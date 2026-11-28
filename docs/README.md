<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/popup/docs-map-dark.svg">
  <img src="img/popup/docs-map-light.svg" width="100%" alt="Pop-up book scene: Every page of the Ark. Start here, then follow the paths to any guide.">
</picture>

# Val Ark Documentation — the doc map

The **one canonical index** of every doc in the repo: what it is, where it lives, and where
to start. Val Ark is an online-optional, local-first mirror of dev/AI tools, AI models, and
offline content (ZIM via Kiwix), with a zero-dependency web UI.

## Start here

| I am… and I want to… | Go to |
|----------------------|-------|
| **A person** getting oriented | [`../README.md`](../README.md) — project front page |
| **An AI agent** about to make a change | [`../AGENTS.md`](../AGENTS.md) (operating manual) + the auto-loaded [`../CLAUDE.md`](../CLAUDE.md) |
| To know **why** something was built a certain way | [`knowledge/decisions.md`](knowledge/decisions.md) |
| To avoid a **known trap** while coding | [`knowledge/gotchas.md`](knowledge/gotchas.md) |
| To understand the **appliance design** | [`design/README.md`](design/README.md) |
| To **choose what goes on your Ark** and in what order | [`CHOOSING-CONTENT.md`](CHOOSING-CONTENT.md) |
| To see **how it all works**, in pictures | [`HOW-IT-WORKS.md`](HOW-IT-WORKS.md) |
| To **share an Ark**: static file share or live web server | [`SERVING.md`](SERVING.md) |
| To **run the tests** | [`../tests/AGENTS.md`](../tests/AGENTS.md) |

## The documentation tree

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/popup/docs-tree-dark.svg">
  <img src="img/popup/docs-tree-light.svg" width="100%" alt="The documentation tree: the README leads to the docs map, the workshop guides, the policies and the AI-agent manuals; the docs map branches into the guides, the design hierarchy and the knowledge base. Each page at the tip of a branch shows its file path.">
</picture>

