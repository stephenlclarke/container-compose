# Pull request: refresh upstreams and publish reviewed runtime corrections

## Summary

- Record a complete zero-behind audit for all Apple-backed forks.
- Correct four reproducible runtime hot paths from `apple/container#2022`.
- Keep review follow-ups and bootstrap cleanup in focused signed runtime
  commits.
- Pin Compose to the exact reviewed runtime revision.
- Remove oversized caches only from the release package lane.
- Refresh current Apple proposal, connector, dependency-bot, validation, and
  release evidence.

The companion report is
[ISSUE-upstream-maintenance-20260727.md](ISSUE-upstream-maintenance-20260727.md).

## Intended review delta

The Apple-shaped runtime changes are in
[stephenlclarke/container#30](https://github.com/stephenlclarke/container/pull/30).
Reviewed head `281208b1a8db06c92348afdeb1c163e043637c16` merged without
tree changes as `5796a79ee3e59c16098d086278c072740d519ee8`.
The independently useful implementation commits are:

| Commit | Purpose |
| --- | --- |
| `abab498f01c4f7325c7b41ec8254a186640824f2` | Compile build ignore globs once. |
| `41e31f7fe34e4a6a99ed9dd29512fd99a2cbc074` | Use hashed build-context membership. |
| `600fde28de94093fc5a067e19a29358a9adcec9e` | Sample independent container stats concurrently. |
| `b15ac4aaf1ad7ce59a124c7e222a427565525d3a` | Size resources outside service locks. |
| `345ae6d50db8480b1f85a481b15a6d8c291fe6d3` | Install init only after runtime bootstrap. |
| `d48a962c30b873d054345cbbb5856eb616e4f2ee` | Keep volume-prune failures isolated. |
| `4436afea7c31a6a6a99e37ea7254465d333d9147` | Preserve Unicode-sensitive glob matching. |
| `25bfef8c7f810aed0442d7214e2e9fd38f3bd89c` | Clean partial bootstrap state on failure. |
| `98b3ae7db2d3dcfdcefd6e4eace5a65f850ac52e` | Reuse a healthy active runtime during install. |
| `c7d05f1e3396436d96090dbffc8f8196d34f3c1d` | Keep volume-usage counts on one snapshot. |
| `20e00d7b340b4a7daf730f505e6a3e80dc812ebc` | Isolate integration bootstrap configuration. |

Documentation-only commits `a111a4e`, `1621722`, `c76ae6a`, `2a0e32a`, and
`37fc529` provide aggregate and review-follow-up handoffs without changing
runtime behavior. `281208b` records the final isolated-bootstrap correction.
The commit-identity correction in `37fc529` ensures every referenced full hash
resolves to the named commit.

The Compose implementation commits are:

| Commit | Purpose |
| --- | --- |
| `6cae9a84deee2b13eecfeb1efbf83ad2c98f88a9` | Avoid oversized release dependency caches. |
| `e45240b718bf88a709e4fbb7056dfa0af4a1811e` | Initially pin manifests and stack metadata to reviewed production runtime `2a0e32a`. |
| `c9a343f0d658dbb576c52a33e1ea97f3130bc730` | Pin all consuming identities to merged runtime `5796a79`. |

## Code map

### `stephenlclarke/container`

- `Sources/ContainerBuild/BuildFSSync.swift`: compiled ignore-pattern cache.
- `Sources/ContainerBuild/ContentStore.swift`: hashed context membership.
- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`:
  concurrent stats and off-lock container sizing.
- `Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift`:
  isolated prune failures and snapshot-consistent off-lock volume sizing.
- `scripts/install-init.sh`: ordered, failure-safe, active-runtime-aware
  bootstrap.
- `Makefile`: one configuration-isolated `init-block` invocation inside the
  integration execution sequence.
- Focused unit and shell tests cover each correction.

### `container-compose`

- `Package.swift` and `Package.resolved`: exact runtime dependency.
- `Tools/release/stack-refs.json`: matching release source identity.
- `.github/workflows/prebuilt-binaries.yml`: cache-free package lane.
- `Tools/release/test_container_stack_release.py`: workflow-policy regression
  coverage.
- `docs/upstream/`: current audit, issue reports, Apple-shaped handoffs, and
  immutable proposal references.

## Validation

```console
# container
make coverage-unit
make test
make check
make test-install-init

# container-compose
python3 Tools/ci/check-stack-consistency.py
HAWKEYE_AUTO_INSTALL=1 make ci
CONTAINER_STACK_REPO=/absolute/path/to/container \
  CONTAINERIZATION_STACK_REPO=/absolute/path/to/containerization \
  CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
  make docker-compose-parity
```

Container unit coverage passes 1,148 tests in 134 suites with 39.27% line
coverage. Source-matched Container integration previously passed 293
concurrent and 87 serial scenarios, and combined coverage reached 51.56%.
The complete Compose release suite passes 175 tests. Full Compose CI passes
1,249 Swift tests in 41 suites with 92.81% Swift and 89.88% Go coverage. The
connector reviewed runtime production head `2a0e32acbf` and reported no major
issue after every earlier actionable thread was answered and resolved. A later
review identified that the integration bootstrap inherited developer
configuration; `20e00d7` moves the sole invocation inside the isolated
sequence and passes its scratch `XDG_CONFIG_HOME`, with a full-target Make
dry-run regression. Docker Compose v5.3.1 parity passes all 62 strict
assertions against the unchanged runtime production tree. The connector then
reviewed exact final runtime head `281208b1a8` with no major issue. Runtime
hosted run
[30249659444](https://github.com/stephenlclarke/container/actions/runs/30249659444)
then passed signatures, build, package, and project tests before merge.
Compose hosted checks and SonarCloud remain publication gates.

## Compatibility and risk

- No public runtime API or Compose model contract changes.
- Build glob semantics retain the existing Swift regex behavior, including
  Unicode-sensitive matches.
- Stats preserve input ordering and all-or-fail error semantics.
- Storage counts retain their metadata total while active and reclaimable
  values derive from one validated snapshot.
- Bootstrap skips replacement only when the existing runtime is healthy and
  bound to the requested application root.
- The release change removes cache transfer only; package inputs, outputs,
  checksums, attestations, and authority checks remain unchanged.
- No Windows path or Linux-host implementation is added.

## Checklist

- [x] Every Apple-backed fork contains current Apple `main`
- [x] Signed Conventional implementation commits
- [x] Focused regression tests and unit coverage
- [x] Apple-shaped issue and pull-request handoffs
- [x] Exact Compose dependency and release stack pin
- [x] Complete Compose release-policy tests
- [x] Exact final-head connector review
- [x] Docker Compose v5.3.1 live parity
- [ ] Hosted CI, CodeQL, Quality, documentation, and SonarCloud
- [ ] Signed prerelease and typed/live VHS evidence
