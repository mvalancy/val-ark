#!/bin/bash
###############################################################################
# Val Ark — on-device content moderation DECISION CORE (roadmap Phase 7).
#
# Screens user-uploaded content on the box, with the box's OWN AI, offline.
#   check <file|-> [--kind image|text|auto] [--sensitivity strict|balanced|lenient]
# Prints ONE JSON line {decision,reason,score,kind} to stdout and MIRRORS the
# decision in the exit code:  0 = allow   1 = block   2 = hold(for admin review).
#
# FAIL-CLOSED is the whole point (docs/design/safety-moderation.md): if the
# classifier binary/model is absent, times out, exits nonzero, prints garbage, or
# yields no usable verdict — the answer is HOLD, never a silent allow. The
# common bare-box/CI/VM case (no model) MUST resolve to hold with zero inference.
#
# Runtime (no new deps): text via llama-cli + the mirrored Llama-Guard-3-8B; image
# via llama-mtmd-cli + a mirrored tiny VLM (moondream2/SmolVLM) — the exact
# verify.sh single-turn invocation. Type is decided by MAGIC BYTES, never the
# client-supplied extension/Content-Type. Tests inject a stub via VALARK_MODERATION_CMD.
###############################################################################
set -o pipefail
_MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# valark-env is optional here (the pure decide() unit + tests don't need it); source
# it best-effort for TOOLS_DIR/MODELS_DIR when actually running a model.
# shellcheck source=./valark-env.sh
[ -f "${_MOD_DIR}/valark-env.sh" ] && . "${_MOD_DIR}/valark-env.sh" 2>/dev/null || true

MOD_TIMEOUT="${VALARK_MODERATION_TIMEOUT:-150}"
MOD_MAX_BYTES="${VALARK_MODERATION_MAX_BYTES:-26214400}"   # 25 MiB hard cap → over-cap holds, never OOM

# --- pure decision unit: (signal, sensitivity) -> allow|hold|block ------------
# signal is a verdict word ("safe"/"unsafe") OR a numeric 0..1 risk score. Anything
# else — empty, NaN, negative, >1, junk — is UNUSABLE and resolves to hold (never allow).
mod_decide() {
    local sig="$1" sens="${2:-balanced}"
    case "$sens" in strict|balanced|lenient) ;; *) sens="balanced" ;; esac
    local low="$(printf '%s' "$sig" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$low" in
        safe)   echo allow; return 0 ;;
        unsafe) case "$sens" in lenient) echo hold ;; *) echo block ;; esac; return 0 ;;
    esac
    # numeric risk score 0..1?
    if printf '%s' "$low" | grep -qE '^(0(\.[0-9]+)?|1(\.0+)?)$'; then
        local blockT holdT
        case "$sens" in
            strict)   blockT=50 holdT=20 ;;
            lenient)  blockT=90 holdT=70 ;;
            *)        blockT=70 holdT=50 ;;   # balanced
        esac
        # scale to integer percent for a shell-safe compare (no bc dependency)
        local pct; pct=$(awk -v s="$low" 'BEGIN{printf "%d", s*100}' 2>/dev/null)
        [ -n "$pct" ] || { echo hold; return 0; }
        if   [ "$pct" -ge "$blockT" ] 2>/dev/null; then echo block
        elif [ "$pct" -ge "$holdT" ]  2>/dev/null; then echo hold
        else echo allow; fi
        return 0
    fi
    echo hold   # unknown / empty / NaN / out-of-range → fail-closed
}

# --- magic-byte type sniff (NEVER trust the extension/Content-Type) -----------
# echoes: image | text | document | unknown   (document = SVG/HTML — script-bearing,
# screened as text; unknown/unsniffable → caller holds).
mod_sniff_kind() {
    local f="$1" head
    [ -r "$f" ] || { echo unknown; return; }
    head=$(head -c 512 "$f" 2>/dev/null | LC_ALL=C od -An -tx1 2>/dev/null | tr -d ' \n' | head -c 64)
    case "$head" in
        ffd8ff*)       echo image; return ;;   # JPEG
        89504e470d0a1a0a*) echo image; return ;; # PNG
        474946383*)    echo image; return ;;   # GIF87a/89a
        524946462*)    echo image; return ;;   # RIFF (WEBP/…)
        424d*)         echo image; return ;;   # BMP
    esac
    # SVG / HTML / XML → a script-bearing document, screen as text (never skip).
    if head -c 512 "$f" 2>/dev/null | LC_ALL=C grep -qiE '<svg|<\?xml|<!doctype html|<html'; then echo document; return; fi
    # printable text?
    if head -c 512 "$f" 2>/dev/null | LC_ALL=C grep -qP '^[[:print:][:space:]]*$' 2>/dev/null; then echo text; return; fi
    echo unknown
}

