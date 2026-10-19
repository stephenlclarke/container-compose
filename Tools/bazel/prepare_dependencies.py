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

"""Prepare the enhanced SwiftPM consumer sources from exact pins and reviewed patches.

USAGE: prepare_dependencies.py --profile stock|enhanced --output ABSOLUTE_FRESH_DIRECTORY
Optional --containerization-source and --zstd-source select local Git object stores.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PATCHES = {
    'containerization': 'containerization-ext4-unaligned.patch',
    'zstd': 'zstd-public-module.patch',
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(repository: Path, *args: str, env: dict[str, str], input: bytes | None = None) -> bytes:
    return subprocess.check_output(['/usr/bin/git', '-C', str(repository), *args], input=input,
                                   env=env, stderr=subprocess.PIPE, timeout=300)


def clean_environment() -> dict[str, str]:
    return {'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
            'GIT_TERMINAL_PROMPT': '0', 'GIT_ASKPASS': '/usr/bin/false',
            'GCM_INTERACTIVE': 'never', 'GIT_CONFIG_COUNT': '1',
            'GIT_CONFIG_KEY_0': 'credential.helper', 'GIT_CONFIG_VALUE_0': ''}


def source_tree_hash(path: Path, env: dict[str, str]) -> str:
    digest = hashlib.sha256()
    for raw in sorted(git(path, 'ls-files', '--cached', '--others', '--exclude-standard', '-z', env=env).split(b'\0')):
        if not raw:
            continue
        name = raw.decode()
        file = path / name
        if file.is_symlink():
            payload, mode = os.readlink(file).encode(), 'link'
        elif file.is_file():
            payload = file.read_bytes()
            mode = 'executable' if file.stat().st_mode & stat.S_IXUSR else 'file'
        else:
            raise ValueError(f'Unsupported dependency source input: {name}')
        digest.update(name.encode() + b'\0' + mode.encode() + b'\0' + bytes.fromhex(sha(payload)))
    return digest.hexdigest()


def prepare(identity: str, pin: dict, output: Path, source: Path | None,
            env: dict[str, str]) -> dict:
    revision = pin['state']['revision']
    if pin['kind'] != 'remoteSourceControl' or not (len(revision) == 40 and all(c in '0123456789abcdef' for c in revision)):
        raise ValueError('Dependency needs an exact source revision')
    destination = output / identity
    destination.mkdir(mode=0o700)
    git(destination, 'init', '-q', env=env)
    remote = str(source.resolve()) if source else pin['location']
    git(destination, 'fetch', '--quiet', '--no-tags', '--depth=1', remote, revision, env=env)
    git(destination, 'checkout', '--quiet', '--detach', 'FETCH_HEAD', env=env)
    actual = git(destination, 'rev-parse', 'HEAD', env=env).decode().strip()
    if actual != revision:
        raise ValueError(f'{identity} source commit mismatch')
    patch = ROOT / 'Tools/bazel' / PATCHES[identity]
    patch_bytes = patch.read_bytes()
    base_tree = source_tree_hash(destination, env)
    git(destination, 'apply', '--check', str(patch), env=env)
    git(destination, 'apply', str(patch), env=env)
    result_tree = source_tree_hash(destination, env)
    if base_tree == result_tree:
        raise ValueError(f'{identity} patch changed no source bytes')
    return {'path': str(destination), 'remote': pin['location'], 'baseRevision': revision,
            'baseTreeSHA256': base_tree, 'patch': PATCHES[identity],
            'patchSHA256': sha(patch_bytes), 'resultTreeSHA256': result_tree}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=['stock', 'enhanced'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--containerization-source', type=Path)
    parser.add_argument('--zstd-source', type=Path)
    args = parser.parse_args()
    output = args.output
    if not output.is_absolute() or output.is_symlink() or output.exists():
        parser.error('--output must be an absolute fresh directory')
    if any(part.is_symlink() for part in output.parents):
        parser.error('Symlinked output parents are not supported')
    os.umask(0o077)
    output.mkdir(mode=0o700)
    receipt: dict = {'schema': 1, 'profile': args.profile, 'containerization': None, 'zstd': None}
    if args.profile == 'enhanced':
        pins = {entry['identity']: entry for entry in json.loads((ROOT / 'Package.resolved').read_text())['pins']}
        env = clean_environment()
        for identity, source in (('containerization', args.containerization_source), ('zstd', args.zstd_source)):
            receipt[identity] = prepare(identity, pins[identity], output, source, env)
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(output / 'receipt.json')


if __name__ == '__main__':
    main()
