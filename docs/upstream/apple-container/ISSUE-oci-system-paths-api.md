# Existing feature: expose OCI masked and read-only system paths

<!-- markdownlint-disable MD013 -->

Existing upstream issue: [apple/container#1995](https://github.com/apple/container/issues/1995).
Existing upstream pull request: [apple/container#1996](https://github.com/apple/container/pull/1996).

Do not open a duplicate issue. Apple merged the API as
[`72431b04584d`](https://github.com/apple/container/commit/72431b04584dbc772e0bac6e64a5a6f71a9d8250)
on 22 July 2026.

## Runtime requirement

Higher-level callers need a typed way to override the OCI `maskedPaths` and
`readonlyPaths` defaults selected by Containerization. The values are generic
OCI runtime configuration and belong in `ContainerConfiguration`; Compose owns
only the policy that maps supported `security_opt` and `privileged` forms onto
those fields.

The Apple API uses optional arrays so an omitted value keeps Containerization's
defaults, while an explicit empty array clears them. That distinction is
required for unconfined system paths and privileged containers.

## Consumed implementation and coverage

- Apple merge: `72431b04584dbc772e0bac6e64a5a6f71a9d8250`.
- Fork merge: `f7612ab5a4018086f8daee70d6d11f45cee286ed`.
- Fork regression tests: `bfe4d8306b927ae2594704d94701060a39b3dc6d`.
- Final refreshed fork tip: `271ba58e88844f3d3708d25eb584e6b4ae441ed5`.
- Compose dependency commit: `d2464978e156d4ab30db104f3e0abf878fb10a0b`.

## Acceptance criteria

- `ContainerConfiguration` round-trips explicit masked/read-only arrays and
  preserves `nil` as the default-selection signal.
- `RuntimeService` forwards explicit arrays to `LinuxContainer.Configuration`.
- Omitted arrays retain Containerization's default masked/read-only paths.
- Existing fork fields, including the stop-timeout extension, survive the
  upstream merge without changing Apple API semantics.
- Live Compose tests cover privileged restoration and unconfined system paths
  through the macOS-hosted Linux runtime.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] This handoff references the merged issue and pull request instead of duplicating them.
