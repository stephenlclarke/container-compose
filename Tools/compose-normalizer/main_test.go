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
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/compose-spec/compose-go/v2/types"
)

func TestStringListRecordsRepeatedFlags(t *testing.T) {
	var values stringList
	var nilValues *stringList
	if got := nilValues.String(); got != "" {
		t.Fatalf("nil String() = %q, want empty", got)
	}
	if err := values.Set("compose.yaml"); err != nil {
		t.Fatalf("Set returned error: %v", err)
	}
	if err := values.Set("override.yaml"); err != nil {
		t.Fatalf("Set returned error: %v", err)
	}

	if got, want := values.String(), "compose.yaml,override.yaml"; got != want {
		t.Fatalf("String() = %q, want %q", got, want)
	}
}

func TestRunWritesNormalizedJSON(t *testing.T) {
	dir := t.TempDir()
	composeFile := filepath.Join(dir, "compose.yaml")
	writeFile(t, composeFile, `
name: sample
services:
  api:
    image: nginx:alpine
`)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	status := run([]string{"--project-directory", dir}, &stdout, &stderr)
	if status != 0 {
		t.Fatalf("run status = %d, stderr = %s", status, stderr.String())
	}

	var project normalizedProject
	if err := json.Unmarshal(stdout.Bytes(), &project); err != nil {
		t.Fatalf("decode normalized JSON: %v", err)
	}
	if project.Name != "sample" {
		t.Fatalf("project.Name = %q, want sample", project.Name)
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

func TestRunReportsFlagAndLoadErrors(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if status := run([]string{"--not-a-real-flag"}, &stdout, &stderr); status != 2 {
		t.Fatalf("bad flag status = %d, want 2", status)
	}
	if !strings.Contains(stderr.String(), "flag provided but not defined") {
		t.Fatalf("bad flag stderr = %q", stderr.String())
	}

	stdout.Reset()
	stderr.Reset()
	if status := run([]string{"--project-directory", t.TempDir()}, &stdout, &stderr); status != 1 {
		t.Fatalf("missing compose status = %d, want 1", status)
	}
	if !strings.Contains(stderr.String(), "no compose file found") {
		t.Fatalf("missing compose stderr = %q", stderr.String())
	}
}

func TestDiscoverComposeFilesUsesDefaultPriority(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "docker-compose.yml"), "services: {}\n")
	writeFile(t, filepath.Join(dir, "compose.yaml"), "services: {}\n")

	got := discoverComposeFiles(dir)
	want := []string{filepath.Join(dir, "compose.yaml")}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("discoverComposeFiles() = %#v, want %#v", got, want)
	}
}

