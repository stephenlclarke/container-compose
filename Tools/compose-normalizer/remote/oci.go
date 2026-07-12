/*
   Copyright 2020 Docker Compose CLI authors

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

package remote

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/compose-spec/compose-go/v2/loader"
	"github.com/containerd/containerd/v2/core/images"
	"github.com/containerd/containerd/v2/core/remotes"
	"github.com/distribution/reference"
	"github.com/docker/cli/cli/config"
	spec "github.com/opencontainers/image-spec/specs-go/v1"

	composeOCI "github.com/stephenlclarke/container-compose/Tools/compose-normalizer/oci"
)

const (
	OCIRemoteEnabled = "COMPOSE_EXPERIMENTAL_OCI_REMOTE"
	OCIPrefix        = "oci://"
)

func ociRemoteLoaderEnabled() (bool, error) {
	if value := os.Getenv(OCIRemoteEnabled); value != "" {
		enabled, err := strconv.ParseBool(value)
		if err != nil {
			return false, fmt.Errorf("%s environment variable expects boolean value: %w", OCIRemoteEnabled, err)
		}
		return enabled, nil
	}
	return true, nil
}

// NewOCIRemoteLoader returns a compose-go resource loader for Docker Compose
// OCI project artifacts.
func NewOCIRemoteLoader(offline bool) loader.ResourceLoader {
	return &ociRemoteLoader{
		offline: offline,
		known:   map[string]string{},
	}
}

type ociRemoteLoader struct {
	offline bool
	known   map[string]string
	mu      sync.RWMutex
}

func (loader *ociRemoteLoader) Accept(path string) bool {
	return strings.HasPrefix(path, OCIPrefix)
}

func (loader *ociRemoteLoader) Load(ctx context.Context, path string) (string, error) {
	enabled, err := ociRemoteLoaderEnabled()
	if err != nil {
		return "", err
	}
	if !enabled {
		return "", fmt.Errorf("OCI remote resource is disabled by %q", OCIRemoteEnabled)
	}
	if loader.offline {
		return "", nil
	}

	if local, ok := loader.knownPath(path); ok {
		return filepath.Join(local, "compose.yaml"), nil
	}

	ref, err := reference.ParseDockerRef(path[len(OCIPrefix):])
	if err != nil {
		return "", err
	}

	resolver := composeOCI.NewResolver(config.LoadDefaultConfigFile(io.Discard), loader.httpTransport(ctx))
	descriptor, content, err := composeOCI.Get(ctx, resolver, ref)
	if err != nil {
		return "", fmt.Errorf("failed to pull OCI resource %q: %w", ref, err)
	}

	cache, err := cacheDir()
	if err != nil {
		return "", fmt.Errorf("initializing remote resource cache: %w", err)
	}
	local := filepath.Join(cache, descriptor.Digest.Hex())
	if _, err = os.Stat(local); os.IsNotExist(err) {
		if err := loader.materialize(ctx, resolver, ref, local, descriptor, content); err != nil {
			_ = os.RemoveAll(local)
			return "", err
		}
	}
	loader.remember(path, local)
	return filepath.Join(local, "compose.yaml"), nil
}

func (loader *ociRemoteLoader) Dir(path string) string {
	if directory, ok := loader.knownPath(path); ok {
		return directory
	}
	return ""
}

func (loader *ociRemoteLoader) knownPath(path string) (string, bool) {
	loader.mu.RLock()
	defer loader.mu.RUnlock()
	local, ok := loader.known[path]
	return local, ok
}

func (loader *ociRemoteLoader) remember(path, local string) {
	loader.mu.Lock()
	defer loader.mu.Unlock()
	loader.known[path] = local
}

func (loader *ociRemoteLoader) httpTransport(context.Context) http.RoundTripper {
	return nil
}

func (loader *ociRemoteLoader) materialize(
	ctx context.Context,
	resolver remotes.Resolver,
	ref reference.Named,
	local string,
	descriptor spec.Descriptor,
	content []byte,
) error {
	if images.IsIndexType(descriptor.MediaType) {
		resolvedContent, err := resolveComposeArtifactFromIndex(ctx, resolver, ref, content)
		if err != nil {
			return err
		}
		content = resolvedContent
	}

	var manifest spec.Manifest
	if err := json.Unmarshal(content, &manifest); err != nil {
		return err
	}
	if (manifest.ArtifactType != "" && manifest.ArtifactType != composeOCI.ComposeProjectArtifactType) ||
		(manifest.ArtifactType == "" && manifest.Config.MediaType != composeOCI.ComposeEmptyConfigMediaType) {
		return fmt.Errorf("%s is not a compose project OCI artifact, but %s", ref.String(), manifest.ArtifactType)
	}
	return loader.pullComposeFiles(ctx, local, manifest, ref, resolver)
}

func resolveComposeArtifactFromIndex(
	ctx context.Context,
	resolver remotes.Resolver,
	ref reference.Named,
	content []byte,
) ([]byte, error) {
	var index spec.Index
	if err := json.Unmarshal(content, &index); err != nil {
		return nil, err
	}
	for _, manifest := range index.Manifests {
		if manifest.ArtifactType != composeOCI.ComposeProjectArtifactType {
			continue
		}
		digested, err := reference.WithDigest(ref, manifest.Digest)
		if err != nil {
			return nil, err
		}
		_, pulled, err := composeOCI.Get(ctx, resolver, digested)
		if err != nil {
			return nil, fmt.Errorf("failed to pull OCI resource %q: %w", ref, err)
		}
		return pulled, nil
	}
	return nil, fmt.Errorf("OCI index %s doesn't refer to compose artifacts", ref)
}

func (loader *ociRemoteLoader) pullComposeFiles(
	ctx context.Context,
	local string,
	manifest spec.Manifest,
	ref reference.Named,
	resolver remotes.Resolver,
) error {
	if err := os.MkdirAll(local, 0o700); err != nil {
		return err
	}

	for index, layer := range manifest.Layers {
		digested, err := reference.WithDigest(ref, layer.Digest)
		if err != nil {
			return err
		}
		_, content, err := composeOCI.Get(ctx, resolver, digested)
		if err != nil {
			return err
		}

		switch layer.MediaType {
		case composeOCI.ComposeYAMLMediaType:
			if err := writeOCIComposeFile(layer, index, local, content); err != nil {
				return err
			}
		case composeOCI.ComposeEnvFileMediaType:
			if err := writeOCIEnvFile(layer, local, content); err != nil {
				return err
			}
		case composeOCI.ComposeEmptyConfigMediaType:
		}
	}
	return nil
}

func validateOCIPathInBase(base, unsafePath string) error {
	if strings.ContainsAny(unsafePath, "\\/") {
		return fmt.Errorf("invalid OCI artifact")
	}

	targetPath := filepath.Join(base, unsafePath)
	targetDir := filepath.Dir(targetPath)
	cleanBase := filepath.Clean(base)
	cleanTargetDir := filepath.Clean(targetDir)
	if cleanTargetDir != cleanBase {
		return fmt.Errorf("invalid OCI artifact")
	}
	return nil
}

func writeOCIComposeFile(layer spec.Descriptor, index int, local string, content []byte) error {
	file := "compose.yaml"
	if _, ok := layer.Annotations["com.docker.compose.extends"]; ok {
		file = layer.Annotations["com.docker.compose.file"]
		if file == "" {
			return fmt.Errorf("missing annotation com.docker.compose.file in layer %q", layer.Digest)
		}
		if err := validateOCIPathInBase(local, file); err != nil {
			return err
		}
	}
	f, err := os.OpenFile(filepath.Join(local, file), os.O_RDWR|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	if _, ok := layer.Annotations["com.docker.compose.file"]; index > 0 && ok {
		if _, err := f.Write([]byte("\n---\n")); err != nil {
			return err
		}
	}
	_, err = f.Write(content)
	return err
}

func writeOCIEnvFile(layer spec.Descriptor, local string, content []byte) error {
	envfilePath, ok := layer.Annotations["com.docker.compose.envfile"]
	if !ok {
		return fmt.Errorf("missing annotation com.docker.compose.envfile in layer %q", layer.Digest)
	}
	if err := validateOCIPathInBase(local, envfilePath); err != nil {
		return err
	}
	otherFile, err := os.Create(filepath.Join(local, envfilePath))
	if err != nil {
		return err
	}
	defer func() { _ = otherFile.Close() }()
	_, err = otherFile.Write(content)
	return err
}

var _ loader.ResourceLoader = (*ociRemoteLoader)(nil)
