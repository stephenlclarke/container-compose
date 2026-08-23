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

# USAGE:
#   @SCRIPT_NAME@ [--nextflow PATH] [--proof-root PATH]
#
# Verify that the build pipeline can resume one explicit failed Nextflow
# session without rerunning successful upstream work.
#
# Environment:
#   NEXTFLOW_BIN                 Pinned Nextflow executable (alternative to
#                                --nextflow).
#   NEXTFLOW_RECOVERY_KEEP       Keep the temporary proof root when truthy.
#   NEXTFLOW_RECOVERY_TIMEOUT    Per-run deadline in seconds (default: 120).

set -euo pipefail

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="$(basename "${SELF_PATH}")"
readonly SCRIPT_NAME
SCRIPT_DIRECTORY="$(cd "$(dirname "${SELF_PATH}")" && pwd -P)"
readonly SCRIPT_DIRECTORY
REPOSITORY_ROOT="$(cd "${SCRIPT_DIRECTORY}/../.." && pwd -P)"
readonly REPOSITORY_ROOT
readonly FIXTURE_PATH="${REPOSITORY_ROOT}/Tests/BuildPipeline/recovery-proof.nf"
readonly FIXTURE_CONFIG_PATH="${REPOSITORY_ROOT}/Tests/BuildPipeline/recovery-proof.config"
readonly DEADLINE_HELPER="${SCRIPT_DIRECTORY}/run-command-with-deadline.py"
readonly PROOF_ROOT_MARKER='.container-compose-nextflow-recovery-root'
readonly PROOF_ROOT_MARKER_VALUE='container-compose Nextflow recovery proof v1'

NEXTFLOW_EXECUTABLE="${NEXTFLOW_BIN:-}"
PROOF_ROOT=""
KEEP_PROOF_ROOT="${NEXTFLOW_RECOVERY_KEEP:-0}"
RUN_TIMEOUT_SECONDS="${NEXTFLOW_RECOVERY_TIMEOUT:-120}"

# Print command help.
usage() {
    sed -n '/^# USAGE:/,/^$/s/^# \{0,1\}//p' "${SELF_PATH}" \
        | sed "s/@SCRIPT_NAME@/${SCRIPT_NAME}/g"
}

# Print an error message.
error() {
    printf 'error: %s\n' "$*" >&2
}

# Return success when a conventional environment boolean is enabled.
is_truthy() {
    case "$1" in
        1 | true | TRUE | True | yes | YES | Yes | on | ON | On)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Parse command-line options.
parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --nextflow)
                (($# >= 2)) || {
                    error '--nextflow requires a path'
                    usage >&2
                    exit 2
                }
                NEXTFLOW_EXECUTABLE="$2"
                shift 2
                ;;
            --proof-root)
                (($# >= 2)) || {
                    error '--proof-root requires a path'
                    usage >&2
                    exit 2
                }
                PROOF_ROOT="$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "unknown argument: $1"
                usage >&2
                exit 2
                ;;
        esac
    done
}

