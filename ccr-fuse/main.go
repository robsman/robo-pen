// ccr-fuse: rule-aware passthrough FUSE.
//
// Layout:
//   --backing <host>  : real host workspace bind mount (lower)
//   --shadow  <store> : container-local writable shadow store
//                       Mirrors FUSE paths: a matched rel path "a/b" lives at <store>/a/b.
//   --mount   <mnt>   : FUSE mount point exposed to the user/Claude
//   --rules   <file>  : path to .ccrshadow (gitignore-style patterns, one per line)
//
// Per-path semantics:
//   * Path NOT matched by any rule: passthrough to <host>/<path>. Edits propagate to host.
//   * Path matched by a rule       : routed to <store>/<path>.
//                                    Host's content is invisible to the container.
//                                    Container's create/write/delete touches the shadow only.
package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

func main() {
	backing := flag.String("backing", "", "backing host directory (absolute)")
	shadow := flag.String("shadow", "", "shadow store directory (absolute)")
	mountpoint := flag.String("mount", "", "mount point (absolute)")
	rulesPath := flag.String("rules", "", "path to .ccrshadow (optional)")
	debug := flag.Bool("debug", false, "enable FUSE debug logging")
	cacheSec := flag.Float64("cache", 1.0, "attr/entry cache TTL in seconds")
	flag.Parse()

	if *backing == "" || *shadow == "" || *mountpoint == "" {
		log.Fatal("--backing, --shadow, --mount are required")
	}

	rules, err := ParseRulesFile(*rulesPath)
	if err != nil {
		log.Fatalf("parse rules %s: %v", *rulesPath, err)
	}
	if err := os.MkdirAll(*shadow, 0o755); err != nil {
		log.Fatalf("mkdir shadow root: %v", err)
	}

	cfg := &Config{Rules: rules}

	var bst, sst syscall.Stat_t
	if statErr := syscall.Stat(*backing, &bst); statErr != nil {
		log.Fatalf("stat backing: %v", statErr)
	}
	if statErr := syscall.Stat(*shadow, &sst); statErr != nil {
		log.Fatalf("stat shadow: %v", statErr)
	}

	shadowRoot := &fs.LoopbackRoot{
		Path: *shadow,
		Dev:  uint64(sst.Dev),
		NewNode: func(rd *fs.LoopbackRoot, parent *fs.Inode, name string, st *syscall.Stat_t) fs.InodeEmbedder {
			return &fs.LoopbackNode{RootData: rd}
		},
	}
	hostRoot := &fs.LoopbackRoot{
		Path: *backing,
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

	ttl := time.Duration(*cacheSec * float64(time.Second))
	opts := &fs.Options{
		AttrTimeout:     &ttl,
		EntryTimeout:    &ttl,
		NegativeTimeout: &ttl,
		MountOptions: fuse.MountOptions{
			Debug:         *debug,
			AllowOther:    true,
			FsName:        "ccr-fuse",
			Name:          "ccr-fuse",
			MaxBackground: 32,
			MaxWrite:      1 << 20,
			DisableXAttrs: true,
		},
	}

	server, mountErr := fs.Mount(*mountpoint, root, opts)
	if mountErr != nil {
		log.Fatalf("mount %s: %v", *mountpoint, mountErr)
	}
	pats := rules.Patterns()
	log.Printf("mounted host=%s shadow=%s mnt=%s patterns=%d", *backing, *shadow, *mountpoint, len(pats))
	for _, p := range pats {
		log.Printf("  pattern: %s", p)
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Print("signal received; unmounting")
		if err := server.Unmount(); err != nil {
			log.Printf("unmount: %v", err)
		}
	}()
	server.Wait()
	log.Print("server exited")
}
