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

"""Hermetic success-path regression for the staged Q runtime release producer."""

from __future__ import annotations

import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from unittest import mock

import q_assets
from artifacts import q_runtime_release as release
import test_q_runtime_release as admission_tests
import test_q_assets as asset_tests


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


def archive_bytes(files: dict[str, bytes]) -> bytes:
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode='w:gz') as archive:
        for name, payload in sorted(files.items()):
            member = tarfile.TarInfo(name)
            member.mode = 0o755 if name.startswith('bin/') or '/bin/' in name else 0o644
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
    return result.getvalue()


class QRuntimeReleaseFlowTests(unittest.TestCase):
    def test_prepare_publish_verify_rederives_real_products_with_transport_stub(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            qroot, evidence, home = base / 'q', base / 'evidence', base / 'home'
            compose = Path(__file__).resolve().parents[3]
            output = base / 'candidate'
            scratch = base / 'scratch'
            source_placeholder = 'b' * 40

            # Build a clean synthetic source checkpoint with the maintained
            # fixture inventories and authenticated lower locks in its tree.
            tools = qroot / 'Tools/bazel'
            tools.mkdir(parents=True)
            fixture_pairs = {
                'containerization': {'repo': '/fixture/containerization', 'stock': '6' * 40,
                    'fork': q_assets.GUEST, 'products': [], 'tests': []},
                'container': {'repo': '/fixture/container', 'stock': '4' * 40,
                    'fork': '5' * 40, 'products': [], 'tests': []},
                'swift-nio-ssl': {'repo': '/fixture/swift-nio-ssl', 'stock': '8' * 40,
                    'fork': '9' * 40, 'products': [], 'tests': []},
                'grpc-swift-nio-transport': {'repo': '/fixture/grpc-swift-nio-transport',
                    'stock': 'a' * 40, 'fork': 'b' * 40, 'products': [], 'tests': []},
                'container-builder-shim': {'repo': '/fixture/container-builder-shim',
                    'stock': 'c' * 40, 'fork': 'd' * 40, 'products': [], 'tests': []}}
            (tools / 'fork_benchmark.py').write_text(
                "from pathlib import Path\nSTORAGE = Path('/fixture/storage')\nBAZEL = Path('/fixture/bazel')\n"
                'PAIRS = ' + repr(fixture_pairs) + '\n')
            (tools / 'qualification.py').write_text(
                'def stages(evidence, trials):\n    return [("compile", [], [], 1)]\n')
            (tools / 'runtime_benchmark.py').write_text(
                'FIXTURES = ("start-exit", "warm-exec")\n')
            (tools / 'runtime_integration.py').write_text('LAYERS = ("core", "network")\n')
            (tools / 'vm_integration.py').write_text(
                'GPU_SKIPS = ("gpuTest",)\nGPU_SKIP_REASON = "GPU unavailable on this host"\n')
            (tools / 'docker_benchmark.py').write_text(
                "HISTORICAL_DOCKER_SERVER_VERSION = '29.2.1'\n"
                "ADMITTED_DOCKER_SERVER_VERSION = '29.5.2'\n")
            for name in release.HELPERS:
                path = tools / (name + '.py')
                if not path.exists():
                    path.write_text('# immutable fixture helper\n')
            (tools / 'artifacts/lower-locks').mkdir(parents=True)
            pins = [{'identity': 'containerization', 'state': {'revision': q_assets.GUEST}}]
            write_json(qroot / 'Package.resolved', {'pins': pins})
            lower_data = {}
            lower_refs = {}
            for name, source in (('guest', q_assets.GUEST), ('builder', q_assets.BUILDER)):
                asset = 'guest.oci.tar' if name == 'guest' else 'builder.oci.tar'
                payload = (name + ' OCI fixture').encode()
                archive_path = base / (name + '.oci.tar')
                archive_path.write_bytes(payload)
                sha = hashlib.sha256(payload).hexdigest()
                reference = 'ghcr.io/fixture/' + name + ':1.0'
                lower_refs[name] = reference
                lower_data[name] = (archive_path, sha, source, asset, reference)
                write_json(tools / 'artifacts/lower-locks' / (name + '.lock.json'), {
                    'schema': 1, 'repository': 'stephenlclarke/container-' + name,
                    'tag': 'fixture-' + name, 'targetCommit': source,
                    'asset': asset, 'sha256': sha, 'releaseId': 300 + len(lower_data),
                    'assetId': 400 + len(lower_data)})

            # The real Q reference reader consumes this exact two-member ZIP.
            historical_source = '3' * 40
            stock_fingerprint = {'binariesSHA256': {'bin/container': 'a' * 64},
                'builder_image': lower_refs['builder'],
                'cli_version': 'container CLI version 1.0.0 (build: release, commit: abcdef0)',
                'init_image': lower_refs['guest'], 'kernel_sha256': 'b' * 64,
                'lane': 'stock', 'package_lock_sha256': 'c' * 64,
                'workload_image': 'docker.io/library/alpine@sha256:' + 'd' * 64}
            reference = {'source': historical_source, 'historical': True,
                'identityLimit': 'Archived signed executable identity is not the measured private executable.',
                'runtimeLaneFingerprints': {'stock': stock_fingerprint},
                'componentInputs': {
                    component: {lane: {'inputCount': 1,
                        'inputManifestSHA256': hashlib.sha256(f'{component}:{lane}'.encode()).hexdigest(),
                        'lockAndModuleInputSHA256': {}, 'repository': pair['repo'], 'revision': pair[lane]}
                        for lane in ('stock', 'fork')}
                    for component, pair in {
                        'containerization': {'repo': 'apple/containerization', 'stock': '6'*40, 'fork': '7'*40},
                        'container': {'repo': 'apple/container', 'stock': '4'*40, 'fork': '7'*40},
                        'swift-nio-ssl': {'repo': 'apple/swift-nio-ssl', 'stock': '8'*40, 'fork': '9'*40},
                        'grpc-swift-nio-transport': {'repo': 'apple/grpc-swift-nio-transport',
                            'stock': 'a'*40, 'fork': 'b'*40},
                        'container-builder-shim': {'repo': 'apple/container-builder-shim',
                            'stock': 'c'*40, 'fork': 'd'*40}}.items()},
                'runtime': {'raw': [
                    {'component': 'runtime', 'fixture': 'start-exit', 'lane': 'stock',
                     'trial': 1, 'seconds': 2.0, 'status': 0},
                    {'component': 'runtime', 'fixture': 'warm-exec', 'lane': 'stock',
                     'trial': 1, 'seconds': 4.0, 'status': 0}]},
                'docker': {'raw': [
                    {'component': 'docker', 'fixture': 'start-exit', 'lane': 'docker',
                     'trial': 1, 'seconds': 1.0, 'status': 0},
                    {'component': 'docker', 'fixture': 'warm-exec', 'lane': 'docker',
                     'trial': 1, 'seconds': 2.0, 'status': 0}]},
                'components': {'raw': [
                    {'component': component, 'fixture': 'api', 'lane': lane, 'trial': 1,
                     'seconds': seconds, 'status': 0}
                    for component, values in {'container': (1.1, 1.0),
                        'containerization': (1.2, 1.1), 'swift-nio-ssl': (1.3, 1.2),
                        'grpc-swift-nio-transport': (1.4, 1.3),
                        'container-builder-shim': (1.5, 1.4)}.items()
                    for lane, seconds in zip(('stock', 'fork'), values)],
                    'goRaw': [{'fixture': 'build', 'lane': 'stock', 'trial': 0,
                               'iterations': 10, 'ns_per_op': 110.0},
                              {'fixture': 'build', 'lane': 'fork', 'trial': 0,
                               'iterations': 10, 'ns_per_op': 100.0}]},
                'protocol': {'runtimeTrials': 1, 'dockerTrials': 1}}
            zipped = io.BytesIO()
            with zipfile.ZipFile(zipped, 'w') as archive:
                archive.writestr('benchmark.json', release.json_bytes(reference))
                archive.writestr('manifest.json', b'{}\n')
            reference_bytes = zipped.getvalue()
            reference_sha = hashlib.sha256(reference_bytes).hexdigest()
            name = 'historical-fixture.zip'
            (tools / 'benchmark_reference.py').write_text(
                f"SOURCE = '{historical_source}'\nARCHIVE_SHA256 = '{reference_sha}'\nNAME = '{name}'\n")
            locks = qroot / 'Tools/bazel/artifacts/lower-locks'
            locks.mkdir(parents=True, exist_ok=True)
            subprocess.run(['git', 'init', '-q', str(qroot)], check=True)
            subprocess.run(['git', '-C', str(qroot), 'config', 'user.email', 'fixture@example.invalid'], check=True)
            subprocess.run(['git', '-C', str(qroot), 'config', 'user.name', 'Q fixture'], check=True)
            subprocess.run(['git', '-C', str(qroot), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(qroot), 'commit', '-qm', 'qualification fixture'], check=True)
            source = subprocess.check_output(['git', '-C', str(qroot), 'rev-parse', 'HEAD'], text=True).strip()

            # Reuse the complete deterministic admission fixture, then replace
            # only the evidence payloads that the real projection consumes.
            admission = admission_tests.QRuntimeReleaseTests()
            admission._admitted_evidence(evidence, qroot, source)
            historical_receipt = {'reference': reference, 'archiveSHA256': reference_sha,
                'historical': True, 'referenceRebuilt': False, 'referenceRerun': False,
                'identityLimit': reference['identityLimit']}
            write_json(evidence / 'benchmark-reference/historical-reference.json', historical_receipt)
            cache = (home / 'Library/Application Support/ContainerFamily/retained/container-only/'
                     'benchmark-references' / reference_sha / name)
            cache.parent.mkdir(parents=True)
            cache.write_bytes(reference_bytes)
            for path in (evidence / 'runtime-benchmark/results.json',
                         evidence / 'docker-benchmark/results.json'):
                rows = json.loads(path.read_text())
                for row in rows:
                    row['component'] = 'runtime' if path.parent.name == 'runtime-benchmark' else 'docker'
                    if row.get('historical') is True:
                        row['reference_archive_sha256'] = reference_sha
                write_json(path, rows)
            old_compare = json.loads((evidence / 'runtime-comparison-acceptance.json').read_text())
            old_compare['dockerServerVersionTransition'] = {'historical': '29.2.1', 'current': '29.5.2'}
            write_json(evidence / 'runtime-comparison-acceptance.json', old_compare)

            native = asset_tests.NativeQAssetTests()
            native.setUp()
            self.addCleanup(native.doCleanups)
            chain = copy.deepcopy(native.chain)
            chain['source'] = source
            chain['release']['source'] = source
            chain['coverage']['source'] = source
            payload_names = list(native.bundle['runtime']['payload'])
            payload_files = {path: ('distribution:' + path).encode() for path in payload_names}
            payload_hashes = {path: hashlib.sha256(data).hexdigest()
                              for path, data in payload_files.items()}
            for product, row in chain['release']['products'].items():
                row['signedDistributionSHA256'] = payload_hashes[row['measuredPath']]
            measured_paths = {row['measuredPath'] for row in chain['release']['products'].values()}
            helper_paths = set(chain['release']['semanticHelperSHA256'])
            measured_files = {path: ('measured:' + path).encode()
                              for path in sorted(measured_paths | helper_paths)}
            measured_hashes = {path: hashlib.sha256(data).hexdigest()
                               for path, data in measured_files.items()}
            for mode in ('release', 'coverage'):
                for product, row in chain[mode]['products'].items():
                    row['signedMeasuredSHA256'] = measured_hashes[row['measuredPath']]
                chain[mode]['semanticHelperSHA256'] = {path: measured_hashes[path]
                                                       for path in sorted(helper_paths)}

            # The same source-input and copied native receipts are present in
            # each qualifying phase; raw hashes are computed from these files.
            for phase in ('runtime-smoke', 'runtime-benchmark', 'release'):
                for filename in ('compiled-consumer.json', 'fork-fingerprint.json', 'source-inputs.json'):
                    if filename == 'fork-fingerprint.json':
                        continue
                    write_json(evidence / phase / filename, {'fixture': True})
            for filename in ('coverage-compiled-consumer.json', 'fork-fingerprint.json'):
                write_json(evidence / 'integration/coverage' / filename, {'fixture': True})
            for phase in ('runtime-smoke', 'runtime-benchmark', 'release'):
                for suffix in ('.events.json', '-native-aquery.json'):
                    base_name = 'fork-release' + suffix
                    (evidence / phase / base_name).write_bytes(b'fixture raw native proof\n')
            (evidence / 'integration/coverage/fork-runtime-coverage.events.json').write_bytes(b'fixture coverage events\n')
            (evidence / 'integration/coverage/fork-runtime-coverage-native-aquery.json').write_bytes(b'fixture coverage graph\n')
            fingerprint = {'lane': 'fork', 'binaries': measured_hashes,
                'kernel_sha256': 'b' * 64, 'init_image': lower_refs['guest'],
                'builder_image': lower_refs['builder'],
                'workload_image': stock_fingerprint['workload_image'], 'cli_version': '1.1.0',
                'package_lock_sha256': 'c' * 64, 'init_archive_sha256': lower_data['guest'][1],
                'builder_archive_sha256': lower_data['builder'][1],
                'compiled_consumer_sha256': hashlib.sha256(b'{"fixture": true}\n').hexdigest(),
                'unsigned_native_inputs': {product: row['unsignedSHA256']
                    for product, row in chain['release']['products'].items()}}
            for phase in ('runtime-smoke', 'runtime-benchmark', 'release'):
                write_json(evidence / phase / 'fork-fingerprint.json', fingerprint)
                write_json(evidence / phase / 'compiled-consumer.json', {'fixture': True})
                write_json(evidence / phase / 'source-inputs.json', {'fork': source})
            write_json(evidence / 'integration/coverage/fork-fingerprint.json', fingerprint)
            coverage_receipt = evidence / 'integration/coverage/coverage-compiled-consumer.json'
            write_json(coverage_receipt, {'fixture': True})
            for phase in ('runtime-smoke', 'runtime-benchmark', 'release'):
                chain['sourceReceiptSHA256'][phase + '/compiled-consumer.json'] = release.digest(evidence / phase / 'compiled-consumer.json')
                chain['sourceReceiptSHA256'][phase + '/fork-fingerprint.json'] = release.digest(evidence / phase / 'fork-fingerprint.json')
                chain['sourceReceiptSHA256'][phase + '/source-inputs.json'] = release.digest(evidence / phase / 'source-inputs.json')
                chain['sourceReceiptSHA256'][phase + '/fork-release.events.json'] = release.digest(evidence / phase / 'fork-release.events.json')
                chain['sourceReceiptSHA256'][phase + '/fork-release-native-aquery.json'] = release.digest(evidence / phase / 'fork-release-native-aquery.json')
            chain['sourceReceiptSHA256']['integration/coverage/coverage-compiled-consumer.json'] = release.digest(coverage_receipt)
            chain['sourceReceiptSHA256']['integration/coverage/fork-fingerprint.json'] = release.digest(evidence / 'integration/coverage/fork-fingerprint.json')
            chain['sourceReceiptSHA256']['integration/coverage/fork-runtime-coverage.events.json'] = release.digest(evidence / 'integration/coverage/fork-runtime-coverage.events.json')
            chain['sourceReceiptSHA256']['integration/coverage/fork-runtime-coverage-native-aquery.json'] = release.digest(evidence / 'integration/coverage/fork-runtime-coverage-native-aquery.json')
            for phase in ('runtime-smoke', 'runtime-benchmark', 'release'):
                chain['sourceReceiptSHA256'][phase + '/compiled-consumer.json'] = fingerprint['compiled_consumer_sha256']
                chain[{'runtime-smoke': 'release', 'runtime-benchmark': 'release', 'release': 'release'}[phase]]['compiledConsumerSHA256'] = fingerprint['compiled_consumer_sha256']
            chain['release']['buildEventsSHA256'] = chain['sourceReceiptSHA256']['runtime-smoke/fork-release.events.json']
            chain['release']['actionGraphSHA256'] = chain['sourceReceiptSHA256']['runtime-smoke/fork-release-native-aquery.json']
            chain['coverage']['compiledConsumerSHA256'] = chain['sourceReceiptSHA256']['integration/coverage/coverage-compiled-consumer.json']
            chain['coverage']['buildEventsSHA256'] = chain['sourceReceiptSHA256']['integration/coverage/fork-runtime-coverage.events.json']
            chain['coverage']['actionGraphSHA256'] = chain['sourceReceiptSHA256']['integration/coverage/fork-runtime-coverage-native-aquery.json']

            for name, (archive_path, sha, pin, asset, reference_uri) in lower_data.items():
                write_json(evidence / f'runtime-smoke/{name}-artifact.json', {
                    'schema': 1, 'identity': {'source': pin}, 'archive': str(archive_path),
                    'archive_sha256': sha, 'reference': reference_uri, 'binaries': {}})
            write_json(evidence / 'runtime-smoke/fork-fingerprint.json', fingerprint)
            write_json(evidence / 'runtime-benchmark/fork-fingerprint.json', fingerprint)
            write_json(evidence / 'runtime-benchmark/stock-fingerprint.json', stock_fingerprint)

            # Signed distribution and measured-private archives are distinct
            # bytes, but both are checked by the producer's real tar verifier.
            signed_tar = archive_bytes(payload_files)
            measured_manifest = {path: {'sha256': measured_hashes[path],
                'mode': 0o755 if path.startswith('bin/') or '/bin/' in path else 0o644,
                'size': len(measured_files[path])} for path in measured_files}
            measured_tar = archive_bytes(measured_files)
            release_dir = evidence / 'release'
            release_dir.mkdir(exist_ok=True)
            measured = {'source': source, 'lane': 'fork', 'resigned': False,
                'payload': measured_manifest, 'benchmark_provenance_sha256': {}}
            for filename in ('fork-fingerprint.json', 'source-inputs.json', 'acceptance.json',
                             'results.json', 'matrix.json', 'host.json'):
                measured['benchmark_provenance_sha256'][filename] = release.digest(
                    evidence / 'runtime-benchmark' / filename)
            measured_json = release.json_bytes(measured)
            signed_path = release_dir / release.ASSETS[0]
            measured_tar_path = release_dir / release.ASSETS[2]
            measured_json_path = release_dir / release.ASSETS[3]
            signed_path.write_bytes(signed_tar)
            measured_tar_path.write_bytes(measured_tar)
            measured_json_path.write_bytes(measured_json)
            chain['signedArchiveSHA256'] = hashlib.sha256(signed_tar).hexdigest()
            chain['measuredAssets'] = {release.ASSETS[2]: hashlib.sha256(measured_tar).hexdigest(),
                                       release.ASSETS[3]: hashlib.sha256(measured_json).hexdigest()}
            runtime_payload = payload_hashes
            release_record = {'passed': True, 'source': source, 'failures': [], 'notarized': True,
                'notary': {'id': 'notary-fixture', 'status': 'Accepted'},
                'archives': {release.ASSETS[0]: hashlib.sha256(signed_tar).hexdigest(),
                             release.ASSETS[2]: hashlib.sha256(measured_tar).hexdigest(),
                             release.ASSETS[3]: hashlib.sha256(measured_json).hexdigest()},
                'payload': runtime_payload,
                'compiled_consumer_sha256': fingerprint['compiled_consumer_sha256'],
                'measured_products': dict(measured, manifest={}, manifest_sha256='e' * 64)}
            write_json(release_dir / 'release-artifact.json', release_record)
            chain['signedArchiveSHA256'] = release_record['archives'][release.ASSETS[0]]
            write_json(evidence / 'install/install.json', {'passed': True, 'source': source,
                'replacement_started': True, 'previous_installation_restored': True,
                'archive_sha256': release_record['archives'][release.ASSETS[0]]})

            # Fill the public parity source inputs with small, path-free rows.
            metadata_pairs = copy.deepcopy(fixture_pairs)
            metadata_pairs['container']['repo'] = str(qroot.resolve())
            metadata_pairs['container']['fork'] = source
            metadata = {'swift': 'Apple Swift version fixture\nTarget: arm64-apple-macosx',
                'bazel_sha256': '1' * 64, 'third_party_lock': '2' * 64,
                'harness_revision': '3' * 40,
                'pairs': metadata_pairs,
                'measured_components': ['containerization', 'container'],
                'historical_reference': True}
            write_json(evidence / 'components/metadata.json', metadata)
            for component in ('container', 'containerization'):
                write_json(evidence / f'components/{component}-fork-inputs.json',
                           {'Sources/Fixture+Testing.swift': hashlib.sha256(
                               f'{component}:fork'.encode()).hexdigest()})
            fresh_rows = [{'component': component, 'lane': 'fork', 'fixture': 'api',
                           'trial': 1, 'seconds': seconds, 'status': 0}
                          for component, seconds in (('container', 1.0), ('containerization', 1.1))]
            write_json(evidence / 'components/results.json', fresh_rows)
            historical_rows = [dict(row, historical=True, reference_archive_sha256=reference_sha)
                for row in reference['components']['raw']
                if row['component'] not in metadata['measured_components'] or row['lane'] == 'stock']
            write_json(evidence / 'components/historical-results.json', historical_rows)
            matrix = [{'component': component, 'fixture': 'api', 'stock': stock, 'fork': fork,
                       'ratio': fork / stock, 'worst_trial_ratio': fork / stock, 'passed': True,
                       'comparison': 'historical', 'historical_lanes': ['stock']}
                      for component, stock, fork in (('container', 1.1, 1.0),
                          ('containerization', 1.2, 1.1))]
            write_json(evidence / 'components/matrix.json', matrix)
            write_json(evidence / 'components/go-benchmarks.json', [
                {'lane': 'stock', 'fixture': 'build', 'trial': 0, 'iterations': 10,
                 'ns_per_op': 110.0, 'historical': True, 'reference_archive_sha256': reference_sha},
                {'lane': 'fork', 'fixture': 'build', 'trial': 0, 'iterations': 10,
                 'ns_per_op': 100.0, 'historical': True, 'reference_archive_sha256': reference_sha}])
            write_json(evidence / 'components/go-matrix.json', [{'component': 'builder', 'fixture': 'build',
                'stock': 110.0, 'fork': 100.0, 'ratio': 100.0 / 110.0,
                'worst_trial_ratio': 100.0 / 110.0, 'passed': True}])
            write_json(evidence / 'components/comparison-review.json', {'phase': 'all',
                'completed': True, 'compatibility_measured': True, 'compatible': False,
                'freshly_measured_components': ['containerization', 'container'], 'unexpected_failures': [],
                'invalid_timings': [], 'expected_differences': [],
                'historical_expected_differences': [], 'superseded_historical_differences': []})
            for phase in ('docker-benchmark', 'docker-reference-admission'):
                admission_row = {'current': {'serverVersion': '29.5.2'},
                    'historical': {'serverVersion': '29.2.1'},
                    'serverVersionTransition': {'historical': '29.2.1', 'current': '29.5.2'},
                    'configuredEnvironment': {}, 'liveProfile': {}, 'selectedDockerContext': 'colima',
                    'usableMemoryBytes': {}, 'dockerInfoLogSHA256': {}}
                write_json(evidence / f'{phase}/engine-admission.json', admission_row)
                acceptance_path = evidence / f'{phase}/acceptance.json'
                acceptance = json.loads(acceptance_path.read_text())
                acceptance['serverVersionTransition'] = admission_row['serverVersionTransition']
                write_json(acceptance_path, acceptance)
            # Link all public graph identities to the actual fixture payloads.
            chain['native_chain_fixture_only'] = True
            # The native verifier's schema is intentionally exercised by the
            # real q_assets validator; retain only its maintained fields.
            chain.pop('native_chain_fixture_only')
            native_locks = {}
            for group, row in chain['layers'].items():
                native_locks[group] = {}
                for kind, asset_row in row['assets'].items():
                    native_locks[group][kind] = {'repository': row['repository'], 'tag': row['tag'],
                        'targetCommit': row['targetCommit'], 'releaseId': row['releaseId'],
                        'asset': asset_row['name'], 'assetId': asset_row['assetId'],
                        'sha256': asset_row['sha256'], 'lockSHA256': asset_row['lockSHA256']}

            comparison = json.loads((evidence / 'runtime-comparison-acceptance.json').read_text())
            transition = comparison['dockerServerVersionTransition']
            runtime_results_path = evidence / 'runtime-benchmark/results.json'
            runtime_results_bytes = runtime_results_path.read_bytes()
            runtime_results = json.loads(runtime_results_bytes)
            stock_sample = next(row for row in runtime_results if row['lane'] == 'stock')
            stock_sample['seconds'] += 1
            write_json(runtime_results_path, runtime_results)
            with self.assertRaisesRegex(ValueError, 'authenticated archive'):
                release.admit_runtime_comparison(qroot, evidence, ['start-exit', 'warm-exec'], transition,
                                                  source=source)
            stock_sample['seconds'] -= 1
            runtime_results_path.write_bytes(runtime_results_bytes)

            component_path = evidence / 'components/historical-results.json'
            component_rows = json.loads(component_path.read_text())
            component_rows[0]['seconds'] += 1
            write_json(component_path, component_rows)
            with self.assertRaisesRegex(ValueError, 'component raw measurements'):
                release.admit_runtime_comparison(qroot, evidence, ['start-exit', 'warm-exec'], transition,
                                                  source=source)
            component_rows[0]['seconds'] -= 1
            write_json(component_path, component_rows)
            component_rows.pop()
            write_json(component_path, component_rows)
            with self.assertRaisesRegex(ValueError, 'component raw measurements differ'):
                release.admit_runtime_comparison(qroot, evidence, ['start-exit', 'warm-exec'], transition,
                                                  source=source)
            component_rows.append(historical_rows[-1])
            write_json(component_path, component_rows)

            go_path = evidence / 'components/go-benchmarks.json'
            go_rows = json.loads(go_path.read_text())
            go_rows[0]['ns_per_op'] += 1
            write_json(go_path, go_rows)
            with self.assertRaisesRegex(ValueError, 'Go component raw measurements'):
                release.admit_runtime_comparison(qroot, evidence, ['start-exit', 'warm-exec'], transition,
                                                  source=source)
            go_rows[0]['ns_per_op'] -= 1
            write_json(go_path, go_rows)

            runtime_results = json.loads(runtime_results_path.read_text())
            fork_sample = next(row for row in runtime_results if row['lane'] == 'fork')
            fork_sample['seconds'] = 30
            write_json(runtime_results_path, runtime_results)
            with self.assertRaisesRegex(ValueError, 'Runtime matrix does not recompute'):
                release.admit_runtime_comparison(qroot, evidence, ['start-exit', 'warm-exec'], transition,
                                                  source=source)
            fork_sample['seconds'] = 3
            runtime_results_path.write_bytes(runtime_results_bytes)

            original_load = release.load_compose_module
            published_assets: dict[str, dict] = {}
            publish_calls = 0
            fetch_calls = 0
            next_id = iter(range(700, 710))
            def load_with_transport(name: str, path: Path):
                module = original_load(name, path)
                if 'release_asset' in name:
                    module.publication_journal_path = lambda journal_root, _repository, _tag, _owner: (
                        journal_root / 'fixture-publication-journal.json')
                    def remote(lock: dict):
                        return {'id': lock['releaseId']}, {'id': lock['assetId']}
                    def publish_assets(_repo, _tag, _source, _title, _body, files, **_kwargs):
                        nonlocal publish_calls
                        publish_calls += 1
                        self.assertIs(_kwargs.get('resume'), True)
                        self.assertEqual(_kwargs.get('scratch'), scratch)
                        self.assertEqual(_kwargs.get('journal_root'), output)
                        self.assertEqual(_kwargs.get('owner'),
                            'q-runtime-release-' + _source + '-' + _tag)
                        rows = {path.name: (published_assets[path.name]
                            if path.name in published_assets else {'assetId': next(next_id)})
                            for path in files}
                        published_assets.update(rows)
                        if publish_calls == 1:
                            raise RuntimeError('simulated interruption after remote draft assets')
                        journal = module.publication_journal_path(
                            _kwargs['journal_root'], _repo, _tag, _kwargs['owner'])
                        journal.write_text('fixture resumable publication journal\n')
                        return {'schema': 1, 'repository': 'stephenlclarke/container',
                            'tag': _tag, 'targetCommit': _source, 'releaseId': 999,
                            'assets': {path.name: {'sha256': release.digest(path),
                                'assetId': rows[path.name]['assetId']} for path in files},
                            'publicationJournal': str(journal)}
                    def fetch(lock_path: Path, destination: Path):
                        nonlocal fetch_calls
                        fetch_calls += 1
                        lock = json.loads(lock_path.read_text())
                        destination.mkdir(parents=True)
                        asset = destination / lock['asset']
                        shutil.copyfile(output / 'assets' / lock['asset'], asset)
                        receipt = {'schema': 1, 'repository': lock['repository'], 'tag': lock['tag'],
                            'targetCommit': lock['targetCommit'], 'releaseId': 999,
                            'assetId': published_assets[lock['asset']]['assetId'], 'asset': str(asset),
                            'sha256': lock['sha256'],
                            'lockSHA256': hashlib.sha256(lock_path.read_bytes()).hexdigest(),
                            'githubImmutable': None}
                        write_json(destination / 'fetch-receipt.json', receipt)
                        return {'releaseId': 999, 'assetId': published_assets[lock['asset']]['assetId']}
                    module.release_asset = remote
                    module.publish_assets = publish_assets
                    module.fetch = fetch
                return module

            with mock.patch.object(release.Path, 'home', return_value=home), \
                 mock.patch.object(release, 'native_chain', return_value=(chain, native_locks)), \
                 mock.patch.object(release, 'load_compose_module', side_effect=load_with_transport):
                prepared = release.prepare(qroot, evidence, compose, output, scratch=scratch)
                self.assertFalse(prepared['authority']['releaseAuthority'])
                self.assertEqual(len(prepared['assets']), 5)
                prepared_path = output / 'preparation.json'
                prepared['tag'] += '-mutated'
                write_json(prepared_path, prepared)
                with self.assertRaisesRegex(ValueError, 'release tag differs'):
                    release.publish(compose, qroot, evidence, output)
                prepared['tag'] = 'layer-runtime-' + source[:12] + '-' + release.digest(
                    output / 'assets' / release.ASSETS[0])[:12]
                write_json(prepared_path, prepared)
                with self.assertRaisesRegex(RuntimeError, 'simulated interruption'):
                    release.publish(compose, qroot, evidence, output, scratch=scratch)
                publication = release.publish(compose, qroot, evidence, output, scratch=scratch)
                self.assertEqual(publication['releaseId'], 999)
                self.assertEqual(release.publish(compose, qroot, evidence, output, scratch=scratch), publication)
                prepared['tag'] += '-mutated'
                write_json(prepared_path, prepared)
                with self.assertRaisesRegex(ValueError, 'release tag differs'):
                    release.verify(compose, qroot, evidence, output, scratch=scratch)
                prepared['tag'] = 'layer-runtime-' + source[:12] + '-' + release.digest(
                    output / 'assets' / release.ASSETS[0])[:12]
                write_json(prepared_path, prepared)
                publication_path = output / 'publication.json'
                publication_bytes = publication_path.read_bytes()
                publication['repository'] = 'attacker/elsewhere'
                write_json(publication_path, publication)
                with self.assertRaisesRegex(ValueError, 'repository, tag, source'):
                    release.verify(compose, qroot, evidence, output, scratch=scratch)
                publication['repository'] = 'stephenlclarke/container'
                publication_path.write_bytes(publication_bytes)
                bad_lock_path = output / (release.ASSETS[0] + '.lock.json')
                lock_bytes = bad_lock_path.read_bytes()
                bad_lock = json.loads(lock_bytes)
                bad_lock['targetCommit'] = 'a' * 40
                write_json(bad_lock_path, bad_lock)
                with self.assertRaisesRegex(ValueError, 'deterministic prepared identity'):
                    release.verify(compose, qroot, evidence, output, scratch=scratch)
                bad_lock_path.write_bytes(lock_bytes)
                partial = output / 'downloaded' / release.ASSETS[0]
                partial.mkdir(parents=True)
                (partial / release.ASSETS[0]).write_bytes(b'interrupted partial asset')
                verified = release.verify(compose, qroot, evidence, output, scratch=scratch)
                self.assertTrue(verified['passed'])
                after_first_fetch = fetch_calls
                self.assertEqual(after_first_fetch, len(prepared['projections']['files']))
                self.assertEqual(release.verify(compose, qroot, evidence, output, scratch=scratch), verified)
                self.assertEqual(fetch_calls, after_first_fetch)
                missing_receipt = output / 'downloaded' / release.ASSETS[1] / 'fetch-receipt.json'
                missing_receipt.unlink()
                release.verify(compose, qroot, evidence, output, scratch=scratch)
                self.assertEqual(fetch_calls, after_first_fetch + 1)
                mismatched_receipt = output / 'downloaded' / release.ASSETS[2] / 'fetch-receipt.json'
                receipt = json.loads(mismatched_receipt.read_text())
                receipt['assetId'] += 1
                write_json(mismatched_receipt, receipt)
                release.verify(compose, qroot, evidence, output, scratch=scratch)
                self.assertEqual(fetch_calls, after_first_fetch + 2)
                self.assertEqual(verified['source'], source)
                parity = output / 'downloaded' / prepared['projections']['files'][-1] / prepared['projections']['files'][-1]
                self.assertEqual(release.digest(parity), prepared['assets'][parity.name])
                self.assertIn('components/container-fork-inputs.json', prepared['source_receipts'])
                self.assertIn('components/containerization-fork-inputs.json', prepared['source_receipts'])
                self.assertNotIn('components/container-stock-inputs.json', prepared['source_receipts'])
                self.assertNotIn('components/container-builder-shim-fork-inputs.json',
                                 prepared['source_receipts'])
                with zipfile.ZipFile(parity) as archive:
                    projected = json.loads(archive.read('benchmark.json'))
                sources = projected['components']['sources']
                self.assertFalse(sources['container']['fork']['historical'])
                self.assertTrue(sources['container']['stock']['historical'])
                self.assertTrue(sources['containerization']['fork']['historical'] is False)
                self.assertTrue(sources['container-builder-shim']['fork']['historical'])
