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
RECOVERY_PROOF = (
    REPOSITORY_ROOT / "Tests/BuildPipeline/recovery-proof.nf"
).read_text(encoding="utf-8")


class ReleaseStageGitHistoryTests(unittest.TestCase):
    """Keep history-sensitive validation on verified Git bundles."""

    def test_stage_tools_include_nested_process_dependencies(self) -> None:
        devcontainer_stage = PIPELINE_SOURCE.split(
            "['devcontainer', 'devcontainer-source'", 1
        )[1].split("['container-k8s'", 1)[0]
        self.assertIn(
            "'make,python3,ruby,swiftformat,swiftlint,shellcheck,markdownlint,actionlint'",
            devcontainer_stage,
        )

    def test_compose_source_stage_is_fail_fast_and_tool_tests_run_once(self) -> None:
        compose_source = PIPELINE_SOURCE.split(
            "['container-compose', 'compose-source'", 1
        )[1].split("['container-builder-shim'", 1)[0]
        compose_go = PIPELINE_SOURCE.split(
            "['container-compose', 'compose-go-validation'", 1
        )[1].split("['container-builder-shim'", 1)[0]

        self.assertIn("pipeline-source-check", compose_source)
        self.assertNotIn(" coverage-tools-test", compose_source)
        self.assertIn("-j4", compose_go)
        self.assertIn("pipeline-tool-validation go-test go-build", compose_go)
        self.assertIn(
            "pipeline-source-check: source-preflight lint-static",
            PIPELINE_MAKEFILE,
        )
        self.assertEqual(PIPELINE_SOURCE.count("pipeline-tool-validation"), 1)

    def test_stage_root_preserves_unix_socket_path_budget(self) -> None:
        self.assertIn(
            "mktemp -d '/private/tmp/ccp.XXXXXX'",
            REPOSITORY_STAGE,
        )
        self.assertIn(
            '[[ "$execution_root" == /private/tmp/ccp.* ]]',
            REPOSITORY_STAGE,
        )
        longest_fixture_socket = (
            "/private/tmp/ccp.XXXXXX/tmp/tmpxxxxxxxx/"
            "app-root/engine-provider/provider.sock"
        )
        self.assertLessEqual(len(longest_fixture_socket.encode()), 103)

    def test_stage_forwards_cancellation_to_the_deadline_supervisor(self) -> None:
        self.assertIn("stage_runner_pid=$!", REPOSITORY_STAGE)
        self.assertIn(
            "trap 'forward_stage_signal TERM 143' TERM",
            REPOSITORY_STAGE,
        )
        self.assertIn(
            '/bin/kill -"$signal_name" "$stage_runner_pid"',
            REPOSITORY_STAGE,
        )
        self.assertIn(
            'exec /usr/bin/env -i "${clean_environment[@]}"',
            REPOSITORY_STAGE,
        )

    def test_history_sensitive_release_stages_request_commit_metadata(self) -> None:
        expected_declarations = (
            "'make,go,hawkeye', '.', 'commit,describe'",
            "'make,apple-swift,hawkeye,codesign', '.', 'commit'",
            "'make,apple-swift,python3,hawkeye,codesign,security', '.', "
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

    def test_release_validation_barrier_preserves_receipt_tuples(self) -> None:
        self.assertIn(
            ".concat(RUN_LIGHTWEIGHT_STAGE.out.receipt)\n"
            "        .collect(flat: false)",
            PIPELINE_SOURCE,
        )
        self.assertIn("receiptGate = channel.of(", RECOVERY_PROOF)
        self.assertIn(".collect(flat: false)", RECOVERY_PROOF)

    def test_container_validation_checks_the_operator_keychain_just_in_time(
        self,
    ) -> None:
        self.assertIn(
            "params.operatorHome = ''",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            '"--operatorHome=$$operator_home"',
            PIPELINE_MAKEFILE,
        )
        self.assertIn(
            "'make,apple-swift,python3,hawkeye,codesign,security'",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "security) tool_selector=/usr/bin/security",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "system-*|otool|codesign|docc|gofmt|security",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            '/usr/bin/security show-keychain-info '
            '"$PIPELINE_OPERATOR_LOGIN_KEYCHAIN"',
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "operator login Keychain readiness check exceeded its deadline",
            PIPELINE_SOURCE,
        )
        self.assertIn(
            "operator login Keychain must be unlocked before Container "
            "release coverage",
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
            '"PIPELINE_OPERATOR_LOGIN_KEYCHAIN=$operator_login_keychain"',
            REPOSITORY_STAGE,
        )
        self.assertIn(
            '"PIPELINE_DEADLINE_RUNNER=$deadline_runner"',
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
        container_stage = PIPELINE_SOURCE.split(
            "['container', 'container-release-validation'", 1
        )[1].split("['homebrew-tap'", 1)[0]
        build = container_stage.index("check build dsym")
        readiness = container_stage.index(
            '/usr/bin/security show-keychain-info '
            '"$PIPELINE_OPERATOR_LOGIN_KEYCHAIN"'
        )
        coverage = container_stage.index("coverage-unit")
        self.assertLess(build, readiness)
        self.assertLess(readiness, coverage)

        host_preflight = PIPELINE_SOURCE.split("process PREFLIGHT_HOST", 1)[1].split(
            "process PREFLIGHT_REPOSITORY", 1
        )[0]
        self.assertNotIn("show-keychain-info", host_preflight)
        self.assertNotIn("system-security", host_preflight)

        stage_preflight = PIPELINE_SOURCE.split(
            "process PREFLIGHT_STAGE_TOOLS", 1
        )[1].split("workflow PREFLIGHT_GRAPH", 1)[0]
        self.assertNotIn('[[ ! -d "$operator_home" ]]', stage_preflight)
        self.assertNotIn('[[ ! -f "$operator_login_keychain" ]]', stage_preflight)

    def test_operator_home_is_scoped_to_selected_container_validation(self) -> None:
        self.assertIn(
            'operator_home=; \\\n\trequires_operator_keychain=false;',
            PIPELINE_MAKEFILE,
        )
        self.assertIn(
            'if [[ "$$action" != plan ]] && '
            '[[ "$${PIPELINE_PROFILE}" == release-hosted ]]; then',
            PIPELINE_MAKEFILE,
        )
        self.assertIn(
            '[[ "$$selected_stage" == container-release-validation ]]',
            PIPELINE_MAKEFILE,
        )
        self.assertIn(
            'if [[ "$$requires_operator_keychain" == true ]]; then',
            PIPELINE_MAKEFILE,
        )
        self.assertNotIn("requiresOperatorKeychain", PIPELINE_SOURCE)

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

    def test_ci_keeps_handoff_only_changes_on_the_lightweight_path(self) -> None:
        classifier = CI_WORKFLOW.split("      - name: Classify changed files", 1)[
            1
        ].split("  source_checks:", 1)[0]
        handoff_case = classifier.split("docs/upstream/*)", 1)[1].split(";;", 1)[
            0
        ]
        lightweight = CI_WORKFLOW.split("  validate-lightweight:", 1)[1]

        self.assertIn("handoff: ${{ steps.filter.outputs.handoff }}", CI_WORKFLOW)
        self.assertIn("handoff=true", handoff_case)
        self.assertNotIn("heavy=true", handoff_case)
        self.assertIn(
            "HANDOFF_CHANGE: ${{ needs.changes.outputs.handoff }}",
            lightweight,
        )
        self.assertIn("make upstream-handoff-registry-check", lightweight)
        self.assertIn("if: needs.changes.outputs.heavy == 'true'", CI_WORKFLOW)

    def test_runtime_validation_uses_pinned_managed_macos_toolchain(
        self,
    ) -> None:
        runtime_validation = CI_WORKFLOW.split("  validate_runtime:", 1)[1].split(
            "  prebuilt_binaries:", 1
        )[0]

        self.assertIn("runs-on: macos-26", runtime_validation)
        self.assertIn(
            "DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer",
            runtime_validation,
        )
        self.assertNotIn("self-hosted", runtime_validation)

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
