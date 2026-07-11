# Support `compose config` Image Digest Pinning

## Summary

This change completes the currently exposed `compose config` command surface:

- Stops rejecting `--resolve-image-digests` and `--lock-image-digests`.
- Marks `config` and both digest flags as supported in help.
- Adds an async config rendering path for digest resolution while preserving the existing synchronous config renderer for non-digest modes.
- Resolves remote manifest digests with `ContainerizationOCI.RegistryClient.resolve`, so no image content is pulled into the local store.
- Pins explicit service image references as `name:tag@sha256:...`.
- Renders `--lock-image-digests` as a deterministic override file containing pinned service images.

## Rationale

Digest pinning needs network I/O, but it does not need a container runtime primitive. Apple's public registry client already performs the OCI Distribution HEAD request used before image pulls, so Compose can satisfy the config flags without importing layers or changing `apple/container`.

Build-only services without `image:` are left unchanged because there is no remote tag to resolve. Images that are already digest-pinned are preserved as-is and do not trigger a registry lookup.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'configResolveImageDigestsPinsSelectedServiceImages|configResolveImageDigestsSkipsNonImageProjections|configLockImageDigestsRendersOverrideFile|imageManagerResolvesImageDigestsThroughDirectAPI|configCommandAndDigestOptionsAreShownAsSupported|configImageDigestFlagsParse'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeConfigResolvesImageDigests
npx --yes markdownlint-cli docs/upstream/container-compose/ISSUE-compose-config-image-digests.md docs/upstream/container-compose/PR-compose-config-image-digests.md
git diff --check
```

Before release promotion, run the broader local gate:

```sh
make coverage-check
make cli-smoke-built
```

## Compatibility Notes

- The digest resolver performs registry HEAD requests and therefore can fail for unavailable images or registries that require unavailable credentials.
- `config --lock-image-digests` always emits the lock override shape rather than the full canonical project.
- `build`, interactive `attach`, and exit-control `up` options remain separate partial-support items.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `2a34c9d5f711a203471a36c3380096da03965b0c`.
