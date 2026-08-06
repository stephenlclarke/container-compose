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
# Container public REST socket. It covers `json-file` and `local` create/start/
# inspect, static/follow history, stream selection, tailing, second-start
# retention, local rotation/compression, start-time local rotation validation,
# graceful stop, the none-reader error, native-client visibility, deletion, and
# exact cleanup.

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

# Writes normal fixture progress to standard output.
info() {
    printf '%s\n' "$*"
}

# Writes a non-fatal diagnostic to standard error.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Writes a fatal diagnostic to standard error.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Prints the embedded script usage with the invoked script name.
usage() {
    sed -n '/^# USAGE:/,/^# The same Docker/ { /^# The same Docker/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-docker-rest-logging-contract.sh/$SCRIPT_NAME/"
}

# Parses command-line options into the fixture configuration.
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

# Skips an optional run or fails a strict run for a missing prerequisite.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping Docker REST logging contract"
    exit 0
}

# Runs Docker against either the default or requested endpoint.
run_docker() {
    if [[ -n "$DOCKER_HOST_OVERRIDE" ]]; then
        env -u DOCKER_API_VERSION DOCKER_HOST="$DOCKER_HOST_OVERRIDE" docker "$@"
    else
        env -u DOCKER_API_VERSION -u DOCKER_HOST docker "$@"
    fi
}

# Returns a formatted assertion failure.
fail() {
    error "$*"
    return 1
}

# Verifies one value exactly equals another.
assert_equal() {
    local actual="$1"
    local expected="$2"
    local description="$3"

    [[ "$actual" == "$expected" ]] \
        || fail "$description: got $(printf '%q' "$actual"), expected $(printf '%q' "$expected")"
}

# Verifies a value contains a stable expected fragment.
assert_contains() {
    local actual="$1"
    local expected="$2"
    local description="$3"

    [[ "$actual" == *"$expected"* ]] \
        || fail "$description: $(printf '%q' "$actual") does not contain $(printf '%q' "$expected")"
}

# Waits until a container reaches an expected lifecycle state.
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

# Waits for a background Docker log follower to close cleanly.
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

# Removes every tracked fixture container during cleanup.
remove_test_containers() {
    local name

    for name in "${CONTAINER_NAMES[@]}"; do
        run_docker rm --force "$name" >/dev/null 2>&1 || true
    done
}

# Removes fixture processes, containers, and marker-protected temporary data.
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

# Checks the Docker endpoint and the tools needed by this public contract.
verify_prerequisites() {
    command -v docker >/dev/null 2>&1 \
        || skip_or_fail "docker CLI is unavailable"
    command -v jq >/dev/null 2>&1 \
        || skip_or_fail "jq is required for logging configuration verification"
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
    fi
}

# Creates the marker-protected root used by the fixture's transient files.
create_work_root() {
    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-logging.XXXXXX")"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"
}

# Verifies the native Container authority sees the expected logging driver.
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

# Verifies the native Container authority no longer sees a deleted container.
assert_native_absent() {
    local name="$1"
    local inventory

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$name" 'all(.[]; .id != $name)' <<<"$inventory" >/dev/null \
        || fail "native authority retained deleted container $name"
}

# Verifies a deleted fixture container is absent through both client surfaces.
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

# Exercises the baseline readable-driver lifecycle through the public socket.
exercise_readable_logging() {
    local name="$1"
    local driver="$2"
    local created_id
    local inspection

    created_id="$(run_docker create --name "$name" --log-driver "$driver" \
        "$REQUIRED_IMAGE" /bin/sh -c \
        'printf "out-1\n"; sleep 1; printf "err-1\n" >&2; sleep 1; printf "out-2\n"; sleep 1; printf "err-2\n" >&2')"
    [[ -n "$created_id" ]] || fail "docker create returned an empty identifier"
    inspection="$(run_docker container inspect --format \
        '{{.Id}}|{{.Name}}|{{.State.Status}}|{{.HostConfig.LogConfig.Type}}|{{.LogPath}}' "$name")"
    assert_equal "$inspection" "$created_id|/$name|created|$driver|" \
        "$driver create inspection"
    assert_native_driver "$name" "$driver"

    run_docker start "$name" >/dev/null
    run_docker logs --follow "$name" >"$WORK_ROOT/follow.stdout" \
        2>"$WORK_ROOT/follow.stderr" &
    FOLLOW_PID=$!
    wait_for_state "$name" "exited"
    wait_for_follower
    inspection="$(run_docker container inspect --format \
        '{{.State.Status}}|{{.HostConfig.LogConfig.Type}}|{{.LogPath}}' "$name")"
    case "$driver" in
        json-file)
            assert_contains "$inspection" "exited|json-file|/" \
                "json-file stopped inspection"
            ;;
        local)
            assert_equal "$inspection" "exited|local|" \
                "local stopped inspection"
            ;;
        *)
            fail "unsupported readable logging driver: $driver"
            ;;
    esac
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

