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
// Copyright 2020 Docker Compose CLI authors.

package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/compose-spec/compose-go/v2/loader"
	"github.com/compose-spec/compose-go/v2/types"
	"github.com/distribution/reference"
	"github.com/docker/cli/cli/config"
	digest "github.com/opencontainers/go-digest"
	spec "github.com/opencontainers/image-spec/specs-go/v1"
	composeOCI "github.com/stephenlclarke/container-compose/Tools/compose-normalizer/oci"
	composeTransform "github.com/stephenlclarke/container-compose/Tools/compose-normalizer/transform"
	"go.yaml.in/yaml/v4"
)

type publishOptions struct {
	repository          string
	app                 bool
	ociVersion          string
	resolveImageDigests bool
	withEnv             bool
	assumeYes           bool
	dryRun              bool
	imageDigestResolver func(reference.Named) (digest.Digest, error)
}

type publishResult struct {
	Repository string                 `json:"repository"`
	OCIVersion string                 `json:"ociVersion"`
	DryRun     bool                   `json:"dryRun,omitempty"`
	Descriptor *publishDescriptor     `json:"descriptor,omitempty"`
	Layers     []publishLayerSnapshot `json:"layers"`
}

type publishDescriptor struct {
	MediaType    string `json:"mediaType"`
	Digest       string `json:"digest"`
	Size         int64  `json:"size"`
	ArtifactType string `json:"artifactType,omitempty"`
}

type publishLayerSnapshot struct {
	Kind      string `json:"kind"`
	Path      string `json:"path"`
	MediaType string `json:"mediaType"`
	Digest    string `json:"digest"`
	Size      int64  `json:"size"`
}

func publishComposeProject(
	files, profiles, envFiles []string,
	projectName, projectDirectory string,
	loadOptions projectLoadOptions,
	options publishOptions,
	stderr io.Writer,
) (*publishResult, error) {
	ctx := context.Background()
	if strings.TrimSpace(options.repository) == "" {
		return nil, errors.New("publish repository is required")
	}
	named, err := reference.ParseDockerRef(options.repository)
	if err != nil {
		return nil, fmt.Errorf("invalid publish repository %q: %w", options.repository, err)
	}
	ociVersion, err := parsePublishOCIVersion(options.ociVersion)
	if err != nil {
		return nil, err
	}
	if options.app {
		return nil, errors.New("unsupported publish option --app: application image indexes are not implemented")
	}

	project, _, err := loadComposeProject(files, profiles, envFiles, projectName, projectDirectory, loadOptions)
	if err != nil {
		return nil, err
	}
	project, err = project.WithProfiles([]string{"*"})
	if err != nil {
		return nil, err
	}
	if err := checkPublishBuildOnlyServices(project); err != nil {
		return nil, err
	}
	if err := checkPublishBindMounts(project, options.assumeYes); err != nil {
		return nil, err
	}
	if err := checkPublishLocalIncludes(project.ComposeFiles); err != nil {
		return nil, err
	}

	if options.resolveImageDigests && options.imageDigestResolver == nil {
		options.imageDigestResolver = publishImageDigestResolver(ctx, stderr)
	}
	layers, err := createPublishLayers(ctx, project, options)
	if err != nil {
		return nil, err
	}

	result := &publishResult{
		Repository: named.String(),
		OCIVersion: displayPublishOCIVersion(ociVersion),
		DryRun:     options.dryRun,
		Layers:     publishLayerSnapshots(layers),
	}
	if options.dryRun {
		return result, nil
	}

	resolver := composeOCI.NewResolver(config.LoadDefaultConfigFile(stderr), nil)
	descriptor, err := composeOCI.PushManifest(ctx, resolver, named, layers, ociVersion)
	if err != nil {
		return nil, err
	}
	result.Descriptor = publishDescriptorFromOCI(descriptor)
	return result, nil
}

