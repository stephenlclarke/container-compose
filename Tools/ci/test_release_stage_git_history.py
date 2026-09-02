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
PIPELINE_MAKEFILE = (REPOSITORY_ROOT / "Makefile").read_text(encoding="utf-8")
REPOSITORY_STAGE = (
    REPOSITORY_ROOT / "build-pipeline/modules/repository-stage.nf"
).read_text(encoding="utf-8")
STABLE_RELEASE_WORKFLOW = (
    REPOSITORY_ROOT / ".github/workflows/stable-release-gate.yml"
).read_text(encoding="utf-8")
CI_WORKFLOW = (REPOSITORY_ROOT / ".github/workflows/ci.yml").read_text(
    encoding="utf-8"
)


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

    def test_release_graph_pins_full_xcode_and_preflights_docc(self) -> None:
        self.assertIn(
            "DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer",
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertIn('developer_directory="${DEVELOPER_DIR:-}"', PIPELINE_SOURCE)
        self.assertIn(
            'DEVELOPER_DIR="$${DEVELOPER_DIR:-}"',
            PIPELINE_MAKEFILE,
        )
        self.assertIn("stable release gate requires full Xcode with DocC", PIPELINE_SOURCE)
        self.assertIn("DEVELOPER_DIR=\"$developer_directory\"", PIPELINE_SOURCE)
        self.assertIn("/usr/bin/xcrun --find docc", PIPELINE_SOURCE)
        self.assertIn("xcrun_shims+=(docc)", PIPELINE_SOURCE)
        self.assertIn("resolved_version=binary-sha256-only", PIPELINE_SOURCE)
        self.assertIn(
            'DEVELOPER_DIR="$recorded_developer_directory" \\\n'
            '                            /usr/bin/xcrun --find docc',
            REPOSITORY_STAGE,
        )

    def test_release_documentation_runs_after_functional_validation(self) -> None:
        self.assertIn("containerization-release-documentation", PIPELINE_SOURCE)
        self.assertIn("container-release-documentation", PIPELINE_SOURCE)
        self.assertIn("'make,apple-swift,docc'", PIPELINE_SOURCE)
        self.assertNotIn(
            "check containerization examples docs coverage",
            PIPELINE_SOURCE,
        )
        self.assertNotIn("check build dsym docs coverage-unit", PIPELINE_SOURCE)
        validation_gate = PIPELINE_SOURCE.index("validationCompletionGate =")
        documentation_run = PIPELINE_SOURCE.index("RUN_DOCUMENTATION_STAGE(")
        self.assertLess(validation_gate, documentation_run)
        self.assertIn("item[10] && item[11]", PIPELINE_SOURCE)
        self.assertIn("withName: RUN_DOCUMENTATION_STAGE", PIPELINE_CONFIG)
        self.assertIn("toolPreflightGate =", PIPELINE_SOURCE)
        self.assertIn(".combine(toolPreflightGate)", PIPELINE_SOURCE)
        self.assertIn(
            "Release documentation requires every functional validation",
            PIPELINE_SOURCE,
        )

    def test_container_validation_preflights_the_operator_keychain(self) -> None:
        self.assertIn(
            "params.operatorHome = ''",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "--operatorHome \"$$operator_home\"",
            PIPELINE_MAKEFILE,
        )
        self.assertIn(
            "system-security:/usr/bin/security",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            '/usr/bin/security show-keychain-info "$operator_login_keychain"',
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "operator login Keychain preflight exceeded its deadline",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "operator login Keychain must be unlocked before release validation",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "stage[1] == 'container-release-validation'",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "printf 'operator-home\\t%s\\n' \"$operator_home\"",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            '[[ "$stage_name" == container-release-validation ]]',
            REPOSITORY_STAGE,
        )
        self.assertIn(
            'metadata_environment+=("PIPELINE_OPERATOR_HOME=$operator_home")',
            REPOSITORY_STAGE,
        )
        self.assertIn(
            'HOME="$PIPELINE_OPERATOR_HOME" make --no-print-directory',
            PIPELINE_SOURCE,
        )
        self.assertNotIn(
            "configure_ephemeral_test_keychain",
            REPOSITORY_STAGE,
        )
        self.assertNotIn(
            "/usr/bin/security create-keychain",
            REPOSITORY_STAGE,
        )
        preflight = PIPELINE_SOURCE.index(
            '/usr/bin/security show-keychain-info "$operator_login_keychain"'
        )
        stage_preparation = PIPELINE_SOURCE.index("process PREFLIGHT_STAGE_TOOLS")
        self.assertLess(preflight, stage_preparation)

    def test_ci_parallelizes_independent_tool_suites(self) -> None:
        tool_tests_section = CI_WORKFLOW.split("  tool_tests:", 1)[1].split(
            "  validate_runtime:", 1
        )[0]
        self.assertIn("run: make source-checks", CI_WORKFLOW)
        self.assertIn("tool_tests:", CI_WORKFLOW)
        self.assertIn("fail-fast: true", CI_WORKFLOW)
        self.assertIn("target: release-tools-test", CI_WORKFLOW)
        self.assertIn("target: ci-tools-test", CI_WORKFLOW)
        self.assertIn("path: container-compose", tool_tests_section)
        self.assertIn('run: make "${TOOL_TEST_TARGET}"', tool_tests_section)
        self.assertIn("      - tool_tests", CI_WORKFLOW)
        self.assertIn("TOOL_TESTS_RESULT", CI_WORKFLOW)
        self.assertIn(
            "coverage-tools-test: coverage-python-tools-test "
            "release-tools-test ci-tools-test",
            PIPELINE_MAKEFILE,
        )

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
