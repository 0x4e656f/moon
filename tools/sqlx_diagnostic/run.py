"""User-invoked launcher. --check never starts Moon, SSH, or database connections."""
import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import queue
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from process_metrics import Sampler
from report import render

ROOT = Path(__file__).resolve().parents[2]


def lua_literal(value):
    """Byte escapes prevent source injection/newline/encoding ambiguity in generated Lua."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        if not math.isfinite(value):
            raise ValueError("configuration contains a non-finite number")
        return str(value)
    if isinstance(value, str):
        return '"' + ''.join(f'\\{byte:03d}' for byte in value.encode('utf-8')) + '"'
    if isinstance(value, list):
        return '{' + ','.join(lua_literal(v) for v in value) + '}'
    if isinstance(value, dict):
        return '{' + ','.join('['+lua_literal(k)+']='+lua_literal(v) for k, v in value.items()) + '}'
    raise ValueError("configuration may not contain null or unsupported values")


def validate(config, require_write=True):
    def integer(key, minimum, maximum):
        n = config.get(key)
        if type(n) is not int or not minimum <= n <= maximum:
            raise ValueError(f'{key} must be an integer in {minimum}..{maximum}')
    for key in ('sweep_duration_ms', 'compare_duration_ms', 'deadline_ms', 'timeout_ms', 'monitor_timeout_ms'):
        integer(key, 1, 2147483647)
    for key in ('warmup_ms', 'idle_ms', 'shutdown_grace_ms'):
        integer(key, 0, 2147483647)
    integer('sample_ms', 100, 2147483647)
    integer('checkpoint_ms', config['sample_ms'], 2147483647)
    for key in ('sweep_concurrency', 'compare_concurrency'):
        integer(key, 1, 65535)
    integer('compare_poolsize', 1, 1024)
    if config['compare_concurrency'] > config['compare_poolsize']:
        raise ValueError('compare_concurrency must not exceed compare_poolsize')
    sizes = config.get('pool_sizes')
    if not isinstance(sizes, list) or not 1 <= len(sizes) <= 8 or any(type(n) is not int or not 1 <= n <= 1024 for n in sizes):
        raise ValueError('pool_sizes must have 1..8 positive integers <=1024')
    if len(set(sizes)) != len(sizes):
        raise ValueError('pool_sizes must be unique')
    if not isinstance(config.get('workload'), list) or not config['workload']:
        raise ValueError('workload must be nonempty')
    if any(w.get('name') == 'hot_lane' for w in config['workload']):
        raise ValueError('hot_lane is excluded from the common direct/driver workload')
    if require_write and config.get('allow_write') is not True:
        raise ValueError('Configure a dedicated test database and set allow_write=true first')
    if 'runtime' in config:
        raise ValueError('runtime is reserved for the launcher')
    monitor = config['monitor']
    fields = {'sample_ms', 'pg_os_mode', 'pg_process_names', 'ssh_target', 'ssh_port', 'ssh_python'}
    if set(monitor) != fields:
        raise ValueError('monitor has missing or unknown settings')
    if type(monitor['sample_ms']) is not int or not 100 <= monitor['sample_ms'] <= 60000:
        raise ValueError('monitor.sample_ms must be 100..60000')
    if monitor['pg_os_mode'] not in ('disabled', 'local', 'ssh'):
        raise ValueError('pg_os_mode must be disabled, local, or ssh')
    if not isinstance(monitor['pg_process_names'], list) or not monitor['pg_process_names'] or not all(
            isinstance(n, str) and re.fullmatch(r'[A-Za-z0-9_.-]+', n) for n in monitor['pg_process_names']):
        raise ValueError('invalid PG process names')
    if monitor['pg_os_mode'] == 'ssh':
        if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@:-]*', monitor['ssh_target']):
            raise ValueError('ssh_target must be an SSH host alias or user@host, not a command')
        if type(monitor['ssh_port']) is not int or not 1 <= monitor['ssh_port'] <= 65535:
            raise ValueError('invalid ssh_port')
        if not re.fullmatch(r'[A-Za-z0-9_/.-]+', monitor['ssh_python']) or monitor['ssh_python'].startswith('-'):
            raise ValueError('ssh_python must be a Python executable path/name')
    planned = (2*len(sizes)*config['sweep_duration_ms'] + 4*config['compare_duration_ms']
               + (2*len(sizes)+4)*config['warmup_ms'] + config['idle_ms'])
    if planned >= config['deadline_ms']:
        raise ValueError('deadline_ms must leave setup/drain time beyond the complete plan')
    lua_literal(config)  # reject unsupported values before launching any subprocess
    return planned


def public(config):
    return {k: v for k, v in config.items() if k not in ('password', 'sslkey', 'runtime')}


def atomic_text(path, content):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(content, encoding='utf-8')
    temporary.replace(path)


def start_pg_collector(config, stderr):
    monitor = config['monitor']
    if monitor['pg_os_mode'] == 'disabled':
        return None
    helper = Path(__file__).with_name('process_metrics.py')
    options = json.dumps(dict(names=monitor['pg_process_names'], sample_ms=monitor['sample_ms'],
                              duration_s=(config['deadline_ms']+config['shutdown_grace_ms'])/1000+10))
    flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
    if monitor['pg_os_mode'] == 'local':
        return subprocess.Popen([sys.executable, '-u', str(helper), options], stdout=subprocess.PIPE,
                                stderr=stderr, text=True, encoding='utf-8', creationflags=flags)
    command = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5",
               "-p", str(monitor['ssh_port']), monitor['ssh_target'],
               shlex.quote(monitor['ssh_python']) + ' -u - ' + shlex.quote(options)]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                               text=True, encoding='utf-8', creationflags=flags)
    try:
        process.stdin.write(helper.read_text(encoding='utf-8'))
        process.stdin.close()
    except Exception:
        process.terminate(); process.wait(timeout=10)
        raise
    return process


def read_pg(process, messages):
    try:
        for line in process.stdout:
            try:
                messages.put((time.monotonic(), json.loads(line)))
            except json.JSONDecodeError:
                messages.put((time.monotonic(), {'error': 'Invalid PG collector output; check pg-monitor.log'}))
    finally:
        process.stdout.close()


def stop_child(process, label, warnings):
    """Only handles children started by this launcher; cleanup failure must not skip HTML."""
    try:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)
    except OSError as exc:
        warnings.append(label+' cleanup failed: '+str(exc))
    except subprocess.TimeoutExpired:
        warnings.append(label+' did not exit; inspect the child process and test schema.')


def run(config):
    planned = validate(config)
    executable = ROOT / config['moon_executable_windows' if os.name == 'nt' else 'moon_executable_linux']
    if not executable.is_file():
        raise ValueError('Moon executable does not exist: ' + str(executable))
    output_parent = (ROOT / config['output_directory']).resolve()
    output_parent.mkdir(parents=True, exist_ok=True)
    token = f'{int(time.time())}_{uuid.uuid4().hex[:10]}'
    output = output_parent / ('sqlx_diagnostic_' + token)
    output.mkdir()  # unique directory; never overwrite an existing run
    raw_path, report_path, html_path = (output / name for name in ('raw.json', 'report.json', 'report.html'))
    origin = time.time()
    report = dict(status='running', config=public(config), launcher_start_epoch_s=origin,
                  started_utc=datetime.now(timezone.utc).isoformat(), warnings=[], stages=[], samples=[])
    atomic_text(html_path, render(report))
    print(f'Plan: {planned/1000:.0f}s load/warmup/idle, plus setup/drain. HTML: {html_path}', flush=True)
    print('Only dedicated test data is created. No SQL retry. Final report is generated even on an ordinary failure.', flush=True)
    descriptor, private_path = tempfile.mkstemp(prefix='moon_sqlxdiag_', suffix='.lua')
    process = pg = None
    os_samples, warnings = [], []
    monitor_log = None
    forced = False
    try:
        runtime = dict(config, runtime=dict(root=ROOT.as_posix(), raw_output=raw_path.as_posix(), token=token))
        with os.fdopen(descriptor, 'w', encoding='utf-8') as f:
            f.write('return ' + lua_literal(runtime))
        runtime_arg = Path(private_path).as_posix()
        if "'" in runtime_arg or any(c in runtime_arg for c in '\n\r'):
            raise ValueError('Moon argument parser cannot accept this temporary directory path')
        monitor_log = (output / 'pg-monitor.log').open('w', encoding='utf-8')
        try:
            pg = start_pg_collector(config, monitor_log)
        except (OSError, ValueError) as exc:
            warnings.append('PG OS collector could not start: ' + str(exc))
        if config['monitor']['pg_os_mode'] == 'disabled':
            warnings.append('PG OS CPU/RSS 未采集：monitor.pg_os_mode=disabled；PG SQL 等待/统计仍可采集。')
        if config['monitor']['pg_os_mode'] == 'local':
            warnings.append('PG OS 采集范围为 Moon 所在主机的匹配进程；必须由使用者确认数据库也在本机，不能代表远程 PG。')
        messages = queue.Queue()
        if pg:
            threading.Thread(target=read_pg, args=(pg, messages), daemon=True).start()
        process = subprocess.Popen([str(executable), str(ROOT/'example/diagnose_sqlx_pg.lua'), 'sqlxdiag', 'manual', runtime_arg],
                                   cwd=ROOT, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        sampler = Sampler()
        limit = time.monotonic() + (config['deadline_ms']+config['shutdown_grace_ms'])/1000
        latest_pg = None
        interval = config['monitor']['sample_ms']/1000
        with (output/'os.jsonl').open('w', encoding='utf-8') as stream:
            while process.poll() is None:
                begin = time.monotonic()
                value = {'epoch_s': time.time()}
                try:
                    value['moon'] = sampler.sample(pids=[process.pid])
                except Exception as exc:
                    value['moon'] = {'error': str(exc)}
                while True:
                    try:
                        latest_pg = messages.get_nowait()
                    except queue.Empty:
                        break
                if latest_pg and time.monotonic()-latest_pg[0] <= max(3, interval*3):
                    value['pg'] = latest_pg[1]
                    value['pg_received_age_s'] = time.monotonic()-latest_pg[0]
                elif pg:
                    value['pg'] = {'error': 'No fresh PG OS sample; check pg-monitor.log / permissions'}
                os_samples.append(value)
                stream.write(json.dumps(value, allow_nan=False)+'\n'); stream.flush()
                if time.monotonic() >= limit:
                    forced = True
                    warnings.append('Moon exceeded deadline + grace and was terminated. Write outcomes may be unknown; inspect test schema.')
                    process.terminate()
                    break
                try:
                    process.wait(timeout=max(.01, interval-(time.monotonic()-begin)))
                except subprocess.TimeoutExpired:
                    pass
        process.wait(timeout=10)
    except KeyboardInterrupt:
        warnings.append('User interrupted the run; incomplete results, verify remaining test schema.')
        forced = True
    except Exception as exc:
        # No config values/URLs in exception text emitted by this wrapper.
        warnings.append('Launcher failure: '+str(exc))
        forced = True
    finally:
        stop_child(process, 'Moon', warnings)
        stop_child(pg, 'PG collector', warnings)
        if monitor_log:
            monitor_log.close()
        try:
            Path(private_path).unlink(missing_ok=True)
        except OSError:
            warnings.append('Could not delete private runtime config; remove this credential file: '+private_path)
        try:
            report.update(json.loads(raw_path.read_text(encoding='utf-8')))
        except (OSError, json.JSONDecodeError):
            report['status'] = 'failed'
            warnings.append('No readable raw.json. A crash may have left schema moon_sqlxdiag_'+token)
        report['warnings'] = report.get('warnings', []) + warnings
        report['os_samples'] = os_samples
        report['moon_exit_code'] = process.returncode if process else None
        report['launcher_start_epoch_s'] = origin
        if forced or report['moon_exit_code'] != 0 or report['status'] != 'complete':
            report['status'] = 'failed' if report['status'] == 'complete' else report['status']
            if report['status'] == 'running':
                report['status'] = 'interrupted'
        for source in ('moon', 'pg'):
            usable = sum(sample.get(source, {}).get('cpu_pct') is not None for sample in os_samples)
            missing = sum('error' in sample.get(source, {}) for sample in os_samples)
            if usable == 0:
                report['warnings'].append(source+' OS CPU 不可用，不能进行 CPU 瓶颈判断。')
            elif missing:
                report['warnings'].append(f'{source} OS 有 {missing} 个缺失/失败采样窗口；不要把空白当作零。')
        try:
            atomic_text(report_path, json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
        except (OSError, ValueError) as exc:
            report['status'] = 'failed'
            report['warnings'].append('Final JSON export failed: '+str(exc))
        try:
            atomic_text(html_path, render(report))
        except OSError as exc:
            report['status'] = 'failed'
            print('Final HTML export failed: '+str(exc), file=sys.stderr)
            try:
                report['report_error'] = str(exc)
                atomic_text(report_path, json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
            except OSError:
                pass
        print('JSON: '+str(report_path), flush=True)
        print('HTML: '+str(html_path), flush=True)
    return 0 if report['status'] == 'complete' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT/'example/sqlx_diagnostic/config.json')
    parser.add_argument('--check', action='store_true', help='offline config/plan check only; never starts Moon or SSH')
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding='utf-8-sig'))
    if args.check:
        planned = validate(config, require_write=False)
        print(f'Offline preflight OK: {2*len(config["pool_sizes"])+4} stages, {planned/1000:.0f}s planned; '
              f'allow_write={config.get("allow_write")}. Full Lua validation occurs before DB access.')
        return 0
    return run(config)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError) as exc:
        print('Configuration/launcher error: '+str(exc), file=sys.stderr)
        sys.exit(1)
