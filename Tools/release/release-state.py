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
import base64
import importlib.util
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


LOCAL_STORE_TOOL = Path(__file__).with_name("retain-local-release-assets.py")
SPEC = importlib.util.spec_from_file_location("retain_local_release_assets", LOCAL_STORE_TOOL)
assert SPEC is not None and SPEC.loader is not None
LOCAL_STORE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOCAL_STORE)
FORMULA_TOOL = Path(__file__).with_name("verify-homebrew-formula-pair.py")
FORMULA_SPEC = importlib.util.spec_from_file_location(
    "verify_homebrew_formula_pair", FORMULA_TOOL
)
assert FORMULA_SPEC is not None and FORMULA_SPEC.loader is not None
FORMULA = importlib.util.module_from_spec(FORMULA_SPEC)
FORMULA_SPEC.loader.exec_module(FORMULA)
SEMVER = re.compile(r"[0-9]+[.][0-9]+[.][0-9]+")
REQUEST_ID = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}")
EXPECTED_DRAFT_ASSETS = (
    "container-compose-plugin-release-arm64.tar.gz",
    "container-compose-plugin-release-arm64.tar.gz.sha256",
    "container-release-arm64.tar.gz",
    "container-release-arm64.tar.gz.sha256",
    "stable-release-authority.tar.gz",
    "stable-release-authority.tar.gz.sha256",
    "release-highlights.json",
    "quality-snapshot.svg",
)
EXPECTED_RELEASE_ASSETS = EXPECTED_DRAFT_ASSETS[:4] + (
    "container-vminit-arm64.oci.tar",
    "container-vminit-arm64.oci.tar.sha256",
) + EXPECTED_DRAFT_ASSETS[4:]
EXPECTED_DOCUMENTATION_ASSETS = (
    "compose.tgz",
    "container.tgz",
    "containerization.tgz",
    "k8s.tgz",
)
EXPECTED_RETAINED_ASSETS = EXPECTED_RELEASE_ASSETS + EXPECTED_DOCUMENTATION_ASSETS
UNREAD_MANIFEST = object()


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
            or value.get("schema") not in {1, 2}
            or value.get("request_id") != path.stem
            or REQUEST_ID.fullmatch(path.stem) is None
            or SEMVER.fullmatch(str(value.get("version", ""))) is None
            or re.fullmatch(r"[0-9a-f]{40}", str(value.get("control_sha", "")))
            is None
            or (
                "previous_request_id" in value
                and REQUEST_ID.fullmatch(str(value["previous_request_id"])) is None
            )
            or not isinstance(value.get("workflow"), str)
            or not value["workflow"]
            or value.get("state")
            not in {"dispatch-intent", "dispatch-unknown", "dispatched", "failed"}
            or (
                value.get("state") in {"dispatched", "failed"}
                and re.fullmatch(r"[0-9]+", str(value.get("run_id", ""))) is None
            )
        ):
            raise StateError(f"unsupported dispatch journal record: {path}")
        if value.get("version") == version:
            records.append(value)
    return records


def retained_assets(
    root: Path,
    version: str,
    deep: bool = False,
    manifest: dict[str, Any] | None | object = UNREAD_MANIFEST,
) -> tuple[list[str], list[str]]:
    present: list[str] = []
    missing: list[str] = []
    if manifest is UNREAD_MANIFEST:
        manifest = load_retained_manifest(root, version)
    if not isinstance(manifest, dict):
        return present, list(EXPECTED_RETAINED_ASSETS)
    for name in EXPECTED_RETAINED_ASSETS:
        try:
            record = manifest["assets"].get(name)
            if not isinstance(record, dict) or not isinstance(record.get("path"), str):
                raise LOCAL_STORE.RetentionError("missing asset record")
            path = Path(record["path"])
            artifact_root = (root / "release/artifacts").resolve(strict=True)
            if (
                not path.is_absolute()
                or artifact_root not in path.resolve(strict=False).parents
                or path.is_symlink()
                or not path.is_file()
                or path.stat().st_size != record.get("size")
                or (deep and LOCAL_STORE.sha256(path) != record.get("sha256"))
            ):
                raise LOCAL_STORE.RetentionError("invalid asset record")
        except (LOCAL_STORE.RetentionError, OSError, json.JSONDecodeError):
            missing.append(name)
        else:
            present.append(name)
    return present, missing


