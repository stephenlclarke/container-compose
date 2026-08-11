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
#   check-docker-rest-splunk-hec-contract.sh [options]
#
# OPTIONS:
#   --host HOST        Docker endpoint to exercise, such as unix:///tmp/docker.sock.
#   --native-cli PATH  Optional Container CLI used to prove one shared authority.
#   --reference        Require the pinned Docker Engine 29.2.1 oracle.
#   --strict           Fail instead of skipping when a prerequisite is unavailable.
#   --work-root PATH   Existing marker-protected root in which to retain evidence.
#   -h, --help         Show this help.
#
# The fixture proves cache-disabled Splunk HEC delivery through the public Docker
# socket. It records only redacted result data; raw receiver requests remain
# mode-0600 inside the marker-protected evidence root.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-splunk-hec-root"
readonly TOKEN_SENTINEL="fixture-token-for-hec-contract"
readonly EXPECTED_PATH="/services/collector/event/1.0"

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
NATIVE_CLI=""
WORK_ROOT=""
WORK_ROOT_PROVIDED=0
ENGINE_VERSION=""
ENGINE_API_VERSION=""
CONTAINER_NAME=""
SERVER_PID=""

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
    sed -n '/^# USAGE:/,/^# The fixture/ { /^# The fixture/d; s/^# //; s/^#//; p; }' "$SELF_PATH" \
        | sed "s/check-docker-rest-splunk-hec-contract.sh/$SCRIPT_NAME/"
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

skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping Docker REST Splunk HEC validation"
    exit 0
}

run_docker() {
    if [[ -n "$DOCKER_HOST_OVERRIDE" ]]; then
        env -u DOCKER_API_VERSION DOCKER_HOST="$DOCKER_HOST_OVERRIDE" docker "$@"
    else
        env -u DOCKER_API_VERSION -u DOCKER_HOST docker "$@"
    fi
}

# Runs Docker with the same endpoint selection but a hard liveness boundary.
run_docker_bounded() {
    if [[ -n "$DOCKER_HOST_OVERRIDE" ]]; then
        env -u DOCKER_API_VERSION DOCKER_HOST="$DOCKER_HOST_OVERRIDE" \
            gtimeout 60 docker "$@"
    else
        env -u DOCKER_API_VERSION -u DOCKER_HOST gtimeout 60 docker "$@"
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

    [[ "$actual" == "$expected" ]] || fail "$description did not match"
}

assert_contains() {
    local actual="$1"
    local expected="$2"
    local description="$3"

    [[ "$actual" == *"$expected"* ]] || fail "$description is missing required content"
}

