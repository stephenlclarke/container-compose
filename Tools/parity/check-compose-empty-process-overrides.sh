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
#   check-compose-empty-process-overrides.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE       Path to the container-compose binary. Defaults to
#                           the local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_CONTAINER
#                           Runtime CLI used for matching live macOS validation.
#                           Defaults to container from PATH.
#   CONTAINER_COMPOSE_LIVE  Set to 1 when an isolated matching Apple runtime is
#                           running. The check then proves the generic runtime
#                           entrypoint-clear primitive executes the image command.
#   DOCKER_COMPOSE          Docker Compose command to compare with. Defaults to
#                           "docker compose" when available, otherwise docker-compose.
#
# This local parity check compares Docker Compose V2 and container-compose
# normalization for explicit empty command and entrypoint lists. Docker Compose
# V2 must run the image command only after the image entrypoint is cleared.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
readonly SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/empty-process-overrides"
readonly COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_PROJECT_NAME="container-compose-empty-process-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="container-compose-empty-process-runtime-$RANDOM-$$"
WORK_DIR=""
CONTAINER_PROJECT_STARTED=0

# Print an informational message.
info() {
    printf '%s\n' "$*"
}

# Print a warning message.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error message.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print the usage block from this script's header.
usage() {
    sed -n '/^# USAGE:/,/^# This local parity/ { /^# This local parity/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-empty-process-overrides.sh/$SCRIPT_NAME/"
}

# Parse the supported flags.
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

# Skip optional validation or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping empty process-override parity check"
    exit 0
}

# Locate Docker Compose V2 without shell evaluation.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
        "${DOCKER_COMPOSE_COMMAND[@]}" version >/dev/null 2>&1 \
            || skip_or_fail "Docker Compose V2 command is unavailable: $DOCKER_COMPOSE"
        return
    fi
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
        return
    fi
    if command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
        return
    fi
    skip_or_fail 'Docker Compose V2 is not available'
}

# Require the reference tools and checked-in Docker Compose fixture.
check_tools() {
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    command -v docker >/dev/null 2>&1 || skip_or_fail 'docker is not available'
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    [[ -f "$COMPOSE_FILE" ]] || { error "missing empty process-override fixture: $COMPOSE_FILE"; return 1; }
    [[ -f "$FIXTURE_DIR/Dockerfile" ]] || { error "missing empty process-override Dockerfile"; return 1; }
}

# Create a private temporary directory for command output.
prepare_work_dir() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-compose-empty-process.XXXXXX")"
}

# Remove only project-scoped resources and this check's temporary directory.
cleanup() {
    if ((${#DOCKER_COMPOSE_COMMAND[@]} > 0)); then
        "${DOCKER_COMPOSE_COMMAND[@]}" \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$DOCKER_PROJECT_NAME" \
            --file "$COMPOSE_FILE" \
            down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if ((CONTAINER_PROJECT_STARTED == 1)); then
        CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
            "$CONTAINER_COMPOSE" \
            --ansi never \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$CONTAINER_PROJECT_NAME" \
            --file "$COMPOSE_FILE" \
            down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

# Capture a command and require its expected process status.
expect_status() {
    local label="$1"
    local expected_status="$2"
    local output_file="$3"
    shift 3

    set +e
    "$@" >"$output_file" 2>&1
    local actual_status=$?
    set -e

    if ((actual_status != expected_status)); then
        error "$label exited $actual_status, expected $expected_status"
        sed -n '1,160p' "$output_file" >&2
        return 1
    fi
}

# Verify an implementation retained the explicit empty list forms.
assert_empty_process_overrides() {
    local implementation="$1"
    local config_file="$2"

    python3 - "$implementation" "$config_file" <<'PY'
import json
import pathlib
import sys

implementation, config_file = sys.argv[1:3]
model = json.loads(pathlib.Path(config_file).read_text(encoding="utf-8"))
service = model.get("services", {}).get("process", {})

if service.get("command") != []:
    raise SystemExit(f"{implementation}: command = {service.get('command')!r}, want []")
if service.get("entrypoint") != []:
    raise SystemExit(f"{implementation}: entrypoint = {service.get('entrypoint')!r}, want []")
PY
}

# Compare normalized Docker Compose and container-compose models.
check_config_parity() {
    local docker_config="$WORK_DIR/docker-compose-config.json"
    local container_config="$WORK_DIR/container-compose-config.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json >"$docker_config"
    assert_empty_process_overrides 'Docker Compose V2' "$docker_config"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json >"$container_config"
    assert_empty_process_overrides 'container-compose' "$container_config"
}

# Prove Docker Compose V2 clears the image entrypoint and retains its command.
check_docker_compose_runtime() {
    local output_file="$WORK_DIR/docker-compose-up.log"

    expect_status 'Docker Compose V2 empty-entrypoint up' 0 "$output_file" \
        "${DOCKER_COMPOSE_COMMAND[@]}" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        up --build --abort-on-container-exit --exit-code-from process process
    grep -Fq 'process-override-ok' "$output_file" \
        || { error 'Docker Compose V2 did not run the image command after clearing its entrypoint'; return 1; }
}

# Prove the matching Apple runtime executes the same process when requested.
check_container_compose_runtime() {
    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        info 'live Apple runtime validation not requested; Docker Compose V2 runtime and model parity passed'
        return
    fi
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        error "matching Apple runtime binary is unavailable: $CONTAINER_BINARY"
        return 1
    fi
    "$CONTAINER_BINARY" system status >/dev/null

    local output_file="$WORK_DIR/container-compose-up.log"
    CONTAINER_PROJECT_STARTED=1
    expect_status 'container-compose empty-entrypoint up' 0 "$output_file" \
        env CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        up --build --abort-on-container-exit --exit-code-from process process
    grep -Fq 'process-override-ok' "$output_file" \
        || { error 'container-compose did not run the image command after clearing its entrypoint'; return 1; }
}

# Run the complete reference, normalized-model, and optional live parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    prepare_work_dir
    trap cleanup EXIT
    check_config_parity
    check_docker_compose_runtime
    check_container_compose_runtime
    info 'empty process-override parity check passed'
}

main "$@"
