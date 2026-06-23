package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseProfileManifest_Minimal(t *testing.T) {
	src := "name: claude-code\n"
	m, err := parseProfileManifestBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if m.Name != "claude-code" {
		t.Errorf("name = %q", m.Name)
	}
	// All entrypoints default to sibling names when not declared.
	if got := m.Entrypoint(EntrypointRun); got != "run.sh" {
		t.Errorf("default run entrypoint = %q, want run.sh", got)
	}
	if got := m.Entrypoint(EntrypointRunGated); got != "run-gated.sh" {
		t.Errorf("default run_gated entrypoint = %q, want run-gated.sh", got)
	}
}

func TestParseProfileManifest_FullShape(t *testing.T) {
	src := `name: claude-code
description: Anthropic Claude Code CLI
env: [ANTHROPIC_API_KEY]
files:
  - src: settings/settings.json
    dst: /home/{{user}}/.claude/settings.json
instructions_dst: /home/{{user}}/.claude/CLAUDE.md
entrypoints:
  install: install.sh
  run: run.sh
  run_gated: run-gated.sh
  login: login.sh
`
	m, err := parseProfileManifestBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Env) != 1 || m.Env[0] != "ANTHROPIC_API_KEY" {
		t.Errorf("env = %+v", m.Env)
	}
	if len(m.Files) != 1 || m.Files[0].Src != "settings/settings.json" {
		t.Errorf("files = %+v", m.Files)
	}
	if m.InstructionsDst != "/home/{{user}}/.claude/CLAUDE.md" {
		t.Errorf("instructions_dst = %q", m.InstructionsDst)
	}
}

func TestParseProfileManifest_EmptyRejected(t *testing.T) {
	_, err := parseProfileManifestBytes([]byte(""))
	if err == nil || !strings.Contains(err.Error(), "empty") {
		t.Errorf("expected empty error, got %v", err)
	}
}

func TestParseProfileManifest_NameRequired(t *testing.T) {
	_, err := parseProfileManifestBytes([]byte("description: foo\n"))
	if err == nil || !strings.Contains(err.Error(), "name") {
		t.Errorf("expected name-required error, got %v", err)
	}
}

func TestParseProfileManifest_BadAgentName(t *testing.T) {
	_, err := parseProfileManifestBytes([]byte("name: Claude_Code\n"))
	if err == nil || !strings.Contains(err.Error(), "invalid character") {
		t.Errorf("expected invalid-char error, got %v", err)
	}
}

func TestParseProfileManifest_RejectUnknownKey(t *testing.T) {
	src := `name: claude-code
mystery_field: 42
`
	_, err := parseProfileManifestBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "mystery_field") {
		t.Errorf("expected unknown-field error, got %v", err)
	}
}

func TestParseProfileManifest_BadEnvName(t *testing.T) {
	src := `name: claude-code
env: [api_key]
`
	_, err := parseProfileManifestBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "POSIX env var") {
		t.Errorf("expected POSIX env var error, got %v", err)
	}
}

func TestParseProfileManifest_DstMustBeAbsolute(t *testing.T) {
	src := `name: claude-code
files:
  - src: settings.json
    dst: home/coder/settings.json
`
	_, err := parseProfileManifestBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "must be absolute") {
		t.Errorf("expected absolute-dst error, got %v", err)
	}
}

func TestParseProfileManifest_SrcMustBeRelative(t *testing.T) {
	src := `name: claude-code
files:
  - src: /etc/passwd
    dst: /home/coder/x
`
	_, err := parseProfileManifestBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "relative to the profile dir") {
		t.Errorf("expected relative-src error, got %v", err)
	}
}

func TestParseProfileManifest_RejectDotDotInSrc(t *testing.T) {
	src := `name: claude-code
files:
  - src: ../secrets
    dst: /home/coder/x
`
	_, err := parseProfileManifestBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "..") {
		t.Errorf("expected ..-rejection, got %v", err)
	}
}

