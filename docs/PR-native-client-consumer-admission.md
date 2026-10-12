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

Actual configured analysis at `3809c385` completed successfully, then exposed an evidence-retention boundary error: launcher-owned admission JSON was inherited into Bazel and rejected by the environment validator. The launcher now keeps this record in its invocation evidence and post-run admission check while removing it from the child environment. Content-addressed retention includes `native-admission.json`; the environment allowlist is unchanged. A focused regression verifies child isolation, post-run verification and the retained JSON blob. The original failed invocation remains preserved; this correction alone is not a compiled-consumer claim.

The actual release-mode import graph and Compose executable now pass at `49e80ae625ba023ddfcfddf31848eec1d44e6a00`, with all five unchanged published native layers and no lower implementation compilation. Both no-runtime CLI gates executed fresh and passed. The first complete enhanced component run passed ten targets but failed to compile `ComposeContainerRuntimeTests`: its duplicated SDK branch-simulation fixture used `@testable` against the production EXT4 module. Compose now imports that module normally and retains all eight public-API alignment offsets for 16-, 32- and 64-bit values. Both byte-order paths remain tested in the SDK's own authenticated 24-case alignment suite; they are not a consumer API and do not require rebuilding a lower layer with testing internals. The original failed run is retained. The affected consumer target requires fresh qualification; matched runtime and comparative performance remain open.

## Native build-info binding correction

The first strict live leaf with the already compiled native product failed after 31 seconds: raw `ComposeBuildInfo.load` fell back to the source-tree `Package.resolved` (`641b7019`/`6db16197`) although the authenticated compiled graph used Container `fc5d94ae` and SDK `518f92a0`. The strict compatibility rejection is correct and remains unchanged. Original failed evidence is retained; no successful live qualification is claimed.

Bazel candidate packaging already reads the declared `@compose_selected_pins//:Package.resolved` selected by native admission. The launcher now replays admission before the invocation and supplies a reserved, internally generated binding containing admission/resolved SHA256 and the two exact runtime refs. The package action validates this binding against its selected lock and records it in candidate provenance; build-info, notice selection and lock identity continue to use that same declared input. Caller defines, environment injection and default stock/enhanced pins remain unchanged. Legacy Makefile release metadata is not a native-admission path.

`Tools/bazel/native_build_info.py` reuses the package build-info generator for retained raw products. It requires a pinned successful compiled acceptance receipt, exact executable bytes, hash-bound original invocation source/admission/outcome evidence, unchanged clean application/metadata source inputs and fresh replay of the five-layer admission. It preserves the executable's original compiled commit when the current clean source differs only outside those inputs, and writes a separate nonqualifying proof. This does not claim that metadata generation compiled or runtime-qualified any new source. The generated file is selected through the existing `CONTAINER_COMPOSE_BUILD_INFO` mechanism.

Focused offline regressions cover legacy-ref rejection, exact selected refs and lock/admission binding, forbidden caller controls, raw executable/receipt/evidence/source mismatch, incoherent or changed lower admission, and fresh output/proof handling. Package-action execution and the corrected strict live leaves remain root-owned follow-up gates.
