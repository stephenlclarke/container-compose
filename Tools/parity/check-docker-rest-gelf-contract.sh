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
#   --scenario MODE    Fixture to prove: standard (default) or tcp-reconnect.
#   --native-cli PATH  Optional Container CLI used to prove one shared authority.
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
# a terminal record without duplicating or corrupting output.

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

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
GELF_ADDRESS_HOST="127.0.0.1"
TRANSPORT="udp"
SCENARIO="standard"
NATIVE_CLI=""
RESULT_PATH=""
WORK_ROOT=""
CONTAINER_NAME=""
RECEIVER_PID=""
RECEIVER_PORT_PATH=""
RECEIVER_RESULT_PATH=""
RECEIVER_FINISH_PATH=""
RECEIVER_PRIMARY_COMPLETE_PATH=""
RECEIVER_RECONNECT_COMPLETE_PATH=""
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
                    standard | tcp-reconnect)
                        SCENARIO="$2"
                        ;;
                    *)
                        error "--scenario must be standard or tcp-reconnect, got: $2"
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

    if [[ "$SCENARIO" == "tcp-reconnect" && "$TRANSPORT" != "tcp" ]]; then
        error "--scenario tcp-reconnect requires --transport tcp"
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
    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-gelf.XXXXXX")"
    printf '%s\n' 'Docker REST GELF contract fixture root v1' \
        >"$WORK_ROOT/$ROOT_MARKER_NAME"
    RECEIVER_PORT_PATH="$WORK_ROOT/receiver.port"
    RECEIVER_RESULT_PATH="$WORK_ROOT/receiver-result.json"
    RECEIVER_FINISH_PATH="$WORK_ROOT/receiver.finish"
    RECEIVER_PRIMARY_COMPLETE_PATH="$WORK_ROOT/receiver.primary-complete"
    RECEIVER_RECONNECT_COMPLETE_PATH="$WORK_ROOT/receiver.reconnect-complete"
}

# Start the selected bounded host-side receiver used by both Docker and Container.
start_receiver() {
    if [[ "$SCENARIO" == "tcp-reconnect" ]]; then
        start_tcp_reconnect_receiver
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
    fi
    jq -n \
        --arg contract "$contract" \
        --arg endpoint "${DOCKER_HOST_OVERRIDE:-default-context}" \
        --arg containerID "$container_id" \
        --argjson durationSeconds "$duration_seconds" \
        --arg scenario "$SCENARIO" \
        '{contract: $contract, endpoint: $endpoint, durationSeconds: $durationSeconds, result: "passed", containerID: $containerID, scenario: $scenario}' \
        >"$RESULT_PATH"
}

# Remove only this fixture's receiver and uniquely named Docker container.
cleanup() {
    local temporary_parent="${TMPDIR:-/tmp}"

    if [[ -n "$RECEIVER_PID" ]] && kill -0 "$RECEIVER_PID" 2>/dev/null; then
        kill "$RECEIVER_PID" 2>/dev/null || true
        wait "$RECEIVER_PID" 2>/dev/null || true
    fi
    if [[ -n "$CONTAINER_NAME" ]]; then
        run_docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_ROOT" && "$WORK_ROOT" == "$temporary_parent"/container-rest-gelf.* \
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
    fi
    container_id="$(run_docker create --name "$CONTAINER_NAME" \
        --env ORACLE_ENV=bravo --label oracle.label=alpha \
        "${log_options[@]}" \
        "$REQUIRED_DISPLAY_IMAGE" /bin/sh -c "$workload")"
    [[ -n "$container_id" ]] || fail "docker create returned an empty GELF identifier"
    assert_native_driver
    started_at="$(monotonic_seconds)"
    run_docker start "$CONTAINER_NAME" >/dev/null
    wait_for_state exited
    if [[ "$TRANSPORT" == "tcp" ]]; then
        if [[ "$SCENARIO" == "tcp-reconnect" ]]; then
            wait_for_tcp_reconnect_complete
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