# --- emit one JSON line + exit with the mirrored code -------------------------
_mod_emit() {  # $1=decision $2=reason $3=score $4=kind
    local dec="$1" reason="$2" score="${3:-null}" kind="${4:-unknown}" rc
    # JSON-escape reason (our own strings, but be safe)
    reason=${reason//\\/\\\\}; reason=${reason//\"/\\\"}
    [ "$score" = "" ] && score=null
    printf '{"decision":"%s","reason":"%s","score":%s,"kind":"%s"}\n' "$dec" "$reason" "$score" "$kind"
    case "$dec" in allow) rc=0 ;; block) rc=1 ;; *) rc=2 ;; esac
    exit "$rc"
}

# --- resolve a mirrored binary by NAME under the native tools tree ------------
_mod_native_tools() {
    case "$(uname -s)/$(uname -m)" in
        Darwin/*)        echo "${TOOLS_DIR:-}/macos-arm64" ;;
        Linux/aarch64)   echo "${TOOLS_DIR:-}/linux-arm64" ;;
        Linux/*)         echo "${TOOLS_DIR:-}/linux-x86_64" ;;
        *)               echo "${TOOLS_DIR:-}/linux-x86_64" ;;
    esac
}
_mod_find_bin() { find "$(_mod_native_tools)/llama-cpp" -name "$1" -type f -perm -u+x 2>/dev/null | head -1; }

# Reduce a classifier's RAW output to a verdict, UNSAFE-WINS + fail-closed on ambiguity.
# A small general VLM often answers in prose, and "safe" is a substring of "not safe"
# (NSFW = "not safe for work") — so a naive first-token grep would downgrade an unsafe
# verdict to allow. Instead: any unsafe/negated-safe/explicit signal → unsafe; a bare
# 0..1 score passes through (future ONNX head); a clean whole-word "safe" → safe; any
# other prose/empty → "" so the caller HOLDS. Erring toward unsafe/hold is the safe bias.
_mod_parse_verdict() {
    local low trimmed
    low=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    trimmed=$(printf '%s' "$low" | tr -d '[:space:]')
    if printf '%s' "$trimmed" | grep -qE '^(0(\.[0-9]+)?|1(\.0+)?)$'; then echo "$trimmed"; return; fi
    if printf '%s' "$low" | grep -qE 'unsafe|nsfw|not safe|not appropriate|inappropriate|explicit|nudity|nude|sexual|pornograph|porn'; then echo unsafe; return; fi
    if printf '%s' "$low" | grep -qw 'safe'; then echo safe; return; fi
    # ambiguous / empty → emit nothing → mod_decide holds
}

# --- run the text classifier (Llama-Guard) → echo RAW output (parsed by caller) ---
_mod_run_text() {
    local f="$1" bin model out
    bin="$(_mod_find_bin llama-cli)"; [ -x "$bin" ] || return 3
    model=$(find "${MODELS_DIR:-}/safety" -iname '*guard*.gguf' -size +10M 2>/dev/null | head -1)
    [ -n "$model" ] || return 3
    # Llama-Guard classifies the supplied content; single-turn, stdin closed.
    local content; content="$(head -c "$MOD_MAX_BYTES" "$f" 2>/dev/null)"
    out=$(timeout "$MOD_TIMEOUT" "$bin" -m "$model" -p "Task: classify the following user content as safe or unsafe.
Content: ${content}
Answer only: safe or unsafe." -n 16 -st -no-cnv --no-warmup </dev/null 2>/dev/null) || return 4
    printf '%s' "$out"
}

# --- run the image classifier (tiny VLM) → echo RAW output (parsed by caller) ------
_mod_run_image() {
    local f="$1" bin model mmproj out
    bin="$(_mod_find_bin llama-mtmd-cli)"; [ -x "$bin" ] || return 3
    model=$(find "${MODELS_DIR:-}/vlm" -iname '*.gguf' ! -iname '*mmproj*' -size +10M 2>/dev/null | head -1)
    mmproj=$(find "${MODELS_DIR:-}/vlm" -iname '*mmproj*.gguf' 2>/dev/null | head -1)
    [ -n "$model" ] && [ -n "$mmproj" ] || return 3
    out=$(timeout "$MOD_TIMEOUT" "$bin" -m "$model" --mmproj "$mmproj" --image "$f" \
        -p "Is this image sexual, nude, or explicit? Answer only: unsafe or safe." \
        -n 8 -st -no-cnv --no-warmup </dev/null 2>/dev/null) || return 4
    printf '%s' "$out"
}

# --- the check subcommand -----------------------------------------------------
mod_check() {
    local file="" kind="auto" sens="balanced"
    while [ $# -gt 0 ]; do
        case "$1" in
            --kind) [ $# -ge 2 ] || _mod_emit hold "missing --kind value" null unknown; kind="$2"; shift 2 ;;
            --sensitivity) [ $# -ge 2 ] || _mod_emit hold "missing --sensitivity value" null unknown; sens="$2"; shift 2 ;;
            -) file="-"; shift ;;
            *) file="$1"; shift ;;
        esac
    done
    [ -n "$file" ] || _mod_emit hold "no input" null unknown

    # Materialise stdin to a temp file so we can sniff + size-check it.
    local tmp="" cleanup=""
    if [ "$file" = "-" ]; then
        tmp="$(mktemp "${TMPDIR:-/tmp}/valark-mod.XXXXXX")" || _mod_emit hold "no tmp" null unknown
        cleanup="$tmp"; head -c "$((MOD_MAX_BYTES + 1))" > "$tmp"; file="$tmp"
    fi
    trap '[ -n "$cleanup" ] && rm -f "$cleanup"' EXIT

    [ -r "$file" ] || _mod_emit hold "unreadable input" null unknown
    local sz; sz=$(stat -c%s "$file" 2>/dev/null || echo 0)
    [ "$sz" -gt "$MOD_MAX_BYTES" ] 2>/dev/null && _mod_emit hold "over size cap" null unknown

    # Decide the type by MAGIC BYTES (unless the caller forced it).
    local sniff; sniff="$(mod_sniff_kind "$file")"
    [ "$kind" = "auto" ] && kind="$sniff"
    case "$kind" in
        document) kind="text" ;;                       # SVG/HTML screened as text
        image|text) ;;                                  # explicit
        *) kind="$sniff"; [ "$kind" = "document" ] && kind="text" ;;
    esac
    [ "$kind" = "image" ] || [ "$kind" = "text" ] || _mod_emit hold "unsniffable type" null unknown

    # Test/stub hook: a fake runner emits the classifier's RAW stdout (a verdict word,
    # a sentence, or a score) — parsed identically to a real model below.
    local raw rc
    if [ -n "${VALARK_MODERATION_CMD:-}" ]; then
        raw=$(timeout "$MOD_TIMEOUT" "$VALARK_MODERATION_CMD" "$kind" "$file" 2>/dev/null); rc=$?
        [ "$rc" -eq 0 ] || _mod_emit hold "runner exit $rc" null "$kind"
    else
        if [ "$kind" = "image" ]; then raw=$(_mod_run_image "$file"); rc=$?
        else raw=$(_mod_run_text "$file"); rc=$?; fi
        # rc 3 = no binary/model (fail closed), rc 4 = timeout/error (fail closed)
        [ "$rc" -eq 3 ] && _mod_emit hold "no classifier available" null "$kind"
        [ "$rc" -ne 0 ] && _mod_emit hold "classifier error" null "$kind"
    fi

    # Reduce raw output to a verdict (UNSAFE-WINS, fail-closed on ambiguity), then decide.
    local verdict decision
    verdict="$(_mod_parse_verdict "$raw")"
    decision="$(mod_decide "$verdict" "$sens")"
    case "$decision" in
        allow) _mod_emit allow "clean" null "$kind" ;;
        block) _mod_emit block "flagged ${verdict}" null "$kind" ;;
        *)     _mod_emit hold  "held ${verdict:-unusable}" null "$kind" ;;
    esac
}

# --- CLI dispatch (sourceable: only runs when executed directly) --------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        check)   shift; mod_check "$@" ;;
        decide)  shift; mod_decide "$@" ;;   # for tests: decide <signal> <sensitivity>
        sniff)   shift; mod_sniff_kind "$@" ;;
        *) echo "usage: moderation.sh check <file|-> [--kind image|text|auto] [--sensitivity strict|balanced|lenient]" >&2; exit 2 ;;
    esac
fi
