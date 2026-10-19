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

"""Prepare and publish a qualified Container runtime release from retained Q evidence.

Preparation may fetch authenticated native lower-layer assets through their
shared release transport, but never builds or executes the runtime. Publishing
is separate and uses the shared release transport only after re-admitting the
source, qualification, native compiled-consumer chain, and prepared bytes.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import statistics
import subprocess
import sys
import tarfile
import tempfile
import types
from typing import Optional, Union
import zipfile

ASSETS = (
    'container-homebrew-arm64.tar.gz',
    'qualified-container-assets.json',
    'container-measured-fork-arm64.tar.gz',
    'container-measured-fork-arm64.json',
)
HELPERS = ('fork_benchmark', 'runtime_benchmark', 'host_lease', 'unattended',
           'preflight', 'failed_api_hold', 'release_install', 'runtime_coverage',
           'bazel_environment', 'guest_artifact', 'builder_artifact')
CORE_RECEIPTS = ('acceptance.json', 'release/release-artifact.json',
                 'runtime-smoke/fork-fingerprint.json',
                 'runtime-smoke/guest-artifact.json', 'runtime-smoke/builder-artifact.json')
REQUIRED_RECEIPTS = (
    *CORE_RECEIPTS, 'qualification.json', 'host-lease.json', 'colima-lease.json',
    'service-restoration.json', 'install/install.json', 'github-quality/quality.json',
    'release/notary-submission.json', 'release/notary-status.json',
    'runtime-smoke/acceptance.json', 'runtime-smoke/source-inputs.json',
    'runtime-benchmark/acceptance.json', 'runtime-benchmark/fork-fingerprint.json',
    'runtime-benchmark/source-inputs.json', 'runtime-benchmark/host.json',
    'runtime-benchmark/results.json', 'runtime-benchmark/matrix.json',
    'docker-benchmark/acceptance.json', 'docker-benchmark/results.json',
    'docker-benchmark/engine-admission.json',
    'docker-reference-admission/acceptance.json', 'docker-reference-admission/results.json',
    'docker-reference-admission/engine-admission.json', 'runtime-comparison-acceptance.json',
    'runtime-comparison.json', 'components/comparison-review.json', 'components/metadata.json',
    'components/results.json', 'components/matrix.json', 'components/historical-results.json',
    'components/go-benchmarks.json', 'components/go-matrix.json',
    'components/containerization-fork-inputs.json', 'components/container-fork-inputs.json',
    'components/container-fork-binary.json', 'benchmark-reference/historical-reference.json',
    'integration/integration.json', 'integration/results.json',
    'integration/coverage/coverage.json', 'combined-coverage/coverage.json',
    'vm-integration/vm-integration.json',
)
NATIVE_PHASES = ('runtime-smoke', 'runtime-benchmark', 'release')
NATIVE_JSON = tuple(phase + '/' + name for phase in NATIVE_PHASES for name in
                    ('compiled-consumer.json', 'fork-fingerprint.json', 'source-inputs.json')) + (
    'integration/coverage/coverage-compiled-consumer.json',
    'integration/coverage/fork-fingerprint.json')
NATIVE_RAW = tuple(phase + '/fork-release' + suffix for phase in NATIVE_PHASES
                   for suffix in ('.events.json', '-native-aquery.json')) + (
    'integration/coverage/fork-runtime-coverage.events.json',
    'integration/coverage/fork-runtime-coverage-native-aquery.json')
SHA = re.compile(r'[0-9a-f]{64}\Z')
COMMIT = re.compile(r'[0-9a-f]{40}\Z')
PRIVATE = re.compile(r'file://|/(?:Users|Volumes|private|tmp|home|var)/|'
                     r'github_pat_|ghp_|Bearer ', re.IGNORECASE)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def require(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def verify_tar_payload(path: Path, payload: dict, manifest: Optional[dict] = None) -> None:
    seen: dict[str, str] = {}
    directories: set[str] = set()
    with tarfile.open(path, 'r:gz') as archive:
        for member in archive:
            if member.name in ('.', './'):
                require(member.isdir() and not member.mode & 0o7000, 'Unsafe archive root')
                continue
            name = member.name[2:] if member.name.startswith('./') else member.name
            parts = name.rstrip('/').split('/')
            require(name and not name.startswith('/')
                    and all(part not in ('', '.', '..') for part in parts)
                    and (member.isdir() or not name.endswith('/'))
                    and not member.mode & 0o7000, 'Release archive contains an unsafe member')
            canonical = '/'.join(parts)
            if member.isdir():
                require(canonical not in directories and canonical not in seen,
                        'Release archive contains a duplicate directory')
                directories.add(canonical)
                continue
            require(member.isfile() and canonical not in seen and canonical not in directories
                    and canonical in payload, 'Release archive contains an unexpected member')
            hasher = hashlib.sha256()
            with archive.extractfile(member) as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    hasher.update(block)
            require(hasher.hexdigest() == payload[canonical], 'Release archive member checksum differs')
            if manifest is not None:
                row = manifest[canonical]
                require(member.mode == row['mode'] and member.size == row['size'],
                        'Measured archive member mode or size differs from manifest')
            seen[canonical] = hasher.hexdigest()
    require(seen == payload, 'Release archive payload inventory differs from receipt')


def source_checkpoint(root: Path) -> str:
    head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    status = subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain',
                                      '--untracked-files=all'], text=True)
    require(COMMIT.fullmatch(head) is not None and not status,
            'Container source must be an exact clean commit')
    return head


def load_json(evidence: Path, name: str) -> Union[dict, list]:
    path = evidence / name
    require(path.is_file() and not path.is_symlink()
            and path.resolve(strict=True).is_relative_to(evidence.resolve(strict=True)),
            'Missing or escaped qualification receipt: ' + name)
    return json.loads(path.read_text())


def expected_stages(container_root: Path) -> list[str]:
    tree = ast.parse((container_root / 'Tools/bazel/qualification.py').read_text())
    function = next(node for node in tree.body
                    if isinstance(node, ast.FunctionDef) and node.name == 'stages')
    expression = function.body[-1].value
    require(isinstance(expression, ast.List), 'Qualification stage recipe is not a literal inventory')
    return [ast.literal_eval(row.elts[0]) for row in expression.elts]


def expected_runtime_fixtures(container_root: Path) -> list[str]:
    tree = ast.parse((container_root / 'Tools/bazel/runtime_benchmark.py').read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id == 'FIXTURES':
                value = ast.literal_eval(node.value)
                require(isinstance(value, tuple) and bool(value)
                        and all(isinstance(item, str) for item in value),
                        'Maintained runtime fixture inventory is malformed')
                return list(value)
    raise ValueError('Maintained runtime fixture inventory is missing')


def admit_runtime_comparison(container_root: Path, evidence: Path,
                             fixtures: list[str], transition: dict,
                             source: Optional[str] = None) -> list[dict]:
    """Recompute the maintained comparison from raw candidate and archive trials.

    This mirrors qualification.benchmark_summary's release gate so a copied
    `passed` bit or edited comparison summary cannot stand in for measurements.
    The historical stock and Docker rows are linked to the already admitted
    exact reference archive; current fork trials must be fresh.
    """
    reference = load_json(evidence, 'benchmark-reference/historical-reference.json')
    archive_sha = reference.get('archiveSHA256')
    reference_body = reference.get('reference')
    require(SHA.fullmatch(archive_sha or '') and isinstance(reference_body, dict)
            and reference_body.get('historical') is True,
            'Runtime comparison has no admitted historical reference identity')
    protocol = reference_body.get('protocol', {})
    runtime_trials = protocol.get('runtimeTrials')
    docker_trials = protocol.get('dockerTrials')
    require(type(runtime_trials) is int and runtime_trials > 0
            and type(docker_trials) is int and docker_trials > 0,
            'Historical performance trial protocol is malformed')
    runtime_acceptance = load_json(evidence, 'runtime-benchmark/acceptance.json')
    docker_acceptance = load_json(evidence, 'docker-benchmark/acceptance.json')
    runtime_host = load_json(evidence, 'runtime-benchmark/host.json')
    require(runtime_host.get('trials') == runtime_trials,
            'Runtime benchmark trial count differs from authenticated reference protocol')
    runtime_raw = load_json(evidence, 'runtime-benchmark/results.json')
    docker_raw = load_json(evidence, 'docker-benchmark/results.json')
    matrix = load_json(evidence, 'runtime-benchmark/matrix.json')
    require(isinstance(runtime_raw, list) and isinstance(docker_raw, list)
            and isinstance(matrix, list), 'Raw benchmark inventories are malformed')

    def admitted_history(actual: list, archived: list, label: str, *, subset: bool = False,
                         log_value: Optional[str] = None) -> None:
        allowed_metadata = {'historical', 'reference_archive_sha256'}
        if log_value is not None:
            allowed_metadata.add('log')
        require(isinstance(actual, list) and isinstance(archived, list),
                'Historical ' + label + ' raw measurements are malformed')
        available = {}
        for row in archived:
            encoded = json.dumps(row, sort_keys=True, separators=(',', ':'))
            available[encoded] = available.get(encoded, 0) + 1
        observed = {}
        for row in actual:
            require(isinstance(row, dict) and row.get('historical') is True
                    and row.get('reference_archive_sha256') == archive_sha
                    and (log_value is None or row.get('log') == log_value)
                    and set(row) - set(archived[0] if archived else {}) <= allowed_metadata,
                    'Historical ' + label + ' row is not linked to the authenticated raw archive')
            raw = {key: value for key, value in row.items() if key not in allowed_metadata}
            encoded = json.dumps(raw, sort_keys=True, separators=(',', ':'))
            observed[encoded] = observed.get(encoded, 0) + 1
        require((all(count <= available.get(row, 0) for row, count in observed.items()) if subset
                 else observed == available),
                'Historical ' + label + ' raw measurements differ from the authenticated archive')

    archived = reference_body
    reference_tree = ast.parse((container_root / 'Tools/bazel/benchmark_reference.py').read_text())
    reference_name = next((ast.literal_eval(node.value) for node in reference_tree.body
                           if isinstance(node, ast.Assign) and len(node.targets) == 1
                           and isinstance(node.targets[0], ast.Name) and node.targets[0].id == 'NAME'), None)
    require(isinstance(reference_name, str), 'Historical reference archive name is not maintained')
    admitted_history([row for row in runtime_raw if row.get('lane') == 'stock'],
                     [row for row in archived.get('runtime', {}).get('raw', [])
                      if row.get('lane') == 'stock'], 'runtime',
                     log_value=reference_name + ':benchmark.json/runtime/raw')
    admitted_history([row for row in docker_raw if row.get('lane') == 'docker'],
                     archived.get('docker', {}).get('raw', []), 'Docker')
    # Reproduce component_reference.retained_rows from its authenticated inputs:
    # stock measurements for every dependency, plus fork measurements for the
    # unchanged dependencies. Never accept the evidence's own subset as its
    # selection authority.
    fork_tree = ast.parse((container_root / 'Tools/bazel/fork_benchmark.py').read_text())
    pairs = next((ast.literal_eval(node.value) for node in fork_tree.body
                  if isinstance(node, ast.Assign) and len(node.targets) == 1
                  and isinstance(node.targets[0], ast.Name) and node.targets[0].id == 'PAIRS'), None)
    require(isinstance(pairs, dict) and pairs, 'Maintained component source inventory is malformed')
    pairs = json.loads(json.dumps(pairs))
    pairs['container']['repo'] = str(container_root.resolve())
    current_source = source if source is not None else source_checkpoint(container_root)
    require(COMMIT.fullmatch(current_source or '') is not None,
            'Current Container source identity is malformed')
    pairs['container']['fork'] = current_source
    resolved = json.loads((container_root / 'Package.resolved').read_text())
    pins = [row.get('state', {}).get('revision') for row in resolved.get('pins', [])
            if row.get('identity') == 'containerization']
    require(len(pins) == 1 and COMMIT.fullmatch(pins[0] or '') is not None,
            'Maintained containerization package pin is ambiguous')
    pairs['containerization']['fork'] = pins[0]
    metadata = load_json(evidence, 'components/metadata.json')
    require(metadata.get('pairs') == pairs,
            'Historical component selection differs from maintained source pins')
    require(metadata.get('historical_reference') is True,
            'Historical component selection is not marked as retained evidence')
    archived_inputs = archived.get('componentInputs')
    require(isinstance(archived_inputs, dict), 'Historical component input pins are missing')
    changed = []
    for name, pair in pairs.items():
        old = archived_inputs.get(name)
        require(isinstance(old, dict) and isinstance(old.get('stock'), dict)
                and isinstance(old.get('fork'), dict)
                and pair.get('stock') == old['stock'].get('revision'),
                'Historical component stock pin differs from authenticated archive: ' + name)
        if pair.get('fork') != old['fork'].get('revision'):
            require(name in ('container', 'containerization'),
                    'Unexpected changed historical component fork pin: ' + name)
            changed.append(name)
    require(metadata.get('measured_components') == changed,
            'Historical changed-component selection differs from maintained source pins')
    expected_components = [row for row in archived.get('components', {}).get('raw', [])
                           if row.get('component') not in changed or row.get('lane') == 'stock']
    admitted_history(load_json(evidence, 'components/historical-results.json'),
                     expected_components, 'component')
    admitted_history(load_json(evidence, 'components/go-benchmarks.json'),
                     archived.get('components', {}).get('goRaw', []), 'Go component')

    def lane_rows(rows: list, fixture: str, lane: str) -> list[dict]:
        return [row for row in rows if row.get('fixture') == fixture and row.get('lane') == lane]

    expected_matrix = []
    for fixture in fixtures:
        stock = lane_rows(runtime_raw, fixture, 'stock')
        fork = lane_rows(runtime_raw, fixture, 'fork')
        docker = lane_rows(docker_raw, fixture, 'docker')
        for group, trials, historical, sha in ((stock, runtime_trials, True, archive_sha),
                                               (fork, runtime_trials, False, None),
                                               (docker, docker_trials, True, archive_sha)):
            require(len(group) == trials and {row.get('trial') for row in group}
                    == set(range(1, trials + 1))
                    and all(row.get('status') == 0 and type(row.get('seconds')) in (int, float)
                            and not isinstance(row.get('seconds'), bool)
                            and math.isfinite(row['seconds']) and row['seconds'] > 0
                            and ((row.get('historical') is True) if historical
                                 else row.get('historical') is not True)
                            and (sha is None or row.get('reference_archive_sha256') == sha)
                            for row in group),
                    'Raw runtime or Docker trials are incomplete, failed, or misattributed: ' + fixture)
        stock_median = statistics.median(row['seconds'] for row in stock)
        fork_median = statistics.median(row['seconds'] for row in fork)
        docker_median = statistics.median(row['seconds'] for row in docker)
        worst = max(row['seconds'] for row in fork) / min(row['seconds'] for row in docker)
        worst_stock = max(row['seconds'] for row in fork) / min(row['seconds'] for row in stock)
        matrix_row = next((row for row in matrix if row.get('fixture') == fixture), None)
        require(worst_stock < 10 and matrix_row is not None and matrix_row.get('stock') == stock_median
                and matrix_row.get('fork') == fork_median
                and matrix_row.get('ratio') == fork_median / stock_median
                and matrix_row.get('worst_trial_ratio') == max(
                    row['seconds'] for row in fork) / min(row['seconds'] for row in stock)
                and matrix_row.get('comparison') == 'historical'
                and matrix_row.get('historical_lanes') == ['stock']
                and matrix_row.get('worst_trial_ratio') == worst_stock
                and matrix_row.get('passed') is True,
                'Runtime matrix does not recompute from its raw trials: ' + fixture)
        expected_matrix.append({'fixture': fixture,
            'apple_seconds': stock_median, 'fork_seconds': fork_median,
            'docker_seconds': docker_median, 'fork_apple_ratio': fork_median / stock_median,
            'apple_historical': True, 'docker_historical': True,
            'docker_historical_engine_version': transition['historical'],
            'docker_current_engine_version': transition['current'],
            'fork_docker_ratio': fork_median / docker_median,
            'worst_fork_docker_ratio': worst,
            'passed': docker_acceptance.get('passed') is True and worst < 10})
    require(runtime_acceptance.get('passed') is True
            and docker_acceptance.get('passed') is True
            and docker_acceptance.get('historical') is True
            and docker_acceptance.get('medians') == {
                row['fixture']: row['docker_seconds'] for row in expected_matrix},
            'Runtime or Docker raw measurements do not match accepted stage summaries')
    return expected_matrix


def admit_qualification(root: Path, evidence: Path, source: str) -> dict[str, dict]:
    acceptance = load_json(evidence, 'acceptance.json')
    qualification = load_json(evidence, 'qualification.json')
    require(acceptance == {'passed': True, 'target': 'bazel-qualify', 'failures': []},
            'Qualification wrapper did not pass exactly')
    require(qualification.get('source') == source and qualification.get('passed') is True
            and qualification.get('failures') == [], 'Full qualification is not passed for this source')
    stages = qualification.get('stages')
    require(isinstance(stages, list)
            and [row.get('name') for row in stages] == expected_stages(root),
            'Qualification stage inventory differs from the maintained recipe')
    for row in stages:
        require(row.get('blocked_by') == [] and (row.get('state') == 'passed'
                or row.get('name') == 'component-benchmarks'
                and row.get('state') == 'reviewed-differences'),
                'Qualification contains a blocked or unadmitted stage: ' + str(row.get('name')))
    for name in REQUIRED_RECEIPTS:
        load_json(evidence, name)
    records = {name: load_json(evidence, name) for name in CORE_RECEIPTS[1:]}
    source_inputs = load_json(evidence, 'runtime-smoke/source-inputs.json')
    require(source_inputs.get('fork') == source,
            'Runtime source-input receipt is not bound to the qualified commit')
    release = records['release/release-artifact.json']
    install = load_json(evidence, 'install/install.json')
    require(release.get('passed') is True and release.get('source') == source
            and release.get('failures') == [] and release.get('notarized') is True
            and release.get('notary', {}).get('status') == 'Accepted'
            and bool(release.get('notary', {}).get('id')),
            'Qualified signed runtime or accepted notary receipt is missing')
    require(load_json(evidence, 'release/notary-status.json') == release['notary']
            and load_json(evidence, 'release/notary-submission.json').get('id') == release['notary']['id'],
            'Notary submission, status, and release receipt identities differ')
    require(install.get('passed') is True and install.get('source') == source
            and install.get('replacement_started') is True
            and install.get('previous_installation_restored') is True
            and install.get('archive_sha256') == release.get('archives', {}).get(ASSETS[0]),
            'Installed runtime receipt or original-install restoration differs')
    for name in ('host-lease.json', 'colima-lease.json'):
        lease = load_json(evidence, name)
        require(lease.get('restored') is True and lease.get('failures') in (None, []),
                name + ' does not prove restoration')
    host = load_json(evidence, 'host-lease.json')
    owner = host.get('owner')
    require(host.get('acquired') is True and host.get('evidence') == str(evidence.resolve())
            and host.get('command_lock') == str(evidence.resolve() / 'commands.lock')
            and type(owner) is int and owner > 0,
            'Host lease is not bound to this completed qualification')
    try:
        os.kill(owner, 0)
    except ProcessLookupError:
        pass
    except PermissionError as error:
        raise ValueError('Host lease owner is still active or cannot be confirmed exited') from error
    else:
        raise ValueError('Host lease owner is still active; qualification is not terminal')
    colima = load_json(evidence, 'colima-lease.json')
    require(type(colima.get('started_by_this_run')) is bool
            and (not colima['started_by_this_run'] or colima.get('profile', {}).get('name') == 'default'),
            'Colima lease does not record a valid original profile disposition')
    services = load_json(evidence, 'service-restoration.json')
    labels = [row.get('label') for row in services] if isinstance(services, list) else []
    require(isinstance(services, list) and bool(services) and len(labels) == len(set(labels))
            and all(isinstance(row.get('label'), str)
                    and row['label'].startswith(('com.apple.container.', 'sh.brew.container'))
                    and row.get('restored') is True and row.get('unloaded') is True
                    and isinstance(row.get('path'), str) and SHA.fullmatch(row.get('sha256', ''))
                    for row in services),
            'Original service restoration receipts are incomplete')
    for row in services:
        before = evidence / (row['label'] + '.before.txt')
        original = evidence / (row['label'] + '.original.plist')
        require(before.is_file() and not before.is_symlink() and original.is_file()
                and not original.is_symlink() and digest(original) == row['sha256']
                and plistlib.loads(original.read_bytes()).get('Label') == row['label'],
                'Original service registration snapshot differs: ' + row['label'])
    for name in ('runtime-smoke/acceptance.json', 'runtime-benchmark/acceptance.json',
                 'docker-benchmark/acceptance.json', 'docker-reference-admission/acceptance.json',
                 'runtime-comparison-acceptance.json'):
        receipt = load_json(evidence, name)
        require(receipt.get('passed') is True and receipt.get('failures') in (None, []),
                name + ' did not pass')
    compare = load_json(evidence, 'runtime-comparison-acceptance.json')
    require(compare.get('reference_verified') is True, 'Historical runtime reference was not authenticated')
    comparison_rows = load_json(evidence, 'runtime-comparison.json')
    docker_transition = load_json(evidence, 'docker-benchmark/acceptance.json').get('serverVersionTransition')
    fixtures = expected_runtime_fixtures(root)
    recomputed_comparison = admit_runtime_comparison(root, evidence, fixtures,
                                                      docker_transition, source=source)
    require(compare.get('passed') is True and compare.get('failures') == []
            and compare.get('dockerServerVersionTransition') == docker_transition
            and isinstance(comparison_rows, list)
            and comparison_rows == recomputed_comparison
            and all(row.get('passed') is True for row in comparison_rows),
            'Full runtime/Apple/Docker comparison does not recompute from its raw trial evidence')
    quality = load_json(evidence, 'github-quality/quality.json')
    require(quality.get('passed') is True and quality.get('source') == source
            and quality.get('failures') == [], 'Hosted quality receipt is not admitted')
    integration = load_json(evidence, 'integration/integration.json')
    outcomes = load_json(evidence, 'integration/results.json')
    coverage = load_json(evidence, 'integration/coverage/coverage.json')
    integration_source = ast.parse((root / 'Tools/bazel/runtime_integration.py').read_text())
    layer_inventory = list(next(ast.literal_eval(node.value) for node in integration_source.body
                           if isinstance(node, ast.Assign) and any(
                               isinstance(target, ast.Name) and target.id == 'LAYERS' for target in node.targets)))
    require(integration.get('passed') is True and integration.get('selection') is None
            and integration.get('coverage') is True and integration.get('layers') == layer_inventory
            and integration.get('failures') == []
            and integration.get('stopped_children') == [] and isinstance(outcomes, list)
            and bool(outcomes) and all(row.get('status') == 0 for row in outcomes)
            and coverage.get('passed') is True and coverage.get('full_suite') is True
            and coverage.get('restored') is True and coverage.get('revision') == source
            and coverage.get('failures') in (None, []),
            'Full integration selection or restored coverage is not admitted')
    combined = load_json(evidence, 'combined-coverage/coverage.json')
    require(combined.get('passed') is True and combined.get('kind') == 'unit-and-full-integration'
            and combined.get('failures') in (None, []), 'Combined unit and full integration coverage failed')
    vm = load_json(evidence, 'vm-integration/vm-integration.json')
    require(vm.get('passed') is True and vm.get('cleanup_complete') is True
            and vm.get('selection') is None and type(vm.get('passed_tests')) is int
            and type(vm.get('total_tests')) is int and type(vm.get('skipped_tests')) is int
            and vm['passed_tests'] > 0 and vm['passed_tests'] + vm['skipped_tests'] == vm['total_tests']
            and len(vm.get('skips', [])) == vm['skipped_tests'] and vm.get('failures') == [],
            'Full VM integration inventory or cleanup is incomplete')
    vm_source = ast.parse((root / 'Tools/bazel/vm_integration.py').read_text())
    vm_constants = {}
    for node in vm_source.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in ('GPU_SKIPS', 'GPU_SKIP_REASON'):
                vm_constants[node.targets[0].id] = ast.literal_eval(node.value)
    require(set(vm_constants) == {'GPU_SKIPS', 'GPU_SKIP_REASON'}
            and all(row.get('test') in vm_constants['GPU_SKIPS']
                    and row.get('reason') == vm_constants['GPU_SKIP_REASON'] for row in vm['skips']),
            'VM skipped-test dispositions differ from maintained policy')
    review = load_json(evidence, 'components/comparison-review.json')
    require(review.get('completed') is True and not review.get('unexpected_failures')
            and not review.get('invalid_timings'), 'Component benchmark differences lack a complete review')
    for name in ('runtime-smoke/fork-fingerprint.json',
                 'runtime-smoke/guest-artifact.json', 'runtime-smoke/builder-artifact.json'):
        value = records[name]
        if name.endswith('fork-fingerprint.json'):
            require(value.get('lane') == 'fork', 'Runtime fingerprint is not the fork lane')
        else:
            require(value.get('schema') == 1 and value.get('identity', {}).get('source'),
                    'Reused lower-layer receipt is incomplete: ' + name)
    return records


def q_modules(container_root: Path):
    package_name = '_qualified_container_native_' + hashlib.sha256(
        str(container_root.resolve()).encode()).hexdigest()[:16]
    for name in tuple(sys.modules):
        if name == package_name or name.startswith(package_name + '.'):
            del sys.modules[name]
    package_root = container_root / 'Tools/bazel/artifacts'
    package = types.ModuleType(package_name)
    package.__path__ = [str(package_root)]
    package.__package__ = package_name
    sys.modules[package_name] = package
    for leaf in ('native_consumer', 'native_layers'):
        path = package_root / (leaf + '.py')
        spec = importlib.util.spec_from_file_location(package_name + '.' + leaf, path)
        require(spec is not None and spec.loader is not None
                and Path(spec.origin).resolve() == path.resolve(),
                'Unable to load exact Container native verifier: ' + leaf)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
    consumer = sys.modules[package_name + '.native_consumer']
    layers = sys.modules[package_name + '.native_layers']
    # Relative imports must stay inside this exact admitted Container checkout.
    # This guards against a same-named Compose or retained module already in
    # Python's import cache silently changing the verifier implementation.
    for name, module in tuple(sys.modules.items()):
        if name == package_name or name.startswith(package_name + '.'):
            if name == package_name:
                require(Path(module.__path__[0]).resolve() == package_root.resolve(),
                        'Container verifier package root differs')
                continue
            origin = getattr(module, '__file__', None)
            require(origin is not None and Path(origin).resolve().is_relative_to(package_root.resolve()),
                    'Container native verifier imported a module outside its explicit checkout: ' + name)
    return consumer, layers


def runtime_build_inputs(container_root: Path) -> dict[str, str]:
    paths = [container_root / name for name in ('Package.swift', 'Package.resolved', 'MODULE.bazel',
                                                'MODULE.bazel.lock', 'BUILD.bazel', '.bazelrc', '.bazelversion')]
    paths += [path for path in (container_root / 'Tools/bazel').iterdir()
              if path.suffix in {'.bzl', '.patch'} or path.name == 'semantic_metadata.py']
    paths += [path for path in (container_root / 'Tools/ContainerSemanticHelper').rglob('*')
              if path.is_file() and path.suffix in {'.go', '.mod', '.sum', '.py', '.bazel'}]
    artifacts = container_root / 'Tools/bazel/artifacts'
    paths += [path for path in artifacts.rglob('*') if path.is_file() and not path.is_symlink()
              and '__pycache__' not in path.parts
              and (path.suffix in {'.py', '.bzl', '.json'} or path.name == 'BUILD.bazel')]
    return {str(path.relative_to(container_root)): digest(path) for path in sorted(paths)}


def runtime_constants(container_root: Path) -> tuple[Path, Path]:
    tree = ast.parse((container_root / 'Tools/bazel/fork_benchmark.py').read_text())
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in ('BAZEL', 'STORAGE'):
                value = node.value
                if (isinstance(value, ast.Call) and isinstance(value.func, ast.Name)
                        and value.func.id == 'Path' and len(value.args) == 1 and not value.keywords):
                    value = value.args[0]
                try:
                    values[node.targets[0].id] = ast.literal_eval(value)
                except (SyntaxError, ValueError) as error:
                    raise ValueError('Q runtime toolchain paths are not literal maintained inputs') from error
    require(set(values) == {'BAZEL', 'STORAGE'}
            and all(isinstance(value, str) and Path(value).is_absolute() for value in values.values()),
            'Q runtime toolchain paths are not literal maintained inputs')
    return Path(values['BAZEL']), Path(values['STORAGE'])


def native_chain(container_root: Path, evidence: Path, source: str) -> tuple[dict, dict]:
    consumer, layers = q_modules(container_root)
    bazel, storage = runtime_constants(container_root)
    native_locks = container_root / 'Tools/bazel/artifacts/native-locks'
    admission = layers.import_layers(container_root, locks=native_locks)
    require(admission.get('source') == source, 'Native lower admission source differs')
    lock_records = {group: {kind: json.loads((native_locks / f'{group}.{kind}.lock.json').read_text())
                            for kind in ('archive', 'evidence', 'proof')}
                    for group in ('argument-parser', 'foundation', 'containerization', 'engine-api')}
    names = (*NATIVE_JSON, *NATIVE_RAW)
    hashes = {}
    for name in names:
        path = evidence / name
        require(path.is_file() and not path.is_symlink()
                and path.resolve(strict=True).is_relative_to(evidence.resolve(strict=True)),
                'Missing or escaped native receipt: ' + name)
        hashes[name] = digest(path)
    for name in ('compiled-consumer.json', 'fork-fingerprint.json', 'source-inputs.json'):
        require(len({hashes[phase + '/' + name] for phase in NATIVE_PHASES}) == 1,
                'Copied native receipt differs: ' + name)
    source_inputs = json.loads((evidence / 'runtime-smoke/source-inputs.json').read_text())
    expected_sources = {str(path.relative_to(container_root)): digest(path)
                        for path in sorted((container_root / 'Sources').rglob('*')) if path.is_file()}
    require(source_inputs.get('fork') == source
            and source_inputs.get('build_inputs') == runtime_build_inputs(container_root)
            and source_inputs.get('fork_pins') == json.loads((container_root / 'Package.resolved').read_text())['pins']
            and source_inputs.get('source_sha256', {}).get('fork') == expected_sources
            and all(json.loads((evidence / phase / 'source-inputs.json').read_text()) == source_inputs
                    for phase in NATIVE_PHASES),
            'Native source-input record differs from current Q source and lock')
    projected = {}
    for phase, configuration, name in (
            ('runtime-smoke', 'release', 'compiled-consumer.json'),
            ('integration/coverage', 'runtime-coverage', 'coverage-compiled-consumer.json')):
        record = consumer.verify_receipt(evidence / phase / name, admission, source, configuration,
                                         output_base=None, bazel=bazel,
                                         output_root=storage / 'output')
        fingerprint = json.loads((evidence / phase / 'fork-fingerprint.json').read_text())
        unsigned = consumer.unsigned_product_hashes(record)
        require(fingerprint.get('lane') == 'fork'
                and fingerprint.get('compiled_consumer_sha256') == hashes[phase + '/' + name]
                and fingerprint.get('unsigned_native_inputs') == unsigned,
                'Native receipt and qualified fingerprint do not agree')
        paths = {product: ('bin/' + product if product in ('container', 'container-apiserver', 'container-engine')
                           else 'libexec/container/plugins/' + product + '/bin/' + product)
                 for product in unsigned}
        helpers = {'libexec/container/helpers/container-semantic-helper',
                   'libexec/container/helpers/container-semantic-helper.manifest.json'}
        binaries = fingerprint.get('binaries', {})
        require(set(binaries) == set(paths.values()) | helpers
                and all(SHA.fullmatch(value) for value in binaries.values()),
                'Native signed measured executable inventory differs')
        graph = record['graph']
        row = {'configuration': record['configuration'], 'source': record['source'],
               'compiledConsumerSHA256': hashes[phase + '/' + name],
               'buildEventsSHA256': record['buildEventsSHA256'],
               'actionGraphSHA256': record['actionGraphSHA256'],
               'build': {key: record['build'][key] for key in
                         ('invocation', 'targets', 'configuration', 'optionsSHA256', 'files')},
               'loadedBUILD': graph['loadedBUILD'], 'importedArchiveInputs': graph['archiveInputs'],
               'importedActions': graph['importedActions'], 'links': graph['links'],
               'actions': graph['actions'], 'recipeSHA256': record['recipeSHA256'],
               'recipeCompatibility': record['recipeCompatibility'], 'toolchain': record['toolchain'],
               'products': {product: {'unsignedSHA256': unsigned[product], 'measuredPath': paths[product],
                                      'signedMeasuredSHA256': binaries[paths[product]]}
                            for product in sorted(unsigned)},
               'semanticHelperSHA256': {key: binaries[key] for key in sorted(helpers)}}
        projected[configuration] = row
    release = json.loads((evidence / 'release/release-artifact.json').read_text())
    require(release.get('compiled_consumer_sha256') == hashes['release/compiled-consumer.json'],
            'Signed distribution receipt lost its compiled-consumer link')
    payload = release['payload']
    for product in projected['release']['products'].values():
        require(product['measuredPath'] in payload, 'Signed distribution omitted a native product')
        product['signedDistributionSHA256'] = payload[product['measuredPath']]
    lower = {}
    for group, owner in (('argument-parser', 'stephenlclarke/container'),
                         ('foundation', 'stephenlclarke/container'),
                         ('containerization', 'stephenlclarke/containerization'),
                         ('engine-api', 'stephenlclarke/container-engine-api')):
        row = admission['layers'][group]
        triple = lock_records[group]
        asset_ids = [row[key] for key in ('assetId', 'evidenceAssetId', 'proofAssetId')]
        require(len(set(asset_ids)) == 3 and row['releaseId'] > 0,
                'Native lower published release or asset identities are incomplete')
        assets = {}
        for kind, sha_key, id_key in (('archive', 'archiveSHA256', 'assetId'),
                                      ('evidence', 'evidenceSHA256', 'evidenceAssetId'),
                                      ('proof', 'proofSHA256', 'proofAssetId')):
            lock = triple[kind]
            require(row[sha_key] == lock['sha256'], 'Native lower archive/proof lock mismatch')
            assets[kind] = {'name': lock['asset'], 'assetId': row[id_key], 'sha256': row[sha_key],
                            'lockSHA256': layers.digest(native_locks / f'{group}.{kind}.lock.json')}
        lower[group] = {'repository': triple['archive']['repository'], 'tag': triple['archive']['tag'],
                        'targetCommit': triple['archive']['targetCommit'], 'releaseId': row['releaseId'],
                        'assets': assets, 'producerCommit': row['producerCommit'],
                        'sourcePins': row['sourcePins'], 'lower': row['lower']}
    chain = {'schema': 1, 'source': source, 'layers': lower, 'release': projected['release'],
             'coverage': projected['runtime-coverage'], 'sourceReceiptSHA256': hashes,
             'measuredAssets': {name: release['archives'][name] for name in ASSETS[2:4]},
             'signedArchiveSHA256': release['archives'][ASSETS[0]],
             'interpretation': 'Eight unsigned native products are linked to separately measured and signed distribution bytes; paths remain in private receipts.'}
    encoded = json_bytes(chain)
    require(not PRIVATE.search(encoded.decode()), 'Native public chain contains a private path or credential')
    return chain, lock_records


def helper_hashes(container_root: Path) -> dict[str, str]:
    return {name + '.py': digest(container_root / 'Tools/bazel' / (name + '.py')) for name in HELPERS}


def qualification_receipt_hashes(evidence: Path) -> dict[str, str]:
    names = set((*REQUIRED_RECEIPTS, *NATIVE_JSON, *NATIVE_RAW))
    services = load_json(evidence, 'service-restoration.json')
    require(isinstance(services, list), 'Service restoration inventory is malformed')
    for row in services:
        require(isinstance(row, dict) and isinstance(row.get('label'), str),
                'Service restoration row is malformed')
        names.update((row['label'] + '.before.txt', row['label'] + '.original.plist'))
    metadata = load_json(evidence, 'components/metadata.json')
    require(isinstance(metadata.get('pairs'), dict), 'Component source-pair inventory is malformed')
    measured = metadata.get('measured_components')
    require(isinstance(measured, list) and len(measured) == len(set(measured))
            and set(measured) <= set(metadata['pairs']),
            'Fresh component measurement inventory is malformed')
    for component in metadata['pairs']:
        require(public_label(component) == component, 'Component name is unsafe')
    names.update(f'components/{component}-fork-inputs.json' for component in measured)
    result = {}
    for name in sorted(names):
        path = evidence / name
        require(path.is_file() and not path.is_symlink()
                and path.resolve(strict=True).is_relative_to(evidence.resolve(strict=True)),
                'Missing or escaped qualification evidence: ' + name)
        result[name] = digest(path)
    return result


def lower_products(container_root: Path, evidence: Path) -> dict:
    locks_dir = container_root / 'Tools/bazel/artifacts/lower-locks'
    result = {}
    for name in ('guest', 'builder'):
        lock = json.loads((locks_dir / (name + '.lock.json')).read_text())
        row = json.loads((evidence / f'runtime-smoke/{name}-artifact.json').read_text())
        archive = Path(row['archive'])
        require(row['identity'].get('source') == lock['targetCommit']
                and row.get('archive_sha256') == lock['sha256']
                and archive.is_file() and not archive.is_symlink() and digest(archive) == lock['sha256'],
                'Reused qualified lower artifact differs from its authenticated lock: ' + name)
        result[name] = (lock, row)
    return result


def public_measurements(rows: list, *, go: bool = False,
                       qualified_source: Optional[str] = None,
                       historical_source: Optional[str] = None) -> list[dict]:
    output = []
    for row in rows:
        if go:
            require(type(row.get('trial')) is int and row['trial'] >= 0,
                    'Go benchmark trial is malformed')
            item = {'lane': public_label(row['lane']), 'fixture': public_label(row['fixture']),
                    'trial': row['trial'], 'iterations': public_positive(row['iterations']),
                    'ns_per_op': public_positive(row['ns_per_op'])}
            if 'historical' in row:
                require(type(row['historical']) is bool, 'Go benchmark historical marker is malformed')
                item['historical'] = row['historical']
                if row['historical'] and historical_source is not None:
                    item['evidenceSource'] = historical_source
            elif qualified_source is not None:
                item['evidenceSource'] = qualified_source
            if 'reference_archive_sha256' in row:
                require(isinstance(row['reference_archive_sha256'], str)
                        and SHA.fullmatch(row['reference_archive_sha256']),
                        'Historical Go benchmark archive link is malformed')
                item['referenceArchiveSHA256'] = row['reference_archive_sha256']
            if 'timestamp' in row:
                require(isinstance(row['timestamp'], (str, int, float))
                        and not PRIVATE.search(str(row['timestamp'])), 'Go benchmark timestamp is unsafe')
                item['timestamp'] = row['timestamp']
            output.append(item)
        else:
            require(type(row.get('trial')) is int and row['trial'] >= 0
                    and type(row.get('status')) is int and row['status'] >= 0,
                    'Benchmark trial or status is malformed')
            if 'historical' in row:
                require(type(row['historical']) is bool,
                        'Benchmark historical marker is malformed')
            if 'timestamp' in row:
                require(isinstance(row['timestamp'], (str, int, float))
                        and not PRIVATE.search(str(row['timestamp'])),
                        'Benchmark timestamp is unsafe')
            if 'reference_archive_sha256' in row:
                require(isinstance(row['reference_archive_sha256'], str)
                        and SHA.fullmatch(row['reference_archive_sha256']),
                        'Historical benchmark archive link is malformed')
            output.append({key: public_label(row[key]) for key in ('component', 'lane', 'fixture')} | {
                'trial': row['trial'], 'seconds': public_positive(row['seconds']), 'status': row['status'],
                **({'historical': row['historical']} if type(row.get('historical')) is bool else {}),
                **({'evidenceSource': historical_source if row.get('historical') is True else qualified_source}
                   if qualified_source is not None and historical_source is not None else {}),
                **({'referenceArchiveSHA256': row['reference_archive_sha256']}
                   if SHA.fullmatch(row.get('reference_archive_sha256', '')) else {}),
                **({'timestamp': row['timestamp']} if 'timestamp' in row else {}),
                **({'executed_tests': row['executed_tests']} if type(row.get('executed_tests')) is int else {})})
    require(bool(output), 'Benchmark evidence contains no raw measurements')
    return output


def public_runtime_comparison(rows: list, source: str, historical_source: str,
                              server_transition: dict) -> list[dict]:
    output = []
    fields = ('apple_seconds', 'fork_seconds', 'docker_seconds', 'fork_apple_ratio',
              'fork_docker_ratio', 'worst_fork_docker_ratio')
    for row in rows:
        item = {'fixture': public_label(row['fixture'])}
        for key in fields:
            value = row.get(key)
            item[key] = None if value is None else public_positive(value)
        for key in ('apple_historical', 'docker_historical', 'passed'):
            require(type(row.get(key)) is bool, 'Runtime comparison disposition is malformed')
            item[key] = row[key]
        for key in ('docker_historical_engine_version', 'docker_current_engine_version'):
            item[key] = public_label(row[key])
        require(row['docker_historical_engine_version'] == server_transition['historical']
                and row['docker_current_engine_version'] == server_transition['current'],
                'Runtime comparison Docker identities differ from preserved engine admission')
        item['appleEvidenceSource'] = historical_source if row['apple_historical'] else source
        item['forkEvidenceSource'] = source
        item['dockerEvidenceSource'] = historical_source if row['docker_historical'] else source
        output.append(item)
    require(bool(output), 'Runtime comparison contains no fixture results')
    return output


def public_label(value: object) -> str:
    require(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_.+:@/\\-]{1,160}', value) is not None
            and not value.startswith('/') and '..' not in Path(value).parts,
            'Public benchmark label is unsafe')
    return value


def safe_relative_path(value: object) -> bool:
    return (isinstance(value, str) and bool(value) and not value.startswith('/')
            and not any(character in value for character in ('\\', ':', '\0'))
            and all(part not in ('', '.', '..') for part in value.split('/')))


def safe_source_manifest_path(value: object) -> bool:
    return (safe_relative_path(value)
            and re.fullmatch(r'[A-Za-z0-9_.+@/\-]{1,512}', value) is not None)


def public_positive(value: object) -> int | float:
    require(not isinstance(value, bool) and isinstance(value, (int, float))
            and value > 0 and math.isfinite(value),
            'Public benchmark value must be finite and positive')
    return value


def public_matrix(rows: list) -> list[dict]:
    output = []
    for row in rows:
        item = {key: public_label(row[key]) for key in ('component', 'fixture') if key in row}
        for key in ('stock', 'fork', 'ratio', 'worst_trial_ratio'):
            value = row.get(key)
            item[key] = (None if key in ('ratio', 'worst_trial_ratio') and value is None
                         and row.get('passed') is False else public_positive(value))
        require(type(row.get('passed')) is bool, 'Benchmark matrix outcome is malformed')
        item['passed'] = row['passed']
        for key in ('comparison', 'historical_lanes'):
            if key in row:
                if key == 'comparison':
                    item[key] = public_label(row[key])
                else:
                    require(isinstance(row[key], list), 'Historical lane inventory is malformed')
                    item[key] = [public_label(value) for value in row[key]]
        if 'historical' in row:
            require(type(row['historical']) is bool, 'Benchmark matrix historical marker is malformed')
            item['historical'] = row['historical']
        if 'phase_ratios' in row:
            require(isinstance(row['phase_ratios'], dict) and bool(row['phase_ratios']),
                    'Benchmark matrix phase-ratio inventory is malformed')
            item['phase_ratios'] = {public_label(name): public_positive(value)
                                    for name, value in row['phase_ratios'].items()}
        output.append(item)
    require(bool(output), 'Benchmark matrix contains no comparisons')
    return output


def public_semantic_review(review: dict) -> dict:
    kinds = ('expected_differences', 'historical_expected_differences',
             'superseded_historical_differences')
    require(review.get('completed') is True and not review.get('unexpected_failures')
            and not review.get('invalid_timings'), 'Semantic review is incomplete or has unadmitted failures')
    dispositions = {}
    for kind in kinds:
        rows = review.get(kind)
        require(isinstance(rows, list), 'Semantic review disposition inventory is malformed')
        projected = []
        for row in rows:
            item = {key: public_label(row[key]) for key in ('component', 'lane', 'fixture')}
            require(type(row.get('trial')) is int and row['trial'] >= 0
                    and type(row.get('status')) is int and row['status'] >= 0,
                    'Semantic review measurement identity is malformed')
            item.update(trial=row['trial'], seconds=public_positive(row['seconds']), status=row['status'])
            if 'historical' in row:
                require(type(row['historical']) is bool, 'Semantic review historical marker is malformed')
                item['historical'] = row['historical']
            projected.append(item)
        dispositions[kind] = {'count': len(projected), 'rows': projected}
    measured = review.get('compatibility_measured')
    compatible = review.get('compatible')
    components = review.get('freshly_measured_components')
    require(type(measured) is bool and (compatible is None or type(compatible) is bool)
            and isinstance(components, list), 'Semantic review summary is malformed')
    return {'phase': public_label(review.get('phase', 'all')),
            'completed': True, 'compatibilityMeasured': measured,
            'compatible': compatible,
            'freshlyMeasuredComponents': [public_label(row) for row in components],
            'unexpectedFailureCount': 0, 'invalidTimingCount': 0,
            'dispositions': dispositions}


def public_fingerprint(row: dict) -> dict:
    binaries = row.get('binaries')
    require(row.get('lane') in ('fork', 'stock') and isinstance(binaries, dict) and bool(binaries)
            and all(isinstance(name, str) and not name.startswith('/')
                    and '..' not in Path(name).parts and SHA.fullmatch(value)
                    for name, value in binaries.items()), 'Runtime fingerprint has unsafe binary identities')
    fields = ('kernel_sha256', 'init_image', 'builder_image', 'workload_image', 'cli_version',
              'package_lock_sha256', 'init_archive_sha256', 'builder_archive_sha256')
    result = {'lane': row['lane'], 'binariesSHA256': binaries}
    for key in fields:
        if key in row:
            value = row[key]
            require(isinstance(value, str) and value and not PRIVATE.search(value) and len(value) <= 1024,
                    'Runtime fingerprint has a private or malformed field')
            result[key] = value
    return result


def public_historical_fingerprint(row: dict, source: str) -> dict:
    """Preserve the authenticated archive's already-public stock fingerprint."""
    fields = {'binariesSHA256', 'builder_image', 'cli_version', 'init_image', 'kernel_sha256',
              'lane', 'package_lock_sha256', 'workload_image'}
    require(isinstance(row, dict) and set(row) == fields and row.get('lane') == 'stock'
            and isinstance(row.get('binariesSHA256'), dict) and bool(row['binariesSHA256'])
            and all(isinstance(name, str) and safe_relative_path(name)
                    and SHA.fullmatch(value) for name, value in row['binariesSHA256'].items())
            and SHA.fullmatch(row.get('kernel_sha256', ''))
            and SHA.fullmatch(row.get('package_lock_sha256', '')),
            'Authenticated historical stock fingerprint schema or binary identities differ')
    result = dict(row)
    for key in ('builder_image', 'init_image', 'workload_image'):
        result[key] = public_label(row[key])
    cli_version = row.get('cli_version')
    require(isinstance(cli_version, str) and len(cli_version) <= 256
            and cli_version.isprintable() and not PRIVATE.search(cli_version),
            'Authenticated historical stock CLI version is not a safe public identity')
    result['cli_version'] = cli_version
    result['evidenceSource'] = source
    return result


