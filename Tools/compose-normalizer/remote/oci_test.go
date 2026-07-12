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
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/containerd/containerd/v2/core/remotes"
	"github.com/distribution/reference"
	"github.com/opencontainers/go-digest"
	spec "github.com/opencontainers/image-spec/specs-go/v1"

	composeOCI "github.com/stephenlclarke/container-compose/Tools/compose-normalizer/oci"
)

func TestOCIRemoteLoaderAcceptsOnlyOCIPrefix(t *testing.T) {
	loader := NewOCIRemoteLoader(false)
	if !loader.Accept("oci://registry.example.com/team/app:latest") {
		t.Fatal("OCI loader did not accept oci:// resource")
	}
	if loader.Accept("https://github.com/example/project.git") {
		t.Fatal("OCI loader accepted non-OCI resource")
	}
}

func TestOCIRemoteLoaderDisabledBeforeNetwork(t *testing.T) {
	t.Setenv(OCIRemoteEnabled, "false")
	loader := NewOCIRemoteLoader(false)
	_, err := loader.Load(t.Context(), "oci://registry.example.com/team/app:latest")
	if err == nil {
		t.Fatal("disabled OCI loader succeeded")
	}
	if got, want := err.Error(), `OCI remote resource is disabled by "COMPOSE_EXPERIMENTAL_OCI_REMOTE"`; got != want {
		t.Fatalf("error = %q, want %q", got, want)
	}
}

func TestOCIRemoteLoaderOfflineReturnsNoPath(t *testing.T) {
	loader := NewOCIRemoteLoader(true)
	local, err := loader.Load(t.Context(), "oci://registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("offline load returned error: %v", err)
	}
	if local != "" {
		t.Fatalf("offline load = %q, want empty path", local)
	}
}

func TestOCIRemoteLoaderRemembersMaterializedDirectory(t *testing.T) {
	loader := NewOCIRemoteLoader(false).(*ociRemoteLoader)
	source := "oci://registry.example.com/team/app:latest"
	local := filepath.Join(t.TempDir(), "artifact")

	if got := loader.Dir(source); got != "" {
		t.Fatalf("Dir before remember = %q, want empty", got)
	}
	loader.remember(source, local)
	if got := loader.Dir(source); got != local {
		t.Fatalf("Dir after remember = %q, want %q", got, local)
	}
}

func TestOCIRemoteLoaderMaterializesDirectManifest(t *testing.T) {
	loader := NewOCIRemoteLoader(false).(*ociRemoteLoader)
	local := t.TempDir()
	ref := mustDockerRef(t, "registry.example.com/team/app:latest")
	compose := []byte("services:\n  web:\n    image: nginx\n")
	env := []byte("FROM_OCI=yes\n")
	manifest, resolver := composeManifestFixture(t, compose, env)
	content := mustJSON(t, manifest)
	descriptor := spec.Descriptor{
		MediaType: spec.MediaTypeImageManifest,
		Digest:    digest.FromBytes(content),
		Size:      int64(len(content)),
	}

	if err := loader.materialize(t.Context(), resolver, ref, local, descriptor, content); err != nil {
		t.Fatalf("materialize returned error: %v", err)
	}
	assertFileContent(t, filepath.Join(local, "compose.yaml"), string(compose))
	assertFileContent(t, filepath.Join(local, "project.env"), string(env))
}

func TestOCIRemoteLoaderMaterializesIndexManifest(t *testing.T) {
	loader := NewOCIRemoteLoader(false).(*ociRemoteLoader)
	local := t.TempDir()
	ref := mustDockerRef(t, "registry.example.com/team/app:latest")
	compose := []byte("services:\n  web:\n    image: nginx\n")
	manifest, resolver := composeManifestFixture(t, compose, nil)
	manifestContent := mustJSON(t, manifest)
	manifestDescriptor := spec.Descriptor{
		MediaType:    spec.MediaTypeImageManifest,
		ArtifactType: composeOCI.ComposeProjectArtifactType,
		Digest:       digest.FromBytes(manifestContent),
		Size:         int64(len(manifestContent)),
	}
	resolver.descriptors[manifestDescriptor.Digest] = manifestDescriptor
	resolver.contents[manifestDescriptor.Digest] = manifestContent
	index := spec.Index{Manifests: []spec.Descriptor{manifestDescriptor}}
	indexContent := mustJSON(t, index)
	indexDescriptor := spec.Descriptor{
		MediaType: spec.MediaTypeImageIndex,
		Digest:    digest.FromBytes(indexContent),
		Size:      int64(len(indexContent)),
	}

	if err := loader.materialize(t.Context(), resolver, ref, local, indexDescriptor, indexContent); err != nil {
		t.Fatalf("materialize index returned error: %v", err)
	}
	assertFileContent(t, filepath.Join(local, "compose.yaml"), string(compose))
}

