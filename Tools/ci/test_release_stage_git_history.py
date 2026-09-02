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

"""Regression tests for recoverable release-stage policy."""

from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PIPELINE_SOURCE = (REPOSITORY_ROOT / "main.nf").read_text(encoding="utf-8")
PIPELINE_CONFIG = (REPOSITORY_ROOT / "nextflow.config").read_text(
    encoding="utf-8"
)
REPOSITORY_STAGE = (
    REPOSITORY_ROOT / "build-pipeline/modules/repository-stage.nf"
).read_text(encoding="utf-8")
STABLE_RELEASE_WORKFLOW = (
    REPOSITORY_ROOT / ".github/workflows/stable-release-gate.yml"
).read_text(encoding="utf-8")


class ReleaseStageGitHistoryTests(unittest.TestCase):
    """Keep history-sensitive validation on verified Git bundles."""

    def test_history_sensitive_release_stages_request_commit_metadata(self) -> None:
        expected_declarations = (
            "'make,go,hawkeye', '.', 'commit,describe'",
            "'make,apple-swift,hawkeye,codesign', '.', 'commit'",
            "'make,apple-swift,python3,hawkeye,codesign', '.', "
            "'commit,describe'",
        )

        for declaration in expected_declarations:
            with self.subTest(declaration=declaration):
                self.assertIn(declaration, PIPELINE_SOURCE)

    def test_complete_repository_commit_capture_preserves_git_history(self) -> None:
        self.assertIn(
            'elif [[ "$source_paths" == . ]]; then\n'
            '        case ",$metadata_requirements," in\n'
            '            *,commit,*) preserve_git_history=1 ;;',
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "if ((preserve_git_history == 1)); then",
            PIPELINE_SOURCE,
        )
        self.assertIn("source_format=git-bundle", PIPELINE_SOURCE)

    def test_partial_source_capture_remains_a_tree_archive(self) -> None:
        self.assertIn(
            'elif [[ "$source_paths" == . ]]; then',
            PIPELINE_SOURCE,
        )
        self.assertIn("source_format=git-tree-archive", PIPELINE_SOURCE)

    def test_release_graph_terminates_after_first_failed_stage(self) -> None:
        self.assertIn("errorStrategy = 'terminate'", PIPELINE_CONFIG)
        self.assertIn("errorStrategy 'terminate'", REPOSITORY_STAGE)
        self.assertNotIn("errorStrategy = 'finish'", PIPELINE_CONFIG)
        self.assertNotIn("errorStrategy 'finish'", REPOSITORY_STAGE)

    def test_release_state_is_persistent_and_candidate_keyed(self) -> None:
        self.assertNotIn(
            "RELEASE_PIPELINE_STATE_ROOT: ${{ github.workspace }}",
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertIn(
            'runner_work_root="$(cd "${RUNNER_TEMP}/.." && pwd -P)"',
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertIn(
            'workspace_root="$(cd "${GITHUB_WORKSPACE}" && pwd -P)"',
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertIn(
            'state_parent="${runner_work_root}/.container-compose-release-pipeline"',
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertIn(
            'state_root="${state_parent}/${CANDIDATE_SHA}"',
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertIn(
            'state_root="$(cd "${state_root}" && pwd -P)"',
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertIn(
            '"${workspace_root}"|"${workspace_root}"/*)',
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertIn('[[ -L "${state_parent}" ]]', STABLE_RELEASE_WORKFLOW)
        self.assertIn('[[ -L "${state_root}" ]]', STABLE_RELEASE_WORKFLOW)
        self.assertIn(
            "printf 'RELEASE_PIPELINE_STATE_ROOT=%s\\n' \"${state_root}\" "
            '>> "${GITHUB_ENV}"',
            STABLE_RELEASE_WORKFLOW,
        )


if __name__ == "__main__":
    unittest.main()
