## v1.6.4 (2026-07-10)

## What's Changed
* fix(chunker): :bug: guard oversized code files from CodeSplitter timeout (HIVE-302) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/107


**Full Changelog**: https://github.com/NeoHiveAI/MemVec/compare/v1.6.3...v1.6.4


## v1.6.3 (2026-07-06)

## What's Changed
* fix(scheduler): :bug: remove orphaned git-sync schedules on hive delete (HIVE-291) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/100


**Full Changelog**: https://github.com/NeoHiveAI/MemVec/compare/v1.6.2...v1.6.3


# Changelog

All notable changes to [NeoHive](https://neohive.ai) are published here.
The in-app update banner reads each version's `### Release overview`
block and links back to this file for the full notes; everything else
is reference material for users who want the details.

The format follows [Keep a Changelog](https://keepachangelog.com/) and
the project adheres to [Semantic Versioning](https://semver.org/).

## v1.5.0 — 2026-05-21

### Release overview
The biggest NeoHive release to date. License-based activation, a faster
vector store, a redesigned onboarding flow, smarter MCP responses, and
a friction-free install experience. Existing installs upgrade in
place — re-run the installer and the gateway picks up where it left off.

### Activation
- License-based activation, with up to 72 hours of offline grace if
  our licensing service is briefly unreachable.
- Moving NeoHive to a new machine no longer leaves a stale seat
  behind — the next install picks up the freed slot automatically.
- New Settings → Licence page shows current state, expiry, grace
  remaining, and self-serve licence rotation.

### Performance
- Recall on hives of a few thousand or more memories is significantly
  faster.
- Dashboard navigation and project switching feel snappier across
  the board.
- `memory_store` now accepts content well past the previous size
  limit — long bodies are chunked automatically.
- Smarter routing of code, markdown, prose, and PDFs to the right
  indexer on the way in.

### MCP and Claude
- Claude is materially better at reusing recalled memories across
  long conversations.
- Claude picks the right memory tool more often without prompting,
  especially for codebase search and subagent flows.
- The MCP install step in onboarding works with any client — Claude
  Code, Cursor, Codex, etc. — and advances on its own once your
  editor connects.

### Onboarding and dashboard
- Refreshing the page mid-setup resumes where you left off rather
  than restarting the wizard.
- Repo onboarding shows live clone and indexing progress as it
  runs.
- Dashboards with many open hives stay smoother on slow networks.
- The update banner now shows release highlights, links to the full
  changelog, and adds a manual "Check now" button.

### Install
- Install now uses a license file instead of an access token. The
  previous access tokens have been revoked — install using the
  license file provided by the NeoHive team.

### Fixes
- Long syncs no longer get interrupted by idle suspension, and
  scheduled syncs wake their worker on time.
- Reinstalling on the same machine no longer burns a fresh licence
  seat each time.

## v1.4.10 — 2026-05-14

### Release overview
Adds `NEOHIVE_PDF_BRIDGE_TIMEOUT_MS` (and `NEOHIVE_PDF_WARMUP_TIMEOUT_MS`)
so ingestion of very large PDFs through the docling bridge no longer
times out at the default 5-minute per-document budget. A 900-page
document typically needs ~25-30 minutes
(`NEOHIVE_PDF_BRIDGE_TIMEOUT_MS=1800000`). Supersedes v1.4.9, which
exposed the wrong knob (`NEOHIVE_CHUNKER_TIMEOUT_MS` gates the
markdown/code chunker, not docling).

### Added
- `NEOHIVE_PDF_BRIDGE_TIMEOUT_MS` env override - the correct knob for
  large-PDF docling timeouts. Forwarded as `MEMVEC_PDF_BRIDGE_TIMEOUT_MS`
- `NEOHIVE_PDF_WARMUP_TIMEOUT_MS` env override for first-boot model
  warmup on hosts with slow HuggingFace downloads

## v1.4.9 — 2026-05-14

### Release overview
Adds a `NEOHIVE_CHUNKER_TIMEOUT_MS` environment override so ingestion of
very large PDFs through the docling bridge no longer times out at the
default 30-second per-chunk budget. Forwarded to the container as
`MEMVEC_CHUNKER_TIMEOUT_MS`. A 900-page document typically needs ~20
minutes (`NEOHIVE_CHUNKER_TIMEOUT_MS=1200000`).

NOTE: v1.4.9's advertised PDF use case is incorrect -
`MEMVEC_CHUNKER_TIMEOUT_MS` gates the markdown/code chunker, not the
docling PDF bridge. Use `NEOHIVE_PDF_BRIDGE_TIMEOUT_MS` (added in
v1.4.10) for large PDFs.

### Added
- `NEOHIVE_CHUNKER_TIMEOUT_MS` env override on the installer, validated
  as a positive integer and forwarded to the container

## v1.4.8 — 2026-04-23

### Release overview
Hotfix release: preflight NVIDIA Container Toolkit before pulling the
`:cuda` image so CUDA hosts without `nvidia-container-toolkit` get a
clear error instead of an opaque container start failure.

### Fixed
- `:cuda` install path now fails fast with an actionable message when
  the NVIDIA Container Toolkit is missing on the host

## v1.4.7 — 2026-04-22

### Release overview
Trust multi-arch manifest lists in tag resolution and filter pre-release
tags from the fallback chain so `latest` resolves cleanly on ARM hosts.

### Fixed
- Multi-arch manifest lists are now treated as valid by the tag resolver
- Pre-release tags (`-rc1`, `-beta`) no longer leak into the fallback chain

## v1.4.6 — 2026-04-20

### Release overview
Adds a deterministic image tag fallback chain with a dry-run harness so
backend mismatches degrade gracefully (e.g. CUDA → Vulkan → CPU) rather
than failing the install outright.

### Added
- Image tag fallback chain per backend
- `NEOHIVE_DRY_RUN=1` harness for testing fallback logic without
  touching `docker pull`
