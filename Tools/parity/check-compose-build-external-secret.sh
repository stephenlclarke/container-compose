#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-build-external-secret.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, Docker Engine, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE       Path to the container-compose binary. Defaults to
#                           the local SwiftPM debug build at .build/debug/compose.
#   CONTAINER_COMPOSE_NORMALIZER
#                           Path to the matching compose-normalizer binary.
#   CONTAINER_COMPOSE_CONTAINER
#                           Runtime CLI used for matching live macOS validation.
#   CONTAINER_COMPOSE_LIVE  Set to 1 when an isolated matching Apple runtime is
#                           running. The check then provisions an invocation-
#                           private Keychain fixture and proves a live build.
#   DOCKER_COMPOSE          Docker Compose command to compare with.
#
# This parity check proves Docker Compose V2's external build-secret config,
# bake omission, and missing-local-store behavior. It then uses the same
# Dockerfile with a file-backed Docker reference secret and, when requested,
# the Compose-owned macOS Keychain backend through the matching Apple runtime.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_DIR="$REPO_ROOT/Tools/parity/fixtures/build-external-secret"
readonly COMPOSE_FILE="$FIXTURE_DIR/compose.yaml"
readonly DOCKER_COMPOSE_FILE="$FIXTURE_DIR/compose.docker.yaml"
readonly EXPECTED_OUTPUT="external-build-secret-parity-ok"
readonly KEYCHAIN_SERVICE="com.apple.container-compose"
readonly KEYCHAIN_PASSWORD="container-compose-parity-fixture"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_COMPOSE_NORMALIZER="${CONTAINER_COMPOSE_NORMALIZER:-$REPO_ROOT/Tools/compose-normalizer/compose-normalizer}"
export CONTAINER_COMPOSE_NORMALIZER
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
DOCKER_COMPOSE_COMMAND=()
DOCKER_PROJECT_NAME="compose-ext-secret-docker-$RANDOM-$$"
DOCKER_EXTERNAL_PROJECT_NAME="compose-ext-secret-missing-$RANDOM-$$"
CONTAINER_PROJECT_NAME="cc-ext-secret-$RANDOM-$$"
KEYCHAIN_ACCOUNT="container-compose-build-parity-$RANDOM-$$"
KEYCHAIN_PROVISIONED=0
KEYCHAIN_CREATED=0
KEYCHAIN_SEARCH_LIST_CHANGED=0
KEYCHAIN_PATH=""
ORIGINAL_KEYCHAINS=()
WORK_DIR=""

info() { printf '%s\n' "$*"; }
warning() { printf 'warning: %s\n' "$*" >&2; }
error() { printf 'error: %s\n' "$*" >&2; }

usage() {
    sed -n '/^# USAGE:/,/^# This parity/ { /^# This parity/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-compose-build-external-secret.sh/$SCRIPT_NAME/"
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
    warning "$message; skipping external build-secret parity check"
    exit 0
}

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

check_tools() {
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is not available'
    command -v docker >/dev/null 2>&1 || skip_or_fail 'docker is not available'
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is not available'
    [[ -x "$CONTAINER_COMPOSE" ]] \
        || skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    [[ -x "$CONTAINER_COMPOSE_NORMALIZER" ]] \
        || skip_or_fail "matching compose-normalizer is not executable: $CONTAINER_COMPOSE_NORMALIZER"
    [[ -f "$COMPOSE_FILE" && -f "$DOCKER_COMPOSE_FILE" ]] || {
        error "missing external build-secret fixture below: $FIXTURE_DIR"
        return 1
    }
    if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]]; then
        command -v security >/dev/null 2>&1 || {
            error 'macOS security command is unavailable'
            return 1
        }
    fi
}

prepare_work_dir() {
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-compose-external-build-secret.XXXXXX")"
    KEYCHAIN_PATH="$WORK_DIR/external-build-secret.keychain-db"
}

prepare_keychain() {
    local keychain_path
    while IFS= read -r keychain_path; do
        keychain_path="${keychain_path#\"}"
        keychain_path="${keychain_path%\"}"
        [[ -n "$keychain_path" ]] && ORIGINAL_KEYCHAINS+=("$keychain_path")
    done < <(
        security list-keychains -d user \
            | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//'
    )

    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    KEYCHAIN_CREATED=1
    security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security list-keychains \
        -d user \
        -s "$KEYCHAIN_PATH" "${ORIGINAL_KEYCHAINS[@]}"
    KEYCHAIN_SEARCH_LIST_CHANGED=1
}