func TestLoadProjectNormalizesComposeModel(t *testing.T) {
	dir := t.TempDir()
	composeFile := filepath.Join(dir, "compose.yaml")
	writeFile(t, composeFile, `
name: sample
services:
  api:
    image: nginx:alpine
    platform: linux/amd64
    mac_address: 02:42:ac:11:00:03
    runtime: container-runtime-linux
    cgroup: host
    cgroup_parent: m-executor-abcd
    cpu_count: 2
    cpu_period: 100000
    cpu_quota: 50000
    cpu_rt_period: 950000
    cpu_rt_runtime: 900000
    cpuset: "0-1"
    cpu_shares: 512
    domainname: example.test
    ipc: host
    isolation: default
    pid: host
    userns_mode: host
    uts: host
    command: ["nginx", "-g", "daemon off;"]
    environment:
      FOO: bar
    dns_opt:
      - use-vc
    expose:
      - "9000"
    shm_size: 64m
    ulimits:
      nofile:
        soft: 1024
        hard: 2048
      nproc: 512
    sysctls:
      net.core.somaxconn: "1024"
      net.ipv4.ip_local_port_range: "1024 65535"
    stop_signal: SIGUSR1
    stop_grace_period: 90s
    ports:
      - "127.0.0.1:8080:80/tcp"
    volumes:
      - data:/var/lib/app:ro
    networks:
      backend:
        aliases:
          - api.internal
        driver_opts:
          com.example.mode: bridge
        gw_priority: 1
        interface_name: eth0
        ipv4_address: 10.10.0.5
        ipv6_address: 2001:db8::5
        link_local_ips:
          - 169.254.1.5
        mac_address: 02:42:ac:11:00:02
        priority: 42
    depends_on:
      redis:
        condition: service_started
    links:
      - redis:cache
    external_links:
      - legacy_db:db
  redis:
    image: redis:7
networks:
  backend:
    labels:
      role: test
volumes:
  data:
    labels:
      role: state
`)

	project, err := loadProject(nil, nil, nil, "", dir)
	if err != nil {
		t.Fatalf("loadProject returned error: %v", err)
	}

	if project.Name != "sample" {
		t.Fatalf("project.Name = %q, want sample", project.Name)
	}
	if !reflect.DeepEqual(project.ComposeFiles, []string{composeFile}) {
		t.Fatalf("project.ComposeFiles = %#v, want %#v", project.ComposeFiles, []string{composeFile})
	}

	api := project.Services["api"]
	if api.Image != "nginx:alpine" {
		t.Fatalf("api.Image = %q, want nginx:alpine", api.Image)
	}
	if api.Platform != "linux/amd64" {
		t.Fatalf("api.Platform = %q, want linux/amd64", api.Platform)
	}
	if api.MacAddress != "02:42:ac:11:00:03" {
		t.Fatalf("api.MacAddress = %q, want 02:42:ac:11:00:03", api.MacAddress)
	}
	if api.Runtime != "container-runtime-linux" {
		t.Fatalf("api.Runtime = %q, want container-runtime-linux", api.Runtime)
	}
	if api.Cgroup != "host" {
		t.Fatalf("api.Cgroup = %q, want host", api.Cgroup)
	}
	if api.CgroupParent != "m-executor-abcd" {
		t.Fatalf("api.CgroupParent = %q, want m-executor-abcd", api.CgroupParent)
	}
	if api.CPUCount != 2 {
		t.Fatalf("api.CPUCount = %d, want 2", api.CPUCount)
	}
	if api.CPUPeriod != 100000 {
		t.Fatalf("api.CPUPeriod = %d, want 100000", api.CPUPeriod)
	}
	if api.CPUQuota != 50000 {
		t.Fatalf("api.CPUQuota = %d, want 50000", api.CPUQuota)
	}
	if api.CPURealtimePeriod != 950000 {
		t.Fatalf("api.CPURealtimePeriod = %d, want 950000", api.CPURealtimePeriod)
	}
	if api.CPURealtimeRuntime != 900000 {
		t.Fatalf("api.CPURealtimeRuntime = %d, want 900000", api.CPURealtimeRuntime)
	}
	if api.CPUSet != "0-1" {
		t.Fatalf("api.CPUSet = %q, want 0-1", api.CPUSet)
	}
	if api.CPUShares != 512 {
		t.Fatalf("api.CPUShares = %d, want 512", api.CPUShares)
	}
	if api.Ipc != "host" {
		t.Fatalf("api.Ipc = %q, want host", api.Ipc)
	}
	if api.Isolation != "default" {
		t.Fatalf("api.Isolation = %q, want default", api.Isolation)
	}
	if api.Pid != "host" {
		t.Fatalf("api.Pid = %q, want host", api.Pid)
	}
	if api.UserNSMode != "host" {
		t.Fatalf("api.UserNSMode = %q, want host", api.UserNSMode)
	}
	if api.Uts != "host" {
		t.Fatalf("api.Uts = %q, want host", api.Uts)
	}
	if api.DomainName != "example.test" {
		t.Fatalf("api.DomainName = %q, want example.test", api.DomainName)
	}
	if got, want := api.Command, []string{"nginx", "-g", "daemon off;"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.Command = %#v, want %#v", got, want)
	}
	if api.Environment["FOO"] == nil || *api.Environment["FOO"] != "bar" {
		t.Fatalf("api.Environment[FOO] = %#v, want bar", api.Environment["FOO"])
	}
	if got, want := api.DNSOptions, []string{"use-vc"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.DNSOptions = %#v, want %#v", got, want)
	}
	if got, want := api.Expose, []string{"9000"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.Expose = %#v, want %#v", got, want)
	}
	if got, want := api.ShmSize, "67108864"; got != want {
		t.Fatalf("api.ShmSize = %q, want %q", got, want)
	}
	if got, want := api.Ulimits, []string{"nofile=1024:2048", "nproc=512"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.Ulimits = %#v, want %#v", got, want)
	}
	if got, want := api.Sysctls, map[string]string{"net.core.somaxconn": "1024", "net.ipv4.ip_local_port_range": "1024 65535"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.Sysctls = %#v, want %#v", got, want)
	}
	if api.StopSignal != "SIGUSR1" {
		t.Fatalf("api.StopSignal = %q, want SIGUSR1", api.StopSignal)
	}
	if api.StopGracePeriodSeconds == nil || *api.StopGracePeriodSeconds != 90 {
		t.Fatalf("api.StopGracePeriodSeconds = %#v, want 90", api.StopGracePeriodSeconds)
	}
	if got, want := api.Ports, []string{"127.0.0.1:8080:80"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.Ports = %#v, want %#v", got, want)
	}
	if got, want := api.Networks, []string{"backend"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.Networks = %#v, want %#v", got, want)
	}
	if got, want := api.NetworkAliases, map[string][]string{"backend": []string{"api.internal"}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.NetworkAliases = %#v, want %#v", got, want)
	}
	if got, want := api.NetworkOptions, map[string]normalizedNetworkOptions{
		"backend": {
			DriverOpts:      map[string]string{"com.example.mode": "bridge"},
			GatewayPriority: 1,
			InterfaceName:   "eth0",
			IPv4Address:     "10.10.0.5",
			IPv6Address:     "2001:db8::5",
			LinkLocalIPs:    []string{"169.254.1.5"},
			MacAddress:      "02:42:ac:11:00:02",
			Priority:        42,
		},
	}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.NetworkOptions = %#v, want %#v", got, want)
	}
	if got, want := api.DependsOn, map[string]string{"redis": "service_started"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.DependsOn = %#v, want %#v", got, want)
	}
	if got, want := api.Links, []string{"redis:cache"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.Links = %#v, want %#v", got, want)
	}
	if got, want := api.ExternalLinks, []string{"legacy_db:db"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("api.ExternalLinks = %#v, want %#v", got, want)
	}
	if got, want := project.Networks["backend"].Labels, map[string]string{"role": "test"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("backend labels = %#v, want %#v", got, want)
	}
	if got, want := project.Volumes["data"].Labels, map[string]string{"role": "state"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("data labels = %#v, want %#v", got, want)
	}
}

