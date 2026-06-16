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
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/compose-spec/compose-go/v2/cli"
	"github.com/compose-spec/compose-go/v2/types"
)

// stringList records repeatable flag values while preserving input order.
type stringList []string

// String returns the flag display value for repeated string options.
func (s *stringList) String() string {
	if s == nil {
		return ""
	}
	return strings.Join(*s, ",")
}

// Set records one occurrence of a repeatable CLI option.
func (s *stringList) Set(value string) error {
	*s = append(*s, value)
	return nil
}

// normalizedProject is the stable JSON envelope consumed by Swift.
type normalizedProject struct {
	Name             string                       `json:"name"`
	WorkingDirectory string                       `json:"workingDirectory"`
	ComposeFiles     []string                     `json:"composeFiles"`
	Services         map[string]normalizedService `json:"services"`
	Networks         map[string]normalizedNetwork `json:"networks"`
	Volumes          map[string]normalizedVolume  `json:"volumes"`
	Configs          map[string]any               `json:"configs,omitempty"`
	Secrets          map[string]any               `json:"secrets,omitempty"`
	Extensions       map[string]any               `json:"extensions,omitempty"`
}

// normalizedService contains the Compose service fields Swift can either
// orchestrate directly or preserve for config output and runtime gap checks.
type normalizedService struct {
	Name                   string                              `json:"name"`
	Image                  string                              `json:"image,omitempty"`
	PullPolicy             string                              `json:"pullPolicy,omitempty"`
	Platform               string                              `json:"platform,omitempty"`
	Annotations            map[string]string                   `json:"annotations,omitempty"`
	Attach                 *bool                               `json:"attach,omitempty"`
	BlkioConfig            bool                                `json:"blkioConfig,omitempty"`
	MacAddress             string                              `json:"macAddress,omitempty"`
	Runtime                string                              `json:"runtime,omitempty"`
	Cgroup                 string                              `json:"cgroup,omitempty"`
	CgroupParent           string                              `json:"cgroupParent,omitempty"`
	CPUCount               int64                               `json:"cpuCount,omitempty"`
	CPUPercent             float32                             `json:"cpuPercent,omitempty"`
	CPUPeriod              int64                               `json:"cpuPeriod,omitempty"`
	CPUQuota               int64                               `json:"cpuQuota,omitempty"`
	CPURealtimePeriod      int64                               `json:"cpuRealtimePeriod,omitempty"`
	CPURealtimeRuntime     int64                               `json:"cpuRealtimeRuntime,omitempty"`
	CPUSet                 string                              `json:"cpuset,omitempty"`
	CPUShares              int64                               `json:"cpuShares,omitempty"`
	Develop                bool                                `json:"develop,omitempty"`
	Build                  *normalizedBuild                    `json:"build,omitempty"`
	Command                []string                            `json:"command,omitempty"`
	Entrypoint             []string                            `json:"entrypoint,omitempty"`
	CredentialSpec         *types.CredentialSpecConfig         `json:"credentialSpec,omitempty"`
	DeviceCgroupRules      []string                            `json:"deviceCgroupRules,omitempty"`
	Devices                []types.DeviceMapping               `json:"devices,omitempty"`
	Environment            map[string]*string                  `json:"environment,omitempty"`
	EnvFiles               []string                            `json:"envFiles,omitempty"`
	Expose                 []string                            `json:"expose,omitempty"`
	Gpus                   []types.DeviceRequest               `json:"gpus,omitempty"`
	Ports                  []string                            `json:"ports,omitempty"`
	Volumes                []normalizedMount                   `json:"volumes,omitempty"`
	VolumeDriver           string                              `json:"volumeDriver,omitempty"`
	VolumesFrom            []string                            `json:"volumesFrom,omitempty"`
	Networks               []string                            `json:"networks,omitempty"`
	NetworkAliases         map[string][]string                 `json:"networkAliases,omitempty"`
	NetworkOptions         map[string]normalizedNetworkOptions `json:"networkOptions,omitempty"`
	NetworkMode            string                              `json:"networkMode,omitempty"`
	DependsOn              map[string]string                   `json:"dependsOn,omitempty"`
	Links                  []string                            `json:"links,omitempty"`
	ExternalLinks          []string                            `json:"externalLinks,omitempty"`
	Labels                 map[string]string                   `json:"labels,omitempty"`
	LabelFiles             []string                            `json:"labelFiles,omitempty"`
	ContainerName          string                              `json:"containerName,omitempty"`
	Hostname               string                              `json:"hostname,omitempty"`
	DomainName             string                              `json:"domainName,omitempty"`
	WorkingDir             string                              `json:"workingDir,omitempty"`
	User                   string                              `json:"user,omitempty"`
	GroupAdd               []string                            `json:"groupAdd,omitempty"`
	TTY                    bool                                `json:"tty,omitempty"`
	StdinOpen              bool                                `json:"stdinOpen,omitempty"`
	ReadOnly               bool                                `json:"readOnly,omitempty"`
	Privileged             bool                                `json:"privileged,omitempty"`
	Restart                string                              `json:"restart,omitempty"`
	Init                   *bool                               `json:"init,omitempty"`
	Scale                  *int                                `json:"scale,omitempty"`
	Logging                any                                 `json:"logging,omitempty"`
	LogDriver              string                              `json:"logDriver,omitempty"`
	LogOptions             map[string]string                   `json:"logOptions,omitempty"`
	StorageOptions         map[string]string                   `json:"storageOptions,omitempty"`
	UseAPISocket           bool                                `json:"useAPISocket,omitempty"`
	Ipc                    string                              `json:"ipc,omitempty"`
	Isolation              string                              `json:"isolation,omitempty"`
	Tmpfs                  []string                            `json:"tmpfs,omitempty"`
	DNS                    []string                            `json:"dns,omitempty"`
	DNSSearch              []string                            `json:"dnsSearch,omitempty"`
	DNSOptions             []string                            `json:"dnsOptions,omitempty"`
	ExtraHosts             []string                            `json:"extraHosts,omitempty"`
	CapAdd                 []string                            `json:"capAdd,omitempty"`
	CapDrop                []string                            `json:"capDrop,omitempty"`
	SecurityOpt            []string                            `json:"securityOpt,omitempty"`
	MemLimit               string                              `json:"memLimit,omitempty"`
	MemReservation         string                              `json:"memReservation,omitempty"`
	MemSwapLimit           string                              `json:"memSwapLimit,omitempty"`
	MemSwappiness          string                              `json:"memSwappiness,omitempty"`
	OomKillDisable         bool                                `json:"oomKillDisable,omitempty"`
	OomScoreAdj            int64                               `json:"oomScoreAdj,omitempty"`
	PidsLimit              int64                               `json:"pidsLimit,omitempty"`
	CPUS                   string                              `json:"cpus,omitempty"`
	ShmSize                string                              `json:"shmSize,omitempty"`
	Ulimits                []string                            `json:"ulimits,omitempty"`
	Pid                    string                              `json:"pid,omitempty"`
	Sysctls                map[string]string                   `json:"sysctls,omitempty"`
	StopSignal             string                              `json:"stopSignal,omitempty"`
	StopGracePeriodSeconds *int64                              `json:"stopGracePeriodSeconds,omitempty"`
	UserNSMode             string                              `json:"usernsMode,omitempty"`
	Uts                    string                              `json:"uts,omitempty"`
	Healthcheck            any                                 `json:"healthcheck,omitempty"`
	Configs                any                                 `json:"configs,omitempty"`
	Secrets                any                                 `json:"secrets,omitempty"`
	Extensions             map[string]any                      `json:"extensions,omitempty"`
}