# Verifies the none driver preserves Docker's unreadable-history contract.
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

# Verifies graceful stop flushes and closes a followed json-file stream.
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

# Verifies local-driver state, public LogPath, and semantic log-option values.
assert_local_log_configuration() {
    local name="$1"
    local expected_state="$2"
    local expected_options="$3"
    local description="$4"
    local inspection
    local actual_state
    local actual_driver
    local actual_options
    local actual_log_path
    local canonical_options

    inspection="$(run_docker container inspect --format \
        '{{.State.Status}}|{{.HostConfig.LogConfig.Type}}|{{json .HostConfig.LogConfig.Config}}|{{.LogPath}}' "$name")"
    IFS='|' read -r actual_state actual_driver actual_options actual_log_path <<<"$inspection"
    assert_equal "$actual_state" "$expected_state" "$description state"
    assert_equal "$actual_driver" "local" "$description logging driver"
    assert_equal "$actual_log_path" "" "$description public LogPath"
    if ! canonical_options="$(jq -S -c . <<<"$actual_options")"; then
        fail "$description returned invalid logging configuration JSON"
        return
    fi
    assert_equal "$canonical_options" "$expected_options" "$description logging options"
}

# Verifies public Docker log output retained one contiguous range of payloads.
assert_local_rotation_records() {
    local path="$1"
    local expected_first="$2"
    local expected_last="$3"
    local description="$4"
    local line
    local marker
    local payload
    local expected_marker
    local expected_record="$expected_first"
    local record_count=0
    local expected_count=$((expected_last - expected_first + 1))

    while IFS= read -r line || [[ -n "$line" ]]; do
        marker="${line%% *}"
        payload="${line#* }"
        [[ "$marker" != "$line" ]] \
            || fail "$description record $expected_record is missing its payload separator"
        printf -v expected_marker 'record-%03d' "$expected_record"
        assert_equal "$marker" "$expected_marker" "$description record order"
        assert_equal "${#payload}" "890" "$description payload length"
        [[ "$payload" != *[!x]* ]] \
            || fail "$description record $expected_record payload contains non-x data"
        ((expected_record += 1))
        ((record_count += 1))
    done <"$path"

    assert_equal "$record_count" "$expected_count" "$description record count"
    assert_equal "$expected_record" "$((expected_last + 1))" "$description final record"
}

