# Feature or Enhancement Request Details

`apple/container` does not currently expose pause/unpause lifecycle controls. That blocks higher-level Compose support because Docker Compose v2 has `pause` and `unpause` commands that operate on service containers.

The lower-level `containerization` runtime already has VM pause/resume hooks, and the local `stephenlclarke/containerization` fork now exposes those hooks through `LinuxContainer.pause()` and `LinuxContainer.resume()`.

Expected native lifecycle shape:

```bash
container pause CONTAINER [CONTAINER...]
container pause --all
container unpause CONTAINER [CONTAINER...]
container unpause --all
```

The first useful implementation should be intentionally narrow:

- Add a `paused` runtime/container status.
- Add runtime XPC routes for pause/resume.
- Add API-server routes and `ContainerClient` methods for pause/unpause.
- Add `container pause` and `container unpause` commands.
- Keep paused containers visible in list/inspect.
- Reject stopping or starting a paused container with a clear message to unpause first.
- Keep Compose-specific service selection out of `apple/container`; `container-compose` can map service names onto these primitives.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), this Apple-facing slice fits the core resource-management boundary: pause and unpause are native lifecycle operations. Compose owns service selection and Docker Compose command semantics.

This is needed by `stephenlclarke/container-compose` so Compose `pause` and `unpause` can stop being treated as an `apple/container` runtime gap.

References:

- Docker container pause: <https://docs.docker.com/reference/cli/docker/container/pause/>
- Docker container unpause: <https://docs.docker.com/reference/cli/docker/container/unpause/>
- Docker Compose pause: <https://docs.docker.com/reference/cli/docker/compose/pause/>
- Docker Compose unpause: <https://docs.docker.com/reference/cli/docker/compose/unpause/>

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
