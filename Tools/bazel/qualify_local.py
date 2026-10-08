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

"""Qualify one immutable Compose source using Q Container and retained receipts."""
from __future__ import annotations

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import statistics
import subprocess
import sys
import tarfile
import time
import uuid
import zipfile
from xml.etree import ElementTree

from hosted_quality import admit as admit_hosted, current_context
import benchmark_evidence
import cli_process
import compose_release
import fixture_cache
import full_suite
import full_suite_scratch
from artifacts.release_asset import cached_fetch, read_lock, release_asset as published_release_asset
from input_identity import source_identity, verify as verify_source
from q_assets import fetch_assets as fetch_q_assets, revalidate as revalidate_q_assets
from prebuilt_parity_tests import test_workspace
from run import RETAINED, ROOT, SSD
from retain_evidence import restore_candidate
sys.path.insert(0, str(ROOT))
from Tools.parity import performance_matrix_capacity

Q = fixture_cache.Q_SOURCE
CONTAINERIZATION = fixture_cache.CONTAINERIZATION_SOURCE
Q_ROOT: Path | None = None
Q_EVIDENCE: Path | None = None
OUTPUT = RETAINED / 'local-final'
CAPTURE_OUTPUT = RETAINED / 'benchmark-reference-capture'
TRIALS = 7
ORIGINAL_FIXTURE_IMAGES = ('alpine:3.20', 'alpine:3.21', 'alpine:latest',
                           'ghcr.io/linuxcontainers/alpine:3.20', 'busybox:latest',
                           'docker/compose-bridge-kubernetes@sha256:'
                           '4ffd3f23f377b1fdd9d0195732980e7534a8975c8a210a12681dc803c002f761',
                           'docker/compose-bridge-helm@sha256:'
                           '7aeee453c13045dcec87b92cb13973871ed8c72d5ca1e9365886487782ea2b09')
API_SOCKET_IMAGE = ('docker.io/library/docker:29.2.1-cli@sha256:'
                    'cab69e2d0a1a2ea9a1ce1060252f439e83483ae41ec09317aecb33b08a0656a5')
FIXTURE_CACHE = RETAINED / f'fixture-image-cache-q{Q[:8]}-c{CONTAINERIZATION[:4]}'
BENCHMARK_LOCK = ROOT / 'Tools/bazel/artifacts/benchmark-reference.lock.json'
BENCHMARK_CACHE = RETAINED / 'release-asset-cache'
DOCKER_COMPOSE_VERSION = '5.5.1'
COLIMA_MEMORY_MAX = 8 * 1024**3
RUNTIME_VM_BUDGET = 6 * 1024**3
PERFORMANCE_MATRIX_SERVICES_MAX = 50
PERFORMANCE_MATRIX_SERVICE_MEMORY_MIB = 200
PERFORMANCE_MATRIX_SERVICE_OVERHEAD_MIB = 32
PERFORMANCE_MATRIX_HOST_HEADROOM = 4 * 1024**3
STAGES = (
    ('go', 'build', '//Tools/compose-normalizer:all', 'enhanced', 900),
    ('spi-stock', 'test', '//:ComposeRuntimeSPITests', 'stock', 900),
    ('spi-enhanced', 'test', '//:ComposeRuntimeSPITests', 'enhanced', 900),
    ('core-stock', 'test', '//:ComposeCoreTests', 'stock', 1800),
    ('core-enhanced', 'test', '//:ComposeCoreTests', 'enhanced', 1800),
    ('provider-stock', 'test', '//:ComposeEngineRuntimeTests', 'stock', 1800),
    ('provider-enhanced', 'test', '//:ComposeContainerRuntimeTests', 'enhanced', 1800),
    ('cli-stock', 'test', '//Tools/bazel:cli_contracts', 'stock', 900),
    ('cli-enhanced', 'test', '//Tools/bazel:cli_contracts', 'enhanced', 900),
    ('unit-stock', 'test', '//:unit_stock', 'stock', 2400),
    ('unit-enhanced', 'test', '//:unit_enhanced', 'enhanced', 2400),
    ('coverage-stock', 'coverage', '//:coverage_stock', 'stock', 2400),
    ('coverage-enhanced', 'coverage', '//:coverage_enhanced', 'enhanced', 2400),
    ('package-tests', 'test', '//Tools/bazel:package_tests', 'enhanced', 900),
    ('docs', 'test', '//:documentation_tests', 'enhanced', 1800),
    ('package', 'build', '//:candidate_archive', 'enhanced', 2400),
    ('package-smoke', 'test', '//Tools/bazel:package_smoke', 'enhanced', 900),
)


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for part in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(part)
    return h.hexdigest()


def write(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(['git', '-C', str(root), *args], text=True, timeout=30).strip()


def existing_directory(parser: argparse.ArgumentParser, option: str, value: Path) -> Path:
    """Resolve an explicitly selected real directory, rejecting symlink paths."""
    try:
        resolved = value.resolve(strict=True)
    except OSError:
        parser.error(f'{option} must name an existing directory')
    if (not resolved.is_dir() or resolved.is_symlink()
            or resolved != Path(os.path.abspath(value))):
        parser.error(f'{option} must name an existing non-symlink directory')
    return resolved


def host_budget() -> dict:
    memory = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True, timeout=5))
    profiles = [json.loads(row) for row in subprocess.check_output(['colima', 'list', '--json'], text=True, timeout=20).splitlines()]
    matches = [row for row in profiles if row.get('name') == 'default']
    if len(matches) != 1 or matches[0].get('arch') != 'aarch64' or matches[0].get('runtime') != 'docker':
        raise RuntimeError('Expected one default arm64 Docker Colima profile')
    colima = matches[0]
    if (memory < 24 * 1024**3 or not 0 < colima.get('memory', 0) <= COLIMA_MEMORY_MAX
            or memory - colima['memory'] - RUNTIME_VM_BUDGET < 8 * 1024**3):
        raise RuntimeError('Host/Colima/Compose runtime memory budget is insufficient')
    if colima.get('status') not in ('Stopped', 'Running'):
        raise RuntimeError('Default Colima profile is changing state')
    if colima['status'] == 'Running' and subprocess.check_output(
            ['docker', '--context', 'colima', 'ps', '-q'], text=True, timeout=20).strip():
        raise RuntimeError('Existing Docker workloads prevent isolated qualification')
    return {'host_bytes': memory, 'colima_bytes': colima['memory'],
            'runtime_envelope_bytes': RUNTIME_VM_BUDGET,
            'benchmark_services_max': 3,
            'benchmark_service_memory_mib': benchmark_evidence.SERVICE_MEMORY_MIB,
            'full_suite_services_max': 10, 'full_suite_service_memory_mib': 256,
            'builder_memory_mib': 2048,
            'minimum_free_budget_bytes': 8 * 1024**3,
            'services_max': 3,
            'memory_per_service_mib': benchmark_evidence.SERVICE_MEMORY_MIB}


def performance_matrix_budget() -> dict:
    """Fail closed unless the explicitly capped 50-service run fits the host."""
    base = host_budget()
    snapshot = performance_matrix_capacity.capture()
    admitted = performance_matrix_capacity.admit(
        snapshot, PERFORMANCE_MATRIX_SERVICE_MEMORY_MIB)
    if (base['host_bytes'] != snapshot['host_bytes']
            or base['colima_bytes'] != snapshot['colima_bytes']):
        raise RuntimeError('Host/Colima capacity changed during broad matrix admission')
    return {**admitted, 'preflight_budget': base}


def benchmark_budget() -> dict:
    return {**host_budget(),
            'service_memory_max_mib': max(benchmark_evidence.COUNTS)
            * benchmark_evidence.SERVICE_MEMORY_MIB,
            'trials': TRIALS}


def benchmark_host_snapshot() -> dict:
    processes = []
    output = subprocess.check_output(['ps', '-axo', 'pid=,pcpu=,comm='],
                                     text=True, timeout=10)
    for line in output.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            try:
                processes.append({'pid': int(parts[0]), 'cpu_percent': float(parts[1]),
                                  'command': parts[2]})
            except ValueError:
                continue
    return {'observed_unix_seconds': time.time(), 'load_average': os.getloadavg(),
            'power': subprocess.check_output(['pmset', '-g', 'ps'], text=True,
                                             timeout=10).strip(),
            'top_cpu_processes': sorted(processes, key=lambda row: row['cpu_percent'],
                                        reverse=True)[:8]}


def benchmark_environment() -> dict:
    """Bind historical timings to the same laptop and VM resource envelope."""
    profiles = [json.loads(row) for row in subprocess.check_output(
        ['colima', 'list', '--json'], text=True, timeout=20).splitlines()]
    matches = [row for row in profiles if row.get('name') == 'default']
    if len(matches) != 1:
        raise RuntimeError('Default Colima benchmark profile is ambiguous')
    profile = matches[0]
    config = Path.home() / '.colima/default/colima.yaml'
    colima = shutil.which('colima')
    docker = shutil.which('docker')
    if not colima or not docker or not config.is_file():
        raise RuntimeError('Benchmark reference host tools or Colima configuration are missing')
    return {'architecture': platform.machine(),
            'host_model': subprocess.check_output(['sysctl', '-n', 'hw.model'],
                                                  text=True, timeout=5).strip(),
            'host_cpus': int(subprocess.check_output(['sysctl', '-n', 'hw.ncpu'],
                                                     text=True, timeout=5)),
            'host_memory_bytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'],
                                                              text=True, timeout=5)),
            'macos_version': subprocess.check_output(['sw_vers', '-productVersion'],
                                                    text=True, timeout=5).strip(),
            'macos_build': subprocess.check_output(['sw_vers', '-buildVersion'],
                                                  text=True, timeout=5).strip(),
            'colima': {'arch': profile.get('arch'), 'runtime': profile.get('runtime'),
                       'cpus': profile.get('cpus'), 'memory_bytes': profile.get('memory'),
                       'disk_bytes': profile.get('disk'), 'config_sha256': sha(config),
                       'binary_sha256': sha(Path(colima).resolve())},
            'docker_cli_sha256': sha(Path(docker).resolve())}


def docker_compose_binary_identity() -> dict:
    """Describe the installed released Homebrew bottle without rebuilding it."""
    prefix = Path(subprocess.check_output(['brew', '--prefix', 'docker-compose'],
                                          text=True, timeout=30).strip())
    binary = prefix / 'lib/docker/cli-plugins/docker-compose'
    metadata = json.loads(subprocess.check_output(
        ['brew', 'info', '--json=v2', '--installed', 'docker-compose'],
        text=True, timeout=30))
    matches = [item for item in metadata.get('formulae', [])
               if item.get('name') == 'docker-compose']
    if len(matches) != 1 or not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError('Installed Docker Compose bottle is unavailable')
    formula = matches[0]
    installed = formula.get('installed', [])
    bottles = formula.get('bottle', {}).get('stable', {}).get('files', {})
    if (len(installed) != 1 or installed[0].get('version') != DOCKER_COMPOSE_VERSION
            or installed[0].get('poured_from_bottle') is not True
            or len(bottles) != 1):
        raise RuntimeError('Docker Compose is not the expected installed Homebrew bottle')
    bottle = next(iter(bottles.values()))
    return {'formula': 'docker-compose', 'version': DOCKER_COMPOSE_VERSION,
            'sha256': sha(binary), 'bottleSHA256': bottle['sha256'],
            'bottleURL': bottle['url']}


def docker_engine_identity() -> dict:
    value = json.loads(subprocess.check_output(
        ['docker', '--context', 'colima', 'version', '--format', '{{json .Server}}'],
        text=True, timeout=20))
    result = {'version': value.get('Version'), 'apiVersion': value.get('ApiVersion'),
              'os': value.get('Os'), 'arch': value.get('Arch'),
              'kernelVersion': value.get('KernelVersion')}
    if any(not isinstance(item, str) or not item for item in result.values()):
        raise RuntimeError('Docker Engine provenance is incomplete after owned Colima start')
    return result


def verify_selected_docker_compose(expected_sha256: str) -> None:
    """Prove `docker compose` selects the bottle whose bytes were recorded."""
    plugins = json.loads(subprocess.check_output(
        ['docker', '--context', 'colima', 'info', '--format', '{{json .ClientInfo.Plugins}}'],
        text=True, timeout=20))
    matches = [row for row in plugins if isinstance(row, dict) and row.get('Name') == 'compose']
    if len(matches) != 1 or not isinstance(matches[0].get('Path'), str):
        raise RuntimeError('Docker did not identify one selected Compose CLI plugin')
    selected = Path(matches[0]['Path'])
    if not selected.is_file() or sha(selected.resolve()) != expected_sha256:
        raise RuntimeError('Docker selected a different Compose plugin than the recorded bottle')


def admit_benchmark_reference(evidence: Path, image: str) -> dict:
    """Fetch one published baseline before any Bazel or live qualification stage."""
    if not BENCHMARK_LOCK.is_file():
        raise RuntimeError('Published benchmark reference lock is missing; use explicit reference capture first')
    lock = read_lock(BENCHMARK_LOCK)
    receipt = cached_fetch(BENCHMARK_LOCK, BENCHMARK_CACHE)
    asset = Path(receipt['asset'])
    document = json.loads(asset.read_text())
    workload = benchmark_evidence.workload(image)
    environment = benchmark_environment()
    benchmark_evidence.validate_reference(document, workload, environment)
    result = {'schema': 1, 'lock_sha256': sha(BENCHMARK_LOCK),
              'asset_sha256': lock['sha256'], 'asset': str(asset),
              'repository': lock['repository'], 'tag': lock['tag'],
              'target_commit': lock['targetCommit'], 'release_id': receipt['releaseId'],
              'asset_id': receipt['assetId'], 'offline_cache_reuse': receipt['offlineCacheReuse'],
              'workload_sha256': benchmark_evidence.digest(workload),
              'environment_sha256': benchmark_evidence.digest(environment)}
    write(evidence / 'benchmark-reference.json', result)
    return {'receipt': result, 'document': document}


def revalidate_benchmark_reference(evidence: Path, image: str) -> dict:
    result = json.loads((evidence / 'benchmark-reference.json').read_text())
    lock = read_lock(BENCHMARK_LOCK)
    asset = Path(result['asset'])
    if (result.get('lock_sha256') != sha(BENCHMARK_LOCK)
            or result.get('asset_sha256') != lock['sha256']
            or not asset.is_file() or asset.is_symlink() or sha(asset) != lock['sha256']):
        raise RuntimeError('Published benchmark reference changed after admission')
    document = json.loads(asset.read_text())
    benchmark_evidence.validate_reference(document, benchmark_evidence.workload(image),
                                          benchmark_environment())
    return document


def admit_previous_candidate(evidence: Path, lock_path: Path, reference: dict) -> dict:
    """Consume a pinned earlier Compose product and its portable results as data."""
    provenance_lock = read_lock(lock_path)
    if (provenance_lock['repository'] != compose_release.REPOSITORY or
            provenance_lock['asset'] != compose_release.PROVENANCE_NAME):
        raise RuntimeError('Previous Compose lock must pin published product provenance')
    published = cached_fetch(lock_path, BENCHMARK_CACHE)
    provenance = json.loads(Path(published['asset']).read_text())
    companion = provenance.get('evidenceCompanion', {})
    if (provenance.get('source') != provenance_lock['targetCommit'] or
            provenance.get('signedAndNotarized') is not True or
            provenance.get('notary', {}).get('status') != 'Accepted' or
            not isinstance(companion, dict) or
            companion.get('asset') != compose_release.EVIDENCE_NAME or
            not isinstance(companion.get('sha256'), str) or
            not re.fullmatch(r'[0-9a-f]{64}', companion['sha256']) or
            not re.fullmatch(r'[0-9a-f]{64}', provenance.get('signedArchiveSHA256', '')) or
            not re.fullmatch(r'[0-9a-f]{40}', provenance.get('qualifiedContainer', '')) or
            not isinstance(provenance.get('lowerReleasedAssets'), dict) or
            not {'runtime', 'guest', 'builder'} <= set(provenance['lowerReleasedAssets']) or
            any(not re.fullmatch(r'[0-9a-f]{64}', provenance['lowerReleasedAssets'][name].get(
                'sha256', '')) for name in ('runtime', 'guest', 'builder'))):
        raise RuntimeError('Previous Compose provenance lacks accepted signed product/evidence')
    directory = evidence / 'previous-candidate'
    directory.mkdir()
    receipts = {}
    for name, expected in ((compose_release.ARCHIVE_NAME, provenance['signedArchiveSHA256']),
                           (compose_release.EVIDENCE_NAME, companion['sha256'])):
        asset_lock = {'schema': 1, 'repository': provenance_lock['repository'],
                      'tag': provenance_lock['tag'],
                      'targetCommit': provenance_lock['targetCommit'],
                      'asset': name, 'sha256': expected}
        asset_lock_path = directory / (name + '.lock.json')
        write(asset_lock_path, asset_lock)
        if name == compose_release.ARCHIVE_NAME:
            release, metadata = published_release_asset(asset_lock)
            if (release.get('id') != published['releaseId'] or
                    metadata.get('digest') != 'sha256:' + expected):
                raise RuntimeError('Previous signed Compose asset metadata differs from provenance')
            receipts[name] = {'releaseId': release['id'], 'assetId': metadata['id']}
        else:
            receipts[name] = cached_fetch(asset_lock_path, BENCHMARK_CACHE)
            if receipts[name]['releaseId'] != published['releaseId']:
                raise RuntimeError('Previous Compose assets are from different releases')
    companion_path = Path(receipts[compose_release.EVIDENCE_NAME]['asset'])
    compose_release.inspect_evidence(companion_path, provenance)
    with zipfile.ZipFile(companion_path) as source:
        benchmark = json.loads(source.read('benchmark.json'))
        parity = json.loads(source.read('parity-summary.json'))
    if (benchmark.get('workload') != reference['workload'] or
            benchmark.get('workloadSHA256') != reference['workloadSHA256'] or
            benchmark.get('environment') != reference['environment'] or
            benchmark.get('signedArchiveSHA256') != provenance['signedArchiveSHA256'] or
            benchmark.get('candidateBinarySHA256') != provenance['signedPayload']['bin/compose']):
        raise RuntimeError('Previous Compose benchmark has a different workload or host envelope')
    samples = benchmark_evidence.checked_samples(benchmark['candidateSamples'], 'candidate')
    for name in ('1-services-up', '1-services-down', '3-services-up', '3-services-down'):
        expected = [row['seconds'] for row in samples if row['fixture'] == name]
        if benchmark['measurements'][name]['lanes']['candidate']['raw_seconds'] != expected:
            raise RuntimeError('Previous Compose raw trials differ from the published report')
    record = {'schema': 1, 'historical': True, 'source': provenance['source'],
              'repository': provenance_lock['repository'], 'tag': provenance_lock['tag'],
              'lockPath': str(lock_path.resolve()), 'lockSHA256': sha(lock_path),
              'releaseId': published['releaseId'], 'provenanceAssetId': published['assetId'],
              'provenanceSHA256': provenance_lock['sha256'],
              'archiveAssetId': receipts[compose_release.ARCHIVE_NAME]['assetId'],
              'archiveSHA256': provenance['signedArchiveSHA256'],
              'companionAssetId': receipts[compose_release.EVIDENCE_NAME]['assetId'],
              'companionSHA256': companion['sha256'],
              'binarySHA256': provenance['signedPayload']['bin/compose'],
              'qualifiedContainer': provenance.get('qualifiedContainer'),
              'lowerReleasedAssets': provenance.get('lowerReleasedAssets'),
              'capturedAt': benchmark['candidateCapture']['capturedAt'],
              'workloadSHA256': reference['workloadSHA256'], 'samples': samples,
              'parityCases': [{'name': row['name'], 'status': row['status'],
                               'sourceSHA256': row['sourceSHA256'],
                               'assertionOutputSHA256': row['assertionOutputSHA256']}
                              for row in parity['cases']]}
    write(directory / 'admission.json', record)
    return record


