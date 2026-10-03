"""Pure rejection tests for Q runtime release source and receipt binding."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ARTIFACTS = Path(__file__).parent
TOOLS = ARTIFACTS.parent
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import q_assets
from artifacts import q_runtime_release as release
import test_q_assets as asset_tests


class QRuntimeReleaseTests(unittest.TestCase):
    def test_runtime_constants_accept_exact_literal_path_wrappers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tools = root / 'Tools/bazel'
            tools.mkdir(parents=True)
            source = tools / 'fork_benchmark.py'
            source.write_text("from pathlib import Path\n"
                              "BAZEL = Path('/fixture/bazel')\n"
                              "STORAGE = Path('/fixture/storage')\n")
            self.assertEqual(release.runtime_constants(root),
                             (Path('/fixture/bazel'), Path('/fixture/storage')))
            source.write_text("import os\nBAZEL = Path(os.environ['BAZEL'])\n"
                              "STORAGE = '/fixture/storage'\n")
            with self.assertRaisesRegex(ValueError, 'not literal maintained inputs'):
                release.runtime_constants(root)

    def _qualification_fixture(self, evidence: Path, qroot: Path, source: str,
                               qualification: dict) -> None:
        tools = qroot / 'Tools/bazel'
        tools.mkdir(parents=True)
        (tools / 'qualification.py').write_text(
            'def stages(evidence, trials):\n    return [("compile", [], [], 1)]\n')
        (evidence / 'acceptance.json').write_text(json.dumps(
            {'passed': True, 'target': 'bazel-qualify', 'failures': []}))
        (evidence / 'qualification.json').write_text(json.dumps(qualification))

    def _admitted_evidence(self, evidence: Path, qroot: Path, source: str) -> None:
        tools = qroot / 'Tools/bazel'
        tools.mkdir(parents=True, exist_ok=True)
        (tools / 'qualification.py').write_text(
            'def stages(evidence, trials):\n    return [("compile", [], [], 1)]\n')
        (tools / 'runtime_integration.py').write_text('LAYERS = ("core", "network")\n')
        (tools / 'runtime_benchmark.py').write_text('FIXTURES = ("start-exit", "warm-exec")\n')
        (tools / 'vm_integration.py').write_text(
            'GPU_SKIPS = ("gpuTest",)\nGPU_SKIP_REASON = "GPU unavailable on this host"\n')
        (tools / 'docker_benchmark.py').write_text(
            "HISTORICAL_DOCKER_SERVER_VERSION = '29.2.1'\n"
            "ADMITTED_DOCKER_SERVER_VERSION = '29.5.2'\n")
        package_pin = '2' * 40
        package_lock = qroot / 'Package.resolved'
        if not package_lock.exists():
            package_lock.write_text(json.dumps({'pins': [
                {'identity': 'containerization', 'state': {'revision': package_pin}}]}))
        else:
            package_pin = json.loads(package_lock.read_text())['pins'][0]['state']['revision']
        pairs = {'containerization': {'repo': '/fixture/containerization', 'stock': '6' * 40,
                    'fork': package_pin, 'products': [], 'tests': []},
                 'container': {'repo': str(qroot.resolve()), 'stock': '4' * 40,
                    'fork': source, 'products': [], 'tests': []}}
        fork_source = tools / 'fork_benchmark.py'
        if not fork_source.exists():
            fork_source.write_text(
                'from pathlib import Path\nSTORAGE = Path(\'/fixture/storage\')\n'
                'BAZEL = Path(\'/fixture/bazel\')\nPAIRS = ' + repr(pairs) + '\n')
        reference_policy = tools / 'benchmark_reference.py'
        if not reference_policy.exists():
            reference_policy.write_text(
                "SOURCE = '3333333333333333333333333333333333333333'\n"
                "ARCHIVE_SHA256 = '" + ('d' * 64) + "'\nNAME = 'historical-fixture.zip'\n")
        evidence.mkdir(parents=True, exist_ok=True)
        archive_sha = 'd' * 64
        reference = {'source': '3' * 40, 'historical': True,
                     'identityLimit': 'Published signed executable differs from measured executable.',
                     'protocol': {'runtimeTrials': 1, 'dockerTrials': 1}}
        (evidence / 'benchmark-reference').mkdir(parents=True, exist_ok=True)
        (evidence / 'benchmark-reference/historical-reference.json').write_text(json.dumps(
            {'reference': reference, 'archiveSHA256': archive_sha, 'historical': True,
             'referenceRebuilt': False, 'referenceRerun': False,
             'identityLimit': reference['identityLimit']}))
        runtime_raw = []
        docker_raw = []
        runtime_matrix = []
        comparison_rows = []
        for fixture, stock_seconds, fork_seconds, docker_seconds in (
                ('start-exit', 2.0, 3.0, 1.0), ('warm-exec', 4.0, 5.0, 2.0)):
            runtime_raw.extend([
                {'lane': 'stock', 'fixture': fixture, 'trial': 1, 'seconds': stock_seconds,
                 'status': 0, 'historical': True, 'reference_archive_sha256': archive_sha},
                {'lane': 'fork', 'fixture': fixture, 'trial': 1, 'seconds': fork_seconds,
                 'status': 0},
            ])
            docker_raw.append({'lane': 'docker', 'fixture': fixture, 'trial': 1,
                'seconds': docker_seconds, 'status': 0, 'historical': True,
                'reference_archive_sha256': archive_sha})
            runtime_matrix.append({'fixture': fixture, 'stock': stock_seconds,
                'fork': fork_seconds, 'ratio': fork_seconds / stock_seconds,
                'worst_trial_ratio': fork_seconds / stock_seconds, 'passed': True,
                'comparison': 'historical', 'historical_lanes': ['stock']})
            comparison_rows.append({'fixture': fixture, 'apple_seconds': stock_seconds,
                'fork_seconds': fork_seconds, 'docker_seconds': docker_seconds,
                'fork_apple_ratio': fork_seconds / stock_seconds,
                'apple_historical': True, 'docker_historical': True,
                'docker_historical_engine_version': '29.2.1',
                'docker_current_engine_version': '29.5.2',
                'fork_docker_ratio': fork_seconds / docker_seconds,
                'worst_fork_docker_ratio': fork_seconds / docker_seconds, 'passed': True})
        for row in runtime_raw:
            if row['lane'] == 'stock':
                row['log'] = 'historical-fixture.zip:benchmark.json/runtime/raw'
        (evidence / 'runtime-benchmark').mkdir(parents=True, exist_ok=True)
        (evidence / 'runtime-benchmark/host.json').write_text(json.dumps({'trials': 1}))
        (evidence / 'runtime-benchmark/results.json').write_text(json.dumps(runtime_raw))
        (evidence / 'runtime-benchmark/matrix.json').write_text(json.dumps(runtime_matrix))
        (evidence / 'docker-benchmark').mkdir(parents=True, exist_ok=True)
        (evidence / 'docker-benchmark/results.json').write_text(json.dumps(docker_raw))
        reference['runtime'] = {'raw': [{key: value for key, value in row.items()
                                         if key not in ('historical', 'reference_archive_sha256', 'log')}
                                        for row in runtime_raw if row['lane'] == 'stock']}
        reference['docker'] = {'raw': [{key: value for key, value in row.items()
                                        if key not in ('historical', 'reference_archive_sha256', 'log')}
                                       for row in docker_raw]}
        reference['componentInputs'] = {
            'container': {'stock': {'revision': '4' * 40}, 'fork': {'revision': '7' * 40}},
            'containerization': {'stock': {'revision': '6' * 40}, 'fork': {'revision': package_pin}}}
        reference['components'] = {'raw': [], 'goRaw': []}
        reference_receipt = {'reference': reference, 'archiveSHA256': archive_sha, 'historical': True,
            'referenceRebuilt': False, 'referenceRerun': False,
            'identityLimit': reference['identityLimit']}
        (evidence / 'benchmark-reference/historical-reference.json').write_text(json.dumps(reference_receipt))
        qualification = {'source': source, 'passed': True, 'failures': [],
                         'stages': [{'name': 'compile', 'state': 'passed', 'blocked_by': []}]}
        (evidence / 'acceptance.json').write_text(json.dumps(
            {'passed': True, 'target': 'bazel-qualify', 'failures': []}))
        (evidence / 'qualification.json').write_text(json.dumps(qualification))
        values = {name: {} for name in release.REQUIRED_RECEIPTS}
        values.update({
            'benchmark-reference/historical-reference.json': {
                'reference': reference, 'archiveSHA256': archive_sha, 'historical': True,
                'referenceRebuilt': False, 'referenceRerun': False,
                'identityLimit': reference['identityLimit']},
            'runtime-benchmark/host.json': {'trials': 1},
            'runtime-benchmark/results.json': runtime_raw,
            'runtime-benchmark/matrix.json': runtime_matrix,
            'components/metadata.json': {'pairs': pairs, 'measured_components': ['container'],
                'historical_reference': True},
            'docker-benchmark/results.json': docker_raw,
            'runtime-smoke/source-inputs.json': {'fork': source},
            'release/release-artifact.json': {'passed': True, 'source': source, 'failures': [],
                'notarized': True, 'notary': {'id': 'notary-fixture', 'status': 'Accepted'},
                'archives': {release.ASSETS[0]: 'a' * 64}},
            'release/notary-status.json': {'id': 'notary-fixture', 'status': 'Accepted'},
            'release/notary-submission.json': {'id': 'notary-fixture'},
            'install/install.json': {'passed': True, 'source': source, 'replacement_started': True,
                'previous_installation_restored': True, 'archive_sha256': 'a' * 64},
            'host-lease.json': {'owner': 2147483647, 'evidence': str(evidence.resolve()),
                'command_lock': str(evidence.resolve() / 'commands.lock'), 'acquired': True,
                'restored': True, 'failures': []},
            'colima-lease.json': {'started_by_this_run': False, 'restored': True, 'failures': []},
            'runtime-smoke/acceptance.json': {'passed': True, 'failures': []},
            'runtime-benchmark/acceptance.json': {'passed': True, 'failures': []},
            'docker-benchmark/acceptance.json': {'passed': True, 'failures': [],
                'historical': True, 'medians': {'start-exit': 1.0, 'warm-exec': 2.0},
                'serverVersionTransition': {'historical': '29.2.1', 'current': '29.5.2'}},
            'docker-reference-admission/acceptance.json': {'passed': True, 'failures': []},
            'runtime-comparison-acceptance.json': {'passed': True, 'reference_verified': True,
                'failures': [], 'dockerServerVersionTransition':
                    {'historical': '29.2.1', 'current': '29.5.2'}},
            'runtime-comparison.json': comparison_rows,
            'github-quality/quality.json': {'passed': True, 'source': source, 'failures': []},
            'integration/integration.json': {'passed': True, 'selection': None, 'coverage': True,
                'layers': ['core', 'network'], 'failures': [], 'stopped_children': []},
            'integration/results.json': [{'component': 'runtime', 'lane': 'fork', 'fixture': 'smoke',
                'trial': 0, 'seconds': 1.0, 'status': 0}],
            'integration/coverage/coverage.json': {'passed': True, 'full_suite': True,
                'restored': True, 'revision': source, 'failures': [], 'covered_lines': 10,
                'executable_lines': 10, 'line_percent': 100.0},
            'combined-coverage/coverage.json': {'passed': True, 'kind': 'unit-and-full-integration',
                'failures': [], 'covered_lines': 20, 'executable_lines': 20, 'line_percent': 100.0},
            'vm-integration/vm-integration.json': {'passed': True, 'cleanup_complete': True,
                'selection': None, 'passed_tests': 1, 'total_tests': 1, 'skipped_tests': 0,
                'skips': [], 'failures': [], 'covered_lines': 10,
                'executable_lines': 10, 'line_percent': 100.0},
            'components/historical-results.json': [],
            'components/go-benchmarks.json': [],
            'components/comparison-review.json': {'completed': True, 'unexpected_failures': [],
                'invalid_timings': []},
            'runtime-smoke/fork-fingerprint.json': {'lane': 'fork'},
            'runtime-smoke/guest-artifact.json': {'schema': 1, 'identity': {'source': '1' * 40}},
            'runtime-smoke/builder-artifact.json': {'schema': 1, 'identity': {'source': '2' * 40}},
        })
        for name, value in values.items():
            path = evidence / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))
        (evidence / 'acceptance.json').write_text(json.dumps(
            {'passed': True, 'target': 'bazel-qualify', 'failures': []}))
        (evidence / 'qualification.json').write_text(json.dumps(qualification))
        services = [{'label': 'com.apple.container.apiserver', 'path': '/private/test/apiserver.plist',
                     'sha256': '0' * 64, 'unloaded': True, 'restored': True}]
        original = evidence / (services[0]['label'] + '.original.plist')
        original.write_bytes(plistlib.dumps({'Label': services[0]['label']}))
        services[0]['sha256'] = hashlib.sha256(original.read_bytes()).hexdigest()
        (evidence / (services[0]['label'] + '.before.txt')).write_text('state = not running\n')
        (evidence / 'service-restoration.json').write_text(json.dumps(services))

    def test_qualification_source_must_match_exact_checkpoint(self):
        source = '2' * 40
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            qroot = evidence / 'q'
            qroot.mkdir()
            self._qualification_fixture(evidence, qroot, source,
                {'source': '3' * 40, 'passed': True, 'failures': [], 'stages': []})
            with self.assertRaisesRegex(ValueError, 'not passed for this source'):
                release.admit_qualification(qroot, evidence, source)

    def test_source_checkpoint_requires_clean_exact_git_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', '-C', str(root), 'config', 'user.email', 'fixture@example.invalid'], check=True)
            subprocess.run(['git', '-C', str(root), 'config', 'user.name', 'Fixture'], check=True)
            (root / 'input.txt').write_text('fixture\n')
            subprocess.run(['git', '-C', str(root), 'add', 'input.txt'], check=True)
            subprocess.run(['git', '-C', str(root), 'commit', '-qm', 'fixture'], check=True)
            self.assertRegex(release.source_checkpoint(root), r'^[0-9a-f]{40}$')
            (root / 'input.txt').write_text('changed\n')
            with self.assertRaisesRegex(ValueError, 'exact clean commit'):
                release.source_checkpoint(root)

    def test_maintained_stage_and_runtime_fixture_inventories_are_read_from_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tools = root / 'Tools/bazel'
            tools.mkdir(parents=True)
            (tools / 'qualification.py').write_text(
                'def stages(evidence, trials):\n    return [("compile", [], [], 1), ("package", [], [], 2)]\n')
            (tools / 'runtime_benchmark.py').write_text('FIXTURES = ("cold", "warm")\n')
            self.assertEqual(release.expected_stages(root), ['compile', 'package'])
            self.assertEqual(release.expected_runtime_fixtures(root), ['cold', 'warm'])

    def test_historical_reference_requires_exact_retained_archive_bytes(self):
        source = '4' * 40
        document = {'source': source, 'historical': True,
                    'identityLimit': 'Published signed executable differs from measured executable.',
                    'docker': {'medians': {'run': 2.0}}}
        import io
        archive_buffer = io.BytesIO()
        with release.zipfile.ZipFile(archive_buffer, 'w') as archive:
            archive.writestr('benchmark.json', release.json_bytes(document))
            archive.writestr('manifest.json', b'{}\n')
        payload = archive_buffer.getvalue()
        archive_sha = hashlib.sha256(payload).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            tools = root / 'Tools/bazel'
            tools.mkdir(parents=True)
            name = 'historical.zip'
            (tools / 'benchmark_reference.py').write_text(
                f"SOURCE = '{source}'\nARCHIVE_SHA256 = '{archive_sha}'\nNAME = '{name}'\n")
            reference_dir = evidence / 'benchmark-reference'
            reference_dir.mkdir()
            (reference_dir / 'historical-reference.json').write_text(json.dumps(
                {'reference': document, 'archiveSHA256': archive_sha, 'historical': True,
                 'referenceRebuilt': False, 'referenceRerun': False,
                 'identityLimit': document['identityLimit']}))
            home = root / 'home'
            cached = (home / 'Library/Application Support/ContainerFamily/retained/container-only/'
                      'benchmark-references' / archive_sha / name)
            cached.parent.mkdir(parents=True)
            cached.write_bytes(payload)
            with mock.patch.object(release.Path, 'home', return_value=home):
                self.assertEqual(release.admitted_historical_reference(root, evidence),
                                 {'source': source, 'archiveSHA256': archive_sha,
                                  'historical': True, 'referenceRebuilt': False,
                                  'referenceRerun': False,
                                  'identityLimit': document['identityLimit']})
                cached.write_bytes(payload + b'changed')
                with self.assertRaisesRegex(ValueError, 'not retained'):
                    release.admitted_historical_reference(root, evidence)

    def test_qualification_json_and_tar_payload_helpers_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            value = evidence / 'receipt.json'
            value.write_text('{"passed": true}\n')
            self.assertEqual(release.load_json(evidence, 'receipt.json'), {'passed': True})
            outside = root / 'outside.json'
            outside.write_text('{}')
            (evidence / 'escaped.json').symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'Missing or escaped qualification receipt'):
                release.load_json(evidence, 'escaped.json')

            payload = b'fixture payload'
            archive_path = root / 'fixture.tar.gz'
            import tarfile
            with tarfile.open(archive_path, 'w:gz') as archive:
                import io
                member = tarfile.TarInfo('bin/tool')
                member.mode = 0o755
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
            expected = hashlib.sha256(payload).hexdigest()
            release.verify_tar_payload(archive_path, {'bin/tool': expected})
            with self.assertRaisesRegex(ValueError, 'member checksum differs'):
                release.verify_tar_payload(archive_path, {'bin/tool': '0' * 64})

    def test_performance_archive_rechecks_exact_members_receipts_and_release_links(self):
        source = '2' * 40
        chain = {'schema': 1, 'source': source, 'layers': {}}
        chain_sha = hashlib.sha256(release.json_bytes(chain)).hexdigest()
        historical = {'source': '3' * 40, 'archiveSHA256': 'd' * 64}
        signed = 'a' * 64
        measured = {'container-measured-fork-arm64.tar.gz': 'b' * 64,
                    'container-measured-fork-arm64.json': 'c' * 64}
        receipt_hash = 'e' * 64
        benchmark = {'source': source, 'native_compiled_chain': chain,
                     'native_compiled_chain_sha256': chain_sha,
                     'signedArchiveSHA256': signed, 'measuredExecutableAssets': measured,
                     'historicalReference': historical,
                     'sourceReceiptSHA256': {'qualification.json': receipt_hash}}
        benchmark_bytes = release.json_bytes(benchmark)
        manifest = {'schema': 1, 'source': source,
                    'kind': 'container-performance-parity-manifest',
                    'signedArchiveSHA256': signed, 'measuredAssets': measured,
                    'nativeCompiledChainSHA256': chain_sha, 'historicalReference': historical,
                    'members': {'benchmark.json': {'sha256': hashlib.sha256(benchmark_bytes).hexdigest(),
                                                   'bytes': len(benchmark_bytes)}}}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'performance.zip'
            with release.zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('benchmark.json', benchmark_bytes)
                archive.writestr('manifest.json', release.json_bytes(manifest))
            bundle = {'assets': {'runtime': {'sha256': signed}}, 'measured_assets': measured,
                      'performance_parity_asset': {
                          'name': 'container-performance-parity-' + source[:8] + '.zip',
                          'sha256': release.digest(path)}}
            self.assertEqual(release.verify_performance_archive(
                path, source, chain, bundle, {'qualification.json': receipt_hash}), benchmark)
            with self.assertRaisesRegex(ValueError, 'receipt hashes differ'):
                release.verify_performance_archive(
                    path, source, chain, bundle, {'qualification.json': 'f' * 64})

    def test_public_labels_positive_values_and_runtime_fingerprints_are_bounded(self):
        self.assertTrue(release.safe_relative_path('component/Package.resolved'))
        self.assertFalse(release.safe_relative_path('../outside'))
        self.assertEqual(release.public_positive(1.25), 1.25)
        with self.assertRaisesRegex(ValueError, 'finite and positive'):
            release.public_positive(float('nan'))
        with self.assertRaisesRegex(ValueError, 'label is unsafe'):
            release.public_label('/private/host/path')
        fingerprint = release.public_fingerprint({'lane': 'fork', 'binaries': {'bin/container': 'a' * 64},
                                                  'kernel_sha256': 'b' * 64})
        self.assertEqual(fingerprint['binariesSHA256']['bin/container'], 'a' * 64)
        with self.assertRaisesRegex(ValueError, 'unsafe binary identities'):
            release.public_fingerprint({'lane': 'fork', 'binaries': {'/private/tool': 'a' * 64}})

    def test_historical_stock_fingerprint_preserves_archived_projection_and_source(self):
        source = '3' * 40
        row = {'binariesSHA256': {'bin/container': 'a' * 64}, 'builder_image': 'example/builder:1',
               'cli_version': '1.1.0', 'init_image': 'example/init:1',
               'kernel_sha256': 'b' * 64, 'lane': 'stock', 'package_lock_sha256': 'c' * 64,
               'workload_image': 'example/workload:1'}
        projected = release.public_historical_fingerprint(row, source)
        self.assertEqual({key: value for key, value in projected.items() if key != 'evidenceSource'}, row)
        self.assertEqual(projected['evidenceSource'], source)
        malformed = dict(row, binaries={'bin/container': 'a' * 64})
        with self.assertRaisesRegex(ValueError, 'schema or binary identities differ'):
            release.public_historical_fingerprint(malformed, source)

    def test_false_or_incomplete_qualification_is_not_prepared(self):
        source = '2' * 40
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / 'evidence'
            evidence.mkdir()
            qroot = Path(temporary) / 'q'
            qroot.mkdir()
            self._qualification_fixture(evidence, qroot, source,
                {'source': source, 'passed': False, 'failures': ['failed'], 'stages': []})
            with self.assertRaisesRegex(ValueError, 'not passed for this source'):
                release.admit_qualification(qroot, evidence, source)
            (evidence / 'qualification.json').write_text(json.dumps(
                {'source': source, 'passed': True, 'failures': [], 'stages': []}))
            with self.assertRaisesRegex(ValueError, 'stage inventory differs'):
                release.admit_qualification(qroot, evidence, source)

    def test_qualified_stage_without_closed_receipt_inventory_is_rejected(self):
        source = '2' * 40
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / 'evidence'
            evidence.mkdir()
            qroot = Path(temporary) / 'q'
            qroot.mkdir()
            self._qualification_fixture(evidence, qroot, source,
                {'source': source, 'passed': True, 'failures': [],
                 'stages': [{'name': 'compile', 'state': 'passed', 'blocked_by': []}]})
            with self.assertRaisesRegex(ValueError, 'Missing or escaped qualification receipt'):
                release.admit_qualification(qroot, evidence, source)

    def test_full_qualification_receipt_admission_accepts_closed_synthetic_checkpoint(self):
        source = '2' * 40
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary) / 'evidence'
            qroot = Path(temporary) / 'q'
            self._admitted_evidence(evidence, qroot, source)
            records = release.admit_qualification(qroot, evidence, source)
            self.assertEqual(records['release/release-artifact.json']['source'], source)
            self.assertEqual(records['runtime-smoke/fork-fingerprint.json']['lane'], 'fork')

    def test_full_qualification_admission_rejects_live_owner_and_incomplete_cleanup(self):
        source = '2' * 40
        for failure in ('live-owner', 'missing-service-snapshot', 'partial-integration',
                        'wrong-vm-skip', 'forged-runtime-comparison'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                evidence = Path(temporary) / 'evidence'
                qroot = Path(temporary) / 'q'
                self._admitted_evidence(evidence, qroot, source)
                if failure == 'live-owner':
                    path = evidence / 'host-lease.json'
                    value = json.loads(path.read_text())
                    value['owner'] = os.getpid()
                    path.write_text(json.dumps(value))
                    message = 'Host lease owner is still active'
                elif failure == 'missing-service-snapshot':
                    (evidence / 'com.apple.container.apiserver.original.plist').unlink()
                    message = 'Original service registration snapshot differs'
                elif failure == 'partial-integration':
                    path = evidence / 'integration/integration.json'
                    value = json.loads(path.read_text())
                    value['layers'] = ['core']
                    path.write_text(json.dumps(value))
                    message = 'Full integration selection or restored coverage'
                elif failure == 'wrong-vm-skip':
                    path = evidence / 'vm-integration/vm-integration.json'
                    value = json.loads(path.read_text())
                    value.update(passed_tests=1, total_tests=2, skipped_tests=1,
                                 skips=[{'test': 'unknown', 'reason': 'unreviewed'}])
                    path.write_text(json.dumps(value))
                    message = 'VM skipped-test dispositions differ'
                else:
                    path = evidence / 'runtime-comparison.json'
                    value = json.loads(path.read_text())
                    value[0]['fork_docker_ratio'] = 1.0
                    path.write_text(json.dumps(value))
                    message = 'does not recompute from its raw trial evidence'
                with self.assertRaisesRegex(ValueError, message):
                    release.admit_qualification(qroot, evidence, source)

    def test_q_asset_validator_accepts_explicit_source_argument_only(self):
        source = '2' * 40
        bundle = {'qualified_container_source': '3' * 40}
        with self.assertRaisesRegex(RuntimeError, 'wrong qualification'):
            q_assets.validate(bundle, {}, {}, qualified_source=source)
        self.assertEqual(q_assets.Q, 'a1effeeaf8c7c1d48b4773262a2d5218dcd5817d')

    def test_complete_native_provenance_validates_for_explicit_future_source(self):
        fixture = asset_tests.NativeQAssetTests()
        fixture.setUp()
        try:
            source = 'd' * 40
            bundle = json.loads(json.dumps(fixture.bundle))
            bundle['qualified_container_source'] = source
            bundle['assets']['runtime']['source'] = source
            bundle['native_compiled_chain']['source'] = source
            bundle['native_compiled_chain']['release']['source'] = source
            bundle['native_compiled_chain']['coverage']['source'] = source
            bundle['performance_parity_asset']['name'] = 'container-performance-parity-' + source[:8] + '.zip'
            asset_tests.NativeQAssetTests.seal(bundle)
            q_assets.validate(bundle, fixture.locks, bundle['qualified_helpers_sha256'],
                              qualified_source=source)
            self.assertNotEqual(q_assets.Q, source)
        finally:
            fixture.doCleanups()

    def test_future_runtime_source_does_not_relabel_published_lower_sources(self):
        fixture = asset_tests.NativeQAssetTests()
        fixture.setUp()
        try:
            source = 'd' * 40
            bundle = json.loads(json.dumps(fixture.bundle))
            bundle['qualified_container_source'] = source
            bundle['assets']['runtime']['source'] = source
            bundle['native_compiled_chain']['source'] = source
            bundle['native_compiled_chain']['release']['source'] = source
            bundle['native_compiled_chain']['coverage']['source'] = source
            bundle['performance_parity_asset']['name'] = 'container-performance-parity-' + source[:8] + '.zip'
            bundle['assets']['guest']['source'] = 'e' * 40
            asset_tests.NativeQAssetTests.seal(bundle)
            with self.assertRaisesRegex(RuntimeError, 'source graph changed'):
                q_assets.validate(bundle, fixture.locks, bundle['qualified_helpers_sha256'],
                                  qualified_source=source)
        finally:
            fixture.doCleanups()

    def test_native_graph_source_mismatch_is_rejected_before_layer_admission(self):
        source = '2' * 40
        chain = {'schema': 1, 'source': '3' * 40, 'layers': {}, 'release': {}, 'coverage': {},
                 'sourceReceiptSHA256': {}, 'measuredAssets': {}, 'signedArchiveSHA256': '0' * 64,
                 'interpretation': 'test projection'}
        bundle = {'native_compiled_chain': chain,
                  'native_compiled_chain_sha256': hashlib.sha256(release.json_bytes(chain)).hexdigest()}
        with self.assertRaisesRegex(RuntimeError, 'projection source differs'):
            q_assets.validate_native_chain(bundle, qualified_source=source)

    def test_public_measurement_projection_rejects_malformed_evidence(self):
        with self.assertRaisesRegex(ValueError, 'trial or status'):
            release.public_measurements([{'component': 'container', 'lane': 'fork',
                                          'fixture': 'run', 'trial': -1,
                                          'status': 0, 'seconds': 1.0}])

    def test_public_measurements_keep_raw_historical_values_and_provenance(self):
        current, historical = '2' * 40, '3' * 40
        rows = release.public_measurements([
            {'component': 'container', 'lane': 'fork', 'fixture': 'run', 'trial': 1,
             'seconds': 2.5, 'status': 0, 'timestamp': '2026-10-03T00:00:00Z',
             'historical': False},
            {'component': 'container', 'lane': 'stock', 'fixture': 'run', 'trial': 1,
             'seconds': 2.0, 'status': 0, 'timestamp': '2026-09-01T00:00:00Z',
             'historical': True, 'reference_archive_sha256': 'a' * 64}],
            qualified_source=current, historical_source=historical)
        self.assertEqual(rows[0]['seconds'], 2.5)
        self.assertEqual(rows[0]['timestamp'], '2026-10-03T00:00:00Z')
        self.assertEqual(rows[0]['evidenceSource'], current)
        self.assertEqual(rows[1]['evidenceSource'], historical)
        self.assertEqual(rows[1]['referenceArchiveSHA256'], 'a' * 64)

        go = release.public_measurements([{'lane': 'stock', 'fixture': 'prefetch', 'trial': 0,
                                           'iterations': 1024, 'ns_per_op': 8.25,
                                           'historical': True}], go=True,
                                         qualified_source=current, historical_source=historical)
        self.assertTrue(go[0]['historical'])
        self.assertEqual(go[0]['evidenceSource'], historical)

    def test_public_matrix_keeps_phase_comparison_and_historical_lane_status(self):
        projected = release.public_matrix([{'component': 'container', 'fixture': 'cli-run-help',
                                             'stock': 1.0, 'fork': 1.5, 'ratio': 1.5,
                                             'worst_trial_ratio': 2.0, 'passed': True,
                                             'comparison': 'historical',
                                             'historical_lanes': ['stock'],
                                             'phase_ratios': {'first-invocation': 1.2,
                                                              'repeated-invocation': 2.0}}])
        self.assertEqual(projected[0]['phase_ratios']['repeated-invocation'], 2.0)
        self.assertEqual(projected[0]['historical_lanes'], ['stock'])

    def test_runtime_comparison_preserves_historical_and_observed_engine_identities(self):
        row = {'fixture': 'image-save', 'apple_seconds': 2.0, 'fork_seconds': 3.0,
               'docker_seconds': 1.0, 'fork_apple_ratio': 1.5, 'fork_docker_ratio': 3.0,
               'worst_fork_docker_ratio': 4.0, 'apple_historical': True,
               'docker_historical': True, 'docker_historical_engine_version': '29.2.1',
               'docker_current_engine_version': '29.5.2', 'passed': True}
        projected = release.public_runtime_comparison(
            [row], '2' * 40, '3' * 40, {'historical': '29.2.1', 'current': '29.5.2'})
        self.assertEqual(projected[0]['forkEvidenceSource'], '2' * 40)
        self.assertEqual(projected[0]['dockerEvidenceSource'], '3' * 40)
        self.assertEqual(projected[0]['docker_current_engine_version'], '29.5.2')
        row['docker_current_engine_version'] = '29.2.1'
        with self.assertRaisesRegex(ValueError, 'differ from preserved engine admission'):
            release.public_runtime_comparison(
                [row], '2' * 40, '3' * 40, {'historical': '29.2.1', 'current': '29.5.2'})

    def test_semantic_review_retains_disposition_counts_and_measurements(self):
        review = {'phase': 'all', 'completed': True, 'compatibility_measured': True,
                  'compatible': False, 'freshly_measured_components': ['container'],
                  'unexpected_failures': [], 'invalid_timings': [],
                  'expected_differences': [{'component': 'container', 'lane': 'fork',
                                           'fixture': 'nameValid', 'trial': 1,
                                           'seconds': 0.2, 'status': 3}],
                  'historical_expected_differences': [],
                  'superseded_historical_differences': []}
        result = release.public_semantic_review(review)
        self.assertEqual(result['dispositions']['expected_differences']['count'], 1)
        self.assertEqual(result['dispositions']['expected_differences']['rows'][0]['seconds'], 0.2)
        review['unexpected_failures'] = [{'component': 'container'}]
        with self.assertRaisesRegex(ValueError, 'incomplete or has unadmitted failures'):
            release.public_semantic_review(review)

    def test_native_verifier_modules_are_loaded_from_explicit_container_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / 'Tools/bazel/artifacts'
            package.mkdir(parents=True)
            (package / 'native_consumer.py').write_text('consumer = True\n')
            (package / 'native_layers.py').write_text('layers = True\n')
            consumer, layers = release.q_modules(root)
            self.assertEqual(Path(consumer.__file__).resolve(), (package / 'native_consumer.py').resolve())
            self.assertEqual(Path(layers.__file__).resolve(), (package / 'native_layers.py').resolve())

    def test_native_verifier_relative_symlink_cannot_escape_explicit_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / 'Tools/bazel/artifacts'
            package.mkdir(parents=True)
            outside = root / 'outside.py'
            outside.write_text('value = True\n')
            (package / 'native_consumer.py').write_text('from . import helper\n')
            (package / 'native_layers.py').write_text('value = True\n')
            (package / 'helper.py').symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'outside its explicit checkout'):
                release.q_modules(root)

    def test_docker_projection_preserves_finite_admitted_server_transition(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            tools = root / 'Tools/bazel'
            tools.mkdir(parents=True)
            (tools / 'docker_benchmark.py').write_text(
                "HISTORICAL_DOCKER_SERVER_VERSION = '29.2.1'\n"
                "ADMITTED_DOCKER_SERVER_VERSION = '29.5.2'\n")
            admission = {'current': {'serverVersion': '29.5.2'},
                         'historical': {'serverVersion': '29.2.1'},
                         'serverVersionTransition': {'historical': '29.2.1', 'current': '29.5.2'},
                         'configuredEnvironment': {}, 'liveProfile': {}, 'selectedDockerContext': 'colima',
                         'usableMemoryBytes': 1024, 'dockerInfoLogSHA256': 'a' * 64}
            (evidence / 'docker-benchmark').mkdir()
            (evidence / 'docker-benchmark/engine-admission.json').write_text(json.dumps(admission))
            (evidence / 'docker-benchmark/acceptance.json').write_text(json.dumps(
                {'serverVersionTransition': admission['serverVersionTransition']}))
            projected = release.public_docker_admission(root, evidence, 'docker-benchmark')
            self.assertEqual(projected['current']['serverVersion'], '29.5.2')
            admission['serverVersionTransition']['current'] = '29.2.1'
            (evidence / 'docker-benchmark/engine-admission.json').write_text(json.dumps(admission))
            with self.assertRaisesRegex(ValueError, 'does not preserve observed'):
                release.public_docker_admission(root, evidence, 'docker-benchmark')


if __name__ == '__main__':
    unittest.main()
