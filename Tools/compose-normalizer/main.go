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
	"sort"
	"strings"
	"time"

	"github.com/compose-spec/compose-go/v2/cli"
	"github.com/compose-spec/compose-go/v2/dotenv"
	"github.com/compose-spec/compose-go/v2/template"
	"github.com/compose-spec/compose-go/v2/types"
)

func init() {
	dotenv.RegisterFormat("raw", parseRawEnvFile)
}

func parseRawEnvFile(r io.Reader, filename string, vars map[string]string, lookup func(key string) (string, bool)) error {
	content, err := io.ReadAll(r)
	if err != nil {
		return fmt.Errorf("failed to read %s: %w", filename, err)
	}
	for _, rawLine := range strings.Split(string(content), "\n") {
		line := strings.TrimSuffix(rawLine, "\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		if key == "" {
			return fmt.Errorf("failed to read %s: missing environment variable name", filename)
		}
		if ok {
			vars[key] = value
			continue
		}
		if lookup == nil {
			continue
		}
		if resolved, found := lookup(key); found {
			vars[key] = resolved
		}
	}
	return nil
}

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
	Environment      map[string]string            `json:"environment,omitempty"`
	Profiles         []string                     `json:"profiles,omitempty"`
	Services         map[string]normalizedService `json:"services"`
	Networks         map[string]normalizedNetwork `json:"networks"`
	Volumes          map[string]normalizedVolume  `json:"volumes"`
	Configs          map[string]any               `json:"configs,omitempty"`
	Secrets          map[string]any               `json:"secrets,omitempty"`
	Models           map[string]any               `json:"models,omitempty"`
	Extensions       map[string]any               `json:"extensions,omitempty"`
}

type normalizedVariable struct {
	Name           string `json:"name"`
	Required       bool   `json:"required"`
	DefaultValue   string `json:"defaultValue,omitempty"`
	AlternateValue string `json:"alternateValue,omitempty"`
}

type normalizedEnvFile struct {
	Path     string `json:"path"`
	Required bool   `json:"required"`
	Format   string `json:"format,omitempty"`
}

// normalizedService contains the Compose service fields Swift can either
// orchestrate directly or preserve for config output and runtime gap checks.
type normalizedService struct {
	Name                    string                              `json:"name"`
	Image                   string                              `json:"image,omitempty"`
	Profiles                []string                            `json:"profiles,omitempty"`
	PullPolicy              string                              `json:"pullPolicy,omitempty"`
	Platform                string                              `json:"platform,omitempty"`
	Annotations             map[string]string                   `json:"annotations,omitempty"`
	Attach                  *bool                               `json:"attach,omitempty"`
	BlkioConfig             *normalizedBlkioConfig              `json:"blkioConfig,omitempty"`
	MacAddress              string                              `json:"macAddress,omitempty"`
	Runtime                 string                              `json:"runtime,omitempty"`
	Cgroup                  string                              `json:"cgroup,omitempty"`
	CgroupParent            string                              `json:"cgroupParent,omitempty"`
	CPUCount                int64                               `json:"cpuCount,omitempty"`
	CPUPercent              float32                             `json:"cpuPercent,omitempty"`
	CPUPeriod               int64                               `json:"cpuPeriod,omitempty"`
	CPUQuota                int64                               `json:"cpuQuota,omitempty"`
	CPURealtimePeriod       int64                               `json:"cpuRealtimePeriod,omitempty"`
	CPURealtimeRuntime      int64                               `json:"cpuRealtimeRuntime,omitempty"`
	CPUSet                  string                              `json:"cpuset,omitempty"`
	CPUShares               int64                               `json:"cpuShares,omitempty"`
	Develop                 *normalizedDevelop                  `json:"develop,omitempty"`
	UnsupportedDeployFields []string                            `json:"unsupportedDeployFields,omitempty"`
	DeployMode              string                              `json:"deployMode,omitempty"`
	DeployLabels            map[string]string                   `json:"deployLabels,omitempty"`
	DeployUpdateDelayNanos  int64                               `json:"deployUpdateDelayNanoseconds,omitempty"`
	DeployRestartPolicy     *normalizedDeployRestartPolicy      `json:"deployRestartPolicy,omitempty"`
	Build                   *normalizedBuild                    `json:"build,omitempty"`
	Command                 []string                            `json:"command,omitempty"`
	Entrypoint              []string                            `json:"entrypoint,omitempty"`
	Provider                *normalizedProvider                 `json:"provider,omitempty"`
	CredentialSpec          *types.CredentialSpecConfig         `json:"credentialSpec,omitempty"`
	DeviceCgroupRules       []string                            `json:"deviceCgroupRules,omitempty"`
	Devices                 []types.DeviceMapping               `json:"devices,omitempty"`
	Environment             map[string]*string                  `json:"environment,omitempty"`
	EnvFiles                []normalizedEnvFile                 `json:"envFiles,omitempty"`
	Expose                  []string                            `json:"expose,omitempty"`
	Gpus                    []types.DeviceRequest               `json:"gpus,omitempty"`
	Ports                   []string                            `json:"ports,omitempty"`
	Volumes                 []normalizedMount                   `json:"volumes,omitempty"`
	VolumeDriver            string                              `json:"volumeDriver,omitempty"`
	VolumesFrom             []string                            `json:"volumesFrom,omitempty"`
	Networks                []string                            `json:"networks,omitempty"`
	NetworkAliases          map[string][]string                 `json:"networkAliases,omitempty"`
	NetworkOptions          map[string]normalizedNetworkOptions `json:"networkOptions,omitempty"`
	NetworkMode             string                              `json:"networkMode,omitempty"`
	DependsOn               map[string]normalizedDependency     `json:"dependsOn,omitempty"`
	Links                   []string                            `json:"links,omitempty"`
	ExternalLinks           []string                            `json:"externalLinks,omitempty"`
	Labels                  map[string]string                   `json:"labels,omitempty"`
	LabelFiles              []string                            `json:"labelFiles,omitempty"`
	ContainerName           string                              `json:"containerName,omitempty"`
	Hostname                string                              `json:"hostname,omitempty"`
	DomainName              string                              `json:"domainName,omitempty"`
	WorkingDir              string                              `json:"workingDir,omitempty"`
	User                    string                              `json:"user,omitempty"`
	GroupAdd                []string                            `json:"groupAdd,omitempty"`
	TTY                     bool                                `json:"tty,omitempty"`
	StdinOpen               bool                                `json:"stdinOpen,omitempty"`
	ReadOnly                bool                                `json:"readOnly,omitempty"`
	Privileged              bool                                `json:"privileged,omitempty"`
	Restart                 string                              `json:"restart,omitempty"`
	Init                    *bool                               `json:"init,omitempty"`
	Scale                   *int                                `json:"scale,omitempty"`
	Logging                 any                                 `json:"logging,omitempty"`
	LogDriver               string                              `json:"logDriver,omitempty"`
	LogOptions              map[string]string                   `json:"logOptions,omitempty"`
	StorageOptions          map[string]string                   `json:"storageOptions,omitempty"`
	UseAPISocket            bool                                `json:"useAPISocket,omitempty"`
	Ipc                     string                              `json:"ipc,omitempty"`
	Isolation               string                              `json:"isolation,omitempty"`
	Tmpfs                   []string                            `json:"tmpfs,omitempty"`
	DNS                     []string                            `json:"dns,omitempty"`
	DNSSearch               []string                            `json:"dnsSearch,omitempty"`
	DNSOptions              []string                            `json:"dnsOptions,omitempty"`
	ExtraHosts              []string                            `json:"extraHosts,omitempty"`
	CapAdd                  []string                            `json:"capAdd,omitempty"`
	CapDrop                 []string                            `json:"capDrop,omitempty"`
	SecurityOpt             []string                            `json:"securityOpt,omitempty"`
	MemLimit                string                              `json:"memLimit,omitempty"`
	MemReservation          string                              `json:"memReservation,omitempty"`
	MemSwapLimit            string                              `json:"memSwapLimit,omitempty"`
	MemSwappiness           string                              `json:"memSwappiness,omitempty"`
	Models                  map[string]normalizedServiceModel   `json:"models,omitempty"`
	OomKillDisable          bool                                `json:"oomKillDisable,omitempty"`
	OomScoreAdj             int64                               `json:"oomScoreAdj,omitempty"`
	PidsLimit               int64                               `json:"pidsLimit,omitempty"`
	CPUS                    string                              `json:"cpus,omitempty"`
	ShmSize                 string                              `json:"shmSize,omitempty"`
	Ulimits                 []string                            `json:"ulimits,omitempty"`
	Pid                     string                              `json:"pid,omitempty"`
	Sysctls                 map[string]string                   `json:"sysctls,omitempty"`
	StopSignal              string                              `json:"stopSignal,omitempty"`
	StopGracePeriodSeconds  *int64                              `json:"stopGracePeriodSeconds,omitempty"`
	PostStart               []normalizedServiceHook             `json:"postStart,omitempty"`
	PreStop                 []normalizedServiceHook             `json:"preStop,omitempty"`
	UserNSMode              string                              `json:"usernsMode,omitempty"`
	Uts                     string                              `json:"uts,omitempty"`
	Healthcheck             any                                 `json:"healthcheck,omitempty"`
	Configs                 any                                 `json:"configs,omitempty"`
	Secrets                 any                                 `json:"secrets,omitempty"`
	Extensions              map[string]any                      `json:"extensions,omitempty"`
}

