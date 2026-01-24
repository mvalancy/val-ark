# Val Ark - Offline & P2P Guide

## Design Philosophy

Val Ark is built for **online-optional** operation:
- Download everything once while online
- Run entirely offline afterward
- Sync between machines over LAN (no internet needed)
- Peer-to-peer distribution via Syncthing

## Offline Workflow

### 1. Initial Download (requires internet)
```bash
./start.sh setup
./start.sh download tools
./start.sh download models tier1  # Start small
./start.sh download models tier2  # Then medium
./start.sh download models tier3  # Then large (if space allows)
```

### 2. Verify Downloads
```bash
./start.sh status
./tests/run-all.sh
```

### 3. Go Offline
Once downloaded, everything runs locally:

```bash
# LLM inference (no internet needed)
./tools/llama.cpp/linux-arm64/llama-server \
    -m ~/models/llm/llama-3.2-3b/Llama-3.2-3B-Instruct-Q8_0.gguf

# Speech-to-text (no internet needed)
./tools/whisper.cpp/linux-arm64/whisper-cli \
    -m ~/models/stt/whisper-ggml/ggml-base.en-q8_0.bin \
    -f audio.wav

# Text-to-speech (no internet needed)
echo "Hello world" | ./tools/piper/linux-arm64/piper/piper \
    --model ~/models/tts/piper-voices/v2/en/en_US/lessac/high/en_US-lessac-high.onnx \
    --output_file output.wav
```

## Peer-to-Peer Sync

### Syncthing Setup

1. **Install Syncthing** (included in tools download):
   ```bash
   ./tools/linux-arm64/syncthing/syncthing
   # Access web UI at http://localhost:8384
   ```

2. **Share the models directory** between machines:
   - Add `~/models/` as a shared folder
   - Connect devices via their Device IDs
   - Models sync automatically over LAN

3. **Selective sync** with `.stignore`:
   ```
   # On constrained devices, ignore large models:
   /llm/nemotron-70b
   /llm/llama-3.3-70b
   /llm/*-32b
   /image-gen/sdxl-base
   ```

### LAN-Only Mode
Configure Syncthing for LAN-only sync (no relay servers):
- Settings > Connections > uncheck "Enable Relaying"
- Settings > Connections > uncheck "Global Discovery"
- Use local discovery only

## Air-Gapped Transfer

For fully air-gapped environments:

### USB Drive Method
```bash
# On online machine: copy to USB
rsync -av --progress ~/models/ /mnt/usb/models/

# On offline machine: copy from USB
rsync -av --progress /mnt/usb/models/ ~/models/
```

### Tarball Method
```bash
# Pack specific tier
tar czf val-ark-tier1.tar.gz \
    models/llm/llama-3.2-1b \
    models/llm/llama-3.2-3b \
    models/llm/nemotron-mini-4b \
    models/stt/whisper-ggml/ggml-tiny* \
    models/stt/whisper-ggml/ggml-base* \
    models/stt/whisper-ggml/ggml-small* \
    models/tts/piper-voices

# Transfer and unpack
tar xzf val-ark-tier1.tar.gz -C ~/
```

## Storage Recommendations

| Tier | Storage Needed | Suitable Devices |
|------|---------------|------------------|
| Tier 1 only | ~15 GB | Phones, tablets, Raspberry Pi |
| Tier 1+2 | ~165 GB | Laptops, workstations |
| All tiers | ~500 GB | Servers, NAS |

## Network Requirements

| Operation | Internet Required? |
|-----------|-------------------|
| Initial download | Yes |
| Running models | No |
| Syncthing (LAN) | No (LAN only) |
| Updates | Yes |
| Validation | Yes |
