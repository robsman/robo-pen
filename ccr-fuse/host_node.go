package main

import (
	"context"
	"os"
	"path/filepath"
	"syscall"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
)

// Config is shared by every HostNode in the FUSE tree.
type Config struct {
	Rules       *Rules
	HostRoot    *fs.LoopbackRoot
	ShadowRoot *fs.LoopbackRoot
}

// HostNode is a rule-aware loopback node rooted at HostRoot.Path.
// When a child path matches a rule it routes to ShadowRoot.
type HostNode struct {
	fs.LoopbackNode
	cfg *Config
}

func (n *HostNode) relPath() string { return n.Path(n.Root()) }

// idFromStat replicates LoopbackRoot.idFromStat (unexported in go-fuse).
func idFromStat(rootDev uint64, st *syscall.Stat_t) fs.StableAttr {
	swapped := (uint64(st.Dev) << 32) | (uint64(st.Dev) >> 32)
	swappedRootDev := (rootDev << 32) | (rootDev >> 32)
	return fs.StableAttr{
		Mode: uint32(st.Mode),
		Gen:  1,
		Ino:  (swapped ^ swappedRootDev) ^ st.Ino,
	}
}

func joinRel(parent, name string) string {
	if parent == "" || parent == "." {
		return name
	}
	return parent + "/" + name
}

// shadowPath returns the shadow backing path for a workspace-relative path.
func (n *HostNode) shadowPath(rel string) string {
	return filepath.Join(n.cfg.ShadowRoot.Path, rel)
}

// ensureShadowParent creates the shadow parent directory (recursively) for a
// to-be-created rule-matched child. No-op if it already exists.
func (n *HostNode) ensureShadowParent(childRel string) error {
	parent := filepath.Dir(childRel)
	if parent == "." || parent == "" {
		return nil
	}
	return os.MkdirAll(n.shadowPath(parent), 0o755)
}

func (n *HostNode) shadowChild(ctx context.Context, rel string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	p := n.shadowPath(rel)
	var st syscall.Stat_t
	if err := syscall.Lstat(p, &st); err != nil {
		return nil, fs.ToErrno(err)
	}
	if out != nil {
		out.Attr.FromStat(&st)
	}
	node := &fs.LoopbackNode{RootData: n.cfg.ShadowRoot}
	ch := n.NewInode(ctx, node, idFromStat(n.cfg.ShadowRoot.Dev, &st))
	return ch, 0
}

// --- Read ops ---

func (n *HostNode) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	childRel := joinRel(n.relPath(), name)
	if n.cfg.Rules.Match(childRel) {
		return n.shadowChild(ctx, childRel, out)
	}
	return n.LoopbackNode.Lookup(ctx, name, out)
}

func (n *HostNode) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	parentRel := n.relPath()

	stream, errno := n.LoopbackNode.Readdir(ctx)
	if errno != 0 {
		return nil, errno
	}
	var entries []fuse.DirEntry
	seen := map[string]bool{}
	for stream.HasNext() {
		e, _ := stream.Next()
		if n.cfg.Rules.Match(joinRel(parentRel, e.Name)) {
			continue
		}
		entries = append(entries, e)
		seen[e.Name] = true
	}
	stream.Close()

	// Merge in shadow-side entries that exist at this directory level.
	shadowDir := n.shadowPath(parentRel)
	if dh, err := os.Open(shadowDir); err == nil {
		names, _ := dh.Readdirnames(-1)
		dh.Close()
		for _, name := range names {
			if seen[name] {
				continue
			}
			childRel := joinRel(parentRel, name)
			if !n.cfg.Rules.Match(childRel) {
				continue
			}
			var st syscall.Stat_t
			if err := syscall.Lstat(filepath.Join(shadowDir, name), &st); err == nil {
				entries = append(entries, fuse.DirEntry{
					Name: name,
					Mode: uint32(st.Mode) & syscall.S_IFMT,
					Ino:  st.Ino,
				})
			}
		}
	}
	return fs.NewListDirStream(entries), 0
}

// --- Write ops on rule-matching children: route to shadow ---

func (n *HostNode) Mkdir(ctx context.Context, name string, mode uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	childRel := joinRel(n.relPath(), name)
	if n.cfg.Rules.Match(childRel) {
		if err := n.ensureShadowParent(childRel); err != nil {
			return nil, fs.ToErrno(err)
		}
		p := n.shadowPath(childRel)
		if err := os.Mkdir(p, os.FileMode(mode)); err != nil {
			return nil, fs.ToErrno(err)
		}
		return n.shadowChild(ctx, childRel, out)
	}
	return n.LoopbackNode.Mkdir(ctx, name, mode, out)
}