# Validate a positive integer deadline.
validate_timeout() {
    if ! [[ "${RUN_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
        error "NEXTFLOW_RECOVERY_TIMEOUT must be a positive integer: ${RUN_TIMEOUT_SECONDS}"
        exit 2
    fi
}

# Prepare an isolated proof directory outside the source checkout.
prepare_proof_root() {
    local proof_root_created=0

    if [[ -n "${PROOF_ROOT}" ]]; then
        if [[ "${PROOF_ROOT}" != /* || "${PROOF_ROOT}" == / ]]; then
            error "--proof-root must be an absolute path other than /: ${PROOF_ROOT}"
            exit 2
        fi
        case "${PROOF_ROOT}/" in
            "${REPOSITORY_ROOT}/"*)
                error "--proof-root must remain outside the source checkout: ${PROOF_ROOT}"
                exit 2
                ;;
        esac
        if [[ -e "${PROOF_ROOT}" && ! -d "${PROOF_ROOT}" ]]; then
            error "--proof-root is not a directory: ${PROOF_ROOT}"
            exit 2
        fi
        if [[ -d "${PROOF_ROOT}" && -n "$(ls -A "${PROOF_ROOT}")" ]]; then
            error "--proof-root must be absent or empty: ${PROOF_ROOT}"
            exit 2
        fi
        if [[ ! -d "${PROOF_ROOT}" ]]; then
            mkdir -p "${PROOF_ROOT}"
            proof_root_created=1
        fi
    else
        PROOF_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/container-compose-nextflow-recovery.XXXXXX")"
    fi
    PROOF_ROOT="$(cd "${PROOF_ROOT}" && pwd -P)"
    case "${PROOF_ROOT}/" in
        "${REPOSITORY_ROOT}/"*)
            if ((proof_root_created == 1)); then
                rmdir -- "${PROOF_ROOT}" 2>/dev/null || true
            fi
            error "--proof-root must remain outside the source checkout: ${PROOF_ROOT}"
            exit 2
            ;;
    esac
    printf '%s\n' "${PROOF_ROOT_MARKER_VALUE}" > "${PROOF_ROOT}/${PROOF_ROOT_MARKER}"
}

# Remove temporary evidence unless the caller requested retention.
cleanup() {
    if [[ -n "${PROOF_ROOT}" ]] && ! is_truthy "${KEEP_PROOF_ROOT}"; then
        if [[ ! -f "${PROOF_ROOT}/${PROOF_ROOT_MARKER}" ]] \
            || [[ "$(<"${PROOF_ROOT}/${PROOF_ROOT_MARKER}")" != "${PROOF_ROOT_MARKER_VALUE}" ]]; then
            error "refusing to remove an unmarked proof root: ${PROOF_ROOT}"
            return
        fi
        rm -rf -- "${PROOF_ROOT}"
    fi
}

# Run Nextflow under the repository's process-session deadline helper.
run_nextflow() {
    local log_path="$1"
    local trace_path="$2"
    shift 2

    (
        cd "${PROOF_ROOT}"
        CI=1 \
            GIT_TERMINAL_PROMPT=0 \
            GCM_INTERACTIVE=never \
            SSH_ASKPASS_REQUIRE=never \
            NXF_ANSI_LOG=false \
            NXF_DISABLE_CHECK_LATEST=true \
            NXF_HOME="${PROOF_ROOT}/nxf-home" \
            python3 "${DEADLINE_HELPER}" \
                --seconds "${RUN_TIMEOUT_SECONDS}" \
                --grace-seconds 5 \
                -- \
                "${NEXTFLOW_EXECUTABLE}" \
                -log "${log_path}" \
                -C "${FIXTURE_CONFIG_PATH}" \
                run "${FIXTURE_PATH}" \
                -ansi-log false \
                -work-dir "${PROOF_ROOT}/work" \
                -with-trace "${trace_path}" \
                "$@"
    ) </dev/null
}

# Extract the only explicit session UUID from an isolated Nextflow history.
extract_failed_session_uuid() {
    local history_path="$1"
    local history_status
    local session_uuid

    history_status="$(awk -F '\t' 'END { print $4 }' "${history_path}")"
    if [[ "${history_status}" != ERR ]]; then
        error "the retained Nextflow session was not recorded as failed: ${history_status}"
        exit 1
    fi
    session_uuid="$(awk -F '\t' 'END { print $6 }' "${history_path}")"
    if ! [[ "${session_uuid}" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
        error "could not extract a session UUID from ${history_path}"
        exit 1
    fi
    printf '%s\n' "${session_uuid}"
}

# Read a trace column for one untagged process name.
trace_value() {
    local trace_path="$1"
    local process_name="$2"
    local column_name="$3"

    awk -F '\t' -v expected_process="${process_name}" -v expected_column="${column_name}" '
        NR == 1 {
            for (field_index = 1; field_index <= NF; field_index += 1) {
                columns[$field_index] = field_index
            }
            next
        }
        {
            observed_process = $columns["name"]
            sub(/^.*:/, "", observed_process)
            sub(/ \(.*/, "", observed_process)
            if (observed_process == expected_process) {
                value = $columns[expected_column]
            }
        }
        END {
            if (value == "") {
                exit 1
            }
            print value
        }
    ' "${trace_path}"
}

# Require an observed trace value.
assert_trace_value() {
    local trace_path="$1"
    local process_name="$2"
    local column_name="$3"
    local expected_value="$4"
    local observed_value

    if ! observed_value="$(trace_value "${trace_path}" "${process_name}" "${column_name}")"; then
        error "${process_name} was not recorded in ${trace_path}"
        exit 1
    fi
    if [[ "${observed_value}" != "${expected_value}" ]]; then
        error "${process_name} ${column_name} was ${observed_value}, expected ${expected_value}"
        exit 1
    fi
}

# Run the failure and exact-session recovery proof.
run_proof() {
    local first_output="${PROOF_ROOT}/first-run.output"
    local first_log="${PROOF_ROOT}/first-run.log"
    local first_trace="${PROOF_ROOT}/first-run.trace.tsv"
    local history_path="${PROOF_ROOT}/.nextflow/history"
    local resume_output="${PROOF_ROOT}/resume-run.output"
    local resume_log="${PROOF_ROOT}/resume-run.log"
    local resume_trace="${PROOF_ROOT}/resume-run.trace.tsv"
    local first_status=0
    local session_uuid
    local resumed_session_uuid
    local stdin_hash_before
    local stdin_hash_after
    local upstream_hash_before
    local upstream_hash_after
    local downstream_hash_before
    local downstream_hash_after

    run_nextflow "${first_log}" "${first_trace}" \
        --upstream_fingerprint upstream-v1 \
        --downstream_fingerprint planned-failure-v1 \
        >"${first_output}" 2>&1 || first_status=$?
    if ((first_status == 0)); then
        error 'the planned downstream failure unexpectedly succeeded'
        exit 1
    fi
    if ((first_status == 124)); then
        error 'the planned downstream failure exceeded its deadline'
        exit 1
    fi
    grep -q 'planned downstream failure' "${first_output}" || {
        error 'the first run did not retain the planned failure evidence'
        exit 1
    }
    [[ -f "${history_path}" ]] || {
        error "Nextflow history was not written: ${history_path}"
        exit 1
    }

    assert_trace_value "${first_trace}" VERIFY_STDIN_CLOSED status COMPLETED
    assert_trace_value "${first_trace}" BUILD_UPSTREAM status COMPLETED
    assert_trace_value "${first_trace}" RUN_DOWNSTREAM status FAILED
    assert_trace_value "${first_trace}" RUN_DOWNSTREAM exit 42
    session_uuid="$(extract_failed_session_uuid "${history_path}")"

    run_nextflow "${resume_log}" "${resume_trace}" \
        -resume "${session_uuid}" \
        --upstream_fingerprint upstream-v1 \
        --downstream_fingerprint corrected-v1 \
        >"${resume_output}" 2>&1

    resumed_session_uuid="$(awk -F '\t' 'END { print $6 }' "${history_path}")"
    if [[ "${resumed_session_uuid}" != "${session_uuid}" ]]; then
        error "resume used session ${resumed_session_uuid}, expected ${session_uuid}"
        exit 1
    fi

    assert_trace_value "${resume_trace}" VERIFY_STDIN_CLOSED status CACHED
    assert_trace_value "${resume_trace}" BUILD_UPSTREAM status CACHED
    assert_trace_value "${resume_trace}" RUN_DOWNSTREAM status COMPLETED
    grep -q 'RECOVERY_PROOF_RESULT=downstream complete' "${resume_output}" || {
        error 'the corrected downstream result was not emitted'
        exit 1
    }

    stdin_hash_before="$(trace_value "${first_trace}" VERIFY_STDIN_CLOSED hash)"
    stdin_hash_after="$(trace_value "${resume_trace}" VERIFY_STDIN_CLOSED hash)"
    upstream_hash_before="$(trace_value "${first_trace}" BUILD_UPSTREAM hash)"
    upstream_hash_after="$(trace_value "${resume_trace}" BUILD_UPSTREAM hash)"
    downstream_hash_before="$(trace_value "${first_trace}" RUN_DOWNSTREAM hash)"
    downstream_hash_after="$(trace_value "${resume_trace}" RUN_DOWNSTREAM hash)"

    [[ "${stdin_hash_before}" == "${stdin_hash_after}" ]] || {
        error 'the stdin-verification task hash changed during downstream recovery'
        exit 1
    }
    [[ "${upstream_hash_before}" == "${upstream_hash_after}" ]] || {
        error 'the upstream task hash changed during downstream recovery'
        exit 1
    }
    [[ "${downstream_hash_before}" != "${downstream_hash_after}" ]] || {
        error 'the corrected downstream fingerprint did not invalidate its failed task'
        exit 1
    }

    printf 'NEXTFLOW_RECOVERY_PROOF=passed\n'
    printf 'SESSION_UUID=%s\n' "${session_uuid}"
    printf 'VERIFY_STDIN_CLOSED=CACHED:%s\n' "${stdin_hash_after}"
    printf 'BUILD_UPSTREAM=CACHED:%s\n' "${upstream_hash_after}"
    printf 'RUN_DOWNSTREAM=COMPLETED:%s\n' "${downstream_hash_after}"
    if is_truthy "${KEEP_PROOF_ROOT}"; then
        printf 'EVIDENCE_ROOT=%s\n' "${PROOF_ROOT}"
    fi
}

# Validate prerequisites and execute the proof.
main() {
    parse_arguments "$@"
    validate_timeout

    if [[ -z "${NEXTFLOW_EXECUTABLE}" ]]; then
        error 'provide the pinned Nextflow executable with --nextflow or NEXTFLOW_BIN'
        exit 2
    fi
    if [[ "${NEXTFLOW_EXECUTABLE}" != /* ]]; then
        error "Nextflow executable must be an absolute path: ${NEXTFLOW_EXECUTABLE}"
        exit 2
    fi
    if [[ ! -x "${NEXTFLOW_EXECUTABLE}" ]]; then
        error "Nextflow executable is not executable: ${NEXTFLOW_EXECUTABLE}"
        exit 2
    fi
    [[ -f "${FIXTURE_PATH}" ]] || {
        error "recovery fixture is missing: ${FIXTURE_PATH}"
        exit 1
    }
    [[ -f "${FIXTURE_CONFIG_PATH}" ]] || {
        error "recovery fixture config is missing: ${FIXTURE_CONFIG_PATH}"
        exit 1
    }
    [[ -x "${DEADLINE_HELPER}" ]] || {
        error "deadline helper is not executable: ${DEADLINE_HELPER}"
        exit 1
    }

    prepare_proof_root
    trap cleanup EXIT
    run_proof
}

main "$@"
