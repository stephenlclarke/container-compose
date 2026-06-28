# Add Privileged Process Exec Support

## Feature or Enhancement Request Details

`apple/container` does not currently expose a way to request an elevated capability set for an additional process started inside an already-running container. That blocks higher-level orchestration from implementing `exec` surfaces that need a privileged process without recreating the container.

The first useful Apple-shaped slice is intentionally narrow:

- Add a typed `ProcessConfiguration.privileged` boolean that defaults to `false` when decoding older process configuration payloads.
- Map `container exec --privileged` to that process configuration field.
- Keep normal `exec` behavior unchanged when the field is absent or false.
- In the Linux runtime server, map privileged exec processes to the existing all-capabilities set.
- Keep Compose service fan-out and Docker Compose command semantics out of `apple/container`.

This is needed by `stephenlclarke/container-compose` so `container compose exec --privileged`, lifecycle hook `privileged: true`, and `develop.watch sync+exec` `privileged: true` can use a real runtime primitive instead of rejecting before exec starts.

References:

- Docker Compose exec reference: <https://docs.docker.com/reference/cli/docker/compose/exec/>
- Docker container exec reference: <https://docs.docker.com/reference/cli/docker/container/exec/>

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
