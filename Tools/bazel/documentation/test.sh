#!/usr/bin/env bash
# Copyright 2026 Container-family authors. SPDX-License-Identifier: Apache-2.0
# USAGE: test.sh TEST_MODULE DOC_ARCHIVE
# Run isolated action regressions and inspect the actual native DocC artifact.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/python3 "$1" "$2"
