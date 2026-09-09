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

"""Policy tests for the simple, recoverable Container-family build."""

from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = (REPOSITORY_ROOT / "Makefile").read_text(encoding="utf-8")
STABLE_RELEASE_WORKFLOW = (
    REPOSITORY_ROOT / ".github/workflows/stable-release-gate.yml"
).read_text(encoding="utf-8")
CI_WORKFLOW = (REPOSITORY_ROOT / ".github/workflows/ci.yml").read_text(
    encoding="utf-8"
)


def make_target(name: str, next_name: str) -> str:
    return MAKEFILE.split(f"\n{name}:", 1)[1].split(f"\n{next_name}:", 1)[0]


class RecoverableStackBuildPolicyTests(unittest.TestCase):
    def test_default_make_is_only_the_native_compose_build(self) -> None:
        self.assertIn("\nall: build go-build\n", MAKEFILE)
        default = make_target("all", "workflow")
        for forbidden in ("codeql", "docs", "package", "release", "codesign"):
            self.assertNotIn(forbidden, default.lower())

    def test_stack_graph_has_explicit_parallel_and_dependency_boundaries(self) -> None:
        self.assertIn("stack-build-locked:", MAKEFILE)
        self.assertIn(
            "stack-container-build: stack-containerization-build stack-engine-api-build",
            MAKEFILE,
        )
        self.assertIn("stack-compose-build: stack-container-build", MAKEFILE)
        invocation = make_target("stack-build", "stack-build-locked")
        self.assertIn("/usr/bin/lockf -t 0", invocation)
        self.assertIn("stack-build-locked STACK_LOCK_HELD=1", invocation)

    def test_global_lock_covers_final_bundle_publication(self) -> None:
        locked = make_target("stack-build-locked", "stack-containerization-build")
        self.assertIn("-j3 stack-builder-build stack-compose-build", locked)
        self.assertIn("requires the stack-build lock", locked)
        self.assertIn('"$(STACK_PIN_TOOL)" bundle', locked)
        self.assertIn('"$(STACK_PIN_TOOL)" verify-bundle', locked)

    def test_individual_stack_stages_reject_unlocked_execution(self) -> None:
        self.assertEqual(MAKEFILE.count("\n\t$(STACK_REQUIRE_LOCK)\n"), 5)
        self.assertIn("stack stage requires the stack-build lock", MAKEFILE)

    def test_every_source_build_publishes_a_verified_atomic_pin(self) -> None:
        for current, following, repository in (
            ("stack-containerization-build", "stack-engine-api-build", "containerization"),
            ("stack-engine-api-build", "stack-container-build", "container-engine-api"),
            ("stack-container-build", "stack-builder-build", "container"),
            ("stack-builder-build", "stack-compose-build", "container-builder-shim"),
            ("stack-compose-build", "all", "container-compose"),
        ):
            with self.subTest(repository=repository):
                target = make_target(current, following)
                self.assertIn('"$(STACK_PIN_TOOL)" verify --quiet', target)
                self.assertIn('"$(STACK_PIN_TOOL)" create', target)
                self.assertIn(f"--repository {repository}", target)
                self.assertIn("--expected-commit", target)
                self.assertIn("--expected-tree", target)
                self.assertLess(target.index(" build"), target.index(" create "))

    def test_downstream_stages_consume_upstream_pin_values(self) -> None:
        container = make_target("stack-container-build", "stack-builder-build")
        self.assertIn('--dependency "$(STACK_CONTAINERIZATION_PIN)"', container)
        self.assertIn('--dependency "$(STACK_ENGINE_API_PIN)"', container)
        compose = make_target("stack-compose-build", "all")
        for pin in (
            "STACK_CONTAINERIZATION_PIN",
            "STACK_ENGINE_API_PIN",
            "STACK_CONTAINER_PIN",
        ):
            self.assertIn(f'value --receipt "$({pin})"', compose)
            self.assertIn(f'--dependency "$({pin})"', compose)

    def test_recovery_state_is_durable_and_has_a_safe_local_fallback(self) -> None:
        self.assertIn("/Volumes/SSD/github/.container-compose-build", MAKEFILE)
        self.assertIn("$(abspath .build/stack)", MAKEFILE)
        state_init = make_target("stack-state-init", "stack-preflight")
        self.assertIn("STACK_STATE_ROOT must be absolute", state_init)
        self.assertIn("must not be a symbolic link", state_init)
        self.assertIn(".container-compose-build-root", state_init)
        self.assertIn("/bin/mv", state_init)

    def test_unattended_make_never_discovers_a_keychain_identity(self) -> None:
        self.assertIn("CONTAINER_RUNTIME_CODESIGN_IDENTITY ?=\n", MAKEFILE)
        self.assertNotIn("security find-identity", MAKEFILE)

    def test_stack_build_excludes_release_only_work(self) -> None:
        stack = MAKEFILE.split("\nstack-build:", 1)[1].split("\nall:", 1)[0]
        for forbidden in (
            "codeql",
            "docc",
            "documentation",
            "notar",
            "codesign",
            "vhs",
            "parity",
        ):
            self.assertNotIn(forbidden, stack.lower())

    def test_ci_tools_lane_runs_recovery_regressions_once(self) -> None:
        ci_tools = make_target("ci-tools-test", "coverage-tools-test")
        self.assertIn(
            "$(MAKE) --no-print-directory stack-self-test",
            ci_tools,
        )
        self.assertEqual(MAKEFILE.count("stack-self-test\n"), 1)

    def test_runtime_validation_uses_pinned_managed_macos_toolchain(self) -> None:
        runtime_validation = CI_WORKFLOW.split("  validate_runtime:", 1)[1].split(
            "  prebuilt_binaries:", 1
        )[0]
        self.assertIn("runs-on: macos-26", runtime_validation)
        self.assertIn(
            "DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer",
            runtime_validation,
        )
        self.assertNotIn("self-hosted", runtime_validation)

    def test_stable_gate_uses_candidate_keyed_checkpoint_state(self) -> None:
        self.assertIn("RELEASE_BUILD_STATE_ROOT", STABLE_RELEASE_WORKFLOW)
        self.assertIn(
            'state_root="${state_parent}/${CANDIDATE_SHA}"',
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertIn(
            "CONTAINER_STACK_VALIDATION_CHECKPOINT_DIR", STABLE_RELEASE_WORKFLOW
        )
        self.assertIn(
            "make -C release-tools release-gate-hosted", STABLE_RELEASE_WORKFLOW
        )
        self.assertIn(
            'HAWKEYE="${GITHUB_WORKSPACE}/container-compose/.local/bin/hawkeye"',
            STABLE_RELEASE_WORKFLOW,
        )
        self.assertNotIn("nextflow", STABLE_RELEASE_WORKFLOW.lower())


if __name__ == "__main__":
    unittest.main()
