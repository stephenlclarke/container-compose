# PR: fix(Engine): preserve resource lifecycle across provenance changes and repeated cleanup

## Behavior

Network reuse after create409 checks stable ownership and custom labels while allowing only `com.apple.container.compose.project.config-files` and `com.apple.container.compose.project.config-files-hash` to differ when the upstream CLI adds a generated override. Name, unique identity and internal setting remain mandatory.

A successful volume DELETE retains its current path. Only a404 triggers inventory lookup, and only exact-name absence completes cleanup. A still-present volume, malformed/failed inventory or direct non404 response remains an error.

## Validation

The regressions were applied to the original production code first: stock Engine tests retained invocation `64f30da2-b810-453c-85ca-98041c3915ef` failed exactly the changed-provenance network and absent-volume cleanup cases (110 tests, two failures). After the fix, stock Engine tests passed in retained invocation `fd5c2d82-c9e4-4331-ab40-98f2b2bb0a40`. Ownership mismatch, ambiguous/malformed inventory, direct DELETE 403/503 and inventory failure cases remain rejected; successful DELETE makes no extra inventory query.

The Engine adapter and these tests belong to the stock profile; the Bazel target is intentionally incompatible with the enhanced native adapter profile. Exact-source stock coverage, packaging and fresh runtime qualification remain separate release gates. The independent Devcontainer C02 event-inventory correction is outside this lower adapter slice. Original failed campaign evidence remains unchanged.
