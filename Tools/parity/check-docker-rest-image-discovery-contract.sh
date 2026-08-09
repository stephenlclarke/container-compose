#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
# Licensed under the Apache License, Version 2.0.
#===----------------------------------------------------------------------===#

# Exercise Docker ImageList and ImageInspect through an unmodified Docker CLI.
# The fixture is read-only: both lanes use the preloaded Alpine index, and the
# candidate additionally proves that Container's native image catalog owns it.

set -euo pipefail

readonly REQUIRED_CLI_VERSION="29.7.1"
readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly REQUIRED_DISPLAY_IMAGE="alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-image-discovery-root"

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
NATIVE_CLI=""
WORK_ROOT=""

info() {
    printf '%s\n' "$*"
}

fail() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

skip_or_fail() {
    local message="$1"

    if ((STRICT == 1)); then
        fail "$message"
        return 1
    fi
    printf 'warning: %s; skipping Docker REST image discovery contract\n' \
        "$message" >&2
    exit 0
}

usage() {
    printf '%s\n' \
        'usage: check-docker-rest-image-discovery-contract.sh [options]' \
        '  --host HOST        Docker endpoint, such as unix:///tmp/docker.sock' \
        '  --native-cli PATH  Container CLI for shared-authority proof' \
        '  --reference        Require Docker Engine 29.2.1' \
        '  --strict           Fail instead of skipping prerequisites'
}

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

run_docker() {
    if [[ -n "$DOCKER_HOST_OVERRIDE" ]]; then
        env -u DOCKER_API_VERSION DOCKER_HOST="$DOCKER_HOST_OVERRIDE" docker "$@"
    else
        env -u DOCKER_API_VERSION -u DOCKER_HOST docker "$@"
    fi
}

cleanup() {
    local temporary_parent="${TMPDIR:-/tmp}"

    if [[ -n "$WORK_ROOT" \
        && "$WORK_ROOT" == "$temporary_parent"/container-rest-image-discovery.* \
        && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
}

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
    run_docker image inspect "$REQUIRED_IMAGE" >/dev/null 2>&1 \
        || skip_or_fail "image is not preloaded: $REQUIRED_IMAGE"
    if [[ -n "$NATIVE_CLI" && ! -x "$NATIVE_CLI" ]]; then
        skip_or_fail "native Container CLI is not executable: $NATIVE_CLI"
    fi
}

assert_image_list() {
    local listing
    local image_id
    local image_digest

    listing="$(run_docker image ls \
        --filter "reference=$REQUIRED_DISPLAY_IMAGE" \
        --no-trunc \
        --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Digest}}')"
    [[ "$(wc -l <<<"$listing" | tr -d ' ')" == "1" ]] \
        || fail "image listing did not return exactly one Alpine tag: $listing"
    IFS='|' read -r repository tag image_id image_digest <<<"$listing"
    [[ "$repository:$tag" == "$REQUIRED_DISPLAY_IMAGE" ]] \
        || fail "image listing returned the wrong reference: $listing"
    [[ "$image_id" == sha256:* && "$image_digest" == "$image_id" ]] \
        || fail "image listing did not preserve the OCI index digest: $listing"
}

assert_image_inspect() {
    local inspect_json

    inspect_json="$(run_docker image inspect "$REQUIRED_DISPLAY_IMAGE")"
    jq -e --arg image "$REQUIRED_DISPLAY_IMAGE" '
        .[0] as $item
        | length == 1
        and ($item.Id | startswith("sha256:"))
        and $item.Architecture == "arm64"
        and $item.Variant == "v8"
        and $item.Os == "linux"
        and ($item.RepoTags | index($image) != null)
        and ($item.RepoDigests[0] | endswith("@" + $item.Id))
        and $item.Descriptor.digest == $item.Id
        and $item.Descriptor.size > 0
        and $item.RootFS.Type == "layers"
        and ($item.RootFS.Layers | length) > 0
        and ($item.Config.Cmd | type) == "array"
        and $item.Size > 0
    ' <<<"$inspect_json" >/dev/null \
        || fail "Docker image inspect response is incomplete or incompatible"
}

assert_missing_image() {
    local error_file="$WORK_ROOT/missing-image.stderr"

    if run_docker image inspect container-compose-does-not-exist:latest \
        >/dev/null 2>"$error_file"; then
        fail "missing image inspect unexpectedly succeeded"
        return 1
    fi
    grep -F 'No such image: container-compose-does-not-exist:latest' \
        "$error_file" >/dev/null \
        || fail "missing image inspect did not preserve Docker's error"
}

assert_native_authority() {
    [[ -n "$NATIVE_CLI" ]] || return 0

    local inventory
    inventory="$("$NATIVE_CLI" image list --format json)"
    jq -e --arg image "$REQUIRED_IMAGE" '
        ([.[] | select(.configuration.name == $image)] | length) == 1
        and ([.[] | select(.configuration.name == $image)][0]
            .configuration.descriptor.digest | startswith("sha256:"))
    ' <<<"$inventory" >/dev/null \
        || fail "native authority does not expose exactly one preloaded Alpine image"
}

main() {
    parse_args "$@"
    verify_prerequisites
    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-image-discovery.XXXXXX")"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"

    assert_image_list
    assert_image_inspect
    assert_missing_image
    assert_native_authority
    info "Docker REST image discovery contract passed"
}

trap cleanup EXIT
main "$@"
