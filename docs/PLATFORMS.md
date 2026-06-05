# Val Ark - Platform Notes

## aarch64 boards: Jetson Orin, Jetson Thor, GB10 (linux-arm64)

All NVIDIA aarch64 boards run the **same `tools/linux-arm64` artifacts**. They are
distinguished only by GPU/CUDA profile, so the prebuilt CLI tools (FFmpeg, Piper,
ONNX Runtime, Vosk, Syncthing, Kiwix, btop, SQLite, etc.) are shared across all of
them — no per-board rebuild needed.

| Profile | GPU / CUDA | CUDA arch | Notes |
|---------|------------|-----------|-------|
| Jetson Orin | CUDA SM 8.7 | `87` | Orin Nano / Orin NX |
| Jetson Thor | CUDA Blackwell | `110` (Blackwell) | Newer Jetson generation |
| GB10 Grace-Blackwell | CUDA Grace-Blackwell, SBSA | Blackwell | Server-Base System Architecture (SBSA) |

**Tested on:** Jetson Orin Nano, Orin NX

### Setup
```bash
# CUDA toolkit should be pre-installed via JetPack (Jetson) or the SBSA
# CUDA toolkit (GB10). Verify it is on PATH:
nvcc --version  # Verify CUDA

./start.sh setup
./start.sh download tools
```

### Building GPU-accelerated AI engines (CUDA source build)

There is **no upstream prebuilt aarch64 CUDA binary** for llama.cpp / whisper.cpp /
stable-diffusion.cpp, so GPU acceleration on any of these boards requires a CUDA
source build. Set the CUDA architecture to match the board:

```bash
# After downloading tools, build from source with CUDA:
cd tools/llama.cpp/source

# Jetson Orin  -> SM 8.7
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87

# Jetson Thor / GB10 (Grace-)Blackwell -> use the Blackwell arch (e.g. 110)
# cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=110

cmake --build build -j$(nproc)
```

The same `-DGGML_CUDA=ON` source build applies to whisper.cpp and
stable-diffusion.cpp.

### Recommended Models
- Tier 1 models work well on 8GB RAM Jetson Orin
- Tier 2 models need 16GB+ RAM
- Thor / GB10 (large unified memory) can run Tier 3 models comfortably
- Use Q4_K_M or smaller quants for best performance

---

## OpenWRT Routers (content / infrastructure only)

OpenWRT mesh/router nodes are aarch64 and reuse the **same `tools/linux-arm64`
artifacts**, but they are a deliberately lightweight profile. Only the
content-serving, sync, and infrastructure tools are surfaced — **never the heavy
inference engines** (no llama.cpp / whisper.cpp / stable-diffusion.cpp / ComfyUI on
a router).

Surfaced tools: Kiwix, Syncthing, btop, FFmpeg, SQLite, and the Dev CLI bundle
(jq / ripgrep). These let a router act as an offline content mirror, a sync relay,
and a monitoring node without GPU dependencies.

### Setup
```bash
./start.sh setup
./start.sh download tools
# Serve offline content from the router:
./scripts/download-zims.sh serve
```

There is no GPU on a router node, so the inference engines are intentionally
marked `n/a` for this profile in the web UI.

---

## macOS Apple Silicon (macos-arm64)

**Tested on:** M1, M2, M3, M4

### Setup
```bash
# Install Xcode command line tools
xcode-select --install

./start.sh setup
./start.sh download tools
```

### Metal Acceleration
- llama.cpp: Prebuilt binary includes Metal support
- whisper.cpp: Build from source with `-DGGML_METAL=ON`
- stable-diffusion.cpp: Prebuilt binary includes Metal

### Recommended Models
- All tiers work well on 16GB+ unified memory
- M1/M2 with 8GB: stick to Tier 1
- M4 Pro/Max: can run Tier 3 32B models comfortably

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
# Install CUDA toolkit from NVIDIA
# Then build with GPU acceleration:
cd tools/llama.cpp/source
cmake -B build -DGGML_CUDA=ON
cmake --build build -j$(nproc)
```

### CPU Optimizations
The build script auto-detects AVX2/AVX-512/FMA and applies appropriate flags.

---

## Windows x64

### Prebuilt Binaries
Most tools have prebuilt Windows binaries:
- llama.cpp (CPU + CUDA variants)
- whisper.cpp (CPU + CUDA variants)
- stable-diffusion.cpp (AVX2 + CUDA variants)
- Piper TTS
- ONNX Runtime
- FFmpeg

### Usage
```powershell
# Run llama.cpp server
.\tools\llama.cpp\windows-x64\llama-server.exe -m models\llm\llama-3.2-3b\model.gguf

# Run whisper
.\tools\whisper.cpp\windows-x64\whisper-cli.exe -m models\stt\whisper-ggml\ggml-base.bin
```

---

## Cross-Platform Sync with Syncthing

Val Ark is designed to be synced across machines using Syncthing:

1. Install Syncthing on all machines
2. Share the val-ark directory (or just the models directory)
3. Models download once, sync to all devices
4. Tier 1 models sync fast (small files)
5. Use `.stignore` to exclude large tiers on constrained devices
