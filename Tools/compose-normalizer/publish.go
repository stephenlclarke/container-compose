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
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/DefangLabs/secret-detector/pkg/detectors/keyword"
	"github.com/DefangLabs/secret-detector/pkg/scanner"
	"github.com/DefangLabs/secret-detector/pkg/secrets"
	"github.com/compose-spec/compose-go/v2/loader"
	"github.com/compose-spec/compose-go/v2/types"
	"github.com/containerd/containerd/v2/core/remotes"
	"github.com/distribution/reference"
	"github.com/docker/cli/cli/config"
	digest "github.com/opencontainers/go-digest"
	spec "github.com/opencontainers/image-spec/specs-go/v1"
	composeOCI "github.com/stephenlclarke/container-compose/Tools/compose-normalizer/oci"
	composeTransform "github.com/stephenlclarke/container-compose/Tools/compose-normalizer/transform"
	"go.yaml.in/yaml/v4"
)

type publishImageCopier func(context.Context, remotes.Resolver, reference.Named, reference.Named) (spec.Descriptor, error)

type publishOptions struct {
	repository          string
	app                 bool
	ociVersion          string
	resolveImageDigests bool
	withEnv             bool
	assumeYes           bool
	dryRun              bool
	imageDigestResolver func(reference.Named) (digest.Digest, error)
	imageCopier         publishImageCopier
	prompt              publishPrompter
}

