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

"""Exact owned, home-shared scratch for live Compose parity fixtures."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import stat
import uuid

# Keep room for fixture filenames and Darwin's short Unix socket paths.
ROOT = Path.home() / 'Library/Caches/cfp'
RECEIPT = 'full-suite-scratch.json'


def _root(root: Path) -> Path:
    if root.is_symlink():
        raise RuntimeError('Full-suite scratch root is a symbolic link')
    resolved = root.resolve()
    if root == ROOT and not resolved.is_relative_to(Path.home().resolve()):
        raise RuntimeError('Live scratch must remain inside the shared home directory')
    return resolved


def _write(path: Path, record: dict) -> None:
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def _validate(evidence: Path, record: dict, root: Path) -> Path:
    if (record.get('schema') != 1 or record.get('evidence') != str(evidence.resolve())
            or record.get('root') != str(root) or record.get('uid') != os.getuid()
            or record.get('state') not in ('intent', 'active', 'restored')
            or not isinstance(record.get('nonce'), str)
            or len(record['nonce']) != 32
            or any(character not in '0123456789abcdef' for character in record['nonce'])):
        raise RuntimeError('Full-suite scratch ownership receipt changed')
    path = root / record['nonce']
    if record.get('path') != str(path):
        raise RuntimeError('Full-suite scratch path changed')
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError('Full-suite scratch root is not a directory')
    if path.is_symlink():
        raise RuntimeError('Full-suite scratch was replaced by a link')
    if path.exists():
        info = path.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or (record['state'] != 'intent' and
                    (info.st_dev != record.get('device') or info.st_ino != record.get('inode')))):
            raise RuntimeError('Full-suite scratch directory identity changed')
    elif record['state'] == 'active':
        # A prior cleanup may have removed the directory before the receipt
        # could be advanced. That operation is safe to resume.
        pass
    return path


def create(evidence: Path, *, root: Path = ROOT) -> Path:
    """Record the exact fresh path before test processes may create files."""
    evidence = evidence.resolve(strict=True)
    root = _root(root)
    receipt = evidence / RECEIPT
    if receipt.exists() or receipt.is_symlink() or root.is_symlink():
        raise RuntimeError('Full-suite scratch receipt/root is not fresh')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o022:
        raise RuntimeError('Full-suite scratch root has unsafe ownership or permissions')
    if root == ROOT and root.stat().st_dev != Path.home().stat().st_dev:
        raise RuntimeError('Live scratch must use the internal home filesystem')
    nonce = uuid.uuid4().hex
    path = root / nonce
    record = {'schema': 1, 'evidence': str(evidence), 'root': str(root),
              'path': str(path), 'nonce': nonce, 'uid': os.getuid(), 'state': 'intent'}
    _write(receipt, record)
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        # An existing tree never becomes ours merely because its name collides.
        receipt.unlink()
        raise
    info = path.lstat()
    record.update(state='active', device=info.st_dev, inode=info.st_ino)
    _write(receipt, record)
    return path


def _writable_directories(descriptor: int, device: int) -> None:
    """Permit removal of owned read-only fixtures without following their links."""
    info = os.fstat(descriptor)
    if info.st_uid != os.getuid() or info.st_dev != device:
        raise RuntimeError('Full-suite scratch child ownership/filesystem changed')
    # Tests can leave 0555 directories. Files need no chmod to unlink, which
    # also preserves permissions of any hard-linked files outside the tree.
    os.fchmod(descriptor, stat.S_IMODE(info.st_mode) | stat.S_IRWXU)
    with os.scandir(descriptor) as entries:
        for entry in entries:
            if not entry.is_dir(follow_symlinks=False):
                continue
            child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            try:
                _writable_directories(child, device)
            finally:
                os.close(child)


def restore(evidence: Path, *, root: Path = ROOT) -> dict:
    """Remove only this recorded tree after exclusive command and runtime idle checks."""
    evidence = evidence.resolve(strict=True)
    root = _root(root)
    receipt = evidence / RECEIPT
    if receipt.is_symlink():
        raise RuntimeError('Full-suite scratch receipt is a symbolic link')
    if not receipt.exists():
        return {'restored': True, 'not_started': True}
    record = json.loads(receipt.read_text())
    path = _validate(evidence, record, root)
    if record['state'] == 'restored':
        if path.exists():
            raise RuntimeError('Restored full-suite scratch reappeared')
        return record
    if path.exists():
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(descriptor)
            if (record['state'] != 'intent' and
                    (info.st_dev != record['device'] or info.st_ino != record['inode'])):
                raise RuntimeError('Full-suite scratch directory identity changed')
            _writable_directories(descriptor, info.st_dev)
        finally:
            os.close(descriptor)
        shutil.rmtree(path)
    record['state'] = 'restored'
    _write(receipt, record)
    return record
