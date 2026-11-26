<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/popup/offline-dark.svg">
  <img src="img/popup/offline-light.svg" width="100%" alt="Pop-up book scene: Off the grid, together. Pull everything once, then share it across the LAN with no internet.">
</picture>

# Val Ark - Offline & P2P Guide

[Back to Docs](README.md) | [Back to Project Root](../README.md)

## Design Philosophy

Val Ark is **online-optional**: pull everything once while online, then run
entirely offline and share between machines over the LAN.

- Download once while online; the **Librarian** fills any-size disk from live catalogs.
- Run inference, content, and the web UI fully offline afterward.
- Sync between machines over LAN — Syncthing P2P, or one NFS-exported shared mirror.
- A 24/7 loop keeps the mirror current, intact, and verified.

What the mirror would still be missing if the internet went off today is tracked as GitHub
issues labelled `offline-gap`, gathered in the burn-down epic #384 (apps first, then library
content, then other content, then models).

## Where data lives (configurable)

All bulk data lives on a single **data root** resolved by `scripts/lib/valark-env.sh`.
Nothing host-specific is committed — your machine's settings go in a git-ignored
`.env` (copy `.env.example`):

```bash
cp .env.example .env
# edit .env:
VAL_ARK_DATA=/mnt/yourdisk    # models reused at $VAL_ARK_DATA/models
```

If unset, the data root is autodetected (largest writable mount, else the repo dir).
Models stay at `$VAL_ARK_DATA/models`; everything else lives under
`$VAL_ARK_DATA/val-ark/{tools,content,sources,assets,installers,state}`. Repo-relative
dirs are symlinked to the disk so legacy scripts work unchanged. See
[LIBRARIAN.md](LIBRARIAN.md) for the full data-root and curation model.

## Offline Workflow

### 1. Initial download (requires internet)

```bash
./start.sh setup
./start.sh download tools             # smallest first, then AI engines
./start.sh download models tier1      # edge/mobile (small, fast)
./start.sh download models tier2      # balanced workstation
./start.sh download models tier3      # large (space permitting)

# Or let the Librarian curate a disk of any size from live catalogs:
scripts/librarian.sh plan             # dry-run the ordered plan
scripts/librarian.sh fill             # download it (aria2 multi-conn, resumable)
```

### 2. Verify downloads

```bash
./start.sh status                     # inventory + disk usage
scripts/librarian.sh verify           # integrity-check managed files (offline)
scripts/verify.sh                     # confirm apps actually RUN (tools/Kiwix/LLM/API)
```

### 3. Go offline

Once downloaded, everything runs locally. The `start.sh` helpers locate the right
prebuilt binary and a suitable model automatically (no internet needed):

```bash
./start.sh chat                       # LLM chat server  (http://localhost:8080)
./start.sh transcribe audio.wav       # speech-to-text   (whisper.cpp)
./start.sh speak "Hello world"        # text-to-speech   (Piper -> speech.wav)
./start.sh serve                      # web UI + API + auto kiwix-serve (port 3000)
```

Prebuilt binaries live at `tools/<platform>/<tool>/...` (often at nested/versioned
paths, e.g. `llama-cpp/llama-b<N>/llama-server`, `piper/piper/piper` — the `start.sh`
helpers find them wherever they land); models
live under `$VAL_ARK_DATA/models/{llm,stt,tts,...}`. On aarch64, GPU-accelerated
llama/whisper/sd require a CUDA source build — see [PLATFORMS.md](PLATFORMS.md).

To let other machines browse the archive, either run the web server (`./start.sh serve`) or
share the data disk and open the static `val-ark/index.html`. Both work offline; see
[SERVING.md](SERVING.md) for which to choose and what (not) to share.

## 24/7 self-healing

