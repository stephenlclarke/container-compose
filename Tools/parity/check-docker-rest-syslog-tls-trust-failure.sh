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
#   check-docker-rest-syslog-tls-trust-failure.sh [options]
#
# OPTIONS:
#   --host HOST        Docker endpoint to exercise, such as unix:///tmp/docker.sock.
#   --native-cli PATH  Optional Container CLI used to prove one shared authority.
#   --work-root PATH   Empty, marker-protected /private/tmp root used for evidence.
#   --retain-work-root Preserve --work-root after cleanup for evidence review.
#   --reference        Require the pinned Docker Engine 29.2.1 oracle.
#   --result PATH      Write machine-readable timing and result evidence to PATH.
#   --strict           Fail instead of skipping when a prerequisite is unavailable.
#   -h, --help         Show this help.
#
# The same unmodified Docker CLI fixture exercises Docker Engine 29.2.1 and
# Container's public socket. It proves cache-disabled Syslog TLS configuration
# is accepted at create, but an untrusted self-signed receiver rejects start at
# Docker's trust-verification boundary while retaining created state, exposing
# native authority before cleanup, and removing the generated private key.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly REQUIRED_CLI_VERSION="29.7.1"
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly REQUIRED_DISPLAY_IMAGE="alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-syslog-tls-root"
readonly RECEIVER_TIMEOUT_SECONDS=15
readonly EXPECTED_START_ERROR="failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority"

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
NATIVE_CLI=""
EXPLICIT_WORK_ROOT=""
WORK_ROOT=""
RETAIN_WORK_ROOT=0
RESULT_PATH=""
CONTAINER_NAME=""
CONTAINER_ID=""
RECEIVER_PID=""
RECEIVER_PORT=""
RECEIVER_CERT_SHA256=""

# Print regular fixture progress.
info() { printf '%s\n' "$*"; }

# Print a non-fatal diagnostic.
warning() { printf 'warning: %s\n' "$*" >&2; }

# Print a fatal diagnostic.
error() { printf 'error: %s\n' "$*" >&2; }

# Return an assertion failure.
fail() { error "$*"; return 1; }

# Print the embedded command usage.
usage() {
    sed -n '/^# USAGE:/,/^# The same unmodified/ { /^# The same unmodified/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-docker-rest-syslog-tls-trust-failure.sh/$SCRIPT_NAME/"
}

