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
#   --syslog-address-host HOST
#                      Hostname or address visible to the selected log driver.
#   --native-cli PATH  Optional Container CLI used to prove one shared authority.
#   --reference        Require the pinned Docker Engine 29.2.1 oracle.
#   --result PATH      Write machine-readable timing and result evidence to PATH.
#   --strict           Fail instead of skipping when a prerequisite is unavailable.
#   -h, --help         Show this help.
#
# The same unmodified Docker CLI fixture exercises Docker Engine 29.2.1 and
# Container's public socket. It proves cache-disabled Syslog UDP RFC 5424
# microsecond datagram framing, stdout/stderr/binary ordering, facility and
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
SYSLOG_ADDRESS_HOST="host.docker.internal"
NATIVE_CLI=""
RESULT_PATH=""
WORK_ROOT=""
CONTAINER_NAME=""
CONTAINER_ID=""
RECEIVER_PID=""
RECEIVER_PORT_PATH=""
RECEIVER_RESULT_PATH=""
RECEIVER_PORT=""

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
    printf '%s\n' 'Docker REST Syslog UDP contract fixture root v1' \
        >"$WORK_ROOT/$ROOT_MARKER_NAME"
    RECEIVER_PORT_PATH="$WORK_ROOT/receiver.port"
    RECEIVER_RESULT_PATH="$WORK_ROOT/receiver-result.json"
}

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
server.bind(("127.0.0.1", 0))
server.settimeout(0.2)
port_path.write_text(str(server.getsockname()[1]), encoding="ascii")
datagrams = []
deadline = time.monotonic() + 30.0
try:
    while len(datagrams) < expected_count and time.monotonic() < deadline:
        try:
            datagram, _ = server.recvfrom(1024 * 1024)
        except TimeoutError:
            continue
        datagrams.append(datagram.hex())
finally:
    server.close()
result_path.write_text(
    json.dumps(
        {
            "datagramsHex": datagrams,
            "expectedCount": expected_count,
            "timedOut": len(datagrams) != expected_count,
        },
        sort_keys=True,
    ) + "\n",
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

wait_for_receiver() {
    [[ -n "$RECEIVER_PID" ]] || fail "Syslog receiver was not started"
    if ! wait "$RECEIVER_PID"; then
        RECEIVER_PID=""
        fail "Syslog receiver exited nonzero"
        return
    fi
    RECEIVER_PID=""
    [[ -f "$RECEIVER_RESULT_PATH" ]] \
        || fail "Syslog receiver did not write its result"
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
    local address="udp://$SYSLOG_ADDRESS_HOST:$RECEIVER_PORT"

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
    local status

    set +e
    output="$(run_docker logs "$CONTAINER_NAME" 2>&1)"
    status=$?
    set -e
    ((status != 0)) || fail "Syslog logging unexpectedly returned readable history"
    [[ "$output" == "Error response from daemon: configured logging driver does not support reading" ]] \
        || fail "Syslog read error differs from Docker: $output"
}

assert_syslog_receiver_contract() {
    local container_id="$1"

    python3 - "$RECEIVER_RESULT_PATH" "$container_id" "$CONTAINER_NAME" <<'PY'
import json
import re
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
container_id = sys.argv[2]
container_name = sys.argv[3]
datagrams = result.get("datagramsHex")
if result.get("timedOut") is not False or not isinstance(datagrams, list) or len(datagrams) != 3:
    raise SystemExit(f"expected three Syslog UDP datagrams, got {result!r}")
frames = [bytes.fromhex(value) for value in datagrams]
pattern = re.compile(rb"^<(\d+)>1 (\S+) (\S+) (\S+) (\d+) (\S+) - (.*)$", re.DOTALL)
expected_contents = [
    b"stdout-ascii\n",
    "stderr-utf8-☃\n".encode("utf-8"),
    b"stdout-binary-\xff\x00-end\n",
]
expected_priority = [142, 139, 142]
expected_tag = f"syslog.{container_name.lstrip('/')}.{container_id[:12]}".encode("ascii")
for index, (frame, content, priority) in enumerate(zip(frames, expected_contents, expected_priority), start=1):
    match = pattern.fullmatch(frame)
    if match is None:
        raise SystemExit(f"Syslog datagram {index} is not an RFC 5424 message: {frame!r}")
    observed_priority = int(match.group(1))
    timestamp = match.group(2).decode("ascii")
    hostname = match.group(3)
    app_name = match.group(4)
    process_id = match.group(5)
    message_id = match.group(6)
    observed_content = match.group(7)
    if observed_priority != priority:
        raise SystemExit(f"Syslog datagram {index} priority {observed_priority}, expected {priority}")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}(?:Z|[+-]\d{2}:\d{2})", timestamp):
        raise SystemExit(f"Syslog datagram {index} timestamp is not RFC 3339 microseconds: {timestamp!r}")
    if not hostname or app_name != expected_tag or message_id != expected_tag:
        raise SystemExit(
            f"Syslog datagram {index} identity differs: hostname={hostname!r}, app={app_name!r}, messageID={message_id!r}"
        )
    if not process_id.isdigit() or int(process_id) <= 0:
        raise SystemExit(f"Syslog datagram {index} has invalid process ID: {process_id!r}")
    if observed_content != content:
        raise SystemExit(
            f"Syslog datagram {index} payload differs: {observed_content!r}, expected {content!r}"
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

    [[ -n "$RESULT_PATH" ]] || return
    [[ -d "$(dirname "$RESULT_PATH")" ]] \
        || fail "result parent directory does not exist: $(dirname "$RESULT_PATH")"
    jq -n \
        --arg contract "Docker REST Syslog UDP" \
        --arg endpoint "${DOCKER_HOST_OVERRIDE:-default-context}" \
        --arg containerID "$container_id" \
        --argjson durationSeconds "$duration_seconds" \
        '{contract: $contract, endpoint: $endpoint, durationSeconds: $durationSeconds, result: "passed", containerID: $containerID}' \
        >"$RESULT_PATH"
}

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
    start_udp_receiver
    workload='printf '\''stdout-ascii\n'\''; sleep 0.2; printf '\''stderr-utf8-\342\230\203\n'\'' >&2; sleep 0.2; printf '\''stdout-binary-\377\000-end\n'\'''
    container_id="$(run_docker create --name "$CONTAINER_NAME" \
        --log-driver syslog --log-opt cache-disabled=true \
        --log-opt "syslog-address=udp://$SYSLOG_ADDRESS_HOST:$RECEIVER_PORT" \
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
    write_result "$duration_seconds" "$container_id"
    info "Docker REST Syslog UDP contract passed in ${duration_seconds}s"
}

trap cleanup EXIT
main "$@"
