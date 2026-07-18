# Val Ark — Current State (as of `VERSION` 0.1.14)

> Snapshot of the **shipped** consumer appliance. It answers, directly, the questions this
> redesign set out to solve: *Can a non-technical person commission it from a web UI? Is there
> an admin area? What happens if they forget their password? Can they choose open vs.
> account-gated? Are there real access controls?* Short answer today: **yes, yes, yes, yes,
> yes.** The CLI still works for power users, but it is no longer the only path.
>
> [roadmap.md](roadmap.md) is the live phase tracker (what shipped in which release, what is
> still open). This file is the point-in-time "what is true right now" companion to it.

Part of the [design hierarchy](README.md).

---

## Where it started vs. where it is now

The redesign began from a power-user / CLI baseline (mid-2026, pre-Phase-1). Phases 1–3 and 5
have since shipped, Phase 6 and 7 shipped their core slices, and Phase 8 shipped its first slice.

| | Baseline (pre-redesign) | Now (0.1.14) |
|---|---|---|
| User | A Linux admin comfortable with `.env`, `ssh`, `bash` | A person who "barely knows what GitHub is" (CLI still available) |
| Setup | Edit files + run scripts in a terminal | Browser (or console) first-boot wizard behind a claim token |
| Manage | Read logs, run CLI commands | Four-tab shell: Home · Library · Activity · Settings |
| Recover | Know the right script/flag | Paper recovery card, forgot-password flow, Safe Mode, two-tier reset |
| Mental model | "A mirror engine you configure" | "One EASY button that just works" |

---

## What exists today

**Commissioning is a browser (or console) wizard, not hand-edited files.**
- A first-boot flow gated by a one-time **claim token** (fail-closed): create the first admin,
  name the box, confirm the found disk, pick a profile/emphasis, offer port 80, and print a
  **recovery card**. Backed by `GET /api/setup/state`, `POST /api/setup/commission`,
  `GET /api/setup/recovery-card`, `POST /api/setup/profile`.
- The CLI path still works (`start.sh setup` / `serve`, headless via `VALARK_YES`, `loop.sh
  install` for the 24/7 cron) — it is now one option, not the only one.