def public_docker_admission(container_root: Path, evidence: Path, phase: str) -> dict:
    admission = load_json(evidence, phase + '/engine-admission.json')
    required = {'current', 'historical', 'serverVersionTransition', 'configuredEnvironment',
                'liveProfile', 'selectedDockerContext', 'usableMemoryBytes', 'dockerInfoLogSHA256'}
    require(isinstance(admission, dict) and required <= set(admission),
            'Docker engine admission lacks its current/historical transition evidence')
    transition = admission['serverVersionTransition']
    require(transition.get('historical') == admission['historical'].get('serverVersion')
            and transition.get('current') == admission['current'].get('serverVersion'),
            'Docker engine transition does not preserve observed and archived server versions')
    policy = ast.parse((container_root / 'Tools/bazel/docker_benchmark.py').read_text())
    constants = {}
    for node in policy.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in ('HISTORICAL_DOCKER_SERVER_VERSION', 'ADMITTED_DOCKER_SERVER_VERSION'):
                constants[node.targets[0].id] = ast.literal_eval(node.value)
    require(set(constants) == {'HISTORICAL_DOCKER_SERVER_VERSION', 'ADMITTED_DOCKER_SERVER_VERSION'}
            and transition.get('historical') == constants['HISTORICAL_DOCKER_SERVER_VERSION']
            and transition.get('current') in {constants['HISTORICAL_DOCKER_SERVER_VERSION'],
                                               constants['ADMITTED_DOCKER_SERVER_VERSION']},
            'Docker transition differs from maintained finite server-version policy')
    acceptance = load_json(evidence, phase + '/acceptance.json')
    require(acceptance.get('serverVersionTransition') == transition,
            'Docker comparison acceptance omitted the current/historical server transition')
    # Retain the exact source policy constants; the runtime label itself is
    # never replaced with its historical value.
    result = {key: admission[key] for key in required}
    result['sourceReceiptSHA256'] = digest(evidence / (phase + '/engine-admission.json'))
    if 'supplementalEnvironmentAsset' in admission:
        result['supplementalEnvironmentAsset'] = admission['supplementalEnvironmentAsset']
    return result