// normalizedBlkioConfig preserves Compose block I/O controls for the runtime
// CLI shape proposed in apple/container#1595.
type normalizedBlkioConfig struct {
	Weight          *uint16                    `json:"weight,omitempty"`
	WeightDevice    []normalizedWeightDevice   `json:"weightDevice,omitempty"`
	DeviceReadBps   []normalizedThrottleDevice `json:"deviceReadBps,omitempty"`
	DeviceReadIOps  []normalizedThrottleDevice `json:"deviceReadIOps,omitempty"`
	DeviceWriteBps  []normalizedThrottleDevice `json:"deviceWriteBps,omitempty"`
	DeviceWriteIOps []normalizedThrottleDevice `json:"deviceWriteIOps,omitempty"`
}

// normalizedWeightDevice stores one per-device block I/O weight.
type normalizedWeightDevice struct {
	Path   string `json:"path"`
	Weight uint16 `json:"weight"`
}

// normalizedThrottleDevice stores one per-device block I/O throttle.
type normalizedThrottleDevice struct {
	Path string `json:"path"`
	Rate string `json:"rate"`
}

// normalizedDeployRestartPolicy preserves the Compose Deploy restart policy
// fields that Swift maps or rejects against apple/container runtime support.
type normalizedDeployRestartPolicy struct {
	Condition   string  `json:"condition,omitempty"`
	DelayNanos  int64   `json:"delayNanoseconds,omitempty"`
	MaxAttempts *uint64 `json:"maxAttempts,omitempty"`
	WindowNanos int64   `json:"windowNanoseconds,omitempty"`
}

// normalizedProvider records the provider executable and options used by a
// non-container service lifecycle.
type normalizedProvider struct {
	Type    string              `json:"type"`
	Options map[string][]string `json:"options,omitempty"`
}

// normalizedServiceModel records the environment-variable binding requested by
// a service for one top-level Compose model.
type normalizedServiceModel struct {
	EndpointVariable string `json:"endpointVariable,omitempty"`
	ModelVariable    string `json:"modelVariable,omitempty"`
}

// normalizedBuild keeps the build fields needed to call `container build`.
type normalizedBuild struct {
	Context            string                  `json:"context,omitempty"`
	Dockerfile         string                  `json:"dockerfile,omitempty"`
	DockerfileInline   string                  `json:"dockerfileInline,omitempty"`
	AdditionalContexts map[string]string       `json:"additionalContexts,omitempty"`
	Args               map[string]string       `json:"args,omitempty"`
	CacheFrom          []string                `json:"cacheFrom,omitempty"`
	CacheTo            []string                `json:"cacheTo,omitempty"`
	Entitlements       []string                `json:"entitlements,omitempty"`
	ExtraHosts         []string                `json:"extraHosts,omitempty"`
	Isolation          string                  `json:"isolation,omitempty"`
	Labels             map[string]string       `json:"labels,omitempty"`
	Network            string                  `json:"network,omitempty"`
	Privileged         bool                    `json:"privileged,omitempty"`
	Secrets            []normalizedBuildSecret `json:"secrets,omitempty"`
	ShmSize            string                  `json:"shmSize,omitempty"`
	SSH                []string                `json:"ssh,omitempty"`
	Target             string                  `json:"target,omitempty"`
	NoCache            bool                    `json:"noCache,omitempty"`
	Pull               bool                    `json:"pull,omitempty"`
	Platforms          []string                `json:"platforms,omitempty"`
	Tags               []string                `json:"tags,omitempty"`
	Ulimits            []string                `json:"ulimits,omitempty"`
	Provenance         string                  `json:"provenance,omitempty"`
	SBOM               string                  `json:"sbom,omitempty"`
	UnsupportedFields  []string                `json:"unsupportedFields,omitempty"`
}

// normalizedBuildSecret contains the apple/container `container build --secret` fields
// that can be safely derived from a Compose top-level secret definition.
type normalizedBuildSecret struct {
	ID          string `json:"id"`
	File        string `json:"file,omitempty"`
	Environment string `json:"environment,omitempty"`
}

// normalizedDevelop preserves Compose Develop Specification data needed by
// Swift validation and watch orchestration.
type normalizedDevelop struct {
	Watch []normalizedWatchTrigger `json:"watch,omitempty"`
}

// normalizedWatchTrigger records one compose-go develop.watch trigger.
type normalizedWatchTrigger struct {
	Path        string                   `json:"path"`
	Action      string                   `json:"action"`
	Target      string                   `json:"target,omitempty"`
	Ignore      []string                 `json:"ignore,omitempty"`
	Include     []string                 `json:"include,omitempty"`
	InitialSync bool                     `json:"initialSync,omitempty"`
	Exec        *normalizedWatchExecHook `json:"exec,omitempty"`
}

