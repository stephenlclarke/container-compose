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
#   check-docker-rest-fluentd-tls-trust-failure.sh [options]
#
# OPTIONS:
#   --host HOST        Docker endpoint to exercise, such as unix:///tmp/docker.sock.
#   --work-root PATH   Empty, marker-protected /private/tmp root used for evidence.
#   --retain-work-root Preserve --work-root after cleanup for evidence review.
#   --reference        Require the pinned Docker Engine 29.2.1 oracle.
#   --result PATH      Write machine-readable timing and result evidence to PATH.
#   --strict           Fail instead of skipping when a prerequisite is unavailable.
#   -h, --help         Show this help.
#
# The same unmodified Docker CLI fixture exercises Docker Engine 29.2.1 and
# Container's public socket. It proves cache-disabled Fluentd TLS configuration
# is accepted at create, but a bounded self-signed receiver rejects start at the
# Docker trust-verification boundary without leaving container or receiver state.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly REQUIRED_CLI_VERSION="29.7.1"
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly REQUIRED_DISPLAY_IMAGE="alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-fluentd-tls-root"
readonly RECEIVER_TIMEOUT_SECONDS=15
readonly EXPECTED_START_ERROR="failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority"

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
EXPLICIT_WORK_ROOT=""
WORK_ROOT=""
RETAIN_WORK_ROOT=0
RESULT_PATH=""
CONTAINER_NAME=""
CONTAINER_ID=""
RECEIVER_PID=""
RECEIVER_PORT_PATH=""
RECEIVER_RESULT_PATH=""
RECEIVER_PORT=""
RECEIVER_CERT_PATH=""
RECEIVER_KEY_PATH=""
RECEIVER_CERT_SHA256=""
START_STDOUT_PATH=""
START_STDERR_PATH=""
START_STATUS_PATH=""
INSPECT_BEFORE_PATH=""
INSPECT_AFTER_PATH=""

# Print regular fixture progress.
info() {
    printf '%s\n' "$*"
}

# Print a non-fatal diagnostic.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print a fatal diagnostic.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Return a formatted assertion failure.
fail() {
    error "$*"
    return 1
}

# Print the embedded command usage.
usage() {
    sed -n '/^# USAGE:/,/^# The same unmodified/ { /^# The same unmodified/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-docker-rest-fluentd-tls-trust-failure.sh/$SCRIPT_NAME/"
}

