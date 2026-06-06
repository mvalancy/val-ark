# Val Ark - Platform Notes

Per-platform setup and acceleration notes. See [ARCHITECTURE.md](ARCHITECTURE.md)
for the system overview, [LIBRARIAN.md](LIBRARIAN.md) for the catalog/fill engine,
and [OFFLINE.md](OFFLINE.md) for sync and offline serving.

> **Data root is configurable.** Val Ark resolves `VAL_ARK_DATA` from a git-ignored
> `.env` (see [`.env.example`](../.env.example)) or autodetects the largest writable
> mount; it falls back to the repo dir for single-disk/dev use. Models live at
> `$VAL_ARK_DATA/models`; everything else under `$VAL_ARK_DATA/val-ark/{tools,content,
> sources,assets,installers,state}`, with repo-relative dirs symlinked to the disk.
> Nothing host-specific is committed — pin a path in `.env` if autodetect guesses wrong.

Supported platforms (web UI selector): **Jetson Orin, Jetson Thor, GB10, Ubuntu,
macOS, Windows, OpenWRT**.

---

## aarch64 boards: Jetson Orin, Jetson Thor, GB10 (linux-arm64)

All NVIDIA aarch64 boards run the **same `tools/linux-arm64` artifacts**, distinguished
only by GPU/CUDA profile. The prebuilt CLI tools (FFmpeg, Piper, ONNX Runtime, Vosk,
Syncthing, Kiwix, btop, SQLite, etc.) are shared across all of them — no per-board rebuild.

| Profile | GPU / CUDA | CUDA arch | Notes |
|---------|------------|-----------|-------|
| Jetson Orin | CUDA SM 8.7 | `87` | Orin Nano / Orin NX |
| Jetson Thor | CUDA Blackwell | `110` | Newer Jetson generation |
| GB10 Grace-Blackwell | CUDA Grace-Blackwell, SBSA | `110` | Server-Base System Architecture (SBSA) |

**Tested on:** Jetson Orin Nano, Orin NX

### Setup
```bash
# CUDA toolkit ships with JetPack (Jetson) or the SBSA CUDA toolkit (GB10).
nvcc --version          # verify CUDA is on PATH
./start.sh setup
./start.sh download tools
```

### Building GPU-accelerated AI engines (CUDA source build)

There is **no upstream prebuilt aarch64 CUDA binary** for llama.cpp / whisper.cpp /
stable-diffusion.cpp, so GPU acceleration on these boards needs a CUDA source build.
The tool scripts clone the source into `tools/linux-arm64/llama-cpp` (and mirror it
under `sources/`); set the CUDA arch to match the board:

```bash
cd tools/linux-arm64/llama-cpp

# Jetson Orin            -> SM 8.7
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87

# Jetson Thor / GB10 (Blackwell) -> 110
# cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=110

cmake --build build -j$(nproc)
```

The same `-DGGML_CUDA=ON` source build applies to whisper.cpp and stable-diffusion.cpp.

### Recommended Models
- Tier 1 runs well on 8 GB Jetson Orin; Tier 2 needs 16 GB+.
- Thor / GB10 (large unified memory) run Tier 3 comfortably.
- Prefer Q4_K_M or smaller quants. See [MODEL_INVENTORY.md](MODEL_INVENTORY.md).

---

## OpenWRT Routers (content / infrastructure only)

OpenWRT mesh/router nodes are aarch64 and reuse the **same `tools/linux-arm64`
artifacts**, but as a deliberately lightweight profile. Only content-serving, sync,
and infrastructure tools are surfaced — **never the heavy inference engines** (no
llama.cpp / whisper.cpp / stable-diffusion.cpp / ComfyUI on a router).

Surfaced tools (`OPENWRT_TOOLS` allow-list in the web UI): **Kiwix, Syncthing, btop,
FFmpeg, SQLite, and the Dev CLI bundle** (jq / ripgrep). These let a router act as an
offline content mirror, a sync relay, and a monitoring node without GPU dependencies.
Inference engines are marked `n/a` for this profile.