def admitted_historical_reference(container_root: Path, evidence: Path) -> dict:
    tree = ast.parse((container_root / 'Tools/bazel/benchmark_reference.py').read_text())
    constants = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            if node.targets[0].id in ('SOURCE', 'ARCHIVE_SHA256', 'NAME'):
                constants[node.targets[0].id] = ast.literal_eval(node.value)
    require(set(constants) == {'SOURCE', 'ARCHIVE_SHA256', 'NAME'}
            and COMMIT.fullmatch(constants['SOURCE']) and SHA.fullmatch(constants['ARCHIVE_SHA256']),
            'Historical benchmark source policy is incomplete')
    cached = (Path.home() / 'Library/Application Support/ContainerFamily/retained/container-only/'
              'benchmark-references' / constants['ARCHIVE_SHA256'] / constants['NAME'])
    require(cached.is_file() and not cached.is_symlink()
            and digest(cached) == constants['ARCHIVE_SHA256'],
            'Authenticated historical benchmark archive is not retained')
    with zipfile.ZipFile(cached) as archive:
        require(sorted(archive.namelist()) == ['benchmark.json', 'manifest.json'],
                'Authenticated historical benchmark archive members differ')
        actual = json.loads(archive.read('benchmark.json'))
    receipt = load_json(evidence, 'benchmark-reference/historical-reference.json')
    require(receipt.get('reference') == actual
            and receipt.get('archiveSHA256') == constants['ARCHIVE_SHA256']
            and actual.get('source') == constants['SOURCE'] and actual.get('historical') is True
            and receipt.get('historical') is True
            and receipt.get('referenceRebuilt') is False
            and receipt.get('referenceRerun') is False
            and isinstance(actual.get('identityLimit'), str) and bool(actual['identityLimit'])
            and not PRIVATE.search(actual['identityLimit'])
            and receipt.get('identityLimit') == actual['identityLimit'],
            'Qualification historical benchmark receipt differs from its authenticated archive')
    return {'source': constants['SOURCE'], 'archiveSHA256': constants['ARCHIVE_SHA256'],
            'historical': True, 'referenceRebuilt': False, 'referenceRerun': False,
            'identityLimit': actual['identityLimit']}


