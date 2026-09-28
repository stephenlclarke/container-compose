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

"""No-live checks for source-bound Compose qualification and restoration."""
from __future__ import annotations

from pathlib import Path
import json
import os
import signal
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import qualify_local as local


class QualificationTests(unittest.TestCase):
    def test_parity_keychain_recovery_is_required_before_host_restore(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'full-suite/keychain/build-external-secret'
            directory.mkdir(parents=True)
            journal = directory / 'keychain.json'
            local.write(journal, {'restored': False})
            with patch.object(local, 'recover_command') as command:
                with self.assertRaisesRegex(RuntimeError, 'unconfirmed'):
                    local.restore_parity_keychain(root, (7,))
                command.assert_called_once()
                local.write(journal, {'restored': True})
                local.restore_parity_keychain(root, (7,))
            self.assertEqual(command.call_args.args[2][-3:],
                             ['recover', '--journal-dir', str(directory)])

    def test_keychain_early_intent_requires_explicit_safe_noop_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'full-suite/keychain/build-external-secret'
            directory.mkdir(parents=True)
            with patch.object(local, 'recover_command', return_value=json.dumps({
                    'schema': 1, 'restored': True, 'prepared': False,
                    'not_started': True, 'journal': str(directory.resolve())})) as command:
                local.restore_parity_keychain(root, (7,))
                command.assert_called_once()
            with patch.object(local, 'recover_command', return_value='{}'):
                with self.assertRaisesRegex(RuntimeError, 'unconfirmed'):
                    local.restore_parity_keychain(root, (7,))

    def runtime_lease_fixture(self, root: Path):
        install = root / 'fork/install'
        (install / 'bin').mkdir(parents=True)
        (install / 'bin/container').write_text('original')
        (install / '.runtime-benchmark-owner.json').write_text(json.dumps({
            'owner': 'container-runtime-benchmark', 'lane': 'fork', 'schema': 1}) + '\n')
        archive = root / 'signed.tar.gz'
        archive.write_bytes(b'qualified signed archive')
        original = {'bin/container': local.sha(install / 'bin/container')}
        payload = {'bin/container': local.sha(archive)}
        runtime = SimpleNamespace(own=lambda *_: None)
        def verify(directory, binaries):
            for name, expected in binaries.items():
                self.assertEqual(local.sha(directory / name), expected)
        coverage = SimpleNamespace(require_idle=lambda *_: None, verify_binaries=verify)
        def extract(_archive, destination, _payload):
            (destination / 'bin').mkdir()
            (destination / 'bin/container').write_bytes(archive.read_bytes())
        return install, archive, original, payload, runtime, coverage, extract

    def test_released_runtime_private_swap_restores_original_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install, archive, original, payload, runtime, coverage, extract = self.runtime_lease_fixture(root)
            lease = local.RuntimeArchiveLease(root, install, archive, payload, original)
            lease.acquire(extract, runtime, coverage)
            self.assertEqual((install / 'bin/container').read_bytes(), archive.read_bytes())
            self.assertFalse(json.loads((root / 'install/install.json').read_text())['previous_installation_restored'])
            recovered = local.RuntimeArchiveLease.from_receipt(root, install, archive, payload)
            recovered.restore(coverage)
            recovered.finalize()
            self.assertEqual((install / 'bin/container').read_text(), 'original')
            self.assertTrue(json.loads((root / 'install/install.json').read_text())['previous_installation_restored'])

    def test_interrupted_released_runtime_swap_restores_original(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install, archive, original, payload, runtime, coverage, extract = self.runtime_lease_fixture(root)
            lease = local.RuntimeArchiveLease(root, install, archive, payload, original)
            original_rename = Path.rename
            def interrupted_rename(path, destination):
                if path == lease.stage and destination == install:
                    raise KeyboardInterrupt('after original moved')
                return original_rename(path, destination)
            with patch.object(Path, 'rename', interrupted_rename):
                with self.assertRaises(KeyboardInterrupt):
                    lease.acquire(extract, runtime, coverage)
            self.assertFalse(install.exists())
            recovered = local.RuntimeArchiveLease.from_receipt(root, install, archive, payload)
            recovered.restore(coverage)
            recovered.finalize()
            self.assertEqual((install / 'bin/container').read_text(), 'original')
            self.assertFalse(recovered.stage.exists())
            self.assertFalse(recovered.backup.exists())

    def test_interrupted_released_runtime_deletion_requires_verified_subset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install, archive, original, payload, runtime, coverage, extract = self.runtime_lease_fixture(root)
            lease = local.RuntimeArchiveLease(root, install, archive, payload, original)
            lease.acquire(extract, runtime, coverage)
            original_delete = local.shutil.rmtree
            def interrupted_delete(path):
                if path == lease.retired:
                    (path / 'bin/container').unlink()
                    raise KeyboardInterrupt('partial delete')
                return original_delete(path)
            with patch.object(local.shutil, 'rmtree', side_effect=interrupted_delete):
                with self.assertRaises(KeyboardInterrupt):
                    lease.restore(coverage)
            recovered = local.RuntimeArchiveLease.from_receipt(root, install, archive, payload)
            self.assertTrue(recovered.record['retired_cleanup_authorized'])
            (recovered.retired / 'tampered').write_text('unexpected')
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                recovered.restore(coverage)
            (recovered.retired / 'tampered').unlink()
            recovered.restore(coverage)
            recovered.finalize()
            self.assertEqual((install / 'bin/container').read_text(), 'original')

    def test_predecessor_plugin_survives_both_recovery_phase_windows(self) -> None:
        for phase_complete in (False, True):
            with self.subTest(phase_complete=phase_complete), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                install, archive, original, payload, runtime, coverage, extract = self.runtime_lease_fixture(root)
                prior = install / 'libexec/container-plugins/compose'
                prior.mkdir(parents=True)
                (prior / 'prior.txt').write_text('user plugin')
                runtime_lease = local.RuntimeArchiveLease(root, install, archive, payload, original)
                runtime_lease.acquire(extract, runtime, coverage)
                candidate = root / 'candidate'
                candidate.mkdir()
                (candidate / 'new.txt').write_text('signed plugin')
                signed = {'tree': local.PluginLease.tree(candidate)}
                plugin_lease = local.PluginLease(root, install, signed, original,
                                                 combined_runtime=True)
                plugin_lease.acquire(candidate)
                plugin_lease.restore()
                original_rename = Path.rename
                def interrupted_rename(path, destination):
                    result = original_rename(path, destination)
                    if not phase_complete and path == runtime_lease.backup and destination == install:
                        raise KeyboardInterrupt('after predecessor restored, before phase')
                    return result
                if phase_complete:
                    runtime_lease.restore(coverage)
                else:
                    with patch.object(Path, 'rename', interrupted_rename):
                        with self.assertRaises(KeyboardInterrupt):
                            runtime_lease.restore(coverage)
                recovered_runtime = local.RuntimeArchiveLease.from_receipt(
                    root, install, archive, payload)
                recovered_plugin = local.PluginLease.from_receipt(root, install, signed)
                self.assertTrue(recovered_runtime.predecessor_present())
                local.recover_plugin_lease(recovered_plugin,
                                           predecessor_present=True,
                                           phase_complete=phase_complete)
                recovered_runtime.restore(coverage)
                recovered_runtime.finalize()
                self.assertEqual((prior / 'prior.txt').read_text(), 'user plugin')
                self.assertFalse((prior / 'new.txt').exists())

    def test_cheap_source_preflight_precedes_bazel_layers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(local, 'STAGES', ()), \
             patch.object(local, 'stage', return_value={'name': 'source-preflight'}) as run, \
             patch.object(local, 'fetch_q_assets', return_value={
                 'provenance': {'source_receipt_sha256': {}},
                 'assets': {name: {'sha256': 'same'} for name in ('runtime', 'guest', 'builder')}}), \
             patch.object(local, 'sha', return_value='receipt-hash'), \
             patch.object(local, 'source_identity', return_value={'source': 'same'}), \
             patch.object(local, 'verify_source'):
            local.write(Path(temporary) / 'preflight.json', {'container': {
                'source_receipt_sha256': {}, 'release_sha256': 'same',
                'guest_sha256': 'same', 'builder_sha256': 'same'}})
            with self.assertRaisesRegex(RuntimeError, 'No candidate package'):
                local.run_layers(Path(temporary), {'source': 'same'}, {'hashes': {}})
        args, kwargs = run.call_args_list[0]
        self.assertEqual(args[1:3], ('source-preflight',
                                    ['make', '--no-print-directory', 'source-preflight']))
        self.assertEqual(kwargs['env']['CONTAINER_STACK_REPO'], str(local.Q_ROOT))
        self.assertEqual(run.call_args_list[1].args[1:3],
                         ('workflow-tools', ['make', '--no-print-directory',
                                             'bazel-workflow-tools-test']))

    def test_release_bound_documentation_and_package_commands(self) -> None:
        for name, target in (('docs', '//:documentation_tests'),
                             ('package', '//:candidate_archive'),
                             ('package-smoke', '//Tools/bazel:package_smoke')):
            command = local.layer_command(name, 'test' if name != 'package' else 'build',
                                          target, 'enhanced')
            self.assertIn('--config=release', command)
            if name in {'package', 'package-smoke'}:
                self.assertIn('--config=prebuilt-container-sdk', command)
            else:
                self.assertNotIn('--config=prebuilt-container-sdk', command)
        self.assertNotIn('--config=release', local.layer_command(
            'unit-stock', 'test', '//:unit_stock', 'stock'))

    def test_fixture_budget_and_matched_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'fixture.yml'
            local.fixture(path, 3, 'example.invalid/alpine@sha256:' + 'a' * 64)
            value = path.read_text()
            self.assertEqual(value.count('mem_limit: 128m'), 3)
            self.assertEqual(value.count('network_mode: none'), 3)
            with self.assertRaises(ValueError):
                local.fixture(path, 50, 'example.invalid/alpine')
        rows = [{'fixture': f'{count}-services-{operation}', 'lane': lane,
                 'trial': trial, 'seconds': 2 if lane == 'candidate' else 1}
                for count in (1, 3) for operation in ('up', 'down')
                for lane in ('candidate', 'docker') for trial in range(1, 8)]
        with tempfile.TemporaryDirectory() as temporary:
            compared = local.compare(rows, Path(temporary))
            self.assertTrue(all(x['passed'] for x in compared.values()))
            self.assertEqual(compared['3-services-up']['lanes']['candidate']['p95_seconds'], 2)
            self.assertIn('P95', (Path(temporary) / 'performance-comparison.md').read_text())
            self.assertTrue((Path(temporary) / 'performance-junit.xml').is_file())
        for row in rows:
            if row['lane'] == 'candidate' and row['fixture'] == '3-services-up':
                row['seconds'] = 10
        with self.assertRaisesRegex(RuntimeError, '10x'):
            local.compare(rows)

    def test_private_plugin_restores_original_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            parent = root / 'install/libexec/container-plugins'
            old = parent / 'compose'
            old.mkdir(parents=True)
            (old / 'config.toml').write_text('original')
            candidate = root / 'candidate'
            (candidate / 'bin').mkdir(parents=True)
            (candidate / 'resources').mkdir()
            (candidate / 'bin/compose').write_text('signed-cli')
            (candidate / 'resources/compose-normalizer').write_text('signed-helper')
            signed = {'payload': {name: local.sha(candidate / name)
                                  for name in ('bin/compose', 'resources/compose-normalizer')},
                      'tree': local.PluginLease.tree(candidate)}
            lease = local.PluginLease(root, root / 'install', signed, {'bin/container': 'q-sha'})
            lease.acquire(candidate)
            self.assertEqual((old / 'bin/compose').read_text(), 'signed-cli')
            self.assertFalse(json.loads((root / 'install/install.json').read_text())['previous_installation_restored'])
            local.PluginLease.from_receipt(root, root / 'install', signed).restore()
            self.assertEqual((old / 'config.toml').read_text(), 'original')
            self.assertFalse((old / 'bin/compose').exists())
            self.assertTrue((root / 'plugin-lease.json').is_file())
            self.assertFalse(json.loads((root / 'install/install.json').read_text())['previous_installation_restored'])
            recovered = local.PluginLease.from_receipt(root, root / 'install', signed)
            fixture = root / 'fixture.yml'
            fixture.write_text('services: {}\n')
            ledger = local.ProjectLedger(root)
            ledger.begin('cfq123-1-1-docker', 'docker', fixture)
            with self.assertRaisesRegex(RuntimeError, 'not fully restored'):
                recovered.finalize(ledger, runtime_idle=True,
                                   colima_restored=True, stock_restored=True)
            self.assertFalse(json.loads((root / 'install/install.json').read_text())['previous_installation_restored'])
            ledger.finished('cfq123-1-1-docker')
            recovered.finalize(ledger, runtime_idle=True,
                               colima_restored=True, stock_restored=True)
            self.assertTrue(json.loads((root / 'install/install.json').read_text())['previous_installation_restored'])

    def test_private_plugin_mutation_preserves_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / 'candidate'
            (candidate / 'bin').mkdir(parents=True)
            (candidate / 'bin/compose').write_text('signed-cli')
            signed = {'payload': {'bin/compose': local.sha(candidate / 'bin/compose')},
                      'tree': local.PluginLease.tree(candidate)}
            lease = local.PluginLease(root, root / 'install', signed, {'bin/container': 'q-sha'})
            lease.acquire(candidate)
            (lease.target / 'bin/compose').write_text('changed')
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                lease.restore()
            self.assertFalse(lease.record['restored'])

    def test_interrupted_swap_restores_original(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / 'candidate'
            (candidate / 'bin').mkdir(parents=True)
            (candidate / 'bin/compose').write_text('signed-cli')
            old = root / 'install/libexec/container-plugins/compose'
            old.mkdir(parents=True)
            (old / 'config.toml').write_text('original')
            signed = {'payload': {'bin/compose': local.sha(candidate / 'bin/compose')},
                      'tree': local.PluginLease.tree(candidate)}
            lease = local.PluginLease(root, root / 'install', signed, {'bin/container': 'q-sha'})
            lease.stage.parent.mkdir(parents=True, exist_ok=True)
            import shutil
            shutil.copytree(candidate, lease.stage)
            lease.record.update(started=True, original=lease.tree(old))
            local.write(root / 'plugin-lease.json', lease.record)
            lease.installation_receipt(False)
            lease.restore()  # Journal persisted, but the original rename never happened.
            self.assertEqual((old / 'config.toml').read_text(), 'original')
            self.assertFalse(lease.stage.exists())

    def test_running_colima_cannot_hide_failed_owned_down(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / '1.yml'
            fixture.write_text('services: {}\n')
            ledger = local.ProjectLedger(root)
            ledger.begin('cfq123-1-1-docker', 'docker', fixture)
            class ExistingColima:
                started_by_this_run = False
                restored = False
                def restore(self):
                    self.restored = True  # Mirrors Q's no-op for a pre-running profile.
            colima = ExistingColima()
            with self.assertRaisesRegex(RuntimeError, 'projects remain'):
                local.restore_colima_after_projects(colima, ledger)
            self.assertFalse(colima.restored)
            ledger.finished('cfq123-1-1-docker')
            local.restore_colima_after_projects(colima, ledger)
            self.assertTrue(colima.restored)

    def test_recovery_finishes_interrupted_plugin_restoration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            old = root / 'install/libexec/container-plugins/compose'
            old.mkdir(parents=True)
            (old / 'config.toml').write_text('original')
            candidate = root / 'candidate'
            (candidate / 'bin').mkdir(parents=True)
            (candidate / 'bin/compose').write_text('signed')
            signed = {'payload': {'bin/compose': local.sha(candidate / 'bin/compose')},
                      'tree': local.PluginLease.tree(candidate)}
            lease = local.PluginLease(root, root / 'install', signed, {'bin/container': 'q-sha'})
            lease.acquire(candidate)
            lease.target.rename(lease.retired)
            lease.backup.rename(lease.target)
            local.PluginLease.from_receipt(root, root / 'install', signed).restore()
            self.assertEqual((old / 'config.toml').read_text(), 'original')
            self.assertFalse(lease.retired.exists())
            self.assertFalse(json.loads((root / 'install/install.json').read_text())['previous_installation_restored'])
            recovered = local.PluginLease.from_receipt(root, root / 'install', signed)
            recovered.finalize(local.ProjectLedger(root), runtime_idle=True,
                               colima_restored=True, stock_restored=True)
            self.assertTrue(json.loads((root / 'install/install.json').read_text())['previous_installation_restored'])

    def test_retired_candidate_deletion_resumes_only_verified_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / 'candidate'
            (candidate / 'bin').mkdir(parents=True)
            (candidate / 'bin/compose').write_text('signed')
            (candidate / 'notice').write_text('signed notice')
            old = root / 'install/libexec/container-plugins/compose'
            old.mkdir(parents=True)
            (old / 'config.toml').write_text('original')
            signed = {'tree': local.PluginLease.tree(candidate)}
            lease = local.PluginLease(root, root / 'install', signed, {'bin/container': 'q-sha'})
            lease.acquire(candidate)
            original_delete = local.shutil.rmtree
            def partial_delete(path):
                if path == lease.retired:
                    (path / 'notice').unlink()
                    raise KeyboardInterrupt()
                return original_delete(path)
            with patch.object(local.shutil, 'rmtree', side_effect=partial_delete):
                with self.assertRaises(KeyboardInterrupt):
                    lease.restore()
            self.assertTrue(json.loads((root / 'plugin-lease.json').read_text())['retired_cleanup_authorized'])
            resumed = local.PluginLease.from_receipt(root, root / 'install', signed)
            resumed.restore()
            self.assertEqual((old / 'config.toml').read_text(), 'original')
            self.assertFalse(lease.retired.exists())

    def test_staged_candidate_deletion_resumes_only_verified_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / 'candidate'
            (candidate / 'bin').mkdir(parents=True)
            (candidate / 'bin/compose').write_text('signed')
            (candidate / 'notice').write_text('signed notice')
            old = root / 'install/libexec/container-plugins/compose'
            old.mkdir(parents=True)
            (old / 'config.toml').write_text('original')
            signed = {'tree': local.PluginLease.tree(candidate)}
            lease = local.PluginLease(root, root / 'install', signed, {'bin/container': 'q-sha'})
            lease.parent.mkdir(parents=True, exist_ok=True)
            local.shutil.copytree(candidate, lease.stage)
            lease.record.update(started=True, original=lease.tree(old))
            local.write(root / 'plugin-lease.json', lease.record)
            lease.installation_receipt(False)
            original_delete = local.shutil.rmtree
            def partial_delete(path):
                if path == lease.stage:
                    (path / 'notice').unlink()
                    raise KeyboardInterrupt()
                return original_delete(path)
            with patch.object(local.shutil, 'rmtree', side_effect=partial_delete):
                with self.assertRaises(KeyboardInterrupt):
                    lease.restore()
            self.assertTrue(json.loads((root / 'plugin-lease.json').read_text())['stage_cleanup_authorized'])
            resumed = local.PluginLease.from_receipt(root, root / 'install', signed)
            resumed.restore()
            self.assertEqual((old / 'config.toml').read_text(), 'original')
            self.assertFalse(lease.stage.exists())

    def test_project_clearance_resume_after_plugin_and_runtime_restored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'fixtures').mkdir()
            fixture = root / 'fixtures/1.yml'
            fixture.write_text('services: {}\n')
            local.write(root / 'signed-candidate.json', {'source': 'a' * 40})
            (root / 'q-assets').mkdir()
            local.write(root / 'q-assets/q-assets.json', {'schema': 1})
            ledger = local.ProjectLedger(root)
            ledger.begin('cfq123-1-1-candidate', 'candidate', fixture)
            ledger.finished('cfq123-1-1-candidate')
            q = {'hashes': {'runtime_benchmark.py': 'h'}, 'modules': {}}
            lock = root / 'commands.lock'
            with patch.object(local, 'recover_projects') as projects:
                local.ensure_projects_cleared(root, ledger, q, (7,), lock, allow_existing=False)
                projects.assert_called_once()
            local.ensure_full_suite_cleared(root, q, (7,), lock, allow_existing=False)
            with patch.object(local.full_suite, 'snapshot',
                              side_effect=AssertionError('removed candidate CLI')):
                local.ensure_full_suite_cleared(root, q, (7,), lock,
                                                allow_existing=True)
            phases = local.CleanupPhases(root, ledger, q, lock)
            for name in ('full_suite', 'projects', 'runtime', 'plugin', 'private_install'):
                phases.mark(name)
            # The candidate CLI and API may be gone here. Recovery must use the
            # durable exclusive-lease proof, then continue with Colima/stock.
            with patch.object(local, 'recover_projects', side_effect=AssertionError('stopped API')):
                local.ensure_projects_cleared(root, local.ProjectLedger(root), q, (7,), lock,
                                              allow_existing=True)
            resumed = local.CleanupPhases(root, local.ProjectLedger(root), q, lock)
            self.assertEqual(resumed.completed, ['full_suite', 'projects', 'runtime', 'plugin',
                                                 'private_install'])
            resumed.mark('colima')
            resumed.mark('stock')
            ledger.reactivate('cfq123-1-1-candidate')
            with self.assertRaisesRegex(RuntimeError, 'incompatible'):
                local.ensure_projects_cleared(root, ledger, q, (7,), lock, allow_existing=True)

    def test_cleanup_phase_identity_binds_only_cleared_ledgers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local.write(root / 'signed-candidate.json', {'source': 'a' * 40})
            (root / 'q-assets').mkdir()
            local.write(root / 'q-assets/q-assets.json', {'schema': 1})
            q = {'hashes': {'runtime_benchmark.py': 'h'}, 'modules': {}}
            lock = root / 'commands.lock'
            projects = local.ProjectLedger(root)
            self.assertFalse(projects.path.exists())
            local.ensure_full_suite_cleared(root, q, (7,), lock, allow_existing=False)
            with patch.object(local, 'recover_projects'):
                local.ensure_projects_cleared(root, projects, q, (7,), lock,
                                              allow_existing=False)
            phases = local.CleanupPhases(root, projects, q, lock)
            phases.mark('full_suite')
            phases.mark('projects')
            self.assertEqual(local.CleanupPhases(root, local.ProjectLedger(root), q,
                                                 lock).completed,
                             ['full_suite', 'projects'])

    def test_cleanup_phase_identity_uses_project_ledger_after_active_restoration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'fixtures').mkdir()
            fixture = root / 'fixtures/1.yml'
            fixture.write_text('services: {}\n')
            local.write(root / 'signed-candidate.json', {'source': 'a' * 40})
            (root / 'q-assets').mkdir()
            local.write(root / 'q-assets/q-assets.json', {'schema': 1})
            q = {'hashes': {'runtime_benchmark.py': 'h'}, 'modules': {}}
            lock = root / 'commands.lock'
            projects = local.ProjectLedger(root)
            projects.begin('cfq123-1-1-candidate', 'candidate', fixture)
            before = local.sha(projects.path)
            local.ensure_full_suite_cleared(root, q, (7,), lock, allow_existing=False)
            with patch.object(local, 'recover_projects',
                              side_effect=lambda _e, ledger, _q, _d:
                              ledger.finished('cfq123-1-1-candidate')):
                local.ensure_projects_cleared(root, projects, q, (7,), lock,
                                              allow_existing=False)
            self.assertNotEqual(local.sha(projects.path), before)
            phases = local.CleanupPhases(root, projects, q, lock)
            phases.mark('full_suite')
            phases.mark('projects')
            self.assertEqual(local.CleanupPhases(root, local.ProjectLedger(root), q,
                                                 lock).completed,
                             ['full_suite', 'projects'])

    def test_failed_inactive_project_recheck_does_not_clear_projects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / 'fixture.yml'
            fixture.write_text('services: {}\n')
            ledger = local.ProjectLedger(root)
            ledger.begin('cfq123-1-1-candidate', 'candidate', fixture)
            ledger.finished('cfq123-1-1-candidate')
            with patch.object(local, 'recover_projects', side_effect=RuntimeError('API unavailable')):
                with self.assertRaisesRegex(RuntimeError, 'API unavailable'):
                    local.ensure_projects_cleared(root, ledger, {}, (7,), root / 'commands.lock',
                                                  allow_existing=False)
            self.assertFalse((root / 'projects-cleared.json').exists())

    def test_unswapped_plugin_intent_can_be_closed_only_without_owned_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install = root / 'install'
            (install / 'libexec').mkdir(parents=True)
            (root / 'runtime').mkdir()
            local.write(root / 'runtime/fork-fingerprint.json', {'binaries': {'bin/container': 'q-sha'}})
            local.write(root / 'install/install.json', {'scope': 'compose-private-plugin',
                        'previous_installation_restored': False,
                        'original_binaries': {'bin/container': 'q-sha'}})
            coverage = SimpleNamespace(verify_binaries=lambda *_: None)
            owned = install / 'libexec/.compose-qualification-stage-test'
            owned.mkdir()
            with self.assertRaisesRegex(RuntimeError, 'cannot be verified'):
                local.finalize_unswapped_plugin_intent(root, install, coverage)
            owned.rmdir()
            local.finalize_unswapped_plugin_intent(root, install, coverage)
            self.assertTrue(json.loads((root / 'install/install.json').read_text())['previous_installation_restored'])

    def test_exclusive_cleanup_rechecks_previously_finished_projects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'fixtures').mkdir()
            fixture = root / 'fixtures/1.yml'
            fixture.write_text('services: {}\n')
            ledger = local.ProjectLedger(root)
            ledger.begin('cfq123-1-1-candidate', 'candidate', fixture)
            ledger.finished('cfq123-1-1-candidate')
            runtime = SimpleNamespace(INSTALLS=root / 'install', environment=lambda lane: {})
            def command(_evidence, name, *_args):
                return 'recreated-id\n' if name.endswith('-precheck') else ''
            with patch.object(local, 'recover_command', side_effect=command):
                with self.assertRaisesRegex(RuntimeError, 'reappeared'):
                    local.recover_projects(root, ledger, {'modules': {'runtime_benchmark': runtime}}, (7,))
            self.assertFalse(ledger.active())

    def test_interrupted_recovery_command_reaps_owned_child(self) -> None:
        class Child:
            pid = 12345
            waits = 0
            def wait(self, timeout):
                self.waits += 1
                if self.waits == 1:
                    raise KeyboardInterrupt()
                return 143
            def poll(self):
                return None
        child = Child()
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(local.subprocess, 'Popen', return_value=child), \
             patch.object(local.os, 'killpg') as kill:
            with self.assertRaises(KeyboardInterrupt):
                local.recover_command(Path(temporary), 'interrupted', ['true'], {}, (7,), 30)
            kill.assert_called_once_with(child.pid, signal.SIGTERM)
            self.assertEqual(child.waits, 2)

    def test_recovery_report_failure_still_closes_shared_locks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            storage = root / 'storage'
            installs = root / 'installs'
            storage.mkdir()
            installs.mkdir()
            modules = {'fork_benchmark': SimpleNamespace(STORAGE=storage),
                       'runtime_benchmark': SimpleNamespace(INSTALLS=installs),
                       'host_lease': SimpleNamespace(LOCK=root / 'host.lock', JOURNAL=root / 'missing.json')}
            closed = []
            original_close = os.close
            def close(fd):
                closed.append(fd)
                original_close(fd)
            with patch.object(local, 'q_modules', return_value={'modules': modules, 'hashes': {}}), \
                 patch.object(local, 'revalidate_q_assets', return_value={}), \
                 patch.object(local, 'write', side_effect=OSError('disk full')), \
                 patch.object(local.os, 'close', side_effect=close):
                result = local.recover(root)
            self.assertFalse(result['restored'])
            self.assertEqual(len(closed), 3)


if __name__ == '__main__':
    unittest.main()
