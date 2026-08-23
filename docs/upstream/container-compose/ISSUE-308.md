# Issue 308: include lifecycle helper images in config image projection

## Problem description

Docker Compose includes explicit `pre_start.image` references in
`config --images`. Container Compose projected only service images and generated
build tags, so lifecycle projects omitted helper images even though create and
up preparation consumed them.

## Resolution

The image projection now combines selected services' normal runtime images with
their distinct explicit pre-start helper images, then applies the existing
deterministic sort. Selection remains scoped: helper images from unselected
services are not reported.

## Focused evidence

- Focused `config renders supported projections` unit test, covering generated
  build tags, helper-image deduplication, deterministic order, and selection.
- Exact matched-stack lifecycle-hooks parity contract.

## Scope

This fixes the configuration projection only. Lifecycle execution and create/up
image-policy preparation already consumed explicit helper images. An explicit
`compose pull` remains scoped to ordinary service images.

Refs [#308](https://github.com/stephenlclarke/container-compose/issues/308).
