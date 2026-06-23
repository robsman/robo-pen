# Persistent volumes for agent state (login, caches)

Agents accumulate runtime state inside the container — most importantly login tokens written by `claude login`, but also history files, indexes, and per-agent caches. Pre-volume, all of that lived in the container's writable layer and disappeared the moment `rp destroy` removed the container. Users had to re-login after every config change that required a recreate.

ai-pod handles this with a named volume mounted at the agent user's home. We follow the same pattern but back the volume with a host bind under `~/.local/share/robo-pen/volumes/<container-name>/<volume-name>/` — explicit, inspectable, and trivially cleaned up by `rp purge` (no Apple Container named-volume management to wrangle).

## What changed

1. **Profile manifest gains `volumes:`**: a list of `{name, mount}` entries. `mount` is relative to `/home/<user>/` (absolute paths are rejected at parse time to keep profiles from shadowing arbitrary in-container locations like `/etc`). Validated by `ProfileManifest.Validate`.

2. **claude-code declares one volume**: `{name: claude-home, mount: .claude}` so the entire `~/.claude` dir persists across destroy + create.

3. **`scripts/resolve-volumes.sh` (new)**: reads the manifest's volumes, mkdirs the host backing dir at `$RP_VOLUMES_DIR/<container>/<volume>/`, and echoes one TSV line per volume (host-dir, container-mount, name). The Justfile `_ensure` / `create` recipes consume this to append `-v` flags and a `RP_VOLUMES=<mount>=<name>,…` env var.

4. **`config/rp-init.sh` seeds + chowns each volume**: iterates `RP_VOLUMES`. If the bind-mounted dir is empty AND `/usr/local/share/rp/seed/<name>/` exists, copies the seed contents into the mount. Then `chown -R $RP_USER` so the agent owns its home.

5. **`scripts/build-project-image.sh` routes file destinations into the seed**: any `files:` entry (and the composed `instructions_dst`) whose `dst` falls inside a declared volume's mount path is COPYed to `/usr/local/share/rp/seed/<volume-name>/<rel>` instead of its absolute target. Without this routing, the in-image content would exist at the original path, but `container create -v <host>:<mount>` would shadow it the moment the container starts — so default settings would vanish on first launch.

6. **`rp-init-bootstrap`** forwards `RP_VOLUMES` through the env-clear barrier.

7. **`rp purge`** wipes `$RP_VOLUMES_DIR` so an aggressive reset doesn't leave login tokens behind.

## Lifecycle in one picture

```
rp create:
  resolve-volumes.sh         ── mkdir $HOST_VOL_ROOT/<cont>/<name>/
  container create -v HOST_VOL:/home/<user>/<mount>
                  -e RP_VOLUMES=<mount>=<name>,...

container start:
  rp-init-bootstrap          ── escalate to root (setuid)
  rp-init.sh                 ── for each volume:
                                 if mount empty: cp -a /usr/local/share/rp/seed/<name>/. <mount>/
                                 chown -R $RP_USER:$RP_USER <mount>
  rp-fuse                    ── (unrelated) mounts the workspace FUSE

rp destroy:
  container delete           ── container goes away
  HOST_VOL_ROOT stays on disk

rp create (again):
  HOST_VOL_ROOT/<cont>/<name>/ already has the user's writes
  container create binds it back at the same mount
  init sees non-empty → skips seed → just chowns → done
```

## Rejected alternatives

- **Container-runtime named volumes** (`-v claude-home:/home/coder/.claude` where `claude-home` is an Apple Container managed volume). Apple Container does support named volumes, but their lifecycle isn't well-documented and `container volume rm` would need integration with `rp purge`. The host-bind path is fully explicit + lets users browse / back up the dir.
- **Per-workspace volumes** (`<workspace-slug>/<volume>` instead of `<container-name>/<volume>`). Container name already encodes workspace + agent (`rp-<agent>-<basename>`), so scoping by container name is identical to scoping by workspace+agent. Avoids the extra slug computation.
- **Copy-on-first-create from host's `~/.claude`** (ai-pod's literal flow). Saves the user one `claude login` on first set-up but exposes host credentials to the container even when shadow rules would normally hide them. Defer to Phase 2 (`host_files:`) which makes the host-side opt-in explicit and overridable per file.
- **Seed at create-time inside an init container** (ai-pod's flow). Apple Container has no clean equivalent to `docker cp` into a stopped container, so we'd need extra orchestration. Seeding at PID 1 inside the regular container is the same idea simpler.

## Boundaries

- Volume mounts are not workspaces. They land in the agent user's home, NOT under any FUSE-shadowed workspace path. Shadow rules don't apply.
- Volumes are scoped per container name. Two workspaces with the same basename + same agent share a volume — usually fine, occasionally surprising; document that `--name` disambiguates.
- Volume content is plaintext on the host. Tokens written by `claude login` live in `$RP_VOLUMES_DIR/<cont>/claude-home/.credentials.json` with 0600 perms set by init's chown. Anyone with host access can read them. Same trust model as ai-pod's volume + the existing rp.host_path label; documented in the ADR rather than encrypted.
- Volumes survive `rp destroy` but not `rp purge`. `purge` is the explicit "scorched earth" hook (gated behind `RP_PURGE_YES=1`).
- The volume-seed routing in build-project-image.sh only kicks in for `dst` paths that match `/home/<user>/<volume.mount>` exactly or as a prefix. Paths outside any declared volume keep their original semantics.

## Tests

- `rp-fuse/profile_test.go`: schema parsing, absolute / `..` / duplicate-name rejection, field accessor.
- `tests/integration/test-volume-persist.sh`: end-to-end. Verifies (a) settings.json appears in the volume after seed, (b) writes survive `rp destroy && rp create`, (c) host backing dir matches expectations.
