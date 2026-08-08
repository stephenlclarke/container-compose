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
#   check-docker-rest-splunk-create-validation.sh [options]
#
# OPTIONS:
#   --host HOST        Docker endpoint to exercise, such as unix:///tmp/docker.sock.
#   --native-cli PATH  Optional Container CLI used to prove one shared authority.
#   --reference        Require the pinned Docker Engine 29.2.1 oracle.
#   --strict           Fail instead of skipping when a prerequisite is unavailable.
#   --work-root PATH   Existing marker-protected root in which to retain result.json.
#   -h, --help         Show this help.
#
# The fixture proves Docker-compatible deferred Splunk required-option
# validation: create and inspect succeed, start fails, state stays created,
# diagnostics are secret-safe, and cleanup removes only fixture containers.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-splunk-root"
readonly TOKEN_SENTINEL="fixture-token-do-not-disclose"

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
NATIVE_CLI=""
WORK_ROOT=""
WORK_ROOT_PROVIDED=0
ENGINE_VERSION=""
ENGINE_API_VERSION=""
MISSING_URL_ERROR=""
MISSING_TOKEN_ERROR=""
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
    sed -n '/^# USAGE:/,/^# The fixture/ { /^# The fixture/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-docker-rest-splunk-create-validation.sh/$SCRIPT_NAME/"
}

# Parses command-line options into fixture configuration.
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

# Skips an optional run or fails a strict run for a missing prerequisite.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping Docker REST Splunk validation"
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

# Verifies a value excludes sensitive fixture material.
assert_not_contains() {
    local actual="$1"
    local forbidden="$2"
    local description="$3"

    [[ "$actual" != *"$forbidden"* ]] \
        || fail "$description disclosed the fixture token"
}

# Checks the Docker endpoint and tools needed by this public contract.
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

# Creates or validates the marker-protected root used by fixture evidence.
prepare_work_root() {
    if ((WORK_ROOT_PROVIDED == 1)); then
        [[ -d "$WORK_ROOT" && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]] \
            || fail "--work-root must be an existing marker-protected directory"
        return
    fi

    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-splunk.XXXXXX")"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"
}

# Verifies native Container authority exposes the created logging driver.
assert_native_driver() {
    local name="$1"
    local inventory

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$name" \
        'any(.[]; .id == $name and .configuration.logging.resolved.driver == "splunk")' \
        <<<"$inventory" >/dev/null \
        || fail "native authority does not expose $name with logging driver splunk"
}

# Verifies a deleted fixture container is absent from Docker and native authority.
assert_container_absent() {
    local name="$1"
    local output
    local result
    local inventory

    set +e
    output="$(run_docker container inspect "$name" 2>&1)"
    result=$?
    set -e
    ((result != 0)) || fail "deleted container remains inspectable: $name"
    assert_contains "$output" "No such container: $name" \
        "deleted-container inspection error"

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$name" 'all(.[]; .id != $name)' <<<"$inventory" >/dev/null \
        || fail "native authority retained deleted container $name"
}

# Exercises one deferred Splunk required-option validation path.
exercise_missing_option() {
    local name="$1"
    local expected_phrase="$2"
    local include_token="$3"
    local created_id
    local inspection
    local state
    local driver
    local output
    local result

    if [[ "$include_token" == "true" ]]; then
        created_id="$(run_docker create --name "$name" --log-driver splunk \
            --log-opt "splunk-token=$TOKEN_SENTINEL" "$REQUIRED_IMAGE" true)"
    else
        created_id="$(run_docker create --name "$name" --log-driver splunk \
            --log-opt 'splunk-url=http://127.0.0.1:8088' "$REQUIRED_IMAGE" true)"
    fi
    [[ -n "$created_id" ]] || fail "docker create returned an empty identifier"

    inspection="$(run_docker container inspect --format \
        '{{.State.Status}}|{{.HostConfig.LogConfig.Type}}' "$name")"
    IFS='|' read -r state driver <<<"$inspection"
    assert_equal "$state" "created" "$expected_phrase create state"
    assert_equal "$driver" "splunk" "$expected_phrase create driver"
    assert_native_driver "$name"

    set +e
    output="$(run_docker start "$name" 2>&1)"
    result=$?
    set -e
    ((result != 0)) || fail "$expected_phrase unexpectedly started"
    assert_contains "$output" \
        "failed to initialize logging driver: splunk: $expected_phrase" \
        "$expected_phrase start error"
    assert_not_contains "$output" "$TOKEN_SENTINEL" "$expected_phrase start error"

    inspection="$(run_docker container inspect --format '{{.State.Status}}' "$name")"
    assert_equal "$inspection" "created" "$expected_phrase retained state"

    if [[ "$include_token" == "true" ]]; then
        MISSING_URL_ERROR="$output"
    else
        MISSING_TOKEN_ERROR="$output"
    fi
}

# Writes machine-readable fixture evidence into the marker-protected root.
write_result() {
    jq -n \
        --arg driver "splunk" \
        --arg engine_version "$ENGINE_VERSION" \
        --arg engine_api_version "$ENGINE_API_VERSION" \
        --arg missing_url_error "$MISSING_URL_ERROR" \
        --arg missing_token_error "$MISSING_TOKEN_ERROR" \
        --arg host "${DOCKER_HOST_OVERRIDE:-default}" \
        '{driver: $driver, engine_version: $engine_version, engine_api_version: $engine_api_version, host: $host, missing_url_error: $missing_url_error, missing_token_error: $missing_token_error, status: "passed"}' \
        >"$WORK_ROOT/result.json"
}

# Removes fixture containers and an auto-created marker-protected root.
cleanup() {
    local name
    local temporary_parent="${TMPDIR:-/tmp}"

    # Bash 3.2 treats an explicitly emptied array as unset under `set -u`.
    # The default keeps EXIT cleanup successful after main has removed its
    # owned fixtures and reset the array.
    for name in "${CONTAINER_NAMES[@]:-}"; do
        [[ -n "$name" ]] || continue
        run_docker rm --force "$name" >/dev/null 2>&1 || true
    done
    if ((WORK_ROOT_PROVIDED == 0)) \
        && [[ -n "$WORK_ROOT" && "$WORK_ROOT" == "$temporary_parent"/container-rest-splunk.* \
        && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
}

# Coordinates the complete public Docker REST Splunk validation contract.
main() {
    local suffix
    local missing_url_name
    local missing_token_name
    local name

    parse_args "$@"
    verify_prerequisites
    prepare_work_root
    suffix="$(basename "$WORK_ROOT" | tr '.[:upper:]' '-[:lower:]')"
    missing_url_name="cc-rest-splunk-url-$suffix"
    missing_token_name="cc-rest-splunk-token-$suffix"
    CONTAINER_NAMES=("$missing_url_name" "$missing_token_name")

    exercise_missing_option "$missing_url_name" "splunk-url is expected" "true"
    exercise_missing_option "$missing_token_name" "splunk-token is expected" "false"

    for name in "${CONTAINER_NAMES[@]}"; do
        run_docker rm --force "$name" >/dev/null
        assert_container_absent "$name"
    done
    CONTAINER_NAMES=()
    write_result
    info "Docker REST Splunk create-validation contract passed"
}

trap cleanup EXIT
main "$@"
