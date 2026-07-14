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

"""Tests for scheduled stable-release eligibility decisions."""

import importlib.util
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


def load_module():
    module_path = Path(__file__).with_name("stable-release-preflight.py")
    spec = importlib.util.spec_from_file_location("stable_release_preflight", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["stable_release_preflight"] = module
    spec.loader.exec_module(module)
    return module


class StableReleasePreflightTests(unittest.TestCase):
    """The scheduler only starts a mature, changed Current build."""

    now = datetime(2026, 7, 14, 9, 17, tzinfo=timezone.utc)

    def decide(self, **overrides):
        module = load_module()
        values = {
            "main_sha": "a" * 40,
            "current_sha": "a" * 40,
            "current_built_at": self.now - timedelta(days=7),
            "latest_stable_sha": "b" * 40,
            "now": self.now,
        }
        values.update(overrides)
        return module.decide(**values)

    def test_allows_a_soaked_current_build_with_new_source(self) -> None:
        decision = self.decide()

        self.assertTrue(decision.should_release)
        self.assertEqual(decision.current_age_seconds, 604800)

    def test_rejects_current_build_that_no_longer_points_at_main(self) -> None:
        decision = self.decide(current_sha="c" * 40)

        self.assertFalse(decision.should_release)
        self.assertIn("does not point", decision.reason)

    def test_rejects_an_unsoaked_current_build(self) -> None:
        decision = self.decide(current_built_at=self.now - timedelta(days=6))

        self.assertFalse(decision.should_release)
        self.assertIn("seven-day soak", decision.reason)

    def test_rejects_source_already_released_as_stable(self) -> None:
        decision = self.decide(latest_stable_sha="a" * 40)

        self.assertFalse(decision.should_release)
        self.assertIn("no source changes", decision.reason)

    def test_rejects_a_future_current_release_timestamp(self) -> None:
        decision = self.decide(current_built_at=self.now + timedelta(seconds=1))

        self.assertFalse(decision.should_release)
        self.assertIn("future", decision.reason)


if __name__ == "__main__":
    unittest.main()
