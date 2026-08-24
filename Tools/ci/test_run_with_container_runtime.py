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
import io
import json
import os
import signal
import shutil
import subprocess
import tarfile
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
    def local_execution_root() -> Path:
        private_tmp = Path("/private/tmp")
        if private_tmp.is_dir() and os.access(private_tmp, os.W_OK):
            return private_tmp
        return Path("/tmp")

    @classmethod
    def local_user_root(cls) -> Path:
        return cls.local_execution_root() / f"container-compose-runtime-{os.getuid()}"

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
            "CONTAINER_RUNTIME_CANDIDATE_SHA256",
            "CONTAINER_RUNTIME_CLI",
            "CONTAINER_RUNTIME_CLI_SHA256",
            "CONTAINER_RUNTIME_SERVICE_NAMESPACE",
            "CONTAINER_RUNTIME_STOP_HELPER",
            "CONTAINER_SERVICE_NAMESPACE",
            "CONTAINERIZATION_INIT_SOURCE_PATH",
            "CONTAINERIZATION_INIT_BUILD_SCRATCH_ROOT",
            "CONTAINER_COMPOSE_INIT_IMAGE",
            "CONTAINER_RUNTIME_LOCK_FILE",
            "CONTAINER_RUNTIME_MANAGED",
            "CONTAINER_RUNTIME_REQUIRED_INIT_IMAGE_REFERENCES",
            "CONTAINER_RUNTIME_RUN_ID",
            "CONTAINER_RUNTIME_START_DEADLINE_SECONDS",
            "CONTAINER_RUNTIME_LOCK_HELD",
            "CONTAINER_RUNTIME_LOCK_KEEPER_PID",
            "CONTAINER_RUNTIME_ANONYMOUS_REGISTRY_HOSTS",
            "CONTAINER_RUNTIME_LOCAL_EXECUTION_ROOT",
            "CONTAINER_RUNTIME_LOCALIZE_APP_ROOT",
            "CONTAINER_RUNTIME_STAGE_CANDIDATE",
            "CONTAINER_RUNTIME_ALLOW_NON_MACHO_TEST_FIXTURES",
            "CONTAINER_REGISTRY_ANONYMOUS_HOSTS",
        ):
            environment.pop(variable, None)
        environment["CONTAINER_RUNTIME_ALLOW_NON_MACHO_TEST_FIXTURES"] = "1"
        return environment

    def test_rejects_a_candidate_cli_that_does_not_match_its_pinned_digest(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            fake_container = temporary_root / "container-cli"
            container_log = temporary_root / "container.log"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_CLI_SHA256": "0" * 64,
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
            self.assertIn("candidate container binary digest mismatch", result.stderr)
            self.assertFalse(container_log.exists())

    def test_candidate_fingerprint_hang_consumes_complete_startup_deadline(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            blocking_candidate = temporary_root / "container-cli"
            os.mkfifo(blocking_candidate)
            blocking_candidate.chmod(0o755)
            command_marker = temporary_root / "command-ran"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "1",
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(blocking_candidate),
                    "/usr/bin/touch",
                    str(command_marker),
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=5,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 4)
            self.assertFalse(command_marker.exists())

    def test_signature_inspection_uses_complete_startup_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            candidate = package_bin / "container"
            self.write_fake_container(candidate)
            for executable_name in ("container-apiserver", "container-engine"):
                executable = package_bin / executable_name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)

            real_find = shutil.which("find")
            self.assertIsNotNone(real_find)
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_find = fake_bin / "find"
            fake_find.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'if [[ "$*" == *"${BLOCKED_SIGNATURE_ROOT:?}/bin"* ]]; then\n'
                "  /bin/sleep 30\n"
                "fi\n"
                f'exec "{real_find}" "$@"\n',
                encoding="utf-8",
            )
            fake_find.chmod(0o755)
            command_marker = temporary_root / "command-ran"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "1",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(temporary_root / "container.log"),
                    "BLOCKED_SIGNATURE_ROOT": str(package_root),
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(candidate),
                    "/usr/bin/touch",
                    str(command_marker),
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=5,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 4)
            self.assertFalse(command_marker.exists())

    def test_rejects_non_macho_required_packaged_binary_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            candidate = package_bin / "container"
            self.write_fake_container(candidate)
            for executable_name in ("container-apiserver", "container-engine"):
                executable = package_bin / executable_name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)

            command_marker = temporary_root / "command-ran"
            environment = self.runtime_environment()
            environment.pop(
                "CONTAINER_RUNTIME_ALLOW_NON_MACHO_TEST_FIXTURES", None
            )
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "never",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(temporary_root / "container.log"),
                }
            )
            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(candidate),
                    "/usr/bin/touch",
                    str(command_marker),
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn(
                "Container runtime packaged binary must be Mach-O",
                result.stderr,
            )
            self.assertFalse(command_marker.exists())

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
    def write_blocking_mktemp(path: Path) -> None:
        real_mktemp = shutil.which("mktemp")
        if real_mktemp is None:
            raise RuntimeError("mktemp is required for runtime wrapper tests")
        path.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            'if [[ "$*" == *"${BLOCKED_MKTEMP_PATTERN:?}"* ]]; then\n'
            '  printf "%s\\n" "$*" >"${MKTEMP_ARGUMENTS:?}"\n'
            '  touch "${MKTEMP_STARTED:?}"\n'
            "  /bin/sleep 30\n"
            "fi\n"
            f'exec "{real_mktemp}" "$@"\n',
            encoding="utf-8",
        )
        path.chmod(0o755)

    @staticmethod
    def create_oci_archive(
        path: Path,
        *references: str,
        distinct_digests: bool = False,
        config_architecture: str = "arm64",
        config_variant: str | None = None,
        indexed_architecture: str | None = None,
        indexed_variant: str | None = None,
    ) -> None:
        def descriptor(payload: bytes, media_type: str) -> dict[str, object]:
            return {
                "mediaType": media_type,
                "digest": "sha256:" + hashlib.sha256(payload).hexdigest(),
                "size": len(payload),
            }

        config_payload = {"architecture": config_architecture, "os": "linux"}
        if config_variant is not None:
            config_payload["variant"] = config_variant
        config = json.dumps(config_payload, sort_keys=True).encode("utf-8")
        layer = b"fixture-layer"
        config_descriptor = descriptor(
            config, "application/vnd.oci.image.config.v1+json"
        )
        layer_descriptor = descriptor(
            layer, "application/vnd.oci.image.layer.v1.tar"
        )
        manifests: list[tuple[bytes, dict[str, object]]] = []
        for position, reference in enumerate(references):
            manifest = json.dumps(
                {
                    "schemaVersion": 2,
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "config": config_descriptor,
                    "layers": [layer_descriptor],
                    "fixture": position if distinct_digests else 0,
                },
                sort_keys=True,
            ).encode("utf-8")
            manifest_descriptor = descriptor(
                manifest, "application/vnd.oci.image.manifest.v1+json"
            )
            manifest_descriptor["annotations"] = {
                "org.opencontainers.image.ref.name": reference,
            }
            manifests.append((manifest, manifest_descriptor))
        payloads = [config, layer, *(item[0] for item in manifests)]
        if indexed_architecture is None:
            index_manifests = [item[1] for item in manifests]
        else:
            if len(manifests) != 1:
                raise ValueError("indexed fixture supports exactly one reference")
            child = manifests[0][1].copy()
            child.pop("annotations")
            child["platform"] = {
                "architecture": indexed_architecture,
                "os": "linux",
            }
            if indexed_variant is not None:
                child["platform"]["variant"] = indexed_variant
            nested = json.dumps(
                {"schemaVersion": 2, "manifests": [child]}, sort_keys=True
            ).encode("utf-8")
            nested_descriptor = descriptor(
                nested, "application/vnd.oci.image.index.v1+json"
            )
            nested_descriptor["annotations"] = {
                "org.opencontainers.image.ref.name": references[0],
            }
            index_manifests = [nested_descriptor]
            payloads.append(nested)
        index = {"schemaVersion": 2, "manifests": index_manifests}
        layout = json.dumps({"imageLayoutVersion": "1.0.0"}).encode("utf-8")
        index_payload = json.dumps(index).encode("utf-8")
        with tarfile.open(path, "w") as archive:
            for name, payload in (("oci-layout", layout), ("index.json", index_payload)):
                member = tarfile.TarInfo(name)
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
            for payload in payloads:
                digest = hashlib.sha256(payload).hexdigest()
                member = tarfile.TarInfo(f"blobs/sha256/{digest}")
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))

    @staticmethod
    def create_oci_artifact_archive(path: Path, reference: str) -> None:
        artifact = json.dumps(
            {
                "schemaVersion": 2,
                "mediaType": "application/vnd.oci.artifact.manifest.v1+json",
                "artifactType": "application/vnd.example.fixture",
                "blobs": [],
            },
            sort_keys=True,
        ).encode("utf-8")
        digest = hashlib.sha256(artifact).hexdigest()
        index = json.dumps(
            {
                "schemaVersion": 2,
                "manifests": [
                    {
                        "mediaType": "application/vnd.oci.artifact.manifest.v1+json",
                        "digest": f"sha256:{digest}",
                        "size": len(artifact),
                        "annotations": {
                            "org.opencontainers.image.ref.name": reference,
                        },
                    }
                ],
            }
        ).encode("utf-8")
        layout = json.dumps({"imageLayoutVersion": "1.0.0"}).encode("utf-8")
        with tarfile.open(path, "w") as archive:
            for name, payload in (
                ("oci-layout", layout),
                ("index.json", index),
                (f"blobs/sha256/{digest}", artifact),
            ):
                member = tarfile.TarInfo(name)
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))

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

    @staticmethod
    def find_staged_service_archive(invocations: str, name: str) -> Path:
        prefixes = (
            "/private/tmp/container-compose-service-inputs.",
            "/tmp/container-compose-service-inputs.",
        )
        paths = [
            Path(token)
            for token in invocations.split()
            if token.startswith(prefixes) and token.endswith(f"/{name}")
        ]
        if len(paths) != 1:
            raise AssertionError(f"expected one staged {name}, got {paths}")
        return paths[0]

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

    def test_preserves_nonempty_unmarked_runtime_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            app_root.mkdir()
            sentinel = app_root / "user-data"
            sentinel.write_text("preserve\n", encoding="utf-8")
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
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
            self.assertIn("refusing to clear unmarked", result.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_preserves_runtime_root_with_invalid_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            app_root.mkdir()
            marker = app_root / ".container-compose-runtime-root"
            marker.write_text("not-owned\n", encoding="utf-8")
            sentinel = app_root / "user-data"
            sentinel.write_text("preserve\n", encoding="utf-8")
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
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
            self.assertIn("refusing to clear container runtime root with an invalid marker", result.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_runtime_root_marker_hang_consumes_complete_startup_deadline(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            app_root.mkdir()
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            real_find = shutil.which("find")
            self.assertIsNotNone(real_find)
            marker_inspection_started = temporary_root / "marker-inspection-started"
            fake_find = fake_bin / "find"
            fake_find.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'if [[ "$*" == *"-print -quit"* ]]; then\n'
                '  touch "${MARKER_INSPECTION_STARTED:?}"\n'
                "  sleep 30\n"
                "fi\n"
                f'exec "{real_find}" "$@"\n',
                encoding="utf-8",
            )
            fake_find.chmod(0o755)
            fake_container = fake_bin / "container-cli"
            self.write_fake_container(fake_container)
            command_marker = temporary_root / "command-ran"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "6",
                    "CONTAINER_TEST_LOG": str(temporary_root / "container.log"),
                    "MARKER_INSPECTION_STARTED": str(marker_inspection_started),
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=9,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 8)
            self.assertTrue(marker_inspection_started.exists())
            self.assertFalse(command_marker.exists())

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
                    "CONTAINER_RUNTIME_RUN_ID": "candidate-test-run",
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
                f"{app_root}:{os.getuid()}:candidate-test-run".encode("utf-8")
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

    def test_stages_packaged_candidate_and_uses_anonymous_public_registry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            candidate = package_bin / "container"
            self.write_fake_container(candidate)
            for executable_name in ("container-apiserver", "container-engine"):
                executable = package_bin / executable_name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)

            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            contract_environment = temporary_root / "candidate-environment"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "always",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "CONTRACT_ENVIRONMENT": str(contract_environment),
                }
            )

            staged_paths: list[str] = []
            source_digest = hashlib.sha256(
                str(package_root.resolve()).encode()
            ).hexdigest()[:16]
            staged_root = self.local_user_root() / f"candidate-{source_digest}"
            try:
                for _ in range(2):
                    result = subprocess.run(
                        [
                            str(SCRIPT),
                            str(candidate),
                            "/bin/sh",
                            "-c",
                            'printf "%s\\n%s\\n%s\\n%s\\n" '
                            '"$CONTAINER_RUNTIME_CLI" "$CONTAINER_BIN" '
                            '"$CONTAINER_COMPOSE_CONTAINER" '
                            '"$CONTAINER_REGISTRY_ANONYMOUS_HOSTS" '
                            '>"$CONTRACT_ENVIRONMENT"',
                        ],
                        cwd=ROOT,
                        env=environment,
                        capture_output=True,
                        text=True,
                    )

                    self.assertEqual(
                        result.returncode, 0, result.stdout + result.stderr
                    )
                    values = contract_environment.read_text(
                        encoding="utf-8"
                    ).splitlines()
                    self.assertEqual(values[0], values[1])
                    self.assertEqual(values[0], values[2])
                    self.assertRegex(
                        values[0],
                        rf"^/(?:private/)?tmp/container-compose-runtime-{os.getuid()}"
                        rf"/candidate-[0-9a-f]{{16}}/bin/container$",
                    )
                    self.assertEqual(values[3], "ghcr.io")
                    staged_paths.append(values[0])

                self.assertEqual(staged_paths[0], staged_paths[1])
                self.assertTrue(staged_root.is_dir())
                marker = staged_root / ".container-compose-runtime-candidate-staging"
                self.assertTrue(marker.is_file())
            finally:
                if staged_root.is_dir():
                    shutil.rmtree(staged_root)

    def test_selected_candidate_replaces_inherited_candidate_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            candidate = temporary_root / "container-cli"
            self.write_fake_container(candidate)
            alias_log = temporary_root / "candidate-aliases"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "never",
                    "CONTAINER_RUNTIME_LOCALIZE_APP_ROOT": "never",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(temporary_root / "container.log"),
                    "CONTAINER_BIN": "/tmp/stale-container-bin",
                    "CONTAINER_COMPOSE_CONTAINER": "/tmp/stale-compose-container",
                    "ALIAS_LOG": str(alias_log),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(candidate),
                    "/bin/sh",
                    "-c",
                    'printf "%s\\n%s\\n" "$CONTAINER_BIN" '
                    '"$CONTAINER_COMPOSE_CONTAINER" >"$ALIAS_LOG"',
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                alias_log.read_text(encoding="utf-8").splitlines(),
                [str(candidate.resolve()), str(candidate.resolve())],
            )

    def test_rejects_source_package_change_during_staging(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            candidate = package_bin / "container"
            self.write_fake_container(candidate)
            for executable_name in ("container-apiserver", "container-engine"):
                executable = package_bin / executable_name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)
            changing_payload = package_libexec / "generation"
            changing_payload.write_text("generation one\n", encoding="utf-8")
            for index in range(512):
                (package_libexec / f"payload-{index:04d}").write_text(
                    f"payload {index}\n", encoding="utf-8"
                )

            source_digest = hashlib.sha256(
                str(package_root.resolve()).encode()
            ).hexdigest()[:16]
            staged_root = self.local_user_root() / f"candidate-{source_digest}"
            marker = staged_root / ".container-compose-runtime-candidate-staging"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "always",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(temporary_root / "container.log"),
                }
            )
            process = subprocess.Popen(
                [str(SCRIPT), str(candidate), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 10
                while not marker.is_file() and process.poll() is None:
                    if time.monotonic() >= deadline:
                        self.fail("candidate staging marker was not created")
                    time.sleep(0.001)
                self.assertIsNone(process.poll(), "staging completed before mutation")
                changing_payload.write_text("generation two\n", encoding="utf-8")
                stdout, stderr = process.communicate(timeout=15)

                self.assertEqual(process.returncode, 2, stdout + stderr)
                self.assertIn(
                    "complete Container runtime package changed during staging",
                    stderr,
                )
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=5)
                if staged_root.is_dir():
                    shutil.rmtree(staged_root)

    def test_interrupted_replacement_preserves_recoverable_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            candidate = package_bin / "container"
            self.write_fake_container(candidate)
            for executable_name in ("container-apiserver", "container-engine"):
                executable = package_bin / executable_name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)
            changing_payload = package_libexec / "generation"
            changing_payload.write_text("generation one\n", encoding="utf-8")
            for index in range(256):
                (package_libexec / f"payload-{index:04d}").write_text(
                    f"payload {index}\n", encoding="utf-8"
                )

            source_digest = hashlib.sha256(
                str(package_root.resolve()).encode()
            ).hexdigest()[:16]
            staged_root = self.local_user_root() / f"candidate-{source_digest}"
            self.local_user_root().mkdir(mode=0o700, exist_ok=True)
            staged_root.mkdir(mode=0o700)
            marker = staged_root / ".container-compose-runtime-candidate-staging"
            old_marker_value = f"container-compose runtime candidate staging v1 {'0' * 64}"
            marker.write_text(old_marker_value + "\n", encoding="utf-8")
            removal_sentinel = staged_root / "old-generation"
            removal_sentinel.write_text("old\n", encoding="utf-8")
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "always",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(temporary_root / "container.log"),
                }
            )
            first = subprocess.Popen(
                [str(SCRIPT), str(candidate), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 10
                while removal_sentinel.exists() and first.poll() is None:
                    if time.monotonic() >= deadline:
                        self.fail("existing candidate payload was not removed")
                    time.sleep(0.001)
                self.assertIsNone(first.poll(), "staging completed before mutation")
                changing_payload.write_text("generation two\n", encoding="utf-8")
                first_stdout, first_stderr = first.communicate(timeout=15)

                self.assertEqual(
                    first.returncode, 2, first_stdout + first_stderr
                )
                self.assertTrue(staged_root.is_dir())
                self.assertEqual(marker.read_text(encoding="utf-8").strip(), old_marker_value)

                second = subprocess.run(
                    [str(SCRIPT), str(candidate), "/usr/bin/true"],
                    cwd=ROOT,
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(
                    second.returncode, 0, second.stdout + second.stderr
                )
                candidate_digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
                self.assertEqual(
                    marker.read_text(encoding="utf-8").strip(),
                    "container-compose runtime candidate staging v1 "
                    + candidate_digest,
                )
            finally:
                if first.poll() is None:
                    first.terminate()
                    first.communicate(timeout=5)
                if staged_root.is_dir():
                    shutil.rmtree(staged_root)

    def test_staged_candidate_lock_is_held_until_command_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            candidate = package_bin / "container"
            self.write_fake_container(candidate)
            for executable_name in ("container-apiserver", "container-engine"):
                executable = package_bin / executable_name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)

            ready = temporary_root / "command-ready"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "always",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(temporary_root / "container.log"),
                    "READY": str(ready),
                }
            )
            source_digest = hashlib.sha256(
                str(package_root.resolve()).encode()
            ).hexdigest()[:16]
            staged_root = self.local_user_root() / f"candidate-{source_digest}"
            first = subprocess.Popen(
                [
                    str(SCRIPT),
                    str(candidate),
                    "/bin/sh",
                    "-c",
                    'touch "$READY"; sleep 5',
                ],
                cwd=ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 15
                while not ready.exists() and first.poll() is None:
                    if time.monotonic() >= deadline:
                        self.fail("first staged command did not become ready")
                    time.sleep(0.05)

                second_environment = environment.copy()
                second_environment["CONTAINER_RUNTIME_START_DEADLINE_SECONDS"] = "3"
                second = subprocess.run(
                    [str(SCRIPT), str(candidate), "/usr/bin/true"],
                    cwd=ROOT,
                    env=second_environment,
                    capture_output=True,
                    text=True,
                    timeout=6,
                )

                self.assertEqual(
                    second.returncode, 124, second.stdout + second.stderr
                )
                self.assertIn(
                    "timed out waiting for local Container candidate staging lock",
                    second.stderr,
                )
                first_stdout, first_stderr = first.communicate(timeout=15)
                self.assertEqual(
                    first.returncode, 0, first_stdout + first_stderr
                )
            finally:
                if first.poll() is None:
                    first.terminate()
                    first.communicate(timeout=5)
                if staged_root.is_dir():
                    shutil.rmtree(staged_root)

    def test_rejects_indirect_candidate_staging_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            candidate = package_bin / "container"
            self.write_fake_container(candidate)
            for executable_name in ("container-apiserver", "container-engine"):
                executable = package_bin / executable_name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)

            source_digest = hashlib.sha256(
                str(package_root.resolve()).encode()
            ).hexdigest()[:16]
            staged_root = self.local_user_root() / f"candidate-{source_digest}"
            self.local_user_root().mkdir(mode=0o700, exist_ok=True)
            protected_target = temporary_root / "protected-target"
            protected_target.mkdir()
            protected_file = protected_target / "preserve"
            protected_file.write_text("unchanged\n", encoding="utf-8")
            staged_root.symlink_to(protected_target, target_is_directory=True)

            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "always",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                }
            )
            try:
                result = subprocess.run(
                    [str(SCRIPT), str(candidate), "/usr/bin/true"],
                    cwd=ROOT,
                    env=environment,
                    capture_output=True,
                    text=True,
                )

                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(
                    "refusing to use an indirect local Container candidate",
                    result.stderr,
                )
                self.assertEqual(
                    protected_file.read_text(encoding="utf-8"), "unchanged\n"
                )
            finally:
                staged_root.unlink(missing_ok=True)

    def test_rejected_candidate_root_is_not_removed_by_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            candidate = package_bin / "container"
            self.write_fake_container(candidate)
            for executable_name in ("container-apiserver", "container-engine"):
                executable = package_bin / executable_name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)

            source_digest = hashlib.sha256(
                str(package_root.resolve()).encode()
            ).hexdigest()[:16]
            candidate_digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
            staged_root = self.local_user_root() / f"candidate-{source_digest}"
            self.local_user_root().mkdir(mode=0o700, exist_ok=True)
            staged_root.mkdir(mode=0o700)
            marker = staged_root / ".container-compose-runtime-candidate-staging"
            marker.write_text(
                f"container-compose runtime candidate staging v1 {candidate_digest}\n",
                encoding="utf-8",
            )
            protected_file = staged_root / "preserve"
            protected_file.write_text("unchanged\n", encoding="utf-8")
            staged_root.chmod(0o777)

            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "always",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                }
            )
            try:
                result = subprocess.run(
                    [str(SCRIPT), str(candidate), "/usr/bin/true"],
                    cwd=ROOT,
                    env=environment,
                    capture_output=True,
                    text=True,
                )

                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(
                    "refusing to use an unowned or accessible local Container candidate",
                    result.stderr,
                )
                self.assertEqual(
                    protected_file.read_text(encoding="utf-8"), "unchanged\n"
                )
            finally:
                staged_root.chmod(0o700)
                shutil.rmtree(staged_root)

    def test_rejects_indirect_packaged_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            candidate = package_bin / "container"
            candidate.symlink_to("/usr/bin/true")
            for executable_name in ("container-apiserver", "container-engine"):
                executable = package_bin / executable_name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)

            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "never",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                }
            )
            result = subprocess.run(
                [str(SCRIPT), str(candidate), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn(
                "Container runtime package contains an indirect executable",
                result.stderr,
            )

    def test_anonymous_registry_opt_out_clears_inherited_policy(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            container_log = temporary_root / "container.log"
            inherited_policy_log = temporary_root / "anonymous-policy"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_ANONYMOUS_REGISTRY_HOSTS": "",
                    "CONTAINER_REGISTRY_ANONYMOUS_HOSTS": "ghcr.io",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "INHERITED_POLICY_LOG": str(inherited_policy_log),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "%s\\n" "${CONTAINER_REGISTRY_ANONYMOUS_HOSTS-unset}" '
                    '>"$INHERITED_POLICY_LOG"',
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(
                inherited_policy_log.read_text(encoding="utf-8"), "unset\n"
            )

    @unittest.skipUnless(
        os.uname().sysname == "Darwin", "requires macOS codesign"
    )
    def test_rejects_ad_hoc_runtime_before_launch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            package_root = temporary_root / "candidate"
            package_bin = package_root / "bin"
            package_libexec = package_root / "libexec" / "container"
            package_bin.mkdir(parents=True)
            package_libexec.mkdir(parents=True)
            executable = package_bin / "container"
            shutil.copyfile("/usr/bin/true", executable)
            executable.chmod(0o700)
            subprocess.run(
                ["/usr/bin/codesign", "--force", "--sign", "-", str(executable)],
                check=True,
                capture_output=True,
                text=True,
            )
            for executable_name in ("container-apiserver", "container-engine"):
                companion = package_bin / executable_name
                companion.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                companion.chmod(0o755)

            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "never",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                }
            )
            result = subprocess.run(
                [str(SCRIPT), str(package_bin / "container"), "/usr/bin/true"],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn(
                "lacks a stable Developer ID signature", result.stderr
            )

    def test_localizes_runtime_state_when_explicitly_requested(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            requested_app_root = temporary_root / "external-app-root"
            container_log = temporary_root / "container.log"
            localized_root_log = temporary_root / "localized-root"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(requested_app_root),
                    "CONTAINER_RUNTIME_LOCALIZE_APP_ROOT": "always",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "LOCALIZED_ROOT_LOG": str(localized_root_log),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "%s\\n" "$CONTAINER_APP_ROOT" >"$LOCALIZED_ROOT_LOG"',
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            localized_root = Path(
                localized_root_log.read_text(encoding="utf-8").strip()
            )
            self.assertRegex(
                str(localized_root),
                rf"^/(?:private/)?tmp/container-compose-runtime-{os.getuid()}"
                rf"/state-[0-9a-f]{{16}}$",
            )
            self.assertNotEqual(localized_root, requested_app_root)
            marker = localized_root / ".container-compose-runtime-root"
            self.assertTrue(marker.is_file())
            shutil.rmtree(localized_root)

    def test_auto_localizes_exact_and_symlinked_privacy_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            fake_home = temporary_root / "home"
            exact_root = fake_home / "Downloads"
            symlink_target = fake_home / "Documents" / "runtime"
            exact_root.mkdir(parents=True)
            symlink_target.mkdir(parents=True)
            alias_root = temporary_root / "runtime-alias"
            alias_root.symlink_to(symlink_target, target_is_directory=True)
            candidate = temporary_root / "container-cli"
            self.write_fake_container(candidate)

            for requested_root in (exact_root, alias_root):
                with self.subTest(requested_root=requested_root):
                    localized_root_log = temporary_root / "localized-root"
                    environment = self.runtime_environment()
                    environment.update(
                        {
                            "HOME": str(fake_home),
                            "CONTAINER_RUNTIME_APP_ROOT": str(requested_root),
                            "CONTAINER_RUNTIME_LOCK_FILE": str(
                                temporary_root / "runtime.lock"
                            ),
                            "CONTAINER_TEST_LOG": str(
                                temporary_root / "container.log"
                            ),
                            "LOCALIZED_ROOT_LOG": str(localized_root_log),
                        }
                    )
                    result = subprocess.run(
                        [
                            str(SCRIPT),
                            str(candidate),
                            "/bin/sh",
                            "-c",
                            'printf "%s\\n" "$CONTAINER_APP_ROOT" '
                            '>"$LOCALIZED_ROOT_LOG"',
                        ],
                        cwd=ROOT,
                        env=environment,
                        capture_output=True,
                        text=True,
                    )

                    self.assertEqual(
                        result.returncode, 0, result.stdout + result.stderr
                    )
                    localized_root = Path(
                        localized_root_log.read_text(encoding="utf-8").strip()
                    )
                    self.assertRegex(
                        str(localized_root),
                        rf"^/(?:private/)?tmp/container-compose-runtime-{os.getuid()}"
                        rf"/state-[0-9a-f]{{16}}$",
                    )
                    self.assertNotEqual(localized_root, requested_root.resolve())
                    shutil.rmtree(localized_root)

    def test_forced_localization_rejects_missing_or_relative_requested_root(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)

            for invalid_root in ("", "relative/app-root"):
                with self.subTest(invalid_root=invalid_root):
                    command_marker = temporary_root / "command-ran"
                    command_marker.unlink(missing_ok=True)
                    environment = self.runtime_environment()
                    environment.update(
                        {
                            "CONTAINER_RUNTIME_APP_ROOT": invalid_root,
                            "CONTAINER_RUNTIME_LOCALIZE_APP_ROOT": "always",
                            "CONTAINER_RUNTIME_LOCK_FILE": str(
                                temporary_root / "runtime.lock"
                            ),
                            "CONTAINER_TEST_LOG": str(
                                temporary_root / "container.log"
                            ),
                        }
                    )

                    result = subprocess.run(
                        [
                            str(SCRIPT),
                            str(fake_container),
                            "/usr/bin/touch",
                            str(command_marker),
                        ],
                        cwd=ROOT,
                        env=environment,
                        capture_output=True,
                        text=True,
                    )

                    self.assertEqual(
                        result.returncode, 2, result.stdout + result.stderr
                    )
                    self.assertIn(
                        "CONTAINER_RUNTIME_APP_ROOT must be an absolute",
                        result.stderr,
                    )
                    self.assertNotIn(
                        "Relocating Container runtime state", result.stdout
                    )
                    self.assertFalse(command_marker.exists())

    def test_privacy_opt_out_skips_unused_local_user_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_LOCALIZE_APP_ROOT": "never",
                    "CONTAINER_RUNTIME_STAGE_CANDIDATE": "never",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(temporary_root / "container.log"),
                }
            )

            result = subprocess.run(
                [
                    "/bin/bash",
                    "-x",
                    str(SCRIPT),
                    str(fake_container),
                    "/usr/bin/true",
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("+ prepare_local_user_root ", result.stderr)

    def test_rejects_indirect_localized_runtime_state_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            requested_app_root = temporary_root / "external-app-root"
            requested_digest = hashlib.sha256(
                str(requested_app_root).encode()
            ).hexdigest()[:16]
            localized_root = self.local_user_root() / f"state-{requested_digest}"
            self.local_user_root().mkdir(mode=0o700, exist_ok=True)
            protected_target = temporary_root / "protected-target"
            protected_target.mkdir()
            protected_file = protected_target / "preserve"
            protected_file.write_text("unchanged\n", encoding="utf-8")
            (protected_target / ".container-compose-runtime-root").write_text(
                "container-compose isolated runtime state v1\n",
                encoding="utf-8",
            )
            localized_root.symlink_to(protected_target, target_is_directory=True)

            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(requested_app_root),
                    "CONTAINER_RUNTIME_LOCALIZE_APP_ROOT": "always",
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                }
            )
            try:
                result = subprocess.run(
                    [str(SCRIPT), str(fake_container), "/usr/bin/true"],
                    cwd=ROOT,
                    env=environment,
                    capture_output=True,
                    text=True,
                )

                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(
                    "refusing to use an indirect localized Container runtime state root",
                    result.stderr,
                )
                self.assertEqual(
                    protected_file.read_text(encoding="utf-8"), "unchanged\n"
                )
            finally:
                localized_root.unlink(missing_ok=True)

    def test_repeated_runs_on_one_root_receive_different_default_namespaces(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            namespaces: list[str] = []
            for run_number in range(2):
                namespace_file = temporary_root / f"namespace-{run_number}"
                environment = self.runtime_environment()
                environment.update(
                    {
                        "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                        "CONTAINER_RUNTIME_LOCK_FILE": str(
                            temporary_root / "runtime.lock"
                        ),
                        "CONTAINER_TEST_LOG": str(container_log),
                        "NAMESPACE_FILE": str(namespace_file),
                    }
                )
                result = subprocess.run(
                    [
                        str(SCRIPT),
                        str(fake_container),
                        "/bin/sh",
                        "-c",
                        'printf "%s\\n" "$CONTAINER_SERVICE_NAMESPACE" >"$NAMESPACE_FILE"',
                    ],
                    cwd=ROOT,
                    env=environment,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                namespaces.append(namespace_file.read_text(encoding="utf-8").strip())

            self.assertNotEqual(namespaces[0], namespaces[1])

    def test_repeated_group_signal_stops_the_isolated_runtime(self) -> None:
        with tempfile.TemporaryDirectory(
            dir="/tmp", prefix="cc-signal."
        ) as temporary_directory:
            temporary_root = Path(temporary_directory)
            for delivered_signal, expected_status in (
                (signal.SIGHUP, 129),
                (signal.SIGINT, 130),
                (signal.SIGQUIT, 131),
                (signal.SIGTERM, 143),
            ):
                with self.subTest(signal=delivered_signal.name):
                    case_root = temporary_root / delivered_signal.name
                    case_root.mkdir()
                    app_root = case_root / "app-root"
                    container_log = case_root / "container.log"
                    ready = case_root / "ready"
                    stop_started = case_root / "stop-started"
                    stop_complete = case_root / "stop-complete"
                    fake_container = case_root / "container-cli"
                    self.write_fake_container(
                        fake_container,
                        body=(
                            'if [[ "$*" == "system stop" && -e "${READY_FILE:-}" ]]; then\n'
                            '  touch "${STOP_STARTED:?}"\n'
                            "  sleep 0.5\n"
                            '  touch "${STOP_COMPLETE:?}"\n'
                            "fi\n"
                        ),
                    )
                    environment = self.runtime_environment()
                    environment.update(
                        {
                            "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                            "CONTAINER_RUNTIME_RUN_ID": (
                                f"{delivered_signal.name.lower()}-test-run"
                            ),
                            "CONTAINER_RUNTIME_LOCK_FILE": str(
                                case_root / "runtime.lock"
                            ),
                            "CONTAINER_TEST_LOG": str(container_log),
                            "READY_FILE": str(ready),
                            "STOP_STARTED": str(stop_started),
                            "STOP_COMPLETE": str(stop_complete),
                        }
                    )

                    process = subprocess.Popen(
                        [
                            str(SCRIPT),
                            str(fake_container),
                            "/bin/sh",
                            "-c",
                            'touch "$READY_FILE"; while :; do sleep 1; done',
                        ],
                        cwd=ROOT,
                        env=environment,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        start_new_session=True,
                    )
                    deadline = time.monotonic() + 10
                    while not ready.exists() and process.poll() is None:
                        if time.monotonic() >= deadline:
                            process.kill()
                            self.fail("candidate command did not become ready")
                        time.sleep(0.05)
                    if process.poll() is not None:
                        stdout, stderr = process.communicate(timeout=10)
                        self.fail(
                            "candidate command exited before signal\n"
                            + stdout
                            + stderr
                        )

                    os.killpg(process.pid, delivered_signal)
                    deadline = time.monotonic() + 10
                    while not stop_started.exists() and process.poll() is None:
                        if time.monotonic() >= deadline:
                            process.kill()
                            self.fail("runtime stop did not begin")
                        time.sleep(0.01)
                    try:
                        os.killpg(process.pid, delivered_signal)
                    except ProcessLookupError:
                        # Cleanup may have completed between observing its
                        # marker and re-delivering the signal.
                        pass
                    stdout, stderr = process.communicate(timeout=10)

                    self.assertEqual(
                        process.returncode, expected_status, stdout + stderr
                    )
                    invocations = container_log.read_text(
                        encoding="utf-8"
                    ).splitlines()
                    self.assertGreaterEqual(invocations.count("system stop"), 2)
                    self.assertIn("Stopping matched container runtime...", stdout)
                    self.assertTrue(stop_complete.exists(), stdout + stderr)

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

    def test_source_validation_hang_consumes_complete_startup_deadline(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            source, _ = self.create_containerization_source(temporary_root)
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            (init_repo / "Makefile").write_text(
                "init-block:\n\t@true\n", encoding="utf-8"
            )
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            real_git = shutil.which("git")
            self.assertIsNotNone(real_git)
            fake_git = fake_bin / "git"
            fake_git.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'if [[ "$*" == *"rev-parse --show-toplevel"* ]]; then\n'
                '  touch "${SOURCE_VALIDATION_STARTED:?}"\n'
                "  sleep 30\n"
                "fi\n"
                f'exec "{real_git}" "$@"\n',
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            fake_container = fake_bin / "container-cli"
            self.write_fake_container(fake_container)
            command_marker = temporary_root / "command-ran"
            validation_started = temporary_root / "source-validation-started"
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINERIZATION_INIT_SOURCE_PATH": str(source),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "3",
                    "CONTAINER_TEST_LOG": str(temporary_root / "container.log"),
                    "SOURCE_VALIDATION_STARTED": str(validation_started),
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=7,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 6)
            self.assertTrue(validation_started.exists())
            self.assertFalse(command_marker.exists())

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

    def test_source_staging_hang_consumes_the_shared_startup_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            source, _ = self.create_containerization_source(temporary_root)
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            (init_repo / "Makefile").write_text(
                "init-block:\n\t@true\n", encoding="utf-8"
            )
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_sleep = fake_bin / "sleep"
            fake_sleep.write_text(
                "#!/usr/bin/env bash\nexit 0\n",
                encoding="utf-8",
            )
            fake_sleep.chmod(0o755)
            fake_git = fake_bin / "git"
            clone_started = temporary_root / "clone-started"
            real_git = shutil.which("git")
            self.assertIsNotNone(real_git)
            fake_git.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'if [[ "${1:-}" == "clone" ]]; then\n'
                f"  touch {clone_started}\n"
                "  /bin/sleep 30\n"
                "fi\n"
                f'exec "{real_git}" "$@"\n',
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            fake_container = fake_bin / "container-cli"
            container_log = temporary_root / "container.log"
            command_marker = temporary_root / "command-ran"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINERIZATION_INIT_SOURCE_PATH": str(source),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "10",
                    "CONTAINER_TEST_LOG": str(container_log),
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
                timeout=13,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 12)
            self.assertTrue(clone_started.exists())
            self.assertFalse(command_marker.exists())

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
                    "EXPECTED_CONTAINER_CLI": str(fake_container.resolve()),
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

    def test_source_built_init_restart_shares_the_startup_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            command_marker = temporary_root / "command-ran"
            container_log = temporary_root / "container.log"
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_sleep = fake_bin / "sleep"
            fake_sleep.write_text(
                "#!/usr/bin/env bash\nexit 0\n",
                encoding="utf-8",
            )
            fake_sleep.chmod(0o755)
            first_start = temporary_root / "first-start"
            fake_container = fake_bin / "container-cli"
            init_repo = temporary_root / "container"
            init_repo.mkdir()
            (init_repo / "Makefile").write_text(
                "init-block:\n\t@true\n",
                encoding="utf-8",
            )
            self.write_fake_container(
                fake_container,
                body=(
                    'if [[ "$*" == *"system start"* ]]; then\n'
                    '  if [[ -e "${FIRST_START:?}" ]]; then\n'
                    "    /bin/sleep 30\n"
                    "  fi\n"
                    '  touch "${FIRST_START:?}"\n'
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_BLOCK_REPO": str(init_repo),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "8",
                    "CONTAINER_TEST_LOG": str(container_log),
                    "FIRST_START": str(first_start),
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=11,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertFalse(command_marker.exists())
            self.assertTrue(first_start.exists(), result.stdout + result.stderr)
            invocations = container_log.read_text(encoding="utf-8")
            self.assertEqual(invocations.count("system start"), 2)

    def test_stale_runtime_stop_hang_consumes_the_shared_startup_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            command_marker = temporary_root / "command-ran"
            stop_started = temporary_root / "stop-started"
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                body=(
                    'if [[ "$*" == "system stop" && ! -e "${STOP_STARTED:?}" ]]; then\n'
                    '  touch "${STOP_STARTED}"\n'
                    "  sleep 30\n"
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "3",
                    "CONTAINER_TEST_LOG": str(container_log),
                    "STOP_STARTED": str(stop_started),
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=7,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 6)
            self.assertTrue(stop_started.exists())
            self.assertFalse(command_marker.exists())

    def test_builder_image_install_shares_the_startup_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            command_marker = temporary_root / "command-ran"
            container_log = temporary_root / "container.log"
            builder_archive = temporary_root / "builder.tar"
            builder_archive.touch()
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            fake_sleep = fake_bin / "sleep"
            fake_sleep.write_text(
                "#!/usr/bin/env bash\nexit 0\n",
                encoding="utf-8",
            )
            fake_sleep.chmod(0o755)
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                body=(
                    'if [[ "$*" == "image load -i "* ]]; then\n'
                    "  /bin/sleep 30\n"
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_BUILDER_IMAGE": "local/builder:test",
                    "CONTAINER_RUNTIME_BUILDER_IMAGE_TAR": str(builder_archive),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "8",
                    "CONTAINER_TEST_LOG": str(container_log),
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=11,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 10, result.stdout + result.stderr)
            self.assertFalse(command_marker.exists())
            self.assertIn("image load -i", container_log.read_text(encoding="utf-8"))

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
            staged_builder_archive = self.find_staged_service_archive(
                invocations, "builder-image.oci.tar"
            )
            self.assertIn(f"image load -i {staged_builder_archive}", invocations)

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
            staged_bootstrap_archive = self.find_staged_service_archive(
                "\n".join(invocations), "bootstrap-image.oci.tar"
            )
            self.assertIn(
                f"--init-image-archive {staged_bootstrap_archive}", starts[0]
            )
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
            staged_init_archive = self.find_staged_service_archive(
                "\n".join(invocations), "matched-init-image.oci.tar"
            )
            self.assertIn(f"--init-image-archive {staged_init_archive}", starts[0])
            self.assertIn("--enable-kernel-install", starts[1])
            self.assertNotIn(f"image load -i {init_archive}", invocations)
            self.assertLess(invocations.index(starts[1]), command_index)
    def test_loads_retained_init_image_archive_without_rebuilding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_archive = temporary_root / "vminit.tar"
            self.create_oci_archive(init_archive, DEFAULT_INIT_IMAGE)
            container_log = temporary_root / "container.log"
            archive_digest_log = temporary_root / "archive-digest.log"
            child_archive_path_log = temporary_root / "child-archive-path.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                body=(
                    "archive_path=\n"
                    "while [[ $# -gt 0 ]]; do\n"
                    '  if [[ "$1" == "--init-image-archive" ]]; then\n'
                    "    archive_path=$2\n"
                    "    break\n"
                    "  fi\n"
                    "  shift\n"
                    "done\n"
                    'if [[ -n "$archive_path" ]]; then\n'
                    '  /usr/bin/shasum -a 256 "$archive_path" '
                    '>>"${CONTAINER_ARCHIVE_DIGEST_LOG:?}"\n'
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_TEST_LOG": str(container_log),
                    "CONTAINER_ARCHIVE_DIGEST_LOG": str(archive_digest_log),
                    "CHILD_ARCHIVE_PATH_LOG": str(child_archive_path_log),
                }
            )

            subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "%s\\n" "$CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE" '
                    '>"$CHILD_ARCHIVE_PATH_LOG"',
                ],
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
            staged_init_archive = self.find_staged_service_archive(
                "\n".join(invocations), "retained-init-image.oci.tar"
            )
            self.assertIn(f"--init-image-archive {staged_init_archive}", starts[0])
            self.assertNotIn(f"image load --input {init_archive}", invocations)
            expected_digest = hashlib.sha256(init_archive.read_bytes()).hexdigest()
            self.assertEqual(
                archive_digest_log.read_text(encoding="utf-8").split()[0],
                expected_digest,
            )
            self.assertEqual(
                child_archive_path_log.read_text(encoding="utf-8").strip(),
                str(staged_init_archive),
            )
            self.assertFalse(staged_init_archive.parent.exists())

    def test_rejects_retained_archive_missing_any_required_reference(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_archive = temporary_root / "vminit.tar"
            immutable_reference = "ghcr.io/example/vminit:0123456789abcdef"
            self.create_oci_archive(init_archive, DEFAULT_INIT_IMAGE)
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
                    "CONTAINER_RUNTIME_REQUIRED_INIT_IMAGE_REFERENCES": immutable_reference,
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

            self.assertEqual(result.returncode, 1)
            self.assertIn(immutable_reference, result.stderr)
            self.assertFalse(container_log.exists())

    def test_rejects_artifact_annotated_as_required_image(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            init_archive = temporary_root / "vminit-artifact.tar"
            self.create_oci_artifact_archive(init_archive, DEFAULT_INIT_IMAGE)
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
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

            self.assertEqual(result.returncode, 1)
            self.assertIn("missing required reference(s)", result.stderr)
            self.assertIn(DEFAULT_INIT_IMAGE, result.stderr)
            self.assertFalse(container_log.exists())

    def test_rejects_required_index_without_linux_arm64_image(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            init_archive = temporary_root / "vminit-amd64.tar"
            self.create_oci_archive(
                init_archive,
                DEFAULT_INIT_IMAGE,
                config_architecture="amd64",
                indexed_architecture="amd64",
            )
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
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

            self.assertEqual(result.returncode, 1)
            self.assertIn("missing required reference(s)", result.stderr)
            self.assertIn(DEFAULT_INIT_IMAGE, result.stderr)
            self.assertFalse(container_log.exists())

    def test_rejects_required_index_with_mismatched_config_platform(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            init_archive = temporary_root / "vminit-platform-mismatch.tar"
            self.create_oci_archive(
                init_archive,
                DEFAULT_INIT_IMAGE,
                config_architecture="amd64",
                indexed_architecture="arm64",
            )
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
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

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "descriptor platform does not match image config", result.stderr
            )
            self.assertFalse(container_log.exists())

    def test_rejects_required_index_with_mismatched_config_variant(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            init_archive = temporary_root / "vminit-variant-mismatch.tar"
            self.create_oci_archive(
                init_archive,
                DEFAULT_INIT_IMAGE,
                config_variant="v9",
                indexed_architecture="arm64",
                indexed_variant="v8",
            )
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
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

            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "descriptor platform does not match image config", result.stderr
            )
            self.assertFalse(container_log.exists())

    def test_rejects_required_archive_references_with_different_digests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            init_archive = temporary_root / "vminit.tar"
            immutable_reference = "ghcr.io/example/vminit:0123456789abcdef"
            self.create_oci_archive(
                init_archive,
                DEFAULT_INIT_IMAGE,
                immutable_reference,
                distinct_digests=True,
            )
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
                    "CONTAINER_RUNTIME_REQUIRED_INIT_IMAGE_REFERENCES": immutable_reference,
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

            self.assertEqual(result.returncode, 1)
            self.assertIn("do not resolve to one digest", result.stderr)
            self.assertFalse(container_log.exists())

    def test_rejects_retained_archive_with_invalid_descriptor_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            complete_archive = temporary_root / "complete.tar"
            self.create_oci_archive(complete_archive, DEFAULT_INIT_IMAGE)
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)

            with tarfile.open(complete_archive, "r") as source:
                complete_payloads = {}
                for member in source.getmembers():
                    if not member.isfile():
                        continue
                    stream = source.extractfile(member)
                    self.assertIsNotNone(stream)
                    complete_payloads[member.name] = stream.read()

            def missing_layer(payloads: dict[str, bytes]) -> None:
                index = json.loads(payloads["index.json"])
                manifest_digest = index["manifests"][0]["digest"].split(":", 1)[1]
                manifest = json.loads(payloads[f"blobs/sha256/{manifest_digest}"])
                layer_digest = manifest["layers"][0]["digest"].split(":", 1)[1]
                del payloads[f"blobs/sha256/{layer_digest}"]

            def wrong_size(payloads: dict[str, bytes]) -> None:
                index = json.loads(payloads["index.json"])
                index["manifests"][0]["size"] += 1
                payloads["index.json"] = json.dumps(index).encode("utf-8")

            def wrong_digest(payloads: dict[str, bytes]) -> None:
                index = json.loads(payloads["index.json"])
                manifest_digest = index["manifests"][0]["digest"].split(":", 1)[1]
                member_name = f"blobs/sha256/{manifest_digest}"
                payload = payloads[member_name]
                payloads[member_name] = bytes([payload[0] ^ 1]) + payload[1:]

            for name, mutation, expected_error in (
                ("missing-layer", missing_layer, "missing required member: blobs/sha256/"),
                ("wrong-size", wrong_size, "size mismatch"),
                ("wrong-digest", wrong_digest, "digest mismatch"),
            ):
                with self.subTest(name=name):
                    init_archive = temporary_root / f"{name}.tar"
                    payloads = complete_payloads.copy()
                    mutation(payloads)
                    with tarfile.open(init_archive, "w") as destination:
                        for member_name, payload in payloads.items():
                            member = tarfile.TarInfo(member_name)
                            member.size = len(payload)
                            destination.addfile(member, io.BytesIO(payload))

                    container_log = temporary_root / f"{name}.log"
                    environment = self.runtime_environment()
                    environment.update(
                        {
                            "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app"),
                            "CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE": str(init_archive),
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

                    self.assertEqual(result.returncode, 1)
                    self.assertIn(expected_error, result.stderr)
                    self.assertFalse(container_log.exists())

    def test_managed_runtime_ready_api_does_not_restart_or_stop_its_owner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            command_log = temporary_root / "command.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_MANAGED": "1",
                    "CONTAINER_RUNTIME_RUN_ID": "outer-owner",
                    "CONTAINER_TEST_LOG": str(container_log),
                    "COMMAND_LOG": str(command_log),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "managed\\n" >"$COMMAND_LOG"',
                ],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(command_log.read_text(encoding="utf-8"), "managed\n")
            self.assertEqual(
                container_log.read_text(encoding="utf-8"),
                "list --all --format json\n",
            )

    def test_candidate_cli_leads_path_for_nested_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            candidate_bin = temporary_root / "candidate-bin"
            competing_bin = temporary_root / "competing-bin"
            candidate_bin.mkdir()
            competing_bin.mkdir()
            candidate_container = candidate_bin / "container"
            competing_container = competing_bin / "container"
            candidate_log = temporary_root / "candidate.log"
            competing_log = temporary_root / "competing.log"
            self.write_fake_container(candidate_container)
            competing_container.write_text(
                "#!/usr/bin/env bash\n"
                'printf "%s\\n" "$*" >>"${COMPETING_CONTAINER_LOG:?}"\n'
                "exit 97\n",
                encoding="utf-8",
            )
            competing_container.chmod(0o755)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_MANAGED": "1",
                    "CONTAINER_RUNTIME_RUN_ID": "outer-owner",
                    "CONTAINER_TEST_LOG": str(candidate_log),
                    "COMPETING_CONTAINER_LOG": str(competing_log),
                    "EXPECTED_CONTAINER_CLI": str(candidate_container.resolve()),
                    "PATH": f"{competing_bin}:{environment['PATH']}",
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(candidate_container),
                    "/bin/sh",
                    "-c",
                    'test "$(command -v container)" = "$EXPECTED_CONTAINER_CLI" '
                    '&& test "$CONTAINER_RUNTIME_CLI" = "$EXPECTED_CONTAINER_CLI" '
                    "&& container nested-command-proof",
                ],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(
                "nested-command-proof",
                candidate_log.read_text(encoding="utf-8").splitlines(),
            )
            self.assertFalse(competing_log.exists())

    def test_resolves_bare_candidate_command_before_pinning_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            candidate_bin = temporary_root / "candidate-bin"
            candidate_bin.mkdir()
            candidate_container = candidate_bin / "container"
            candidate_log = temporary_root / "candidate.log"
            self.write_fake_container(candidate_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_MANAGED": "1",
                    "CONTAINER_RUNTIME_RUN_ID": "outer-owner",
                    "CONTAINER_TEST_LOG": str(candidate_log),
                    "BASH_ENV": "/dev/null",
                    "ENV": "/dev/null",
                    "EXPECTED_CONTAINER_CLI": str(candidate_container.resolve()),
                    "PATH": f"{candidate_bin}:{environment['PATH']}",
                }
            )
            resolved_candidate = subprocess.run(
                ["/bin/bash", "-c", "command -v container"],
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            self.assertEqual(resolved_candidate, str(candidate_container))

            result = subprocess.run(
                [
                    str(SCRIPT),
                    "container",
                    "/bin/sh",
                    "-c",
                    'test "$(command -v container)" = "$EXPECTED_CONTAINER_CLI" '
                    '&& test "$CONTAINER_RUNTIME_CLI" = "$EXPECTED_CONTAINER_CLI" '
                    "&& container bare-command-proof",
                ],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            candidate_invocations = (
                candidate_log.read_text(encoding="utf-8")
                if candidate_log.exists()
                else "<candidate was not invoked>\n"
            )
            self.assertEqual(
                result.returncode,
                0,
                result.stdout + result.stderr + candidate_invocations,
            )
            self.assertIn(
                "bare-command-proof",
                candidate_invocations.splitlines(),
            )

    def test_managed_runtime_recovers_owner_api_after_cli_reinstall(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            command_log = temporary_root / "command.log"
            ready_marker = temporary_root / "ready"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                body=(
                    'if [[ "$*" == "list --all --format json" ]]; then\n'
                    '  [[ -f "${READY_MARKER:?}" ]]\n'
                    "  exit\n"
                    "fi\n"
                    'if [[ "$*" == *"system start"* ]]; then\n'
                    '  : >"${READY_MARKER:?}"\n'
                    "  exit 0\n"
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_MANAGED": "1",
                    "CONTAINER_RUNTIME_RUN_ID": "outer-owner",
                    "CONTAINER_TEST_LOG": str(container_log),
                    "COMMAND_LOG": str(command_log),
                    "READY_MARKER": str(ready_marker),
                }
            )

            result = subprocess.run(
                [
                    str(SCRIPT),
                    str(fake_container),
                    "/bin/sh",
                    "-c",
                    'printf "recovered\\n" >"$COMMAND_LOG"',
                ],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(command_log.read_text(encoding="utf-8"), "recovered\n")
            container_commands = container_log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(container_commands[0], "list --all --format json")
            self.assertIn(
                f"--debug system start --timeout 60 --enable-kernel-install --app-root {app_root}",
                container_commands,
            )
            self.assertEqual(container_commands[-1], "list --all --format json")
            self.assertFalse(any("system stop" in command for command in container_commands))

    def test_managed_runtime_api_hang_stays_inside_the_shared_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            command_marker = temporary_root / "command-ran"
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                body=(
                    'if [[ "$*" == "list --all --format json" ]]; then\n'
                    "  sleep 30\n"
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_MANAGED": "1",
                    "CONTAINER_RUNTIME_RUN_ID": "outer-owner",
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "1",
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=4,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 3)
            self.assertFalse(command_marker.exists())
            self.assertEqual(
                container_log.read_text(encoding="utf-8").splitlines(),
                ["list --all --format json"],
            )

    def test_managed_start_state_creation_stays_inside_the_shared_deadline(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            mktemp_arguments = temporary_root / "mktemp-arguments"
            mktemp_started = temporary_root / "mktemp-started"
            self.write_blocking_mktemp(fake_bin / "mktemp")
            command_marker = temporary_root / "command-ran"
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                body=(
                    'if [[ "$*" == "list --all --format json" ]]; then\n'
                    "  exit 1\n"
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "BLOCKED_MKTEMP_PATTERN": (
                        "container-compose-runtime-managed-start."
                    ),
                    "CONTAINER_RUNTIME_APP_ROOT": str(
                        temporary_root / "app-root"
                    ),
                    "CONTAINER_RUNTIME_MANAGED": "1",
                    "CONTAINER_RUNTIME_RUN_ID": "outer-owner",
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "3",
                    "CONTAINER_TEST_LOG": str(container_log),
                    "MKTEMP_STARTED": str(mktemp_started),
                    "MKTEMP_ARGUMENTS": str(mktemp_arguments),
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=6,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 5)
            self.assertTrue(
                mktemp_started.exists(), result.stdout + result.stderr
            )
            self.assertNotIn(
                str(temporary_root), mktemp_arguments.read_text(encoding="utf-8")
            )
            self.assertFalse(command_marker.exists())

    def test_api_round_trip_failure_blocks_the_candidate_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            command_marker = temporary_root / "command-ran"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                body=(
                    'if [[ "$*" == "list --all --format json" ]]; then\n'
                    "  exit 23\n"
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(command_marker.exists())

    def test_non_transient_start_failure_is_not_retried(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                body=(
                    'if [[ "$*" == *"system start"* ]]; then\n'
                    "  printf 'invalid runtime configuration\\n' >&2\n"
                    "  exit 42\n"
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(temporary_root / "app-root"),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
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

            self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
            invocations = container_log.read_text(encoding="utf-8")
            self.assertEqual(invocations.count("system start"), 1)
            self.assertNotIn("restarting the matched runtime once", result.stderr)

    def test_start_state_creation_stays_inside_the_shared_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            fake_bin = temporary_root / "fake-bin"
            fake_bin.mkdir()
            mktemp_arguments = temporary_root / "mktemp-arguments"
            mktemp_started = temporary_root / "mktemp-started"
            self.write_blocking_mktemp(fake_bin / "mktemp")
            (fake_bin / "sleep").write_text(
                "#!/usr/bin/env bash\nexit 0\n",
                encoding="utf-8",
            )
            (fake_bin / "sleep").chmod(0o755)
            command_marker = temporary_root / "command-ran"
            container_log = temporary_root / "container.log"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(fake_container)
            environment = self.runtime_environment()
            environment.update(
                {
                    "BLOCKED_MKTEMP_PATTERN": "container-compose-runtime-start.",
                    "CONTAINER_RUNTIME_APP_ROOT": str(
                        temporary_root / "app-root"
                    ),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(
                        temporary_root / "runtime.lock"
                    ),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "8",
                    "CONTAINER_TEST_LOG": str(container_log),
                    "MKTEMP_STARTED": str(mktemp_started),
                    "MKTEMP_ARGUMENTS": str(mktemp_arguments),
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=11,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(time.monotonic() - started, 10)
            self.assertTrue(
                mktemp_started.exists(), result.stdout + result.stderr
            )
            self.assertNotIn(
                str(temporary_root), mktemp_arguments.read_text(encoding="utf-8")
            )
            self.assertFalse(command_marker.exists())

    def test_api_round_trip_hang_consumes_the_shared_startup_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            app_root = temporary_root / "app-root"
            container_log = temporary_root / "container.log"
            command_marker = temporary_root / "command-ran"
            fake_container = temporary_root / "container-cli"
            self.write_fake_container(
                fake_container,
                body=(
                    'if [[ "$*" == "list --all --format json" ]]; then\n'
                    "  sleep 30\n"
                    "fi\n"
                ),
            )
            environment = self.runtime_environment()
            environment.update(
                {
                    "CONTAINER_RUNTIME_APP_ROOT": str(app_root),
                    "CONTAINER_RUNTIME_LOCK_FILE": str(temporary_root / "runtime.lock"),
                    "CONTAINER_RUNTIME_START_DEADLINE_SECONDS": "6",
                    "CONTAINER_TEST_LOG": str(container_log),
                }
            )

            started = time.monotonic()
            result = subprocess.run(
                [str(SCRIPT), str(fake_container), "/usr/bin/touch", str(command_marker)],
                cwd=ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
                timeout=9,
            )

            self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
            self.assertLess(
                time.monotonic() - started,
                8,
                result.stdout + result.stderr,
            )
            self.assertFalse(command_marker.exists())
            invocations = container_log.read_text(encoding="utf-8")
            self.assertEqual(invocations.count("system start"), 1)
            self.assertEqual(invocations.count("list --all --format json"), 1)

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
    @staticmethod
    def independent_runtime_environment() -> dict[str, str]:
        environment = os.environ.copy()
        for variable in (
            "CONTAINER_RUNTIME_LOCK_HELD",
            "CONTAINER_RUNTIME_LOCK_KEEPER_PID",
            "CONTAINER_RUNTIME_MANAGED",
        ):
            environment.pop(variable, None)
        return environment

    def test_runtime_children_do_not_inherit_the_lock_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            lock_file = temporary_root / "runtime.lock"
            inherited_descriptor = temporary_root / "inherited-descriptor"
            environment = self.independent_runtime_environment()
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
            environment = self.independent_runtime_environment()
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
