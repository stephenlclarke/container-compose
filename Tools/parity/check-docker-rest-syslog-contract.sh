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
#   check-docker-rest-syslog-contract.sh [options]
#
# OPTIONS:
#   --host HOST        Docker endpoint to exercise, such as unix:///tmp/docker.sock.
#   --transport TRANSPORT
#                      Syslog connection transport: udp (default) or tcp.
#   --receiver-location LOCATION
#                      Receiver location: local (default) or colima.
#   --syslog-address-host HOST
#                      Hostname or address visible to the selected log driver.
#   --native-cli PATH  Optional Container CLI used to prove one shared authority.
#   --reference        Require the pinned Docker Engine 29.2.1 oracle.
#   --result PATH      Write machine-readable timing and result evidence to PATH.
#   --strict           Fail instead of skipping when a prerequisite is unavailable.
#   -h, --help         Show this help.
#
# The same unmodified Docker CLI fixture exercises Docker Engine 29.2.1 and
# Container's public socket. It proves cache-disabled Syslog UDP or TCP RFC
# 5424 microsecond framing, stdout/stderr/binary ordering, facility and
# severity mapping, Docker tag expansion, inspect projection, unsupported
# remote history, native authority visibility, and marker-protected cleanup.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly REQUIRED_CLI_VERSION="29.7.1"
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly REQUIRED_DISPLAY_IMAGE="alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-syslog-root"
readonly RECEIVER_MESSAGE_COUNT=3

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
SYSLOG_TRANSPORT="udp"
RECEIVER_LOCATION="local"
SYSLOG_ADDRESS_HOST="host.docker.internal"
NATIVE_CLI=""
RESULT_PATH=""
WORK_ROOT=""
CONTAINER_NAME=""
CONTAINER_ID=""
RECEIVER_PID=""
RECEIVER_PORT_PATH=""
RECEIVER_RESULT_PATH=""
RECEIVER_FIRST_RESULT_PATH=""
RECEIVER_RELEASE_PATH=""
RECEIVER_PORT=""
RECEIVER_ADDRESS_HOST=""
REMOTE_RECEIVER_READY_PATH=""
REMOTE_RECEIVER_RESULT_PATH=""
REMOTE_RECEIVER_FIRST_RESULT_PATH=""
REMOTE_RECEIVER_RELEASE_PATH=""
REMOTE_RECEIVER_PID_PATH=""
REMOTE_RECEIVER_MARKER_PATH=""

info() {
    printf '%s\n' "$*"
}

warning() {
    printf 'warning: %s\n' "$*" >&2
}

error() {
    printf 'error: %s\n' "$*" >&2
}

fail() {
    error "$*"
    return 1
}

usage() {
    sed -n '/^# USAGE:/,/^# The same unmodified/ { /^# The same unmodified/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-docker-rest-syslog-contract.sh/$SCRIPT_NAME/"
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
            --transport)
                [[ $# -ge 2 ]] || {
                    error "--transport requires a value"
                    return 2
                }
                case "$2" in
                    udp | tcp)
                        SYSLOG_TRANSPORT="$2"
                        ;;
                    *)
                        error "--transport must be udp or tcp, got: $2"
                        return 2
                        ;;
                esac
                shift 2
                ;;
            --receiver-location)
                [[ $# -ge 2 ]] || {
                    error "--receiver-location requires a value"
                    return 2
                }
                case "$2" in
                    local | colima)
                        RECEIVER_LOCATION="$2"
                        ;;
                    *)
                        error "--receiver-location must be local or colima, got: $2"
                        return 2
                        ;;
                esac
                shift 2
                ;;
            --syslog-address-host)
                [[ $# -ge 2 && -n "$2" ]] || {
                    error "--syslog-address-host requires a value"
                    return 2
                }
                SYSLOG_ADDRESS_HOST="$2"
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
}

skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        fail "$message"
        return 1
    fi
    warning "$message; skipping Docker REST Syslog contract"
    exit 0
}

