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

"""Create and verify atomic, source-addressed Container stack build pins."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
OBJECT_ID_PATTERN = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")
REPOSITORY_PATTERN = re.compile(r"[a-z0-9][a-z0-9._-]*")
GO_BUILD_ENVIRONMENT = (
    "AR",
    "CC",
    "CGO_CFLAGS",
    "CGO_CPPFLAGS",
    "CGO_CXXFLAGS",
    "CGO_ENABLED",
    "CGO_FFLAGS",
    "CGO_LDFLAGS",
    "CXX",
    "FC",
    "GCCGO",
    "GO386",
    "GOAMD64",
    "GOARCH",
    "GOARM",
    "GOARM64",
    "GOEXPERIMENT",
    "GOFIPS140",
    "GOFLAGS",
    "GOGCCFLAGS",
    "GOMIPS",
    "GOMIPS64",
    "GOOS",
    "GOPPC64",
    "GORISCV64",
    "GOTOOLCHAIN",
    "GOWASM",
    "GOWORK",
    "PKG_CONFIG",
)


class PinError(RuntimeError):
    """A build pin is absent, malformed, or no longer authoritative."""


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create and verify recoverable Container stack build pins."
    )
    subparsers = parser.add_subparsers(dest="action", required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--repository", required=True)
    create.add_argument("--repository-path", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    create.add_argument("--artifact", type=Path, action="append", default=[])
    create.add_argument("--dependency", type=Path, action="append", default=[])
    create.add_argument("--command-label", required=True)
    create.add_argument("--build-contract", required=True)
    create.add_argument("--duration-seconds", type=float, required=True)
    create.add_argument("--expected-commit", required=True)
    create.add_argument("--expected-tree", required=True)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--receipt", type=Path, required=True)
    verify.add_argument("--repository")
    verify.add_argument("--repository-path", type=Path)
    verify.add_argument("--build-contract")
    verify.add_argument("--quiet", action="store_true")

    value = subparsers.add_parser("value")
    value.add_argument("--receipt", type=Path, required=True)
    value.add_argument("--field", required=True)

    bundle = subparsers.add_parser("bundle")
    bundle.add_argument("--output", type=Path, required=True)
    bundle.add_argument("--pin", type=Path, action="append", required=True)

    verify_bundle_parser = subparsers.add_parser("verify-bundle")
    verify_bundle_parser.add_argument("--bundle", type=Path, required=True)
    verify_bundle_parser.add_argument("--repository", action="append", default=[])
    verify_bundle_parser.add_argument("--quiet", action="store_true")

    contract = subparsers.add_parser("contract")
    contract.add_argument("--tool", required=True)
    contract.add_argument("--configuration", required=True)
    contract.add_argument("--controller", type=Path, action="append", default=[])

    return parser.parse_args(arguments)


def sha256_bytes(contents: bytes) -> str:
    return hashlib.sha256(contents).hexdigest()


def regular_file_bytes(path: Path) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise PinError(f"not a regular file: {path}")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            return stream.read()
    except OSError as error:
        raise PinError(f"could not read {path}: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def sha256_file(path: Path) -> str:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    digest = hashlib.sha256()
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise PinError(f"not a regular file: {path}")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = -1
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise PinError(f"could not read {path}: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


def canonical_json(value: dict[str, Any]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def payload_digest(payload: dict[str, Any]) -> str:
    unsigned = dict(payload)
    unsigned.pop("receipt_sha256", None)
    return sha256_bytes(canonical_json(unsigned))


def git_output(repository_path: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(repository_path), *arguments],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or f"exit {result.returncode}"
        raise PinError(f"could not inspect {repository_path}: {diagnostic}")
    return result.stdout.strip()


def validate_repository_name(name: str) -> str:
    if not REPOSITORY_PATTERN.fullmatch(name):
        raise PinError(f"invalid repository name: {name}")
    return name


def normalize_gogccflags(value: str) -> str:
    """Remove cmd/go's per-invocation work path without hiding real flag changes."""
    normalized: list[str] = []
    for argument in shlex.split(value):
        prefix = "-ffile-prefix-map="
        if argument.startswith(prefix):
            source, separator, destination = argument[len(prefix) :].rpartition("=")
            if (
                separator
                and destination == "/tmp/go-build"
                and re.fullmatch(r"go-build[0-9]+", Path(source).name)
            ):
                argument = f"{prefix}<go-build-work>={destination}"
        normalized.append(argument)
    return shlex.join(normalized)


