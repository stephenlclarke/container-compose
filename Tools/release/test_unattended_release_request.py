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

"""Tests for the unattended stable-release request policy."""

import importlib.util
import sys
import unittest
from pathlib import Path


def load_module():
    module_path = Path(__file__).with_name("unattended-release-request.py")
    spec = importlib.util.spec_from_file_location(
        "unattended_release_request", module_path
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["unattended_release_request"] = module
    spec.loader.exec_module(module)
    return module


class UnattendedReleaseRequestTests(unittest.TestCase):
    """Only complete, noninteractive requests reach the release runner."""

    def validate(self, **overrides):
        module = load_module()
        values = {
            "event_name": "workflow_dispatch",
            "intent": "milestone",
            "selector": "auto",
            "reason": "",
            "soak_override_reason": "",
        }
        values.update(overrides)
        return module.validate_request(**values)

    def test_scheduled_release_accepts_only_automatic_milestone(self) -> None:
        request = self.validate(event_name="schedule")

        self.assertEqual(request.intent, "milestone")
        self.assertEqual(request.selector, "auto")

    def test_manual_milestone_accepts_exact_version_and_soak_override(self) -> None:
        request = self.validate(
            selector="1.2.3", soak_override_reason="authorised baseline"
        )

        self.assertEqual(request.selector, "1.2.3")
        self.assertEqual(request.soak_override_reason, "authorised baseline")

    def test_maintenance_maps_reason_to_controller_variable(self) -> None:
        request = self.validate(
            intent="maintenance", selector="--+", reason="repair release controller"
        )

        self.assertEqual(request.maintenance_reason, "repair release controller")
        self.assertEqual(request.security_reason, "")

    def test_maintenance_exact_version_only_resumes_an_existing_release(self) -> None:
        with self.assertRaisesRegex(ValueError, "patch selector"):
            self.validate(intent="maintenance", selector="1.2.3", reason="repair")

        request = self.validate(
            intent="maintenance",
            selector="1.2.3",
            reason="repair",
            existing_release=True,
        )

        self.assertEqual(request.selector, "1.2.3")

    def test_new_maintenance_rejects_nonpatch_bump_selectors(self) -> None:
        for selector in ("-+-", "+--"):
            with self.subTest(selector=selector), self.assertRaisesRegex(
                ValueError, "patch selector"
            ):
                self.validate(intent="maintenance", selector=selector, reason="repair")

    def test_security_maps_reason_to_controller_variable(self) -> None:
        request = self.validate(
            intent="security", selector="2.0.1", reason="CVE-2026-12345"
        )

        self.assertEqual(request.security_reason, "CVE-2026-12345")
        self.assertEqual(request.maintenance_reason, "")

    def test_rejects_unsupported_event_intent_and_selector(self) -> None:
        for override in (
            {"event_name": "push"},
            {"intent": "emergency"},
            {"selector": "latest"},
            {"selector": "1.2"},
        ):
            with self.subTest(override=override), self.assertRaises(ValueError):
                self.validate(**override)

    def test_rejects_nonautomatic_scheduled_request(self) -> None:
        with self.assertRaisesRegex(ValueError, "automatic milestone"):
            self.validate(event_name="schedule", selector="--+")

    def test_rejects_automatic_maintenance_or_security(self) -> None:
        for intent in ("maintenance", "security"):
            with self.subTest(intent=intent), self.assertRaisesRegex(
                ValueError, "explicit version selector"
            ):
                self.validate(intent=intent, reason="required")

    def test_rejects_missing_maintenance_or_security_reason(self) -> None:
        for intent in ("maintenance", "security"):
            with self.subTest(intent=intent), self.assertRaisesRegex(
                ValueError, "require a reason"
            ):
                self.validate(intent=intent, selector="--+")

    def test_rejects_whitespace_only_operational_reasons(self) -> None:
        for reason in (" ", "   "):
            with self.subTest(reason=repr(reason)), self.assertRaisesRegex(
                ValueError, "require a reason"
            ):
                self.validate(intent="maintenance", selector="--+", reason=reason)
        request = self.validate(
            selector="1.2.3", soak_override_reason="  authorised baseline  "
        )
        self.assertEqual(request.soak_override_reason, "authorised baseline")

    def test_rejects_reason_output_injection(self) -> None:
        for reason in ("a\nb", "a\x7fb", "a\u2028b"):
            with self.subTest(reason=repr(reason)), self.assertRaisesRegex(
                ValueError, "one printable line"
            ):
                self.validate(intent="maintenance", selector="--+", reason=reason)

    def test_rejects_unbounded_reason(self) -> None:
        with self.assertRaisesRegex(ValueError, "no longer than 512"):
            self.validate(intent="maintenance", selector="--+", reason="a" * 513)

    def test_rejects_reason_in_the_wrong_policy_field(self) -> None:
        with self.assertRaisesRegex(ValueError, "soak override field"):
            self.validate(reason="wrong field")
        with self.assertRaisesRegex(ValueError, "only milestone"):
            self.validate(
                intent="maintenance",
                selector="--+",
                reason="repair",
                soak_override_reason="wrong field",
            )


if __name__ == "__main__":
    unittest.main()
