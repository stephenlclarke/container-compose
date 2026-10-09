#!/usr/bin/env bash
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
# USAGE: cli-smoke.sh COMPOSE_EXECUTABLE
# Check the native CLI without contacting a container service or requiring Go assets.
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: %s COMPOSE_EXECUTABLE\n' "${0##*/}"
    exit 0
fi
[[ $# == 1 && -x "$1" ]] || { printf 'Expected one executable.\n' >&2; exit 2; }
output="$("$1" --ansi never --help)"
printf '%s\n' "$output"
[[ "$output" == 'Usage:  container compose '* && "$output" == *Commands:* && "$output" == *'Create and start containers'* && "$output" == *'Stop and remove containers, networks'* ]] || {
    printf 'Native CLI help is missing its command surface.\n' >&2
    exit 1
}
