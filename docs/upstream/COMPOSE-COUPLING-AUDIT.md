# Compose Runtime Coupling Audit

This audit classifies the fork-only commits needed by `container-compose` against clean Apple-upstream worktrees. It is a review record, not an Apple handoff: [README.md](README.md) remains the policy for drafts that should be raised upstream.

## Clean Baselines

The baseline worktrees are clean local branches at Apple upstream heads. They make the retained delta independently inspectable without modifying the established support forks.

| Repository | Clean worktree | Apple upstream head | Fork divergence at audit | Diff from Apple baseline |
| --- | --- | --- | --- | --- |
| `container` | `/Users/sclarke/github/worktrees/container-apple-upstream-audit-20260717` | `07ff3c0a72503a71f161784c95d059e80058af14` | 0 behind, 165 ahead | 254 files, 22,982 additions, 1,080 deletions |
| `containerization` | `/Users/sclarke/github/worktrees/containerization-apple-upstream-audit-20260717` | `2a591c2aeed6ff0cc70f00a5a8bf06b112b433c2` | 0 behind, 78 ahead | 76 files, 5,209 additions, 360 deletions |
| `container-builder-shim` | `/Users/sclarke/github/worktrees/container-builder-shim-apple-upstream-audit-20260717` | `267b5ab98e1d7db7d98af98bdc90578bf5fd3192` | 0 behind, 31 ahead | 60 files, 2,474 additions, 875 deletions |

The graph contains 274 fork-ahead commits. The audit reviewed all 248 non-merge semantic commits (`152` in `container`, `69` in `containerization`, and `27` in `container-builder-shim`) with `git log --cherry-pick --right-only --no-merges` against those Apple heads.

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

Classify every new semantic commit with the rule above. Preserve bug fixes and generic runtime primitives in the support forks; move only complete Compose-only slices into the provider layer.
