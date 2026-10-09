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

"""Focused tests for the Compose signal and logging reliability harness."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).parents[2]
HARNESS = REPOSITORY / "Tools" / "parity" / "check-compose-signal-log-reliability.sh"


class PrebuiltUnitContractTests(unittest.TestCase):
    CONTRACTS = (
        (
            "check-compose-rm.sh", "check_container_compose_rm_tests", True, False,
            "rmSkipsRunningContainersUnlessStopIsRequested|rmIgnoresContainersThatDisappearDuringRemoval|"
            "rmSupportsForceAndAnonymousVolumeRemoval|rmConfirmsBeforeStoppingContainers|"
            "rmStopSkipsStopForAlreadyStoppedContainers",
        ),
        (
            "check-compose-lifecycle-hooks.sh", "check_unit_contracts", True, True,
            "ComposeOrchestratorTests/(preStart|upCreatesEveryReplicaBeforeOnePreStart|runForeground|"
            "runReattachesInteractive|interactiveRunDetachKeys|runInterruption)",
        ),
        (
            "check-compose-signal-log-reliability.sh", "check_unit_contracts", False, True,
            "(ComposeBuildInfoTests/|ComposeOrchestratorTests/("
            "attachInteractiveMode|attachOutputOnlyMode|logsPasses|logsAcceptsComposeAllTailValue|"
            "logManagerNormalizesUnreadableDriverErrorsForCompose|logManagerNormalizesPublicUnreadableDriverCategory|"
            "logsTreatsUnreadableDriverHistoryAsEmptyStream|logsContinuesReadableServicesAfterUnreadableDriverHistory|"
            "logsPreservesUnreadableDriverErrorsForFollowRequests))",
        ),
    )

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="compose unit hook ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.record = self.root / "record.json"
        self.helper = REPOSITORY / "Tools/parity/run-unit-contracts.sh"
        self.runner = self.root / "prebuilt test runner"
        for executable in (self.runner, self.root / "swift"):
            executable.write_text(
                '#!/usr/bin/python3\n'
                'import json, os, pathlib, sys\n'
                'pathlib.Path(os.environ["RECORD_FILE"]).write_text(json.dumps({\n'
                '    "program": sys.argv[0], "args": sys.argv[1:],\n'
                '    "runtime": [os.environ.get("CONTAINER_BIN"),\n'
                '                os.environ.get("CONTAINER_COMPOSE_CONTAINER")],\n'
                '}))\n'
                'sys.exit(int(os.environ.get("RECORDER_STATUS", "0")))\n',
                encoding="utf-8",
            )
            executable.chmod(0o755)

    def environment(self, runner: str | None = None) -> dict[str, str]:
        environment = {
            "PATH": f"{self.root}:/usr/bin:/bin",
            "RECORD_FILE": str(self.record),
            "CONTAINER_BIN": "fixture-native-cli",
            "CONTAINER_COMPOSE_CONTAINER": "fixture-compose-backend",
        }
        if runner is not None:
            environment["COMPOSE_PARITY_TEST_RUNNER"] = runner
        return environment

    def run_contract(self, script: str, function: str, environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
        self.record.unlink(missing_ok=True)
        return subprocess.run(
            ["/bin/bash", "-c", 'source "$1"; "$2"', "_", REPOSITORY / "Tools/parity" / script, function],
            cwd=REPOSITORY, env=environment, capture_output=True, text=True, check=False, timeout=20,
        )

    def test_standalone_commands_keep_exact_swiftpm_filters_and_environment(self) -> None:
        for script, function, disable_resolution, clear_runtime, selection in self.CONTRACTS:
            with self.subTest(script=script):
                result = self.run_contract(script, function, self.environment())
                self.assertEqual(result.returncode, 0, result.stderr)
                observed = json.loads(self.record.read_text())
                expected = ["test"] + (["--disable-automatic-resolution"] if disable_resolution else [])
                self.assertEqual(observed["args"], expected + ["--filter", selection])
                self.assertEqual(observed["program"], str(self.root / "swift"))
                self.assertEqual(observed["runtime"], [None, None] if clear_runtime else
                                 ["fixture-native-cli", "fixture-compose-backend"])

    def test_prebuilt_adapter_receives_original_selection_without_swiftpm(self) -> None:
        for script, function, _disable_resolution, clear_runtime, selection in self.CONTRACTS:
            with self.subTest(script=script):
                result = self.run_contract(script, function, self.environment(str(self.runner)))
                self.assertEqual(result.returncode, 0, result.stderr)
                observed = json.loads(self.record.read_text())
                self.assertEqual(observed["program"], str(self.runner))
                self.assertEqual(observed["args"], ["--filter", selection])
                self.assertEqual(observed["runtime"], [None, None] if clear_runtime else
                                 ["fixture-native-cli", "fixture-compose-backend"])

    def test_prebuilt_failure_propagates_without_source_fallback(self) -> None:
        environment = self.environment(str(self.runner))
        environment["RECORDER_STATUS"] = "37"
        for script, function, *_ in self.CONTRACTS:
            with self.subTest(script=script):
                result = self.run_contract(script, function, environment)
                self.assertEqual(result.returncode, 37, result.stderr)
                self.assertEqual(json.loads(self.record.read_text())["program"], str(self.runner))

    def test_invalid_adapter_fails_without_invoking_swift(self) -> None:
        nonexecutable = self.root / "not executable"
        nonexecutable.write_text("fixture")
        for runner in ("relative-runner", str(self.root / "missing"), str(nonexecutable), str(self.root)):
            with self.subTest(runner=runner):
                result = self.run_contract(*self.CONTRACTS[0][:2], self.environment(runner))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.record.exists())

    def test_helper_rejects_missing_duplicate_and_unknown_filters(self) -> None:
        for arguments in ([], ["--filter"], ["--filter", ""],
                          ["--filter", "one", "--filter", "two"], ["--unknown"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [self.helper, *arguments], env=self.environment(str(self.runner)),
                    capture_output=True, text=True, check=False, timeout=20,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(self.record.exists())


class ScaledIdentifierTests(unittest.TestCase):
    def test_accepts_complete_docker_and_container_compose_hostnames(self) -> None:
        for identifiers in (
            ("01ab", "02cd", "03ef"),
            (
                "cc-sl-a-demo-scaled-log-1",
                "cc-sl-a-demo-scaled-log-2",
                "cc-sl-a-demo-scaled-log-3",
            ),
        ):
            with self.subTest(identifiers=identifiers):
                result = self.run_assertion(identifiers, identifiers)

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_duplicate_complete_hostnames(self) -> None:
        identifiers = ("cc-sl-a-demo-scaled-log-1",) * 3

        result = self.run_assertion(identifiers, identifiers)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected 3 unique", result.stderr)

    def run_assertion(
        self,
        foreground_identifiers: tuple[str, ...],
        history_identifiers: tuple[str, ...],
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="compose-scale-identifiers-") as directory:
            root = Path(directory)
            foreground = root / "foreground.log"
            history = root / "history.log"
            foreground.write_text(
                "".join(f"SCALE:{value}\n" for value in foreground_identifiers),
                encoding="utf-8",
            )
            history.write_text(
                "".join(f"SCALE:{value}\n" for value in history_identifiers),
                encoding="utf-8",
            )
            return subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; assert_scaled_identifiers test "$2" "$3"',
                    "_",
                    HARNESS,
                    foreground,
                    history,
                ],
                cwd=REPOSITORY,
                capture_output=True,
                check=False,
                text=True,
            )


class MatchedPackagePathTests(unittest.TestCase):
    def test_make_target_passes_the_local_engine_api_package(self) -> None:
        result = subprocess.run(
            [
                "make",
                "--dry-run",
                "docker-compose-signal-log-reliability-parity",
                "CONTAINER_ENGINE_API_STACK_REPO=/tmp/matched-engine-api",
                "CONTAINER_ENGINE_API_PACKAGE_PATH=/tmp/matched-engine-api",
                "PARITY_CONTAINER_ENGINE_API_REF=fixture-engine-api-ref",
            ],
            cwd=REPOSITORY,
            capture_output=True,
            check=False,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            'CONTAINER_ENGINE_API_PACKAGE_PATH="/tmp/matched-engine-api"',
            result.stdout,
        )
        self.assertIn(
            'CONTAINER_ENGINE_API_REF="fixture-engine-api-ref"',
            result.stdout,
        )
        self.assertIn(
            'CONTAINER_ENGINE_API_STACK_REPO="/tmp/matched-engine-api"',
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
