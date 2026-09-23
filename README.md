# NeoHive installer

One-shot installer for the [NeoHive](https://neohive.ai) semantic-memory
server. This repo holds nothing but the shell script and a CI smoke test.
The server image lives on public Docker Hub — you need a NeoHive license
file from Logilica to activate it, but no registry credentials are
required to pull.

## Watch it in action

A short walkthrough of installing NeoHive and getting started:

<video src="https://github.com/NeoHiveAI/docs/releases/download/docs-media/getting-started.mp4" controls width="100%"></video>

If the player doesn't load, [download or open the walkthrough directly](https://github.com/NeoHiveAI/docs/releases/download/docs-media/getting-started.mp4).

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

You need a NeoHive license file — Logilica issues this from the
dashboard. Plain-text (`license.key`) and JSON (`license.json`)
formats are both supported. The installer finds the license through
the first path that resolves:

1. `--license-file PATH` (or `-l PATH`) command-line flag
2. `NEOHIVE_LICENSE_FILE=PATH` environment variable
3. Auto-detected `license.json` or `license.key` in the current
   working directory, then alongside `install.sh`
4. Interactive prompt for the path

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

## Apple Silicon: native Metal embedding (automatic)

Docker on macOS runs Linux containers in a VM with no GPU access, so
in-container embedding is CPU-only there. On Apple Silicon Macs
(M1 or later) the installer automatically provisions a small native
worker that runs the embedding model directly on the Metal GPU —
roughly 30–70× faster indexing, with no extra steps: just install or
upgrade as usual.

What it does on your machine:

- Installs a self-contained worker under `~/.neohive/metal-worker/`
  (own Node runtime included — nothing else to install) and a launchd
  agent `com.neohive.metal-worker` that keeps it running across
  reboots. It listens on `127.0.0.1` only; nothing is exposed to your
  network.
- Downloads embedding models to `~/.neohive/models/` on first use;
  logs go to `~/.neohive/logs/`.
- Points the NeoHive container at the worker. If any part of this
  fails (offline pull, blocked port, …) the installer prints a warning
  and NeoHive runs exactly as before, with in-container CPU embedding.

Non-macOS and Intel Mac installs are entirely unaffected.

Options:

| Variable                     | Default                                     | Effect                                                                                                           |
| ---------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `NEOHIVE_METAL_WORKER`       | `1`                                         | Set `0` to skip the Metal worker and keep in-container CPU embedding                                             |
| `NEOHIVE_METAL_WORKER_PORT`  | `50051`                                     | Loopback port the worker listens on, change it if 50051 is taken                                                 |
| `NEOHIVE_METAL_WORKER_IMAGE` | `docker.io/neohivedev/neohive-metal-worker` | Worker repository to install from. A repository on another registry needs `NEOHIVE_METAL_WORKER_TAG` set as well |
| `NEOHIVE_METAL_WORKER_TAG`   | matched to the installed image              | Exact worker version to install                                                                                  |

Upgrades: re-running the installer refreshes the worker to the version
matching the pulled NeoHive image. Downloaded models are kept.

To remove the worker later:

```sh
launchctl bootout "gui/$(id -u)/com.neohive.metal-worker"
rm -rf ~/.neohive/metal-worker ~/Library/LaunchAgents/com.neohive.metal-worker.plist
NEOHIVE_METAL_WORKER=0 bash <(curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/install.sh)
```

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

## Back up and restore

```sh
curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/backup.sh | bash
```

Writes `neohive-backup-<timestamp>.tar.gz` into the current directory
(`--out <dir>` to put it elsewhere). It holds every database, every vector
index and the encryption keys your credentials are stored with, plus a
`manifest.json` and `SHA256SUMS`. Databases are snapshotted consistently
while the server keeps running; a vector index written during the copy
comes out consistent but possibly a moment stale. The archive contains your
memories and indexed content, so keep it where you keep other private data.

To restore, download the script and point it at the archive:

```sh
curl -fsSLo backup.sh https://raw.githubusercontent.com/NeoHiveAI/install/main/backup.sh
bash backup.sh --restore neohive-backup-<timestamp>.tar.gz
```

The checksums are verified first, then the server is stopped, the volume's
contents replaced, and the server started again. You are asked to type the
volume name before anything changes; `--yes` skips that for scripts.

## Diagnostics for support

```sh
curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/logs.sh | bash
```

Writes `neohive-diag-<timestamp>.tar.gz` with the container's recent logs
and configuration, `/health`, disk use, the Metal worker's logs and launchd
state on Apple Silicon, and the settings in effect. Send it to
hello@neohive.ai with a description of the problem.

It never includes memories, indexed content, databases or credentials.
Every text file passes through a redaction filter that blanks the value of
anything named like a key, secret, token, password or licence, and the
cached licence key is looked for but only its presence is recorded. To see
exactly what is inside before sending: `tar -tzf neohive-diag-*.tar.gz`.
`--tail <n>` and `--since <duration>` control how much log is included.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/uninstall.sh | bash
```

Shows what it found, asks once, then removes the container, the cached
licence key and, on Apple Silicon, the Metal embedding worker and its
watchdog (both launchd agents are unloaded first, so nothing restarts them).
It also prints the plugin and MCP entries to remove in your editor, which
it cannot reach.

Your data survives by default: the `neohive-data` volume and the
licence-seat fingerprint in `~/.cache/neohive/machine-id` are kept, so a
later reinstall finds your hives and reuses the same seat. To delete
everything:

```sh
curl -fsSL https://raw.githubusercontent.com/NeoHiveAI/install/main/uninstall.sh | bash -s -- --purge-data
```

That offers to run a backup first and then asks you to type the volume name
before it is deleted. `--dry-run` prints the plan without changing anything;
`--yes` skips the questions for scripted use.

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
npx mcp-remote@latest http://localhost:3577/hives/<hive-id>/mcp
```

(requires Node.js / npx on the client)

The dashboard shows a copy-paste command for this. No server-side TLS
configuration is needed.

## Licence

The installer script in this repo is MIT licensed. The NeoHive container
image itself is proprietary.

## About NeoHive

[**NeoHive**](https://neohive.ai) is the one shared memory layer that runs entirely on your own infrastructure, works across every AI agent your team uses, and remembers what your team learns — not just what's in the code.

- 🌐 [neohive.ai](https://neohive.ai)
- 📚 [docs.neohive.ai](https://docs.neohive.ai)