The tree is drawn by [`scripts/docs/popup_art.py`](../scripts/docs/popup_art.py) from its
`DOC_TREE` list, and `tests/test-doc-art.sh` fails if a tracked human-facing doc is missing from it (see
[Pop-up art](AGENTS.md#pop-up-art-the-chapter-scenes) for what is exempt).
Every guide on it opens with its own pop-up scene.

Every important folder also carries its own `AGENTS.md` (local operating notes) and/or a
`README.md`; they are inventoried below.

## Master inventory

Every tracked `.md`, grouped. The source of truth for "did we document it?" is
`git ls-files '*.md'` — keep this table in sync with it (see [Keeping this map in
sync](#keeping-this-map-in-sync)).

### Root governance

| File | Purpose |
|------|---------|
| [`../README.md`](../README.md) | Project front page: what an Ark is, screenshots, quick start, static vs dynamic, and the docs tree. |
| [`../CLAUDE.md`](../CLAUDE.md) | Codebase guide + rules, **auto-loaded every session**; the "how to add a tool" checklist. |
| [`../AGENTS.md`](../AGENTS.md) | AI-agent operating manual: prime directives, the delivery pipeline, definition of done. |
| [`../CONTRIBUTING.md`](../CONTRIBUTING.md) | Contributor entry point; points at the authoritative workflow + knowledge base. |
| [`../SECURITY.md`](../SECURITY.md) | Security policy and trust posture (offline LAN/tailnet appliance, not internet-exposed). |

### docs/ — reference guides

| File | Purpose |
|------|---------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture diagrams and component overview. |
| [COMMUNITY.md](COMMUNITY.md) | Offline community services: chat, mail, boards, and file drop. |
| [SECURITY-AUDIT.md](SECURITY-AUDIT.md) | Security audit and posture: repo, web server, scripts, runtime. |
| [ENCRYPTION.md](ENCRYPTION.md) | Local certificate authority and TLS for the offline LAN. |
| [LIBRARIAN.md](LIBRARIAN.md) | The self-filling, self-healing engine: scalable disk-fill, curation, and the 24/7 loop. |
| [TOOLS.md](TOOLS.md) | Catalog of the mirrored tools and their usage (source of truth: the web-ui TOOLS array / tests `TOOL_IDS`). |
| [PLATFORMS.md](PLATFORMS.md) | Supported platforms and chips, including builds and the OpenWRT subset. |
| [ARM64-NAS.md](ARM64-NAS.md) | ARM64 NAS appliances (chips such as the Rockchip RK3588): setup notes and gotchas. |
| [HOW-IT-WORKS.md](HOW-IT-WORKS.md) | The picture book: ten animated diagrams in reading order, from one disk to a whole network, each linking to the guide that goes deeper. |
| [CHOOSING-CONTENT.md](CHOOSING-CONTENT.md) | How an owner chooses and prioritises content: the setup focus, Settings → Downloads & Priorities, requests and pins, and the `.env` limits. |
| [SCREENSHOTS.md](SCREENSHOTS.md) | The web UI on a running Ark: home, software, library, models and a tool's page. |
| [SERVING.md](SERVING.md) | The two ways to serve an Ark, static (any file share) or dynamic (the web server): how to choose, step-by-step setup, screenshots, security. |
| [OFFLINE.md](OFFLINE.md) | Offline operation, P2P sync, and the NFS-shared mesh. |
| [MODEL_INVENTORY.md](MODEL_INVENTORY.md) | Model families, tiers, and availability. |
| [AGENTS.md](AGENTS.md) | Operating notes for writing and maintaining these reference guides. |

### docs/design/ — consumer-appliance architecture (scope-first)

Start at [design/README.md](design/README.md). The scope-first set: [vision](design/vision.md) ·
[commissioning](design/commissioning.md) · [admin-console](design/admin-console.md) ·
[access-identity](design/access-identity.md) · [recovery](design/recovery.md) ·
[storage](design/storage.md) · [downloads-monitoring](design/downloads-monitoring.md) ·
[errors-selfheal](design/errors-selfheal.md) · [safety-moderation](design/safety-moderation.md) ·
[deployment](design/deployment.md) · [roadmap](design/roadmap.md) ·
[research-brief](design/research-brief.md) · [current-state](design/current-state.md).
Operating notes for editing this set: [design/AGENTS.md](design/AGENTS.md).

### docs/knowledge/ — the git-tracked shared brain

| File | Purpose |
|------|---------|
| [knowledge/README.md](knowledge/README.md) | How the shared brain works and where each kind of knowledge goes. |
| [knowledge/decisions.md](knowledge/decisions.md) | Architecturally significant decisions + progress log (context → decision → why). |
| [knowledge/gotchas.md](knowledge/gotchas.md) | Operational gotchas & hard-won fixes (symptom → cause → fix). |
| [knowledge/workflow.md](knowledge/workflow.md) | Git / branch / PR / parallelization strategy. |
| [knowledge/governance.md](knowledge/governance.md) | Self-guided agent governance, CI & trust model (implemented by `.agents/`). |
| [knowledge/AGENTS.md](knowledge/AGENTS.md) | Operating notes for baking learnings into the shared brain. |

### .agents/ — the agents' operating manual (skills + pipeline knowledge)

| File | Purpose |
|------|---------|
| [../.agents/README.md](../.agents/README.md) | Index of the agent skills + operational knowledge. |
| [../.agents/skills/worker-protocol.md](../.agents/skills/worker-protocol.md) | Implement one issue as a reviewable PR (branch → fix → test → PR). |
| [../.agents/skills/review.md](../.agents/skills/review.md) | Review a PR or release diff (Gate 1 / Gate 2). |
| [../.agents/skills/issue-discovery.md](../.agents/skills/issue-discovery.md) | Hunt for real, confirmed issues to file. |
| [../.agents/skills/release.md](../.agents/skills/release.md) | Cut a `dev → main` release and tag it. |
| [../.agents/skills/recovery.md](../.agents/skills/recovery.md) | Resume after a restart / limit / dead worker without losing work. |
| [../.agents/knowledge/pipeline-insights.md](../.agents/knowledge/pipeline-insights.md) | Hard-won operational insights about running the multi-agent pipeline. |

### Per-folder AGENTS.md + READMEs

Each important folder carries local operating notes.

| Folder | Docs |
|--------|------|
| `scripts/` | [scripts/AGENTS.md](../scripts/AGENTS.md) · [scripts/README.md](../scripts/README.md) — orchestration, curation, server layer. |
| `scripts/lib/` | [scripts/lib/AGENTS.md](../scripts/lib/AGENTS.md) — data-root resolution + catalog/planner internals, the mirror CLIs (release: loop step 5d; APT / git-bundle, run by hand; Lastbook / references / OCI, driven by `scripts/tools/*.sh`), auth + commissioning, moderation, TLS. |
| `scripts/docs/` | `popup_art.py` (the pop-up scenes and the docs tree) and `flow_art.py` (the animated how-it-works diagrams); see [Pop-up art](AGENTS.md#pop-up-art-the-chapter-scenes). |
| `scripts/services/` | [scripts/services/AGENTS.md](../scripts/services/AGENTS.md) — offline community service launchers (chat/mail/forum/paste/gitea/seaweedfs). |
| `scripts/tools/` | [scripts/tools/AGENTS.md](../scripts/tools/AGENTS.md) · [scripts/tools/README.md](../scripts/tools/README.md) — per-tool mirror scripts + `_common.sh` helpers. |
| `tests/` | [tests/AGENTS.md](../tests/AGENTS.md) · [tests/README.md](../tests/README.md) — one runner → offline HTML report. |
| `tests/lib/`, `tests/fixtures/` | Shared test helpers (results, ports, doc-link / secret / port-hygiene checkers) and offline fixtures (see [tests/README.md](../tests/README.md)). |
| `tests/screenshots/` | [tests/screenshots/AGENTS.md](../tests/screenshots/AGENTS.md) — Playwright specs, parametrized over the catalog. |
| `web-ui/` | [web-ui/AGENTS.md](../web-ui/AGENTS.md) · [web-ui/README.md](../web-ui/README.md) — zero-dep SPA (TOOLS array, TOOL_META, logos, screenshots). |
| `data/` | [data/AGENTS.md](../data/AGENTS.md) — the catalog TSVs (installers, models-extra, essentials, dev-stack, apt-sets, source-repos, dev-stack-checks) and their schemas, plus the dev-stack offline guides (`data/dev-stack-guides/`). |
| `docs/` | [docs/AGENTS.md](AGENTS.md) — the reference guides (this folder). |
| `docs/screenshots/` | Screenshots by topic: `web-ui/`, `serving/`, `mirror-honesty/`, and `terminal/` once `scripts/screenshots.sh` records one. |
| `docs/img/` | Drawn art: `hero/` and the generated `popup/` scenes and docs tree. |
| `docs/design/` | [docs/design/AGENTS.md](design/AGENTS.md) — the scope-first design set. |
| `docs/knowledge/` | [docs/knowledge/AGENTS.md](knowledge/AGENTS.md) — the shared brain. |
| `.github/` | [.github/AGENTS.md](../.github/AGENTS.md) — issue/PR templates + CI notes. |

### .github/ — templates

| File | Purpose |
|------|---------|
| [../.github/ISSUE_TEMPLATE/agent-task.md](../.github/ISSUE_TEMPLATE/agent-task.md) | Well-scoped, autonomous-agent-ready job (maintainer-authored). |
| [../.github/ISSUE_TEMPLATE/bug.md](../.github/ISSUE_TEMPLATE/bug.md) | Bug report template. |
| [../.github/ISSUE_TEMPLATE/feature.md](../.github/ISSUE_TEMPLATE/feature.md) | Feature request template. |
| [../.github/PULL_REQUEST_TEMPLATE.md](../.github/PULL_REQUEST_TEMPLATE.md) | One-focused-job PR template. |

## Key concepts

- **Configurable data root** — all bulk data lives on one disk resolved from a
  git-ignored `.env` (see [`.env.example`](../.env.example)) or autodetected; the
  repo's dirs are symlinked to it. Scales to any disk size. Logic in
  `scripts/lib/valark-env.sh`. See [LIBRARIAN.md](LIBRARIAN.md).
- **Librarian engine** — `scripts/librarian.sh` fills a disk from live catalogs
  in priority order (grid-down essentials, then apps → library → models → bulk, each diversity → small-valuable → fill-remaining;
  `evict` and `request` trade up when room is needed), using aria2 multi-connection downloads with curl fallback. It
  curates hundreds of catalog items — 50+ tool mirror scripts (`scripts/tools/*.sh`),
  models and the live Kiwix library. See [LIBRARIAN.md](LIBRARIAN.md).
- **Offline build & survival kit** — `data/essentials.tsv` front-loads the grid-down
  essentials, then apps and the library before more models; the loop mirrors a developer +
  security stack, standalone mirror CLIs (run by hand) build offline APT repos and git
  bundles of upstream source, and the tool mirrors keep Lastbook
  and container images current, for a LAN with no internet.
  See [OFFLINE.md](OFFLINE.md#what-else-works-offline).
- **24/7 self-healing loop** — `scripts/loop.sh` + `scripts/verify.sh` repair
  symlinks, keep services up, self-mirror Val Ark's source, refresh the live Kiwix
  catalog, link-check, integrity-verify, re-fill pins, top-up fill, sweep uploads
  through moderation, and confirm apps actually run (including remote mesh nodes).
- **Mesh** — the data root is NFS-exportable so fleet nodes mount one shared
  mirror and run GPU inference over the network. See [OFFLINE.md](OFFLINE.md).
- **Web server** — `scripts/server.js` (zero-dep Node) serves the UI, a JSON API,
  and SSE, and auto-launches `kiwix-serve` for any complete ZIM. See
  [ARCHITECTURE.md](ARCHITECTURE.md).
- **Static browse pages** — `scripts/librarian.sh site` writes `index.html` + `browse/` at the
  archive root: plain HTML with relative links, so any file share can serve the archive with no
  server running. Static vs dynamic (when to use which): [SERVING.md](SERVING.md); how the pages
  are built: [LIBRARIAN.md](LIBRARIAN.md#static-browse-pages).

## Pop-up art

The animated chapter scenes at the top of the guides are generated by
[`scripts/docs/popup_art.py`](../scripts/docs/popup_art.py) into [`img/popup/`](img/popup/)
(light + dark pairs) and guarded by [`tests/test-doc-art.sh`](../tests/test-doc-art.sh).
How to add or change one: [`AGENTS.md` → Pop-up art](AGENTS.md#pop-up-art-the-chapter-scenes).

## Keeping this map in sync

This is the **one canonical index** — keeping it current is part of the definition of done.
When you add, remove, or rename a tracked `.md`, update this file in the same change:

1. Add/adjust its row in the matching group above.
2. If it is a human-facing doc, add it to `DOC_TREE` in `scripts/docs/popup_art.py`, give it a
   pop-up scene (`SCENES`), and run `python3 scripts/docs/popup_art.py`. A new folder also goes
   in the per-folder table.
3. Sanity-check with `git ls-files '*.md'` — every path it prints must appear here.

---

↑ [Repo root](../README.md) · [Agent manual](../AGENTS.md) · [Design](design/README.md) · [Knowledge base](knowledge/README.md) · [.agents](../.agents/README.md)