# Parse command-line options into fixture configuration.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --host)
                [[ $# -ge 2 && -n "$2" ]] || { error "--host requires a value"; return 2; }
                DOCKER_HOST_OVERRIDE="$2"
                shift 2
                ;;
            --native-cli)
                [[ $# -ge 2 && -n "$2" ]] || { error "--native-cli requires a value"; return 2; }
                NATIVE_CLI="$2"
                shift 2
                ;;
            --work-root)
                [[ $# -ge 2 && -n "$2" ]] || { error "--work-root requires a value"; return 2; }
                EXPLICIT_WORK_ROOT="$2"
                shift 2
                ;;
            --retain-work-root)
                RETAIN_WORK_ROOT=1
                shift
                ;;
            --reference)
                REFERENCE=1
                shift
                ;;
            --result)
                [[ $# -ge 2 && -n "$2" ]] || { error "--result requires a value"; return 2; }
                RESULT_PATH="$2"
                shift 2
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

    if ((RETAIN_WORK_ROOT == 1)) && [[ -z "$EXPLICIT_WORK_ROOT" ]]; then
        error "--retain-work-root requires --work-root"
        return 2
    fi
}

# Skip an optional run or fail a strict run for a missing prerequisite.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        fail "$message"
        return 1
    fi
    warning "$message; skipping Docker REST Syslog TLS trust-failure contract"
    exit 0
}

# Invoke Docker against the selected public endpoint.
run_docker() {
    if [[ -n "$DOCKER_HOST_OVERRIDE" ]]; then
        env -u DOCKER_API_VERSION DOCKER_HOST="$DOCKER_HOST_OVERRIDE" docker "$@"
    else
        env -u DOCKER_API_VERSION -u DOCKER_HOST docker "$@"
    fi
}

# Verify required client, endpoint, image, TLS tools, and optional native CLI.
verify_prerequisites() {
    local cli_version
    local engine_version

    command -v docker >/dev/null 2>&1 || skip_or_fail "docker CLI is unavailable"
    command -v jq >/dev/null 2>&1 || skip_or_fail "jq is required"
    command -v openssl >/dev/null 2>&1 || skip_or_fail "openssl is required"
    command -v python3 >/dev/null 2>&1 || skip_or_fail "python3 is required"
    command -v shasum >/dev/null 2>&1 || skip_or_fail "shasum is required"
    run_docker info >/dev/null 2>&1 || skip_or_fail "Docker endpoint is unavailable"
    cli_version="$(run_docker version --format '{{.Client.Version}}')"
    [[ "$cli_version" == "$REQUIRED_CLI_VERSION" ]] || fail "Docker CLI version is $cli_version, expected $REQUIRED_CLI_VERSION"
    if ((REFERENCE == 1)); then
        engine_version="$(run_docker version --format '{{.Server.Version}}')"
        [[ "$engine_version" == "$REQUIRED_ENGINE_VERSION" ]] || fail "Docker Engine version is $engine_version, expected $REQUIRED_ENGINE_VERSION"
    fi
    run_docker image inspect "$REQUIRED_IMAGE" >/dev/null 2>&1 || skip_or_fail "required image is not preloaded: $REQUIRED_IMAGE"
    [[ -z "$NATIVE_CLI" || -x "$NATIVE_CLI" ]] || skip_or_fail "native Container CLI is not executable: $NATIVE_CLI"
}

# Create an empty marker-protected root for one fixture execution.
create_work_root() {
    if [[ -n "$EXPLICIT_WORK_ROOT" ]]; then
        WORK_ROOT="$EXPLICIT_WORK_ROOT"
        [[ "$WORK_ROOT" == /private/tmp/container-rest-syslog-tls.* && -d "$WORK_ROOT" && ! -L "$WORK_ROOT" ]] \
            || fail "--work-root must be a non-symlink /private/tmp/container-rest-syslog-tls.* directory"
        WORK_ROOT="$(cd -P -- "$WORK_ROOT" && pwd -P)" || fail "--work-root cannot be resolved safely"
        [[ "$WORK_ROOT" == /private/tmp/container-rest-syslog-tls.* && ! -e "$WORK_ROOT/$ROOT_MARKER_NAME" ]] \
            || fail "--work-root is outside the fixture namespace or has its marker"
        [[ -z "$(find "$WORK_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "--work-root must be empty"
    else
        WORK_ROOT="$(mktemp -d /private/tmp/container-rest-syslog-tls.XXXXXX)"
    fi

    printf '%s\n' 'Docker REST Syslog TLS trust-failure fixture root v1' >"$WORK_ROOT/$ROOT_MARKER_NAME"
    [[ -n "$RESULT_PATH" ]] || RESULT_PATH="$WORK_ROOT/result.json"
}

# Stop only fixture-owned state and remove its key and default root.
cleanup() {
    local exit_status=$?

    trap - EXIT
    set +e
    [[ -z "$CONTAINER_ID" ]] || run_docker container rm --force "$CONTAINER_ID" >/dev/null 2>&1
    if [[ -n "$RECEIVER_PID" ]]; then
        wait "$RECEIVER_PID" 2>/dev/null
        kill -0 "$RECEIVER_PID" 2>/dev/null && kill "$RECEIVER_PID" 2>/dev/null
    fi
    rm -f -- "$WORK_ROOT/receiver-key.pem"
    if ((RETAIN_WORK_ROOT == 0)) && [[ "$WORK_ROOT" == /private/tmp/container-rest-syslog-tls.* && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -r -- "$WORK_ROOT"
    fi
    exit "$exit_status"
}

# Start a bounded self-signed TLS receiver and publish its local port.
start_receiver() {
    local port_path="$WORK_ROOT/receiver.port"
    local result_path="$WORK_ROOT/receiver-result.json"
    local cert_path="$WORK_ROOT/receiver-cert.pem"
    local key_path="$WORK_ROOT/receiver-key.pem"
    local attempt

    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$key_path" -out "$cert_path" -days 1 \
        -subj '/CN=host.docker.internal' -addext 'subjectAltName=DNS:host.docker.internal' \
        >"$WORK_ROOT/openssl.stdout" 2>"$WORK_ROOT/openssl.stderr" || fail "could not generate TLS receiver certificate"
    RECEIVER_CERT_SHA256="$(shasum -a 256 "$cert_path" | awk '{print $1}')"
    [[ "$RECEIVER_CERT_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "receiver certificate has no SHA-256 digest"
    python3 - "$port_path" "$result_path" "$cert_path" "$key_path" "$RECEIVER_TIMEOUT_SECONDS" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import socket
import ssl
import sys
import time
from pathlib import Path

port_path, result_path, certificate_path, private_key_path, timeout = sys.argv[1:]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certificate_path, private_key_path)
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", 0))
server.listen(4)
server.settimeout(0.1)
Path(port_path).write_text(str(server.getsockname()[1]), encoding="ascii")
result = {"acceptedConnections": 0, "handshakeSucceeded": False, "timedOut": False, "tlsError": None}
deadline = time.monotonic() + float(timeout)
try:
    while time.monotonic() < deadline:
        try:
            connection, _ = server.accept()
        except TimeoutError:
            continue
        result["acceptedConnections"] += 1
        try:
            connection.settimeout(max(0.1, deadline - time.monotonic()))
            tls_connection = context.wrap_socket(connection, server_side=True)
            result["handshakeSucceeded"] = True
            tls_connection.close()
        except ssl.SSLError as exception:
            result["tlsError"] = f"{type(exception).__name__}: {exception}"
            connection.close()
        break
    else:
        result["timedOut"] = True
finally:
    server.close()
Path(result_path).write_text(json.dumps(result, separators=(",", ":"), sort_keys=True), encoding="utf-8")
PY
    RECEIVER_PID=$!

    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if [[ -s "$port_path" ]]; then
            RECEIVER_PORT="$(<"$port_path")"
            [[ "$RECEIVER_PORT" =~ ^[0-9]+$ ]] || fail "TLS receiver wrote an invalid port: $RECEIVER_PORT"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "TLS receiver exited before publishing a port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for Syslog TLS receiver port"
}

# Assert the active native authority exposes the requested Syslog driver.
assert_native_driver() {
    local expected="$1"
    local inventory

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    if [[ "$expected" == "present" ]]; then
        jq -e --arg name "$CONTAINER_NAME" 'any(.[]; .id == $name and .configuration.logging.resolved.driver == "syslog")' \
            <<<"$inventory" >/dev/null || fail "native authority does not expose $CONTAINER_NAME with Syslog"
    else
        jq -e --arg name "$CONTAINER_NAME" 'all(.[]; .id != $name)' <<<"$inventory" >/dev/null \
            || fail "native authority retained $CONTAINER_NAME after cleanup"
    fi
}

# Create and start the Syslog TLS container through unmodified Docker CLI calls.
run_contract() {
    local start_status

    CONTAINER_NAME="syslog-tls-rest-$RANDOM-$RANDOM"
    CONTAINER_ID="$(run_docker container create --name "$CONTAINER_NAME" --log-driver syslog \
        --log-opt cache-disabled=true --log-opt "syslog-address=tcp+tls://host.docker.internal:$RECEIVER_PORT" \
        "$REQUIRED_DISPLAY_IMAGE" sh -c "printf 'syslog-tls-trust-failure\\n'")"
    [[ "$CONTAINER_ID" =~ ^[0-9a-f]{64}$ ]] || fail "Docker create returned an invalid container ID: $CONTAINER_ID"
    run_docker container inspect "$CONTAINER_ID" >"$WORK_ROOT/inspect-before-start.json"
    if run_docker container start "$CONTAINER_ID" >"$WORK_ROOT/start.stdout" 2>"$WORK_ROOT/start.stderr"; then start_status=0; else start_status=$?; fi
    printf '%s\n' "$start_status" >"$WORK_ROOT/start.status"
    ((start_status != 0)) || fail "Syslog TLS start unexpectedly succeeded"
    run_docker container inspect "$CONTAINER_ID" >"$WORK_ROOT/inspect-after-start.json"
}

# Assert Docker's failure diagnostic, inspection, TLS alert, and key cleanup.
assert_contract() {
    local start_status

    wait "$RECEIVER_PID" || fail "TLS receiver exited nonzero"
    RECEIVER_PID=""
    rm -f -- "$WORK_ROOT/receiver-key.pem"
    start_status="$(<"$WORK_ROOT/start.status")"
    [[ "$start_status" =~ ^[1-9][0-9]*$ ]] || fail "Syslog TLS start status must be nonzero, got: $start_status"
    grep -Fq "$EXPECTED_START_ERROR" "$WORK_ROOT/start.stderr" || fail "Syslog TLS start did not return Docker's trust-verification error"
    jq -e --arg address "tcp+tls://host.docker.internal:$RECEIVER_PORT" '
        .[0].HostConfig.LogConfig.Type == "syslog"
        and .[0].HostConfig.LogConfig.Config["cache-disabled"] == "true"
        and .[0].HostConfig.LogConfig.Config["syslog-address"] == $address
        and .[0].State.Status == "created"
    ' "$WORK_ROOT/inspect-after-start.json" >/dev/null || fail "Syslog TLS inspect state or configuration differed from Docker"
    jq -e '
        .acceptedConnections == 1 and .handshakeSucceeded == false and .timedOut == false
        and (.tlsError | type == "string") and (.tlsError | ascii_upcase | contains("ALERT_BAD_CERTIFICATE"))
    ' "$WORK_ROOT/receiver-result.json" >/dev/null || fail "TLS receiver did not observe Docker's bad-certificate alert"
    [[ ! -e "$WORK_ROOT/receiver-key.pem" ]] || fail "synthetic TLS private key remained in evidence"
}

# Remove the failed container and prove public and native cleanup.
remove_container_and_assert() {
    run_docker container rm --force "$CONTAINER_ID" >/dev/null
    run_docker container inspect "$CONTAINER_ID" >/dev/null 2>&1 && fail "Syslog TLS container still exists after cleanup"
    assert_native_driver absent
    CONTAINER_ID=""
}

# Write machine-readable timing, receiver, inspection, and public error evidence.
write_result() {
    local started="$1"
    local finished
    local duration

    [[ -d "$(dirname "$RESULT_PATH")" ]] || fail "result parent directory does not exist: $(dirname "$RESULT_PATH")"
    finished="$(python3 -c 'import time; print(time.monotonic())')"
    duration="$(python3 - "$started" "$finished" <<'PY'
import sys
print(float(sys.argv[2]) - float(sys.argv[1]))
PY
    )"
    jq -n --arg client "$(run_docker version --format '{{.Client.Version}}')" \
        --arg engine "$(run_docker version --format '{{.Server.Version}}')" --arg certificate "$RECEIVER_CERT_SHA256" \
        --arg native_cli "$NATIVE_CLI" --argjson reference "$REFERENCE" --argjson duration "$duration" \
        --rawfile stdout "$WORK_ROOT/start.stdout" --rawfile stderr "$WORK_ROOT/start.stderr" \
        --slurpfile before "$WORK_ROOT/inspect-before-start.json" --slurpfile after "$WORK_ROOT/inspect-after-start.json" \
        --slurpfile receiver "$WORK_ROOT/receiver-result.json" '{
            certificateSHA256: $certificate,
            cleanup: {containerAbsent: true, nativeAuthorityChecked: ($native_cli != ""), syntheticPrivateKeyRemoved: true},
            docker: {clientVersion: $client, engineVersion: $engine}, durationSeconds: $duration,
            inspectAfterStart: $after[0][0], inspectBeforeStart: $before[0][0], receiver: $receiver[0], reference: $reference,
            start: {stderr: $stderr, stdout: $stdout}
        }' >"$RESULT_PATH"
}

# Run the isolated Docker CLI fixture.
main() {
    local started

    parse_args "$@"
    verify_prerequisites
    create_work_root
    trap cleanup EXIT
    started="$(python3 -c 'import time; print(time.monotonic())')"
    start_receiver
    run_contract
    assert_native_driver present
    assert_contract
    remove_container_and_assert
    write_result "$started"
    info "Syslog TLS trust-failure contract passed: $RESULT_PATH"
}

main "$@"
