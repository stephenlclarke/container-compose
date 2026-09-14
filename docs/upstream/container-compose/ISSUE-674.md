# Issue 674: allow a bounded natural drain after the release gate

Unattended stable release run
[34825534574](https://github.com/stephenlclarke/container-compose/actions/runs/34825534574)
completed the exact 0.15.2 sibling-stack checkpoint successfully. Its durable
result records status 0 after 5,154.089933 seconds, including 100 serial live
Apple Container integration tests and combined coverage export. The enclosing
process supervisor then returned exit 125 because a verified Xcode Python
descendant remained in the gate session beyond the default five-second natural
drain.

The fail-closed result and cleanup are correct for an ordinary command. The
release gate, however, has an existing 30-second candidate cleanup bound and
normal Apple/Xcode teardown can outlive the general-purpose allowance. A
changed sealed environment fingerprint also prevents a retry from reliably
reusing the otherwise valid checkpoint.

The process supervisor therefore needs an explicit, validated natural-drain
option. Only the expensive release-gate wrapper should select the existing
30-second bound. A process that remains live after that interval must still be
terminated and make the release fail closed. Cancellation during this extended
drain must use the same detached cleanup watchdog as cancellation while the
direct child is running, so an outer `SIGKILL` escalation cannot orphan the
verified session.

Related issue:
[#674](https://github.com/stephenlclarke/container-compose/issues/674).