def validate_core(root: Path, evidence: Path) -> tuple[str, dict[str, dict]]:
    source = source_checkpoint(root)
    records = admit_qualification(root, evidence, source)
    lower = lower_products(root, evidence)
    guest_pin = json.loads((root / 'Package.resolved').read_text())['pins']
    selected = [row['state']['revision'] for row in guest_pin if row.get('identity') == 'containerization']
    require(len(selected) == 1 and lower['guest'][0]['targetCommit'] == selected[0],
            'Reused guest source differs from current Containerization pin')
    return source, records


def create_products(root: Path, evidence: Path, output: Path, compose_root: Path,
                    source: str, records: dict[str, dict], chain: dict) -> dict:
    release = records['release/release-artifact.json']
    fingerprint = records['runtime-smoke/fork-fingerprint.json']
    benchmark_fingerprint = json.loads((evidence / 'runtime-benchmark/fork-fingerprint.json').read_text())
    require(fingerprint == benchmark_fingerprint, 'Runtime benchmark fingerprint differs from qualified smoke')
    measured = json.loads((evidence / 'release/container-measured-fork-arm64.json').read_text())
    require(measured == {key: value for key, value in release['measured_products'].items()
                         if key not in ('manifest', 'manifest_sha256')},
            'Measured executable manifest differs from signed release receipt')
    require(measured.get('source') == source and measured.get('lane') == 'fork'
            and measured.get('resigned') is False
            and {name: row['sha256'] for name, row in measured['payload'].items()} == fingerprint['binaries']
            and release.get('payload', {}).get('bin/container') != fingerprint['binaries'].get('bin/container'),
            'Measured private and signed distribution executables are not distinct linked identities')
    for name in ('fork-fingerprint.json', 'source-inputs.json', 'acceptance.json',
                 'results.json', 'matrix.json', 'host.json'):
        require(measured.get('benchmark_provenance_sha256', {}).get(name)
                == digest(evidence / 'runtime-benchmark' / name),
                'Measured executable manifest lost its benchmark receipt link: ' + name)
    verify_tar_payload(evidence / 'release' / ASSETS[0], release['payload'])
    verify_tar_payload(evidence / 'release' / ASSETS[2], fingerprint['binaries'], measured['payload'])
    for name in ASSETS[0:1] + ASSETS[2:4]:
        path = evidence / 'release' / name
        require(path.is_file() and not path.is_symlink()
                and digest(path) == release['archives'][name], 'Release asset bytes differ: ' + name)
        shutil.copyfile(path, output / name)
    source_receipts = {name: digest(evidence / name) for name in CORE_RECEIPTS}
    helper_digests = helper_hashes(root)
    lower = lower_products(root, evidence)
    lower_rows = {}
    for name, (lock, row) in lower.items():
        lower_rows[name] = {'name': lock['asset'], 'source': lock['targetCommit'],
                            'sha256': lock['sha256'], 'reference': row['reference']}
    runtime = {key: fingerprint[key] for key in
               ('kernel_sha256', 'init_image', 'builder_image', 'workload_image',
                'package_lock_sha256', 'init_archive_sha256', 'builder_archive_sha256')}
    runtime.update({'compiled_consumer_sha256': fingerprint['compiled_consumer_sha256'],
                    'unsigned_native_inputs': fingerprint['unsigned_native_inputs'],
                    'payload': release['payload'],
                    'notary': {key: release['notary'][key] for key in ('id', 'status')},
                    'binariesSHA256': fingerprint['binaries']})
    bundle = {'schema': 1, 'kind': 'container-qualified-runtime-assets',
              'qualified_container_source': source,
              'native_compiled_chain': chain,
              'native_compiled_chain_sha256': hashlib.sha256(json_bytes(chain)).hexdigest(),
              'qualification': {'target': 'bazel-qualify', 'passed': True},
              'qualified_helpers_sha256': helper_digests,
              'source_receipt_sha256': source_receipts,
              'assets': {'runtime': {'name': ASSETS[0], 'source': source,
                                     'sha256': release['archives'][ASSETS[0]]},
                         'guest': lower_rows['guest'], 'builder': lower_rows['builder']},
              'guest': {'source': lower_rows['guest']['source'],
                        'reference': lower_rows['guest']['reference'],
                        'binaries': records['runtime-smoke/guest-artifact.json']['binaries']},
              'builder': {'source': lower_rows['builder']['source'],
                          'reference': lower_rows['builder']['reference']},
              'runtime': runtime,
              'measured_assets': {name: release['archives'][name] for name in ASSETS[2:4]},
              'performance_parity_asset': {'name': 'container-performance-parity-' + source[:8] + '.zip'},
              'distribution_readiness': {'installer_signed': False,
                                         'vendor_notice_closure_reviewed': False,
                                         'scope': 'Qualified signed prerelease; no broader distribution-readiness claim.'}}
    # The runtime/provenance locks are produced after GitHub creates the exact
    # draft assets. This structural check binds all source/evidence links now;
    # q_assets.validate is applied with the explicit admitted source below.
    q_assets = load_compose_module('q_assets', compose_root / 'Tools/bazel/q_assets.py')
    provisional_locks = {
        'runtime': {'sha256': release['archives'][ASSETS[0]]},
        'guest': json.loads((root / 'Tools/bazel/artifacts/lower-locks/guest.lock.json').read_text()),
        'builder': json.loads((root / 'Tools/bazel/artifacts/lower-locks/builder.lock.json').read_text()),
    }
    # q_assets expects the release lock record's exact sha field for products.
    provisional_locks['runtime'] = {'sha256': release['archives'][ASSETS[0]]}
    parity_name = 'container-performance-parity-' + source[:8] + '.zip'
    qualification = json.loads((evidence / 'qualification.json').read_text())
    component_metadata = json.loads((evidence / 'components/metadata.json').read_text())
    component_review = json.loads((evidence / 'components/comparison-review.json').read_text())
    runtime_results = json.loads((evidence / 'runtime-benchmark/results.json').read_text())
    runtime_matrix = json.loads((evidence / 'runtime-benchmark/matrix.json').read_text())
    docker_results = json.loads((evidence / 'docker-benchmark/results.json').read_text())
    docker_acceptance = json.loads((evidence / 'docker-benchmark/acceptance.json').read_text())
    component_raw = (json.loads((evidence / 'components/results.json').read_text())
                     + json.loads((evidence / 'components/historical-results.json').read_text()))
    go_raw = json.loads((evidence / 'components/go-benchmarks.json').read_text())
    go_matrix = json.loads((evidence / 'components/go-matrix.json').read_text())
    benchmark_fork = json.loads((evidence / 'runtime-benchmark/fork-fingerprint.json').read_text())
    reference_identity = admitted_historical_reference(root, evidence)
    archived_reference = load_json(evidence, 'benchmark-reference/historical-reference.json')['reference']
    archived_component_inputs = archived_reference.get('componentInputs')
    measured_components = component_metadata.get('measured_components')
    require(isinstance(archived_component_inputs, dict)
            and isinstance(measured_components, list)
            and set(measured_components) <= set(component_metadata.get('pairs', {})),
            'Historical component source identity inventory is incomplete')
    benchmark_stock = archived_reference.get('runtimeLaneFingerprints', {}).get('stock')
    require(isinstance(benchmark_stock, dict) and benchmark_stock.get('lane') == 'stock',
            'Authenticated historical archive has no original stock runtime fingerprint')
    swift = component_metadata.get('swift', '').splitlines()
    require(len(swift) >= 2 and swift[0].startswith('Apple Swift version ')
            and swift[1].startswith('Target: '), 'Component toolchain identification is incomplete')
    component_toolchain = {'bazelSHA256': component_metadata['bazel_sha256'],
                           'thirdPartyLockSHA256': component_metadata['third_party_lock'],
                           'harnessRevision': component_metadata['harness_revision'],
                           'swiftVersion': swift[0], 'swiftTarget': swift[1]}
    component_sources = {}
    for component, pair in component_metadata.get('pairs', {}).items():
        require(isinstance(pair, dict), 'Component source pair is malformed')
        archived_pair = archived_component_inputs.get(component)
        require(isinstance(archived_pair, dict),
                'Historical component source identity is missing: ' + component)
        lanes = {}
        for lane in ('stock', 'fork'):
            revision = pair.get(lane)
            require(isinstance(revision, str) and COMMIT.fullmatch(revision),
                    'Component lane source revision is malformed')
            historical = lane == 'stock' or component not in measured_components
            if historical:
                archived_lane = archived_pair.get(lane)
                require(isinstance(archived_lane, dict)
                        and archived_lane.get('revision') == revision
                        and type(archived_lane.get('inputCount')) is int
                        and archived_lane['inputCount'] > 0
                        and SHA.fullmatch(archived_lane.get('inputManifestSHA256', ''))
                        and isinstance(archived_lane.get('lockAndModuleInputSHA256'), dict),
                        'Historical component input identity differs from authenticated archive')
                archived_locks = archived_lane['lockAndModuleInputSHA256']
                require(isinstance(archived_lane.get('repository'), str)
                        and public_label(archived_lane['repository']) == archived_lane['repository']
                        and all(safe_source_manifest_path(path) and SHA.fullmatch(value)
                                for path, value in archived_locks.items()),
                        'Historical component input identity contains unsafe public fields')
                lanes[lane] = {'revision': revision, 'repository': archived_lane.get('repository'),
                    'historical': True, 'evidenceSource': reference_identity['source'],
                    'referenceArchiveSHA256': reference_identity['archiveSHA256'],
                    'inputManifestSHA256': archived_lane['inputManifestSHA256'],
                    'inputCount': archived_lane['inputCount'],
                    'lockAndModuleInputSHA256': archived_lane['lockAndModuleInputSHA256']}
            else:
                name = f'components/{component}-{lane}-inputs.json'
                inputs = load_json(evidence, name)
                require(isinstance(inputs, dict) and bool(inputs)
                        and all(safe_source_manifest_path(path)
                                and SHA.fullmatch(value) for path, value in inputs.items()),
                        'Component source-input manifest is incomplete or unsafe')
                lanes[lane] = {'revision': revision, 'historical': False,
                    'evidenceSource': source, 'inputManifestSHA256': digest(evidence / name),
                    'inputCount': len(inputs),
                    'lockAndModuleInputSHA256': {path: value for path, value in inputs.items()
                        if path.endswith(('Package.resolved', 'MODULE.bazel', 'go.mod', 'go.sum'))}}
        component_sources[component] = lanes
    parity_source_receipts = tuple(
        'runtime-benchmark/' + name for name in
        ('acceptance.json', 'fork-fingerprint.json', 'source-inputs.json', 'results.json',
         'matrix.json', 'host.json')) + tuple(
        'docker-benchmark/' + name for name in ('acceptance.json', 'results.json', 'engine-admission.json')) + (
        'components/metadata.json', 'components/results.json', 'components/historical-results.json',
        'components/matrix.json', 'components/go-benchmarks.json', 'components/go-matrix.json',
        'components/comparison-review.json', 'benchmark-reference/historical-reference.json',
        'runtime-comparison.json', 'runtime-comparison-acceptance.json',
        'integration/results.json', 'integration/coverage/coverage.json',
         'combined-coverage/coverage.json', 'vm-integration/vm-integration.json')
    parity_source_receipts += tuple(
        f'components/{component}-fork-inputs.json'
        for component in measured_components)
    parity_source_receipts += ('docker-reference-admission/acceptance.json',
                               'docker-reference-admission/results.json',
                               'docker-reference-admission/engine-admission.json')
    fork_public = public_fingerprint(benchmark_fork)
    fork_public.update(compiled_consumer_sha256=benchmark_fork['compiled_consumer_sha256'],
                       unsigned_native_inputs=benchmark_fork['unsigned_native_inputs'])
    parity = {'schema': 1, 'kind': 'container-performance-parity', 'source': source,
              'native_compiled_chain': chain,
              'native_compiled_chain_sha256': hashlib.sha256(json_bytes(chain)).hexdigest(),
              'historicalReference': reference_identity,
              'measuredPrivateBinarySHA256': fingerprint['binaries']['bin/container'],
              'releasedSignedBinarySHA256': release['payload']['bin/container'],
              'signedArchiveSHA256': release['archives'][ASSETS[0]],
              'measuredExecutableAssets': {name: release['archives'][name] for name in ASSETS[2:4]},
              'runtimeLaneFingerprints': {'fork': fork_public,
                                          'stock': public_historical_fingerprint(
                                              benchmark_stock, reference_identity['source'])},
              'componentToolchain': component_toolchain,
              'components': {'sources': component_sources,
                             'raw': public_measurements(component_raw,
                                 qualified_source=source, historical_source=reference_identity['source']),
                             'matrix': public_matrix(json.loads((evidence / 'components/matrix.json').read_text())),
                             'goRaw': public_measurements(go_raw, go=True,
                                 qualified_source=source, historical_source=reference_identity['source']),
                             'goEvidenceSource': reference_identity['source'],
                             'goMatrix': public_matrix(go_matrix),
                             'semanticParityReview': public_semantic_review(component_review)},
              'runtime': {'raw': public_measurements(runtime_results,
                                  qualified_source=source, historical_source=reference_identity['source']),
                          'matrix': public_matrix(runtime_matrix),
                          'crossRuntimeComparison': public_runtime_comparison(
                              json.loads((evidence / 'runtime-comparison.json').read_text()),
                              source, reference_identity['source'],
                              docker_acceptance['serverVersionTransition'])},
              'docker': {'raw': public_measurements(docker_results,
                                  qualified_source=source, historical_source=reference_identity['source']),
                         'medians': {public_label(name): public_positive(value)
                                     for name, value in docker_acceptance['medians'].items()},
                         'engineAdmission': public_docker_admission(root, evidence, 'docker-benchmark')},
              'functional': {'qualificationStages': [
                                {key: row[key] for key in ('name', 'state', 'seconds') if key in row}
                                for row in qualification['stages']],
                             'integrationOutcomes': public_measurements(
                                 json.loads((evidence / 'integration/results.json').read_text()),
                                 qualified_source=source, historical_source=reference_identity['source']),
                             'coverage': {name: {key: load_json(evidence, name)[key]
                                 for key in ('covered_lines', 'executable_lines', 'line_percent')}
                                 for name in ('integration/coverage/coverage.json',
                                              'combined-coverage/coverage.json')},
                             'vm': {key: load_json(evidence, 'vm-integration/vm-integration.json')[key]
                                    for key in ('passed_tests', 'total_tests', 'skipped_tests', 'skips')},
                             'hostedQualityReceiptSHA256': digest(evidence / 'github-quality/quality.json'),
                             'restored': True},
              'sourceReceiptSHA256': {name: digest(evidence / name) for name in parity_source_receipts}}
    admitted_hashes = qualification_receipt_hashes(evidence)
    for name, value in parity['sourceReceiptSHA256'].items():
        require(name in admitted_hashes and value == admitted_hashes[name] and SHA.fullmatch(value),
                'Performance projection refers to an unadmitted source receipt')
    payload = json_bytes(parity)
    manifest = json_bytes({'schema': 1, 'source': source,
                           'kind': 'container-performance-parity-manifest',
                           'signedArchiveSHA256': release['archives'][ASSETS[0]],
                           'measuredAssets': {name: release['archives'][name] for name in ASSETS[2:4]},
                           'nativeCompiledChainSHA256': hashlib.sha256(json_bytes(chain)).hexdigest(),
                           'historicalReference': reference_identity,
                           'members': {'benchmark.json': {'sha256': hashlib.sha256(payload).hexdigest(),
                                                          'bytes': len(payload)}}})
    with zipfile.ZipFile(output / parity_name, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in (('benchmark.json', payload), ('manifest.json', manifest)):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED)
    bundle['performance_parity_asset']['sha256'] = digest(output / parity_name)
    require(not PRIVATE.search(json_bytes(bundle).decode())
            and not PRIVATE.search(payload.decode()), 'Public release metadata contains private paths or credentials')
    q_assets.validate(bundle, provisional_locks, helper_digests, qualified_source=source)
    (output / ASSETS[1]).write_bytes(json_bytes(bundle))
    return {'files': [*ASSETS, parity_name], 'native_chain': chain,
            'native_chain_sha256': hashlib.sha256(json_bytes(chain)).hexdigest(),
            'source_receipt_sha256': source_receipts, 'qualified_helpers_sha256': helper_digests}


