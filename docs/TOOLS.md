# Val Ark - Tools Catalog

## AI Inference Engines

| Tool | Purpose | Platforms | Size |
|------|---------|-----------|------|
| llama.cpp | LLM/VLM inference (GGUF) | All | ~50MB/platform |
| whisper.cpp | Speech-to-text (GGML) | All | ~20MB/platform |
| stable-diffusion.cpp | Image generation | All | ~30MB/platform |
| ONNX Runtime | Kokoro TTS, Moonshine ASR | All | ~50MB/platform |
| Piper TTS | Fast text-to-speech (ONNX) | All | ~30MB/platform |
| Vosk | Lightweight offline ASR | All | ~10MB/platform |

## Creative & Dev Tools

| Tool | Purpose | Platforms | Size |
|------|---------|-----------|------|
| Blender | 3D modeling & rendering | All | ~300MB |
| FreeCAD | Parametric CAD | All | ~400MB |
| KiCad | PCB design | All | ~500MB |
| Godot | Game engine | All | ~50MB |
| VLC | Media player | All | ~50MB |

## Networking & IoT

| Tool | Purpose | Platforms | Size |
|------|---------|-----------|------|
| Tailscale | Mesh VPN / overlay network | Linux | ~20MB |
| Mosquitto | MQTT broker & clients | Linux (compiled) | ~5MB |
| MQTT Explorer | GUI MQTT client | Linux x86_64 | ~100MB |

## Databases

| Tool | Purpose | Platforms | Size |
|------|---------|-----------|------|
| SQLite | Embedded SQL database CLI | Linux | ~2MB |
| Redis | In-memory key-value store | Linux (compiled) | ~5MB |
| PostgreSQL | Relational database | Linux x86_64 (binaries), arm64 (instructions) | ~50MB |
| InfluxDB | Time-series database | Linux | ~100MB |

## Editors & IDEs

| Tool | Purpose | Platforms | Size |
|------|---------|-----------|------|
| Helix | Modal text editor (Rust) | Linux | ~15MB |
| VSCodium | Open-source VS Code | Linux | ~100MB |

## Python & Runtimes

| Tool | Purpose | Platforms | Size |
|------|---------|-----------|------|
| Miniforge | Conda-forge package manager | Linux | ~80MB |
| python-build-standalone | Portable CPython builds | Linux | ~30MB |

## Infrastructure & Utilities

| Tool | Purpose | Platforms | Size |
|------|---------|-----------|------|
| Syncthing | P2P file sync | Linux | ~15MB |
| btop | System monitor | Linux | ~2MB |
| tmux | Terminal multiplexer | Linux | ~2MB |
| FFmpeg | Audio/video processing | All | ~100MB |

## Dev CLI Bundle

| Tool | Purpose | Size |
|------|---------|------|
| ripgrep (rg) | Fast grep replacement | ~5MB |
| fd | Fast find replacement | ~3MB |
| bat | cat with syntax highlighting | ~5MB |
| jq | JSON processor | ~2MB |
| fzf | Fuzzy finder | ~3MB |
| lazygit | Terminal git UI | ~10MB |

## AI Platforms

| Tool | Purpose | Size |
|------|---------|------|
| Ollama | Model manager/server | ~500MB |
| ComfyUI | Node-based image gen UI | Variable |
| n8n | Workflow automation | Variable |
| Milvus | Vector database | Variable |

## Platform Support

- **linux-arm64**: NVIDIA Jetson (Orin, Xavier)
- **linux-x86_64**: Ubuntu, Debian, Arch
- **macos-arm64**: Apple Silicon (M1/M2/M3/M4)
- **windows-x64**: Windows 10/11

## Build From Source

For platforms without prebuilt binaries, build scripts are generated:

- `build-from-source.sh` - Jetson CUDA builds
- `build-macos.sh` - macOS Metal builds
- `build-linux-x86_64.sh` - Linux x86_64 with CUDA auto-detection
