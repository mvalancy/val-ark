#!/bin/bash
# Val Ark - Download Claude Code
source "$(dirname "$0")/_common.sh"

TOOL_NAME="claude-code"
PINNED_VERSION="latest"

download_claude_code() {
    log "Downloading ${TOOL_NAME}..."

    local instructions="Claude Code - Installation Instructions
==========================================

Claude Code is distributed as an npm package.

Install (all platforms):
  npm install -g @anthropic-ai/claude-code

Requirements:
  - Node.js 18+ (https://nodejs.org/)
  - npm (comes with Node.js)

Usage:
  claude

For more information:
  https://code.claude.com/docs
"

    # linux-arm64
    local dest="${TOOLS_DIR}/linux-arm64/claude-code"
    write_install_hint "$dest" "claude-code (linux-arm64)" "$instructions"

    # linux-x86_64
    dest="${TOOLS_DIR}/linux-x86_64/claude-code"
    write_install_hint "$dest" "claude-code (linux-x86_64)" "$instructions"

    # macos-arm64
    dest="${TOOLS_DIR}/macos-arm64/claude-code"
    write_install_hint "$dest" "claude-code (macos-arm64)" "$instructions"

    # windows-x64
    dest="${TOOLS_DIR}/windows-x64/claude-code"
    write_install_hint "$dest" "claude-code (windows-x64)" "$instructions"
}

# Run if called directly
[ "${BASH_SOURCE[0]}" = "$0" ] && download_claude_code
