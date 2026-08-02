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

"""Render and validate the Container-family programme progress register."""

from __future__ import annotations

import argparse
import json
import os
import pwd
import re
import subprocess
import sys
from datetime import date
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable
from urllib.parse import quote, urlparse


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_REGISTER = ROOT / "docs/parity/PROGRAMME-PROGRESS.json"
DEFAULT_RENDERED = ROOT / "docs/parity/PROGRAMME-PROGRESS.md"

FULL_SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DESIGN_ID_PATTERN = re.compile(r"^[A-Z][A-Z0-9-]*$")
ITEM_ID_PATTERN = re.compile(r"^[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+$")
ITEM_PREFIX_PATTERN = re.compile(r"^[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*-?$")
ANCHOR_PATTERN = re.compile(r'<a id="([a-z][a-z0-9-]*)"></a>')
SAFE_REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

ALLOWED_STATES = ("not started", "in progress", "blocked", "verified")
ALLOWED_KINDS = {"workflow", "coherent", "residual", "focused"}
ALLOWED_DISPOSITIONS = {"updated", "reviewed unchanged", "not applicable"}
ALLOWED_AUTHORITY_KINDS = {
    "delivery",
    "quality",
    "review",
    "test",
}
REQUIRED_NON_DESIGN_AUTHORITIES = {
    "docs/container-family-development-cycle.md",
}
EXPECTED_PROGRAMME_BASE = "6a0a7e608632a7e4b1fd05f50f3f687370325e88"
TRUSTED_REPOSITORY_LOCATIONS = {
    "stephenlclarke/container": ("CONTAINER_STACK_REPO", "container"),
    "stephenlclarke/containerization": (
        "CONTAINERIZATION_STACK_REPO",
        "containerization",
    ),
    "stephenlclarke/container-builder-shim": (
        "CONTAINER_BUILDER_SHIM_STACK_REPO",
        "container-builder-shim",
    ),
    "stephenlclarke/container-k8s": (
        "CONTAINER_K8S_STACK_REPO",
        "container-k8s",
    ),
    "stephenlclarke/homebrew-tap": ("HOMEBREW_TAP_REPO", "homebrew-tap"),
}
COMPOSE_REPOSITORY = "stephenlclarke/container-compose"
SUPPORTED_REPOSITORIES = frozenset(
    {COMPOSE_REPOSITORY, *TRUSTED_REPOSITORY_LOCATIONS}
)
FAMILY_REPOSITORIES = tuple(sorted(SUPPORTED_REPOSITORIES))
COMPOSE_ONLY_REPOSITORIES = (COMPOSE_REPOSITORY,)
WORKFLOW_REPOSITORY_OVERRIDES = (
    ("WORKFLOW-ENABLER-03", COMPOSE_ONLY_REPOSITORIES),
    ("WORKFLOW-ENABLER-04", COMPOSE_ONLY_REPOSITORIES),
    ("WORKFLOW-ENABLER-12", COMPOSE_ONLY_REPOSITORIES),
    ("WORKFLOW-ENABLER-13", COMPOSE_ONLY_REPOSITORIES),
    ("WORKFLOW-ENABLER-14", COMPOSE_ONLY_REPOSITORIES),
    ("WORKFLOW-ENABLER-15", COMPOSE_ONLY_REPOSITORIES),
)

AuthorityReader = Callable[[str], object | None]
GITHUB_CLI_PATHS = (
    Path("/opt/homebrew/bin/gh"),
    Path("/usr/local/bin/gh"),
    Path("/usr/bin/gh"),
)


def numbered_ids(prefix: str, first: int, last: int) -> tuple[str, ...]:
    return tuple(f"{prefix}{number:02d}" for number in range(first, last + 1))


# This is the reviewed programme boundary. Keeping it independent from both the
# design prose and state register means deleting the same row or required
# evidence dependency from both sources cannot silently shrink the programme.
EXPECTED_DESIGN_CONTRACTS = {
    "WORKFLOW": (
        "workflow",
        "docs/container-family-development-cycle.md",
        "WORKFLOW-ENABLER-",
        numbered_ids("WORKFLOW-ENABLER-", 1, 15),
        FAMILY_REPOSITORIES,
        WORKFLOW_REPOSITORY_OVERRIDES,
        (
            "BUILD.md",
            "CONTRIBUTING.md",
            "README.md",
            "docs/container-family-development-cycle.md",
        ),
    ),
    "COHERENT": (
        "coherent",
        "docs/coherent-container-family-parity-design.md",
        "COHERENT-WAVE-",
        (
            "COHERENT-WAVE-00",
            "COHERENT-WAVE-01",
            "COHERENT-WAVE-02",
            "COHERENT-WAVE-03",
            "COHERENT-WAVE-04",
            "COHERENT-WAVE-05",
            "COHERENT-WAVE-06",
            "COHERENT-WAVE-07",
            "COHERENT-WAVE-08",
            "COHERENT-WAVE-08B",
            "COHERENT-WAVE-09",
        ),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/runtime-capabilities.md",
        ),
    ),
    "CLOSURE": (
        "residual",
        "docs/remaining-macos-parity-closure-design.md",
        "CLOSURE-R",
        tuple(f"CLOSURE-R{number}" for number in range(6)),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/runtime-capabilities.md",
        ),
    ),
    "LIFECYCLE": (
        "focused",
        "docs/docker-lifecycle-states-actions-design.md",
        "LIFECYCLE-WP-",
        numbered_ids("LIFECYCLE-WP-", 1, 9),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/docker-lifecycle-states-actions-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/runtime-capabilities.md",
        ),
    ),
    "NAMESPACE": (
        "focused",
        "docs/shared-namespaces-privileged-isolation-design.md",
        "NAMESPACE-WP-",
        numbered_ids("NAMESPACE-WP-", 1, 10),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/runtime-capabilities.md",
            "docs/shared-namespaces-privileged-isolation-design.md",
        ),
    ),
    "NETWORK": (
        "focused",
        "docs/advanced-network-ipam-design.md",
        "NET-WP-",
        numbered_ids("NET-WP-", 1, 9),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/advanced-network-ipam-design.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/runtime-capabilities.md",
        ),
    ),
    "STORAGE": (
        "focused",
        "docs/non-local-volumes-advanced-mounts-api-socket-design.md",
        "STORAGE-WP-",
        numbered_ids("STORAGE-WP-", 1, 13),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/non-local-volumes-advanced-mounts-api-socket-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/runtime-capabilities.md",
        ),
    ),
    "SECURITY": (
        "focused",
        "docs/remaining-resource-security-controls-design.md",
        "SECURITY-WP-",
        numbered_ids("SECURITY-WP-", 1, 11),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/remaining-resource-security-controls-design.md",
            "docs/runtime-capabilities.md",
        ),
    ),
    "DEPLOY": (
        "focused",
        "docs/local-deploy-device-resource-subset-design.md",
        "DEPLOY-WP-",
        numbered_ids("DEPLOY-WP-", 1, 9),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/local-deploy-device-resource-subset-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/runtime-capabilities.md",
        ),
    ),
    "LOGGING": (
        "focused",
        "docs/docker-logging-driver-semantics-design.md",
        "LOGGING-WP-",
        numbered_ids("LOGGING-WP-", 1, 11),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/docker-logging-driver-semantics-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/runtime-capabilities.md",
        ),
    ),
    "MODEL": (
        "focused",
        "docs/model-runner-services-design.md",
        "MODEL-WP-",
        numbered_ids("MODEL-WP-", 1, 8),
        FAMILY_REPOSITORIES,
        (),
        (
            "STATUS.md",
            "docs/coherent-container-family-parity-design.md",
            "docs/model-runner-services-design.md",
            "docs/remaining-macos-parity-closure-design.md",
            "docs/runtime-capabilities.md",
        ),
    ),
}