type publishResult struct {
	Repository  string                 `json:"repository"`
	OCIVersion  string                 `json:"ociVersion"`
	DryRun      bool                   `json:"dryRun,omitempty"`
	Descriptor  *publishDescriptor     `json:"descriptor,omitempty"`
	Application *publishDescriptor     `json:"application,omitempty"`
	Layers      []publishLayerSnapshot `json:"layers"`
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
	if err := checkPublishLocalIncludes(project.ComposeFiles); err != nil {
		return nil, err
	}
	if err := checkPublishPreflight(ctx, project, options, stderr); err != nil {
		return nil, err
	}

	if options.app {
		options.resolveImageDigests = true
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
	if options.app {
		application, err := publishApplicationIndex(ctx, resolver, project, named, descriptor, options.imageCopier)
		if err != nil {
			return nil, err
		}
		result.Application = publishDescriptorFromOCI(application)
	}
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

func checkPublishPreflight(ctx context.Context, project *types.Project, options publishOptions, stderr io.Writer) error {
	prompt := options.prompt
	if prompt == nil {
		prompt = newPublishPrompt(os.Stdin, stderr, options.assumeYes)
	}

	if err := checkPublishBindMounts(project, prompt); err != nil {
		return err
	}
	if err := checkPublishSensitiveData(project, prompt); err != nil {
		return err
	}
	return checkPublishEnvironmentVariables(project, options, prompt)
}

type publishPrompter interface {
	Confirm(message string, defaultValue bool) (bool, error)
}

type publishPrompt struct {
	input     *bufio.Reader
	output    io.Writer
	assumeYes bool
}

func newPublishPrompt(input io.Reader, output io.Writer, assumeYes bool) publishPrompter {
	return &publishPrompt{
		input:     bufio.NewReader(input),
		output:    output,
		assumeYes: assumeYes,
	}
}

func (prompt *publishPrompt) Confirm(message string, defaultValue bool) (bool, error) {
	if prompt.assumeYes {
		return true, nil
	}
	if _, err := fmt.Fprintf(prompt.output, "%s [y/N]: ", message); err != nil {
		return false, err
	}
	answer, err := prompt.input.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return false, err
	}
	answer = strings.TrimSpace(answer)
	if answer == "" {
		return defaultValue, nil
	}
	switch strings.ToLower(answer) {
	case "y", "yes", "true", "1":
		return true, nil
	case "n", "no", "false", "0":
		return false, nil
	default:
		return defaultValue, nil
	}
}

func checkPublishBindMounts(project *types.Project, prompt publishPrompter) error {
	findings := map[string][]types.ServiceVolumeConfig{}
	for _, service := range project.Services {
		for _, volume := range service.Volumes {
			if volume.Type == types.VolumeTypeBind {
				findings[service.Name] = append(findings[service.Name], volume)
			}
		}
	}
	if len(findings) == 0 {
		return nil
	}
	var message strings.Builder
	message.WriteString("you are about to publish bind mounts declaration within your OCI artifact.\n")
	message.WriteString("only the bind mount declarations will be added to the OCI artifact (not content)\n")
	message.WriteString("please double check that you are not mounting potential user's sensitive directories or data\n")
	for _, serviceName := range sortedMapKeys(findings) {
		message.WriteString(serviceName)
		message.WriteRune('\n')
		for _, volume := range findings[serviceName] {
			message.WriteString(volume.String())
			message.WriteRune('\n')
		}
	}
	message.WriteString("Are you ok to publish these bind mount declarations?")
	return confirmPublish(prompt, message.String())
}

func checkPublishSensitiveData(project *types.Project, prompt publishPrompter) error {
	detected, err := collectPublishSensitiveData(project)
	if err != nil {
		return err
	}
	if len(detected) == 0 {
		return nil
	}
	var message strings.Builder
	message.WriteString("you are about to publish sensitive data within your OCI artifact.\n")
	message.WriteString("please double check that you are not leaking sensitive data\n")
	for _, finding := range detected {
		message.WriteString(formatPublishSecretFinding(finding))
		message.WriteRune('\n')
	}
	message.WriteString("Are you ok to publish these sensitive data?")
	return confirmPublish(prompt, message.String())
}

func formatPublishSecretFinding(finding secrets.DetectedSecret) string {
	if finding.Key == "" {
		return fmt.Sprintf("%s: detected value redacted", finding.Type)
	}
	return fmt.Sprintf("%s %q: detected value redacted", finding.Type, finding.Key)
}

func collectPublishSensitiveData(project *types.Project) ([]secrets.DetectedSecret, error) {
	scan := scanner.NewDefaultScanner()
	var findings []secrets.DetectedSecret
	for _, file := range project.ComposeFiles {
		reader, err := publishComposeFileAsReader(file)
		if err != nil {
			return nil, err
		}
		fileFindings, err := scan.ScanReader(reader)
		if err != nil {
			return nil, fmt.Errorf("failed to scan compose file %s: %w", file, err)
		}
		findings = append(findings, fileFindings...)
	}
	for _, service := range project.Services {
		for _, envFile := range service.EnvFiles {
			if _, statErr := os.Stat(envFile.Path); statErr != nil {
				if !os.IsNotExist(statErr) {
					return nil, fmt.Errorf("failed to access env file %s: %w", envFile.Path, statErr)
				}
				if envFile.Required {
					return nil, fmt.Errorf("env file %s not found", envFile.Path)
				}
				continue
			}
			fileFindings, err := scan.ScanFile(envFile.Path)
			if err != nil {
				return nil, fmt.Errorf("failed to scan env file %s: %w", envFile.Path, err)
			}
			findings = append(findings, fileFindings...)
		}
	}
	for _, config := range project.Configs {
		if config.File == "" {
			continue
		}
		fileFindings, err := scan.ScanFile(config.File)
		if err != nil {
			return nil, fmt.Errorf("failed to scan config file %s: %w", config.File, err)
		}
		findings = append(findings, fileFindings...)
	}
	for _, secret := range project.Secrets {
		if secret.File == "" {
			continue
		}
		fileFindings, err := scan.ScanFile(secret.File)
		if err != nil {
			return nil, fmt.Errorf("failed to scan secret file %s: %w", secret.File, err)
		}
		findings = append(findings, fileFindings...)
	}
	return findings, nil
}

type envCheckFindings struct {
	services              map[string]*serviceEnvFindings
	configsLiteralContent []string
}

type serviceEnvFindings struct {
	hasEnvFile     bool
	suspiciousKeys map[string]struct{}
}

func (findings *serviceEnvFindings) sortedSuspiciousKeys() []string {
	return sortedMapKeys(findings.suspiciousKeys)
}

func (findings *envCheckFindings) hasEnvFinding() bool {
	for _, service := range findings.services {
		if service.hasEnvFile || len(service.suspiciousKeys) > 0 {
			return true
		}
	}
	return false
}

func checkPublishEnvironmentVariables(project *types.Project, options publishOptions, prompt publishPrompter) error {
	if len(project.ComposeFiles) == 0 {
		return nil
	}
	findings, err := collectEnvCheckFindings(project)
	if err != nil {
		return err
	}
	if !options.withEnv && findings.hasEnvFinding() {
		if err := confirmPublish(prompt, buildEnvPromptMessage(findings.services)); err != nil {
			return err
		}
	}
	if len(findings.configsLiteralContent) > 0 {
		if err := confirmPublish(prompt, buildConfigContentPromptMessage(findings.configsLiteralContent)); err != nil {
			return err
		}
	}
	return nil
}

func collectEnvCheckFindings(project *types.Project) (*envCheckFindings, error) {
	findings := &envCheckFindings{services: map[string]*serviceEnvFindings{}}
	literalConfigs := map[string]struct{}{}
	detector := keyword.NewDetector("0")

	seen := map[string]struct{}{}
	queue := append([]string(nil), project.ComposeFiles...)
	for len(queue) > 0 {
		file := queue[0]
		queue = queue[1:]
		if _, ok := seen[file]; ok {
			continue
		}
		seen[file] = struct{}{}

		data, err := os.ReadFile(file)
		if err != nil {
			return nil, fmt.Errorf("failed to open compose file %s: %w", file, err)
		}
		var doc yaml.Node
		if err := yaml.Unmarshal(data, &doc); err != nil {
			return nil, fmt.Errorf("failed to load compose file %s: %w", file, err)
		}
		root := documentRoot(&doc)
		if root == nil {
			continue
		}

		services := mappingValue(root, "services")
		for _, serviceName := range sortedMappingKeys(services) {
			service := mappingEntry(services, serviceName)
			recordServiceEnvFindings(findings.services, detector, serviceName, service)
			if parent := localExtendsParent(file, service); parent != "" {
				queue = append(queue, parent)
			}
		}
		configs := mappingValue(root, "configs")
		for _, name := range sortedMappingKeys(configs) {
			config := mappingEntry(configs, name)
			content := mappingScalar(config, "content")
			if content != "" && configContentLooksLiteral(content, detector) {
				literalConfigs[name] = struct{}{}
			}
		}
	}

	if len(literalConfigs) > 0 {
		findings.configsLiteralContent = sortedMapKeys(literalConfigs)
	}
	return findings, nil
}

func recordServiceEnvFindings(
	services map[string]*serviceEnvFindings,
	detector secrets.Detector,
	serviceName string,
	service *yaml.Node,
) {
	envValues := serviceEnvironmentValues(service)
	hits, _ := detector.ScanMap(envValues)
	hasEnvFile := serviceEnvFileDeclared(service)
	if len(hits) == 0 && !hasEnvFile {
		return
	}

	findings := services[serviceName]
	if findings == nil {
		findings = &serviceEnvFindings{suspiciousKeys: map[string]struct{}{}}
		services[serviceName] = findings
	}
	if hasEnvFile {
		findings.hasEnvFile = true
	}
	for _, hit := range hits {
		findings.suspiciousKeys[hit.Key] = struct{}{}
	}
}

func configContentLooksLiteral(content string, detector secrets.Detector) bool {
	hits, _ := detector.ScanMap(map[string]string{"password": replaceDollarEscape(content)})
	return len(hits) > 0
}

func replaceDollarEscape(value string) string {
	return strings.ReplaceAll(value, "$$", "X")
}

func serviceEnvironmentValues(service *yaml.Node) map[string]string {
	values := map[string]string{}
	environment := mappingValue(service, "environment")
	if environment == nil {
		return values
	}
	switch environment.Kind {
	case yaml.MappingNode:
		for index := 0; index < len(environment.Content); index += 2 {
			key := environment.Content[index]
			value := environment.Content[index+1]
			if key.Kind != yaml.ScalarNode || value.Kind != yaml.ScalarNode {
				continue
			}
			values[key.Value] = replaceDollarEscape(value.Value)
		}
	case yaml.SequenceNode:
		for _, item := range environment.Content {
			if item.Kind != yaml.ScalarNode {
				continue
			}
			key, value, ok := strings.Cut(item.Value, "=")
			if !ok || key == "" {
				continue
			}
			values[key] = replaceDollarEscape(value)
		}
	}
	return values
}

func serviceEnvFileDeclared(service *yaml.Node) bool {
	envFile := mappingValue(service, "env_file")
	if envFile == nil {
		return false
	}
	switch envFile.Kind {
	case yaml.ScalarNode:
		return envFile.Value != ""
	case yaml.SequenceNode:
		return len(envFile.Content) > 0
	case yaml.MappingNode:
		return len(envFile.Content) > 0
	default:
		return false
	}
}

func localExtendsParent(currentFile string, service *yaml.Node) string {
	extends := mappingValue(service, "extends")
	if extends == nil {
		return ""
	}
	var parent string
	switch extends.Kind {
	case yaml.ScalarNode:
		parent = extends.Value
	case yaml.MappingNode:
		parent = mappingScalar(extends, "file")
	}
	if parent == "" || isRemotePublishResource(parent) {
		return ""
	}
	if !filepath.IsAbs(parent) {
		parent = filepath.Join(filepath.Dir(currentFile), parent)
	}
	if _, err := os.Stat(parent); err != nil {
		return ""
	}
	return parent
}

func buildEnvPromptMessage(services map[string]*serviceEnvFindings) string {
	var message strings.Builder
	message.WriteString("you are about to publish env-related declarations within your OCI artifact.\n")
	message.WriteString("env_file paths and literal values for sensitive-looking keys are embedded as-is in the published YAML;\n")
	message.WriteString("interpolated values like \"${VAR}\" are kept symbolic and have already been excluded.\n")
	for _, name := range sortedMapKeys(services) {
		findings := services[name]
		if findings.hasEnvFile {
			fmt.Fprintf(&message, "  service %q: env_file declared\n", name)
		}
		if keys := findings.sortedSuspiciousKeys(); len(keys) > 0 {
			quoted := make([]string, len(keys))
			for index, key := range keys {
				quoted[index] = fmt.Sprintf("%q", key)
			}
			fmt.Fprintf(&message, "  service %q: literal value for %s\n", name, strings.Join(quoted, ", "))
		}
	}
	message.WriteString("Use --with-env to silence this prompt and always publish env declarations.\n")
	message.WriteString("Are you ok to publish these env declarations?")
	return message.String()
}

func buildConfigContentPromptMessage(configs []string) string {
	var message strings.Builder
	message.WriteString("you are about to publish literal inline config content within your OCI artifact.\n")
	for _, name := range configs {
		fmt.Fprintf(&message, "  config %q\n", name)
	}
	message.WriteString("Are you ok to publish these config contents?")
	return message.String()
}

func confirmPublish(prompt publishPrompter, message string) error {
	ok, err := prompt.Confirm(message, false)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("publish canceled")
	}
	return nil
}

