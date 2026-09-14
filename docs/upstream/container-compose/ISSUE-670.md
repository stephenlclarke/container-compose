# Issue 670: isolate release tests from controller handoff state

The unattended stable-release controller exports asynchronous gate-handoff
variables before it runs the complete local release gate. The Python
release-policy suite inherits those variables when each fixture sources the
release library. Tests written to exercise the ordinary synchronous path can
therefore enter the asynchronous recovery path instead.

The 0.15.2 promotion run
[34801145630](https://github.com/stephenlclarke/container-compose/actions/runs/34801145630)
completed the matched runtime integration work and then failed four
release-resume tests. Three attempted to inspect a repository that the
synchronous fixture deliberately did not create; the fourth rejected the
fixture's abbreviated control revision as asynchronous handoff authority.

Release-tool subprocesses must remove both parent asynchronous handoff
variables, just as they already remove recursive Make state. Tests that need
the asynchronous mode continue to set it explicitly in their own shell setup.

Related issue:
[#670](https://github.com/stephenlclarke/container-compose/issues/670).