def compare_previous_candidate(evidence: Path, live: dict, previous: dict) -> dict:
    """Compare current raw samples with a released old candidate, without running it."""
    lock_path = Path(previous['lockPath'])
    if (not lock_path.is_file() or lock_path.is_symlink() or
            sha(lock_path) != previous['lockSHA256']):
        raise RuntimeError('Previous Compose release lock changed after admission')
    rows = json.loads((evidence / 'runtime/compose-operations.json').read_text())['rows']
    current = benchmark_evidence.checked_samples(rows, 'candidate')
    outcomes = {}
    for name in ('1-services-up', '1-services-down', '3-services-up', '3-services-down'):
        now = [row['seconds'] for row in current if row['fixture'] == name]
        old = [row['seconds'] for row in previous['samples'] if row['fixture'] == name]
        current_p95 = sorted(now)[math.ceil(.95 * len(now)) - 1]
        old_p95 = sorted(old)[math.ceil(.95 * len(old)) - 1]
        outcomes[name] = {'currentRawSeconds': now, 'historicalRawSeconds': old,
                          'currentMedianSeconds': statistics.median(now),
                          'historicalMedianSeconds': statistics.median(old),
                          'currentP95Seconds': current_p95,
                          'historicalP95Seconds': old_p95,
                          'medianRatio': statistics.median(now) / statistics.median(old),
                          'p95Ratio': current_p95 / old_p95}
    full = json.loads((evidence / 'full-suite/acceptance.json').read_text())
    current_cases = {row['fixture']: row['status'] for row in full['rows']}
    old_cases = {row['name']: row['status'] for row in previous['parityCases']}
    if set(current_cases) != set(old_cases) or any(value != 0 for value in current_cases.values()):
        raise RuntimeError('Current and historical Compose parity case inventories differ')
    q_assets = json.loads((evidence / 'q-assets/q-assets.json').read_text())
    current_lower = {name: {'sha256': asset['sha256'],
                            'release': q_assets['releases'][name]}
                     for name, asset in q_assets['assets'].items()}
    result = {'schema': 1, 'historical': True, 'previousSource': previous['source'],
              'previousCompanionSHA256': previous['companionSHA256'],
              'currentLiveSHA256': sha(evidence / 'live.json'), 'measurements': outcomes,
              'previousQualifiedContainer': previous['qualifiedContainer'],
              'currentQualifiedContainer': Q,
              'previousLowerReleasedAssets': previous['lowerReleasedAssets'],
              'currentLowerReleasedAssets': current_lower,
              'runtimeStackChanged': (previous['qualifiedContainer'] != Q or
                                      previous['lowerReleasedAssets'] != current_lower),
              'parityOutcomeComparison': {'samePassedCaseNames': sorted(current_cases),
                                          'observationReuse': False},
              'dockerSlowdownGateUnchanged': all(row['passed'] for row in live['benchmarks'].values())}
    write(evidence / 'previous-candidate-comparison.json', result)
    return result


def portable_benchmark(evidence: Path, live: dict, signed: dict,
                       notarization: dict, image: str) -> dict:
    """Export accepted raw samples without machine paths or private logs."""
    admitted = json.loads((evidence / 'benchmark-reference.json').read_text())
    reference = revalidate_benchmark_reference(evidence, image)
    operations = json.loads((evidence / 'runtime/compose-operations.json').read_text())
    candidate = benchmark_evidence.checked_samples(operations['rows'], 'candidate')
    document = {'schema': 1, 'source': signed['source'],
                'signedArchiveSHA256': notarization['archive_sha256'], 'passed': True,
                'workload': reference['workload'],
                'workloadSHA256': reference['workloadSHA256'],
                'environment': reference['environment'],
                'candidateBinarySHA256': signed['payload']['bin/compose'],
                'historicalReference': True,
                'reference': {'repository': admitted['repository'], 'tag': admitted['tag'],
                              'targetCommit': admitted['target_commit'],
                              'releaseId': admitted['release_id'], 'assetId': admitted['asset_id'],
                              'assetSHA256': admitted['asset_sha256'],
                              'referenceBinary': reference['referenceBinary'],
                              'capture': reference['capture']},
                'candidateSamples': candidate,
                'candidateCapture': {
                    'capturedAt': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
                    'hostBeforeSHA256': sha(evidence / 'runtime/benchmark-host-before.json'),
                    'hostAfterSHA256': sha(evidence / 'runtime/benchmark-host-after.json'),
                    'hostBefore': benchmark_evidence.host_projection(json.loads(
                        (evidence / 'runtime/benchmark-host-before.json').read_text())),
                    'hostAfter': benchmark_evidence.host_projection(json.loads(
                        (evidence / 'runtime/benchmark-host-after.json').read_text())),
                    'warmups': benchmark_evidence.checked_samples(
                        live['benchmark_candidate_warmups'], 'candidate', trial=0)},
                'referenceSamples': reference['samples'],
                'measurements': live['benchmarks']}
    write(evidence / 'portable-benchmark.json', document)
    return document


def q_modules() -> dict:
    if git(Q_ROOT, 'rev-parse', 'HEAD') != Q or git(Q_ROOT, 'status', '--porcelain'):
        raise RuntimeError('Qualified Container helper checkout is no longer exact and clean')
    tools = Q_ROOT / 'Tools/bazel'
    names = ('fork_benchmark', 'runtime_benchmark', 'host_lease', 'unattended', 'preflight', 'failed_api_hold',
             'release_install', 'runtime_coverage', 'bazel_environment', 'guest_artifact', 'builder_artifact')
    digests = {name + '.py': sha(tools / (name + '.py')) for name in names}
    sys.path.insert(0, str(tools))
    modules = {name: __import__(name) for name in names}
    return {'modules': modules, 'hashes': digests}


def q_evidence_file(relative: str) -> Path:
    if Q_EVIDENCE is None:
        raise RuntimeError('Qualified Container evidence directory was not selected')
    if Q_EVIDENCE.is_symlink() or not Q_EVIDENCE.is_dir():
        raise RuntimeError('Qualified Container evidence directory is missing or unsafe')
    path = Q_EVIDENCE
    parts = Path(relative).parts
    if Path(relative).is_absolute() or any(part in {'', '.', '..'} for part in parts):
        raise RuntimeError('Invalid qualified Container receipt path')
    for part in parts[:-1]:
        path /= part
        if path.is_symlink() or not path.is_dir():
            raise RuntimeError('Qualified Container receipt parent is missing or unsafe: ' + relative)
    path /= parts[-1]
    if path.is_symlink() or not path.is_file():
        raise RuntimeError('Qualified Container receipt is missing or unsafe: ' + relative)
    return path


def validate_q(q: dict, *, verify_install: bool = True) -> dict:
    acceptance = json.loads(q_evidence_file('acceptance.json').read_text())
    if acceptance.get('passed') is not True or acceptance.get('target') != 'bazel-qualify':
        raise RuntimeError('Qualified Container final acceptance is absent')
    runtime_acceptance_path = q_evidence_file('runtime-smoke/acceptance.json')
    runtime_acceptance_bytes = runtime_acceptance_path.read_bytes()
    runtime_acceptance = json.loads(runtime_acceptance_bytes)
    if runtime_acceptance.get('passed') is not True:
        raise RuntimeError('Qualified Container runtime preparation did not pass')
    fingerprint_path = q_evidence_file('runtime-smoke/fork-fingerprint.json')
    fingerprint_bytes = fingerprint_path.read_bytes()
    fingerprint = json.loads(fingerprint_bytes)
    if not isinstance(fingerprint.get('binaries'), dict):
        raise RuntimeError('Qualified runtime fingerprint has no binary identity')
    runtime = q['modules']['runtime_benchmark']
    if fingerprint.get('workspace') != str(Q_ROOT):
        raise RuntimeError('Qualified runtime fingerprint has a different source workspace')
    install = runtime.INSTALLS / 'fork/install'
    if verify_install:
        for relative, expected in fingerprint['binaries'].items():
            if sha(install / relative) != expected:
                raise RuntimeError('Qualified private runtime binary changed: ' + relative)
    products = {name: json.loads(q_evidence_file(f'runtime-smoke/{name}-artifact.json').read_text())
                for name in ('guest', 'builder')}
    if any(not re.fullmatch(r'[0-9a-f]{64}', record.get('archive_sha256', ''))
           for record in products.values()):
        raise RuntimeError('Qualified Container OCI receipt is malformed')
    release = json.loads(q_evidence_file('release/release-artifact.json').read_text())
    if (release.get('passed') is not True or release.get('source') != Q
            or not re.fullmatch(r'[0-9a-f]{64}', release.get('archives', {}).get('container-homebrew-arm64.tar.gz', ''))):
        raise RuntimeError('Qualified Container release receipt is malformed')
    receipt_paths = ('acceptance.json', 'release/release-artifact.json',
                     'runtime-smoke/fork-fingerprint.json',
                     'runtime-smoke/guest-artifact.json', 'runtime-smoke/builder-artifact.json')
    return {'checkpoint': Q, 'evidence': str(Q_EVIDENCE), 'helpers': q['hashes'],
            'runtime_fingerprint_sha256': hashlib.sha256(fingerprint_bytes).hexdigest(),
            'runtime_acceptance_sha256': hashlib.sha256(runtime_acceptance_bytes).hexdigest(),
            'source_receipt_sha256': {name: sha(q_evidence_file(name)) for name in receipt_paths},
            'guest_sha256': products['guest']['archive_sha256'],
            'builder_sha256': products['builder']['archive_sha256'],
            'release_sha256': release['archives']['container-homebrew-arm64.tar.gz']}


def admit_recovery_q(evidence: Path, q: dict, *, preflight_name: str) -> dict:
    """Bind recovery to the Q source receipts admitted before host ownership."""
    preflight_path = evidence / preflight_name
    if (evidence.is_symlink() or not evidence.is_dir()
            or preflight_path.is_symlink() or not preflight_path.is_file()):
        raise RuntimeError('Original Q preflight receipt is missing or unsafe')
    preflight = json.loads(preflight_path.read_text())
    if preflight.get('ready') is not True:
        raise RuntimeError('Original Q preflight did not admit recovery')
    if preflight_name == 'reference-preflight.json':
        if preflight.get('qualified_runtime') != Q:
            raise RuntimeError('Reference recovery Q checkpoint changed')
    elif preflight_name != 'preflight.json':
        raise RuntimeError('Unsupported original Q preflight receipt')
    admitted = preflight.get('container')
    if not isinstance(admitted, dict):
        raise RuntimeError('Original preflight has no Q receipt identity')
    current = validate_q(q, verify_install=False)
    if any(admitted.get(key) != value for key, value in current.items()):
        raise RuntimeError('Selected Q evidence differs from the original preflight receipts')
    fingerprint_path = q_evidence_file('runtime-smoke/fork-fingerprint.json')
    fingerprint_bytes = fingerprint_path.read_bytes()
    fingerprint = json.loads(fingerprint_bytes)
    if hashlib.sha256(fingerprint_bytes).hexdigest() != current['runtime_fingerprint_sha256']:
        raise RuntimeError('Selected Q runtime fingerprint changed during recovery admission')
    return {'container': current, 'fingerprint': fingerprint}


def preflight(evidence: Path, q: dict, *, development_bridge: bool = False,
              development_parity: bool = False) -> tuple[dict, dict]:
    identity = source_identity(ROOT)
    if identity['dirty'] or identity['commit'] != git(ROOT, 'rev-parse', 'HEAD'):
        raise RuntimeError('Qualification and development proof require one clean immutable Compose checkpoint')
    config_path = q['modules']['preflight'].CONFIG
    config = json.loads(config_path.read_text())
    checks = q['modules']['preflight'].check('runtime', config)
    failed = [c['check'] for c in checks['checks'] if not c['ready']]
    pending_api_hold = failed == ['apple-runtime-slot'] and config.get('failed_api_hold') is not None
    if not checks['ready'] and not pending_api_hold:
        raise RuntimeError('Runtime/signing/host preflight failed: ' + ', '.join(c['check'] for c in checks['checks'] if not c['ready']))
    if not (development_bridge or development_parity):
        profile = config.get('notary_profile')
        if not isinstance(profile, str) or not profile:
            raise RuntimeError('Notary keychain profile missing before expensive stages')
        subprocess.run(['/usr/bin/xcrun', 'notarytool', 'history', '--keychain-profile', profile,
                        '--output-format', 'json'], check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=30)
        context = subprocess.run(['gh', 'api', 'user'], env={k:v for k,v in os.environ.items() if k not in ('GH_TOKEN','GITHUB_TOKEN')},
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        if context.returncode:
            raise RuntimeError('GitHub quality access unavailable')
        current_context(identity['commit'])
    docker_compose = subprocess.check_output(['docker', 'compose', 'version', '--short'],
                                             text=True, timeout=20).strip().lstrip('v')
    if docker_compose != DOCKER_COMPOSE_VERSION:
        raise RuntimeError('Docker Compose oracle is not the pinned 5.5.1 release')
    budget = host_budget()
    runtime = q['modules']['runtime_benchmark']
    q['modules']['runtime_coverage'].require_idle(runtime.INSTALLS / 'fork/install')
    if q['modules']['host_lease'].JOURNAL.exists():
        raise RuntimeError('Prior shared host restoration is incomplete')
    if any(pid != '-' for pid, _ in runtime.services(runtime.NAMESPACE + '.')):
        raise RuntimeError('Private qualified runtime is already active')
    qualified = validate_q(q)
    pins = json.loads((ROOT / 'Package.resolved').read_text())['pins']
    selected = {row['identity']: row['state']['revision'] for row in pins}
    if selected.get('container') != Q or selected.get('containerization') != CONTAINERIZATION:
        raise RuntimeError('Enhanced consumer dependency graph does not match Q runtime family')
    qualified['sdk_graph'] = {'lock_sha256': sha(ROOT / 'Package.resolved'),
                              'zstd_patch_sha256': sha(ROOT / 'Tools/bazel/zstd-public-module.patch'),
                              'ext4_patch_sha256': sha(ROOT / 'Tools/bazel/containerization-ext4-unaligned.patch')}
    qualified['source'] = identity
    write(evidence / 'preflight.json', {'ready': True, 'development_bridge': development_bridge,
                                        'development_parity': development_parity,
                                        'pending_approved_api_hold': pending_api_hold,
                                        'docker_compose_version': docker_compose,
                                        'budget': budget,
                                        'container': qualified, 'host_checks': checks})
    return identity, config


def reference_preflight(evidence: Path, q: dict) -> None:
    """Admit released Docker capture without signing or candidate build stages."""
    identity = source_identity(ROOT)
    if identity['dirty'] or identity['commit'] != git(ROOT, 'rev-parse', 'HEAD'):
        raise RuntimeError('Reference capture requires one clean Compose checkpoint')
    host_budget()
    if subprocess.check_output(['docker', 'compose', 'version', '--short'],
                               text=True, timeout=20).strip().lstrip('v') != DOCKER_COMPOSE_VERSION:
        raise RuntimeError('Reference capture requires installed Docker Compose 5.5.1')
    docker_compose_binary_identity()
    environment = benchmark_environment()
    if BENCHMARK_LOCK.is_file():
        receipt = cached_fetch(BENCHMARK_LOCK, BENCHMARK_CACHE)
        prior = json.loads(Path(receipt['asset']).read_text())
        benchmark_evidence.validate_reference(prior, prior['workload'], prior['environment'])
        current = benchmark_evidence.workload(q['modules']['runtime_benchmark'].ALPINE)
        if prior['workload'] == current and prior['environment'] == environment:
            raise RuntimeError('Compatible published Docker reference already exists; reuse it')
    runtime = q['modules']['runtime_benchmark']
    q['modules']['runtime_coverage'].require_idle(runtime.INSTALLS / 'fork/install')
    if q['modules']['host_lease'].JOURNAL.exists():
        raise RuntimeError('Prior shared host restoration is incomplete')
    qualified = validate_q(q)
    write(evidence / 'reference-preflight.json', {'schema': 1, 'ready': True,
                                                  'source': identity['commit'],
                                                  'qualified_runtime': Q,
                                                  'container': qualified})


def execute_capture(evidence: Path) -> dict:
    q = q_modules()
    reference_preflight(evidence, q)
    return capture_reference(evidence, q)


def stage(evidence: Path, name: str, args: list[str], timeout: int, cwd: Path = ROOT,
          env: dict | None = None) -> dict:
    directory = evidence / 'stages'
    directory.mkdir(exist_ok=True)
    log = directory / (name + '.log')
    started = time.monotonic()
    with log.open('wb') as stream:
        with subprocess.Popen(args, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                              stdout=stream, stderr=subprocess.STDOUT,
                              start_new_session=True) as process:
            try:
                status = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                status = 124
            except BaseException:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=10)
                raise
    row = {'name': name, 'command': args, 'status': status, 'seconds': time.monotonic()-started,
           'log': str(log), 'sha256': sha(log)}
    write(directory / (name + '.json'), row)
    if status:
        raise RuntimeError(f'{name} failed ({status}); see {log}')
    return row


def layer_command(name: str, command: str, target: str, profile: str) -> list[str]:
    selected = [str(ROOT / 'Tools/bazel/run.sh'), command, target, '--config='+profile]
    if name in {'docs', 'package', 'package-smoke'}:
        selected.append('--config=release')
    if name in {'package', 'package-smoke'}:
        selected.append('--config=prebuilt-container-sdk')
    return selected