class ProgressError(ValueError):
    """Raised when progress data or generated output is invalid."""


def git_result(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    """Run system Git without replacement objects or ambient Git configuration."""
    environment = {
        "GIT_CONFIG_COUNT": "0",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_PAGER": "cat",
        "GIT_TERMINAL_PROMPT": "0",
        "LANG": "C",
        "LC_ALL": "C",
    }
    return subprocess.run(
        [
            "/usr/bin/git",
            "--no-replace-objects",
            "-c",
            "core.attributesFile=/dev/null",
            "-c",
            "core.excludesFile=/dev/null",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "credential.helper=",
            *arguments,
        ],
        cwd=root,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
    )


def git_object_exists(root: Path, object_name: str) -> bool:
    return git_result(root, "cat-file", "-e", object_name).returncode == 0


def git_is_ancestor(root: Path, ancestor: str, descendant: str = "HEAD") -> bool:
    return (
        git_result(root, "merge-base", "--is-ancestor", ancestor, descendant)
        .returncode
        == 0
    )


def git_commit(root: Path, reference: str) -> str | None:
    """Resolve a reference to one full commit without accepting replacements."""
    result = git_result(root, "rev-parse", "--verify", f"{reference}^{{commit}}")
    commit = result.stdout.strip()
    if result.returncode != 0 or FULL_SHA_PATTERN.fullmatch(commit) is None:
        return None
    return commit


def git_is_direct_commit(root: Path, object_name: str) -> bool:
    """Require an object ID to name the resolved commit object itself."""
    return git_commit(root, object_name) == object_name


def default_accepted_through(root: Path) -> str:
    """Choose the local accepted-main boundary when CI did not provide one."""
    configured = os.environ.get("PROGRAMME_PROGRESS_ACCEPTED_THROUGH", "").strip()
    if configured:
        return configured
    for reference in ("refs/remotes/origin/main", "main"):
        if git_commit(root, reference) is not None:
            return reference
    return "HEAD"


def trusted_repository_roots(root: Path) -> dict[str, Path]:
    """Resolve fixed Container-family checkout locations without network access."""
    repositories = {COMPOSE_REPOSITORY: root}
    for repository, (environment_name, sibling_name) in (
        TRUSTED_REPOSITORY_LOCATIONS.items()
    ):
        configured = os.environ.get(environment_name, "").strip()
        path = Path(configured).expanduser() if configured else root.parent / sibling_name
        if path.exists():
            repositories[repository] = path.resolve()
    return repositories


def github_repository_from_remote(url: str) -> str | None:
    """Return the GitHub owner/repository identity represented by a remote URL."""
    candidate = url.strip()
    if candidate.startswith("git@github.com:"):
        path = candidate.removeprefix("git@github.com:")
    else:
        parsed = urlparse(candidate)
        if parsed.hostname != "github.com" or parsed.scheme not in {"https", "ssh"}:
            return None
        path = parsed.path.removeprefix("/")
    path = path.removesuffix("/").removesuffix(".git")
    if SAFE_REPOSITORY_PATTERN.fullmatch(path) is None:
        return None
    return path


def checkout_repository_remotes(root: Path) -> dict[str, set[str]]:
    """Map checkout-local GitHub identities to their configured remote names."""
    result = git_result(root, "config", "--get-regexp", r"^remote\..*\.url$")
    if result.returncode != 0:
        return {}
    repositories: dict[str, set[str]] = {}
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) != 2:
            continue
        key_match = re.fullmatch(r"remote\.(.+)\.url", fields[0])
        identity = github_repository_from_remote(fields[1])
        if key_match is not None and identity is not None:
            repositories.setdefault(identity, set()).add(key_match.group(1))
    return repositories


def commit_is_accepted_by_remote_main(
    root: Path, commit: str, remote_names: set[str]
) -> bool:
    """Require a commit to be contained in a fetched main for an identified remote."""
    for remote_name in sorted(remote_names):
        reference = f"refs/remotes/{remote_name}/main"
        if git_object_exists(root, f"{reference}^{{commit}}") and git_is_ancestor(
            root, commit, reference
        ):
            return True
    return False


def validate_repository_head(
    repository: str,
    commit: str,
    repository_roots: dict[str, Path],
    context: str,
) -> list[str]:
    """Verify a recorded head in an authenticated repository-specific checkout."""
    checkout = repository_roots.get(repository)
    if checkout is None:
        return [f"{context} has no trusted repository checkout"]
    remote_names = checkout_repository_remotes(checkout).get(repository, set())
    if not remote_names:
        return [f"{context} trusted checkout does not identify {repository}"]
    if not git_object_exists(checkout, commit):
        return [f"{context} is not available in the trusted checkout: {commit}"]
    if not git_is_direct_commit(checkout, commit):
        return [f"{context} does not identify a commit object directly: {commit}"]
    if not commit_is_accepted_by_remote_main(checkout, commit, remote_names):
        return [
            f"{context} is not accepted by fetched {repository} main: {commit}"
        ]
    return []


