# Pull request: require complete static quality snapshots

## Summary

Make static quality evidence an all-or-nothing release invariant. Current and stable notes now require all eleven SonarQube metrics plus the three CodeQL metrics, rendered as fourteen verified static badges and retained as a self-contained SVG asset. The controller looks across successful exact-commit `main` CI runs, including an explicit full-validation dispatch, instead of treating a racing docs-only trigger as the only available evidence source.

## Constructible commit

- `d18d1f607792340fdd67a92182c191d1f614d23e` `fix(release): require complete quality snapshots`

## Implementation

- `.github/workflows/prebuilt-binaries.yml` accepts successful `push` and full-validation `workflow_dispatch` CI completions, recognises the active `Validate` or `Validate Runtime` lane, and searches successful exact-main CI runs for a passed `SonarQube scan` step.
- The branch package path skips when no exact passed scan exists, and manual Current dispatch fails explicitly in the same situation. This preserves the last verified `current` release instead of publishing a partial note.
- `Tools/release/capture-quality-snapshot.py` no longer exposes the CodeQL-only snapshot mode. SonarQube and CodeQL analysis for the exact promoted commit are both mandatory, and a failed evidence lookup stops publication.
- `Tools/release/test_capture_quality_snapshot.py` and `Tools/release/test_container_stack_release.py` cover the strict policy, exact CI scan lookup, manual full-CI acceptance, and removal of every partial-snapshot fallback.

## Verification

```sh
python3 -m py_compile Tools/release/capture-quality-snapshot.py Tools/release/test_capture_quality_snapshot.py Tools/release/test_container_stack_release.py
python3 -m unittest discover -s Tools/release -p 'test_*.py'
ruby -ryaml -e 'workflow = YAML.unsafe_load_file(".github/workflows/prebuilt-binaries.yml"); print workflow.fetch("jobs").fetch("resolve-publish-context").fetch("steps").first.fetch("run")' | bash -n
git diff --check
```

Hosted confirmation after merge:

1. Run a full CI validation on `main` for the promoted commit and require its SonarCloud quality gate to pass.
2. Let the matching Current package complete, then confirm its release body contains fourteen `img.shields.io/static/v1` badges and no omission text.
3. Confirm `quality-snapshot-current.svg` describes all fourteen badges, every GitHub-proxied image is valid SVG, and the same behavior applies to the next semantic release.

## Compatibility and risk

The only behavior change is intentionally strict: a Current publication may wait for or require an explicit full CI run after a docs-only push. It will never use metrics from a different source commit or fabricate a SonarQube state. No Apple-facing PR is needed because the change is fully contained in the Compose release layer.