def rederive_assets(container_root: Path, evidence: Path, compose_root: Path, source: str,
                    records: dict[str, dict], chain: dict, *, scratch: Optional[Path] = None
                    ) -> tuple[dict[str, str], dict]:
    if scratch is not None:
        scratch.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix='q-runtime-release-recheck-', dir=scratch) as temporary:
        directory = Path(temporary)
        projections = create_products(container_root, evidence, directory, compose_root,
                                      source, records, chain)
        return ({path.name: digest(path) for path in sorted(directory.iterdir())}, projections)


def load_compose_module(name: str, path: Path):
    tools_root = path.parent if path.parent.name == 'bazel' else path.parents[1]
    if str(tools_root) not in sys.path:
        sys.path.insert(0, str(tools_root))
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, 'Unable to load Compose Q asset validator')
    require(Path(spec.origin).resolve() == path.resolve(), 'Compose validator path differs from requested root')
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    if path.name == 'q_assets.py':
        from artifacts import release_asset
        expected_transport = path.parent / 'artifacts/release_asset.py'
        require(Path(release_asset.__file__).resolve() == expected_transport.resolve(),
                'Q asset validator resolved a different release transport')
    return module


def write_json_new(path: Path, value: dict) -> None:
    with path.open('xb') as stream:
        stream.write(json_bytes(value))


