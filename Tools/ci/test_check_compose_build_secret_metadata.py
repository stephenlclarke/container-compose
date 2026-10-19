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

"""Focused regression tests for build-secret parity path handling."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "Tools/parity/check-compose-build-secret-metadata.sh"


FAKE_COMPOSE = r"""#!/usr/bin/env python3
import json
import os
import pathlib
import re
import sys

args = sys.argv[1:]
image_state = pathlib.Path(os.environ["FAKE_IMAGE_STATE"])
image_events = pathlib.Path(os.environ["FAKE_IMAGE_EVENTS"])
if pathlib.Path(sys.argv[0]).name == "docker":
    if args == ["image", "ls", "--no-trunc", "--format", "{{.Repository}}:{{.Tag}}"]:
        if image_state.exists():
            print(image_state.read_text(encoding="utf-8"), end="")
        sys.exit(0)
    if args[:2] == ["image", "rm"] and len(args) == 3:
        if image_state.read_text(encoding="utf-8").strip() != args[2]:
            sys.exit(1)
        image_state.unlink()
        with image_events.open("a", encoding="utf-8") as stream:
            stream.write(f"remove {args[2]}\n")
        sys.exit(0)
    raise SystemExit(f"unexpected fake Docker command: {args!r}")

project_directory = pathlib.Path(args[args.index("--project-directory") + 1])
secret_path = project_directory / "secret.txt"
fixture = (project_directory / "compose.yml").read_text(encoding="utf-8")
image_match = re.search(r"^    image: (\S+)$", fixture, re.MULTILINE)
if image_match is None:
    raise SystemExit("fixture has no selected image tag")
image = image_match.group(1)
if os.environ.get("FAKE_WRONG_IMAGE_TAG") == "1":
    image = "example/api:wrong-tag"
is_docker = pathlib.Path(sys.argv[0]).name == "docker-compose-fake"
if is_docker:
    secret_path = secret_path.resolve()

if "config" in args:
    if is_docker:
        print(json.dumps({
            "services": {
                "api": {
                    "image": image,
                    "build": {
                        "secrets": [{
                            "source": "app_secret",
                            "target": "runtime_secret",
                            "uid": "1000",
                            "gid": "1000",
                            "mode": "0440",
                        }],
                    },
                },
            },
        }))
    else:
        print(json.dumps({
            "services": {
                "api": {
                    "image": image,
                    "build": {
                        "secrets": [{
                            "id": "runtime_secret",
                            "file": str(secret_path),
                        }],
                    },
                },
            },
        }))
elif "--print" in args:
    secret = f"id=runtime_secret,type=file,src={secret_path}"
    if os.environ.get("FAKE_LEAK_METADATA") == "1":
        secret += ",uid=1000"
    print(json.dumps({"target": {"api": {"tags": [image], "secret": [secret]}}}))
elif "--dry-run" in args:
    print(f"--secret id=runtime_secret,src={secret_path}")
elif is_docker and "build" in args:
    image_state.write_text(image + "\n", encoding="utf-8")
    with image_events.open("a", encoding="utf-8") as stream:
        stream.write(f"build {image}\n")
else:
    raise SystemExit(f"unexpected fake Compose command: {args!r}")
"""


class ComposeBuildSecretMetadataParityTests(unittest.TestCase):
    def run_check(
        self, *, leak_metadata: bool = False, wrong_image_tag: bool = False
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            actual_tmp = root / "actual"
            alias_tmp = root / "alias"
            bin_directory = root / "bin"
            actual_tmp.mkdir()
            alias_tmp.symlink_to(actual_tmp, target_is_directory=True)
            bin_directory.mkdir()

            docker_compose = bin_directory / "docker-compose-fake"
            container_compose = bin_directory / "container-compose-fake"
            for executable in (docker_compose, container_compose, bin_directory / "docker"):
                executable.write_text(textwrap.dedent(FAKE_COMPOSE), encoding="utf-8")
                executable.chmod(0o755)

            environment = os.environ.copy()
            # The fake Docker executable must take precedence over shell startup
            # configuration that may prepend a host Docker binary to PATH.
            environment.pop("BASH_ENV", None)
            environment.update(
                {
                    "TMPDIR": str(alias_tmp),
                    "DOCKER_COMPOSE": str(docker_compose),
                    "CONTAINER_COMPOSE": str(container_compose),
                    "FAKE_IMAGE_STATE": str(root / "images.txt"),
                    "FAKE_IMAGE_EVENTS": str(root / "image-events.txt"),
                    "PATH": str(bin_directory) + os.pathsep + environment["PATH"],
                }
            )
            if leak_metadata:
                environment["FAKE_LEAK_METADATA"] = "1"
            if wrong_image_tag:
                environment["FAKE_WRONG_IMAGE_TAG"] = "1"

            result = subprocess.run(
                [str(SCRIPT), "--strict"],
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode == 0:
                events = (root / "image-events.txt").read_text(encoding="utf-8").splitlines()
                self.assertEqual(len(events), 2, events)
                self.assertTrue(events[0].startswith("build "), events)
                self.assertEqual(events[1], events[0].replace("build ", "remove ", 1))
                self.assertFalse((root / "images.txt").exists())
            return result

    def test_equivalent_filesystem_aliases_pass(self) -> None:
        result = self.run_check()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build-secret metadata parity passed", result.stdout)

    def test_additional_secret_metadata_still_fails(self) -> None:
        result = self.run_check(leak_metadata=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rendered bake secret fields", result.stderr)

    def test_changed_selected_image_tag_still_fails(self) -> None:
        result = self.run_check(wrong_image_tag=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed the selected image tag", result.stderr)


if __name__ == "__main__":
    unittest.main()