// normalizedBuild keeps the build fields needed to call `container build`.
type normalizedBuild struct {
	Context           string            `json:"context,omitempty"`
	Dockerfile        string            `json:"dockerfile,omitempty"`
	Args              map[string]string `json:"args,omitempty"`
	Target            string            `json:"target,omitempty"`
	UnsupportedFields []string          `json:"unsupportedFields,omitempty"`
}

// normalizedMount keeps mount data in a compact runtime-oriented shape.
type normalizedMount struct {
	Type     string `json:"type,omitempty"`
	Source   string `json:"source,omitempty"`
	Target   string `json:"target,omitempty"`
	ReadOnly bool   `json:"readOnly,omitempty"`
	Raw      string `json:"raw,omitempty"`
}

// normalizedNetwork contains project-level network metadata.
type normalizedNetwork struct {
	Name     string            `json:"name"`
	External bool              `json:"external,omitempty"`
	Driver   string            `json:"driver,omitempty"`
	Labels   map[string]string `json:"labels,omitempty"`
}

// normalizedNetworkOptions preserves per-service network attachment settings.
type normalizedNetworkOptions struct {
	DriverOpts      map[string]string `json:"driverOpts,omitempty"`
	GatewayPriority int               `json:"gatewayPriority,omitempty"`
	InterfaceName   string            `json:"interfaceName,omitempty"`
	IPv4Address     string            `json:"ipv4Address,omitempty"`
	IPv6Address     string            `json:"ipv6Address,omitempty"`
	LinkLocalIPs    []string          `json:"linkLocalIPs,omitempty"`
	MacAddress      string            `json:"macAddress,omitempty"`
	Priority        int               `json:"priority,omitempty"`
}

