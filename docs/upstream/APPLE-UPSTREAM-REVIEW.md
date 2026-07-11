# Current Apple Upstream Review

This is the current disposition of Apple upstream work that can affect the
five-repository container stack. Re-check GitHub before preparing any Apple
submission because issue and review state can change independently of this
repository.

## Scope

- `apple/container`
- `apple/containerization`
- `apple/container-builder-shim`

The review covers every open issue typed or titled as a bug, additional open
behavior reports, linked fix pull requests, and every approved open pull
request. The current review classified 120 bug or behavior reports and found
six approved open pull requests.

## Approved Open Pull Requests

| Pull request | Local disposition |
| --- | --- |
| [apple/container#1818](https://github.com/apple/container/pull/1818) | Ported as `6e525cc`; this is the exact approved ordered-journaling source change and remains a standalone upstream commit. |
| [apple/container#1708](https://github.com/apple/container/pull/1708) | Already represented by the machine-configuration documentation in `3bb6864`. |
| [apple/container#1660](https://github.com/apple/container/pull/1660) | Already represented by the application-root backup exclusion in `3bb6864`. |
| [apple/container#1508](https://github.com/apple/container/pull/1508) | Not cherry-picked because it conflicts and the local `2bf9dfb`, `cc54428`, and `f34a51f` implementation supports default, explicit, and multiple named SSH sockets. Keep useful upstream structure when the PR is refreshed or merged. |
| [apple/container#730](https://github.com/apple/container/pull/730) | Already represented in `3bb6864`, with the additional parse-entry correction required by the fork's `@main` wrapper. |
| [apple/containerization#753](https://github.com/apple/containerization/pull/753) | Already represented by `8de8a10`, including default client ID, caller override, and request-header tests. |

## Confirmed Local Impact

| Upstream report | Result |
| --- | --- |
| [apple/container#1927](https://github.com/apple/container/issues/1927) | A missing copy-out source could leave the container state lock held. Fixed in `stephenlclarke/containerization` `b065eaa`. |
| [apple/containerization#518](https://github.com/apple/containerization/issues/518) | Exec debug logging serialized environment-backed secrets. Fixed in `stephenlclarke/containerization` `f17ec69`. |
| [apple/container#1917](https://github.com/apple/container/issues/1917) | Generated resolver files polluted the macOS global search list. Fixed in `stephenlclarke/container` `160035f`. |
| [apple/container#1888](https://github.com/apple/container/issues/1888) | `container system start` status text used stdout. The focused change from [apple/container#1889](https://github.com/apple/container/pull/1889) is ported as `0fe7833`. |
| [apple/container#1672](https://github.com/apple/container/issues/1672) | `container system stop --prefix` accepted path-like values. [apple/container#1717](https://github.com/apple/container/pull/1717) is ported as `7329f12`. |
| [apple/container#1767](https://github.com/apple/container/issues/1767) | Image snapshots omitted ordered EXT4 journaling. Approved [apple/container#1818](https://github.com/apple/container/pull/1818) is ported as `6e525cc`. |

## Open Follow-up

- [apple/container#1895](https://github.com/apple/container/issues/1895) and
  [apple/containerization#790](https://github.com/apple/containerization/issues/790)
  affect registry push when ECR briefly returns `404` after upload completion.
  Open `apple/containerization#792` retries a broader set of failures and has no
  regression coverage, so it should be narrowed and tested before use.
- [apple/container#1757](https://github.com/apple/container/issues/1757) affects
  service registration because a nonzero `launchctl bootstrap` result is not
  propagated. The local fork still needs a focused error-handling fix.

## Submission Boundary

Do not push any local commit to an Apple remote. Keep an upstream import in its
own commit with the original pull request and bug references. Locally authored
Apple-shaped fixes require issue and pull-request drafts in this directory,
focused tests, and a fresh overlap check before a human submits them.
