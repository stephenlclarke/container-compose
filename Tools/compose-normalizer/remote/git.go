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
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

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
	return gitRemoteLoader{
		offline: offline,
		known:   map[string]string{},
	}
}

type gitRemoteLoader struct {
	offline bool
	known   map[string]string
}

func (g gitRemoteLoader) Accept(path string) bool {
	_, _, err := gitutil.ParseGitRef(path)
	return err == nil
}

var commitSHA = regexp.MustCompile(`^[a-f0-9]{40}$`)

func (g gitRemoteLoader) Load(ctx context.Context, path string) (string, error) {
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

	local, ok := g.known[path]
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
		if _, err := os.Stat(local); os.IsNotExist(err) {
			if g.offline {
				return "", nil
			}
			if err := g.checkout(ctx, local, ref); err != nil {
				return "", err
			}
		}
		g.known[path] = local
	}
	if ref.SubDir != "" {
		if err := validateGitSubDir(local, ref.SubDir); err != nil {
			return "", err
		}
		local = filepath.Join(local, ref.SubDir)
	}
	stat, err := os.Stat(local)
	if err != nil {
		return "", err
	}
	if stat.IsDir() {
		local, err = findFile(cli.DefaultFileNames, local)
	}
	return local, err
}

func (g gitRemoteLoader) Dir(path string) string {
	return g.known[path]
}

func validateGitSubDir(base, subDir string) error {
	cleanSubDir := filepath.Clean(subDir)

	if filepath.IsAbs(cleanSubDir) {
		return fmt.Errorf("git subdirectory must be relative, got: %s", subDir)
	}

	if cleanSubDir == ".." || strings.HasPrefix(cleanSubDir, "../") || strings.HasPrefix(cleanSubDir, `..\`) {
		return fmt.Errorf("git subdirectory path traversal detected: %s", subDir)
	}

	if len(cleanSubDir) >= 2 && cleanSubDir[1] == ':' {
		return fmt.Errorf("git subdirectory must be relative, got: %s", subDir)
	}

	targetPath := filepath.Join(base, cleanSubDir)
	cleanBase := filepath.Clean(base)
	cleanTarget := filepath.Clean(targetPath)

	relPath, err := filepath.Rel(cleanBase, cleanTarget)
	if err != nil {
		return fmt.Errorf("invalid git subdirectory path: %w", err)
	}

	if relPath == ".." || strings.HasPrefix(relPath, "../") || strings.HasPrefix(relPath, `..\`) {
		return fmt.Errorf("git subdirectory escapes base directory: %s", subDir)
	}

	return nil
}

func (g gitRemoteLoader) resolveGitRef(ctx context.Context, path string, ref *gitutil.GitRef) error {
	if commitSHA.MatchString(ref.Ref) {
		return nil
	}

	cmd := exec.CommandContext(ctx, "git", "ls-remote", "--exit-code", ref.Remote, ref.Ref)
	cmd.Env = g.gitCommandEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		if cmd.ProcessState.ExitCode() == 2 {
			return fmt.Errorf("repository does not contain ref %s, output: %q: %w", path, string(out), err)
		}
		return fmt.Errorf("failed to access repository at %s:\n %s", ref.Remote, out)
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

func (g gitRemoteLoader) checkout(ctx context.Context, path string, ref *gitutil.GitRef) error {
	if err := os.MkdirAll(path, 0o700); err != nil {
		return err
	}
	if err := exec.CommandContext(ctx, "git", "init", path).Run(); err != nil {
		return err
	}

	cmd := exec.CommandContext(ctx, "git", "remote", "add", "origin", ref.Remote)
	cmd.Dir = path
	if err := cmd.Run(); err != nil {
		return err
	}

	cmd = exec.CommandContext(ctx, "git", "fetch", "--depth=1", "origin", ref.Ref)
	cmd.Env = g.gitCommandEnv()
	cmd.Dir = path
	if err := g.run(cmd); err != nil {
		return err
	}

	cmd = exec.CommandContext(ctx, "git", "checkout", ref.Ref)
	cmd.Dir = path
	return cmd.Run()
}

func (g gitRemoteLoader) run(cmd *exec.Cmd) error {
	if logrus.IsLevelEnabled(logrus.DebugLevel) {
		output, err := cmd.CombinedOutput()
		scanner := bufio.NewScanner(bytes.NewBuffer(output))
		for scanner.Scan() {
			logrus.Debug(scanner.Text())
		}
		return err
	}
	return cmd.Run()
}

func (g gitRemoteLoader) gitCommandEnv() []string {
	env := types.NewMapping(os.Environ())
	if env["GIT_TERMINAL_PROMPT"] == "" {
		env["GIT_TERMINAL_PROMPT"] = "0"
	}
	if env["GIT_SSH"] == "" && env["GIT_SSH_COMMAND"] == "" {
		env["GIT_SSH_COMMAND"] = "ssh -o ControlMaster=no -o BatchMode=yes"
	}
	return env.Values()
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

var _ loader.ResourceLoader = gitRemoteLoader{}
