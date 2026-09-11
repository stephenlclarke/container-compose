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
  if [[ " $* " == *" --silent "* ]]; then
    printf 'release lookup must preserve the response body\n' >&2
    exit 64
  fi
  if [[ "$2" == */releases/latest ]]; then
    printf '%s\n' "${MOCK_LATEST_TAG:-1.2.3}"
    exit 0
  fi
  case "${MOCK_RELEASE_STATE}" in
    exists)
      exit 0
      ;;
    draft)
      printf '{"draft":true,"name":"Foreign title","body":"foreign notes","prerelease":true}\n'
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

if [[ "$1" == "release" && "$2" == "view" ]]; then
  view_count=0
  if [[ -f "${MOCK_VIEW_COUNT_FILE}" ]]; then
    view_count="$(<"${MOCK_VIEW_COUNT_FILE}")"
  fi
  view_count=$((view_count + 1))
  printf '%s\n' "${view_count}" > "${MOCK_VIEW_COUNT_FILE}"
  if (( view_count == 2 )) && [[ -n "${MOCK_RACE_ASSET:-}" ]]; then
    printf '%s\n' "${MOCK_RACE_ASSET}" >> "${MOCK_REMOTE_STATE}"
  fi
  if (( view_count == 4 )) && [[ -n "${MOCK_POST_PUBLISH_RACE_ASSET:-}" ]]; then
    printf '%s\n' "${MOCK_POST_PUBLISH_RACE_ASSET}" >> "${MOCK_REMOTE_STATE}"
  fi
  if [[ " $* " == *"isDraft"* ]]; then
    digest="$(printf '%s' "${MOCK_DOWNLOAD_CONTENT:-}" | shasum -a 256 | awk '{print $1}')"
    if [[ "${MOCK_RELEASE_STATE}" == "exists" ]] || (( view_count >= 4 )); then
      draft=false
    else
      draft="${MOCK_FINAL_DRAFT_STATE:-true}"
    fi
    printf '{"isDraft":%s,"isImmutable":%s,"isPrerelease":false,"tagName":"1.2.3","targetCommitish":"0123456789012345678901234567890123456789","name":"%s","body":"%s","assets":[' \
      "${draft}" "${MOCK_PUBLISHED_IMMUTABLE:-true}" \
      "${MOCK_PUBLISHED_NAME:-1.2.3}" "${MOCK_PUBLISHED_BODY:-}"
    separator=""
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      if [[ -n "${MOCK_FINAL_DIGEST_MISMATCH:-}" && \
        "${name}" == "${MOCK_FINAL_DIGEST_MISMATCH}" ]]; then
        asset_digest="$(printf '%064d' 0)"
      else
        asset_digest="${digest}"
      fi
      printf '%s' "${separator}"
      jq -cn --arg name "${name}" --arg digest "sha256:${asset_digest}" \
        '{name: $name, digest: $digest}'
      separator=,
    done < "${MOCK_REMOTE_STATE}"
    printf ']}\n'
  else
    cat "${MOCK_REMOTE_STATE}"
  fi
  exit 0
fi

if [[ "$1" == "release" && "$2" == "download" ]]; then
  while (( $# > 0 )); do
    case "$1" in
      --pattern)
        pattern="$2"
        shift 2
        ;;
      --dir)
        directory="$2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  printf '%s' "${MOCK_DOWNLOAD_CONTENT:-}" > "${directory}/${pattern}"
  exit 0
fi

if [[ "$1" == "release" && "$2" == "upload" ]]; then
  basename "$4" >> "${MOCK_REMOTE_STATE}"
fi

printf '%s\n' "$*" >> "${MOCK_GH_CALLS}"
EOF
chmod +x "${temporary_directory}/bin/gh"

cat > "${temporary_directory}/bin/git" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" >> "${MOCK_GIT_CALLS}"
if [[ "$1" == rev-list ]]; then
  printf '0123456789012345678901234567890123456789\n'
fi
if [[ "$1" == ls-remote ]]; then
  printf '%s\trefs/tags/1.2.3\n' \
    "${MOCK_REMOTE_TAG_SHA:-0123456789012345678901234567890123456789}"
fi
EOF
chmod +x "${temporary_directory}/bin/git"

