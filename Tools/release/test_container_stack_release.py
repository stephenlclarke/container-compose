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

"""Regression tests for stable release policy in the stack helper."""

import os
import re
import shlex
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[2] / "scripts" / "CONTAINER_STACK_RELEASE.sh"
ROOT = SCRIPT.parent.parent
TEMPLATE = ROOT / "Tools" / "release" / "container-compose.rb.in"
HOMEBREW_WORKFLOW = ROOT / ".github" / "workflows" / "homebrew.yml"
PACKAGE_WORKFLOW = ROOT / ".github" / "workflows" / "prebuilt-binaries.yml"
STABLE_GATE_WORKFLOW = ROOT / ".github" / "workflows" / "stable-release-gate.yml"
SCHEDULED_STABLE_RELEASE_WORKFLOW = (
    ROOT / ".github" / "workflows" / "scheduled-stable-release.yml"
)
CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
CODEQL_WORKFLOW = ROOT / ".github" / "workflows" / "codeql.yml"
STACK_RELEASE_VALIDATION = ROOT / "Tools" / "ci" / "run-stack-release-validation.sh"
FORMULA_RENDERER = ROOT / "Tools" / "release" / "render-homebrew-stack-formulae.sh"
RUNNER_INSTALLER = ROOT / "scripts" / "install-scheduled-release-runner.sh"


