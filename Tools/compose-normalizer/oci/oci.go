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
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/containerd/containerd/v2/core/remotes"
	"github.com/containerd/containerd/v2/core/remotes/docker"
	remoteserrors "github.com/containerd/containerd/v2/core/remotes/errors"
	"github.com/containerd/containerd/v2/pkg/labels"
	"github.com/containerd/errdefs"
	"github.com/distribution/reference"
	"github.com/docker/cli/cli/config/configfile"
	"github.com/moby/buildkit/util/contentutil"
	"github.com/opencontainers/go-digest"
	"github.com/opencontainers/image-spec/specs-go"
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

const composeVersionAnnotation = "container-compose"

// OCIVersion controls the manifest shape used for Compose project artifacts.
type OCIVersion string

const (
	OCIVersion1_0 OCIVersion = "1.0"
	OCIVersion1_1 OCIVersion = "1.1"
)

var clientAuthStatusCodes = []int{
	http.StatusUnauthorized,
	http.StatusForbidden,
	http.StatusProxyAuthRequired,
}

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

// Copy mounts/copies an image descriptor chain into the target repository.
func Copy(ctx context.Context, resolver remotes.Resolver, image reference.Named, named reference.Named) (spec.Descriptor, error) {
	src, desc, err := resolver.Resolve(ctx, image.String())
	if err != nil {
		return spec.Descriptor{}, err
	}
	if desc.Annotations == nil {
		desc.Annotations = make(map[string]string)
	}
	refspec := reference.TrimNamed(image).String()
	u, err := url.Parse("dummy://" + refspec)
	if err != nil {
		return spec.Descriptor{}, err
	}
	source, repo := u.Hostname(), strings.TrimPrefix(u.Path, "/")
	desc.Annotations[labels.LabelDistributionSource+"."+source] = repo

	p, err := resolver.Pusher(ctx, named.Name())
	if err != nil {
		return spec.Descriptor{}, err
	}
	f, err := resolver.Fetcher(ctx, src)
	if err != nil {
		return spec.Descriptor{}, err
	}

	err = contentutil.CopyChain(ctx,
		contentutil.FromPusher(p),
		contentutil.FromFetcher(f),
		desc,
	)
	return desc, err
}

func authConfigKey(host string) string {
	if host == "registry-1.docker.io" {
		return "https://index.docker.io/v1/"
	}
	return host
}

// DescriptorForComposeFile returns an OCI layer descriptor for one Compose YAML
// file.
func DescriptorForComposeFile(path string, content []byte) spec.Descriptor {
	return spec.Descriptor{
		MediaType: ComposeYAMLMediaType,
		Digest:    digest.FromBytes(content),
		Size:      int64(len(content)),
		Annotations: map[string]string{
			"com.docker.compose.version": composeVersionAnnotation,
			"com.docker.compose.file":    filepath.Base(path),
		},
		Data: content,
	}
}

// DescriptorForEnvFile returns an OCI layer descriptor for one env file.
func DescriptorForEnvFile(path string, content []byte) spec.Descriptor {
	return spec.Descriptor{
		MediaType: ComposeEnvFileMediaType,
		Digest:    digest.FromBytes(content),
		Size:      int64(len(content)),
		Annotations: map[string]string{
			"com.docker.compose.version": composeVersionAnnotation,
			"com.docker.compose.envfile": filepath.Base(path),
		},
		Data: content,
	}
}

// DescriptorForApplicationIndex returns an OCI image index that references
// service image manifests and links back to the Compose project artifact.
func DescriptorForApplicationIndex(subject spec.Descriptor, manifests []spec.Descriptor) (spec.Descriptor, error) {
	subject.Data = nil
	index, err := json.Marshal(spec.Index{
		Versioned: specs.Versioned{SchemaVersion: 2},
		MediaType: spec.MediaTypeImageIndex,
		Manifests: manifests,
		Subject:   &subject,
		Annotations: map[string]string{
			"com.docker.compose.version": composeVersionAnnotation,
		},
	})
	if err != nil {
		return spec.Descriptor{}, err
	}
	return spec.Descriptor{
		MediaType:    spec.MediaTypeImageIndex,
		ArtifactType: ComposeProjectArtifactType,
		Digest:       digest.FromBytes(index),
		Size:         int64(len(index)),
		Annotations: map[string]string{
			"com.docker.compose.version": composeVersionAnnotation,
		},
		Data: index,
	}, nil
}