// normalizedVolume contains project-level volume metadata.
type normalizedVolume struct {
	Name     string            `json:"name"`
	External bool              `json:"external,omitempty"`
	Driver   string            `json:"driver,omitempty"`
	Labels   map[string]string `json:"labels,omitempty"`
}

// main exits with the helper status code returned by run.
func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run parses helper flags and writes canonical Compose project JSON.
func run(args []string, stdout io.Writer, stderr io.Writer) int {
	var files stringList
	var profiles stringList
	var envFiles stringList
	var projectName string
	var projectDirectory string

	flags := flag.NewFlagSet("compose-normalizer", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Var(&files, "file", "Compose file path. May be repeated.")
	flags.Var(&profiles, "profile", "Compose profile. May be repeated.")
	flags.Var(&envFiles, "env-file", "Environment file. May be repeated.")
	flags.StringVar(&projectName, "project-name", "", "Compose project name.")
	flags.StringVar(&projectDirectory, "project-directory", "", "Project directory.")
	if err := flags.Parse(args); err != nil {
		return 2
	}

	project, err := loadProject(files, profiles, envFiles, projectName, projectDirectory)
	if err != nil {
		fmt.Fprintf(stderr, "compose-normalizer: %v\n", err)
		return 1
	}

	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(project); err != nil {
		fmt.Fprintf(stderr, "compose-normalizer: encode: %v\n", err)
		return 1
	}
	return 0
}

// loadProject delegates Compose parsing, merging, interpolation, and profile
// handling to compose-go.
func loadProject(files, profiles, envFiles []string, projectName, projectDirectory string) (*normalizedProject, error) {
	if projectDirectory == "" {
		var err error
		projectDirectory, err = os.Getwd()
		if err != nil {
			return nil, err
		}
	}

	if len(files) == 0 {
		files = discoverComposeFiles(projectDirectory)
	}
	if len(files) == 0 {
		return nil, errors.New("no compose file found")
	}

	var options []cli.ProjectOptionsFn
	options = append(options, cli.WithWorkingDirectory(projectDirectory))
	options = append(options, cli.WithOsEnv)
	options = append(options, cli.WithDotEnv)
	if projectName != "" {
		options = append(options, cli.WithName(projectName))
	}
	if len(profiles) > 0 {
		options = append(options, cli.WithProfiles(profiles))
	}
	if len(envFiles) > 0 {
		options = append(options, cli.WithEnvFiles(envFiles...))
	}

	projectOptions, err := cli.NewProjectOptions(files, options...)
	if err != nil {
		return nil, err
	}

	project, err := cli.ProjectFromOptions(context.Background(), projectOptions)
	if err != nil {
		return nil, err
	}

	return normalize(project, projectDirectory), nil
}

// discoverComposeFiles follows Docker Compose's default file discovery order.
func discoverComposeFiles(projectDirectory string) []string {
	candidates := []string{
		"compose.yaml",
		"compose.yml",
		"docker-compose.yaml",
		"docker-compose.yml",
	}
	for _, candidate := range candidates {
		path := filepath.Join(projectDirectory, candidate)
		if _, err := os.Stat(path); err == nil {
			return []string{path}
		}
	}
	return nil
}

// normalize copies the compose-go project into the stable JSON shape consumed
// by Swift orchestration.
func normalize(project *types.Project, projectDirectory string) *normalizedProject {
	result := &normalizedProject{
		Name:             project.Name,
		WorkingDirectory: projectDirectory,
		ComposeFiles:     append([]string(nil), project.ComposeFiles...),
		Services:         map[string]normalizedService{},
		Networks:         map[string]normalizedNetwork{},
		Volumes:          map[string]normalizedVolume{},
	}

	for _, service := range project.Services {
		result.Services[service.Name] = normalizeService(service)
	}
	for name, network := range project.Networks {
		result.Networks[name] = normalizedNetwork{
			Name:     firstNonEmpty(network.Name, name),
			External: bool(network.External),
			Driver:   network.Driver,
			Labels:   mapLabels(network.Labels),
		}
	}
	for name, volume := range project.Volumes {
		result.Volumes[name] = normalizedVolume{
			Name:     firstNonEmpty(volume.Name, name),
			External: bool(volume.External),
			Driver:   volume.Driver,
			Labels:   mapLabels(volume.Labels),
		}
	}
	if len(project.Configs) > 0 {
		result.Configs = jsonMap(project.Configs)
	}
	if len(project.Secrets) > 0 {
		result.Secrets = jsonMap(project.Secrets)
	}
	if len(project.Extensions) > 0 {
		result.Extensions = project.Extensions
	}

	return result
}

// normalizeService copies a compose-go service into the stable Swift model.
func normalizeService(service types.ServiceConfig) normalizedService {
	result := normalizedService{
		Name:                   service.Name,
		Image:                  service.Image,
		PullPolicy:             service.PullPolicy,
		Platform:               service.Platform,
		Annotations:            mapMapping(service.Annotations),
		Attach:                 service.Attach,
		BlkioConfig:            service.BlkioConfig != nil,
		MacAddress:             service.MacAddress,
		Runtime:                service.Runtime,
		Cgroup:                 service.Cgroup,
		CgroupParent:           service.CgroupParent,
		CPUCount:               service.CPUCount,
		CPUPercent:             service.CPUPercent,
		CPUPeriod:              service.CPUPeriod,
		CPUQuota:               service.CPUQuota,
		CPURealtimePeriod:      service.CPURTPeriod,
		CPURealtimeRuntime:     service.CPURTRuntime,
		CPUSet:                 service.CPUSet,
		CPUShares:              service.CPUShares,
		Develop:                service.Develop != nil,
		Command:                shellCommandValues(service.Command),
		Entrypoint:             shellCommandValues(service.Entrypoint),
		CredentialSpec:         service.CredentialSpec,
		DeviceCgroupRules:      append([]string(nil), service.DeviceCgroupRules...),
		Devices:                append([]types.DeviceMapping(nil), service.Devices...),
		Environment:            mapEnvironment(service.Environment),
		EnvFiles:               envFileValues(service.EnvFiles),
		Expose:                 append([]string(nil), service.Expose...),
		Gpus:                   append([]types.DeviceRequest(nil), service.Gpus...),
		Ports:                  portValues(service.Ports),
		Volumes:                mountValues(service.Volumes),
		VolumeDriver:           service.VolumeDriver,
		VolumesFrom:            append([]string(nil), service.VolumesFrom...),
		Networks:               networkValues(service.Networks),
		NetworkAliases:         networkAliasValues(service.Networks),
		NetworkOptions:         networkOptionValues(service.Networks),
		NetworkMode:            service.NetworkMode,
		DependsOn:              dependsOnValues(service.DependsOn),
		Links:                  append([]string(nil), service.Links...),
		ExternalLinks:          append([]string(nil), service.ExternalLinks...),
		Labels:                 mapLabels(service.Labels),
		LabelFiles:             append([]string(nil), service.LabelFiles...),
		ContainerName:          service.ContainerName,
		Hostname:               service.Hostname,
		DomainName:             service.DomainName,
		WorkingDir:             service.WorkingDir,
		User:                   service.User,
		GroupAdd:               append([]string(nil), service.GroupAdd...),
		TTY:                    service.Tty,
		StdinOpen:              service.StdinOpen,
		ReadOnly:               service.ReadOnly,
		Privileged:             service.Privileged,
		Restart:                service.Restart,
		Init:                   service.Init,
		Scale:                  serviceScale(service),
		Logging:                service.Logging,
		LogDriver:              service.LogDriver,
		LogOptions:             mapStringMap(service.LogOpt),
		StorageOptions:         mapStringMap(service.StorageOpt),
		UseAPISocket:           service.UseAPISocket,
		Ipc:                    service.Ipc,
		Isolation:              service.Isolation,
		Tmpfs:                  append([]string(nil), service.Tmpfs...),
		DNS:                    append([]string(nil), service.DNS...),
		DNSSearch:              append([]string(nil), service.DNSSearch...),
		DNSOptions:             append([]string(nil), service.DNSOpts...),
		ExtraHosts:             service.ExtraHosts.AsList(":"),
		CapAdd:                 append([]string(nil), service.CapAdd...),
		CapDrop:                append([]string(nil), service.CapDrop...),
		SecurityOpt:            append([]string(nil), service.SecurityOpt...),
		MemLimit:               unitBytesValue(service.MemLimit),
		MemReservation:         unitBytesValue(service.MemReservation),
		MemSwapLimit:           unitBytesValue(service.MemSwapLimit),
		MemSwappiness:          unitBytesValue(service.MemSwappiness),
		OomKillDisable:         service.OomKillDisable,
		OomScoreAdj:            service.OomScoreAdj,
		PidsLimit:              service.PidsLimit,
		CPUS:                   cpusValue(service.CPUS),
		ShmSize:                unitBytesValue(service.ShmSize),
		Ulimits:                ulimitValues(service.Ulimits),
		Pid:                    service.Pid,
		Sysctls:                mapMapping(service.Sysctls),
		StopSignal:             service.StopSignal,
		StopGracePeriodSeconds: durationSeconds(service.StopGracePeriod),
		UserNSMode:             service.UserNSMode,
		Uts:                    service.Uts,
	}
	if service.Build != nil {
		result.Build = &normalizedBuild{
			Context:           service.Build.Context,
			Dockerfile:        service.Build.Dockerfile,
			Args:              buildArgs(service.Build.Args),
			Target:            service.Build.Target,
			UnsupportedFields: unsupportedBuildFields(service.Build),
		}
	}
	if service.HealthCheck != nil {
		result.Healthcheck = service.HealthCheck
	}
	if len(service.Configs) > 0 {
		result.Configs = service.Configs
	}
	if len(service.Secrets) > 0 {
		result.Secrets = service.Secrets
	}
	if len(service.Extensions) > 0 {
		result.Extensions = service.Extensions
	}
	return result
}

// serviceScale preserves an explicit Compose scale or deploy replica count.
func serviceScale(service types.ServiceConfig) *int {
	if service.Scale != nil {
		return service.Scale
	}
	if service.Deploy != nil && service.Deploy.Replicas != nil {
		scale := int(*service.Deploy.Replicas)
		return &scale
	}
	return nil
}

// jsonMap widens typed compose-go maps so they can be encoded without losing
// extension, config, or secret fields Swift does not yet interpret.
func jsonMap[T any](values map[string]T) map[string]any {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]any, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}

