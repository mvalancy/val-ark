#!/bin/bash
# Val Ark - Download ComfyUI
source "$(dirname "$0")/_common.sh"

TOOL_NAME="comfyui"
PINNED_VERSION="v0.10.0"

download_comfyui() {
    log "Downloading ${TOOL_NAME}..."

    local linux_instructions="ComfyUI - Installation Instructions (Linux)
=============================================

ComfyUI is a Python application. Install from source:

1. Clone the repository:
   git clone https://github.com/Comfy-Org/ComfyUI.git
   cd ComfyUI

2. Create a virtual environment (recommended):
   python3 -m venv venv
   source venv/bin/activate

3. Install PyTorch (select one):
   # NVIDIA GPU (CUDA 12.1):
   pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
   # CPU only:
   pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu

4. Install ComfyUI dependencies:
   pip install -r requirements.txt

5. Run ComfyUI:
   python main.py

6. Access the UI at: http://127.0.0.1:8188

For more info: https://github.com/Comfy-Org/ComfyUI
"

    local macos_instructions="ComfyUI - Installation Instructions (macOS)
=============================================

ComfyUI is a Python application. Install from source:

1. Clone the repository:
   git clone https://github.com/Comfy-Org/ComfyUI.git
   cd ComfyUI

2. Create a virtual environment (recommended):
   python3 -m venv venv
   source venv/bin/activate

3. Install PyTorch (Apple Silicon MPS):
   pip install torch torchvision torchaudio

4. Install ComfyUI dependencies:
   pip install -r requirements.txt

5. Run ComfyUI:
   python main.py --force-fp16

6. Access the UI at: http://127.0.0.1:8188

For more info: https://github.com/Comfy-Org/ComfyUI
"

    local windows_instructions="ComfyUI - Installation Instructions (Windows)
===============================================

Option 1 - Portable Package (recommended):
  Download the Windows portable build from:
  https://github.com/Comfy-Org/ComfyUI/releases

  Available variants:
    - ComfyUI_windows_portable_nvidia.7z (NVIDIA GPU, CUDA 12.1)
    - ComfyUI_windows_portable_nvidia_cu126.7z (NVIDIA GPU, CUDA 12.6)
    - ComfyUI_windows_portable_nvidia_cu128.7z (NVIDIA GPU, CUDA 12.8)
    - ComfyUI_windows_portable_amd.7z (AMD GPU)

  Extract with 7-Zip and run:
    run_nvidia_gpu.bat   (or run_cpu.bat for CPU-only)

Option 2 - Manual install:
  1. Install Python 3.11+ from https://python.org
  2. Clone the repository:
     git clone https://github.com/Comfy-Org/ComfyUI.git
     cd ComfyUI
  3. Create a virtual environment:
     python -m venv venv
     venv\\Scripts\\activate
  4. Install PyTorch:
     pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
  5. Install dependencies:
     pip install -r requirements.txt
  6. Run:
     python main.py

Access the UI at: http://127.0.0.1:8188

For more info: https://github.com/Comfy-Org/ComfyUI
"

    # linux-arm64
    write_install_hint "${TOOLS_DIR}/linux-arm64/comfyui" "comfyui (linux-arm64)" "$linux_instructions"

    # linux-x86_64
    write_install_hint "${TOOLS_DIR}/linux-x86_64/comfyui" "comfyui (linux-x86_64)" "$linux_instructions"

    # macos-arm64
    write_install_hint "${TOOLS_DIR}/macos-arm64/comfyui" "comfyui (macos-arm64)" "$macos_instructions"

    # windows-x64
    write_install_hint "${TOOLS_DIR}/windows-x64/comfyui" "comfyui (windows-x64)" "$windows_instructions"

    log_success "${TOOL_NAME} download complete."
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_comfyui
