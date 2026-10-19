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

"""Retain selected Q image-store blobs across the qualified private reset.

This is bound to Q f86fea22 and Containerization 6db16197's on-disk image
store. The exact historical Q 15361ce5 receipts remain reusable only when the
24-file image-store source contract is unchanged; their provenance is not
rewritten. Only the original index and linux/arm64 closure are copied.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile

SCHEMA = 1
Q_SOURCE = 'f86fea2236fab118c0e0c6f8be5eb7672df894e2'
LEGACY_Q_SOURCE = '15361ce5f55a6b8ab3242e89650a188766b47581'
IMAGE_FORMAT_CONTRACT_SHA256 = 'f3c6f8fcb3132eb41dcaf48254f6e18e65f47fe15875261cde90931bce6f33ee'
IMAGE_FORMAT_DIRS = ('Sources/Plugins/CoreImages', 'Sources/Services/ContainerImagesService',
                     'Sources/ContainerCommands/Image')
IMAGE_FORMAT_FILES = ('Sources/Services/ContainerAPIService/Client/ClientImage.swift',
                      'Sources/ContainerPlugin/ApplicationRoot.swift', 'Package.resolved')
CONTAINERIZATION_SOURCE = '6db16197bbad8196a78132f86529daa89125aafb'
INDEX_TYPES = {'application/vnd.oci.image.index.v1+json',
               'application/vnd.docker.distribution.manifest.list.v2+json'}
MANIFEST_TYPES = {'application/vnd.oci.image.manifest.v1+json',
                  'application/vnd.docker.distribution.manifest.v2+json'}
HEX = re.compile(r'sha256:([0-9a-f]{64})\Z')


def digest(data: bytes) -> str:
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def regular(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file() or not stat.S_ISREG(path.stat().st_mode):
        raise RuntimeError('Fixture cache path is not a regular file: ' + str(path))
    return path.read_bytes()


def directory(path: Path, *, create: bool = False) -> None:
    if create and not path.exists() and not path.is_symlink():
        path.mkdir(mode=0o700, parents=True)
    if path.is_symlink() or not path.is_dir():
        raise RuntimeError('Fixture cache path is not a directory: ' + str(path))


def normalized(reference: str) -> str:
    if not isinstance(reference, str) or not reference or any(c.isspace() for c in reference):
        raise RuntimeError('Invalid fixture image reference')
    if reference.startswith('index.docker.io/'):
        result = 'docker.io/' + reference.removeprefix('index.docker.io/')
    elif reference.startswith(('docker.io/', 'ghcr.io/')):
        result = reference
    elif '/' in reference:
        result = 'docker.io/' + reference
    else:
        result = 'docker.io/library/' + reference
    if any(part in ('', '.', '..') for part in result.split('/')):
        raise RuntimeError('Invalid fixture image reference')
    if not re.fullmatch(r'[a-z0-9./_-]+(?::[A-Za-z0-9_.-]+)?(?:@sha256:[0-9a-f]{64})?', result) \
            or (':' not in result.rsplit('/', 1)[-1] and '@sha256:' not in result):
        raise RuntimeError('Invalid fixture image reference')
    return result


def entry_path(cache: Path, reference: str) -> Path:
    return cache / hashlib.sha256(reference.encode()).hexdigest()


def blob(root: Path, descriptor: dict) -> bytes:
    if not isinstance(descriptor, dict) or not isinstance(descriptor.get('size'), int) \
            or isinstance(descriptor.get('size'), bool) or descriptor['size'] < 0:
        raise RuntimeError('Invalid fixture image descriptor')
    value = descriptor.get('digest')
    match = HEX.fullmatch(value) if isinstance(value, str) else None
    if not match:
        raise RuntimeError('Invalid fixture image digest')
    path = root / 'blobs' / 'sha256' / match.group(1)
    directory(root)
    directory(root / 'blobs')
    directory(root / 'blobs' / 'sha256')
    raw = regular(path)
    if len(raw) != descriptor['size'] or digest(raw) != descriptor['digest']:
        raise RuntimeError('Fixture image blob changed: ' + descriptor['digest'])
    return raw


def closure(root: Path, descriptor: dict, reference: str) -> dict:
    if not isinstance(descriptor, dict) or not {'digest', 'mediaType', 'size'} <= set(descriptor) \
            or set(descriptor) - {'digest', 'mediaType', 'size', 'annotations'} \
            or descriptor['mediaType'] not in INDEX_TYPES:
        raise RuntimeError('Fixture image must retain its original index descriptor')
    annotations = descriptor.get('annotations', {})
    if not isinstance(annotations, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                                     for k, v in annotations.items()):
        raise RuntimeError('Fixture image index annotations are invalid')
    if '@sha256:' in reference and descriptor['digest'] != reference.split('@', 1)[1]:
        raise RuntimeError('Pinned fixture reference does not match its original index')
    index = json.loads(blob(root, descriptor))
    manifests = index.get('manifests')
    if not isinstance(manifests, list):
        raise RuntimeError('Fixture image index has no manifests')
    selected = [row for row in manifests if isinstance(row, dict)
                and isinstance(row.get('platform'), dict)
                and row['platform'].get('os') == 'linux'
                and row['platform'].get('architecture') == 'arm64'
                and row['platform'].get('variant') in (None, 'v8')]
    if len(selected) != 1 or selected[0].get('mediaType') not in MANIFEST_TYPES:
        raise RuntimeError('Fixture image needs exactly one linux/arm64 manifest')
    manifest = selected[0]
    content = json.loads(blob(root, manifest))
    config = content.get('config')
    layers = content.get('layers')
    if not isinstance(config, dict) or not isinstance(layers, list):
        raise RuntimeError('Fixture image manifest is incomplete')
    configuration = json.loads(blob(root, config))
    if configuration.get('os') != 'linux' or configuration.get('architecture') != 'arm64':
        raise RuntimeError('Fixture image configuration is not linux/arm64')
    descriptors = [descriptor, manifest, config, *layers]
    for item in layers:
        if not isinstance(item, dict):
            raise RuntimeError('Invalid fixture image layer')
        blob(root, item)
    unique = {item['digest']: item['size'] for item in descriptors}
    return {'root': descriptor, 'arm64_manifest': manifest['digest'],
            'config': config['digest'],
            'blobs': [{'digest': key, 'size': value} for key, value in sorted(unique.items())]}


def image_store_contract(root: Path) -> str:
    """Bind the complete Q image-service source and unchanged 5ed dependency graph."""
    names = list(IMAGE_FORMAT_FILES)
    for directory_name in IMAGE_FORMAT_DIRS:
        directory_path = root / directory_name
        if directory_path.is_symlink() or not directory_path.is_dir():
            raise RuntimeError('Q image-store source directory changed')
        names.extend(str(path.relative_to(root)) for path in directory_path.rglob('*.swift'))
    rows = {}
    for name in sorted(names):
        path = root / name
        rows[name] = hashlib.sha256(regular(path)).hexdigest()
    return hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def legacy_format_compatible(root: Path) -> bool:
    return image_store_contract(root) == IMAGE_FORMAT_CONTRACT_SHA256


def receipt(entry: Path, reference: str, *, container_root: Path | None = None) -> dict:
    directory(entry)
    value = json.loads(regular(entry / 'receipt.json'))
    recorded_q = value.get('q_source')
    if (value.get('schema') != SCHEMA
            or recorded_q not in (Q_SOURCE, LEGACY_Q_SOURCE)
            or (recorded_q == LEGACY_Q_SOURCE and (
                container_root is None or not legacy_format_compatible(container_root)))
            or value.get('containerization_source') != CONTAINERIZATION_SOURCE
            or value.get('reference') != reference
            or not isinstance(value.get('stored_reference'), str)):
        raise RuntimeError('Fixture cache receipt identity changed')
    if normalized(value['stored_reference']) != normalized(reference) \
            and (not _same_pinned_repository(value['stored_reference'], reference)
                 or value['root']['digest'] != reference.split('@', 1)[1]):
        raise RuntimeError('Fixture cache stored reference changed')
    verified = closure(entry / 'content', value.get('root'), reference)
    if value.get('arm64_manifest') != verified['arm64_manifest'] \
            or value.get('config') != verified['config'] or value.get('blobs') != verified['blobs']:
        raise RuntimeError('Fixture cache receipt content changed')
    return value


def repository(reference: str) -> str:
    # Docker's successful image listing may print <none> for a digest-only tag.
    # Strip that display tag before validating the repository, never treating
    # the listing's image ID as a registry digest.
    untagged = reference.removesuffix(':<none>')
    if ':' not in untagged.rsplit('/', 1)[-1] and '@sha256:' not in untagged:
        untagged += ':fixture'
    canonical = normalized(untagged).split('@', 1)[0]
    if ':' in canonical.rsplit('/', 1)[-1]:
        canonical = canonical.rsplit(':', 1)[0]
    return canonical


def _same_pinned_repository(stored: str, requested: str) -> bool:
    return '@sha256:' in requested and repository(stored) == repository(requested)


def _state_entry(state: dict, reference: str) -> tuple[str, dict] | None:
    if reference in state:
        return reference, state[reference]
    if '@sha256:' not in reference:
        return None
    root_digest = reference.split('@', 1)[1]
    exact_aliases = []
    for key, descriptor in state.items():
        if not isinstance(key, str) or not isinstance(descriptor, dict):
            continue
        try:
            canonical = normalized(key)
        except RuntimeError:
            continue
        if canonical == reference:
            exact_aliases.append((key, descriptor))
    if exact_aliases:
        if any(descriptor.get('digest') != root_digest for _, descriptor in exact_aliases):
            raise RuntimeError('Pinned fixture image alias changed its original index')
        if len({json.dumps(descriptor, sort_keys=True) for _, descriptor in exact_aliases}) != 1:
            raise RuntimeError('Ambiguous pinned fixture image aliases')
        return sorted(exact_aliases, key=lambda item: item[0])[0]
    matches = [(key, descriptor) for key, descriptor in state.items()
               if isinstance(key, str) and isinstance(descriptor, dict)
               and descriptor.get('digest') == root_digest
               and _same_pinned_repository(key, reference)]
    canonical = {normalized(key) for key, _ in matches}
    if len(canonical) > 1:
        raise RuntimeError('Ambiguous pinned fixture image aliases')
    return sorted(matches)[0] if matches else None


def native_record(rows: dict, requested: str) -> dict | None:
    """Find a Q image by its pinned original root, including state-name aliases."""
    reference = normalized(requested)
    if reference in rows:
        return rows[reference]
    if '@sha256:' not in reference:
        return None
    root_digest = reference.split('@', 1)[1]
    matches = [row for name, row in rows.items()
               if repository(name) == repository(reference)
               and row['configuration']['descriptor']['digest'] == root_digest]
    if not matches:
        return None
    variants = {tuple(sorted(variant['digest'] for variant in row['variants']
                             if variant.get('platform', {}).get('os') == 'linux'
                             and variant.get('platform', {}).get('architecture') == 'arm64'))
                for row in matches}
    if len(variants) != 1:
        raise RuntimeError('Ambiguous pinned Q fixture image aliases')
    return matches[0]


def docker_pinned_candidates(identities: set[str], requested: str) -> set[str]:
    """Select only image IDs in the requested repository from a Docker listing."""
    expected_repo = repository(requested)
    result = set()
    for identity in identities:
        reference, separator, image_id = identity.partition('|')
        if not separator or not image_id:
            raise RuntimeError('Docker fixture inventory identity changed')
        if reference == '<none>:<none>':
            continue
        try:
            observed_repo = repository(reference)
        except RuntimeError:
            # The complete host inventory can contain unrelated local registries
            # with ports, which are outside this finite public fixture allowlist.
            continue
        if observed_repo == expected_repo:
            result.add(image_id)
    return result


def docker_pinned_metadata_matches(raw: str, requested: str) -> bool:
    """Match only public platform/RepoDigest metadata, never image Config.Env."""
    fields = raw.strip().split('|', 3)
    if len(fields) != 4:
        raise RuntimeError('Docker pinned fixture image metadata changed')
    operating_system, architecture, variant, raw_digests = fields
    digests = json.loads(raw_digests)
    if digests is None:
        digests = []
    if not isinstance(digests, list) or not all(isinstance(value, str) for value in digests):
        raise RuntimeError('Docker pinned fixture image metadata changed')
    if operating_system != 'linux' or architecture != 'arm64' or variant not in ('', 'v8'):
        return False
    expected = normalized(requested)
    if '@sha256:' not in expected:
        raise RuntimeError('Docker fixture image is not digest-pinned')
    if not all(re.fullmatch(r'[^\s@]+@sha256:[0-9a-f]{64}', value) for value in digests):
        raise RuntimeError('Docker pinned fixture image digest metadata changed')
    for value in digests:
        try:
            observed_repo = repository(value)
        except RuntimeError:
            # Other registry aliases on the same image are not fixture refs.
            continue
        if observed_repo == repository(expected) \
                and value.split('@', 1)[1] == expected.split('@', 1)[1]:
            return True
    return False


def capture(app: Path, cache: Path, references: tuple[str, ...], *,
            container_root: Path | None = None) -> list[dict]:
    """Add currently present allowlisted images without replacing existing entries."""
    directory(cache, create=True)
    if not (app / 'state.json').exists():
        return []
    directory(app)
    state = json.loads(regular(app / 'state.json'))
    if not isinstance(state, dict):
        raise RuntimeError('Q image state is malformed')
    result = []
    for requested in references:
        reference = normalized(requested)
        destination = entry_path(cache, reference)
        if destination.exists() or destination.is_symlink():
            result.append(receipt(destination, reference, container_root=container_root))
            continue
        selected = _state_entry(state, reference)
        if selected is None:
            continue
        stored_reference, descriptor = selected
        source = app / 'content'
        inspected = closure(source, descriptor, reference)
        staging = Path(tempfile.mkdtemp(prefix='.fixture-', dir=cache))
        try:
            blobs = staging / 'content' / 'blobs' / 'sha256'
            blobs.mkdir(mode=0o700, parents=True)
            for item in inspected['blobs']:
                name = item['digest'][7:]
                shutil.copyfile(source / 'blobs' / 'sha256' / name, blobs / name)
            value = {'schema': SCHEMA, 'q_source': Q_SOURCE,
                     'containerization_source': CONTAINERIZATION_SOURCE,
                     'reference': reference, 'stored_reference': stored_reference,
                     **inspected}
            (staging / 'receipt.json').write_text(json.dumps(value, sort_keys=True) + '\n')
            receipt(staging, reference, container_root=container_root)
            if destination.exists() or destination.is_symlink():
                result.append(receipt(destination, reference, container_root=container_root))
            else:
                staging.rename(destination)
                result.append(value)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    return result


def restore(app: Path, cache: Path, references: tuple[str, ...], *,
            container_root: Path | None = None) -> list[dict]:
    """Seed only verified fixture refs into a freshly reset, idle Q app tree."""
    directory(app)
    if (app / 'state.json').exists() or (app / 'state.json').is_symlink() \
            or (app / 'content').exists() or (app / 'content').is_symlink() \
            or (app / 'snapshots').exists() or (app / 'snapshots').is_symlink():
        raise RuntimeError('Q fixture cache target is not a fresh reset app')
    if not cache.exists() and not cache.is_symlink():
        return []
    directory(cache)
    values = []
    for requested in references:
        reference = normalized(requested)
        source = entry_path(cache, reference)
        if source.exists() or source.is_symlink():
            values.append(receipt(source, reference, container_root=container_root))
    if not values:
        return []
    blobs = app / 'content' / 'blobs' / 'sha256'
    blobs.mkdir(mode=0o700, parents=True)
    state = {}
    for value in values:
        stored_reference = value['stored_reference']
        if stored_reference in state and state[stored_reference] != value['root']:
            raise RuntimeError('Fixture cache reference collision')
        state[stored_reference] = value['root']
        source = entry_path(cache, value['reference']) / 'content' / 'blobs' / 'sha256'
        for item in value['blobs']:
            name = item['digest'][7:]
            destination = blobs / name
            if destination.exists() or destination.is_symlink():
                if digest(regular(destination)) != item['digest']:
                    raise RuntimeError('Fixture cache blob collision')
            else:
                shutil.copyfile(source / name, destination)
            if len(regular(destination)) != item['size'] or digest(regular(destination)) != item['digest']:
                raise RuntimeError('Fixture cache copied blob changed')
    temporary = app / '.fixture-state.json'
    if temporary.exists() or temporary.is_symlink():
        raise RuntimeError('Q fixture cache temporary state already exists')
    temporary.write_text(json.dumps(state, sort_keys=True) + '\n')
    os.replace(temporary, app / 'state.json')
    return values
