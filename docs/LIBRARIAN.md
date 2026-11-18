# Librarian — scalable disk-fill, curation & self-healing

↑ [Docs](README.md) · [Repo root](../README.md)

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

0. **Grid-down essentials** — before anything else, the ranked list in
   [`data/essentials.tsv`](../data/essentials.tsv): safe water, field medicine,
   medicines, food, knots, post-disaster recovery, a pocket Wikipedia, a small
   offline assistant, then repair / power / radio / farming references and the
   network-boot images. Each entry takes its **smallest** variant (mini/nopic ZIM)
   and an entry that does not fit is skipped, so a 2 GB stick still gets the most
   critical ~20 items and a big disk later upgrades to the full variants in
   phases 1–3. Rows can target an owner profile (`focus`), e.g. Army field manuals
   only for `survival`.
   Once the full variant is complete on disk, the end of each `fill` removes the
   now-redundant small copy (managed + unpinned only; never while a STOP halted the
   fill). **Known trade-off:** on a big disk an essential ZIM is downloaded twice
   (the mini first, the maxi later, then the mini is pruned), and on a disk where
   the maxi would fit alone but not beside the mini, the maxi is not fetched and
   that essential stays on its mini. This is on purpose: getting a critical copy
   onto the disk fast beats saving the mini's bytes (see
   [decisions](knowledge/decisions.md#mini-then-maxi)).
1. **Diversity first** — one item (the *smallest*) from every category before
   deepening any single one. Guarantees breadth across ~40+ categories (22 ZIM
   topics, 17 model modalities, and netboot / OS-install / router-firmware /
   jetson-bsp installers).
2. **Small valuable files** — then items by **value ÷ byte**, capped per category
   so a prolific category (devdocs, TED…) can't crowd out diversity.
3. **Fill remaining space** — then the big flagships by intrinsic value (full
   Wikipedia, large model quants, distro ISOs) until a reserve is reached.
4. **Cut back for better small items** — when the disk is full and a new small
   high-value item appears, evict the *lowest value/byte* managed item (never the
   sole representative of a category) to make room.

Everything scales from live `df` headroom (`avail − max(2%, 50GB)`); there are no
hardcoded sizes. On a shared disk an optional footprint cap bounds Val Ark itself:
`VALARK_MAX_GB` caps its total usage (budget = min(headroom, cap − used)) and
`VALARK_MODEL_MAX_GB` skips any single model bigger than N GB. Same-content ZIM
flavours (maxi/nopic/mini) collapse to the most complete one.

## Catalogs (sources of candidates)

| Source | File | Notes |
|--------|------|-------|
| Kiwix ZIM library | live OPDS via `scripts/lib/kiwix_catalog.py` | **Always current** — ZIM dates never go stale. ~1700+ entries across 9 languages by default (`VALARK_ZIM_LANGS`). |
| Models (diversity) | `data/models-extra.tsv` | Small high-value models across 17 modalities (embeddings, rerankers, tiny VLMs, OCR, depth, segmentation, detection, audio, time-series). |
| OS / router / netboot / server source | `data/installers.tsv` | Distro ISOs (Alpine/Debian/Ubuntu/…), OpenWRT firmware, netboot.xyz, Jetson BSP — for PXE / mesh commissioning — plus `server-source`: upstream LAMP + LAN-infrastructure releases (httpd/APR, PHP, MariaDB, PostgreSQL, nginx, OpenSSL/OpenSSH, BIND, Kea, dnsmasq, Unbound, Samba, Dovecot, WordPress, Nextcloud, Gitea, …). |
| Offline .deb sets | `data/apt-sets.tsv` | Server package sets resolved with all dependencies per Ubuntu suite+arch by `scripts/lib/apt_offline.py build --suite noble --arch arm64 --set lamp --dest <dir>` → a flat local APT repo for a LAN with no internet. |

The big LLM/STT/TTS/VLM/image catalog is still managed by `download-models.sh`.

### Offline .deb sets: exit codes and a real-box check

`apt_offline.py` exits with one of these codes:

- **0** complete.
- **1** `apt-get update` or a set's resolve failed, or the environment is broken (`apt-get` is
  missing, `--dest` isn't writable).
- **2** a download failed. A rerun skips finished files and re-downloads each failed one whole.
- **3** incomplete: packages missing for that suite/arch, an empty index, or `.deb`s left
  unindexed. `--allow-missing` accepts missing packages.
- **64** usage error: a bad option, an unknown set, an unreadable `--tsv`, or a missing
  `--suite`/`--arch`/`--dest`.

When several apply, the most severe wins, in that order: 64, 1, 2, 3, 0. So a failed download
never hides a set that could not be resolved at all.

CI only runs `apt_offline.py` against stubs and fixture lists (`tests/test-server-stack.sh`); it never
talks to the real Ubuntu archive. Before trusting a change to it, check on a real Ubuntu box with
`apt-get` and `ubuntu-archive-keyring` installed (use a scratch `--cache` and `--dest`, e.g. from
`mktemp -d`):

1. **Cross-arch resolve, empty dpkg status.** On an x86_64 host run
   `apt_offline.py resolve --suite noble --arch arm64 --set lamp --cache <scratch>`. Expect exit 0,
   every URL on `ports.ubuntu.com`, `libc6_…_arm64.deb` in the list (the empty status pulled in the
   base dependencies), and a SHA256 in the 4th column of every row (otherwise stderr prints a count: "N package(s) have no SHA256").
2. **Native arch.** The same with `--arch amd64`: URLs on `archive.ubuntu.com` / `security.ubuntu.com`.
3. **Build.** `apt_offline.py build --suite noble --arch arm64 --set lamp --dest <dir> --cache <scratch>`
   exits 0, stderr says `indexed N packages` with no ".deb not in lists", `<dir>` has `Packages` +
   `Packages.gz` and no `*.part`. Run it again with `--no-update`: it finishes fast, downloading
   nothing.
4. **Host untouched.** `/etc/apt` and `dpkg -l` are unchanged and no host `apt.conf.d` hook ran
   (the APT root lives entirely under `--cache`).
5. **Install offline.** On a disposable target of that arch with no network (a VM, or a container
   started with networking disabled and `<dir>` mounted), add
   `deb [trusted=yes] file:<dir> ./` as the only source, `apt-get update`, then install the set's
   packages: every dependency resolves from `<dir>`.
6. **Exit codes.** `--set no-such-set` exits 64. An interrupted download (pull the network during
   step 3) exits 2, and rerunning re-fetches the failed files and finishes the job.

## Commands

```bash
scripts/librarian.sh status        # disk + per-category coverage
scripts/librarian.sh plan          # dry-run: the ordered plan + totals
scripts/librarian.sh fill          # download the plan (resumable, never aborts)
scripts/librarian.sh fill --time 1800 --max-bytes 53687091200   # bounded chunk (secs / raw bytes)
scripts/librarian.sh verify        # integrity-check managed files; requeue bad
scripts/librarian.sh evict --need 107374182400   # free space (raw bytes), lowest value/byte first
scripts/librarian.sh refresh       # re-pull the live ZIM catalog
scripts/librarian.sh maintain      # refresh + verify + bounded top-up + report (loop core)
```

Downloads prefer **aria2** (8 connections, ~3x faster on per-connection-throttled
mirrors), falling back to single-stream `curl -C -` (and `hf` for repo pulls). All
are resumable, retried, size-verified, atomically renamed, recorded in
`state/manifest.tsv`, and a single `flock` ensures only one filler runs at a time.
A `state/STOP` flag halts filling, and a fill that stopped because of it also skips the
superseded-variant prune, so nothing is deleted after you ask it to stop (the prune runs at the end
of the next fill). Resumers never mix: an aria2 partial (marked by
its `.aria2` control file) is only ever resumed by aria2 — the curl fallback skips
it, because an aria2 `.part` is segmented and `curl -C -` would "complete" it with
holes. Failed attempts keep the partial + control file so the next cycle resumes
where it left off; abandoned partials are garbage-collected by `verify` after
`VALARK_PARTIAL_MAX_AGE_DAYS` (default 14).

## The 24/7 loop

`scripts/loop.sh once` runs one maintenance cycle:

1. ensure the data disk is **writable** (self-heals an NTFS volume Windows left
   read-only; preserves any NFS export),
2. repair the repo↔disk symlink layout,
3. **ensure the web server is up** (`scripts/server.js`, which auto-launches
   `kiwix-serve` for any complete ZIM),
4. **ensure standard-port access** — when `VALARK_WEB_PUBLIC_PORT` is set (e.g.
   80), keep an idempotent iptables NAT redirect public→web port in place
   (LAN + VPN interfaces; loopback untouched),
5. **keep enabled community services running** (`VALARK_SERVICES` in `.env` —
   chat, mail, forum, paste),
6. **refresh the live catalog** → content links self-heal (no stale dates),
7. **check & repair links** — tool/installer URLs (retry-aware: curl 000/429/403
   are transient, not dead), web-ui assets, symlinks → `state/linkcheck.txt`,
8. **integrity verify** → requeue corrupt/short downloads,
9. **top-up fill** (bounded; skipped if a fill already runs),
10. **weekly tool refresh** — re-run the tool mirror so apps track their latest
    upstream versions (`VALARK_TOOL_REFRESH_DAYS`, default 7; a failed pass
    retries in a day),
11. **functional verification** (`scripts/verify.sh`) — tools run, Kiwix serves a
    real ZIM, a tiny LLM infers, the web API answers, and each configured remote
    mesh node (`VALARK_FLEET` in `.env`) is reachable and sees the shared content
    (plus a Playwright UI smoke when installed),
12. **self-heal snapshot** — write `state/selfheal.json` (the loop's own cycle
    snapshot) and append any genuine repairs to `state/heal-events.jsonl` (the feed
    behind the Health page), plus a fleet coordination drop (`state/coordination/`).
    This is **distinct from `state/health.json`**, which the librarian's own
    `maintain` command writes (disk + per-category coverage); the loop invokes
    `maintain` as part of steps 6/8/9 above, so both files land each cycle.

Install it as a durable, reboot-surviving job:

```bash
scripts/loop.sh install 30     # every 30 min + @reboot resume (flock-guarded)
scripts/loop.sh uninstall
scripts/loop.sh run 1800       # or run in the foreground forever
```

## Multi-arch / mesh

Content and installers cover x86_64, **aarch64 (Jetson Orin / Thor / GB10)**,
Apple Silicon, Windows, and **OpenWRT routers** (see [PLATFORMS.md](PLATFORMS.md)).
The data root is NFS-exportable so mesh nodes mount one shared mirror; the
verification loop checks each node over SSH.
