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

"""Focused tests for the IPv6-only runtime fingerprint writer."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
WRITER = ROOT / "Tools" / "parity" / "ipv6_only_runtime_fingerprint.py"
MARKER_NAME = ".container-compose-network-ipv6-only-root"
MARKER_VALUE = "container-compose IPv6-only network certificate v1"
WRITER_SPEC = importlib.util.spec_from_file_location("ipv6_only_runtime_fingerprint", WRITER)
assert WRITER_SPEC is not None and WRITER_SPEC.loader is not None
WRITER_MODULE = importlib.util.module_from_spec(WRITER_SPEC)
sys.modules[WRITER_SPEC.name] = WRITER_MODULE
WRITER_SPEC.loader.exec_module(WRITER_MODULE)


class IPv6OnlyRuntimeFingerprintTests(unittest.TestCase):
    def test_preflight_and_complete_share_exact_inputs(self) -> None:
        fixture = self.fixture()
        preflight = fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json"
        complete = fixture["evidence"] / "FINGERPRINT-COMPLETE.json"

        result = self.invoke(fixture, "preflight", preflight)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.invoke(
            fixture,
            "complete",
            complete,
            preflight=preflight,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        preflight_payload = json.loads(preflight.read_text(encoding="utf-8"))
        complete_payload = json.loads(complete.read_text(encoding="utf-8"))
        self.assertEqual(preflight_payload["phase"], "preflight")
        self.assertEqual(complete_payload["phase"], "complete")
        self.assertEqual(complete_payload["candidate_status"], "passed")
        self.assertEqual(
            preflight_payload["fingerprint"], complete_payload["fingerprint"]
        )
        self.assertEqual(
            preflight_payload["fingerprint"]["sources"]["container"]["dependencies"],
            [
                {
                    "identity": "example-dependency",
                    "kind": "remoteSourceControl",
                    "location": "https://example.invalid/dependency.git",
                    "revision": "0123456789abcdef",
                    "version": "1.2.3",
                }
            ],
        )

    def test_completion_rejects_a_binary_that_drifted_after_preflight(self) -> None:
        fixture = self.fixture()
        preflight = fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json"
        complete = fixture["evidence"] / "FINGERPRINT-COMPLETE.json"

        self.assertEqual(
            self.invoke(fixture, "preflight", preflight).returncode,
            0,
        )
        fixture["binaries"]["compose"].write_text(
            "#!/usr/bin/env bash\necho drifted\n", encoding="utf-8"
        )
        fixture["binaries"]["compose"].chmod(0o755)

        result = self.invoke(
            fixture,
            "complete",
            complete,
            preflight=preflight,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not match its exact preflight", result.stderr)
        self.assertFalse(complete.exists())

    def test_preflight_rejects_an_unowned_evidence_root(self) -> None:
        fixture = self.fixture()
        (fixture["evidence"] / MARKER_NAME).write_text(
            "unrelated root\n", encoding="utf-8"
        )

        result = self.invoke(
            fixture,
            "preflight",
            fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("ownership marker is invalid", result.stderr)

    def test_preflight_rejects_a_missing_evidence_root_marker(self) -> None:
        fixture = self.fixture()
        (fixture["evidence"] / MARKER_NAME).unlink()

        result = self.invoke(
            fixture,
            "preflight",
            fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("ownership marker is unavailable", result.stderr)

    def test_preflight_rejects_an_empty_guest_image_capture(self) -> None:
        fixture = self.fixture()
        fixture["guest_image"].write_text("", encoding="utf-8")

        result = self.invoke(
            fixture,
            "preflight",
            fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("guest init image inspection capture is empty", result.stderr)

    def test_preflight_rejects_a_service_identity_from_another_container_revision(
        self,
    ) -> None:
        fixture = self.fixture()
        fixture["status"].write_text(
            "FIELD                  VALUE\n"
            "apiserver.version      containerization test\n"
            "apiserver.commit       another-revision\n",
            encoding="utf-8",
        )

        result = self.invoke(
            fixture,
            "preflight",
            fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("does not match the selected Container source", result.stderr)

    def test_preflight_rejects_a_service_identity_from_another_containerization_revision(
        self,
    ) -> None:
        fixture = self.fixture()
        fixture["status"].write_text(
            "FIELD                  VALUE\n"
            "apiserver.version      containerization another-revision\n"
            f"apiserver.commit       {self.git_head(fixture['sources']['container'])}\n",
            encoding="utf-8",
        )

        result = self.invoke(
            fixture,
            "preflight",
            fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("does not identify the selected Containerization source", result.stderr)

    def test_preflight_rejects_missing_api_service_identity_fields(self) -> None:
        fixture = self.fixture()
        fixture["status"].write_text(
            "FIELD                  VALUE\nstatus                 running\n",
            encoding="utf-8",
        )

        result = self.invoke(
            fixture,
            "preflight",
            fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json",
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("lacks required identity fields", result.stderr)

    def test_preflight_retains_untracked_source_content(self) -> None:
        fixture = self.fixture()
        (fixture["sources"]["compose"] / "untracked.txt").write_text(
            "untracked source evidence\n", encoding="utf-8"
        )
        preflight = fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json"

        result = self.invoke(fixture, "preflight", preflight)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(preflight.read_text(encoding="utf-8"))
        self.assertNotEqual(
            payload["fingerprint"]["sources"]["compose"]["untracked_sha256"],
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        )

    def test_preflight_refuses_to_overwrite_existing_evidence(self) -> None:
        fixture = self.fixture()
        preflight = fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json"
        self.assertEqual(self.invoke(fixture, "preflight", preflight).returncode, 0)

        result = self.invoke(fixture, "preflight", preflight)

        self.assertEqual(result.returncode, 2)
        self.assertIn("refusing to overwrite", result.stderr)

    def test_completion_rejects_an_unreadable_preflight_record(self) -> None:
        fixture = self.fixture()
        preflight = fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json"
        complete = fixture["evidence"] / "FINGERPRINT-COMPLETE.json"
        self.assertEqual(self.invoke(fixture, "preflight", preflight).returncode, 0)
        preflight.write_text("not JSON\n", encoding="utf-8")

        result = self.invoke(
            fixture,
            "complete",
            complete,
            preflight=preflight,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot read preflight fingerprint", result.stderr)

    def test_parser_rejects_invalid_or_duplicate_assignments(self) -> None:
        with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "invalid source"):
            WRITER_MODULE.parse_assignments(["not-an-assignment"], "source")
        with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "duplicate binary"):
            WRITER_MODULE.parse_assignments(
                ["compose=/tmp/one", "compose=/tmp/two"], "binary"
            )

    def test_source_fingerprint_rejects_a_non_git_path(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ipv6-fingerprint-no-git-") as directory:
            with self.assertRaisesRegex(
                WRITER_MODULE.FingerprintError, "required local Git source"
            ):
                WRITER_MODULE.source_fingerprint(Path(directory))

    def test_low_level_guards_fail_closed_for_invalid_evidence_inputs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ipv6-fingerprint-invalid-") as directory:
            root = Path(directory)
            missing = root / "missing"
            with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "required file"):
                WRITER_MODULE.sha256_file(missing)
            with self.assertRaisesRegex(
                WRITER_MODULE.FingerprintError, "cannot fingerprint Git source"
            ):
                WRITER_MODULE.git_output(root, "rev-parse", "HEAD")
            package = root / "Package.resolved"
            package.write_text("not JSON\n", encoding="utf-8")
            with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "invalid Package"):
                WRITER_MODULE.package_dependencies(package)
            package.write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "no pins"):
                WRITER_MODULE.package_dependencies(package)
            package.write_text('{"pins":[{}]}\n', encoding="utf-8")
            with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "invalid pin"):
                WRITER_MODULE.package_dependencies(package)
            package.write_text(
                '{"pins":[{"identity":"fixture"}]}\n', encoding="utf-8"
            )
            with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "no state"):
                WRITER_MODULE.package_dependencies(package)
            executable = root / "not-executable"
            executable.write_text("fixture\n", encoding="utf-8")
            with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "executable"):
                WRITER_MODULE.binary_fingerprint(executable)
            with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "capture is unavailable"):
                WRITER_MODULE.read_required_output(missing, "fixture")
            with self.assertRaisesRegex(WRITER_MODULE.FingerprintError, "sources are required"):
                WRITER_MODULE.assert_runtime_matches_sources({}, {})

    def test_parser_rejects_phase_invariants(self) -> None:
        fixture = self.fixture()
        preflight = fixture["evidence"] / "FINGERPRINT-PREFLIGHT.json"
        invalid_preflight = self.command(fixture, "preflight", preflight)
        invalid_preflight.extend(("--preflight", str(preflight), "--candidate-status", "passed"))
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                WRITER_MODULE.parse_arguments(invalid_preflight)
        invalid_completion = self.command(fixture, "complete", preflight)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                WRITER_MODULE.parse_arguments(invalid_completion)

    def fixture(self):
        temporary_directory = tempfile.TemporaryDirectory(prefix="ipv6-fingerprint-")
        self.addCleanup(temporary_directory.cleanup)
        root = Path(temporary_directory.name)
        sources = {
            role: self.make_repository(root / role)
            for role in ("compose", "container", "containerization", "engine-api")
        }
        container_head = self.git_head(sources["container"])
        containerization_head = self.git_head(sources["containerization"])
        binaries: dict[str, Path] = {}
        for role in (
            "compose",
            "container-cli",
            "container-apiserver",
            "container-core-images",
            "container-runtime-linux",
        ):
            binary = root / "binaries" / role
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            binary.chmod(0o755)
            binaries[role] = binary
        evidence = root / "evidence"
        evidence.mkdir()
        (evidence / MARKER_NAME).write_text(f"{MARKER_VALUE}\n", encoding="utf-8")
        guest_image = evidence / "guest-image.json"
        guest_image.write_text('{"name":"vminit:container-compose"}\n', encoding="utf-8")
        status = evidence / "system-status.txt"
        status.write_text(
            "FIELD                  VALUE\n"
            "status                 running\n"
            "apiserver.version      containerization@"
            f"{containerization_head}\n"
            f"apiserver.commit       {container_head}\n",
            encoding="utf-8",
        )
        compose_version = evidence / "compose-version.txt"
        compose_version.write_text("container-compose test\n", encoding="utf-8")
        container_version = evidence / "container-version.txt"
        container_version.write_text("container test\n", encoding="utf-8")
        return {
            "sources": sources,
            "binaries": binaries,
            "evidence": evidence,
            "guest_image": guest_image,
            "status": status,
            "compose_version": compose_version,
            "container_version": container_version,
        }

    def invoke(
        self,
        fixture,
        phase: str,
        output: Path,
        *,
        preflight: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = self.command(fixture, phase, output, preflight=preflight)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            returncode = WRITER_MODULE.main(command)
        return subprocess.CompletedProcess(
            command,
            returncode,
            stdout="",
            stderr=stderr.getvalue(),
        )

    def command(
        self,
        fixture,
        phase: str,
        output: Path,
        *,
        preflight: Path | None = None,
    ) -> list[str]:
        command = [
            "--output",
            str(output),
            "--phase",
            phase,
            "--compose-version",
            str(fixture["compose_version"]),
            "--container-version",
            str(fixture["container_version"]),
            "--guest-image-name",
            "vminit:container-compose",
            "--guest-image-inspect",
            str(fixture["guest_image"]),
            "--system-status",
            str(fixture["status"]),
            "--builder-reference",
            "example.invalid/builder@sha256:test",
            "--test-root",
            str(fixture["evidence"]),
            "--root-marker-name",
            MARKER_NAME,
            "--root-marker-value",
            MARKER_VALUE,
        ]
        for role, source in fixture["sources"].items():
            command.extend(("--source", f"{role}={source}"))
        for role, binary in fixture["binaries"].items():
            command.extend(("--binary", f"{role}={binary}"))
        if preflight is not None:
            command.extend(
                ("--preflight", str(preflight), "--candidate-status", "passed")
            )
        return command

    def make_repository(self, path: Path) -> Path:
        path.mkdir()
        (path / "Package.resolved").write_text(
            json.dumps(
                {
                    "pins": [
                        {
                            "identity": "example-dependency",
                            "kind": "remoteSourceControl",
                            "location": "https://example.invalid/dependency.git",
                            "state": {
                                "revision": "0123456789abcdef",
                                "version": "1.2.3",
                            },
                        }
                    ],
                    "version": 3,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (path / "README.md").write_text("fixture\n", encoding="utf-8")
        subprocess.run(["git", "init", "--quiet", str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "add", "."], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(path),
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "--quiet",
                "-m",
                "fixture",
            ],
            check=True,
        )
        return path

    def git_head(self, path: Path) -> str:
        return subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()


if __name__ == "__main__":
    unittest.main()