func parsePublishOCIVersion(version string) (composeOCI.OCIVersion, error) {
	switch version {
	case "":
		return "", nil
	case string(composeOCI.OCIVersion1_0):
		return composeOCI.OCIVersion1_0, nil
	case string(composeOCI.OCIVersion1_1):
		return composeOCI.OCIVersion1_1, nil
	default:
		return "", fmt.Errorf("unsupported OCI version: %s", version)
	}
}

func displayPublishOCIVersion(version composeOCI.OCIVersion) string {
	if version == "" {
		return "auto"
	}
	return string(version)
}

func checkPublishBuildOnlyServices(project *types.Project) error {
	var services []string
	for _, service := range project.Services {
		if service.Image == "" && service.Build != nil {
			services = append(services, service.Name)
		}
	}
	if len(services) == 0 {
		return nil
	}
	sort.Strings(services)
	var message strings.Builder
	message.WriteString("Compose project cannot be published because these services only define build sections:\n")
	for _, service := range services {
		fmt.Fprintf(&message, "- %q\n", service)
	}
	return errors.New(strings.TrimSuffix(message.String(), "\n"))
}

func checkPublishBindMounts(project *types.Project, assumeYes bool) error {
	var findings []string
	for _, service := range project.Services {
		for _, volume := range service.Volumes {
			if volume.Type == types.VolumeTypeBind {
				findings = append(findings, fmt.Sprintf("%s:%s", service.Name, volume.String()))
			}
		}
	}
	if len(findings) == 0 || assumeYes {
		return nil
	}
	sort.Strings(findings)
	return fmt.Errorf("publish would include bind mount declarations (%s); pass --yes to publish declarations without host content", strings.Join(findings, ", "))
}

func createPublishLayers(ctx context.Context, project *types.Project, options publishOptions) ([]spec.Descriptor, error) {
	var layers []spec.Descriptor
	extendsFiles := map[string]string{}
	envFiles := map[string]string{}
	for _, file := range project.ComposeFiles {
		data, err := processPublishFile(ctx, file, project, extendsFiles, envFiles)
		if err != nil {
			return nil, err
		}
		layers = append(layers, composeOCI.DescriptorForComposeFile(file, data))
	}

	extendsLayers, err := processPublishExtends(ctx, project, extendsFiles)
	if err != nil {
		return nil, err
	}
	layers = append(layers, extendsLayers...)
	if options.withEnv {
		layers = append(layers, publishEnvFileLayers(envFiles)...)
	}
	if options.resolveImageDigests {
		digestOverride, err := generatePublishImageDigestsOverride(project, options.imageDigestResolver)
		if err != nil {
			return nil, err
		}
		layers = append(layers, composeOCI.DescriptorForComposeFile("image-digests.yaml", digestOverride))
	}
	return layers, nil
}

func publishImageDigestResolver(ctx context.Context, stderr io.Writer) func(reference.Named) (digest.Digest, error) {
	resolver := composeOCI.NewResolver(config.LoadDefaultConfigFile(stderr), nil)
	return func(named reference.Named) (digest.Digest, error) {
		tagged := reference.TagNameOnly(named)
		_, descriptor, err := resolver.Resolve(ctx, tagged.String())
		if err != nil {
			return "", fmt.Errorf("failed to resolve digest for %s: %w", tagged.String(), err)
		}
		return descriptor.Digest, nil
	}
}

func generatePublishImageDigestsOverride(project *types.Project, resolver func(reference.Named) (digest.Digest, error)) ([]byte, error) {
	resolved, err := project.WithImagesResolved(resolver)
	if err != nil {
		return nil, err
	}
	override := types.Project{
		Services: types.Services{},
	}
	for name, service := range resolved.Services {
		override.Services[name] = types.ServiceConfig{
			Image: service.Image,
		}
	}
	return override.MarshalYAML()
}

