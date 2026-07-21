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
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	gitutil "github.com/moby/buildkit/frontend/dockerfile/dfgitutil"
	"github.com/sirupsen/logrus"
)

func TestValidateGitSubDir(t *testing.T) {
	base := "/tmp/cache/compose/abc123def456"
	tests := []struct {
		name    string
		subDir  string
		wantErr bool
	}{
		{name: "valid simple directory", subDir: "examples"},
		{name: "valid nested directory", subDir: "examples/nginx"},
		{name: "valid deeply nested directory", subDir: "examples/web/frontend/config"},
		{name: "valid current directory", subDir: "."},
		{name: "valid directory with redundant separators", subDir: "examples//nginx"},
		{name: "valid directory with dots in name", subDir: "examples/nginx.conf.d"},
		{name: "path traversal - parent directory", subDir: "..", wantErr: true},
		{name: "path traversal - multiple parent directories", subDir: "../../../etc/passwd", wantErr: true},
		{name: "path traversal - deeply nested escape", subDir: "../../../../../../../tmp/pwned", wantErr: true},
		{name: "path traversal - mixed with valid path", subDir: "examples/../../etc/passwd", wantErr: true},
		{name: "path traversal - at the end", subDir: "examples/.."},
		{name: "path traversal - in the middle", subDir: "examples/../../../etc/passwd", wantErr: true},
		{name: "path traversal - windows style", subDir: `..\..\..\windows\system32`, wantErr: true},
		{name: "path traversal - mixed windows style", subDir: `examples\..\..\windows\system32`, wantErr: true},
		{name: "absolute unix path", subDir: "/etc/passwd", wantErr: true},
		{name: "absolute windows path", subDir: `C:\windows\system32\config\sam`, wantErr: true},
		{name: "absolute path with home directory", subDir: "/home/user/.ssh/id_rsa", wantErr: true},
		{name: "normalized path that would escape", subDir: "./../../etc/passwd", wantErr: true},
		{name: "directory name with three dots", subDir: ".../config"},
		{name: "directory name with four dots", subDir: "..../config"},
		{name: "directory name with five dots", subDir: "...../etc/passwd"},
		{name: "directory name starting with two dots and letter", subDir: "..foo/bar"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateGitSubDir(base, test.subDir)
			if (err != nil) != test.wantErr {
				t.Fatalf("validateGitSubDir(%q, %q) error = %v, wantErr %v", base, test.subDir, err, test.wantErr)
			}
		})
	}
}

func TestResolveGitSubDirRejectsSymlinkEscape(t *testing.T) {
	root := t.TempDir()
	base := filepath.Join(root, "repository")
	outside := filepath.Join(root, "outside")
	if err := os.MkdirAll(base, 0o755); err != nil {
		t.Fatalf("create repository: %v", err)
	}
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatalf("create outside directory: %v", err)
	}
	if err := os.Symlink(outside, filepath.Join(base, "escape")); err != nil {
		t.Fatalf("create escape symlink: %v", err)
	}

	_, err := resolveGitSubDir(base, "escape")
	if err == nil || !strings.Contains(err.Error(), "escapes repository") {
		t.Fatalf("resolveGitSubDir error = %v, want repository escape error", err)
	}
}

func TestResolveGitRefReportsMissingGitWithoutPanic(t *testing.T) {
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	loader.command = unavailableGitCommand(filepath.Join(t.TempDir(), "missing-git"))
	ref := &gitutil.GitRef{Remote: "https://example.test/project.git", Ref: "main"}

	err := loader.resolveGitRef(context.Background(), ref.Remote+"#main", ref)
	if err == nil || !strings.Contains(err.Error(), "failed to access repository") {
		t.Fatalf("resolveGitRef error = %v, want Git access error", err)
	}
}

func TestOfflineCacheMissReturnsError(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	loader := NewGitRemoteLoader(true)
	ref := "https://example.test/project.git#aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	_, err := loader.Load(context.Background(), ref)
	if err == nil || !strings.Contains(err.Error(), "not available in the offline cache") {
		t.Fatalf("Load error = %v, want offline cache miss", err)
	}
}