func TestNormalizeServicePreservesCPUPercent(t *testing.T) {
	service := normalizeService(types.ServiceConfig{
		Name:       "api",
		CPUPercent: 12.5,
	})

	if service.CPUPercent != 12.5 {
		t.Fatalf("service.CPUPercent = %f, want 12.5", service.CPUPercent)
	}
}

func TestLoadProjectNormalizesNetworkMode(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "compose.yaml"), `
services:
  api:
    image: nginx:alpine
    network_mode: service:redis
  redis:
    image: redis:7
`)

	project, err := loadProject(nil, nil, nil, "", dir)
	if err != nil {
		t.Fatalf("loadProject returned error: %v", err)
	}
	if project.Services["api"].NetworkMode != "service:redis" {
		t.Fatalf("api.NetworkMode = %q, want service:redis", project.Services["api"].NetworkMode)
	}
}

func TestLoadProjectPreservesConfigsSecretsHealthchecksAndExtensions(t *testing.T) {
	dir := t.TempDir()
	composeFile := filepath.Join(dir, "compose.yaml")
	writeFile(t, composeFile, `
x-project:
  enabled: true
services:
  api:
    image: alpine
    restart: unless-stopped
    healthcheck:
      disable: true
    configs:
      - source: app_config
        target: /etc/app.conf
    secrets:
      - source: app_secret
    x-service:
      owner: platform
configs:
  app_config:
    external: true
secrets:
  app_secret:
    external: true
`)

	project, err := loadProject([]string{composeFile}, nil, nil, "sample", dir)
	if err != nil {
		t.Fatalf("loadProject returned error: %v", err)
	}

	if project.Configs["app_config"] == nil {
		t.Fatal("project.Configs[app_config] is nil")
	}
	if project.Secrets["app_secret"] == nil {
		t.Fatal("project.Secrets[app_secret] is nil")
	}
	if project.Extensions["x-project"] == nil {
		t.Fatal("project.Extensions[x-project] is nil")
	}

	api := project.Services["api"]
	if api.Healthcheck == nil {
		t.Fatal("api.Healthcheck is nil")
	}
	if api.Restart != "unless-stopped" {
		t.Fatalf("api.Restart = %q, want unless-stopped", api.Restart)
	}
	if api.Configs == nil {
		t.Fatal("api.Configs is nil")
	}
	if api.Secrets == nil {
		t.Fatal("api.Secrets is nil")
	}
	if api.Extensions["x-service"] == nil {
		t.Fatal("api.Extensions[x-service] is nil")
	}
}

