#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
# Licensed under the Apache License, Version 2.0.
#===----------------------------------------------------------------------===#

# Exercise Docker ImageCreate, ImageTag, and ImageDelete through an unmodified
# Docker CLI. The unique secondary tag is always removed; the pinned Alpine
# source image must retain the same OCI index identity throughout.

set -euo pipefail

readonly REQUIRED_CLI_VERSION="29.7.1"
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly REQUIRED_DISPLAY_IMAGE="alpine:3.20"
readonly REQUIRED_DIGEST="sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
readonly MUTATION_IMAGE="container-compose-image-mutation-contract:20260805"
readonly ROOT_MARKER_NAME=".container-rest-image-mutation-root"

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
NATIVE_CLI=""
WORK_ROOT=""

# Print a progress message.
info() {
    printf '%s\n' "$*"
}

# Report a contract failure.
fail() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

# Skip an unavailable optional contract or fail in strict mode.
skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        fail "$message"
        return 1
    fi
    printf 'warning: %s; skipping Docker REST image mutation contract\n' \
        "$message" >&2
    exit 0
}

# Print command usage.
usage() {
    printf '%s\n' \
        'usage: check-docker-rest-image-mutation-contract.sh [options]' \
        '  --host HOST        Docker endpoint, such as unix:///tmp/docker.sock' \
        '  --native-cli PATH  Container CLI for shared-authority proof' \
        '  --reference        Require Docker Engine 29.2.1' \
        '  --strict           Fail instead of skipping prerequisites'
}

