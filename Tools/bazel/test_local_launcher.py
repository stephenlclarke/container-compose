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

"""Focused safety checks for the Compose-owned Bazel wrapper."""
from __future__ import annotations

import json
import subprocess
import sys
import os
import signal
import sqlite3
import fcntl
import time
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run
import prepare_dependencies
from input_identity import source_identity, verify
from retain_evidence import retain, validate_client_environment


class LauncherTests(unittest.TestCase):
    def test_profile_and_dependency_overrides(self) -> None:
        self.assertEqual(run.validated_args(['--config=stock', '//:unit_stock']),
                         ('stock', ['//:unit_stock']))
        self.assertEqual(run.validated_args(['//:unit_go']), ('enhanced', ['//:unit_go']))
        for rejected in (['--config=stock', '--config=enhanced'],
                         ['--override_module=container=/tmp/source'],
                         ['--disk_cache=/tmp/cache'], ['--repo_env=TOKEN=value'],
                         ['--flagfile=/tmp/args'], ['--define=DEVCONTAINER_COMMIT=fake'], ['--define', 'runtime_profile=stock'],
                         ['--config=unknown'], ['--config=stock', '--config=enhanced'],
                         ['--noenable_bzlmod']):
            with self.subTest(rejected=rejected), self.assertRaises(ValueError):
                run.validated_args(rejected)

    def test_storage_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'alias').symlink_to(root)
            with self.assertRaisesRegex(ValueError, 'symlinked storage'):
                run.ensure_dir(root / 'alias' / 'cache')

    def test_source_drift_fails(self) -> None:
        before = {'commit': 'a', 'files': {'Package.swift': {'sha256': 'old'}},
                  'tooling': {'run.py': 'old'}}
        with self.assertRaisesRegex(ValueError, 'Sources changed'):
            verify(before, {**before, 'files': {'Package.swift': {'sha256': 'new'}}})
        with self.assertRaisesRegex(ValueError, 'tooling changed'):
            verify(before, {**before, 'tooling': {'run.py': 'new'}})


    def test_ignored_bazel_inputs_are_identified_and_drift_detected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['/usr/bin/git', 'init', '-q', str(root)], check=True)
            (root / '.gitignore').write_text('Tests/**/*.swift\nTests/**/Fixtures/**\nTools/compose-normalizer/**/*.go\nTools/compose-normalizer/coverage.out\nTools/compose-normalizer/compose-normalizer\n')
            (root / 'README').write_text('fixture\n')
            subprocess.run(['/usr/bin/git', '-C', str(root), 'add', '.gitignore', 'README'], check=True)
            subprocess.run(['/usr/bin/git', '-C', str(root), '-c', 'user.name=Fixture',
                            '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            entries = {'Tests/Suite/Case.swift': 'swift',
                       'Tests/Suite/Fixtures/payload.json': '{}',
                       'Tools/compose-normalizer/sub/logic.go': 'package sub'}
            for name, content in entries.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            before = source_identity(root)
            self.assertTrue(before['dirty'])
            self.assertTrue(set(entries) <= set(before['files']))
            (root / 'Tools/compose-normalizer/coverage.out').write_text('generated')
            (root / 'Tools/compose-normalizer/compose-normalizer').write_text('binary')
            self.assertEqual(source_identity(root)['files'], before['files'])
            target = root / 'Tools/compose-normalizer/sub/logic.go'
            target.write_text('package changed')
            with self.assertRaisesRegex(ValueError, 'Sources changed'):
                verify(before, source_identity(root))



    def test_retained_status_honors_wrapper_cancellation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            events = root / 'events.json'
            events.write_text('\n'.join((
                json.dumps({'started': {'uuid': '00000000-0000-0000-0000-000000000001', 'command': 'build'}}),
                json.dumps({'finished': {'exitCode': {'code': 0}}}))) + '\n')
            (root / 'outcome.json').write_text(json.dumps({'bazel_exit_code': 143,
                'validation_exit_code': 0, 'suite': ''}))
            database = root / 'evidence.sqlite'
            retain(events, database, root)
            with sqlite3.connect(database) as connection:
                status = connection.execute('SELECT exit_code FROM invocations').fetchone()[0]
            self.assertEqual(status, 143)

    def test_prepared_tree_digest_includes_patch_created_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['/usr/bin/git', 'init', '-q', str(root)], check=True)
            source = root / 'Package.swift'
            source.write_text('base')
            subprocess.run(['/usr/bin/git', '-C', str(root), 'add', 'Package.swift'], check=True)
            before = prepare_dependencies.source_tree_hash(root, os.environ.copy())
            (root / 'lib').mkdir()
            (root / 'lib/zstd.h').write_text('patch-created')
            after = prepare_dependencies.source_tree_hash(root, os.environ.copy())
            self.assertNotEqual(before, after)

    def test_event_client_environment_drops_unknown_secrets(self) -> None:
        validate_client_environment({'optionName': 'client_env', 'optionValue': 'PATH=/usr/bin'})
        with self.assertRaisesRegex(ValueError, 'Unsafe inherited environment'):
            validate_client_environment({'optionName': 'client_env', 'optionValue': 'GH_TOKEN=secret'})


    def test_wrapper_term_holds_lease_until_owned_child_finishes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lease, ready, finished, output = (root / name for name in ('lease', 'ready', 'finished', 'output'))
            child = ("import signal,time,pathlib; "
                     "signal.signal(signal.SIGTERM, lambda *_: (time.sleep(0.6), exit(0))); "
                     f"pathlib.Path({str(ready)!r}).write_text('ready'); "
                     "time.sleep(10)")
            parent = ("import fcntl,pathlib,run,sys; "
                      f"lock=pathlib.Path({str(lease)!r}).open('a+b'); "
                      "fcntl.flock(lock, fcntl.LOCK_EX); "
                      f"status=run.run_owned([sys.executable,'-c',{child!r}], "
                      f"pathlib.Path({str(output)!r}),dict(PATH='/usr/bin:/bin')); "
                      f"pathlib.Path({str(finished)!r}).write_text(str(status))")
            process = subprocess.Popen([sys.executable, '-c', parent],
                                       cwd=Path(run.__file__).parent, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.PIPE, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists(), process.stderr.read().decode() if process.poll() is not None else '')
                time.sleep(0.1)  # The parent has installed its forwarder.
                os.kill(process.pid, signal.SIGTERM)
                with lease.open('a+b') as competitor:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(competitor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertIsNone(process.poll())
                process.wait(timeout=5)
                self.assertEqual(process.returncode, 0, process.stderr.read().decode())
                self.assertEqual(finished.read_text(), str(128 + signal.SIGTERM))
                with lease.open('a+b') as competitor:
                    fcntl.flock(competitor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                if process.stderr is not None:
                    process.stderr.close()


    def test_forced_client_termination_quarantines_next_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ready, marker, output = (root / name for name in ('ready', 'recovery.json', 'output'))
            child = ("import signal,time,pathlib; "
                     "signal.signal(signal.SIGTERM, lambda *_: None); "
                     f"pathlib.Path({str(ready)!r}).write_text('ready'); "
                     "time.sleep(10)")
            parent = ("import pathlib,run,sys; "
                      f"status=run.run_owned([sys.executable,'-c',{child!r}], "
                      f"pathlib.Path({str(output)!r}),dict(PATH='/usr/bin:/bin'), "
                      f"pathlib.Path({str(marker)!r}),0.2); "
                      "sys.exit(0 if status==143 else 3)")
            process = subprocess.Popen([sys.executable, '-c', parent],
                                       cwd=Path(run.__file__).parent, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.PIPE, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists())
                time.sleep(0.1)
                os.kill(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
                self.assertEqual(process.returncode, 0, process.stderr.read().decode())
                self.assertEqual(json.loads(marker.read_text())['reason'],
                                 'owned Bazel client ignored cancellation')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                if process.stderr is not None:
                    process.stderr.close()

    def test_signal_during_launch_is_forwarded_after_child_assignment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child_pid = root / 'child.pid'
            child = "import time; time.sleep(10)"
            parent = f"""import os, signal, run, subprocess, sys, pathlib
original = subprocess.Popen
def wrapped(*a, **k):
    process = original(*a, **k)
    pathlib.Path({str(child_pid)!r}).write_text(str(process.pid))
    os.kill(os.getpid(), signal.SIGTERM)
    return process
run.subprocess.Popen = wrapped
status = run.run_owned([sys.executable, '-c', {child!r}],
                       pathlib.Path({str(root / 'out')!r}), dict(PATH='/usr/bin:/bin'),
                       cancel_grace=1)
sys.exit(0 if status == 143 else 3)
"""
            process = subprocess.run([sys.executable, '-c', parent], cwd=Path(run.__file__).parent,
                                     capture_output=True, text=True, timeout=5,
                                     env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertTrue(child_pid.exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(int(child_pid.read_text()), 0)

    def test_help_does_not_preflight_or_build(self) -> None:
        with patch.object(run, 'preflight', side_effect=AssertionError('preflight called')):
            self.assertEqual(run.main(['--help']), 0)
