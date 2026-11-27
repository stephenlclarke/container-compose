# Dependency PR stock-runtime timeout

PRs 709 and 710 fail their first dry-run CLI assertion while loading the Compose model. The source-checkout normalizer uses `go run .`, but the stock-runtime job only installs Go and invokes Swift tests. A cold build of the changed Go graph is therefore charged to the first command's 30-second runtime deadline.
