# Issue 688: refresh the Current stack pins

The `Prebuilt Binaries` workflow correctly stopped publishing after the
Container family repositories advanced beyond the exact revisions recorded in
`Tools/release/stack-refs.json`. Publishing the older manifest would have
misrepresented the tested source stack and retained a stale builder image.

The Current package must advance Container, Containerization, and the builder
shim as one matched set. The builder entry must use the immutable digest from
the release metadata produced for the same exact builder commit; its mutable
tag remains discovery metadata only.

The final matched replacement set is:

- Container `ef78345f59fdb913b3abce6ac0445616955c4e55`;
- Containerization `4c95face06701be6572c92db34ca1864329c7b69`;
- builder shim `016040197215684db474181b444767eb58797cfa`;
- builder image digest
  `sha256:a20bf1788286e46fb2c2025acdce6b6e9cdd11394e0875e0f3297415d1c4d108`.

This correction preserves the fail-closed release check. It does not weaken or
bypass the comparison with each component's protected `main` branch.

The first synchronized publication attempt passed those checks and then
exposed an Xcode 27 release-compiler diagnostic in the enhanced Container
runtime. Container pull request
[#274](https://github.com/stephenlclarke/container/pull/274) fixes that
production-build defect. The Current manifest must now advance its Container
pin to the resulting protected-main commit
`ef78345f59fdb913b3abce6ac0445616955c4e55` before publication is retried.

Related issue: [#688](https://github.com/stephenlclarke/container-compose/issues/688).
