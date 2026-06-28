#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright (c) 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-build-builder.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It verifies
# Docker Compose V2 accepts `build --builder default --print` without a daemon,
# then verifies container-compose accepts the same default-builder spelling,
# renders the same service bake target, and still rejects non-default builder
# names before side effects.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""

# Print an informational message to stdout.
info() {
    printf '%s\n' "$*"
}

# Print a warning message to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print usage text extracted from the top of this script.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-build-builder.sh/$SCRIPT_NAME/"
}

# Parse command-line flags.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict)
                STRICT=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
}

# Either fail in strict mode or skip the local-only parity check.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose build-builder parity check"
    exit 0
}

# Locate Docker Compose V2, accepting either plugin or standalone command form.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is not available'
    fi
}

# Check local tools needed by the comparison.
check_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a minimal build project that can be printed without a Docker daemon.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-build-builder.XXXXXX")"
    mkdir -p "$FIXTURE_DIR/api"
    cat >"$FIXTURE_DIR/api/Dockerfile" <<'DOCKERFILE'
FROM scratch
DOCKERFILE
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: example/api:latest
    build:
      context: ./api
YAML
}

# Remove temporary fixture files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert a bake JSON document contains the expected service build target.
assert_bake_target() {
    local path="$1"
    local source="$2"

    python3 - "$path" "$source" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = sys.argv[2]
doc = json.loads(path.read_text(encoding="utf-8"))
targets = doc.get("group", {}).get("default", {}).get("targets")
if targets != ["api"]:
    raise SystemExit(f"{source} rendered default targets {targets!r}, want ['api']")
target = doc.get("target", {}).get("api")
if not isinstance(target, dict):
    raise SystemExit(f"{source} did not render an api target")
if target.get("tags") != ["example/api:latest"]:
    raise SystemExit(f"{source} rendered tags {target.get('tags')!r}")
if "builder" in target:
    raise SystemExit(f"{source} leaked a builder field into bake JSON")
if target.get("output") != ["type=docker"]:
    raise SystemExit(f"{source} rendered output {target.get('output')!r}")
PY
}

# Assert Docker Compose accepts the explicit default builder in print mode.
expect_docker_default_builder_print() {
    local output="$FIXTURE_DIR/docker-compose-builder.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build --builder default --print api >"$output"
    assert_bake_target "$output" 'Docker Compose'
}

# Assert container-compose accepts the same explicit default-builder spelling.
expect_container_default_builder_print() {
    local output="$FIXTURE_DIR/container-compose-builder.json"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build --builder default --print api >"$output"
    assert_bake_target "$output" 'container-compose'
}

# Assert non-default builder names fail before build side effects.
expect_container_named_builder_rejected() {
    local output
    local command_status

    set +e
    output="$("$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build --builder remote --print api 2>&1)"
    command_status=$?
    set -e

    if [[ "$command_status" -eq 0 ]]; then
        error 'container-compose accepted build --builder remote; expected unsupported-feature failure'
        return 1
    fi
    if [[ "$output" != *"build --builder 'remote'; only the default apple/container builder is supported"* ]]; then
        error 'container-compose build --builder remote did not report the expected unsupported-feature message'
        printf '%s\n' "$output" >&2
        return 1
    fi
}

# Run the local-only Docker Compose V2 parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT

    expect_docker_default_builder_print
    expect_container_default_builder_print
    expect_container_named_builder_rejected

    info 'Docker Compose build-builder parity passed.'
}

main "$@"