// normalizedWatchExecHook records sync+exec metadata without executing it.
type normalizedWatchExecHook struct {
	Command     []string           `json:"command,omitempty"`
	User        string             `json:"user,omitempty"`
	Privileged  bool               `json:"privileged,omitempty"`
	WorkingDir  string             `json:"workingDir,omitempty"`
	Environment map[string]*string `json:"environment,omitempty"`
}

// normalizedServiceHook records lifecycle hook metadata for Swift execution.
type normalizedServiceHook struct {
	Command     []string           `json:"command,omitempty"`
	User        string             `json:"user,omitempty"`
	Privileged  bool               `json:"privileged,omitempty"`
	WorkingDir  string             `json:"workingDir,omitempty"`
	Environment map[string]*string `json:"environment,omitempty"`
}

// normalizedMount keeps mount data in a compact runtime-oriented shape.
type normalizedMount struct {
	Type               string            `json:"type,omitempty"`
	Source             string            `json:"source,omitempty"`
	Target             string            `json:"target,omitempty"`
	ReadOnly           bool              `json:"readOnly,omitempty"`
	BindCreateHostPath *bool             `json:"bindCreateHostPath,omitempty"`
	BindPropagation    string            `json:"bindPropagation,omitempty"`
	VolumeLabels       map[string]string `json:"volumeLabels,omitempty"`
	TmpfsSize          string            `json:"tmpfsSize,omitempty"`
	TmpfsMode          string            `json:"tmpfsMode,omitempty"`
	Raw                string            `json:"raw,omitempty"`
	UnsupportedFields  []string          `json:"unsupportedFields,omitempty"`
}

