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
#   check-compose-bind-create-host-path.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It verifies
# Docker Compose V2 preserves `bind.create_host_path: false`, rejects a missing
# source for that explicit false policy, accepts the default create-host-path
# bind mount, and then verifies container-compose mirrors the CLI behavior.

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
PROJECT_NAME="cc-bind-path-$RANDOM"

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-bind-create-host-path.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker Compose bind create_host_path parity check"
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

    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker Engine is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a minimal Compose fixture with explicit and default bind policies.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-bind-create-host-path.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  defaulted:
    image: alpine:3.20
    command: ["true"]
    volumes:
      - type: bind
        source: ./defaulted
        target: /data
  required:
    image: alpine:3.20
    command: ["true"]
    volumes:
      - type: bind
        source: ./required
        target: /data
        bind:
          create_host_path: false
YAML
}

# Remove temporary fixture files and Docker Compose resources.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" \
            --project-directory "$FIXTURE_DIR" \
            -p "$PROJECT_NAME" \
            -f "$FIXTURE_DIR/compose.yml" \
            down -v --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose config preserves the explicit false bind policy.
assert_docker_config_preserves_bind_policy() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
required = doc.get("services", {}).get("required", {}).get("volumes", [{}])[0]
bind = required.get("bind") or {}
if bind.get("create_host_path") is not False:
    raise SystemExit(f"Docker Compose bind.create_host_path = {bind.get('create_host_path')!r}, want False")
PY
}

# Assert container-compose config preserves the explicit false bind policy.
assert_container_config_preserves_bind_policy() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
services = doc.get("services", {})
required = services.get("required", {}).get("volumes", [{}])[0]
bind = required.get("bind") or {}
normalized = required.get("bindCreateHostPath")
if bind.get("create_host_path") is not False and normalized is not False:
    raise SystemExit(
        "container-compose bind create_host_path policy "
        f"= raw {bind.get('create_host_path')!r}, normalized {normalized!r}; want False"
    )
PY
}

# Exercise Docker Compose as the local-mode parity baseline.
expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"
    local default_output="$FIXTURE_DIR/docker-compose-defaulted.txt"
    local required_output="$FIXTURE_DIR/docker-compose-required.txt"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_docker_config_preserves_bind_policy "$config_output"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start defaulted >"$default_output" 2>&1
    if ! grep -F "Container $PROJECT_NAME-defaulted-1 Created" "$default_output" >/dev/null; then
        error 'Docker Compose did not accept the default bind create_host_path policy'
        sed -n '1,120p' "$default_output" >&2
        return 1
    fi

    if "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start required >"$required_output" 2>&1; then
        error 'Docker Compose accepted a missing bind source with create_host_path false'
        sed -n '1,120p' "$required_output" >&2
        return 1
    fi
    if ! grep -F 'bind source path does not exist' "$required_output" >/dev/null; then
        error 'Docker Compose failed for an unexpected create_host_path false reason'
        sed -n '1,120p' "$required_output" >&2
        return 1
    fi
    if [[ -e "$FIXTURE_DIR/required" ]]; then
        error 'Docker Compose created a bind source even though create_host_path was false'
        return 1
    fi
}

# Exercise container-compose against the same fixture.
expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local default_output="$FIXTURE_DIR/container-compose-defaulted.txt"
    local required_output="$FIXTURE_DIR/container-compose-required.txt"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_container_config_preserves_bind_policy "$config_output"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start defaulted >"$default_output" 2>&1
    if ! grep -F "container create --name $PROJECT_NAME-defaulted-1" "$default_output" >/dev/null; then
        error 'container-compose did not accept the default bind create_host_path policy'
        sed -n '1,120p' "$default_output" >&2
        return 1
    fi

    if "$CONTAINER_COMPOSE" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -p "$PROJECT_NAME" \
        -f "$FIXTURE_DIR/compose.yml" \
        up --no-start required >"$required_output" 2>&1; then
        error 'container-compose accepted a missing bind source with create_host_path false'
        sed -n '1,120p' "$required_output" >&2
        return 1
    fi
    if ! grep -F "service 'required' bind mount source" "$required_output" >/dev/null ||
        ! grep -F 'bind.create_host_path is false' "$required_output" >/dev/null; then
        error 'container-compose failed for an unexpected create_host_path false reason'
        sed -n '1,120p' "$required_output" >&2
        return 1
    fi
    if [[ -e "$FIXTURE_DIR/required" ]]; then
        error 'container-compose created a bind source even though create_host_path was false'
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

    expect_docker_behavior
    expect_container_behavior

    info 'Docker Compose bind create_host_path parity passed.'
}

main "$@"
