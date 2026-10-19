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

"""Journal and restore only the external-build-secret parity keychain fixture."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys

KEYCHAIN = 'external-build-secret.keychain-db'
RECEIPT = 'keychain.json'
SERVICE = 'com.apple.container-compose'
MARKER = 'external-build-secret-parity-ok'  # Public parity value, not a credential.


class Security:
    def __init__(self, descriptor: int):
        self.descriptor = descriptor

    def __call__(self, *arguments: str) -> str:
        # An orphaned mutation retains this lock until the exact child exits.
        # Never echo arguments, stderr or exceptions that can contain passwords.
        try:
            result = subprocess.run(
                ['/usr/bin/security', *arguments], stdin=subprocess.DEVNULL,
                capture_output=True, text=True, timeout=30,
                pass_fds=(self.descriptor,), check=False,
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError('Keychain fixture command timed out; recovery required') from None
        if result.returncode:
            raise RuntimeError('Keychain fixture command failed; recovery required')
        return result.stdout


def search_list(security: Security) -> list[str]:
    paths = shlex.split(security('list-keychains', '-d', 'user'))
    if len(set(paths)) != len(paths) or any(not Path(path).is_absolute() for path in paths):
        raise RuntimeError('User keychain search list is not an unambiguous absolute list')
    return paths


def save(directory: Path, record: dict) -> None:
    temporary = directory / (RECEIPT + '.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(record, stream, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(directory / RECEIPT)
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextmanager
def journal(directory: Path, *, create: bool = False):
    if not directory.is_absolute() or directory.is_symlink():
        raise RuntimeError('Keychain journal must be an absolute owned directory')
    directory = directory.resolve()
    if create:
        directory.mkdir(mode=0o700)
    info = directory.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('Keychain journal directory is not private to this user')
    descriptor = os.open(directory / '.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        lock = os.fstat(descriptor)
        if (not stat.S_ISREG(lock.st_mode) or lock.st_uid != os.getuid()
                or lock.st_nlink != 1 or lock.st_mode & 0o077):
            raise RuntimeError('Unsafe keychain journal lock')
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield directory, Security(descriptor)
    finally:
        # Close without LOCK_UN: an inherited child must keep its exclusion.
        os.close(descriptor)


def owned_file(path: Path) -> None:
    if path.is_symlink():
        raise RuntimeError('Owned keychain path became a symbolic link')
    if path.exists():
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise RuntimeError('Owned keychain path has a different file identity')


def unchanged_others(current: list[str], original: list[str], keychain: str) -> None:
    if current.count(keychain) > 1 or [path for path in current if path != keychain] != original:
        raise RuntimeError('Unrelated keychain search list changed; preserving it for explicit recovery')


def prepare(directory: Path, password: str, account: str, owner: str) -> Path:
    if not password or not account or not re.fullmatch(r'[0-9a-f]{32}', owner):
        raise RuntimeError('Fixture password, account and invocation identity are required')
    with journal(directory, create=True) as (directory, security):
        keychain = directory / KEYCHAIN
        original = search_list(security)
        if str(keychain) in original or keychain.exists():
            raise RuntimeError('Fixture keychain path is already in use')
        info = directory.stat()
        record = {'schema': 1, 'owner_uid': os.getuid(), 'journal': str(directory),
                  'invocation': owner,
                  'directory_identity': [info.st_dev, info.st_ino],
                  'keychain': str(keychain), 'original_search_list': original,
                  'prepared': False, 'restored': False}
        # This intent covers create-keychain, which may itself add to the list.
        save(directory, record)
        security('create-keychain', '-p', password, str(keychain))
        security('set-keychain-settings', '-lut', '3600', str(keychain))
        security('unlock-keychain', '-p', password, str(keychain))
        security('add-generic-password', '-A', '-U', '-s', SERVICE, '-a', account,
                 '-w', MARKER, str(keychain))
        unchanged_others(search_list(security), original, str(keychain))
        security('list-keychains', '-d', 'user', '-s', str(keychain), *original)
        if search_list(security) != [str(keychain), *original]:
            raise RuntimeError('Fixture keychain search list was not installed')
        owned_file(keychain)
        if not keychain.is_file():
            raise RuntimeError('Fixture keychain was not created')
        record['prepared'] = True
        save(directory, record)
        return keychain


def recover(directory: Path, owner: str | None = None) -> dict:
    with journal(directory) as (directory, security):
        receipt = directory / RECEIPT
        if receipt.is_symlink():
            raise RuntimeError('Keychain receipt became a symbolic link')
        keychain = directory / KEYCHAIN
        if not receipt.exists():
            # No mutation can precede the first intent. Prove there is also no
            # owned residue; do not invent a snapshot of the original list.
            owned_file(keychain)
            if keychain.exists() or str(keychain) in search_list(security):
                raise RuntimeError('Owned keychain exists without restoration intent; preserving it')
            return {'schema': 1, 'restored': True, 'prepared': False,
                    'not_started': True, 'journal': str(directory)}
        record = json.loads(receipt.read_text())
        info = directory.stat()
        original = record.get('original_search_list')
        if (record.get('schema') != 1 or record.get('owner_uid') != os.getuid()
                or record.get('journal') != str(directory)
                or record.get('directory_identity') != [info.st_dev, info.st_ino]
                or record.get('keychain') != str(keychain)
                or not re.fullmatch(r'[0-9a-f]{32}', record.get('invocation', ''))
                or (owner is not None and record['invocation'] != owner)
                or not isinstance(original, list)
                or any(not isinstance(path, str) or not Path(path).is_absolute() for path in original)
                or len(set(original)) != len(original) or str(keychain) in original):
            raise RuntimeError('Keychain restoration journal has a different ownership identity')
        owned_file(keychain)
        current = search_list(security)
        unchanged_others(current, original, str(keychain))
        if current != original:
            security('list-keychains', '-d', 'user', '-s', *original)
        if search_list(security) != original:
            raise RuntimeError('Original keychain search list did not restore')
        if keychain.exists():
            security('delete-keychain', str(keychain))
        if keychain.exists() or keychain.is_symlink() or search_list(security) != original:
            raise RuntimeError('Keychain fixture cleanup is incomplete')
        record['restored'] = True
        save(directory, record)
        return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare', 'recover'))
    parser.add_argument('--journal-dir', type=Path, required=True)
    parser.add_argument('--account', help='Prepare only: public parity account identifier')
    parser.add_argument('--owner', help='Prepare: unique invocation ID; recover: require this ID when supplied')
    args = parser.parse_args()
    def interrupted(signum: int, _frame: object) -> None:
        raise SystemExit(128 + signum)
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    try:
        if args.operation == 'prepare':
            if not args.account or not args.owner:
                parser.error('--account and --owner are required for prepare; fixture password is read from stdin')
            print(prepare(args.journal_dir, sys.stdin.read(), args.account, args.owner))
        else:
            result = recover(args.journal_dir, args.owner)
            if result.get('not_started'):
                print(json.dumps(result, sort_keys=True))
    except (OSError, ValueError, RuntimeError) as error:
        print('error: ' + str(error), file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