// normalizedNetwork contains project-level network metadata.
type normalizedNetwork struct {
	Name              string            `json:"name"`
	External          bool              `json:"external,omitempty"`
	Driver            string            `json:"driver,omitempty"`
	DriverOpts        map[string]string `json:"driverOpts,omitempty"`
	Internal          bool              `json:"internal,omitempty"`
	Labels            map[string]string `json:"labels,omitempty"`
	IPv4Subnet        string            `json:"ipv4Subnet,omitempty"`
	IPv6Subnet        string            `json:"ipv6Subnet,omitempty"`
	UnsupportedFields []string          `json:"unsupportedFields,omitempty"`
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

// normalizedDependency preserves Compose dependency behavior that affects
// startup ordering or requires explicit unsupported-feature checks.
type normalizedDependency struct {
	Condition string `json:"condition,omitempty"`
	Restart   bool   `json:"restart,omitempty"`
	Required  *bool  `json:"required,omitempty"`
}

// normalizedVolume contains project-level volume metadata.
type normalizedVolume struct {
	Name       string            `json:"name"`
	External   bool              `json:"external,omitempty"`
	Driver     string            `json:"driver,omitempty"`
	DriverOpts map[string]string `json:"driverOpts,omitempty"`
	Labels     map[string]string `json:"labels,omitempty"`
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
	var noConsistency bool
	var noEnvResolution bool
	var noInterpolate bool
	var noNormalize bool
	var noPathResolution bool
	var variables bool

	flags := flag.NewFlagSet("compose-normalizer", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Var(&files, "file", "Compose file path. May be repeated.")
	flags.Var(&profiles, "profile", "Compose profile. May be repeated.")
	flags.Var(&envFiles, "env-file", "Environment file. May be repeated.")
	flags.StringVar(&projectName, "project-name", "", "Compose project name.")
	flags.StringVar(&projectDirectory, "project-directory", "", "Project directory.")
	flags.BoolVar(&noConsistency, "no-consistency", false, "Skip model consistency checks.")
	flags.BoolVar(&noEnvResolution, "no-env-resolution", false, "Do not resolve service env files.")
	flags.BoolVar(&noInterpolate, "no-interpolate", false, "Do not interpolate environment variables.")
	flags.BoolVar(&noNormalize, "no-normalize", false, "Do not normalize the compose model.")
	flags.BoolVar(&noPathResolution, "no-path-resolution", false, "Do not resolve relative file paths.")
	flags.BoolVar(&variables, "variables", false, "Print model variables as JSON.")
	if err := flags.Parse(args); err != nil {
		return 2
	}

	loadOptions := projectLoadOptions{
		noConsistency:    noConsistency,
		noEnvResolution:  noEnvResolution,
		noInterpolate:    noInterpolate,
		noNormalize:      noNormalize,
		noPathResolution: noPathResolution,
	}
	var result any
	var err error
	if variables {
		result, err = loadVariables(files, profiles, envFiles, projectName, projectDirectory, loadOptions)
	} else {
		result, err = loadProject(files, profiles, envFiles, projectName, projectDirectory, loadOptions)
	}
	if err != nil {
		fmt.Fprintf(stderr, "compose-normalizer: %v\n", err)
		return 1
	}

	encoder := json.NewEncoder(stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintf(stderr, "compose-normalizer: encode: %v\n", err)
		return 1
	}
	return 0
}

type projectLoadOptions struct {
	noConsistency    bool
	noEnvResolution  bool
	noInterpolate    bool
	noNormalize      bool
	noPathResolution bool
}

// loadProject delegates Compose parsing, merging, interpolation, and profile
// handling to compose-go.
func loadProject(files, profiles, envFiles []string, projectName, projectDirectory string, optionalLoadOptions ...projectLoadOptions) (*normalizedProject, error) {
	loadOptions := firstProjectLoadOptions(optionalLoadOptions)
	if projectDirectory == "" {
		var err error
		projectDirectory, err = os.Getwd()
		if err != nil {
			return nil, err
		}
	}

	usesDefaultFiles := len(files) == 0
	var options []cli.ProjectOptionsFn
	options = append(options, cli.WithWorkingDirectory(projectDirectory))
	options = append(options, cli.WithOsEnv)
	if len(envFiles) > 0 {
		options = append(options, cli.WithEnvFiles(envFiles...))
	} else {
		options = append(options, cli.WithEnvFiles())
	}
	options = append(options, cli.WithDotEnv)
	if usesDefaultFiles {
		options = append(options, cli.WithConfigFileEnv)
		options = append(options, cli.WithDefaultConfigPath)
	}
	if projectName != "" {
		options = append(options, cli.WithName(projectName))
	}
	if len(profiles) > 0 {
		options = append(options, cli.WithProfiles(profiles))
	}
	options = appendProjectLoadOptions(options, loadOptions)

	projectOptions, err := newProjectOptions(files, projectDirectory, usesDefaultFiles, options...)
	if err != nil {
		return nil, err
	}
	if len(projectOptions.ConfigPaths) == 0 {
		return nil, errors.New("no compose file found")
	}

	project, err := cli.ProjectFromOptions(context.Background(), projectOptions)
	if err != nil {
		return nil, err
	}

	return normalize(project, projectDirectory), nil
}

func loadVariables(files, profiles, envFiles []string, projectName, projectDirectory string, optionalLoadOptions ...projectLoadOptions) ([]normalizedVariable, error) {
	loadOptions := firstProjectLoadOptions(optionalLoadOptions)
	if projectDirectory == "" {
		var err error
		projectDirectory, err = os.Getwd()
		if err != nil {
			return nil, err
		}
	}

	usesDefaultFiles := len(files) == 0
	options := []cli.ProjectOptionsFn{cli.WithWorkingDirectory(projectDirectory), cli.WithOsEnv}
	if len(envFiles) > 0 {
		options = append(options, cli.WithEnvFiles(envFiles...))
	} else {
		options = append(options, cli.WithEnvFiles())
	}
	options = append(options, cli.WithDotEnv)
	if usesDefaultFiles {
		options = append(options, cli.WithConfigFileEnv, cli.WithDefaultConfigPath)
	}
	if projectName != "" {
		options = append(options, cli.WithName(projectName))
	}
	if len(profiles) > 0 {
		options = append(options, cli.WithProfiles(profiles))
	}
	options = appendProjectLoadOptions(options, loadOptions)
	options = append(options, cli.WithInterpolation(false))

	projectOptions, err := newProjectOptions(files, projectDirectory, usesDefaultFiles, options...)
	if err != nil {
		return nil, err
	}
	if len(projectOptions.ConfigPaths) == 0 {
		return nil, errors.New("no compose file found")
	}

	model, err := projectOptions.LoadModel(context.Background())
	if err != nil {
		return nil, err
	}

	extracted := template.ExtractVariables(model, template.DefaultPattern)
	names := make([]string, 0, len(extracted))
	for name := range extracted {
		names = append(names, name)
	}
	sort.Strings(names)

	variables := make([]normalizedVariable, 0, len(names))
	for _, name := range names {
		variable := extracted[name]
		variables = append(variables, normalizedVariable{
			Name:           variable.Name,
			Required:       variable.Required,
			DefaultValue:   variable.DefaultValue,
			AlternateValue: variable.PresenceValue,
		})
	}
	return variables, nil
}

func firstProjectLoadOptions(options []projectLoadOptions) projectLoadOptions {
	if len(options) == 0 {
		return projectLoadOptions{}
	}
	return options[0]
}

func appendProjectLoadOptions(options []cli.ProjectOptionsFn, loadOptions projectLoadOptions) []cli.ProjectOptionsFn {
	options = append(options,
		cli.WithConsistency(!loadOptions.noConsistency),
		cli.WithInterpolation(!loadOptions.noInterpolate),
		cli.WithNormalization(!loadOptions.noNormalize),
		cli.WithResolvedPaths(!loadOptions.noPathResolution),
	)
	if loadOptions.noEnvResolution {
		options = append(options, cli.WithoutEnvironmentResolution)
	}
	return options
}

// newProjectOptions applies compose-go options from the Compose project
// directory when default file discovery is active. That keeps COMPOSE_FILE
// paths from .env aligned between installed helpers and source-checkout go run.
func newProjectOptions(files []string, projectDirectory string, usesDefaultFiles bool, options ...cli.ProjectOptionsFn) (*cli.ProjectOptions, error) {
	if !usesDefaultFiles {
		return cli.NewProjectOptions(files, options...)
	}

	previousDirectory, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	if err := os.Chdir(projectDirectory); err != nil {
		return nil, err
	}
	defer func() {
		_ = os.Chdir(previousDirectory)
	}()

	return cli.NewProjectOptions(files, options...)
}

// normalize copies the compose-go project into the stable JSON shape consumed
// by Swift orchestration.
func normalize(project *types.Project, projectDirectory string) *normalizedProject {
	profiles := project.AllServices().GetProfiles()
	sort.Strings(profiles)
	result := &normalizedProject{
		Name:             project.Name,
		WorkingDirectory: projectDirectory,
		ComposeFiles:     append([]string(nil), project.ComposeFiles...),
		Environment:      mapStringValues(project.Environment),
		Profiles:         profiles,
		Services:         map[string]normalizedService{},
		Networks:         map[string]normalizedNetwork{},
		Volumes:          map[string]normalizedVolume{},
	}

	for _, service := range project.Services {
		result.Services[service.Name] = normalizeService(service, project.Secrets)
	}
	for name, network := range project.Networks {
		ipv4Subnet, ipv6Subnet, unsupportedFields := networkIPAMValues(network.Ipam)
		result.Networks[name] = normalizedNetwork{
			Name:              firstNonEmpty(network.Name, name),
			External:          bool(network.External),
			Driver:            network.Driver,
			DriverOpts:        mapOptions(network.DriverOpts),
			Internal:          network.Internal,
			Labels:            mapLabels(network.Labels),
			IPv4Subnet:        ipv4Subnet,
			IPv6Subnet:        ipv6Subnet,
			UnsupportedFields: unsupportedFields,
		}
	}
	for name, volume := range project.Volumes {
		result.Volumes[name] = normalizedVolume{
			Name:       firstNonEmpty(volume.Name, name),
			External:   bool(volume.External),
			Driver:     volume.Driver,
			DriverOpts: mapOptions(volume.DriverOpts),
			Labels:     mapLabels(volume.Labels),
		}
	}
	if len(project.Configs) > 0 {
		result.Configs = jsonMap(project.Configs)
	}
	if len(project.Secrets) > 0 {
		result.Secrets = jsonMap(project.Secrets)
	}
	if len(project.Models) > 0 {
		result.Models = jsonMap(project.Models)
	}
	if len(project.Extensions) > 0 {
		result.Extensions = project.Extensions
	}

	return result
}

// normalizeService copies a compose-go service into the stable Swift model.
func normalizeService(service types.ServiceConfig, secrets map[string]types.SecretConfig) normalizedService {
	result := normalizedService{
		Name:                    service.Name,
		Image:                   service.Image,
		Profiles:                append([]string(nil), service.Profiles...),
		PullPolicy:              service.PullPolicy,
		Platform:                service.Platform,
		Annotations:             mapMapping(service.Annotations),
		Attach:                  service.Attach,
		BlkioConfig:             blkioConfigValue(service.BlkioConfig),
		MacAddress:              service.MacAddress,
		Runtime:                 service.Runtime,
		Cgroup:                  service.Cgroup,
		CgroupParent:            service.CgroupParent,
		CPUCount:                service.CPUCount,
		CPUPercent:              service.CPUPercent,
		CPUPeriod:               service.CPUPeriod,
		CPUQuota:                service.CPUQuota,
		CPURealtimePeriod:       service.CPURTPeriod,
		CPURealtimeRuntime:      service.CPURTRuntime,
		CPUSet:                  service.CPUSet,
		CPUShares:               service.CPUShares,
		Develop:                 developValues(service.Develop),
		UnsupportedDeployFields: unsupportedDeployFields(service.Deploy),
		DeployMode:              deployMode(service.Deploy),
		DeployLabels:            deployLabels(service.Deploy),
		DeployUpdateDelayNanos:  deployUpdateDelayNanoseconds(service.Deploy),
		DeployRestartPolicy:     deployRestartPolicyValue(service.Deploy),
		Command:                 shellCommandValues(service.Command),
		Entrypoint:              shellCommandValues(service.Entrypoint),
		Provider:                providerValue(service.Provider),
		CredentialSpec:          service.CredentialSpec,
		DeviceCgroupRules:       append([]string(nil), service.DeviceCgroupRules...),
		Devices:                 append([]types.DeviceMapping(nil), service.Devices...),
		Environment:             mapEnvironment(service.Environment),
		EnvFiles:                envFileValues(service.EnvFiles),
		Expose:                  append([]string(nil), service.Expose...),
		Gpus:                    append([]types.DeviceRequest(nil), service.Gpus...),
		Ports:                   portValues(service.Ports),
		Volumes:                 mountValues(service.Volumes),
		VolumeDriver:            service.VolumeDriver,
		VolumesFrom:             append([]string(nil), service.VolumesFrom...),
		Networks:                networkValues(service.Networks),
		NetworkAliases:          networkAliasValues(service.Networks),
		NetworkOptions:          networkOptionValues(service.Networks),
		NetworkMode:             service.NetworkMode,
		DependsOn:               dependsOnValues(service.DependsOn),
		Links:                   append([]string(nil), service.Links...),
		ExternalLinks:           append([]string(nil), service.ExternalLinks...),
		Labels:                  mapLabels(service.Labels),
		LabelFiles:              append([]string(nil), service.LabelFiles...),
		ContainerName:           service.ContainerName,
		Hostname:                service.Hostname,
		DomainName:              service.DomainName,
		WorkingDir:              service.WorkingDir,
		User:                    service.User,
		GroupAdd:                append([]string(nil), service.GroupAdd...),
		TTY:                     service.Tty,
		StdinOpen:               service.StdinOpen,
		ReadOnly:                service.ReadOnly,
		Privileged:              service.Privileged,
		Restart:                 service.Restart,
		Init:                    service.Init,
		Scale:                   serviceScale(service),
		Logging:                 service.Logging,
		LogDriver:               service.LogDriver,
		LogOptions:              mapStringMap(service.LogOpt),
		StorageOptions:          mapStringMap(service.StorageOpt),
		UseAPISocket:            service.UseAPISocket,
		Ipc:                     service.Ipc,
		Isolation:               service.Isolation,
		Tmpfs:                   append([]string(nil), service.Tmpfs...),
		DNS:                     append([]string(nil), service.DNS...),
		DNSSearch:               append([]string(nil), service.DNSSearch...),
		DNSOptions:              append([]string(nil), service.DNSOpts...),
		ExtraHosts:              service.ExtraHosts.AsList(":"),
		CapAdd:                  append([]string(nil), service.CapAdd...),
		CapDrop:                 append([]string(nil), service.CapDrop...),
		SecurityOpt:             append([]string(nil), service.SecurityOpt...),
		MemLimit:                firstNonEmpty(unitBytesValue(service.MemLimit), deployLimitMemory(service.Deploy)),
		MemReservation:          unitBytesValue(service.MemReservation),
		MemSwapLimit:            unitBytesValue(service.MemSwapLimit),
		MemSwappiness:           unitBytesValue(service.MemSwappiness),
		Models:                  serviceModelValues(service.Models),
		OomKillDisable:          service.OomKillDisable,
		OomScoreAdj:             service.OomScoreAdj,
		PidsLimit:               service.PidsLimit,
		CPUS:                    firstNonEmpty(cpusValue(service.CPUS), deployLimitCPUS(service.Deploy)),
		ShmSize:                 unitBytesValue(service.ShmSize),
		Ulimits:                 ulimitValues(service.Ulimits),
		Pid:                     service.Pid,
		Sysctls:                 mapMapping(service.Sysctls),
		StopSignal:              service.StopSignal,
		StopGracePeriodSeconds:  durationSeconds(service.StopGracePeriod),
		PostStart:               serviceHookValues(service.PostStart),
		PreStop:                 serviceHookValues(service.PreStop),
		UserNSMode:              service.UserNSMode,
		Uts:                     service.Uts,
	}
	if service.Build != nil {
		buildSecrets, unsupportedSecrets := buildSecretValues(service.Build, secrets)
		result.Build = &normalizedBuild{
			Context:            service.Build.Context,
			Dockerfile:         service.Build.Dockerfile,
			DockerfileInline:   service.Build.DockerfileInline,
			AdditionalContexts: mapMapping(service.Build.AdditionalContexts),
			Args:               buildArgs(service.Build.Args),
			CacheFrom:          append([]string(nil), service.Build.CacheFrom...),
			CacheTo:            append([]string(nil), service.Build.CacheTo...),
			Entitlements:       append([]string(nil), service.Build.Entitlements...),
			ExtraHosts:         hostListValues(service.Build.ExtraHosts, "="),
			Isolation:          service.Build.Isolation,
			Labels:             mapLabels(service.Build.Labels),
			Network:            service.Build.Network,
			Privileged:         service.Build.Privileged,
			Secrets:            buildSecrets,
			ShmSize:            unitBytesValue(service.Build.ShmSize),
			SSH:                buildSSHValues(service.Build.SSH),
			Target:             service.Build.Target,
			NoCache:            service.Build.NoCache,
			Pull:               service.Build.Pull,
			Platforms:          append([]string(nil), service.Build.Platforms...),
			Tags:               append([]string(nil), service.Build.Tags...),
			Ulimits:            ulimitValues(service.Build.Ulimits),
			Provenance:         service.Build.Provenance,
			SBOM:               service.Build.SBOM,
			UnsupportedFields:  unsupportedBuildFields(service.Build, unsupportedSecrets),
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

// providerValue copies provider metadata into stable JSON for Swift.
func providerValue(provider *types.ServiceProviderConfig) *normalizedProvider {
	if provider == nil {
		return nil
	}
	return &normalizedProvider{
		Type:    provider.Type,
		Options: mapMultiOptions(provider.Options),
	}
}

// developValues preserves Compose Develop Specification watch triggers for
// Swift command validation and watch orchestration.
func developValues(develop *types.DevelopConfig) *normalizedDevelop {
	if develop == nil {
		return nil
	}
	return &normalizedDevelop{
		Watch: watchTriggerValues(develop.Watch),
	}
}

// watchTriggerValues copies compose-go watch triggers into the stable JSON
// shape consumed by Swift.
func watchTriggerValues(triggers []types.Trigger) []normalizedWatchTrigger {
	if len(triggers) == 0 {
		return nil
	}
	result := make([]normalizedWatchTrigger, 0, len(triggers))
	for _, trigger := range triggers {
		result = append(result, normalizedWatchTrigger{
			Path:        trigger.Path,
			Action:      string(trigger.Action),
			Target:      trigger.Target,
			Ignore:      append([]string(nil), trigger.Ignore...),
			Include:     append([]string(nil), trigger.Include...),
			InitialSync: trigger.InitialSync,
			Exec:        watchExecHookValue(trigger.Exec),
		})
	}
	return result
}

// watchExecHookValue copies sync+exec hook data when a trigger declares it.
func watchExecHookValue(hook types.ServiceHook) *normalizedWatchExecHook {
	if len(hook.Command) == 0 &&
		hook.User == "" &&
		!hook.Privileged &&
		hook.WorkingDir == "" &&
		len(hook.Environment) == 0 {
		return nil
	}
	return &normalizedWatchExecHook{
		Command:     append([]string(nil), hook.Command...),
		User:        hook.User,
		Privileged:  hook.Privileged,
		WorkingDir:  hook.WorkingDir,
		Environment: mappingWithEqualsValues(hook.Environment),
	}
}

// serviceHookValues copies compose-go lifecycle hooks into the stable JSON
// shape consumed by Swift.
func serviceHookValues(hooks []types.ServiceHook) []normalizedServiceHook {
	if len(hooks) == 0 {
		return nil
	}
	result := make([]normalizedServiceHook, 0, len(hooks))
	for _, hook := range hooks {
		result = append(result, normalizedServiceHook{
			Command:     append([]string(nil), hook.Command...),
			User:        hook.User,
			Privileged:  hook.Privileged,
			WorkingDir:  hook.WorkingDir,
			Environment: mappingWithEqualsValues(hook.Environment),
		})
	}
	return result
}

// mappingWithEqualsValues preserves keys with omitted values.
func mappingWithEqualsValues(values types.MappingWithEquals) map[string]*string {
	if len(values) == 0 {
		return nil
	}
	result := map[string]*string{}
	for key, value := range values {
		if value == nil {
			result[key] = nil
			continue
		}
		copied := *value
		result[key] = &copied
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

// unsupportedDeployFields reports deploy fields beyond the local deploy subset
// the orchestrator models or safely preserves as Docker Compose local metadata.
func unsupportedDeployFields(deploy *types.DeployConfig) []string {
	if deploy == nil {
		return nil
	}
	fields := []string{}
	if field := unsupportedDeployModeField(deploy.Mode); field != "" {
		fields = append(fields, field)
	}
	fields = append(fields, unsupportedUpdateConfigFields(deploy.UpdateConfig)...)
	fields = append(fields, unsupportedDeployLimitFields(deploy.Resources.Limits)...)
	fields = append(fields, unsupportedDeployReservationFields(deploy.Resources.Reservations)...)
	return fields
}

// deployMode preserves the Compose Deploy mode so Swift orchestration can
// distinguish long-running services from completion-oriented local jobs.
func deployMode(deploy *types.DeployConfig) string {
	if deploy == nil {
		return ""
	}
	return strings.ToLower(strings.TrimSpace(deploy.Mode))
}

// deployLabels returns Compose deploy service metadata without treating it as
// container labels.
func deployLabels(deploy *types.DeployConfig) map[string]string {
	if deploy == nil {
		return nil
	}
	return mapLabels(deploy.Labels)
}

// deployUpdateDelayNanoseconds returns the Compose stop-first update delay in
// nanoseconds so Swift can apply it between recreated local replicas.
func deployUpdateDelayNanoseconds(deploy *types.DeployConfig) int64 {
	if deploy == nil || deploy.UpdateConfig == nil {
		return 0
	}
	return int64(deploy.UpdateConfig.Delay)
}

// deployRestartPolicyValue returns the Compose Deploy restart policy exactly
// enough for Swift orchestration to map Docker-compatible local semantics.
func deployRestartPolicyValue(deploy *types.DeployConfig) *normalizedDeployRestartPolicy {
	if deploy == nil || deploy.RestartPolicy == nil {
		return nil
	}
	policy := deploy.RestartPolicy
	result := normalizedDeployRestartPolicy{
		Condition: policy.Condition,
	}
	if policy.Delay != nil {
		result.DelayNanos = int64(*policy.Delay)
	}
	if policy.MaxAttempts != nil {
		maxAttempts := *policy.MaxAttempts
		result.MaxAttempts = &maxAttempts
	}
	if policy.Window != nil {
		result.WindowNanos = int64(*policy.Window)
	}
	return &result
}

// unsupportedDeployModeField allows Compose deployment modes that Docker Compose
// local orchestration accepts with the local replica algorithm.
func unsupportedDeployModeField(mode string) string {
	if mode == "" {
		return ""
	}
	normalized := strings.ToLower(mode)
	switch normalized {
	case "replicated", "global", "replicated-job", "global-job":
		return ""
	default:
		return "mode"
	}
}

// appendUnsupportedDeployField records one unsupported deploy field when present.
func appendUnsupportedDeployField(fields *[]string, name string, present bool) {
	if present {
		*fields = append(*fields, name)
	}
}

// unsupportedUpdateConfigFields reports update behavior outside Docker Compose's
// local mode and the stop-first recreation the local orchestrator performs.
func unsupportedUpdateConfigFields(config *types.UpdateConfig) []string {
	if config == nil {
		return nil
	}
	return unsupportedUpdateOrderFields(config.Order)
}

// unsupportedUpdateOrderFields reports update orders that need a different
// recreate boundary from the existing local stop-before-start path.
func unsupportedUpdateOrderFields(order string) []string {
	if order == "" {
		return nil
	}
	if strings.EqualFold(order, "stop-first") {
		return nil
	}
	if strings.EqualFold(order, "start-first") {
		return []string{"update_config.order.start-first"}
	}
	return []string{"update_config.order"}
}

// unsupportedDeployLimitFields reports deploy resource limits that are not
// backed by the local container runtime flags this plugin already maps.
func unsupportedDeployLimitFields(resource *types.Resource) []string {
	if resource == nil {
		return nil
	}
	fields := []string{}
	appendUnsupportedDeployField(&fields, "resources.limits.pids", resource.Pids != 0)
	appendUnsupportedDeployField(&fields, "resources.limits.devices", len(resource.Devices) > 0)
	appendUnsupportedDeployField(&fields, "resources.limits.generic_resources", len(resource.GenericResources) > 0)
	return fields
}

// unsupportedDeployReservationFields reports deploy resource reservations beyond
// the CPU/memory scheduler metadata Docker Compose local mode accepts.
func unsupportedDeployReservationFields(resource *types.Resource) []string {
	if resource == nil {
		return nil
	}
	fields := []string{}
	appendUnsupportedDeployField(&fields, "resources.reservations.pids", resource.Pids != 0)
	appendUnsupportedDeployField(&fields, "resources.reservations.devices", len(resource.Devices) > 0)
	appendUnsupportedDeployField(&fields, "resources.reservations.generic_resources", len(resource.GenericResources) > 0)
	return fields
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

// serviceModelValues preserves service model binding options from compose-go.
func serviceModelValues(models map[string]*types.ServiceModelConfig) map[string]normalizedServiceModel {
	if len(models) == 0 {
		return nil
	}
	result := make(map[string]normalizedServiceModel, len(models))
	for name, model := range models {
		if model == nil {
			result[name] = normalizedServiceModel{}
			continue
		}
		result[name] = normalizedServiceModel{
			EndpointVariable: model.EndpointVariable,
			ModelVariable:    model.ModelVariable,
		}
	}
	return result
}

// mapStringValues copies string maps while preserving nil for absent maps.
func mapStringValues(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]string, len(values))
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

// envFileValues extracts normalized env-file metadata in compose-go order.
func envFileValues(envFiles []types.EnvFile) []normalizedEnvFile {
	if len(envFiles) == 0 {
		return nil
	}
	result := make([]normalizedEnvFile, 0, len(envFiles))
	for _, envFile := range envFiles {
		result = append(result, normalizedEnvFile{
			Path:     envFile.Path,
			Required: bool(envFile.Required),
			Format:   envFile.Format,
		})
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
		if port.HostIP != "" {
			value := formatPortHostPrefix(port.HostIP) + ":" + target
			if protocol != "tcp" {
				value += "/" + protocol
			}
			return value
		}
		if protocol == "tcp" {
			return target
		}
		return target + "/" + protocol
	}

	value := formatPortHostPrefix(port.HostIP) + published + ":" + target
	if protocol != "tcp" {
		value += "/" + protocol
	}
	return value
}

// formatPortHostPrefix returns the Docker-style host portion for a publish
// string, bracketing IPv6 literals so colon-delimited ports stay parseable.
func formatPortHostPrefix(hostIP string) string {
	if hostIP == "" {
		return ""
	}
	if strings.Contains(hostIP, ":") && !strings.HasPrefix(hostIP, "[") {
		return "[" + hostIP + "]:"
	}
	return hostIP + ":"
}

// mountValues converts compose-go volume configs to normalized mount records.
func mountValues(volumes []types.ServiceVolumeConfig) []normalizedMount {
	if len(volumes) == 0 {
		return nil
	}
	result := make([]normalizedMount, 0, len(volumes))
	for _, volume := range volumes {
		result = append(result, normalizedMount{
			Type:               volume.Type,
			Source:             volume.Source,
			Target:             volume.Target,
			ReadOnly:           volume.ReadOnly,
			BindCreateHostPath: bindCreateHostPathValue(volume),
			BindPropagation:    bindPropagationValue(volume),
			VolumeLabels:       volumeLabelsValue(volume),
			TmpfsSize:          tmpfsSizeValue(volume),
			TmpfsMode:          tmpfsModeValue(volume),
			UnsupportedFields:  unsupportedMountFields(volume),
		})
	}
	return result
}

// bindCreateHostPathValue preserves Compose bind mount source creation policy.
func bindCreateHostPathValue(volume types.ServiceVolumeConfig) *bool {
	if volume.Type != "bind" || volume.Bind == nil {
		return nil
	}
	value := bool(volume.Bind.CreateHostPath)
	return &value
}

// bindPropagationValue preserves supported Docker bind propagation semantics.
func bindPropagationValue(volume types.ServiceVolumeConfig) string {
	if volume.Type != "bind" || volume.Bind == nil {
		return ""
	}
	return volume.Bind.Propagation
}

// volumeLabelsValue preserves long-form service volume labels for config
// output and for anonymous volume creation parity.
func volumeLabelsValue(volume types.ServiceVolumeConfig) map[string]string {
	if volume.Type != "volume" || volume.Volume == nil || len(volume.Volume.Labels) == 0 {
		return nil
	}
	return map[string]string(volume.Volume.Labels)
}

// tmpfsSizeValue returns the normalized byte count for long-form tmpfs mounts.
func tmpfsSizeValue(volume types.ServiceVolumeConfig) string {
	if volume.Type != "tmpfs" || volume.Tmpfs == nil {
		return ""
	}
	return unitBytesValue(volume.Tmpfs.Size)
}

// tmpfsModeValue returns the normalized octal mode for long-form tmpfs mounts.
func tmpfsModeValue(volume types.ServiceVolumeConfig) string {
	if volume.Type != "tmpfs" || volume.Tmpfs == nil || volume.Tmpfs.Mode == 0 {
		return ""
	}
	return fmt.Sprintf("%04o", volume.Tmpfs.Mode)
}

// unsupportedMountFields reports mount options that the apple/container runtime
// argument shape used by this plugin cannot preserve yet.
func unsupportedMountFields(volume types.ServiceVolumeConfig) []string {
	fields := []string{}
	if volume.Type != "" && volume.Type != "bind" && volume.Type != "volume" && volume.Type != "tmpfs" {
		appendUnsupportedMountField(&fields, "type")
	}
	appendUnsupportedMountFieldWhen(&fields, "consistency", volume.Consistency != "")
	if volume.Bind != nil {
		appendUnsupportedMountFieldWhen(&fields, "bind.selinux", volume.Bind.SELinux != "")
		appendUnsupportedMountFieldWhen(&fields, "bind.recursive", volume.Bind.Recursive != "")
	}
	if volume.Volume != nil {
		appendUnsupportedMountFieldWhen(&fields, "volume.subpath", volume.Volume.Subpath != "")
	}
	if volume.Image != nil {
		appendUnsupportedMountFieldWhen(&fields, "image.subpath", volume.Image.SubPath != "")
	}
	if len(fields) == 0 {
		return nil
	}
	return fields
}

// appendUnsupportedMountField records one unsupported mount field once.
func appendUnsupportedMountField(fields *[]string, name string) {
	for _, field := range *fields {
		if field == name {
			return
		}
	}
	*fields = append(*fields, name)
}

// appendUnsupportedMountFieldWhen records one unsupported mount field when present.
func appendUnsupportedMountFieldWhen(fields *[]string, name string, present bool) {
	if present {
		appendUnsupportedMountField(fields, name)
	}
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

// networkIPAMValues returns the one IPv4 and one IPv6 subnet apple/container can create.
func networkIPAMValues(ipam types.IPAMConfig) (string, string, []string) {
	fields := []string{}
	appendUnsupportedNetworkField(&fields, "ipam.driver", ipam.Driver != "")
	appendUnsupportedNetworkField(&fields, "ipam.options", len(ipam.Options) > 0)
	var ipv4Subnet string
	var ipv6Subnet string
	for _, pool := range ipam.Config {
		if pool == nil {
			continue
		}
		appendUnsupportedNetworkField(&fields, "ipam.config.gateway", pool.Gateway != "")
		appendUnsupportedNetworkField(&fields, "ipam.config.ip_range", pool.IPRange != "")
		appendUnsupportedNetworkField(&fields, "ipam.config.aux_addresses", len(pool.AuxiliaryAddresses) > 0)
		subnet := strings.TrimSpace(pool.Subnet)
		if subnet == "" {
			continue
		}
		if strings.Contains(subnet, ":") {
			if ipv6Subnet != "" {
				appendUnsupportedNetworkField(&fields, "ipam.config.subnet", true)
				continue
			}
			ipv6Subnet = subnet
			continue
		}
		if ipv4Subnet != "" {
			appendUnsupportedNetworkField(&fields, "ipam.config.subnet", true)
			continue
		}
		ipv4Subnet = subnet
	}
	if len(fields) == 0 {
		return ipv4Subnet, ipv6Subnet, nil
	}
	return ipv4Subnet, ipv6Subnet, fields
}

// appendUnsupportedNetworkField records unsupported network metadata once.
func appendUnsupportedNetworkField(fields *[]string, name string, present bool) {
	if !present {
		return
	}
	for _, field := range *fields {
		if field == name {
			return
		}
	}
	*fields = append(*fields, name)
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

// dependsOnValues records dependency metadata for Swift runtime gap checks.
func dependsOnValues(dependsOn types.DependsOnConfig) map[string]normalizedDependency {
	if len(dependsOn) == 0 {
		return nil
	}
	result := map[string]normalizedDependency{}
	for name, dependency := range dependsOn {
		value := normalizedDependency{
			Condition: dependency.Condition,
			Restart:   dependency.Restart,
		}
		if !dependency.Required {
			required := dependency.Required
			value.Required = &required
		}
		result[name] = value
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

// mapMultiOptions copies provider options while preserving repeated values.
func mapMultiOptions(options types.MultiOptions) map[string][]string {
	if len(options) == 0 {
		return nil
	}
	result := map[string][]string{}
	for key, values := range options {
		result[key] = append([]string(nil), values...)
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

// buildSecretValues converts supported Compose build secrets to apple/container build
// secret arguments and reports whether any secret needs unsupported behavior.
func buildSecretValues(build *types.BuildConfig, secrets map[string]types.SecretConfig) ([]normalizedBuildSecret, bool) {
	if build == nil || len(build.Secrets) == 0 {
		return nil, false
	}
	values := []normalizedBuildSecret{}
	unsupported := false
	for _, secret := range build.Secrets {
		id, ok := buildSecretID(secret)
		if !ok {
			unsupported = true
			continue
		}
		// Docker Compose accepts build secret uid/gid/mode metadata, but
		// BuildKit does not implement it. Keep the effective secret source and
		// ignore those metadata fields for build execution parity.
		source, ok := secrets[secret.Source]
		if !ok {
			unsupported = true
			continue
		}
		switch {
		case source.Environment != "":
			values = append(values, normalizedBuildSecret{ID: id, Environment: source.Environment})
		case source.File != "":
			values = append(values, normalizedBuildSecret{ID: id, File: source.File})
		default:
			unsupported = true
		}
	}
	return values, unsupported
}

// buildSecretID returns the BuildKit secret id Compose expects to expose.
func buildSecretID(secret types.ServiceSecretConfig) (string, bool) {
	source := strings.TrimSpace(secret.Source)
	if source == "" {
		return "", false
	}
	target := strings.TrimSpace(secret.Target)
	if target == "" || target == "/run/secrets/"+source {
		return source, true
	}
	const secretsDirectory = "/run/secrets/"
	if strings.HasPrefix(target, secretsDirectory) {
		id := strings.TrimPrefix(target, secretsDirectory)
		return id, id != "" && !strings.Contains(id, "/")
	}
	return target, !strings.Contains(target, "/")
}

// unsupportedBuildFields reports Compose build fields not mapped to container build.
func unsupportedBuildFields(build *types.BuildConfig, unsupportedSecrets bool) []string {
	if build == nil {
		return nil
	}
	fields := []string{}
	appendUnsupportedBuildField(&fields, "secrets", unsupportedSecrets)
	return fields
}

// buildSSHValues encodes Compose build.ssh entries as container build --ssh values.
func buildSSHValues(ssh types.SSHConfig) []string {
	if len(ssh) == 0 {
		return nil
	}
	values := make([]string, 0, len(ssh))
	for _, key := range ssh {
		id := strings.TrimSpace(key.ID)
		if id == "" {
			id = "default"
		}
		path := strings.TrimSpace(key.Path)
		if path == "" {
			values = append(values, id)
			continue
		}
		values = append(values, fmt.Sprintf("%s=%s", id, path))
	}
	sort.Strings(values)
	return values
}

// appendUnsupportedBuildField records one unsupported build field when present.
func appendUnsupportedBuildField(fields *[]string, name string, present bool) {
	if present {
		*fields = append(*fields, name)
	}
}

// blkioConfigValue converts Compose block I/O controls into the Swift wire
// model without resolving host devices. apple/container#1595 owns device
// path/literal validation at runtime.
func blkioConfigValue(config *types.BlkioConfig) *normalizedBlkioConfig {
	if config == nil {
		return nil
	}
	result := normalizedBlkioConfig{
		WeightDevice:    weightDeviceValues(config.WeightDevice),
		DeviceReadBps:   throttleDeviceValues(config.DeviceReadBps),
		DeviceReadIOps:  throttleDeviceValues(config.DeviceReadIOps),
		DeviceWriteBps:  throttleDeviceValues(config.DeviceWriteBps),
		DeviceWriteIOps: throttleDeviceValues(config.DeviceWriteIOps),
	}
	if config.Weight != 0 {
		weight := config.Weight
		result.Weight = &weight
	}
	return &result
}

// weightDeviceValues converts per-device weights while preserving Compose
// order.
func weightDeviceValues(devices []types.WeightDevice) []normalizedWeightDevice {
	if len(devices) == 0 {
		return nil
	}
	result := make([]normalizedWeightDevice, 0, len(devices))
	for _, device := range devices {
		result = append(result, normalizedWeightDevice{
			Path:   device.Path,
			Weight: device.Weight,
		})
	}
	return result
}

// throttleDeviceValues converts per-device byte/iops throttles while
// preserving explicit zero rates.
func throttleDeviceValues(devices []types.ThrottleDevice) []normalizedThrottleDevice {
	if len(devices) == 0 {
		return nil
	}
	result := make([]normalizedThrottleDevice, 0, len(devices))
	for _, device := range devices {
		result = append(result, normalizedThrottleDevice{
			Path: device.Path,
			Rate: fmt.Sprint(int64(device.Rate)),
		})
	}
	return result
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

// nanoCPUsValue formats compose-go deploy NanoCPUs values as container --cpus text.
func nanoCPUsValue(value types.NanoCPUs) string {
	return cpusValue(value.Value())
}

// deployLimitCPUS returns the local CPU limit from deploy.resources.limits.
func deployLimitCPUS(deploy *types.DeployConfig) string {
	if deploy == nil || deploy.Resources.Limits == nil {
		return ""
	}
	return nanoCPUsValue(deploy.Resources.Limits.NanoCPUs)
}

// deployLimitMemory returns the local memory limit from deploy.resources.limits.
func deployLimitMemory(deploy *types.DeployConfig) string {
	if deploy == nil || deploy.Resources.Limits == nil {
		return ""
	}
	return unitBytesValue(deploy.Resources.Limits.MemoryBytes)
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

func hostListValues(hosts types.HostsList, separator string) []string {
	values := hosts.AsList(separator)
	if len(values) == 0 {
		return nil
	}
	sort.Strings(values)
	return values
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