func TestGitLoaderChecksOutCommitIntoCache(t *testing.T) {
	cacheHome := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheHome)
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	loader.command = successfulGitCommand(t)
	commit := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	remote := "https://example.test/project.git#" + commit

	local, err := loader.Load(context.Background(), remote)
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	want := filepath.Join(cacheHome, cacheDirectoryName, commit, "compose.yaml")
	if local != want {
		t.Fatalf("Load = %q, want %q", local, want)
	}
	content, err := os.ReadFile(local)
	if err != nil {
		t.Fatalf("read checked out compose file: %v", err)
	}
	if string(content) != "services: {}\n" {
		t.Fatalf("compose file = %q, want fixture content", content)
	}
	if got := loader.Dir(remote); got != filepath.Dir(local) {
		t.Fatalf("Dir(remote) = %q, want %q", got, filepath.Dir(local))
	}
}

func TestResolveGitRefUsesResolvedCommit(t *testing.T) {
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	loader.command = successfulGitCommand(t)
	ref := &gitutil.GitRef{Remote: "https://example.test/project.git", Ref: "main"}

	if err := loader.resolveGitRef(context.Background(), ref.Remote+"#main", ref); err != nil {
		t.Fatalf("resolveGitRef returned error: %v", err)
	}
	if got, want := ref.Ref, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; got != want {
		t.Fatalf("resolved ref = %q, want %q", got, want)
	}
}

func TestGitLoaderRejectsInvalidEnablementValue(t *testing.T) {
	t.Setenv(GitRemoteEnabled, "not-a-bool")
	loader := NewGitRemoteLoader(false)

	_, err := loader.Load(context.Background(), "https://example.test/project.git#main")
	if err == nil || !strings.Contains(err.Error(), "expects boolean value") {
		t.Fatalf("Load error = %v, want enablement error", err)
	}
}

func TestGitLoaderRejectsDisabledAndMalformedRemote(t *testing.T) {
	t.Setenv(GitRemoteEnabled, "false")
	loader := NewGitRemoteLoader(false)
	if _, err := loader.Load(context.Background(), "https://example.test/project.git#main"); err == nil {
		t.Fatal("Load returned nil error for disabled Git remote")
	}

	t.Setenv(GitRemoteEnabled, "true")
	if _, err := loader.Load(context.Background(), "not a Git remote"); err == nil {
		t.Fatal("Load returned nil error for malformed Git remote")
	}
}

func TestGitLoaderResolvesDefaultHead(t *testing.T) {
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	loader.command = successfulGitCommand(t)

	local, err := loader.Load(context.Background(), "https://example.test/project.git")
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if filepath.Base(filepath.Dir(local)) != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
		t.Fatalf("Load cache directory = %q, want resolved commit", filepath.Dir(local))
	}
}

func TestEnsureCheckoutAcceptsDirectoryAndRejectsFile(t *testing.T) {
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	ref := &gitutil.GitRef{Remote: "https://example.test/project.git"}
	directory := t.TempDir()
	if err := loader.ensureCheckout(context.Background(), directory, ref); err != nil {
		t.Fatalf("ensureCheckout(directory) returned error: %v", err)
	}
	file := filepath.Join(t.TempDir(), "cache-file")
	if err := os.WriteFile(file, []byte("not a checkout"), 0o600); err != nil {
		t.Fatalf("write cache file: %v", err)
	}
	if err := loader.ensureCheckout(context.Background(), file, ref); err == nil || !strings.Contains(err.Error(), "not a directory") {
		t.Fatalf("ensureCheckout(file) error = %v, want non-directory error", err)
	}
}

func TestGitLoaderLogsFetchOutputAtDebugLevel(t *testing.T) {
	previousLevel := logrus.GetLevel()
	logrus.SetLevel(logrus.DebugLevel)
	t.Cleanup(func() { logrus.SetLevel(previousLevel) })
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	command := exec.Command("printf", "fetched https://user:secret@example.test/project.git\\n")

	if err := loader.run(command, "https://user:secret@example.test/project.git"); err != nil {
		t.Fatalf("run returned error: %v", err)
	}
}

func TestResolveGitRefRejectsMalformedOutputAndMissingRefs(t *testing.T) {
	for _, test := range []struct {
		name    string
		command string
		want    string
	}{
		{name: "short output", command: "printf short", want: "unexpected git command output"},
		{name: "invalid SHA", command: "printf zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", want: "invalid commit sha"},
		{name: "missing ref", command: "printf missing; exit 2", want: "repository does not contain ref"},
	} {
		t.Run(test.name, func(t *testing.T) {
			loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
			loader.command = shellGitCommand(test.command)
			ref := &gitutil.GitRef{Remote: "https://user:secret@example.test/project.git", Ref: "main"}

			err := loader.resolveGitRef(context.Background(), ref.Remote+"#main", ref)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("resolveGitRef error = %v, want %q", err, test.want)
			}
			if strings.Contains(err.Error(), "secret") {
				t.Fatalf("resolveGitRef error leaked credentials: %v", err)
			}
		})
	}
}

