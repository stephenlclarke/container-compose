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

"""Exercise keychain interruption/restoration using fake security commands only."""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import keychain_fixture as fixture

OWNER = 'a' * 32
PASSWORD = 'test-only-password'


class FakeSecurity:
    def __init__(self, directory: Path, original: list[str]):
        self.directory = directory.resolve()
        self.paths = list(original)
        self.original = list(original)
        self.mutations: list[str] = []
        self.interrupt: str | None = None
        self.ignore_selection = False

    def __call__(self, *args: str) -> str:
        if args == ('list-keychains', '-d', 'user'):
            return '\n'.join('    ' + json.dumps(path) for path in self.paths) + '\n'
        record = json.loads((self.directory / fixture.RECEIPT).read_text())
        if record['original_search_list'] != self.original or record['restored']:
            raise AssertionError('Mutation has no prior restoration intent')
        operation = args[0]
        self.mutations.append(operation)
        if operation == 'create-keychain':
            Path(args[-1]).write_text('opaque fake keychain bytes')
            self.paths.append(args[-1])  # security may add it during creation.
        elif operation == 'list-keychains':
            if args[:4] != ('list-keychains', '-d', 'user', '-s'):
                raise AssertionError('Unexpected search-list command')
            if not self.ignore_selection:
                self.paths = list(args[4:])
        elif operation == 'delete-keychain':
            Path(args[-1]).unlink()
            self.paths = [path for path in self.paths if path != args[-1]]
        elif operation not in ('set-keychain-settings', 'unlock-keychain', 'add-generic-password'):
            raise AssertionError('Unexpected security mutation')
        if self.interrupt == operation:
            raise KeyboardInterrupt('injected interruption after mutation')
        return ''


class KeychainFixtureTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix='compose keychain fixture ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.directory = self.root / 'journal'
        self.original = ['/fixture/login.keychain-db', '/fixture/another keychain.keychain-db']
        self.security = FakeSecurity(self.directory, self.original)
        self.addCleanup(patch.stopall)
        patch.object(fixture, 'Security', return_value=self.security).start()

    def prepare(self) -> Path:
        return fixture.prepare(self.directory, PASSWORD, 'test-only-account', OWNER)

    def record(self) -> dict:
        return json.loads((self.directory / fixture.RECEIPT).read_text())

    def test_prepare_and_recover_preserve_order_and_retain_only_nonsecret_identity(self) -> None:
        keychain = self.prepare()
        self.assertEqual(self.security.paths, [str(keychain), *self.original])
        text = (self.directory / fixture.RECEIPT).read_text()
        self.assertNotIn(PASSWORD, text)
        self.assertNotIn(fixture.MARKER, text)
        self.assertFalse(self.record()['restored'])
        self.assertTrue(fixture.recover(self.directory, OWNER)['restored'])
        self.assertEqual(self.security.paths, self.original)
        self.assertFalse(keychain.exists())
        self.assertTrue(fixture.recover(self.directory)['restored'])

    def test_empty_original_search_list_restores_without_defaults(self) -> None:
        self.security.paths = []
        self.security.original = []
        self.prepare()
        fixture.recover(self.directory)
        self.assertEqual(self.security.paths, [])

    def test_before_first_intent_interruption_recovers_without_global_mutation(self) -> None:
        for error in (KeyboardInterrupt(), OSError('first intent write failed')):
            with self.subTest(error=type(error).__name__):
                directory = self.root / type(error).__name__
                security = FakeSecurity(directory, self.original)
                with patch.object(fixture, 'Security', return_value=security):
                    with patch.object(fixture, 'save', side_effect=error):
                        with self.assertRaises(type(error)):
                            fixture.prepare(directory, PASSWORD, 'account', OWNER)
                    security.paths.append('/fixture/new-unrelated.keychain-db')
                    current = list(security.paths)
                    result = fixture.recover(directory, OWNER)
                    self.assertTrue(result['restored'])
                    self.assertTrue(result['not_started'])
                    self.assertFalse(result['prepared'])
                    self.assertEqual(security.paths, current)
                    self.assertEqual(security.mutations, [])
                    self.assertFalse((directory / fixture.RECEIPT).exists())

    def test_missing_intent_with_owned_file_or_list_entry_refuses_cleanup(self) -> None:
        with fixture.journal(self.directory, create=True):
            pass  # Simulate interruption before the first receipt.
        keychain = self.directory.resolve() / fixture.KEYCHAIN
        for residue in ('file', 'search-list'):
            with self.subTest(residue=residue):
                if residue == 'file':
                    keychain.write_text('unconfirmed owned keychain')
                else:
                    self.security.paths.append(str(keychain))
                with self.assertRaisesRegex(RuntimeError, 'without restoration intent'):
                    fixture.recover(self.directory)
                self.assertEqual(self.security.mutations, [])
                if residue == 'file':
                    self.assertTrue(keychain.exists())
                    keychain.unlink()
                else:
                    self.assertIn(str(keychain), self.security.paths)

    def test_no_intent_cli_emits_explicit_noop_receipt(self) -> None:
        with fixture.journal(self.directory, create=True):
            pass  # No keychain command or receipt was issued.
        output = io.StringIO()
        with patch.object(fixture.sys, 'argv', ['keychain_fixture.py', 'recover',
                                               '--journal-dir', str(self.directory)]), \
             patch.object(fixture.signal, 'signal'), patch.object(fixture.sys, 'stdout', output):
            fixture.main()
        self.assertEqual(json.loads(output.getvalue()), {
            'schema': 1, 'restored': True, 'prepared': False, 'not_started': True,
            'journal': str(self.directory.resolve()),
        })

    def test_every_prepare_mutation_can_be_recovered_after_interruption(self) -> None:
        for operation in ('create-keychain', 'set-keychain-settings', 'unlock-keychain',
                          'add-generic-password', 'list-keychains'):
            with self.subTest(operation=operation):
                directory = self.root / operation
                security = FakeSecurity(directory, self.original)
                security.interrupt = operation
                with patch.object(fixture, 'Security', return_value=security):
                    with self.assertRaises(KeyboardInterrupt):
                        fixture.prepare(directory, PASSWORD, 'account', OWNER)
                    security.interrupt = None
                    self.assertTrue(fixture.recover(directory)['restored'])
                self.assertEqual(security.paths, self.original)
                self.assertFalse((directory / fixture.KEYCHAIN).exists())

    def test_search_list_drift_is_preserved_without_any_cleanup_mutation(self) -> None:
        keychain = self.prepare()
        for other in (self.original + ['/fixture/new.keychain-db'],
                      self.original[1:], list(reversed(self.original))):
            with self.subTest(other=other):
                self.security.paths = [str(keychain), *other]
                mutations = list(self.security.mutations)
                with self.assertRaisesRegex(RuntimeError, 'Unrelated'):
                    fixture.recover(self.directory)
                self.assertEqual(self.security.paths, [str(keychain), *other])
                self.assertEqual(self.security.mutations, mutations)
                self.assertTrue(keychain.exists())
                self.assertFalse(self.record()['restored'])

    def test_failed_search_list_restore_keeps_keychain_and_false_receipt(self) -> None:
        keychain = self.prepare()
        self.security.ignore_selection = True
        with self.assertRaisesRegex(RuntimeError, 'did not restore'):
            fixture.recover(self.directory)
        self.assertTrue(keychain.exists())
        self.assertNotIn('delete-keychain', self.security.mutations)
        self.assertFalse(self.record()['restored'])

    def test_restore_retries_after_list_change_and_delete_interruptions(self) -> None:
        for operation in ('list-keychains', 'delete-keychain'):
            with self.subTest(operation=operation):
                directory = self.root / ('restore-' + operation)
                security = FakeSecurity(directory, self.original)
                with patch.object(fixture, 'Security', return_value=security):
                    fixture.prepare(directory, PASSWORD, 'account', OWNER)
                    security.interrupt = operation
                    with self.assertRaises(KeyboardInterrupt):
                        fixture.recover(directory)
                    security.interrupt = None
                    self.assertTrue(fixture.recover(directory)['restored'])
                self.assertEqual(security.paths, self.original)

    def test_report_failure_does_not_destroy_recovery_record(self) -> None:
        self.prepare()
        with patch.object(fixture, 'save', side_effect=OSError('full fixture disk')):
            with self.assertRaises(OSError):
                fixture.recover(self.directory)
        self.assertFalse(self.record()['restored'])
        self.assertTrue(fixture.recover(self.directory)['restored'])

    def test_existing_journal_and_wrong_invocation_cannot_restore_another_run(self) -> None:
        self.prepare()
        mutations = list(self.security.mutations)
        with self.assertRaises(FileExistsError):
            self.prepare()
        with self.assertRaisesRegex(RuntimeError, 'identity'):
            fixture.recover(self.directory, 'b' * 32)
        self.assertEqual(self.security.mutations, mutations)

    def test_changed_owned_path_or_symlink_is_not_deleted(self) -> None:
        keychain = self.prepare()
        original = self.record()
        changed = dict(original, keychain='/fixture/unrelated.keychain-db')
        fixture.save(self.directory, changed)
        with self.assertRaisesRegex(RuntimeError, 'identity'):
            fixture.recover(self.directory)
        fixture.save(self.directory, original)
        keychain.unlink()
        untouched = self.root / 'unrelated'
        untouched.write_text('unchanged')
        keychain.symlink_to(untouched)
        with self.assertRaisesRegex(RuntimeError, 'symbolic'):
            fixture.recover(self.directory)
        self.assertEqual(untouched.read_text(), 'unchanged')


