# Val Ark — Errors & Self-Heal

Part of the [design hierarchy](README.md). The promise: **"one big EASY button, regardless
of errors."** Val Ark's self-heal loop (`loop.sh`/`verify.sh`) already repairs links,
restarts services, tops up content, and re-verifies every 30 minutes — that autonomy is the
product. The job here is to make it **visible, reassuring, and, for the rare thing it can't
auto-fix, a one-tap repair in plain words.** Never a stack trace.

## The model: self-heal first → surface only what's left → always show what was healed

1. **Fix it automatically** where the loop safely can (already happening).
2. **Show what was healed**, calmly — self-healing you can't see doesn't build trust:
   *"Web server was down — restarted it automatically. Nothing to do."* *"Re-linked 3 files."*
3. **Surface only the residue** — the few things that truly need a human — as one plain card
   with **what happened + the one recommended next step + one button.**

## Strict color grammar (everywhere, no decoration)

`● green = healthy · ● yellow = attention / working on it · ● red = act now.` A glance at any
card, badge, or the home status light means the same thing across the entire UI. If the box
has a status **LED**, it speaks the same vocabulary (solid = healthy, blinking = working/
updating, red = problem) and the on-screen banner color **matches the LED** — device and app
never disagree.

## Where errors live: a Repairs/Health strip, pinned on Home

Modeled on Home Assistant **Repairs** + Nextcloud setup warnings — advisory, not blocking, so
the box stays usable:

```
Health
  ✓ Everything healthy — last self-check 2 min ago
  ✓ Wikipedia is being served · AI helper ready · 3 people on chat
  ─────────────────────────────────────────────────────────────
  ⚠ Disk almost full — freeing up low-priority content automatically   [Details]
  ⚠ "Backup DAS" was unplugged — 2,140 collections paused              [Reconnect help]
  ✕ Drive health warning on NVMe                                       [Check drive]
```

