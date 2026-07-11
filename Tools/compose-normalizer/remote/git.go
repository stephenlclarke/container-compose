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
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	pathpkg "path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/compose-spec/compose-go/v2/cli"
	"github.com/compose-spec/compose-go/v2/loader"
	"github.com/compose-spec/compose-go/v2/types"
	gitutil "github.com/moby/buildkit/frontend/dockerfile/dfgitutil"
	"github.com/sirupsen/logrus"
)

const GitRemoteEnabled = "COMPOSE_EXPERIMENTAL_GIT_REMOTE"

func gitRemoteLoaderEnabled() (bool, error) {
	if value := os.Getenv(GitRemoteEnabled); value != "" {
		enabled, err := strconv.ParseBool(value)
		if err != nil {
			return false, fmt.Errorf("%s environment variable expects boolean value: %w", GitRemoteEnabled, err)
		}
		return enabled, nil
	}
	return true, nil
}

func NewGitRemoteLoader(offline bool) loader.ResourceLoader {
	return &gitRemoteLoader{
		offline:     offline,
		known:       map[string]string{},
		directories: map[string]string{},
	}
}

type gitRemoteLoader struct {
	offline     bool
	mu          sync.RWMutex
	known       map[string]string
	directories map[string]string
}

func (g *gitRemoteLoader) Accept(path string) bool {
	_, _, err := gitutil.ParseGitRef(path)
	return err == nil
}

var commitSHA = regexp.MustCompile(`^[a-f0-9]{40}$`)

func (g *gitRemoteLoader) Load(ctx context.Context, path string) (string, error) {
	enabled, err := gitRemoteLoaderEnabled()
	if err != nil {
		return "", err
	}
	if !enabled {
		return "", fmt.Errorf("git remote resource is disabled by %q", GitRemoteEnabled)
	}

	ref, _, err := gitutil.ParseGitRef(path)
	if err != nil {
		return "", err
	}

	local, ok := g.knownPath(path)
	if !ok {
		if ref.Ref == "" {
			ref.Ref = "HEAD"
		}

		if err := g.resolveGitRef(ctx, path, ref); err != nil {
			return "", err
		}

		cache, err := cacheDir()
		if err != nil {
			return "", fmt.Errorf("initializing remote resource cache: %w", err)
		}

		local = filepath.Join(cache, ref.Ref)
		if err := g.ensureCheckout(ctx, local, ref); err != nil {
			return "", err
		}
		g.rememberCheckout(path, local)
	}
	repositoryRoot := local
	if ref.SubDir != "" {
		local, err = resolveGitSubDir(repositoryRoot, ref.SubDir)
		if err != nil {
			return "", err
		}
	}
	stat, err := os.Stat(local)
	if err != nil {
		return "", err
	}
	if stat.IsDir() {
		local, err = findFile(cli.DefaultFileNames, local)
		if err != nil {
			return "", err
		}
	}
	if err := validatePathInBase(repositoryRoot, local); err != nil {
		return "", err
	}
	g.rememberDirectory(path, local)
	return local, nil
}

func (g *gitRemoteLoader) Dir(path string) string {
	g.mu.RLock()
	directory, ok := g.directories[path]
	g.mu.RUnlock()
	if ok {
		return directory
	}
	if filepath.IsAbs(path) {
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			return path
		}
		return filepath.Dir(path)
	}
	if path == "" || g.Accept(path) {
		return ""
	}
	return filepath.Clean(path)
}

