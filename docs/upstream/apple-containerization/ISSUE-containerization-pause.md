# Feature or Enhancement Request Details

`LinuxContainer` already carries an internal paused state and `VirtualMachineInstance` already exposes `pause()` and `resume()` hooks, but there is no public `LinuxContainer` API that transitions a running container into that state or back out of it.

That leaves higher-level clients such as `apple/container` unable to implement native pause and unpause lifecycle behavior without reaching through the runtime boundary or duplicating state handling outside `containerization`.

The requested enhancement is to expose small, state-checked lifecycle methods on `LinuxContainer`:

- `pause()` should require a running container, call the VM pause hook, and transition the container to its existing paused state.
- `resume()` should require a paused container, call the VM resume hook, and transition the container back to the started state.
- Failed VM operations should leave the existing container state unchanged because the state transition is only committed after the lower-level operation succeeds.

This enables downstream `apple/container` work to expose pause/unpause through the API service, client, and CLI, and lets `container-compose` map Compose `pause`/`unpause` semantics onto the native lifecycle primitive.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
