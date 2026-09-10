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

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("publish-github-release.sh")


class PublishGitHubReleaseTests(unittest.TestCase):
    def test_current_finalize_never_deletes_existing_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "commands"
            gh = root / "gh"
            gh.write_text(
                "#!/bin/bash\nset -euo pipefail\nprintf 'gh:%s\\n' \"$*\" >> \"${TEST_LOG}\"\nif [[ \"${1:-}:${2:-}\" == api:--silent ]]; then printf '{}\\n'; fi\n",
                encoding="utf-8",
            )
            gh.chmod(0o755)
            git = root / "git"
            git.write_text(
                "#!/bin/bash\nset -euo pipefail\nprintf 'git:%s\\n' \"$*\" >> \"${TEST_LOG}\"\n",
                encoding="utf-8",
            )
            git.chmod(0o755)
            notes = root / "notes.md"
            asset = root / "current.tar.gz"
            checksum = root / "current.tar.gz.sha256"
            for path in (notes, asset, checksum):
                path.write_text("data\n", encoding="utf-8")
            environment = os.environ.copy()
            environment.update(
                {
                    "GH": str(gh),
                    "GIT": str(git),
                    "PUBLISH_REF_TYPE": "branch",
                    "PUBLISH_SHA": "a" * 40,
                    "RELEASE_ASSET_PATH": str(asset),
                    "RELEASE_CHECKSUM_PATH": str(checksum),
                    "RELEASE_LATEST": "false",
                    "RELEASE_MUTABLE": "true",
                    "RELEASE_NOTES_FILE": str(notes),
                    "RELEASE_PHASE": "finalize",
                    "RELEASE_PRERELEASE": "true",
                    "RELEASE_REPOSITORY": "owner/repository",
                    "RELEASE_TAG": "current",
                    "RELEASE_TITLE": "Current build",
                    "TEST_LOG": str(log),
                }
            )

            result = subprocess.run(
                ["/bin/bash", str(SCRIPT)],
                cwd=root,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            commands = log.read_text(encoding="utf-8")
            self.assertIn("gh:release upload current", commands)
            self.assertIn("gh:release edit current", commands)
            self.assertNotIn("release delete", commands)
            self.assertNotIn("release create", commands)
            self.assertIn("git:push --force origin refs/tags/current", commands)


if __name__ == "__main__":
    unittest.main()
