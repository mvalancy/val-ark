# Val Ark — Flexible Storage (add & remove drives)

Part of the [design hierarchy](README.md). Requirement: a **primary** location (e.g. a
folder on NVMe) plus **additional** storage (a USB DAS, another disk) that the owner can
**flexibly add and remove** — and it just keeps working. Today Val Ark uses a *single*
data root (`VAL_ARK_DATA`, autodetected largest mount); this generalizes it to a pool.

## The model: a small fixed brain + a growable content pool

```
PRIMARY (fixed, never removable)                CONTENT POOL (growable, hot-pluggable)
┌──────────────────────────┐                    ┌───────────┐ ┌───────────┐ ┌───────────┐
│ valark/state  (config,   │   librarian +      │ NVMe      │ │ USB DAS   │ │ ext HDD   │
│   admin, pins, manifest, │   kiwix + server → │ /content  │ │ /content  │ │ /content  │
│   metrics DB) — tiny      │   see ONE logical  │ models…   │ │ models…   │ │ models…   │
│ + hot content            │   content path      │ (primary) │ │ (added)   │ │ (added)   │
└──────────────────────────┘                    └───────────┘ └───────────┘ └───────────┘
```

Two rules make this safe and simple:

1. **The brain lives on the primary, always.** `valark/state` — the config, admin
   identity, pins/manifest, metrics — is small and stays on the fixed primary volume. It
   is **never** on removable media, so pulling a USB drive can never corrupt Val Ark's
   settings or its record of what it has. (This is the same content-safety invariant that
   makes [recovery](recovery.md) safe: a reset touches the brain, never the multi-TB content.)
2. **Content is a pool the owner grows.** The primary also holds content, and any added
   drive contributes more content capacity. The librarian, `kiwix-serve`, and the web
   server see **one logical content location**; where a file physically lives is Val Ark's
   problem, not the owner's.

## Two ways to present the pool as "one location"

| Approach | How | When |
|----------|-----|------|
| **Union mount** *(preferred on Linux)* | Pool the per-drive `content`/`models` dirs into one path with a FUSE union (mergerfs; the box already runs one FUSE union on the RK3588). Add a drive = add a branch; remove = drop a branch. Files land on whichever branch has room (policy: most-free-space). | The clean default when mergerfs is available (mirrored as a tool). |
| **Multi-root** *(portable fallback)* | Keep a **list** of content roots; `kiwix-serve` is started with ZIMs from *all* roots, the librarian picks the fill target (most free space, respecting caps), and the server serves from each. No extra filesystem. | macOS/Windows or when mergerfs isn't present. |

Either way, the app logic is the same: **a list of content volumes**, each mounted or not,
each with free space, health, and the content it carries.

## Adding storage — "plug it in, tap Add"

1. Owner plugs in a USB DAS / drive.
2. Val Ark **detects the new block device/mount** and shows a gentle prompt on the
   Storage page / Home: *"Found a new 8 TB drive. Add it to Val Ark's storage?"* with the
   drive's label and free space.
3. On confirm: format-if-needed (Summary-gated, type-to-confirm only if it must erase —
   the QNAP Initialize pattern; never silent), create the `content`/`models` layout on it,
   and **join it to the pool** (mergerfs branch or the content-root list). A friendly
   *"Added — Val Ark now has 14 TB. New downloads can use it."*
4. Nothing moves automatically; the drive simply becomes available capacity. Optional
   *"Balance"* action rebalances/moves cold content onto it in the background.

## Removing storage — "safely remove," and unplug-safe

1. Owner taps **Safely remove** next to a drive → Val Ark quiesces writes to it, flushes,
   drops it from the pool, unmounts, and says *"Safe to unplug [Backup DAS]."*
2. Content that lived on that drive is now **unavailable, not lost**: the Library shows
   those collections as *"Needs the '[Backup DAS]' drive — reconnect it to use these,"* and
   `kiwix-serve` serves everything still present. No errors, no crash — graceful degrade.
3. **Surprise unplug** (someone yanks the USB): same graceful state, driven by a mount
   watch. The self-heal loop notices the missing branch, marks its content unavailable,
   keeps serving the rest, and raises a calm *"A drive was removed"* card
   ([errors-selfheal.md](errors-selfheal.md)) — never a black screen.
4. **Re-plug** → Val Ark recognizes the drive by a stable id (UUID/label, not `/dev/sdX`),
   auto-rejoins it, and its content is instantly back. Re-mounts survive reboots via the
   pool's own record, not brittle `/dev` paths.

