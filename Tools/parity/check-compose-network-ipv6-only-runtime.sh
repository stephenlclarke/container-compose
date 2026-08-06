#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-network-ipv6-only-runtime.sh [options]
#
# OPTIONS:
#   --strict    Require Docker Compose, Docker Engine, the built Compose CLI,
#               and (when live validation is requested) Container.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE              Exact built container-compose CLI.
#   CONTAINER_COMPOSE_CONTAINER    Exact matching Container CLI.
#   CONTAINER_COMPOSE_LIVE         Set to 1 to run the candidate runtime lane.
#   CONTAINER_PACKAGE_PATH         Local Container source used for the build.
#   CONTAINERIZATION_PACKAGE_PATH  Local Containerization source used for the build.
#   PARITY_EVIDENCE_DIR            Marker-protected root retained with raw
#                                  configs, inspections, timings, and hashes.
#   PARITY_TIMEOUT_SECONDS         Per-operation timeout (default: 300).
#
# This local-only certificate compares a Docker Compose IPv6-only project with
# the candidate. It proves the requested model, network configuration, endpoint
# address family, IPv6 service-name connectivity, lifecycle, and cleanup. A
# single timing sample is retained for diagnosis only; it is not release-grade
# performance evidence.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly FIXTURE_IMAGE="alpine:3.20"
readonly ROOT_MARKER=".container-compose-network-ipv6-only-root"
readonly ROOT_MARKER_VALUE="container-compose IPv6-only network certificate v1"

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
CONTAINER_COMPOSE_LIVE="${CONTAINER_COMPOSE_LIVE:-0}"
PARITY_TIMEOUT_SECONDS="${PARITY_TIMEOUT_SECONDS:-300}"
EVIDENCE_ROOT="${PARITY_EVIDENCE_DIR:-}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_FILE=""
DOCKER_PROJECT=""
CANDIDATE_PROJECT=""

# Print an informational line to stdout.
info() {
    printf '%s\n' "$*"
}

# Print a warning line to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error line to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print the documented command usage.
usage() {
    sed -n '/^# USAGE:/,/^# This local-only/ { /^# This local-only/d; s/^# //; s/^#//; p; }' "$SELF_PATH" |
        sed "s/check-compose-network-ipv6-only-runtime.sh/$SCRIPT_NAME/"
}

