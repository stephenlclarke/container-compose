# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
# Opt-in native graph. No legacy Makefile parsing or signing/keychain discovery.
override SHELL := /bin/bash -p -euo pipefail
.DEFAULT_GOAL := help
BAZEL_PROFILE ?= enhanced
export BAZEL_PROFILE
export FAMILY_BAZEL_LAUNCHER
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
export ROOT

.PHONY: help check-launcher build test-spi test-cli
help:
	@printf 'Set FAMILY_BAZEL_LAUNCHER to the locked family run.sh. Targets: build, test-spi, test-cli. BAZEL_PROFILE=stock|enhanced.\n'

check-launcher:
	@test -n "$${FAMILY_BAZEL_LAUNCHER:-}" -a -f "$${FAMILY_BAZEL_LAUNCHER:-}" || { printf 'Set FAMILY_BAZEL_LAUNCHER to the reviewed shared launcher.\n' >&2; exit 2; }
	@case "$$BAZEL_PROFILE" in stock|enhanced) ;; *) printf 'BAZEL_PROFILE must be stock or enhanced.\n' >&2; exit 2 ;; esac

build: check-launcher
	@"$$FAMILY_BAZEL_LAUNCHER" --workspace "$$ROOT" build --config="$$BAZEL_PROFILE" //:product

test-spi: check-launcher
	@"$$FAMILY_BAZEL_LAUNCHER" --workspace "$$ROOT" test --config="$$BAZEL_PROFILE" //:ComposeRuntimeSPITests

test-cli: check-launcher
	@"$$FAMILY_BAZEL_LAUNCHER" --workspace "$$ROOT" test --config="$$BAZEL_PROFILE" //Tools/bazel:cli_smoke
