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
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("fingerprint-release-environment.py")


def load_script() -> ModuleType:
    specification = importlib.util.spec_from_file_location(
        "fingerprint_release_environment", SCRIPT
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"could not load {SCRIPT}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class FingerprintReleaseEnvironmentTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script()

    def test_unknown_environment_input_fails_closed(self) -> None:
        root = Path("/")
        baseline = self.module.fingerprint_environment({"PATH": "/usr/bin"}, root)
        changed = self.module.fingerprint_environment(
            {"PATH": "/usr/bin", "FUTURE_RELEASE_POLICY": "enabled"}, root
        )

        self.assertNotEqual(baseline, changed)

    def test_execution_identity_and_output_paths_do_not_invalidate_proof(self) -> None:
        root = Path("/")
        baseline = self.module.fingerprint_environment(
            {
                "PATH": "/usr/bin",
                "CONTAINER_APP_ROOT": "/tmp/first/app",
                "CONTAINER_RUNTIME_DOCKER_HOST": "unix:///tmp/first/docker.sock",
                "CONTAINER_RUNTIME_DOCKER_SOCKET": "/tmp/first/docker.sock",
                "CONTAINER_RUNTIME_RUN_ID": "first",
                "CONTAINER_SERVICE_NAMESPACE": "example.first",
                "PARITY_EVIDENCE_DIR": "/tmp/first",
                "CODEX_THREAD_ID": "first-task",
            },
            root,
        )
        changed = self.module.fingerprint_environment(
            {
                "PATH": "/usr/bin",
                "CONTAINER_APP_ROOT": "/tmp/second/app",
                "CONTAINER_RUNTIME_DOCKER_HOST": "unix:///tmp/second/docker.sock",
                "CONTAINER_RUNTIME_DOCKER_SOCKET": "/tmp/second/docker.sock",
                "CONTAINER_RUNTIME_RUN_ID": "second",
                "CONTAINER_SERVICE_NAMESPACE": "example.second",
                "PARITY_EVIDENCE_DIR": "/tmp/second",
                "CODEX_THREAD_ID": "second-task",
            },
            root,
        )

        self.assertEqual(baseline, changed)

    def test_staged_init_archive_uses_content_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first" / "retained-init-image.oci.tar"
            second = root / "second" / "retained-init-image.oci.tar"
            first.parent.mkdir()
            second.parent.mkdir()
            first.write_bytes(b"same init image")
            second.write_bytes(b"same init image")

            first_fingerprint = self.module.fingerprint_environment(
                {
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(first),
                    "PATH": "/usr/bin",
                },
                root,
            )
            relocated_fingerprint = self.module.fingerprint_environment(
                {
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(second),
                    "PATH": "/usr/bin",
                },
                root,
            )
            second.write_bytes(b"changed init image")
            changed_fingerprint = self.module.fingerprint_environment(
                {
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(second),
                    "PATH": "/usr/bin",
                },
                root,
            )

            self.assertEqual(first_fingerprint, relocated_fingerprint)
            self.assertNotEqual(relocated_fingerprint, changed_fingerprint)

    def test_staged_builder_archive_uses_content_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first" / "builder-image.oci.tar"
            second = root / "second" / "builder-image.oci.tar"
            first.parent.mkdir()
            second.parent.mkdir()
            first.write_bytes(b"same builder image")
            second.write_bytes(b"same builder image")

            first_fingerprint = self.module.fingerprint_environment(
                {
                    "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR": str(first),
                    "PATH": "/usr/bin",
                },
                root,
            )
            relocated_fingerprint = self.module.fingerprint_environment(
                {
                    "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR": str(second),
                    "PATH": "/usr/bin",
                },
                root,
            )
            second.write_bytes(b"changed builder image")
            changed_fingerprint = self.module.fingerprint_environment(
                {
                    "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR": str(second),
                    "PATH": "/usr/bin",
                },
                root,
            )

            self.assertEqual(first_fingerprint, relocated_fingerprint)
            self.assertNotEqual(relocated_fingerprint, changed_fingerprint)

    def test_relocated_containerization_checkout_uses_content_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            subprocess.run(
                ["git", "-C", str(first), "init", "--quiet"], check=True
            )
            (first / ".gitignore").write_text(".local\nbin\n", encoding="utf-8")
            (first / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            subprocess.run(
                ["git", "-C", str(first), "add", ".gitignore", "tracked.txt"],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(first),
                    "-c",
                    "user.name=Release Test",
                    "-c",
                    "user.email=release-test@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "--quiet",
                    "-m",
                    "fixture",
                ],
                check=True,
            )
            subprocess.run(
                ["git", "clone", "--quiet", "--no-local", str(first), str(second)],
                check=True,
            )
            for checkout in (first, second):
                hawkeye = checkout / ".local" / "bin" / "hawkeye"
                hawkeye.parent.mkdir(parents=True)
                hawkeye.write_bytes(b"same hawkeye")
                hawkeye.chmod(0o755)
                kernel = checkout / "bin" / "vmlinux-arm64"
                kernel.parent.mkdir()
                kernel.write_bytes(b"same kernel")

            def environment(checkout: Path) -> dict[str, str]:
                return {
                    "CONTAINERIZATION_INIT_SOURCE_PATH": str(checkout),
                    "MAKEFLAGS": (
                        "s -- CONTAINERIZATION_STACK_REPO=" + str(checkout)
                    ),
                    "MAKEOVERRIDES": "${-*-command-variables-*-}",
                    "PATH": "/usr/bin:/bin",
                }

            first_fingerprint = self.module.fingerprint_environment(
                environment(first), root
            )
            relocated_fingerprint = self.module.fingerprint_environment(
                environment(second), root
            )
            (second / "bin" / "vmlinux-arm64").write_bytes(b"changed kernel")
            changed_kernel_fingerprint = self.module.fingerprint_environment(
                environment(second), root
            )
            (second / "bin" / "vmlinux-arm64").write_bytes(b"same kernel")
            (second / "tracked.txt").write_text("changed tracked tree\n", encoding="utf-8")
            subprocess.run(
                ["git", "-C", str(second), "add", "tracked.txt"], check=True
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(second),
                    "-c",
                    "user.name=Release Test",
                    "-c",
                    "user.email=release-test@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "--quiet",
                    "-m",
                    "changed fixture",
                ],
                check=True,
            )
            changed_tree_fingerprint = self.module.fingerprint_environment(
                environment(second), root
            )

            self.assertEqual(first_fingerprint, relocated_fingerprint)
            self.assertNotEqual(relocated_fingerprint, changed_kernel_fingerprint)
            self.assertNotEqual(relocated_fingerprint, changed_tree_fingerprint)

    def test_relocated_container_checkout_uses_content_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first"
            second = root / "second"
            first.mkdir()
            subprocess.run(["git", "-C", str(first), "init", "--quiet"], check=True)
            (first / ".gitignore").write_text(".local\n", encoding="utf-8")
            (first / "tracked.txt").write_text("tracked\n", encoding="utf-8")
            subprocess.run(
                ["git", "-C", str(first), "add", ".gitignore", "tracked.txt"],
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(first),
                    "-c",
                    "user.name=Release Test",
                    "-c",
                    "user.email=release-test@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "--quiet",
                    "-m",
                    "fixture",
                ],
                check=True,
            )
            subprocess.run(
                ["git", "clone", "--quiet", "--no-local", str(first), str(second)],
                check=True,
            )
            for checkout in (first, second):
                hawkeye = checkout / ".local" / "bin" / "hawkeye"
                hawkeye.parent.mkdir(parents=True)
                hawkeye.write_bytes(b"same hawkeye")
                hawkeye.chmod(0o755)

            def environment(checkout: Path) -> dict[str, str]:
                return {
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(checkout),
                    "MAKEFLAGS": "s -- CONTAINER_STACK_REPO=" + str(checkout),
                    "MAKEOVERRIDES": "${-*-command-variables-*-}",
                    "PATH": "/usr/bin:/bin",
                }

            first_fingerprint = self.module.fingerprint_environment(
                environment(first), root
            )
            relocated_fingerprint = self.module.fingerprint_environment(
                environment(second), root
            )
            (second / ".local" / "bin" / "hawkeye").write_bytes(
                b"changed hawkeye"
            )
            changed_hawkeye_fingerprint = self.module.fingerprint_environment(
                environment(second), root
            )

            self.assertEqual(first_fingerprint, relocated_fingerprint)
            self.assertNotEqual(
                relocated_fingerprint, changed_hawkeye_fingerprint
            )

    def test_staged_init_archive_preserves_literal_path_semantics(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "retained-init-image.oci.tar"
            archive.write_bytes(b"same init image")

            with patch.dict(os.environ, {"HOME": str(root)}):
                absolute_fingerprint = self.module.fingerprint_environment(
                    {
                        "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(archive),
                        "PATH": "/usr/bin",
                    },
                    root,
                )
                unexpanded_fingerprint = self.module.fingerprint_environment(
                    {
                        "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": (
                            "~/retained-init-image.oci.tar"
                        ),
                        "PATH": "/usr/bin",
                    },
                    root,
                )

            self.assertNotEqual(absolute_fingerprint, unexpanded_fingerprint)

    def test_selected_executable_content_is_part_of_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            normalizer = root / "compose normalizer"
            normalizer.write_bytes(b"first normalizer")
            environment = {
                "CONTAINER_COMPOSE_NORMALIZER": str(normalizer),
                "PATH": "/usr/bin",
            }
            initial = self.module.fingerprint_environment(environment, root)
            normalizer.write_bytes(b"second normalizer")
            changed = self.module.fingerprint_environment(environment, root)

            self.assertNotEqual(initial, changed)

    def test_unknown_selected_file_location_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first" / "future-input"
            second = root / "second" / "future-input"
            first.parent.mkdir()
            second.parent.mkdir()
            first.write_bytes(b"same contents")
            second.write_bytes(b"same contents")

            initial = self.module.fingerprint_environment(
                {"FUTURE_RELEASE_FILE": str(first), "PATH": "/usr/bin"}, root
            )
            relocated = self.module.fingerprint_environment(
                {"FUTURE_RELEASE_FILE": str(second), "PATH": "/usr/bin"}, root
            )

            self.assertNotEqual(initial, relocated)

    def test_make_command_line_selected_file_content_is_part_of_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            normalizer = root / "compose normalizer"
            normalizer.write_bytes(b"first normalizer")
            escaped_normalizer = str(normalizer).replace(" ", "\\ ")
            environment = {
                "MAKEFLAGS": (
                    "s -- CONTAINER_COMPOSE_NORMALIZER=" + escaped_normalizer
                ),
                "MAKEOVERRIDES": "${-*-command-variables-*-}",
                "PATH": "/usr/bin",
            }
            initial = self.module.fingerprint_environment(environment, root)
            normalizer.write_bytes(b"second normalizer")
            changed = self.module.fingerprint_environment(environment, root)

            self.assertNotEqual(initial, changed)

    def test_makeflags_decode_make_escapes_and_preserve_literal_quotes(self) -> None:
        flags, overrides = self.module.parse_make_inputs(
            {
                "MAKEFLAGS": (
                    "s -- BACKSLASH_INPUT=a\\\\b SPACE_INPUT=a\\ b "
                    "SOME_RESULT_INPUT=a'b DOUBLE_QUOTE_INPUT=a\"b"
                )
            }
        )

        self.assertEqual(flags, ("s",))
        self.assertEqual(
            overrides,
            (
                ("BACKSLASH_INPUT", "=", "a\\b"),
                ("SPACE_INPUT", "=", "a b"),
                ("SOME_RESULT_INPUT", "=", "a'b"),
                ("DOUBLE_QUOTE_INPUT", "=", 'a"b'),
            ),
        )

    def test_fresh_runtime_paths_normalize_to_content_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def runtime_environment(name: str) -> dict[str, str]:
                runtime = root / name
                binary = runtime / "candidate" / "bin" / "container"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"immutable container candidate")
                config = runtime / "app" / "xdg-config" / "container" / "config.toml"
                config.parent.mkdir(parents=True)
                config.write_text('[build]\nimage = "fixture"\n', encoding="utf-8")
                candidate_path = str(binary.parent)
                return {
                    "CONTAINER_RUNTIME_CANDIDATE_SHA256": "a" * 64,
                    "CONTAINER_RUNTIME_CLI": str(binary),
                    "CONTAINER_RUNTIME_CLI_SHA256": self.module.sha256_file(binary),
                    "MAKEFLAGS": (
                        "s -- CONTAINER_COMPOSE_CONTAINER=" + str(binary)
                    ),
                    "PATH": os.pathsep.join(
                        (candidate_path, candidate_path, "/usr/bin")
                    ),
                    "XDG_CONFIG_HOME": str(config.parents[1]),
                }

            first_environment = runtime_environment("first-run")
            second_environment = runtime_environment("second-run")

            first = self.module.fingerprint_environment(first_environment, root)
            second = self.module.fingerprint_environment(second_environment, root)

            self.assertEqual(first, second)

    def test_runtime_candidate_or_config_content_invalidates_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "candidate" / "bin" / "container"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"first candidate")
            config = root / "xdg" / "container" / "config.toml"
            config.parent.mkdir(parents=True)
            config.write_text("first config\n", encoding="utf-8")
            environment = {
                "CONTAINER_RUNTIME_CANDIDATE_SHA256": "a" * 64,
                "CONTAINER_RUNTIME_CLI": str(binary),
                "CONTAINER_RUNTIME_CLI_SHA256": self.module.sha256_file(binary),
                "MAKEFLAGS": "s -- CONTAINER_COMPOSE_CONTAINER=" + str(binary),
                "PATH": f"{binary.parent}{os.pathsep}/usr/bin",
                "XDG_CONFIG_HOME": str(config.parents[1]),
            }
            baseline = self.module.fingerprint_environment(environment, root)
            binary.write_bytes(b"second candidate")
            changed_binary = self.module.fingerprint_environment(environment, root)
            config.write_text("second config\n", encoding="utf-8")
            changed_config = self.module.fingerprint_environment(environment, root)

            self.assertNotEqual(baseline, changed_binary)
            self.assertNotEqual(changed_binary, changed_config)

    def test_manifest_never_contains_plaintext_values_or_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selected = root / "secret-named-tool"
            selected.write_bytes(b"tool contents")
            manifest = self.module.environment_manifest(
                {
                    "PATH": "/usr/bin",
                    "SENSITIVE_RELEASE_INPUT": "do-not-disclose",
                    "SELECTED_TOOL": str(selected),
                },
                root,
            )
            encoded = repr(manifest)

            self.assertNotIn("do-not-disclose", encoded)
            self.assertNotIn(str(selected), encoded)
            self.assertIn("SENSITIVE_RELEASE_INPUT", encoded)
            self.assertIn("selected_file_sha256", encoded)

    def test_non_path_values_are_hashed_without_file_probe_failures(self) -> None:
        value = "opaque-" + ("x" * 8192)

        manifest = self.module.environment_manifest(
            {"OPAQUE_RELEASE_INPUT": value, "PATH": "/usr/bin"}, Path("/")
        )

        self.assertIn("OPAQUE_RELEASE_INPUT", manifest["entries"])
        self.assertNotIn(value, repr(manifest))


if __name__ == "__main__":
    unittest.main()
