# Issue 664: require a public VM-init authority

The Current and stable stack gates proved that an exact Containerization build
produced a retained VM-init filesystem, but did not prove that a clean runtime
could resolve the compiled GHCR reference without credentials. A retained OCI
archive allowed releases to pass while the public registry reference returned
`404 Not Found` to a fresh Homebrew installation.

The release preflight must treat both authorities as mandatory: the exact
retained build artifact proves provenance, while an anonymous registry pull
proves that the installed runtime can boot from its immutable default.

The Compose package and release manifest also advance together to Container
`14257435e40367d60ac3904f4f67ca35d1c29fe5` and Containerization
`aa6b0bdeef888b52afaf290cc7ac1909c3ac6fe5`, the reviewed source pair that
passed the clean Developer-ID-signed runtime boot.

Related issue: [#664](https://github.com/stephenlclarke/container-compose/issues/664).
