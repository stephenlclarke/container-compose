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
    create.add_argument(
        "--artifact-map",
        action="append",
        default=[],
        metavar="LOGICAL_PATH=FILE",
        help="retain a file under a package-relative logical path",
    )
    create.add_argument("--dependency", type=Path, action="append", default=[])
    create.add_argument("--command-label", required=True)
    create.add_argument("--build-contract", required=True)
    create.add_argument("--duration-seconds", type=float, required=True)
    create.add_argument("--expected-commit", required=True)
    create.add_argument("--expected-tree", required=True)
    create.add_argument("--index-root", type=Path)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--receipt", type=Path, required=True)
    verify.add_argument("--repository")
    verify.add_argument("--repository-path", type=Path)
    verify.add_argument("--build-contract")
    verify.add_argument(
        "--retained-only",
        action="store_true",
        help="verify retained receipts and artifacts without requiring source checkouts",
    )
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

    materialize = subparsers.add_parser("materialize")
    materialize.add_argument("--receipt", type=Path, required=True)
    materialize.add_argument("--output", type=Path, required=True)

    lookup = subparsers.add_parser("lookup")
    lookup.add_argument("--repository", required=True)
    lookup.add_argument("--repository-path", type=Path, required=True)
    lookup.add_argument("--build-contract", required=True)
    lookup.add_argument("--dependency", type=Path, action="append", default=[])
    lookup.add_argument("--index-root", type=Path, required=True)
    lookup.add_argument("--output", type=Path, required=True)

    contract = subparsers.add_parser("contract")
    contract.add_argument("--tool", required=True)
    contract.add_argument("--configuration", required=True)
    contract.add_argument("--controller", type=Path, action="append", default=[])
    contract.add_argument("--controller-section", action="append", default=[])

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


def output_manifest_digest(artifacts: list[dict[str, Any]]) -> str:
    """Return location-independent identity for a retained product closure."""
    members = [
        {
            "mode": artifact["mode"],
            "name": artifact["name"],
            "sha256": artifact["sha256"],
            "size": artifact["size"],
        }
        for artifact in artifacts
    ]
    return sha256_bytes(canonical_json({"members": members, "schema": 1}))


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


