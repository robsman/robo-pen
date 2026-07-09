# Host aliases via /etc/hosts injection

Containers run by rp need a stable way to reach the host (e.g. a database service on the host, a localhost-bound dev server). Docker and Podman expose this via `--add-host <name>:host-gateway` + a magic `host-gateway` resolver in their network stack. Apple Container has no such flag (`container create --help` confirms no `--add-host`). We approximate the convention from inside the container.

## Decision

1. `.rp/config.yaml` adds a `host_aliases:` block. Each entry is either a bare string (resolves to `host-gateway`) or `{name: NAME, ip: IP}`. The Go parser supports both shapes via a custom `HostAlias.UnmarshalYAML`.
2. `host.containers.internal → host-gateway` is **always** injected (whether or not the user lists it). Matches Podman's default + ai-pod's convention so tools that hard-code that name keep working.
3. `scripts/resolve-create-args.sh` reads the effective alias list via `rp-fuse config field host_aliases` and forwards it to the container as a single env var `RP_HOST_ALIASES=name1=ip1,name2=ip2,…`.
4. `config/rp-init.sh` reads `RP_HOST_ALIASES` early in init (before the FUSE stack is up; still running as root). For each entry it appends one line to `/etc/hosts` tagged `# rp-host-alias` so re-launches can de-dup idempotently.
5. The literal `host-gateway` is resolved at append time by reading `/proc/net/route` and decoding the default route's gateway field. The route appears asynchronously on Apple Container — the network is brought up after PID 1 starts running — so init.sh polls for up to ~3s before giving up on `host-gateway` entries.

## Rejected alternatives

- **`--add-host` flag.** Apple Container doesn't support it. Forwarding to the user would mean: works on Docker, breaks on Apple Container. Not worth the divergence.
- **Bind-mount a generated `/etc/hosts`.** Works in principle, but Apple Container's image setup makes `/etc/hosts` come from the image layer, not from a bind. We'd have to either materialise it pre-container-start (chicken-and-egg with the gateway IP) or accept the same in-container write path init.sh already has.
- **DNS-only approach via `--dns`.** Apple Container does support `--dns`, but pointing it at the host's resolver doesn't help: there's no DNS server on the host that would respond to `host.containers.internal`. We'd need to run a stub resolver, which is a much bigger lift than appending to `/etc/hosts`.
- **Use `gawk` strtonum for hex decode in init.sh.** Debian's default awk is mawk, which lacks `strtonum`. Either ship gawk in rp-system (extra dependency) or decode with bash arithmetic — went with bash arithmetic (zero extra dep, the script already requires bash).

## Boundaries

- Aliases live in `/etc/hosts` inside the container only. Nothing on the host changes.
- Aliases are appended at PID 1 startup. Changes to `host_aliases:` take effect on the next `rp destroy && rp create` (same edit-config cycle as other config keys).
- A `host-gateway` alias is best-effort: if the route doesn't appear within ~3s, init logs a WARN and skips that entry. Fixed-IP entries (e.g. `192.168.64.10`) always succeed.
- IPv6 is not supported yet. `validateIP` rejects anything that isn't IPv4 dotted-quad.

## Validation

`rp-fuse/config_test.go` covers: scalar + mapping schema forms, default `host.containers.internal` injection, user-override of the default, rejection of bad hostnames + out-of-range octets.

`tests/integration/test-host-aliases.sh` covers: end-to-end injection on a real container, `getent` resolution from the agent user, both `host-gateway` aliases sharing the gateway IP, fixed-IP exact match.
