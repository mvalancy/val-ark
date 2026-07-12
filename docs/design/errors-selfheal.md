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