func TestGitResourceResolutionReportsMissingPaths(t *testing.T) {
	root := t.TempDir()
	if _, err := resolveGitResource(root, ""); err == nil || !strings.Contains(err.Error(), "no compose file") {
		t.Fatalf("resolveGitResource error = %v, want missing compose file error", err)
	}
	if _, err := resolveGitResource(root, "missing"); err == nil || !os.IsNotExist(err) {
		t.Fatalf("resolveGitResource subdirectory error = %v, want not found", err)
	}
	if err := validatePathInBase(filepath.Join(root, "missing"), root); err == nil || !strings.Contains(err.Error(), "resolve Git repository path") {
		t.Fatalf("validatePathInBase missing base error = %v", err)
	}
	if err := validatePathInBase(root, filepath.Join(root, "missing")); err == nil || !strings.Contains(err.Error(), "resolve Git resource path") {
		t.Fatalf("validatePathInBase missing target error = %v", err)
	}
}

func TestGitLoaderDirHandlesAbsoluteFilesAndDirectories(t *testing.T) {
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	directory := t.TempDir()
	file := filepath.Join(directory, "compose.yaml")
	if err := os.WriteFile(file, []byte("services: {}\n"), 0o600); err != nil {
		t.Fatalf("write compose file: %v", err)
	}
	if got := loader.Dir(directory); got != directory {
		t.Fatalf("Dir(directory) = %q, want %q", got, directory)
	}
	if got := loader.Dir(file); got != directory {
		t.Fatalf("Dir(file) = %q, want %q", got, directory)
	}
}

func TestGitRemoteLoaderDefaultsEnabledAndUsesSystemCommand(t *testing.T) {
	t.Setenv(GitRemoteEnabled, "")
	enabled, err := gitRemoteLoaderEnabled()
	if err != nil || !enabled {
		t.Fatalf("gitRemoteLoaderEnabled = %v, %v; want true, nil", enabled, err)
	}
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	if command := loader.gitCommand(context.Background(), "--version"); !filepath.IsAbs(command.Path) {
		t.Fatalf("gitCommand path = %q, want absolute system Git path", command.Path)
	}
}

func TestFindFileSelectsLaterNameAndReportsMissingFiles(t *testing.T) {
	directory := t.TempDir()
	second := filepath.Join(directory, "docker-compose.yaml")
	if err := os.WriteFile(second, []byte("services: {}\n"), 0o600); err != nil {
		t.Fatalf("write compose file: %v", err)
	}
	file, err := findFile([]string{"compose.yaml", "docker-compose.yaml"}, directory)
	if err != nil || file != second {
		t.Fatalf("findFile = %q, %v; want %q, nil", file, err, second)
	}
	if _, err := findFile([]string{"compose.yaml"}, t.TempDir()); err == nil || !strings.Contains(err.Error(), "no compose file") {
		t.Fatalf("findFile missing error = %v, want no compose file error", err)
	}
}

func TestGitLoaderReportsEarlyRemoteResolutionFailures(t *testing.T) {
	t.Setenv(GitRemoteEnabled, "true")
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	if _, err := loader.Load(context.Background(), "git://example.test/project.git#main:%zz"); err == nil || !strings.Contains(err.Error(), "invalid URL escape") {
		t.Fatalf("Load fragment error = %v, want URL parse error", err)
	}
	if _, err := resolveGitResource(filepath.Join(t.TempDir(), "missing"), ""); err == nil || !os.IsNotExist(err) {
		t.Fatalf("resolveGitResource missing root error = %v, want not found", err)
	}
	remote := "https://example.test/project.git#main"
	loader.rememberCheckout(remote, t.TempDir())
	if _, err := loader.Load(context.Background(), remote); err == nil || !strings.Contains(err.Error(), "no compose file") {
		t.Fatalf("Load cached resource error = %v, want missing compose file", err)
	}
	loader = NewGitRemoteLoader(false).(*gitRemoteLoader)
	loader.command = unavailableGitCommand(filepath.Join(t.TempDir(), "missing-git"))
	ref := &gitutil.GitRef{Remote: "https://example.test/project.git", Ref: "main"}
	if _, err := loader.checkoutPath(context.Background(), ref.Remote+"#main", ref); err == nil || !strings.Contains(err.Error(), "failed to access repository") {
		t.Fatalf("checkoutPath error = %v, want Git access error", err)
	}
}

