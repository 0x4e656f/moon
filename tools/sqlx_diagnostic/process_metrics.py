"""Read-only OS sampling, standard library only. Also streamed over SSH to a PG host."""
import ctypes
import json
import os
from pathlib import Path
import sys
import time


def process_ids():
    if sys.platform == "linux":
        return [int(p.name) for p in Path("/proc").iterdir() if p.name.isdigit()]
    if os.name == "nt":
        from ctypes import wintypes as w
        api = ctypes.WinDLL("psapi", use_last_error=True)
        api.EnumProcesses.argtypes = [ctypes.POINTER(w.DWORD), w.DWORD, ctypes.POINTER(w.DWORD)]
        size = 4096
        while True:
            values = (w.DWORD * size)()
            used = w.DWORD()
            if not api.EnumProcesses(values, ctypes.sizeof(values), ctypes.byref(used)):
                raise ctypes.WinError(ctypes.get_last_error())
            if used.value < ctypes.sizeof(values):
                return list(values[:used.value // ctypes.sizeof(w.DWORD)])
            size *= 2
    raise RuntimeError("OS sampling supports Windows and Linux only")


def read_process(pid):
    if sys.platform == "linux":
        base = Path("/proc") / str(pid)
        stat = (base / "stat").read_text()
        left, right = stat.index("("), stat.rindex(")")
        fields = stat[right + 2:].split()  # starts at stat field 3
        result = {"pid": pid, "name": stat[left + 1:right], "identity": fields[19],
                  "cpu_s": (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK"),
                  "rss_bytes": int(fields[21]) * os.sysconf("SC_PAGE_SIZE")}
        try:
            io = dict(line.split(":", 1) for line in (base / "io").read_text().splitlines())
            result.update(read_bytes=int(io["read_bytes"]), write_bytes=int(io["write_bytes"]))
        except (OSError, KeyError, ValueError):
            pass
        return result
    if os.name != "nt":
        raise RuntimeError("OS sampling supports Windows and Linux only")
    from ctypes import wintypes as w
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    p = ctypes.WinDLL("psapi", use_last_error=True)
    k.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    k.OpenProcess.restype = w.HANDLE
    k.CloseHandle.argtypes = [w.HANDLE]
    k.GetProcessTimes.argtypes = [w.HANDLE] + [ctypes.POINTER(w.FILETIME)] * 4
    k.QueryFullProcessImageNameW.argtypes = [w.HANDLE, w.DWORD, w.LPWSTR, ctypes.POINTER(w.DWORD)]

    class Memory(ctypes.Structure):
        _fields_ = [("cb", w.DWORD), ("PageFaultCount", w.DWORD)] + [
            (name, ctypes.c_size_t) for name in ("PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
            "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage", "PagefileUsage",
            "PeakPagefileUsage", "PrivateUsage")]

    class IO(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in
                    ("ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                     "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    p.GetProcessMemoryInfo.argtypes = [w.HANDLE, ctypes.POINTER(Memory), w.DWORD]
    k.GetProcessIoCounters.argtypes = [w.HANDLE, ctypes.POINTER(IO)]
    handle = k.OpenProcess(0x1000 | 0x0010, False, pid)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        created, exited, kernel, user = (w.FILETIME() for _ in range(4))
        mem = Memory(); mem.cb = ctypes.sizeof(mem)
        name = ctypes.create_unicode_buffer(32768); length = w.DWORD(len(name))
        if not (k.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited), ctypes.byref(kernel), ctypes.byref(user))
                and p.GetProcessMemoryInfo(handle, ctypes.byref(mem), mem.cb)
                and k.QueryFullProcessImageNameW(handle, 0, name, ctypes.byref(length))):
            raise ctypes.WinError(ctypes.get_last_error())
        def ticks(value):
            return (value.dwHighDateTime << 32) | value.dwLowDateTime
        result = {"pid": pid, "name": Path(name.value).stem, "identity": str(ticks(created)),
                  "cpu_s": (ticks(kernel) + ticks(user)) / 1e7, "rss_bytes": mem.WorkingSetSize,
                  "private_bytes": mem.PrivateUsage}
        counts = IO()
        if k.GetProcessIoCounters(handle, ctypes.byref(counts)):
            result.update(read_bytes=counts.ReadTransferCount, write_bytes=counts.WriteTransferCount)
        return result
    finally:
        k.CloseHandle(handle)


class Sampler:
    def __init__(self):
        self.previous = {}

    def sample(self, pids=None, names=None):
        now = time.monotonic()
        records, denied = [], 0
        wanted = {n.lower() for n in names or []}
        for pid in pids if pids is not None else process_ids():
            try:
                value = read_process(pid)
                if wanted and value["name"].lower() not in wanted:
                    continue
                records.append(value)
            except (OSError, ValueError):
                denied += 1
        result = {"epoch_s": time.time(), "process_count": len(records), "unreadable_processes": denied,
                  "logical_cpus": os.cpu_count(), "pids": [r["pid"] for r in records]}
        if not records:
            result["error"] = "No readable matching process; missing metrics are not zero"
        else:
            result["rss_bytes"] = sum(r["rss_bytes"] for r in records)
            if all("private_bytes" in r for r in records):
                result["private_bytes"] = sum(r["private_bytes"] for r in records)
        rates = []
        for r in records:
            key = (r["pid"], r["identity"])
            previous = self.previous.get(key)
            if previous and now > previous[0]:
                elapsed = now - previous[0]
                delta = r["cpu_s"] - previous[1]["cpu_s"]
                if delta >= 0:
                    rates.append(delta / elapsed * 100)
            self.previous[key] = (now, r)
        live = {(r["pid"], r["identity"]) for r in records}
        self.previous = {k: v for k, v in self.previous.items() if k in live}
        if rates:
            result["cpu_pct"] = sum(rates)  # 100% = one fully utilized logical CPU, can exceed 100
            result["cpu_sampled_processes"] = len(rates)
        return result


def stream(options):
    sampler = Sampler()
    end = time.monotonic() + options["duration_s"]
    while time.monotonic() < end:
        try:
            result = sampler.sample(names=options["names"])
        except Exception as exc:
            result = {"epoch_s": time.time(), "error": str(exc)}
        print(json.dumps(result, allow_nan=False), flush=True)
        time.sleep(options["sample_ms"] / 1000)


if __name__ == "__main__":
    stream(json.loads(sys.argv[1]))
