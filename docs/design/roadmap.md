# Val Ark — Implementation Roadmap

Part of the [design hierarchy](README.md). Turns the design into a phased build. Each phase
ships something a real owner can feel; later phases deepen. Ordered so the **safety net
(recovery) lands before we gate anything**, per the research's #1 lesson.

## Phase 0 — Substrate (✅ shipped this cycle)

The plumbing the consumer UX sits on, already built + tested + deployed (PR #1):
one-click catalog/request + cap-aware evict + pins, offline self-replication (`bootstrap.sh`,
`mirror-self.sh`, Node runtime mirror), the Community hub + service start, the fixed
per-platform app downloads (`/api/archive`), curation (Linux + assistants), and the test
library + offline HTML report. Cross-arch service fixes. **This is the engine; the phases
below are the appliance around it.**

## Phase 1 — Commissionable (the first-boot wizard) → [commissioning.md](commissioning.md)
- mDNS `valark.local` (+ fixed fallback IP on the console banner) and a **captive-portal
  redirect**: an un-owned box sends all traffic to the setup wizard, not the catalog.
- **Claim token** (printed sticker / console) gates the setup surface → fail-closed.
- Wizard screens: Preparing → Claim → **Create admin** (with generator + strength meter) →
  Name → **Found your disk (one confirm)** → **Profile + emphasis** → Port 80 → **Recovery
  card (print/QR)** → Cert heads-up → Done (fill already running).
- Console **boot banner** with URL + "Press Enter for recovery menu."
- *Reuses:* `valark-env.sh` disk autodetect, `setup.sh --VALARK_YES`, `start.sh port80`.

## Phase 2 — Access & Recovery (the safety net) → [access-identity.md](access-identity.md) · [recovery.md](recovery.md)
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

## Phase 3 — The consumer shell → [admin-console.md](admin-console.md)
- Restructure the SPA to **four top tabs: Home · Library · Activity · Settings** (cap it there).
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

## Phase 5 — Priorities & downloads UX → [downloads-monitoring.md](downloads-monitoring.md)
- **Profiles (disk-sized class roles)** + **emphasis** (Knowledge / AI / Tools / Balanced)
  driving curation weights + caps; "Fill everything (Recommended)" default.
- Plain-language topic picker → catalog priorities; the **download queue** as the marquee
  monitoring surface: per-item cards, ETA, pause/resume/reorder, "resumes after power loss,"
  Retry-not-error. Updates surfaced as reassurance.
- *Reuses:* the SSE stream, librarian priority fill, storage bar.

## Phase 6 — Monitoring & self-heal UX → [errors-selfheal.md](errors-selfheal.md)
- **[DONE — Health/Repairs UX]** `#/health` page + Home entry point, fed by the loop/verify
  reports: **strict green/yellow/red** per-component grammar, **fault attribution** (drive vs
  box vs internet vs config; dead upstream links framed as "recovering"), a **healed-events
  feed**, and **one-click Repair** — a single fixed-argv `POST /api/maintenance/repair` that
  runs the loop's own fixers (`loop.sh once`), plus per-service Restart and Safe-Mode Recover.
  Backed by `loop.sh` now actually writing `health.json` + `heal-events.jsonl`, `verify.sh`
  emitting per-check component results, and a read-gated `GET /api/status/health`.
- **[DONE — live metrics]** Live host gauges on the Health page (`GET /api/status/metrics`):
  a **System tiles** strip (CPU%, memory, load, uptime, net rate, temperature) + a "System
  load" component card, read straight from `/proc` + `os` by the zero-dep server — **works on
  a bare box with no services**. History shown as a neutral "live-only" indicator.
- **[NEXT — retention stack]** Stand up **Telegraf + InfluxDB** as mirrored services (Grafana
  optional/Advanced, Task #24) for history/sparklines + fleet rollup, fed into the same strip
  via a reviewed InfluxDB HTTP passthrough; **offline notification center** routing into the
  box's own mail/board/chat.

## Phase 7 — Safety & moderation → [safety-moderation.md](safety-moderation.md)
- On-device **moderation hook** (NSFW ONNX classifier on NPU/GPU + Llama-Guard text),
  **default-on** for shared uploads (paste/forum/SeaweedFS/mail), block-by-default + admin
  review queue, fail-closed.
- Curate the NSFW model into `models-extra.tsv`.

## Phase 8 — The assistant, everywhere
- **"Ask Val Ark"** embedded across the shell: the on-box LLM (already curated) + the bundled
  Linux/setup docs, context-aware help, and — where safe — a button that applies the fix.

## Cross-cutting (every phase)
- **Tests:** extend the harness — a **fresh-VM commissioning e2e** (wizard → running box) and
  a **recovery e2e** (forgot-password/reset paths), plus per-phase specs, all feeding the
  offline HTML report.
- **Docs:** keep this hierarchy + the user-facing docs current; the assistant reads them.
- **Accessibility + both themes** on every new screen; plain language reviewed against "Jordan."
- **Backwards-compatible:** the CLI/`.env` path keeps working for power users (it's just no
  longer the *only* path).

## Suggested first sprint
Phase 1 + Phase 2 together (**commission + recover**) — they're the "set it up and never get
locked out" core that makes Val Ark usable by a non-technical owner, and they unblock everyone
testing on real hardware. Phase 3 (the shell) follows immediately so the rest has a home.
