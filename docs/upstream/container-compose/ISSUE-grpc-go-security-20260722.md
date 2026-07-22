# Upgrade gRPC-Go to resolve the Dependabot security alert

<!-- markdownlint-disable MD013 -->

## Problem

Dependabot identified the high-severity advisory
[GHSA-hrxh-6v49-42gf](https://github.com/advisories/GHSA-hrxh-6v49-42gf)
against `google.golang.org/grpc` `v1.81.1` in
`Tools/compose-normalizer/go.mod` (repository alert
[#24](https://github.com/stephenlclarke/container-compose/security/dependabot/24)). The normalizer includes gRPC through its Compose-spec dependency graph, so leaving the indirect version pinned would retain the affected code in the supported toolchain.

## Required behavior

- Upgrade the indirect gRPC-Go dependency to the first version supplied by the Dependabot remediation, `v1.82.1`.
- Preserve the checked-in module graph's reproducibility by updating only its two matching `go.sum` entries.
- Confirm that normalizer tests, the complete Swift test suite, and live Docker Compose v2 parity retain their existing behavior on macOS.

## Scope and ownership

This is a narrowly scoped dependency-security update in the Compose normalizer. It changes no Compose command semantics, Apple Container primitive, Containerization behavior, or Windows-specific code.

## Commit tracking

- Dependabot alert: [#24](https://github.com/stephenlclarke/container-compose/security/dependabot/24) (`GHSA-hrxh-6v49-42gf`).
- Dependabot proposal: [#135](https://github.com/stephenlclarke/container-compose/pull/135) (`google.golang.org/grpc` `v1.81.1` to `v1.82.1`).
- Signed Compose-layer implementation:
  `62ebc4049ef031bf3e33a7cc92c792c4a352054e`
  (`chore(go): update grpc security patch`).

## Validation

```sh
cd Tools/compose-normalizer
go mod verify
go test ./... -cover

cd ../..
make test
make docker-compose-parity
```

`go mod verify` completed without module drift. The normalizer's covered Go packages passed, including `89.9%` coverage for its root package. `make test` passed 1,113 Swift tests in 26 suites. The full live macOS parity matrix passed against Docker Compose v2 `5.3.1` with `COMPOSE_PARITY_EXIT=0`.
