#!/bin/bash
###############################################################################
# Val Ark - Online-Optional Tool Server
# Entry point: interactive menu + CLI arguments
#
# Created by Matthew Valancy
###############################################################################

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="${SCRIPT_DIR}/scripts"
TESTS="${SCRIPT_DIR}/tests"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

###############################################################################
# Cron Management
###############################################################################

CRON_CMD="cd ${SCRIPT_DIR} && ./start.sh update >> /var/log/val-ark-update.log 2>&1"
CRON_SCHEDULE="0 3 * * 0"
CRON_LINE="${CRON_SCHEDULE} ${CRON_CMD}"

cron_install() {
    (crontab -l 2>/dev/null | grep -v "val-ark-update"; echo "$CRON_LINE") | crontab -
    echo -e "  ${GREEN}✓${NC} Weekly cron job installed (Sundays at 3 AM)"
    echo "    ${CRON_LINE}"
}

cron_remove() {
    crontab -l 2>/dev/null | grep -v "val-ark-update" | crontab -
    echo -e "  ${GREEN}✓${NC} Cron job removed"
}

cron_status() {
    echo ""
    echo -e "  ${BOLD}Val Ark cron entries:${NC}"
    echo ""
    local entries
    entries=$(crontab -l 2>/dev/null | grep "val-ark" || true)
    if [ -n "$entries" ]; then
        echo "  $entries"
    else
        echo "  (none)"
    fi
    echo ""
}

cron_menu() {
    echo ""
    echo -e "  ${BOLD}Cron Job${NC}"
    echo ""
    echo "  1) Install    Weekly auto-update (Sundays 3 AM)"
    echo "  2) Remove     Remove cron job"
    echo "  3) Status     Show current entries"
    echo ""
    echo "  0) Back"
    echo ""
    echo -n "  Enter choice [0-3]: "
    read -r choice

    case "$choice" in
        1) cron_install ;;
        2) cron_remove ;;
        3) cron_status ;;
        0|"") return ;;
        *) echo -e "  ${RED}Invalid choice${NC}"; cron_menu ;;
    esac
}

###############################################################################
# Systemd Service Management
###############################################################################

SERVICE_FILE="${SCRIPTS}/val-ark.service"