`scripts/loop.sh` keeps an offline mirror healthy without supervision: it ensures the
disk is writable, repairs symlinks, keeps the web server and enabled community services
up, mirrors its own source for LAN self-replication, optionally serves DHCP + DNS to a
laptop plugged straight into the wired port ([below](#direct-connect-laptop-no-router)), checks that Tailscale isn't in
userspace-networking mode (which would make every tailnet peer the Admin; a critical notification
if it is, #311), refreshes the live catalog (content
links self-heal — no stale dates), checks & repairs links, verifies integrity, re-fills
pinned requests, tops up the fill, refreshes mirrored tools weekly (latest upstream
versions), runs functional verification and a UI smoke, and sweeps uploads through the
fail-closed moderation check (full step list: [LIBRARIAN.md](LIBRARIAN.md#the-247-loop)). Install it as a flock-guarded cron job:

```bash
scripts/loop.sh install 30            # one cycle every 30 min (survives reboot)
scripts/loop.sh uninstall
```

Full details: [LIBRARIAN.md](LIBRARIAN.md).

## What else works offline

Beyond the tools, models and ZIM library, an Ark can rebuild and serve software with no
internet at all. The APT, developer-stack and source-archive mirrors are standalone CLIs
you run (or schedule) yourself — the loop does not run them; self-replication and Lastbook
are kept current by the loop and the weekly tool refresh.

- **Self-replication** — the loop keeps a full-history git bundle + tarball of Val Ark's
  own source under `<data>/sources/val-ark/` (`scripts/mirror-self.sh`), and the web
  server hands out a host-aware installer, so a neighbour stands up their own node from
  the LAN: `curl -fsSL http://<ark-host>:3000/bootstrap.sh | bash`.
- **Offline APT repos** — `scripts/lib/apt_offline.py` resolves the package sets in
  `data/apt-sets.tsv` with every dependency for any Ubuntu suite + architecture and
  indexes them as a flat repo (`deb [trusted=yes] file:<dir> ./`). See
  [LIBRARIAN.md](LIBRARIAN.md#offline-deb-sets-exit-codes-and-a-real-box-check).
- **Developer + security stack** — `scripts/lib/release_mirror.py` fetches the current
  release of each `data/dev-stack.tsv` project for every platform, including Python
  installers and a PyPI wheelhouse (`pip install --no-index --find-links <dir>`). See
  [LIBRARIAN.md](LIBRARIAN.md#developer--security-stack-release_mirrorpy).
- **Source archive** — `scripts/lib/git_bundle_mirror.py` builds full-history git bundles
  of the repos in `data/source-repos.tsv`; `git clone <repo>.bundle` works offline. See
  [TOOLS.md](TOOLS.md#content-mirrors).
- **Lastbook** — the free offline survival library (packs, maps, address search, its
  model and installers), kept current by `scripts/tools/lastbook.sh`.

## Sharing between machines

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/flow/fleet-dark.svg">
  <img src="img/flow/fleet-light.svg" width="100%" alt="Animated diagram: One Ark, many machines. Share one Ark across the LAN, or set up new ones from it, without the internet.">
</picture>

### Option A — NFS shared mirror (mesh)

The data root is NFS-exportable, so fleet nodes mount **one shared mirror** and run
GPU inference on served models over the network. Set `VALARK_FLEET` in `.env` and the
verification loop checks each remote node over SSH (reachable, sees the shared content,
GPU inference works on NFS-served models).

Nodes only need to read the shared `models/`, `content/` and `tools/`. The Ark keeps `val-ark/state/`
private (mode `700`, see [SERVING.md](SERVING.md#what-to-share-and-what-not-to)), so a node that
leaves notes in the loop's `state/coordination/` drop must mount as the Ark's own uid.

### Option B — Syncthing P2P

1. Syncthing ships in the tools download:
   ```bash
   ./tools/<platform>/syncthing/syncthing    # web UI at http://localhost:8384
   ```
2. Share `$VAL_ARK_DATA/models/` (and/or `content/`) between machines; connect devices
   by Device ID. Files sync automatically over LAN.
3. **Selective sync** with `.stignore` on constrained devices:
   ```
   /llm/nemotron-70b
   /llm/llama-3.3-70b
   /llm/*-32b
   /image-gen/sdxl-base
   ```

**LAN-only mode** (no relay/global discovery): Settings > Connections — uncheck
"Enable Relaying" and "Global Discovery"; rely on local discovery only.

### Topology

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {
  'primaryColor': '#1a2230',
  'primaryBorderColor': '#2a3545',
  'primaryTextColor': '#e8edf4',
  'lineColor': '#4da6ff',
  'secondaryColor': '#131921',
  'tertiaryColor': '#0a0e14'
}}}%%
graph TB
    subgraph Internet["Internet (one-time, online)"]
        style Internet fill:#1a2230,stroke:#fb923c
        CAT["Live Catalogs<br/>Kiwix OPDS / HF / GitHub"]
    end

    subgraph Ark["Val Ark Node (data root)"]
        style Ark fill:#1a2230,stroke:#4ade80
        LIB["librarian.sh<br/>plan / fill / evict"]
        LOOP["loop.sh + verify.sh<br/>24/7 self-heal + verify"]
        STORE["DATA_ROOT<br/>models/ + val-ark/{tools,content,...}"]
        WEB["server.js<br/>Web UI + API + kiwix-serve"]
        SYNC["Syncthing<br/>P2P daemon"]
    end

    subgraph Peers["LAN / Mesh Peers (offline OK)"]
        style Peers fill:#1a2230,stroke:#a78bfa
        NFS["NFS mounts<br/>Jetson / desktop / Mac<br/>(GPU inference on served models)"]
        ST["Syncthing peers<br/>selective .stignore"]
    end

    CAT -.->|"aria2 download<br/>(online)"| LIB
    LIB --> STORE
    LOOP --> STORE
    LOOP --> WEB
    WEB --> STORE
    SYNC --> STORE
    STORE -->|"NFS export<br/>(one shared mirror)"| NFS
    SYNC <-->|"Syncthing P2P"| ST
```

## Air-Gapped Transfer

For fully air-gapped environments, move a populated data root by USB or tarball.

### USB drive

```bash
rsync -av --progress "$VAL_ARK_DATA/models/" /mnt/usb/models/   # on online machine
rsync -av --progress /mnt/usb/models/ "$VAL_ARK_DATA/models/"   # on offline machine
```

### Tarball

```bash
cd "$VAL_ARK_DATA"
tar czf val-ark-tier1.tar.gz \
    models/llm/llama-3.2-1b models/llm/llama-3.2-3b models/llm/nemotron-mini-4b \
    models/stt/whisper-ggml/ggml-tiny* models/stt/whisper-ggml/ggml-base* \
    models/tts/piper-voices
# Transfer, then unpack into the target data root:
tar xzf val-ark-tier1.tar.gz -C "$VAL_ARK_DATA"
```

## Storage Recommendations

The Librarian scales to any disk — it fills from live `df` headroom
(`avail − max(2%, 50 GB)`) with no hardcoded ceiling (set `VALARK_MAX_GB` in `.env`
to cap Val Ark's own footprint on a shared disk). The tiers below are convenient
starting points; see [MODEL_INVENTORY.md](MODEL_INVENTORY.md) for exact sizes.

| Tier | Storage needed | Suitable devices |
|------|----------------|------------------|
| Tier 1 only | ~15 GB | Phones, tablets, Raspberry Pi, OpenWRT routers |
| Tier 1+2 | ~165 GB | Laptops, workstations, Jetson Orin/Thor |
| All tiers + ZIM | ~500 GB+ | Servers, NAS, GB10, shared NFS mirror |

## Direct-connect laptop (no router)

Off-grid there may be no router: just a laptop and an ethernet cable into the Ark.
Set `VALARK_LINK_DHCP=1` in `.env` and the loop hands that laptop an address and DNS
over the wired port, so `http://valark/` (or the box's hostname) opens the web UI and
the community apps with no router, internet or VPN. It probes for a DHCP server first
and never serves while one answers, so plugging the Ark into a home or office network
is safe; it stops the moment a real server appears. Needs root or passwordless sudo
and `dnsmasq`. Its DNS answers the Ark's own names and, by default
(`VALARK_LINK_DHCP_DNS=forward`), passes other lookups to the Ark's own upstream
resolvers. A laptop that also has Wi-Fi keeps its internet while the Ark is online;
when the Ark is offline, non-local lookups fail fast. In that mode the laptop's lookups
go out through the Ark's upstream resolvers (a privacy consideration). `local` (Ark names only) and
`off` (no DNS) are the alternatives. Details and the hardware checklist:
[ARM64-NAS.md](ARM64-NAS.md#direct-connect-laptop-dhcp--dns-on-the-wired-port).

## Network Requirements

| Operation | Internet required? |
|-----------|--------------------|
| Initial download / Librarian fill | Yes |
| Catalog refresh & link/URL checks | Yes |
| Running models, content, web UI | No |
| Integrity verify (`librarian.sh verify`) | No |
| Syncthing / NFS over LAN | No (LAN only) |
| Laptop direct to the Ark's ethernet (`VALARK_LINK_DHCP=1`) | No (no router either) |
| Updates | Yes |
