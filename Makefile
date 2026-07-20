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

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := all
.PHONY: upstream-divergence-report upstream-divergence-check upstream-divergence-release-check docs serve-docs

SWIFT ?= swift
SWIFT_RESOLVED_FLAGS ?= --disable-automatic-resolution
# Swift 6.3.2 can crash in release coroutine optimization on this package's
# watch loop. Size optimization avoids that toolchain crash while still
# producing a release binary; override to empty when a newer toolchain no
# longer needs the workaround.
SWIFT_RELEASE_FLAGS ?= -Xswiftc -Osize
GO ?= go
GO_RELEASE_ENV ?= CGO_ENABLED=0
GO_RELEASE_BUILD_FLAGS ?= -trimpath
GO_RELEASE_LDFLAGS ?= -s -w
PYTHON ?= python3
MARKDOWNLINT ?= markdownlint
HAWKEYE ?= $(shell command -v hawkeye 2>/dev/null || printf '%s' .local/bin/hawkeye)
SWIFT_COVERAGE_MIN ?= 90
GO_COVERAGE_MIN ?= 85
DIST_DIR ?= dist
PLUGIN_ARCHIVE ?= container-compose-plugin-release-arm64.tar.gz
PLUGIN_ICON ?= docs/images/container-compose-icon-octopus.png
DOCS_OUTPUT_DIR ?= _site
DOCS_SERVER_DIR ?= _serve
DOCS_HOSTING_BASE_PATH ?= container-compose
DOCS_SCRATCH_PATH ?= .build/docc
COMPOSE_VERSION ?= 0.7.0
CONTAINER_COMPOSE_SOURCE ?= $(shell $(PYTHON) -c 'import subprocess; result = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True); url = result.stdout.strip() if result.returncode == 0 else ""; url = url[len("git@github.com:"):] if url.startswith("git@github.com:") else url; url = url[len("https://github.com/"):] if url.startswith("https://github.com/") else url; url = url[:-4] if url.endswith(".git") else url; print(url)')
CONTAINER_COMPOSE_BRANCH ?= $(shell git branch --show-current 2>/dev/null || git rev-parse --short HEAD)
CONTAINER_COMPOSE_LANE ?= $(shell $(PYTHON) -c 'branch = "$(CONTAINER_COMPOSE_BRANCH)"; print("main" if branch == "main" else "release" if branch == "release" or branch.startswith("release-") else "detached" if branch in ("", "HEAD") else "development")')
CONTAINER_COMPOSE_COMMIT ?= $(shell git rev-parse HEAD)
CONTAINER_SOURCE ?= stephenlclarke/container
CONTAINER_REF ?= $(shell $(PYTHON) Tools/release/resolve-container-ref.py 2>/dev/null || printf 'unspecified')
CONTAINERIZATION_SOURCE ?= $(shell $(PYTHON) Tools/release/resolve-containerization-pin.py --field source 2>/dev/null || printf 'unspecified')
CONTAINERIZATION_REF ?= $(shell $(PYTHON) Tools/release/resolve-containerization-pin.py --field ref 2>/dev/null || printf 'unspecified')
COMPOSE_GO_VERSION ?= $(shell $(PYTHON) Tools/release/go-module-version.py --go-mod Tools/compose-normalizer/go.mod github.com/compose-spec/compose-go/v2 2>/dev/null || printf 'unspecified')
SONAR_QUALITYGATE_WAIT ?= false
SONAR_SCAN_ATTEMPTS ?= 3
XCODE_SELECT_DEVELOPER_DIR ?= $(shell xcode-select -p 2>/dev/null || true)
SWIFT_RUNTIME_RESOURCE_PATH ?= $(shell $(SWIFT) -print-target-info 2>/dev/null | $(PYTHON) -c 'import json, sys; print(json.load(sys.stdin).get("paths", {}).get("runtimeResourcePath", ""))' 2>/dev/null || true)
SWIFT_RUNTIME_LIBRARY_PATHS ?= $(shell $(SWIFT) -print-target-info 2>/dev/null | $(PYTHON) -c 'import json, sys; print(" ".join(json.load(sys.stdin).get("paths", {}).get("runtimeLibraryPaths", [])))' 2>/dev/null || true)
SWIFT_TOOLCHAIN_USR_DIR := $(patsubst %/lib/swift,%,$(SWIFT_RUNTIME_RESOURCE_PATH))
SWIFT_XCODE_DEVELOPER_DIR := $(patsubst %/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift,%,$(filter %/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift,$(SWIFT_RUNTIME_RESOURCE_PATH)))
SWIFT_CLT_DEVELOPER_DIR := $(patsubst %/usr/lib/swift,%,$(filter-out %/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift,$(filter %/usr/lib/swift,$(SWIFT_RUNTIME_RESOURCE_PATH))))
SWIFT_ACTIVE_DEVELOPER_DIR ?= $(firstword $(SWIFT_XCODE_DEVELOPER_DIR) $(SWIFT_CLT_DEVELOPER_DIR) $(XCODE_SELECT_DEVELOPER_DIR))
SWIFT_LLVM_COV ?= $(firstword $(wildcard $(SWIFT_TOOLCHAIN_USR_DIR)/bin/llvm-cov) $(shell xcrun --find llvm-cov 2>/dev/null || command -v llvm-cov 2>/dev/null || true))
SWIFT_LLVM_PROFDATA ?= $(firstword $(wildcard $(SWIFT_TOOLCHAIN_USR_DIR)/bin/llvm-profdata) $(shell xcrun --find llvm-profdata 2>/dev/null || command -v llvm-profdata 2>/dev/null || true))
SWIFT_TEST_FRAMEWORK_CANDIDATES := \
	$(SWIFT_ACTIVE_DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks \
	$(SWIFT_ACTIVE_DEVELOPER_DIR)/Library/Developer/Frameworks \
	$(XCODE_SELECT_DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks \
	$(XCODE_SELECT_DEVELOPER_DIR)/Library/Developer/Frameworks
SWIFT_TEST_RUNTIME_LIBRARY_CANDIDATES := \
	$(foreach path,$(SWIFT_RUNTIME_LIBRARY_PATHS),$(path)/testing $(path)) \
	$(SWIFT_RUNTIME_RESOURCE_PATH)/macosx/testing \
	$(SWIFT_ACTIVE_DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib \
	$(SWIFT_ACTIVE_DEVELOPER_DIR)/Library/Developer/usr/lib \
	$(XCODE_SELECT_DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/usr/lib \
	$(XCODE_SELECT_DEVELOPER_DIR)/Library/Developer/usr/lib
SWIFT_TEST_FRAMEWORK_SEARCH_PATH ?= $(firstword $(foreach path,$(SWIFT_TEST_FRAMEWORK_CANDIDATES),$(if $(wildcard $(path)/Testing.framework),$(path))))
SWIFT_TEST_RUNTIME_LIBRARY_PATH ?= $(firstword $(foreach path,$(SWIFT_TEST_RUNTIME_LIBRARY_CANDIDATES),$(if $(wildcard $(path)/libTesting.dylib $(path)/lib_TestingInterop.dylib),$(path))))
SWIFT_TEST_RESULT_LOG ?= .build/swift-test.log
SWIFT_TEST_ATTEMPTS ?= 2
# Coverage needs a normal Swift test exit; accepting a SwiftPM signal-13 fallback
# can leave incomplete profile data that reports false 0% coverage.
SWIFT_COVERAGE_TEST_ATTEMPTS ?= 3
SWIFT_TEST_RUN_FLAGS ?= --no-parallel
SWIFT_RUNTIME_TEST_FILTER ?= ComposeRuntimeTests
COMPOSE_TEST_BINARY ?= $(abspath .build/debug/compose)
CONTAINER_STACK_REPO ?= $(abspath ../container)
CONTAINERIZATION_STACK_REPO ?= $(abspath ../containerization)
CONTAINER_BUILDER_SHIM_STACK_REPO ?= $(abspath ../container-builder-shim)
HOMEBREW_TAP_REPO ?= $(abspath ../homebrew-tap)
LOCAL_CONTAINER_BINARY ?= $(abspath $(CONTAINER_STACK_REPO)/bin/container)
LOCAL_CONTAINER_PACKAGE_BINARY ?= $(abspath $(CONTAINER_STACK_REPO)/usr/local/bin/container)
CONTAINER_COMPOSE_CONTAINER ?= $(or $(firstword $(wildcard $(LOCAL_CONTAINER_BINARY) $(LOCAL_CONTAINER_PACKAGE_BINARY))),container)
CONTAINER_RUNTIME_STOP_HELPER ?= $(abspath $(CONTAINER_STACK_REPO)/scripts/ensure-container-stopped.sh)
CONTAINER_RUNTIME_APP_ROOT ?= $(abspath .build/container-runtime)
CONTAINER_RUNTIME_INIT_BLOCK_REPO ?= $(if $(wildcard $(CONTAINER_STACK_REPO)/Makefile),$(CONTAINER_STACK_REPO),)
CONTAINERIZATION_INIT_SOURCE_PATH ?= $(if $(wildcard $(CONTAINERIZATION_STACK_REPO)/Package.swift),$(CONTAINERIZATION_STACK_REPO),)
# Prefer Docker's plugin form, while accepting the standalone Docker Compose V2
# executable that Homebrew installs on macOS.  Parity targets pass this value to
# their scripts verbatim, so selecting it here keeps every documented `make
# docker-compose-…-parity` invocation runnable on either installation layout.
DOCKER_COMPOSE_REFERENCE ?= $(shell if docker compose version >/dev/null 2>&1; then printf '%s' 'docker compose'; elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then printf '%s' docker-compose; else printf '%s' 'docker compose'; fi)
DOCKER_COMPOSE_REFERENCE_VERSION ?= 5.3.1
DOCKER_COMPOSE_E2E_REF ?= f32009d4a2c687dd405398cc7975d12dccaf8dff
CONTAINER_COMPOSE_LIVE ?= 0
PARITY_ENV = CONTAINER_COMPOSE_CONTAINER="$(CONTAINER_COMPOSE_CONTAINER)" CONTAINER_COMPOSE_LIVE="$(CONTAINER_COMPOSE_LIVE)" DOCKER_COMPOSE="$(DOCKER_COMPOSE_REFERENCE)" DOCKER_COMPOSE_E2E_REF="$(DOCKER_COMPOSE_E2E_REF)"
MARKDOWN_FILES := $(shell git ls-files '*.md')
DOCKER_COMPOSE_PARITY_TARGETS := \
	docker-compose-cli-surface-parity \
	docker-compose-environment-parity \
	docker-compose-format-template-actions-parity \
	docker-compose-bridge-parity \
	docker-compose-compatibility-names-parity \
	docker-compose-config-all-resources-parity \
	docker-compose-env-file-parity \
	docker-compose-git-remote-parity \
	docker-compose-commit-parity \
	docker-compose-cp-stdio-archive-streams-parity \
	docker-compose-build-builder-parity \
	docker-compose-build-check-parity \
	docker-compose-build-isolation-parity \
	docker-compose-build-secret-metadata-parity \
	docker-compose-bind-create-host-path-parity \
	docker-compose-bind-propagation-parity \
	docker-compose-image-volumes-parity \
	docker-compose-volume-labels-parity \
	docker-compose-named-volume-reuse-parity \
	docker-compose-deploy-endpoint-mode-parity \
	docker-compose-deploy-resource-reservations-parity \
	docker-compose-cpu-limit-parity \
	docker-compose-cpu-cfs-parity \
	docker-compose-cpu-shares-parity \
	docker-compose-cpuset-parity \
	docker-compose-pid-namespace-parity \
	docker-compose-cgroup-namespace-parity \
	docker-compose-cgroup-parent-parity \
	docker-compose-ipc-uts-namespace-parity \
	docker-compose-userns-mode-parity \
	docker-compose-privileged-parity \
	docker-compose-security-opt-parity \
	docker-compose-stop-defaults-parity \
	docker-compose-deploy-scheduler-metadata-parity \
	docker-compose-memory-byte-precision-parity \
	docker-compose-memory-swap-limit-parity \
	docker-compose-pids-limit-parity \
	docker-compose-device-cgroup-rules-parity \
	docker-compose-devices-parity \
	docker-compose-gpus-parity \
	docker-compose-network-driver-opts-parity \
	docker-compose-network-attachable-parity \
	docker-compose-network-ipv6-parity \
	docker-compose-network-ipam-options-parity \
	docker-compose-up-menu-parity \
	docker-compose-host-namespaces-parity \
	docker-compose-health-wait-parity \
	docker-compose-create-options-parity \
	docker-compose-events-parity \
	docker-compose-rm-parity \
	docker-compose-restart-policy-parity

# Some local toolchains can build Swift Testing targets without adding the
# framework and interop library to SwiftPM's generated test runner. Derive
# those paths from the selected Swift executable so `SWIFT=... make swift-test`
# does not mix Xcode and Command Line Tools runtimes.
ifneq ($(strip $(SWIFT_TEST_FRAMEWORK_SEARCH_PATH)),)
SWIFT_TEST_FLAGS ?= -Xswiftc -F -Xswiftc '$(SWIFT_TEST_FRAMEWORK_SEARCH_PATH)' -Xlinker -rpath -Xlinker '$(SWIFT_TEST_FRAMEWORK_SEARCH_PATH)'
ifneq ($(strip $(SWIFT_TEST_RUNTIME_LIBRARY_PATH)),)
SWIFT_TEST_FLAGS += -Xlinker -rpath -Xlinker '$(SWIFT_TEST_RUNTIME_LIBRARY_PATH)'
endif
else
SWIFT_TEST_FLAGS ?=
endif

.PHONY: all workflow ci ci-fast release-gate release-gate-hosted ci-release clean run build build-release test resolve swift-test-build swift-test swift-runtime-test-build swift-runtime-test swift-coverage go-test go-build go-release-check cli-smoke cli-smoke-built container-stack-build docker-log-fixtures docker-log-fixtures-update docker-compose-reference docker-compose-e2e-fixtures docker-compose-parity docker-compose-cli-surface-parity docker-compose-bridge-parity docker-compose-compatibility-names-parity docker-compose-config-all-resources-parity docker-compose-env-file-parity docker-compose-git-remote-parity docker-compose-commit-parity docker-compose-cp-stdio-archive-streams-parity docker-compose-build-builder-parity docker-compose-build-check-parity docker-compose-build-isolation-parity docker-compose-build-secret-metadata-parity docker-compose-bind-create-host-path-parity docker-compose-bind-propagation-parity docker-compose-image-volumes-parity docker-compose-deploy-endpoint-mode-parity docker-compose-deploy-resource-reservations-parity docker-compose-cpu-limit-parity docker-compose-privileged-parity docker-compose-security-opt-parity docker-compose-deploy-scheduler-metadata-parity docker-compose-memory-byte-precision-parity docker-compose-memory-swap-limit-parity docker-compose-pids-limit-parity docker-compose-device-cgroup-rules-parity docker-compose-devices-parity docker-compose-gpus-parity docker-compose-network-driver-opts-parity docker-compose-up-menu-parity docker-compose-host-namespaces-parity docker-compose-health-wait-parity docker-compose-create-options-parity docker-compose-events-parity docker-compose-rm-parity docker-compose-restart-policy-parity docker-compose-userns-mode-parity coverage coverage-check sonar sonar-scan release release-plan package package-release package-debug package-built stack-consistency coverage-tools-test lint format fmt check check-licenses update-licenses pre-commit

.PHONY: worktree-audit worktree-audit-strict
.PHONY: docker-compose-environment-parity docker-compose-named-volume-reuse-parity
.PHONY: docker-compose-format-template-actions-parity
.PHONY: docker-compose-stop-defaults-parity docker-compose-cpu-cfs-parity docker-compose-cpu-shares-parity docker-compose-cpuset-parity docker-compose-pid-namespace-parity docker-compose-cgroup-namespace-parity docker-compose-cgroup-parent-parity docker-compose-ipc-uts-namespace-parity docker-compose-userns-mode-parity docker-compose-privileged-parity docker-compose-network-attachable-parity docker-compose-network-ipv6-parity

all: workflow

workflow: ci package

ci: check coverage-check go-build cli-smoke-built

ci-fast: check test go-build cli-smoke-built

release-gate: container-stack-release-validation ci swift-runtime-test docker-compose-parity

release-gate-hosted: container-stack-hosted-release-validation ci

ci-release: release-gate package-release

release:
	@test -n "$(VERSION_SELECTOR)" || { \
		printf 'VERSION_SELECTOR is required, for example: make release VERSION_SELECTOR=--+\n' >&2; \
		exit 2; \
	}
	./scripts/CONTAINER_STACK_RELEASE.sh release "$(VERSION_SELECTOR)" --execute

release-plan:
	./scripts/CONTAINER_STACK_RELEASE.sh plan

resolve:
	$(SWIFT) package resolve

build:
	$(SWIFT) build $(SWIFT_RESOLVED_FLAGS) --product compose

build-release:
	$(SWIFT) build $(SWIFT_RESOLVED_FLAGS) -c release --product compose $(SWIFT_RELEASE_FLAGS)

run:
	$(SWIFT) run $(SWIFT_RESOLVED_FLAGS) compose version

test: swift-test go-test

swift-test-build:
	$(SWIFT) build $(SWIFT_RESOLVED_FLAGS) --build-tests --enable-code-coverage $(SWIFT_TEST_FLAGS)

swift-test: swift-test-build
	@mkdir -p .build
	@SWIFT_TEST_RESULT_LOG="$(SWIFT_TEST_RESULT_LOG)" SWIFT_TEST_ATTEMPTS="$(SWIFT_TEST_ATTEMPTS)" Tools/ci/run-swift-test.sh $(SWIFT) test $(SWIFT_RESOLVED_FLAGS) --skip-build --enable-code-coverage $(SWIFT_TEST_RUN_FLAGS) $(SWIFT_TEST_FLAGS)
	@if ! grep -Eq 'Test run with [1-9][0-9]* tests .* passed|Executed [1-9][0-9]* tests|swiftpm-testing-helper signal 13 toolchain failure' "$(SWIFT_TEST_RESULT_LOG)"; then \
		printf 'swift test completed without running tests; check the active toolchain Testing.framework and rpath settings.\n' >&2; \
		exit 1; \
	fi

swift-runtime-test-build:
	$(SWIFT) build $(SWIFT_RESOLVED_FLAGS) --build-tests $(SWIFT_TEST_FLAGS)

swift-runtime-test: container-stack-build build swift-runtime-test-build
	container_binary="$(CONTAINER_COMPOSE_CONTAINER)"; \
	if [[ "$$container_binary" == "container" ]]; then \
		for candidate in "$(LOCAL_CONTAINER_BINARY)" "$(LOCAL_CONTAINER_PACKAGE_BINARY)"; do \
			if [[ -x "$$candidate" ]]; then container_binary="$$candidate"; break; fi; \
		done; \
	fi; \
	CONTAINER_RUNTIME_STOP_HELPER="$(CONTAINER_RUNTIME_STOP_HELPER)" \
		CONTAINER_RUNTIME_APP_ROOT="$(CONTAINER_RUNTIME_APP_ROOT)" \
		CONTAINER_RUNTIME_INIT_BLOCK_REPO="$(CONTAINER_RUNTIME_INIT_BLOCK_REPO)" \
		CONTAINERIZATION_INIT_SOURCE_PATH="$(CONTAINERIZATION_INIT_SOURCE_PATH)" \
		./scripts/run-with-container-runtime.sh "$$container_binary" \
		env CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 COMPOSE_TEST_BINARY="$(COMPOSE_TEST_BINARY)" \
		CONTAINER_BIN="$$container_binary" CONTAINER_COMPOSE_CONTAINER="$$container_binary" \
		$(SWIFT) test $(SWIFT_RESOLVED_FLAGS) --skip-build --filter "$(SWIFT_RUNTIME_TEST_FILTER)" $(SWIFT_TEST_RUN_FLAGS) $(SWIFT_TEST_FLAGS)

swift-coverage: swift-test-build
	@if [[ -z "$(SWIFT_LLVM_COV)" ]]; then \
		printf 'llvm-cov is required; install the active Swift toolchain or set SWIFT_LLVM_COV=/path/to/llvm-cov\n' >&2; \
		exit 1; \
	fi
	@if [[ -z "$(SWIFT_LLVM_PROFDATA)" ]]; then \
		printf 'llvm-profdata is required; install the active Swift toolchain or set SWIFT_LLVM_PROFDATA=/path/to/llvm-profdata\n' >&2; \
		exit 1; \
	fi
	@rm -f .build/*/debug/codecov/*.profraw .build/*/debug/codecov/*.profdata .build/codecov/fallback.profdata coverage.lcov coverage.xml
	@find .build -maxdepth 3 -path .build/index-build -prune -o -path '*/debug' -type d -exec mkdir -p '{}/codecov' \;
	@SWIFT_TEST_RESULT_LOG="$(SWIFT_TEST_RESULT_LOG)" SWIFT_TEST_ATTEMPTS="$(SWIFT_COVERAGE_TEST_ATTEMPTS)" SWIFT_TEST_ACCEPT_SIGNAL_13=0 Tools/ci/run-swift-test.sh $(SWIFT) test $(SWIFT_RESOLVED_FLAGS) --skip-build --enable-code-coverage $(SWIFT_TEST_RUN_FLAGS) $(SWIFT_TEST_FLAGS)
	test_binary="$$(find .build -path '*.xctest/Contents/MacOS/container-composePackageTests' -type f | head -n 1)"; \
	profile=".build/codecov/fallback.profdata"; \
	if [[ -z "$$test_binary" ]]; then \
		printf 'Swift test binary is missing; run make swift-test-build before make swift-coverage\n' >&2; \
		exit 2; \
	fi; \
	raw_profile_count="$$(find .build -path .build/index-build -prune -o -name '*.profraw' -type f -print | wc -l | tr -d ' ')"; \
	for _ in 1 2 3 4 5 6 7 8 9 10; do \
		if [[ "$$raw_profile_count" -gt 0 ]]; then \
			break; \
		fi; \
		sleep 1; \
		raw_profile_count="$$(find .build -path .build/index-build -prune -o -name '*.profraw' -type f -print | wc -l | tr -d ' ')"; \
	done; \
	if [[ "$$raw_profile_count" -eq 0 ]]; then \
		printf 'Swift coverage profile is missing and no raw .profraw files were found\n' >&2; \
		exit 2; \
	fi; \
	mkdir -p .build/codecov; \
	find .build -path .build/index-build -prune -o -name '*.profraw' -type f -print0 | xargs -0 "$(SWIFT_LLVM_PROFDATA)" merge -sparse -o "$$profile"; \
	"$(SWIFT_LLVM_COV)" export \
		-format=lcov \
		-instr-profile="$$profile" \
		"$$test_binary" \
		--sources Sources/ComposeCore \
		> coverage.lcov; \
	$(PYTHON) Tools/coverage/lcov-to-sonarqube-generic.py coverage.lcov coverage.xml

go-test:
	cd Tools/compose-normalizer && $(GO) test ./... -coverpkg=./... -coverprofile=coverage.out -covermode=atomic

go-build:
	cd Tools/compose-normalizer && $(GO_RELEASE_ENV) $(GO) build $(GO_RELEASE_BUILD_FLAGS) -ldflags "$(GO_RELEASE_LDFLAGS)" -o compose-normalizer .
	$(MAKE) go-release-check

go-release-check:
	@test -x Tools/compose-normalizer/compose-normalizer || { \
		printf 'Tools/compose-normalizer/compose-normalizer is missing; run make go-build first\n' >&2; \
		exit 1; \
	}
	@case " $(GO_RELEASE_BUILD_FLAGS) " in \
		*" -trimpath "*) ;; \
		*) \
			printf 'GO_RELEASE_BUILD_FLAGS must include -trimpath for Homebrew package builds\n' >&2; \
			exit 1; \
			;; \
	esac
	@case " $(GO_RELEASE_LDFLAGS) " in \
		*" -s "*) ;; \
		*) \
			printf 'GO_RELEASE_LDFLAGS must include -s for Homebrew package builds\n' >&2; \
			exit 1; \
			;; \
	esac
	@case " $(GO_RELEASE_LDFLAGS) " in \
		*" -w "*) ;; \
		*) \
			printf 'GO_RELEASE_LDFLAGS must include -w for Homebrew package builds\n' >&2; \
			exit 1; \
			;; \
	esac
	@$(GO) version -m Tools/compose-normalizer/compose-normalizer | grep -E '^[[:space:]]*build[[:space:]]+-trimpath=true$$' >/dev/null || { \
		printf 'compose-normalizer was not built with -trimpath; Homebrew packages require the release Go build path\n' >&2; \
		$(GO) version -m Tools/compose-normalizer/compose-normalizer >&2; \
		exit 1; \
	}
	@$(GO) version -m Tools/compose-normalizer/compose-normalizer | grep -E '^[[:space:]]*build[[:space:]]+CGO_ENABLED=0$$' >/dev/null || { \
		printf 'compose-normalizer was not built with CGO_ENABLED=0; Homebrew packages require the release Go build path\n' >&2; \
		$(GO) version -m Tools/compose-normalizer/compose-normalizer >&2; \
		exit 1; \
	}
	@if otool -l Tools/compose-normalizer/compose-normalizer | grep -E '__DWARF|__debug' >/dev/null; then \
		printf 'compose-normalizer contains DWARF debug sections; Homebrew packages require stripped release Go binaries\n' >&2; \
		exit 1; \
	fi