// shellCommandValues copies compose-go shell command slices into ordinary JSON
// arrays while preserving nil for omitted fields.
func shellCommandValues(command types.ShellCommand) []string {
	if command == nil {
		return nil
	}
	return append([]string(nil), command...)
}

// mapEnvironment preserves the difference between KEY and KEY=value entries.
func mapEnvironment(environment types.MappingWithEquals) map[string]*string {
	if len(environment) == 0 {
		return nil
	}
	result := map[string]*string{}
	for key, value := range environment {
		if value == nil {
			result[key] = nil
			continue
		}
		copied := *value
		result[key] = &copied
	}
	return result
}

// envFileValues extracts normalized env-file paths in compose-go order.
func envFileValues(envFiles []types.EnvFile) []string {
	if len(envFiles) == 0 {
		return nil
	}
	result := make([]string, 0, len(envFiles))
	for _, envFile := range envFiles {
		result = append(result, envFile.Path)
	}
	return result
}

// portValues converts structured Compose ports to CLI publish strings.
func portValues(ports []types.ServicePortConfig) []string {
	if len(ports) == 0 {
		return nil
	}
	result := make([]string, 0, len(ports))
	for _, port := range ports {
		result = append(result, formatPort(port))
	}
	return result
}

// formatPort mirrors Docker-style published port text for the runtime CLI.
func formatPort(port types.ServicePortConfig) string {
	target := fmt.Sprint(port.Target)
	protocol := port.Protocol
	if protocol == "" {
		protocol = "tcp"
	}

	published := port.Published
	if published == "" {
		if protocol == "tcp" {
			return target
		}
		return target + "/" + protocol
	}

	hostPrefix := ""
	if port.HostIP != "" {
		hostPrefix = port.HostIP + ":"
	}
	value := hostPrefix + published + ":" + target
	if protocol != "tcp" {
		value += "/" + protocol
	}
	return value
}

