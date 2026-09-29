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
from contextlib import nullcontext
import json
from pathlib import Path
import sys
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

    def test_parity_layers_prepare_core_and_plugin_without_runtime_suite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / 'output'
            output.mkdir()
            qualified = {'source_receipt_sha256': 'source', 'release_sha256': 'runtime',
                         'guest_sha256': 'guest', 'builder_sha256': 'builder'}
            local.write(root / 'preflight.json', {'container': qualified})
            assets = {'provenance': {'source_receipt_sha256': 'source'},
                      'assets': {name: {'sha256': name} for name in ('runtime', 'guest', 'builder')}}
            def fetch(destination, hashes):
                destination.mkdir()
                local.write(destination / 'q-assets.json', assets)
                return assets
            for name in ('ComposeCoreTests', 'ComposePluginTests'):
                binary = output / (name + '.xctest/Contents/MacOS') / name
                binary.parent.mkdir(parents=True)
                binary.write_text('test')
                binary.chmod(0o755)
                binary.with_name(name + '.runfiles').mkdir()
            calls = []
            def stage(evidence, name, args, timeout, **kwargs):
                calls.append((name, args))
                log = root / (name + '.log')
                log.write_text(str(output) if name == 'native-test-output-root' else
                               'Retained Compose Bazel invocation: 12345678-1234-1234-1234-123456789abc')
                return {'name': name, 'log': str(log), 'status': 0}
            def chain(evidence, source, invocation):
                local.write(root / 'compiled-sdk-chain.json', {'verified': True})
            with patch.object(local, 'SSD', root), patch.object(local, 'stage', side_effect=stage), \
                 patch.object(local, 'fetch_q_assets', side_effect=fetch), \
                 patch.object(local, 'source_identity', return_value={'commit': 'a' * 40}), \
                 patch.object(local, 'verify_source'), \
                 patch.object(local, 'compiled_sdk_chain', side_effect=chain), \
                 patch.object(local, 'test_workspace', return_value='test-workspace'):
                _, _, _, native = local.run_layers(
                    root, {'commit': 'a' * 40}, {'hashes': {}}, development_parity=True)
            self.assertEqual(set(native), {'ComposeCoreTests', 'ComposePluginTests'})
            build = next(args for name, args in calls if name == 'runtime-tests-build')
            self.assertIn('//:ComposeCoreTests', build)
            self.assertIn('//:ComposePluginTests', build)
            self.assertNotIn('//:ComposeRuntimeTests', build)
            self.assertNotIn('workflow-tools', [name for name, _ in calls])

    def test_parity_case_selection_reuses_original_environment_and_is_not_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / 'evidence'
            evidence.mkdir()
            runner_evidence = evidence / 'runtime'
            runner_evidence.mkdir()
            runner = SimpleNamespace(evidence=runner_evidence, rows=[], runtime_environment={})
            runtime = SimpleNamespace(environment=lambda lane: {})
            native = {}
            for name in ('ComposeCoreTests', 'ComposePluginTests'):
                binary = root / name
                binary.write_text('test')
                binary.chmod(0o755)
                runfiles = binary.with_name(name + '.runfiles')
                runfiles.mkdir()
                native[name] = {'path': str(binary), 'sha256': local.sha(binary),
                                'runfiles': str(runfiles), 'workspace': 'test-workspace'}
            empty = {lane: {kind: {} for kind in ('containers', 'networks', 'volumes', 'images')}
                     for lane in ('candidate', 'docker')}
            commands = []
            def completed(command, *, env, on_start, on_clear, **kwargs):
                commands.append((command, env, kwargs['timeout']))
                on_start({'pid': 100, 'sid': 100, 'birth': 'now',
                          'nonce': env[local.cli_process.CASE_NONCE]})
                on_clear()
                return 0
            with patch.dict(sys.modules, {'fork_benchmark': SimpleNamespace(
                     command_lease=lambda environment: nullcontext(()))}), \
                 patch.object(local.subprocess, 'check_output', return_value=b'/sdk'), \
                 patch.object(local.full_suite_scratch, 'create', return_value=root), \
                 patch.object(local.full_suite, 'snapshot', return_value=empty), \
                 patch.object(local.full_suite, 'assert_namespace_free'), \
                 patch.object(local, 'test_workspace', return_value='test-workspace'), \
                 patch.object(local.cli_process, 'run', side_effect=completed):
                receipt = local.run_original_full_suite(
                    evidence, runner, runtime, root, root, native,
                    lambda *args: self.fail('unexpected inventory command'),
                    development_parity=True)
            self.assertEqual(receipt['target'], 'compose-development-parity')
            self.assertEqual(receipt['parity_cases'], 66)
            self.assertEqual(len(commands), 66)
            self.assertTrue(all(timeout == 600 for _, _, timeout in commands))
            environments = {Path(command[0]).name: env for command, env, _ in commands}
            for name in ('check-compose-image-volumes.sh', 'check-compose-commit.sh',
                         'check-compose-volume-labels.sh'):
                self.assertIn('COMPOSE_FULL_SUITE_MOUNT_JOURNAL', environments[name])
            output_tags = []
            ledger_cases = {case['name']: case for case in json.loads(
                (evidence / 'full-suite/resource-ledger.json').read_text())['cases']}
            for name, prefix in local.full_suite.UNIQUE_OUTPUT_IMAGE_PREFIXES.items():
                script = next(Path(item['script']).name for item in local.full_suite.inventory()
                              if item['target'] == name)
                tag = environments[script]['PARITY_OUTPUT_IMAGE']
                self.assertTrue(tag.startswith(prefix))
                self.assertRegex(tag[len(prefix):], '^[0-9a-f]{32}$')
                self.assertEqual(ledger_cases[name]['owned_image_prefixes'], [tag])
                output_tags.append(tag)
            self.assertEqual(len(set(output_tags)), 2)
            self.assertTrue(all(env['COMPOSE_FULL_SUITE_QUALIFIED'] == '1'
                                for _, env, _ in commands))
            self.assertIn('COMPOSE_PARITY_KEYCHAIN_JOURNAL_DIR',
                          environments['check-compose-build-external-secret.sh'])
            self.assertFalse((evidence / 'full-suite/acceptance.json').exists())
            self.assertFalse((evidence / 'acceptance.json').exists())

    def test_unique_build_image_collision_refused_before_case_ledger(self) -> None:
        for name, prefix in local.full_suite.UNIQUE_OUTPUT_IMAGE_PREFIXES.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                evidence = root / 'evidence'
                evidence.mkdir()
                runner_evidence = evidence / 'runtime'
                runner_evidence.mkdir()
                runner = SimpleNamespace(evidence=runner_evidence, rows=[],
                                         runtime_environment={})
                native = {}
                for target in ('ComposeCoreTests', 'ComposePluginTests'):
                    binary = root / target
                    binary.write_text('test')
                    binary.chmod(0o755)
                    runfiles = binary.with_name(target + '.runfiles')
                    runfiles.mkdir()
                    native[target] = {'path': str(binary), 'sha256': local.sha(binary),
                                      'runfiles': str(runfiles), 'workspace': 'test-workspace'}
                empty = {lane: {kind: {} for kind in ('containers', 'networks',
                                                      'volumes', 'images')}
                         for lane in ('candidate', 'docker')}
                selected = next(item for item in local.full_suite.inventory()
                                if item['target'] == name)
                original_check = local.full_suite.assert_namespace_free
                observed = []
                def collided(baseline, case, fixed_names, fixed_images):
                    tag = next(image for image in fixed_images if image.startswith(prefix))
                    observed.append(tag)
                    baseline['docker']['images'][tag + '|sha256:existing'] = tag
                    return original_check(baseline, case, fixed_names, fixed_images)
                with patch.object(local.subprocess, 'check_output', return_value=b'/sdk'), \
                     patch.object(local.full_suite_scratch, 'create', return_value=root), \
                     patch.object(local.full_suite, 'inventory', return_value=[selected]), \
                     patch.object(local.full_suite, 'snapshot', return_value=empty), \
                     patch.object(local.full_suite, 'assert_namespace_free', side_effect=collided), \
                     patch.object(local, 'test_workspace', return_value='test-workspace'), \
                     patch.object(local.cli_process, 'run', side_effect=AssertionError('case started')):
                    with self.assertRaisesRegex(RuntimeError, 'collides with parity-owned namespace'):
                        local.run_original_full_suite(
                            evidence, runner, SimpleNamespace(environment=lambda lane: {}),
                            root, root, native, lambda *args: self.fail('inventory command'),
                            development_parity=True)
                self.assertEqual(len(observed), 1)
                self.assertTrue(observed[0].startswith(prefix))
                self.assertRegex(observed[0][len(prefix):], '^[0-9a-f]{32}$')
                self.assertFalse((evidence / 'full-suite/resource-ledger.json').exists())
                self.assertEqual(runner.rows, [])

    def test_development_receipt_never_invokes_release_or_benchmark_gates(self) -> None:
        for parity, fail_live in ((False, False), (False, True),
                                  (True, False), (True, True)):
            with self.subTest(parity=parity, fail_live=fail_live), tempfile.TemporaryDirectory() as temporary:
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
                    execute = (local.execute_development_parity if parity else
                               local.execute_development_bridge)
                    if fail_live:
                        with self.assertRaisesRegex(RuntimeError, 'restoration failed'):
                            execute(root)
                    else:
                        execute(root)
                    mode = 'development_parity' if parity else 'development_bridge'
                    self.assertTrue(preflight.call_args.kwargs[mode])
                    self.assertTrue(live.call_args.kwargs[mode])
                target = 'compose-development-parity' if parity else 'compose-development-bridge'
                result = json.loads((root / (target.removeprefix('compose-') + '.json')).read_text())
                self.assertEqual(result['target'], target)
                self.assertEqual(result['passed'], not fail_live)
                self.assertFalse((root/'acceptance.json').exists())


if __name__ == '__main__':
    unittest.main()
