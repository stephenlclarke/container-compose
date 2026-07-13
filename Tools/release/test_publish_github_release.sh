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

set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
publisher="${root}/Tools/release/publish-github-release.sh"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "${temporary_directory}"' EXIT

mkdir -p "${temporary_directory}/bin"
cat > "${temporary_directory}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$1" == "api" ]]; then
  case "${MOCK_RELEASE_STATE}" in
    exists)
      exit 0
      ;;
    missing)
      printf 'gh: Not Found (HTTP 404)\n' >&2
      exit 1
      ;;
    unavailable)
      printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2
      exit 1
      ;;
  esac
  printf 'unknown mock release state: %s\n' "${MOCK_RELEASE_STATE}" >&2
  exit 2
fi

printf '%s\n' "$*" >> "${MOCK_GH_CALLS}"
EOF
chmod +x "${temporary_directory}/bin/gh"

asset="${temporary_directory}/container-compose-plugin-release-arm64.tar.gz"
checksum="${asset}.sha256"
notes="${temporary_directory}/notes.md"
touch "${asset}" "${checksum}" "${notes}"

# Run the publisher with a temporary, recorded GitHub CLI implementation.
run_publisher() {
  GH="${temporary_directory}/bin/gh" \
    RELEASE_REPOSITORY="stephenlclarke/container-compose" \
    RELEASE_TAG="1.2.3" \
    RELEASE_TITLE="1.2.3" \
    RELEASE_NOTES_FILE="${notes}" \
    RELEASE_LATEST="true" \
    RELEASE_PRERELEASE="false" \
    PUBLISH_REF_TYPE="$1" \
    PUBLISH_SHA="0123456789012345678901234567890123456789" \
    RELEASE_ASSET_PATH="${asset}" \
    RELEASE_CHECKSUM_PATH="${checksum}" \
    MOCK_RELEASE_STATE="$2" \
    MOCK_GH_CALLS="$3" \
    "${publisher}"
}

stable_existing_calls="${temporary_directory}/stable-existing.calls"
if run_publisher tag exists "${stable_existing_calls}"; then
  printf 'stable publication unexpectedly accepted an existing release\n' >&2
  exit 1
fi
if [[ -e "${stable_existing_calls}" ]]; then
  printf 'stable publication invoked a mutation for an existing release\n' >&2
  exit 1
fi

stable_create_calls="${temporary_directory}/stable-create.calls"
run_publisher tag missing "${stable_create_calls}"
grep -Fqx "release create 1.2.3 ${asset} ${checksum} --repo stephenlclarke/container-compose --verify-tag --title 1.2.3 --notes-file ${notes} --latest" "${stable_create_calls}"
if grep -Eq 'release (edit|upload)|clobber' "${stable_create_calls}"; then
  printf 'stable publication attempted a mutable release operation\n' >&2
  exit 1
fi

stable_unavailable_calls="${temporary_directory}/stable-unavailable.calls"
if run_publisher tag unavailable "${stable_unavailable_calls}"; then
  printf 'stable publication unexpectedly ignored a release lookup failure\n' >&2
  exit 1
fi
if [[ -e "${stable_unavailable_calls}" ]]; then
  printf 'stable publication invoked a mutation after a release lookup failure\n' >&2
  exit 1
fi

main_calls="${temporary_directory}/main.calls"
run_publisher branch exists "${main_calls}"
grep -Fqx "release edit 1.2.3 --repo stephenlclarke/container-compose --title 1.2.3 --notes-file ${notes} --latest" "${main_calls}"
grep -Fqx "release upload 1.2.3 ${asset} ${checksum} --repo stephenlclarke/container-compose --clobber" "${main_calls}"

main_create_calls="${temporary_directory}/main-create.calls"
run_publisher branch missing "${main_create_calls}"
grep -Fqx "release create 1.2.3 --repo stephenlclarke/container-compose --target 0123456789012345678901234567890123456789 --title 1.2.3 --notes-file ${notes} --latest" "${main_create_calls}"
grep -Fqx "release upload 1.2.3 ${asset} ${checksum} --repo stephenlclarke/container-compose --clobber" "${main_create_calls}"