run_docker() {
    if [[ -n "$DOCKER_HOST_OVERRIDE" ]]; then
        env -u DOCKER_API_VERSION DOCKER_HOST="$DOCKER_HOST_OVERRIDE" docker "$@"
    else
        env -u DOCKER_API_VERSION -u DOCKER_HOST docker "$@"
    fi
}

verify_prerequisites() {
    local cli_version
    local engine_version

    command -v docker >/dev/null 2>&1 || skip_or_fail "docker CLI is unavailable"
    command -v jq >/dev/null 2>&1 || skip_or_fail "jq is required"
    command -v python3 >/dev/null 2>&1 || skip_or_fail "python3 is required"
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
    if [[ -n "$NATIVE_CLI" && ! -x "$NATIVE_CLI" ]]; then
        skip_or_fail "native Container CLI is not executable: $NATIVE_CLI"
    fi
}

create_work_root() {
    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-syslog.XXXXXX")"
    printf '%s\n' 'Docker REST Syslog transport contract fixture root v2' \
        >"$WORK_ROOT/$ROOT_MARKER_NAME"
    RECEIVER_PORT_PATH="$WORK_ROOT/receiver.port"
    RECEIVER_RESULT_PATH="$WORK_ROOT/receiver-result.json"
    RECEIVER_FIRST_RESULT_PATH="$WORK_ROOT/receiver-first-result.json"
    RECEIVER_RELEASE_PATH="$WORK_ROOT/receiver-release"
}

