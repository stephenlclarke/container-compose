//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

// Portions derived from Docker Compose.
// Copyright 2023 Docker Compose CLI authors.

package oci

import (
	"context"
	"io"
	"net/http"
	"slices"

	"github.com/containerd/containerd/v2/core/remotes"
	"github.com/containerd/containerd/v2/core/remotes/docker"
	"github.com/distribution/reference"
	"github.com/docker/cli/cli/config/configfile"
	spec "github.com/opencontainers/image-spec/specs-go/v1"
)

const (
	// ComposeProjectArtifactType is the OCI 1.1-compliant artifact type value
	// for the generated image manifest.
	ComposeProjectArtifactType = "application/vnd.docker.compose.project"
	// ComposeYAMLMediaType is the media type for each layer (Compose file)
	// in the image manifest.
	ComposeYAMLMediaType = "application/vnd.docker.compose.file+yaml"
	// ComposeEmptyConfigMediaType is the OCI 1.0 fallback config media type
	// used to recognize Compose project artifacts.
	ComposeEmptyConfigMediaType = "application/vnd.docker.compose.config.empty.v1+json"
	// ComposeEnvFileMediaType is the media type for each env-file layer.
	ComposeEnvFileMediaType = "application/vnd.docker.compose.envfile"
)

// NewResolver sets up an OCI resolver with Docker-compatible registry
// credentials. A nil transport falls back to containerd's default transport.
func NewResolver(config *configfile.ConfigFile, transport http.RoundTripper, insecureRegistries ...string) remotes.Resolver {
	authOpts := []docker.AuthorizerOpt{
		docker.WithAuthCreds(func(host string) (string, string, error) {
			auth, err := config.GetAuthConfig(authConfigKey(host))
			if err != nil {
				return "", "", err
			}
			if auth.IdentityToken != "" {
				return "", auth.IdentityToken, nil
			}
			return auth.Username, auth.Password, nil
		}),
	}
	if transport != nil {
		authOpts = append(authOpts, docker.WithAuthClient(&http.Client{Transport: transport}))
	}
	opts := []docker.RegistryOpt{
		docker.WithAuthorizer(docker.NewDockerAuthorizer(authOpts...)),
		docker.WithPlainHTTP(func(domain string) (bool, error) {
			return slices.Contains(insecureRegistries, domain), nil
		}),
	}
	if transport != nil {
		opts = append(opts, docker.WithClient(&http.Client{Transport: transport}))
	}
	return docker.NewResolver(docker.ResolverOptions{
		Hosts: docker.ConfigureDefaultRegistries(opts...),
	})
}

// Get retrieves a named OCI resource and returns its descriptor and manifest.
func Get(ctx context.Context, resolver remotes.Resolver, ref reference.Named) (spec.Descriptor, []byte, error) {
	_, descriptor, err := resolver.Resolve(ctx, ref.String())
	if err != nil {
		return spec.Descriptor{}, nil, err
	}

	fetcher, err := resolver.Fetcher(ctx, ref.String())
	if err != nil {
		return spec.Descriptor{}, nil, err
	}
	fetch, err := fetcher.Fetch(ctx, descriptor)
	if err != nil {
		return spec.Descriptor{}, nil, err
	}
	defer fetch.Close()
	content, err := io.ReadAll(fetch)
	if err != nil {
		return spec.Descriptor{}, nil, err
	}
	return descriptor, content, nil
}

func authConfigKey(host string) string {
	if host == "registry-1.docker.io" {
		return "https://index.docker.io/v1/"
	}
	return host
}