def reject_duplicate_json_keys(
    pairs: list[tuple[str, object]],
) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ProgressError(f"progress register repeats JSON key: {key}")
        result[key] = value
    return result


def reject_json_constant(value: str) -> object:
    raise ProgressError(f"progress register contains invalid JSON number: {value}")


def load_register(path: Path) -> dict[str, object]:
    try:
        payload = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_json_keys,
            parse_constant=reject_json_constant,
        )
    except ProgressError:
        raise
    except (OSError, json.JSONDecodeError) as error:
        raise ProgressError(f"could not read progress register: {error}") from error
    if not isinstance(payload, dict):
        raise ProgressError("progress register must be a JSON object")
    return payload


def safe_relative_path(value: object, *, prefix: str | None = None) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        return None
    normalized = path.as_posix()
    if normalized != value:
        return None
    if prefix is not None and not normalized.startswith(prefix):
        return None
    return normalized


def natural_key(value: str) -> tuple[object, ...]:
    return tuple(
        int(part) if part.isdigit() else part
        for part in re.split(r"(\d+)", value)
    )


def is_calendar_date(value: object) -> bool:
    if not isinstance(value, str) or DATE_PATTERN.fullmatch(value) is None:
        return False
    try:
        date.fromisoformat(value)
    except ValueError:
        return False
    return True


def is_nonempty_single_line(value: object) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and "\n" not in value
        and "\r" not in value
    )


def exact_keys(
    value: dict[str, object], expected: set[str], context: str
) -> list[str]:
    actual = set(value)
    errors: list[str] = []
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing:
        errors.append(f"{context} is missing keys: {', '.join(missing)}")
    if unexpected:
        errors.append(
            f"{context} has unsupported keys: {', '.join(unexpected)}"
        )
    return errors


def validate_repository_requirements(
    value: object, context: str
) -> tuple[list[str], tuple[str, ...]]:
    """Validate one sorted, explicit set of repositories required for evidence."""
    errors: list[str] = []
    repositories: list[str] = []
    if not isinstance(value, list) or not value:
        return [f"{context} must be a non-empty array"], ()
    if all(isinstance(repository, str) for repository in value) and value != sorted(
        value
    ):
        errors.append(f"{context} must be sorted")
    for index, repository in enumerate(value):
        if not isinstance(repository, str) or repository not in SUPPORTED_REPOSITORIES:
            errors.append(
                f"{context}[{index}] must name a supported Container-family repository"
            )
            continue
        if repository in repositories:
            errors.append(f"{context} repeats {repository}")
            continue
        repositories.append(repository)
    if COMPOSE_REPOSITORY not in repositories:
        errors.append(f"{context} must include {COMPOSE_REPOSITORY}")
    return errors, tuple(repositories)


