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
#   check-compose-git-remote.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Git, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to a
#                      working "docker compose" plugin when available,
#                      otherwise docker-compose.
#
# This local-only check serves a generated Compose repository through a local
# Git daemon. It does not require a Docker daemon or a container runtime.

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
GIT_DAEMON_PID=""
REMOTE_URL=""

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
    sed -n '/^# USAGE:/,/^# This local-only/ { /^# This local-only/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-git-remote.sh/$SCRIPT_NAME/"
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
    warning "$message; skipping Docker Compose Git remote parity check"
    exit 0
}

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

check_tools() {
    detect_docker_compose
    for tool in git python3; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            skip_or_fail "$tool is not available"
        fi
    done
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

create_fixture() {
    local source
    local stack
    local port

    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-git-remote.XXXXXX")"
    source="$FIXTURE_DIR/source"
    stack="$source/stacks/demo"
    mkdir -p "$stack/context"
    printf 'FROM_REMOTE=resolved\n' >"$stack/service.env"
    printf 'FROM scratch\n' >"$stack/context/Dockerfile"
    cat >"$stack/compose.yaml" <<'YAML'
name: git-remote-parity
services:
  api:
    image: ${REMOTE_IMAGE:-alpine:3.20}
    env_file: service.env
    build: context
YAML

    git init -q "$source"
    git -C "$source" add .
    git -C "$source" -c user.name='Compose Parity' -c user.email=compose@example.test commit -qm initial
    git clone -q --bare "$source" "$FIXTURE_DIR/project.git"

    port="$(python3 - <<'PY'
import socket

with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)"
    git daemon --reuseaddr --export-all --base-path="$FIXTURE_DIR" \
        --listen=127.0.0.1 --port="$port" "$FIXTURE_DIR" \
        >"$FIXTURE_DIR/git-daemon.log" 2>&1 &
    GIT_DAEMON_PID=$!
    REMOTE_URL="git://127.0.0.1:$port/project.git#HEAD:stacks/demo"

    for _ in {1..100}; do
        if git ls-remote "${REMOTE_URL%%#*}" HEAD >/dev/null 2>&1; then
            return
        fi
        sleep 0.05
    done
    error "Git daemon did not become ready: $(cat "$FIXTURE_DIR/git-daemon.log")"
    return 1
}

cleanup() {
    if [[ -n "$GIT_DAEMON_PID" ]]; then
        kill "$GIT_DAEMON_PID" >/dev/null 2>&1 || true
        wait "$GIT_DAEMON_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

assert_config() {
    local path="$1"
    local source="$2"
    local cache="$3"
    python3 - "$path" "$source" "$cache" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
source = sys.argv[2]
cache = pathlib.Path(sys.argv[3]).resolve()
if document.get("name") != "git-remote-parity":
    raise SystemExit(f"{source} project name = {document.get('name')!r}")
service = document.get("services", {}).get("api", {})
if service.get("image") != "alpine:3.20":
    raise SystemExit(f"{source} api image = {service.get('image')!r}")
if service.get("environment", {}).get("FROM_REMOTE") != "resolved":
    raise SystemExit(f"{source} FROM_REMOTE = {service.get('environment')!r}")
context = pathlib.Path(service.get("build", {}).get("context", "")).resolve()
if context.name != "context" or context.parent.name != "demo":
    raise SystemExit(f"{source} build context = {context}")
if cache not in context.parents:
    raise SystemExit(f"{source} build context {context} is outside cache {cache}")
PY
}

expect_failure() {
    local source="$1"
    local pattern="$2"
    shift 2
    local output
    if output="$("$@" 2>&1)"; then
        error "$source unexpectedly succeeded"
        return 1
    fi
    if [[ -n "$pattern" && "$output" != *"$pattern"* ]]; then
        error "$source error did not contain '$pattern': $output"
        return 1
    fi
}

run_check() {
    local docker_cache="$FIXTURE_DIR/docker-cache"
    local container_cache="$FIXTURE_DIR/container-cache"
    local docker_config="$FIXTURE_DIR/docker.json"
    local container_config="$FIXTURE_DIR/container.json"
    local dry_run_output
    local base_url="${REMOTE_URL%%#*}"
    local missing_ref="${base_url}#missing-ref:stacks/demo"
    local traversal="${base_url}#HEAD:../../escape"

    XDG_CACHE_HOME="$docker_cache" "${DOCKER_COMPOSE_COMMAND[@]}" -f "$REMOTE_URL" config --format json >"$docker_config"
    XDG_CACHE_HOME="$container_cache" "$CONTAINER_COMPOSE" --ansi never -f "$REMOTE_URL" config --format json >"$container_config"
    assert_config "$docker_config" "Docker Compose" "$docker_cache"
    assert_config "$container_config" "container-compose" "$container_cache"

    dry_run_output="$(XDG_CACHE_HOME="$container_cache" "$CONTAINER_COMPOSE" --ansi never --dry-run -f "$REMOTE_URL" create --no-build api)"
    if [[ "$dry_run_output" != *'--env FROM_REMOTE=resolved'* ]]; then
        error "container-compose dry run did not use the remote env file: $dry_run_output"
        return 1
    fi

    expect_failure "Docker Compose disabled Git loader" "disabled" \
        env COMPOSE_EXPERIMENTAL_GIT_REMOTE=false XDG_CACHE_HOME="$docker_cache" "${DOCKER_COMPOSE_COMMAND[@]}" -f "$REMOTE_URL" config
    expect_failure "container-compose disabled Git loader" "disabled" \
        env COMPOSE_EXPERIMENTAL_GIT_REMOTE=false XDG_CACHE_HOME="$container_cache" "$CONTAINER_COMPOSE" -f "$REMOTE_URL" config
    expect_failure "Docker Compose missing Git ref" "does not contain ref" \
        env XDG_CACHE_HOME="$docker_cache" "${DOCKER_COMPOSE_COMMAND[@]}" -f "$missing_ref" config
    expect_failure "container-compose missing Git ref" "does not contain ref" \
        env XDG_CACHE_HOME="$container_cache" "$CONTAINER_COMPOSE" -f "$missing_ref" config

    mkdir -p "$docker_cache/escape" "$container_cache/escape"
    printf 'services:\n  escaped:\n    image: alpine\n' >"$docker_cache/escape/compose.yaml"
    cp "$docker_cache/escape/compose.yaml" "$container_cache/escape/compose.yaml"
    expect_failure "Docker Compose Git traversal" "" \
        env XDG_CACHE_HOME="$docker_cache" "${DOCKER_COMPOSE_COMMAND[@]}" -f "$traversal" config
    expect_failure "container-compose Git traversal" "path traversal" \
        env XDG_CACHE_HOME="$container_cache" "$CONTAINER_COMPOSE" -f "$traversal" config

    info "Docker Compose Git remote parity passed using ${DOCKER_COMPOSE_COMMAND[*]} and $CONTAINER_COMPOSE"
}

main() {
    parse_args "$@"
    check_tools
    trap cleanup EXIT
    create_fixture
    run_check
}

main "$@"
