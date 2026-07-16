#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
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
#   check-compose-pids-limit.sh [options]
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
# Docker Compose V2 handling for service `pids_limit` and
# `deploy.resources.limits.pids`, checks Docker Engine HostConfig projection,
# then checks the same Compose files through container-compose config and
# dry-run output.

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
COMPOSE_FILE=""
UNLIMITED_FILE=""
DEPLOY_FILE=""
PROJECT_NAME="container-compose-pids-$RANDOM-$$"
DEPLOY_PROJECT_NAME="${PROJECT_NAME}-deploy"

# Print an informational line to stdout.
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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-pids-limit.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker/container-compose pids_limit parity check"
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

# Create minimal Compose fixtures for service and Deploy pids limits.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-pids-limit.XXXXXX")"
    COMPOSE_FILE="$FIXTURE_DIR/compose.yml"
    UNLIMITED_FILE="$FIXTURE_DIR/unlimited.yml"
    DEPLOY_FILE="$FIXTURE_DIR/deploy.yml"

    cat >"$COMPOSE_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    pids_limit: 128
YAML

    cat >"$UNLIMITED_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["true"]
    pids_limit: -1
YAML

    cat >"$DEPLOY_FILE" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    deploy:
      resources:
        limits:
          pids: 64
YAML
}

