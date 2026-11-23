// rp-fuse: rule-aware passthrough FUSE.
//
// Mounts one or more workspaces, each as an independent rule-aware FUSE
// tree. A workspace spec is `<path>=<fd>[:ro]`:
//
//	--workspace /Users/me/work/proj=10
//	--workspace /Users/me/work/notes=11:ro
//
//	* path : the FUSE mountpoint AND the host bind path inside the container
//	         (rp uses 1:1 binds — see ADR-0010).
//	* fd   : an open file descriptor pointing at the host bind, inherited
//	         from the parent (init.sh captures it before overmounting the
//	         path with tmpfs). The kernel resolves /proc/self/fd/N through
//	         the inode the fd already opens, so we can reach the host bind
//	         after it's overmounted.
//	* :ro  : optional, mounts the FUSE layer read-only; writes return EROFS
//	         from the kernel before reaching the FUSE handlers.
//
// Each workspace gets its own shadow store under `<--shadow>/<sha256(path)[:8]>/`.
// Per-path semantics inside each workspace:
//
//	* Path NOT matched by any rule: passthrough to the host bind (via fd).
//	  Edits propagate to the host.
//	* Path matched by a rule: routed to the per-workspace shadow store.
//	  Host content invisible inside the container; container writes only
//	  touch the shadow.
//
// When any workspace's FUSE server exits, all the others are unmounted and
// the process exits — matches the container-as-unit lifecycle (tini exits
// when rp-fuse exits → container dies).
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// WorkspaceSpec captures the parsed form of one `--workspace path=fd[:ro]` flag.
type WorkspaceSpec struct {
	Path      string
	BackingFd int
	ReadOnly  bool
}

type workspaceFlag []WorkspaceSpec

func (wf *workspaceFlag) String() string { return "" }

func (wf *workspaceFlag) Set(s string) error {
	spec, err := parseWorkspaceSpec(s)
	if err != nil {
		return err
	}
	*wf = append(*wf, spec)
	return nil
}

func parseWorkspaceSpec(s string) (WorkspaceSpec, error) {
	eq := strings.IndexByte(s, '=')
	if eq < 0 {
		return WorkspaceSpec{}, errors.New("missing '=' in workspace spec (want path=fd[:ro])")
	}
	spec := WorkspaceSpec{Path: s[:eq]}
	rest := s[eq+1:]
	if i := strings.IndexByte(rest, ':'); i >= 0 {
		flag := rest[i+1:]
		if flag != "ro" {
			return WorkspaceSpec{}, fmt.Errorf("unknown workspace flag %q (want :ro)", flag)
		}
		spec.ReadOnly = true
		rest = rest[:i]
	}
	fd, err := strconv.Atoi(rest)
	if err != nil {
		return WorkspaceSpec{}, fmt.Errorf("invalid fd %q: %w", rest, err)
	}
	if fd < 0 {
		return WorkspaceSpec{}, fmt.Errorf("fd must be >= 0, got %d", fd)
	}
	if !filepath.IsAbs(spec.Path) {
		return WorkspaceSpec{}, fmt.Errorf("workspace path must be absolute: %q", spec.Path)
	}
	spec.BackingFd = fd
	return spec, nil
}

// mounted tracks a single live workspace + its FUSE server.
type mounted struct {
	Spec   WorkspaceSpec
	Server *fuse.Server
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "lint":
			runLint(os.Args[2:])
			return
		case "config":
			runConfig(os.Args[2:])
			return
		case "profile":
			runProfile(os.Args[2:])
			return
		case "rpdir":
			// rp-fuse rpdir <workspace>: the .rp/ dir that applies to it.
			if len(os.Args) != 3 {
				fmt.Fprintln(os.Stderr, "usage: rp-fuse rpdir <workspace>")
				os.Exit(2)
			}
			fmt.Println(RPDir(os.Args[2]))
			return
		}
	}

	var workspaces workspaceFlag
	rulesFiles := rulesFlag{}
	flag.Var(&rulesFiles, "rules", "<path>=<file>, repeatable. Shadow rules for the workspace at path when it has no .rp/ of its own (the repo home's .rp/shadow, captured at create; ADR-0023).")
	flag.Var(&workspaces, "workspace", "<path>=<fd>[:ro], repeatable. path is the FUSE mountpoint (1:1 with the host bind path). fd is an inherited open file descriptor on the host bind.")
	shadow := flag.String("shadow", "", "base shadow store dir; per-workspace subdirs derived from sha256(path)[:8]")
	debug := flag.Bool("debug", false, "enable FUSE debug logging")
	cacheSec := flag.Float64("cache", 1.0, "attr/entry cache TTL in seconds")
	flag.Parse()

	if len(workspaces) == 0 {
		log.Fatal("at least one --workspace <path>=<fd>[:ro] required")
	}
	if *shadow == "" {
		log.Fatal("--shadow is required")
	}
	if err := os.MkdirAll(*shadow, 0o755); err != nil {
		log.Fatalf("mkdir shadow base %s: %v", *shadow, err)
	}

	ttl := time.Duration(*cacheSec * float64(time.Second))

	// Mount each workspace. If any fails, unmount the rest and exit.
	servers := make([]*mounted, 0, len(workspaces))
	cleanup := func() {
		for _, m := range servers {
			if m != nil && m.Server != nil {
				_ = m.Server.Unmount()
			}
		}
	}

	for _, spec := range workspaces {
		m, err := mountOne(spec, rulesFiles[spec.Path], *shadow, ttl, *debug)
		if err != nil {
			log.Printf("mount %s failed: %v; rolling back %d earlier mount(s)", spec.Path, err, len(servers))
			cleanup()
			os.Exit(1)
		}
		servers = append(servers, m)
	}

	log.Printf("rp-fuse: mounted %d workspace(s)", len(servers))

	// Wait for any server to exit OR a signal. Any exit triggers full
	// teardown — fail-closed semantics match single-mount behaviour.
	exited := make(chan int, len(servers))
	for i, m := range servers {
		go func(i int, m *mounted) {
			m.Server.Wait()
			exited <- i
		}(i, m)
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)

	select {
	case <-sigs:
		log.Print("signal received; unmounting all workspaces")
	case idx := <-exited:
		log.Printf("workspace %s exited; unmounting remaining", servers[idx].Spec.Path)
	}
	cleanup()
	// Drain remaining exits with a timeout so we don't hang on a stuck
	// kernel-side unmount.
	for range servers {
		select {
		case <-exited:
		case <-time.After(5 * time.Second):
			log.Print("unmount drain timed out")
		}
	}
	log.Print("rp-fuse: all servers exited")
}

