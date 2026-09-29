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

"""Bind released Q runtime/guest/builder bytes to portable qualified provenance."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Callable

from artifacts.release_asset import read_lock

Q = '6fe80db1bad6abff5dfa22f02bdf8bc403ad48bc'
GUEST = '5ed9bc7490aa30c76337bd5b3d8ff251b63c678f'
BUILDER = '016040197215684db474181b444767eb58797cfa'
NAMES = {'runtime': 'container-homebrew-arm64.tar.gz',
         'guest': 'guest.oci.tar', 'builder': 'builder.oci.tar',
         'provenance': 'qualified-container-assets.json'}
SOURCES = {'runtime': ('stephenlclarke/container', Q),
           'provenance': ('stephenlclarke/container', Q),
           'guest': ('stephenlclarke/containerization', GUEST),
           'builder': ('stephenlclarke/container-builder-shim', BUILDER)}
LOCKS = Path(__file__).with_name('artifacts') / 'q-assets'
FETCH = Path(__file__).with_name('artifacts') / 'release_asset.py'
SHA = re.compile(r'[0-9a-f]{64}\Z')
RECEIPTS = {'acceptance.json', 'release/release-artifact.json',
            'runtime-smoke/fork-fingerprint.json',
            'runtime-smoke/guest-artifact.json',
            'runtime-smoke/builder-artifact.json'}


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for piece in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(piece)
    return value.hexdigest()


def fetch_command(lock: Path, destination: Path) -> None:
    subprocess.run([sys.executable, str(FETCH), 'fetch', '--lock', str(lock),
                    '--destination', str(destination)], check=True, timeout=420)


def validate(bundle: dict, locks: dict, helpers: dict[str, str]) -> None:
    if (bundle.get('schema') != 1 or bundle.get('kind') != 'container-qualified-runtime-assets'
            or bundle.get('qualified_container_source') != Q
            or bundle.get('qualification') != {'target': 'bazel-qualify', 'passed': True}
            or bundle.get('qualified_helpers_sha256') != helpers):
        raise RuntimeError('Released Q provenance has wrong qualification or helper identity')
    assets = bundle.get('assets')
    if not isinstance(assets, dict) or set(assets) != set(NAMES) - {'provenance'}:
        raise RuntimeError('Released Q provenance omits a required product')
    for name in ('runtime', 'guest', 'builder'):
        product = assets[name]
        if (product.get('name') != NAMES[name]
                or product.get('sha256') != locks[name]['sha256']):
            raise RuntimeError('Released Q asset differs from the provenance sidecar: ' + name)
    if (assets['runtime'].get('source') != Q
            or assets['guest'].get('source') != GUEST
            or assets['builder'].get('source') != BUILDER):
        raise RuntimeError('Released Q asset source graph changed')
    guest, builder, runtime = bundle.get('guest', {}), bundle.get('builder', {}), bundle.get('runtime', {})
    if (guest.get('source') != GUEST or guest.get('reference') != assets['guest'].get('reference')
            or builder.get('source') != BUILDER or builder.get('reference') != assets['builder'].get('reference')
            or runtime.get('init_archive_sha256') != assets['guest']['sha256']
            or runtime.get('builder_archive_sha256') != assets['builder']['sha256']
            or runtime.get('notary', {}).get('status') != 'Accepted'
            or not runtime.get('notary', {}).get('id')
            or runtime.get('init_image') != assets['guest']['reference']
            or runtime.get('builder_image') != assets['builder']['reference']
            or not runtime.get('workload_image', '').startswith('docker.io/library/alpine@sha256:')):
        raise RuntimeError('Released Q runtime/OCI/notarization provenance changed')
    payload = runtime.get('payload')
    receipts = bundle.get('source_receipt_sha256')
    if (not isinstance(payload, dict) or len(payload) != 25
            or any(not SHA.fullmatch(value) or path.startswith('/') or '..' in Path(path).parts
                   for path, value in payload.items())
            or not isinstance(receipts, dict) or set(receipts) != RECEIPTS
            or any(not SHA.fullmatch(value) for value in receipts.values())
            or not SHA.fullmatch(runtime.get('kernel_sha256', ''))
            or not SHA.fullmatch(runtime.get('package_lock_sha256', ''))):
        raise RuntimeError('Released Q payload or source receipts are malformed')


def fetch_assets(evidence: Path, helpers: dict[str, str],
                 *, locks_dir: Path = LOCKS,
                 invoke: Callable[[Path, Path], None] = fetch_command) -> dict:
    """Use only the common published-release transport; never fall back locally."""
    if evidence.exists() or not evidence.is_absolute():
        raise RuntimeError('Q asset evidence must be a fresh absolute directory')
    locks = {name: read_lock(locks_dir / (name + '.lock.json')) for name in NAMES}
    if (any((row['repository'], row['targetCommit']) != SOURCES[name]
            or row['asset'] != NAMES[name] for name, row in locks.items())
            or locks['runtime']['tag'] != locks['provenance']['tag']):
        raise RuntimeError('Released Q asset locks do not bind their exact source releases')
    evidence.mkdir(parents=True, mode=0o700)
    files = {}
    receipts = {}
    for name in NAMES:
        directory = evidence / name
        invoke(locks_dir / (name + '.lock.json'), directory)
        receipt = json.loads((directory / 'fetch-receipt.json').read_text())
        asset = directory / NAMES[name]
        if (receipt.get('targetCommit') != locks[name]['targetCommit']
                or receipt.get('repository') != locks[name]['repository']
                or receipt.get('tag') != locks[name]['tag']
                or receipt.get('asset') != str(asset) or receipt.get('sha256') != locks[name]['sha256']
                or receipt.get('lockSHA256') != digest(locks_dir / (name + '.lock.json'))
                or not asset.is_file() or asset.is_symlink()
                or digest(asset) != locks[name]['sha256']):
            raise RuntimeError('Released Q fetch receipt or asset changed: ' + name)
        files[name] = asset
        receipts[name] = receipt
    bundle = json.loads(files['provenance'].read_text())
    validate(bundle, locks, helpers)
    result = {'schema': 1, 'qualified_container_source': Q,
              'releases': {name: {'repository': locks[name]['repository'],
                                  'tag': locks[name]['tag'],
                                  'target_commit': locks[name]['targetCommit']}
                           for name in NAMES},
              'assets': {name: {'path': str(files[name]), 'sha256': locks[name]['sha256'],
                                'fetch_receipt_sha256': digest(evidence / name / 'fetch-receipt.json')}
                         for name in NAMES},
              'provenance': bundle}
    (evidence / 'q-assets.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def revalidate(evidence: Path, helpers: dict[str, str]) -> dict:
    """Recover using exactly the already downloaded bytes, without network access."""
    result = json.loads((evidence / 'q-assets.json').read_text())
    if result.get('schema') != 1 or result.get('qualified_container_source') != Q:
        raise RuntimeError('Q asset recovery receipt has a different source')
    assets = result.get('assets', {})
    releases = result.get('releases', {})
    if set(assets) != set(NAMES) or set(releases) != set(NAMES):
        raise RuntimeError('Q asset recovery receipt omitted a product')
    locks = {name: read_lock(LOCKS / (name + '.lock.json')) for name in NAMES}
    for name in NAMES:
        path = evidence / name / NAMES[name]
        row = assets[name]
        lock = locks[name]
        receipt_path = evidence / name / 'fetch-receipt.json'
        receipt = json.loads(receipt_path.read_text())
        if (row.get('path') != str(path) or path.is_symlink() or not path.is_file()
                or row.get('sha256') != lock['sha256'] or row['sha256'] != digest(path)
                or row.get('fetch_receipt_sha256') != digest(receipt_path)
                or (releases[name]['repository'], releases[name]['target_commit'], releases[name]['tag'])
                   != (lock['repository'], lock['targetCommit'], lock['tag'])
                or (receipt.get('repository'), receipt.get('targetCommit'), receipt.get('tag'),
                    receipt.get('sha256'), receipt.get('asset'), receipt.get('lockSHA256'))
                   != (lock['repository'], lock['targetCommit'], lock['tag'], lock['sha256'],
                       str(path), digest(LOCKS / (name + '.lock.json')))):
            raise RuntimeError('Downloaded Q asset changed during recovery: ' + name)
    if releases['runtime']['tag'] != releases['provenance']['tag']:
        raise RuntimeError('Released Q sidecar belongs to a different runtime release')
    bundle = json.loads((evidence / 'provenance' / NAMES['provenance']).read_text())
    if result.get('provenance') != bundle:
        raise RuntimeError('Released Q provenance changed during recovery')
    validate(bundle, locks, helpers)
    return result