# Parse the supported command-line flags.
parse_args() {
    while (($# > 0)); do
        case "$1" in
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

# Fail strict invocations or skip optional local checks.
skip_or_fail() {
    local message="$1"
    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    warning "$message; skipping IPv6-only network runtime certificate"
    exit 0
}

# Resolve the Docker Compose CLI once for all reference operations.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is unavailable'
    fi
}

# Validate required tools and requested runtime inputs.
check_tools() {
    detect_docker_compose
    command -v python3 >/dev/null 2>&1 || skip_or_fail 'python3 is unavailable'
    docker info >/dev/null 2>&1 || skip_or_fail 'Docker Engine is unavailable'
    [[ "$PARITY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
        error "PARITY_TIMEOUT_SECONDS must be a positive integer: $PARITY_TIMEOUT_SECONDS"
        return 2
    }
    [[ -x "$CONTAINER_COMPOSE" ]] || skip_or_fail "container-compose binary is unavailable: $CONTAINER_COMPOSE"
    if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]] &&
        [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        skip_or_fail "matching Container binary is unavailable: $CONTAINER_BINARY"
    fi
}

# Execute one bounded command without inheriting an unbounded process group.
run_bounded() {
    python3 -c '
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit(124)
' "$PARITY_TIMEOUT_SECONDS" "$@"
}

# Return a monotonic timestamp for an operation timing record.
monotonic_nanoseconds() {
    python3 -c 'import time; print(time.monotonic_ns())'
}

# Record one diagnostic timing sample without assigning a performance verdict.
record_timing() {
    local lane="$1"
    local operation="$2"
    local start_ns="$3"
    local end_ns="$4"
    python3 - "$EVIDENCE_ROOT/timings.tsv" "$lane" "$operation" "$start_ns" "$end_ns" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
elapsed = (int(sys.argv[5]) - int(sys.argv[4])) / 1_000_000_000
with path.open("a", encoding="utf-8") as output:
    output.write(f"{sys.argv[2]}\t{sys.argv[3]}\t{elapsed:.6f}\n")
PY
}

# Run a command, write its output, and retain an operation timing sample.
run_capture() {
    local lane="$1"
    local operation="$2"
    local output_path="$3"
    shift 3
    local start_ns
    local end_ns
    start_ns="$(monotonic_nanoseconds)"
    local status
    if run_bounded "$@" >"$output_path" 2>&1; then
        status=0
    else
        status=$?
    fi
    end_ns="$(monotonic_nanoseconds)"
    record_timing "$lane" "$operation" "$start_ns" "$end_ns"
    return "$status"
}

# Create or verify the retained evidence root and its ownership marker.
prepare_evidence_root() {
    if [[ -z "$EVIDENCE_ROOT" ]]; then
        EVIDENCE_ROOT="$(mktemp -d /private/tmp/container-compose-network-ipv6-only.XXXXXX)"
    fi
    mkdir -p "$EVIDENCE_ROOT"
    local marker_path="$EVIDENCE_ROOT/$ROOT_MARKER"
    if [[ -e "$marker_path" ]]; then
        local marker_value
        IFS= read -r marker_value <"$marker_path" || true
        if [[ "$marker_value" != "$ROOT_MARKER_VALUE" ]]; then
            error "refusing an evidence root with an invalid marker: $EVIDENCE_ROOT"
            return 2
        fi
    elif [[ -n "$(find "$EVIDENCE_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        error "refusing a non-empty unmarked evidence root: $EVIDENCE_ROOT"
        return 2
    else
        printf '%s\n' "$ROOT_MARKER_VALUE" >"$marker_path"
    fi
    mkdir -p "$EVIDENCE_ROOT/reference" "$EVIDENCE_ROOT/candidate"
    printf 'lane\toperation\tseconds\n' >"$EVIDENCE_ROOT/timings.tsv"
}

# Write the immutable Compose project used by both reference and candidate lanes.
write_fixture() {
    FIXTURE_FILE="$EVIDENCE_ROOT/compose.yml"
    python3 - "$FIXTURE_FILE" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    """services:
  server:
    image: alpine:3.20
    command: [\"sh\", \"-c\", \"while :; do sleep 3600; done\"]
    networks:
      - ipv6only
  client:
    image: alpine:3.20
    command: [\"sh\", \"-c\", \"while :; do sleep 3600; done\"]
    networks:
      - ipv6only
networks:
  ipv6only:
    enable_ipv4: false
    enable_ipv6: true
    ipam:
      config:
        - subnet: fd00:2026:806::/64
""",
    encoding="utf-8",
)
PY
}

# Write source, binary, guest-input, and tool fingerprints before candidate use.
write_fingerprint() {
    local path="$EVIDENCE_ROOT/fingerprint.json"
    python3 - "$path" "$REPO_ROOT" "$CONTAINER_COMPOSE" "$CONTAINER_BINARY" \
        "${CONTAINER_PACKAGE_PATH:-}" "${CONTAINERIZATION_PACKAGE_PATH:-}" \
        "${CONTAINER_COMPOSE_INIT_IMAGE:-}" "${CONTAINER_RUNTIME_BUILDER_IMAGE:-}" \
        "${CONTAINER_RUNTIME_BUILDER_IMAGE_TAR:-}" "${CONTAINER_RUNTIME_BUILDER_REFERENCE:-}" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

(
    output,
    compose_root,
    compose_binary,
    container_binary,
    container_root,
    containerization_root,
    init_image,
    builder_image,
    builder_archive,
    builder_reference,
) = sys.argv[1:]

def digest(path):
    candidate = pathlib.Path(path)
    if not candidate.is_file():
        return None
    return hashlib.sha256(candidate.read_bytes()).hexdigest()

def git(path, *arguments):
    if not path or not pathlib.Path(path, ".git").exists():
        return None
    result = subprocess.run(
        ["git", "-C", path, *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.stdout if result.returncode == 0 else None

def source_fingerprint(path):
    if not path or not pathlib.Path(path, ".git").exists():
        return None
    head = git(path, "rev-parse", "HEAD")
    diff = git(path, "diff", "--binary", "HEAD")
    untracked = git(path, "ls-files", "--others", "--exclude-standard")
    untracked_digest = hashlib.sha256()
    for relative_path in (untracked or b"").decode("utf-8").splitlines():
        candidate = pathlib.Path(path, relative_path)
        untracked_digest.update(relative_path.encode("utf-8") + b"\\0")
        if candidate.is_file():
            untracked_digest.update(candidate.read_bytes())
    return {
        "path": str(pathlib.Path(path).resolve()),
        "head": head.decode("utf-8").strip() if head else None,
        "tracked_diff_sha256": hashlib.sha256(diff or b"").hexdigest(),
        "untracked_sha256": untracked_digest.hexdigest(),
    }

compose_source = source_fingerprint(compose_root)
container_source = source_fingerprint(container_root)
containerization_source = source_fingerprint(containerization_root)
payload = {
    "compose_source_sha": compose_source["head"] if compose_source else None,
    "container_source_sha": container_source["head"] if container_source else None,
    "containerization_source_sha": containerization_source["head"] if containerization_source else None,
    "source_fingerprints": {
        "compose": compose_source,
        "container": container_source,
        "containerization": containerization_source,
    },
    "compose_binary": compose_binary,
    "compose_binary_sha256": digest(compose_binary),
    "container_binary": container_binary,
    "container_binary_sha256": digest(container_binary),
    "guest_init_image": init_image or None,
    "runtime_builder_image": builder_image or None,
    "runtime_builder_reference": builder_reference or None,
    "runtime_builder_archive": builder_archive or None,
    "runtime_builder_archive_sha256": digest(builder_archive),
    "test_root": str(pathlib.Path(output).parent),
}
pathlib.Path(output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

# Assert the Docker Compose request model is explicitly IPv6-only.
assert_docker_config() {
    python3 - "$EVIDENCE_ROOT/reference/config.json" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["networks"]["ipv6only"]
if network.get("enable_ipv4") is not False or network.get("enable_ipv6") is not True:
    raise SystemExit(f"Docker Compose address-family model = {network!r}")
if network.get("ipam", {}).get("config", [{}])[0].get("subnet") != "fd00:2026:806::/64":
    raise SystemExit(f"Docker Compose IPv6 pool = {network.get('ipam')!r}")
PY
}

# Assert the Container Compose request model has no unsupported IPv4 marker.
assert_candidate_config() {
    python3 - "$EVIDENCE_ROOT/candidate/config.json" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["networks"]["ipv6only"]
if network.get("enableIPv4") is not False or network.get("enableIPv6") is not True:
    raise SystemExit(f"container-compose address-family model = {network!r}")
if network.get("unsupportedFields") is not None:
    raise SystemExit(f"container-compose unsupported fields = {network['unsupportedFields']!r}")
if network.get("ipv6Subnet") != "fd00:2026:806::/64":
    raise SystemExit(f"container-compose IPv6 pool = {network.get('ipv6Subnet')!r}")
PY
}

# Assert an inspected Docker network and server endpoint expose no IPv4 address.
assert_docker_observed_state() {
    python3 - "$EVIDENCE_ROOT/reference/network.json" "$EVIDENCE_ROOT/reference/server.json" <<'PY'
import json
import pathlib
import sys

network = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))[0]
server = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))[0]
if network.get("EnableIPv4") is not False or network.get("EnableIPv6") is not True:
    raise SystemExit(f"Docker network family state = {network.get('EnableIPv4')!r}/{network.get('EnableIPv6')!r}")
attachments = server.get("NetworkSettings", {}).get("Networks", {})
if len(attachments) != 1:
    raise SystemExit(f"Docker server attachments = {attachments!r}")
attachment = next(iter(attachments.values()))
if attachment.get("IPAddress") not in (None, ""):
    raise SystemExit(f"Docker server IPv4 address = {attachment.get('IPAddress')!r}")
if not attachment.get("GlobalIPv6Address"):
    raise SystemExit("Docker server has no observed IPv6 address")
PY
}

# Assert the candidate network request and endpoint attachments expose no IPv4.
assert_candidate_observed_state() {
    python3 - "$EVIDENCE_ROOT/candidate/network.json" "$EVIDENCE_ROOT/candidate/containers.json" "$CANDIDATE_PROJECT" <<'PY'
import json
import pathlib
import sys

network_items = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
containers = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
project = sys.argv[3]
if len(network_items) != 1:
    raise SystemExit(f"candidate network inspect count = {len(network_items)}")
network = network_items[0]
configuration = network.get("configuration", {})
if configuration.get("enableIPv4") is not False or configuration.get("enableIPv6") is not True:
    raise SystemExit(
        f"candidate network family state = {configuration.get('enableIPv4')!r}/{configuration.get('enableIPv6')!r}"
    )
if configuration.get("ipv4Subnet") is not None or configuration.get("ipv4Gateway") is not None:
    raise SystemExit(f"candidate network exposed IPv4 configuration = {configuration!r}")
if configuration.get("ipv6Subnet") != "fd00:2026:806::/64":
    raise SystemExit(f"candidate IPv6 subnet = {configuration.get('ipv6Subnet')!r}")

server_name = f"{project}-server-1"
server = next((item for item in containers if item.get("configuration", {}).get("id") == server_name), None)
if server is None:
    raise SystemExit(f"candidate server {server_name!r} is absent from native list")
attachments = server.get("status", {}).get("networks", [])
if len(attachments) != 1:
    raise SystemExit(f"candidate server attachments = {attachments!r}")
attachment = attachments[0]
if attachment.get("ipv4Address") is not None or attachment.get("ipv4Gateway") is not None:
    raise SystemExit(f"candidate server exposed IPv4 attachment = {attachment!r}")
if not attachment.get("ipv6Address"):
    raise SystemExit(f"candidate server has no observed IPv6 attachment = {attachment!r}")
PY
}

# Build a Compose command line for the selected candidate project.
candidate_compose() {
    env "CONTAINER_BIN=$CONTAINER_BINARY" "CONTAINER_COMPOSE_CONTAINER=$CONTAINER_BINARY" \
        "$CONTAINER_COMPOSE" --ansi never --project-name "$CANDIDATE_PROJECT" --file "$FIXTURE_FILE" "$@"
}

# Run Docker's complete reference lifecycle and retain raw results.
run_reference() {
    info 'Running Docker Compose IPv6-only reference lane'
    "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" --file "$FIXTURE_FILE" config --format json >"$EVIDENCE_ROOT/reference/config.json"
    assert_docker_config
    run_capture docker up "$EVIDENCE_ROOT/reference/up.log" \
        "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" --file "$FIXTURE_FILE" up --detach
    local network_name="${DOCKER_PROJECT}_ipv6only"
    local server_id
    server_id="$("${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" --file "$FIXTURE_FILE" ps --quiet server)"
    docker network inspect "$network_name" >"$EVIDENCE_ROOT/reference/network.json"
    docker inspect "$server_id" >"$EVIDENCE_ROOT/reference/server.json"
    run_capture docker ipv6-connectivity "$EVIDENCE_ROOT/reference/ping6.log" \
        "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" --file "$FIXTURE_FILE" exec -T client ping -6 -c 1 server
    assert_docker_observed_state
    run_capture docker down "$EVIDENCE_ROOT/reference/down.log" \
        "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" --file "$FIXTURE_FILE" down --remove-orphans
    if docker network inspect "$network_name" >"$EVIDENCE_ROOT/reference/network-after-down.log" 2>&1; then
        error "Docker network survived cleanup: $network_name"
        return 1
    fi
}

# Run the exact candidate lifecycle against the already-started isolated runtime.
run_candidate() {
    [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]] || return 0
    info 'Running container-compose IPv6-only candidate lane'
    local -a compose_command=(
        env "CONTAINER_BIN=$CONTAINER_BINARY" "CONTAINER_COMPOSE_CONTAINER=$CONTAINER_BINARY"
        "$CONTAINER_COMPOSE" --ansi never --project-name "$CANDIDATE_PROJECT" --file "$FIXTURE_FILE"
    )
    run_bounded "${compose_command[@]}" config --format json >"$EVIDENCE_ROOT/candidate/config.json"
    assert_candidate_config
    run_bounded "$CONTAINER_BINARY" image pull "$FIXTURE_IMAGE" >"$EVIDENCE_ROOT/candidate/image-pull.log" 2>&1
    run_capture container-compose up "$EVIDENCE_ROOT/candidate/up.log" "${compose_command[@]}" up --detach
    local network_name="${CANDIDATE_PROJECT}_ipv6only"
    run_bounded "$CONTAINER_BINARY" network inspect "$network_name" >"$EVIDENCE_ROOT/candidate/network.json"
    run_bounded "$CONTAINER_BINARY" list --all --format json >"$EVIDENCE_ROOT/candidate/containers.json"
    run_capture container-compose ipv6-connectivity "$EVIDENCE_ROOT/candidate/ping6.log" \
        "${compose_command[@]}" exec -T client ping -6 -c 1 server
    assert_candidate_observed_state
    run_capture container-compose down "$EVIDENCE_ROOT/candidate/down.log" \
        "${compose_command[@]}" down --remove-orphans
    if run_bounded "$CONTAINER_BINARY" network inspect "$network_name" >"$EVIDENCE_ROOT/candidate/network-after-down.log" 2>&1; then
        error "candidate network survived cleanup: $network_name"
        return 1
    fi
}

# Remove only the two project lifecycles, leaving marker-protected evidence intact.
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$FIXTURE_FILE" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" --project-name "$DOCKER_PROJECT" --file "$FIXTURE_FILE" down --remove-orphans >/dev/null 2>&1 || true
        if [[ "$CONTAINER_COMPOSE_LIVE" == "1" ]]; then
            candidate_compose down --remove-orphans >/dev/null 2>&1 || true
        fi
    fi
    exit "$status"
}

# Execute the reference and, when requested, the candidate certificate.
main() {
    parse_args "$@"
    check_tools
    prepare_evidence_root
    write_fixture
    DOCKER_PROJECT="cc-ipv6-reference-$RANDOM-$$"
    CANDIDATE_PROJECT="cc-ipv6-candidate-$RANDOM-$$"
    trap cleanup EXIT
    write_fingerprint
    run_reference
    run_candidate
    info "IPv6-only network certificate passed; retained evidence: $EVIDENCE_ROOT"
}

main "$@"
