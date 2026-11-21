package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseProjectConfig_Empty(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte(""))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "" || cfg.Build != nil || cfg.User != "" {
		t.Errorf("expected empty config, got %+v", cfg)
	}
	if cfg.HasImageSource() {
		t.Errorf("empty config should not have image source")
	}
}

func TestParseProjectConfig_Image(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("image: ghcr.io/example/foo:v1\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "ghcr.io/example/foo:v1" {
		t.Errorf("image = %q", cfg.Image)
	}
	if !cfg.HasImageSource() {
		t.Errorf("expected HasImageSource")
	}
}

func TestParseProjectConfig_Build(t *testing.T) {
	src := `build:
  context: .
  dockerfile: Dockerfile
  args:
    NODE_VERSION: "22"
`
	cfg, err := parseProjectConfigBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Build == nil {
		t.Fatal("build is nil")
	}
	if cfg.Build.Context != "." {
		t.Errorf("context = %q", cfg.Build.Context)
	}
	if cfg.Build.Dockerfile != "Dockerfile" {
		t.Errorf("dockerfile = %q", cfg.Build.Dockerfile)
	}
	if cfg.Build.Args["NODE_VERSION"] != "22" {
		t.Errorf("args[NODE_VERSION] = %q", cfg.Build.Args["NODE_VERSION"])
	}
}

func TestParseProjectConfig_User(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("image: node:22-bookworm\nuser: node\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.User != "node" {
		t.Errorf("user = %q", cfg.User)
	}
}

func TestParseProjectConfig_RejectImageAndBuild(t *testing.T) {
	src := `image: foo
build:
  dockerfile: Dockerfile
`
	_, err := parseProjectConfigBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "both `image:` and `build:`") {
		t.Errorf("expected ambiguity error, got %v", err)
	}
}

func TestParseProjectConfig_RejectUnknownKey(t *testing.T) {
	src := `image: foo
depends_on:
  - bar
`
	_, err := parseProjectConfigBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "depends_on") {
		t.Errorf("expected error mentioning depends_on, got %v", err)
	}
}

func TestParseProjectConfig_RejectRootUser(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("image: foo\nuser: root\n"))
	if err == nil || !strings.Contains(err.Error(), "root") {
		t.Errorf("expected root rejection, got %v", err)
	}
}

func TestParseProjectConfig_RejectInvalidUser(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("image: foo\nuser: \"bad user\"\n"))
	if err == nil || !strings.Contains(err.Error(), "invalid character") {
		t.Errorf("expected invalid-char error, got %v", err)
	}
}

func TestParseProjectConfig_BuildRequiresDockerfile(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("build:\n  context: .\n"))
	if err == nil || !strings.Contains(err.Error(), "dockerfile") {
		t.Errorf("expected dockerfile-required error, got %v", err)
	}
}

func TestResolveContext_Default(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Dockerfile: "Dockerfile"}}
	got, err := cfg.ResolveContext(ws)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(ws, ".rp")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveContext_DotDotToWorkspaceRoot(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: "..", Dockerfile: "Dockerfile"}}
	got, err := cfg.ResolveContext(ws)
	if err != nil {
		t.Fatal(err)
	}
	if got != filepath.Clean(ws) {
		t.Errorf("got %q, want %q", got, ws)
	}
}

func TestResolveContext_EscapeRejected(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: "../..", Dockerfile: "Dockerfile"}}
	_, err := cfg.ResolveContext(ws)
	if err == nil || !strings.Contains(err.Error(), "outside workspace") {
		t.Errorf("expected escape rejection, got %v", err)
	}
}

func TestResolveContext_AbsoluteRejected(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: "/etc", Dockerfile: "Dockerfile"}}
	_, err := cfg.ResolveContext(ws)
	if err == nil || !strings.Contains(err.Error(), "absolute") {
		t.Errorf("expected absolute rejection, got %v", err)
	}
}

func TestResolveDockerfile_InContext(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: ".", Dockerfile: "Dockerfile.dev"}}
	got, err := cfg.ResolveDockerfile(ws)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(ws, ".rp", "Dockerfile.dev")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveDockerfile_EscapeRejected(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: ".", Dockerfile: "../Dockerfile"}}
	_, err := cfg.ResolveDockerfile(ws)
	if err == nil || !strings.Contains(err.Error(), "escapes") {
		t.Errorf("expected escape rejection, got %v", err)
	}
}