### Setup
```bash
./start.sh setup
./start.sh download tools
./scripts/download-zims.sh serve   # serve offline ZIM content from the router
```

---

## macOS Apple Silicon (macos-arm64)

**Tested on:** M1, M2, M3, M4

### Setup
```bash
xcode-select --install   # Xcode command line tools
./start.sh setup
./start.sh download tools
```

### Metal Acceleration
- llama.cpp: prebuilt binary includes Metal.
- stable-diffusion.cpp: prebuilt binary includes Metal.
- whisper.cpp: build from source with `-DGGML_METAL=ON`.

### Recommended Models
- All tiers work on 16 GB+ unified memory.
- M1/M2 with 8 GB: stick to Tier 1.
- M4 Pro/Max: runs Tier 3 32B models comfortably.

---

## Linux x86_64 (Ubuntu/Debian)

### Setup
```bash
sudo apt install wget curl git tar unzip cmake build-essential
./start.sh setup
./start.sh download tools
```

### CUDA Support
```bash
# Install the CUDA toolkit from NVIDIA, then build with GPU acceleration:
cd tools/linux-x86_64/llama-cpp
cmake -B build -DGGML_CUDA=ON
cmake --build build -j$(nproc)
```

### CPU Optimizations
The build script auto-detects AVX2/AVX-512/FMA and applies appropriate flags.

---

## Windows x64

### Prebuilt Binaries
Most tools ship prebuilt Windows binaries: llama.cpp (CPU + CUDA), whisper.cpp
(CPU + CUDA), stable-diffusion.cpp (AVX2 + CUDA), Piper TTS, ONNX Runtime, FFmpeg, Vosk.

### Usage
```powershell
# Run llama.cpp server
.\tools\windows-x64\llama-cpp\llama-server.exe -m models\llm\llama-3.2-3b\model.gguf

# Run whisper
.\tools\windows-x64\whisper.cpp\whisper-cli.exe -m models\stt\whisper-ggml\ggml-base.bin
```

---

## Filling a disk: the Librarian

On any platform, once tools are present, [`scripts/librarian.sh`](../scripts/librarian.sh)
fills a disk of **any size** from live catalogs (Kiwix OPDS fetched live — never stale),
in priority order: diversity → small-valuable → fill-remaining → evict-for-better.
Downloads use aria2 multi-connection (~3× faster) with curl fallback — resumable,
size-verified, atomic, single-`flock`.

```bash
./scripts/librarian.sh status   # disk budget + what's planned
./scripts/librarian.sh fill     # download per the curation priority
```

A 24/7 self-healing loop ([`scripts/loop.sh`](../scripts/loop.sh)) keeps a node healthy:
it repairs the symlink layout, refreshes the live catalog, link-checks and re-verifies
integrity, tops up the fill, and runs functional verification
([`scripts/verify.sh`](../scripts/verify.sh)) that the tools actually run, Kiwix serves
a real ZIM, a tiny LLM responds, and the web API answers.

```bash
./scripts/loop.sh once          # one maintenance cycle
./scripts/loop.sh install 30    # register a flock-guarded cron, every 30 min
```

See [LIBRARIAN.md](LIBRARIAN.md) for the full design.

---

## Cross-platform sync & the NFS mesh

Because the data root is a single configurable disk, Val Ark scales from a laptop to a
fleet:

- **Syncthing** — share `$VAL_ARK_DATA` (or just `models`) across machines; tools and
  models download once and replicate. Use `.stignore` to exclude large tiers on
  constrained devices. Tier 1 models sync fast.
- **NFS mesh** — the data disk is NFS-exportable, so fleet nodes mount **one shared
  mirror** and run GPU inference on the served models over the network. The verify loop
  checks each remote host listed in `VALARK_FLEET` (in `.env`): reachable, mounting the
  shared mirror, and able to run inference on a model served over NFS.

See [OFFLINE.md](OFFLINE.md) for offline serving and peer-to-peer details.
