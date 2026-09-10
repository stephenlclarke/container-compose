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

"""Inspect retained and remote release recovery state without mutating it."""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


LOCAL_STORE_TOOL = Path(__file__).with_name("retain-local-release-assets.py")
SPEC = importlib.util.spec_from_file_location("retain_local_release_assets", LOCAL_STORE_TOOL)
assert SPEC is not None and SPEC.loader is not None
LOCAL_STORE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOCAL_STORE)
SEMVER = re.compile(r"[0-9]+[.][0-9]+[.][0-9]+")
REQUEST_ID = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}")
EXPECTED_ASSETS = (
    "container-compose-plugin-release-arm64.tar.gz",
    "container-compose-plugin-release-arm64.tar.gz.sha256",
    "container-release-arm64.tar.gz",
    "container-release-arm64.tar.gz.sha256",
    "container-vminit-arm64.oci.tar",
    "container-vminit-arm64.oci.tar.sha256",
    "stable-release-authority.tar.gz",
    "stable-release-authority.tar.gz.sha256",
    "release-highlights.json",
    "quality-snapshot.svg",
    "compose.tgz",
    "container.tgz",
    "containerization.tgz",
    "k8s.tgz",
)


class StateError(RuntimeError):
    """The retained release state is unsafe or malformed."""


def dispatch_records(root: Path, version: str) -> list[dict[str, Any]]:
    directory = root / "release/dispatches"
    if not directory.exists():
        return []
    if directory.is_symlink() or not directory.is_dir():
        raise StateError(f"unsafe dispatch journal directory: {directory}")
    records: list[dict[str, Any]] = []
    for path in sorted(directory.glob("*.json")):
        if path.is_symlink() or not path.is_file():
            raise StateError(f"unsafe dispatch journal record: {path}")
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise StateError(f"invalid dispatch journal record: {path}") from error
        if (
            not isinstance(value, dict)
            or value.get("schema") != 1
            or value.get("request_id") != path.stem
            or REQUEST_ID.fullmatch(path.stem) is None
            or SEMVER.fullmatch(str(value.get("version", ""))) is None
            or re.fullmatch(r"[0-9a-f]{40}", str(value.get("control_sha", "")))
            is None
            or not isinstance(value.get("workflow"), str)
            or not value["workflow"]
            or value.get("state")
            not in {"dispatch-intent", "dispatch-unknown", "dispatched"}
            or (
                value.get("state") == "dispatched"
                and re.fullmatch(r"[0-9]+", str(value.get("run_id", ""))) is None
            )
        ):
            raise StateError(f"unsupported dispatch journal record: {path}")
        if value.get("version") == version:
            records.append(value)
    return records


def retained_assets(root: Path, version: str) -> tuple[list[str], list[str]]:
    present: list[str] = []
    missing: list[str] = []
    for name in EXPECTED_ASSETS:
        try:
            LOCAL_STORE.retained_path(root, version, name)
        except (LOCAL_STORE.RetentionError, OSError, json.JSONDecodeError):
            missing.append(name)
        else:
            present.append(name)
    return present, missing