func TestParseProjectConfig_MissingFile(t *testing.T) {
	cfg, err := ParseProjectConfig("/nonexistent/.rp/config.yaml")
	if err != nil {
		t.Fatalf("missing file should not error: %v", err)
	}
	if cfg.HasImageSource() {
		t.Errorf("missing file should yield empty config")
	}
}

func TestParseProjectConfig_Resources(t *testing.T) {
	src := `image: debian:bookworm-slim
resources:
  memory: 4G
  cpus: 2
`
	cfg, err := parseProjectConfigBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Resources == nil {
		t.Fatal("Resources is nil")
	}
	if cfg.Resources.Memory != "4G" {
		t.Errorf("memory = %q", cfg.Resources.Memory)
	}
	if cfg.Resources.CPUs != 2 {
		t.Errorf("cpus = %d", cfg.Resources.CPUs)
	}
}

func TestParseProjectConfig_FuseCache(t *testing.T) {
	src := `image: debian:bookworm-slim
fuse:
  cache: 0.5
`
	cfg, err := parseProjectConfigBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Fuse == nil || cfg.Fuse.Cache == nil {
		t.Fatal("Fuse.Cache is nil")
	}
	if *cfg.Fuse.Cache != 0.5 {
		t.Errorf("cache = %f", *cfg.Fuse.Cache)
	}
}

func TestParseProjectConfig_FuseCacheZero(t *testing.T) {
	// Zero is valid (=disable caching). Tests that the *float64 pointer
	// correctly distinguishes "unset" from "explicit zero".
	src := "fuse:\n  cache: 0\n"
	cfg, err := parseProjectConfigBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Fuse == nil || cfg.Fuse.Cache == nil {
		t.Fatal("Cache is nil; zero should still set it")
	}
	if *cfg.Fuse.Cache != 0.0 {
		t.Errorf("cache = %f, want 0.0", *cfg.Fuse.Cache)
	}
}

func TestParseProjectConfig_RejectBadMemory(t *testing.T) {
	cases := []string{
		"resources:\n  memory: abc\n",
		"resources:\n  memory: 0G\n",
		"resources:\n  memory: 4XB\n",
	}
	for _, src := range cases {
		_, err := parseProjectConfigBytes([]byte(src))
		if err == nil || !strings.Contains(err.Error(), "resources.memory") {
			t.Errorf("expected memory rejection for %q, got %v", src, err)
		}
	}
}

func TestParseProjectConfig_RejectNegativeCPUs(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("resources:\n  cpus: -1\n"))
	if err == nil || !strings.Contains(err.Error(), "resources.cpus") {
		t.Errorf("expected cpus rejection, got %v", err)
	}
}

func TestParseProjectConfig_RejectNegativeCache(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("fuse:\n  cache: -0.5\n"))
	if err == nil || !strings.Contains(err.Error(), "fuse.cache") {
		t.Errorf("expected cache rejection, got %v", err)
	}
}

func TestValidateMemorySize(t *testing.T) {
	good := []string{"1", "100", "512M", "4G", "16g", "2T", "1024K"}
	for _, s := range good {
		if err := validateMemorySize(s); err != nil {
			t.Errorf("expected %q to be valid, got %v", s, err)
		}
	}
	bad := []string{"", "abc", "0", "0G", "4XB", "4.5G", " 4G", "G"}
	for _, s := range bad {
		if err := validateMemorySize(s); err == nil {
			t.Errorf("expected %q to be invalid", s)
		}
	}
}

func TestParseProjectConfig_FromFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(path, []byte("image: alpine\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := ParseProjectConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "alpine" {
		t.Errorf("image = %q", cfg.Image)
	}
}

func TestParseProjectConfig_HostAliasesScalar(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("host_aliases:\n  - mac.local\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.HostAliases) != 1 {
		t.Fatalf("expected 1 alias, got %v", cfg.HostAliases)
	}
	if cfg.HostAliases[0].Name != "mac.local" || cfg.HostAliases[0].IP != "" {
		t.Errorf("scalar alias = %+v, want {Name:mac.local IP:}", cfg.HostAliases[0])
	}
}

