<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../img/popup/decisions-dark.svg">
  <img src="../img/popup/decisions-light.svg" width="100%" alt="Pop-up book scene: Why it is this way. Each big call: the context, the decision and the reason. Newest first.">
</picture>

# Val Ark — Decisions & Progress Log

Architecturally significant decisions and notable progress, newest first. Format:
**context → decision → why.** Append when you make a call worth remembering (or reversing
later). See [README](README.md).

## Index

> Newest first, mirroring the body order. **Append new decisions at the top of the body and add a
> matching row at the top of this table.**

| Date | Decision | Issue / Phase |
|------|----------|---------------|
| 2026‑11 | [Dev-stack apps get generated cards + guides + checks, not hand-written TOOLS entries](#202611--dev-stack-apps-get-generated-cards--guides--checks-not-hand-written-tools-entries-397) | #397 |
| 2026‑11 | [Apps and the library before AI models: class order, app mirrors before the fill](#202611--apps-and-the-library-before-ai-models-class-order-app-mirrors-before-the-fill-347) | #347 |
| 2026‑11 | [Offline gaps live in issues, not a doc](#202611--offline-gaps-live-in-issues-not-a-doc-384) | #384 |
| 2026‑11 | [Setup keeps its promises: a .local name when avahi can, a first fill, the cron is the admin's call](#202611--setup-keeps-its-promises-a-local-name-when-avahi-can-a-first-fill-the-cron-is-the-admins-call-306) | #306 |
| 2026‑11 | [Docs as a picture book: a short README and a generated docs tree](#202611--docs-as-a-picture-book-a-short-readme-and-a-generated-docs-tree-282) | #282 |
| 2026‑11 | [Grid-down essentials tier + survival profile](#202611--grid-down-essentials-tier--survival-profile) | |
| 2026‑11 | [Static browse pages for server-less archives](#202611--static-browse-pages-for-server-less-archives-257) | #257 |
| 2026‑11 | [Lastbook: auto-sized by default, every pack opt-in](#202611--lastbook-auto-sized-by-default-every-pack-opt-in-181) | #181 |
| 2026‑11 | [cad-agent references: a private, content-addressed archive of every cited source](#202611--cad-agent-references-a-private-content-addressed-archive-of-every-cited-source-cad-agent323) | cad-agent#323 |
| 2026‑11 | [Python wheelhouses + container archives as tool artifacts](#202611--python-wheelhouses--container-archives-as-tool-artifacts-149) | #149 |
| 2026‑07 | [CI guards: doc-link integrity + secret/host-leak scan](#202607--ci-guards-doc-link-integrity--secrethost-leak-scan-130) | #130 |
| 2026‑07 | [Notification center: bell/inbox slice 1](#202607--notification-center-bellinbox-slice-1-69) | #69 |
| 2026‑07 | ["Ask Val Ark": an offline ask endpoint reusing the moderation runtime](#202607--ask-val-ark-slice-1-an-offline-ask-endpoint-that-reuses-the-moderation-runtime-phase-8-67) | Phase 8 · #67 |
| 2026‑07 | [Four‑tab consumer nav: Home · Library · Activity · Settings](#202607--fourtab-consumer-nav-home--library--activity--settings-61--epic-91-slice-1) | #61 · epic #91 |
| 2026‑07 | [Packages manifest: `/api/packages` = present inventory, not the catalog](#202607--packages-manifest-served-apipackages--present-inventory-not-the-catalog-89-slice-1) | #89 |
| 2026‑07 | [Release tags: unprefixed 0.x, minted by release.sh from VERSION](#202607--release-tags-unprefixed-0x-minted-by-releasesh-from-the-version-file-64) | #64 |
| 2026‑07 | [Safety card ships without "restore"; review is remove/dismiss only](#202607--safety-card-ships-without-restore-review-is-removedismiss-only-phase-7-4n) | Phase 7 (4/n) |
| 2026‑07 | [Moderation ENFORCEMENT is a post-store loop sweep](#202607--moderation-enforcement-is-a-post-store-loop-sweep-phase-7-3n) | Phase 7 (3/n) |
| 2026‑07 | [Community chat is open (no-login) by default](#202607--community-chat-is-open-no-login-by-default) | — |
| 2026‑07 | [Versioning re-baselined to honest pre‑1.0 (0.1.x)](#202607--versioning-re-baselined-to-honest-pre10-01x) | — |
| 2026‑07 | [Reframe to a consumer appliance (scope‑first)](#202607--reframe-to-a-consumer-appliance-scopefirst) | — |
| 2026‑07 | [Live host metrics, live-first](#202607--live-host-metrics-live-first-roadmap-phase-6-part-2--monitoring) | Phase 6 (pt 2) |
| 2026‑07 | [On-device moderation: fail-closed decision core first](#202607--on-device-moderation-fail-closed-decision-core-first-phase-7) | Phase 7 |
| 2026‑07 | [Metrics HISTORY is a zero-dep ring buffer](#202607--metrics-history-is-a-zero-dep-ring-buffer-phase-6b-part-2) | Phase 6b (pt 2) |
| 2026‑07 | [Health & Repairs page](#202607--health--repairs-page-roadmap-phase-6-part-1--self-heal-ux) | Phase 6 (pt 1) |
| 2026‑07 | [Download queue as the monitoring surface](#202607--download-queue-as-the-monitoring-surface-roadmap-phase-5-part-1) | Phase 5 (pt 1) |
| 2026‑07 | [Access-mode enforcement + admin sessions](#202607--access-mode-enforcement--admin-sessions-roadmap-phase-2-depth) | Phase 2 depth |
| 2026‑07 | [Consumer shell: Home status + Settings + Activity](#202607--consumer-shell-home-status--settings--activity-roadmap-phase-3-issue-12) | Phase 3 · #12 |
| 2026‑07 | [First‑boot commissioning wizard](#202607--firstboot-commissioning-wizard-roadmap-phase-1-issue-11) | Phase 1 · #11 |
| 2026‑07 | [Access identity + recovery foundation](#202607--access-identity--recovery-foundation-roadmap-phase-2-issue-10) | Phase 2 · #10 |
| 2026‑07 | [First `dev → main` release (v1.1.0) + community sign‑ups](#202607--first-dev--main-release-v110--community-signups-pr-23) | PR #2/#3 |
| 2026‑07 | [Feature branch: discover/request + self‑replication + tests](#202607--feature-branch-discoverrequest--selfreplication--tests-pr-1) | PR #1 |
| — | [Earlier project facts (fleet, curation)](#earlier-project-facts-fleet-curation) | — |

---

## 2026‑11 — Dev-stack apps get generated cards + guides + checks, not hand-written TOOLS entries (#397)
**Context:** fifteen `offline-gap` issues each asked for the same three things for an app
`data/dev-stack.tsv` already mirrors: a Software card, an install hint and a check that it runs.
The Software page's way of doing that is the "Adding a New Tool" checklist: a `TOOLS` entry, a
`TOOL_META` entry, a logo, a screenshot, a tool script and a spec id, per app.
- **Decision.** Dev-stack apps do not get `TOOLS` entries. **Library ▸ Developer stack** is
  generated: `GET /api/devstack` (`scripts/lib/devstack.js`) joins the list with what the box
  holds, and the page draws one card per row. The install hint is a guide file
  (`data/dev-stack-guides/<key>.md`), shown on the card and written beside the files as
  `INSTALL.txt` by `release_mirror.py`. The run check is a row in `data/dev-stack-checks.tsv`,
  run by `verify.sh verify_devstack`.
- **Why.** The list has about 230 projects and changes by one line at a time. Hand-written cards
  would mean six files per app in an 8,000-line page, a second mirror script for files the loop
  already fetches, and a card that goes stale when a release renames its assets. A generated
  card cannot disagree with the disk: versions, files, sizes and platforms are read from it.
- **What a row still needs by hand.** Only prose that cannot be generated: the `note`
  (the card's description), a guide when the app is worth one, and a check row when it has a
  command line. A guide stays short and holds only commands its author ran against the
  mirrored build or is sure of from the project's documentation.
- **One reader of the layout per language.** `devstack.js` follows `release_mirror.py`'s dest
  layout and key rule; `verify.sh` asks `devstack.js` which file to run rather than learning
  the layout a third time. A test compares the keys of every row across the two.
- **Guides are data, served by key.** The guide endpoint only answers for a key computed from
  the list, so a request can never name a path. The page renders a guide as escaped text with
  a few markdown marks.
- **A run check is hostile-input handling.** It runs a downloaded program: only the named
  members are unpacked as plain files under a size limit, the program gets a clean
  environment, a timeout that ends in KILL and no network where `unshare` allows, and its
  output reaches `verify.json` as printable ASCII. A PASS is cached per file for a week.
- **Not done here.** No logos or screenshots for these cards; no Ark-run services (registry,
  Headscale, croc relay); no DuckDB extension mirror. Those stay in their own issues.

## 2026‑11 — Apps and the library before AI models: class order, app mirrors before the fill (#347)
**Owner's call:** "prioritize downloading all apps and library content before any more AI models
and other content".
- **Class order in the planner.** After phase 0 (the grid-down essentials, which keep the tiny
  assistant model), `planner.py` runs its passes class by class: **apps** (`installers` bucket),
  **library** (`content` bucket: ZIMs, and every Lastbook row but its model), **models**
  (`models` bucket: curated, scouted, the Lastbook model), **bulk** (anything else). Diversity,
  small-valuable and fill still run, but inside each class. So no model beyond the essentials is
  planned while an app or library item that fits is unplanned; a library item too big for the rest
  does not block a smaller model. The Lastbook installers ride with the library (they need its
  pack, which the apps class would plan too late).
- **Profiles weight, never reorder.** The catalog's per-bucket profile multipliers still apply, but
  only rank items inside a class. The one exception is the `ai` profile: one small (≤ `--small-max`)
  curated model right after the essentials (`EARLY_MODELS`), so an AI-first box can talk early.
- **Unplanned apps run first in the loop.** The tool mirror moved from step 6b (after the fill) to
  5c, and the dev stack (`release_mirror.py fetch` over `data/dev-stack.tsv`, until now by hand
  only) runs at 5d, both before the top-up fill. Both are bounded in time, skip under STOP or under
  1 GiB of budget, and are fail-soft. The dev stack is weekly, on by default, `VALARK_DEVSTACK=0`
  off, `VALARK_DEVSTACK_MAX_GB` / `_GROUPS` to limit it.
- **Same disk rules for the dev stack.** `release_mirror.py fetch` now keeps the Val Ark reserve
  (always, like the Lastbook mirror), takes `--budget BYTES` (the loop passes `valark_budget_bytes`,
  so `VALARK_MAX_GB` holds) and stops at the STOP flag, re-checked every 256 MiB; deferred files keep
  their `.part` and the run exits 3. `valark_data_used_bytes` now counts the dev-stack tree, so the
  footprint cap sees it. Sizing it as planner candidates was rejected: a plan needs ~250 GitHub API
  calls (and ~1000 PyPI calls for the wheelhouse), too slow and rate-limited for every fill.
- **Unchanged:** `fill` never evicts (it only drops a smaller copy once a fuller version of the same
  item is on disk); `evict` and `request` trade up. The APT sets and source bundles stay manual.
- Tests: `tests/test-planner-classes.sh`, `tests/test-loop-apps-first.sh`, the guard checks in
  `tests/test-release-mirror.sh`.
- **Review follow-up (B1/B2):** the loop gates steps 5c/5d on `librarian.sh essentials-done` and
  gives the dev stack a bounded share (`VALARK_DEVSTACK_PCT`, default 25) of the budget;
  installers are **library**, not apps (a 32-64 GB disk must still plan ZIMs). See
  [LIBRARIAN.md](../LIBRARIAN.md#the-priority-model) for the models-vs-library note (N1), the
  dev-stack storage choice (N2) and the long-cycle lock note (N3).

## 2026‑11 — Offline gaps live in issues, not a doc (#384)

**Context.** docs/OFFLINE-GAPS.md (a July 2026 sweep) listed what the mirror would lack if the
internet went off, but nothing tracked closing each gap. **Decision.** Every open or partial gap is an
`offline-gap` issue with a priority label (`prio:apps` → `prio:library` → `prio:content` →
`prio:later`), gathered in the burn-down epic #384, and the doc is removed. Owner priority
(2026-11-25): apps and library content before any more AI models. **Why.** A tracker can be burned
down; a frozen report drifts. The doc's "explicitly rejected" list is kept below so the reasons
aren't lost.

Rejected (and why), from the July sweep: Full PyPI mirror (42.3 TB), Docker Desktop (proprietary), HAProxy (source-only),
nginx as a catalog binary (no portable builds — Caddy wins), GCC official
binaries (don't exist — distro packages + `zig cc` + w64devkit), official
LLVM tarballs (~5 GB, Windows 404 — Zig wins), rustup (a downloader — mirror
static.rust-lang.org standalone installers), MariaDB (no arm64 bintar/macOS —
MySQL 8.4 covers all 4), MinIO (duplicates SeaweedFS), Promtail (EOL —
Telegraf ships logs to Loki), magic-wormhole (no portable binaries — croc),
GnuPG portable (doesn't exist — age), Vaultwarden (Docker-only — KeePassXC),
OSRM/Valhalla (Docker/source-only — GraphHopper's single JAR), tileserver-gl
(npm native deps — go-pmtiles), Cura (Orca/Prusa cover it), Candle/LaserGRBL
(unmaintained/Windows-only — Universal G-code Sender), standalone
dnsmasq/unbound (apt-only — AdGuard Home).

## 2026‑11 — Setup keeps its promises: a .local name when avahi can, a first fill, the cron is the admin's call (#306)

**Context.** The wizard said "You'll open it at http://<name>.local/" and the recovery card printed
that address, but nothing published an mDNS name; the design said commissioning started the fill,
but it only saved settings. **Decision.** `scripts/lib/mdns.sh` publishes the name after setup and
every loop cycle (step 2h) with what the box already has: the hostname (avahi/macOS answer for
it) or one kept-up `avahi-publish -a -R` child (D-Bus, no root). It never installs packages and
never edits `/etc/avahi` (that needs root and outlives Val Ark). `server.js boxAddress()` is the
single decision of which address to show (wizard, recovery card, Health): `.local` only while it is
announced (publisher up; that is not proof every client resolves it, so the IP is shown beside
it), else the LAN IP plus the reason. Commissioning starts ONE bounded `loop.sh once` when no
`val-ark-loop` cron entry exists. Installing the cron is NOT automatic: it writes the user's
crontab, so it is an explicit admin action (Home's admin-only **Keep it healthy 24/7**,
`POST /api/setup/loop-install`, fixed argv `loop.sh install 30`) or the printed command.
**Why.** An appliance must not promise an address that doesn't resolve; showing the real IP is
honest and always works. A one-off cycle starts filling right away without silently changing
the system's scheduler.

## 2026‑11 — Docs as a picture book: a short README and a generated docs tree (#282)

**Context.** The front-page README had grown to 514 lines of diagrams, tool lists and command
references that the guides already owned, and only the top-level guides had pop-up art.
**Decision.** The README is a short front page (what an Ark is, screenshots, quick start, static vs
dynamic, the docs tree) that links into the guides. Every human-facing doc opens with a generated
pop-up scene, and `DOC_TREE` in `scripts/docs/popup_art.py` draws the whole docs hierarchy as one
animated SVG tree, replacing the mermaid doc graph. `--check` fails when a tracked human-facing doc
is left off the tree. Screenshots live in `docs/screenshots/<topic>/`.
**Why.** People read pictures first; one fact keeps one home; and a generated tree with a test
cannot drift the way a hand-drawn graph did.

## 2026‑11 — Grid-down essentials tier + survival profile
- <a id="griddown-essentials"></a>**The planner gains a phase 0 that always runs first:** the ranked
  `data/essentials.tsv`. Val Ark's premise is "the internet may disappear", so the most critical small
  items (water, field medicine, medicines, food, shelter, a pocket encyclopedia, a CPU-sized assistant)
  must land before diversity or value/byte ever get a say, on ANY disk size.
- **Smallest variant first, never blocking.** Phase 0 picks from the *uncollapsed* stream (the normal
  pipeline keeps only the largest ZIM flavour) so it can take the mini/nopic variant, and it skips an
  entry that doesn't fit instead of stopping. It deliberately does NOT reserve the content key, so on a
  big disk phases 1–3 still upgrade to the maxi. Eviction would NOT clean up the small copy (it has the
  *higher* value/byte, so evict() removes it last), hence an explicit step: `planner.py --superseded`
  lists managed, unpinned smaller variants whose larger variant is complete on disk, and
  `librarian.sh fill` removes them at the end of every fill, so nothing is stored twice.
- Phase-0 picks count toward category coverage (phase 1) and the phase-2 per-category caps.
- **Focus, not a fork:** rows carry `focus` (`all` or profile list). A new `survival` profile weights
  content 1.4 / tools 1.2 / models 0.8 and unlocks survival-only rows (Army field manuals, self-reliance
  video). Every profile still gets the `all` rows. Grid-down topics also get a +80 value boost for all
  profiles in `catalog.sh`.
- Backward compatible: without `--essentials` the planner is unchanged (tested).
- <a id="prune-after-stop"></a>**The superseded prune is skipped after a STOP halt (#177).** A
  `state/STOP` flag means "stop changing the disk" (the owner may be about to unplug or inspect it)
  and the plan ran only partway, so `cmd_fill` does not delete anything after a STOP — the prune just
  runs at the end of the next un-halted fill. Every other early exit (time / byte / item budget, low
  headroom) still prunes, because freeing the redundant small copy is exactly what helps then. The
  prune's manifest rewrite is an exact first-column match (`awk '$1!=id'`), so an id that is a prefix
  or extension of the pruned id is never dropped; `tests/test-essentials.sh` §8 runs the real
  `prune_superseded` + `cmd_fill` against a fixture to hold both rules.
- <a id="mini-then-maxi"></a>**Known trade-off, kept on purpose: mini first, maxi later.** On a big
  disk an essential ZIM is fetched twice — the mini in phase 0, the maxi in phase 1–3, then the mini is
  pruned — so its small variant's bytes are downloaded and thrown away. And on a disk where the maxi
  would fit alone but not beside the mini (budget between `maxi` and `mini + maxi`), the maxi is never
  planned; that essential stays on its mini. We considered "skip the mini when the maxi is also planned":
  it would either move a multi-GB download into phase 0 (delaying every lower-ranked life-safety item
  behind it on a time-bounded `maintain` fill) or leave the essential with *no* copy until phase 3
  reaches it. Crediting the mini's bytes back to the maxi's budget doesn't work either: the prune runs
  after the fill, so the disk briefly holds both, and the fill's live headroom check would then stop the
  whole fill before the maxi. The waste is bounded by the small variants' size (typically ~10% of the
  full ones), while getting the critical small copy onto the disk fast is the point of phase 0, so the
  behavior stays as is (documented in `docs/LIBRARIAN.md`).

## 2026‑11 — Static browse pages for server-less archives (#257)

- A NAS or USB disk is often reachable only as a plain file share; opening `web-ui/index.html` there
  showed "nothing installed" because the SPA needs `server.js`. Decision: generate a **static**
  catalog (`scripts/lib/static_site.py`, `librarian.sh site`, refreshed by `maintain`) instead of
  teaching the SPA to read the disk: it works over `file://`, SMB and any dumb HTTP server.
- Relative links only, no external URLs, no JS requirement: the page has to open on an offline
  laptop pointed at a share. Names are escaped and links percent-encoded (archive file names come
  from upstream and are untrusted).
- Scale over completeness: per-section row caps, per-entry file caps and a walk limit, plus a
  `--listing` TSV input so a mirror that already keeps an index never walks millions of files over a
  slow share. Unchanged pages are not rewritten (fewer writes on network shares).
- A file listing is not a catalog: every card carries a picture and a human description. Sources in
  order: the web UI's own data tables (read from `web-ui/index.html` by a small JS-literal reader, so
  there is one source of truth), the item's own metadata (ZIM `M/Title`, `M/Description`,
  `M/Illustration_48x48@1`; model / dataset cards), the `data/*.tsv` notes, then a generated badge.
  ZIM metadata is read with a few small random reads (header, URL-pointer binary search, one cluster)
  instead of a ZIM library, and cached, because the archive may sit on a slow share.

## 2026‑11 — Lastbook: auto-sized by default, every pack opt-in (#181)
- **Context:** [Lastbook](https://lastbook.org) (MIT, `Immortal-Protocols/lastbook`) is a free offline
  survival library. Its release is three live files: `manifest-v1.json` (packs Small 7.7 GB / Medium
  67.5 GB / All 388 GB, each a superset of the one before; 52 state maps ~85 GB; 52 address indexes
  ~5 GB; a 16.9 GB GGUF on huggingface.co), `app-v1.json` (current installers) and `SHA256SUMS.txt`
  (every installer, including the Ubuntu 26.04 deb that `app-v1.json` omits). Every file has a sha256.
- **Decision:** `scripts/tools/lastbook.sh` + `scripts/lib/lastbook_mirror.py` keep the **current
  release only** under `content/lastbook/` (served: Lastbook and its packs are freely published, and
  LAN users install the app from the Ark). It **is** in `download-tools.sh all` with `--pack auto`:
  the largest pack whose bytes still to fetch (plus the base maps and installers) fit Lastbook's
  share, `VALARK_LASTBOOK_BUDGET_PCT` (default 50) percent of (headroom on its disk + what it holds;
  see #183 below), then base maps, the installers, the model (`auto`: only if it still fits),
  then state maps (in manifest order, largest states first) each with its address index, while they fit. `--pack every`
  (all three packs, ~463 GB; ~570 GB with every map and the model) is **opt-in** via `.env`.
- **Why auto for users:** a household box should hold the survival library without anyone choosing,
  and the pack ladder lets one rule fit any disk, from a small one (Small) to a big drive (All).
  Budgeting on bytes *still to fetch* makes the choice stable: once a pack is held it costs 0, so a
  later full disk never makes `auto` drop it or flap. The 50% share leaves the librarian (Wikipedia,
  models, installers) the other half instead of letting whichever runs first take the disk.
  *(Superseded by #203: the librarian's planner now sizes Lastbook; the share remains only for an
  operator-chosen selection, see "Planned by the librarian" below.)* All
  downloads resume from `.part`, so the loop's 2-hour refresh window just continues a big pack next time.
- **Why every-pack is opt-in for servers:** the packs nest, so `every` stores Small and Medium again
  inside All: worth it only for a mirror that hands packs to other machines of different sizes. On a
  household disk that is ~75 GB of duplicates, so only an operator who knows the space is there
  turns it on (the NAS mirror role sets `VALARK_LASTBOOK_PACK=every`).
- **Fail closed:** only https URLs on `downloads.lastbook.org`, `lastbook.org` and `huggingface.co`
  (redirects: those or HF's `*.hf.co` / `*.huggingface.co` CDN), no credentials or odd ports, plain
  file names, 64-hex sha256s; one bad entry anywhere in a manifest fails the whole run. A file is
  renamed into place only after its sha256 matches; a mismatched `.part` is deleted. Exit codes `0` ok,
  `1` failure, `3` incomplete (budget), `64` usage (argparse's `2` is remapped so it can't collide).
- **Prune only what it recorded (PR #182 review).** After a complete run, a file goes only if *this tool*
  recorded it in `.lastbook-verified.json` (finals and the `.part`s it started) and the release no
  longer names it; a stray file under `packs/`, `maps/`, `models/` or `app/<x>/` is never touched (a
  misconfigured `VALARK_LASTBOOK_DIR` pointing at `$HOME` or the model dir must not cost user data).
  A section dir that is a symlink (e.g. `models/` linked to a shared model dir) is never followed by
  prune, old `app/<ver>/` dirs are emptied file by file and `rmdir`ed, never `rmtree`d. And nothing is
  pruned when the release looks truncated: a section that holds files comes back empty, or the run
  would drop more than half of the held files *and* bytes (a normal pack re-release or app bump drops
  less), so one bad upstream publish cannot wipe every box's maps on the weekly refresh.
- **Follow-ups resolved (#183):**
  - *Per-section guard.* Prune is also refused when maps, addresses or models would each lose more
    than half of their own held files **while the release lists fewer files in that section than are
    held**. The whole-mirror AND check missed the All-pack box whose manifest lists only a few states
    (most maps go, but under half the bytes). The "lists fewer" qualifier lets a like-for-like
    replacement (a new model file, renamed maps) still prune; packs and `app/` are left out because
    their names change every release by design. All three checks trigger on **more than** half, so a
    release that keeps exactly half (26 of 52 states) still prunes the other half: a deliberate
    line, since an even split is as likely to be a real re-scope as a truncation.
  - *Nested packs (N3).* With `--pack auto` or one explicit pack, once every file of the chosen pack
    is verified (rc 0), the smaller packs of the ladder are pruned (only recorded files). `every`, a
    list, `none` and `--keep-old` never do this. **Ranked on disk, not by the manifest (PR #194
    review):** a manifest that omitted or under-reported All's size made `auto` pick Medium and then
    delete the verified All as "smaller". Now a pack is superseded only when every manifest size (its
    and the chosen pack's) is present and positive, its recorded on-disk sizes match the manifest,
    its held bytes are strictly below the chosen pack's *verified* bytes, and it shares no file with
    it; files of a pack verified this run are never dropped, and `auto` ranks packs by the larger of
    the manifest size and the recorded bytes, so a held All stays chosen.
    - *Superseded by #204 (R3):* `auto` no longer takes the larger of the two. A held, verified pack
      ranks by its recorded bytes only, and any other pack by its manifest file sizes (see "Auto
      ranking (R3)" below).
  - *No held pack without a larger verified one.* Any held pack file (superseded or no longer in the
    release) is dropped only when a pack this run verified is at least as large on disk. A packs
    list truncated to Small therefore keeps Medium and All, and `--pack none` keeps every held pack.
  - *Fit reserves the extras (N5).* `auto` picks the largest pack whose need **plus** the base maps
    and installers fits; if none does, a pack already held (need 0) stays chosen. That fallback
    requires the pack to be held **and verified on disk**: a manifest entry with no size also has
    need 0, and must not be picked through it (#230).
  - *Share without compounding (N4).* `lastbook.sh` no longer passes a budget from
    `valark_budget_bytes` on `DATA_ROOT`. `lastbook_mirror.py --share PCT [--cap N]` measures headroom
    above the reserve on the filesystem that holds the Lastbook dir, caps it with what `VALARK_MAX_GB`
    still allows, and lets Lastbook hold PCT% of (headroom + the bytes it already holds), so
    repeated runs stay at the share. The fetch-time free check keeps the reserve too. `--cap` is
    passed only when the Lastbook dir is inside the data trees `VALARK_MAX_GB` accounts for
    (`valark_data_used_bytes`); a dir elsewhere is not bounded by that cap (logged), only by its own
    disk's headroom, the reserve and the share.
  - *Downloads (N7).* A 206 whose `Content-Range` start is not the `.part` size deletes the `.part`
    and restarts; 404 / 410 fail the file at once (no back-off).
  - *Pre-change `.part`s.* A stray unrecorded `*.part` in `packs|maps|addresses|models|app/<ver>` is
    pruned only when its final **path** (section/[version/]name) is one the current or the previously
    kept manifests name (those are re-parsed with the live validation, read before the new ones
    overwrite them); a bare name in another section stays. `app/<ver>` must be a real version
    (`1.1.11`, `1.1.rc1`; not `2024photos`).
  - *Library card.* Lastbook is a `CONTENT_LIBRARY` card (Library ▸ Content): its state comes from the
    `/api/status/content` walk of `content/` (a held pack = Mirrored), its Mirror button starts the
    `lastbook` tool job, and the detail page lists the installers and packs held as direct
    `/api/archive/content/lastbook/…` downloads. Without the API there is no HEAD-probe guess (an
    empty directory can answer 200), so it says Not Mirrored. A `VALARK_LASTBOOK_DIR` outside
    `content/` is still reported by `server.js` under `lastbook/…` but flagged `external`: the card
    shows Mirrored and explains that those files are not served (no links), since `/api/archive`
    stays confined to the served trees.
- **Re-review follow-ups (#204):**
  - *Re-released packs are replaced (R1).* The held-pack guard ("a verified pack at least as large")
    kept the old All whenever upstream re-released it under a new file name that was even one byte
    smaller, so a box held two copies of All. Each verified pack file now records its pack id in
    `.lastbook-verified.json` (boxes stamped before that fall back to the kept manifest, which names
    the old file's pack). A held pack file is dropped as **replaced** when this run verified the same
    pack id under another name and the new copy holds at least half the old one's bytes. A gutted
    re-release (under half) keeps the old file, and the truncation guards still apply.
  - *External listing from records only (R2).* For a `VALARK_LASTBOOK_DIR` outside `content/`,
    `server.js` no longer walks the tree. It lists only keys recorded in that dir's
    `.lastbook-verified.json` that are shaped like Lastbook's sections
    (`packs|maps|addresses|models/<name>`, `app/<version>/<name>`), are regular files, and have no
    symlink on the way. With no stamps file it lists nothing, so pointing the variable at `$HOME` by
    mistake cannot enumerate the operator's files to the LAN.
  - *Auto ranking (R3).* A held, verified pack ranks by its recorded bytes. Any other pack ranks by
    its manifest file sizes; `installed_bytes` counts only when a size is missing. An unheld pack
    that would outrank the held one needs a HEAD whose Content-Length equals every manifest size
    (see #214 for what happens when HEAD fails). So an over-reported Medium (`installed_bytes` or
    file size) no longer moves auto off a held All.
    - *Narrowed by #218:* the HEAD check now has two outcomes. A HEAD that answers with a different
      size marks the pack broken upstream: it is skipped and the next confirmed pack goes through.
      Only a HEAD with **no** size keeps the held pack and downloads nothing that run. `auto`'s pick
      is HEAD-checked on fresh boxes too (see "Broken upstream vs not confirmed (#218)").
- **HEAD confirmation and id swaps (#214):**
  - *A failed HEAD is not confirmation (H1).* A HEAD that errors, or answers without a
    Content-Length, counts as **unconfirmed** when the pack would displace a held one. The held
    pack stays chosen, the claimant is not downloaded, and the run logs why. The floor it is
    compared against is the largest pack file held and verified on disk, listed in this release or
    not. A side effect: a genuine upgrade (Small held, All now fits) also needs a working HEAD, and
    without one it waits for the next run.
  - *Renamed re-release that over-claims (H2).* When the larger candidate is a renamed re-release,
    the old All is no longer listed, so it cannot be "kept chosen". If the claim is unconfirmed,
    `auto` chooses no pack rather than a smaller download below the held size: rc 3, "no Lastbook
    pack chosen", nothing fetched or pruned. Separately, every pack download now starts with a HEAD.
    If the server's size disagrees with the manifest, the file fails at once with "the manifest
    says X but the server has Y: not downloading; an upstream manifest error", instead of a GET that
    ends in "range not satisfiable" or a sha mismatch. A failed HEAD there just proceeds, since the
    sha256 still guards the file.
  - *Swapped or aliased ids (H4).* The nested-pack prune skips a pack if any of its files was
    recorded (`pack` in the stamps, else the kept manifest) under a different pack id, because then
    the ladder no longer says what is nested in what. It also never drops a file that a pack it
    keeps still names.
- **Polish (#216):**
  - *No intermediate upgrade after an unconfirmed claim (F1).* Once a larger pack's HEAD is
    unconfirmed, `auto` downloads **no** pack that run. That rules out a smaller one, and also a
    mid-size step up: with Small held and All unconfirmed, it no longer fetches about 67 GB of
    Medium first. Only a pack already held and verified can still be chosen, so it keeps the held
    pack and retries next run. The log names the held file and says no pack was downloaded.
  - *Accurate rc-3 reason (F2).* When no pack is chosen, the message names the held pack file and
    says either that it "is not in this release" (a renamed re-release) or that it "is listed in
    this release with a different size" (same name, over- or under-claimed).
  - *Superseded by #218:* the wait-a-run rule now applies only to a HEAD that gives **no** size;
    a HEAD that contradicts the manifest marks the pack broken and the next pack goes through.
  - *Real-box check (F3).* HEAD on `downloads.lastbook.org` returns a Content-Length equal to the
    manifest size for all three pack zips (checked 2026-11), so genuine upgrades are not blocked by
    the HEAD gate.
- **Broken upstream vs not confirmed (#218):**
  - *A definite mismatch skips only that pack (G1).* `auto`'s HEAD check now has two outcomes.
    - **A HEAD that answers with a size different from the manifest** means that pack is broken
      upstream: it is skipped this run and the next pack that confirms goes through. Before, a
      lying All kept a Small box on Small, or failed a fresh box with rc 1, for as long as upstream
      stayed wrong.
    - **A HEAD that gives no size** is still the transient case. On a box holding a pack it would
      displace, nothing is downloaded and the held pack is kept (F1).
  - *Fresh boxes are checked too.* `auto`'s pick is now HEAD-checked even with nothing held. On a
    fresh box a HEAD with no size still proceeds (nothing to displace; the sha256 guards it).
  - *Exit 3 when a larger pack is passed over.* Whenever a larger pack was skipped (broken) or not
    confirmed, the run exits 3, so the weekly job shows "incomplete" instead of "mirrored".
    `lastbook.sh`'s rc-3 line now names both causes (budget, or upstream size).
  - *Nothing-fits message (G2).* It now quotes the smallest pack's need **plus** the room reserved
    for the base maps and installers, and the total, which is what the fit actually compares.
- **Step up, never down; prune on a skip-only exit 3 (#220):**
  - *Never below the held pack (K1).* `auto` never downloads a pack smaller than the largest pack
    held and verified on disk, whatever happened to the better candidates. Before, after a "broken
    upstream" skip of a renamed All-2, it could fetch about 67 GB of Medium beside the held All.
    The one exception is a same-id re-release of at least half the held size, which replaces the
    held file (R1). The pack id comes from the stamps, else the kept manifest. If that leaves
    nothing to choose, the run exits 3 and says every offered pack is smaller than the held file.
  - *Prune after a skip-only exit 3 (K2).* When the run exits 3 **only** because `auto` passed over
    a larger pack upstream (everything selected was fetched and verified; nothing deferred, over
    budget or failed; a pack was chosen), prune runs with exactly the guards of an exit-0 prune.
    So the smaller pack nested in the verified choice no longer lingers while upstream is wrong.
    Any other exit 3, and every exit 1, still prunes nothing.
  - *Messages (K3).* When every candidate is contradicted upstream, the note says "no Lastbook pack
    could be confirmed upstream" (not "fits the budget"), and an unlimited budget prints as
    "unlimited", never "?".
- **A frozen pack still refreshes everything else (#222).** "Step up, never down" means `auto`
  never trades a held, verified pack for a smaller download. So when the only candidates are
  smaller (for example a same-id re-release under half the held size), or the larger one cannot be
  confirmed upstream, no pack is chosen and the held one is **frozen**: kept as it is, not updated,
  and the run exits 3. Before, a frozen pack also stopped the base map, state maps, address indexes
  and model, which only ride with a chosen pack. Now a held, verified pack counts as the pack for
  them: they keep refreshing within the budget (installers always did), and the log says so. A
  fresh box with no pack held still gets no maps without a pack.
  - **Escape hatch:** to take a re-release that `auto` refuses, set `VALARK_LASTBOOK_PACK=all` (or
    run `lastbook.sh --pack all`). That fetches the current All whatever its size. The old file is
    kept while it is larger than the verified new one (the held-pack guard), so delete it by hand
    once the new one is verified if the disk is tight.
- **Planned by the librarian, not a fixed share (#203).** This supersedes the 50% share as the
  default: a share either starved Lastbook on a disk with room or took half of a small disk from
  everything else, whatever the profile.
  - *Candidates.* `lastbook_mirror.py candidates` prints one planner row per pack (plus the base
    maps), state map (plus its address index), the model (bucket `models`) and the installers.
    It applies the same allow-list and validation as a mirror run, and a row with no size is
    left out (#230). `catalog.sh` caches these rows daily, points them at the current Lastbook
    dir and applies the profile weights. `planner.py` then places them with everything else.
  - *Nesting.* The planner plans at most one pack per Lastbook dir. A later phase may replace the
    planned pack with a larger one, and its bytes are refunded. A pack held and verified at its
    recorded size, summed per pack, satisfies every pack no larger than it. The held pack's own
    id is still charged when its listed files are not all there (a re-release under a new name,
    a missing base map). Maps, the model and the installers need a pack, held or planned. The
    survival profile lists `pack:small` and `app:*` in `essentials.tsv` (new kind `lastbook`).
    That phase-0 essential is the one exception to "one pack": it stays planned beside a later,
    larger pick. It is fetched first, and the nested prune drops it once the larger pack is
    verified.
  - *Charged what is left (review of PR #288).* Each Lastbook row costs only the bytes it still has
    to fetch: held files cost 0 and a `.part` is credited, so a half-fetched Medium is not
    stranded behind a fresh Small. The mirror's budget is the sum of the planned rows' remaining
    bytes, not unlimited, so a held-item refresh is budgeted too. There is no "plus held"
    re-enable path, so `MODEL=no` and `APPS=none` hold. A "no" means "do not fetch or refresh",
    not "delete what is held".
  - *Fetch and prune stay in the mirror.*
    - `librarian.sh fill` passes the planned Lastbook rows to `lastbook.sh --plan-file`. The
      phase-0 essentials go in their own batch, then every planned row. Each batch is checked
      against free space as a whole, bounded by the remaining `--time`, and counted only by the
      bytes the mirror really added. A busy lock (75) is a skip.
    - The mirror run is `--pack auto --pack-limit <planned id>`, meaning that pack or a smaller
      one, so a planned All that is broken upstream falls back down the ladder, never below the
      held pack. When no pack will be held, the planned maps, model and installers wait too.
    - The auto guards (step up never down, HEAD confirmation, keep the held pack, nested prune
      after a verified larger pack) and the #182/#194 prune rules all still apply.
    - The reserve and the STOP flag are re-checked every 256 MiB inside a download.
    - The files never enter `manifest.tsv`, so `verify` and `evict` never delete them. `request`
      and `catalog` never resolve a Lastbook row, and `request` refuses any source `download_one`
      cannot fetch before it pins or evicts anything.
    - Run alone (the weekly refresh or the Mirror button), `lastbook.sh` asks
      `librarian.sh lastbook-plan` first.
    - A flock on `state/lastbook.lock` serialises Lastbook mirror runs only. The fill's own
      `fill.lock` is separate, so other librarian downloads are not serialised against it.
  - *Opt-outs.*
    - The candidate cache holds the full offer (header `format=2`; an older cache is ignored).
      MAPS, ADDRESSES=none, MODEL=no and APPS=none are applied when the rows are read, so an
      opt-out holds at once, even offline.
    - Share mode, with no planner rows and the share as before, applies with:
      `VALARK_LASTBOOK_PACK=every` (the server opt-in) or an explicit pack, an explicit
      `VALARK_LASTBOOK_BUDGET`, `VALARK_LASTBOOK_PLAN=0`, `VALARK_LASTBOOK_ADDRESSES=all` or a
      code list (the planner folds addresses into a map, and would otherwise quietly reduce
      these to `follow`), CLI selection options, or a `VALARK_LASTBOOK_DIR` on another
      filesystem than the data root (`stat -c %d`). The last one stays until there is a
      per-destination budget.
    - `VALARK_LASTBOOK_BUDGET_PCT` is kept as a **deprecated** fallback: set on its own it
      selects share mode and logs a warning.
  - *Never delete before the replacement verifies (re-review of PR #288).*
    - Removing `--plus-held` made one case worse: a new app version that did not fit let prune
      delete the old installers with nothing in their place.
    - Now a held map, address index, model or installer that the release no longer names is
      pruned only once its replacement is on disk and verified. For an old `app/<ver>/` file
      that means all the current installers; for a map, address index or model it means the
      current entry with the same id. An entry dropped upstream altogether still goes, under
      the truncation guards, and a file whose entry cannot be told is kept.
    - The entry id is recorded in `.lastbook-verified.json` (`entry`, like `pack`), at fetch time
      and from the kept manifest on every run, so the link survives once the kept manifest
      moves on.
    - *Second re-review:* the model and the installers are each one slot. A renamed model (new id)
      keeps the old file until every current model entry is verified, even with `MODEL=no`.
      An unknown-entry model file follows the same slot rule, and an unknown-entry map or address
      index is kept and logged. An address index upstream marks `available: false` is kept.
      In planner mode the base maps are not wanted and are taken last, after every planned row
      (third review). An unplanned base-map refresh never uses up budget charged for other rows,
      and when nothing is left it is skipped, not deferred. So it no longer makes the run
      incomplete or blocks the prune, though a run can still exit 3 for other reasons.
      `lastbook_fill` never runs unbounded: with a `--time` budget and no seconds left it does
      not start.
    - Files kept indefinitely are logged with the reason on every run, and only an operator
      removes them: an entry upstream marks unavailable, an unknown entry, an old model or
      installer version kept under `MODEL=no` / `APPS=none`.
    - Candidate rows carry each file's sha256, so a same-name, same-size re-release is not taken
      for held. With these rules, every held item is at least as well off as with `--plus-held`:
      it is kept until replaced, and its refresh is planned and charged.
  - *Model category.* The Lastbook GGUF is `lastbook:model`, not `model:assistant`. It must not take
    or cover the curated assistants' diversity slot, and it never takes a diversity slot itself.

## 2026‑11 — cad-agent references: a private, content-addressed archive of every cited source (cad-agent#323)
- **Context:** cad-agent keeps a reference knowledge base of ~760 sources (≈330 GitHub repos, ≈350
  pages, ≈70 PDFs, a few books) and publishes it as JSON beside its site
  (`catalog/references/index.json`, `records.json`, `<area>.json`). The owner, 2026-11-04: *"the
  resources were for cad-agent to provide references for designs and also to mine in the future, of
  course val-ark would back them up as well and clone them."*
- **Decision:** `scripts/tools/cad-agent-references.sh` + `scripts/lib/references_mirror.py` read that
  index (the Ark keeps no URL list of its own) and archive **every** source, whatever its licence:
  repos as full-history `git bundle`s (every branch and tag, no size cap by default; `--max-repo-mb`
  for small disks keeps a pointer only), pages as one self-contained HTML file via **monolith**
  (Y2Z/monolith, CC0; raw HTML when it is missing), PDFs and other files as served. Blobs are
  content-addressed, `manifest.jsonl` is an append-only log, and `by-id/<id>.<ext>` is the stable path
  from a record id to its latest copy. The work is ordered by `planner.py` (value: evidence class and
  cited status); the budget (`valark_budget_bytes`) is enforced on bytes actually written, checked
  before each item and after each fetch, and the run stops cleanly when it is reached.
- **Opt-in, run by hand.** `download-tools.sh all` (the loop's weekly refresh, `start.sh` "download
  all") and the web UI's one-click tool requests leave it out: the first pass is ~37 GB and can take a
  day. Run `scripts/tools/cad-agent-references.sh` directly (detached, e.g. `nohup … &`), not through
  `download-tools.sh`, which would hold the tool lock for the whole pass. It resumes per item, so re-run
  it after an interruption and now and then to re-check (copies older than 30 days are re-checked).
- **One bad item never stops a run:** anything an item raises (a malformed URL, a git or monolith
  timeout, a monolith that cannot execute) is recorded as `failed` and retried after `--retry-hours`
  (24); a monolith failure falls back to raw HTML. A body shorter than its `Content-Length` is never
  stored. robots.txt is honoured; 5xx or no answer counts as disallow (RFC 9309).
- **Politeness, precisely:** the module spaces its own requests (index, robots.txt, each page or file,
  the GitHub API) at least 1 s apart per host. monolith's asset fetches for a page, redirect hops and
  git traffic are not throttled by it.
- **`redistribute` governs serving, never keeping.** It is `true` only for the `open` and
  `share-alike` licence classes; `non-commercial`, `unclear`, `proprietary` and `unrecorded` copies are
  archived with `redistribute: false`. So the store lives in `$VALARK_HOME/private/`, which `server.js`
  never serves (its static and `/api/archive/` trees are tools/models/content/sources/assets/installers/docs),
  and it counts in the footprint (`valark_data_used_bytes`). A future UI may serve the `true` copies.
- **Adopt, don't build:** `git bundle` (restorable with `git clone`, checkable with `git bundle
  verify`), monolith for pages, the librarian's planner for ordering. ArchiveBox / browsertrix (WARC,
  JS-heavy pages) stay an optional later path; lychee belongs in cad-agent's link checker, not here.
- **Size (dry run, 2026-11-04, cad-agent dev index, repo sizes from the GitHub API):** ≈ 37 GiB in all,
  ≈ 36 GiB of it repos (the largest 6.8 GiB); pages and PDFs ≈ 1 GiB at 2–3 MB each.
- **Why:** one source of truth (cad-agent's index), a store a later tool can walk with no network,
  and dedup for free (two records of one repo or one PDF share a blob).

### The manifest (`manifest.jsonl`, schema `val-ark/cad-agent-references-manifest/1`)

One JSON object per line, one line per fetch outcome, appended (one `write()` per line) and never
rewritten. A torn last line (a write cut short) is skipped by readers and dropped by the next mirror run.
An item the budget stops is not recorded (it is simply fetched by a later run). The **latest line of
an id whose `status` is `archived`, `unchanged` or `relabelled`** names its current copy; a later
`gone` or `blocked` line never removes it (`references_mirror.py latest` prints exactly those). cad-agent's
phase 6 (`tools/references_archive.py`) copies `sha256`, `kind`, `fetched` and `redistribute` into each
record's `archive:` block, and never a path or host.

| Field | On | Meaning |
|---|---|---|
| `v` | all | `1` |
| `id` | all | cad-agent record id (`^[a-z0-9][a-z0-9._-]*$`; others are rejected, never written) |
| `url` | all | the record's URL as published (`null` for a book) |
| `method` | all | `git` \| `page` \| `pdf` \| `none`: how it was classified from the URL |
| `status` | all | `archived` (copy made; may equal an earlier blob) \| `unchanged` (re-check found the same refs or HTTP 304; same blob) \| `relabelled` (licence changed, no fetch; same blob, `fetched` of the copy, plus `relabelled` time) \| `too-large` (pointer only) \| `no-url` \| `blocked` (401/403/429/451, or robots.txt disallows, refuses or is unreachable) \| `gone` (404/410, repo not found) \| `failed` (anything else, incl. a truncated body or a timeout; retried after `--retry-hours`) |
| `fetched` | all | UTC `YYYY-MM-DDTHH:MM:SSZ` of the fetch that made the copy |
| `record_kind` | all | cad-agent's `kind` (project, guide, datasheet …) |
| `licence_class`, `licence_read` | all | as published; `unrecorded` when the record has none |
| `redistribute` | all | `true` only for `open` and `share-alike`: may the Ark serve this copy |
| `index_revision` | all | cad-agent commit the index was built from |
| `kind` | copies | `git-bundle` \| `html` \| `pdf` \| `file` |
| `sha256`, `bytes` | copies | of the stored blob |
| `blob` | copies | `blobs/<sha256[:2]>/<sha256>.<ext>`, relative to the store |
| `link` | copies | `by-id/<id>.<ext>`, relative symlink to the blob |
| `tool` | copies | `git <version>` \| `monolith` \| `raw-html` \| `urllib` |
| `remote` | git | the clone URL |
| `commit`, `ref`, `refs`, `lfs` | git | HEAD commit, its branch, number of branches+tags, whether `.gitattributes` uses LFS (LFS objects are not fetched) |
| `repo_kb` | git | size the host reports (GitHub API), when known |
| `http_status`, `final_url`, `etag`, `last_modified`, `content_type` | http | as served (`final_url` only after a redirect) |
| `cap_mb`, `error`, `retry_after`, `monolith_error` | some | why a copy was not made, or fell back |

## 2026‑11 — Python wheelhouses + container archives as tool artifacts (#149)
- **Context:** cad-agent (CAD/FEA/CFD toolkit) needs ~100 Python wheels, an OpenFOAM container
  image, and on aarch64 two libraries PyPI has no wheel for (gmsh, pyamg). The catalog only knew
  binaries, archives, source clones and install hints; a full PyPI mirror is rejected (42 TB).
- **Decision:** one tool entry, `scripts/tools/cad-agent.sh`, is the whole bundle. A per-platform
  **wheelhouse** (`pip download --platform … --only-binary=:all:` from a throwaway venv, so one host
  fills every platform and nothing is installed on the box) covers the core package and every
  extra; linux-arm64 adds a **conda-forge explicit set + static micromamba**, because PyPI has no
  aarch64 gmsh/pyamg; the
  OpenFOAM image is a **`docker load` archive** pulled by the new stdlib `scripts/lib/oci_pull.py`.
  `install.sh` per platform builds the environment with `pip --no-index`; `verify.sh` installs the
  core package offline each cycle. Wheels target CPython 3.12 (the mirrored python-standalone) and
  glibc ≤ 2.31 (`VALARK_CADAGENT_GLIBC`), the oldest fleet host.
- **arm64 is conda-native, not a mix.** Measured on the NAS (glibc 2.31): adding just conda's
  gmsh to a pip env fails, conda's numpy needs `GLIBCXX_3.4.29` after a pip wheel already bound
  the host's libstdc++, and conda's pyexpat then meets the host's libexpat. So the env is conda's
  Python (its own libexpat) with gmsh, pyamg and the numeric stack (numpy/scipy, mujoco, numba …)
  from conda, and a `.pth` preloads the env's libstdc++, libexpat and zlib before any manylinux wheel loads (the
  wheels' system GL/X11 chain otherwise binds the host's older libexpat first and breaks pyexpat).
- **…but the CAD kernel stays on PyPI.** conda-forge's `ocp` 7.9.3.1 binds OCCT static methods
  without the `_s` suffix (`TopoDS.Solid`, not `TopoDS.Solid_s`); cad-agent calls the PyPI form, and
  ~180 of its tests failed on the NAS with a conda OCP. So cadquery, cadquery-ocp, vtk and pyvista
  come from the wheelhouse, `occt` is pinned to its no-VTK build (gmsh needs it), and the fill fails
  if the solve ever pulls `ocp`/`vtk`/`cadquery`/`pyvista` (`CONDA_ARM64_FORBID`). pip adds what
  conda lacks plus its wheel deps (`conda/pip-wheels.txt`, followed through wheel METADATA).
- **cad-agent's `fea` extra cannot resolve off x86_64** (pypardiso→MKL, no marker; reported upstream
  as Valpatel/cad-agent#285), so `install.sh` installs the platform-filtered `requirements.txt` and
  then cad-agent `--no-deps`.
- **Why:** curated, per-project wheelhouses are small (≈0.5–1 GB per platform) and prove an offline
  install end to end, where a generic PyPI cache would not. A new cad-agent release replaces only
  the wheelhouse; the image (digest stamp) and conda packages (md5) are kept.

## 2026‑07 — CI guards: doc-link integrity + secret/host-leak scan (#130)

**Context:** the #129 doc-hierarchy cleanup surfaced two defect classes CI never caught — a real
host name committed in `tests/README.md` (scrubbed in #129), and nothing verifying the `.md`
internal links/anchors actually resolve. **Decision:** add two OFFLINE `test-*.sh` validators
(`test-doc-links.sh` + `test-secrets.sh`, backed by `tests/lib/{md_link_check,secret_scan}.py` and a
reviewed `tests/lib/secrets-allowlist.txt`) that gate in CI **and** locally, and run them as a
fail-fast CI step BEFORE the Playwright browser install. **Why:** doc rot and secret leaks are cheap
to catch mechanically and expensive to catch by eye (the #129 review had to hand-build a link
resolver); a public repo must never ship a real host/IP/credential. The scan is a ratchet — it fails
any NEW leak while allowlisting the handful of reviewed examples/constants/fixtures; public dotted
domains, loopback, and `$`/`{}`/`<>` placeholders pass automatically.

## 2026‑07 — Notification center: bell/inbox slice 1 (#69)
- <a id="notify-bell-69-slice1"></a>**The notification center is a READ‑ONLY aggregation, not a
  new store.** `GET /api/status/notifications` composes the signals the box *already* writes —
  `heal-events.jsonl` (self‑heal events) + `selfheal.json`/`verify.json`/disk/Safe‑Mode (current
  conditions) — into one severity‑tagged list. No new state file, no daemon, zero deps. This keeps
  the endpoint read‑gated like the rest of `/api/status/*` and avoids an unauthenticated write path.
- **Dismiss is client‑side (localStorage) for slice 1** so the endpoint stays read‑only. That
  needs **stable item identity**: `heal-events.jsonl` lines carry only `ts|kind|detail` (no id,
  tail‑capped at 200), so the server assigns `ev-<djb2-hash(ts|kind|detail)>` for events and a
  fixed key per condition (`cond-safemode`, `cond-disk-warning|critical`, `cond-verify-<comp>`,
  `cond-missing-assets`). A disk *escalation* gets its own id (`…-critical` vs `…-warning`) so a
  worsening condition re‑surfaces even if the warning was dismissed. **Server‑side, cross‑device
  dismiss** is the deferred follow‑up (adds a write path → same adversarial bar as
  `POST /api/maintenance/repair`); routing into mail/board/chat, the Immediately/Daily/Never
  frequency, and the on‑box LED are also later #69 slices.
- **Severity maps to the existing color grammar** (green info / yellow warning / red critical).
  Self‑heal events are reassuring **info** ("handled it for you"); the lone exception is
  `moderation-error` (could NOT quarantine) → **warning**. Failed functional‑verify checks are
  **warning** ("working on it — self‑heal re‑verifies"), matching the Health page framing.

## 2026‑07 — "Ask Val Ark" slice 1: an offline ask endpoint that reuses the moderation runtime (Phase 8, #67)

- **Context:** Phase 8's core affordance is a "Ask Val Ark" helper backed by the box's OWN small
  chat model. Every building block already existed — curated assistant models
  (`data/models-extra.tsv` kind=`assistant`, land in `models/assistant/…`), the mirrored
  llama.cpp runtime, and a PROVEN single-shot invocation (`verify.sh:104`, `moderation.sh`
  `_mod_run_text`) — but nothing wired the box to answer "how do I…" anywhere in the UI.
- **Decision (this slice — minimal, offline, zero-dep):** two endpoints in `scripts/server.js` +
  a Home card. **`GET /api/status/ask`** → `{ready, runtime, model, reason, modelId}` (pure
  presence checks, NO inference; read-gated for free by the `/api/status/` prefix). **`POST
  /api/ask` `{question, context?}`** streams the answer as **SSE frames** (`event: token|soft|
  error|done`, JSON-encoded `data` so newlines never break framing) — a per-request stream, NOT
  the shared `sseClients` broadcast pool. Runtime reuse is exact: resolve `llama-completion`
  (fallback `llama-cli`) by NAME under `tools/<platform>/llama-cpp` (the `_mod_find_bin` /
  `findKiwixServe` pattern; `VALARK_TOOLS_DIR`-overridable) and the smallest `.gguf` > 10 MB under
  `models/{assistant,llm}` (verify.sh's filter, assistant preferred). Invocation is the proven
  single-shot argv `-m … -p <prompt> -n 256 -st -no-cnv --no-warmup --no-display-prompt --temp 0`.
- **Why streaming, when the issue listed SSE as out-of-scope:** the worker task direction asked for
  token-visible streaming; a single-shot `llama-cli` already emits tokens to stdout as it decodes,
  so we stream **its stdout** — no persistent `llama-server` daemon (that stays out of scope). The
  UI reads the stream with a `fetch()` + `ReadableStream` reader (EventSource can't POST) and a
  tiny SSE frame parser; every token is rendered via `textContent` (auto-escaped — XSS-safe).
- **Security posture (the whole point):** the user's `question` is DATA in ONE `-p` argv element —
  `spawn(bin, argvArray)`, **never** a shell string / `sh -c`. Defence in depth: control-char
  strip + 2000-char cap on the question (600 on context), `-n` token cap (hard max 1024), a
  wall-clock `setTimeout`→`SIGKILL` backstop, a memory guard (`os.freemem()` vs model size) to
  avoid OOM-killing community services, and an **admission cap** (`ASK_MAX_CONCURRENT`, default 2)
  that 503s over-budget — mirroring the moderation/#62 in-flight cap so a burst can't fan out
  unbounded 1–2 GB model loads.
- **FAIL-SOFT (hard requirement):** the ARM64 appliance ships a llama.cpp SOURCE clone only, so a
  bare box may have no binary and/or no model. Every such path returns **HTTP 200** with a friendly
  `event: soft {reason: runtime|model|memory|empty}` (Home shows a one-click "Get the helper" that
  fires the existing `POST /api/request {kind:'model', id:'qwen2.5-1.5b-instruct-gguf'}`), NEVER a
  5xx, and never crashes the event loop. `VALARK_TEST_NO_SPAWN=1` returns a deterministic stub
  answer AFTER the soft checks, so the Playwright suite never triggers a real model load while a
  bare CI box still exercises the soft path; the offline bash validator leaves it UNSET to drive
  the REAL spawn against a stub binary (proving the argv-array/no-shell contract).
- **Deferred (later #67 slices):** doc-grounding/RAG over the bundled Linux docs + ZIM,
  per-page context beyond Home, embed-everywhere, the "apply-the-fix" button, and — if single-shot
  cold-load latency proves too slow on the appliance — a lazily-started persistent `llama-server`.

## 2026‑07 — Four‑tab consumer nav: Home · Library · Activity · Settings (#61 / epic #91 slice 1)

- **Context:** the top nav had SEVEN links (Home, Software, Models, Library, Community, Settings,
  Getting Started). The easy‑consumer‑UI roadmap ("cap it at four tabs") wants a calm top bar.
- **Decision (this slice — NAV SHELL only, no page internals redesigned):** reduce the top bar to
  exactly four — **Home** (`#/`), **Library** (`#/content`), **Activity** (`#/activity`, surfaced
  in the top nav for the first time), **Settings** (`#/settings`). The three former browse links
  (Software `#/tools`, Models `#/models`, Content `#/content`) **plus** Downloads (`#/packages`)
  now live UNDER the Library tab via an in‑page **segmented sub‑nav** (`renderLibraryNav(active)` →
  `.library-nav`/`.lib-tab`, one real deep link per surface). `activeSection` maps
  tools/models/content/library/packages → `library` (Library tab highlights on all of them),
  activity/health → `activity`, settings → `settings`. Community & Getting Started **leave the top
  bar but stay reachable** — Community via the Home hub card + a new footer link; Getting Started
  via the footer + hero CTA. **No route changed:** `#/tools`, `#/models`, `#/content`, `#/library`
  (alias), `#/community`, `#/quickstart`, `#/packages`, `#/health`, `#/tools/<id>` all still
  deep‑link exactly as before.
- **Why a sub‑nav, not a new landing page:** the roadmap said "pick the simplest coherent pattern."
  A sub‑nav adds ZERO new routes and touches only the four list pages' top‑of‑body — the Library
  tab points at the existing `#/content` ("Offline Library") default and the peers are one click
  away. A new `#/library` landing would be page‑internals work this slice explicitly excluded.
- **Gotchas for the next slice:** (1) the mobile hamburger reuses the SAME `.nav-links` DOM, so
  four tabs there is automatic — no separate mobile list to keep in sync. (2) Playwright tests that
  navigated via `page.click('a.nav-link:has-text("Software"|"Models"|"Getting Started"|"Community")')`
  BREAK — those top links are gone. Fixed with an `openLibrarySection(page, sub)` helper (click
  Library tab → click sub‑tab) and footer clicks for Community/Getting Started; the sub‑nav uses
  `.lib-tab` (never `.nav-link`) so `:has-text("Library")` still resolves to exactly the one top
  tab. (3) On a <480px viewport `.nav-link` is `display:none` until the hamburger opens — wait for
  `.nav-hamburger`, not a visible nav link. New `tests/screenshots/specs/nav.spec.ts` (27 tests)
  locks all of this in. Later #91 slices: Home one‑status‑light polish, Basic/Expert Settings,
  Ask Val Ark (#67).

## 2026‑07 — Packages manifest: served `/api/packages` = present inventory, not the catalog (#89 slice 1)

- **Context:** the box already serves individual downloads (per‑platform app archives via
  `/api/archive/`, the self‑replication bundle/tarball via `/sources/val-ark/`, ZIMs via kiwix) but
  had no consolidated, machine‑ + human‑readable **packages list**. Epic #89 wants a versioned,
  checksummed package set + a manifest the UI renders as a "downloads" list.
- **Decision (this slice):** add a read‑gated `GET /api/packages` that enumerates what THIS box can
  hand out **right now** — app/tool archives (per platform, version from `.version` markers), the
  self‑replication source bundle/tarball/node runtimes (version from the mirror's `VERSION`, sha256
  from a `SHA256SUMS`), on‑disk models, and complete ZIMs — each with a stable `id`, `name`, `kind`
  (app|source|model|content), `platform`, `version`, `size`, optional `sha256`, `desc`, and a
  **relative** `url`. Plus a minimal "Downloads" page (`#/packages`) that renders it. Deferred to
  later slices: wiring artifacts into the CI/CD release + attaching the manifest to the GH Release.
- **Why this shape:** it is deliberately DISTINCT from `/api/catalog/*` (the *upstream, not‑yet‑
  downloaded* browse feed that one‑click `POST /api/request` pulls). `/api/packages` is the *present
  inventory* — no network, no eviction, just "what's on disk to grab." Keeping URLs relative +
  metadata‑only preserves the public‑repo / LAN‑only posture (no host paths or absolute URLs ever
  cross the boundary); reusing the existing read‑gate keeps the same access posture as the library
  it lists; hashing at mirror time (not per request) keeps the endpoint fast on a multi‑GB box.

## 2026‑07 — Release tags: unprefixed 0.x, minted by release.sh from the VERSION file (#64)

- **Context:** the shipped series is **unprefixed** (`0.1.7`, `0.1.8`, `0.1.9`), created by hand
  because `scripts/release.sh` still minted `vX.Y.Z` tags, never read the `VERSION` file, and its
  clean‑tree check used to trip on untracked local files. A single stray v‑tag would permanently
  outrank every unprefixed tag under version sort (`v0.1.10` > `0.2.0`), silently corrupting any
  "latest tag" logic; and a tag could ship while `/api/health` still served the old version.
- **Decision:** the canonical tag scheme is the **unprefixed `X.Y.Z`** the series already uses —
  shipped tags stay as‑is, no renormalizing. `release.sh` now derives the tag from the repo‑root
  `VERSION` file (no argument needed; an explicit argument must match it, leading `v` stripped,
  never minted), only blocks on uncommitted **tracked** changes (untracked cruft can't change what
  a tag of HEAD captures), refuses a double release under either prefix, and computes the
  changelog baseline via `git describe --tags --abbrev=0` (nearest **ancestor** tag) instead of
  the highest version‑sorted tag repo‑wide. `.github/workflows/release.yml` now also triggers on
  unprefixed tags (it only knew `v*.*.*`, so it never fired for 0.1.7–0.1.9) with the same
  ancestor‑tag baseline. Validated offline by `tests/test-release.sh` against scratch repos.
- **Why:** one source of truth (`VERSION` → tag → `/api/health`) and one tag scheme make "cut a
  release" a no‑judgment operation: bump `VERSION` in the release commit, merge to `main`, run
  `scripts/release.sh --push` on main's tip. The old `.memsearch/` clean‑tree workaround is
  obsolete (gitignored since ce214a7) — use the helper, not manual `git tag`.

## 2026‑07 — Safety card ships without "restore"; review is remove/dismiss only (Phase 7, 4/n)

- **Context:** the admin Safety card's review queue needs actions on held items. The natural
  set is remove (delete) / restore (release a false positive back to its store) / dismiss
  (acknowledge, keep quarantined). An adversarial review of the endpoints flagged that
  **restore is the entire risky surface** (4 of 5 findings, incl. a HIGH): its destination is
  `item.path` read from `queue.jsonl`, an append-only log living in the in-`<state>` tree that
  this project's OWN threat model treats as attacker-writable (a same-uid service or an
  NFS-mesh peer). An unconfined write-back is an arbitrary-file-write → RCE-if-root
  confused-deputy (admin clicks "Approve" → server writes attacker bytes to e.g. `/etc/cron.d`),
  plus a TOCTOU symlink-swap on the copy source that exfiltrates arbitrary readable files.
- **Decision:** **drop restore** for 4/n. The queue supports only **remove** (`unlinkSync` the
  quarantine entry — never follows a final symlink, basename-confined) and **dismiss** (append
  `reviewed.jsonl`, keep the file). Both are provably safe. A false positive is released on the
  box itself for now.
- **Why not just harden it:** doing restore safely needs the destination realpath-confined to an
  allowlist of the sweep's store roots (which the server would have to duplicate from
  `mod-sweep.sh` — a drift hazard) **and** an `O_NOFOLLOW` fd-based copy. That's a real feature,
  not a patch; better shipped deliberately later than rushed into a security-sensitive path. The
  fail-closed instinct applies to our OWN write-backs too: if we can't confine it simply, don't
  do it. Follow-up: store-root-confined + `O_NOFOLLOW` restore.

## 2026‑07 — Moderation ENFORCEMENT is a post-store loop sweep (Phase 7, 3/n)

- **Context:** the endpoints + settings (2/n) can screen content on request, but nothing on
  the box actually ran community content through them — so the Safety card's "screening" claim
  was hollow. Two ways to enforce: a **pre-store proxy intercept** (screen the POST body in
  `pipeProxy` before NodeBB/MicroBin stores it) or a **post-store sweep** (the self-heal loop
  screens already-stored files each cycle).
- **Decision:** post-store **file sweep** (`scripts/lib/mod-sweep.sh`, wired as `loop.sh` step
  7c). It walks configured community stores (paste files, mail, upload dirs — `VALARK_MODERATION_DIRS`
  overrides), screens each new file with `moderation.sh check`, and on any non-`allow` verdict
  **quarantines** the file (moves it out of the store) + appends a `state/moderation/queue.jsonl`
  review entry. Idempotent via a `screened.tsv` (path+size+mtime) marker; bounded per run; the
  admin's `action` (block/quarantine/flag) decides move-vs-copy. **Fail-closed:** an unparseable
  verdict, a classifier error, or node-unavailable settings all resolve to hold→quarantine, never
  "left served."
- **Why the sweep, not the intercept:** the pre-store intercept must parse each app's POST format
  (NodeBB CSRF/multipart, MicroBin forms) — fragile and app-coupled — and NodeBB's post store is
  **Redis**, not files. The sweep is app-agnostic, offline-testable with fixtures + a stub
  classifier (`test-mod-sweep.sh`, 16/0), and fits the loop's "reconcile reality each cycle"
  model. It's reactive (content is briefly visible before the next cycle) — an acceptable first
  cut; a NodeBB/Redis screener and a pre-store paste intercept are documented follow-ups.
- **CORRECTION (real-box investigation, 0.1.9 deploy):** the sweep must **NOT** target the
  community services' internal stores at all — they are **DB-backed**. MicroBin keeps text pastes
  in SQLite (`microbin.db` under `STATE_DIR/services/paste`); maddy keeps mail in an imapsql/bbolt
  store (`STATE_DIR/services/mail/maddy/`). The files on disk are referenced *from* a database, so
  the sweep's move-to-quarantine would **corrupt the store**, not screen it (and pastes/mail bodies
  often aren't standalone files). The original default paths (`services/paste/data`,
  `services/mail/messages`) were also just plain **wrong** (off by the real subdir), so the sweep
  was a harmless no-op on the real box — but "correcting" them would have caused corruption. So the
  sweep now screens **only** an explicit plain-file uploads area (`VAL_ARK_UPLOADS` /
  `VALARK_MODERATION_DIRS`), never a service store. Real per-service enforcement (paste/mail/forum)
  requires a **pre-store intercept or a service-native hook** — a deliberate follow-up, not a path
  tweak. This is the fail-closed instinct applied to integrity: don't let the safety mechanism
  itself break the thing it guards.

## 2026‑07 — Community chat is open (no-login) by default
- **Context:** on the real box a visitor opening `/app/chat/` hit The Lounge's **private-mode login
  wall with no way to create an account** (accounts were host-only, via `thelounge add`) — chat was
  effectively unusable without shell access. Plus ngIRCd's default `MaxNickLength=9` rejected
  ordinary names ("nickname too long"), and there was only one empty room.
- **Decision:** default chat to **public / no-login** (`VALARK_CHAT_PUBLIC=1`) — pick a nickname and
  join. Val Ark's reverse proxy + Use Mode already gate *who* reaches `/app/chat/`, so The Lounge
  needn't re-auth. Operators wanting per-user logins + persistent history set `VALARK_CHAT_PUBLIC=0`.
  Also: `MaxNickLength=30`, starter channels (`#valark #general #help #random`), a MOTD teaching
  `/list` + `/join`, an ark-themed leave message, and an idempotent start (real pid + port fallback).
- **Why:** the appliance principle is "it just works" — a trusted-LAN community box should let people
  in with zero friction, not gate casual chat behind account provisioning. `COMMUNITY_ACCOUNTS.chat`
  tracks the mode (`open`↔`host`) so the account panel and `adduser` stay correct either way.
- **Proven on the deployed ARM64 box** (not just CI): a 20-char nick registers, `/list` shows the
  channels, `/join` creates one, repeat `start` is a no-op. Real-box verification caught what the
  green test suite didn't — the login wall, the nick limit, the write-once config.

## 2026‑07 — Versioning re-baselined to honest pre‑1.0 (0.1.x)
- **Context:** early releases had jumped to a 1.x line (v1.0.0–v1.5.0), which implies a real,
  supported 1.0 user release we are nowhere near.
- **Decision:** we are **pre‑1.0**. Deleted the premature v1.0.0–v1.5.0 tags + GitHub releases
  (nobody depended on them) and re-baselined to **0.1.x**; the Phase 6 release (Health UX + live
  metrics) is **0.1.7**. The app version now has a single source of truth — the repo‑root
  `VERSION` file, read by `scripts/server.js` (`APP_VERSION`, served at `/api/health`).
- **Rule going forward:** stay on **0.x** until there's a genuine, stable 1.0 user release; **bump
  the `VERSION` file as part of each release** (the release-branch commit), so `/api/health` never
  goes stale again. Don't reach for 1.0 by increment — it's a deliberate "this is ready for real
  users" call.

## 2026‑07 — Reframe to a consumer appliance (scope‑first)
- **Context:** Val Ark was a power‑user/CLI tool; the goal is a router‑app / health‑app
  experience for a non‑technical owner ("one big EASY button").
- **Decision:** Scope the whole consumer experience *before* coding, as a cohesive 14‑doc
  hierarchy in [`docs/design/`](../design/README.md), grounded in a research sweep of 8
  comparable products ([research‑brief](../design/research-brief.md)). Implement per
  [roadmap](../design/roadmap.md); first sprint = **Commission + Recover**.
- **Why:** the surface area (commissioning, admin, access, recovery, storage, monitoring,
  moderation, deployment) is large and interdependent; getting the architecture right first
  avoids expensive rework.

### Key design calls (see the design docs for detail)
- **Access model:** operator chooses **Open (default) / Passworded / Accounts**; **two roles**
  (Admin + optional Viewer), never a usable default credential (only a one‑time claim token),
  **localhost/console always trusted as admin**. *Why:* a knowledge appliance's happy path is
  open‑on‑LAN; full RBAC is over‑engineering for the persona.
- **Recovery is paper‑backed + fully local:** a printed recovery card + two‑tier reset (button
  beeps / console menu / `valark setpassword`) + Safe Mode. *Why:* offline → no email reset;
  this is the single most important thing for "a box in a closet."
- **Content‑safety invariant:** the tiny `valark/state` (config) is physically separate from the
  multi‑TB content/model library; **no reset ever wipes Wikipedia/models** — only an explicit
  type‑the‑word disk‑erase does. *Why:* a panic reset must never re‑trigger a multi‑day download.
- **Storage is a growable pool:** primary (fixed, holds the brain) + add/remove drives (USB DAS),
  scaling to **SeaweedFS across computers**; track drives by UUID/label, graceful‑degrade on unplug.
- **Downloads:** disk‑sized **profiles** ("class roles") + **emphasis** (Knowledge/AI/Tools) drive
  curation weights + caps; "Fill everything (Recommended)" default.
- **On‑device moderation** (NPU) for shared uploads, default‑on, private, fail‑closed.
- **Deployment:** ship both a **Docker appliance image** *and* the bare‑metal bootstrap; both
  offline, both commissioned from the same wizard.

## 2026‑07 — Live host metrics, live-first (roadmap Phase 6, part 2 — monitoring)
- A scout→3-design→judge **workflow** weighed live-first vs stack-faithful vs MVP for the
  Telegraf+InfluxDB phase. Verdict: ship an **S-effort live-first MVP** and DEFER the whole
  named stack — because the zero-dep server can read `/proc` + `os` itself, so the Health
  page's **System tiles work day one on a bare box** (CI/VM, no services) and the retention
  layer becomes a pure enhancement, never a dependency.
- **This branch (`feat/metrics-live-gauges`):** one read-gated `GET /api/status/metrics`
  (`getHostMetrics()` — CPU%/mem/load/net-rate/temp/uptime + reused `getDiskStatus()`), a client
  `loadMetrics()` on the existing 15s Health cadence, a friendly **System tiles** strip + ONE
  additive `{key:'system'}` component card (informational: good/warn, `repair:null`, never red),
  and a **neutral "History: live-only"** indicator. NO new POST, NO service, NO secret, NO npm
  dep — so its adversarial surface is a pure local read (same class as `/api/status/disk`).
- **Why live-first beats stack-faithful here:** InfluxDB 2.x needs token-authed first-run setup
  (a real secret + onboarding dance); coupling the visible gauges to that daemon would make the
  Health strip blank whenever it's down. Live-first inverts it — always-on gauges, optional history.
- **Deferred to focused follow-up branches** (named precisely so they graft in additively):
  `scripts/services/{influxdb,telegraf}.sh` daemons + `telegraf.conf` (branch 2); a
  `GET /api/status/metrics/history` **InfluxDB passthrough** via a zero-dep `queryInflux()` —
  THE adversarial-review deliverable (injection/SSRF: never interpolate client range/metric into
  the Flux/URL, pin host to 127.0.0.1, `ECONNREFUSED → {influx:false}` at 200); `.env` token/URL
  keys (git-ignored / auto-minted to 0600 state, PUBLIC repo); `scripts/services/grafana.sh` at
  `/app/grafana/` under Advanced (branch 3); fleet aggregation + SSE metrics push (later).

## 2026‑07 — On-device moderation: fail-closed decision core first (Phase 7)
- A scout→3-design→judge **workflow** designed Phase 7 (screen user uploads with the box's own AI,
  offline). Key inversion it surfaced: **the model + inference is NOT the risky part** — text
  (llama-cli + the already-mirrored Llama-Guard-3-8B) and image (llama-mtmd-cli + moondream2/SmolVLM)
  run today via the exact `verify.sh` single-turn invocation. The **risky part is wiring to a
  surface**: pre-store multipart interception in the zero-dep proxy would replace pipeProxy's
  streaming `req.pipe`, break Range/resumability, risk OOM, add a hand-rolled multipart parser, and
  open a scan-vs-store TOCTOU. So that is **deferred**.
- **Branch order:** ship the fail-closed **decision core in isolation first** (`scripts/lib/moderation.sh`
  + `test-moderation.sh`), adversarial-review it, then wire surfaces. `moderation.sh check <file> --kind
  --sensitivity` → one JSON line + exit code (0 allow / 1 block / 2 hold); a pure `decide(signal,
  sensitivity)` unit; type by **magic bytes** (never the client extension/Content-Type; SVG screened as
  a script-bearing document); `VALARK_MODERATION_CMD` stub hook for tests.
- **FAIL-CLOSED is the invariant** (same class as the Safe-Mode `useMode` fix): absent binary/model,
  timeout, nonzero, unparseable stdout, or a NaN/out-of-range/unknown signal → **hold**, never a silent
  allow. The common bare-box/CI/VM case has no model → that IS the fail-closed path (needs no inference).
- **Deferred (own branches, each reviewed):** the real enforcement surfaces — a NodeBB post-store
  quarantine sweep (highest-risk: open self-registration, plain-file uploads, no proxy surgery) then a
  pre-store paste multipart intercept; the server endpoints (`/api/moderation/{check,queue,review}`,
  `/api/status/moderation`) + the admin Safety card + Sensitivity slider; and a dedicated NSFW **ONNX**
  head (Xenova/nsfw_image_detection) which needs a mirrored onnxruntime CLI/wheels — the mirrored ORT is
  library-only/CPU-only today. NPU (.rknn on RK3588/UT2) later.

## 2026‑07 — Metrics HISTORY is a zero-dep ring buffer (Phase 6b part 2)
- A scout→3-design→judge **workflow** pitted InfluxDB-v2-Flux vs InfluxDB-v1-InfluxQL vs a
  **zero-dep on-disk ring-buffer challenger**. The ring won (9/10): the server already produces
  every datapoint via `getHostMetrics()`, so it **samples itself** into a capped
  `state/metrics-history.jsonl` (~24h) and serves it at read-gated `GET /api/status/metrics/history`
  — sparklines under the shipped System tiles with **NO service, NO token, NO npm dep, NO outbound
  call**. Decisively, the ring is the ONLY path where sparklines render on a bare box/CI/VM (the
  InfluxDB path shows nothing until ~1GB of daemons + token onboarding run) — consistent with the
  live-first call above.
- **Fixed a real bug found in the design:** `getHostMetrics()` mutated a single module-global
  `_metricsPrev` for its two-sample deltas — the live endpoint and a sampler would contend over one
  baseline. Refactored to `getHostMetrics(prev = _metricsPrev)` returning the fresh counters as a
  non-enumerable `_sample` (never serialized); the live endpoint and the sampler each keep their OWN
  baseline. The always-on server is the SINGLE writer (like `heal-events.jsonl`); `loop.sh` never
  touches this file. `?window` is allowlist-mapped to a fixed point cap (never a path/slice index).
- **InfluxDB/Telegraf/Grafana are the deferred, opt-in Advanced/fleet upgrade** — grafted onto the
  SAME endpoint later under an allowlisted `?source=influx`, for long retention + cross-node rollup
  (the genuine InfluxDB payoff a single appliance may not need yet). That branch carries the
  injection/SSRF-sensitive `queryInflux()` passthrough → its own adversarial review.

## 2026‑07 — Health & Repairs page (roadmap Phase 6, part 1 — self-heal UX)
- Shipped the **Health/Repairs UX** first (metrics stack is a separate branch): a `#/health`
  page with **strict green/yellow/red** per-component cards, **fault attribution** (drive / this
  box / internet / config), a **healed-events feed**, and **one-click Repair**. Matches
  [errors-selfheal.md](../design/errors-selfheal.md) to the letter.
- **Data flows from reports the loop already should have produced.** `verify.sh` now serialises
  each functional check into `verify.json` as `checks[]` (`{status, comp, label}`); `loop.sh`
  now actually **writes `selfheal.json`** (a long-standing log line promised a file nothing wrote)
  + an append-only, capped **`heal-events.jsonl`** feed of genuine repairs. `GET
  /api/status/health` (read-gated) composes them; the **UI computes the component list
  client-side** (`computeComponents()`) from those + the live disk/services/kiwix status the
  shell already fetches — no duplicated health logic on the server, minimal new server surface.
- **One repair endpoint, not many.** `POST /api/maintenance/repair` (admin-only) runs the loop's
  own fixers via a **fixed argv** (`loop.sh once`) — the honest "fix everything" button — so no
  request data reaches a shell. Targeted fixes reuse what exists: per-service **Restart** →
  `POST /api/service/start`; Safe-Mode → the existing **Recover** flow. Deduped + 30s rate-limit.
- **Adversarial-reviewed** (new gated endpoint) before merge; `test-health.sh` + `health.spec.ts`
  cover the report shapes, the composition endpoint, the read-gate, and the admin-gate (the last
  via the fail-safe `VALARK_TEST_NO_SPAWN` hook so CI never runs the heavy loop).
- **Next:** stand up Telegraf + InfluxDB as mirrored services and feed live metrics into the strip.

## 2026‑07 — Download queue as the monitoring surface (roadmap Phase 5, part 1)
- Rebuilt the **Activity** view into a live download **queue**: rich per‑item cards (plain‑language
  label, animated progress bar + %, **ETA** from `startedAt`+progress, status pill, last line),
  **Cancel** (running) / **Retry** (failed), a "resumes automatically after a power loss" note, and
  **Retry‑not‑error framing** — a failed download reads "Interrupted — retries automatically" (true:
  the self‑heal loop re‑runs it), never a scary red error.
- **Live**: reuses the existing SSE stream — `start` stamps a client `startedAt` (for ETA),
  `progress`/`complete` re‑render the queue only when on `#/activity` (`_activityLive`, rAF‑debounced);
  `loadDownloads()` merges `/api/status/downloads` (server truth incl. `startedAt`) once on load to
  catch downloads already running. No backend changes, no new endpoints.
- **Deferred:** true pause/resume + reorder need backend support (the download scripts are aria2/curl
  subprocesses — only cancel exists today); noted as a follow‑up.
- **Profiles → curation weighting (part 2):** the wizard's profile pick now drives REAL librarian
  priority. `catalog.sh` resolves the profile (`VALARK_PROFILE` env → `settings.json` → `balanced`)
  and applies a **per‑bucket multiplier** on each candidate's value (knowledge 1.6× content, ai 1.6×
  models, tools 1.6× tools; off‑buckets 0.8–0.9×), so the box fills what the owner asked for; the
  planner still sorts by value/bytes. A Settings → **Downloads & Priorities** picker changes it live
  via admin‑only `POST /api/setup/profile` (validated to the 5 profiles (knowledge/ai/tools/survival/balanced)). `test-profile.sh` proves a
  profile shifts the fill; requesting a specific item still jumps the queue (pins).

## 2026‑07 — Access-mode enforcement + admin sessions (roadmap Phase 2 depth)
- The access layer now **enforces** (was "no gating yet"): stateless HMAC **admin sessions**
  (`auth.issueSession/verifySession`, `varksid` HttpOnly cookie), `POST /api/auth/login｜logout`
  with a per-IP login cooldown, `isAdmin(req)` = localhost OR valid session, and a POST **access
  gate** — admin-only actions always need admin; use-actions need admin in Passworded/Accounts
  mode; Open stays open. UI: a sign-in modal + Settings sign-in row; 401 `{needsAuth}` prompts it.
- **`adduser` upgraded** from localhost-only to admin (localhost OR logged-in) — a remote admin can
  now manage service accounts.
- **Scoped:** the read-wall (gating GET views in Passworded/Accounts) and full Accounts-mode named
  users are follow-ups; this ships the write/use + admin gate (the sensitive actions).
- Security surface → ran a 3-lens adversarial-review Workflow before merge. Tests:
  `tests/test-access.sh` (12, real-server gate via `VALARK_TEST_FORCE_REMOTE`) + auth session unit
  tests + server-api login/logout + a web-ui sign-in spec. Full suite 8 validators + Playwright 321/1.

## 2026‑07 — Consumer shell: Home status + Settings + Activity (roadmap Phase 3, issue #12)
- Delivered the shell's essence **additively** (no route regressions): a health‑app **Home
  status summary** (● All good / Working on it / Needs you + one sentence + big area/utility
  cards), a consolidated **Settings** hub (`#/settings`, Basic/Expert, the design's section list +
  inline Storage + About/Rescue), and an **Activity** feed (`#/activity`, live downloads + events
  placeholder). New nav link **Settings**; `computeHealth()` derives green/amber/red from the
  status the app already fetches (disk, services, downloads).
- **Why additive, not a full 4‑tab teardown:** ~15 existing tests click the current nav links
  (Software/Models/Library/Community/Getting Started). Ripping the nav to a literal four tabs would
  churn them for little user gain right now; the summary‑Home + Settings hub deliver the consumer
  experience without regressions. The literal 4‑tab cap (folding Software/Models into Home cards,
  Getting Started into the wizard) is a **noted follow‑up**.
- Tests: 5 Playwright specs (Home status + 6 cards, Settings nav + hub + inline Storage,
  Basic/Expert reveal, Activity, light‑theme render). Full suite 319/1 green, no regressions.

## 2026‑07 — First‑boot commissioning wizard (roadmap Phase 1, issue #11)
- Shipped the commissioning **core**: `scripts/lib/commission.js` (claim‑token gate + settings
  store, builds on `auth.js`), server `GET /api/setup/state` + `POST /api/setup/commission`
  (fail‑closed on the claim token from the LAN; localhost/console trusted), a startup **claim‑code
  console banner**, `valark claim｜setup-status`, and a **full‑page web wizard** (`#/setup`:
  Welcome → Claim → Name → Admin → Focus → Done) that auto‑takes‑over an un‑commissioned box.
- **Grandfather rule** so existing installs aren't hijacked: a box with a content/model library is
  treated as commissioned (see gotchas). Fresh box (empty library) → wizard.
- **Deferred to follow‑ups** (noted in the PR): the OS‑level discovery/enablement — mDNS
  `valark.local` (avahi), hostname set, captive‑portal at the network layer, the port‑80 toggle
  wiring, `setup.sh --VALARK_YES` integration, the on‑screen TUI, and the topic‑picker → curation
  weight mapping. The state machine + claim gate + wizard + create‑admin (wired to #10) are the core.
- Tests: `tests/test-commission.sh` (10 checks incl. fail‑closed + single‑use token +
  content‑safety), server‑api `/api/setup/state` shape+no‑leak, web‑ui wizard render+step‑through,
  and a fresh‑VM commissioning assertion in `provision.sh`.

## 2026‑07 — Access identity + recovery foundation (roadmap Phase 2, issue #10)
- **Safety net lands first** (research's #1 lesson). Shipped the backend + CLI foundation, no UI
  gating yet (Open stays default): `scripts/lib/auth.js` (scrypt‑hashed admin store, shared by
  server + CLI), `scripts/valark` (`setpassword｜auth status｜auth list｜verify｜usemode｜reset
  --tier1/--tier2`), and read‑only `GET /api/auth/status`.
- **No usable default credential** — an un‑set admin means Open mode + "localhost/console is
  admin," which is exactly what makes password‑less recovery safe. Passcode is scrypt‑hashed in a
  0600 `<state>/auth.json`; the hash/salt never cross the API.
- **Content‑safety invariant is structural + tested:** `STATE_DIR` is separate from
  content/models, so `reset --tier1/--tier2` provably can't wipe the library
  (`tests/test-auth.sh` sha256‑verifies sentinels survive). Content‑erase is deliberately NOT in
  this CLI (it needs the typed‑confirmation UI flow).

## 2026‑07 — First `dev → main` release (v1.1.0) + community sign‑ups (PR #2/#3)
- **Adopted the branch model in practice:** PR #1 (foundational) landed on `dev`; the
  community‑signups quick win (PR #2) landed on `dev`; then the first **`dev → main` release**
  (PR #3) shipped **v1.1.0**. Release cleared the high bar: CI green + full local Playwright
  (310/1) + services e2e (11/0) + **fresh‑VM matrix 27/0 across Ubuntu 22.04/24.04/26.04**.
- **CI is a real gate now.** A fresh CI checkout has *no mirror*, so host‑population tests
  (on‑disk binaries, non‑empty status maps) **skip‑when‑empty**; CI validates code + endpoint
  shape + upstream URL health, while populated‑system e2e runs locally + in the VM matrix. One
  real strict‑mode locator bug was fixed (`#install-btn-<id>` vs `:has-text("Mirror")`).
- **Community account model = per‑service tech, not one UX** ([[val-ark-forum-proxy-burst-quirk]]):
  `COMMUNITY_ACCOUNTS[id].signup` ∈ `host｜self｜shared`. chat/mail = host‑provisioned
  (`<svc>.sh adduser`, one‑step for mail); forum = NodeBB self‑register; paste = shared gated
  instance. `POST /api/service/adduser` is **localhost‑only** (minting a login is admin).
- **Release merge = rebase (main requires linear history).** Rebase‑merge re‑parents dev's
  commits onto `main`, so after a release `main` and `dev` share *content* but diverge by *SHA*
  (`git diff origin/main origin/dev` is empty; commit counts differ). This is benign: GitHub's
  rebase‑merge skips already‑applied patches, so the next release applies only new commits. Tag
  `main`'s tip with `scripts/release.sh` (unprefixed `X.Y.Z` from the `VERSION` file — see the
  release‑tags decision above; the old "untracked `.memsearch/` trips the clean‑tree check"
  workaround is obsolete).

## 2026‑07 — Feature branch: discover/request + self‑replication + tests (PR #1)
- Shipped + deployed to the ARM64 NAS test node + tested (337 tests): Library relabel; Community hub; one‑click
  LAN/tailnet **catalog + request** with **pin + cap‑aware auto‑evict**; **offline
  self‑replication** (git bundle + Node runtime + `bootstrap.sh` + `mirror-self.sh`); fixed
  per‑platform app downloads (`/api/archive`); cross‑arch service fixes; curation (Linux docs +
  setup assistants); the **test library + offline HTML report + fresh‑VM matrix (Ubuntu 22/24/26)**.
- **Why the request/evict shape:** the librarian already did diversity→small‑value→fill→evict;
  a per‑item `request` that pins + evicts the lowest‑priority *unpinned* content extends it
  cleanly and honors the footprint cap.

## Earlier project facts (fleet, curation)
- **Fleet/hardware & mesh:** big shared disk, several boxes (an ARM64 Grace‑Blackwell node, an x86 GPU workstation, a router, an ARM64 NAS),
  NFS/Syncthing sharing, tailscale‑ssh. The data disk is the one shared mirror; GPU nodes infer
  over the network. (Host‑specific addresses/creds are **not** in git — see the deployment host's
  own `.env`.)
- **Curation priority model:** live Kiwix OPDS catalog → planner phases
  diversity → small‑value → fill → evict‑for‑better; value = curated category weight + language +
  density + topic boosts (now including a strong Linux/shell boost, so an offline user can get
  setup help from the box).
