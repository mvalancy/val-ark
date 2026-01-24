# Val Ark - Tools Catalog (41 Tools)

[Back to Docs](README.md) | [Back to Project Root](../README.md)

```mermaid
%%{init: {'theme': 'dark', 'themeVariables': {'pie1': '#2563eb', 'pie2': '#7c3aed', 'pie3': '#e87d0d', 'pie4': '#16a34a', 'pie5': '#0891b2', 'pie6': '#6366f1'}}}%%
pie title Tool Categories (41 Total)
    "AI Inference (8)" : 8
    "AI Platforms (6)" : 6
    "Creative (6)" : 6
    "Media (5)" : 5
    "Infrastructure (8)" : 8
    "Dev Tools (9)" : 9
```

---

## AI Inference (8)

Local inference engines for running AI models directly on hardware without cloud dependencies.

| # | Tool | Description | Platforms | Method | License |
|---|------|-------------|-----------|--------|---------|
| 1 | **llama.cpp** | LLM/VLM inference engine for GGUF quantized models with GPU offloading | arm64, x86_64, mac, windows | Prebuilt binary (mac/win), source build (Linux CUDA) | MIT |
| 2 | **whisper.cpp** | Fast speech-to-text using OpenAI Whisper models in C/C++ | arm64, x86_64, mac, windows | Prebuilt binary (mac), source build (Linux/Win CUDA) | MIT |
| 3 | **Piper TTS** | Fast neural text-to-speech with VITS/ONNX models, 51 languages | arm64, x86_64, mac, windows | Prebuilt binary | MIT |
| 4 | **stable-diffusion.cpp** | Image generation from text prompts (SD 1.x, SDXL, SD3.5, FLUX, Wan2.1) | arm64, x86_64, mac, windows | Prebuilt binary (mac/win), source build (Linux CUDA) | MIT |
| 5 | **ONNX Runtime** | Inference runtime for Kokoro TTS, Silero VAD, Moonshine ASR, and ONNX models | arm64, x86_64, mac, windows | Prebuilt binary | MIT |
| 6 | **Vosk** | Lightweight offline speech recognition (Kaldi-based), 30+ languages, streaming | arm64, x86_64, mac, windows | Prebuilt binary / pip | Apache-2.0 |
| 7 | **BitNet.cpp** | 1-bit (ternary) LLM inference, 2-6x CPU speedup over FP16 | arm64, x86_64 | Source build (Python setup) | MIT |
| 8 | **FFmpeg** | Audio/video processing, format conversion, Whisper audio prep, HW encoding | arm64, x86_64, mac, windows | Prebuilt binary | LGPL-2.1+ |

---

## AI Platforms (6)

Higher-level AI services, model managers, and workflow systems.

| # | Tool | Description | Platforms | Method | License |
|---|------|-------------|-----------|--------|---------|
| 9 | **Ollama** | Model manager and server for local LLMs with pull/run/serve workflow | arm64, x86_64, mac, windows | Prebuilt binary | MIT |
| 10 | **n8n** | Workflow automation platform with AI nodes, connects to Ollama/llama.cpp | arm64, x86_64 | npm / Docker | Sustainable Use |
| 11 | **InfluxDB** | Time-series database for metrics, inference telemetry, and IoT sensor data | arm64, x86_64, mac, windows | Prebuilt binary | MIT / Apache-2.0 |
| 12 | **Milvus** | Vector database for embeddings, similarity search, and RAG pipelines | x86_64 | pip (Milvus Lite) / Docker | Apache-2.0 |
| 13 | **ComfyUI** | Node-based image/video generation workflow editor using sd.cpp models | arm64, x86_64, mac, windows | pip / source (Python) | GPL-3.0 |
| 14 | **Open WebUI** | ChatGPT-style web interface for Ollama and local LLMs with RAG support | arm64, x86_64, mac, windows | pip / Docker | MIT |

---

## Creative (6)

Design, modeling, and content creation tools with headless/scripting capabilities.

| # | Tool | Description | Platforms | Method | License |
|---|------|-------------|-----------|--------|---------|
| 15 | **Blender** | 3D modeling, animation, rendering with Python scripting API (bpy) | x86_64, mac, windows | Prebuilt binary | GPL-2.0+ |
| 16 | **FreeCAD** | Parametric 3D CAD modeler with headless mode (FreeCADCmd) and Python API | x86_64, mac, windows | Prebuilt binary | LGPL-2.1+ |
| 17 | **KiCad** | PCB/schematic EDA suite with kicad-cli for headless Gerber/BOM/DRC export | x86_64 | Prebuilt binary (AppImage) | GPL-3.0+ |
| 18 | **Godot Engine** | 2D/3D game engine with GDScript, headless export, and CI integration | arm64, x86_64, mac, windows | Prebuilt binary | MIT |
| 19 | **GIMP** | Raster image editor with batch processing via Script-Fu and Python-Fu | x86_64, mac, windows | Package manager / Flatpak | GPL-3.0 |
| 20 | **Inkscape** | Vector graphics editor (SVG) with CLI export to PDF/PNG/EPS | x86_64 | Package manager | GPL-2.0+ |

---

## Media (5)

Media playback, download, conversion, and library management.

