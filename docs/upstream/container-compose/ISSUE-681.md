# Issue 681: isolate signing state in release-policy tests

Scheduled stable release run [34896635604](https://github.com/stephenlclarke/container-compose/actions/runs/34896635604) completed the exact sibling-stack checkpoint in 5,226.760 seconds, including 409 live Container integration tests, then failed the Compose CI checkpoint. The 643-test release-tool suite finished in 728.318 seconds with exactly two failures: `test_hosted_stack_validation_excludes_virtualization_commands` and `test_runtime_candidate_staging_rejects_missing_signing_keychain`.

Both fixtures intentionally verify that release orchestration fails closed when no operation-scoped Developer ID Keychain is configured. The scheduled workflow correctly exports `DEVELOPER_ID_KEYCHAIN`, so the tests inherited a real, valid Keychain from their parent process. The hosted-stack fixture therefore succeeded instead of returning the expected configuration error, while the runtime-candidate fixture continued until an unrelated Git failure. The release product path, certificate installation, isolated signing, and all live runtime checks remained healthy; the defect is non-hermetic test setup.

Every release-policy fixture must remove parent `CONTAINER_RUNTIME_CODESIGN_IDENTITY` and `DEVELOPER_ID_KEYCHAIN` values unless the fixture explicitly supplies them. The direct hosted-stack fixture also needs to clear the Keychain before exercising its missing-identity and missing-Keychain branches. Regression coverage must run with both variables deliberately inherited and prove that the test helper removes them.

This correction changes test isolation only. It must not alter Compose behavior, Docker Compose parity, Apple runtime integration, release artifact contents, or checkpoint fingerprints. The corrected 0.15.2 release should reuse the completed exact-input sibling-stack checkpoint and rerun the failed Compose CI checkpoint from reviewed `main`.

Related issue: [#681](https://github.com/stephenlclarke/container-compose/issues/681).
