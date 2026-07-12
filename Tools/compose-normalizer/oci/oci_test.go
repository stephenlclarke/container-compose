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

package oci

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/containerd/containerd/v2/core/content"
	"github.com/containerd/containerd/v2/core/remotes"
	remoteserrors "github.com/containerd/containerd/v2/core/remotes/errors"
	"github.com/containerd/containerd/v2/pkg/labels"
	"github.com/containerd/errdefs"
	"github.com/distribution/reference"
	"github.com/docker/cli/cli/config/configfile"
	"github.com/opencontainers/go-digest"
	spec "github.com/opencontainers/image-spec/specs-go/v1"
)

type recordingRoundTripper struct {
	delegate  http.RoundTripper
	calls     atomic.Int32
	authCalls atomic.Int32
}

func (r *recordingRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	r.calls.Add(1)
	if strings.HasSuffix(req.URL.Path, "/token") {
		r.authCalls.Add(1)
	}
	return r.delegate.RoundTrip(req)
}

func TestNewResolverUsesProvidedTransport(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	t.Cleanup(server.Close)

	host := server.Listener.Addr().String()
	recorder := &recordingRoundTripper{delegate: &http.Transport{}}
	resolver := NewResolver(&configfile.ConfigFile{}, recorder, host)

	_, _, _ = resolver.Resolve(t.Context(), host+"/test/image:latest")
	if recorder.calls.Load() == 0 {
		t.Fatal("resolver did not invoke the supplied transport")
	}
}

func TestNewResolverAuthorizerUsesProvidedTransport(t *testing.T) {
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if strings.HasSuffix(req.URL.Path, "/token") {
			_, _ = w.Write([]byte(`{"token":"fake","access_token":"fake","expires_in":300}`))
			return
		}
		if req.Header.Get("Authorization") == "" {
			w.Header().Set("Www-Authenticate", `Bearer realm="`+server.URL+`/token",service="test"`)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(server.Close)

	host := server.Listener.Addr().String()
	recorder := &recordingRoundTripper{delegate: &http.Transport{}}
	resolver := NewResolver(&configfile.ConfigFile{}, recorder, host)

	_, _, _ = resolver.Resolve(t.Context(), host+"/test/image:latest")
	if recorder.authCalls.Load() == 0 {
		t.Fatal("authorizer token fetch did not go through the supplied transport")
	}
}

func TestNewResolverNilTransportIsValid(t *testing.T) {
	if resolver := NewResolver(&configfile.ConfigFile{}, nil); resolver == nil {
		t.Fatal("NewResolver returned nil")
	}
}

func TestGetFetchesResolvedDescriptorContent(t *testing.T) {
	payload := []byte(`{"schemaVersion":2}`)
	descriptor := spec.Descriptor{
		MediaType: "application/vnd.oci.image.manifest.v1+json",
		Digest:    digest.FromBytes(payload),
		Size:      int64(len(payload)),
	}
	resolver := fakeResolver{
		descriptor: descriptor,
		content:    payload,
	}

	ref, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("parse ref: %v", err)
	}
	gotDescriptor, gotPayload, err := Get(t.Context(), resolver, ref)
	if err != nil {
		t.Fatalf("Get returned error: %v", err)
	}
	if gotDescriptor.Digest != descriptor.Digest {
		t.Fatalf("descriptor digest = %s, want %s", gotDescriptor.Digest, descriptor.Digest)
	}
	if string(gotPayload) != string(payload) {
		t.Fatalf("payload = %q, want %q", string(gotPayload), string(payload))
	}
}

func TestGetReturnsResolveError(t *testing.T) {
	ref, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("parse ref: %v", err)
	}
	wantErr := errors.New("resolve failed")
	_, _, err = Get(t.Context(), fakeResolver{resolveErr: wantErr}, ref)
	if !errors.Is(err, wantErr) {
		t.Fatalf("Get error = %v, want %v", err, wantErr)
	}
}

