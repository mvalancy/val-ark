#!/bin/bash
###############################################################################
# Test: served packages manifest — GET /api/packages (#89 slice 1).
#
# The manifest lists what THIS box can hand out RIGHT NOW (present inventory):
# app/tool archives, the self-replication source bundle/tarball/node runtimes,
# on-disk models, and complete ZIMs — as relative URLs + metadata only. This
# exercises the assembly logic against a populated fake mirror (sizes, ids,
# versions from .version markers, sha256 from a precomputed SHA256SUMS), the
# empty-box tolerance (never a crash), and the read-gate (401 on a Passworded
# LAN). Distinct from /api/catalog/* (the upstream not-yet-downloaded feed).
###############################################################################
PASS=0; FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass() { PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
NODE="$HOME/.local/node/bin/node"; [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] || { echo "SKIP: no node runtime" >&2; exit 0; }

T="$(mktemp -d)"; SRV_PID=""; ALL_PIDS=""
trap 'for p in $ALL_PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT

# --- Build a populated fake mirror (all four package kinds) -------------------
mkdir -p "$T/tools/linux-x86_64/helix" "$T/models/llm/qwen2.5" \
         "$T/content/zim" "$T/sources/val-ark" "$T/state"
# App: a tool dir with a binary + a .version marker.
head -c 400000 /dev/zero > "$T/tools/linux-x86_64/helix/hx"
printf 'v25.01\n' > "$T/tools/linux-x86_64/helix/.version"
# Model: a multi-file dir AND a single .gguf file.
head -c 1200000 /dev/zero > "$T/models/llm/qwen2.5/model.gguf"
head -c 500000  /dev/zero > "$T/models/llm/tiny.gguf"
# Content: one complete ZIM + one still-downloading .part that must NOT be listed.
head -c 3000000 /dev/zero > "$T/content/zim/wikipedia_en_all_mini.zim"
head -c 111     /dev/zero > "$T/content/zim/incomplete.zim.part"
# In-progress app/model entries that must NEVER be advertised as ready (#89):
#  - a partial single-file model download (*.part) inside a category dir
head -c 222 /dev/zero > "$T/models/llm/downloading.gguf.part"
#  - a tool dir mid-extraction: holds only download_and_extract's .tmp_* archive temp
mkdir -p "$T/tools/linux-x86_64/half-extracted"
head -c 333 /dev/zero > "$T/tools/linux-x86_64/half-extracted/.tmp_half.tar.gz"
#  - a model dir mid-extraction (same .tmp_* discipline)
mkdir -p "$T/models/llm/half-model"
head -c 444 /dev/zero > "$T/models/llm/half-model/.tmp_half.gguf.tar.gz"
# Top-level single .gguf directly under the model root (flat layout, #89) — IS a
# package; a top-level *.gguf.part partial stays excluded by the .gguf suffix test.
head -c 800000 /dev/zero > "$T/models/toplevel.gguf"
head -c 555    /dev/zero > "$T/models/incomplete-top.gguf.part"
# Source: the self-replication bundle + tarball + a node runtime + real SHA256SUMS.
head -c 900000  /dev/zero > "$T/sources/val-ark/val-ark.bundle"
head -c 700000  /dev/zero > "$T/sources/val-ark/val-ark-latest.tar.gz"
head -c 600000  /dev/zero > "$T/sources/val-ark/node-linux-x86_64.tar.gz"
printf 'ref=1.2.3\ncommit=deadbee\n' > "$T/sources/val-ark/VERSION"
( cd "$T/sources/val-ark" && sha256sum val-ark.bundle val-ark-latest.tar.gz node-linux-x86_64.tar.gz > SHA256SUMS )
BUNDLE_SHA="$(awk '/val-ark.bundle$/{print $1}' "$T/sources/val-ark/SHA256SUMS")"

# Start the server in the PARENT shell (never in $(...) — a command-substitution
# subshell would strip $! and leak the background server), tracking its PID.
start_srv() {  # start_srv <port> <state-dir>  (mirror dirs come from TOOLS/SOURCES/MODELS/CONTENT)
    local port="$1" sd="$2"
    # Unique HTTPS port per server so the throwaway TLS listener never collides
    # with a live Ark's 8443 (or another test server) on the same box.
    # `env` (not a bare assignment prefix) so the conditional ${FORCE_REMOTE:+…}
    # expansion is parsed as a VAR=val arg at runtime — an expansion that produces
    # `VAR=val` is NOT recognized as a shell assignment prefix and would otherwise
    # be run as a command ("VALARK_TEST_FORCE_REMOTE=1: command not found").
    env VALARK_TEST_NO_SPAWN=1 VALARK_COMMISSIONED=1 VALARK_BIND=127.0.0.1 VALARK_DISABLE_KIWIX=1 \
      VALARK_WEB_PORT="$port" VALARK_HTTPS_PORT="$((port + 9000))" VALARK_STATE_DIR="$sd" \
      VALARK_TOOLS_DIR="$TOOLS" VALARK_SOURCES_DIR="$SOURCES" \
      VALARK_MODELS_DIR="$MODELS" VALARK_CONTENT_DIR="$CONTENT" \
      ${FORCE_REMOTE:+VALARK_TEST_FORCE_REMOTE=1} \
      "$NODE" "$ROOT/scripts/server.js" "$port" >"$sd/srv.log" 2>&1 &
    SRV_PID=$!; ALL_PIDS="$ALL_PIDS $SRV_PID"
}
# Poll /api/health (never read-gated) until the server answers; echoes 1/0.
wait_up() {
    local b="http://127.0.0.1:$1" up=0 i
    for i in $(seq 1 30); do sleep 0.4; curl -sf --max-time 2 "$b/api/health" >/dev/null 2>&1 && { up=1; break; }; done
    echo "$up"
}

# --- 1. Populated mirror: manifest shape + all four kinds ---------------------
TOOLS="$T/tools" SOURCES="$T/sources" MODELS="$T/models" CONTENT="$T/content"
PORT=3951; B="http://127.0.0.1:$PORT"
start_srv "$PORT" "$T/state"; [ "$(wait_up "$PORT")" = 1 ] && pass || { fail "server did not start on :$PORT"; echo "packages: ${PASS} passed, ${FAIL} failed"; exit 1; }

PK="$(curl -s --max-time 6 "$B/api/packages")"
echo "$PK" | "$NODE" -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    const j=JSON.parse(s);
    const ok = j && typeof j.generatedAt==="string" && typeof j.count==="number"
            && Array.isArray(j.packages) && j.count===j.packages.length
            && j.packages.every(p=>p.id&&p.name&&p.kind&&typeof p.size==="number"
                                 && typeof p.url==="string" && p.url.startsWith("/"));
    process.exit(ok?0:1);
  });' && pass || fail "manifest must be {generatedAt,count,packages[]} with id/name/kind/size/relative-url per row"

