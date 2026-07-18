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
#   check-compose-memory-byte-precision.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#               Docker Engine dry-run confirmation is performed when a daemon
#               is available; Compose config parity is always required.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It verifies
# Docker Compose V2 preserves a byte-granular mem_limit value in config output
# and accepts it for local orchestration. It then verifies container-compose
# retains the exact byte count in its normalized model and runtime command.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_DAEMON_AVAILABLE=0
FIXTURE_DIR=""
PROJECT_NAME="cc-memory-bytes-$RANDOM"
readonly MEMORY_BYTES=209715201

# Print an informational line to stdout.
info() {
    printf '%s\n' "$*"
}

# Print a warning to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Show usage extracted from the top-of-file help block.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-memory-byte-precision.sh/$SCRIPT_NAME/"
}

# Parse command-line options.
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

# Skip optional parity checks, or fail when strict mode is active.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose byte-precise memory parity check"
    exit 0
}

# Resolve the Docker Compose command used as the parity oracle.
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

# Ensure required local tools are available.
check_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Docker Compose config rendering is independent of an Engine daemon. Its
# --dry-run up output, however, still queries the daemon. Keep the local check
# deterministic on developer Macs without Docker Desktop/Colima while using the
# stronger Engine-backed assertion whenever one is running.
detect_docker_daemon() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        DOCKER_DAEMON_AVAILABLE=1
        return
    fi

    info 'Docker daemon unavailable; checking Docker Compose config parity without Engine dry-run output.'
}

# Create a fixture one byte above 200 MiB. The non-MiB value exposes any
# accidental conversion to an integral mebibyte before runtime projection.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-memory-bytes.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: alpine:3.20
    mem_limit: 209715201b
YAML
}

# Remove temporary fixture files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose preserves the exact hard memory limit in its public
# Compose-spec config model.
assert_docker_config_preserves_memory_bytes() {
    local path="$1"

    python3 - "$path" "$MEMORY_BYTES" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = str(sys.argv[2])
value = doc.get("services", {}).get("api", {}).get("mem_limit")
if str(value) != expected:
    raise SystemExit(f"mem_limit = {value!r}, want {expected!r}")
PY
}

# Assert container-compose retains the exact byte count in its normalized
# service model.
assert_container_config_preserves_memory_bytes() {
    local path="$1"

    python3 - "$path" "$MEMORY_BYTES" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = str(sys.argv[2])
value = doc.get("services", {}).get("api", {}).get("memLimit")
if value != expected:
    raise SystemExit(f"memLimit = {value!r}, want {expected!r}")
PY
}

# Return failure unless a dry-run container command contains the exact generic
# memory argument. Both quoted and plain command renderings are accepted so the
# assertion remains independent of the reporter formatter.
dry_run_projects_memory_bytes() {
    local output_path="$1"

    grep -F -- "--memory '$MEMORY_BYTES'" "$output_path" >/dev/null \
        || grep -F -- "--memory $MEMORY_BYTES" "$output_path" >/dev/null
}

# Exercise Docker Compose as the local-mode parity baseline.
expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"
    local dry_run_output="$FIXTURE_DIR/docker-compose-dry-run.txt"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_docker_config_preserves_memory_bytes "$config_output"

    if ((DOCKER_DAEMON_AVAILABLE == 0)); then
        return
    fi

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start api >"$dry_run_output" 2>&1
    if ! grep -F "Container $PROJECT_NAME-api-1 Created" "$dry_run_output" >/dev/null; then
        error 'Docker Compose did not accept the byte-precise memory limit in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
}

# Exercise container-compose against the same fixture.
expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local dry_run_output="$FIXTURE_DIR/container-compose-dry-run.txt"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_container_config_preserves_memory_bytes "$config_output"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start api >"$dry_run_output" 2>&1
    if ! grep -F "container create --name $PROJECT_NAME-api-1" "$dry_run_output" >/dev/null; then
        error 'container-compose did not accept the byte-precise memory limit in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
    if ! dry_run_projects_memory_bytes "$dry_run_output"; then
        error 'container-compose did not retain the exact memory byte count in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
}

# Run the parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    detect_docker_daemon
    create_fixture
    trap cleanup EXIT

    expect_docker_behavior
    expect_container_behavior

    info 'Docker Compose config and container-compose byte-precise memory parity passed.'
}

main "$@"
