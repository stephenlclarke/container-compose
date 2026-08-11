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
#   check-docker-rest-gelf-contract.sh [options]
#
# OPTIONS:
#   --host HOST        Docker endpoint to exercise, such as unix:///tmp/docker.sock.
#   --gelf-address-host HOST
#                      Hostname or address visible to the selected log driver.
#   --transport MODE   GELF transport to prove: udp (default) or tcp.
#   --scenario MODE    Fixture to prove: standard (default), tcp-reconnect,
#                      tcp-retry-delay, tcp-failure, or tcp-unavailable.
#   --native-cli PATH  Optional Container CLI used to prove one shared authority.
#   --work-root PATH   Empty, marker-protected /private/tmp root to use for
#                      retained fixture evidence.
#   --retain-work-root Preserve --work-root after cleanup for evidence review.
#   --reference        Require the pinned Docker Engine 29.2.1 oracle.
#   --result PATH      Write machine-readable timing and result evidence to PATH.
#   --strict           Fail instead of skipping when a prerequisite is unavailable.
#   -h, --help         Show this help.
#
# The same unmodified Docker CLI fixture exercises Docker Engine 29.2.1 and
# Container's public socket. It proves GELF UDP gzip or TCP NUL framing,
# selected metadata and tag expansion, Docker inspect state, unreadable remote
# logs, native authority visibility, and marker-protected cleanup. The
# tcp-reconnect scenario closes the first TCP peer after one frame and proves
# Docker's configured reconnect path carries valid, ordered recovery bytes and
# a terminal record without duplicating or corrupting output. tcp-retry-delay
# resets two peers with a positive reconnect budget and a one-second delay.
# tcp-failure resets two peers with a zero reconnect budget to prove Docker's
# per-write exhaustion/replacement semantics. tcp-unavailable preserves
# Docker's create-success/start-failure lifecycle for an initially unreachable
# TCP sink.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly REQUIRED_CLI_VERSION="29.7.1"
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly REQUIRED_DISPLAY_IMAGE="alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-gelf-root"
readonly RECEIVER_MESSAGE_COUNT=3
readonly RECONNECT_OUTPUT_BYTES=1048576
readonly TCP_FAILURE_RESET_CONNECTIONS=2
readonly TCP_DELAYED_RETRY_RESET_CONNECTIONS=2
readonly TCP_DELAYED_RETRY_MAX_RECONNECTS=2
readonly TCP_DELAYED_RETRY_DELAY_SECONDS=1
readonly TCP_DELAYED_RETRY_MIN_INTERVAL_SECONDS=0.75

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
# Both Docker Engine and Container's Engine-Linux TCP relay initiate this
# connection from a guest context on macOS.  The bridge alias reaches the
# host-side receiver without silently changing a caller's explicitly supplied
# literal loopback address.
GELF_ADDRESS_HOST="host.docker.internal"
TRANSPORT="udp"
SCENARIO="standard"
NATIVE_CLI=""
RESULT_PATH=""
WORK_ROOT=""
EXPLICIT_WORK_ROOT=""
RETAIN_WORK_ROOT=0
CONTAINER_NAME=""
CONTAINER_ID=""
RECEIVER_PID=""
RECEIVER_PORT_PATH=""
RECEIVER_RESULT_PATH=""
RECEIVER_FINISH_PATH=""
RECEIVER_PRIMARY_COMPLETE_PATH=""
RECEIVER_RECONNECT_COMPLETE_PATH=""
RECEIVER_FAILURE_COMPLETE_PATH=""
RECEIVER_DELAY_COMPLETE_PATH=""
RECEIVER_PORT=""

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
        | sed "s/check-docker-rest-gelf-contract.sh/$SCRIPT_NAME/"
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
            --gelf-address-host)
                [[ $# -ge 2 && -n "$2" ]] || {
                    error "--gelf-address-host requires a value"
                    return 2
                }
                GELF_ADDRESS_HOST="$2"
                shift 2
                ;;
            --transport)
                [[ $# -ge 2 && -n "$2" ]] || {
                    error "--transport requires a value"
                    return 2
                }
                case "$2" in
                    udp | tcp)
                        TRANSPORT="$2"
                        ;;
                    *)
                        error "--transport must be udp or tcp, got: $2"
                        return 2
                        ;;
                esac
                shift 2
                ;;
            --scenario)
                [[ $# -ge 2 && -n "$2" ]] || {
                    error "--scenario requires a value"
                    return 2
                }
                case "$2" in
                    standard | tcp-reconnect | tcp-retry-delay | tcp-failure | tcp-unavailable)
                        SCENARIO="$2"
                        ;;
                    *)
                        error "--scenario must be standard, tcp-reconnect, tcp-retry-delay, tcp-failure, or tcp-unavailable, got: $2"
                        return 2
                        ;;
                esac
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

    if [[ "$SCENARIO" != "standard" && "$TRANSPORT" != "tcp" ]]; then
        error "--scenario $SCENARIO requires --transport tcp"
        return 2
    fi
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
    warning "$message; skipping Docker REST GELF contract"
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

# Verify the required public client and endpoint are available.
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

# Create the marker-protected root for receiver state and fixture output.
create_work_root() {
    if [[ -n "$EXPLICIT_WORK_ROOT" ]]; then
        WORK_ROOT="$EXPLICIT_WORK_ROOT"
        [[ "$WORK_ROOT" == /private/tmp/container-rest-gelf.* ]] \
            || fail "--work-root must be an isolated /private/tmp/container-rest-gelf.* directory: $WORK_ROOT"
        [[ -d "$WORK_ROOT" ]] \
            || fail "--work-root must already exist: $WORK_ROOT"
        [[ ! -L "$WORK_ROOT" ]] \
            || fail "--work-root must not be a symlink: $WORK_ROOT"
        local canonical_work_root
        canonical_work_root="$(cd -P -- "$WORK_ROOT" && pwd -P)" \
            || fail "--work-root cannot be resolved safely: $WORK_ROOT"
        [[ "$canonical_work_root" == /private/tmp/container-rest-gelf.* ]] \
            || fail "--work-root resolved outside its isolated namespace: $WORK_ROOT"
        WORK_ROOT="$canonical_work_root"
        [[ ! -e "$WORK_ROOT/$ROOT_MARKER_NAME" ]] \
            || fail "--work-root already has the fixture marker: $WORK_ROOT"
        [[ -z "$(find "$WORK_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
            || fail "--work-root must be empty before the fixture starts: $WORK_ROOT"
    else
        WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-gelf.XXXXXX")"
    fi
    printf '%s\n' 'Docker REST GELF contract fixture root v1' \
        >"$WORK_ROOT/$ROOT_MARKER_NAME"
    RECEIVER_PORT_PATH="$WORK_ROOT/receiver.port"
    RECEIVER_RESULT_PATH="$WORK_ROOT/receiver-result.json"
    RECEIVER_FINISH_PATH="$WORK_ROOT/receiver.finish"
    RECEIVER_PRIMARY_COMPLETE_PATH="$WORK_ROOT/receiver.primary-complete"
    RECEIVER_RECONNECT_COMPLETE_PATH="$WORK_ROOT/receiver.reconnect-complete"
    RECEIVER_FAILURE_COMPLETE_PATH="$WORK_ROOT/receiver.failure-complete"
    RECEIVER_DELAY_COMPLETE_PATH="$WORK_ROOT/receiver.delay-complete"
}

# Start the selected bounded host-side receiver used by both Docker and Container.
start_receiver() {
    if [[ "$SCENARIO" == "tcp-reconnect" ]]; then
        start_tcp_reconnect_receiver
        return
    fi
    if [[ "$SCENARIO" == "tcp-retry-delay" ]]; then
        start_tcp_delayed_retry_receiver
        return
    fi
    if [[ "$SCENARIO" == "tcp-failure" ]]; then
        start_tcp_failure_receiver
        return
    fi
    if [[ "$SCENARIO" == "tcp-unavailable" ]]; then
        reserve_unavailable_tcp_port
        return
    fi

    case "$TRANSPORT" in
        udp)
            start_udp_receiver
            ;;
        tcp)
            start_tcp_receiver
            ;;
        *)
            fail "unsupported GELF transport: $TRANSPORT"
            ;;
    esac
}