func publishComposeFileAsReader(file string) (io.Reader, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, fmt.Errorf("failed to open compose file %s: %w", file, err)
	}
	return bytes.NewBuffer(data), nil
}

func documentRoot(doc *yaml.Node) *yaml.Node {
	if doc == nil || len(doc.Content) == 0 || doc.Content[0].Kind != yaml.MappingNode {
		return nil
	}
	return doc.Content[0]
}

func sortedMappingKeys(root *yaml.Node) []string {
	if root == nil || root.Kind != yaml.MappingNode {
		return nil
	}
	keys := make([]string, 0, len(root.Content)/2)
	for index := 0; index < len(root.Content); index += 2 {
		key := root.Content[index]
		if key.Kind == yaml.ScalarNode {
			keys = append(keys, key.Value)
		}
	}
	sort.Strings(keys)
	return keys
}

func mappingEntry(root *yaml.Node, key string) *yaml.Node {
	if root == nil || root.Kind != yaml.MappingNode {
		return nil
	}
	for index := 0; index < len(root.Content); index += 2 {
		candidate := root.Content[index]
		if candidate.Kind == yaml.ScalarNode && candidate.Value == key {
			return root.Content[index+1]
		}
	}
	return nil
}

func mappingScalar(root *yaml.Node, key string) string {
	value := mappingValue(root, key)
	if value == nil || value.Kind != yaml.ScalarNode {
		return ""
	}
	return value.Value
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

func publishApplicationIndex(
	ctx context.Context,
	resolver remotes.Resolver,
	project *types.Project,
	named reference.Named,
	composeDescriptor spec.Descriptor,
	copier publishImageCopier,
) (spec.Descriptor, error) {
	application, err := createPublishApplicationIndex(ctx, resolver, project, named, composeDescriptor, copier)
	if err != nil {
		return spec.Descriptor{}, err
	}
	if err := composeOCI.Push(ctx, resolver, reference.TrimNamed(named), application); err != nil {
		return spec.Descriptor{}, err
	}
	return application, nil
}

func createPublishApplicationIndex(
	ctx context.Context,
	resolver remotes.Resolver,
	project *types.Project,
	named reference.Named,
	composeDescriptor spec.Descriptor,
	copier publishImageCopier,
) (spec.Descriptor, error) {
	if copier == nil {
		copier = composeOCI.Copy
	}
	manifests := make([]spec.Descriptor, 0, len(project.Services))
	for _, serviceName := range sortedMapKeys(project.Services) {
		service := project.Services[serviceName]
		if strings.TrimSpace(service.Image) == "" {
			return spec.Descriptor{}, fmt.Errorf("publish --app requires service %q to define an image", serviceName)
		}
		image, err := reference.ParseDockerRef(service.Image)
		if err != nil {
			return spec.Descriptor{}, fmt.Errorf("invalid image for service %q: %w", serviceName, err)
		}
		manifest, err := copier(ctx, resolver, image, named)
		if err != nil {
			return spec.Descriptor{}, fmt.Errorf("failed to copy image for service %q: %w", serviceName, err)
		}
		manifests = append(manifests, manifest)
	}
	return composeOCI.DescriptorForApplicationIndex(composeDescriptor, manifests)
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
