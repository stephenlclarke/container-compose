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
#   check-docker-rest-logging-contract.sh [options]
#
# OPTIONS:
#   --host HOST        Docker endpoint to exercise, such as unix:///tmp/docker.sock.
#   --native-cli PATH  Optional Container CLI used to prove one shared authority.
#   --reference        Require the pinned Docker Engine 29.2.1 oracle.
#   --strict           Fail instead of skipping when a prerequisite is unavailable.
#   -h, --help         Show this help.
#
# The same Docker CLI fixture exercises the pinned Docker oracle and the
# Container public REST socket. It covers create/start/inspect, static/follow
# history, stream selection, tailing, second-start retention, graceful stop,
# the none-reader error, native-client visibility, deletion, and exact cleanup.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-logging-root"

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
NATIVE_CLI=""
WORK_ROOT=""
FOLLOW_PID=""
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
    sed -n '/^# USAGE:/,/^# The same Docker/ { /^# The same Docker/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-docker-rest-logging-contract.sh/$SCRIPT_NAME/"
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
    warning "$message; skipping Docker REST logging contract"
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

wait_for_state() {
    local name="$1"
    local expected="$2"
    local observed=""
    local attempt

    for ((attempt = 0; attempt < 120; attempt += 1)); do
        observed="$(run_docker container inspect --format '{{.State.Status}}' "$name")"
        if [[ "$observed" == "$expected" ]]; then
            return 0
        fi
        sleep 0.25
    done
    fail "$name did not reach state $expected; last state was $observed"
}

wait_for_follower() {
    local attempt

    for ((attempt = 0; attempt < 80; attempt += 1)); do
        if ! kill -0 "$FOLLOW_PID" 2>/dev/null; then
            if wait "$FOLLOW_PID"; then
                FOLLOW_PID=""
                return 0
            fi
            FOLLOW_PID=""
            fail "docker logs --follow exited nonzero"
            return
        fi
        sleep 0.25
    done
    kill "$FOLLOW_PID" 2>/dev/null || true
    wait "$FOLLOW_PID" 2>/dev/null || true
    FOLLOW_PID=""
    fail "docker logs --follow did not close after the workload stopped"
}

remove_test_containers() {
    local name

    for name in "${CONTAINER_NAMES[@]}"; do
        run_docker rm --force "$name" >/dev/null 2>&1 || true
    done
}

