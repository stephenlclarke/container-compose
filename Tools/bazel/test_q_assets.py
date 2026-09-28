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

"""No-network checks for released qualified Container asset admission."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

import q_assets


class QAssetTests(unittest.TestCase):
    def fixture(self):
        # Keep the production schema test self-contained; no local Q checkout
        # or unpublished draft is an admission input.
        h = 'a' * 64
        locks = {name: {'sha256': h} for name in q_assets.NAMES}
        bundle = {'schema': 1, 'kind': 'container-qualified-runtime-assets',
                  'qualified_container_source': q_assets.Q,
                  'qualification': {'target': 'bazel-qualify', 'passed': True},
                  'qualified_helpers_sha256': {'helper.py': h},
                  'assets': {
                      name: {'name': q_assets.NAMES[name], 'sha256': h,
                             'source': {'runtime': q_assets.Q, 'guest': q_assets.GUEST,
                                        'builder': q_assets.BUILDER}[name],
                             'reference': name + ':pinned'}
                      for name in ('runtime', 'guest', 'builder')},
                  'guest': {'source': q_assets.GUEST, 'reference': 'guest:pinned'},
                  'builder': {'source': q_assets.BUILDER, 'reference': 'builder:pinned'},
                  'runtime': {'init_archive_sha256': h, 'builder_archive_sha256': h,
                              'kernel_sha256': h, 'package_lock_sha256': h,
                              'init_image': 'guest:pinned', 'builder_image': 'builder:pinned',
                              'workload_image': 'docker.io/library/alpine@sha256:' + h,
                              'payload': {f'bin/file{index}': h for index in range(25)},
                              'notary': {'status': 'Accepted', 'id': 'receipt-id'}},
                  'source_receipt_sha256': {name: h for name in q_assets.RECEIPTS}}
        return bundle, locks

    def test_complete_same_release_provenance(self) -> None:
        bundle, locks = self.fixture()
        q_assets.validate(bundle, locks, bundle['qualified_helpers_sha256'])

    def test_tamper_and_missing_product_fail(self) -> None:
        bundle, locks = self.fixture()
        for mutation in ('archive', 'payload', 'notary', 'guest', 'helper', 'missing'):
            changed = copy.deepcopy(bundle)
            if mutation == 'archive':
                changed['assets']['runtime']['sha256'] = 'b' * 64
            elif mutation == 'payload':
                changed['runtime']['payload']['bin/file0'] = 'invalid'
            elif mutation == 'notary':
                changed['runtime']['notary']['status'] = 'Rejected'
            elif mutation == 'guest':
                changed['guest']['source'] = 'b' * 40
            elif mutation == 'helper':
                changed['qualified_helpers_sha256']['helper.py'] = 'b' * 64
            else:
                del changed['assets']['builder']
            with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                q_assets.validate(changed, locks, bundle['qualified_helpers_sha256'])

    def test_missing_or_mixed_release_locks_fail_before_fetch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            locks_dir = root / 'locks'
            locks_dir.mkdir()
            with self.assertRaises(FileNotFoundError):
                q_assets.fetch_assets(root / 'evidence', {}, locks_dir=locks_dir,
                                      invoke=lambda *_: self.fail('must not fetch'))
            for name in q_assets.NAMES:
                (locks_dir / (name + '.lock.json')).write_text(json.dumps({
                    'schema': 1, 'repository': q_assets.SOURCES[name][0],
                    'tag': 'q153', 'targetCommit': q_assets.SOURCES[name][1],
                    'asset': q_assets.NAMES[name], 'sha256': 'a' * 64}))
            provenance = locks_dir / 'provenance.lock.json'
            record = json.loads(provenance.read_text())
            record['tag'] = 'different'
            provenance.write_text(json.dumps(record))
            with self.assertRaisesRegex(RuntimeError, 'source releases'):
                q_assets.fetch_assets(root / 'evidence', {}, locks_dir=locks_dir,
                                      invoke=lambda *_: self.fail('must not fetch'))


if __name__ == '__main__':
    unittest.main()
