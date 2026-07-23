# Val Ark — Implementation Roadmap

Part of the [design hierarchy](README.md). Turns the design into a phased build. Each phase
ships something a real owner can feel; later phases deepen. Ordered so the **safety net
(recovery) lands before we gate anything**, per the research's #1 lesson.

> **Status (as of `VERSION` 0.1.17).** The appliance is real and running. Phases 1–3 and 5
> have shipped; Phase 6 and 7 shipped their core slices (Phase 6 also shipped the notification
> center bell/inbox, #69 slice 1, in 0.1.16); Phase 8 shipped its first slice.
> Delivering releases are cited inline. This file is the **live** phase tracker;
> [current-state.md](current-state.md) is the matching as-of-0.1.17 snapshot. Remaining scope
> is called out per phase with issue references — nothing below claims more than what is on
> `main`.

## Phase 0 — Substrate (✅ shipped this cycle)

The plumbing the consumer UX sits on, already built + tested + deployed (PR #1):
one-click catalog/request + cap-aware evict + pins, offline self-replication (`bootstrap.sh`,
`mirror-self.sh`, Node runtime mirror), the Community hub + service start, the fixed
per-platform app downloads (`/api/archive`), curation (Linux + assistants), and the test
library + offline HTML report. Cross-arch service fixes. **This is the engine; the phases
below are the appliance around it.**

## Phase 1 — Commissionable (the first-boot wizard) — ✅ shipped (v1.2.0; easy-setup polish in 0.1.13) → [commissioning.md](commissioning.md)
- mDNS `valark.local` (+ fixed fallback IP on the console banner) and a **captive-portal
  redirect**: an un-owned box sends all traffic to the setup wizard, not the catalog.
- **Claim token** (printed sticker / console) gates the setup surface → fail-closed.
- Wizard screens: Preparing → Claim → **Create admin** (with generator + strength meter) →
  Name → **Found your disk (one confirm)** → **Profile + emphasis** → Port 80 → **Recovery
  card (print/QR)** → Cert heads-up → Done (fill already running).
- Console **boot banner** with URL + "Press Enter for recovery menu."
- *Reuses:* `valark-env.sh` disk autodetect, `setup.sh --VALARK_YES`, `start.sh port80`.

## Phase 2 — Access & Recovery (the safety net) — ✅ shipped (v1.3.0 access control; v1.4.0 recovery card + Safe Mode) → [access-identity.md](access-identity.md) · [recovery.md](recovery.md)
- Admin identity store (hashed passcode / accounts), **localhost & console implicitly
  trusted**, **never a usable default credential** (only the one-time claim token).
- **Use Mode:** Open (default) / Passworded / Accounts — **two roles only** (Admin + optional
  Viewer). Optional opt-in 2FA.
- **Recovery, fully local + paper-backed:** forgot-password auto-surfaced after 3 fails +
  recovery card; **two-tier reset** — button-with-beeps (1 = admin+network only; 3 = config
  reset, **content kept**) / console recovery menu / `valark setpassword` + `valark auth list`.
- **Content-safety invariant:** `valark/state` (config) physically separate from the multi-TB
  content — **no reset ever wipes Wikipedia/models.**
- **Safe Mode** boot (core-only) when config is broken.
- *Builds on:* the LAN/tailnet/localhost POST gate + rate limiter (already present) as the floor.

## Phase 3 — The consumer shell — ✅ shipped (four-tab nav in 0.1.13, epic #91) → [admin-console.md](admin-console.md)
- Restructure the SPA to **four top tabs: Home · Library · Activity · Settings** (cap it there).
  The nav is live (`web-ui/index.html` `renderNav` — Home/Library/Activity/Settings); Library
  carries an in-page sub-nav (Software · Models · Content · **Downloads**). Onboarding polish
  continues under epic **#91**.
- **Home** = one status light + one sentence + a few big cards; persistent health line.
- **Settings** = one consolidated admin panel with **Basic (default) / Expert** and
  progressive disclosure; **hide what doesn't apply yet** (no Fleet UI until a 2nd node).
- Plain-language everything; audit line; the assistant embedded per page.

## Phase 4 — Storage as a pool → [storage.md](storage.md)
- Generalize the single `DATA_ROOT` to a **pool descriptor** (`state/storage.json`): primary
  (fixed, holds the brain) + growable content volumes; drives tracked by UUID/label.
- **Add / safely-remove a drive**, surprise-unplug graceful-degrade, auto-rejoin on re-plug.
- Union (mergerfs) preferred; multi-root fallback. Per-volume health/space tiles.
- **SeaweedFS multi-computer pool** as the opt-in "add a computer" upgrade (progressive).
- *Status:* not yet shipped. The `SeaweedFS` community service exists (`scripts/services/seaweedfs.sh`,
  opt-in via `VALARK_SERVICES`), but the pool descriptor (`state/storage.json`), add/remove-drive,
  and union mount are still future work. `valark-env.sh` remains single-root today.

## Phase 5 — Priorities & downloads UX — ✅ shipped (v1.5.0; packages/Downloads surface in 0.1.12) → [downloads-monitoring.md](downloads-monitoring.md)
- **Profiles (disk-sized class roles)** + **emphasis** (Knowledge / AI / Tools / Balanced)
  driving curation weights + caps; "Fill everything (Recommended)" default.
- Plain-language topic picker → catalog priorities; the **download queue** as the marquee
  monitoring surface: per-item cards, ETA, pause/resume/reorder, "resumes after power loss,"
  Retry-not-error. Updates surfaced as reassurance.
- *Reuses:* the SSE stream, librarian priority fill, storage bar.
- **Packages / Downloads surface (0.1.12, epic #89 slice 1).** `GET /api/packages` enumerates the
  per-platform app/tool archives **present on the box** (present inventory, not the catalog),
  surfaced under Library ▸ **Downloads**. Broadening the published, downloadable package set
  beyond the on-disk manifest and the release artifacts remains open in epic **#89**.

## Phase 6 — Monitoring & self-heal UX (core shipped 0.1.7–0.1.8; tracking issue #28 **closed**) → [errors-selfheal.md](errors-selfheal.md)
- **[DONE — Health/Repairs UX]** (0.1.7) `#/health` page + Home entry point, fed by the loop/verify
  reports: **strict green/yellow/red** per-component grammar, **fault attribution** (drive vs
  box vs internet vs config; dead upstream links framed as "recovering"), a **healed-events
  feed**, and **one-click Repair** — a single fixed-argv `POST /api/maintenance/repair` that
  runs the loop's own fixers (`loop.sh once`), plus per-service Restart and Safe-Mode Recover.
  Backed by `loop.sh` writing `state/selfheal.json` + `heal-events.jsonl` (the self-heal snapshot —
  distinct from librarian's `health.json`), `verify.sh` emitting per-check component results, and a
  read-gated `GET /api/status/health`.
- **[DONE — live metrics]** (0.1.7) Live host gauges on the Health page (`GET /api/status/metrics`):
  a **System tiles** strip (CPU%, memory, load, uptime, net rate, temperature) + a "System
  load" component card, read straight from `/proc` + `os` by the zero-dep server — **works on
  a bare box with no services**.
- **[DONE — metrics history + sparklines]** (0.1.8) A **zero-dep on-disk ring buffer**
  (`state/metrics-history.jsonl`, ~24h, single-writer server) serves `GET /api/status/metrics/history`;
  each System tile gets an inline sparkline when the ring has history, falling back to a neutral
  "live-only" indicator only when it is empty. This replaced the planned Telegraf/InfluxDB
  dependency for the single-appliance case — see [`../knowledge/decisions.md`](../knowledge/decisions.md).
- **[DONE — offline notification center, slice 1]** (0.1.16, issue #69, the last open slice of the
  now-closed #28) a real bell/inbox in the shell. `GET /api/status/notifications` (read-gated, like
  all `/api/status/*`) aggregates the read-only signals the box already writes — recent
  `heal-events.jsonl` entries plus the current warning/critical conditions the health report knows
  (Safe Mode, disk almost full, a failed functional-verify check, unresolved missing assets) — into
  one severity-tagged list with stable ids, never throwing on a bare box. The nav gains a bell with
  an unread badge and a dropdown inbox (All / Critical / Warning / Info / Dismissed filters); dismiss
  is **client-side (localStorage)** this slice, so the endpoint stays read-only. See
  [errors-selfheal.md](errors-selfheal.md) ("As built") and [`../knowledge/decisions.md`](../knowledge/decisions.md).
- **[NEXT — notification routing + cross-device dismiss]** (still open under #69) route digests into
  the box's own mail/board/chat, add the Immediately / Daily / Never frequency setting and the on-box
  LED, and add **server-side (cross-device) dismiss** — held to the same adversarial bar as
  `POST /api/maintenance/repair` once a dismiss write path is added.
- **[DEFERRED — opt-in retention stack]** (issue #66) **Telegraf + InfluxDB** as mirrored services
  (Grafana optional/Advanced) for long-horizon retention + fleet rollup, grafted onto the *same*
  `GET /api/status/metrics/history` endpoint later under an allowlisted `?source=influx`. Native
  sparklines already cover the single-box case, so whether the stack is still warranted is an open
  question tracked in #66; Telegraf/InfluxDB are currently mirrored only as **catalog tools**, not
  wired as services.

## Phase 7 — Safety & moderation — ✅ shipped (0.1.9, end to end) → [safety-moderation.md](safety-moderation.md)
- **[DONE]** On-device, **fail-closed** moderation: a decision core (`scripts/lib/moderation.sh`)
  screens content on `POST /api/moderation/check` (the raw bytes are the content); `GET /api/status/moderation`
  + `GET /api/moderation/queue` + admin-only `POST /api/moderation/review` drive the admin **Safety
  card** + review queue; `POST /api/setup/moderation` tunes the `VALARK_MODERATION_*` knobs. An error,
  timeout, or ambiguous result **holds/quarantines** — never allows.
- **[DONE]** A loop **enforcement sweep** (`loop.sh` step 7c → `scripts/lib/mod-sweep.sh`) screens
  and quarantines stored uploads each cycle.
- *Scope as shipped (PR #46):* the sweep covers an **explicit plain-file uploads area only**
  (`VAL_ARK_UPLOADS` / `VALARK_MODERATION_DIRS`) — never a DB-backed service store — so the original
  "default-on for paste/forum/SeaweedFS/mail" wording overstated it.
- **[NEXT — per-service enforcement]** real paste/forum/mail coverage needs a **pre-store intercept
  or service-native hook**; recorded as a deliberate follow-up in
  [`../knowledge/decisions.md`](../knowledge/decisions.md) (no tracking issue open yet).
- *Note:* the shipped classifiers run on **llama.cpp**, not the originally-planned ONNX head —
  text via **Llama-Guard-3-8B**, images via a mirrored **tiny VLM** (SmolVLM / moondream2,
  `llama-mtmd-cli`), all curated in `data/models-extra.tsv`. Tests inject a stub via
  `VALARK_MODERATION_CMD`.

## Phase 8 — The assistant, everywhere (slice 1 shipped 0.1.14, issue #67)
- **[DONE — Ask Val Ark, slice 1]** (0.1.14) A minimal offline ask affordance: `GET /api/status/ask`
  (runtime + model readiness, read-gated) + `POST /api/ask` (streams the box's own small chat
  model's answer as SSE frames), and a Home "Ask Val Ark" card. Reuses the proven single-shot
  llama.cpp invocation (verify.sh / moderation) — argv-array spawn (no shell), token cap,
  wall-clock SIGKILL, concurrency admission cap, and FAIL-SOFT (a bare box answers "not installed
  yet", never a 5xx). See [`../knowledge/decisions.md`](../knowledge/decisions.md).
- **[NEXT]** embed it everywhere: **doc-grounding/RAG is not built yet** — slice 1 passes only the
  user's question plus an optional caller-supplied `context` string, with no retrieval over the
  bundled Linux/setup docs or ZIM. Later slices add RAG, per-page context beyond Home, and — where
  safe — a button that applies the fix.

## Cross-cutting (every phase)
- **Release & self-replication (0.1.12, epic #88 slice).** Pushing an unprefixed `0.x.y` tag runs
  `.github/workflows/release.yml`, which builds the offline self-replication payload — a full-history
  git **bundle**, a `val-ark/`-prefixed source **tarball**, and **`SHA256SUMS`** — and attaches them
  to the GitHub release. This is the same payload `scripts/mirror-self.sh` serves at
  `/sources/val-ark/` and `bootstrap.sh` consumes. Fuller dev→main cut automation stays open in #88.
- **Tests:** extend the harness — a **fresh-VM commissioning e2e** (wizard → running box) and
  a **recovery e2e** (forgot-password/reset paths), plus per-phase specs, all feeding the
  offline HTML report.
- **Docs:** keep this hierarchy + the user-facing docs current; the assistant reads them.
- **Accessibility + both themes** on every new screen; plain language reviewed against "Jordan."
- **Backwards-compatible:** the CLI/`.env` path keeps working for power users (it's just no
  longer the *only* path).

## Delivery order (as executed)
Phase 1 + Phase 2 (**commission + recover**) landed first — the "set it up and never get locked
out" core that makes Val Ark usable by a non-technical owner — followed by Phase 3 (the shell) so
the rest had a home, then Phase 5 (downloads/priorities), Phase 6 (health/metrics), Phase 7
(moderation), and Phase 8 slice 1 (the assistant). Phase 4 (storage as a pool) is the main
consumer-facing phase still ahead.
