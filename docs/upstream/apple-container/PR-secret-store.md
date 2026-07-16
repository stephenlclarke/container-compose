# Apple PR Handoff: Local Opaque Secret Store

## Intended Review Delta

- `stephenlclarke/container`
  `468a85e233dd9ee71897adfada3d812d1da0d4cf`
  `feat(secret): add local keychain secret store (#12)`

The change is merged only in the Stephen-owned fork. It is not pushed to an
Apple repository.

## Changes

- Add `SecretConfiguration`, `SecretResource`, validation, and typed errors.
- Add `ClientSecret` over the generic Keychain password primitive using service
  `com.apple.container.secret`.
- Add `container secret create|list|inspect|delete`; list and inspect print
  metadata only, and no CLI read command is provided.
- Read values in the API-client process rather than through XPC so macOS
  Keychain process access controls remain effective.
- Add binary round-trip, duplicate-create, metadata privacy, and name
  validation coverage.

## Validation

```sh
make check
swift test --filter 'SecretValidationTests|ClientSecretTests'
make test
swift run container secret --help
```

The full fork test run passed with 957 tests across 122 suites.