- **Green reassurance** at the top (the box is fine, and here's the proof).
- **Calm auto-fix reports** ("handled it for you") — the trust-builders.
- **Actionable cards**: one sentence + one button. A nav **badge count** flags how many need
  attention; severity is critical/warning/info; **Dismiss / Dismiss-all** persists across reboots.

## Attribute faults to the right layer (the single most valuable behavior)

Borrowed from routers (a red WAN light means "your ISP," not "the router"). This stops a
non-expert from factory-resetting a working box:

- *"The internet is down — that's your provider. Val Ark is fine and still serving Wikipedia
  offline."*
- *"A drive was removed — Val Ark and everything on your other drives are fine."*
- Known-benign transients (e.g. the NodeBB `/app/forum/` 503 burst quirk) render as
  **"recovering,"** never "ERROR."

## Every problem offers a fix — including via the assistant

- Common issues get a **Repair** button that runs the fix (restart a service, re-mirror,
  free space, re-run a setup step) — the loop's actions, exposed as one tap.
- **"Ask Val Ark"** is on every error card: the on-box assistant explains the issue in plain
  words from the bundled docs and, where safe, offers to apply the fix.
- **"Learn more" resolves to bundled offline docs / a ZIM page — never a dead internet URL**
  (Val Ark mirrors Kiwix content; point there).

## Notifications are offline-native

No cloud push, no email (there is no internet). **One aggregating bell/inbox** (à la QNAP
Notification Center / TrueNAS alert bell):

- Filters: All / Critical / Warning / Info / Dismissed; frequency: Immediately / Daily / Never
  (never nag).
- **Delivery uses the box's own comms** it already ships — a message to the local mail/board/
  chat, an on-box LED, and the home status line.

### As built (bell/inbox — issue #69 slice 1)

- **`GET /api/status/notifications`** (read-gated, like all `/api/status/*`) aggregates the
  read-only self-heal signals the box already writes into one severity-tagged list: recent
  `heal-events.jsonl` entries (info; a `moderation-error` rises to warning) plus the current
  warning/critical conditions the health report knows — Safe Mode, disk almost full (same
  ≥90/≥97 thresholds as the Health page), a failed functional-verify check, unresolved missing
  assets. Each item is `{ id, ts, severity (critical|warning|info), title, detail, source }`
  with a **stable id** (a content hash for events, a fixed key per condition), bounded to the
  last 60, and it **never throws on a bare box** (empty → `{items:[]}`).
- **Bell/inbox in the shell** (`web-ui/`): a real `<button>` bell in the top nav with an
  unread-count badge, a dropdown inbox listing items newest-first with critical/warning/info
  styling and **All / Critical / Warning / Info / Dismissed** filter chips. Esc- and
  backdrop-dismissible; both themes; all rendered text escaped. **Persistent dismiss is
  client-side (localStorage)** this slice, so the endpoint stays read-only; "unread" =
  active-and-not-yet-seen (opening the inbox marks the set seen).
- **Deferred to later slices** (still open under #69): routing digests into the box's own
  mail/board/chat; the Immediately / Daily / Never frequency setting; the on-box LED; and
  **server-side (cross-device) dismiss** state — the natural next step once a dismiss write
  path is added (held to the same adversarial bar as `POST /api/maintenance/repair`).

## Never make the owner hunt for a credential

Any tool that generates a login (paste, forum admin, etc.) shows it in a post-setup dialog
and keeps it retrievable via **"Show credentials"** on that app's tile — the owner never opens
a log to find a password ([recovery.md](recovery.md) covers the admin passcode itself).

## When the box itself can't start: Safe Mode / recovery page

If config is fatally broken (bad setting, half-finished update), Val Ark boots **core-only** —
just the web UI + recovery, skipping community services and the fill — so one broken piece can
never black-screen the owner. It shows: *"Val Ark is in recovery mode — repairing content, X
of Y verified,"* with an admin login and **Restore / Reset admin / Continue** buttons. This is
the existing repair logic exposed as a friendly page instead of a dead port
([recovery.md](recovery.md)).

## What we build (→ [roadmap.md](roadmap.md))

- A **Health/Repairs API + strip** fed by `loop.sh`/`verify.sh` + the metrics stack
  ([monitoring](downloads-monitoring.md)): healed-events feed, actionable items, severity,
  dismissals.
- **Fault attribution** rules (internet vs. box vs. drive; benign transients).
- **One-click Repair** actions mapped to the loop's fixers; the assistant hook.
- **Offline notification center** routing into the box's own channels.
- **Safe Mode** boot path (shared with [recovery.md](recovery.md)) + the always-matching
  color/LED grammar.

## As built (Health/Repairs UX + live metrics + history — shipped)

- **Reports the loop already had — now actually written.** `verify.sh` serialises every
  functional check into `verify.json` as `checks[]` (`{status, comp, label}`, `comp` ∈
  library/apps/models/server/integrity/mesh) so the page can attribute faults per component.
  `loop.sh` now **writes `selfheal.json`** (a log line long promised it, but nothing wrote it):
  the latest cycle's space/verify tallies + dead-link/missing-asset counts + this-cycle
  repairs, plus an append-only, 200-line-capped **`heal-events.jsonl`** feed of genuine repairs
  (a web-server restart, a service start). Both emitted from bash via tiny `_json_str`/`_hj_str`
  escapers, written atomically (`.tmp` → `mv`).
- **`GET /api/status/health`** (read-gated, like all `/api/status/*`) composes those two files
  + the events tail + Safe-Mode state. The **web UI** (`#/health`, `computeComponents()`) turns
  them — with the live disk/services/kiwix status the shell already has — into per-component
  green/yellow/red cards, each naming a **likely cause** and, where the box can act, a repair.
- **One-click Repair** = **`POST /api/maintenance/repair`** (admin-only; `ADMIN_ONLY_POSTS`):
  a **fixed-argv** `bash loop.sh once` — the loop's own fixers — spawned detached, deduped +
  rate-limited, **no request data reaches the command**. Per-service Restart reuses
  `POST /api/service/start`; Safe-Mode uses the existing Recover flow.
- **Live metrics + history — shipped.** `GET /api/status/metrics` reads host gauges straight from
  `/proc` + `os` (CPU/memory/load/uptime/net/temperature); a **zero-dep on-disk ring buffer**
  (`state/metrics-history.jsonl`, single-writer server) serves `GET /api/status/metrics/history`,
  which draws an inline sparkline on each System tile (falling back to a neutral "live-only"
  indicator only when the ring is empty). This replaced the Telegraf/InfluxDB dependency for the
  single-appliance case.
- Entry points: the Home status strip's "Health & repairs ›" link, Settings → Health, and the
  Activity → Events pointer. **Next:** the offline notification center (issue #69, the last open
  slice of the now-closed #28); the Telegraf/InfluxDB retention stack is a deferred opt-in
  Advanced/fleet upgrade (issue #66).
