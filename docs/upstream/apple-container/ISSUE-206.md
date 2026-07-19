# Support Privileged Run and Create Processes

## Feature or Enhancement Request Details

`container run --privileged` is tracked upstream as [apple/container#206](https://github.com/apple/container/issues/206). Higher-level Compose support also needs the same primitive for service containers created from `services.<name>.privileged: true`.

The local `stephenlclarke/container` fork already carries the Apple-shaped process boundary from the privileged exec slice: `ProcessConfiguration.privileged` is a typed boolean that defaults to `false` and the Linux runtime maps it to the existing all-capabilities set. This follow-up exposes that same process intent through the init-process paths used by `container run` and `container create`, then restores the standard Linux guest paths that Containerization masks or mounts read-only by default.

The requested shape is intentionally narrow:

- Expose `--privileged` through the shared process option group.
- Pass the flag into `ProcessConfiguration` for `container run` and `container create`.
- Keep `container exec --privileged` using the same shared process flag rather than a duplicate exec-only flag.
- Pass the field through `container machine run` too, because it uses the same shared process option group.
- For a privileged init process only, clear the generic Containerization `maskedPaths` and `readonlyPaths` defaults while preserving the VM sandbox boundary.
- Keep host-device, device-cgroup, seccomp, AppArmor, and other Docker privileged-mode isolation changes out of this slice unless the runtime adds those primitives explicitly.

This is needed by `stephenlclarke/container-compose` so service-level `privileged: true` can map to a real runtime flag instead of being rejected before service container creation.

References:

- Apple issue: <https://github.com/apple/container/issues/206>
- Docker Compose service `privileged`: <https://docs.docker.com/reference/compose-file/services/#privileged>
- Docker run `--privileged`: <https://docs.docker.com/reference/cli/docker/container/run/#privileged>

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
