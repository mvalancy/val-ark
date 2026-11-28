# docs/ — the top-level guide & reference set

The system-level docs for Val Ark: how the appliance is built and how to keep the writing about it true. Work here whenever you change what a guide describes.

↑ [Repo root](/AGENTS.md) · [Doc map](/docs/README.md)

Each file is either a **reference** (describes what the code *is* — keep it matched to the code) or a **guide** (helps a reader *do* something). Some are both. Point at the canonical owner instead of re-copying a fact.

## What's here

| File | Type | Purpose |
|------|------|---------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Reference | System architecture diagrams + component overview; the entry-point/engine/web-server/loop/mesh picture. |
| [LIBRARIAN.md](LIBRARIAN.md) | Reference | The disk-fill/curation engine, the data-root/`.env` layout, and the 24/7 loop. **Canonical** for data root, priority model, and loop steps. |
| [TOOLS.md](TOOLS.md) | Reference | Catalog of the mirrored tools and how to use them. **Canonical** for the tool set (source of truth is `scripts/tools/*.sh`). |
| [MODEL_INVENTORY.md](MODEL_INVENTORY.md) | Reference | Model families, tiers, and availability. **Canonical** for models. |
| [SECURITY-AUDIT.md](SECURITY-AUDIT.md) | Reference (dated) | Security audit + posture — a point-in-time report (Audit date 2026-06-06; line numbers frozen, see its Addendum). **Canonical** for security posture. |
| [COMMUNITY.md](COMMUNITY.md) | Both | Offline community services (chat, mail, boards, file drop) — reference for the services + guide to running them. **Canonical** for comms. |
| [ENCRYPTION.md](ENCRYPTION.md) | Guide | The local CA + TLS for the offline LAN. **Canonical** for TLS/HTTPS (link here, don't re-explain). |
| [PLATFORMS.md](PLATFORMS.md) | Guide | Per-platform setup + acceleration; the OpenWRT subset. **Canonical** for the CUDA/Metal source build. |
| [HOW-IT-WORKS.md](HOW-IT-WORKS.md) | Guide | The picture book: one moving picture per chapter, with a short caption each. Chapters are moving to storybook scenes (`img/story/`), no two in the same form; the precise flow diagram stays in the guide each chapter links to. It links out and doesn't restate the guides. |
| [SERVING.md](SERVING.md) | Guide | Static (any file share) vs dynamic (`server.js`) serving: choosing, setup for each, screenshots. **Canonical** for that choice. |
| [OFFLINE.md](OFFLINE.md) | Guide | Offline operation, P2P sync, and the NFS-shared mesh. |
| [ARM64-NAS.md](ARM64-NAS.md) | Guide | ARM64 NAS appliances (chips such as the Rockchip RK3588): setup notes + gotchas. |

The hub that indexes these is [README.md](README.md) (owned elsewhere — link it, don't restructure it). Sub-areas: [design/](design/README.md) (the scope-first product design) and [knowledge/](knowledge/README.md) (gotchas/decisions/workflow).

## Pop-up art (the chapter scenes)

Screenshots live in [`screenshots/<topic>/`](screenshots/) (`web-ui/`, `serving/`, `mirror-honesty/`, and `terminal/` once `scripts/screenshots.sh` records one); drawn art lives in [`img/`](img/).

Every human-facing doc (guides, design, knowledge, the code READMEs, CONTRIBUTING and SECURITY) opens with an animated pop-up-book scene, with a light and a dark version under [`img/popup/`](img/popup/). They are **generated**, so never hand-edit an SVG there:

- Scenes, captions and the docs each scene belongs to live in `SCENES` in [`scripts/docs/popup_art.py`](../scripts/docs/popup_art.py) (stdlib only, deterministic). Run `python3 scripts/docs/popup_art.py` to rewrite them; `--list` shows where each scene is used.
- `DOC_TREE` in the same file draws `docs-tree-{light,dark}.svg`, the whole docs hierarchy as a tree on the [doc map](README.md#the-documentation-tree) and the front page. Add a new doc to it, with its own scene.
- **Storybook scenes** (`img/story/`, #398) come from `SCENES` in [`scripts/docs/story_art.py`](../scripts/docs/story_art.py): one hand-composed scene per idea, each in its own form (so far a landscape, a ship's-hold cutaway, a night-watch frieze, an open book, a comic strip and an island map). **Anything worth telling users gets one, shipped in the same PR as the feature, and a new scene must not repeat a form already used.** Write the facts it shows into its `desc` (that is also the alt text), check them against the code, and look at it in a browser in both themes before committing. The scene must be complete with animations off. Run `python3 scripts/docs/story_art.py`; the same test checks them.
- **How-it-works diagrams** (`img/flow/`) come from `DIAGRAMS` in [`scripts/docs/flow_art.py`](../scripts/docs/flow_art.py): parts as cards, arrows with travelling dots, or a ring for a cycle. Run `python3 scripts/docs/flow_art.py`; the same test checks them. Prefer one of these over a mermaid chart for a reader-facing explanation, and keep the mermaid in a `<details>` block for the detail.
- Embed a scene as a `<picture>` with a `prefers-color-scheme: dark` `<source>` (copy an existing one). The `alt` text is the scene's title and caption.
- A caption is a claim about the doc. Keep it true, like any other line in a guide.
- [`tests/test-doc-art.sh`](../tests/test-doc-art.sh) fails if:
  - the SVGs are stale;
  - an SVG has a script, an external reference, or no `<title>`/`<desc>`;
  - an SVG skips `prefers-reduced-motion`, or goes over 40 KB;
  - a scene isn't used as a light/dark pair;
  - a doc listed in a scene's or diagram's `used=` doesn't embed it;
  - a tracked human-facing doc is missing from `DOC_TREE` (nested `AGENTS.md`, `.github/` and `.agents/` skills are exempt).
- The resting state is the fully opened scene, so reduced motion (and any renderer that won't animate) shows the finished picture.

## Canonical source — edit the owner, link everywhere else

One fact, one home. Change it in the owning doc; from any other doc, link — never restate.

| Fact / concept | Canonical owner | Notes |
|----------------|-----------------|-------|
| Data root + `.env` layout | [LIBRARIAN.md](LIBRARIAN.md) | "Where data lives" section. |
| Curation priority model | [LIBRARIAN.md](LIBRARIAN.md) | essentials, then apps → library → models → bulk (#347), each diversity → small-valuable → fill; `evict` / `request` trade up (fill never evicts; it only drops a smaller copy once a fuller version of the same item is on disk). |
| 24/7 loop steps + `state/selfheal.json` / `state/heal-events.jsonl` | [LIBRARIAN.md](LIBRARIAN.md) | Keep [ARCHITECTURE.md](ARCHITECTURE.md)'s Self-Healing Loop diagram **in sync** with it. |
| CUDA / Metal source build | [PLATFORMS.md](PLATFORMS.md) | GPU llama.cpp / whisper.cpp / sd.cpp on aarch64. |
| Tool catalog | [TOOLS.md](TOOLS.md) | Backed by `scripts/tools/*.sh`. |
| Models | [MODEL_INVENTORY.md](MODEL_INVENTORY.md) | Plus `data/models-extra.tsv` (diversity). |
| Security posture | [SECURITY-AUDIT.md](SECURITY-AUDIT.md) | Dated report + Addendum. |
| TLS / HTTPS | [ENCRYPTION.md](ENCRYPTION.md) | The local CA. |
| Community / comms | [COMMUNITY.md](COMMUNITY.md) | Services + reverse-proxy model. |
| Static vs dynamic serving | [SERVING.md](SERVING.md) | How the static pages are built stays in [LIBRARIAN.md](LIBRARIAN.md#static-browse-pages). |

## How to work here

- **Every guide describes real code.** After you change `scripts/server.js`, `scripts/loop.sh`, `scripts/librarian.sh`, a tool script under `scripts/tools/`, or `web-ui/`, update the owning doc **in the same change** — a stale guide is a bug.
- **Verify before you write.** Grep the code for the exact behavior; don't restate a number or a filename from memory or from another doc.
- **Relative links only**, ` · ` separators, and no host names / IPs / creds / host paths (the repo is PUBLIC).

## Gotchas

- **The loop writes `state/selfheal.json` + `state/heal-events.jsonl`, not `state/health.json`.** `state/health.json` is the **librarian's** `maintain` report (`scripts/librarian.sh`); the loop's self-heal snapshot is `selfheal.json` and its healed-events feed is `heal-events.jsonl` (`scripts/loop.sh`). Several docs have gotten this wrong — check any "loop writes health.json" claim. See [knowledge/gotchas.md](knowledge/gotchas.md#health--self-heal-phase-6).
- **The tool count is duplicated across many files** (README, CLAUDE.md, ARCHITECTURE). Reference [TOOLS.md](TOOLS.md) / `scripts/tools/*.sh` as the source — don't restate a number that will drift.
- **[SECURITY-AUDIT.md](SECURITY-AUDIT.md) is a dated point-in-time report.** Its findings and line numbers reflect the tree as scanned; read the dated addendum for current status rather than "fixing" the frozen body. Offline gaps live as `offline-gap` issues (epic #384), not in a doc.
- **PUBLIC repo.** No host names, local IPs, tailnet names, creds, or host paths in any doc — roles and placeholders only.

## Related

- [design/AGENTS.md](design/AGENTS.md) — the scope-first product design hierarchy.
- [knowledge/AGENTS.md](knowledge/AGENTS.md) — gotchas / decisions / workflow / governance.
- [../AGENTS.md](../AGENTS.md) · [../CLAUDE.md](../CLAUDE.md) — the pipeline and the codebase guide.
