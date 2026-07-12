#!/usr/bin/env bash
##===----------------------------------------------------------------------===##
## Copyright © 2026 container-compose project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

set -euo pipefail

repo="${1:-../containerization}"

if [[ ! -f "$repo/Package.swift" ]]; then
    printf 'containerization checkout is missing at %s\n' "$repo" >&2
    exit 1
fi

swift package unedit containerization --force >/dev/null 2>&1 || true
swift package edit containerization --path "$repo"
