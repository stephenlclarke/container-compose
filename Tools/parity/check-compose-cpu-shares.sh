#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright (c) 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-cpu-shares.sh [options]
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
# This script verifies that Docker Compose V2 accepts a relative `cpu_shares`
# value, then checks that container-compose carries the same value into the
# generic runtime argument. The Containerization guest integration verifies the
# OCI-shares-to-cgroup-v2-weight conversion on macOS.

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
PROJECT_NAME="cc-cpu-shares-$RANDOM"

info() { printf '%s\n' "$*"; }
warning() { printf 'warning: %s\n' "$*" >&2; }
error() { printf 'error: %s\n' "$*" >&2; }

usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-cpu-shares.sh/$SCRIPT_NAME/"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict) STRICT=1; shift ;;
            -h | --help) usage; exit 0 ;;
            *) error "unknown argument: $1"; usage >&2; return 2 ;;
        esac
    done
}

skip_or_fail() {
    local message="$1"
    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping Docker Compose CPU-shares parity check"
    exit 0
}

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

check_tools() {
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
}

detect_docker_daemon() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        DOCKER_DAEMON_AVAILABLE=1
        return
    fi
    info 'Docker daemon unavailable; checking Docker Compose config parity without Engine dry-run output.'
}

create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-cpu-shares.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: alpine:3.20
    cpu_shares: 512
YAML
}

cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

assert_docker_config_preserves_cpu_shares() {
    python3 - "$1" <<'PY'
import json
import pathlib
import sys

service = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("services", {}).get("api", {})
shares = service.get("cpu_shares", service.get("cpuShares"))
if shares != 512:
    raise SystemExit(f"Docker Compose cpu_shares = {shares!r}, want 512")
PY
}

assert_container_config_preserves_cpu_shares() {
    python3 - "$1" <<'PY'
import json
import pathlib
import sys

service = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")).get("services", {}).get("api", {})
if service.get("cpuShares") != 512:
    raise SystemExit(f"container-compose cpuShares = {service.get('cpuShares')!r}, want 512")
PY
}

dry_run_projects_cpu_shares() {
    local output_path="$1"
    grep -F -- "--cpu-shares 512" "$output_path" >/dev/null
}

expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"
    local dry_run_output="$FIXTURE_DIR/docker-compose-dry-run.txt"
    "${DOCKER_COMPOSE_COMMAND[@]}" --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --format json >"$config_output"
    assert_docker_config_preserves_cpu_shares "$config_output"
    if ((DOCKER_DAEMON_AVAILABLE == 0)); then return; fi
    "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never --dry-run --project-directory "$FIXTURE_DIR" -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up --no-start api >"$dry_run_output" 2>&1
    if ! grep -F "Container $PROJECT_NAME-api-1 Created" "$dry_run_output" >/dev/null; then
        error 'Docker Compose did not accept cpu_shares in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
}

expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local dry_run_output="$FIXTURE_DIR/container-compose-dry-run.txt"
    "$CONTAINER_COMPOSE" --ansi never --project-directory "$FIXTURE_DIR" -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" config --format json >"$config_output"
    assert_container_config_preserves_cpu_shares "$config_output"
    "$CONTAINER_COMPOSE" --ansi never --dry-run --project-directory "$FIXTURE_DIR" -p "$PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up --no-start api >"$dry_run_output" 2>&1
    if ! grep -F "container create --name $PROJECT_NAME-api-1" "$dry_run_output" >/dev/null; then
        error 'container-compose did not accept cpu_shares in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
    if ! dry_run_projects_cpu_shares "$dry_run_output"; then
        error 'container-compose did not project cpu_shares to --cpu-shares in local dry-run up'
        sed -n '1,120p' "$dry_run_output" >&2
        return 1
    fi
}

main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    detect_docker_daemon
    create_fixture
    trap cleanup EXIT
    expect_docker_behavior
    expect_container_behavior
    info 'Docker Compose config and container-compose CPU-shares parity passed.'
}

main "$@"
