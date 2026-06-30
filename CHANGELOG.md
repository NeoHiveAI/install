## v1.6.0 (2026-06-30)

## What's Changed
* fix(ci): drop gh CLI dependency from release tag job by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/55
* fix: handle Keygen HEARTBEAT_NOT_STARTED in validateLicense by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/56
* feat(v1.6): :truck: NeoHive v1.6 — Cycle 2 (staging branch, stacked on v1.5) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/32
* fix(gateway): :bug: SSE events query-param + sync registry-client resolution (HIVE-214/215) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/61
* fix(sync): :bug: full re-scan when last_indexed_sha is unreachable (HIVE-216) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/62
* ci: add frontend tests and codecov reporting by @deanmcgregor in https://github.com/NeoHiveAI/MemVec/pull/63
* ci: trigger test on main branch as well by @deanmcgregor in https://github.com/NeoHiveAI/MemVec/pull/65
* fix(git): :bug: prevent stdout maxBuffer crash on large/LFS repo sync by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/59
* [HIVE-167] Setup CI job to sync external repos with MemVec on release by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/45
* fix(gateway): :bug: bind HTTP listener before warmup to stop 502/unhealthy on restart by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/66
* feat(topology): :sparkles: co-located T2 wiring for gRPC query + RMQ ingest (HIVE-152/153) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/67
* [HIVE-202] Rework how Hives reference data sources by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/71
* [HIVE-146] implement `@logilica/scheduler-core` package by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/69
* fix(chunker): resolve docling bridge script path in Docker (PDF uploads stuck) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/73
* feat(frontend): :sparkles: add branded 404 error page (HIVE-165) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/68
* fix(gateway): restore dropped project-dashboard routes and harden /api no-match handling by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/77
* [HIVE-227] enforce eslint gate and fix all violations by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/75
* [HIVE-200] Formalize common store/embeddings/chunker/ingest-worker/query-worker as @neohive/* packages by @azchu in https://github.com/NeoHiveAI/MemVec/pull/60
* [HIVE-200] Extract ingestion pipeline + sources as @neohive/ingestion by @azchu in https://github.com/NeoHiveAI/MemVec/pull/70
* [HIVE-226] Scheduler: recurring runs don't record real run status (last_run_status hardcoded 'success', failures unrecorded) by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/76
* proper include paths for packages by @deanmcgregor in https://github.com/NeoHiveAI/MemVec/pull/80
* feat(embeddings): add EmbeddingGemma 300M (markdown + code modes) by @MannyKv in https://github.com/NeoHiveAI/MemVec/pull/81
* [HIVE-232] Fix flaky GGUF model download: concurrent cold-cache downloads race on a shared temp path  by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/79
* [HIVE-225] Introduce a first-class Connection model for data sources by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/78
* [HIVE-204] Define NeoHive data models for Activity by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/74
* fix(retrieval): single-hive queries embed with the hive's own model (HIVE-262) by @MannyKv in https://github.com/NeoHiveAI/MemVec/pull/88
* fix(telemetry): :bug: re-wire per-hive inventory gauges into single-process gateway by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/84
* fix(ingestion): :wrench: block binary build artifacts by default by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/89
* fix(v1.6): :bug: restore dashboard stats, hive on-disk size, and container-aware embedder budget by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/64
* fix(metrics): :bug: restore MCP/sync/embedder OTel recording + per-project queries_30d by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/92
* ci: replace semantic-release repo by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/93
* [HIVE-287] Add Headway release notes widget by @azchu in https://github.com/NeoHiveAI/MemVec/pull/91

## New Contributors
* @azchu made their first contribution in https://github.com/NeoHiveAI/MemVec/pull/60
* @MannyKv made their first contribution in https://github.com/NeoHiveAI/MemVec/pull/81

**Full Changelog**: https://github.com/NeoHiveAI/MemVec/compare/v1.5.0...v1.6.0


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