asset="${temporary_directory}/container-compose-plugin-release-arm64.tar.gz"
checksum="${asset}.sha256"
notes="${temporary_directory}/notes.md"
retained_manifest="${temporary_directory}/retained-complete.json"
touch "${asset}" "${checksum}" "${notes}" "${retained_manifest}"

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
  printf '%s' "${6:-}" > "${3}.remote"
  printf '0\n' > "${3}.views"

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
    RELEASE_RETAINED_COMPLETE_MANIFEST="${retained_manifest}" \
    RELEASE_EXTRA_ASSETS_FILE="${4:-}" \
    MOCK_RELEASE_STATE="$2" \
    MOCK_REMOTE_ASSETS="${6:-}" \
    MOCK_DOWNLOAD_CONTENT="${7:-}" \
    MOCK_RACE_ASSET="${8:-}" \
    MOCK_FINAL_DIGEST_MISMATCH="${9:-}" \
    MOCK_FINAL_DRAFT_STATE="${10:-true}" \
    MOCK_POST_PUBLISH_RACE_ASSET="${11:-}" \
    MOCK_PUBLISHED_IMMUTABLE="${12:-true}" \
    MOCK_PUBLISHED_NAME="${13:-1.2.3}" \
    MOCK_PUBLISHED_BODY="${14:-}" \
    MOCK_LATEST_TAG="${15:-1.2.3}" \
    MOCK_REMOTE_TAG_SHA="${16:-0123456789012345678901234567890123456789}" \
    MOCK_REMOTE_STATE="${3}.remote" \
    MOCK_VIEW_COUNT_FILE="${3}.views" \
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

stable_existing_exact_calls="${temporary_directory}/stable-existing-exact.calls"
run_publisher tag exists "${stable_existing_exact_calls}" "" publish \
  $'container-compose-plugin-release-arm64.tar.gz\ncontainer-compose-plugin-release-arm64.tar.gz.sha256\n'
if [[ -e "${stable_existing_exact_calls}" ]] && \
  grep -Eq 'release (upload|edit|create|delete)' "${stable_existing_exact_calls}"; then
  printf 'exact published stable recovery performed a mutation\n' >&2
  exit 1
fi

stable_create_calls="${temporary_directory}/stable-create.calls"
run_publisher tag missing "${stable_create_calls}"
grep -Fqx "release create 1.2.3 --repo stephenlclarke/container-compose --title 1.2.3 --notes-file ${notes} --target 0123456789012345678901234567890123456789 --verify-tag --latest --draft" "${stable_create_calls}"
grep -Fqx "release upload 1.2.3 ${asset} --repo stephenlclarke/container-compose" "${stable_create_calls}"
grep -Fqx "release upload 1.2.3 ${checksum} --repo stephenlclarke/container-compose" "${stable_create_calls}"
grep -Fqx "release edit 1.2.3 --repo stephenlclarke/container-compose --target 0123456789012345678901234567890123456789 --title 1.2.3 --notes-file ${notes} --draft=false --prerelease=false --latest" "${stable_create_calls}"
if grep -Eq 'clobber|release delete' "${stable_create_calls}"; then
  printf 'stable publication attempted to replace immutable state\n' >&2
  exit 1
fi

stable_draft_calls="${temporary_directory}/stable-draft.calls"
run_publisher tag draft "${stable_draft_calls}"
grep -Fqx "release upload 1.2.3 ${asset} --repo stephenlclarke/container-compose" "${stable_draft_calls}"
grep -Fqx "release upload 1.2.3 ${checksum} --repo stephenlclarke/container-compose" "${stable_draft_calls}"
grep -Fqx "release edit 1.2.3 --repo stephenlclarke/container-compose --target 0123456789012345678901234567890123456789 --title 1.2.3 --notes-file ${notes} --draft=false --prerelease=false --latest" "${stable_draft_calls}"
if grep -Eq 'release create|clobber|release delete' "${stable_draft_calls}"; then
  printf 'stable draft recovery recreated or clobbered release state\n' >&2
  exit 1
fi

stable_draft_unexpected_calls="${temporary_directory}/stable-draft-unexpected.calls"
if run_publisher tag draft "${stable_draft_unexpected_calls}" "" publish \
  $'container-vminit-arm64.oci.tar\ncontainer-vminit-arm64.oci.tar.sha256\n'; then
  printf 'stable draft recovery accepted an unexpected asset\n' >&2
  exit 1