cli-smoke: build cli-smoke-built

cli-smoke-built:
	@test -x .build/debug/compose || { \
		printf '.build/debug/compose is missing; run make build or make swift-test-build before make cli-smoke-built\n' >&2; \
		exit 2; \
	}
	.build/debug/compose --ansi never version >/dev/null
	.build/debug/compose version --dry-run >/dev/null
	version_short_output="$$(".build/debug/compose" version --short)"; \
	[[ "$$version_short_output" == "0.7.0" ]]; \
	version_pretty_output="$$(".build/debug/compose" version)"; \
	[[ "$$version_pretty_output" == *"container-compose 0.7.0"* ]]; \
	[[ "$$version_pretty_output" == *"container:"*" (custom)"* ]]; \
	[[ "$$version_pretty_output" == *"containerization:"*" (custom)"* ]]; \
	[[ "$$version_pretty_output" == *"compose-go: $(COMPOSE_GO_VERSION)"* ]]; \
	version_json_output="$$(".build/debug/compose" version --format json)"; \
	[[ "$$version_json_output" == *'"version":"0.7.0"'* ]]; \
	[[ "$$version_json_output" == *'"containerSource":"stephenlclarke/container"'* ]]; \
	[[ "$$version_json_output" == *'"containerRef":"$(CONTAINER_REF)"'* ]]; \
	[[ "$$version_json_output" == *'"containerDistribution":"custom"'* ]]; \
	[[ "$$version_json_output" == *'"containerizationSource":'* ]]; \
	[[ "$$version_json_output" == *'"containerizationDistribution":"custom"'* ]]; \
	[[ "$$version_json_output" == *'"composeGoVersion":"$(COMPOSE_GO_VERSION)"'* ]]; \
	version_short_format_output="$$(".build/debug/compose" version -f json)"; \
	[[ "$$version_short_format_output" == *'"version":"0.7.0"'* ]]; \
	version_compact_format_output="$$(".build/debug/compose" version -fjson)"; \
	[[ "$$version_compact_format_output" == *'"version":"0.7.0"'* ]]; \
	package_tmp="$$(mktemp -d)"; \
	trap 'rm -rf "$$package_tmp"' EXIT; \
	mkdir -p "$$package_tmp/compose/bin" "$$package_tmp/compose/resources" "$$package_tmp/bin"; \
	cp .build/debug/compose "$$package_tmp/compose/bin/compose"; \
	cp "$(PLUGIN_ICON)" "$$package_tmp/compose/resources/container-compose-icon.png"; \
	test -f "$$package_tmp/compose/resources/container-compose-icon.png"; \
	printf '%s\n' '{"version":"0.7.0","source":"stephenlclarke/container-compose","branch":"symlink-smoke","lane":"stable","commit":"packaged-smoke","buildType":"release","containerSource":"stephenlclarke/container","containerRef":"container-smoke","containerizationSource":"stephenlclarke/containerization","containerizationRef":"containerization-smoke","composeGoVersion":"$(COMPOSE_GO_VERSION)"}' > "$$package_tmp/compose/resources/build-info.json"; \
	ln -s ../compose/bin/compose "$$package_tmp/bin/container-compose"; \
	packaged_version_output="$$(cd /tmp && "$$package_tmp/bin/container-compose" version --format json)"; \
	[[ "$$packaged_version_output" == *'"branch":"symlink-smoke"'* ]]; \
	[[ "$$packaged_version_output" == *'"lane":"stable"'* ]]; \
	[[ "$$packaged_version_output" == *'"containerRef":"container-smoke"'* ]]; \
	version_bad_format_output="$$(".build/debug/compose" version --format yaml 2>&1 || true)"; \
	[[ "$$version_bad_format_output" == *"unsupported compose feature: version --format 'yaml'; supported formats are pretty and json"* ]]; \
	compat_tmp="$$(mktemp -d)"; \
	trap 'rm -rf "$$compat_tmp"' EXIT; \
	printf '%s\n' '#!/usr/bin/env bash' 'if [[ "$$*" == "system version --format json" ]]; then' '  printf '\''[{"appName":"container","buildType":"release","commit":"abc123","containerization":"apple/containerization@main","distribution":"apple","source":"apple/container","version":"0.5.0"}]\n'\''' '  exit 0' 'fi' 'exit 2' > "$$compat_tmp/container"; \
	chmod +x "$$compat_tmp/container"; \
	set +e; \
	compat_output="$$(CONTAINER_COMPOSE_CONTAINER="$$compat_tmp/container" ".build/debug/compose" ps 2>&1)"; \
	compat_status="$$?"; \
	set -e; \
	[[ "$$compat_status" -ne 0 ]]; \
	[[ "$$compat_output" == *"The installed container components do not match the Compose functionality in this plugin."* ]]; \
	[[ "$$compat_output" == *"brew upgrade stephenlclarke/tap/container stephenlclarke/tap/container-compose || brew install --formula stephenlclarke/tap/container-compose"* ]]; \
	[[ "$$compat_output" == *"brew postinstall stephenlclarke/tap/container"* ]]; \
	[[ "$$compat_output" == *"brew services restart stephenlclarke/tap/container"* ]]; \
	[[ "$$compat_output" == *"https://github.com/stephenlclarke/container-compose/blob/main/INSTALL.md"* ]]; \
	service_tmp="$$(mktemp -d)"; \
	trap 'rm -rf "$$service_tmp"' EXIT; \
	printf '%s\n' '{"version":"0.7.0","source":"stephenlclarke/container-compose","branch":"service-smoke","lane":"stable","commit":"service-smoke","buildType":"release","containerSource":"stephenlclarke/container","containerRef":"matched-container","containerizationSource":"stephenlclarke/containerization","containerizationRef":"matched-containerization","composeGoVersion":"$(COMPOSE_GO_VERSION)"}' > "$$service_tmp/build-info.json"; \
	printf '%s\n' '#!/usr/bin/env bash' 'if [[ "$$*" == "system version --format json" ]]; then' '  printf '\''[{"appName":"container","buildType":"release","commit":"matched-container","containerization":"stephenlclarke/containerization@matched-containerization","distribution":"custom","source":"stephenlclarke/container","version":"homebrew-main"}]\n'\''' '  exit 0' 'fi' 'if [[ "$$*" == "system status" ]]; then' '  printf '\''apiserver is not running and not registered with launchd\n'\'' >&2' '  exit 1' 'fi' 'exit 2' > "$$service_tmp/container"; \
	chmod +x "$$service_tmp/container"; \
	set +e; \
	service_output="$$(CONTAINER_COMPOSE_BUILD_INFO="$$service_tmp/build-info.json" CONTAINER_COMPOSE_CONTAINER="$$service_tmp/container" ".build/debug/compose" ps 2>&1)"; \
	service_status="$$?"; \
	set -e; \
	[[ "$$service_status" -ne 0 ]]; \
	[[ "$$service_output" == *"container-compose requires the matching stephenlclarke container system service to be running."* ]]; \
	[[ "$$service_output" == *"The installed container components match this plugin"* ]]; \
	[[ "$$service_output" == *"container system start"* ]]; \
	[[ "$$service_output" == *"brew postinstall stephenlclarke/tap/container"* ]]; \
	[[ "$$service_output" == *"brew services restart stephenlclarke/tap/container"* ]]; \
	[[ "$$service_output" == *"container system status: apiserver is not running and not registered with launchd"* ]]; \
	ansi_escape="$$(printf '\033')"; \
	root_help_output="$$(".build/debug/compose" --help)"; \
	[[ "$$root_help_output" == *"$${ansi_escape}[32malpha$${ansi_escape}[0m"* ]]; \
	[[ "$$root_help_output" == *"$${ansi_escape}[32mversion$${ansi_escape}[0m"* ]]; \
	[[ "$$root_help_output" == *"$${ansi_escape}[32mup$${ansi_escape}[0m"* ]]; \
	[[ "$$root_help_output" == *"$${ansi_escape}[38;5;208mcommit$${ansi_escape}[0m"* ]]; \
	[[ "$$root_help_output" == *"$${ansi_escape}[32mhelp$${ansi_escape}[0m"* ]]; \
	[[ "$$root_help_output" == *"$${ansi_escape}[32mpause$${ansi_escape}[0m"* ]]; \
	[[ "$$root_help_output" == *"$${ansi_escape}[32m--file$${ansi_escape}[0m"* ]]; \
	[[ "$$root_help_output" == *"$${ansi_escape}[32m--parallel$${ansi_escape}[0m"* ]]; \
	plain_help_output="$$(".build/debug/compose" --ansi never --help)"; \
	[[ "$$plain_help_output" == *"Support: supported | partially supported | not supported"* ]]; \
	[[ "$$plain_help_output" != *"$${ansi_escape}["* ]]; \
	compose_help_output="$$(".build/debug/compose" help)"; \
	[[ "$$compose_help_output" == *"Usage:  container compose [OPTIONS] COMMAND"* ]]; \
	[[ "$$compose_help_output" == *"$${ansi_escape}[32mhelp$${ansi_escape}[0m"* ]]; \
	alpha_output="$$(".build/debug/compose" alpha)"; \
	[[ "$$alpha_output" == *"Usage:  container compose alpha [OPTIONS] COMMAND"* ]]; \
	alpha_help_output="$$(".build/debug/compose" alpha --help)"; \
	[[ "$$alpha_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$alpha_help_output" == *"$${ansi_escape}[32m--dry-run$${ansi_escape}[0m"* ]]; \
	alpha_scale_help_output="$$(".build/debug/compose" alpha scale --help)"; \
	[[ "$$alpha_scale_help_output" == *"Usage:  container compose alpha scale [OPTIONS] SERVICE=REPLICAS..."* ]]; \
	[[ "$$alpha_scale_help_output" == *"$${ansi_escape}[32m--no-deps$${ansi_escape}[0m"* ]]; \
	alpha_watch_help_output="$$(".build/debug/compose" alpha watch --help)"; \
	[[ "$$alpha_watch_help_output" == *"Usage:  container compose alpha watch [OPTIONS] [SERVICE...]"* ]]; \
	[[ "$$alpha_watch_help_output" == *"$${ansi_escape}[32m--no-up$${ansi_escape}[0m"* ]]; \
	[[ "$$alpha_watch_help_output" == *"$${ansi_escape}[32m--quiet$${ansi_escape}[0m"* ]]; \
	version_help_output="$$(".build/debug/compose" version --help)"; \
	[[ "$$version_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$version_help_output" == *"$${ansi_escape}[32m--dry-run$${ansi_escape}[0m"* ]]; \
	[[ "$$version_help_output" == *"$${ansi_escape}[32m--format$${ansi_escape}[0m"* ]]; \
	commit_help_output="$$(".build/debug/compose" commit --help)"; \
	[[ "$$commit_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$commit_help_output" == *"$${ansi_escape}[32m--author$${ansi_escape}[0m"* ]]; \
	[[ "$$commit_help_output" == *"$${ansi_escape}[32m--pause$${ansi_escape}[0m"* ]]; \
	config_help_output="$$(".build/debug/compose" config --help)"; \
	[[ "$$config_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"Normalized output omits build.no_cache_filter."* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--format$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--services$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--images$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--lock-image-digests$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--output$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--environment$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--profiles$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--resolve-image-digests$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--variables$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--no-consistency$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--no-env-resolution$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--no-interpolate$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--no-normalize$${ansi_escape}[0m"* ]]; \
	[[ "$$config_help_output" == *"$${ansi_escape}[32m--no-path-resolution$${ansi_escape}[0m"* ]]; \
	build_help_output="$$(".build/debug/compose" build --help)"; \
	[[ "$$build_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$build_help_output" == *"build.no_cache_filter and non-file/environment build-secret source forms are unavailable."* ]]; \
	[[ "$$build_help_output" == *"$${ansi_escape}[32m--build-arg$${ansi_escape}[0m"* ]]; \
	[[ "$$build_help_output" == *"$${ansi_escape}[32m--memory$${ansi_escape}[0m"* ]]; \
	[[ "$$build_help_output" == *"$${ansi_escape}[32m--no-cache$${ansi_escape}[0m"* ]]; \
	[[ "$$build_help_output" == *"$${ansi_escape}[32m--print$${ansi_escape}[0m"* ]]; \
	[[ "$$build_help_output" == *"$${ansi_escape}[32m--provenance$${ansi_escape}[0m"* ]]; \
	[[ "$$build_help_output" == *"$${ansi_escape}[32m--sbom$${ansi_escape}[0m"* ]]; \
	[[ "$$build_help_output" == *"Use --provenance=false to explicitly disable."* ]]; \
	[[ "$$build_help_output" == *"Use --sbom=false to explicitly disable."* ]]; \
	[[ "$$build_help_output" == *"$${ansi_escape}[32m--ssh$${ansi_escape}[0m"* ]]; \
	attach_help_output="$$(".build/debug/compose" attach --help)"; \
	[[ "$$attach_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$attach_help_output" == *"$${ansi_escape}[38;5;208m--detach-keys$${ansi_escape}[0m"* ]]; \
	[[ "$$attach_help_output" == *"Ignored with --no-stdin output-only attach."* ]]; \
	[[ "$$attach_help_output" == *"$${ansi_escape}[32m--no-stdin$${ansi_escape}[0m"* ]]; \
	[[ "$$attach_help_output" == *"$${ansi_escape}[32m--sig-proxy$${ansi_escape}[0m"* ]]; \
	stats_help_output="$$(".build/debug/compose" stats --help)"; \
	[[ "$$stats_help_output" == *"Usage:  container compose stats [OPTIONS] [SERVICE]"* ]]; \
	[[ "$$stats_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$stats_help_output" == *"Go-template control blocks and nested object paths are unavailable."* ]]; \
	[[ "$$stats_help_output" == *"$${ansi_escape}[32m--format$${ansi_escape}[0m"* ]]; \
	ls_help_output="$$(".build/debug/compose" ls --help)"; \
	[[ "$$ls_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$ls_help_output" == *"$${ansi_escape}[32m--filter$${ansi_escape}[0m"* ]]; \
	[[ "$$ls_help_output" == *"$${ansi_escape}[32m--format$${ansi_escape}[0m"* ]]; \
	[[ "$$ls_help_output" == *"Format the output. Values: [table | json]"* ]]; \
	ps_help_output="$$(".build/debug/compose" ps --help)"; \
	[[ "$$ps_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$ps_help_output" == *"Go-template control blocks and nested object paths are unavailable."* ]]; \
	[[ "$$ps_help_output" == *"$${ansi_escape}[32m--filter$${ansi_escape}[0m"* ]]; \
	[[ "$$ps_help_output" == *"$${ansi_escape}[32m--format$${ansi_escape}[0m"* ]]; \
	[[ "$$ps_help_output" == *"$${ansi_escape}[32m--no-trunc$${ansi_escape}[0m"* ]]; \
	[[ "$$ps_help_output" == *"$${ansi_escape}[32m--orphans$${ansi_escape}[0m"* ]]; \
	[[ "$$ps_help_output" == *"$${ansi_escape}[32m--status$${ansi_escape}[0m"* ]]; \
	images_help_output="$$(".build/debug/compose" images --help)"; \
	[[ "$$images_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$images_help_output" == *"$${ansi_escape}[32m--format$${ansi_escape}[0m"* ]]; \
	[[ "$$images_help_output" == *"Format the output. Values: [table | json]"* ]]; \
	cp_help_output="$$(".build/debug/compose" cp --help)"; \
	[[ "$$cp_help_output" == *"$${ansi_escape}[32m--archive$${ansi_escape}[0m"* ]]; \
	[[ "$$cp_help_output" == *"$${ansi_escape}[32m--follow-link$${ansi_escape}[0m"* ]]; \
	logs_help_output="$$(".build/debug/compose" logs --help)"; \
	[[ "$$logs_help_output" == *"-f, --follow"* ]]; \
	[[ "$$logs_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$logs_help_output" == *"$${ansi_escape}[32m--follow$${ansi_escape}[0m"* ]]; \
	[[ "$$logs_help_output" == *"$${ansi_escape}[32m--tail$${ansi_escape}[0m"* ]]; \
	[[ "$$logs_help_output" == *"$${ansi_escape}[32m--timestamps$${ansi_escape}[0m"* ]]; \
	[[ "$$logs_help_output" == *"$${ansi_escape}[32m--since$${ansi_escape}[0m"* ]]; \
	[[ "$$logs_help_output" == *"$${ansi_escape}[32m--until$${ansi_escape}[0m"* ]]; \
	logs_misordered_help_output="$$(".build/debug/compose" logs help)"; \
	[[ "$$logs_misordered_help_output" == *"Usage:  container compose logs [OPTIONS] [SERVICE...]"* ]]; \
	[[ "$$logs_misordered_help_output" != *"compose-normalizer"* ]]; \
	logs_plain_misordered_help_output="$$(".build/debug/compose" --ansi never logs help)"; \
	[[ "$$logs_plain_misordered_help_output" == *"Usage:  container compose logs [OPTIONS] [SERVICE...]"* ]]; \
	[[ "$$logs_plain_misordered_help_output" != *"$${ansi_escape}["* ]]; \
	run_help_output="$$(".build/debug/compose" run --help)"; \
	[[ "$$run_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$run_help_output" == *"Container-facing DNS aliases and interactive lifecycle hooks are incomplete."* ]]; \
	[[ "$$run_help_output" == *"-p, --publish stringArray"* ]]; \
	[[ "$$run_help_output" == *"$${ansi_escape}[32m--build$${ansi_escape}[0m"* ]]; \
	[[ "$$run_help_output" == *"$${ansi_escape}[32m--interactive$${ansi_escape}[0m"* ]]; \
	[[ "$$run_help_output" == *"$${ansi_escape}[32m--quiet$${ansi_escape}[0m"* ]]; \
	[[ "$$run_help_output" == *"$${ansi_escape}[32m--quiet-build$${ansi_escape}[0m"* ]]; \
	[[ "$$run_help_output" == *"$${ansi_escape}[32m--quiet-pull$${ansi_escape}[0m"* ]]; \
	[[ "$$run_help_output" == *"$${ansi_escape}[32m--remove-orphans$${ansi_escape}[0m"* ]]; \
	[[ "$$run_help_output" == *"$${ansi_escape}[32m--publish$${ansi_escape}[0m"* ]]; \
	[[ "$$run_help_output" == *"$${ansi_escape}[38;5;208m--use-aliases$${ansi_escape}[0m"* ]]; \
	up_help_output="$$(".build/debug/compose" up --help)"; \
	[[ "$$up_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"pre_start and container-facing DNS aliases are unavailable."* ]]; \
	up_wait_support="$${ansi_escape}[38;5;208m--wait$${ansi_escape}[0m"; \
	up_wait_timeout_support="$${ansi_escape}[38;5;208m--wait-timeout$${ansi_escape}[0m"; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--abort-on-container-exit$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--abort-on-container-failure$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--attach$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--attach-dependencies$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--detach$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--menu$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"Use --menu=false to explicitly disable the helper menu."* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--no-attach$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--exit-code-from$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--no-color$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--renew-anon-volumes$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--timestamps$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${up_wait_support}"* ]]; \
	[[ "$$up_help_output" == *"$${up_wait_timeout_support}"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--watch$${ansi_escape}[0m"* ]]; \
	[[ "$$up_help_output" == *"$${ansi_escape}[32m--yes$${ansi_escape}[0m"* ]]; \
	rm_help_output="$$(".build/debug/compose" rm --help)"; \
	[[ "$$rm_help_output" == *"-f, --force"* ]]; \
	start_help_output="$$(".build/debug/compose" start --help)"; \
	[[ "$$start_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$start_help_output" == *"$${ansi_escape}[32m--wait$${ansi_escape}[0m"* ]]; \
	[[ "$$start_help_output" == *"$${ansi_escape}[32m--wait-timeout$${ansi_escape}[0m"* ]]; \
	create_help_output="$$(".build/debug/compose" create --help)"; \
	[[ "$$create_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$create_help_output" == *"$${ansi_escape}[32m--scale$${ansi_escape}[0m"* ]]; \
	stop_help_output="$$(".build/debug/compose" stop --help)"; \
	[[ "$$stop_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	top_help_output="$$(".build/debug/compose" top --help)"; \
	[[ "$$top_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$top_help_output" == *"$${ansi_escape}[32m--dry-run$${ansi_escape}[0m"* ]]; \
	kill_help_output="$$(".build/debug/compose" kill --help)"; \
	[[ "$$kill_help_output" == *"$${ansi_escape}[32m--remove-orphans$${ansi_escape}[0m"* ]]; \
	export_help_output="$$(".build/debug/compose" export --help)"; \
	[[ "$$export_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	version_help_output="$$(".build/debug/compose" version --help)"; \
	[[ "$$version_help_output" == *"$${ansi_escape}[32m--dry-run$${ansi_escape}[0m"* ]]; \
	wait_help_output="$$(".build/debug/compose" wait --help)"; \
	[[ "$$wait_help_output" == *"--down-project"* ]]; \
	[[ "$$wait_help_output" != *"unsupported compose feature"* ]]; \
	bridge_help_output="$$(".build/debug/compose" bridge --help)"; \
	[[ "$$bridge_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$bridge_help_output" == *"Management Commands:"* ]]; \
	bridge_misordered_help_output="$$(".build/debug/compose" bridge help)"; \
	[[ "$$bridge_misordered_help_output" == *"Usage:  container compose bridge [OPTIONS] COMMAND"* ]]; \
	bridge_convert_help_output="$$(".build/debug/compose" bridge convert --help)"; \
	[[ "$$bridge_convert_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$bridge_convert_help_output" == *"Usage:  container compose bridge convert"* ]]; \
	[[ "$$bridge_convert_help_output" == *"-o, --output string"* ]]; \
	[[ "$$bridge_convert_help_output" == *"$${ansi_escape}[32m--output$${ansi_escape}[0m"* ]]; \
	bridge_transformations_help_output="$$(".build/debug/compose" bridge transformations --help)"; \
	[[ "$$bridge_transformations_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$bridge_transformations_help_output" == *"Usage:  container compose bridge transformations [OPTIONS] COMMAND"* ]]; \
	bridge_transformations_create_help_output="$$(".build/debug/compose" bridge transformations create --help)"; \
	[[ "$$bridge_transformations_create_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$bridge_transformations_create_help_output" == *"Usage:  container compose bridge transformations create [OPTION] PATH"* ]]; \
	bridge_transformations_list_help_output="$$(".build/debug/compose" bridge transformations list --help)"; \
	[[ "$$bridge_transformations_list_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$bridge_transformations_list_help_output" == *"Usage:  container compose bridge transformations list"* ]]; \
	[[ "$$bridge_transformations_list_help_output" == *"$${ansi_escape}[32m--format$${ansi_escape}[0m"* ]]; \
	commit_help_output="$$(".build/debug/compose" commit --help)"; \
	[[ "$$commit_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$commit_help_output" == *"$${ansi_escape}[32m--pause$${ansi_escape}[0m"* ]]; \
	tmpdir="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	printf 'enabled=true\n' > "$$tmpdir/api.conf"; \
	printf 'token\n' > "$$tmpdir/api-token.txt"; \
	printf 'services:\n  api:\n    image: alpine\n    annotations:\n      example.com/owner: platform\n    depends_on:\n      - db\n    ports:\n      - "8080:80"\n    mac_address: "02:42:ac:11:00:03"\n    configs:\n      - source: api_config\n        target: /etc/api.conf\n    secrets:\n      - api_token\n    volumes_from:\n      - db:ro\n    volumes:\n      - /scratch\n      - cache:/cache\n    dns_opt:\n      - use-vc\n    networks:\n      default:\n        driver_opts:\n          com.docker.network.driver.mtu: "1450"\n  db:\n    image: alpine\n    volumes:\n      - cache:/db-cache\n  debugger:\n    image: alpine\n    profiles:\n      - dev\n      - debug\n  job:\n    image: alpine\n    depends_on:\n      db:\n        condition: service_healthy\n        restart: true\n  shell:\n    image: alpine\n    tty: true\n    stdin_open: true\n  isolated:\n    image: alpine\n    network_mode: none\nnetworks:\n  default:\n    internal: true\n    ipam:\n      config:\n        - subnet: "10.77.0.0/24"\n        - subnet: "fd77::/64"\nvolumes:\n  cache:\n    driver: local\n    driver_opts:\n      journal: ordered\n      size: 64m\nconfigs:\n  api_config:\n    file: ./api.conf\nsecrets:\n  api_token:\n    file: ./api-token.txt\n' > "$$tmpdir/compose.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    ports:\n      - "80"\n' > "$$tmpdir/dynamic-ports.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    attach: false\n' > "$$tmpdir/attach-false.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    networks:\n      default:\n        aliases:\n          - api\n' > "$$tmpdir/aliases.yml"; \
	mkdir -p "$$tmpdir/src"; \
	printf 'services:\n  api:\n    image: alpine\n    develop:\n      watch:\n        - path: ./src\n          action: rebuild\n' > "$$tmpdir/watch.yml"; \
	printf 'services:\n  worker:\n    image: alpine\n' > "$$tmpdir/scale.yml"; \
	printf 'services:\n  worker:\n    image: alpine\n    scale: 2\n' > "$$tmpdir/logs-scale.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    depends_on:\n      - db\n  db:\n    image: alpine\n' > "$$tmpdir/scale-deps.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    ports:\n      - "8080-8081:80"\n' > "$$tmpdir/scale-ports.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    volumes:\n      - /scratch\n' > "$$tmpdir/scale-volumes.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    pull_policy: daily\n' > "$$tmpdir/pull-window.yml"; \
	printf 'services:\n  api:\n    image: example/api:build\n    build:\n      context: ./api\n    pull_policy: build\n' > "$$tmpdir/pull-build.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    volumes:\n      - type: tmpfs\n        target: /scratch\n        tmpfs:\n          size: 64m\n          mode: 1777\n' > "$$tmpdir/tmpfs-options.yml"; \
	mkdir -p "$$tmpdir/api"; \
	printf 'FROM alpine:3.20\n' > "$$tmpdir/api/Dockerfile"; \
	printf 'secret\n' > "$$tmpdir/build-token.txt"; \
	printf 'services:\n  api:\n    image: example/api:build\n    build:\n      context: ./api\n      secrets:\n        - source: file_token\n        - source: env_token\n          target: npm_token\nsecrets:\n  file_token:\n    file: ./build-token.txt\n  env_token:\n    environment: NPM_TOKEN\n' > "$$tmpdir/build-secrets.yml"; \
	printf 'name: inline-build\nservices:\n  api:\n    image: example/api:inline\n    build:\n      context: ./api\n      dockerfile_inline: |\n        FROM alpine:3.20\n        RUN echo inline\n' > "$$tmpdir/build-inline.yml"; \
	printf 'services:\n  worker:\n    build:\n      context: ./api\n' > "$$tmpdir/build-only.yml"; \
	printf 'services:\n  api:\n    image: "$${IMAGE_NAME:-alpine}:$${IMAGE_TAG:-3.20}"\n    environment:\n      REQUIRED: "$${REQUIRED?must set}"\n      WHEN_PRESENT: "$${OPTIONAL:+enabled}"\n' > "$$tmpdir/variables.yml"; \
	printf 'services:\n  api:\n    image: alpine\n' > "$$tmpdir/no-variables.yml"; \
	printf 'VALUE=from-env-file\n' > "$$tmpdir/service.env"; \
	printf 'services:\n  api:\n    image: alpine\n    env_file:\n      - service.env\n' > "$$tmpdir/env-file.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    build:\n      context: ./api\n    volumes:\n      - ./src:/src\n' > "$$tmpdir/relative-paths.yml"; \
	printf 'services:\n  api:\n    image: alpine\n    depends_on:\n      - missing\n' > "$$tmpdir/missing-dependency.yml"; \
	version_compact_global_output="$$(".build/debug/compose" -pcompact -f"$$tmpdir/compose.yml" version --short)"; \
	[[ "$$version_compact_global_output" == "0.7.0" ]]; \
	config_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config)"; \
	[[ "$$config_output" == *"name: \"demo\""* ]]; \
	[[ "$$config_output" == *"services:"* ]]; \
	config_json_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config --format json)"; \
	[[ "$$config_json_output" == *'"name":"demo"'* ]]; \
	config_yaml_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config --format yaml api)"; \
	[[ "$$config_yaml_output" == *"services:"* ]]; \
	[[ "$$config_yaml_output" == *"  api:"* ]]; \
	[[ "$$config_yaml_output" == *'    image: "alpine"'* ]]; \
	[[ "$$config_yaml_output" != *"  db:"* ]]; \
	config_services_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config --services)"; \
	[[ "$$config_services_output" == *"api"* ]]; \
	[[ "$$config_services_output" == *"db"* ]]; \
	[[ "$$config_services_output" == *"job"* ]]; \
	config_images_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config --images api)"; \
	[[ "$$config_images_output" == "alpine" ]]; \
	config_networks_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config --networks)"; \
	[[ "$$config_networks_output" == "default" ]]; \
	config_profiles_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config --profiles)"; \
	[[ "$$config_profiles_output" == $$'debug\ndev' ]]; \
	config_variables_output="$$(".build/debug/compose" -f "$$tmpdir/variables.yml" config --variables)"; \
	[[ "$$config_variables_output" == *"IMAGE_NAME"*"false"*"alpine"* ]]; \
	[[ "$$config_variables_output" == *"IMAGE_TAG"*"false"*"3.20"* ]]; \
	[[ "$$config_variables_output" == *"OPTIONAL"*"false"*"enabled"* ]]; \
	[[ "$$config_variables_output" == *"REQUIRED"*"true"* ]]; \
	config_no_variables_output="$$(".build/debug/compose" -f "$$tmpdir/no-variables.yml" config --variables)"; \
	[[ "$$config_no_variables_output" == "NAME  REQUIRED  DEFAULT VALUE  ALTERNATE VALUE" ]]; \
	config_no_interpolate_output="$$(".build/debug/compose" -f "$$tmpdir/variables.yml" config --no-interpolate --format json)"; \
	[[ "$$config_no_interpolate_output" == *'$${IMAGE_NAME:-alpine}:$${IMAGE_TAG:-3.20}'* ]]; \
	config_no_env_resolution_output="$$(".build/debug/compose" -f "$$tmpdir/env-file.yml" config --no-env-resolution --format json)"; \
	[[ "$$config_no_env_resolution_output" == *'"envFiles"'* ]]; \
	[[ "$$config_no_env_resolution_output" != *"from-env-file"* ]]; \
	config_no_path_resolution_output="$$(".build/debug/compose" -f "$$tmpdir/relative-paths.yml" config --no-path-resolution --format json)"; \
	[[ "$$config_no_path_resolution_output" == *'"context":"./api"'* ]]; \
	[[ "$$config_no_path_resolution_output" == *'"source":"./src"'* ]]; \
	config_no_normalize_output="$$(".build/debug/compose" -f "$$tmpdir/relative-paths.yml" config --no-normalize --format json)"; \
	[[ "$$config_no_normalize_output" == *'"context":'* ]]; \
	[[ "$$config_no_normalize_output" != *'"dockerfile":"Dockerfile"'* ]]; \
	config_no_consistency_output="$$(".build/debug/compose" -f "$$tmpdir/missing-dependency.yml" config --no-consistency --services)"; \
	[[ "$$config_no_consistency_output" == "api" ]]; \
	config_volumes_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config --volumes)"; \
	[[ "$$config_volumes_output" == "cache" ]]; \
	config_hash_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config --hash api)"; \
	[[ "$$config_hash_output" == api" "* ]]; \
	config_filtered_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" config api)"; \
	[[ "$$config_filtered_output" == *'"api"'* ]]; \
	[[ "$$config_filtered_output" != *'"db"'* ]]; \
	convert_json_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" convert --format json api)"; \
	[[ "$$convert_json_output" == *'"api"'* ]]; \
	[[ "$$convert_json_output" != *'"db"'* ]]; \
	convert_services_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" convert --services)"; \
	[[ "$$convert_services_output" == *"api"* ]]; \
	[[ "$$convert_services_output" == *"db"* ]]; \
	convert_hash_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" convert --hash api)"; \
	[[ "$$convert_hash_output" == api" "* ]]; \
	config_output_path="$$tmpdir/config-output.yaml"; \
	".build/debug/compose" -f "$$tmpdir/compose.yml" config --output "$$config_output_path"; \
	[[ -s "$$config_output_path" ]]; \
	convert_output_path="$$tmpdir/convert-output.yaml"; \
	".build/debug/compose" -f "$$tmpdir/compose.yml" convert --output "$$convert_output_path"; \
	[[ -s "$$convert_output_path" ]]; \
	config_environment_output="$$(COMPOSE_CONFIG_ENV_SMOKE=ok ".build/debug/compose" -f "$$tmpdir/compose.yml" config --environment)"; \
	[[ "$$config_environment_output" == *"COMPOSE_CONFIG_ENV_SMOKE=ok"* ]]; \
	compact_global_output="$$(".build/debug/compose" --dry-run -pcompact -f"$$tmpdir/compose.yml" up api)"; \
	[[ "$$compact_global_output" == *"compact-db-1"* ]]; \
	[[ "$$compact_global_output" == *"compact-api-1"* ]]; \
	pull_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" pull --include-deps --ignore-pull-failures --policy missing -q api)"; \
	[[ "$$(printf '%s\n' "$$pull_options_output" | grep -c "container image inspect alpine")" == "2" ]]; \
	pull_window_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/pull-window.yml" up api)"; \
	[[ "$$pull_window_output" == *"container image inspect alpine"* ]]; \
	[[ "$$pull_window_output" == *"container image pull alpine"* ]]; \
	[[ "$$pull_window_output" == *"container run"* ]]; \
	pull_build_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/pull-build.yml" up api)"; \
	[[ "$$pull_build_output" == *"container build --tag example/api:build"* ]]; \
	[[ "$$pull_build_output" == *"container run"* ]]; \
	tmpfs_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/tmpfs-options.yml" up api)"; \
	[[ "$$tmpfs_options_output" == *"--mount type=tmpfs,destination=/scratch,size=67108864,mode=1777"* ]]; \
	[[ "$$tmpfs_options_output" != *"--tmpfs /scratch"* ]]; \
	push_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" push --include-deps --ignore-push-failures -q api)"; \
	[[ "$$(printf '%s\n' "$$push_options_output" | grep -c "container image push alpine")" == "2" ]]; \
	run_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run api echo hello)"; \
	[[ "$$run_output" == *"container run"* ]]; \
	[[ "$$run_output" == *"demo-db-1"* ]]; \
	[[ "$$run_output" == *"--volume demo_cache:/db-cache:ro"* ]]; \
	[[ "$$run_output" == *"--volume $$tmpdir/api.conf:/etc/api.conf:ro"* ]]; \
	[[ "$$run_output" == *"--volume $$tmpdir/api-token.txt:/run/secrets/api_token:ro"* ]]; \
	[[ "$$run_output" == *" alpine echo hello"* ]]; \
	[[ "$$run_output" != *"--publish 8080:80"* ]]; \
	run_service_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --service-ports api echo hello)"; \
	[[ "$$run_service_ports_output" == *"--publish 8080:80"* ]]; \
	run_dynamic_service_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/dynamic-ports.yml" run --service-ports api echo hello)"; \
	[[ "$$run_dynamic_service_ports_output" == *"--publish "*":80"* ]]; \
	run_publish_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -p 9090:90 api echo hello)"; \
	[[ "$$run_publish_output" == *"--publish 9090:90"* ]]; \
	[[ "$$run_publish_output" != *"--publish 8080:80"* ]]; \
	run_aliases_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/aliases.yml" run --use-aliases api echo hello 2>&1 || true)"; \
	[[ "$$run_aliases_output" == *"unsupported compose feature: service 'api' uses network aliases; apple/container registers aliases but cannot resolve them inside service containers until it exposes container-facing DNS"* ]]; \
	run_capability_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --cap-add SYS_PTRACE --cap-drop NET_RAW api echo hello)"; \
	[[ "$$run_capability_output" == *"--cap-add SYS_PTRACE"* ]]; \
	[[ "$$run_capability_output" == *"--cap-drop NET_RAW"* ]]; \
	build_secret_output="$$(NPM_TOKEN=local-secret ".build/debug/compose" --dry-run -f "$$tmpdir/build-secrets.yml" build --pull --with-dependencies -q api)"; \
	[[ "$$build_secret_output" == *"--secret id=file_token,src=$$tmpdir/build-token.txt"* ]]; \
	[[ "$$build_secret_output" == *"--secret id=npm_token,env=NPM_TOKEN"* ]]; \
	[[ "$$build_secret_output" == *"--pull"* ]]; \
	[[ "$$build_secret_output" == *"--quiet"* ]]; \
	build_arg_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" build --build-arg VERSION=2 --memory 256m worker)"; \
	[[ "$$build_arg_output" == *"--memory 256m"* ]]; \
	[[ "$$build_arg_output" == *"--build-arg VERSION=2"* ]]; \
	build_print_output="$$(BUILD_PRINT_ENV=ok ".build/debug/compose" --ansi never --progress quiet -f "$$tmpdir/build-only.yml" build --print --provenance=false --sbom=false --build-arg VERSION=2 --build-arg BUILD_PRINT_ENV worker)"; \
	[[ "$$build_print_output" == *'"target"'* ]]; \
	[[ "$$build_print_output" == *'"worker"'* ]]; \
	[[ "$$build_print_output" == *'"VERSION" : "2"'* ]]; \
	[[ "$$build_print_output" == *'"BUILD_PRINT_ENV" : "ok"'* ]]; \
	[[ "$$build_print_output" == *'"type=docker"'* ]]; \
	[[ "$$build_print_output" != *"container build"* ]]; \
	build_provenance_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" build --provenance=mode=max worker)"; \
	[[ "$$build_provenance_output" == *"container build"*"--provenance mode=max"* ]]; \
	build_sbom_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" build --sbom=true worker)"; \
	[[ "$$build_sbom_output" == *"container build"*"--sbom true"* ]]; \
	build_ssh_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" build --ssh default worker)"; \
	[[ "$$build_ssh_output" == *"container build"*"--ssh default"* ]]; \
	build_inline_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-inline.yml" build api)"; \
	[[ "$$build_inline_output" == *"container build"* ]]; \
	[[ "$$build_inline_output" == *"--tag example/api:inline"* ]]; \
	[[ "$$build_inline_output" == *"--file "*"container-compose-inline-build-api-"*"/Dockerfile"* ]]; \
	run_pull_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --pull missing api true)"; \
	[[ "$$run_pull_output" == *"container image inspect alpine"* ]]; \
	[[ "$$run_pull_output" == *"container image pull alpine"* ]]; \
	[[ "$$run_pull_output" == *" alpine true"* ]]; \
	run_quiet_pull_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --pull always --quiet-pull api true)"; \
	[[ "$$run_quiet_pull_output" == *"container image pull --progress none alpine"* ]]; \
	run_build_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" run --build --quiet-build worker true)"; \
	[[ "$$run_build_output" == *"container build"* ]]; \
	[[ "$$run_build_output" == *"--quiet"* ]]; \
	[[ "$$run_build_output" == *"container run"* ]]; \
	run_interactive_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --interactive api true)"; \
	[[ "$$run_interactive_output" == *"--interactive"* ]]; \
	run_quiet_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --quiet api true)"; \
	[[ "$$run_quiet_output" == *"container run"* ]]; \
	[[ "$$run_quiet_output" == *" alpine true"* ]]; \
	run_named_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --name custom-api api echo hello)"; \
	[[ "$$run_named_output" == *"--name custom-api"* ]]; \
	[[ "$$run_named_output" == *" alpine echo hello"* ]]; \
	run_entrypoint_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --entrypoint "/bin/sh -c" api echo hello)"; \
	[[ "$$run_entrypoint_output" == *"--entrypoint '/bin/sh -c'"* ]]; \
	[[ "$$run_entrypoint_output" == *" alpine echo hello"* ]]; \
	run_workdir_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --workdir /workspace api pwd)"; \
	[[ "$$run_workdir_output" == *"--workdir /workspace"* ]]; \
	[[ "$$run_workdir_output" == *" alpine pwd"* ]]; \
	run_user_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -u 1000:1000 api id)"; \
	[[ "$$run_user_output" == *"--user 1000:1000"* ]]; \
	[[ "$$run_user_output" == *" alpine id"* ]]; \
	run_compact_user_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -u1000:1000 api id)"; \
	[[ "$$run_compact_user_output" == *"--user 1000:1000"* ]]; \
	[[ "$$run_compact_user_output" == *" alpine id"* ]]; \
	run_env_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -e LOG_LEVEL=debug --env-from-file .env.local api env)"; \
	[[ "$$run_env_output" == *"--env LOG_LEVEL=debug"* ]]; \
	[[ "$$run_env_output" == *"--env-file .env.local"* ]]; \
	[[ "$$run_env_output" == *" alpine env"* ]]; \
	run_compact_env_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -eLOG_LEVEL=trace api env)"; \
	[[ "$$run_compact_env_output" == *"--env LOG_LEVEL=trace"* ]]; \
	[[ "$$run_compact_env_output" == *" alpine env"* ]]; \
	run_label_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -l com.example.role=job api true)"; \
	[[ "$$run_label_output" == *"--label com.example.role=job"* ]]; \
	[[ "$$run_label_output" == *" alpine true"* ]]; \
	run_compact_label_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -lcom.example.compact=true api true)"; \
	[[ "$$run_compact_label_output" == *"--label com.example.compact=true"* ]]; \
	[[ "$$run_compact_label_output" == *" alpine true"* ]]; \
	run_volume_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -v /host:/container:ro api ls)"; \
	[[ "$$run_volume_output" == *"--volume /host:/container:ro"* ]]; \
	[[ "$$run_volume_output" == *" alpine ls"* ]]; \
	run_compact_volume_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -v/host:/container:ro api ls)"; \
	[[ "$$run_compact_volume_output" == *"--volume /host:/container:ro"* ]]; \
	[[ "$$run_compact_volume_output" == *" alpine ls"* ]]; \
	run_compact_workdir_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -w/workspace api pwd)"; \
	[[ "$$run_compact_workdir_output" == *"--workdir /workspace"* ]]; \
	[[ "$$run_compact_workdir_output" == *" alpine pwd"* ]]; \
	run_detached_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -d api sleep 60)"; \
	[[ "$$run_detached_output" == *"--detach"* ]]; \
	[[ "$$run_detached_output" == *" alpine sleep 60"* ]]; \
	run_tty_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run shell sh)"; \
	[[ "$$run_tty_output" == *"--tty"* ]]; \
	[[ "$$run_tty_output" == *"--interactive"* ]]; \
	run_no_tty_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run -T shell sh)"; \
	[[ "$$run_no_tty_output" != *"--tty"* ]]; \
	[[ "$$run_no_tty_output" == *"--interactive"* ]]; \
	run_deps_metadata_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run job true 2>&1 || true)"; \
	[[ "$$run_deps_metadata_output" == *"container inspect "*"db-1"* ]]; \
	[[ "$$run_deps_metadata_output" == *"--name "*"db-1 --detach"* ]]; \
	[[ "$$run_deps_metadata_output" == *"--name "*"job-run-"* ]]; \
	[[ "$$run_deps_metadata_output" == *" alpine true"* ]]; \
	run_no_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run --no-deps job true)"; \
	[[ "$$run_no_deps_output" == *"container run"* ]]; \
	[[ "$$run_no_deps_output" == *" alpine true"* ]]; \
	run_no_network_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" run isolated true)"; \
	[[ "$$run_no_network_output" == *"--network none"* ]]; \
	[[ "$$run_no_network_output" == *" alpine true"* ]]; \
	up_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up api)"; \
	[[ "$$up_output" == *"container network create --internal --subnet 10.77.0.0/24 --subnet-v6 fd77::/64"* ]]; \
	[[ "$$up_output" == *"container volume create --opt journal=ordered --opt size=64m"* ]]; \
	[[ "$$up_output" == *"container run"* ]]; \
	[[ "$$up_output" == *"demo-db-1"* ]]; \
	[[ "$$up_output" == *"--publish 8080:80"* ]]; \
	[[ "$$up_output" == *"--volume demo_cache:/db-cache:ro"* ]]; \
	[[ "$$up_output" == *"--volume $$tmpdir/api.conf:/etc/api.conf:ro"* ]]; \
	[[ "$$up_output" == *"--volume $$tmpdir/api-token.txt:/run/secrets/api_token:ro"* ]]; \
	[[ "$$up_output" == *"--dns-option use-vc"* ]]; \
	[[ "$$up_output" == *"--network demo_default,mac=02:42:ac:11:00:03,mtu=1450"* ]]; \
	[[ "$$up_output" == *"--label example.com/owner=platform"* ]]; \
	[[ "$$up_output" == *"--name demo-db-1 --detach"* ]]; \
	[[ "$$up_output" != *"--name demo-api-1 --detach"* ]]; \
	up_no_attach_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --no-attach api api)"; \
	[[ "$$up_no_attach_output" != *"--name demo-db-1 --detach"* ]]; \
	[[ "$$up_no_attach_output" == *"--name demo-api-1 --detach"* ]]; \
	up_attach_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --attach api api)"; \
	[[ "$$up_attach_output" == *"--name demo-db-1 --detach"* ]]; \
	[[ "$$up_attach_output" == *"--name demo-api-1 --detach"* ]]; \
	[[ "$$up_attach_output" == *"compose-runtime logs --follow demo-api-1"* ]]; \
	[[ "$$up_attach_output" != *"compose-runtime logs --follow demo-db-1"* ]]; \
	up_attach_dependencies_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --attach api --attach-dependencies api)"; \
	[[ "$$up_attach_dependencies_output" == *"compose-runtime logs --follow demo-db-1"* ]]; \
	[[ "$$up_attach_dependencies_output" == *"compose-runtime logs --follow demo-api-1"* ]]; \
	up_exit_code_from_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --exit-code-from api api)"; \
	[[ "$$up_exit_code_from_output" == *"--name demo-db-1 --detach"* ]]; \
	[[ "$$up_exit_code_from_output" == *"--name demo-api-1 --detach"* ]]; \
	[[ "$$up_exit_code_from_output" == *"compose-runtime wait demo-api-1"* ]]; \
	[[ "$$up_exit_code_from_output" == *"container stop demo-db-1"* ]]; \
	[[ "$$up_exit_code_from_output" == *"container delete demo-api-1"* ]]; \
	up_attach_false_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/attach-false.yml" up api)"; \
	[[ "$$up_attach_false_output" == *"--name demo-api-1 --detach"* ]]; \
	for unsupported_up_option in \
		"--menu"; do \
		up_unsupported_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up $$unsupported_up_option api 2>&1 || true)"; \
		up_unsupported_name="$${unsupported_up_option%% *}"; \
		[[ "$$up_unsupported_output" == *"unsupported compose feature: up $$up_unsupported_name"* ]]; \
	done; \
	up_timestamps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --timestamps api)"; \
	[[ "$$up_timestamps_output" == *"--name demo-api-1 --detach"* ]]; \
	[[ "$$up_timestamps_output" == *"compose-runtime logs --follow --timestamps demo-api-1"* ]]; \
	up_watch_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/watch.yml" up --watch --no-deps api)"; \
	[[ "$$up_watch_output" == *"compose: watch project demo services api"* ]]; \
	[[ "$$up_watch_output" == *"compose: watch initial-up enabled"* ]]; \
	[[ "$$up_watch_output" == *"compose: watch api rebuild path="*"/src"* ]]; \
	up_watch_detach_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/watch.yml" up --watch --detach api 2>&1 || true)"; \
	[[ "$$up_watch_detach_output" == *"unsupported compose feature: up --detach cannot be combined with --watch"* ]]; \
	up_watch_wait_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/watch.yml" up --watch --wait api 2>&1 || true)"; \
	[[ "$$up_watch_wait_output" == *"unsupported compose feature: up --wait cannot be combined with --watch"* ]]; \
	up_detached_log_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --detach --no-color --no-log-prefix --timestamps api)"; \
	[[ "$$up_detached_log_options_output" == *"container run"* ]]; \
	[[ "$$up_detached_log_options_output" == *"--name demo-api-1 --detach"* ]]; \
	up_wait_log_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --wait --no-color --no-log-prefix --timestamps api)"; \
	[[ "$$up_wait_log_options_output" == *"container run"* ]]; \
	[[ "$$up_wait_log_options_output" == *"--name demo-api-1 --detach"* ]]; \
	up_no_start_log_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --no-start --no-color --no-log-prefix --timestamps api)"; \
	[[ "$$up_no_start_log_options_output" == *"container create"* ]]; \
	up_quiet_pull_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --pull always --quiet-pull api)"; \
	[[ "$$up_quiet_pull_output" == *"container image pull --progress none alpine"* ]]; \
	[[ "$$up_quiet_pull_output" == *"container run"* ]]; \
	up_always_recreate_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --always-recreate-deps api)"; \
	[[ "$$up_always_recreate_deps_output" == *"container run"* ]]; \
	[[ "$$up_always_recreate_deps_output" == *"demo-db-1"* ]]; \
	[[ "$$up_always_recreate_deps_output" == *"demo-api-1"* ]]; \
	up_always_recreate_no_recreate_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --always-recreate-deps --no-recreate api 2>&1 || true)"; \
	[[ "$$up_always_recreate_no_recreate_output" == *"invalid compose project: --always-recreate-deps and --no-recreate are incompatible"* ]]; \
	up_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --timeout 12 api)"; \
	[[ "$$up_timeout_output" == *"container run"* ]]; \
	up_compact_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up -t12 api)"; \
	[[ "$$up_compact_timeout_output" == *"container run"* ]]; \
	up_invalid_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --timeout=-1 api 2>&1 || true)"; \
	[[ "$$up_invalid_timeout_output" == *"invalid compose project: up --timeout must be between 0 and 2147483647 seconds"* ]]; \
	up_no_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --no-deps api)"; \
	[[ "$$up_no_deps_output" == *"container run"* ]]; \
	[[ "$$up_no_deps_output" != *"demo-db-1"* ]]; \
	up_no_start_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --no-start api)"; \
	[[ "$$up_no_start_output" == *"container create"* ]]; \
	[[ "$$up_no_start_output" != *"container run"* ]]; \
	[[ "$$up_no_start_output" == *"demo-db-1"* ]]; \
	[[ "$$up_no_start_output" == *"demo-api-1"* ]]; \
	up_no_start_no_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --no-start --no-deps api)"; \
	[[ "$$up_no_start_no_deps_output" == *"container create"* ]]; \
	[[ "$$up_no_start_no_deps_output" != *"container run"* ]]; \
	[[ "$$up_no_start_no_deps_output" != *"demo-db-1"* ]]; \
	up_no_build_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" up --no-build worker)"; \
	[[ "$$up_no_build_output" == *"container run"* ]]; \
	[[ "$$up_no_build_output" != *"container build"* ]]; \
	[[ "$$up_no_build_output" == *"demo_worker:latest"* ]]; \
	up_quiet_build_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" up --quiet-build worker)"; \
	[[ "$$up_quiet_build_output" == *"container build"* ]]; \
	[[ "$$up_quiet_build_output" == *"--quiet"* ]]; \
	[[ "$$up_quiet_build_output" == *"container run"* ]]; \
	up_wait_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --wait --wait-timeout 3 api)"; \
	[[ "$$up_wait_output" == *"--name demo-db-1 --detach"* ]]; \
	[[ "$$up_wait_output" == *"--name demo-api-1 --detach"* ]]; \
	[[ "$$up_wait_output" == *"compose-runtime wait-ready --timeout 3 demo-db-1"* ]]; \
	[[ "$$up_wait_output" == *"compose-runtime wait-ready --timeout 3 demo-api-1"* ]]; \
	up_wait_no_start_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --wait --no-start api 2>&1 || true)"; \
	[[ "$$up_wait_no_start_output" == *"invalid compose project: --wait and --no-start are incompatible"* ]]; \
	up_renew_anon_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-volumes.yml" up --renew-anon-volumes --scale api=2 api)"; \
	[[ "$$up_renew_anon_output" == *"container volume delete demo_anon-api-1-"* ]]; \
	[[ "$$up_renew_anon_output" == *"container volume delete demo_anon-api-2-"* ]]; \
	[[ "$$up_renew_anon_output" == *"--name demo-api-1"* ]]; \
	[[ "$$up_renew_anon_output" == *"--name demo-api-2 --detach"* ]]; \
	up_renew_no_recreate_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-volumes.yml" up --renew-anon-volumes --no-recreate api 2>&1 || true)"; \
	[[ "$$up_renew_no_recreate_output" == *"invalid compose project: --no-recreate and --renew-anon-volumes are incompatible"* ]]; \
	up_build_no_build_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/build-only.yml" up --build --no-build worker 2>&1 || true)"; \
	[[ "$$up_build_no_build_output" == *"invalid compose project: --build and --no-build are incompatible"* ]]; \
	up_scale_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale.yml" up --scale worker=2 worker)"; \
	[[ "$$up_scale_output" == *"--name demo-worker-1"* ]]; \
	[[ "$$up_scale_output" == *"--name demo-worker-2 --detach"* ]]; \
	up_scale_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --scale api=2 api 2>&1 || true)"; \
	[[ "$$up_scale_ports_output" == *"unsupported compose feature: service 'api' publishes '8080:80'; scaled published ports require at least 2 explicit host ports for 2 replicas"* ]]; \
	up_scale_port_range_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-ports.yml" up --scale api=2 api)"; \
	[[ "$$up_scale_port_range_output" == *"--name demo-api-1"* ]]; \
	[[ "$$up_scale_port_range_output" == *"--publish 8080:80"* ]]; \
	[[ "$$up_scale_port_range_output" == *"--name demo-api-2 --detach"* ]]; \
	[[ "$$up_scale_port_range_output" == *"--publish 8081:80"* ]]; \
	up_scale_volume_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-volumes.yml" up --scale api=2 api)"; \
	[[ "$$up_scale_volume_output" == *"--volume demo_anon-api-1-"*":/scratch"* ]]; \
	[[ "$$up_scale_volume_output" == *"--volume demo_anon-api-2-"*":/scratch"* ]]; \
	create_scale_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale.yml" create --scale worker=2 worker)"; \
	[[ "$$create_scale_output" == *"--name demo-worker-1"* ]]; \
	[[ "$$create_scale_output" == *"--name demo-worker-2"* ]]; \
	scale_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale.yml" scale worker=2)"; \
	[[ "$$scale_output" == *"--name demo-worker-1 --detach"* ]]; \
	[[ "$$scale_output" == *"--name demo-worker-2 --detach"* ]]; \
	scale_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-deps.yml" scale api=2)"; \
	[[ "$$scale_deps_output" == *"--name demo-db-1 --detach"* ]]; \
	[[ "$$scale_deps_output" == *"--name demo-api-1 --detach"* ]]; \
	[[ "$$scale_deps_output" == *"--name demo-api-2 --detach"* ]]; \
	scale_no_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-deps.yml" scale --no-deps api=2)"; \
	[[ "$$scale_no_deps_output" != *"demo-db-1"* ]]; \
	[[ "$$scale_no_deps_output" == *"--name demo-api-1 --detach"* ]]; \
	[[ "$$scale_no_deps_output" == *"--name demo-api-2 --detach"* ]]; \
	alpha_scale_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/scale-deps.yml" alpha scale --no-deps api=2)"; \
	[[ "$$alpha_scale_output" != *"demo-db-1"* ]]; \
	[[ "$$alpha_scale_output" == *"--name demo-api-1 --detach"* ]]; \
	[[ "$$alpha_scale_output" == *"--name demo-api-2 --detach"* ]]; \
	scale_missing_output="$$(".build/debug/compose" --dry-run scale 2>&1 || true)"; \
	[[ "$$scale_missing_output" == *"invalid compose project: scale requires at least one SERVICE=REPLICAS argument"* ]]; \
	scale_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" scale api=2 2>&1 || true)"; \
	[[ "$$scale_ports_output" == *"unsupported compose feature: service 'api' publishes '8080:80'; scaled published ports require at least 2 explicit host ports for 2 replicas"* ]]; \
	create_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" create --build api)"; \
	[[ "$$create_output" == *"container create"* ]]; \
	[[ "$$create_output" == *"--publish 8080:80"* ]]; \
	[[ "$$create_output" == *"--dns-option use-vc"* ]]; \
	[[ "$$create_output" == *"--network demo_default,mac=02:42:ac:11:00:03,mtu=1450"* ]]; \
	[[ "$$create_output" != *"--detach"* ]]; \
	create_quiet_pull_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" create --pull always --quiet-pull api)"; \
	[[ "$$create_quiet_pull_output" == *"container image pull --progress none alpine"* ]]; \
	[[ "$$create_quiet_pull_output" == *"container create"* ]]; \
	create_dynamic_ports_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/dynamic-ports.yml" create api)"; \
	[[ "$$create_dynamic_ports_output" == *"--publish "*":80"* ]]; \
	detached_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --detach api)"; \
	[[ "$$detached_output" == *"container run"* ]]; \
	[[ "$$detached_output" == *"--detach"* ]]; \
	[[ "$$detached_output" == *"--name demo-api-1 --detach"* ]]; \
	up_menu_false_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --menu=false --no-start api)"; \
	[[ "$$up_menu_false_output" == *"container create --name demo-api-1"* ]]; \
	up_menu_true_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" up --menu=true --no-start api)"; \
	[[ "$$up_menu_true_output" == *"container create --name demo-api-1"* ]]; \
	logs_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs -f api)"; \
	[[ "$$logs_output" == *"container logs --follow"* ]]; \
	logs_scaled_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/logs-scale.yml" logs worker)"; \
	[[ "$$logs_scaled_output" == *"container logs demo-worker-1"* ]]; \
	[[ "$$logs_scaled_output" == *"container logs demo-worker-2"* ]]; \
	logs_tail_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs -n 5 api)"; \
	[[ "$$logs_tail_output" == *"container logs -n 5 demo-api-1"* ]]; \
	logs_compact_tail_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs -n5 api)"; \
	[[ "$$logs_compact_tail_output" == *"container logs -n 5 demo-api-1"* ]]; \
	logs_all_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --tail all api)"; \
	[[ "$$logs_all_output" == *"container logs demo-api-1"* ]]; \
	[[ "$$logs_all_output" != *" -n "* ]]; \
	logs_filter_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --since 2026-06-18T10:00:00Z --until 30m api)"; \
	[[ "$$logs_filter_output" == *"container logs --since 2026-06-18T10:00:00Z --until 30m demo-api-1"* ]]; \
	logs_timestamp_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --timestamps api)"; \
	[[ "$$logs_timestamp_output" == *"compose-runtime logs --timestamps demo-api-1"* ]]; \
	logs_filtered_follow_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --follow --since 2026-06-18T10:00:00Z api)"; \
	[[ "$$logs_filtered_follow_output" == *"compose-runtime logs --follow --since 2026-06-18T10:00:00Z demo-api-1"* ]]; \
	logs_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --index 2 api)"; \
	[[ "$$logs_index_output" == *"container logs demo-api-2"* ]]; \
	logs_display_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" logs --no-color --no-log-prefix api)"; \
	[[ "$$logs_display_output" == *"container logs demo-api-1"* ]]; \
	attach_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo attach --no-stdin api)"; \
	[[ "$$attach_output" == *"compose-runtime logs --follow demo-api-1"* ]]; \
	attach_detach_keys_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo attach --no-stdin --detach-keys=ctrl-x api)"; \
	[[ "$$attach_detach_keys_output" == *"compose-runtime logs --follow demo-api-1"* ]]; \
	attach_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo attach --no-stdin --sig-proxy=false --index 2 api)"; \
	[[ "$$attach_index_output" == *"compose-runtime logs --follow demo-api-2"* ]]; \
	attach_default_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" attach api 2>&1 || true)"; \
	[[ "$$attach_default_output" == *"unsupported compose feature: attach: apple/container does not expose stdin/stdout/stderr reattach"* ]]; \
	exec_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec api echo ok)"; \
	[[ "$$exec_output" == *"container exec --interactive --tty demo-api-1 echo ok"* ]]; \
	exec_no_tty_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -T api echo ok)"; \
	[[ "$$exec_no_tty_output" == *"container exec --interactive demo-api-1 echo ok"* ]]; \
	[[ "$$exec_no_tty_output" != *"--tty"* ]]; \
	exec_long_no_tty_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec --no-tty api echo ok)"; \
	[[ "$$exec_long_no_tty_output" == *"container exec --interactive demo-api-1 echo ok"* ]]; \
	[[ "$$exec_long_no_tty_output" != *"--tty"* ]]; \
	exec_non_interactive_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec --interactive=false -T api echo ok)"; \
	[[ "$$exec_non_interactive_output" == *"container exec demo-api-1 echo ok"* ]]; \
	[[ "$$exec_non_interactive_output" != *"--interactive"* ]]; \
	[[ "$$exec_non_interactive_output" != *"--tty"* ]]; \
	exec_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -e FOO=bar -u 1000:1000 -w /app api env)"; \
	[[ "$$exec_options_output" == *"container exec --env FOO=bar --user 1000:1000 --workdir /app --interactive --tty demo-api-1 env"* ]]; \
	exec_compact_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -eFOO=bar -u1000:1000 -w/app api env)"; \
	[[ "$$exec_compact_options_output" == *"container exec --env FOO=bar --user 1000:1000 --workdir /app --interactive --tty demo-api-1 env"* ]]; \
	exec_mixed_options_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -e FOO=bar -u1000:1000 -w/app api env)"; \
	[[ "$$exec_mixed_options_output" == *"container exec --env FOO=bar --user 1000:1000 --workdir /app --interactive --tty demo-api-1 env"* ]]; \
	exec_detach_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec -d api sleep 60)"; \
	[[ "$$exec_detach_output" == *"container exec --detach demo-api-1 sleep 60"* ]]; \
	[[ "$$exec_detach_output" != *"--interactive"* ]]; \
	[[ "$$exec_detach_output" != *"--tty"* ]]; \
	exec_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec --index 2 api true)"; \
	[[ "$$exec_index_output" == *"container exec --interactive --tty demo-api-2 true"* ]]; \
	exec_help_output="$$(".build/debug/compose" exec --help)"; \
	[[ "$$exec_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$exec_help_output" == *"Docker-complete privileged execution is unavailable."* ]]; \
	[[ "$$exec_help_output" == *"$${ansi_escape}[38;5;208m--privileged$${ansi_escape}[0m"* ]]; \
	exec_privileged_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo exec --privileged api true)"; \
	[[ "$$exec_privileged_output" == *"container exec --privileged --interactive --tty demo-api-1 true"* ]]; \
	cp_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp api:/tmp/file .)"; \
	[[ "$$cp_output" == *"container cp demo-api-1:/tmp/file ."* ]]; \
	cp_relative_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp api:tmp/file .)"; \
	[[ "$$cp_relative_output" == *"container cp demo-api-1:/tmp/file ."* ]]; \
	cp_stdin_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp - api:/tmp)"; \
	[[ "$$cp_stdin_output" == *"compose-runtime cp - demo-api-1:/tmp"* ]]; \
	cp_stdout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp api:/tmp/file -)"; \
	[[ "$$cp_stdout_output" == *"compose-runtime cp demo-api-1:/tmp/file -"* ]]; \
	cp_index_one_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp --index 1 api:/tmp/file .)"; \
	[[ "$$cp_index_one_output" == *"container cp demo-api-1:/tmp/file ."* ]]; \
	cp_archive_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp -a api:/tmp/file .)"; \
	[[ "$$cp_archive_output" == *"compose-runtime cp --archive demo-api-1:/tmp/file ."* ]]; \
	cp_follow_link_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp -L api:/tmp/file .)"; \
	[[ "$$cp_follow_link_output" == *"compose-runtime cp --follow-link demo-api-1:/tmp/file ."* ]]; \
	cp_all_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp --all api:/tmp/file .)"; \
	[[ "$$cp_all_output" == *"container cp demo-api-1:/tmp/file ."* ]]; \
	cp_all_service_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp --all api:/tmp/file db:/tmp/file)"; \
	[[ "$$cp_all_service_output" == *"container cp demo-api-1:/tmp/file demo-db-1:/tmp/file"* ]]; \
	cp_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo cp --index 2 api:/tmp/file .)"; \
	[[ "$$cp_index_output" == *"container cp demo-api-2:/tmp/file ."* ]]; \
	export_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo export api)"; \
	[[ "$$export_output" == *"container export demo-api-1"* ]]; \
	export_file_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo export -o api.tar api)"; \
	[[ "$$export_file_output" == *"container export --output api.tar demo-api-1"* ]]; \
	export_index_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo export --index 2 api)"; \
	[[ "$$export_index_output" == *"container export demo-api-2"* ]]; \
	stop_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo stop --timeout 12 api)"; \
	[[ "$$stop_timeout_output" == *"container stop --time 12 demo-api-1"* ]]; \
	stop_compact_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo stop -t12 api)"; \
	[[ "$$stop_compact_timeout_output" == *"container stop --time 12 demo-api-1"* ]]; \
	restart_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo restart -t 13 api)"; \
	restart_help_output="$$(".build/debug/compose" restart --help)"; \
	[[ "$$restart_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	[[ "$$restart_timeout_output" == *"container stop --time 13 demo-api-1"* ]]; \
	[[ "$$restart_timeout_output" == *"container stop --time 13 demo-db-1"* ]]; \
	[[ "$$restart_timeout_output" == *"container start demo-db-1"* ]]; \
	[[ "$$restart_timeout_output" == *"container start demo-api-1"* ]]; \
	restart_compact_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo restart -t13 api)"; \
	[[ "$$restart_compact_timeout_output" == *"container stop --time 13 demo-api-1"* ]]; \
	restart_no_deps_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo restart --no-deps -t 13 api)"; \
	[[ "$$restart_no_deps_output" == *"container stop --time 13 demo-api-1"* ]]; \
	[[ "$$restart_no_deps_output" == *"container start demo-api-1"* ]]; \
	[[ "$$restart_no_deps_output" != *"demo-db-1"* ]]; \
	kill_compact_signal_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo kill -sSIGKILL api)"; \
	[[ "$$kill_compact_signal_output" == *"container kill --signal SIGKILL demo-api-1"* ]]; \
	kill_remove_orphans_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo kill --remove-orphans api)"; \
	[[ "$$kill_remove_orphans_output" == *"compose-runtime kill demo-api-1"* ]]; \
	[[ "$$kill_remove_orphans_output" == *"container list --format json --all"* ]]; \
	rm_force_volumes_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo rm -fv api)"; \
	[[ "$$rm_force_volumes_output" == *"container delete --force demo-api-1"* ]]; \
	[[ "$$rm_force_volumes_output" == *"container volume delete demo_anon-"* ]]; \
	down_compact_timeout_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo down -t12)"; \
	[[ "$$down_compact_timeout_output" == *"container stop --time 12 demo-api-1"* ]]; \
	down_service_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo down api)"; \
	[[ "$$down_service_output" == *"container stop demo-api-1"* ]]; \
	[[ "$$down_service_output" != *"demo-db-1"* ]]; \
	[[ "$$down_service_output" != *"container network delete"* ]]; \
	down_rmi_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo down --rmi all)"; \
	[[ "$$down_rmi_output" == *"container image delete --force alpine"* ]]; \
	ps_quiet_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps -q)"; \
	[[ "$$ps_quiet_output" == *"container list --format json"* ]]; \
	ps_service_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps api)"; \
	[[ "$$ps_service_output" == *"container list --format json"* ]]; \
	ps_services_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps --services)"; \
	[[ "$$ps_services_output" == *"container list --format json"* ]]; \
	ps_status_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps --status running)"; \
	[[ "$$ps_status_output" == *"container list --format json --all"* ]]; \
	ps_status_paused_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps --status paused)"; \
	[[ "$$ps_status_paused_output" == *"container list --format json --all"* ]]; \
	ps_filter_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps --filter status=exited)"; \
	[[ "$$ps_filter_output" == *"container list --format json --all"* ]]; \
	ps_format_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps --format json --no-trunc --orphans)"; \
	[[ "$$ps_format_output" == *"container list --format json"* ]]; \
	ps_bad_format_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo ps --format '{{.Command}}' 2>&1 || true)"; \
	[[ "$$ps_bad_format_output" == *"unsupported compose feature: ps --format field '.Command'; supported fields are ExitCode, Health, ID, Image, Name, Ports, Project, Publishers, Service, State, Status"* ]]; \
	images_json_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo images --format json api)"; \
	[[ "$$images_json_output" == *"container list --format json --all"* ]]; \
	images_quiet_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo images -q api)"; \
	[[ "$$images_quiet_output" == *"container list --format json --all"* ]]; \
	images_bad_format_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo images --format '{{.Size}}' api 2>&1 || true)"; \
	[[ "$$images_bad_format_output" == *"unsupported compose feature: images --format '{{.Size}}'; supported formats are table and json"* ]]; \
	volumes_help_output="$$(".build/debug/compose" volumes --help)"; \
	[[ "$$volumes_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$volumes_help_output" == *"Go-template control blocks and nested object paths are unavailable."* ]]; \
	[[ "$$volumes_help_output" == *"$${ansi_escape}[32m--format$${ansi_escape}[0m"* ]]; \
	volumes_json_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo volumes --format json api)"; \
	[[ "$$volumes_json_output" == *"container volume list --format json"* ]]; \
	volumes_quiet_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo volumes -q api)"; \
	[[ "$$volumes_quiet_output" == *"container volume list --format json"* ]]; \
	volumes_bad_format_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo volumes --format '{{.Foo}}' api 2>&1 || true)"; \
	[[ "$$volumes_bad_format_output" == *"unsupported compose feature: volumes --format field '.Foo'; supported fields are Availability, Driver, Group, Labels, Links, Mountpoint, Name, Scope, Size, Status"* ]]; \
	stats_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo stats --no-stream --format json api db)"; \
	[[ "$$stats_output" == *"container stats --format json --no-stream demo-api-1 demo-db-1"* ]]; \
	stats_template_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo stats --no-stream --format '{{.Container}}' api)"; \
	[[ "$$stats_template_output" == *"container stats --format '{{.Container}}' --no-stream demo-api-1"* ]]; \
	stats_bad_format_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo stats --format '{{.Scope}}' api 2>&1 || true)"; \
	[[ "$$stats_bad_format_output" == *"unsupported compose feature: stats --format field '.Scope'; supported fields are BlockIO, CPUPerc, Container, ID, MemPerc, MemUsage, Name, NetIO, PIDs"* ]]; \
	stats_no_trunc_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" -p demo stats --no-stream --no-trunc api)"; \
	[[ "$$stats_no_trunc_output" == *"container stats --no-stream --no-trunc demo-api-1"* ]]; \
	ls_json_output="$$(".build/debug/compose" --dry-run ls --format json)"; \
	[[ "$$ls_json_output" == *"container list --format json"* ]]; \
	[[ "$$ls_json_output" != *"--all"* ]]; \
	ls_all_output="$$(".build/debug/compose" --dry-run ls --all --filter name=demo)"; \
	[[ "$$ls_all_output" == *"container list --format json --all"* ]]; \
	top_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" top api)"; \
	[[ "$$top_output" == *"+ compose-runtime top demo-api-1"* ]]; \
	events_help_output="$$(".build/debug/compose" events --help)"; \
	[[ "$$events_help_output" == *"Support: $${ansi_escape}[38;5;208mpartially supported$${ansi_escape}[0m"* ]]; \
	[[ "$$events_help_output" == *"The Docker event-action vocabulary is incomplete."* ]]; \
	events_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" events --json)"; \
	[[ "$$events_output" == *"+ container events"* ]]; \
	port_help_output="$$(".build/debug/compose" port --help)"; \
	[[ "$$port_help_output" == *"Support: $${ansi_escape}[32msupported$${ansi_escape}[0m"* ]]; \
	port_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" port api 80)"; \
	[[ "$$port_output" == *"0.0.0.0:8080"* ]]; \
	pause_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" pause api)"; \
	[[ "$$pause_output" == *"compose-runtime pause demo-api-1"* ]]; \
	unpause_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" unpause api)"; \
	[[ "$$unpause_output" == *"compose-runtime unpause demo-api-1"* ]]; \
	start_wait_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" start --wait --wait-timeout 3 api)"; \
	[[ "$$start_wait_output" == *"container start demo-api-1"* ]]; \
	[[ "$$start_wait_output" == *"compose-runtime wait-ready --timeout 3 demo-api-1"* ]]; \
	wait_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" wait api)"; \
	[[ "$$wait_output" == *"container wait demo-api-1"* ]]; \
	wait_down_project_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" wait --down-project api)"; \
	[[ "$$wait_down_project_output" == *"container wait demo-api-1"* ]]; \
	[[ "$$wait_down_project_output" == *"container delete demo-api-1"* ]]; \
	watch_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/watch.yml" watch --no-up --no-prune --quiet api)"; \
	[[ "$$watch_output" == *"compose: watch project demo services api"* ]]; \
	[[ "$$watch_output" == *"compose: watch initial-up disabled"* ]]; \
	[[ "$$watch_output" == *"compose: watch prune disabled"* ]]; \
	[[ "$$watch_output" == *"compose: watch quiet enabled"* ]]; \
	[[ "$$watch_output" == *"compose: watch api rebuild path="*"/src"* ]]; \
	alpha_watch_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/watch.yml" alpha watch --no-up --quiet api)"; \
	[[ "$$alpha_watch_output" == *"compose: watch project demo services api"* ]]; \
	[[ "$$alpha_watch_output" == *"compose: watch initial-up disabled"* ]]; \
	[[ "$$alpha_watch_output" == *"compose: watch quiet enabled"* ]]; \
	[[ "$$alpha_watch_output" == *"compose: watch api rebuild path="*"/src"* ]]; \
	alpha_dry_run_output="$$(".build/debug/compose" -f "$$tmpdir/compose.yml" alpha dry-run -- up api)"; \
	[[ "$$alpha_dry_run_output" == *"container create"* ]]; \
	[[ "$$alpha_dry_run_output" == *"container run --name demo-api-1"* ]]; \
	commit_output="$$(".build/debug/compose" --dry-run --project-name demo -f "$$tmpdir/compose.yml" commit --change 'ENV SNAPSHOT=true' api example/api:snapshot)"; \
	[[ "$$commit_output" == *"compose-runtime export --output /tmp/demo-api-1-commit-rootfs.tar demo-api-1"* ]]; \
	[[ "$$commit_output" == *"compose-runtime commit-archive"* ]]; \
	[[ "$$commit_output" == *"--change 'ENV SNAPSHOT=true'"* ]]; \
	[[ "$$commit_output" == *"compose-runtime image load --input /tmp/demo-api-1-commit-image.tar"* ]]; \
	publish_output="$$(".build/debug/compose" --dry-run -f "$$tmpdir/compose.yml" publish example/app:latest)"; \
	[[ "$$publish_output" == *"container image push alpine"* ]]; \
	[[ "$$publish_output" == *"DRY-RUN MODE - would publish example/app:latest as OCI auto"* ]]; \
	[[ "$$publish_output" == *"+ publish layer compose compose.yml sha256:"* ]]