func TestLoadUsesRememberedCheckoutAndSubdirectory(t *testing.T) {
	t.Setenv(GitRemoteEnabled, "true")
	loader := NewGitRemoteLoader(true).(*gitRemoteLoader)
	remote := "https://example.test/project.git#main:stacks/demo"
	root := t.TempDir()
	composeFile := filepath.Join(root, "stacks", "demo", "compose.yaml")
	if err := os.MkdirAll(filepath.Dir(composeFile), 0o755); err != nil {
		t.Fatalf("create Compose directory: %v", err)
	}
	if err := os.WriteFile(composeFile, []byte("services: {}\n"), 0o600); err != nil {
		t.Fatalf("write Compose file: %v", err)
	}
	loader.rememberCheckout(remote, root)

	local, err := loader.Load(context.Background(), remote)
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if local != composeFile {
		t.Fatalf("Load = %q, want %q", local, composeFile)
	}
	if directory := loader.Dir(remote); directory != filepath.Dir(composeFile) {
		t.Fatalf("Dir = %q, want %q", directory, filepath.Dir(composeFile))
	}
}

func TestLoadRejectsRawFragmentTraversalBeforeBuildKitNormalization(t *testing.T) {
	t.Setenv(GitRemoteEnabled, "true")
	loader := NewGitRemoteLoader(true).(*gitRemoteLoader)
	remote := "git://example.test/project.git#HEAD:../../escape"
	root := t.TempDir()
	composeFile := filepath.Join(root, "escape", "compose.yaml")
	if err := os.MkdirAll(filepath.Dir(composeFile), 0o755); err != nil {
		t.Fatalf("create escaped Compose directory: %v", err)
	}
	if err := os.WriteFile(composeFile, []byte("services: {}\n"), 0o600); err != nil {
		t.Fatalf("write escaped Compose file: %v", err)
	}
	loader.rememberCheckout(remote, root)

	_, err := loader.Load(context.Background(), remote)
	if err == nil || !strings.Contains(err.Error(), "path traversal") {
		t.Fatalf("Load error = %v, want path traversal rejection", err)
	}
}