class ContainerStackReleasePolicyTests(unittest.TestCase):
    """Stable releases must be new, immutable, and tap-owned."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.script = SCRIPT.read_text(encoding="utf-8")

    def test_existing_stable_tags_resume_without_changing_identity(self) -> None:
        release = self.script[self.script.index("release_current_stack() {") :]
        self.assertIn('if stable_tag_exists "${version}"', release)
        self.assertIn('resume_stable_release "${version}"', release)
        self.assertIn('ensure_latest_stable_retry "${version}"', self.script)
        self.assertIn("ensure_new_stable_release \"${version}\"", release)
        self.assertLess(
            release.index('resume_stable_release "${version}"'),
            release.index("ensure_new_stable_release \"${version}\""),
        )
        self.assertIn("ensure_stable_release_is_unpublished() {", self.script)
        self.assertIn("stable_release_is_published() {", self.script)
        self.assertIn("stable release %s already exists and is immutable", self.script)
        self.assertIn('if stable_release_is_published "${version}"; then', self.script)
        self.assertIn('dispatch_compose_stable_tap_repair "${version}"', self.script)
        self.assertIn("tag_new_stable_version() {", self.script)
        self.assertIn("stable tag already exists locally", self.script)
        self.assertIn("stable tag already exists remotely", self.script)

    def test_stable_tags_are_signed_and_verified_by_github(self) -> None:
        self.assertIn('tag -s "${version}" main', self.script)
        self.assertIn('verify_github_stable_tag_signature "${version}"', self.script)
        self.assertIn("GitHub did not verify stable tag", self.script)

    def test_release_helper_supports_an_isolated_stack_root(self) -> None:
        self.assertIn('ROOT="${CONTAINER_STACK_RELEASE_ROOT:-${HOME}/github}"', self.script)
        self.assertIn("CONTAINER_STACK_RELEASE_ROOT", self.script)

    def test_release_helper_recovers_only_its_unpublished_candidate_before_readiness(self) -> None:
        recovery = self.script[
            self.script.index("recover_unpublished_release_candidate() {") : self.script.index(
                "# Print and optionally execute a command."
            )
        ]
        release = self.script[self.script.index("release_current_stack() {") :]
        self.assertIn('git -C "${path}" reset --soft "${remote_head}"', recovery)
        self.assertNotIn("reset --hard", recovery)
        self.assertIn('"chore(release): prepare ${version}"', recovery)
        self.assertIn('"chore(deps): pin containerization "[0-9a-f]*', recovery)
        self.assertIn('"chore(deps): pin container "[0-9a-f]*', recovery)
        self.assertIn('"chore(deps): pin container stack "[0-9a-f]*" "[0-9a-f]*', recovery)
        self.assertIn("dirty worktree blocks recovery", recovery)
        self.assertLess(
            release.index('recover_unpublished_release_candidate "${version}"'),
            release.index("ensure_current_build_release_readiness"),
        )

    def test_release_plan_describes_the_stable_promotion_lanes(self) -> None:
        plan = self.script[self.script.index("\nplan() {") : self.script.index("\nmain() {")]
        self.assertIn("documented milestone soak override", plan)
        self.assertIn("maintenance with --+", plan)
        self.assertIn("documented operational", plan)

    def test_internal_dependency_pins_do_not_become_release_highlights(self) -> None:
        pin_commit = self.script[
            self.script.index("commit_containerization_package_pin() {") : self.script.index(
                "sync_containerization_package_pins() {"
            )
        ]
        self.assertIn("Release-Note: none", pin_commit)
        self.assertNotIn("Release-Highlight:", pin_commit)

    def test_release_helper_publishes_a_validated_container_pin_before_compose_resolves_it(self) -> None:
        candidate = self.script[
            self.script.index("publish_container_dependency_candidate() {") : self.script.index(
                "# Update Compose's remote runtime dependency"
            )
        ]
        sync = self.script[
            self.script.index("sync_containerization_package_pins() {") : self.script.index(
                "# Keep Compose's direct runtime dependencies aligned as one resolvable stack."
            )
        ]
        release = self.script[self.script.index("release_current_stack() {") :]

        self.assertIn('candidate_parent="$(git -C "${repo_dir}" rev-parse "${local_head}^")"', candidate)
        self.assertIn('candidate_subject="$(git -C "${repo_dir}" show -s --format=%s "${local_head}")"', candidate)
        self.assertIn('candidate_files="$(git -C "${repo_dir}" diff-tree --no-commit-id --name-only -r "${local_head}" | sort | paste -sd, -)"', candidate)
        self.assertIn('^chore\\(deps\\):\\ pin\\ containerization\\ [0-9a-f]{12}$', candidate)
        self.assertIn('"${candidate_files}" != "Package.resolved,Package.swift"', candidate)
        self.assertIn('make -C "${repo_dir}" check test', candidate)
        self.assertIn('git -C "${repo_dir}" push "${remote}" refs/heads/main', candidate)
        self.assertIn('remote_head="$(remote_main_commit "${CONTAINER_REPO}")"', candidate)
        self.assertIn("publish_container_dependency_candidate", sync)
        self.assertLess(
            sync.index('commit_containerization_package_pin "${CONTAINER_REPO}" "${ref}"'),
            sync.index("publish_container_dependency_candidate"),
        )
        self.assertLess(
            release.index("sync_containerization_package_pins"),
            release.index("sync_container_package_pin"),
        )

    def test_release_helper_signs_release_authored_commits(self) -> None:
        container_pin = self.script[
            self.script.index("commit_containerization_package_pin() {") : self.script.index(
                "publish_container_dependency_candidate() {"
            )
        ]
        compose_pin = self.script[
            self.script.index("commit_compose_stack_package_pins() {") : self.script.index(
                "# Keep the container and compose manifests aligned"
            )
        ]
        release = self.script[self.script.index("release_current_stack() {") :]

        self.assertIn("commit \\", container_pin)
        self.assertIn("    -S", container_pin)
        self.assertIn("commit \\", compose_pin)
        self.assertIn("    -S", compose_pin)
        self.assertIn('commit -S -m "chore(release): prepare ${version}"', release)

    def test_release_helper_pins_compose_to_the_exact_runtime_revision(self) -> None:
        runtime_pin = self.script[
            self.script.index("update_container_package_pin() {") : self.script.index(
                "sync_containerization_package_pins() {"
            )
        ]
        self.assertIn("https://github.com/stephenlclarke/container", runtime_pin)
        self.assertIn('unedit_release_dependency "${path}" container', runtime_pin)
        sync = self.script[
            self.script.index("sync_container_package_pin() {") : self.script.index(
                "write_release_stack_manifest() {"
            )
        ]
        self.assertIn('update_containerization_package_pin "${COMPOSE_REPO}" "${containerization_ref}" 0', sync)
        self.assertIn('update_container_package_pin "${container_ref}" 0', sync)
        self.assertLess(
            sync.index('update_containerization_package_pin "${COMPOSE_REPO}" "${containerization_ref}" 0'),
            sync.index('update_container_package_pin "${container_ref}" 0'),
        )
        self.assertLess(
            sync.index('update_container_package_pin "${container_ref}" 0'),
            sync.index('unedit_release_dependency "${path}" containerization'),
        )
        self.assertLess(
            sync.index('unedit_release_dependency "${path}" containerization\n'),
            sync.index('unedit_release_dependency "${path}" container\n'),
        )
        self.assertLess(
            sync.index('unedit_release_dependency "${path}" container\n'),
            sync.index('swift package --package-path "${path}" resolve'),
        )
        self.assertIn("commit_compose_stack_package_pins", sync)
        self.assertIn("chore(deps): pin container stack", self.script)
        self.assertIn("Release-Note: none", runtime_pin)
        self.assertIn("sync_container_package_pin", self.script)

    def test_containerization_pin_supports_literal_and_named_revisions(self) -> None:
        revision = "a" * 40
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            named = root / "container"
            named.mkdir()
            named_manifest = named / "Package.swift"
            named_manifest.write_text(
                textwrap.dedent(
                    """\
                    import PackageDescription

                    let containerizationRevision = "old"
                    let package = Package(
                        name: "container",
                        dependencies: [
                            .package(
                                url: "https://github.com/stephenlclarke/containerization.git",
                                revision: containerizationRevision
                            ),
                        ]
                    )
                    """
                ),
                encoding="utf-8",
            )
            named_result = self.run_release_function(
                root,
                f"update_containerization_package_pin container {revision} 0",
            )
            self.assertEqual(named_result.returncode, 0, named_result.stderr)
            named_text = named_manifest.read_text(encoding="utf-8")
            self.assertIn(f'let containerizationRevision = "{revision}"', named_text)
            self.assertIn("revision: containerizationRevision", named_text)

            literal = root / "container-compose"
            literal.mkdir()
            literal_manifest = literal / "Package.swift"
            literal_manifest.write_text(
                textwrap.dedent(
                    """\
                    import PackageDescription

                    let package = Package(
                        name: "container-compose",
                        dependencies: [
                            .package(
                                url: "https://github.com/stephenlclarke/containerization.git",
                                revision: "old"
                            ),
                        ]
                    )
                    """
                ),
                encoding="utf-8",
            )
            literal_result = self.run_release_function(
                root,
                f"update_containerization_package_pin container-compose {revision} 0",
            )
            self.assertEqual(literal_result.returncode, 0, literal_result.stderr)
            self.assertIn(
                f'revision: "{revision}"',
                literal_manifest.read_text(encoding="utf-8"),
            )

            unsupported = root / "unsupported"
            unsupported.mkdir()
            (unsupported / "Package.swift").write_text(
                '.package(url: "https://github.com/apple/containerization.git", branch: "main")\n',
                encoding="utf-8",
            )
            unsupported_result = self.run_release_function(
                root,
                f"update_containerization_package_pin unsupported {revision} 0",
            )
            self.assertNotEqual(unsupported_result.returncode, 0)
            self.assertIn(
                "is missing the stephenlclarke containerization dependency",
                unsupported_result.stderr,
            )

    def test_release_helper_resolves_immutable_dependencies(self) -> None:
        helper = self.script[
            self.script.index("unedit_release_dependency() {") : self.script.index(
                "# Update one SwiftPM manifest to the current containerization stack revision."
            )
        ]
        self.assertIn("swift package --package-path", helper)
        self.assertIn("unedit --force", helper)
        self.assertIn("not in edit mode", helper)

    def test_release_helper_has_no_existing_stable_package_mode(self) -> None:
        self.assertNotIn("package VERSION", self.script)
        self.assertNotIn("package_existing_stable", self.script)
        self.assertNotIn("sync_source_homebrew_formula", self.script)
        self.assertIn("formula-only recovery from immutable release assets", self.script)
        self.assertIn('repair_tap=true', self.script)

    def test_release_formula_is_tap_owned_and_template_backed(self) -> None:
        self.assertFalse((ROOT / "Formula" / "container-compose.rb").exists())
        self.assertTrue(TEMPLATE.is_file())
        workflow = HOMEBREW_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Tools/release/container-compose.rb.in", workflow)
        self.assertNotIn("Formula/container-compose.rb", workflow)

    def test_stable_formulae_use_runtime_packaged_with_the_stable_release(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('runtime_asset="container-release-arm64.tar.gz"', workflow)
        self.assertIn('runtime_repository="${GITHUB_REPOSITORY}"', workflow)
        self.assertIn("RELEASE_EXTRA_ASSETS_FILE=\"${extra_assets}\"", workflow)
        self.assertTrue(FORMULA_RENDERER.is_file())
        self.assertIn("RUNTIME_ASSET", FORMULA_RENDERER.read_text(encoding="utf-8"))

    def test_runtime_archive_is_verified_before_formula_promotion(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        renderer = FORMULA_RENDERER.read_text(encoding="utf-8")
        self.assertIn('tar -tzf "${runtime_local_asset}" >/dev/null', workflow)
        self.assertIn("grep -Fx './bin/container'", workflow)
        self.assertIn('verify_archive_entry "${RUNTIME_ASSET}" "./bin/container" "runtime"', renderer)
        self.assertIn("published ${label} package archive is corrupt", renderer)

    def test_release_checksum_sidecars_use_published_asset_basenames(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        writer = "Tools/release/write-sha256-sidecar.py"

        self.assertIn(f'$(PYTHON) {writer} "$(PLUGIN_ARCHIVE)"', makefile)
        self.assertEqual(
            workflow.count(
                f'python3 container-compose/{writer} "${{runtime_local_asset}}"'
            ),
            2,
        )

    def test_formula_renderer_uses_an_authenticated_published_release(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        renderer_step = workflow[
            workflow.index("- name: Render matched Homebrew stack formulae") : workflow.index(
                "- name: Commit atomic Homebrew stack update"
            )
        ]
        renderer = FORMULA_RENDERER.read_text(encoding="utf-8")
        self.assertIn("GH_TOKEN: ${{ github.token }}", renderer_step)
        self.assertIn("release-tools/Tools/release/render-homebrew-stack-formulae.sh", renderer_step)
        self.assertNotIn("gh release download", renderer_step)
        self.assertIn("gh release view", renderer)
        self.assertIn("gh release download", renderer)
        self.assertIn("verify_release_checksum", renderer)
        self.assertIn("update-homebrew-container-formula.py", renderer)
        self.assertNotIn("${CONTAINER_SOURCE_DIR}/scripts/update-homebrew-formula.py", renderer)
        self.assertIn("compose/bin/compose", renderer)

    def test_published_stable_tap_repair_does_not_repackage_or_replace_assets(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        repair = workflow[workflow.index("repair-stable-tap:") :]
        self.assertIn("repair_tap:", workflow)
        self.assertIn("Repair Stable Homebrew Formulae", repair)
        self.assertIn("needs.resolve-publish-context.outputs.repair_tap == 'true'", repair)
        self.assertIn("Checkout tagged container-compose source", repair)
        self.assertIn("Checkout immutable release control tools", repair)
        self.assertIn("Resolve pinned container dependency", repair)
        self.assertIn("Require the hosted release authority", repair)
        self.assertIn("candidate-bound Stable Release Authority", repair)
        self.assertIn("render-homebrew-stack-formulae.sh", repair)
        self.assertNotIn("Build matched runtime package", repair)
        self.assertNotIn("Publish GitHub release", repair)
        self.assertNotIn("Attest release package", repair)

    def test_release_helper_tracks_the_stable_package_dispatch_by_tag(self) -> None:
        self.assertIn('title="Prebuilt Binaries · ${version}"', self.script)
        self.assertIn("--json databaseId,displayTitle", self.script)
        self.assertIn('latest_compose_package_dispatch_run "${version}"', self.script)

    def test_current_formulae_use_the_matched_runtime_in_the_single_prerelease(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('runtime_asset="container-current-${PUBLISH_SHA:0:12}-arm64.tar.gz"', workflow)
        self.assertIn('runtime_repository="${GITHUB_REPOSITORY}"', workflow)
        self.assertIn('release_tag="current"', workflow)
        self.assertIn('release_title="Current build"', workflow)
        self.assertIn('asset="container-compose-plugin-current-${short_sha}-arm64.tar.gz"', workflow)
        self.assertIn('highlights_asset="release-highlights-current-${short_sha}.json"', workflow)
        self.assertIn("python3 Tools/release/current-formula-version.py", workflow)
        self.assertIn('--run-number "${GITHUB_RUN_NUMBER}"', workflow)
        self.assertIn('--commit "${PUBLISH_SHA}"', workflow)
        self.assertNotIn('formula_version="current.${short_sha}"', workflow)
        self.assertIn(
            "FORMULA_VERSION: ${{ steps.lane.outputs.formula_version }}",
            workflow,
        )
        self.assertIn('runtime_version="${FORMULA_VERSION}"', workflow)
        self.assertNotIn('runtime_version="current.${PUBLISH_SHA:0:12}"', workflow)
        self.assertIn('RELEASE_PHASE="${release_phase}"', workflow)
        self.assertIn("Publish Current build release", workflow)
        self.assertLess(
            workflow.index("Commit atomic Homebrew stack update"),
            workflow.index("Publish Current build release"),
        )
        self.assertIn('RELEASE_MUTABLE="${release_mutable}"', workflow)
        self.assertIn("--delete-superseded-current-releases", workflow)
        self.assertIn("release_notes_args=(", workflow)

    def test_current_build_records_and_publishes_the_matched_vhs_demo(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn('demo_asset="container-compose-demo-current.gif"', workflow)
        package = workflow[workflow.index("  package:") : workflow.index("  repair-stable-tap:")]
        self.assertIn(
            "runs-on: [self-hosted, macOS, ARM64, container-compose-release, container-compose-current]",
            package,
        )
        self.assertIn("validated for GitHub", package)
        self.assertIn("Install VHS", workflow)
        self.assertIn("Generate Current build VHS recording", workflow)
        self.assertIn('tar -xzf "${RUNTIME_ARCHIVE}" -C "${demo_root}"', workflow)
        self.assertIn(
            'tar -xzf "${PLUGIN_ARCHIVE}" -C "${demo_root}/libexec/container-plugins"',
            workflow,
        )
        self.assertIn('export CONTAINER_INSTALL_ROOT="${demo_root}"', workflow)
        self.assertIn('export CONTAINER_APP_ROOT="${demo_app_root}"', workflow)
        self.assertIn('trap cleanup EXIT', workflow)
        self.assertIn('"${container_binary}" system stop || true', workflow)
        self.assertIn("docs/container-compose-demo.tape", workflow)
        self.assertIn("VHS itself is the fail-closed runtime gate", workflow)
        self.assertIn("bash Tools/release/record-vhs-live-demo.sh", workflow)
        self.assertNotIn("record_monitoring_stack_transcript", workflow)
        self.assertNotIn("demo_transcript", workflow)
        self.assertNotIn("current-build-demo-transcript", workflow)
        self.assertNotIn('"${container_binary}" system start', workflow)
        recorder = (
            ROOT / "Tools" / "release" / "record-vhs-live-demo.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('rm -f "${output}" "${vhs_log}"', recorder)
        self.assertIn('could not open ttyd', recorder)
        self.assertIn('refusing to retry a live-demo failure', recorder)
        self.assertIn('vhs validate "${tape}"', workflow)
        self.assertIn('"${vhs_bin}" "${tape}"', recorder)
        self.assertIn("Current build VHS recording is missing", workflow)
        self.assertIn('--current-asset "${{ steps.lane.outputs.demo_asset }}"', workflow)
        tape = (ROOT / "docs" / "container-compose-demo.tape").read_text(encoding="utf-8")
        self.assertIn('Set TypingSpeed 48ms', tape)
        self.assertIn('Set Width 1600', tape)
        self.assertIn('$CONTAINER_COMPOSE_DEMO_ROOT', tape)
        self.assertIn('Type "container system start', tape)
        self.assertIn('&& container system status', tape)
        self.assertIn('--app-root $CONTAINER_APP_ROOT', tape)
        self.assertIn('--install-root $CONTAINER_INSTALL_ROOT', tape)
        self.assertLess(
            tape.index('Type "container system start'),
            tape.index('Type "container compose version"'),
        )
        self.assertEqual(tape.count('Wait+Screen@900s /status +running/'), 1)
        self.assertIn('Type "container compose version"', tape)
        live_up = (
            "container compose --ansi never --progress plain "
            "-f examples/monitoring-stack/docker-compose.yaml up --detach --wait "
            "--wait-timeout 900 --quiet-pull nginx alertmanager && clear && container compose "
            "-f examples/monitoring-stack/docker-compose.yaml ps"
        )
        self.assertEqual(tape.count(live_up), 2)
        self.assertEqual(tape.count("--quiet-pull nginx alertmanager"), 2)
        retained_volume_down = (
            "container compose -f examples/monitoring-stack/docker-compose.yaml "
            "down --remove-orphans && clear && container compose "
            "-f examples/monitoring-stack/docker-compose.yaml volumes --format json"
        )
        final_volume_down = (
            "container compose -f examples/monitoring-stack/docker-compose.yaml "
            "down --volumes --remove-orphans && clear && container compose "
            "-f examples/monitoring-stack/docker-compose.yaml ps --all"
        )
        self.assertIn(retained_volume_down, tape)
        self.assertIn(final_volume_down, tape)
        self.assertEqual(tape.count("&& clear && container compose"), 4)
        self.assertEqual(tape.count("stats --no-stream nginx alertmanager"), 2)
        self.assertEqual(tape.count("Wait+Screen@90s /CONTAINER ID/"), 2)
        nginx_health = (
            "container compose -f examples/monitoring-stack/docker-compose.yaml "
            "exec --no-tty nginx wget -qO- http://127.0.0.1/healthz"
        )
        alertmanager_readiness = (
            "container compose -f examples/monitoring-stack/docker-compose.yaml "
            "exec --no-tty alertmanager wget -qO- "
            "http://127.0.0.1:9093/alertmanager/-/ready"
        )
        self.assertEqual(tape.count(nginx_health), 2)
        self.assertEqual(tape.count(alertmanager_readiness), 2)
        self.assertNotIn("curl -4fsS", tape)
        self.assertIn("volumes --format json", tape)
        self.assertIn("container-compose-volume-reuse-ok", tape)
        self.assertIn("down --volumes --remove-orphans", tape)
        self.assertIn('Type "container system stop; container system status"', tape)
        self.assertIn('Wait+Screen@30s /not running/', tape)
        self.assertEqual(tape.count("--wait-timeout 900"), 2)
        self.assertEqual(
            tape.count("Wait+Screen@900s /nginx.*r[[:space:]]*unning/"),
            2,
        )
        self.assertNotIn("--wait-timeout 900 &&", tape)
        self.assertNotIn("monitoring-stack-.*alertmanager.*running", tape)
        self.assertNotIn("Wait+Screen@300s /SERVICE.*STATUS/", tape)
        self.assertNotIn("Wait+Screen@90s /NAME/", tape)
        self.assertNotIn("Wait+Screen@120s /Removed/", tape)
        self.assertNotIn("CONTAINER_COMPOSE_DEMO_TRANSCRIPT", tape)
        self.assertNotIn("replay()", tape)
        self.assertNotIn("marker()", tape)
        self.assertNotIn("TAPE_TRANSCRIPT_", tape)
        self.assertIn("Ctrl+L", tape)
        self.assertNotIn("Sleep 6s", tape)
        self.assertNotIn("--dry-run", tape)
        self.assertIn(
            "releases/download/current/container-compose-demo-current.gif",
            readme,
        )
        monitoring_stack = (ROOT / "examples" / "monitoring-stack" / "docker-compose.yaml").read_text(
            encoding="utf-8"
        )
        self.assertIn("nginx_cache:/var/cache/nginx", monitoring_stack)
        self.assertIn("nginx_cache: {}", monitoring_stack)

    def test_package_gate_requires_full_quality_evidence(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        start = workflow.index("CI intentionally has an active Validate job")
        end = workflow.index("elif [[ \"${WORKFLOW_RUN_HEAD_BRANCH}\" == \"main\" ]];", start)
        gate = workflow[start:end]

        self.assertIn("wait_for_complete_validate_conclusions()", workflow)
        self.assertIn(
            'wait_for_complete_validate_conclusions "${WORKFLOW_RUN_ID}"',
            gate,
        )
        self.assertIn(
            'github_authority_query "jobs for validated CI run ${run_id}"',
            workflow,
        )
        self.assertIn("api --paginate --slurp", workflow)
        self.assertIn("refusing package publication because validated CI job evidence could not be read", gate)
        self.assertIn(
            '[.[] | .jobs[] | select(.name == "Validate" or .name == "Validate Runtime") | .conclusion]',
            workflow,
        )
        self.assertIn('any(.[]; . == "success")', gate)
        self.assertIn('all(.[]; . == "success" or . == "skipped")', gate)
        self.assertIn('if length == 0 then "missing" else join(",") end', gate)
        self.assertIn('map(. // "pending") | join(",")', gate)
        self.assertIn(
            "refusing package publication because CI Validate results did not settle",
            gate,
        )
        self.assertIn('quality_release_kind="current"', workflow)
        self.assertIn('quality_release_kind="stable"', workflow)
        self.assertIn('--release-kind "${quality_release_kind}"', workflow)
        self.assertIn('python3 Tools/release/release-notes.py "${release_notes_args[@]}"', workflow)
        self.assertIn(
            "--component-repo container-builder-shim=../container-builder-shim",
            workflow,
        )
        self.assertIn(
            "--component-repo containerization=../containerization",
            workflow,
        )
        self.assertIn("--component-repo container=../container", workflow)
        self.assertIn('quality_snapshot_args=(', workflow)
        self.assertIn(
            'wait_for_successful_main_sonarqube_scan "${WORKFLOW_RUN_HEAD_SHA}"',
            workflow,
        )
        self.assertNotIn('nc -z -w 5 sonarcloud.io 443', workflow)
        self.assertNotIn('SonarQube was unavailable during promotion', workflow)
        self.assertNotIn('SONARQUBE_SNAPSHOT_REQUIRED', workflow)
        self.assertNotIn('--allow-missing-sonarqube', workflow)

    def test_package_gate_retries_unsettled_validate_conclusions(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        start = workflow.index("wait_for_complete_validate_conclusions()")
        end = workflow.index('if [[ "${GITHUB_EVENT_NAME}" == "workflow_run" ]]', start)
        retry = workflow[start:end]
        settled_filter = "length > 0 and all(.[]; . != null)"

        self.assertIn(settled_filter, retry)
        self.assertIn("attempt=1 max_attempts=12 retry_delay=5", retry)
        self.assertIn("CI Validate job conclusions for run %s are not visible yet", retry)
        for payload, expected in (
            ('[null, "skipped", "success"]', False),
            ("[]", False),
            ('["skipped", "success"]', True),
            ('["failure", "skipped"]', True),
        ):
            result = subprocess.run(
                ["jq", "-e", settled_filter],
                input=payload,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(
                result.returncode == 0,
                expected,
                msg=f"unexpected settled classification for {payload}: {result.stderr}",
            )

    def test_current_package_skips_only_when_the_pointer_already_matches_main(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Skipping current package because current already points at", workflow)
        self.assertIn("refs/tags/current^{}", workflow)
        self.assertIn('current_tag_sha="$(', workflow)

    def test_current_package_rechecks_main_before_release_mutations(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        freshness = workflow[
            workflow.index("- name: Verify current source is still latest") : workflow.index(
                "- name: Stage release assets and notes"
            )
        ]
        self.assertIn('current_main="$(', freshness)
        self.assertIn("Skipping superseded current package", freshness)
        self.assertIn('printf \'publish=%s\\n\' "${publish}" >> "$GITHUB_OUTPUT"', freshness)
        self.assertEqual(
            workflow.count("if: steps.current-freshness.outputs.publish == 'true'"),
            8,
        )

    def test_current_package_workflow_only_follows_successful_main_ci(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("workflow_run:", workflow)
        self.assertIn("branches:\n      - main", workflow)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", workflow)
        self.assertIn(
            'if [[ "${WORKFLOW_RUN_EVENT}" != "push" && "${WORKFLOW_RUN_EVENT}" != "workflow_dispatch" ]]',
            workflow,
        )
        self.assertIn('elif [[ "${WORKFLOW_RUN_HEAD_BRANCH}" == "main" ]]', workflow)
        self.assertIn("main_ci_has_successful_sonarqube_scan()", workflow)
        self.assertIn("wait_for_successful_main_sonarqube_scan()", workflow)
        self.assertIn('.event == "workflow_dispatch"', workflow)
        self.assertIn("Skipping current package for %s until successful exact-main CI", workflow)
        self.assertIn("timeout-minutes: 120", workflow)
        self.assertIn("name: Cache SwiftPM build artifacts", workflow)
        self.assertIn("container-compose/.build", workflow)
        self.assertIn("container/.build", workflow)
        self.assertIn('select(.headBranch == "main" and .status == "completed"', workflow)

    def test_stable_and_current_release_authority_select_main_ci(self) -> None:
        stable_gate = STABLE_GATE_WORKFLOW.read_text(encoding="utf-8")
        package = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("--json databaseId,status,conclusion,headBranch", stable_gate)
        self.assertIn('select(.headBranch == "main")', stable_gate)
        self.assertIn("--json status,conclusion,headBranch", package)
        self.assertIn('select(.headBranch == "main" and .status == "completed"', package)

    def test_main_codeql_analysis_is_not_skipped_and_validate_context_is_stable(self) -> None:
        codeql = CODEQL_WORKFLOW.read_text(encoding="utf-8")
        ci = CI_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            "if: github.event_name != 'pull_request' || needs.changes.outputs.go == 'true'",
            codeql,
        )
        self.assertIn(
            "if: github.event_name == 'pull_request' && needs.changes.outputs.go != 'true'",
            codeql,
        )
        self.assertNotIn("name: Validate Lightweight", ci)
        self.assertEqual(len(re.findall(r"^    name: Validate$", ci, re.MULTILINE)), 2)
        self.assertIn("name: CodeQL", codeql)
        self.assertIn("needs.analyze.result", codeql)
        self.assertIn("needs.analyze-skipped.result", codeql)

    def test_stable_package_requires_candidate_bound_release_authority(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        authority = workflow[
            workflow.index("- name: Require the hosted release authority") : workflow.index(
                "- name: Build matched runtime package"
            )
        ]
        tag_authority = authority[authority.index("tag)") : authority.index("*)")]
        self.assertIn("checks: read", workflow)
        self.assertIn("PUBLISH_REF_NAME", authority)
        self.assertIn('authority_name="Stable Release Authority (${PUBLISH_REF_NAME})"', tag_authority)
        self.assertIn("commits/${PUBLISH_SHA}/check-runs?per_page=100", tag_authority)
        self.assertIn(".app.slug", tag_authority)
        self.assertIn("github-actions", tag_authority)
        self.assertIn(".external_id", tag_authority)
        self.assertIn('gh run view "${authority_run_id}"', tag_authority)
        self.assertIn("workflowName", tag_authority)
        self.assertIn("Stable Release Gate", tag_authority)
        self.assertIn("workflow_dispatch", tag_authority)
        self.assertNotIn('workflow="stable-release-gate.yml"', tag_authority)
        self.assertNotIn('--commit "${PUBLISH_SHA}"', tag_authority)

    def test_package_authority_requires_a_successful_candidate_bound_gate(self) -> None:
        accepted = self.run_package_authority_step("tag", "0.6.70", "29288195238", "success")
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        missing_authority = self.run_package_authority_step("tag", "0.6.70", "", "success")
        self.assertNotEqual(missing_authority.returncode, 0)
        self.assertIn("candidate-bound Stable Release Authority", missing_authority.stderr)

        failed_gate = self.run_package_authority_step("tag", "0.6.70", "29288195238", "")
        self.assertNotEqual(failed_gate.returncode, 0)
        self.assertIn("successful Stable Release Gate authority", failed_gate.stderr)

        branch = self.run_package_authority_step("branch", "main", "", "success")
        self.assertEqual(branch.returncode, 0, branch.stderr)

    def test_release_gate_includes_sibling_coverage_and_runtime_integration(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        validation = STACK_RELEASE_VALIDATION.read_text(encoding="utf-8")
        self.assertIn("check-licenses vet lint coverage build", validation)
        self.assertIn("run-stack-release-validation.sh full", makefile)
        self.assertIn("run-stack-release-validation.sh hosted", makefile)
        self.assertIn(
            "containerization_targets=(check containerization examples docs coverage fetch-default-kernel integration)",
            validation,
        )
        self.assertIn(
            "container_targets=(check container dsym docs coverage)",
            validation,
        )
        self.assertIn(
            "release-gate-hosted: container-stack-hosted-release-validation ci",
            makefile,
        )
        self.assertIn(
            "containerization_targets=(check containerization examples docs coverage)",
            validation,
        )
        self.assertIn(
            "container_targets=(check container dsym docs coverage-unit)",
            validation,
        )
        self.assertIn("CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1", makefile)
        self.assertIn("docker-compose-devices-parity", makefile)
        self.assertIn("docker-compose-named-volume-reuse-parity", makefile)
        self.assertIn(
            "release-gate: container-stack-release-validation ci swift-runtime-test docker-compose-parity",
            makefile,
        )
        self.assertIn("DOCKER_COMPOSE_REFERENCE_VERSION ?= 5.3.1", makefile)
        self.assertIn("DOCKER_COMPOSE_E2E_REF ?= f32009d4a2c687dd405398cc7975d12dccaf8dff", makefile)
        self.assertNotIn("repackage-release", makefile)

    def test_phase5_builder_gaps_exception_is_local_and_expires_at_phase5(self) -> None:
        validation = STACK_RELEASE_VALIDATION.read_text(encoding="utf-8")
        self.assertIn(
            "CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON",
            self.script,
        )
        self.assertIn("0.7.*|0.8.*|0.9.*", self.script)
        self.assertIn("not %s", self.script)
        self.assertIn('"${RELEASE_INTENT}" != "milestone"', self.script)
        self.assertIn("TestCLIBuilderSerial.swift", validation)
        self.assertIn("TestCLIBuilderLocalOutputSerial.swift", validation)
        self.assertIn("TestCLIBuilderTarExportSerial.swift", validation)
        self.assertIn("phase5_excluded_serial_suites", validation)
        self.assertIn('"${mode}" != "full"', validation)
        self.assertIn("SERIAL_TEST_SUITES=${serial_test_suites}", validation)

    def test_phase5_builder_gaps_exception_accepts_only_pre_phase5_milestones(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            setup = "\n".join(
                [
                    "PHASE5_BUILDER_GAPS_EXCEPTION_REASON='tracked Phase 5 Builder work'",
                    "RELEASE_INTENT=milestone",
                ]
            )
            for version in ("0.7.0", "0.8.0", "0.9.0", "0.9.4"):
                accepted = self.run_release_function(
                    root,
                    f"ensure_phase5_builder_gaps_exception {version}",
                    shell_setup=setup,
                )
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                self.assertIn(
                    f"pre-Phase-5 Builder-gap exception accepted for {version}",
                    accepted.stdout,
                )

            for version in ("0.6.70", "0.10.0", "1.0.0"):
                rejected = self.run_release_function(
                    root,
                    f"ensure_phase5_builder_gaps_exception {version}",
                    shell_setup=setup,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn(
                    "permitted only for pre-Phase-5 0.7.x through 0.9.x releases",
                    rejected.stderr,
                )

            non_milestone = self.run_release_function(
                root,
                "ensure_phase5_builder_gaps_exception 0.8.0",
                shell_setup=setup.replace("milestone", "maintenance"),
            )
            self.assertNotEqual(non_milestone.returncode, 0)
            self.assertIn(
                "requires CONTAINER_STACK_RELEASE_INTENT=milestone",
                non_milestone.stderr,
            )

    def test_hosted_stack_validation_excludes_virtualization_commands(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compose = root / "container-compose"
            builder = root / "container-builder-shim"
            containerization = root / "containerization"
            container = root / "container"
            tap = root / "homebrew-tap"
            for checkout in (compose, builder, containerization, container):
                checkout.mkdir()
                (checkout / "Makefile").touch()
            serial_tests = container / "Tests" / "IntegrationTests" / "Build"
            serial_tests.mkdir(parents=True)
            (serial_tests / "TestCLIBuilderSerial.swift").touch()
            (serial_tests / "TestCLIBuilderLocalOutputSerial.swift").touch()
            (serial_tests / "TestCLIBuilderTarExportSerial.swift").touch()
            (serial_tests / "TestCLIOtherSerial.swift").touch()
            (tap / "Formula").mkdir(parents=True)
            (tap / "Formula" / "container-compose.rb").touch()

            tools = root / "tools"
            tools.mkdir()
            log = root / "commands.log"
            for name in ("make", "ruby"):
                tool = tools / name
                tool.write_text(
                    "#!/usr/bin/env bash\n"
                    "printf '%s:%s\\n' \"$(basename \"$0\")\" \"$*\" >> \"${STACK_VALIDATION_LOG:?}\"\n",
                    encoding="utf-8",
                )
                tool.chmod(0o755)

            environment = os.environ.copy()
            environment.pop(
                "CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON",
                None,
            )
            environment["PATH"] = f"{tools}{os.pathsep}{environment['PATH']}"
            environment["STACK_VALIDATION_LOG"] = str(log)
            validation_paths = [
                str(compose),
                str(builder),
                str(containerization),
                str(container),
                str(tap),
            ]

            full = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(full.returncode, 0, full.stderr)
            full_commands = log.read_text(encoding="utf-8")
            self.assertIn(
                f"make:-C {containerization} check containerization examples docs coverage fetch-default-kernel integration",
                full_commands,
            )
            self.assertIn(
                "make:-C "
                f"{container} "
                f"APP_ROOT={container}/.test-scratch/stack-release-app-root "
                f"LOG_ROOT={container}/.test-scratch/stack-release-log-root "
                "check container dsym docs coverage",
                full_commands,
            )

            log.unlink()
            exception_environment = environment.copy()
            exception_environment[
                "CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON"
            ] = "Promote completed Phase 1 while the documented Phase 5 Builder gaps remain scheduled."
            exception = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=exception_environment,
                text=True,
            )
            self.assertEqual(exception.returncode, 0, exception.stderr)
            exception_commands = log.read_text(encoding="utf-8")
            self.assertIn(
                "make:-C "
                f"{container} "
                f"APP_ROOT={container}/.test-scratch/stack-release-app-root "
                f"LOG_ROOT={container}/.test-scratch/stack-release-log-root "
                "SERIAL_TEST_SUITES=TestCLIOtherSerial/ check container dsym docs coverage",
                exception_commands,
            )

            log.unlink()
            (serial_tests / "TestCLIBuilderTarExportSerial.swift").unlink()
            missing_tracked_suite = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=exception_environment,
                text=True,
            )
            self.assertNotEqual(missing_tracked_suite.returncode, 0)
            self.assertIn(
                "expected tracked Phase 5 Builder suite is missing: TestCLIBuilderTarExportSerial.swift",
                missing_tracked_suite.stderr,
            )

            hosted = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *validation_paths],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(hosted.returncode, 0, hosted.stderr)
            hosted_commands = log.read_text(encoding="utf-8")
            self.assertIn(
                f"make:-C {containerization} check containerization examples docs coverage",
                hosted_commands,
            )
            self.assertIn(
                "make:-C "
                f"{container} "
                f"APP_ROOT={container}/.test-scratch/stack-release-app-root "
                f"LOG_ROOT={container}/.test-scratch/stack-release-log-root "
                "check container dsym docs coverage-unit",
                hosted_commands,
            )
            self.assertNotIn(" integration", hosted_commands)
            self.assertNotIn(" fetch-default-kernel", hosted_commands)

            rejected = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *validation_paths],
                check=False,
                capture_output=True,
                env=exception_environment,
                text=True,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("permitted only for full local validation", rejected.stderr)

    def test_hosted_release_gate_uses_an_unpublished_verified_tag_and_immutable_tap_snapshot(
        self,
    ) -> None:
        workflow = STABLE_GATE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("stable tag %s is not GitHub-verified", workflow)
        self.assertIn("stable tag %s is not the latest semantic source tag", workflow)
        self.assertIn("stable release %s already exists and is immutable", workflow)
        self.assertIn(
            "accepting its GitHub-verified unpublished source for a release retry",
            workflow,
        )
        self.assertIn(
            "homebrew_tap_ref: ${{ steps.candidate.outputs.homebrew_tap_ref }}",
            workflow,
        )
        self.assertIn(
            "git ls-remote --heads https://github.com/stephenlclarke/homebrew-tap.git refs/heads/main",
            workflow,
        )
        self.assertIn("repository: stephenlclarke/homebrew-tap", workflow)
        self.assertIn("path: homebrew-tap", workflow)
        self.assertIn(
            "ref: ${{ needs.resolve-candidate.outputs.homebrew_tap_ref }}",
            workflow,
        )
        self.assertIn("git -C homebrew-tap rev-parse HEAD", workflow)
        self.assertIn("Provision pinned stack tools", workflow)
        self.assertIn("cd container-compose", workflow)
        self.assertIn("HAWKEYE_AUTO_INSTALL=1 ./scripts/install-hawkeye.sh", workflow)
        self.assertIn(
            "for repository in container-builder-shim containerization container; do",
            workflow,
        )
        self.assertIn("./scripts/install-hawkeye.sh", workflow)
        self.assertIn("name: Run Hosted Release Gate", workflow)
        self.assertIn("Checkout immutable stable-gate tools", workflow)
        self.assertIn("path: release-tools", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertIn("git -C release-tools rev-parse HEAD", workflow)
        self.assertIn("run-stack-release-validation.sh hosted", workflow)
        self.assertIn("make -C container-compose ci", workflow)
        self.assertIn("Run Compose CI from immutable source lockfile", workflow)
        self.assertNotIn("Use pinned container dependency", workflow)
        self.assertNotIn("Use pinned containerization dependency", workflow)
        self.assertIn("checks: write", workflow)
        self.assertIn("name: Record Stable Release Authority", workflow)
        self.assertIn("needs: [resolve-candidate, release-gate]", workflow)
        self.assertIn("needs.release-gate.result == 'success'", workflow)
        self.assertIn('authority_name="Stable Release Authority (${RELEASE_TAG})"', workflow)
        self.assertIn('head_sha=${CANDIDATE_SHA}', workflow)
        self.assertIn('external_id=${GITHUB_RUN_ID}', workflow)
        self.assertNotIn("Provision containerization integration kernel", workflow)
        self.assertNotIn("run: make fetch-default-kernel", workflow)
        self.assertNotIn("run: make release-gate-hosted", workflow)
        self.assertNotIn("run: make release-gate\n", workflow)
        self.assertLess(
            workflow.index("Checkout immutable Homebrew tap snapshot"),
            workflow.index("Run hosted release gate"),
        )
        self.assertLess(
            workflow.index("Provision pinned stack tools"),
            workflow.index("Run hosted release gate"),
        )
        self.assertLess(
            workflow.index("Run Compose CI from immutable source lockfile"),
            workflow.index("Run hosted release gate"),
        )

    def test_release_helper_waits_longer_than_the_hosted_stable_gate_timeout(self) -> None:
        dispatch = self.script[
            self.script.index("dispatch_stable_release_gate() {") : self.script.index(
                "publish_stable_release() {"
            )
        ]
        self.assertIn(
            'STABLE_RELEASE_GATE_WAIT_SECONDS="${CONTAINER_STACK_STABLE_GATE_WAIT_SECONDS:-10800}"',
            self.script,
        )
        self.assertIn("CONTAINER_STACK_STABLE_GATE_WAIT_SECONDS", self.script)
        self.assertIn("deadline=$((SECONDS + STABLE_RELEASE_GATE_WAIT_SECONDS))", dispatch)
        self.assertIn(
            '"${run_id}" "hosted stable release gate" "${STABLE_RELEASE_GATE_WAIT_SECONDS}"',
            dispatch,
        )
        self.assertIn("timeout-minutes: 120", STABLE_GATE_WORKFLOW.read_text(encoding="utf-8"))

    def test_new_stable_release_runs_the_local_gate_before_promotion(self) -> None:
        release = self.script[self.script.index("release_current_stack() {") :]
        self.assertIn("ensure_release_intent", release)
        self.assertIn("ensure_current_build_release_readiness", release)
        self.assertIn("require_release_upstream_alignment", release)
        self.assertIn("run_local_release_gate", release)
        self.assertLess(release.index("ensure_release_intent"), release.index("run_local_release_gate"))
        self.assertLess(release.index("require_release_upstream_alignment"), release.index("run_local_release_gate"))
        self.assertLess(release.index("run_local_release_gate"), release.index("push_all_main"))
        self.assertIn('HOMEBREW_TAP_REPO="${ROOT}/homebrew-tap"', self.script)
        self.assertIn('"$(repo_path "container-builder-shim")"', self.script)
        self.assertIn('make -C "$(repo_path "containerization")" fetch-default-kernel', self.script)

    def test_stable_release_requires_intent_and_reviewed_sibling_mains(self) -> None:
        promotion = self.script[self.script.index("push_all_main() {") : self.script.index("# Require an executable command")]

        self.assertIn("CONTAINER_STACK_RELEASE_INTENT is required", self.script)
        self.assertIn("CONTAINER_STACK_MAINTENANCE_REASON is required", self.script)
        self.assertIn("maintenance releases must use the --+ patch selector", self.script)
        self.assertIn("CONTAINER_STACK_SECURITY_REASON is required", self.script)
        self.assertIn("CONTAINER_STACK_MILESTONE_SOAK_OVERRIDE_REASON supports only milestone", self.script)
        self.assertIn("STABLE_CURRENT_SOAK_SECONDS=604800", self.script)
        self.assertIn("upstream-divergence-release-check", self.script)
        self.assertIn("land it through its own PR before releasing", promotion)
        self.assertNotIn('push "${remote}" "refs/heads/main"', promotion)

    def test_stable_release_soak_starts_when_the_current_package_is_refreshed(self) -> None:
        readiness = self.script[
            self.script.index("ensure_current_build_release_readiness() {") : self.script.index(
                "# Print and optionally execute a command."
            )
        ]
        self.assertIn('releases/tags/current', readiness)
        self.assertIn(".prerelease", readiness)
        self.assertIn("container-compose-plugin-current-[0-9a-f]{12}-arm64", readiness)
        self.assertIn(".updated_at", readiness)
        self.assertNotIn("publishedAt", readiness)

    def test_documented_milestone_override_bypasses_only_the_soak_timer(self) -> None:
        readiness = self.script[
            self.script.index("ensure_current_build_release_readiness() {") : self.script.index(
                "# Print and optionally execute a command."
            )
        ]
        self.assertIn('"${RELEASE_INTENT}" == "milestone" && -z "${MILESTONE_SOAK_OVERRIDE_REASON}"', readiness)
        self.assertIn('milestone Current soak override accepted:', readiness)
        self.assertLess(readiness.index('current tag targets'), readiness.index('MILESTONE_SOAK_OVERRIDE_REASON'))
        self.assertLess(readiness.index('current GitHub prerelease or package asset is missing'), readiness.index('MILESTONE_SOAK_OVERRIDE_REASON'))
        build_doc = (ROOT / "BUILD.md").read_text(encoding="utf-8")
        self.assertIn("CONTAINER_STACK_MILESTONE_SOAK_OVERRIDE_REASON", build_doc)
        self.assertIn("Current source and package", build_doc)

    def test_weekly_stable_scheduler_uses_the_same_fresh_current_package_policy(self) -> None:
        workflow = SCHEDULED_STABLE_RELEASE_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn('cron: "17 9 * * 1"', workflow)
        self.assertIn('default: "-+-"', workflow)
        self.assertIn('  - "+--"', workflow)
        self.assertIn("container-compose-plugin-current-[0-9a-f]{12}-arm64", workflow)
        self.assertIn(".updated_at", workflow)
        self.assertIn("current_is_prerelease", workflow)
        self.assertNotIn("--current-published-at", workflow)
        self.assertIn("runs-on: [self-hosted, macOS, ARM64, container-compose-release]", workflow)
        self.assertTrue(os.access(RUNNER_INSTALLER, os.X_OK))

    def test_local_release_gate_requires_hardware_virtualization(self) -> None:
        local_gate = self.script[
            self.script.index("run_local_release_gate() {") : self.script.index(
                "# Verify that Apple remotes cannot be pushed"
            )
        ]
        self.assertIn("require_local_virtualization() {", self.script)
        self.assertIn("require_local_virtualization", local_gate)
        self.assertIn("sysctl -n kern.hv_support", self.script)
        self.assertIn("kern.hv_support=1", self.script)

    def test_local_virtualization_preflight_requires_hardware_support(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            for name, output in (("uname", "Darwin"), ("sysctl", "0")):
                command = bin_directory / name
                command.write_text(
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    f"printf '%s\\n' {shlex.quote(output)}\n",
                    encoding="utf-8",
                )
                command.chmod(0o755)

            shell_setup = f"export PATH={shlex.quote(str(bin_directory))}:$PATH"
            unsupported = self.run_release_function(
                root,
                "require_local_virtualization",
                shell_setup=shell_setup,
            )
            self.assertNotEqual(unsupported.returncode, 0)
            self.assertIn("kern.hv_support=1", unsupported.stderr)

            (bin_directory / "sysctl").write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' 1\n",
                encoding="utf-8",
            )
            (bin_directory / "sysctl").chmod(0o755)
            supported = self.run_release_function(
                root,
                "require_local_virtualization",
                shell_setup=shell_setup,
            )
            self.assertEqual(supported.returncode, 0, supported.stderr)

    def test_release_helper_fetches_tags_before_resolving_versions(self) -> None:
        self.assertIn("fetch --prune --tags", self.script)
        self.assertIn("+refs/tags/current:refs/tags/current", self.script)
        self.assertNotIn("fetch --prune --tags --force", self.script)

    def test_git_fixtures_never_launch_an_editor(self) -> None:
        self.assertEqual(self.non_interactive_environment()["GIT_EDITOR"], ":")

    def test_release_fetch_refreshes_only_mutable_current_tag(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, local = self.create_compose_checkout(root)
            self.run_command("git", "-C", str(local), "tag", "--no-sign", "current")
            self.run_command("git", "-C", str(local), "push", "origin", "refs/tags/current")

            updater = root / "updater"
            self.run_command("git", "clone", "--branch", "main", str(remote), str(updater))
            self.configure_repo(updater)
            self.commit_file(updater, "CURRENT.md", "current\n", "chore: advance current")
            self.run_command("git", "-C", str(updater), "push", "origin", "main")
            # The developer's global tag.gpgSign setting makes an otherwise
            # lightweight force-update prompt for an annotation. Current is a
            # mutable pointer, never a signed release identity, so make the
            # test's intent explicit and keep it non-interactive.
            self.run_command("git", "-C", str(updater), "tag", "--no-sign", "-f", "current")
            self.run_command("git", "-C", str(updater), "push", "origin", "+refs/tags/current")

            result = self.run_release_function(root / "github", "fetch_release_remote container-compose")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("refreshing mutable current tag", result.stdout)
            local_current = self.git(local, "rev-parse", "refs/tags/current")
            remote_current = self.run_command(
                "git", "ls-remote", "--tags", "--refs", str(remote), "refs/tags/current"
            ).stdout.split()[0]
            self.assertEqual(local_current, remote_current)

    def test_release_helper_reconstructs_an_unpublished_prepared_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local = self.create_compose_checkout(root)
            remote_head = self.git(local, "rev-parse", "origin/main")
            self.commit_file(
                local,
                "VERSION",
                "0.6.71\n",
                "chore(release): prepare 0.6.71",
            )

            result = self.run_release_function(
                root / "github",
                "recover_unpublished_release_candidate 0.6.71",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("reconstructing unpublished release candidate", result.stdout)
            self.assertEqual(self.git(local, "rev-parse", "main"), remote_head)
            self.assertEqual(self.git(local, "diff", "--cached", "--name-only"), "VERSION")

    def test_release_helper_reconstructs_an_atomic_stack_pin_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local = self.create_compose_checkout(root)
            remote_head = self.git(local, "rev-parse", "origin/main")
            self.commit_file(
                local,
                "Package.swift",
                "pinned stack\n",
                "chore(deps): pin container stack 123456789abc abcdef123456",
            )

            result = self.run_release_function(
                root / "github",
                "recover_unpublished_release_candidate 0.6.71",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.git(local, "rev-parse", "main"), remote_head)
            self.assertEqual(self.git(local, "diff", "--cached", "--name-only"), "Package.swift")

    def test_release_helper_refuses_to_reconstruct_an_unrelated_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local = self.create_compose_checkout(root)
            self.commit_file(local, "candidate.yml", "candidate\n", "feat: unrelated candidate")
            candidate_head = self.git(local, "rev-parse", "main")

            result = self.run_release_function(
                root / "github",
                "recover_unpublished_release_candidate 0.6.71",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unpublished non-release commit", result.stderr)
            self.assertEqual(self.git(local, "rev-parse", "main"), candidate_head)

    def test_release_helper_uses_the_active_github_cli_credential(self) -> None:
        self.assertIn("github_cli() {", self.script)
        self.assertIn("github_cli pr create", self.script)
        self.assertIn('--add-assignee "@me"', self.script)
        self.assertIn("run github_cli workflow run", self.script)
        self.assertNotIn("env -u GITHUB_TOKEN -u GH_TOKEN gh", self.script)

    def test_release_helper_describes_the_hosted_stable_gate(self) -> None:
        self.assertIn(
            "The hosted Stable Release Gate runs after the signed tag and before stable package publication.",
            self.script,
        )
        self.assertIn(
            "- The hosted Stable Release Gate must pass before stable package publication.",
            self.script,
        )
        self.assertNotIn("make release-gate completed locally before this PR.", self.script)

    def test_release_helper_preserves_formatted_swiftpm_dependency_pins(self) -> None:
        self.assertIn(r'r"(\s*,?\s*\))"', self.script)

    def test_release_helper_does_not_refresh_legacy_mutable_package_pointers(self) -> None:
        self.assertNotIn("+refs/tags/homebrew-main:refs/tags/homebrew-main", self.script)
        self.assertNotIn("legacy mutable pointer", self.script)
        self.assertNotIn("fetch --prune --tags --force", self.script)

    def test_equivalent_squash_promotion_aligns_local_main(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local, candidate_tree, remote_head = self.create_equivalent_squash(root)

            result = self.promote_compose_main(root / "github")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("already promoted", result.stdout)
            self.assertEqual(self.git(local, "rev-parse", "main"), remote_head)
            self.assertEqual(self.git(local, "rev-parse", "main^{tree}"), candidate_tree)
            self.assertEqual(self.git(local, "status", "--short"), "")

    def test_post_promotion_equivalent_squash_aligns_local_main(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local, candidate_tree, remote_head = self.create_equivalent_squash(root)

            result = self.synchronize_promoted_compose_main(root / "github")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("already promoted", result.stdout)
            self.assertEqual(self.git(local, "rev-parse", "main"), remote_head)
            self.assertEqual(self.git(local, "rev-parse", "main^{tree}"), candidate_tree)
            self.assertEqual(self.git(local, "status", "--short"), "")

    def test_divergent_promotion_still_requires_revalidation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, local = self.create_compose_checkout(root)
            self.commit_file(local, "candidate.yml", "candidate\n", "feat: gated candidate")
            candidate_head = self.git(local, "rev-parse", "HEAD")

            remote_change = root / "remote-change"
            self.run_command("git", "clone", "--branch", "main", str(remote), str(remote_change))
            self.configure_repo(remote_change)
            self.commit_file(
                remote_change,
                "remote.yml",
                "remote\n",
                "feat: unrelated remote change",
            )
            self.run_command("git", "-C", str(remote_change), "push", "origin", "main")

            result = self.promote_compose_main(root / "github")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not based on origin/main", result.stderr)
            self.assertEqual(self.git(local, "rev-parse", "main"), candidate_head)

    def test_post_promotion_divergence_does_not_move_local_main(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote, local = self.create_compose_checkout(root)
            self.commit_file(local, "candidate.yml", "candidate\n", "feat: gated candidate")
            candidate_head = self.git(local, "rev-parse", "HEAD")

            remote_change = root / "remote-change"
            self.run_command("git", "clone", "--branch", "main", str(remote), str(remote_change))
            self.configure_repo(remote_change)
            self.commit_file(
                remote_change,
                "remote.yml",
                "remote\n",
                "feat: altered remote candidate",
            )
            self.run_command("git", "-C", str(remote_change), "push", "origin", "main")

            result = self.synchronize_promoted_compose_main(root / "github")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("tree differs from the locally gated candidate", result.stderr)
            self.assertEqual(self.git(local, "rev-parse", "main"), candidate_head)

    def test_merge_promotion_accepts_external_merge_after_auto_merge_rejection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            state_file = root / "gh-view-state"
            fake_gh = bin_directory / "gh"
            fake_gh.write_text(
                """#!/usr/bin/env bash
