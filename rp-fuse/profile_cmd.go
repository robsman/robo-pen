package main

// The `profile` subcommand lets shell scripts (build-project-image.sh,
// Justfile recipes) resolve and read agent profile bundles without
// re-implementing the YAML parser or the workspace/builtin lookup order.

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// runProfile is the entrypoint for `rp-fuse profile`.
func runProfile(args []string) {
	fs := flag.NewFlagSet("profile", flag.ExitOnError)
	workspace := fs.String("workspace", "", "absolute path of the workspace directory")
	repoDir := fs.String("repo-dir", "", "absolute path of the robo-pen-default repo (where agent.profiles/ lives)")
	agent := fs.String("agent", "", "agent profile name (overrides .rp/config.yaml if set)")
	configPath := fs.String("config", "", "path to .rp/config.yaml (used to determine agent when --agent is unset)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: rp-fuse profile --workspace <ws> --repo-dir <repo> [--agent <name>|--config <path>] <subcommand>")
		fmt.Fprintln(os.Stderr, "Subcommands:")
		fmt.Fprintln(os.Stderr, "  resolve            print absolute profile directory")
		fmt.Fprintln(os.Stderr, "  source             print profile source: workspace | builtin")
		fmt.Fprintln(os.Stderr, "  show               print manifest fields, one per line")
		fmt.Fprintln(os.Stderr, "  validate           parse + validate; exit 0 on success, 1 on error")
		fmt.Fprintln(os.Stderr, "  field <name>       print one field (name, description, env, entrypoint.install,")
		fmt.Fprintln(os.Stderr, "                                       entrypoint.run, entrypoint.run_gated,")
		fmt.Fprintln(os.Stderr, "                                       entrypoint.login, instructions_dst, files)")
	}
	_ = fs.Parse(args)

	if fs.NArg() < 1 {
		fs.Usage()
		os.Exit(2)
	}

	agentName, err := resolveAgentName(*agent, *configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "rp-fuse profile: %v\n", err)
		os.Exit(1)
	}

	sub := fs.Arg(0)
	subArgs := fs.Args()[1:]

	dir, source, err := ResolveProfile(*workspace, *repoDir, agentName)
	if err != nil {
		fmt.Fprintf(os.Stderr, "rp-fuse profile: %v\n", err)
		os.Exit(1)
	}

	switch sub {
	case "resolve":
		fmt.Println(dir)
		return
	case "source":
		fmt.Println(source)
		return
	}

	m, err := ParseProfileManifest(dir + "/manifest.yaml")
	if err != nil {
		fmt.Fprintf(os.Stderr, "rp-fuse profile: %v\n", err)
		os.Exit(1)
	}

	switch sub {
	case "validate":
		return
	case "show":
		showProfileManifest(m, dir, source)
		return
	case "field":
		if len(subArgs) < 1 {
			fmt.Fprintln(os.Stderr, "rp-fuse profile field: name required")
			os.Exit(2)
		}
		out, err := profileManifestField(m, subArgs[0])
		if err != nil {
			fmt.Fprintf(os.Stderr, "rp-fuse profile field: %v\n", err)
			os.Exit(1)
		}
		if out != "" {
			fmt.Println(out)
		}
		return
	}
	fmt.Fprintf(os.Stderr, "rp-fuse profile: unknown subcommand %q\n", sub)
	os.Exit(2)
}

// resolveAgentName picks the agent name from --agent (highest priority) or
// the parsed .rp/config.yaml (`agent:` field, default `claude-code`).
func resolveAgentName(flagAgent, configPath string) (string, error) {
	if flagAgent != "" {
		if err := validateAgentName(flagAgent); err != nil {
			return "", fmt.Errorf("--agent: %w", err)
		}
		return flagAgent, nil
	}
	if configPath != "" {
		cfg, err := ParseProjectConfig(configPath)
		if err != nil {
			return "", err
		}
		return cfg.AgentName(), nil
	}
	return DefaultAgent, nil
}

func showProfileManifest(m *ProfileManifest, dir, source string) {
	fmt.Printf("dir: %s\n", dir)
	fmt.Printf("source: %s\n", source)
	fmt.Printf("name: %s\n", m.Name)
	fmt.Printf("description: %s\n", emptyDash(m.Description))
	if len(m.Env) > 0 {
		fmt.Printf("env: %s\n", strings.Join(m.Env, ", "))
	} else {
		fmt.Println("env: -")
	}
	fmt.Printf("instructions_dst: %s\n", emptyDash(m.InstructionsDst))
	fmt.Println("entrypoints:")
	fmt.Printf("  install:   %s\n", m.Entrypoint(EntrypointInstall))
	fmt.Printf("  run:       %s\n", m.Entrypoint(EntrypointRun))
	fmt.Printf("  run_gated: %s\n", m.Entrypoint(EntrypointRunGated))
	fmt.Printf("  login:     %s\n", m.Entrypoint(EntrypointLogin))
	if len(m.Files) > 0 {
		fmt.Println("files:")
		for _, f := range m.Files {
			fmt.Printf("  %s -> %s\n", f.Src, f.Dst)
		}
	} else {
		fmt.Println("files: -")
	}
}

func profileManifestField(m *ProfileManifest, name string) (string, error) {
	switch name {
	case "name":
		return m.Name, nil
	case "description":
		return m.Description, nil
	case "instructions_dst":
		return m.InstructionsDst, nil
	case "env":
		return strings.Join(m.Env, "\n"), nil
	case "entrypoint.install":
		return m.Entrypoint(EntrypointInstall), nil
	case "entrypoint.run":
		return m.Entrypoint(EntrypointRun), nil
	case "entrypoint.run_gated":
		return m.Entrypoint(EntrypointRunGated), nil
	case "entrypoint.login":
		return m.Entrypoint(EntrypointLogin), nil
	case "files":
		var lines []string
		for _, f := range m.Files {
			lines = append(lines, f.Src+"\t"+f.Dst)
		}
		return strings.Join(lines, "\n"), nil
	case "volumes":
		// One line per volume: "name\tmount" (mount is relative to /home/<user>/).
		var lines []string
		for _, v := range m.Volumes {
			lines = append(lines, v.Name+"\t"+v.Mount)
		}
		return strings.Join(lines, "\n"), nil
	}
	return "", fmt.Errorf("unknown field %q", name)
}
