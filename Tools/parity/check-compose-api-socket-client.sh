#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
# Licensed under the Apache License, Version 2.0.
#===----------------------------------------------------------------------===#

# Prove Compose use_api_socket with an unmodified Docker CLI image. The image
# must already be present in Container; this check never pulls or builds it.

set -euo pipefail
shopt -s nullglob

readonly SELF_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "$SELF_PATH")/../.." && pwd)"
readonly REPO_ROOT
readonly ROOT_MARKER_NAME=".container-compose-api-socket-proof"
readonly DEFAULT_CLIENT_IMAGE="docker.io/library/docker:29.2.1-cli@sha256:cab69e2d0a1a2ea9a1ce1060252f439e83483ae41ec09317aecb33b08a0656a5"
readonly AUTH_SENTINEL="compose-api-socket-proof-secret"
readonly AUTH_USERNAME_SENTINEL="compose-api-socket-proof-user"
readonly AUTH_PASSWORD_SENTINEL="compose-api-socket-proof-password"
readonly AUTH_VALUE="Y29tcG9zZS1hcGktc29ja2V0LXByb29mLXVzZXI6Y29tcG9zZS1hcGktc29ja2V0LXByb29mLXBhc3N3b3Jk"
CALLER_ROOT="$(pwd -P)"
readonly CALLER_ROOT

STRICT=0
TIMEOUT_SECONDS="${PARITY_TIMEOUT_SECONDS:-300}"
EXPECTED_FAILURE_TIMEOUT_SECONDS="${PARITY_EXPECTED_FAILURE_TIMEOUT_SECONDS:-30}"
CLIENT_IMAGE="${API_SOCKET_CLIENT_IMAGE:-$DEFAULT_CLIENT_IMAGE}"
CONTAINER_COMPOSE="${CONTAINER_COMPOSE:-$REPO_ROOT/.build/debug/compose}"
CONTAINER_BINARY="${CONTAINER_COMPOSE_CONTAINER:-container}"
EVIDENCE_OUTPUT="${API_SOCKET_EVIDENCE_OUTPUT:-$REPO_ROOT/.build/parity/use-api-socket-client-evidence.json}"
LOCAL_EXECUTION_ROOT="${CONTAINER_RUNTIME_LOCAL_EXECUTION_ROOT:-}"
WORK_ROOT=""
PROJECT=""
CANARY_NATIVE_ID=""
COMPOSE_FILE=""
TRANSCRIPT=""
CLIENT_PROBE=""
OPT_OUT_PROBE=""
ONE_OFF_PROBE=""
COMMAND_INDEX=0
CLEANING=0
PROOF_COMPLETE=0
PROOF_STARTED=0
CURRENT_PHASE="initialization"
START_SECONDS=$SECONDS
COMPOSE_COMMAND=()
SEEN_NATIVE_IDS=()

info() { printf '%s\n' "$*"; }
error() { printf 'error: %s\n' "$*" >&2; }

usage() {
    printf '%s\n' \
        'usage: check-compose-api-socket-client.sh [--strict]' \
        '' \
        'Environment:' \
        '  CONTAINER_COMPOSE             Compose executable to certify.' \
        '  CONTAINER_COMPOSE_CONTAINER   Matching Container executable.' \
        '  API_SOCKET_CLIENT_IMAGE       Preloaded Docker CLI image.' \
        '  API_SOCKET_EVIDENCE_OUTPUT    Machine-readable result path.' \
        '  PARITY_TIMEOUT_SECONDS        Per-command deadline (default 300).' \
        '  PARITY_EXPECTED_FAILURE_TIMEOUT_SECONDS' \
        '                                Stopped-exec deadline (default 30).'
}

skip_or_fail() {
    local message="$1"
    if ((STRICT == 1)); then
        error "$message"
        return 1
    fi
    printf 'warning: %s; skipping API socket client proof\n' "$message" >&2
    exit 0
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --strict)
                STRICT=1
                shift
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