func TestRawGitFragmentSubDir(t *testing.T) {
	tests := []struct {
		name    string
		remote  string
		want    string
		wantOK  bool
		wantErr bool
	}{
		{name: "no fragment", remote: "git://example.test/project.git"},
		{name: "ref only", remote: "git://example.test/project.git#main"},
		{name: "plain subdirectory", remote: "git://example.test/project.git#main:stacks/demo", want: "stacks/demo", wantOK: true},
		{name: "escaped subdirectory", remote: "git://example.test/project.git#main:stacks%2Fdemo", want: "stacks/demo", wantOK: true},
		{name: "invalid escape", remote: "git://example.test/project.git#main:%zz", wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok, err := rawGitFragmentSubDir(test.remote)
			if (err != nil) != test.wantErr {
				t.Fatalf("rawGitFragmentSubDir() error = %v, wantErr %v", err, test.wantErr)
			}
			if ok != test.wantOK {
				t.Fatalf("rawGitFragmentSubDir() ok = %v, want %v", ok, test.wantOK)
			}
			if got != test.want {
				t.Fatalf("rawGitFragmentSubDir() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestFailedCheckoutDoesNotPublishCache(t *testing.T) {
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	loader.command = unavailableGitCommand(filepath.Join(t.TempDir(), "missing-git"))
	cache := t.TempDir()
	local := filepath.Join(cache, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	ref := &gitutil.GitRef{
		Remote: "https://example.test/project.git",
		Ref:    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}

	if err := loader.ensureCheckout(context.Background(), local, ref); err == nil {
		t.Fatal("ensureCheckout returned nil error with Git unavailable")
	}
	if _, err := os.Stat(local); !os.IsNotExist(err) {
		t.Fatalf("published cache path stat error = %v, want not found", err)
	}
	entries, err := os.ReadDir(cache)
	if err != nil {
		t.Fatalf("read cache: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("cache entries = %v, want no failed temporary checkout", entries)
	}
}

func TestSystemGitCommandUsesAbsoluteExecutable(t *testing.T) {
	command := systemGitCommand(context.Background(), "--version")
	if !filepath.IsAbs(command.Path) {
		t.Fatalf("systemGitCommand path = %q, want absolute path", command.Path)
	}
}

func unavailableGitCommand(path string) gitCommandFactory {
	return func(_ context.Context, args ...string) *exec.Cmd {
		return &exec.Cmd{
			Path: path,
			Args: append([]string{path}, args...),
		}
	}
}

func successfulGitCommand(t *testing.T) gitCommandFactory {
	t.Helper()
	script := filepath.Join(t.TempDir(), "git")
	const contents = `#!/bin/sh
case "$1" in
  init)
    mkdir -p "$2"
    ;;
  ls-remote)
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/main\n'
    ;;
  checkout)
    printf 'services: {}\n' > compose.yaml
    ;;
esac
`
	if err := os.WriteFile(script, []byte(contents), 0o700); err != nil {
		t.Fatalf("write Git fixture: %v", err)
	}
	return func(ctx context.Context, args ...string) *exec.Cmd {
		return exec.CommandContext(ctx, script, args...)
	}
}

func shellGitCommand(command string) gitCommandFactory {
	return func(ctx context.Context, _ ...string) *exec.Cmd {
		return exec.CommandContext(ctx, "sh", "-c", command)
	}
}

func TestEnsureCheckoutRejectsSymlinkedCacheEntry(t *testing.T) {
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	root := t.TempDir()
	target := filepath.Join(root, "target")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatalf("create symlink target: %v", err)
	}
	local := filepath.Join(root, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	if err := os.Symlink(target, local); err != nil {
		t.Fatalf("create cache symlink: %v", err)
	}
	ref := &gitutil.GitRef{Remote: "https://example.test/project.git", Ref: filepath.Base(local)}

	err := loader.ensureCheckout(context.Background(), local, ref)
	if err == nil || !strings.Contains(err.Error(), "must not be a symlink") {
		t.Fatalf("ensureCheckout error = %v, want symlink rejection", err)
	}
}

func TestGitLoaderTracksEffectiveResourceDirectory(t *testing.T) {
	loader := NewGitRemoteLoader(false).(*gitRemoteLoader)
	remote := "https://example.test/project.git#main:stacks/demo"
	local := filepath.Join(t.TempDir(), "stacks", "demo", "compose.yaml")
	loader.rememberDirectory(remote, local)

	if got, want := loader.Dir(remote), filepath.Dir(local); got != want {
		t.Fatalf("Dir(remote) = %q, want %q", got, want)
	}
	if got, want := loader.Dir(local), filepath.Dir(local); got != want {
		t.Fatalf("Dir(local) = %q, want %q", got, want)
	}
	if got, want := loader.Dir("relative/project"), filepath.Clean("relative/project"); got != want {
		t.Fatalf("Dir(relative) = %q, want %q", got, want)
	}
	if got := loader.Dir(""); got != "" {
		t.Fatalf("Dir(empty) = %q, want empty", got)
	}
}

func TestDisplayGitRemoteRedactsCredentials(t *testing.T) {
	remote := "https://user:secret@example.test/team/project.git#main"
	if got, want := displayGitRemote(remote), "https://example.test/team/project.git#main"; got != want {
		t.Fatalf("displayGitRemote() = %q, want %q", got, want)
	}
	output := "fatal: could not read from " + remote
	if got, want := sanitizeGitOutput(output, remote), "fatal: could not read from https://example.test/team/project.git#main"; got != want {
		t.Fatalf("sanitizeGitOutput() = %q, want %q", got, want)
	}
}

func TestValidateGitSubDirSecurityScenarios(t *testing.T) {
	base := "/var/cache/docker-compose/git/1234567890abcdef"
	for _, maliciousPath := range []string{
		"../../../../../../../tmp/pwned",
		"../../../../../../../../etc/passwd",
	} {
		if err := validateGitSubDir(base, maliciousPath); err == nil || !strings.Contains(err.Error(), "path traversal") {
			t.Fatalf("validateGitSubDir(%q, %q) error = %v, want path traversal error", base, maliciousPath, err)
		}
	}

	if err := validateGitSubDir(base, "examples/docker-compose/nginx/config"); err != nil {
		t.Fatalf("validateGitSubDir returned error for legitimate nested path: %v", err)
	}
}
