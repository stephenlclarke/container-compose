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
#   check-docker-rest-fluentd-contract.sh [options]
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
# Container's public socket. It proves that a host-side Fluent Forward receiver
# is reachable through host.docker.internal, observes three MessagePack
# EventTime records with selected metadata and tag expansion, acknowledges each
# per-event chunk, observes the Docker unreadable-history error, and verifies
# marker-protected cleanup.

set -euo pipefail

readonly SELF_PATH="$0"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly REQUIRED_CLI_VERSION="29.7.1"
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly REQUIRED_DISPLAY_IMAGE="alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-fluentd-root"
readonly RECEIVER_MESSAGE_COUNT=3
readonly RECEIVER_TIMEOUT_SECONDS=20

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
RECEIVER_FINISH_PATH=""
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
        | sed "s/check-docker-rest-fluentd-contract.sh/$SCRIPT_NAME/"
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
    warning "$message; skipping Docker REST Fluentd contract"
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
}

# Create the marker-protected root for receiver state and fixture output.
create_work_root() {
    if [[ -n "$EXPLICIT_WORK_ROOT" ]]; then
        WORK_ROOT="$EXPLICIT_WORK_ROOT"
        [[ "$WORK_ROOT" == /private/tmp/container-rest-fluentd.* ]] \
            || fail "--work-root must be an isolated /private/tmp/container-rest-fluentd.* directory: $WORK_ROOT"
        [[ -d "$WORK_ROOT" ]] \
            || fail "--work-root must already exist: $WORK_ROOT"
        [[ ! -L "$WORK_ROOT" ]] \
            || fail "--work-root must not be a symlink: $WORK_ROOT"
        local canonical_work_root
        canonical_work_root="$(cd -P -- "$WORK_ROOT" && pwd -P)" \
            || fail "--work-root cannot be resolved safely: $WORK_ROOT"
        [[ "$canonical_work_root" == /private/tmp/container-rest-fluentd.* ]] \
            || fail "--work-root resolved outside its isolated namespace: $WORK_ROOT"
        WORK_ROOT="$canonical_work_root"
        [[ ! -e "$WORK_ROOT/$ROOT_MARKER_NAME" ]] \
            || fail "--work-root already has the fixture marker: $WORK_ROOT"
        [[ -z "$(find "$WORK_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
            || fail "--work-root must be empty before the fixture starts: $WORK_ROOT"
    else
        WORK_ROOT="$(mktemp -d /private/tmp/container-rest-fluentd.XXXXXX)"
    fi
    printf '%s\n' 'Docker REST Fluentd contract fixture root v1' \
        >"$WORK_ROOT/$ROOT_MARKER_NAME"
    RECEIVER_PORT_PATH="$WORK_ROOT/receiver.port"
    RECEIVER_RESULT_PATH="$WORK_ROOT/receiver-result.json"
    RECEIVER_FINISH_PATH="$WORK_ROOT/receiver.finish"
    if [[ -z "$RESULT_PATH" ]]; then
        RESULT_PATH="$WORK_ROOT/result.json"
    fi
}

# Remove only a fixture root that this script created and marked.
remove_work_root() {
    [[ -n "$WORK_ROOT" && -d "$WORK_ROOT" ]] || return 0
    [[ -e "$WORK_ROOT/$ROOT_MARKER_NAME" ]] || return 0
    case "$WORK_ROOT" in
        /private/tmp/container-rest-fluentd.*)
            rm -rf -- "$WORK_ROOT"
            ;;
        *)
            warning "refusing to remove unexpected fixture root: $WORK_ROOT"
            ;;
    esac
}