func TestParseProfileManifest_EntrypointMustBeRelative(t *testing.T) {
	src := `name: claude-code
entrypoints:
  run: /usr/local/bin/claude
`
	_, err := parseProfileManifestBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "relative to the profile dir") {
		t.Errorf("expected relative-entrypoint error, got %v", err)
	}
}

func TestParseProfileManifest_OverridesPickedUp(t *testing.T) {
	src := `name: claude-code
entrypoints:
  run: bin/run-custom.sh
`
	m, err := parseProfileManifestBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if got := m.Entrypoint(EntrypointRun); got != "bin/run-custom.sh" {
		t.Errorf("run entrypoint = %q, want bin/run-custom.sh", got)
	}
}

func TestResolveProfile_BuiltinHit(t *testing.T) {
	repo := t.TempDir()
	writeManifest(t, filepath.Join(repo, "agent.profiles", "claude-code", "manifest.yaml"), "name: claude-code\n")
	ws := t.TempDir()

	dir, source, err := ResolveProfile(ws, repo, "claude-code")
	if err != nil {
		t.Fatal(err)
	}
	if source != "builtin" {
		t.Errorf("source = %q, want builtin", source)
	}
	if dir != filepath.Join(repo, "agent.profiles", "claude-code") {
		t.Errorf("dir = %q", dir)
	}
}

func TestResolveProfile_WorkspaceWins(t *testing.T) {
	repo := t.TempDir()
	writeManifest(t, filepath.Join(repo, "agent.profiles", "claude-code", "manifest.yaml"), "name: claude-code\n")
	ws := t.TempDir()
	writeManifest(t, filepath.Join(ws, ".rp", "agents", "claude-code", "manifest.yaml"), "name: claude-code\n")

	dir, source, err := ResolveProfile(ws, repo, "claude-code")
	if err != nil {
		t.Fatal(err)
	}
	if source != "workspace" {
		t.Errorf("source = %q, want workspace", source)
	}
	if dir != filepath.Join(ws, ".rp", "agents", "claude-code") {
		t.Errorf("dir = %q", dir)
	}
}

