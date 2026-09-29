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

"""Development Bridge selection and non-release receipt regressions."""

from contextlib import ExitStack
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import qualify_local as local


class DevelopmentBridgeTests(unittest.TestCase):
    def test_layers_select_only_optimized_package_and_released_dependencies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            qualified = {'source_receipt_sha256': 'source', 'release_sha256': 'runtime',
                         'guest_sha256': 'guest', 'builder_sha256': 'builder'}
            local.write(root/'preflight.json', {'container': qualified})
            assets = {'provenance': {'source_receipt_sha256': 'source'},
                      'assets': {name: {'sha256': name} for name in ('runtime', 'guest', 'builder')}}
            def fetch(destination, hashes):
                destination.mkdir()
                local.write(destination/'q-assets.json', assets)
                return assets
            calls = []
            def stage(evidence, name, args, timeout, **kwargs):
                calls.append((name, args))
                log = root/(name + '.log')
                log.write_text('Retained Compose Bazel invocation: 12345678-1234-1234-1234-123456789abc')
                return {'name': name, 'log': str(log), 'status': 0}
            def chain(evidence, source, invocation):
                local.write(root/'compiled-sdk-chain.json', {'verified': True})
            with patch.object(local, 'stage', side_effect=stage), \
                 patch.object(local, 'fetch_q_assets', side_effect=fetch), \
                 patch.object(local, 'source_identity', return_value={'commit': 'a'*40}), \
                 patch.object(local, 'verify_source'), \
                 patch.object(local, 'compiled_sdk_chain', side_effect=chain):
                rows, invocation, selected, native = local.run_layers(
                    root, {'commit': 'a'*40}, {'hashes': {}}, development_bridge=True)
            self.assertEqual([name for name, _ in calls],
                             ['source-preflight', 'original-parity-fixtures', 'package'])
            package = calls[-1][1]
            self.assertIn('--config=release', package)
            self.assertIn('--config=prebuilt-container-sdk', package)
            self.assertEqual(native, {})
            self.assertEqual(selected, assets)
            self.assertTrue(invocation)

    def test_development_receipt_never_invokes_release_or_benchmark_gates(self) -> None:
        for fail_live in (False, True):
            with self.subTest(fail_live=fail_live), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for filename in ('preflight.json', 'compiled-sdk-chain.json', 'live.json'):
                    local.write(root/filename, {})
                (root/'q-assets').mkdir()
                local.write(root/'q-assets/q-assets.json', {})
                source = {'commit': 'a'*40, 'dirty': False}
                q = {'modules': {'runtime_benchmark': SimpleNamespace(IDENTITY='test')}, 'hashes': {}}
                with ExitStack() as patches:
                    for name in ('admit_hosted', 'admit_benchmark_reference', 'measure_lane', 'notarize', 'portable_benchmark'):
                        patches.enter_context(patch.object(local, name, side_effect=AssertionError(name)))
                    patches.enter_context(patch.object(local, 'q_modules', return_value=q))
                    preflight = patches.enter_context(patch.object(local, 'preflight', return_value=(source, {})))
                    patches.enter_context(patch.object(local, 'run_layers', return_value=([], 'invocation', {}, {})))
                    patches.enter_context(patch.object(local, 'source_identity', return_value=source))
                    patches.enter_context(patch.object(local, 'verify_source'))
                    patches.enter_context(patch.object(local, 'verify_qualified_helpers'))
                    patches.enter_context(patch.object(local, 'unpack_candidate', return_value=root/'candidate'))
                    patches.enter_context(patch.object(local, 'sign', return_value={'source': source['commit']}))
                    live = patches.enter_context(patch.object(local, 'run_live',
                        side_effect=RuntimeError('restoration failed') if fail_live else None,
                        return_value={'passed': True}))
                    if fail_live:
                        with self.assertRaisesRegex(RuntimeError, 'restoration failed'):
                            local.execute_development_bridge(root)
                    else:
                        local.execute_development_bridge(root)
                    self.assertTrue(preflight.call_args.kwargs['development_bridge'])
                    self.assertTrue(live.call_args.kwargs['development_bridge'])
                result = json.loads((root/'development-bridge.json').read_text())
                self.assertEqual(result['target'], 'compose-development-bridge')
                self.assertEqual(result['passed'], not fail_live)
                self.assertFalse((root/'acceptance.json').exists())


if __name__ == '__main__':
    unittest.main()