def load_retained_manifest(root: Path, version: str) -> dict[str, Any] | None:
    """Load and validate the retained manifest exactly once per inspection."""
    try:
        return LOCAL_STORE.read_manifest(LOCAL_STORE.manifest_path(root, version))
    except (LOCAL_STORE.RetentionError, OSError, json.JSONDecodeError):
        return None


def formula_expectations(
    manifest: dict[str, Any] | None, version: str, repo: str
) -> dict[str, str] | None:
    """Return formula inputs rooted in the retained release manifest."""
    if manifest is None:
        return None
    names = {
        "compose": "container-compose-plugin-release-arm64.tar.gz",
        "runtime": "container-release-arm64.tar.gz",
    }
    values: dict[str, str] = {}
    for label, name in names.items():
        record = manifest["assets"].get(name)
        if (
            not isinstance(record, dict)
            or re.fullmatch(r"[0-9a-f]{64}", str(record.get("sha256", ""))) is None
        ):
            return None
        values[f"{label}_sha256"] = record["sha256"]
        values[f"{label}_url"] = (
            f"https://github.com/{repo}/releases/"
            f"download/{version}/{name}"
        )
    return values


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
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        return {"reason": "GitHub release query timed out", "state": "unavailable"}
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
    if not isinstance(assets, list):
        return {"reason": "GitHub returned malformed release assets", "state": "unavailable"}
    if not all(
        isinstance(asset, dict)
        and isinstance(asset.get("name"), str)
        and bool(asset["name"])
        for asset in assets
    ):
        return {"reason": "GitHub returned malformed release assets", "state": "unavailable"}
    names = sorted(
        asset["name"]
        for asset in assets
    )
    if release.get("draft") is False and release.get("prerelease") is False:
        release_state = "published"
    elif release.get("draft") is True:
        release_state = "draft"
    else:
        release_state = "invalid"
    result = {
        "assets": names,
        "asset_digests": {
            asset["name"]: asset.get("digest")
            for asset in assets
            if isinstance(asset, dict)
            and isinstance(asset.get("name"), str)
            and isinstance(asset.get("digest"), str)
        },
        "draft": release.get("draft"),
        "id": release.get("id"),
        "prerelease": release.get("prerelease"),
        "state": release_state,
    }
    expected = (
        EXPECTED_DRAFT_ASSETS if release_state == "draft" else EXPECTED_RELEASE_ASSETS
    )
    result["missing_assets"] = sorted(set(expected) - set(names))
    return result


def reconcile_remote_digests(
    remote: dict[str, Any], manifest: dict[str, Any] | None
) -> dict[str, Any]:
    """Bind API-provided remote asset digests to the retained manifest."""
    result = dict(remote)
    if remote.get("state") not in {"draft", "published"} or manifest is None:
        return result
    names = remote.get("assets")
    if not isinstance(names, list) or not all(
        isinstance(name, str) and name for name in names
    ):
        result.update(
            reason="remote release asset inventory is malformed",
            state="unavailable",
        )
        return result
    duplicates = sorted({name for name in names if names.count(name) > 1})
    expected = (
        EXPECTED_DRAFT_ASSETS
        if remote.get("state") == "draft"
        else EXPECTED_RELEASE_ASSETS
    )
    unexpected = sorted(set(names) - set(expected))
    result["duplicate_assets"] = duplicates
    result["unexpected_assets"] = unexpected
    if duplicates or unexpected:
        result.update(
            reason="remote release asset inventory conflicts with retained closure",
            state="conflicting",
        )
        return result
    observed = remote.get("asset_digests")
    if not isinstance(observed, dict):
        result.update(
            reason="remote release digest inventory is malformed",
            state="unavailable",
        )
        return result
    conflicts: dict[str, dict[str, str]] = {}
    unavailable: list[str] = []
    for name in names:
        record = manifest["assets"].get(name)
        if not isinstance(record, dict) or not isinstance(record.get("sha256"), str):
            unavailable.append(name)
            continue
        digest = observed.get(name)
        if digest is None:
            unavailable.append(name)
        elif digest != f"sha256:{record['sha256']}":
            conflicts[name] = {
                "expected": f"sha256:{record['sha256']}",
                "observed": str(digest),
            }
    result["digest_conflicts"] = conflicts
    result["unverified_digests"] = unavailable
    if conflicts:
        result.update(
            reason="remote release asset digests conflict with retained bytes",
            state="conflicting",
        )
    elif unavailable:
        result.update(
            reason="remote release asset digests are unavailable",
            state="unavailable",
        )
    return result


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
                timeout=30,
            )
        except subprocess.TimeoutExpired:
            record["observed"] = {
                "reason": "GitHub run query timed out",
                "state": "unavailable",
            }
            observed.append(record)
            continue
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


