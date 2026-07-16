# Apple PR Handoff: Generic Local Keychain Password Store

## Intended Review Delta

- `stephenlclarke/containerization`
  `9f63d1890ebbb999f552e88124cbcc6e7813e631`
  `feat(keychain): add generic password storage`

The change is merged only in the Stephen-owned fork. It is not pushed to an
Apple repository.

## Changes

- Add generic-password save, lookup, existence, delete, and metadata-list
  operations to `KeychainQuery`.
- Use a `(service, account)` identity and `Data` payloads.
- Keep list results metadata-only; callers must explicitly retrieve a value.
- Add binary data, duplicate, missing-item, and metadata coverage.
- Mark the existing intentional legacy accessibility test as deprecated so the
  project remains clean under warnings-as-errors.

## Validation

```sh
make check
make test
```

The fork validation completed with 606 tests across 81 suites.
