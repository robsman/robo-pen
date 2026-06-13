# Strict gitignore subset; rename to `.ccrshadow`

The rule file is named `.ccrshadow` (not `.ccrignore`) and its pattern semantics are a **strict subset** of `.gitignore`:

- Same anchoring rules as `git`: leading `/` OR any mid-pattern `/` anchors to the workspace root.
- `*`, `**`, `?`, `[…]` globs.
- Trailing `/` restricts to directories.
- **Negation (`!pattern`) is not supported** — silently skipped with a warning. The "shadow" semantic is union-only; there is no negation concept.

Reasoning:

- **The filename signals different semantics.** `.gitignore` excludes paths from VCS; `.ccrshadow` reroutes paths to a container-local store. Using the same filename `.ccrignore` would invite the assumption "this is just like gitignore" — which is wrong for negation and for the read/write reroute behavior.
- **`go-gitignore` (the library we use) treats mid-slash patterns as unanchored**, which diverges from real `git` behavior. We override classification so mid-slash patterns are anchored per git spec; users copying patterns from a real `.gitignore` get the behavior they expect.
- **Negation conflicts with our model.** A path is either shadowed or not — there's no "shadow this directory but expose this specific file" because re-introducing a single file would require crossing the boundary at a specific subpath, which complicates the resolution layer without clear demand.

Trade-off: users with `.gitignore` muscle memory must know "negation isn't supported". The lint subcommand (`ccr lint`) reports unsupported patterns explicitly.
