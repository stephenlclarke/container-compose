# ``ComposeCore``

@Metadata {
  @PageImage(purpose: icon, source: "container-compose-docc-card.png", alt: "The container-compose DocC illustration: a light-blue octopus beside the standard three-row container service panel.")
  @PageImage(purpose: card, source: "container-compose-docc-card.png", alt: "The container-compose DocC card illustration: a light-blue octopus beside the standard three-row container service panel.")
}

Parse, normalize, and execute Compose projects with the `container` runtime.

## Overview

`ComposeCore` is the reusable Swift library behind the `compose` container plugin. It models Compose configuration, prepares runtime-neutral service execution plans, and orchestrates them through `ComposeRuntimeSPI` providers. The plugin supplies the [`container`](https://github.com/apple/container)-backed provider.

The generated reference covers the public configuration models and adapter protocols used to integrate Compose behavior into container-based tools.

## Topics

### Runtime Architecture

- <doc:Architecture>

### Container Ecosystem

- <doc:ContainerProjects>
