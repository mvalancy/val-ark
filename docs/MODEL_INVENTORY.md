# AI Model Inventory

↑ [Docs](README.md) · [Repo root](../README.md)

The flagship LLM/STT/TTS/VLM/image catalog (~500 GB) is curated by
`scripts/download-models.sh`. A complementary **diversity catalog** of small,
high-value models (embeddings, rerankers, tiny VLMs, OCR, depth, segmentation,
detection, audio, time-series) lives in [`data/models-extra.tsv`](../data/models-extra.tsv)
and is filled automatically by the [Librarian](LIBRARIAN.md).

## Contents

- [Where models live](#where-models-live)
- [Quick Start](#quick-start)
- [Category 1: LLM Models (GGUF for llama.cpp)](#category-1-llm-models-gguf-for-llamacpp---300gb)
- [Category 2: TTS Models](#category-2-tts-models---15gb)
- [Category 3: STT / ASR Models](#category-3-stt--asr-models---20gb)
- [Category 4: Vision Language Models](#category-4-vision-language-models---40gb)
- [Category 5: Image Generation](#category-5-image-generation---40gb)
- [Category 6: NVIDIA Special](#category-6-nvidia-special---24gb)
- [Diversity Catalog (Librarian)](#diversity-catalog-librarian)
- [Usage with llama.cpp](#usage-with-llamacpp)
- [Performance Tips for NVIDIA (Jetson Orin / Thor / GB10)](#performance-tips-for-nvidia-jetson-orin--thor--gb10)

## Where models live

Models live at `<DATA_ROOT>/models`, where `<DATA_ROOT>` is the configurable data
root resolved by `scripts/lib/valark-env.sh` (from a git-ignored `.env`, else the
largest writable mount, else the repo). `~/models` and the repo-relative `models/`
dir are symlinked there, so the paths below work unchanged. See
[LIBRARIAN.md](LIBRARIAN.md) for the layout.

## Quick Start

```bash
# Priority tiers (recommended):
scripts/download-models.sh tier1    # Edge/mobile (~15GB)  - small, fast
scripts/download-models.sh tier2    # Workstation (~150GB) - balanced
scripts/download-models.sh tier3    # Large (~300GB+)      - highest quality
scripts/download-models.sh all      # Everything (~500GB, overnight)

# Or by category:
scripts/download-models.sh llm      # LLM models (~300GB)
scripts/download-models.sh tts      # Text-to-Speech (~15GB)
scripts/download-models.sh stt      # Speech-to-Text (~20GB)
scripts/download-models.sh vision   # Vision Language Models (~40GB)
scripts/download-models.sh image    # Image Generation (~40GB)
scripts/download-models.sh nvidia   # NVIDIA Special (~24GB)
scripts/download-models.sh extra    # Additional quality models (~75GB)
scripts/download-models.sh bitnet   # BitNet 1-bit models (~14GB)

scripts/download-models.sh validate # Pre-check all URLs, download nothing
```

Downloads never abort on error, resume (`wget -c`), retry with backoff, and track
failures for retry. Small diversity models from `models-extra.tsv` instead flow
through the Librarian, which uses aria2 multi-connection (~3x faster, curl fallback).

## Category 1: LLM Models (GGUF for llama.cpp) - ~300GB

### NVIDIA Nemotron Family
| Model | Quant | Size | Active Params | Notes |
|-------|-------|------|---------------|-------|
| Nemotron-3-Nano-30B-A3B | Q4_K_M | 24.6 GB | 3.2B (MoE) | TOP PICK: Fast MoE, only 3.2B active |
| Nemotron-3-Nano-30B-A3B | Q8_0 | 33.6 GB | 3.2B (MoE) | Higher quality, needs offload |
| Nemotron-Nano-12B-v2 | Q8_0 | ~11 GB | 12B | Hybrid Mamba-2 + Attention |
| Nemotron-Nano-9B-v2 | Q8_0 | ~7.9 GB | 9B | Compact, fast reasoning |
| Nemotron-Mini-4B | Q8_0 | ~4.5 GB | 4B | Ultra-fast, good for drafting |
| Nemotron-70B-Instruct | IQ2_XXS | ~19 GB | 70B | Aggressive quant, still capable |
| Nemotron-Super-49B-v1.5 | IQ3_XXS | ~19.7 GB | 49B | Top-tier conversational |

### Qwen 2.5 Family
| Model | Quant | Size | Notes |
|-------|-------|------|-------|
| Qwen2.5-32B-Instruct | Q4_K_M | 19.9 GB | Best general-purpose open model |
| Qwen2.5-32B-Instruct | Q5_K_M | 23.4 GB | Higher quality variant |
| Qwen2.5-Coder-32B | Q4_K_M | 19.9 GB | Top coding model |
| Qwen2.5-14B-Instruct | Q8_0 | 15.7 GB | Near-lossless, fast |
| Qwen2.5-14B-Instruct | Q6_K | 12.5 GB | Good quality/speed balance |
| QwQ-32B | Q4_K_M | 19.9 GB | Reasoning (o1-mini competitive) |

### DeepSeek R1 Distilled
| Model | Quant | Size | Notes |
|-------|-------|------|-------|
| DeepSeek-R1-Distill-Qwen-32B | Q4_K_M | 19.9 GB | TOP PICK reasoning |
| DeepSeek-R1-Distill-Qwen-32B | Q5_K_M | 23.4 GB | Higher quality |
| DeepSeek-R1-Distill-Qwen-14B | Q8_0 | 15.7 GB | Compact reasoning |
| DeepSeek-R1-Distill-Qwen-14B | Q6_K | 12.1 GB | Good balance |

### Microsoft Phi-4
| Model | Quant | Size | Notes |
|-------|-------|------|-------|
| Phi-4 | Q8_0 | 16 GB | Excellent reasoning/math/code |
| Phi-4-reasoning | Q8_0 | 15.6 GB | Chain-of-thought enhanced |
| Phi-4-reasoning-plus | Q8_0 | 15.6 GB | Best reasoning variant |

### Meta Llama 3.x
| Model | Quant | Size | Notes |
|-------|-------|------|-------|
| Llama-3.1-8B-Instruct | Q8_0 | 8.5 GB | 128K context, fast on modern hardware |
| Llama-3.2-3B-Instruct | Q8_0 | 3.4 GB | Ultra-fast for pipelines |
| Llama-3.2-1B-Instruct | Q8_0 | 1.3 GB | Minimal footprint |
| Llama-3.3-70B-Instruct | IQ2_XXS | ~19 GB | Latest 70B, aggressive quant |

### Mistral
| Model | Quant | Size | Notes |
|-------|-------|------|-------|
| Mistral-Nemo-12B | Q8_0 | 13 GB | 128K context, Apache 2.0 |
| Mistral-Nemo-12B | Q6_K | 10.1 GB | Lighter variant |

### Google Gemma
| Model | Quant | Size | Notes |
|-------|-------|------|-------|
| Gemma-2-27B-IT | Q4_K_M | 16.6 GB | Strong creative/general |
| Gemma-2-9B-IT | Q8_0 | ~9.8 GB | Fast, good quality |
| Gemma-3-27B-IT | Q4_K_M | ~17 GB | Latest generation |

### BitNet 1-bit Models (I2_S for BitNet.cpp)
| Model | Quant | Size | Notes |
|-------|-------|------|-------|
| BitNet-b1.58-2B-4T | I2_S | 1.2 GB | Official Microsoft, trained on 4T tokens |
| Falcon3-1B-Instruct-1.58bit | I2_S | 1.3 GB | Ultra-fast edge, TII UAE |
| Falcon3-3B-Instruct-1.58bit | I2_S | 2.1 GB | Best edge balance |
| Falcon3-7B-Instruct-1.58bit | I2_S | 3.1 GB | Near full-precision quality |
| Falcon3-10B-Instruct-1.58bit | I2_S | 3.8 GB | Best 1-bit quality available |

---

## Category 2: TTS Models - ~15GB

| Model | Size | Format | Notes |
|-------|------|--------|-------|
| Kokoro-82M | ~350 MB | PyTorch | #1 TTS Arena, 82M params, Apache 2.0 |
| Kokoro-82M ONNX | ~300 MB | ONNX | Fastest inference, INT8 available |
| OuteTTS-1.0-0.6B | ~600 MB | GGUF | Runs on llama.cpp, voice cloning |
| Piper TTS (5 voices) | ~600 MB | ONNX | Ultra-fast (<700ms), edge-optimized |
| Coqui XTTS v2 | ~2.1 GB | PyTorch | Best voice cloning, 17 languages |
| Parler TTS Mini v1.1 | ~3.5 GB | PyTorch | Natural language voice control |
| StyleTTS2-LibriTTS | ~1 GB | PyTorch | Human-level quality |
| Bark (small) | ~2 GB | PyTorch | Music + speech + effects |

---

## Category 3: STT / ASR Models - ~20GB

| Model | Size | Format | Notes |
|-------|------|--------|-------|
| Whisper large-v3-turbo | 1.62 GB | GGML | Best overall for quality/speed |
| Whisper large-v3-turbo Q5_0 | 574 MB | GGML | TOP PICK for edge |
| Whisper large-v3 | 3.1 GB | GGML | Highest quality |
| Whisper large-v2 Q5_0 | 1.08 GB | GGML | Good fallback |
| Whisper medium Q5_0 | 539 MB | GGML | Balanced |
| Whisper small/base/tiny | ~500 MB | GGML | Ultra-fast options |
| Distil-Whisper v3.5 | ~1.5 GB | GGML | 1.5x faster than turbo |
| Distil-Whisper v3 | ~1.5 GB | GGML | Proven reliable |
| Moonshine (ONNX) | ~2.5 GB | ONNX | Fastest edge ASR |
| Vosk EN-US (3 models) | ~4 GB | Kaldi | Streaming, offline, 40MB min |
| Faster-Whisper large-v3 | ~3 GB | CTranslate2 | 4x faster than vanilla |
| Faster-Whisper v3-turbo | ~1.6 GB | CTranslate2 | Best Python option |
| Parakeet-TDT-0.6B-v2 | ~1.5 GB | NeMo | NVIDIA SOTA English ASR |

---

## Category 4: Vision Language Models - ~40GB

| Model | Size | Format | Notes |
|-------|------|--------|-------|
| MiniCPM-V 2.6 | ~5 GB | GGUF | GPT-4V competitive, llama.cpp |
| LLaVA 1.6 Mistral 7B | ~5 GB | GGUF | Proven VLM, good quality |
| Moondream 2 | ~4 GB | PyTorch | Tiny but capable |
| NVIDIA Nemotron Nano VL 8B | ~16 GB | SafeTensors | OCR champion, Jetson-optimized |
| Qwen2-VL 7B | ~5 GB | GGUF | Strong multilingual VLM |

---

## Category 5: Image Generation - ~40GB

| Model | Size | Format | Notes |
|-------|------|--------|-------|
| Stable Diffusion 3.5 Medium | ~5 GB | SafeTensors | Latest SD, good quality |
| SDXL Turbo | ~7 GB | SafeTensors | 1-step generation |
| SDXL Lightning | ~7 GB | SafeTensors | Fast high-quality |
| SDXL Base 1.0 | ~7 GB | SafeTensors | Full SDXL baseline |
| PixArt-Sigma 1024 | ~2.5 GB | SafeTensors | 0.6B params, 4K capable |

---

## Category 6: NVIDIA Special - ~24GB

| Model | Size | Format | Notes |
|-------|------|--------|-------|
| Audio2Face-3D v3.0 | ~1 GB | PyTorch | Facial animation from audio |
| Canary-1B | ~2 GB | NeMo | Multilingual ASR + translation |
| Cosmos Tokenizer | ~2 GB | PyTorch | World model tokenizer |
| Cosmos-Reason1-7B | ~14 GB | PyTorch | Physical AI reasoning |
| PersonaPlex-7B | ~14 GB | SafeTensors | Conversational persona model |

---

## Diversity Catalog (Librarian)

Beyond the big catalog above, [`data/models-extra.tsv`](../data/models-extra.tsv)
broadens modality coverage with small, high-value files the
[Librarian](LIBRARIAN.md) downloads to fill spare disk:

| Modality | Examples |
|----------|----------|
| Embeddings / rerankers | bge, nomic, mxbai, gte, jina, e5 (RAG backbone) |
| Tiny VLMs / OCR | SmolVLM, moondream2, granite-docling, Florence-2 |
| Speech | silero-vad, whisper-base ONNX, Kokoro-q8 |
| Vision | YOLO11n, depth-anything-v2, MobileSAM, CLIP, SigLIP |
| Time-series / audio | chronos-t5, moirai, CLAP, musicgen-small |
| Safety | Llama-Guard-3-8B |

---

## Usage with llama.cpp

```bash
# Run a GGUF model ($MODELS_DIR resolves to <DATA_ROOT>/models):
llama-server \
    -m "$MODELS_DIR/llm/nemotron-3-nano-30b/Nemotron-3-Nano-30B-A3B-Q4_K_M.gguf" \
    -ngl 999 -fa -c 4096 --port 8080

# Run whisper:
whisper-cli \
    -m "$MODELS_DIR/stt/whisper-ggml/ggml-large-v3-turbo-q5_0.bin" \
    -f audio.wav
```

In a mesh, the data root is NFS-exportable: fleet nodes mount one shared mirror and
run GPU inference on the served models over the network ([PLATFORMS.md](PLATFORMS.md)).

## Performance Tips for NVIDIA (Jetson Orin / Thor / GB10)

1. Set max power mode: `sudo nvpmodel -m 0 && sudo jetson_clocks`
2. On aarch64 there are no upstream GPU binaries — build llama.cpp/whisper.cpp from
   source with CUDA: `cmake -B build -DGGML_CUDA=ON && cmake --build build -j$(nproc)`
   (see [PLATFORMS.md](PLATFORMS.md)).
3. Always use `-ngl 999` to offload all layers to GPU
4. Use `-fa` for flash attention (10-15% speed boost)
5. For MoE models, ensure all experts are GPU-offloaded
6. Q4_0 benefits from automatic weight repacking on ARM/CUDA

---

[Back to docs](README.md)
