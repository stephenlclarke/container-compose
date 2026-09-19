#!/usr/bin/env bash
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
# USAGE: package.sh TEST_MODULE BUILD_INFO_HELPER unit|archive [ARCHIVE]
# Run native package boundary regressions with case-level XML on SSD.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/python3 "$@"
