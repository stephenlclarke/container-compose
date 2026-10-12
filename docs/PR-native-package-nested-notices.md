# fix(package): retain nested notices for admitted native layers

## Motivation

The actual native checkpoint passed compilation and eleven unit targets, then package smoke failed before archive creation because binary dependency metadata did not traverse nested source-license declarations. Keep that original failure intact.

## Implementation

Declare the five required nested Swift notices and the Crypto/NIOSSL root NOTICE texts already required by archive smoke tests as direct metadata-action inputs. Merge them with aspect notices through existing deterministic headings and conflict/empty checks; reject duplicate or unrecognized explicit inputs. The complete inventory requirement remains unchanged.

Add a finite native override to the reviewed vendor inventory, selected only for admitted enhanced native metadata and still checked against exact repository/revision pins. Record the actual current NIO, Crypto and fork NIOSSL provenance, including NIOSSL's BoringSSL revision and exact upstream notice. Default profile provenance and distribution/closure flags remain unchanged. All variant notice inputs are declared; only selected provenance is emitted.

## Validation

All 23 offline package tests pass. New cases reproduce missing nested aspect inputs, restore exact deterministic output through explicit inputs, reject duplicates/unknown paths/conflicting or empty texts, and validate current native vendor provenance while rejecting default/stale pins and stock selection. An offline replay of the actual retained failed manifest first reproduces the missing-notice error, then assembles 122 notice texts with all five nested requirements, both required root NOTICE texts and current native vendor/source provenance. All existing archive metadata/notice assertions also pass against real-input offline metadata; archive layout and CLI execution remain pending. This is not execution of the Bazel package action or package smoke test.

Root owns the fresh immutable native packaging checkpoint. No heavy build, runtime, benchmark or baseline rerun is performed here. See [ISSUE-native-package-nested-notices.md](ISSUE-native-package-nested-notices.md).
