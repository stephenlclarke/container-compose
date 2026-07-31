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

# Source this file from an already-running Bash or Zsh process. Starting a new
# interpreter to run this file would let a hostile native-loader environment
# execute before the entry boundary can clear it. Keep this check command-free:
# inherited functions must not run before container_compose_codeql disables
# them.
case "${BASH_VERSION-}:${ZSH_VERSION-}" in
    :)
        return 2
        ;;
esac

# Builds the first new process environment entirely with shell builtins. No
# dynamically linked helper runs while inherited loader controls still exist.
# A supported caller must not carry GITHUB_TOKEN or GH_TOKEN, tracing modes, or
# shell traps: inherited tracing and traps run before any function body can
# disable them. Real upload credentials are acquired from the GitHub CLI auth
# store only after this boundary has removed traps, tracing, functions, and the
# inherited environment.
container_compose_codeql() (
    codeql_shell_flags=$-
    codeql_inherited_trap=0
    # Bash gives POSIX special builtins precedence over functions once
    # POSIXLY_CORRECT is set. Clear inherited DEBUG/RETURN/ERR handlers before
    # they can survive to a new process, disable their inheritance modes, use
    # trusted unset to remove the commands needed to enumerate functions, then
    # remove every remaining function in this subshell. Zsh exposes traps as
    # TRAP* functions and enabled/disabled functions as paired special
    # associative arrays; capture those trap names, then atomically disable the
    # complete enabled function table without resolving a command name.
    # Backslashes suppress caller aliases until the trusted builtin dispatcher
    # is available.
    if [[ -n "${BASH_VERSION-}" ]]; then
        POSIXLY_CORRECT=1
        \trap - DEBUG RETURN ERR
        \set +x +T +E
        if [[ "$codeql_shell_flags" == *T* || "$codeql_shell_flags" == *E* ]]; then
            codeql_inherited_trap=1
        fi
        \unset -f builtin compgen printf read trap
        for codeql_name in $(\builtin compgen -A function); do
            \unset -f "$codeql_name" || {
                \builtin printf \
                    'could not remove inherited shell function: %s\n' \
                    "$codeql_name" >&2
                \builtin return 2
            }
        done
    else
        codeql_zsh_traps=("${(@k)functions[(I)TRAP*]}")
        dis_functions=("${(@kv)functions}")
        \set +x
        if (( ${#codeql_zsh_traps[@]} != 0 )); then
            codeql_inherited_trap=1
        fi
    fi

    IFS=$' \t\n'
    if [[ "$codeql_shell_flags" == *x* ]]; then
        \builtin printf '%s\n' \
            'unsafe traced caller; disable shell tracing before entering CodeQL' >&2
        \builtin return 2
    fi
    if [[ "$codeql_inherited_trap" == 1 ]]; then
        \builtin printf '%s\n' \
            'unsafe trap-bearing caller; disable shell traps, functrace, and errtrace before entering CodeQL' >&2
        \builtin return 2
    fi
    if [[ -n "${GITHUB_TOKEN-}" || -n "${GH_TOKEN-}" ]]; then
        \builtin printf '%s\n' \
            'unsafe credential-bearing caller; use a credential-free shell and the GitHub CLI auth store' >&2
        \builtin return 2
    fi
    if [[ "$#" -ne 1 ]]; then
        \builtin printf '%s\n' \
            'usage: container_compose_codeql codeql-local|codeql-sarif-upload|codeql-sarif-upload-dry-run' >&2
        \builtin return 2
    fi

    case "$1" in
        codeql-local|codeql-sarif-upload|codeql-sarif-upload-dry-run)
            ;;
        *)
            \builtin printf 'unsupported CodeQL goal: %s\n' "$1" >&2
            \builtin return 2
            ;;
    esac
    if [[ ! -r Tools/ci/codeql-make.py ]]; then
        \builtin printf '%s\n' 'run container_compose_codeql from the repository root' >&2
        \builtin return 2
    fi

    codeql_goal=$1
    if [[ -n "${BASH_VERSION-}" ]]; then
        for codeql_name in $(\builtin compgen -e); do
            \builtin export -n "$codeql_name" || {
                \builtin printf 'could not remove inherited environment variable: %s\n' "$codeql_name" >&2
                \builtin return 2
            }
        done
    else
        for codeql_name in ${(k)parameters[(R)*export*]}; do
            \builtin typeset +x "$codeql_name" || {
                \builtin printf 'could not remove inherited environment variable: %s\n' "$codeql_name" >&2
                \builtin return 2
            }
        done
    fi

    \builtin export CONTAINER_COMPOSE_CODEQL_CLEAN_PROCESS_ENTRY=1

    [[ "${CODEQL_CACHE_ROOT+x}" != x ]] || \builtin export CODEQL_CACHE_ROOT
    [[ "${CODEQL_ARTIFACT_ROOT+x}" != x ]] || \builtin export CODEQL_ARTIFACT_ROOT

    if [[ "$codeql_goal" != codeql-local ]]; then
        [[ "${CODEQL_UPLOAD_REPOSITORY+x}" != x ]] || \builtin export CODEQL_UPLOAD_REPOSITORY
        [[ "${CODEQL_UPLOAD_REF+x}" != x ]] || \builtin export CODEQL_UPLOAD_REF
        [[ "${CODEQL_UPLOAD_COMMIT+x}" != x ]] || \builtin export CODEQL_UPLOAD_COMMIT
    fi

    [[ "${LANG+x}" != x ]] || \builtin export LANG
    [[ "${LC_ALL+x}" != x ]] || \builtin export LC_ALL
    [[ "${LC_CTYPE+x}" != x ]] || \builtin export LC_CTYPE
    [[ "${SSL_CERT_FILE+x}" != x ]] || \builtin export SSL_CERT_FILE
    [[ "${SSL_CERT_DIR+x}" != x ]] || \builtin export SSL_CERT_DIR
    [[ "${HTTP_PROXY+x}" != x ]] || \builtin export HTTP_PROXY
    [[ "${HTTPS_PROXY+x}" != x ]] || \builtin export HTTPS_PROXY
    [[ "${NO_PROXY+x}" != x ]] || \builtin export NO_PROXY
    [[ "${http_proxy+x}" != x ]] || \builtin export http_proxy
    [[ "${https_proxy+x}" != x ]] || \builtin export https_proxy
    [[ "${no_proxy+x}" != x ]] || \builtin export no_proxy

    \builtin exec /usr/bin/python3 -I Tools/ci/codeql-make.py "$codeql_goal"
)
