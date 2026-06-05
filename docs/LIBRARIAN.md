# Librarian — scalable disk-fill, curation & self-healing

The **Librarian** turns Val Ark into a self-filling, self-healing offline mirror.
It fills a disk of *any* size from live catalogs, prioritizing diversity and
value, and a 24/7 loop keeps everything current, intact, and verified.

## Where data lives (configurable)

All bulk data lives on a single **data root**, resolved once and shared by every
script. Nothing host-specific is committed — your machine's settings go in a
git-ignored `.env` (copy `.env.example`):

```bash
cp .env.example .env
# edit .env:
VAL_ARK_DATA=/mnt/yourdisk       # the disk to fill; models reused at $VAL_ARK_DATA/models
```

If unset, the data root is autodetected (largest writable `/mnt/*` mount, else the
repo dir for single-disk/dev use). Val Ark's own trees live under
`$VAL_ARK_DATA/val-ark/{tools,content,sources,assets,installers,state}`; models
stay at `$VAL_ARK_DATA/models`. Repo-relative dirs are symlinked to the disk so
the web server and legacy scripts work unchanged. Resolution + disk math live in
`scripts/lib/valark-env.sh`.

## The priority model

The disk fills in the order you'd curate by hand (`scripts/lib/planner.py`):

1. **Diversity first** — one item (the *smallest*) from every category before
   deepening any single one. Guarantees breadth across ~45 categories (22 ZIM
   topics, 18 model modalities, OS/router/netboot installers).
2. **Small valuable files** — then items by **value ÷ byte**, capped per category
   so a prolific category (devdocs, TED…) can't crowd out diversity.
3. **Fill remaining space** — then the big flagships by intrinsic value (full
   Wikipedia, large model quants, distro ISOs) until a reserve is reached.
4. **Cut back for better small items** — when the disk is full and a new small
   high-value item appears, evict the *lowest value/byte* managed item (never the
   sole representative of a category) to make room.

Everything scales from live `df` headroom (`avail − max(2%, 50GB)`); there are no
hardcoded sizes. Same-content ZIM flavours (maxi/nopic/mini) collapse to the most
complete one.

## Catalogs (sources of candidates)

| Source | File | Notes |
|--------|------|-------|
| Kiwix ZIM library | live OPDS via `scripts/lib/kiwix_catalog.py` | **Always current** — ZIM dates never go stale. ~1700+ entries across 9 languages by default (`VALARK_ZIM_LANGS`). |
| Models (diversity) | `data/models-extra.tsv` | Small high-value models across 18 modalities (embeddings, rerankers, tiny VLMs, OCR, depth, segmentation, detection, audio, time-series). |
| OS / router / netboot | `data/installers.tsv` | Ubuntu/Debian/Fedora/Alpine/Arch/RPi ISOs, OpenWRT firmware, netboot.xyz, open NVIDIA L4T — for PXE / mesh commissioning. |

The big LLM/STT/TTS/VLM/image catalog is still managed by `download-models.sh`.

## Commands

```bash
scripts/librarian.sh status        # disk + per-category coverage
scripts/librarian.sh plan          # dry-run: the ordered plan + totals
scripts/librarian.sh fill          # download the plan (resumable, never aborts)
scripts/librarian.sh fill --time 1800 --max-bytes 50G   # bounded chunk
scripts/librarian.sh verify        # integrity-check managed files; requeue bad
scripts/librarian.sh evict --need 100G   # free space, lowest value/byte first
scripts/librarian.sh refresh       # re-pull the live ZIM catalog
```

Downloads are resumable (`curl -C -` / `hf`), retried, size-verified, atomically
renamed, recorded in `state/manifest.tsv`, and a single `flock` ensures only one
filler runs at a time. A `state/STOP` flag halts filling.

## The 24/7 loop

`scripts/loop.sh once` runs one maintenance cycle:

1. ensure the data disk is **writable** (self-heals an NTFS volume Windows left
   read-only; preserves any NFS export),
2. repair the repo↔disk symlink layout,
3. **refresh the live catalog** → content links self-heal (no stale dates),
4. **check & repair links** — tool/installer URLs (retry-aware: curl 000/429/403
   are transient, not dead), web-ui assets, symlinks → `state/linkcheck.txt`,
5. **integrity verify** → requeue corrupt/short downloads,
6. **top-up fill** (bounded; skipped if a fill already runs),
7. **functional verification** (`scripts/verify.sh`) — tools run, Kiwix serves a
   real ZIM, a tiny LLM infers, the web API answers, and each configured remote
   mesh node (`VALARK_FLEET` in `.env`) is reachable and sees the shared content,
8. health report (`state/health.json`) + a fleet coordination drop
   (`state/coordination/`).

Install it as a durable, reboot-surviving job:

```bash
scripts/loop.sh install 30     # run a cycle every 30 min (flock-guarded)
scripts/loop.sh uninstall
scripts/loop.sh run 1800       # or run in the foreground forever
```

## Multi-arch / mesh

Content and installers cover x86_64, **aarch64 (Jetson Orin / Thor / GB10)**,
Apple Silicon, Windows, and **OpenWRT routers** (see [PLATFORMS.md](PLATFORMS.md)).
The data root is NFS-exportable so mesh nodes mount one shared mirror; the
verification loop checks each node over SSH.
