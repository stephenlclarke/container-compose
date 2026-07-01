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

"""Unit tests for release asset pruning decisions."""

import importlib.util
import sys
import unittest
from pathlib import Path


def load_module():
    module_path = Path(__file__).with_name("prune-release-assets.py")
    spec = importlib.util.spec_from_file_location("prune_release_assets", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["prune_release_assets"] = module
    spec.loader.exec_module(module)
    return module


class ReleaseAssetPruningTests(unittest.TestCase):
    """Only one pre-release and one stable release should retain assets."""

    def test_prunes_older_prerelease_assets_when_current_is_prerelease(self) -> None:
        module = load_module()
        releases = [
            self.release(module, "homebrew-main", prerelease=True, published_at="2026-07-01T10:00:00Z"),
            self.release(module, "0.5.1-pre", prerelease=True, published_at="2026-06-30T10:00:00Z"),
            self.release(module, "0.5.0", prerelease=False, published_at="2026-06-29T10:00:00Z"),
        ]

        self.assertEqual(
            [release.tag_name for release in module.releases_to_prune(releases, "homebrew-main")],
            ["0.5.1-pre"],
        )

    def test_prunes_older_stable_assets_when_current_is_stable(self) -> None:
        module = load_module()
        releases = [
            self.release(module, "0.6.0", prerelease=False, published_at="2026-07-01T10:00:00Z"),
            self.release(module, "homebrew-main", prerelease=True, published_at="2026-06-30T10:00:00Z"),
            self.release(module, "0.5.0", prerelease=False, published_at="2026-06-29T10:00:00Z"),
        ]

        self.assertEqual(
            [release.tag_name for release in module.releases_to_prune(releases, "0.6.0")],
            ["0.5.0"],
        )

    def test_pruned_notes_include_source_build_formula_once(self) -> None:
        module = load_module()
        release = self.release(module, "0.5.0", prerelease=False)

        body = module.body_with_source_install(
            "## Summary\n\nOld notes.\n",
            release,
            prebuilt_sha256="a" * 64,
        )
        repeated = module.body_with_source_install(
            body,
            release,
            prebuilt_sha256="a" * 64,
        )

        self.assertEqual(body, repeated)
        self.assertIn("## Source Install From This Release", body)
        self.assertIn("Original pruned prebuilt asset SHA-256", body)
        self.assertIn("a" * 64, body)
        self.assertIn('url "https://github.com/stephenlclarke/container-compose.git"', body)
        self.assertIn('tag: "0.5.0"', body)
        self.assertIn('revision: "abcdef1234567890"', body)
        self.assertIn('PLUGIN_ARCHIVE=#{archive}', body)
        self.assertIn('Local rebuild SHA-256 #{rebuilt_sha256}', body)
        self.assertIn('brew install --build-from-source "${FORMULA}"', body)

    def release(
        self,
        module,
        tag_name: str,
        *,
        prerelease: bool,
        published_at: str = "2026-07-01T10:00:00Z",
    ):
        return module.Release(
            tag_name=tag_name,
            name=tag_name,
            prerelease=prerelease,
            draft=False,
            published_at=published_at,
            target_commitish="abcdef1234567890",
            assets=(
                {"id": 1, "name": f"{tag_name}.tar.gz"},
                {"id": 2, "name": f"{tag_name}.tar.gz.sha256"},
            ),
            body="## Summary\n",
        )


if __name__ == "__main__":
    unittest.main()
