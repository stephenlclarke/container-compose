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
#   check-compose-env-file.sh [options]
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
# Docker Compose V2 accepts service env_file long syntax with optional missing
# files and raw values, then verifies container-compose preserves the metadata
# and renders the resolved runtime environment without forwarding env files to
# the lower container runtime.

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

info() {
    printf '%s\n' "$*"
}

warning() {
    printf 'warning: %s\n' "$*" >&2
}

error() {
    printf 'error: %s\n' "$*" >&2
}

usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-env-file.sh/$SCRIPT_NAME/"
}

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

skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose env_file parity check"
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
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-env-file.XXXXXX")"
    printf 'FROM_FILE=resolved\n' >"$FIXTURE_DIR/service.env"
    # shellcheck disable=SC2016
    printf 'RAW_VALUE="$NOT_INTERPOLATED"\n' >"$FIXTURE_DIR/raw.env"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: alpine
    env_file:
      - path: service.env
      - path: missing.env
        required: false
      - path: raw.env
        format: raw
YAML
}

cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

assert_docker_config() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
env = doc.get("services", {}).get("api", {}).get("environment", {})
if env.get("FROM_FILE") != "resolved":
    raise SystemExit(f"Docker Compose FROM_FILE = {env.get('FROM_FILE')!r}")
raw = env.get("RAW_VALUE")
if raw not in ('"$$NOT_INTERPOLATED"', '"$NOT_INTERPOLATED"'):
    raise SystemExit(f"Docker Compose RAW_VALUE = {raw!r}")
PY
}

assert_container_config() {
    local path="$1"
    local fixture="$2"

    python3 - "$path" "$fixture" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
fixture = pathlib.Path(sys.argv[2])
service = doc.get("services", {}).get("api", {})
env = service.get("environment", {})
if env.get("FROM_FILE") != "resolved":
    raise SystemExit(f"container-compose FROM_FILE = {env.get('FROM_FILE')!r}")
if env.get("RAW_VALUE") != '"$NOT_INTERPOLATED"':
    raise SystemExit(f"container-compose RAW_VALUE = {env.get('RAW_VALUE')!r}")

env_files = service.get("envFiles", [])
want = [
    str(fixture / "service.env"),
    {"path": str(fixture / "missing.env"), "required": False},
    {"path": str(fixture / "raw.env"), "format": "raw"},
]
if env_files != want:
    raise SystemExit(f"container-compose envFiles = {env_files!r}, want {want!r}")
PY
}

assert_container_dry_run() {
    local output="$1"

    if [[ "$output" != *'--env FROM_FILE=resolved'* ]]; then
        error 'container-compose dry run did not render FROM_FILE env'
        return 1
    fi
    # shellcheck disable=SC2016
    if [[ "$output" != *'RAW_VALUE="$NOT_INTERPOLATED"'* ]]; then
        error 'container-compose dry run did not render raw env value'
        return 1
    fi
    if [[ "$output" == *'--env-file'* ]]; then
        error 'container-compose dry run forwarded service env_file to the runtime'
        return 1
    fi
}

run_check() {
    local docker_config
    local container_config
    local dry_run_output

    docker_config="$FIXTURE_DIR/docker-config.json"
    container_config="$FIXTURE_DIR/container-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --format json >"$docker_config"
    assert_docker_config "$docker_config"

    "$CONTAINER_COMPOSE" --ansi never --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --format json >"$container_config"
    assert_container_config "$container_config" "$FIXTURE_DIR"

    dry_run_output="$("$CONTAINER_COMPOSE" --ansi never --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" --dry-run create --no-build api 2>&1)"
    assert_container_dry_run "$dry_run_output"

    info "Docker Compose env_file parity passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT
    run_check
}

main "$@"
