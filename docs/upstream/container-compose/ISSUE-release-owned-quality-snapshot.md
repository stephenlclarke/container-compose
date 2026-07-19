# Keep release quality snapshots available without third-party image fetches

## Problem

The Current release note placed fourteen independently fetched Shields images in
one Markdown row. A release page can therefore display a partial snapshot when
an individual third-party image request fails. The observed page rendered the
surrounding badges while Coverage and Lines of Code appeared as broken images,
even though the generated URLs and metric encoding were valid.

## Acceptance criteria

- Derive the same SonarQube and CodeQL metrics from the exact promoted commit.
- Render the complete set into one deterministic, self-contained SVG with no
  network URL in the image payload.
- Upload the SVG as a release asset before notes reference its immutable GitHub
  release-asset URL.
- Keep the mutable Current asset during retention and give stable releases their
  own immutable asset.
- Declare the Current snapshot asset in the retention step itself, so strict
  shell execution cannot fail after publication.
- Preserve accessible metric names and values in the Markdown alternative text.
- Cover SVG generation, XML escaping, CLI asset wiring, and workflow retention
  with unit and workflow-contract tests.

## Scope and compatibility

This is a Compose release-controller repair only. It changes neither Compose
runtime behavior nor quality-gate semantics. Existing releases retain their
historical notes; the next Current and stable publications use the owned asset.
