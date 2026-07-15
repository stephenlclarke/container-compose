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

package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/compose-spec/compose-go/v2/types"
	"github.com/containerd/containerd/v2/core/content"
	"github.com/containerd/containerd/v2/core/remotes"
	"github.com/distribution/reference"
	digest "github.com/opencontainers/go-digest"
	spec "github.com/opencontainers/image-spec/specs-go/v1"
	composeOCI "github.com/stephenlclarke/container-compose/Tools/compose-normalizer/oci"
)

func TestPublishDryRunAcceptsShortFormPortMappings(t *testing.T) {
	dir := t.TempDir()
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  whoami:
    image: docker.io/traefik/whoami:v1.11
    ports:
      - ${DASHBOARD_PORT:-3000}:3000
`)

	result, err := publishComposeProject(
		publishRequestForTest([]string{composeFile}, nil, "publish-short-ports", dir),
		publishOptions{
			repository: "registry.example.com/team/app:latest",
			dryRun:     true,
		},
		io.Discard,
	)
	if err != nil {
		t.Fatalf("publishComposeProject returned error: %v", err)
	}
	if result.Repository != "registry.example.com/team/app:latest" {
		t.Fatalf("repository = %q", result.Repository)
	}
	if len(result.Layers) != 1 {
		t.Fatalf("layers = %#v, want one compose layer", result.Layers)
	}
	layer := result.Layers[0]
	if layer.Kind != "compose" || layer.MediaType != composeOCI.ComposeYAMLMediaType {
		t.Fatalf("layer = %#v, want compose OCI layer", layer)
	}
}

func TestPublishDryRunIncludesEnvLayersWithWithEnv(t *testing.T) {
	dir := t.TempDir()
	envFile := writePublishFixture(t, dir, ".env", "TOKEN=from-file\n")
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    image: alpine
    env_file:
      - .env
`)

	result, err := publishComposeProject(
		publishRequestForTest([]string{composeFile}, []string{envFile}, "publish-env", dir),
		publishOptions{
			repository: "registry.example.com/team/app:latest",
			withEnv:    true,
			dryRun:     true,
		},
		io.Discard,
	)
	if err != nil {
		t.Fatalf("publishComposeProject returned error: %v", err)
	}
	if len(result.Layers) != 2 {
		t.Fatalf("layers = %#v, want compose and env layers", result.Layers)
	}
	if result.Layers[1].Kind != "env" || !strings.HasSuffix(result.Layers[1].Path, ".env") {
		t.Fatalf("env layer = %#v", result.Layers[1])
	}
}

func TestPublishDryRunIncludesExtendsLayers(t *testing.T) {
	dir := t.TempDir()
	_ = writePublishFixture(t, dir, "base.yaml", `
services:
  base:
    image: alpine
`)
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    extends:
      file: base.yaml
      service: base
`)

	result, err := publishComposeProject(
		publishRequestForTest([]string{composeFile}, nil, "publish-extends", dir),
		publishOptions{
			repository: "registry.example.com/team/app:latest",
			dryRun:     true,
		},
		io.Discard,
	)
	if err != nil {
		t.Fatalf("publishComposeProject returned error: %v", err)
	}
	var hasExtends bool
	for _, layer := range result.Layers {
		if layer.Kind == "extends" && layer.MediaType == composeOCI.ComposeYAMLMediaType {
			hasExtends = true
		}
	}
	if !hasExtends {
		t.Fatalf("layers = %#v, want an extends layer", result.Layers)
	}
}

func TestPublishDryRunIncludesImageDigestOverrideLayer(t *testing.T) {
	dir := t.TempDir()
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    image: registry.example.com/team/api
  pinned:
    image: registry.example.com/team/pinned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  worker:
    image: registry.example.com/team/worker:2
`)
	var (
		requestsMu sync.Mutex
		requests   []string
	)
	digests := map[string]digest.Digest{
		"registry.example.com/team/api:latest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"registry.example.com/team/worker:2":   "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
	}

	result, err := publishComposeProject(
		publishRequestForTest([]string{composeFile}, nil, "publish-digests", dir),
		publishOptions{
			repository:          "registry.example.com/team/app:latest",
			resolveImageDigests: true,
			dryRun:              true,
			imageDigestResolver: func(named reference.Named) (digest.Digest, error) {
				requestsMu.Lock()
				defer requestsMu.Unlock()
				requests = append(requests, named.String())
				return digests[named.String()], nil
			},
		},
		io.Discard,
	)
	if err != nil {
		t.Fatalf("publishComposeProject returned error: %v", err)
	}
	requestsMu.Lock()
	requestsSnapshot := slices.Clone(requests)
	requestsMu.Unlock()
	slices.Sort(requestsSnapshot)
	if len(requestsSnapshot) != 2 || requestsSnapshot[0] != "registry.example.com/team/api:latest" || requestsSnapshot[1] != "registry.example.com/team/worker:2" {
		t.Fatalf("digest resolver requests = %#v", requestsSnapshot)
	}
	layer := result.Layers[len(result.Layers)-1]
	if layer.Kind != "compose" || layer.Path != "image-digests.yaml" {
		t.Fatalf("digest layer = %#v, want compose image-digests.yaml", layer)
	}

	layers, err := createPublishLayers(t.Context(), mustPublishProject(t, []string{composeFile}, dir), publishOptions{
		resolveImageDigests: true,
		imageDigestResolver: func(named reference.Named) (digest.Digest, error) {
			return digests[named.String()], nil
		},
	})
	if err != nil {
		t.Fatalf("createPublishLayers returned error: %v", err)
	}
	got := string(layers[len(layers)-1].Data)
	for _, want := range []string{
		`image: registry.example.com/team/api:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`,
		`image: registry.example.com/team/pinned@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc`,
		`image: registry.example.com/team/worker:2@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("digest override YAML =\n%s\nmissing %q", got, want)
		}
	}
}

func TestPublishAppDryRunIncludesImageDigestOverrideLayer(t *testing.T) {
	dir := t.TempDir()
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    image: registry.example.com/team/api
`)
	var requests []string

	result, err := publishComposeProject(
		publishRequestForTest([]string{composeFile}, nil, "publish-app", dir),
		publishOptions{
			repository: "registry.example.com/team/app:latest",
			app:        true,
			dryRun:     true,
			imageDigestResolver: func(named reference.Named) (digest.Digest, error) {
				requests = append(requests, named.String())
				return "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nil
			},
		},
		io.Discard,
	)
	if err != nil {
		t.Fatalf("publishComposeProject returned error: %v", err)
	}
	if len(requests) != 1 || requests[0] != "registry.example.com/team/api:latest" {
		t.Fatalf("digest resolver requests = %#v", requests)
	}
	layer := result.Layers[len(result.Layers)-1]
	if layer.Kind != "compose" || layer.Path != "image-digests.yaml" {
		t.Fatalf("digest layer = %#v, want compose image-digests.yaml", layer)
	}
}

