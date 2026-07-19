# Pull request: align Current quality snapshots with validated CI evidence

## Summary

Fixes the `current` release controller so it does not wait for a SonarQube
analysis that its own validated CI run did not create. Code-bearing CI remains
strict: a successful SonarQube scan still requires exact-commit SonarQube and
CodeQL evidence before publication.

## Constructible commit

- `31a9800bcb3de8bfa716188e4cd9383b35e1a22b`
  `fix(release): allow CodeQL-only snapshots when CI skips SonarQube`

## Implementation

- `.github/workflows/prebuilt-binaries.yml` reads the exact triggering run's
  `Validate Runtime` / `SonarQube scan` step conclusion and publishes that
  evidence policy to staging.
- `Tools/release/capture-quality-snapshot.py` adds a current-only,
  `--allow-missing-sonarqube` path. It still waits for exact CodeQL data and
  creates a clear three-badge CodeQL-only snapshot when no scan exists.
- `BUILD.md` documents the different evidence requirements precisely.
- Unit tests cover the CodeQL-only snapshot and its no-SonarQube polling path;
  release-policy tests ensure the workflow carries the explicit policy.

## Verification

```sh
python3 -m unittest discover -s Tools/release -p 'test_*.py'
make check
git diff --check
ruby -e 'require "yaml"; YAML.unsafe_load_file(".github/workflows/prebuilt-binaries.yml")'
```

All checks passed locally. The follow-up `current` release is additionally
validated by its public GitHub Actions workflow and by matching the mutable
`current` tag and release assets to the queued commit.

## Compatibility and risk

The optional path is limited to `current`; stable snapshots reject the flag.
It does not soften code-bearing CI: the workflow only uses it when the exact
validated run has no successful SonarQube scan. The release note says why the
SonarQube metrics are absent, avoiding a false quality claim.
