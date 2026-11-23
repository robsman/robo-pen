# `config.local.yaml` falls back to the repo home

ADR-0017 introduced `.rp/config.local.yaml` as the gitignored, per-developer layer on top of the committed `.rp/config.yaml`. It carries personal plugins, `host_files` imports (dotfiles, `~/.claude.json`) and `host_keychain` credentials.

Because it is gitignored, a **freshly created worktree doesn't have it**. Without a fix, every new task container runs without your plugins and credentials, so it needs `rp login` again. It also gets a different image hash than your other worktrees (ADR-0022), which defeats image reuse.

## Decision

1. **Repo home** is the parent of the git common dir:
   - layout B (`~/proj/.git`): the regular checkout `~/proj`
   - layout A (`~/proj/.bare`): the project folder holding `.bare` and all worktrees
2. **Resolution order**, each later layer overriding the earlier one with ADR-0017's merge rules:
   1. the worktree's committed `.rp/config.yaml` (the branch you're on decides the team config)
   2. `<repo home>/.rp/config.local.yaml`
   3. the worktree's own `.rp/config.local.yaml`, if present (a per-task override)
3. Only `config.local.yaml` is taken from the repo home. It is gitignored and doesn't depend on the branch. The committed config always comes from the workspace itself.
4. For a plain clone or a main worktree, the repo home is the workspace itself, so nothing changes.
5. **A worktree without any `.rp/`** takes the repo home's whole `.rp/` instead: its `config.yaml`, `config.local.yaml`, `shadow`, `Dockerfile`, `instructions.md` and `agents/`. This covers repos that don't commit `.rp/`, where a new worktree would otherwise run with no config and no shadow rules at all. The dir is taken from one place, never mixed. Once the worktree has a `.rp/` of its own (a branch that commits one), point 3 applies again. `rp-fuse rpdir <workspace>` answers which dir applies. (Amended for worktree-oriented flows, where a tool creates worktrees and starts a container in each.)
6. **Layout C** (`~/repos/proj.git`) has no fallback: its parent is shared by all central repos. If a worktree there has no `config.local.yaml`, `rp` prints a hint, and the worktree runs with the committed config only. A per-repo host-side file could fill this gap later.

The fallback lives in the config loader (`rp-fuse config`), so every consumer sees the same layers. Shadow rules are read inside the container, which can't see the repo home. So for point 5, `rp create` captures the repo home's `.rp/shadow` and passes it to `rp-init` as `RP_SHADOW_FALLBACK`. `rp-fuse` uses it only while the worktree still has no `.rp/`. Changes to those rules apply on `rp recreate`; the stale-image warning doesn't cover them. It finds the repo home by parsing the worktree's `.git` file and the `commondir` it points to, without running git, which keeps the frequent config lookups cheap. A repo home is only recognised when the common dir is named `.git` or `.bare`. Any other name counts as layout C, and only then is the hint printed, at image resolution time.

## Why the repo home is safe

`config.local.yaml` decides which host files and keychain entries are copied into containers. Anything that can write it effectively controls what leaves the host, so it must not be writable by an agent.

A worktree container binds only its worktree and the common dir (ADR-0019), never the repo home's `.rp/`. In layout A the repo home is the parent of both binds, and in layout B the main checkout's `.rp/` is outside the `.git` bind. In both cases no worktree container can write the fallback file.

The worktree's own `.rp/config.local.yaml` (layer 3) is inside the workspace bind, but `rp-fuse` makes the whole `.rp/` tree read-only to the container, including renaming or deleting `.rp` itself. None of the three layers can be written by the agent. The same protection keeps point 5 safe: `rp-fuse` refuses to create `.rp` in a workspace that has none, so the agent can't switch the fallback rules off. The captured rules live in the container's environment and in `/var/lib/rp` (root-only).

## Rejected alternatives

- **A file inside the common dir** (`.bare/rp/config.local.yaml`). It is shared by all worktrees automatically, but the agent can write it through the read-write common-dir bind.
- **A per-repo file under `~/.config/robo-pen/`.** Safe, but it moves personal project config away from the project, where users don't expect it. It remains the candidate for layout C.
- **Copying the file into each new worktree** (manually, or with a git hook). Creates copies that drift apart, and a bare layout has no main worktree to copy from.