func TestPublishImageDigestResolverTagsAndWrapsResolveFailures(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	resolver := publishImageDigestResolver(ctx, io.Discard)
	named, err := reference.ParseNamed("registry.example.com/team/api")
	if err != nil {
		t.Fatalf("ParseNamed returned error: %v", err)
	}
	_, err = resolver(named)
	if err == nil {
		t.Fatal("resolver returned nil error, want failure")
	}
	if !strings.Contains(err.Error(), "failed to resolve digest for registry.example.com/team/api:latest") {
		t.Fatalf("resolver error = %v", err)
	}
}

func TestGeneratePublishImageDigestsOverrideReturnsResolverError(t *testing.T) {
	project := &types.Project{
		Services: types.Services{
			"api": {
				Name:  "api",
				Image: "registry.example.com/team/api:latest",
			},
		},
	}
	_, err := generatePublishImageDigestsOverride(project, func(reference.Named) (digest.Digest, error) {
		return "", errors.New("resolver unavailable")
	})
	if err == nil {
		t.Fatal("generatePublishImageDigestsOverride returned nil error, want failure")
	}
	if !strings.Contains(err.Error(), "resolver unavailable") {
		t.Fatalf("digest override error = %v", err)
	}
}

func TestCreatePublishApplicationIndexCopiesImagesInServiceOrder(t *testing.T) {
	project := &types.Project{
		Services: types.Services{
			"worker": {
				Name:  "worker",
				Image: "registry.example.com/team/worker:2",
			},
			"api": {
				Name:  "api",
				Image: "registry.example.com/team/api:1",
			},
		},
	}
	target, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("ParseDockerRef returned error: %v", err)
	}
	composeDescriptor := spec.Descriptor{
		MediaType:    spec.MediaTypeImageManifest,
		ArtifactType: composeOCI.ComposeProjectArtifactType,
		Digest:       "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
		Size:         42,
		Data:         []byte("compose-manifest"),
	}
	var copied []string

	application, err := createPublishApplicationIndex(
		t.Context(),
		nil,
		project,
		target,
		composeDescriptor,
		func(_ context.Context, _ remotes.Resolver, image reference.Named, named reference.Named) (spec.Descriptor, error) {
			copied = append(copied, image.String()+" -> "+named.Name())
			imageBytes := []byte(image.String())
			return spec.Descriptor{
				MediaType: spec.MediaTypeImageManifest,
				Digest:    digest.FromBytes(imageBytes),
				Size:      int64(len(imageBytes)),
			}, nil
		},
	)
	if err != nil {
		t.Fatalf("createPublishApplicationIndex returned error: %v", err)
	}
	if want := []string{
		"registry.example.com/team/api:1 -> registry.example.com/team/app",
		"registry.example.com/team/worker:2 -> registry.example.com/team/app",
	}; !slices.Equal(copied, want) {
		t.Fatalf("copied images = %#v, want %#v", copied, want)
	}
	if application.MediaType != spec.MediaTypeImageIndex || application.ArtifactType != composeOCI.ComposeProjectArtifactType {
		t.Fatalf("application descriptor = %#v", application)
	}

	var index spec.Index
	if err := json.Unmarshal(application.Data, &index); err != nil {
		t.Fatalf("application index did not decode: %v", err)
	}
	if index.Subject == nil || index.Subject.Digest != composeDescriptor.Digest {
		t.Fatalf("index subject = %#v, want compose descriptor", index.Subject)
	}
	if len(index.Subject.Data) != 0 {
		t.Fatalf("index subject carries data, want descriptor-only subject")
	}
	if len(index.Manifests) != 2 {
		t.Fatalf("index manifests = %#v, want two service image manifests", index.Manifests)
	}
}