fi
if [[ -e "${stable_draft_unexpected_calls}" ]] && \
  grep -Eq 'release (upload|edit|create|delete)' "${stable_draft_unexpected_calls}"; then
  printf 'stable draft recovery mutated a draft with an unexpected asset\n' >&2
  exit 1
fi

stable_draft_mismatch_calls="${temporary_directory}/stable-draft-mismatch.calls"
if run_publisher tag draft "${stable_draft_mismatch_calls}" "" publish \
  "$(basename "${asset}")" 'conflicting bytes'; then
  printf 'stable draft recovery accepted a mismatched asset\n' >&2
  exit 1
fi
if [[ -e "${stable_draft_mismatch_calls}" ]] && \
  grep -Eq 'release (upload|edit|create|delete)' "${stable_draft_mismatch_calls}"; then
  printf 'stable draft recovery mutated a draft with a mismatched asset\n' >&2
  exit 1
fi

stable_draft_late_mismatch_calls="${temporary_directory}/stable-draft-late-mismatch.calls"
if run_publisher tag draft "${stable_draft_late_mismatch_calls}" "" publish \
  "$(basename "${checksum}")" 'conflicting bytes'; then
  printf 'stable draft recovery accepted a later mismatched asset\n' >&2
  exit 1
fi
if [[ -e "${stable_draft_late_mismatch_calls}" ]] && \
  grep -Eq 'release (upload|edit|create|delete)' "${stable_draft_late_mismatch_calls}"; then
  printf 'stable draft recovery mutated before validating every existing asset\n' >&2
  exit 1
fi

stable_draft_race_calls="${temporary_directory}/stable-draft-race.calls"
if run_publisher tag draft "${stable_draft_race_calls}" "" publish \
  "" "" 'foreign-after-upload.tar.gz'; then
  printf 'stable draft recovery published after a concurrent inventory change\n' >&2
  exit 1
fi
if ! grep -Fq 'release upload' "${stable_draft_race_calls}" || \
  grep -Fq 'release edit' "${stable_draft_race_calls}"; then
  printf 'stable draft recovery did not block publication after the inventory race\n' >&2
  exit 1
fi

stable_draft_digest_race_calls="${temporary_directory}/stable-draft-digest-race.calls"
if run_publisher tag draft "${stable_draft_digest_race_calls}" "" publish \
  "" "" "" "$(basename "${asset}")"; then
  printf 'stable draft recovery published after a concurrent digest change\n' >&2
  exit 1
fi
if ! grep -Fq 'release upload' "${stable_draft_digest_race_calls}" || \
  grep -Fq 'release edit' "${stable_draft_digest_race_calls}"; then
  printf 'stable draft recovery did not block publication after the digest race\n' >&2
  exit 1
fi

stable_draft_published_race_calls="${temporary_directory}/stable-draft-published-race.calls"
if run_publisher tag draft "${stable_draft_published_race_calls}" "" publish \
  "" "" "" "" false; then
  printf 'stable draft recovery edited a concurrently published release\n' >&2
  exit 1
fi
if ! grep -Fq 'release upload' "${stable_draft_published_race_calls}" || \
  grep -Fq 'release edit' "${stable_draft_published_race_calls}"; then
  printf 'stable draft recovery did not stop after concurrent publication\n' >&2
  exit 1
fi

stable_post_publish_race_calls="${temporary_directory}/stable-post-publish-race.calls"
if run_publisher tag draft "${stable_post_publish_race_calls}" "" publish \
  "" "" "" "" true 'foreign-after-publication.tar.gz'; then
  printf 'stable publication accepted a changed immutable snapshot\n' >&2
  exit 1
fi
if ! grep -Fq 'release edit' "${stable_post_publish_race_calls}"; then
  printf 'stable publication did not exercise post-publication verification\n' >&2
  exit 1
fi

stable_mutable_publication_calls="${temporary_directory}/stable-mutable-publication.calls"
if run_publisher tag draft "${stable_mutable_publication_calls}" "" publish \
  "" "" "" "" true "" false; then
  printf 'stable publication accepted a mutable published release\n' >&2
  exit 1
fi

stable_metadata_drift_calls="${temporary_directory}/stable-metadata-drift.calls"
if run_publisher tag exists "${stable_metadata_drift_calls}" "" publish \
  $'container-compose-plugin-release-arm64.tar.gz\ncontainer-compose-plugin-release-arm64.tar.gz.sha256\n' \
  "" "" "" true "" true 'Foreign title'; then
  printf 'stable recovery accepted changed release metadata\n' >&2
  exit 1
