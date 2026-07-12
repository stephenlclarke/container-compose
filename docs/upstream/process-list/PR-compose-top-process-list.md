# Pull request: support Docker-shaped `container compose top`

<!-- markdownlint-disable MD013 -->

## Summary

- Render Docker Compose-style process tables for selected service containers.
- Use the direct `ContainerClient.processes(id:)` API instead of shelling out through the CLI.
- Mark `container compose top` as supported now that the matched runtime stack exposes process metadata.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports `docker compose top [SERVICES...]`. The current `stephenlclarke` stack exposes generic process metadata through `containerization` and `apple/container`; `container-compose` owns the Compose service selection and Docker-shaped presentation layer.

References:

- Docker Compose `top`: <https://docs.docker.com/reference/cli/docker/compose/top/>
- Docker `container top`: <https://docs.docker.com/reference/cli/docker/container/top/>
- Container handoffs: [ISSUE-process-identifiers.md](../apple-container/ISSUE-process-identifiers.md) and [PR-process-identifiers.md](../apple-container/PR-process-identifiers.md)
- Lower-runtime handoffs: [ISSUE-process-identifiers.md](../apple-containerization/ISSUE-process-identifiers.md) and [PR-process-identifiers.md](../apple-containerization/PR-process-identifiers.md)
- Matched init-image handoff: [PR-containerization-branch-init.md](../apple-container/PR-containerization-branch-init.md)

## Commit Tracking

- Compose code:
  `feat(top): render Docker process tables` in the current `container-compose`
  release lane.
- Container code commit:
  `b8c45d53720a11a5247577e3975e0d3fc52e614d` in
  `stephenlclarke/container` (`feat(runtime): surface container process
  metadata`).
- Matched init-image automation commit:
  `b478439e81c3ceddd58ef4be65d4c948bc1fa4f1` in
  `stephenlclarke/container` (`fix(build): build source-checkout init images
  safely`) and `d82fc5c24d48fffe2f48c8144642ab6fcf5299e0` in
  `stephenlclarke/container` (`fix(build): clean copied init sources`), plus
  `d03f81b4968d9f33914db1d77e00ce9f43178d00` in
  `stephenlclarke/container` (`build(init): install matched vminit image
  refs`).
- Lower-runtime code commit:
  `58c7eb72e1a6c1b17d8754c3593ebd0ad141193a` in
  `stephenlclarke/containerization` (`feat(runtime): expose container process
  metadata`) and `8cbc60df9047f308ba774ba5e18c1fb2746c06ef` in
  `stephenlclarke/containerization` (`fix(runtime): qualify process error
  existential`), plus `d8b9585a9855b1c0958d423a2d08b564eb6f8626` in
  `stephenlclarke/containerization` (`build(init): parameterize vminit image
  reference`).

## Implementation Details

- `ContainerClientTopManager` preserves Compose service/container order while collecting process data from the direct API.
- When metadata is available, output is rendered as one Docker Compose-style section per selected container with UID, PID, PPID, CPU, STIME, TTY, TIME, and CMD columns.
- The live parity harness writes an isolated runtime config with a matched init image reference, builds and installs that same image from the selected `containerization` checkout, and exports `CONTAINER_COMPOSE_INIT_IMAGE` so service containers use the matching guest `vminitd`.
- The legacy PID list remains a compatibility fallback for older matched runtime lanes, but the current release lane reports `top` as fully supported.
- `STATUS.md`, command support metadata, help tests, and upstream handoff docs now list `top` as supported.

## Docker Compose Compatibility Notes

- The CLI shape matches Docker Compose `top [SERVICES...]`.
- Compose-specific service selection, replica filtering, and Docker-shaped output stay in `container-compose`.
- Apple-facing repositories expose generic process metadata only; they do not own Docker Compose output policy.
- The current upstream scan did not find an accepted Apple process-metadata API to reuse. [apple/container#1769](https://github.com/apple/container/pull/1769) remains relevant maintainer/status context but does not expose per-container process metadata.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter ComposeOrchestratorTests/topManagerRendersDockerProcessTableFromDirectAPI
swift test --filter ComposeOrchestratorTests/topManagerRendersProcessIdentifiersFromDirectAPI
swift test --filter ComposeOrchestratorTests/upPassesConfiguredInitImageToContainerCreate
swift test --filter ComposeCLIHelpTests
make check
make swift-runtime-test SWIFT_RUNTIME_TEST_FILTER=ComposeRuntimeSmokeTests/runtimePsAndTopInspectBuiltComposeService
```

Additional release validation:

```sh
make ci-fast
make docker-compose-cli-surface-parity
git diff --check
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