def checked_output(arguments: Sequence[str], description: str) -> str:
    result = subprocess.run(
        arguments,
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or f"exit {result.returncode}"
        raise PinError(f"could not resolve {description}: {diagnostic}")
    return result.stdout.strip()


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


def effective_swift_build_environment(tool: Path) -> dict[str, Any]:
    try:
        target_info = json.loads(
            checked_output([str(tool), "-print-target-info"], "Swift target")
        )
    except json.JSONDecodeError as error:
        raise PinError("effective Swift target is not valid JSON") from error
    if not isinstance(target_info, dict):
        raise PinError("effective Swift target is malformed")

    compiler = tool
    developer_directory = ""
    sdk: dict[str, Any] = {}
    if platform.system() == "Darwin":
        developer_selector = os.environ.get("DEVELOPER_DIR", "")
        sdk_selector = os.environ.get("SDKROOT", "")
        xcrun: Path | None = None
        if tool == Path("/usr/bin/swift") or not sdk_selector:
            xcrun = Path("/usr/bin/xcrun").resolve(strict=True)
        if tool == Path("/usr/bin/swift"):
            assert xcrun is not None
            compiler = Path(
                checked_output([str(xcrun), "--find", "swift"], "Swift compiler")
            ).resolve(strict=True)
        developer_directory = str(
            (
                Path(developer_selector)
                if developer_selector
                else Path(
                    checked_output(
                        ["/usr/bin/xcode-select", "-p"], "Xcode developer directory"
                    )
                )
            ).resolve(strict=True)
        )
        sdk_path = (
            Path(sdk_selector)
            if sdk_selector
            else Path(
                checked_output(
                    [
                        str(xcrun),
                        "--sdk",
                        "macosx",
                        "--show-sdk-path",
                    ],
                    "Swift SDK",
                )
            )
        ).resolve(strict=True)
        metadata: list[dict[str, str]] = []
        for relative_path in (
            "SDKSettings.json",
            "SDKSettings.plist",
            "System/Library/CoreServices/SystemVersion.plist",
        ):
            metadata_path = sdk_path / relative_path
            if metadata_path.is_file() and not metadata_path.is_symlink():
                metadata.append(
                    {"path": relative_path, "sha256": sha256_file(metadata_path)}
                )
        if not metadata:
            raise PinError(f"effective Swift SDK has no identity metadata: {sdk_path}")
        sdk = {"metadata": metadata, "path": str(sdk_path)}

    return {
        "compiler": {"path": str(compiler), "sha256": sha256_file(compiler)},
        "developer_directory": developer_directory,
        "sdk": sdk,
        "target": target_info,
    }


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
    for specification in options.controller_section:
        fields = specification.split("::", 2)
        if len(fields) != 3 or not all(fields):
            raise PinError(
                "build controller section must be PATH::BEGIN-MARKER::END-MARKER"
            )
        path_value, begin_marker, end_marker = fields
        section_path = Path(path_value)
        if not section_path.is_absolute():
            raise PinError(f"build controller path must be absolute: {section_path}")
        resolved_section = section_path.resolve(strict=True)
        try:
            contents = regular_file_bytes(resolved_section).decode("utf-8")
        except UnicodeDecodeError as error:
            raise PinError(
                f"build controller section is not UTF-8: {resolved_section}"
            ) from error
        begin_token = begin_marker + "\n"
        end_token = end_marker + "\n"
        if contents.count(begin_token) != 1 or contents.count(end_token) != 1:
            raise PinError(
                f"build controller section markers must occur once: {resolved_section}"
            )
        begin = contents.index(begin_token)
        end = contents.index(end_token, begin) + len(end_token)
        controllers.append(
            {
                "path": str(resolved_section),
                "section": f"{begin_marker}..{end_marker}",
                "sha256": sha256_bytes(contents[begin:end].encode("utf-8")),
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
            "SWIFT_EXEC",
            "SWIFTFLAGS",
            "TOOLCHAINS",
        )
    }
    if resolved_tool.name == "go":
        effective_tool_environment: dict[str, Any] = effective_go_build_environment(
            resolved_tool
        )
    elif resolved_tool.name == "swift":
        effective_tool_environment = effective_swift_build_environment(resolved_tool)
    else:
        effective_tool_environment = {}
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
    recorded_names: list[str] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise PinError("build receipt has a malformed artifact")
        path_value = artifact.get("path")
        if not isinstance(path_value, str):
            raise PinError("build receipt artifact has no path")
        recorded_names.append(
            validate_logical_path(str(artifact.get("name", Path(path_value).name)))
        )
        path = Path(path_value)
        expected = validate_digest(artifact.get("sha256"), f"artifact {path} digest")
        expected_mode = artifact.get("mode")
        expected_size = artifact.get("size")
        if (
            isinstance(expected_mode, bool)
            or not isinstance(expected_mode, int)
            or expected_mode < 0
            or expected_mode > 0o7777
        ):
            raise PinError(f"artifact {path} has an invalid file mode")
        if expected_size is not None and (
            isinstance(expected_size, bool)
            or not isinstance(expected_size, int)
            or expected_size < 0
        ):
            raise PinError(f"artifact {path} has an invalid size")
        try:
            actual = sha256_file(path)
            actual_mode = stat.S_IMODE(path.stat(follow_symlinks=False).st_mode)
        except (OSError, PinError) as error:
            raise PinError(f"build artifact is unavailable: {path}: {error}") from error
        if actual != expected:
            raise PinError(
                f"build artifact digest changed: {path} (expected {expected}, got {actual})"
            )
        if actual_mode != expected_mode:
            raise PinError(
                f"build artifact mode changed: {path} "
                f"(expected {expected_mode:#o}, got {actual_mode:#o})"
            )
        if expected_size is not None and path.stat(follow_symlinks=False).st_size != expected_size:
            raise PinError(f"build artifact size changed: {path}")
    if recorded_names != sorted(set(recorded_names)):
        raise PinError("build receipt artifact names are duplicated or not canonical")


def verify_receipt(
    path: Path,
    expected_repository: str | None = None,
    expected_path: Path | None = None,
    expected_build_contract: str | None = None,
    verify_source: bool = True,
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
        # The recorded path is build-time audit evidence, not artifact identity.
        # A clean checkout may be recreated elsewhere after external workspace
        # cleanup. When a caller supplies its current path, validate that exact
        # repository against the recorded commit/tree/origin.
        for field in ("commit", "tree"):
            recorded = source.get(field)
            if not isinstance(recorded, str) or not OBJECT_ID_PATTERN.fullmatch(recorded):
                raise PinError(
                    f"build pin has an invalid source {field}: {resolved_receipt}"
                )
        recorded_remote = source.get("remote")
        if not isinstance(recorded_remote, str):
            raise PinError(f"build pin has no source remote: {resolved_receipt}")
        if verify_source:
            source_path = expected_path if expected_path is not None else Path(source["path"])
            current_source = repository_record(source_path)
            for field in ("commit", "tree"):
                if current_source[field] != source[field]:
                    raise PinError(
                        f"{repository} {field} changed: expected {source[field]}, "
                        f"got {current_source[field]}"
                    )
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
            dependency_output_digest = dependency.get("output_manifest_digest")
            if dependency_output_digest is not None:
                dependency_output_digest = validate_digest(
                    dependency_output_digest, "dependency output manifest digest"
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
                verify_source=False,
                seen=seen,
            )
            if (
                dependency_output_digest is None
                and verified["receipt_sha256"] != dependency_digest
            ):
                raise PinError(
                    f"dependency pin changed for {dependency_name}: "
                    f"{dependency_path}"
                )
            if (
                dependency_output_digest is not None
                and verified.get("output_manifest_digest") != dependency_output_digest
            ):
                raise PinError(
                    f"dependency output changed for {dependency_name}: "
                    f"{dependency_path}"
                )
        if dependency_names != sorted(set(dependency_names)):
            raise PinError(
                f"build pin dependencies are duplicated or not canonical: {resolved_receipt}"
            )
        verify_artifacts(receipt)
        recorded_output_digest = receipt.get("output_manifest_digest")
        if recorded_output_digest is not None:
            recorded_output_digest = validate_digest(
                recorded_output_digest, f"receipt {resolved_receipt} output manifest"
            )
            if recorded_output_digest != output_manifest_digest(receipt["artifacts"]):
                raise PinError(f"build pin output manifest changed: {resolved_receipt}")
        return receipt
    finally:
        seen.remove(resolved_receipt)


def dependency_record(path: Path) -> dict[str, str]:
    receipt = verify_receipt(path)
    return {
        "output_manifest_digest": receipt.get(
            "output_manifest_digest", output_manifest_digest(receipt["artifacts"])
        ),
        "receipt": str(path.resolve(strict=True)),
        "receipt_sha256": receipt["receipt_sha256"],
        "repository": receipt["repository"],
    }


def validate_logical_path(value: str) -> str:
    path = Path(value)
    if (
        not value
        or path.is_absolute()
        or ".." in path.parts
        or any(component in {"", "."} for component in path.parts)
    ):
        raise PinError(f"invalid artifact logical path: {value!r}")
    return path.as_posix()


def artifact_record(path: Path, logical_path: str | None = None) -> dict[str, str | int]:
    if not path.is_absolute():
        raise PinError(f"artifact path must be absolute: {path}")
    if path.is_symlink():
        raise PinError(f"artifact path must not be a symbolic link: {path}")
    resolved = path.resolve(strict=True)
    mode = stat.S_IMODE(resolved.stat(follow_symlinks=False).st_mode)
    return {
        "mode": mode,
        "name": validate_logical_path(logical_path or resolved.name),
        "path": str(resolved),
        "sha256": sha256_file(resolved),
        "size": resolved.stat(follow_symlinks=False).st_size,
    }


def mapped_artifact(value: str) -> tuple[str, Path]:
    logical, separator, source = value.partition("=")
    if not separator or not source:
        raise PinError(f"artifact map must be LOGICAL_PATH=FILE: {value!r}")
    return validate_logical_path(logical), Path(source)


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


def receipt_input_key(
    repository: str,
    source: dict[str, str],
    build_contract: str,
    dependencies: list[dict[str, str]],
) -> str:
    semantic_dependencies = [
        {
            "repository": dependency["repository"],
            "output_manifest_digest": dependency["output_manifest_digest"],
        }
        for dependency in dependencies
    ]
    return sha256_bytes(
        canonical_json(
            {
                "build_contract": validate_digest(build_contract, "build contract"),
                "dependencies": semantic_dependencies,
                "repository": validate_repository_name(repository),
                "source": {
                    "commit": source["commit"],
                    "remote": source["remote"],
                    "tree": source["tree"],
                },
            }
        )
    )


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
    if not options.artifact and not options.artifact_map:
        raise PinError("at least one --artifact is required")
    if not math.isfinite(options.duration_seconds) or options.duration_seconds < 0:
        raise PinError("build duration must be finite and non-negative")
    if not options.command_label.strip():
        raise PinError("build command label must not be empty")
    artifacts = [artifact_record(path) for path in options.artifact]
    artifacts.extend(
        artifact_record(source, logical)
        for logical, source in (mapped_artifact(value) for value in options.artifact_map)
    )
    artifacts.sort(key=lambda record: str(record["name"]))
    if len({artifact["name"] for artifact in artifacts}) != len(artifacts):
        raise PinError("build receipt contains duplicate artifact logical paths")
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
    receipt["output_manifest_digest"] = output_manifest_digest(artifacts)
    receipt["receipt_sha256"] = payload_digest(receipt)
    write_json_atomically(options.output, receipt)
    if options.index_root is not None:
        if not options.index_root.is_absolute() or options.index_root == Path("/"):
            raise PinError(f"unsafe build pin index: {options.index_root}")
        input_key = receipt_input_key(
            repository, source, receipt["build"]["contract"], dependencies
        )
        indexed = options.index_root / repository / f"{input_key}.json"
        if indexed.exists():
            existing = verify_receipt(indexed, verify_source=False)
            if existing["receipt_sha256"] != receipt["receipt_sha256"]:
                # Attempt metadata may differ while the same semantic input is
                # rebuilt. Preserve the first valid result as the reusable one.
                return receipt
        else:
            write_json_atomically(indexed, receipt)
    return receipt


def lookup_receipt(options: argparse.Namespace) -> dict[str, Any]:
    repository = validate_repository_name(options.repository)
    source = repository_record(options.repository_path)
    dependencies = sorted(
        (dependency_record(path) for path in options.dependency),
        key=lambda record: record["repository"],
    )
    input_key = receipt_input_key(
        repository, source, options.build_contract, dependencies
    )
    indexed = options.index_root / repository / f"{input_key}.json"
    receipt = verify_receipt(
        indexed,
        expected_repository=repository,
        expected_path=options.repository_path,
        expected_build_contract=options.build_contract,
    )
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
            Path(receipt_path), expected_repository=repository, verify_source=False
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


def materialize_receipt(receipt_path: Path, output: Path) -> None:
    receipt = verify_receipt(receipt_path, verify_source=False)
    if not output.is_absolute() or output == Path("/") or output.is_symlink():
        raise PinError(f"unsafe materialization output: {output}")
    if output.exists() and any(output.iterdir()):
        raise PinError(f"materialization output is not empty: {output}")
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    resolved_output = output.resolve(strict=True)
    if resolved_output != Path(os.path.abspath(output)):
        raise PinError(f"materialization output contains a symbolic link: {output}")
    for artifact in receipt["artifacts"]:
        logical = validate_logical_path(str(artifact.get("name", Path(artifact["path"]).name)))
        destination = resolved_output / logical
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if destination.parent.resolve(strict=True) != destination.parent:
            raise PinError(f"materialization path contains a symbolic link: {destination}")
        shutil.copyfile(Path(artifact["path"]), destination, follow_symlinks=False)
        if sha256_file(destination) != artifact["sha256"]:
            raise PinError(f"materialized artifact changed: {logical}")
        # The retained object is immutable. A materialization is a transient
        # staging copy which must remain writable for operations such as code
        # signing without ever mutating the shared retained object.
        os.chmod(destination, int(artifact["mode"]) | stat.S_IWUSR)


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
                verify_source=not options.retained_only,
            )
            if not options.quiet:
                print(receipt["receipt_sha256"])
        elif options.action == "value":
            receipt = verify_receipt(options.receipt, verify_source=False)
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
        elif options.action == "materialize":
            materialize_receipt(options.receipt, options.output)
        elif options.action == "lookup":
            receipt = lookup_receipt(options)
            print(receipt["receipt_sha256"])
        else:  # pragma: no cover - argparse enforces the action.
            raise AssertionError(options.action)
    except (OSError, PinError) as error:
        if not getattr(options, "quiet", False):
            print(f"stack pin error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