docker-log-fixtures:
	./scripts/capture-docker-compose-log-fixtures.sh

docker-log-fixtures-update:
	./scripts/capture-docker-compose-log-fixtures.sh --update

container-stack-build:
	@if [[ -f "$(CONTAINER_STACK_REPO)/Makefile" ]]; then \
		$(MAKE) -C "$(CONTAINER_STACK_REPO)" container; \
	else \
		printf 'warning: sibling container repo not found at %s; using CONTAINER_COMPOSE_CONTAINER=%s\n' \
			"$(CONTAINER_STACK_REPO)" "$(CONTAINER_COMPOSE_CONTAINER)" >&2; \
	fi

.PHONY: container-stack-release-validation container-stack-hosted-release-validation
container-stack-release-validation:
	./Tools/ci/run-stack-release-validation.sh full "$(CURDIR)" \
		"$(CONTAINER_BUILDER_SHIM_STACK_REPO)" "$(CONTAINERIZATION_STACK_REPO)" \
		"$(CONTAINER_STACK_REPO)" "$(HOMEBREW_TAP_REPO)"

container-stack-hosted-release-validation:
	./Tools/ci/run-stack-release-validation.sh hosted "$(CURDIR)" \
		"$(CONTAINER_BUILDER_SHIM_STACK_REPO)" "$(CONTAINERIZATION_STACK_REPO)" \
		"$(CONTAINER_STACK_REPO)" "$(HOMEBREW_TAP_REPO)"