func TestParseProjectConfig_HostAliasesMapping(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("host_aliases:\n  - name: postgres.dev\n    ip: 192.168.64.10\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.HostAliases) != 1 {
		t.Fatalf("expected 1 alias, got %v", cfg.HostAliases)
	}
	want := HostAlias{Name: "postgres.dev", IP: "192.168.64.10"}
	if cfg.HostAliases[0] != want {
		t.Errorf("mapping alias = %+v, want %+v", cfg.HostAliases[0], want)
	}
}

func TestHostAliasesEffective_AlwaysIncludesGateway(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte(""))
	if err != nil {
		t.Fatal(err)
	}
	effective := cfg.HostAliasesEffective()
	if len(effective) != 1 || effective[0].Name != "host.containers.internal" || effective[0].IP != "host-gateway" {
		t.Errorf("empty config effective = %+v, want [host.containers.internal=host-gateway]", effective)
	}
}

func TestHostAliasesEffective_UserCanShadowDefault(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("host_aliases:\n  - name: host.containers.internal\n    ip: 10.0.0.1\n"))
	if err != nil {
		t.Fatal(err)
	}
	effective := cfg.HostAliasesEffective()
	if len(effective) != 1 || effective[0].IP != "10.0.0.1" {
		t.Errorf("user override = %+v, want IP=10.0.0.1", effective)
	}
}

func TestParseProjectConfig_RejectBadHostAlias(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("host_aliases:\n  - \"bad name with spaces\"\n"))
	if err == nil {
		t.Error("expected error on hostname with spaces")
	}
}

func TestParseProjectConfig_RejectBadIP(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("host_aliases:\n  - name: x.local\n    ip: 999.0.0.1\n"))
	if err == nil {
		t.Error("expected error on out-of-range IPv4 octet")
	}
}

func TestParseProjectConfig_PluginsParse(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte(`plugins:
  marketplaces:
    - jarrodwatts/claude-hud
  install:
    - claude-hud@jarrodwatts-claude-hud
`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Plugins == nil || len(cfg.Plugins.Marketplaces) != 1 || len(cfg.Plugins.Install) != 1 {
		t.Fatalf("plugins = %+v", cfg.Plugins)
	}
}

func TestParseProjectConfig_PluginsRejectInjection(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("plugins:\n  install:\n    - 'evil; rm -rf /'\n"))
	if err == nil {
		t.Error("expected error on shell-injection in plugins.install")
	}
}

func TestProjectConfigPluginsFieldAccessor(t *testing.T) {
	cfg, _ := parseProjectConfigBytes([]byte("plugins:\n  install:\n    - x@a\n"))
	got, _ := projectConfigField(cfg, "plugins.install")
	if got != "x@a" {
		t.Errorf("plugins.install accessor = %q", got)
	}
}

func TestParseProjectConfig_HostFilesParse(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte(`host_files:
  - src: ~/.gitconfig
    dst: /home/coder/.gitconfig
`))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.HostFiles) != 1 || cfg.HostFiles[0].Src != "~/.gitconfig" {
		t.Errorf("HostFiles = %+v", cfg.HostFiles)
	}
}

func TestParseProjectConfig_HostKeychainParse(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte(`host_keychain:
  - service: Foo
    dst: /home/coder/.foo
`))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.HostKeychain) != 1 || cfg.HostKeychain[0].Service != "Foo" {
		t.Errorf("HostKeychain = %+v", cfg.HostKeychain)
	}
}

func TestProjectConfig_HostFilesFieldAccessor(t *testing.T) {
	cfg, _ := parseProjectConfigBytes([]byte("host_files:\n  - src: ~/.x\n    dst: /h/.x\n"))
	got, _ := projectConfigField(cfg, "host_files")
	if got != "~/.x\t/h/.x\tskip" {
		t.Errorf("host_files accessor = %q", got)
	}
}

func TestParseProjectConfig_HostPathAliasesParse(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("host_path_aliases:\n  - ~/.claude\n  - ~/.config/zsh\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.HostPathAliases) != 2 {
		t.Fatalf("HostPathAliases = %v", cfg.HostPathAliases)
	}
}

func TestParseProjectConfig_HostPathAliasesRejectAbsolute(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("host_path_aliases:\n  - /Users/me/.claude\n"))
	if err == nil {
		t.Error("expected error on non-~ host_path_aliases entry")
	}
}

