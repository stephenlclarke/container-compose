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

#
# USAGE:
#   check-compose-cli-surface.sh [options]
#
# OPTIONS:
#   --strict       Fail when Docker Compose V2 or container-compose is unavailable.
#   --report PATH  Write the Markdown comparison report to PATH.
#   -h, --help     Show this help.
#
# ENVIRONMENT:
#   CONTAINER_COMPOSE  Path to the container-compose binary. Defaults to the
#                      local SwiftPM debug build at .build/debug/compose.
#   DOCKER_COMPOSE     Docker Compose command to compare with. Defaults to
#                      "docker compose" when available, otherwise docker-compose.
#
# This script is intentionally local-only and is not part of CI. It compares
# the Docker Compose V2 command/help surface with container-compose, including
# root management commands, bridge management commands, and long options for
# every documented command. Known intentional differences are read from
# Tools/parity/compose-cli-surface.allowlist and are included in the report.

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "$SELF_PATH")"
readonly SCRIPT_NAME
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT

STRICT=0
REPORT_PATH="${COMPOSE_CLI_SURFACE_REPORT:-$REPO_ROOT/.build/parity/compose-cli-surface.md}"
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
ALLOWLIST_PATH="$REPO_ROOT/Tools/parity/compose-cli-surface.allowlist"
DOCKER_COMPOSE_COMMAND=()

# Print an informational message to stdout.
info() {
    printf '%s\n' "$*"
}

# Print a warning message to stderr.
warning() {
    printf 'warning: %s\n' "$*" >&2
}

# Print an error message to stderr.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Print usage text extracted from the top of this script.
usage() {
    sed -n '/^# USAGE:/,/^# This script/ { /^# This script/d; s/^# //; s/^#//; p; }' "$SELF_PATH" | sed "s/check-compose-cli-surface.sh/$SCRIPT_NAME/"
}

# Parse command-line flags.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict)
                STRICT=1
                shift
                ;;
            --report)
                if (($# < 2)); then
                    error '--report requires a path'
                    usage >&2
                    return 2
                fi
                REPORT_PATH="$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
}

# Exit cleanly for optional local dependencies, or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi

    warning "$message; skipping Docker Compose CLI surface parity check"
    exit 0
}

# Locate Docker Compose V2, accepting either plugin or standalone command form.
detect_docker_compose() {
    if [[ -n "${DOCKER_COMPOSE:-}" ]]; then
        IFS=' ' read -r -a DOCKER_COMPOSE_COMMAND <<<"$DOCKER_COMPOSE"
    elif docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_COMMAND=(docker-compose)
    else
        skip_or_fail 'Docker Compose V2 is not available'
    fi
}

# Check local tools needed by the comparison.
check_tools() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_or_fail 'python3 is not available'
    fi

    if [[ ! -x "$CONTAINER_COMPOSE" ]]; then
        skip_or_fail "container-compose binary is not executable: $CONTAINER_COMPOSE"
    fi

    if ! "$CONTAINER_COMPOSE" version --short >/dev/null 2>&1; then
        skip_or_fail "container-compose binary could not run: $CONTAINER_COMPOSE"
    fi
}