| # | Tool | Description | Platforms | Method | License |
|---|------|-------------|-----------|--------|---------|
| 21 | **FFmpeg** | Audio/video processing, transcoding, streaming, and frame extraction | arm64, x86_64, mac, windows | Prebuilt binary | LGPL-2.1+ |
| 22 | **VLC** | Universal media player with CLI transcoding and HTTP streaming (cvlc) | arm64, x86_64, mac, windows | Prebuilt binary | GPL-2.0+ |
| 23 | **yt-dlp** | Video/audio downloader supporting 1000+ sites with format selection | arm64, x86_64, mac, windows | Prebuilt binary | Unlicense |
| 24 | **Calibre** | E-book library manager, format converter, and content server | arm64, x86_64, mac, windows | Prebuilt binary | GPL-3.0 |
| 25 | **Audacity** | Multi-track audio editor with recording, effects, and noise reduction | x86_64, mac, windows | Prebuilt binary / package manager | GPL-3.0 |

Note: FFmpeg appears in both AI Inference and Media categories as it serves both roles (audio prep for Whisper and general media processing).

---

## Infrastructure (8)

Networking, sync, databases, self-hosting, and IoT messaging.

| # | Tool | Description | Platforms | Method | License |
|---|------|-------------|-----------|--------|---------|
| 26 | **Syncthing** | Peer-to-peer continuous file synchronization across devices | arm64, x86_64, mac, windows | Prebuilt binary | MPL-2.0 |
| 27 | **Coolify** | Self-hosted PaaS for deploying apps, databases, and services with Git push | x86_64 | Docker / install script | Apache-2.0 |
| 28 | **Kiwix** | Offline content server for ZIM archives (Wikipedia, StackOverflow, etc.) | arm64, x86_64, mac, windows | Prebuilt binary | GPL-3.0 |
| 29 | **Tailscale** | Mesh VPN / overlay network with zero-config device connectivity | arm64, x86_64, mac, windows | Prebuilt binary | BSD-3-Clause |
| 30 | **Mosquitto** | Lightweight MQTT broker and clients for IoT device messaging | arm64 | Source build (compiled) | EPL-2.0 / EDL-1.0 |
| 31 | **MQTT Explorer** | Visual GUI MQTT client for browsing topics and debugging IoT data flows | x86_64 | Prebuilt binary (AppImage) | CC-BY-ND-4.0 |
| 32 | **Redis** | In-memory key-value store for caching, pub/sub, and session management | arm64 | Source build (compiled) | RSALv2 / SSPLv1 |
| 33 | **PostgreSQL** | Relational database with pgvector extension for AI embeddings | arm64 | Source build (compiled) | PostgreSQL License |

---

## Dev Tools (9)

Editors, terminals, runtimes, CLI utilities, and AI coding assistants.

| # | Tool | Description | Platforms | Method | License |
|---|------|-------------|-----------|--------|---------|
| 34 | **btop** | Interactive system/resource monitor with CPU, GPU, memory, and process views | arm64, x86_64, mac, windows | Prebuilt binary | Apache-2.0 |
| 35 | **tmux** | Terminal multiplexer with session persistence, splits, and remote attach | arm64, x86_64, mac | Prebuilt binary (static) | ISC |
| 36 | **Helix** | Modal text editor (Rust) with built-in LSP, tree-sitter, and multi-cursor | arm64, x86_64, mac, windows | Prebuilt binary | MPL-2.0 |
| 37 | **VSCodium** | Open-source VS Code (telemetry-free) with Open VSX extension registry | arm64, x86_64, mac, windows | Prebuilt binary | MIT |
| 38 | **SQLite** | Embedded SQL database CLI for experiment tracking, logs, and local storage | arm64, x86_64, windows | Prebuilt binary | Public Domain |
| 39 | **Miniforge** | Conda-forge distribution for managing Python environments and packages offline | arm64, x86_64, mac, windows | Prebuilt installer | BSD-3-Clause |
| 40 | **Python Standalone** | Portable CPython build with no system dependencies, pip included | arm64, x86_64, mac, windows | Prebuilt binary | MPL-2.0 |
| 41 | **Dev CLI Bundle** | ripgrep, fd, bat, jq, fzf, lazygit bundled as portable CLI dev tools | arm64, x86_64, mac, windows | Prebuilt binary | MIT / Apache-2.0 |
| -- | **Claude Code** | Anthropic's agentic coding CLI, works offline via Ollama or llama.cpp backend | arm64, x86_64, mac, windows | npm | Proprietary |

Note: Claude Code is bundled within the Dev Tools category but is listed separately as it requires an npm install rather than a direct binary download. The total unique tool count is 41 (FFmpeg shared between AI Inference and Media, Claude Code as part of Dev Tools).

---

## Platform Support Matrix

| Platform | Architecture | Examples |
|----------|-------------|----------|
| linux-arm64 | ARM64 | NVIDIA Jetson (Orin, Xavier), Raspberry Pi |
| linux-x86_64 | x86_64 | Ubuntu, Debian, Arch, Fedora |
| macos-arm64 | Apple Silicon | M1 / M2 / M3 / M4 |
| windows-x64 | x86_64 | Windows 10 / 11 |

---

## Download Methods

| Method | Description |
|--------|-------------|
| Prebuilt binary | Static binary or portable archive, runs immediately |
| Source build | Compiled from source with platform-specific flags (CUDA, Metal) |
| pip | Python package installed via pip into a virtualenv |
| npm | Node.js package installed globally via npm |
| Docker | Container image pulled and run via Docker/Compose |
| Package manager | Installed via apt, brew, or flatpak |

---

## Build From Source

For platforms without prebuilt binaries, build scripts are generated:

- `build-from-source.sh` - Jetson CUDA builds (llama.cpp, whisper.cpp, sd.cpp)
- `build-macos.sh` - macOS Metal builds
- `build-linux-x86_64.sh` - Linux x86_64 with CUDA auto-detection
