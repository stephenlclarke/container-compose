# Issue 672: allow bounded release helper drain

Scheduled stable release run
[34811458494](https://github.com/stephenlclarke/container-compose/actions/runs/34811458494)
completed the exact 0.15.2 sibling-stack checkpoint successfully. Its durable
result records status 0 after 100 live integration tests and the combined
coverage export. The enclosing process supervisor then returned exit 125
because an Xcode Python helper remained in the supervised session beyond the
fixed 0.5-second natural-drain allowance.

The release transaction and content-addressed success checkpoint were retained,
so this was not a product or runtime failure. It nevertheless made an otherwise
successful scheduled promotion require a manual retry.

The supervisor must allow a small, bounded post-exit interval for transient
toolchain helpers. A persistent descendant must still be terminated and make an
otherwise successful command fail closed with exit 125.

Related issue:
[#672](https://github.com/stephenlclarke/container-compose/issues/672).
