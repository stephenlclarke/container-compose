#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  CONTAINER_STACK_RELEASE.sh plan
  CONTAINER_STACK_RELEASE.sh tag-current [--execute]
  CONTAINER_STACK_RELEASE.sh start-dev VERSION_SELECTOR [--execute]

Purpose:
  Coordinate the simplified Stephen-owned container stack release flow without
  touching Apple upstream repositories.

Modes:
  plan
      Inspect the four local main branches and print the release/dev-slice
      plan. This mode never mutates repositories.

  tag-current
      Tag the current validated container-compose main state as the latest
      stable release using the current COMPOSE_VERSION value. This is the
      manual release point that triggers release generation and tap updates.

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
  start-dev)
    VERSION_SELECTOR="${1:-}"
    if [[ -z "${VERSION_SELECTOR}" ]]; then
      printf 'start-dev requires VERSION_SELECTOR, for example --+, -+-, +--, or 9.0.2\n' >&2
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

# Resolve an explicit or symbolic next development version.
resolve_next_version() {
  local selector="$1" current major minor patch plus_count
  current="$(current_compose_version)"
  if [[ ! "${current}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    printf 'current COMPOSE_VERSION is not semantic: %s\n' "${current}" >&2
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
    IFS=. read -r major minor patch <<<"${current}"
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

# Tag the current compose state as the stable/latest release point.
tag_current_stable() {
  local version
  version="$(current_compose_version)"
  print_header "tag container-compose main as ${version} latest"
  tag_repo_main_if_needed "${COMPOSE_REPO}" "${version}"
  print_component_refs
  cat <<EOF

Stable release point:
  version: ${version}
  label: latest
  release generation: container-compose tag-triggered workflow
  tap update: stable container-compose formula after package artifacts are ready
EOF
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
  local repo current next_patch next_minor next_major changed
  prepare_all_main
  current="$(current_compose_version)"
  next_patch="$(resolve_next_version '--+')"
  next_minor="$(resolve_next_version '-+-')"
  next_major="$(resolve_next_version '+--')"

  print_header "simplified stack release plan"
  printf 'stable version on current main: %s\n' "${current}"
  printf 'next patch slice:              %s\n' "${next_patch}"
  printf 'next minor slice:              %s\n' "${next_minor}"
  printf 'next major slice:              %s\n\n' "${next_major}"
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
  2. Start short-lived work with start-dev VERSION_SELECTOR.
  3. The script tags the current container-compose main version as latest before the bump.
  4. The develop/VERSION branch carries the next version and publishes as pre-release.
  5. Squash the validated develop/VERSION branch to main.
  6. The next start-dev run tags that container-compose main state as latest before opening the following slice.
EOF
}

case "${MODE}" in
  plan)
    plan
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