func TestPublishApplicationIndexPushesApplicationDescriptor(t *testing.T) {
	project := &types.Project{
		Services: types.Services{
			"api": {
				Name:  "api",
				Image: "registry.example.com/team/api:1",
			},
		},
	}
	target, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("ParseDockerRef returned error: %v", err)
	}
	composeDescriptor := spec.Descriptor{
		MediaType:    spec.MediaTypeImageManifest,
		ArtifactType: composeOCI.ComposeProjectArtifactType,
		Digest:       "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
		Size:         42,
	}
	pusher := &publishRecordingPusher{}
	var pusherRefs []string

	application, err := publishApplicationIndex(
		t.Context(),
		publishFakeResolver{pusher: pusher, pusherRefs: &pusherRefs},
		project,
		target,
		composeDescriptor,
		func(_ context.Context, _ remotes.Resolver, image reference.Named, _ reference.Named) (spec.Descriptor, error) {
			imageBytes := []byte(image.String())
			return spec.Descriptor{
				MediaType: spec.MediaTypeImageManifest,
				Digest:    digest.FromBytes(imageBytes),
				Size:      int64(len(imageBytes)),
			}, nil
		},
	)
	if err != nil {
		t.Fatalf("publishApplicationIndex returned error: %v", err)
	}
	if len(pusherRefs) != 1 || pusherRefs[0] != "registry.example.com/team/app" {
		t.Fatalf("pusher refs = %#v, want target repository", pusherRefs)
	}
	if len(pusher.descriptors) != 1 || pusher.descriptors[0].Digest != application.Digest {
		t.Fatalf("pushed descriptors = %#v, want application descriptor %s", pusher.descriptors, application.Digest)
	}
	if len(pusher.writers) != 1 || string(pusher.writers[0].data) != string(application.Data) {
		t.Fatalf("pushed application data = %#v, want index bytes", pusher.writers)
	}
}

func TestPushPublishProjectUpdatesComposeAndApplicationDescriptors(t *testing.T) {
	target, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("ParseDockerRef returned error: %v", err)
	}
	layerData := []byte("services: {}\n")
	layer := spec.Descriptor{
		MediaType: composeOCI.ComposeYAMLMediaType,
		Digest:    digest.FromBytes(layerData),
		Size:      int64(len(layerData)),
		Data:      layerData,
	}

	for _, test := range []struct {
		name string
		app  bool
	}{
		{name: "compose project"},
		{name: "application", app: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			result := &publishResult{}
			pusher := &publishRecordingPusher{}
			request := publishPushRequest{
				project:    &types.Project{},
				named:      target,
				ociVersion: composeOCI.OCIVersion1_1,
				layers:     []spec.Descriptor{layer},
				options:    publishOptions{app: test.app},
				stderr:     io.Discard,
				result:     result,
				resolver:   publishFakeResolver{pusher: pusher},
			}
			if test.app {
				request.project.Services = types.Services{
					"api": {Name: "api", Image: "registry.example.com/team/api:latest"},
				}
				request.options.imageCopier = func(_ context.Context, _ remotes.Resolver, _ reference.Named, _ reference.Named) (spec.Descriptor, error) {
					return spec.Descriptor{MediaType: spec.MediaTypeImageManifest, Digest: digest.FromBytes([]byte("api")), Size: 3}, nil
				}
			}

			if err := pushPublishProject(t.Context(), request); err != nil {
				t.Fatalf("pushPublishProject returned error: %v", err)
			}
			if result.Descriptor == nil || result.Descriptor.Digest == "" {
				t.Fatalf("compose descriptor = %#v, want published descriptor", result.Descriptor)
			}
			if test.app && (result.Application == nil || result.Application.Digest == "") {
				t.Fatalf("application descriptor = %#v, want published descriptor", result.Application)
			}
			if !test.app && result.Application != nil {
				t.Fatalf("application descriptor = %#v, want nil", result.Application)
			}
		})
	}
}

