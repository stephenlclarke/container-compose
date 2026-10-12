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

"""No-runtime checks for the original prebuilt Swift parity filters."""

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prebuilt_parity_tests as prebuilt

ROOT = Path(__file__).resolve().parents[2]


class PrebuiltParityTests(unittest.TestCase):
    def test_filters_are_exact_original_script_selections(self) -> None:
        for script, pattern in (('rm', prebuilt.RM_FILTER),
                                ('lifecycle-hooks', prebuilt.LIFECYCLE_FILTER),
                                ('signal-log-reliability', prebuilt.SIGNAL_FILTER)):
            source = (ROOT / 'Tools/parity' / ('check-compose-' + script + '.sh')).read_text()
            self.assertIn("--filter '" + pattern + "'", source)

    def fixture(self, root: Path, result: str = 'Test run with 2 tests passed after 0.01 seconds') -> dict:
        environment = {}
        for profile in ('core', 'plugin'):
            binary = root / (profile + '-tests')
            binary.write_text('#!/bin/sh\nprintf "%s\\n" "$TESTBRIDGE_TEST_ONLY"\nprintf "%s\\n" '
                              + repr(result) + '\n')
            binary.chmod(0o700)
            runfiles = binary.with_name(binary.name + '.runfiles')
            (runfiles / '_main' / (binary.name + '.xctest')).mkdir(parents=True)
            environment['COMPOSE_PREBUILT_' + profile.upper() + '_TEST'] = str(binary)
        return environment

    def test_each_original_filter_routes_to_matching_prebuilt_suite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = self.fixture(Path(temporary))
            with patch.object(prebuilt, 'macos_sdkroot', return_value='/active/SDKs/MacOSX.sdk'):
                self.assertEqual(prebuilt.run_filter(prebuilt.RM_FILTER, environment), {'core': 2})
                self.assertEqual(prebuilt.run_filter(prebuilt.LIFECYCLE_FILTER, environment), {'core': 2})
                self.assertEqual(prebuilt.run_filter(prebuilt.SIGNAL_FILTER, environment),
                                 {'core': 2, 'plugin': 2})

    def test_resolves_sdk_from_active_developer_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            developer = Path(temporary) / 'Xcode/Contents/Developer'
            sdk = developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
            sdk.mkdir(parents=True)
            with patch.object(prebuilt.subprocess, 'check_output',
                              side_effect=[str(developer) + '\n', str(sdk) + '\n']) as check:
                self.assertEqual(prebuilt.macos_sdkroot({}), str(sdk.resolve()))
            self.assertEqual([call.args[0] for call in check.call_args_list], [
                ['/usr/bin/xcode-select', '-p'],
                ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'],
            ])

    def test_rejects_sdk_outside_active_developer_or_unavailable_sdk(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            developer = root / 'Xcode/Contents/Developer'
            external_sdk = root / 'other/SDKs/MacOSX.sdk'
            developer.mkdir(parents=True)
            external_sdk.mkdir(parents=True)
            with patch.object(prebuilt.subprocess, 'check_output',
                              return_value=str(external_sdk)):
                with self.assertRaisesRegex(RuntimeError, 'outside the active developer directory'):
                    prebuilt.macos_sdkroot({'DEVELOPER_DIR': str(developer)})
            with patch.object(prebuilt.subprocess, 'check_output', side_effect=FileNotFoundError):
                with self.assertRaisesRegex(RuntimeError, 'Could not resolve'):
                    prebuilt.macos_sdkroot({'DEVELOPER_DIR': str(developer)})

    def test_filter_passes_derived_sdkroot_even_when_environment_omits_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = self.fixture(Path(temporary))
            with (patch.object(prebuilt, 'macos_sdkroot', return_value='/active/SDKs/MacOSX.sdk') as resolve,
                  patch.object(prebuilt.subprocess, 'run', wraps=prebuilt.subprocess.run) as run):
                self.assertEqual(prebuilt.run_filter(prebuilt.RM_FILTER, environment), {'core': 2})
            resolve.assert_called_once_with(environment)
            self.assertEqual(len(run.call_args_list), 1)
            self.assertEqual(run.call_args.kwargs['env']['SDKROOT'], '/active/SDKs/MacOSX.sdk')

    def test_unknown_or_zero_match_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = self.fixture(Path(temporary), 'Test run with 0 tests passed after 0.01 seconds')
            with self.assertRaisesRegex(ValueError, 'not one of'):
                prebuilt.run_filter('.*', environment)
            with patch.object(prebuilt, 'macos_sdkroot', return_value='/active/SDKs/MacOSX.sdk'):
                with self.assertRaisesRegex(RuntimeError, 'matched no'):
                    prebuilt.run_filter(prebuilt.RM_FILTER, environment)

    def test_workspace_requires_exact_binary_and_declared_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runfiles = root / 'test.runfiles'
            bundle = runfiles / '_main' / 'ComposeRuntimeFixtures.bundle'
            (runfiles / '_main' / 'ComposeRuntimeTests.xctest').mkdir(parents=True)
            (bundle / 'Contents/Resources/Fixtures').mkdir(parents=True)
            self.assertEqual(prebuilt.test_workspace(runfiles, 'ComposeRuntimeTests',
                                                    'ComposeRuntimeFixtures.bundle'), '_main')
            (runfiles / 'other' / 'ComposeRuntimeTests.xctest').mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, 'one workspace'):
                prebuilt.test_workspace(runfiles, 'ComposeRuntimeTests')
            (runfiles / 'other' / 'ComposeRuntimeTests.xctest').rmdir()
            (bundle / 'Contents/Resources/Fixtures').rmdir()
            with self.assertRaisesRegex(ValueError, 'fixture bundle is missing'):
                prebuilt.test_workspace(runfiles, 'ComposeRuntimeTests',
                                       'ComposeRuntimeFixtures.bundle')


if __name__ == '__main__':
    unittest.main()
