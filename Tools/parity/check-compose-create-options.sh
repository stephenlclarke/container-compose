#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#===----------------------------------------------------------------------===#

#
# USAGE:
#   check-compose-create-options.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2, the Docker daemon, or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#   DOCKER_COMPOSE_E2E_DIR
#                      Sparse checkout path for docker/compose e2e fixtures.
#                      Defaults to .build/parity/docker-compose-e2e.
#
# This script is intentionally local-only and is not part of CI. It first
# validates Docker Compose V2's rendered create-time container configuration,
# then runs the same fixture through container-compose so fork-backed runtime
# option mapping is exercised before Apple-facing PR review. The build-backed
# service uses a Dockerfile refreshed from docker/compose e2e fixtures.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
TMPDIR=""
COMPOSE_FILE=""
DOCKER_PROJECT_NAME="container-compose-create-docker-$RANDOM-$$"
CONTAINER_PROJECT_NAME="container-compose-create-runtime-$RANDOM-$$"
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_PROJECT_TOUCHED=0
DOCKER_COMPOSE_COMMAND=()
DOCKER_COMPOSE_E2E_DIR="${DOCKER_COMPOSE_E2E_DIR:-$REPO_ROOT/.build/parity/docker-compose-e2e}"
DOCKER_COMPOSE_E2E_FIXTURES="$DOCKER_COMPOSE_E2E_DIR/pkg/e2e/fixtures"
DOCKER_COMPOSE_E2E_COMMIT=""

# Print a warning message to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print usage text extracted from the top of this script.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-create-options.sh/$SCRIPT_NAME/"
}

# Parse command-line flags.
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

# Exit cleanly for optional local runtime dependencies, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker/container-compose create-options parity check"
    exit 0
}

# Run a command with a bounded wall-clock timeout.
with_timeout() {
    local seconds="$1"
    shift

    perl -e 'alarm shift @ARGV; exec @ARGV' "$seconds" "$@"
}

# Locate Docker Compose V2, accepting either plugin or standalone command form.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is not available'
    fi
}

# Check Docker Compose V2 and daemon availability.
check_docker() {
    detect_docker_compose
    if ! docker info >/dev/null 2>&1; then
        skip_or_fail 'Docker daemon is not available'
    fi
}

# Check the configured container-compose binary.
check_container_compose() {
    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi

    if ! "$CONTAINER_COMPOSE" version >/dev/null 2>&1; then
        skip_or_fail "container-compose binary could not run: $CONTAINER_COMPOSE"
    fi
}

# Refresh docker/compose e2e fixtures only when missing or upstream moved.
sync_docker_compose_e2e_fixtures() {
    local sync_args
    local sync_output

    sync_args=(--dest "$DOCKER_COMPOSE_E2E_DIR")
    if ((STRICT == 1)); then
        sync_args+=(--strict)
    fi

    if ! sync_output="$("$REPO_ROOT/Tools/parity/sync-docker-compose-e2e-fixtures.sh" "${sync_args[@]}" 2>&1)"; then
        skip_or_fail "$sync_output"
    fi

    DOCKER_COMPOSE_E2E_COMMIT="$(printf '%s\n' "$sync_output" | tail -n 1)"
}

# Create a Compose fixture covering create-time options mapped by this repo.
create_fixture() {
    local upstream_dockerfile
    local build_image_name

    mkdir -p "$REPO_ROOT/.build/parity"
    TMPDIR="$(mktemp -d "$REPO_ROOT/.build/parity/create-options.XXXXXX")"
    COMPOSE_FILE="$TMPDIR/compose.yml"
    upstream_dockerfile="$DOCKER_COMPOSE_E2E_FIXTURES/build-test/minimal/Dockerfile"
    build_image_name="$CONTAINER_PROJECT_NAME-built:latest"

    if [[ ! -f "$upstream_dockerfile" ]]; then
        skip_or_fail "Docker Compose e2e Dockerfile is missing: $upstream_dockerfile"
    fi

    printf 'enabled=true\n' >"$TMPDIR/api.conf"
    printf 'secret\n' >"$TMPDIR/api-token.txt"
    printf 'copied from docker/compose e2e commit %s\n' "$DOCKER_COMPOSE_E2E_COMMIT" >"$TMPDIR/source.txt"
    cp "$upstream_dockerfile" "$TMPDIR/Dockerfile"
    cat >"$COMPOSE_FILE" <<YAML
services:
  built:
    build:
      context: .
      dockerfile: Dockerfile
    image: $build_image_name
    command: ["true"]
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    working_dir: /srv/app
    user: "1000:1000"
    hostname: api-host
    domainname: compose.test
    extra_hosts:
      - "static.local=127.0.0.44"
      - "host.docker.internal=host-gateway"
    dns_opt:
      - use-vc
    sysctls:
      net.ipv4.ip_unprivileged_port_start: "1024"
    blkio_config:
      weight: 300
    logging:
      driver: local
      options:
        max-size: "512b"
        max-file: "3"
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "test -f /tmp/ready || exit 1"]
      interval: 5s
      timeout: 1s
      retries: 2
      start_period: 3s
      start_interval: 1s
    ports:
      - "127.0.0.1:18080:8080"
    configs:
      - source: api_config
        target: /etc/api.conf
    secrets:
      - api_token
  worker:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 60"]
    logging:
      driver: none
    deploy:
      restart_policy:
        condition: on-failure
        delay: 2s
        max_attempts: 4
        window: 6s
