package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// LintEntry is one diagnosed line from a .rp/shadow file.
type LintEntry struct {
	Line    int    // 1-based source line number
	Raw     string // raw pattern as written, trimmed of whitespace
	Status  string // "ok" | "warn" | "err"
	Class   string // "literal-unanchored" | "literal-anchored" | "glob-anchored" | "glob-unanchored" | "" if not applicable
	Key     string // lookup key for fast-path buckets; raw pattern for globs
	Message string // human-readable note when status != ok
}

// runLint is the entrypoint for `rp-fuse lint`.
//
// Default behavior: lints `.rp/shadow` (the rules file) AND validates
// `.rp/config.yaml` if it exists. Either file is optional; an empty
// workspace is a no-op success. An explicit shadow path argument turns
// off the config.yaml side and lints only the named file.
//
// Exit codes: 1 if any error-status line in shadow or invalid config; 2
// on argument / IO errors.
func runLint(args []string) {
	fs := flag.NewFlagSet("lint", flag.ExitOnError)
	matchPath := fs.String("match", "", "report whether this workspace-relative path would be shadowed")
	workspace := fs.String("workspace", ".", "workspace directory (default: current dir)")
	repoDir := fs.String("repo-dir", "", "robo-pen-default repo dir (skips profile lint if empty)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: rp-fuse lint [--match <path>] [--workspace <ws>] [--repo-dir <repo>] [<.rp/shadow file>]")
		fmt.Fprintln(os.Stderr, "  Default: lints .rp/shadow, validates .rp/config.yaml, and resolves the agent profile.")
		fs.PrintDefaults()
	}
	_ = fs.Parse(args)

	exitCode := 0

	shadowPath := filepath.Join(*workspace, ".rp", "shadow")
	explicit := fs.NArg() > 0
	if explicit {
		shadowPath = fs.Arg(0)
	}

	hadShadow := lintShadow(shadowPath, *matchPath, explicit, &exitCode)

	if !explicit {
		configPath := filepath.Join(*workspace, ".rp", "config.yaml")
		hadConfig := false
		var cfg *ProjectConfig
		if _, err := os.Stat(configPath); err == nil {
			if hadShadow {
				fmt.Println()
			}
			cfg = lintConfig(configPath, &exitCode)
			hadConfig = true
		}
		if *repoDir != "" {
			agent := DefaultAgent
			if cfg != nil {
				agent = cfg.AgentName()
			}
			if hadShadow || hadConfig {
				fmt.Println()
			}
			lintProfile(*workspace, *repoDir, agent, cfg, &exitCode)
		}
	}

	if exitCode != 0 {
		os.Exit(exitCode)
	}
}

// lintShadow lints a single .rp/shadow file. Returns true if the file
// existed and was processed. `explicit` distinguishes "user passed a path"
// from "default-discover at .rp/shadow" — the former errors on missing
// file, the latter falls through silently.
func lintShadow(path, matchPath string, explicit bool, exitCode *int) bool {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) && !explicit {
			return false
		}
		fmt.Fprintf(os.Stderr, "rp-fuse lint: %v\n", err)
		*exitCode = 2
		return false
	}
	defer f.Close()

	entries, err := lintReader(f)
	if err != nil {
		fmt.Fprintf(os.Stderr, "rp-fuse lint: read %s: %v\n", path, err)
		*exitCode = 2
		return false
	}

	var active, warns, errs int
	maxRaw := 0
	for _, e := range entries {
		if l := len(e.Raw); l > maxRaw {
			maxRaw = l
		}
		switch e.Status {
		case "ok":
			active++
		case "warn":
			warns++
		case "err":
			errs++
		}
	}
	if maxRaw < 8 {
		maxRaw = 8
	}
	for _, e := range entries {
		fmt.Printf("%s:%d: %-*s  %-4s  %s\n",
			path, e.Line, maxRaw, e.Raw, strings.ToUpper(e.Status), describe(e))
	}
	fmt.Printf("\nSummary: %d active, %d warning, %d error\n", active, warns, errs)

	if matchPath != "" {
		fmt.Printf("\nMatch report for path %q:\n", matchPath)
		matches := matchAgainst(matchPath, entries)
		if len(matches) == 0 {
			fmt.Println("  not matched by any active rule")
		} else {
			for _, m := range matches {
				fmt.Printf("  matched by line %d: %s (%s)\n", m.Line, m.Raw, m.Class)
			}
		}
	}

	if errs > 0 && *exitCode < 1 {
		*exitCode = 1
	}
	return true
}

