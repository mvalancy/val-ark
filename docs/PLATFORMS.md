# Val Ark - Platform Notes

## NVIDIA Jetson (linux-arm64)

**Tested on:** Jetson Orin Nano, Orin NX

### Setup
```bash
# CUDA toolkit should be pre-installed via JetPack
nvcc --version  # Verify CUDA

./start.sh setup
./start.sh download tools
```

### Building AI Engines
```bash
# After downloading tools, build from source with CUDA:
cd tools/llama.cpp/source
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=87
cmake --build build -j$(nproc)
```

### Recommended Models
- Tier 1 models work well on 8GB RAM Jetson
- Tier 2 models need 16GB+ RAM
- Use Q4_K_M or smaller quants for best performance

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
