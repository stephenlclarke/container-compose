#!/usr/bin/env bash
#===----------------------------------------------------------------------===#
# Copyright © 2026 container-compose project authors.
# Licensed under the Apache License, Version 2.0.
#===----------------------------------------------------------------------===#

# Exercise Docker SystemVersion and ContainerList through an unmodified Docker
# CLI. The same fixture runs against the pinned Docker oracle and Container's
# public Unix socket, and proves that native Container sees the same objects.

set -euo pipefail

readonly REQUIRED_ENGINE_VERSION="29.2.1"
readonly REQUIRED_IMAGE="docker.io/library/alpine:3.20"
readonly ROOT_MARKER_NAME=".container-rest-discovery-root"

STRICT=0
REFERENCE=0
DOCKER_HOST_OVERRIDE=""
NATIVE_CLI=""
WORK_ROOT=""
CONTAINER_NAMES=()

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
    printf 'warning: %s; skipping Docker REST discovery contract\n' "$message" >&2
    exit 0
}

usage() {
    printf '%s\n' \
        'usage: check-docker-rest-discovery-contract.sh [options]' \
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

remove_test_containers() {
    local name

    for name in "${CONTAINER_NAMES[@]}"; do
        run_docker rm --force "$name" >/dev/null 2>&1 || true
    done
}

cleanup() {
    local temporary_parent="${TMPDIR:-/tmp}"

    remove_test_containers
    if [[ -n "$WORK_ROOT" && "$WORK_ROOT" == "$temporary_parent"/container-rest-discovery.* \
        && -f "$WORK_ROOT/$ROOT_MARKER_NAME" ]]; then
        rm -rf -- "$WORK_ROOT"
    fi
}

verify_prerequisites() {
    command -v docker >/dev/null 2>&1 || skip_or_fail "docker CLI is unavailable"
    command -v jq >/dev/null 2>&1 || skip_or_fail "jq is unavailable"
    run_docker info >/dev/null 2>&1 || skip_or_fail "Docker endpoint is unavailable"
    if ((REFERENCE == 1)); then
        local version
        version="$(run_docker version --format '{{.Server.Version}}')"
        [[ "$version" == "$REQUIRED_ENGINE_VERSION" ]] \
            || fail "Docker reference version is $version, expected $REQUIRED_ENGINE_VERSION"
        run_docker image inspect "$REQUIRED_IMAGE" >/dev/null 2>&1 \
            || skip_or_fail "reference image is not preloaded: $REQUIRED_IMAGE"
    fi
    if [[ -n "$NATIVE_CLI" && ! -x "$NATIVE_CLI" ]]; then
        skip_or_fail "native Container CLI is not executable: $NATIVE_CLI"
    fi
}

wait_for_state() {
    local name="$1"
    local expected="$2"
    local observed=""
    local attempt

    for ((attempt = 0; attempt < 120; attempt += 1)); do
        observed="$(run_docker container inspect --format '{{.State.Status}}' "$name")"
        [[ "$observed" == "$expected" ]] && return 0
        sleep 0.25
    done
    fail "$name did not reach $expected; last state was $observed"
}

assert_native_authority() {
    [[ -n "$NATIVE_CLI" ]] || return 0

    local inventory
    local name
    inventory="$("$NATIVE_CLI" list --all --format json)"
    for name in "${CONTAINER_NAMES[@]}"; do
        jq -e --arg name "$name" \
            '([.[] | select(.id == $name)] | length) == 1' \
            <<<"$inventory" >/dev/null \
            || fail "native authority does not expose exactly one $name"
    done
}

assert_exact_listing() {
    local created_name="$1"
    local exited_name="$2"
    local running_name="$3"
    local expected
    local actual

    expected="$(printf '%s\n' \
        "$created_name|created|Created" \
        "$exited_name|exited|Exited (7)" \
        "$running_name|running|Up" | sort)"
    actual="$(run_docker ps --all \
        --filter label=container-compose.contract=discovery \
        --format '{{.Names}}|{{.State}}|{{.Status}}' \
        | sed -E 's/\|Exited \(7\).*/|Exited (7)/; s/\|Up .*/|Up/' \
        | sort)"
    [[ "$actual" == "$expected" ]] || fail "all-container listing mismatch: $actual"

    actual="$(run_docker ps \
        --filter label=container-compose.contract=discovery \
        --format '{{.Names}}|{{.State}}')"
    [[ "$actual" == "$running_name|running" ]] \
        || fail "default listing did not contain only the running container: $actual"

    actual="$(run_docker ps --all \
        --filter label=container-compose.contract=discovery \
        --filter status=exited --format '{{.Names}}|{{.State}}')"
    [[ "$actual" == "$exited_name|exited" ]] \
        || fail "status and label filters did not select the exited container: $actual"

    actual="$(run_docker ps --all --filter name="^/${created_name}$" \
        --format '{{.Names}}|{{.State}}')"
    [[ "$actual" == "$created_name|created" ]] \
        || fail "name filter did not select the created container: $actual"
}

assert_cleanup() {
    local name
    local listed

    for name in "${CONTAINER_NAMES[@]}"; do
        run_docker rm --force "$name" >/dev/null
    done
    listed="$(run_docker ps --all \
        --filter label=container-compose.contract=discovery \
        --format '{{.Names}}')"
    [[ -z "$listed" ]] || fail "discovery containers remain after cleanup: $listed"
    if [[ -n "$NATIVE_CLI" ]]; then
        local inventory
        inventory="$("$NATIVE_CLI" list --all --format json)"
        for name in "${CONTAINER_NAMES[@]}"; do
            jq -e --arg name "$name" 'all(.[]; .id != $name)' \
                <<<"$inventory" >/dev/null \
                || fail "native authority retained deleted container $name"
        done
    fi
    CONTAINER_NAMES=()
}

main() {
    local suffix
    local created_name
    local exited_name
    local running_name
    local version_json

    parse_args "$@"
    verify_prerequisites
    WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-rest-discovery.XXXXXX")"
    touch "$WORK_ROOT/$ROOT_MARKER_NAME"
    suffix="$(basename "$WORK_ROOT" | tr '.[:upper:]' '-[:lower:]')"
    created_name="cc-rest-created-$suffix"
    exited_name="cc-rest-exited-$suffix"
    running_name="cc-rest-running-$suffix"
    CONTAINER_NAMES=("$created_name" "$exited_name" "$running_name")

    version_json="$(run_docker version --format '{{json .Server}}')"
    jq -e \
        '.ApiVersion == "1.53" and .MinAPIVersion == "1.44" and .Os == "linux" and .Arch == "arm64" and (.Version | length > 0)' \
        <<<"$version_json" >/dev/null \
        || fail "Docker version response is incomplete or incompatible: $version_json"

    run_docker create --name "$created_name" \
        --label container-compose.contract=discovery --label role=created \
        "$REQUIRED_IMAGE" /bin/sh -c 'printf created' >/dev/null
    run_docker create --name "$exited_name" \
        --label container-compose.contract=discovery --label role=exited \
        "$REQUIRED_IMAGE" /bin/sh -c 'exit 7' >/dev/null
    run_docker start "$exited_name" >/dev/null
    wait_for_state "$exited_name" exited
    run_docker create --name "$running_name" \
        --label container-compose.contract=discovery --label role=running \
        "$REQUIRED_IMAGE" /bin/sh -c 'while :; do sleep 1; done' >/dev/null
    run_docker start "$running_name" >/dev/null
    wait_for_state "$running_name" running

    assert_exact_listing "$created_name" "$exited_name" "$running_name"
    assert_native_authority
    assert_cleanup
    info "Docker REST discovery contract passed"
}

trap cleanup EXIT
main "$@"