run_bounded() {
    (
        cd "$WORK_ROOT"
        python3 "$REPO_ROOT/Tools/ci/run-command-with-deadline.py" \
            --seconds "$TIMEOUT_SECONDS" --grace-seconds 5 -- "$@"
    )
}

run_bounded_for() {
    local seconds="$1"
    shift
    (
        cd "$WORK_ROOT"
        python3 "$REPO_ROOT/Tools/ci/run-command-with-deadline.py" \
            --seconds "$seconds" --grace-seconds 5 -- "$@"
    )
}

redact_output() {
    sed -e "s/$AUTH_SENTINEL/[REDACTED]/g" \
        -e "s/$AUTH_USERNAME_SENTINEL/[REDACTED]/g" \
        -e "s/$AUTH_PASSWORD_SENTINEL/[REDACTED]/g" \
        -e "s/$AUTH_VALUE/[REDACTED]/g" "$1"
}

assert_no_secret_output() {
    local path="$1"
    if grep -F -e "$AUTH_SENTINEL" -e "$AUTH_USERNAME_SENTINEL" \
        -e "$AUTH_PASSWORD_SENTINEL" -e "$AUTH_VALUE" "$path" >/dev/null; then
        error "a credential sentinel appeared in command output"
        return 1
    fi
}

capture_command() {
    local variable_name="$1"
    local label="$2"
    local output value status=0
    shift 2
    ((COMMAND_INDEX += 1))
    output="$WORK_ROOT/command-$COMMAND_INDEX-$label.log"
    run_bounded "$@" >"$output" 2>&1 || status=$?
    assert_no_secret_output "$output" || return 1
    cat "$output" >>"$TRANSCRIPT"
    if ((status != 0)); then
        redact_output "$output" >&2
        return "$status"
    fi
    value="$(<"$output")"
    printf -v "$variable_name" '%s' "$value"
}

run_command() {
    local ignored
    capture_command ignored "$@"
    : "$ignored"
}

capture_command_with_input() {
    local variable_name="$1"
    local label="$2"
    local input_path="$3"
    local output value status=0
    shift 3
    ((COMMAND_INDEX += 1))
    output="$WORK_ROOT/command-$COMMAND_INDEX-$label.log"
    run_bounded "$@" <"$input_path" >"$output" 2>&1 || status=$?
    assert_no_secret_output "$output" || return 1
    cat "$output" >>"$TRANSCRIPT"
    if ((status != 0)); then
        redact_output "$output" >&2
        return "$status"
    fi
    value="$(<"$output")"
    printf -v "$variable_name" '%s' "$value"
}

run_command_with_input() {
    local ignored
    capture_command_with_input ignored "$@"
    : "$ignored"
}

expect_stopped_exec_failure() {
    local label="$1"
    local expected_id="$2"
    local output status=0
    shift 2
    ((COMMAND_INDEX += 1))
    output="$WORK_ROOT/command-$COMMAND_INDEX-$label.log"
    run_bounded_for "$EXPECTED_FAILURE_TIMEOUT_SECONDS" "$@" >"$output" 2>&1 || status=$?
    assert_no_secret_output "$output" || return 1
    cat "$output" >>"$TRANSCRIPT"
    if ((status == 0)); then
        error "$label unexpectedly succeeded"
        return 1
    fi
    if ((status != 1)); then
        redact_output "$output" >&2
        error "$label returned unexpected status $status instead of 1"
        return 1
    fi
    if ! grep -F "container '$expected_id' is not running" "$output" >/dev/null; then
        redact_output "$output" >&2
        error "$label did not report the expected stopped container"
        return 1
    fi
}

compose_config_directories() {
    local root="$HOME/.container-compose/config-secrets"
    local path
    [[ -d "$root" ]] || return 0
    for path in "$root"/"$PROJECT"-*; do
        [[ -d "$path" && ! -L "$path" ]] && printf '%s\n' "$path"
    done
}