cleanup() {
    if ((${#DOCKER_COMPOSE_COMMAND[@]} > 0)); then
        "${DOCKER_COMPOSE_COMMAND[@]}" \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$DOCKER_PROJECT_NAME" \
            --file "$DOCKER_COMPOSE_FILE" \
            down --rmi all --volumes --remove-orphans >/dev/null 2>&1 || true
        "${DOCKER_COMPOSE_COMMAND[@]}" \
            --project-directory "$FIXTURE_DIR" \
            --project-name "$DOCKER_EXTERNAL_PROJECT_NAME" \
            --file "$COMPOSE_FILE" \
            down --rmi all --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        down --rmi all --volumes --remove-orphans >/dev/null 2>&1 || true
    if ((KEYCHAIN_PROVISIONED == 1)); then
        security delete-generic-password \
            -s "$KEYCHAIN_SERVICE" \
            -a "$KEYCHAIN_ACCOUNT" \
            "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    fi
    if ((KEYCHAIN_SEARCH_LIST_CHANGED == 1)); then
        if ((${#ORIGINAL_KEYCHAINS[@]} > 0)); then
            security list-keychains \
                -d user \
                -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
        else
            security list-keychains -d user -s >/dev/null 2>&1 || true
        fi
    fi
    if ((KEYCHAIN_CREATED == 1)); then
        security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

assert_external_config() {
    local implementation="$1"
    python3 -c '
import json
import sys

implementation, account = sys.argv[1:3]
document = json.load(sys.stdin)
definition = document.get("secrets", {}).get("build_secret", {})
if definition.get("external") is not True or definition.get("name") != account:
    raise SystemExit(f"{implementation}: external definition is {definition!r}")
secret = document.get("services", {}).get("app", {}).get("build", {}).get("secrets", [])
if implementation == "container-compose":
    want = [{"id": "api_token", "externalName": account}]
else:
    want = [{"source": "build_secret", "target": "api_token"}]
if secret != want:
    raise SystemExit(f"{implementation}: build secret projection is {secret!r}, want {want!r}")
' "$implementation" "$KEYCHAIN_ACCOUNT"
}

assert_external_bake_omission() {
    local implementation="$1"
    python3 -c '
import json
import sys

implementation = sys.argv[1]
target = json.load(sys.stdin).get("target", {}).get("app", {})
if "secret" in target:
    raise SystemExit(
        "{}: external secret leaked into bake output: {!r}".format(
            implementation, target.get("secret")
        )
    )
' "$implementation"
}

check_projection() {
    EXTERNAL_SECRET_NAME="$KEYCHAIN_ACCOUNT" \
        "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_EXTERNAL_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json | assert_external_config 'Docker Compose V2'
    EXTERNAL_SECRET_NAME="$KEYCHAIN_ACCOUNT" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        config --format json | assert_external_config container-compose

    EXTERNAL_SECRET_NAME="$KEYCHAIN_ACCOUNT" \
        "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_EXTERNAL_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build --print app | assert_external_bake_omission 'Docker Compose V2'
    EXTERNAL_SECRET_NAME="$KEYCHAIN_ACCOUNT" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build --print app | assert_external_bake_omission container-compose
}

check_docker_contract() {
    local failure_output="$WORK_DIR/docker-external-failure.out"
    if EXTERNAL_SECRET_NAME="$KEYCHAIN_ACCOUNT" \
        "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_EXTERNAL_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build --no-cache app >"$failure_output" 2>&1
    then
        error 'Docker Compose V2 unexpectedly supplied an external local build secret'
        return 1
    fi
    if ! grep -Fq 'secret api_token: not found' "$failure_output"; then
        error 'Docker Compose V2 external-secret failure did not report the missing BuildKit secret'
        return 1
    fi

    local output
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$DOCKER_COMPOSE_FILE" \
        build app >/dev/null
    output="$("${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$DOCKER_PROJECT_NAME" \
        --file "$DOCKER_COMPOSE_FILE" \
        run --rm --no-deps app)"
    [[ "$output" == *"$EXPECTED_OUTPUT"* ]] || {
        error "Docker Compose V2 file-backed reference output was '$output'"
        return 1
    }
}

check_container_live() {
    local output
    if [[ "$CONTAINER_COMPOSE_LIVE" != "1" ]]; then
        info 'live Apple runtime validation not requested; Docker Compose V2 contract and bake parity passed'
        return
    fi
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        error "matching Apple runtime binary is unavailable: $CONTAINER_BINARY"
        return 1
    fi
    "$CONTAINER_BINARY" system status >/dev/null
    # This value is a public parity marker, not a credential. An invocation-
    # private, unlocked keychain keeps the fixture noninteractive without
    # changing the access policy of the user's login keychain.
    prepare_keychain
    security add-generic-password \
        -A \
        -U \
        -s "$KEYCHAIN_SERVICE" \
        -a "$KEYCHAIN_ACCOUNT" \
        -w "$EXPECTED_OUTPUT" \
        "$KEYCHAIN_PATH" >/dev/null
    KEYCHAIN_PROVISIONED=1

    EXTERNAL_SECRET_NAME="$KEYCHAIN_ACCOUNT" \
        CONTAINER_BIN="$CONTAINER_BINARY" \
        CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        build app >/dev/null
    output="$(EXTERNAL_SECRET_NAME="$KEYCHAIN_ACCOUNT" \
        CONTAINER_BIN="$CONTAINER_BINARY" \
        CONTAINER_COMPOSE_CONTAINER="$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        --project-name "$CONTAINER_PROJECT_NAME" \
        --file "$COMPOSE_FILE" \
        run --rm --no-deps app)"
    [[ "$output" == *"$EXPECTED_OUTPUT"* ]] || {
        error "container-compose external build-secret output was '$output'"
        return 1
    }
}

main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    prepare_work_dir
    trap cleanup EXIT
    check_projection
    check_docker_contract
    check_container_live
    info 'Docker Compose V2 and container-compose external build-secret parity passed.'
}

main "$@"