func TestPublishApplicationIndexReturnsPushErrors(t *testing.T) {
	project := &types.Project{
		Services: types.Services{
			"api": {
				Name:  "api",
				Image: "registry.example.com/team/api:1",
			},
		},
	}
	target, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("ParseDockerRef returned error: %v", err)
	}

	_, err = publishApplicationIndex(
		t.Context(),
		publishFakeResolver{pusherErr: errors.New("push unavailable")},
		project,
		target,
		spec.Descriptor{},
		func(_ context.Context, _ remotes.Resolver, image reference.Named, _ reference.Named) (spec.Descriptor, error) {
			imageBytes := []byte(image.String())
			return spec.Descriptor{
				MediaType: spec.MediaTypeImageManifest,
				Digest:    digest.FromBytes(imageBytes),
				Size:      int64(len(imageBytes)),
			}, nil
		},
	)
	if err == nil || !strings.Contains(err.Error(), "push unavailable") {
		t.Fatalf("error = %v, want push failure", err)
	}
}

func TestCreatePublishApplicationIndexRejectsMissingServiceImage(t *testing.T) {
	project := &types.Project{
		Services: types.Services{
			"api": {
				Name: "api",
			},
		},
	}
	target, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("ParseDockerRef returned error: %v", err)
	}

	_, err = createPublishApplicationIndex(t.Context(), nil, project, target, spec.Descriptor{}, nil)
	if err == nil || !strings.Contains(err.Error(), `publish --app requires service "api" to define an image`) {
		t.Fatalf("error = %v, want missing image rejection", err)
	}
}

func TestCreatePublishApplicationIndexRejectsInvalidServiceImage(t *testing.T) {
	project := &types.Project{
		Services: types.Services{
			"api": {
				Name:  "api",
				Image: "bad reference with spaces",
			},
		},
	}
	target, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("ParseDockerRef returned error: %v", err)
	}

	_, err = createPublishApplicationIndex(t.Context(), nil, project, target, spec.Descriptor{}, nil)
	if err == nil || !strings.Contains(err.Error(), `invalid image for service "api"`) {
		t.Fatalf("error = %v, want invalid image rejection", err)
	}
}

func TestCreatePublishApplicationIndexWrapsCopyErrors(t *testing.T) {
	project := &types.Project{
		Services: types.Services{
			"api": {
				Name:  "api",
				Image: "registry.example.com/team/api:1",
			},
		},
	}
	target, err := reference.ParseDockerRef("registry.example.com/team/app:latest")
	if err != nil {
		t.Fatalf("ParseDockerRef returned error: %v", err)
	}

	_, err = createPublishApplicationIndex(
		t.Context(),
		nil,
		project,
		target,
		spec.Descriptor{},
		func(context.Context, remotes.Resolver, reference.Named, reference.Named) (spec.Descriptor, error) {
			return spec.Descriptor{}, errors.New("copy failed")
		},
	)
	if err == nil || !strings.Contains(err.Error(), `failed to copy image for service "api": copy failed`) {
		t.Fatalf("error = %v, want wrapped copy failure", err)
	}
}

func TestPublishRejectsBuildOnlyServices(t *testing.T) {
	dir := t.TempDir()
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    build: .
`)

	_, err := publishComposeProject(
		publishRequestForTest([]string{composeFile}, nil, "publish-build-only", dir),
		publishOptions{
			repository: "registry.example.com/team/app:latest",
			dryRun:     true,
		},
		io.Discard,
	)
	if err == nil || !strings.Contains(err.Error(), "only define build sections") {
		t.Fatalf("error = %v, want build-only rejection", err)
	}
}

func TestPublishRejectsBindMountsWithoutYes(t *testing.T) {
	dir := t.TempDir()
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    image: alpine
    volumes:
      - .:/workspace:ro
`)

	_, err := publishComposeProject(
		publishRequestForTest([]string{composeFile}, nil, "publish-bind", dir),
		publishOptions{
			repository: "registry.example.com/team/app:latest",
			dryRun:     true,
			prompt:     &publishPromptRecorder{answers: []bool{false}},
		},
		io.Discard,
	)
	if err == nil || !strings.Contains(err.Error(), "publish canceled") {
		t.Fatalf("error = %v, want publish cancellation", err)
	}
}