func TestOCIRemoteLoaderRejectsNonComposeManifest(t *testing.T) {
	loader := NewOCIRemoteLoader(false).(*ociRemoteLoader)
	ref := mustDockerRef(t, "registry.example.com/team/app:latest")
	manifest := spec.Manifest{ArtifactType: "application/vnd.example.other"}
	content := mustJSON(t, manifest)
	err := loader.materialize(t.Context(), fakeOCIResolver{}, ref, t.TempDir(), spec.Descriptor{
		MediaType: spec.MediaTypeImageManifest,
		Digest:    digest.FromBytes(content),
		Size:      int64(len(content)),
	}, content)
	if err == nil || !strings.Contains(err.Error(), "is not a compose project OCI artifact") {
		t.Fatalf("materialize error = %v, want non-compose artifact error", err)
	}
}

func TestValidateOCIPathInBase(t *testing.T) {
	base := filepath.Join(t.TempDir(), "compose")
	tests := []struct {
		name       string
		unsafePath string
		wantErr    bool
	}{
		{name: "simple filename", unsafePath: "compose.yaml"},
		{name: "hashed filename", unsafePath: "f8f9ede3d201ec37d5a5e3a77bbadab79af26035e53135e19571f50d541d390c.yaml"},
		{name: "env suffix", unsafePath: ".env.prod"},
		{name: "unix path traversal", unsafePath: "../../../etc/passwd", wantErr: true},
		{name: "windows path traversal", unsafePath: "..\\..\\windows\\system32\\config\\sam", wantErr: true},
		{name: "subdirectory unix", unsafePath: "config/base.yaml", wantErr: true},
		{name: "subdirectory windows", unsafePath: "config\\base.yaml", wantErr: true},
		{name: "absolute unix path", unsafePath: "/etc/passwd", wantErr: true},
		{name: "absolute windows path", unsafePath: "C:\\windows\\system32\\config\\sam", wantErr: true},
		{name: "parent reference only", unsafePath: "..", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateOCIPathInBase(base, tt.unsafePath)
			if (err != nil) != tt.wantErr {
				t.Fatalf("validateOCIPathInBase(%q) error = %v, wantErr %v", tt.unsafePath, err, tt.wantErr)
			}
		})
	}
}

func TestWriteOCIComposeFileRejectsExtendsPathTraversal(t *testing.T) {
	layer := spec.Descriptor{
		MediaType: "application/vnd.docker.compose.file+yaml",
		Digest:    digest.FromString("services:\n  web:\n    image: nginx\n"),
		Size:      33,
		Annotations: map[string]string{
			"com.docker.compose.extends": "true",
			"com.docker.compose.file":    "../other.yaml",
		},
	}

	err := writeOCIComposeFile(layer, 0, t.TempDir(), []byte("services:\n  web:\n    image: nginx\n"))
	if err == nil || err.Error() != "invalid OCI artifact" {
		t.Fatalf("writeOCIComposeFile error = %v, want invalid OCI artifact", err)
	}
}

func TestWriteOCIComposeFileRejectsExtendsWithoutFileAnnotation(t *testing.T) {
	layer := spec.Descriptor{
		MediaType: "application/vnd.docker.compose.file+yaml",
		Digest:    digest.FromString("services:\n  web:\n    image: nginx\n"),
		Size:      33,
		Annotations: map[string]string{
			"com.docker.compose.extends": "true",
		},
	}

	err := writeOCIComposeFile(layer, 0, t.TempDir(), []byte("services:\n  web:\n    image: nginx\n"))
	if err == nil || !strings.Contains(err.Error(), "missing annotation com.docker.compose.file") {
		t.Fatalf("writeOCIComposeFile error = %v, want missing file annotation", err)
	}
}