docker-compose-reference:
	DOCKER_COMPOSE="$(DOCKER_COMPOSE_REFERENCE)" DOCKER_COMPOSE_REFERENCE_VERSION="$(DOCKER_COMPOSE_REFERENCE_VERSION)" \
		./Tools/parity/check-docker-compose-reference.sh --strict

docker-compose-e2e-fixtures:
	DOCKER_COMPOSE_E2E_REF="$(DOCKER_COMPOSE_E2E_REF)" ./Tools/parity/sync-docker-compose-e2e-fixtures.sh --strict

docker-compose-parity: container-stack-build docker-compose-reference
	container_binary="$(CONTAINER_COMPOSE_CONTAINER)"; \
	if [[ "$$container_binary" == "container" ]]; then \
		for candidate in "$(LOCAL_CONTAINER_BINARY)" "$(LOCAL_CONTAINER_PACKAGE_BINARY)"; do \
			if [[ -x "$$candidate" ]]; then container_binary="$$candidate"; break; fi; \
		done; \
	fi; \
	CONTAINER_RUNTIME_STOP_HELPER="$(CONTAINER_RUNTIME_STOP_HELPER)" \
		CONTAINER_RUNTIME_APP_ROOT="$(CONTAINER_RUNTIME_APP_ROOT)" \
		CONTAINER_RUNTIME_INIT_BLOCK_REPO="$(CONTAINER_RUNTIME_INIT_BLOCK_REPO)" \
		CONTAINERIZATION_INIT_SOURCE_PATH="$(CONTAINERIZATION_INIT_SOURCE_PATH)" \
		./scripts/run-with-container-runtime.sh "$$container_binary" \
		$(MAKE) --no-print-directory -j1 \
			CONTAINER_COMPOSE_CONTAINER="$$container_binary" \
			DOCKER_COMPOSE_REFERENCE="$(DOCKER_COMPOSE_REFERENCE)" \
			DOCKER_COMPOSE_REFERENCE_VERSION="$(DOCKER_COMPOSE_REFERENCE_VERSION)" \
			DOCKER_COMPOSE_E2E_REF="$(DOCKER_COMPOSE_E2E_REF)" \
			CONTAINER_COMPOSE_LIVE=1 \
			CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1 \
			$(DOCKER_COMPOSE_PARITY_TARGETS)