# Run the help-surface parity comparison and write the Markdown report.
run_comparison() {
    mkdir -p "$(dirname "$REPORT_PATH")"
    python3 - "$REPORT_PATH" "$ALLOWLIST_PATH" "$CONTAINER_COMPOSE" "${DOCKER_COMPOSE_COMMAND[@]}" <<'PY'
import datetime as dt
import pathlib
import re
import subprocess
import sys

report_path = pathlib.Path(sys.argv[1])
allowlist_path = pathlib.Path(sys.argv[2])
container_compose = sys.argv[3]
docker_compose = sys.argv[4:]

command_paths = [
    [],
    ["attach"],
    ["bridge"],
    ["bridge", "convert"],
    ["bridge", "transformations"],
    ["bridge", "transformations", "create"],
    ["bridge", "transformations", "list"],
    ["bridge", "transformations", "ls"],
    ["build"],
    ["commit"],
    ["config"],
    ["convert"],
    ["cp"],
    ["create"],
    ["down"],
    ["events"],
    ["exec"],
    ["export"],
    ["images"],
    ["kill"],
    ["logs"],
    ["ls"],
    ["pause"],
    ["port"],
    ["ps"],
    ["publish"],
    ["pull"],
    ["push"],
    ["restart"],
    ["rm"],
    ["run"],
    ["scale"],
    ["start"],
    ["stats"],
    ["stop"],
    ["top"],
    ["unpause"],
    ["up"],
    ["version"],
    ["volumes"],
    ["wait"],
    ["watch"],
]
command_listing_paths = [
    [],
    ["bridge"],
    ["bridge", "transformations"],
]
ansi_pattern = re.compile(r"\x1b\[[0-9;]*m")


def path_label(path):
    return "root" if not path else " ".join(path)


def run_output(command):
    return subprocess.check_output(command, stderr=subprocess.STDOUT, text=True)


def strip_ansi(text):
    return ansi_pattern.sub("", text)


def help_output(base, path):
    return strip_ansi(run_output(base + path + ["--help"]))


def try_help_output(base, path):
    try:
        return help_output(base, path), None
    except subprocess.CalledProcessError as error:
        return None, strip_ansi(error.output or "").strip()


def version_output(base):
    try:
        return run_output(base + ["version", "--short"]).strip()
    except subprocess.CalledProcessError:
        return run_output(base + ["version"]).strip().splitlines()[0]


def extract_long_options(text):
    options = set()
    option_row = re.compile(r"^( {2}-\S+,\s+--| {6}--)")
    for line in text.splitlines():
        if not option_row.match(line):
            continue
        stripped = line.strip()
        for word in stripped.split():
            token = word.strip(",")
            if token.startswith("--"):
                options.add(token.split("=", 1)[0])
            elif options and not token.startswith("-"):
                break
    return options


def extract_commands(text):
    commands = set()
    in_listing = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped in {"Management Commands:", "Commands:"}:
            in_listing = True
            continue
        if not in_listing:
            continue
        if not stripped:
            continue
        if stripped.startswith("Run '"):
            break
        if not line.startswith("  "):
            in_listing = False
            continue
        token = stripped.split()[0]
        if not token.startswith("-"):
            commands.add(token)
    return commands


def load_allowlist(path):
    entries = {}
    if not path.exists():
        return entries
    for index, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|", 4)
        if len(parts) != 5:
            raise SystemExit(f"{path}:{index}: expected scope|path|direction|name|reason")
        scope, surface, direction, name, reason = parts
        entries[(scope, surface, direction, name)] = reason
    return entries


def diff_entries(scope, surface, local, docker):
    entries = []
    for name in sorted(local - docker):
        entries.append((scope, surface, "local-only", name))
    for name in sorted(docker - local):
        entries.append((scope, surface, "docker-only", name))
    return entries


allowlist = load_allowlist(allowlist_path)
container_base = [container_compose]
docker_base = docker_compose
container_help = {}
docker_help = {}
all_differences = []
unexpected = []
skipped_help_surfaces = []
compared_option_surfaces = 0

for path in command_paths:
    label = path_label(path)
    container_text = help_output(container_base, path)
    container_help[label] = container_text
    docker_text, docker_error = try_help_output(docker_base, path)
    if docker_text is None:
        reason = docker_error.splitlines()[0] if docker_error else "reference help command failed"
        skipped_help_surfaces.append((label, reason))
        continue
    docker_help[label] = docker_text
    compared_option_surfaces += 1
    all_differences.extend(
        diff_entries(
            "option",
            label,
            extract_long_options(container_text),
            extract_long_options(docker_text),
        )
    )

for path in command_listing_paths:
    label = path_label(path)
    all_differences.extend(
        diff_entries(
            "command",
            label,
            extract_commands(container_help[label]),
            extract_commands(docker_help[label]),
        )
    )

for difference in all_differences:
    if difference not in allowlist:
        unexpected.append(difference)

generated = dt.datetime.now(dt.timezone.utc).astimezone().replace(microsecond=0).isoformat()
container_version = version_output(container_base)
docker_version = version_output(docker_base)
lines = [
    "# Docker Compose CLI Surface Parity",
    "",
    f"Generated: `{generated}`",
    "",
    f"- container-compose: `{container_version}` (`{container_compose}`)",
    f"- Docker Compose V2: `{docker_version}` (`{' '.join(docker_compose)}`)",
    f"- Compared help surfaces: `{compared_option_surfaces}` option surfaces, `{len(command_listing_paths)}` command-list surfaces",
    f"- Skipped Docker help surfaces: `{len(skipped_help_surfaces)}`",
    f"- Allowlist: `{allowlist_path.relative_to(pathlib.Path.cwd()) if allowlist_path.is_relative_to(pathlib.Path.cwd()) else allowlist_path}`",
    "",
    "This local-only report compares command names and long option names. It intentionally ignores prose wrapping, support-colour annotations, and description text.",
    "",
]

if unexpected:
    lines.extend(["## Unexpected Differences", ""])
    for scope, surface, direction, name in unexpected:
        lines.append(f"- `{scope}` `{surface}` `{direction}` `{name}`")
    lines.append("")
else:
    lines.extend(["## Unexpected Differences", "", "None.", ""])

known = [difference for difference in all_differences if difference in allowlist]
if known:
    lines.extend(["## Documented Differences", ""])
    for scope, surface, direction, name in known:
        lines.append(f"- `{scope}` `{surface}` `{direction}` `{name}`: {allowlist[(scope, surface, direction, name)]}")
    lines.append("")
else:
    lines.extend(["## Documented Differences", "", "None.", ""])

if skipped_help_surfaces:
    lines.extend(["## Skipped Docker Help Surfaces", ""])
    for label, reason in skipped_help_surfaces:
        lines.append(f"- `{label}`: {reason}")
    lines.append("")
else:
    lines.extend(["## Skipped Docker Help Surfaces", "", "None.", ""])

if not all_differences:
    lines.extend(["## Raw Differences", "", "None.", ""])
else:
    lines.extend(["## Raw Differences", ""])
    for scope, surface, direction, name in sorted(all_differences):
        state = "documented" if (scope, surface, direction, name) in allowlist else "unexpected"
        lines.append(f"- `{state}` `{scope}` `{surface}` `{direction}` `{name}`")
    lines.append("")

report_path.write_text("\n".join(lines), encoding="utf-8")
print(f"Wrote Docker Compose CLI surface report to {report_path}")

if unexpected:
    for scope, surface, direction, name in unexpected:
        print(f"unexpected {scope} difference on {surface}: {direction} {name}", file=sys.stderr)
    raise SystemExit(1)

print(f"Docker Compose CLI surface parity passed with {len(known)} documented difference(s)")
PY
}

# Run the local-only CLI surface parity check.
main() {
    parse_args "$@"
    detect_docker_compose
    check_tools
    run_comparison
}

main "$@"