start_colima_tcp_receiver() {
    local remote_stem
    local receiver_ready
    local attempt

    [[ "$SYSLOG_TRANSPORT" == "tcp" ]] \
        || fail "the Colima receiver supports only TCP"
    command -v colima >/dev/null 2>&1 \
        || skip_or_fail "colima is required for the VM-local Docker TCP reference"
    remote_stem="/tmp/$(basename "$WORK_ROOT")-receiver"
    REMOTE_RECEIVER_READY_PATH="$remote_stem.ready.json"
    REMOTE_RECEIVER_RESULT_PATH="$remote_stem.result.json"
    REMOTE_RECEIVER_FIRST_RESULT_PATH="$remote_stem.first-result.json"
    REMOTE_RECEIVER_RELEASE_PATH="$remote_stem.release"
    REMOTE_RECEIVER_PID_PATH="$remote_stem.pid"
    REMOTE_RECEIVER_MARKER_PATH="$remote_stem.marker"
    colima ssh -- rm -f -- "$REMOTE_RECEIVER_READY_PATH" \
        "$REMOTE_RECEIVER_RESULT_PATH" "$REMOTE_RECEIVER_FIRST_RESULT_PATH" \
        "$REMOTE_RECEIVER_RELEASE_PATH" "$REMOTE_RECEIVER_PID_PATH" \
        "$REMOTE_RECEIVER_MARKER_PATH"
    colima ssh -- python3 -u - "$REMOTE_RECEIVER_READY_PATH" \
        "$REMOTE_RECEIVER_RESULT_PATH" "$REMOTE_RECEIVER_FIRST_RESULT_PATH" \
        "$REMOTE_RECEIVER_RELEASE_PATH" "$REMOTE_RECEIVER_PID_PATH" \
        "$REMOTE_RECEIVER_MARKER_PATH" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import os
import socket
import sys
import time
from pathlib import Path

ready_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
first_result_path = Path(sys.argv[3])
release_path = Path(sys.argv[4])
pid_path = Path(sys.argv[5])
marker_path = Path(sys.argv[6])
for path in (ready_path, result_path, first_result_path, release_path, pid_path, marker_path):
    path.unlink(missing_ok=True)
marker_path.write_text("Docker REST Syslog TCP Colima receiver v1\n", encoding="ascii")
pid_path.write_text(str(os.getpid()), encoding="ascii")


def write_json(path, value):
    temporary_path = path.with_name(f"{path.name}.tmp")
    try:
        temporary_path.write_text(
            json.dumps(value, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def receive_connection(connection, deadline):
    payload = bytearray()
    peer_closed = False
    with connection:
        connection.settimeout(0.1)
        while time.monotonic() < deadline:
            try:
                chunk = connection.recv(1024 * 1024)
            except TimeoutError:
                if release_path.exists():
                    break
                continue
            if not chunk:
                peer_closed = True
                break
            payload.extend(chunk)
    return bytes(payload), peer_closed


server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
# Docker's logging-driver namespace reaches the Colima VM through its
# non-loopback listener even when the configured destination is 127.0.0.1.
server.bind(("0.0.0.0", 0))
server.listen(8)
server.settimeout(0.1)
ready_path.write_text(
    json.dumps({"host": "127.0.0.1", "port": server.getsockname()[1]}, sort_keys=True)
    + "\n",
    encoding="utf-8",
)
first_deadline = time.monotonic() + 30.0
first_stream = b""
first_connection_count = 0
first_peer_closed = False
post_exit_streams = []
release_timed_out = False
try:
    while first_connection_count == 0 and time.monotonic() < first_deadline:
        try:
            connection, _ = server.accept()
        except TimeoutError:
            continue
        first_connection_count = 1
        first_stream, first_peer_closed = receive_connection(connection, first_deadline)

    first_result = {
        "connectionCount": first_connection_count,
        "peerClosed": first_peer_closed,
        "streamHex": first_stream.hex(),
        "timedOut": first_connection_count != 1 or not first_stream,
        "transport": "tcp",
    }
    write_json(first_result_path, first_result)

    release_deadline = time.monotonic() + 30.0
    while first_connection_count == 1 and not release_path.exists():
        if time.monotonic() >= release_deadline:
            release_timed_out = True
            break
        try:
            connection, _ = server.accept()
        except TimeoutError:
            continue
        stream, _ = receive_connection(connection, release_deadline)
        post_exit_streams.append(stream.hex())
finally:
    server.close()
write_json(
    result_path,
    {
        "connectionCount": first_connection_count + len(post_exit_streams),
        "peerClosed": first_peer_closed,
        "postExitConnectionCount": len(post_exit_streams),
        "postExitStreamsHex": post_exit_streams,
        "releaseTimedOut": release_timed_out,
        "streamHex": first_stream.hex(),
        "timedOut": first_connection_count != 1 or not first_stream,
        "transport": "tcp",
    },
)
PY
    RECEIVER_PID=$!

    for ((attempt = 0; attempt < 120; attempt += 1)); do
        if colima ssh -- test -f "$REMOTE_RECEIVER_READY_PATH" 2>/dev/null; then
            receiver_ready="$(colima ssh -- cat "$REMOTE_RECEIVER_READY_PATH")"
            RECEIVER_PORT="$(jq -er '.port' <<<"$receiver_ready")"
            RECEIVER_ADDRESS_HOST="$(jq -er '.host' <<<"$receiver_ready")"
            [[ "$RECEIVER_PORT" =~ ^[0-9]+$ ]] \
                || fail "Colima Syslog receiver wrote an invalid port: $RECEIVER_PORT"
            [[ "$RECEIVER_ADDRESS_HOST" == "127.0.0.1" ]] \
                || fail "Colima Syslog receiver wrote an unexpected host: $RECEIVER_ADDRESS_HOST"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "Colima Syslog receiver exited before publishing its port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for Colima Syslog receiver port"
}

start_receiver() {
    if [[ "$RECEIVER_LOCATION" == "colima" ]]; then
        start_colima_tcp_receiver
        return
    fi
    RECEIVER_ADDRESS_HOST="$SYSLOG_ADDRESS_HOST"
    python3 - "$RECEIVER_PORT_PATH" "$RECEIVER_RESULT_PATH" \
        "$RECEIVER_FIRST_RESULT_PATH" "$RECEIVER_RELEASE_PATH" \
        "$RECEIVER_MESSAGE_COUNT" "$SYSLOG_TRANSPORT" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import os
import socket
import sys
import time
from pathlib import Path

port_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
first_result_path = Path(sys.argv[3])
release_path = Path(sys.argv[4])
expected_count = int(sys.argv[5])
transport = sys.argv[6]
if transport not in {"udp", "tcp"}:
    raise SystemExit(f"unsupported transport: {transport}")
deadline = time.monotonic() + 30.0
if transport == "udp":
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("127.0.0.1", 0))
    server.settimeout(0.2)
    port_path.write_text(str(server.getsockname()[1]), encoding="ascii")
    datagrams = []
    try:
        while len(datagrams) < expected_count and time.monotonic() < deadline:
            try:
                datagram, _ = server.recvfrom(1024 * 1024)
            except TimeoutError:
                continue
            datagrams.append(datagram.hex())
    finally:
        server.close()
    result = {
        "datagramsHex": datagrams,
        "expectedCount": expected_count,
        "timedOut": len(datagrams) != expected_count,
        "transport": transport,
    }
else:
    def write_json(path, value):
        temporary_path = path.with_name(f"{path.name}.tmp")
        try:
            temporary_path.write_text(
                json.dumps(value, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            os.replace(temporary_path, path)
        finally:
            temporary_path.unlink(missing_ok=True)


    def receive_connection(connection, connection_deadline):
        payload = bytearray()
        peer_closed = False
        with connection:
            connection.settimeout(0.1)
            while time.monotonic() < connection_deadline:
                try:
                    chunk = connection.recv(1024 * 1024)
                except TimeoutError:
                    if release_path.exists():
                        break
                    continue
                if not chunk:
                    peer_closed = True
                    break
                payload.extend(chunk)
        return bytes(payload), peer_closed


    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Docker Desktop and Colima resolve host.docker.internal to the host-side
    # bridge address, not loopback, for plain TCP logging.
    server.bind(("0.0.0.0", 0))
    server.listen(8)
    server.settimeout(0.1)
    port_path.write_text(str(server.getsockname()[1]), encoding="ascii")
    first_stream = b""
    first_connection_count = 0
    first_peer_closed = False
    post_exit_streams = []
    release_timed_out = False
    first_deadline = time.monotonic() + 30.0
    try:
        while first_connection_count == 0 and time.monotonic() < first_deadline:
            try:
                connection, _ = server.accept()
            except TimeoutError:
                continue
            first_connection_count = 1
            first_stream, first_peer_closed = receive_connection(connection, first_deadline)

        write_json(
            first_result_path,
            {
                "connectionCount": first_connection_count,
                "peerClosed": first_peer_closed,
                "streamHex": first_stream.hex(),
                "timedOut": first_connection_count != 1 or not first_stream,
                "transport": transport,
            },
        )

        release_deadline = time.monotonic() + 30.0
        while first_connection_count == 1 and not release_path.exists():
            if time.monotonic() >= release_deadline:
                release_timed_out = True
                break
            try:
                connection, _ = server.accept()
            except TimeoutError:
                continue
            stream, _ = receive_connection(connection, release_deadline)
            post_exit_streams.append(stream.hex())
    finally:
        server.close()
    result = {
        "connectionCount": first_connection_count + len(post_exit_streams),
        "expectedCount": expected_count,
        "peerClosed": first_peer_closed,
        "postExitConnectionCount": len(post_exit_streams),
        "postExitStreamsHex": post_exit_streams,
        "releaseTimedOut": release_timed_out,
        "streamHex": first_stream.hex(),
        "timedOut": first_connection_count != 1 or not first_stream,
        "transport": transport,
    }
if transport == "tcp":
    write_json(result_path, result)
else:
    result_path.write_text(
        json.dumps(result, sort_keys=True) + "\n",
        encoding="utf-8",
    )
PY
    RECEIVER_PID=$!

    local attempt
    for ((attempt = 0; attempt < 120; attempt += 1)); do
        if [[ -f "$RECEIVER_PORT_PATH" ]]; then
            RECEIVER_PORT="$(<"$RECEIVER_PORT_PATH")"
            [[ "$RECEIVER_PORT" =~ ^[0-9]+$ ]] \
                || fail "Syslog receiver wrote an invalid port: $RECEIVER_PORT"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "Syslog receiver exited before publishing its port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for Syslog receiver port"
}

## Wait for the first TCP stream while preserving the listener for `docker logs`.
wait_for_first_receiver_result() {
    local attempt
    local receiver_result

    [[ -n "$RECEIVER_PID" ]] || fail "Syslog receiver was not started"
    for ((attempt = 0; attempt < 600; attempt += 1)); do
        if [[ "$RECEIVER_LOCATION" == "colima" ]]; then
            if receiver_result="$(colima ssh -- cat "$REMOTE_RECEIVER_FIRST_RESULT_PATH" 2>/dev/null)" \
                && jq -e . >/dev/null <<<"$receiver_result"; then
                printf '%s\n' "$receiver_result" >"$RECEIVER_FIRST_RESULT_PATH"
                return
            fi
        elif [[ -s "$RECEIVER_FIRST_RESULT_PATH" ]] \
            && jq -e . "$RECEIVER_FIRST_RESULT_PATH" >/dev/null 2>&1; then
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "Syslog TCP receiver exited before writing its first result"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for the first Syslog TCP receiver result"
}

## Wait for a receiver after its TCP release marker, or for a complete UDP capture.
wait_for_receiver_completion() {
    [[ -n "$RECEIVER_PID" ]] || fail "Syslog receiver was not started"
    if ! wait "$RECEIVER_PID"; then
        RECEIVER_PID=""
        fail "Syslog receiver exited nonzero"
        return
    fi
    RECEIVER_PID=""
    if [[ "$RECEIVER_LOCATION" == "colima" ]]; then
        colima ssh -- cat "$REMOTE_RECEIVER_RESULT_PATH" >"$RECEIVER_RESULT_PATH" \
            || fail "Colima Syslog receiver did not write its result"
    fi
    [[ -f "$RECEIVER_RESULT_PATH" ]] \
        || fail "Syslog receiver did not write its result"
    jq -e . "$RECEIVER_RESULT_PATH" >/dev/null 2>&1 \
        || fail "Syslog receiver wrote invalid JSON"
}

## Release the held-open TCP listener and retain its post-exit connection record.
release_tcp_receiver() {
    [[ "$SYSLOG_TRANSPORT" == "tcp" ]] || return 0
    if [[ "$RECEIVER_LOCATION" == "colima" ]]; then
        colima ssh -- touch -- "$REMOTE_RECEIVER_RELEASE_PATH" \
            || fail "could not release the Colima Syslog TCP receiver"
        return
    fi
    : >"$RECEIVER_RELEASE_PATH"
}

## Verify that releasing the held-open TCP listener completed promptly.
assert_tcp_receiver_completion() {
    [[ "$SYSLOG_TRANSPORT" == "tcp" ]] || return 0
    jq -e '
        .transport == "tcp"
        and .releaseTimedOut == false
        and .connectionCount == 2
        and .postExitConnectionCount == 1
        and .postExitStreamsHex == [""]
    ' "$RECEIVER_RESULT_PATH" >/dev/null \
        || fail "Syslog TCP reader initialization differed from Docker"
}

## Select the correct receiver synchronization point for the active transport.
wait_for_receiver() {
    if [[ "$SYSLOG_TRANSPORT" == "tcp" ]]; then
        wait_for_first_receiver_result
        return
    fi
    wait_for_receiver_completion
}

## Finalize the receiver only after the public history assertion has run.
finish_receiver() {
    [[ "$SYSLOG_TRANSPORT" == "tcp" ]] || return 0
    release_tcp_receiver
    wait_for_receiver_completion
    assert_tcp_receiver_completion
}

wait_for_state() {
    local expected="$1"
    local observed=""
    local attempt

    for ((attempt = 0; attempt < 120; attempt += 1)); do
        observed="$(run_docker container inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
        if [[ "$observed" == "$expected" ]]; then
            return
        fi
        sleep 0.25
    done
    fail "$CONTAINER_NAME did not reach $expected; last state was $observed"
}

assert_public_create_identity() {
    local container_id="$1"
    local short_id
    local identifier
    local resolved_id
    local resolved_name

    [[ "$container_id" =~ ^[0-9a-f]{64}$ ]] \
        || fail "docker create returned a non-canonical container ID: $container_id"
    short_id="${container_id:0:12}"
    for identifier in "$CONTAINER_NAME" "$container_id" "$short_id"; do
        resolved_id="$(run_docker container inspect --format '{{.Id}}' "$identifier")"
        [[ "$resolved_id" == "$container_id" ]] \
            || fail "Docker identifier $identifier resolved to $resolved_id, expected $container_id"
    done
    resolved_name="$(run_docker container inspect --format '{{.Name}}' "$container_id")"
    [[ "$resolved_name" == "/$CONTAINER_NAME" ]] \
        || fail "Docker canonical ID $container_id resolved to name $resolved_name, expected /$CONTAINER_NAME"
}

assert_native_driver() {
    local inventory

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$CONTAINER_NAME" \
        'any(.[]; .id == $name and .configuration.logging.resolved.driver == "syslog")' \
        <<<"$inventory" >/dev/null \
        || fail "native authority does not expose $CONTAINER_NAME with Syslog"
}

assert_public_inspection() {
    local log_config
    local state
    local log_path
    local address="$SYSLOG_TRANSPORT://$RECEIVER_ADDRESS_HOST:$RECEIVER_PORT"

    log_config="$(run_docker container inspect --format '{{json .HostConfig.LogConfig}}' "$CONTAINER_NAME")"
    jq -e --arg address "$address" '
        .Type == "syslog"
        and .Config == {
            "cache-disabled": "true",
            "syslog-address": $address,
            "syslog-facility": "local1",
            "syslog-format": "rfc5424micro",
            "tag": "syslog.{{.Name}}.{{.ID}}"
        }
    ' <<<"$log_config" >/dev/null \
        || fail "Syslog inspect configuration differs from the Docker contract: $log_config"
    state="$(run_docker container inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
    [[ "$state" == "exited" ]] || fail "Syslog inspect state is $state, expected exited"
    log_path="$(run_docker container inspect --format '{{.LogPath}}' "$CONTAINER_NAME")"
    [[ -z "$log_path" ]] || fail "Syslog public LogPath is not empty: $log_path"
}

assert_unreadable_logs() {
    local output
    local command_status

    set +e
    output="$(run_docker logs "$CONTAINER_NAME" 2>&1)"
    command_status=$?
    set -e
    ((command_status != 0)) || fail "Syslog logging unexpectedly returned readable history"
    [[ "$output" == "Error response from daemon: configured logging driver does not support reading" ]] \
        || fail "Syslog $SYSLOG_TRANSPORT read error differs from Docker: $output"
}

assert_syslog_receiver_contract() {
    local container_id="$1"
    local receiver_result_path="$RECEIVER_RESULT_PATH"

    if [[ "$SYSLOG_TRANSPORT" == "tcp" ]]; then
        receiver_result_path="$RECEIVER_FIRST_RESULT_PATH"
    fi

    python3 - "$receiver_result_path" "$container_id" "$CONTAINER_NAME" "$SYSLOG_TRANSPORT" <<'PY'
import json
import re
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
container_id = sys.argv[2]
container_name = sys.argv[3]
transport = sys.argv[4]
if result.get("transport") != transport or result.get("timedOut") is not False:
    raise SystemExit(f"Syslog {transport} receiver timed out or changed transport: {result!r}")
if transport == "udp":
    datagrams = result.get("datagramsHex")
    if not isinstance(datagrams, list) or len(datagrams) != 3:
        raise SystemExit(f"expected three Syslog UDP datagrams, got {result!r}")
    frames = [bytes.fromhex(value) for value in datagrams]
    expected_contents = [
        b"stdout-ascii\n",
        "stderr-utf8-☃\n".encode("utf-8"),
        b"stdout-binary-\xff\x00-end\n",
    ]
else:
    if result.get("connectionCount") != 1:
        raise SystemExit(f"expected one Syslog TCP connection, got {result!r}")
    if result.get("peerClosed") is not True:
        raise SystemExit(f"Syslog TCP peer did not close after container exit: {result!r}")
    stream = bytes.fromhex(result.get("streamHex", ""))
    if not stream.endswith(b"\n"):
        raise SystemExit(f"Syslog TCP stream is not LF-delimited: {stream!r}")
    frames_with_delimiter = stream.splitlines(keepends=True)
    if len(frames_with_delimiter) != 3 or any(
        not frame.endswith(b"\n") for frame in frames_with_delimiter
    ):
        raise SystemExit(f"expected three LF-delimited Syslog TCP frames, got {stream!r}")
    frames = [frame[:-1] for frame in frames_with_delimiter]
    expected_contents = [
        b"stdout-ascii",
        "stderr-utf8-☃".encode("utf-8"),
        b"stdout-binary-\xff\x00-end",
    ]
pattern = re.compile(rb"^<(\d+)>1 (\S+) (\S+) (\S+) (\d+) (\S+) - (.*)$", re.DOTALL)
expected_priority = [142, 139, 142]
expected_tag = f"syslog.{container_name.lstrip('/')}.{container_id[:12]}".encode("ascii")
for index, (frame, content, priority) in enumerate(zip(frames, expected_contents, expected_priority), start=1):
    match = pattern.fullmatch(frame)
    if match is None:
        raise SystemExit(f"Syslog {transport} frame {index} is not an RFC 5424 message: {frame!r}")
    observed_priority = int(match.group(1))
    timestamp = match.group(2).decode("ascii")
    hostname = match.group(3)
    app_name = match.group(4)
    process_id = match.group(5)
    message_id = match.group(6)
    observed_content = match.group(7)
    if observed_priority != priority:
        raise SystemExit(f"Syslog {transport} frame {index} priority {observed_priority}, expected {priority}")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}(?:Z|[+-]\d{2}:\d{2})", timestamp):
        raise SystemExit(f"Syslog {transport} frame {index} timestamp is not RFC 3339 microseconds: {timestamp!r}")
    if not hostname or app_name != expected_tag or message_id != expected_tag:
        raise SystemExit(
            f"Syslog {transport} frame {index} identity differs: hostname={hostname!r}, app={app_name!r}, messageID={message_id!r}"
        )
    if not process_id.isdigit() or int(process_id) <= 0:
        raise SystemExit(f"Syslog {transport} frame {index} has invalid process ID: {process_id!r}")
    if observed_content != content:
        raise SystemExit(
            f"Syslog {transport} frame {index} payload differs: {observed_content!r}, expected {content!r}"
        )
PY
}

monotonic_seconds() {
    python3 - <<'PY'
import time
print(f"{time.monotonic():.9f}")
PY
}

write_result() {
    local duration_seconds="$1"
    local container_id="$2"
    local contract="Docker REST Syslog UDP"
    local receiver_capture

    [[ -n "$RESULT_PATH" ]] || return
    [[ -d "$(dirname "$RESULT_PATH")" ]] \
        || fail "result parent directory does not exist: $(dirname "$RESULT_PATH")"
    if [[ "$SYSLOG_TRANSPORT" == "tcp" ]]; then
        contract="Docker REST Syslog TCP"
    fi
    receiver_capture="$(jq -c . "$RECEIVER_RESULT_PATH")"
    jq -n \
        --arg contract "$contract" \
        --arg endpoint "${DOCKER_HOST_OVERRIDE:-default-context}" \
        --arg containerID "$container_id" \
        --argjson durationSeconds "$duration_seconds" \
        --argjson receiverCapture "$receiver_capture" \
        '{contract: $contract, endpoint: $endpoint, durationSeconds: $durationSeconds, result: "passed", containerID: $containerID, receiverCapture: $receiverCapture}' \
        >"$RESULT_PATH"
}

cleanup() {
    local temporary_parent="${TMPDIR:-/tmp}"
    local remote_pid=""

    if [[ -n "$RECEIVER_PID" ]] && kill -0 "$RECEIVER_PID" 2>/dev/null; then
        kill "$RECEIVER_PID" 2>/dev/null || true
        wait "$RECEIVER_PID" 2>/dev/null || true
    fi
    if [[ -n "$CONTAINER_ID" ]]; then
        run_docker rm --force "$CONTAINER_ID" >/dev/null 2>&1 || true
    elif [[ -n "$CONTAINER_NAME" ]]; then
        run_docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n "$REMOTE_RECEIVER_MARKER_PATH" ]] \
        && colima ssh -- test -f "$REMOTE_RECEIVER_MARKER_PATH" 2>/dev/null; then
        if [[ -n "$REMOTE_RECEIVER_PID_PATH" ]] \
            && colima ssh -- test -s "$REMOTE_RECEIVER_PID_PATH" 2>/dev/null; then
            remote_pid="$(colima ssh -- cat "$REMOTE_RECEIVER_PID_PATH" 2>/dev/null || true)"
            if [[ "$remote_pid" =~ ^[0-9]+$ ]]; then
                colima ssh -- kill "$remote_pid" >/dev/null 2>&1 || true
            fi
        fi
        colima ssh -- rm -f -- "$REMOTE_RECEIVER_READY_PATH" \
            "$REMOTE_RECEIVER_RESULT_PATH" "$REMOTE_RECEIVER_FIRST_RESULT_PATH" \
            "$REMOTE_RECEIVER_RELEASE_PATH" "$REMOTE_RECEIVER_PID_PATH" \
            "$REMOTE_RECEIVER_MARKER_PATH" \
            || error "could not remove marker-protected Colima Syslog receiver paths"
        # shellcheck disable=SC2016
        if ! colima ssh -- sh -c \
            'test ! -e "$1" && test ! -e "$2" && test ! -e "$3" && test ! -e "$4" && test ! -e "$5" && test ! -e "$6"' \
            cleanup "$REMOTE_RECEIVER_READY_PATH" "$REMOTE_RECEIVER_RESULT_PATH" \
            "$REMOTE_RECEIVER_FIRST_RESULT_PATH" "$REMOTE_RECEIVER_RELEASE_PATH" \
            "$REMOTE_RECEIVER_PID_PATH" "$REMOTE_RECEIVER_MARKER_PATH" 2>/dev/null; then
            error "Colima Syslog receiver cleanup left VM paths"
        fi
    fi
    if [[ -n "$WORK_ROOT" && "$WORK_ROOT" == "$temporary_parent"/container-rest-syslog.* \
        && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
}

main() {
    local suffix
    local container_id
    local started_at
    local finished_at
    local duration_seconds
    local workload

    parse_args "$@"
    verify_prerequisites
    create_work_root
    suffix="$(basename "$WORK_ROOT" | tr '.[:upper:]' '-[:lower:]')"
    CONTAINER_NAME="cc-rest-syslog-$suffix"
    start_receiver
    workload='printf '\''stdout-ascii\n'\''; sleep 0.2; printf '\''stderr-utf8-\342\230\203\n'\'' >&2; sleep 0.2; printf '\''stdout-binary-\377\000-end\n'\'''
    container_id="$(run_docker create --name "$CONTAINER_NAME" \
        --log-driver syslog --log-opt cache-disabled=true \
        --log-opt "syslog-address=$SYSLOG_TRANSPORT://$RECEIVER_ADDRESS_HOST:$RECEIVER_PORT" \
        --log-opt syslog-facility=local1 --log-opt syslog-format=rfc5424micro \
        --log-opt 'tag=syslog.{{.Name}}.{{.ID}}' \
        "$REQUIRED_DISPLAY_IMAGE" /bin/sh -c "$workload")"
    [[ -n "$container_id" ]] || fail "docker create returned an empty Syslog identifier"
    CONTAINER_ID="$container_id"
    assert_public_create_identity "$container_id"
    assert_native_driver
    started_at="$(monotonic_seconds)"
    run_docker start "$container_id" >/dev/null
    wait_for_state exited
    wait_for_receiver
    finished_at="$(monotonic_seconds)"
    duration_seconds="$(python3 - "$started_at" "$finished_at" <<'PY'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.9f}")
PY
    )"
    assert_public_inspection
    assert_syslog_receiver_contract "$container_id"
    assert_unreadable_logs
    finish_receiver
    write_result "$duration_seconds" "$container_id"
    info "Docker REST Syslog $SYSLOG_TRANSPORT contract passed in ${duration_seconds}s"
}

trap cleanup EXIT
main "$@"
