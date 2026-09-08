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

"""Tests for the content-pinned Nextflow runtime bootstrap."""

import importlib.util
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest


MODULE_PATH = Path(__file__).with_name("bootstrap-nextflow-runtime.py")
SPEC = importlib.util.spec_from_file_location("bootstrap_nextflow_runtime", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {MODULE_PATH}")
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class NextflowRuntimeBootstrapTests(unittest.TestCase):
    """Keep runtime provisioning independent of mutable Homebrew paths."""

    def state_root(self, root: Path) -> Path:
        """Create one minimal marked pipeline state root."""
        (root / "tools").mkdir(parents=True)
        (root / "tmp").mkdir()
        (root / ".container-compose-pipeline-root").write_text(
            bootstrap.STATE_MARKER + "\n", encoding="utf-8"
        )
        return bootstrap.marked_state_root(root)

    def test_launcher_is_installed_atomically_and_then_reused(self) -> None:
        """A valid launcher never reaches the downloader a second time."""
        with tempfile.TemporaryDirectory() as directory:
            state = self.state_root(Path(directory) / "state")
            payload = Path(directory) / "nextflow"
            payload.write_bytes(b"pinned nextflow\n")
            destination = state / "tools/nextflow/1.2.3/nextflow"
            calls = 0

            def download(_url: str, output: Path) -> None:
                nonlocal calls
                calls += 1
                shutil.copyfile(payload, output)

            arguments = {
                "destination": destination,
                "expected_parent": destination.parent,
                "version": "1.2.3",
                "url": "https://example.invalid/nextflow",
                "expected_sha256": bootstrap.sha256(payload),
                "downloader": download,
            }
            bootstrap.install_launcher(**arguments)
            bootstrap.install_launcher(**arguments)

            self.assertEqual(calls, 1)
            self.assertEqual(destination.read_bytes(), payload.read_bytes())
            self.assertTrue(os.access(destination, os.X_OK))

    def test_managed_parent_rejects_a_symlink_before_creating_children(self) -> None:
        """A tampered ancestor cannot redirect even temporary tool state."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = self.state_root(root / "state")
            outside = root / "outside"
            outside.mkdir()
            (state / "tools/nextflow").symlink_to(
                outside, target_is_directory=True
            )
            destination = state / "tools/nextflow/1.2.3/nextflow"

            with self.assertRaisesRegex(
                bootstrap.BootstrapError, "ancestor is indirect"
            ):
                bootstrap.install_launcher(
                    destination=destination,
                    expected_parent=destination.parent,
                    version="1.2.3",
                    url="https://example.invalid/nextflow",
                    expected_sha256="0" * 64,
                )

            self.assertFalse((outside / "1.2.3").exists())

    def make_java_archive(
        self, root: Path, release: str
    ) -> tuple[Path, dict[Path, str], str]:
        """Create a tiny executable JDK-shaped fixture and its file pins."""
        archive_root = root / f"jdk-{release}"
        home = archive_root / "Contents/Home"
        (home / "bin").mkdir(parents=True)
        (home / "lib/server").mkdir(parents=True)
        java = home / "bin/java"
        java.write_text(
            '#!/bin/sh\nprintf \'openjdk version "21.0.11" fixture\\n\' >&2\n',
            encoding="utf-8",
        )
        java.chmod(0o755)
        (home / "lib/modules").write_bytes(b"modules")
        (home / "lib/server/libjvm.dylib").write_bytes(b"jvm")
        (home / "lib/libzip.dylib").write_bytes(b"zip")
        (home / "release").write_bytes(b"release")
        archive = root / "temurin.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            output.add(archive_root, arcname=archive_root.name)
        runtime_files = {
            path.relative_to(archive_root): bootstrap.sha256(path)
            for path in (
                java,
                home / "lib/modules",
                home / "lib/server/libjvm.dylib",
                home / "release",
            )
        }
        return archive, runtime_files, bootstrap.tree_sha256(archive_root)

    def test_java_archive_is_verified_installed_and_reused(self) -> None:
        """The JDK becomes a durable content-addressed tool, not a Cellar alias."""
        with tempfile.TemporaryDirectory() as directory:
            fixture_root = Path(directory)
            state = self.state_root(fixture_root / "state")
            release = "21.0.11+10"
            archive, runtime_files, tree_digest = self.make_java_archive(
                fixture_root, release
            )
            destination = state / "tools/temurin" / release
            calls = 0

            def download(_url: str, output: Path) -> None:
                nonlocal calls
                calls += 1
                shutil.copyfile(archive, output)

            arguments = {
                "root": destination,
                "expected_parent": destination.parent,
                "version": "21.0.11",
                "release": release,
                "url": "https://example.invalid/temurin.tar.gz",
                "archive_sha256": bootstrap.sha256(archive),
                "expected_tree_sha256": tree_digest,
                "runtime_files": runtime_files,
                "temporary_root": state / "tmp",
                "downloader": download,
            }
            bootstrap.install_java(**arguments)
            bootstrap.install_java(**arguments)

            self.assertEqual(calls, 1)
            self.assertTrue(
                bootstrap.valid_runtime(destination, runtime_files, tree_digest)
            )

    def test_java_reuse_rejects_corruption_outside_the_critical_file_subset(
        self,
    ) -> None:
        """Every extracted JDK byte, not only launcher files, remains pinned."""
        with tempfile.TemporaryDirectory() as directory:
            fixture_root = Path(directory)
            state = self.state_root(fixture_root / "state")
            release = "21.0.11+10"
            archive, runtime_files, tree_digest = self.make_java_archive(
                fixture_root, release
            )
            destination = state / "tools/temurin" / release
            calls = 0

            def download(_url: str, output: Path) -> None:
                nonlocal calls
                calls += 1
                shutil.copyfile(archive, output)

            arguments = {
                "root": destination,
                "expected_parent": destination.parent,
                "version": "21.0.11",
                "release": release,
                "url": "https://example.invalid/temurin.tar.gz",
                "archive_sha256": bootstrap.sha256(archive),
                "expected_tree_sha256": tree_digest,
                "runtime_files": runtime_files,
                "temporary_root": state / "tmp",
                "downloader": download,
            }
            bootstrap.install_java(**arguments)
            (destination / "Contents/Home/lib/libzip.dylib").write_bytes(b"corrupt")
            with self.assertRaisesRegex(
                bootstrap.BootstrapError, "tree digest mismatch"
            ):
                bootstrap.verify_java_tree(
                    state_root=state,
                    root=destination,
                    release=release,
                    expected_tree_sha256=tree_digest,
                )
            bootstrap.install_java(**arguments)

            self.assertEqual(calls, 2)
            self.assertTrue(
                bootstrap.valid_runtime(destination, runtime_files, tree_digest)
            )

    def test_java_install_restores_an_interrupted_previous_runtime(self) -> None:
        """A hard kill between the two atomic renames needs no redownload."""
        with tempfile.TemporaryDirectory() as directory:
            fixture_root = Path(directory)
            state = self.state_root(fixture_root / "state")
            release = "21.0.11+10"
            archive, runtime_files, tree_digest = self.make_java_archive(
                fixture_root, release
            )
            destination = state / "tools/temurin" / release

            def download(_url: str, output: Path) -> None:
                shutil.copyfile(archive, output)

            arguments = {
                "root": destination,
                "expected_parent": destination.parent,
                "version": "21.0.11",
                "release": release,
                "url": "https://example.invalid/temurin.tar.gz",
                "archive_sha256": bootstrap.sha256(archive),
                "expected_tree_sha256": tree_digest,
                "runtime_files": runtime_files,
                "temporary_root": state / "tmp",
                "downloader": download,
            }
            bootstrap.install_java(**arguments)
            previous = destination.parent / f".temurin-previous.{'a' * 32}"
            os.replace(destination, previous)

            def unexpected_download(_url: str, _output: Path) -> None:
                self.fail("recovery should not download the JDK again")

            arguments["downloader"] = unexpected_download
            bootstrap.install_java(**arguments)

            self.assertTrue(
                bootstrap.valid_runtime(destination, runtime_files, tree_digest)
            )
            self.assertFalse(previous.exists())

    def test_java_archive_rejects_parent_traversal(self) -> None:
        """A matching download still cannot write outside its staging root."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive_path = root / "unsafe.tar.gz"
            payload = root / "payload"
            payload.write_bytes(b"unsafe")
            with tarfile.open(archive_path, "w:gz") as archive:
                archive.add(payload, arcname="../escaped")

            with tarfile.open(archive_path, "r:gz") as archive:
                with self.assertRaisesRegex(bootstrap.BootstrapError, "unsafe"):
                    bootstrap.validate_archive(archive, "jdk-21.0.11+10")

    def test_hawkeye_is_installed_atomically_and_then_reused(self) -> None:
        """The graph uses its archive-pinned Hawkeye, not a mutable Cellar tool."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = self.state_root(root / "state")
            installer = root / "install-hawkeye.sh"
            counter = root / "installer-calls"
            hawkeye_payload = (
                "#!/bin/sh\n"
                "case \"${1:-}:${2:-}\" in\n"
                "  --version:) printf '%s\\n' 'version: 6.5.1' ;;\n"
                "  check:--help) printf '%s\\n' '--fail-if-unknown' ;;\n"
                "  format:--help) printf '%s\\n' '--fail-if-updated' ;;\n"
                "  *) exit 64 ;;\n"
                "esac\n"
            )
            expected_hawkeye = root / "expected-hawkeye"
            expected_hawkeye.write_text(hawkeye_payload, encoding="utf-8")
            installer_source = (
                "#!/bin/sh\n"
                "set -eu\n"
                f"printf x >>'{counter}'\n"
                "mkdir -p .local/bin\n"
                "cat >.local/bin/hawkeye <<'EOF'\n"
                + hawkeye_payload
                + "EOF\nchmod 0755 .local/bin/hawkeye\n"
            )
            installer.write_text(
                installer_source,
                encoding="utf-8",
            )
            installer.chmod(0o755)
            destination = state / "tools/hawkeye/6.5.1/hawkeye"
            arguments = {
                "destination": destination,
                "expected_parent": destination.parent,
                "version": "6.5.1",
                "expected_sha256": bootstrap.sha256(expected_hawkeye),
                "installer": installer,
                "temporary_root": state / "tmp",
            }

            bootstrap.install_hawkeye(**arguments)
            interrupted = destination.parent / ".hawkeye-install.abcd"
            interrupted.mkdir()
            destination.write_text(hawkeye_payload + "# impostor\n", encoding="utf-8")
            destination.chmod(0o755)
            bootstrap.install_hawkeye(**arguments)

            self.assertEqual(counter.read_text(encoding="utf-8"), "xx")
            self.assertTrue(
                bootstrap.valid_hawkeye(
                    destination, "6.5.1", bootstrap.sha256(expected_hawkeye)
                )
            )
            self.assertFalse(interrupted.exists())

    def test_state_root_requires_the_exact_marker(self) -> None:
        """Bootstrap never claims an arbitrary tools directory."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "state"
            root.mkdir()
            (root / ".container-compose-pipeline-root").write_text(
                "wrong\n", encoding="utf-8"
            )

            with self.assertRaisesRegex(bootstrap.BootstrapError, "does not match"):
                bootstrap.marked_state_root(root)


if __name__ == "__main__":
    unittest.main()
