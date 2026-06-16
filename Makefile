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

SWIFT ?= swift
GO ?= go
PYTHON ?= python3
COVERAGE_MIN ?= 85
DIST_DIR ?= dist
PLUGIN_ARCHIVE ?= container-compose-plugin.tar.gz

.PHONY: all workflow ci clean run build build-release test resolve swift-test swift-coverage go-test go-build coverage coverage-check sonar package lint format

all: workflow

workflow: ci package

ci: resolve lint build coverage-check go-build

resolve:
	$(SWIFT) package resolve

build:
	$(SWIFT) build

build-release:
	$(SWIFT) build -c release --product compose

run:
	$(SWIFT) run compose version

test: swift-test go-test

swift-test:
	$(SWIFT) test --enable-code-coverage

swift-coverage: swift-test
	test_binary="$$(find .build -path '*.xctest/Contents/MacOS/*' -type f | head -n 1)"; \
	profile="$$(find .build -path '*/codecov/default.profdata' -type f | head -n 1)"; \
	xcrun llvm-cov export \
		-format=lcov \
		-instr-profile="$$profile" \
		"$$test_binary" \
		--sources Sources/ComposeCore \
		> coverage.lcov; \
	$(PYTHON) Tools/coverage/lcov-to-sonarqube-generic.py coverage.lcov coverage.xml

go-test:
	cd Tools/compose-normalizer && $(GO) test ./... -coverprofile=coverage.out -covermode=atomic

go-build:
	cd Tools/compose-normalizer && $(GO) build -o compose-normalizer .

coverage: swift-coverage go-test

coverage-check: coverage
	$(PYTHON) Tools/coverage/check-coverage.py \
		--minimum "$(COVERAGE_MIN)" \
		--swift coverage.xml \
		--go Tools/compose-normalizer/coverage.out

sonar: coverage
	@if [[ -z "$${SONAR_TOKEN:-}" ]]; then \
		printf 'SONAR_TOKEN is required for make sonar\n' >&2; \
		exit 2; \
	fi
	sonar-scanner

package: build-release
	cd Tools/compose-normalizer && $(GO) build -o compose-normalizer .
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)/compose/bin" "$(DIST_DIR)/compose/resources"
	cp .build/release/compose "$(DIST_DIR)/compose/bin/compose"
	cp config.toml "$(DIST_DIR)/compose/config.toml"
	cp Tools/compose-normalizer/compose-normalizer "$(DIST_DIR)/compose/resources/compose-normalizer"
	tar -czf "$(PLUGIN_ARCHIVE)" -C "$(DIST_DIR)" compose

lint:
	$(PYTHON) -m py_compile Tools/coverage/*.py
	@if command -v markdownlint >/dev/null 2>&1; then \
		markdownlint README.md; \
	elif command -v markdownlint-cli2 >/dev/null 2>&1; then \
		markdownlint-cli2 README.md; \
	else \
		printf 'markdownlint not installed; skipping README lint\n'; \
	fi
	@unformatted="$$(find Tools/compose-normalizer -name '*.go' -type f -print0 | xargs -0 gofmt -l)"; \
	if [[ -n "$$unformatted" ]]; then \
		printf 'Go files need formatting:\n%s\n' "$$unformatted" >&2; \
		exit 1; \
	fi

format:
	cd Tools/compose-normalizer && $(GO) fmt ./...

clean:
	$(SWIFT) package clean
	rm -rf "$(DIST_DIR)" "$(PLUGIN_ARCHIVE)" coverage.lcov coverage.report coverage.xml
	rm -f Tools/compose-normalizer/coverage.out Tools/compose-normalizer/compose-normalizer
	find Tools -type d -name __pycache__ -prune -exec rm -rf {} +