func TestParseProjectConfig_HostPathAliasesRejectDotDot(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("host_path_aliases:\n  - ~/../escape\n"))
	if err == nil {
		t.Error("expected error on .. in host_path_aliases")
	}
}

func TestProjectConfig_HostPathAliasesFieldAccessor(t *testing.T) {
	cfg, _ := parseProjectConfigBytes([]byte("host_path_aliases:\n  - ~/.claude\n  - ~/.config\n"))
	got, _ := projectConfigField(cfg, "host_path_aliases")
	if got != "~/.claude\n~/.config" {
		t.Errorf("host_path_aliases accessor = %q", got)
	}
}

func TestParseProjectConfig_LocalMerge_ListsAppend(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte(`host_path_aliases:
  - ~/.claude
plugins:
  install:
    - shared@market
`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "config.local.yaml"), []byte(`host_path_aliases:
  - ~/.zshrc
plugins:
  install:
    - personal@market
`), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := ParseProjectConfig(filepath.Join(dir, "config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.HostPathAliases) != 2 {
		t.Errorf("host_path_aliases = %v, want 2 entries appended", cfg.HostPathAliases)
	}
	if len(cfg.Plugins.Install) != 2 {
		t.Errorf("plugins.install = %v, want 2 entries appended", cfg.Plugins.Install)
	}
}

func TestParseProjectConfig_LocalMerge_ScalarsOverride(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte(`image: shared-image
user: coder
resources:
  memory: 4G
  cpus: 2
`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "config.local.yaml"), []byte(`image: my-image
resources:
  memory: 8G
`), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := ParseProjectConfig(filepath.Join(dir, "config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "my-image" {
		t.Errorf("image = %q, want my-image (local wins)", cfg.Image)
	}
	if cfg.User != "coder" {
		t.Errorf("user = %q, want coder (preserved from base)", cfg.User)
	}
	if cfg.Resources.Memory != "8G" {
		t.Errorf("memory = %q, want 8G (local wins)", cfg.Resources.Memory)
	}
	if cfg.Resources.CPUs != 2 {
		t.Errorf("cpus = %d, want 2 (preserved from base)", cfg.Resources.CPUs)
	}
}

// Regression test: a plain bool zero-value is indistinguishable from an
// explicit false, so a naive `if other.StripSudo { c.StripSudo = true }`
// merge can only ever flip false->true, never override true back to
// false. config.local.yaml must be able to switch a workspace from
// strip_sudo back off (e.g. toward allow_sudo instead) — verify it can.
func TestParseProjectConfig_LocalMerge_BoolScalarOverridesToFalse(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte(`user: node
strip_sudo: true
`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "config.local.yaml"), []byte(`strip_sudo: false
allow_sudo: true
`), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := ParseProjectConfig(filepath.Join(dir, "config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.StripSudo == nil || *cfg.StripSudo {
		t.Errorf("strip_sudo = %v, want false (local override)", cfg.StripSudo)
	}
	if cfg.AllowSudo == nil || !*cfg.AllowSudo {
		t.Errorf("allow_sudo = %v, want true (local override)", cfg.AllowSudo)
	}
}

func TestParseProjectConfig_LocalMerge_NoLocalNoChange(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), []byte("image: foo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := ParseProjectConfig(filepath.Join(dir, "config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "foo" {
		t.Errorf("image = %q, want foo", cfg.Image)
	}
}

func TestParseProjectConfig_AllowSudoParse(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("allow_sudo: true\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AllowSudo == nil || !*cfg.AllowSudo {
		t.Errorf("AllowSudo = %v, want true", cfg.AllowSudo)
	}
}

func TestProjectConfig_AllowSudoFieldAccessor(t *testing.T) {
	cfg, _ := parseProjectConfigBytes([]byte("allow_sudo: true\n"))
	got, _ := projectConfigField(cfg, "allow_sudo")
	if got != "true" {
		t.Errorf("allow_sudo accessor = %q", got)
	}
	cfg, _ = parseProjectConfigBytes([]byte(""))
	got, _ = projectConfigField(cfg, "allow_sudo")
	if got != "" {
		t.Errorf("empty allow_sudo accessor = %q, want empty", got)
	}
}

// writeWorktree fakes the .git indirection of a linked worktree: <wt>/.git
// points at <common>/worktrees/<id>, whose commondir points back.
func writeWorktree(t *testing.T, wt, common, id string, relative bool) {
	t.Helper()
	admin := filepath.Join(common, "worktrees", id)
	for _, d := range []string{admin, filepath.Join(wt, ".rp")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(admin, "commondir"), []byte("../..\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitdir := admin
	if relative {
		rel, err := filepath.Rel(wt, admin)
		if err != nil {
			t.Fatal(err)
		}
		gitdir = rel
	}
	if err := os.WriteFile(filepath.Join(wt, ".git"), []byte("gitdir: "+gitdir+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRepoHome_Layouts(t *testing.T) {
	root := t.TempDir()
	// Layout B: worktree added from a regular checkout.
	writeWorktree(t, filepath.Join(root, "projb-feat"), filepath.Join(root, "projb", ".git"), "projb-feat", false)
	// Layout A: bare repo inside the project folder, relative gitdir.
	writeWorktree(t, filepath.Join(root, "proja", "main"), filepath.Join(root, "proja", ".bare"), "main", true)
	// Layout C: central bare repo.
	writeWorktree(t, filepath.Join(root, "src", "projc-main"), filepath.Join(root, "repos", "projc.git"), "projc-main", false)
	// Plain clone: .git is a directory.
	if err := os.MkdirAll(filepath.Join(root, "plain", ".git"), 0o755); err != nil {
		t.Fatal(err)
	}

	cases := []struct{ ws, want string }{
		{filepath.Join(root, "projb-feat"), filepath.Join(root, "projb")},
		{filepath.Join(root, "proja", "main"), filepath.Join(root, "proja")},
		{filepath.Join(root, "src", "projc-main"), ""},
		{filepath.Join(root, "plain"), ""},
		{filepath.Join(root, "missing"), ""},
	}
	for _, c := range cases {
		if got := RepoHome(c.ws); got != c.want {
			t.Errorf("RepoHome(%s) = %q, want %q", c.ws, got, c.want)
		}
	}
}

func TestParseProjectConfig_RepoHomeFallback(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "proj")
	wt := filepath.Join(root, "proj-feat")
	writeWorktree(t, wt, filepath.Join(home, ".git"), "proj-feat", false)
	writeFile(t, filepath.Join(wt, ".rp", "config.yaml"), "user: coder\nplugins:\n  install:\n    - team@market\n")
	writeFile(t, filepath.Join(home, ".rp", "config.local.yaml"), "image: home-image\nplugins:\n  install:\n    - personal@market\n")
	cfgPath := filepath.Join(wt, ".rp", "config.yaml")

	cfg, err := ParseProjectConfig(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "home-image" || cfg.User != "coder" {
		t.Errorf("image=%q user=%q, want home-image + coder", cfg.Image, cfg.User)
	}
	if got := strings.Join(cfg.Plugins.Install, ","); got != "team@market,personal@market" {
		t.Errorf("plugins.install = %s, want committed then repo-home entries", got)
	}

	// The worktree's own config.local.yaml is layered last and wins.
	writeFile(t, filepath.Join(wt, ".rp", "config.local.yaml"), "image: task-image\n")
	cfg, err = ParseProjectConfig(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "task-image" {
		t.Errorf("image = %q, want task-image (worktree layer wins)", cfg.Image)
	}
	layers := ConfigLayers(cfgPath)
	if len(layers) != 3 || layers[1] != filepath.Join(home, ".rp", "config.local.yaml") {
		t.Errorf("layers = %v, want config.yaml, repo home, worktree", layers)
	}
}

func TestParseProjectConfig_NoFallbackForCentralBareRepo(t *testing.T) {
	root := t.TempDir()
	wt := filepath.Join(root, "src", "projc-main")
	writeWorktree(t, wt, filepath.Join(root, "repos", "projc.git"), "projc-main", false)
	// A file in the shared parent of central repos must not leak in.
	writeFile(t, filepath.Join(root, "repos", ".rp", "config.local.yaml"), "image: wrong\n")
	cfg, err := ParseProjectConfig(filepath.Join(wt, ".rp", "config.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "" {
		t.Errorf("image = %q, want empty (no fallback in layout C)", cfg.Image)
	}
}
