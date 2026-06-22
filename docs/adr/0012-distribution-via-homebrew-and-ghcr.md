# Distribution via Homebrew + GHCR

robo-pen ships as a Homebrew formula in `robsman/homebrew-tap` plus pre-built container images on `ghcr.io/robsman/{rp-base,robo-pen-default}`. The local `rp setup` recipe defaults to pulling those images instead of building from source.

## Why

Before this change, first-time setup required `git clone` + three `brew install` deps + `rp build-base` + `rp build` + `rp build-host` — about 15 minutes on a current Mac, blocking on Go cross-compile and ~1.5 GB of layer rebuilds. The container image content is identical across users; rebuilding from each fresh checkout is wasted work.

## What changed

1. **GitHub Actions release workflow** (`.github/workflows/release.yml`). Tagged-push trigger (`v*`) runs four jobs:
   - `host-binary` — cross-builds `rp-fuse-darwin-arm64` on `ubuntu-latest` (CGO disabled, so Linux can compile a Darwin binary).
   - `image-base` — `ubuntu-24.04-arm` native runner; builds `Dockerfile.base` for `linux/arm64`; pushes to `ghcr.io/<owner>/rp-base:vX.Y.Z` + `:latest`.
   - `image-default` — depends on `image-base`; rewrites the local `FROM rp-base` to `FROM ghcr.io/<owner>/rp-base:<tag>` and pushes `robo-pen-default`.
   - `release` — bundles source + host binary into `robo-pen-vX.Y.Z.tar.gz`, attaches checksum, calls `gh release create`.

2. **`rp setup` prefers pull over build.** New recipe `pull-images` pulls + re-tags ghcr images as the local tags (`rp-base`, `robo-pen-default`) the rest of the tooling expects. `RP_BUILD_FROM_SOURCE=1` flips back to the local-build path for Dockerfile development. `RP_REGISTRY_OWNER` + `RP_IMAGE_TAG` let users pin a fork or a specific release.

3. **`rp build-host` short-circuits if the binary is already present.** Release tarballs ship the pre-built binary at the expected path, so the Go cross-compile step disappears for end users. `RP_FORCE_BUILD_HOST=1` overrides.

4. **Homebrew formula** at `dist/homebrew/robo-pen.rb` (canonical copy in this repo; the tap repo's `Formula/robo-pen.rb` is the deploy target). Declares deps on `container`, `jq`, `just`; constrains to `arch: arm64 + macos`; symlinks the wrapper into `bin/`. Updated per release by bumping `url` + `sha256` (automated later via `brew bump-formula-pr`).

## Rejected alternatives

- **`curl … | bash` install script.** Simpler than Homebrew for one-off users but worse hygiene; people running it inherit a moving target. The formula gives us versioned, audited install.
- **Bundling images into the brew formula.** Brew bottles cap around a few hundred MB; ~1.5 GB of image layers belongs in a container registry, not in a bottle.
- **`docker buildx` multi-arch.** Apple Container is Apple-Silicon-only; amd64 layers would just inflate the registry. Re-add if Docker Sandbox support ever returns (currently parked, see ADR-0010 status notes).
- **Auto-rolling `:latest`.** `rp setup` defaults to `:latest` for convenience but the formula pins a specific tag; users wanting reproducibility export `RP_IMAGE_TAG=vX.Y.Z`.

## Per-release procedure

1. Tag + push: `git tag v0.2.0 && git push origin v0.2.0`.
2. CI builds images, pushes to GHCR, creates the GitHub release with the tarball + checksum + host binary.
3. Bump the formula: copy `dist/homebrew/robo-pen.rb` into `robsman/homebrew-tap/Formula/robo-pen.rb`, update `url` (`v0.1.0` → `v0.2.0`) and `sha256` (from the `.sha256` file attached to the release), commit, push.
4. (Future) Automate step 3 with `dawidd6/action-homebrew-bump-formula`.

## Risks

- **`ubuntu-24.04-arm` availability.** GitHub's native arm64 public-runner went GA in 2025. Free for public repos. If GitHub changes the policy, fall back to qemu emulation on `ubuntu-latest` (~5× slower).
- **GHCR storage costs.** Free for public repos at arbitrary scale.
- **GHCR pull rate limits.** Anonymous pulls are rate-limited; once a user has the images locally, the cap doesn't matter. CI pulls authenticate with `GITHUB_TOKEN`.