func TestResolveProfile_WorkspaceDirWithoutManifestIgnored(t *testing.T) {
	// A partial workspace override (script files present, manifest.yaml absent)
	// must NOT be picked — the builtin is the resolved profile. Lint flags this
	// as a partial-override warning (in Phase C).
	repo := t.TempDir()
	writeManifest(t, filepath.Join(repo, "agent.profiles", "claude-code", "manifest.yaml"), "name: claude-code\n")
	ws := t.TempDir()
	if err := os.MkdirAll(filepath.Join(ws, ".rp", "agents", "claude-code"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, ".rp", "agents", "claude-code", "run.sh"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	_, source, err := ResolveProfile(ws, repo, "claude-code")
	if err != nil {
		t.Fatal(err)
	}
	if source != "builtin" {
		t.Errorf("partial workspace override picked: source = %q", source)
	}
}

func TestResolveProfile_NotFound(t *testing.T) {
	repo := t.TempDir()
	ws := t.TempDir()
	_, _, err := ResolveProfile(ws, repo, "nonexistent")
	if err == nil || !strings.Contains(err.Error(), "no profile") {
		t.Errorf("expected not-found error, got %v", err)
	}
}

func TestResolveProfile_RejectBadAgentName(t *testing.T) {
	_, _, err := ResolveProfile("", "", "Has_Caps")
	if err == nil || !strings.Contains(err.Error(), "invalid character") {
		t.Errorf("expected validation error, got %v", err)
	}
}

func TestLoadResolvedProfile_ReportsParseErrorWithPath(t *testing.T) {
	repo := t.TempDir()
	writeManifest(t, filepath.Join(repo, "agent.profiles", "foo", "manifest.yaml"), "name: \"\"\n")
	_, _, _, err := LoadResolvedProfile("", repo, "foo")
	if err == nil || !strings.Contains(err.Error(), "name is required") {
		t.Errorf("expected name-required error with path, got %v", err)
	}
	if err != nil && !strings.Contains(err.Error(), "manifest.yaml") {
		t.Errorf("expected error to mention manifest.yaml path, got %v", err)
	}
}

func TestProjectConfig_AgentName(t *testing.T) {
	c := &ProjectConfig{}
	if c.AgentName() != "claude-code" {
		t.Errorf("empty config should default to claude-code, got %q", c.AgentName())
	}
	c.Agent = "opencode"
	if c.AgentName() != "opencode" {
		t.Errorf("got %q, want opencode", c.AgentName())
	}
}

func TestProjectConfig_RejectInvalidAgent(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("agent: Claude_Code\n"))
	if err == nil || !strings.Contains(err.Error(), "agent") {
		t.Errorf("expected agent validation error, got %v", err)
	}
}

func TestProjectConfig_AgentPasses(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("agent: opencode\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AgentName() != "opencode" {
		t.Errorf("agent = %q", cfg.AgentName())
	}
}

func TestProjectConfig_StripSudoDefault(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("image: foo\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.StripSudo {
		t.Errorf("strip_sudo should default to false")
	}
}

func TestProjectConfig_StripSudoTrue(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("image: foo\nuser: node\nstrip_sudo: true\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.StripSudo {
		t.Errorf("strip_sudo: true should parse to true")
	}
}

func TestProjectConfig_StripSudoFieldAccessor(t *testing.T) {
	cfg, _ := parseProjectConfigBytes([]byte("strip_sudo: true\n"))
	got, _ := projectConfigField(cfg, "strip_sudo")
	if got != "true" {
		t.Errorf("projectConfigField strip_sudo = %q, want \"true\"", got)
	}
	cfg, _ = parseProjectConfigBytes([]byte(""))
	got, _ = projectConfigField(cfg, "strip_sudo")
	if got != "" {
		t.Errorf("projectConfigField strip_sudo (default) = %q, want empty", got)
	}
}

func writeManifest(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestProfileManifest_VolumesParse(t *testing.T) {
	m, err := parseProfileManifestBytes([]byte(`name: foo
volumes:
  - name: claude-home
    mount: .claude
  - name: zsh-state
    mount: .local/share/zsh
`))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Volumes) != 2 {
		t.Fatalf("expected 2 volumes, got %v", m.Volumes)
	}
	if m.Volumes[0] != (ProfileVolume{Name: "claude-home", Mount: ".claude"}) {
		t.Errorf("volume[0] = %+v", m.Volumes[0])
	}
}

func TestProfileManifest_VolumeRejectAbsoluteMount(t *testing.T) {
	_, err := parseProfileManifestBytes([]byte(`name: foo
volumes:
  - name: bad
    mount: /etc
`))
	if err == nil {
		t.Error("expected error on absolute mount path")
	}
}

func TestProfileManifest_VolumeRejectDotDotMount(t *testing.T) {
	_, err := parseProfileManifestBytes([]byte(`name: foo
volumes:
  - name: bad
    mount: ../../escape
`))
	if err == nil {
		t.Error("expected error on .. in mount path")
	}
}

func TestProfileManifest_VolumeRejectDuplicateName(t *testing.T) {
	_, err := parseProfileManifestBytes([]byte(`name: foo
volumes:
  - name: home
    mount: .a
  - name: home
    mount: .b
`))
	if err == nil {
		t.Error("expected error on duplicate volume name")
	}
}

func TestProfileManifest_VolumesFieldAccessor(t *testing.T) {
	m, _ := parseProfileManifestBytes([]byte(`name: foo
volumes:
  - name: claude-home
    mount: .claude
`))
	got, err := profileManifestField(m, "volumes")
	if err != nil {
		t.Fatal(err)
	}
	if got != "claude-home\t.claude" {
		t.Errorf("volumes accessor = %q", got)
	}
}