func TestLoadProjectAppliesProfilesEnvFilesAndBuildFields(t *testing.T) {
	dir := t.TempDir()
	composeFile := filepath.Join(dir, "compose.yaml")
	envFile := filepath.Join(dir, "app.env")
	writeFile(t, envFile, "FROM_ENV=enabled\n")
	writeFile(t, composeFile, `
services:
  api:
    profiles: ["dev"]
    pull_policy: always
    build:
      context: ./api
      dockerfile: Containerfile
      target: runtime
      args:
        VERSION: "1"
        EMPTY:
    environment:
      FROM_ENV:
    env_file:
      - app.env
    ports:
      - target: 53
        protocol: udp
    cpus: 1.5
    mem_limit: 128m
  worker:
    image: alpine
`)

	project, err := loadProject(
		[]string{composeFile},
		[]string{"dev"},
		[]string{envFile},
		"custom",
		dir,
	)
	if err != nil {
		t.Fatalf("loadProject returned error: %v", err)
	}

	api := project.Services["api"]
	if project.Name != "custom" {
		t.Fatalf("project.Name = %q, want custom", project.Name)
	}
	if api.Build == nil {
		t.Fatal("api.Build is nil")
	}
	if api.PullPolicy != "always" {
		t.Fatalf("api.PullPolicy = %q, want always", api.PullPolicy)
	}
	if api.Build.Context != filepath.Join(dir, "api") || api.Build.Dockerfile != "Containerfile" || api.Build.Target != "runtime" {
		t.Fatalf("api.Build = %#v", api.Build)
	}
	if got, want := api.Build.Args, map[string]string{"VERSION": "1"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("build args = %#v, want %#v", got, want)
	}
	if got, want := api.EnvFiles, []string{envFile}; !reflect.DeepEqual(got, want) {
		t.Fatalf("env files = %#v, want %#v", got, want)
	}
	if value, ok := api.Environment["FROM_ENV"]; !ok || value != nil {
		t.Fatalf("FROM_ENV = %#v, want nil preserved mapping", value)
	}
	if got, want := api.Ports, []string{"53/udp"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("ports = %#v, want %#v", got, want)
	}
	if api.CPUS != "1.5" {
		t.Fatalf("cpus = %q, want 1.5", api.CPUS)
	}
	if api.MemLimit == "" {
		t.Fatal("MemLimit is empty")
	}
}

func TestLoadProjectWithoutComposeFileReturnsError(t *testing.T) {
	_, err := loadProject(nil, nil, nil, "", t.TempDir())
	if err == nil {
		t.Fatal("loadProject returned nil error")
	}
	if err.Error() != "no compose file found" {
		t.Fatalf("loadProject error = %q, want no compose file found", err.Error())
	}
}