def compiled_sdk_chain(evidence: Path, source: str, package_invocation: str) -> dict:
    """Retain the exact published layer locks selected by the final package lane."""
    directory = ROOT / 'Tools/bazel/artifacts'
    paths = {'argument-parser': directory / 'argument-parser.lock.json'}
    paths.update({name: directory / 'layer-locks' / (name + '-enhanced.json')
                  for name in ('foundation', 'containerization', 'engine-api', 'container-sdk')})
    locks = {}
    for name, path in paths.items():
        lock = json.loads(path.read_text())
        if (lock.get('developmentProof') is True or not lock.get('tag')
                or not lock.get('archiveSHA256') or len(lock['archiveSHA256']) != 64):
            raise RuntimeError('Final Compose package requires a published compiled SDK layer: ' + name)
        target_commit = (lock.get('targetCommit') if name != 'argument-parser'
                         else lock.get('manifest', {}).get('producerCommit'))
        if not isinstance(target_commit, str) or len(target_commit) != 40:
            raise RuntimeError('Published compiled SDK layer lacks a target commit: ' + name)
        locks[name] = {'lock_sha256': sha(path), 'archive_sha256': lock['archiveSHA256'],
                       'repository': lock['repository'], 'tag': lock['tag'],
                       'target_commit': target_commit}
    receipt = {'schema': 1, 'source': source, 'profile': 'enhanced',
               'package_invocation': package_invocation,
               'selected_config': 'prebuilt-container-sdk', 'locks': locks}
    write(evidence / 'compiled-sdk-chain.json', receipt)
    return receipt


def run_layers(evidence: Path, original: dict, q: dict, *,
               development_bridge: bool = False,
               development_parity: bool = False) -> tuple[list[dict], str, dict, dict]:
    rows = [stage(evidence, 'source-preflight',
                  ['make', '--no-print-directory', 'source-preflight'], 900,
                  env=dict(os.environ, CONTAINER_STACK_REPO=str(Q_ROOT)))]
    verify_source(original, source_identity(ROOT))
    if not (development_bridge or development_parity):
        rows.append(stage(evidence, 'workflow-tools',
                          ['make', '--no-print-directory', 'bazel-workflow-tools-test'], 300))
        verify_source(original, source_identity(ROOT))
    rows.append(stage(evidence, 'original-parity-fixtures',
                      ['make', '--no-print-directory', 'docker-compose-e2e-fixtures'], 900))
    verify_source(original, source_identity(ROOT))
    assets = fetch_q_assets(evidence / 'q-assets', q['hashes'])
    qualified = json.loads((evidence / 'preflight.json').read_text())['container']
    bundle = assets['provenance']
    if (bundle['source_receipt_sha256'] != qualified['source_receipt_sha256']
            or assets['assets']['runtime']['sha256'] != qualified['release_sha256']
            or assets['assets']['guest']['sha256'] != qualified['guest_sha256']
            or assets['assets']['builder']['sha256'] != qualified['builder_sha256']):
        raise RuntimeError('Published Q assets differ from local qualified source receipts')
    rows.append({'name': 'q-assets', 'status': 0,
                 'receipt': str(evidence / 'q-assets/q-assets.json'),
                 'sha256': sha(evidence / 'q-assets/q-assets.json')})
    verify_source(original, source_identity(ROOT))
    package_invocation = ''
    selected_stages = (tuple(row for row in STAGES if row[0] == 'package')
                       if development_bridge or development_parity else STAGES)
    for name, command, target, profile, timeout in selected_stages:
        args = layer_command(name, command, target, profile)
        row = stage(evidence, name, args, timeout)
        rows.append(row)
        verify_source(original, source_identity(ROOT))
        if name.startswith('coverage-'):
            text = Path(row['log']).read_text(errors='replace')
            match = re.search(r'Retained Compose Bazel invocation: ([0-9a-f-]{36})', text)
            if not match:
                raise RuntimeError('Native coverage invocation was not retained')
            rows.append(stage(evidence, name + '-report',
                              [str(ROOT / 'Tools/bazel/run.sh'), 'coverage-report', match[1],
                               '--minimum-percent', '90', '--inventory=unit-cli', '--config='+profile], 300))
        if name == 'package':
            text = Path(row['log']).read_text(errors='replace')
            match = re.search(r'Retained Compose Bazel invocation: ([0-9a-f-]{36})', text)
            if not match:
                raise RuntimeError('Candidate package invocation was not retained')
            package_invocation = match[1]
    if not package_invocation:
        raise RuntimeError('No candidate package invocation')
    chain = compiled_sdk_chain(evidence, original['commit'], package_invocation)
    rows.append({'name': 'compiled-sdk-chain', 'status': 0,
                 'receipt': str(evidence / 'compiled-sdk-chain.json'),
                 'sha256': sha(evidence / 'compiled-sdk-chain.json')})
    if development_bridge:
        verify_source(original, source_identity(ROOT))
        return rows, package_invocation, assets, {}
    test_names = (('ComposeCoreTests', 'ComposePluginTests') if development_parity else
                  ('ComposeRuntimeTests', 'ComposeCoreTests', 'ComposePluginTests'))
    rows.append(stage(evidence, 'runtime-tests-build',
                      [str(ROOT / 'Tools/bazel/run.sh'), 'build',
                       *(f'//:{name}' for name in test_names), '--config=enhanced'], 1800))
    verify_source(original, source_identity(ROOT))
    rows.append(stage(evidence, 'native-test-output-root',
                      [str(ROOT / 'Tools/bazel/run.sh'), 'info', 'bazel-bin',
                       '--config=enhanced'], 90))
    output = Path(Path(rows[-1]['log']).read_text().strip().splitlines()[-1])
    if not output.is_absolute() or not output.is_dir() or not output.is_relative_to(SSD / 'output'):
        raise RuntimeError('Bazel native test output root escaped the enrolled SSD')
    binaries = {}
    for name in test_names:
        binary = output / (name + '.xctest/Contents/MacOS') / name
        runfiles = binary.with_name(name + '.runfiles')
        if not binary.is_file() or not os.access(binary, os.X_OK) or not runfiles.is_dir():
            raise RuntimeError('Built native test executable/runfiles are missing: ' + name)
        workspace = test_workspace(runfiles, name,
                                   'ComposeRuntimeFixtures.bundle' if name == 'ComposeRuntimeTests' else None)
        binaries[name] = {'path': str(binary), 'sha256': sha(binary),
                          'runfiles': str(runfiles), 'workspace': workspace}
    write(evidence / 'native-tests.json', {'source': original['commit'], 'binaries': binaries})
    verify_source(original, source_identity(ROOT))
    return rows, package_invocation, assets, binaries


def unpack_candidate(evidence: Path, invocation: str) -> Path:
    restored = restore_candidate(RETAINED / 'bazel-evidence.sqlite', invocation, SSD)
    root = evidence / 'candidate'
    root.mkdir()
    with tarfile.open(restored / 'candidate_archive.tar.gz', 'r:gz') as archive:
        for member in archive.getmembers():
            path = Path(member.name)
            if (path.is_absolute() or '..' in path.parts or member.issym() or member.islnk()
                    or not (member.isfile() or member.isdir())):
                raise RuntimeError('Candidate archive has unsafe entry')
        archive.extractall(root)
    plugin = root / 'compose'
    if not (plugin / 'bin/compose').is_file() or not (plugin / 'resources/compose-normalizer').is_file():
        raise RuntimeError('Candidate archive omitted the visible plugin or normalizer')
    receipt = json.loads((restored / 'candidate_archive.json').read_text())
    if receipt.get('commit') != git(ROOT, 'rev-parse', 'HEAD') or receipt.get('runtimeProfile') != 'enhanced':
        raise RuntimeError('Candidate archive has wrong source/profile')
    write(evidence / 'candidate-unsigned.json', {'invocation': invocation, 'archive_sha256': sha(restored / 'candidate_archive.tar.gz'),
                                                  'receipt': receipt, 'plugin': str(plugin)})
    return plugin


def sign(evidence: Path, plugin: Path, identity: str) -> dict:
    hashes = {}
    for relative in ('bin/compose', 'resources/compose-normalizer'):
        path = plugin / relative
        subprocess.run(['/usr/bin/codesign', '--force', '--options', 'runtime', '--timestamp',
                        '--sign', identity, str(path)], check=True, timeout=180)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(path)],
                       check=True, timeout=30)
        hashes[relative] = sha(path)
    result = {'source': git(ROOT, 'rev-parse', 'HEAD'), 'identity': identity,
              'payload': hashes, 'tree': PluginLease.tree(plugin)}
    write(evidence / 'signed-candidate.json', result)
    return result


class PluginLease:
    """Replace only the exact private plugin and retain a durable restoration journal."""
    def __init__(self, evidence: Path, install: Path, signed: dict,
                 original_binaries: dict[str, str] | None = None,
                 *, combined_runtime: bool = False):
        self.evidence, self.install, self.signed = evidence, install, signed
        self.original_binaries = original_binaries or {}
        self.combined_runtime = combined_runtime
        self.parent = install / 'libexec/container-plugins'
        self.target = self.parent / 'compose'
        # Keep the prior plugin outside the discovery directory while leased.
        self.backup = install / 'libexec' / ('.compose-qualification-backup-' + uuid.uuid4().hex)
        self.stage = install / 'libexec' / ('.compose-qualification-stage-' + uuid.uuid4().hex)
        self.retired = install / 'libexec' / ('.compose-qualification-retired-' + uuid.uuid4().hex)
        self.record = {'started': False, 'restored': False, 'target': str(self.target),
                       'backup': str(self.backup), 'stage': str(self.stage),
                       'retired': str(self.retired), 'original': {}}

    def installation_receipt(self, restored: bool) -> None:
        if not self.original_binaries:
            raise RuntimeError('Private plugin lease lacks qualified runtime binary fingerprints')
        directory = self.evidence / 'install'
        directory.mkdir(exist_ok=True)
        write(directory / 'install.json', {'replacement_started': True,
              'previous_installation_restored': restored, 'scope': 'compose-private-plugin',
              'original_binaries': self.original_binaries})

    @staticmethod
    def tree(path: Path) -> dict:
        files = {}
        for p in sorted(path.rglob('*')):
            if p.is_symlink():
                raise RuntimeError('Private plugin contains an unverified symbolic link')
            if p.is_file():
                files[str(p.relative_to(path))] = sha(p)
        return files

    def acquire(self, plugin: Path) -> None:
        if (self.parent.is_symlink() or self.target.is_symlink() or self.backup.exists()
                or self.stage.exists() or self.retired.exists()):
            raise RuntimeError('Unsafe private plugin destination')
        self.parent.mkdir(parents=True, exist_ok=True)
        self.record['original'] = self.tree(self.target) if self.target.exists() else {}
        # Q's generic recovery refuses to resume workers while this receipt is
        # false. Only Compose recovery knows how to restore the plugin journal.
        if not self.combined_runtime:
            self.installation_receipt(False)
        write(self.evidence / 'plugin-lease.json', self.record)
        try:
            shutil.copytree(plugin, self.stage)
            if self.tree(self.stage) != self.signed['tree']:
                raise RuntimeError('Staged signed plugin changed')
        except BaseException:
            if self.stage.exists():
                shutil.rmtree(self.stage)
            raise
        self.record['started'] = True
        write(self.evidence / 'plugin-lease.json', self.record)
        if self.target.exists():
            self.target.rename(self.backup)
        self.stage.rename(self.target)
        if self.tree(self.target) != self.signed['tree']:
            raise RuntimeError('Installed signed plugin changed')

    def remove_verified_candidate(self, path: Path, authorization: str) -> None:
        """Allow deletion to resume only for still-matching signed files."""
        if not path.exists():
            return
        remaining = self.tree(path)
        if not self.record.get(authorization):
            if remaining != self.signed['tree']:
                raise RuntimeError('Private signed candidate changed before deletion')
            self.record[authorization] = True
            write(self.evidence / 'plugin-lease.json', self.record)
        elif any(self.signed['tree'].get(name) != digest for name, digest in remaining.items()):
            raise RuntimeError('Partially deleted private candidate changed')
        shutil.rmtree(path)

    def restore(self) -> None:
        if not (self.evidence / 'plugin-lease.json').exists():
            return
        if not self.record['started']:
            if (self.tree(self.target) if self.target.exists() else {}) != self.record['original']:
                raise RuntimeError('Private plugin changed before swap; preserving recovery authority')
            if self.stage.exists():
                shutil.rmtree(self.stage)
            self.record['restored'] = True
            write(self.evidence / 'plugin-lease.json', self.record)
            return
        if self.target.exists():
            current = self.tree(self.target)
            if current == self.record['original'] and not self.backup.exists():
                pass  # Swap never began; original plugin is still installed.
            elif current == self.signed['tree']:
                self.target.rename(self.retired)
            else:
                raise RuntimeError('Private candidate plugin changed; preserving recovery authority')
        if self.stage.exists():
            self.remove_verified_candidate(self.stage, 'stage_cleanup_authorized')
        if self.backup.exists():
            self.backup.rename(self.target)
        if self.retired.exists():
            if (self.tree(self.target) if self.target.exists() else {}) != self.record['original']:
                raise RuntimeError('Original plugin is unverified before retired candidate deletion')
            self.remove_verified_candidate(self.retired, 'retired_cleanup_authorized')
        if (self.tree(self.target) if self.target.exists() else {}) != self.record['original']:
            raise RuntimeError('Original private plugin did not restore')
        self.record['restored'] = True
        write(self.evidence / 'plugin-lease.json', self.record)

    def finalize(self, ledger: 'ProjectLedger', *, runtime_idle: bool,
                 colima_restored: bool, stock_restored: bool) -> None:
        if self.combined_runtime:
            raise RuntimeError('Combined private runtime lease owns the installation guard')
        if (not self.record['restored'] or ledger.active() or not runtime_idle
                or not colima_restored or not stock_restored):
            raise RuntimeError('Compose transaction is not fully restored; preserving Q recovery guard')
        self.installation_receipt(True)

    @classmethod
    def from_receipt(cls, evidence: Path, install: Path, signed: dict) -> 'PluginLease':
        record = json.loads((evidence / 'plugin-lease.json').read_text())
        sentinel = json.loads((evidence / 'install/install.json').read_text())
        scope = sentinel.get('scope')
        lease = cls(evidence, install, signed, sentinel['original_binaries'],
                    combined_runtime=scope == 'compose-private-runtime-and-plugin')
        if (record.get('target') != str(lease.target)
                or scope not in {'compose-private-plugin', 'compose-private-runtime-and-plugin'}):
            raise RuntimeError('Private plugin recovery journal targets a different installation')
        for field, prefix in (('backup', '.compose-qualification-backup-'),
                              ('stage', '.compose-qualification-stage-'),
                              ('retired', '.compose-qualification-retired-')):
            path = Path(record[field])
            if path.parent != install / 'libexec' or not path.name.startswith(prefix):
                raise RuntimeError('Private plugin recovery path escaped its installation')
            setattr(lease, field, path)
        if not isinstance(record.get('original'), dict) or type(record.get('started')) is not bool:
            raise RuntimeError('Private plugin recovery journal is malformed')
        lease.record = record
        return lease


class RuntimeArchiveLease:
    """Temporarily install the downloaded, signed Q archive in its private slot."""

    def __init__(self, evidence: Path, install: Path, archive: Path,
                 payload: dict[str, str], original_binaries: dict[str, str]):
        self.evidence, self.install, self.archive = evidence, install, archive
        self.payload, self.original_binaries = payload, original_binaries
        nonce = uuid.uuid4().hex
        self.stage = install.parent / ('.compose-q-stage-' + nonce)
        self.backup = install.parent / ('.compose-q-backup-' + nonce)
        self.retired = install.parent / ('.compose-q-retired-' + nonce)
        self.record = {'schema': 1, 'qualified_source': Q, 'install': str(install),
                       'archive_sha256': sha(archive), 'stage': str(self.stage),
                       'backup': str(self.backup), 'retired': str(self.retired),
                       'started': False, 'restored': False,
                       'original_binaries': original_binaries,
                       'original_tree': {}, 'signed_tree': {}}

    def save(self) -> None:
        write(self.evidence / 'runtime-install.json', self.record)

    def guard(self, restored: bool) -> None:
        directory = self.evidence / 'install'
        directory.mkdir(exist_ok=True)
        write(directory / 'install.json', {'replacement_started': True,
              'previous_installation_restored': restored,
              'scope': 'compose-private-runtime-and-plugin',
              'original_binaries': self.original_binaries})

    def acquire(self, checked_payload: object, runtime: object,
                runtime_coverage: object) -> None:
        if (not self.install.is_dir() or self.install.is_symlink()
                or any(path.exists() for path in (self.stage, self.backup, self.retired))):
            raise RuntimeError('Qualified private runtime baseline is missing or occupied')
        runtime.own(self.install, 'fork')
        runtime_coverage.require_idle(self.install)
        runtime_coverage.verify_binaries(self.install, self.original_binaries)
        self.record['original_tree'] = PluginLease.tree(self.install)
        self.save()
        self.stage.mkdir()
        checked_payload(self.archive, self.stage, self.payload)
        shutil.copy2(self.install / '.runtime-benchmark-owner.json',
                     self.stage / '.runtime-benchmark-owner.json')
        self.record['signed_tree'] = PluginLease.tree(self.stage)
        self.save()
        # Q's generic recovery must refuse worker resumption from this point.
        self.guard(False)
        self.record['started'] = True
        self.save()
        self.install.rename(self.backup)
        self.stage.rename(self.install)
        runtime.own(self.install, 'fork')
        runtime_coverage.verify_binaries(self.install, self.payload)

    def remove_signed(self, path: Path, authorization: str) -> None:
        if not path.exists():
            return
        remaining = PluginLease.tree(path)
        if not self.record.get(authorization):
            if remaining != self.record['signed_tree']:
                raise RuntimeError('Released runtime changed before private cleanup')
            self.record[authorization] = True
            self.save()
        elif any(self.record['signed_tree'].get(name) != value
                 for name, value in remaining.items()):
            raise RuntimeError('Partially deleted released runtime changed')
        shutil.rmtree(path)

    def restore(self, runtime_coverage: object) -> None:
        if not (self.evidence / 'runtime-install.json').exists():
            return
        runtime_coverage.require_idle(self.install)
        if not self.record['started']:
            if PluginLease.tree(self.install) != self.record['original_tree']:
                raise RuntimeError('Private runtime changed before signed swap')
            if self.stage.exists():
                shutil.rmtree(self.stage)
            self.record['restored'] = True
            self.save()
            return
        if self.install.exists():
            current = PluginLease.tree(self.install)
            if current == self.record['original_tree'] and not self.backup.exists():
                pass
            elif current == self.record['signed_tree']:
                self.install.rename(self.retired)
            else:
                raise RuntimeError('Private signed runtime changed; preserving recovery authority')
        if self.stage.exists():
            self.remove_signed(self.stage, 'stage_cleanup_authorized')
        if self.backup.exists():
            if PluginLease.tree(self.backup) != self.record['original_tree']:
                raise RuntimeError('Original private runtime backup changed')
            self.backup.rename(self.install)
        if not self.install.exists() or PluginLease.tree(self.install) != self.record['original_tree']:
            raise RuntimeError('Original private runtime did not restore')
        if self.retired.exists():
            self.remove_signed(self.retired, 'retired_cleanup_authorized')
        runtime_coverage.verify_binaries(self.install, self.original_binaries)
        self.record['restored'] = True
        self.save()

    def predecessor_present(self) -> bool:
        """Recognize a completed swap before its phase receipt was persisted."""
        return (bool(self.record['original_tree']) and self.install.is_dir()
                and not self.backup.exists()
                and PluginLease.tree(self.install) == self.record['original_tree'])

    def finalize(self) -> None:
        if not self.record['restored']:
            raise RuntimeError('Released runtime private installation remains active')
        self.guard(True)

    @classmethod
    def from_receipt(cls, evidence: Path, install: Path, archive: Path,
                     payload: dict[str, str]) -> 'RuntimeArchiveLease':
        record = json.loads((evidence / 'runtime-install.json').read_text())
        lease = cls(evidence, install, archive, payload, record['original_binaries'])
        if (record.get('schema') != 1 or record.get('qualified_source') != Q
                or record.get('install') != str(install)
                or record.get('archive_sha256') != sha(archive)):
            raise RuntimeError('Released runtime recovery journal changed source or archive')
        for field in ('stage', 'backup', 'retired'):
            path = Path(record[field])
            if path.parent != install.parent or not path.name.startswith('.compose-q-' + field + '-'):
                raise RuntimeError('Released runtime recovery path escaped its private installation')
            setattr(lease, field, path)
        if (not isinstance(record.get('original_tree'), dict)
                or not isinstance(record.get('signed_tree'), dict)
                or type(record.get('started')) is not bool):
            raise RuntimeError('Released runtime recovery journal is malformed')
        lease.record = record
        return lease