class CommandBoundaryTests(unittest.TestCase):
    def test_security_uses_bounded_child_and_inherited_lock_without_error_secrets(self) -> None:
        command = fixture.Security(42)
        with patch.object(fixture.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'list', '')) as run:
            self.assertEqual(command('list-keychains', '-d', 'user'), 'list')
            self.assertEqual(run.call_args.kwargs['pass_fds'], (42,))
            self.assertEqual(run.call_args.kwargs['timeout'], 30)
        for failure in (subprocess.TimeoutExpired(['security', PASSWORD], 30),
                        subprocess.CompletedProcess([], 1, '', PASSWORD)):
            with self.subTest(failure=type(failure).__name__):
                options = {'side_effect': failure} if isinstance(failure, Exception) else {'return_value': failure}
                with patch.object(fixture.subprocess, 'run', **options):
                    with self.assertRaises(RuntimeError) as raised:
                        command('create-keychain', '-p', PASSWORD, '/fixture/keychain')
                    self.assertNotIn(PASSWORD, str(raised.exception))

    def test_inherited_descriptor_blocks_recovery_until_all_holders_close(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'journal'
            with fixture.journal(directory, create=True) as (_, security):
                inherited = os.dup(security.descriptor)
            try:
                with self.assertRaises(BlockingIOError):
                    with fixture.journal(directory):
                        self.fail('Inherited lease was ignored')
            finally:
                os.close(inherited)
            with fixture.journal(directory):
                pass  # The final holder closed; the same journal can be recovered.

    def test_script_cleanup_failure_retains_work_and_propagates_failure(self) -> None:
        script = Path(__file__).with_name('check-compose-build-external-secret.sh').resolve()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / 'python3'
            binary.write_text('#!/bin/sh\nexit "$FIXTURE_STATUS"\n')
            binary.chmod(0o755)
            journal = root / 'journal'
            journal.mkdir()
            for status, present in ((1, True), (0, True), (1, False)):
                selected_journal = journal if present else root / 'missing-journal'
                work = root / ('work-' + str(status) + '-' + str(present))
                work.mkdir()
                result = subprocess.run(
                    ['/bin/bash', '-c', 'source "$1"; WORK_DIR="$2"; KEYCHAIN_JOURNAL_DIR="$3"; '
                     'KEYCHAIN_OWNER=fixture; CONTAINER_COMPOSE=/usr/bin/true; cleanup',
                     '_', str(script), str(work), str(selected_journal)],
                    env={'PATH': str(root) + ':/usr/bin:/bin', 'FIXTURE_STATUS': str(status)},
                    capture_output=True, text=True, timeout=20,
                )
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(work.exists(), status != 0)
                self.assertTrue(journal.exists())


if __name__ == '__main__':
    unittest.main()
