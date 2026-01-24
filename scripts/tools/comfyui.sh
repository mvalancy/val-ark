#!/bin/bash
# Val Ark - Download ComfyUI
source "$(dirname "$0")/_common.sh"

TOOL_NAME="comfyui"
PINNED_VERSION="master"

download_comfyui() {
    log "Downloading ${TOOL_NAME}..."

    local repo_url="https://github.com/comfyanonymous/ComfyUI.git"
    local ref="${PINNED_VERSION}"

    local setup_instructions="ComfyUI - Setup Instructions
==============================

After cloning, install dependencies:

1. Create a virtual environment (recommended):
   cd comfyui
   python -m venv venv
   source venv/bin/activate   # Linux/macOS
   # or: venv\\Scripts\\activate  # Windows

2. Install requirements:
   pip install -r requirements.txt

3. For GPU support (NVIDIA):
   pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

4. Run ComfyUI:
   python main.py

5. Access the UI at: http://127.0.0.1:8188

For more info: https://github.com/comfyanonymous/ComfyUI
"

    # linux-x86_64
    local dest="${TOOLS_DIR}/linux-x86_64/comfyui"
    clone_repo "$repo_url" "$ref" "$dest" "comfyui (linux-x86_64)"
    if [ -d "$dest" ]; then
        echo "$setup_instructions" > "${dest}/SETUP.txt"
        log_info "Created SETUP.txt for comfyui (linux-x86_64)"
    fi

    # linux-arm64
    dest="${TOOLS_DIR}/linux-arm64/comfyui"
    clone_repo "$repo_url" "$ref" "$dest" "comfyui (linux-arm64)"
    if [ -d "$dest" ]; then
        echo "$setup_instructions" > "${dest}/SETUP.txt"
        log_info "Created SETUP.txt for comfyui (linux-arm64)"
    fi

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/comfyui"
    clone_repo "$repo_url" "$ref" "$dest" "comfyui (macos-arm64)"
    if [ -d "$dest" ]; then
        echo "$setup_instructions" > "${dest}/SETUP.txt"
        log_info "Created SETUP.txt for comfyui (macos-arm64)"
    fi
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_comfyui
