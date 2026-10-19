#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright 2026 container-compose project authors.
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

# USAGE:
#   run-unit-contracts.sh [--disable-automatic-resolution] --filter REGEX
#
# OPTIONS:
#   --disable-automatic-resolution  Preserve the standalone SwiftPM option.
#   --filter REGEX                  Exact existing Swift test selection.
#   -h, --help                      Show this help.
#
# ENVIRONMENT:
#   COMPOSE_PARITY_TEST_RUNNER      Optional absolute executable accepting
#                                  --filter REGEX for already-built tests.
#
# This helper preserves standalone SwiftPM behavior. An explicit prebuilt
# adapter replaces compilation and must fail when its tests cannot execute.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME

# Print usage from the maintained header.
usage() {
    sed -n '/^# USAGE:/,/^# This helper/ { /^# This helper/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/run-unit-contracts.sh/$SCRIPT_NAME/"
}

# Select one execution route without interpreting the adapter path as shell code.
main() {
    local original=("$@")
    local filter=""
    local runner="${COMPOSE_PARITY_TEST_RUNNER:-}"
    while (($# > 0)); do
        case "$1" in
            --disable-automatic-resolution)
                shift
                ;;
            --filter)
                if (($# < 2)) || [[ -z "$2" || -n "$filter" ]]; then
                    printf 'error: exactly one nonempty --filter is required\n' >&2
                    return 2
                fi
                filter="$2"
                shift 2
                ;;
            -h | --help)
                usage
                return 0
                ;;
            *)
                printf 'error: unknown unit-contract argument: %s\n' "$1" >&2
                usage >&2
                return 2
                ;;
        esac
    done
    if [[ -z "$filter" ]]; then
        printf 'error: --filter is required\n' >&2
        return 2
    fi
    if [[ -z "$runner" ]]; then
        exec swift test "${original[@]}"
    fi
    if [[ "$runner" != /* || ! -f "$runner" || ! -x "$runner" ]]; then
        printf 'error: COMPOSE_PARITY_TEST_RUNNER must be an absolute executable file\n' >&2
        return 2
    fi
    exec "$runner" --filter "$filter"
}

main "$@"