## What the owner sees (Storage page)

```
Storage — 3.1 TB used of 14 TB
  ● NVMe (primary)     ████████░░  1.8 / 2 TB    healthy · brain + hot content
  ● Backup DAS (USB)   ██░░░░░░░░  1.3 / 8 TB    healthy · [Safely remove] [Balance]
  ○ ext HDD            —  not connected           2,140 collections here · reconnect to use
  [ + Add a drive ]                     Val Ark keeps 2% free automatically
```

- Per-drive: friendly name, used/free bar, health, mounted/disconnected, actions.
- Plain totals up top; "Free up space" (cap-aware evict) and per-category breakdown as today.

## How the engine adapts (implementation notes)

- **`valark-env.sh`** grows from a single `DATA_ROOT` to a **pool descriptor** (primary +
  ordered content volumes) persisted in `state/storage.json`. `VAL_ARK_DATA` remains the
  primary/back-compat single-volume case.
- **Fill target selection**: the librarian chooses the volume with the most free space
  (or the union handles it), still bounded by the total footprint cap.
- **`kiwix-serve`**: launched over the union path (one dir) or with ZIMs globbed from all
  content roots; `server.js` serves/archives across roots.
- **Mount identity**: track drives by UUID/label; a `state/storage.json` maps id → mount →
  role, so re-plugs and reboots are deterministic and `/dev/sdX` churn is irrelevant.
- **Health/metrics**: per-volume free space + SMART where available feed the
  [monitoring](downloads-monitoring.md) tiles and alerts.
- **Caps** apply to the *pool total* (footprint cap) and can optionally be per-drive.

## Edge cases handled by design

- **Drive fills up** → fills spill to another volume / the union rebalances; if the pool is
  full, cap-aware evict runs (pinned/requested content protected).
- **Drive removed mid-download** → that item pauses, requeues to another volume, resumes.
- **Primary must never be removable** — enforced: if the detected "largest disk" is
  removable, the wizard warns and prefers a fixed disk for the brain.
- **Moving Val Ark to a bigger disk** → an explicit "migrate primary" flow (copy brain,
  re-point), separate from adding content drives.

## Scaling across several computers — one pool, many boxes (SeaweedFS)

The pool doesn't have to be one box. Several computers can contribute storage to **one
shared Val Ark pool** using SeaweedFS (a distributed store Val Ark already mirrors as a
tool), so a household/community's spare disks across a few machines become one big,
resilient library.

- **How it looks to the owner:** the Storage page simply lists more drives — some local,
  some *"on Living-Room-PC," "on Garage-NAS."* Same add/remove/health cards; location is a
  label, not a chore. Adding a computer to the pool is a **"pair a device"** flow (scan a
  code / approve on the other box), exactly like adding a mesh node — no volumes, ports, or
  IPs typed.
- **Under the hood:** SeaweedFS runs a **master + volume servers** across the fleet; each
  box runs a volume server contributing its drives, and content is stored (optionally
  **replicated**, e.g. keep 2 copies) across them. Any box's `kiwix-serve`/web server reads
  content through the SeaweedFS filer mount, so **any node can serve any content** even if
  the physical copy is on another machine — the mesh already assumed one shared mirror; this
  makes that mirror distributed and redundant.
- **Resilience:** with replication on, a computer going offline doesn't lose content — the
  replica on another box still serves it. This is the natural upgrade from "reconnect the
  drive" (single box) to "the fleet has it covered" (several boxes).
- **Still offline-first:** SeaweedFS is LAN/tailnet-only, no cloud. The distributed pool
  works with the internet unplugged, across the local mesh.
- **Choice, not forced:** most owners run a single box (the pool above). SeaweedFS is the
  opt-in "I have a few computers, pool them" path, surfaced under Storage → *Add a computer*
  once a second node exists (progressive disclosure — hidden until relevant).

Design layering: **single-drive → multi-drive pool (mergerfs/multi-root) → multi-computer
pool (SeaweedFS)** is one continuum. The owner grows along it by "adding a drive" or
"adding a computer"; Val Ark hides which mechanism is in play.

> Grounded in the research (Synology Storage Manager "overview + one confirm," QNAP's
> Initialize erase-gate, unRAID's add-a-disk-to-the-array simplicity, and the
> content-safety invariant every NAS preserves across resets) — [research-brief.md](research-brief.md).
> Distributed layer builds on the existing mesh/NFS design in [ARCHITECTURE.md](../ARCHITECTURE.md).
