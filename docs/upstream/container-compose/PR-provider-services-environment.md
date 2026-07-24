# Pull Request

## Summary

- Add Docker Compose V2-compatible `rawsetenv` provider messages.
- Pass the normalized project environment to provider metadata and lifecycle
  commands.
- Warn when a raw provider variable replaces a dependent service variable.
- Add focused unit tests and Compose-file-backed live parity coverage.
- Resolve
  [`ISSUE-provider-services-environment.md`](ISSUE-provider-services-environment.md).

## Type of Change

- [x] Compose provider compatibility
- [x] Docker Compose V2 configuration and live parity coverage
- [ ] Apple Containerization API change
- [ ] Windows behavior

## Apple-Shaped Boundary

This change is intentionally confined to the Compose layer. Provider services
are an external Compose protocol: Apple Containerization and Container require
no Docker-shaped API, model, or lifecycle behavior to implement it. The patch
extends the existing provider abstraction instead of modifying either fork.

The provider result keeps prefixed and raw variables separate until dependency
injection. `setenv` remains service-name-prefixed; `rawsetenv` is injected
verbatim and produces the same visible override diagnostic as Docker Compose.
The existing command runner remains the only process boundary.

## Commit Tracking

The signed semantic commit is:

- `7e99acb1ca336c643d1ed2793592288f1fd556ae`
  `feat(provider): complete provider environment parity`

No Containerization, Container, or builder-shim commit is required.

## Code Map

- `Sources/ComposeCore/ComposeCommandOptions.swift`: models provider variables
  without exposing them as public runtime API.
- `Sources/ComposeCore/ComposeOrchestratorProviders.swift`: parses `rawsetenv`,
  injects raw and prefixed values, emits override diagnostics, and supplies the
  normalized project environment to both provider process forms.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift`: covers valid
  prefixed/raw injection, replacement diagnostics, project-environment
  propagation, and malformed raw messages.
- `Tools/parity/fixtures/provider-services/compose.yaml` and `provider.sh`:
  exercise the protocol through a real Compose project and external provider.
- `Tools/parity/check-compose-provider-services.sh`: compares the pinned Docker
  Compose V2 behavior and the matching macOS Apple-runtime behavior.
- `Makefile`: includes the provider check in the aggregate parity gate.

## Validation

```console
swift test --filter \
  'ComposeCoreTests.ComposeOrchestratorTests/(upRunsProviderServicesAndInjectsProviderEnvironmentIntoDependents|upRejectsMalformedProviderRawSetenv)'
make docker-compose-provider-services-parity
make check
make coverage-check
```

Current local results:

- Focused provider tests: passed, including both malformed-message cases.
- Full Swift suite: 1,119 tests passed.
- Swift coverage: 91.41% (minimum 90%).
- Go normalizer coverage: 90.06% (minimum 85%).
- Docker Compose V2 5.3.1 configuration/live provider fixture and the matching
  macOS Container/Containerization source runtime fixture: passed.
- ShellCheck, Markdown lint, SwiftFormat, strict SwiftLint, license, release-tool,
  and stack-consistency checks: passed.

## Compatibility and Risks

- Existing `setenv` variables retain their service-name prefix.
- Raw values only affect services that directly depend on the provider.
- An identical existing raw value is not reported as an override.
- Empty raw values are accepted; missing keys or separators fail before a
  dependent service is created.
- Provider subprocesses now receive Compose's resolved project environment,
  matching Docker Compose and allowing `.env`/environment-file values without
  leaking service-only environment values.
- Windows-only behavior is not added or tested.

## Checklist

- [x] Minimal Compose-owned implementation
- [x] Focused unit coverage
- [x] Docker Compose YAML fixture
- [x] Docker Compose V2 5.3.1 parity passed
- [x] Matching macOS runtime parity passed
- [x] Swift coverage threshold passed
- [ ] SonarQube quality gate passed
- [ ] Signed commit and prerelease published