docker-compose-named-volume-reuse-parity: build docker-compose-reference

	$(PARITY_ENV) ./Tools/parity/check-compose-named-volume-reuse.sh --strict

docker-compose-cli-surface-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-cli-surface.sh --strict

docker-compose-environment-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-environment.sh --strict

docker-compose-format-template-actions-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-format-template-actions.sh --strict

docker-compose-bridge-parity: build docker-compose-reference docker-compose-e2e-fixtures
	$(PARITY_ENV) ./Tools/parity/check-compose-bridge.sh --strict

docker-compose-compatibility-names-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-compatibility-names.sh --strict

docker-compose-config-all-resources-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-config-all-resources.sh --strict

docker-compose-env-file-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-env-file.sh --strict

docker-compose-git-remote-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-git-remote.sh --strict

docker-compose-commit-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-commit.sh --strict

docker-compose-cp-stdio-archive-streams-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-cp-stdio-archive-streams.sh --strict

docker-compose-build-builder-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-build-builder.sh --strict

docker-compose-build-check-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-build-check.sh --strict

docker-compose-build-isolation-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-build-isolation.sh --strict

docker-compose-build-secret-metadata-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-build-secret-metadata.sh --strict

docker-compose-bind-create-host-path-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-bind-create-host-path.sh --strict

