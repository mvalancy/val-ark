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
| Developer + security stack | `data/dev-stack.tsv` | The kit to build, run and secure software offline: every supported Python (python.org installers + relocatable builds + a top-1000 PyPI wheelhouse), compilers (LLVM, GCC/GNU sources, MinGW, Go, Rust, JDK, CMake…), decompilers/RE (Ghidra, radare2/rizin/Cutter, x64dbg, jadx, ILSpy, Frida…), security tools (Nmap, Wireshark, ZAP, Metasploit, nuclei, Trivy, Zeek, Suricata, Kali ISOs…), containers + Kubernetes (Docker static, Podman, kubeadm/kubectl, MicroK8s snaps, k3s, Helm…), cloud/IaC, S3-compatible storage (MinIO source, SeaweedFS, RustFS, versitygw, rclone) and databases (Neo4j + Relate, Milvus, Qdrant, DuckDB, ClickHouse, Valkey, OpenSearch…). Current release of each, resolved live by `scripts/lib/release_mirror.py` (see below). |
| Offline .deb sets | `data/apt-sets.tsv` | Server + developer/security package sets resolved with all dependencies per Ubuntu suite+arch by `scripts/lib/apt_offline.py build --suite noble --arch arm64 --set lamp --dest <dir>` → a flat local APT repo for a LAN with no internet. |

The big LLM/STT/TTS/VLM/image catalog is still managed by `download-models.sh`.

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
- **GNU mirrors.** `VALARK_GNU_BASE` is a comma list tried in order (default ftp.gnu.org, then
  mirrors.kernel.org). Every mirror but the last gets one attempt, and a mirror that is
  unreachable once is skipped for the rest of the run. So an unreachable ftp.gnu.org costs one
  timeout per run, not four per package.
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

**Last real-network run (2026-11-19, Ubuntu 24.04 x86_64, a `gh`, `go`, `gnu` and `=latest`
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