func TestPublishAllowsBindMountsWithYes(t *testing.T) {
	dir := t.TempDir()
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    image: alpine
    volumes:
      - .:/workspace:ro
`)

	_, err := publishComposeProject(
		publishRequestForTest([]string{composeFile}, nil, "publish-bind", dir),
		publishOptions{
			repository: "registry.example.com/team/app:latest",
			assumeYes:  true,
			dryRun:     true,
		},
		io.Discard,
	)
	if err != nil {
		t.Fatalf("publishComposeProject returned error: %v", err)
	}
}

func TestPublishPromptReadsSequentialAnswers(t *testing.T) {
	output := &strings.Builder{}
	prompt := newPublishPrompt(strings.NewReader("y\nn\n"), output, false)

	first, err := prompt.Confirm("first?", false)
	if err != nil {
		t.Fatalf("first Confirm returned error: %v", err)
	}
	second, err := prompt.Confirm("second?", true)
	if err != nil {
		t.Fatalf("second Confirm returned error: %v", err)
	}

	if !first || second {
		t.Fatalf("answers = (%v, %v), want (true, false)", first, second)
	}
	if got := output.String(); !strings.Contains(got, "first? [y/N]: ") || !strings.Contains(got, "second? [y/N]: ") {
		t.Fatalf("prompt output = %q, want both prompts", got)
	}
}

func TestPublishPromptDefaultsAndAssumeYes(t *testing.T) {
	output := &strings.Builder{}
	assumeYes := newPublishPrompt(strings.NewReader(""), output, true)
	ok, err := assumeYes.Confirm("ignored?", false)
	if err != nil {
		t.Fatalf("assume-yes Confirm returned error: %v", err)
	}
	if !ok || output.Len() != 0 {
		t.Fatalf("assume-yes = (%v, %q), want true without output", ok, output.String())
	}

	prompt := newPublishPrompt(strings.NewReader("\nmaybe\n"), output, false)
	first, err := prompt.Confirm("default yes?", true)
	if err != nil {
		t.Fatalf("default yes Confirm returned error: %v", err)
	}
	second, err := prompt.Confirm("default no?", false)
	if err != nil {
		t.Fatalf("default no Confirm returned error: %v", err)
	}
	if !first || second {
		t.Fatalf("answers = (%v, %v), want defaults (true, false)", first, second)
	}
}

func TestPublishEnvAndConfigPreflightPrompts(t *testing.T) {
	dir := t.TempDir()
	_ = writePublishFixture(t, dir, ".env", "TOKEN=from-file\n")
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    image: alpine
    env_file:
      - .env
    environment:
      LOG_LEVEL: info
      MYSQL_ROOT_PASSWORD: toto
      SYMBOLIC_SECRET: ${SECRET}
configs:
  app_config:
    content: |
      password=literal
  symbolic_config:
    content: ${CONFIG_CONTENT}
`)
	project := mustPublishProject(t, []string{composeFile}, dir)
	prompt := &publishPromptRecorder{answers: []bool{true, true}}

	err := checkPublishEnvironmentVariables(project, publishOptions{}, prompt)
	if err != nil {
		t.Fatalf("checkPublishEnvironmentVariables returned error: %v", err)
	}
	if len(prompt.messages) != 2 {
		t.Fatalf("messages = %#v, want env and config prompts", prompt.messages)
	}
	if !strings.Contains(prompt.messages[0], `service "api": env_file declared`) {
		t.Fatalf("env prompt = %q, want env_file finding", prompt.messages[0])
	}
	if !strings.Contains(prompt.messages[0], `"MYSQL_ROOT_PASSWORD"`) {
		t.Fatalf("env prompt = %q, want sensitive-looking key", prompt.messages[0])
	}
	if strings.Contains(prompt.messages[0], "LOG_LEVEL") || strings.Contains(prompt.messages[0], "SYMBOLIC_SECRET") {
		t.Fatalf("env prompt = %q, want benign and symbolic values excluded", prompt.messages[0])
	}
	if !strings.Contains(prompt.messages[1], `config "app_config"`) || strings.Contains(prompt.messages[1], "symbolic_config") {
		t.Fatalf("config prompt = %q, want only literal config content", prompt.messages[1])
	}
}