func TestCopyAnnotatesDistributionSourceAndCopiesChain(t *testing.T) {
	payload := []byte("layer")
	descriptor := spec.Descriptor{
		MediaType: spec.MediaTypeImageLayer,
		Digest:    digest.FromBytes(payload),
		Size:      int64(len(payload)),
	}
	pusher := &recordingPusher{}
	var refs []string
	resolver := fakeResolver{
		descriptor: descriptor,
		content:    payload,
		pusher:     pusher,
		pusherRefs: &refs,
	}
	image, err := reference.ParseDockerRef("docker.io/library/alpine:latest")
	if err != nil {
		t.Fatalf("parse image ref: %v", err)
	}
	target, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("parse target ref: %v", err)
	}

	got, err := Copy(t.Context(), resolver, image, target)
	if err != nil {
		t.Fatalf("Copy returned error: %v", err)
	}
	if got.Digest != descriptor.Digest {
		t.Fatalf("copied descriptor digest = %s, want %s", got.Digest, descriptor.Digest)
	}
	sourceKey := labels.LabelDistributionSource + ".docker.io"
	if got.Annotations[sourceKey] != "library/alpine" {
		t.Fatalf("distribution source annotation = %q, want library/alpine", got.Annotations[sourceKey])
	}
	if len(refs) != 1 || refs[0] != "registry.example.com/team/app" {
		t.Fatalf("pusher refs = %#v, want target repository name", refs)
	}
	if len(pusher.writers) != 1 || string(pusher.writers[0].data) != string(payload) {
		t.Fatalf("copied writer payload = %#v, want %q", pusher.writers, string(payload))
	}
}

func TestAuthConfigKeyMapsDockerHub(t *testing.T) {
	if got, want := authConfigKey("registry-1.docker.io"), "https://index.docker.io/v1/"; got != want {
		t.Fatalf("authConfigKey(registry-1.docker.io) = %q, want %q", got, want)
	}
	if got, want := authConfigKey("registry.example.com"), "registry.example.com"; got != want {
		t.Fatalf("authConfigKey(registry.example.com) = %q, want %q", got, want)
	}
}

func TestDescriptorForComposeFile(t *testing.T) {
	content := []byte("services:\n  api:\n    image: alpine\n")
	descriptor := DescriptorForComposeFile("/tmp/project/compose.yml", content)

	if descriptor.MediaType != ComposeYAMLMediaType {
		t.Fatalf("media type = %q, want %q", descriptor.MediaType, ComposeYAMLMediaType)
	}
	if descriptor.Digest != digest.FromBytes(content) {
		t.Fatalf("digest = %s, want %s", descriptor.Digest, digest.FromBytes(content))
	}
	if descriptor.Size != int64(len(content)) {
		t.Fatalf("size = %d, want %d", descriptor.Size, len(content))
	}
	if string(descriptor.Data) != string(content) {
		t.Fatalf("data = %q, want %q", string(descriptor.Data), string(content))
	}
	if got := descriptor.Annotations["com.docker.compose.file"]; got != "compose.yml" {
		t.Fatalf("compose file annotation = %q, want compose.yml", got)
	}
	if got := descriptor.Annotations["com.docker.compose.version"]; got != composeVersionAnnotation {
		t.Fatalf("compose version annotation = %q, want %q", got, composeVersionAnnotation)
	}
}

func TestDescriptorForEnvFile(t *testing.T) {
	content := []byte("FOO=bar\n")
	descriptor := DescriptorForEnvFile("/tmp/project/.env.prod", content)

	if descriptor.MediaType != ComposeEnvFileMediaType {
		t.Fatalf("media type = %q, want %q", descriptor.MediaType, ComposeEnvFileMediaType)
	}
	if descriptor.Digest != digest.FromBytes(content) {
		t.Fatalf("digest = %s, want %s", descriptor.Digest, digest.FromBytes(content))
	}
	if descriptor.Size != int64(len(content)) {
		t.Fatalf("size = %d, want %d", descriptor.Size, len(content))
	}
	if string(descriptor.Data) != string(content) {
		t.Fatalf("data = %q, want %q", string(descriptor.Data), string(content))
	}
	if got := descriptor.Annotations["com.docker.compose.envfile"]; got != ".env.prod" {
		t.Fatalf("env file annotation = %q, want .env.prod", got)
	}
}

