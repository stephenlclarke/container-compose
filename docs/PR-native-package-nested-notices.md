# fix(package): retain nested notices for admitted native layers

## Motivation

The actual native checkpoint passed compilation and eleven unit targets, then package smoke failed before archive creation because binary dependency metadata did not traverse nested source-license declarations. Keep that original failure intact.

## Implementation

Declare the five required nested Swift notices and the Crypto/NIOSSL root NOTICE texts already required by archive smoke tests as direct metadata-action inputs. Merge them with aspect notices through existing deterministic headings and conflict/empty checks; reject duplicate or unrecognized explicit inputs. The complete inventory requirement remains unchanged.

Add a finite native override to the reviewed vendor inventory, selected only for admitted enhanced native metadata and still checked against exact repository/revision pins. Record the actual current NIO, Crypto and fork NIOSSL provenance, including NIOSSL's BoringSSL revision and exact upstream notice. Default profile provenance and distribution/closure flags remain unchanged. All variant notice inputs are declared; only selected provenance is emitted.

## Validation

All 23 offline package tests pass. New cases reproduce missing nested aspect inputs, restore exact deterministic output through explicit inputs, reject duplicates/unknown paths/conflicting or empty texts, and validate current native vendor provenance while rejecting default/stale pins and stock selection. An offline replay of the actual retained failed manifest first reproduces the missing-notice error, then assembles 122 notice texts with all five nested requirements, both required root NOTICE texts and current native vendor/source provenance. All existing archive metadata/notice assertions also pass against real-input offline metadata; archive layout and CLI execution remain pending. This is not execution of the Bazel package action or package smoke test.

Root owns the fresh immutable native packaging checkpoint. No heavy build, runtime, benchmark or baseline rerun is performed here. See [ISSUE-native-package-nested-notices.md](ISSUE-native-package-nested-notices.md).

## Native label-export correction

The next actual checkpoint exposed a distinct analysis error: all seven notice files exist, but published native package BUILD files do not export their file labels. A small `notice_exports.bzl` repository rule now reads them through the five packages' public `pkg_info.json` labels and exports exactly seven copied texts from an independent metadata-only repository. `dependencies.bzl` creates this repository for either source or native selection; the root imports it and candidate metadata consumes its closed filegroup. Imported package BUILD files, lower archives, source SwiftPM generation and the strict action-graph verifier remain unchanged.

Four focused offline repository-template regressions execute the maintained template against a file-backed context. They prove exact public label/input closure, unchanged original package bytes, preserved metadata headings and rejection of missing, empty, escaping or incomplete/duplicate package inputs. Command: `PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 -m unittest Tools.bazel.test_notice_exports -v`. The four tests are registered in the maintained `bazel-workflow-tools-test` inventory. They also pass with its `PYTHONPATH="Tools/bazel:Tools/bazel/artifacts"` setting. Actual Bazel repository analysis and package smoke remain root-owned pending gates; no heavy work is performed by this correction.

## CLI assertion-only quoting correction

The v5 direct release contract failure is distinct from notice assembly: production emitted the correctly quoted executable in a path containing spaces, while two foreground create/start assertions interpolated the path without quoting. Use the already imported `shlex.quote` for those two expected tokens. An audit found no other raw `self.runtime` string interpolation; the remaining runtime expectations compare `shlex.split` argument vectors. All argument/order, attachment and no-runtime-execution assertions remain intact.

The retained failed case is the actual quoted-path regression. Source-only syntax and replay of its captured output can check the corrected expectation; fresh execution of all 42 CLI cases remains root-owned against the existing release product. Preserve the v5 failure and do not advertise an unexecuted pass or rebuilt binary.