func processPublishExtends(ctx context.Context, project *types.Project, files map[string]string) ([]spec.Descriptor, error) {
	var layers []spec.Descriptor
	nextFiles := map[string]string{}
	for _, file := range sortedMapKeys(files) {
		hash := files[file]
		envFiles := map[string]string{}
		data, err := processPublishFile(ctx, file, project, nextFiles, envFiles)
		if err != nil {
			return nil, err
		}
		layer := composeOCI.DescriptorForComposeFile(hash, data)
		layer.Annotations["com.docker.compose.extends"] = "true"
		layers = append(layers, layer)
	}
	pendingFiles := map[string]string{}
	for file, hash := range nextFiles {
		if _, ok := files[file]; !ok {
			files[file] = hash
			pendingFiles[file] = hash
		}
	}
	if len(pendingFiles) > 0 {
		nextLayers, err := processPublishExtends(ctx, project, pendingFiles)
		if err != nil {
			return nil, err
		}
		layers = append(layers, nextLayers...)
	}
	return layers, nil
}

func processPublishFile(ctx context.Context, file string, project *types.Project, extendsFiles map[string]string, envFiles map[string]string) ([]byte, error) {
	content, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	if _, err := loadPublishFileModel(ctx, file, content, project); err != nil {
		return nil, err
	}

	base, err := loader.LoadWithContext(ctx, types.ConfigDetails{
		WorkingDir:  project.WorkingDir,
		Environment: project.Environment,
		ConfigFiles: []types.ConfigFile{{
			Filename: file,
			Content:  content,
		}},
	}, publishSourceLoadOptions(project))
	if err != nil {
		return nil, err
	}

	for name, service := range base.Services {
		for index, envFile := range service.EnvFiles {
			hash := fmt.Sprintf("%x.env", sha256.Sum256([]byte(envFile.Path)))
			if _, statErr := os.Stat(envFile.Path); statErr == nil {
				envFiles[envFile.Path] = hash
			} else if !os.IsNotExist(statErr) {
				return nil, fmt.Errorf("failed to access env file %s: %w", envFile.Path, statErr)
			}
			content, err = composeTransform.ReplaceEnvFile(content, name, index, hash)
			if err != nil {
				return nil, err
			}
		}

		if service.Extends == nil || service.Extends.File == "" {
			continue
		}
		extendsFile := service.Extends.File
		if _, statErr := os.Stat(extendsFile); os.IsNotExist(statErr) {
			continue
		} else if statErr != nil {
			return nil, fmt.Errorf("failed to access extends file %s: %w", extendsFile, statErr)
		}

		hash := fmt.Sprintf("%x.yaml", sha256.Sum256([]byte(extendsFile)))
		extendsFiles[extendsFile] = hash
		content, err = composeTransform.ReplaceExtendsFile(content, name, hash)
		if err != nil {
			return nil, err
		}
	}
	return content, nil
}

func publishSourceLoadOptions(project *types.Project) func(*loader.Options) {
	return func(options *loader.Options) {
		options.SkipValidation = true
		options.SkipExtends = true
		options.SkipConsistencyCheck = true
		options.ResolvePaths = true
		options.SkipInclude = true
		options.Profiles = project.Profiles
	}
}

func loadPublishFileModel(ctx context.Context, file string, content []byte, project *types.Project) (map[string]any, error) {
	model, err := loader.LoadModelWithContext(ctx, types.ConfigDetails{
		WorkingDir:  project.WorkingDir,
		Environment: project.Environment,
		ConfigFiles: []types.ConfigFile{{
			Filename: file,
			Content:  content,
		}},
	}, func(options *loader.Options) {
		publishSourceLoadOptions(project)(options)
		options.SkipInterpolation = true
		options.SkipResolveEnvironment = true
	})
	if err != nil {
		return nil, fmt.Errorf("failed to load compose file %s: %w", file, err)
	}
	return model, nil
}

func publishEnvFileLayers(files map[string]string) []spec.Descriptor {
	layers := make([]spec.Descriptor, 0, len(files))
	for _, file := range sortedMapKeys(files) {
		content, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		layers = append(layers, composeOCI.DescriptorForEnvFile(files[file], content))
	}
	return layers
}