func TestGenerateManifestOCI11(t *testing.T) {
	layer := DescriptorForComposeFile("compose.yml", []byte("services: {}\n"))
	descriptor, toPush, err := generateManifest([]spec.Descriptor{layer}, OCIVersion1_1)
	if err != nil {
		t.Fatalf("generateManifest returned error: %v", err)
	}

	if descriptor.MediaType != spec.MediaTypeImageManifest {
		t.Fatalf("manifest descriptor media type = %q, want %q", descriptor.MediaType, spec.MediaTypeImageManifest)
	}
	if descriptor.ArtifactType != ComposeProjectArtifactType {
		t.Fatalf("manifest descriptor artifact type = %q, want %q", descriptor.ArtifactType, ComposeProjectArtifactType)
	}
	if len(toPush) != 2 {
		t.Fatalf("toPush length = %d, want 2", len(toPush))
	}
	if toPush[0].MediaType != spec.DescriptorEmptyJSON.MediaType ||
		toPush[0].Digest != spec.DescriptorEmptyJSON.Digest ||
		toPush[0].Size != spec.DescriptorEmptyJSON.Size {
		t.Fatalf("first descriptor = %#v, want DescriptorEmptyJSON", toPush[0])
	}

	var manifest spec.Manifest
	if err := json.Unmarshal(descriptor.Data, &manifest); err != nil {
		t.Fatalf("manifest JSON did not decode: %v", err)
	}
	if manifest.SchemaVersion != 2 {
		t.Fatalf("schema version = %d, want 2", manifest.SchemaVersion)
	}
	if manifest.ArtifactType != ComposeProjectArtifactType {
		t.Fatalf("manifest artifact type = %q, want %q", manifest.ArtifactType, ComposeProjectArtifactType)
	}
	if len(manifest.Layers) != 1 || manifest.Layers[0].Digest != layer.Digest {
		t.Fatalf("manifest layers = %#v, want compose layer digest %s", manifest.Layers, layer.Digest)
	}
	if manifest.Annotations["org.opencontainers.image.created"] == "" {
		t.Fatal("manifest does not include creation annotation")
	}
}

func TestGenerateManifestOCI10(t *testing.T) {
	layer := DescriptorForComposeFile("compose.yml", []byte("services: {}\n"))
	descriptor, toPush, err := generateManifest([]spec.Descriptor{layer}, OCIVersion1_0)
	if err != nil {
		t.Fatalf("generateManifest returned error: %v", err)
	}

	if descriptor.ArtifactType != "" {
		t.Fatalf("manifest descriptor artifact type = %q, want empty for OCI 1.0", descriptor.ArtifactType)
	}
	if len(toPush) != 2 {
		t.Fatalf("toPush length = %d, want 2", len(toPush))
	}
	if toPush[0].MediaType != ComposeEmptyConfigMediaType {
		t.Fatalf("config media type = %q, want %q", toPush[0].MediaType, ComposeEmptyConfigMediaType)
	}

	var manifest spec.Manifest
	if err := json.Unmarshal(descriptor.Data, &manifest); err != nil {
		t.Fatalf("manifest JSON did not decode: %v", err)
	}
	if manifest.ArtifactType != "" {
		t.Fatalf("manifest artifact type = %q, want empty for OCI 1.0", manifest.ArtifactType)
	}
	if manifest.Config.MediaType != ComposeEmptyConfigMediaType {
		t.Fatalf("manifest config media type = %q, want %q", manifest.Config.MediaType, ComposeEmptyConfigMediaType)
	}
}

func TestGenerateManifestRejectsUnsupportedVersion(t *testing.T) {
	_, _, err := generateManifest(nil, OCIVersion("9.9"))
	if err == nil {
		t.Fatal("generateManifest returned nil error for unsupported OCI version")
	}
	if !strings.Contains(err.Error(), "unsupported OCI version: 9.9") {
		t.Fatalf("error = %v, want unsupported OCI version", err)
	}
}

