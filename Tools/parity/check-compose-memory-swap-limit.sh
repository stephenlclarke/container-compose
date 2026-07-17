#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-memory-swap-limit.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, the Docker daemon, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to a
#                      working "docker compose" plugin when available,
#                      otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It validates
# Docker Compose V2 handling for service `memswap_limit`, checks Docker Engine
# HostConfig projection for explicit and unlimited values, and verifies that
# container-compose config plus dry-run output preserve Docker's default
# memory-plus-swap behavior when only `mem_limit` is supplied.

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
EXPLICIT_FILE=""
UNLIMITED_FILE=""
DEFAULT_FILE=""
PROJECT_PREFIX="container-compose-memory-swap-$RANDOM-$$"

# Print an informational line to stdout.
info() {
    printf '%s\n' "$*"
}

# Print a warning line to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error line to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print usage text extracted from the top of this script.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-memory-swap-limit.sh/$SCRIPT_NAME/"
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

# Exit cleanly for optional local runtime dependencies, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker/container-compose memory-swap parity check"
    exit 0
}

# Locate Docker Compose V2, accepting either plugin or standalone command form.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose --help 2>&1 | grep -q 'Usage:.*docker compose' && docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is not available'
    fi
}

# Ensure required local tools are available.
check_tools() {
    detect_docker_compose

    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker daemon is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create small Compose fixtures for explicit, unlimited, and default swap.
create_fixtures() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-memory-swap.XXXXXX")"
    EXPLICIT_FILE="$FIXTURE_DIR/explicit.yml"
    UNLIMITED_FILE="$FIXTURE_DIR/unlimited.yml"
    DEFAULT_FILE="$FIXTURE_DIR/default.yml"

    cat >"$EXPLICIT_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    mem_limit: 64m
    memswap_limit: 128m
YAML

    cat >"$UNLIMITED_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    mem_limit: 64m
    memswap_limit: -1
YAML

    cat >"$DEFAULT_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    mem_limit: 64m
YAML
}

# Remove runtime containers and temporary fixture files.
cleanup() {
    local suffix
    local file

    for suffix in explicit unlimited default; do
        case "$suffix" in
            explicit) file="$EXPLICIT_FILE" ;;
            unlimited) file="$UNLIMITED_FILE" ;;
            default) file="$DEFAULT_FILE" ;;
        esac
        if [[ -n "$file" ]]; then
            "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_PREFIX-$suffix" -f "$file" down --volumes --remove-orphans >/dev/null 2>&1 || true
        fi
    done

    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert JSON config contains a selected memory and swap byte value.
assert_config_limits() {
    local path="$1"
    local source="$2"
    local expected_swap="$3"

    python3 - "$path" "$source" "$expected_swap" <<'PY'
import json
import pathlib
import sys

path, source, expected_swap = sys.argv[1], sys.argv[2], int(sys.argv[3])
service = json.loads(pathlib.Path(path).read_text(encoding="utf-8")).get("services", {}).get("api", {})

def value(*keys):
    for key in keys:
        if key in service:
            return service[key]
    return None

memory = value("mem_limit", "memLimit")
swap = value("memswap_limit", "memSwapLimit")
if memory is None or int(memory) != 67_108_864:
    raise SystemExit(f"{source} memory limit = {memory!r}, want 67108864")
if swap is None or int(swap) != expected_swap:
    raise SystemExit(f"{source} memory swap limit = {swap!r}, want {expected_swap}")
PY
}

# Assert Docker Engine receives the expected explicit host configuration.
assert_docker_engine_limits() {
    local suffix="$1"
    local compose_file="$2"
    local expected_swap="$3"
    local project="$PROJECT_PREFIX-$suffix"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$project" -f "$compose_file" up -d --quiet-pull >/dev/null
    python3 - "$project" "$compose_file" "$expected_swap" "${DOCKER_COMPOSE_COMMAND[@]}" <<'PY'
import json
import subprocess
import sys

project, compose_file, expected_swap = sys.argv[1], sys.argv[2], int(sys.argv[3])
compose_command = sys.argv[4:]
container_id = subprocess.check_output(
    compose_command + ["-p", project, "-f", compose_file, "ps", "-q", "api"],
    text=True,
).strip()
if not container_id:
    raise SystemExit("Docker Compose did not create an api container")

host_config = json.loads(subprocess.check_output(["docker", "inspect", container_id], text=True))[0]["HostConfig"]
if host_config.get("Memory") != 67_108_864:
    raise SystemExit(f"Docker HostConfig.Memory = {host_config.get('Memory')!r}, want 67108864")
if host_config.get("MemorySwap") != expected_swap:
    raise SystemExit(f"Docker HostConfig.MemorySwap = {host_config.get('MemorySwap')!r}, want {expected_swap}")
PY
}

