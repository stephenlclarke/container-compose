# Engine resource lifecycle rejects generated-file provenance and repeated volume deletion

## Observed failures

The retained `bf02d4959b8c` full campaign against Compose `79b3c92930a64fa151b856f2254db8d16825661d` failed Q C04 recreate with HTTP 409 for existing `c04-compose-lifecycle_default`. Initial upstream up supplies the fixture file plus a generated features override; lifecycle recreation supplies only the fixture file. Network resource labels record the file list and its hash, so the existing reuse guard incorrectly rejects changed provenance for the same owned network.

The first down succeeds. Repeated cleanup down then reports HTTP 404 for the already removed managed volume `c04-compose-lifecycle_lifecycle-state`, retaining one project claim and zero runtime containers. The Engine adapter unconditionally deletes volumes, while the native adapter handles proven absence.

## Expected behavior and scope

Exclude only the two native config-file provenance labels from network reuse equality. Continue binding project, logical network, working directory, version, custom labels, unique name/identity and internal setting. For volume deletion, preserve successful DELETE and all non404 failures; only404 may query inventory and succeed when the exact name is absent. Preserve existing/malformed/unavailable inventory failures.

Change only the lower Compose Engine adapter, focused regressions and documentation. The campaign's separate C02 empty success JSON/events EOF is unresolved and outside this correction. Original failed evidence remains failed; no comparator or ownership waiver is permitted.
