# ComposeCore

Parse, normalize, and execute Compose projects with the `container` runtime.

## Overview

`ComposeCore` is the reusable Swift library behind the `compose` container plugin. It models Compose configuration, prepares service execution plans, and adapts those plans to the APIs exposed by [`container`](https://github.com/apple/container).

The generated reference covers the public configuration models and adapter protocols used to integrate Compose behavior into container-based tools.

## Topics

### Architecture

- <doc:Architecture>
