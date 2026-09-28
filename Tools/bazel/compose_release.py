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
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

from artifacts.release_asset import fetch, publish_assets, read_lock

REPOSITORY = 'stephenlclarke/container-compose'
ARCHIVE_NAME = 'container-compose-signed-arm64.zip'
PROVENANCE_NAME = 'qualified-compose-release.json'
LOCK_DIRECTORY = Path(__file__).resolve().parent / 'artifacts'
SHA = re.compile(r'[0-9a-f]{64}\Z')
COMMIT = re.compile(r'[0-9a-f]{40}\Z')
PHASES = ('full_suite', 'projects', 'runtime', 'plugin', 'private_install',
          'colima', 'stock', 'install', 'host')
EXECUTABLES = ('bin/compose', 'resources/compose-normalizer',
               'resources/volume-initializer/compose-volume-initializer-linux-arm64',
               'resources/volume-initializer/compose-volume-initializer-linux-amd64')


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
    output.mkdir(parents=True, mode=0o700)
    shutil.copyfile(archive, output / ARCHIVE_NAME)
    if digest(output / ARCHIVE_NAME) != provenance['signedArchiveSHA256']:
        raise RuntimeError('Staged signed Compose archive changed')
    write(output / PROVENANCE_NAME, provenance)
    locks = {}
    for name, asset in ((ARCHIVE_NAME, output / ARCHIVE_NAME),
                        (PROVENANCE_NAME, output / PROVENANCE_NAME)):
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
    provenance = admit(evidence)
    expected_tag = ('layer-compose-' + provenance['source'][:12] + '-'
                    + provenance['signedArchiveSHA256'][:12])
    if (record.get('repository') != REPOSITORY or record.get('source') != provenance['source']
            or record.get('tag') != expected_tag):
        raise RuntimeError('Prepared Compose release no longer binds accepted source')
    assets = (prepared / ARCHIVE_NAME, prepared / PROVENANCE_NAME)
    if read(assets[1]) != provenance:
        raise RuntimeError('Prepared Compose provenance changed')
    for asset in assets:
        lock = read_lock(prepared / (asset.name + '.lock.json'))
        if (lock != {'schema': 1, 'repository': REPOSITORY, 'tag': expected_tag,
                     'targetCommit': provenance['source'], 'asset': asset.name,
                     'sha256': digest(asset)} or
                digest(asset) != record['archiveSHA256' if asset.name == ARCHIVE_NAME
                                        else 'provenanceSHA256']):
            raise RuntimeError('Prepared Compose release asset or lock changed: ' + asset.name)
    published = publish_assets(REPOSITORY, expected_tag, provenance['source'],
                               'Qualified Compose ' + provenance['source'][:12],
                               'Signed, notarized qualified Compose prerelease; comprehensive '
                               'vendor/header notice closure remains open.',
                               assets)
    if (published.get('repository') != REPOSITORY or published.get('tag') != expected_tag
            or published.get('targetCommit') != provenance['source']
            or {name: row.get('sha256') for name, row in published.get('assets', {}).items()}
            != {asset.name: digest(asset) for asset in assets}):
        raise RuntimeError('Published Compose release differs from prepared signed bytes')
    write(prepared / 'publish-receipt.json', {**published, 'published': True,
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
            or record.get('prepareReceiptSHA256') != digest(prepared / 'prepare-receipt.json')):
        raise RuntimeError('Compose release is not published')
    for name in (ARCHIVE_NAME, PROVENANCE_NAME):
        lock = read_lock(prepared / (name + '.lock.json'))
        if (lock.get('repository') != REPOSITORY or lock.get('tag') != record['tag']
                or lock.get('targetCommit') != record['targetCommit']
                or lock.get('sha256') != record.get('assets', {}).get(name, {}).get('sha256')):
            raise RuntimeError('Published Compose asset does not match its reviewed lock')
    destination.mkdir(parents=True, mode=0o700)
    downloads = {}
    for name in (ARCHIVE_NAME, PROVENANCE_NAME):
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
            or archive_tree(downloaded_archive) != provenance.get('signedTree')):
        raise RuntimeError('Downloaded signed Compose product changed')
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
