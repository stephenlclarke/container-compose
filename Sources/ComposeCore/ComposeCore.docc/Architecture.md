# Runtime Architecture

`ComposeCore` keeps Compose behavior and runtime collaborators separated where
the current SPI permits, but it is not yet package-independent from the Apple
runtime. Its current layer order is:

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

The executable installs `ComposeContainerRuntime` at its composition boundary,
and library users must likewise supply runtime collaborators. Unconfigured
defaults report an explicit unsupported-runtime error instead of constructing
an Apple client.

That injection boundary is incomplete. `ComposeCore` directly depends on seven
products from `container` and `containerization`, 32 Core source files import
Apple modules, and public create-plan values expose Apple runtime types.
Alternate providers therefore still inherit the Apple build graph. `ARCH-101`
tracks removal of those package dependencies and imports; `ARCH-102` tracks
moving the remaining DTO, archive, and live API translation into
`ComposeContainerRuntime`.

Compose-specific resource policy stays in Core. For example, `memswap_limit`
is normalized and validated with `mem_limit` into a typed service-create plan;
the current CLI provider transports the resulting generic total
memory-plus-swap value to the matched runtime stack. The target architecture
keeps that policy while replacing every Apple-shaped Core value with a
Compose-owned SPI model.

The repository's [full design document](https://github.com/stephenlclarke/container-compose/blob/main/DESIGN.md) contains the ownership rules and layer diagram.
