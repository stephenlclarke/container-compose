# Issue 679: bind unattended signing to the operation Keychain

Scheduled stable release run [34884902647](https://github.com/stephenlclarke/container-compose/actions/runs/34884902647) installed and preflighted a temporary Developer ID Keychain, then stopped making progress while a nested Container build signed its executable. Process sampling showed `codesign` blocked in SecurityServer signature generation.

The release controller passed the exact certificate fingerprint into the runtime candidate, direct Container build, and stack-validation signing paths, but none of those three `CODESIGN_OPTS` values included the temporary Keychain path. The host has more than one copy of that Developer ID identity, so macOS could select a login-Keychain private key and open an account-authentication prompt even though the operation-scoped private key had already been authorised for unattended signing.

Every release-owned source-runtime signing path must bind `codesign` to the validated `DEVELOPER_ID_KEYCHAIN`. The configured path must be absolute, restricted to shell-safe pathname characters, a regular file, and not a symlink; its parent is canonicalised before use. Invalid or absent configuration must fail before an expensive source build. The operation-scoped path remains retry metadata rather than a product input: the certificate fingerprint continues to carry the signing identity in checkpoint evidence while a new workflow attempt may safely create a different temporary Keychain filename.

Regression coverage must prove that the runtime candidate, direct Container build, and independently checkpointed Container targets all receive `--keychain` before `--sign`, and that unsafe or missing paths fail closed. The corrected unattended 0.15.2 release must resume from retained exact-input checkpoints and complete without another Keychain prompt.

Related issue: [#679](https://github.com/stephenlclarke/container-compose/issues/679).