def remote_release(repo: str, version: str, offline: bool) -> dict[str, Any]:
    if offline:
        return {"state": "not-inspected"}
    try:
        completed = subprocess.run(
            ["gh", "api", f"repos/{repo}/releases/tags/{version}"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (FileNotFoundError, PermissionError, OSError):
        return {"reason": "GitHub CLI is unavailable", "state": "unavailable"}
    if completed.returncode != 0:
        if "HTTP 404" in completed.stderr:
            return {"state": "absent"}
        return {
            "reason": f"GitHub release query failed with exit {completed.returncode}",
            "state": "unavailable",
        }
    try:
        release = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return {"reason": "GitHub returned malformed JSON", "state": "unavailable"}
    if not isinstance(release, dict):
        return {"reason": "GitHub returned a non-object", "state": "unavailable"}
    assets = release.get("assets", [])
    names = sorted(
        asset["name"]
        for asset in assets
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    )
    return {
        "assets": names,
        "draft": release.get("draft"),
        "id": release.get("id"),
        "prerelease": release.get("prerelease"),
        "state": "published"
        if release.get("draft") is False and release.get("prerelease") is False
        else "invalid",
    }


def observe_dispatches(
    records: list[dict[str, Any]], repo: str, offline: bool
) -> list[dict[str, Any]]:
    observed: list[dict[str, Any]] = []
    for original in records:
        record = dict(original)
        run_id = record.get("run_id")
        if offline or record.get("state") != "dispatched" or not isinstance(
            run_id, str
        ):
            observed.append(record)
            continue
        try:
            completed = subprocess.run(
                [
                    "gh",
                    "run",
                    "view",
                    run_id,
                    "--repo",
                    repo,
                    "--json",
                    "status,conclusion,url",
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except (FileNotFoundError, PermissionError, OSError):
            record["observed"] = {
                "reason": "GitHub CLI is unavailable",
                "state": "unavailable",
            }
            observed.append(record)
            continue
        if completed.returncode != 0:
            record["observed"] = {
                "reason": f"GitHub run query failed with exit {completed.returncode}",
                "state": "unavailable",
            }
        else:
            try:
                value = json.loads(completed.stdout)
            except json.JSONDecodeError:
                value = None
            if isinstance(value, dict):
                record["observed"] = {
                    "conclusion": value.get("conclusion"),
                    "state": value.get("status"),
                    "url": value.get("url"),
                }
            else:
                record["observed"] = {
                    "reason": "GitHub returned malformed run JSON",
                    "state": "unavailable",
                }
        observed.append(record)
    return observed


def inspect(root: Path, version: str, repo: str, offline: bool) -> dict[str, Any]:
    if not root.is_absolute() or root == Path("/") or root.is_symlink():
        raise StateError(f"unsafe retained release root: {root}")
    if not SEMVER.fullmatch(version):
        raise StateError(f"invalid stable release version: {version}")
    present, missing = retained_assets(root, version)
    records = observe_dispatches(dispatch_records(root, version), repo, offline)
    remote = remote_release(repo, version, offline)
    waiting = [
        record
        for record in records
        if record.get("state") in {"dispatch-intent", "dispatch-unknown"}
        or (
            record.get("state") == "dispatched"
            and (
                not isinstance(record.get("observed"), dict)
                or record["observed"].get("state") != "completed"
            )
        )
    ]
    if any(record.get("state") == "dispatch-unknown" for record in waiting):
        next_action = "reconcile the unknown request ID; do not redispatch"
    elif waiting:
        next_action = "inspect the acknowledged workflow run before resuming"
    elif missing and remote.get("state") == "published":
        next_action = "import and verify exact published bytes; do not rebuild"
    elif missing:
        next_action = "restore exact authenticated bytes or report the release blocked"
    else:
        next_action = "verify remote formula and Pages postconditions; no build is required"
    return {
        "dispatches": records,
        "next_action": next_action,
        "remote_release": remote,
        "retained": {"missing": missing, "verified": present},
        "root": str(root),
        "schema": 1,
        "version": version,
        "waiting": waiting,
    }


def render_text(state: dict[str, Any], planning: bool) -> str:
    retained = state["retained"]
    remote = state["remote_release"]
    lines = [f"Release {state['version']}: read-only {'plan' if planning else 'status'}"]
    lines.append(f"Remote release: {remote['state']}")
    lines.append(
        f"Retained artifacts: {len(retained['verified'])}/{len(EXPECTED_ASSETS)} verified"
    )
    if retained["missing"]:
        lines.append("Missing locally: " + ", ".join(retained["missing"]))
    if state["waiting"]:
        lines.append(
            "Waiting/unknown requests: "
            + ", ".join(
                f"{record['request_id']}={record['state']}"
                for record in state["waiting"]
            )
        )
    lines.append("Next: " + state["next_action"])
    lines.append("Mutation: none (inspection is read-only)")
    return "\n".join(lines)


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "plan"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repo", default="stephenlclarke/container-compose")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--offline", action="store_true")
    options = parser.parse_args(arguments)
    try:
        state = inspect(options.root, options.version, options.repo, options.offline)
    except (StateError, OSError, UnicodeError) as error:
        print(f"release-state: {error}", file=sys.stderr)
        return 2
    if options.format == "json":
        print(json.dumps(state, sort_keys=True, indent=2))
    else:
        print(render_text(state, options.action == "plan"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
