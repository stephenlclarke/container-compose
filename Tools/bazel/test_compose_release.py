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
                  'payload': {name: hashes[name] for name in files if name != 'resources/THIRD-PARTY-NOTICES.txt'},
                  'tree': hashes}
        self.put('signed-candidate.json', signed)
        rows = [{'status': 0} for _ in range(67)]
        full = {'passed': True, 'runtime_tests': 27, 'parity_cases': 66, 'rows': rows}
        self.put('full-suite/acceptance.json', full)
        self.put('full-suite-cleared.json', {'verified_under_exclusive_lease': True})
        measurement = {'passed': True, 'lanes': {
            lane: {'raw_seconds': [1.0] * 7} for lane in ('candidate', 'docker')}}
        live = {'passed': True, 'original_full_suite': full,
                'benchmarks': {f'{count}-services-{operation}': measurement
                               for count in (1, 3) for operation in ('up', 'down')}}
        self.put('live.json', live)
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
                 'live_sha256': release.digest(self.evidence / 'live.json'),
                 'notarization_sha256': release.digest(self.evidence / 'notarization.json')})

    def test_prepare_retains_unsigned_truth_and_exact_signed_assets(self) -> None:
        output = self.base / 'staged'
        record = release.prepare(self.evidence, output)
        self.assertFalse(release.read(output / release.PROVENANCE_NAME)
                         ['unsignedCandidate']['receipt']['distributionReady'])
        self.assertFalse(release.read(output / release.PROVENANCE_NAME)['signedDistributionReady'])
        self.assertTrue(release.read(output / release.PROVENANCE_NAME)['signedAndNotarized'])
        self.assertFalse(record['published'])
        self.assertEqual(release.digest(output / release.ARCHIVE_NAME), record['archiveSHA256'])

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
                           for index, name in enumerate((release.ARCHIVE_NAME, release.PROVENANCE_NAME), 1)}}) as publisher:
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
                                                              release.PROVENANCE_NAME), 1)}}
        release.write(output / 'publish-receipt.json', published)
        def downloaded(lock: Path, destination: Path) -> dict:
            name = release.read_lock(lock)['asset']
            destination.mkdir()
            asset = destination / name
            shutil.copyfile(output / name, asset)
            return {'asset': str(asset), 'sha256': release.digest(asset),
                    'releaseId': 42, 'assetId': published['assets'][name]['assetId']}
        original_run = release.subprocess.run
        def run(command: list[str], **kwargs: object) -> object:
            if command[0] == '/usr/bin/ditto':
                return original_run(command, **kwargs)
            return original_run(['/usr/bin/true'], **kwargs)
        with patch.object(release, 'fetch', side_effect=downloaded), patch.object(release.subprocess, 'run', side_effect=run):
            result = release.verify_published(output, self.base / 'consumer')
        self.assertTrue(result['publishedBytesVerified'])
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


if __name__ == '__main__':
    unittest.main()
