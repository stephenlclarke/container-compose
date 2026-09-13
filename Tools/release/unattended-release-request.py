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

"""Validate one non-interactive stable-release request."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import asdict, dataclass


SEMANTIC_VERSION = re.compile(r"[0-9]+[.][0-9]+[.][0-9]+")
SELECTORS = {"auto", "--+", "-+-", "+--"}
INTENTS = {"milestone", "maintenance", "security"}
EVENTS = {"schedule", "workflow_dispatch"}


@dataclass(frozen=True)
class UnattendedReleaseRequest:
    """Sanitized values exported to the release controller."""

    event_name: str
    intent: str
    selector: str
    maintenance_reason: str
    security_reason: str
    soak_override_reason: str


def _require_printable_line(name: str, value: str) -> None:
    """Reject GitHub-output injection and prompt-shaped multiline input."""

    if len(value) > 512:
        raise ValueError(f"{name} must be no longer than 512 characters")
    if not value.isprintable():
        raise ValueError(f"{name} must be one printable line")


def validate_request(
    *,
    event_name: str,
    intent: str,
    selector: str,
    reason: str,
    soak_override_reason: str,
    existing_release: bool = False,
) -> UnattendedReleaseRequest:
    """Validate policy before allocating the Apple-silicon release runner."""

    if event_name not in EVENTS:
        raise ValueError(f"unsupported release event: {event_name}")
    if intent not in INTENTS:
        raise ValueError(f"unsupported release intent: {intent}")
    if selector not in SELECTORS and not SEMANTIC_VERSION.fullmatch(selector):
        raise ValueError(f"unsupported release selector: {selector}")
    _require_printable_line("reason", reason)
    _require_printable_line("soak override", soak_override_reason)
    reason = reason.strip()
    soak_override_reason = soak_override_reason.strip()

    if event_name == "schedule" and (
        intent != "milestone"
        or selector != "auto"
        or reason
        or soak_override_reason
    ):
        raise ValueError("scheduled releases must use the automatic milestone policy")
    if intent != "milestone" and selector == "auto":
        raise ValueError(f"{intent} releases require an explicit version selector")
    if intent == "maintenance" and selector != "--+" and not (
        existing_release and SEMANTIC_VERSION.fullmatch(selector)
    ):
        raise ValueError(
            "new maintenance releases require the --+ patch selector; "
            "an exact version may only resume an existing release"
        )
    if intent in {"maintenance", "security"} and not reason:
        raise ValueError(f"{intent} releases require a reason")
    if intent != "milestone" and soak_override_reason:
        raise ValueError("only milestone releases may carry a soak override")
    if intent == "milestone" and reason:
        raise ValueError("milestone releases use the soak override field, not reason")

    return UnattendedReleaseRequest(
        event_name=event_name,
        intent=intent,
        selector=selector,
        maintenance_reason=reason if intent == "maintenance" else "",
        security_reason=reason if intent == "security" else "",
        soak_override_reason=soak_override_reason,
    )


def parse_arguments() -> argparse.Namespace:
    """Parse workflow-provided request values without reading a terminal."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--intent", required=True)
    parser.add_argument("--selector", required=True)
    parser.add_argument("--reason", default="")
    parser.add_argument("--soak-override-reason", default="")
    parser.add_argument("--existing-release", action="store_true")
    return parser.parse_args()


def main() -> None:
    """Write one sanitized JSON request for the workflow shell."""

    arguments = parse_arguments()
    try:
        request = validate_request(
            event_name=arguments.event_name,
            intent=arguments.intent,
            selector=arguments.selector,
            reason=arguments.reason,
            soak_override_reason=arguments.soak_override_reason,
            existing_release=arguments.existing_release,
        )
    except ValueError as error:
        raise SystemExit(f"invalid unattended release request: {error}") from error
    print(json.dumps(asdict(request), sort_keys=True))


if __name__ == "__main__":
    main()