func sortedMapKeys[V any](values map[string]V) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func checkPublishLocalIncludes(files []string) error {
	for _, file := range files {
		if isRemotePublishResource(file) {
			continue
		}
		content, err := os.ReadFile(file)
		if err != nil {
			return err
		}
		includes, err := localIncludesInCompose(content)
		if err != nil {
			return fmt.Errorf("failed to inspect include directives in %s: %w", file, err)
		}
		if len(includes) > 0 {
			sort.Strings(includes)
			return fmt.Errorf("publish does not support local include files in %s: %s", file, strings.Join(includes, ", "))
		}
	}
	return nil
}

func localIncludesInCompose(content []byte) ([]string, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(content, &doc); err != nil {
		return nil, err
	}
	if len(doc.Content) == 0 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, nil
	}
	include := mappingValue(doc.Content[0], "include")
	if include == nil {
		return nil, nil
	}
	var includes []string
	collectLocalIncludePaths(include, &includes)
	return includes, nil
}

func collectLocalIncludePaths(node *yaml.Node, includes *[]string) {
	switch node.Kind {
	case yaml.ScalarNode:
		if node.Value != "" && !isRemotePublishResource(node.Value) {
			*includes = append(*includes, node.Value)
		}
	case yaml.SequenceNode:
		for _, child := range node.Content {
			collectLocalIncludePaths(child, includes)
		}
	case yaml.MappingNode:
		path := mappingValue(node, "path")
		if path == nil {
			return
		}
		collectLocalIncludePaths(path, includes)
	}
}

func mappingValue(root *yaml.Node, key string) *yaml.Node {
	if root.Kind != yaml.MappingNode {
		return nil
	}
	for index := 0; index < len(root.Content); index += 2 {
		k := root.Content[index]
		if k.Kind == yaml.ScalarNode && k.Value == key {
			return root.Content[index+1]
		}
	}
	return nil
}

func isRemotePublishResource(path string) bool {
	if strings.HasPrefix(path, "oci://") ||
		strings.HasPrefix(path, "git@") ||
		strings.HasPrefix(path, "github.com/") {
		return true
	}
	if strings.Contains(path, "://") {
		return true
	}
	return strings.Contains(path, ".git#")
}

func publishLayerSnapshots(layers []spec.Descriptor) []publishLayerSnapshot {
	snapshots := make([]publishLayerSnapshot, 0, len(layers))
	for _, layer := range layers {
		snapshots = append(snapshots, publishLayerSnapshot{
			Kind:      publishLayerKind(layer),
			Path:      publishLayerPath(layer),
			MediaType: layer.MediaType,
			Digest:    layer.Digest.String(),
			Size:      layer.Size,
		})
	}
	return snapshots
}

func publishLayerKind(layer spec.Descriptor) string {
	switch layer.MediaType {
	case composeOCI.ComposeYAMLMediaType:
		if layer.Annotations["com.docker.compose.extends"] == "true" {
			return "extends"
		}
		return "compose"
	case composeOCI.ComposeEnvFileMediaType:
		return "env"
	default:
		return "unknown"
	}
}

func publishLayerPath(layer spec.Descriptor) string {
	switch layer.MediaType {
	case composeOCI.ComposeYAMLMediaType:
		return layer.Annotations["com.docker.compose.file"]
	case composeOCI.ComposeEnvFileMediaType:
		return layer.Annotations["com.docker.compose.envfile"]
	default:
		return filepath.Base(layer.Annotations["org.opencontainers.image.title"])
	}
}

func publishDescriptorFromOCI(descriptor spec.Descriptor) *publishDescriptor {
	return &publishDescriptor{
		MediaType:    descriptor.MediaType,
		Digest:       descriptor.Digest.String(),
		Size:         descriptor.Size,
		ArtifactType: descriptor.ArtifactType,
	}
}
