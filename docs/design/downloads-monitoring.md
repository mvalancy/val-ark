# Val Ark — Priorities, Downloads & Monitoring

Part of the [design hierarchy](README.md). How Jordan **picks what matters in plain
language** and **watches downloads** of Wikipedia/software/models simply. Today the engine
(the librarian: catalog → priority fill → cap-aware evict, plus live SSE progress) exists,
but the *controls* are `.env`/source weights and the *view* is a single progress panel.

## 0. Profiles — "class roles" sized to the owner's disk

The first, simplest lever: Val Ark **suggests a profile based on how much space it has**,
so the owner doesn't reason about model sizes vs. ZIMs — the box picks a sensible mix, then
they nudge it. The profile sets the *ceilings* (how big a model is allowed, how deep the ZIM
fill goes); the emphasis (below) sets the *tilt*.

| Profile (auto-suggested by free space) | AI models | ZIMs / Library | Tools | Feel |
|---|---|---|---|---|
| **Pocket** (≲256 GB) | tiny assistant only (1–3B) | Simple Wikipedia + How-to essentials | core apps | "the essentials, offline" |
| **Standard** (256 GB–2 TB) | up to ~7B, a few | full Wikipedia + broad topics | all apps | "a great home box" |
| **Big** (2–8 TB) | up to ~14–32B, several | many topics + languages | all apps + comms | "a community library" |
| **Max** (8 TB+) | the big ones (70B+), many | everything, all voices | everything | "hold it all" |

- The wizard shows one line: *"You've got 6 TB — I'd suggest **Big**. Change it? "* with the
  profile pre-selected. One tap accepts.
- Changing the profile later (Storage/Downloads settings) just moves the ceilings; the
  librarian re-plans within them (raising `VALARK_MODEL_MAX_GB`, widening the ZIM langs/topics,
  etc. — all hidden behind the plain profile name).
- **Adding a drive bumps the suggestion:** plug in a USB DAS and Val Ark offers *"You've got
  room for bigger AI models now — move to Max?"* Storage and profile stay in sync.

## Emphasis — "what matters most to you?"

One friendly control (three choices + balanced) that tilts the mix **within** the profile's budget:

- **Knowledge & Wikipedia** → more ZIMs, more languages/topics; models kept lean.
- **AI helpers** → bigger/more models (up to the profile ceiling); a solid but smaller Library.
- **Software & Tools** → the full app mirror across platforms first.
- **Balanced** *(default)* → a sensible split of all three.

Emphasis reweights the catalog's value scores (the same mechanism that already boosts Linux/
shell content) — so "AI helpers" makes models win the value-per-byte race, "Knowledge" makes
ZIMs win — while the profile caps how far each can go. Simple to the owner ("I mostly want
AI"), precise underneath.

## 1. "What do you want on it?" — the plain-language priority picker

Not a list of 1,900 ZIMs. A short set of **interest toggles**, each mapping to a curated
bundle the librarian prioritizes (extending the value-weight mechanism already in
`catalog.sh`):

| Toggle | Plain description | Maps to (examples) |
|--------|-------------------|--------------------|
| 📚 **Wikipedia** | All of Wikipedia, offline | `wikipedia_en_all_maxi`, simple |
| 🔧 **How-to & Repair** | Fix things, DIY, computers, Linux | iFixit, StackExchange, archlinux/askubuntu, devdocs |
| ⚕️ **Health & Medicine** | Medical & first-aid references | WikiMed, medicine ZIMs |
| 🎓 **Kids & School** | Learning for all ages | Khan-style, Wikibooks, Vikidia |
| 🗺️ **Maps & Travel** | Places, guides, survival | Wikivoyage, OSM-style, prepper refs |
| 🔬 **Science & Tech** | Math, physics, computing | topical Wikipedia + StackExchange |
| 🤖 **AI Helper** | On-box chatbots & a setup assistant | small LLMs (Qwen/Llama), llama.cpp |
| 💾 **Software & Tools** | Offline app mirror | the tools catalog (all platforms) |
| 💬 **Community apps** | Chat, mail, boards, files for my network | enable chat/mail/forum/paste |

- **Sensible starter set pre-checked** (Wikipedia + How-to + AI Helper + Software).
- A **live estimate**: *"~46 GB · fits easily in your space · ~25 min on a good connection · then works offline."*
- **When to download**: *Now* / *When the box is idle* / *Only when plugged into power* (for laptops).
- **Advanced** drawer: the full catalog browse + per-item request (already built) and raw curation weights.
- Under the hood: picks set curation priorities; the librarian fills highest-value-per-byte first within the cap, auto-evicting low-value unpinned content — exactly the engine that's built.

## 2. Watching downloads — the Downloads view

A calm, phone-friendly list. Home shows a summary card (**"⬇ 2 downloading · 61%"**); tapping
opens:

```
Downloads
  ▶ Wikipedia (English, full)        ██████████░░  61%   4.2 / 6.9 GB   ⏸  ✕
  ▶ Qwen setup assistant             ███░░░░░░░░░  22%   210 / 940 MB   ⏸  ✕
  ⏳ Up next:  How-to & Repair bundle (3 items, ~1.1 GB)          [Reorder]
  ✓ Done:      Linux docs · llama.cpp · bash/git docs
  ⚠ Trouble:   piper voices — "source was slow, retrying (3/5)"   [Details] [Retry]
```

- **Active**: progress bar, size, ETA, **Pause / Cancel** per item.
- **Up next (queue)**: what's coming, drag to reorder or "do this first."
- **Done** and **Trouble** (failures with a *plain reason* + Retry — never a raw error).
- **Global**: Pause all / Resume all; a note "downloading your priorities first."
- Driven by the existing SSE stream + the librarian queue; failures already retry — we just surface them kindly.

## 3. Storage — "how full, what's using it, free some up"

- The **storage bar** (built) with plain category labels ("Wikipedia & Library," "AI Models," "Software," "Community data").
- Per-category "how much / how many," and a **Free up space** action → the cap-aware evict, with a preview ("removes the 20 lowest-priority items, ~12 GB; your pinned picks are safe").
- "Val Ark keeps ___% free automatically" (the reserve) explained simply.

## 4. Health monitoring (summary here; detail in [admin-console.md](admin-console.md))

- Home status line: **green/amber/red + one sentence**.
- Health page: each service up/down with a small uptime history, disk/CPU/temp, and any alerts — the metrics stack ([Telegraf/InfluxDB](../../CLAUDE.md)) surfaced as friendly tiles, not a raw dashboard. Grafana stays under Advanced for power users.

## Principles
- **Interests, not catalogs.** Jordan picks *topics*; the box picks *files*.
- **Always show the plan.** "Priorities first," "up next," estimates — no mystery.
- **Failures are calm and recoverable.** A reason + Retry, never a stack trace ([errors-selfheal.md](errors-selfheal.md)).
- **Everything reversible.** Pause, reorder, cancel, free-up — all safe, all obvious.

> Reconcile with research (Synology Download Station queues/priorities, app-store install
> progress in Umbrel/CasaOS, router "usage" views, health-app summary→detail) —
> [research-brief.md](research-brief.md).
