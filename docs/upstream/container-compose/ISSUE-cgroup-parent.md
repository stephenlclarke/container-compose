# Compose compatibility gap: guest cgroup parent

## Compose surface

`services.<name>.cgroup_parent` places a service container beneath a named
Linux cgroup hierarchy.

## Docker Compose V2 behavior

Docker Compose V2 accepts `cgroup_parent` and preserves it in normalized
configuration. The Engine applies the setting to its Linux cgroup hierarchy.

References:

- <https://compose-spec.github.io/compose-spec/05-services.html#cgroup_parent>
- <https://docs.docker.com/reference/compose-file/services/#cgroup_parent>

## Implemented behavior

`container-compose` accepts a non-empty relative `cgroup_parent` with no
empty, `.` or `..` path components. It carries the validated value in the typed
service-create plan and emits the generic `container run --cgroup-parent PATH`
option for `up`, `create`, and one-off `run` containers.

The generic runtime owns the sandbox VM's `/container` cgroup v2 root and
creates the service container as a leaf below the selected parent. For example,
`workloads/build` becomes `/container/workloads/build/<container-id>` in the
Linux guest.

## Boundaries

- This is a Linux-guest facility only; it never chooses or exposes a macOS-host
  cgroup.
- The runtime owns creation and cleanup below `/container`; it does not expose
  an operator-managed named cgroup lifecycle or controller interface.
- Compose deliberately rejects absolute and traversal-bearing paths before any
  container side effects. That is a local runtime safety boundary, not an
  attempt to manage arbitrary host cgroups as Docker Engine can.

## Ownership

The supporting generic runtime work is recorded in
`docs/upstream/apple-containerization/` and `docs/upstream/apple-container/`.
Neither fork contains Compose-specific policy or terminology. The Compose
adapter owns Compose syntax, validation, and command projection.