# Parse command-line options.
parse_args() {
    while (($# > 0)); do
        case "$1" in
            --host)
                [[ $# -ge 2 && -n "$2" ]] || return 2
                DOCKER_HOST_OVERRIDE="$2"
                shift 2
                ;;
            --native-cli)
                [[ $# -ge 2 && -n "$2" ]] || return 2
                NATIVE_CLI="$2"
                shift 2
                ;;
            --reference)
                REFERENCE=1
                shift
                ;;
            --strict)
                STRICT=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                fail "unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
}

# Resolve the user's selected Docker context before isolating client credentials.
resolve_reference_host() {
    ((REFERENCE == 1)) || return 0
    [[ -z "$DOCKER_HOST_OVERRIDE" ]] || return 0

    local context_name
    context_name="$(env -u DOCKER_API_VERSION docker context show)"
    DOCKER_HOST_OVERRIDE="$(
        env -u DOCKER_API_VERSION docker context inspect \
            --format '{{.Endpoints.docker.Host}}' \
            "$context_name"
    )"
    [[ -n "$DOCKER_HOST_OVERRIDE" ]] \
        || fail "Docker context $context_name has no endpoint"
}

# Invoke the pinned Docker CLI with isolated client configuration.
run_docker() {
    if [[ -n "$DOCKER_HOST_OVERRIDE" ]]; then
        env -u DOCKER_API_VERSION \
            "DOCKER_CONFIG=$WORK_ROOT/docker-config" \
            "DOCKER_HOST=$DOCKER_HOST_OVERRIDE" \
            docker "$@"
    else
        env -u DOCKER_API_VERSION -u DOCKER_HOST \
            "DOCKER_CONFIG=$WORK_ROOT/docker-config" \
            docker "$@"
    fi
}

# Remove only the marker-protected fixture root and unique test tag.
cleanup() {
    local temporary_parent="${TMPDIR:-/tmp}"

    if [[ -n "$WORK_ROOT" && -d "$WORK_ROOT" ]]; then
        run_docker image rm --force "$MUTATION_IMAGE" >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_ROOT" \
        && "$WORK_ROOT" == "$temporary_parent"/container-rest-image-mutation.* \
        && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
}

# Verify the exact Docker client, reference daemon, and native CLI inputs.
verify_prerequisites() {
    local cli_version
    local engine_version

    command -v docker >/dev/null 2>&1 || skip_or_fail "docker CLI is unavailable"
    command -v jq >/dev/null 2>&1 || skip_or_fail "jq is unavailable"
    run_docker info >/dev/null 2>&1 || skip_or_fail "Docker endpoint is unavailable"
    cli_version="$(run_docker version --format '{{.Client.Version}}')"
    [[ "$cli_version" == "$REQUIRED_CLI_VERSION" ]] \
        || fail "Docker CLI version is $cli_version, expected $REQUIRED_CLI_VERSION"
    if ((REFERENCE == 1)); then
        engine_version="$(run_docker version --format '{{.Server.Version}}')"
        [[ "$engine_version" == "$REQUIRED_ENGINE_VERSION" ]] \
            || fail "Docker reference version is $engine_version, expected $REQUIRED_ENGINE_VERSION"
    fi
    if [[ -n "$NATIVE_CLI" && ! -x "$NATIVE_CLI" ]]; then
        skip_or_fail "native Container CLI is not executable: $NATIVE_CLI"
    fi
    if run_docker image inspect "$MUTATION_IMAGE" >/dev/null 2>&1; then
        fail "mutation fixture tag already exists: $MUTATION_IMAGE"
    fi
}

# Return the Docker image identifier for one reference.
image_id() {
    run_docker image inspect "$1" --format '{{.Id}}'
}

# Prove the Docker reference is projected from native Container authority.
assert_native_reference() {
    local reference="$1"
    local expected_count="$2"
    [[ -n "$NATIVE_CLI" ]] || return 0

    local inventory
    inventory="$("$NATIVE_CLI" image list --format json)"
    jq -e \
        --arg reference "$reference" \
        --arg digest "${REQUIRED_DIGEST#sha256:}" \
        --argjson expected "$expected_count" '
        ([.[] | select(
            .configuration.name == $reference
            and .configuration.descriptor.digest == ("sha256:" + $digest)
        )] | length) == $expected
    ' <<<"$inventory" >/dev/null \
        || fail "native authority reference count differs for $reference"
}

# Pull the pinned public image and prove its index digest and native identity.
assert_pull() {
    local output_file="$WORK_ROOT/pull.stdout"

    run_docker pull --platform linux/arm64/v8 "$REQUIRED_IMAGE" \
        >"$output_file"
    grep -F "Digest: $REQUIRED_DIGEST" "$output_file" >/dev/null \
        || fail "pull output omitted the pinned digest"
    grep -F 'Status:' "$output_file" >/dev/null \
        || fail "pull output omitted Docker status"
    [[ "$(image_id "$REQUIRED_IMAGE")" == "$REQUIRED_DIGEST" ]] \
        || fail "pull did not retain the pinned OCI index"
    assert_native_reference "$REQUIRED_IMAGE" 1
}

# Add and remove a secondary tag without changing the source image.
assert_tag_and_remove() {
    run_docker image tag "$REQUIRED_IMAGE" "$MUTATION_IMAGE"
    [[ "$(image_id "$MUTATION_IMAGE")" == "$REQUIRED_DIGEST" ]] \
        || fail "tag did not preserve the source OCI index"
    assert_native_reference \
        "docker.io/library/$MUTATION_IMAGE" \
        1

    local removal_output
    removal_output="$(run_docker image rm "$MUTATION_IMAGE")"
    grep -F "Untagged: $MUTATION_IMAGE" <<<"$removal_output" >/dev/null \
        || fail "image removal omitted Docker's untagged result"
    if run_docker image inspect "$MUTATION_IMAGE" >/dev/null 2>&1; then
        fail "secondary tag remained after Docker image removal"
    fi
    [[ "$(image_id "$REQUIRED_DISPLAY_IMAGE")" == "$REQUIRED_DIGEST" ]] \
        || fail "secondary tag removal changed the source image"
    assert_native_reference \
        "docker.io/library/$MUTATION_IMAGE" \
        0
    assert_native_reference "$REQUIRED_IMAGE" 1
}

# Prove a missing deletion returns Docker's exact user-visible error.
assert_missing_delete() {
    local error_file="$WORK_ROOT/missing-delete.stderr"

    if run_docker image rm container-compose-does-not-exist:latest \
        >/dev/null 2>"$error_file"; then
        fail "missing image delete unexpectedly succeeded"
        return 1
    fi
    grep -F 'No such image: container-compose-does-not-exist:latest' \
        "$error_file" >/dev/null \
        || fail "missing image delete did not preserve Docker's error"
}

# Run the complete image-mutation contract.
main() {
    parse_args "$@"
    resolve_reference_host
    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-image-mutation.XXXXXX")"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"
    mkdir "$WORK_ROOT/docker-config"
    printf '{}\n' >"$WORK_ROOT/docker-config/config.json"
    verify_prerequisites
    assert_pull
    assert_tag_and_remove
    assert_missing_delete
    info "Docker REST image mutation contract passed"
}

trap cleanup EXIT
main "$@"
