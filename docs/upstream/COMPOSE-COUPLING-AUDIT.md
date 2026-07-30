# Compose Runtime Coupling Audit

This audit classifies the fork-only commits carried for `container-compose`,
including explicit removal candidates, against current Apple upstream refs. It
is a review record, not an Apple handoff: [README.md](README.md) remains the
policy for drafts that should be raised upstream.

## Clean Baselines

The baseline refs were fetched from Apple and Stephen-owned remotes. The
strict report inspects the clean supported `main` branches without modifying
them.

| Repository | Apple upstream head | Fork head | Fork divergence at audit | Diff from Apple baseline |
| --- | --- | --- | --- | --- |
| `container` | `6e65319fe476ffe8db8ddaf828a537ed36fe2859` | `8657c4b8685865c8889b0171d953342fc9f427a7` | 0 behind, 338 ahead | 353 files, 32,340 additions, 1,240 deletions |
| `containerization` | `ff44a5b683c80fceab875dba8a20ed24d7648c07` | `971fc7e5e27467ebd6227e1ae54f3e5c23de87b4` | 0 behind, 135 ahead | 110 files, 8,570 additions, 493 deletions |
| `container-builder-shim` | `267b5ab98e1d7db7d98af98bdc90578bf5fd3192` | `61832d4ca91715180a84dec0eab091170174c43c` | 0 behind, 34 ahead | 61 files, 2,579 additions, 881 deletions |

The graph contains 507 fork-ahead commits. The refreshed audit reviewed and
classified all 440 patch-unique non-merge semantic commits (`299` in
`container`, `112` in `containerization`, and `29` in
`container-builder-shim`) with `git log --cherry-pick --right-only
--no-merges` against those Apple heads. The exact ownership and disposition
registry is
[Fork Commit Classifications](FORK-COMMIT-CLASSIFICATIONS.md).

## Classification Rule

| Classification | Disposition |
| --- | --- |
| Independent bug fix, test, CI, release, dependency, or upstream port | Retain in the support fork. It is not Compose policy and must stay individually reviewable. |
| Generic runtime or builder primitive that Compose consumes | Retain in the support fork and keep its Apple-shaped handoff. A Compose decorator cannot create missing VM, guest, cgroup, mount, networking, archive, process, device, GPU, logging, or BuildKit behavior. |
| Compose-only policy, storage, normalization, output, or adapter behavior | Move behind `ComposeRuntimeSPI` and a Compose provider. Remove the corresponding Apple handoff only when the default provider no longer requires the fork API. |

## Result

`ComposeRuntimeSPI` is now the provider seam. `ComposeCore` uses only its runtime-neutral contracts and `ComposeContainerRuntime` owns the Apple-backed composition graph. This moves adapter construction, runtime types, and compatibility decoration below Compose policy without pretending that generic runtime capabilities can be recreated in an interception layer.

The complete Compose-only external-resource slice has moved:

- External configs now use the Compose-owned filesystem reader, rooted at `CONTAINER_COMPOSE_CONFIG_DIRECTORY` or `~/.config/container-compose/configs`.
- External secrets now use the caller's Keychain generic-password item, service `com.apple.container-compose`, through the Compose-owned reader.
- The config/secret reader contracts remain injectable `ComposeRuntimeSPI` interfaces, so another runtime provider can replace the local backends without changing orchestration.
- The six superseded config/secret handoff and tracking documents were removed. Provisioning and security semantics are documented in [External Compose Resources](../../external-resources.md).

The remaining runtime-composition candidates are deliberately retained:

- Resource controls, device/GPU settings, mounts, process namespaces, guest networking and address allocation require lower-runtime behavior, not a Compose wrapper.
- Memory-plus-swap support follows that rule: Compose owns the `memswap_limit` relationship and defaulting policy, while the matched runtime carries one optional signed-byte primitive to OCI `LinuxMemory.swap`.
- Copy/export, log/event streaming, health observation, and lifecycle paths require runtime-owned state or guest processes.
- Build attestations, SSH forwarding, named-builder selection, checks, and BuildKit transport remain builder primitives. Recreating the builder-shim lifecycle in Compose would increase, rather than reduce, coupling.

The complete refreshed classification contains 310 support-maintenance
commits, 105 generic runtime primitives, 21 temporary upstream ports, and four
rejected Compose-policy commits. The rejected config, secret, and Keychain
storage slices are explicit FORK-105 removal candidates.

## Decorator Boundary

A focused decorator remains appropriate only after the runtime exposes a constrained, versioned extension or a complete typed primitive. It can validate Compose-owned plans, negotiate a declared capability, and translate that plan at the `ComposeRuntimeSPI` boundary. It must not use source swizzling, private runtime storage, process injection, or a general interception framework.

The outstanding [runtime-configuration extension proposal](apple-container/ISSUE-runtime-configuration-extension-hook.md) describes the narrow future hook for typed Linux runtime data. It cannot replace the lower-runtime primitives listed above, and it is not a justification for an unbounded AOP layer.

## Re-audit Procedure

After an upstream refresh, recreate or reset only the clean audit worktrees to the new Apple heads, then compare the support heads:

```sh
git -C /Users/sclarke/github/container log --cherry-pick --right-only --no-merges --oneline origin/main...main
git -C /Users/sclarke/github/containerization log --cherry-pick --right-only --no-merges --oneline upstream/main...main
git -C /Users/sclarke/github/container-builder-shim log --cherry-pick --right-only --no-merges --oneline origin/main...main
```

Classify every new semantic commit with the rule above. Preserve bug fixes and generic runtime primitives in the support forks; move only complete Compose-only slices into the provider layer. Update the reviewed JSON registry explicitly, then run:

```sh
make fork-classifications-check
```

The check fails for an unclassified, duplicate, stale, or invalid entry and
does not assign a disposition automatically.
