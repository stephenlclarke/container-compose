# Issue 624: Keep stable authority lookup compatible with the release runner

Issue [#624](https://github.com/stephenlclarke/container-compose/issues/624) tracks a packaging failure exposed after the candidate-bound 0.14.3 Stable Release Gate passed.

## Failure

The stable package workflow requests paginated check runs with `gh api --paginate --slurp` and applies its filter through the same command's `--jq` option. The GitHub CLI installed on the release runner rejects `--slurp` together with `--jq`, so the workflow stops before building binaries despite having a valid successful release authority.

## Contract

- Preserve pagination and slurping so the authority lookup covers every check-run page.
- Apply the existing candidate-bound authority filter as a separate `jq -r` process under `set -o pipefail`.
- Continue to fail closed when no successful GitHub Actions authority, valid receipt binding, or successful authority workflow run exists.
- Prevent the incompatible combined `gh --slurp --jq` form from returning to the stable tag path.

## Evidence

Stable package run [34468851916](https://github.com/stephenlclarke/container-compose/actions/runs/34468851916) failed in `Require the hosted release authority` with `the --slurp option is not supported with --jq or --template` after Stable Release Gate run [34465109888](https://github.com/stephenlclarke/container-compose/actions/runs/34465109888) passed.