verify_prerequisites() {
    command -v docker >/dev/null 2>&1 \
        || skip_or_fail "docker CLI is unavailable"
    command -v jq >/dev/null 2>&1 \
        || skip_or_fail "jq is required for result evidence"
    command -v python3 >/dev/null 2>&1 \
        || skip_or_fail "python3 is required for the local HEC receiver"
    command -v gtimeout >/dev/null 2>&1 \
        || skip_or_fail "gtimeout is required for the liveness boundary"
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

prepare_work_root() {
    if ((WORK_ROOT_PROVIDED == 1)); then
        [[ -d "$WORK_ROOT" && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]] \
            || fail "--work-root must be an existing marker-protected directory"
        return
    fi
    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-splunk-hec.XXXXXX")"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"
}

cleanup() {
    if [[ -n "$CONTAINER_NAME" ]]; then
        run_docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if ((WORK_ROOT_PROVIDED == 0)) \
        && [[ -n "$WORK_ROOT" && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
}

assert_native_driver() {
    local inventory

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$CONTAINER_NAME" \
        'any(.[]; .id == $name and .configuration.logging.resolved.driver == "splunk")' \
        <<<"$inventory" >/dev/null \
        || fail "native authority does not expose the Splunk fixture container"
}

assert_container_absent() {
    local inspection
    local result
    local inventory

    set +e
    inspection="$(run_docker container inspect "$CONTAINER_NAME" 2>&1)"
    result=$?
    set -e
    ((result != 0)) || fail "fixture container remains inspectable after cleanup"
    assert_contains "$inspection" "No such container" "deleted-container inspection"

    [[ -n "$NATIVE_CLI" ]] || return 0
    inventory="$("$NATIVE_CLI" list --all --format json)"
    jq -e --arg name "$CONTAINER_NAME" 'all(.[]; .id != $name)' \
        <<<"$inventory" >/dev/null \
        || fail "native authority retained the deleted Splunk fixture container"
}

start_receiver() {
    local request_file="$WORK_ROOT/requests.jsonl"
    local port_file="$WORK_ROOT/receiver.port"

    python3 -u - "$request_file" "$port_file" <<'PY' \
        >"$WORK_ROOT/receiver.stdout" 2>"$WORK_ROOT/receiver.stderr" &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

request_file, port_file = sys.argv[1:]

class Receiver(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        record = {
            "method": self.command,
            "path": self.path,
            "headers": {key.lower(): value for key, value in self.headers.items()},
            "body_hex": body.hex(),
        }
        with open(request_file, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, sort_keys=True) + "\n")
        response = b'{"text":"Success","code":0}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, _format, *_args):
        return

server = ThreadingHTTPServer(("0.0.0.0", 0), Receiver)
with open(port_file, "w", encoding="utf-8") as stream:
    stream.write(str(server.server_address[1]))
    stream.flush()
server.serve_forever(poll_interval=0.1)
PY
    SERVER_PID=$!
    for _ in {1..50}; do
        [[ -s "$port_file" ]] && return
        sleep 0.1
    done
    fail "local HEC receiver did not publish a port"
}

verify_receiver() {
    local created_id="$1"

    for _ in {1..50}; do
        [[ -s "$WORK_ROOT/requests.jsonl" ]] && break
        sleep 0.1
    done
    [[ -s "$WORK_ROOT/requests.jsonl" ]] \
        || fail "HEC receiver captured no request"

    python3 - "$WORK_ROOT/requests.jsonl" "$TOKEN_SENTINEL" "$created_id" \
        "$EXPECTED_PATH" "$WORK_ROOT/receiver-summary.json" <<'PY'
import json
import sys

request_file, token, container_id, expected_path, result_file = sys.argv[1:]
with open(request_file, encoding="utf-8") as stream:
    requests = [json.loads(line) for line in stream if line.strip()]
if len(requests) != 1:
    raise SystemExit("expected one HEC request")
request = requests[0]
if request["method"] != "POST" or request["path"] != expected_path:
    raise SystemExit("unexpected HEC request route")
headers = request["headers"]
if headers.get("authorization") != "Splunk " + token:
    raise SystemExit("unexpected Splunk authorization")
if headers.get("content-encoding"):
    raise SystemExit("unexpected content encoding when gzip is disabled")
body = bytes.fromhex(request["body_hex"]).decode("utf-8")
decoder = json.JSONDecoder()
offset = 0
records = []
while offset < len(body):
    record, offset = decoder.raw_decode(body, offset)
    records.append(record)
if len(records) != 2:
    raise SystemExit("expected two HEC events")
events = sorted((record.get("event", {}).get("line"), record.get("event", {}).get("source")) for record in records)
if events != [("stderr-two", "stderr"), ("stdout-one", "stdout")]:
    raise SystemExit("unexpected HEC event lines or sources")
tag = container_id[:12]
for record in records:
    event = record.get("event", {})
    if event.get("tag") != tag or not record.get("host") or not record.get("time"):
        raise SystemExit("HEC event metadata did not match Docker shape")
summary = {
    "request_count": len(requests),
    "path": request["path"],
    "authorization_scheme": "Splunk",
    "authorization_token_matches": True,
    "content_encoding": headers.get("content-encoding", ""),
    "events": events,
    "tag": tag,
    "host": records[0]["host"],
}
with open(result_file, "w", encoding="utf-8") as stream:
    json.dump(summary, stream, sort_keys=True)
PY
}

run_contract() {
    local port
    local created_id
    local driver
    local state
    local exit_code
    local start_status

    start_receiver
    port="$(/bin/cat "$WORK_ROOT/receiver.port")"
    CONTAINER_NAME="cc-rest-splunk-hec-$(shasum -a 256 <<<"$WORK_ROOT" | /usr/bin/awk '{print substr($1, 1, 12)}')"
    created_id="$(run_docker create --name "$CONTAINER_NAME" --log-driver splunk \
        --log-opt "splunk-url=http://host.docker.internal:$port" \
        --log-opt "splunk-token=$TOKEN_SENTINEL" \
        --log-opt 'splunk-verify-connection=false' \
        --log-opt 'splunk-gzip=false' \
        --log-opt 'cache-disabled=true' \
        "$REQUIRED_IMAGE" sh -c 'printf stdout-one; printf stderr-two >&2')"

    driver="$(run_docker inspect --format '{{.HostConfig.LogConfig.Type}}' "$CONTAINER_NAME")"
    assert_equal "$driver" "splunk" "Splunk create driver"
    assert_native_driver

    set +e
    run_docker_bounded start -a "$CONTAINER_NAME" \
        >"$WORK_ROOT/start.stdout" 2>"$WORK_ROOT/start.stderr"
    start_status=$?
    set -e
    ((start_status == 0)) || fail "Splunk container did not exit cleanly"
    state="$(run_docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
    exit_code="$(run_docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME")"
    assert_equal "$state" "exited" "Splunk final state"
    assert_equal "$exit_code" "0" "Splunk container exit code"
    verify_receiver "$created_id"

    run_docker rm --force "$CONTAINER_NAME" >"$WORK_ROOT/remove.stdout"
    assert_container_absent
    CONTAINER_NAME=""

    jq -n \
        --arg driver "$driver" \
        --arg engine_version "$ENGINE_VERSION" \
        --arg engine_api_version "$ENGINE_API_VERSION" \
        --arg host "${DOCKER_HOST_OVERRIDE:-default}" \
        --arg container_id "$created_id" \
        --slurpfile receiver "$WORK_ROOT/receiver-summary.json" \
        '{driver:$driver, engine_version:$engine_version, engine_api_version:$engine_api_version, host:$host, container_id:$container_id, receiver:$receiver[0], state:"exited", exit_code:0, status:"passed"}' \
        >"$WORK_ROOT/result.json"
    chmod 600 "$WORK_ROOT"/requests.jsonl "$WORK_ROOT"/receiver-summary.json \
        "$WORK_ROOT"/receiver.stdout "$WORK_ROOT"/receiver.stderr \
        "$WORK_ROOT"/start.stdout "$WORK_ROOT"/start.stderr "$WORK_ROOT"/result.json
    info "Docker REST Splunk HEC contract passed"
}

main() {
    parse_args "$@"
    verify_prerequisites
    prepare_work_root
    trap cleanup EXIT
    run_contract
}

main "$@"
