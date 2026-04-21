# NeoHive installer

One-shot installer for the [NeoHive](https://neohive.ai) semantic-memory
server. This repo holds nothing but the shell script and a CI smoke test.
The server itself is a private container image. You need an access token
from Logilica to pull it.

## Requirements

- Linux or macOS (on Windows: use WSL2)
- Docker 20+ — install via
  [Docker Desktop](https://www.docker.com/products/docker-desktop/) on
  macOS/Windows, or follow the
  [Docker Engine install guide](https://docs.docker.com/engine/install/)
  on Linux
- Port 3577 available on localhost

## Install

**bash / zsh:**

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh)
```

**fish:**

```fish
bash (curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh | psub)
```

**Any shell (two-step):**

```sh
curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh -o /tmp/neohive-install.sh
bash /tmp/neohive-install.sh
```

You'll be prompted for your GHCR access token. After first install the token
is cached at `~/.cache/neohive/ghcr-pat` so upgrades don't re-prompt.

## Upgrade

Re-run the install command. The `neohive-data` Docker volume is preserved
across upgrades.

## Uninstall

```sh
docker rm -f neohive
docker volume rm neohive-data    # destroys all data, run only if you're sure
rm -f ~/.cache/neohive/ghcr-pat
```

## Non-interactive (CI / scripted)

```sh
NEOHIVE_PAT=ghp_xxx curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh | bash
```

## MCP over HTTPS

The server serves plain HTTP. If your MCP client requires TLS, wrap the
endpoint with [mcp-remote](https://www.npmjs.com/package/mcp-remote):

```sh
npx mcp-remote@latest http://localhost:3577/hiveminds/<id>/mcp
```

(requires Node.js / npx on the client)

The dashboard shows a copy-paste command for this. No server-side TLS
configuration is needed.

## Licence

The installer script in this repo is MIT licensed. The NeoHive container
image itself is proprietary.