# Per-kind assertions (kind, size, url, version, sha256) via one node pass.
echo "$PK" | BUNDLE_SHA="$BUNDLE_SHA" "$NODE" -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    const j=JSON.parse(s); const P=j.packages;
    const by=id=>P.find(p=>p.id===id);
    const app=by("app:linux-x86_64:helix");
    const modDir=by("model:llm:qwen2.5"), modFile=by("model:llm:tiny.gguf");
    const zim=by("content:wikipedia_en_all_mini.zim");
    const bundle=by("source:val-ark.bundle"), tar=by("source:val-ark-latest.tar.gz");
    const node=by("source:node-linux-x86_64.tar.gz");
    const topModel=by("model:toplevel.gguf");
    const checks = {
      app:        app && app.kind==="app" && app.platform==="linux-x86_64" && app.version==="v25.01"
                    && app.size===400000 && app.url==="/api/archive/tools/linux-x86_64/helix",
      modelDir:   modDir && modDir.kind==="model" && modDir.size===1200000
                    && modDir.url==="/api/archive/models/llm/qwen2.5",
      modelFile:  modFile && modFile.kind==="model" && modFile.size===500000,
      zim:        zim && zim.kind==="content" && zim.size===3000000
                    && zim.url==="/api/archive/content/zim/wikipedia_en_all_mini.zim",
      // #89: a top-level single .gguf under the model root IS surfaced (flat layout).
      topLevelGguf: topModel && topModel.kind==="model" && topModel.size===800000
                    && topModel.url==="/api/archive/models/toplevel.gguf",
      noPart:     !P.some(p=>String(p.name).includes(".part")),
      // #89: no in-progress entry is advertised — no *.part row (partial single-file),
      // no .tmp_* leak, and neither mid-extraction dir (holding only a .tmp_* temp).
      noInProgress: !by("model:llm:downloading.gguf.part") && !by("model:incomplete-top.gguf.part")
                    && !by("app:linux-x86_64:half-extracted") && !by("model:llm:half-model")
                    && !P.some(p=>String(p.name).endsWith(".part") || String(p.name).includes(".tmp_")),
      bundle:     bundle && bundle.kind==="source" && bundle.version==="1.2.3"
                    && bundle.sha256===process.env.BUNDLE_SHA && bundle.url==="/sources/val-ark/val-ark.bundle",
      tarball:    tar && tar.kind==="source" && typeof tar.sha256==="string",
      nodeRt:     node && node.kind==="source" && node.platform==="linux-x86_64",
    };
    const bad = Object.entries(checks).filter(([k,v])=>!v).map(([k])=>k);
    if (bad.length) { console.error("failing checks: "+bad.join(",")); process.exit(1); }
    process.exit(0);
  });' && pass || fail "manifest rows must carry correct kind/size/url/version and sha256 (from SHA256SUMS), surface top-level .gguf, and exclude .part/in-progress entries"

