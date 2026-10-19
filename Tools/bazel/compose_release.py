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

"""Prepare and verify a signed Compose product release from completed evidence."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

import benchmark_evidence
from artifacts.release_asset import fetch, publish_assets, read_lock

REPOSITORY = 'stephenlclarke/container-compose'
ARCHIVE_NAME = 'container-compose-signed-arm64.zip'
PROVENANCE_NAME = 'qualified-compose-release.json'
EVIDENCE_NAME = 'compose-qualified-evidence-v1.zip'
LOCK_DIRECTORY = Path(__file__).resolve().parent / 'artifacts'
SHA = re.compile(r'[0-9a-f]{64}\Z')
COMMIT = re.compile(r'[0-9a-f]{40}\Z')
PHASES = ('full_suite', 'projects', 'runtime', 'plugin', 'private_install',
          'colima', 'stock', 'install', 'host')
EXECUTABLES = ('bin/compose', 'resources/compose-normalizer',
               'resources/volume-initializer/compose-volume-initializer-linux-arm64',
               'resources/volume-initializer/compose-volume-initializer-linux-amd64')
PORTABLE_BENCHMARK = 'portable-benchmark.json'
BENCHMARK_LOCK = LOCK_DIRECTORY / 'benchmark-reference.lock.json'
PRIVATE_TEXT = re.compile(r'file://|/(?:Users|Volumes|private|tmp|home|var)/|'
                          r'\b(?:ghp_|github_pat_|Bearer )[A-Za-z0-9_\-]+', re.IGNORECASE)
PRIVATE_KEY = re.compile(r'(?:^|_)(?:path|log|secret|token|password|credential|'
                         r'authorization)(?:$|_)', re.IGNORECASE)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def read(path: Path) -> dict:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise RuntimeError('Release evidence is not an object: ' + str(path))
    return value


def write(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def canonical_json(value: dict) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n').encode()


def baseline_link(benchmark: dict) -> dict:
    reference = benchmark['reference']
    return {'referenceSHA256': hashlib.sha256(canonical_json(reference)).hexdigest(),
            'repository': reference['repository'], 'tag': reference['tag'],
            'releaseId': reference['releaseId'], 'assetId': reference['assetId'],
            'assetSHA256': reference['assetSHA256'],
            'binarySHA256': reference['referenceBinary']['sha256'],
            'capturedAt': reference['capture']['capturedAt']}


def require_portable(value: object, location: str = 'evidence') -> None:
    """Reject local paths and credentials before putting evidence on a public release."""
    if isinstance(value, dict):
        for key, item in value.items():
            if (not isinstance(key, str) or
                    (PRIVATE_KEY.search(key) and not key.lower().endswith('sha256'))):
                raise RuntimeError('Public release evidence contains a private key at ' + location)
            require_portable(item, location + '.' + key)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            require_portable(item, location + '[' + str(index) + ']')
    elif isinstance(value, str):
        if (PRIVATE_TEXT.search(value) or '\x00' in value or len(value) > 4096):
            raise RuntimeError('Public release evidence contains a local path or secret at ' + location)
    elif isinstance(value, float) and not math.isfinite(value):
        raise RuntimeError('Public release evidence contains a non-finite value at ' + location)
    elif value is not None and not isinstance(value, (int, float, bool)):
        raise RuntimeError('Public release evidence contains an unsupported value at ' + location)


def evidence_members(evidence: Path, provenance: dict) -> dict[str, dict]:
    benchmark = read(evidence / PORTABLE_BENCHMARK)
    live = read(evidence / 'live.json')
    full = read(evidence / 'full-suite/acceptance.json')
    reference_receipt = read(evidence / 'benchmark-reference.json')
    lock = read_lock(BENCHMARK_LOCK)
    reference_path = Path(reference_receipt.get('asset', ''))
    if (not reference_path.is_file() or reference_path.is_symlink()
            or digest(reference_path) != lock['sha256']
            or reference_receipt.get('lock_sha256') != digest(BENCHMARK_LOCK)
            or reference_receipt.get('asset_sha256') != lock['sha256']):
        raise RuntimeError('Published benchmark reference changed after acceptance')
    reference = read(reference_path)
    if (set(benchmark) != {'schema', 'source', 'signedArchiveSHA256', 'passed', 'workload',
                           'workloadSHA256', 'environment', 'candidateBinarySHA256',
                           'historicalReference', 'reference', 'candidateSamples',
                           'referenceSamples', 'measurements', 'candidateCapture'}
            or set(benchmark.get('reference', {})) != {
                'repository', 'tag', 'targetCommit', 'releaseId', 'assetId', 'assetSHA256',
                'referenceBinary', 'capture'}):
        raise RuntimeError('Portable benchmark has unsupported public fields')
    image = benchmark.get('workload', {}).get('image')
    if not isinstance(image, str) or benchmark['workload'] != benchmark_evidence.workload(image):
        raise RuntimeError('Portable benchmark workload differs from reviewed fixture')
    try:
        validated_reference_samples = benchmark_evidence.validate_reference(
            reference, benchmark['workload'], benchmark.get('environment'))
        validated_candidate_samples = benchmark_evidence.checked_samples(
            benchmark.get('candidateSamples', []), 'candidate')
        validated_warmups = benchmark_evidence.checked_samples(
            live.get('benchmark_candidate_warmups', []), 'candidate', trial=0)
    except (TypeError, ValueError) as error:
        raise RuntimeError('Portable benchmark reference or samples are invalid') from error
    capture = benchmark.get('candidateCapture')
    if not isinstance(capture, dict) or set(capture) != {
            'capturedAt', 'hostBeforeSHA256', 'hostAfterSHA256',
            'hostBefore', 'hostAfter', 'warmups'}:
        raise RuntimeError('Portable candidate capture is incomplete')
    try:
        timestamp = datetime.fromisoformat(capture['capturedAt'].replace('Z', '+00:00'))
    except (AttributeError, ValueError):
        timestamp = None
    try:
        observed_before = benchmark_evidence.host_projection(read(
            evidence / 'runtime/benchmark-host-before.json'))
        observed_after = benchmark_evidence.host_projection(read(
            evidence / 'runtime/benchmark-host-after.json'))
    except ValueError as error:
        raise RuntimeError('Portable candidate host snapshots are invalid') from error
    if (timestamp is None or timestamp.tzinfo != timezone.utc
            or capture['hostBeforeSHA256'] != digest(
                evidence / 'runtime/benchmark-host-before.json')
            or capture['hostAfterSHA256'] != digest(
                evidence / 'runtime/benchmark-host-after.json')
            or capture['hostBefore'] != observed_before
            or capture['hostAfter'] != observed_after
            or capture['warmups'] != validated_warmups):
        raise RuntimeError('Portable candidate capture differs from accepted live evidence')
    if (benchmark.get('schema') != 1 or benchmark.get('source') != provenance['source']
            or benchmark.get('signedArchiveSHA256') != provenance['signedArchiveSHA256']
            or benchmark.get('candidateBinarySHA256') != provenance['signedPayload']['bin/compose']
            or benchmark.get('historicalReference') is not True
            or not isinstance(benchmark.get('workload'), dict)
            or not isinstance(benchmark.get('reference'), dict)
            or benchmark['reference'].get('repository') != lock['repository']
            or benchmark['reference'].get('tag') != lock['tag']
            or benchmark['reference'].get('targetCommit') != lock['targetCommit']
            or benchmark['reference'].get('assetSHA256') != lock['sha256']
            or benchmark['reference'].get('releaseId') != reference_receipt.get('release_id')
            or benchmark['reference'].get('assetId') != reference_receipt.get('asset_id')
            or benchmark['reference'].get('referenceBinary') != reference.get('referenceBinary')
            or benchmark['reference'].get('capture') != reference.get('capture')
            or benchmark.get('referenceSamples') != validated_reference_samples
            or benchmark.get('candidateSamples') != validated_candidate_samples
            or benchmark.get('workload') != reference.get('workload')
            or benchmark.get('workloadSHA256') != reference.get('workloadSHA256')
            or benchmark.get('environment') != reference.get('environment')
            or benchmark.get('passed') is not True):
        raise RuntimeError('Portable benchmark does not bind accepted signed Compose product')
    expected = set(live['benchmarks'])
    if set(benchmark.get('measurements', {})) != expected:
        raise RuntimeError('Portable benchmark omits an accepted workload')
    for name in expected:
        source = live['benchmarks'][name]
        portable = benchmark['measurements'][name]
        if portable != source:
            raise RuntimeError('Portable benchmark raw trials differ: ' + name)
    for lane, key in (('candidate', 'candidateSamples'), ('docker', 'referenceSamples')):
        samples = benchmark.get(key)
        if not isinstance(samples, list) or len(samples) != 28:
            raise RuntimeError('Portable timing samples are incomplete: ' + lane)
        for name in expected:
            selected = [row for row in samples if isinstance(row, dict)
                        and row.get('fixture') == name]
            if (len(selected) != 7 or
                    {row.get('trial') for row in selected} != set(range(1, 8)) or
                    any(type(row.get('trial')) is not int or row.get('lane') != lane or
                        row.get('status') != 0 or
                        not SHA.fullmatch(row.get('log_sha256', '')) or
                        row.get('seconds') != live['benchmarks'][name]['lanes'][lane][
                            'raw_seconds'][row['trial'] - 1] for row in selected)):
                raise RuntimeError('Portable timing samples changed: ' + name + '/' + lane)
    cases = []
    for row in full['rows']:
        name = row.get('fixture')
        if (not isinstance(name, str) or not re.fullmatch(r'[a-z0-9-]+', name)
                or row.get('status') != 0
                or not isinstance(row.get('seconds'), (int, float))
                or isinstance(row['seconds'], bool) or not math.isfinite(row['seconds'])
                or row['seconds'] <= 0):
            raise RuntimeError('Original parity case lacks a successful timed result')
        case = read(evidence / 'full-suite' / (name + '.json'))
        log = Path(case.get('log', ''))
        if (not log.is_relative_to(evidence) or '..' in log.parts or log.is_symlink()
                or not log.is_file()
                or case.get('name') != name or case.get('status') != 0
                or not SHA.fullmatch(case.get('source_sha256', ''))
                or not SHA.fullmatch(case.get('log_sha256', ''))
                or digest(log) != case['log_sha256']):
            raise RuntimeError('Original parity case evidence changed: ' + name)
        cases.append({'name': name, 'status': 0, 'seconds': row['seconds'],
                      'sourceSHA256': case['source_sha256'],
                      'assertionOutputSHA256': case['log_sha256']})
    parity = {'schema': 1, 'kind': 'original-compose-parity-summary',
              'source': provenance['source'], 'runtimeTests': full['runtime_tests'],
              'parityCases': full['parity_cases'], 'cases': cases,
              'observationReuse': False}
    members = {'benchmark.json': benchmark, 'parity-summary.json': parity}
    for name, value in members.items():
        require_portable(value, name)
    return members


def seal_evidence(path: Path, members: dict[str, dict], provenance: dict) -> dict:
    files = {name: canonical_json(value) for name, value in sorted(members.items())}
    manifest = {'schema': 1, 'kind': 'compose-qualified-evidence',
                'source': provenance['source'],
                'signedArchiveSHA256': provenance['signedArchiveSHA256'],
                'files': {name: {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
                          for name, data in files.items()}}
    files['manifest.json'] = canonical_json(manifest)
    with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(files.items()):
            member = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            member.external_attr = 0o100644 << 16
            archive.writestr(member, data)
    return manifest


def inspect_evidence(path: Path, provenance: dict) -> dict:
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        names = [item.filename for item in infos]
        if (len(names) != len(set(names)) or
                set(names) != {'manifest.json', 'benchmark.json', 'parity-summary.json'}):
            raise RuntimeError('Portable release evidence has unsafe or unexpected members')
        if (any(item.flag_bits & 1 or item.file_size > 2_000_000 or
                ((item.external_attr >> 16) & 0o170000) == 0o120000
                for item in infos) or sum(item.file_size for item in infos) > 5_000_000):
            raise RuntimeError('Portable release evidence has unsafe members or size')
        def decoded(name: str) -> dict:
            value = json.loads(archive.read(name), parse_constant=lambda _: (_ for _ in ()).throw(
                RuntimeError('Portable release evidence has a non-finite number')))
            if not isinstance(value, dict):
                raise RuntimeError('Portable release evidence member is not an object: ' + name)
            return value
        manifest = decoded('manifest.json')
        if (manifest.get('schema') != 1 or manifest.get('kind') != 'compose-qualified-evidence'
                or manifest.get('source') != provenance['source']
                or manifest.get('signedArchiveSHA256') != provenance['signedArchiveSHA256']
                or set(manifest.get('files', {})) != set(names) - {'manifest.json'}):
            raise RuntimeError('Portable release evidence manifest changed')
        for name, record in manifest['files'].items():
            content = archive.read(name)
            if (record != {'sha256': hashlib.sha256(content).hexdigest(),
                           'bytes': len(content)}):
                raise RuntimeError('Portable release evidence member changed: ' + name)
            require_portable(decoded(name), name)
        benchmark = decoded('benchmark.json')
        parity = decoded('parity-summary.json')
        cases = parity.get('cases', [])
        if (benchmark.get('schema') != 1 or benchmark.get('source') != provenance['source']
                or benchmark.get('signedArchiveSHA256') != provenance['signedArchiveSHA256']
                or benchmark.get('candidateBinarySHA256') != provenance['signedPayload']['bin/compose']
                or benchmark.get('historicalReference') is not True
                or benchmark.get('passed') is not True
                or not isinstance(benchmark.get('reference'), dict)
                or (provenance.get('evidenceCompanion') is not None and
                    provenance['evidenceCompanion'].get('benchmarkBaseline') !=
                    baseline_link(benchmark))
                or set(benchmark.get('measurements', {})) != {
                    '1-services-up', '1-services-down', '3-services-up', '3-services-down'}
                or parity.get('schema') != 1 or parity.get('source') != provenance['source']
                or parity.get('runtimeTests') != 27 or parity.get('parityCases') != 66
                or parity.get('observationReuse') is not False
                or not isinstance(cases, list) or len(cases) != 67
                or any(not isinstance(case, dict) for case in cases)
                or len({case.get('name') for case in cases}) != 67
                or any(not isinstance(case.get('name'), str) or
                       not re.fullmatch(r'[a-z0-9-]+', case['name']) or
                       case.get('status') != 0 or
                       not isinstance(case.get('seconds'), (int, float)) or
                       isinstance(case['seconds'], bool) or case['seconds'] <= 0 or
                       not SHA.fullmatch(case.get('sourceSHA256', '')) or
                       not SHA.fullmatch(case.get('assertionOutputSHA256', ''))
                       for case in cases)):
            raise RuntimeError('Portable release evidence does not bind qualified product')
    return manifest


def archive_tree(archive: Path) -> dict[str, str]:
    result = {}
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            relative = Path(member.filename)
            if (relative.is_absolute() or '..' in relative.parts or
                    not relative.parts or relative.parts[0] != 'compose'):
                raise RuntimeError('Signed Compose archive has an unsafe entry')
            mode = (member.external_attr >> 16) & 0o170000
            if mode == 0o120000:
                raise RuntimeError('Signed Compose archive contains a symbolic link')
            if member.is_dir():
                continue
            # ditto stores macOS file metadata as AppleDouble siblings. The
            # complete ZIP SHA binds those bytes; only payload files belong in
            # the signed installation tree measured before notarization.
            if relative.name.startswith('._'):
                continue
            name = relative.relative_to('compose').as_posix()
            if name in result:
                raise RuntimeError('Signed Compose archive has duplicate files')
            result[name] = hashlib.sha256(source.read(member)).hexdigest()
    return result


def admit(evidence: Path) -> dict:
    acceptance = read(evidence / 'acceptance.json')
    source = acceptance.get('source')
    if (acceptance.get('schema') != 1 or acceptance.get('target') != 'compose-only-qualify'
            or acceptance.get('passed') is not True or acceptance.get('failures')
            or not COMMIT.fullmatch(source or '')):
        raise RuntimeError('Compose qualification has not passed at one exact source')
    stages = acceptance.get('stages')
    required = {'source-preflight', 'workflow-tools', 'original-parity-fixtures',
                'runtime-tests-build', 'unit-stock', 'unit-enhanced',
                'coverage-stock', 'coverage-enhanced', 'package-tests', 'package-smoke',
                'docs', 'package', 'compiled-sdk-chain'}
    if (not isinstance(stages, list) or
            not required.issubset({row.get('name') for row in stages}) or
            any(row.get('status') != 0 for row in stages)):
        raise RuntimeError('Compose source/build/unit/coverage/package stages are incomplete')
    receipts = {name: evidence / path for name, path in {
        'acceptance': 'acceptance.json', 'preflight': 'preflight.json',
        'hosted_quality': 'hosted-quality/quality.json',
        'q_assets': 'q-assets/q-assets.json',
        'compiled_sdk_chain': 'compiled-sdk-chain.json',
        'benchmark_reference': 'benchmark-reference.json',
        'portable_benchmark': 'portable-benchmark.json',
        'unsigned_candidate': 'candidate-unsigned.json',
        'signed_candidate': 'signed-candidate.json',
        'full_suite': 'full-suite/acceptance.json',
        'full_suite_clearance': 'full-suite-cleared.json',
        'live': 'live.json', 'cleanup': 'cleanup-phases.json',
        'notarization': 'notarization.json',
    }.items()}
    values = {name: read(path) for name, path in receipts.items()}
    for name, claim in (('preflight', acceptance.get('preflight_sha256')),
                        ('hosted_quality', acceptance.get('hosted_quality_sha256')),
                        ('q_assets', acceptance.get('released_q_assets_sha256')),
                        ('compiled_sdk_chain', acceptance.get('compiled_sdk_chain_sha256')),
                        ('benchmark_reference', acceptance.get('benchmark_reference_sha256')),
                        ('portable_benchmark', acceptance.get('portable_benchmark_sha256')),
                        ('live', acceptance.get('live_sha256')),
                        ('notarization', acceptance.get('notarization_sha256'))):
        if digest(receipts[name]) != claim:
            raise RuntimeError('Accepted Compose receipt changed: ' + name)
    hosted = values['hosted_quality']
    if hosted.get('passed') is not True or hosted.get('source') != source:
        raise RuntimeError('Exact-source hosted quality is not accepted')
    if values['preflight'].get('ready') is not True:
        raise RuntimeError('Local preflight was not accepted')
    unsigned = values['unsigned_candidate']['receipt']
    signed = values['signed_candidate']
    if (unsigned.get('kind') != 'unsigned-native-candidate'
            or unsigned.get('commit') != source or unsigned.get('runtimeProfile') != 'enhanced'
            or unsigned.get('distributionReady') is not False
            or unsigned.get('licenseClosureComplete') is not False
            or not SHA.fullmatch(unsigned.get('dependencyNoticesSHA256', ''))
            or unsigned.get('goNoticeModules', 0) <= 0
            or unsigned.get('swiftNoticePackages', 0) <= 0
            or not unsigned.get('vendoredNotices')
            or not unsigned.get('sourceNoticeFragments')
            or signed.get('source') != source or not signed.get('identity')
            or not isinstance(signed.get('tree'), dict)
            or not signed['tree']):
        raise RuntimeError('Unsigned candidate or signed payload identity is incomplete')
    full = values['full_suite']
    live = values['live']
    if (full.get('passed') is not True or full.get('runtime_tests') != 27
            or full.get('parity_cases') != 66 or len(full.get('rows', [])) != 67
            or any(row.get('status') != 0 for row in full['rows'])
            or live.get('passed') is not True
            or live.get('original_full_suite') != full
            or set(live.get('benchmarks', {})) != {
                '1-services-up', '1-services-down', '3-services-up', '3-services-down'}):
        raise RuntimeError('Original runtime/parity suite or matched benchmark is incomplete')
    for measurement in live['benchmarks'].values():
        if measurement.get('passed') is not True or any(
                len(measurement['lanes'][lane]['raw_seconds']) != 7
                for lane in ('candidate', 'docker')):
            raise RuntimeError('Seven-trial matched performance gate is incomplete')
    if (values['full_suite_clearance'].get('verified_under_exclusive_lease') is not True
            or values['cleanup'].get('completed') != list(PHASES)
            or (evidence / 'live-recovery-required.json').exists()):
        raise RuntimeError('Private runtime, plugin or workers were not restored')
    notarization = values['notarization']
    archive = evidence / 'signed-compose.zip'
    if (notarization.get('passed') is not True or
            notarization.get('notary', {}).get('status') != 'Accepted'
            or not notarization.get('notary', {}).get('id')
            or notarization.get('source') != source
            or notarization.get('archive') != str(archive)
            or notarization.get('archive_sha256') != digest(archive)
            or notarization.get('signed_payload') != signed['payload']):
        raise RuntimeError('The measured signed archive lacks accepted notarization')
    tree = archive_tree(archive)
    if tree != signed['tree'] or tree.get('resources/THIRD-PARTY-NOTICES.txt') != unsigned[
            'dependencyNoticesSHA256']:
        raise RuntimeError('Signed archive differs from measured payload or notice inventory')
    q_assets = values['q_assets']
    if (q_assets.get('qualified_container_source') != acceptance.get('q_checkpoint')
            or set(q_assets.get('assets', {})) != {'runtime', 'guest', 'builder', 'provenance'}):
        raise RuntimeError('Released qualified Container dependency is incomplete')
    for name, asset in q_assets['assets'].items():
        path = Path(asset['path'])
        if not path.is_file() or path.is_symlink() or digest(path) != asset['sha256']:
            raise RuntimeError('Lower published artifact changed: ' + name)
    chain = values['compiled_sdk_chain']
    if (chain.get('source') != source or chain.get('profile') != 'enhanced'
            or chain.get('selected_config') != 'prebuilt-container-sdk'
            or not chain.get('package_invocation')
            or set(chain.get('locks', {})) != {'argument-parser', 'foundation',
                                              'containerization', 'engine-api', 'container-sdk'}):
        raise RuntimeError('Compiled SDK consumer chain is incomplete')
    for name, lock in chain['locks'].items():
        path = LOCK_DIRECTORY / ('argument-parser.lock.json' if name == 'argument-parser'
                                 else 'layer-locks/' + name + '-enhanced.json')
        if not path.is_file() or digest(path) != lock.get('lock_sha256'):
            raise RuntimeError('Compiled SDK release lock changed: ' + name)
    return {'schema': 1, 'kind': 'signed-compose-product-provenance',
            'source': source, 'qualifiedContainer': acceptance['q_checkpoint'],
            'unsignedCandidate': {'receipt': unsigned,
                                  'receiptSHA256': digest(receipts['unsigned_candidate'])},
            'signedPayload': signed['payload'], 'signedTree': signed['tree'],
            'signedArchiveSHA256': digest(archive),
            'notary': {'status': 'Accepted', 'id': notarization['notary']['id']},
            'noticeInventorySHA256': unsigned['dependencyNoticesSHA256'],
            'lowerReleasedAssets': {
                name: {'sha256': asset['sha256'], 'release': q_assets['releases'][name]}
                for name, asset in q_assets['assets'].items()},
            'compiledSdkChain': chain,
            'qualificationReceiptsSHA256': {name: digest(path)
                                            for name, path in receipts.items()},
            'signedAndNotarized': True, 'releaseChannel': 'qualified-prerelease',
            'signedDistributionReady': False,
            'distributionLimitation': 'Comprehensive vendor/header notice closure remains open'}


def prepare(evidence: Path, output: Path) -> dict:
    if not evidence.is_absolute() or not evidence.is_dir() or not output.is_absolute() or output.exists():
        raise RuntimeError('Release preparation requires existing absolute evidence and fresh output')
    provenance = admit(evidence)
    archive = evidence / 'signed-compose.zip'
    tag = 'layer-compose-' + provenance['source'][:12] + '-' + provenance['signedArchiveSHA256'][:12]
    members = evidence_members(evidence, provenance)
    output.mkdir(parents=True, mode=0o700)
    shutil.copyfile(archive, output / ARCHIVE_NAME)
    if digest(output / ARCHIVE_NAME) != provenance['signedArchiveSHA256']:
        raise RuntimeError('Staged signed Compose archive changed')
    manifest = seal_evidence(output / EVIDENCE_NAME, members, provenance)
    provenance['evidenceCompanion'] = {
        'asset': EVIDENCE_NAME, 'sha256': digest(output / EVIDENCE_NAME),
        'manifestSHA256': hashlib.sha256(canonical_json(manifest)).hexdigest(),
        'benchmarkBaseline': baseline_link(members['benchmark.json'])}
    write(output / PROVENANCE_NAME, provenance)
    locks = {}
    for name, asset in ((ARCHIVE_NAME, output / ARCHIVE_NAME),
                        (PROVENANCE_NAME, output / PROVENANCE_NAME),
                        (EVIDENCE_NAME, output / EVIDENCE_NAME)):
        lock = {'schema': 1, 'repository': REPOSITORY, 'tag': tag,
                'targetCommit': provenance['source'], 'asset': name, 'sha256': digest(asset)}
        lock_path = output / (name + '.lock.json')
        write(lock_path, lock)
        read_lock(lock_path)
        locks[name] = lock
    receipt = {'schema': 1, 'prepared': True, 'published': False,
               'source': provenance['source'], 'tag': tag, 'repository': REPOSITORY,
               'provenanceSHA256': locks[PROVENANCE_NAME]['sha256'],
               'archiveSHA256': locks[ARCHIVE_NAME]['sha256'],
               'evidenceSHA256': locks[EVIDENCE_NAME]['sha256'],
               'qualificationEvidence': str(evidence)}
    write(output / 'prepare-receipt.json', receipt)
    return receipt


def publish(prepared: Path) -> dict:
    """Publish only the exact assets prepared from still-accepted local evidence."""
    if not prepared.is_absolute() or not prepared.is_dir():
        raise RuntimeError('Compose release preparation directory must exist and be absolute')
    if (prepared / 'publish-receipt.json').exists():
        raise RuntimeError('Compose release already has a publication receipt')
    record = read(prepared / 'prepare-receipt.json')
    if record.get('prepared') is not True or record.get('published') is not False:
        raise RuntimeError('Compose release preparation receipt is incomplete')
    evidence = Path(record['qualificationEvidence'])
    admitted = admit(evidence)
    expected_tag = ('layer-compose-' + admitted['source'][:12] + '-'
                    + admitted['signedArchiveSHA256'][:12])
    if (record.get('repository') != REPOSITORY or record.get('source') != admitted['source']
            or record.get('tag') != expected_tag):
        raise RuntimeError('Prepared Compose release no longer binds accepted source')
    assets = (prepared / ARCHIVE_NAME, prepared / PROVENANCE_NAME,
              prepared / EVIDENCE_NAME)
    provenance = read(assets[1])
    members = evidence_members(evidence, admitted)
    manifest = inspect_evidence(assets[2], admitted)
    if (provenance != {**admitted, 'evidenceCompanion': {
            'asset': EVIDENCE_NAME, 'sha256': digest(assets[2]),
            'manifestSHA256': hashlib.sha256(canonical_json(manifest)).hexdigest(),
            'benchmarkBaseline': baseline_link(members['benchmark.json'])}}
            or manifest['files'] != {name: {'sha256': hashlib.sha256(canonical_json(value)).hexdigest(),
                                           'bytes': len(canonical_json(value))}
                                     for name, value in members.items()}):
        raise RuntimeError('Prepared Compose provenance changed')
    receipt_hashes = {ARCHIVE_NAME: 'archiveSHA256', PROVENANCE_NAME: 'provenanceSHA256',
                      EVIDENCE_NAME: 'evidenceSHA256'}
    for asset in assets:
        lock = read_lock(prepared / (asset.name + '.lock.json'))
        if (lock != {'schema': 1, 'repository': REPOSITORY, 'tag': expected_tag,
                     'targetCommit': provenance['source'], 'asset': asset.name,
                     'sha256': digest(asset)} or
                digest(asset) != record[receipt_hashes[asset.name]]):
            raise RuntimeError('Prepared Compose release asset or lock changed: ' + asset.name)
    published = publish_assets(REPOSITORY, expected_tag, provenance['source'],
                               'Qualified Compose ' + provenance['source'][:12],
                               'Signed, notarized qualified Compose prerelease; comprehensive '
                               'vendor/header notice closure remains open.',
                               assets)
    if (published.get('repository') != REPOSITORY or published.get('tag') != expected_tag
            or published.get('targetCommit') != provenance['source']
            or not isinstance(published.get('releaseId'), int)
            or published['releaseId'] <= 0
            or any(not isinstance(row.get('assetId'), int) or row['assetId'] <= 0
                   for row in published.get('assets', {}).values())
            or {name: row.get('sha256') for name, row in published.get('assets', {}).items()}
            != {asset.name: digest(asset) for asset in assets}):
        raise RuntimeError('Published Compose release differs from prepared signed bytes')
    write(prepared / 'publish-receipt.json', {**published, 'published': True,
                                            'evidenceCompanion': {
                                                **provenance['evidenceCompanion'],
                                                'releaseId': published['releaseId'],
                                                'assetId': published['assets'][EVIDENCE_NAME]['assetId']},
                                            'prepareReceiptSHA256': digest(prepared / 'prepare-receipt.json')})
    return published


def verify_published(prepared: Path, destination: Path) -> dict:
    if not prepared.is_absolute() or not prepared.is_dir() or not destination.is_absolute() or destination.exists():
        raise RuntimeError('Published verification requires prepared assets and fresh destination')
    record = read(prepared / 'publish-receipt.json')
    staged = read(prepared / 'prepare-receipt.json')
    if (record.get('published') is not True or record.get('repository') != REPOSITORY
            or record.get('tag') != staged.get('tag')
            or record.get('targetCommit') != staged.get('source')
            or record.get('evidenceCompanion', {}).get('sha256') != staged.get('evidenceSHA256')
            or record['evidenceCompanion'].get('assetId') != record.get('assets', {}).get(
                EVIDENCE_NAME, {}).get('assetId')
            or record.get('prepareReceiptSHA256') != digest(prepared / 'prepare-receipt.json')):
        raise RuntimeError('Compose release is not published')
    for name in (ARCHIVE_NAME, PROVENANCE_NAME, EVIDENCE_NAME):
        lock = read_lock(prepared / (name + '.lock.json'))
        if (lock.get('repository') != REPOSITORY or lock.get('tag') != record['tag']
                or lock.get('targetCommit') != record['targetCommit']
                or lock.get('sha256') != record.get('assets', {}).get(name, {}).get('sha256')):
            raise RuntimeError('Published Compose asset does not match its reviewed lock')
    destination.mkdir(parents=True, mode=0o700)
    downloads = {}
    for name in (ARCHIVE_NAME, PROVENANCE_NAME, EVIDENCE_NAME):
        lock = prepared / (name + '.lock.json')
        downloads[name] = fetch(lock, destination / name)
        if (downloads[name].get('releaseId') != record.get('releaseId')
                or downloads[name].get('assetId') != record['assets'][name].get('assetId')):
            raise RuntimeError('Published Compose release or asset identity changed')
        if digest(Path(downloads[name]['asset'])) != digest(prepared / name):
            raise RuntimeError('Published Compose asset differs from prepared bytes')
    downloaded_archive = Path(downloads[ARCHIVE_NAME]['asset'])
    provenance = read(Path(downloads[PROVENANCE_NAME]['asset']))
    if (provenance != read(prepared / PROVENANCE_NAME)
            or provenance.get('signedArchiveSHA256') != digest(downloaded_archive)
            or archive_tree(downloaded_archive) != provenance.get('signedTree')
            or provenance.get('evidenceCompanion', {}).get('sha256') !=
               digest(Path(downloads[EVIDENCE_NAME]['asset']))):
        raise RuntimeError('Downloaded signed Compose product changed')
    manifest = inspect_evidence(Path(downloads[EVIDENCE_NAME]['asset']), provenance)
    if provenance['evidenceCompanion'].get('manifestSHA256') != hashlib.sha256(
            canonical_json(manifest)).hexdigest():
        raise RuntimeError('Downloaded portable release evidence manifest changed')
    extracted = destination / 'extracted'
    extracted.mkdir()
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(downloaded_archive), str(extracted)],
                   check=True, timeout=120)
    actual_tree = {}
    for path in sorted((extracted / 'compose').rglob('*')):
        if path.is_symlink():
            raise RuntimeError('Downloaded Compose product contains a symbolic link')
        if path.is_file():
            actual_tree[path.relative_to(extracted / 'compose').as_posix()] = digest(path)
    if actual_tree != provenance['signedTree']:
        raise RuntimeError('Extracted Compose product differs from signed payload tree')
    for name in EXECUTABLES:
        if name not in actual_tree or not os.access(extracted / 'compose' / name, os.X_OK):
            raise RuntimeError('Downloaded Compose executable mode is missing: ' + name)
    for name, expected in provenance['signedPayload'].items():
        binary = extracted / 'compose' / name
        if digest(binary) != expected:
            raise RuntimeError('Downloaded signed Compose binary changed: ' + name)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2',
                        str(binary)], check=True, timeout=30)
    result = {'schema': 1, 'publishedBytesVerified': True,
              'source': provenance['source'], 'tag': record['tag'],
              'archiveSHA256': digest(downloaded_archive),
              'provenanceSHA256': downloads[PROVENANCE_NAME]['sha256'],
              'evidenceSHA256': downloads[EVIDENCE_NAME]['sha256'],
              'evidenceManifestSHA256': provenance['evidenceCompanion']['manifestSHA256'],
              'releaseId': record['releaseId'],
              'evidenceAssetId': record['assets'][EVIDENCE_NAME]['assetId'],
              'installedPluginCandidate': str(extracted / 'compose'),
              'fetchReceipts': downloads}
    write(destination / 'consume-receipt.json', result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    staged = commands.add_parser('prepare')
    staged.add_argument('--evidence', required=True, type=Path)
    staged.add_argument('--output', required=True, type=Path)
    release = commands.add_parser('publish')
    release.add_argument('--prepared', required=True, type=Path)
    consumed = commands.add_parser('verify-published')
    consumed.add_argument('--prepared', required=True, type=Path)
    consumed.add_argument('--destination', required=True, type=Path)
    args = parser.parse_args()
    result = (prepare(args.evidence, args.output) if args.command == 'prepare'
              else publish(args.prepared) if args.command == 'publish'
              else verify_published(args.prepared, args.destination))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