service_install() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo -e "${RED}Error:${NC} Service file not found: $SERVICE_FILE"
        exit 1
    fi

    echo -e "${BOLD}Installing Val Ark systemd service...${NC}"
    echo ""

    # Create service user if needed
    if ! id val-ark &>/dev/null; then
        echo -e "  Creating service user 'val-ark'..."
        sudo useradd -r -s /bin/false -d /opt/val-ark val-ark 2>/dev/null || true
    fi

    # Copy files to /opt/val-ark
    echo -e "  Copying files to /opt/val-ark..."
    sudo mkdir -p /opt/val-ark
    sudo cp -r "${SCRIPT_DIR}"/* /opt/val-ark/
    sudo chown -R val-ark:val-ark /opt/val-ark

    # Install service file
    echo -e "  Installing service file..."
    sudo cp "$SERVICE_FILE" /etc/systemd/system/val-ark.service
    sudo systemctl daemon-reload
    sudo systemctl enable val-ark

    echo ""
    echo -e "${GREEN}Service installed!${NC}"
    echo ""
    echo "  Start:   sudo systemctl start val-ark"
    echo "  Stop:    sudo systemctl stop val-ark"
    echo "  Status:  sudo systemctl status val-ark"
    echo "  Logs:    sudo journalctl -u val-ark -f"
    echo ""
}

service_remove() {
    echo -e "${BOLD}Removing Val Ark systemd service...${NC}"
    echo ""

    sudo systemctl stop val-ark 2>/dev/null || true
    sudo systemctl disable val-ark 2>/dev/null || true
    sudo rm -f /etc/systemd/system/val-ark.service
    sudo systemctl daemon-reload

    echo -e "${GREEN}Service removed.${NC}"
    echo "  Note: Files in /opt/val-ark were not deleted."
}

service_status() {
    echo ""
    if systemctl is-active --quiet val-ark 2>/dev/null; then
        echo -e "  ${GREEN}●${NC} val-ark service is ${GREEN}running${NC}"
        systemctl status val-ark --no-pager | head -15
    else
        echo -e "  ${RED}○${NC} val-ark service is ${RED}not running${NC}"
    fi
    echo ""
}

###############################################################################
# AI Commands - Convenience wrappers for common AI tasks
###############################################################################

# Detect platform and set tool paths
detect_platform() {
    local arch=$(uname -m)
    local os=$(uname -s)

    if [ "$os" = "Darwin" ]; then
        TOOLS_DIR="${SCRIPT_DIR}/tools/macos-arm64"
        GPU_FLAG="-ngl 999"
    elif [ "$os" = "Linux" ]; then
        if [ "$arch" = "aarch64" ]; then
            TOOLS_DIR="${SCRIPT_DIR}/tools/linux-arm64"
            GPU_FLAG="-ngl 999"
        else
            TOOLS_DIR="${SCRIPT_DIR}/tools/linux-x86_64"
            GPU_FLAG="-ngl 999"
        fi
    else
        # Windows / other
        TOOLS_DIR="${SCRIPT_DIR}/tools/windows-x64"
        GPU_FLAG="-ngl 999"
    fi
    MODELS_DIR="${SCRIPT_DIR}/models"
}

# Locate a tool binary by name anywhere under TOOLS_DIR (binaries install at
# nested/versioned paths, e.g. llama-cpp/llama-bNNNN/llama-server, piper/piper/piper).
find_bin() {
    find "${TOOLS_DIR}" -name "$1" -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x \) 2>/dev/null | head -1
}

# Find first available model matching pattern
find_model() {
    local pattern="$1"
    local category="$2"
    local found=""

    if [ -n "$pattern" ]; then
        # Look for model matching pattern
        found=$(find "${MODELS_DIR}/${category}" -name "*.gguf" -o -name "*.bin" 2>/dev/null | grep -i "$pattern" | head -1)
    fi

    if [ -z "$found" ]; then
        # Find smallest available model (for quick startup)
        found=$(find "${MODELS_DIR}/${category}" -name "*.gguf" -o -name "*.bin" 2>/dev/null | head -1)
    fi

    echo "$found"
}

# Start LLM chat server
ai_chat() {
    detect_platform
    local model_hint="${1:-}"
    local llama_server="$(find_bin llama-server)"
    [ -x "$llama_server" ] || llama_server="${TOOLS_DIR}/llama-server"

    if [ ! -x "$llama_server" ]; then
        echo -e "${RED}Error:${NC} llama-server not found under ${TOOLS_DIR}"
        echo "Run: ./start.sh download tools"
        exit 1
    fi

    local model=$(find_model "$model_hint" "llm")
    if [ -z "$model" ]; then
        echo -e "${RED}Error:${NC} No LLM models found in ${MODELS_DIR}/llm"
        echo "Run: ./start.sh download models tier1"
        exit 1
    fi

    echo -e "${GREEN}Starting chat server...${NC}"
    echo -e "  Model: ${CYAN}$(basename "$model")${NC}"
    echo -e "  URL:   ${CYAN}http://localhost:8080${NC}"
    echo ""
    echo -e "${DIM}Press Ctrl+C to stop${NC}"
    echo ""

    exec "$llama_server" -m "$model" $GPU_FLAG -c 4096 --port 8080
}

# Transcribe audio/video to text
ai_transcribe() {
    detect_platform
    local input_file="$1"

    if [ -z "$input_file" ]; then
        echo -e "${RED}Error:${NC} No input file specified"
        echo "Usage: ./start.sh transcribe <audio_or_video_file>"
        exit 1
    fi

    if [ ! -f "$input_file" ]; then
        echo -e "${RED}Error:${NC} File not found: $input_file"
        exit 1
    fi

    local whisper="$(find_bin whisper-cli)"
    [ -x "$whisper" ] || whisper="${TOOLS_DIR}/whisper-cli"
    if [ ! -x "$whisper" ]; then
        echo -e "${RED}Error:${NC} whisper-cli not found under ${TOOLS_DIR}"
        echo "Run: ./start.sh download tools"
        exit 1
    fi

    local model=$(find_model "turbo" "stt/whisper-ggml")
    if [ -z "$model" ]; then
        model=$(find_model "" "stt/whisper-ggml")
    fi
    if [ -z "$model" ]; then
        echo -e "${RED}Error:${NC} No Whisper models found"
        echo "Run: ./start.sh download models tier1"
        exit 1
    fi

    echo -e "${GREEN}Transcribing...${NC}"
    echo -e "  Input: ${CYAN}$input_file${NC}"
    echo -e "  Model: ${CYAN}$(basename "$model")${NC}"
    echo ""

    # Convert to WAV if needed (requires ffmpeg)
    local wav_file="$input_file"
    local temp_wav=""
    if [[ ! "$input_file" =~ \.wav$ ]]; then
        local ffmpeg="${TOOLS_DIR}/ffmpeg"
        if [ ! -x "$ffmpeg" ]; then
            ffmpeg=$(which ffmpeg 2>/dev/null)
        fi
        if [ -n "$ffmpeg" ]; then
            temp_wav="/tmp/val-ark-transcribe-$$.wav"
            echo -e "${DIM}Converting to WAV...${NC}"
            "$ffmpeg" -i "$input_file" -ar 16000 -ac 1 -y "$temp_wav" 2>/dev/null
            wav_file="$temp_wav"
        fi
    fi

    "$whisper" -m "$model" -f "$wav_file" --output-txt

    # Cleanup temp file
    [ -n "$temp_wav" ] && rm -f "$temp_wav"
}

# Generate image from text prompt
ai_image() {
    detect_platform
    local prompt="$1"

    if [ -z "$prompt" ]; then
        echo -e "${RED}Error:${NC} No prompt specified"
        echo "Usage: ./start.sh image \"your prompt here\""
        exit 1
    fi

    local sd="$(find_bin sd-cli)"; [ -x "$sd" ] || sd="$(find_bin sd)"
    [ -x "$sd" ] || sd="${TOOLS_DIR}/sd-cli"
    if [ ! -x "$sd" ]; then
        echo -e "${RED}Error:${NC} stable-diffusion (sd/sd-cli) not found under ${TOOLS_DIR}"
        echo "Run: ./start.sh download tools"
        exit 1
    fi

    local model=$(find_model "turbo" "image-gen")
    if [ -z "$model" ]; then
        model=$(find_model "" "image-gen")
    fi
    if [ -z "$model" ]; then
        echo -e "${RED}Error:${NC} No image generation models found"
        echo "Run: ./start.sh download models tier2"
        exit 1
    fi

    local output="output-$(date +%Y%m%d-%H%M%S).png"

    echo -e "${GREEN}Generating image...${NC}"
    echo -e "  Prompt: ${CYAN}$prompt${NC}"
    echo -e "  Model:  ${CYAN}$(basename "$model")${NC}"
    echo -e "  Output: ${CYAN}$output${NC}"
    echo ""

    "$sd" -m "$model" -p "$prompt" -o "$output" --steps 4

    if [ -f "$output" ]; then
        echo -e "${GREEN}Image saved to:${NC} $output"
    fi
}

# Text to speech
ai_speak() {
    detect_platform
    local text="$1"

    if [ -z "$text" ]; then
        echo -e "${RED}Error:${NC} No text specified"
        echo "Usage: ./start.sh speak \"text to speak\""
        exit 1
    fi

    local piper="$(find_bin piper)"
    [ -x "$piper" ] || piper="${TOOLS_DIR}/piper/piper"
    if [ ! -x "$piper" ]; then
        echo -e "${RED}Error:${NC} piper not found under ${TOOLS_DIR}"
        echo "Run: ./start.sh download tools"
        exit 1
    fi

    local model=$(find_model "lessac" "tts/piper")
    if [ -z "$model" ]; then
        model=$(find_model "" "tts/piper")
    fi
    if [ -z "$model" ]; then
        echo -e "${RED}Error:${NC} No Piper voice models found"
        echo "Run: ./start.sh download models tier1"
        exit 1
    fi

    local output="speech.wav"

    echo -e "${GREEN}Generating speech...${NC}"
    echo -e "  Text:   ${CYAN}$text${NC}"
    echo -e "  Voice:  ${CYAN}$(basename "$model")${NC}"
    echo -e "  Output: ${CYAN}$output${NC}"
    echo ""

    echo "$text" | "$piper" --model "$model" --output_file "$output"

    if [ -f "$output" ]; then
        echo -e "${GREEN}Audio saved to:${NC} $output"
        # Try to play it
        if command -v aplay &>/dev/null; then
            aplay "$output" 2>/dev/null
        elif command -v afplay &>/dev/null; then
            afplay "$output" 2>/dev/null
        fi
    fi
}

###############################################################################
# CLI Mode
###############################################################################

show_help() {
    echo ""
    echo -e "${BOLD}Val Ark${NC} - Online-Optional Tool Server"
    echo ""
    echo "Usage: ./start.sh [command] [options]"
    echo ""
    echo -e "${BOLD}AI Commands:${NC}"
    echo "  chat [model]             Start LLM chat server (default: smallest available)"
    echo "  transcribe <file>        Convert audio/video to text"
    echo "  image \"<prompt>\"         Generate an image from text"
    echo "  speak \"<text>\"           Convert text to speech (saves to speech.wav)"
    echo ""
    echo -e "${BOLD}Management:${NC}"
    echo "  setup                    Install dependencies, create directories"
    echo "  download tools           Download tools (smallest first, then AI engines)"
    echo "  download models tier1    Download edge/mobile models (small, fast)"
    echo "  download models tier2    Download balanced workstation models"
    echo "  download models tier3    Download large models (space permitting)"
    echo "  download models all      Download all model tiers"
    echo "  download all             Download everything (tools first, then models)"
    echo "  update                   Update tools and assets"
    echo "  monitor                  Watch active downloads"
    echo "  status                   Show what's installed"
    echo "  test                     Run validation suite"
    echo "  serve [port]             Start web UI server (default: port 3000)"
    echo "  screenshots [web|terminal]  Capture screenshots and terminal recordings"
    echo "  optimize-images          Compress and resize web UI images"
    echo "  cron install             Install weekly auto-update cron job"
    echo "  cron remove              Remove cron job"
    echo "  cron status              Show current cron entries"
    echo "  service install          Install systemd service (requires sudo)"
    echo "  service remove           Remove systemd service"
    echo "  service status           Show service status"
    echo "  uninstall                Remove Val Ark configuration"
    echo "  help                     Show this help"
    echo ""
    echo "Examples:"
    echo "  ./start.sh chat                    # Start chat with default model"
    echo "  ./start.sh chat qwen               # Start chat with Qwen model"
    echo "  ./start.sh transcribe meeting.mp3  # Transcribe audio file"
    echo "  ./start.sh image \"a sunset\"        # Generate image"
    echo "  ./start.sh speak \"Hello world\"     # Generate speech"
    echo "  ./start.sh serve 8080              # Start web UI on port 8080"
    echo ""
}

###############################################################################
# Download Submenu (interactive)
###############################################################################

download_menu() {
    echo ""
    echo -e "  ${BOLD}Download what?${NC}"
    echo ""
    echo "  1) Tools (small utilities first, then AI engines)"
    echo "  2) Models - Tier 1 (small/fast, phones & edge)"
    echo "  3) Models - Tier 2 (balanced workstation)"
    echo "  4) Models - Tier 3 (large, space permitting)"
    echo "  5) Models - All tiers"
    echo "  6) Everything (tools first, then models by tier)"
    echo ""
    echo "  0) Back"
    echo ""
    echo -n "  Enter choice [0-6]: "
    read -r choice

    case "$choice" in
        1) exec bash "${SCRIPTS}/download-tools.sh" all ;;
        2) exec bash "${SCRIPTS}/download-models.sh" tier1 ;;
        3) exec bash "${SCRIPTS}/download-models.sh" tier2 ;;
        4) exec bash "${SCRIPTS}/download-models.sh" tier3 ;;
        5) exec bash "${SCRIPTS}/download-models.sh" all ;;
        6)
            bash "${SCRIPTS}/download-tools.sh" all
            bash "${SCRIPTS}/download-models.sh" all
            ;;
        0|"") return ;;
        *) echo -e "  ${RED}Invalid choice${NC}"; download_menu ;;
    esac
}

###############################################################################
# Interactive Menu
###############################################################################

ai_menu() {
    echo ""
    echo -e "  ${BOLD}AI Tools${NC}"
    echo ""
    echo "  1) Chat        Start LLM chat server"
    echo "  2) Transcribe  Convert audio/video to text"
    echo "  3) Image       Generate image from prompt"
    echo "  4) Speak       Convert text to speech"
    echo ""
    echo "  0) Back"
    echo ""
    echo -n "  Enter choice [0-4]: "
    read -r choice

    case "$choice" in
        1)
            echo -n "  Model name (or Enter for default): "
            read -r model
            ai_chat "$model"
            ;;
        2)
            echo -n "  Audio/video file path: "
            read -r file
            ai_transcribe "$file"
            ;;
        3)
            echo -n "  Image prompt: "
            read -r prompt
            ai_image "$prompt"
            ;;
        4)
            echo -n "  Text to speak: "
            read -r text
            ai_speak "$text"
            ;;
        0|"") return ;;
        *) echo -e "  ${RED}Invalid choice${NC}"; ai_menu ;;
    esac
}

interactive_menu() {
    while true; do
        echo ""
        echo -e "${DIM}══════════════════════════════════════${NC}"
        echo -e "  ${BOLD}Val Ark${NC} - Online-Optional Tool Server"
        echo -e "${DIM}══════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${CYAN}── AI Tools ──${NC}"
        echo "  1) Chat        Start LLM chat server"
        echo "  2) Transcribe  Audio/video to text"
        echo "  3) Image       Generate from prompt"
        echo "  4) Speak       Text to speech"
        echo ""
        echo -e "  ${CYAN}── Management ──${NC}"
        echo "  5) Setup       Install dependencies"
        echo "  6) Download    Download tools & models"
        echo "  7) Update      Update everything"
        echo "  8) Status      Show what's installed"
        echo "  9) Serve       Start web UI server"
        echo "  10) More...    Monitor, test, cron, help"
        echo ""
        echo "  0) Exit"
        echo ""
        echo -n "  Enter choice [0-10]: "
        read -r choice

        case "$choice" in
            1)
                echo -n "  Model (Enter for default): "
                read -r model
                ai_chat "$model"
                ;;
            2)
                echo -n "  File path: "
                read -r file
                ai_transcribe "$file"
                ;;
            3)
                echo -n "  Prompt: "
                read -r prompt
                ai_image "$prompt"
                ;;
            4)
                echo -n "  Text: "
                read -r text
                ai_speak "$text"
                ;;
            5) exec bash "${SCRIPTS}/setup.sh" ;;
            6) download_menu ;;
            7) exec bash "${SCRIPTS}/update.sh" all ;;
            8) exec bash "${SCRIPTS}/status.sh" ;;
            9)
                local port=""
                echo -n "  Port [3000]: "
                read -r port
                port="${port:-3000}"
                local NODE="$HOME/.local/node/bin/node"
                [ ! -x "$NODE" ] && NODE=$(which node 2>/dev/null)
                if [ -z "$NODE" ]; then echo -e "  ${RED}Node.js not found${NC}"; continue; fi
                echo -e "  ${GREEN}http://localhost:${port}${NC}"
                exec "$NODE" "${SCRIPTS}/server.js" "$port"
                ;;
            10) more_menu ;;
            0|"") echo ""; exit 0 ;;
            *) echo -e "  ${RED}Invalid choice${NC}" ;;
        esac
    done
}

more_menu() {
    echo ""
    echo -e "  ${BOLD}More Options${NC}"
    echo ""
    echo "  1) Monitor     Watch active downloads"
    echo "  2) Test        Run validation suite"
    echo "  3) Cron        Manage auto-update schedule"
    echo "  4) Uninstall   Remove Val Ark configuration"
    echo "  5) Help        Show detailed CLI help"
    echo ""
    echo "  0) Back"
    echo ""
    echo -n "  Enter choice [0-5]: "
    read -r choice

    case "$choice" in
        1) exec bash "${SCRIPTS}/monitor.sh" ;;
        2) exec bash "${TESTS}/run-all.sh" ;;
        3) cron_menu ;;
        4) exec bash "${SCRIPTS}/uninstall.sh" ;;
        5) show_help ;;
        0|"") return ;;
        *) echo -e "  ${RED}Invalid choice${NC}"; more_menu ;;
    esac
}

###############################################################################
# CLI Dispatch
###############################################################################

case "${1:-}" in
    # AI Commands
    chat)
        ai_chat "${2:-}"
        ;;
    transcribe)
        ai_transcribe "${2:-}"
        ;;
    image)
        ai_image "${2:-}"
        ;;
    speak)
        ai_speak "${2:-}"
        ;;
    # Management Commands
    setup)
        exec bash "${SCRIPTS}/setup.sh"
        ;;
    download)
        case "${2:-}" in
            tools)
                exec bash "${SCRIPTS}/download-tools.sh" all
                ;;
            models)
                case "${3:-all}" in
                    tier1) exec bash "${SCRIPTS}/download-models.sh" tier1 ;;
                    tier2) exec bash "${SCRIPTS}/download-models.sh" tier2 ;;
                    tier3) exec bash "${SCRIPTS}/download-models.sh" tier3 ;;
                    all)   exec bash "${SCRIPTS}/download-models.sh" all ;;
                    *)
                        echo "Usage: $0 download models [tier1|tier2|tier3|all]"
                        exit 1
                        ;;
                esac
                ;;
            all)
                bash "${SCRIPTS}/download-tools.sh" all
                exec bash "${SCRIPTS}/download-models.sh" all
                ;;
            "")
                download_menu
                ;;
            *)
                echo "Usage: $0 download [tools|models|all]"
                exit 1
                ;;
        esac
        ;;
    update)
        exec bash "${SCRIPTS}/update.sh" "${2:-all}"
        ;;
    monitor)
        exec bash "${SCRIPTS}/monitor.sh"
        ;;
    status)
        exec bash "${SCRIPTS}/status.sh"
        ;;
    test)
        exec bash "${TESTS}/run-all.sh"
        ;;
    uninstall)
        exec bash "${SCRIPTS}/uninstall.sh"
        ;;
    cron)
        case "${2:-}" in
            install) cron_install ;;
            remove)  cron_remove ;;
            status)  cron_status ;;
            "")      cron_menu ;;
            *)
                echo "Usage: $0 cron [install|remove|status]"
                exit 1
                ;;
        esac
        ;;
    service)
        case "${2:-}" in
            install) service_install ;;
            remove)  service_remove ;;
            status)  service_status ;;
            *)
                echo "Usage: $0 service [install|remove|status]"
                exit 1
                ;;
        esac
        ;;
    screenshots)
        exec bash "${SCRIPTS}/screenshots.sh" "${2:-all}"
        ;;
    optimize-images)
        if ! python3 -c "from PIL import Image" 2>/dev/null; then
            echo -e "${RED}Pillow not installed. Run: pip3 install Pillow${NC}"
            exit 1
        fi
        python3 "${SCRIPTS}/optimize-images.py"
        ;;
    serve)
        _node="$HOME/.local/node/bin/node"
        [ ! -x "$_node" ] && _node=$(which node 2>/dev/null)
        if [ -z "$_node" ]; then echo -e "${RED}Node.js not found${NC}"; exit 1; fi
        # Port resolution MIRRORS server.js (issue #105): an explicit `serve <port>`
        # wins; with NO port arg we pass NOTHING to server.js and let it fall through
        # to VALARK_WEB_PORT (env or .env) || 3000. Passing a hardcoded 3000 here used
        # to override a custom VALARK_WEB_PORT, so `./start.sh serve` bound 3000 while
        # the bootstrap hand-off printed the .env port — a dead link. Deriving the
        # port only for the printed URL keeps that URL in agreement with the bound port.
        _srv_args=()
        if [ -n "${2:-}" ]; then
            _port="$2"
            _srv_args=("$_port")
        else
            _port="${VALARK_WEB_PORT:-}"
            if [ -z "$_port" ]; then
                _port="$(sed -n 's/^[[:space:]]*VALARK_WEB_PORT[[:space:]]*=//p' "${SCRIPT_DIR}/.env" 2>/dev/null | head -1)"
                _port="${_port//[[:space:]]/}"; _port="${_port//\"/}"; _port="${_port//\'/}"
            fi
            _port="${_port:-3000}"
        fi
        echo -e "  ${GREEN}http://localhost:${_port}${NC}"
        exec "$_node" "${SCRIPTS}/server.js" "${_srv_args[@]}"
        ;;
    port80|port-80)
        # Make this machine reachable at http://<its-ip>/  (no :3000 to remember).
        # Best path: grant the node binary permission to bind :80 (one sudo, persists);
        # fall back to an iptables 80->PORT redirect the self-healing loop maintains.
        _node="$HOME/.local/node/bin/node"; [ -x "$_node" ] || _node="$(command -v node 2>/dev/null)"
        _webport="$(sed -n 's/^VALARK_WEB_PORT=\(.*\)/\1/p' .env 2>/dev/null | tr -d '"')"; _webport="${_webport:-3000}"
        _set_env() { touch .env; if grep -qE "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }
        _done=0
        if [ -n "$_node" ] && command -v setcap >/dev/null 2>&1; then
            _rn="$(readlink -f "$_node")"
            echo -e "  Granting ${BOLD}${_rn}${NC} permission to bind port 80 (sudo, once)..."
            if sudo setcap 'cap_net_bind_service=+ep' "$_rn" 2>/dev/null; then
                _extra="$(sed -n 's/^VALARK_WEB_EXTRA_PORTS=\(.*\)/\1/p' .env 2>/dev/null | tr -d '"')"
                case ",$_extra," in *",80,"*) : ;; *) _extra="${_extra:+$_extra,}80" ;; esac
                _set_env VALARK_WEB_EXTRA_PORTS "$_extra"
                echo -e "  ${GREEN}Done.${NC} node can now bind :80. Restart the server (./start.sh serve, or the loop) and open ${BOLD}http://<this-ip>/${NC}"
                _done=1
            else
                echo -e "  ${YELLOW}setcap needed sudo/root and it wasn't granted — trying the redirect instead.${NC}"
            fi
        fi
        if [ "$_done" != 1 ]; then
            _set_env VALARK_WEB_PUBLIC_PORT 80
            echo -e "  Set ${BOLD}VALARK_WEB_PUBLIC_PORT=80${NC} — the loop maps :80 -> :${_webport} each cycle (needs passwordless sudo or root)."
            PATH="/usr/sbin:/sbin:$PATH"
            if command -v iptables >/dev/null 2>&1 && { sudo iptables -t nat -C PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports "$_webport" 2>/dev/null \
                 || sudo iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-ports "$_webport" 2>/dev/null; }; then
                echo -e "  ${GREEN}Redirect applied now.${NC} Open ${BOLD}http://<this-ip>/${NC}"
            else
                echo -e "  ${YELLOW}Could not apply the redirect right now${NC} (need sudo/root); the loop retries each cycle once VALARK_WEB_PUBLIC_PORT=80 is set."
            fi
        fi
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        interactive_menu
        ;;
    *)
        echo -e "${RED}Unknown command:${NC} $1"
        show_help
        exit 1
        ;;
esac
