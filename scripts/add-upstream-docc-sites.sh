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

if (( $# != 4 )); then
    printf 'usage: %s OUTPUT_PATH CONTAINER_PATH CONTAINERIZATION_PATH CONTAINER_K8S_PATH\n' "$0" >&2
    exit 2
fi

output_path="$(cd "$1" && pwd -P)"
container_path="$2"
containerization_path="$3"
container_k8s_path="$4"
hosting_base_path="container-compose"

# Writes the small static-hosting entry point expected by each DocC site.
write_index() {
    local site_path="$1"

    printf '{}\n' > "$site_path/theme-settings.json"
    cat > "$site_path/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en-US">
  <head>
    <meta charset="utf-8">
    <title>Redirecting...</title>
    <meta http-equiv="refresh" content="0; url=./documentation/">
  </head>
  <body>
    <p>If you are not redirected automatically, <a href="./documentation/">click here</a>.</p>
  </body>
</html>
EOF
}

# Builds one upstream Swift package into a site nested below the portal.
build_swift_package_docs() {
    local repository_path="$1"
    local site_name="$2"
    local site_path="$output_path/$site_name"

    mkdir -p "$site_path"
    (
        cd "$repository_path"
        scripts/make-docs.sh "$site_path" "$hosting_base_path/$site_name"
    )
}

build_swift_package_docs "$container_path" "container"
build_swift_package_docs "$containerization_path" "containerization"

k8s_site_path="$output_path/k8s"
mkdir -p "$k8s_site_path"
(
    cd "$container_k8s_path"
    /usr/bin/swift package \
        --disable-automatic-resolution \
        --allow-writing-to-directory "$k8s_site_path" \
        generate-documentation \
        --target K8sCore \
        --target K8sPlugin \
        --output-path "$k8s_site_path" \
        --disable-indexing \
        --transform-for-static-hosting \
        --enable-experimental-combined-documentation \
        --hosting-base-path "$hosting_base_path/k8s" \
        --source-service github \
        --source-service-base-url "https://github.com/stephenlclarke/container-k8s/blob/main" \
        --checkout-path "$container_k8s_path"
)
write_index "$k8s_site_path"
