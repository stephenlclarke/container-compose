# Pull request: preserve retained stable SonarQube evidence

## Summary

Allow an immutable stable release to publish after SonarCloud has expired the
promoted commit's per-metric history, but only when GitHub still proves both the
exact successful SonarCloud check and the exact successful `main` CI scan.
Current builds remain strict, later metrics are never substituted, and every
missing or mismatched authority remains fail-closed.

## Constructible commit

- `154e70b80d52bb3bdf471afb40fbb3a92636b15a`
  `fix(release): preserve retained Sonar evidence`

The commit is signed and contains the implementation, workflow wiring, tests,
and operator documentation.

## Implementation

- `Tools/release/capture-quality-snapshot.py`
  - adds a stable-only `--allow-expired-sonarqube-metrics` policy;
  - validates the exact successful `SonarCloud Code Analysis` check, its
    `sonarqubecloud` app identity, the successful exact-commit `main` CI run,
    the successful `Validate Runtime` job, and its successful
    `SonarQube scan` step;
  - keeps exact CodeQL result and rule counts;
  - emits explicit `SonarQube Quality Gate: Passed` and
    `SonarQube Metrics: Expired` badges plus links and a no-substitution
    statement;
  - distinguishes absent metric history from request or schema failures so
    transient service errors remain fatal.
- `.github/workflows/prebuilt-binaries.yml` enables the retention policy only
  for semantic stable tags. Mutable Current publication retains the complete
  metric requirement.
- `Tools/release/test_capture_quality_snapshot.py` covers exact authority
  selection, cross-commit rejection, stable rendering, CLI policy isolation,
  workflow wiring, static SVG generation, and the original strict path.
- `BUILD.md` documents the normal fourteen-metric snapshot and the precise
  stable-only retention behavior.

## Verification

```sh
python3 -m py_compile \
  Tools/release/capture-quality-snapshot.py \
  Tools/release/test_capture_quality_snapshot.py \
  Tools/release/test_container_stack_release.py \
  Tools/release/test_release_notes.py
python3 -m unittest discover -s Tools/release -p 'test_*.py'
make check
git diff --check
```

Live exact-commit validation:

```sh
python3 Tools/release/capture-quality-snapshot.py \
  --repo stephenlclarke/container-compose \
  --commit 42b737dcda830f79b3f0993212e97fefe179f427 \
  --release-kind stable \
  --allow-expired-sonarqube-metrics \
  --badge-snapshot-id local-retention-validation-42b737dc \
  --verify-static-badges \
  --svg-output /tmp/quality-snapshot.svg \
  --asset-url https://github.com/stephenlclarke/container-compose/releases/download/0.10.0/quality-snapshot-0.10.0.svg
```

Observed locally:

- 160 release-tool tests passed.
- All coverage, release, CI-helper, consistency, and secret checks in
  `make check` passed.
- The live command resolved CI run `30089845474`, CI job `89470421550`, the
  exact SonarCloud check, and exact CodeQL analysis.
- GitHub rendered and delivered all five fallback badges as valid SVG.
- The generated `quality-snapshot.svg` is self-contained.

Hosted confirmation after merge:

1. Require source checks and CodeQL on the pull request.
2. Rerun the `0.10.0` stable package workflow.
3. Confirm the immutable release contains both matched archives, checksums,
   attestations, release highlights, and `quality-snapshot-0.10.0.svg`.
4. Confirm the release note links the exact SonarCloud check and CI job and
   contains no metrics from a different commit.
5. Confirm the stable Compose and runtime Homebrew formula pair is updated
   atomically and installs successfully.

## Compatibility and risk

The change is limited to release-note evidence capture in the Compose layer.
It does not weaken the Current lane or accept another commit's metrics. The
stable fallback can still refuse publication if either GitHub or SonarCloud
authority is absent, which is the intended fail-closed behavior. No Apple-facing
runtime PR is required.

## Review checklist

- [ ] Exact commit checks, CI run, job, and scan step are all required.
- [ ] SonarQube metric API request failures remain fatal.
- [ ] Current builds cannot enable expired-metric evidence.
- [ ] CodeQL result and rule counts remain exact and complete.
- [ ] Static badge delivery and self-contained SVG validation remain mandatory.
- [ ] Stable `0.10.0` publication and atomic Homebrew promotion complete.
