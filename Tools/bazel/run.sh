#!/usr/bin/env bash
# Copyright © 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
# USAGE: run.sh build|test|coverage|coverage-report|restore-candidate [ARGS...]
set -euo pipefail
exec /usr/bin/python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/run.py" "$@"