def write_json_idempotent(path: Path, value: dict) -> None:
    encoded = json_bytes(value)
    if path.exists() or path.is_symlink():
        require(path.is_file() and not path.is_symlink() and path.read_bytes() == encoded,
                'Existing release receipt differs from the authenticated retry: ' + path.name)
        return
    temporary: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(mode='wb', dir=path.parent, prefix='.' + path.name + '.',
                                         delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), 0o600)
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        if path.exists() or path.is_symlink():
            require(path.is_file() and not path.is_symlink() and path.read_bytes() == encoded,
                    'Concurrent release receipt differs from the authenticated retry: ' + path.name)
            return
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def expected_release_lock(source: str, tag: str, name: str, sha256: str) -> dict:
    return {'schema': 1, 'repository': 'stephenlclarke/container', 'tag': tag,
            'targetCommit': source, 'asset': name, 'sha256': sha256}


def validate_publication(publication: dict, receipt: dict, source: str) -> None:
    names = receipt['projections']['files']
    require(publication.get('schema') == 1
            and publication.get('repository') == 'stephenlclarke/container'
            and publication.get('tag') == receipt['tag']
            and publication.get('targetCommit') == source
            and type(publication.get('releaseId')) is int and publication['releaseId'] > 0
            and isinstance(publication.get('assets'), dict)
            and set(publication['assets']) == set(names),
            'Publication repository, tag, source, or asset inventory differs from preparation')
    for name in names:
        row = publication['assets'][name]
        require(isinstance(row, dict) and row.get('sha256') == receipt['assets'].get(name)
                and type(row.get('assetId')) is int and row['assetId'] > 0,
                'Publication asset identity differs from prepared bytes: ' + name)


