package main

// ProfileManifest models an agent profile bundle's manifest.yaml. A profile
// is a directory under either `<workspace>/.rp/agents/<name>/` (workspace
// override) or `<repo>/agent.profiles/<name>/` (built-in). Each profile
// describes one coding agent (Claude Code, OpenCode, etc.) the container
// can run: how to install it, how to launch it, what env vars it needs.
//
// Lookup order is workspace-first; see ResolveProfile.

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// ProfileManifest is the parsed contents of a profile's manifest.yaml.
type ProfileManifest struct {
	Name            string          `yaml:"name"`
	Description     string          `yaml:"description,omitempty"`
	Env             []string        `yaml:"env,omitempty"`
	Files           []ProfileFile   `yaml:"files,omitempty"`
	InstructionsDst string          `yaml:"instructions_dst,omitempty"`
	Entrypoints     ProfileEntries  `yaml:"entrypoints,omitempty"`
	Volumes         []ProfileVolume `yaml:"volumes,omitempty"`
}

// ProfileVolume declares a persistent path inside the container that
// survives `rp destroy && rp create`. Used for state the agent writes
// during a session that should carry over: login tokens (~/.claude),
// history files, agent-local caches.
//
// Host-side backing lives at $RP_VOLUMES_DIR/<container-name>/<volume-name>/
// (default RP_VOLUMES_DIR = ~/.local/share/robo-pen/volumes). Mounted into
// the container at /home/{{user}}/<Mount>. `Mount` MUST be a relative path
// (an absolute path would let a profile shadow arbitrary locations, e.g.
// /etc — out of scope; see Validate).
type ProfileVolume struct {
	Name  string `yaml:"name"`
	Mount string `yaml:"mount"`
}

// ProfileFile lists a static file to copy into the image at build time.
// Src is relative to the profile dir. Dst is the absolute in-container path;
// `{{user}}` is templated by the build script, not by the parser.
type ProfileFile struct {
	Src string `yaml:"src"`
	Dst string `yaml:"dst"`
}

// ProfileEntries names the scripts the wrapper invokes for each lifecycle
// action. All fields are optional; when blank, conventional sibling filenames
// (install.sh, run.sh, run-gated.sh, login.sh) are used.
type ProfileEntries struct {
	Install  string `yaml:"install,omitempty"`
	Run      string `yaml:"run,omitempty"`
	RunGated string `yaml:"run_gated,omitempty"`
	Login    string `yaml:"login,omitempty"`
}

// Entrypoint kinds — used by callers asking "where is the run script for
// this profile?". Returned as well-known names that match Entrypoint().
const (
	EntrypointInstall  = "install"
	EntrypointRun      = "run"
	EntrypointRunGated = "run_gated"
	EntrypointLogin    = "login"
)

// Entrypoint returns the script's relative path within the profile dir, or
// "" if the kind is unknown. Defaults are applied here — the caller does not
// need to know about sibling-name conventions.
func (m *ProfileManifest) Entrypoint(kind string) string {
	switch kind {
	case EntrypointInstall:
		return firstNonEmpty(m.Entrypoints.Install, "install.sh")
	case EntrypointRun:
		return firstNonEmpty(m.Entrypoints.Run, "run.sh")
	case EntrypointRunGated:
		return firstNonEmpty(m.Entrypoints.RunGated, "run-gated.sh")
	case EntrypointLogin:
		return firstNonEmpty(m.Entrypoints.Login, "login.sh")
	}
	return ""
}

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// ParseProfileManifest reads and validates a profile manifest. Strict mode:
// unknown YAML keys produce an error.
func ParseProfileManifest(path string) (*ProfileManifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseProfileManifestBytes(data)
}

func parseProfileManifestBytes(data []byte) (*ProfileManifest, error) {
	m := &ProfileManifest{}
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, errors.New("manifest: empty")
	}
	d := yaml.NewDecoder(bytes.NewReader(data))
	d.KnownFields(true)
	if err := d.Decode(m); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, errors.New("manifest: empty")
		}
		return nil, fmt.Errorf("manifest: parse: %w", err)
	}
	if err := m.Validate(); err != nil {
		return nil, err
	}
	return m, nil
}

