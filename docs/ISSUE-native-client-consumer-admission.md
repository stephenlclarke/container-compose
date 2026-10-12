# Admit the coherent Container-native client graph in Compose

## Contract and scope

Status: Implemented locally; actual matched consumer verification is pending. No upstream issue is claimed. This supports the active SDK → Container → Compose contract; historical published binaries and the frozen 26-workload timing matrix are reused without rerunning their baselines. The Docker oracle and public Compose/runtime behavior are unchanged.

## Reproduction and expected result

Compose's legacy enhanced importer requires its own old recipe/profile and Container `641b7019`/SDK `6db16197` pins. A Container-native client archive cannot satisfy that identity by relabeling it. The native generated package also needs a binary executable import macro absent from Compose.

The native adapter is an explicit Bazel consumer path for the existing enhanced direct-API backend. It does not introduce a runtime profile or relabel native archives. Default stock/enhanced source and legacy prebuilt selectors retain their existing pins and checks.

The reviewed Container verifier source is pinned to `fc5d94aeeaae2ce373480a65b7a7ae11c2897315`. Every tracked byte must match that clean commit before its validators are imported. Its four published lowers are admitted through the maintained native verifier, including finite recipe compatibility, toolchain, immutable source and portable source/build/test proof. The export-only Container client separately requires its exact own-source commit, exact producer recipe/toolchain, all four lower identities, client/XPC source qualification and matching compiled modules. Its original portable proof is replayed before any override is exposed. Cache reuse rehashes the complete inventory, permissions and ownership; links and extra files fail closed. Admission is repeated after the consumer invocation.

Compose independently requires the existing enhanced release configuration, the same minimum OS/Bazel and actual compiler/SDK toolchain. Conflicting compile flags and legacy binary selectors are rejected. The generated Bazel-only source vector replaces every shared native pin (18 revisions at the current checkpoint), adds native transitive packages and binds Container's own producer commit. It does not pretend to be a SwiftPM resolver output or mutate either maintained resolved file. The native SDK already owns the unaligned EXT4 correction: the old Compose patch is omitted only when this admitted native vector is selected. Generated minimum-OS wrapper/dependency edges remain intact; the executable import macro provides binary-only tools with no source fallback.

The selected-pins metadata repository makes candidate packaging embed the actual source vector. The admission receipt preserves `graph: container-native`, `consumerProfile: enhanced` and `compiledConsumerVerified: false`. Admission alone is not a compiled consumer or runtime compatibility proof.

## Completion and blocker criteria

Root must publish the matched SDK/client archive, evidence and portable proof triples and provide their authentic locks, then advance the reviewed verifier source pin coherently if the SDK source advances. No placeholder lock or fabricated artifact is added. A fresh immutable Compose checkpoint must pass its actual configured import-only action inventory, focused client/runtime tests and matched isolated runtime proof before support can be called Verified. Any source/lower/recipe/toolchain/configuration or proof mismatch blocks admission. Legacy recipe hashes change where maintained adapter integration changes recipe inputs; no legacy artifact compatibility waiver is introduced.

## Focused proof

Offline regressions exercise changed own-source/lower/recipe/profile/toolchain identities, malformed source pins, configuration/path overrides, missing client/XPC inventory, portable-proof failure before cache exposure, and tampered cache bytes/modes/links. Existing foundation regressions remain required. No Swift/Bazel build, runtime operation, release or baseline benchmark was executed by this implementation worker.

The current native-v3 producer loaded 37 lower package repositories, including Yams, SwiftTOML, zstd and the matching NIOSSL. Its authenticated `expectedUnimportedPins` contains two non-documentation HTTP metadata packages. That declared absence is preserved; actual Compose action proof must demonstrate those repositories remain unreached and that no lower Swift/C implementation is source-compiled, including cache-hit actions. Unknown missing packages are rejected. Legitimate source/recipe-bound cached test results retain the pinned Container verifier's semantics; fabricated cache/skipped proof is rejected by portable replay.

Final focused offline validation passes 29 cases: 15 adapter tests and 14 existing foundation tests. The verifier import uses a fresh private Python bytecode-cache prefix, restored in `finally`, so ignored cached bytecode cannot substitute for the authenticated source. Instrumented adapter coverage and its unexecuted native paths are retained externally; this evidence does not replace actual consumer qualification.
