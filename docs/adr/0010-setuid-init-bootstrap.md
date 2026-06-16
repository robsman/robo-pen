# Setuid Go wrapper for non-root rp-init bootstrap

`rp-init.sh` requires root: it mounts a tmpfs over `/workspace-real`, bind-mounts the host workspace into `/var/lib/rp/backing` (mode 0700 root), and execs `rp-fuse` as PID 1 with CAP_SYS_ADMIN. Apple Container's create flow does `container create --user 0 …` so init runs as root naturally; Docker Sandbox templates have no equivalent — they start their containers with a non-root `agent` user and offer no documented hook for a privileged pre-start step. ([Docker Sandbox kits docs](https://docs.docker.com/ai/sandboxes/customize/kits/): `commands.startup` runs as agent; `commands.install` runs once at kit setup, not per container start.)

We ship a small setuid-root Go binary, `rp-init-bootstrap`, baked into the rp-base image at `/usr/local/bin/rp-init-bootstrap` with mode `4755`. The Docker overlay uses it as `ENTRYPOINT`. When Docker starts the container as the agent user, the kernel's setuid handling escalates the bootstrap process to root before `main()` runs; the wrapper then `execve`s `/usr/local/bin/rp-init.sh`, which proceeds with the normal init sequence. Sessions continue to land as the agent via `docker exec -u <agent>`.

## Why Go (and not C)

The build pipeline already has a `golang:1.22-alpine` stage for `rp-fuse`. Adding a sibling stage for the bootstrap reuses that toolchain — one more `COPY rp-init-bootstrap/* . && go build` step, no new compiler in the image. The setuid concerns that historically motivated C (LD_PRELOAD injection caught by glibc's `secure_getenv`) don't apply: Go's static binaries don't dynamically link, so no `LD_*` interpretation happens. The Go runtime starts goroutines before `main()`, but the filesystem-bit setuid escalation happens in the kernel during execve — before any user-space code runs in the new process — so the multi-threaded runtime is irrelevant here. Cost is binary size (~2 MB statically-linked Go vs ~10 KB C); inconsequential inside a container layer.

## Scope kept deliberately tight

The wrapper:
- Hardcodes its target (`/usr/local/bin/rp-init.sh`). No path argument, no environment-driven target resolution.
- Drops argv. Whatever a caller passes is ignored, so a hostile invocation can't smuggle extra options into the script.
- Clears the inherited environment via `os.Clearenv()` and sets a small safe baseline (`PATH`, `HOME`, `TERM`). Forwards exactly three rp-controlled vars (`RP_DEBUG`, `RP_CACHE`, `RP_USER`) if they were present in the inherited env.

These constraints mean the audit surface is the wrapper's ~30 lines plus the existing rp-init.sh + rp-fuse content — the same content that already runs as root under Apple Container. The bootstrap doesn't widen what root-in-container can do; it just provides a second path to reach that state. We rejected sudo and capability-file grants because each is a more general escalation primitive (sudo grants execution of any command; capabilities like `cap_sys_admin` apply to all execs of a binary, not just the bootstrap flow).

The wrapper is no-op for Apple Container: that path stays on `container create --user 0` and never invokes the bootstrap. It only matters under Docker / Docker Sandbox / any runtime that defaults the container to a non-root user. If a future maintainer is tempted to extend the wrapper to accept arguments or call a different target, the comment in `main.go` forbids it and points back here.

## RUID/EUID equalization via setresuid

The kernel's setuid-bit handling sets EUID and SUID to the file owner (0) but leaves RUID as the caller (1000 / agent under Docker Sandbox). Caps are computed correctly; most syscalls only care about EUID + caps. **But util-linux's `mount(8)` does a userland precheck on `getuid()` (RUID) and bails with "must be superuser" if it's nonzero**, never issuing the mount syscall. Found this the hard way: on Docker Desktop, every tmpfs mount in `rp-init.sh` failed even though `CapEff` contained `CAP_SYS_ADMIN` and `Uid:` was `1000 0 0 0`.

Fix: bootstrap calls `setresuid(0, 0, 0)` (and `setresgid`) before `execve`. Requires CAP_SETUID, which we have. Result: the script lands at `Uid: 0 0 0 0` and util-linux's precheck passes. No-op when called under Apple Container's `--user 0` flow, since RUID is already 0.

This is technically separable from the setuid-Bootstrap purpose, but lives in the same binary because both concerns serve the same goal — "make the script see a complete root identity" — and splitting them into two binaries would just multiply the audit surface.

## FD-as-backing mount layout

Independent of the bootstrap, the script needs to bind/move the host workspace into a private location so rp-fuse can read it while the container user cannot reach it. Docker Desktop's host file-sharing layer presents bind mounts via a `fakeowner` FS driver that refuses to be the source of any further `mount --bind`, `--rbind`, or `--move`. Even `--privileged` doesn't bypass that.

So the script now uses an open file descriptor as the backing reference instead of a mount:

```
1. bash `exec {BACKING_FD}<$REAL` captures fd on the host bind
2. mount -t tmpfs none $REAL  (allowed — mount ONTO fakeowner is fine)
3. rp-fuse --backing-fd N
   rp-fuse resolves /proc/self/fd/N — the kernel's "magic symlink" reaches
   through the fd's inode, bypassing path lookup of the now-overmounted
   /workspace-real.
```

No `/var/lib/rp/backing` mountpoint; no bind/move operations on the fakeowner mount. The same code path works on Apple Container's virtiofs (which would have allowed bind anyway). One less coupling to host-share FS quirks.
