# Feature or Enhancement Request Details

`container-compose` exposed `pause` and `unpause` command names, but they returned unsupported-feature errors because released upstream `apple/container` did not expose Docker-compatible pause/unpause lifecycle primitives.

The local integration stack now has the required runtime path:

- [`stephenlclarke/containerization`](https://github.com/stephenlclarke/containerization) branch `integration/blkio-runtime` exposes `LinuxContainer.pause()` and `LinuxContainer.resume()`.
- [`stephenlclarke/container`](https://github.com/stephenlclarke/container) branch `logs-integration-chris` exposes `ContainerClient.pause(id:)`, `ContainerClient.unpause(id:)`, `container pause`, and `container unpause`.

Expected Compose behavior:

```bash
container compose pause [SERVICE...]
container compose unpause [SERVICE...]
```

The implementation should:

- Resolve Compose service names, replicas, and custom `container_name` values through the existing service-target logic.
- Use direct `ContainerClient` lifecycle APIs through `ContainerClientLifecycleManager`.
- Preserve dry-run output as equivalent `container pause` and `container unpause` commands.
- Keep Compose service selection in `container-compose`; do not move Compose-specific behavior into `apple/container`.
- Keep compatibility docs explicit that this support is fork-backed until the corresponding `apple/container` and `apple/containerization` surfaces are accepted upstream.

References:

- Docker Compose pause: <https://docs.docker.com/reference/cli/docker/compose/pause/>
- Docker Compose unpause: <https://docs.docker.com/reference/cli/docker/compose/unpause/>
- Docker container pause: <https://docs.docker.com/reference/cli/docker/container/pause/>
- Docker container unpause: <https://docs.docker.com/reference/cli/docker/container/unpause/>

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