docker-compose-bind-propagation-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-bind-propagation.sh --strict

docker-compose-image-volumes-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-image-volumes.sh --strict

docker-compose-volume-labels-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-volume-labels.sh --strict

docker-compose-deploy-endpoint-mode-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-deploy-endpoint-mode.sh --strict

docker-compose-deploy-resource-reservations-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-deploy-resource-reservations.sh --strict

docker-compose-cpu-limit-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-cpu-limit.sh --strict

docker-compose-cpu-cfs-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-cpu-cfs.sh --strict

docker-compose-cpu-shares-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-cpu-shares.sh --strict

docker-compose-cpuset-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-cpuset.sh --strict

docker-compose-pid-namespace-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-pid-namespace.sh --strict

docker-compose-cgroup-namespace-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-cgroup-namespace.sh --strict

docker-compose-cgroup-parent-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-cgroup-parent.sh --strict

docker-compose-ipc-uts-namespace-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-ipc-uts-namespace.sh --strict

docker-compose-userns-mode-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-userns-mode.sh --strict

docker-compose-privileged-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-privileged.sh --strict

docker-compose-security-opt-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-security-opt.sh --strict

docker-compose-stop-defaults-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-stop-defaults.sh --strict

docker-compose-deploy-scheduler-metadata-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-deploy-scheduler-metadata.sh --strict

