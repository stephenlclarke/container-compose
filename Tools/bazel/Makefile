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

# Opt-in native graph. No legacy Makefile parsing or signing/keychain discovery.
override SHELL := /bin/bash -p -euo pipefail
.DEFAULT_GOAL := help
BAZEL_PROFILE ?= enhanced
export BAZEL_PROFILE
export INVOCATION
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
export ROOT

.PHONY: help check-launcher build test-spi test-cli test-unit test-go test-go-race test-asan test-tsan coverage coverage-report coverage-check package test-package restore-package
.PHONY: docs
help:
	@printf 'Uses this repository’s locked Tools/bazel/run.sh. Targets: build, test-spi, test-cli, test-unit, test-go, test-go-race, test-asan, test-tsan, coverage, coverage-report, coverage-check, package, test-package, restore-package, docs. BAZEL_PROFILE=stock|enhanced. Sanitizers instrument Swift/C; Go race and live leak checks are separate. Report/check/restore require INVOCATION=retained-id. Packages are unsigned candidates, not releases.\n'

check-launcher:
	@case "$$BAZEL_PROFILE" in stock|enhanced) ;; *) printf 'BAZEL_PROFILE must be stock or enhanced.\n' >&2; exit 2 ;; esac

build: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" build --config="$$BAZEL_PROFILE" //:product

test-spi: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" test --config="$$BAZEL_PROFILE" //:ComposeRuntimeSPITests

test-cli: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" test --config="$$BAZEL_PROFILE" //Tools/bazel:cli_smoke //Tools/bazel:cli_contracts

test-unit: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" test --config="$$BAZEL_PROFILE" "//:unit_$$BAZEL_PROFILE"

test-go: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" test --config="$$BAZEL_PROFILE" //:unit_go

test-go-race: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" test --config="$$BAZEL_PROFILE" --@rules_go//go/config:race=true //:unit_go

# The local runner retains the complete selected-profile inventory and logs.
# Bazel's Swift/C sanitizer features do not instrument the Go test binaries.
test-asan: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" test --config="$$BAZEL_PROFILE" --config=asan "//:unit_$$BAZEL_PROFILE"

test-tsan: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" test --config="$$BAZEL_PROFILE" --config=tsan "//:unit_$$BAZEL_PROFILE"

coverage: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" coverage --config="$$BAZEL_PROFILE" "//:coverage_$$BAZEL_PROFILE"

coverage-report: check-launcher
	@test -n "$${INVOCATION:-}" || { printf 'Set INVOCATION to a retained clean source coverage run.\n' >&2; exit 2; }
	@"$$ROOT/Tools/bazel/run.sh" coverage-report "$$INVOCATION"

coverage-check: check-launcher
	@test -n "$${INVOCATION:-}" || { printf 'Set INVOCATION to a retained clean source coverage run.\n' >&2; exit 2; }
	@"$$ROOT/Tools/bazel/run.sh" coverage-report "$$INVOCATION" --minimum-percent 90 --inventory=unit-cli --config="$$BAZEL_PROFILE"

package: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" build --config=release --config="$$BAZEL_PROFILE" //:candidate_archive

docs: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" test --config=release --config="$$BAZEL_PROFILE" //:documentation_tests

test-package: check-launcher
	@"$$ROOT/Tools/bazel/run.sh" test --config=release --config="$$BAZEL_PROFILE" //Tools/bazel:package_tests //Tools/bazel:package_smoke

restore-package: check-launcher
	@test -n "$${INVOCATION:-}" || { printf 'Set INVOCATION to a retained package build.\n' >&2; exit 2; }
	@"$$ROOT/Tools/bazel/run.sh" restore-candidate "$$INVOCATION"
