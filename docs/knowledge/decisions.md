# Val Ark — Decisions & Progress Log

Architecturally significant decisions and notable progress, newest first. Format:
**context → decision → why.** Append when you make a call worth remembering (or reversing
later). See [README](README.md).

## Index

> Newest first, mirroring the body order. **Append new decisions at the top of the body and add a
> matching row at the top of this table.**

| Date | Decision | Issue / Phase |
|------|----------|---------------|
| 2026‑11 | [cad-agent references: a private, content-addressed archive of every cited source](#202611--cad-agent-references-a-private-content-addressed-archive-of-every-cited-source-cad-agent323) | cad-agent#323 |
| 2026‑11 | [Python wheelhouses + container archives as tool artifacts](#202611--python-wheelhouses--container-archives-as-tool-artifacts-149) | #149 |
| 2026‑07 | [CI guards: doc-link integrity + secret/host-leak scan](#202607--ci-guards-doc-link-integrity--secrethost-leak-scan-130) | #130 |
| 2026‑07 | ["Ask Val Ark": an offline ask endpoint reusing the moderation runtime](#202607--ask-val-ark-slice-1-an-offline-ask-endpoint-that-reuses-the-moderation-runtime-phase-8-67) | Phase 8 · #67 |
| 2026‑07 | [Four‑tab consumer nav: Home · Library · Activity · Settings](#202607--fourtab-consumer-nav-home--library--activity--settings-61--epic-91-slice-1) | #61 · epic #91 |
| 2026‑07 | [Packages manifest: `/api/packages` = present inventory, not the catalog](#202607--packages-manifest-served-apipackages--present-inventory-not-the-catalog-89-slice-1) | #89 |
| 2026‑07 | [Release tags: unprefixed 0.x, minted by release.sh from VERSION](#202607--release-tags-unprefixed-0x-minted-by-releasesh-from-the-version-file-64) | #64 |
| 2026‑07 | [Safety card ships without "restore"; review is remove/dismiss only](#202607--safety-card-ships-without-restore-review-is-removedismiss-only-phase-7-4n) | Phase 7 (4/n) |
| 2026‑07 | [Moderation ENFORCEMENT is a post-store loop sweep](#202607--moderation-enforcement-is-a-post-store-loop-sweep-phase-7-3n) | Phase 7 (3/n) |
| 2026‑07 | [Community chat is open (no-login) by default](#202607--community-chat-is-open-no-login-by-default) | — |
| 2026‑07 | [Versioning re-baselined to honest pre‑1.0 (0.1.x)](#202607--versioning-re-baselined-to-honest-pre10-01x) | — |
| 2026‑07 | [Reframe to a consumer appliance (scope‑first)](#202607--reframe-to-a-consumer-appliance-scopefirst) | — |
| 2026‑07 | [Live host metrics, live-first](#202607--live-host-metrics-live-first-roadmap-phase-6-part-2--monitoring) | Phase 6 (pt 2) |
| 2026‑07 | [On-device moderation: fail-closed decision core first](#202607--on-device-moderation-fail-closed-decision-core-first-phase-7) | Phase 7 |
| 2026‑07 | [Metrics HISTORY is a zero-dep ring buffer](#202607--metrics-history-is-a-zero-dep-ring-buffer-phase-6b-part-2) | Phase 6b (pt 2) |
| 2026‑07 | [Health & Repairs page](#202607--health--repairs-page-roadmap-phase-6-part-1--self-heal-ux) | Phase 6 (pt 1) |
| 2026‑07 | [Download queue as the monitoring surface](#202607--download-queue-as-the-monitoring-surface-roadmap-phase-5-part-1) | Phase 5 (pt 1) |
| 2026‑07 | [Access-mode enforcement + admin sessions](#202607--access-mode-enforcement--admin-sessions-roadmap-phase-2-depth) | Phase 2 depth |
| 2026‑07 | [Consumer shell: Home status + Settings + Activity](#202607--consumer-shell-home-status--settings--activity-roadmap-phase-3-issue-12) | Phase 3 · #12 |
| 2026‑07 | [First‑boot commissioning wizard](#202607--firstboot-commissioning-wizard-roadmap-phase-1-issue-11) | Phase 1 · #11 |
| 2026‑07 | [Access identity + recovery foundation](#202607--access-identity--recovery-foundation-roadmap-phase-2-issue-10) | Phase 2 · #10 |
| 2026‑07 | [First `dev → main` release (v1.1.0) + community sign‑ups](#202607--first-dev--main-release-v110--community-signups-pr-23) | PR #2/#3 |
| 2026‑07 | [Feature branch: discover/request + self‑replication + tests](#202607--feature-branch-discoverrequest--selfreplication--tests-pr-1) | PR #1 |
| — | [Earlier project facts (fleet, curation)](#earlier-project-facts-fleet-curation) | — |
| 2026‑07 | [Notification center: bell/inbox slice 1](#202607--notification-center-bellinbox-slice-1-69) | #69 |

---

## 2026‑11 — cad-agent references: a private, content-addressed archive of every cited source (cad-agent#323)
- **Context:** cad-agent keeps a reference knowledge base of ~760 sources (≈330 GitHub repos, ≈350
  pages, ≈70 PDFs, a few books) and publishes it as JSON beside its site
  (`catalog/references/index.json`, `records.json`, `<area>.json`). The owner, 2026-11-04: *"the
  resources were for cad-agent to provide references for designs and also to mine in the future, of
  course val-ark would back them up as well and clone them."*
- **Decision:** `scripts/tools/cad-agent-references.sh` + `scripts/lib/references_mirror.py` read that
  index (the Ark keeps no URL list of its own) and archive **every** source, whatever its licence:
  repos as full-history `git bundle`s (every branch and tag, no size cap by default; `--max-repo-mb`
  for small disks keeps a pointer only), pages as one self-contained HTML file via **monolith**
  (Y2Z/monolith, CC0; raw HTML when it is missing), PDFs and other files as served. Blobs are
  content-addressed, `manifest.jsonl` is an append-only log, and `by-id/<id>.<ext>` is the stable path
  from a record id to its latest copy. The work is ordered by `planner.py` (value: evidence class and
  cited status); the budget (`valark_budget_bytes`) is enforced on bytes actually written, checked
  before each item and after each fetch, and the run stops cleanly when it is reached.
- **Opt-in, run by hand.** `download-tools.sh all` (the loop's weekly refresh, `start.sh` "download
  all") and the web UI's one-click tool requests leave it out: the first pass is ~37 GB and can take a
  day. Run `scripts/tools/cad-agent-references.sh` directly (detached, e.g. `nohup … &`), not through
  `download-tools.sh`, which would hold the tool lock for the whole pass. It resumes per item, so re-run
  it after an interruption and now and then to re-check (copies older than 30 days are re-checked).
- **One bad item never stops a run:** anything an item raises (a malformed URL, a git or monolith
  timeout, a monolith that cannot execute) is recorded as `failed` and retried after `--retry-hours`
  (24); a monolith failure falls back to raw HTML. A body shorter than its `Content-Length` is never
  stored. robots.txt is honoured; 5xx or no answer counts as disallow (RFC 9309).
- **Politeness, precisely:** the module spaces its own requests (index, robots.txt, each page or file,
  the GitHub API) at least 1 s apart per host. monolith's asset fetches for a page, redirect hops and
  git traffic are not throttled by it.
- **`redistribute` governs serving, never keeping.** It is `true` only for the `open` and
  `share-alike` licence classes; `non-commercial`, `unclear`, `proprietary` and `unrecorded` copies are
  archived with `redistribute: false`. So the store lives in `$VALARK_HOME/private/`, which `server.js`
  never serves (its static and `/api/archive/` trees are tools/models/content/sources/assets/installers/docs),
  and it counts in the footprint (`valark_data_used_bytes`). A future UI may serve the `true` copies.
- **Adopt, don't build:** `git bundle` (restorable with `git clone`, checkable with `git bundle
  verify`), monolith for pages, the librarian's planner for ordering. ArchiveBox / browsertrix (WARC,
  JS-heavy pages) stay an optional later path; lychee belongs in cad-agent's link checker, not here.
- **Size (dry run, 2026-11-04, cad-agent dev index, repo sizes from the GitHub API):** ≈ 37 GiB in all,
  ≈ 36 GiB of it repos (the largest 6.8 GiB); pages and PDFs ≈ 1 GiB at 2–3 MB each.
- **Why:** one source of truth (cad-agent's index), a store a later tool can walk with no network,
  and dedup for free (two records of one repo or one PDF share a blob).

### The manifest (`manifest.jsonl`, schema `val-ark/cad-agent-references-manifest/1`)

One JSON object per line, one line per fetch outcome, appended (one `write()` per line) and never
rewritten. A torn last line (a write cut short) is skipped by readers and dropped by the next mirror run.
An item the budget stops is not recorded (it is simply fetched by a later run). The **latest line of
an id whose `status` is `archived`, `unchanged` or `relabelled`** names its current copy; a later
`gone` or `blocked` line never removes it (`references_mirror.py latest` prints exactly those). cad-agent's
phase 6 (`tools/references_archive.py`) copies `sha256`, `kind`, `fetched` and `redistribute` into each
record's `archive:` block, and never a path or host.

| Field | On | Meaning |
|---|---|---|
| `v` | all | `1` |
| `id` | all | cad-agent record id (`^[a-z0-9][a-z0-9._-]*$`; others are rejected, never written) |
| `url` | all | the record's URL as published (`null` for a book) |
| `method` | all | `git` \| `page` \| `pdf` \| `none`: how it was classified from the URL |
| `status` | all | `archived` (copy made; may equal an earlier blob) \| `unchanged` (re-check found the same refs or HTTP 304; same blob) \| `relabelled` (licence changed, no fetch; same blob, `fetched` of the copy, plus `relabelled` time) \| `too-large` (pointer only) \| `no-url` \| `blocked` (401/403/429/451, or robots.txt disallows, refuses or is unreachable) \| `gone` (404/410, repo not found) \| `failed` (anything else, incl. a truncated body or a timeout; retried after `--retry-hours`) |
| `fetched` | all | UTC `YYYY-MM-DDTHH:MM:SSZ` of the fetch that made the copy |
| `record_kind` | all | cad-agent's `kind` (project, guide, datasheet …) |
| `licence_class`, `licence_read` | all | as published; `unrecorded` when the record has none |
| `redistribute` | all | `true` only for `open` and `share-alike`: may the Ark serve this copy |
| `index_revision` | all | cad-agent commit the index was built from |
| `kind` | copies | `git-bundle` \| `html` \| `pdf` \| `file` |
| `sha256`, `bytes` | copies | of the stored blob |
| `blob` | copies | `blobs/<sha256[:2]>/<sha256>.<ext>`, relative to the store |
| `link` | copies | `by-id/<id>.<ext>`, relative symlink to the blob |
| `tool` | copies | `git <version>` \| `monolith` \| `raw-html` \| `urllib` |
| `remote` | git | the clone URL |
| `commit`, `ref`, `refs`, `lfs` | git | HEAD commit, its branch, number of branches+tags, whether `.gitattributes` uses LFS (LFS objects are not fetched) |
| `repo_kb` | git | size the host reports (GitHub API), when known |
| `http_status`, `final_url`, `etag`, `last_modified`, `content_type` | http | as served (`final_url` only after a redirect) |
| `cap_mb`, `error`, `retry_after`, `monolith_error` | some | why a copy was not made, or fell back |

## 2026‑11 — Python wheelhouses + container archives as tool artifacts (#149)
- **Context:** cad-agent (CAD/FEA/CFD toolkit) needs ~100 Python wheels, an OpenFOAM container
  image, and on aarch64 two libraries PyPI has no wheel for (gmsh, pyamg). The catalog only knew
  binaries, archives, source clones and install hints; a full PyPI mirror is rejected (42 TB).
- **Decision:** one tool entry, `scripts/tools/cad-agent.sh`, is the whole bundle. A per-platform
  **wheelhouse** (`pip download --platform … --only-binary=:all:` from a throwaway venv, so one host
  fills every platform and nothing is installed on the box) covers the core package and every
  extra; linux-arm64 adds a **conda-forge explicit set + static micromamba**, because PyPI has no
  aarch64 gmsh/pyamg; the
  OpenFOAM image is a **`docker load` archive** pulled by the new stdlib `scripts/lib/oci_pull.py`.
  `install.sh` per platform builds the environment with `pip --no-index`; `verify.sh` installs the
  core package offline each cycle. Wheels target CPython 3.12 (the mirrored python-standalone) and
  glibc ≤ 2.31 (`VALARK_CADAGENT_GLIBC`), the oldest fleet host.
- **arm64 is conda-native, not a mix.** Measured on the NAS (glibc 2.31): adding just conda's
  gmsh to a pip env fails, conda's numpy needs `GLIBCXX_3.4.29` after a pip wheel already bound
  the host's libstdc++, and conda's pyexpat then meets the host's libexpat. So the env is conda's
  Python (its own libexpat) with gmsh, pyamg and the numeric stack (numpy/scipy, mujoco, numba …)
  from conda, and a `.pth` preloads the env's libstdc++, libexpat and zlib before any manylinux wheel loads (the
  wheels' system GL/X11 chain otherwise binds the host's older libexpat first and breaks pyexpat).
- **…but the CAD kernel stays on PyPI.** conda-forge's `ocp` 7.9.3.1 binds OCCT static methods
  without the `_s` suffix (`TopoDS.Solid`, not `TopoDS.Solid_s`); cad-agent calls the PyPI form, and
  ~180 of its tests failed on the NAS with a conda OCP. So cadquery, cadquery-ocp, vtk and pyvista
  come from the wheelhouse, `occt` is pinned to its no-VTK build (gmsh needs it), and the fill fails
  if the solve ever pulls `ocp`/`vtk`/`cadquery`/`pyvista` (`CONDA_ARM64_FORBID`). pip adds what
  conda lacks plus its wheel deps (`conda/pip-wheels.txt`, followed through wheel METADATA).
- **cad-agent's `fea` extra cannot resolve off x86_64** (pypardiso→MKL, no marker; reported upstream
  as Valpatel/cad-agent#285), so `install.sh` installs the platform-filtered `requirements.txt` and
  then cad-agent `--no-deps`.
- **Why:** curated, per-project wheelhouses are small (≈0.5–1 GB per platform) and prove an offline
  install end to end, where a generic PyPI cache would not. A new cad-agent release replaces only
  the wheelhouse; the image (digest stamp) and conda packages (md5) are kept.

## 2026‑07 — CI guards: doc-link integrity + secret/host-leak scan (#130)

**Context:** the #129 doc-hierarchy cleanup surfaced two defect classes CI never caught — a real
host name committed in `tests/README.md` (scrubbed in #129), and nothing verifying the `.md`
internal links/anchors actually resolve. **Decision:** add two OFFLINE `test-*.sh` validators
(`test-doc-links.sh` + `test-secrets.sh`, backed by `tests/lib/{md_link_check,secret_scan}.py` and a
reviewed `tests/lib/secrets-allowlist.txt`) that gate in CI **and** locally, and run them as a
fail-fast CI step BEFORE the Playwright browser install. **Why:** doc rot and secret leaks are cheap
to catch mechanically and expensive to catch by eye (the #129 review had to hand-build a link
resolver); a public repo must never ship a real host/IP/credential. The scan is a ratchet — it fails
any NEW leak while allowlisting the handful of reviewed examples/constants/fixtures; public dotted
domains, loopback, and `$`/`{}`/`<>` placeholders pass automatically.

## 2026‑07 — "Ask Val Ark" slice 1: an offline ask endpoint that reuses the moderation runtime (Phase 8, #67)

- **Context:** Phase 8's core affordance is a "Ask Val Ark" helper backed by the box's OWN small
  chat model. Every building block already existed — curated assistant models
  (`data/models-extra.tsv` kind=`assistant`, land in `models/assistant/…`), the mirrored
  llama.cpp runtime, and a PROVEN single-shot invocation (`verify.sh:104`, `moderation.sh`
  `_mod_run_text`) — but nothing wired the box to answer "how do I…" anywhere in the UI.
- **Decision (this slice — minimal, offline, zero-dep):** two endpoints in `scripts/server.js` +
  a Home card. **`GET /api/status/ask`** → `{ready, runtime, model, reason, modelId}` (pure
  presence checks, NO inference; read-gated for free by the `/api/status/` prefix). **`POST
  /api/ask` `{question, context?}`** streams the answer as **SSE frames** (`event: token|soft|
  error|done`, JSON-encoded `data` so newlines never break framing) — a per-request stream, NOT
  the shared `sseClients` broadcast pool. Runtime reuse is exact: resolve `llama-completion`
  (fallback `llama-cli`) by NAME under `tools/<platform>/llama-cpp` (the `_mod_find_bin` /
  `findKiwixServe` pattern; `VALARK_TOOLS_DIR`-overridable) and the smallest `.gguf` > 10 MB under
  `models/{assistant,llm}` (verify.sh's filter, assistant preferred). Invocation is the proven
  single-shot argv `-m … -p <prompt> -n 256 -st -no-cnv --no-warmup --no-display-prompt --temp 0`.
- **Why streaming, when the issue listed SSE as out-of-scope:** the worker task direction asked for
  token-visible streaming; a single-shot `llama-cli` already emits tokens to stdout as it decodes,
  so we stream **its stdout** — no persistent `llama-server` daemon (that stays out of scope). The
  UI reads the stream with a `fetch()` + `ReadableStream` reader (EventSource can't POST) and a
  tiny SSE frame parser; every token is rendered via `textContent` (auto-escaped — XSS-safe).
- **Security posture (the whole point):** the user's `question` is DATA in ONE `-p` argv element —
  `spawn(bin, argvArray)`, **never** a shell string / `sh -c`. Defence in depth: control-char
  strip + 2000-char cap on the question (600 on context), `-n` token cap (hard max 1024), a
  wall-clock `setTimeout`→`SIGKILL` backstop, a memory guard (`os.freemem()` vs model size) to
  avoid OOM-killing community services, and an **admission cap** (`ASK_MAX_CONCURRENT`, default 2)
  that 503s over-budget — mirroring the moderation/#62 in-flight cap so a burst can't fan out
  unbounded 1–2 GB model loads.
- **FAIL-SOFT (hard requirement):** the ARM64 appliance ships a llama.cpp SOURCE clone only, so a
  bare box may have no binary and/or no model. Every such path returns **HTTP 200** with a friendly
  `event: soft {reason: runtime|model|memory|empty}` (Home shows a one-click "Get the helper" that
  fires the existing `POST /api/request {kind:'model', id:'qwen2.5-1.5b-instruct-gguf'}`), NEVER a
  5xx, and never crashes the event loop. `VALARK_TEST_NO_SPAWN=1` returns a deterministic stub
  answer AFTER the soft checks, so the Playwright suite never triggers a real model load while a
  bare CI box still exercises the soft path; the offline bash validator leaves it UNSET to drive
  the REAL spawn against a stub binary (proving the argv-array/no-shell contract).
- **Deferred (later #67 slices):** doc-grounding/RAG over the bundled Linux docs + ZIM,
  per-page context beyond Home, embed-everywhere, the "apply-the-fix" button, and — if single-shot
  cold-load latency proves too slow on the appliance — a lazily-started persistent `llama-server`.

## 2026‑07 — Four‑tab consumer nav: Home · Library · Activity · Settings (#61 / epic #91 slice 1)

- **Context:** the top nav had SEVEN links (Home, Software, Models, Library, Community, Settings,
  Getting Started). The easy‑consumer‑UI roadmap ("cap it at four tabs") wants a calm top bar.
- **Decision (this slice — NAV SHELL only, no page internals redesigned):** reduce the top bar to
  exactly four — **Home** (`#/`), **Library** (`#/content`), **Activity** (`#/activity`, surfaced
  in the top nav for the first time), **Settings** (`#/settings`). The three former browse links
  (Software `#/tools`, Models `#/models`, Content `#/content`) **plus** Downloads (`#/packages`)
  now live UNDER the Library tab via an in‑page **segmented sub‑nav** (`renderLibraryNav(active)` →
  `.library-nav`/`.lib-tab`, one real deep link per surface). `activeSection` maps
  tools/models/content/library/packages → `library` (Library tab highlights on all of them),
  activity/health → `activity`, settings → `settings`. Community & Getting Started **leave the top
  bar but stay reachable** — Community via the Home hub card + a new footer link; Getting Started
  via the footer + hero CTA. **No route changed:** `#/tools`, `#/models`, `#/content`, `#/library`
  (alias), `#/community`, `#/quickstart`, `#/packages`, `#/health`, `#/tools/<id>` all still
  deep‑link exactly as before.
- **Why a sub‑nav, not a new landing page:** the roadmap said "pick the simplest coherent pattern."
  A sub‑nav adds ZERO new routes and touches only the four list pages' top‑of‑body — the Library
  tab points at the existing `#/content` ("Offline Library") default and the peers are one click
  away. A new `#/library` landing would be page‑internals work this slice explicitly excluded.
- **Gotchas for the next slice:** (1) the mobile hamburger reuses the SAME `.nav-links` DOM, so
  four tabs there is automatic — no separate mobile list to keep in sync. (2) Playwright tests that
  navigated via `page.click('a.nav-link:has-text("Software"|"Models"|"Getting Started"|"Community")')`
  BREAK — those top links are gone. Fixed with an `openLibrarySection(page, sub)` helper (click
  Library tab → click sub‑tab) and footer clicks for Community/Getting Started; the sub‑nav uses
  `.lib-tab` (never `.nav-link`) so `:has-text("Library")` still resolves to exactly the one top
  tab. (3) On a <480px viewport `.nav-link` is `display:none` until the hamburger opens — wait for
  `.nav-hamburger`, not a visible nav link. New `tests/screenshots/specs/nav.spec.ts` (27 tests)
  locks all of this in. Later #91 slices: Home one‑status‑light polish, Basic/Expert Settings,
  Ask Val Ark (#67).

## 2026‑07 — Packages manifest: served `/api/packages` = present inventory, not the catalog (#89 slice 1)

- **Context:** the box already serves individual downloads (per‑platform app archives via
  `/api/archive/`, the self‑replication bundle/tarball via `/sources/val-ark/`, ZIMs via kiwix) but
  had no consolidated, machine‑ + human‑readable **packages list**. Epic #89 wants a versioned,
  checksummed package set + a manifest the UI renders as a "downloads" list.
- **Decision (this slice):** add a read‑gated `GET /api/packages` that enumerates what THIS box can
  hand out **right now** — app/tool archives (per platform, version from `.version` markers), the
  self‑replication source bundle/tarball/node runtimes (version from the mirror's `VERSION`, sha256
  from a `SHA256SUMS`), on‑disk models, and complete ZIMs — each with a stable `id`, `name`, `kind`
  (app|source|model|content), `platform`, `version`, `size`, optional `sha256`, `desc`, and a
  **relative** `url`. Plus a minimal "Downloads" page (`#/packages`) that renders it. Deferred to
  later slices: wiring artifacts into the CI/CD release + attaching the manifest to the GH Release.
- **Why this shape:** it is deliberately DISTINCT from `/api/catalog/*` (the *upstream, not‑yet‑
  downloaded* browse feed that one‑click `POST /api/request` pulls). `/api/packages` is the *present
  inventory* — no network, no eviction, just "what's on disk to grab." Keeping URLs relative +
  metadata‑only preserves the public‑repo / LAN‑only posture (no host paths or absolute URLs ever
  cross the boundary); reusing the existing read‑gate keeps the same access posture as the library
  it lists; hashing at mirror time (not per request) keeps the endpoint fast on a multi‑GB box.

## 2026‑07 — Release tags: unprefixed 0.x, minted by release.sh from the VERSION file (#64)

- **Context:** the shipped series is **unprefixed** (`0.1.7`, `0.1.8`, `0.1.9`), created by hand
  because `scripts/release.sh` still minted `vX.Y.Z` tags, never read the `VERSION` file, and its
  clean‑tree check used to trip on untracked local files. A single stray v‑tag would permanently
  outrank every unprefixed tag under version sort (`v0.1.10` > `0.2.0`), silently corrupting any
  "latest tag" logic; and a tag could ship while `/api/health` still served the old version.
- **Decision:** the canonical tag scheme is the **unprefixed `X.Y.Z`** the series already uses —
  shipped tags stay as‑is, no renormalizing. `release.sh` now derives the tag from the repo‑root
  `VERSION` file (no argument needed; an explicit argument must match it, leading `v` stripped,
  never minted), only blocks on uncommitted **tracked** changes (untracked cruft can't change what
  a tag of HEAD captures), refuses a double release under either prefix, and computes the
  changelog baseline via `git describe --tags --abbrev=0` (nearest **ancestor** tag) instead of
  the highest version‑sorted tag repo‑wide. `.github/workflows/release.yml` now also triggers on
  unprefixed tags (it only knew `v*.*.*`, so it never fired for 0.1.7–0.1.9) with the same
  ancestor‑tag baseline. Validated offline by `tests/test-release.sh` against scratch repos.
- **Why:** one source of truth (`VERSION` → tag → `/api/health`) and one tag scheme make "cut a
  release" a no‑judgment operation: bump `VERSION` in the release commit, merge to `main`, run
  `scripts/release.sh --push` on main's tip. The old `.memsearch/` clean‑tree workaround is
  obsolete (gitignored since ce214a7) — use the helper, not manual `git tag`.

## 2026‑07 — Safety card ships without "restore"; review is remove/dismiss only (Phase 7, 4/n)

- **Context:** the admin Safety card's review queue needs actions on held items. The natural
  set is remove (delete) / restore (release a false positive back to its store) / dismiss
  (acknowledge, keep quarantined). An adversarial review of the endpoints flagged that
  **restore is the entire risky surface** (4 of 5 findings, incl. a HIGH): its destination is
  `item.path` read from `queue.jsonl`, an append-only log living in the in-`<state>` tree that
  this project's OWN threat model treats as attacker-writable (a same-uid service or an
  NFS-mesh peer). An unconfined write-back is an arbitrary-file-write → RCE-if-root
  confused-deputy (admin clicks "Approve" → server writes attacker bytes to e.g. `/etc/cron.d`),
  plus a TOCTOU symlink-swap on the copy source that exfiltrates arbitrary readable files.
- **Decision:** **drop restore** for 4/n. The queue supports only **remove** (`unlinkSync` the
  quarantine entry — never follows a final symlink, basename-confined) and **dismiss** (append
  `reviewed.jsonl`, keep the file). Both are provably safe. A false positive is released on the
  box itself for now.
- **Why not just harden it:** doing restore safely needs the destination realpath-confined to an
  allowlist of the sweep's store roots (which the server would have to duplicate from
  `mod-sweep.sh` — a drift hazard) **and** an `O_NOFOLLOW` fd-based copy. That's a real feature,
  not a patch; better shipped deliberately later than rushed into a security-sensitive path. The
  fail-closed instinct applies to our OWN write-backs too: if we can't confine it simply, don't
  do it. Follow-up: store-root-confined + `O_NOFOLLOW` restore.

## 2026‑07 — Moderation ENFORCEMENT is a post-store loop sweep (Phase 7, 3/n)

- **Context:** the endpoints + settings (2/n) can screen content on request, but nothing on
  the box actually ran community content through them — so the Safety card's "screening" claim
  was hollow. Two ways to enforce: a **pre-store proxy intercept** (screen the POST body in
  `pipeProxy` before NodeBB/MicroBin stores it) or a **post-store sweep** (the self-heal loop
  screens already-stored files each cycle).
- **Decision:** post-store **file sweep** (`scripts/lib/mod-sweep.sh`, wired as `loop.sh` step
  7c). It walks configured community stores (paste files, mail, upload dirs — `VALARK_MODERATION_DIRS`
  overrides), screens each new file with `moderation.sh check`, and on any non-`allow` verdict
  **quarantines** the file (moves it out of the store) + appends a `state/moderation/queue.jsonl`
  review entry. Idempotent via a `screened.tsv` (path+size+mtime) marker; bounded per run; the
  admin's `action` (block/quarantine/flag) decides move-vs-copy. **Fail-closed:** an unparseable
  verdict, a classifier error, or node-unavailable settings all resolve to hold→quarantine, never
  "left served."
- **Why the sweep, not the intercept:** the pre-store intercept must parse each app's POST format
  (NodeBB CSRF/multipart, MicroBin forms) — fragile and app-coupled — and NodeBB's post store is
  **Redis**, not files. The sweep is app-agnostic, offline-testable with fixtures + a stub
  classifier (`test-mod-sweep.sh`, 16/0), and fits the loop's "reconcile reality each cycle"
  model. It's reactive (content is briefly visible before the next cycle) — an acceptable first
  cut; a NodeBB/Redis screener and a pre-store paste intercept are documented follow-ups.
- **CORRECTION (real-box investigation, 0.1.9 deploy):** the sweep must **NOT** target the
  community services' internal stores at all — they are **DB-backed**. MicroBin keeps text pastes
  in SQLite (`microbin.db` under `STATE_DIR/services/paste`); maddy keeps mail in an imapsql/bbolt
  store (`STATE_DIR/services/mail/maddy/`). The files on disk are referenced *from* a database, so
  the sweep's move-to-quarantine would **corrupt the store**, not screen it (and pastes/mail bodies
  often aren't standalone files). The original default paths (`services/paste/data`,
  `services/mail/messages`) were also just plain **wrong** (off by the real subdir), so the sweep
  was a harmless no-op on the real box — but "correcting" them would have caused corruption. So the
  sweep now screens **only** an explicit plain-file uploads area (`VAL_ARK_UPLOADS` /
  `VALARK_MODERATION_DIRS`), never a service store. Real per-service enforcement (paste/mail/forum)
  requires a **pre-store intercept or a service-native hook** — a deliberate follow-up, not a path
  tweak. This is the fail-closed instinct applied to integrity: don't let the safety mechanism
  itself break the thing it guards.

## 2026‑07 — Community chat is open (no-login) by default
- **Context:** on the real box a visitor opening `/app/chat/` hit The Lounge's **private-mode login
  wall with no way to create an account** (accounts were host-only, via `thelounge add`) — chat was
  effectively unusable without shell access. Plus ngIRCd's default `MaxNickLength=9` rejected
  ordinary names ("nickname too long"), and there was only one empty room.
- **Decision:** default chat to **public / no-login** (`VALARK_CHAT_PUBLIC=1`) — pick a nickname and
  join. Val Ark's reverse proxy + Use Mode already gate *who* reaches `/app/chat/`, so The Lounge
  needn't re-auth. Operators wanting per-user logins + persistent history set `VALARK_CHAT_PUBLIC=0`.
  Also: `MaxNickLength=30`, starter channels (`#valark #general #help #random`), a MOTD teaching
  `/list` + `/join`, an ark-themed leave message, and an idempotent start (real pid + port fallback).
- **Why:** the appliance principle is "it just works" — a trusted-LAN community box should let people
  in with zero friction, not gate casual chat behind account provisioning. `COMMUNITY_ACCOUNTS.chat`
  tracks the mode (`open`↔`host`) so the account panel and `adduser` stay correct either way.
- **Proven on the deployed ARM64 box** (not just CI): a 20-char nick registers, `/list` shows the
  channels, `/join` creates one, repeat `start` is a no-op. Real-box verification caught what the
  green test suite didn't — the login wall, the nick limit, the write-once config.

## 2026‑07 — Versioning re-baselined to honest pre‑1.0 (0.1.x)
- **Context:** early releases had jumped to a 1.x line (v1.0.0–v1.5.0), which implies a real,
  supported 1.0 user release we are nowhere near.
- **Decision:** we are **pre‑1.0**. Deleted the premature v1.0.0–v1.5.0 tags + GitHub releases
  (nobody depended on them) and re-baselined to **0.1.x**; the Phase 6 release (Health UX + live
  metrics) is **0.1.7**. The app version now has a single source of truth — the repo‑root
  `VERSION` file, read by `scripts/server.js` (`APP_VERSION`, served at `/api/health`).
- **Rule going forward:** stay on **0.x** until there's a genuine, stable 1.0 user release; **bump
  the `VERSION` file as part of each release** (the release-branch commit), so `/api/health` never
  goes stale again. Don't reach for 1.0 by increment — it's a deliberate "this is ready for real
  users" call.

## 2026‑07 — Reframe to a consumer appliance (scope‑first)
- **Context:** Val Ark was a power‑user/CLI tool; the goal is a router‑app / health‑app
  experience for a non‑technical owner ("one big EASY button").
- **Decision:** Scope the whole consumer experience *before* coding, as a cohesive 14‑doc
  hierarchy in [`docs/design/`](../design/README.md), grounded in a research sweep of 8
  comparable products ([research‑brief](../design/research-brief.md)). Implement per
  [roadmap](../design/roadmap.md); first sprint = **Commission + Recover**.
- **Why:** the surface area (commissioning, admin, access, recovery, storage, monitoring,
  moderation, deployment) is large and interdependent; getting the architecture right first
  avoids expensive rework.

### Key design calls (see the design docs for detail)
- **Access model:** operator chooses **Open (default) / Passworded / Accounts**; **two roles**
  (Admin + optional Viewer), never a usable default credential (only a one‑time claim token),
  **localhost/console always trusted as admin**. *Why:* a knowledge appliance's happy path is
  open‑on‑LAN; full RBAC is over‑engineering for the persona.
- **Recovery is paper‑backed + fully local:** a printed recovery card + two‑tier reset (button
  beeps / console menu / `valark setpassword`) + Safe Mode. *Why:* offline → no email reset;
  this is the single most important thing for "a box in a closet."
- **Content‑safety invariant:** the tiny `valark/state` (config) is physically separate from the
  multi‑TB content/model library; **no reset ever wipes Wikipedia/models** — only an explicit
  type‑the‑word disk‑erase does. *Why:* a panic reset must never re‑trigger a multi‑day download.
- **Storage is a growable pool:** primary (fixed, holds the brain) + add/remove drives (USB DAS),
  scaling to **SeaweedFS across computers**; track drives by UUID/label, graceful‑degrade on unplug.
- **Downloads:** disk‑sized **profiles** ("class roles") + **emphasis** (Knowledge/AI/Tools) drive
  curation weights + caps; "Fill everything (Recommended)" default.
- **On‑device moderation** (NPU) for shared uploads, default‑on, private, fail‑closed.
- **Deployment:** ship both a **Docker appliance image** *and* the bare‑metal bootstrap; both
  offline, both commissioned from the same wizard.

## 2026‑07 — Live host metrics, live-first (roadmap Phase 6, part 2 — monitoring)
- A scout→3-design→judge **workflow** weighed live-first vs stack-faithful vs MVP for the
  Telegraf+InfluxDB phase. Verdict: ship an **S-effort live-first MVP** and DEFER the whole
  named stack — because the zero-dep server can read `/proc` + `os` itself, so the Health
  page's **System tiles work day one on a bare box** (CI/VM, no services) and the retention
  layer becomes a pure enhancement, never a dependency.
- **This branch (`feat/metrics-live-gauges`):** one read-gated `GET /api/status/metrics`
  (`getHostMetrics()` — CPU%/mem/load/net-rate/temp/uptime + reused `getDiskStatus()`), a client
  `loadMetrics()` on the existing 15s Health cadence, a friendly **System tiles** strip + ONE
  additive `{key:'system'}` component card (informational: good/warn, `repair:null`, never red),
  and a **neutral "History: live-only"** indicator. NO new POST, NO service, NO secret, NO npm
  dep — so its adversarial surface is a pure local read (same class as `/api/status/disk`).
- **Why live-first beats stack-faithful here:** InfluxDB 2.x needs token-authed first-run setup
  (a real secret + onboarding dance); coupling the visible gauges to that daemon would make the
  Health strip blank whenever it's down. Live-first inverts it — always-on gauges, optional history.
- **Deferred to focused follow-up branches** (named precisely so they graft in additively):
  `scripts/services/{influxdb,telegraf}.sh` daemons + `telegraf.conf` (branch 2); a
  `GET /api/status/metrics/history` **InfluxDB passthrough** via a zero-dep `queryInflux()` —
  THE adversarial-review deliverable (injection/SSRF: never interpolate client range/metric into
  the Flux/URL, pin host to 127.0.0.1, `ECONNREFUSED → {influx:false}` at 200); `.env` token/URL
  keys (git-ignored / auto-minted to 0600 state, PUBLIC repo); `scripts/services/grafana.sh` at
  `/app/grafana/` under Advanced (branch 3); fleet aggregation + SSE metrics push (later).

## 2026‑07 — On-device moderation: fail-closed decision core first (Phase 7)
- A scout→3-design→judge **workflow** designed Phase 7 (screen user uploads with the box's own AI,
  offline). Key inversion it surfaced: **the model + inference is NOT the risky part** — text
  (llama-cli + the already-mirrored Llama-Guard-3-8B) and image (llama-mtmd-cli + moondream2/SmolVLM)
  run today via the exact `verify.sh` single-turn invocation. The **risky part is wiring to a
  surface**: pre-store multipart interception in the zero-dep proxy would replace pipeProxy's
  streaming `req.pipe`, break Range/resumability, risk OOM, add a hand-rolled multipart parser, and
  open a scan-vs-store TOCTOU. So that is **deferred**.
- **Branch order:** ship the fail-closed **decision core in isolation first** (`scripts/lib/moderation.sh`
  + `test-moderation.sh`), adversarial-review it, then wire surfaces. `moderation.sh check <file> --kind
  --sensitivity` → one JSON line + exit code (0 allow / 1 block / 2 hold); a pure `decide(signal,
  sensitivity)` unit; type by **magic bytes** (never the client extension/Content-Type; SVG screened as
  a script-bearing document); `VALARK_MODERATION_CMD` stub hook for tests.
- **FAIL-CLOSED is the invariant** (same class as the Safe-Mode `useMode` fix): absent binary/model,
  timeout, nonzero, unparseable stdout, or a NaN/out-of-range/unknown signal → **hold**, never a silent
  allow. The common bare-box/CI/VM case has no model → that IS the fail-closed path (needs no inference).
- **Deferred (own branches, each reviewed):** the real enforcement surfaces — a NodeBB post-store
  quarantine sweep (highest-risk: open self-registration, plain-file uploads, no proxy surgery) then a
  pre-store paste multipart intercept; the server endpoints (`/api/moderation/{check,queue,review}`,
  `/api/status/moderation`) + the admin Safety card + Sensitivity slider; and a dedicated NSFW **ONNX**
  head (Xenova/nsfw_image_detection) which needs a mirrored onnxruntime CLI/wheels — the mirrored ORT is
  library-only/CPU-only today. NPU (.rknn on RK3588/UT2) later.

## 2026‑07 — Metrics HISTORY is a zero-dep ring buffer (Phase 6b part 2)
- A scout→3-design→judge **workflow** pitted InfluxDB-v2-Flux vs InfluxDB-v1-InfluxQL vs a
  **zero-dep on-disk ring-buffer challenger**. The ring won (9/10): the server already produces
  every datapoint via `getHostMetrics()`, so it **samples itself** into a capped
  `state/metrics-history.jsonl` (~24h) and serves it at read-gated `GET /api/status/metrics/history`
  — sparklines under the shipped System tiles with **NO service, NO token, NO npm dep, NO outbound
  call**. Decisively, the ring is the ONLY path where sparklines render on a bare box/CI/VM (the
  InfluxDB path shows nothing until ~1GB of daemons + token onboarding run) — consistent with the
  live-first call above.
- **Fixed a real bug found in the design:** `getHostMetrics()` mutated a single module-global
  `_metricsPrev` for its two-sample deltas — the live endpoint and a sampler would contend over one
  baseline. Refactored to `getHostMetrics(prev = _metricsPrev)` returning the fresh counters as a
  non-enumerable `_sample` (never serialized); the live endpoint and the sampler each keep their OWN
  baseline. The always-on server is the SINGLE writer (like `heal-events.jsonl`); `loop.sh` never
  touches this file. `?window` is allowlist-mapped to a fixed point cap (never a path/slice index).
- **InfluxDB/Telegraf/Grafana are the deferred, opt-in Advanced/fleet upgrade** — grafted onto the
  SAME endpoint later under an allowlisted `?source=influx`, for long retention + cross-node rollup
  (the genuine InfluxDB payoff a single appliance may not need yet). That branch carries the
  injection/SSRF-sensitive `queryInflux()` passthrough → its own adversarial review.

## 2026‑07 — Health & Repairs page (roadmap Phase 6, part 1 — self-heal UX)
- Shipped the **Health/Repairs UX** first (metrics stack is a separate branch): a `#/health`
  page with **strict green/yellow/red** per-component cards, **fault attribution** (drive / this
  box / internet / config), a **healed-events feed**, and **one-click Repair**. Matches
  [errors-selfheal.md](../design/errors-selfheal.md) to the letter.
- **Data flows from reports the loop already should have produced.** `verify.sh` now serialises
  each functional check into `verify.json` as `checks[]` (`{status, comp, label}`); `loop.sh`
  now actually **writes `selfheal.json`** (a long-standing log line promised a file nothing wrote)
  + an append-only, capped **`heal-events.jsonl`** feed of genuine repairs. `GET
  /api/status/health` (read-gated) composes them; the **UI computes the component list
  client-side** (`computeComponents()`) from those + the live disk/services/kiwix status the
  shell already fetches — no duplicated health logic on the server, minimal new server surface.
- **One repair endpoint, not many.** `POST /api/maintenance/repair` (admin-only) runs the loop's
  own fixers via a **fixed argv** (`loop.sh once`) — the honest "fix everything" button — so no
  request data reaches a shell. Targeted fixes reuse what exists: per-service **Restart** →
  `POST /api/service/start`; Safe-Mode → the existing **Recover** flow. Deduped + 30s rate-limit.
- **Adversarial-reviewed** (new gated endpoint) before merge; `test-health.sh` + `health.spec.ts`
  cover the report shapes, the composition endpoint, the read-gate, and the admin-gate (the last
  via the fail-safe `VALARK_TEST_NO_SPAWN` hook so CI never runs the heavy loop).
- **Next:** stand up Telegraf + InfluxDB as mirrored services and feed live metrics into the strip.

## 2026‑07 — Download queue as the monitoring surface (roadmap Phase 5, part 1)
- Rebuilt the **Activity** view into a live download **queue**: rich per‑item cards (plain‑language
  label, animated progress bar + %, **ETA** from `startedAt`+progress, status pill, last line),
  **Cancel** (running) / **Retry** (failed), a "resumes automatically after a power loss" note, and
  **Retry‑not‑error framing** — a failed download reads "Interrupted — retries automatically" (true:
  the self‑heal loop re‑runs it), never a scary red error.
- **Live**: reuses the existing SSE stream — `start` stamps a client `startedAt` (for ETA),
  `progress`/`complete` re‑render the queue only when on `#/activity` (`_activityLive`, rAF‑debounced);
  `loadDownloads()` merges `/api/status/downloads` (server truth incl. `startedAt`) once on load to
  catch downloads already running. No backend changes, no new endpoints.
- **Deferred:** true pause/resume + reorder need backend support (the download scripts are aria2/curl
  subprocesses — only cancel exists today); noted as a follow‑up.
- **Profiles → curation weighting (part 2):** the wizard's profile pick now drives REAL librarian
  priority. `catalog.sh` resolves the profile (`VALARK_PROFILE` env → `settings.json` → `balanced`)
  and applies a **per‑bucket multiplier** on each candidate's value (knowledge 1.6× content, ai 1.6×
  models, tools 1.6× tools; off‑buckets 0.8–0.9×), so the box fills what the owner asked for; the
  planner still sorts by value/bytes. A Settings → **Downloads & Priorities** picker changes it live
  via admin‑only `POST /api/setup/profile` (validated to the 4 profiles). `test-profile.sh` proves a
  profile shifts the fill; requesting a specific item still jumps the queue (pins).

## 2026‑07 — Access-mode enforcement + admin sessions (roadmap Phase 2 depth)
- The access layer now **enforces** (was "no gating yet"): stateless HMAC **admin sessions**
  (`auth.issueSession/verifySession`, `varksid` HttpOnly cookie), `POST /api/auth/login｜logout`
  with a per-IP login cooldown, `isAdmin(req)` = localhost OR valid session, and a POST **access
  gate** — admin-only actions always need admin; use-actions need admin in Passworded/Accounts
  mode; Open stays open. UI: a sign-in modal + Settings sign-in row; 401 `{needsAuth}` prompts it.
- **`adduser` upgraded** from localhost-only to admin (localhost OR logged-in) — a remote admin can
  now manage service accounts.
- **Scoped:** the read-wall (gating GET views in Passworded/Accounts) and full Accounts-mode named
  users are follow-ups; this ships the write/use + admin gate (the sensitive actions).
- Security surface → ran a 3-lens adversarial-review Workflow before merge. Tests:
  `tests/test-access.sh` (12, real-server gate via `VALARK_TEST_FORCE_REMOTE`) + auth session unit
  tests + server-api login/logout + a web-ui sign-in spec. Full suite 8 validators + Playwright 321/1.

## 2026‑07 — Consumer shell: Home status + Settings + Activity (roadmap Phase 3, issue #12)
- Delivered the shell's essence **additively** (no route regressions): a health‑app **Home
  status summary** (● All good / Working on it / Needs you + one sentence + big area/utility
  cards), a consolidated **Settings** hub (`#/settings`, Basic/Expert, the design's section list +
  inline Storage + About/Rescue), and an **Activity** feed (`#/activity`, live downloads + events
  placeholder). New nav link **Settings**; `computeHealth()` derives green/amber/red from the
  status the app already fetches (disk, services, downloads).
- **Why additive, not a full 4‑tab teardown:** ~15 existing tests click the current nav links
  (Software/Models/Library/Community/Getting Started). Ripping the nav to a literal four tabs would
  churn them for little user gain right now; the summary‑Home + Settings hub deliver the consumer
  experience without regressions. The literal 4‑tab cap (folding Software/Models into Home cards,
  Getting Started into the wizard) is a **noted follow‑up**.
- Tests: 5 Playwright specs (Home status + 6 cards, Settings nav + hub + inline Storage,
  Basic/Expert reveal, Activity, light‑theme render). Full suite 319/1 green, no regressions.

## 2026‑07 — First‑boot commissioning wizard (roadmap Phase 1, issue #11)
- Shipped the commissioning **core**: `scripts/lib/commission.js` (claim‑token gate + settings
  store, builds on `auth.js`), server `GET /api/setup/state` + `POST /api/setup/commission`
  (fail‑closed on the claim token from the LAN; localhost/console trusted), a startup **claim‑code
  console banner**, `valark claim｜setup-status`, and a **full‑page web wizard** (`#/setup`:
  Welcome → Claim → Name → Admin → Focus → Done) that auto‑takes‑over an un‑commissioned box.
- **Grandfather rule** so existing installs aren't hijacked: a box with a content/model library is
  treated as commissioned (see gotchas). Fresh box (empty library) → wizard.
- **Deferred to follow‑ups** (noted in the PR): the OS‑level discovery/enablement — mDNS
  `valark.local` (avahi), hostname set, captive‑portal at the network layer, the port‑80 toggle
  wiring, `setup.sh --VALARK_YES` integration, the on‑screen TUI, and the topic‑picker → curation
  weight mapping. The state machine + claim gate + wizard + create‑admin (wired to #10) are the core.
- Tests: `tests/test-commission.sh` (10 checks incl. fail‑closed + single‑use token +
  content‑safety), server‑api `/api/setup/state` shape+no‑leak, web‑ui wizard render+step‑through,
  and a fresh‑VM commissioning assertion in `provision.sh`.

## 2026‑07 — Access identity + recovery foundation (roadmap Phase 2, issue #10)
- **Safety net lands first** (research's #1 lesson). Shipped the backend + CLI foundation, no UI
  gating yet (Open stays default): `scripts/lib/auth.js` (scrypt‑hashed admin store, shared by
  server + CLI), `scripts/valark` (`setpassword｜auth status｜auth list｜verify｜usemode｜reset
  --tier1/--tier2`), and read‑only `GET /api/auth/status`.
- **No usable default credential** — an un‑set admin means Open mode + "localhost/console is
  admin," which is exactly what makes password‑less recovery safe. Passcode is scrypt‑hashed in a
  0600 `<state>/auth.json`; the hash/salt never cross the API.
- **Content‑safety invariant is structural + tested:** `STATE_DIR` is separate from
  content/models, so `reset --tier1/--tier2` provably can't wipe the library
  (`tests/test-auth.sh` sha256‑verifies sentinels survive). Content‑erase is deliberately NOT in
  this CLI (it needs the typed‑confirmation UI flow).

## 2026‑07 — First `dev → main` release (v1.1.0) + community sign‑ups (PR #2/#3)
- **Adopted the branch model in practice:** PR #1 (foundational) landed on `dev`; the
  community‑signups quick win (PR #2) landed on `dev`; then the first **`dev → main` release**
  (PR #3) shipped **v1.1.0**. Release cleared the high bar: CI green + full local Playwright
  (310/1) + services e2e (11/0) + **fresh‑VM matrix 27/0 across Ubuntu 22.04/24.04/26.04**.
- **CI is a real gate now.** A fresh CI checkout has *no mirror*, so host‑population tests
  (on‑disk binaries, non‑empty status maps) **skip‑when‑empty**; CI validates code + endpoint
  shape + upstream URL health, while populated‑system e2e runs locally + in the VM matrix. One
  real strict‑mode locator bug was fixed (`#install-btn-<id>` vs `:has-text("Mirror")`).
- **Community account model = per‑service tech, not one UX** ([[val-ark-forum-proxy-burst-quirk]]):
  `COMMUNITY_ACCOUNTS[id].signup` ∈ `host｜self｜shared`. chat/mail = host‑provisioned
  (`<svc>.sh adduser`, one‑step for mail); forum = NodeBB self‑register; paste = shared gated
  instance. `POST /api/service/adduser` is **localhost‑only** (minting a login is admin).
- **Release merge = rebase (main requires linear history).** Rebase‑merge re‑parents dev's
  commits onto `main`, so after a release `main` and `dev` share *content* but diverge by *SHA*
  (`git diff origin/main origin/dev` is empty; commit counts differ). This is benign: GitHub's
  rebase‑merge skips already‑applied patches, so the next release applies only new commits. Tag
  `main`'s tip with `scripts/release.sh` (unprefixed `X.Y.Z` from the `VERSION` file — see the
  release‑tags decision above; the old "untracked `.memsearch/` trips the clean‑tree check"
  workaround is obsolete).

## 2026‑07 — Feature branch: discover/request + self‑replication + tests (PR #1)
- Shipped + deployed to the ARM64 NAS test node + tested (337 tests): Library relabel; Community hub; one‑click
  LAN/tailnet **catalog + request** with **pin + cap‑aware auto‑evict**; **offline
  self‑replication** (git bundle + Node runtime + `bootstrap.sh` + `mirror-self.sh`); fixed
  per‑platform app downloads (`/api/archive`); cross‑arch service fixes; curation (Linux docs +
  setup assistants); the **test library + offline HTML report + fresh‑VM matrix (Ubuntu 22/24/26)**.
- **Why the request/evict shape:** the librarian already did diversity→small‑value→fill→evict;
  a per‑item `request` that pins + evicts the lowest‑priority *unpinned* content extends it
  cleanly and honors the footprint cap.

## Earlier project facts (fleet, curation)
- **Fleet/hardware & mesh:** big shared disk, several boxes (an ARM64 Grace‑Blackwell node, an x86 GPU workstation, a router, an ARM64 NAS),
  NFS/Syncthing sharing, tailscale‑ssh. The data disk is the one shared mirror; GPU nodes infer
  over the network. (Host‑specific addresses/creds are **not** in git — see the deployment host's
  own `.env`.)
- **Curation priority model:** live Kiwix OPDS catalog → planner phases
  diversity → small‑value → fill → evict‑for‑better; value = curated category weight + language +
  density + topic boosts (now including a strong Linux/shell boost, so an offline user can get
  setup help from the box).

## 2026‑07 — Notification center: bell/inbox slice 1 (#69)
- <a id="notify-bell-69-slice1"></a>**The notification center is a READ‑ONLY aggregation, not a
  new store.** `GET /api/status/notifications` composes the signals the box *already* writes —
  `heal-events.jsonl` (self‑heal events) + `selfheal.json`/`verify.json`/disk/Safe‑Mode (current
  conditions) — into one severity‑tagged list. No new state file, no daemon, zero deps. This keeps
  the endpoint read‑gated like the rest of `/api/status/*` and avoids an unauthenticated write path.
- **Dismiss is client‑side (localStorage) for slice 1** so the endpoint stays read‑only. That
  needs **stable item identity**: `heal-events.jsonl` lines carry only `ts|kind|detail` (no id,
  tail‑capped at 200), so the server assigns `ev-<djb2-hash(ts|kind|detail)>` for events and a
  fixed key per condition (`cond-safemode`, `cond-disk-warning|critical`, `cond-verify-<comp>`,
  `cond-missing-assets`). A disk *escalation* gets its own id (`…-critical` vs `…-warning`) so a
  worsening condition re‑surfaces even if the warning was dismissed. **Server‑side, cross‑device
  dismiss** is the deferred follow‑up (adds a write path → same adversarial bar as
  `POST /api/maintenance/repair`); routing into mail/board/chat, the Immediately/Daily/Never
  frequency, and the on‑box LED are also later #69 slices.
- **Severity maps to the existing color grammar** (green info / yellow warning / red critical).
  Self‑heal events are reassuring **info** ("handled it for you"); the lone exception is
  `moderation-error` (could NOT quarantine) → **warning**. Failed functional‑verify checks are
  **warning** ("working on it — self‑heal re‑verifies"), matching the Health page framing.
