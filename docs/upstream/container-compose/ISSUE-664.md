# Issue 664: require a public VM-init authority

The Current and stable stack gates proved that an exact Containerization build
produced a retained VM-init filesystem, but did not prove that a clean runtime
could resolve the compiled GHCR reference without credentials. A retained OCI
archive allowed releases to pass while the public registry reference returned
`404 Not Found` to a fresh Homebrew installation.

The release preflight must treat both authorities as mandatory: the exact
retained build artifact proves provenance, while an anonymous registry pull
proves that the installed runtime can boot from its immutable default.

Related issue: [#664](https://github.com/stephenlclarke/container-compose/issues/664).