class ProjectLedger:
    """Journal exact Compose projects before up and attest absence after down."""
    def __init__(self, evidence: Path):
        self.path = evidence / 'projects.json'
        self.records = json.loads(self.path.read_text()) if self.path.exists() else {}

    def begin(self, project: str, lane: str, fixture: Path) -> None:
        if (project in self.records or lane not in {'candidate', 'docker'}
                or not re.fullmatch(r'cfq[0-9]+-[13]-[0-7]-(candidate|docker)', project)
                or not project.endswith('-' + lane)):
            raise RuntimeError('Invalid or duplicate owned Compose project')
        self.records[project] = {'lane': lane, 'fixture': str(fixture),
                                 'fixture_sha256': sha(fixture), 'active': True}
        write(self.path, self.records)

    def finished(self, project: str) -> None:
        self.records[project]['active'] = False
        write(self.path, self.records)

    def reactivate(self, project: str) -> None:
        self.records[project]['active'] = True
        write(self.path, self.records)

    def active(self) -> list[tuple[str, dict]]:
        return [(name, record) for name, record in self.records.items() if record['active']]


def restore_colima_after_projects(lease: object, ledger: ProjectLedger) -> None:
    if ledger.active():
        raise RuntimeError('Owned Docker/Compose projects remain; Colima restoration cannot attest cleanup')
    lease.restore()


def fixture(path: Path, count: int, image: str) -> None:
    path.write_text(benchmark_evidence.fixture_text(count, image))


def candidate_environment(runtime: object, install: Path, additional: dict | None = None,
                          *, machine_output: bool = False) -> dict:
    """Select the signed private CLI even when the host has another Container on PATH."""
    environment = dict(runtime.environment('fork'), **(additional or {}))
    executable = str(install / 'bin/container')
    environment.update(CONTAINER_COMPOSE_CONTAINER=executable, CONTAINER_BIN=executable)
    if machine_output:
        environment['COMPOSE_PROGRESS'] = 'quiet'
    return environment


def benchmark_issue_environment(lane: str, fixture_name: str, runtime: object,
                                install: Path, additional: dict) -> dict:
    if lane == 'candidate':
        machine_output = fixture_name.endswith(('-services-ps', '-services-absent'))
        return candidate_environment(runtime, install, additional,
                                     machine_output=machine_output)
    return dict(os.environ, **additional)


def measure_lane(lane: str, base: list[str], fixtures: Path, ledger: ProjectLedger,
                 issue: object, progress: Path) -> tuple[list[dict], list[dict]]:
    """Run only the requested lane with the exact published workload commands."""
    if lane not in {'candidate', 'docker'}:
        raise ValueError('Benchmark lane must be candidate or Docker')
    rows: list[dict] = []
    warmups: list[dict] = []
    operations = benchmark_evidence.OPERATIONS
    timeouts = benchmark_evidence.TIMEOUTS
    for count in benchmark_evidence.COUNTS:
        source = fixtures / f'{count}.yml'
        for trial in range(TRIALS + 1):
            project = f'cfq{os.getpid()}-{count}-{trial}-{lane}'
            prefix = base + ['-p', project, '-f', str(source)]
            issue(lane, f'{count}-services-config', trial,
                  prefix + operations['config'], timeouts['config'])
            up = None
            ledger.begin(project, lane, source)
            try:
                up = issue(lane, f'{count}-services-up', trial,
                           prefix + operations['up'], timeouts['up'])
                ps = issue(lane, f'{count}-services-ps', trial,
                           prefix + operations['ps'], timeouts['ps'])
                report = Path(ps['log']).read_text(errors='replace')
                if any(f'worker{index:02d}' not in report for index in range(1, count + 1)):
                    raise RuntimeError('Compose did not report every expected service')
            finally:
                down = issue(lane, f'{count}-services-down', trial,
                             prefix + operations['down'], timeouts['down'])
                absent = issue(lane, f'{count}-services-absent', trial,
                               prefix + operations['absent'], timeouts['absent'])
                if Path(absent['log']).read_text().strip():
                    raise RuntimeError('Project containers remain after successful down: ' + project)
                if lane == 'docker' and subprocess.check_output(
                        ['docker', '--context', 'colima', 'ps', '-aq', '--filter',
                         'label=com.docker.compose.project=' + project],
                        text=True, timeout=20).strip():
                    raise RuntimeError('Docker containers remain after successful down: ' + project)
                ledger.finished(project)
                if up is not None:
                    target = warmups if trial == 0 else rows
                    for operation, result in (('up', up), ('down', down)):
                        target.append({'fixture': f'{count}-services-{operation}',
                                       'lane': lane, 'trial': trial,
                                       'seconds': result['seconds'], 'status': result['status'],
                                       'log_sha256': sha(Path(result['log']))})
            write(progress, {'rows': rows, 'warmups': warmups})
    return rows, warmups


