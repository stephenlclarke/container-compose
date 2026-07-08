#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  CONTAINER_STACK_RELEASE.sh plan
  CONTAINER_STACK_RELEASE.sh release VERSION_SELECTOR [--execute]
  CONTAINER_STACK_RELEASE.sh package VERSION [--execute]
  CONTAINER_STACK_RELEASE.sh tag-current [--execute]
  CONTAINER_STACK_RELEASE.sh start-dev VERSION_SELECTOR [--execute]

Purpose:
  Coordinate the simplified Stephen-owned container stack release flow without
  touching Apple upstream repositories.

Modes:
  plan
      Inspect the four local main branches and print the release/dev-slice
      plan. This mode never mutates repositories.

  release VERSION_SELECTOR
      Deterministically promote the current four-repo stack to the next stable
      release. The version selector is resolved from the latest local semantic
      container-compose tag, not from mutable working-tree state. The helper
      bumps container-compose on main when needed, commits that bump, pushes all
      Stephen-owned main branches, creates the stable container-compose source
      tag, pushes that tag, dispatches the stable package workflow, and waits
      for that workflow to publish the release assets and Homebrew tap update.

  package VERSION
      Re-run the stable package workflow for an existing semantic source tag,
      then verify the release archive, checksum asset, and Homebrew formula
      URL/SHA without moving any tags.

  tag-current
      Tag the current validated container-compose main state as the latest
      stable release using the current COMPOSE_VERSION value, then dispatch and
      wait for the stable package workflow.

  start-dev VERSION_SELECTOR
      First tag the current container-compose main state as the latest stable release, then
      create a short-lived develop/VERSION branch from main in container-compose,
      bump COMPOSE_VERSION to VERSION, update local version expectations, commit
      the bump, and push the branch. CI for that branch should publish an
      immutable VERSION-pre.RUN.SHA pre-release/dev slice.

      Version selectors:
        9.0.2  use the explicit 9.0.2 next development version
        --+    increment patch from the current COMPOSE_VERSION
        -+-    increment minor and reset patch to 0
        +--    increment major and reset minor and patch to 0

      Source tags are bare MAJOR.MINOR.PATCH for Apple compatibility.

Options:
  --execute
      Run mutating git commands. Without this flag the script is a dry run.

Repository layout expected:
  ~/github/container-builder-shim
  ~/github/containerization
  ~/github/container
  ~/github/container-compose

Rules enforced:
  - Apple remotes are read-only and must not be push targets.
  - Stephen-owned remotes are the only push targets.
  - Worktrees must be clean before release or dev-slice changes.
  - Stable container-compose release tags point at current main before the next dev version bump.
  - Stable package and Homebrew tap updates are explicitly dispatched and waited for.
  - Stable package assets and the Homebrew tap SHA are verified before success.
  - Existing tags are never moved.
  - Long-lived release branches are not used.
USAGE
}

MODE="${1:-}"
if [[ -z "${MODE}" || "${MODE}" == "-h" || "${MODE}" == "--help" ]]; then
  usage
  exit 0
fi
shift || true

VERSION_SELECTOR=""
EXECUTE=0
case "${MODE}" in
  plan|tag-current)
    ;;
  release|package|start-dev)
    VERSION_SELECTOR="${1:-}"
    if [[ -z "${VERSION_SELECTOR}" ]]; then
      if [[ "${MODE}" == "package" ]]; then
        printf '%s requires VERSION, for example 9.0.2\n' "${MODE}" >&2
      else
        printf '%s requires VERSION_SELECTOR, for example --+, -+-, +--, or 9.0.2\n' "${MODE}" >&2
      fi
      exit 2
    fi
    shift || true
    ;;
  *)
    printf 'unknown mode: %s\n' "${MODE}" >&2
    usage >&2
    exit 2
    ;;
esac