func TestHelperFunctionsHandleEmptyAndFallbackValues(t *testing.T) {
	if shellCommandValues(nil) != nil {
		t.Fatal("shellCommandValues(nil) returned non-nil")
	}
	if mapEnvironment(nil) != nil {
		t.Fatal("mapEnvironment(nil) returned non-nil")
	}
	if envFileValues(nil) != nil {
		t.Fatal("envFileValues(nil) returned non-nil")
	}
	if portValues(nil) != nil {
		t.Fatal("portValues(nil) returned non-nil")
	}
	if mountValues(nil) != nil {
		t.Fatal("mountValues(nil) returned non-nil")
	}
	if networkValues(nil) != nil {
		t.Fatal("networkValues(nil) returned non-nil")
	}
	if dependsOnValues(nil) != nil {
		t.Fatal("dependsOnValues(nil) returned non-nil")
	}
	if mapLabels(nil) != nil {
		t.Fatal("mapLabels(nil) returned non-nil")
	}
	if mapMapping(nil) != nil {
		t.Fatal("mapMapping(nil) returned non-nil")
	}
	if got, want := mapMapping(types.Mapping{"net.core.somaxconn": "1024"}), map[string]string{"net.core.somaxconn": "1024"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("mapMapping() = %#v, want %#v", got, want)
	}
	if buildArgs(nil) != nil {
		t.Fatal("buildArgs(nil) returned non-nil")
	}
	if got := unitBytesValue(0); got != "" {
		t.Fatalf("unitBytesValue(0) = %q, want empty", got)
	}
	if got := unitBytesValue(types.UnitBytes(1024)); got != "1024" {
		t.Fatalf("unitBytesValue(1024) = %q, want 1024", got)
	}
	if got := cpusValue(0); got != "" {
		t.Fatalf("cpusValue(0) = %q, want empty", got)
	}
	if got := cpusValue(2.5); got != "2.5" {
		t.Fatalf("cpusValue(2.5) = %q, want 2.5", got)
	}
	if got := durationSeconds(nil); got != nil {
		t.Fatalf("durationSeconds(nil) = %#v, want nil", got)
	}
	duration := types.Duration(1500 * time.Millisecond)
	if got := durationSeconds(&duration); got == nil || *got != 2 {
		t.Fatalf("durationSeconds(1500ms) = %#v, want 2", got)
	}
	zeroDuration := types.Duration(0)
	if got := durationSeconds(&zeroDuration); got == nil || *got != 0 {
		t.Fatalf("durationSeconds(0) = %#v, want 0", got)
	}
	if got := ulimitValues(nil); got != nil {
		t.Fatalf("ulimitValues(nil) = %#v, want nil", got)
	}
	ulimits := map[string]*types.UlimitsConfig{
		"empty":  nil,
		"nofile": {Soft: 1024, Hard: 2048},
		"nproc":  {Single: 512},
		"stack":  {Soft: 8192, Hard: 8192},
	}
	if got, want := ulimitValues(ulimits), []string{"nofile=1024:2048", "nproc=512", "stack=8192"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("ulimitValues() = %#v, want %#v", got, want)
	}
	if got := firstNonEmpty("", "fallback"); got != "fallback" {
		t.Fatalf("firstNonEmpty fallback = %q, want fallback", got)
	}
	if got := firstNonEmpty("", ""); got != "" {
		t.Fatalf("firstNonEmpty empty = %q, want empty", got)
	}
}

func TestFormatPort(t *testing.T) {
	cases := []struct {
		name string
		port types.ServicePortConfig
		want string
	}{
		{
			name: "target only",
			port: types.ServicePortConfig{Target: 80},
			want: "80",
		},
		{
			name: "published udp",
			port: types.ServicePortConfig{Published: "5353", Target: 53, Protocol: "udp"},
			want: "5353:53/udp",
		},
		{
			name: "host ip",
			port: types.ServicePortConfig{HostIP: "127.0.0.1", Published: "8080", Target: 80},
			want: "127.0.0.1:8080:80",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := formatPort(tc.port); got != tc.want {
				t.Fatalf("formatPort() = %q, want %q", got, tc.want)
			}
		})
	}
}

func writeFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
