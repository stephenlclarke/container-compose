# Pull request: add a generic IPv6 network-disablement control

## Summary

- Add enableIPv6 to NetworkConfiguration with a default true value and backward-compatible Codable decoding.
- Reject a configuration that disables IPv6 while specifying an IPv6 subnet.
- Thread the typed setting through the API service and network helper.
- Configure vmnet with NAT66 and router advertisements disabled when IPv6 is false.
- Report no IPv6 prefix in realized network status and expose the primitive through container network create --disable-ipv6.

## Intended review delta

This Apple-shaped draft is constructible from [4bce15d507837e3f8bb58ebc4efd557a283bff82](https://github.com/stephenlclarke/container/commit/4bce15d507837e3f8bb58ebc4efd557a283bff82), feat(network): add IPv6 disablement control. The commit contains no Compose parser, Docker model, project label, output formatting, or orchestration policy.

## Implementation details

NetworkConfiguration stores the generic Boolean beside existing typed subnet properties. Its custom decoding preserves the enabled default for old persisted configurations. The public CLI and the internal helper use the same generic disable flag. The API service copies the typed value and forwards the helper argument.

ReservedVmnetNetwork applies the two public vmnet configuration keys before starting the network. When disabled, it does not query or publish an IPv6 prefix. The result is generic runtime behavior usable by any caller.

## Upstream context

[apple/container issue 282](https://github.com/apple/container/issues/282) remains the related user-addressing request. [apple/container pull request 1174](https://github.com/apple/container/pull/1174) proposes IPv6 gateway support. This change is independent and may be reviewed separately.

## Code map

- Sources/ContainerResource/Network/NetworkConfiguration.swift
- Sources/ContainerCommands/Network/NetworkCreate.swift
- Sources/Plugins/NetworkVmnet/NetworkVmnetHelper+Start.swift
- Sources/Services/ContainerAPIService/Server/Networks/NetworksService.swift
- Sources/Services/NetworkVmnet/Server/ReservedVmnetNetwork.swift
- Tests/ContainerResourceTests/NetworkConfigurationTest.swift
- Tests/IntegrationTests/Network/TestCLINetwork.swift

## Validation

    swift test --skip-build --filter NetworkConfigurationTest --no-parallel
    make check
    CLITEST_SCRATCH_ROOT="$PWD/.test-scratch" CONTAINER_CLI_PATH="$PWD/bin/container" swift test --skip-build -c debug --filter TestCLINetwork.testNetworkCreateWithIPv6Disabled

The focused unit suite, repository check, and macOS 26 live CLI integration passed against the fork runtime. container-compose separately verifies Docker Compose v5.3.1 model and dry-run parity; that compatibility coverage remains outside Apple CI.

## Compatibility and risk

The default is enabled, so existing clients and stored configurations retain their current behavior. The only new invalid configuration is the contradictory combination of a disabled IPv6 setting and an IPv6 subnet. The macOS availability of the vmnet configuration keys is guarded by the existing macOS 26 runtime surface.

## Handoff status

No Apple remote has been modified. The Stephen-owned fork commit is ready for Apple-maintainer review and can be proposed independently of the Compose source commit.