// lintConfig parses .rp/config.yaml and prints a short summary line.
// Returns the parsed config (nil on parse error) so the caller can re-use
// the agent name for profile lint.
func lintConfig(path string, exitCode *int) *ProjectConfig {
	cfg, err := ParseProjectConfig(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
		if *exitCode < 1 {
			*exitCode = 1
		}
		return nil
	}

	source := "default (robo-pen-default)"
	switch {
	case cfg.Image != "":
		source = "image: " + cfg.Image
	case cfg.Build != nil:
		source = "build: " + cfg.Build.Dockerfile
	}
	user := cfg.User
	if user == "" {
		user = "coder (default)"
	}
	agent := cfg.AgentName()
	if cfg.Agent == "" {
		agent += " (default)"
	}
	fmt.Printf("%s: OK\n", path)
	fmt.Printf("  agent: %s\n", agent)
	fmt.Printf("  image source: %s\n", source)
	fmt.Printf("  container user: %s\n", user)
	if cfg.Resources != nil {
		if cfg.Resources.Memory != "" {
			fmt.Printf("  resources.memory: %s\n", cfg.Resources.Memory)
		}
		if cfg.Resources.CPUs > 0 {
			fmt.Printf("  resources.cpus: %d\n", cfg.Resources.CPUs)
		}
	}
	if cfg.Fuse != nil && cfg.Fuse.Cache != nil {
		fmt.Printf("  fuse.cache: %g\n", *cfg.Fuse.Cache)
	}
	// Always show the effective host aliases (includes the implicit
	// host.containers.internal entry) — the user may not know it's added
	// automatically and lint is the place to surface it.
	aliases := cfg.HostAliasesEffective()
	if len(aliases) > 0 {
		fmt.Printf("  host_aliases:\n")
		for _, a := range aliases {
			fmt.Printf("    - %s → %s\n", a.Name, a.IP)
		}
	}
	return cfg
}

// lintProfile resolves and validates the agent profile bundle. Reports the
// source ("workspace" or "builtin"), checks required entrypoints exist as
// executable files, warns on missing optional entrypoints + partial workspace
// overrides + host env vars declared but unset.
func lintProfile(workspace, repoDir, agent string, cfg *ProjectConfig, exitCode *int) {
	// Detect partial workspace override: directory exists, manifest.yaml missing.
	wsDir := filepath.Join(workspace, ".rp", "agents", agent)
	if info, err := os.Stat(wsDir); err == nil && info.IsDir() {
		if _, err := os.Stat(filepath.Join(wsDir, "manifest.yaml")); err != nil {
			fmt.Printf("agent profile %s: WARN partial workspace override at %s lacks manifest.yaml; falling through to builtin\n", agent, wsDir)
			if *exitCode < 1 {
				*exitCode = 0 // warn, not err
			}
		}
	}

	m, dir, source, err := LoadResolvedProfile(workspace, repoDir, agent)
	if err != nil {
		fmt.Fprintf(os.Stderr, "agent profile %s: %v\n", agent, err)
		if *exitCode < 1 {
			*exitCode = 1
		}
		return
	}

	fmt.Printf("agent profile %s: OK (%s)\n", agent, source)
	fmt.Printf("  dir: %s\n", dir)
	if m.Description != "" {
		fmt.Printf("  description: %s\n", m.Description)
	}

	for _, kind := range []struct {
		name     string
		required bool
	}{
		{EntrypointInstall, true},
		{EntrypointRun, true},
		{EntrypointRunGated, false},
		{EntrypointLogin, false},
	} {
		rel := m.Entrypoint(kind.name)
		full := filepath.Join(dir, rel)
		info, err := os.Stat(full)
		switch {
		case err != nil:
			if kind.required {
				fmt.Printf("  ERR  entrypoint %s: %s not found\n", kind.name, rel)
				if *exitCode < 1 {
					*exitCode = 1
				}
			} else {
				fmt.Printf("  WARN entrypoint %s: %s not found (optional)\n", kind.name, rel)
			}
		case info.Mode()&0o111 == 0:
			fmt.Printf("  WARN entrypoint %s: %s exists but is not executable\n", kind.name, rel)
		default:
			fmt.Printf("  OK   entrypoint %s: %s\n", kind.name, rel)
		}
	}

	containerUser := "coder"
	if cfg != nil && cfg.User != "" {
		containerUser = cfg.User
	}
	for _, f := range m.Files {
		expanded := strings.ReplaceAll(f.Dst, "{{user}}", containerUser)
		if !strings.HasPrefix(expanded, "/home/"+containerUser+"/") {
			fmt.Printf("  WARN file dst %q resolves to %q which is outside /home/%s/\n", f.Dst, expanded, containerUser)
		}
	}

	for _, v := range m.Env {
		if _, present := os.LookupEnv(v); !present {
			fmt.Printf("  INFO env %s declared by profile but unset on host\n", v)
		}
	}

	// Show host_files / host_keychain imports so users see what gets
	// copied at create-time and can flag missing sources before running.
	if len(m.HostFiles) > 0 {
		fmt.Printf("  host_files:\n")
		for _, h := range m.HostFiles {
			expanded := strings.ReplaceAll(h.Src, "~", os.Getenv("HOME"))
			marker := "OK"
			if _, err := os.Stat(expanded); err != nil {
				if h.IfMissing == "error" {
					marker = "ERR (if_missing=error)"
				} else {
					marker = "MISSING (will skip)"
				}
			}
			fmt.Printf("    - %s → %s [%s]\n", h.Src, h.Dst, marker)
		}
	}
	if len(m.HostKeychain) > 0 {
		fmt.Printf("  host_keychain:\n")
		for _, k := range m.HostKeychain {
			fmt.Printf("    - %s → %s (mode %s)\n", k.Service, k.Dst, firstNonEmpty(k.Mode, "0600"))
		}
	}
}