def enrolled_ssd_scratch(path: Path) -> Path:
    volume = Path('/Volumes/SSD')
    root = volume / 'cf/bazel'
    enrollment = (Path.home() / 'Library/Application Support/ContainerFamily/retained/'
                  'workflow/ssd-volume.uuid')
    require(os.uname().sysname == 'Darwin' and os.uname().machine == 'arm64'
            and enrollment.is_file() and not enrollment.is_symlink(),
            'Release scratch requires the enrolled Apple silicon SSD')
    expected_uuid = enrollment.read_text().strip()
    require(re.fullmatch(r'[A-Fa-f0-9-]{36}', expected_uuid) is not None,
            'Enrolled SSD identity is malformed')
    plist = subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', str(volume)])
    identity = plistlib.loads(plist)
    require((identity.get('VolumeUUID'), identity.get('MountPoint'), identity.get('Internal'))
            == (expected_uuid, str(volume), False),
            'Enrolled external SSD identity or mount does not match')
    require(path.is_absolute() and '..' not in path.parts
            and path != root and path.is_relative_to(root),
            'Release scratch must be below enrolled SSD Bazel storage')
    current = Path('/')
    for part in path.parts[1:]:
        current /= part
        require(not current.is_symlink(), 'Release scratch path contains a symlink')
        if not current.exists():
            current.mkdir()
        require(current.is_dir(), 'Release scratch path contains a non-directory')
    resolved = path.resolve(strict=True)
    require(resolved == path and resolved.stat().st_dev == volume.stat().st_dev,
            'Release scratch is not on the enrolled SSD volume')
    return resolved


def verify_performance_archive(path: Path, source: str, chain: dict,
                              bundle: dict, expected_receipts: dict) -> dict:
    parity_name = 'container-performance-parity-' + source[:8] + '.zip'
    with zipfile.ZipFile(path) as archive:
        require(archive.namelist() == ['benchmark.json', 'manifest.json'],
                'Performance archive has an unexpected member inventory')
        benchmark_bytes = archive.read('benchmark.json')
        manifest = json.loads(archive.read('manifest.json'))
    benchmark = json.loads(benchmark_bytes)
    chain_sha = hashlib.sha256(json_bytes(chain)).hexdigest()
    require(manifest == {'schema': 1, 'source': source,
                         'kind': 'container-performance-parity-manifest',
                         'signedArchiveSHA256': bundle['assets']['runtime']['sha256'],
                         'measuredAssets': bundle['measured_assets'],
                         'nativeCompiledChainSHA256': chain_sha,
                         'historicalReference': benchmark['historicalReference'],
                         'members': {'benchmark.json': {'sha256': hashlib.sha256(benchmark_bytes).hexdigest(),
                                                        'bytes': len(benchmark_bytes)}}},
            'Performance archive manifest or release crosslinks differ')
    require(benchmark.get('source') == source
            and benchmark.get('native_compiled_chain') == chain
            and benchmark.get('native_compiled_chain_sha256') == chain_sha
            and benchmark.get('signedArchiveSHA256') == bundle['assets']['runtime']['sha256']
            and benchmark.get('measuredExecutableAssets') == bundle['measured_assets']
            and bundle['performance_parity_asset'] == {'name': parity_name, 'sha256': digest(path)},
            'Performance measurements or native/release links differ')
    perf_receipts = benchmark.get('sourceReceiptSHA256', {})
    require(bool(perf_receipts) and perf_receipts ==
            {name: expected_receipts[name] for name in perf_receipts if name in expected_receipts},
            'Performance receipt hashes differ from the prepared qualification evidence')
    require(not PRIVATE.search(benchmark_bytes.decode()), 'Performance archive contains private paths or credentials')
    return benchmark


def prepare(container_root: Path, qualification_dir: Path, compose_root: Path, output: Path,
            *, scratch: Optional[Path] = None) -> dict:
    source, records = validate_core(container_root, qualification_dir)
    if not output.is_absolute() or output.exists() or output.is_symlink():
        raise ValueError('Preparation output must be a fresh absolute directory')
    chain, lock_records = native_chain(container_root, qualification_dir, source)
    input_hashes = qualification_receipt_hashes(qualification_dir)
    output.mkdir(mode=0o700, parents=True)
    assets_dir = output / 'assets'
    assets_dir.mkdir(mode=0o700)
    projections = create_products(container_root, qualification_dir, assets_dir, compose_root,
                                  source, records, chain)
    # Bind exact inputs and the maintained producer/transport source. These
    # private paths stay in this review receipt, not the published sidecar.
    require(source_checkpoint(container_root) == source
            and qualification_receipt_hashes(qualification_dir) == input_hashes,
            'Container source or qualification evidence changed during preparation')
    receipt = {'schema': 1, 'source': source, 'prepared': True, 'published': False,
               'tag': 'layer-runtime-' + source[:12] + '-' + digest(assets_dir / ASSETS[0])[:12],
               'assets': {path.name: digest(path) for path in sorted(assets_dir.iterdir())},
               'source_receipts': input_hashes,
               'native_locks': lock_records, 'projections': projections,
               'producer_sha256': digest(Path(__file__)),
               'validator_sha256': digest(compose_root / 'Tools/bazel/q_assets.py'),
               'transport_sha256': digest(compose_root / 'Tools/bazel/artifacts/release_asset.py'),
               'authority': {'releaseAuthority': False}}
    write_json_new(output / 'preparation.json', receipt)
    return receipt


def require_derived_tag(receipt: dict, source: str, assets_dir: Path) -> None:
    runtime = assets_dir / ASSETS[0]
    expected = 'layer-runtime-' + source[:12] + '-' + digest(runtime)[:12]
    require(receipt.get('tag') == expected, 'Prepared runtime release tag differs from its qualified archive')


def publish(compose_root: Path, container_root: Path, qualification_dir: Path,
            output: Path, *, scratch: Optional[Path] = None) -> dict:
    source, records = validate_core(container_root, qualification_dir)
    receipt = json.loads((output / 'preparation.json').read_text())
    require(receipt.get('source') == source and receipt.get('prepared') is True
            and receipt.get('published') is False
            and receipt.get('producer_sha256') == digest(Path(__file__))
            and receipt.get('validator_sha256') == digest(compose_root / 'Tools/bazel/q_assets.py')
            and receipt.get('transport_sha256') == digest(compose_root / 'Tools/bazel/artifacts/release_asset.py'),
            'Prepared runtime candidate or maintained recipe changed')
    observed = {path.name: digest(path) for path in sorted((output / 'assets').iterdir())
                if path.is_file() and not path.is_symlink()}
    require(observed == receipt.get('assets'), 'Prepared runtime release assets changed')
    require_derived_tag(receipt, source, output / 'assets')
    require(receipt.get('source_receipts') == qualification_receipt_hashes(qualification_dir),
            'Qualification evidence changed after preparation')
    chain, current_native_locks = native_chain(container_root, qualification_dir, source)
    require(receipt.get('native_locks') == current_native_locks
            and receipt.get('projections', {}).get('native_chain') == chain,
            'Prepared native graph, lower locks, or verified compiled chain changed')
    regenerated_assets, regenerated_projections = rederive_assets(
        container_root, qualification_dir, compose_root, source, records, chain, scratch=scratch)
    require(receipt.get('assets') == regenerated_assets
            and receipt.get('projections') == regenerated_projections,
            'Prepared release bytes or public measurements do not match qualified evidence')
    q_assets = load_compose_module('compose_q_assets', compose_root / 'Tools/bazel/q_assets.py')
    bundle = json.loads((output / 'assets' / ASSETS[1]).read_text())
    lower_locks_dir = container_root / 'Tools/bazel/artifacts/lower-locks'
    locks = {'runtime': {'sha256': digest(output / 'assets' / ASSETS[0])}}
    for name in ('guest', 'builder'):
        locks[name] = json.loads((lower_locks_dir / (name + '.lock.json')).read_text())
    helpers = helper_hashes(container_root)
    q_assets.validate(bundle, locks, helpers, qualified_source=source)
    transport = load_compose_module('compose_release_asset',
                                    compose_root / 'Tools/bazel/artifacts/release_asset.py')
    for group, triple in current_native_locks.items():
        expected = chain['layers'][group]
        for kind, lock in triple.items():
            remote_release, remote_asset = transport.release_asset(lock)
            expected_asset = expected['assets'][kind]
            require(remote_release.get('id') == expected['releaseId']
                    and remote_asset.get('id') == expected_asset['assetId']
                    and lock.get('sha256') == expected_asset['sha256'],
                    'Published native lower-layer release identity changed: ' + group + '/' + kind)
    for name in ('guest', 'builder'):
        transport.release_asset(locks[name])
    require(source_checkpoint(container_root) == source, 'Container source changed before publication')
    require(scratch is not None, 'Resumable publication requires explicit enrolled SSD scratch')
    owner = 'q-runtime-release-' + source + '-' + receipt['tag']
    result = transport.publish_assets('stephenlclarke/container', receipt['tag'], source,
        'Qualified Container runtime ' + source[:12],
        'Qualified signed runtime with exact measured executables and qualified provenance. '
        'Guest and builder releases are reused unchanged.',
        tuple(output / 'assets' / name for name in receipt['projections']['files']),
        resume=True, scratch=scratch, owner=owner, journal_root=output)
    validate_publication(result, receipt, source)
    expected_journal = transport.publication_journal_path(
        output, 'stephenlclarke/container', receipt['tag'], owner)
    require(result.get('publicationJournal') == str(expected_journal),
            'Resumable publisher journal identity differs from its stable owner')
    write_json_idempotent(output / 'publication.json', result)
    for name in receipt['projections']['files']:
        lock = expected_release_lock(source, receipt['tag'], name, receipt['assets'][name])
        write_json_idempotent(output / (name + '.lock.json'), lock)
    return result


