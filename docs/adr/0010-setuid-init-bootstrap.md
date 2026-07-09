# Non-root container init + FUSE-over-bind mount stack

Two coupled decisions taken together because they unblock the same goal — running `rp` under runtimes that (a) start the container as a non-root default user and (b) refuse bind/move with the host share as source. Apple Container honours neither constraint; Docker Sandbox / Docker Desktop on macOS imposes both. The first decision (setuid Go bootstrap + RUID equalization) gives the init script a complete root identity. The second decision (FUSE-over-tmpfs-over-bind directly at the workspace path) gives the shadow filesystem a single mount layout that works on both runtimes without bind/move tricks. They share an ADR because (a) they shipped together, (b) each one alone is insufficient — Docker Sandbox needs both — and (c) splitting them would leave a reader of one wondering why the other exists.

## Setuid Go wrapper for the init bootstrap

`rp-init.sh` requires root: it captures an fd on the workspace (the host bind), stacks tmpfs + rp-fuse on top of the workspace path, and execs `rp-fuse` as PID 1 with CAP_SYS_ADMIN. Container runtimes differ in how they hand PID 1 to the image: Apple Container historically used `container create --user 0 …`; Docker Sandbox templates have no equivalent — they start their containers with a non-root `agent` user and offer no documented hook for a privileged pre-start step. ([Docker Sandbox kits docs](https://docs.docker.com/ai/sandboxes/customize/kits/): `commands.startup` runs as agent; `commands.install` runs once at kit setup, not per container start.) Rather than fork the create flow per runtime, we install a setuid bootstrap and let the kernel handle the escalation uniformly.

We ship a small setuid-root Go binary, `rp-init-bootstrap`, baked into the rp-system image at `/usr/local/bin/rp-init-bootstrap` with mode `4755`. **It is the child of the unified `ENTRYPOINT` for every rp image**, regardless of runtime. The full ENTRYPOINT is `["tini", "--", "/usr/local/bin/rp-init-bootstrap"]` — tini sits at PID 1 as the conventional zombie-reaper / signal-forwarder, and reaps zombies for the (small) process tree we run. Docker Sandbox specifically depends on tini-as-PID-1; without it, Sandbox's lifecycle hooks fail and the container is reported as "not running" before the agent can attach. tini is baked into `rp-system` (Debian's `tini` package) and explicitly COPYed into overlays so user-supplied bases don't need to ship it. The kernel handles the escalation: if the runtime starts the container as a non-root user (e.g. Docker Sandbox's `agent`, or the image's own `USER` directive on Apple Container), the setuid bit kicks in and EUID becomes 0 before `main()` runs; if the runtime starts the container as root, the setuid bit is a no-op and the bootstrap is just a thin shell over `rp-init.sh`. The wrapper then `execve`s `/usr/local/bin/rp-init.sh` either way. Sessions continue to land as the agent via `<runtime> exec -u <agent>`.

## Why Go (and not C)

The build pipeline already has a `golang:1.22-alpine` stage for `rp-fuse`. Adding a sibling stage for the bootstrap reuses that toolchain — one more `COPY rp-init-bootstrap/* . && go build` step, no new compiler in the image. The setuid concerns that historically motivated C (LD_PRELOAD injection caught by glibc's `secure_getenv`) don't apply: Go's static binaries don't dynamically link, so no `LD_*` interpretation happens. The Go runtime starts goroutines before `main()`, but the filesystem-bit setuid escalation happens in the kernel during execve — before any user-space code runs in the new process — so the multi-threaded runtime is irrelevant here. Cost is binary size (~2 MB statically-linked Go vs ~10 KB C); inconsequential inside a container layer.

## Scope kept deliberately tight

The wrapper:
- Hardcodes its target (`/usr/local/bin/rp-init.sh`). No path argument, no environment-driven target resolution.
- Drops argv. Whatever a caller passes is ignored, so a hostile invocation can't smuggle extra options into the script.
- Clears the inherited environment via `os.Clearenv()` and sets a small safe baseline (`PATH`, `HOME`, `TERM`). Forwards exactly three rp-controlled vars (`RP_DEBUG`, `RP_CACHE`, `RP_USER`) if they were present in the inherited env.

These constraints mean the audit surface is the wrapper's ~30 lines plus the existing rp-init.sh + rp-fuse content — the same content that already runs as root under Apple Container. The bootstrap doesn't widen what root-in-container can do; it just provides a second path to reach that state. We rejected sudo and capability-file grants because each is a more general escalation primitive (sudo grants execution of any command; capabilities like `cap_sys_admin` apply to all execs of a binary, not just the bootstrap flow).

The wrapper is the unified entry. The Justfile no longer passes `--user 0` to `container create`; we rely on the setuid bit to escalate from whatever default the runtime hands us. Verified 2026-06-17 on a devcontainer image (`mcr.microsoft.com/devcontainers/javascript-node:22`, image USER `node`): `cat /proc/1/status | grep ^Uid` reports `Uid: 0 0 0 0` — setresuid in the bootstrap equalizes the identity after the setuid bit lands. One ENTRYPOINT, one mount-setup flow, one audit surface. If a future maintainer is tempted to extend the wrapper to accept arguments or call a different target, the comment in `main.go` forbids it and points back here.

## RUID/EUID equalization via setresuid

The kernel's setuid-bit handling sets EUID and SUID to the file owner (0) but leaves RUID as the caller (1000 / agent under Docker Sandbox). Caps are computed correctly; most syscalls only care about EUID + caps. **But util-linux's `mount(8)` does a userland precheck on `getuid()` (RUID) and bails with "must be superuser" if it's nonzero**, never issuing the mount syscall. Found this the hard way: on Docker Desktop, every tmpfs mount in `rp-init.sh` failed even though `CapEff` contained `CAP_SYS_ADMIN` and `Uid:` was `1000 0 0 0`.

Fix: bootstrap calls `setresuid(0, 0, 0)` (and `setresgid`) before `execve`. Requires CAP_SETUID, which we have. Result: the script lands at `Uid: 0 0 0 0` and util-linux's precheck passes. No-op when called under a runtime that already starts the container as root.

This is technically separable from the setuid-Bootstrap purpose, but lives in the same binary because both concerns serve the same goal — "make the script see a complete root identity" — and splitting them into two binaries would just multiply the audit surface.

## FD-as-backing mount layout (FUSE over tmpfs over bind, at the workspace path)

Independent of the bootstrap, the script needs to keep the host workspace reachable by rp-fuse while making it unreachable to the container user. Docker Desktop's host file-sharing layer presents bind mounts via a `fakeowner` FS driver that refuses to be the source of any further `mount --bind`, `--rbind`, or `--move`. Even `--privileged` doesn't bypass that.

The current layout uses an open file descriptor as the backing reference instead of a mount, and stacks tmpfs + FUSE directly on top of the host bind. The workspace is bind-mounted **1:1** (host path = container path) — see the discovery section below.

```
runtime bind:  $WS                        ← Docker / Apple Container bind from host workspace (1:1)
init step 1:   exec {BACKING_FD}<$WS     ← capture fd on the bind BEFORE overmount
init step 2:   mount -t tmpfs … $WS      ← fail-closed backstop
init step 3:   mount -t fuse  … $WS      ← rp-fuse, --backing-fd N
                                            kernel resolves /proc/self/fd/N
                                            through the fd's inode, not via
                                            path lookup — bypasses the tmpfs +
                                            FUSE that now sit on top.
```

User-visible at `$WS`: the FUSE layer. The raw host bind is reachable only through the fd held by rp-fuse — no separate path. If rp-fuse exits or never mounts, the tmpfs underneath becomes visible (empty), not the raw bind. This is fail-closed by construction; no post-mount verification needed.

No separate `/workspace-real` mountpoint, no `/var/lib/rp/backing` bind, no bind/move on the fakeowner mount. The same code path works on Apple Container's virtiofs (which would have allowed bind anyway). One mount stack, two runtimes, no coupling to host-share FS quirks.

## Docker Sandbox status (2026-06-18): blocked by cgroup BPF

We investigated running rp images under Docker Sandbox (`sbx run --template …`). The setuid bootstrap path works (`Uid: 0 0 0 0` confirmed; `CapBnd` shows full caps under the `docker/sandbox-templates:shell-docker` base). `/dev/fuse` is absent but recreatable via `mknod c 10 229` since `CAP_MKNOD` is present. **The hard block is the cgroup v2 device BPF program Sandbox attaches**: `open("/dev/fuse")` returns EPERM even for real root with full caps. `/dev/null` and `/dev/zero` open fine — the BPF whitelist excludes FUSE major:minor by policy.

Findings:

| Probe | Result |
|---|---|
| Seccomp | disabled |
| AppArmor / LSM | none visible |
| User-ns remap | none (`uid_map: 0 0 4294967295`) |
| `CapBnd` | `000001ffffffffff` (full) |
| Setuid bit on bootstrap (after tar round-trip) | preserved |
| `/dev/fuse` kernel driver | present (`/proc/filesystems` lists `fuse`, `fuseblk`, `fusectl`) |
| `mknod /dev/fuse` | succeeds |
| `open("/dev/fuse")` | EPERM (cgroup BPF deny) |

Sandbox kit YAML doesn't expose a `devices:` or `cap_add:` key for whitelisting the FUSE device. Until upstream Sandbox adds device-customization, rp's FUSE shadow is not viable inside Sandbox. We rejected the tmpfs-overlay-per-pattern alternative as a significant capability regression (loses file-level rules, caller-ownership, inode-disjoint, dynamic rule reload).

The remaining bits we landed during this investigation stay because they're useful beyond Sandbox: `/dev/fuse` autocreate (any runtime that omits the device node), `RP_ALLOW_SUDO` (any image whose user has sudo), `fakeowner` in the workspace-discovery scan (Docker Desktop), `--poc` / `--diagnose` flags on `build-docker-experimental.sh`.

## Workspace discovery (1:1 binds)

The `rp` wrapper bind-mounts the host workspace **1:1** — the path inside the container is the same as the path on the host. This aligns with Docker Sandbox's convention ("workspace mounted at the same absolute path as on your host") and removes the `/workspace` magic path that earlier rp versions used. The init script discovers the workspace at startup:

1. `$RP_WORKSPACE` if set and is a directory — the canonical signal. The `rp` Justfile sets it explicitly via `-e RP_WORKSPACE={{host_dir}}`; Sandbox templates set it in kit env config.
2. Scan `/proc/mounts` for `virtiofs` / `9p` / `fakeowner` / `fuse.fakeowner` entries whose target is a directory containing `.rp/` — first match wins. Fallback for runtimes that don't pass the env var (e.g. `docker run -v /path:/path` without `-e RP_WORKSPACE`).

The scan tolerates unrelated entries: `/etc/resolv.conf` is a regular file and gets skipped by the directory check. Multiple `.rp/`-marked mounts in one container — multi-workspace FUSE (one rp-fuse process mounting N trees) is deferred until a real use case surfaces; today the scan picks the first match.

The mount-stack logic above is applied to EACH discovered workspace: per-workspace fd capture, tmpfs cover, and rp-fuse mount. rp-fuse takes one `--workspace <path>=<fd>[:ro]` argument per workspace and mounts an independent FUSE tree for each. Per-workspace shadow stores live under `/var/lib/rp/shadow/<sha256(path)[:8]>/`. When any FUSE tree exits, the others are unmounted and the process exits (container-as-unit fail-closed semantics carry over).

### Read-only workspaces (`:ro`)

An entry in `RP_WORKSPACE` (or a `--workspace` arg) may carry a `:ro` suffix:

```
RP_WORKSPACE="/Users/me/work/proj /Users/me/docs:ro"
```

The `:ro` flag is passed to rp-fuse, which sets the FUSE mount option `ro`. The kernel mount machinery then returns EROFS on every write — no need to gate write ops in Go. Reads continue to work; shadow rules still apply (matched paths still route to the per-workspace shadow store, but writes there also EROFS via the kernel-level read-only flag).

This aligns with Sandbox's `sbx run claude . /path/to/docs:ro` syntax.
