#!/usr/bin/env bash
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
# USAGE: release-notes.sh TEST_MODULE
# Run isolated release-note Git fixtures under the native Bazel test runner.
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
exec /usr/bin/python3 "$1"
