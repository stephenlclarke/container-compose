#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Real subprocess regressions at the full-suite log/resource boundary."""

from contextlib import nullcontext
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

import cli_process
import full_suite
import full_suite_scratch
import qualify_local as local


# Construct the loop without quoting through a shell.
CHILD = "import os,time\nos.setpgrp()\nprint('child-writing',flush=True)\nwhile True:\n print('tick',flush=True)\n time.sleep(.02)\n"


def command(linger: bool = True) -> list[str]:
    source = ("import subprocess,sys,time\n"
              f"subprocess.Popen([sys.executable, '-c', {CHILD!r}])\n"
              + ("time.sleep(60)\n" if linger else "time.sleep(.15)\n"))
    return [sys.executable, '-c', source]


class QualifiedProcessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = dict(os.environ, **{cli_process.CASE_NONCE: uuid.uuid4().hex})

    def test_timeout_drains_detached_group_before_sealing_full_case_log(self) -> None:
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'],
                                     start_new_session=True)
        self.addCleanup(lambda: (unrelated.kill(), unrelated.wait()) if unrelated.poll() is None else None)
        runtime_logs = self.root / 'runtime'
        runtime_logs.mkdir()
        script = self.root / 'bridge'
        script.write_text('#!' + sys.executable + '\n' + command()[2])
        script.chmod(0o700)
        name = 'docker-compose-bridge-parity'
        item = {'target': name, 'script': str(script), 'script_sha256': local.sha(script),
                'owned_prefixes': [], 'owned_image_prefixes': [], 'fixed_names': []}
        baseline = {lane: {kind: {} for kind in ('containers', 'networks', 'volumes', 'images')}
                    for lane in ('candidate', 'docker')}
        runner = SimpleNamespace(rows=[], evidence=runtime_logs, runtime_environment={})
        runtime = SimpleNamespace(environment=lambda lane: dict(os.environ))
        real_run = cli_process.run
        scratch_create = full_suite_scratch.create
        def bounded(*args, **kwargs):
            self.assertEqual(kwargs['timeout'], 600)
            kwargs['timeout'] = .5
            return real_run(*args, **kwargs)
        with patch.dict(sys.modules, {'fork_benchmark': SimpleNamespace(command_lease=lambda env: nullcontext(()))}), \
             patch.object(local.subprocess, 'check_output', return_value='/SDK'), \
             patch.object(full_suite, 'inventory', return_value=[item]), \
             patch.object(full_suite, 'snapshot', return_value=baseline), \
             patch.object(local, 'full_suite_sources', return_value={name: item['script_sha256']}), \
             patch.object(full_suite_scratch, 'create', side_effect=lambda evidence: scratch_create(evidence, root=self.root/'scratch')), \
             patch.object(cli_process, 'run', side_effect=bounded):
            with self.assertRaisesRegex(RuntimeError, 'case failed'):
                local.run_original_full_suite(self.root, runner, runtime, self.root/'install',
                                               self.root/'plugin', {}, lambda *args: None,
                                               development_bridge=True)
        receipt = json.loads((self.root/'full-suite'/f'{name}.json').read_text())
        self.assertEqual(receipt['status'], 124)
        log = Path(receipt['log'])
        self.assertIn('child-writing', log.read_text())
        size = log.stat().st_size
        time.sleep(.1)
        self.assertEqual(log.stat().st_size, size)
        self.assertEqual(local.sha(log), receipt['log_sha256'])
        case = full_suite.Ledger(self.root/'full-suite').data['cases'][0]
        self.assertTrue(case['session']['cleared'])
        self.assertTrue(case['restored'])
        self.assertFalse(cli_process.session_members(case['session']['sid']))
        self.assertIsNone(unrelated.poll())
        self.assertFalse((self.root/'full-suite/acceptance.json').exists())

    def test_launch_claim_failure_never_executes_command(self) -> None:
        marker = self.root/'executed'
        records = []
        def fail(record):
            records.append(record)
            raise RuntimeError('journal unavailable')
        with open(os.devnull, 'w') as stream, self.assertRaisesRegex(RuntimeError, 'journal unavailable'):
            cli_process.run([sys.executable, '-c', f'open({str(marker)!r},"w").write("bad")'],
                            cwd=self.root, env=self.environment, stdout=stream, stderr=stream,
                            timeout=1, on_start=fail)
        self.assertFalse(marker.exists())
        self.assertFalse(cli_process.session_members(records[0]['sid']))

    def test_command_lease_descriptor_survives_gated_exec(self) -> None:
        read_fd, write_fd = os.pipe()
        records = []
        try:
            status = cli_process.run(
                [sys.executable, '-c', f'import os; os.write({write_fd}, b"lease")'],
                cwd=self.root, env=self.environment, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=2, on_start=records.append,
                pass_fds=(write_fd,))
            self.assertEqual(status, 0)
            os.close(write_fd)
            write_fd = -1
            self.assertEqual(os.read(read_fd, 16), b'lease')
        finally:
            os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)

    def test_gate_eof_exits_without_launching_payload(self) -> None:
        read_fd, write_fd = os.pipe()
        marker = self.root/'should-not-exist'
        process = subprocess.Popen(
            [sys.executable, '-c', cli_process._GATED_EXEC, str(read_fd),
             sys.executable, '-c', f'open({str(marker)!r}, "w").close()'],
            pass_fds=(read_fd,), start_new_session=True)
        os.close(read_fd)
        os.close(write_fd)
        self.assertEqual(process.wait(timeout=3), 125)
        self.assertFalse(marker.exists())

    def test_recovery_identifies_child_after_session_leader_exits(self) -> None:
        with (self.root/'orphan-log').open('w') as stream:
            process = subprocess.Popen(command(False), env=self.environment,
                                       stdout=stream, stderr=stream, start_new_session=True)
            record = {'pid': process.pid, 'sid': process.pid,
                      'birth': cli_process.process_birth(process.pid),
                      'nonce': self.environment[cli_process.CASE_NONCE]}
            try:
                self.assertEqual(process.wait(timeout=3), 0)
                self.assertTrue(cli_process.session_members(process.pid))
                cli_process.recover_session(record)
                self.assertFalse(cli_process.session_members(process.pid))
            finally:
                cli_process.terminate_session(process)

    def test_normal_exit_with_detached_writer_cannot_succeed(self) -> None:
        records, cleared = [], []
        with (self.root/'log').open('w') as stream, self.assertRaisesRegex(RuntimeError, 'helper processes'):
            cli_process.run(command(False), cwd=self.root, env=self.environment,
                            stdout=stream, stderr=stream, timeout=2,
                            on_start=records.append, on_clear=lambda: cleared.append(True))
        self.assertEqual(cleared, [True])
        self.assertFalse(cli_process.session_members(records[0]['sid']))

    def test_recovery_requires_original_birth_and_nonce(self) -> None:
        process = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'],
                                   env=self.environment, start_new_session=True)
        self.addCleanup(lambda: (process.kill(), process.wait()) if process.poll() is None else None)
        record = {'pid': process.pid, 'sid': process.pid,
                  'birth': cli_process.process_birth(process.pid),
                  'nonce': self.environment[cli_process.CASE_NONCE]}
        for wrong in (dict(record, birth='different'), dict(record, nonce='0'*32)):
            with self.assertRaisesRegex(RuntimeError, 'refusing cleanup'):
                cli_process.recover_session(wrong)
            self.assertIsNone(process.poll())
        cli_process.recover_session(record)
        process.wait(timeout=3)
        self.assertFalse(cli_process.session_members(record['sid']))

    def test_unverified_cleanup_preserves_case_ownership(self) -> None:
        ledger = full_suite.Ledger(self.root/'full-suite')
        ledger.begin('case', 'a'*64, [], {}, supervised=True)
        with (self.root/'log').open('w') as stream:
            def claim(record):
                ledger.claim_session('case', 'a'*64, record)
            real_terminate = cli_process.terminate_session
            records = []
            def failed_cleanup(process):
                records.append(process)
                raise RuntimeError('cleanup unverified')
            try:
                with patch.object(cli_process, 'terminate_session', side_effect=failed_cleanup), \
                     self.assertRaisesRegex(RuntimeError, 'cleanup unverified'):
                    cli_process.run(command(), cwd=self.root, env=self.environment,
                                    stdout=stream, stderr=stream, timeout=.2,
                                    on_start=claim, on_clear=lambda: ledger.clear_session('case'))
                self.assertFalse(full_suite.Ledger(ledger.directory).pending()[0]['session']['cleared'])
                with self.assertRaisesRegex(RuntimeError, 'session remains active'):
                    ledger.recover(lambda *args: self.fail('inventory must not run'), {'case': 'a'*64})
            finally:
                for process in records:
                    real_terminate(process)


if __name__ == '__main__':
    unittest.main()
