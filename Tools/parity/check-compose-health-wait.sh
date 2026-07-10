#!/usr/bin/env bash
# USAGE: check-compose-health-wait.sh [--strict]
#
# Compare Docker Compose and container-compose health-aware wait behavior.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
readonly SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
readonly PROJECT_SUFFIX="$$-${RANDOM}"
readonly DOCKER_PROJECT="health-docker-${PROJECT_SUFFIX}"
readonly CONTAINER_PROJECT="health-container-${PROJECT_SUFFIX}"

STRICT=0
FIXTURE_DIR=""
DOCKER_COMPOSE_COMMAND=()

# Print an error message.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print a warning message.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an informational message.
info() {
    printf '%s\n' "$*"
}

# Print command usage.
usage() {
    sed -n 's/^# \{0,1\}//p' "$SELF_PATH" | sed -n '/^USAGE:/,/^$/p'
}

# Parse command-line arguments.
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

    warning "$message; skipping health-aware wait parity check"
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

# Ensure local binaries and runtimes are available.
check_tools() {
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
    if ! "${DOCKER_COMPOSE_COMMAND[@]}" version >/dev/null 2>&1; then
        skip_or_fail 'Docker Compose is not runnable'
    fi
    if ! "$CONTAINER_COMPOSE" version >/dev/null 2>&1; then
        skip_or_fail 'container-compose is not runnable'
    fi
}

# Create healthy and unhealthy Compose fixtures.
create_fixtures() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-health-wait.XXXXXX")"
    cat >"$FIXTURE_DIR/healthy.yml" <<'YAML'
services:
  ready:
    image: alpine:3.20
    pull_policy: never
    stop_grace_period: 1s
    command: ["/bin/sh", "-c", "sleep 1; touch /tmp/ready; sleep 30"]
    healthcheck:
      test: ["CMD-SHELL", "test -f /tmp/ready"]
      interval: 250ms
      timeout: 1s
      retries: 10
      start_period: 2s
      start_interval: 200ms
  dependent:
    image: alpine:3.20
    pull_policy: never
    stop_grace_period: 1s
    command: ["/bin/sh", "-c", "sleep 30"]
    depends_on:
      ready:
        condition: service_healthy
YAML
    cat >"$FIXTURE_DIR/unhealthy.yml" <<'YAML'
services:
  broken:
    image: alpine:3.20
    pull_policy: never
    stop_grace_period: 1s
    command: ["/bin/sh", "-c", "sleep 30"]
    healthcheck:
      test: ["CMD", "/bin/false"]
      interval: 200ms
      timeout: 1s
      retries: 2
YAML
}

# Assert that structured ps output reports a healthy service.
assert_healthy() {
    local output="$1"
    local label="$2"

    HEALTH_OUTPUT="$output" python3 - "$label" <<'PY'
import json
import os
import sys

label = sys.argv[1]
raw = os.environ["HEALTH_OUTPUT"].strip()
try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    payload = [json.loads(line) for line in raw.splitlines() if line.strip()]
records = payload if isinstance(payload, list) else [payload]
health = [str(record.get("Health") or record.get("health") or "").lower() for record in records]
if "healthy" not in health:
    raise SystemExit(f"{label} did not report a healthy service: {raw}")
PY
}

# Assert that a health-aware wait rejects an unhealthy service.
assert_unhealthy_failure() {
    local status="$1"
    local output="$2"
    local label="$3"

    if ((status == 0)); then
        error "$label unexpectedly succeeded"
        return 1
    fi
    if [[ "${output,,}" != *"unhealthy"* ]]; then
        printf '%s\n' "$output" >&2
        error "$label did not report an unhealthy service"
        return 1
    fi
}

# Exercise health-aware up and start behavior through Docker Compose.
check_docker_compose() {
    local healthy_file="$FIXTURE_DIR/healthy.yml"
    local unhealthy_file="$FIXTURE_DIR/unhealthy.yml"
    local output status

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$healthy_file" up --wait --wait-timeout 10 >/dev/null 2>&1
    output="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$healthy_file" ps --format json ready)"
    assert_healthy "$output" 'Docker Compose up --wait'
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$healthy_file" down --volumes --remove-orphans >/dev/null 2>&1

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$healthy_file" create >/dev/null 2>&1
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$healthy_file" start --wait --wait-timeout 10 >/dev/null 2>&1
    output="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$healthy_file" ps --format json ready)"
    assert_healthy "$output" 'Docker Compose start --wait'
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$healthy_file" down --volumes --remove-orphans >/dev/null 2>&1

    set +e
    output="$("${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$unhealthy_file" up --wait --wait-timeout 5 2>&1)"
    status=$?
    set -e
    assert_unhealthy_failure "$status" "$output" 'Docker Compose unhealthy up --wait'
}

# Exercise health-aware up and start behavior through container-compose.
check_container_compose() {
    local healthy_file="$FIXTURE_DIR/healthy.yml"
    local unhealthy_file="$FIXTURE_DIR/unhealthy.yml"
    local output status

    "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$healthy_file" up --wait --wait-timeout 10 >/dev/null
    output="$("$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$healthy_file" ps --format json ready)"
    assert_healthy "$output" 'container-compose up --wait'
    "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$healthy_file" down --volumes --remove-orphans >/dev/null

    "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$healthy_file" create >/dev/null
    "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$healthy_file" start --wait --wait-timeout 10 >/dev/null
    output="$("$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$healthy_file" ps --format json ready)"
    assert_healthy "$output" 'container-compose start --wait'
    "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$healthy_file" down --volumes --remove-orphans >/dev/null

    set +e
    output="$("$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$unhealthy_file" up --wait --wait-timeout 5 2>&1)"
    status=$?
    set -e
    assert_unhealthy_failure "$status" "$output" 'container-compose unhealthy up --wait'
}

# Remove runtime resources and temporary files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$FIXTURE_DIR/healthy.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT" -f "$FIXTURE_DIR/unhealthy.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/healthy.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT" -f "$FIXTURE_DIR/unhealthy.yml" down --volumes --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$FIXTURE_DIR"
    fi
}

# Main entry point.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixtures
    trap cleanup EXIT
    check_docker_compose
    check_container_compose
    info 'Docker Compose health-aware wait parity passed.'
}

main "$@"
