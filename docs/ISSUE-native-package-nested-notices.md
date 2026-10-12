# Native candidate packaging omits nested Swift notices

## Reproduction and actual failure

At signed Compose `cff80020c4d07677e2d423ce8942db858b534872`, the native checkpoint compiled and passed all eleven unit targets (1,825 cases). Its package smoke target failed to build: `dependency_notices` rejected `Missing nested Swift source notices`. The original `compose-wait-native-checkpoint-v1` acceptance and `003-compose-wait-candidate-cli-package-tests-3.log` remain unchanged.

## Cause and expected behavior

Authenticated native binary archives preserve the five required nested source notices, but their generated package BUILD license aspect exposes only package-root notices. Package metadata must receive CArchive, CNIOLLHTTP, Abseil, Protobuf and utf8_range license files plus Crypto/NIOSSL root NOTICE texts explicitly and merge them with aspect inputs under the same source-relative identity and conflicting/empty-text checks. Missing notice requirements must remain fatal.

The admitted graph also advances Swift NIO to `0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b`, Swift Crypto to `95ba0316a9b733e92bb6b071255ff46263bbe7dc` and the NIOSSL fork to `8f2f979a28610f47714d50eccfe16b435e7e04a5`. Native inventory provenance must describe these actual pins rather than the default graph. NIOSSL's retained `Sources/CNIOBoringSSL/hash.txt` identifies BoringSSL `8eb25be6fa18d475291122887a7bccd3762ff236`; its [upstream LICENSE](https://raw.githubusercontent.com/google/boringssl/8eb25be6fa18d475291122887a7bccd3762ff236/LICENSE) has SHA256 `827c8d8fc207c2392794eef9e00fe246f9f61fdcc132556c275be3dd8c3cd97f`. The current NIO SHA1 header text matches the existing reviewed notice bytes.

## Scope and remaining proof

Preserve default stock/enhanced provenance, selected-lock validation, all required inventories and non-distribution-ready flags. Offline regression and retained-input replay can verify notice assembly; actual native package smoke remains a separate root-owned gate. No compiled product, lower artifact or historical result is rebuilt or reclassified. See [the matching PR handoff](PR-native-package-nested-notices.md).
