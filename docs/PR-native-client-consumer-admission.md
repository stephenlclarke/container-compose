# Explicitly consume the unchanged Container-native client graph

## Change and rationale

The native adapter is an explicit Bazel consumer path for the existing enhanced direct-API backend. It does not introduce a runtime profile or relabel native archives. Default stock/enhanced source and legacy prebuilt selectors retain their existing pins and checks.

The reviewed Container verifier source is pinned to `fc5d94aeeaae2ce373480a65b7a7ae11c2897315`. Every tracked byte must match that clean commit before its validators are imported. Its four published lowers are admitted through the maintained native verifier, including finite recipe compatibility, toolchain, immutable source and portable source/build/test proof. The export-only Container client separately requires its exact own-source commit, exact producer recipe/toolchain, all four lower identities, client/XPC source qualification and matching compiled modules. Its original portable proof is replayed before any override is exposed. Cache reuse rehashes the complete inventory, permissions and ownership; links and extra files fail closed. Admission is repeated after the consumer invocation.

Compose independently requires the existing enhanced release configuration, the same minimum OS/Bazel and actual compiler/SDK toolchain. Conflicting compile flags and legacy binary selectors are rejected. The generated Bazel-only source vector replaces every shared native pin (18 revisions at the current checkpoint), adds native transitive packages and binds Container's own producer commit. It does not pretend to be a SwiftPM resolver output or mutate either maintained resolved file. The native SDK already owns the unaligned EXT4 correction: the old Compose patch is omitted only when this admitted native vector is selected. Generated minimum-OS wrapper/dependency edges remain intact; the executable import macro provides binary-only tools with no source fallback.

The selected-pins metadata repository makes candidate packaging embed the actual source vector. The admission receipt preserves `graph: container-native`, `consumerProfile: enhanced` and `compiledConsumerVerified: false`. Admission alone is not a compiled consumer or runtime compatibility proof.

## Supported opt-in

From a clean reviewed Compose checkout, after root supplies the actual published five-layer lock directory and exact reviewed Container verifier checkout:

```sh
Tools/bazel/run.sh build //:compose --config=enhanced --config=release --native-container-source=/ABS/REVIEWED/CONTAINER --native-layer-locks=/ABS/PUBLISHED/NATIVE/LOCKS
```

Both paths must be explicit, absolute and unique. Ambient runtime selectors cannot activate this path. The launcher records native admission alongside the invocation evidence. `candidate_archive` selects the same generated pin vector; no new third runtime or SwiftPM manifest resolution is claimed.

## Validation and remaining limits

```sh
PYTHONPATH=Tools/bazel/artifacts python3 -m unittest Tools.bazel.artifacts.test_native_consumer Tools.bazel.artifacts.test_foundation
```

The offline adapter/foundation tests pass. The client artifact is published as immutable [release 410244273](https://github.com/stephenlclarke/container/releases/tag/layer-container-sdk-native-fc5d94aeeaae-97f40b0467271c5d00c9), targeting the reviewed Container commit. Its archive, evidence and portable proof are download-verified; the explicit five-layer locks remain programme-owned. The portable proof integration test uses a synthetic product and injected verifier to demonstrate ordering and fail-closed propagation; it does not qualify a native client archive. Actual native import-only aquery, compilation, focused Swift tests, matched runtime proof and final source/recipe readmission remain pending. The current Container verifier pin must advance explicitly with the next coherent SDK/client checkpoint. No historical baseline rebuild or benchmark is requested.

The current native-v3 producer loaded 37 lower package repositories, including Yams, SwiftTOML, zstd and the matching NIOSSL. Its authenticated `expectedUnimportedPins` contains two non-documentation HTTP metadata packages. That declared absence is preserved; actual Compose action proof must demonstrate those repositories remain unreached and that no lower Swift/C implementation is source-compiled, including cache-hit actions. Unknown missing packages are rejected. Legitimate source/recipe-bound cached test results retain the pinned Container verifier's semantics; fabricated cache/skipped proof is rejected by portable replay.

Final focused offline validation passes 29 cases: 15 adapter tests and 14 existing foundation tests. The verifier import uses a fresh private Python bytecode-cache prefix, restored in `finally`, so ignored cached bytecode cannot substitute for the authenticated source. Instrumented adapter coverage and its unexecuted native paths are retained externally; this evidence does not replace actual consumer qualification.

Native-only launch requires Python >= 3.10 because the pinned portable-proof verifier uses `zip(strict=True)`. The shell selects Homebrew Python only for explicit native admission options; ordinary stock/enhanced commands retain system Python. The adapter checks the actual published `.rspm` client/XPC labels, required targets and positive unskipped report/XML-hash bindings before replaying the original proof. Release aquery/cquery now receive the same internally generated commit/lane/dirty defines as build/test/coverage; caller overrides remain forbidden. The two actual pre-analysis failures remain retained, and no native test rerun is requested. The focused correction passes 33 offline checks; actual consumer analysis and compilation are still pending.
