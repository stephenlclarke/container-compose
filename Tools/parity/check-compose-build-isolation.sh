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
#   check-compose-build-isolation.sh [options]
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
# Docker Compose V2 accepts service build.isolation values on the local builder,
# preserves the value in config output, omits it from Buildx bake JSON, and then
# verifies container-compose mirrors that config and build-print behavior.

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

# Print an informational message to stdout.
info() {
    printf '%s\n' "$*"
}

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
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-build-isolation.sh/$SCRIPT_NAME/"
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

# Either fail in strict mode or skip the local-only parity check.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose build-isolation parity check"
    exit 0
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

# Check local tools needed by the comparison.
check_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi
}

# Create a minimal build project with a platform-specific isolation request.
create_fixture() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/compose-build-isolation.XXXXXX")"
    mkdir -p "$FIXTURE_DIR/api"
    cat >"$FIXTURE_DIR/api/Dockerfile" <<'DOCKERFILE'
FROM scratch
DOCKERFILE
    cat >"$FIXTURE_DIR/compose.yml" <<'YAML'
services:
  api:
    image: example/api:isolation
    build:
      context: ./api
      isolation: hyperv
YAML
}

# Remove temporary fixture files.
cleanup() {
    if [[ -n "$FIXTURE_DIR" ]]; then
        rm -rf "$FIXTURE_DIR"
    fi
}

# Assert config JSON preserves the Compose build isolation value.
assert_config_isolation() {
    local path="$1"
    local source="$2"

    python3 - "$path" "$source" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = sys.argv[2]
doc = json.loads(path.read_text(encoding="utf-8"))
isolation = doc.get("services", {}).get("api", {}).get("build", {}).get("isolation")
if isolation != "hyperv":
    raise SystemExit(f"{source} rendered build.isolation {isolation!r}, want 'hyperv'")
PY
}

# Assert a bake JSON document contains the expected target and no isolation key.
assert_bake_omits_isolation() {
    local path="$1"
    local source="$2"

    python3 - "$path" "$source" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = sys.argv[2]
doc = json.loads(path.read_text(encoding="utf-8"))
target = doc.get("target", {}).get("api")
if not isinstance(target, dict):
    raise SystemExit(f"{source} did not render an api target")
if target.get("tags") != ["example/api:isolation"]:
    raise SystemExit(f"{source} rendered tags {target.get('tags')!r}")
if "isolation" in target:
    raise SystemExit(f"{source} leaked build.isolation into bake JSON")
PY
}

# Assert Docker Compose accepts and builds the fixture.
expect_docker_build_accepts_isolation() {
    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build api >/dev/null
}

# Assert Docker Compose config and build-print behavior.
expect_docker_behavior() {
    local config_output="$FIXTURE_DIR/docker-compose-config.json"
    local bake_output="$FIXTURE_DIR/docker-compose-bake.json"

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_config_isolation "$config_output" 'Docker Compose'

    "${DOCKER_COMPOSE_COMMAND[@]}" \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build --print api >"$bake_output"
    assert_bake_omits_isolation "$bake_output" 'Docker Compose'

    expect_docker_build_accepts_isolation
}

# Assert container-compose config and build-print behavior.
expect_container_behavior() {
    local config_output="$FIXTURE_DIR/container-compose-config.json"
    local bake_output="$FIXTURE_DIR/container-compose-bake.json"
    local dry_run_output

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        config --format json >"$config_output"
    assert_config_isolation "$config_output" 'container-compose'

    "$CONTAINER_COMPOSE" \
        --ansi never \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build --print api >"$bake_output"
    assert_bake_omits_isolation "$bake_output" 'container-compose'

    dry_run_output="$("$CONTAINER_COMPOSE" \
        --ansi never \
        --dry-run \
        --project-directory "$FIXTURE_DIR" \
        -f "$FIXTURE_DIR/compose.yml" \
        build api)"
    if [[ "$dry_run_output" != *"container build"* || "$dry_run_output" == *"--isolation"* ]]; then
        error 'container-compose did not mirror Docker Compose Buildx handling for build.isolation'
        printf '%s\n' "$dry_run_output" >&2
        return 1
    fi
}

# Run the local-only Docker Compose V2 parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    create_fixture
    trap cleanup EXIT

    expect_docker_behavior
    expect_container_behavior

    info 'Docker Compose build-isolation parity passed.'
}

main "$@"