# Exercises local rotation, compressed retention, restart persistence, and tailing.
exercise_local_rotation() {
    local name="$1"
    local created_id
    local identity
    local expected_options='{"compress":"true","max-file":"3","max-size":"4k"}'

    # The workload must expand its variables only in the guest shell.
    # shellcheck disable=SC2016
    created_id="$(run_docker create --name "$name" --log-driver local \
        --log-opt max-size=4k --log-opt max-file=3 --log-opt compress=true \
        "$REQUIRED_IMAGE" /bin/sh -ceu '
            mkdir -p /state
            first="$(cat /state/next 2>/dev/null || printf 1)"
            last=$((first + 39))
            record=$first
            while [ "$record" -le "$last" ]; do
                printf "record-%03d " "$record"
                head -c 890 /dev/zero | tr "\\000" x
                printf "\\n"
                record=$((record + 1))
            done
            printf "%s\\n" "$((last + 1))" > /state/next
        ')"
    [[ -n "$created_id" ]] || fail "local rotation create returned an empty identifier"
    identity="$(run_docker container inspect --format '{{.Id}}|{{.Name}}' "$name")"
    assert_equal "$identity" "$created_id|/$name" "local rotation create identity"
    assert_local_log_configuration "$name" "created" "$expected_options" \
        "local rotation create inspection"
    assert_native_driver "$name" "local"

    run_docker start "$name" >/dev/null
    wait_for_state "$name" "exited"
    assert_local_log_configuration "$name" "exited" "$expected_options" \
        "local rotation first exit inspection"
    run_docker logs "$name" >"$WORK_ROOT/local-rotation-first.stdout" \
        2>"$WORK_ROOT/local-rotation-first.stderr"
    assert_equal "$(<"$WORK_ROOT/local-rotation-first.stderr")" "" \
        "local rotation first history stderr"
    assert_local_rotation_records "$WORK_ROOT/local-rotation-first.stdout" 26 40 \
        "local rotation first history"
    run_docker logs --tail 3 "$name" >"$WORK_ROOT/local-rotation-first-tail.stdout" \
        2>"$WORK_ROOT/local-rotation-first-tail.stderr"
    assert_equal "$(<"$WORK_ROOT/local-rotation-first-tail.stderr")" "" \
        "local rotation first tail stderr"
    assert_local_rotation_records "$WORK_ROOT/local-rotation-first-tail.stdout" 38 40 \
        "local rotation first tail"

    run_docker start "$name" >/dev/null
    wait_for_state "$name" "exited"
    assert_local_log_configuration "$name" "exited" "$expected_options" \
        "local rotation second exit inspection"
    run_docker logs "$name" >"$WORK_ROOT/local-rotation-second.stdout" \
        2>"$WORK_ROOT/local-rotation-second.stderr"
    assert_equal "$(<"$WORK_ROOT/local-rotation-second.stderr")" "" \
        "local rotation second history stderr"
    assert_local_rotation_records "$WORK_ROOT/local-rotation-second.stdout" 66 80 \
        "local rotation second history"
    run_docker logs --tail 3 "$name" >"$WORK_ROOT/local-rotation-second-tail.stdout" \
        2>"$WORK_ROOT/local-rotation-second-tail.stderr"
    assert_equal "$(<"$WORK_ROOT/local-rotation-second-tail.stderr")" "" \
        "local rotation second tail stderr"
    assert_local_rotation_records "$WORK_ROOT/local-rotation-second-tail.stdout" 78 80 \
        "local rotation second tail"
}

# Verifies local's deferred compression error and retained created container state.
exercise_invalid_local_compression() {
    local name="$1"
    local output
    local result_code
    local inspection
    local state
    local start_error
    local expected_options='{"compress":"true","max-file":"1","max-size":"4k"}'
    local expected_reason='compression cannot be enabled when max file count is 1'

    run_docker create --name "$name" --log-driver local \
        --log-opt max-size=4k --log-opt max-file=1 --log-opt compress=true \
        "$REQUIRED_IMAGE" true >/dev/null
    assert_local_log_configuration "$name" "created" "$expected_options" \
        "invalid local compression create inspection"
    assert_native_driver "$name" "local"

    set +e
    output="$(run_docker start "$name" 2>&1)"
    result_code=$?
    set -e
    ((result_code != 0)) || fail "invalid local compression unexpectedly started"
    assert_contains "$output" \
        "failed to initialize logging driver: $expected_reason" \
        "invalid local compression start error"
    inspection="$(run_docker container inspect --format '{{.State.Status}}|{{.State.Error}}' "$name")"
    IFS='|' read -r state start_error <<<"$inspection"
    assert_equal "$state" "created" "invalid local compression retained state"
    assert_contains "$start_error" "$expected_reason" \
        "invalid local compression retained error"
}

# Coordinates the complete public Docker REST logging contract.
main() {
    local suffix
    local readable_name
    local local_name
    local rotation_name
    local invalid_compression_name
    local none_name
    local stop_name
    local name

    parse_args "$@"
    verify_prerequisites
    create_work_root
    suffix="$(basename "$WORK_ROOT" | tr '.[:upper:]' '-[:lower:]')"
    readable_name="cc-rest-readable-$suffix"
    local_name="cc-rest-local-$suffix"
    rotation_name="cc-rest-local-rotation-$suffix"
    invalid_compression_name="cc-rest-local-invalid-$suffix"
    none_name="cc-rest-none-$suffix"
    stop_name="cc-rest-stop-$suffix"
    CONTAINER_NAMES=(
        "$readable_name"
        "$local_name"
        "$rotation_name"
        "$invalid_compression_name"
        "$none_name"
        "$stop_name"
    )

    exercise_readable_logging "$readable_name" "json-file"
    exercise_readable_logging "$local_name" "local"
    exercise_local_rotation "$rotation_name"
    exercise_invalid_local_compression "$invalid_compression_name"
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
