# Runtime Architecture

`ComposeCore` keeps Compose behavior independent of a particular runtime
implementation. Its layer order is:

1. `ComposePlugin` accepts the `container compose` command.
2. The Compose bridge calls the Go `compose-normalizer`, which uses
   `compose-go` to produce canonical project JSON.
3. `ComposeCore` builds `ComposeProject` values and applies service selection,
   planning, reconciliation, compatibility policy, and output formatting.
4. `ComposeRuntimeSPI` defines runtime-neutral requests, summaries, and
   provider contracts.
5. `ComposeContainerRuntime` wires those contracts to the current typed
   `ContainerClient`, explicit CLI-backed providers, and Compose-owned local
   external config/secret readers.
6. The matched `container`, `containerization`, and builder-shim stack performs
   the platform-specific work.

The orchestrator imports only `ComposeRuntimeSPI` contracts. The executable
installs `ComposeContainerRuntime` at its composition boundary, which permits a
focused compatibility decorator or a different runtime implementation without
leaking its package types into Compose policy. Library users must likewise
supply a runtime provider; unconfigured defaults report an explicit
unsupported-runtime error instead of constructing an Apple client.

The repository's [full design document](https://github.com/stephenlclarke/container-compose/blob/main/DESIGN.md) contains the ownership rules and layer diagram.