# Reserve and release one local TCP port immediately before Docker starts. The
# selected fixture proves an initial connection refusal, not a slow listener.
reserve_unavailable_tcp_port() {
    RECEIVER_PORT="$(python3 - <<'PY'
import socket

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.bind(("127.0.0.1", 0))
print(server.getsockname()[1])
server.close()
PY
    )"
    [[ "$RECEIVER_PORT" =~ ^[0-9]+$ ]] \
        || fail "failed to reserve an unavailable GELF TCP port: $RECEIVER_PORT"
}

# Start a TCP receiver that forces Docker's configured GELF reconnect path.
start_tcp_reconnect_receiver() {
    python3 - "$RECEIVER_PORT_PATH" "$RECEIVER_RESULT_PATH" \
        "$RECEIVER_FINISH_PATH" "$RECEIVER_RECONNECT_COMPLETE_PATH" \
        "$WORK_ROOT/receiver-first-stream.bin" "$WORK_ROOT/receiver-reconnect-stream.bin" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import socket
import sys
import time
from pathlib import Path

port_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
finish_path = Path(sys.argv[3])
complete_path = Path(sys.argv[4])
first_stream_path = Path(sys.argv[5])
reconnect_stream_path = Path(sys.argv[6])
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", 0))
server.listen(8)
server.settimeout(0.2)
port_path.write_text(str(server.getsockname()[1]), encoding="ascii")
first_stream = bytearray()
reconnect_stream = bytearray()
accepted_connections = 0
connection = None
connection_index = 0
first_closed_by_receiver = False
reconnect_marker_seen = False
second_peer_closed = False
deadline = time.monotonic() + 35.0
try:
    while time.monotonic() < deadline:
        if reconnect_marker_seen and second_peer_closed and finish_path.exists():
            break
        if connection is None:
            try:
                connection, _ = server.accept()
                accepted_connections += 1
                connection_index = accepted_connections
                connection.settimeout(0.2)
            except TimeoutError:
                continue
        try:
            chunk = connection.recv(1024 * 1024)
        except TimeoutError:
            continue
        if not chunk:
            connection.close()
            connection = None
            if connection_index == 2:
                second_peer_closed = True
                if reconnect_marker_seen:
                    complete_path.write_text("complete\n", encoding="ascii")
            continue
        if connection_index == 1:
            first_stream.extend(chunk)
            if b"\0" in first_stream:
                connection.shutdown(socket.SHUT_WR)
                connection.close()
                connection = None
                first_closed_by_receiver = True
        elif connection_index == 2:
            reconnect_stream.extend(chunk)
            if b"reconnect-complete" in reconnect_stream:
                reconnect_marker_seen = True
        # Later connections can be opened by Docker's unreadable-history
        # initialization. Retain the listener until the shell fixture finishes.
finally:
    if connection is not None:
        connection.close()
    server.close()
    first_stream_path.write_bytes(first_stream)
    reconnect_stream_path.write_bytes(reconnect_stream)
    result_path.write_text(
        json.dumps(
            {
                "acceptedConnections": accepted_connections,
                "firstClosedByReceiver": first_closed_by_receiver,
                "firstFrameCount": first_stream.count(0),
                "firstStreamBytes": len(first_stream),
                "reconnectComplete": complete_path.exists(),
                "reconnectFrameCount": reconnect_stream.count(0),
                "reconnectMarkerSeen": reconnect_marker_seen,
                "reconnectStreamBytes": len(reconnect_stream),
                "secondPeerClosed": second_peer_closed,
                "timedOut": not (reconnect_marker_seen and second_peer_closed and finish_path.exists()),
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
                || fail "GELF receiver wrote an invalid port: $RECEIVER_PORT"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "GELF receiver exited before publishing its port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for GELF receiver port"
}

# Start a TCP receiver that resets two peers. A zero reconnect budget makes the
# failed record terminal while Docker retains the final replacement socket for
# the next record; the later stream proves that exact replacement behavior.
start_tcp_failure_receiver() {
    python3 - "$RECEIVER_PORT_PATH" "$RECEIVER_RESULT_PATH" \
        "$RECEIVER_FINISH_PATH" "$RECEIVER_FAILURE_COMPLETE_PATH" \
        "$TCP_FAILURE_RESET_CONNECTIONS" "$WORK_ROOT/receiver-failure-stream-1.bin" \
        "$WORK_ROOT/receiver-failure-stream-2.bin" \
        "$WORK_ROOT/receiver-failure-recovery-stream.bin" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import socket
import struct
import sys
import time
from pathlib import Path

port_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
finish_path = Path(sys.argv[3])
complete_path = Path(sys.argv[4])
reset_connection_count = int(sys.argv[5])
reset_stream_paths = [Path(sys.argv[6]), Path(sys.argv[7])]
recovery_stream_path = Path(sys.argv[8])
if reset_connection_count != len(reset_stream_paths):
    raise SystemExit("configured reset count does not match receiver streams")
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", 0))
server.listen(8)
server.settimeout(0.2)
port_path.write_text(str(server.getsockname()[1]), encoding="ascii")
reset_streams = [bytearray() for _ in range(reset_connection_count)]
recovery_stream = bytearray()
accepted_connections = 0
forced_closed_connections = 0
recovery_connection_index = 0
recovery_terminal_seen = False
recovery_peer_closed = False
connection = None
connection_index = 0
deadline = time.monotonic() + 35.0
try:
    while time.monotonic() < deadline:
        if recovery_terminal_seen and recovery_peer_closed and finish_path.exists():
            break
        if connection is None:
            try:
                connection, _ = server.accept()
                accepted_connections += 1
                connection_index = accepted_connections
                connection.settimeout(0.2)
            except TimeoutError:
                continue
        try:
            chunk = connection.recv(1024 * 1024)
        except TimeoutError:
            continue
        if not chunk:
            connection.close()
            connection = None
            if connection_index == reset_connection_count + 1:
                recovery_peer_closed = True
                if recovery_terminal_seen:
                    complete_path.write_text("complete\n", encoding="ascii")
            continue
        if connection_index <= reset_connection_count:
            stream = reset_streams[connection_index - 1]
            stream.extend(chunk)
            if b"\0" in stream:
                connection.setsockopt(
                    socket.SOL_SOCKET,
                    socket.SO_LINGER,
                    struct.pack("ii", 1, 0),
                )
                connection.close()
                connection = None
                forced_closed_connections += 1
        elif connection_index == reset_connection_count + 1:
            recovery_connection_index = connection_index
            recovery_stream.extend(chunk)
            if b"after-complete" in recovery_stream:
                recovery_terminal_seen = True
        # Later connections can be opened by Docker's unreadable-history
        # initialization. Retain the listener until the shell fixture finishes.
finally:
    if connection is not None:
        connection.close()
    server.close()
    for path, stream in zip(reset_stream_paths, reset_streams):
        path.write_bytes(stream)
    recovery_stream_path.write_bytes(recovery_stream)
    result_path.write_text(
        json.dumps(
            {
                "acceptedConnections": accepted_connections,
                "forcedClosedConnections": forced_closed_connections,
                "recoveryConnectionIndex": recovery_connection_index,
                "recoveryFrameCount": recovery_stream.count(0),
                "recoveryPeerClosed": recovery_peer_closed,
                "recoveryTerminalSeen": recovery_terminal_seen,
                "resetFrameCounts": [stream.count(0) for stream in reset_streams],
                "timedOut": not (
                    recovery_terminal_seen
                    and recovery_peer_closed
                    and finish_path.exists()
                ),
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
                || fail "GELF receiver wrote an invalid port: $RECEIVER_PORT"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "GELF receiver exited before publishing its port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for GELF receiver port"
}

# Start a TCP receiver that proves Docker waits between two configured retries.
# Each reset peer receives one complete frame, while the third connection
# retains the ordered recovery stream through normal container shutdown.
start_tcp_delayed_retry_receiver() {
    python3 - "$RECEIVER_PORT_PATH" "$RECEIVER_RESULT_PATH" \
        "$RECEIVER_FINISH_PATH" "$RECEIVER_DELAY_COMPLETE_PATH" \
        "$TCP_DELAYED_RETRY_RESET_CONNECTIONS" "$WORK_ROOT/receiver-delay-stream-1.bin" \
        "$WORK_ROOT/receiver-delay-stream-2.bin" \
        "$WORK_ROOT/receiver-delay-recovery-stream.bin" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import socket
import struct
import sys
import time
from pathlib import Path

port_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
finish_path = Path(sys.argv[3])
complete_path = Path(sys.argv[4])
reset_connection_count = int(sys.argv[5])
reset_stream_paths = [Path(sys.argv[6]), Path(sys.argv[7])]
recovery_stream_path = Path(sys.argv[8])
if reset_connection_count != len(reset_stream_paths):
    raise SystemExit("configured reset count does not match receiver streams")
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", 0))
server.listen(8)
server.settimeout(0.2)
port_path.write_text(str(server.getsockname()[1]), encoding="ascii")
reset_streams = [bytearray() for _ in range(reset_connection_count)]
recovery_stream = bytearray()
accepted_connections = 0
accepted_at = []
forced_closed_connections = 0
reset_closed_at = []
recovery_connection_index = 0
recovery_terminal_seen = False
recovery_peer_closed = False
connection = None
connection_index = 0
deadline = time.monotonic() + 60.0
try:
    while time.monotonic() < deadline:
        if recovery_terminal_seen and recovery_peer_closed and finish_path.exists():
            break
        if connection is None:
            try:
                connection, _ = server.accept()
                accepted_connections += 1
                connection_index = accepted_connections
                accepted_at.append(time.monotonic())
                connection.settimeout(0.2)
            except TimeoutError:
                continue
        try:
            chunk = connection.recv(1024 * 1024)
        except TimeoutError:
            continue
        if not chunk:
            connection.close()
            connection = None
            if connection_index == reset_connection_count + 1:
                recovery_peer_closed = True
                if recovery_terminal_seen:
                    complete_path.write_text("complete\n", encoding="ascii")
            continue
        if connection_index <= reset_connection_count:
            stream = reset_streams[connection_index - 1]
            stream.extend(chunk)
            if b"\0" in stream:
                connection.setsockopt(
                    socket.SOL_SOCKET,
                    socket.SO_LINGER,
                    struct.pack("ii", 1, 0),
                )
                connection.close()
                connection = None
                forced_closed_connections += 1
                reset_closed_at.append(time.monotonic())
        elif connection_index == reset_connection_count + 1:
            recovery_connection_index = connection_index
            recovery_stream.extend(chunk)
            if b"after-retry-delay-complete" in recovery_stream:
                recovery_terminal_seen = True
        # Later connections can be opened by Docker's unreadable-history
        # initialization. Retain the listener until the shell fixture finishes.
finally:
    if connection is not None:
        connection.close()
    server.close()
    for path, stream in zip(reset_stream_paths, reset_streams):
        path.write_bytes(stream)
    recovery_stream_path.write_bytes(recovery_stream)
    reconnect_intervals = [
        accepted_at[index + 1] - reset_closed_at[index]
        for index in range(min(len(reset_closed_at), len(accepted_at) - 1))
    ]
    result_path.write_text(
        json.dumps(
            {
                "acceptedConnections": accepted_connections,
                "forcedClosedConnections": forced_closed_connections,
                "reconnectIntervalsSeconds": reconnect_intervals,
                "recoveryConnectionIndex": recovery_connection_index,
                "recoveryFrameCount": recovery_stream.count(0),
                "recoveryPeerClosed": recovery_peer_closed,
                "recoveryTerminalSeen": recovery_terminal_seen,
                "resetFrameCounts": [stream.count(0) for stream in reset_streams],
                "timedOut": not (
                    recovery_terminal_seen
                    and recovery_peer_closed
                    and finish_path.exists()
                ),
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
                || fail "GELF receiver wrote an invalid port: $RECEIVER_PORT"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "GELF receiver exited before publishing its port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for GELF receiver port"
}

# Start a bounded host-side UDP receiver for Docker's compressed GELF records.
start_udp_receiver() {
    python3 - "$RECEIVER_PORT_PATH" "$RECEIVER_RESULT_PATH" "$RECEIVER_MESSAGE_COUNT" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import socket
import sys
import time
from pathlib import Path

port_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
expected_count = int(sys.argv[3])
server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
server.bind(("0.0.0.0", 0))
server.settimeout(0.2)
port_path.write_text(str(server.getsockname()[1]), encoding="ascii")
datagrams = []
deadline = time.monotonic() + 20.0
while len(datagrams) < expected_count and time.monotonic() < deadline:
    try:
        datagram, _ = server.recvfrom(1024 * 1024)
    except TimeoutError:
        continue
    datagrams.append(datagram.hex())
server.close()
result_path.write_text(
    json.dumps(
        {
            "datagramsHex": datagrams,
            "expectedCount": expected_count,
            "timedOut": len(datagrams) != expected_count,
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
                || fail "GELF receiver wrote an invalid port: $RECEIVER_PORT"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "GELF receiver exited before publishing its port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for GELF receiver port"
}

# Start a bounded host-side TCP receiver for Docker's NUL-delimited GELF records.
start_tcp_receiver() {
    python3 - "$RECEIVER_PORT_PATH" "$RECEIVER_RESULT_PATH" \
        "$RECEIVER_FINISH_PATH" "$RECEIVER_PRIMARY_COMPLETE_PATH" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import socket
import sys
import time
from pathlib import Path

port_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
finish_path = Path(sys.argv[3])
primary_complete_path = Path(sys.argv[4])
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", 0))
server.listen(1)
server.settimeout(0.2)
port_path.write_text(str(server.getsockname()[1]), encoding="ascii")
stream = bytearray()
accepted_connections = 0
primary_peer_closed = False
connection = None
deadline = time.monotonic() + 20.0
try:
    while time.monotonic() < deadline:
        if primary_peer_closed and finish_path.exists():
            break
        if connection is None:
            try:
                connection, _ = server.accept()
                accepted_connections += 1
                connection.settimeout(0.2)
            except TimeoutError:
                continue
        try:
            chunk = connection.recv(1024 * 1024)
        except TimeoutError:
            continue
        if not chunk:
            connection.close()
            connection = None
            if accepted_connections == 1:
                primary_peer_closed = True
                primary_complete_path.write_text("closed\n", encoding="ascii")
            continue
        if accepted_connections == 1:
            stream.extend(chunk)
finally:
    if connection is not None:
        connection.close()
    server.close()
result_path.write_text(
    json.dumps(
        {
            "accepted": accepted_connections > 0,
            "acceptedConnections": accepted_connections,
            "finished": finish_path.exists(),
            "peerClosed": primary_peer_closed,
            "streamHex": bytes(stream).hex(),
            "timedOut": not (primary_peer_closed and finish_path.exists()),
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
                || fail "GELF receiver wrote an invalid port: $RECEIVER_PORT"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "GELF receiver exited before publishing its port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for GELF receiver port"
}

# Wait for the bounded receiver to finish without hiding its exit result.
wait_for_receiver() {
    local status

    set +e
    wait "$RECEIVER_PID"
    status=$?
    set -e
    RECEIVER_PID=""
    ((status == 0)) || fail "GELF receiver exited with status $status"
}

# Wait for TCP's primary delivery connection to close while retaining the
# listener for Docker's later unreadable-history initialization attempt.
wait_for_tcp_primary_close() {
    local attempt

    [[ "$TRANSPORT" == "tcp" ]] || return 0
    for ((attempt = 0; attempt < 100; attempt += 1)); do
        [[ -f "$RECEIVER_PRIMARY_COMPLETE_PATH" ]] && return
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "GELF TCP receiver exited before the primary peer closed"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for the GELF TCP primary peer to close"
}

# Wait for the reconnect receiver to see the replacement peer close cleanly.
wait_for_tcp_reconnect_complete() {
    local attempt

    [[ "$SCENARIO" == "tcp-reconnect" ]] || return 0
    for ((attempt = 0; attempt < 160; attempt += 1)); do
        [[ -f "$RECEIVER_RECONNECT_COMPLETE_PATH" ]] && return
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "GELF TCP reconnect receiver exited before the replacement peer closed"
            return
        fi
        sleep 0.25
    done
    fail "timed out waiting for the GELF TCP reconnect peer to close"
}

# Wait for the delayed-retry receiver to finish its retained recovery peer.
wait_for_tcp_delayed_retry_complete() {
    local attempt
    local receiver_result="receiver did not write a result"

    [[ "$SCENARIO" == "tcp-retry-delay" ]] || return 0
    for ((attempt = 0; attempt < 220; attempt += 1)); do
        [[ -f "$RECEIVER_DELAY_COMPLETE_PATH" ]] && return
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            if [[ -f "$RECEIVER_RESULT_PATH" ]]; then
                receiver_result="$(<"$RECEIVER_RESULT_PATH")"
            fi
            fail "GELF TCP delayed-retry receiver exited before the recovery peer closed: $receiver_result"
            return
        fi
        sleep 0.25
    done
    fail "timed out waiting for the GELF TCP delayed-retry recovery peer to close"
}

# Wait for the exhausted-retry receiver's retained replacement peer to close.
wait_for_tcp_failure_complete() {
    local attempt
    local receiver_result="receiver did not write a result"

    [[ "$SCENARIO" == "tcp-failure" ]] || return 0
    for ((attempt = 0; attempt < 160; attempt += 1)); do
        [[ -f "$RECEIVER_FAILURE_COMPLETE_PATH" ]] && return
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            if [[ -f "$RECEIVER_RESULT_PATH" ]]; then
                receiver_result="$(<"$RECEIVER_RESULT_PATH")"
            fi
            fail "GELF TCP failure receiver exited before the retained replacement peer closed: $receiver_result"
            return
        fi
        sleep 0.25
    done
    fail "timed out waiting for the GELF TCP retained replacement peer to close"
}

# Let the TCP receiver finish after the unreadable-history check has had a
# listener available for Docker's logger initialization path.
finish_tcp_receiver() {
    [[ "$TRANSPORT" == "tcp" ]] || return 0
    printf '%s\n' 'finish' >"$RECEIVER_FINISH_PATH"
}

# Wait until the public Docker API reports the expected lifecycle state.
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

# Confirm the optional native CLI observes the same selected logging driver.
assert_native_driver() {
    local inventory

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$CONTAINER_NAME" \
        'any(.[]; .id == $name and .configuration.logging.resolved.driver == "gelf")' \
        <<<"$inventory" >/dev/null \
        || fail "native authority does not expose $CONTAINER_NAME with GELF"
}

# Assert the Docker create response has a canonical identity while name and
# full/short ID route aliases all resolve to the same object.
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

# Assert public Docker inspect preserves the expected remote logging state.
assert_public_inspection() {
    local log_config
    local state
    local log_path
    local address="$TRANSPORT://$GELF_ADDRESS_HOST:$RECEIVER_PORT"

    log_config="$(run_docker container inspect --format '{{json .HostConfig.LogConfig}}' "$CONTAINER_NAME")"
    if [[ "$SCENARIO" == "tcp-reconnect" ]]; then
        jq -e --arg address "$address" '
            .Type == "gelf"
            and .Config == {
                "cache-disabled": "true",
                "env": "ORACLE_ENV",
                "gelf-address": $address,
                "gelf-tcp-max-reconnect": "1",
                "gelf-tcp-reconnect-delay": "0",
                "labels": "oracle.label",
                "tag": "gelf.{{.Name}}.{{.ID}}"
            }
        ' <<<"$log_config" >/dev/null \
            || fail "GELF TCP reconnect inspect configuration differs from the Docker contract: $log_config"
    elif [[ "$SCENARIO" == "tcp-retry-delay" ]]; then
        jq -e --arg address "$address" '
            .Type == "gelf"
            and .Config == {
                "cache-disabled": "true",
                "env": "ORACLE_ENV",
                "gelf-address": $address,
                "gelf-tcp-max-reconnect": "2",
                "gelf-tcp-reconnect-delay": "1",
                "labels": "oracle.label",
                "tag": "gelf.{{.Name}}.{{.ID}}"
            }
        ' <<<"$log_config" >/dev/null \
            || fail "GELF TCP delayed-retry inspect configuration differs from the Docker contract: $log_config"
    elif [[ "$SCENARIO" == "tcp-failure" ]]; then
        jq -e --arg address "$address" '
            .Type == "gelf"
            and .Config == {
                "cache-disabled": "true",
                "env": "ORACLE_ENV",
                "gelf-address": $address,
                "gelf-tcp-max-reconnect": "0",
                "gelf-tcp-reconnect-delay": "0",
                "labels": "oracle.label",
                "tag": "gelf.{{.Name}}.{{.ID}}"
            }
        ' <<<"$log_config" >/dev/null \
            || fail "GELF TCP failure inspect configuration differs from the Docker contract: $log_config"
    else
        jq -e --arg address "$address" '
            .Type == "gelf"
            and .Config == {
                "cache-disabled": "true",
                "env": "ORACLE_ENV",
                "gelf-address": $address,
                "labels": "oracle.label",
                "tag": "gelf.{{.Name}}.{{.ID}}"
            }
        ' <<<"$log_config" >/dev/null \
            || fail "GELF inspect configuration differs from the Docker contract: $log_config"
    fi
    state="$(run_docker container inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
    [[ "$state" == "exited" ]] || fail "GELF inspect state is $state, expected exited"
    log_path="$(run_docker container inspect --format '{{.LogPath}}' "$CONTAINER_NAME")"
    [[ -z "$log_path" ]] || fail "GELF public LogPath is not empty: $log_path"
}

# Decode the GELF wire records and assert Docker's common record contract.
assert_gelf_receiver_contract() {
    local container_id="$1"

    if [[ "$SCENARIO" == "tcp-reconnect" ]]; then
        assert_tcp_reconnect_receiver_contract "$container_id"
        return
    fi
    if [[ "$SCENARIO" == "tcp-retry-delay" ]]; then
        assert_tcp_delayed_retry_receiver_contract "$container_id"
        return
    fi
    if [[ "$SCENARIO" == "tcp-failure" ]]; then
        assert_tcp_failure_receiver_contract "$container_id"
        return
    fi

    python3 - "$RECEIVER_RESULT_PATH" "$container_id" "$CONTAINER_NAME" "$TRANSPORT" <<'PY'
import gzip
import json
import math
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
container_id = sys.argv[2]
container_name = sys.argv[3]
transport = sys.argv[4]
if transport == "udp":
    datagrams = result.get("datagramsHex")
    if not isinstance(datagrams, list) or len(datagrams) != 3:
        raise SystemExit(f"expected three GELF datagrams, got {result!r}")
    payloads = []
    for value in datagrams:
        payload = bytes.fromhex(value)
        if not payload.startswith(b"\x1f\x8b"):
            raise SystemExit(f"GELF UDP payload is not gzip: {payload!r}")
        payloads.append(gzip.decompress(payload))
elif transport == "tcp":
    stream_hex = result.get("streamHex")
    if result.get("accepted") is not True or result.get("peerClosed") is not True:
        raise SystemExit(f"GELF TCP receiver did not observe a clean peer close: {result!r}")
    if not isinstance(stream_hex, str):
        raise SystemExit(f"GELF TCP receiver result is malformed: {result!r}")
    stream = bytes.fromhex(stream_hex)
    if not stream.endswith(b"\0"):
        raise SystemExit(f"GELF TCP stream is not NUL terminated: {stream!r}")
    payloads = stream[:-1].split(b"\0") if stream else []
    if len(payloads) != 3 or any(not payload for payload in payloads):
        raise SystemExit(f"expected three non-empty GELF TCP frames, got {payloads!r}")
else:
    raise SystemExit(f"unsupported GELF transport: {transport!r}")
records = [json.loads(payload.decode("utf-8")) for payload in payloads]
expected_messages = [
    "stdout-ascii",
    "stderr-utf8-☃",
    "stdout-binary-�\x00-end",
]
if [record.get("short_message") for record in records] != expected_messages:
    raise SystemExit(f"unexpected GELF messages: {records!r}")
if [record.get("level") for record in records] != [6, 3, 6]:
    raise SystemExit(f"unexpected GELF levels: {records!r}")
expected_keys = {
    "version", "host", "short_message", "timestamp", "level",
    "_ORACLE_ENV", "_oracle.label", "_command", "_container_id",
    "_container_name", "_created", "_image_id", "_image_name", "_tag",
}
visible_name = container_name.lstrip("/")
expected_tag = f"gelf.{visible_name}.{container_id[:12]}"
for record in records:
    if set(record) != expected_keys:
        raise SystemExit(f"unexpected GELF metadata fields: {sorted(record)!r}")
    if record["version"] != "1.1" or not isinstance(record["host"], str) or not record["host"]:
        raise SystemExit(f"invalid GELF identity fields: {record!r}")
    if not isinstance(record["timestamp"], (int, float)) or not math.isfinite(record["timestamp"]):
        raise SystemExit(f"invalid GELF timestamp: {record!r}")
    if record["_ORACLE_ENV"] != "bravo" or record["_oracle.label"] != "alpha":
        raise SystemExit(f"missing selected GELF metadata: {record!r}")
    if record["_container_id"] != container_id or record["_container_name"] != visible_name:
        raise SystemExit(f"incorrect GELF container identity: {record!r}")
    if record["_tag"] != expected_tag or record["_image_name"] != "alpine:3.20":
        raise SystemExit(f"incorrect GELF tag or image metadata: {record!r}")
    if not record["_created"] or not record["_command"] or not record["_image_id"].startswith("sha256:"):
        raise SystemExit(f"incomplete GELF Docker metadata: {record!r}")
PY
}

# Assert reconnect framing, ordered recovery bytes, and Docker GELF metadata.
assert_tcp_reconnect_receiver_contract() {
    local container_id="$1"

    python3 - "$RECEIVER_RESULT_PATH" "$WORK_ROOT/receiver-first-stream.bin" \
        "$WORK_ROOT/receiver-reconnect-stream.bin" "$container_id" "$CONTAINER_NAME" \
        "$RECONNECT_OUTPUT_BYTES" <<'PY'
import json
import math
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
first_stream = Path(sys.argv[2]).read_bytes()
reconnect_stream = Path(sys.argv[3]).read_bytes()
container_id = sys.argv[4]
container_name = sys.argv[5]
expected_output_bytes = int(sys.argv[6])
if result.get("firstClosedByReceiver") is not True or result.get("secondPeerClosed") is not True:
    raise SystemExit(f"GELF TCP reconnect receiver did not observe both peer transitions: {result!r}")
if result.get("reconnectComplete") is not True or result.get("timedOut") is not False:
    raise SystemExit(f"GELF TCP reconnect receiver did not finish cleanly: {result!r}")
if not first_stream.endswith(b"\0") or not reconnect_stream.endswith(b"\0"):
    raise SystemExit("GELF TCP reconnect stream is not NUL terminated")
first_payloads = first_stream[:-1].split(b"\0") if first_stream else []
reconnect_payloads = reconnect_stream[:-1].split(b"\0") if reconnect_stream else []
if len(first_payloads) != 1 or not first_payloads[0]:
    raise SystemExit(f"expected exactly one first-peer GELF frame, got {len(first_payloads)}")
if not reconnect_payloads or any(not payload for payload in reconnect_payloads):
    raise SystemExit(f"expected a non-empty GELF reconnect stream, got {len(reconnect_payloads)} frames")
first_record = json.loads(first_payloads[0].decode("utf-8"))
reconnect_records = [json.loads(payload.decode("utf-8")) for payload in reconnect_payloads]
if first_record.get("short_message") != "first":
    raise SystemExit(f"unexpected first-peer GELF message: {first_record!r}")
if reconnect_records[-1].get("short_message") != "reconnect-complete":
    raise SystemExit(f"missing terminal GELF reconnect message: {reconnect_records[-1]!r}")
recovered_output = "".join(record.get("short_message", "") for record in reconnect_records[:-1])
recovered_output_bytes = len(recovered_output.encode("utf-8"))
if recovered_output_bytes > expected_output_bytes or any(character != "x" for character in recovered_output):
    raise SystemExit(
        f"GELF reconnect duplicated, reordered, or changed recovery bytes: {recovered_output_bytes}"
    )
expected_keys = {
    "version", "host", "short_message", "timestamp", "level",
    "_ORACLE_ENV", "_oracle.label", "_command", "_container_id",
    "_container_name", "_created", "_image_id", "_image_name", "_tag",
}
visible_name = container_name.lstrip("/")
expected_tag = f"gelf.{visible_name}.{container_id[:12]}"
for record in [first_record, *reconnect_records]:
    if set(record) != expected_keys:
        raise SystemExit(f"unexpected GELF reconnect metadata fields: {sorted(record)!r}")
    if record["version"] != "1.1" or not isinstance(record["host"], str) or not record["host"]:
        raise SystemExit(f"invalid GELF reconnect identity fields: {record!r}")
    if not isinstance(record["timestamp"], (int, float)) or not math.isfinite(record["timestamp"]):
        raise SystemExit(f"invalid GELF reconnect timestamp: {record!r}")
    if record["level"] != 6 or record["_ORACLE_ENV"] != "bravo" or record["_oracle.label"] != "alpha":
        raise SystemExit(f"incorrect GELF reconnect record fields: {record!r}")
    if record["_container_id"] != container_id or record["_container_name"] != visible_name:
        raise SystemExit(f"incorrect GELF reconnect container identity: {record!r}")
    if record["_tag"] != expected_tag or record["_image_name"] != "alpine:3.20":
        raise SystemExit(f"incorrect GELF reconnect tag or image metadata: {record!r}")
    if not record["_created"] or not record["_command"] or not record["_image_id"].startswith("sha256:"):
        raise SystemExit(f"incomplete GELF reconnect Docker metadata: {record!r}")
PY
}

# Assert the bounded delayed-retry budget, record disposition, and Docker GELF metadata.
assert_tcp_delayed_retry_receiver_contract() {
    local container_id="$1"

    python3 - "$RECEIVER_RESULT_PATH" "$WORK_ROOT/receiver-delay-stream-1.bin" \
        "$WORK_ROOT/receiver-delay-stream-2.bin" \
        "$WORK_ROOT/receiver-delay-recovery-stream.bin" "$container_id" \
        "$CONTAINER_NAME" "$TCP_DELAYED_RETRY_MIN_INTERVAL_SECONDS" <<'PY'
import json
import math
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
reset_streams = [Path(sys.argv[2]).read_bytes(), Path(sys.argv[3]).read_bytes()]
recovery_stream = Path(sys.argv[4]).read_bytes()
container_id = sys.argv[5]
container_name = sys.argv[6]
minimum_interval = float(sys.argv[7])
expected_messages = [
    # A reset is observed by the sender only on a later write. Docker's
    # go-gelf loop retries that triggering frame, so the source records
    # emitted while each preceding TCP close is still unobserved are absent.
    "first",
    "fourth",
    "after-retry-delay-complete",
]
if result.get("forcedClosedConnections") != 2 or result.get("resetFrameCounts") != [1, 1]:
    raise SystemExit(f"GELF TCP delayed-retry receiver did not reset one framed record per peer: {result!r}")
if result.get("acceptedConnections", 0) < 3 or result.get("recoveryConnectionIndex") != 3:
    raise SystemExit(f"GELF TCP delayed-retry receiver did not observe its retained recovery peer: {result!r}")
if result.get("recoveryTerminalSeen") is not True or result.get("recoveryPeerClosed") is not True:
    raise SystemExit(f"GELF TCP delayed-retry receiver did not observe recovery and peer close: {result!r}")
if result.get("timedOut") is not False:
    raise SystemExit(f"GELF TCP delayed-retry receiver timed out: {result!r}")
intervals = result.get("reconnectIntervalsSeconds")
if not isinstance(intervals, list) or len(intervals) != 2 or any(
    not isinstance(interval, (int, float)) or not math.isfinite(interval) or interval < minimum_interval
    for interval in intervals
):
    raise SystemExit(f"GELF TCP delayed-retry reconnect delay differs from the contract: {result!r}")
if any(not stream.endswith(b"\0") for stream in [*reset_streams, recovery_stream]):
    raise SystemExit("GELF TCP delayed-retry stream is not NUL terminated")
payload_groups = [
    stream[:-1].split(b"\0") if stream else []
    for stream in [*reset_streams, recovery_stream]
]
if any(len(group) != 1 or not group[0] for group in payload_groups[:2]):
    raise SystemExit(f"expected exactly one frame on each delayed-retry reset peer, got {payload_groups[:2]!r}")
if not payload_groups[2] or any(not payload for payload in payload_groups[2]):
    raise SystemExit(f"expected a non-empty delayed-retry recovery stream, got {payload_groups[2]!r}")
records = [
    json.loads(payload.decode("utf-8"))
    for group in payload_groups
    for payload in group
]
messages = [record.get("short_message") for record in records]
if messages != expected_messages:
    raise SystemExit(f"GELF TCP delayed-retry records differ from Docker's ordered disposition: {messages!r}")
expected_keys = {
    "version", "host", "short_message", "timestamp", "level",
    "_ORACLE_ENV", "_oracle.label", "_command", "_container_id",
    "_container_name", "_created", "_image_id", "_image_name", "_tag",
}
visible_name = container_name.lstrip("/")
expected_tag = f"gelf.{visible_name}.{container_id[:12]}"
for record in records:
    if set(record) != expected_keys:
        raise SystemExit(f"unexpected GELF delayed-retry metadata fields: {sorted(record)!r}")
    if record["version"] != "1.1" or not isinstance(record["host"], str) or not record["host"]:
        raise SystemExit(f"invalid GELF delayed-retry identity fields: {record!r}")
    if not isinstance(record["timestamp"], (int, float)) or not math.isfinite(record["timestamp"]):
        raise SystemExit(f"invalid GELF delayed-retry timestamp: {record!r}")
    if record["level"] != 6 or record["_ORACLE_ENV"] != "bravo" or record["_oracle.label"] != "alpha":
        raise SystemExit(f"incorrect GELF delayed-retry record fields: {record!r}")
    if record["_container_id"] != container_id or record["_container_name"] != visible_name:
        raise SystemExit(f"incorrect GELF delayed-retry container identity: {record!r}")
    if record["_tag"] != expected_tag or record["_image_name"] != "alpine:3.20":
        raise SystemExit(f"incorrect GELF delayed-retry tag or image metadata: {record!r}")
    if not record["_created"] or not record["_command"] or not record["_image_id"].startswith("sha256:"):
        raise SystemExit(f"incomplete GELF delayed-retry Docker metadata: {record!r}")
PY
}

# Assert Docker's zero-budget behavior: every reset drops the current record,
# but the final replacement connection remains available to later records.
assert_tcp_failure_receiver_contract() {
    local container_id="$1"

    python3 - "$RECEIVER_RESULT_PATH" "$WORK_ROOT/receiver-failure-stream-1.bin" \
        "$WORK_ROOT/receiver-failure-stream-2.bin" \
        "$WORK_ROOT/receiver-failure-recovery-stream.bin" "$container_id" \
        "$CONTAINER_NAME" <<'PY'
import json
import math
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
reset_streams = [Path(sys.argv[2]).read_bytes(), Path(sys.argv[3]).read_bytes()]
recovery_stream = Path(sys.argv[4]).read_bytes()
container_id = sys.argv[5]
container_name = sys.argv[6]
expected_messages = [
    "first",
    "second",
    "third",
    "fourth",
    "fifth",
    "sixth",
    "seventh",
    "eighth",
    "ninth",
    "tenth",
    "complete",
    "after-complete",
]
if result.get("forcedClosedConnections") != 2 or result.get("resetFrameCounts") != [1, 1]:
    raise SystemExit(f"GELF TCP failure receiver did not reset one framed record per peer: {result!r}")
if result.get("acceptedConnections", 0) < 3 or result.get("recoveryConnectionIndex") != 3:
    raise SystemExit(f"GELF TCP failure receiver did not observe the retained replacement peer: {result!r}")
if result.get("recoveryTerminalSeen") is not True or result.get("recoveryPeerClosed") is not True:
    raise SystemExit(f"GELF TCP failure receiver did not observe terminal recovery and peer close: {result!r}")
if result.get("timedOut") is not False:
    raise SystemExit(f"GELF TCP failure receiver timed out: {result!r}")
if any(not stream.endswith(b"\0") for stream in [*reset_streams, recovery_stream]):
    raise SystemExit("GELF TCP failure stream is not NUL terminated")
payload_groups = [
    stream[:-1].split(b"\0") if stream else []
    for stream in [*reset_streams, recovery_stream]
]
if any(len(group) != 1 or not group[0] for group in payload_groups[:2]):
    raise SystemExit(f"expected exactly one frame on each reset peer, got {payload_groups[:2]!r}")
if not payload_groups[2] or any(not payload for payload in payload_groups[2]):
    raise SystemExit(f"expected non-empty retained-replacement stream, got {payload_groups[2]!r}")
records = [
    json.loads(payload.decode("utf-8"))
    for group in payload_groups
    for payload in group
]
messages = [record.get("short_message") for record in records]
if messages[0] != "first" or messages[-1] != "after-complete":
    raise SystemExit(f"unexpected GELF TCP failure endpoints: {messages!r}")
if "complete" not in messages:
    raise SystemExit(f"missing terminal GELF recovery marker: {messages!r}")
if any(message not in expected_messages for message in messages):
    raise SystemExit(f"unexpected GELF TCP failure message: {messages!r}")
indices = [expected_messages.index(message) for message in messages]
if indices != sorted(indices) or len(indices) != len(set(indices)):
    raise SystemExit(f"GELF TCP failure duplicated, reordered, or changed recovery bytes: {messages!r}")
expected_keys = {
    "version", "host", "short_message", "timestamp", "level",
    "_ORACLE_ENV", "_oracle.label", "_command", "_container_id",
    "_container_name", "_created", "_image_id", "_image_name", "_tag",
}
visible_name = container_name.lstrip("/")
expected_tag = f"gelf.{visible_name}.{container_id[:12]}"
for record in records:
    if set(record) != expected_keys:
        raise SystemExit(f"unexpected GELF TCP failure metadata fields: {sorted(record)!r}")
    if record["version"] != "1.1" or not isinstance(record["host"], str) or not record["host"]:
        raise SystemExit(f"invalid GELF TCP failure identity fields: {record!r}")
    if not isinstance(record["timestamp"], (int, float)) or not math.isfinite(record["timestamp"]):
        raise SystemExit(f"invalid GELF TCP failure timestamp: {record!r}")
    if record["level"] != 6 or record["_ORACLE_ENV"] != "bravo" or record["_oracle.label"] != "alpha":
        raise SystemExit(f"incorrect GELF TCP failure record fields: {record!r}")
    if record["_container_id"] != container_id or record["_container_name"] != visible_name:
        raise SystemExit(f"incorrect GELF TCP failure container identity: {record!r}")
    if record["_tag"] != expected_tag or record["_image_name"] != "alpine:3.20":
        raise SystemExit(f"incorrect GELF TCP failure tag or image metadata: {record!r}")
    if not record["_created"] or not record["_command"] or not record["_image_id"].startswith("sha256:"):
        raise SystemExit(f"incomplete GELF TCP failure Docker metadata: {record!r}")
PY
}

# Assert Docker's create-success/start-failure lifecycle for a TCP GELF sink
# that refuses the initial eager connection. The concrete peer IP is platform
# dependent, so the stable Docker path and configured endpoint are asserted.
assert_tcp_unavailable_start_failure() {
    local start_status="$1"
    local start_output="$2"
    local address="$TRANSPORT://$GELF_ADDRESS_HOST:$RECEIVER_PORT"
    local log_config
    local state

    ((start_status != 0)) || fail "GELF TCP unavailable endpoint unexpectedly started $CONTAINER_NAME"
    [[ "$start_output" == *"failed to initialize logging driver: gelf: cannot connect to GELF endpoint:"* ]] \
        || fail "GELF TCP unavailable start error differs from Docker: $start_output"
    [[ "$start_output" == *"$GELF_ADDRESS_HOST:$RECEIVER_PORT"* ]] \
        || fail "GELF TCP unavailable start error omits its configured endpoint: $start_output"
    [[ "$start_output" == *"failed to start containers: $CONTAINER_NAME"* ]] \
        || fail "GELF TCP unavailable start error omits Docker's container failure: $start_output"

    log_config="$(run_docker container inspect --format '{{json .HostConfig.LogConfig}}' "$CONTAINER_NAME")"
    jq -e --arg address "$address" '
        .Type == "gelf"
        and .Config == {
            "cache-disabled": "true",
            "env": "ORACLE_ENV",
            "gelf-address": $address,
            "gelf-tcp-max-reconnect": "0",
            "gelf-tcp-reconnect-delay": "0",
            "labels": "oracle.label",
            "tag": "gelf.{{.Name}}.{{.ID}}"
        }
    ' <<<"$log_config" >/dev/null \
        || fail "GELF TCP unavailable inspect configuration differs from the Docker contract: $log_config"
    state="$(run_docker container inspect --format '{{json .State}}' "$CONTAINER_NAME")"
    jq -e --arg endpoint "$GELF_ADDRESS_HOST:$RECEIVER_PORT" '
        .Status == "created"
        and .Running == false
        and .ExitCode == 128
        and .StartedAt == "0001-01-01T00:00:00Z"
        and .FinishedAt == "0001-01-01T00:00:00Z"
        and (.Error | contains("failed to create task for container: failed to initialize logging driver: gelf: cannot connect to GELF endpoint:"))
        and (.Error | contains($endpoint))
    ' <<<"$state" >/dev/null \
        || fail "GELF TCP unavailable inspect state differs from the Docker contract: $state"
}

# Verify Docker preserves its unreadable remote-driver error for GELF.
assert_unreadable_logs() {
    local output
    local status

    set +e
    output="$(run_docker logs "$CONTAINER_NAME" 2>&1)"
    status=$?
    set -e
    ((status != 0)) || fail "GELF logging unexpectedly returned readable history"
    [[ "$output" == "Error response from daemon: configured logging driver does not support reading" ]] \
        || fail "GELF read error differs from Docker: $output"
}

# Return a monotonic timestamp in seconds for evidence-backed timing.
monotonic_seconds() {
    python3 - <<'PY'
import time
print(f"{time.monotonic():.9f}")
PY
}

# Write optional machine-readable completion evidence outside the fixture root.
write_result() {
    local duration_seconds="$1"
    local container_id="$2"
    local contract
    local contract_transport

    [[ -n "$RESULT_PATH" ]] || return 0
    [[ -d "$(dirname "$RESULT_PATH")" ]] \
        || fail "result parent directory does not exist: $(dirname "$RESULT_PATH")"
    contract_transport="$(printf '%s' "$TRANSPORT" | tr '[:lower:]' '[:upper:]')"
    contract="Docker REST GELF $contract_transport"
    if [[ "$SCENARIO" == "tcp-reconnect" ]]; then
        contract="$contract reconnect"
    elif [[ "$SCENARIO" == "tcp-retry-delay" ]]; then
        contract="$contract delayed retry"
    elif [[ "$SCENARIO" == "tcp-failure" ]]; then
        contract="$contract retry exhaustion"
    elif [[ "$SCENARIO" == "tcp-unavailable" ]]; then
        contract="$contract unavailable endpoint"
    fi
    jq -n \
        --arg contract "$contract" \
        --arg endpoint "${DOCKER_HOST_OVERRIDE:-default-context}" \
        --arg containerID "$container_id" \
        --arg workRoot "$WORK_ROOT" \
        --argjson durationSeconds "$duration_seconds" \
        --arg scenario "$SCENARIO" \
        '{contract: $contract, endpoint: $endpoint, durationSeconds: $durationSeconds, result: "passed", containerID: $containerID, scenario: $scenario, workRoot: $workRoot}' \
        >"$RESULT_PATH"
}

# Remove only this fixture's receiver and uniquely named Docker container.
cleanup() {
    local temporary_parent="${TMPDIR:-/tmp}"

    if [[ -n "$RECEIVER_PID" ]] && kill -0 "$RECEIVER_PID" 2>/dev/null; then
        kill "$RECEIVER_PID" 2>/dev/null || true
        wait "$RECEIVER_PID" 2>/dev/null || true
    fi
    if [[ -n "$CONTAINER_ID" ]]; then
        run_docker rm --force "$CONTAINER_ID" >/dev/null 2>&1 || true
    elif [[ -n "$CONTAINER_NAME" ]]; then
        run_docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if ((RETAIN_WORK_ROOT == 0)) \
        && [[ -n "$WORK_ROOT" && "$WORK_ROOT" == "$temporary_parent"/container-rest-gelf.* \
        && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
}

# Exercise the complete public GELF lifecycle through an unmodified Docker CLI.
main() {
    local suffix
    local container_id
    local started_at
    local finished_at
    local duration_seconds
    local workload
    local start_status
    local start_output
    local -a log_options

    parse_args "$@"
    verify_prerequisites
    create_work_root
    suffix="$(basename "$WORK_ROOT" | tr '.[:upper:]' '-[:lower:]')"
    CONTAINER_NAME="cc-rest-gelf-$suffix"
    start_receiver
    workload='printf '\''stdout-ascii\n'\''; sleep 0.2; printf '\''stderr-utf8-\342\230\203\n'\'' >&2; sleep 0.2; printf '\''stdout-binary-\377\000-end\n'\'''
    if [[ "$SCENARIO" == "tcp-reconnect" ]]; then
        workload='sleep 1; printf '\''first\n'\''; sleep 2; dd if=/dev/zero bs=65536 count=16 2>/dev/null | tr '\''\000'\'' x; sleep 2; printf '\''reconnect-complete\n'\'''
    elif [[ "$SCENARIO" == "tcp-retry-delay" ]]; then
        # Each source record is separated long enough for Docker to observe the
        # receiver's preceding reset before it drives the next retry attempt.
        # shellcheck disable=SC2016 # $message expands inside the test container.
        workload='for message in first second third fourth fifth sixth after-retry-delay-complete; do sleep 3; printf '\''%s\n'\'' "$message"; done'
    elif [[ "$SCENARIO" == "tcp-failure" ]]; then
        # shellcheck disable=SC2016 # $message expands inside the test container.
        workload='for message in first second third fourth fifth sixth seventh eighth ninth tenth complete after-complete; do sleep 1; printf '\''%s\n'\'' "$message"; done'
    elif [[ "$SCENARIO" == "tcp-unavailable" ]]; then
        workload='printf '\''should-not-run\n'\'''
    fi
    log_options=(
        --log-driver gelf --log-opt cache-disabled=true
        --log-opt "gelf-address=$TRANSPORT://$GELF_ADDRESS_HOST:$RECEIVER_PORT"
        --log-opt env=ORACLE_ENV --log-opt labels=oracle.label
        --log-opt 'tag=gelf.{{.Name}}.{{.ID}}'
    )
    if [[ "$SCENARIO" == "tcp-reconnect" ]]; then
        log_options+=(
            --log-opt gelf-tcp-max-reconnect=1
            --log-opt gelf-tcp-reconnect-delay=0
        )
    elif [[ "$SCENARIO" == "tcp-retry-delay" ]]; then
        log_options+=(
            --log-opt "gelf-tcp-max-reconnect=$TCP_DELAYED_RETRY_MAX_RECONNECTS"
            --log-opt "gelf-tcp-reconnect-delay=$TCP_DELAYED_RETRY_DELAY_SECONDS"
        )
    elif [[ "$SCENARIO" == "tcp-failure" || "$SCENARIO" == "tcp-unavailable" ]]; then
        log_options+=(
            --log-opt gelf-tcp-max-reconnect=0
            --log-opt gelf-tcp-reconnect-delay=0
        )
    fi
    container_id="$(run_docker create --name "$CONTAINER_NAME" \
        --env ORACLE_ENV=bravo --label oracle.label=alpha \
        "${log_options[@]}" \
        "$REQUIRED_DISPLAY_IMAGE" /bin/sh -c "$workload")"
    [[ -n "$container_id" ]] || fail "docker create returned an empty GELF identifier"
    CONTAINER_ID="$container_id"
    assert_public_create_identity "$container_id"
    assert_native_driver
    started_at="$(monotonic_seconds)"
    if [[ "$SCENARIO" == "tcp-unavailable" ]]; then
        set +e
        start_output="$(run_docker start "$CONTAINER_NAME" 2>&1)"
        start_status=$?
        set -e
        assert_tcp_unavailable_start_failure "$start_status" "$start_output"
        finished_at="$(monotonic_seconds)"
        duration_seconds="$(python3 - "$started_at" "$finished_at" <<'PY'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.9f}")
PY
        )"
        write_result "$duration_seconds" "$container_id"
        info "Docker REST GELF TCP unavailable endpoint contract passed in ${duration_seconds}s"
        return
    fi
    run_docker start "$container_id" >/dev/null
    wait_for_state exited
    if [[ "$TRANSPORT" == "tcp" ]]; then
        if [[ "$SCENARIO" == "tcp-reconnect" ]]; then
            wait_for_tcp_reconnect_complete
        elif [[ "$SCENARIO" == "tcp-retry-delay" ]]; then
            wait_for_tcp_delayed_retry_complete
        elif [[ "$SCENARIO" == "tcp-failure" ]]; then
            wait_for_tcp_failure_complete
        else
            wait_for_tcp_primary_close
        fi
        assert_unreadable_logs
        finish_tcp_receiver
    fi
    wait_for_receiver
    finished_at="$(monotonic_seconds)"
    duration_seconds="$(python3 - "$started_at" "$finished_at" <<'PY'
import sys
print(f"{float(sys.argv[2]) - float(sys.argv[1]):.9f}")
PY
    )"
    assert_public_inspection
    assert_gelf_receiver_contract "$container_id"
    if [[ "$TRANSPORT" == "udp" ]]; then
        assert_unreadable_logs
    fi
    write_result "$duration_seconds" "$container_id"
    info "Docker REST GELF $TRANSPORT contract passed in ${duration_seconds}s"
}

trap cleanup EXIT
main "$@"
