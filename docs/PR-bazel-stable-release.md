# PR: finalize qualified Bazel Compose releases

Related issue: [711](https://github.com/stephenlclarke/container-compose/issues/711).

## Change

The stable bridge finalizes an already qualified enhanced Compose package without rebuilding the runtime stack. It retains exact executable bytes, binds separate product/tool commits and source/notices companions, notarizes the final archive, publishes a complete immutable prerelease and verifies downloaded bytes. A durable controller tests the exact Homebrew pair with baseline restoration, publishes both tested public formulas in one signed commit and promotes the same release ID.

The runtime distribution version and original embedded product version are separately authenticated. The paired runtime installs full notices and source links from a separate hash-bound text resource while retaining the original qualified runtime archive. The runtime formula registers only its owned Compose link and preserves foreign entries. The installation transaction skips broad service-stop post-install behavior and performs bounded owned registration instead.

## Validation

Independent focused archive/controller/production-adapter tests: 32 passed. Source companion tests: five Compose and seven runtime cases passed, including recursive pinned gitlinks. Ruby registration regressions: five passed, with ten assertions. The V6 installation adapter and related existing review tests passed 26 focused cases. These fixture results do not claim a real publication or Homebrew installation pass. Full exact-source live qualification, final accepted notarization, real downloads and the production restoration receipt are admitted separately before promotion.

## Release evidence

The qualified product source remains `5a60352febdbd2db04216c65b9b60443b1bf5d39`. The matched runtime source remains `f86fea2236fab118c0e0c6f8be5eb7672df894e2`; its published archive stays unchanged. The tooling commit records these helpers. Historical failed/recovered runs remain preserved. See the [stable procedure](guides/BAZEL-STABLE-RELEASE.md) and [controller contract](compose-stable-controller.md).
