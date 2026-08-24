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

import json
import os
import re
import signal
import shlex
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[2] / "scripts" / "CONTAINER_STACK_RELEASE.sh"
ROOT = SCRIPT.parent.parent
TEMPLATE = ROOT / "Tools" / "release" / "container-compose.rb.in"
HOMEBREW_WORKFLOW = ROOT / ".github" / "workflows" / "homebrew.yml"
PACKAGE_WORKFLOW = ROOT / ".github" / "workflows" / "prebuilt-binaries.yml"
CURRENT_DEMO_WORKFLOW = ROOT / ".github" / "workflows" / "current-demo.yml"
DOCS_WORKFLOW = ROOT / ".github" / "workflows" / "docs.yml"
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

    def test_local_release_gate_stages_the_init_archive_on_the_system_volume(self) -> None:
        staging = 'staged_init_image_archive="${runtime_parent}/vminit.oci.tar"'
        copy = 'cp "${init_image_archive}" "${staged_init_image_archive}"'
        use = 'init_image_archive="${staged_init_image_archive}"'

        self.assertIn(staging, self.script)
        self.assertIn(copy, self.script)
        self.assertIn(use, self.script)
        self.assertLess(self.script.index(staging), self.script.index(copy))
        self.assertLess(self.script.index(copy), self.script.index(use))
        self.assertLess(
            self.script.index(use), self.script.index("run_local_release_gate_command env")
        )

    def test_release_helper_retains_only_its_unpublished_candidate_before_readiness(self) -> None:
        recovery = self.script[
            self.script.index("recover_unpublished_release_candidate() {") : self.script.index(
                "# Print and optionally execute a command."
            )
        ]
        release = self.script[self.script.index("release_current_stack() {") :]
        self.assertNotIn('git -C "${path}" reset --soft "${remote_head}"', recovery)
        self.assertIn("retaining unpublished release candidate", recovery)
        self.assertIn("RECOVERED_UNPUBLISHED_RELEASE_BASE", recovery)
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
            sync.index('resolve_release_dependency_pins "${path}" container containerization'),
        )
        self.assertIn("commit_compose_stack_package_pins", sync)
        self.assertIn("chore(deps): pin container stack", self.script)
        self.assertIn("Release-Note: none", runtime_pin)
        self.assertIn("sync_container_package_pin", self.script)

    def test_release_pin_sync_skips_aligned_graph_and_rejects_transitive_drift(self) -> None:
        helper = self.script[
            self.script.index("resolved_package_pin_matches() {") : self.script.index(
                "# Update one SwiftPM manifest"
            )
        ]
        sync = self.script[
            self.script.index("sync_container_package_pin() {") : self.script.index(
                "write_release_stack_manifest() {"
            )
        ]

        self.assertIn("resolve_release_dependency_pins() {", helper)
        self.assertIn("release pin resolution changed unrelated dependencies", helper)
        self.assertIn('cp "${backup}" "${path}/Package.resolved"', helper)
        self.assertIn('git -C "${path}" diff --quiet -- Package.swift', sync)
        self.assertIn(
            'resolved_package_pin_matches "${path}" container "${container_ref}"',
            sync,
        )
        self.assertIn(
            'resolved_package_pin_matches "${path}" containerization "${containerization_ref}"',
            sync,
        )
        self.assertIn(
            'resolve_release_dependency_pins "${path}" container containerization',
            sync,
        )

    def test_release_pin_resolution_restores_lockfile_after_transitive_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "package"
            package.mkdir()
            before = {
                "pins": [
                    {"identity": "container", "state": {"revision": "old"}},
                    {"identity": "transitive", "state": {"version": "1.0.0"}},
                ]
            }
            after = {
                "pins": [
                    {"identity": "container", "state": {"revision": "new"}},
                    {"identity": "transitive", "state": {"version": "1.1.0"}},
                ]
            }
            resolved = package / "Package.resolved"
            resolved.write_text(json.dumps(before), encoding="utf-8")
            replacement = root / "after.json"
            replacement.write_text(json.dumps(after), encoding="utf-8")
            bin_directory = root / "bin"
            bin_directory.mkdir()
            fake_swift = bin_directory / "swift"
            fake_swift.write_text(
                "#!/bin/sh\ncp \"$TEST_AFTER\" \"$TEST_PACKAGE/Package.resolved\"\n",
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)

            result = self.run_release_function(
                root,
                f"resolve_release_dependency_pins {shlex.quote(str(package))} container",
                shell_setup=(
                    f"export PATH={shlex.quote(str(bin_directory))}:/usr/bin:/bin\n"
                    f"export TEST_AFTER={shlex.quote(str(replacement))}\n"
                    f"export TEST_PACKAGE={shlex.quote(str(package))}"
                ),
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("changed unrelated dependencies: transitive", result.stderr)
            self.assertEqual(json.loads(resolved.read_text(encoding="utf-8")), before)

    def test_unedit_restores_lockfile_after_swiftpm_graph_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "package"
            package.mkdir()
            before = {
                "pins": [
                    {"identity": "container", "state": {"revision": "expected"}},
                    {"identity": "transitive", "state": {"version": "1.0.0"}},
                ]
            }
            after = {
                "pins": [
                    {"identity": "container", "state": {"revision": "expected"}},
                    {"identity": "transitive", "state": {"version": "1.1.0"}},
                ]
            }
            resolved = package / "Package.resolved"
            replacement = root / "after.json"
            replacement.write_text(json.dumps(after), encoding="utf-8")
            bin_directory = root / "bin"
            bin_directory.mkdir()
            fake_swift = bin_directory / "swift"
            fake_swift.write_text(
                textwrap.dedent(
                    """\
                    #!/bin/sh
                    cp "$TEST_AFTER" "$TEST_PACKAGE/Package.resolved"
                    if [ "${TEST_SWIFT_SIGNAL_PARENT:-0}" -eq 1 ]; then
                        kill -TERM "$PPID"
                        exit 0
                    fi
                    if [ "${TEST_SWIFT_SIGNAL_OUTER:-0}" -eq 1 ]; then
                        outer_pid=$(ps -o ppid= -p "$PPID" | awk '{print $1}')
                        kill -TERM "$outer_pid"
                        exit 0
                    fi
                    if [ "$TEST_SWIFT_STATUS" -ne 0 ]; then
                        printf 'not in edit mode\n' >&2
                        exit "$TEST_SWIFT_STATUS"
                    fi
                    """
                ),
                encoding="utf-8",
            )
            fake_swift.chmod(0o755)

            for status in (0, 1):
                with self.subTest(swift_status=status):
                    resolved.write_text(json.dumps(before), encoding="utf-8")
                    result = self.run_release_function(
                        root,
                        f"unedit_release_dependency {shlex.quote(str(package))} container",
                        shell_setup=(
                            f"export PATH={shlex.quote(str(bin_directory))}:/usr/bin:/bin\n"
                            f"export TEST_AFTER={shlex.quote(str(replacement))}\n"
                            f"export TEST_PACKAGE={shlex.quote(str(package))}\n"
                            f"export TEST_SWIFT_STATUS={status}"
                        ),
                    )

                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(
                        json.loads(resolved.read_text(encoding="utf-8")), before
                    )

            resolved.unlink()
            result = self.run_release_function(
                root,
                f"unedit_release_dependency {shlex.quote(str(package))} container",
                shell_setup=(
                    f"export PATH={shlex.quote(str(bin_directory))}:/usr/bin:/bin\n"
                    f"export TEST_AFTER={shlex.quote(str(replacement))}\n"
                    f"export TEST_PACKAGE={shlex.quote(str(package))}\n"
                    "export TEST_SWIFT_STATUS=0"
                ),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(resolved.exists())

            resolved.write_text(json.dumps(before), encoding="utf-8")
            result = self.run_release_function(
                root,
                f"unedit_release_dependency {shlex.quote(str(package))} container",
                shell_setup=(
                    f"export PATH={shlex.quote(str(bin_directory))}:/usr/bin:/bin\n"
                    f"export TEST_AFTER={shlex.quote(str(replacement))}\n"
                    f"export TEST_PACKAGE={shlex.quote(str(package))}\n"
                    "export TEST_SWIFT_STATUS=0\n"
                    "export TEST_SWIFT_SIGNAL_PARENT=1"
                ),
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(resolved.read_text(encoding="utf-8")), before)

            resolved.write_text(json.dumps(before), encoding="utf-8")
            result = self.run_release_function(
                root,
                f"unedit_release_dependency {shlex.quote(str(package))} container",
                shell_setup=(
                    f"export PATH={shlex.quote(str(bin_directory))}:/usr/bin:/bin\n"
                    f"export TEST_AFTER={shlex.quote(str(replacement))}\n"
                    f"export TEST_PACKAGE={shlex.quote(str(package))}\n"
                    "export TEST_SWIFT_STATUS=0\n"
                    "export TEST_SWIFT_SIGNAL_OUTER=1"
                ),
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(resolved.read_text(encoding="utf-8")), before)

    def test_containerization_pin_supports_literal_named_and_dynamic_revisions(self) -> None:
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

            dynamic = root / "container-dynamic"
            dynamic.mkdir()
            dynamic_manifest = dynamic / "Package.swift"
            dynamic_manifest.write_text(
                textwrap.dedent(
                    """\
                    import Foundation
                    import PackageDescription

                    let containerizationRevision = "old"
                    let scSource =
                        ProcessInfo.processInfo.environment["CONTAINERIZATION_SOURCE"]
                        ?? "stephenlclarke/containerization"
                    let scRef =
                        ProcessInfo.processInfo.environment["CONTAINERIZATION_REF"]
                        ?? containerizationRevision
                    let containerizationDependency: Package.Dependency = .package(
                        url: "https://github.com/\\(scSource).git",
                        revision: scRef
                    )
                    """
                ),
                encoding="utf-8",
            )
            dynamic_result = self.run_release_function(
                root,
                f"update_containerization_package_pin container-dynamic {revision} 0",
            )
            self.assertEqual(dynamic_result.returncode, 0, dynamic_result.stderr)
            dynamic_text = dynamic_manifest.read_text(encoding="utf-8")
            self.assertIn(f'let containerizationRevision = "{revision}"', dynamic_text)
            self.assertIn("revision: scRef", dynamic_text)

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
        self.assertIn(
            '"${signature_verifier}" "${tmp}/${asset}"',
            self.script,
        )
        self.assertIn(
            '"${signature_verifier}" "${tmp}/${runtime_asset}"',
            self.script,
        )

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

    def test_homebrew_tap_pushes_authenticate_with_the_tap_token(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(
            workflow.count(
                "GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}"
            ),
            2,
        )
        self.assertEqual(workflow.count("gh auth setup-git"), 2)

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

    def test_current_demo_is_recoverable_and_not_release_critical(self) -> None:
        package = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        release_critical = package[
            : package.index("- name: Retain only current release assets")
        ]
        workflow = CURRENT_DEMO_WORKFLOW.read_text(encoding="utf-8")
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        tape = (ROOT / "docs" / "assets" / "container-compose-demo.tape").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("Install VHS", release_critical)
        self.assertNotIn("Generate Current build VHS recording", release_critical)
        self.assertNotIn("Validate Current demo init-image authority", release_critical)
        self.assertNotIn("CURRENT_DEMO_INIT_IMAGE_ARCHIVE", release_critical)
        self.assertIn(
            'gh release view "${RELEASE_TAG}"', release_critical
        )
        self.assertIn(
            '--pattern "container-compose-demo-current.gif"', release_critical
        )
        self.assertIn(
            'printf \'%s\\n\' "${retained_demo}" >> "${extra_assets}"',
            release_critical,
        )
        self.assertIn(
            '--current-asset "container-compose-demo-current.gif"', package
        )

        self.assertIn("- Prebuilt Binaries", workflow)
        self.assertIn("cancel-in-progress: true", workflow)
        self.assertIn(
            "runs-on: [self-hosted, macOS, ARM64, "
            "container-compose-release, container-compose-current]",
            workflow,
        )
        self.assertIn("isolated from package, attestation, release, and Homebrew", workflow)
        self.assertIn('demo_session_root="/private/tmp/container-compose-current-demo"', workflow)
        self.assertIn(".container-compose-current-demo-root", workflow)
        self.assertIn("container-compose-current-demo-v1", workflow)
        self.assertIn('"$(stat -f %u "${demo_session_root}")" != "$(id -u)"', workflow)
        self.assertIn('"$(stat -f %Lp "${demo_session_root}")" != "700"', workflow)
        self.assertNotIn("/tmp/cc-current-${GITHUB_RUN_ID}", workflow)
        self.assertIn(
            "python3 Tools/ci/run-command-with-deadline.py \\\n"
            "              --seconds 2400 --grace-seconds 15 --",
            workflow,
        )
        self.assertIn(
            "python3 Tools/ci/run-command-with-deadline.py \\\n"
            "              --seconds 30 --grace-seconds 5 --",
            workflow,
        )
        self.assertIn("bash Tools/release/record-vhs-live-demo.sh", workflow)
        self.assertIn("Validate Current demo init-image authority", workflow)
        self.assertIn('"${DEMO_INIT_IMAGE_ARCHIVE}" == /Volumes/*', workflow)
        self.assertIn('-L "${DEMO_INIT_IMAGE_ARCHIVE}"', workflow)
        self.assertIn("Tools/release/validate-oci-image-layout.py", workflow)
        self.assertIn("Tools/release/verify-developer-id-archive.sh", workflow)
        self.assertIn("shasum -a 256 -c", workflow)
        self.assertIn("Verify source and release are still current", workflow)
        self.assertLess(
            workflow.index("Verify source and release are still current"),
            workflow.index("Publish exact Current demo"),
        )
        self.assertIn('gh release upload current "${DEMO_OUTPUT}"', workflow)
        self.assertEqual(workflow.count('--repo "${GITHUB_REPOSITORY}"'), 4)
        self.assertIn("if: failure()", workflow)
        self.assertIn("current-demo-diagnostics-", workflow)

        self.assertIn("Set Framerate 24", tape)
        self.assertIn("Set TypingSpeed 48ms", tape)
        self.assertIn("Set Width 1600", tape)
        self.assertEqual(
            tape.count(
                "--init-image-archive "
                "$CONTAINER_COMPOSE_DEMO_INIT_IMAGE_ARCHIVE"
            ),
            2,
        )
        typed_command = None
        for line in tape.splitlines():
            if line.startswith('Type "'):
                typed_command = shlex.split(line)[1]
                continue
            wait_match = re.fullmatch(r"Wait\+Screen@\S+ /(.*)/", line)
            if wait_match is None:
                continue
            self.assertIsNotNone(typed_command)
            wait_pattern = wait_match.group(1).replace(
                "[[:space:]]", r"\s"
            )
            self.assertIsNone(
                re.search(wait_pattern, typed_command or ""),
                f"screen wait can match its typed command: {line}",
            )
        self.assertEqual(tape.count("container system start"), 2)
        self.assertEqual(tape.count("--quiet-pull nginx alertmanager"), 2)
        self.assertIn("container-compose-volume-reuse-ok", tape)
        self.assertIn("down --volumes --remove-orphans", tape)
        self.assertIn('Type "container system stop; container system status"', tape)
        self.assertIn(
            "releases/download/current/container-compose-demo-current.gif",
            readme,
        )

    def test_documentation_sites_build_in_parallel_before_pages_assembly(self) -> None:
        workflow = DOCS_WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("strategy:", workflow)
        self.assertIn("fail-fast: false", workflow)
        self.assertEqual(workflow.count("- site:"), 4)
        for site in ("compose", "container", "containerization", "k8s"):
            self.assertIn(f"- site: {site}", workflow)
        self.assertIn("downloads/compose.tgz", workflow)
        self.assertIn('downloads/${site}.tgz', workflow)
        self.assertIn("name: Build ${{ matrix.site }} DocC Site", workflow)
        self.assertIn("runs-on: macos-26", workflow)
        self.assertIn("needs: build-sites", workflow)
        self.assertIn("merge-multiple: true", workflow)
        self.assertIn("Assemble DocC portal", workflow)
        self.assertNotIn("scripts/add-upstream-docc-sites.sh", workflow)
        self.assertNotIn("      - Makefile", workflow)

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
        self.assertIn(
            'python3 ../release-tools/Tools/release/release-notes.py \\\n'
            '            "${release_notes_args[@]}"',
            workflow,
        )
        self.assertIn(
            "../release-tools/Tools/release/publish-github-release.sh",
            workflow,
        )
        self.assertIn(
            "../release-tools/Tools/release/retain-release-assets.py",
            workflow,
        )
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
        self.assertIn('.headBranch == "main"', workflow)
        self.assertIn('.status == "completed"', workflow)

    def test_current_package_avoids_oversized_dependency_caches(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("name: Cache SwiftPM build artifacts", workflow)
        self.assertNotIn("id: swiftpm-cache", workflow)
        setup_go = workflow[
            workflow.index("- name: Set up Go") : workflow.index(
                "- name: Build release package"
            )
        ]
        self.assertIn("cache: false", setup_go)
        self.assertNotIn("cache-dependency-path:", setup_go)

    def test_package_build_uses_manifest_paths_without_swiftpm_edits(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        package_build = workflow[
            workflow.index("- name: Verify containerization dependency ref") : workflow.index(
                "- name: Build release package"
            )
        ]

        self.assertNotIn("use-stack-container.sh", package_build)
        self.assertNotIn("use-stack-containerization.sh", package_build)
        self.assertIn("- name: Checkout container dependency", workflow)
        self.assertIn("- name: Checkout containerization dependency", workflow)

    def test_stable_and_current_release_authority_select_main_ci(self) -> None:
        stable_gate = STABLE_GATE_WORKFLOW.read_text(encoding="utf-8")
        package = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        package_authority = package[
            package.index("- name: Require the hosted release authority") : package.index(
                "- name: Install Developer ID application certificate"
            )
        ]
        current_authority = package_authority[
            package_authority.index("branch)") : package_authority.index("tag)")
        ]
        self.assertIn("--json databaseId,status,conclusion,headBranch", stable_gate)
        self.assertIn('select(.headBranch == "main")', stable_gate)
        self.assertIn("--json event,status,conclusion,headBranch", current_authority)
        self.assertIn('.headBranch == "main"', current_authority)
        self.assertIn('(.event == "push" or .event == "workflow_dispatch")', current_authority)
        self.assertNotIn("--event push", current_authority)

    def test_codeql_defers_drafts_without_weakening_main_or_ready_prs(self) -> None:
        codeql = CODEQL_WORKFLOW.read_text(encoding="utf-8")
        ci = CI_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("- converted_to_draft", codeql)
        self.assertIn("- ready_for_review", codeql)
        self.assertIn(
            "if: github.event_name != 'pull_request' || github.event.pull_request.draft == false",
            codeql,
        )
        self.assertIn(
            "if: github.event_name != 'pull_request' || "
            "(github.event.pull_request.draft == false && "
            "needs.changes.outputs.go == 'true')",
            codeql,
        )
        self.assertIn(
            "if: github.event_name == 'pull_request' && "
            "github.event.pull_request.draft == false && "
            "needs.changes.outputs.go != 'true'",
            codeql,
        )
        self.assertIn("DRAFT_PULL_REQUEST:", codeql)
        self.assertIn("CodeQL analysis deferred while the pull request is a draft", codeql)
        self.assertNotIn("name: Validate Lightweight", ci)
        self.assertEqual(len(re.findall(r"^    name: Validate$", ci, re.MULTILINE)), 2)
        self.assertIn("name: CodeQL", codeql)
        self.assertIn("needs.analyze.result", codeql)
        self.assertIn("needs.analyze-skipped.result", codeql)

    def test_main_sonar_step_preserves_the_complete_retry_budget(self) -> None:
        ci = CI_WORKFLOW.read_text(encoding="utf-8")
        runtime_job = ci[
            ci.index("  validate_runtime:") : ci.index(
                "    steps:", ci.index("  validate_runtime:")
            )
        ]
        sonar = ci[
            ci.index("- name: SonarQube scan") : ci.index(
                "- name: Enforce SonarQube failures when the service is available"
            )
        ]
        sonar_install = ci[
            ci.index("- name: Install Sonar Scanner CLI") : ci.index(
                "- name: SonarQube scan"
            )
        ]
        self.assertIn("timeout-minutes: 105", runtime_job)
        self.assertIn("continue-on-error: true", sonar)
        self.assertIn("timeout-minutes: 25", sonar)
        self.assertIn('SONAR_QUALITYGATE_WAIT: "true"', sonar)
        self.assertIn("run: make sonar-scan", sonar)
        self.assertIn(
            'gpg_home="$(mktemp -d /private/tmp/container-compose-sonar-gpg.XXXXXX)"',
            sonar_install,
        )
        self.assertIn('gpgconf --homedir "$gpg_home" --launch gpg-agent', sonar_install)
        self.assertIn('gpgconf --homedir "$gpg_home" --kill gpg-agent', sonar_install)
        self.assertIn('find "$gpg_home" -depth -delete', sonar_install)

    def test_stable_package_requires_candidate_bound_release_authority(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        authority = workflow[
            workflow.index("- name: Require the hosted release authority") : workflow.index(
                "- name: Install Developer ID application certificate"
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

    def test_release_archives_require_developer_id_signatures(self) -> None:
        workflow = PACKAGE_WORKFLOW.read_text(encoding="utf-8")
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        certificate_step = workflow[
            workflow.index("- name: Install Developer ID application certificate") :
            workflow.index("- name: Build matched runtime package")
        ]
        signing_steps = workflow[
            workflow.index("- name: Build matched runtime package") :
            workflow.index("- name: Attest release package")
        ]

        self.assertIn(
            "secrets.DEVELOPER_ID_APPLICATION_P12_BASE64",
            certificate_step,
        )
        self.assertIn(
            "secrets.DEVELOPER_ID_APPLICATION_P12_PASSWORD",
            certificate_step,
        )
        self.assertIn("security set-key-partition-list", certificate_step)
        self.assertIn("security list-keychains", certificate_step)
        self.assertIn("developer-id-signing-probe-", certificate_step)
        self.assertIn("DEVELOPER_ID_ORIGINAL_KEYCHAINS", certificate_step)
        self.assertIn("restore_keychain_search_list", certificate_step)
        self.assertIn('--keychain "${DEVELOPER_ID_KEYCHAIN}"', certificate_step)
        self.assertNotIn("-A", certificate_step)
        self.assertIn(
            'CODESIGN_OPTS="--force --keychain ${DEVELOPER_ID_KEYCHAIN} '
            '--sign ${DEVELOPER_ID_APPLICATION_IDENTITY}',
            signing_steps,
        )
        self.assertEqual(workflow.count("--options runtime"), 4)
        self.assertEqual(workflow.count("--timestamp"), 4)
        self.assertEqual(
            signing_steps.count("verify-developer-id-archive.sh"),
            2,
        )
        self.assertIn("if: always()", signing_steps)
        self.assertIn("security delete-keychain", signing_steps)
        self.assertIn("CODESIGN_OPTS ?= --force --sign - --timestamp=none", makefile)
        self.assertIn(
            "--identifier io.github.stephenlclarke.container-compose",
            makefile,
        )
        self.assertTrue(
            (ROOT / "Tools" / "release" / "verify-developer-id-archive.sh").is_file()
        )

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
        ci_workflow = CI_WORKFLOW.read_text(encoding="utf-8")
        validation = STACK_RELEASE_VALIDATION.read_text(encoding="utf-8")
        reference_check = (
            ROOT / "Tools" / "parity" / "check-docker-compose-reference.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("check-licenses vet lint coverage build", validation)
        self.assertIn(
            "runs-on: [self-hosted, macOS, ARM64, container-compose-current]",
            ci_workflow,
        )
        self.assertIn("run-stack-release-validation.sh full", makefile)
        self.assertIn("run-stack-release-validation.sh hosted", makefile)
        direct_full_gate = subprocess.run(
            [
                "make",
                "-n",
                "container-stack-release-validation",
                "CONTAINER_COMPOSE_CONTAINER=container",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=self.non_interactive_environment(),
        )
        self.assertEqual(direct_full_gate.returncode, 0, direct_full_gate.stderr)
        self.assertIn(
            'CONTAINER_RUNTIME_CLI="container"',
            direct_full_gate.stdout,
        )
        self.assertIn(
            "containerization_targets=(check containerization examples docs coverage fetch-default-kernel integration)",
            validation,
        )
        self.assertIn(
            "container_targets=(check container dsym docs coverage)",
            validation,
        )
        self.assertIn("release-gate-hosted:", makefile)
        self.assertIn("--stage sibling-stack-hosted", makefile)
        self.assertIn("container-stack-hosted-release-validation", makefile)
        self.assertIn("--stage compose-ci-hosted", makefile)
        self.assertIn(
            "containerization_targets=(check containerization examples docs coverage)",
            validation,
        )
        self.assertIn(
            "container_targets=(check build dsym docs coverage-unit)",
            validation,
        )
        self.assertIn("container_runtime_parent_base=/private/tmp", validation)
        self.assertIn(
            '[[ ! -d "${container_runtime_parent_base}" || ! -w "${container_runtime_parent_base}" ]]',
            validation,
        )
        self.assertIn("container_runtime_parent_base=/tmp", validation)
        self.assertIn(
            "env -u CONTAINER_APP_ROOT -u CONTAINER_SERVICE_NAMESPACE",
            validation,
        )
        self.assertIn(
            'CONTAINER_INIT_BOOTSTRAP_IMAGE_ARCHIVE="${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE:-}"',
            validation,
        )
        self.assertIn(
            'CONTAINER_INIT_BUILDER_IMAGE_ARCHIVE="${CONTAINER_RUNTIME_BUILDER_IMAGE_TAR:-}"',
            validation,
        )
        self.assertIn("CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1", makefile)
        self.assertIn("docker-compose-devices-parity", makefile)
        self.assertIn("docker-compose-named-volume-reuse-parity", makefile)
        self.assertIn("release-gate:", makefile)
        for stage in ("sibling-stack", "compose-ci", "swift-runtime", "compose-parity"):
            self.assertIn(f"--stage {stage}", makefile)
        self.assertIn("docker-compose-parity-stages:", makefile)
        self.assertIn(
            "docker-compose-parity: build container-stack-build docker-compose-reference",
            makefile,
        )
        self.assertIn("RELEASE_GATE_INIT_ARCHIVE_FINGERPRINT", makefile)
        self.assertIn("init=$(RELEASE_GATE_INIT_ARCHIVE_FINGERPRINT)", makefile)
        self.assertIn("fingerprint-release-environment.py", makefile)
        self.assertIn(
            "--fingerprint-command ./Tools/ci/print-release-gate-fingerprint.py",
            makefile,
        )
        self.assertNotIn(
            "release-gate: release-gate-environment-fingerprint-check", makefile
        )
        self.assertIn("parity-inputs=$(RELEASE_GATE_PARITY_INPUT_FINGERPRINT)", makefile)
        self.assertIn("run-release-checkpoint.py", makefile)
        self.assertEqual(
            makefile.count("env -u CONTAINER_BIN -u CONTAINER_COMPOSE_CONTAINER"),
            2,
        )
        self.assertIn("DOCKER_COMPOSE_REFERENCE_VERSION ?= 5.4.0", makefile)
        self.assertIn(
            'REQUIRED_VERSION="${DOCKER_COMPOSE_REFERENCE_VERSION:-5.4.0}"',
            reference_check,
        )
        self.assertIn("DOCKER_COMPOSE_E2E_REF ?= f32009d4a2c687dd405398cc7975d12dccaf8dff", makefile)
        self.assertNotIn("repackage-release", makefile)

    def test_swift_coverage_follows_ssd_backed_build_symlink(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        coverage_start = makefile.index("swift-coverage: swift-test-build")
        coverage = makefile[
            coverage_start : makefile.index("go-test:", coverage_start)
        ]

        self.assertEqual(coverage.count("find -L .build"), 5)
        self.assertNotRegex(coverage, r"find \.build(?:\s|$)")

    def test_release_gate_fingerprint_tracks_archive_and_parity_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "init.oci.tar"
            archive.write_bytes(b"first archive")

            def fingerprint(
                repetitions: int,
                core_coverage: int = 90,
                runtime_filter: str = "ComposeRuntimeTests",
                test_flags: str = "",
                test_attempts: int = 2,
                go_build_flags: str = "-trimpath",
                parity_overrides: dict[str, str] | None = None,
            ) -> str:
                parity_overrides = parity_overrides or {}
                completed = subprocess.run(
                    [
                        "make",
                        "--no-print-directory",
                        "-s",
                        "print-release-gate-fingerprint",
                        f"CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE={archive}",
                        f"PARITY_REPETITIONS={repetitions}",
                        f"SWIFT_CORE_COVERAGE_MIN={core_coverage}",
                        f"SWIFT_RUNTIME_TEST_FILTER={runtime_filter}",
                        f"SWIFT_TEST_FLAGS={test_flags}",
                        f"SWIFT_TEST_ATTEMPTS={test_attempts}",
                        f"GO_RELEASE_BUILD_FLAGS={go_build_flags}",
                        *(
                            f"{name}={value}"
                            for name, value in parity_overrides.items()
                        ),
                    ],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                    env=self.non_interactive_environment(),
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                return completed.stdout.strip()

            initial = fingerprint(1)
            archive.write_bytes(b"second archive")
            changed_archive = fingerprint(1)
            changed_repetitions = fingerprint(3)
            changed_coverage = fingerprint(3, core_coverage=91)
            changed_filter = fingerprint(3, 91, runtime_filter="OtherRuntimeTests")
            changed_flags = fingerprint(3, 91, "OtherRuntimeTests", "-Xswiftc -DSTRICT")
            changed_attempts = fingerprint(
                3, 91, "OtherRuntimeTests", "-Xswiftc -DSTRICT", test_attempts=3
            )
            changed_go_flags = fingerprint(
                3,
                91,
                "OtherRuntimeTests",
                "-Xswiftc -DSTRICT",
                3,
                "-trimpath -buildvcs=false",
            )

            self.assertNotEqual(initial, changed_archive)
            self.assertNotEqual(changed_archive, changed_repetitions)
            self.assertNotEqual(changed_repetitions, changed_coverage)
            self.assertNotEqual(changed_coverage, changed_filter)
            self.assertNotEqual(changed_filter, changed_flags)
            self.assertNotEqual(changed_flags, changed_attempts)
            self.assertNotEqual(changed_attempts, changed_go_flags)
            self.assertNotIn(str(archive), changed_archive)

            parity_baseline = fingerprint(3)
            for name, value in {
                "DOCKER_COMPOSE_PARITY_TARGETS": "docker-compose-links-parity",
                "PARITY_TIMING_MAX_RATIO": "9",
                "PARITY_TIMING_MIN_DELTA_SECONDS": "4",
                "PARITY_COMPARABLE_NOISE_PCT": "4",
                "PARITY_SINK_STALL_SECONDS": "3",
                "PARITY_PRESSURE_RECORDS": "32768",
                "PARITY_DOCKER_HOST_ADDRESS": "docker.example.invalid",
                "PARITY_CONTAINER_HOST_ADDRESS": "127.0.0.2",
            }.items():
                with self.subTest(parity_input=name):
                    self.assertNotEqual(
                        parity_baseline,
                        fingerprint(3, parity_overrides={name: value}),
                    )

    def test_release_gate_fingerprints_all_defaulted_parity_result_inputs(
        self,
    ) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        parity_source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROOT / "Tools" / "parity").glob("*.sh")
        )
        defaulted_inputs = set(
            re.findall(r'\b(PARITY_[A-Z0-9_]+)="\$\{\1:-', parity_source)
        )
        output_only_inputs = {"PARITY_EVIDENCE_DIR", "PARITY_TIMING_OUTPUT"}
        result_inputs = defaulted_inputs - output_only_inputs
        parity_fingerprint = makefile[
            makefile.index("RELEASE_GATE_PARITY_INPUT_FINGERPRINT") : makefile.index(
                "override RELEASE_GATE_STATIC_FINGERPRINT ="
            )
        ]

        self.assertTrue(result_inputs)
        for name in result_inputs:
            with self.subTest(parity_input=name):
                self.assertIn(f"$({name})", parity_fingerprint)
        self.assertIn("$(DOCKER_COMPOSE_PARITY_TARGETS)", parity_fingerprint)

    def test_phase5_builder_suites_are_unconditionally_restored(self) -> None:
        validation = STACK_RELEASE_VALIDATION.read_text(encoding="utf-8")
        self.assertNotIn(
            "CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON",
            self.script,
        )
        self.assertNotIn(
            "CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON",
            validation,
        )
        self.assertNotIn("phase5_excluded_concurrent_suites", validation)
        self.assertNotIn("CONCURRENT_TEST_SUITES=", validation)
        self.assertNotIn("TestCLIBuilder.swift", validation)
        self.assertNotIn("TestCLIBuilderLocalOutput.swift", validation)
        self.assertNotIn("TestCLIBuilderTarExport.swift", validation)

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
            (tap / "Formula").mkdir(parents=True)
            (tap / "Formula" / "container-compose.rb").touch()
            subprocess.run(["git", "-C", str(compose), "init", "--quiet"], check=True)
            subprocess.run(["git", "-C", str(compose), "add", "Makefile"], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(compose),
                    "-c",
                    "user.name=Release Test",
                    "-c",
                    "user.email=release-test@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "--quiet",
                    "-m",
                    "fixture",
                ],
                check=True,
            )

            tools = root / "tools"
            tools.mkdir()
            candidate_tools = root / "candidate-tools"
            candidate_tools.mkdir()
            candidate_tools_resolved = candidate_tools.resolve()
            log = root / "commands.log"
            for name in ("make", "ruby"):
                tool = tools / name
                tool.write_text(
                    "#!/usr/bin/env bash\n"
                    "if [[ \"${1:-}\" == \"--version\" ]]; then\n"
                    "  printf '%s version 1.0\\n' \"$(basename \"$0\")\"\n"
                    "  exit 0\n"
                    "fi\n"
                    "printf '%s:%s\\n' \"$(basename \"$0\")\" \"$*\" >> \"${STACK_VALIDATION_LOG:?}\"\n"
                    "printf 'bootstrap:%s\\n' \"${CONTAINER_INIT_BOOTSTRAP_IMAGE_ARCHIVE:-}\" >> \"${STACK_VALIDATION_LOG:?}\"\n"
                    "printf 'builder:%s\\n' \"${CONTAINER_INIT_BUILDER_IMAGE_ARCHIVE:-}\" >> \"${STACK_VALIDATION_LOG:?}\"\n"
                    "if [[ \"$(basename \"$0\")\" == make && "
                    "-n \"${MUTATE_RUNTIME_CLI_AFTER_MATCH:-}\" && "
                    "\"$*\" == *\"${MUTATE_RUNTIME_CLI_AFTER_MATCH}\"* ]]; then\n"
                    "  printf '# drift\\n' >>\"${CONTAINER_RUNTIME_CLI:?}\"\n"
                    "fi\n",
                    encoding="utf-8",
                )
                tool.chmod(0o755)
            for directory, marker in ((tools, "competing"), (candidate_tools, "candidate")):
                container_tool = directory / "container"
                container_tool.write_text(
                    "#!/usr/bin/env bash\n"
                    f"printf '%s\\n' {shlex.quote(marker)}\n",
                    encoding="utf-8",
                )
                container_tool.chmod(0o755)
            go_tool = tools / "go"
            go_tool.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"${1:-}\" == \"version\" ]]; then\n"
                "  printf 'go version %s\\n' \"${FAKE_GO_VERSION:?}\"\n"
                "  exit 0\n"
                "fi\n"
                "exit 64\n",
                encoding="utf-8",
            )
            go_tool.chmod(0o755)

            environment = os.environ.copy()
            environment["PATH"] = f"{tools}{os.pathsep}{environment['PATH']}"
            environment["BASH_ENV"] = "/dev/null"
            environment["ENV"] = "/dev/null"
            environment["STACK_VALIDATION_LOG"] = str(log)
            environment["FAKE_GO_VERSION"] = "go1.26.3"
            environment["CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE"] = "/tmp/runtime-init.oci.tar"
            environment["CONTAINER_RUNTIME_BUILDER_IMAGE_TAR"] = "/tmp/runtime-builder.oci.tar"
            environment["CONTAINER_RUNTIME_CLI"] = str(candidate_tools_resolved / "container")
            # This fixture substitutes its own candidate CLI. A full release
            # gate exports candidate identity and scratch locations for the
            # real validation run before running the policy tests. Inheriting
            # any of them would make the fixture validate its fake binary or
            # expected default paths against unrelated live state.
            environment.pop("CONTAINER_RUNTIME_CLI_SHA256", None)
            environment.pop("CONTAINER_RUNTIME_CANDIDATE_SHA256", None)
            environment.pop("CONTAINER_STACK_VALIDATION_SCRATCH_ROOT", None)
            environment["CONTAINER_STACK_VALIDATION_CHECKPOINT_DIR"] = str(
                root / "checkpoints"
            )
            runtime_directory = tempfile.TemporaryDirectory(
                prefix="ccsv-test.", dir="/tmp"
            )
            self.addCleanup(runtime_directory.cleanup)
            explicit_runtime_root = Path(runtime_directory.name)
            environment["CONTAINER_STACK_VALIDATION_RUNTIME_ROOT"] = str(
                explicit_runtime_root
            )
            validation_paths = [
                str(compose),
                str(builder),
                str(containerization),
                str(container),
                str(tap),
            ]

            environment.pop("CONTAINER_RUNTIME_CODESIGN_IDENTITY", None)
            missing_signing_identity = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(missing_signing_identity.returncode, 2)
            self.assertIn(
                "requires a Developer ID Application identity",
                missing_signing_identity.stderr,
            )
            signing_identity = "A" * 40
            environment["CONTAINER_RUNTIME_CODESIGN_IDENTITY"] = signing_identity

            full = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(full.returncode, 0, full.stderr)
            full_commands = log.read_text(encoding="utf-8")
            resolved_container = container.resolve()

            def assert_make_targets(
                commands: str,
                repository: Path | str,
                targets: tuple[str, ...],
                required_fragment: str = "",
            ) -> None:
                prefix = f"make:-C {repository} "
                command_lines = commands.splitlines()
                for target in targets:
                    self.assertTrue(
                        any(
                            line.startswith(prefix)
                            and required_fragment in line
                            and line.endswith(f" {target}")
                            for line in command_lines
                        ),
                        f"missing independent {repository} stage {target}:\n{commands}",
                    )

            self.assertIn(
                f"make:-C {containerization} PATH={candidate_tools_resolved}{os.pathsep}{tools}",
                full_commands,
            )
            assert_make_targets(
                full_commands,
                containerization,
                (
                    "check",
                    "containerization",
                    "examples",
                    "docs",
                    "coverage",
                    "fetch-default-kernel",
                    "integration",
                ),
            )
            assert_make_targets(
                full_commands,
                container,
                ("check", "container", "dsym", "docs", "coverage"),
                required_fragment=(
                    "CODESIGN_OPTS=--force --sign "
                    f"{signing_identity} --timestamp=none "
                    f"APP_ROOT={explicit_runtime_root.resolve()}/stack-release-app-root "
                    f"LOG_ROOT={explicit_runtime_root.resolve()}/stack-release-log-root "
                    "INTEGRATION_SERVICE_NAMESPACE="
                    "io.github.container.stack-validation.fixture"
                ),
            )
            self.assertNotIn("CONCURRENT_TEST_SUITES=", full_commands)
            self.assertIn("bootstrap:/tmp/runtime-init.oci.tar", full_commands)
            self.assertIn("builder:/tmp/runtime-builder.oci.tar", full_commands)

            repeated_runtime_directory = tempfile.TemporaryDirectory(
                prefix="ccsv-retry-test.", dir="/tmp"
            )
            self.addCleanup(repeated_runtime_directory.cleanup)
            environment["CONTAINER_STACK_VALIDATION_RUNTIME_ROOT"] = str(
                Path(repeated_runtime_directory.name)
            )
            repeated_full = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(repeated_full.returncode, 0, repeated_full.stderr)
            self.assertEqual(log.read_text(encoding="utf-8"), full_commands)
            self.assertIn(
                "reusing exact-input validation checkpoint: containerization-check",
                repeated_full.stdout,
            )

            (compose / "Makefile").write_text("compose-only-change:\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(compose), "add", "Makefile"], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(compose),
                    "-c",
                    "user.name=Release Test",
                    "-c",
                    "user.email=release-test@example.invalid",
                    "-c",
                    "commit.gpgsign=false",
                    "commit",
                    "--quiet",
                    "-m",
                    "compose-only change",
                ],
                check=True,
            )
            changed_compose = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(changed_compose.returncode, 0, changed_compose.stderr)
            self.assertEqual(log.read_text(encoding="utf-8"), full_commands)
            self.assertEqual(
                changed_compose.stdout.count("reusing exact-input validation checkpoint:"),
                18,
                changed_compose.stdout,
            )

            environment["FAKE_GO_VERSION"] = "go1.26.4"
            changed_toolchain = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(changed_toolchain.returncode, 0, changed_toolchain.stderr)
            changed_commands = log.read_text(encoding="utf-8")
            self.assertEqual(
                changed_commands.count(f"make:-C {builder}"),
                10,
                full.stdout
                + repeated_full.stdout
                + changed_toolchain.stdout
                + changed_toolchain.stderr
                + changed_commands,
            )
            self.assertNotIn(
                "reusing exact-input validation checkpoint",
                changed_toolchain.stdout,
            )

            packaged_log = root / "packaged-commands.log"
            packaged_checkpoints = root / "packaged-checkpoints"
            packaged_environments = []
            for index in (1, 2):
                packaged_tools = root / f"packaged-candidate-{index}"
                packaged_tools.mkdir()
                packaged_cli = packaged_tools / "container"
                packaged_cli.write_text(
                    "#!/usr/bin/env bash\nprintf 'packaged candidate\\n'\n",
                    encoding="utf-8",
                )
                packaged_cli.chmod(0o555)
                packaged_environment = environment.copy()
                packaged_environment["PATH"] = (
                    f"{packaged_tools}{os.pathsep}{packaged_tools}"
                    f"{os.pathsep}{environment['PATH']}"
                )
                packaged_environment["STACK_VALIDATION_LOG"] = str(packaged_log)
                packaged_environment["CONTAINER_RUNTIME_CLI"] = str(packaged_cli)
                packaged_environment["CONTAINER_RUNTIME_CANDIDATE_SHA256"] = "a" * 64
                packaged_environment["CONTAINER_STACK_VALIDATION_CHECKPOINT_DIR"] = str(
                    packaged_checkpoints
                )
                packaged_environments.append(packaged_environment)

            first_packaged = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=packaged_environments[0],
                text=True,
            )
            self.assertEqual(first_packaged.returncode, 0, first_packaged.stderr)
            first_packaged_commands = packaged_log.read_text(encoding="utf-8")
            second_packaged = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=packaged_environments[1],
                text=True,
            )
            self.assertEqual(second_packaged.returncode, 0, second_packaged.stderr)
            self.assertEqual(
                packaged_log.read_text(encoding="utf-8"),
                first_packaged_commands,
                first_packaged.stdout
                + first_packaged.stderr
                + second_packaged.stdout
                + second_packaged.stderr,
            )
            self.assertEqual(
                second_packaged.stdout.count(
                    "reusing exact-input validation checkpoint:"
                ),
                18,
                second_packaged.stdout,
            )

            packaged_cli.chmod(0o755)
            writable_packaged = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=packaged_environments[1],
                text=True,
            )
            self.assertEqual(writable_packaged.returncode, 2)
            self.assertIn(
                "packaged Container runtime candidate CLI must be read-only",
                writable_packaged.stderr,
            )

            drift_environment = environment.copy()
            drift_environment["CONTAINER_STACK_VALIDATION_CHECKPOINT_DIR"] = str(
                root / "drift-checkpoints"
            )
            drift_environment["MUTATE_RUNTIME_CLI_AFTER_MATCH"] = str(
                containerization
            )
            drift = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=drift_environment,
                text=True,
            )
            self.assertEqual(drift.returncode, 2)
            self.assertIn("Container CLI content drifted", drift.stderr)
            self.assertFalse(
                (
                    root
                    / "drift-checkpoints"
                    / "full-containerization-check.sha256"
                ).exists()
            )

            log.unlink()
            environment.pop("CONTAINER_STACK_VALIDATION_RUNTIME_ROOT")
            hosted = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *validation_paths],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(hosted.returncode, 0, hosted.stderr)
            hosted_commands = log.read_text(encoding="utf-8")
            assert_make_targets(
                hosted_commands,
                containerization,
                ("check", "containerization", "examples", "docs", "coverage"),
            )
            assert_make_targets(
                hosted_commands,
                container,
                ("check", "build", "dsym", "docs", "coverage-unit"),
                required_fragment=(
                    f"APP_ROOT={resolved_container}/.test-scratch/runtime/"
                    "stack-release-app-root"
                ),
            )
            self.assertFalse(
                any(
                    line.startswith(f"make:-C {container} ")
                    and line.endswith(" container")
                    for line in hosted_commands.splitlines()
                ),
                hosted_commands,
            )
            self.assertNotIn(" integration", hosted_commands)
            self.assertNotIn(" fetch-default-kernel", hosted_commands)

            log.unlink()
            relative_paths = [
                path.name
                for path in (compose, builder, containerization, container, tap)
            ]
            relative = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *relative_paths],
                check=False,
                capture_output=True,
                cwd=root,
                env=environment,
                text=True,
            )
            self.assertEqual(relative.returncode, 0, relative.stderr)
            self.assertFalse(log.exists())
            self.assertEqual(
                relative.stdout.count(
                    "reusing exact-input validation checkpoint:"
                ),
                16,
                relative.stdout,
            )

            container_link = root / "container-link"
            container_link.symlink_to(container, target_is_directory=True)
            symlink_paths = validation_paths.copy()
            symlink_paths[3] = str(container_link)
            symlinked = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *symlink_paths],
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(symlinked.returncode, 0, symlinked.stderr)
            self.assertFalse(log.exists())
            self.assertEqual(
                symlinked.stdout.count(
                    "reusing exact-input validation checkpoint:"
                ),
                16,
                symlinked.stdout,
            )

            external_scratch = root / "external-runtime"
            external_environment = environment.copy()
            external_environment["CONTAINER_STACK_VALIDATION_SCRATCH_ROOT"] = str(
                external_scratch
            )
            external_environment["CONTAINER_STACK_VALIDATION_CHECKPOINT_DIR"] = str(
                root / "external-checkpoints"
            )
            external = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *validation_paths],
                check=False,
                capture_output=True,
                env=external_environment,
                text=True,
            )
            self.assertEqual(external.returncode, 0, external.stderr)
            external_commands = log.read_text(encoding="utf-8")
            resolved_external_scratch = external_scratch.resolve()
            assert_make_targets(
                external_commands,
                container,
                ("check", "build", "dsym", "docs", "coverage-unit"),
                required_fragment=(
                    f"APP_ROOT={resolved_external_scratch}/runtime/"
                    "stack-release-app-root"
                ),
            )

            log.unlink()
            internal_runtime = root / "internal-launchd-runtime"
            split_environment = external_environment.copy()
            split_environment["CONTAINER_STACK_VALIDATION_RUNTIME_ROOT"] = str(
                internal_runtime
            )
            split_environment["CONTAINER_STACK_VALIDATION_CHECKPOINT_DIR"] = str(
                root / "split-checkpoints"
            )
            split = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *validation_paths],
                check=False,
                capture_output=True,
                env=split_environment,
                text=True,
            )
            self.assertEqual(split.returncode, 0, split.stderr)
            split_commands = log.read_text(encoding="utf-8")
            assert_make_targets(
                split_commands,
                container,
                ("check", "build", "dsym", "docs", "coverage-unit"),
                required_fragment=(
                    f"APP_ROOT={internal_runtime.resolve()}/stack-release-app-root"
                ),
            )

            invalid_environment = environment.copy()
            invalid_environment["CONTAINER_STACK_VALIDATION_SCRATCH_ROOT"] = ".scratch"
            invalid = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *validation_paths],
                check=False,
                capture_output=True,
                env=invalid_environment,
                text=True,
            )
            self.assertEqual(invalid.returncode, 2)
            self.assertIn(
                "CONTAINER_STACK_VALIDATION_SCRATCH_ROOT must be an absolute path",
                invalid.stderr,
            )

            root_link = root / "root-link"
            root_link.symlink_to(Path("/"), target_is_directory=True)
            root_environment = environment.copy()
            root_environment["CONTAINER_STACK_VALIDATION_SCRATCH_ROOT"] = str(
                root_link
            )
            root_scratch = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *validation_paths],
                check=False,
                capture_output=True,
                env=root_environment,
                text=True,
            )
            self.assertEqual(root_scratch.returncode, 2)
            self.assertIn(
                "CONTAINER_STACK_VALIDATION_SCRATCH_ROOT must not resolve to /",
                root_scratch.stderr,
            )

            relative_runtime_environment = environment.copy()
            relative_runtime_environment[
                "CONTAINER_STACK_VALIDATION_RUNTIME_ROOT"
            ] = ".runtime"
            relative_runtime = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *validation_paths],
                check=False,
                capture_output=True,
                env=relative_runtime_environment,
                text=True,
            )
            self.assertEqual(relative_runtime.returncode, 2)
            self.assertIn(
                "CONTAINER_STACK_VALIDATION_RUNTIME_ROOT must be an absolute path",
                relative_runtime.stderr,
            )

            root_runtime_environment = environment.copy()
            root_runtime_environment["CONTAINER_STACK_VALIDATION_RUNTIME_ROOT"] = str(
                root_link
            )
            root_runtime = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "hosted", *validation_paths],
                check=False,
                capture_output=True,
                env=root_runtime_environment,
                text=True,
            )
            self.assertEqual(root_runtime.returncode, 2)
            self.assertIn(
                "CONTAINER_STACK_VALIDATION_RUNTIME_ROOT must not resolve to /",
                root_runtime.stderr,
            )

            long_runtime_environment = environment.copy()
            long_runtime_environment["CONTAINER_STACK_VALIDATION_RUNTIME_ROOT"] = str(
                root / ("long-runtime-" + "x" * 80)
            )
            long_runtime = subprocess.run(
                [str(STACK_RELEASE_VALIDATION), "full", *validation_paths],
                check=False,
                capture_output=True,
                env=long_runtime_environment,
                text=True,
            )
            self.assertEqual(long_runtime.returncode, 2)
            self.assertIn(
                "exceeds the provider Unix socket path limit",
                long_runtime.stderr,
            )

    def test_hosted_release_gate_uses_an_unpublished_verified_tag_and_immutable_tap_snapshot(
        self,
    ) -> None:
        workflow = STABLE_GATE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            "runs-on: [self-hosted, macOS, ARM64, container-compose-release]",
            workflow,
        )
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
        self.assertIn("Select supported Bash 5 runtime", workflow)
        self.assertIn("HOMEBREW_NO_AUTO_UPDATE=1 brew install bash", workflow)
        self.assertIn("(( BASH_VERSINFO[0] >= 5 ))", workflow)
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
        self.assertIn("Run Compose application CI from immutable source lockfile", workflow)
        self.assertIn("make -C container-compose", workflow)
        self.assertIn("complete main CI, including the 390 tool-policy tests", workflow)
        for target in (
            "format",
            "core-runtime-neutrality",
            "stack-consistency",
            "upstream-handoff-registry-check",
            "check-licenses",
            "performance-matrix-harness-test",
            "signal-log-reliability-harness-test",
            "coverage-check",
            "go-build",
            "cli-smoke-built",
        ):
            self.assertIn(target, workflow)
        self.assertNotIn("make -C container-compose ci", workflow)
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
            workflow.index("Select supported Bash 5 runtime"),
            workflow.index("Provision pinned stack tools"),
        )
        self.assertLess(
            workflow.index("Provision pinned stack tools"),
            workflow.index("Run hosted release gate"),
        )
        self.assertLess(
            workflow.index("Run Compose application CI from immutable source lockfile"),
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
        self.assertIn('containerization_path="$(repo_path "containerization")"', self.script)
        self.assertIn('make -C "${containerization_path}" fetch-default-kernel', self.script)
        self.assertIn("one fresh marker-protected runtime lifecycle", self.script)
        self.assertIn("CONTAINER_RUNTIME_REQUIRED_INIT_IMAGE_REFERENCES", self.script)
        self.assertIn("CONTAINER_RUNTIME_INIT_BLOCK_REPO", self.script)
        self.assertIn("CONTAINERIZATION_INIT_SOURCE_PATH", self.script)
        self.assertIn("-u CONTAINER_RUNTIME_SERVICE_NAMESPACE", self.script)

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
        build_doc = (ROOT / "docs/guides/BUILD.md").read_text(encoding="utf-8")
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

    def test_local_release_gate_keeps_llvm_profiles_out_of_source_checkouts(self) -> None:
        local_gate = self.script[
            self.script.index("run_local_release_gate() {") : self.script.index(
                "# Verify that Apple remotes cannot be pushed"
            )
        ]
        self.assertIn('profile_root="${runtime_parent}/profiles"', local_gate)
        self.assertIn('mkdir -p "${profile_root}"', local_gate)
        self.assertIn('LLVM_PROFILE_FILE="${profile_root}/%p-%m.profraw"', local_gate)
        self.assertIn(
            'init_image_archive="${CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE:-}"',
            local_gate,
        )
        self.assertIn(
            "local release gate requires an absolute retained OCI init-image archive",
            local_gate,
        )
        self.assertIn(
            'CONTAINER_RUNTIME_INIT_IMAGE_ARCHIVE="${init_image_archive}"',
            local_gate,
        )
        self.assertIn(
            'CONTAINER_STACK_VALIDATION_SCRATCH_ROOT="${evidence_root}/container-scratch"',
            local_gate,
        )
        self.assertIn(
            'CONTAINER_STACK_VALIDATION_RUNTIME_ROOT="${runtime_parent}/i"',
            local_gate,
        )
        self.assertIn("runtime_parent_base=/private/tmp", local_gate)
        self.assertIn(
            '[[ ! -d "${runtime_parent_base}" || ! -w "${runtime_parent_base}" ]]',
            local_gate,
        )
        self.assertNotIn('${TMPDIR:-/tmp}/cc-release.', local_gate)
        self.assertIn(
            'runtime_parent="$(create_release_runtime_parent "${runtime_parent_base}")"',
            local_gate,
        )
        self.assertIn(
            '.container-compose-release-runtime-parent',
            self.script,
        )
        self.assertLess(
            local_gate.index('create_release_runtime_parent "${runtime_parent_base}"'),
            local_gate.index('run_local_release_gate_command env'),
        )
        self.assertIn(
            '[[ ! -d "${candidate_parent}" || ! -w "${candidate_parent}" ]]',
            self.script,
        )
        self.assertIn("resolve_release_evidence_root", local_gate)
        self.assertLess(
            local_gate.index('"${OCI_IMAGE_LAYOUT_VALIDATOR}" "${init_image_archive}"'),
            local_gate.index('stage_container_runtime_candidate "${container_path}"'),
        )
        self.assertLess(
            local_gate.index('profile_root="${runtime_parent}/profiles"'),
            local_gate.index('"${path}/scripts/run-with-container-runtime.sh"'),
        )

    def test_local_release_gate_waits_for_signal_cleanup_before_candidate_deletion(
        self,
    ) -> None:
        release_signals = (
            signal.SIGHUP,
            signal.SIGINT,
            signal.SIGQUIT,
            signal.SIGTERM,
        )

        def reset_release_signals() -> None:
            # Long-running test supervisors can ignore SIGHUP before they
            # launch this fixture. Bash cannot trap a signal that was ignored
            # when the shell started, so normalise the child exactly as a
            # directly launched release helper before exercising its traps.
            for number in release_signals:
                signal.signal(number, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_UNBLOCK, release_signals)

        with tempfile.TemporaryDirectory() as directory:
            for delivered_signal, expected_status in (
                (signal.SIGHUP, 129),
                (signal.SIGINT, 130),
                (signal.SIGQUIT, 131),
                (signal.SIGTERM, 143),
            ):
                for signal_scope in ("process", "group"):
                    root = Path(directory) / delivered_signal.name / signal_scope
                    candidate_root = root / "candidate"
                    candidate_bin = candidate_root / "bin"
                    candidate_bin.mkdir(parents=True)
                    candidate_cli = candidate_bin / "container"
                    candidate_cli.write_text(
                        "#!/usr/bin/env bash\nexit 0\n", encoding="utf-8"
                    )
                    candidate_cli.chmod(0o755)
                    ready = root / "ready"
                    cleanup_started = root / "cleanup-started"
                    stop_complete = root / "stop-complete"
                    removed = root / "removed"
                    fake_gate = root / "fake-gate"
                    fake_gate.write_text(
                        "#!/usr/bin/env bash\n"
                        "set -u\n"
                        "cleanup() { trap '' HUP INT QUIT TERM; "
                        "test -x \"$CANDIDATE_ROOT/bin/container\"; "
                        "touch \"$CLEANUP_STARTED\"; sleep 0.5; "
                        "touch \"$STOP_COMPLETE\"; }\n"
                        "trap 'cleanup; exit 129' HUP\n"
                        "trap 'cleanup; exit 130' INT\n"
                        "trap 'cleanup; exit 131' QUIT\n"
                        "trap 'cleanup; exit 143' TERM\n"
                        "touch \"$READY\"\n"
                        # A signal sent only to this wrapper leaves its
                        # synchronous gate descendant alive and defers the
                        # wrapper trap. The helper must supervise and signal
                        # their complete process group.
                        "/bin/sh -c 'while :; do sleep 1; done'\n",
                        encoding="utf-8",
                    )
                    fake_gate.chmod(0o755)
                    shell = "\n".join(
                        [
                            "set -u",
                            "export CONTAINER_STACK_RELEASE_LIBRARY=1",
                            f"source {shlex.quote(str(SCRIPT))}",
                            f"export CANDIDATE_ROOT={shlex.quote(str(candidate_root))}",
                            f"export READY={shlex.quote(str(ready))}",
                            "export CLEANUP_STARTED="
                            f"{shlex.quote(str(cleanup_started))}",
                            f"export STOP_COMPLETE={shlex.quote(str(stop_complete))}",
                            "status=0",
                            "run_local_release_gate_command "
                            f"{shlex.quote(str(fake_gate))} || status=$?",
                            'test -f "$STOP_COMPLETE"',
                            'find "$CANDIDATE_ROOT" -depth -delete',
                            f"touch {shlex.quote(str(removed))}",
                            'exit "$status"',
                        ]
                    )
                    process = subprocess.Popen(
                        ["bash", "-c", shell],
                        cwd=ROOT,
                        env=self.non_interactive_environment(),
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        start_new_session=True,
                        preexec_fn=reset_release_signals,
                    )
                    # This regression test deliberately coordinates three
                    # process layers. Give a busy release runner enough time
                    # to schedule them before declaring the signal contract
                    # broken; the subprocess still has its own bounded exit.
                    deadline = time.monotonic() + 30
                    while not ready.exists() and process.poll() is None:
                        if time.monotonic() >= deadline:
                            os.killpg(process.pid, signal.SIGKILL)
                            stdout, stderr = process.communicate(timeout=10)
                            self.fail(
                                "outer release gate did not become ready for "
                                f"{delivered_signal.name}/{signal_scope}\n"
                                + stdout
                                + stderr
                            )
                        time.sleep(0.05)

                    send_signal = os.kill if signal_scope == "process" else os.killpg
                    send_signal(process.pid, delivered_signal)
                    deadline = time.monotonic() + 30
                    while not cleanup_started.exists() and process.poll() is None:
                        if time.monotonic() >= deadline:
                            os.killpg(process.pid, signal.SIGKILL)
                            stdout, stderr = process.communicate(timeout=10)
                            self.fail(
                                "candidate signal cleanup did not start for "
                                f"{delivered_signal.name}/{signal_scope}\n"
                                + stdout
                                + stderr
                            )
                        time.sleep(0.01)
                    send_signal(process.pid, delivered_signal)
                    try:
                        stdout, stderr = process.communicate(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        stdout, stderr = process.communicate(timeout=10)
                        self.fail(
                            "outer release gate did not finish after cleanup\n"
                            + stdout
                            + stderr
                        )

                    self.assertEqual(
                        process.returncode, expected_status, stdout + stderr
                    )
                    self.assertTrue(stop_complete.exists(), stdout + stderr)
                    self.assertTrue(removed.exists(), stdout + stderr)
                    self.assertFalse(candidate_root.exists(), stdout + stderr)

        local_gate = self.script[
            self.script.index("run_local_release_gate_command() {") : self.script.index(
                "# Resolve retained evidence"
            )
        ]
        self.assertIn('"${RELEASE_COMMAND_DEADLINE_RUNNER}"', local_gate)
        self.assertIn("--no-deadline", local_gate)

    def test_outer_marker_cleans_a_pre_runtime_interrupt_root(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="cc-parent-test.") as directory:
            fixture_root = Path(directory)
            runtime_parent = Path(
                tempfile.mkdtemp(prefix="c.pre-marker-test.", dir="/tmp")
            )
            self.addCleanup(
                lambda: subprocess.run(
                    ["find", str(runtime_parent), "-depth", "-delete"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if runtime_parent.exists()
                else None
            )
            (runtime_parent / ".container-compose-release-runtime-parent").write_text(
                "container-compose release runtime parent v1\n", encoding="utf-8"
            )
            (runtime_parent / "profiles").mkdir()

            cleaned = self.run_release_function(
                fixture_root,
                "cleanup_release_runtime_parent "
                f"{shlex.quote(str(runtime_parent))}; "
                f"test ! -e {shlex.quote(str(runtime_parent))}",
            )

            self.assertEqual(cleaned.returncode, 0, cleaned.stderr)

    def test_parent_cleanup_stops_exact_namespace_before_removing_roots(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="cc-cleanup-test.") as directory:
            root = Path(directory)
            runtime_parent = Path(
                tempfile.mkdtemp(prefix="c.parent-stop-test.", dir="/tmp")
            )
            candidate_root = Path(
                tempfile.mkdtemp(
                    prefix="container-compose-runtime-candidate.stop-test.",
                    dir="/tmp",
                )
            )
            self.addCleanup(
                lambda: subprocess.run(
                    ["find", str(runtime_parent), "-depth", "-delete"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if runtime_parent.exists()
                else None
            )
            self.addCleanup(
                lambda: subprocess.run(
                    ["find", str(candidate_root), "-depth", "-delete"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if candidate_root.exists()
                else None
            )
            (runtime_parent / ".container-compose-release-runtime-parent").write_text(
                "container-compose release runtime parent v1\n", encoding="utf-8"
            )
            runtime_app_root = runtime_parent / "app"
            runtime_app_root.mkdir()
            (candidate_root / ".container-compose-runtime-candidate-run").write_text(
                "container-compose runtime candidate run v1 fixture digest\n",
                encoding="utf-8",
            )
            candidate_bin = candidate_root / "bin"
            candidate_bin.mkdir()
            stop_log = root / "stop.log"
            candidate_cli = candidate_bin / "container"
            candidate_cli.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'test -d "$CONTAINER_APP_ROOT"\n'
                'printf "%s|%s|%s\\n" "$CONTAINER_APP_ROOT" '
                '"$CONTAINER_SERVICE_NAMESPACE" "$*" >"$STOP_LOG"\n',
                encoding="utf-8",
            )
            candidate_cli.chmod(0o755)
            namespace = (
                "io.github.stephenlclarke.container-compose.runtime.parentstoptest"
            )

            cleaned = self.run_release_function(
                root,
                "cleanup_local_release_gate_resources "
                f"{shlex.quote(str(candidate_cli))} "
                f"{shlex.quote(str(runtime_parent))} "
                f"{shlex.quote(str(runtime_app_root))} "
                f"{shlex.quote(namespace)}; "
                f"test ! -e {shlex.quote(str(runtime_parent))}; "
                f"test ! -e {shlex.quote(str(candidate_root))}",
                shell_setup=(
                    f"CONTAINER_RUNTIME_CANDIDATE_ROOT={shlex.quote(str(candidate_root))}\n"
                    f"export STOP_LOG={shlex.quote(str(stop_log))}"
                ),
            )

            self.assertEqual(cleaned.returncode, 0, cleaned.stderr)
            self.assertEqual(
                stop_log.read_text(encoding="utf-8").strip(),
                f"{runtime_app_root}|{namespace}|system stop",
            )

    def test_parent_cleanup_retains_roots_when_exact_stop_fails(self) -> None:
        runtime_parent = Path(
            tempfile.mkdtemp(prefix="c.failed-stop-test.", dir="/tmp")
        )
        candidate_root = Path(
            tempfile.mkdtemp(
                prefix="container-compose-runtime-candidate.failed-stop-test.",
                dir="/tmp",
            )
        )
        self.addCleanup(
            lambda: subprocess.run(
                ["find", str(runtime_parent), "-depth", "-delete"],
                check=False,
                capture_output=True,
                text=True,
            )
            if runtime_parent.exists()
            else None
        )
        self.addCleanup(
            lambda: subprocess.run(
                ["find", str(candidate_root), "-depth", "-delete"],
                check=False,
                capture_output=True,
                text=True,
            )
            if candidate_root.exists()
            else None
        )
        (runtime_parent / ".container-compose-release-runtime-parent").write_text(
            "container-compose release runtime parent v1\n", encoding="utf-8"
        )
        runtime_app_root = runtime_parent / "app"
        runtime_app_root.mkdir()
        (candidate_root / ".container-compose-runtime-candidate-run").write_text(
            "container-compose runtime candidate run v1 fixture digest\n",
            encoding="utf-8",
        )
        candidate_bin = candidate_root / "bin"
        candidate_bin.mkdir()
        candidate_cli = candidate_bin / "container"
        candidate_cli.write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
        candidate_cli.chmod(0o755)
        namespace = "io.github.stephenlclarke.container-compose.runtime.failedstoptest"

        retained = self.run_release_function(
            Path("/tmp"),
            "if cleanup_local_release_gate_resources "
            f"{shlex.quote(str(candidate_cli))} "
            f"{shlex.quote(str(runtime_parent))} "
            f"{shlex.quote(str(runtime_app_root))} "
            f"{shlex.quote(namespace)}; then exit 99; fi; "
            f"test -d {shlex.quote(str(runtime_parent))}; "
            f"test -d {shlex.quote(str(candidate_root))}",
            shell_setup=(
                f"CONTAINER_RUNTIME_CANDIDATE_ROOT={shlex.quote(str(candidate_root))}"
            ),
        )

        self.assertEqual(retained.returncode, 0, retained.stderr)
        self.assertIn("failed to stop release runtime namespace", retained.stderr)

    def test_parent_cleanup_bounds_a_hung_exact_stop_and_retains_roots(self) -> None:
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="cc-stop-timeout-test.") as directory:
            fixture_root = Path(directory)
            stop_started = fixture_root / "stop-started"
            runtime_parent = Path(
                tempfile.mkdtemp(prefix="c.stop-timeout-test.", dir="/tmp")
            )
            candidate_root = Path(
                tempfile.mkdtemp(
                    prefix="container-compose-runtime-candidate.stop-timeout-test.",
                    dir="/tmp",
                )
            )
            self.addCleanup(
                lambda: subprocess.run(
                    ["find", str(runtime_parent), "-depth", "-delete"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if runtime_parent.exists()
                else None
            )
            self.addCleanup(
                lambda: subprocess.run(
                    ["find", str(candidate_root), "-depth", "-delete"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                if candidate_root.exists()
                else None
            )
            (runtime_parent / ".container-compose-release-runtime-parent").write_text(
                "container-compose release runtime parent v1\n", encoding="utf-8"
            )
            runtime_app_root = runtime_parent / "app"
            runtime_app_root.mkdir()
            (candidate_root / ".container-compose-runtime-candidate-run").write_text(
                "container-compose runtime candidate run v1 fixture digest\n",
                encoding="utf-8",
            )
            candidate_bin = candidate_root / "bin"
            candidate_bin.mkdir()
            candidate_cli = candidate_bin / "container"
            candidate_cli.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                'touch "$STOP_STARTED"\n'
                "sleep 30\n",
                encoding="utf-8",
            )
            candidate_cli.chmod(0o755)
            namespace = (
                "io.github.stephenlclarke.container-compose.runtime.stoptimeouttest"
            )

            started = time.monotonic()
            retained = self.run_release_function(
                fixture_root,
                "if cleanup_local_release_gate_resources "
                f"{shlex.quote(str(candidate_cli))} "
                f"{shlex.quote(str(runtime_parent))} "
                f"{shlex.quote(str(runtime_app_root))} "
                f"{shlex.quote(namespace)}; then exit 99; fi; "
                f"test -d {shlex.quote(str(runtime_parent))}; "
                f"test -d {shlex.quote(str(candidate_root))}",
                shell_setup=(
                    f"CONTAINER_RUNTIME_CANDIDATE_ROOT={shlex.quote(str(candidate_root))}\n"
                    "CANDIDATE_STOP_TIMEOUT_SECONDS=1\n"
                    f"export STOP_STARTED={shlex.quote(str(stop_started))}"
                ),
            )

            self.assertEqual(retained.returncode, 0, retained.stderr)
            self.assertLess(time.monotonic() - started, 5, retained.stderr)
            self.assertTrue(stop_started.exists(), retained.stderr)
            self.assertIn(
                "timed out stopping release runtime namespace", retained.stderr
            )

    def test_creator_cleanup_stays_armed_through_path_publication(self) -> None:
        runtime_parent = Path("/tmp") / (
            f"c.publication-test.{os.getpid()}.{time.time_ns()}"
        )
        self.addCleanup(
            lambda: subprocess.run(
                ["find", str(runtime_parent), "-depth", "-delete"],
                check=False,
                capture_output=True,
                text=True,
            )
            if runtime_parent.exists()
            else None
        )
        shell_setup = textwrap.dedent(
            f"""\
            runtime_parent_fixture={shlex.quote(str(runtime_parent))}
            mktemp() {{
              mkdir "${{runtime_parent_fixture}}"
              builtin printf '%s\\n' "${{runtime_parent_fixture}}"
            }}
            printf() {{
              if [[ "$#" -eq 2 && "$1" == '%s\\n' && "$2" == "${{runtime_parent_fixture}}" ]]; then
                kill -TERM "${{BASHPID}}"
              fi
              builtin printf "$@"
            }}
            """
        )

        interrupted = self.run_release_function(
            Path("/tmp"),
            'published="$(create_release_runtime_parent /tmp)"',
            shell_setup=shell_setup,
        )

        self.assertEqual(interrupted.returncode, 143, interrupted.stderr)
        self.assertFalse(runtime_parent.exists(), interrupted.stderr)

    def test_creator_disarms_exit_cleanup_after_successful_publication(self) -> None:
        published = self.run_release_function(
            Path("/tmp"),
            'published="$(create_release_runtime_parent /tmp)"; '
            'test -d "$published"; '
            'cleanup_release_runtime_parent "$published"; '
            'test ! -e "$published"',
        )

        self.assertEqual(published.returncode, 0, published.stderr)
        self.assertEqual(published.stderr, "")

    def test_release_evidence_root_is_absolute_canonical_and_not_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compose = root / "compose"
            compose.mkdir()
            relative = self.run_release_function(
                root,
                "resolve_release_evidence_root "
                f"{shlex.quote(str(compose))} .build/release-evidence",
            )
            self.assertEqual(relative.returncode, 0, relative.stderr)
            self.assertEqual(
                relative.stdout.strip(),
                str((compose / ".build" / "release-evidence").resolve()),
            )

            root_link = root / "root-link"
            root_link.symlink_to(Path("/"), target_is_directory=True)
            rejected = self.run_release_function(
                root,
                "resolve_release_evidence_root "
                f"{shlex.quote(str(compose))} {shlex.quote(str(root_link))}",
            )
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("must not resolve to /", rejected.stderr)

    def test_local_release_gate_freezes_the_container_runtime_candidate(self) -> None:
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        stack_validation = makefile[
            makefile.index("container-stack-release-validation:") : makefile.index(
                "container-stack-hosted-release-validation:"
            )
        ]
        staging = self.script[
            self.script.index("stage_container_runtime_candidate() {") : self.script.index(
                "# Delete only the fresh marker-protected candidate extraction"
            )
        ]
        local_gate = self.script[
            self.script.index("run_local_release_gate() {") : self.script.index(
                "# Verify that Apple remotes cannot be pushed"
            )
        ]

        self.assertIn("git -C \"${container_path}\" rev-parse", staging)
        self.assertIn(
            'CONTAINER_RUNTIME_CODESIGN_IDENTITY="$(CONTAINER_RUNTIME_CODESIGN_IDENTITY)"',
            stack_validation,
        )
        self.assertIn("homebrew-package", staging)
        self.assertIn('"HOMEBREW_ARCHIVE=${archive}"', staging)
        self.assertIn(
            '"CODESIGN_OPTS=--force --sign ${signing_identity} --timestamp=none"',
            staging,
        )
        self.assertIn(
            'artifact_root="${artifact_parent}/${container_head}-${signing_identity}"',
            staging,
        )
        self.assertIn("shasum -a 256 -c", staging)
        self.assertIn("tar -xzf \"${archive}\"", staging)
        self.assertIn("chmod -R a-w", staging)
        self.assertIn("candidate_parent=/private/tmp", staging)
        self.assertNotIn('candidate_parent="${artifact_root}/runs"', staging)
        self.assertIn(".container-compose-runtime-candidate-artifact", staging)
        self.assertIn(".container-compose-runtime-candidate-run", staging)
        self.assertNotIn('make -C "${container_path}" container', local_gate)
        self.assertIn(
            'container_binary="${CONTAINER_RUNTIME_CANDIDATE_ROOT}/bin/container"',
            local_gate,
        )
        self.assertIn(
            'CONTAINER_RUNTIME_CANDIDATE_SHA256="${CONTAINER_RUNTIME_CANDIDATE_SHA256}"',
            local_gate,
        )
        self.assertIn(
            '"CONTAINER_BUILDER_SHIM_STACK_REPO=$(repo_path "container-builder-shim")"',
            local_gate,
        )
        self.assertIn(
            '"CONTAINERIZATION_STACK_REPO=${containerization_path}"',
            local_gate,
        )
        self.assertIn('"CONTAINER_STACK_REPO=${container_path}"', local_gate)
        compose_container_environment = (
            'CONTAINER_COMPOSE_CONTAINER="${container_binary}" \\'
        )
        runtime_wrapper = (
            '"${path}/scripts/run-with-container-runtime.sh" "${container_binary}"'
        )
        self.assertIn(compose_container_environment, local_gate)
        self.assertLess(
            local_gate.index(compose_container_environment),
            local_gate.index(runtime_wrapper),
        )
        self.assertNotIn(
            '"CONTAINER_COMPOSE_CONTAINER=${container_binary}"',
            local_gate[local_gate.index(runtime_wrapper) :],
        )
        self.assertIn("trap cleanup_local_release_gate_roots EXIT", local_gate)
        self.assertIn("cleanup_local_release_gate_resources", local_gate)
        self.assertIn(
            'CONTAINER_RUNTIME_RUN_ID="${runtime_run_id}"', local_gate
        )
        self.assertIn(
            'CONTAINER_RUNTIME_SERVICE_NAMESPACE="${runtime_service_namespace}"',
            local_gate,
        )
        self.assertIn(
            '.container-compose-release-runtime-identity', local_gate
        )
        self.assertIn(
            "/private/tmp/container-compose-runtime-candidate.*",
            self.script,
        )

    def test_runtime_candidate_staging_is_read_only_reusable_and_marker_cleaned(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            container = root / "container"
            container.mkdir()
            (container / "fixture").write_text("source\n", encoding="utf-8")
            for command in (
                ["git", "init", "--quiet", str(container)],
                ["git", "-C", str(container), "config", "user.email", "test@example.com"],
                ["git", "-C", str(container), "config", "user.name", "Container Test"],
                ["git", "-C", str(container), "add", "."],
                ["git", "-C", str(container), "commit", "--quiet", "-m", "fixture"],
            ):
                subprocess.run(command, check=True, capture_output=True, text=True)

            bin_directory = root / "bin"
            bin_directory.mkdir()
            make_arguments = root / "make-arguments"
            signing_identity = "A" * 40
            fake_make = bin_directory / "make"
            fake_make.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$@\" >\"${MAKE_ARGUMENTS:?}\"\n"
                "archive=\n"
                "for argument in \"$@\"; do\n"
                "  case \"$argument\" in\n"
                "    HOMEBREW_ARCHIVE=*) archive=${argument#*=} ;;\n"
                "  esac\n"
                "done\n"
                "test -n \"$archive\"\n"
                "payload=$(mktemp -d)\n"
                "mkdir -p \"$payload/bin\" \"$payload/libexec/container\"\n"
                "printf '#!/usr/bin/env bash\\nexit 0\\n' >\"$payload/bin/container\"\n"
                "chmod +x \"$payload/bin/container\"\n"
                "tar -czf \"$archive\" -C \"$payload\" .\n"
                "(cd \"$(dirname \"$archive\")\" && "
                "shasum -a 256 \"$(basename \"$archive\")\" >\"$(basename \"$archive\").sha256\")\n"
                "find \"$payload\" -depth -delete\n",
                encoding="utf-8",
            )
            fake_make.chmod(0o755)
            evidence = root / "evidence"
            result = self.run_release_function(
                root,
                f"evidence={shlex.quote(str(evidence))}; "
                "stage_container_runtime_candidate "
                f"{shlex.quote(str(container))} {shlex.quote(str(evidence))}; "
                "test -x \"$CONTAINER_RUNTIME_CANDIDATE_ROOT/bin/container\"; "
                "test ! -w \"$CONTAINER_RUNTIME_CANDIDATE_ROOT/bin/container\"; "
                "test \"${CONTAINER_RUNTIME_CANDIDATE_ROOT#\"$evidence\"/}\" = "
                '"$CONTAINER_RUNTIME_CANDIDATE_ROOT"; '
                "candidate_root=$CONTAINER_RUNTIME_CANDIDATE_ROOT; "
                "test \"${#CONTAINER_RUNTIME_CANDIDATE_SHA256}\" -eq 64; "
                "cleanup_container_runtime_candidate; test ! -e \"$candidate_root\"",
                shell_setup=(
                    f"export PATH={shlex.quote(str(bin_directory))}:$PATH\n"
                    f"export MAKE_ARGUMENTS={shlex.quote(str(make_arguments))}\n"
                    "export CONTAINER_RUNTIME_CODESIGN_IDENTITY="
                    f"{signing_identity}"
                ),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            artifacts = list((evidence / "runtime-candidates").glob("*"))
            self.assertEqual(len(artifacts), 1)
            self.assertTrue(
                (artifacts[0] / ".container-compose-runtime-candidate-artifact").is_file()
            )
            self.assertIn(
                "CODESIGN_OPTS=--force --sign "
                f"{signing_identity} --timestamp=none",
                make_arguments.read_text(encoding="utf-8").splitlines(),
            )

    def test_runtime_candidate_staging_rejects_invalid_signing_identity(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rejected = self.run_release_function(
                root,
                "stage_container_runtime_candidate /does/not/exist evidence",
                shell_setup="export CONTAINER_RUNTIME_CODESIGN_IDENTITY=adhoc",
            )

            self.assertEqual(rejected.returncode, 2)
            self.assertIn(
                "set CONTAINER_RUNTIME_CODESIGN_IDENTITY to its 40-character fingerprint",
                rejected.stderr,
            )
            self.assertFalse((root / "evidence").exists())

    def test_runtime_candidate_staging_cleans_interrupted_build_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            container = root / "container"
            container.mkdir()
            (container / "fixture").write_text("source\n", encoding="utf-8")
            for command in (
                ["git", "init", "--quiet", str(container)],
                ["git", "-C", str(container), "config", "user.email", "test@example.com"],
                ["git", "-C", str(container), "config", "user.name", "Container Test"],
                ["git", "-C", str(container), "add", "."],
                ["git", "-C", str(container), "commit", "--quiet", "-m", "fixture"],
            ):
                subprocess.run(command, check=True, capture_output=True, text=True)

            bin_directory = root / "bin"
            bin_directory.mkdir()
            ready = root / "ready"
            fake_make = bin_directory / "make"
            fake_make.write_text(
                "#!/usr/bin/env bash\n"
                "set -u\n"
                "trap 'exit 143' TERM\n"
                'touch "${BUILD_READY:?}"\n'
                "while :; do sleep 1; done\n",
                encoding="utf-8",
            )
            fake_make.chmod(0o755)
            evidence = root / "evidence"
            shell = "\n".join(
                [
                    "set -euo pipefail",
                    "export CONTAINER_STACK_RELEASE_LIBRARY=1",
                    f"source {shlex.quote(str(SCRIPT))}",
                    f"ROOT={shlex.quote(str(root))}",
                    "EXECUTE=1",
                    f"export PATH={shlex.quote(str(bin_directory))}:$PATH",
                    f"export BUILD_READY={shlex.quote(str(ready))}",
                    f"export CONTAINER_RUNTIME_CODESIGN_IDENTITY={'B' * 40}",
                    "stage_container_runtime_candidate "
                    f"{shlex.quote(str(container))} {shlex.quote(str(evidence))}",
                ]
            )
            process = subprocess.Popen(
                ["bash", "-c", shell],
                cwd=ROOT,
                env=self.non_interactive_environment(),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            deadline = time.monotonic() + 10
            while not ready.exists() and process.poll() is None:
                if time.monotonic() >= deadline:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                    self.fail("runtime candidate package build did not start")
                time.sleep(0.05)

            os.killpg(process.pid, signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)

            self.assertEqual(process.returncode, 143, stdout + stderr)
            artifact_parent = evidence / "runtime-candidates"
            self.assertEqual(list(artifact_parent.glob(".build-*")), [])
            self.assertEqual(
                [path for path in artifact_parent.iterdir() if not path.name.startswith(".")],
                [],
            )

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
        self.assertIn("^refs/tags/homebrew-main", self.script)
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

            result = self.run_release_function(
                root / "github",
                "fetch_release_remote container-compose",
                shell="/bin/bash",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("refreshing mutable current tag", result.stdout)
            local_current = self.git(local, "rev-parse", "refs/tags/current")
            remote_current = self.run_command(
                "git", "ls-remote", "--tags", "--refs", str(remote), "refs/tags/current"
            ).stdout.split()[0]
            self.assertEqual(local_current, remote_current)

    def test_release_fetch_excludes_mutable_homebrew_main_tag(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            remote = root / "remote.git"
            local = root / "github" / "container"
            self.run_command("git", "init", "--bare", str(remote))
            local.parent.mkdir(parents=True)
            self.run_command("git", "init", "-b", "main", str(local))
            self.configure_repo(local)
            self.run_command("git", "-C", str(local), "remote", "add", "fork", str(remote))
            self.commit_file(local, "README.md", "base\n", "chore: initial runtime")
            self.run_command("git", "-C", str(local), "tag", "--no-sign", "homebrew-main")
            self.run_command(
                "git",
                "-C",
                str(local),
                "push",
                "-u",
                "fork",
                "main",
                "refs/tags/homebrew-main",
            )
            local_tag = self.git(local, "rev-parse", "refs/tags/homebrew-main")

            updater = root / "updater"
            self.run_command("git", "clone", "--branch", "main", str(remote), str(updater))
            self.configure_repo(updater)
            self.commit_file(updater, "CURRENT.md", "current\n", "chore: advance runtime")
            self.run_command("git", "-C", str(updater), "push", "origin", "main")
            self.run_command(
                "git",
                "-C",
                str(updater),
                "tag",
                "--no-sign",
                "-f",
                "homebrew-main",
            )
            self.run_command(
                "git",
                "-C",
                str(updater),
                "push",
                "origin",
                "+refs/tags/homebrew-main",
            )

            result = self.run_release_function(
                root / "github",
                "fetch_release_remote container",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.git(local, "rev-parse", "refs/tags/homebrew-main"), local_tag)
            remote_tag = self.run_command(
                "git",
                "ls-remote",
                "--tags",
                "--refs",
                str(remote),
                "refs/tags/homebrew-main",
            ).stdout.split()[0]
            self.assertNotEqual(local_tag, remote_tag)

    def test_release_helper_retains_an_unpublished_prepared_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local = self.create_compose_checkout(root)
            remote_head = self.git(local, "rev-parse", "origin/main")
            self.run_command(
                "git", "-C", str(local), "tag", "--no-sign", "current", remote_head
            )
            self.commit_file(
                local,
                "VERSION",
                "0.6.71\n",
                "chore(release): prepare 0.6.71",
            )
            candidate_head = self.git(local, "rev-parse", "main")

            result = self.run_release_function(
                root / "github",
                "recover_unpublished_release_candidate 0.6.71; "
                "ensure_current_release_source_identity",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("retaining unpublished release candidate", result.stdout)
            self.assertIn("current tag targets published parent", result.stdout)
            self.assertEqual(self.git(local, "rev-parse", "main"), candidate_head)
            self.assertNotEqual(candidate_head, remote_head)
            self.assertEqual(self.git(local, "diff", "--cached", "--name-only"), "")

    def test_release_helper_retains_an_atomic_stack_pin_candidate(self) -> None:
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
            candidate_head = self.git(local, "rev-parse", "main")

            result = self.run_release_function(
                root / "github",
                "recover_unpublished_release_candidate 0.6.71",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.git(local, "rev-parse", "main"), candidate_head)
            self.assertNotEqual(candidate_head, remote_head)
            self.assertEqual(self.git(local, "diff", "--cached", "--name-only"), "")

    def test_release_helper_retains_the_symlinked_coverage_gate_repair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local = self.create_compose_checkout(root)
            remote_head = self.git(local, "rev-parse", "origin/main")
            self.commit_file(
                local,
                "Makefile",
                "swift-coverage:\n\tfind -L .build\n",
                "fix(coverage): follow symlinked build cache",
            )
            candidate_head = self.git(local, "rev-parse", "main")

            result = self.run_release_function(
                root / "github",
                "recover_unpublished_release_candidate 0.6.71",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("retaining unpublished release candidate", result.stdout)
            self.assertEqual(self.git(local, "rev-parse", "main"), candidate_head)
            self.assertNotEqual(candidate_head, remote_head)

    def test_retained_candidate_rejects_current_from_any_commit_but_its_parent(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local = self.create_compose_checkout(root)
            remote_head = self.git(local, "rev-parse", "origin/main")
            self.commit_file(local, "STALE", "stale\n", "chore: stale current")
            self.run_command(
                "git", "-C", str(local), "tag", "--no-sign", "current"
            )
            self.run_command("git", "-C", str(local), "reset", "--hard", remote_head)
            self.commit_file(
                local,
                "VERSION",
                "0.6.71\n",
                "chore(release): prepare 0.6.71",
            )

            result = self.run_release_function(
                root / "github",
                "recover_unpublished_release_candidate 0.6.71; "
                "ensure_current_release_source_identity",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("current tag targets", result.stderr)

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
        self.assertNotIn("fetch --prune --tags --force", self.script)

    def test_equivalent_squash_promotion_aligns_local_main(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _remote, local, candidate_tree, remote_head = self.create_equivalent_squash(root)

            result = self.promote_compose_main(
                root / "github",
                shell_setup="PATH=/usr/bin:/bin",
            )

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

            result = self.promote_compose_main(
                root / "github",
                shell_setup="PATH=/usr/bin:/bin",
            )

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

    def test_compose_promotion_rejects_a_head_change_after_review_request(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.create_promotion_review_fixture(
                root,
                stale_head="b" * 40,
            )

            result = self.run_release_function(
                root,
                f"merge_compose_promotion_pr 42 {'a' * 40}",
                shell_setup=fixture["shell_setup"],
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("head changed", result.stderr)
            self.assertTrue(fixture["request_marker"].exists())
            self.assertFalse(fixture["merge_marker"].exists())

    def test_compose_promotion_surfaces_an_unanswered_query_before_request(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            query = {
                "author": {"login": "chatgpt-codex-connector"},
                "createdAt": "2026-08-01T11:00:00Z",
                "body": "Please handle this exact query.",
                "url": "https://example.invalid/query",
            }
            fixture = self.create_promotion_review_fixture(
                root,
                threads=[
                    {
                        "isResolved": False,
                        "comments": {
                            "nodes": [query],
                            "pageInfo": {"hasNextPage": False, "endCursor": None},
                        },
                    }
                ],
            )

            result = self.run_release_function(
                root,
                f"merge_compose_promotion_pr 42 {'a' * 40}",
                shell_setup=fixture["shell_setup"],
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("later owner response", result.stderr)
            self.assertIn("https://example.invalid/query", result.stderr)
            self.assertFalse(fixture["request_marker"].exists())
            self.assertFalse(fixture["merge_marker"].exists())

    def test_compose_promotion_review_timeout_never_merges(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.create_promotion_review_fixture(root)

            result = self.run_release_function(
                root,
                f"merge_compose_promotion_pr 42 {'a' * 40}",
                shell_setup="\n".join(
                    [fixture["shell_setup"], "PROMOTION_WAIT_SECONDS=0"],
                ),
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("timed out waiting for exact-head Codex review", result.stderr)
            self.assertTrue(fixture["request_marker"].exists())
            self.assertFalse(fixture["merge_marker"].exists())

    def test_compose_promotion_clean_review_merges_only_the_expected_head(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = self.create_promotion_review_fixture(
                root,
                comments=[
                    {
                        "user": {"login": "chatgpt-codex-connector[bot]"},
                        "created_at": "2026-08-01T12:00:01Z",
                        "body": (
                            "Codex Review: Didn't find any major issues.\n\n"
                            "**Reviewed commit:** `aaaaaaaaaa`"
                        ),
                        "html_url": "https://example.invalid/pr/42/clean-review",
                    }
                ],
                require_admin=True,
            )

            result = self.run_release_function(
                root,
                f"merge_compose_promotion_pr 42 {'a' * 40}",
                shell_setup=fixture["shell_setup"],
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("exact-head review passed", result.stdout)
            self.assertTrue(fixture["request_marker"].exists())
            self.assertTrue(fixture["merge_marker"].exists())
            merge_arguments = fixture["merge_arguments"].read_text(encoding="utf-8")
            self.assertIn("--match-head-commit", merge_arguments)
            self.assertIn("a" * 40, merge_arguments)
            self.assertIn("--admin", merge_arguments)
            self.assertNotIn("--auto", merge_arguments)

    def test_compose_promotion_rejects_the_retired_direct_mode(self) -> None:
        merge_policy = self.script[
            self.script.index("merge_compose_promotion_pr() {") : self.script.index(
                "# Align local main after GitHub"
            )
        ]
        promotion = self.script[
            self.script.index("promote_compose_main() {") : self.script.index(
                "push_all_main() {"
            )
        ]
        self.assertNotIn("--auto", merge_policy)
        self.assertIn("--match-head-commit", merge_policy)
        self.assertIn("body='@codex review'", self.script)
        self.assertNotIn('push "${remote}" "refs/heads/main"', promotion)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_release_function(
                root,
                "ensure_compose_promotion_mode",
                shell_setup="COMPOSE_MAIN_PROMOTION_MODE=direct",
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("direct container-compose main promotion is retired", result.stderr)

            prepare_marker = root / "prepare-called"
            result = self.run_release_function(
                root,
                "main release --+ --execute",
                shell_setup="\n".join(
                    [
                        "COMPOSE_MAIN_PROMOTION_MODE=direct",
                        f"prepare_all_main() {{ : > {shlex.quote(str(prepare_marker))}; }}",
                        "release_current_stack() { return 0; }",
                    ]
                ),
            )

            self.assertEqual(result.returncode, 2)
            self.assertFalse(prepare_marker.exists())

            release_marker = root / "release-read-called"
            result = self.run_release_function(
                root,
                "VERSION_SELECTOR=--+; release_current_stack",
                shell_setup="\n".join(
                    [
                        "COMPOSE_MAIN_PROMOTION_MODE=direct",
                        (
                            "latest_local_semver_tag() { "
                            f": > {shlex.quote(str(release_marker))}; "
                            "printf '%s\\n' 0.6.70; }"
                        ),
                    ]
                ),
            )

            self.assertEqual(result.returncode, 2)
            self.assertFalse(release_marker.exists())

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

    def create_promotion_review_fixture(
        self,
        root: Path,
        *,
        threads: list[dict[str, object]] | None = None,
        reactions: list[dict[str, object]] | None = None,
        comments: list[dict[str, object]] | None = None,
        stale_head: str = "",
        require_admin: bool = False,
    ) -> dict[str, object]:
        bin_directory = root / "bin"
        bin_directory.mkdir(parents=True)
        expected_head = "a" * 40
        request_marker = root / "review-requested"
        merge_marker = root / "merged"
        merge_arguments = root / "merge-arguments"
        threads_file = root / "threads.json"
        reactions_file = root / "reactions.json"
        comments_file = root / "comments.json"
        threads_file.write_text(
            json.dumps(
                [
                    {
                        "data": {
                            "repository": {
                                "pullRequest": {
                                    "reviewThreads": {
                                        "nodes": threads or [],
                                        "pageInfo": {
                                            "hasNextPage": False,
                                            "endCursor": None,
                                        },
                                    }
                                }
                            }
                        }
                    }
                ]
            ),
            encoding="utf-8",
        )
        reactions_file.write_text(json.dumps([reactions or []]), encoding="utf-8")
        comments_file.write_text(json.dumps([comments or []]), encoding="utf-8")

        fake_gh = bin_directory / "gh"
        fake_gh.write_text(
            """#!/usr/bin/env bash
set -euo pipefail

current_head() {
  if [[ -n "${GH_STALE_HEAD:-}" && -e "${GH_REQUEST_MARKER}" ]]; then
    printf '%s' "${GH_STALE_HEAD}"
  else
    printf '%s' "${GH_EXPECTED_HEAD}"
  fi
}

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  head="$(current_head)"
  case "$*" in
    *headRefOid,state,mergedAt,url,reviewDecision*)
      if [[ -e "${GH_MERGE_MARKER}" ]]; then
        printf '%s\tMERGED\t2026-08-01T12:05:00Z\thttps://example.invalid/pr/42\tREVIEW_REQUIRED\n' "$head"
      else
        printf '%s\tOPEN\t-\thttps://example.invalid/pr/42\tREVIEW_REQUIRED\n' "$head"
      fi
      ;;
    *headRefOid,state,mergedAt,url*)
      if [[ -e "${GH_MERGE_MARKER}" ]]; then
        printf '%s\tMERGED\t2026-08-01T12:05:00Z\thttps://example.invalid/pr/42\n' "$head"
      else
        printf '%s\tOPEN\t-\thttps://example.invalid/pr/42\n' "$head"
      fi
      ;;
    *headRefOid,mergedAt*)
      if [[ -e "${GH_MERGE_MARKER}" ]]; then
        printf '%s\t2026-08-01T12:05:00Z\n' "$head"
      else
        printf '%s\t-\n' "$head"
      fi
      ;;
    *reviewDecision*)
      printf '%s\n' REVIEW_REQUIRED
      ;;
    *)
      printf 'unexpected fake gh pr view: %s\n' "$*" >&2
      exit 64
      ;;
  esac
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "checks" ]]; then
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "merge" ]]; then
  if [[ "${GH_REQUIRE_ADMIN}" == "1" && "$*" != *"--admin"* ]]; then
    exit 1
  fi
  printf '%s\n' "$*" > "${GH_MERGE_ARGUMENTS}"
  : > "${GH_MERGE_MARKER}"
  exit 0
fi

if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  /bin/cat "${GH_THREADS_FILE}"
  exit 0
fi

if [[ "$1" == "api" ]]; then
  path=""
  for argument in "$@"; do
    if [[ "$argument" == repos/* ]]; then
      path="$argument"
    fi
  done
  if [[ "$path" == */issues/42/comments && "$*" == *"--method POST"* ]]; then
    : > "${GH_REQUEST_MARKER}"
    printf '5150000042\t2026-08-01T12:00:00Z\thttps://example.invalid/pr/42/review-request\n'
    exit 0
  fi
  if [[ "$path" == "repos/stephenlclarke/container-compose/issues/comments/5150000042/reactions?per_page=100" ]]; then
    /bin/cat "${GH_REACTIONS_FILE}"
    exit 0
  fi
  if [[ "$path" == "repos/stephenlclarke/container-compose/issues/42/comments?per_page=100" ]]; then
    /bin/cat "${GH_COMMENTS_FILE}"
    exit 0
  fi
fi

printf 'unexpected fake gh invocation: %s\n' "$*" >&2
exit 64
""",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        shell_setup = "\n".join(
            [
                f"export PATH={shlex.quote(str(bin_directory))}:$PATH",
                f"export GH_EXPECTED_HEAD={expected_head}",
                f"export GH_STALE_HEAD={shlex.quote(stale_head)}",
                f"export GH_REQUIRE_ADMIN={'1' if require_admin else '0'}",
                f"export GH_REQUEST_MARKER={shlex.quote(str(request_marker))}",
                f"export GH_MERGE_MARKER={shlex.quote(str(merge_marker))}",
                f"export GH_MERGE_ARGUMENTS={shlex.quote(str(merge_arguments))}",
                f"export GH_THREADS_FILE={shlex.quote(str(threads_file))}",
                f"export GH_REACTIONS_FILE={shlex.quote(str(reactions_file))}",
                f"export GH_COMMENTS_FILE={shlex.quote(str(comments_file))}",
                "PROMOTION_POLL_SECONDS=0",
            ]
        )
        return {
            "shell_setup": shell_setup,
            "request_marker": request_marker,
            "merge_marker": merge_marker,
            "merge_arguments": merge_arguments,
        }

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

    def promote_compose_main(
        self,
        root: Path,
        shell_setup: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return self.run_release_function(
            root,
            "promote_compose_main 0.6.70 source 'test promotion' 'test body'",
            shell_setup=shell_setup,
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
                "- name: Install Developer ID application certificate"
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
        shell: str = "bash",
    ) -> subprocess.CompletedProcess[str]:
        lines = [
            "set -euo pipefail",
            "export CONTAINER_STACK_RELEASE_LIBRARY=1",
            f"source {shlex.quote(str(SCRIPT))}",
            f"ROOT={shlex.quote(str(root))}",
            "EXECUTE=1",
            "COMPOSE_MAIN_PROMOTION_MODE=pr",
            "COMPOSE_MAIN_MERGE_MODE=checked-admin",
        ]
        if shell_setup is not None:
            lines.append(shell_setup)
        lines.append(function_call)
        command = "\n".join(lines)
        environment = self.non_interactive_environment()
        return subprocess.run(
            [shell, "-c", command],
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