def effective_go_build_environment(tool: Path) -> dict[str, str]:
    result = subprocess.run(
        [str(tool), "env", "-json", *GO_BUILD_ENVIRONMENT],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or f"exit {result.returncode}"
        raise PinError(f"could not resolve the effective Go build target: {diagnostic}")
    try:
        environment = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise PinError("effective Go build target is not valid JSON") from error
    if (
        not isinstance(environment, dict)
        or set(environment) != set(GO_BUILD_ENVIRONMENT)
        or any(not isinstance(value, str) for value in environment.values())
    ):
        raise PinError("effective Go build target is incomplete")
    environment["GOGCCFLAGS"] = normalize_gogccflags(environment["GOGCCFLAGS"])
    return {name: environment[name] for name in sorted(environment)}


def repository_record(repository_path: Path) -> dict[str, str]:
    if not repository_path.is_absolute():
        raise PinError(f"repository path must be absolute: {repository_path}")
    if repository_path.is_symlink():
        raise PinError(f"repository path must not be a symbolic link: {repository_path}")
    resolved_path = repository_path.resolve(strict=True)
    if git_output(resolved_path, "status", "--porcelain", "--untracked-files=normal"):
        raise PinError(f"repository must be clean before publishing a pin: {resolved_path}")
    commit = git_output(resolved_path, "rev-parse", "HEAD^{commit}")
    tree = git_output(resolved_path, "rev-parse", "HEAD^{tree}")
    if not OBJECT_ID_PATTERN.fullmatch(commit):
        raise PinError(f"repository has an invalid commit object ID: {commit}")
    if not OBJECT_ID_PATTERN.fullmatch(tree):
        raise PinError(f"repository has an invalid tree object ID: {tree}")
    remote_result = subprocess.run(
        ["/usr/bin/git", "-C", str(resolved_path), "remote", "get-url", "origin"],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return {
        "commit": commit,
        "path": str(resolved_path),
        "remote": remote_result.stdout.strip() if remote_result.returncode == 0 else "",
        "tree": tree,
    }


def build_contract(options: argparse.Namespace) -> str:
    tool_selector = options.tool
    tool_path = (
        Path(tool_selector)
        if "/" in tool_selector
        else Path(shutil.which(tool_selector) or tool_selector)
    )
    try:
        resolved_tool = tool_path.resolve(strict=True)
        tool_sha256 = sha256_file(resolved_tool)
    except (OSError, PinError) as error:
        raise PinError(f"build tool is unavailable: {tool_selector}: {error}") from error
    version_arguments = ["version"] if resolved_tool.name == "go" else ["--version"]
    version = subprocess.run(
        [str(resolved_tool), *version_arguments],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if version.returncode != 0:
        raise PinError(
            f"build tool version check failed: {tool_selector}: exit {version.returncode}"
        )
    controllers: list[dict[str, str]] = []
    for controller in options.controller:
        if not controller.is_absolute():
            raise PinError(f"build controller path must be absolute: {controller}")
        resolved_controller = controller.resolve(strict=True)
        controllers.append(
            {
                "path": str(resolved_controller),
                "sha256": sha256_file(resolved_controller),
            }
        )
    relevant_environment = {
        name: os.environ.get(name, "")
        for name in (
            "CC",
            "CFLAGS",
            "CGO_ENABLED",
            "CXX",
            "DEVELOPER_DIR",
            "GOFLAGS",
            "LDFLAGS",
            "SDKROOT",
            "SWIFTFLAGS",
        )
    }
    effective_tool_environment = (
        effective_go_build_environment(resolved_tool)
        if resolved_tool.name == "go"
        else {}
    )
    python_path = Path(sys.executable).resolve(strict=True)
    contract = {
        "configuration": options.configuration,
        "controllers": sorted(controllers, key=lambda item: item["path"]),
        "environment": relevant_environment,
        "host": {
            "machine": platform.machine(),
            "release": platform.release(),
            "system": platform.system(),
        },
        "python": {
            "path": str(python_path),
            "sha256": sha256_file(python_path),
            "version": platform.python_version(),
        },
        "schema": SCHEMA_VERSION,
        "tool": {
            "effective_environment": effective_tool_environment,
            "path": str(resolved_tool),
            "selector": tool_selector,
            "sha256": tool_sha256,
            "version": version.stdout.strip(),
        },
    }
    return sha256_bytes(canonical_json(contract))


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(regular_file_bytes(path).decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise PinError(f"invalid JSON receipt {path}: {error}") from error
    if not isinstance(value, dict):
        raise PinError(f"receipt must contain a JSON object: {path}")
    return value


def validate_digest(value: object, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise PinError(f"{label} is not a lowercase SHA-256 digest")
    return value


def verify_artifacts(receipt: dict[str, Any]) -> None:
    artifacts = receipt.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise PinError("build receipt has no artifacts")
    recorded_paths: list[str] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise PinError("build receipt has a malformed artifact")
        path_value = artifact.get("path")
        if not isinstance(path_value, str):
            raise PinError("build receipt artifact has no path")
        recorded_paths.append(path_value)
        path = Path(path_value)
        expected = validate_digest(artifact.get("sha256"), f"artifact {path} digest")
        try:
            actual = sha256_file(path)
        except (OSError, PinError) as error:
            raise PinError(f"build artifact is unavailable: {path}: {error}") from error
        if actual != expected:
            raise PinError(
                f"build artifact digest changed: {path} (expected {expected}, got {actual})"
            )
    if recorded_paths != sorted(set(recorded_paths)):
        raise PinError("build receipt artifact paths are duplicated or not canonical")


def verify_receipt(
    path: Path,
    expected_repository: str | None = None,
    expected_path: Path | None = None,
    expected_build_contract: str | None = None,
    seen: set[Path] | None = None,
) -> dict[str, Any]:
    if path.is_symlink():
        raise PinError(f"build receipt must not be a symbolic link: {path}")
    resolved_receipt = path.resolve(strict=True)
    if seen is None:
        seen = set()
    if resolved_receipt in seen:
        raise PinError(f"dependency receipt cycle detected: {resolved_receipt}")
    seen.add(resolved_receipt)
    try:
        receipt = read_json(resolved_receipt)
        if receipt.get("schema") != SCHEMA_VERSION:
            raise PinError(f"unsupported build pin schema in {resolved_receipt}")
        repository = receipt.get("repository")
        if not isinstance(repository, str):
            raise PinError(f"build pin has no repository name: {resolved_receipt}")
        validate_repository_name(repository)
        if expected_repository is not None and repository != expected_repository:
            raise PinError(
                f"build pin repository is {repository}, expected {expected_repository}"
            )
        expected_digest = validate_digest(
            receipt.get("receipt_sha256"), f"receipt {resolved_receipt} digest"
        )
        actual_digest = payload_digest(receipt)
        if actual_digest != expected_digest:
            raise PinError(
                f"build pin digest changed: {resolved_receipt} "
                f"(expected {expected_digest}, got {actual_digest})"
            )
        build = receipt.get("build")
        if not isinstance(build, dict):
            raise PinError(f"build pin has no build identity: {resolved_receipt}")
        command = build.get("command")
        completed_at = build.get("completed_at")
        duration_seconds = build.get("duration_seconds")
        if not isinstance(command, str) or not command.strip():
            raise PinError(f"build pin has no command label: {resolved_receipt}")
        if not isinstance(completed_at, str):
            raise PinError(f"build pin has no completion time: {resolved_receipt}")
        try:
            completion_time = datetime.fromisoformat(completed_at)
        except ValueError as error:
            raise PinError(
                f"build pin has an invalid completion time: {resolved_receipt}"
            ) from error
        if completion_time.tzinfo is None:
            raise PinError(
                f"build pin completion time has no timezone: {resolved_receipt}"
            )
        if (
            isinstance(duration_seconds, bool)
            or not isinstance(duration_seconds, (int, float))
            or not math.isfinite(duration_seconds)
            or duration_seconds < 0
        ):
            raise PinError(f"build pin has an invalid duration: {resolved_receipt}")
        recorded_contract = validate_digest(
            build.get("contract"), f"receipt {resolved_receipt} build contract"
        )
        if expected_build_contract is not None:
            validate_digest(expected_build_contract, "expected build contract")
            if recorded_contract != expected_build_contract:
                raise PinError(
                    f"build contract changed for {repository}: expected "
                    f"{expected_build_contract}, got {recorded_contract}"
                )
        source = receipt.get("source")
        if not isinstance(source, dict) or not isinstance(source.get("path"), str):
            raise PinError(f"build pin has no source path: {resolved_receipt}")
        source_path = Path(source["path"])
        current_source = repository_record(source_path)
        if expected_path is not None and current_source["path"] != str(
            expected_path.resolve(strict=True)
        ):
            raise PinError(
                f"build pin source is {current_source['path']}, expected "
                f"{expected_path.resolve(strict=True)}"
            )
        for field in ("commit", "tree"):
            recorded = source.get(field)
            if not isinstance(recorded, str) or not OBJECT_ID_PATTERN.fullmatch(recorded):
                raise PinError(
                    f"build pin has an invalid source {field}: {resolved_receipt}"
                )
            if current_source[field] != recorded:
                raise PinError(
                    f"{repository} {field} changed: expected {recorded}, "
                    f"got {current_source[field]}"
                )
        recorded_remote = source.get("remote")
        if not isinstance(recorded_remote, str):
            raise PinError(f"build pin has no source remote: {resolved_receipt}")
        if current_source["remote"] != recorded_remote:
            raise PinError(
                f"{repository} remote changed: expected {recorded_remote!r}, "
                f"got {current_source['remote']!r}"
            )
        dependencies = receipt.get("dependencies")
        if not isinstance(dependencies, list):
            raise PinError(f"build pin has malformed dependencies: {resolved_receipt}")
        dependency_names: list[str] = []
        for dependency in dependencies:
            if not isinstance(dependency, dict):
                raise PinError(f"build pin has a malformed dependency: {resolved_receipt}")
            dependency_path = dependency.get("receipt")
            dependency_name = dependency.get("repository")
            dependency_digest = validate_digest(
                dependency.get("receipt_sha256"), "dependency receipt digest"
            )
            if not isinstance(dependency_path, str) or not isinstance(
                dependency_name, str
            ):
                raise PinError(f"build pin has a malformed dependency: {resolved_receipt}")
            validate_repository_name(dependency_name)
            dependency_names.append(dependency_name)
            verified = verify_receipt(
                Path(dependency_path),
                expected_repository=dependency_name,
                seen=seen,
            )
            if verified["receipt_sha256"] != dependency_digest:
                raise PinError(
                    f"dependency pin changed for {dependency_name}: "
                    f"{dependency_path}"
                )
        if dependency_names != sorted(set(dependency_names)):
            raise PinError(
                f"build pin dependencies are duplicated or not canonical: {resolved_receipt}"
            )
        verify_artifacts(receipt)
        return receipt
    finally:
        seen.remove(resolved_receipt)


def dependency_record(path: Path) -> dict[str, str]:
    receipt = verify_receipt(path)
    return {
        "receipt": str(path.resolve(strict=True)),
        "receipt_sha256": receipt["receipt_sha256"],
        "repository": receipt["repository"],
    }


def artifact_record(path: Path) -> dict[str, str]:
    if not path.is_absolute():
        raise PinError(f"artifact path must be absolute: {path}")
    if path.is_symlink():
        raise PinError(f"artifact path must not be a symbolic link: {path}")
    resolved = path.resolve(strict=True)
    return {"path": str(resolved), "sha256": sha256_file(resolved)}


def write_json_atomically(path: Path, value: dict[str, Any]) -> None:
    if not path.is_absolute():
        raise PinError(f"output path must be absolute: {path}")
    if path == Path("/") or path.is_symlink():
        raise PinError(f"unsafe output path: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        temporary_path.unlink(missing_ok=True)


def create_receipt(options: argparse.Namespace) -> dict[str, Any]:
    repository = validate_repository_name(options.repository)
    source = repository_record(options.repository_path)
    for field, expected in (
        ("commit", options.expected_commit),
        ("tree", options.expected_tree),
    ):
        if not OBJECT_ID_PATTERN.fullmatch(expected):
            raise PinError(f"expected source {field} is not a Git object ID")
        if source[field] != expected:
            raise PinError(
                f"{repository} {field} changed while the build ran: "
                f"expected {expected}, got {source[field]}"
            )
    if not options.artifact:
        raise PinError("at least one --artifact is required")
    if not math.isfinite(options.duration_seconds) or options.duration_seconds < 0:
        raise PinError("build duration must be finite and non-negative")
    if not options.command_label.strip():
        raise PinError("build command label must not be empty")
    artifacts = sorted(
        (artifact_record(path) for path in options.artifact),
        key=lambda record: record["path"],
    )
    if len({artifact["path"] for artifact in artifacts}) != len(artifacts):
        raise PinError("build receipt contains duplicate artifact paths")
    dependencies = sorted(
        (dependency_record(path) for path in options.dependency),
        key=lambda record: record["repository"],
    )
    if len({dependency["repository"] for dependency in dependencies}) != len(
        dependencies
    ):
        raise PinError("build receipt contains duplicate dependency repositories")
    receipt: dict[str, Any] = {
        "artifacts": artifacts,
        "build": {
            "command": options.command_label,
            "completed_at": datetime.now(timezone.utc).isoformat(),
            "contract": validate_digest(options.build_contract, "build contract"),
            "duration_seconds": options.duration_seconds,
        },
        "dependencies": dependencies,
        "repository": repository,
        "schema": SCHEMA_VERSION,
        "source": source,
    }
    receipt["receipt_sha256"] = payload_digest(receipt)
    write_json_atomically(options.output, receipt)
    return receipt


def create_bundle(options: argparse.Namespace) -> dict[str, Any]:
    pins = [dependency_record(path) for path in options.pin]
    repositories = [pin["repository"] for pin in pins]
    if len(repositories) != len(set(repositories)):
        raise PinError("bundle contains duplicate repository pins")
    bundle: dict[str, Any] = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "pins": sorted(pins, key=lambda value: value["repository"]),
        "schema": SCHEMA_VERSION,
    }
    bundle["receipt_sha256"] = payload_digest(bundle)
    write_json_atomically(options.output, bundle)
    return bundle


def verify_bundle(
    path: Path, expected_repositories: Sequence[str] = ()
) -> dict[str, Any]:
    if path.is_symlink():
        raise PinError(f"stack pin bundle must not be a symbolic link: {path}")
    resolved_bundle = path.resolve(strict=True)
    bundle = read_json(resolved_bundle)
    if bundle.get("schema") != SCHEMA_VERSION:
        raise PinError(f"unsupported stack pin bundle schema in {resolved_bundle}")
    expected_digest = validate_digest(
        bundle.get("receipt_sha256"), f"bundle {resolved_bundle} digest"
    )
    actual_digest = payload_digest(bundle)
    if actual_digest != expected_digest:
        raise PinError(
            f"stack pin bundle digest changed: {resolved_bundle} "
            f"(expected {expected_digest}, got {actual_digest})"
        )
    pins = bundle.get("pins")
    if not isinstance(pins, list) or not pins:
        raise PinError(f"stack pin bundle has no pins: {resolved_bundle}")
    repositories: set[str] = set()
    for pin in pins:
        if not isinstance(pin, dict):
            raise PinError(f"stack pin bundle has a malformed pin: {resolved_bundle}")
        receipt_path = pin.get("receipt")
        repository = pin.get("repository")
        recorded_digest = validate_digest(
            pin.get("receipt_sha256"), "bundled receipt digest"
        )
        if not isinstance(receipt_path, str) or not isinstance(repository, str):
            raise PinError(f"stack pin bundle has a malformed pin: {resolved_bundle}")
        validate_repository_name(repository)
        if repository in repositories:
            raise PinError(f"stack pin bundle contains duplicate pin: {repository}")
        repositories.add(repository)
        receipt = verify_receipt(
            Path(receipt_path), expected_repository=repository
        )
        if receipt["receipt_sha256"] != recorded_digest:
            raise PinError(f"bundled receipt changed for {repository}: {receipt_path}")
    if [pin["repository"] for pin in pins] != sorted(repositories):
        raise PinError(f"stack pin bundle is not in canonical order: {resolved_bundle}")
    expected = {validate_repository_name(name) for name in expected_repositories}
    if expected and repositories != expected:
        raise PinError(
            "stack pin bundle repository set changed: expected "
            f"{sorted(expected)}, got {sorted(repositories)}"
        )
    return bundle


def receipt_value(receipt: dict[str, Any], field: str) -> object:
    value: object = receipt
    for component in field.split("."):
        if not isinstance(value, dict) or component not in value:
            raise PinError(f"receipt field does not exist: {field}")
        value = value[component]
    if isinstance(value, (dict, list)):
        return json.dumps(value, sort_keys=True, separators=(",", ":"))
    return value


def main(arguments: Sequence[str] | None = None) -> int:
    options = parse_arguments(sys.argv[1:] if arguments is None else arguments)
    try:
        if options.action == "create":
            receipt = create_receipt(options)
            print(receipt["receipt_sha256"])
        elif options.action == "verify":
            receipt = verify_receipt(
                options.receipt,
                expected_repository=options.repository,
                expected_path=options.repository_path,
                expected_build_contract=options.build_contract,
            )
            if not options.quiet:
                print(receipt["receipt_sha256"])
        elif options.action == "value":
            receipt = verify_receipt(options.receipt)
            print(receipt_value(receipt, options.field))
        elif options.action == "bundle":
            bundle = create_bundle(options)
            print(bundle["receipt_sha256"])
        elif options.action == "verify-bundle":
            bundle = verify_bundle(options.bundle, options.repository)
            if not options.quiet:
                print(bundle["receipt_sha256"])
        elif options.action == "contract":
            print(build_contract(options))
        else:  # pragma: no cover - argparse enforces the action.
            raise AssertionError(options.action)
    except (OSError, PinError) as error:
        if not getattr(options, "quiet", False):
            print(f"stack pin error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