cleanup() {
    local temporary_parent="${TMPDIR:-/tmp}"

    if [[ -n "$FOLLOW_PID" ]] && kill -0 "$FOLLOW_PID" 2>/dev/null; then
        kill "$FOLLOW_PID" 2>/dev/null || true
        wait "$FOLLOW_PID" 2>/dev/null || true
    fi
    remove_test_containers
    if [[ -n "$WORK_ROOT" && "$WORK_ROOT" == "$temporary_parent"/container-rest-logging.* \
        && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
}

verify_prerequisites() {
    command -v docker >/dev/null 2>&1 \
        || skip_or_fail "docker CLI is unavailable"
    run_docker info >/dev/null 2>&1 \
        || skip_or_fail "Docker endpoint is unavailable"

    if ((REFERENCE == 1)); then
        local engine_version
        engine_version="$(run_docker version --format '{{.Server.Version}}')"
        assert_equal "$engine_version" "$REQUIRED_ENGINE_VERSION" \
            "Docker reference Engine version"
        run_docker image inspect "$REQUIRED_IMAGE" >/dev/null 2>&1 \
            || skip_or_fail "reference image is not preloaded: $REQUIRED_IMAGE"
    fi

    if [[ -n "$NATIVE_CLI" ]]; then
        [[ -x "$NATIVE_CLI" ]] \
            || skip_or_fail "native Container CLI is not executable: $NATIVE_CLI"
        command -v jq >/dev/null 2>&1 \
            || skip_or_fail "jq is required for native authority verification"
    fi
}

create_work_root() {
    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-logging.XXXXXX")"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"
}

assert_native_driver() {
    local name="$1"
    local driver="$2"
    local inventory

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$name" --arg driver "$driver" \
        'any(.[]; .id == $name and .configuration.logging.resolved.driver == $driver)' \
        <<<"$inventory" >/dev/null \
        || fail "native authority does not expose $name with logging driver $driver"
}

assert_native_absent() {
    local name="$1"
    local inventory

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$name" 'all(.[]; .id != $name)' <<<"$inventory" >/dev/null \
        || fail "native authority retained deleted container $name"
}

assert_container_absent() {
    local name="$1"
    local output
    local result

    set +e
    output="$(run_docker container inspect "$name" 2>&1)"
    result=$?
    set -e
    ((result != 0)) || fail "deleted container remains inspectable: $name"
    assert_contains "$output" "No such container: $name" \
        "deleted-container inspection error"
    assert_native_absent "$name"
}

exercise_readable_logging() {
    local name="$1"
    local created_id
    local inspection

    created_id="$(run_docker create --name "$name" --log-driver json-file \
        "$REQUIRED_IMAGE" /bin/sh -c \
        'printf "out-1\n"; sleep 1; printf "err-1\n" >&2; sleep 1; printf "out-2\n"; sleep 1; printf "err-2\n" >&2')"
    [[ -n "$created_id" ]] || fail "docker create returned an empty identifier"
    inspection="$(run_docker container inspect --format \
        '{{.Id}}|{{.Name}}|{{.State.Status}}|{{.HostConfig.LogConfig.Type}}|{{.LogPath}}' "$name")"
    assert_equal "$inspection" "$created_id|/$name|created|json-file|" \
        "readable create inspection"
    assert_native_driver "$name" "json-file"

    run_docker start "$name" >/dev/null
    run_docker logs --follow "$name" >"$WORK_ROOT/follow.stdout" \
        2>"$WORK_ROOT/follow.stderr" &
    FOLLOW_PID=$!
    wait_for_state "$name" "exited"
    wait_for_follower
    inspection="$(run_docker container inspect --format \
        '{{.State.Status}}|{{.HostConfig.LogConfig.Type}}|{{.LogPath}}' "$name")"
    assert_contains "$inspection" "exited|json-file|/" \
        "readable stopped inspection"
    assert_equal "$(<"$WORK_ROOT/follow.stdout")" $'out-1\nout-2' \
        "follow stdout"
    assert_equal "$(<"$WORK_ROOT/follow.stderr")" $'err-1\nerr-2' \
        "follow stderr"

    run_docker start "$name" >/dev/null
    wait_for_state "$name" "exited"
    run_docker logs "$name" >"$WORK_ROOT/history.stdout" \
        2>"$WORK_ROOT/history.stderr"
    assert_equal "$(<"$WORK_ROOT/history.stdout")" $'out-1\nout-2\nout-1\nout-2' \
        "second-start retained stdout"
    assert_equal "$(<"$WORK_ROOT/history.stderr")" $'err-1\nerr-2\nerr-1\nerr-2' \
        "second-start retained stderr"

    run_docker logs --tail 2 "$name" >"$WORK_ROOT/tail.stdout" \
        2>"$WORK_ROOT/tail.stderr"
    assert_equal "$(<"$WORK_ROOT/tail.stdout")" "out-2" "tail stdout"
    assert_equal "$(<"$WORK_ROOT/tail.stderr")" "err-2" "tail stderr"
}

exercise_none_logging() {
    local name="$1"
    local inspection
    local output
    local result

    run_docker create --name "$name" --log-driver none "$REQUIRED_IMAGE" \
        /bin/sh -c 'printf "none-out\n"; printf "none-err\n" >&2' >/dev/null
    inspection="$(run_docker container inspect --format \
        '{{.Name}}|{{.State.Status}}|{{.HostConfig.LogConfig.Type}}|{{.LogPath}}' "$name")"
    assert_equal "$inspection" "/$name|created|none|" "none create inspection"
    assert_native_driver "$name" "none"
    run_docker start "$name" >/dev/null
    wait_for_state "$name" "exited"

    set +e
    output="$(run_docker logs "$name" 2>&1)"
    result=$?
    set -e
    ((result != 0)) || fail "none logging unexpectedly returned readable history"
    assert_equal "$output" \
        "Error response from daemon: configured logging driver does not support reading" \
        "none read error"
}

exercise_stop_logging() {
    local name="$1"
    local state

    run_docker create --name "$name" --log-driver json-file "$REQUIRED_IMAGE" \
        /bin/sh -c \
        'trap '\''printf "term-out\n"; printf "term-err\n" >&2; exit 0'\'' TERM INT; printf "ready\n"; while :; do sleep 1; done' \
        >/dev/null
    run_docker start "$name" >/dev/null
    run_docker logs --follow "$name" >"$WORK_ROOT/stop.stdout" \
        2>"$WORK_ROOT/stop.stderr" &
    FOLLOW_PID=$!
    sleep 1
    run_docker stop --time 3 "$name" >/dev/null
    wait_for_state "$name" "exited"
    wait_for_follower
    state="$(run_docker container inspect --format \
        '{{.State.Status}}|{{.State.ExitCode}}' "$name")"
    assert_equal "$state" "exited|0" "graceful stop state"
    assert_equal "$(<"$WORK_ROOT/stop.stdout")" $'ready\nterm-out' \
        "graceful stop stdout"
    assert_equal "$(<"$WORK_ROOT/stop.stderr")" "term-err" \
        "graceful stop stderr"
}

main() {
    local suffix
    local readable_name
    local none_name
    local stop_name
    local name

    parse_args "$@"
    verify_prerequisites
    create_work_root
    suffix="$(basename "$WORK_ROOT" | tr '.[:upper:]' '-[:lower:]')"
    readable_name="cc-rest-readable-$suffix"
    none_name="cc-rest-none-$suffix"
    stop_name="cc-rest-stop-$suffix"
    CONTAINER_NAMES=("$readable_name" "$none_name" "$stop_name")

    exercise_readable_logging "$readable_name"
    exercise_none_logging "$none_name"
    exercise_stop_logging "$stop_name"

    for name in "${CONTAINER_NAMES[@]}"; do
        run_docker rm --force "$name" >/dev/null
        assert_container_absent "$name"
    done
    CONTAINER_NAMES=()
    info "Docker REST logging contract passed"
}

trap cleanup EXIT
main "$@"
