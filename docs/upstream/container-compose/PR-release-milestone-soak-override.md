# Pull request: add an auditable milestone-soak override

## Summary

Add `CONTAINER_STACK_MILESTONE_SOAK_OVERRIDE_REASON` for exceptional,
maintainer-authorized milestone promotion. The override is accepted only for
`CONTAINER_STACK_RELEASE_INTENT=milestone` and bypasses only the seven-day
Current soak. It does not weaken Current identity/package checks, local and
hosted release gates, signed tags, immutable release assets, or paired
Homebrew verification.

## Constructible commit

- `6014231c2e32c5bf23d6e8da90c69a384463d1a9`
  `fix(release): allow documented milestone soak override`

## Implementation

- `scripts/CONTAINER_STACK_RELEASE.sh` documents and enforces the
  milestone-only override, leaves the weekly soak default intact, and logs the
  accepted rationale before release preparation.
- `BUILD.md` documents the exceptional command and the gates it does not
  bypass.
- `Tools/release/test_container_stack_release.py` proves the override remains
  after Current source/package checks and is confined to the milestone path.

## Verification

```sh
python3 -m unittest Tools/release/test_container_stack_release.py
bash -n scripts/CONTAINER_STACK_RELEASE.sh
make check
```

## Promotion command

```sh
CONTAINER_STACK_RELEASE_INTENT=milestone \\
CONTAINER_STACK_MILESTONE_SOAK_OVERRIDE_REASON='explicit maintainer authorization: promote Current as 0.7.0' \\
make release VERSION_SELECTOR=0.7.0
```

The command remains subject to all non-soak release controls.