// rulesFlag maps a workspace path to a fallback rules file.
type rulesFlag map[string]string

func (rf rulesFlag) String() string { return "" }

func (rf rulesFlag) Set(s string) error {
	eq := strings.IndexByte(s, '=')
	if eq <= 0 || eq == len(s)-1 {
		return errors.New("want --rules <path>=<file>")
	}
	rf[s[:eq]] = s[eq+1:]
	return nil
}

// mountOne wires up one FUSE tree for a single workspace and returns the
// server. The caller is responsible for unmounting on shutdown.
// fallbackRules, if set, is used only while the workspace has no .rp/.
func mountOne(spec WorkspaceSpec, fallbackRules, shadowBase string, ttl time.Duration, debug bool) (*mounted, error) {
	backing := fmt.Sprintf("/proc/self/fd/%d", spec.BackingFd)
	shadow := filepath.Join(shadowBase, workspaceKey(spec.Path))
	if err := os.MkdirAll(shadow, 0o755); err != nil {
		return nil, fmt.Errorf("mkdir shadow %s: %w", shadow, err)
	}

	// Rules file lives inside the workspace at .rp/shadow. We reach it via
	// the fd so any overmount on the path can't interfere with the lookup.
	rulesPath := filepath.Join(backing, ".rp", "shadow")
	if fallbackRules != "" {
		if _, err := os.Stat(filepath.Join(backing, ".rp")); os.IsNotExist(err) {
			rulesPath = fallbackRules
		}
	}
	rules, err := ParseRulesFile(rulesPath)
	if err != nil {
		return nil, fmt.Errorf("parse rules %s: %w", rulesPath, err)
	}

	var bst, sst syscall.Stat_t
	if err := syscall.Stat(backing, &bst); err != nil {
		return nil, fmt.Errorf("stat backing %s: %w", backing, err)
	}
	if err := syscall.Stat(shadow, &sst); err != nil {
		return nil, fmt.Errorf("stat shadow %s: %w", shadow, err)
	}

	cfg := &Config{Rules: rules}

	shadowRoot := &fs.LoopbackRoot{
		Path: shadow,
		Dev:  uint64(sst.Dev),
		NewNode: func(rd *fs.LoopbackRoot, parent *fs.Inode, name string, st *syscall.Stat_t) fs.InodeEmbedder {
			return &ShadowNode{LoopbackNode: fs.LoopbackNode{RootData: rd}}
		},
	}
	hostRoot := &fs.LoopbackRoot{
		Path: backing,
		Dev:  uint64(bst.Dev),
		NewNode: func(rd *fs.LoopbackRoot, parent *fs.Inode, name string, st *syscall.Stat_t) fs.InodeEmbedder {
			return &HostNode{
				LoopbackNode: fs.LoopbackNode{RootData: rd},
				cfg:          cfg,
			}
		},
	}
	cfg.HostRoot = hostRoot
	cfg.ShadowRoot = shadowRoot

	root := &HostNode{
		LoopbackNode: fs.LoopbackNode{RootData: hostRoot},
		cfg:          cfg,
	}

	mountOpts := fuse.MountOptions{
		Debug:         debug,
		AllowOther:    true,
		FsName:        "rp-fuse",
		Name:          "rp-fuse",
		MaxBackground: 32,
		MaxWrite:      1 << 20,
		DisableXAttrs: true,
	}
	if spec.ReadOnly {
		// `ro` is honoured by the kernel mount machinery; writes return
		// EROFS before reaching our FUSE handlers. Cleaner than gating each
		// write op in Go.
		mountOpts.Options = append(mountOpts.Options, "ro")
	}
	opts := &fs.Options{
		AttrTimeout:     &ttl,
		EntryTimeout:    &ttl,
		NegativeTimeout: &ttl,
		MountOptions:    mountOpts,
	}

	server, err := fs.Mount(spec.Path, root, opts)
	if err != nil {
		return nil, fmt.Errorf("mount %s: %w", spec.Path, err)
	}

	pats := rules.Patterns()
	log.Printf("mounted host=%s shadow=%s mnt=%s ro=%v patterns=%d", backing, shadow, spec.Path, spec.ReadOnly, len(pats))
	for _, p := range pats {
		log.Printf("  pattern: %s", p)
	}

	return &mounted{Spec: spec, Server: server}, nil
}

// workspaceKey is the per-workspace shadow-store subdir name. Derived from
// the absolute path so the same host workspace lands at the same shadow
// across container lifecycles (stable + opaque + collision-free in
// practice; 8 hex chars = 32 bits is plenty for our small N).
func workspaceKey(path string) string {
	h := sha256.Sum256([]byte(path))
	return hex.EncodeToString(h[:4])
}
