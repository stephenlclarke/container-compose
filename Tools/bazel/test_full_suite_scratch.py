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

"""Focused ownership and interruption checks for home-shared parity scratch."""

import json
from pathlib import Path
import tempfile
import unittest

import full_suite_scratch as scratch


class ScratchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.evidence = self.base / 'evidence'
        self.evidence.mkdir()
        self.root = self.base / 'shared'

    def test_create_restore_and_reentry_preserve_other_trees(self) -> None:
        owned = scratch.create(self.evidence, root=self.root)
        other = self.root / 'unrelated'
        other.mkdir()
        (other / 'keep').write_text('keep')
        self.assertEqual(owned.stat().st_mode & 0o777, 0o700)
        (owned / 'secret-fixture').write_text('private')
        result = scratch.restore(self.evidence, root=self.root)
        self.assertEqual(result['state'], 'restored')
        self.assertFalse(owned.exists())
        self.assertEqual((other / 'keep').read_text(), 'keep')
        self.assertEqual(scratch.restore(self.evidence, root=self.root), result)

    def test_link_or_replaced_directory_refuses_without_touching_target(self) -> None:
        owned = scratch.create(self.evidence, root=self.root)
        target = self.base / 'target'
        target.mkdir()
        (target / 'keep').write_text('keep')
        owned.rmdir()
        owned.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'link'):
            scratch.restore(self.evidence, root=self.root)
        self.assertEqual((target / 'keep').read_text(), 'keep')

    def test_intent_crash_and_removed_before_receipt_write_resume(self) -> None:
        owned = scratch.create(self.evidence, root=self.root)
        receipt = self.evidence / scratch.RECEIPT
        record = json.loads(receipt.read_text())
        record['state'] = 'intent'
        record.pop('device')
        record.pop('inode')
        receipt.write_text(json.dumps(record))
        self.assertEqual(scratch.restore(self.evidence, root=self.root)['state'], 'restored')
        self.assertFalse(owned.exists())
        record['state'] = 'active'
        receipt.write_text(json.dumps(record))
        self.assertEqual(scratch.restore(self.evidence, root=self.root)['state'], 'restored')

    def test_wrong_evidence_or_inode_refuses(self) -> None:
        scratch.create(self.evidence, root=self.root)
        receipt = self.evidence / scratch.RECEIPT
        record = json.loads(receipt.read_text())
        record['inode'] += 1
        receipt.write_text(json.dumps(record))
        with self.assertRaisesRegex(RuntimeError, 'identity'):
            scratch.restore(self.evidence, root=self.root)
        record['inode'] -= 1
        record['evidence'] = str(self.base / 'another')
        receipt.write_text(json.dumps(record))
        with self.assertRaisesRegex(RuntimeError, 'ownership'):
            scratch.restore(self.evidence, root=self.root)

    def test_partial_recursive_removal_is_recoverable(self) -> None:
        owned = scratch.create(self.evidence, root=self.root)
        (owned / 'first').write_text('first')
        (owned / 'second').write_text('second')
        (owned / 'first').unlink()
        self.assertEqual(scratch.restore(self.evidence, root=self.root)['state'], 'restored')


if __name__ == '__main__':
    unittest.main()