// Validate enforces syntactic rules on the manifest. Filesystem checks
// (does install.sh exist? is it executable?) belong in the lint step.
func (m *ProfileManifest) Validate() error {
	if m.Name == "" {
		return errors.New("manifest: name is required")
	}
	if err := validateAgentName(m.Name); err != nil {
		return fmt.Errorf("manifest: name: %w", err)
	}
	for i, e := range m.Env {
		if !validEnvVarName(e) {
			return fmt.Errorf("manifest: env[%d]: %q is not a valid POSIX env var name", i, e)
		}
	}
	for i, f := range m.Files {
		if f.Src == "" {
			return fmt.Errorf("manifest: files[%d]: src is required", i)
		}
		if filepath.IsAbs(f.Src) {
			return fmt.Errorf("manifest: files[%d].src %q must be relative to the profile dir", i, f.Src)
		}
		if strings.Contains(f.Src, "..") {
			return fmt.Errorf("manifest: files[%d].src %q must not contain `..`", i, f.Src)
		}
		if f.Dst == "" {
			return fmt.Errorf("manifest: files[%d]: dst is required", i)
		}
		if !filepath.IsAbs(f.Dst) {
			return fmt.Errorf("manifest: files[%d].dst %q must be absolute", i, f.Dst)
		}
	}
	if m.InstructionsDst != "" && !filepath.IsAbs(m.InstructionsDst) {
		return fmt.Errorf("manifest: instructions_dst %q must be absolute", m.InstructionsDst)
	}
	volNames := map[string]int{}
	for i, v := range m.Volumes {
		if v.Name == "" {
			return fmt.Errorf("manifest: volumes[%d]: name is required", i)
		}
		if err := validateVolumeName(v.Name); err != nil {
			return fmt.Errorf("manifest: volumes[%d].name: %w", i, err)
		}
		if dup, ok := volNames[v.Name]; ok {
			return fmt.Errorf("manifest: volumes[%d].name %q duplicates volumes[%d]", i, v.Name, dup)
		}
		volNames[v.Name] = i
		if v.Mount == "" {
			return fmt.Errorf("manifest: volumes[%d]: mount is required", i)
		}
		if filepath.IsAbs(v.Mount) {
			return fmt.Errorf("manifest: volumes[%d].mount %q must be relative to the container user's home", i, v.Mount)
		}
		if strings.Contains(v.Mount, "..") {
			return fmt.Errorf("manifest: volumes[%d].mount %q must not contain `..`", i, v.Mount)
		}
		// Disallow leading slash already covered by IsAbs; also reject any
		// rooted-looking variants like `./..`/leading-dot-segments.
		clean := filepath.Clean(v.Mount)
		if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
			return fmt.Errorf("manifest: volumes[%d].mount %q resolves outside the home directory", i, v.Mount)
		}
	}
	for kind, ep := range map[string]string{
		EntrypointInstall:  m.Entrypoints.Install,
		EntrypointRun:      m.Entrypoints.Run,
		EntrypointRunGated: m.Entrypoints.RunGated,
		EntrypointLogin:    m.Entrypoints.Login,
	} {
		if ep == "" {
			continue
		}
		if filepath.IsAbs(ep) {
			return fmt.Errorf("manifest: entrypoints.%s %q must be relative to the profile dir", kind, ep)
		}
		if strings.Contains(ep, "..") {
			return fmt.Errorf("manifest: entrypoints.%s %q must not contain `..`", kind, ep)
		}
	}
	return nil
}

// validateVolumeName accepts lowercase alphanumeric + dashes; same shape as
// container names. Volume name is used as a directory under
// $RP_VOLUMES_DIR/<container>/, so we forbid `.`, `..`, slashes, spaces.
func validateVolumeName(name string) error {
	if name == "" {
		return errors.New("empty")
	}
	for i, r := range name {
		switch {
		case r >= 'a' && r <= 'z':
			continue
		case r >= '0' && r <= '9' && i > 0:
			continue
		case r == '-' && i > 0:
			continue
		}
		return fmt.Errorf("invalid character %q in volume name %q (lowercase, digits, hyphens; cannot start with digit or hyphen)", r, name)
	}
	return nil
}

func validEnvVarName(name string) bool {
	if name == "" {
		return false
	}
	for i, r := range name {
		switch {
		case r >= 'A' && r <= 'Z':
			continue
		case r == '_':
			continue
		case r >= '0' && r <= '9' && i > 0:
			continue
		}
		return false
	}
	return true
}

// ResolveProfile finds the profile bundle directory for `agentName`.
//
// Workspace overrides take precedence over built-ins. A workspace override
// is recognized only if `<workspace>/.rp/agents/<agentName>/manifest.yaml`
// exists; profile dirs lacking a manifest are treated as not-present (lint
// reports them as partial overrides).
//
// Returns the absolute profile directory and a source label
// ("workspace" | "builtin"). Both empty + error if neither is found.
func ResolveProfile(workspace, repoDir, agentName string) (string, string, error) {
	if agentName == "" {
		return "", "", errors.New("resolve profile: agent name is empty")
	}
	if err := validateAgentName(agentName); err != nil {
		return "", "", fmt.Errorf("resolve profile: %w", err)
	}
	if workspace != "" {
		dir := filepath.Join(workspace, ".rp", "agents", agentName)
		if hasManifest(dir) {
			return dir, "workspace", nil
		}
	}
	if repoDir != "" {
		dir := filepath.Join(repoDir, "agent.profiles", agentName)
		if hasManifest(dir) {
			return dir, "builtin", nil
		}
	}
	return "", "", fmt.Errorf("resolve profile: no profile %q found in workspace .rp/agents/ or builtin agent.profiles/", agentName)
}

func hasManifest(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "manifest.yaml"))
	return err == nil
}

// LoadResolvedProfile finds + parses + validates the profile in one shot.
func LoadResolvedProfile(workspace, repoDir, agentName string) (*ProfileManifest, string, string, error) {
	dir, source, err := ResolveProfile(workspace, repoDir, agentName)
	if err != nil {
		return nil, "", "", err
	}
	m, err := ParseProfileManifest(filepath.Join(dir, "manifest.yaml"))
	if err != nil {
		return nil, dir, source, fmt.Errorf("%s/manifest.yaml: %w", dir, err)
	}
	return m, dir, source, nil
}
