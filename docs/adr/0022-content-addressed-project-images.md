# Content-addressed project images

`build-project-image.sh` tags the composed image as `<container-name>:latest-rp`, so every new container name means a new overlay build. With one container per short-lived worktree (ADR-0019), that puts an image build on the hot path of every new task. The image doesn't even depend on the worktree. Its inputs are configuration only, and the source tree is bind-mounted at run time.

A second problem exists today, independent of worktrees. The image is built only when the container doesn't exist yet. For an existing container, nothing compares the image with the current `.rp/`. If you switch branches in a plain clone and `.rp/config.yaml`, `.rp/Dockerfile` or the plugin list differ, the container silently keeps running the old image until it is destroyed.

## Decision

1. **The tag is a hash of the build inputs**: `rp-img-<agent>-<hash12>:latest-rp`. The inputs are:
   - the resolved configuration, i.e. `config.yaml` merged with the effective `config.local.yaml` (ADR-0023)
   - `.rp/Dockerfile` or the configured `build:` Dockerfile and its context
   - `.rp/instructions.md` and `.rp/agents/<name>/`, if present
   - the agent profile files
   - the `rp-system` tag
   - the version of the overlay generator itself, so an overlay change in robo-pen invalidates images
2. **Reuse is automatic.** If an image with the tag exists, `rp create` uses it without building. Worktrees of one repo with identical `.rp/` (almost every new worktree) share one image, and so do two plain clones of the same project.
3. **Concurrent builds are serialised per hash** with a host-side lock, so two worktrees starting at the same time don't build the same image twice.
4. **The hash is recorded on the container** as label `rp.image_hash`. Every `rp run`, `shell` and `login` recomputes it from the current `.rp/`, which costs a few file hashes and no build, and compares.
5. **A mismatch warns; it never recreates.** `rp` prints which input changed and suggests `rp recreate`. Recreating in the middle of a task would destroy container-local state (shadowed dependencies, a running agent session), and a prompt would break non-interactive use (`rp run -- "prompt"`). Because images are content-addressed, `rp recreate` is usually fast: the image for the new hash often already exists from another worktree.
6. **`rp recreate`** replaces the container with one built from the current inputs. It keeps the workspace volume (ADR-0024).

## Rejected alternatives

- **One image per repository.** A branch that edits `.rp/` would either run on the wrong image or rebuild it for every other worktree.
- **An explicit `--image` choice.** Pushes bookkeeping onto the user that the hash does for free.
- **Automatic recreate on mismatch.** Destroys state in the middle of a task without asking.

## Boundaries

- The hash covers inputs, not upstream content. A Dockerfile with `FROM node:latest` or unpinned `apt-get install` won't pick up upstream changes on its own. A forced rebuild (`rp recreate --rebuild`) stays available.
- Old hashes accumulate. Images no container references are removed by `rp gc` (ADR-0025). `rp destroy` no longer removes images, because they are shared.
- Containers from before this ADR have no `rp.image_hash`. They count as stale, and the warning tells the user that `rp recreate` migrates them (ADR-0025).
