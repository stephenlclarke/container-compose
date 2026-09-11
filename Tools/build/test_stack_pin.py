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

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("stack-pin.py")
SPEC = importlib.util.spec_from_file_location("stack_pin", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
STACK_PIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STACK_PIN)


class StackPinTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name).resolve()
        self.repository = self.create_repository("containerization")
        self.artifact = self.root / "artifacts/cctl"
        self.artifact.parent.mkdir()
        self.artifact.write_text("binary\n", encoding="utf-8")
        self.receipt = self.root / "pins/containerization.json"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def git(self, repository: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["/usr/bin/git", "-C", str(repository), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        )
        return result.stdout.strip()

    def create_repository(self, name: str) -> Path:
        repository = self.root / name
        repository.mkdir()
        self.git(repository, "init", "-q")
        self.git(repository, "config", "user.name", "Test")
        self.git(repository, "config", "user.email", "test@example.invalid")
        (repository / "source.txt").write_text("source\n", encoding="utf-8")
        self.git(repository, "add", "source.txt")
        self.git(repository, "commit", "-q", "-m", "test: create fixture")
        return repository

    def create_pin(
        self,
        repository: Path | None = None,
        receipt: Path | None = None,
        artifact: Path | None = None,
        dependencies: list[Path] | None = None,
    ) -> int:
        repository = repository or self.repository
        receipt = receipt or self.receipt
        artifact = artifact or self.artifact
        arguments = [
            "create",
            "--repository",
            repository.name,
            "--repository-path",
            str(repository),
            "--output",
            str(receipt),
            "--artifact",
            str(artifact),
            "--command-label",
            "swift build --product cctl",
            "--build-contract",
            "a" * 64,
            "--duration-seconds",
            "1.25",
            "--expected-commit",
            self.git(repository, "rev-parse", "HEAD^{commit}"),
            "--expected-tree",
            self.git(repository, "rev-parse", "HEAD^{tree}"),
        ]
        for dependency in dependencies or []:
            arguments.extend(("--dependency", str(dependency)))
        return self.invoke(arguments)

    def invoke(self, arguments: list[str]) -> int:
        with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
            return STACK_PIN.main(arguments)

    def test_create_verify_and_read_source_pin(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        self.assertEqual(
            self.invoke(
                [
                    "verify",
                    "--receipt",
                    str(self.receipt),
                    "--repository",
                    "containerization",
                    "--repository-path",
                    str(self.repository),
                ]
            ),
            0,
        )
        self.assertEqual(
            STACK_PIN.receipt_value(
                STACK_PIN.verify_receipt(self.receipt), "source.commit"
            ),
            self.git(self.repository, "rev-parse", "HEAD"),
        )

    def test_dirty_source_invalidates_pin_without_overwriting_it(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        original = self.receipt.read_bytes()
        (self.repository / "source.txt").write_text("changed\n", encoding="utf-8")

        self.assertEqual(
            self.invoke(["verify", "--receipt", str(self.receipt), "--quiet"]),
            2,
        )
        self.assertEqual(self.create_pin(), 2)
        self.assertEqual(self.receipt.read_bytes(), original)

    def test_changed_artifact_invalidates_pin(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        self.artifact.write_text("replacement\n", encoding="utf-8")
        self.assertEqual(
            self.invoke(["verify", "--receipt", str(self.receipt), "--quiet"]),
            2,
        )

    def test_changed_artifact_mode_invalidates_pin(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        original_mode = stat.S_IMODE(self.artifact.stat().st_mode)
        os.chmod(self.artifact, original_mode ^ stat.S_IXUSR)

        self.assertEqual(
            self.invoke(["verify", "--receipt", str(self.receipt), "--quiet"]),
            2,
        )

    def test_changed_source_remote_invalidates_pin(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        self.git(
            self.repository,
            "remote",
            "add",
            "origin",
            "https://example.invalid/containerization.git",
        )
        self.assertEqual(
            self.invoke(["verify", "--receipt", str(self.receipt), "--quiet"]),
            2,
        )

    def test_exact_source_recreated_at_new_path_reuses_retained_artifact(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        moved = self.root / "recreated/containerization"
        moved.parent.mkdir()
        shutil.copytree(self.repository, moved)
        shutil.rmtree(self.repository)

        self.assertEqual(
            self.invoke(
                [
                    "verify",
                    "--receipt",
                    str(self.receipt),
                    "--repository-path",
                    str(moved),
                    "--quiet",
                ]
            ),
            0,
        )

    def test_dependent_pin_accepts_relocated_parent_and_retained_dependency(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        downstream = self.create_repository("container")
        downstream_artifact = self.root / "artifacts/container"
        downstream_artifact.write_text("container\n", encoding="utf-8")
        downstream_receipt = self.root / "pins/container.json"
        self.assertEqual(
            self.create_pin(
                repository=downstream,
                receipt=downstream_receipt,
                artifact=downstream_artifact,
                dependencies=[self.receipt],
            ),
            0,
        )
        moved = self.root / "relocated/container"
        moved.parent.mkdir()
        downstream.rename(moved)
        shutil.rmtree(self.repository)

        self.assertEqual(
            self.invoke(
                [
                    "verify",
                    "--receipt",
                    str(downstream_receipt),
                    "--repository-path",
                    str(moved),
                    "--quiet",
                ]
            ),
            0,
        )

    def test_retained_only_verification_does_not_require_source_checkout(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        shutil.rmtree(self.repository)
        self.assertEqual(
            self.invoke(
                [
                    "verify",
                    "--receipt",
                    str(self.receipt),
                    "--retained-only",
                    "--quiet",
                ]
            ),
            0,
        )

    def test_materialize_restores_logical_product_layout_without_source(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        shutil.rmtree(self.repository)
        output = self.root / "materialized"

        self.assertEqual(
            self.invoke(
                [
                    "materialize",
                    "--receipt",
                    str(self.receipt),
                    "--output",
                    str(output),
                ]
            ),
            0,
        )
        self.assertEqual((output / "cctl").read_bytes(), self.artifact.read_bytes())

    def test_index_recovers_an_earlier_exact_input_after_latest_pin_changes(self) -> None:
        index = self.root / "pin-index"
        first_commit = self.git(self.repository, "rev-parse", "HEAD")
        first_tree = self.git(self.repository, "rev-parse", "HEAD^{tree}")
        first_arguments = [
            "create",
            "--repository",
            self.repository.name,
            "--repository-path",
            str(self.repository),
            "--output",
            str(self.receipt),
            "--artifact",
            str(self.artifact),
            "--command-label",
            "fixture",
            "--build-contract",
            "a" * 64,
            "--duration-seconds",
            "0",
            "--expected-commit",
            first_commit,
            "--expected-tree",
            first_tree,
            "--index-root",
            str(index),
        ]
        self.assertEqual(self.invoke(first_arguments), 0)
        first_receipt = self.receipt.read_bytes()
        (self.repository / "source.txt").write_text("second\n", encoding="utf-8")
        self.git(self.repository, "add", "source.txt")
        self.git(self.repository, "commit", "-qm", "test: second input")
        second_arguments = first_arguments.copy()
        second_arguments[second_arguments.index(first_commit)] = self.git(
            self.repository, "rev-parse", "HEAD"
        )
        second_arguments[second_arguments.index(first_tree)] = self.git(
            self.repository, "rev-parse", "HEAD^{tree}"
        )
        self.assertEqual(self.invoke(second_arguments), 0)
        self.assertNotEqual(self.receipt.read_bytes(), first_receipt)
        self.git(self.repository, "checkout", "-q", first_commit)

        self.assertEqual(
            self.invoke(
                [
                    "lookup",
                    "--repository",
                    self.repository.name,
                    "--repository-path",
                    str(self.repository),
                    "--build-contract",
                    "a" * 64,
                    "--index-root",
                    str(index),
                    "--output",
                    str(self.receipt),
                ]
            ),
            0,
        )
        self.assertEqual(self.receipt.read_bytes(), first_receipt)

    def test_source_change_during_build_refuses_to_publish_pin(self) -> None:
        arguments = [
            "create",
            "--repository",
            "containerization",
            "--repository-path",
            str(self.repository),
            "--output",
            str(self.receipt),
            "--artifact",
            str(self.artifact),
            "--command-label",
            "swift build --product cctl",
            "--build-contract",
            "a" * 64,
            "--duration-seconds",
            "1.25",
            "--expected-commit",
            "0" * 40,
            "--expected-tree",
            self.git(self.repository, "rev-parse", "HEAD^{tree}"),
        ]
        self.assertEqual(self.invoke(arguments), 2)
        self.assertFalse(self.receipt.exists())

    def test_changed_build_contract_invalidates_pin(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        self.assertEqual(
            self.invoke(
                [
                    "verify",
                    "--receipt",
                    str(self.receipt),
                    "--build-contract",
                    "b" * 64,
                    "--quiet",
                ]
            ),
            2,
        )

    def test_contract_changes_with_configuration_or_controller(self) -> None:
        controller = self.root / "Makefile"
        controller.write_text("all:\n\t@true\n", encoding="utf-8")
        options = STACK_PIN.parse_arguments(
            [
                "contract",
                "--tool",
                "/usr/bin/git",
                "--configuration",
                "debug",
                "--controller",
                str(controller),
            ]
        )
        debug = STACK_PIN.build_contract(options)
        options.configuration = "release"
        release = STACK_PIN.build_contract(options)
        controller.write_text("all:\n\t@false\n", encoding="utf-8")
        changed_controller = STACK_PIN.build_contract(options)

        self.assertRegex(debug, r"^[0-9a-f]{64}$")
        self.assertNotEqual(debug, release)
        self.assertNotEqual(release, changed_controller)

    def test_contract_hashes_only_the_declared_controller_section(self) -> None:
        controller = self.root / "Makefile"
        controller.write_text(
            "unrelated = one\nBEGIN STACK\nbuild = one\nEND STACK\n",
            encoding="utf-8",
        )
        options = STACK_PIN.parse_arguments(
            [
                "contract",
                "--tool",
                "/usr/bin/git",
                "--configuration",
                "debug",
                "--controller-section",
                f"{controller}::BEGIN STACK::END STACK",
            ]
        )
        baseline = STACK_PIN.build_contract(options)
        controller.write_text(
            "unrelated = two\nBEGIN STACK\nbuild = one\nEND STACK\n",
            encoding="utf-8",
        )
        unrelated = STACK_PIN.build_contract(options)
        controller.write_text(
            "unrelated = two\nBEGIN STACK\nbuild = two\nEND STACK\n",
            encoding="utf-8",
        )
        changed = STACK_PIN.build_contract(options)

        self.assertEqual(baseline, unrelated)
        self.assertNotEqual(unrelated, changed)

    def test_contract_rejects_ambiguous_controller_sections(self) -> None:
        controller = self.root / "Makefile"
        controller.write_text("BEGIN STACK\nBEGIN STACK\nEND STACK\n", encoding="utf-8")
        options = STACK_PIN.parse_arguments(
            [
                "contract",
                "--tool",
                "/usr/bin/git",
                "--configuration",
                "debug",
                "--controller-section",
                f"{controller}::BEGIN STACK::END STACK",
            ]
        )

        with self.assertRaisesRegex(STACK_PIN.PinError, "must occur once"):
            STACK_PIN.build_contract(options)

    def test_contract_changes_with_the_effective_go_target(self) -> None:
        go = shutil.which("go")
        self.assertIsNotNone(go)
        assert go is not None
        options = STACK_PIN.parse_arguments(
            [
                "contract",
                "--tool",
                go,
                "--configuration",
                "release",
            ]
        )
        with patch.dict(
            os.environ,
            {"GOOS": "linux", "GOARCH": "amd64", "GOAMD64": "v1"},
            clear=False,
        ):
            baseline = STACK_PIN.build_contract(options)
        with patch.dict(
            os.environ,
            {"GOOS": "linux", "GOARCH": "amd64", "GOAMD64": "v3"},
            clear=False,
        ):
            changed = STACK_PIN.build_contract(options)

        self.assertRegex(baseline, r"^[0-9a-f]{64}$")
        self.assertNotEqual(baseline, changed)

    def test_go_contract_is_repeatable(self) -> None:
        go = shutil.which("go")
        self.assertIsNotNone(go)
        assert go is not None
        options = STACK_PIN.parse_arguments(
            [
                "contract",
                "--tool",
                go,
                "--configuration",
                "release",
            ]
        )

        contracts = {STACK_PIN.build_contract(options) for _ in range(3)}

        self.assertEqual(len(contracts), 1)

    def test_contract_changes_with_the_effective_swift_sdk(self) -> None:
        swift = self.root / "swift"
        swift.write_text("#!/bin/sh\nprintf 'Swift version test\\n'\n", encoding="utf-8")
        swift.chmod(0o755)
        options = STACK_PIN.parse_arguments(
            [
                "contract",
                "--tool",
                str(swift),
                "--configuration",
                "release",
            ]
        )
        with patch.object(
            STACK_PIN,
            "effective_swift_build_environment",
            return_value={"sdk": {"path": "/SDKs/MacOSX26.5.sdk"}},
        ):
            baseline = STACK_PIN.build_contract(options)
        with patch.object(
            STACK_PIN,
            "effective_swift_build_environment",
            return_value={"sdk": {"path": "/SDKs/MacOSX26.6.sdk"}},
        ):
            changed = STACK_PIN.build_contract(options)

        self.assertNotEqual(baseline, changed)

    def test_swift_contract_fingerprints_the_selected_macos_sdk(self) -> None:
        swift = self.root / "swift"
        swift.write_text(
            """#!/bin/sh
if [ "${1:-}" = "-print-target-info" ]; then
  printf '%s\n' '{"target":{"triple":"arm64-apple-macosx26.0"}}'
else
  printf '%s\n' 'Swift version test'
fi
""",
            encoding="utf-8",
        )
        swift.chmod(0o755)
        developer = self.root / "Xcode/Contents/Developer"
        developer.mkdir(parents=True)
        sdk = self.root / "MacOSX.sdk"
        metadata = sdk / "SDKSettings.json"
        metadata.parent.mkdir()
        metadata.write_text('{"Version":"26.0"}\n', encoding="utf-8")
        options = STACK_PIN.parse_arguments(
            [
                "contract",
                "--tool",
                str(swift),
                "--configuration",
                "release",
            ]
        )

        with (
            patch.object(STACK_PIN.platform, "system", return_value="Darwin"),
            patch.dict(
                os.environ,
                {"DEVELOPER_DIR": str(developer), "SDKROOT": str(sdk)},
                clear=False,
            ),
        ):
            baseline = STACK_PIN.build_contract(options)
            metadata.write_text('{"Version":"26.1"}\n', encoding="utf-8")
            changed = STACK_PIN.build_contract(options)

        self.assertNotEqual(baseline, changed)

    def test_swift_environment_rejects_bad_target_and_unidentified_sdk(self) -> None:
        swift = self.root / "swift"
        swift.write_text("binary\n", encoding="utf-8")
        developer = self.root / "Developer"
        developer.mkdir()
        sdk = self.root / "MacOSX.sdk"
        sdk.mkdir()
        with (
            patch.object(STACK_PIN.platform, "system", return_value="Darwin"),
            patch.dict(
                os.environ,
                {"DEVELOPER_DIR": str(developer), "SDKROOT": str(sdk)},
                clear=False,
            ),
            patch.object(
                STACK_PIN, "checked_output", return_value='{"target":{}}'
            ),
        ):
            with self.assertRaisesRegex(STACK_PIN.PinError, "no identity metadata"):
                STACK_PIN.effective_swift_build_environment(swift)
        with patch.object(STACK_PIN, "checked_output", return_value="not-json"):
            with self.assertRaisesRegex(STACK_PIN.PinError, "not valid JSON"):
                STACK_PIN.effective_swift_build_environment(swift)
        with patch.object(STACK_PIN, "checked_output", return_value="[]"):
            with self.assertRaisesRegex(STACK_PIN.PinError, "malformed"):
                STACK_PIN.effective_swift_build_environment(swift)

    def test_dependency_change_invalidates_downstream_pin(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        downstream = self.create_repository("container")
        downstream_artifact = self.root / "artifacts/container"
        downstream_artifact.parent.mkdir(exist_ok=True)
        downstream_artifact.write_text("container\n", encoding="utf-8")
        downstream_receipt = self.root / "pins/container.json"
        self.assertEqual(
            self.create_pin(
                repository=downstream,
                receipt=downstream_receipt,
                artifact=downstream_artifact,
                dependencies=[self.receipt],
            ),
            0,
        )

        dependency = json.loads(self.receipt.read_text(encoding="utf-8"))
        dependency["build"]["command"] = "tampered"
        self.receipt.write_text(json.dumps(dependency), encoding="utf-8")
        self.assertEqual(
            self.invoke(
                ["verify", "--receipt", str(downstream_receipt), "--quiet"]
            ),
            2,
        )

    def test_bundle_rejects_duplicate_repository_pins(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        bundle = self.root / "pins/stack.json"
        self.assertEqual(
            self.invoke(
                [
                    "bundle",
                    "--output",
                    str(bundle),
                    "--pin",
                    str(self.receipt),
                    "--pin",
                    str(self.receipt),
                ]
            ),
            2,
        )
        self.assertFalse(bundle.exists())

    def test_bundle_verification_rejects_changed_component(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        bundle = self.root / "pins/stack.json"
        self.assertEqual(
            self.invoke(
                [
                    "bundle",
                    "--output",
                    str(bundle),
                    "--pin",
                    str(self.receipt),
                ]
            ),
            0,
        )
        self.assertEqual(
            self.invoke(
                [
                    "verify-bundle",
                    "--bundle",
                    str(bundle),
                    "--repository",
                    "containerization",
                    "--quiet",
                ]
            ),
            0,
        )
        self.assertEqual(
            self.invoke(
                [
                    "verify-bundle",
                    "--bundle",
                    str(bundle),
                    "--repository",
                    "containerization",
                    "--repository",
                    "container",
                    "--quiet",
                ]
            ),
            2,
        )

        self.artifact.write_text("replacement\n", encoding="utf-8")
        self.assertEqual(
            self.invoke(["verify-bundle", "--bundle", str(bundle), "--quiet"]),
            2,
        )

    def test_output_symlink_is_rejected(self) -> None:
        destination = self.root / "outside.json"
        destination.write_text("preserve\n", encoding="utf-8")
        self.receipt.parent.mkdir()
        self.receipt.symlink_to(destination)
        self.assertEqual(self.create_pin(), 2)
        self.assertEqual(destination.read_text(encoding="utf-8"), "preserve\n")

    def test_receipt_and_bundle_input_symlinks_are_rejected(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        receipt_link = self.root / "receipt-link.json"
        receipt_link.symlink_to(self.receipt)
        self.assertEqual(
            self.invoke(["verify", "--receipt", str(receipt_link), "--quiet"]),
            2,
        )

        bundle = self.root / "pins/stack.json"
        self.assertEqual(
            self.invoke(
                [
                    "bundle",
                    "--output",
                    str(bundle),
                    "--pin",
                    str(self.receipt),
                ]
            ),
            0,
        )
        bundle_link = self.root / "bundle-link.json"
        bundle_link.symlink_to(bundle)
        self.assertEqual(
            self.invoke(
                ["verify-bundle", "--bundle", str(bundle_link), "--quiet"]
            ),
            2,
        )

    def test_malformed_build_metadata_is_rejected_after_digest_validation(self) -> None:
        self.assertEqual(self.create_pin(), 0)
        receipt = json.loads(self.receipt.read_text(encoding="utf-8"))
        receipt["build"]["duration_seconds"] = float("inf")
        receipt["receipt_sha256"] = STACK_PIN.payload_digest(receipt)
        self.receipt.write_text(json.dumps(receipt), encoding="utf-8")
        self.assertEqual(
            self.invoke(["verify", "--receipt", str(self.receipt), "--quiet"]),
            2,
        )


if __name__ == "__main__":
    unittest.main()