func TestPublishWithEnvSilencesEnvPromptButKeepsConfigContentPrompt(t *testing.T) {
	dir := t.TempDir()
	_ = writePublishFixture(t, dir, ".env", "TOKEN=from-file\n")
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    image: alpine
    env_file:
      - .env
configs:
  app_config:
    content: password=literal
`)
	project := mustPublishProject(t, []string{composeFile}, dir)
	prompt := &publishPromptRecorder{answers: []bool{true}}

	err := checkPublishEnvironmentVariables(project, publishOptions{withEnv: true}, prompt)
	if err != nil {
		t.Fatalf("checkPublishEnvironmentVariables returned error: %v", err)
	}
	if len(prompt.messages) != 1 || !strings.Contains(prompt.messages[0], `config "app_config"`) {
		t.Fatalf("messages = %#v, want only config content prompt", prompt.messages)
	}
}

func TestPublishEnvironmentPreflightSkipsEmptyProject(t *testing.T) {
	prompt := &publishPromptRecorder{err: errors.New("prompt should not run")}

	err := checkPublishEnvironmentVariables(&types.Project{}, publishOptions{}, prompt)
	if err != nil {
		t.Fatalf("checkPublishEnvironmentVariables returned error: %v", err)
	}
	if len(prompt.messages) != 0 {
		t.Fatalf("messages = %#v, want no prompts", prompt.messages)
	}
}

func TestPublishConfirmPropagatesPromptErrors(t *testing.T) {
	want := errors.New("prompt unavailable")
	err := confirmPublish(&publishPromptRecorder{err: want}, "continue?")
	if !errors.Is(err, want) {
		t.Fatalf("error = %v, want %v", err, want)
	}
}

func TestPublishComposeFileReaderReportsMissingFile(t *testing.T) {
	_, err := publishComposeFileAsReader(filepath.Join(t.TempDir(), "missing.yaml"))
	if err == nil || !strings.Contains(err.Error(), "failed to open compose file") {
		t.Fatalf("error = %v, want compose file open failure", err)
	}
}

func TestPublishSensitiveDataPreflightPromptsForDetectedFiles(t *testing.T) {
	dir := t.TempDir()
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    image: alpine
`)
	envFile := writePublishFixture(t, dir, ".env", "AWS_SECRET_ACCESS_KEY=abcdefghijklmnop\n")
	configFile := writePublishFixture(t, dir, "config.env", "PASSWORD=super-secret-value\n")
	secretFile := writePublishFixture(t, dir, "secret.env", "TOKEN=another-secret-value\n")
	project := &types.Project{
		ComposeFiles: []string{composeFile},
		Services: types.Services{
			"api": {
				Name:     "api",
				Image:    "alpine",
				EnvFiles: []types.EnvFile{{Path: envFile, Required: true}},
			},
		},
		Configs: types.Configs{
			"app_config": types.ConfigObjConfig{File: configFile},
		},
		Secrets: types.Secrets{
			"app_secret": types.SecretConfig{File: secretFile},
		},
	}
	prompt := &publishPromptRecorder{answers: []bool{true}}

	err := checkPublishSensitiveData(project, prompt)
	if err != nil {
		t.Fatalf("checkPublishSensitiveData returned error: %v", err)
	}
	if len(prompt.messages) != 1 || !strings.Contains(prompt.messages[0], "sensitive data") {
		t.Fatalf("messages = %#v, want one sensitive-data prompt", prompt.messages)
	}
	for _, rawValue := range []string{"abcdefghijklmnop", "super-secret-value", "another-secret-value"} {
		if strings.Contains(prompt.messages[0], rawValue) {
			t.Fatalf("sensitive-data prompt leaked raw value %q in %q", rawValue, prompt.messages[0])
		}
	}
	if !strings.Contains(prompt.messages[0], "redacted") {
		t.Fatalf("message = %q, want redaction notice", prompt.messages[0])
	}
}

func TestPublishSensitiveDataPreflightCancellation(t *testing.T) {
	dir := t.TempDir()
	composeFile := writePublishFixture(t, dir, "compose.yaml", "services: {}\n")
	envFile := writePublishFixture(t, dir, ".env", "AWS_SECRET_ACCESS_KEY=abcdefghijklmnop\n")
	project := &types.Project{
		ComposeFiles: []string{composeFile},
		Services: types.Services{
			"api": {
				Name:     "api",
				Image:    "alpine",
				EnvFiles: []types.EnvFile{{Path: envFile, Required: true}},
			},
		},
	}
	prompt := &publishPromptRecorder{answers: []bool{false}}

	err := checkPublishSensitiveData(project, prompt)
	if err == nil || !strings.Contains(err.Error(), "publish canceled") {
		t.Fatalf("error = %v, want publish cancellation", err)
	}
}

