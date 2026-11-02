# Val Ark — Home Screen & Admin Console

Part of the [design hierarchy](README.md). Defines the two surfaces: the **Home screen**
(what everyone sees — a calm health-app summary) and the **Admin console** (settings/system,
admin-gated). Today there is neither; the UI is a catalog only.

## Home screen — a status, not a control panel

Modeled on a fitness-app summary: the first thing you see is **"is it well?"**, then a few
big cards, then detail on tap.

```
┌─────────────────────────────────────────────────────────────┐
│  Val Ark            valark.local            [☰ / avatar]      │
│                                                              │
│  ●  All good                       Library 92% full · 2 downloading
│  ───────────────────────────────────────────────────────    │
│  [ 📚 Library ]   [ 🤖 AI Helper ]   [ 💬 Community ]         │  ← big tappable cards,
│   1,174 sets       Ready · Qwen       Chat·Mail·Boards        │     each = a whole area
│   Ready            Ask me anything    3 online                │
│                                                              │
│  [ ⬇ Downloads (2) ]   [ 💽 Storage ]   [ ⚙ Settings ]        │
│   Wikipedia 61% …      3.1 / 7 TB       admin                 │
└─────────────────────────────────────────────────────────────┘
```

- **One status line up top**: `● All good` / `● Working on it` / `● Needs you` (green/amber/red) — the single glance answer, driven by [health](#health) + [errors](errors-selfheal.md).
- **Big area cards**: Library, AI Helper, Community — tap to enter that experience (today's sections).
- **Utility cards**: Downloads (with live progress), Storage, Settings.
- An **"Ask Val Ark"** affordance (the offline assistant) is always one tap away — it can answer "how do I…" and, where safe, do it.
- Everyone sees this (per Use Mode). The **Settings** card only *acts* as admin (prompts for the passcode from the LAN; free on the box/localhost).

## Admin console — information architecture

A single **Settings** list, each item a simple page. Plain names first; the `env`/CLI
equivalent is noted only here for us, never shown to Jordan.

| Section | Plain purpose | Covers (today's mechanics) |
|---------|---------------|----------------------------|
| **Storage** | How much space, what's using it, free some up | disk & `VAL_ARK_DATA`, `VALARK_MAX_GB`, storage breakdown, evict/cleanup, add/replace disk |
| **Downloads & Priorities** | Pick what matters; watch & control downloads | topic picker → curation weights, queue, active (SSE), pause/resume/cancel, "get more" catalog |
| **Apps & Services** | Turn features on/off; manage app accounts | `VALARK_SERVICES` (chat/mail/forum/paste) start/stop + [registration](../COMMUNITY.md), AI/tools status + mirror |
| **Network & Access** | The box's name/address; who can get in | hostname/mDNS, port 80, HTTPS/CA ([guide](../ENCRYPTION.md)), Use Mode + admin ([access-identity.md](access-identity.md)) |
| **Users** *(Accounts mode)* | Add people, set who's admin | accounts, roles, per-app access, audit line |
| **Health** | Is everything running? Any alerts? | service uptime, disk/CPU/temp, the metrics stack, alert rules |
| **Activity** | What happened, and any problems | plain event feed + advanced raw logs + one-click repairs ([errors-selfheal.md](errors-selfheal.md)) |
| **Update** | Get the latest, safely | update from a source Ark or the internet, changelog, **rollback** |
| **Backup & Replicate** | Copy Val Ark to another box | the offline [bootstrap/self-replication](../../bootstrap.sh), config backup/restore |
| **About & Rescue** | Version, reset, rescue | version/build, factory reset, rescue mode ([recovery.md](recovery.md)) |

### IA principles
- **Home = summary, Settings = the list above.** Two levels, no deep trees.
- **Every settings page: current state on top, the common action as a big button, "Advanced" collapsed.** (e.g. Storage shows the bar + "Free up space", with the raw cap slider under Advanced.)
- **Read is open per Use Mode; every *change* is admin.** The gear is visible to all but gated on action.
- **The assistant is embedded per page**: "Not sure? Ask Val Ark" gives context help drawn from the on-box docs.

## <a name="health"></a>Health, at two depths
- **Glance** (home status line + the Health card): green/amber/red + one sentence.
- **Detail** (Health page): each service with an up/down history sparkline, disk/temp, and any alerts — the [monitoring stack](../../CLAUDE.md) rendered simply (not a raw Grafana dump; Grafana stays available for power users under Advanced).

## Mapping to today's UI
- Keep Home / Library / Community / AI (Models+tools) as the **public areas** (the big cards).
- Add the **Settings** area (new) with the sections above.
- Fold Getting Started into the **commissioning wizard** (first boot) + contextual help, rather than a static page.

> Reconcile the menu grouping with research (Synology **Control Panel** categories, Home
> Assistant **Settings** + **Repairs**, router admin tabs, unRAID/TrueNAS dashboards) —
> see [research-brief.md](research-brief.md).