func validateGitSubDir(base, subDir string) error {
	normalizedSubDir := strings.ReplaceAll(subDir, `\`, "/")
	cleanSubDir := pathpkg.Clean(normalizedSubDir)

	if pathpkg.IsAbs(cleanSubDir) {
		return fmt.Errorf("git subdirectory must be relative, got: %s", subDir)
	}

	if cleanSubDir == ".." || strings.HasPrefix(cleanSubDir, "../") {
		return fmt.Errorf("git subdirectory path traversal detected: %s", subDir)
	}

	if len(cleanSubDir) >= 2 && cleanSubDir[1] == ':' {
		return fmt.Errorf("git subdirectory must be relative, got: %s", subDir)
	}

	targetPath := filepath.Join(base, filepath.FromSlash(cleanSubDir))
	cleanBase := filepath.Clean(base)
	cleanTarget := filepath.Clean(targetPath)

	relPath, err := filepath.Rel(cleanBase, cleanTarget)
	if err != nil {
		return fmt.Errorf("invalid git subdirectory path: %w", err)
	}

	if relPath == ".." || strings.HasPrefix(relPath, ".."+string(filepath.Separator)) {
		return fmt.Errorf("git subdirectory escapes base directory: %s", subDir)
	}

	return nil
}

func resolveGitSubDir(base, subDir string) (string, error) {
	if err := validateGitSubDir(base, subDir); err != nil {
		return "", err
	}
	cleanSubDir := pathpkg.Clean(strings.ReplaceAll(subDir, `\`, "/"))
	target := filepath.Join(base, filepath.FromSlash(cleanSubDir))
	if _, err := os.Stat(target); err != nil {
		return "", err
	}
	if err := validatePathInBase(base, target); err != nil {
		return "", err
	}
	return target, nil
}

func validatePathInBase(base, target string) error {
	resolvedBase, err := filepath.EvalSymlinks(base)
	if err != nil {
		return fmt.Errorf("resolve Git repository path: %w", err)
	}
	resolvedTarget, err := filepath.EvalSymlinks(target)
	if err != nil {
		return fmt.Errorf("resolve Git resource path: %w", err)
	}
	relative, err := filepath.Rel(resolvedBase, resolvedTarget)
	if err != nil {
		return fmt.Errorf("compare Git resource path: %w", err)
	}
	if relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return fmt.Errorf("git resource path escapes repository: %s", target)
	}
	return nil
}

func (g *gitRemoteLoader) resolveGitRef(ctx context.Context, path string, ref *gitutil.GitRef) error {
	if commitSHA.MatchString(ref.Ref) {
		return nil
	}

	cmd := exec.CommandContext(ctx, "git", "ls-remote", "--exit-code", ref.Remote, ref.Ref)
	cmd.Env = g.gitCommandEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		remote := displayGitRemote(ref.Remote)
		output := sanitizeGitOutput(string(out), ref.Remote)
		var exitError *exec.ExitError
		if errors.As(err, &exitError) && exitError.ExitCode() == 2 {
			return fmt.Errorf("repository does not contain ref %s, output: %q: %w", displayGitRemote(path), output, err)
		}
		return fmt.Errorf("failed to access repository at %s: %w\n%s", remote, err, output)
	}
	if len(out) < 40 {
		return fmt.Errorf("unexpected git command output: %q", string(out))
	}
	sha := string(out[:40])
	if !commitSHA.MatchString(sha) {
		return fmt.Errorf("invalid commit sha %q", sha)
	}
	ref.Ref = sha
	return nil
}

func (g *gitRemoteLoader) ensureCheckout(ctx context.Context, local string, ref *gitutil.GitRef) error {
	info, err := os.Lstat(local)
	if err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("git cache path must not be a symlink: %s", local)
		}
		if !info.IsDir() {
			return fmt.Errorf("git cache path is not a directory: %s", local)
		}
		return nil
	}
	if !os.IsNotExist(err) {
		return fmt.Errorf("inspect Git cache path: %w", err)
	}
	if g.offline {
		return fmt.Errorf("git remote resource is not available in the offline cache: %s", displayGitRemote(ref.Remote))
	}
	if err := os.MkdirAll(filepath.Dir(local), 0o700); err != nil {
		return fmt.Errorf("create Git cache directory: %w", err)
	}
	temporary, err := os.MkdirTemp(filepath.Dir(local), ".compose-git-checkout-")
	if err != nil {
		return fmt.Errorf("create temporary Git checkout: %w", err)
	}
	defer os.RemoveAll(temporary)

	if err := g.checkout(ctx, temporary, ref); err != nil {
		return err
	}
	if err := os.Rename(temporary, local); err != nil {
		if info, statErr := os.Lstat(local); statErr == nil && info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
			return nil
		}
		return fmt.Errorf("publish Git checkout to cache: %w", err)
	}
	return nil
}

func (g *gitRemoteLoader) checkout(ctx context.Context, path string, ref *gitutil.GitRef) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return fmt.Errorf("create Git checkout: %w", err)
	}
	if err := exec.CommandContext(ctx, "git", "init", path).Run(); err != nil {
		return fmt.Errorf("initialize Git checkout: %w", err)
	}

	cmd := exec.CommandContext(ctx, "git", "remote", "add", "origin", ref.Remote)
	cmd.Dir = path
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("configure Git checkout remote: %w", err)
	}

	cmd = exec.CommandContext(ctx, "git", "fetch", "--depth=1", "origin", ref.Ref)
	cmd.Env = g.gitCommandEnv()
	cmd.Dir = path
	if err := g.run(cmd, ref.Remote); err != nil {
		return fmt.Errorf("fetch Git ref %s: %w", ref.Ref, err)
	}
	cmd = exec.CommandContext(ctx, "git", "remote", "set-url", "origin", displayGitRemote(ref.Remote))
	cmd.Dir = path
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("redact Git checkout remote: %w", err)
	}

	cmd = exec.CommandContext(ctx, "git", "checkout", ref.Ref)
	cmd.Dir = path
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("check out Git ref %s: %w", ref.Ref, err)
	}
	return nil
}

func (g *gitRemoteLoader) run(cmd *exec.Cmd, sensitiveRemotes ...string) error {
	if logrus.IsLevelEnabled(logrus.DebugLevel) {
		output, err := cmd.CombinedOutput()
		scanner := bufio.NewScanner(bytes.NewBuffer(output))
		for scanner.Scan() {
			logrus.Debug(sanitizeGitOutput(scanner.Text(), sensitiveRemotes...))
		}
		return err
	}
	return cmd.Run()
}

func (g *gitRemoteLoader) gitCommandEnv() []string {
	env := types.NewMapping(os.Environ())
	if env["GIT_TERMINAL_PROMPT"] == "" {
		env["GIT_TERMINAL_PROMPT"] = "0"
	}
	if env["GIT_SSH"] == "" && env["GIT_SSH_COMMAND"] == "" {
		env["GIT_SSH_COMMAND"] = "ssh -o ControlMaster=no -o BatchMode=yes"
	}
	return env.Values()
}

func (g *gitRemoteLoader) knownPath(path string) (string, bool) {
	g.mu.RLock()
	defer g.mu.RUnlock()
	local, ok := g.known[path]
	return local, ok
}

func (g *gitRemoteLoader) rememberCheckout(path, local string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.known[path] = local
}

func (g *gitRemoteLoader) rememberDirectory(original, local string) {
	directory := filepath.Dir(local)
	g.mu.Lock()
	defer g.mu.Unlock()
	g.directories[original] = directory
	g.directories[local] = directory
}

func displayGitRemote(remote string) string {
	parsed, err := url.Parse(remote)
	if err != nil || parsed.User == nil {
		return remote
	}
	parsed.User = nil
	return parsed.String()
}

func sanitizeGitOutput(output string, remotes ...string) string {
	for _, remote := range remotes {
		output = strings.ReplaceAll(output, remote, displayGitRemote(remote))
	}
	return output
}

func findFile(names []string, pwd string) (string, error) {
	for _, name := range names {
		file := filepath.Join(pwd, name)
		if info, err := os.Stat(file); err == nil && !info.IsDir() {
			return file, nil
		}
	}
	return "", fmt.Errorf("no compose file found in Git repository directory %s", pwd)
}

var _ loader.ResourceLoader = (*gitRemoteLoader)(nil)