func TestPushWritesDescriptorData(t *testing.T) {
	pusher := &recordingPusher{}
	ref, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("parse ref: %v", err)
	}
	descriptor := DescriptorForComposeFile("compose.yml", []byte("services: {}\n"))

	err = Push(t.Context(), fakeResolver{pusher: pusher}, ref, descriptor)
	if err != nil {
		t.Fatalf("Push returned error: %v", err)
	}
	if len(pusher.writers) != 1 {
		t.Fatalf("writer count = %d, want 1", len(pusher.writers))
	}
	writer := pusher.writers[0]
	if got := string(writer.data); got != string(descriptor.Data) {
		t.Fatalf("pushed data = %q, want %q", got, string(descriptor.Data))
	}
	if writer.committedSize != descriptor.Size {
		t.Fatalf("committed size = %d, want %d", writer.committedSize, descriptor.Size)
	}
	if writer.committedDigest != descriptor.Digest {
		t.Fatalf("committed digest = %s, want %s", writer.committedDigest, descriptor.Digest)
	}
}

func TestPushIgnoresAlreadyExists(t *testing.T) {
	ref, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("parse ref: %v", err)
	}
	err = Push(t.Context(), fakeResolver{pusher: &recordingPusher{err: errdefs.ErrAlreadyExists}}, ref, DescriptorForComposeFile("compose.yml", []byte("services: {}\n")))
	if err != nil {
		t.Fatalf("Push returned error for already-exists descriptor: %v", err)
	}
}

func TestPushManifestPushesOCI11LayersAndManifest(t *testing.T) {
	ref, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("parse ref: %v", err)
	}
	layer := DescriptorForComposeFile("compose.yml", []byte("services: {}\n"))
	pusher := &recordingPusher{}
	var refs []string

	descriptor, err := PushManifest(t.Context(), fakeResolver{pusher: pusher, pusherRefs: &refs}, ref, []spec.Descriptor{layer}, OCIVersion1_1)
	if err != nil {
		t.Fatalf("PushManifest returned error: %v", err)
	}
	if descriptor.ArtifactType != ComposeProjectArtifactType {
		t.Fatalf("artifact type = %q, want %q", descriptor.ArtifactType, ComposeProjectArtifactType)
	}
	if len(pusher.descriptors) != 4 {
		t.Fatalf("pushed descriptors = %d, want config, layer, config, manifest", len(pusher.descriptors))
	}
	if pusher.descriptors[1].Digest != layer.Digest {
		t.Fatalf("second descriptor digest = %s, want layer digest %s", pusher.descriptors[1].Digest, layer.Digest)
	}
	if pusher.descriptors[len(pusher.descriptors)-1].MediaType != spec.MediaTypeImageManifest {
		t.Fatalf("last pushed media type = %q, want manifest", pusher.descriptors[len(pusher.descriptors)-1].MediaType)
	}
	for _, pushedRef := range refs {
		if !strings.Contains(pushedRef, "@sha256:") {
			t.Fatalf("pushed ref %q does not use a digest reference", pushedRef)
		}
	}
}

func TestPushManifestAutoFallsBackToOCI10OnClientErrors(t *testing.T) {
	ref, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("parse ref: %v", err)
	}
	layer := DescriptorForComposeFile("compose.yml", []byte("services: {}\n"))
	pusher := &recordingPusher{
		errors: []error{
			nil,
			nil,
			nil,
			remoteserrors.ErrUnexpectedStatus{StatusCode: http.StatusBadRequest},
			nil,
			nil,
		},
	}

	descriptor, err := PushManifest(t.Context(), fakeResolver{pusher: pusher}, ref, []spec.Descriptor{layer}, "")
	if err != nil {
		t.Fatalf("PushManifest returned error: %v", err)
	}
	if descriptor.ArtifactType != "" {
		t.Fatalf("fallback artifact type = %q, want OCI 1.0 image-manifest fallback", descriptor.ArtifactType)
	}
	if pusher.descriptors[len(pusher.descriptors)-1].Digest != descriptor.Digest {
		t.Fatalf("last pushed descriptor digest = %s, want returned manifest %s", pusher.descriptors[len(pusher.descriptors)-1].Digest, descriptor.Digest)
	}
}

