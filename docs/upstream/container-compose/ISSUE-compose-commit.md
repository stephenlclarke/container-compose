# Support `compose commit` for service containers

## Summary

`container compose commit [OPTIONS] SERVICE [REPOSITORY[:TAG]]` should create an image from a selected Compose service container. The Compose-owned path supports stopped service containers with the current Apple-backed runtime, and it should fail clearly for running containers until Apple exposes live export/commit support above the merged lower-runtime freeze/thaw primitive.

Docker Compose behavior:

- Requires one service name and accepts an optional image reference.
- Selects a service replica with `--index`; Docker Compose uses `0` as the default unset value.
- Sends `--author`, repeated `--change`, `--message`, and `--pause` into Docker Engine `ContainerCommit`.
- Uses `--pause=true` by default and maps `--pause=false` to Docker Engine `NoPause`.
- Requires a running service container.

Current Apple upstream context:

- [apple/container#1399](https://github.com/apple/container/issues/1399) tracks a `container commit` command and has active upstream interest.
- [apple/container#1400](https://github.com/apple/container/issues/1400) tracks live container filesystem export/commit and calls out the need for snapshot or freeze support.
- [apple/container#1630](https://github.com/apple/container/pull/1630) adds the active Apple live-export implementation.
- [apple/container#1762](https://github.com/apple/container/pull/1762) adds the draft Apple `container commit` command on top of live export.
- [apple/container#1262](https://github.com/apple/container/pull/1262) was closed with guidance to reuse export/load behavior and avoid a broad Docker-shaped commit endpoint.
- [apple/containerization#685](https://github.com/apple/containerization/pull/685) completed the lower-runtime freeze/thaw filesystem operation API that live export/commit builds on.

## Acceptance Criteria

- `container compose help commit` reports the command as partial, marks `--pause` as partial because it only applies to unavailable running-container commit, and marks the remaining documented options as supported.
- `commit --author`, repeated `--change`, `--index`, `--message`, and `--pause` parse in Docker Compose-compatible forms, including omitted `--index`, `--index=0`, `-a`, `-c`, `-m`, and `-p=false` through the Compose argument rewriter.
- A stopped service container is exported with the existing runtime export adapter, wrapped as a single-layer OCI image archive, and loaded through the image adapter.
- The generated OCI config carries Compose service image metadata plus Docker-compatible `--change` instructions for `CMD`, `ENTRYPOINT`, `ENV`, `EXPOSE`, `LABEL`, `ONBUILD`, `USER`, `VOLUME`, and `WORKDIR`.
- Running containers, including `--pause=false`, fail before export or image load with an error that references the Apple live export/commit blockers.
- The Compose layer owns service selection, Docker Compose option parsing, dry-run text, and Docker-shaped image config changes.
- No Apple-backed repository change is required for the current Compose-owned service commit behavior.

## Non-Goals

- Do not add a Docker-shaped commit endpoint to `apple/container`.
- Do not attempt paused live/running container commit until Apple accepts live export/commit support in `apple/container`.
- Do not move Compose service selection or Docker Compose parser behavior into Apple-backed repositories.

## Validation

Focused validation:

```sh
swift test --filter ComposeOrchestratorTests/commit
swift test --filter ComposeArgumentRewriterTests
swift test --filter ComposeCLIHelpTests
```

Broader validation before release:

```sh
make ci
make docker-compose-parity
git diff --check
```

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