# Stop the receiver and remove the Docker object without touching shared runtime state.
cleanup() {
    local exit_status=$?

    trap - EXIT
    set +e
    if [[ -n "$CONTAINER_ID" ]]; then
        run_docker container rm --force "$CONTAINER_ID" >/dev/null 2>&1
    fi
    if [[ -n "$RECEIVER_PID" ]]; then
        touch "$RECEIVER_FINISH_PATH"
        wait "$RECEIVER_PID" 2>/dev/null
        if kill -0 "$RECEIVER_PID" 2>/dev/null; then
            kill "$RECEIVER_PID" 2>/dev/null
            wait "$RECEIVER_PID" 2>/dev/null
        fi
    fi
    if ((RETAIN_WORK_ROOT == 0)); then
        remove_work_root
    fi
    exit "$exit_status"
}

# Start a bounded host-side Fluent Forward receiver and publish its port.
start_receiver() {
    python3 - "$RECEIVER_PORT_PATH" "$RECEIVER_RESULT_PATH" \
        "$RECEIVER_FINISH_PATH" "$RECEIVER_MESSAGE_COUNT" \
        "$RECEIVER_TIMEOUT_SECONDS" \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" <<'PY' &
import json
import select
import socket
import struct
import sys
import time
from pathlib import Path

port_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
finish_path = Path(sys.argv[3])
expected_records = int(sys.argv[4])
timeout_seconds = float(sys.argv[5])


class IncompleteMessagePack(Exception):
    pass


class UnsupportedMessagePack(Exception):
    pass


class Node:
    def __init__(self, kind, value, raw, extension_type=None):
        self.kind = kind
        self.value = value
        self.raw = raw
        self.extension_type = extension_type


def take(data, offset, length):
    end = offset + length
    if end > len(data):
        raise IncompleteMessagePack()
    return data[offset:end], end


def parse_string(data, start, offset, length):
    value, end = take(data, offset, length)
    return Node("string", value, data[start:end]), end


def parse_binary(data, start, offset, length):
    value, end = take(data, offset, length)
    return Node("binary", value, data[start:end]), end


def parse_extension(data, start, offset, length):
    extension_type_raw, payload_offset = take(data, offset, 1)
    payload, end = take(data, payload_offset, length)
    extension_type = struct.unpack("b", extension_type_raw)[0]
    return Node("extension", payload, data[start:end], extension_type), end


def parse_array(data, start, offset, count):
    values = []
    for _ in range(count):
        value, offset = parse(data, offset)
        values.append(value)
    return Node("array", values, data[start:offset]), offset


def parse_map(data, start, offset, count):
    entries = []
    for _ in range(count):
        key, offset = parse(data, offset)
        value, offset = parse(data, offset)
        entries.append((key, value))
    return Node("map", entries, data[start:offset]), offset


def parse(data, offset):
    if offset >= len(data):
        raise IncompleteMessagePack()
    start = offset
    code = data[offset]
    offset += 1
    if code <= 0x7f or code >= 0xe0:
        return Node("integer", code, data[start:offset]), offset
    if 0x80 <= code <= 0x8f:
        return parse_map(data, start, offset, code & 0x0f)
    if 0x90 <= code <= 0x9f:
        return parse_array(data, start, offset, code & 0x0f)
    if 0xa0 <= code <= 0xbf:
        return parse_string(data, start, offset, code & 0x1f)
    if code == 0xc0:
        return Node("nil", None, data[start:offset]), offset
    if code in (0xc2, 0xc3):
        return Node("boolean", code == 0xc3, data[start:offset]), offset
    if code == 0xc4:
        length_raw, offset = take(data, offset, 1)
        return parse_binary(data, start, offset, length_raw[0])
    if code == 0xc5:
        length_raw, offset = take(data, offset, 2)
        return parse_binary(data, start, offset, struct.unpack(">H", length_raw)[0])
    if code == 0xc6:
        length_raw, offset = take(data, offset, 4)
        return parse_binary(data, start, offset, struct.unpack(">I", length_raw)[0])
    if code == 0xc7:
        length_raw, offset = take(data, offset, 1)
        return parse_extension(data, start, offset, length_raw[0])
    if code == 0xc8:
        length_raw, offset = take(data, offset, 2)
        return parse_extension(data, start, offset, struct.unpack(">H", length_raw)[0])
    if code == 0xc9:
        length_raw, offset = take(data, offset, 4)
        return parse_extension(data, start, offset, struct.unpack(">I", length_raw)[0])
    if code == 0xca:
        _, end = take(data, offset, 4)
        return Node("float", None, data[start:end]), end
    if code == 0xcb:
        _, end = take(data, offset, 8)
        return Node("float", None, data[start:end]), end
    if 0xcc <= code <= 0xcf:
        widths = {0xcc: 1, 0xcd: 2, 0xce: 4, 0xcf: 8}
        _, end = take(data, offset, widths[code])
        return Node("integer", None, data[start:end]), end
    if 0xd0 <= code <= 0xd3:
        widths = {0xd0: 1, 0xd1: 2, 0xd2: 4, 0xd3: 8}
        _, end = take(data, offset, widths[code])
        return Node("integer", None, data[start:end]), end
    if code == 0xd4:
        return parse_extension(data, start, offset, 1)
    if code == 0xd5:
        return parse_extension(data, start, offset, 2)
    if code == 0xd6:
        return parse_extension(data, start, offset, 4)
    if code == 0xd7:
        return parse_extension(data, start, offset, 8)
    if code == 0xd8:
        return parse_extension(data, start, offset, 16)
    if code == 0xd9:
        length_raw, offset = take(data, offset, 1)
        return parse_string(data, start, offset, length_raw[0])
    if code == 0xda:
        length_raw, offset = take(data, offset, 2)
        return parse_string(data, start, offset, struct.unpack(">H", length_raw)[0])
    if code == 0xdb:
        length_raw, offset = take(data, offset, 4)
        return parse_string(data, start, offset, struct.unpack(">I", length_raw)[0])
    if code == 0xdc:
        length_raw, offset = take(data, offset, 2)
        return parse_array(data, start, offset, struct.unpack(">H", length_raw)[0])
    if code == 0xdd:
        length_raw, offset = take(data, offset, 4)
        return parse_array(data, start, offset, struct.unpack(">I", length_raw)[0])
    if code == 0xde:
        length_raw, offset = take(data, offset, 2)
        return parse_map(data, start, offset, struct.unpack(">H", length_raw)[0])
    if code == 0xdf:
        length_raw, offset = take(data, offset, 4)
        return parse_map(data, start, offset, struct.unpack(">I", length_raw)[0])
    raise UnsupportedMessagePack(f"unsupported MessagePack lead byte 0x{code:02x}")


def map_value(node, name):
    if node.kind != "map":
        raise UnsupportedMessagePack("expected MessagePack map")
    requested = name.encode("ascii")
    for key, value in node.value:
        if key.kind == "string" and key.value == requested:
            return value
    return None


def text_value(node):
    if node is None or node.kind != "string":
        return None
    return node.value.decode("utf-8", errors="surrogateescape")


def record_summary(node):
    if node.kind != "array" or len(node.value) != 4:
        raise UnsupportedMessagePack("Forward event must be a four-element array")
    tag, timestamp, payload, options = node.value
    chunk = map_value(options, "chunk")
    if chunk is None or chunk.kind not in ("string", "binary"):
        raise UnsupportedMessagePack("Forward acknowledgement event has no chunk")
    if timestamp.kind != "extension":
        raise UnsupportedMessagePack("Forward timestamp is not an extension")
    log = map_value(payload, "log")
    source = map_value(payload, "source")
    environment = map_value(payload, "FLUENTD_ENV")
    label = map_value(payload, "fluentd.label")
    container_id = map_value(payload, "container_id")
    container_name = map_value(payload, "container_name")
    if log is None or log.kind not in ("string", "binary"):
        raise UnsupportedMessagePack("Forward payload has no byte log value")
    return {
        "chunkKind": chunk.kind,
        "containerID": text_value(container_id),
        "containerName": text_value(container_name),
        "environment": text_value(environment),
        "label": text_value(label),
        "logHex": log.value.hex(),
        "source": text_value(source),
        "tag": text_value(tag),
        "timestamp": {
            "extensionType": timestamp.extension_type,
            "kind": timestamp.kind,
            "payloadBytes": len(timestamp.value),
        },
    }, bytes((0x81, 0xa3)) + b"ack" + chunk.raw


server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", 0))
server.listen(8)
server.setblocking(False)
port_path.write_text(str(server.getsockname()[1]), encoding="ascii")

connections = {}
records = []
errors = []
acknowledgements = 0
accepted_connections = 0
peer_closed = False
timed_out = True
deadline = time.monotonic() + timeout_seconds
try:
    while time.monotonic() < deadline:
        if finish_path.exists() and len(records) >= expected_records:
            timed_out = False
            break
        readers = [server, *connections]
        readable, _, _ = select.select(readers, [], [], 0.1)
        for ready in readable:
            if ready is server:
                connection, _ = server.accept()
                connection.setblocking(False)
                connections[connection] = bytearray()
                accepted_connections += 1
                continue
            try:
                fragment = ready.recv(1024 * 1024)
            except BlockingIOError:
                continue
            if not fragment:
                peer_closed = True
                ready.close()
                connections.pop(ready, None)
                continue
            buffer = connections[ready]
            buffer.extend(fragment)
            while buffer:
                try:
                    event, consumed = parse(bytes(buffer), 0)
                except IncompleteMessagePack:
                    break
                except Exception as exc:
                    errors.append(str(exc))
                    buffer.clear()
                    break
                del buffer[:consumed]
                try:
                    summary, acknowledgement = record_summary(event)
                    ready.sendall(acknowledgement)
                    records.append(summary)
                    acknowledgements += 1
                except Exception as exc:
                    errors.append(str(exc))
finally:
    for connection in connections:
        connection.close()
    server.close()
    result_path.write_text(
        json.dumps(
            {
                "acceptedConnections": accepted_connections,
                "acksSent": acknowledgements,
                "errors": errors,
                "peerClosed": peer_closed,
                "recordCount": len(records),
                "records": records,
                "timedOut": timed_out,
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
                || fail "Fluentd receiver wrote an invalid port: $RECEIVER_PORT"
            return
        fi
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            wait "$RECEIVER_PID" || true
            RECEIVER_PID=""
            fail "Fluentd receiver exited before publishing its port"
            return
        fi
        sleep 0.05
    done
    fail "timed out waiting for Fluentd receiver port"
}

# Wait for the receiver's marker-protected result after the Docker lifecycle.
finish_receiver() {
    touch "$RECEIVER_FINISH_PATH"
    wait "$RECEIVER_PID"
    RECEIVER_PID=""
    [[ -s "$RECEIVER_RESULT_PATH" ]] \
        || fail "Fluentd receiver did not write result evidence"
}

# Create, start, inspect, wait, and query logs with unmodified Docker CLI calls.
run_contract() {
    local inspect_path="$WORK_ROOT/inspect.json"
    local logs_path="$WORK_ROOT/logs.stdout"
    local logs_error_path="$WORK_ROOT/logs.stderr"
    local logs_status

    CONTAINER_NAME="fluentd-rest-$RANDOM-$RANDOM"
    CONTAINER_ID="$(run_docker container create \
        --name "$CONTAINER_NAME" \
        --env FLUENTD_ENV=bravo \
        --label fluentd.label=alpha \
        --log-driver fluentd \
        --log-opt cache-disabled=true \
        --log-opt fluentd-address="tcp://host.docker.internal:$RECEIVER_PORT" \
        --log-opt fluentd-request-ack=true \
        --log-opt fluentd-sub-second-precision=true \
        --log-opt env=FLUENTD_ENV \
        --log-opt labels=fluentd.label \
        --log-opt tag='fluentd-rest.{{.Name}}' \
        "$REQUIRED_DISPLAY_IMAGE" \
        sh -c "printf 'fluentd-stdout\\n'; printf 'fluentd-stderr\\n' >&2; printf 'fluentd-binary-\\377\\000-end\\n'")"
    [[ "$CONTAINER_ID" =~ ^[0-9a-f]{64}$ ]] \
        || fail "Docker create returned an invalid container ID: $CONTAINER_ID"
    run_docker container inspect "$CONTAINER_ID" >"$WORK_ROOT/inspect-before-start.json"
    run_docker container start "$CONTAINER_ID" >/dev/null
    [[ "$(run_docker container wait "$CONTAINER_ID")" == "0" ]] \
        || fail "Fluentd Docker container did not exit successfully"
    run_docker container inspect "$CONTAINER_ID" >"$inspect_path"
    if run_docker container logs "$CONTAINER_ID" >"$logs_path" 2>"$logs_error_path"; then
        logs_status=0
    else
        logs_status=$?
    fi
    printf '%s\n' "$logs_status" >"$WORK_ROOT/logs.status"
    ((logs_status != 0)) \
        || fail "Docker Fluentd history unexpectedly succeeded"
    grep -Fq "configured logging driver does not support reading" "$logs_error_path" \
        || fail "Docker Fluentd history did not return its unreadable-driver error"
}

# Check Docker inspect state and the receiver's exact observable semantics.
assert_contract() {
    local expected_tag
    local expected_name

    expected_name="$(jq -r '.[0].Name' "$WORK_ROOT/inspect.json")"
    expected_tag="fluentd-rest.$CONTAINER_NAME"
    jq -e \
        --arg expected_name "$expected_name" \
        --arg expected_tag "$expected_tag" \
        --arg expected_id "$CONTAINER_ID" \
        '
            .[0].HostConfig.LogConfig.Type == "fluentd"
            and .[0].HostConfig.LogConfig.Config["cache-disabled"] == "true"
            and .[0].HostConfig.LogConfig.Config["fluentd-request-ack"] == "true"
            and .[0].HostConfig.LogConfig.Config["fluentd-sub-second-precision"] == "true"
            and (.[0].HostConfig.LogConfig.Config["fluentd-address"] | startswith("tcp://host.docker.internal:"))
            and .[0].State.Status == "exited"
        ' "$WORK_ROOT/inspect.json" >/dev/null \
        || fail "Docker inspect did not preserve Fluentd configuration"
    jq -e \
        --arg expected_name "$expected_name" \
        --arg expected_tag "$expected_tag" \
        --arg expected_id "$CONTAINER_ID" \
        '
            .recordCount == 3
            and .acksSent == 3
            and .timedOut == false
            and (.errors | length == 0)
            and ([.records[].tag] | unique == [$expected_tag])
            and ([.records[].containerID] | unique == [$expected_id])
            and ([.records[].containerName] | unique == [$expected_name])
            and ([.records[].environment] | unique == ["bravo"])
            and ([.records[].label] | unique == ["alpha"])
            and ([.records[].chunkKind] | unique == ["string"])
            and (all(.records[]; .timestamp.kind == "extension" and .timestamp.extensionType == 0 and .timestamp.payloadBytes == 8))
            and ([.records[].logHex] | sort == ["666c75656e74642d62696e6172792dff002d656e64", "666c75656e74642d737464657272", "666c75656e74642d7374646f7574"])
            and ([.records[].source] | sort == ["stderr", "stdout", "stdout"])
        ' "$RECEIVER_RESULT_PATH" >/dev/null \
        || fail "Fluentd receiver evidence did not match the Docker Forward contract"
}

# Write machine-readable timing and public-socket evidence.
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
        --argjson reference "$REFERENCE" \
        --argjson duration_seconds "$duration" \
        --slurpfile inspect "$WORK_ROOT/inspect.json" \
        --slurpfile receiver "$RECEIVER_RESULT_PATH" \
        '{
            docker: {
                clientVersion: $client_version,
                engineVersion: $engine_version
            },
            durationSeconds: $duration_seconds,
            inspect: $inspect[0][0],
            receiver: $receiver[0],
            reference: $reference
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
    write_result "$started"
    info "Fluentd Docker REST contract passed: $RESULT_PATH"
}

main "$@"