# Parse command-line options into fixture configuration.
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
            --work-root)
                [[ $# -ge 2 && -n "$2" ]] || {
                    error "--work-root requires a value"
                    return 2
                }
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
                [[ $# -ge 2 && -n "$2" ]] || {
                    error "--result requires a value"
                    return 2
                }
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
    warning "$message; skipping Docker REST Fluentd TLS trust-failure contract"
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

# Verify the required public client, endpoint, image, and local TLS tools.
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
    [[ "$cli_version" == "$REQUIRED_CLI_VERSION" ]] \
        || fail "Docker CLI version is $cli_version, expected $REQUIRED_CLI_VERSION"
    if ((REFERENCE == 1)); then
        engine_version="$(run_docker version --format '{{.Server.Version}}')"
        [[ "$engine_version" == "$REQUIRED_ENGINE_VERSION" ]] \
            || fail "Docker reference Engine version is $engine_version, expected $REQUIRED_ENGINE_VERSION"
    fi
    run_docker image inspect "$REQUIRED_IMAGE" >/dev/null 2>&1 \
        || skip_or_fail "required image is not preloaded: $REQUIRED_IMAGE"
}

# Create an empty marker-protected root for one fixture execution.
create_work_root() {
    if [[ -n "$EXPLICIT_WORK_ROOT" ]]; then
        WORK_ROOT="$EXPLICIT_WORK_ROOT"
        [[ "$WORK_ROOT" == /private/tmp/container-rest-fluentd-tls.* ]] \
            || fail "--work-root must be an isolated /private/tmp/container-rest-fluentd-tls.* directory: $WORK_ROOT"
        [[ -d "$WORK_ROOT" && ! -L "$WORK_ROOT" ]] \
            || fail "--work-root must be a non-symlink directory: $WORK_ROOT"
        local canonical_work_root
        canonical_work_root="$(cd -P -- "$WORK_ROOT" && pwd -P)" \
            || fail "--work-root cannot be resolved safely: $WORK_ROOT"
        [[ "$canonical_work_root" == /private/tmp/container-rest-fluentd-tls.* ]] \
            || fail "--work-root resolved outside its isolated namespace: $WORK_ROOT"
        WORK_ROOT="$canonical_work_root"
        [[ ! -e "$WORK_ROOT/$ROOT_MARKER_NAME" ]] \
            || fail "--work-root already has the fixture marker: $WORK_ROOT"
        [[ -z "$(find "$WORK_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
            || fail "--work-root must be empty before the fixture starts: $WORK_ROOT"
    else
        WORK_ROOT="$(mktemp -d /private/tmp/container-rest-fluentd-tls.XXXXXX)"
    fi

    printf '%s\n' 'Docker REST Fluentd TLS trust-failure fixture root v1' \
        >"$WORK_ROOT/$ROOT_MARKER_NAME"
    RECEIVER_PORT_PATH="$WORK_ROOT/receiver.port"
    RECEIVER_RESULT_PATH="$WORK_ROOT/receiver-result.json"
    RECEIVER_CERT_PATH="$WORK_ROOT/receiver-cert.pem"
    RECEIVER_KEY_PATH="$WORK_ROOT/receiver-key.pem"
    START_STDOUT_PATH="$WORK_ROOT/start.stdout"
    START_STDERR_PATH="$WORK_ROOT/start.stderr"
    START_STATUS_PATH="$WORK_ROOT/start.status"
    INSPECT_BEFORE_PATH="$WORK_ROOT/inspect-before-start.json"
    INSPECT_AFTER_PATH="$WORK_ROOT/inspect-after-start.json"
    if [[ -z "$RESULT_PATH" ]]; then
        RESULT_PATH="$WORK_ROOT/result.json"
    fi
}

# Remove only a fixture root that this script created and marked.
remove_work_root() {
    [[ -n "$WORK_ROOT" && -d "$WORK_ROOT" ]] || return 0
    [[ -e "$WORK_ROOT/$ROOT_MARKER_NAME" ]] || return 0
    case "$WORK_ROOT" in
        /private/tmp/container-rest-fluentd-tls.*)
            rm -rf -- "$WORK_ROOT"
            ;;
        *)
            warning "refusing to remove unexpected fixture root: $WORK_ROOT"
            ;;
    esac
}

# Stop only fixture-owned state and remove the generated private key.
cleanup() {
    local exit_status=$?

    trap - EXIT
    set +e
    if [[ -n "$CONTAINER_ID" ]]; then
        run_docker container rm --force "$CONTAINER_ID" >/dev/null 2>&1
    fi
    if [[ -n "$RECEIVER_PID" ]]; then
        wait "$RECEIVER_PID" 2>/dev/null
        if kill -0 "$RECEIVER_PID" 2>/dev/null; then
            kill "$RECEIVER_PID" 2>/dev/null
            wait "$RECEIVER_PID" 2>/dev/null
        fi
    fi
    if [[ -n "$RECEIVER_KEY_PATH" ]]; then
        rm -f -- "$RECEIVER_KEY_PATH"
    fi
    if ((RETAIN_WORK_ROOT == 0)); then
        remove_work_root
    fi
    exit "$exit_status"
}

# Create an ephemeral self-signed receiver certificate without retaining its key.
generate_receiver_certificate() {
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$RECEIVER_KEY_PATH" \
        -out "$RECEIVER_CERT_PATH" \
        -days 1 \
        -subj '/CN=host.docker.internal' \
        -addext 'subjectAltName=DNS:host.docker.internal' \
        >"$WORK_ROOT/openssl.stdout" 2>"$WORK_ROOT/openssl.stderr" \
        || fail "could not generate the bounded self-signed TLS receiver certificate"
    RECEIVER_CERT_SHA256="$(shasum -a 256 "$RECEIVER_CERT_PATH" | awk '{print $1}')"
    [[ "$RECEIVER_CERT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
        || fail "generated receiver certificate has no SHA-256 digest"
}

# Start a bounded self-signed TLS receiver and publish its local port.
start_receiver() {
    generate_receiver_certificate
    python3 - "$RECEIVER_PORT_PATH" "$RECEIVER_RESULT_PATH" \
        "$RECEIVER_CERT_PATH" "$RECEIVER_KEY_PATH" "$RECEIVER_TIMEOUT_SECONDS" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import socket
import ssl
import sys
import time
from pathlib import Path

port_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
certificate_path = sys.argv[3]
private_key_path = sys.argv[4]
timeout_seconds = float(sys.argv[5])

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certificate_path, private_key_path)
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", 0))
server.listen(4)
server.settimeout(0.1)
port_path.write_text(str(server.getsockname()[1]), encoding="ascii")

accepted_connections = 0
handshake_succeeded = False
timed_out = False
tls_error = None
deadline = time.monotonic() + timeout_seconds
try:
    while time.monotonic() < deadline:
        try:
            connection, _ = server.accept()
        except TimeoutError:
            continue
        accepted_connections += 1
        try:
            connection.settimeout(max(0.1, deadline - time.monotonic()))
            tls_connection = context.wrap_socket(connection, server_side=True)
            handshake_succeeded = True
            tls_connection.close()
        except ssl.SSLError as error:
            tls_error = f"{type(error).__name__}: {error}"
            connection.close()
        break
    else:
        timed_out = True
finally:
    server.close()

result_path.write_text(
    json.dumps(
        {
            "acceptedConnections": accepted_connections,
            "handshakeSucceeded": handshake_succeeded,
            "timedOut": timed_out,
            "tlsError": tls_error,
        },
        separators=(",", ":"),
        sort_keys=True,
    ),
    encoding="utf-8",
)
PY
    RECEIVER_PID=$!

    local attempt
    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if [[ -s "$RECEIVER_PORT_PATH" ]]; then
            RECEIVER_PORT="$(<"$RECEIVER_PORT_PATH")"
            [[ "$RECEIVER_PORT" =~ ^[0-9]+$ ]] \
                || fail "TLS receiver wrote an invalid port: $RECEIVER_PORT"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "TLS receiver exited before publishing its port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for Fluentd TLS receiver port"
}

# Create and start the Fluentd TLS container through unmodified Docker CLI calls.
run_contract() {
    local start_status

    CONTAINER_NAME="fluentd-tls-rest-$RANDOM-$RANDOM"
    CONTAINER_ID="$(run_docker container create \
        --name "$CONTAINER_NAME" \
        --log-driver fluentd \
        --log-opt cache-disabled=true \
        --log-opt fluentd-address="tls://host.docker.internal:$RECEIVER_PORT" \
        --log-opt fluentd-max-retries=0 \
        "$REQUIRED_DISPLAY_IMAGE" \
        sh -c "printf 'fluentd-tls-trust-failure\\n'")"
    [[ "$CONTAINER_ID" =~ ^[0-9a-f]{64}$ ]] \
        || fail "Docker create returned an invalid container ID: $CONTAINER_ID"
    run_docker container inspect "$CONTAINER_ID" >"$INSPECT_BEFORE_PATH"
    if run_docker container start "$CONTAINER_ID" >"$START_STDOUT_PATH" 2>"$START_STDERR_PATH"; then
        start_status=0
    else
        start_status=$?
    fi
    printf '%s\n' "$start_status" >"$START_STATUS_PATH"
    ((start_status != 0)) || fail "Fluentd TLS start unexpectedly succeeded"
    run_docker container inspect "$CONTAINER_ID" >"$INSPECT_AFTER_PATH"
}

# Wait for the receiver result and erase its synthetic private key.
finish_receiver() {
    wait "$RECEIVER_PID" || fail "TLS receiver exited nonzero"
    RECEIVER_PID=""
    [[ -s "$RECEIVER_RESULT_PATH" ]] \
        || fail "TLS receiver did not write result evidence"
    jq -e . "$RECEIVER_RESULT_PATH" >/dev/null \
        || fail "TLS receiver wrote invalid JSON"
    rm -f -- "$RECEIVER_KEY_PATH"
}

# Assert Docker's create/start/inspect and TLS trust-failure observations.
assert_contract() {
    local start_status

    start_status="$(<"$START_STATUS_PATH")"
    [[ "$start_status" =~ ^[1-9][0-9]*$ ]] \
        || fail "Fluentd TLS start status must be nonzero, got: $start_status"
    grep -Fq "$EXPECTED_START_ERROR" "$START_STDERR_PATH" \
        || fail "Fluentd TLS start did not return Docker's trust-verification error"
    jq -e \
        --arg expected_address "tls://host.docker.internal:$RECEIVER_PORT" \
        '
            .[0].HostConfig.LogConfig.Type == "fluentd"
            and .[0].HostConfig.LogConfig.Config["cache-disabled"] == "true"
            and .[0].HostConfig.LogConfig.Config["fluentd-address"] == $expected_address
            and .[0].HostConfig.LogConfig.Config["fluentd-max-retries"] == "0"
            and .[0].State.Status == "created"
        ' "$INSPECT_AFTER_PATH" >/dev/null \
        || fail "Fluentd TLS inspect state or configuration differed from Docker"
    jq -e '
        .acceptedConnections == 1
        and .handshakeSucceeded == false
        and .timedOut == false
        and (.tlsError | type == "string")
        and (.tlsError | ascii_upcase | contains("ALERT_BAD_CERTIFICATE"))
    ' "$RECEIVER_RESULT_PATH" >/dev/null \
        || fail "TLS receiver did not observe Docker's bad-certificate alert"
    [[ ! -e "$RECEIVER_KEY_PATH" ]] \
        || fail "synthetic TLS private key remained in retained evidence"
}

# Remove the exact failed container and prove the selected endpoint no longer finds it.
remove_container_and_assert() {
    run_docker container rm --force "$CONTAINER_ID" >/dev/null
    if run_docker container inspect "$CONTAINER_ID" >/dev/null 2>&1; then
        fail "Fluentd TLS container still exists after cleanup"
        return
    fi
    CONTAINER_ID=""
}

# Write timing, client, receiver, and public error evidence without private keys.
write_result() {
    local started="$1"
    local finished
    local duration

    finished="$(python3 -c 'import time; print(time.monotonic())')"
    duration="$(python3 - "$started" "$finished" <<'PY'
import sys
print(float(sys.argv[2]) - float(sys.argv[1]))
PY
    )"
    jq -n \
        --arg client_version "$(run_docker version --format '{{.Client.Version}}')" \
        --arg engine_version "$(run_docker version --format '{{.Server.Version}}')" \
        --arg certificate_sha256 "$RECEIVER_CERT_SHA256" \
        --argjson reference "$REFERENCE" \
        --argjson duration_seconds "$duration" \
        --rawfile start_stdout "$START_STDOUT_PATH" \
        --rawfile start_stderr "$START_STDERR_PATH" \
        --slurpfile inspect_before "$INSPECT_BEFORE_PATH" \
        --slurpfile inspect_after "$INSPECT_AFTER_PATH" \
        --slurpfile receiver "$RECEIVER_RESULT_PATH" \
        '{
            certificateSHA256: $certificate_sha256,
            cleanup: {
                containerAbsent: true,
                syntheticPrivateKeyRemoved: true
            },
            docker: {
                clientVersion: $client_version,
                engineVersion: $engine_version
            },
            durationSeconds: $duration_seconds,
            inspectAfterStart: $inspect_after[0][0],
            inspectBeforeStart: $inspect_before[0][0],
            receiver: $receiver[0],
            reference: $reference,
            start: {
                stderr: $start_stderr,
                stdout: $start_stdout
            }
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
    finish_receiver
    assert_contract
    remove_container_and_assert
    write_result "$started"
    info "Fluentd TLS trust-failure contract passed: $RESULT_PATH"
}

main "$@"
