#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
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
#   check-docker-rest-syslog-unix-create-validation.sh [options]
#
# OPTIONS:
#   --host HOST        Docker endpoint to exercise, such as unix:///tmp/docker.sock.
#   --native-cli PATH  Optional Container CLI used to prove no native residue.
#   --reference        Require the pinned Docker Engine 29.2.1 oracle.
#   --strict           Fail instead of skipping when a prerequisite is unavailable.
#   --work-root PATH   Existing marker-protected root in which to retain result.json.
#   -h, --help         Show this help.
#
# The fixture proves that missing Unix Syslog paths fail during Docker create
# rather than at logger start, for both stream and datagram URI schemes.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-syslog-unix-root"
readonly MISSING_SOCKET_PATH="/definitely-missing/syslog.sock"

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
NATIVE_CLI=""
WORK_ROOT=""
WORK_ROOT_PROVIDED=0
ENGINE_VERSION=""
ENGINE_API_VERSION=""
CONTAINER_NAMES=()

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
    sed -n '/^# USAGE:/,/^# The fixture/ { /^# The fixture/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-docker-rest-syslog-unix-create-validation.sh/$SCRIPT_NAME/"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --host)
                [[ $# -ge 2 && -n "$2" ]] || {
                    error "--host requires a value"
                    return 2
                }
                DOCKER_HOST_OVERRIDE="$2"
                shift 2
                ;;
            --native-cli)
                [[ $# -ge 2 && -n "$2" ]] || {
                    error "--native-cli requires a value"
                    return 2
                }
                NATIVE_CLI="$2"
                shift 2
                ;;
            --reference)
                REFERENCE=1
                shift
                ;;
            --strict)
                STRICT=1
                shift
                ;;
            --work-root)
                [[ $# -ge 2 && -n "$2" ]] || {
                    error "--work-root requires a value"
                    return 2
                }
                WORK_ROOT="$2"
                WORK_ROOT_PROVIDED=1
                shift 2
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
    warning "$message; skipping Docker REST Syslog Unix validation"
    exit 0
}

run_docker() {
    if [[ -n "$DOCKER_HOST_OVERRIDE" ]]; then
        env -u DOCKER_API_VERSION DOCKER_HOST="$DOCKER_HOST_OVERRIDE" docker "$@"
    else
        env -u DOCKER_API_VERSION -u DOCKER_HOST docker "$@"
    fi
}

fail() {
    error "$*"
    return 1
}

assert_equal() {
    local actual="$1"
    local expected="$2"
    local description="$3"

    [[ "$actual" == "$expected" ]] \
        || fail "$description: got $(printf '%q' "$actual"), expected $(printf '%q' "$expected")"
}

assert_contains() {
    local actual="$1"
    local expected="$2"
    local description="$3"

    [[ "$actual" == *"$expected"* ]] \
        || fail "$description: $(printf '%q' "$actual") does not contain $(printf '%q' "$expected")"
}

verify_prerequisites() {
    command -v docker >/dev/null 2>&1 \
        || skip_or_fail "docker CLI is unavailable"
    command -v jq >/dev/null 2>&1 \
        || skip_or_fail "jq is required for result evidence"
    run_docker info >/dev/null 2>&1 \
        || skip_or_fail "Docker endpoint is unavailable"

    ENGINE_VERSION="$(run_docker version --format '{{.Server.Version}}')"
    ENGINE_API_VERSION="$(run_docker version --format '{{.Server.APIVersion}}')"
    if ((REFERENCE == 1)); then
        assert_equal "$ENGINE_VERSION" "$REQUIRED_ENGINE_VERSION" \
            "Docker reference Engine version"
        run_docker image inspect "$REQUIRED_IMAGE" >/dev/null 2>&1 \
            || skip_or_fail "reference image is not preloaded: $REQUIRED_IMAGE"
    fi
    if [[ -n "$NATIVE_CLI" ]]; then
        [[ -x "$NATIVE_CLI" ]] \
            || skip_or_fail "native Container CLI is not executable: $NATIVE_CLI"
    fi
}

prepare_work_root() {
    if ((WORK_ROOT_PROVIDED == 1)); then
        [[ -d "$WORK_ROOT" && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]] \
            || fail "--work-root must be an existing marker-protected directory"
        return
    fi

    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-syslog-unix.XXXXXX")"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"
}

assert_native_absent() {
    local name="$1"
    local inventory

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$name" 'all(.[]; .id != $name)' <<<"$inventory" >/dev/null \
        || fail "native authority retained rejected container $name"
}

exercise_scheme() {
    local scheme="$1"
    local name="$2"
    local output
    local result

    set +e
    output="$(run_docker create --name "$name" --log-driver syslog \
        --log-opt "syslog-address=${scheme}://${MISSING_SOCKET_PATH}" \
        "$REQUIRED_IMAGE" true 2>&1)"
    result=$?
    set -e
    ((result != 0)) || fail "$scheme missing Unix socket unexpectedly created a container"
    assert_contains "$output" "stat $MISSING_SOCKET_PATH: no such file or directory" \
        "$scheme create diagnostic"

    set +e
    run_docker container inspect "$name" >/dev/null 2>&1
    result=$?
    set -e
    ((result != 0)) || fail "$scheme rejected container remains inspectable"
    assert_native_absent "$name"

    jq -n --arg scheme "$scheme" --arg diagnostic "$output" \
        '{scheme: $scheme, createExit: 1, diagnostic: $diagnostic, containerAbsent: true}' \
        >"$WORK_ROOT/$scheme.json"
}

cleanup() {
    local name

    for name in "${CONTAINER_NAMES[@]:-}"; do
        run_docker rm --force "$name" >/dev/null 2>&1 || true
    done
}

main() {
    parse_args "$@"
    verify_prerequisites
    prepare_work_root
    trap cleanup EXIT

    local suffix
    suffix="$(basename "$WORK_ROOT" | tr '.[:upper:]' '-[:lower:]')"
    local scheme
    for scheme in unix unixgram; do
        local name="cc-rest-syslog-${scheme}-${suffix}"
        CONTAINER_NAMES+=("$name")
        exercise_scheme "$scheme" "$name"
    done

    jq -n \
        --arg engineVersion "$ENGINE_VERSION" \
        --arg engineAPIVersion "$ENGINE_API_VERSION" \
        --arg workRoot "$WORK_ROOT" \
        --slurpfile unix "$WORK_ROOT/unix.json" \
        --slurpfile unixgram "$WORK_ROOT/unixgram.json" \
        '{
            status: "passed",
            engineVersion: $engineVersion,
            engineAPIVersion: $engineAPIVersion,
            workRoot: $workRoot,
            cases: [$unix[0], $unixgram[0]]
        }' >"$WORK_ROOT/result.json"
    info "Syslog Unix create-validation fixture passed: $WORK_ROOT/result.json"
}

main "$@"
