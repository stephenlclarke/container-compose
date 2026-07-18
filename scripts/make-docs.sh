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

set -euo pipefail

if (( $# != 2 )); then
    printf 'usage: %s OUTPUT_PATH HOSTING_BASE_PATH\n' "$0" >&2
    exit 2
fi

output_path="$1"
hosting_base_path="$2"
scratch_path="${DOCS_SCRATCH_PATH:-.build/docc}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_reference="${DOCS_SOURCE_REFERENCE:-${GITHUB_SHA:-main}}"

arguments=(
    --disable-automatic-resolution
    --scratch-path "$scratch_path"
    --allow-writing-to-directory "$output_path"
    generate-documentation
    --target ComposeCore
    --output-path "$output_path"
    --disable-indexing
    --transform-for-static-hosting
    --enable-experimental-combined-documentation
    --hosting-base-path "$hosting_base_path"
    --source-service github
    --source-service-base-url "https://github.com/stephenlclarke/container-compose/blob/$source_reference"
    --checkout-path "$repository_root"
)

swift package "${arguments[@]}"

printf '{}\n' > "$output_path/theme-settings.json"

cat > "$output_path/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en-US">
  <head>
    <meta charset="utf-8">
    <title>Container Documentation</title>
    <meta http-equiv="refresh" content="0; url=./documentation/composecore/containerprojects/">
  </head>
  <body>
    <p>If you are not redirected automatically, <a href="./documentation/composecore/containerprojects/">open the Container documentation portal</a>.</p>
  </body>
</html>
EOF