# Return the first dry-run create line for the api service container.
dry_run_api_line() {
    local output="$1"
    local project="$2"

    printf '%s\n' "$output" | grep -E "container (run|create) --name ${project}-api" | head -n 1 || true
}

# Return success when a dry-run line contains an expected memory-swap value.
line_has_memory_swap() {
    local line="$1"
    local expected="$2"

    printf '%s\n' "$line" | grep -F -- "--memory-swap '$expected'" >/dev/null \
        || printf '%s\n' "$line" | grep -F -- "--memory-swap $expected" >/dev/null
}

# Validate Docker Compose normalized config and its observable Engine projection.
validate_docker_behavior() {
    local explicit_config="$FIXTURE_DIR/docker-explicit.json"
    local unlimited_config="$FIXTURE_DIR/docker-unlimited.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_PREFIX-explicit" -f "$EXPLICIT_FILE" config --format json >"$explicit_config"
    assert_config_limits "$explicit_config" "Docker Compose explicit config" 134217728
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_PREFIX-unlimited" -f "$UNLIMITED_FILE" config --format json >"$unlimited_config"
    assert_config_limits "$unlimited_config" "Docker Compose unlimited config" -1

    assert_docker_engine_limits explicit "$EXPLICIT_FILE" 134217728
    assert_docker_engine_limits unlimited "$UNLIMITED_FILE" -1
}

# Validate container-compose config and dry-run command projection.
validate_container_compose_behavior() {
    local explicit_config="$FIXTURE_DIR/container-compose-explicit.json"
    local unlimited_config="$FIXTURE_DIR/container-compose-unlimited.json"
    local explicit_output
    local default_output
    local unlimited_output
    local explicit_line
    local default_line
    local unlimited_line
    local command
    local project

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_PREFIX-explicit" -f "$EXPLICIT_FILE" config --format json >"$explicit_config"
    assert_config_limits "$explicit_config" "container-compose explicit config" 134217728
    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_PREFIX-unlimited" -f "$UNLIMITED_FILE" config --format json >"$unlimited_config"
    assert_config_limits "$unlimited_config" "container-compose unlimited config" -1

    for command in up create run; do
        project="$PROJECT_PREFIX-explicit"
        if [[ "$command" == run ]]; then
            explicit_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$project" -f "$EXPLICIT_FILE" run api true)"
        else
            explicit_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$project" -f "$EXPLICIT_FILE" "$command" api)"
        fi
        explicit_line="$(dry_run_api_line "$explicit_output" "$project")"
        if [[ -z "$explicit_line" ]] || ! line_has_memory_swap "$explicit_line" 134217728; then
            error "container-compose dry-run $command did not render --memory-swap 134217728"
            printf '%s\n' "$explicit_output" >&2
            return 1
        fi
    done

    default_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_PREFIX-default" -f "$DEFAULT_FILE" up api)"
    default_line="$(dry_run_api_line "$default_output" "$PROJECT_PREFIX-default")"
    if [[ -z "$default_line" ]] || ! line_has_memory_swap "$default_line" 134217728; then
        error 'container-compose dry-run up did not render Docker default --memory-swap 134217728'
        printf '%s\n' "$default_output" >&2
        return 1
    fi

    unlimited_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_PREFIX-unlimited" -f "$UNLIMITED_FILE" up api)"
    unlimited_line="$(dry_run_api_line "$unlimited_output" "$PROJECT_PREFIX-unlimited")"
    if [[ -z "$unlimited_line" ]] || ! line_has_memory_swap "$unlimited_line" -1; then
        error 'container-compose dry-run up did not render --memory-swap -1'
        printf '%s\n' "$unlimited_output" >&2
        return 1
    fi
}

# Script entry point.
main() {
    parse_args "$@"
    check_tools
    create_fixtures
    trap cleanup EXIT

    validate_docker_behavior
    validate_container_compose_behavior
    info "memory-swap parity check passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main "$@"