// mountValues converts compose-go volume configs to normalized mount records.
func mountValues(volumes []types.ServiceVolumeConfig) []normalizedMount {
	if len(volumes) == 0 {
		return nil
	}
	result := make([]normalizedMount, 0, len(volumes))
	for _, volume := range volumes {
		result = append(result, normalizedMount{
			Type:     volume.Type,
			Source:   volume.Source,
			Target:   volume.Target,
			ReadOnly: volume.ReadOnly,
		})
	}
	return result
}

// networkValues returns deterministic service network names.
func networkValues(networks map[string]*types.ServiceNetworkConfig) []string {
	if len(networks) == 0 {
		return nil
	}
	result := make([]string, 0, len(networks))
	for name := range networks {
		result = append(result, name)
	}
	sort.Strings(result)
	return result
}

// networkAliasValues returns declared aliases keyed by Compose network name.
func networkAliasValues(networks map[string]*types.ServiceNetworkConfig) map[string][]string {
	if len(networks) == 0 {
		return nil
	}
	result := map[string][]string{}
	for name, config := range networks {
		if config == nil || len(config.Aliases) == 0 {
			continue
		}
		result[name] = append([]string(nil), config.Aliases...)
	}
	if len(result) == 0 {
		return nil
	}
	return result
}

// networkOptionValues returns unsupported service network options by network.
func networkOptionValues(networks map[string]*types.ServiceNetworkConfig) map[string]normalizedNetworkOptions {
	if len(networks) == 0 {
		return nil
	}
	result := map[string]normalizedNetworkOptions{}
	for name, config := range networks {
		if config == nil {
			continue
		}
		options := normalizedNetworkOptions{
			DriverOpts:      mapOptions(config.DriverOpts),
			GatewayPriority: config.GatewayPriority,
			InterfaceName:   config.InterfaceName,
			IPv4Address:     config.Ipv4Address,
			IPv6Address:     config.Ipv6Address,
			LinkLocalIPs:    append([]string(nil), config.LinkLocalIPs...),
			MacAddress:      config.MacAddress,
			Priority:        config.Priority,
		}
		if options.hasValues() {
			result[name] = options
		}
	}
	if len(result) == 0 {
		return nil
	}
	return result
}