while (($#)); do
  case "$1" in
    --execute)
      EXECUTE=1
      shift
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

ROOT="${HOME}/github"
COMPOSE_REPO="container-compose"
CONTAINER_REPO="container"
RELEASE_WAIT_SECONDS="${CONTAINER_STACK_RELEASE_WAIT_SECONDS:-3600}"
RELEASE_POLL_SECONDS="${CONTAINER_STACK_RELEASE_POLL_SECONDS:-30}"
COMPOSE_PACKAGE_WAIT_SECONDS="${CONTAINER_STACK_COMPOSE_PACKAGE_WAIT_SECONDS:-3600}"
COMPOSE_PACKAGE_POLL_SECONDS="${CONTAINER_STACK_COMPOSE_PACKAGE_POLL_SECONDS:-30}"
REPOS=(
  "container-builder-shim"
  "containerization"
  "container"
  "container-compose"
)

# Map local checkout names to their Stephen-owned GitHub repositories.
github_repo() {
  case "$1" in
    container-builder-shim) printf 'stephenlclarke/container-builder-shim' ;;
    containerization) printf 'stephenlclarke/containerization' ;;
    container) printf 'stephenlclarke/container' ;;
    container-compose) printf 'stephenlclarke/container-compose' ;;
  esac
}

# Return the writable Stephen-owned remote for each checkout.
push_remote() {
  case "$1" in
    container|container-builder-shim) printf 'fork' ;;
    *) printf 'origin' ;;
  esac
}

# Print and optionally execute a command.
run() {
  if [[ "${EXECUTE}" == "1" ]]; then
    printf '+ %s\n' "$*"
    "$@"
  else
    printf 'would run: %s\n' "$*"
  fi
}

