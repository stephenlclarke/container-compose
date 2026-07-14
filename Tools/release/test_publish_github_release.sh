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

cat > "${temporary_directory}/bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" >> "${MOCK_GIT_CALLS}"
EOF
chmod +x "${temporary_directory}/bin/git"

asset="${temporary_directory}/container-compose-plugin-release-arm64.tar.gz"
checksum="${asset}.sha256"
notes="${temporary_directory}/notes.md"
touch "${asset}" "${checksum}" "${notes}"

# Run the publisher with a temporary, recorded GitHub CLI implementation.
run_publisher() {
  local ref_type="$1" release_tag release_title release_latest release_prerelease release_mutable
  local release_phase="${5:-publish}"
  if [[ "${ref_type}" == "branch" ]]; then
    release_tag="current"
    release_title="Current build"
    release_latest="false"
    release_prerelease="true"
    release_mutable="true"
  else
    release_tag="1.2.3"
    release_title="1.2.3"
    release_latest="true"
    release_prerelease="false"
    release_mutable="false"
  fi

  GH="${temporary_directory}/bin/gh" \
    GIT="${temporary_directory}/bin/git" \
    RELEASE_REPOSITORY="stephenlclarke/container-compose" \
    RELEASE_TAG="${release_tag}" \
    RELEASE_TITLE="${release_title}" \
    RELEASE_NOTES_FILE="${notes}" \
    RELEASE_LATEST="${release_latest}" \
    RELEASE_PRERELEASE="${release_prerelease}" \
    RELEASE_MUTABLE="${release_mutable}" \
    RELEASE_PHASE="${release_phase}" \
    PUBLISH_REF_TYPE="${ref_type}" \
    PUBLISH_SHA="0123456789012345678901234567890123456789" \
    RELEASE_ASSET_PATH="${asset}" \
    RELEASE_CHECKSUM_PATH="${checksum}" \
    RELEASE_EXTRA_ASSETS_FILE="${4:-}" \
    MOCK_RELEASE_STATE="$2" \
    MOCK_GH_CALLS="$3" \
    MOCK_GIT_CALLS="${3}.git" \
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
grep -Fqx "release create 1.2.3 ${asset} ${checksum} --repo stephenlclarke/container-compose --title 1.2.3 --notes-file ${notes} --verify-tag --latest" "${stable_create_calls}"
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

main_implicit_calls="${temporary_directory}/main-implicit.calls"
if run_publisher branch exists "${main_implicit_calls}"; then
  printf 'current publication unexpectedly accepted an implicit phase\n' >&2
  exit 1
fi

main_stage_calls="${temporary_directory}/main-stage.calls"
run_publisher branch exists "${main_stage_calls}" "" stage
grep -Fqx "release upload current ${asset} ${checksum} --repo stephenlclarke/container-compose --clobber" "${main_stage_calls}"
if [[ -e "${main_stage_calls}.git" ]] || grep -Eq 'release (create|edit|delete)' "${main_stage_calls}"; then
  printf 'current staging changed a release identity instead of only uploading assets\n' >&2
  exit 1
fi

main_finalize_calls="${temporary_directory}/main-finalize.calls"
run_publisher branch exists "${main_finalize_calls}" "" finalize
grep -Fqx "tag --no-sign --force current 0123456789012345678901234567890123456789" "${main_finalize_calls}.git"
grep -Fqx "push --force origin refs/tags/current" "${main_finalize_calls}.git"
grep -Fqx "release edit current --repo stephenlclarke/container-compose --title Current build --notes-file ${notes} --target 0123456789012345678901234567890123456789 --prerelease" "${main_finalize_calls}"
if grep -Eq 'release (create|upload|delete)' "${main_finalize_calls}"; then
  printf 'current finalization unexpectedly changed release assets\n' >&2
  exit 1
fi

main_create_calls="${temporary_directory}/main-create.calls"
run_publisher branch missing "${main_create_calls}" "" stage
grep -Fqx "release create current ${asset} ${checksum} --repo stephenlclarke/container-compose --title Current build --notes-file ${notes} --verify-tag --prerelease --latest=false" "${main_create_calls}"
grep -Fqx "tag --no-sign --force current 0123456789012345678901234567890123456789" "${main_create_calls}.git"
grep -Fqx "push --force origin refs/tags/current" "${main_create_calls}.git"

main_missing_finalize_calls="${temporary_directory}/main-missing-finalize.calls"
if run_publisher branch missing "${main_missing_finalize_calls}" "" finalize; then
  printf 'current finalization unexpectedly created a missing release\n' >&2
  exit 1
fi
if [[ -e "${main_missing_finalize_calls}" || -e "${main_missing_finalize_calls}.git" ]]; then
  printf 'current finalization mutated a missing release\n' >&2
  exit 1
fi

runtime_asset="${temporary_directory}/container-release-arm64.tar.gz"
runtime_checksum="${runtime_asset}.sha256"
extra_assets="${temporary_directory}/extra-assets"
touch "${runtime_asset}" "${runtime_checksum}"
printf '%s\n%s\n' "${runtime_asset}" "${runtime_checksum}" > "${extra_assets}"
stable_extra_calls="${temporary_directory}/stable-extra.calls"
run_publisher tag missing "${stable_extra_calls}" "${extra_assets}"
grep -Fqx "release create 1.2.3 ${asset} ${checksum} ${runtime_asset} ${runtime_checksum} --repo stephenlclarke/container-compose --title 1.2.3 --notes-file ${notes} --verify-tag --latest" "${stable_extra_calls}"

current_extra_calls="${temporary_directory}/current-extra.calls"
run_publisher branch exists "${current_extra_calls}" "${extra_assets}" stage
grep -Fqx "release upload current ${asset} ${checksum} ${runtime_asset} ${runtime_checksum} --repo stephenlclarke/container-compose --clobber" "${current_extra_calls}"
