<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/popup/librarian-dark.svg">
  <img src="img/popup/librarian-light.svg" width="100%" alt="Pop-up book scene: The Librarian fills the shelves. Essentials first, then diversity, small and valuable, fill, then trade up.">
</picture>

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
   topics, 18 model categories, and netboot / OS-install / router-firmware /
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
| Models (diversity) | `data/models-extra.tsv` | Small high-value models across 18 categories (setup-assistant chat LLMs, small LLMs, code, embeddings, rerankers, tiny VLMs, OCR, depth, segmentation, detection, audio, time-series, safety). |
| Models (scouted, weekly) | `<state>/catalog/models-scouted.tsv` | **New open models, found automatically** by `scripts/lib/hf_scout.py` — see [Model scout](#model-scout-hf_scoutpy). Planned after the curated rows on a small disk. |
| Lastbook (survival library) | live release via `lastbook_mirror.py candidates`, cached daily in `<state>/catalog/lastbook.tsv` | See [Lastbook](#lastbook-planned-like-any-other-content). Each pack, state map (+ its address index), the model and the installers. |
| OS / router / netboot / server source | `data/installers.tsv` | Distro ISOs (Alpine/Debian/Ubuntu/…), OpenWRT firmware, netboot.xyz, Jetson BSP — for PXE / mesh commissioning — plus `server-source`: upstream LAMP + LAN-infrastructure releases (httpd/APR, PHP, MariaDB, PostgreSQL, nginx, OpenSSL/OpenSSH, BIND, Kea, dnsmasq, Unbound, Samba, Dovecot, WordPress, Nextcloud, Gitea, …). |

The grid-down list in `data/essentials.tsv` is not a source of its own: it names ZIMs, models and
installers from the catalogs above, and the planner takes the matches first (phase 0).

The big LLM/STT/TTS/VLM/image catalog is still managed by `download-models.sh`.

### Lastbook: planned like any other content

[Lastbook](https://lastbook.org) is sized by this planner, not by a fixed share of the disk (#203).
`catalog.sh` turns its live release into rows. It uses `lastbook_mirror.py candidates`, which
applies the same URL allow-list and validation as a mirror run. The rows are cached daily, and
a failed refresh keeps the old cache. There is one row per **pack** (with the base maps, which
ride with any pack), one per **state map** (with its address index), one for the **model**
(category `lastbook:model`, bucket `models`, so `VALARK_MODEL_MAX_GB` applies) and one for the
**installers**. An entry with no size is left out, so it can never look free. The rows carry a
value and a size like every other row, and the owner profile weights them.

- **Bytes still to fetch.** A Lastbook row is charged only what it still has to download. Files
  held at their listed size cost 0, and a resumable `.part` is credited, so a half-fetched
  Medium is finished rather than stranded behind a fresh Small. The plan's size column for
  these rows is that remainder.
- **The packs nest** (Small ⊂ Medium ⊂ All), so the planner plans at most **one** pack.
  - Diversity takes the Small pack. A later phase may **upgrade** the planned pack to a larger
    one that fits, and the smaller pick's bytes come back.
  - A pack held and verified on disk satisfies every pack up to its size. Held means recorded
    in the mirror's `.lastbook-verified.json`, at its recorded size, summed per pack. A `.part`,
    a symlink or a wrong size does not count. A larger pack is still an upgrade.
  - The held pack's **own** id is still planned and charged when its listed files are not all
    there. That covers a re-release under a new name and a missing base map, so a refresh is
    budgeted too.
  - **One exception:** a phase-0 essential pack (the survival profile's Small) stays planned
    beside a later, larger pick. `fill` fetches the essentials first, then the rest, and the
    mirror's nested prune removes the Small once the larger pack is verified.
- **Maps, the model and the installers need a pack**, held or planned. The model never takes a
  diversity slot, and a held Lastbook GGUF does not cover the curated `model:assistant`
  category.
- **Survival profile:** `data/essentials.tsv` lists the Small pack and the installers (kind
  `lastbook`). They are planned in phase 0, and a held Medium or All satisfies them.
- **The fetch stays with the mirror.**
  - `fill` hands the planned Lastbook rows to `scripts/tools/lastbook.sh --plan-file`. The
    phase-0 rows go in their own batch at their turn, and every planned row goes at the first
    later row's turn.
  - Each batch is checked against free space as a whole and bounded by the fill's remaining
    `--time`. The `.part` files resume next cycle. Only bytes the mirror reports as added are
    counted. A busy Lastbook lock (exit 75) is a skip, not a failure.
  - `lastbook_mirror.py` then runs `--pack auto --pack-limit <planned>`. That means the planned
    pack or a smaller one, so a planned All that is broken upstream falls back down the ladder,
    never below the held pack. It gets the planned maps, model and installers, with a budget of
    the planned bytes still to fetch.
  - Every auto guard still holds: step up never down, HEAD-confirmed upgrades, keep the held
    pack. When no pack will be held after all, the planned maps, model and installers wait too.
  - Downloads stop at the reserve, which is re-checked every 256 MiB, and at the STOP flag.
  - The prune rules from #182/#194 are unchanged: only recorded files go, nested packs go only
    after a larger one is verified, and nothing goes when the release looks truncated.
  - **Nothing held is deleted before its replacement is verified.** That covers a held map,
    address index, model or installer version that the release no longer names (a new app
    version, a renamed map or model). Such a file stays until what replaces it is downloaded
    and verified. Installers and the model are each **one slot**: an old installer or model
    file waits for every current installer or model, even if upstream renamed the model to a
    new id. A map or address index waits for the current entry with the same id. If the
    planner had no room for the replacement, the old copy is kept, and the replacement stays
    charged in later plans.
  - Some files are kept rather than pruned, each with a log line saying why: a map or address
    index whose entry cannot be told, and an address index that upstream marks
    `available: false`. Only a map or address index entry the release dropped altogether goes,
    and the truncation guards still apply to that.
  - In planner mode a base-map refresh the planner did not charge is skipped, not deferred, so
    it never exits 3 and blocks the prune (such as the nested Small after All verifies). The
    old base map stays until its replacement is verified.
  - The mirror records each file's entry id in its stamps, so the link survives once the kept
    manifest moves on. Candidate rows carry each file's sha256, so a re-release under the same
    name and size counts as not held and is charged.
  - These files never enter `state/manifest.tsv`, so `verify` and `evict` never touch them.
    `catalog` and `request` never offer them, because there is no per-item path; the Lastbook
    card mirrors the release.
- Run on its own (the weekly tool refresh, the Mirror button), `lastbook.sh` first asks
  `librarian.sh lastbook-plan` for the same rows. A lock lets only one Lastbook mirror run go
  at a time.
- **Opt-outs apply at once.** The cache always holds the full offer. `VALARK_LASTBOOK_MAPS`
  (`none`, or a code list), `VALARK_LASTBOOK_ADDRESSES=none`, `VALARK_LASTBOOK_MODEL=no` and
  `VALARK_LASTBOOK_APPS=none` filter the rows when they are read, so a `no` holds even with a
  day-old or offline cache. In planner mode, `MAPS=all` / `MODEL=yes` only mean "offered", and
  the planner still decides whether they fit.
- **The operator's choice keeps the planner out.** In these cases Lastbook is sized by its own
  share as before:
  - `VALARK_LASTBOOK_PACK=every` (the server / NAS opt-in) or one explicit pack;
  - an explicit `VALARK_LASTBOOK_BUDGET`, or `VALARK_LASTBOOK_PLAN=0`;
  - `VALARK_LASTBOOK_ADDRESSES=all` or a code list (the planner only folds an address index
    into its map, and would otherwise quietly reduce these to `follow`);
  - a `VALARK_LASTBOOK_DIR` on **another filesystem** than the data root (the planner's budget
    is the data root's, and there is no per-destination budget yet);
  - a selection option on `lastbook.sh`'s command line.

  `VALARK_LASTBOOK_BUDGET_PCT` is **deprecated**: set on its own it also selects share mode,
  and logs a warning.

### Model scout (`hf_scout.py`)

The curated catalog only changes when someone edits it, so good new open models would
never reach a box on their own. Once a week (`librarian.sh maintain`, TTL
`VALARK_SCOUT_TTL`, default 7 days) the Librarian asks the Hugging Face API what is new
and writes the picks to `<state>/catalog/models-scouted.tsv`, in the `models-extra.tsv`
schema. `librarian.sh scout` does it now.

- **speech-vision** (default): **speech and vision models are small but important, so they
  always come early.** ASR, TTS, voice activity, audio enhancement/classification/generation,
  and object detection (YOLO-class), segmentation, depth, image classification, zero-shot,
  keypoints, image features and OCR. **Any age** (the classics count), real repo size ≤ 6 GB,
  at least 15 likes, drawn from each task's all-time most-downloaded and most-liked lists, up
  to 150 per run. Valued about 600–700, ahead of the other scouted rows. No `safetensors`
  requirement (many are ONNX / PyTorch / NeMo), and `-base` is kept (here it is a size:
  `whisper-base`, `vit-base`).
- **small** (default): any modality, created in the last 180 days, **real repo size ≤ 10 GB**
  (summed from the repo's file list, not guessed), at least 40 likes (10 for a repo owned by
  a well-known lab), up to 200 per run. These are the cheap wins: OCR, embeddings, small
  LLMs and VLMs, speech, time-series.
- **frontier** (opt-in, `VALARK_SCOUT_SWEEPS=small,speech-vision,frontier`): open-weight releases with
  ≥ 20B parameters from the last 18 months, from a lab or heavily liked. No size cap; the
  planner's value-per-byte order fills them last, so they only land on a big disk.

Both skip gated and private repos (no accepted licence), quantised / converted re-uploads
(the originals are kept), speculative-decoding heads, abliterated / uncensored fine-tunes,
`-base` checkpoints and any repo the curated catalog already names. The small and frontier
sweeps only consider repos that publish `safetensors` metadata (their size pre-filter needs
it); the speech-vision sweep sizes every candidate from its file list instead.

How they rank: speech-vision rows get about 600–700, small rows 300–550, frontier 200–400,
against 480–900 for the curated rows, and reuse the curated category words (`small-llm`,
`tiny-vlm`, `embed`, `speech-asr`, `detection`, …; captioners are `captioning`, anything else
`scouted`). They never take a diversity slot and are not shielded from eviction as a
category's only item, and they skip the small-valuable phase (their tiny size would win it
outright). They are planned in the final fill phase by intrinsic value: after every curated
item valued above them (the setup-assistant LLMs, for example), before curated items valued
below them, with speech and vision picks ahead of the other scouted rows. Under disk
pressure scouted rows are evicted before any curated item. A curated model too big for the
small-valuable phase and valued below a speech-vision pick (`qwen25-coder-7b`, 670) can wait
behind it on a small disk; raise its value in `data/models-extra.tsv` if it must come first.

A scout that cannot reach every listing never replaces a good cache (the ZIM catalog's completeness rule); a failed attempt waits
`VALARK_SCOUT_RETRY` (1 day) before the next, a run is capped at `VALARK_SCOUT_TIMEOUT` (30 min), and the scout's stderr is kept next to the
cache as `models-scouted.tsv.err`. `VALARK_SCOUT=0` turns it off and ignores the cache.
Rows are fetched with `hf download --include '*'` like any `repo` row; a whole-repo pull
counts as present only once it finished (`.valark-complete` stamp). Tests:
`tests/test-hf-scout.sh`.

### Standalone mirrors (run by hand, not part of `fill` / the loop)

These catalogs are read by their own CLIs, which you run (or schedule) yourself; `librarian.sh
fill` and `loop.sh` do not plan them.

| Source | File | Notes |
|--------|------|-------|
| Developer + security stack | `data/dev-stack.tsv` | The kit to build, run and secure software offline: every supported Python (python.org installers + relocatable builds + a top-1000 PyPI wheelhouse), compilers (LLVM, GCC/GNU sources, MinGW, Go, Rust, JDK, CMake…), decompilers/RE (Ghidra, radare2/rizin/Cutter, x64dbg, jadx, ILSpy, Frida…), security tools (Nmap, Wireshark, ZAP, Metasploit, nuclei, Trivy, Zeek, Suricata, Kali ISOs…), containers + Kubernetes (Docker static, Podman, kubeadm/kubectl, MicroK8s snaps, k3s, Helm…), cloud/IaC, S3-compatible storage (MinIO source, SeaweedFS, RustFS, versitygw, rclone) and databases (Neo4j + Relate, Milvus, Qdrant, DuckDB, ClickHouse, Valkey, OpenSearch…). Current release of each, resolved live by `scripts/lib/release_mirror.py` (see below). |
| Offline .deb sets | `data/apt-sets.tsv` | Server + developer/security package sets resolved with all dependencies per Ubuntu suite+arch by `scripts/lib/apt_offline.py build --suite noble --arch arm64 --set lamp --dest <dir>` → a flat local APT repo for a LAN with no internet. |
| Upstream source repos | `data/source-repos.tsv` | Full-history git bundles of 200+ upstream repos via `scripts/lib/git_bundle_mirror.py plan\|mirror\|verify` (see [TOOLS.md](TOOLS.md#content-mirrors)). |

### Developer + security stack (`release_mirror.py`)

`data/dev-stack.tsv` lists upstream projects, not files: each row names a resolver `kind`
(GitHub latest release, a directory index, a GNU package, go.dev, python.org, PyPI, the PyPI
top-N list, a URL template, or a snap) and `release_mirror.py` turns it into the current files
for every platform the project ships. Rows rank small, irreplaceable tools above bulk fill
(Kali ISOs, the PyPI wheelhouse).

```bash
python3 scripts/lib/release_mirror.py plan                       # url, dest, size, digest, volatile rows; no downloads
python3 scripts/lib/release_mirror.py plan --group security      # one group (or --only <ref>, repeatable)
GITHUB_TOKEN=... python3 scripts/lib/release_mirror.py fetch --dest "$DATA_ROOT/val-ark/dev-stack"
```

- **Resume and verify.** `fetch` resumes `.part` files with Range. Before renaming a file into
  place it checks the length, then the upstream digest: sha256, or sha3-384 for snaps. The
  length comes from the planned size, or the server's `Content-Length` / `Content-Range` total
  when the size isn't known up front (source tarballs, templates).
- **Interrupted downloads.** A cut-short body keeps its `.part` and is resumed. A `.part` that
  is already complete is verified and kept. That covers a run killed before the rename, and a
  server answering 416.
- **What gets skipped.** Files already complete are skipped. Nothing is written outside `--dest`.
- **Layout.** Versioned rows land at `<group>/<project>/<version>/<file>`, so a new release sits
  beside the old one. Index rows land at `<group>/<host>/<dir path>/<file>`.
- **Volatile rows.** These are files whose name stays the same across upstream versions:
  `=latest` templates such as the Metasploit installers, `SHA256SUMS`, and `current/`
  directories. Those with a digest (the Kali ISOs) are checked against this run's digest,
  through the `.verified` stamp, so they're re-hashed only when the digest, size or mtime
  changed. Those without one are re-checked with a HEAD request against a `<file>.source.json`
  sidecar, and downloaded again when upstream changed or the server refuses HEAD.
- **Size.** About 130 GB without the wheelhouse (late 2026). The top-1000 wheelhouse adds about
  64 GB (13,000 files): the newest version of each project, every platform's wheels.
- **Integrity.** A file checked against an upstream digest gets a `<file>.verified` stamp
  (digest, size, whole-second mtime), so later runs don't re-hash multi-GB ISOs while all
  three still match. Corruption that keeps the size and mtime (bit rot, a bad NAS write) is
  caught only by a full re-hash: run with `VALARK_REHASH=1`, or delete the `*.verified` files.
  GNU tarballs and GitHub source tarballs have no upstream digest, so they are checked by length
  only. The GNU `.sig` files and `gnu-keyring.gpg` are mirrored, so you can check them offline:
  `gpg --no-default-keyring --keyring ./gnu-keyring.gpg --verify X.tar.xz.sig X.tar.xz`.
  The keyring comes from the same mirror as the tarballs, so this proves the files match each
  other and were signed by a key in that keyring. It is not independent proof they came from
  GNU; for that, compare the keyring with a copy you got some other way.
- **Sidecars and long names.** Next to the files sit `<file>.verified` stamps (for files with a
  digest) and `<file>.source.json` (for volatile files with no digest). Upstream names longer
  than 180 characters are stored under a shortened name with a hash suffix (the extension is
  kept). A file mirrored before 0.1.24 under the old cut-off name is downloaded again under the
  new one, and the old copy is left in place.
- **GNU mirrors.** `VALARK_GNU_BASE` is a comma list tried in order (default ftp.gnu.org, then
  mirrors.kernel.org). Every mirror but the last gets one attempt. A mirror that can't be
  reached (DNS, connect, timeout) is skipped for the rest of the run; one that answers with
  any HTTP status, even a 404 or 5xx for one package, stays in use. So an unreachable
  ftp.gnu.org costs one timeout per run, not four per package.
- **GitHub token.** Set `GITHUB_TOKEN`. A plan makes roughly 250 GitHub API calls, and the
  anonymous limit is 60 an hour.
- **Stale "latest" releases.** A `gh:` template whose GitHub latest release isn't a plain version
  (Neo4j's is a 2017 alpha) is an error. Use `ghtag:owner/repo` for the newest plain version tag.
- **Tag-only projects.** Projects with no GitHub releases get the source tarball of their newest
  plain version tag (`v1.2` / `1.2.3`). The tags come from `git/matching-refs/tags`, because the
  paged tags API often misses the newest ones.
- **Silent gaps are errors.** These all exit 1 rather than silently mirroring nothing:
  - an index with no matching file;
  - a `gh` regex that selects no asset;
  - a Brotli-encoded listing (stdlib can't decode it, so pick a mirror that serves plain HTML);
  - a template version source that returns something other than a version.
- **Exit codes:**
  - `0` complete;
  - `1` an entry failed to resolve, or nothing resolved (the rest are still planned and fetched);
  - `2` a download failed;
  - `64` usage (a bad catalog row, kind or regex).

  The most severe wins. Every metadata request and download gets 4 attempts on DNS and
  connection errors, 5xx and 429. A malformed row (an index with no regex, a template with
  no URLs, a non-numeric pypi-top) is reported as 64 before any network request.

**Last real-network run (2026-11-19 UTC, Ubuntu 24.04 x86_64, a `gh`, `go`, `gnu` and `=latest`
template row):**
- The first fetch exited 0 with 7 files, including the 406 MB Metasploit `.msi` (volatile, with
  a HEAD sidecar).
- The rerun exited 0 with every file skipped: HEAD for the 2 volatile files, the `.verified`
  stamp for the 2 digest files.
- A 30 MB `.part` of the 70 MB Go tarball resumed with Range and matched go.dev's sha256.
- `gpg --verify` of the mirrored m4 `.sig` against the mirrored keyring printed "Good signature".
- ftp.gnu.org was unreachable from that host, and the kernel.org fallback served the GNU rows.
- Not yet run: an offline `snap install --dangerous` of MicroK8s on a target box.
- Offline-install hints: Python wheels install with `pip install --no-index --find-links <dir>`;
  MicroK8s with `snap install --dangerous core20_*.snap` then `snap install --dangerous --classic
  microk8s_*.snap`; Docker static binaries by unpacking `docker-*.tgz` into `/usr/local/bin`.
- The Ubuntu-packaged side of the same stack (compilers, debuggers, Linux security tools, KVM /
  Ceph / cloud-init) is in the `dev-toolchain`, `security`, `reverse-eng` and `virt-cloud`
  APT sets below.

Tests: `tests/test-release-mirror.sh` (offline fixture for every kind).

### Offline .deb sets: desktop apps and building from source

`desktop-apps` holds Inkscape, GIMP, Krita, Blender, Kdenlive, KiCad (+ symbols/footprints),
OpenSCAD, PrusaSlicer, Audacity, VLC, mpv, FFmpeg, LibreOffice, Calibre, darktable, Shotcut,
OBS, tmux, btop and htop for Ubuntu on both arches (~1.2 GB each for noble): the offline path
where upstream ships no Linux arm64 build. `desktop-src` adds, for the apps with no arm64
build, Ubuntu's source package and every build dependency (~2.7 GB each), so a box with no
internet can rebuild them:

```bash
python3 scripts/lib/apt_offline.py build --suite noble --arch arm64 --set desktop-apps --set desktop-src --dest <dir>
# on the target: deb [trusted=yes] file:<dir> ./  then (the flat repo has no deb-src index,
# so build deps come from the .dsc FILE, not the package name)
cd <dir>/source/inkscape && D=$(ls -v inkscape_*.dsc | tail -1)   # the newest .dsc
sudo apt-get build-dep ./$D
rm -rf build-inkscape && dpkg-source -x $D build-inkscape && cd build-inkscape
dpkg-buildpackage -us -uc -b
```

These build the Ubuntu suite's version of each app (noble: e.g. KiCad 7, Blender 4.0,
Audacity 3.4). A newer upstream release, whose source the tool script mirrors separately,
may need newer or extra libraries.

Set entries `build-dep:SRC` / `source:SRC` drive this (see `data/AGENTS.md`); the tool
scripts' `INSTALL.txt` for those platforms name the same sets, the mirrored upstream release
tarball and the git bundle ([TOOLS.md](TOOLS.md#no-upstream-build-for-a-platform-offline-install--source)).

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
never hides a set that could not be resolved at all. An environment failure (code 1) prints a single
`apt_offline: …` line; set `VALARK_DEBUG=1` to get the full Python traceback as well.

CI only runs `apt_offline.py` against stubs and fixture lists (`tests/test-server-stack.sh`); it never
talks to the real Ubuntu archive. Before trusting a change to it, check on a real Ubuntu box with
`apt-get` and `ubuntu-archive-keyring` installed (use a scratch `--cache` and `--dest`, e.g. from
`mktemp -d`):

1. **Cross-arch resolve, empty dpkg status.** On an x86_64 host run
   `apt_offline.py resolve --suite noble --arch arm64 --set lamp --cache <scratch>`. Expect exit 0,
   every URL on `ports.ubuntu.com`, `libc6_…_arm64.deb` in the list (the empty status pulled in the
   base dependencies), and a SHA256 in the 4th column of every row. If some rows lack one,
   stderr prints only a count: `N package(s) have no SHA256`.
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

**Last real-archive run (release 0.1.22, 2026-11-18, Ubuntu 24.04 x86_64 host, `noble`, `--set lamp`):**
steps 1–4 passed. The arm64 resolve gave 281 rows, all on `ports.ubuntu.com`, with `libc6` included
and a SHA256 on every row. The amd64 resolve gave 281 rows on `archive.ubuntu.com`. The arm64 build
indexed 281 packages (98 MB) with no ".deb not in lists" lines and no `.part` left, and the
`--no-update` rerun took 10 s. `/etc/apt` (checksums of every file) and `dpkg -l` were unchanged.
Whether a host `apt.conf.d` hook ran was not checked directly.

Step 5 ran on amd64, because the host had no arm64 emulation. A separate amd64 build (`build --suite
noble --arch amd64 --set lamp`, which indexed 281 packages) went into an `ubuntu:24.04` container
started with `--network none`. With that flat repo as the only source, the whole `lamp` set
installed (apache2, mariadb-server, php 8.3). `--set no-such-set` exited 64. Not yet run: the interrupted-download half
of step 6, and step 5 on a real arm64 target.

## Commands

```bash
scripts/librarian.sh status        # disk + per-category coverage
scripts/librarian.sh plan          # dry-run: the ordered plan + totals
scripts/librarian.sh fill          # download the plan (resumable, never aborts)
scripts/librarian.sh fill --time 1800 --max-bytes 53687091200   # bounded chunk (secs / raw bytes)
scripts/librarian.sh verify        # integrity-check managed files; requeue bad
scripts/librarian.sh evict --need 107374182400   # free space (raw bytes), lowest value/byte first
scripts/librarian.sh refresh       # re-pull the live ZIM catalog
scripts/librarian.sh scout         # scout Hugging Face for new models now (weekly otherwise)
scripts/librarian.sh maintain      # refresh (+ weekly scout) + verify + bounded top-up + report + static pages (loop core)
scripts/librarian.sh site          # rewrite the static browse pages (index.html + browse/)
scripts/librarian.sh catalog model # not-yet-downloaded items (content|model|installer|all; web browse feed)
scripts/librarian.sh request model <id>   # pin + fetch ONE item now (content|model|tool), evicting unpinned items to fit
scripts/librarian.sh pin content <id>     # keep an item: pins are never evicted
scripts/librarian.sh unpin <id>    # files kept, but evictable again
scripts/librarian.sh pins --refill # list pins (--refill re-fetches any that went missing)
scripts/librarian.sh lastbook-plan # the Lastbook rows the planner picks (what lastbook.sh fetches)
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

## Static browse pages

When to serve an Ark statically or dynamically, and how to set up each: [SERVING.md](SERVING.md).
This section covers how the pages are built.

`scripts/librarian.sh site` (and `maintain`, at most every `VALARK_STATIC_SITE_HOURS`, default 6)
runs `scripts/lib/static_site.py`, which writes a **static catalog** of the archive at
`<VALARK_HOME>`: `index.html`, one card-grid page per section (`browse/<section>.html`) and one
detail page per item (`browse/item/*.html`). Plain HTML with inline CSS, **relative links only**,
no external URLs and no JavaScript requirement (a search box and group filter appear when scripts
run). Open `index.html` from a file explorer, an SMB share, a USB disk or any dumb file server.

Every card has a picture and a description, from the best source available:

| Section | Picture | Description |
|---------|---------|-------------|
| Tools & apps (one card per tool, all platforms) | the web UI's logo; screenshots on the detail page | the web UI's `TOOLS` / `TOOL_META` (matched by id, download folder or name): description, overview, features, CLI, maker, licence; else the header comment of `scripts/tools/<name>.sh` |
| Library (ZIM) | the ZIM's own 48x48 illustration | the ZIM's own title + description (read from its header and directory with a few small reads; uncompressed, xz and, with the `zstd` CLI, zstd clusters, each decoded once and capped at 4 MB), the web UI's `CONTENT_LIBRARY` overview, article counts from a cached Kiwix catalog |
| AI models, datasets | the first image the model / dataset card shows from its own repo (a real PNG / JPEG / GIF / WebP file inside the repo: symlinks out of it and upstream SVGs are refused) | the card's first paragraphs, licence and pipeline tag; curated `MODEL_FAMILIES` text for the classic `llm/` folders |
| Installers, developer stack, sources | generated badge | `data/installers.tsv`, `data/dev-stack.tsv`, `data/source-repos.tsv` notes; a PyPI package's `Summary` from its wheel's `METADATA`; the web UI text for a known tool |

**Every card has a description.** When none of the sources above has one, the generator uses, in
order: a caller's `--hints` file (`path<TAB>json` lines with `description` / `title` / `item` /
`collection` / `topic` / `platform` / `version` / `repo` / `publisher`; a NAS collector passes what it
recorded at download time), the curated sentences in
[`data/static-descriptions.json`](../data/static-descriptions.json) (Kiwix projects such as Wikipedia,
TED, DevDocs, Gutenberg, and tool folder names such as `maddy` or `node`), and finally a sentence built from
what is known: task (from the model card or the folder name), organisation, format and how to run it,
topic, version, platforms, file count and size. Folders named after a version (`3.12.1`, `latest`,
`24.04`) are titled by their project. `summary.json` counts, per section, how many descriptions came
from hints and how many were generated, and the run prints the totals.

Anything without a picture gets a generated badge (initials or a modality glyph). Pictures are copied
into `browse/thumbs/` (deduplicated, size-capped) so the catalog works without the repo next to it.

Only section directories are scanned (`state/`, `private/` and the repo's own code never appear);
`*.part`, `*.tmp`, `.source.json` sidecars and dot files are skipped. Big trees stay cheap:
`--max-rows` (3000 cards per section), `--max-files` (60 files per detail page), `--max-details`
(8000 detail pages), `--meta-limit` (4000 README reads, 64 KiB each), `--zim-limit` (400 ZIMs
opened per run; results are cached in `browse/zim-meta.json`, so later runs fill in the rest) and
`--walk-limit` (the page then says its totals are partial). Pages are written temp + rename and
unchanged files are not rewritten: only `index.html` and `summary.json` carry the generation time, so
a refresh with nothing new touches two files. Stale detail pages, thumbnails and an interrupted run's
temp files are removed.

**What to share.** The pages sit in `<VALARK_HOME>` (`<DATA_ROOT>/val-ark`), but models live in
`<DATA_ROOT>/models`, next to it, and the model links climb out to `../models`. Share (or open) the
whole `<DATA_ROOT>` so those links resolve; a share of `val-ark/` alone shows the model cards but
their file links break. A single-disk dev box keeps everything in the repo, so nothing climbs out.
The data root also holds the Ark's private folders (`state/`, `private/`, `seaweedfs/`; the
uploads drop is left alone).
Setup, every loop cycle and every `site` run set them to mode `700` (`valark_lock_private`), so a share must run as a different account; see
[SERVING.md](SERVING.md#what-to-share-and-what-not-to).

**Cost.** `librarian.sh site` walks the section folders (`os.scandir` + one `stat` per file) on every
refresh. That is quick on a local disk; on a very large tree on a slow disk raise
`VALARK_STATIC_SITE_HOURS`, or run `static_site.py` yourself with a `--listing`.

A mirror that keeps its own index can skip the walk entirely: `--listing FILE` takes
`path<TAB>size[<TAB>mtime]` rows (relative to `--root`) for what is present, `--pending FILE` the same
for what is still queued (shown as "queued" chips), and `--walk NAME` adds a section the listing does
not cover. `VALARK_STATIC_SITE=0` turns the refresh off. Opening `web-ui/index.html` over `file://`
shows a hint linking to the static catalog, since the dynamic UI needs its server. Tests:
`tests/test-static-site.sh`.

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
6. **self-mirror** — package Val Ark's own source under `<data>/sources/val-ark/`
   (`scripts/mirror-self.sh`) so a neighbour can bootstrap a node over the LAN,
7. **refresh the live catalog** → content links self-heal (no stale dates),
8. **check & repair links** — tool/installer URLs (retry-aware: curl 000/429/403
   are transient, not dead), web-ui assets, symlinks → `state/linkcheck.txt`,
9. **integrity verify** → requeue corrupt/short downloads,
10. **re-fill pinned requests** — user-requested items that went missing come back
    before the generic fill,
11. **top-up fill** (bounded; skipped if a fill already runs),
12. **weekly tool refresh** — re-run the tool mirror so apps track their latest
    upstream versions (`VALARK_TOOL_REFRESH_DAYS`, default 7; a failed pass
    retries in a day),
13. **functional verification** (`scripts/verify.sh`) — tools run, Kiwix serves a
    real ZIM, a tiny LLM infers, the web API answers, and each configured remote
    mesh node (`VALARK_FLEET` in `.env`) is reachable and sees the shared content,
14. **UI smoke** — a Playwright pass over the dynamic controls (when installed),
15. **moderation sweep** — screen plain-file community uploads on-device and
    quarantine anything not cleanly allowed (`scripts/lib/mod-sweep.sh`, fail-closed),
16. **report + coordination** — the librarian's `maintain` (writes
    `state/health.json`: disk + per-category coverage) and a fleet coordination drop
    (`state/coordination/`),
17. **self-heal snapshot** — write `state/selfheal.json` (the loop's own cycle
    snapshot) and append any genuine repairs to `state/heal-events.jsonl` (the feed
    behind the Health page). This is **distinct from `state/health.json`**.

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