stephen_https_url() {
  local url="$1"
  case "${url}" in
    git@github.com:stephenlclarke/*)
      printf 'https://github.com/stephenlclarke/%s\n' "${url#git@github.com:stephenlclarke/}"
      ;;
    *)
      return 1
      ;;
  esac
}

fetch_release_remote() {
  local repo="$1" path remote url fallback_url
  path="$(repo_path "${repo}")"
  remote="$(push_remote "${repo}")"
  url="$(git -C "${path}" remote get-url "${remote}")"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would run: git -C %s fetch --prune --no-tags %s\n' "${path}" "${remote}"
    return 0
  fi

  if fallback_url="$(stephen_https_url "${url}")"; then
    printf 'normalizing %s release remote for %s from %s to %s\n' "${remote}" "${repo}" "${url}" "${fallback_url}" >&2
    git -C "${path}" remote set-url "${remote}" "${fallback_url}"
    url="${fallback_url}"
  fi

  printf '+ git -C %s fetch --prune --no-tags %s\n' "${path}" "${remote}"
  if git -C "${path}" fetch --prune --no-tags "${remote}"; then
    return 0
  fi

  if fallback_url="$(stephen_https_url "${url}")"; then
    printf 'fetch from %s failed for %s; switching %s to %s and retrying\n' "${url}" "${repo}" "${remote}" "${fallback_url}" >&2
    git -C "${path}" remote set-url "${remote}" "${fallback_url}"
    printf '+ git -C %s fetch --prune --no-tags %s\n' "${path}" "${remote}"
    git -C "${path}" fetch --prune --no-tags "${remote}"
    return 0
  fi

  return 1
}

# Return an absolute checkout path.
repo_path() {
  printf '%s/%s' "${ROOT}" "$1"
}

# Emit a visible section header.
print_header() {
  printf '\n== %s ==\n' "$1"
}

# Verify that a checkout exists.
ensure_repo_exists() {
  local repo="$1" path
  path="$(repo_path "${repo}")"
  if [[ ! -d "${path}/.git" ]]; then
    printf 'missing checkout: %s\n' "${path}" >&2
    exit 1
  fi
}

# Refuse to operate on dirty working trees.
ensure_clean() {
  local repo="$1" path status
  path="$(repo_path "${repo}")"
  status="$(git -C "${path}" status --short)"
  if [[ -n "${status}" ]]; then
    printf 'dirty worktree blocks release for %s:\n%s\n' "${repo}" "${status}" >&2
    exit 1
  fi
}

# Verify that Apple remotes cannot be pushed and Stephen remotes are the target.
ensure_push_boundary() {
  local repo="$1" path remote url remote_name push_url
  path="$(repo_path "${repo}")"
  remote="$(push_remote "${repo}")"
  url="$(git -C "${path}" remote get-url "${remote}")"
  case "${url}" in
    *github.com/stephenlclarke/*|git@github.com:stephenlclarke/*)
      ;;
    *)
      printf 'push remote for %s is not Stephen-owned: %s %s\n' "${repo}" "${remote}" "${url}" >&2
      exit 1
      ;;
  esac

  while read -r remote_name; do
    while read -r push_url; do
      case "${push_url}" in
        no_push)
          ;;
        *github.com/apple/*|git@github.com:apple/*)
          printf 'remote %s push URL for %s targets Apple; refusing: %s\n' "${remote_name}" "${repo}" "${push_url}" >&2
          exit 1
          ;;
      esac
    done < <(git -C "${path}" remote get-url --push --all "${remote_name}" 2>/dev/null || true)
  done < <(git -C "${path}" remote)

  if [[ "${repo}" == "container" || "${repo}" == "container-builder-shim" ]]; then
    if ! git -C "${path}" remote get-url --push origin 2>/dev/null | grep -qx 'no_push'; then
      printf '%s origin must keep push URL no_push\n' "${repo}" >&2
      exit 1
    fi
  fi
  if [[ "${repo}" == "containerization" ]] && git -C "${path}" remote get-url upstream >/dev/null 2>&1; then
    if ! git -C "${path}" remote get-url --push upstream 2>/dev/null | grep -qx 'no_push'; then
      printf 'containerization upstream must keep push URL no_push\n' >&2
      exit 1
    fi
  fi
}

# Fetch and align the local main branch.
prepare_repo_main() {
  local repo="$1" path remote
  path="$(repo_path "${repo}")"
  remote="$(push_remote "${repo}")"
  ensure_repo_exists "${repo}"
  ensure_clean "${repo}"
  ensure_push_boundary "${repo}"
  fetch_release_remote "${repo}"
  run git -C "${path}" switch main
  run git -C "${path}" pull --rebase --autostash "${remote}" main
  ensure_clean "${repo}"
}

# Prepare every stack participant in release order.
prepare_all_main() {
  local repo
  for repo in "${REPOS[@]}"; do
    prepare_repo_main "${repo}"
  done
}

# Read the compose plugin version from the Makefile.
current_compose_version() {
  sed -n 's/^COMPOSE_VERSION ?= //p' "$(repo_path "${COMPOSE_REPO}")/Makefile" | head -n 1
}

# Resolve an explicit or symbolic version relative to a semantic base version.
resolve_version_selector() {
  local selector="$1" base="$2" major minor patch plus_count
  if [[ ! "${base}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    printf 'base version is not semantic: %s\n' "${base}" >&2
    exit 1
  fi

  if [[ "${selector}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    printf '%s' "${selector}"
    return 0
  fi

  if [[ "${selector}" =~ ^[+-][+-][+-]$ ]]; then
    plus_count="${selector//[^+]}"
    if [[ "${#plus_count}" != "1" ]]; then
      printf 'increment selector must contain exactly one +: %s\n' "${selector}" >&2
      exit 2
    fi
    IFS=. read -r major minor patch <<<"${base}"
    case "${selector}" in
      +--)
        ((major += 1))
        minor=0
        patch=0
        ;;
      -+-)
        ((minor += 1))
        patch=0
        ;;
      --+)
        ((patch += 1))
        ;;
    esac
    printf '%s.%s.%s' "${major}" "${minor}" "${patch}"
    return 0
  fi

  printf 'invalid version selector: %s\n' "${selector}" >&2
  printf 'expected MAJOR.MINOR.PATCH, --+, -+-, or +--\n' >&2
  exit 2
}

# Resolve an explicit or symbolic next development version.
resolve_next_version() {
  resolve_version_selector "$1" "$(current_compose_version)"
}

# Resolve the release version from the latest semantic tag, not mutable files.
resolve_release_version() {
  local latest
  latest="$(latest_local_semver_tag "${COMPOSE_REPO}")"
  if [[ -z "${latest}" ]]; then
    latest="$(current_compose_version)"
  fi
  resolve_version_selector "$1" "${latest}"
}

# Require an exact semantic version.
ensure_semver_version() {
  local version="$1"
  if [[ ! "${version}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    printf 'version must be MAJOR.MINOR.PATCH: %s\n' "${version}" >&2
    exit 2
  fi
}

# Ensure a target version is newer than the current compose version.
ensure_next_version_increases() {
  local current="$1" next="$2"
  python3 - "$current" "$next" <<'PY'
import sys
current = tuple(int(part) for part in sys.argv[1].split("."))
next_version = tuple(int(part) for part in sys.argv[2].split("."))
if next_version <= current:
    raise SystemExit(f"next development version {sys.argv[2]} must be greater than current stable {sys.argv[1]}")
PY
}

ensure_release_version_is_valid() {
  local latest="$1" current="$2" version="$3"
  python3 - "$latest" "$current" "$version" <<'PY'
import sys

def parse(value):
    return tuple(int(part) for part in value.split("."))

latest, current, version = map(parse, sys.argv[1:])
if version <= latest:
    raise SystemExit(
        f"release version {sys.argv[3]} must be newer than latest release tag {sys.argv[1]}"
    )
if current > version:
    raise SystemExit(
        f"COMPOSE_VERSION {sys.argv[2]} is newer than requested release {sys.argv[3]}"
    )
PY
}

# Return the latest local semantic tag for a repo, if one exists.
latest_local_semver_tag() {
  local repo="$1"
  git -C "$(repo_path "${repo}")" tag --list '[0-9]*.[0-9]*.[0-9]*' \
    | python3 -c 'import re, sys
versions = [line.strip() for line in sys.stdin if re.fullmatch(r"[0-9]+[.][0-9]+[.][0-9]+", line.strip())]
versions.sort(key=lambda version: tuple(int(part) for part in version.split(".")))
print(versions[-1] if versions else "")
'
}

# Decide whether a repository changed since its latest local semver tag.
repo_changed_since_latest_tag() {
  local repo="$1" latest main_commit tag_commit
  latest="$(latest_local_semver_tag "${repo}")"
  if [[ -z "${latest}" ]]; then
    return 0
  fi
  main_commit="$(git -C "$(repo_path "${repo}")" rev-parse main)"
  tag_commit="$(git -C "$(repo_path "${repo}")" rev-list -n 1 "${latest}")"
  [[ "${main_commit}" != "${tag_commit}" ]]
}

# Create a stable tag for a repo when needed, never moving existing tags.
tag_repo_main_if_needed() {
  local repo="$1" version="$2" path remote main_commit latest latest_commit
  path="$(repo_path "${repo}")"
  remote="$(push_remote "${repo}")"
  main_commit="$(git -C "${path}" rev-parse main)"

  if git -C "${path}" rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
    latest_commit="$(git -C "${path}" rev-list -n 1 "${version}")"
    if [[ "${latest_commit}" != "${main_commit}" ]]; then
      printf 'tag %s already exists for %s at %s; refusing to move it to %s\n' "${version}" "${repo}" "${latest_commit}" "${main_commit}" >&2
      exit 1
    fi
    printf '%s already has tag %s at current main\n' "${repo}" "${version}"
    return 0
  fi

  if git -C "${path}" ls-remote --exit-code --tags "${remote}" "refs/tags/${version}" >/dev/null 2>&1; then
    printf 'tag %s already exists remotely for %s; fetch and verify before proceeding\n' "${version}" "${repo}" >&2
    exit 1
  fi

  latest="$(latest_local_semver_tag "${repo}")"
  if [[ -n "${latest}" ]]; then
    latest_commit="$(git -C "${path}" rev-list -n 1 "${latest}")"
    if [[ "${latest_commit}" == "${main_commit}" ]]; then
      printf '%s unchanged since tag %s; release manifest should reuse that artifact\n' "${repo}" "${latest}"
      return 0
    fi
  fi

  run git -C "${path}" tag -a "${version}" main -m "$(github_repo "${repo}") ${version}"
  run git -C "${path}" push "${remote}" "refs/tags/${version}"
}

print_component_refs() {
  local repo path
  printf '\nComponent refs recorded by package metadata or companion release processes:\n'
  for repo in "${REPOS[@]}"; do
    path="$(repo_path "${repo}")"
    printf '  %-26s %s\n' "${repo}" "$(git -C "${path}" rev-parse main)"
  done
}

push_all_main() {
  local repo path remote
  print_header "push Stephen-owned main branches"
  for repo in "${REPOS[@]}"; do
    path="$(repo_path "${repo}")"
    remote="$(push_remote "${repo}")"
    run git -C "${path}" push "${remote}" "refs/heads/main"
  done
}

container_homebrew_tag_for_sha() {
  local sha="$1" path remote
  path="$(repo_path "${CONTAINER_REPO}")"
  remote="$(push_remote "${CONTAINER_REPO}")"
  git -C "${path}" ls-remote --tags --refs "${remote}" "refs/tags/homebrew-main-*" \
    | awk -v sha="${sha}" '$1 == sha { sub("^refs/tags/", "", $2); print $2; exit }'
}

wait_for_container_homebrew_package() {
  local sha tag deadline now
  sha="$(git -C "$(repo_path "${CONTAINER_REPO}")" rev-parse main)"
  print_header "wait for container main package"
  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would wait for stephenlclarke/container homebrew-main-* tag at %s\n' "${sha}"
    return 0
  fi

  deadline=$((SECONDS + RELEASE_WAIT_SECONDS))
  while true; do
    tag="$(container_homebrew_tag_for_sha "${sha}")"
    if [[ -n "${tag}" ]]; then
      printf 'container package tag ready: %s -> %s\n' "${tag}" "${sha}"
      return 0
    fi

    now="${SECONDS}"
    if (( now >= deadline )); then
      printf 'timed out waiting for stephenlclarke/container homebrew-main-* tag at %s\n' "${sha}" >&2
      printf 'check the container Prebuilt Binaries workflow before tagging container-compose\n' >&2
      exit 1
    fi

    printf 'waiting for container package tag at %s; next check in %ss\n' "${sha}" "${RELEASE_POLL_SECONDS}"
    sleep "${RELEASE_POLL_SECONDS}"
  done
}

# Require an executable command when an executed workflow depends on it.
need_command() {
  local command_name="$1"
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'required command not found: %s\n' "${command_name}" >&2
    exit 1
  fi
}

# Return the newest workflow_dispatch run id for the compose package workflow.
latest_compose_package_dispatch_run() {
  env -u GITHUB_TOKEN -u GH_TOKEN gh run list \
    --repo "$(github_repo "${COMPOSE_REPO}")" \
    --workflow "Prebuilt Binaries" \
    --event workflow_dispatch \
    --limit 1 \
    --json databaseId \
    --jq '.[0].databaseId // ""'
}

# Wait for a GitHub Actions run to complete successfully.
wait_for_github_run_success() {
  local run_id="$1" status conclusion url deadline now details
  deadline=$((SECONDS + COMPOSE_PACKAGE_WAIT_SECONDS))
  while true; do
    details="$(
      env -u GITHUB_TOKEN -u GH_TOKEN gh run view "${run_id}" \
        --repo "$(github_repo "${COMPOSE_REPO}")" \
        --json status,conclusion,url \
        --jq '[.status, (.conclusion // ""), .url] | @tsv'
    )"
    IFS=$'\t' read -r status conclusion url <<<"${details}"

    if [[ "${status}" == "completed" ]]; then
      if [[ "${conclusion}" == "success" ]]; then
        printf 'container-compose package workflow passed: %s\n' "${url}"
        return 0
      fi
      printf 'container-compose package workflow ended with %s: %s\n' "${conclusion}" "${url}" >&2
      exit 1
    fi

    now="${SECONDS}"
    if (( now >= deadline )); then
      printf 'timed out waiting for container-compose package workflow %s: %s\n' "${run_id}" "${url}" >&2
      exit 1
    fi

    printf 'waiting for container-compose package workflow %s (%s); next check in %ss\n' \
      "${run_id}" "${status}" "${COMPOSE_PACKAGE_POLL_SECONDS}"
    sleep "${COMPOSE_PACKAGE_POLL_SECONDS}"
  done
}

# Verify the stable release assets and Homebrew formula agree.
verify_compose_stable_package() {
  local version="$1" repo asset expected_url tmp asset_names asset_sha checksum_sha formula_text formula_url formula_version formula_sha
  repo="$(github_repo "${COMPOSE_REPO}")"
  asset="container-compose-plugin-release-arm64.tar.gz"
  expected_url="https://github.com/${repo}/releases/download/${version}/${asset}"
  print_header "verify container-compose ${version} package"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would verify GitHub release assets and stephenlclarke/tap/container-compose for %s\n' "${version}"
    return 0
  fi

  tmp="$(mktemp -d)"
  asset_names="$(
    env -u GITHUB_TOKEN -u GH_TOKEN gh release view "${version}" \
      --repo "${repo}" \
      --json assets \
      --jq '.assets[].name'
  )"
  if ! grep -Fxq "${asset}" <<<"${asset_names}"; then
    printf 'release %s is missing asset %s\n' "${version}" "${asset}" >&2
    exit 1
  fi
  if ! grep -Fxq "${asset}.sha256" <<<"${asset_names}"; then
    printf 'release %s is missing asset %s.sha256\n' "${version}" "${asset}" >&2
    exit 1
  fi

  env -u GITHUB_TOKEN -u GH_TOKEN gh release download "${version}" \
    --repo "${repo}" \
    --pattern "${asset}" \
    --pattern "${asset}.sha256" \
    --dir "${tmp}"
  asset_sha="$(shasum -a 256 "${tmp}/${asset}" | awk '{print $1}')"
  checksum_sha="$(awk '{print $1}' "${tmp}/${asset}.sha256")"
  rm -rf "${tmp}"
  if [[ "${asset_sha}" != "${checksum_sha}" ]]; then
    printf 'release %s checksum mismatch: asset %s, checksum file %s\n' \
      "${version}" "${asset_sha}" "${checksum_sha}" >&2
    exit 1
  fi

  formula_text="$(
    env -u GITHUB_TOKEN -u GH_TOKEN gh api \
      repos/stephenlclarke/homebrew-tap/contents/Formula/container-compose.rb \
      --jq '.content' | base64 --decode
  )"
  formula_url="$(sed -n 's/^  url "\(.*\)"/\1/p' <<<"${formula_text}" | head -n 1)"
  formula_version="$(sed -n 's/^  version "\(.*\)"/\1/p' <<<"${formula_text}" | head -n 1)"
  formula_sha="$(sed -n 's/^  sha256 "\(.*\)"/\1/p' <<<"${formula_text}" | head -n 1)"

  if [[ "${formula_url}" != "${expected_url}" ]]; then
    printf 'Homebrew formula URL mismatch: expected %s, got %s\n' "${expected_url}" "${formula_url}" >&2
    exit 1
  fi
  if [[ "${formula_version}" != "${version}" ]]; then
    printf 'Homebrew formula version mismatch: expected %s, got %s\n' "${version}" "${formula_version}" >&2
    exit 1
  fi
  if [[ "${formula_sha}" != "${asset_sha}" ]]; then
    printf 'Homebrew formula SHA mismatch: expected %s, got %s\n' "${asset_sha}" "${formula_sha}" >&2
    exit 1
  fi

  printf 'container-compose %s package verified: %s\n' "${version}" "${asset_sha}"
}

# Dispatch and wait for the stable compose package workflow for a semantic tag.
dispatch_compose_stable_package() {
  local version="$1" previous_run run_id deadline now
  print_header "dispatch container-compose ${version} package"

  if [[ "${EXECUTE}" != "1" ]]; then
    printf 'would run: gh workflow run prebuilt-binaries.yml --repo %s --ref main -f ref=%s\n' \
      "$(github_repo "${COMPOSE_REPO}")" "${version}"
    printf 'would wait for the container-compose stable package workflow to publish assets and update Homebrew\n'
    return 0
  fi

  need_command gh
  previous_run="$(latest_compose_package_dispatch_run || true)"
  run env -u GITHUB_TOKEN -u GH_TOKEN gh workflow run prebuilt-binaries.yml \
    --repo "$(github_repo "${COMPOSE_REPO}")" \
    --ref main \
    -f "ref=${version}"

  deadline=$((SECONDS + COMPOSE_PACKAGE_WAIT_SECONDS))
  while true; do
    run_id="$(latest_compose_package_dispatch_run || true)"
    if [[ -n "${run_id}" && "${run_id}" != "${previous_run}" ]]; then
      printf 'container-compose package workflow started: %s\n' "${run_id}"
      wait_for_github_run_success "${run_id}"
      verify_compose_stable_package "${version}"
      return 0
    fi

    now="${SECONDS}"
    if (( now >= deadline )); then
      printf 'timed out waiting for container-compose package workflow dispatch for %s\n' "${version}" >&2
      exit 1
    fi

    printf 'waiting for container-compose package workflow dispatch for %s; next check in %ss\n' \
      "${version}" "${COMPOSE_PACKAGE_POLL_SECONDS}"
    sleep "${COMPOSE_PACKAGE_POLL_SECONDS}"
  done
}

# Tag a compose state as the stable/latest release point.
tag_stable_version() {
  local version="$1"
  print_header "tag container-compose main as ${version} latest"
  tag_repo_main_if_needed "${COMPOSE_REPO}" "${version}"
  dispatch_compose_stable_package "${version}"
  print_component_refs
  cat <<EOF

Stable release point:
  version: ${version}
  label: latest
  release generation: container-compose stable package workflow dispatch
  tap update: stable container-compose formula after package artifacts are ready
EOF
}

# Tag the current compose state as the stable/latest release point.
tag_current_stable() {
  tag_stable_version "$(current_compose_version)"
}

# Rebuild and verify an existing stable package without moving its source tag.
package_existing_stable() {
  local version="$1" remote
  ensure_semver_version "${version}"
  remote="$(push_remote "${COMPOSE_REPO}")"

  print_header "package existing container-compose ${version} tag"
  if ! git -C "$(repo_path "${COMPOSE_REPO}")" ls-remote --exit-code --tags "${remote}" "refs/tags/${version}" >/dev/null 2>&1; then
    printf 'stable tag not found on %s: %s\n' "${remote}" "${version}" >&2
    exit 1
  fi

  dispatch_compose_stable_package "${version}"
}

release_current_stack() {
  local latest current version path
  latest="$(latest_local_semver_tag "${COMPOSE_REPO}")"
  if [[ -z "${latest}" ]]; then
    latest="$(current_compose_version)"
  fi
  current="$(current_compose_version)"
  version="$(resolve_release_version "${VERSION_SELECTOR}")"
  ensure_release_version_is_valid "${latest}" "${current}" "${version}"
  path="$(repo_path "${COMPOSE_REPO}")"

  print_header "prepare stable release ${version}"
  printf 'latest semantic tag: %s\n' "${latest}"
  printf 'current COMPOSE_VERSION: %s\n' "${current}"
  printf 'release version: %s\n' "${version}"

  if [[ "${current}" != "${version}" ]]; then
    if [[ "${EXECUTE}" == "1" ]]; then
      bump_compose_version_files "${current}" "${version}"
    else
      printf 'would update: %s\n' "${path}/Makefile"
      printf 'would update: %s\n' "${path}/Sources/ComposePlugin/ComposePlugin.swift"
    fi
    run git -C "${path}" add Makefile Sources/ComposePlugin/ComposePlugin.swift
    run git -C "${path}" commit -m "chore(release): prepare ${version}"
  else
    printf 'container-compose version files already declare %s\n' "${version}"
  fi

  ensure_clean "${COMPOSE_REPO}"
  push_all_main
  wait_for_container_homebrew_package
  tag_stable_version "${version}"
}

# Update compose version declarations and local smoke expectations.
bump_compose_version_files() {
  local current="$1" next="$2" path
  path="$(repo_path "${COMPOSE_REPO}")"
  python3 - "${path}" "${current}" "${next}" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
current = sys.argv[2]
next_version = sys.argv[3]

makefile = root / "Makefile"
text = makefile.read_text(encoding="utf-8")
text = re.sub(r"^COMPOSE_VERSION \?= .+$", f"COMPOSE_VERSION ?= {next_version}", text, flags=re.MULTILINE)
text = text.replace(f'== "{current}"', f'== "{next_version}"')
text = text.replace(f'container-compose {current}', f'container-compose {next_version}')
text = text.replace(f'"version":"{current}"', f'"version":"{next_version}"')
makefile.write_text(text, encoding="utf-8")

source = root / "Sources" / "ComposePlugin" / "ComposePlugin.swift"
text = source.read_text(encoding="utf-8")
text = text.replace(f'var version: String = "{current}"', f'var version: String = "{next_version}"')
text = text.replace(f'version: "{current}"', f'version: "{next_version}"')
source.write_text(text, encoding="utf-8")
PY
}

# Create and optionally push the next short-lived dev slice branch.
start_dev_slice() {
  local current next branch path remote
  current="$(current_compose_version)"
  next="$(resolve_next_version "${VERSION_SELECTOR}")"
  ensure_next_version_increases "${current}" "${next}"
  path="$(repo_path "${COMPOSE_REPO}")"
  remote="$(push_remote "${COMPOSE_REPO}")"
  branch="develop/${next}"

  printf 'current stable version: %s\n' "${current}"
  printf 'next development version: %s\n' "${next}"
  if git -C "${path}" show-ref --verify --quiet "refs/heads/${branch}"; then
    printf 'branch %s already exists locally; refusing to overwrite it\n' "${branch}" >&2
    exit 1
  fi
  if git -C "${path}" ls-remote --exit-code --heads "${remote}" "${branch}" >/dev/null 2>&1; then
    printf 'branch %s already exists remotely; refusing to overwrite it\n' "${branch}" >&2
    exit 1
  fi

  tag_current_stable

  print_header "start ${branch}"
  run git -C "${path}" switch -c "${branch}" main
  if [[ "${EXECUTE}" == "1" ]]; then
    bump_compose_version_files "${current}" "${next}"
  else
    printf 'would update: %s\n' "${path}/Makefile"
    printf 'would update: %s\n' "${path}/Sources/ComposePlugin/ComposePlugin.swift"
  fi
  run git -C "${path}" add Makefile Sources/ComposePlugin/ComposePlugin.swift
  run git -C "${path}" commit -m "chore(release): start ${next} development"
  run git -C "${path}" push "${remote}" "refs/heads/${branch}"

  cat <<EOF

Development slice:
  branch: ${branch}
  version: ${next}
  release tag: ${next}-pre.RUN.SHA
  label: pre-release
  merge rule: squash ${branch} back to main after validation
EOF
}

# Print current stack release status.
plan() {
  local repo current latest next_patch next_minor next_major changed
  prepare_all_main
  current="$(current_compose_version)"
  latest="$(latest_local_semver_tag "${COMPOSE_REPO}")"
  if [[ -z "${latest}" ]]; then
    latest="${current}"
  fi
  next_patch="$(resolve_version_selector '--+' "${latest}")"
  next_minor="$(resolve_version_selector '-+-' "${latest}")"
  next_major="$(resolve_version_selector '+--' "${latest}")"

  print_header "simplified stack release plan"
  printf 'current COMPOSE_VERSION: %s\n' "${current}"
  printf 'latest semantic tag:     %s\n' "${latest}"
  printf 'next patch release:      %s\n' "${next_patch}"
  printf 'next minor release:      %s\n' "${next_minor}"
  printf 'next major release:      %s\n\n' "${next_major}"
  printf '%-26s %-40s %-18s\n' "component" "main-sha" "changed-since-tag"
  for repo in "${REPOS[@]}"; do
    changed="yes"
    if ! repo_changed_since_latest_tag "${repo}"; then
      changed="no"
    fi
    printf '%-26s %-40s %-18s\n' "${repo}" "$(git -C "$(repo_path "${repo}")" rev-parse main)" "${changed}"
  done

  cat <<'EOF'

Process:
  1. Keep main as the releasable integration branch.
  2. For a stable release, run release VERSION_SELECTOR after validation.
  3. The release mode resolves VERSION_SELECTOR from the latest semantic tag,
     bumps container-compose on main when needed, pushes Stephen-owned main
     branches, tags container-compose, dispatches the stable package workflow,
     and verifies the release assets plus Homebrew tap update.
  4. Use package VERSION to rebuild and verify an existing stable tag without
     moving tags.
  5. Use start-dev VERSION_SELECTOR only when opening a separate pre-release
     develop/VERSION slice.
EOF
}

case "${MODE}" in
  plan)
    plan
    ;;
  release)
    prepare_all_main
    release_current_stack
    ;;
  package)
    prepare_all_main
    package_existing_stable "${VERSION_SELECTOR}"
    ;;
  tag-current)
    prepare_all_main
    tag_current_stable
    ;;
  start-dev)
    prepare_all_main
    start_dev_slice
    ;;
esac
