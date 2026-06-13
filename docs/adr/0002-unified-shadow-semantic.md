# Unified "shadow" semantic

An earlier prototype distinguished two directives in `.ccrshadow`:

- `mask <path>` — hide host content (read-only 0-byte ghost over the path)
- `private <path>` — redirect container's writes to a container-local store

We collapsed these into a single "shadow" semantic: a listed path is invisible to the container, and the container has its own writable store for that path. Both prior use cases (hiding secrets, isolating build artifacts) reduce to the same operation. Reasoning:

- The container's writable store starts empty. For a "mask" use case (`.env.local`), the container that doesn't write to the path sees ENOENT — same observable behavior as the 0-byte ghost, plus the strict upgrade that the container can now keep its own version for test fixtures.
- The "read-only ghost" semantic of the old `mask` was never useful in practice — if you want the container to see host content, just don't list the path.
- One directive, one mental model, one code path.

The cost (losing read-only-ghost) is theoretical; the gain (a single coherent concept) is concrete.
