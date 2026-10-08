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
import hashlib
import os
import signal
import sys
import tempfile
import unittest
import zipfile
from types import SimpleNamespace
from unittest.mock import patch

import qualify_local as local
import q_assets


class QualificationTests(unittest.TestCase):
    def test_docker_buildx_identity_uses_selected_context_and_hashes_plugin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'docker-buildx'
            binary.write_bytes(b'selected buildx plugin')
            binary.chmod(0o755)
            expected_sha256 = local.sha(binary)
            environment = {'DOCKER_CONFIG': '/private/selected/docker-config',
                           'DOCKER_CONTEXT': 'colima'}
            outputs = iter((
                'github.com/docker/buildx v0.37.1 1234567890abcdef\n',
                json.dumps([{'Name': 'buildx', 'Path': str(binary),
                             'Version': 'v0.37.1'}]),
            ))
            with patch.object(local.subprocess, 'check_output',
                              side_effect=lambda *args, **kwargs: next(outputs)) as check:
                identity = local.docker_buildx_identity(environment)

        self.assertEqual(identity['context'], 'colima')
        self.assertEqual(identity['plugin_version'], 'v0.37.1')
        self.assertEqual(identity['version_output'],
                         'github.com/docker/buildx v0.37.1 1234567890abcdef')
        self.assertEqual(identity['binary_sha256'], expected_sha256)
        self.assertEqual(check.call_count, 2)
        self.assertTrue(all(call.kwargs['env'] is environment for call in check.call_args_list))
        self.assertEqual(check.call_args_list[0].args[0],
                         ['docker', '--context', 'colima', 'buildx', 'version'])

    def test_docker_buildx_identity_rejects_missing_selected_plugin(self) -> None:
        outputs = iter((
            'github.com/docker/buildx v0.37.1 1234567890abcdef\n',
            json.dumps([{'Name': 'compose', 'Path': '/docker/cli-plugins/docker-compose',
                         'Version': 'v5.5.1'}]),
        ))
        with patch.object(local.subprocess, 'check_output',
                          side_effect=lambda *args, **kwargs: next(outputs)):
            with self.assertRaisesRegex(RuntimeError, 'Buildx plugin is unavailable'):
                local.docker_buildx_identity({'DOCKER_CONFIG': '/private/selected/config'})

    def make_q_recovery_fixture(self, root: Path) -> tuple[Path, Path, dict]:
        container_root = root / 'container'
        q_evidence = root / 'q-evidence'
        installs = root / 'installs'
        container_root.mkdir()
        q_evidence.mkdir()
        (q_evidence / 'runtime-smoke').mkdir()
        (q_evidence / 'release').mkdir()
        (installs / 'fork/install/bin').mkdir(parents=True)
        (installs / 'fork/install/bin/container').write_text('displaced runtime')
        local.write(q_evidence / 'acceptance.json', {'passed': True, 'target': 'bazel-qualify'})
        local.write(q_evidence / 'runtime-smoke/acceptance.json', {'passed': True})
        local.write(q_evidence / 'runtime-smoke/fork-fingerprint.json', {
            'workspace': str(container_root), 'binaries': {'bin/container': '0' * 64}})
        for name in ('guest', 'builder'):
            local.write(q_evidence / f'runtime-smoke/{name}-artifact.json', {
                'archive_sha256': ('1' if name == 'guest' else '2') * 64})
        local.write(q_evidence / 'release/release-artifact.json', {
            'passed': True, 'source': local.Q,
            'archives': {'container-homebrew-arm64.tar.gz': '3' * 64}})
        q = {'modules': {'runtime_benchmark': SimpleNamespace(INSTALLS=installs)},
             'hashes': {'runtime_benchmark.py': '4' * 64}}
        return container_root, q_evidence, q

    def admit_q_recovery_fixture(self, container_root: Path, q_evidence: Path,
                                 q: dict, evidence: Path) -> None:
        with patch.object(local, 'Q_ROOT', container_root), \
             patch.object(local, 'Q_EVIDENCE', q_evidence):
            admitted = local.validate_q(q, verify_install=False)
        local.write(evidence / 'preflight.json', {'ready': True, 'container': admitted})

    def test_validate_q_keeps_released_five_receipt_contract_and_binds_runtime_acceptance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            container_root, q_evidence, q = self.make_q_recovery_fixture(root)
            with patch.object(local, 'Q_ROOT', container_root), \
                 patch.object(local, 'Q_EVIDENCE', q_evidence):
                admitted = local.validate_q(q, verify_install=False)
            self.assertEqual(set(admitted['source_receipt_sha256']), q_assets.RECEIPTS)
            runtime_acceptance = (q_evidence / 'runtime-smoke/acceptance.json').read_bytes()
            self.assertEqual(admitted['runtime_acceptance_sha256'],
                             hashlib.sha256(runtime_acceptance).hexdigest())
            fingerprint = (q_evidence / 'runtime-smoke/fork-fingerprint.json').read_bytes()
            self.assertEqual(admitted['runtime_fingerprint_sha256'],
                             hashlib.sha256(fingerprint).hexdigest())

    def test_recovery_admission_rejects_unbound_q_receipts_before_any_action(self) -> None:
        for failure in ('empty-preflight', 'changed-receipt', 'symlink-child'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                evidence = root / 'evidence'
                evidence.mkdir()
                container_root, q_evidence, q = self.make_q_recovery_fixture(root)
                self.admit_q_recovery_fixture(container_root, q_evidence, q, evidence)
                if failure == 'empty-preflight':
                    local.write(evidence / 'preflight.json', {'ready': True})
                elif failure == 'changed-receipt':
                    local.write(q_evidence / 'acceptance.json', {
                        'passed': True, 'target': 'bazel-qualify', 'unexpected': True})
                else:
                    outside = root / 'acceptance.json'
                    outside.write_bytes((q_evidence / 'acceptance.json').read_bytes())
                    (q_evidence / 'acceptance.json').unlink()
                    (q_evidence / 'acceptance.json').symlink_to(outside)
                modules = {
                    'fork_benchmark': SimpleNamespace(STORAGE=root / 'storage'),
                    'runtime_benchmark': q['modules']['runtime_benchmark'],
                    'host_lease': SimpleNamespace(LOCK=root / 'host.lock',
                                                  JOURNAL=root / 'host.journal')}
                (root / 'storage').mkdir()
                q['modules'].update(modules)
                with patch.object(local, 'Q_ROOT', container_root), \
                     patch.object(local, 'Q_EVIDENCE', q_evidence), \
                     patch.object(local, 'q_modules', return_value=q), \
                     patch.object(local, 'revalidate_q_assets') as asset_admission:
                    with self.assertRaises(RuntimeError):
                        local.recover(evidence)
                asset_admission.assert_not_called()
                self.assertFalse((root / 'storage/qualification.lock').exists())
                self.assertFalse((root / 'host.lock').exists())

    def test_recovery_admits_matching_q_receipts_after_private_install_displacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            container_root, q_evidence, q = self.make_q_recovery_fixture(root)
            self.admit_q_recovery_fixture(container_root, q_evidence, q, evidence)
            storage = root / 'storage'
            storage.mkdir()
            q['modules'].update({
                'fork_benchmark': SimpleNamespace(STORAGE=storage),
                'host_lease': SimpleNamespace(LOCK=root / 'host.lock',
                                              JOURNAL=root / 'host.journal')})
            with patch.object(local, 'Q_ROOT', container_root), \
                 patch.object(local, 'Q_EVIDENCE', q_evidence), \
                 patch.object(local, 'q_modules', return_value=q), \
                 patch.object(local, 'revalidate_q_assets', return_value={}):
                result = local.recover(evidence)
            self.assertTrue(result['restored'])
            self.assertTrue((root / 'host.lock').is_file())
            self.assertEqual((q['modules']['runtime_benchmark'].INSTALLS /
                              'fork/install/bin/container').read_text(), 'displaced runtime')

    def test_reference_recovery_rejects_changed_q_receipt_before_lock_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            container_root, q_evidence, q = self.make_q_recovery_fixture(root)
            with patch.object(local, 'Q_ROOT', container_root), \
                 patch.object(local, 'Q_EVIDENCE', q_evidence):
                admitted = local.validate_q(q, verify_install=False)
            local.write(evidence / 'reference-preflight.json', {
                'ready': True, 'qualified_runtime': local.Q, 'container': admitted})
            local.write(q_evidence / 'release/release-artifact.json', {
                'passed': True, 'source': local.Q,
                'archives': {'container-homebrew-arm64.tar.gz': '4' * 64}})
            with patch.object(local, 'Q_ROOT', container_root), \
                 patch.object(local, 'Q_EVIDENCE', q_evidence), \
                 patch.object(local, 'q_modules', return_value=q):
                with self.assertRaisesRegex(RuntimeError, 'differs from the original'):
                    local.recover_reference(evidence)
            self.assertFalse((root / 'fork.lock').exists())
            self.assertFalse((root / 'host.lock').exists())

    def test_fixture_cache_directory_tracks_exact_runtime_source_pins(self) -> None:
        self.assertEqual(local.FIXTURE_CACHE.name,
                         f'fixture-image-cache-q{local.Q[:8]}-c{local.CONTAINERIZATION[:4]}')

    def test_candidate_benchmark_environment_pins_private_cli_without_changing_measured_progress(self) -> None:
        install = Path('/private/qualified/install')
        runtime = SimpleNamespace(environment=lambda lane: {
            'PATH': '/host/older/bin', 'COMPOSE_PROGRESS': 'plain',
            'CONTAINER_COMPOSE_CONTAINER': '/host/older/bin/container',
            'CONTAINER_BIN': '/host/older/bin/container'})
        poisoned = {'CONTAINER_COMPOSE_CONTAINER': '/another/container',
                    'CONTAINER_BIN': '/another/container'}
        for operation in ('up', 'down'):
            environment = local.benchmark_issue_environment(
                'candidate', '1-services-' + operation, runtime, install, poisoned)
            self.assertEqual(environment['CONTAINER_COMPOSE_CONTAINER'],
                             str(install / 'bin/container'))
            self.assertEqual(environment['CONTAINER_BIN'], str(install / 'bin/container'))
            self.assertEqual(environment['COMPOSE_PROGRESS'], 'plain')
            self.assertEqual(environment['PATH'], '/host/older/bin')
        for operation in ('ps', 'absent'):
            environment = local.benchmark_issue_environment(
                'candidate', '1-services-' + operation, runtime, install, poisoned)
            self.assertEqual(environment['CONTAINER_COMPOSE_CONTAINER'],
                             str(install / 'bin/container'))
            self.assertEqual(environment['COMPOSE_PROGRESS'], 'quiet')
        with patch.dict(os.environ, {'PATH': '/docker/path'}, clear=True):
            environment = local.benchmark_issue_environment(
                'docker', '1-services-up', runtime, install, {'LOCK': 'owned'})
        self.assertEqual(environment, {'PATH': '/docker/path', 'LOCK': 'owned'})

    def test_owned_project_recovery_pins_private_cli_and_quiets_only_observation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'fixtures').mkdir()
            fixture = root / 'fixtures/1.yml'
            fixture.write_text('services: {}\n')
            ledger = local.ProjectLedger(root)
            ledger.begin('cfq123-1-0-candidate', 'candidate', fixture)
            runtime = SimpleNamespace(INSTALLS=root / 'runtime', environment=lambda lane: {
                'PATH': '/host/older/bin', 'COMPOSE_PROGRESS': 'plain',
                'CONTAINER_COMPOSE_CONTAINER': '/host/older/bin/container'})
            calls = []
            def command(_evidence, name, args, environment, *_rest):
                calls.append((name, args, environment))
                return ''
            with patch.object(local, 'recover_command', side_effect=command):
                local.recover_projects(root, ledger, {'modules': {'runtime_benchmark': runtime}}, (7,))
            self.assertFalse(ledger.active())
            self.assertEqual([name.rsplit('-', 1)[-1] for name, *_ in calls], ['down', 'ps'])
            for name, args, environment in calls:
                self.assertEqual(environment['CONTAINER_COMPOSE_CONTAINER'],
                                 str(root / 'runtime/fork/install/bin/container'))
                self.assertEqual(environment['CONTAINER_BIN'],
                                 str(root / 'runtime/fork/install/bin/container'))
                self.assertEqual(args[0], str(root / 'runtime/fork/install/bin/container'))
                self.assertEqual(environment['COMPOSE_PROGRESS'],
                                 'quiet' if name.endswith('-ps') else 'plain')

    def test_fixture_app_allows_cold_state_but_checks_parent_before_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            state = base / 'state'
            retained = base / 'retained'
            retained.mkdir()
            calls = []
            def own(path, lane):
                calls.append((path, lane))
                path.mkdir(parents=True, exist_ok=True)
            runtime = SimpleNamespace(own=own)
            app = local._checked_fixture_app(runtime, state, retained, require_app=False)
            self.assertEqual(app, state / 'fork/app')
            self.assertEqual(calls, [(state / 'fork', 'fork')])
            with self.assertRaisesRegex(RuntimeError, 'app changed'):
                local._checked_fixture_app(runtime, state, retained, require_app=True)
            app.mkdir()
            self.assertEqual(local._checked_fixture_app(runtime, state, retained,
                                                        require_app=True), app)
            (base / 'linked-state').symlink_to(state, target_is_directory=True)
            calls.clear()
            with self.assertRaisesRegex(RuntimeError, 'directory changed'):
                local._checked_fixture_app(runtime, base / 'linked-state', retained,
                                           require_app=False)
            self.assertEqual(calls, [])

    def test_runtime_summary_accepts_real_swift_testing_suite_wording(self) -> None:
        for summary in ('✔ Test run with 27 tests in 2 suites passed after 0.364 seconds.',
                        '✔ Test run with 27 tests passed after 10.52 seconds.'):
            local.require_runtime_test_summary('◇ Test run started.\n' + summary + '\n')

    def test_runtime_summary_rejects_zero_wrong_or_malformed_counts(self) -> None:
        for summary in ('✔ Test run with 1 test in 1 suite passed after 0.354 seconds.',
                        '✔ Test run with 0 tests in 2 suites passed after 1.0 seconds.',
                        '✔ Test run with 26 tests in 2 suites passed after 1.0 seconds.',
                        '✔ Test run with 27 tests in 0 suites passed after 1.0 seconds.',
                        '✔ Test run with 27 tests in 2 suites failed after 1.0 seconds.',
                        'Test run with 27 tests in 2 suites passed',
                        '✔ Test run with 27 tests in 2 suites passed after 1.0 seconds.\n'
                        '✔ Test run with 26 tests in 2 suites passed after 2.0 seconds.'):
            with self.subTest(summary=summary), self.assertRaisesRegex(RuntimeError, '27 passing'):
                local.require_runtime_test_summary(summary)

    def test_original_fixture_preload_admits_existing_tags_without_refresh(self) -> None:
        runtime_source = (local.ROOT / 'Tests/ComposeRuntimeTests/ComposeRuntimeSmokeTests.swift').read_text()
        rm_source = (local.ROOT / 'Tools/parity/check-compose-rm.sh').read_text()
        self.assertIn('FROM ghcr.io/linuxcontainers/alpine:3.20', runtime_source)
        self.assertIn('image: alpine:3.20', runtime_source)
        self.assertIn('image: busybox:latest', rm_source)
        lifecycle_fixture = (local.ROOT / 'Tools/parity/fixtures/lifecycle-hooks/compose.yaml')
        self.assertIn('image: alpine:3.21', lifecycle_fixture.read_text())
        bridge_source = (local.ROOT / 'Tools/parity/check-compose-bridge.sh').read_text()
        self.assertIn('docker/compose-bridge-kubernetes@sha256:', bridge_source)
        self.assertIn('docker/compose-bridge-helm@sha256:', bridge_source)
        self.assertEqual(set(local.ORIGINAL_FIXTURE_IMAGES),
                         {'alpine:3.20', 'alpine:3.21', 'alpine:latest',
                          'ghcr.io/linuxcontainers/alpine:3.20',
                          'busybox:latest',
                          'docker/compose-bridge-kubernetes@sha256:'
                          '4ffd3f23f377b1fdd9d0195732980e7534a8975c8a210a12681dc803c002f761',
                          'docker/compose-bridge-helm@sha256:'
                          '7aeee453c13045dcec87b92cb13973871ed8c72d5ca1e9365886487782ea2b09'})
        with tempfile.TemporaryDirectory() as temporary:
            install = Path(temporary)
            issued = []
            inspected = []
            def issue(lane, name, trial, command, timeout):
                issued.append((lane, name, command))
            def present(lane, image):
                inspected.append((lane, image))
                return image == 'busybox:latest'
            rows = local.preload_original_fixture_images(
                'docker.io/library/alpine@sha256:' + 'a' * 64, install, issue, present)
            self.assertEqual(len(rows), 18)
            self.assertEqual(len(issued), 16)
            self.assertEqual(len(inspected), 18)
            self.assertEqual([row['image'] for row in rows if row['already_present']],
                             ['busybox:latest', 'busybox:latest'])
            self.assertIn(('candidate', 'setup-original-fixture-image',
                           [str(install / 'bin/container'), 'image', 'pull', '--progress',
                            'none', '--platform', 'linux/arm64',
                            'ghcr.io/linuxcontainers/alpine:3.20']), issued)
            self.assertIn(('docker', 'setup-original-fixture-image',
                           ['docker', '--context', 'colima', 'pull', '--platform',
                            'linux/arm64', 'alpine:3.20']), issued)

    def test_journald_preload_requires_exact_signed_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            install = Path(temporary)
            prefix = 'libexec/container/services/journald/container-journald-service'
            archive = install / (prefix + '.oci.tar')
            manifest = install / (prefix + '.manifest.json')
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b'published OCI archive')
            manifest.write_text(json.dumps({
                'schemaVersion': 1, 'platform': 'linux', 'architecture': 'arm64',
                'ociArchiveSHA256': local.sha(archive),
                'workloadManifestDigest': 'sha256:' + 'b' * 64}))
            payload = {prefix + '.oci.tar': local.sha(archive),
                       prefix + '.manifest.json': local.sha(manifest)}
            selected, identity = local.verified_journald_archive(install, payload)
            self.assertEqual(selected, archive)
            self.assertEqual(identity['workload_manifest_digest'], 'sha256:' + 'b' * 64)
            archive.write_bytes(b'different archive')
            with self.assertRaisesRegex(RuntimeError, 'asset changed'):
                local.verified_journald_archive(install, payload)

    def test_capture_refuses_existing_compatible_published_reference(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / 'benchmark.lock.json'
            lock.write_text('{}')
            asset = root / 'published.json'
            image = 'docker.io/library/alpine@sha256:' + 'a' * 64
            workload = local.benchmark_evidence.workload(image)
            asset.write_text(json.dumps({'workload': workload, 'environment': {'host': 'same'}}))
            q = {'modules': {'runtime_benchmark': SimpleNamespace(ALPINE=image)}}
            with patch.object(local, 'BENCHMARK_LOCK', lock), \
                 patch.object(local, 'source_identity', return_value={'dirty': False,
                                                                     'commit': 'a' * 40}), \
                 patch.object(local, 'git', return_value='a' * 40), \
                 patch.object(local, 'host_budget'), \
                 patch.object(local.subprocess, 'check_output', return_value='5.5.1'), \
                 patch.object(local, 'docker_compose_binary_identity'), \
                 patch.object(local, 'benchmark_environment', return_value={'host': 'same'}), \
                 patch.object(local, 'cached_fetch', return_value={'asset': str(asset)}), \
                 patch.object(local.benchmark_evidence, 'validate_reference'):
                with self.assertRaisesRegex(RuntimeError, 'already exists'):
                    local.reference_preflight(root, q)

    def test_reference_preflight_retains_q_receipt_identity_for_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            lock = root / 'benchmark.lock.json'
            image = 'docker.io/library/alpine@sha256:' + 'a' * 64
            admitted = {'checkpoint': local.Q, 'runtime_fingerprint_sha256': '1' * 64,
                        'source_receipt_sha256': {'acceptance.json': '2' * 64}}
            q = {'modules': {
                'runtime_benchmark': SimpleNamespace(ALPINE=image, INSTALLS=root / 'installs'),
                'runtime_coverage': SimpleNamespace(require_idle=lambda _path: None),
                'host_lease': SimpleNamespace(JOURNAL=root / 'missing-host-journal')}}
            with patch.object(local, 'BENCHMARK_LOCK', lock), \
                 patch.object(local, 'source_identity', return_value={'dirty': False,
                                                                      'commit': 'a' * 40}), \
                 patch.object(local, 'git', return_value='a' * 40), \
                 patch.object(local, 'host_budget'), \
                 patch.object(local.subprocess, 'check_output', return_value='5.5.1'), \
                 patch.object(local, 'docker_compose_binary_identity'), \
                 patch.object(local, 'benchmark_environment', return_value={'host': 'same'}), \
                 patch.object(local, 'validate_q', return_value=admitted):
                local.reference_preflight(evidence, q)
            receipt = json.loads((evidence / 'reference-preflight.json').read_text())
            self.assertEqual(receipt['container'], admitted)

    def test_reference_recovery_report_failure_cannot_signal_restored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            image = 'docker.io/library/alpine@sha256:' + 'a' * 64
            local.write(evidence / 'reference-capture-intent.json', {
                'schema': 1, 'qualified_runtime': local.Q,
                'workload_sha256': local.benchmark_evidence.digest(
                    local.benchmark_evidence.workload(image)),
                'command_lock': str(evidence / 'commands.lock')})
            for name in ('projects-cleared.json', 'colima-lease.json', 'host-lease.json'):
                local.write(evidence / name, {'restored': True})
            q = {'modules': {'fork_benchmark': SimpleNamespace(STORAGE=root),
                             'runtime_benchmark': SimpleNamespace(INSTALLS=root, ALPINE=image),
                             'host_lease': SimpleNamespace(LOCK=root / 'host.lock',
                                                            JOURNAL=root / 'host.journal')}}
            original_write = local.write
            def failed_report(path, value):
                if path.name == 'reference-restoration.json':
                    raise OSError('retained report failed')
                original_write(path, value)
            with patch.object(local, 'q_modules', return_value=q), \
                 patch.object(local, 'admit_recovery_q', return_value={}), \
                 patch.object(local, 'write', side_effect=failed_report):
                result = local.recover_reference(evidence)
            self.assertFalse(result['restored'])
            self.assertIn('retained report failed', result['failures'][0])
            with patch.object(local, 'q_modules', return_value=q), \
                 patch.object(local, 'admit_recovery_q', return_value={}):
                recovered = local.recover_reference(evidence)
            self.assertTrue(recovered['restored'])
            self.assertTrue((evidence / 'reference-restoration.json').is_file())

    def test_active_reference_journal_report_failure_cannot_signal_restored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            image = 'docker.io/library/alpine@sha256:' + 'a' * 64
            local.write(evidence / 'reference-capture-intent.json', {
                'schema': 1, 'qualified_runtime': local.Q,
                'workload_sha256': local.benchmark_evidence.digest(
                    local.benchmark_evidence.workload(image)),
                'command_lock': str(evidence / 'commands.lock')})
            journal = root / 'host.journal'
            local.write(journal, {'evidence': str(evidence),
                                  'command_lock': str(evidence / 'commands.lock'),
                                  'bazel_workspace': str(local.Q_ROOT), 'owner': 999999,
                                  'workers': [], 'suspended': []})
            local.write(evidence / 'colima-lease.json', {'restored': False})
            host = SimpleNamespace(record={}, rows=[], suspended=[], close=lambda: None)
            def restore_host(**_kwargs):
                local.write(evidence / 'host-lease.json', {'restored': True})
                journal.unlink()
            host.restore = restore_host
            colima = SimpleNamespace(record={}, command_descriptors=())
            def restore_colima():
                colima.record['restored'] = True
                local.write(evidence / 'colima-lease.json', colima.record)
            colima.restore = restore_colima
            q = {'modules': {'fork_benchmark': SimpleNamespace(STORAGE=root),
                             'runtime_benchmark': SimpleNamespace(INSTALLS=root, ALPINE=image),
                             'host_lease': SimpleNamespace(LOCK=root / 'host.lock',
                                                            JOURNAL=journal, processes=lambda: {},
                                                            HostLease=lambda _evidence: host),
                             'unattended': SimpleNamespace(
                                 acquire_cleanup_commands=lambda *_args: (),
                                 ColimaLease=lambda _evidence: colima)}}
            original_write = local.write
            def failed_report(path, value):
                if path.name == 'reference-restoration.json':
                    raise OSError('final receipt failed')
                original_write(path, value)
            def clear_projects(_evidence, _ledger, _q, _descriptors,
                               _command_lock, **_kwargs):
                original_write(evidence / 'projects-cleared.json', {'cleared': True})
            with patch.object(local, 'q_modules', return_value=q), \
                 patch.object(local, 'admit_recovery_q', return_value={}), \
                 patch.object(local, 'ensure_projects_cleared', side_effect=clear_projects), \
                 patch.object(local, 'write', side_effect=failed_report):
                outcome = local.recover_reference(evidence)
            self.assertFalse(outcome['restored'])
            self.assertIn('final receipt failed', outcome['failures'][0])
            self.assertFalse(journal.exists())

    def test_pinned_previous_release_is_consumed_as_data_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            previous_source = 'a' * 40
            archive_hash, companion_hash, provenance_hash = ('1' * 64, '2' * 64, '3' * 64)
            previous_binary = '4' * 64
            lock = root / 'previous.lock.json'
            local.write(lock, {'schema': 1, 'repository': local.compose_release.REPOSITORY,
                               'tag': 'layer-compose-old', 'targetCommit': previous_source,
                               'asset': local.compose_release.PROVENANCE_NAME,
                               'sha256': provenance_hash})
            provenance = {'source': previous_source, 'signedAndNotarized': True,
                          'notary': {'status': 'Accepted'},
                          'qualifiedContainer': 'b' * 40,
                          'lowerReleasedAssets': {name: {'sha256': 'a' * 64,
                                                        'release': {'tag': 'old'}}
                                                  for name in ('runtime', 'guest', 'builder')},
                          'signedArchiveSHA256': archive_hash,
                          'signedPayload': {'bin/compose': previous_binary},
                          'signedTree': {'bin/compose': previous_binary},
                          'evidenceCompanion': {'asset': local.compose_release.EVIDENCE_NAME,
                                                'sha256': companion_hash}}
            provenance_path = root / local.compose_release.PROVENANCE_NAME
            local.write(provenance_path, provenance)
            archive_path = root / local.compose_release.ARCHIVE_NAME
            archive_path.write_bytes(b'old released archive')
            reference = {'workload': {'fixture': 'exact'}, 'workloadSHA256': '5' * 64,
                         'environment': {'host': 'same'}}
            samples = [{'fixture': f'{count}-services-{operation}', 'lane': 'candidate',
                        'trial': trial, 'seconds': float(trial), 'status': 0,
                        'log_sha256': '6' * 64}
                       for count in (1, 3) for operation in ('up', 'down')
                       for trial in range(1, 8)]
            benchmark = {'workload': reference['workload'],
                         'workloadSHA256': reference['workloadSHA256'],
                         'environment': reference['environment'],
                         'signedArchiveSHA256': archive_hash,
                         'candidateBinarySHA256': previous_binary,
                         'candidateCapture': {'capturedAt': '2026-09-28T12:00:00Z'},
                         'candidateSamples': samples,
                         'measurements': {name: {'lanes': {'candidate': {'raw_seconds': [
                             float(trial) for trial in range(1, 8)]}}} for name in (
                                 '1-services-up', '1-services-down',
                                 '3-services-up', '3-services-down')}}
            parity = {'cases': [{'name': f'case-{number:02d}', 'status': 0,
                                 'sourceSHA256': '7' * 64,
                                 'assertionOutputSHA256': '8' * 64}
                                for number in range(67)]}
            companion_path = root / local.compose_release.EVIDENCE_NAME
            with zipfile.ZipFile(companion_path, 'w') as companion:
                companion.writestr('benchmark.json', json.dumps(benchmark))
                companion.writestr('parity-summary.json', json.dumps(parity))
            assets = {local.compose_release.PROVENANCE_NAME: provenance_path,
                      local.compose_release.ARCHIVE_NAME: archive_path,
                      local.compose_release.EVIDENCE_NAME: companion_path}
            def fetched(path, _cache):
                asset = local.read_lock(path)['asset']
                return {'asset': str(assets[asset]), 'releaseId': 17,
                        'assetId': list(assets).index(asset) + 1}
            with patch.object(local, 'cached_fetch', side_effect=fetched), \
                 patch.object(local.compose_release, 'inspect_evidence', return_value={}), \
                 patch.object(local, 'published_release_asset', return_value=(
                     {'id': 17}, {'id': 18, 'digest': 'sha256:' + archive_hash})):
                admitted = local.admit_previous_candidate(evidence, lock, reference)
            self.assertEqual(admitted['archiveSHA256'], archive_hash)
            self.assertEqual(admitted['companionSHA256'], companion_hash)
            self.assertEqual(len(admitted['samples']), 28)
            self.assertEqual(len(admitted['parityCases']), 67)
            runtime = evidence / 'runtime'
            runtime.mkdir()
            local.write(runtime / 'compose-operations.json', {'rows': samples})
            local.write(evidence / 'live.json', {'passed': True})
            (evidence / 'full-suite').mkdir()
            local.write(evidence / 'full-suite/acceptance.json', {'rows': [
                {'fixture': row['name'], 'status': 0} for row in parity['cases']]})
            (evidence / 'q-assets').mkdir()
            local.write(evidence / 'q-assets/q-assets.json', {
                'assets': {name: {'sha256': 'c' * 64}
                           for name in ('runtime', 'guest', 'builder')},
                'releases': {name: {'tag': 'current'}
                             for name in ('runtime', 'guest', 'builder')}})
            comparison = local.compare_previous_candidate(evidence, {
                'benchmarks': {name: {'passed': True} for name in benchmark['measurements']}},
                admitted)
            self.assertEqual(comparison['measurements']['1-services-up']['medianRatio'], 1)
            self.assertEqual(comparison['measurements']['1-services-up']['p95Ratio'], 1)
            self.assertEqual(len(comparison['parityOutcomeComparison']['samePassedCaseNames']), 67)
            self.assertTrue(comparison['runtimeStackChanged'])
            local.write(lock, {**local.read_lock(lock), 'sha256': '9' * 64})
            with self.assertRaisesRegex(RuntimeError, 'lock changed'):
                local.compare_previous_candidate(evidence, {'benchmarks': {}}, admitted)

    def test_missing_reference_fails_before_hosted_or_build_stages(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            evidence = root / 'fresh'
            container_root = root / 'container'
            q_evidence = root / 'q-evidence'
            container_root.mkdir()
            q_evidence.mkdir()
            runtime = SimpleNamespace(ALPINE='docker.io/library/alpine@sha256:' + 'a' * 64)
            selected = {}
            def cheap_preflight(destination, _q):
                local.write(destination / 'preflight.json', {'container': {}})
                return {'commit': 'a' * 40}, {}
            def selected_q_modules():
                selected['container_root'] = local.Q_ROOT
                selected['q_evidence'] = local.Q_EVIDENCE
                return {'modules': {'runtime_benchmark': runtime}}
            with patch.object(local, 'OUTPUT', root), \
                 patch.object(local, 'Q_ROOT', None), patch.object(local, 'Q_EVIDENCE', None), \
                 patch.object(sys, 'argv', ['qualify_local.py', '--evidence', str(evidence),
                                            '--container-root', str(container_root),
                                            '--q-evidence', str(q_evidence)]), \
                 patch.object(local, 'q_modules', side_effect=selected_q_modules), \
                 patch.object(local, 'preflight', side_effect=cheap_preflight), \
                 patch.object(local, 'admit_benchmark_reference', side_effect=RuntimeError('missing baseline')), \
                 patch.object(local, 'admit_hosted') as hosted, \
                 patch.object(local, 'run_layers') as layers, \
                 patch.object(local, 'run_live') as live:
                with self.assertRaisesRegex(RuntimeError, 'missing baseline'):
                    local.main()
            hosted.assert_not_called()
            layers.assert_not_called()
            live.assert_not_called()
            self.assertEqual(selected['container_root'], container_root)
            self.assertEqual(selected['q_evidence'], q_evidence)

    def test_cli_requires_q_paths_and_rejects_symlink_directories(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            evidence = root / 'fresh'
            container_root = root / 'container'
            q_evidence = root / 'q-evidence'
            container_root.mkdir()
            q_evidence.mkdir()
            with patch.object(local, 'Q_ROOT', None), patch.object(local, 'Q_EVIDENCE', None), \
                 patch.object(sys, 'argv', ['qualify_local.py', '--evidence', str(evidence)]):
                with self.assertRaises(SystemExit) as missing:
                    local.main()
            self.assertEqual(missing.exception.code, 2)

            container_alias = root / 'container-alias'
            q_evidence_alias = root / 'q-evidence-alias'
            container_alias.symlink_to(container_root, target_is_directory=True)
            q_evidence_alias.symlink_to(q_evidence, target_is_directory=True)
            for option, value in (('--container-root', container_alias),
                                  ('--q-evidence', q_evidence_alias)):
                args = ['qualify_local.py', '--evidence', str(evidence),
                        '--container-root', str(container_root),
                        '--q-evidence', str(q_evidence)]
                args[args.index(option) + 1] = str(value)
                with self.subTest(option=option), \
                     patch.object(local, 'Q_ROOT', None), patch.object(local, 'Q_EVIDENCE', None), \
                     patch.object(sys, 'argv', args):
                    with self.assertRaises(SystemExit) as invalid:
                        local.main()
                self.assertEqual(invalid.exception.code, 2)

    def test_recovery_uses_the_explicit_container_and_q_evidence_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output = root / 'output'
            evidence = output / 'interrupted'
            container_root = root / 'container'
            q_evidence = root / 'q-evidence'
            evidence.mkdir(parents=True)
            container_root.mkdir()
            q_evidence.mkdir()
            observed = {}
            def recover(selected_evidence):
                observed.update(evidence=selected_evidence, container_root=local.Q_ROOT,
                                q_evidence=local.Q_EVIDENCE)
                return {'restored': True}
            args = ['qualify_local.py', '--recover', '--evidence', str(evidence),
                    '--container-root', str(container_root), '--q-evidence', str(q_evidence)]
            with patch.object(local, 'OUTPUT', output), \
                 patch.object(local, 'Q_ROOT', None), patch.object(local, 'Q_EVIDENCE', None), \
                 patch.object(sys, 'argv', args), patch.object(local, 'recover', side_effect=recover), \
                 patch.object(signal, 'signal'), patch('builtins.print'):
                local.main()
            self.assertEqual(observed, {'evidence': evidence, 'container_root': container_root,
                                        'q_evidence': q_evidence})

    def test_reference_capture_route_never_enters_candidate_pipeline(self) -> None:
        with patch.object(local, 'q_modules', return_value={'modules': {}}) as modules, \
             patch.object(local, 'reference_preflight') as preflight, \
             patch.object(local, 'capture_reference', return_value={'passed': True}) as capture, \
             patch.object(local, 'run_layers') as layers, patch.object(local, 'sign') as sign, \
             patch.object(local, 'run_original_full_suite') as suite:
            result = local.execute_capture(Path('/tmp/reference-test'))
        self.assertTrue(result['passed'])
        modules.assert_called_once()
        preflight.assert_called_once()
        capture.assert_called_once()
        layers.assert_not_called()
        sign.assert_not_called()
        suite.assert_not_called()

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
        container_root = Path('/qualified/container')
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(local, 'STAGES', ()), \
             patch.object(local, 'Q_ROOT', container_root), \
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
        self.assertEqual(kwargs['env']['CONTAINER_STACK_REPO'], str(container_root))
        self.assertEqual(run.call_args_list[1].args[1:3],
                         ('workflow-tools', ['make', '--no-print-directory',
                                             'bazel-workflow-tools-test']))

    def test_native_test_binaries_are_materialized_after_all_layers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            output = root / 'output' / 'bazel-out' / 'darwin_arm64-dbg' / 'bin'
            output.mkdir(parents=True)
            local.write(evidence / 'preflight.json', {'container': {
                'source_receipt_sha256': {}, 'release_sha256': 'same',
                'guest_sha256': 'same', 'builder_sha256': 'same'}})
            seen = []

            def fake_stage(directory, name, command, timeout, **_):
                seen.append((name, command))
                log = directory / 'stages' / (name + '.log')
                log.parent.mkdir(exist_ok=True)
                if name == 'package':
                    log.write_text('Retained Compose Bazel invocation: ' + 'a' * 36 + '\n')
                elif name == 'runtime-tests-build':
                    for target in ('ComposeRuntimeTests', 'ComposeCoreTests',
                                   'ComposePluginTests'):
                        binary = output / (target + '.xctest/Contents/MacOS') / target
                        binary.parent.mkdir(parents=True)
                        binary.write_bytes(target.encode())
                        binary.chmod(0o755)
                        runfiles = binary.with_name(target + '.runfiles')
                        (runfiles / '_main' / (target + '.xctest')).mkdir(parents=True)
                        if target == 'ComposeRuntimeTests':
                            (runfiles / '_main' / 'ComposeRuntimeFixtures.bundle' /
                             'Contents/Resources/Fixtures').mkdir(parents=True)
                    log.write_text('Built all native test targets\n')
                elif name == 'native-test-output-root':
                    log.write_text(str(output) + '\n')
                else:
                    log.write_text('stage passed\n')
                return {'name': name, 'log': str(log), 'status': 0}

            with patch.object(local, 'SSD', root), \
                 patch.object(local, 'STAGES', (
                     ('core-enhanced', 'test', '//:ComposeCoreTests', 'enhanced', 1800),
                     ('package', 'build', '//:candidate_archive', 'enhanced', 2400))), \
                 patch.object(local, 'stage', side_effect=fake_stage), \
                 patch.object(local, 'fetch_q_assets', return_value={
                     'provenance': {'source_receipt_sha256': {}},
                     'assets': {name: {'sha256': 'same'}
                                for name in ('runtime', 'guest', 'builder')}}), \
                 patch.object(local, 'compiled_sdk_chain', return_value={}), \
                 patch.object(local, 'sha', return_value='receipt-hash'), \
                 patch.object(local, 'source_identity', return_value={'source': 'same'}), \
                 patch.object(local, 'verify_source'):
                rows, _, _, binaries = local.run_layers(
                    evidence, {'commit': 'a' * 40}, {'hashes': {}})

            self.assertEqual([name for name, _ in seen][-3:],
                             ['package', 'runtime-tests-build',
                              'native-test-output-root'])
            self.assertEqual(seen[-2][1], [str(local.ROOT / 'Tools/bazel/run.sh'),
                                           'build', '//:ComposeRuntimeTests',
                                           '//:ComposeCoreTests', '//:ComposePluginTests',
                                           '--config=enhanced'])
            self.assertEqual(set(binaries), {'ComposeRuntimeTests', 'ComposeCoreTests',
                                             'ComposePluginTests'})
            self.assertEqual({record['workspace'] for record in binaries.values()}, {'_main'})
            self.assertEqual(rows[-2]['name'], 'runtime-tests-build')

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
            self.assertEqual(value.count('mem_limit: 256m'), 3)
            self.assertEqual(value.count('network_mode: none'), 3)
            with self.assertRaises(ValueError):
                local.fixture(path, 50, 'example.invalid/alpine')
        def output(command, **_options):
            if command[:2] == ['sysctl', '-n']:
                return str(32 * 1024**3)
            if command[:2] == ['colima', 'list']:
                return json.dumps({'name': 'default', 'arch': 'aarch64',
                                   'runtime': 'docker', 'status': 'Stopped',
                                   'memory': 8 * 1024**3}) + '\n'
            raise AssertionError(command)
        with patch.object(local.subprocess, 'check_output', side_effect=output):
            budget = local.benchmark_budget()
        self.assertEqual(budget['service_memory_max_mib'], 3 * local.benchmark_evidence.SERVICE_MEMORY_MIB)
        self.assertEqual(budget['benchmark_service_memory_mib'], 256)
        self.assertEqual(budget['memory_per_service_mib'], 256)
        self.assertEqual(budget['trials'], 7)
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

    def test_broad_matrix_budget_requires_200m_profile_and_live_headroom(self) -> None:
        def output(command, **_options):
            if command[-2:] == ['-n', 'hw.memsize']:
                return str(24 * 1024**3)
            if command[:2] == ['colima', 'list']:
                return json.dumps({'name': 'default', 'arch': 'aarch64',
                                   'runtime': 'docker', 'status': 'Stopped',
                                   'memory': 8 * 1024**3}) + '\n'
            if command == ['/usr/bin/vm_stat']:
                return ('Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
                        'Pages free: 1000000.\nPages inactive: 400000.\n'
                        'Pages speculative: 100000.\n')
            raise AssertionError(command)

        with patch.object(local.subprocess, 'check_output', side_effect=output):
            budget = local.performance_matrix_budget()
        self.assertEqual(budget['service_memory_mib'], 200)
        self.assertEqual(budget['service_count_max'], 50)
        self.assertEqual(budget['candidate_guest_envelope_bytes'],
                         50 * (200 + 32) * 1024**2)
        self.assertEqual(budget['minimum_host_headroom_bytes'], 4 * 1024**3)
        self.assertTrue(budget['passed'])

        def pressured(command, **_options):
            if command[-2:] == ['-n', 'hw.memsize']:
                return str(24 * 1024**3)
            if command[:2] == ['colima', 'list']:
                return json.dumps({'name': 'default', 'arch': 'aarch64',
                                   'runtime': 'docker', 'status': 'Stopped',
                                   'memory': 8 * 1024**3}) + '\n'
            if command == ['/usr/bin/vm_stat']:
                return ('Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
                        'Pages free: 300000.\nPages inactive: 100000.\n'
                        'Pages speculative: 10000.\n')
            raise AssertionError(command)

        with patch.object(local.subprocess, 'check_output', side_effect=pressured):
            with self.assertRaisesRegex(RuntimeError, 'Current memory pressure'):
                local.performance_matrix_budget()

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

    def test_missing_host_journal_does_not_clear_pending_parity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            storage = root / 'storage'
            installs = root / 'installs'
            storage.mkdir()
            installs.mkdir()
            modules = {'fork_benchmark': SimpleNamespace(STORAGE=storage),
                       'runtime_benchmark': SimpleNamespace(INSTALLS=installs),
                       'host_lease': SimpleNamespace(LOCK=root / 'host.lock', JOURNAL=root / 'missing.json')}
            ledger = local.full_suite.Ledger(root / 'full-suite')
            ledger.begin('docker-compose-build-isolation-parity', 'source', [], {})
            original = ledger.path.read_bytes()
            with patch.object(local, 'q_modules', return_value={'modules': modules, 'hashes': {}}), \
                 patch.object(local, 'admit_recovery_q', return_value={'fingerprint': {'binaries': {}}}), \
                 patch.object(local, 'revalidate_q_assets', return_value={}):
                result = local.recover(root)
            self.assertFalse(result['restored'])
            self.assertTrue(any('Parity resources remain' in failure for failure in result['failures']))
            self.assertEqual(ledger.path.read_bytes(), original)

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
                 patch.object(local, 'admit_recovery_q', return_value={'fingerprint': {'binaries': {}}}), \
                 patch.object(local, 'revalidate_q_assets', return_value={}), \
                 patch.object(local, 'write', side_effect=OSError('disk full')), \
                 patch.object(local.os, 'close', side_effect=close):
                result = local.recover(root)
            self.assertFalse(result['restored'])
            self.assertEqual(len(closed), 3)


if __name__ == '__main__':
    unittest.main()