def capture_reference(evidence: Path, q: dict) -> dict:
    """Capture the missing Docker denominator once, without any Compose build."""
    modules = q['modules']
    runtime = modules['runtime_benchmark']
    fb = modules['fork_benchmark']
    unattended = modules['unattended']
    image = runtime.ALPINE
    workload = benchmark_evidence.workload(image)
    environment = benchmark_environment()
    binary = docker_compose_binary_identity()
    fixtures = evidence / 'fixtures'
    fixtures.mkdir()
    for count in benchmark_evidence.COUNTS:
        fixture(fixtures / f'{count}.yml', count, image)
        if sha(fixtures / f'{count}.yml') != workload['fixtureSHA256'][str(count)]:
            raise RuntimeError('Captured fixture differs from canonical workload')
    runner_evidence = evidence / 'runtime'
    runner_evidence.mkdir()
    runner = runtime.RuntimeRunner(runner_evidence, fb.STORAGE)
    ledger = ProjectLedger(evidence)
    host = modules['host_lease'].HostLease(evidence)
    colima = unattended.ColimaLease(evidence)
    command_lock = evidence / 'commands.lock'
    write(evidence / 'reference-capture-intent.json',
          {'schema': 1, 'qualified_runtime': Q, 'workload_sha256': benchmark_evidence.digest(workload),
           'command_lock': str(command_lock)})
    result = {'schema': 1, 'target': 'capture-compose-docker-reference',
              'passed': False, 'restored': False, 'failures': []}
    with (fb.STORAGE / 'qualification.lock').open('w') as qualify_lock, \
         (runtime.INSTALLS / 'benchmark.lock').open('w') as benchmark_lock, ExitStack() as commands:
        fcntl.flock(qualify_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(benchmark_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        host.record['command_lock'] = str(command_lock)
        host.record['bazel_workspace'] = str(Q_ROOT)
        descriptor = os.open(command_lock, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
        os.close(descriptor)
        colima.command_descriptors = commands.enter_context(
            fb.command_lease({fb.COMMAND_LOCK_ENV: str(command_lock)}))
        runner.runtime_environment[fb.COMMAND_LOCK_ENV] = str(command_lock)
        host_started = False
        cleanup_ok = True
        rows: list[dict] = []
        warmups: list[dict] = []
        engine = None
        try:
            host_started = True
            host.acquire()
            colima.acquire()
            for fd in colima.command_descriptors:
                fcntl.flock(fd, fcntl.LOCK_UN)
            commands.close()
            colima.command_descriptors = ()
            if benchmark_environment() != environment:
                raise RuntimeError('Reference environment changed during owned Colima start')
            engine = docker_engine_identity()
            verify_selected_docker_compose(binary['sha256'])
            def issue(lane: str, fixture_name: str, trial: int,
                      command: list[str], timeout: int = 180) -> dict:
                if lane != 'docker':
                    raise RuntimeError('Reference capture may execute only the released Docker lane')
                runner.env = dict(os.environ, **runner.runtime_environment)
                row = runner.run('compose-reference', lane, fixture_name, trial,
                                 command, ROOT, timeout)
                if row['status']:
                    raise RuntimeError(f'Docker reference {fixture_name}/{trial} failed; see {row["log"]}')
                return row
            issue('docker', 'setup-image', 0,
                  ['docker', '--context', 'colima', 'pull', image], 300)
            write(runner_evidence / 'benchmark-host-before.json', benchmark_host_snapshot())
            rows, warmups = measure_lane('docker', ['docker', '--context', 'colima', 'compose'],
                                         fixtures, ledger, issue,
                                         runner_evidence / 'compose-operations.json')
            verify_selected_docker_compose(binary['sha256'])
            write(runner_evidence / 'benchmark-host-after.json', benchmark_host_snapshot())
        except BaseException as error:
            result['failures'].append(str(error))
        finally:
            commands.close()
            try:
                colima.command_descriptors = unattended.acquire_cleanup_commands(
                    evidence, commands, str(Q_ROOT))
                ensure_projects_cleared(evidence, ledger, q, colima.command_descriptors,
                                        command_lock, allow_existing=False)
                colima.restore()
                if colima.record['restored'] is not True:
                    raise RuntimeError('Reference Colima restoration was not recorded')
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append('Reference project/Colima cleanup failed: ' + str(error))
            try:
                if host_started:
                    host.restore(restore_workers=cleanup_ok)
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append('Reference host restoration failed: ' + str(error))
            finally:
                host.close()
            result['restored'] = cleanup_ok and not ledger.active()
            write(evidence / 'reference-capture.json', result)
    if not result['restored'] or result['failures'] or engine is None:
        raise RuntimeError('Reference capture failed or left host restoration uncertain')
    restoration = {'schema': 1, 'projects_cleared_sha256': sha(evidence / 'projects-cleared.json'),
                   'colima_lease_sha256': sha(evidence / 'colima-lease.json'),
                   'host_lease_sha256': sha(evidence / 'host-lease.json'),
                   'restored': True}
    write(evidence / 'reference-restoration.json', restoration)
    capture = {'cleanupVerified': True, 'hostRestored': True,
               'capturedAt': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
               'hostBeforeSHA256': sha(runner_evidence / 'benchmark-host-before.json'),
               'hostAfterSHA256': sha(runner_evidence / 'benchmark-host-after.json'),
               'hostBefore': benchmark_evidence.host_projection(json.loads(
                   (runner_evidence / 'benchmark-host-before.json').read_text())),
               'hostAfter': benchmark_evidence.host_projection(json.loads(
                   (runner_evidence / 'benchmark-host-after.json').read_text())),
               'cleanupReceiptSHA256': sha(evidence / 'reference-restoration.json'),
               'dockerEngine': engine}
    document = benchmark_evidence.reference_document(workload, environment, binary,
                                                     rows, warmups, capture)
    write(evidence / 'compose-benchmark-reference-v1.json', document)
    benchmark_evidence.validate_reference(document, workload, environment)
    result['passed'] = True
    result['reference_sha256'] = sha(evidence / 'compose-benchmark-reference-v1.json')
    write(evidence / 'reference-capture.json', result)
    (evidence / 'reference-capture-intent.json').unlink()
    return result


def compare(rows: list[dict], report_dir: Path | None = None) -> dict:
    results = {}
    for count in (1, 3):
        for operation in ('up', 'down'):
            key = f'{count}-services-{operation}'
            lanes = {}
            for lane in ('candidate', 'docker'):
                values = [r['seconds'] for r in rows if r['fixture'] == key and r['lane'] == lane and r['trial'] > 0]
                if len(values) != TRIALS or any(not math.isfinite(x) or x <= 0 for x in values):
                    raise RuntimeError('Incomplete matched performance fixture: ' + key)
                lanes[lane] = {'raw_seconds': values, 'median_seconds': statistics.median(values),
                               'p95_seconds': sorted(values)[math.ceil(.95 * len(values)) - 1],
                               'historical': lane == 'docker'}
            ratio = lanes['candidate']['median_seconds'] / lanes['docker']['median_seconds']
            results[key] = {'lanes': lanes, 'candidate_to_docker': ratio, 'passed': ratio < 10}
    if report_dir is not None:
        retain_performance_reports(report_dir, results)
    if not all(value['passed'] for value in results.values()):
        raise RuntimeError('A matched Compose fixture reached the documented 10x slowdown gate')
    return results


def run_candidate_reference_benchmark(evidence: Path, runtime: object, candidate: list[str],
                                     ledger: ProjectLedger, issue: object,
                                     benchmark_reference: dict) -> dict:
    """Measure the candidate against the admitted immutable seven-trial Docker reference."""
    image = runtime.ALPINE
    reference = revalidate_benchmark_reference(evidence, image)
    if reference != benchmark_reference:
        raise RuntimeError('Published historical benchmark changed before live measurements')
    fixtures = evidence / 'fixtures'
    fixtures.mkdir()
    for count in benchmark_evidence.COUNTS:
        fixture(fixtures / f'{count}.yml', count, image)
    fixture_hashes = {str(count): sha(fixtures / f'{count}.yml')
                      for count in benchmark_evidence.COUNTS}
    if fixture_hashes != reference['workload']['fixtureSHA256']:
        raise RuntimeError('Current fixture bytes differ from the published reference')
    runtime_evidence = evidence / 'runtime'
    write(runtime_evidence / 'benchmark-host-before.json', benchmark_host_snapshot())
    measured, warmups = measure_lane(
        'candidate', candidate, fixtures, ledger, issue,
        runtime_evidence / 'compose-operations.json')
    write(runtime_evidence / 'benchmark-host-after.json', benchmark_host_snapshot())
    historical = [{**row, 'historical_reference': True}
                  for row in reference['samples']]
    return {'fixture_sha256': fixture_hashes,
            'budget': benchmark_budget(),
            'benchmark_reference': json.loads((evidence / 'benchmark-reference.json').read_text()),
            'benchmark_candidate_warmups': warmups,
            'benchmarks': compare(measured + historical, runtime_evidence)}


def performance_matrix_projects() -> list[tuple[str, str, str]]:
    rows = [('candidate', 'cc-perf-c-preflight', 'services-1.yml')]
    for lane, prefix in (('docker', 'cc-perf-d'), ('candidate', 'cc-perf-c')):
        for count in (1, 10, 50):
            rows.append((lane, f'{prefix}-{count}', f'services-{count}.yml'))
            rows.append((lane, f'{prefix}-aggregate-{count}', f'aggregate-{count}.yml'))
        rows.append((lane, f'{prefix}-logging', 'logging.yml'))
    return rows


def run_broad_performance_matrix(evidence: Path, runtime: object, install: Path,
                                 plugin: Path, runner: object) -> dict:
    """Run the full capped five-repetition matrix under the active live lease."""
    runtime_evidence = evidence / 'runtime'
    matrix_evidence = runtime_evidence / 'performance-matrix'
    work_root = ROOT / '.build/parity' / ('development-performance-' + uuid.uuid4().hex)
    if matrix_evidence.exists() or work_root.exists():
        raise RuntimeError('Broad performance matrix evidence path is already occupied')

    shutdown = stage(evidence, 'bazel-shutdown-before-performance-matrix',
                     [str(ROOT / 'Tools/bazel/run.sh'), 'shutdown'], 120)
    try:
        budget = performance_matrix_budget()
    except BaseException as error:
        write(runtime_evidence / 'performance-matrix-budget.json',
              {'schema': 1, 'passed': False, 'failure': str(error),
               'bazel_shutdown': shutdown})
        raise
    budget['bazel_shutdown'] = shutdown
    write(runtime_evidence / 'performance-matrix-budget.json', budget)

    environment = candidate_environment(runtime, install, runner.runtime_environment)
    environment.update(
        DOCKER_CONTEXT='colima', DOCKER_COMPOSE='docker --context colima compose',
        CONTAINER_COMPOSE=str(plugin / 'bin/compose'),
        COMPOSE_TEST_BINARY=str(plugin / 'bin/compose'),
        CONTAINER_COMPOSE_CONTAINER=str(install / 'bin/container'),
        CONTAINER_BIN=str(install / 'bin/container'),
        CONTAINER_COMPOSE_NORMALIZER=str(plugin / 'resources/compose-normalizer'),
        CONTAINER_COMPOSE_LIVE='1', CONTAINER_COMPOSE_BUILD_CHECK_LIVE='1',
        PARITY_EVIDENCE_DIR=str(matrix_evidence), PARITY_WORK_ROOT=str(work_root),
        PARITY_REPETITIONS='5', PARITY_FIXTURE_GROUPS='all',
        PARITY_SERVICE_MEMORY_MIB=str(PERFORMANCE_MATRIX_SERVICE_MEMORY_MIB),
        PARITY_RETAIN_FIXTURE_DIR='1', PARITY_INCLUDE_REMOTE_LOGGING='1',
        PARITY_SINK_BIND_ADDRESS='0.0.0.0',
        PARITY_DOCKER_HOST_ADDRESS='host.docker.internal',
        PARITY_CONTAINER_HOST_ADDRESS='127.0.0.1',
        PARITY_TIMEOUT_SECONDS='300')
    fixture_ids = subprocess.check_output(
        [str(ROOT / 'Tools/parity/check-compose-performance-matrix.sh'),
         '--list-fixtures'], text=True, timeout=30, env=environment).splitlines()
    if (len(fixture_ids) != 29
            or 'logging-blocking-slow-sink' not in fixture_ids
            or 'logging-dual-cache-read' not in fixture_ids
            or 'startup-50-services' not in fixture_ids
            or 'logging-aggregate-50-services' not in fixture_ids):
        raise RuntimeError('Broad matrix fixture selection is incomplete or changed')
    state_path = runtime_evidence / 'performance-matrix-state.json'

    cleanup_rows = []
    leftovers = []

    def run_cleanup_command(lane: str, name: str, args: list[str], timeout: int = 120) -> dict:
        runner.env = benchmark_issue_environment(lane, name, runtime, install,
                                                 runner.runtime_environment)
        command = ([str(install / 'bin/container')] if lane == 'candidate'
                   else ['docker', '--context', 'colima']) + args
        try:
            row = runner.run('performance-matrix-cleanup', lane, name,
                             len(cleanup_rows), command, ROOT, timeout)
        except BaseException as error:
            row = {'component': 'performance-matrix-cleanup', 'lane': lane,
                   'fixture': name, 'trial': len(cleanup_rows),
                   'status': 255, 'command': command, 'error': str(error)}
        cleanup_rows.append(row)
        return row

    def resource_snapshot(label: str) -> dict:
        snapshot = {}
        for lane in ('candidate', 'docker'):
            for kind, args in (
                    ('containers', ['ps', '-aq']),
                    ('networks', ['network', 'ls', '-q']),
                    ('volumes', ['volume', 'ls', '-q'])):
                row = run_cleanup_command(lane, label + '-' + kind, args, 90)
                if row['status']:
                    raise RuntimeError(f'{label} {lane} {kind} inventory failed; '
                                       + row.get('log', row.get('error', 'unknown command failure')))
                snapshot[lane + '/' + kind] = sorted(
                    Path(row['log']).read_text(errors='replace').splitlines())
        return snapshot

    before = resource_snapshot('before-matrix')
    write(state_path, {'schema': 1, 'started': True,
                       'fixture_count': len(fixture_ids),
                       'fixture_ids': fixture_ids,
                       'profile': {'repetitions': 5, 'remote_logging': True,
                                   'service_memory_mib': PERFORMANCE_MATRIX_SERVICE_MEMORY_MIB},
                       'budget_sha256': sha(runtime_evidence / 'performance-matrix-budget.json')})

    stage_error = None
    stage_row = None
    try:
        runner.env = environment
        stage_row = runner.run(
            'compose', 'candidate', 'broad-performance-matrix', 0,
            [str(ROOT / 'Tools/parity/check-compose-performance-matrix.sh'),
             '--strict'], ROOT, 21600)
        runner.report()
        if stage_row['status']:
            stage_error = f"matrix process exited {stage_row['status']}; see {stage_row['log']}"
    except BaseException as error:
        stage_error = str(error)

    manifest_path = matrix_evidence / 'workload.json'
    try:
        workload = json.loads(manifest_path.read_text()) if manifest_path.is_file() else None
    except (OSError, json.JSONDecodeError) as error:
        workload = None
        stage_error = stage_error or 'Broad matrix workload manifest is unreadable: ' + str(error)
    fixture_directory = None
    if workload is not None:
        try:
            fixture_directory = Path(workload['fixtureDirectory']).resolve()
            if (workload.get('serviceMemoryMiB') != PERFORMANCE_MATRIX_SERVICE_MEMORY_MIB
                    or fixture_directory.parent != work_root.resolve()
                    or not isinstance(workload.get('fixtureSHA256'), dict)):
                stage_error = stage_error or 'Broad matrix workload manifest failed exact profile admission'
        except (KeyError, TypeError, OSError) as error:
            stage_error = stage_error or 'Broad matrix workload manifest is malformed: ' + str(error)

    if fixture_directory is not None and fixture_directory.is_dir():
        for lane, project, filename in performance_matrix_projects():
            fixture_path = fixture_directory / filename
            if not fixture_path.is_file():
                continue
            row = run_cleanup_command(lane, project + '-down',
                                      ['compose', '-p', project, '-f', str(fixture_path),
                                       'down', '--volumes', '--remove-orphans'])
            if row['status']:
                leftovers.append({'lane': lane, 'project': project,
                                  'kind': 'cleanup', 'status': row['status'],
                                  'log': row.get('log'), 'error': row.get('error')})
    else:
        # No workload was started if fixture generation did not produce its admission receipt.
        if stage_row is not None:
            stage_error = stage_error or 'Broad matrix completed without a retained workload manifest'

    try:
        after = resource_snapshot('after-matrix')
        for key in before:
            if before[key] != after[key]:
                leftovers.append({'kind': 'resource-inventory-changed', 'resource': key,
                                  'before': before[key], 'after': after[key]})
    except BaseException as error:
        after = None
        leftovers.append({'kind': 'resource-inventory-failed', 'error': str(error)})
    cleanup = {'schema': 1, 'verified': not leftovers,
               'projects': [project for _, project, _ in performance_matrix_projects()],
               'resource_inventory_before': before,
               'resource_inventory_after': after,
               'workload_manifest': str(manifest_path) if workload is not None else None,
               'cleanup_commands': cleanup_rows, 'leftovers': leftovers,
               'stage_error': stage_error}
    if fixture_directory is not None and fixture_directory.is_dir() and not leftovers:
        retained_fixtures = matrix_evidence / 'fixtures'
        if retained_fixtures.exists():
            leftovers.append({'kind': 'evidence-collision',
                              'path': str(retained_fixtures)})
            cleanup['verified'] = False
            cleanup['leftovers'] = leftovers
        else:
            expected_hashes = workload.get('fixtureSHA256', {})
            observed_hashes = {path.name: sha(path) for path in sorted(fixture_directory.glob('*.yml'))}
            if observed_hashes != expected_hashes:
                leftovers.append({'kind': 'fixture-bytes-changed',
                                  'expected': expected_hashes,
                                  'observed': observed_hashes})
                cleanup['verified'] = False
                cleanup['leftovers'] = leftovers
            else:
                shutil.copytree(fixture_directory, retained_fixtures)
                workload['fixtureDirectory'] = str(retained_fixtures)
                write(manifest_path, workload)
                shutil.rmtree(work_root)
                cleanup['retained_fixture_directory'] = str(retained_fixtures)
    write(runtime_evidence / 'performance-matrix-cleanup.json', cleanup)
    write(state_path, {'schema': 1, 'started': True, 'completed': True,
                       'passed': stage_error is None and not leftovers,
                       'cleanup_verified': not leftovers,
                       'fixture_count': len(fixture_ids),
                       'fixture_ids': fixture_ids,
                       'profile': {'repetitions': 5, 'remote_logging': True,
                                   'service_memory_mib': PERFORMANCE_MATRIX_SERVICE_MEMORY_MIB},
                       'budget_sha256': sha(runtime_evidence / 'performance-matrix-budget.json'),
                       'cleanup_sha256': sha(runtime_evidence / 'performance-matrix-cleanup.json')})
    if leftovers:
        raise RuntimeError('Broad performance matrix left resources; see performance-matrix-cleanup.json')
    if stage_error:
        raise RuntimeError('Broad performance matrix failed: ' + stage_error)
    if stage_row is None:
        raise RuntimeError('Broad performance matrix did not produce a stage receipt')
    fingerprint = json.loads((matrix_evidence / 'fingerprints.json').read_text())
    return {'passed': True, 'stage': stage_row,
            'budget_sha256': sha(runtime_evidence / 'performance-matrix-budget.json'),
            'fingerprint_sha256': sha(matrix_evidence / 'fingerprints.json'),
            'workload_sha256': sha(manifest_path),
            'fixture_count': len(fixture_ids),
            'fixture_ids': fixture_ids,
            'repetitions': fingerprint['conditions']['repetitions'],
            'remote_logging': fingerprint['conditions']['remoteLogging'],
            'service_memory_mib': fingerprint['conditions']['serviceMemoryMiB'],
            'cleanup_sha256': sha(runtime_evidence / 'performance-matrix-cleanup.json')}


def retain_performance_reports(directory: Path, results: dict) -> None:
    rows = ['# Matched Compose performance', '',
            'Seven same-fixture trials per lane; Docker is a released historical reference. '
            'P95 uses nearest rank.', '',
            '| Fixture | Candidate median (s) | Docker median (s) | Candidate P95 (s) | Docker P95 (s) | Median ratio |',
            '| --- | ---: | ---: | ---: | ---: | ---: |']
    suite = ElementTree.Element('testsuite', name='compose-matched-performance',
                                tests=str(len(results)), failures='0')
    for name, record in results.items():
        candidate, docker = record['lanes']['candidate'], record['lanes']['docker']
        rows.append(f"| {name} | {candidate['median_seconds']:.3f} | {docker['median_seconds']:.3f} | "
                    f"{candidate['p95_seconds']:.3f} | {docker['p95_seconds']:.3f} | "
                    f"{record['candidate_to_docker']:.2f}x |")
        case = ElementTree.SubElement(suite, 'testcase', name=name,
                                      classname='compose.performance')
        ElementTree.SubElement(case, 'system-out').text = json.dumps(record, sort_keys=True)
        if not record['passed']:
            suite.set('failures', str(int(suite.get('failures', '0')) + 1))
            ElementTree.SubElement(case, 'failure', message='Median slowdown reached 10x')
    (directory / 'performance-comparison.md').write_text('\n'.join(rows) + '\n')
    ElementTree.ElementTree(suite).write(directory / 'performance-junit.xml',
                                         encoding='utf-8', xml_declaration=True)


def full_suite_sources() -> dict[str, str]:
    return {'runtime-suite': sha(ROOT / 'Tests/ComposeRuntimeTests/ComposeRuntimeSmokeTests.swift'),
            **{row['target']: row['script_sha256'] for row in full_suite.inventory()}}


def expected_case_cleanup_resource(case: str, resource: dict) -> bool:
    if (resource['lane'] == 'candidate' and resource['kind'] == 'containers'
            and full_suite.authorized_builder(resource['name'], case)):
        return True
    # Ledger.difference has already admitted this image against source-declared
    # case/project image namespaces and proven every original ref+digest intact.
    return resource['kind'] == 'images'


def require_runtime_test_summary(output: str) -> None:
    """Require Swift Testing's terminal summary for the original 27 tests."""
    summaries = re.findall(
        r'(?m)^(?:✔ )?Test run with ([1-9][0-9]*) tests?'
        r'(?: in [1-9][0-9]* suites?)? passed after [0-9]+(?:\.[0-9]+)? seconds?\.$',
        output)
    if not summaries or int(summaries[-1]) != 27:
        raise RuntimeError('Original live runtime suite did not report all 27 passing tests')


def verified_journald_archive(install: Path, payload: dict[str, str]) -> tuple[Path, dict]:
    """Bind a preloaded OCI image to the exact released Q service payload."""
    prefix = 'libexec/container/services/journald/container-journald-service'
    archive_name, manifest_name = prefix + '.oci.tar', prefix + '.manifest.json'
    archive, manifest_path = install / archive_name, install / manifest_name
    for name, path in ((archive_name, archive), (manifest_name, manifest_path)):
        if (not path.is_file() or path.is_symlink() or
                not re.fullmatch(r'[0-9a-f]{64}', payload.get(name, '')) or
                sha(path) != payload[name]):
            raise RuntimeError('Released Q journald asset changed: ' + name)
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get('schemaVersion') != 1 or manifest.get('platform') != 'linux'
            or manifest.get('architecture') != 'arm64'
            or manifest.get('ociArchiveSHA256') != payload[archive_name]
            or not re.fullmatch(r'sha256:[0-9a-f]{64}',
                                manifest.get('workloadManifestDigest', ''))):
        raise RuntimeError('Released Q journald manifest does not bind its OCI image')
    return archive, {'archive_sha256': payload[archive_name],
                     'manifest_sha256': payload[manifest_name],
                     'workload_manifest_digest': manifest['workloadManifestDigest']}


def preload_original_fixture_images(runtime_image: str, install: Path,
                                    issue: object, present: object) -> list[dict]:
    """Resolve every image the maintained live fixture can otherwise pull later."""
    rows = []
    for image in (runtime_image, 'alpine:3.22', *ORIGINAL_FIXTURE_IMAGES):
        for lane in ('candidate', 'docker'):
            if present(lane, image):
                rows.append({'lane': lane, 'image': image, 'already_present': True})
                continue
            base = ([str(install / 'bin/container')] if lane == 'candidate'
                    else ['docker', '--context', 'colima'])
            args = (['image', 'pull', '--progress', 'none', '--platform', 'linux/arm64', image]
                    if lane == 'candidate' else ['pull', '--platform', 'linux/arm64', image])
            issue(lane, 'setup-original-fixture-image', 0, base + args, 300)
            rows.append({'lane': lane, 'image': image, 'already_present': False})
    return rows


def qualified_fixture_app(runtime: object, *, require_app: bool = True) -> Path:
    """Bind direct image-store seeding to Q's owned private, idle app tree."""
    state = Path('/private/tmp') / f'cfb-{os.getuid()}'
    if runtime.STATE != state:
        raise RuntimeError('Qualified Q fixture cache root changed')
    return _checked_fixture_app(runtime, state, RETAINED, require_app=require_app)


def _checked_fixture_app(runtime: object, state: Path, retained: Path,
                         *, require_app: bool) -> Path:
    fork = state / 'fork'
    for path in (state, fork, retained):
        if path.is_symlink() or (path.exists() and not path.is_dir()) \
                or (path == retained and not path.is_dir()):
            raise RuntimeError('Qualified fixture cache directory changed: ' + str(path))
        if path.exists() and path.stat().st_uid != os.getuid():
            raise RuntimeError('Qualified fixture cache owner changed: ' + str(path))
    app = fork / 'app'
    if app.is_symlink() or (app.exists() and not app.is_dir()) or (require_app and not app.is_dir()):
        raise RuntimeError('Qualified fixture cache app changed: ' + str(app))
    if app.is_dir() and app.stat().st_uid != os.getuid():
        raise RuntimeError('Qualified fixture cache app owner changed: ' + str(app))
    runtime.own(fork, 'fork')
    if fork.is_symlink() or fork.stat().st_uid != os.getuid():
        raise RuntimeError('Qualified fixture cache owner changed: ' + str(fork))
    return app


def run_original_full_suite(evidence: Path, runner: object, runtime: object,
                            install: Path, plugin: Path, native_tests: dict,
                            issue: object, *, development_bridge: bool = False,
                            development_parity: bool = False) -> dict:
    """Execute the unchanged 27/66 checks with one enrolled case at a time."""
    base = evidence / 'full-suite'
    base.mkdir()
    ledger = full_suite.Ledger(base)
    sources = full_suite_sources()
    rows = []
    sequence = 0
    def invoke(lane: str, kind: str, args: list[str]) -> str:
        nonlocal sequence
        sequence += 1
        command = [str(install / 'bin/container') if args[0] == 'container' else args[0], *args[1:]]
        row = issue(lane, 'full-inventory-' + kind, sequence, command, 60)
        return Path(row['log']).read_text(errors='replace')
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                                  text=True, timeout=20).strip()
    scratch = full_suite_scratch.create(evidence)
    common = dict(candidate_environment(runtime, install, runner.runtime_environment),
                  DOCKER_CONTEXT='colima', DOCKER_COMPOSE='docker --context colima compose',
                  CONTAINER_COMPOSE=str(plugin / 'bin/compose'),
                  COMPOSE_TEST_BINARY=str(plugin / 'bin/compose'),
                  CONTAINER_COMPOSE_CONTAINER=str(install / 'bin/container'),
                  CONTAINER_BIN=str(install / 'bin/container'),
                  CONTAINER_COMPOSE_NORMALIZER=str(plugin / 'resources/compose-normalizer'),
                  CONTAINER_COMPOSE_LIVE='1', CONTAINER_COMPOSE_BUILD_CHECK_LIVE='1',
                  COMPOSE_PARITY_TEST_RUNNER=str(ROOT / 'Tools/bazel/prebuilt_parity_tests.py'),
                  PARITY_TIMEOUT_SECONDS='300', SDKROOT=sdk,
                  TEST_TMPDIR=str(scratch), TMPDIR=str(scratch) + '/')
    if not development_bridge:
        common.update(COMPOSE_PREBUILT_CORE_TEST=native_tests['ComposeCoreTests']['path'],
                      COMPOSE_PREBUILT_PLUGIN_TEST=native_tests['ComposePluginTests']['path'])
    for name, record in native_tests.items():
        path = Path(record['path'])
        if (not path.is_file() or sha(path) != record['sha256']
                or path.with_name(name + '.runfiles') != Path(record['runfiles'])
                or not Path(record['runfiles']).is_dir()
                or test_workspace(Path(record['runfiles']), name,
                                  'ComposeRuntimeFixtures.bundle'
                                  if name == 'ComposeRuntimeTests' else None) != record['workspace']):
            raise RuntimeError('Native test executable/runfiles changed after cached build: ' + name)
    def run_case(name: str, source_hash: str, prefixes: list[str],
                 args: list[str], environment: dict, timeout: int,
                 image_prefixes: list[str] | None = None,
                 fixed_names: list[str] | None = None) -> None:
        baseline = full_suite.snapshot(invoke)
        fixed_images = list(full_suite.FIXED_OUTPUT_IMAGES.get(name, ()))
        if name == 'docker-compose-build-external-secret-parity':
            fixed_images.append('container-compose-external-build-secret-'
                                + environment['IMAGE_SUFFIX'] + ':latest')
        if name in full_suite.UNIQUE_OUTPUT_IMAGE_PREFIXES:
            fixed_images.append(environment['PARITY_OUTPUT_IMAGE'])
            image_prefixes = [environment['PARITY_OUTPUT_IMAGE']]
        full_suite.assert_namespace_free(baseline, name, fixed_names, fixed_images)
        ledger.begin(name, source_hash, prefixes, baseline, image_prefixes, supervised=True)
        # The private CLI changes process group, so Q's group-only watchdog
        # cannot establish that all writers have stopped before hashing logs.
        from fork_benchmark import command_lease
        environment = dict(environment, COMPOSE_FULL_SUITE_QUALIFIED='1',
                           **{cli_process.CASE_NONCE: uuid.uuid4().hex})
        number = len(runner.rows)
        log = runner.evidence / f'{number:03}-compose-full-suite-candidate-{name}-0.log'
        started = time.monotonic_ns()
        with command_lease(environment) as descriptors, log.open('w') as stream:
            try:
                status = cli_process.run(
                    args, cwd=ROOT, env=environment, stdout=stream,
                    stderr=subprocess.STDOUT, timeout=timeout, pass_fds=descriptors,
                    on_start=lambda session: ledger.claim_session(name, source_hash, session),
                    on_clear=lambda: ledger.clear_session(name))
            except subprocess.TimeoutExpired:
                status = 124
        row = {'component': 'compose-full-suite', 'lane': 'candidate', 'fixture': name,
               'trial': 0, 'seconds': (time.monotonic_ns() - started) / 1e9,
               'status': status, 'command': [str(arg) for arg in args], 'log': str(log)}
        runner.rows.append(row)
        write(runner.evidence / 'results.json', runner.rows)
        rows.append(row)
        write(base / (name + '.json'), {'name': name, 'source_sha256': source_hash,
                                        'status': row['status'], 'log': row['log'],
                                        'log_sha256': sha(Path(row['log']))})
        removed = ledger.recover(invoke, sources)
        expected = all(expected_case_cleanup_resource(name, resource)
                       for resource in removed)
        if row['status'] or (removed and not expected):
            raise RuntimeError('Original full-suite case failed or leaked resources: ' + name)
    if not (development_bridge or development_parity):
        test = native_tests['ComposeRuntimeTests']
        workspace = test['workspace']
        run_case('runtime-suite', sources['runtime-suite'], ['ccrt-'], [test['path']],
                 dict(common, CONTAINER_COMPOSE_RUN_RUNTIME_TESTS='1',
                      TEST_SRCDIR=test['runfiles'], TEST_WORKSPACE=workspace), 1800,
                 list(full_suite.EXTRA_IMAGE_PREFIXES['runtime-suite']))
        output = Path(rows[-1]['log']).read_text(errors='replace')
        require_runtime_test_summary(output)
    selected = full_suite.inventory()
    if development_bridge:
        selected = [item for item in selected
                    if item['target'] == 'docker-compose-bridge-parity']
        if len(selected) != 1:
            raise RuntimeError('Original Bridge parity case is absent from inventory')
    for item in selected:
        name = item['target']
        case_dir = base / 'cases' / name
        case_dir.mkdir(parents=True)
        env = dict(common, PARITY_EVIDENCE_DIR=str(case_dir))
        env['PARITY_TIMING_OUTPUT'] = str(case_dir / 'timing.tsv')
        if name in full_suite.UNIQUE_OUTPUT_IMAGE_PREFIXES:
            env['PARITY_OUTPUT_IMAGE'] = full_suite.UNIQUE_OUTPUT_IMAGE_PREFIXES[name] + uuid.uuid4().hex
        if name in full_suite.MOUNT_JOURNAL_CASES:
            env['COMPOSE_FULL_SUITE_MOUNT_JOURNAL'] = str(case_dir / 'mounts.json')
        if name == 'docker-compose-build-external-secret-parity':
            keychain = base / 'keychain/build-external-secret'
            keychain.parent.mkdir(parents=True, exist_ok=True)
            env['COMPOSE_PARITY_KEYCHAIN_JOURNAL_DIR'] = str(keychain)
            env['IMAGE_SUFFIX'] = 'cfq' + str(os.getpid())
        run_case(name, item['script_sha256'], item['owned_prefixes'],
                 [item['script'], '--strict'], env, 600,
                 item['owned_image_prefixes'], item['fixed_names'])
    if development_bridge or development_parity:
        target = 'compose-development-bridge' if development_bridge else 'compose-development-parity'
        if len(rows) != (1 if development_bridge else 66):
            raise RuntimeError('Development parity selected an incomplete original inventory')
        receipt = {'schema': 1, 'target': target, 'passed': True,
                   'parity_cases': len(rows), 'rows': rows,
                   'ledger_sha256': sha(ledger.path)}
        if development_bridge:
            receipt['case'] = rows[0]['fixture']
        write(base / ('development-bridge.json' if development_bridge
                      else 'development-parity.json'), receipt)
        return receipt
    receipt = {'passed': True, 'runtime_tests': 27, 'parity_cases': len(rows) - 1,
               'rows': rows, 'ledger_sha256': sha(ledger.path)}
    write(base / 'acceptance.json', receipt)
    return receipt


def run_live(evidence: Path, q: dict, plugin: Path, signed: dict,
             q_assets: dict, native_tests: dict, benchmark_reference: dict | None, *,
             development_bridge: bool = False,
             development_parity: bool = False,
             development_performance: bool = False) -> dict:
    """Own signed Q release bytes, private plugin and exact host/command leases."""
    modules = q['modules']
    runtime = modules['runtime_benchmark']
    fb = modules['fork_benchmark']
    unattended = modules['unattended']
    runtime_evidence = evidence / 'runtime'
    runtime_evidence.mkdir()
    q_assets = revalidate_q_assets(evidence / 'q-assets', q['hashes'])
    provenance = q_assets['provenance']
    original_fingerprint = json.loads((Q_EVIDENCE / 'runtime-smoke/fork-fingerprint.json').read_text())
    fingerprint = dict(original_fingerprint, **{name: value for name, value in provenance['runtime'].items()
                                                if name not in {'payload', 'notary'}},
                       binaries=provenance['runtime']['payload'],
                       installed_archive_sha256=q_assets['assets']['runtime']['sha256'])
    write(runtime_evidence / 'fork-fingerprint.json', fingerprint)
    for name in ('guest', 'builder'):
        product = provenance[name]
        write(runtime_evidence / (name + '-artifact.json'), {
            'schema': 1, 'identity': {'source': product['source']},
            'reference': product['reference'],
            'archive': q_assets['assets'][name]['path'],
            'archive_sha256': q_assets['assets'][name]['sha256']})
    install = runtime.INSTALLS / 'fork/install'
    runtime_lease = RuntimeArchiveLease(
        evidence, install, Path(q_assets['assets']['runtime']['path']),
        provenance['runtime']['payload'], original_fingerprint['binaries'])
    plugin_lease = PluginLease(evidence, install, signed, original_fingerprint['binaries'],
                               combined_runtime=True)
    result = {'passed': False, 'failures': [], 'benchmarks': {}, 'runtime_install': str(install)}
    host = modules['host_lease'].HostLease(evidence)
    colima = unattended.ColimaLease(evidence)
    stock = runtime.StockSlot(evidence)
    runner = runtime.RuntimeRunner(runtime_evidence, fb.STORAGE)
    ledger = ProjectLedger(evidence)
    candidate = [str(install / 'bin/container'), 'compose']
    def issue(lane: str, fixture_name: str, trial: int, command: list[str], timeout: int = 180) -> dict:
        runner.env = benchmark_issue_environment(lane, fixture_name, runtime, install,
                                                 runner.runtime_environment)
        row = runner.run('compose', lane, fixture_name, trial, command, ROOT, timeout)
        if row['status']:
            raise RuntimeError(f'{lane}/{fixture_name}/{trial} failed; see {row["log"]}')
        return row
    command_lock = evidence / 'commands.lock'
    marker = evidence / 'live-recovery-required.json'
    marker.write_text(json.dumps({'reason': 'private live qualification in flight'}) + '\n')
    # Keep Q's benchmark and host ownership locks for the entire plugin lease.
    with (fb.STORAGE / 'qualification.lock').open('w') as qualify_lock, \
         (runtime.INSTALLS / 'benchmark.lock').open('w') as benchmark_lock, ExitStack() as commands:
        fcntl.flock(qualify_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(benchmark_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        host.record['command_lock'] = str(command_lock)
        host.record['bazel_workspace'] = str(Q_ROOT)
        descriptor = os.open(command_lock, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
        os.close(descriptor)
        colima.command_descriptors = commands.enter_context(fb.command_lease({fb.COMMAND_LOCK_ENV: str(command_lock)}))
        runner.runtime_environment[fb.COMMAND_LOCK_ENV] = str(command_lock)
        cleanup_ok = True
        host_acquired = False
        try:
            # The host may have changed during cached builds or hosted admission.
            readiness = modules['preflight'].check('runtime', json.loads(modules['preflight'].CONFIG.read_text()))
            failed = [c['check'] for c in readiness['checks'] if not c['ready']]
            pending_api_hold = failed == ['apple-runtime-slot'] and json.loads(modules['preflight'].CONFIG.read_text()).get('failed_api_hold') is not None
            if not readiness['ready'] and not pending_api_hold:
                raise RuntimeError('Host is no longer ready before resource ownership')
            modules['runtime_coverage'].require_idle(install)
            if any(pid != '-' for pid, _ in runtime.services(runtime.NAMESPACE + '.')):
                raise RuntimeError('Private qualified runtime activated before lease')
            host.acquire()
            host_acquired = True
            if pending_api_hold:
                modules['failed_api_hold'].hold_failed_api(stock, json.loads(modules['preflight'].CONFIG.read_text())['failed_api_hold'])
                if not modules['preflight'].apple_runtime_slot_ready():
                    raise RuntimeError('Original runtime slot unavailable after approved failed API hold')
            stock.acquire()
            colima.acquire()
            for fd in colima.command_descriptors:
                fcntl.flock(fd, fcntl.LOCK_UN)
            commands.close()
            colima.command_descriptors = ()
            runtime_lease.acquire(modules['release_install'].checked_payload,
                                  runtime, modules['runtime_coverage'])
            private_app = qualified_fixture_app(runtime, require_app=False)
            fixture_references = (runtime.ALPINE, 'alpine:3.22',
                                  *ORIGINAL_FIXTURE_IMAGES, API_SOCKET_IMAGE)
            cached_before_reset = fixture_cache.capture(
                private_app, FIXTURE_CACHE, fixture_references, container_root=Q_ROOT)
            write(runtime_evidence / 'fixture-cache-before-reset.json',
                  {'schema': 1, 'references': [row['reference'] for row in cached_before_reset],
                   'roots': {row['reference']: row['root']['digest'] for row in cached_before_reset}})
            if runtime.reset_state('fork', fingerprint['init_image'], fingerprint['builder_image']) != fingerprint['kernel_sha256']:
                raise RuntimeError('Released Q private runtime kernel changed')
            qualified_fixture_app(runtime)
            restored_fixtures = fixture_cache.restore(
                private_app, FIXTURE_CACHE, fixture_references, container_root=Q_ROOT)
            write(runtime_evidence / 'fixture-cache-restored.json',
                  {'schema': 1, 'references': [row['reference'] for row in restored_fixtures],
                   'roots': {row['reference']: row['root']['digest'] for row in restored_fixtures}})
            plugin_lease.acquire(plugin)
            runtime.start_lane(runner, 'fork')
            journald_archive, journald_identity = verified_journald_archive(
                install, runtime_lease.payload)
            row = issue('candidate', 'setup-released-journald-image', 0,
                        [str(install / 'bin/container'), 'image', 'load', '--input',
                         str(journald_archive)], 300)
            write(runtime_evidence / 'journald-preload.json',
                  dict(journald_identity, load_log_sha256=sha(Path(row['log']))))
            fixture_inventories = {}
            def fixture_image_present(lane: str, image: str) -> bool:
                if lane not in fixture_inventories:
                    base = ([str(install / 'bin/container')] if lane == 'candidate'
                            else ['docker', '--context', 'colima'])
                    args = (['image', 'list', '--format', 'json'] if lane == 'candidate'
                            else ['image', 'ls', '--no-trunc', '--format',
                                  '{{.Repository}}:{{.Tag}} {{.ID}}'])
                    listed = issue(lane, 'setup-original-fixture-image-inventory', 0,
                                   base + args, 90)
                    output = Path(listed['log']).read_text(errors='replace')
                    images = (full_suite.native_images(output) if lane == 'candidate'
                              else full_suite.docker_images(output))
                    if lane == 'candidate':
                        fixture_inventories[lane] = {
                            row['configuration']['name']: row for row in json.loads(output)}
                    else:
                        fixture_inventories[lane] = images
                reference = fixture_cache.normalized(image) if lane == 'candidate' else full_suite.image_reference(image)
                if lane == 'candidate':
                    rows = fixture_inventories[lane]
                    row = fixture_cache.native_record(rows, reference)
                    if row is None:
                        return False
                    observed = row['configuration']['descriptor']['digest']
                    cached = fixture_cache.entry_path(FIXTURE_CACHE, reference)
                    if cached.exists() or cached.is_symlink():
                        cached_receipt = fixture_cache.receipt(cached, reference, container_root=Q_ROOT)
                        expected = cached_receipt['root']['digest']
                        if observed != expected:
                            raise RuntimeError('Qualified cached fixture image changed: ' + reference)
                        arm64 = [variant for variant in row['variants']
                                 if variant.get('platform', {}).get('os') == 'linux'
                                 and variant.get('platform', {}).get('architecture') == 'arm64']
                        if len(arm64) != 1 or arm64[0]['digest'] != cached_receipt['arm64_manifest']:
                            raise RuntimeError('Qualified cached fixture arm64 variant changed: ' + reference)
                    if '@sha256:' in reference and observed != reference.split('@', 1)[1]:
                        raise RuntimeError('Qualified pinned fixture image changed: ' + reference)
                    return True
                if '@sha256:' not in reference:
                    return reference in {full_suite.image_reference(identity)
                                         for identity in fixture_inventories[lane]}
                candidates = fixture_cache.docker_pinned_candidates(
                    fixture_inventories[lane], image)
                for identity in sorted(candidates):
                    inspected = issue('docker', 'setup-pinned-fixture-image-inspect', 0,
                                      ['docker', '--context', 'colima', 'image', 'inspect',
                                       '--format', '{{.Os}}|{{.Architecture}}|{{.Variant}}|{{json .RepoDigests}}',
                                       identity], 90)
                    if fixture_cache.docker_pinned_metadata_matches(
                            Path(inspected['log']).read_text(), image):
                        return True
                return False
            fixture_rows = preload_original_fixture_images(
                runtime.ALPINE, install, issue, fixture_image_present)
            if not fixture_image_present('candidate', API_SOCKET_IMAGE):
                issue('candidate', 'setup-api-socket-image', 0,
                      [str(install / 'bin/container'), 'image', 'pull', '--progress', 'none',
                       '--platform', 'linux/arm64', API_SOCKET_IMAGE], 300)
            cached_after_setup = fixture_cache.capture(
                private_app, FIXTURE_CACHE, fixture_references, container_root=Q_ROOT)
            expected_fixture_refs = {fixture_cache.normalized(image) for image in fixture_references}
            if {row['reference'] for row in cached_after_setup} != expected_fixture_refs:
                raise RuntimeError('Prepared Q fixture cache omitted a required image')
            fixture_inventories.pop('candidate', None)
            for image in fixture_references:
                reference = fixture_cache.normalized(image)
                cached_entry = fixture_cache.entry_path(FIXTURE_CACHE, reference)
                if cached_entry.exists() or cached_entry.is_symlink():
                    if not fixture_image_present('candidate', image):
                        raise RuntimeError('Prepared Q fixture image disappeared: ' + reference)
            write(runtime_evidence / 'fixture-cache-after-setup.json',
                  {'schema': 1, 'references': [row['reference'] for row in cached_after_setup],
                   'roots': {row['reference']: row['root']['digest'] for row in cached_after_setup}})
            write(runtime_evidence / 'fixture-image-preload.json',
                  {'schema': 1, 'images': fixture_rows})
            issue('candidate', 'setup-version', 0, candidate + ['version'], 60)
            suite = run_original_full_suite(
                evidence, runner, runtime, install, plugin, native_tests, issue,
                development_bridge=development_bridge,
                development_parity=development_parity)
            if development_bridge:
                result['development_bridge'] = suite
            elif development_parity:
                result['development_parity'] = suite
            else:
                result['original_full_suite'] = suite
            time.sleep(5)
            quiet = full_suite.Ledger(evidence / 'full-suite').verify_quiet(
                lambda lane, kind, args: Path(issue(
                    lane, 'full-suite-settle-' + kind, 0,
                    [str(install / 'bin/container') if args[0] == 'container'
                     else args[0], *args[1:]], 90)['log']).read_text(errors='replace'))
            write(evidence / 'full-suite/quiet-baseline.json',
                  {'schema': 1, 'settle_seconds': 5,
                   'inventory_sha256': hashlib.sha256(json.dumps(
                       quiet, sort_keys=True).encode()).hexdigest()})
            if development_performance or not (development_bridge or development_parity):
                result.update(run_candidate_reference_benchmark(
                    evidence, runtime, candidate, ledger, issue, benchmark_reference))
            if development_performance:
                result['broad_performance_matrix'] = run_broad_performance_matrix(
                    evidence, runtime, install, plugin, runner)
            result['passed'] = True
        except BaseException as error:
            result['failures'].append(str(error))
        finally:
            # Acquire exclusive authority before retrying any project. An
            # escaped command holder must not recreate it after verification.
            commands.close()
            phases = None
            try:
                colima.command_descriptors = unattended.acquire_cleanup_commands(evidence, commands, str(Q_ROOT))
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append('Owned command lease remains busy: ' + str(error))
            else:
                try:
                    restore_parity_keychain(evidence, colima.command_descriptors)
                    full_clear = ensure_full_suite_cleared(
                        evidence, q, colima.command_descriptors,
                        command_lock, allow_existing=False)
                    if full_clear['removed_count']:
                        result['passed'] = False
                        result['failures'].append('Original full suite left resources; verified cleanup retained')
                    ensure_projects_cleared(evidence, ledger, q, colima.command_descriptors,
                                            command_lock, allow_existing=False)
                    phases = CleanupPhases(evidence, ledger, q, command_lock)
                    phases.mark('full_suite')
                    phases.mark('projects')
                except BaseException as error:
                    cleanup_ok = False
                    result['failures'].append('Owned project cleanup failed: ' + str(error))
                runtime_idle = not host_acquired
                if phases is not None:
                    try:
                        if host_acquired:
                            runtime.stop_owned('fork')
                        modules['runtime_coverage'].require_idle(install)
                        full_suite_scratch.restore(evidence)
                        runtime_idle = True
                        phases.mark('runtime')
                    except BaseException as error:
                        cleanup_ok = False
                        result['failures'].append(str(error))
                if runtime_idle and phases is not None and phases.has('runtime'):
                    try:
                        plugin_lease.restore()
                        if (evidence / 'plugin-lease.json').exists():
                            verified_plugin_restored(plugin_lease)
                        phases.mark('plugin')
                    except BaseException as error:
                        cleanup_ok = False
                        result['failures'].append(str(error))
                plugin_restored = (not (evidence / 'plugin-lease.json').exists()
                                   or plugin_lease.record['restored'])
                if phases is not None and phases.has('plugin') and plugin_restored:
                    try:
                        runtime_lease.restore(modules['runtime_coverage'])
                        modules['runtime_coverage'].verify_binaries(
                            install, original_fingerprint['binaries'])
                        phases.mark('private_install')
                    except BaseException as error:
                        cleanup_ok = False
                        result['failures'].append(str(error))
                if phases is not None and phases.has('private_install'):
                    try:
                        restore_colima_after_projects(colima, ledger)
                        if colima.record['restored'] is not True:
                            raise RuntimeError('Colima restoration was not recorded')
                        phases.mark('colima')
                        stock.restore()
                        if not all(row.get('restored') is True for row in stock.saved):
                            raise RuntimeError('Original service restoration was not recorded')
                        phases.mark('stock')
                    except BaseException as error:
                        cleanup_ok = False
                        result['failures'].append(str(error))
                else:
                    cleanup_ok = False
                    result['failures'].append('Project, runtime or private installation remains active; preserving original registrations')
                if cleanup_ok and phases is not None and phases.has('stock'):
                    try:
                        if (evidence / 'runtime-install.json').exists():
                            runtime_lease.finalize()
                        unattended.verify_installations(evidence)
                        phases.mark('install')
                    except BaseException as error:
                        cleanup_ok = False
                        result['failures'].append(str(error))
            try:
                host.restore(restore_workers=cleanup_ok)
                if cleanup_ok and phases is not None and phases.has('install'):
                    phases.mark('host')
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append(str(error))
            finally:
                host.close()
            result['passed'] = result['passed'] and cleanup_ok and not ledger.active()
            write(evidence / 'live.json', result)
            if result['passed']:
                marker.unlink()
    if not result['passed']:
        raise RuntimeError('Live qualification/restoration failed; see ' + str(evidence / 'live.json'))
    return result


def notarize(evidence: Path, plugin: Path, signed: dict, profile: str) -> dict:
    archive = evidence / 'signed-compose.zip'
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(plugin), str(archive)],
                   check=True, timeout=120)
    raw = subprocess.check_output(['/usr/bin/xcrun', 'notarytool', 'submit', str(archive),
                                   '--keychain-profile', profile, '--wait', '--output-format', 'json'],
                                  text=True, timeout=3600)
    result = json.loads(raw)
    receipt = {'source': signed['source'], 'signed_payload': signed['payload'],
               'archive': str(archive), 'archive_sha256': sha(archive), 'notary': result,
               'passed': result.get('status') == 'Accepted'}
    write(evidence / 'notarization.json', receipt)
    if not receipt['passed']:
        raise RuntimeError('Same signed candidate was not accepted by Apple notarization')
    if PluginLease.tree(plugin) != signed['tree']:
        raise RuntimeError('Measured signed payload changed after notarization')
    return receipt


def recover_command(evidence: Path, name: str, args: list[str], environment: dict,
                    descriptors: tuple[int, ...], timeout: int) -> str:
    log = evidence / (name + '.log')
    def terminate(process: subprocess.Popen) -> None:
        if process.poll() is not None:
            return
        for kind in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, kind)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
                return
            except subprocess.TimeoutExpired:
                continue
        raise RuntimeError('Recovery child survived bounded termination; inherited command lease remains held')
    with log.open('wb') as stream:
        process = subprocess.Popen(args, cwd=ROOT, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=stream, stderr=subprocess.STDOUT, start_new_session=True,
                                   pass_fds=descriptors)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate(process)
            status = 124
        except BaseException:
            terminate(process)
            raise
    if status:
        raise RuntimeError(f'{name} recovery failed ({status}); see {log}')
    return log.read_text()


def restore_parity_keychain(evidence: Path, descriptors: tuple[int, ...]) -> None:
    """Resume the exact external-secret fixture before shared workers return."""
    directory = evidence / 'full-suite/keychain/build-external-secret'
    journal = directory / 'keychain.json'
    if any(path.is_symlink() for path in (evidence / 'full-suite', directory.parent,
                                          directory, journal)):
        raise RuntimeError('Parity keychain recovery path contains a symbolic link')
    if not directory.exists():
        return
    if journal.exists() and not journal.is_file():
        raise RuntimeError('Parity keychain recovery journal is not a regular file')
    output = recover_command(evidence, 'parity-keychain-recovery',
                             [sys.executable, str(ROOT / 'Tools/parity/keychain_fixture.py'),
                              'recover', '--journal-dir', str(directory)],
                             dict(os.environ), descriptors, 90)
    if journal.exists():
        restored = json.loads(journal.read_text()).get('restored') is True
    else:
        safe = json.loads(output)
        restored = safe == {'schema': 1, 'restored': True, 'prepared': False,
                            'not_started': True, 'journal': str(directory.resolve())}
    if not restored:
        raise RuntimeError('Parity keychain restoration remains unconfirmed')


def recover_projects(evidence: Path, ledger: ProjectLedger, q: dict,
                     descriptors: tuple[int, ...]) -> None:
    runtime = q['modules']['runtime_benchmark']
    install = runtime.INSTALLS / 'fork/install'
    recreated = []
    for project, record in ledger.records.items():
        fixture_path = Path(record['fixture'])
        if (not re.fullmatch(r'cfq[0-9]+-[13]-[0-7]-(candidate|docker)', project)
                or record.get('lane') not in {'candidate', 'docker'}
                or not project.endswith('-' + record['lane'])
                or not fixture_path.is_relative_to(evidence / 'fixtures')
                or not fixture_path.is_file() or sha(fixture_path) != record.get('fixture_sha256')):
            raise RuntimeError('Owned project recovery record is malformed')
        base = ([str(install / 'bin/container'), 'compose'] if record['lane'] == 'candidate'
                else ['docker', '--context', 'colima', 'compose'])
        environment = (candidate_environment(runtime, install) if record['lane'] == 'candidate'
                       else dict(os.environ))
        observation_environment = (candidate_environment(runtime, install, machine_output=True)
                                   if record['lane'] == 'candidate' else environment)
        prefix = base + ['-p', project, '-f', str(fixture_path)]
        if not record['active']:
            prior = recover_command(evidence, 'recovery-' + project + '-precheck',
                                    prefix + ['ps', '--all', '--quiet'], observation_environment,
                                    descriptors, 60)
            if record['lane'] == 'docker':
                prior += recover_command(evidence, 'recovery-' + project + '-precheck-docker',
                                         ['docker', '--context', 'colima', 'ps', '-aq', '--filter',
                                          'label=com.docker.compose.project=' + project],
                                         environment, descriptors, 20)
            if prior.strip():
                ledger.reactivate(project)
                recreated.append(project)
        if ledger.records[project]['active']:
            recover_command(evidence, 'recovery-' + project + '-down',
                            prefix + ['down', '--remove-orphans', '--timeout', '10'], environment, descriptors, 120)
        present = recover_command(evidence, 'recovery-' + project + '-ps',
                                    prefix + ['ps', '--all', '--quiet'], observation_environment,
                                    descriptors, 60)
        if present.strip():
            raise RuntimeError('Owned project survived recovery down: ' + project)
        if record['lane'] == 'docker' and recover_command(
                evidence, 'recovery-' + project + '-docker-ps',
                ['docker', '--context', 'colima', 'ps', '-aq', '--filter',
                 'label=com.docker.compose.project=' + project], environment, descriptors, 20).strip():
            raise RuntimeError('Owned Docker containers survived recovery: ' + project)
        ledger.finished(project)
    if recreated:
        raise RuntimeError('Previously cleared Compose projects reappeared before exclusive cleanup: ' + ', '.join(recreated))


def ensure_projects_cleared(evidence: Path, ledger: ProjectLedger, q: dict,
                            descriptors: tuple[int, ...], command_lock: Path,
                            *, allow_existing: bool) -> dict:
    """Bind a completed project inventory to exclusive command ownership."""
    matrix_cleanup = evidence / 'runtime/performance-matrix-cleanup.json'
    matrix_state_path = evidence / 'runtime/performance-matrix-state.json'
    if matrix_state_path.is_file():
        state = json.loads(matrix_state_path.read_text())
        if (state.get('schema') != 1 or state.get('started') is not True
                or state.get('completed') is not True
                or state.get('cleanup_verified') is not True):
            raise RuntimeError('Broad performance matrix did not complete verified cleanup')
    if matrix_cleanup.is_file():
        receipt = json.loads(matrix_cleanup.read_text())
        if receipt.get('schema') != 1 or receipt.get('verified') is not True:
            raise RuntimeError('Broad performance matrix cleanup is not verified')
    elif matrix_state_path.is_file():
        raise RuntimeError('Broad performance matrix cleanup receipt is missing')
    phase_path = evidence / 'projects-cleared.json'
    if phase_path.exists():
        if not allow_existing:
            raise RuntimeError('Unexpected prior project-clearance phase in a fresh live run')
        phase = json.loads(phase_path.read_text())
        if (phase.get('schema') != 1 or phase.get('verified_under_exclusive_lease') is not True
                or phase.get('command_lock') != str(command_lock)
                or phase.get('qualified_runtime') != Q
                or not ledger.path.is_file() or phase.get('ledger_sha256') != sha(ledger.path)
                or phase.get('project_count') != len(ledger.records) or ledger.active()):
            raise RuntimeError('Project-clearance phase is incompatible with the recovery journal')
        return phase
    recover_projects(evidence, ledger, q, descriptors)
    if ledger.active():
        raise RuntimeError('Project inventory remains active after exclusive verification')
    if not ledger.path.exists():
        write(ledger.path, ledger.records)
    phase = {'schema': 1, 'verified_under_exclusive_lease': True,
             'command_lock': str(command_lock), 'qualified_runtime': Q,
             'ledger_sha256': sha(ledger.path), 'project_count': len(ledger.records)}
    write(phase_path, phase)
    return phase


def ensure_full_suite_cleared(evidence: Path, q: dict, descriptors: tuple[int, ...],
                              command_lock: Path, *, allow_existing: bool) -> dict:
    """Verify 27/66 case resources absent before the private CLI can be removed."""
    base = evidence / 'full-suite'
    phase_path = evidence / 'full-suite-cleared.json'
    ledger = full_suite.Ledger(base)
    source_hashes = full_suite_sources()
    source_digest = hashlib.sha256(json.dumps(source_hashes, sort_keys=True).encode()).hexdigest()
    if phase_path.exists():
        if not allow_existing:
            raise RuntimeError('Unexpected prior full-suite clearance in fresh live run')
        phase = json.loads(phase_path.read_text())
        if (phase.get('schema') != 1 or phase.get('verified_under_exclusive_lease') is not True
                or phase.get('command_lock') != str(command_lock)
                or phase.get('qualified_runtime') != Q
                or phase.get('source_digest') != source_digest
                or not ledger.path.is_file() or phase.get('ledger_sha256') != sha(ledger.path)
                or ledger.pending()):
            raise RuntimeError('Full-suite clearance is incompatible with recovery journal')
        return phase
    base.mkdir(exist_ok=True)
    if not ledger.path.exists():
        full_suite.write(ledger.path, ledger.data)
    removed = []
    if ledger.data['cases']:
        for row in ledger.pending():
            if source_hashes.get(row['name']) != row['source_sha256']:
                raise RuntimeError('Full-suite source changed before process recovery: ' + row['name'])
            session = row.get('session')
            if not session and row.get('supervised') is True:
                # The exec gate cannot release until its session claim is durable.
                continue
            if not session:
                raise RuntimeError('Pending full-suite case lacks process ownership: ' + row['name'])
            if session.get('cleared') is not True:
                cli_process.recover_session(session)
                ledger.clear_session(row['name'])
        runtime = q['modules']['runtime_benchmark']
        install = runtime.INSTALLS / 'fork/install'
        sequence = 0
        def invoke(lane: str, kind: str, args: list[str]) -> str:
            nonlocal sequence
            sequence += 1
            command = [str(install / 'bin/container') if args[0] == 'container'
                       else args[0], *args[1:]]
            environment = (candidate_environment(runtime, install, machine_output=True)
                           if lane == 'candidate' else dict(os.environ))
            return recover_command(evidence, f'full-suite-recovery-{sequence}-{kind}',
                                   command, environment, descriptors, 90)
        removed = ledger.recover(invoke, source_hashes)
        if removed:
            # Cleanup restores host safety, but it never converts a leaked
            # original parity case into an accepted qualification result.
            full_suite.write(base / 'recovered-resources.json', {'removed': removed})
    if ledger.pending():
        raise RuntimeError('Original full-suite case remains active')
    phase = {'schema': 1, 'verified_under_exclusive_lease': True,
             'command_lock': str(command_lock), 'qualified_runtime': Q,
             'source_digest': source_digest, 'ledger_sha256': sha(ledger.path),
             'case_count': len(ledger.data['cases']), 'removed_count': len(removed)}
    write(phase_path, phase)
    return phase


class CleanupPhases:
    """Resume only the next cleanup step bound to the verified project ledger."""
    ORDER = ('full_suite', 'projects', 'runtime', 'plugin', 'private_install',
             'colima', 'stock', 'install', 'host')

    def __init__(self, evidence: Path, ledger: ProjectLedger, q: dict, command_lock: Path):
        self.path = evidence / 'cleanup-phases.json'
        self.identity = {'schema': 1, 'qualified_runtime': Q,
                         'qualified_helpers': q['hashes'],
                         'compose_source': json.loads((evidence / 'signed-candidate.json').read_text())['source'],
                         'command_lock': str(command_lock),
                         'released_q_assets_sha256': sha(evidence / 'q-assets/q-assets.json'),
                         'full_suite_ledger_sha256': sha(evidence / 'full-suite/resource-ledger.json'),
                         'ledger_sha256': sha(ledger.path)}
        self.completed = []
        if self.path.exists():
            record = json.loads(self.path.read_text())
            completed = record.get('completed')
            if (any(record.get(key) != value for key, value in self.identity.items())
                    or not isinstance(completed, list)
                    or completed != list(self.ORDER[:len(completed)])):
                raise RuntimeError('Compose cleanup phase journal changed or is out of order')
            self.completed = completed

    def has(self, name: str) -> bool:
        return name in self.completed

    def mark(self, name: str) -> None:
        if self.has(name):
            return
        if len(self.completed) >= len(self.ORDER) or self.ORDER[len(self.completed)] != name:
            raise RuntimeError('Compose cleanup phase order changed: ' + name)
        self.completed.append(name)
        write(self.path, {**self.identity, 'completed': self.completed})


def verified_plugin_restored(lease: PluginLease) -> None:
    if not lease.record.get('restored') or any(path.exists() for path in
            (lease.backup, lease.stage, lease.retired)):
        raise RuntimeError('Private plugin restoration phase is incomplete')
    if (lease.tree(lease.target) if lease.target.exists() else {}) != lease.record['original']:
        raise RuntimeError('Original private plugin changed after restoration')


def recover_plugin_lease(lease: PluginLease, *, predecessor_present: bool,
                         phase_complete: bool) -> None:
    if predecessor_present:
        # The original Q install can have its own plugin. It is not the
        # temporary signed-runtime plugin that this lease describes.
        if (not lease.record.get('restored') or any(path.exists() for path in
                (lease.backup, lease.stage, lease.retired))):
            raise RuntimeError('Signed-runtime plugin was not restored before predecessor swap')
        return
    if not phase_complete:
        lease.restore()
    verified_plugin_restored(lease)


def finalize_unswapped_plugin_intent(evidence: Path, install: Path, runtime_coverage: object) -> None:
    """Close an intent journal written before any plugin mutation was possible."""
    receipt = evidence / 'install/install.json'
    if not receipt.exists():
        return
    record = json.loads(receipt.read_text())
    if record.get('previous_installation_restored') is True:
        return
    libexec = install / 'libexec'
    if (record.get('scope') != 'compose-private-plugin'
            or (evidence / 'plugin-lease.json').exists()
            or list(libexec.glob('.compose-qualification-*'))):
        raise RuntimeError('Unswapped private plugin intent cannot be verified')
    fingerprint = json.loads((evidence / 'runtime/fork-fingerprint.json').read_text())
    if record.get('original_binaries') != fingerprint['binaries']:
        raise RuntimeError('Unswapped private plugin intent has different qualified binaries')
    runtime_coverage.verify_binaries(install, fingerprint['binaries'])
    record['previous_installation_restored'] = True
    write(receipt, record)


def recover_reference(evidence: Path) -> dict:
    """Clear only enrolled Docker projects before restoring capture-owned host state."""
    result = {'schema': 1, 'target': 'capture-compose-docker-reference',
              'restored': False, 'failures': []}
    q = q_modules()
    admit_recovery_q(evidence, q, preflight_name='reference-preflight.json')
    modules = q['modules']
    fb, runtime = modules['fork_benchmark'], modules['runtime_benchmark']
    host_module = modules['host_lease']
    command_lock = evidence / 'commands.lock'
    intent = json.loads((evidence / 'reference-capture-intent.json').read_text())
    if (intent.get('schema') != 1 or intent.get('qualified_runtime') != Q
            or intent.get('command_lock') != str(command_lock)
            or intent.get('workload_sha256') != benchmark_evidence.digest(
                benchmark_evidence.workload(runtime.ALPINE))):
        raise RuntimeError('Reference capture recovery intent changed')
    ledger = ProjectLedger(evidence)
    descriptors: list[int] = []
    host = None
    try:
        with ExitStack() as commands:
            for path in (fb.STORAGE / 'qualification.lock', host_module.LOCK,
                         runtime.INSTALLS / 'benchmark.lock'):
                fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                descriptors.append(fd)
                info = os.fstat(fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or info.st_nlink != 1 or info.st_mode & 0o022):
                    raise RuntimeError('Unsafe reference recovery lock: ' + str(path))
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if host_module.JOURNAL.is_symlink():
                raise RuntimeError('Shared host recovery journal is a symbolic link')
            if not host_module.JOURNAL.exists():
                if ledger.active():
                    raise RuntimeError('Reference projects remain without host recovery authority')
                colima_record = evidence / 'colima-lease.json'
                if colima_record.exists() and json.loads(colima_record.read_text()).get('restored') is not True:
                    raise RuntimeError('Reference Colima restoration lacks shared host authority')
                host_record = evidence / 'host-lease.json'
                if host_record.exists() and json.loads(host_record.read_text()).get('restored') is not True:
                    raise RuntimeError('Reference host receipt does not prove worker restoration')
                if colima_record.exists() and not (evidence / 'projects-cleared.json').is_file():
                    raise RuntimeError('Reference project clearance receipt is missing')
                if colima_record.exists() and not host_record.exists():
                    raise RuntimeError('Reference host receipt is missing after Colima ownership')
                if (evidence / 'reference-restoration.json').exists():
                    prior = json.loads((evidence / 'reference-restoration.json').read_text())
                    if prior.get('restored') is not True:
                        raise RuntimeError('Reference restoration receipt does not attest success')
                elif colima_record.exists():
                    write(evidence / 'reference-restoration.json', {
                        'schema': 1, 'projects_cleared_sha256': sha(evidence / 'projects-cleared.json'),
                        'colima_lease_sha256': sha(colima_record),
                        'host_lease_sha256': sha(host_record), 'restored': True,
                        'recovered': True})
                result['restored'] = True
                return result
            record = json.loads(host_module.JOURNAL.read_text())
            if (record.get('evidence') != str(evidence)
                    or record.get('command_lock') != str(command_lock)
                    or record.get('bazel_workspace') != str(Q_ROOT)
                    or type(record.get('owner')) is not int
                    or record['owner'] in host_module.processes()):
                raise RuntimeError('Reference host recovery belongs to an active or different owner')
            command_descriptors = modules['unattended'].acquire_cleanup_commands(
                evidence, commands, str(Q_ROOT))
            host = host_module.HostLease(evidence)
            host.record = record
            host.rows = record['workers']
            host.suspended = record['suspended']
            cleanup_ok = True
            try:
                ensure_projects_cleared(evidence, ledger, q, command_descriptors,
                                        command_lock, allow_existing=True)
                path = evidence / 'colima-lease.json'
                if path.exists():
                    colima = modules['unattended'].ColimaLease(evidence)
                    colima.record = json.loads(path.read_text())
                    colima.command_descriptors = command_descriptors
                    colima.restore()
                    if colima.record['restored'] is not True:
                        raise RuntimeError('Reference Colima restoration is unconfirmed')
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append(str(error))
            try:
                host.restore(restore_workers=cleanup_ok)
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append(str(error))
            result['restored'] = cleanup_ok and not ledger.active()
            if result['restored']:
                restoration = {'schema': 1,
                               'projects_cleared_sha256': sha(evidence / 'projects-cleared.json'),
                               'colima_lease_sha256': sha(evidence / 'colima-lease.json')
                               if (evidence / 'colima-lease.json').exists() else None,
                               'host_lease_sha256': sha(evidence / 'host-lease.json'),
                               'restored': True, 'recovered': True}
                write(evidence / 'reference-restoration.json', restoration)
            return result
    except BaseException as error:
        result['restored'] = False
        result['failures'].append(str(error))
        return result
    finally:
        try:
            write(evidence / ('reference-recovery-' + str(os.getpid()) + '.json'), result)
        finally:
            if host:
                host.close()
            for fd in reversed(descriptors):
                os.close(fd)


def recover(evidence: Path) -> dict:
    """Recover Compose project/plugin journals before Q workers can resume."""
    result = {'schema': 1, 'restored': False, 'evidence': str(evidence), 'failures': []}
    q = q_modules()
    recovery_authority = admit_recovery_q(evidence, q, preflight_name='preflight.json')
    original_fingerprint = recovery_authority['fingerprint']
    assets = revalidate_q_assets(evidence / 'q-assets', q['hashes'])
    modules = q['modules']
    fb, runtime = modules['fork_benchmark'], modules['runtime_benchmark']
    host_module = modules['host_lease']
    ledger = ProjectLedger(evidence)
    descriptors = []
    host = None
    try:
        with ExitStack() as command_stack:
            for path in (fb.STORAGE / 'qualification.lock', host_module.LOCK,
                         runtime.INSTALLS / 'benchmark.lock'):
                fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
                descriptors.append(fd)
                info = os.fstat(fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or info.st_nlink != 1 or info.st_mode & 0o022):
                    raise RuntimeError('Unsafe shared recovery lock: ' + str(path))
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if host_module.JOURNAL.is_symlink():
                raise RuntimeError('Shared host recovery journal is a symbolic link')
            if not host_module.JOURNAL.exists():
                if full_suite.Ledger(evidence / 'full-suite').pending():
                    raise RuntimeError('Parity resources remain but shared host journal is missing')
                plugin = evidence / 'plugin-lease.json'
                if plugin.exists() and json.loads(plugin.read_text()).get('restored') is not True:
                    raise RuntimeError('Plugin restoration is unconfirmed but shared host journal is missing')
                sentinel = evidence / 'install/install.json'
                if sentinel.exists() and json.loads(sentinel.read_text()).get('previous_installation_restored') is not True:
                    raise RuntimeError('Private plugin transaction is unconfirmed but shared host journal is missing')
                if ledger.active():
                    raise RuntimeError('Owned projects remain but shared host journal is missing')
                phases_path = evidence / 'cleanup-phases.json'
                if phases_path.exists():
                    phases = CleanupPhases(evidence, ledger, q, evidence / 'commands.lock')
                    if not phases.has('install'):
                        raise RuntimeError('Host journal vanished before private installation restoration')
                    modules['unattended'].verify_installations(evidence)
                    # Q removes its host journal only after every original
                    # registration is confirmed online. A crash before this
                    # phase write can therefore be resumed without replay.
                    phases.mark('host')
                result['restored'] = True
                return result
            record = json.loads(host_module.JOURNAL.read_text())
            if record.get('evidence') != str(evidence):
                raise RuntimeError('Shared host recovery belongs to another invocation')
            if type(record.get('owner')) is not int or record['owner'] <= 0 or record['owner'] in host_module.processes():
                raise RuntimeError('Qualification owner remains active or unconfirmed')
            command_lock = evidence / 'commands.lock'
            if record.get('command_lock') != str(command_lock) or record.get('bazel_workspace') != str(Q_ROOT):
                raise RuntimeError('Compose command lease/helper workspace changed')
            command_descriptors = modules['unattended'].acquire_cleanup_commands(
                evidence, command_stack, str(Q_ROOT))
            result['command_lock_verified'] = True
            host = host_module.HostLease(evidence)
            host.record = record
            host.rows = record['workers']
            host.suspended = record['suspended']
            host.record['recovered_by'] = os.getpid()
            cleanup_ok = True
            plugin_lease = None
            runtime_lease = None
            colima_lease = None
            stock_slot = None
            phases = None
            try:
                restore_parity_keychain(evidence, command_descriptors)
                ensure_full_suite_cleared(evidence, q, command_descriptors,
                                          command_lock, allow_existing=True)
                ensure_projects_cleared(evidence, ledger, q, command_descriptors,
                                        command_lock, allow_existing=True)
                phases = CleanupPhases(evidence, ledger, q, command_lock)
                phases.mark('full_suite')
                phases.mark('projects')
                if not phases.has('runtime'):
                    runtime.stop_owned('fork')
                modules['runtime_coverage'].require_idle(runtime.INSTALLS / 'fork/install')
                full_suite_scratch.restore(evidence)
                phases.mark('runtime')
                runtime_record = evidence / 'runtime-install.json'
                if runtime_record.exists():
                    runtime_lease = RuntimeArchiveLease.from_receipt(
                        evidence, runtime.INSTALLS / 'fork/install',
                        Path(assets['assets']['runtime']['path']),
                        assets['provenance']['runtime']['payload'])
                predecessor_present = runtime_lease is not None and runtime_lease.predecessor_present()
                plugin_record = evidence / 'plugin-lease.json'
                if plugin_record.exists():
                    signed = json.loads((evidence / 'signed-candidate.json').read_text())
                    plugin_lease = PluginLease.from_receipt(evidence, runtime.INSTALLS / 'fork/install', signed)
                    recover_plugin_lease(plugin_lease, predecessor_present=predecessor_present,
                                         phase_complete=phases.has('plugin'))
                phases.mark('plugin')
                if runtime_lease is not None:
                    if not phases.has('private_install'):
                        runtime_lease.restore(modules['runtime_coverage'])
                    if not runtime_lease.record['restored']:
                        raise RuntimeError('Original Q private runtime remains displaced')
                modules['runtime_coverage'].verify_binaries(
                    runtime.INSTALLS / 'fork/install', original_fingerprint['binaries'])
                phases.mark('private_install')
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append(str(error))
            if cleanup_ok:
                for name, constructor, attribute in (
                        ('colima-lease.json', modules['unattended'].ColimaLease, 'record'),
                        ('service-restoration.json', runtime.StockSlot, 'saved')):
                    path = evidence / name
                    if not path.exists():
                        phases.mark('colima' if name == 'colima-lease.json' else 'stock')
                        continue
                    try:
                        resource = constructor(evidence)
                        setattr(resource, attribute, json.loads(path.read_text()))
                        if isinstance(resource, modules['unattended'].ColimaLease):
                            resource.command_descriptors = command_descriptors
                            if not phases.has('colima'):
                                restore_colima_after_projects(resource, ledger)
                            if resource.record['restored'] is not True:
                                raise RuntimeError('Colima restoration is unverified')
                            colima_lease = resource
                        else:
                            if not phases.has('stock'):
                                resource.restore()
                            if not all(row.get('restored') is True for row in resource.saved):
                                raise RuntimeError('Original service restoration is unverified')
                            stock_slot = resource
                    except BaseException as error:
                        cleanup_ok = False
                        result['failures'].append(str(error))
                        break
                    else:
                        phases.mark('colima' if name == 'colima-lease.json' else 'stock')
            if cleanup_ok:
                try:
                    if runtime_lease and not phases.has('install'):
                        runtime_lease.finalize()
                    elif plugin_lease is None and runtime_lease is None:
                        finalize_unswapped_plugin_intent(
                            evidence, runtime.INSTALLS / 'fork/install', modules['runtime_coverage'])
                    modules['unattended'].verify_installations(evidence)
                    phases.mark('install')
                except BaseException as error:
                    cleanup_ok = False
                    result['failures'].append(str(error))
            try:
                host.restore(restore_workers=cleanup_ok)
                if cleanup_ok:
                    phases.mark('host')
            except BaseException as error:
                cleanup_ok = False
                result['failures'].append(str(error))
            result['restored'] = cleanup_ok and not ledger.active()
            return result
    except BaseException as error:
        result['failures'].append(str(error))
        return result
    finally:
        try:
            write(evidence / ('recovery-' + str(os.getpid()) + '.json'), result)
        except OSError as error:
            result['restored'] = False
            result['failures'].append('Cannot retain recovery receipt: ' + str(error))
        finally:
            try:
                if host:
                    host.close()
            finally:
                for fd in reversed(descriptors):
                    os.close(fd)


def verify_qualified_helpers(q: dict) -> None:
    if git(Q_ROOT, 'rev-parse', 'HEAD') != Q or git(Q_ROOT, 'status', '--porcelain'):
        raise RuntimeError('Qualified helper source changed during Compose qualification')
    for name, expected in q['hashes'].items():
        if sha(Q_ROOT / 'Tools/bazel' / name) != expected:
            raise RuntimeError('Qualified helper changed during Compose qualification: ' + name)


def execute_development(evidence: Path, *, parity: bool,
                        performance: bool = False) -> dict:
    """Run selected original parity leaves without producing release acceptance."""
    target = ('compose-development-parity-performance' if performance else
              'compose-development-parity' if parity else 'compose-development-bridge')
    mode = {'development_parity': True} if parity else {'development_bridge': True}
    result = {'schema': 1, 'target': target, 'passed': False,
              'source': None, 'q_checkpoint': Q, 'stages': [], 'failures': []}
    try:
        q = q_modules()
        source, config = preflight(evidence, q, **mode)
        result['source'] = source['commit']
        result['preflight_sha256'] = sha(evidence / 'preflight.json')
        result['stages'], invocation, assets, native_tests = run_layers(
            evidence, source, q, **mode)
        result['released_q_assets_sha256'] = sha(evidence / 'q-assets/q-assets.json')
        result['compiled_sdk_chain_sha256'] = sha(evidence / 'compiled-sdk-chain.json')
        verify_source(source, source_identity(ROOT))
        plugin = unpack_candidate(evidence, invocation)
        signed = sign(evidence, plugin, config.get(
            'signing_identity', q['modules']['runtime_benchmark'].IDENTITY))
        result['signed_candidate'] = signed
        benchmark_reference = (admit_benchmark_reference(
            evidence, q['modules']['runtime_benchmark'].ALPINE) if performance else None)
        if benchmark_reference:
            result['benchmark_reference_sha256'] = sha(evidence / 'benchmark-reference.json')
        result['live'] = run_live(evidence, q, plugin, signed, assets, native_tests,
                                  benchmark_reference['document'] if benchmark_reference else None,
                                  development_performance=performance, **mode)
        result['live_sha256'] = sha(evidence / 'live.json')
        verify_source(source, source_identity(ROOT))
        verify_qualified_helpers(q)
        result['passed'] = result['live'].get('passed') is True
        if not result['passed']:
            label = 'Development parity/performance' if performance else 'Development parity'
            raise RuntimeError(label + ' proof or restoration did not pass')
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        receipt = ('development-parity-performance.json' if performance else
                   'development-parity.json' if parity else 'development-bridge.json')
        write(evidence / receipt, result)
    return result


def execute_development_bridge(evidence: Path) -> dict:
    return execute_development(evidence, parity=False)


def execute_development_parity(evidence: Path) -> dict:
    return execute_development(evidence, parity=True)


def execute_development_parity_performance(evidence: Path) -> dict:
    return execute_development(evidence, parity=True, performance=True)


def main() -> None:
    global Q_ROOT, Q_EVIDENCE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True, help='Fresh internal retained directory')
    parser.add_argument('--container-root', type=Path, required=True,
                        help='Exact clean qualified Container source checkout')
    parser.add_argument('--q-evidence', type=Path, required=True,
                        help='Completed qualification evidence for that Container checkout')
    parser.add_argument('--previous-candidate-lock', type=Path,
                        help='Exact published Compose provenance lock for historical comparison')
    action = parser.add_mutually_exclusive_group()
    action.add_argument('--recover', action='store_true', help='Recover a previously interrupted Compose host lease')
    action.add_argument('--capture-reference', action='store_true',
                        help='Capture one released Docker reference without building Compose')
    action.add_argument('--development-bridge', action='store_true',
                        help='Build and sign a local candidate, run only original Bridge parity, and restore the host; not release qualification')
    action.add_argument('--development-parity', action='store_true',
                        help='Build and sign a local candidate, run all 66 original parity cases, and restore the host; not release qualification')
    action.add_argument('--development-parity-performance', action='store_true',
                        help='Build and sign a local candidate, run all 66 original parity cases and the matched four-fixture seven-trial benchmark, then restore the host; no unit, notary or release stages')
    args = parser.parse_args()
    Q_ROOT = existing_directory(parser, '--container-root', args.container_root)
    Q_EVIDENCE = existing_directory(parser, '--q-evidence', args.q_evidence)
    if args.previous_candidate_lock and (args.recover or args.capture_reference
                                         or args.development_bridge or args.development_parity
                                         or args.development_parity_performance):
        parser.error('Historical Compose comparison applies only to full qualification')
    evidence = args.evidence.resolve()
    allowed = (OUTPUT, CAPTURE_OUTPUT) if args.recover else (
        (CAPTURE_OUTPUT,) if args.capture_reference else (OUTPUT,))
    if (not any(evidence.parent == root for root in allowed) or args.evidence.is_symlink()):
        parser.error('Evidence must be a direct directory under its internal retained root')
    def interrupted(signum: int, _frame: object) -> None:
        raise SystemExit(128 + signum)
    for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(number, interrupted)
    if args.recover:
        if not evidence.is_dir():
            parser.error('Recovery evidence directory is missing')
        outcome = (recover_reference(evidence) if
                   (evidence / 'reference-capture-intent.json').exists() else recover(evidence))
        print(json.dumps(outcome, indent=2))
        if not outcome['restored']:
            raise SystemExit(1)
        return
    if evidence.exists():
        parser.error('Use a fresh directory under the Compose internal local-final root')
    evidence.mkdir(parents=True)
    if args.capture_reference:
        outcome = execute_capture(evidence)
        print(json.dumps(outcome, indent=2))
        return
    if args.development_bridge:
        outcome = execute_development_bridge(evidence)
        print(json.dumps(outcome, indent=2))
        return
    if args.development_parity:
        outcome = execute_development_parity(evidence)
        print(json.dumps(outcome, indent=2))
        return
    if args.development_parity_performance:
        outcome = execute_development_parity_performance(evidence)
        print(json.dumps(outcome, indent=2))
        return
    result = {'schema': 1, 'target': 'compose-only-qualify', 'passed': False,
              'source': None, 'q_checkpoint': Q, 'stages': [], 'failures': []}
    try:
        q = q_modules()
        source, config = preflight(evidence, q)
        result['source'] = source['commit']
        result['preflight_sha256'] = sha(evidence / 'preflight.json')
        result['qualified_container'] = json.loads((evidence / 'preflight.json').read_text())['container']
        benchmark_reference = admit_benchmark_reference(
            evidence, q['modules']['runtime_benchmark'].ALPINE)
        result['benchmark_reference_sha256'] = sha(evidence / 'benchmark-reference.json')
        previous = (admit_previous_candidate(evidence, args.previous_candidate_lock.resolve(),
                                             benchmark_reference['document'])
                    if args.previous_candidate_lock else None)
        result['hosted_quality'] = admit_hosted(source['commit'], evidence / 'hosted-quality')
        result['hosted_quality_sha256'] = sha(evidence / 'hosted-quality/quality.json')
        result['stages'], package_invocation, q_assets, native_tests = run_layers(evidence, source, q)
        result['released_q_assets_sha256'] = sha(evidence / 'q-assets/q-assets.json')
        result['compiled_sdk_chain_sha256'] = sha(evidence / 'compiled-sdk-chain.json')
        verify_source(source, source_identity(ROOT))
        plugin = unpack_candidate(evidence, package_invocation)
        signed = sign(evidence, plugin, config.get('signing_identity', q['modules']['runtime_benchmark'].IDENTITY))
        result['signed_candidate'] = signed
        result['live'] = run_live(evidence, q, plugin, signed, q_assets, native_tests,
                                  benchmark_reference['document'])
        result['live_sha256'] = sha(evidence / 'live.json')
        if previous is not None:
            result['previous_candidate_comparison'] = compare_previous_candidate(
                evidence, result['live'], previous)
            result['previous_candidate_comparison_sha256'] = sha(
                evidence / 'previous-candidate-comparison.json')
        result['notarization'] = notarize(evidence, plugin, signed, config['notary_profile'])
        result['notarization_sha256'] = sha(evidence / 'notarization.json')
        portable_benchmark(evidence, result['live'], signed, result['notarization'],
                           q['modules']['runtime_benchmark'].ALPINE)
        result['portable_benchmark_sha256'] = sha(evidence / 'portable-benchmark.json')
        verify_source(source, source_identity(ROOT))
        verify_qualified_helpers(q)
        result['passed'] = True
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        write(evidence / 'acceptance.json', result)


if __name__ == '__main__':
    main()
