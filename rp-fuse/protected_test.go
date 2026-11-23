package main

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestIsProtected(t *testing.T) {
	cases := map[string]bool{
		".rp":                        true,
		".rp/shadow":                 true,
		".rp/config.yaml":            true,
		".rp/agents/claude-code":     true,
		".rp/agents/x/manifest.yaml": true,
		".rpx":                       false,
		".rp2/shadow":                false,
		"src/.rp":                    false,
		"src/.rp/shadow":             false,
		"":                           false,
		"node_modules":               false,
	}
	for rel, want := range cases {
		if got := isProtected(rel); got != want {
			t.Errorf("isProtected(%q) = %v, want %v", rel, got, want)
		}
	}
}

// TestProtectedTreeOverFUSE mounts the real FUSE tree and checks that no
// container-side op can modify, move or remove anything under .rp/. Needs
// /dev/fuse + CAP_SYS_ADMIN; skips otherwise (e.g. plain `go test` on macOS).
// `just test-go` provides both.
func TestProtectedTreeOverFUSE(t *testing.T) {
	backing := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(backing, ".rp", "agents", "x"), 0o755))
	must(t, os.WriteFile(filepath.Join(backing, ".rp", "shadow"), []byte("node_modules/\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(backing, ".rp", "config.yaml"), []byte("agent: claude-code\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(backing, ".rp", "agents", "x", "manifest.yaml"), []byte("name: x\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(backing, "scratch"), []byte("s\n"), 0o644))

	fd, err := syscall.Open(backing, syscall.O_RDONLY|syscall.O_DIRECTORY, 0)
	must(t, err)
	defer syscall.Close(fd)

	mnt := t.TempDir()
	m, err := mountOne(WorkspaceSpec{Path: mnt, BackingFd: fd}, "", t.TempDir(), 0, false)
	if err != nil {
		t.Skipf("FUSE mount unavailable: %v", err)
	}
	defer m.Server.Unmount()

	p := func(rel string) string { return filepath.Join(mnt, rel) }
	ops := []struct {
		name string
		op   func() error
	}{
		{"rename .rp away", func() error { return os.Rename(p(".rp"), p(".rp2")) }},
		{"rename dir onto .rp", func() error { must(t, os.Mkdir(p("other"), 0o755)); return syscall.Rename(p("other"), p(".rp")) }},
		{"rename .rp/agents away", func() error { return os.Rename(p(".rp/agents"), p("agents")) }},
		{"rename file into .rp", func() error { return os.Rename(p("scratch"), p(".rp/config.yaml")) }},
		{"unlink nested manifest", func() error { return os.Remove(p(".rp/agents/x/manifest.yaml")) }},
		{"rmdir .rp/agents/x", func() error { return syscall.Rmdir(p(".rp/agents/x")) }},
		{"write .rp/config.yaml", func() error { return os.WriteFile(p(".rp/config.yaml"), []byte("allow_sudo: true\n"), 0o644) }},
		{"truncate .rp/config.yaml", func() error { return os.Truncate(p(".rp/config.yaml"), 0) }},
		{"O_RDONLY|O_TRUNC config", func() error {
			f, err := os.OpenFile(p(".rp/config.yaml"), os.O_RDONLY|os.O_TRUNC, 0)
			if err == nil {
				f.Close()
			}
			return err
		}},
		{"chmod .rp", func() error { return os.Chmod(p(".rp"), 0o777) }},
		{"create .rp/Dockerfile", func() error { return os.WriteFile(p(".rp/Dockerfile"), []byte("FROM x\n"), 0o644) }},
		{"mkdir .rp/agents/evil", func() error { return os.Mkdir(p(".rp/agents/evil"), 0o755) }},
		{"symlink in .rp", func() error { return os.Symlink("/etc/passwd", p(".rp/link")) }},
		{"unlink .rp/shadow", func() error { return os.Remove(p(".rp/shadow")) }},
		{"hardlink .rp/config.yaml out", func() error { return os.Link(p(".rp/config.yaml"), p("cfg-link")) }},
		{"hardlink scratch into .rp", func() error { return os.Link(p("scratch"), p(".rp/scratch")) }},
	}
	for _, o := range ops {
		if err := o.op(); !errors.Is(err, syscall.EROFS) {
			t.Errorf("%s: got %v, want EROFS", o.name, err)
		}
	}

	// Reads stay allowed.
	if b, err := os.ReadFile(p(".rp/config.yaml")); err != nil || string(b) != "agent: claude-code\n" {
		t.Errorf("read .rp/config.yaml through FUSE: %q, %v", b, err)
	}

	// Host side untouched.
	time.Sleep(10 * time.Millisecond)
	for _, rel := range []string{".rp/shadow", ".rp/config.yaml", ".rp/agents/x/manifest.yaml"} {
		if _, err := os.Stat(filepath.Join(backing, rel)); err != nil {
			t.Errorf("host %s: %v", rel, err)
		}
	}
	for _, rel := range []string{".rp2", "agents", "cfg-link", ".rp/Dockerfile", ".rp/link", ".rp/scratch", ".rp/agents/evil"} {
		if _, err := os.Lstat(filepath.Join(backing, rel)); err == nil {
			t.Errorf("host %s exists; protected-tree op leaked", rel)
		}
	}
	if b, _ := os.ReadFile(filepath.Join(backing, ".rp", "config.yaml")); string(b) != "agent: claude-code\n" {
		t.Errorf("host .rp/config.yaml modified: %q", b)
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// TestLinkRegions: a hard link must stay inside one region, like Rename.
// Host<->shadow links return EXDEV; shadow->shadow links land in the shadow
// store. go-fuse's LoopbackNode.Link resolves the target path against the
// PARENT's root, so without this a shadow target linked into the host region
// would link the hidden host file at the same path and expose it.
func TestLinkRegions(t *testing.T) {
	backing := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(backing, ".rp"), 0o755))
	must(t, os.WriteFile(filepath.Join(backing, ".rp", "shadow"), []byte("node_modules/\n"), 0o644))
	must(t, os.MkdirAll(filepath.Join(backing, "src"), 0o755))
	must(t, os.WriteFile(filepath.Join(backing, "src", "a"), []byte("host-a\n"), 0o644))
	must(t, os.MkdirAll(filepath.Join(backing, "node_modules"), 0o755))
	must(t, os.WriteFile(filepath.Join(backing, "node_modules", "secret"), []byte("host-secret\n"), 0o644))

	fd, err := syscall.Open(backing, syscall.O_RDONLY|syscall.O_DIRECTORY, 0)
	must(t, err)
	defer syscall.Close(fd)

	mnt := t.TempDir()
	m, err := mountOne(WorkspaceSpec{Path: mnt, BackingFd: fd}, "", t.TempDir(), 0, false)
	if err != nil {
		t.Skipf("FUSE mount unavailable: %v", err)
	}
	defer m.Server.Unmount()
	p := func(rel string) string { return filepath.Join(mnt, rel) }

	must(t, os.MkdirAll(p("node_modules/sub"), 0o755))
	must(t, os.WriteFile(p("node_modules/secret"), []byte("shadow-secret\n"), 0o644))

	cross := []struct{ name, src, dst string }{
		{"host -> shadow region", "src/a", "node_modules/a"},
		{"host -> nested shadow dir", "src/a", "node_modules/sub/a"},
		{"shadow -> host region", "node_modules/secret", "leak"},
	}
	for _, c := range cross {
		if err := os.Link(p(c.src), p(c.dst)); !errors.Is(err, syscall.EXDEV) {
			t.Errorf("%s: got %v, want EXDEV", c.name, err)
		}
	}
	for _, rel := range []string{"leak", "node_modules/a", "node_modules/sub"} {
		if _, err := os.Lstat(filepath.Join(backing, rel)); err == nil {
			t.Errorf("host %s exists; link leaked across regions", rel)
		}
	}

	// Same-region links keep working.
	must(t, os.Link(p("src/a"), p("src/a2")))
	if b, _ := os.ReadFile(filepath.Join(backing, "src", "a2")); string(b) != "host-a\n" {
		t.Errorf("host->host link: host src/a2 = %q", b)
	}
	for _, dst := range []string{"node_modules/s2", "node_modules/sub/s3"} {
		if err := os.Link(p("node_modules/secret"), p(dst)); err != nil {
			t.Errorf("shadow->shadow link %s: %v", dst, err)
			continue
		}
		if b, _ := os.ReadFile(p(dst)); string(b) != "shadow-secret\n" {
			t.Errorf("shadow->shadow link %s reads %q, want shadow content", dst, b)
		}
		if _, err := os.Lstat(filepath.Join(backing, dst)); err == nil {
			t.Errorf("shadow->shadow link %s landed on host", dst)
		}
	}
}
