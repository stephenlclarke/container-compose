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
#   check-compose-environment.sh [options]
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
# This script is intentionally local-only and is not part of CI. It compares
# Docker Compose V2 and container-compose handling for COMPOSE_PROFILES,
# COMPOSE_ENV_FILES, COMPOSE_COMPATIBILITY, COMPOSE_PROGRESS, and
# COMPOSE_STATUS_STDOUT. Orphan lifecycle defaults are covered deterministically
# by ComposeCore unit tests because they require a live container runtime.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
readonly SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""
PROJECT_NAME="compose-environment-$RANDOM-$$"

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

# Print usage text extracted from the top-of-file help block.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-environment.sh/$SCRIPT_NAME/"
}

# Parse supported script options.
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

# Skip optional local checks or fail when strict mode was requested.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker/container-compose environment parity check"
    exit 0
}

# Resolve Docker Compose V2 in plugin or standalone form.
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

# Confirm the local comparison tools can run.
check_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a fixture whose profile and image both depend on root environment settings.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-environment.XXXXXX")"
    printf 'PROFILE_IMAGE=example/first:latest\n' >"$FIXTURE_DIR/first.env"
    printf 'PROFILE_IMAGE=example/second:latest\n' >"$FIXTURE_DIR/second.env"
    printf 'PROFILE_IMAGE=example/explicit:latest\n' >"$FIXTURE_DIR/explicit.env"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: alpine:3.20
  profiled:
    image: "${PROFILE_IMAGE}"
    profiles: ["dev"]
YAML
}

# Remove temporary fixture files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert a normalized configuration activates the profile and selects its expected image.
assert_profiled_config() {
    local path="$1"
    local source="$2"
    local expected_image="$3"

    python3 - "$path" "$source" "$expected_image" <<'PY'
import json
import pathlib
import sys

path, source, expected_image = sys.argv[1:]
services = json.loads(pathlib.Path(path).read_text(encoding="utf-8")).get("services", {})
profiled = services.get("profiled")
if profiled is None:
    raise SystemExit(f"{source} did not activate profiled through COMPOSE_PROFILES")
if profiled.get("image") != expected_image:
    raise SystemExit(f"{source} profiled image = {profiled.get('image')!r}, want {expected_image!r}")
PY
}

# Capture a command's combined output while retaining its exit status.
capture_status() {
    local output_path="$1"
    shift

    set +e
    "$@" >"$output_path" 2>&1
    local status=$?
    set -e
    return "$status"
}

# Verify both CLIs reject Docker's invalid COMPOSE_PROGRESS values.
assert_invalid_progress() {
    local label="$1"
    shift
    local output_path="$FIXTURE_DIR/$label-invalid-progress.txt"

    if capture_status "$output_path" env COMPOSE_PROGRESS=invalid "$@" --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --quiet; then
        error "$label accepted COMPOSE_PROGRESS=invalid"
        return 1
    fi
    if ! grep -Fq 'unsupported --progress value "invalid"' "$output_path"; then
        error "$label did not report Docker-compatible invalid progress diagnostics"
        sed -n '1,120p' "$output_path" >&2
        return 1
    fi
}

# Check observable root environment behavior against Docker Compose V2.
run_checks() {
    local docker_config="$FIXTURE_DIR/docker-config.json"
    local container_config="$FIXTURE_DIR/container-config.json"
    local docker_explicit="$FIXTURE_DIR/docker-explicit.json"
    local container_explicit="$FIXTURE_DIR/container-explicit.json"
    local docker_compat container_compat status_stdout status_stderr

    (
        cd "$FIXTURE_DIR"
        env COMPOSE_PROFILES=dev COMPOSE_ENV_FILES='first.env,second.env' \
            "${DOCKER_COMPOSE_COMMAND[@]}" --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --format json
    ) >"$docker_config"
    (
        cd "$FIXTURE_DIR"
        env COMPOSE_PROFILES=dev COMPOSE_ENV_FILES='first.env,second.env' COMPOSE_PROGRESS=quiet \
            "$CONTAINER_COMPOSE" --ansi never --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --format json
    ) >"$container_config"
    assert_profiled_config "$docker_config" 'Docker Compose' 'example/second:latest'
    assert_profiled_config "$container_config" 'container-compose' 'example/second:latest'

    (
        cd "$FIXTURE_DIR"
        env COMPOSE_PROFILES=dev COMPOSE_ENV_FILES='first.env,second.env' \
            "${DOCKER_COMPOSE_COMMAND[@]}" --env-file explicit.env --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --format json
    ) >"$docker_explicit"
    (
        cd "$FIXTURE_DIR"
        env COMPOSE_PROFILES=dev COMPOSE_ENV_FILES='first.env,second.env' COMPOSE_PROGRESS=quiet \
            "$CONTAINER_COMPOSE" --ansi never --env-file explicit.env --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --format json
    ) >"$container_explicit"
    assert_profiled_config "$docker_explicit" 'Docker Compose explicit --env-file' 'example/explicit:latest'
    assert_profiled_config "$container_explicit" 'container-compose explicit --env-file' 'example/explicit:latest'

    docker_compat="$(env COMPOSE_COMPATIBILITY=1 "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$PROJECT_NAME" --dry-run --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" up --no-start 2>&1)"
    container_compat="$(env COMPOSE_COMPATIBILITY=1 COMPOSE_PROGRESS=quiet "$CONTAINER_COMPOSE" --ansi never --project-name "$PROJECT_NAME" --dry-run --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" up --no-start 2>&1)"
    [[ "$docker_compat" == *"${PROJECT_NAME}_api_1"* ]] || { error 'Docker Compose did not apply COMPOSE_COMPATIBILITY'; return 1; }
    [[ "$container_compat" == *"${PROJECT_NAME}_api_1"* ]] || { error 'container-compose did not apply COMPOSE_COMPATIBILITY'; return 1; }

    status_stdout="$FIXTURE_DIR/status-stdout.txt"
    status_stderr="$FIXTURE_DIR/status-stderr.txt"
    env COMPOSE_STATUS_STDOUT=1 COMPOSE_PROGRESS=plain \
        "$CONTAINER_COMPOSE" --ansi never --project-directory "$FIXTURE_DIR" -f "$FIXTURE_DIR/compose.yml" config --quiet >"$status_stdout" 2>"$status_stderr"
    grep -Fq 'Loading Compose model' "$status_stdout" || { error 'container-compose did not route progress to stdout'; return 1; }
    [[ ! -s "$status_stderr" ]] || { error 'container-compose wrote progress to stderr with COMPOSE_STATUS_STDOUT=1'; return 1; }

    assert_invalid_progress 'docker' "${DOCKER_COMPOSE_COMMAND[@]}"
    assert_invalid_progress 'container' "$CONTAINER_COMPOSE" --ansi never
}

# Main entry point.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT
    run_checks
    info "Docker Compose environment parity passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main "$@"