func TestPublishSensitiveDataPreflightSkipsOptionalMissingEnvFile(t *testing.T) {
	dir := t.TempDir()
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
services:
  api:
    image: alpine
    env_file:
      - path: missing.env
        required: false
`)
	project := mustPublishProject(t, []string{composeFile}, dir)
	prompt := &publishPromptRecorder{answers: []bool{true}}

	err := checkPublishSensitiveData(project, prompt)
	if err != nil {
		t.Fatalf("checkPublishSensitiveData returned error: %v", err)
	}
	if len(prompt.messages) != 0 {
		t.Fatalf("messages = %#v, want no sensitive-data prompt", prompt.messages)
	}
}

func TestPublishEnvFileExists(t *testing.T) {
	existing := writePublishFixture(t, t.TempDir(), ".env", "TOKEN=value\n")

	for _, test := range []struct {
		name    string
		envFile types.EnvFile
		want    bool
		wantErr string
	}{
		{
			name:    "existing",
			envFile: types.EnvFile{Path: existing, Required: true},
			want:    true,
		},
		{
			name:    "optional missing",
			envFile: types.EnvFile{Path: filepath.Join(t.TempDir(), "missing.env")},
		},
		{
			name:    "required missing",
			envFile: types.EnvFile{Path: filepath.Join(t.TempDir(), "missing.env"), Required: true},
			wantErr: "not found",
		},
		{
			name:    "inaccessible",
			envFile: types.EnvFile{Path: "\x00"},
			wantErr: "failed to access env file",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := publishEnvFileExists(test.envFile)
			if test.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantErr) {
					t.Fatalf("error = %v, want error containing %q", err, test.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("publishEnvFileExists returned error: %v", err)
			}
			if got != test.want {
				t.Fatalf("publishEnvFileExists = %t, want %t", got, test.want)
			}
		})
	}
}

func TestPublishRejectsLocalIncludes(t *testing.T) {
	dir := t.TempDir()
	_ = writePublishFixture(t, dir, "included.yaml", "services: {}\n")
	composeFile := writePublishFixture(t, dir, "compose.yaml", `
include:
  - included.yaml
services:
  api:
    image: alpine
`)

	_, err := publishComposeProject(
		publishRequestForTest([]string{composeFile}, nil, "publish-include", dir),
		publishOptions{
			repository: "registry.example.com/team/app:latest",
			dryRun:     true,
		},
		io.Discard,
	)
	if err == nil || !strings.Contains(err.Error(), "local include files") {
		t.Fatalf("error = %v, want local include rejection", err)
	}
}

func TestLocalIncludesInComposeSkipsRemoteResources(t *testing.T) {
	includes, err := localIncludesInCompose([]byte(`
include:
  - path: ./local.yml
  - path: https://example.com/compose.yml
  - git@github.com:example/project.git#main:compose.yml
  - oci://registry.example.com/team/app:latest
services:
  api:
    image: alpine
`))
	if err != nil {
		t.Fatalf("localIncludesInCompose returned error: %v", err)
	}
	if len(includes) != 1 || includes[0] != "./local.yml" {
		t.Fatalf("includes = %#v, want only local include", includes)
	}
}

func TestPublishLayerSnapshotsUnknownDescriptor(t *testing.T) {
	snapshots := publishLayerSnapshots([]spec.Descriptor{{
		MediaType: "application/vnd.example.layer",
		Digest:    "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		Size:      7,
		Annotations: map[string]string{
			"org.opencontainers.image.title": "nested/custom.bin",
		},
	}})
	if len(snapshots) != 1 {
		t.Fatalf("snapshots = %#v, want one snapshot", snapshots)
	}
	if snapshots[0].Kind != "unknown" || snapshots[0].Path != "custom.bin" {
		t.Fatalf("snapshot = %#v, want unknown custom.bin layer", snapshots[0])
	}
}

func TestPublishRejectsMissingRepository(t *testing.T) {
	_, err := publishComposeProject(
		publishRequestForTest(nil, nil, "publish-missing-repo", ""),
		publishOptions{dryRun: true},
		io.Discard,
	)
	if err == nil || !strings.Contains(err.Error(), "publish repository is required") {
		t.Fatalf("error = %v, want missing repository rejection", err)
	}
}

func TestPublishRejectsInvalidRepository(t *testing.T) {
	_, err := publishComposeProject(
		publishRequestForTest(nil, nil, "publish-invalid-repo", ""),
		publishOptions{
			repository: "bad reference with spaces",
			dryRun:     true,
		},
		io.Discard,
	)
	if err == nil || !strings.Contains(err.Error(), "invalid publish repository") {
		t.Fatalf("error = %v, want invalid repository rejection", err)
	}
}

func TestPublishRejectsUnsupportedOCIVersion(t *testing.T) {
	_, err := parsePublishOCIVersion("9.9")
	if err == nil || !strings.Contains(err.Error(), "unsupported OCI version: 9.9") {
		t.Fatalf("error = %v, want unsupported version", err)
	}
}

func TestPublishOCIVersionParsingAndDisplay(t *testing.T) {
	tests := []struct {
		in      string
		want    composeOCI.OCIVersion
		display string
	}{
		{in: "", want: "", display: "auto"},
		{in: "1.0", want: composeOCI.OCIVersion1_0, display: "1.0"},
		{in: "1.1", want: composeOCI.OCIVersion1_1, display: "1.1"},
	}
	for _, test := range tests {
		got, err := parsePublishOCIVersion(test.in)
		if err != nil {
			t.Fatalf("parsePublishOCIVersion(%q) returned error: %v", test.in, err)
		}
		if got != test.want {
			t.Fatalf("parsePublishOCIVersion(%q) = %q, want %q", test.in, got, test.want)
		}
		if display := displayPublishOCIVersion(got); display != test.display {
			t.Fatalf("displayPublishOCIVersion(%q) = %q, want %q", got, display, test.display)
		}
	}
}

func TestPublishDescriptorFromOCI(t *testing.T) {
	descriptor := publishDescriptorFromOCI(spec.Descriptor{
		MediaType:    spec.MediaTypeImageManifest,
		Digest:       "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Size:         42,
		ArtifactType: composeOCI.ComposeProjectArtifactType,
	})
	if descriptor.MediaType != spec.MediaTypeImageManifest {
		t.Fatalf("media type = %q, want %q", descriptor.MediaType, spec.MediaTypeImageManifest)
	}
	if descriptor.Digest != "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
		t.Fatalf("digest = %q", descriptor.Digest)
	}
	if descriptor.Size != 42 {
		t.Fatalf("size = %d, want 42", descriptor.Size)
	}
	if descriptor.ArtifactType != composeOCI.ComposeProjectArtifactType {
		t.Fatalf("artifact type = %q, want %q", descriptor.ArtifactType, composeOCI.ComposeProjectArtifactType)
	}
}

func TestPublishRejectsUnsupportedOCIVersionBeforeLoadingProject(t *testing.T) {
	_, err := publishComposeProject(
		publishRequestForTest(nil, nil, "publish-unsupported-oci", ""),
		publishOptions{
			repository: "registry.example.com/team/app:latest",
			ociVersion: "9.9",
			dryRun:     true,
		},
		io.Discard,
	)
	if err == nil || !strings.Contains(err.Error(), "unsupported OCI version: 9.9") {
		t.Fatalf("error = %v, want unsupported OCI version", err)
	}
}

func writePublishFixture(t *testing.T, dir, name, content string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir fixture: %v", err)
	}
	if err := os.WriteFile(path, []byte(strings.TrimPrefix(content, "\n")), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	return path
}

func publishRequestForTest(files, envFiles []string, projectName, projectDirectory string) publishRequest {
	return publishRequest{
		files:            files,
		envFiles:         envFiles,
		projectName:      projectName,
		projectDirectory: projectDirectory,
		loadOptions:      projectLoadOptions{},
	}
}

func mustPublishProject(t *testing.T, files []string, projectDirectory string) *types.Project {
	t.Helper()
	project, _, err := loadComposeProject(files, nil, nil, "publish-digests", projectDirectory, projectLoadOptions{})
	if err != nil {
		t.Fatalf("loadComposeProject returned error: %v", err)
	}
	project, err = project.WithProfiles([]string{"*"})
	if err != nil {
		t.Fatalf("WithProfiles returned error: %v", err)
	}
	return project
}

type publishFakeResolver struct {
	pusher     remotes.Pusher
	pusherErr  error
	pusherRefs *[]string
}

func (resolver publishFakeResolver) Resolve(context.Context, string) (string, spec.Descriptor, error) {
	return "", spec.Descriptor{}, errors.New("resolve is not implemented in tests")
}

func (resolver publishFakeResolver) Fetcher(context.Context, string) (remotes.Fetcher, error) {
	return nil, errors.New("fetch is not implemented in tests")
}

func (resolver publishFakeResolver) Pusher(_ context.Context, ref string) (remotes.Pusher, error) {
	if resolver.pusherErr != nil {
		return nil, resolver.pusherErr
	}
	if resolver.pusherRefs != nil {
		*resolver.pusherRefs = append(*resolver.pusherRefs, ref)
	}
	return resolver.pusher, nil
}

type publishRecordingPusher struct {
	descriptors []spec.Descriptor
	writers     []*publishRecordingWriter
}

func (pusher *publishRecordingPusher) Push(_ context.Context, descriptor spec.Descriptor) (content.Writer, error) {
	pusher.descriptors = append(pusher.descriptors, descriptor)
	writer := &publishRecordingWriter{}
	pusher.writers = append(pusher.writers, writer)
	return writer, nil
}

type publishRecordingWriter struct {
	data []byte
}

func (writer *publishRecordingWriter) Write(data []byte) (int, error) {
	writer.data = append(writer.data, data...)
	return len(data), nil
}

func (writer *publishRecordingWriter) Close() error {
	return nil
}

func (writer *publishRecordingWriter) Digest() digest.Digest {
	return digest.FromBytes(writer.data)
}

func (writer *publishRecordingWriter) Commit(context.Context, int64, digest.Digest, ...content.Opt) error {
	return nil
}

func (writer *publishRecordingWriter) Status() (content.Status, error) {
	return content.Status{Offset: int64(len(writer.data))}, nil
}

type publishPromptRecorder struct {
	answers  []bool
	messages []string
	err      error
}

func (recorder *publishPromptRecorder) Confirm(message string, _ bool) (bool, error) {
	recorder.messages = append(recorder.messages, message)
	if recorder.err != nil {
		return false, recorder.err
	}
	if len(recorder.answers) == 0 {
		return false, nil
	}
	answer := recorder.answers[0]
	recorder.answers = recorder.answers[1:]
	return answer, nil
}

func (writer *publishRecordingWriter) Truncate(size int64) error {
	writer.data = writer.data[:int(size)]
	return nil
}
