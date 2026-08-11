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

import hashlib
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / "scripts" / "run-with-container-runtime.sh"
LOCK_SCRIPT = ROOT / "Tools" / "ci" / "container-runtime-lock.sh"
DEFAULT_INIT_IMAGE = "vminit:container-compose"


class RunWithContainerRuntimeTest(unittest.TestCase):
    @staticmethod
    def runtime_environment() -> dict[str, str]:
        environment = os.environ.copy()
        for variable in (
            "CONTAINER_APP_ROOT",
            "CONTAINER_RUNTIME_APP_ROOT",
            "CONTAINER_RUNTIME_DOCKER_HOST",
            "CONTAINER_RUNTIME_DOCKER_SOCKET",
            "CONTAINER_RUNTIME_INIT_BLOCK_REPO",
            "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE",
            "CONTAINER_RUNTIME_INIT_IMAGE_TAR",
            "CONTAINER_RUNTIME_BOOTSTRAP_IMAGE_TAR",
            "CONTAINER_RUNTIME_BUILDER_IMAGE",
            "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR",
            "CONTAINER_RUNTIME_SERVICE_NAMESPACE",
            "CONTAINER_RUNTIME_STOP_HELPER",
            "CONTAINER_SERVICE_NAMESPACE",
            "CONTAINERIZATION_INIT_SOURCE_PATH",
            "CONTAINERIZATION_INIT_BUILD_SCRATCH_ROOT",
            "CONTAINER_COMPOSE_INIT_IMAGE",
            "CONTAINER_RUNTIME_LOCK_FILE",
            "CONTAINER_RUNTIME_LOCK_HELD",
            "CONTAINER_RUNTIME_LOCK_KEEPER_PID",
        ):
            environment.pop(variable, None)
        return environment

    @staticmethod
    def write_fake_container(
        path: Path,
        body: str = "",
        status_socket: str | None = None,
    ) -> None:
        status_socket = status_socket or "${CONTAINER_RUNTIME_DOCKER_SOCKET:?}"
        path.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            'if [[ "$*" == "system status --format json" ]]; then\n'
            f'  printf \'{{"engineSocket":"%s"}}\\n\' "{status_socket}"\n'
            "  exit 1\n"
            "fi\n"
            'printf "%s\\n" "$*" >>"${CONTAINER_TEST_LOG:?}"\n'
            + body,
            encoding="utf-8",
        )
        path.chmod(0o755)

    @staticmethod
    def create_containerization_source(root: Path) -> tuple[Path, str]:
        source = root / "containerization-source"
        (source / "vminitd").mkdir(parents=True)
        (source / ".gitignore").write_text(
            ".build/\nvminitd/.build/\n",
            encoding="utf-8",
        )
        (source / "Package.swift").write_text(
            "// exact staged source fixture\n",
            encoding="utf-8",
        )
        (source / "vminitd" / "Makefile").write_text(
            "# source fixture\n",
            encoding="utf-8",
        )
        for command in (
            ["git", "init", "--quiet", str(source)],
            ["git", "-C", str(source), "config", "user.email", "test@example.com"],
            ["git", "-C", str(source), "config", "user.name", "Container Test"],
            ["git", "-C", str(source), "add", "."],
            ["git", "-C", str(source), "commit", "--quiet", "-m", "fixture"],
        ):
            subprocess.run(command, check=True, capture_output=True, text=True)
        source_head = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return source, source_head

    def test_rejects_invalid_runtime_inputs_before_service_side_effects(
        self,
    ) -> None:
        cases = [
            (
                "builder image without archive",
                {"CONTAINER_RUNTIME_BUILDER_IMAGE": "local/builder:test"},
                "CONTAINER_RUNTIME_BUILDER_IMAGE and "
                "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR must be set together",
            ),
            (
                "missing init archive",
                {"CONTAINER_RUNTIME_INIT_IMAGE_TAR": "/missing/vminit.tar"},
                "container runtime init image archive does not exist",
            ),
            (
                "runtime root exceeds provider socket limit",
                {"CONTAINER_RUNTIME_APP_ROOT": "/tmp/" + "x" * 80},
                "container runtime app root exceeds the provider Unix socket path limit",
            ),
        ]
        for name, overrides, expected_error in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary_directory:
                temporary_root = Path(temporary_directory)
                container_log = temporary_root / "container.log"
                fake_container = temporary_root / "container"
                self.write_fake_container(fake_container)
                environment = self.runtime_environment()
                environment.update(
                    {
                        "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                        "CONTAINER_TEST_LOG": str(container_log),
                        **overrides,
                    }
                )

                result = subprocess.run(
                    [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                    cwd=ROOT,
                    env=environment,
                    capture_output=True,
                    text=True,
                )

                self.assertEqual(result.returncode, 2)
                self.assertIn(expected_error, result.stderr)
                self.assertFalse(container_log.exists())

    def test_scopes_candidate_namespace_and_exports_public_socket(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            contract_environment = temporary_root / "candidate-environment"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "CONTRACT_ENVIRONMENT": str(contract_environment),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "%s\\n%s\\n%s\\n%s\\n" '
                    '"$CONTAINER_SERVICE_NAMESPACE" "$CONTAINER_APP_ROOT" '
                    '"$CONTAINER_RUNTIME_DOCKER_SOCKET" '
                    '"$CONTAINER_RUNTIME_DOCKER_HOST" >"$CONTRACT_ENVIRONMENT"',
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            namespace_digest = hashlib.sha256(
                f"{app_root}:{os.getuid()}".encode("utf-8")
            ).hexdigest()[:24]
            namespace = (
                "io.github.stephenlclarke.container-compose.runtime."
                f"{namespace_digest}"
            )
            socket_digest = hashlib.sha256(namespace.encode("utf-8")).hexdigest()[:24]
            socket = (
                f"/tmp/container-engine-{os.getuid()}-{socket_digest}/docker.sock"
            )
            self.assertEqual(
                contract_environment.read_text(encoding="utf-8").splitlines(),
                [namespace, str(app_root), socket, f"unix://{socket}"],
            )
            self.assertIn("system start", container_log.read_text(encoding="utf-8"))

    def test_rejects_legacy_global_stop_helper_before_service_side_effects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            helper_marker = temporary_root / "legacy-helper-ran"
            helper = temporary_root / "legacy-stop-helper"
            helper.write_text(
                "#!/usr/bin/env bash\n"
                f'touch "{helper_marker}"\n',
                encoding="utf-8",
            )
            helper.chmod(0o755)
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STOP_HELPER": str(helper),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("unsafe with isolated candidates", result.stderr)
            self.assertFalse(helper_marker.exists())
            self.assertFalse(container_log.exists())

    def test_rejects_binary_without_isolated_status_socket_before_service_side_effects(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                status_socket=f"/tmp/container-engine-{os.getuid()}/docker.sock",
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("did not select the isolated Docker socket", result.stderr)
            self.assertFalse(container_log.exists())

    def test_rejects_dirty_init_source_before_service_side_effects(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            source, _ = self.create_containerization_source(temporary_root)
            (source / "Package.swift").write_text(
                "// dirty source fixture\n",
                encoding="utf-8",
            )
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            (init_repo / "Makefile").write_text("init-block:\n\t@true\n", encoding="utf-8")
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINERIZATION_INIT_SOURCE_PATH": str(source),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("checkout must be clean before staging", result.stderr)
            self.assertFalse(container_log.exists())

    def test_stages_clean_init_source_and_separate_build_scratch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            source, source_head = self.create_containerization_source(temporary_root)
            (source / ".build" / "ModuleCache").mkdir(parents=True)
            (source / ".build" / "ModuleCache" / "stale.pcm").touch()
            (source / "vminitd" / ".build" / "ModuleCache").mkdir(
                parents=True
            )
            (source / "vminitd" / ".build" / "ModuleCache" / "stale.pcm").touch()

            app_root = temporary_root / "app-root"
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            source_stage_log = temporary_root / "source-stage.log"
            source_stage_head = temporary_root / "source-stage-head"
            (init_repo / "Makefile").write_text(
                "init-block:\n"
                '\t@printf "%s\\n%s\\n" "$(CONTAINERIZATION_INIT_SOURCE_PATH)" "$(CONTAINERIZATION_INIT_BUILD_SCRATCH_ROOT)" >"$(SOURCE_STAGE_LOG)"\n'
                '\t@git -C "$(CONTAINERIZATION_INIT_SOURCE_PATH)" rev-parse HEAD >"$(SOURCE_STAGE_HEAD)"\n'
                '\t@test ! -e "$(CONTAINERIZATION_INIT_SOURCE_PATH)/.build"\n'
                '\t@test ! -e "$(CONTAINERIZATION_INIT_SOURCE_PATH)/vminitd/.build"\n',
                encoding="utf-8",
            )
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINERIZATION_INIT_SOURCE_PATH": str(source),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "SOURCE_STAGE_LOG": str(source_stage_log),
                    "SOURCE_STAGE_HEAD": str(source_stage_head),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            staged_source = app_root / "source-inputs" / "containerization"
            scratch_root = app_root / "source-build-cache"
            self.assertEqual(
                source_stage_log.read_text(encoding="utf-8").splitlines(),
                [str(staged_source), str(scratch_root)],
            )
            self.assertEqual(
                source_stage_head.read_text(encoding="utf-8").strip(), source_head
            )
            self.assertTrue((staged_source / ".git").is_dir())
            self.assertFalse((staged_source / ".build").exists())
            self.assertFalse((staged_source / "vminitd" / ".build").exists())
            self.assertTrue(scratch_root.is_dir())
            fingerprint = (
                app_root / "fingerprints" / "containerization-init-source.txt"
            ).read_text(encoding="utf-8")
            self.assertIn(f"source_root={source.resolve()}", fingerprint)
            self.assertIn(f"source_head={source_head}", fingerprint)
            self.assertIn(f"staged_source_root={staged_source}", fingerprint)
            self.assertIn(f"build_scratch_root={scratch_root}", fingerprint)

    def test_configures_default_init_image_only_after_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            container_log = temporary_root / "container.log"
            init_log = temporary_root / "init.log"
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_container = fake_bin / "container"
            self.write_fake_container(fake_container)
            (init_repo / "Makefile").write_text(
                "init-block:\n"
                '\t@test ! -e "$(CONFIG_TEST_PATH)"\n'
                '\t@test "$(BASH_ENV)" = "/dev/null"\n'
                '\t@test "$$(command -v container)" = "$(EXPECTED_CONTAINER_CLI)"\n'
                '\t@test "$(CONTAINER_INIT_CLI)" = "$(EXPECTED_CONTAINER_CLI)"\n'
                '\t@printf "%s\\n" "$(CONTAINER_INIT_IMAGE_NAME)" >"$(INIT_TEST_LOG)"\n',
                encoding="utf-8",
            )
            config_path = app_root / "xdg-config" / "container" / "config.toml"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "CONFIG_TEST_PATH": str(config_path),
                    "EXPECTED_CONTAINER_CLI": str(fake_container),
                    "INIT_TEST_LOG": str(init_log),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            config = config_path.read_text(encoding="utf-8")
            self.assertIn(f'image = "{DEFAULT_INIT_IMAGE}"', config)
            self.assertEqual(init_log.read_text(encoding="utf-8").strip(), DEFAULT_INIT_IMAGE)
            invocations = container_log.read_text(encoding="utf-8")
            starts = [
                invocation
                for invocation in invocations.splitlines()
                if "system start" in invocation
            ]
            self.assertIn("system start", invocations)
            self.assertIn(f"--app-root {app_root}", invocations)
            self.assertEqual(invocations.count("system start"), 2)
            self.assertGreaterEqual(invocations.count("system stop"), 2)
            self.assertIn("--enable-kernel-install", starts[0])

    def test_installs_and_configures_unpublished_builder_before_init_build(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            builder_archive = temporary_root / "builder.tar"
            builder_archive.touch()
            container_log = temporary_root / "container.log"
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_container = fake_bin / "container"
            self.write_fake_container(fake_container)

            config_path = app_root / "xdg-config" / "container" / "config.toml"
            (init_repo / "Makefile").write_text(
                "init-block:\n"
                '\t@grep -F \'image = "local/builder:test"\' "$(CONFIG_TEST_PATH)"\n',
                encoding="utf-8",
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINER_RUNTIME_BUILDER_IMAGE": "local/builder:test",
                    "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR": str(builder_archive),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "CONFIG_TEST_PATH": str(config_path),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            config = config_path.read_text(encoding="utf-8")
            self.assertIn('[build]\nimage = "local/builder:test"', config)
            self.assertIn(f'[vminit]\nimage = "{DEFAULT_INIT_IMAGE}"', config)
            invocations = container_log.read_text(encoding="utf-8")
            self.assertIn(f"image load -i {builder_archive}", invocations)

    def test_uses_bootstrap_archive_before_source_matched_init_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            bootstrap_archive = temporary_root / "bootstrap.tar"
            bootstrap_archive.touch()
            container_log = temporary_root / "container.log"
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_container = fake_bin / "container"
            self.write_fake_container(fake_container)
            (init_repo / "Makefile").write_text(
                "init-block:\n"
                '\t@printf "init-block\\n" >>"$(CONTAINER_TEST_LOG)"\n',
                encoding="utf-8",
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINER_RUNTIME_BOOTSTRAP_IMAGE_TAR": str(
                        bootstrap_archive
                    ),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "command\\n" >>"$CONTAINER_TEST_LOG"',
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            invocations = container_log.read_text(encoding="utf-8").splitlines()
            start_index = next(
                index
                for index, invocation in enumerate(invocations)
                if "system start" in invocation
            )
            init_index = invocations.index("init-block")
            restart_index = next(
                index
                for index, invocation in enumerate(invocations)
                if index > init_index and "system start" in invocation
            )
            command_index = invocations.index("command")
            starts = [
                invocation
                for invocation in invocations
                if "system start" in invocation
            ]
            self.assertIn(f"--init-image-archive {bootstrap_archive}", starts[0])
            self.assertIn("--enable-kernel-install", starts[0])
            self.assertNotIn(f"image load -i {bootstrap_archive}", invocations)
            self.assertLess(start_index, init_index)
            self.assertLess(init_index, restart_index)
            self.assertLess(restart_index, command_index)

    def test_installs_prebuilt_init_image_without_source_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_archive = temporary_root / "vminit.tar"
            init_archive.touch()
            container_log = temporary_root / "container.log"
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_container = fake_bin / "container"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_IMAGE_TAR": str(init_archive),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "command\\n" >>"$CONTAINER_TEST_LOG"',
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )

            invocations = container_log.read_text(encoding="utf-8").splitlines()
            starts = [
                invocation
                for invocation in invocations
                if "system start" in invocation
            ]
            command_index = invocations.index("command")
            self.assertEqual(
                len(starts),
                2,
            )
            self.assertIn("--disable-kernel-install", starts[0])
            self.assertIn(f"--init-image-archive {init_archive}", starts[0])
            self.assertIn("--enable-kernel-install", starts[1])
            self.assertNotIn(f"image load -i {init_archive}", invocations)
            self.assertLess(invocations.index(starts[1]), command_index)
    def test_loads_retained_init_image_archive_without_rebuilding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_archive = temporary_root / "vminit.tar"
            init_archive.write_bytes(b"retained init image")
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )

            config_path = app_root / "xdg-config" / "container" / "config.toml"
            self.assertIn(
                f'image = "{DEFAULT_INIT_IMAGE}"',
                config_path.read_text(encoding="utf-8"),
            )
            invocations = container_log.read_text(encoding="utf-8").splitlines()
            starts = [
                invocation
                for invocation in invocations
                if "system start" in invocation
            ]
            self.assertEqual(len(starts), 2)
            self.assertIn("--disable-kernel-install", starts[0])
            self.assertIn(f"--init-image-archive {init_archive}", starts[0])
            self.assertNotIn(f"image load --input {init_archive}", invocations)

    def test_restarts_once_after_transient_xpc_start_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            start_count = temporary_root / "start-count"
            fake_container = temporary_root / "container-cli"
            start_failure_body = (
                'if [[ "$*" == *"system start"* ]]; then\n'
                "  count=0\n"
                '  if [[ -f "${CONTAINER_START_COUNT:?}" ]]; then\n'
                '    IFS= read -r count <"${CONTAINER_START_COUNT}"\n'
                "  fi\n"
                "  ((count += 1))\n"
                '  printf "%s\\n" "$count" >"${CONTAINER_START_COUNT}"\n'
                '  if [[ "$count" == "1" ]]; then\n'
                '    printf \'Error: interrupted: "XPC connection error: Connection invalid"\\n\' >&2\n'
                "    exit 1\n"
                "  fi\n"
                "fi\n"
                'if [[ "$*" == "list --all --format json" ]]; then\n'
                "  printf '[]\\n'\n"
                "fi\n"
            )
            self.write_fake_container(fake_container, body=start_failure_body)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_START_COUNT": str(start_count),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            invocations = container_log.read_text(encoding="utf-8")
            self.assertEqual(invocations.count("system start"), 2)
            self.assertEqual(invocations.count("list --all --format json"), 1)

    def test_restarts_once_after_transient_xpc_ping_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            start_count = temporary_root / "start-count"
            fake_container = temporary_root / "container-cli"
            ping_timeout_body = (
                'if [[ "$*" == *"system start"* ]]; then\n'
                "  count=0\n"
                '  if [[ -f "${CONTAINER_START_COUNT:?}" ]]; then\n'
                '    IFS= read -r count <"${CONTAINER_START_COUNT}"\n'
                "  fi\n"
                "  ((count += 1))\n"
                '  printf "%s\\n" "$count" >"${CONTAINER_START_COUNT}"\n'
                '  if [[ "$count" == "1" ]]; then\n'
                '    printf \'Error: failed to get a response from apiserver: timeout: "XPC timeout for request to %s.apiserver/ping"\\n\' "${CONTAINER_SERVICE_NAMESPACE:?}" >&2\n'
                "    exit 1\n"
                "  fi\n"
                "fi\n"
                'if [[ "$*" == "list --all --format json" ]]; then\n'
                "  printf '[]\\n'\n"
                "fi\n"
            )
            self.write_fake_container(fake_container, body=ping_timeout_body)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_START_COUNT": str(start_count),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            invocations = container_log.read_text(encoding="utf-8")
            self.assertEqual(invocations.count("system start"), 2)
            self.assertEqual(invocations.count("list --all --format json"), 1)


class ContainerRuntimeLockTest(unittest.TestCase):
    def test_runtime_children_do_not_inherit_the_lock_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            lock_file = temporary_root / "runtime.lock"
            inherited_descriptor = temporary_root / "inherited-descriptor"
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_RUNTIME_LOCK_FILE": str(lock_file),
                    "CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS": "1",
                }
            )
            holder_script = (
                f'source "{LOCK_SCRIPT}"; '
                "acquire_container_runtime_lock; "
                f"/bin/bash -c 'if [[ -e /dev/fd/9 ]]; then "
                f'touch "{inherited_descriptor}"; fi; sleep 2\' '
                ">/dev/null 2>&1 &"
            )
            contender_script = (
                f'source "{LOCK_SCRIPT}"; '
                "acquire_container_runtime_lock; "
                "release_container_runtime_lock"
            )

            holder = subprocess.run(
                ["/bin/bash", "-c", holder_script],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(holder.returncode, 0, holder.stdout + holder.stderr)

            started = time.monotonic()
            contender = subprocess.run(
                ["/bin/bash", "-c", contender_script],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            elapsed = time.monotonic() - started
            self.assertEqual(
                contender.returncode,
                0,
                contender.stdout + contender.stderr,
            )
            self.assertLess(elapsed, 1.0)
            self.assertFalse(inherited_descriptor.exists())

    def test_serializes_independent_runtime_users(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            lock_file = temporary_root / "runtime.lock"
            holder_ready = temporary_root / "holder-ready"
            holder_release = temporary_root / "holder-release"
            contender_acquired = temporary_root / "contender-acquired"
            environment = os.environ.copy()
            environment.update(
                {
                    "CONTAINER_RUNTIME_LOCK_FILE": str(lock_file),
                    "CONTAINER_RUNTIME_LOCK_TIMEOUT_SECONDS": "5",
                }
            )
            holder_script = (
                f'source "{LOCK_SCRIPT}"; '
                "acquire_container_runtime_lock; "
                f'touch "{holder_ready}"; '
                f'while [[ ! -e "{holder_release}" ]]; do sleep 0.02; done'
            )
            contender_script = (
                f'source "{LOCK_SCRIPT}"; '
                "acquire_container_runtime_lock; "
                f'touch "{contender_acquired}"'
            )

            holder = subprocess.Popen(
                ["/bin/bash", "-c", holder_script],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            deadline = time.monotonic() + 5
            while not holder_ready.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            if not holder_ready.exists():
                holder_stdout, holder_stderr = holder.communicate(timeout=5)
                self.fail(
                    "lock holder did not acquire the lock\n"
                    + holder_stdout
                    + holder_stderr
                )

            contender = subprocess.Popen(
                ["/bin/bash", "-c", contender_script],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            time.sleep(0.2)
            acquired_before_release = contender_acquired.exists()

            holder_release.touch()
            holder_stdout, holder_stderr = holder.communicate(timeout=5)
            contender_stdout, contender_stderr = contender.communicate(timeout=5)
            self.assertEqual(holder.returncode, 0, holder_stdout + holder_stderr)
            self.assertEqual(contender.returncode, 0, contender_stdout + contender_stderr)
            self.assertFalse(
                acquired_before_release,
                "contender acquired the runtime lock before the holder released it",
            )
            self.assertTrue(contender_acquired.exists())


if __name__ == "__main__":
    unittest.main()