**The web UI is a four-tab consumer shell (epic #91), not a bare catalog.**
- **Home · Library · Activity · Settings** (`web-ui/index.html` `renderNav`). Library carries an
  in-page sub-nav — Software · Models · Content · **Downloads**.
- **Home** = a status light + one sentence + big cards, including an **Ask Val Ark** box.
- **Settings** = a consolidated admin panel with a Basic/Expert detail toggle; **Activity** shows
  the download queue and the self-heal event feed.
- **Downloads** lists the packages actually present on the box via `GET /api/packages` (present
  inventory, not the catalog — epic #89 slice 1).

**There is a real Val Ark identity + operator-chosen access model.**
- **Use Mode: Open / Passworded / Accounts**, two roles (Admin + optional Viewer), with
  **localhost & console implicitly trusted**. Login/logout/recover via `GET /api/auth/status`,
  `POST /api/auth/login|logout|recover`; admin-only POSTs are enforced server-side
  (`ADMIN_ONLY_POSTS`).
- Underneath, the original floor still holds: write actions and the reads behind the wall are
  gated to **LAN + tailnet + localhost** with a per-IP rate limit; the box is assumed reachable
  only on the LAN + tailscale, never the public internet.

**Recovery is fully local and paper-backed.**
- Forgot-password flow, the printed recovery card, **Safe Mode** boot (core-only when config is
  broken), and a two-tier reset that **never wipes content** (`valark/state` config is physically
  separate from the multi-TB content). (Phase 2 — v1.3.0 / v1.4.0.)

**Health, metrics, and self-heal are a real dashboard (Phase 6, issue #28 closed).**
- `#/health` composes the loop/verify reports into strict green/yellow/red per-component cards
  with fault attribution and a **healed-events feed**; **one-click Repair** =
  `POST /api/maintenance/repair` (fixed-argv `loop.sh once`, admin-only, no request data reaches
  the shell). `loop.sh` writes `state/selfheal.json` + `heal-events.jsonl`; `verify.sh` writes
  per-check results; served read-gated at `GET /api/status/health`.
- **Live host gauges** at `GET /api/status/metrics` (CPU/memory/load/uptime/net/temperature,
  read from `/proc` + `os` by the zero-dep server) plus a **zero-dep on-disk history ring buffer**
  (`state/metrics-history.jsonl`) at `GET /api/status/metrics/history`, which drives inline
  sparklines on each tile. The planned Telegraf/InfluxDB retention stack was **descoped to an
  opt-in Advanced/fleet upgrade** (issue #66); the offline notification center is the last open
  Phase-6 slice (issue #69).

**Shared uploads are moderated, fail-closed (Phase 7, 0.1.9).**
- On-device moderation screens content (`POST /api/moderation/check`), an admin **Safety card** +
  review queue (`GET /api/status/moderation`, `GET /api/moderation/queue`, admin-only
  `POST /api/moderation/review`), tunable via `POST /api/setup/moderation` (`VALARK_MODERATION_*`).
  An error, timeout, or ambiguous result **holds/quarantines** — never allows. A loop sweep
  (`loop.sh` step 7c) quarantines flagged files in the explicit plain-file uploads area
  (`VAL_ARK_UPLOADS` / `VALARK_MODERATION_DIRS`); per-service (paste/forum/mail) pre-store
  intercepts are a documented follow-up.

**The box can start to help you: Ask Val Ark (Phase 8 slice 1, 0.1.14, issue #67).**
- A Home "Ask Val Ark" card streams the box's own small chat model's answer over SSE
  (`POST /api/ask`, readiness at `GET /api/status/ask`), reusing the hardened single-shot
  llama.cpp path (argv-array spawn, token cap, wall-clock kill, concurrency cap) and **failing
  soft** on a bare box ("not installed yet", never a 5xx). **No RAG yet** — it passes only the
  question plus an optional caller-supplied context string.

**It replicates itself offline, with real release artifacts.**
- `/bootstrap.sh` hands out a host-aware offline installer; the source **bundle + tarball** are
  served at `/sources/val-ark/` (mirrored by `scripts/mirror-self.sh`). Tagging a release runs
  `.github/workflows/release.yml`, which builds the same git bundle + `val-ark/`-prefixed source
  tarball + `SHA256SUMS` and attaches them to the GitHub release (epic #88 slice).
- File serving is **realpath-contained**: `/api/archive/*` and `findZimFiles` reject in-tree
  symlinks that escape the data tree (#101 / #112).

---

## Direct answers to the questions raised

1. **Easy web-UI commissioning of a new system?** — *Yes.* A browser/console first-boot wizard
   behind a claim token; no `.env` editing required (the CLI path still exists for power users).
2. **An actual admin area?** — *Yes.* The Settings tab is a consolidated admin panel (Basic/Expert),
   with Health, Activity, Downloads, and moderation surfaces.
3. **Forgot the password — recovery on a local monitor / localhost experience?** — *Yes.* A
   forgot-password flow, a printed recovery card, Safe Mode, and a two-tier reset that keeps
   content; localhost & console are implicitly trusted.
4. **Can the operator choose open vs. account-gated?** — *Yes.* Use Mode is **Open / Passworded /
   Accounts**, chosen at setup and changeable later.
5. **Real access controls (roles, admin vs. user)?** — *Yes.* A Val Ark identity with Admin +
   optional Viewer roles and server-enforced admin-only actions, on top of the network-position
   gate on writes.

---

## What's still open

- **Storage as a pool (Phase 4).** Still single-root (`valark-env.sh`). The SeaweedFS *service*
  exists (opt-in), but the pool descriptor (`state/storage.json`), add/remove-drive, and union
  mount are future work.
- **Offline notification center (issue #69).** The last open Phase-6 slice — a bell/inbox routing
  self-heal events into the box's own mail/board/chat.
- **Opt-in retention stack (issue #66).** Telegraf + InfluxDB (+ optional Grafana) for
  long-horizon retention and fleet rollup, grafted onto the same `metrics/history` endpoint —
  deferred, since native sparklines already cover the single-box case.
- **Assistant, everywhere (issue #67 next slices).** Doc-grounding/RAG over the bundled Linux/setup
  docs + ZIM, per-page context beyond Home, and safe "apply the fix" buttons.
- **Per-service moderation enforcement.** A pre-store intercept or service-native hook for
  paste/forum/mail — a recorded deliberate follow-up (see [`../knowledge/decisions.md`](../knowledge/decisions.md)).
- **Epic remainders.** Fuller dev→main release automation (#88), a broader published package set
  (#89), and continued easy-setup / onboarding polish (#90 / #91).

The rest of this hierarchy specifies each phase, informed by how the best comparable products
(Synology DSM, TrueNAS, Home Assistant, Umbrel/CasaOS, consumer routers, and health apps) solve
these problems.
