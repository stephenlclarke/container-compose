#!/usr/bin/env bash
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
# USAGE: cli-contracts.sh TEST_MODULE COMPOSE_EXECUTABLE NORMALIZER_EXECUTABLE
# Exercise declared native products without source builds or runtime services.
set -euo pipefail
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf 'Usage: %s TEST_MODULE COMPOSE_EXECUTABLE NORMALIZER_EXECUTABLE\n' "${0##*/}"
    exit 0
fi
[[ $# == 3 && -f "$1" && -x "$2" && -x "$3" ]] || {
    printf 'Expected a test module and two declared executable products.\n' >&2
    exit 2
}
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/python3 "$@"
