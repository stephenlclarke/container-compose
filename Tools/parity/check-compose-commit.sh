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
#   check-compose-commit.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_CONTAINER
#                      Path to the Apple container binary used by container-compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It validates
# Docker Compose V2 running-container commit image config behavior with
# --pause=false, then compares that image config with the stopped-container
# slice currently supported through container-compose and the local Apple-backed
# runtime.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""
DOCKER_PROJECT_NAME="container-compose-commit-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="container-compose-commit-runtime-$RANDOM-$$"
DOCKER_IMAGE="example/commit-parity-docker-$RANDOM:latest"
CONTAINER_IMAGE="example/commit-parity-runtime-$RANDOM:latest"

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-commit.sh/$SCRIPT_NAME/"
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

    warning "$message; skipping Docker/container-compose commit parity check"
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
    detect_docker_compose
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi
    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker Engine is not available'
    fi
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
    if ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1 && [[ ! -x "$CONTAINER_BINARY" ]]; then
        skip_or_fail "container binary is not executable: $CONTAINER_BINARY"
    fi
}

create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-commit.XXXXXX")"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 120"]
    environment:
      BASE_VALUE: original
    expose:
      - "8080"
    healthcheck:
      test: ["CMD-SHELL", "test -f /etc/alpine-release"]
      interval: 5s
      timeout: 3s
      start_period: 1s
      start_interval: 500ms
      retries: 2
YAML
}

cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" down --remove-orphans >/dev/null 2>&1 || true
        CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
            "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" down --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$FIXTURE_DIR"
    fi
    docker image rm -f "$DOCKER_IMAGE" >/dev/null 2>&1 || true
    "$CONTAINER_BINARY" image delete --force "$CONTAINER_IMAGE" >/dev/null 2>&1 || true
}

commit_with_docker_compose() {
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up -d --quiet-pull api >/dev/null
    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" commit \
        --pause=false \
        --author parity \
        --message snapshot \
        --change 'ENV SNAPSHOT=true' \
        --change 'CMD ["sh","-c","echo committed"]' \
        --change 'EXPOSE 8443' \
        --change 'LABEL org.example.commit=yes' \
        --change 'USER app' \
        --change 'WORKDIR /srv/app' \
        api "$DOCKER_IMAGE" >/dev/null
    docker image inspect "$DOCKER_IMAGE" >"$FIXTURE_DIR/docker-image.json"
}

commit_with_container_compose() {
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" up -d api >/dev/null
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" stop api >/dev/null
    CONTAINER_BIN="$CONTAINER_BINARY" CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never -p "$CONTAINER_PROJECT_NAME" -f "$FIXTURE_DIR/compose.yml" commit \
        -p=false \
        -a parity \
        -m snapshot \
        -c 'ENV SNAPSHOT=true' \
        -c 'CMD ["sh","-c","echo committed"]' \
        -c 'EXPOSE 8443' \
        -c 'LABEL org.example.commit=yes' \
        -c 'USER app' \
        -c 'WORKDIR /srv/app' \
        api "$CONTAINER_IMAGE" >/dev/null
    "$CONTAINER_BINARY" image inspect "$CONTAINER_IMAGE" >"$FIXTURE_DIR/container-image.json"
}

assert_committed_image_config() {
    python3 - "$FIXTURE_DIR/docker-image.json" "$FIXTURE_DIR/container-image.json" <<'PY'
import json
import pathlib
import sys

docker = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))[0]["Config"]
container_variant = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))[0]["variants"][0]
container = container_variant["config"]["config"]

def env_map(config):
    result = {}
    for entry in config.get("Env") or []:
        key, _, value = entry.partition("=")
        result[key] = value
    return result

def exposed(config):
    return set((config.get("ExposedPorts") or {}).keys())

def labels(config):
    return config.get("Labels") or {}

def assert_healthcheck(source, healthcheck):
    if healthcheck is None:
        raise SystemExit(f"{source} committed healthcheck is missing")
    if healthcheck.get("Test") != ["CMD-SHELL", "test -f /etc/alpine-release"]:
        raise SystemExit(f"{source} committed healthcheck Test = {healthcheck.get('Test')!r}")
    if healthcheck.get("Interval") != 5_000_000_000:
        raise SystemExit(f"{source} committed healthcheck Interval = {healthcheck.get('Interval')!r}")
    if healthcheck.get("Timeout") != 3_000_000_000:
        raise SystemExit(f"{source} committed healthcheck Timeout = {healthcheck.get('Timeout')!r}")
    if healthcheck.get("StartPeriod") != 1_000_000_000:
        raise SystemExit(f"{source} committed healthcheck StartPeriod = {healthcheck.get('StartPeriod')!r}")
    if healthcheck.get("StartInterval") != 500_000_000:
        raise SystemExit(f"{source} committed healthcheck StartInterval = {healthcheck.get('StartInterval')!r}")
    if healthcheck.get("Retries") != 2:
        raise SystemExit(f"{source} committed healthcheck Retries = {healthcheck.get('Retries')!r}")

for source, config, healthcheck in [
    ("Docker Compose", docker, docker.get("Healthcheck")),
    ("container-compose", container, container_variant.get("healthCheck")),
]:
    env = env_map(config)
    if env.get("BASE_VALUE") != "original" or env.get("SNAPSHOT") != "true" or "PATH" not in env:
        raise SystemExit(f"{source} committed env = {config.get('Env')!r}")
    if config.get("Cmd") != ["sh", "-c", "echo committed"]:
        raise SystemExit(f"{source} committed Cmd = {config.get('Cmd')!r}")
    if config.get("User") != "app":
        raise SystemExit(f"{source} committed User = {config.get('User')!r}")
    if config.get("WorkingDir") != "/srv/app":
        raise SystemExit(f"{source} committed WorkingDir = {config.get('WorkingDir')!r}")
    if labels(config).get("org.example.commit") != "yes":
        raise SystemExit(f"{source} committed labels = {labels(config)!r}")
    ports = exposed(config)
    if not {"8080/tcp", "8443/tcp"}.issubset(ports):
        raise SystemExit(f"{source} committed exposed ports = {ports!r}")
    assert_healthcheck(source, healthcheck)
PY
}

main() {
    parse_args "$@"
    check_tools
    trap cleanup EXIT
    create_fixture
    commit_with_docker_compose
    commit_with_container_compose
    assert_committed_image_config
    info "Docker Compose commit parity passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main "$@"
