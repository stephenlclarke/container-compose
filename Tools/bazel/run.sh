#!/usr/bin/env bash
# Copyright © 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
# USAGE: run.sh build|test|coverage|coverage-report|restore-candidate [ARGS...]
set -euo pipefail
python=/usr/bin/python3
for argument in "$@"; do
    case "$argument" in
        --native-container-source=*|--native-layer-locks=*) python=/opt/homebrew/bin/python3 ;;
    esac
done
if [[ "$python" != /usr/bin/python3 ]]; then
    "$python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else "Native Container proof admission requires Python >= 3.10")'
fi
exec "$python" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/run.py" "$@"