// hasValues reports whether any attachment option carries Compose data.
func (options normalizedNetworkOptions) hasValues() bool {
	return len(options.DriverOpts) > 0 ||
		options.GatewayPriority != 0 ||
		options.InterfaceName != "" ||
		options.IPv4Address != "" ||
		options.IPv6Address != "" ||
		len(options.LinkLocalIPs) > 0 ||
		options.MacAddress != "" ||
		options.Priority != 0
}

// dependsOnValues records dependency conditions for Swift runtime gap checks.
func dependsOnValues(dependsOn types.DependsOnConfig) map[string]string {
	if len(dependsOn) == 0 {
		return nil
	}
	result := map[string]string{}
	for name, dependency := range dependsOn {
		result[name] = dependency.Condition
	}
	return result
}

// mapLabels copies Compose labels into a regular string map.
func mapLabels(labels types.Labels) map[string]string {
	if len(labels) == 0 {
		return nil
	}
	result := map[string]string{}
	for key, value := range labels {
		result[key] = value
	}
	return result
}

// mapOptions copies Compose driver options into a regular string map.
func mapOptions(options types.Options) map[string]string {
	if len(options) == 0 {
		return nil
	}
	result := map[string]string{}
	for key, value := range options {
		result[key] = value
	}
	return result
}

// mapMapping copies Compose key/value mappings into regular string maps.
func mapMapping(mapping types.Mapping) map[string]string {
	if len(mapping) == 0 {
		return nil
	}
	result := map[string]string{}
	for key, value := range mapping {
		result[key] = value
	}
	return result
}

// mapStringMap copies plain Compose string maps into independent values.
func mapStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := map[string]string{}
	for key, value := range values {
		result[key] = value
	}
	return result
}

