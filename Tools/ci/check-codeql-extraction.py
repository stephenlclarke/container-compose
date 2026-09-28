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

"""Compare CodeQL extraction diagnostics with a tracked source inventory."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit

import codeql_compatibility

ERROR_EXAMPLE_LIMIT = 5


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalize_uri(uri: str, base_id: str | None) -> str:
    if base_id not in (None, "%SRCROOT%"):
        raise ValueError(f"unsupported URI base: {base_id!r}")
    if not isinstance(uri, str):
        raise ValueError("missing artifact URI")
    parsed = urlsplit(uri)
    if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError(f"unsupported artifact URI: {uri!r}")
    decoded = unquote(parsed.path)
    if not decoded or decoded.startswith("/") or "\\" in decoded:
        raise ValueError(f"non-relative artifact path: {uri!r}")
    parts = PurePosixPath(decoded).parts
    if any(part in (".", "..") for part in decoded.split("/")) or not parts:
        raise ValueError(f"unsafe artifact path: {uri!r}")
    return str(PurePosixPath(*parts))


def notification_paths(notification: dict, artifacts: list) -> set[str]:
    paths = set()
    for location in notification.get("locations", []):
        artifact = location.get("physicalLocation", {}).get("artifactLocation", {})
        index = artifact.get("index")
        indexed = None
        if index is not None:
            if not isinstance(index, int) or isinstance(index, bool) or index < 0 or index >= len(artifacts):
                raise ValueError(f"invalid SARIF artifact index: {index!r}")
            indexed = artifacts[index].get("location", {})
        uri = artifact.get("uri")
        base = artifact.get("uriBaseId")
        if uri is None and indexed is not None:
            uri = indexed.get("uri")
            base = base or indexed.get("uriBaseId")
        if uri is None:
            raise ValueError("diagnostic location has no artifact URI or index")
        path = normalize_uri(uri, base)
        if indexed is not None and indexed.get("uri") is not None:
            indexed_path = normalize_uri(indexed["uri"], indexed.get("uriBaseId"))
            if path != indexed_path:
                raise ValueError(f"artifact index and URI disagree: {path!r} != {indexed_path!r}")
        paths.add(path)
    return paths


def is_source(path: str, language: str) -> bool:
    if language == "swift":
        return path.startswith("Sources/") and path.endswith(".swift")
    return (
        path.startswith("Tools/compose-normalizer/")
        and path.endswith(".go")
        and not path.endswith("_test.go")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--language", choices=("swift", "go"), required=True)
    parser.add_argument("--require-clean", action="store_true")
    parser.add_argument("--sarif", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reviewed-compatibility", type=Path)
    parser.add_argument("--source-root", type=Path, default=Path.cwd())
    args = parser.parse_args()

    sarif = json.loads(args.sarif.read_text(encoding="utf-8"))
    success_id = f"{args.language}/diagnostics/successfully-extracted-files"
    expected_ids = {
        f"{args.language}/baseline/expected-extracted-files",
        f"cli/expected-extracted-files/{args.language}",
    }
    error_id = f"{args.language}/diagnostics/extraction-errors"
    inventory = {
        normalize_uri(line.strip(), None)
        for line in args.inventory.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }
    if not inventory or any(not is_source(path, args.language) for path in inventory):
        raise ValueError("inventory must contain only maintained production source paths")

    extracted, expected, errors = set(), set(), []
    success_notifications = expected_notifications = 0
    invocation_results = []
    language_successful_invocation = False
    invocation_count = 0
    language_run_count = 0
    for run in sarif.get("runs", []):
        artifacts = run.get("artifacts", [])
        for invocation in run.get("invocations", []):
            invocation_count += 1
            succeeded = invocation.get("executionSuccessful") is True
            invocation_results.append(succeeded)
            language_diagnostics_in_invocation = False
            for notification in invocation.get("toolExecutionNotifications", []):
                descriptor = notification.get("descriptor") or {}
                diagnostic_id = descriptor.get("id")
                if diagnostic_id == success_id:
                    language_diagnostics_in_invocation = True
                    success_notifications += 1
                    paths = notification_paths(notification, artifacts)
                    if succeeded:
                        extracted.update(paths)
                elif diagnostic_id in expected_ids:
                    expected_notifications += 1
                    expected.update(notification_paths(notification, artifacts))
                elif diagnostic_id == error_id:
                    errors.append((notification.get("message") or {}).get("text", ""))
            if language_diagnostics_in_invocation and succeeded:
                language_successful_invocation = True
        if any(
            (n.get("descriptor") or {}).get("id") == success_id
            for inv in run.get("invocations", [])
            for n in inv.get("toolExecutionNotifications", [])
        ):
            language_run_count += 1

    extracted_source = {path for path in extracted if is_source(path, args.language)}
    expected_source = {path for path in expected if is_source(path, args.language)}
    missing = inventory - extracted_source
    invocation_success = bool(invocation_results) and all(invocation_results)
    policy = None
    compatibility_source = None
    if args.reviewed_compatibility:
        if args.language != "swift":
            raise ValueError("Reviewed compatibility applies only to Swift")
        policy = codeql_compatibility.load_policy(args.reviewed_compatibility)
        compatibility_source = codeql_compatibility.source_receipt(
            args.source_root, policy, verify_checkout=True)
    disposition = codeql_compatibility.assessment(sarif, policy)
    report = {
        "language": args.language,
        "sarif": str(args.sarif.resolve()),
        "sarif_sha256": sha256(args.sarif),
        "inventory": str(args.inventory.resolve()),
        "inventory_sha256": sha256(args.inventory),
        "invocation_count": invocation_count,
        "invocation_success": invocation_success,
        "language_successful_invocation": language_successful_invocation,
        "language_run_count": language_run_count,
        **disposition,
        "compatibility_disposition_sha256": sha256(args.reviewed_compatibility)
        if args.reviewed_compatibility else None,
        "compatibility_source": compatibility_source,
        "inventory_count": len(inventory),
        "expected_source_count": len(expected_source),
        "extracted_source_count": len(extracted_source),
        "inventory_extracted_count": len(inventory & extracted_source),
        "success_diagnostic_count": success_notifications,
        "expected_diagnostic_count": expected_notifications,
        "extraction_error_diagnostic_count": len(errors),
        "extraction_error_examples": errors[:ERROR_EXAMPLE_LIMIT],
        "missing": sorted(missing),
        "extra_extracted": sorted(extracted_source - inventory),
        "expected_not_in_inventory": sorted(expected_source - inventory),
        "inventory_not_expected": sorted(inventory - expected_source),
        "complete": invocation_success and language_successful_invocation and not missing,
        "clean": disposition["compatibility_disposition_complete"] and not errors,
        "interpretation": "complete requires successful invocations and extraction of every inventoried source; clean requires zero extraction errors and zero unreviewed findings, with any reviewed compatibility findings retained in the raw alert count and bound to exact dependency source",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({key: report[key] for key in (
        "inventory_count", "expected_source_count", "extracted_source_count",
        "inventory_extracted_count", "extraction_error_diagnostic_count",
        "alert_count", "reviewed_compatibility_count", "actionable_alert_count",
        "unreviewed_alert_count", "invocation_success", "complete", "clean",
    )}, sort_keys=True))
    return 0 if report["complete"] and (not args.require_clean or report["clean"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
