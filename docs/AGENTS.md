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
| [OFFLINE-GAPS.md](OFFLINE-GAPS.md) | Reference (dated) | "Internet went off today" gap analysis — a point-in-time report (Updated 2026-07-10). |
| [SECURITY-AUDIT.md](SECURITY-AUDIT.md) | Reference (dated) | Security audit + posture — a point-in-time report (Audit date 2026-06-06; line numbers frozen, see its Addendum). **Canonical** for security posture. |
| [COMMUNITY.md](COMMUNITY.md) | Both | Offline community services (chat, mail, boards, file drop) — reference for the services + guide to running them. **Canonical** for comms. |
| [ENCRYPTION.md](ENCRYPTION.md) | Guide | The local CA + TLS for the offline LAN. **Canonical** for TLS/HTTPS (link here, don't re-explain). |
| [PLATFORMS.md](PLATFORMS.md) | Guide | Per-platform setup + acceleration; the OpenWRT subset. **Canonical** for the CUDA/Metal source build. |
| [OFFLINE.md](OFFLINE.md) | Guide | Offline operation, P2P sync, and the NFS-shared mesh. |
| [ARM64-NAS.md](ARM64-NAS.md) | Guide | ARM64 NAS appliances (chips such as the Rockchip RK3588): setup notes + gotchas. |

The hub that indexes these is [README.md](README.md) (owned elsewhere — link it, don't restructure it). Sub-areas: [design/](design/README.md) (the scope-first product design) and [knowledge/](knowledge/README.md) (gotchas/decisions/workflow).

## Canonical source — edit the owner, link everywhere else

One fact, one home. Change it in the owning doc; from any other doc, link — never restate.

| Fact / concept | Canonical owner | Notes |
|----------------|-----------------|-------|
| Data root + `.env` layout | [LIBRARIAN.md](LIBRARIAN.md) | "Where data lives" section. |
| Curation priority model | [LIBRARIAN.md](LIBRARIAN.md) | diversity → small-valuable → fill → evict. |
| 24/7 loop steps + `state/selfheal.json` / `state/heal-events.jsonl` | [LIBRARIAN.md](LIBRARIAN.md) | Keep [ARCHITECTURE.md](ARCHITECTURE.md)'s Self-Healing Loop diagram **in sync** with it. |
| CUDA / Metal source build | [PLATFORMS.md](PLATFORMS.md) | GPU llama.cpp / whisper.cpp / sd.cpp on aarch64. |
| Tool catalog | [TOOLS.md](TOOLS.md) | Backed by `scripts/tools/*.sh`. |
| Models | [MODEL_INVENTORY.md](MODEL_INVENTORY.md) | Plus `data/models-extra.tsv` (diversity). |
| Security posture | [SECURITY-AUDIT.md](SECURITY-AUDIT.md) | Dated report + Addendum. |
| TLS / HTTPS | [ENCRYPTION.md](ENCRYPTION.md) | The local CA. |
| Community / comms | [COMMUNITY.md](COMMUNITY.md) | Services + reverse-proxy model. |

## How to work here

- **Every guide describes real code.** After you change `scripts/server.js`, `scripts/loop.sh`, `scripts/librarian.sh`, a tool script under `scripts/tools/`, or `web-ui/`, update the owning doc **in the same change** — a stale guide is a bug.
- **Verify before you write.** Grep the code for the exact behavior; don't restate a number or a filename from memory or from another doc.
- **Relative links only**, ` · ` separators, and no host names / IPs / creds / host paths (the repo is PUBLIC).

## Gotchas

- **The loop writes `state/selfheal.json` + `state/heal-events.jsonl`, not `state/health.json`.** `state/health.json` is the **librarian's** `maintain` report (`scripts/librarian.sh`); the loop's self-heal snapshot is `selfheal.json` and its healed-events feed is `heal-events.jsonl` (`scripts/loop.sh`). Several docs have gotten this wrong — check any "loop writes health.json" claim. See [knowledge/gotchas.md](knowledge/gotchas.md#health--self-heal-phase-6).
- **The tool count is duplicated across many files** (README, CLAUDE.md, ARCHITECTURE). Reference [TOOLS.md](TOOLS.md) / `scripts/tools/*.sh` as the source — don't restate a number that will drift.
- **[OFFLINE-GAPS.md](OFFLINE-GAPS.md) and [SECURITY-AUDIT.md](SECURITY-AUDIT.md) are dated point-in-time reports.** Their findings and line numbers reflect the tree as scanned; read the dated addendum for current status rather than "fixing" the frozen body.
- **PUBLIC repo.** No host names, local IPs, tailnet names, creds, or host paths in any doc — roles and placeholders only.

## Related

- [design/AGENTS.md](design/AGENTS.md) — the scope-first product design hierarchy.
- [knowledge/AGENTS.md](knowledge/AGENTS.md) — gotchas / decisions / workflow / governance.
- [../AGENTS.md](../AGENTS.md) · [../CLAUDE.md](../CLAUDE.md) — the pipeline and the codebase guide.