func describe(e LintEntry) string {
	if e.Message != "" {
		return e.Message
	}
	return e.Class
}

// lintReader walks the .rp/shadow content and classifies each non-empty
// line. Errors and warnings do not abort — they show up as entries with
// their own Status. Returns I/O errors from the scanner.
func lintReader(r io.Reader) ([]LintEntry, error) {
	var out []LintEntry
	seen := map[string]int{}
	sc := bufio.NewScanner(r)
	for lineNo := 0; sc.Scan(); {
		lineNo++
		raw := strings.TrimRight(sc.Text(), "\r")
		trim := strings.TrimSpace(raw)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		// Negation is now supported (ADR-0011). Validate the body just like
		// any other pattern — '!' is the only special prefix and otherwise
		// rules follow the same syntax constraints.
		body := trim
		if strings.HasPrefix(body, "!") {
			body = strings.TrimPrefix(body, "!")
		}
		if err := validatePattern(body); err != nil {
			out = append(out, LintEntry{
				Line: lineNo, Raw: trim, Status: "err",
				Message: err.Error() + "; skipped",
			})
			continue
		}
		if dup, ok := seen[trim]; ok {
			out = append(out, LintEntry{
				Line: lineNo, Raw: trim, Status: "warn",
				Message: fmt.Sprintf("duplicate of line %d", dup),
			})
			continue
		}
		seen[trim] = lineNo
		// classify operates on the pattern body (without the '!' prefix);
		// negation is orthogonal to whether the pattern is anchored / glob /
		// unanchored.
		kind, key := classify(body)
		out = append(out, LintEntry{
			Line:   lineNo,
			Raw:    trim,
			Status: "ok",
			Class:  className(kind, body),
			Key:    key,
		})
	}
	return out, sc.Err()
}

func className(kind patKind, raw string) string {
	switch kind {
	case patUnanchored:
		return "literal-unanchored"
	case patAnchored:
		return "literal-anchored"
	case patGlob:
		if strings.HasPrefix(raw, "/") || strings.Contains(strings.TrimSuffix(raw, "/"), "/") {
			if strings.HasPrefix(raw, "**/") {
				return "glob-unanchored"
			}
			return "glob-anchored"
		}
		return "glob-unanchored"
	}
	return "unknown"
}

// matchAgainst runs each active lint entry against a candidate path and
// returns the entries that match. Reuses the same engine the FUSE driver
// uses, so lint output matches actual runtime behavior.
func matchAgainst(path string, entries []LintEntry) []LintEntry {
	var matched []LintEntry
	for _, e := range entries {
		if e.Status != "ok" {
			continue
		}
		r, _ := parseRulesReader(strings.NewReader(e.Raw + "\n"))
		if r.Match(path) {
			matched = append(matched, e)
		}
	}
	return matched
}
