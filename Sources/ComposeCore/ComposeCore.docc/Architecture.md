# Runtime Architecture

`ComposeCore` keeps Compose behaviour and runtime collaborators separated. Its
layer order is:

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

The current 0.14.1 matched stack publishes a schema-versioned capability manifest.
Runtime-backed commands negotiate the required version-1 contracts before
side effects, including lifecycle, observation, networking, archive, build,
image-filesystem, create-configuration, and logging-driver behavior. Unknown
additional identifiers are accepted, while missing, duplicate, or incompatible
requirements fail closed with an actionable compatibility error.

The matched provider projects the Compose service `isolation` field to the
runtime's explicit `dedicated-vm` and experimental `shared-vm` modes. Dedicated
VMs remain the default security boundary; shared workloads are accepted only
for the host, none, or built-in bridge network surfaces supported by this
release. The provider also reuses one Container client for an invocation's
ordinary control-plane work while attach and exec retain independently owned
sessions.

`ComposeCore` depends only on `ComposeRuntimeSPI` and imports no Apple modules.
Its public create-plan values use Compose-owned process, logging, health,
restart, host, and block-I/O types. `ComposeContainerRuntime` projects those
values to Apple DTOs and owns Bridge extraction, archive staging, OCI commit
image construction, and live API integration. `make
core-runtime-neutrality` enforces both the package dependency and source-import
rules.

Compose-specific resource policy stays in Core. For example, `memswap_limit`
is normalized and validated with `mem_limit` into a typed service-create plan;
the current CLI provider transports the resulting generic total
memory-plus-swap value to the matched runtime stack.

The repository's [full design document](https://github.com/stephenlclarke/container-compose/blob/main/docs/project/DESIGN.md) contains the ownership rules and layer diagram.
