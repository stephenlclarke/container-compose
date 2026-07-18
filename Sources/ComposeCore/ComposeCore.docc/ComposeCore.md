# ``ComposeCore``

@Metadata {
  @PageImage(purpose: icon, source: "container-compose-icon-octopus.png", alt: "The container-compose application icon: a light-blue octopus in front of a container service panel.")
  @PageImage(purpose: card, source: "container-compose-icon-octopus.png", alt: "The container-compose application icon: a light-blue octopus in front of a container service panel.")
}

Parse, normalize, and execute Compose projects with the `container` runtime.

@Image(source: "container-compose-icon-octopus.png", alt: "The container-compose application icon: a light-blue octopus in front of a container service panel.")

## Overview

`ComposeCore` is the reusable Swift library behind the `compose` container plugin. It models Compose configuration, prepares service execution plans, and adapts those plans to the APIs exposed by [`container`](https://github.com/apple/container).

The generated reference covers the public configuration models and adapter protocols used to integrate Compose behavior into container-based tools.

## Topics

### Runtime Architecture

- <doc:Architecture>

### Container Ecosystem

- <doc:ContainerProjects>
