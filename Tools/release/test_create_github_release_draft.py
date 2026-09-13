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


SCRIPT = Path(__file__).with_name("create-github-release-draft.sh")


class CreateGitHubReleaseDraftTests(unittest.TestCase):
    def fixture(self, root: Path, mode: str) -> dict[str, str]:
        notes = root / "notes.md"
        notes.write_text("release notes\n", encoding="utf-8")
        fake_gh = root / "gh"
        fake_gh.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_TRACE}"
count=0
[[ ! -f "${TEST_COUNT}" ]] || count="$(<"${TEST_COUNT}")"
if [[ "${1:-}:${2:-}" == release:create ]]; then
  count=$((count + 1))
  printf '%s\n' "${count}" > "${TEST_COUNT}"
  if [[ "${TEST_MODE}" == transient && "${count}" == 1 ]]; then
    printf 'HTTP 500\n' >&2
    exit 1
  fi
  if [[ "${TEST_MODE}" == ambiguous && "${count}" == 1 ]]; then
    touch "${TEST_DRAFT}"
    printf 'connection closed\n' >&2
    exit 1
  fi
  if [[ "${TEST_MODE}" == mismatch ]]; then
    touch "${TEST_DRAFT}"
    printf 'release already exists\n' >&2
    exit 1
  fi
  if [[ "${TEST_MODE}" == persistent ]]; then
    printf 'HTTP 500\n' >&2
    exit 1
  fi
  touch "${TEST_DRAFT}"
  exit 0
fi
if [[ "${1:-}:${2:-}" == release:view && -f "${TEST_DRAFT}" ]]; then
  title="${RELEASE_TITLE}"
  [[ "${TEST_MODE}" != mismatch ]] || title="wrong release"
  jq -n \
    --arg tag "${RELEASE_TAG}" \
    --arg target "${PUBLISH_SHA}" \
    --arg title "${title}" \
    --argjson prerelease "${RELEASE_PRERELEASE}" \
    '{isDraft:true,isPrerelease:$prerelease,tagName:$tag,
      targetCommitish:$target,name:$title}'
  exit 0
fi
exit 1
""",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        return {
            **os.environ,
            "GH": str(fake_gh),
            "PUBLISH_SHA": "a" * 40,
            "RELEASE_GITHUB_RETRY_ATTEMPTS": "2",
            "RELEASE_GITHUB_RETRY_DELAY_SECONDS": "0",
            "RELEASE_LATEST": "true",
            "RELEASE_NOTES_FILE": str(notes),
            "RELEASE_PRERELEASE": "false",
            "RELEASE_REPOSITORY": "owner/repository",
            "RELEASE_TAG": "1.2.3",
            "RELEASE_TITLE": "1.2.3",
            "TEST_COUNT": str(root / "count"),
            "TEST_DRAFT": str(root / "draft"),
            "TEST_MODE": mode,
            "TEST_TRACE": str(root / "trace"),
        }

    def run_helper(
        self, environment: dict[str, str]
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(SCRIPT)],
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )

    def test_retries_a_definite_transient_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root, "transient")

            result = self.run_helper(environment)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "count").read_text().strip(), "2")
            self.assertIn("retrying exact draft", result.stderr)

    def test_accepts_an_exact_draft_after_an_ambiguous_response(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root, "ambiguous")

            result = self.run_helper(environment)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "count").read_text().strip(), "1")
            trace = (root / "trace").read_text(encoding="utf-8")
            self.assertIn("release view 1.2.3", trace)

    def test_bounds_persistent_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root, "persistent")

            result = self.run_helper(environment)

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "count").read_text().strip(), "2")
            self.assertIn("after 2 attempts", result.stderr)

    def test_rejects_a_draft_with_mismatched_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root, "mismatch")

            result = self.run_helper(environment)

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((root / "count").read_text().strip(), "2")
            self.assertIn("after 2 attempts", result.stderr)

    def test_rejects_unsafe_retry_configuration_before_github(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self.fixture(root, "transient")
            environment["RELEASE_GITHUB_RETRY_ATTEMPTS"] = "0"

            result = self.run_helper(environment)

            self.assertEqual(result.returncode, 2)
            self.assertFalse((root / "trace").exists())


if __name__ == "__main__":
    unittest.main()