def validate_designs(
    designs_value: object,
    root: Path,
) -> tuple[
    list[str],
    dict[str, str],
    set[str],
    dict[str, set[str]],
    dict[str, set[str]],
]:
    errors: list[str] = []
    states: dict[str, str] = {}
    verified: set[str] = set()
    documentation_dependencies: dict[str, set[str]] = {}
    repository_dependencies: dict[str, set[str]] = {}
    design_ids: set[str] = set()
    design_contracts: dict[
        str,
        tuple[
            object,
            object,
            object,
            set[str],
            tuple[str, ...],
            tuple[tuple[str, tuple[str, ...]], ...],
            tuple[str, ...],
        ],
    ] = {}
    paths: set[str] = set()
    registered_anchors: set[str] = set()

    if not isinstance(designs_value, list) or not designs_value:
        return (
            ["designs must be a non-empty array"],
            states,
            verified,
            documentation_dependencies,
            repository_dependencies,
        )

    for index, design_value in enumerate(designs_value):
        context = f"designs[{index}]"
        if not isinstance(design_value, dict):
            errors.append(f"{context} must be an object")
            continue
        errors.extend(
            exact_keys(
                design_value,
                {
                    "id",
                    "title",
                    "kind",
                    "path",
                    "itemPrefix",
                    "documentationDependencies",
                    "requiredRepositories",
                    "repositoryRequirementOverrides",
                    "items",
                },
                context,
            )
        )
        design_id = design_value.get("id")
        title = design_value.get("title")
        kind = design_value.get("kind")
        path_value = design_value.get("path")
        prefix = design_value.get("itemPrefix")
        dependencies_value = design_value.get("documentationDependencies")
        required_repositories_value = design_value.get("requiredRepositories")
        repository_overrides_value = design_value.get(
            "repositoryRequirementOverrides"
        )
        items_value = design_value.get("items")

        if not isinstance(design_id, str) or DESIGN_ID_PATTERN.fullmatch(
            design_id
        ) is None:
            errors.append(f"{context}.id must be a stable uppercase identifier")
        elif design_id in design_ids:
            errors.append(f"duplicate design id: {design_id}")
        else:
            design_ids.add(design_id)
        if not is_nonempty_single_line(title):
            errors.append(f"{context}.title must be a non-empty single line")
        if not isinstance(kind, str) or kind not in ALLOWED_KINDS:
            errors.append(f"{context}.kind must be one of {sorted(ALLOWED_KINDS)}")
        path = safe_relative_path(path_value, prefix="docs/")
        if path is None or not path.endswith(".md"):
            errors.append(f"{context}.path must be a safe Markdown path under docs/")
        elif path in paths:
            errors.append(f"duplicate design path: {path}")
        else:
            paths.add(path)
        if not isinstance(prefix, str) or ITEM_PREFIX_PATTERN.fullmatch(
            prefix
        ) is None:
            errors.append(f"{context}.itemPrefix must be an uppercase ID prefix")
        dependencies: set[str] = set()
        if not isinstance(dependencies_value, list) or not dependencies_value:
            errors.append(
                f"{context}.documentationDependencies must be a non-empty array"
            )
        else:
            if all(isinstance(item, str) for item in dependencies_value) and (
                dependencies_value != sorted(dependencies_value)
            ):
                errors.append(
                    f"{context}.documentationDependencies must be sorted"
                )
            for dependency_index, dependency_value in enumerate(
                dependencies_value
            ):
                dependency = safe_relative_path(dependency_value)
                if dependency is None:
                    errors.append(
                        f"{context}.documentationDependencies[{dependency_index}] "
                        "is unsafe"
                    )
                    continue
                if dependency in dependencies:
                    errors.append(
                        f"{context}.documentationDependencies repeats {dependency}"
                    )
                dependencies.add(dependency)
                if not (root / dependency).is_file():
                    errors.append(
                        f"{context}.documentationDependencies is missing: "
                        f"{dependency}"
                    )

        repository_errors, required_repositories = (
            validate_repository_requirements(
                required_repositories_value,
                f"{context}.requiredRepositories",
            )
        )
        errors.extend(repository_errors)

        design_items: set[str] = set()
        if not isinstance(items_value, dict):
            errors.append(f"{context}.items must be an object")
            continue
        errors.extend(exact_keys(items_value, set(ALLOWED_STATES), f"{context}.items"))
        for state in ALLOWED_STATES:
            item_values = items_value.get(state)
            if not isinstance(item_values, list):
                errors.append(f"{context}.items.{state} must be an array")
                continue
            if all(isinstance(item, str) for item in item_values) and (
                item_values != sorted(item_values, key=natural_key)
            ):
                errors.append(f"{context}.items.{state} must use natural ID order")
            for item in item_values:
                if not isinstance(item, str) or ITEM_ID_PATTERN.fullmatch(
                    item
                ) is None:
                    errors.append(
                        f"{context}.items.{state} contains an invalid stable ID: "
                        f"{item!r}"
                    )
                    continue
                if isinstance(prefix, str) and not item.startswith(prefix):
                    errors.append(
                        f"{item} does not start with {context}.itemPrefix {prefix}"
                    )
                if item in design_items:
                    errors.append(f"{item} has more than one state in {context}")
                if item in states:
                    errors.append(f"duplicate programme item id: {item}")
                design_items.add(item)
                states[item] = state
                documentation_dependencies[item] = set(dependencies)
                if state == "verified":
                    verified.add(item)
        if not design_items:
            errors.append(f"{context} must register at least one programme item")
        repository_overrides: dict[str, tuple[str, ...]] = {}
        if not isinstance(repository_overrides_value, dict):
            errors.append(f"{context}.repositoryRequirementOverrides must be an object")
        else:
            override_ids = list(repository_overrides_value)
            if all(isinstance(item_id, str) for item_id in override_ids) and (
                override_ids != sorted(override_ids, key=natural_key)
            ):
                errors.append(
                    f"{context}.repositoryRequirementOverrides must use natural ID order"
                )
            for item_id, repositories_value in repository_overrides_value.items():
                override_context = (
                    f"{context}.repositoryRequirementOverrides.{item_id}"
                )
                if item_id not in design_items:
                    errors.append(
                        f"{context}.repositoryRequirementOverrides names an "
                        f"unregistered item: {item_id}"
                    )
                override_errors, repositories = validate_repository_requirements(
                    repositories_value, override_context
                )
                errors.extend(override_errors)
                if isinstance(item_id, str):
                    repository_overrides[item_id] = repositories
        for item_id in design_items:
            repository_dependencies[item_id] = set(
                repository_overrides.get(item_id, required_repositories)
            )
        if isinstance(design_id, str) and design_id not in design_contracts:
            design_contracts[design_id] = (
                kind,
                path_value,
                prefix,
                design_items,
                required_repositories,
                tuple(
                    sorted(repository_overrides.items(), key=lambda entry: natural_key(entry[0]))
                ),
                tuple(sorted(dependencies)),
            )

        if path is None:
            continue
        design_path = root / path
        try:
            text = design_path.read_text(encoding="utf-8")
        except OSError as error:
            errors.append(f"could not read design {path}: {error}")
            continue
        anchors = ANCHOR_PATTERN.findall(text)
        duplicate_anchors = sorted(
            {anchor for anchor in anchors if anchors.count(anchor) > 1}
        )
        for anchor in duplicate_anchors:
            errors.append(f"design {path} repeats anchor #{anchor}")
        relevant_anchors = {
            anchor
            for anchor in anchors
            if isinstance(prefix, str) and anchor.startswith(prefix.lower())
        }
        expected_anchors = {item.lower() for item in design_items}
        for anchor in sorted(expected_anchors - relevant_anchors):
            errors.append(f"registered design anchor is missing: {path}#{anchor}")
        for anchor in sorted(relevant_anchors - expected_anchors):
            errors.append(f"design anchor is absent from the register: {path}#{anchor}")
        for anchor in sorted(relevant_anchors):
            if anchor in registered_anchors:
                errors.append(f"programme anchor is not globally unique: #{anchor}")
            registered_anchors.add(anchor)
            item_id = anchor.upper()
            position = text.find(f'<a id="{anchor}"></a>')
            following = text[position : position + 300]
            if f"`{item_id}`" not in following:
                errors.append(
                    f"design anchor {path}#{anchor} does not display `{item_id}`"
                )

    required_paths = {
        path
        for path in REQUIRED_NON_DESIGN_AUTHORITIES
        if (root / path).is_file()
    } | {
        path.relative_to(root).as_posix()
        for path in (root / "docs").glob("*design.md")
        if path.is_file()
    }
    for required_path in sorted(required_paths - paths):
        errors.append(
            f"active programme authority is absent from designs: {required_path}"
        )

    expected_design_ids = set(EXPECTED_DESIGN_CONTRACTS)
    actual_design_ids = set(design_contracts)
    for design_id in sorted(expected_design_ids - actual_design_ids):
        errors.append(f"required programme design is missing: {design_id}")
    for design_id in sorted(actual_design_ids - expected_design_ids):
        errors.append(f"unsupported programme design is registered: {design_id}")
    for design_id in sorted(expected_design_ids & actual_design_ids):
        (
            expected_kind,
            expected_path,
            expected_prefix,
            expected_items,
            expected_repositories,
            expected_overrides,
            expected_documentation,
        ) = (
            EXPECTED_DESIGN_CONTRACTS[design_id]
        )
        (
            kind,
            path,
            prefix,
            items,
            repositories,
            overrides,
            documentation,
        ) = design_contracts[design_id]
        if kind != expected_kind:
            errors.append(f"{design_id} must use kind {expected_kind}")
        if path != expected_path:
            errors.append(f"{design_id} must use design path {expected_path}")
        if prefix != expected_prefix:
            errors.append(f"{design_id} must use item prefix {expected_prefix}")
        expected_item_set = set(expected_items)
        for item_id in sorted(expected_item_set - items, key=natural_key):
            errors.append(f"required programme item is missing: {item_id}")
        for item_id in sorted(items - expected_item_set, key=natural_key):
            errors.append(f"unsupported programme item is registered: {item_id}")
        if repositories != expected_repositories:
            errors.append(
                f"{design_id} must use its reviewed required repository set: "
                f"{', '.join(expected_repositories)}"
            )
        if overrides != expected_overrides:
            errors.append(
                f"{design_id} must use its reviewed item repository overrides"
            )
        if documentation != expected_documentation:
            errors.append(
                f"{design_id} must use its reviewed documentation dependencies: "
                f"{', '.join(expected_documentation)}"
            )

    return (
        errors,
        states,
        verified,
        documentation_dependencies,
        repository_dependencies,
    )


