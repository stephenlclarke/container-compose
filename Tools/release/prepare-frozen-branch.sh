#!/usr/bin/env bash
# USAGE:
#   Tools/release/prepare-frozen-branch.sh
#
# Removes branch-specific SonarCloud badges from release branches. Free
# SonarCloud only reports the useful branch signal on main, so release branch
# READMEs should not display stale main-branch Sonar badges.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
readme="${repo_root}/README.md"

if [[ ! -f "$readme" ]]; then
    printf 'README.md was not found at %s\n' "$readme" >&2
    exit 1
fi

tmp="$(mktemp)"
grep -v 'sonarcloud.io' "$readme" > "$tmp"
mv "$tmp" "$readme"