set -euo pipefail

if [[ \"$1\" != \"pr\" ]]; then
  exit 1
fi

case \"$2\" in
  view)
    if [[ ! -e \"${GH_STATE_FILE}\" ]]; then
      : > \"${GH_STATE_FILE}\"
      exit 0
    fi
    printf '%s\\n' '2026-07-13T12:00:00Z'
    ;;
  merge)
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
""",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)

            result = self.run_release_function(
                root,
                "merge_compose_promotion_pr 42",
                shell_setup="\n".join(
                    [
                        f"export GH_STATE_FILE={shlex.quote(str(state_file))}",
                        f"export PATH={shlex.quote(str(bin_directory))}:$PATH",
                    ]
                ),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("auto-merge was not available", result.stdout)
            self.assertIn("promotion PR already merged: #42", result.stdout)

    def test_retry_requires_an_unpublished_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            fake_gh = bin_directory / "gh"
            fake_gh.write_text(
                """#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" != "release" || "$2" != "view" ]]; then
  exit 1
fi

if [[ "${GH_RELEASE_STATE}" == "published" ]]; then
  printf '%s\\n' '{"id": 1}'
  exit 0
fi

printf '%s\\n' 'release not found' >&2
exit 1
""",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)
            shell_setup = "\n".join(
                [
                    f"export PATH={shlex.quote(str(bin_directory))}:$PATH",
                    "export GH_RELEASE_STATE=unpublished",
                ]
            )

            unpublished = self.run_release_function(
                root,
                "ensure_stable_release_is_unpublished 0.6.70",
                shell_setup=shell_setup,
            )
            self.assertEqual(unpublished.returncode, 0, unpublished.stderr)

            published = self.run_release_function(
                root,
                "ensure_stable_release_is_unpublished 0.6.70",
                shell_setup=shell_setup.replace("unpublished", "published"),
            )
            self.assertNotEqual(published.returncode, 0)
            self.assertIn("stable release 0.6.70 already exists and is immutable", published.stderr)

    def test_stable_release_state_requires_a_published_nonprerelease(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            fake_gh = bin_directory / "gh"
            fake_gh.write_text(
                """#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" != "release" || "$2" != "view" ]]; then
  exit 1
fi

case "${GH_RELEASE_STATE}" in
  published)
    printf '%s\\t%s\\n' false false
    ;;
  prerelease)
    printf '%s\\t%s\\n' false true
    ;;
  missing)
    printf '%s\\n' 'release not found' >&2
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
""",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)
            shell_setup = "\n".join(
                [
                    f"export PATH={shlex.quote(str(bin_directory))}:$PATH",
                    "export GH_RELEASE_STATE=published",
                ]
            )

            published = self.run_release_function(
                root,
                "stable_release_is_published 0.6.70",
                shell_setup=shell_setup,
            )
            self.assertEqual(published.returncode, 0, published.stderr)

            missing = self.run_release_function(
                root,
                "stable_release_is_published 0.6.70",
                shell_setup=shell_setup.replace("published", "missing"),
            )
            self.assertNotEqual(missing.returncode, 0)

            prerelease = self.run_release_function(
                root,
                "stable_release_is_published 0.6.70",
                shell_setup=shell_setup.replace("published", "prerelease"),
            )
            self.assertNotEqual(prerelease.returncode, 0)
            self.assertIn("not published and immutable", prerelease.stderr)

    def test_resume_routes_published_tags_to_formula_only_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            published = self.run_release_function(
                root,
                "resume_stable_release 0.6.70",
                shell_setup="\n".join(
                    [
                        "ensure_latest_stable_retry() { :; }",
                        "verify_github_stable_tag_signature() { :; }",
                        "stable_release_is_published() { return 0; }",
                        "ensure_stable_release_is_unpublished() { exit 71; }",
                        "dispatch_compose_stable_tap_repair() { printf 'repair %s\\n' \"$1\"; }",
                        "publish_stable_release() { exit 72; }",
                        "print_stable_release_point() { printf 'point %s %s\\n' \"$1\" \"$2\"; }",
                    ]
                ),
            )
            self.assertEqual(published.returncode, 0, published.stderr)
            self.assertIn("repair 0.6.70", published.stdout)
            self.assertIn("formula-only recovery from immutable release assets", published.stdout)

            unpublished = self.run_release_function(
                root,
                "resume_stable_release 0.6.70",
                shell_setup="\n".join(
                    [
                        "ensure_latest_stable_retry() { :; }",
                        "verify_github_stable_tag_signature() { :; }",
                        "stable_release_is_published() { return 1; }",
                        "ensure_stable_release_is_unpublished() { :; }",
                        "dispatch_compose_stable_tap_repair() { exit 73; }",
                        "publish_stable_release() { printf 'publish %s\\n' \"$1\"; }",
                    ]
                ),
            )
            self.assertEqual(unpublished.returncode, 0, unpublished.stderr)
            self.assertIn("publish 0.6.70", unpublished.stdout)

    def test_retry_rejects_a_stale_semantic_tag(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shell_setup = "latest_local_semver_tag() { printf '%s\\n' 0.6.71; }"

            latest = self.run_release_function(
                root,
                "ensure_latest_stable_retry 0.6.71",
                shell_setup=shell_setup,
            )
            self.assertEqual(latest.returncode, 0, latest.stderr)

            stale = self.run_release_function(
                root,
                "ensure_latest_stable_retry 0.6.70",
                shell_setup=shell_setup,
            )
            self.assertNotEqual(stale.returncode, 0)
            self.assertIn("stable tag 0.6.70 is not the latest semantic source tag (0.6.71)", stale.stderr)

    def create_compose_checkout(self, root: Path) -> tuple[Path, Path]:
        remote = root / "remote.git"
        local = root / "github" / "container-compose"
        self.run_command("git", "init", "--bare", str(remote))
        local.parent.mkdir(parents=True)
        self.run_command("git", "init", "-b", "main", str(local))
        self.configure_repo(local)
        self.run_command("git", "-C", str(local), "remote", "add", "origin", str(remote))
        self.commit_file(local, "README.md", "base\n", "chore: initial stack")
        self.run_command("git", "-C", str(local), "push", "-u", "origin", "main")
        return remote, local

    def create_equivalent_squash(self, root: Path) -> tuple[Path, Path, str, str]:
        remote, local = self.create_compose_checkout(root)
        self.commit_file(local, "compose.yml", "services: {}\n", "feat: gated candidate")
        candidate_tree = self.git(local, "rev-parse", "HEAD^{tree}")

        squashed = root / "squashed"
        self.run_command("git", "clone", "--branch", "main", str(remote), str(squashed))
        self.configure_repo(squashed)
        self.commit_file(
            squashed,
            "compose.yml",
            "services: {}\n",
            "chore: equivalent squash promotion",
        )
        self.run_command("git", "-C", str(squashed), "push", "origin", "main")
        return remote, local, candidate_tree, self.git(squashed, "rev-parse", "HEAD")

    def configure_repo(self, repo: Path) -> None:
        self.run_command("git", "-C", str(repo), "config", "user.name", "Test")
        self.run_command("git", "-C", str(repo), "config", "user.email", "test@example.com")
        self.run_command("git", "-C", str(repo), "config", "commit.gpgSign", "false")
        self.run_command("git", "-C", str(repo), "config", "tag.gpgSign", "false")

    def commit_file(self, repo: Path, name: str, contents: str, subject: str) -> None:
        (repo / name).write_text(contents, encoding="utf-8")
        self.run_command("git", "-C", str(repo), "add", name)
        self.run_command("git", "-C", str(repo), "commit", "-m", subject)

    def promote_compose_main(self, root: Path) -> subprocess.CompletedProcess[str]:
        return self.run_release_function(
            root,
            "promote_compose_main 0.6.70 source 'test promotion' 'test body'",
        )

    def synchronize_promoted_compose_main(self, root: Path) -> subprocess.CompletedProcess[str]:
        path = root / "container-compose"
        candidate_tree = self.git(path, "rev-parse", "main^{tree}")
        return self.run_release_function(
            root,
            " ".join(
                [
                    "synchronize_promoted_compose_main",
                    shlex.quote(str(path)),
                    "origin",
                    shlex.quote(candidate_tree),
                ]
            ),
        )

    def run_package_authority_step(
        self,
        ref_type: str,
        ref_name: str,
        authority_run_id: str,
        gate_conclusion: str,
    ) -> subprocess.CompletedProcess[str]:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        authority = workflow[
            workflow.index("- name: Require the hosted release authority") : workflow.index(
                "- name: Build matched runtime package"
            )
        ]
        run_marker = "        run: |\n"
        run_start = authority.index(run_marker) + len(run_marker)
        command = textwrap.dedent(authority[run_start:]).rstrip()
        fake_gh = """\