docker-compose-memory-byte-precision-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-memory-byte-precision.sh --strict

docker-compose-memory-swap-limit-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-memory-swap-limit.sh --strict

docker-compose-pids-limit-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-pids-limit.sh --strict

docker-compose-device-cgroup-rules-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-device-cgroup-rules.sh --strict

docker-compose-devices-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-devices.sh --strict

docker-compose-gpus-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-gpus.sh --strict

docker-compose-network-driver-opts-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-network-driver-opts.sh --strict

docker-compose-network-attachable-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-network-attachable.sh --strict

docker-compose-network-ipv6-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-network-ipv6.sh --strict

docker-compose-network-ipam-options-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-network-ipam-options.sh --strict

docker-compose-up-menu-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-up-menu.sh --strict

docker-compose-host-namespaces-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-host-namespaces.sh --strict

docker-compose-health-wait-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-health-wait.sh --strict

docker-compose-create-options-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-create-options.sh --strict

docker-compose-events-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-events.sh --strict

docker-compose-rm-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-rm.sh --strict

docker-compose-restart-policy-parity: build docker-compose-reference
	$(PARITY_ENV) ./Tools/parity/check-compose-restart-policy.sh --strict

coverage: swift-coverage go-test

coverage-check: coverage
	$(PYTHON) Tools/coverage/check-coverage.py \
		--swift-minimum "$(SWIFT_COVERAGE_MIN)" \
		--go-minimum "$(GO_COVERAGE_MIN)" \
		--swift coverage.xml \
		--go Tools/compose-normalizer/coverage.out

