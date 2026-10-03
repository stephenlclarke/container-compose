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

"""Synthetic, no-network admission checks for the signed Compose release."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import compose_release as release
import benchmark_evidence as benchmark


SOURCE = 'a' * 40
Q = 'b' * 40


class ComposeReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.evidence = self.base / 'evidence'
        self.evidence.mkdir()
        self.locks = self.base / 'locks'
        self.locks.mkdir()
        lock_patch = patch.object(release, 'LOCK_DIRECTORY', self.locks)
        lock_patch.start()
        self.addCleanup(lock_patch.stop)
        benchmark_lock_patch = patch.object(release, 'BENCHMARK_LOCK',
                                           self.locks / 'benchmark-reference.lock.json')
        benchmark_lock_patch.start()
        self.addCleanup(benchmark_lock_patch.stop)
        self.receipts: dict[str, dict] = {}
        self._fixture()

    def put(self, name: str, value: dict) -> Path:
        path = self.evidence / name
        path.parent.mkdir(parents=True, exist_ok=True)
        release.write(path, value)
        self.receipts[name] = value
        return path

    def _fixture(self) -> None:
        notice = b'qualified notices\n'
        archive = self.evidence / 'signed-compose.zip'
        files = {'bin/compose': b'signed compose',
                 'resources/compose-normalizer': b'signed normalizer',
                 'resources/volume-initializer/compose-volume-initializer-linux-arm64': b'linux arm64',
                 'resources/volume-initializer/compose-volume-initializer-linux-amd64': b'linux amd64',
                 'resources/THIRD-PARTY-NOTICES.txt': notice}
        import hashlib
        hashes = {name: hashlib.sha256(value).hexdigest() for name, value in files.items()}
        with zipfile.ZipFile(archive, 'w') as target:
            for name, value in files.items():
                member = zipfile.ZipInfo('compose/' + name)
                member.external_attr = (0o100755 if name in release.EXECUTABLES
                                        else 0o100644) << 16
                target.writestr(member, value)
        self.put('preflight.json', {'ready': True})
        self.put('hosted-quality/quality.json', {'passed': True, 'source': SOURCE})
        q_assets = {'qualified_container_source': Q, 'assets': {}, 'releases': {}}
        for name in ('runtime', 'guest', 'builder', 'provenance'):
            asset = self.evidence / 'q-assets' / (name + '.bin')
            asset.parent.mkdir(exist_ok=True)
            asset.write_bytes(name.encode())
            q_assets['assets'][name] = {'path': str(asset), 'sha256': release.digest(asset)}
            q_assets['releases'][name] = {'repository': 'owner/repo', 'tag': name}
        self.put('q-assets/q-assets.json', q_assets)
        chain = {'source': SOURCE, 'profile': 'enhanced',
                 'selected_config': 'prebuilt-container-sdk',
                 'package_invocation': 'fixture-invocation', 'locks': {}}
        for name in ('argument-parser', 'foundation', 'containerization', 'engine-api', 'container-sdk'):
            path = self.locks / ('argument-parser.lock.json' if name == 'argument-parser'
                                 else 'layer-locks/' + name + '-enhanced.json')
            path.parent.mkdir(exist_ok=True)
            release.write(path, {'name': name})
            chain['locks'][name] = {'lock_sha256': release.digest(path)}
        self.put('compiled-sdk-chain.json', chain)
        unsigned = {'kind': 'unsigned-native-candidate', 'commit': SOURCE,
                    'runtimeProfile': 'enhanced', 'distributionReady': False,
                    'licenseClosureComplete': False,
                    'dependencyNoticesSHA256': hashes['resources/THIRD-PARTY-NOTICES.txt'],
                    'goNoticeModules': 1, 'swiftNoticePackages': 1,
                    'vendoredNotices': {'x': 'y'}, 'sourceNoticeFragments': {'x': 'y'}}
        self.put('candidate-unsigned.json', {'receipt': unsigned})
        signed = {'source': SOURCE, 'identity': 'Developer ID: fixture',
                  'payload': {name: hashes[name] for name in ('bin/compose', 'resources/compose-normalizer')},
                  'tree': hashes}
        self.put('signed-candidate.json', signed)
        rows = [{'status': 0} for _ in range(67)]
        full = {'passed': True, 'runtime_tests': 27, 'parity_cases': 66, 'rows': rows}
        for index, row in enumerate(rows):
            name = 'runtime-suite' if index == 0 else f'docker-compose-case-{index}-parity'
            row.update(fixture=name, seconds=1.0)
            log = self.evidence / 'full-suite' / (name + '.log')
            log.parent.mkdir(exist_ok=True)
            log.write_text('assertions passed\n')
            self.put('full-suite/' + name + '.json', {
                'name': name, 'status': 0, 'source_sha256': 'c' * 64,
                'log': str(log), 'log_sha256': release.digest(log)})
        self.put('full-suite/acceptance.json', full)
        self.put('full-suite-cleared.json', {'verified_under_exclusive_lease': True})
        measurement = {'passed': True, 'lanes': {
            lane: {'raw_seconds': [1.0] * 7} for lane in ('candidate', 'docker')}}
        live = {'passed': True, 'original_full_suite': full,
                'benchmarks': {f'{count}-services-{operation}': measurement
                               for count in (1, 3) for operation in ('up', 'down')}}
        samples = [{'fixture': name, 'lane': 'candidate', 'trial': trial,
                    'seconds': 1.0, 'status': 0, 'log_sha256': 'e' * 64}
                   for name in sorted(live['benchmarks']) for trial in range(1, 8)]
        candidate_warmups = [{**row, 'trial': 0} for row in samples[::7]]
        live['benchmark_candidate_warmups'] = candidate_warmups
        self.put('live.json', live)
        before_snapshot = {'observed_unix_seconds': 1, 'load_average': [0.5, 0.4, 0.3],
                           'power': "Now drawing from 'AC Power'",
                           'top_cpu_processes': [{'pid': 123, 'cpu_percent': 1.5,
                                                  'command': '/private/example'}]}
        after_snapshot = {**before_snapshot, 'observed_unix_seconds': 2}
        before = self.put('runtime/benchmark-host-before.json', before_snapshot)
        after = self.put('runtime/benchmark-host-after.json', after_snapshot)
        reference_samples = [{**row, 'lane': 'docker'} for row in samples]
        image = 'docker.io/library/alpine@sha256:' + 'a' * 64
        workload = benchmark.workload(image)
        environment = {'architecture': 'arm64', 'host_model': 'Mac16,1', 'host_cpus': 12,
                       'host_memory_bytes': 32 * 1024**3, 'macos_version': '26.0',
                       'macos_build': '25A123', 'docker_cli_sha256': 'a' * 64,
                       'colima': {'arch': 'aarch64', 'runtime': 'docker', 'cpus': 4,
                                  'memory_bytes': 8 * 1024**3, 'disk_bytes': 100 * 1024**3,
                                  'config_sha256': 'b' * 64, 'binary_sha256': 'c' * 64}}
        binary = {'formula': 'docker-compose', 'version': '5.5.1',
                  'sha256': 'c' * 64, 'bottleSHA256': 'd' * 64,
                  'bottleURL': 'https://ghcr.io/v2/homebrew/core/docker-compose/blobs/sha256:'
                               + 'd' * 64}
        capture = {'cleanupVerified': True, 'hostRestored': True,
                   'capturedAt': '2026-09-28T10:00:00Z',
                   'hostBeforeSHA256': '1' * 64, 'hostAfterSHA256': '2' * 64,
                   'hostBefore': benchmark.host_projection(before_snapshot),
                   'hostAfter': benchmark.host_projection(after_snapshot),
                   'cleanupReceiptSHA256': '3' * 64,
                   'dockerEngine': {'version': '29.2.1', 'apiVersion': '1.53',
                                    'os': 'linux', 'arch': 'arm64', 'kernelVersion': '6.12.0'}}
        warmups = [{**row, 'trial': 0} for row in reference_samples[::7]]
        baseline = self.put('baseline-asset.json', benchmark.reference_document(
            workload, environment, binary, reference_samples, warmups, capture))
        release.write(release.BENCHMARK_LOCK, {
            'schema': 1, 'repository': 'owner/repo', 'tag': 'benchmark-reference',
            'targetCommit': SOURCE, 'asset': 'baseline-asset.json',
            'sha256': release.digest(baseline)})
        self.put('benchmark-reference.json', {
            'asset': str(baseline), 'lock_sha256': release.digest(release.BENCHMARK_LOCK),
            'asset_sha256': release.digest(baseline), 'release_id': 41, 'asset_id': 42})
        self.put('portable-benchmark.json', {
            'schema': 1, 'source': SOURCE, 'signedArchiveSHA256': release.digest(archive),
            'candidateBinarySHA256': hashes['bin/compose'],
            'historicalReference': True, 'passed': True,
            'workload': workload, 'workloadSHA256': benchmark.digest(workload),
            'environment': environment,
            'reference': {'repository': 'owner/repo', 'tag': 'benchmark-reference',
                          'targetCommit': SOURCE, 'releaseId': 41, 'assetId': 42,
                          'assetSHA256': release.digest(baseline),
                          'referenceBinary': binary, 'capture': capture},
            'candidateCapture': {'capturedAt': '2026-09-28T11:00:00Z',
                                 'hostBeforeSHA256': release.digest(before),
                                 'hostAfterSHA256': release.digest(after),
                                 'hostBefore': benchmark.host_projection(before_snapshot),
                                 'hostAfter': benchmark.host_projection(after_snapshot),
                                 'warmups': candidate_warmups},
            'candidateSamples': samples, 'referenceSamples': reference_samples,
            'measurements': live['benchmarks']})
        self.put('cleanup-phases.json', {'completed': list(release.PHASES)})
        self.put('notarization.json', {'passed': True, 'source': SOURCE,
                  'archive': str(archive), 'archive_sha256': release.digest(archive),
                  'signed_payload': signed['payload'],
                  'notary': {'status': 'Accepted', 'id': 'fixture-notary-id'}})
        stages = [{'name': name, 'status': 0} for name in (
            'source-preflight', 'workflow-tools', 'original-parity-fixtures',
            'runtime-tests-build', 'unit-stock', 'unit-enhanced', 'coverage-stock',
            'coverage-enhanced', 'package-tests', 'package-smoke', 'docs', 'package',
            'compiled-sdk-chain')]
        self.put('acceptance.json', {'schema': 1, 'target': 'compose-only-qualify',
                 'source': SOURCE, 'q_checkpoint': Q, 'passed': True, 'failures': [],
                 'stages': stages,
                 'preflight_sha256': release.digest(self.evidence / 'preflight.json'),
                 'hosted_quality_sha256': release.digest(self.evidence / 'hosted-quality/quality.json'),
                 'released_q_assets_sha256': release.digest(self.evidence / 'q-assets/q-assets.json'),
                 'compiled_sdk_chain_sha256': release.digest(self.evidence / 'compiled-sdk-chain.json'),
                 'benchmark_reference_sha256': release.digest(self.evidence / 'benchmark-reference.json'),
                 'portable_benchmark_sha256': release.digest(self.evidence / 'portable-benchmark.json'),
                 'live_sha256': release.digest(self.evidence / 'live.json'),
                 'notarization_sha256': release.digest(self.evidence / 'notarization.json')})

    def test_development_receipts_cannot_be_admitted_as_release(self) -> None:
        for target in ('compose-development-bridge', 'compose-development-parity'):
            with self.subTest(target=target):
                acceptance = self.receipts['acceptance.json']
                acceptance['target'] = target
                self.put('acceptance.json', acceptance)
                with self.assertRaisesRegex(RuntimeError, 'qualification'):
                    release.prepare(self.evidence, self.base / 'release')

    def test_prepare_retains_unsigned_truth_and_exact_signed_assets(self) -> None:
        output = self.base / 'staged'
        record = release.prepare(self.evidence, output)
        self.assertFalse(release.read(output / release.PROVENANCE_NAME)
                         ['unsignedCandidate']['receipt']['distributionReady'])
        self.assertFalse(release.read(output / release.PROVENANCE_NAME)['signedDistributionReady'])
        self.assertTrue(release.read(output / release.PROVENANCE_NAME)['signedAndNotarized'])
        self.assertFalse(record['published'])
        self.assertEqual(release.digest(output / release.ARCHIVE_NAME), record['archiveSHA256'])
        self.assertEqual(release.digest(output / release.EVIDENCE_NAME), record['evidenceSHA256'])
        provenance = release.read(output / release.PROVENANCE_NAME)
        manifest = release.inspect_evidence(output / release.EVIDENCE_NAME, provenance)
        self.assertEqual(set(manifest['files']), {'benchmark.json', 'parity-summary.json'})

    def test_tampered_notary_and_notice_fail_closed(self) -> None:
        notary = self.evidence / 'notarization.json'
        value = release.read(notary)
        value['notary']['status'] = 'Rejected'
        release.write(notary, value)
        with self.assertRaisesRegex(RuntimeError, 'changed'):
            release.admit(self.evidence)
        self._fixture()
        with zipfile.ZipFile(self.evidence / 'signed-compose.zip', 'w') as archive:
            archive.writestr('compose/resources/THIRD-PARTY-NOTICES.txt', b'changed')
        with self.assertRaisesRegex(RuntimeError, 'notarization|archive'):
            release.admit(self.evidence)

    def test_publish_requires_still_accepted_source_and_exact_assets(self) -> None:
        output = self.base / 'staged'
        release.prepare(self.evidence, output)
        with patch.object(release, 'publish_assets', return_value={
                'repository': release.REPOSITORY,
                'tag': release.read(output / 'prepare-receipt.json')['tag'],
                'targetCommit': SOURCE, 'releaseId': 42,
                'assets': {name: {'sha256': release.digest(output / name), 'assetId': index}
                           for index, name in enumerate((release.ARCHIVE_NAME,
                                                         release.PROVENANCE_NAME,
                                                         release.EVIDENCE_NAME), 1)}}) as publisher:
            release.publish(output)
            publisher.assert_called_once()
        with self.assertRaisesRegex(RuntimeError, 'already'):
            release.publish(output)

    def test_downloaded_release_is_bound_to_published_asset_ids(self) -> None:
        output = self.base / 'staged'
        release.prepare(self.evidence, output)
        staged = release.read(output / 'prepare-receipt.json')
        published = {'schema': 1, 'published': True, 'repository': release.REPOSITORY,
                     'tag': staged['tag'], 'targetCommit': SOURCE, 'releaseId': 42,
                     'prepareReceiptSHA256': release.digest(output / 'prepare-receipt.json'),
                     'assets': {name: {'sha256': release.digest(output / name), 'assetId': index}
                                for index, name in enumerate((release.ARCHIVE_NAME,
                                                              release.PROVENANCE_NAME,
                                                              release.EVIDENCE_NAME), 1)}}
        published['evidenceCompanion'] = {
            **release.read(output / release.PROVENANCE_NAME)['evidenceCompanion'],
            'releaseId': 42, 'assetId': published['assets'][release.EVIDENCE_NAME]['assetId']}
        release.write(output / 'publish-receipt.json', published)
        def downloaded(lock: Path, destination: Path) -> dict:
            name = release.read_lock(lock)['asset']
            destination.mkdir()
            asset = destination / name
            shutil.copyfile(output / name, asset)
            return {'asset': str(asset), 'sha256': release.digest(asset),
                    'releaseId': 42, 'assetId': published['assets'][name]['assetId']}
        commands = []
        def run(command: list[str], **kwargs: object) -> object:
            commands.append(command)
            if command[0] == '/usr/bin/ditto':
                self.assertEqual(command[1:3], ['-x', '-k'])
                with zipfile.ZipFile(command[3]) as archive:
                    for member in archive.infolist():
                        path = Path(command[4]) / member.filename
                        if member.is_dir():
                            path.mkdir(parents=True, exist_ok=True)
                        else:
                            path.parent.mkdir(parents=True, exist_ok=True)
                            path.write_bytes(archive.read(member))
                            path.chmod((member.external_attr >> 16) & 0o777)
            return release.subprocess.CompletedProcess(command, 0)
        with patch.object(release, 'fetch', side_effect=downloaded), patch.object(release.subprocess, 'run', side_effect=run):
            result = release.verify_published(output, self.base / 'consumer')
        self.assertTrue(result['publishedBytesVerified'])
        self.assertEqual(result['evidenceSHA256'], published['assets'][release.EVIDENCE_NAME]['sha256'])
        self.assertEqual(sum(command[0] == '/usr/bin/ditto' for command in commands), 1)
        self.assertEqual(sum(command[0] == '/usr/bin/codesign' for command in commands), 2)
        self.assertTrue((self.base / 'consumer/extracted/compose/bin/compose').is_file())
        for name in release.EXECUTABLES:
            self.assertTrue((self.base / 'consumer/extracted/compose' / name).stat().st_mode & 0o111)

    def test_prepared_lock_tamper_prevents_publication(self) -> None:
        output = self.base / 'staged'
        release.prepare(self.evidence, output)
        lock = output / (release.ARCHIVE_NAME + '.lock.json')
        value = release.read(lock)
        value['sha256'] = '0' * 64
        release.write(lock, value)
        with patch.object(release, 'publish_assets') as publisher:
            with self.assertRaisesRegex(RuntimeError, 'lock changed'):
                release.publish(output)
            publisher.assert_not_called()

    def test_public_companion_rejects_local_paths_and_raw_trial_mismatch(self) -> None:
        portable = self.evidence / 'portable-benchmark.json'
        benchmark = release.read(portable)
        benchmark['reference']['log_path'] = '/Users/sclarke/private.log'
        release.write(portable, benchmark)
        accepted = release.read(self.evidence / 'acceptance.json')
        accepted['portable_benchmark_sha256'] = release.digest(portable)
        release.write(self.evidence / 'acceptance.json', accepted)
        with self.assertRaisesRegex(RuntimeError, 'unsupported public fields'):
            release.prepare(self.evidence, self.base / 'rejected-path')
        self._fixture()
        benchmark = release.read(portable)
        benchmark['measurements']['1-services-up']['lanes']['candidate']['raw_seconds'][0] = 100
        release.write(portable, benchmark)
        accepted = release.read(self.evidence / 'acceptance.json')
        accepted['portable_benchmark_sha256'] = release.digest(portable)
        release.write(self.evidence / 'acceptance.json', accepted)
        with self.assertRaisesRegex(RuntimeError, 'raw trials differ'):
            release.prepare(self.evidence, self.base / 'rejected-trial')

    def test_companion_manifest_rejects_changed_member(self) -> None:
        output = self.base / 'staged'
        release.prepare(self.evidence, output)
        archive = output / release.EVIDENCE_NAME
        with zipfile.ZipFile(archive, 'a') as target:
            target.writestr('unexpected.json', '{}')
        with patch.object(release, 'publish_assets') as publisher:
            with self.assertRaisesRegex(RuntimeError, 'unsafe or unexpected'):
                release.publish(output)
            publisher.assert_not_called()

    def test_reference_asset_or_accepted_portable_receipt_cannot_change(self) -> None:
        reference = release.read(self.evidence / 'benchmark-reference.json')
        asset = Path(reference['asset'])
        asset.write_text(asset.read_text() + ' ')
        with self.assertRaisesRegex(RuntimeError, 'reference changed'):
            release.prepare(self.evidence, self.base / 'changed-reference')
        self._fixture()
        portable = self.evidence / 'portable-benchmark.json'
        value = release.read(portable)
        value['reference']['assetId'] = 900
        release.write(portable, value)
        with self.assertRaisesRegex(RuntimeError, 'Accepted Compose receipt changed'):
            release.prepare(self.evidence, self.base / 'changed-portable')

    def test_candidate_capture_must_match_accepted_host_and_warmups(self) -> None:
        portable = self.evidence / 'portable-benchmark.json'
        value = release.read(portable)
        value['candidateCapture']['hostAfterSHA256'] = '0' * 64
        release.write(portable, value)
        accepted = release.read(self.evidence / 'acceptance.json')
        accepted['portable_benchmark_sha256'] = release.digest(portable)
        release.write(self.evidence / 'acceptance.json', accepted)
        with self.assertRaisesRegex(RuntimeError, 'candidate capture differs'):
            release.prepare(self.evidence, self.base / 'changed-capture')


if __name__ == '__main__':
    unittest.main()