gh() {
  case "$1:$2" in
    api:*) printf '%s\\n' "${TEST_AUTHORITY_RUN_ID}" ;;
    run:*) printf '%s\\n' "${TEST_GATE_CONCLUSION}" ;;
    *) exit 64 ;;
  esac
}
"""
        environment = os.environ.copy()
        environment.update(
            {
                "PUBLISH_REF_TYPE": ref_type,
                "PUBLISH_REF_NAME": ref_name,
                "PUBLISH_SHA": "0123456789012345678901234567890123456789",
                "GITHUB_REPOSITORY": "stephenlclarke/container-compose",
                "GH_TOKEN": "test",
                "TEST_AUTHORITY_RUN_ID": authority_run_id,
                "TEST_GATE_CONCLUSION": gate_conclusion,
            }
        )
        return subprocess.run(
            ["bash", "-c", f"{fake_gh}\n{command}"],
            capture_output=True,
            text=True,
            check=False,
            env=environment,
        )

    def run_release_function(
        self,
        root: Path,
        function_call: str,
        shell_setup: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        lines = [
            "set -euo pipefail",
            "export CONTAINER_STACK_RELEASE_LIBRARY=1",
            f"source {shlex.quote(str(SCRIPT))}",
            f"ROOT={shlex.quote(str(root))}",
            "EXECUTE=1",
            "COMPOSE_MAIN_PROMOTION_MODE=direct",
            "COMPOSE_MAIN_MERGE_MODE=checked-admin",
        ]
        if shell_setup is not None:
            lines.append(shell_setup)
        lines.append(function_call)
        command = "\n".join(lines)
        environment = self.non_interactive_environment()
        return subprocess.run(
            ["bash", "-c", command],
            capture_output=True,
            text=True,
            check=False,
            env=environment,
        )

    def git(self, repo: Path, *arguments: str) -> str:
        return self.run_command("git", "-C", str(repo), *arguments).stdout.strip()

    def run_command(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            check=True,
            env=self.non_interactive_environment(),
        )

    def non_interactive_environment(self) -> dict[str, str]:
        """Prevent Git fixtures from launching an editor during automated tests."""
        environment = os.environ.copy()
        environment["GIT_EDITOR"] = ":"
        return environment


if __name__ == "__main__":
    unittest.main()