sonar: coverage sonar-scan

sonar-scan:
	@test -f coverage.xml || { \
		printf 'coverage.xml is missing; run make coverage or make ci before make sonar-scan\n' >&2; \
		exit 2; \
	}
	@test -f Tools/compose-normalizer/coverage.out || { \
		printf 'Tools/compose-normalizer/coverage.out is missing; run make coverage or make ci before make sonar-scan\n' >&2; \
		exit 2; \
	}
	@sonar_token="$${SONAR_TOKEN:-$${SONAR_TOKEN_PERSONAL:-}}"; \
	if [[ -z "$$sonar_token" ]]; then \
		printf 'SONAR_TOKEN or SONAR_TOKEN_PERSONAL is required for make sonar\n' >&2; \
		exit 2; \
	fi
	sonar_token="$${SONAR_TOKEN:-$${SONAR_TOKEN_PERSONAL:-}}"; \
	branch="$${SONAR_BRANCH:-$$(git branch --show-current 2>/dev/null || true)}"; \
	attempt=1; \
	max_attempts="$(SONAR_SCAN_ATTEMPTS)"; \
	scanner_args=(-Dsonar.qualitygate.wait="$(SONAR_QUALITYGATE_WAIT)"); \
	if [[ -n "$$branch" && "$$branch" != "HEAD" ]]; then \
		scanner_args=(-Dsonar.branch.name="$$branch" "$${scanner_args[@]}"); \
	fi; \
	while true; do \
		set +e; \
		SONAR_TOKEN="$$sonar_token" sonar-scanner "$${scanner_args[@]}"; \
		status="$$?"; \
		set -e; \
		if [[ "$$status" -eq 0 ]]; then \
			exit 0; \
		fi; \
		if (( attempt >= max_attempts )); then \
			exit "$$status"; \
		fi; \
		printf 'Sonar scanner failed with exit %s; retrying %s/%s after 20 seconds...\n' "$$status" "$$((attempt + 1))" "$$max_attempts" >&2; \
		sleep 20; \
		((attempt += 1)); \
	done

package: package-release

package-release: PACKAGE_BUILD_CONFIGURATION = release
package-release: build-release go-build
	$(MAKE) package-built PACKAGE_BUILD_CONFIGURATION="$(PACKAGE_BUILD_CONFIGURATION)"

package-debug: PACKAGE_BUILD_CONFIGURATION = debug
package-debug: build go-build
	$(MAKE) package-built PACKAGE_BUILD_CONFIGURATION="$(PACKAGE_BUILD_CONFIGURATION)"

package-built:
	$(MAKE) go-release-check
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)/compose/bin" "$(DIST_DIR)/compose/resources"
	cp ".build/$(PACKAGE_BUILD_CONFIGURATION)/compose" "$(DIST_DIR)/compose/bin/compose"
	cp config.toml "$(DIST_DIR)/compose/config.toml"
	cp Tools/compose-normalizer/compose-normalizer "$(DIST_DIR)/compose/resources/compose-normalizer"
	cp "$(PLUGIN_ICON)" "$(DIST_DIR)/compose/resources/container-compose-icon.png"
	$(PYTHON) Tools/release/write-build-info.py \
		--output "$(DIST_DIR)/compose/resources/build-info.json" \
		--version "$(COMPOSE_VERSION)" \
		--source "$(CONTAINER_COMPOSE_SOURCE)" \
		--branch "$(CONTAINER_COMPOSE_BRANCH)" \
		--lane "$(CONTAINER_COMPOSE_LANE)" \
		--commit "$(CONTAINER_COMPOSE_COMMIT)" \
		--build-type "$(PACKAGE_BUILD_CONFIGURATION)" \
		--container-source "$(CONTAINER_SOURCE)" \
		--container-ref "$(CONTAINER_REF)" \
		--containerization-source "$(CONTAINERIZATION_SOURCE)" \
		--containerization-ref "$(CONTAINERIZATION_REF)" \
		--compose-go-version "$(COMPOSE_GO_VERSION)"
	tar -czf "$(PLUGIN_ARCHIVE)" -C "$(DIST_DIR)" compose
	tar -tzf "$(PLUGIN_ARCHIVE)" | grep -Fx 'compose/resources/container-compose-icon.png' >/dev/null
	shasum -a 256 "$(PLUGIN_ARCHIVE)" > "$(PLUGIN_ARCHIVE).sha256"

coverage-tools-test:
	$(PYTHON) -m py_compile Tools/coverage/*.py Tools/release/*.py Tools/ci/*.py
	$(PYTHON) -m unittest discover Tools/coverage
	$(PYTHON) -m unittest discover Tools/release
	$(PYTHON) -m unittest discover Tools/ci
	Tools/release/test_publish_github_release.sh

upstream-divergence-report:
	$(PYTHON) Tools/ci/upstream-divergence-report.py --fetch --output .build/reports/upstream-divergence.md --json-output .build/reports/upstream-divergence.json

upstream-divergence-check:
	$(PYTHON) Tools/ci/upstream-divergence-report.py --fetch --strict --output .build/reports/upstream-divergence.md --json-output .build/reports/upstream-divergence.json

upstream-divergence-release-check:
	$(PYTHON) Tools/ci/upstream-divergence-report.py --fetch --strict --require-upstream-current --output .build/reports/upstream-divergence.md --json-output .build/reports/upstream-divergence.json

docs:
	@printf 'Building DocC API documentation...\n'
	@rm -rf "$(DOCS_OUTPUT_DIR)"
	@DOCS_SCRATCH_PATH="$(DOCS_SCRATCH_PATH)" ./scripts/make-docs.sh "$(DOCS_OUTPUT_DIR)" "$(DOCS_HOSTING_BASE_PATH)"

serve-docs:
	@printf 'To browse: open http://127.0.0.1:8000/$(DOCS_HOSTING_BASE_PATH)/documentation/\n'
	@rm -rf "$(DOCS_SERVER_DIR)"
	@mkdir -p "$(DOCS_SERVER_DIR)"
	@cp -a "$(DOCS_OUTPUT_DIR)" "$(DOCS_SERVER_DIR)/$(DOCS_HOSTING_BASE_PATH)"
	@$(PYTHON) -m http.server --bind 127.0.0.1 --directory "$(DOCS_SERVER_DIR)"

stack-consistency:
	CONTAINER_STACK_REPO="$(CONTAINER_STACK_REPO)" $(PYTHON) Tools/ci/check-stack-consistency.py

worktree-audit:
	$(PYTHON) Tools/ci/worktree-audit.py --repository "$(CURDIR)" --main main

worktree-audit-strict:
	$(PYTHON) Tools/ci/worktree-audit.py --repository "$(CURDIR)" --main main --strict

check: lint stack-consistency check-licenses

lint: coverage-tools-test
	@while IFS= read -r -d '' script; do \
		bash -n "$$script"; \
	done < <(find scripts Tools/parity Tools/release -type f \( -name '*.sh' -o -name 'pre-commit.fmt' \) -print0)
	@if command -v "$(MARKDOWNLINT)" >/dev/null 2>&1; then \
		"$(MARKDOWNLINT)" $(MARKDOWN_FILES); \
	elif command -v markdownlint-cli2 >/dev/null 2>&1; then \
		markdownlint-cli2 $(MARKDOWN_FILES); \
	else \
		printf 'markdownlint is required; install markdownlint-cli or set MARKDOWNLINT=/path/to/markdownlint\n' >&2; \
		exit 1; \
	fi
	@unformatted="$$(find Tools/compose-normalizer -name '*.go' -type f -print0 | xargs -0 gofmt -l)"; \
	if [[ -n "$$unformatted" ]]; then \
		printf 'Go files need formatting:\n%s\n' "$$unformatted" >&2; \
		exit 1; \
	fi

fmt: format

format: update-licenses
	cd Tools/compose-normalizer && $(GO) fmt ./...

check-licenses:
	@./scripts/ensure-hawkeye-exists.sh
	@$(HAWKEYE) check --fail-if-unknown

update-licenses:
	@./scripts/ensure-hawkeye-exists.sh
	@$(HAWKEYE) format --fail-if-unknown --fail-if-updated false

pre-commit:
	$(eval HOOKS_DIR := $(shell git rev-parse --git-path hooks))
	cp scripts/pre-commit.fmt "$(HOOKS_DIR)/"
	touch "$(HOOKS_DIR)/pre-commit"
	grep -v 'hooks/pre-commit\.fmt' "$(HOOKS_DIR)/pre-commit" > /tmp/container-compose-pre-commit.new || true
	printf 'PRECOMMIT_NOFMT=$${PRECOMMIT_NOFMT} "$$(git rev-parse --git-path hooks/pre-commit.fmt)"\n' >> /tmp/container-compose-pre-commit.new
	mv /tmp/container-compose-pre-commit.new "$(HOOKS_DIR)/pre-commit"
	chmod +x "$(HOOKS_DIR)/pre-commit"
	@./scripts/ensure-hawkeye-exists.sh

clean:
	$(SWIFT) package clean
	rm -rf "$(DIST_DIR)" "$(PLUGIN_ARCHIVE)" "$(DOCS_OUTPUT_DIR)" "$(DOCS_SERVER_DIR)" "$(DOCS_SCRATCH_PATH)" .scannerwork coverage.lcov coverage.out coverage.report coverage.xml
	rm -f *.profraw Tools/compose-normalizer/coverage.out Tools/compose-normalizer/compose-normalizer
	find Tools -type d -name __pycache__ -prune -exec rm -rf {} +
