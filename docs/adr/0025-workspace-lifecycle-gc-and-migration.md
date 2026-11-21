# Workspace lifecycle: destroy, gc and migration

Short-lived worktrees produce leftovers all the time. robo-pen doesn't notice `git worktree remove` or a deleted directory. With shared images (ADR-0022) and volumes that live as long as the workspace (ADR-0024), the old cleanup rules no longer fit:

- `rp destroy` removed the container and "its" image, and kept volumes.
- `rp gc` only swept old base image tags.

## Decision

### robo-pen reacts to worktrees; it doesn't manage them

Users create worktrees with their own tooling (`git worktree add`, an IDE, a script) and run `rp run` in them. robo-pen doesn't create or remove worktrees.

- Where a new worktree goes depends on the layout, and there's no standard. Owning this would add a configuration surface with little benefit.
- Docker Sandboxes tried the opposite (`sbx run --branch` created worktrees under `.sbx/`) and removed it in sbx v0.31.0.

A thin `rp task new|done` layer can come later without changing anything below.

### Cleanup

| Resource | Removed by |
|---|---|
| Container | `rp destroy`; `rp gc` when its `rp.host_path` no longer exists |
| Workspace volume | `rp destroy` (**changed**: no longer survives); `rp gc` when its recorded path no longer exists |
| Project image (hash) | `rp gc` when no container references it |
| Legacy `*:latest-rp` image | `rp gc` when no container references it |
| Repo memory | never automatically. `rp gc` reports it when the common dir is gone and deletes it only with `--memory` |

- **No automatic cleanup during normal commands.** A path on an unmounted external drive or network share looks deleted. `rp run` only prints a hint when orphans exist ("3 orphaned workspace containers, run `rp gc`").
- **`rp gc` shows what it will remove and asks for confirmation.** `--yes` skips the prompt for scripts.
- Memory is the only resource with long-term value, so it is the only one protected.

### Lazy migration on `rp recreate`

Existing containers keep working unchanged. They carry `rp.host_path`, so the path-based lookup (ADR-0021) finds them under their old names, with their old volume dirs mounted. They have no `rp.image_hash`, so the stale-image warning (ADR-0022) appears with the hint "image predates hash tracking — `rp recreate` migrates this workspace".

`rp recreate` on a legacy container:

1. moves `$RP_VOLUMES_DIR/<old-container-name>/` to `$RP_VOLUMES_DIR/workspaces/<workspace-key>/`, so login and history survive
2. copies `claude-home/projects/*/memory/` into the repo memory dir, **only if that dir is empty**, so the first worktree recreated seeds the repo's memory without any merge logic
3. creates the container from the hash image with the new labels (`rp.image_hash`, `rp.volume_key`)

Legacy volume dirs whose container is already gone have no path metadata. `rp gc` lists them as "legacy, origin unknown" and deletes them only with `--legacy`.

## Implementation

- Containers carry `rp.volume_key` (the workspace key). `rp destroy` removes `workspaces/<rp.volume_key>/`. A legacy container has no such label, so `destroy` leaves its `$RP_VOLUMES_DIR/<container-name>/` in place and says so: that dir may hold auto-memory that was never migrated. `rp gc --legacy` removes it later.
- `rp gc` is `scripts/gc.sh`. It prompts only when stdin is a terminal; otherwise it prints the list and fails, and `--yes` is required. Images in use are computed against the containers that remain after the planned removals, so an orphaned container's image goes in the same run. Old `rp-system`/`rp-default` tags (everything but the current pin and `:latest`) are swept as before.
- The `rp run` hint counts orphaned containers only, at the cost of one `container list` call. Orphaned volume dirs need `rp gc` to show up.
- `rp recreate` migrates after deleting the old container and before creating the new one. A failed migration is reported but doesn't stop the create, so the user is never left without a container. If `workspaces/<key>/` already exists, the legacy dir stays for `rp gc --legacy`. The keys are computed from the recorded workspace rather than the current directory, so `rp recreate --name` from elsewhere migrates to the right place.

## Rejected alternatives

- **Automatic orphan pruning on every command.** It destroys state on temporarily unavailable paths.
- **A one-shot migration command.** It forces a cut-over for every workspace at once, while lazy migration happens anyway the first time each workspace needs a recreate.
- **Keeping volumes across `destroy`.** Unbounded growth with short-lived worktrees. The state that has long-term value (memory) now lives in its own repo-scoped dir.