def remote_postconditions(
    repo: str,
    version: str,
    offline: bool,
    expected_formulae: dict[str, str] | None,
) -> dict[str, Any]:
    if offline:
        return {
            "formulae": {"state": "not-inspected"},
            "pages": {"state": "not-inspected"},
        }
    try:
        latest_result = subprocess.run(
            ["gh", "api", f"repos/{repo}/releases/latest"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError, OSError):
        unavailable = {
            "reason": "latest stable release observation unavailable",
            "state": "unavailable",
        }
        return {"formulae": dict(unavailable), "pages": dict(unavailable)}
    try:
        latest = json.loads(latest_result.stdout) if latest_result.returncode == 0 else None
    except json.JSONDecodeError:
        latest = None
    if not isinstance(latest, dict) or not isinstance(latest.get("tag_name"), str):
        unavailable = {
            "reason": f"latest stable release query failed with exit {latest_result.returncode}",
            "state": "unavailable",
        }
        return {"formulae": dict(unavailable), "pages": dict(unavailable)}
    latest_version = latest["tag_name"]
    if latest_version != version:
        superseded = {"latest_version": latest_version, "state": "superseded"}
        return {"formulae": dict(superseded), "pages": dict(superseded)}
    observations: dict[str, Any] = {}
    if expected_formulae is None:
        formulae: dict[str, Any] = {
            "reason": "retained archive identities are unavailable",
            "state": "unavailable",
        }
    else:
        formulae = {"members": {}}
    for name in ("container.rb", "container-compose.rb"):
        if expected_formulae is None:
            break
        try:
            result = subprocess.run(
                ["gh", "api", f"repos/stephenlclarke/homebrew-tap/contents/Formula/{name}"],
                check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, timeout=30,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError, OSError):
            formulae = {
                "reason": "Homebrew formula observation unavailable",
                "state": "unavailable",
            }
            break
        if result.returncode != 0:
            formulae = {
                "reason": f"Homebrew formula query failed with exit {result.returncode}",
                "state": "absent" if "HTTP 404" in result.stderr else "unavailable",
            }
            break
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError:
            value = None
        if (
            not isinstance(value, dict)
            or not isinstance(value.get("sha"), str)
            or value.get("encoding") != "base64"
            or not isinstance(value.get("content"), str)
        ):
            formulae = {
                "reason": "GitHub returned malformed formula metadata",
                "state": "unavailable",
            }
            break
        try:
            encoded = re.sub(r"\s+", "", value["content"])
            body = base64.b64decode(encoded, validate=True).decode("utf-8")
        except (ValueError, UnicodeError):
            formulae = {
                "reason": "GitHub returned malformed formula content",
                "state": "unavailable",
            }
            break
        formulae["members"][name] = {"blob_sha": value["sha"], "body": body}
    else:
        try:
            FORMULA.verify_texts(
                formulae["members"]["container-compose.rb"].pop("body"),
                formulae["members"]["container.rb"].pop("body"),
                expected_formulae["compose_url"],
                expected_formulae["runtime_url"],
                expected_formulae["compose_sha256"],
                expected_formulae["runtime_sha256"],
            )
        except FORMULA.FormulaError as error:
            formulae = {"reason": str(error), "state": "conflict"}
        else:
            formulae["state"] = "verified"
    observations["formulae"] = formulae
    try:
        result = subprocess.run(
            ["gh", "api", f"repos/{repo}/pages"], check=False,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError, OSError):
        observations["pages"] = {
            "reason": "Pages observation unavailable",
            "state": "unavailable",
        }
    else:
        try:
            value = json.loads(result.stdout) if result.returncode == 0 else None
        except json.JSONDecodeError:
            value = None
        if not isinstance(value, dict):
            observations["pages"] = {
                "reason": f"Pages query failed with exit {result.returncode}",
                "state": "absent" if "HTTP 404" in result.stderr else "unavailable",
            }
        else:
            pages: dict[str, Any] = {
                "build_type": value.get("build_type"),
                "html_url": value.get("html_url"),
                "status": value.get("status"),
            }
            try:
                runs_result = subprocess.run(
                    [
                        "gh",
                        "api",
                        f"repos/{repo}/actions/workflows/docs.yml/runs"
                        "?event=workflow_dispatch&per_page=100",
                    ],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=30,
                )
                deployments_result = subprocess.run(
                    [
                        "gh",
                        "api",
                        f"repos/{repo}/deployments"
                        "?environment=github-pages&per_page=100",
                    ],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=30,
                )
            except (
                subprocess.TimeoutExpired,
                FileNotFoundError,
                PermissionError,
                OSError,
            ):
                pages.update(
                    reason="documentation deployment observation unavailable",
                    state="unavailable",
                )
            else:
                try:
                    runs_value = (
                        json.loads(runs_result.stdout)
                        if runs_result.returncode == 0
                        else None
                    )
                    deployments = (
                        json.loads(deployments_result.stdout)
                        if deployments_result.returncode == 0
                        else None
                    )
                except json.JSONDecodeError:
                    runs_value = deployments = None
                runs = runs_value.get("workflow_runs") if isinstance(runs_value, dict) else None
                prefix = f"Documentation · {version} · "
                matches = [
                    run
                    for run in runs or []
                    if isinstance(run, dict)
                    and isinstance(run.get("display_title"), str)
                    and run["display_title"].startswith(prefix)
                    and run.get("status") == "completed"
                    and run.get("conclusion") == "success"
                    and isinstance(run.get("head_sha"), str)
                ]
                if not isinstance(runs, list) or not isinstance(deployments, list):
                    pages.update(
                        reason="GitHub returned malformed documentation deployment data",
                        state="unavailable",
                    )
                elif not matches:
                    pages.update(
                        reason="no successful exact-version Documentation run exists",
                        state="absent",
                    )
                elif not deployments or not isinstance(deployments[0], dict):
                    pages.update(reason="no active github-pages deployment exists", state="absent")
                elif deployments[0].get("sha") != matches[0]["head_sha"]:
                    pages.update(
                        reason=(
                            "active Pages deployment does not match the "
                            "exact-version Documentation run"
                        ),
                        state="conflict",
                    )
                elif value.get("status") != "built":
                    pages.update(reason="GitHub Pages is not built", state="conflict")
                elif not isinstance(deployments[0].get("id"), (int, str)):
                    pages.update(
                        reason="active Pages deployment has no identity",
                        state="unavailable",
                    )
                else:
                    deployment_id = deployments[0]["id"]
                    try:
                        status_result = subprocess.run(
                            [
                                "gh",
                                "api",
                                f"repos/{repo}/deployments/{deployment_id}/statuses"
                                "?per_page=1",
                            ],
                            check=False,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            text=True,
                            timeout=30,
                        )
                    except (
                        subprocess.TimeoutExpired,
                        FileNotFoundError,
                        PermissionError,
                        OSError,
                    ):
                        pages.update(
                            reason="Pages deployment status observation unavailable",
                            state="unavailable",
                        )
                    else:
                        try:
                            statuses = (
                                json.loads(status_result.stdout)
                                if status_result.returncode == 0
                                else None
                            )
                        except json.JSONDecodeError:
                            statuses = None
                        if not isinstance(statuses, list) or not statuses:
                            pages.update(
                                reason="Pages deployment status is unavailable",
                                state="unavailable",
                            )
                        elif (
                            not isinstance(statuses[0], dict)
                            or statuses[0].get("state") != "success"
                        ):
                            pages.update(
                                reason="Pages deployment did not complete successfully",
                                state="conflict",
                            )
                        else:
                            pages.update(
                                control_sha=matches[0]["head_sha"],
                                deployment_id=deployment_id,
                                run_id=matches[0].get("id"),
                                state="verified",
                            )
            observations["pages"] = pages
    return observations


def recovery_action(
    name: str,
    summary: str,
    *,
    prerequisites: list[str],
    side_effects: list[str],
    authority: str,
    invalidates: list[str] | None = None,
) -> dict[str, Any]:
    """Construct one deterministic recovery action record."""
    return {
        "invalidated_descendants": invalidates or [],
        "name": name,
        "prerequisites": prerequisites,
        "reason": summary,
        "required_authority": authority,
        "side_effects": side_effects,
        "summary": summary,
    }


def plan_recovery(
    waiting: list[dict[str, Any]],
    failed: list[dict[str, Any]],
    missing: list[str],
    remote: dict[str, Any],
    postconditions: dict[str, Any],
) -> dict[str, Any]:
    """Return a pure, single-next-step recovery plan from typed observations."""
    missing_release_assets = sorted(set(missing) & set(EXPECTED_RELEASE_ASSETS))
    missing_documentation = sorted(
        set(missing) & set(EXPECTED_DOCUMENTATION_ASSETS)
    )
    if any(record.get("state") == "dispatch-unknown" for record in waiting):
        return recovery_action(
            "reconcile-dispatch",
            "reconcile the unknown request ID; do not redispatch",
            prerequisites=["bounded request-ID workflow search"],
            side_effects=[],
            authority="recorded logical dispatch claim",
        )
    if waiting:
        return recovery_action(
            "inspect-run",
            "inspect the acknowledged workflow run before resuming",
            prerequisites=["recorded workflow run identity"],
            side_effects=[],
            authority="dispatch journal",
        )
    if failed:
        return recovery_action(
            "authorize-retry",
            "record the failed operation and explicitly authorize a new attempt",
            prerequisites=["terminal failed run evidence"],
            side_effects=["create a linked dispatch attempt"],
            authority="operator retry authorization",
        )
    if remote.get("state") == "unavailable":
        return recovery_action(
            "restore-observation",
            "restore remote observation before planning a mutation",
            prerequisites=["bounded authenticated GitHub observation"],
            side_effects=[],
            authority="read-only remote access",
        )
    if remote.get("state") in {"invalid", "conflicting"}:
        return recovery_action(
            "resolve-release-conflict",
            "resolve the conflicting remote release state",
            prerequisites=["retained manifest", "remote release identity and digests"],
            side_effects=[],
            authority="release maintainer decision",
            invalidates=["formulae", "pages"],
        )
    if remote.get("state") == "draft" and not missing_release_assets:
        return recovery_action(
            "resume-stable-draft",
            "reconcile and publish the existing stable release draft",
            prerequisites=["retained-complete manifest", "matching stable draft"],
            side_effects=["upload missing assets", "publish stable release"],
            authority="retained publication authority",
            invalidates=["formulae", "pages"],
        )
    if (
        not missing_release_assets
        and remote.get("state") == "published"
        and remote.get("missing_assets")
    ):
        return recovery_action(
            "upload-missing-assets",
            "reconcile the incomplete remote release from exact retained bytes",
            prerequisites=["retained-complete manifest", "resumable release draft"],
            side_effects=["upload missing byte-identical assets"],
            authority="retained publication authority",
            invalidates=["formulae", "pages"],
        )
    if missing_release_assets and remote.get("state") == "published":
        return recovery_action(
            "import-published-assets",
            "import and verify exact published bytes; do not rebuild",
            prerequisites=["published immutable release assets"],
            side_effects=["write verified objects to retained storage"],
            authority="published release identity and checksums",
        )
    if missing_release_assets and remote.get("state") == "absent":
        return recovery_action(
            "restore-retained-closure",
            "produce or restore the missing retained release closure before publication",
            prerequisites=["authenticated source or exact recovery objects"],
            side_effects=["materialize only missing release nodes"],
            authority="release build authority",
        )
    if missing_release_assets:
        return recovery_action(
            "restore-exact-assets",
            "restore exact authenticated bytes or report the release blocked",
            prerequisites=["authenticated object source"],
            side_effects=["repair missing retained objects"],
            authority="retained or published checksum authority",
        )
    if remote.get("state") == "absent":
        return recovery_action(
            "publish-retained-release",
            "publish the verified retained release closure",
            prerequisites=["retained-complete manifest", "stable gate authority"],
            side_effects=["create or resume draft", "publish stable release"],
            authority="retained publication authority",
            invalidates=["formulae", "pages"],
        )
    if missing_documentation:
        return recovery_action(
            "restore-documentation-artifacts",
            "recover the missing DocC archives from the exact documentation run",
            prerequisites=["successful exact-input documentation run or regeneration"],
            side_effects=["retain verified context-bound DocC archives"],
            authority="stable documentation run identity",
        )
    if any(
        value.get("state") == "unavailable" for value in postconditions.values()
    ):
        return recovery_action(
            "restore-postcondition-observation",
            "restore formula and Pages observation before declaring recovery complete",
            prerequisites=["authenticated tap and Pages read access"],
            side_effects=[],
            authority="read-only remote access",
        )
    if postconditions["formulae"].get("state") not in {"verified", "superseded"}:
        return recovery_action(
            "repair-formulae",
            "restore or reconcile the paired Homebrew formulae; no build is required",
            prerequisites=["retained archive URLs and digests"],
            side_effects=["atomically update the paired stable formulae"],
            authority="tap publication authority",
        )
    if postconditions["pages"].get("state") not in {"verified", "superseded"}:
        return recovery_action(
            "redeploy-pages",
            "restore or reconcile Pages deployment; no build is required",
            prerequisites=["retained context-bound DocC sites"],
            side_effects=["assemble and deploy GitHub Pages"],
            authority="latest-stable documentation authority",
        )
    return recovery_action(
        "complete",
        "release recovery state is complete; no mutation or rebuild is required",
        prerequisites=[],
        side_effects=[],
        authority="verified retained and remote observations",
    )


def dispatch_succeeded(record: dict[str, Any]) -> bool:
    """Return whether one acknowledged dispatch completed successfully."""
    observed = record.get("observed")
    return (
        record.get("state") == "dispatched"
        and isinstance(observed, dict)
        and observed.get("state") == "completed"
        and observed.get("conclusion") == "success"
    )


def unresolved_failed_dispatches(
    records: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Exclude failed attempts superseded by a successful linked retry."""
    records_by_id = {
        record["request_id"]: record
        for record in records
        if isinstance(record.get("request_id"), str)
    }
    superseded: set[str] = set()
    for record in records:
        if not dispatch_succeeded(record):
            continue
        previous = record.get("previous_request_id")
        while isinstance(previous, str) and previous not in superseded:
            superseded.add(previous)
            predecessor = records_by_id.get(previous)
            previous = (
                predecessor.get("previous_request_id")
                if isinstance(predecessor, dict)
                else None
            )

    return [
        record
        for record in records
        if record.get("request_id") not in superseded
        and (
            record.get("state") == "failed"
            or (
                record.get("state") == "dispatched"
                and isinstance(record.get("observed"), dict)
                and record["observed"].get("state") == "completed"
                and record["observed"].get("conclusion") != "success"
            )
        )
    ]


def inspect(
    root: Path, version: str, repo: str, offline: bool, deep: bool = False
) -> dict[str, Any]:
    if not root.is_absolute() or root == Path("/") or root.is_symlink():
        raise StateError(f"unsafe retained release root: {root}")
    if not SEMVER.fullmatch(version):
        raise StateError(f"invalid stable release version: {version}")
    observed_at = datetime.now(timezone.utc).isoformat()
    manifest = load_retained_manifest(root, version)
    present, missing = retained_assets(root, version, deep, manifest)
    records = observe_dispatches(dispatch_records(root, version), repo, offline)
    remote = reconcile_remote_digests(
        remote_release(repo, version, offline), manifest
    )
    remote["evidence_source"] = "none" if offline else "github-api"
    remote["observed_at"] = observed_at
    missing_release_assets = sorted(set(missing) & set(EXPECTED_RELEASE_ASSETS))
    if remote.get("state") == "published" and not missing_release_assets:
        postconditions = remote_postconditions(
            repo, version, offline, formula_expectations(manifest, version, repo)
        )
    else:
        postconditions = {
            "formulae": {"state": "deferred"},
            "pages": {"state": "deferred"},
        }
    for observation in postconditions.values():
        observation["evidence_source"] = (
            "none" if offline or observation.get("state") == "deferred" else "github-api"
        )
        observation["observed_at"] = observed_at
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
    failed = unresolved_failed_dispatches(records)
    action = plan_recovery(waiting, failed, missing, remote, postconditions)
    return {
        "actions": [action],
        "dispatches": records,
        "failed": failed,
        "next_action": action["summary"],
        "observed_at": observed_at,
        "remote_release": remote,
        "remote_postconditions": postconditions,
        "retained": {
            "evidence_source": "internal-retained-manifest",
            "missing": missing,
            "observed_at": observed_at,
            "verified": present,
        },
        "root": str(root),
        "verification": "deep" if deep else "shallow",
        "schema": 2,
        "version": version,
        "waiting": waiting,
    }


def render_text(state: dict[str, Any], planning: bool) -> str:
    retained = state["retained"]
    remote = state["remote_release"]
    lines = [f"Release {state['version']}: read-only {'plan' if planning else 'status'}"]
    lines.append(f"Remote release: {remote['state']}")
    lines.append(
        "Retained artifacts: "
        f"{len(retained['verified'])}/{len(EXPECTED_RETAINED_ASSETS)} verified"
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
    parser.add_argument(
        "--deep", action="store_true",
        help="rehash every retained payload instead of using manifest metadata",
    )
    options = parser.parse_args(arguments)
    try:
        state = inspect(
            options.root, options.version, options.repo, options.offline, options.deep
        )
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
