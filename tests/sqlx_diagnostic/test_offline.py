"""Offline unit tests. Real process metrics only sample this Python process, never Moon/PG."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import time
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools/sqlx_diagnostic'))
import process_metrics
import report
import run


def fixture():
    # Independent fixture, deliberately no user config / credentials.
    return dict(sweep_duration_ms=20000, compare_duration_ms=30000, deadline_ms=360000,
                timeout_ms=10000, monitor_timeout_ms=2000, warmup_ms=2000, idle_ms=10000,
                shutdown_grace_ms=15000, sample_ms=2000, checkpoint_ms=10000,
                sweep_concurrency=32, compare_concurrency=8, compare_poolsize=8,
                pool_sizes=[4, 8, 16], workload=[dict(name='point', weight=1)], allow_write=True,
                monitor=dict(sample_ms=1000, pg_os_mode='disabled', pg_process_names=['postgres'],
                             ssh_target='', ssh_port=22, ssh_python='python3'))


class OfflineTests(unittest.TestCase):
    def test_plan(self):
        self.assertEqual(run.validate(fixture()), 270000)
        for change in [dict(allow_write=False), dict(compare_concurrency=9), dict(deadline_ms=260000),
                       dict(pool_sizes=[4,4]), dict(runtime={}), dict(sample_ms=1),
                       dict(workload=[dict(name='hot_lane', weight=1)])]:
            with self.assertRaises(ValueError):
                run.validate(dict(fixture(), **change))

    def test_no_injection_or_secrets(self):
        secret = '"\n]];os.exit();--中文'
        encoded = run.lua_literal(secret)
        self.assertNotIn('os.exit', encoded)
        self.assertNotIn('\n', encoded)
        self.assertNotIn('中文', encoded)
        for bad in [None, float('nan'), float('inf')]:
            with self.assertRaises(ValueError):
                run.lua_literal(bad)
        self.assertEqual(run.public(dict(password='secret', sslkey='secret', runtime={}, host='test')), dict(host='test'))
        cfg = fixture(); cfg['monitor'].update(pg_os_mode='ssh', ssh_target='-oProxyCommand=bad')
        with self.assertRaises(ValueError):
            run.validate(cfg)

    def test_windows_or_linux_current_process_only(self):
        first = process_metrics.read_process(os.getpid())
        self.assertEqual(first['pid'], os.getpid())
        self.assertGreater(first['rss_bytes'], 0)
        sampler = process_metrics.Sampler()
        self.assertNotIn('cpu_pct', sampler.sample(pids=[os.getpid()]))
        until = time.monotonic()+.03
        while time.monotonic() < until:
            sum(range(100))
        sample = sampler.sample(pids=[os.getpid()])
        self.assertGreaterEqual(sample['cpu_pct'], 0)

    def test_pid_reuse_missing_not_zero(self):
        base = dict(pid=123, name='postgres', identity='a', cpu_s=1, rss_bytes=100)
        sampler = process_metrics.Sampler()
        with patch.object(process_metrics, 'read_process', return_value=base):
            self.assertNotIn('cpu_pct', sampler.sample(pids=[123]))
        with patch.object(process_metrics, 'read_process', return_value=dict(base, identity='b', cpu_s=20)):
            self.assertNotIn('cpu_pct', sampler.sample(pids=[123]))
        with patch.object(process_metrics, 'read_process', side_effect=OSError('denied')):
            value = sampler.sample(pids=[123])
            self.assertIn('error', value)
            self.assertNotIn('rss_bytes', value)

    def test_report_comparisons_and_escape(self):
        sample = dict(status='complete', launcher_start_epoch_s=10, config={}, samples=[], checks=[],
                      warnings=['<script>alert(1)</script>'], stages=[], os_samples=[])
        for index, (mode, qps) in enumerate([('direct',100),('driver',80),('driver',100),('direct',120)]):
            sample['stages'].append(dict(name=f'api_{index}', group='api', mode=mode, concurrency=8, poolsize=8,
                status='complete', result=dict(requests_per_s=qps, errors=0, p99_ms=2)))
        groups = report.comparisons(sample)
        self.assertEqual(groups[0]['median_qps'], 110)
        self.assertEqual(groups[1]['median_qps'], 90)
        html = report.render(sample)
        self.assertIn('0.818', html)
        self.assertNotIn('<script>', html)
        self.assertIn('&lt;script&gt;', html)
        self.assertIn('未采集', html)
        sample['stages'][0]['status'] = 'failed'
        self.assertIn('不计算完整对照结论', report.render(sample))

    def test_linux_proc_parser(self):
        # stat fields 3..24, process name contains a space and closing parenthesis.
        fields = ['0']*22
        fields[0]='R'; fields[11]='100'; fields[12]='50'; fields[19]='12345'; fields[21]='20'
        stat = '42 (postgres worker)) '+' '.join(fields)
        def read(path, *args, **kwargs):
            return stat if path.name == 'stat' else 'read_bytes: 1024\nwrite_bytes: 2048\n'
        with patch.object(process_metrics.sys, 'platform', 'linux'), patch.object(Path, 'read_text', read), \
             patch.object(process_metrics.os, 'sysconf', side_effect=lambda k: 100 if k=='SC_CLK_TCK' else 4096, create=True):
            value = process_metrics.read_process(42)
        self.assertEqual(value['cpu_s'], 1.5)
        self.assertEqual(value['rss_bytes'], 81920)
        self.assertEqual(value['identity'], '12345')

    def test_launcher_final_report_without_executing_any_binary(self):
        for malformed, exitcode, expected in [(False, 0, 0), (False, 1, 1), (True, 1, 1)]:
            with self.subTest(malformed=malformed, exitcode=exitcode), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                fake = root/'fake-moon'; fake.touch()  # path validation only; never executed
                cfg = dict(fixture(), moon_executable_windows='fake-moon', moon_executable_linux='fake-moon',
                           output_directory='output', password='must-not-leak')
                runtime_paths = []
                class Finished:
                    returncode = exitcode
                    def poll(self): return self.returncode
                    def wait(self, timeout=None): return self.returncode
                def popen(command, **kwargs):
                    self.assertEqual(command[0], str(fake))
                    runtime_paths.append(Path(command[4]))
                    self.assertNotIn('must-not-leak', runtime_paths[-1].read_text(encoding='utf-8'))
                    raw = next((root/'output').iterdir())/'raw.json'
                    raw.write_text('{' if malformed else json.dumps(dict(status='complete', stages=[], samples=[], warnings=[])))
                    return Finished()
                with patch.object(run, 'ROOT', root), patch.object(run.subprocess, 'Popen', side_effect=popen), \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(run.run(cfg), expected)
                output = next((root/'output').iterdir())
                payload = json.loads((output/'report.json').read_text(encoding='utf-8'))
                self.assertNotIn('must-not-leak', json.dumps(payload))
                self.assertTrue((output/'report.html').is_file())
                self.assertTrue(all(not path.exists() for path in runtime_paths))
                self.assertEqual(payload['status']=='complete', expected==0)


if __name__ == '__main__':
    unittest.main()