configs:
  api_config:
    file: ./api.conf
secrets:
  api_token:
    file: ./api-token.txt
networks:
  default: {}
YAML
}

# Clean up the temporary Docker and container-compose projects.
cleanup() {
    if [[ -n "$COMPOSE_FILE" ]]; then
        "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
        if ((CONTAINER_PROJECT_TOUCHED == 1)) && [[ -x "$CONTAINER_COMPOSE" ]]; then
            with_timeout 30 "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1 || true
        fi
    fi
    if [[ -n "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
}

# Validate Docker Compose's rendered create-time container configuration.
validate_docker_create() {
    python3 - "$DOCKER_PROJECT_NAME" "$COMPOSE_FILE" "$TMPDIR" "${DOCKER_COMPOSE_COMMAND[@]}" <<'PY'
import json
import subprocess
import sys

project, compose_file, tmpdir = sys.argv[1:4]
compose_command = sys.argv[4:]


def inspect(service):
    container_id = subprocess.check_output(
        compose_command + ["-p", project, "-f", compose_file, "ps", "--all", "-q", service],
        text=True,
    ).strip()
    if not container_id:
        raise SystemExit(f"service {service!r} did not create a container")
    raw = subprocess.check_output(["docker", "inspect", container_id], text=True)
    return json.loads(raw)[0]


def require(condition, message):
    if not condition:
        raise SystemExit(message)


api = inspect("api")
api_config = api["Config"]
api_host = api["HostConfig"]

require(api_config["WorkingDir"] == "/srv/app", "api working_dir was not rendered")
require(api_config["User"] == "1000:1000", "api user was not rendered")
require(api_config["Hostname"] == "api-host", "api hostname was not rendered")
require(api_config["Domainname"] == "compose.test", "api domainname was not rendered")
require(api_host["LogConfig"]["Type"] == "local", "api log driver was not local")
require(api_host["LogConfig"]["Config"].get("max-size") == "512b", "api max-size log option was not rendered")
require(api_host["LogConfig"]["Config"].get("max-file") == "3", "api max-file log option was not rendered")
require(api_host["RestartPolicy"] == {"Name": "unless-stopped", "MaximumRetryCount": 0}, "api restart policy was not unless-stopped")
require(api_host["DnsOptions"] == ["use-vc"], "api DNS options were not rendered")
require(api_host["Sysctls"] == {"net.ipv4.ip_unprivileged_port_start": "1024"}, "api sysctls were not rendered")
require(api_host["BlkioWeight"] == 300, "api blkio weight was not rendered")
require("static.local:127.0.0.44" in api_host["ExtraHosts"], "api static extra_hosts entry was not rendered")
require("host.docker.internal:host-gateway" in api_host["ExtraHosts"], "api host-gateway entry was not rendered")

healthcheck = api_config["Healthcheck"]
require(healthcheck["Test"] == ["CMD-SHELL", "test -f /tmp/ready || exit 1"], "api healthcheck command was not rendered")
require(healthcheck["Interval"] == 5_000_000_000, "api healthcheck interval was not rendered")
require(healthcheck["Timeout"] == 1_000_000_000, "api healthcheck timeout was not rendered")
require(healthcheck["Retries"] == 2, "api healthcheck retries were not rendered")
require(healthcheck["StartPeriod"] == 3_000_000_000, "api healthcheck start_period was not rendered")
require(healthcheck["StartInterval"] == 1_000_000_000, "api healthcheck start_interval was not rendered")

bindings = api_host["PortBindings"].get("8080/tcp") or []
require(bindings and bindings[0]["HostIp"] == "127.0.0.1", "api host_ip port binding was not rendered")
require(bindings[0]["HostPort"] == "18080", "api published host port was not rendered")

mounts = {
    mount["Target"]: mount
    for mount in api_host["Mounts"]
    if mount.get("Type") == "bind"
}
require(mounts.get("/etc/api.conf", {}).get("Source") == f"{tmpdir}/api.conf", "api config bind was not rendered")
require(mounts.get("/etc/api.conf", {}).get("ReadOnly") is True, "api config bind was not readonly")
require(mounts.get("/run/secrets/api_token", {}).get("Source") == f"{tmpdir}/api-token.txt", "api secret bind was not rendered")
require(mounts.get("/run/secrets/api_token", {}).get("ReadOnly") is True, "api secret bind was not readonly")

worker = inspect("worker")
worker_host = worker["HostConfig"]
require(worker_host["LogConfig"]["Type"] == "none", "worker disabled logging was not rendered")
require(worker_host["RestartPolicy"] == {"Name": "on-failure", "MaximumRetryCount": 4}, "worker deploy restart policy was not rendered")

built = inspect("built")
require(built["Config"]["Image"].endswith("-built:latest"), "build-backed service did not use the expected image tag")
PY
}

# Validate container-compose's create command plan for the same fixture.
validate_container_compose_dry_run() {
    local dry_run_output

    dry_run_output="$("$CONTAINER_COMPOSE" --dry-run -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" create --build --force-recreate)"

    [[ "$dry_run_output" == *"container build --tag $CONTAINER_PROJECT_NAME-built:latest"* ]]
    [[ "$dry_run_output" == *"--file $TMPDIR/Dockerfile $TMPDIR"* ]]
    [[ "$dry_run_output" == *"container create --name $CONTAINER_PROJECT_NAME-built-1"* ]]
    [[ "$dry_run_output" == *"container create --name $CONTAINER_PROJECT_NAME-api-1"* ]]
    [[ "$dry_run_output" == *"--log-opt max-file=3"* ]]
    [[ "$dry_run_output" == *"--log-opt max-size=512b"* ]]
    [[ "$dry_run_output" == *"--health-cmd 'test -f /tmp/ready || exit 1'"* ]]
    [[ "$dry_run_output" == *"--health-interval 5s"* ]]
    [[ "$dry_run_output" == *"--health-timeout 1s"* ]]
    [[ "$dry_run_output" == *"--health-start-period 3s"* ]]
    [[ "$dry_run_output" == *"--health-start-interval 1s"* ]]
    [[ "$dry_run_output" == *"--health-retries 2"* ]]
    [[ "$dry_run_output" == *"--restart unless-stopped"* ]]
    [[ "$dry_run_output" == *"--publish 127.0.0.1:18080:8080"* ]]
    [[ "$dry_run_output" == *"--volume $TMPDIR/api.conf:/etc/api.conf:ro"* ]]
    [[ "$dry_run_output" == *"--volume $TMPDIR/api-token.txt:/run/secrets/api_token:ro"* ]]
    [[ "$dry_run_output" == *"--workdir /srv/app"* ]]
    [[ "$dry_run_output" == *"--user 1000:1000"* ]]
    [[ "$dry_run_output" == *"--hostname api-host"* ]]
    [[ "$dry_run_output" == *"--domainname compose.test"* ]]
    [[ "$dry_run_output" == *"--dns-option use-vc"* ]]
    [[ "$dry_run_output" == *"--add-host host.docker.internal:host-gateway"* ]]
    [[ "$dry_run_output" == *"--add-host static.local:127.0.0.44"* ]]
    [[ "$dry_run_output" == *"--sysctl net.ipv4.ip_unprivileged_port_start=1024"* ]]
    [[ "$dry_run_output" == *"--blkio weight=300"* ]]
    [[ "$dry_run_output" == *"container create --name $CONTAINER_PROJECT_NAME-worker-1"* ]]
    [[ "$dry_run_output" == *"--log-driver none"* ]]
    [[ "$dry_run_output" == *"--restart on-failure:4"* ]]
    [[ "$dry_run_output" == *"--restart-delay 2s"* ]]
    [[ "$dry_run_output" == *"--restart-window 6s"* ]]
}

# Run container-compose create against the same fixture.
run_container_compose_create() {
    local create_output

    CONTAINER_PROJECT_TOUCHED=1
    if ! create_output="$(with_timeout 120 "$CONTAINER_COMPOSE" -p "$CONTAINER_PROJECT_NAME" -f "$COMPOSE_FILE" create --build --pull missing --force-recreate 2>&1)"; then
        skip_or_fail "container-compose create failed: $create_output"
    fi
}

# Run the local-only Docker Compose V2 and container-compose parity check.
main() {
    parse_args "$@"
    check_docker
    check_container_compose
    sync_docker_compose_e2e_fixtures
    create_fixture
    trap cleanup EXIT

    "${DOCKER_COMPOSE_COMMAND[@]}" -p "$DOCKER_PROJECT_NAME" -f "$COMPOSE_FILE" create --build --pull missing --force-recreate >/dev/null
    validate_docker_create
    validate_container_compose_dry_run
    run_container_compose_create
    printf 'Docker Compose/container-compose create-options parity check passed for projects %s and %s\n' "$DOCKER_PROJECT_NAME" "$CONTAINER_PROJECT_NAME"
}

main "$@"