def github_api_json(endpoint: str) -> object | None:
    """Read one fixed-host GitHub API resource without exposing credentials."""
    executable = next((path for path in GITHUB_CLI_PATHS if path.is_file()), None)
    if executable is None:
        return None
    account_home = pwd.getpwuid(os.getuid()).pw_dir
    environment = {
        "GH_PAGER": "cat",
        "HOME": account_home,
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    for credential_name in ("GH_TOKEN", "GITHUB_TOKEN"):
        credential = os.environ.get(credential_name)
        if credential:
            environment[credential_name] = credential
    try:
        result = subprocess.run(
            [str(executable), "api", "--hostname", "github.com", endpoint],
            env=environment,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def validate_pull_authority(
    repository: str,
    number: str,
    fragment: str,
    url: str,
    expected_head: str,
    authority_reader: AuthorityReader,
    context: str,
) -> list[str]:
    """Verify a merged pull request and any named comment against GitHub."""
    pull_endpoint = f"repos/{repository}/pulls/{number}"
    pull = authority_reader(pull_endpoint)
    expected_pull_url = f"https://github.com/{repository}/pull/{number}"
    if not isinstance(pull, dict):
        return [f"{context}.url could not verify GitHub resource: {url}"]
    if (
        pull.get("html_url") != expected_pull_url
        or pull.get("merged") is not True
        or pull.get("merge_commit_sha") != expected_head
    ):
        return [
            f"{context}.url is not a merged pull request for exact head "
            f"{expected_head}: {url}"
        ]
    if not fragment:
        return []

    issue_comment = re.fullmatch(r"issuecomment-([1-9][0-9]*)", fragment)
    review_comment = re.fullmatch(r"discussion_r([1-9][0-9]*)", fragment)
    if issue_comment is not None:
        comment_endpoint = (
            f"repos/{repository}/issues/comments/{issue_comment.group(1)}"
        )
        comment = authority_reader(comment_endpoint)
        expected_parent = (
            f"https://api.github.com/repos/{repository}/issues/{number}"
        )
        parent_key = "issue_url"
    elif review_comment is not None:
        comment_endpoint = (
            f"repos/{repository}/pulls/comments/{review_comment.group(1)}"
        )
        comment = authority_reader(comment_endpoint)
        expected_parent = (
            f"https://api.github.com/repos/{repository}/pulls/{number}"
        )
        parent_key = "pull_request_url"
    else:
        return [f"{context}.url has an unsupported pull-request fragment: {url}"]
    if not isinstance(comment, dict):
        return [f"{context}.url could not verify GitHub resource: {url}"]
    if comment.get("html_url") != url or comment.get(parent_key) != expected_parent:
        return [f"{context}.url does not identify the named pull request: {url}"]
    return []


def validate_run_authority(
    repository: str,
    run_id: str,
    url: str,
    expected_head: str,
    authority_reader: AuthorityReader,
    context: str,
) -> list[str]:
    """Verify one successful exact-head GitHub Actions run."""
    run = authority_reader(f"repos/{repository}/actions/runs/{run_id}")
    if not isinstance(run, dict):
        return [f"{context}.url could not verify GitHub resource: {url}"]
    run_repository = run.get("repository")
    if (
        run.get("html_url") != url
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or run.get("head_sha") != expected_head
        or not isinstance(run_repository, dict)
        or run_repository.get("full_name") != repository
    ):
        return [
            f"{context}.url is not a successful GitHub Actions run for exact "
            f"head {expected_head}: {url}"
        ]
    return []


def validate_authority(
    authority: object,
    repository_heads: dict[object, object],
    authority_reader: AuthorityReader,
    context: str,
) -> list[str]:
    """Require a kind-specific, existing authority in an affected repository."""
    if not isinstance(authority, dict):
        return [f"{context} must be an object"]
    errors = exact_keys(authority, {"kind", "url"}, context)
    kind = authority.get("kind")
    url = authority.get("url")
    if not isinstance(kind, str) or kind not in ALLOWED_AUTHORITY_KINDS:
        errors.append(
            f"{context}.kind must be one of {sorted(ALLOWED_AUTHORITY_KINDS)}"
        )
        return errors
    if not isinstance(url, str):
        errors.append(f"{context}.url must be an HTTPS URL")
        return errors
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or parsed.params
        or parsed.query
        or any(character.isspace() for character in url)
    ):
        errors.append(f"{context}.url must use the trusted GitHub HTTPS service")
        return errors

    parts = parsed.path.split("/")
    if len(parts) < 5 or parts[0] != "":
        errors.append(f"{context}.url has an unsupported authority path: {url}")
        return errors
    repository = f"{parts[1]}/{parts[2]}"
    expected_head = repository_heads.get(repository)
    if (
        SAFE_REPOSITORY_PATTERN.fullmatch(repository) is None
        or repository not in SUPPORTED_REPOSITORIES
        or not isinstance(expected_head, str)
    ):
        errors.append(
            f"{context}.url must identify an affected trusted repository: {url}"
        )
        return errors

    resource = parts[3]
    if resource == "commit" and len(parts) == 5:
        commit = parts[4]
        if kind != "delivery" or parsed.fragment:
            errors.append(
                f"{context}.url is not valid for {kind} authority evidence: {url}"
            )
            return errors
        if FULL_SHA_PATTERN.fullmatch(commit) is None or commit != expected_head:
            errors.append(
                f"{context}.url does not identify the affected repository head "
                f"{expected_head}: {url}"
            )
            return errors
        return errors

    if (
        resource == "pull"
        and len(parts) == 5
        and re.fullmatch(r"[1-9][0-9]*", parts[4]) is not None
    ):
        if kind not in {"delivery", "review"}:
            errors.append(
                f"{context}.url is not valid for {kind} authority evidence: {url}"
            )
            return errors
        errors.extend(
            validate_pull_authority(
                repository,
                parts[4],
                parsed.fragment,
                url,
                expected_head,
                authority_reader,
                context,
            )
        )
        return errors

    if (
        resource == "actions"
        and len(parts) == 6
        and parts[4] == "runs"
        and re.fullmatch(r"[1-9][0-9]*", parts[5]) is not None
    ):
        if kind not in {"quality", "test"} or parsed.fragment:
            errors.append(
                f"{context}.url is not valid for {kind} authority evidence: {url}"
            )
            return errors
        errors.extend(
            validate_run_authority(
                repository,
                parts[5],
                url,
                expected_head,
                authority_reader,
                context,
            )
        )
        return errors

    errors.append(f"{context}.url has an unsupported authority path: {url}")
    return errors


def validate_evidence_entry(
    item_id: str,
    value: object,
    root: Path,
    required_documentation: set[str],
    required_repositories: set[str],
    accepted_through: str | None,
    repository_roots: dict[str, Path],
    authority_reader: AuthorityReader,
) -> list[str]:
    context = f"evidence.{item_id}"
    if not isinstance(value, dict):
        return [f"{context} must be an object"]
    errors = exact_keys(
        value,
        {
            "exactAcceptedHead",
            "repositoryHeads",
            "evidencePaths",
            "documentation",
            "authorities",
        },
        context,
    )
    head = value.get("exactAcceptedHead")
    if not isinstance(head, str) or FULL_SHA_PATTERN.fullmatch(head) is None:
        errors.append(f"{context}.exactAcceptedHead must be a full lowercase Git SHA")
        head = None
    elif not git_object_exists(root, head):
        errors.append(f"{context}.exactAcceptedHead is not available locally: {head}")
    elif not git_is_direct_commit(root, head):
        errors.append(
            f"{context}.exactAcceptedHead does not identify a commit object "
            f"directly: {head}"
        )
    elif not git_is_ancestor(root, head):
        errors.append(f"{context}.exactAcceptedHead is not an ancestor of HEAD: {head}")
    elif accepted_through is not None and not git_is_ancestor(
        root, head, accepted_through
    ):
        errors.append(
            f"{context}.exactAcceptedHead is newer than trusted accepted "
            f"checkpoint {accepted_through}: {head}"
        )

    repository_heads = value.get("repositoryHeads")
    if not isinstance(repository_heads, dict) or not repository_heads:
        errors.append(f"{context}.repositoryHeads must be a non-empty object")
    else:
        supplied_repositories = set(repository_heads)
        for repository in sorted(required_repositories - supplied_repositories):
            errors.append(
                f"{context}.repositoryHeads lacks required repository: {repository}"
            )
        for repository in sorted(
            supplied_repositories - required_repositories, key=str
        ):
            errors.append(
                f"{context}.repositoryHeads names an undeclared repository: "
                f"{repository}"
            )
        for repository, commit in repository_heads.items():
            if not isinstance(repository, str) or SAFE_REPOSITORY_PATTERN.fullmatch(
                repository
            ) is None:
                errors.append(f"{context}.repositoryHeads has an invalid repository")
                continue
            if not isinstance(commit, str) or FULL_SHA_PATTERN.fullmatch(
                commit
            ) is None:
                errors.append(
                    f"{context}.repositoryHeads.{repository} must be a full Git SHA"
                )
                continue
            errors.extend(
                validate_repository_head(
                    repository,
                    commit,
                    repository_roots,
                    f"{context}.repositoryHeads.{repository}",
                )
            )
        compose_head = repository_heads.get(COMPOSE_REPOSITORY)
        if head is not None and compose_head != head:
            errors.append(
                f"{context}.repositoryHeads must bind container-compose to "
                "exactAcceptedHead"
            )

    evidence_paths = value.get("evidencePaths")
    if not isinstance(evidence_paths, list) or not evidence_paths:
        errors.append(f"{context}.evidencePaths must be a non-empty array")
    else:
        if all(isinstance(path, str) for path in evidence_paths) and (
            evidence_paths != sorted(evidence_paths)
        ):
            errors.append(f"{context}.evidencePaths must be sorted")
        if all(isinstance(path, str) for path in evidence_paths) and len(
            evidence_paths
        ) != len(set(evidence_paths)):
            errors.append(f"{context}.evidencePaths must not contain duplicates")
        for index, path_value in enumerate(evidence_paths):
            path = safe_relative_path(path_value)
            if path is None:
                errors.append(f"{context}.evidencePaths[{index}] is unsafe")
            elif head is not None and not git_object_exists(root, f"{head}:{path}"):
                errors.append(
                    f"{context}.evidencePaths[{index}] is absent at {head}: {path}"
                )

    documentation = value.get("documentation")
    if not isinstance(documentation, list) or not documentation:
        errors.append(f"{context}.documentation must be a non-empty array")
    else:
        seen_paths: set[str] = set()
        for index, review in enumerate(documentation):
            review_context = f"{context}.documentation[{index}]"
            if not isinstance(review, dict):
                errors.append(f"{review_context} must be an object")
                continue
            errors.extend(
                exact_keys(
                    review,
                    {"path", "disposition", "reviewedAtHead", "rationale"},
                    review_context,
                )
            )
            path = safe_relative_path(review.get("path"))
            if path is None:
                errors.append(f"{review_context}.path is unsafe")
            elif path in seen_paths:
                errors.append(f"{context}.documentation repeats {path}")
            else:
                seen_paths.add(path)
            disposition = review.get("disposition")
            if (
                not isinstance(disposition, str)
                or disposition not in ALLOWED_DISPOSITIONS
            ):
                errors.append(
                    f"{review_context}.disposition must be one of "
                    f"{sorted(ALLOWED_DISPOSITIONS)}"
                )
            rationale = review.get("rationale")
            if not is_nonempty_single_line(rationale):
                errors.append(
                    f"{review_context}.rationale must be a non-empty single line"
                )
            reviewed_at = review.get("reviewedAtHead")
            if head is not None and reviewed_at != head:
                errors.append(
                    f"{review_context}.reviewedAtHead must equal exactAcceptedHead"
                )
            if path is not None and head is not None and not git_object_exists(
                root, f"{head}:{path}"
            ):
                errors.append(f"{review_context}.path is absent at {head}: {path}")
        for path in sorted(required_documentation - seen_paths):
            errors.append(
                f"{context} lacks review disposition for dependent documentation: "
                f"{path}"
            )

    authorities = value.get("authorities")
    if not isinstance(authorities, list) or not authorities:
        errors.append(f"{context}.authorities must be a non-empty array")
    else:
        for index, authority in enumerate(authorities):
            errors.extend(
                validate_authority(
                    authority,
                    repository_heads if isinstance(repository_heads, dict) else {},
                    authority_reader,
                    f"{context}.authorities[{index}]",
                )
            )
    return errors


def validate_blockers(
    blockers_value: object, states: dict[str, str]
) -> list[str]:
    errors: list[str] = []
    if not isinstance(blockers_value, dict):
        return ["blockers must be an object"]
    blocked = {item_id for item_id, state in states.items() if state == "blocked"}
    blocker_ids = set(blockers_value)
    for item_id in sorted(blocked - blocker_ids):
        errors.append(f"blocked item lacks owner/blocker/next action: {item_id}")
    for item_id in sorted(blocker_ids - blocked):
        state = states.get(item_id, "unregistered")
        errors.append(
            f"blocker metadata is only valid for blocked items: {item_id} ({state})"
        )
    for item_id in sorted(blocked & blocker_ids):
        context = f"blockers.{item_id}"
        blocker = blockers_value[item_id]
        if not isinstance(blocker, dict):
            errors.append(f"{context} must be an object")
            continue
        errors.extend(
            exact_keys(
                blocker,
                {"owner", "blocker", "nextAction", "nextReviewDate"},
                context,
            )
        )
        for key in ("owner", "blocker", "nextAction"):
            value = blocker.get(key)
            if not is_nonempty_single_line(value):
                errors.append(f"{context}.{key} must be a non-empty single line")
        review_date = blocker.get("nextReviewDate")
        if not is_calendar_date(review_date):
            errors.append(f"{context}.nextReviewDate must use YYYY-MM-DD")
    return errors


def validate_progress(
    payload: dict[str, object],
    root: Path,
    *,
    accepted_through: str = "HEAD",
    repository_roots: dict[str, Path] | None = None,
    authority_reader: AuthorityReader = github_api_json,
) -> list[str]:
    errors = exact_keys(
        payload,
        {
            "schemaVersion",
            "programmeBase",
            "generatedAt",
            "designs",
            "blockers",
            "evidence",
        },
        "progress register",
    )
    if payload.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    accepted_commit = git_commit(root, accepted_through)
    if accepted_commit is None:
        errors.append(
            "trusted accepted checkpoint is not an available commit: "
            f"{accepted_through}"
        )
    elif not git_is_ancestor(root, accepted_commit):
        errors.append(
            "trusted accepted checkpoint is not an ancestor of HEAD: "
            f"{accepted_commit}"
        )
        accepted_commit = None
    configured_repositories = dict(repository_roots or {})
    configured_repositories.setdefault(COMPOSE_REPOSITORY, root)
    authority_cache: dict[str, object | None] = {}

    def cached_authority_reader(endpoint: str) -> object | None:
        if endpoint not in authority_cache:
            authority_cache[endpoint] = authority_reader(endpoint)
        return authority_cache[endpoint]

    programme_base = payload.get("programmeBase")
    if not isinstance(programme_base, str) or FULL_SHA_PATTERN.fullmatch(
        programme_base
    ) is None:
        errors.append("programmeBase must be a full lowercase Git SHA")
    elif not git_object_exists(root, f"{programme_base}^{{commit}}"):
        errors.append(f"programmeBase is not available locally: {programme_base}")
    elif not git_is_ancestor(root, programme_base):
        errors.append(f"programmeBase is not an ancestor of HEAD: {programme_base}")
    if programme_base != EXPECTED_PROGRAMME_BASE:
        errors.append(
            "programmeBase must remain the reviewed programme root: "
            f"{EXPECTED_PROGRAMME_BASE}"
        )
    generated_at = payload.get("generatedAt")
    if not is_calendar_date(generated_at):
        errors.append("generatedAt must use YYYY-MM-DD")

    (
        design_errors,
        states,
        verified,
        documentation_dependencies,
        repository_dependencies,
    ) = validate_designs(payload.get("designs"), root)
    errors.extend(design_errors)
    errors.extend(validate_blockers(payload.get("blockers"), states))
    evidence = payload.get("evidence")
    if not isinstance(evidence, dict):
        errors.append("evidence must be an object")
        return errors
    evidence_ids = set(evidence)
    for item_id in sorted(verified - evidence_ids):
        errors.append(f"verified item lacks exact-head evidence: {item_id}")
    for item_id in sorted(evidence_ids - verified):
        state = states.get(item_id, "unregistered")
        errors.append(f"evidence is only valid for verified items: {item_id} ({state})")
    for item_id in sorted(verified & evidence_ids):
        errors.extend(
            validate_evidence_entry(
                item_id,
                evidence[item_id],
                root,
                documentation_dependencies.get(item_id, set()),
                repository_dependencies.get(item_id, set()),
                accepted_commit,
                configured_repositories,
                cached_authority_reader,
            )
        )
    return errors


def markdown_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("|", "\\|")


def immutable_path_url(head: str, path: str) -> str:
    return (
        "https://github.com/stephenlclarke/container-compose/blob/"
        f"{head}/{quote(path, safe='/')}"
    )


def commit_url(repository: str, head: str) -> str:
    return f"https://github.com/{repository}/commit/{head}"


def render_progress(payload: dict[str, object]) -> str:
    evidence = payload["evidence"]
    assert isinstance(evidence, dict)
    blockers = payload["blockers"]
    assert isinstance(blockers, dict)
    designs = payload["designs"]
    assert isinstance(designs, list)
    counts = {state: 0 for state in ALLOWED_STATES}
    for design in designs:
        assert isinstance(design, dict)
        items = design["items"]
        assert isinstance(items, dict)
        for state in ALLOWED_STATES:
            state_items = items[state]
            assert isinstance(state_items, list)
            counts[state] += len(state_items)

    lines = [
        "# Container-Family Programme Progress",
        "",
        "<!-- Generated by Tools/ci/programme-progress.py. Do not edit. -->",
        "",
        f"Programme base: `{payload['programmeBase']}`.",
        "",
        f"Register generated: {payload['generatedAt']}.",
        "",
        "| State | Count |",
        "| --- | ---: |",
    ]
    for state in ALLOWED_STATES:
        lines.append(f"| {state} | {counts[state]} |")

    for design in designs:
        assert isinstance(design, dict)
        title = str(design["title"])
        path = str(design["path"])
        lines.extend(
            [
                "",
                f"## {markdown_escape(title)}",
                "",
                f"Authority: [{path}](../{path.removeprefix('docs/')}).",
                "",
                "Dependent documentation: "
                + ", ".join(
                    f"`{dependency}`"
                    for dependency in design["documentationDependencies"]
                )
                + ".",
                "",
                "Default required repository heads: "
                + ", ".join(
                    f"`{repository}`"
                    for repository in design["requiredRepositories"]
                )
                + ".",
                "",
                "| Stable ID | State | Exact accepted head | Evidence / blocker |",
                "| --- | --- | --- | --- |",
            ]
        )
        repository_overrides = design["repositoryRequirementOverrides"]
        assert isinstance(repository_overrides, dict)
        if repository_overrides:
            override_text = "; ".join(
                f"`{item_id}`: "
                + ", ".join(f"`{repository}`" for repository in repositories)
                for item_id, repositories in repository_overrides.items()
            )
            lines[-2:-2] = [
                "Item-specific repository-head requirements: "
                + override_text
                + ".",
                "",
            ]
        items = design["items"]
        assert isinstance(items, dict)
        entries: list[tuple[str, str]] = []
        for state in ALLOWED_STATES:
            state_items = items[state]
            assert isinstance(state_items, list)
            entries.extend((str(item), state) for item in state_items)
        for item_id, state in sorted(entries, key=lambda entry: natural_key(entry[0])):
            anchor = item_id.lower()
            authority = f"../{path.removeprefix('docs/')}#{anchor}"
            item_link = f"[`{item_id}`]({authority})"
            head_text = "—"
            evidence_text = "—"
            evidence_value = evidence.get(item_id)
            if isinstance(evidence_value, dict):
                head = str(evidence_value["exactAcceptedHead"])
                head_text = f"`{head[:12]}`"
                evidence_text = f"[exact evidence](#evidence-{item_id.lower()})"
            blocker_value = blockers.get(item_id)
            if isinstance(blocker_value, dict):
                evidence_text = markdown_escape(
                    f"{blocker_value['owner']}: {blocker_value['blocker']}; "
                    f"next: {blocker_value['nextAction']}; review "
                    f"{blocker_value['nextReviewDate']}"
                )
            lines.append(
                f"| {item_link} | {state} | {head_text} | {evidence_text} |"
            )

    if evidence:
        lines.extend(["", "## Verified Evidence"])
    for item_id in sorted(evidence, key=natural_key):
        evidence_value = evidence[item_id]
        assert isinstance(evidence_value, dict)
        head = str(evidence_value["exactAcceptedHead"])
        lines.extend(
            [
                "",
                f'<a id="evidence-{item_id.lower()}"></a>',
                "",
                f"### `{item_id}`",
                "",
                "Exact accepted head: "
                f"[{head}]({commit_url('stephenlclarke/container-compose', head)}).",
                "",
                "Repository heads:",
                "",
            ]
        )
        repository_heads = evidence_value["repositoryHeads"]
        assert isinstance(repository_heads, dict)
        for repository, repository_head in sorted(repository_heads.items()):
            lines.append(
                f"- `{repository}`: "
                f"[{repository_head}]({commit_url(repository, str(repository_head))})"
            )
        lines.extend(["", "Evidence paths:", ""])
        evidence_paths = evidence_value["evidencePaths"]
        assert isinstance(evidence_paths, list)
        for path in evidence_paths:
            lines.append(f"- [{path}]({immutable_path_url(head, str(path))})")
        lines.extend(["", "Documentation review:", ""])
        documentation = evidence_value["documentation"]
        assert isinstance(documentation, list)
        for review in sorted(documentation, key=lambda value: str(value["path"])):
            assert isinstance(review, dict)
            path = str(review["path"])
            disposition = str(review["disposition"])
            rationale = str(review["rationale"])
            lines.append(
                f"- [{path}]({immutable_path_url(head, path)}): "
                f"`{disposition}` — {rationale}"
            )
        lines.extend(["", "Authorities:", ""])
        authorities = evidence_value["authorities"]
        assert isinstance(authorities, list)
        for authority in sorted(
            authorities,
            key=lambda value: (str(value["kind"]), str(value["url"])),
        ):
            assert isinstance(authority, dict)
            lines.append(f"- [{authority['kind']}]({authority['url']})")
    lines.append("")
    return "\n".join(lines)


def write_rendered(path: Path, rendered: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(rendered, encoding="utf-8")


def resolved_path(root: Path, path: Path) -> Path:
    return path if path.is_absolute() else root / path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--register", type=Path, default=DEFAULT_REGISTER)
    parser.add_argument("--rendered", type=Path, default=DEFAULT_RENDERED)
    parser.add_argument(
        "--accepted-through",
        help=(
            "trusted pre-change main/base commit; defaults to "
            "PROGRAMME_PROGRESS_ACCEPTED_THROUGH or the local main ref"
        ),
    )
    parser.add_argument("command", choices=("check", "render"))
    return parser


def report_errors(errors: Iterable[str]) -> None:
    for error in errors:
        print(error, file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = args.root.resolve()
    register_path = resolved_path(root, args.register)
    rendered_path = resolved_path(root, args.rendered)
    try:
        payload = load_register(register_path)
        accepted_through = args.accepted_through or default_accepted_through(root)
        errors = validate_progress(
            payload,
            root,
            accepted_through=accepted_through,
            repository_roots=trusted_repository_roots(root),
        )
        if errors:
            report_errors(errors)
            return 1
        rendered = render_progress(payload)
        if args.command == "render":
            write_rendered(rendered_path, rendered)
            return 0
        try:
            actual = rendered_path.read_text(encoding="utf-8")
        except OSError as error:
            print(
                f"could not read rendered progress register: {error}",
                file=sys.stderr,
            )
            return 1
        if actual != rendered:
            print(
                "rendered programme progress is stale; run "
                "make programme-progress-update",
                file=sys.stderr,
            )
            return 1
        return 0
    except ProgressError as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
