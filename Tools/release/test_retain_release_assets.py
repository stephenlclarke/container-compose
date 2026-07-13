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

"""Unit tests for deterministic release-asset retention."""

import importlib.util
import sys
import unittest
from pathlib import Path


def load_module():
    module_path = Path(__file__).with_name("retain-release-assets.py")
    spec = importlib.util.spec_from_file_location("retain_release_assets", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["retain_release_assets"] = module
    spec.loader.exec_module(module)
    return module


class ReleaseAssetRetentionTests(unittest.TestCase):
    """Only the newest stable and newest prerelease retain packages."""

    def test_retains_one_published_release_per_lane(self) -> None:
        module = load_module()
        releases = [
            {"id": 1, "published_at": "2026-07-01T00:00:00Z", "prerelease": False, "draft": False},
            {"id": 2, "published_at": "2026-07-02T00:00:00Z", "prerelease": False, "draft": False},
            {"id": 3, "published_at": "2026-07-03T00:00:00Z", "prerelease": True, "draft": False},
            {"id": 4, "published_at": "2026-07-04T00:00:00Z", "prerelease": True, "draft": False},
            {"id": 5, "published_at": None, "prerelease": True, "draft": True},
        ]
        self.assertEqual(module.retained_release_ids(releases), {2, 4})

    def test_current_pointer_beats_newer_noncurrent_prerelease(self) -> None:
        module = load_module()
        releases = [
            {
                "id": 1,
                "tag_name": "0.6.69",
                "published_at": "2026-07-01T00:00:00Z",
                "prerelease": False,
                "draft": False,
            },
            {
                "id": 2,
                "tag_name": "current",
                "published_at": "2026-07-02T00:00:00Z",
                "prerelease": True,
                "draft": False,
            },
            {
                "id": 3,
                "tag_name": "0.6.70-rc.1",
                "published_at": "2026-07-03T00:00:00Z",
                "prerelease": True,
                "draft": False,
            },
        ]
        self.assertEqual(module.retained_release_ids(releases), {1, 2})

    def test_only_generated_current_releases_are_removed(self) -> None:
        module = load_module()
        self.assertTrue(module.obsolete_current_release({"prerelease": True, "tag_name": "current-12-abc"}))
        self.assertTrue(
            module.obsolete_current_release(
                {"prerelease": True, "tag_name": "homebrew-main-12-abc"}
            )
        )
        self.assertFalse(module.obsolete_current_release({"prerelease": True, "tag_name": "0.6.70-rc.1"}))
        self.assertFalse(module.obsolete_current_release({"prerelease": False, "tag_name": "0.6.69"}))

    def test_historical_note_uses_exact_tag_and_homebrew_bootstrap(self) -> None:
        module = load_module()
        note = module.historical_source_note(
            repo="stephenlclarke/container-compose",
            tag="0.6.67",
            bootstrap_command="brew install go node python",
            build_command="make package",
            source_guidance="BUILD.md and INSTALL.md",
            install_command="sudo install -d /usr/local/libexec/container-plugins && sudo tar -xzf container-compose-plugin-release-arm64.tar.gz -C /usr/local/libexec/container-plugins",
        )
        self.assertIn("git clone --depth 1 --branch 0.6.67", note)
        self.assertIn("brew install go node python", note)
        self.assertIn("make package", note)
        self.assertIn("sudo tar -xzf", note)
        self.assertIn(module.RETENTION_START, note)
        self.assertIn(module.RETENTION_END, note)

    def test_replacing_a_note_is_idempotent(self) -> None:
        module = load_module()
        first = module.replace_retention_note("## Summary\n", "first")
        marker_note = module.historical_source_note(
            repo="stephenlclarke/container-compose",
            tag="0.6.67",
            bootstrap_command="brew install go",
            build_command="make package",
            source_guidance="BUILD.md",
            install_command=None,
        )
        replaced = module.replace_retention_note(first, marker_note)
        again = module.replace_retention_note(replaced, marker_note)
        self.assertEqual(replaced, again)
        self.assertEqual(replaced.count(module.RETENTION_START), 1)

    def test_active_releases_show_the_correct_homebrew_lane(self) -> None:
        module = load_module()
        stable = module.active_homebrew_note(
            prerelease=False,
            install_command="brew install --formula stephenlclarke/tap/container-compose",
        )
        current = module.active_homebrew_note(
            prerelease=True,
            install_command="brew install --formula stephenlclarke/tap/container-compose-current",
        )
        self.assertIn("newest published stable release", stable)
        self.assertIn("container-compose\n", stable)
        self.assertIn("newest published current prerelease", current)
        self.assertIn("container-compose-current", current)
        self.assertIn("brew tap stephenlclarke/tap", current)

    def test_legacy_dependency_pin_highlights_are_removed(self) -> None:
        module = load_module()
        body = (
            "## Highlights\n\n"
            "- Useful user-facing change.\n"
            "- Release automation pins stephenlclarke/containerization by exact SwiftPM revision 101a0868022e.\n"
        )
        cleaned = module.remove_legacy_pin_highlights(body)
        self.assertIn("Useful user-facing change", cleaned)
        self.assertNotIn("Release automation pins", cleaned)


if __name__ == "__main__":
    unittest.main()
