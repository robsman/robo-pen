## Available Tools

| Tool | Version/Notes |
|------|---------------|
| git | System package |
| curl | System package |
| build-essential | gcc, g++, make, etc. |

No language runtime (Node, Python, R, ...) is preinstalled. If this
project needs one, check for a `.rp/Dockerfile` or a `build:`/`image:`
entry in `.rp/config.yaml` — if neither exists, that runtime isn't
available in this container and installing it yourself won't persist
past this container's lifetime unless it's baked into one of those.