// PushManifest pushes a Compose project artifact manifest and its layers.
func PushManifest(ctx context.Context, resolver remotes.Resolver, named reference.Named, layers []spec.Descriptor, ociVersion OCIVersion) (spec.Descriptor, error) {
	if ociVersion == OCIVersion1_1 || ociVersion == "" {
		if err := push(ctx, resolver, named, spec.DescriptorEmptyJSON); err != nil {
			return spec.Descriptor{}, err
		}
	}

	layerDescriptors := make([]spec.Descriptor, len(layers))
	for index := range layers {
		layerDescriptors[index] = layers[index]
		if err := push(ctx, resolver, named, layers[index]); err != nil {
			return spec.Descriptor{}, err
		}
	}

	if ociVersion != "" {
		return createAndPushManifest(ctx, resolver, named, layerDescriptors, ociVersion)
	}

	descriptor, err := createAndPushManifest(ctx, resolver, named, layerDescriptors, OCIVersion1_1)
	var pushErr remoteserrors.ErrUnexpectedStatus
	if errors.As(err, &pushErr) && isNonAuthClientError(pushErr.StatusCode) {
		return createAndPushManifest(ctx, resolver, named, layerDescriptors, OCIVersion1_0)
	}
	return descriptor, err
}

// Push writes one descriptor to the registry.
func Push(ctx context.Context, resolver remotes.Resolver, ref reference.Named, descriptor spec.Descriptor) error {
	pusher, err := resolver.Pusher(ctx, ref.String())
	if err != nil {
		return err
	}
	ctx = remotes.WithMediaTypeKeyPrefix(ctx, ComposeYAMLMediaType, "artifact-")
	ctx = remotes.WithMediaTypeKeyPrefix(ctx, ComposeEnvFileMediaType, "artifact-")
	ctx = remotes.WithMediaTypeKeyPrefix(ctx, ComposeEmptyConfigMediaType, "config-")
	ctx = remotes.WithMediaTypeKeyPrefix(ctx, spec.MediaTypeEmptyJSON, "config-")

	push, err := pusher.Push(ctx, descriptor)
	if errdefs.IsAlreadyExists(err) {
		return nil
	}
	if err != nil {
		return err
	}

	if _, err = push.Write(descriptor.Data); err != nil {
		_ = push.Close()
		return err
	}
	return push.Commit(ctx, int64(len(descriptor.Data)), descriptor.Digest)
}

func push(ctx context.Context, resolver remotes.Resolver, ref reference.Named, descriptor spec.Descriptor) error {
	fullRef, err := reference.WithDigest(reference.TagNameOnly(ref), descriptor.Digest)
	if err != nil {
		return err
	}
	return Push(ctx, resolver, fullRef, descriptor)
}

func createAndPushManifest(ctx context.Context, resolver remotes.Resolver, named reference.Named, layers []spec.Descriptor, ociVersion OCIVersion) (spec.Descriptor, error) {
	descriptor, toPush, err := generateManifest(layers, ociVersion)
	if err != nil {
		return spec.Descriptor{}, err
	}
	for _, descriptorToPush := range toPush {
		if err := push(ctx, resolver, named, descriptorToPush); err != nil {
			return spec.Descriptor{}, err
		}
	}
	return descriptor, nil
}

func generateManifest(layers []spec.Descriptor, ociVersion OCIVersion) (spec.Descriptor, []spec.Descriptor, error) {
	var toPush []spec.Descriptor
	var config spec.Descriptor
	var artifactType string
	switch ociVersion {
	case OCIVersion1_0:
		configData := []byte("{}")
		config = spec.Descriptor{
			MediaType: ComposeEmptyConfigMediaType,
			Digest:    digest.FromBytes(configData),
			Size:      int64(len(configData)),
			Data:      configData,
		}
		toPush = append(toPush, config)
	case OCIVersion1_1:
		config = spec.DescriptorEmptyJSON
		artifactType = ComposeProjectArtifactType
		toPush = append(toPush, config)
	default:
		return spec.Descriptor{}, nil, fmt.Errorf("unsupported OCI version: %s", ociVersion)
	}

	manifest, err := json.Marshal(spec.Manifest{
		Versioned:    specs.Versioned{SchemaVersion: 2},
		MediaType:    spec.MediaTypeImageManifest,
		ArtifactType: artifactType,
		Config:       config,
		Layers:       layers,
		Annotations: map[string]string{
			"org.opencontainers.image.created": time.Now().Format(time.RFC3339),
		},
	})
	if err != nil {
		return spec.Descriptor{}, nil, err
	}

	manifestDescriptor := spec.Descriptor{
		MediaType: spec.MediaTypeImageManifest,
		Digest:    digest.FromBytes(manifest),
		Size:      int64(len(manifest)),
		Annotations: map[string]string{
			"com.docker.compose.version": composeVersionAnnotation,
		},
		ArtifactType: artifactType,
		Data:         manifest,
	}
	toPush = append(toPush, manifestDescriptor)
	return manifestDescriptor, toPush, nil
}

func isNonAuthClientError(statusCode int) bool {
	if statusCode < 400 || statusCode >= 500 {
		return false
	}
	return !slices.Contains(clientAuthStatusCodes, statusCode)
}
