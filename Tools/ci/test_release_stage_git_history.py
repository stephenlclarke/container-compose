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
PACKAGE_DEPENDENCY_STAGE = (
    REPOSITORY_ROOT / "build-pipeline/modules/compose-package-dependencies.nf"
).read_text(encoding="utf-8")
PACKAGE_DEPENDENCY_COLLECTOR = (
    REPOSITORY_ROOT / "Tools/ci/collect-compose-package-dependencies.sh"
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

    def test_default_make_uses_the_recoverable_repository_graph(self) -> None:
        """The normal CLI entry point must use one durable build graph."""
        self.assertIn("all: pipeline", PIPELINE_MAKEFILE)
        self.assertIn("workflow: ci package", PIPELINE_MAKEFILE)

    def test_nextflow_runtime_is_immutable_and_not_homebrew_versioned(self) -> None:
        """A brew upgrade cannot move the orchestration runtime underneath a run."""
        self.assertNotIn("/opt/homebrew/Cellar", PIPELINE_MAKEFILE)
        self.assertIn("NEXTFLOW_JAVA_ARCHIVE_SHA256", PIPELINE_MAKEFILE)
        self.assertIn("NEXTFLOW_JAVA_TREE_SHA256", PIPELINE_MAKEFILE)
        self.assertIn("verify-java", PIPELINE_MAKEFILE)
        self.assertIn("bootstrap-nextflow-runtime.py", PIPELINE_MAKEFILE)
        self.assertIn("tools/temurin/$(NEXTFLOW_JAVA_RELEASE)", PIPELINE_MAKEFILE)
        self.assertIn("PIPELINE_HAWKEYE_VERSION := 6.5.1", PIPELINE_MAKEFILE)
        self.assertIn("PIPELINE_HAWKEYE_SHA256 :=", PIPELINE_MAKEFILE)
        self.assertIn(
            "tools/hawkeye/$(PIPELINE_HAWKEYE_VERSION)", PIPELINE_MAKEFILE
        )
        self.assertIn(
            '--hawkeye-installer "$(CURDIR)/scripts/install-hawkeye.sh"',
            PIPELINE_MAKEFILE,
        )

    def test_compose_package_consumes_verified_compiler_products(self) -> None:
        """Packaging must not rebuild products that the graph already proved."""
        package_stage = PIPELINE_SOURCE.split(
            "['container-compose', 'compose-package'", 1
        )[1].split("def releaseHostedSourceStageSpecs", 1)[0]
        self.assertIn("package-built", package_stage)
        self.assertNotIn("build-release", package_stage)
        self.assertNotIn("go-build", package_stage)
        self.assertIn("compose-release-build", PIPELINE_SOURCE)
        self.assertIn("compose-go-validation", PIPELINE_SOURCE)
        self.assertIn("COLLECT_COMPOSE_PACKAGE_DEPENDENCIES", PIPELINE_SOURCE)
        self.assertIn('/bin/bash -p ${collector}', PACKAGE_DEPENDENCY_STAGE)
        self.assertNotIn('!{collector}', PACKAGE_DEPENDENCY_STAGE)
        self.assertIn("install-pipeline-dependencies.py", PIPELINE_SOURCE)
        self.assertIn("noDependencyInstaller", PIPELINE_SOURCE)
        self.assertEqual(
            PIPELINE_SOURCE.count("        noDependencyInstaller,"), 4
        )
        self.assertEqual(PIPELINE_SOURCE.count("        dependencyInstaller,"), 1)
        self.assertIn("source-commit", REPOSITORY_STAGE)
        self.assertIn("dependency-count", REPOSITORY_STAGE)
        self.assertIn("PIPELINE_PACKAGE_MATERIALIZER", PIPELINE_MAKEFILE)
        pipeline_execute = PIPELINE_MAKEFILE.split("pipeline-execute:", 1)[1]
        recovery = pipeline_execute.index("--recover-only --destination")
        nextflow_run = pipeline_execute.index('"$${NEXTFLOW_BIN}" -log')
        self.assertLess(recovery, nextflow_run)
        self.assertEqual(
            pipeline_execute.count(
                '/usr/bin/lockf -t 30 "$$materialization_lock"'
            ),
            2,
        )
        release_build_stage = PIPELINE_SOURCE.split(
            "['container-compose', 'compose-release-build'", 1
        )[1].split("['container-builder-shim'", 1)[0]
        self.assertIn(
            "'Package.swift Package.resolved Sources Tests ",
            release_build_stage,
        )
        self.assertTrue(release_build_stage.rstrip().endswith("'none'],"))
        go_build_stage = PIPELINE_SOURCE.split(
            "['container-compose', 'compose-go-validation'", 1
        )[1].split("['container-compose', 'compose-tool-validation'", 1)[0]
        self.assertTrue(go_build_stage.rstrip().endswith("'none'],"))
        self.assertIn("source-payload-sha256", PACKAGE_DEPENDENCY_COLLECTOR)
        self.assertNotIn("source-commit", PACKAGE_DEPENDENCY_COLLECTOR)
        self.assertIn(
            "Tools/release/runtime-capabilities.json", package_stage
        )

    def test_nextflow_dependency_links_resolve_only_inside_pipeline_state(self) -> None:
        """Nextflow path staging must not defeat dependency-root validation."""
        self.assertIn(
            '"${params.stateRoot}/empty-dependencies"', PIPELINE_SOURCE
        )
        self.assertNotIn(
            '"${projectDir}/build-pipeline/empty-stage-dependencies"',
            PIPELINE_SOURCE,
        )
        self.assertIn("caches empty-dependencies", PIPELINE_MAKEFILE)
        self.assertIn(
            'require_managed_directory empty-dependencies', REPOSITORY_STAGE
        )
        self.assertIn(
            'canonical_dependencies="$(cd "$dependencies_root" && pwd -P)"',
            REPOSITORY_STAGE,
        )
        self.assertIn('"$state_root/work/"*', REPOSITORY_STAGE)
        self.assertIn(
            'stage dependency root escaped pipeline state', REPOSITORY_STAGE
        )

    def test_parallel_compose_lanes_each_enforce_their_coverage_floor(self) -> None:
        """Moving to the graph must preserve coverage without rerunning tests."""
        swift_stage = PIPELINE_SOURCE.split(
            "['container-compose', 'compose-swift-validation'", 1
        )[1].split("['container-compose', 'compose-go-validation'", 1)[0]
        go_stage = PIPELINE_SOURCE.split(
            "['container-compose', 'compose-go-validation'", 1
        )[1].split("['container-compose', 'compose-tool-validation'", 1)[0]
        self.assertIn("swift-coverage swift-coverage-check", swift_stage)
        self.assertNotIn("swift-test ", swift_stage)
        self.assertIn("go-test go-coverage-check go-build", go_stage)
        self.assertEqual(PIPELINE_SOURCE.count("swift-coverage "), 1)
        self.assertEqual(PIPELINE_SOURCE.count("go-test "), 1)

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
        )[1].split("['container-compose', 'compose-tool-validation'", 1)[0]
        compose_tools = PIPELINE_SOURCE.split(
            "['container-compose', 'compose-tool-validation'", 1
        )[1].split("['container-compose', 'compose-release-build'", 1)[0]

        self.assertIn("pipeline-source-check", compose_source)
        self.assertNotIn(" coverage-tools-test", compose_source)
        self.assertIn("-j4", compose_tools)
        self.assertIn("go-test go-coverage-check go-build", compose_go)
        self.assertNotIn("pipeline-tool-validation", compose_go)
        self.assertIn("pipeline-tool-validation", compose_tools)
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

    def test_stage_rechecks_inputs_and_tracked_source_before_success(self) -> None:
        """A stage cannot publish a receipt for inputs it changed while running."""
        command_start = REPOSITORY_STAGE.index("set +e\n    (")
        command_end = REPOSITORY_STAGE.index("verify_tool_closure", command_start)
        command_boundary = REPOSITORY_STAGE[command_start:command_end]

        self.assertIn("stage_input_sha256_before", REPOSITORY_STAGE[:command_start])
        self.assertIn("source_head_before", REPOSITORY_STAGE[:command_start])
        self.assertIn("stage_input_sha256_after", command_boundary)
        self.assertIn("source_head_after", command_boundary)
        self.assertIn("stage changed tracked source after preflight", command_boundary)
        self.assertIn("stage inputs changed while command ran", command_boundary)
        self.assertIn("printf 'schema\\t4\\n'", REPOSITORY_STAGE)
        self.assertIn("stage-inputs-sha256", REPOSITORY_STAGE)
        self.assertIn("source-tracked-clean", REPOSITORY_STAGE)

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
        self.assertIn("if: needs.changes.outputs.tools == 'true'", tool_tests_section)
        self.assertIn(
            "coverage-tools-test: coverage-python-tools-test "
            "release-tools-test ci-tools-test",
            PIPELINE_MAKEFILE,
        )

    def test_ci_keeps_handoff_only_changes_on_the_lightweight_path(self) -> None:
        classifier = CI_WORKFLOW.split("      - name: Classify changed files", 1)[
            1
        ].split("  source_checks:", 1)[0]
        lightweight = CI_WORKFLOW.split("  validate-lightweight:", 1)[1]

        self.assertIn("handoff: ${{ steps.filter.outputs.handoff }}", CI_WORKFLOW)
        self.assertIn("tools: ${{ steps.filter.outputs.tools }}", CI_WORKFLOW)
        self.assertIn("runtime: ${{ steps.filter.outputs.runtime }}", CI_WORKFLOW)
        self.assertIn(
            'python3 Tools/ci/classify-ci-changes.py "$changed_files"',
            classifier,
        )
        self.assertEqual(
            classifier.count("(.previous_filename // empty)"),
            2,
        )
        self.assertEqual(classifier.count("--no-renames"), 2)
        self.assertIn(
            "HANDOFF_CHANGE: ${{ needs.changes.outputs.handoff }}",
            lightweight,
        )
        self.assertIn("make upstream-handoff-registry-check", lightweight)
        self.assertIn("if: needs.changes.outputs.heavy == 'true'", CI_WORKFLOW)

    def test_ci_skips_runtime_validation_for_controller_only_changes(self) -> None:
        runtime_validation = CI_WORKFLOW.split("  validate_runtime:", 1)[1].split(
            "  prebuilt_binaries:", 1
        )[0]
        canonical_main = CI_WORKFLOW.split("  resolve-canonical-main:", 1)[1].split(
            "  validate:", 1
        )[0]
        aggregate = CI_WORKFLOW.split("  validate:", 1)[1].split(
            "  validate-lightweight:", 1
        )[0]

        self.assertIn(
            "needs.changes.outputs.runtime == 'true' || github.ref == 'refs/heads/main'",
            runtime_validation,
        )
        self.assertIn(
            "if: needs.changes.outputs.runtime == 'true' || github.ref == 'refs/heads/main'",
            canonical_main,
        )
        self.assertIn("TOOLS_SELECTED", aggregate)
        self.assertIn("RUNTIME_SELECTED", aggregate)
        self.assertIn("github.ref == 'refs/heads/main'", aggregate)
        self.assertIn("All selected validation scopes passed", aggregate)

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
