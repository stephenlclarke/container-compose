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
#   sync-docker-compose-e2e-fixtures.sh [options]
#
# OPTIONS:
#   --dest PATH       Destination checkout. Defaults to .build/parity/docker-compose-e2e.
#   --repo URL        Source repository. Defaults to https://github.com/docker/compose.git.
#   --ref REF         Source branch. Defaults to main.
#   --strict          Fail when git or network access is unavailable.
#   -h, --help        Show this help.
#
# This helper refreshes a sparse checkout of Docker Compose's e2e fixture corpus
# only when the checkout is missing or Docker Compose's source branch moved. The
# checkout lives under .build so upstream fixture churn does not modify
# maintained source.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

DEST="$REPO_ROOT/.build/parity/docker-compose-e2e"
SOURCE_REPO="https://github.com/docker/compose.git"
SOURCE_REF="main"
STRICT=0

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
    sed -n '/^# USAGE:/,/^# This helper/ { /^# This helper/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/sync-docker-compose-e2e-fixtures.sh/$SCRIPT_NAME/"
}

# Parse command-line flags.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --dest)
                if (($# < 2)); then
                    error '--dest requires a path'
                    usage >&2
                    return 2
                fi
                DEST="$2"
                shift 2
                ;;
            --repo)
                if (($# < 2)); then
                    error '--repo requires a URL'
                    usage >&2
                    return 2
                fi
                SOURCE_REPO="$2"
                shift 2
                ;;
            --ref)
                if (($# < 2)); then
                    error '--ref requires a ref'
                    usage >&2
                    return 2
                fi
                SOURCE_REF="$2"
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

# Exit cleanly for optional fixture refresh dependencies, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; leaving Docker Compose e2e fixtures unchanged"
    exit 0
}

# Print the current local checkout commit when it exists.
print_local_head() {
    git -C "$DEST" rev-parse HEAD 2>/dev/null
}

# Return the current remote commit for the configured source branch.
remote_head() {
    git ls-remote "$SOURCE_REPO" "refs/heads/$SOURCE_REF" | awk '{print $1}'
}

# Clone the Docker Compose repository with only e2e fixtures checked out.
clone_fixtures() {
    local parent

    parent="$(dirname "$DEST")"
    mkdir -p "$parent"
    rm -rf "$DEST"
    git clone --depth 1 --branch "$SOURCE_REF" --filter=blob:none --sparse "$SOURCE_REPO" "$DEST" >/dev/null 2>&1
    git -C "$DEST" sparse-checkout set pkg/e2e/fixtures >/dev/null 2>&1
}

# Refresh an existing fixture checkout.
update_fixtures() {
    git -C "$DEST" remote set-url origin "$SOURCE_REPO" >/dev/null 2>&1
    git -C "$DEST" fetch --depth 1 origin "$SOURCE_REF" >/dev/null 2>&1
    git -C "$DEST" checkout --detach FETCH_HEAD >/dev/null 2>&1
    git -C "$DEST" sparse-checkout set pkg/e2e/fixtures >/dev/null 2>&1
}

# Refresh the local sparse checkout only when needed and print its commit.
main() {
    parse_args "$@"
    local local_head
    local remote

    if ! command -v git >/dev/null 2>&1; then
        skip_or_fail 'git is not available'
    fi

    remote="$(remote_head)"
    if [[ -z "$remote" ]]; then
        if ((STRICT == 0)) && [[ -d "$DEST/.git" ]] && print_local_head; then
            warning "could not resolve $SOURCE_REPO refs/heads/$SOURCE_REF; using existing Docker Compose e2e fixtures"
            exit 0
        fi
        skip_or_fail "could not resolve $SOURCE_REPO refs/heads/$SOURCE_REF"
    fi

    if [[ -d "$DEST/.git" ]]; then
        local_head="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
        if [[ "$local_head" != "$remote" ]]; then
            if ! update_fixtures; then
                skip_or_fail "failed to update Docker Compose e2e fixtures from $SOURCE_REPO"
            fi
        fi
    else
        if ! clone_fixtures; then
            skip_or_fail "failed to clone Docker Compose e2e fixtures from $SOURCE_REPO"
        fi
    fi

    printf '%s\n' "$(git -C "$DEST" rev-parse HEAD)"
}

main "$@"
