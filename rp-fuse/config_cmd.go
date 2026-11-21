package main

// The `config` subcommand lets shell scripts (Justfile recipes, rp wrapper)
// inspect .rp/config.yaml without re-implementing the YAML parser.

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// runConfig is the entrypoint for `rp-fuse config`.
func runConfig(args []string) {
	fs := flag.NewFlagSet("config", flag.ExitOnError)
	configPath := fs.String("file", ".rp/config.yaml", "path to .rp/config.yaml")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: rp-fuse config [--file <path>] <subcommand>")
		fmt.Fprintln(os.Stderr, "Subcommands:")
		fmt.Fprintln(os.Stderr, "  show      print resolved fields, one per line")
		fmt.Fprintln(os.Stderr, "  validate  parse + validate; exit 0 on success, 1 on error")
		fmt.Fprintln(os.Stderr, "  field <name>")
		fmt.Fprintln(os.Stderr, "            print one field (image | dockerfile | context | user |")
		fmt.Fprintln(os.Stderr, "                              agent | source | resources.memory |")
		fmt.Fprintln(os.Stderr, "                              resources.cpus | fuse.cache)")
	}
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		fs.Usage()
		os.Exit(2)
	}

	cfg, err := ParseProjectConfig(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "rp-fuse config: %v\n", err)
		os.Exit(1)
	}

	sub := fs.Arg(0)
	switch sub {
	case "validate":
		// Already parsed without error; exit 0.
		return
	case "show":
		showProjectConfig(cfg, *configPath)
		return
	case "field":
		if fs.NArg() < 2 {
			fmt.Fprintln(os.Stderr, "rp-fuse config field: name required")
			os.Exit(2)
		}
		out, err := projectConfigField(cfg, fs.Arg(1))
		if err != nil {
			fmt.Fprintf(os.Stderr, "rp-fuse config field: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(out)
	default:
		fmt.Fprintf(os.Stderr, "rp-fuse config: unknown subcommand %q\n", sub)
		os.Exit(2)
	}
}

func showProjectConfig(c *ProjectConfig, path string) {
	fmt.Printf("file: %s\n", path)
	for _, l := range ConfigLayers(path)[1:] {
		fmt.Printf("local layer: %s\n", l)
	}
	agent := c.AgentName()
	if c.Agent == "" {
		agent += " (default)"
	}
	fmt.Printf("agent: %s\n", agent)
	fmt.Printf("image: %s\n", emptyDash(c.Image))
	fmt.Printf("user: %s\n", emptyDash(c.User))
	if c.Build != nil {
		fmt.Println("build:")
		fmt.Printf("  context: %s\n", emptyDash(c.Build.Context))
		fmt.Printf("  dockerfile: %s\n", c.Build.Dockerfile)
		if len(c.Build.Args) > 0 {
			fmt.Println("  args:")
			for k, v := range c.Build.Args {
				fmt.Printf("    %s: %s\n", k, v)
			}
		}
	} else {
		fmt.Println("build: -")
	}
	if c.Resources != nil {
		fmt.Println("resources:")
		fmt.Printf("  memory: %s\n", emptyDash(c.Resources.Memory))
		cpus := "-"
		if c.Resources.CPUs > 0 {
			cpus = fmt.Sprintf("%d", c.Resources.CPUs)
		}
		fmt.Printf("  cpus: %s\n", cpus)
	} else {
		fmt.Println("resources: -")
	}
	if c.Fuse != nil && c.Fuse.Cache != nil {
		fmt.Printf("fuse.cache: %s\n", strings.TrimRight(strings.TrimRight(fmt.Sprintf("%f", *c.Fuse.Cache), "0"), "."))
	} else {
		fmt.Println("fuse.cache: -")
	}
}

func projectConfigField(c *ProjectConfig, name string) (string, error) {
	switch name {
	case "image":
		return c.Image, nil
	case "agent":
		return c.AgentName(), nil
	case "user":
		return c.User, nil
	case "strip_sudo":
		if c.StripSudo != nil && *c.StripSudo {
			return "true", nil
		}
		return "", nil
	case "allow_sudo":
		if c.AllowSudo != nil && *c.AllowSudo {
			return "true", nil
		}
		return "", nil
	case "dockerfile":
		if c.Build == nil {
			return "", nil
		}
		return c.Build.Dockerfile, nil
	case "context":
		if c.Build == nil {
			return "", nil
		}
		if c.Build.Context == "" {
			return ".", nil
		}
		return c.Build.Context, nil
	case "source":
		if c.Image != "" {
			return "image", nil
		}
		if c.Build != nil {
			return "build", nil
		}
		return "default", nil
	case "resources.memory":
		if c.Resources == nil {
			return "", nil
		}
		return c.Resources.Memory, nil
	case "resources.cpus":
		if c.Resources == nil || c.Resources.CPUs == 0 {
			return "", nil
		}
		return fmt.Sprintf("%d", c.Resources.CPUs), nil
	case "fuse.cache":
		if c.Fuse == nil || c.Fuse.Cache == nil {
			return "", nil
		}
		return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%f", *c.Fuse.Cache), "0"), "."), nil
	case "host_files":
		// Same TSV shape as the profile manifest accessor so
		// seed-host-files.sh treats both sources uniformly.
		var lines []string
		for _, h := range c.HostFiles {
			ifm := h.IfMissing
			if ifm == "" {
				ifm = "skip"
			}
			lines = append(lines, h.Src+"\t"+h.Dst+"\t"+ifm)
		}
		return strings.Join(lines, "\n"), nil
	case "host_keychain":
		var lines []string
		for _, k := range c.HostKeychain {
			mode := k.Mode
			if mode == "" {
				mode = "0600"
			}
			ifm := k.IfMissing
			if ifm == "" {
				ifm = "skip"
			}
			lines = append(lines, k.Service+"\t"+k.Dst+"\t"+mode+"\t"+ifm)
		}
		return strings.Join(lines, "\n"), nil
	case "plugins.marketplaces":
		if c.Plugins == nil {
			return "", nil
		}
		return strings.Join(c.Plugins.Marketplaces, "\n"), nil
	case "plugins.install":
		if c.Plugins == nil {
			return "", nil
		}
		return strings.Join(c.Plugins.Install, "\n"), nil
	case "host_path_aliases":
		// One ~/-prefixed entry per line. Caller expands ~ → host's
		// $HOME and computes the container target via /home/<user>/<rel>.
		return strings.Join(c.HostPathAliases, "\n"), nil
	case "host_aliases":
		// One alias per line: "name=ip". Always includes the implicit
		// `host.containers.internal=host-gateway` entry. Shell consumers
		// can `while read line; do …; done` over this.
		var out []string
		for _, a := range c.HostAliasesEffective() {
			out = append(out, fmt.Sprintf("%s=%s", a.Name, a.IP))
		}
		return strings.Join(out, "\n"), nil
	}
	return "", fmt.Errorf("unknown field %q", name)
}

func emptyDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