// buildArgs prepares Compose build arguments for `container build --build-arg`.
func buildArgs(args types.MappingWithEquals) map[string]string {
	if len(args) == 0 {
		return nil
	}
	result := map[string]string{}
	for key, value := range args {
		if value == nil {
			result[key] = ""
		} else {
			result[key] = *value
		}
	}
	return result
}

// unsupportedBuildFields reports Compose build fields not mapped to container build yet.
func unsupportedBuildFields(build *types.BuildConfig) []string {
	if build == nil {
		return nil
	}
	fields := []string{}
	appendUnsupportedBuildField(&fields, "additional_contexts", len(build.AdditionalContexts) > 0)
	appendUnsupportedBuildField(&fields, "cache_from", len(build.CacheFrom) > 0)
	appendUnsupportedBuildField(&fields, "cache_to", len(build.CacheTo) > 0)
	appendUnsupportedBuildField(&fields, "dockerfile_inline", build.DockerfileInline != "")
	appendUnsupportedBuildField(&fields, "entitlements", len(build.Entitlements) > 0)
	appendUnsupportedBuildField(&fields, "extra_hosts", len(build.ExtraHosts) > 0)
	appendUnsupportedBuildField(&fields, "isolation", build.Isolation != "")
	appendUnsupportedBuildField(&fields, "labels", len(build.Labels) > 0)
	appendUnsupportedBuildField(&fields, "network", build.Network != "")
	appendUnsupportedBuildField(&fields, "no_cache", build.NoCache)
	appendUnsupportedBuildField(&fields, "platforms", len(build.Platforms) > 0)
	appendUnsupportedBuildField(&fields, "privileged", build.Privileged)
	appendUnsupportedBuildField(&fields, "provenance", build.Provenance != "")
	appendUnsupportedBuildField(&fields, "pull", build.Pull)
	appendUnsupportedBuildField(&fields, "sbom", build.SBOM != "")
	appendUnsupportedBuildField(&fields, "secrets", len(build.Secrets) > 0)
	appendUnsupportedBuildField(&fields, "shm_size", unitBytesValue(build.ShmSize) != "")
	appendUnsupportedBuildField(&fields, "ssh", len(build.SSH) > 0)
	appendUnsupportedBuildField(&fields, "tags", len(build.Tags) > 0)
	appendUnsupportedBuildField(&fields, "ulimits", len(build.Ulimits) > 0)
	return fields
}

func appendUnsupportedBuildField(fields *[]string, name string, present bool) {
	if present {
		*fields = append(*fields, name)
	}
}

// unitBytesValue emits byte counts only when Compose supplied a limit.
func unitBytesValue(value types.UnitBytes) string {
	if value == 0 {
		return ""
	}
	return fmt.Sprint(int64(value))
}

// cpusValue formats CPU limits without trailing zero noise.
func cpusValue(value float32) string {
	if value == 0 {
		return ""
	}
	return fmt.Sprintf("%g", value)
}

// durationSeconds converts Compose durations to whole seconds for container stop.
func durationSeconds(duration *types.Duration) *int64 {
	if duration == nil {
		return nil
	}
	value := time.Duration(*duration)
	var seconds int64
	if value > 0 {
		seconds = int64((value + time.Second - 1) / time.Second)
	}
	return &seconds
}

// ulimitValues converts Compose ulimits into container CLI arguments.
func ulimitValues(ulimits map[string]*types.UlimitsConfig) []string {
	if len(ulimits) == 0 {
		return nil
	}
	names := make([]string, 0, len(ulimits))
	for name := range ulimits {
		names = append(names, name)
	}
	sort.Strings(names)

	result := make([]string, 0, len(names))
	for _, name := range names {
		ulimit := ulimits[name]
		if ulimit == nil {
			continue
		}
		if ulimit.Single != 0 {
			result = append(result, fmt.Sprintf("%s=%d", name, ulimit.Single))
			continue
		}
		if ulimit.Hard != 0 && ulimit.Hard != ulimit.Soft {
			result = append(result, fmt.Sprintf("%s=%d:%d", name, ulimit.Soft, ulimit.Hard))
			continue
		}
		result = append(result, fmt.Sprintf("%s=%d", name, ulimit.Soft))
	}
	if len(result) == 0 {
		return nil
	}
	return result
}

// firstNonEmpty selects the first non-empty normalized name candidate.
func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