func (n *HostNode) Create(ctx context.Context, name string, flags uint32, mode uint32, out *fuse.EntryOut) (*fs.Inode, fs.FileHandle, uint32, syscall.Errno) {
	childRel := joinRel(n.relPath(), name)
	if n.cfg.Rules.Match(childRel) {
		if err := n.ensureShadowParent(childRel); err != nil {
			return nil, nil, 0, fs.ToErrno(err)
		}
		p := n.shadowPath(childRel)
		flags &^= syscall.O_APPEND
		fd, err := syscall.Open(p, int(flags)|os.O_CREATE, mode)
		if err != nil {
			return nil, nil, 0, fs.ToErrno(err)
		}
		var st syscall.Stat_t
		if err := syscall.Fstat(fd, &st); err != nil {
			syscall.Close(fd)
			return nil, nil, 0, fs.ToErrno(err)
		}
		out.FromStat(&st)
		node := &fs.LoopbackNode{RootData: n.cfg.ShadowRoot}
		ch := n.NewInode(ctx, node, idFromStat(n.cfg.ShadowRoot.Dev, &st))
		return ch, fs.NewLoopbackFile(fd), 0, 0
	}
	return n.LoopbackNode.Create(ctx, name, flags, mode, out)
}

func (n *HostNode) Symlink(ctx context.Context, target, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	childRel := joinRel(n.relPath(), name)
	if n.cfg.Rules.Match(childRel) {
		if err := n.ensureShadowParent(childRel); err != nil {
			return nil, fs.ToErrno(err)
		}
		p := n.shadowPath(childRel)
		if err := syscall.Symlink(target, p); err != nil {
			return nil, fs.ToErrno(err)
		}
		return n.shadowChild(ctx, childRel, out)
	}
	return n.LoopbackNode.Symlink(ctx, target, name, out)
}

func (n *HostNode) Mknod(ctx context.Context, name string, mode, rdev uint32, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	childRel := joinRel(n.relPath(), name)
	if n.cfg.Rules.Match(childRel) {
		if err := n.ensureShadowParent(childRel); err != nil {
			return nil, fs.ToErrno(err)
		}
		p := n.shadowPath(childRel)
		if err := syscall.Mknod(p, mode, int(rdev)); err != nil {
			return nil, fs.ToErrno(err)
		}
		return n.shadowChild(ctx, childRel, out)
	}
	return n.LoopbackNode.Mknod(ctx, name, mode, rdev, out)
}

func (n *HostNode) Unlink(ctx context.Context, name string) syscall.Errno {
	childRel := joinRel(n.relPath(), name)
	if n.cfg.Rules.Match(childRel) {
		return fs.ToErrno(syscall.Unlink(n.shadowPath(childRel)))
	}
	return n.LoopbackNode.Unlink(ctx, name)
}

func (n *HostNode) Rmdir(ctx context.Context, name string) syscall.Errno {
	childRel := joinRel(n.relPath(), name)
	if n.cfg.Rules.Match(childRel) {
		return fs.ToErrno(syscall.Rmdir(n.shadowPath(childRel)))
	}
	return n.LoopbackNode.Rmdir(ctx, name)
}

// Rename: same-region only. Cross-region returns EXDEV.
func (n *HostNode) Rename(ctx context.Context, name string, newParent fs.InodeEmbedder, newName string, flags uint32) syscall.Errno {
	srcRel := joinRel(n.relPath(), name)

	dstParent, ok := newParent.(*HostNode)
	if !ok {
		return syscall.EXDEV
	}
	dstRel := joinRel(dstParent.relPath(), newName)

	srcRule := n.cfg.Rules.Match(srcRel)
	dstRule := n.cfg.Rules.Match(dstRel)
	if srcRule != dstRule {
		return syscall.EXDEV
	}
	if srcRule {
		if err := n.ensureShadowParent(dstRel); err != nil {
			return fs.ToErrno(err)
		}
		return fs.ToErrno(syscall.Rename(n.shadowPath(srcRel), n.shadowPath(dstRel)))
	}
	return n.LoopbackNode.Rename(ctx, name, newParent, newName, flags)
}
