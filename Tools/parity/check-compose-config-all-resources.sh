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
#   check-compose-config-all-resources.sh [options]
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
# Docker Compose V2 and container-compose config output for selected services,
# including root --all-resources resource retention for networks, volumes,
# configs, and secrets, plus the --services projection's service-argument
# behavior.

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-config-all-resources.sh/$SCRIPT_NAME/"
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

# Exit cleanly for optional local dependencies, or fail when strict mode is active.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose config --all-resources parity check"
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

# Ensure local tools needed by the comparison are available.
check_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a fixture with service-specific and unused top-level resources.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-config-all-resources.XXXXXX")"
    COMPOSE_FILE="$FIXTURE_DIR/compose.yml"

    cat >"$COMPOSE_FILE" <<'YAML'
name: allres
services:
  web:
    image: nginx:alpine
    networks:
      - front
    volumes:
      - data:/data
    configs:
      - app_config
    secrets:
      - app_secret
  worker:
    image: busybox:1.36
    networks:
      - back
    volumes:
      - tmp:/tmp
    configs:
      - worker_config
    secrets:
      - worker_secret
networks:
  front:
  back:
volumes:
  data:
  tmp:
configs:
  app_config:
    file: ./app.conf
  worker_config:
    file: ./worker.conf
secrets:
  app_secret:
    file: ./app.secret
  worker_secret:
    file: ./worker.secret
YAML
    : >"$FIXTURE_DIR/app.conf"
    : >"$FIXTURE_DIR/worker.conf"
    : >"$FIXTURE_DIR/app.secret"
    : >"$FIXTURE_DIR/worker.secret"
}

# Remove temporary fixture files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose and container-compose agree on config resource behavior.
assert_outputs() {
    local docker_selected="$1"
    local container_selected="$2"
    local docker_all="$3"
    local container_all="$4"
    local docker_services="$5"
    local container_services="$6"

    python3 - "$docker_selected" "$container_selected" "$docker_all" "$container_all" "$docker_services" "$container_services" <<'PY'
import json
import pathlib
import sys


def load_json(path: str) -> dict:
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def non_empty_lines(path: str) -> set[str]:
    return {line.strip() for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines() if line.strip()}


def keys(doc: dict, section: str) -> list[str]:
    return sorted((doc.get(section) or {}).keys())


def assert_keys(doc: dict, section: str, expected: list[str], label: str) -> None:
    actual = keys(doc, section)
    if actual != expected:
        raise SystemExit(f"{label} {section} = {actual!r}, want {expected!r}")


def assert_config(
    path: str,
    expected_services: list[str],
    expected_networks: list[str],
    expected_volumes: list[str],
    expected_configs: list[str],
    expected_secrets: list[str],
    label: str,
) -> None:
    doc = load_json(path)
    assert_keys(doc, "services", expected_services, label)
    assert_keys(doc, "networks", expected_networks, label)
    assert_keys(doc, "volumes", expected_volumes, label)
    assert_keys(doc, "configs", expected_configs, label)
    assert_keys(doc, "secrets", expected_secrets, label)


docker_selected, container_selected, docker_all, container_all, docker_services, container_services = sys.argv[1:]
assert_config(docker_selected, ["web"], ["front"], ["data"], ["app_config"], ["app_secret"], "Docker Compose selected config")
assert_config(container_selected, ["web"], ["front"], ["data"], ["app_config"], ["app_secret"], "container-compose selected config")
assert_config(
    docker_all,
    ["web"],
    ["back", "front"],
    ["data", "tmp"],
    ["app_config", "worker_config"],
    ["app_secret", "worker_secret"],
    "Docker Compose --all-resources config",
)
assert_config(
    container_all,
    ["web"],
    ["back", "front"],
    ["data", "tmp"],
    ["app_config", "worker_config"],
    ["app_secret", "worker_secret"],
    "container-compose --all-resources config",
)

expected_services = {"web", "worker"}
for path, label in ((docker_services, "Docker Compose --services"), (container_services, "container-compose --services")):
    actual = non_empty_lines(path)
    if actual != expected_services:
        raise SystemExit(f"{label} output = {sorted(actual)!r}, want {sorted(expected_services)!r}")
PY
}

# Run the local-only parity comparison.
run_check() {
    local docker_selected
    local container_selected
    local docker_all
    local container_all
    local docker_services
    local container_services

    docker_selected="$FIXTURE_DIR/docker-selected.json"
    container_selected="$FIXTURE_DIR/container-selected.json"
    docker_all="$FIXTURE_DIR/docker-all-resources.json"
    container_all="$FIXTURE_DIR/container-all-resources.json"
    docker_services="$FIXTURE_DIR/docker-services.txt"
    container_services="$FIXTURE_DIR/container-services.txt"

    "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never --progress quiet -f "$COMPOSE_FILE" config --format json web >"$docker_selected"
    "$CONTAINER_COMPOSE" --ansi never --progress quiet -f "$COMPOSE_FILE" config --format json web >"$container_selected"

    "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never --progress quiet --all-resources -f "$COMPOSE_FILE" config --format json web >"$docker_all"
    "$CONTAINER_COMPOSE" --ansi never --progress quiet --all-resources -f "$COMPOSE_FILE" config --format json web >"$container_all"

    "${DOCKER_COMPOSE_COMMAND[@]}" --ansi never --progress quiet -f "$COMPOSE_FILE" config --services missing >"$docker_services"
    "$CONTAINER_COMPOSE" --ansi never --progress quiet -f "$COMPOSE_FILE" config --services missing >"$container_services"

    assert_outputs "$docker_selected" "$container_selected" "$docker_all" "$container_all" "$docker_services" "$container_services"
}

# Script entrypoint.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT
    run_check
    info 'Docker Compose config --all-resources parity passed.'
}

main "$@"
