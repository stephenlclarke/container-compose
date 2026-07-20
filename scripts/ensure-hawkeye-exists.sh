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

auto_install=0

for arg in "$@"; do
    case "${arg}" in
        --auto-install|-y)
            auto_install=1
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--auto-install|-y]

Checks first for a working system-wide hawkeye installation, then for the
repository-local .local/bin fallback. If hawkeye is missing, prompts before
running scripts/install-hawkeye.sh.

Skip the prompt non-interactively in either of two ways:
  --auto-install, -y      pass on the command line
  HAWKEYE_AUTO_INSTALL=1  set in the environment
EOF
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "${arg}" >&2
            printf "see '%s --help' for usage\n" "$(basename "$0")" >&2
            exit 2
            ;;
    esac
done

if [[ "${HAWKEYE_AUTO_INSTALL:-}" == "1" ]]; then
    auto_install=1
fi

if command -v hawkeye >/dev/null 2>&1; then
    printf 'hawkeye found at %s\n' "$(command -v hawkeye)"
    exit 0
fi

if command -v .local/bin/hawkeye >/dev/null 2>&1; then
    printf 'repository-local hawkeye found at .local/bin/hawkeye\n'
    exit 0
fi

cat <<EOF

hawkeye is not installed system-wide or in this checkout.

scripts/install-hawkeye.sh will install a repository-local fallback by running:

    curl -LsSf https://github.com/korandoru/hawkeye/releases/download/<version>/hawkeye-installer.sh | sh

and performs the installation by passing the downloaded content to \`sh\`.

See scripts/install-hawkeye.sh for the pinned version.
EOF

if [[ "${auto_install}" -eq 1 ]]; then
    printf '\nAuto-install enabled; proceeding.\n'
elif [[ ! -t 0 ]]; then
    printf '\nNon-interactive context detected. Refusing to install silently.\n' >&2
    printf 'Set HAWKEYE_AUTO_INSTALL=1 or pass --auto-install to proceed.\n' >&2
    exit 1
else
    printf '\n'
    read -r -p "Proceed with install? [y/N] " response
    case "${response}" in
        [yY][eE][sS]|[yY])
            ;;
        *)
            printf 'please install hawkeye. For convenience, you can run scripts/install-hawkeye.sh\n'
            exit 1
            ;;
    esac
fi

exec "$(dirname "$0")/install-hawkeye.sh"
