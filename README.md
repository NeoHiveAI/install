# NeoHive installer

One-shot installer for the [NeoHive](https://neohive.ai) semantic-memory
server. This repo holds nothing but the shell script and a CI smoke test.
The server image lives on public Docker Hub — you need a NeoHive license
file from Logilica to activate it, but no registry credentials are
required to pull.

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

A license key is **optional**. With no key, NeoHive installs and runs in
**Demo mode** — the free tier, with a small cap on projects and hives. Add a
key any time to unlock the full product in place (no reinstall, no restart):
see [Rotate your license](#rotate-your-license). Logilica issues full license
files from the dashboard. Plain-text (`license.key`) and JSON (`license.json`)
formats are both supported. The installer finds a license through the first
path that resolves, and falls back to Demo mode if none do:

1. `--license-file PATH` (or `-l PATH`) command-line flag
2. `NEOHIVE_LICENSE_FILE=PATH` environment variable
3. Auto-detected `license.json` or `license.key` in the current
   working directory, then alongside `install.sh`
4. Interactive prompt for the path (press Enter to run Demo)
5. **Demo mode** — no key supplied; runs the capped free tier

The simplest workflow is to drop the file next to where you're
running the installer and let auto-detection handle it. The extracted
key is cached at `~/.cache/neohive/license-key` after first install
so upgrades don't re-supply the file.

For CI or headless hosts, the env-var form is cleanest:

```sh
NEOHIVE_LICENSE_FILE=/path/to/neohive.license \
  bash <(curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh)
```

## Upgrade

Re-run the install command. The `neohive-data` Docker volume is preserved
across upgrades.

## Force the CPU backend

The installer auto-detects your hardware (CUDA, ROCm, Vulkan, or CPU).
If detection picks the wrong backend, or the chosen backend fails to
pull or start, retry with the CPU backend forced on:

```sh
NEOHIVE_BACKEND=cpu bash <(curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh)
```

CPU mode runs everywhere but is slower than a working GPU backend.
**Please also report the failure** to the NeoHive team (`support@neohive.ai`
or your pilot onboarding contact) so we can fix the underlying backend issue.
The installer surfaces this command on stderr when a pull or start
failure looks backend-related.

## Rotate your license

If Logilica issued you a replacement license, drop the new file at the
same path and force the installer to re-read it:

```sh
NEOHIVE_LICENSE_FILE=/path/to/new-neohive.license \
NEOHIVE_ROTATE_LICENSE=1 \
  bash <(curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh)
```

If Keygen rejects the cached key on validation, the installer also
clears `~/.cache/neohive/license-key` automatically — so a plain re-run
with the new file is enough to re-read in that case.

## Uninstall

```sh
docker rm -f neohive
docker volume rm neohive-data    # destroys all data, run only if you're sure
rm -f ~/.cache/neohive/license-key
```

## Non-interactive (CI / scripted)

```sh
NEOHIVE_LICENSE_FILE=/path/to/neohive.license \
  curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh | bash
```

Or, if you've downloaded the script to disk and want to pass the
license path as a flag rather than an env var:

```sh
./install.sh --license-file /path/to/neohive.license
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