func TestWriteOCIComposeAndEnvFiles(t *testing.T) {
	dir := t.TempDir()
	first := []byte("services:\n  web:\n    image: nginx\n")
	second := []byte("services:\n  worker:\n    image: busybox\n")

	firstLayer := spec.Descriptor{
		MediaType: "application/vnd.docker.compose.file+yaml",
		Digest:    digest.FromBytes(first),
		Size:      int64(len(first)),
		Annotations: map[string]string{
			"com.docker.compose.file": "compose.yaml",
		},
	}
	secondLayer := spec.Descriptor{
		MediaType: "application/vnd.docker.compose.file+yaml",
		Digest:    digest.FromBytes(second),
		Size:      int64(len(second)),
		Annotations: map[string]string{
			"com.docker.compose.file": "compose.override.yaml",
		},
	}
	envLayer := spec.Descriptor{
		MediaType: "application/vnd.docker.compose.envfile",
		Digest:    digest.FromString("FOO=bar\n"),
		Size:      8,
		Annotations: map[string]string{
			"com.docker.compose.envfile": "hashed.env",
		},
	}

	if err := writeOCIComposeFile(firstLayer, 0, dir, first); err != nil {
		t.Fatalf("write first compose file: %v", err)
	}
	if err := writeOCIComposeFile(secondLayer, 1, dir, second); err != nil {
		t.Fatalf("write second compose file: %v", err)
	}
	if err := writeOCIEnvFile(envLayer, dir, []byte("FOO=bar\n")); err != nil {
		t.Fatalf("write env file: %v", err)
	}

	compose, err := os.ReadFile(filepath.Join(dir, "compose.yaml"))
	if err != nil {
		t.Fatalf("read compose.yaml: %v", err)
	}
	wantCompose := "services:\n  web:\n    image: nginx\n\n---\nservices:\n  worker:\n    image: busybox\n"
	if string(compose) != wantCompose {
		t.Fatalf("compose.yaml = %q, want %q", string(compose), wantCompose)
	}
	env, err := os.ReadFile(filepath.Join(dir, "hashed.env"))
	if err != nil {
		t.Fatalf("read env file: %v", err)
	}
	if string(env) != "FOO=bar\n" {
		t.Fatalf("env = %q, want FOO=bar", string(env))
	}
}

func composeManifestFixture(t *testing.T, compose []byte, env []byte) (spec.Manifest, fakeOCIResolver) {
	t.Helper()
	composeDescriptor := spec.Descriptor{
		MediaType: composeOCI.ComposeYAMLMediaType,
		Digest:    digest.FromBytes(compose),
		Size:      int64(len(compose)),
		Annotations: map[string]string{
			"com.docker.compose.file": "compose.yaml",
		},
	}
	layers := []spec.Descriptor{composeDescriptor}
	resolver := fakeOCIResolver{
		descriptors: map[digest.Digest]spec.Descriptor{
			composeDescriptor.Digest: composeDescriptor,
		},
		contents: map[digest.Digest][]byte{
			composeDescriptor.Digest: compose,
		},
	}
	if env != nil {
		envDescriptor := spec.Descriptor{
			MediaType: composeOCI.ComposeEnvFileMediaType,
			Digest:    digest.FromBytes(env),
			Size:      int64(len(env)),
			Annotations: map[string]string{
				"com.docker.compose.envfile": "project.env",
			},
		}
		layers = append(layers, envDescriptor)
		resolver.descriptors[envDescriptor.Digest] = envDescriptor
		resolver.contents[envDescriptor.Digest] = env
	}
	return spec.Manifest{
		ArtifactType: composeOCI.ComposeProjectArtifactType,
		Layers:       layers,
	}, resolver
}

func mustDockerRef(t *testing.T, value string) reference.Named {
	t.Helper()
	ref, err := reference.ParseDockerRef(value)
	if err != nil {
		t.Fatalf("parse docker ref: %v", err)
	}
	return ref
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	content, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	return content
}

func assertFileContent(t *testing.T, path, want string) {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if string(content) != want {
		t.Fatalf("%s = %q, want %q", path, string(content), want)
	}
}

type fakeOCIResolver struct {
	descriptors map[digest.Digest]spec.Descriptor
	contents    map[digest.Digest][]byte
}

func (resolver fakeOCIResolver) Resolve(_ context.Context, ref string) (string, spec.Descriptor, error) {
	for value, descriptor := range resolver.descriptors {
		if strings.Contains(ref, value.String()) {
			return ref, descriptor, nil
		}
	}
	return "", spec.Descriptor{}, errors.New("descriptor not found")
}

func (resolver fakeOCIResolver) Fetcher(context.Context, string) (remotes.Fetcher, error) {
	return fakeOCIFetcher{contents: resolver.contents}, nil
}

func (fakeOCIResolver) Pusher(context.Context, string) (remotes.Pusher, error) {
	return nil, errors.New("push is not implemented in tests")
}

type fakeOCIFetcher struct {
	contents map[digest.Digest][]byte
}

func (fetcher fakeOCIFetcher) Fetch(_ context.Context, descriptor spec.Descriptor) (io.ReadCloser, error) {
	content, ok := fetcher.contents[descriptor.Digest]
	if !ok {
		return nil, errors.New("content not found")
	}
	return io.NopCloser(strings.NewReader(string(content))), nil
}