# No host filesystem paths or absolute host URLs may leak into the manifest.
echo "$PK" | grep -qE '"/home/|'"$T"'|http://127|http://localhost|/tmp/' && fail "manifest must not leak filesystem paths / absolute host URLs" || pass
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 2. Bare box (empty trees): partial/empty list, never a crash ------------
mkdir -p "$T/empty/tools" "$T/empty/sources" "$T/empty/models" "$T/empty/content/zim" "$T/state2"
TOOLS="$T/empty/tools" SOURCES="$T/empty/sources" MODELS="$T/empty/models" CONTENT="$T/empty/content"
PORT=3952; B="http://127.0.0.1:$PORT"
start_srv "$PORT" "$T/state2"; [ "$(wait_up "$PORT")" = 1 ] && pass || fail "server did not start on :$PORT (empty box)"
E="$(curl -s --max-time 6 "$B/api/packages")"
echo "$E" | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.exit(j.count===0&&Array.isArray(j.packages)&&j.packages.length===0?0:1)})' \
    && pass || fail "an empty box must return {count:0,packages:[]} (never a crash)"
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

# --- 3. Read-gate: 401 for an un-authed LAN visitor on a Passworded box -------
mkdir -p "$T/s3"
"$NODE" -e 'const a=require(process.argv[1]);const d=process.argv[2];a.setPassword("packpass","admin",d);a.setUseMode("passworded",d);' \
    "$ROOT/scripts/lib/auth.js" "$T/s3"
TOOLS="$T/tools" SOURCES="$T/sources" MODELS="$T/models" CONTENT="$T/content"
PORT=3953; B="http://127.0.0.1:$PORT"; FORCE_REMOTE=1
start_srv "$PORT" "$T/s3"; [ "$(wait_up "$PORT")" = 1 ] && pass || fail "server did not start on :$PORT (passworded)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$B/api/packages")"
[ "$CODE" = "401" ] && pass || fail "/api/packages must be read-gated (401) on a Passworded LAN, got $CODE"
unset FORCE_REMOTE
kill "$SRV_PID" 2>/dev/null; SRV_PID=""

echo "packages: ${PASS} passed, ${FAIL} failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1