fi

stable_latest_drift_calls="${temporary_directory}/stable-latest-drift.calls"
if run_publisher tag exists "${stable_latest_drift_calls}" "" publish \
  $'container-compose-plugin-release-arm64.tar.gz\ncontainer-compose-plugin-release-arm64.tar.gz.sha256\n' \
  "" "" "" true "" true 1.2.3 "" 1.2.2; then
  printf 'stable recovery accepted a changed latest-release pointer\n' >&2
  exit 1
fi

stable_tag_drift_calls="${temporary_directory}/stable-tag-drift.calls"
if run_publisher tag exists "${stable_tag_drift_calls}" "" publish \
  $'container-compose-plugin-release-arm64.tar.gz\ncontainer-compose-plugin-release-arm64.tar.gz.sha256\n' \
  "" "" "" true "" true 1.2.3 "" 1.2.3 \
  1111111111111111111111111111111111111111; then
  printf 'stable recovery accepted a retargeted published tag\n' >&2
  exit 1
fi
if ! grep -Fq 'release edit' "${stable_mutable_publication_calls}"; then
  printf 'stable immutable verification did not run after publication\n' >&2
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
grep -Fqx "release upload current ${asset} ${checksum} --repo stephenlclarke/container-compose --clobber" "${main_finalize_calls}"
grep -Fqx "release edit current --repo stephenlclarke/container-compose --target 0123456789012345678901234567890123456789 --title Current build --notes-file ${notes} --prerelease --latest=false" "${main_finalize_calls}"
if grep -Eq 'release (create|delete)' "${main_finalize_calls}" || grep -Fq -- '--cleanup-tag' "${main_finalize_calls}"; then
  printf 'current finalization replaced the release object or removed the current tag\n' >&2
  exit 1
fi

main_create_calls="${temporary_directory}/main-create.calls"
run_publisher branch missing "${main_create_calls}" "" stage
grep -Fqx "release create current ${asset} ${checksum} --repo stephenlclarke/container-compose --title Current build --notes-file ${notes} --verify-tag --prerelease --latest=false" "${main_create_calls}"
grep -Fqx "tag --no-sign --force current 0123456789012345678901234567890123456789" "${main_create_calls}.git"
grep -Fqx "push --force origin refs/tags/current" "${main_create_calls}.git"

main_missing_finalize_calls="${temporary_directory}/main-missing-finalize.calls"
run_publisher branch missing "${main_missing_finalize_calls}" "" finalize
grep -Fqx "release create current ${asset} ${checksum} --repo stephenlclarke/container-compose --title Current build --notes-file ${notes} --verify-tag --prerelease --latest=false" "${main_missing_finalize_calls}"
grep -Fqx "release edit current --repo stephenlclarke/container-compose --target 0123456789012345678901234567890123456789 --prerelease" "${main_missing_finalize_calls}"
grep -Fqx "tag --no-sign --force current 0123456789012345678901234567890123456789" "${main_missing_finalize_calls}.git"
grep -Fqx "push --force origin refs/tags/current" "${main_missing_finalize_calls}.git"

runtime_asset="${temporary_directory}/container-release-arm64.tar.gz"
runtime_checksum="${runtime_asset}.sha256"
extra_assets="${temporary_directory}/extra-assets"
touch "${runtime_asset}" "${runtime_checksum}"
printf '%s\n%s\n' "${runtime_asset}" "${runtime_checksum}" > "${extra_assets}"
stable_extra_calls="${temporary_directory}/stable-extra.calls"
run_publisher tag missing "${stable_extra_calls}" "${extra_assets}"
grep -Fqx "release upload 1.2.3 ${runtime_asset} --repo stephenlclarke/container-compose" "${stable_extra_calls}"
grep -Fqx "release upload 1.2.3 ${runtime_checksum} --repo stephenlclarke/container-compose" "${stable_extra_calls}"

current_extra_calls="${temporary_directory}/current-extra.calls"
run_publisher branch exists "${current_extra_calls}" "${extra_assets}" stage
grep -Fqx "release upload current ${asset} ${checksum} ${runtime_asset} ${runtime_checksum} --repo stephenlclarke/container-compose --clobber" "${current_extra_calls}"
