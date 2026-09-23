## v1.7.0 (2026-09-22)

## What's Changed
* fix(gateway): :bug: repair vestigial hiveminds.port column on upgraded DBs by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/95
* fix(sync): repair downstream PR creation, restore src parity, and adopt always-PR delivery by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/94
* fix(frontend): :bug: 1.6 FE bug-fixing pass (hive move UI + sync queue labels) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/97
* [HIVE-205] Integrate import logic and scheduling for activity data by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/86
* [HIVE-237] F1 - Session-state file + recall-signal stamping by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/90
* fix(scheduler): :bug: remove orphaned git-sync schedules on hive delete (HIVE-291) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/99
* fix(chunker): :bug: guard oversized code files from CodeSplitter timeout (HIVE-302) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/106
* Sync downstream plugins to v1.6.3 and adopt Codex marketplace layout by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/105
* sync reliability: branch auto-detect/recovery + scheduler overlap guard (HIVE-318, HIVE-319) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/110
* fix(installer): :bug: resolve arm64 versioned image tags, clarify pull failures by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/104
* refactor: 💅🏽 Improve project and hive UI/UX for connecting data sources by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/108
* fix(commit-import): stop passing --since=@0 to git log (flaky Full Tests) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/109
* feat(embeddings): per-model pooling + Qwen3-Embedding-4B (HIVE-234) by @MannyKv in https://github.com/NeoHiveAI/MemVec/pull/87
* Add NeoHive backlink blurb to README by @YEADOS in https://github.com/NeoHiveAI/MemVec/pull/101
* fix: correct licence banner visibility logic and banner dark mode colour by @YEADOS in https://github.com/NeoHiveAI/MemVec/pull/113
* feat(embeddings): :sparkles: Zero-touch native Metal embedding on Apple Silicon (+ ship proto in image) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/102
* fix(embeddings): :bug: bound embedder onboarding + surface remote-worker download progress (HIVE-323) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/114
* feat(migrations): migration safety — snapshot before migrate, auto-rollback, refuse-to-start [HIVE-213] by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/83
* HIVE-354: metal query-worker auto-deploy from main + auto-heal watchdog by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/121
* Batch LanceDB vector writes during indexing (HIVE-321) by @MannyKv in https://github.com/NeoHiveAI/MemVec/pull/115
* fix(ingestion): :bug: cap ingest embed batch size to avoid wedging the shared worker by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/127
* feat(embeddings): :sparkles: add Qwen3-Embedding-0.6B (last-token); deprecate Qwen3-Embedding-4B by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/126
* fix(metal-worker): :ambulance: actually install the auto-heal watchdog (HIVE-382) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/128
* fix(ci): :bug: authenticate the metal-worker pnpm install to the private registry (HIVE-382) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/130
* fix: Add-a-hive, onboarding, and project-management fixes by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/117
* ci: report build timings in the Slack notifications by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/138
* fix(chunker): unpinned Docling auto-upgrade broke PDFs, force eager backend by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/146
* [HIVE-358] Organise the test suite by level (rename, tag, wire Vitest projects) by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/131
* ci: collapse a PR stack into one Slack notification by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/139
* chore(bench): :bar_chart: LanceDB ingest + write benchmark harnesses (HIVE-357) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/123
* [HIVE-361] Implement the Fast feedback gate (on push) by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/141
* [HIVE-362] Implement the merge gate (pre-merge) by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/143
* fix(ci): notify a stacked PR on its own message when the stack has none by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/153
* fix(ci): scope the traceability gate to product source by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/157
* [HIVE-369] Fill Connections and Credentials test gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/160
* [HIVE-371] Fill Sync Engine test gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/161
* [HIVE-402] CI job to manually branch from `main` as first Release Candidate by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/148
* [HIVE-370] Fill Licensing test gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/163
* [HIVE-365] Fill Embedding Retrieval unit test gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/164
* [HIVE-419] Typecheck test sources by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/165
* fix(stats): :bug: include vector bytes in hive on-disk total by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/125
* fix(re-embed): :bug: bound producer concurrency to the worker, not the host CPU count (HIVE-383) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/129
* feat(embeddings): :sparkles: progress-based embed staleness (HIVE-394 P1) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/132
* fix(embeddings): :bug: GGUF model download resilience (retry + backoff) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/112
* fix(embeddings): :bug: stop one failed embed from wedging the shared gRPC stream (HIVE-396) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/178
* [HIVE-317] Rename Projects to Hives, Hives to Index by @azchu in https://github.com/NeoHiveAI/MemVec/pull/119
* [HIVE-416] Redirect /projects/* links and enforce Hive/Index casing by @azchu in https://github.com/NeoHiveAI/MemVec/pull/166
* [HIVE-419] Type connection secret columns as ArrayBuffer by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/173
* [HIVE-368] Fill MCP tools test gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/159
* [HIVE-364] Fill Auth and access control test gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/158
* [HIVE-404] Make sure hotfixes follow the Release Candidate process by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/150
* fix(ci): give a PR stack one Slack message however the stack was formed by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/175
* ci: implement exemption logic for coverage gate by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/181
* [HIVE-403] CI job to promote latest release candidate as the public release by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/152
* [HIVE-407] Block publish while any gate-found fix's main-bound PR is open by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/154
* [HIVE-317] Sweep docs for Hive/Index vocabulary by @azchu in https://github.com/NeoHiveAI/MemVec/pull/179
* fix(embeddings): :bug: reuse the gRPC channel across self-heals (HIVE-436) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/184
* fix(ingestion): :bug: stop binary files reaching the embedder (HIVE-397) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/183
* refactor(gateway): :recycle: derive ingest routing from the query worker; remove MEMVEC_INGEST_WORKER_HOST/PORT (HIVE-395) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/133
* fix(re-embed): auto-recover corrupt Lance vector store + batch re-embed writes (backport of #189) by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/190
* fix(retrieval): :bug: keep match quality through the multi-query merge by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/168
* ci: add new "cosmetic" check step in Traceability gate by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/180
* fix(retrieval): :bug: rank cross-hive results by real match quality by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/169
* [HIVE-372] Fill Hive and Index test gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/186
* fix(retrieval): :bug: make per-hive diversity a floor, not a share by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/170
* test(retrieval): :white_check_mark: cover cross-hive relevance, not just shape by @Nader-Awad in https://github.com/NeoHiveAI/MemVec/pull/171
* [HIVE-367] Fill Platform and Deploy test gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/187
* [HIVE-442][HIVE-443][HIVE-444][HIVE-445][HIVE-446][HIVE-447] Close P0 coverage gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/192
* [HIVE-440] [HIVE-441] P0 coverage remaining embedding retrieval engine by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/194
* [HIVE-366] Fill Frontend Dashboard test gaps by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/188
* [HIVE-363] Implement QA check during candidate and promotion Release CI gates by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/191
* ci: script to install neohive rc for manual testing by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/197
* [HIVE-401] Implement QA check for patch Release CI gates  by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/193
* ci: automate qa gate dispatch (automating HIVE-363 and HIVE-401) by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/198
* ci: update pr slack notifier to handle `assignee` as another `reviewer` field by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/199
* [HIVE-449] Restrict candidate cut to only `main` branch by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/200
* rc-fix: Handle silent failures in candidate build (release/v1.7) by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/203
* rc-fix: Stop the rust cache from deleting rustup on the metal runner (release/v1.7) by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/205
* rc-fix: Fix QA gate failures and post verdict to slack (release/v1.7) by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/207
* rc-fix: Fix the GPU (vulkan) embedder failing to start in the release image (release/v1.7) by @Rgonzales4 in https://github.com/NeoHiveAI/MemVec/pull/209


**Full Changelog**: https://github.com/NeoHiveAI/MemVec/compare/v1.6.0...v1.7.0


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