func TestPushManifestDoesNotFallbackOnAuthClientErrors(t *testing.T) {
	ref, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("parse ref: %v", err)
	}
	pusher := &recordingPusher{
		errors: []error{
			nil,
			nil,
			remoteserrors.ErrUnexpectedStatus{StatusCode: http.StatusUnauthorized},
		},
	}

	_, err = PushManifest(t.Context(), fakeResolver{pusher: pusher}, ref, nil, "")
	if err == nil {
		t.Fatal("PushManifest returned nil error for auth client failure")
	}
	if len(pusher.descriptors) != 3 {
		t.Fatalf("pushed descriptors = %d, want no fallback after auth failure", len(pusher.descriptors))
	}
}

func TestIsNonAuthClientError(t *testing.T) {
	tests := []struct {
		status int
		want   bool
	}{
		{status: http.StatusBadRequest, want: true},
		{status: http.StatusUnauthorized, want: false},
		{status: http.StatusForbidden, want: false},
		{status: http.StatusProxyAuthRequired, want: false},
		{status: http.StatusInternalServerError, want: false},
	}
	for _, test := range tests {
		if got := isNonAuthClientError(test.status); got != test.want {
			t.Fatalf("isNonAuthClientError(%d) = %v, want %v", test.status, got, test.want)
		}
	}
}

type fakeResolver struct {
	descriptor spec.Descriptor
	content    []byte
	resolveErr error
	fetcherErr error
	fetchErr   error
	pusher     remotes.Pusher
	pusherErr  error
	pusherRefs *[]string
}

func (resolver fakeResolver) Resolve(context.Context, string) (string, spec.Descriptor, error) {
	if resolver.resolveErr != nil {
		return "", spec.Descriptor{}, resolver.resolveErr
	}
	return "registry.example.com/team/app:latest", resolver.descriptor, nil
}

func (resolver fakeResolver) Fetcher(context.Context, string) (remotes.Fetcher, error) {
	if resolver.fetcherErr != nil {
		return nil, resolver.fetcherErr
	}
	return fakeFetcher{content: resolver.content, err: resolver.fetchErr}, nil
}

func (resolver fakeResolver) Pusher(_ context.Context, ref string) (remotes.Pusher, error) {
	if resolver.pusherErr != nil {
		return nil, resolver.pusherErr
	}
	if resolver.pusherRefs != nil {
		*resolver.pusherRefs = append(*resolver.pusherRefs, ref)
	}
	if resolver.pusher != nil {
		return resolver.pusher, nil
	}
	return nil, errors.New("push is not implemented in tests")
}

type fakeFetcher struct {
	content []byte
	err     error
}

func (fetcher fakeFetcher) Fetch(context.Context, spec.Descriptor) (io.ReadCloser, error) {
	if fetcher.err != nil {
		return nil, fetcher.err
	}
	return io.NopCloser(strings.NewReader(string(fetcher.content))), nil
}

type recordingPusher struct {
	err         error
	errors      []error
	descriptors []spec.Descriptor
	writers     []*recordingWriter
}

func (pusher *recordingPusher) Push(_ context.Context, descriptor spec.Descriptor) (content.Writer, error) {
	pusher.descriptors = append(pusher.descriptors, descriptor)
	if len(pusher.errors) > 0 {
		err := pusher.errors[0]
		pusher.errors = pusher.errors[1:]
		if err != nil {
			return nil, err
		}
	}
	if pusher.err != nil {
		return nil, pusher.err
	}
	writer := &recordingWriter{}
	pusher.writers = append(pusher.writers, writer)
	return writer, nil
}

type recordingWriter struct {
	data            []byte
	closed          bool
	committedSize   int64
	committedDigest digest.Digest
}

func (writer *recordingWriter) Write(data []byte) (int, error) {
	writer.data = append(writer.data, data...)
	return len(data), nil
}

func (writer *recordingWriter) Close() error {
	writer.closed = true
	return nil
}

func (writer *recordingWriter) Digest() digest.Digest {
	return digest.FromBytes(writer.data)
}

func (writer *recordingWriter) Commit(_ context.Context, size int64, expected digest.Digest, _ ...content.Opt) error {
	writer.closed = true
	writer.committedSize = size
	writer.committedDigest = expected
	return nil
}

func (writer *recordingWriter) Status() (content.Status, error) {
	return content.Status{Offset: int64(len(writer.data))}, nil
}

func (writer *recordingWriter) Truncate(size int64) error {
	writer.data = writer.data[:int(size)]
	return nil
}