# Remove runtime containers and temporary fixture files.
cleanup() {
    if [[ -n "$COMPOSE_FILE" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$DEPLOY_FILE" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DEPLOY_PROJECT_NAME" -f "$DEPLOY_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert a JSON Compose service preserves the expected pids limit.
assert_config_pids_limit() {
    local path="$1"
    local source="$2"

    python3 - "$path" "$source" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
source = sys.argv[2]
service = doc.get("services", {}).get("api", {})
limit = service.get("pids_limit")
if limit is None:
    limit = service.get("pidsLimit")
if limit != 128:
    raise SystemExit(f"{source} pids_limit = {limit!r}, want 128")
PY
}

# Assert a JSON Compose service preserves the expected Deploy pids limit.
assert_config_deploy_pids_limit() {
    local path="$1"
    local source="$2"

    python3 - "$path" "$source" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
source = sys.argv[2]
service = doc.get("services", {}).get("api", {})
limit = service.get("deploy", {}).get("resources", {}).get("limits", {}).get("pids")
if limit != 64:
    raise SystemExit(f"{source} deploy.resources.limits.pids = {limit!r}, want 64")
PY
}

# Assert Docker Engine receives the expected cgroup pids limit.
assert_docker_engine_pids_limit() {
    local project="$1"
    local compose_file="$2"
    local expected="$3"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$project" -f "$compose_file" up -d --quiet-pull >/dev/null
    python3 - "$project" "$compose_file" "$expected" "${DOCKER_COMPOSE_COMMAND[@]}" <<'PY'
import json
import subprocess
import sys

project, compose_file, expected = sys.argv[1], sys.argv[2], int(sys.argv[3])
compose_command = sys.argv[4:]
container_id = subprocess.check_output(
    compose_command + ["-p", project, "-f", compose_file, "ps", "-q", "api"],
    text=True,
).strip()
if not container_id:
    raise SystemExit("Docker Compose did not create an api container")

inspect = subprocess.check_output(["docker", "inspect", container_id], text=True)
limit = json.loads(inspect)[0]["HostConfig"].get("PidsLimit")
if limit != expected:
    raise SystemExit(f"Docker HostConfig.PidsLimit = {limit!r}, want {expected}")
PY
}

# Validate Docker Compose normalized config and runtime host config.
validate_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"
    local deploy_config_output="$FIXTURE_DIR/docker-compose-deploy-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_output"
    assert_config_pids_limit "$config_output" "Docker Compose"
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DEPLOY_PROJECT_NAME" -f "$DEPLOY_FILE" config --format json >"$deploy_config_output"
    assert_config_deploy_pids_limit "$deploy_config_output" "Docker Compose"

    assert_docker_engine_pids_limit "$PROJECT_NAME" "$COMPOSE_FILE" 128
    assert_docker_engine_pids_limit "$DEPLOY_PROJECT_NAME" "$DEPLOY_FILE" 64
}

# Return the first dry-run command line for the api service container.
dry_run_api_line() {
    local output="$1"
    local project="$2"

    printf '%s\n' "$output" | grep -E "container (run|create) --name ${project}-api" | head -n 1 || true
}

# Return success when a dry-run command line includes the expected pids limit.
line_has_pids_limit() {
    local line="$1"
    local expected="$2"

    printf '%s\n' "$line" | grep -F -- "--pids-limit '$expected'" >/dev/null \
        || printf '%s\n' "$line" | grep -F -- "--pids-limit $expected" >/dev/null
}

# Return failure when a dry-run command line includes any pids-limit flag.
line_omits_pids_limit() {
    local line="$1"

    ! printf '%s\n' "$line" | grep -F -- "--pids-limit" >/dev/null
}

# Validate container-compose config and dry-run command projection.
validate_container_compose_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local deploy_config_output="$FIXTURE_DIR/container-compose-deploy-config.json"
    local up_output
    local create_output
    local run_output
    local up_line
    local create_line
    local run_line
    local unlimited_output
    local unlimited_line
    local deploy_output
    local deploy_line

    "$CONTAINER_COMPOSE" --ansi never -p "$PROJECT_NAME" -f "$COMPOSE_FILE" config --format json >"$config_output"
    assert_config_pids_limit "$config_output" "container-compose"
    "$CONTAINER_COMPOSE" --ansi never -p "$DEPLOY_PROJECT_NAME" -f "$DEPLOY_FILE" config --format json >"$deploy_config_output"
    assert_config_deploy_pids_limit "$deploy_config_output" "container-compose"

    up_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up api)"
    create_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" create api)"
    run_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$COMPOSE_FILE" run api true)"
    up_line="$(dry_run_api_line "$up_output" "$PROJECT_NAME")"
    create_line="$(dry_run_api_line "$create_output" "$PROJECT_NAME")"
    run_line="$(dry_run_api_line "$run_output" "$PROJECT_NAME")"

    if [[ -z "$up_line" ]] || ! line_has_pids_limit "$up_line" 128; then
        error "container-compose dry-run up did not render --pids-limit 128"
        printf '%s\n' "$up_output" >&2
        return 1
    fi
    if [[ -z "$create_line" ]] || ! line_has_pids_limit "$create_line" 128; then
        error "container-compose dry-run create did not render --pids-limit 128"
        printf '%s\n' "$create_output" >&2
        return 1
    fi
    if [[ -z "$run_line" ]] || ! line_has_pids_limit "$run_line" 128; then
        error "container-compose dry-run run did not render --pids-limit 128"
        printf '%s\n' "$run_output" >&2
        return 1
    fi

    unlimited_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$PROJECT_NAME" -f "$UNLIMITED_FILE" up api)"
    unlimited_line="$(dry_run_api_line "$unlimited_output" "$PROJECT_NAME")"
    if [[ -z "$unlimited_line" ]] || ! line_omits_pids_limit "$unlimited_line"; then
        error "container-compose dry-run up rendered --pids-limit for pids_limit: -1"
        printf '%s\n' "$unlimited_output" >&2
        return 1
    fi

    deploy_output="$("$CONTAINER_COMPOSE" --ansi never --dry-run -p "$DEPLOY_PROJECT_NAME" -f "$DEPLOY_FILE" up api)"
    deploy_line="$(dry_run_api_line "$deploy_output" "$DEPLOY_PROJECT_NAME")"
    if [[ -z "$deploy_line" ]] || ! line_has_pids_limit "$deploy_line" 64; then
        error "container-compose dry-run up did not render --pids-limit 64 for deploy.resources.limits.pids"
        printf '%s\n' "$deploy_output" >&2
        return 1
    fi
}

# Script entry point.
main() {
    parse_args "$@"
    check_tools
    create_fixture
    trap cleanup EXIT

    validate_docker_behavior
    validate_container_compose_behavior
    info "pids-limit parity check passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main "$@"
