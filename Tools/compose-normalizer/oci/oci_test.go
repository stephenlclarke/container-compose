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
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/containerd/containerd/v2/core/remotes"
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

func TestAuthConfigKeyMapsDockerHub(t *testing.T) {
	if got, want := authConfigKey("registry-1.docker.io"), "https://index.docker.io/v1/"; got != want {
		t.Fatalf("authConfigKey(registry-1.docker.io) = %q, want %q", got, want)
	}
	if got, want := authConfigKey("registry.example.com"), "registry.example.com"; got != want {
		t.Fatalf("authConfigKey(registry.example.com) = %q, want %q", got, want)
	}
}

type fakeResolver struct {
	descriptor spec.Descriptor
	content    []byte
	resolveErr error
	fetcherErr error
	fetchErr   error
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

func (fakeResolver) Pusher(context.Context, string) (remotes.Pusher, error) {
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
