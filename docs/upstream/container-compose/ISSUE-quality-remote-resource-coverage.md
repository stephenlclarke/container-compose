# Harden macOS remote-resource cache handling and coverage

## Context

Compose accepts Git and OCI remote project resources through the normalizer.
Those loaders are exercised before project orchestration, so their cache and
materialization paths must be deterministic on macOS and safe to validate
without a registry, a daemon, or a network fixture.

## Gap

An explicitly empty `XDG_CACHE_HOME` was treated as a configured cache root.
That produced the relative path `docker-compose` instead of falling back to
macOS's `~/Library/Caches/docker-compose`. The remote loaders also had most of
their checkout, resolver, cache, error-cleanup, and YAML transformation
branches untested, leaving the combined Go threshold below the requested 90%.

## Required behavior

- Treat an empty `XDG_CACHE_HOME` the same as an unset value and use the
  existing macOS cache fallback.
- Keep the production OCI resolver unchanged while exposing only a private,
  injectable factory for deterministic loader tests.
- Cover Git checkout/ref/error paths, OCI fetch/materialization cleanup, cache
  selection, transform errors, and publish helper edge cases without calling a
  real registry.
- Keep the quality gate at or above 90% for Swift and Go; Swift remains the
  priority metric for maintained runtime-facing code.

## Scope

This is Compose-owned normalizer hygiene. It does not add a Docker socket,
Windows behavior, Linux-only primitives, a registry implementation, or a
runtime API change. Existing Docker Compose V2 remote-resource parity remains
the integration oracle.
