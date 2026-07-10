# Val Ark — Internet-Off Gap Analysis

*A decision report: if the internet went off today, what would this mirror be
missing? Produced by a 14-category sweep (each proposal HEAD-verified for real
offline artifacts on our four platforms) plus an adversarial completeness
critique. Updated 2026-07-10.*

[Back to Docs](README.md) | [Back to Project Root](../README.md)

## 1. Top additions (ranked, verified mirrorable)

| # | Tool | Why (one line) | Platforms | Size | License |
|---|------|----------------|-----------|------|---------|
| 1 | **Gitea** | Replaces GitHub the day it goes dark AND ships built-in npm/PyPI/Cargo/Go/Debian/OCI registries in one binary | all 4 | ~155 MB | MIT |
| 2 | **Docker stack** (static engine + compose + buildx + CNCF registry) | Coolify/n8n/Open WebUI/Milvus docs all assume `docker run`; the LAN registry is the only offline `docker pull` target | all 4 (mac=client) | ~580 MB | Apache-2.0 |
| 3 | **Caddy** | The missing general web server / reverse proxy; single static binary with a built-in local CA matching our auto-TLS | all 4 | ~67 MB | Apache-2.0 |
| 4 | **Headscale** | Highest leverage per byte: converts the already-mirrored (dead-offline) Tailscale clients back into a working mesh VPN | linux×2 + mac | ~150 MB | BSD-3 |
| 5 | **AdGuard Home** | Local DNS + DHCP + LAN-name rewrites with a web UI; every device stalls on DNS the moment upstream disappears | all 4 | ~45 MB | GPL-3.0 |
| 6 | **Git client** (PortableGit win + source tarball) | Gitea and every rebuild-from-source flow is useless without a client; fresh Windows/macOS boxes have no offline git today | win binary; src+hints | ~70 MB | GPL-2.0 |
| 7 | **CMake + Ninja** | Our own catalog marks llama.cpp/whisper.cpp/sd.cpp as CUDA *source builds* on Jetson — blocked day 1 without cmake | all 4 | ~256 MB | BSD/Apache |
| 8 | **KeePassXC** | Cloud password managers stop syncing immediately; every new LAN service needs offline credential storage | 3 of 4 | ~130 MB | GPL-3.0 |
| 9 | **Grafana OSS** | Dashboard layer for the InfluxDB/Telegraf stack the Ark already mirrors *(added to the catalog same day as this report)* | all 4 | ~1.4 GB | AGPL-3.0 |
| 10 | **LibreOffice** | Nobody without MS Office can open/edit/print community .docx/.xlsx on day 1 | 3 of 4 (no TDF arm64) | ~880 MB | MPL-2.0 |
| 11 | **Rescue-boot pack** (Ventoy, Rufus, SystemRescue, Clonezilla, Memtest86+) | Every ISO in installers.tsv is stranded without an offline USB writer; SystemRescue = ddrescue/testdisk/gparted/smartctl in one artifact | writers + x86 ISOs | ~2.0 GB | GPL family |
| 12 | **Meshtastic suite** (firmware + apps + CLI wheelhouse) | The only item reaching beyond the LAN: encrypted LoRa text mesh when internet AND cell are gone | all 4 + fw + APK | ~220–700 MB | GPL-3.0 |

**Next in line:** MySQL 8.4 LTS (~1.3 GB), OrcaSlicer (only slicer with official
linux-arm64, 630 MB), rclone+restic+age+croc static kit (~225 MB), Go toolchain
(270 MB — the most offline-friendly compiler that exists), pandoc+typst (225 MB),
Prometheus+node_exporter+Alertmanager (610 MB), DuckDB (90 MB), Temurin JDK 21
(820 MB — prerequisite for GraphHopper/JOSM/Stirling-PDF), arduino-cli+esptool
(290 MB + cores).

## 2. First-run-offline warnings

Tools that are dead or crippled offline unless pre-seeded at mirror time:

