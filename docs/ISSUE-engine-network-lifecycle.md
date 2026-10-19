# Engine network operations fail repeated Compose lifecycle requests

The exact `5bda8798320d` campaign's Q C04 recreate failed with HTTP 409 because `c04-compose-lifecycle_default` already existed. Its first down succeeded, but repeated cleanup down failed with HTTP 404 after network removal, retaining one project claim and zero runtime containers.

`ComposeCore.ensureNetwork` invokes resource creation on each up. The native adapter tolerates typed exists/notFound outcomes, while the Engine adapter unconditionally creates and deletes. Preserve strict ownership and identity checks while making these Engine lifecycle calls idempotent. Do not weaken the campaign comparator or normalize ambiguous errors.

## Steps to reproduce

Run the C04 Compose lifecycle fixture through the stock Engine gateway: create the project, restart it, recreate it with `up`, then run `down` twice. The second creation encounters an existing network, and the repeated deletion encounters an absent network. Both should succeed when inventory confirms the expected resource identity or its absence.

## Environment and evidence

The failure used Compose source `57ee265a5fbd17a1109240a0d0aa99da01acfc3a` and Devcontainer source `5bda8798320dd933be21511b602df71cf6f80a4c`, with the pinned Q Container runtime and retained signed stock gateway. The original campaign evidence is preserved. The regression suite reproduces both failures on the original adapter and passes after the correction.

## Linked change

See [the implementation and validation handoff](PR-engine-network-lifecycle.md). No GitHub issue or PR number has been assigned.
