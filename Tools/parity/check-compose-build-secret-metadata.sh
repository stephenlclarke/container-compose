#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright (c) 2026 container-compose project authors.
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
#   check-compose-build-secret-metadata.sh [options]
#
# OPTIONS:
#   --strict    Fail when Docker Compose V2 or container-compose is unavailable.
#   -h, --help  Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It verifies
# Docker Compose V2 accepts build secret uid/gid/mode metadata while omitting
# those fields from BuildKit bake secret entries, then verifies container-compose
# mirrors the build-print and build-command behavior.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
DOCKER_COMPOSE_COMMAND=()
FIXTURE_DIR=""

# Print an informational line to stdout.
info() {
    printf '%s\n' "$*"
}

# Print a warning to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Show usage extracted from the top-of-file help block.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-build-secret-metadata.sh/$SCRIPT_NAME/"
}

# Parse command-line options.
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

# Skip optional parity checks, or fail when strict mode is active.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose build-secret metadata parity check"
    exit 0
}

# Resolve the Docker Compose command used as the parity oracle.
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

# Ensure required local tools are available.
check_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a small Compose fixture with build secret metadata.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-build-secret-metadata.XXXXXX")"
    mkdir -p "$FIXTURE_DIR/api"
    cat >"$FIXTURE_DIR/api/Dockerfile" <<'DOCKERFILE'
FROM scratch
DOCKERFILE
    printf 'super-secret\n' >"$FIXTURE_DIR/secret.txt"
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: example/api:secretmeta
    build:
      context: ./api
      secrets:
        - source: app_secret
          target: runtime_secret
          uid: "1000"
          gid: "1000"
          mode: 0440
secrets:
  app_secret:
    file: ./secret.txt
YAML
}

# Remove the temporary Compose fixture.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert Docker Compose keeps metadata in config output.
assert_docker_config_preserves_metadata() {
    local path="$1"

    python3 - "$path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
secrets = doc.get("services", {}).get("api", {}).get("build", {}).get("secrets", [])
if len(secrets) != 1:
    raise SystemExit(f"Docker Compose rendered build secrets {secrets!r}")
secret = secrets[0]
want = {
    "source": "app_secret",
    "target": "runtime_secret",
    "uid": "1000",
    "gid": "1000",
    "mode": "0440",
}
for key, value in want.items():
    if secret.get(key) != value:
        raise SystemExit(f"Docker Compose build secret {key}={secret.get(key)!r}, want {value!r}")
PY
}

# Assert container-compose accepts metadata and reports effective secrets.
assert_container_config_accepts_metadata() {
    local path="$1"
    local secret_path="$2"

    python3 - "$path" "$secret_path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
secret_path = pathlib.Path(sys.argv[2]).as_posix()
build = doc.get("services", {}).get("api", {}).get("build", {})
if build.get("unsupportedFields"):
    raise SystemExit(f"container-compose still reports unsupported build fields: {build['unsupportedFields']!r}")
secrets = build.get("secrets", [])
if secrets != [{"id": "runtime_secret", "file": secret_path}]:
    raise SystemExit(f"container-compose effective build secrets {secrets!r}")
PY
}

# Assert BuildKit bake output omits unsupported secret metadata.
assert_bake_ignores_metadata() {
    local path="$1"
    local source="$2"
    local secret_path="$3"

    python3 - "$path" "$source" "$secret_path" <<'PY'
import json
import pathlib
import sys

doc = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
source = sys.argv[2]
secret_path = pathlib.Path(sys.argv[3]).as_posix()
target = doc.get("target", {}).get("api")
if not isinstance(target, dict):
    raise SystemExit(f"{source} did not render an api target")
secrets = target.get("secret")
want = [f"id=runtime_secret,type=file,src={secret_path}"]
if secrets != want:
    raise SystemExit(f"{source} rendered bake secrets {secrets!r}, want {want!r}")
for entry in secrets:
    if "uid=" in entry or "gid=" in entry or "mode=" in entry:
        raise SystemExit(f"{source} leaked ignored build secret metadata into bake JSON: {entry!r}")
PY
}

# Exercise Docker Compose as the parity baseline.
expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"
    local bake_output="$FIXTURE_DIR/docker-compose-bake.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_docker_config_preserves_metadata "$config_output"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build --print api >"$bake_output"
    assert_bake_ignores_metadata "$bake_output" 'Docker Compose' "$FIXTURE_DIR/secret.txt"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build api >/dev/null
}

# Exercise container-compose against the same fixture.
expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local bake_output="$FIXTURE_DIR/container-compose-bake.json"
    local dry_run_output

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_container_config_accepts_metadata "$config_output" "$FIXTURE_DIR/secret.txt"

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build --print api >"$bake_output"
    assert_bake_ignores_metadata "$bake_output" 'container-compose' "$FIXTURE_DIR/secret.txt"

    dry_run_output="$("$CONTAINER_COMPOSE" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build api)"
    if [[ "$dry_run_output" != *"id=runtime_secret,src="*"/secret.txt"* || "$dry_run_output" == *"uid="* || "$dry_run_output" == *"gid="* || "$dry_run_output" == *"mode="* ]]; then
        error 'container-compose did not mirror Docker Compose BuildKit handling for build secret metadata'
        printf '%s\n' "$dry_run_output" >&2
        return 1
    fi
}

# Run the parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT

    expect_docker_behavior
    expect_container_behavior

    info 'Docker Compose build-secret metadata parity passed.'
}

main "$@"