def verify(compose_root: Path, container_root: Path, qualification_dir: Path,
           output: Path, *, scratch: Optional[Path] = None) -> dict:
    receipt = json.loads((output / 'preparation.json').read_text())
    publication = json.loads((output / 'publication.json').read_text())
    source, records = validate_core(container_root, qualification_dir)
    require(COMMIT.fullmatch(source or '') and receipt.get('prepared') is True
            and receipt.get('published') is False and receipt.get('source') == source,
            'Publication receipt is incomplete')
    require_derived_tag(receipt, source, output / 'assets')
    validate_publication(publication, receipt, source)
    files = receipt['projections']['files']
    require(files and files[1] == ASSETS[1],
            'Verification output exists or prepared asset inventory differs')
    expected_receipts = receipt.get('source_receipts', {})
    require(expected_receipts == qualification_receipt_hashes(qualification_dir),
            'Qualification evidence changed since preparation')
    chain, native_locks = native_chain(container_root, qualification_dir, source)
    require(receipt.get('native_locks') == native_locks
            and receipt.get('projections', {}).get('native_chain') == chain,
            'Published candidate no longer matches its qualified native source graph')
    regenerated_assets, regenerated_projections = rederive_assets(
        container_root, qualification_dir, compose_root, source, records, chain, scratch=scratch)
    require(receipt.get('assets') == regenerated_assets
            and receipt.get('projections') == regenerated_projections,
            'Published measurements do not match retained qualification evidence')
    transport = load_compose_module('compose_release_asset_verify',
                                    compose_root / 'Tools/bazel/artifacts/release_asset.py')
    require(scratch is not None, 'Download verification requires explicit enrolled SSD scratch')
    owner = 'q-runtime-release-' + source + '-' + receipt['tag']
    expected_journal = transport.publication_journal_path(
        output, 'stephenlclarke/container', receipt['tag'], owner)
    require(publication.get('publicationJournal') == str(expected_journal)
            and expected_journal.is_file() and not expected_journal.is_symlink(),
            'Resumable publisher journal is missing or belongs to another release')
    downloaded = output / 'downloaded'
    require(not downloaded.is_symlink()
            and (not downloaded.exists() or downloaded.is_dir()),
            'Download verification path must be a real directory')
    downloaded.mkdir(mode=0o700, exist_ok=True)
    results = {}
    for name in files:
        lock_path = output / (name + '.lock.json')
        lock = json.loads(lock_path.read_text())
        require(lock == expected_release_lock(source, receipt['tag'], name, receipt['assets'][name]),
                'Published asset lock differs from deterministic prepared identity: ' + name)
        destination = downloaded / name
        asset_path = destination / name
        fetch_receipt_path = destination / 'fetch-receipt.json'
        lock_sha = hashlib.sha256(lock_path.read_bytes()).hexdigest()

        def admitted_fetch(path: Path, receipt_path: Path) -> Optional[dict]:
            if (not path.is_file() or path.is_symlink() or not receipt_path.is_file()
                    or receipt_path.is_symlink()):
                return None
            try:
                fetched = json.loads(receipt_path.read_text())
            except (OSError, ValueError):
                return None
            expected = {'schema': 1, 'repository': lock['repository'], 'tag': lock['tag'],
                        'targetCommit': lock['targetCommit'], 'releaseId': publication['releaseId'],
                        'assetId': publication['assets'][name]['assetId'], 'asset': str(path),
                        'sha256': lock['sha256'], 'lockSHA256': lock_sha}
            if not isinstance(fetched, dict) or fetched.get('githubImmutable') not in (True, False, None):
                return None
            expected['githubImmutable'] = fetched.get('githubImmutable')
            if fetched != expected or digest(path) != lock['sha256']:
                return None
            return {'releaseId': publication['releaseId'],
                    'assetId': publication['assets'][name]['assetId'], 'sha256': lock['sha256']}

        result = (admitted_fetch(asset_path, fetch_receipt_path)
                  if destination.is_dir() and not destination.is_symlink() else None)
        if result is None:
            # A prior interrupted or unreceipted download is never trusted. Fetch
            # into fresh enrolled SSD scratch first, then copy its verified bytes
            # and exact identity receipt into retained storage before atomic promotion.
            require(scratch.is_dir() and not scratch.is_symlink(),
                    'Download verification scratch must be an enrolled real directory')
            with tempfile.TemporaryDirectory(prefix='q-runtime-fetch-', dir=scratch) as temporary:
                staged = Path(temporary) / 'asset'
                fetched_result = transport.fetch(lock_path, staged)
                staged_asset = staged / name
                staged_receipt_path = staged / 'fetch-receipt.json'
                require(isinstance(fetched_result, dict)
                        and fetched_result.get('releaseId') == publication['releaseId']
                        and fetched_result.get('assetId') == publication['assets'][name]['assetId']
                        and staged.is_dir() and not staged.is_symlink()
                        and {entry.name for entry in staged.iterdir()} == {name, 'fetch-receipt.json'}
                        and staged_asset.is_file() and not staged_asset.is_symlink()
                        and digest(staged_asset) == lock['sha256']
                        and staged_receipt_path.is_file() and not staged_receipt_path.is_symlink(),
                        'Freshly fetched release asset has no exact authenticated receipt: ' + name)
                staged_receipt = json.loads(staged_receipt_path.read_text())
                expected_staged = {'schema': 1, 'repository': lock['repository'], 'tag': lock['tag'],
                    'targetCommit': lock['targetCommit'], 'releaseId': publication['releaseId'],
                    'assetId': publication['assets'][name]['assetId'], 'asset': str(staged_asset),
                    'sha256': lock['sha256'], 'lockSHA256': lock_sha}
                require(isinstance(staged_receipt, dict)
                        and staged_receipt.get('githubImmutable') in (True, False, None),
                        'Freshly fetched release receipt is malformed: ' + name)
                expected_staged['githubImmutable'] = staged_receipt.get('githubImmutable')
                require(staged_receipt == expected_staged,
                        'Freshly fetched release receipt differs from its lock and publication: ' + name)
                promoted = Path(tempfile.mkdtemp(prefix='.q-runtime-promote-', dir=downloaded))
                try:
                    shutil.copyfile(staged_asset, promoted / name)
                    retained_receipt = dict(staged_receipt, asset=str(destination / name))
                    (promoted / 'fetch-receipt.json').write_bytes(json_bytes(retained_receipt))
                    require(digest(promoted / name) == lock['sha256'],
                            'Promoted release asset differs from authenticated download: ' + name)
                    if destination.exists() or destination.is_symlink():
                        require(destination.is_dir() and not destination.is_symlink()
                                and {entry.name for entry in destination.iterdir()}
                                <= {name, 'fetch-receipt.json'},
                                'Incomplete download contains unowned files: ' + name)
                        shutil.rmtree(destination)
                    os.replace(promoted, destination)
                finally:
                    if promoted.exists():
                        shutil.rmtree(promoted)
            result = admitted_fetch(asset_path, fetch_receipt_path)
            require(result is not None, 'Promoted release download receipt failed admission: ' + name)
        require(result.get('releaseId') == publication['releaseId']
                and result.get('assetId') == publication['assets'][name]['assetId'],
                'Downloaded asset differs from published release identity: ' + name)
        path = downloaded / name / name
        require(path.is_file() and not path.is_symlink() and digest(path) == lock['sha256']
                and receipt['assets'][name] == lock['sha256'],
                'Downloaded runtime asset differs from prepared bytes: ' + name)
        results[name] = {'releaseId': publication['releaseId'],
                         'assetId': publication['assets'][name]['assetId'],
                         'sha256': lock['sha256']}
    bundle = json.loads((downloaded / ASSETS[1] / ASSETS[1]).read_text())
    q_assets = load_compose_module('compose_q_assets_verify',
                                   compose_root / 'Tools/bazel/q_assets.py')
    lower_locks = container_root / 'Tools/bazel/artifacts/lower-locks'
    locks = {'runtime': json.loads((output / (ASSETS[0] + '.lock.json')).read_text())}
    for name in ('guest', 'builder'):
        locks[name] = json.loads((lower_locks / (name + '.lock.json')).read_text())
    q_assets.validate(bundle, locks, helper_hashes(container_root), qualified_source=source)
    chain = receipt['projections']['native_chain']
    parity_name = 'container-performance-parity-' + source[:8] + '.zip'
    verify_performance_archive(downloaded / parity_name / parity_name, source, chain, bundle,
                               expected_receipts)
    result = {'schema': 1, 'passed': True, 'source': source, 'releaseId': publication['releaseId'],
              'assets': results, 'provenanceSHA256': digest(downloaded / ASSETS[1] / ASSETS[1])}
    write_json_idempotent(output / 'download-verification.json', result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'publish', 'verify'))
    parser.add_argument('--container-root', required=True, type=Path)
    parser.add_argument('--qualification-dir', required=True, type=Path)
    parser.add_argument('--root', required=True, type=Path, help='Compose checkout root')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--scratch', type=Path, default=Path('/Volumes/SSD/cf/bazel/tmp'),
                        help='Enrolled SSD scratch directory for temporary release work')
    args = parser.parse_args()
    scratch = enrolled_ssd_scratch(args.scratch)
    if args.action == 'prepare':
        result = prepare(args.container_root, args.qualification_dir, args.root, args.output, scratch=scratch)
    elif args.action == 'publish':
        result = publish(args.root, args.container_root, args.qualification_dir, args.output, scratch=scratch)
    else:
        result = verify(args.root, args.container_root, args.qualification_dir, args.output, scratch=scratch)
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