- **Existing catalog cold-start failures (currently silent):**
  - `claude-code`: dead without the Anthropic API — and it supervises the
    self-healing loop. Mirror an offline coding agent (Aider + a llama.cpp-served
    coding model) as the fallback brain.
  - `tailscale`: dead without the SaaS control plane → **Headscale** (#4).
  - `coolify`: the mirrored artifact is a curl|bash hint that itself needs
    internet + Docker — not offline-installable as shipped.
  - Godot (~1 GB export templates), VSCodium (Open VSX .vsix cache), ComfyUI
    (checkpoints/custom nodes), Ollama (registry blobs), Miniforge (conda
    channel): all download on first real use.
  - **Action:** add a network-blocked cold-start pass to `verify.sh` that
    installs and exercises each tool on an offline VM.
- **Proposals needing pre-warming:** Uptime Kuma / Verdaccio (pack node_modules,
  n8n-style), devpi/aptly/Athens/CNCF-registry (empty shells until caches
  exist), DBeaver (bundle JDBC jars), DuckDB (mirror the pinned extension dir),
  arduino-cli/PlatformIO/ESPHome (pre-seed cores/toolchains, 1.5–2 GB), Podman
  mac/win (mirror the machine VM image), NAPS2 (tessdata), croc (run `croc
  relay` as an Ark service).
- **Mirror-time fetch quirks:** CHIRP is behind a Cloudflare challenge (browser
  fetch needed); WSJT-X needs `master.dl.sourceforge.net/...?viasf=1` URLs;
  SDR++/OpenSCAD/GPSBabel nightly URLs rotate — pin with sha256 and let the
  link-repair loop re-resolve.

## 3. Content-not-tools gaps (the real disk spend)

1. **Package-ecosystem caches** — PyPI top-500 ×4 platforms: 20–40 GB; npm
   top-1000: 5–10 GB; Ubuntu 24.04 main+security amd64+arm64 (aptly): 150–250 GB;
   full crates.io (panamax): 250–350 GB (fill-tier). *Start: ~230–300 GB.*
   Full PyPI is 42.3 TB — never.
2. **Container images** — curated `docker save`/skopeo set (postgres, redis,
   node, python, ollama, milvus, nodebb, vaultwarden…) served by the CNCF
   registry: start ~30 GB.
3. **Maps/geodata (currently zero in the catalog)** — Organic Maps home
   continent ~21 GB + home Geofabrik .osm.pbf ~19 GB now; Protomaps planet
   basemap (137 GB single .pmtiles, serves zoomable maps to every browser and
   regional extracts are computable offline) as the first fill-tier item.
4. **Firmware/toolchain data** — Arduino cores 1–2 GB, PlatformIO cache
   1.5–2 GB, Meshtastic firmware ~250 MB, Tesseract tessdata ~1 GB.
5. **Cold-start assets for existing tools** — Godot export templates,
   Open VSX cache, conda-forge subset, Ollama blobs.
6. **Corpora with no ingestion pipeline today** — NVIDIA CUDA/cuDNN/TensorRT
   archives (`installers.tsv` already carries the Jetson L4T BSP and OpenWRT
   sysupgrade images, but not the CUDA userspace),
   Kolibri education channels + Anki decks, Hesperian/FEMA/appropriate-tech PDF
   libraries, public-domain media for morale, spare-parts STL packs.
   **Design change required:** the librarian only ingests Kiwix OPDS + two
   TSVs — it needs a third generic-manifest catalog (TSV of
   url/size/sha/priority) so bulk PDF/STL/map/package content participates in
   the diversity→fill→evict planner.

## 4. Completeness critique (what every sweep missed)

1. **NVIDIA driver/CUDA userspace + remaining fleet firmware** (GB10, BIOS) —
   `installers.tsv` already re-images Orin (L4T BSP) and common OpenWRT routers,
   but CUDA/cuDNN/TensorRT archives, GB10 recovery, and BIOS updates are missing.
2. **Time sync**: chrony + GPS-disciplined stratum-0 (gpsd + PPS dongle) — with
   pool.ntp.org gone, clock drift silently breaks our local-CA TLS, mail, and
   builds within months.
3. **Offline replacement for Claude Code** — the Ark's maintenance brain
   currently dies with the internet.
4. **Cold-start audit** of the existing catalog (see §2 action).
5. **Printing stack**: CUPS + PPDs + Gutenprint + HPLIP + brlaser + font
   bundle — paper is the durable output medium and nobody can print today.
6. **Power protection**: NUT/apcupsd — grid instability accompanies internet
   loss; a hard cut mid-write corrupts the collection.
7. **Ark self-redundancy** — the NFS mesh consumes ONE disk; there is no stated
   policy for a second physical copy of the data root.
8. **Structured education**: Kolibri (Khan Academy/PhET/CK-12 channels) + Anki —
   ZIMs are reference reading, not sequenced curriculum.
9. **Entertainment at scale**: Jellyfin/Audiobookshelf + actual public-domain
   libraries — VLC/Calibre are players with nothing to play; morale over months
   offline is a survival input.
10. **Non-ZIM practical-knowledge corpora** (medical guides, field manuals,
    agriculture, STL packs) — no home in the priority planner (see §3.6).

## 5. Explicitly rejected (and why)

Full PyPI mirror (42.3 TB), Docker Desktop (proprietary), HAProxy (source-only),
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
