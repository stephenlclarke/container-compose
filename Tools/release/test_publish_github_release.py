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
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("publish-github-release.sh")


class PublishGitHubReleaseTests(unittest.TestCase):
    def test_current_published_retry_restores_and_verifies_immutable_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "commands"
            gh = root / "gh"
            gh.write_text(
                """#!/bin/bash
set -euo pipefail
printf 'gh:%s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == api && "$*" == *releases/latest* ]]; then
  printf '{"tag_name":"1.2.3"}\n'
elif [[ "${1:-}" == api ]]; then
  printf '{}\n'
elif [[ "${1:-}:${2:-}" == release:view ]]; then
  jq -n --arg tag "${RELEASE_TAG}" --arg target "${PUBLISH_SHA}" \
    --arg title "Current build" --rawfile body "${TEST_PUBLISHED_NOTES}" \
    --arg digest "sha256:${TEST_DIGEST}" \
    '{isDraft:false,isImmutable:true,isPrerelease:true,tagName:$tag,
      targetCommitish:$target,name:$title,body:$body,
      assets:[{name:"current.tar.gz",digest:$digest},
              {name:"current.tar.gz.sha256",digest:$digest}]}'
elif [[ "${1:-}:${2:-}" == release:download ]]; then
  pattern=""
  directory=""
  while (( $# > 0 )); do
    case "$1" in
      --pattern) pattern="$2"; shift 2 ;;
      --dir) directory="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s' "${TEST_PUBLISHED_BYTES}" > "${directory}/${pattern}"
fi
""",
                encoding="utf-8",
            )
            gh.chmod(0o755)
            git = root / "git"
            git.write_text(
                """#!/bin/bash
set -euo pipefail
printf 'git:%s\n' "$*" >> "${TEST_LOG}"
if [[ "${1:-}" == ls-remote ]]; then
  printf '%s\trefs/tags/%s\n' "${PUBLISH_SHA}" "${RELEASE_TAG}"
fi
""",
                encoding="utf-8",
            )
            git.chmod(0o755)
            notes = root / "notes.md"
            published_notes = root / "published-notes.md"
            asset = root / "current.tar.gz"
            checksum = root / "current.tar.gz.sha256"
            asset.write_text("rebuilt archive\n", encoding="utf-8")
            checksum.write_text("rebuilt checksum\n", encoding="utf-8")
            published_bytes = b"published immutable bytes\n"
            published_digest = hashlib.sha256(published_bytes).hexdigest()
            rebuilt_digest = hashlib.sha256(asset.read_bytes()).hexdigest()
            notes.write_text(
                "\n".join(
                    (
                        "deterministic notes",
                        "- `current.tar.gz` SHA-256:",
                        f"  `{rebuilt_digest}`.",
                        "",
                    )
                ),
                encoding="utf-8",
            )
            published_notes.write_text(
                "\n".join(
                    (
                        "deterministic notes",
                        "- `current.tar.gz` SHA-256:",
                        f"  `{published_digest}`.",
                        "",
                    )
                ),
                encoding="utf-8",
            )
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
                    "RELEASE_TAG": f"current-{'a' * 40}",
                    "RELEASE_TITLE": "Current build",
                    "TEST_DIGEST": published_digest,
                    "TEST_LOG": str(log),
                    "TEST_NOTES": str(notes),
                    "TEST_PUBLISHED_NOTES": str(published_notes),
                    "TEST_PUBLISHED_BYTES": published_bytes.decode(),
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
            self.assertEqual(asset.read_bytes(), published_bytes)
            self.assertEqual(checksum.read_bytes(), published_bytes)
            self.assertEqual(notes.read_bytes(), published_notes.read_bytes())
            commands = log.read_text(encoding="utf-8")
            self.assertIn(f"gh:release view current-{'a' * 40}", commands)
            self.assertEqual(commands.count("gh:release download"), 2)
            self.assertNotIn("release upload", commands)
            self.assertNotIn("release edit", commands)
            self.assertNotIn("release delete", commands)
            self.assertNotIn("release create", commands)
            self.assertNotIn("git:push", commands)


if __name__ == "__main__":
    unittest.main()