cleanup() {
    ((CLEANING == 0)) || return 0
    CLEANING=1
    if ((${#COMPOSE_COMMAND[@]} > 0)); then
        run_bounded "${COMPOSE_COMMAND[@]}" down --remove-orphans >/dev/null 2>&1 || true
    fi
    if [[ -n "$CANARY_NATIVE_ID" ]]; then
        run_bounded "$CONTAINER_BINARY" delete --force "$CANARY_NATIVE_ID" >/dev/null 2>&1 || true
    fi
    if ((PROOF_COMPLETE == 0 && PROOF_STARTED == 1)) && [[ -n "$WORK_ROOT" ]]; then
        error "proof failed during $CURRENT_PHASE; retained evidence: $WORK_ROOT"
        return 0
    fi
    if [[ -n "$WORK_ROOT" && "$WORK_ROOT" == "$LOCAL_EXECUTION_ROOT"/compose-api-socket.* \
        && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        find "$WORK_ROOT" -depth -delete
    fi
}

prepare_local_work_root() {
    if [[ -z "$LOCAL_EXECUTION_ROOT" ]]; then
        LOCAL_EXECUTION_ROOT=/private/tmp
        if [[ ! -d "$LOCAL_EXECUTION_ROOT" || ! -w "$LOCAL_EXECUTION_ROOT" ]]; then
            LOCAL_EXECUTION_ROOT=/tmp
        fi
    fi
    case "$LOCAL_EXECUTION_ROOT" in
        /private/tmp | /tmp) ;;
        *)
            error "CONTAINER_RUNTIME_LOCAL_EXECUTION_ROOT must be /private/tmp or /tmp: $LOCAL_EXECUTION_ROOT"
            return 2
            ;;
    esac
    if [[ ! -d "$LOCAL_EXECUTION_ROOT" || ! -w "$LOCAL_EXECUTION_ROOT" ]]; then
        error "local execution root is not writable: $LOCAL_EXECUTION_ROOT"
        return 2
    fi
    WORK_ROOT="$(mktemp -d "$LOCAL_EXECUTION_ROOT/compose-api-socket.XXXXXX")"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"
    chmod 700 "$WORK_ROOT"
}

resolve_command_paths() {
    if [[ "$CONTAINER_COMPOSE" != /* ]]; then
        CONTAINER_COMPOSE="$CALLER_ROOT/$CONTAINER_COMPOSE"
    fi
    case "$CONTAINER_BINARY" in
        /*) ;;
        */*) CONTAINER_BINARY="$CALLER_ROOT/$CONTAINER_BINARY" ;;
    esac
}

check_prerequisites() {
    [[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
        || skip_or_fail "PARITY_TIMEOUT_SECONDS must be a positive integer"
    [[ "$EXPECTED_FAILURE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] \
        || skip_or_fail "PARITY_EXPECTED_FAILURE_TIMEOUT_SECONDS must be a positive integer"
    command -v python3 >/dev/null 2>&1 || skip_or_fail "python3 is unavailable"
    command -v jq >/dev/null 2>&1 || skip_or_fail "jq is unavailable"
    [[ -x "$CONTAINER_COMPOSE" ]] \
        || skip_or_fail "container-compose is not executable: $CONTAINER_COMPOSE"
    if [[ ! -x "$CONTAINER_BINARY" ]] && ! command -v "$CONTAINER_BINARY" >/dev/null 2>&1; then
        skip_or_fail "Container is unavailable: $CONTAINER_BINARY"
    fi
    run_bounded "$CONTAINER_BINARY" system status >/dev/null 2>&1 \
        || skip_or_fail "Container system is not running"
    run_bounded "$CONTAINER_BINARY" image inspect "$CLIENT_IMAGE" >/dev/null 2>&1 \
        || skip_or_fail "Docker CLI image is not preloaded: $CLIENT_IMAGE"
}

write_fixture() {
    cat >"$COMPOSE_FILE" <<YAML
services:
  root-client:
    image: $CLIENT_IMAGE
    command: ["sh", "-c", "sleep 900"]
    pull_policy: never
    use_api_socket: true
  nonroot-client:
    image: $CLIENT_IMAGE
    command: ["sh", "-c", "sleep 900"]
    pull_policy: never
    user: "1000:991"
    use_api_socket: true
  opt-out:
    image: $CLIENT_IMAGE
    command: ["sh", "-c", "sleep 900"]
    pull_policy: never
YAML

    CLIENT_PROBE="$WORK_ROOT/client-probe.sh"
    OPT_OUT_PROBE="$WORK_ROOT/opt-out-probe.sh"
    ONE_OFF_PROBE="$WORK_ROOT/one-off-probe.sh"
    cat >"$CLIENT_PROBE" <<'SCRIPT'
set -eu
test "$(id -u)" = "$EXPECTED_UID"
test "$(id -g)" = "$EXPECTED_GID"
test -S /var/run/docker.sock
test "$(stat -c %u:%g:%a /var/run/docker.sock)" = 0:991:660
test "${DOCKER_CONFIG:-}" = /run/secrets/docker
test -r /run/secrets/docker/config.json
test "$(stat -c %a /run/secrets/docker/config.json)" = 444
if (printf x >>/run/secrets/docker/config.json) 2>/dev/null; then
    exit 1
fi
config_sha256="$(tr -d '[:space:]' </run/secrets/docker/config.json | sha256sum | awk '{print $1}')"
test "$config_sha256" = "$EXPECTED_CONFIG_SHA256"
docker version --format '{{.Server.Version}}'
inventory="$(docker ps --no-trunc --format '{{.ID}}')"
if ! grep -Fx "$EXPECTED_CONTAINER_ID" <<EOF >/dev/null
$inventory
EOF
then
    printf 'expected Docker API inventory to contain %s; observed:\n%s\n' \
        "$EXPECTED_CONTAINER_ID" "$inventory" >&2
    exit 1
fi
external_inventory="$(docker ps --no-trunc --format '{{.Names}}')"
if ! grep -Fx "$EXPECTED_EXTERNAL_CONTAINER_NAME" <<EOF >/dev/null
$external_inventory
EOF
then
    printf 'expected Docker API inventory to contain external canary %s; observed:\n%s\n' \
        "$EXPECTED_EXTERNAL_CONTAINER_NAME" "$external_inventory" >&2
    exit 1
fi
SCRIPT
    cat >"$OPT_OUT_PROBE" <<'SCRIPT'
set -eu
test ! -S /var/run/docker.sock
test ! -e /run/secrets/docker/config.json
test -z "${DOCKER_CONFIG+x}"
SCRIPT
    cat >"$ONE_OFF_PROBE" <<'SCRIPT'
set -eu
test -S /var/run/docker.sock
test "$(stat -c %u:%g:%a /var/run/docker.sock)" = 0:991:660
test "${DOCKER_CONFIG:-}" = /run/secrets/docker
test -r /run/secrets/docker/config.json
test "$(stat -c %a /run/secrets/docker/config.json)" = 444
if (printf x >>/run/secrets/docker/config.json) 2>/dev/null; then
    exit 1
fi
config_sha256="$(tr -d '[:space:]' </run/secrets/docker/config.json | sha256sum | awk '{print $1}')"
test "$config_sha256" = "$EXPECTED_CONFIG_SHA256"
docker version >/dev/null
inventory="$(docker ps --no-trunc --format '{{.ID}}')"
if ! grep -Fx "$EXPECTED_CONTAINER_ID" <<EOF >/dev/null
$inventory
EOF
then
    printf 'expected Docker API inventory to contain %s; observed:\n%s\n' \
        "$EXPECTED_CONTAINER_ID" "$inventory" >&2
    exit 1
fi
external_inventory="$(docker ps --no-trunc --format '{{.Names}}')"
if ! grep -Fx "$EXPECTED_EXTERNAL_CONTAINER_NAME" <<EOF >/dev/null
$external_inventory
EOF
then
    printf 'expected Docker API inventory to contain external canary %s; observed:\n%s\n' \
        "$EXPECTED_EXTERNAL_CONTAINER_NAME" "$external_inventory" >&2
    exit 1
fi
SCRIPT
    chmod 600 "$CLIENT_PROBE" "$OPT_OUT_PROBE" "$ONE_OFF_PROBE"
}

assert_client_access() {
    local service="$1"
    local expected_uid="$2"
    local expected_gid="$3"
    local expected_api_id="$4"
    local result_variable="${5:-}"
    local observed_server_version
    capture_command_with_input observed_server_version "$service-version" "$CLIENT_PROBE" \
        "${COMPOSE_COMMAND[@]}" exec -T \
        --env "EXPECTED_UID=$expected_uid" --env "EXPECTED_GID=$expected_gid" \
        --env "EXPECTED_CONFIG_SHA256=$EXPECTED_CONFIG_SHA256" \
        --env "EXPECTED_CONTAINER_ID=$expected_api_id" \
        --env "EXPECTED_EXTERNAL_CONTAINER_NAME=$CANARY_NATIVE_ID" \
        "$service" sh
    [[ -n "$observed_server_version" ]] || {
        error "$service returned an empty Docker server version"
        return 1
    }
    if [[ -n "$result_variable" ]]; then
        printf -v "$result_variable" '%s' "$observed_server_version"
    fi
}

assert_opt_out() {
    run_command_with_input opt-out "$OPT_OUT_PROBE" \
        "${COMPOSE_COMMAND[@]}" exec -T opt-out sh
}

assert_ids_absent() {
    local inventory id
    capture_command inventory native-inventory "$CONTAINER_BINARY" list --all --format json
    for id in "$@"; do
        [[ -n "$id" ]] || continue
        jq -e --arg id "$id" 'all(.[]; .id != $id)' <<<"$inventory" >/dev/null \
            || {
                error "Container retained removed Compose object $id"
                return 1
            }
    done
}

assert_native_id_present() {
    local native_id="$1"
    local inventory
    capture_command inventory native-canary-inventory "$CONTAINER_BINARY" list --all --format json
    jq -e --arg id "$native_id" 'any(.[]; .id == $id)' <<<"$inventory" >/dev/null \
        || {
            error "independent native canary is absent: $native_id"
            return 1
        }
}

capture_native_creation_date() {
    local result_variable="$1"
    local label="$2"
    local native_id="$3"
    local inventory creation_date
    capture_command inventory "$label-inventory" "$CONTAINER_BINARY" list --all --format json
    creation_date="$(jq -er --arg id "$native_id" '
        [.[] | select(.id == $id) | .configuration.creationDate]
        | if length == 1 and .[0] != null then .[0] else error("missing unique native container creation date") end
    ' <<<"$inventory")" || {
        error "could not resolve a unique creation date for native container $native_id"
        return 1
    }
    printf -v "$result_variable" '%s' "$creation_date"
}

assert_project_resources_absent() {
    local kind names
    for kind in network volume; do
        capture_command names "native-$kind-names" "$CONTAINER_BINARY" "$kind" list --quiet
        if awk -v project="$PROJECT" \
            '$0 == project || index($0, project "_") == 1 || index($0, project "-") == 1 { found = 1 } END { exit found ? 0 : 1 }' \
            <<<"$names"
        then
            error "Container retained a $kind owned by Compose project $PROJECT"
            return 1
        fi
    done
}

write_evidence() {
    local compose_version="$1"
    local container_version="$2"
    local server_version="$3"
    local evidence_directory evidence_temp
    evidence_directory="$(dirname "$EVIDENCE_OUTPUT")"
    mkdir -p "$evidence_directory"
    evidence_temp="$(mktemp "$evidence_directory/.api-socket-client-evidence.XXXXXX")"
    if ! jq -n \
        --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg project "$PROJECT" \
        --arg image "$CLIENT_IMAGE" \
        --arg composeVersion "$compose_version" \
        --arg containerVersion "$container_version" \
        --arg serverVersion "$server_version" \
        --argjson durationSeconds "$((SECONDS - START_SECONDS))" \
        '{schemaVersion:1, generatedAt:$generatedAt, project:$project, clientImage:$image, composeVersion:$composeVersion, containerVersion:$containerVersion, engineServerVersion:$serverVersion, durationSeconds:$durationSeconds, rootClient:true, nonRootClient:true, credentialReadable:true, credentialImmutable:true, credentialOutput:false, dockerAPIInventoryBoundToCompose:true, outOfProjectDiscovery:true, restart:true, recreate:true, recreatedNativeGeneration:true, oneOffRun:true, stoppedClientRevoked:true, removedObjectsAbsent:true, networkResidueAbsent:true, volumeResidueAbsent:true, optOutUnmodified:true, externalCanaryPreserved:true, materializedCredentialsRemoved:true}' \
        >"$evidence_temp"
    then
        rm -f -- "$evidence_temp"
        return 1
    fi
    mv -f -- "$evidence_temp" "$EVIDENCE_OUTPUT"
}

main() {
    local compose_version container_version root_version
    local root_public_id nonroot_public_id opt_out_public_id
    local root_api_id nonroot_api_id opt_out_api_id
    local root_creation_date nonroot_creation_date
    local restarted_root_creation_date restarted_nonroot_creation_date
    local recreated_root_public_id recreated_nonroot_public_id
    local recreated_root_api_id recreated_nonroot_api_id
    local recreated_root_creation_date recreated_nonroot_creation_date
    local ids_before_run ids_after_run remaining config_paths

    parse_args "$@"
    resolve_command_paths
    prepare_local_work_root
    check_prerequisites
    PROOF_STARTED=1
    if [[ -e "$EVIDENCE_OUTPUT" || -L "$EVIDENCE_OUTPUT" ]]; then
        rm -f -- "$EVIDENCE_OUTPUT"
    fi
    PROJECT="cc-api-socket-${RANDOM}-$$"
    CANARY_NATIVE_ID="cc-api-socket-canary-${RANDOM}-$$"
    COMPOSE_FILE="$WORK_ROOT/compose.yml"
    TRANSCRIPT="$WORK_ROOT/transcript.log"
    touch "$TRANSCRIPT"
    chmod 600 "$TRANSCRIPT"
    write_fixture

    export DOCKER_AUTH_CONFIG="{\"auths\":{\"proof.invalid\":{\"auth\":\"$AUTH_VALUE\",\"identitytoken\":\"$AUTH_SENTINEL\"}}}"
    EXPECTED_CONFIG_SHA256="$(printf '%s' "$DOCKER_AUTH_CONFIG" | shasum -a 256 | awk '{print $1}')"
    COMPOSE_COMMAND=("$CONTAINER_COMPOSE" --ansi never --progress quiet --project-name "$PROJECT" --file "$COMPOSE_FILE")

    CURRENT_PHASE="version inspection"
    capture_command compose_version compose-version "$CONTAINER_COMPOSE" version
    capture_command container_version container-version "$CONTAINER_BINARY" --version
    CURRENT_PHASE="independent canary startup"
    run_command native-canary "$CONTAINER_BINARY" run --detach \
        --name "$CANARY_NATIVE_ID" --network none --entrypoint sh \
        "$CLIENT_IMAGE" -c 'sleep 900'
    assert_native_id_present "$CANARY_NATIVE_ID"
    CURRENT_PHASE="initial startup"
    run_command up "${COMPOSE_COMMAND[@]}" up --detach --pull never root-client nonroot-client opt-out
    CURRENT_PHASE="initial identity capture"
    capture_command root_public_id root-id "${COMPOSE_COMMAND[@]}" ps --quiet root-client
    capture_command nonroot_public_id nonroot-id "${COMPOSE_COMMAND[@]}" ps --quiet nonroot-client
    capture_command opt_out_public_id opt-out-id "${COMPOSE_COMMAND[@]}" ps --quiet opt-out
    capture_command root_api_id root-api-id \
        "${COMPOSE_COMMAND[@]}" ps --no-trunc --format '{{.Name}}' root-client
    capture_command nonroot_api_id nonroot-api-id \
        "${COMPOSE_COMMAND[@]}" ps --no-trunc --format '{{.Name}}' nonroot-client
    capture_command opt_out_api_id opt-out-api-id \
        "${COMPOSE_COMMAND[@]}" ps --no-trunc --format '{{.Name}}' opt-out
    if [[ -z "$root_public_id" || -z "$nonroot_public_id" || -z "$opt_out_public_id" \
        || "$root_public_id" == "$nonroot_public_id" || "$root_public_id" == "$opt_out_public_id" \
        || "$nonroot_public_id" == "$opt_out_public_id" ]]; then
        error "expected three distinct non-empty service IDs"
        return 1
    fi
    if [[ -z "$root_api_id" || -z "$nonroot_api_id" || -z "$opt_out_api_id" \
        || "$root_api_id" == "$nonroot_api_id" || "$root_api_id" == "$opt_out_api_id" \
        || "$nonroot_api_id" == "$opt_out_api_id" ]]; then
        error "expected three distinct non-empty Compose API identities"
        return 1
    fi
    SEEN_NATIVE_IDS+=("$root_api_id" "$nonroot_api_id" "$opt_out_api_id")
    capture_native_creation_date root_creation_date initial-root "$root_api_id"
    capture_native_creation_date nonroot_creation_date initial-nonroot "$nonroot_api_id"
    CURRENT_PHASE="initial client access"
    assert_client_access root-client 0 0 "$root_api_id" root_version
    assert_client_access nonroot-client 1000 991 "$nonroot_api_id"
    assert_opt_out

    CURRENT_PHASE="credential materialization"
    config_paths="$(compose_config_directories)"
    [[ "$(sed '/^$/d' <<<"$config_paths" | wc -l | tr -d ' ')" == 1 ]] || {
        error "expected exactly one materialized credential directory for $PROJECT"
        return 1
    }

    CURRENT_PHASE="restart"
    run_command restart "${COMPOSE_COMMAND[@]}" restart root-client nonroot-client
    assert_client_access root-client 0 0 "$root_api_id"
    assert_client_access nonroot-client 1000 991 "$nonroot_api_id"
    capture_native_creation_date restarted_root_creation_date restarted-root "$root_api_id"
    capture_native_creation_date restarted_nonroot_creation_date restarted-nonroot "$nonroot_api_id"
    if [[ "$restarted_root_creation_date" != "$root_creation_date" \
        || "$restarted_nonroot_creation_date" != "$nonroot_creation_date" ]]; then
        error "restart replaced a native container generation"
        return 1
    fi

    CURRENT_PHASE="force recreation"
    run_command recreate "${COMPOSE_COMMAND[@]}" up --detach --force-recreate --pull never root-client nonroot-client
    capture_command recreated_root_public_id recreated-root-id "${COMPOSE_COMMAND[@]}" ps --quiet root-client
    capture_command recreated_nonroot_public_id recreated-nonroot-id "${COMPOSE_COMMAND[@]}" ps --quiet nonroot-client
    capture_command recreated_root_api_id recreated-root-api-id \
        "${COMPOSE_COMMAND[@]}" ps --no-trunc --format '{{.Name}}' root-client
    capture_command recreated_nonroot_api_id recreated-nonroot-api-id \
        "${COMPOSE_COMMAND[@]}" ps --no-trunc --format '{{.Name}}' nonroot-client
    if [[ -z "$recreated_root_public_id" || -z "$recreated_nonroot_public_id" \
        || "$recreated_root_public_id" == "$recreated_nonroot_public_id" \
        || -z "$recreated_root_api_id" || -z "$recreated_nonroot_api_id" \
        || "$recreated_root_api_id" == "$recreated_nonroot_api_id" ]]; then
        error "force recreation did not return two distinct addressable containers"
        return 1
    fi
    capture_native_creation_date recreated_root_creation_date recreated-root "$recreated_root_api_id"
    capture_native_creation_date recreated_nonroot_creation_date recreated-nonroot "$recreated_nonroot_api_id"
    if [[ "$recreated_root_creation_date" == "$restarted_root_creation_date" \
        || "$recreated_nonroot_creation_date" == "$restarted_nonroot_creation_date" ]]; then
        error "force recreation retained a native container generation"
        return 1
    fi
    SEEN_NATIVE_IDS+=("$recreated_root_api_id" "$recreated_nonroot_api_id")
    assert_client_access root-client 0 0 "$recreated_root_api_id"
    assert_client_access nonroot-client 1000 991 "$recreated_nonroot_api_id"

    CURRENT_PHASE="one-off run"
    capture_command ids_before_run ids-before-run "${COMPOSE_COMMAND[@]}" ps --all --quiet
    run_command_with_input one-off "$ONE_OFF_PROBE" \
        "${COMPOSE_COMMAND[@]}" run --rm --pull never \
        --env "EXPECTED_CONFIG_SHA256=$EXPECTED_CONFIG_SHA256" \
        --env "EXPECTED_CONTAINER_ID=$recreated_root_api_id" \
        --env "EXPECTED_EXTERNAL_CONTAINER_NAME=$CANARY_NATIVE_ID" \
        root-client sh
    capture_command ids_after_run ids-after-run "${COMPOSE_COMMAND[@]}" ps --all --quiet
    if [[ "$(sort <<<"$ids_before_run")" != "$(sort <<<"$ids_after_run")" ]]; then
        error "one-off --rm retained a Compose object"
        return 1
    fi

    CURRENT_PHASE="stop and start"
    run_command stop "${COMPOSE_COMMAND[@]}" stop root-client nonroot-client
    expect_stopped_exec_failure stopped-exec "$recreated_root_api_id" \
        "${COMPOSE_COMMAND[@]}" exec -T root-client docker version
    run_command start "${COMPOSE_COMMAND[@]}" start root-client nonroot-client
    assert_client_access root-client 0 0 "$recreated_root_api_id"
    assert_client_access nonroot-client 1000 991 "$recreated_nonroot_api_id"

    CURRENT_PHASE="service removal"
    run_command remove-root "${COMPOSE_COMMAND[@]}" rm --stop --force root-client
    capture_command remaining remaining-root "${COMPOSE_COMMAND[@]}" ps --all --quiet root-client
    if [[ -n "$remaining" ]]; then
        error "removed root-client remains in the Compose inventory"
        return 1
    fi
    assert_ids_absent "$recreated_root_api_id"

    CURRENT_PHASE="project teardown"
    run_command down "${COMPOSE_COMMAND[@]}" down --remove-orphans
    assert_ids_absent "${SEEN_NATIVE_IDS[@]}"
    assert_project_resources_absent
    assert_native_id_present "$CANARY_NATIVE_ID"
    run_command remove-native-canary "$CONTAINER_BINARY" delete --force "$CANARY_NATIVE_ID"
    assert_ids_absent "$CANARY_NATIVE_ID"
    remaining="$(compose_config_directories)"
    [[ -z "$remaining" ]] || {
        error "materialized API socket credentials remain after down"
        return 1
    }
    assert_no_secret_output "$TRANSCRIPT"
    write_evidence "$compose_version" "$container_version" "$root_version"
    PROOF_COMPLETE=1
    CURRENT_PHASE="complete"
    info "Compose API socket client proof passed: $EVIDENCE_OUTPUT"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
