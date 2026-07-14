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
#   check-docker-compose-reference.sh [--strict]
#
# ENVIRONMENT:
#   DOCKER_COMPOSE                    Docker Compose command to validate.
#                                     Defaults to "docker compose".
#   DOCKER_COMPOSE_REFERENCE_VERSION  Required Docker Compose version.
#                                     Defaults to 5.3.1.
#
# This preflight makes every parity target use the documented Docker Compose
# oracle version rather than whichever version happens to be installed.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
readonly SCRIPT_NAME="$(basename "$SELF_PATH")"

DOCKER_COMPOSE_VALUE="${DOCKER_COMPOSE:-docker compose}"
REQUIRED_VERSION="${DOCKER_COMPOSE_REFERENCE_VERSION:-5.3.1}"
DOCKER_COMPOSE_COMMAND=()

# Print an error message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print usage text extracted from the top of this script.
usage() {
    sed -n '/^# USAGE:/,/^# This preflight/ { /^# This preflight/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-docker-compose-reference.sh/$SCRIPT_NAME/"
}

# Parse supported command-line flags.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict)
                shift
                ;;
            -h|--help)
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

# Resolve the configured Docker Compose command without invoking a shell.
resolve_command() {
    IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE_VALUE"
    if ((${#DOCKER_COMPOSE_COMMAND[@]} == 0)); then
        error 'DOCKER_COMPOSE is empty'
        return 2
    fi
}

# Require the exact version used to maintain parity expectations.
verify_version() {
    local actual_version

    if ! actual_version="$("${DOCKER_COMPOSE_COMMAND[@]}" version --short 2>/dev/null)"; then
        error "Docker Compose reference is unavailable: ${DOCKER_COMPOSE_VALUE}"
        return 1
    fi
    actual_version="${actual_version#v}"
    if [[ "$actual_version" != "$REQUIRED_VERSION" ]]; then
        error "Docker Compose reference version is ${actual_version}; expected ${REQUIRED_VERSION}"
        return 1
    fi
    printf 'Docker Compose reference: %s (%s)\n' "$actual_version" "$DOCKER_COMPOSE_VALUE"
}

main() {
    parse_args "$@"
    resolve_command
    verify_version
}

main "$@"
