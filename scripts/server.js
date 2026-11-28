#!/usr/bin/env node
// Val Ark API Server - Zero dependency Node.js server
// Serves web UI + provides status/control endpoints
//
// ── NAVIGATION (server.js section map) ───────────────────────────────────────
// Sections are delimited by `// ====` banners. Ranges are 1-based and shift when
// this header grows — re-grep `// ====` to confirm. Served surfaces: ~48 /api/…
// routes (dispatched in Request Handling) · /app/<id>/ · /kiwix/ · /sources/ ·
// /bootstrap.sh · /ca.crt.
//   L1–172     Config & bootstrap — requires, ROOT, APP_VERSION, .env, listen ports
//   L173–210   Input Validation — isAlphanumDash / isCatalogId (request-id allowlists)
//   L211–228   Status Cache — invalidateCache + status/SSE memo
//   L229–405   Download Manager — broadcastSSE + jobManager (lib/jobs.js) / startFromDesc / cancel / retry (SSE)
//   L406–626   Status Helpers (cached) — getDisk/Tools/Content/Models (/api/status/*)
//   L627–991   Packages manifest — getPackages (/api/packages) + storage/catalog helpers + getDevstack (/api/devstack)
//   L992–1756  Request Handling — auth/CORS helpers + handleAPI (~48 /api/… routes)
//   L1757–3435 Static File Serving — serveStatic / serveArchive (Range) / pipeProxy
//   L3436–3516 TLS / local-CA — cert/key, /ca.crt, serveBootstrap (/bootstrap.sh)
//   L3517–3669 Server — handleRequest router + HTTP/HTTPS listen (PORT + EXTRA_PORTS)
//   L3670–end  Kiwix Auto-Launch — scan content/zim, launch kiwix-serve, proxy /kiwix/
// ─────────────────────────────────────────────────────────────────────────────

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execSync, execFile, execFileSync, spawn, spawnSync } = require('child_process');
const { parseCatalogTSV } = require('./lib/catalog-parse');
const { createJobManager, bestReason } = require('./lib/jobs');
const { shallowDirInfo, scanToolDir, verifyToolMirror } = require('./lib/tool-scan');
const devstack = require('./lib/devstack');

const ROOT = path.resolve(__dirname, '..');

// Single source of truth for the app version — the repo-root VERSION file (bump it
// once per release). Pre-1.0: honest 0.1.x numbering, not a premature 1.x.
const APP_VERSION = (() => { try { return fs.readFileSync(path.join(ROOT, 'VERSION'), 'utf8').trim() || '0.1.7'; } catch (_) { return '0.1.7'; } })();

// --- Config: process env, then .env file, then default ----------------------
const DOTENV = (() => {
    const out = {};
    try {
        for (const line of fs.readFileSync(path.join(ROOT, '.env'), 'utf8').split('\n')) {
            if (/^\s*#/.test(line)) continue;
            const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
            if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, '');
        }
    } catch (_) { /* no .env */ }
    return out;
})();
const cfg = (k, d) => (process.env[k] !== undefined ? process.env[k]
                      : (DOTENV[k] !== undefined ? DOTENV[k] : d));

// Listen ports: primary from argv[2] / VALARK_WEB_PORT (default 3000), plus any
// VALARK_WEB_EXTRA_PORTS (comma-separated, e.g. "80" for standard HTTP) and any
// extra numeric CLI args. Privileged ports (<1024) need CAP_NET_BIND_SERVICE on
// node (setcap) or root; if a port can't bind we warn and keep the others.
const PORT = parseInt(process.argv[2] || cfg('VALARK_WEB_PORT', '3000'), 10);
const EXTRA_PORTS = [
    ...String(cfg('VALARK_WEB_EXTRA_PORTS', '')).split(','),
    ...process.argv.slice(3),
].map(s => parseInt(String(s).trim(), 10))
 .filter(p => Number.isInteger(p) && p > 0 && p !== PORT);
const ALL_PORTS = [PORT, ...new Set(EXTRA_PORTS)];

// Resolve WHERE Val Ark stores data, mirroring scripts/lib/valark-env.sh, so the
// web UI's disk stats reflect the DATA disk — not the OS/boot volume the repo
// happens to sit on. Order: $VAL_ARK_DATA -> VAL_ARK_DATA= in .env -> follow a
// data symlink onto the big disk -> repo root (single-disk/dev fallback).
function resolveDataRoot() {
    const cfgd = cfg('VAL_ARK_DATA');
    if (cfgd) return cfgd;
    for (const name of ['tools', 'models', 'content']) {
        try {
            const real = fs.realpathSync(path.join(ROOT, name));
            if (real && real !== path.join(ROOT, name)) return path.dirname(real);
        } catch (_) { /* symlink absent — try next */ }
    }
    return ROOT;
}
const DATA_ROOT = resolveDataRoot();
// Models resolve like valark-env.sh: the VALARK_MODELS_DIR override first, then
// the repo 'models' symlink (valark_ensure_layout keeps it pointing at the real
// dir under every configuration), then <DATA_ROOT>/models, then the legacy
// single-disk ~/models.
const MODEL_ROOT = (() => {
    const candidates = [cfg('VALARK_MODELS_DIR')];
    try { candidates.push(fs.realpathSync(path.join(ROOT, 'models'))); } catch (_) {}
    candidates.push(path.join(DATA_ROOT, 'models'),
                    path.join(process.env.HOME || require('os').homedir(), 'models'));
    for (const c of candidates) {
        if (!c) continue;
        try { if (fs.statSync(c).isDirectory()) return c; } catch (_) {}
    }
    return path.join(DATA_ROOT, 'models');
})();

// Admin identity store. STATE_DIR mirrors valark-env.sh: config lives under
// <VALARK_HOME>/state, physically separate from the content/model libraries.
const auth = require('./lib/auth');
const commission = require('./lib/commission');
const VALARK_HOME = process.env.VALARK_HOME || (DATA_ROOT === ROOT ? ROOT : path.join(DATA_ROOT, 'val-ark'));
const STATE_DIR = process.env.VALARK_STATE_DIR || path.join(VALARK_HOME, 'state');
// The developer stack (data/dev-stack.tsv, mirrored by lib/release_mirror.py), where
// valark-env.sh puts it: VALARK_DEVSTACK_DIR, else <VALARK_HOME>/dev-stack.
const DEVSTACK_DIR = cfg('VALARK_DEVSTACK_DIR') || path.join(VALARK_HOME, 'dev-stack');

// Grandfather existing installs: a box set up the old way (before the wizard) already
// holds mirrored tools/content/models — don't hijack a working Ark with first-boot
// setup. Only a genuinely fresh box (empty data) gets the commissioning takeover.
function _legacyActive() {
    // "Already a working Ark" = it already holds a content or model LIBRARY. (Tools
    // alone — e.g. a mirrored node runtime — don't count; a fresh box can have those
    // yet still need the wizard.) Honors the resolved dirs like valark-env, so it
    // points at the real library location (and is isolatable in tests).
    const zim = process.env.VALARK_ZIM_DIR
        || (process.env.VALARK_CONTENT_DIR ? path.join(process.env.VALARK_CONTENT_DIR, 'zim') : path.join(ROOT, 'content', 'zim'));
    for (const d of [zim, MODEL_ROOT]) {
        try { if (fs.readdirSync(d).some((n) => !n.startsWith('.'))) return true; } catch (_) {}
    }
    return false;
}
// Safe Mode: the box's config (settings.json/auth.json) is present but corrupt. It
// still boots — into a recovery-only state — rather than a dead port; content is never
// touched. Recomputed live so fixing/resetting the config exits Safe Mode with no restart.
let _smCache = { v: null, ts: 0 };
// Prior CPU/net sample for the live-metrics two-sample deltas (see getHostMetrics).
// The client's 15s Health poll spaces the samples — no sleep-between-reads on the server.
let _metricsPrev = { stat: null, net: null, ts: 0 };
function safeModeState() {
    const now = Date.now();
    if (_smCache.v && now - _smCache.ts < 3000) return _smCache.v;   // cache: it's on the read/POST hot path
    let v; try { v = commission.configHealth(STATE_DIR); } catch (_) { v = { safeMode: false, reasons: [] }; }
    _smCache = { v, ts: now };
    return v;
}
function boxCommissioned() {
    // Explicit operator/CI override: a managed deployment (or the test harness) can
    // declare the box already set up so the first-boot wizard never takes over.
    if (process.env.VALARK_COMMISSIONED === '1') return true;
    // Derived ONLY from the persisted flag — never live from _legacyActive(), so that
    // library files appearing AFTER first boot (e.g. an attacker POSTing to a download
    // endpoint) can't flip an un-owned box to "commissioned". The legacy/grandfather
    // decision is snapshotted once at startup (see below).
    return commission.isCommissioned(STATE_DIR);
}

// MIME types for static file serving
const MIME = {
    '.html': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.mp4': 'video/mp4',
    '.webm': 'video/webm',
    '.webp': 'image/webp',
    '.zim': 'application/octet-stream',
    '.gguf': 'application/octet-stream',
    '.tar': 'application/x-tar',
    '.gz': 'application/gzip',
};

// =============================================================================
// Input Validation
// =============================================================================
// Discover valid tool targets from scripts/tools/*.sh
const VALID_TOOL_TARGETS = new Set(['all']);
try {
    const toolScripts = fs.readdirSync(path.join(ROOT, 'scripts/tools'));
    for (const f of toolScripts) {
        // cad-agent-references is opt-in (a ~37 GB, day-long archive pass): run from the shell, never one click.
        if (f.endsWith('.sh') && f !== '_common.sh' && f !== 'cad-agent-references.sh') {
            VALID_TOOL_TARGETS.add(f.replace('.sh', ''));
        }
    }
    // Backward-compat aliases
    VALID_TOOL_TARGETS.add('llama');
    VALID_TOOL_TARGETS.add('whisper');
    VALID_TOOL_TARGETS.add('sd');
    VALID_TOOL_TARGETS.add('onnx');
} catch (e) {}
// Model download targets: priority tiers + per-category selectors that
// download-models.sh accepts (main models are downloaded by category, not per-file).
const VALID_MODEL_TIERS = new Set(['all', 'tier1', 'tier2', 'tier3',
    'llm', 'tts', 'stt', 'vision', 'image', 'nvidia', 'extra', 'bitnet']);
const VALID_CONTENT_TARGETS = new Set(['all', 'wikipedia', 'serve']);
// Per-item user requests routed through librarian.sh (content ZIM / model / tool).
const VALID_REQUEST_KINDS = new Set(['content', 'model', 'tool']);

function isAlphanumDash(str) {
    return typeof str === 'string' && /^[a-zA-Z0-9_-]+$/.test(str);
}
// Catalog ids carry a bucket prefix and dots (e.g. "zim:wikipedia_en_all_maxi_eng",
// "model:bge-small"). Allow those chars but nothing shell-special (defence in depth;
// ids are passed to spawn as an arg array, never through a shell).
function isCatalogId(str) {
    return typeof str === 'string' && str.length > 0 && str.length <= 256
        && /^[a-zA-Z0-9_:.-]+$/.test(str);
}

// =============================================================================
// Status Cache
// =============================================================================
const statusCache = {
    tools: { data: null, timestamp: 0 },
    content: { data: null, timestamp: 0 },
    models: { data: null, timestamp: 0 },
    disk: { data: null, timestamp: 0 },
};
const CACHE_TTL = 60000; // 60 seconds
const DISK_CACHE_TTL = 10000; // 10 seconds for disk

function invalidateCache() {
    statusCache.tools.timestamp = 0;
    statusCache.content.timestamp = 0;
    statusCache.models.timestamp = 0;
}

// =============================================================================
// Download Manager
// =============================================================================
const sseClients = new Set();

const MAX_SSE_CONNECTIONS = 50;
// One peer opening 50 EventSource streams (or a laptop that sleeps and leaves them dangling
// with no FIN) can exhaust the global pool for everyone — nothing is ever written to an idle
// SSE socket, so a dead peer is never noticed. Cap streams PER IP and heartbeat every stream
// so vanished peers get reaped and their slot freed. (Defence-in-depth on top of the global cap.)
const MAX_SSE_PER_IP = Number(process.env.VALARK_MAX_SSE_PER_IP) || 6;
const SSE_HEARTBEAT_MS = 30000;
const sseByIp = new Map();   // clientIp -> live stream count

// A directory /api/archive/<dir> spawns an on-the-fly `tar -czf -` over the whole subtree —
// CPU-bound gzip with no cap. The per-IP rate bucket can't bound this (a handful of requests,
// well under the bucket, pin every core for hours on multi-GB trees), so cap the number of
// concurrent tar spawns globally (mirrors the MAX_SSE_CONNECTIONS 503 pattern). Single-file
// downloads don't spawn tar and are unaffected — the first-class tool-download path stays open.
const MAX_ARCHIVE_TAR = Number(process.env.VALARK_MAX_ARCHIVE_TAR) || 3;
let archiveTarInFlight = 0;
// One client may not hold every slot: it gets at most MAX_ARCHIVE_TAR - 1 (never under 1).
const MAX_ARCHIVE_TAR_PER_IP = Number(process.env.VALARK_MAX_ARCHIVE_TAR_PER_IP) || Math.max(1, MAX_ARCHIVE_TAR - 1);
const archiveTarByIp = new Map();   // clientIp -> directory tar streams running

function broadcastSSE(event, data) {
    const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of sseClients) {
        try { res.write(msg); } catch (e) { sseClients.delete(res); }
    }
}

// Keepalive comment (ignored by EventSource) — provokes a write on otherwise-idle streams so a
// dead peer surfaces as a socket 'close' and gets reaped, freeing its global + per-IP slot.
setInterval(() => {
    for (const res of sseClients) { try { res.write(': ping\n\n'); } catch (_) { try { res.destroy(); } catch (_) {} } }
}, SSE_HEARTBEAT_MS).unref();

// Job manager (scripts/lib/jobs.js): honest, re-syncable download/mirror jobs — real byte
// progress, a reason for every failure, a no-progress watchdog, post-mirror verification,
// restart recovery. See that file's header for the state contract the web UI relies on.
const DOWNLOAD_ALIASES = { llama: 'llama-cpp', whisper: 'whisper-cpp', sd: 'sd-cpp', onnx: 'onnxruntime' };
const jobManager = createJobManager({
    root: ROOT,
    stateDir: STATE_DIR,
    broadcast: broadcastSSE,
    stallMs: (Number(process.env.VALARK_JOB_STALL_SEC) || 900) * 1000,
    pollMs: Number(process.env.VALARK_JOB_POLL_MS) || 1000,
    env: process.env.VALARK_TEST_PATH_PREPEND
        ? { ...process.env, PATH: process.env.VALARK_TEST_PATH_PREPEND + ':/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || '') }
        : { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || '') },
    checkDisk: () => {
        const disk = getDiskStatus();
        return disk.available < 1024 * 1024 * 1024 ? 'Insufficient disk space (less than 1 GB free)' : null;
    },
    onFinish: () => invalidateCache(),
});

// Post-mirror verification for one tool: what is REALLY on disk per platform (wrapper-aware
// scan) + archive integrity. A job that exited 0 but mirrored nothing is a failure, not a
// success; platforms without an upstream asset are surfaced as warnings with the script's
// own reason (e.g. "No linux-arm64 asset found for ...").
const formatMB = (b) => b >= 1073741824 ? (b / 1073741824).toFixed(2) + ' GB' : (b / 1048576).toFixed(1) + ' MB';
const NO_PLATFORM_FILES = 'no files were mirrored for this platform';
function makeToolVerifier(target) {
    const name = DOWNLOAD_ALIASES[target] || target;
    return async (job) => {
        const toolsDir = path.join(ROOT, 'tools');
        const platforms = await verifyToolMirror(toolsDir, name);
        const have = platforms.filter(p => ['mirrored', 'source', 'hint'].includes(p.state));
        const bad = platforms.filter(p => p.verified === false);
        const PLAT_RE = {
            'linux-arm64': /linux[-_ ]?(arm64|aarch64)|aarch64[-_ ]?(unknown[-_ ])?linux|arm64[-_ ]?linux/i,
            'linux-x86_64': /linux[-_ ]?(x86[_-]?64|amd64|x64)|x86_64[-_ ]?(unknown[-_ ])?linux/i,
            'macos-arm64': /macos|darwin|osx|apple/i,
            'windows-x64': /windows|win64|win-x64|\.exe/i,
        };
        const reasonFor = (plat) => {
            const re = PLAT_RE[plat.platform];
            const hit = re && [...job.errors, ...job.warnings].reverse().find(l => re.test(l));
            return hit ? hit.replace(/^(WARN|ERROR|ERR):?\s*/i, '') : NO_PLATFORM_FILES;
        };
        const missing = platforms.filter(p => ['empty', 'absent'].includes(p.state));
        const alreadyHad = !!job.sawAlready && !job.sawFresh;
        const out = { tool: name, platforms, mirrored: have.length, verified: have.length > 0 && bad.length === 0 && have.every(p => p.verified !== false),
                      alreadyMirrored: alreadyHad && have.length > 0 };
        if (have.length === 0) {
            return { ...out, ok: false, error: `Finished, but nothing was mirrored for ${name}. ` + (bestReason(job.errors, job.warnings) || 'The source returned no usable files.') + (job.errors.length > 1 ? ` (+${job.errors.length - 1} more error${job.errors.length > 2 ? 's' : ''} in the log below)` : '') };
        }
        if (bad.length) {
            return { ...out, ok: false, error: `Verification failed for ${bad.map(p => p.platform + ' (' + (p.detail || 'corrupt') + ')').join(', ')}. Retry re-downloads it.` };
        }
        // An 'empty' dir is a failed platform; an 'absent' one is only worth a warning if the
        // script itself said something about it (e.g. "no linux-arm64 asset published").
        const warnings = missing.map(p => {
            const r = reasonFor(p);
            return (p.state === 'absent' && r === NO_PLATFORM_FILES) ? null : `${p.platform}: ${r}`;
        }).filter(Boolean);
        // Real bytes on disk (incl. the kept upstream archive copies under .dist/), measured with
        // du — the scan's own size only counts what it visited and would understate.
        const real = have.filter(p => p.state !== 'hint');
        let sz = 0;
        for (const p of real) { p.diskBytes = await duAsync(path.join(toolsDir, p.platform, name)); sz += p.diskBytes; }
        const hintOnly = have.filter(p => p.state === 'hint').map(p => p.platform);
        const summary = (out.alreadyMirrored ? 'Already mirrored — nothing new to download. ' : (real.length ? 'Mirrored ' : 'Install guide only for ')) +
            (real.length ? real.map(p => p.platform).join(', ') : hintOnly.join(', ')) +
            (real.length ? ` (${formatMB(sz)} on disk)` : '') +
            (real.length ? (out.verified ? ', verified' : ', size-checked') : '') +
            (real.length && hintOnly.length ? `; install guide only for ${hintOnly.join(', ')}` : '');
        return { ...out, ok: true, warnings, summary };
    };
}

// Start a job from a small, JSON-serialisable descriptor — the same path serves the
// POST endpoints AND "Retry" (the descriptor is stored on the job), so a retry restarts
// EXACTLY what failed, not a guessed "all".
function startFromDesc(desc) {
    switch (desc.kind) {
        case 'tools': {
            const target = desc.target || 'all';
            if (!isAlphanumDash(target) || !VALID_TOOL_TARGETS.has(target)) {
                return { error: 'Invalid target. Use: ' + [...VALID_TOOL_TARGETS].slice(0, 5).join(', ') + '...' };
            }
            return jobManager.start({ type: 'tools', target, desc, label: target === 'all' ? 'Mirror all tools' : `Mirror ${target}`,
                script: path.join(ROOT, 'scripts/download-tools.sh'), args: [target],
                verify: target === 'all' ? null : makeToolVerifier(target) });
        }
        case 'models': {
            const tier = desc.target || 'all';
            if (!VALID_MODEL_TIERS.has(tier)) return { error: 'Invalid tier. Use: all, tier1, tier2, tier3' };
            return jobManager.start({ type: 'models', target: tier, desc, label: `Mirror models (${tier})`,
                script: path.join(ROOT, 'scripts/download-models.sh'), args: [tier] });
        }
        case 'content': {
            const target = desc.target || 'all';
            if (!isAlphanumDash(target) && !VALID_CONTENT_TARGETS.has(target)) return { error: 'Invalid content target' };
            if (target === 'serve') return { error: '"serve" starts the Kiwix server, it is not a download target' };
            return jobManager.start({ type: 'content', target, desc, label: `Mirror library content (${target})`,
                script: path.join(ROOT, 'scripts/download-zims.sh'), args: [target] });
        }
        case 'update': {
            const target = desc.target || 'all';
            if (!isAlphanumDash(target)) return { error: 'Invalid update target' };
            return jobManager.start({ type: 'update', target, desc, label: 'Update',
                script: path.join(ROOT, 'scripts/update.sh'), args: [target] });
        }
        case 'request': {
            const { rkind, target } = desc;
            if (!VALID_REQUEST_KINDS.has(rkind)) return { error: 'Invalid kind. Use: content, model, tool' };
            if (rkind === 'tool') {
                if (!isAlphanumDash(target) || !VALID_TOOL_TARGETS.has(target)) return { error: 'Unknown tool: ' + String(target).slice(0, 40) };
            } else if (!isCatalogId(target)) return { error: 'Invalid item id' };
            return jobManager.start({ type: 'request', target: `${rkind}:${target}`, desc, label: `Request ${rkind} ${String(target).replace(/^(model|zim|content|inst|tool):/, '')}`,
                script: path.join(ROOT, 'scripts/librarian.sh'), args: ['request', rkind, target],
                verify: rkind === 'tool' ? makeToolVerifier(target) : null });
        }
    }
    return { error: 'Unknown download kind' };
}

function cancelDownload(id) {
    if (!id || typeof id !== 'string' || !/^\d+$/.test(id)) return { error: 'Invalid download ID' };
    return jobManager.cancel(id);
}
function retryDownload(id) {
    if (!id || typeof id !== 'string' || !/^\d+$/.test(id)) return { error: 'Invalid download ID' };
    const j = jobManager.get(id);
    if (!j) return { error: 'Download not found' };
    if (!j.desc) return { error: 'This job cannot be retried (no record of what it was).' };
    if (!['failed', 'cancelled', 'deferred'].includes(j.status)) return { error: 'Only a failed, cancelled or deferred job can be retried' };
    return startFromDesc(j.desc);
}
function dismissDownload(id) {
    if (!id || typeof id !== 'string' || !/^\d+$/.test(id)) return { error: 'Invalid download ID' };
    return jobManager.dismiss(id);
}

// =============================================================================
// Status Helpers (with caching)
// =============================================================================
function getDiskStatus() {
    const now = Date.now();
    if (statusCache.disk.data && (now - statusCache.disk.timestamp) < DISK_CACHE_TTL) {
        return statusCache.disk.data;
    }
    try {
        // Measure the DATA disk (where tools/models/content live), not the repo.
        let target = ROOT;
        try { if (fs.statSync(DATA_ROOT).isDirectory()) target = DATA_ROOT; } catch (_) {}
        const output = execSync('/usr/bin/df -B1 --output=size,used,avail .', {
            cwd: target, encoding: 'utf8', timeout: 5000,
        });
        const lines = output.trim().split('\n');
        const parts = lines[1].trim().split(/\s+/);
        const result = {
            total: parseInt(parts[0], 10),
            used: parseInt(parts[1], 10),
            available: parseInt(parts[2], 10),
        };
        statusCache.disk = { data: result, timestamp: now };
        return result;
    } catch (e) {
        return { total: 0, used: 0, available: 0, error: e.message };
    }
}

function getToolsStatus() {
    const now = Date.now();
    if (statusCache.tools.data && (now - statusCache.tools.timestamp) < CACHE_TTL) {
        return statusCache.tools.data;
    }

    const tools = {};
    const toolsDir = path.join(ROOT, 'tools');
    if (!fs.existsSync(toolsDir)) {
        statusCache.tools = { data: tools, timestamp: now };
        return tools;
    }

    const platforms = readdirSafe(toolsDir).filter(f => {
        if (f.startsWith('.')) return false;
        try { return fs.statSync(path.join(toolsDir, f)).isDirectory(); }
        catch { return false; }
    });

    for (const platform of platforms) {
        const platDir = path.join(toolsDir, platform);
        const entries = readdirSafe(platDir).filter(e => !e.startsWith('.'));
        for (const entry of entries) {
            const fullPath = path.join(platDir, entry);
            try {
                const stat = fs.statSync(fullPath);
                if (!tools[entry]) tools[entry] = {};
                if (stat.isDirectory()) {
                    // Shallow scan: only stat top-level dir, don't recurse 45k files
                    const dirInfo = scanToolDir(fullPath);
                    tools[entry][platform] = dirInfo;
                } else {
                    tools[entry][platform] = {
                        size: stat.size,
                        lastModified: stat.mtime.toISOString(),
                    };
                }
            } catch (e) {}
        }
    }

    // Check sources
    const sourcesDir = path.join(ROOT, 'sources');
    if (fs.existsSync(sourcesDir)) {
        const sources = readdirSafe(sourcesDir).filter(f => {
            try { return fs.statSync(path.join(sourcesDir, f)).isDirectory(); }
            catch { return false; }
        });
        for (const src of sources) {
            const key = src.replace(/\.cpp$/, '-cpp').replace(/\./, '-');
            if (!tools[key]) tools[key] = {};
            try {
                const stat = fs.statSync(path.join(sourcesDir, src));
                tools[key]['source'] = { lastModified: stat.mtime.toISOString() };
            } catch (e) {}
        }
    }

    statusCache.tools = { data: tools, timestamp: now };
    return tools;
}

// An out-of-tree VALARK_LASTBOOK_DIR is listed by what lastbook_mirror.py RECORDED there, never by
// walking it (R2): if the variable is misconfigured (say to $HOME) an unauthenticated
// /api/status/content must not enumerate the operator's files. Only recorded keys shaped like
// Lastbook's own sections (packs|maps|addresses|models/<name>, app/<version>/<name>) that are regular
// files with no symlink anywhere on the way are reported; no stamps file -> nothing.
const LASTBOOK_KEY = /^(?:(?:packs|maps|addresses|models)|app\/[0-9]{1,6}(?:\.[0-9A-Za-z]{1,20}){1,5})\/[A-Za-z0-9][A-Za-z0-9._+-]{0,200}$/;
function lastbookExternalFiles(realLb) {
    const out = {};
    let stamps;
    try {
        const sf = path.join(realLb, '.lastbook-verified.json');
        const st = fs.lstatSync(sf);
        if (!st.isFile() || st.size > 8 * 1024 * 1024) return out;
        stamps = JSON.parse(fs.readFileSync(sf, 'utf8'));
    } catch (_) { return out; }
    if (!stamps || typeof stamps !== 'object' || Array.isArray(stamps)) return out;
    for (const k of Object.keys(stamps).slice(0, 5000)) {
        if (!LASTBOOK_KEY.test(k) || k.includes('..') || k.endsWith('.part')) continue;
        let p = realLb, st = null;
        try {
            for (const part of k.split('/')) {
                p = path.join(p, part);
                st = fs.lstatSync(p);
                if (st.isSymbolicLink()) { st = null; break; }
            }
        } catch (_) { st = null; }
        if (!st || !st.isFile()) continue;
        out['lastbook/' + k] = { size: st.size, lastModified: st.mtime.toISOString(), external: true };
    }
    return out;
}

function getContentStatus() {
    const now = Date.now();
    if (statusCache.content.data && (now - statusCache.content.timestamp) < CACHE_TTL) {
        return statusCache.content.data;
    }

    const content = {};
    const contentDir = path.join(ROOT, 'content');

    const walk = (dir, prefix) => {
        for (const entry of readdirSafe(dir)) {
            const fullPath = path.join(dir, entry);
            const rel = prefix ? `${prefix}/${entry}` : entry;
            try {
                const stat = fs.statSync(fullPath);
                if (stat.isDirectory()) {
                    walk(fullPath, rel);
                } else {
                    content[rel] = {
                        size: stat.size,
                        lastModified: stat.mtime.toISOString(),
                    };
                }
            } catch (e) {}
        }
    };
    if (fs.existsSync(contentDir)) walk(contentDir, '');
    // Lastbook may live outside content/ (VALARK_LASTBOOK_DIR on another disk). Report it under the
    // same lastbook/ prefix so its Library card is honest, flagged `external`: it is NOT served from
    // here (/api/archive is confined to the served trees), so the UI offers no download links for it.
    const lbDir = cfg('VALARK_LASTBOOK_DIR', '');
    if (lbDir) {
        try {
            const realLb = fs.realpathSync(lbDir);
            let realContent = '';
            try { realContent = fs.realpathSync(contentDir); } catch (_) {}
            if (!realContent || (realLb !== realContent && !realLb.startsWith(realContent + path.sep))) {
                Object.assign(content, lastbookExternalFiles(realLb));
            }
        } catch (_) { /* not there yet */ }
    }
    statusCache.content = { data: content, timestamp: now };
    return content;
}

function getModelsStatus() {
    const now = Date.now();
    if (statusCache.models.data && (now - statusCache.models.timestamp) < CACHE_TTL) {
        return statusCache.models.data;
    }

    const models = {};
    if (!fs.existsSync(MODEL_ROOT)) {
        statusCache.models = { data: models, timestamp: now };
        return models;
    }

    // Scan top-level categories: llm/, stt/, tts/, image-gen/, vlm/
    const categories = readdirSafe(MODEL_ROOT).filter(f => {
        if (f.startsWith('.') || f === 'logs' || f === 'tools') return false;
        try { return fs.statSync(path.join(MODEL_ROOT, f)).isDirectory(); }
        catch { return false; }
    });

    for (const category of categories) {
        const catDir = path.join(MODEL_ROOT, category);
        models[category] = {};
        const entries = readdirSafe(catDir);
        for (const entry of entries) {
            const fullPath = path.join(catDir, entry);
            try {
                const stat = fs.statSync(fullPath);
                if (stat.isDirectory()) {
                    models[category][entry] = shallowDirInfo(fullPath);
                } else if (stat.isFile()) {
                    models[category][entry] = {
                        size: stat.size,
                        lastModified: stat.mtime.toISOString(),
                    };
                }
            } catch (e) {}
        }
    }

    // Also check top-level .gguf files in MODEL_ROOT
    const topFiles = readdirSafe(MODEL_ROOT).filter(f => f.endsWith('.gguf'));
    for (const f of topFiles) {
        try {
            const stat = fs.statSync(path.join(MODEL_ROOT, f));
            if (!models['_top']) models['_top'] = {};
            models['_top'][f] = { size: stat.size, lastModified: stat.mtime.toISOString() };
        } catch (e) {}
    }

    statusCache.models = { data: models, timestamp: now };
    return models;
}

// =============================================================================
// Packages manifest — what THIS box can hand out RIGHT NOW
// =============================================================================
// A consolidated, machine- + human-readable inventory of the downloadable
// packages actually present on disk: the per-platform app/tool archives (served
// as on-the-fly tarballs via /api/archive/tools/…), the offline self-replication
// source bundle + tarball + per-platform Node runtimes under /sources/val-ark/,
// the on-disk AI models, and the complete local ZIMs.
//
// This is DISTINCT from /api/catalog/* — that is the UPSTREAM browse feed of
// NOT-yet-downloaded items; this is the PRESENT inventory the box can serve now.
//
// Constraints (prime directives):
//  - Zero-dep, offline, never throws: an empty/missing tree yields {packages:[]}.
//  - Fast + non-blocking: NO recursive du and NO file hashing on the request path.
//    Single-file packages report their exact stat size; directory packages (tool
//    and multi-file model trees) report a cheap shallow (immediate-children) size.
//    sha256 is attached ONLY from a precomputed SHA256SUMS (written at mirror time
//    by scripts/mirror-self.sh) — multi-GB files are never hashed here.
//  - Public-repo safe: relative URLs + package metadata only, never an absolute
//    host URL or a host filesystem path (the box is LAN/tailnet-only). The URLs
//    resolve through the same read-gate as the manifest itself.
let _packagesCache = { data: null, ts: 0 };
const PACKAGES_TTL = 60000; // 60s — matches statusCache; the on-disk inventory moves slowly

// Enumeration roots, resolved like the rest of the server (env override → repo
// symlink). The emitted URLs are always repo-relative (/api/archive/… or
// /sources/…), which on a Val Ark box resolve to these same bytes via the layout
// symlinks that serveArchive/the static router serve from.
function _pkgToolsDir()   { return cfg('VALARK_TOOLS_DIR')   || path.join(ROOT, 'tools'); }
function _pkgSourcesDir() { return cfg('VALARK_SOURCES_DIR') || path.join(ROOT, 'sources'); }
function _pkgZimDir() {
    return process.env.VALARK_ZIM_DIR
        || (process.env.VALARK_CONTENT_DIR ? path.join(process.env.VALARK_CONTENT_DIR, 'zim')
            : path.join(ROOT, 'content', 'zim'));
}

// Sum of immediate-child file sizes — a cheap, bounded, non-recursive size for a
// directory package (never walks the whole tree over the FUSE mount).
function _shallowSize(dir) {
    let size = 0;
    for (const e of readdirSafe(dir)) {
        if (e.startsWith('.')) continue;   // skip metadata markers (.version, .dist, …)
        try { const s = fs.statSync(path.join(dir, e)); if (s.isFile()) size += s.size; } catch (_) {}
    }
    return size;
}

// Parse a `sha256sum`-style SHA256SUMS file into { basename: hash }. Cheap (a few
// short lines). Missing/garbage → {} (sha256 is simply omitted from those rows).
function _parseSha256Sums(file) {
    const out = {};
    let txt;
    try { txt = fs.readFileSync(file, 'utf8'); } catch (_) { return out; }
    for (const line of txt.split('\n')) {
        const m = line.match(/^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$/);
        if (m) out[path.basename(m[2])] = m[1].toLowerCase();
    }
    return out;
}

// A tool's mirrored version from its .version marker (see _common.sh version_stamp).
// Absent/unreadable → null. Never throws.
function _versionMarker(dir) {
    try { return (fs.readFileSync(path.join(dir, '.version'), 'utf8').trim() || null); }
    catch (_) { return null; }
}

// Is this tools/models entry still IN FLIGHT — i.e. NOT a ready package? True for a
// partial single-file download (`*.part`, e.g. a half-fetched .gguf) or a directory
// still mid-extraction: one holding a `.tmp_*` archive temp, which
// _common.sh's download_and_extract writes into the dest dir and removes only on a
// successful extract. Mirrors that helper's own "already extracted" check and the
// ZIM enum's `.part` skip, so a not-yet-ready tree is never advertised as ready.
function _pkgInProgress(name, full, isDir) {
    if (name.endsWith('.part')) return true;
    if (isDir) {
        for (const c of readdirSafe(full)) if (c.startsWith('.tmp_')) return true;
    }
    return false;
}

function computePackages() {
    const packages = [];

    // 1) Apps/tools: tools/<platform>/<entry> — each a separately downloadable
    //    archive at /api/archive/tools/<platform>/<entry> (dirs stream as .tar.gz).
    const toolsDir = _pkgToolsDir();
    for (const platform of readdirSafe(toolsDir)) {
        if (platform.startsWith('.')) continue;
        const platDir = path.join(toolsDir, platform);
        let pstat; try { pstat = fs.statSync(platDir); } catch (_) { continue; }
        if (!pstat.isDirectory()) continue;
        if (realpathWithin(platDir, toolsDir) === null) continue;   // #101: no escape via a platform symlink
        for (const entry of readdirSafe(platDir)) {
            if (entry.startsWith('.')) continue;
            const full = path.join(platDir, entry);
            if (realpathWithin(full, toolsDir) === null) continue;  // #101: skip in-tree symlinks that escape ROOT
            let st; try { st = fs.statSync(full); } catch (_) { continue; }
            const isDir = st.isDirectory();
            if (_pkgInProgress(entry, full, isDir)) continue;       // #89: not a ready package (.part / mid-extraction)
            // Wrapper-aware size (piper/piper/..., onnxruntime-linux-x64-1.2x/...: the shallow sum read 0 B)
            // and no "package" for a platform that only holds an INSTALL.txt guide (not a downloadable app).
            const scan = isDir ? scanToolDir(full) : null;
            if (scan && scan.contentType === 'hint') continue;
            packages.push({
                id: `app:${platform}:${entry}`,
                name: entry,
                kind: 'app',
                platform,
                version: isDir ? _versionMarker(full) : null,
                size: isDir ? ((scan.scanned === 'wrapped' && scan.size) ? scan.size : _shallowSize(full)) : st.size,
                desc: `App for ${platform}`,
                url: `/api/archive/tools/${encodeURIComponent(platform)}/${encodeURIComponent(entry)}`,
            });
        }
    }

    // 2) Offline self-replication: the source bundle + tarball + per-platform Node
    //    runtimes served straight from /sources/val-ark/. Version comes from the
    //    mirror's VERSION metadata (falls back to the box app version); sha256 from
    //    a precomputed SHA256SUMS when present (never hashed on the request path).
    const vaDir = path.join(_pkgSourcesDir(), 'val-ark');
    const sums = _parseSha256Sums(path.join(vaDir, 'SHA256SUMS'));
    let mirrorRef = null;
    try {
        const meta = fs.readFileSync(path.join(vaDir, 'VERSION'), 'utf8');
        const m = meta.match(/^ref=(.+)$/m);
        if (m) mirrorRef = m[1].trim();
    } catch (_) { /* no mirror metadata yet */ }
    const srcVersion = mirrorRef || APP_VERSION;
    const pushSource = (file, name, platform, desc) => {
        const full = path.join(vaDir, file);
        if (realpathWithin(full, vaDir) === null) return;   // #101: skip a symlink escaping the source dir
        let st; try { st = fs.statSync(full); } catch (_) { return; }
        if (!st.isFile()) return;
        const pkg = {
            id: `source:${file}`, name, kind: 'source', platform,
            version: srcVersion, size: st.size, desc,
            url: `/sources/val-ark/${encodeURIComponent(file)}`,
        };
        if (sums[file]) pkg.sha256 = sums[file];
        packages.push(pkg);
    };
    pushSource('val-ark.bundle',        'Val Ark source (git bundle)', null, 'Full-history git bundle — clone it offline');
    pushSource('val-ark-latest.tar.gz', 'Val Ark source (tarball)',    null, 'Working-tree tarball — extract & set up, no git');
    // node-<platform>.tar.gz runtimes — what makes the offline clone actually run.
    for (const f of readdirSafe(vaDir)) {
        const m = /^node-(.+)\.tar\.gz$/.exec(f);
        if (m) pushSource(f, `Node.js runtime (${m[1]})`, m[1], 'Bundled Node runtime for the offline installer');
    }

    // 3) On-disk AI models: models/<category>/<name> (dirs or single .gguf files),
    //    served at /api/archive/models/<category>/<name>.
    for (const category of readdirSafe(MODEL_ROOT)) {
        if (category.startsWith('.') || category === 'logs' || category === 'tools') continue;
        const catDir = path.join(MODEL_ROOT, category);
        let cstat; try { cstat = fs.statSync(catDir); } catch (_) { continue; }
        if (!cstat.isDirectory()) continue;
        if (realpathWithin(catDir, MODEL_ROOT) === null) continue;   // #101: no escape via a category symlink
        for (const entry of readdirSafe(catDir)) {
            if (entry.startsWith('.')) continue;
            const full = path.join(catDir, entry);
            if (realpathWithin(full, MODEL_ROOT) === null) continue; // #101: skip in-tree symlinks that escape ROOT
            let st; try { st = fs.statSync(full); } catch (_) { continue; }
            const isDir = st.isDirectory();
            if (_pkgInProgress(entry, full, isDir)) continue;        // #89: not a ready package (.part / mid-extraction)
            packages.push({
                id: `model:${category}:${entry}`,
                name: entry,
                kind: 'model',
                platform: null,
                version: null,
                size: isDir ? _shallowSize(full) : st.size,
                desc: `AI model (${category})`,
                url: `/api/archive/models/${encodeURIComponent(category)}/${encodeURIComponent(entry)}`,
            });
        }
    }

    // 3b) Top-level single .gguf files directly under the model root — the flat
    //     layout getModelsStatus also supports (models/<name>.gguf, no category dir),
    //     served at /api/archive/models/<name>. A `*.gguf.part` in flight fails the
    //     .gguf suffix test, so partials are excluded exactly like the ZIM enum.
    for (const entry of readdirSafe(MODEL_ROOT)) {
        if (entry.startsWith('.') || !entry.endsWith('.gguf')) continue;
        const full = path.join(MODEL_ROOT, entry);
        if (realpathWithin(full, MODEL_ROOT) === null) continue; // #101: skip a symlink escaping the model root
        let st; try { st = fs.statSync(full); } catch (_) { continue; }
        if (!st.isFile()) continue;
        packages.push({
            id: `model:${entry}`,
            name: entry,
            kind: 'model',
            platform: null,
            version: null,
            size: st.size,
            desc: 'AI model',
            url: `/api/archive/models/${encodeURIComponent(entry)}`,
        });
    }

    // 4) Complete local ZIMs: content/zim/*.zim (a bare `.zim`, not a `.part`),
    //    served at /api/archive/content/zim/<file> (readable in-shell via Kiwix).
    const zimDir = _pkgZimDir();
    for (const f of readdirSafe(zimDir)) {
        if (f.startsWith('.') || !f.endsWith('.zim')) continue;
        const full = path.join(zimDir, f);
        if (realpathWithin(full, zimDir) === null) continue;   // #101: skip a symlink escaping the zim dir
        let st; try { st = fs.statSync(full); } catch (_) { continue; }
        if (!st.isFile()) continue;
        packages.push({
            id: `content:${f}`,
            name: f,
            kind: 'content',
            platform: null,
            version: null,
            size: st.size,
            desc: 'Offline library (ZIM)',
            url: `/api/archive/content/zim/${encodeURIComponent(f)}`,
        });
    }

    // Stable ordering: by kind, then name.
    const KIND_ORDER = { app: 0, model: 1, content: 2, source: 3 };
    packages.sort((a, b) =>
        ((KIND_ORDER[a.kind] ?? 9) - (KIND_ORDER[b.kind] ?? 9)) || String(a.name).localeCompare(String(b.name)));

    return { generatedAt: new Date().toISOString(), version: APP_VERSION, count: packages.length, packages };
}

// Cached manifest (60s). Never throws → an empty inventory on any error.
function getPackages() {
    const now = Date.now();
    if (_packagesCache.data && (now - _packagesCache.ts) < PACKAGES_TTL) return _packagesCache.data;
    let data;
    try { data = computePackages(); }
    catch (_) { data = { generatedAt: new Date().toISOString(), version: APP_VERSION, count: 0, packages: [] }; }
    _packagesCache = { data, ts: now };
    return data;
}

// Total bytes under a directory tree, ASYNC so a multi-hundred-GB walk never
// blocks the single-threaded event loop (a synchronous du here would freeze the
// whole web server for every client while it ran). `du -sb` is native/fast; no
// shell. The repo trees (content/, tools/, …) are SYMLINKS onto the data disk
// and du measures a symlink as ~0 bytes, so resolve to the real target first.
function duAsync(dir) {
    return new Promise((resolve) => {
        let real;
        try { if (!fs.existsSync(dir)) return resolve(0); real = fs.realpathSync(dir); }
        catch { return resolve(0); }
        execFile('du', ['-sb', real], { timeout: 120000, maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => {
            if (err) return resolve(0);
            resolve(parseInt(String(stdout).trim().split(/\s+/)[0], 10) || 0);
        });
    });
}

// Live storage breakdown across every Val Ark tree — so the UI shows the ZIM
// library (usually the biggest slice) instead of a hardcoded models-only guess.
// Computed in the background and cached; requests get the cached value instantly
// and never wait on (or block during) the walk.
let _storageCache = { data: null, timestamp: 0 };
let _storageComputing = null;
const STORAGE_CACHE_TTL = 1800000; // 30 min — the tools tree (~45k files) is slow to du over FUSE; storage moves slowly, so re-walk rarely
async function computeStorage() {
    const defs = [
        { key: 'zim',        label: 'Wikipedia & ZIM Content', color: '#4da6ff', dir: path.join(ROOT, 'content') },
        { key: 'models',     label: 'AI Models',               color: '#a78bfa', dir: MODEL_ROOT },
        { key: 'tools',      label: 'Software & Tools',        color: '#4ade80', dir: path.join(ROOT, 'tools') },
        { key: 'installers', label: 'OS Installers',           color: '#fbbf24', dir: path.join(ROOT, 'installers') },
        { key: 'sources',    label: 'Source Code',             color: '#f472b6', dir: path.join(ROOT, 'sources') },
        { key: 'devstack',   label: 'Developer Stack',         color: '#22d3ee', dir: DEVSTACK_DIR },
    ];
    const categories = [];
    for (const d of defs) {
        const bytes = await duAsync(d.dir);     // one at a time: kind to the FUSE mount
        if (bytes > 0) categories.push({ key: d.key, label: d.label, color: d.color, bytes });
    }
    const zimCount = readdirSafe(path.join(ROOT, 'content', 'zim')).filter(f => f.endsWith('.zim')).length;
    const total = categories.reduce((s, c) => s + c.bytes, 0);
    const data = { categories, total, zimCount, disk: getDiskStatus() };
    _storageCache = { data, timestamp: Date.now() };
    return data;
}
function getStorageStatus() {
    const now = Date.now();
    const fresh = _storageCache.data && (now - _storageCache.timestamp) < STORAGE_CACHE_TTL;
    if (!fresh && !_storageComputing) {
        _storageComputing = computeStorage().catch(() => null).finally(() => { _storageComputing = null; });
    }
    // Never block a request on the walk: serve cached data if we have it, else a
    // lightweight "computing" placeholder (the UI shows its static estimate until
    // real numbers land, then refines).
    return _storageCache.data || { categories: [], total: 0, zimCount: 0, disk: getDiskStatus(), computing: true };
}

// The developer stack for Library ▸ Developer stack (#397): every data/dev-stack.tsv row
// joined with what DEVSTACK_DIR holds (lib/devstack.js: async, bounded reads). Cached like
// the other status helpers; concurrent requests share one scan.
const DEVSTACK_GUIDES = path.join(ROOT, 'data', 'dev-stack-guides');
let _devstackCache = { data: null, ts: 0 };
let _devstackComputing = null;
function getDevstack() {
    if (_devstackCache.data && (Date.now() - _devstackCache.ts) < CACHE_TTL) return Promise.resolve(_devstackCache.data);
    if (!_devstackComputing) {
        _devstackComputing = devstack.listing(path.join(ROOT, 'data', 'dev-stack.tsv'), DEVSTACK_GUIDES, DEVSTACK_DIR)
            .catch(() => ({ groups: [], projects: [] }))
            .then((data) => { _devstackCache = { data, ts: Date.now() }; return data; })
            .finally(() => { _devstackComputing = null; });
    }
    return _devstackComputing;
}

// Catalog of downloadable-but-absent resources (live Kiwix OPDS for content, the
// curated data/models-extra.tsv for models). Computed in the BACKGROUND by shelling
// to `librarian.sh catalog` so a browse request never blocks on the OPDS fetch; the
// result is cached and the UI one-click-requests any item (POST /api/request).
const _catalogCache = { content: { data: null, ts: 0 }, models: { data: null, ts: 0 } };
const _catalogComputing = { content: null, models: null };
const CATALOG_TTL = 3600000;               // 1h — OPDS moves slowly; re-walked in background
const CATALOG_MAX_ITEMS = 4000;            // bound the JSON payload
// Browse the English catalog by default (thousands of ZIMs per language would swamp
// the UI); operators can widen with VALARK_CATALOG_LANGS.
const CATALOG_LANGS = String(cfg('VALARK_CATALOG_LANGS', 'eng')).trim();

function computeCatalog(kind) {
    const arg = kind === 'models' ? 'model' : 'content';
    return new Promise((resolve) => {
        // NOTE (#57): do NOT pass VALARK_ZIM_LANGS here. That would make the shared
        // librarian cache re-fetch English-only and clobber the full multi-language
        // catalog. We always refresh the full cache and narrow LANGUAGES on output
        // (parseCatalogTSV langs) — a browse can never degrade the on-disk cache.
        execFile('/usr/bin/bash', [path.join(ROOT, 'scripts/librarian.sh'), 'catalog', arg], {
            cwd: ROOT, timeout: 160000, maxBuffer: 48 * 1024 * 1024,
            env: { ...process.env, FORCE_COLOR: '0' },
        }, (err, stdout) => {
            const items = err ? (_catalogCache[kind].data || [])
                : parseCatalogTSV(stdout, {
                    maxItems: CATALOG_MAX_ITEMS,
                    // language filter is meaningful for ZIM content only
                    langs: kind === 'content' ? CATALOG_LANGS : '',
                });
            _catalogCache[kind] = { data: items, ts: Date.now() };
            resolve(items);
        });
    });
}
function getCatalog(kind) {
    if (kind !== 'content' && kind !== 'models') return { items: [], count: 0, computing: false };
    const c = _catalogCache[kind];
    const now = Date.now();
    const fresh = c.data && (now - c.ts) < CATALOG_TTL;
    if (!fresh && !_catalogComputing[kind]) {
        _catalogComputing[kind] = computeCatalog(kind).finally(() => { _catalogComputing[kind] = null; });
    }
    return { items: c.data || [], count: (c.data || []).length, computing: !c.data };
}

function readdirSafe(dir) {
    try { return fs.readdirSync(dir); }
    catch { return []; }
}

// =============================================================================
// Request Handling
// =============================================================================
const SECURITY_HEADERS = {
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'SAMEORIGIN',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
};

// CSRF guard for every POST (#314). A browser always sends Origin on a cross-origin POST
// (and Sec-Fetch-Site on modern ones), so a web page elsewhere, even one opened in a
// browser on the box itself, where localhost counts as Admin, can't drive an admin or
// "use" action. Requests with neither header (curl, the CLI, scripts) are unaffected.
function sameOriginPost(req) {
    const scheme = req.socket && req.socket.encrypted ? 'https:' : 'http:';
    const origin = req.headers.origin;
    if (origin !== undefined) {
        if (origin === 'null') return false;
        try {
            // URL() can't parse an IPv6 zone id ([fe80::1%eth0]); drop it on both sides first.
            // Zones must match when both sides carry one (fe80::1%eth0 is not fe80::1%wlan0).
            const zoneOf = v => { const m = String(v).match(/%(?:25)?([0-9a-z]+)\]/i); return m ? m[1].toLowerCase() : ''; };
            const unzone = v => String(v).replace(/%(25)?[0-9a-z]+\]/i, ']');
            const zo = zoneOf(origin), zh = zoneOf(req.headers.host || '');
            if (zo && zh && zo !== zh) return false;
            const o = new URL(unzone(origin)), h = new URL(scheme + '//' + unzone(req.headers.host || ''));
            return o.protocol === scheme && o.host === h.host;   // URL() drops default ports, canonicalizes IPv6
        } catch (_) { return false; }
    }
    const site = req.headers['sec-fetch-site'];
    return site === undefined || site === 'same-origin' || site === 'none';
}
// Defence in depth for #317: a page under /app/<id>/ or /kiwix/ is same-origin with the
// UI, so the Origin check above lets it through. The browser names the calling page in
// Referer (Referrer-Policy keeps the full URL same-origin), so /api/* refuses a write from
// one, and a script read (fetch/XHR: Sec-Fetch-Dest "empty"). A plain navigation or a
// download link from a forum post to /api/archive/... still works. A script can hide or
// change its Referer, so this is a second line, not the fix: user content is sandboxed
// by the proxy (SUBAPP_USER_CONTENT).
function fromProxiedPage(req) {
    const ref = req.headers.referer;
    if (!ref) return false;
    let p;
    try { p = decodeURIComponent(new URL(String(ref)).pathname); } catch (_) { return false; }
    p = path.posix.normalize(p.replace(/\\/g, '/'));
    return /^\/+(?:app|kiwix)(?:\/|$)/i.test(p);
}
function subAppApiCallRefused(req) {
    if (!fromProxiedPage(req)) return false;
    const m = req.method;
    if (m !== 'GET' && m !== 'HEAD' && m !== 'OPTIONS') return true;
    return req.headers['sec-fetch-dest'] === 'empty';
}
// DNS rebinding guard: a page on an attacker's domain that re-resolves to the box would send a
// matching Host and Origin. Only names that can belong to this box are served: IP literals,
// localhost, single-label names (no dot: a LAN hostname), *.local / *.lan / *.home / *.home.arpa /
// *.internal / *.localdomain / *.ts.net / *.fritz.box, the TLS domain, the box's own hostname, and VALARK_ALLOWED_HOSTS
// (comma-separated). Anything else gets 421 (review of #316).
function hostAllowed(req) {
    let raw = String(req.headers.host || '').toLowerCase();
    if (!raw) return true;   // HTTP/1.0 without Host: nothing for a rebinding page to forge
    if (/^\[fe80:[0-9a-f:.]*%[0-9a-z]+\](:\d+)?$/.test(raw)) return true;   // link-local with a zone id
    // Only the shapes a browser actually sends: a name or IPv4 (with one optional trailing dot)
    // or a bracketed IPv6, plus a port. No userinfo, escapes or other junk reaches URL().
    if (!/^([a-z0-9-]+(\.[a-z0-9-]+)*\.?|\[[0-9a-f:.]+\])(:\d+)?$/.test(raw)) return false;
    raw = raw.replace(/\.(?=(:\d+)?$)/, '');   // 'valark.local.' is 'valark.local'
    let name;
    try { name = new URL('http://' + raw).hostname; } catch (_) { return false; }
    if (/^\[.*\]$/.test(name) || /^\d{1,3}(\.\d{1,3}){3}$/.test(name)) return true;   // IP literal
    if (name === 'localhost' || !name.includes('.')) return true;
    if (/\.(local|lan|home|home\.arpa|internal|localdomain|ts\.net|fritz\.box)$/.test(name)) return true;
    const tls = String(process.env.VALARK_TLS_DOMAIN || 'valark.lan').trim().toLowerCase().replace(/^\.+|\.+$/g, '');
    // The TLS domain itself, exactly. Its subdomains are served only when it is a private name,
    // which the suffix rule above already covers: a real domain (or a public suffix) is never
    // trusted wholesale, since whoever controls a subdomain's DNS could rebind it to this box.
    if (tls.includes('.') && name === tls) return true;
    const extra = [require('os').hostname(), ...String(process.env.VALARK_ALLOWED_HOSTS || '').split(',')]
        .map(x => String(x).trim().toLowerCase()).filter(Boolean);
    return extra.includes(name);
}
function getCORSOrigin(req) {
    // The web UI is same-origin and needs no CORS. Reflecting localhost origins let any page on
    // another localhost port read admin data (the recovery code) from a browser on the box
    // (review of #316). VALARK_DEV_CORS_ORIGIN allows one exact origin for a dev server only.
    const dev = process.env.VALARK_DEV_CORS_ORIGIN;
    return dev && req.headers.origin === dev ? dev : '';
}

function sendJSON(res, req, data, status = 200, extraHeaders) {
    const body = JSON.stringify(data);
    const corsOrigin = getCORSOrigin(req);
    res.writeHead(status, {
        'Content-Type': 'application/json',
        ...(corsOrigin ? { 'Access-Control-Allow-Origin': corsOrigin } : {}),
        'Content-Length': Buffer.byteLength(body),
        ...SECURITY_HEADERS,
        ...(extraHeaders || {}),
    });
    res.end(body);
}

function send404(res) {
    res.writeHead(404, { 'Content-Type': 'text/plain', ...SECURITY_HEADERS });
    res.end('Not Found');
}

function readBody(req) {
    return new Promise((resolve) => {
        const chunks = [];
        let size = 0;
        req.on('data', (c) => {
            size += c.length;
            if (size > 65536) { resolve({}); req.destroy(); return; }
            chunks.push(c);
        });
        req.on('end', () => {
            try { resolve(JSON.parse(Buffer.concat(chunks).toString() || '{}')); }
            catch { resolve({}); }
        });
    });
}

// Check if request is from localhost (for restricting dangerous operations)
function isLocalhost(req) {
    // Test hook: simulate a remote (LAN) client so the access gate can be exercised.
    // Fail-SAFE — it only REMOVES the localhost admin bypass, never grants access.
    if (process.env.VALARK_TEST_FORCE_REMOTE === '1') return false;
    if (process.env.VALARK_TEST_FORCE_PUBLIC === '1') return false;
    const addr = req.socket?.remoteAddress || '';
    // IPv4 localhost
    if (addr === '127.0.0.1' || addr === '::1') return true;
    // IPv6 localhost
    if (addr === '::ffff:127.0.0.1') return true;
    // No address: the server only listens on TCP, and Node reports no address once a
    // socket is gone, so this is NOT a local peer (it used to count as admin).
    return false;
}

// ---- Admin sessions & the access gate ---------------------------------------
// Read the signed session cookie set at login (see auth.js). No server-side table.
function sessionToken(req) {
    const raw = req.headers?.cookie || '';
    const m = raw.match(/(?:^|;\s*)varksid=([^;]+)/);
    return m ? decodeURIComponent(m[1]) : '';
}
// Is this request an authenticated admin? The box's own console/localhost is always
// admin (physical possession = ownership — this is what makes recovery possible);
// from the LAN you need a valid session (obtained by POSTing the admin passcode).
function isAdmin(req) {
    if (isLocalhost(req)) return true;
    if (!auth.status(STATE_DIR).adminSet) return false;     // no admin ⇒ no LAN admin
    // Bind the session to the login IP: a cookie captured on the wire can't be
    // replayed from another host.
    return auth.verifySession(sessionToken(req), STATE_DIR, clientIp(req));
}
// A cookie is safe to mark Secure only when this request actually arrived over TLS
// (behind the local CA) — marking it Secure on plain HTTP would silently drop it.
function isSecureReq(req) {
    return !!(req.socket && req.socket.encrypted) || req.headers?.['x-forwarded-proto'] === 'https';
}

// Read-wall: content/data paths that reveal what's on the box. The UI shell, auth,
// setup, health and the CA are NOT gated (so the login wall can render + you can sign
// in). Gated paths are refused for un-authed LAN visitors in Passworded/Accounts mode,
// and for any peer that isn't LAN, tailnet or localhost in every mode (#297).
function isReadGated(urlPath) {
    if (urlPath.startsWith('/api/auth/') || urlPath.startsWith('/api/setup/')) return false;
    if (urlPath === '/api/health' || urlPath === '/api/status/tls') return false;
    if (urlPath.startsWith('/api/status/') || urlPath.startsWith('/api/catalog/') ||
        urlPath.startsWith('/api/archive/') || urlPath === '/api/downloads/stream') return true;
    // The packages manifest enumerates the library (what's on the box) → gate it
    // like the archive/catalog reads it points at, not like the open UI shell.
    if (urlPath === '/api/packages') return true;
    if (urlPath === '/api/devstack' || urlPath === '/api/devstack/guide') return true;   // same: what the dev-stack tree holds
    if (urlPath === '/kiwix' || urlPath.startsWith('/kiwix/')) return true;
    if (/^\/app\//.test(urlPath)) return true;
    // The raw data/content trees the static router serves straight from ROOT (the
    // library, models, tool binaries, source bundles, assets, docs). These ARE the
    // content the wall protects — /api/archive + /kiwix are just another door to the
    // same bytes, so gating only those would leave the front door wide open.
    if (/^\/(content|models|tools|sources|assets|installers|docs)(\/|$)/i.test(urlPath)) return true;
    return false;   // the web-ui shell + its assets (index.html, styles.css, favicon, logos) stay open
}
function readAllowed(req) {
    // Safe Mode = recovery-only, fail CLOSED: a corrupt auth.json makes useMode read as
    // the swallowed default 'open', which would otherwise DROP the read-wall. So gate all
    // content reads to admin (localhost/console or a valid session) whenever config is broken.
    if (safeModeState().safeMode) return isAdmin(req);
    const mode = auth.status(STATE_DIR).useMode;
    if (mode !== 'passworded' && mode !== 'accounts') return true;   // Open: reads are open
    return isAdmin(req);   // gated modes: localhost/console or a valid session
}
// Login cooldown (not a permanent lock): slow down passcode guessing. Per-IP AND a
// global cap, so an attacker can't just rotate source IPs (NIC aliases) to multiply
// their guess budget. localhost/console always bypasses (owner is never locked out).
const _loginFails = new Map();
const LOGIN_MAX = 8, LOGIN_WINDOW_MS = 10 * 60 * 1000;
let _loginGlobal = { n: 0, first: 0 };
const LOGIN_GLOBAL_MAX = 40;
function loginAllowed(req) {
    if (isLocalhost(req)) return true;   // the owner on the box/console is NEVER locked out
    if (_loginGlobal.first && Date.now() - _loginGlobal.first > LOGIN_WINDOW_MS) _loginGlobal = { n: 0, first: 0 };
    if (_loginGlobal.n >= LOGIN_GLOBAL_MAX) return false;   // global brute-force cap
    const rec = _loginFails.get(clientIp(req));
    if (!rec) return true;
    if (Date.now() - rec.first > LOGIN_WINDOW_MS) { _loginFails.delete(clientIp(req)); return true; }
    return rec.n < LOGIN_MAX;
}
function noteLoginFail(req) {
    const ip = clientIp(req); const rec = _loginFails.get(ip);
    if (!rec || Date.now() - rec.first > LOGIN_WINDOW_MS) _loginFails.set(ip, { n: 1, first: Date.now() });
    else rec.n++;
    if (!_loginGlobal.first || Date.now() - _loginGlobal.first > LOGIN_WINDOW_MS) _loginGlobal = { n: 1, first: Date.now() };
    else _loginGlobal.n++;
}
function sessionCookie(token, maxAgeSec, secure) {
    // HttpOnly so JS can't read it (a sub-app's scripts included); SameSite=Lax to resist
    // CSRF, and a sandboxed (opaque-origin) user upload counts as cross-site, so its
    // requests carry no cookie. Path=/ because the read-wall checks it on /app/, /kiwix/
    // and the data trees too (Path=/api would sign Passworded users out of those); the
    // proxy strips it before forwarding to any sub-app (#317).
    // Secure ONLY when the request came over TLS (else the browser would drop it on HTTP).
    return `varksid=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${maxAgeSec}${secure ? '; Secure' : ''}`;
}
// POSTs that CHANGE the box's config/accounts — always admin (localhost or a
// logged-in admin), regardless of Use Mode. "Use" actions (downloads/requests/
// service starts) are gated per Use Mode instead (Open = anyone on the LAN).
const ADMIN_ONLY_POSTS = new Set(['/api/service/adduser', '/api/setup/profile', '/api/maintenance/repair', '/api/setup/moderation', '/api/moderation/review', '/api/setup/usemode', '/api/setup/loop-install']);
const AUTH_EXEMPT_POSTS = new Set(['/api/auth/login', '/api/auth/logout', '/api/auth/recover', '/api/setup/commission']);

// Peer IP, normalized (node reports LAN/tailnet IPv4 peers as IPv4-mapped IPv6).
function clientIp(req) {
    let a = req.socket?.remoteAddress || '';
    if (a.startsWith('::ffff:')) a = a.slice(7);
    return a;
}

// Is the request from the LAN or the tailnet? Val Ark is a community appliance
// reachable ONLY on the local network and the tailscale tailnet (never the public
// internet — see docs/ARM64-NAS.md), so members can one-click downloads from those
// peers. Every trigger is still guarded (allowlist targets, footprint-cap eviction,
// single-flight fill lock, per-IP rate limit); public/unknown peers are refused.
// Did this connection arrive on a tailscale interface (tailscale0, utunN with a 100.x
// tailscale address)? Looked up per request, so a tailnet that comes up later works.
// os.networkInterfaces(), cached for a few seconds (an internet peer can make us ask).
let _ifCache = { at: 0, v: {} };
function netIfaces() {
    if (Date.now() - _ifCache.at > 5000) _ifCache = { at: Date.now(), v: require('os').networkInterfaces() };
    return _ifCache.v;
}
// Linux names it tailscale0; macOS uses a utunN carrying Tailscale's 100.64/10 address AND
// its fd7a:115c:a1e0::/48 IPv6 (other VPNs, e.g. WARP, also use 100.x on a utun).
// Tailscale's userspace-networking mode has no interface: tailscaled connects onward from
// 127.0.0.1, so its peers look like the box itself (Admin). Use the kernel interface.
function arrivedOnTailnet(req, ifaces = netIfaces()) {
    const la = (req.socket?.localAddress || '').replace(/^::ffff:/, '');
    if (!la) return false;
    const cgnat = a => /^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(a);
    for (const [name, addrs] of Object.entries(ifaces)) {
        const list = addrs || [];
        const tsV6 = list.some(a => /^fd7a:115c:a1e0:/i.test(a.address));
        const tail = /^(tailscale|ts)\d*$/i.test(name) || (/^utun\d+$/i.test(name) && list.some(a => cgnat(a.address)) && tsV6);
        if (tail && list.some(a => a.address === la)) return true;
    }
    return false;
}
// A global IPv6 peer is on the LAN when it shares an on-link prefix (/64 or longer) with
// one of the box's own interfaces that ALSO carries a private (RFC 1918) IPv4 address, e.g.
// a home router's delegated /64. A cloud uplink or an ISP's shared WAN /64 has no private
// IPv4 beside it, so its neighbours (other customers) are not trusted.
function ipv6ToBig(a) {
    const s = a.split('%')[0].toLowerCase();
    if (!/^[0-9a-f:]+$/.test(s) || (s.match(/::/g) || []).length > 1) return null;
    const [h, t] = s.split('::');
    const head = h ? h.split(':') : [], tail = t !== undefined && t ? t.split(':') : [];
    const fill = t !== undefined ? 8 - head.length - tail.length : 0;
    if (t !== undefined && fill < 1) return null;   // '::' must stand for at least one group
    const parts = [...head, ...Array(Math.max(fill, 0)).fill('0'), ...tail];
    if (parts.length !== 8 || parts.some(x => !/^[0-9a-f]{1,4}$/.test(x))) return null;
    return parts.reduce((n, x) => (n << 16n) + BigInt(parseInt(x, 16)), 0n);
}
function onLinkV6(peer, ifaces = netIfaces()) {
    const p = ipv6ToBig(peer); if (p === null) return false;
    const rfc1918 = a => /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a);
    for (const addrs of Object.values(ifaces)) {
        if (!(addrs || []).some(a => (a.family === 'IPv4' || a.family === 4) && rfc1918(a.address))) continue;
        for (const a of addrs || []) {
            if (a.family !== 'IPv6' && a.family !== 6) continue;
            const bits = Number(String(a.cidr || '').split('/')[1]);
            if (!(bits >= 64 && bits <= 128)) continue;
            const mine = ipv6ToBig(a.address); if (mine === null) continue;
            const mask = ((1n << BigInt(bits)) - 1n) << BigInt(128 - bits);
            if ((mine & mask) === (p & mask)) return true;
        }
    }
    return false;
}
function isLanOrTailnet(req) {
    // Test hook: simulate a public-internet peer. Fail-SAFE like VALARK_TEST_FORCE_REMOTE:
    // it only takes access away, never grants it.
    if (process.env.VALARK_TEST_FORCE_PUBLIC === '1') return false;
    if (isLocalhost(req)) return true;
    const a = clientIp(req);
    if (!a) return false;                      // no address (socket gone): not local
    const m = a.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
    if (m) {
        const o = m.slice(1, 5).map(Number);
        if (o.some(n => n > 255)) return false;
        if (o[0] === 127) return true;                                 // loopback
        if (o[0] === 10) return true;                                  // 10.0.0.0/8
        if (o[0] === 172 && o[1] >= 16 && o[1] <= 31) return true;     // 172.16.0.0/12
        if (o[0] === 192 && o[1] === 168) return true;                 // 192.168.0.0/16
        // 100.64.0.0/10 is the tailnet only when the request arrived on the box's own
        // tailscale interface; on a carrier-CGNAT uplink the same range is other subscribers.
        if (o[0] === 100 && o[1] >= 64 && o[1] <= 127) return arrivedOnTailnet(req);
        if (o[0] === 169 && o[1] === 254) return true;                 // link-local
        return false;
    }
    const low = a.toLowerCase();
    if (low === '::1') return true;
    if (/^f[cd][0-9a-f]{2}:/.test(low)) return true;   // ULA fc00::/7 (tailnet fd7a:…⊂ this)
    if (/^fe[89ab][0-9a-f]:/.test(low)) return true;   // link-local fe80::/10
    return onLinkV6(low);                               // global IPv6 on the box's own /64
}

// Per-IP token bucket for expensive POST triggers (download / request / service
// start). Prevents a single LAN client from spamming multi-GB fetches or NodeBB
// builds. Sliding 60s window; the map is pruned opportunistically.
const rateBuckets = new Map();
const RATE_MAX = 30;              // triggers per window per IP
const RATE_WINDOW_MS = 60000;
function rateLimitOk(req) {
    const key = clientIp(req) || 'local';
    const now = Date.now();
    let b = rateBuckets.get(key);
    if (!b || (now - b.start) >= RATE_WINDOW_MS) { b = { start: now, n: 0 }; rateBuckets.set(key, b); }
    b.n++;
    if (rateBuckets.size > 512) {
        for (const [k, v] of rateBuckets) if ((now - v.start) >= RATE_WINDOW_MS) rateBuckets.delete(k);
    }
    return b.n <= RATE_MAX;
}

function handleAPI(req, res, urlPath) {
    const corsOrigin = getCORSOrigin(req);

    // CORS preflight
    if (req.method === 'OPTIONS') {
        res.writeHead(204, {
            ...(corsOrigin ? { 'Access-Control-Allow-Origin': corsOrigin } : {}),
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Max-Age': '86400',
        });
        return res.end();
    }

    // GET endpoints (HEAD too — the UI probes /api/archive availability with HEAD
    // before downloading; serveArchive answers HEAD with headers only).
    if (req.method === 'GET' || req.method === 'HEAD') {
        switch (urlPath) {
            case '/api/health': {
                const sm = safeModeState();
                return sendJSON(res, req, {
                    status: sm.safeMode ? 'safe-mode' : 'ok',
                    safeMode: sm.safeMode,
                    safeModeReasons: sm.reasons,
                    uptime: process.uptime(),
                    version: APP_VERSION,
                    timestamp: new Date().toISOString()
                });
            }
            case '/api/status/disk':
                return sendJSON(res, req, getDiskStatus());
            case '/api/status/tools':
                return sendJSON(res, req, getToolsStatus());
            case '/api/status/content':
                return sendJSON(res, req, getContentStatus());
            case '/api/status/models':
                return sendJSON(res, req, getModelsStatus());
            case '/api/status/kiwix':
                return sendJSON(res, req, kiwixStatus);
            case '/api/status/storage':
                return sendJSON(res, req, getStorageStatus());
            case '/api/status/services':
                return getServicesStatus().then(d => sendJSON(res, req, d)).catch(() => sendJSON(res, req, {}));
            case '/api/status/all':
                return sendJSON(res, req, {
                    disk: getDiskStatus(),
                    tools: getToolsStatus(),
                    content: getContentStatus(),
                    models: getModelsStatus(),
                    kiwix: kiwixStatus,
                });
            case '/api/status/downloads':
                // Every live + recent job (incl. failures with their reason). The UI re-syncs
                // from this on page load, on SSE (re)connect, and while any job is active.
                return sendJSON(res, req, jobManager.snapshot());
            case '/api/status/health':
                // Self-heal detail for the Health page: the loop's selfheal.json snapshot
                // (space, verify tallies, link/asset counts, this-cycle repairs), the
                // functional-verify per-check results (verify.json), the timestamped
                // heal-events feed, and Safe-Mode state. Read-gated like all /api/status.
                return sendJSON(res, req, getHealthDetail(req));
            case '/api/status/notifications':
                // Notification center (issue #69 slice 1): a read-only aggregation of
                // recent self-heal events + current warning/critical conditions for the
                // web UI's bell/inbox. Read-gated by the /api/status/ prefix; never throws
                // on a bare box (empty → {items:[]}). Dismiss is client-side this slice.
                return sendJSON(res, req, getNotifications());
            case '/api/status/metrics': {
                // Live host gauges for the Health page's System tiles — pure local reads
                // (/proc + os + cached disk), no external service, never throws. Read-gated
                // by the /api/status/ prefix (reveals host load), same class as .../disk.
                const m = getHostMetrics();          // uses + updates the live baseline
                _metricsPrev = m._sample || _metricsPrev;
                return sendJSON(res, req, m);
            }
            case '/api/status/metrics/history': {
                // Sparkline history from the zero-dep on-disk ring buffer (the server samples
                // itself; no daemon/token/outbound call). In-memory read; ?window is
                // allowlist-mapped to a fixed cap. Empty on a fresh box → 200 {series:[]},
                // never 500. Read-gated by the /api/status/ prefix like the live endpoint.
                let win = null;
                try { win = new URL(req.url, 'http://localhost').searchParams.get('window'); } catch (_) {}
                return sendJSON(res, req, getMetricsHistory(win));
            }
            case '/api/status/moderation':
                // Safety card: is on-device screening enabled, and is a classifier actually
                // installed (else it holds everything). Read-gated by the /api/status/ prefix.
                return sendJSON(res, req, getModerationStatus());
            case '/api/status/ask':
                // "Ask Val Ark" readiness (Phase 8): is the on-box assistant runtime + a
                // chat model present? Pure presence checks, no inference. Read-gated by the
                // /api/status/ prefix — the Home card uses it to show ask vs. get-the-helper.
                return sendJSON(res, req, getAskStatus());
            case '/api/moderation/queue':
                // The held-content review feed for the admin Safety card. Reveals flagged
                // content details, so it's ADMIN-ONLY (localhost/console or a signed session)
                // regardless of Use Mode — not merely read-gated.
                if (!isAdmin(req)) return sendJSON(res, req, { error: 'Admin only.', needsAuth: true }, 401);
                return sendJSON(res, req, getModerationQueue());
            case '/api/auth/status':
                // Read-only: is an admin set, which Use Mode, is this caller the
                // trusted box/localhost (`trusted`) and are they an authenticated
                // admin right now (`authed` = localhost or a valid session).
                return sendJSON(res, req, { ...auth.status(STATE_DIR), trusted: isLocalhost(req), authed: isAdmin(req), localOnly: !isLanOrTailnet(req) });
            case '/api/setup/state': {
                // First-boot state for the wizard. Never leaks the claim token; only
                // whether one is needed (LAN) or bypassed (this box/localhost).
                // commissioned comes from the persisted snapshot (+ operator override),
                // never live from the library, so it can't be flipped after boot.
                const st = commission.state(STATE_DIR, isLocalhost(req));
                st.commissioned = boxCommissioned();
                if (st.commissioned) { st.hasClaim = false; st.needsClaim = false; }
                const sm = safeModeState();
                st.safeMode = sm.safeMode; st.safeModeReasons = sm.reasons;
                // How to reach the box (<name>.local or its LAN IP, #306) + whether filling
                // has started / the 24/7 loop is installed (Home's "filling" card).
                st.access = boxAddress(req);
                st.fill = firstFillState();
                loopInstalled();   // refresh the cron cache in the background
                return sendJSON(res, req, st);
            }
            case '/api/setup/recovery-card': {
                // The printable recovery card — box name/address + the one-time recovery
                // code. The code is a SECRET, so this is admin-only (localhost or a signed
                // session); un-authed peers can't read it.
                if (!isAdmin(req)) return sendJSON(res, req, { error: 'Admin only.', needsAuth: true }, 401);
                // The address is boxAddress()'s pick: <name>.local only when it really
                // answers, else the LAN IP with the reason .local is unavailable (#306).
                const a = boxAddress(req);
                return sendJSON(res, req, {
                    name: a.name,
                    address: a.url,
                    addressAlt: a.altUrl,
                    mdns: a.mdns,
                    mdnsNote: a.mdns ? '' : `${a.host} is unavailable on this box (${a.reason})`,
                    recovery: commission.ensureRecovery(STATE_DIR),
                });
            }
            case '/api/catalog/content':
                return sendJSON(res, req, getCatalog('content'));
            case '/api/catalog/models':
                return sendJSON(res, req, getCatalog('models'));
            case '/api/packages':
                // The PRESENT inventory this box can hand out now: app archives,
                // the self-replication source bundle/tarball/node runtimes, on-disk
                // models, complete ZIMs — relative URLs + metadata only. Read-gated
                // like the library it enumerates (see isReadGated). Distinct from
                // /api/catalog/* (the upstream not-yet-downloaded browse feed).
                return sendJSON(res, req, getPackages());
            case '/api/devstack':
                return getDevstack().then((d) => sendJSON(res, req, d));
            case '/api/devstack/guide': {
                // ?ref= is only ever compared with the catalog's own keys (never used as a path).
                let ref = '';
                try { ref = new URL(req.url, 'http://localhost').searchParams.get('ref') || ''; } catch (_) {}
                return getDevstack().then(async (d) => {
                    const p = d.projects.find((x) => x.key === ref);
                    const text = p ? await devstack.guide(DEVSTACK_GUIDES, p.key, new Set(d.projects.map((x) => x.key))) : null;
                    if (text === null) return sendJSON(res, req, { error: 'No guide for that project' }, 404);
                    sendJSON(res, req, { key: p.key, name: p.name, guide: text });
                });
            }
            case '/api/downloads/stream': {
                // SSE connection limits: a global pool cap AND a per-IP cap, so one peer
                // can't monopolise the progress stream for every other client/tab.
                if (sseClients.size >= MAX_SSE_CONNECTIONS) {
                    res.writeHead(503, { 'Retry-After': '10' });
                    return res.end('Too many SSE connections');
                }
                const sseIp = clientIp(req) || 'local';
                if ((sseByIp.get(sseIp) || 0) >= MAX_SSE_PER_IP) {
                    res.writeHead(503, { 'Retry-After': '10' });
                    return res.end('Too many SSE connections from this client');
                }
                res.writeHead(200, {
                    'Content-Type': 'text/event-stream',
                    'Cache-Control': 'no-cache',
                    'Connection': 'keep-alive',
                    ...(corsOrigin ? { 'Access-Control-Allow-Origin': corsOrigin } : {}),
                    ...SECURITY_HEADERS,
                });
                res.write(`event: init\ndata: ${JSON.stringify({ connected: true, jobs: jobManager.snapshot() })}\n\n`);
                sseClients.add(res);
                sseByIp.set(sseIp, (sseByIp.get(sseIp) || 0) + 1);
                req.on('close', () => {
                    sseClients.delete(res);
                    const n = (sseByIp.get(sseIp) || 1) - 1;
                    if (n <= 0) sseByIp.delete(sseIp); else sseByIp.set(sseIp, n);
                });
                return;
            }
            default:
                // Handle /api/archive/<path> for tarball downloads
                if (urlPath.startsWith('/api/archive/')) {
                    return serveArchive(res, req, urlPath.slice('/api/archive/'.length));
                }
                return sendJSON(res, req, { error: 'Unknown endpoint' }, 404);
        }
    }

    // POST endpoints - trigger downloads / service starts. Allowed from the LAN and
    // the tailnet (this appliance is not exposed to the public internet); each trigger
    // is validated against an allowlist, disk/footprint-cap guarded, single-flight,
    // and per-IP rate limited. Public/unknown peers are refused.
    if (req.method === 'POST') {
        if (!isLanOrTailnet(req)) {
            return sendJSON(res, req, {
                error: 'Downloads can be triggered only from the local network or tailnet.'
            }, 403);
        }
        if (!rateLimitOk(req)) {
            return sendJSON(res, req, {
                error: 'Too many requests — please slow down and try again in a minute.'
            }, 429);
        }
        if (!sameOriginPost(req)) {
            return sendJSON(res, req, { error: 'Cross-site requests are not accepted. Use the Val Ark web UI.' }, 403);
        }
        // An un-owned box serves the setup wizard, NOT the catalog: refuse every
        // mutating action (downloads, requests, service starts, account creation)
        // until it's commissioned — except commissioning itself. This closes the
        // grandfather-flip vector (a LAN peer can't seed the library to fake setup)
        // and matches the "fresh box → wizard" design.
        if (!boxCommissioned() && !AUTH_EXEMPT_POSTS.has(urlPath)) {
            // auth + recovery + commission must work even before/without commissioning
            // (and in Safe Mode, where a corrupt config reads as un-commissioned).
            return sendJSON(res, req, {
                error: 'Val Ark isn’t set up yet — finish the setup wizard first.'
            }, 409);
        }
        // Access gate (per Use Mode). Config/account changes always need admin; "use"
        // actions need admin only when the box is Passworded or Accounts. Open = anyone
        // on the LAN may use. Login/logout/commission are exempt (you can't be authed
        // to log in). The box's own console/localhost is always admin.
        if (!AUTH_EXEMPT_POSTS.has(urlPath)) {
            const mode = auth.status(STATE_DIR).useMode;
            // Safe Mode is recovery-only → every mutating action needs admin (fail closed,
            // since a corrupt auth.json makes useMode read as the swallowed 'open' default).
            const needsAuth = safeModeState().safeMode || ADMIN_ONLY_POSTS.has(urlPath) || mode === 'passworded' || mode === 'accounts';
            if (needsAuth && !isAdmin(req)) {
                return sendJSON(res, req, { error: 'Sign in required to do that on this network.', needsAuth: true }, 401);
            }
        }

        // Moderation check consumes the RAW request body itself (content bytes, up to
        // 25 MiB) — it must NOT go through readBody (which caps at 64KB and JSON-parses).
        // The full gate stack above (LAN/tailnet, rate limit, commissioned, auth-per-Use-
        // Mode) has already applied; a disabled engine is handled inside the handler.
        if (urlPath === '/api/moderation/check') return handleModerationCheck(req, res);

        readBody(req).then((body) => {
            let result;
            switch (urlPath) {
                case '/api/auth/login': {
                    // Exchange the admin passcode for a signed session cookie. Cooldown
                    // (not a lock) on repeated failures; localhost never needs this.
                    if (!auth.status(STATE_DIR).adminSet) {
                        return sendJSON(res, req, { error: 'No admin passcode is set yet — set one on the box first.' }, 400);
                    }
                    if (!loginAllowed(req)) {
                        return sendJSON(res, req, { error: 'Too many attempts — wait a few minutes, or sign in from the box itself.' }, 429);
                    }
                    if (typeof body.password === 'string' && auth.verify(body.password, STATE_DIR)) {
                        const token = auth.issueSession(STATE_DIR, 12 * 3600 * 1000, clientIp(req));
                        return sendJSON(res, req, { ok: true }, 200, { 'Set-Cookie': sessionCookie(token, 12 * 3600, isSecureReq(req)) });
                    }
                    noteLoginFail(req);
                    return sendJSON(res, req, { error: 'Incorrect passcode.' }, 401);
                }
                case '/api/auth/logout':
                    return sendJSON(res, req, { ok: true }, 200, { 'Set-Cookie': sessionCookie('', 0, isSecureReq(req)) });
                case '/api/auth/recover': {
                    // Forgot-password: set a new admin passcode. localhost/console needs
                    // no code; from the LAN you present the recovery code from the card.
                    // Same cooldown as login (it's a code-guessing surface).
                    if (!loginAllowed(req)) {
                        return sendJSON(res, req, { error: 'Too many attempts — wait a few minutes, or reset from the box itself.' }, 429);
                    }
                    const rr = commission.recoverAdmin(STATE_DIR, body, { trusted: isLocalhost(req) });
                    if (rr.error) { noteLoginFail(req); return sendJSON(res, req, rr, 401); }
                    _smCache.ts = 0;   // config just repaired → re-evaluate Safe Mode now
                    // Auto-sign-in the recovered admin so they're not immediately locked out.
                    const tok = auth.issueSession(STATE_DIR, 12 * 3600 * 1000, clientIp(req));
                    return sendJSON(res, req, { ok: true, recovery: rr.recovery }, 200, { 'Set-Cookie': sessionCookie(tok, 12 * 3600, isSecureReq(req)) });
                }
                case '/api/ask':
                    // On-box assistant (Phase 8, slice 1). Streams the answer as SSE frames
                    // and manages its own response — return before the trailing sendJSON. A
                    // "use" action (NOT ADMIN_ONLY_POSTS): open on the LAN in Open mode, admin
                    // in Passworded/Accounts (the gate above already enforced that). Fail-soft.
                    return handleAsk(req, res, body);
                case '/api/download/tools':
                    result = startFromDesc({ kind: 'tools', target: body.target || 'all' });
                    break;
                case '/api/download/models':
                    result = startFromDesc({ kind: 'models', target: body.tier || 'all' });
                    break;
                case '/api/download/content':
                    result = startFromDesc({ kind: 'content', target: body.target || 'all' });
                    break;
                case '/api/download/update':
                    result = startFromDesc({ kind: 'update', target: body.target || 'all' });
                    break;
                case '/api/download/cancel':
                    result = cancelDownload(body.id);
                    break;
                case '/api/download/retry':
                    // Restart EXACTLY what failed/was cancelled (the job keeps its descriptor).
                    result = retryDownload(body.id);
                    break;
                case '/api/download/dismiss':
                    result = dismissDownload(body.id);
                    break;
                case '/api/request':
                    // One-click per-item request: pin + fetch a specific catalog item,
                    // auto-evicting lowest-priority unpinned content to fit the cap.
                    result = startFromDesc({ kind: 'request', rkind: body.kind, target: body.id });
                    break;
                case '/api/setup/commission':
                    // First-boot setup. Fail-closed on the claim token from the LAN;
                    // the box/localhost is trusted and may commission without one.
                    // (Public peers are already refused by the isLanOrTailnet gate.)
                    result = commission.commission(STATE_DIR, body, { trusted: isLocalhost(req) });
                    if (result && result.ok) {
                        // Keep the wizard's promises (#306): publish <name>.local when the box
                        // can, start filling if the 24/7 loop isn't installed, then answer with
                        // the address to use and what happened.
                        // Answer within ~3 s even if avahi or crontab is slow (#339): the work
                        // carries on, and the UI reads the outcome from /api/setup/state.
                        const done = result;
                        let answered = false;
                        const answer = (fill) => {
                            if (answered) return; answered = true; clearTimeout(cap);
                            sendJSON(res, req, { ...done, access: boxAddress(req), fill });
                        };
                        const cap = setTimeout(() => answer({ ...firstFillState(), pending: true }), 3000);
                        refreshMdns(() => startFirstFill(answer));
                        return;
                    }
                    break;
                case '/api/setup/profile':
                    // Change the download profile (Downloads & Priorities). Admin-only
                    // (ADMIN_ONLY_POSTS); drives the librarian's per-bucket curation weights.
                    result = commission.setProfile(STATE_DIR, body.profile);
                    break;
                case '/api/moderation/review':
                    // Act on a held item (remove / dismiss). Admin-only (ADMIN_ONLY_POSTS).
                    // The id is a bare quarantine basename, confined to the quarantine dir.
                    // There is no restore over the web (a file-write risk); see reviewModerationItem.
                    result = reviewModerationItem(body);
                    break;
                case '/api/setup/moderation':
                    // Toggle/tune on-device content screening (Safety card). Admin-only
                    // (ADMIN_ONLY_POSTS). Fail-closed defaults live in commission.getModeration;
                    // when the admin turns it ON, kick off a best-effort model pin so a real
                    // classifier lands (until then the core holds content rather than pass it).
                    result = commission.setModeration(STATE_DIR, {
                        enabled: body.enabled, sensitivity: body.sensitivity,
                        action: body.action, surfaces: body.surfaces,
                    });
                    if (result && result.ok && result.moderation.enabled) ensureModerationModel();
                    break;
                case '/api/setup/usemode': {
                    // Choose who can use the box: Open / Passworded / Accounts (#303).
                    // Admin-only (ADMIN_ONLY_POSTS). Gated modes need an admin passcode
                    // first (auth.setUseMode refuses otherwise): it's the only sign-in
                    // today, so "Accounts" behaves like Passworded until member accounts
                    // exist. Refused in Safe Mode: auth.json is unreadable there, and
                    // writing the mode would overwrite it with defaults (dropping the admin).
                    // Sessions are NOT rotated: every session is an admin session and the
                    // mode doesn't change who the admin is, so rotating would only sign out
                    // the admin making the change.
                    const mode = body.mode;
                    if (!['open', 'passworded', 'accounts'].includes(mode)) {
                        return sendJSON(res, req, { error: 'Use Mode must be open, passworded or accounts.' }, 400);
                    }
                    if (safeModeState().safeMode) {
                        return sendJSON(res, req, { error: 'Val Ark is in Safe Mode — recover the admin passcode first.' }, 409);
                    }
                    const before = auth.status(STATE_DIR);
                    if (mode !== 'open' && !before.adminSet) {
                        return sendJSON(res, req, { error: 'Set an admin passcode first — otherwise nobody on your network could sign in.', needsPasscode: true }, 409);
                    }
                    // setUseMode logs "[access] Use Mode changed …" (stderr → the server log)
                    // and refuses a corrupt auth.json even if the Safe Mode cache is stale.
                    try { auth.setUseMode(mode, STATE_DIR, isLocalhost(req) ? 'this box in Settings' : 'a signed-in admin in Settings'); }
                    catch (e) { return sendJSON(res, req, { error: e.message }, 409); }
                    result = { ok: true, useMode: mode, previous: before.useMode };
                    break;
                }
                case '/api/service/start':
                    // Bring up an enabled + mirrored community service (chat/mail/forum/paste/gitea).
                    result = startService(body.id);
                    break;
                case '/api/service/adduser':
                    // Provision a login on a host-managed service (chat/mail). An admin
                    // action (ADMIN_ONLY_POSTS): the access gate above already required
                    // localhost or a logged-in admin, so a remote admin can do it too.
                    result = addServiceUser(body.id, body.username, body.password);
                    break;
                case '/api/setup/loop-install':
                    // "Keep it healthy 24/7" (Home, after setup). Admin-only (ADMIN_ONLY_POSTS):
                    // runs `loop.sh install 30`, which writes this user's crontab. Fixed argv;
                    // takes NO request data.
                    return installLoop((r) => sendJSON(res, req, r, r.error ? 400 : 200));
                case '/api/maintenance/repair':
                    // One-click "Run self-heal now" (Health page). Admin-only
                    // (ADMIN_ONLY_POSTS). Runs the loop's own fixers with a fixed argv —
                    // takes NO request data, so there's no injection surface.
                    result = triggerRepair();
                    break;
                default:
                    return sendJSON(res, req, { error: 'Unknown endpoint' }, 404);
            }
            sendJSON(res, req, result, result.error ? 400 : 200);
        });
        return;
    }

    sendJSON(res, req, { error: 'Method not allowed' }, 405);
}

// =============================================================================
// Static File Serving (with path traversal protection)
// =============================================================================
function isPathSafe(resolved, baseDir) {
    const base = path.resolve(baseDir) + path.sep;
    return path.resolve(resolved).startsWith(base) || path.resolve(resolved) === path.resolve(baseDir);
}

// Realpath containment (issue #101). isPathSafe() above is purely LEXICAL, so a
// symlink planted INSIDE a served tree (tools/models/content/sources) that points
// OUTSIDE ROOT passes it — and fs.stat/statSync then FOLLOW the link. This resolves
// every symlink in `target` and confirms the REAL path is still inside the REAL
// `baseDir`. baseDir itself may be a symlink onto the data disk (the tools/models/
// content/sources trees ARE — the layout symlinks the repo back onto the big disk),
// so we realpath the base too and compare real-to-real; a legitimate within-tree
// symlink stays contained and still serves. Returns the resolved real path when
// contained, else null (dangling/absent links and an unreadable base → null, so the
// caller 404s / skips). Never throws.
function realpathWithin(target, baseDir) {
    let base, real;
    try { base = fs.realpathSync(baseDir); } catch (_) { return null; }
    try { real = fs.realpathSync(target); } catch (_) { return null; }
    if (real === base || real.startsWith(base + path.sep)) return real;
    return null;
}

// Stream one file with HTTP Range support — a mirror serves multi-GB artifacts (models,
// ZIMs, installers, dev-stack archives) and interrupted downloads must be resumable
// (curl -C -, wget -c, browser resume). Single-range only; malformed ranges fall through
// to a normal 200. Shared by serveStatic and serveArchive.
function sendFile(res, req, filePath, stat, headers) {
    const baseHeaders = { ...headers, 'Accept-Ranges': 'bytes', ...SECURITY_HEADERS };
    const pipe = (opts) => {
        const stream = fs.createReadStream(filePath, opts);
        stream.on('error', () => { try { res.destroy(); } catch (_) {} });
        stream.pipe(res);
    };
    const m = req && req.headers && req.headers.range
        && /^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
    if (m && (m[1] !== '' || m[2] !== '')) {
        let start, end;
        if (m[1] === '') {              // bytes=-N : final N bytes
            start = Math.max(0, stat.size - parseInt(m[2], 10));
            end = stat.size - 1;
        } else {
            start = parseInt(m[1], 10);
            end = m[2] === '' ? stat.size - 1 : Math.min(parseInt(m[2], 10), stat.size - 1);
        }
        if (start >= stat.size || start > end) {
            res.writeHead(416, { 'Content-Range': `bytes */${stat.size}`, ...SECURITY_HEADERS });
            return res.end();
        }
        res.writeHead(206, {
            ...baseHeaders,
            'Content-Length': end - start + 1,
            'Content-Range': `bytes ${start}-${end}/${stat.size}`,
        });
        return pipe({ start, end });
    }
    res.writeHead(200, { ...baseHeaders, 'Content-Length': stat.size });
    pipe();
}

function serveStatic(res, filePath, req) {
    fs.stat(filePath, (err, stat) => {
        if (err) return send404(res);

        // Handle directories with a simple file listing
        if (stat.isDirectory()) {
            return serveDirectory(res, filePath);
        }

        const ext = path.extname(filePath).toLowerCase();
        sendFile(res, req, filePath, stat, {
            'Content-Type': MIME[ext] || 'application/octet-stream',
            'Cache-Control': (ext === '.html' || ext === '.css' || ext === '.js') ? 'no-cache' : 'max-age=3600',
        });
    });
}

// HTML-escape untrusted text (filenames from the data disk, paths) before it
// goes into the autoindex / error pages — prevents stored XSS via attacker-named
// files. encodeURI keeps href path slashes while encoding metacharacters.
function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Serve a mirrored artifact under the data trees as a DOWNLOAD — this is how site
// visitors pull app binaries per platform. A file streams as an attachment; a
// directory streams as a gzipped tar (via system `tar`, zero-dep). Only paths
// inside the allowed data dirs are served; traversal is rejected.
// Each served name maps to its directory: the repo-root trees (symlinks onto the data
// disk), and the developer stack, which has no repo symlink and lives at DEVSTACK_DIR.
const ARCHIVE_DIRS = Object.assign(Object.create(null),
    Object.fromEntries(['tools', 'models', 'content', 'sources', 'assets', 'installers'].map((d) => [d, path.join(ROOT, d)])),
    { 'dev-stack': DEVSTACK_DIR });
function serveArchive(res, req, relPath) {
    let clean;
    try { clean = decodeURIComponent(relPath); } catch (_) { clean = relPath; }
    // A control character can never be part of a mirrored name, and one in the
    // Content-Disposition header below would throw inside the stat callback (a hung request).
    if (/[\x00-\x1f\x7f]/.test(clean)) return send404(res);
    clean = path.normalize(clean).replace(/^([/\\]|\.\.[/\\]?)+/, '');
    const top = clean.split(/[/\\]/)[0];
    const topDir = ARCHIVE_DIRS[top];
    if (!topDir) return send404(res);
    const target = path.join(topDir, clean.slice(top.length));
    if (!isPathSafe(target, topDir)) return send404(res);
    // Beyond the lexical check: an in-tree symlink could point outside ROOT and
    // fs.stat would follow it. Require the realpath to stay within the (realpathed)
    // top-level served dir before serving. Dangling links → null → 404. (#101)
    if (realpathWithin(target, topDir) === null) return send404(res);

    fs.stat(target, (err, stat) => {
        if (err) return send404(res);
        const base = path.basename(target).replace(/["\\]/g, '_');   // quoted in the header below
        // HEAD preflight (the UI probes availability before downloading) — answer the
        // headers without spawning a tar / opening the file for every probe.
        if (req && req.method === 'HEAD') {
            res.writeHead(200, {
                'Content-Type': stat.isDirectory() ? 'application/gzip' : 'application/octet-stream',
                'Content-Disposition': `attachment; filename="${base}${stat.isDirectory() ? '.tar.gz' : ''}"`,
                ...(stat.isDirectory() ? {} : { 'Content-Length': stat.size, 'Accept-Ranges': 'bytes' }),
                ...SECURITY_HEADERS,
            });
            return res.end();
        }
        if (stat.isDirectory()) {
            // Cap concurrent tar+gzip streams so a few cheap GETs can't pin every core on
            // large trees (a whole served dir, the ~194 GB dev stack included, is a legal
            // target and streams without buffering): MAX_ARCHIVE_TAR in all, fewer per client.
            // Fail politely (503 + Retry-After) before writing 200 headers.
            const tarIp = clientIp(req) || 'local';
            if (archiveTarInFlight >= MAX_ARCHIVE_TAR || (archiveTarByIp.get(tarIp) || 0) >= MAX_ARCHIVE_TAR_PER_IP) {
                res.writeHead(503, { 'Content-Type': 'text/plain', 'Retry-After': '10', ...SECURITY_HEADERS });
                return res.end('Too many concurrent archive downloads — please retry shortly.\n');
            }
            archiveTarInFlight++;
            archiveTarByIp.set(tarIp, (archiveTarByIp.get(tarIp) || 0) + 1);
            let tarReleased = false;
            const releaseTar = () => { if (tarReleased) return; tarReleased = true; archiveTarInFlight--;
                const n = (archiveTarByIp.get(tarIp) || 1) - 1;
                if (n <= 0) archiveTarByIp.delete(tarIp); else archiveTarByIp.set(tarIp, n);
            };
            res.writeHead(200, {
                'Content-Type': 'application/gzip',
                'Content-Disposition': `attachment; filename="${base}.tar.gz"`,
                ...SECURITY_HEADERS,
            });
            const tar = spawn('tar', ['-czf', '-', '-C', path.dirname(target), base]);
            tar.stdout.pipe(res);
            tar.on('error', () => { releaseTar(); try { res.destroy(); } catch (_) {} });
            tar.on('close', releaseTar);          // normal exit, error, or req-close kill — always freed
            req.on('close', () => { try { tar.kill(); } catch (_) {} });
        } else {
            sendFile(res, req, target, stat, {
                'Content-Type': 'application/octet-stream',
                'Content-Disposition': `attachment; filename="${base}"`,
            });
        }
    });
}

function serveDirectory(res, dirPath) {
    const entries = readdirSafe(dirPath);
    const relativePath = dirPath.replace(ROOT, '').replace(/^\//, '');
    const relSafe = escapeHtml(relativePath);

    let html = `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Index of /${relSafe}</title>
    <style>body{font-family:system-ui,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;background:#0a0e14;color:#e8edf4}
    a{color:#4da6ff;text-decoration:none}a:hover{text-decoration:underline}
    table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 12px;border-bottom:1px solid #2a3545}
    th{color:#94a3b8}.size{text-align:right;color:#64748b}.dir{color:#4ade80}</style></head>
    <body><h1>Index of /${relSafe}</h1><table><tr><th>Name</th><th class="size">Size</th><th>Modified</th></tr>`;

    // Add parent directory link if not at root
    if (relativePath) {
        const parent = '/' + relativePath.split('/').slice(0, -1).join('/');
        html += `<tr><td><a href="${escapeHtml(encodeURI(parent || '/'))}">..</a></td><td></td><td></td></tr>`;
    }

    // List entries
    for (const name of entries.sort()) {
        if (name.startsWith('.')) continue; // Skip hidden files
        try {
            const fullPath = path.join(dirPath, name);
            const stat = fs.statSync(fullPath);
            const href = '/' + relativePath + (relativePath ? '/' : '') + name;
            const isDir = stat.isDirectory();
            const sizeStr = isDir ? '-' : formatSize(stat.size);
            const dateStr = stat.mtime.toISOString().split('T')[0];
            html += `<tr><td><a href="${escapeHtml(encodeURI(href))}" class="${isDir ? 'dir' : ''}">${escapeHtml(name)}${isDir ? '/' : ''}</a></td><td class="size">${sizeStr}</td><td>${dateStr}</td></tr>`;
        } catch (e) {}
    }

    html += '</table><hr><p style="color:#64748b;font-size:0.85em">Val Ark Server</p></body></html>';

    res.writeHead(200, {
        'Content-Type': 'text/html',
        'Cache-Control': 'no-cache',
        ...SECURITY_HEADERS,
    });
    res.end(html);
}

function formatSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

// Generic same-origin reverse proxy to an internal service on 127.0.0.1:<port>.
// Same-origin means one port to remember and the fixed Val Ark nav stays on
// screen as a "back to the ark" header; we strip embedding-blocker headers so
// the service renders inside our in-page frame. No HTML rewriting — each service
// already serves under its own base path (/kiwix/ or /app/<id>/).
// Community sub-apps are same-origin with the Val Ark UI, so a page they serve can call
// /api/* with a valid Origin (#317). The routes below hand out what USERS uploaded or
// wrote (a file, a raw paste, a mail part), not the app's own UI, so the proxy serves
// them in a sandbox: an opaque origin with no access to the box's cookies, storage or
// API, and nosniff so a text paste can't turn into a page. Matched against the decoded,
// normalized path (the upstream decodes too) and case-insensitively (Express is).
// Any sub-app response carrying Content-Disposition (a file download or preview) gets
// the same treatment, which catches a route this list doesn't know about.
const SUBAPP_SANDBOX_CSP = 'sandbox allow-scripts allow-forms allow-popups allow-downloads';
const SUBAPP_USER_CONTENT = {
    // MicroBin: /file/{id} (?preview=true serves the upload INLINE with a guessed type, so
    // an .html upload renders as a page), /secure_file/{id}, /raw/{id}, /archive/{id}.
    paste: /^\/app\/paste\/(?:file|secure_file|raw|archive)\//i,
    // NodeBB (served under /app/forum): uploads live at /assets/uploads/; /uploads/ redirects.
    forum: /^\/app\/forum\/(?:assets\/uploads|uploads)\//i,
    // The Lounge: /uploads/{name}/{slug} (file uploads) and /storage/ (link-preview cache).
    chat:  /^\/app\/chat\/(?:uploads|storage)\//i,
    // alps: raw message parts, plus its remote-resource proxy and BIMI avatars.
    mail:  /^\/app\/mail\/(?:(?:mailboxes|message)\/.+\/raw|proxy|bimi\/avatar)(?:\/|$)/i,
    // Gitea (#346): site-wide attachments, avatars, package files (npm/PyPI/generic uploads
    // under /api/packages/) and the container registry (/v2/); per repo /{owner}/{repo}/...
    // raw and media (LFS) files, attachments, release downloads, archives, raw wiki pages
    // and the render frame, also via /api/v1/repos/{owner}/{repo}/...; LFS objects (with or
    // without .git); commit/PR/compare .patch and .diff (and the API's git/commits ones),
    // which carry user text as text/plain; and a user's /{name}.keys / .gpg key dumps.
    gitea: new RegExp('^/app/gitea/(?:(?:attachments|avatars|repo-avatars|api/packages|v2)/'
        + '|(?:api/v1/repos/)?[^/]+/[^/]+/(?:raw|media|attachments|releases/download|archive|wiki/raw|render)(?:/|$)'
        + '|[^/]+/[^/]+(?:\\.git)?/info/lfs/'
        + '|[^/]+/[^/]+/(?:commit|pulls|compare)/.+\\.(?:patch|diff)$'
        + '|api/v1/repos/[^/]+/[^/]+/git/commits/[^/]+\\.(?:patch|diff)$'
        + '|[^/]+\\.(?:keys|gpg)$)', 'i'),
};
function isSubAppUserContent(id, urlPath) {
    const re = SUBAPP_USER_CONTENT[id];
    return !!(re && re.test(urlPath));
}
// Drop only the frame-ancestors directive (it would stop the in-page frame) and keep the
// rest of the upstream's policy: a sub-app's own sandbox on its uploads must survive.
function cspWithoutFrameAncestors(v) {
    const one = (s) => String(s).split(';').map((d) => d.trim())
        .filter((d) => d && !/^frame-ancestors(\s|$)/i.test(d)).join('; ');
    const out = (Array.isArray(v) ? v : [v]).map(one).filter(Boolean);
    return out.length ? out : undefined;
}

// opts.subApp: a community sub-app (keep its CSP minus frame-ancestors; sandbox user
// content). Without it (Kiwix) the upstream CSP is dropped as before.
function pipeProxy(req, res, port, label, pathOverride, opts) {
    opts = opts || {};
    // Fresh upstream socket per request (agent:false) + drop hop-by-hop headers.
    // Reusing the default agent's keep-alive sockets races against backends that
    // close idle connections (e.g. NodeBB): a reused half-closed socket throws
    // ECONNRESET → a spurious 503. The race surfaced intermittently only under
    // the added TLS latency of the HTTPS listener. A new socket each time is the
    // standard, robust behaviour for a small reverse proxy like this.
    // Never leak the Val Ark admin session cookie to backend sub-apps (NodeBB, The
    // Lounge, kiwix, …) — they don't need it and could log/exfiltrate the bearer token.
    const fwdHeaders = { ...req.headers, host: `127.0.0.1:${port}` };
    // Identity/forwarding headers are ours to set, never the client's (#386 review): an
    // upstream that trusts loopback (Gitea's REVERSE_PROXY_TRUSTED_PROXIES) would take a
    // forged X-Forwarded-For / X-Real-IP / Forwarded as the peer address, and a header-auth
    // name (X-WEBAUTH-USER, Remote-User) is one config change from a login bypass. Node
    // keeps underscore spellings, so those are matched too.
    for (const k of Object.keys(fwdHeaders)) {
        if (/^(?:x[-_]forwarded[-_]|forwarded$|x[-_]real[-_]ip$|x[-_]webauth[-_]|x?[-_]?remote[-_]user$|true[-_]client[-_]ip$|x[-_]client[-_]ip$|cf[-_]connecting[-_]ip$|x[-_]original[-_])/i.test(k)) delete fwdHeaders[k];
    }
    const peer = clientIp(req);
    if (peer) fwdHeaders['x-forwarded-for'] = peer;
    if (opts.preserveHost && req.headers.host) {
        // The upstream builds absolute links (clone URLs, avatars, API urls) from the Host
        // the browser used, so pass it through (hostAllowed() already vetted it) along with
        // the scheme of the listener the request arrived on, never a client-supplied one.
        fwdHeaders.host = req.headers.host;
        fwdHeaders['x-forwarded-proto'] = req.socket && req.socket.encrypted ? 'https' : 'http';
    }
    if (fwdHeaders.cookie) {
        const kept = fwdHeaders.cookie.split(/;\s*/).filter((c) => c && !/^varksid=/.test(c)).join('; ');
        if (kept) fwdHeaders.cookie = kept; else delete fwdHeaders.cookie;
    }
    const proxyReq = http.request({
        host: '127.0.0.1', port, method: req.method, path: pathOverride || req.url,
        headers: fwdHeaders,
    }, (proxyRes) => {
        const headers = { ...proxyRes.headers };
        delete headers['x-frame-options'];
        if (opts.subApp) {
            const kept = headers['content-security-policy'] !== undefined
                ? cspWithoutFrameAncestors(headers['content-security-policy']) : undefined;
            delete headers['content-security-policy'];
            if (kept) headers['content-security-policy'] = kept;
            if (opts.userContent || headers['content-disposition'] !== undefined) {
                // A second policy is enforced alongside any upstream one (both must pass).
                const list = headers['content-security-policy'] || [];
                headers['content-security-policy'] = [...list, SUBAPP_SANDBOX_CSP];
                headers['x-content-type-options'] = 'nosniff';
            }
        } else {
            delete headers['content-security-policy'];
        }
        res.writeHead(proxyRes.statusCode || 502, headers);
        proxyRes.pipe(res);
    });
    proxyReq.setTimeout(30000, () => proxyReq.destroy(new Error('upstream timeout')));
    proxyReq.on('error', () => {
        if (res.headersSent) return res.end();
        // Friendly page for a browser hitting a service that isn't up yet.
        if ((req.headers.accept || '').includes('text/html')) {
            res.writeHead(503, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache', ...SECURITY_HEADERS });
            // target="_top" so the link escapes the embedding iframe back to the
            // real Val Ark shell, instead of nesting the whole SPA inside the frame.
            return res.end(`<!doctype html><meta charset="utf-8"><body style="font-family:system-ui,sans-serif;background:#0a0e14;color:#e8edf4;padding:40px"><h2>${label || 'This service'} isn't running yet</h2><p>Start it on the Val Ark host (e.g. <code>scripts/services/&lt;name&gt;.sh start</code>), then reload. <a style="color:#4da6ff" target="_top" href="/">&larr; Back to Val Ark</a></p></body>`);
        }
        res.writeHead(502, { 'Content-Type': 'text/plain', ...SECURITY_HEADERS });
        res.end('Proxy error (service unreachable)');
    });
    req.pipe(proxyReq);
}

function proxyKiwix(req, res) {
    if (!kiwixStatus.running) {
        res.writeHead(503, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache', ...SECURITY_HEADERS });
        return res.end('<!doctype html><meta charset="utf-8"><body style="font-family:system-ui,sans-serif;background:#0a0e14;color:#e8edf4;padding:40px"><h2>Offline library is starting…</h2><p>The Kiwix content server auto-starts once at least one <code>.zim</code> file is present. <a style="color:#4da6ff" target="_top" href="/#/content">&larr; Back to Val Ark</a></p></body>');
    }
    pipeProxy(req, res, KIWIX_PORT, 'Offline library');
}

// Community / sub-app services, each run LAN-bound by scripts/services/<id>.sh
// and reverse-proxied here at /app/<id>/ so they live inside the Val Ark shell.
// Ports must match those service scripts. `strip`: true when the upstream serves
// its routes at ROOT and only PREFIXES generated links (MicroBin), so we remove
// the /app/<id> prefix before forwarding; false when the upstream genuinely
// serves under that base path (NodeBB `url`, etc.) and needs the prefix intact.
function envPort(k, d) {
    const n = parseInt(cfg(k, ''), 10);
    return n > 0 && n < 65536 ? n : d;
}
const APP_SERVICES = {
    // Ports follow the same env overrides the service scripts read (default = the script's).
    chat:  { port: envPort('VALARK_CHAT_WEB_PORT', 9000), strip: true },   // The Lounge (web client mounts at root)
    mail:  { port: envPort('VALARK_MAIL_WEB_PORT', 1323), strip: true },   // alps webmail
    forum: { port: envPort('VALARK_FORUM_PORT', 4567), strip: false },     // NodeBB serves under its configured url base
    paste: { port: envPort('PASTE_PORT', 8085), strip: true },             // MicroBin serves at root; PUBLIC_PATH only prefixes links
    // Gitea serves at root; ROOT_URL's /app/gitea/ only prefixes links. preserveHost: its
    // PUBLIC_URL_DETECTION=auto builds absolute URLs from the browser's Host.
    gitea: { port: envPort('VALARK_GITEA_PORT', 3300), strip: true, preserveHost: true },
};
function proxyAppService(req, res, id, urlPath, name) {
    const svc = APP_SERVICES[id];
    if (!svc) return send404(res);
    let targetPath = req.url;
    if (svc.strip) {
        targetPath = req.url.replace(new RegExp('^/app/' + id), '');
        if (!targetPath.startsWith('/')) targetPath = '/' + targetPath;
    }
    pipeProxy(req, res, svc.port, name || id, targetPath,
        { subApp: true, userContent: isSubAppUserContent(id, urlPath || ''), preserveHost: !!svc.preserveHost });
}

// Liveness of each sub-app (so the UI offers "Launch" only when it's actually
// up, and a "how to start" hint otherwise). Probed on demand, cached briefly.
function probePort(port) {
    return new Promise((resolve) => {
        const net = require('net');
        const s = net.connect(port, '127.0.0.1');
        s.setTimeout(800);
        const done = (up) => { try { s.destroy(); } catch {} resolve(up); };
        s.on('connect', () => done(true));
        s.on('error', () => done(false));
        s.on('timeout', () => done(false));
    });
}
// A service is ENABLED when the operator listed it in VALARK_SERVICES (.env), and
// MIRRORED when its binary/source is present in the tools tree for any platform.
// The Community section uses these to offer a one-click Start (only for services
// the operator already opted into + mirrored — never build/mirror on demand).
function serviceEnabled(id) {
    return String(cfg('VALARK_SERVICES', '')).split(/\s+/).filter(Boolean).includes(id);
}
function serviceMirrored(id) {
    for (const plat of ['linux-arm64', 'linux-x86_64', 'macos-arm64', 'windows-x64']) {
        const d = path.join(ROOT, 'tools', plat, id);
        try { if (fs.existsSync(d) && fs.readdirSync(d).length > 0) return true; } catch (_) {}
    }
    return false;
}

// ---- Health page data + one-click self-heal ---------------------------------
// Pure reads of <state> JSON reports (no library bytes). null until the loop has
// written them (a box whose maintenance cycle hasn't finished a first pass).
function readStateJson(name) {
    try { return JSON.parse(fs.readFileSync(path.join(STATE_DIR, name), 'utf8')); } catch (_) { return null; }
}
function getHealthDetail(req) {
    const verify = readStateJson('verify.json');
    const heal = readStateJson('selfheal.json');   // loop.sh write_health (NOT librarian's health.json)
    let events = [];
    try {
        const raw = fs.readFileSync(path.join(STATE_DIR, 'heal-events.jsonl'), 'utf8').trim();
        if (raw) events = raw.split('\n').slice(-25).map(l => { try { return JSON.parse(l); } catch (_) { return null; } })
                             .filter(Boolean).reverse();
    } catch (_) {}
    const sm = safeModeState();
    return { verify, heal, events, safeMode: sm.safeMode, safeModeReasons: sm.reasons, repairRunning: repairInFlight(),
             tailscale: tailscaleMode(), access: boxAddress(req), fill: firstFillState() };
}

// ---- Tailscale userspace-networking check (#311) ----------------------------
// In userspace-networking mode tailscaled has no interface and connects onward from
// 127.0.0.1, so isLocalhost() sees every tailnet peer as the box's own console: the
// Admin. lib/tailscale-mode.sh detects it (read-only, fail-soft) and writes
// <state>/tailscale.json; the loop runs it every cycle (step 2g) and the server runs
// it at startup and every TAILSCALE_CHECK_MS so the Health page doesn't wait for the
// next cycle. We do NOT stop trusting 127.0.0.1 when it fires: on the box both the
// real console and tailscaled's proxied peers come from 127.0.0.1 with nothing in
// the connection that tells them apart reliably (see access-identity.md), and
// refusing all of them would take away the console's recovery path. The critical
// notification tells the operator to fix the box instead.
const TAILSCALE_CHECK_MS = 10 * 60 * 1000;
let _tsCheckRunning = false;
function tailscaleMode() {
    const t = readStateJson('tailscale.json');
    if (!t || typeof t !== 'object' || typeof t.state !== 'string') return null;
    return { state: t.state, userspace: t.userspace === true || t.state === 'userspace',
             evidence: Array.isArray(t.evidence) ? t.evidence.filter(e => typeof e === 'string').slice(0, 5) : [],
             ts: typeof t.ts === 'string' ? t.ts : null };
}
function refreshTailscaleMode() {
    // Tests spawn no helpers unless they hand the detector a stub tailscale CLI.
    if (process.env.VALARK_TEST_NO_SPAWN === '1' && !process.env.VALARK_TAILSCALE_CMD) return;
    if (_tsCheckRunning) return;
    _tsCheckRunning = true;
    // Fixed argv; no request data reaches it.
    execFile('bash', [path.join(__dirname, 'lib', 'tailscale-mode.sh'), 'write', path.join(STATE_DIR, 'tailscale.json')],
        { timeout: 30000 }, (err, stdout) => {
            _tsCheckRunning = false;
            if (!err && /"state":"userspace"/.test(stdout || '')) {
                console.warn('[tailscale] userspace-networking mode: every tailnet peer reaches this server as 127.0.0.1 (the Admin). ' +
                             'Run tailscaled with a kernel TUN, or stop it on this box.');
            }
        });
}

// ---- Notification center (issue #69 slice 1) --------------------------------
// A READ-ONLY aggregation for the web UI's bell/inbox: recent self-heal events
// (heal-events.jsonl) folded together with the current warning/critical conditions
// the health report already knows (Safe Mode, disk almost full, a failed
// functional-verify check, unresolved missing assets). Pure state-file + cached-df
// reads — it NEVER throws on a bare box (no state yet → { items: [] }), adds ZERO
// deps, and is read-gated by the /api/status/ prefix like every other status read.
// Dismiss is client-side (localStorage) for this slice, so the endpoint stays
// read-only; the stable ids below are what make a dismissal persist across reloads.
// Deferred to later slices: routing digests into the box's own mail/board/chat,
// Immediately/Daily/Never frequency, an on-box LED, and server-side (cross-device)
// dismiss state. See docs/design/errors-selfheal.md ("Notifications are offline-native").
const NOTIF_MAX = 60;          // hard cap on returned items (newest kept)
const NOTIF_EVENTS_MAX = 40;   // how many recent heal-events to fold in
function _notifHash(s) {
    // djb2 → short hex. Deterministic and dependency-free; only needs to be stable
    // and collision-resistant enough to key a client-side dismissal, not cryptographic.
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
    return h.toString(16);
}
// Self-heal event kind → severity. The loop only records things it DID (a restart, a
// start, a quarantine) — those are reassuring "handled it for you" info. The lone
// exception is moderation-error: the loop could NOT quarantine a flagged upload, which
// still needs a human, so it rises to a warning.
function _notifEventSeverity(kind) { return kind === 'moderation-error' ? 'warning' : 'info'; }
function _notifEventTitle(kind) {
    switch (kind) {
        case 'restart': return 'Service restarted automatically';
        case 'start': return 'Service started automatically';
        case 'quarantine': return 'Flagged upload quarantined';
        case 'moderation-error': return 'Could not quarantine a flagged upload';
        default: return 'Self-heal action';
    }
}
// Friendly component names for a failed functional-verify check (verify.json comp).
const _NOTIF_COMP_TITLE = { models: 'AI models', apps: 'A tool', library: 'Library', server: 'Web server', integrity: 'File integrity', mesh: 'Fleet mesh' };
const _NOTIF_COMP_LABEL = { models: 'the AI models', apps: 'a mirrored tool', library: 'the offline library', server: 'the web server', integrity: 'file integrity', mesh: 'the fleet mesh' };
function getNotifications() {
    const items = [];
    // 1) Recent self-heal events (append-only jsonl, newest last). Reassuring info,
    //    mostly — the id is a stable content hash so a client-side dismiss sticks.
    try {
        const raw = fs.readFileSync(path.join(STATE_DIR, 'heal-events.jsonl'), 'utf8').trim();
        if (raw) {
            for (const l of raw.split('\n').slice(-NOTIF_EVENTS_MAX)) {
                let o; try { o = JSON.parse(l); } catch (_) { continue; }
                if (!o || !o.kind) continue;
                const ts = o.ts || '', detail = o.detail || '';
                items.push({
                    id: 'ev-' + _notifHash(ts + '|' + o.kind + '|' + detail),
                    ts, severity: _notifEventSeverity(o.kind),
                    title: _notifEventTitle(o.kind), detail, source: 'self-heal',
                });
            }
        }
    } catch (_) {}
    // 2) Current conditions the box knows right now (state files + cached disk). Each
    //    gets a STABLE id keyed on the condition (not a fluctuating value) so a
    //    dismissal persists; a critical escalation carries its OWN id so it re-surfaces.
    const heal = readStateJson('selfheal.json');
    const verify = readStateJson('verify.json');
    const sm = safeModeState();
    const condTs = () => (heal && heal.ts) || (verify && verify.ts) || new Date().toISOString();
    if (sm.safeMode) items.push({ id: 'cond-safemode', ts: condTs(), severity: 'critical',
        title: 'Val Ark is in recovery mode',
        detail: 'The box booted core-only because its settings could not be read. Your content is safe. Open Health to recover and set a new passcode.',
        source: 'config' });
    // Tailscale in userspace-networking mode (#311): every tailnet peer is the Admin.
    const ts = tailscaleMode();
    if (ts && ts.userspace) items.push({ id: 'cond-tailscale-userspace', ts: ts.ts || condTs(), severity: 'critical',
        title: 'Tailscale is giving every tailnet device admin rights',
        detail: 'Tailscale on this box runs in userspace-networking mode, so everyone on your tailnet reaches Val Ark as if they were sitting at the box, and the box is always the Admin. ' +
                'Fix: run tailscaled with a kernel TUN interface (drop --tun=userspace-networking; in a container give it /dev/net/tun and NET_ADMIN), or stop Tailscale on this box.' +
                (ts.evidence.length ? ' Detected: ' + ts.evidence.join('; ') + '.' : ''),
        source: 'security' });
    // A tailscaled the detector found but couldn't check (in a container whose network
    // namespace it can't read): a warning to look, never the critical alarm.
    else if (ts && ts.state === 'unknown' && ts.evidence.length) items.push({ id: 'cond-tailscale-unknown', ts: ts.ts || condTs(), severity: 'warning',
        title: 'Could not check how Tailscale is set up',
        detail: 'A Tailscale daemon is running that this box could not inspect (' + ts.evidence.join('; ') + '). ' +
                'If it shares this box\'s network and runs in userspace-networking mode, every tailnet device would reach Val Ark as the Admin. Make sure it uses a kernel TUN interface.',
        source: 'security' });
    // Disk almost full — same thresholds the Health page uses (>=97 act now, >=90 filling up).
    let diskPct = null;
    try { const d = getDiskStatus(); if (d && d.total) diskPct = d.used / d.total * 100; } catch (_) {}
    if (diskPct != null) {
        const p = Math.round(diskPct);
        if (diskPct >= 97) items.push({ id: 'cond-disk-critical', ts: condTs(), severity: 'critical',
            title: 'Disk almost full', detail: 'The disk is ' + p + '% full. Free some space so downloads and services keep working.', source: 'storage' });
        else if (diskPct >= 90) items.push({ id: 'cond-disk-warning', ts: condTs(), severity: 'warning',
            title: 'Disk filling up', detail: 'The disk is ' + p + '% full. The librarian makes room by evicting the lowest-priority content automatically.', source: 'storage' });
    }
    // A functional-verify check that failed — self-heal re-verifies, so it's a yellow
    // "working on it", one deduped item per affected component.
    if (verify && Array.isArray(verify.checks)) {
        const failed = [...new Set(verify.checks.filter(c => c && c.status === 'FAIL' && c.comp).map(c => c.comp))];
        for (const comp of failed) items.push({ id: 'cond-verify-' + comp, ts: condTs(), severity: 'warning',
            title: (_NOTIF_COMP_TITLE[comp] || comp) + ' self-check failed',
            detail: 'A functional check for ' + (_NOTIF_COMP_LABEL[comp] || comp) + ' did not pass. Self-heal re-verifies every cycle; if it persists the file may be re-downloading.',
            source: 'self-heal' });
    }
    // Missing linked files the loop hasn't re-linked yet — a genuine box residue.
    if (heal && typeof heal.missingAssets === 'number' && heal.missingAssets > 0) items.push({
        id: 'cond-missing-assets', ts: condTs(), severity: 'warning',
        title: heal.missingAssets + ' file' + (heal.missingAssets === 1 ? '' : 's') + ' need re-linking',
        detail: 'The last self-check found ' + heal.missingAssets + ' missing linked file(s). The loop re-links them automatically on the next cycle.',
        source: 'self-heal' });
    // Newest first; a severity tiebreak floats criticals above equal-timestamped info.
    const rank = { critical: 3, warning: 2, info: 1 };
    items.sort((a, b) => (b.ts || '').localeCompare(a.ts || '') || (rank[b.severity] || 0) - (rank[a.severity] || 0));
    return { items: items.slice(0, NOTIF_MAX), ts: new Date().toISOString() };
}

// ---- Live host metrics (Health page System tiles) ---------------------------
// Pure local reads — /proc + the os module + the 10s-cached getDiskStatus() — so it's
// instant, needs NO npm deps and NO external service (Telegraf/InfluxDB add history on
// top later, they are not required here), and NEVER throws: every field degrades to null
// off-Linux or when a source is missing. CPU% and net rate are two-sample deltas; the
// client's 15s Health poll spaces the samples (first read → null, filled next poll).
function _readProc(p) { try { return fs.readFileSync(p, 'utf8'); } catch (_) { return null; } }
function _readMem() {
    const os = require('os');
    const mi = _readProc('/proc/meminfo');
    if (mi) {
        const g = (k) => { const m = mi.match(new RegExp('^' + k + ':\\s+(\\d+)\\s*kB', 'm')); return m ? parseInt(m[1], 10) * 1024 : null; };
        const total = g('MemTotal'), avail = g('MemAvailable'), free = g('MemFree');
        const swapTotal = g('SwapTotal'), swapFree = g('SwapFree');
        // used = total - available (NOT total-free: free excludes reclaimable cache and
        // would overstate "used"). Same reason we don't lean on os.freemem() below.
        if (total && avail != null) {
            const used = total - avail;
            return { total, used, available: avail, free, percent: Math.round(used / total * 100),
                     swapTotal, swapUsed: (swapTotal != null && swapFree != null) ? swapTotal - swapFree : null };
        }
    }
    try {
        const total = os.totalmem(), free = os.freemem();
        if (total) { const used = total - free; return { total, used, available: free, free, percent: Math.round(used / total * 100), swapTotal: null, swapUsed: null }; }
    } catch (_) {}
    return null;
}
function _readTemp() {
    try {
        const base = '/sys/class/thermal';
        let max = null;
        for (const z of fs.readdirSync(base)) {
            if (!/^thermal_zone\d+$/.test(z)) continue;
            const raw = _readProc(path.join(base, z, 'temp'));
            if (raw == null) continue;
            const v = parseInt(raw.trim(), 10);
            if (!isNaN(v)) { const c = v / 1000; if (max == null || c > max) max = c; }
        }
        return max != null ? Math.round(max * 10) / 10 : null;
    } catch (_) { return null; }
}
// prev = the caller's previous counter sample (defaults to the live endpoint's
// _metricsPrev). Computes CPU%/net-rate deltas against `prev` and returns the fresh
// counters as a NON-enumerable out._sample (never serialized) so each caller — the
// live endpoint and the history sampler — keeps its OWN baseline and they can't
// contend over one shared global.
function getHostMetrics(prev = _metricsPrev, opts = {}) {
    const os = require('os');
    const now = Date.now();
    const out = { ts: new Date().toISOString(), source: 'live' };

    try { out.host = { hostname: os.hostname(), arch: os.arch(), platform: os.platform(), release: os.release(), uptime: Math.round(os.uptime()) }; }
    catch (_) { out.host = null; }

    // CPU%: two /proc/stat samples (idle = idle+iowait, total = sum of all fields).
    let cpuPercent = null, statNow = null;
    const stat = _readProc('/proc/stat');
    if (stat) {
        const line = stat.split('\n').find(l => /^cpu\s/.test(l));
        if (line) {
            const parts = line.trim().split(/\s+/).slice(1).map(Number);
            const idle = (parts[3] || 0) + (parts[4] || 0);
            const total = parts.reduce((a, b) => a + (b || 0), 0);
            statNow = { idle, total };
            if (prev.stat) {
                const dt = total - prev.stat.total, di = idle - prev.stat.idle;
                if (dt > 0) cpuPercent = Math.max(0, Math.min(100, Math.round((1 - di / dt) * 100)));
            }
        }
    }
    let cores = null, model = null, loadavg = null;
    try { const c = os.cpus() || []; cores = c.length || null; model = c[0] ? c[0].model : null; } catch (_) {}
    try { const la = os.loadavg(); loadavg = (Array.isArray(la) && (la[0] || la[1] || la[2])) ? la.map(n => Math.round(n * 100) / 100) : null; } catch (_) {}
    out.cpu = { cores, model, loadavg, percent: cpuPercent };

    out.mem = _readMem();

    // opts.disk === false skips getDiskStatus() entirely — its execSync('df') can BLOCK
    // the event loop up to 5s on a stale NFS mount. The self-sampler passes disk:false
    // (its ring row has no disk field), so it stays truly /proc+os-only and never stalls.
    if (opts.disk === false) { out.disk = null; }
    else {
        try { const d = getDiskStatus(); out.disk = (d && d.total) ? { total: d.total, used: d.used, available: d.available, percent: Math.round(d.used / d.total * 100) } : null; }
        catch (_) { out.disk = null; }
    }

    // Net: rx/tx summed across non-lo interfaces + rate over MEASURED elapsed. Guard the
    // cumulative-counter wrap/reset (Δ<0 → null); first sample → null.
    let netNow = null, rxRate = null, txRate = null;
    const nd = _readProc('/proc/net/dev');
    if (nd) {
        let rx = 0, tx = 0, seen = false;
        for (const l of nd.split('\n')) {
            const m = l.match(/^\s*([^:]+):\s*(.*)$/);
            if (!m || m[1].trim() === 'lo') continue;
            const f = m[2].trim().split(/\s+/).map(Number);
            if (f.length >= 9) { rx += f[0] || 0; tx += f[8] || 0; seen = true; }
        }
        if (seen) {
            netNow = { rx, tx };
            if (prev.net && prev.ts) {
                const secs = (now - prev.ts) / 1000;
                if (secs > 0) {
                    const drx = rx - prev.net.rx, dtx = tx - prev.net.tx;
                    rxRate = drx >= 0 ? Math.round(drx / secs) : null;
                    txRate = dtx >= 0 ? Math.round(dtx / secs) : null;
                }
            }
        }
    }
    out.net = netNow ? { rxBytes: netNow.rx, txBytes: netNow.tx, rxRate, txRate } : null;

    out.temp = _readTemp();

    Object.defineProperty(out, '_sample', { value: { stat: statNow, net: netNow, ts: now }, enumerable: false });
    return out;
}

// ---- Metrics history: a zero-dep on-disk ring buffer (default history layer) ----
// The always-on server samples its OWN getHostMetrics() into a capped in-memory ring
// (persisted to state/metrics-history.jsonl for cross-restart continuity) and serves it
// at GET /api/status/metrics/history for the Health page's sparklines. No daemon, no
// token, no npm dep, no outbound call — works on a bare box. InfluxDB/Telegraf are a
// deferred, opt-in Advanced/fleet upgrade grafted onto the same endpoint later.
const _METRICS_RING_CAP = 2880;                 // ~24h at the default 30s cadence
const _METRICS_HISTORY_FILE = path.join(STATE_DIR, 'metrics-history.jsonl');
let _metricsRing = [];
let _samplerPrev = { stat: null, net: null, ts: 0 };   // the sampler's OWN baseline
let _ringPersistedAt = 0;

function _loadMetricsRing() {
    try {
        const raw = fs.readFileSync(_METRICS_HISTORY_FILE, 'utf8').trim();
        if (raw) _metricsRing = raw.split('\n').slice(-_METRICS_RING_CAP)
            .map(l => { try { return JSON.parse(l); } catch (_) { return null; } })
            .filter(r => r && typeof r.t === 'number');
    } catch (_) { /* absent on a fresh box — that's the normal case */ }
}
// Sample once: PROC/os-only (NO getDiskStatus/df — dodges the 10s disk cache + stale-NFS
// hang), append a compact row, cap in memory, atomically persist. Never throws.
function sampleMetricsToRing() {
    try {
        const m = getHostMetrics(_samplerPrev, { disk: false });   // disk:false → no blocking df
        _samplerPrev = m._sample || _samplerPrev;
        const cpu = m.cpu || {}, mem = m.mem || {}, net = m.net || {};
        _metricsRing.push({
            t: Date.now(),
            cpu: (typeof cpu.percent === 'number') ? cpu.percent : null,
            mem: (typeof mem.percent === 'number') ? mem.percent : null,
            load: (cpu.loadavg && cpu.loadavg.length) ? cpu.loadavg[0] : null,
            rx: (net && typeof net.rxRate === 'number') ? net.rxRate : null,
            tx: (net && typeof net.txRate === 'number') ? net.txRate : null,
            temp: (typeof m.temp === 'number') ? m.temp : null,
        });
        if (_metricsRing.length > _METRICS_RING_CAP) _metricsRing = _metricsRing.slice(-_METRICS_RING_CAP);
        // Throttle disk writes to ~ every 5th sample; atomic tmp+rename.
        const now = Date.now();
        if (now - _ringPersistedAt >= 4 * Number(cfg('VALARK_METRICS_SAMPLE_MS', '30000'))) {
            _ringPersistedAt = now;
            const tmp = _METRICS_HISTORY_FILE + '.tmp';
            fs.writeFileSync(tmp, _metricsRing.map(r => JSON.stringify(r)).join('\n') + '\n');
            fs.renameSync(tmp, _METRICS_HISTORY_FILE);
        }
    } catch (_) { /* read-only/absent STATE_DIR → skip this tick, never crash the server */ }
}
// ?window → a fixed point cap (allowlist-mapped; the client string never indexes/slices
// or reaches a path). Down-sample to at most ~150 points for a compact sparkline.
const _METRICS_WINDOWS = { hour: 120, '6h': 720, day: _METRICS_RING_CAP };
function getMetricsHistory(window) {
    const cap = _METRICS_WINDOWS[window] || _METRICS_WINDOWS.hour;
    let rows = _metricsRing.slice(-cap);
    const MAX_POINTS = 150;
    if (rows.length > MAX_POINTS) {
        const step = Math.ceil(rows.length / MAX_POINTS);
        rows = rows.filter((_, i) => i % step === 0);
    }
    return { source: 'ring', window: (_METRICS_WINDOWS[window] ? window : 'hour'), count: rows.length, series: rows };
}

// "Run self-heal now": kick the maintenance loop's own fixers (loop.sh once) — repairs
// the symlink layout, ensures web/kiwix/community services are up, re-resolves stale
// links, tops up, re-verifies. FIXED argv (no user input reaches the shell). loop.sh
// self-guards with a flock, so a concurrent cron cycle just makes this exit cleanly; we
// also dedupe rapid clicks in-process and rate-limit to one manual run per 30s.
let _repairProc = null, _repairStartedAt = 0;
function repairInFlight() { return !!_repairProc || (Date.now() - _repairStartedAt < 5000); }
// ---- On-device content moderation (roadmap Phase 7) --------------------------
// The web door to scripts/lib/moderation.sh: screen a piece of content with the box's
// own AI, offline, FAIL-CLOSED. The decision core lives in the shell script (tested in
// isolation); this only marshals bytes in and a verdict out. Every rule the script
// enforces (magic-byte typing, size cap, hold-on-anything-unusable) is preserved here.
const MOD_SCRIPT = path.join(__dirname, 'lib', 'moderation.sh');
const MOD_CHECK_MAX = Number(process.env.VALARK_MODERATION_MAX_BYTES) || 25 * 1024 * 1024;  // matches moderation.sh MOD_MAX_BYTES
const MOD_TIMEOUT_S = Number(process.env.VALARK_MODERATION_TIMEOUT) || 150;
// Concurrency budget for /api/moderation/check. The per-IP rate limiter bounds the
// admission RATE (30/min) but NOT how many checks run at once, and each buffers up to
// MOD_CHECK_MAX (25 MiB) in memory then spawns a classifier child — so a burst of slow
// uploads (one peer, or many) could pin unbounded RAM/CPU and OOM a small ARM node. Cap
// both the number of concurrent checks AND the cumulative in-flight bytes. Over budget →
// fail-closed {decision:'hold'} + 503 Retry-After (Phase-7 semantics: never an implicit
// allow). Held from body-read through the classifier callback, so it bounds children too.
const MOD_MAX_CONCURRENT = Number(process.env.VALARK_MODERATION_MAX_CONCURRENT) || 4;
const MOD_MAX_INFLIGHT_BYTES = Number(process.env.VALARK_MODERATION_MAX_INFLIGHT) || 3 * MOD_CHECK_MAX;
let modInFlight = 0, modInFlightBytes = 0;
// Where screened bytes are staged. A dedicated 0700 dir under <state>; each scan file is
// 0600, random-named, realpath-confined, and unlinked the instant the runner returns.
const MOD_SCAN_DIR = path.join(STATE_DIR, 'moderation', 'scan');

// Classifier-readiness probe result, CACHED. `moderation.sh ready` runs `find` over the
// mirror, which can take seconds on a big disk — so it must NEVER block the single Node
// event loop on the hot status path. We refresh it ASYNC and serve the cached value; the
// only synchronous probe is a one-time cold warm (so the very first status is accurate).
let _modReady = { ts: 0, ready: false, text: false, image: false, reason: 'unknown' };
let _modReadyBusy = false;
const MOD_READY_TTL = 30000;
function _parseReady(raw) {
    try {
        const v = JSON.parse(String(raw || '').trim().split('\n').filter(Boolean).pop() || '{}');
        if (v && typeof v === 'object') return { ready: !!v.ready, text: !!v.text, image: !!v.image, reason: v.reason || '' };
    } catch (_) {}
    return null;   // unparseable → caller keeps fail-closed default
}
function _refreshModReady() {
    if (_modReadyBusy || Date.now() - _modReady.ts < MOD_READY_TTL) return;   // fresh enough / already probing
    _modReadyBusy = true;
    let out = '', child;
    try {
        child = spawn('/usr/bin/bash', [MOD_SCRIPT, 'ready'], {
            stdio: ['ignore', 'pipe', 'ignore'],
            env: { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || '') },
        });
    } catch (_) { _modReadyBusy = false; return; }
    const killer = setTimeout(() => { try { child.kill('SIGKILL'); } catch (_) {} }, 8000);
    child.stdout.on('data', (d) => { out += d; if (out.length > 8192) out = out.slice(-8192); });
    child.on('error', () => { clearTimeout(killer); _modReadyBusy = false; });
    child.on('close', () => {
        clearTimeout(killer); _modReadyBusy = false;
        const p = _parseReady(out) || { ready: false, text: false, image: false, reason: 'probe error' };
        _modReady = { ts: Date.now(), ...p };
    });
}
// Health card for the admin Safety panel + the loop. Read-only, cheap: never runs
// inference. Serves the cached readiness (warmed synchronously once, then async).
function getModerationStatus() {
    if (_modReady.ts === 0) {
        // Cold warm: one bounded synchronous probe so the first status is truthful.
        try {
            const r = spawnSync('/usr/bin/bash', [MOD_SCRIPT, 'ready'], {
                timeout: 8000, encoding: 'utf8',
                env: { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || '') },
            });
            const p = _parseReady(r.stdout);
            _modReady = { ts: Date.now(), ...(p || { ready: false, text: false, image: false, reason: 'probe error' }) };
        } catch (_) { _modReady = { ts: Date.now(), ready: false, text: false, image: false, reason: 'probe error' }; }
    } else {
        _refreshModReady();   // async, non-blocking
    }
    const cfg = commission.getModeration(STATE_DIR);
    const runner = _modReady;
    return {
        enabled: cfg.enabled,
        sensitivity: cfg.sensitivity,
        surfaces: cfg.surfaces,
        action: cfg.action,
        runnerReady: !!runner.ready,
        classifiers: { text: !!runner.text, image: !!runner.image },
        // Honest effective state: ON without a model does NOT mean content flows — the
        // core holds everything for review. Surface that so "on" is never misread as "safe".
        effective: cfg.enabled ? (runner.ready ? 'screening' : 'holding (no model installed)') : 'off',
    };
}

// Boot-time sweep of leaked scan temps (a process killed between staging and unlink
// leaves screened content at rest). Only runs at startup, when nothing is in-flight, so
// removing every entry is safe. Best-effort + quiet: a missing dir is the common case.
function sweepModerationScan() {
    let entries;
    try { entries = fs.readdirSync(MOD_SCAN_DIR); } catch (_) { return; }   // no dir → nothing to sweep
    let swept = 0;
    for (const name of entries) {
        try { fs.unlinkSync(path.join(MOD_SCAN_DIR, name)); swept++; } catch (_) {}
    }
    if (swept) console.log(`[moderation] swept ${swept} stale scan temp(s) at startup`);
}

// Reduce a runner's stdout+exit to a verdict object, FAIL-CLOSED. Anything we can't
// parse into a real decision string → hold (never allow). The temp is always unlinked.
function _runModeration(buf, kind, sens, cb) {
    let tmp = null;
    try {
        // Confine the staged file against the INTENDED base, not against itself. STATE_DIR
        // is legitimately a symlink into the data disk, so resolve it; but the `moderation`
        // and `scan` components must NOT be symlinks (a co-resident same-uid process — or a
        // fleet node over the NFS-exported state tree — could otherwise plant one to redirect
        // our write, and up to 25 MiB of attacker bytes, outside quarantine). Reject a
        // symlinked component, then require the resolved scan dir to equal the expected path.
        const stateReal = fs.realpathSync(STATE_DIR);
        const modDir = path.join(stateReal, 'moderation');
        const scanDir = path.join(modDir, 'scan');
        for (const d of [modDir, scanDir]) {
            let st = null; try { st = fs.lstatSync(d); } catch (_) {}
            if (st && st.isSymbolicLink()) return cb({ decision: 'hold', reason: 'quarantine path is a symlink' });
        }
        fs.mkdirSync(scanDir, { recursive: true, mode: 0o700 });
        if (fs.realpathSync(scanDir) !== scanDir) return cb({ decision: 'hold', reason: 'quarantine path escaped <state>' });
        const cand = path.join(scanDir, crypto.randomBytes(18).toString('hex') + '.bin');
        fs.writeFileSync(cand, buf, { mode: 0o600, flag: 'wx' });   // wx: never follow/clobber an existing node
        tmp = cand;
    } catch (_) {
        return cb({ decision: 'hold', reason: 'could not stage content' });
    }
    const done = (out) => { try { if (tmp) fs.unlinkSync(tmp); } catch (_) {} cb(out); };
    const args = [MOD_SCRIPT, 'check', tmp];
    if (kind && kind !== 'auto') args.push('--kind', kind);
    if (sens) args.push('--sensitivity', sens);
    let child, out = '', settled = false;
    const settle = (o) => { if (settled) return; settled = true; done(o); };
    try {
        // ARGV array (never a shell string) — tmp is our own random path, but the argv
        // form means even a hostile filename could never break out of an arg slot.
        child = spawn('/usr/bin/bash', args, {
            stdio: ['ignore', 'pipe', 'ignore'],
            env: { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || '') },
        });
    } catch (_) { return settle({ decision: 'hold', reason: 'runner spawn failed' }); }
    // Wall-clock backstop above the script's own timeout, so a wedged child can't pin
    // the request open forever. On fire → SIGKILL → 'close' settles us to hold.
    const killer = setTimeout(() => { try { child.kill('SIGKILL'); } catch (_) {} }, (MOD_TIMEOUT_S + 20) * 1000);
    child.stdout.on('data', (d) => { out += d; if (out.length > 65536) out = out.slice(-65536); });
    child.on('error', () => { clearTimeout(killer); settle({ decision: 'hold', reason: 'runner error' }); });
    child.on('close', () => {
        clearTimeout(killer);
        const line = out.trim().split('\n').filter(Boolean).pop() || '';
        let v = null;
        try { v = JSON.parse(line); } catch (_) {}
        if (!v || typeof v.decision !== 'string' || !['allow', 'block', 'hold'].includes(v.decision)) {
            return settle({ decision: 'hold', reason: 'unreadable classifier output' });
        }
        settle({ decision: v.decision, reason: v.reason || '', kind: v.kind || kind, score: (v.score == null ? null : v.score) });
    });
}

// POST /api/moderation/check — screen the RAW request body (the bytes ARE the content).
// Its OWN size-capped reader, NOT readBody (that caps at 64KB + JSON-parses). Always
// answers with a {decision} the caller can act on. Gate stack (isLanOrTailnet + rateLimit
// + commissioned + auth-per-UseMode) already ran.
//
// The caller does NOT get to weaken screening: the content TYPE is decided by magic bytes
// inside moderation.sh (kind='auto'), never a client hint — a ?kind=text on image bytes
// would otherwise route them to the text classifier (which can't see the image) and pass.
// SENSITIVITY is the ADMIN's configured policy, never caller-tunable — a caller could
// otherwise ask for 'lenient' and turn a score-based hold into an allow.
function handleModerationCheck(req, res) {
    const cfg = commission.getModeration(STATE_DIR);
    // OFF = "no opinion", explicitly NOT allow-by-policy. Callers must not read a disabled
    // engine as approval; they get decision:'skip' + enabled:false and decide for themselves.
    if (!cfg.enabled) return sendJSON(res, req, { decision: 'skip', enabled: false, reason: 'moderation disabled' });

    // On an early refusal we never read the body — tear the socket down once the reply
    // flushes so a client still streaming a huge payload can't keep it half-read on the
    // keep-alive connection (a synchronous destroy would truncate the reply first).
    const refuse = (obj, code) => {
        res.on('finish', () => { try { req.destroy(); } catch (_) {} });
        return sendJSON(res, req, obj, code);
    };
    // Reject a DECLARED oversize body before buffering a single byte (backstop; the
    // streaming guard below still catches chunked / lying Content-Length uploads).
    const clen = Number(req.headers['content-length']);
    if (Number.isFinite(clen) && clen > MOD_CHECK_MAX) {
        return refuse({ decision: 'hold', reason: 'content exceeds size cap' }, 413);
    }
    // Admission control: refuse (fail-closed hold) when too many checks are already in
    // flight or the cumulative buffered bytes are at the ceiling. This is what actually
    // bounds memory/child-process fan-out — the rate limiter only paces admissions.
    if (modInFlight >= MOD_MAX_CONCURRENT || modInFlightBytes >= MOD_MAX_INFLIGHT_BYTES) {
        res.setHeader('Retry-After', '5');
        return refuse({ decision: 'hold', reason: 'moderation busy — retry shortly' }, 503);
    }

    const kind = 'auto', sens = cfg.sensitivity;   // type = magic bytes; sensitivity = admin policy

    const chunks = []; let size = 0, over = false, ended = false;
    let myBytes = 0, classifierStarted = false, released = false;
    modInFlight++;
    // Give back this request's slot + buffered-byte contribution exactly once, on ANY
    // terminal path (overflow, budget, error, empty, client disconnect, classifier done).
    const release = () => { if (released) return; released = true; modInFlight--; modInFlightBytes -= myBytes; myBytes = 0; };
    // Fail-closed teardown after the response flushes (a synchronous req.destroy() can
    // truncate the reply into an ECONNRESET instead of the clean hold the caller expects).
    const holdAndClose = (obj, code) => {
        over = true;
        res.on('finish', () => { try { req.destroy(); } catch (_) {} });
        sendJSON(res, req, obj, code);
        release();
    };
    req.on('data', (c) => {
        if (over || ended) return;
        size += c.length;
        if (size > MOD_CHECK_MAX) return holdAndClose({ decision: 'hold', reason: 'content exceeds size cap' }, 413);
        // Count each buffered chunk against the global in-flight budget; a mid-stream
        // crossing (concurrent uploads racing up together) also fails closed.
        myBytes += c.length; modInFlightBytes += c.length;
        chunks.push(c);
        if (modInFlightBytes > MOD_MAX_INFLIGHT_BYTES) {
            res.setHeader('Retry-After', '5');
            return holdAndClose({ decision: 'hold', reason: 'moderation busy — retry shortly' }, 503);
        }
    });
    req.on('error', () => { if (!over && !ended) { ended = true; if (!res.headersSent) sendJSON(res, req, { decision: 'hold', reason: 'read error' }, 200); } release(); });
    // Client vanished mid-upload (slow-loris drop) before we handed off to the classifier
    // → free the slot now. Once the classifier is running its callback owns the release.
    req.on('close', () => { if (!classifierStarted) release(); });
    req.on('end', () => {
        if (over || ended) return;
        ended = true;
        const buf = Buffer.concat(chunks);
        if (buf.length === 0) { release(); return sendJSON(res, req, { decision: 'hold', reason: 'empty content' }, 400); }
        classifierStarted = true;
        _runModeration(buf, kind, sens, (out) => { release(); sendJSON(res, req, out, 200); });
    });
}

// ---- Review queue (Safety card) ----------------------------------------------------
// The sweep appends each quarantined item to queue.jsonl; a review action (remove /
// dismiss) is recorded in reviewed.jsonl so the queue log stays append-only.
// An item's ID is its quarantine BASENAME (unique, contains no separators) — it both
// correlates the two logs AND confines the file operation to the quarantine dir.
function _modQueueFiles() {
    const base = path.join(STATE_DIR, 'moderation');
    return { q: path.join(base, 'queue.jsonl'), r: path.join(base, 'reviewed.jsonl'), qdir: path.join(base, 'quarantine') };
}
function _readJsonl(file) {
    const out = [];
    let raw; try { raw = fs.readFileSync(file, 'utf8'); } catch (_) { return out; }
    for (const line of raw.split('\n')) { if (!line.trim()) continue; try { out.push(JSON.parse(line)); } catch (_) {} }
    return out;
}
// The full pending set (queue.jsonl minus reviewed.jsonl), newest first. The existence
// check MUST use this, not a display slice, or items past the cap become un-actionable.
function _modPending() {
    const { q, r } = _modQueueFiles();
    const resolved = new Set(_readJsonl(r).map((o) => o.id).filter(Boolean));
    const pending = [];
    for (const o of _readJsonl(q)) {
        const id = o.quarantine ? path.basename(String(o.quarantine)) : null;
        if (!id || resolved.has(id)) continue;
        pending.push({ id, path: o.path || '', decision: o.decision || 'hold', reason: o.reason || '', ts: o.ts || 0 });
    }
    pending.reverse();   // newest first
    return pending;
}
function getModerationQueue() {
    const pending = _modPending();
    return { pending: pending.slice(0, 200), count: pending.length };
}
// Act on a held item. Deliberately only remove / dismiss — both provably safe. RESTORE
// (writing a quarantined file back to a store path) is intentionally NOT here: its
// destination comes from queue.jsonl, and under this project's own threat model (a
// same-uid process or an NFS-mesh peer can append to that in-<state> log) an unconfined
// write-back is an arbitrary-file-write / RCE vector. A store-root-confined + O_NOFOLLOW
// restore is a documented follow-up; until then an admin releases a false positive on the
// box itself. (See docs/knowledge/decisions.md, Phase 7.)
function reviewModerationItem(body) {
    body = body || {};
    const id = String(body.id || '');
    const action = String(body.action || '');
    // ID must be a bare basename — no separators / traversal. This is what confines the
    // file op to the quarantine dir (the sweep only ever wrote basenames there).
    if (!id || id !== path.basename(id) || id === '.' || id === '..' || /[/\\]/.test(id)) return { error: 'Invalid item id.' };
    if (!['remove', 'dismiss'].includes(action)) return { error: 'Invalid action.' };
    const { r, qdir } = _modQueueFiles();
    // Existence check against the FULL pending set (not the 200-item display slice).
    if (!_modPending().some((p) => p.id === id)) return { error: 'Item not found in the review queue.' };

    if (action === 'remove') {
        // unlinkSync removes the quarantine entry ITSELF — it never follows a final
        // symlink — and the basename-confined id keeps it inside the quarantine dir, so a
        // bare delete cannot touch anything the symlink might point at.
        try { fs.unlinkSync(path.join(qdir, id)); } catch (_) { /* already gone — fine */ }
    }
    // dismiss: leave the quarantined file in place, just mark the item reviewed.
    try {
        fs.mkdirSync(path.dirname(r), { recursive: true });
        fs.appendFileSync(r, JSON.stringify({ id, action, ts: Math.floor(Date.now() / 1000) }) + '\n');
    } catch (_) {}
    return { ok: true, id, action };
}

// Best-effort: when moderation is switched ON and no classifier is installed, pin+fetch
// the text safety model (Llama-Guard-3) via the librarian so real screening can begin.
// Until it lands the core FAIL-CLOSED holds content rather than pass it. Detached +
// idempotent (librarian `request` pins, skips already-present, auto-evicts to fit the
// cap); never blocks the settings write, and self-throttles against toggle storms.
let _modPinAt = 0;
function ensureModerationModel() {
    if (process.env.VALARK_TEST_NO_SPAWN === '1') return;   // tests exercise the gate, not the fetch
    if (Date.now() - _modPinAt < 600000) return;            // at most one kick per 10 min
    // Skip the pin if the cached probe already saw a classifier — no synchronous ready
    // probe here (this runs inside a request handler; librarian `request` is itself
    // idempotent — it pins, skips already-present items, and auto-evicts to fit the cap).
    if (_modReady.ready && Date.now() - _modReady.ts < MOD_READY_TTL) return;
    _modPinAt = Date.now();
    try {
        const p = spawn('/usr/bin/bash', [path.join(ROOT, 'scripts/librarian.sh'), 'request', 'model', 'llama-guard-3-8b-gguf'], {
            cwd: ROOT, detached: true, stdio: 'ignore',
            env: { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || ''), FORCE_COLOR: '0' },
        });
        p.unref();
    } catch (_) {}
}

// loop.sh is always run through this fixed wrapper: `bash -c 'exec 8>&- && exec "$0" "$@"'
// bash loop.sh <verb> [arg]`. The wrapper string and every argv element are constants
// (verb ∈ once/install, arg = '30'); no request data reaches it. `exec 8>&-` closes fd 8
// in case this server inherited loop.lock (a long-lived child holding that fd would
// keep the loop's cycle lock forever — scripts/AGENTS.md). VALARK_TEST_LOOP_SH is a
// test seam: a stub that records its argv instead of running a real cycle.
const BASH_BIN = fs.existsSync('/usr/bin/bash') ? '/usr/bin/bash' : '/bin/bash';
const LOOP_WRAP = 'exec 8>&- && exec "$0" "$@"';
function _loopSh() { return process.env.VALARK_TEST_LOOP_SH || path.join(ROOT, 'scripts/loop.sh'); }
function _loopArgv(verb) {
    const extra = verb === 'install' ? ['install', '30'] : ['once'];
    return ['-c', LOOP_WRAP, BASH_BIN, _loopSh(), ...extra];
}
function _loopEnv() {
    return { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || ''), FORCE_COLOR: '0' };
}
// Test hook: exercise the gate + dedupe contract without actually running the loop
// (heavy + network). Fail-safe like VALARK_TEST_FORCE_REMOTE — it only PREVENTS the
// action; the auth gate still fully applies, so it can never grant access.
function _noLoopSpawn() { return process.env.VALARK_TEST_NO_SPAWN === '1' && !process.env.VALARK_TEST_LOOP_SH; }

function triggerRepair() {
    if (_repairProc) return { ok: true, started: false, running: true };
    if (Date.now() - _repairStartedAt < 30000) return { ok: true, started: false, cooldown: true };
    if (_noLoopSpawn()) { _repairStartedAt = Date.now(); return { ok: true, started: true, running: true, test: true }; }
    let proc;
    try {
        proc = spawn(BASH_BIN, _loopArgv('once'), { cwd: ROOT, detached: true, stdio: 'ignore', env: _loopEnv() });
    } catch (e) { return { error: 'Could not start self-heal: ' + e.message }; }
    _repairProc = proc; _repairStartedAt = Date.now();
    proc.on('exit', () => { _repairProc = null; });
    proc.on('error', () => { _repairProc = null; });
    proc.unref();
    return { ok: true, started: true, running: true };
}

// ---- After setup: start filling + is the 24/7 loop installed? (#306) ---------
// Commissioning used to only save settings; filling waited for someone to run
// `loop.sh install`. Now, if no cron entry exists, commissioning starts ONE bounded
// `loop.sh once` (the same fixed-argv, deduped spawn as "Run self-heal": its fill step
// is capped by LOOP_FILL_SECONDS) and records it in <state>/first-fill.json so Home can
// say filling has started. Making it permanent is the admin's call: Home shows
// `./scripts/loop.sh install 30` and an admin-only "Keep it healthy 24/7" button
// (POST /api/setup/loop-install), which runs exactly that with a fixed argv.
const CRON_TAG = 'val-ark-loop';   // loop.sh cron_install's tag
let _cron = { at: 0, installed: false, hasCron: false, waiters: null };
function _onPath(cmd) {
    for (const d of String(process.env.PATH || '').split(':')) {
        if (!d) continue;
        try { fs.accessSync(path.join(d, cmd), fs.constants.X_OK); return true; } catch (_) {}
    }
    return false;
}
// Calls cb(installed) with a fresh answer (when the cache is older than maxAgeMs).
function loopInstalled(cb, maxAgeMs = 60000) {
    if (Date.now() - _cron.at < maxAgeMs) return cb && cb(_cron.installed);
    if (_cron.waiters) { if (cb) _cron.waiters.push(cb); return; }
    _cron.waiters = cb ? [cb] : [];
    const done = (installed, hasCron) => {
        _cron.installed = installed; _cron.hasCron = hasCron; _cron.at = Date.now();
        const w = _cron.waiters; _cron.waiters = null;
        for (const f of w) { try { f(installed); } catch (_) {} }
    };
    if (!_onPath('crontab')) return done(false, false);
    // Fixed argv; `crontab -l` only reads this user's table.
    execFile('crontab', ['-l'], { timeout: 5000 }, (err, stdout) => {
        done(!err && String(stdout || '').split('\n').some(l => l.includes(CRON_TAG) && !/^\s*#/.test(l)), true);
    });
}
function firstFillState() {
    const f = readStateJson('first-fill.json');
    return {
        loopInstalled: _cron.installed, cronAvailable: _cron.hasCron, running: repairInFlight(),
        startedAt: f && typeof f.ts === 'string' ? f.ts : null,
        started: !!(f && f.started),
    };
}
// After a successful commission: cb({ loopInstalled, started, ... }).
function startFirstFill(cb) {
    loopInstalled((installed) => {
        let started = false, note = '';
        if (installed) note = 'The 24/7 loop is installed; its next cycle fills the disk.';
        else {
            const r = triggerRepair();
            started = !!(r && r.ok && (r.started || r.running));
            if (!started) note = (r && r.error) || 'Could not start the first fill.';
        }
        try {
            fs.mkdirSync(STATE_DIR, { recursive: true });
            fs.writeFileSync(path.join(STATE_DIR, 'first-fill.json'),
                JSON.stringify({ ts: new Date().toISOString(), started, loopInstalled: installed }) + '\n');
        } catch (_) {}
        cb({ ...firstFillState(), started, note });
    }, 0);
}
// POST /api/setup/loop-install (ADMIN_ONLY_POSTS): `loop.sh install 30` — it writes this
// user's crontab (an @reboot + every-30-min entry, tagged val-ark-loop). Fixed argv.
let _loopInstalling = false;
function installLoop(cb) {
    if (!_onPath('crontab')) return cb({ error: 'This box has no cron (crontab not found). Run ./scripts/loop.sh run under a service manager instead.' });
    if (_loopInstalling) return cb({ error: 'Already installing — try again in a moment.' });
    if (_noLoopSpawn()) return cb({ ok: true, loopInstalled: false, test: true });
    _loopInstalling = true;
    execFile(BASH_BIN, _loopArgv('install'), { cwd: ROOT, timeout: 30000, env: _loopEnv() }, (err) => {
        _loopInstalling = false;
        loopInstalled((installed) => {
            if (installed) return cb({ ok: true, loopInstalled: true });
            cb({ error: 'loop.sh install did not add a cron entry' + (err ? ' (' + String(err.message || err).slice(0, 160) + ')' : '') + '. Run ./scripts/loop.sh install 30 on the box.' });
        }, 0);
    });
}

// ---- The box's address: <name>.local or its LAN IP (#306) --------------------
// ONE place decides which address to show; the wizard, the recovery card and the
// Health page all use boxAddress(). <name>.local is promised only when lib/mdns.sh
// reports it live (published by our avahi-publish child, or native: the hostname is
// the name); otherwise the box's real LAN IPv4 is shown, with the reason .local is
// unavailable. mdns.sh never installs anything; the loop re-runs it every cycle.
// "mdns: true" means our publisher is up and announcing (or the hostname is the name);
// it does NOT prove every client resolves .local (some phones/Windows setups don't), so
// the IP is always shown beside it (altUrl).
const MDNS_SH = path.join(__dirname, 'lib', 'mdns.sh');
const MDNS_CHECK_MS = 10 * 60 * 1000;
let _mdnsCheck = null;          // last `mdns.sh check` (an un-commissioned box)
let _mdnsWaiters = null;
// Never start a REAL publisher from a test (it would keep announcing <name>.local on the
// LAN after the test). A test is recognised by any VALARK_TEST_* hook or a state dir in
// the system temp dir; there mdns.sh runs only when VALARK_MDNS_PUBLISH is 'none' or a
// stub that itself lives in the temp dir (mdns.sh enforces the same rule).
function _inTmp(p) {
    if (!p) return false;
    let real = p; try { real = fs.realpathSync(p); } catch (_) {}
    const roots = new Set([require('os').tmpdir(), '/tmp', '/var/tmp']);
    for (const r of [...roots]) { try { roots.add(fs.realpathSync(r)); } catch (_) {} }
    for (const r of roots) {
        const base = r.replace(/\/+$/, '');
        if (!base) continue;
        if ([p, real].some(x => x === base || x.startsWith(base + '/'))) return true;
    }
    return false;
}
function _mdnsNoSpawn() {
    const pub = process.env.VALARK_MDNS_PUBLISH;
    const testy = Object.keys(process.env).some(k => k.startsWith('VALARK_TEST_')) || _inTmp(STATE_DIR);
    if (!testy) return false;
    return !(pub === 'none' || (pub && _inTmp(pub)));
}
function _cleanMdns(m) {
    if (!m || typeof m !== 'object' || typeof m.state !== 'string') return null;
    const str = (v, n) => (typeof v === 'string' ? v.replace(/[\u0000-\u001f]/g, '').slice(0, n) : '');
    return { state: str(m.state, 16), label: str(m.label, 63), canPublish: m.canPublish === true,
             hostLabel: str(m.hostLabel, 63), ip: str(m.ip, 45), reason: str(m.reason, 200), ts: str(m.ts, 32) };
}
function mdnsState() {
    const m = _cleanMdns(readStateJson('mdns.json'));
    if (!boxCommissioned() && _mdnsCheck) return _mdnsCheck;
    if (m && m.state === 'published' && !mdnsPublisherAlive()) {
        // Our publisher died (or its pid now belongs to another process) since the last
        // ensure; don't promise .local then.
        refreshMdns();
        return { ...m, state: 'unavailable', reason: 'the .local publisher stopped; restarting it' };
    }
    return m || _mdnsCheck;
}
// Is the pid in mdns.pid alive AND still running the argv mdns.sh recorded for it (line
// 2)? Same rule as mdns.sh any_our_pid, so a recycled pid never counts as our publisher.
function mdnsPublisherAlive() {
    let lines;
    try { lines = fs.readFileSync(path.join(STATE_DIR, 'mdns.pid'), 'utf8').split('\n'); } catch (_) { return false; }
    const pid = parseInt(lines[0], 10), want = String(lines[1] || '').trim();
    if (!(pid > 1) || !want) return false;
    let args = null;
    try {
        args = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean).join(' ');
    } catch (_) {
        if (fs.existsSync('/proc/self/cmdline')) return false;   // Linux: no such process
        try { args = execFileSync('ps', ['-p', String(pid), '-o', 'args='], { timeout: 2000, encoding: 'utf8' }).trim(); }
        catch (_) { return false; }
    }
    return args === want;
}
// Run mdns.sh (ensure on a commissioned box, else check); cb() when done.
function refreshMdns(cb) {
    if (_mdnsNoSpawn()) return cb && cb();
    if (_mdnsWaiters) { if (cb) _mdnsWaiters.push(cb); return; }
    _mdnsWaiters = cb ? [cb] : [];
    const mode = boxCommissioned() ? 'ensure' : 'check';
    // Fixed argv; mdns.sh reads the name from settings.json itself.
    execFile('bash', [MDNS_SH, mode, STATE_DIR], { timeout: 20000 }, (err, stdout) => {
        if (mode === 'check') { try { _mdnsCheck = _cleanMdns(JSON.parse(String(stdout || '').trim())); } catch (_) {} }
        else _mdnsCheck = null;
        const w = _mdnsWaiters; _mdnsWaiters = null;
        for (const f of w) { try { f(); } catch (_) {} }
    });
}
// Interfaces that never carry "the LAN address" (VPNs/tunnels, containers, bridges,
// loopback). SAME list as lib/mdns.sh SKIP_IFACE_RE; keep them in step.
const _SKIP_IFACE = /^(tailscale|ts|utun|wg|tun|zt|docker|br-|veth|virbr|lo)/i;
function _rfc1918(a) { return /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a); }
// The LAN IPv4 to show: the address this request arrived on when it's a private LAN
// address, else the first private IPv4 of a non-tailnet interface, else any non-loopback
// IPv4 the request arrived on. null when there is none (e.g. only loopback).
function lanIp(req) {
    const la = String(req?.socket?.localAddress || '').replace(/^::ffff:/, '');
    const ifs = netIfaces();
    // The arrival address counts only when it isn't on a VPN/container interface (a
    // WireGuard or docker address is often RFC 1918 too).
    const onSkipped = Object.entries(ifs).some(([n, as]) => _SKIP_IFACE.test(n) && (as || []).some(a => a.address === la));
    if (_rfc1918(la) && !onSkipped) return la;
    for (const [name, addrs] of Object.entries(ifs)) {
        if (_SKIP_IFACE.test(name)) continue;
        for (const a of addrs || []) {
            if ((a.family === 'IPv4' || a.family === 4) && !a.internal && _rfc1918(a.address)) return a.address;
        }
    }
    if (/^\d+\.\d+\.\d+\.\d+$/.test(la) && !la.startsWith('127.')) return la;
    return null;
}
// ':PORT' as the visitor typed it (the Host header), '' for the scheme's default port.
function _visitPort(req) {
    const h = String(req?.headers?.host || '');
    const secure = isSecureReq(req);
    const m = h.match(/:(\d{1,5})$/);
    if (m) return (m[1] === (secure ? '443' : '80')) ? '' : ':' + m[1];
    if (h) return '';
    const lp = req?.socket?.localPort;
    return lp && lp !== (secure ? 443 : 80) ? ':' + lp : '';
}
function boxAddress(req) {
    const s = commission.readSettings(STATE_DIR);
    const label = commission.mdnsLabel(s.name);
    const m = mdnsState();
    const scheme = isSecureReq(req) ? 'https' : 'http';
    const port = _visitPort(req);
    const ip = lanIp(req);
    const localUrl = `${scheme}://${label}.local${port}/`;
    const ipUrl = ip ? `${scheme}://${ip}${port}/` : null;
    const live = !!(m && m.label === label && (m.state === 'published' || m.state === 'native'));
    let reason = '';
    if (!live) {
        if (!m) reason = 'not checked yet';
        else if (m.state === 'unavailable') reason = m.reason || 'unavailable';
        else if (m.label !== label) reason = 'not published yet';
        else reason = m.reason || 'not published yet';
    }
    return {
        name: s.name || 'valark', label, host: `${label}.local`,
        mdns: live,                                   // <label>.local is being announced now
        canPublish: !!(m && m.canPublish),            // this box can publish any name (wizard)
        hostLabel: (m && m.hostLabel) || '',          // the name the responder already answers for
        localUrl, ip, ipUrl,
        url: live ? localUrl : (ipUrl || localUrl),  // THE address to show
        altUrl: live ? ipUrl : null,
        reason,
    };
}

// ---- "Ask Val Ark": the on-box assistant (roadmap Phase 8, slice 1) ----------
// A minimal, offline, zero-dependency door to the box's OWN small chat model. It
// wraps a SINGLE-SHOT llama.cpp invocation (no persistent daemon) exactly like
// verify.sh's inference check and moderation's classifier spawn — reusing that
// proven runtime rather than inventing a new one. FAIL-SOFT is a hard requirement:
// a bare box (no binary or no model — the ARM64 appliance ships a source clone
// only) answers with a friendly "not installed yet" payload, HTTP 200, never a 5xx,
// and never crashes the event loop. SECURITY: the model binary is spawned with an
// ARGV ARRAY (never a shell string) so the user's question is inert data in one arg;
// the prompt is length-bounded + control-char-stripped, tokens are capped, a
// wall-clock timer SIGKILLs a wedged child, and an admission cap bounds concurrent
// model loads (each is 1-2 GB of RAM) — over cap → 503, never an unbounded fan-out.
const ASK_MAX_Q = Number(process.env.VALARK_ASK_MAX_Q) || 2000;          // question char cap
const ASK_MAX_CTX = Number(process.env.VALARK_ASK_MAX_CTX) || 600;       // page/status context char cap
const ASK_N_TOKENS = Math.min(Number(process.env.VALARK_ASK_N_TOKENS) || 256, 1024); // answer token cap (hard max)
const ASK_TIMEOUT_S = Number(process.env.VALARK_ASK_TIMEOUT) || 120;     // wall-clock per ask (SIGKILL backstop)
const ASK_MAX_CONCURRENT = Number(process.env.VALARK_ASK_MAX_CONCURRENT) || 2; // concurrent inferences
const ASK_MAX_ANSWER_BYTES = 256 * 1024;    // defence-in-depth: cap a runaway generation
let askInFlight = 0;

// Native tools tree that holds the mirrored llama.cpp build. cfg() honours a
// VALARK_TOOLS_DIR override (tests point it at a fixture tree) then the repo 'tools'
// symlink — same resolution as the packages endpoint (_pkgToolsDir).
function _askToolsDir() { return cfg('VALARK_TOOLS_DIR') || path.join(ROOT, 'tools'); }
function _askPlatformDir() {
    const os = require('os');
    if (os.platform() === 'darwin') return 'macos-arm64';
    const a = os.arch();
    if (a === 'arm64' || a === 'aarch64') return 'linux-arm64';
    return 'linux-x86_64';
}
// Resolve an executable by NAME under a base dir (recursive — the mirror nests a
// build-tag dir, e.g. llama-cpp/llama-bNNNN/llama-cli). Mirrors moderation.sh
// _mod_find_bin ('find <base>/llama-cpp -name <n> -type f -perm -u+x | head -1').
function _findAskExec(dir, name, depth) {
    depth = depth || 0;
    if (depth > 6) return null;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return null; }
    for (const e of entries) {
        if (e.isFile() && e.name === name) {
            const p = path.join(dir, name);
            try { fs.accessSync(p, fs.constants.X_OK); return p; } catch (_) {}
        }
    }
    for (const e of entries) {
        if (e.isDirectory()) { const hit = _findAskExec(path.join(dir, e.name), name, depth + 1); if (hit) return hit; }
    }
    return null;
}
// Prefer llama-completion, fall back to llama-cli — the same pair moderation resolves.
function findLlamaBin() {
    const base = path.join(_askToolsDir(), _askPlatformDir(), 'llama-cpp');
    for (const name of ['llama-completion', 'llama-cli']) {
        const hit = _findAskExec(base, name);
        if (hit) return hit;
    }
    return null;
}
function _walkGguf(dir, cb, depth) {
    depth = depth || 0;
    if (depth > 4) return;
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return; }
    for (const e of entries) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) _walkGguf(p, cb, depth + 1);
        else if (e.isFile() && e.name.toLowerCase().endsWith('.gguf')) {
            try { cb(p, fs.statSync(p).size); } catch (_) {}
        }
    }
}
// Smallest generative .gguf > 10 MB — assistant/ (curated chat models) first, then
// llm/, mirroring verify.sh's selection (the >10 MB floor skips zero-byte/stub ggufs
// and embedding heads). Returns { path, size } or null.
function findAssistantModel() {
    for (const sub of ['assistant', 'llm']) {
        let best = null;
        _walkGguf(path.join(MODEL_ROOT, sub), (p, size) => {
            if (size > 10 * 1024 * 1024 && (!best || size < best.size)) best = { path: p, size };
        });
        if (best) return best;
    }
    return null;
}
// Read-only readiness (GET /api/status/ask) — pure presence checks, NEVER runs
// inference. Read-gated for free by the /api/status/ prefix (isReadGated).
function getAskStatus() {
    const bin = findLlamaBin();
    const model = findAssistantModel();
    let reason = 'ok';
    if (!bin) reason = 'runtime';
    else if (!model) reason = 'model';
    return {
        ready: !!bin && !!model,
        runtime: bin ? path.basename(bin) : null,
        model: model ? path.basename(model.path) : null,
        reason,
        modelId: 'qwen2.5-1.5b-instruct-gguf',   // the one-click "get the helper" target
    };
}
// Strip control chars (keep tab/newline) and hard-cap length. Defence in depth — the
// value is spawned as a single argv element regardless, never through a shell.
function _askSanitize(s, max) {
    if (typeof s !== 'string') return '';
    let t = s.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, ' ');
    if (t.length > max) t = t.slice(0, max);
    return t;
}
// POST /api/ask {question, context?} — stream the answer back as SSE frames (the
// project's event:/data: framing, per-request, NOT the shared broadcast pool):
//   event: token  data: {"t":"..."}            one per stdout chunk (JSON-encoded so
//                                               newlines never break SSE framing)
//   event: soft   data: {"ready":false,...}    fail-soft (no runtime/model/memory/empty)
//   event: error  data: {"message":"..."}      mid-stream failure (already 200)
//   event: done   data: {"model":..,"ms":..}   terminal, always sent
// The gate stack (LAN/tailnet, rate-limit, commissioned, auth-per-Use-Mode) already
// ran in handleAPI — in Passworded/Accounts mode a non-admin LAN caller is 401'd
// there, giving this the same read-gated posture as the other reads.
function handleAsk(req, res, body) {
    body = body || {};
    const question = _askSanitize(body.question, ASK_MAX_Q).trim();
    const context = _askSanitize(body.context, ASK_MAX_CTX).trim();
    const corsOrigin = getCORSOrigin(req);
    let headed = false;
    const startSSE = () => {
        if (headed) return; headed = true;
        res.writeHead(200, {
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            'X-Accel-Buffering': 'no',
            ...(corsOrigin ? { 'Access-Control-Allow-Origin': corsOrigin } : {}),
            ...SECURITY_HEADERS,
        });
    };
    const sse = (event, data) => { try { res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`); } catch (_) {} };
    const soft = (reason, message) => { startSSE(); sse('soft', { ready: false, reason, message }); sse('done', {}); try { res.end(); } catch (_) {} };

    if (!question) return soft('empty', 'Type a question first.');

    // Admission cap: bound concurrent model loads (1-2 GB RAM each). Over cap → 503
    // with Retry-After BEFORE any streaming headers (mirrors the moderation/#62 cap).
    if (askInFlight >= ASK_MAX_CONCURRENT) {
        res.writeHead(503, { 'Content-Type': 'application/json', 'Retry-After': '5', ...SECURITY_HEADERS });
        return res.end(JSON.stringify({ ready: false, busy: true, reason: 'busy', message: 'The assistant is busy right now — please try again in a moment.' }));
    }

    // FAIL-SOFT ladder: a bare box has no binary and/or no model. Never a 5xx.
    const bin = findLlamaBin();
    if (!bin) return soft('runtime', 'The AI helper runtime isn’t installed on this box yet.');
    const model = findAssistantModel();
    if (!model) return soft('model', 'No assistant model installed yet — add one from the Library ▸ Models tab.');
    // Memory guard: refuse rather than OOM-kill community services loading the model.
    try {
        const os = require('os');
        const free = os.freemem();
        if (free > 0 && free < model.size + 128 * 1024 * 1024) {
            return soft('memory', 'Not enough free memory right now to run the assistant — try again after other tasks finish.');
        }
    } catch (_) {}

    // Test seam (mirrors moderation/repair): the Playwright suite runs the server with
    // VALARK_TEST_NO_SPAWN=1 so it never triggers a real 1-2 GB model load. Only reached
    // when a binary + model actually resolve, so a bare CI box still exercises the soft
    // path above. The offline bash validator leaves this UNSET to drive the real spawn
    // against a stub binary (proving the argv-array, no-shell contract).
    if (process.env.VALARK_TEST_NO_SPAWN === '1') {
        startSSE();
        sse('token', { t: 'Test mode — the assistant is wired up (stubbed answer, no model was run).' });
        sse('done', { model: path.basename(model.path), ms: 0, stub: true });
        return res.end();
    }

    // Build the prompt server-side. question/context are DATA inside one -p argv
    // element — NEVER interpolated into a shell string.
    const sysline = "You are Val Ark's helpful offline assistant on a local, internet-free knowledge appliance. Answer briefly and in plain language.";
    const ctxline = context ? `\nContext: ${context}` : '';
    const prompt = `${sysline}${ctxline}\n\nQuestion: ${question}\nAnswer:`;
    // Proven single-shot invocation (verify.sh:104 / moderation.sh): single-turn,
    // conversation mode off, stdin closed, warmup off. --no-display-prompt keeps stdout
    // to the answer only. ARGV ARRAY — no shell, ever.
    const args = ['-m', model.path, '-p', prompt, '-n', String(ASK_N_TOKENS),
                  '-st', '-no-cnv', '--no-warmup', '--no-display-prompt', '--temp', '0'];

    let child, released = false;
    const release = () => { if (released) return; released = true; askInFlight--; };
    askInFlight++;
    try {
        child = spawn(bin, args, {
            stdio: ['ignore', 'pipe', 'ignore'],
            env: { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || '') },
        });
    } catch (_) {
        release();
        return soft('runtime', 'Couldn’t start the assistant on this box.');
    }

    startSSE();
    const t0 = Date.now();
    const { StringDecoder } = require('string_decoder');
    const dec = new StringDecoder('utf8');
    let wrote = 0, finished = false;
    const finish = (ev, data) => {
        if (finished) return; finished = true;
        clearTimeout(killer);
        try { child.kill('SIGKILL'); } catch (_) {}
        release();
        const tail = dec.end();
        if (tail) sse('token', { t: tail });
        if (ev) sse(ev, data || {});
        sse('done', { model: path.basename(model.path), ms: Date.now() - t0 });
        try { res.end(); } catch (_) {}
    };
    const killer = setTimeout(() => {
        // Wedged/slow child: SIGKILL and close cleanly (answer so far already streamed).
        if (wrote === 0) finish('error', { message: 'The assistant took too long to respond on this box.' });
        else finish('error', { message: 'The assistant timed out — partial answer above.' });
    }, ASK_TIMEOUT_S * 1000);
    child.stdout.on('data', (d) => {
        wrote += d.length;
        if (wrote > ASK_MAX_ANSWER_BYTES) return finish('error', { message: 'Answer truncated (too long).' });
        const s = dec.write(d);
        if (s) sse('token', { t: s });
    });
    child.on('error', () => {
        // Headers already flushed (SSE), so signal via a stream frame, not a status code.
        if (wrote === 0) finish('soft', { ready: false, reason: 'runtime', message: 'The assistant couldn’t run on this box.' });
        else finish('error', { message: 'The assistant stopped unexpectedly.' });
    });
    child.on('close', () => finish(null));
    // Client vanished mid-answer → SIGKILL the child and free the admission slot NOW.
    // Bind to res ('close'), NOT req: handleAsk runs inside readBody(req).then(...), so
    // the request body is already fully drained and req's 'close' has ALREADY fired at
    // body-end (attaching there is dead code — the leak the DoS review caught). For a
    // streaming response, res 'close' is the true "client went away" signal and fires
    // exactly on disconnect. It ALSO fires on normal completion after res.end(), but the
    // idempotent finished/released guards make that a no-op (no double-kill/-release).
    res.on('close', () => { if (!finished) finish(null); });
}

// In-flight service starts: forum/chat first-run builds take minutes, so a start is
// spawned detached and tracked here to (a) dedupe repeat clicks and (b) show "starting…".
const startingServices = new Map();
function startService(id) {
    if (!isAlphanumDash(id) || !APP_SERVICES[id]) return { error: 'Unknown service' };
    if (!serviceEnabled(id)) {
        return { error: `Service '${id}' is not enabled. Add it to VALARK_SERVICES in .env.` };
    }
    if (!serviceMirrored(id)) {
        return { error: `Service '${id}' is not mirrored yet. Run: scripts/tools/${id}.sh` };
    }
    if (startingServices.has(id)) return { id, status: 'starting' };
    const proc = spawn('/usr/bin/bash', [path.join(ROOT, 'scripts/services', id + '.sh'), 'start'], {
        cwd: ROOT, detached: true, stdio: 'ignore',
        env: { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || ''), FORCE_COLOR: '0' },
    });
    startingServices.set(id, Date.now());
    proc.on('exit', () => { startingServices.delete(id); _svcCache.ts = 0; });
    proc.on('error', () => { startingServices.delete(id); });
    proc.unref();
    _svcCache.ts = 0;   // force the next status probe to re-check
    return { id, status: 'starting' };
}

// Per-service account model — how a person actually gets a login. One source of
// truth for the UI's Community "Accounts & sign-up" panel and for validating
// /api/service/adduser. The underlying tech dictates the model: IRC/mail have no
// safe self-signup (host provisions), NodeBB has its own registration page, and
// MicroBin is a single shared gated instance.
// chat's model tracks its actual access mode: PUBLIC (default) => open, just pick a
// nickname (no account); private (VALARK_CHAT_PUBLIC=0) => host-provisioned like mail.
const _chatPublic = !/^(0|false|no|off)$/i.test(String(cfg('VALARK_CHAT_PUBLIC', '1')));
const COMMUNITY_ACCOUNTS = {
    chat:  _chatPublic
        ? { signup: 'open', label: 'Chat', note: 'Open chat — just pick a nickname at /app/chat/ and join. No account needed.' }
        : { signup: 'host', label: 'Chat', note: 'IRC has no self-signup — the host creates your login (chat.sh adduser), then you sign in at /app/chat/.' },
    mail:  { signup: 'host',   label: 'Mail',              note: 'The host provisions your mailbox (login + IMAP account); sign in at /app/mail/.' },
    forum: { signup: 'self',   label: 'Message Boards',    registerPath: '/app/forum/register', note: 'Create your own account on the forum’s Register page.' },
    paste: { signup: 'shared', label: 'Files & Pastebin',  note: 'One shared, access-gated instance — get the access code from your host (no per-user signup).' },
    gitea: { signup: 'host',   label: 'Git forge',         note: 'Registration is off: the host creates your login (gitea.sh adduser; the first one is the site admin), then you sign in at /app/gitea/.' },
};

// Create a login on a host-provisioned community service (chat/mail). Minting a
// mail/chat login is an ADMIN action, so the caller localhost-gates it. forum users
// self-register and paste is a shared instance — neither is provisioned here.
function addServiceUser(id, username, password) {
    const model = COMMUNITY_ACCOUNTS[id];
    if (!model) return { error: 'Unknown service' };
    if (model.signup === 'self')   return { error: `Sign up for ${model.label} on its own Register page.`, registerPath: model.registerPath };
    if (model.signup === 'shared') return { error: `${model.label} is a shared instance — ask your host for the access code (no per-user signup).` };
    if (model.signup === 'open')   return { error: `${model.label} is open — just pick a nickname at /app/${id}/ and join. No account needed.` };
    if (typeof username !== 'string' || !/^[a-zA-Z0-9._-]{1,32}$/.test(username)) {
        return { error: 'Invalid username (letters, digits, dot, dash, underscore; max 32).' };
    }
    if (password != null && (typeof password !== 'string' || password.length > 128 || /[\x00-\x1f\x7f]/.test(password))) {
        return { error: 'Invalid password (max 128 chars, no control characters).' };
    }
    if (!serviceMirrored(id)) return { error: `Service '${id}' is not mirrored yet. Run: scripts/tools/${id}.sh` };
    // spawn with an argv array (no shell) — username/password are data, never a command.
    const args = [path.join(ROOT, 'scripts/services', id + '.sh'), 'adduser', username];
    if (password) args.push(password);
    try {
        const out = execFileSync('/usr/bin/bash', args, {
            cwd: ROOT, timeout: 20000, encoding: 'utf8',
            env: { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || ''), FORCE_COLOR: '0' },
        });
        return { ok: true, id, username, message: (out || '').trim().split('\n').filter(Boolean).pop() || 'account created' };
    } catch (e) {
        const detail = ((e.stderr || '') + (e.stdout || '')).trim().split('\n').filter(Boolean).pop() || e.message || 'unknown error';
        return { error: `Could not create the account: ${detail}` };
    }
}

let _svcCache = { data: null, ts: 0 };
async function getServicesStatus() {
    const now = Date.now();
    if (_svcCache.data && (now - _svcCache.ts) < 5000) return _svcCache.data;
    const ids = Object.keys(APP_SERVICES);
    const ups = await Promise.all(ids.map((id) => probePort(APP_SERVICES[id].port)));
    const data = {};
    ids.forEach((id, i) => {
        const running = ups[i];
        const enabled = serviceEnabled(id);
        const mirrored = serviceMirrored(id);
        const starting = startingServices.has(id);
        data[id] = {
            port: APP_SERVICES[id].port, path: `/app/${id}/`, running,
            enabled, mirrored, starting,
            startable: enabled && mirrored && !running && !starting,
            account: COMMUNITY_ACCOUNTS[id] || null,   // how a person gets a login (UI signup panel)
        };
    });
    _svcCache = { data, ts: now };
    return data;
}

// =============================================================================
// TLS / local-CA: Val Ark runs its own offline certificate authority (see
// scripts/lib/tls.sh) so the LAN can use HTTPS with no internet/public CA. The
// CA private key lives OFF the world-readable data disk; we only ever read the
// generated cert/key here. The CA *certificate* is offered at /ca.crt (over
// plain HTTP too — you must be able to fetch the trust anchor before HTTPS is
// trusted) so devices install it once.
const TLS = {
    enabled: false,
    httpsPort: parseInt(process.env.VALARK_HTTPS_PORT || '8443', 10),
    caRoute: '/ca.crt',
    domain: process.env.VALARK_TLS_DOMAIN || 'valark.lan',
    notAfter: null, fingerprint: null, sans: null, dir: null,
};
let _caBuf = null;
function tlsDir() {
    try { return execFileSync('bash', [path.join(__dirname, 'lib', 'tls.sh'), 'dir'], { encoding: 'utf8' }).trim(); }
    catch (e) { return path.join(process.env.HOME || require('os').homedir(), '.config', 'val-ark', 'tls'); }
}
function loadTls() {
    if (process.env.VALARK_DISABLE_TLS === '1') return null;
    const dir = tlsDir();
    const read = () => ({
        key: fs.readFileSync(path.join(dir, 'server.key')),
        cert: fs.readFileSync(path.join(dir, 'server.crt')),
        ca: fs.readFileSync(path.join(dir, 'ca.crt')),
        dir,
    });
    try { return read(); }
    catch (e) {
        // Certs not generated yet — create them once, then retry.
        try { execFileSync('bash', [path.join(__dirname, 'lib', 'tls.sh'), 'ensure'], { stdio: 'ignore' }); return read(); }
        catch (e2) { return null; }
    }
}
// Serve the offline bootstrap script with this Ark's host:port baked in, so the
// piped one-liner (`curl http://<ark>/bootstrap.sh | bash`) knows where to clone
// from without the user typing the address. Falls back to the literal file if the
// Host header is missing (the script then expects the host as an argument).
function serveBootstrap(req, res) {
    try {
        let script = fs.readFileSync(path.join(ROOT, 'bootstrap.sh'), 'utf8');
        const host = (req.headers && req.headers.host) ? String(req.headers.host) : '';
        if (host && /^[a-zA-Z0-9.\-:\[\]]+$/.test(host)) {
            const scheme = (req.socket && req.socket.encrypted) ? 'https' : 'http';
            script = script.split('__VALARK_HOST__').join(`${scheme}://${host}`);
        }
        res.writeHead(200, {
            'Content-Type': 'text/x-shellscript; charset=utf-8',
            'Cache-Control': 'no-cache', ...SECURITY_HEADERS,
        });
        res.end(script);
    } catch (e) {
        res.writeHead(503, { 'Content-Type': 'text/plain', ...SECURITY_HEADERS });
        res.end('# Val Ark bootstrap unavailable (bootstrap.sh missing on this host)\n');
    }
}

function serveCaCert(res) {
    try {
        if (!_caBuf) _caBuf = fs.readFileSync(path.join(tlsDir(), 'ca.crt'));
        res.writeHead(200, {
            'Content-Type': 'application/x-x509-ca-cert',
            'Content-Disposition': 'attachment; filename="valark-ca.crt"',
            'Cache-Control': 'no-cache', ...SECURITY_HEADERS,
        });
        res.end(_caBuf);
    } catch (e) {
        res.writeHead(503, { 'Content-Type': 'text/plain', ...SECURITY_HEADERS });
        res.end('Val Ark CA not generated yet — run scripts/lib/tls.sh ensure');
    }
}
function serveTlsStatus(res) {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache', ...SECURITY_HEADERS });
    res.end(JSON.stringify({
        enabled: TLS.enabled, httpsPort: TLS.httpsPort, caDownload: TLS.caRoute,
        domain: TLS.domain, notAfter: TLS.notAfter, fingerprintSha256: TLS.fingerprint,
        sans: TLS.sans, forceHttps: process.env.VALARK_FORCE_HTTPS === '1',
    }));
}

// Server
// =============================================================================
function handleRequest(req, res) {
    if (!hostAllowed(req)) {
        res.writeHead(421, { 'Content-Type': 'text/plain' });
        return res.end('Misdirected request: this Val Ark answers only to its own names (set VALARK_ALLOWED_HOSTS to add one).\n');
    }
    // Block path traversal attempts early (before URL normalization resolves ..)
    // Any '..' segment in the raw path, plain or with encoded dots (%2e., .%2e, %2e%2e): the
    // URL parser would resolve it before we ever saw the path. Only whole segments count, so
    // names like "...And_Justice_for_All" or "foo..tar.gz" and the query string are fine.
    // %5c / %2f count as separators too: the Kiwix and app proxies forward the raw URL.
    if (/(^|\/|\\|%5c|%2f)(\.|%2e){2}(\/|\\|%5c|%2f|$)/i.test(req.url.split(/[?#]/)[0])) {
        return send404(res);
    }

    const parsedUrl = new URL(req.url, `http://localhost:${PORT}`);
    let urlPath;
    try { urlPath = decodeURIComponent(parsedUrl.pathname); } catch (_) { return send404(res); }
    if (urlPath.split('/').includes('..')) return send404(res);   // belt and braces
    if (urlPath.includes('\0')) return send404(res);   // a NUL never names a real file
    // One canonical path for every check and route below. Without this, an encoded or
    // doubled slash or a dot segment (/%2fdocs, //docs, /./docs) slips past the
    // read-wall's prefix match and is then normalized straight back into a gated tree
    // by the file server (#297). '..' is already refused above.
    urlPath = path.posix.normalize(urlPath);
    // The Kiwix and app proxies forward the raw URL, so they only take a request whose
    // path was already clean and whose route prefix wasn't percent-encoded: then the raw
    // URL and the path we checked name the same thing.
    const rawPath = req.url.split(/[?#]/)[0];
    const proxyPathOk = (prefix) => {
        try { return decodeURIComponent(rawPath) === urlPath && (rawPath === prefix || rawPath.startsWith(prefix + '/')); } catch (_) { return false; }
    };

    // The CA trust anchor must be fetchable over BOTH http and https (you can't
    // require trusted HTTPS to download the cert that establishes that trust).
    if (urlPath === '/ca.crt' || urlPath === '/valark-ca.crt') {
        return serveCaCert(res);
    }
    // TLS status for the UI (also served over http so the "switch to HTTPS"
    // banner can render before the user has trusted the CA).
    if (urlPath === '/api/status/tls') {
        return serveTlsStatus(res);
    }

    // Offline self-replication: hand out a bootstrap script with THIS host baked in
    // so `curl http://<ark>/bootstrap.sh | bash` clones the whole system from the
    // LAN — no internet. The source bundle/tarball are served from /sources/val-ark/.
    if (urlPath === '/bootstrap.sh' || urlPath === '/bootstrap') {
        return serveBootstrap(req, res);
    }

    // Optional: push LAN visitors to HTTPS (opt-in via VALARK_FORCE_HTTPS=1).
    // Never redirect the CA download, the API, or loopback/health traffic.
    if (process.env.VALARK_FORCE_HTTPS === '1' && TLS.enabled && !(req.socket && req.socket.encrypted)) {
        const host = (req.headers.host || '').split(':')[0];
        const loopback = host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '';
        if (!loopback && !urlPath.startsWith('/api/')) {
            res.writeHead(301, { 'Location': `https://${host}:${TLS.httpsPort}${req.url}` });
            return res.end();
        }
    }

    // Read-wall: in Passworded/Accounts mode an un-authed LAN visitor can't read the
    // library, catalog, downloads or apps — they get a 401 and the SPA shows a login
    // wall. The shell/auth/setup/health/CA above are always reachable so the wall can
    // render and you can sign in; localhost/console is always in.
    // The library is for the local network: whatever the Use Mode, a peer that isn't on
    // the LAN, the tailnet or the box itself can't read it (#297). Open mode means open to
    // people here, not to the internet. The shell, health, setup and auth stay reachable.
    if (isReadGated(urlPath) && !isLanOrTailnet(req)) {
        return sendJSON(res, req, { error: 'This Val Ark shares its library only on the local network.', localOnly: true }, 403);
    }
    if (isReadGated(urlPath) && !readAllowed(req)) {
        return sendJSON(res, req, { error: 'Sign in to view this Val Ark.', needsAuth: true }, 401);
    }

    // API routes
    if (urlPath.startsWith('/api/')) {
        if (subAppApiCallRefused(req)) {
            return sendJSON(res, req, { error: 'Community apps and the library cannot call the Val Ark API. Use the Val Ark web UI.' }, 403);
        }
        return handleAPI(req, res, urlPath);
    }

    // Reverse-proxy the embedded Kiwix server under one origin (/kiwix/*). This
    // keeps offline content INSIDE the Val Ark shell: same port to remember, and
    // the fixed top-nav stays on screen as a permanent "back to Val Ark" header
    // instead of stranding readers on a separate :8888 with no way home. Kiwix
    // runs with --urlRootLocation /kiwix, so its own links already point at
    // /kiwix/* — we just pipe bytes through, no HTML rewriting.
    if (urlPath === '/kiwix' || urlPath.startsWith('/kiwix/')) {
        if (!proxyPathOk('/kiwix')) return send404(res);
        return proxyKiwix(req, res);
    }

    // Community sub-apps (chat/mail/forum/paste, …) reverse-proxied at /app/<id>/
    // so they render inside the Val Ark shell with the same back-to-ark header.
    const appMatch = urlPath.match(/^\/app\/([a-z0-9-]+)(?:\/|$)/);
    if (appMatch) {
        if (!proxyPathOk('/app/' + appMatch[1])) return send404(res);
        return proxyAppService(req, res, appMatch[1], urlPath);
    }

    // Static file serving with path traversal protection
    const normalized = path.normalize(urlPath);

    // Route / to web-ui/index.html
    if (normalized === '/' || normalized === path.sep) {
        return serveStatic(res, path.join(ROOT, 'web-ui', 'index.html'), req);
    }

    // Serve from project root for known directories
    const segments = normalized.split(path.sep).filter(Boolean);
    const topLevel = segments[0];
    const projectDirs = ['tools', 'content', 'sources', 'models', 'assets', 'docs'];
    if (projectDirs.includes(topLevel)) {
        const fullPath = path.join(ROOT, normalized);
        if (!isPathSafe(fullPath, ROOT)) return send404(res);
        return serveStatic(res, fullPath, req);
    }

    // Serve LICENSE from project root
    if (normalized === '/LICENSE' || normalized === path.sep + 'LICENSE') {
        return serveStatic(res, path.join(ROOT, 'LICENSE'), req);
    }

    // Everything else from web-ui/
    const webPath = path.join(ROOT, 'web-ui', normalized);
    if (!isPathSafe(webPath, path.join(ROOT, 'web-ui'))) return send404(res);

    serveStatic(res, webPath, req);
}

// Never let a single bad request take the whole mirror server down: catch any
// synchronous handler error and return 500 instead of crashing the process.
// Shared by the HTTP, extra-port, and HTTPS listeners.
function guardedHandler(req, res) {
    try {
        handleRequest(req, res);
    } catch (e) {
        console.error(`[request error] ${req.method} ${req.url}: ${e && e.stack || e}`);
        try {
            if (!res.headersSent) res.writeHead(500, { 'Content-Type': 'text/plain' });
            res.end('Internal Server Error');
        } catch (_) { /* response already gone */ }
    }
}

const server = http.createServer(guardedHandler);
// Last-resort guard so an async surprise logs instead of killing a public server.
process.on('uncaughtException', (e) => console.error(`[uncaughtException] ${e && e.stack || e}`));

// =============================================================================
// Kiwix Auto-Launch
// =============================================================================
const KIWIX_PORT = parseInt(process.env.VALARK_KIWIX_PORT || '8888', 10); // internal; proxied at /kiwix/
const KIWIX_ROOT = '/kiwix';   // URL prefix (kiwix-serve --urlRootLocation); proxied same-origin
let kiwixProcess = null;
let kiwixStatus = { running: false, port: KIWIX_PORT, url: '', path: KIWIX_ROOT + '/', files: 0 };

function findKiwixServe() {
    const arch = require('os').arch();
    const platform = arch === 'x64' ? 'linux-x86_64' : 'linux-arm64';
    const kiwixPath = path.join(ROOT, 'tools', platform, 'kiwix', 'kiwix-serve');
    try {
        fs.accessSync(kiwixPath, fs.constants.X_OK);
        return kiwixPath;
    } catch { return null; }
}

// Expected ZIM file sizes (bytes) for completeness validation
const ZIM_EXPECTED_SIZES = {
    'wikipedia_en_simple_all_maxi_2025-11.zim': 3.1 * 1073741824,
    'wikipedia_en_all_maxi_2025-08.zim': 111 * 1073741824,
};

function findZimFiles() {
    const zimDir = path.join(ROOT, 'content', 'zim');
    try {
        return fs.readdirSync(zimDir)
            .filter(f => f.endsWith('.zim'))
            .filter(f => {
                // #112: realpath-contain each .zim before handing it to kiwix-serve.
                // The statSync below FOLLOWS symlinks, so an in-tree X.zim symlink
                // pointing OUTSIDE ROOT would otherwise be resolved and served — the
                // same in-tree-symlink-escape class #101 closed on serveArchive + the
                // packages enumeration, here on the ZIM-serving path. realpathWithin()
                // (issue #101) realpaths the base too, so the legit content/zim →
                // data-disk symlink layout and within-tree relative links stay
                // contained and still serve; escaping/dangling links are skipped (no
                // throw). We keep passing the in-tree path to kiwix (unchanged).
                if (realpathWithin(path.join(zimDir, f), zimDir) === null) {
                    console.log(`Skipping ZIM outside content tree (escaping/dangling symlink): ${f}`);
                    return false;
                }
                // Serve every complete .zim. The librarian downloads atomically
                // (partials are *.zim.part, which don't match .zim), so any .zim
                // here is finished — no size floor needed beyond skipping empties.
                // Known legacy names keep a 95%-complete guard as a safety net.
                try {
                    const stat = fs.statSync(path.join(zimDir, f));
                    const expected = ZIM_EXPECTED_SIZES[f];
                    if (expected && stat.size < expected * 0.95) {
                        console.log(`Skipping incomplete ZIM: ${f} (${(stat.size/1073741824).toFixed(1)}GB / ${(expected/1073741824).toFixed(0)}GB)`);
                        return false;
                    }
                    if (stat.size < 1048576) return false; // skip <1MB / empty
                    return true;
                } catch { return false; }
            })
            .map(f => path.join(zimDir, f));
    } catch { return []; }
}

// Single-shot "is something serving on the kiwix port?" probe.
function probeKiwixUp(cb) {
    const net = require('net');
    const s = net.connect(KIWIX_PORT, '127.0.0.1');
    let done = false;
    const fin = (up) => { if (done) return; done = true; try { s.destroy(); } catch (e) {} cb(up); };
    s.setTimeout(2000);
    s.on('connect', () => fin(true));
    s.on('error', () => fin(false));
    s.on('timeout', () => fin(false));
}

function markKiwixUp(reason) {
    const n = findZimFiles().length;
    kiwixStatus = { running: true, port: KIWIX_PORT, url: `http://localhost:${KIWIX_PORT}${KIWIX_ROOT}/`, path: KIWIX_ROOT + '/', files: n };
    console.log(`Kiwix serving on :${KIWIX_PORT} (${reason}, ${n} ZIM file(s)) — proxied at /kiwix/`);
}

// Eventually-consistent status. A big library (1000+ ZIMs over FUSE) can take
// several minutes to index before kiwix-serve binds — sometimes longer than the
// initial probe window — and a serving instance can later die. Re-probe on an
// interval so kiwixStatus (and therefore the /kiwix/ proxy) self-corrects instead
// of getting stuck "down" while kiwix is actually up (or vice-versa). This is the
// backstop that prevents the orphaned-kiwix / stuck-status failure mode.
function reconcileKiwix() {
    if (process.env.VALARK_DISABLE_KIWIX) return;
    probeKiwixUp((up) => {
        if (up && !kiwixStatus.running) markKiwixUp('reconciled');
        else if (!up && kiwixStatus.running) {
            kiwixStatus.running = false;
            console.log(`Kiwix not responding on :${KIWIX_PORT} — marked down (will re-adopt when back)`);
        }
    });
}

function startKiwix() {
    // Opt-out (used by the test harness so an ephemeral instance doesn't fight
    // the production kiwix for the port, and for content-less dev runs).
    if (process.env.VALARK_DISABLE_KIWIX) { kiwixStatus = { running: false, port: KIWIX_PORT, url: '', path: KIWIX_ROOT + '/', files: 0 }; return; }
    // Adopt an already-healthy kiwix-serve (e.g. a survivor of a fast web-server
    // restart) instead of spawning a duplicate that would just fail to bind :8888.
    probeKiwixUp((up) => {
        if (up) { markKiwixUp('adopted existing'); return; }
        const kiwixBin = findKiwixServe();
        const zimFiles = findZimFiles();
        if (!kiwixBin || zimFiles.length === 0) { kiwixStatus = { running: false, port: KIWIX_PORT, url: '', path: KIWIX_ROOT + '/', files: 0 }; return; }
        serveWithRetry(kiwixBin, zimFiles, 0);
    });
}

// kiwix-serve is all-or-nothing: a single corrupt ZIM makes it exit during
// startup ("Unable to add the ZIM file 'X'"), taking the whole library down.
// Parse the offending file from stderr, drop it, and retry — so one bad
// download can't kill the library. A port probe marks it up once it binds
// (kiwix-serve doesn't exit once serving); validating each ZIM up front with
// kiwix-manage is far too slow over a network/FUSE mount, so we let kiwix-serve
// itself report the bad ones.
function serveWithRetry(kiwixBin, zimFiles, attempt) {
    if (zimFiles.length === 0 || attempt > 25) { kiwixStatus = { running: false, port: KIWIX_PORT, url: '', path: KIWIX_ROOT + '/', files: 0 }; return; }
    // Bind kiwix to loopback only — it's an internal upstream reached solely via
    // the same-origin /kiwix/ reverse proxy; never expose unauthenticated content
    // directly on the LAN.
    const proc = spawn(kiwixBin, ['--port', String(KIWIX_PORT), '--address', '127.0.0.1', '--urlRootLocation', KIWIX_ROOT, ...zimFiles], { stdio: ['ignore', 'ignore', 'pipe'] });
    kiwixProcess = proc;
    let stderrBuf = '', settled = false;
    proc.stderr.on('data', (c) => { stderrBuf = (stderrBuf + c.toString()).slice(-2000); });
    proc.on('error', (err) => {
        if (settled) return; settled = true; kiwixProcess = null;
        console.error(`Kiwix failed to start: ${err.message}`);
        kiwixStatus = { running: false, port: KIWIX_PORT, url: '', path: KIWIX_ROOT + '/', files: 0 };
    });
    proc.on('exit', (code) => {
        if (settled) { kiwixStatus.running = false; kiwixProcess = null; return; } // was serving, then died
        settled = true; kiwixProcess = null;
        const m = stderrBuf.match(/Unable to add the ZIM file '([^']+)'/);
        if (m) {
            const bad = m[1];
            // Quarantine the corrupt file (move it out of content/zim) so it
            // self-heals: future starts skip it without a re-scan, and the
            // librarian re-downloads it (the path is now absent).
            try {
                const qdir = path.join(path.dirname(bad), '.corrupt');
                fs.mkdirSync(qdir, { recursive: true });
                fs.renameSync(bad, path.join(qdir, path.basename(bad)));
                console.error(`Quarantined corrupt ZIM: ${path.basename(bad)}`);
            } catch (e) { console.error(`Could not move corrupt ZIM ${path.basename(bad)}: ${e.message}`); }
            serveWithRetry(kiwixBin, zimFiles.filter((z) => z !== bad), attempt + 1);
        } else {
            console.error(`Kiwix exited with code ${code}${stderrBuf ? ': ' + stderrBuf.slice(-300).trim() : ''}`);
            kiwixStatus = { running: false, port: KIWIX_PORT, url: '', path: KIWIX_ROOT + '/', files: 0 };
        }
    });
    // Probe the port; once kiwix binds it's up (and stays up).
    const net = require('net');
    const probe = (tries) => {
        if (settled) return;
        const s = net.connect(KIWIX_PORT, '127.0.0.1');
        s.setTimeout(2000);
        const again = () => { s.destroy(); if (!settled && tries > 0) setTimeout(() => probe(tries - 1), 1000); };
        s.on('connect', () => {
            s.destroy();
            if (settled) return; settled = true;
            kiwixStatus = { running: true, port: KIWIX_PORT, url: `http://localhost:${KIWIX_PORT}${KIWIX_ROOT}/`, path: KIWIX_ROOT + '/', files: zimFiles.length };
            console.log(`Kiwix serving ${zimFiles.length} ZIM file(s) at http://localhost:${KIWIX_PORT}${KIWIX_ROOT}/ (proxied at /kiwix/)`);
        });
        s.on('error', again); s.on('timeout', again);
    };
    // Scale patience to library size — indexing 1000+ ZIMs over FUSE can take
    // minutes before the port binds. The periodic reconciler is the ultimate
    // backstop, but a generous initial probe avoids a multi-minute "down" blip.
    setTimeout(() => probe(Math.max(180, zimFiles.length)), 1000);
}

// Cleanup on exit
process.on('exit', () => { if (kiwixProcess) kiwixProcess.kill(); });
process.on('SIGINT', () => { if (kiwixProcess) kiwixProcess.kill(); process.exit(0); });
process.on('SIGTERM', () => { if (kiwixProcess) kiwixProcess.kill(); process.exit(0); });

// Bind address: defaults to all interfaces (Val Ark is a LAN hub by design), but
// honor VALARK_BIND so a security-conscious operator can restrict it (e.g.
// 127.0.0.1 for host-only access).
const WEB_BIND = process.env.VALARK_BIND || '0.0.0.0';

// HTTPS for the LAN: serve the SAME app over TLS on VALARK_HTTPS_PORT (default
// 8443) using the local-CA leaf cert. HTTP on PORT stays up for back-compat,
// health checks, and the /ca.crt trust-bootstrap. Failure here is non-fatal —
// the Ark keeps serving HTTP and the UI shows TLS as unavailable.
function startHttps() {
    const t = loadTls();
    if (!t) {
        console.log('TLS: certs unavailable (run scripts/lib/tls.sh ensure) — serving HTTP only');
        return;
    }
    try {
        _caBuf = t.ca;
        const httpsServer = https.createServer({ key: t.key, cert: t.cert }, guardedHandler);
        httpsServer.on('error', (e) => console.error('HTTPS server error:', e.message));
        httpsServer.listen(TLS.httpsPort, WEB_BIND, () => {
            TLS.enabled = true;
            TLS.dir = t.dir;
            try {
                const x = new crypto.X509Certificate(t.cert);
                TLS.notAfter = x.validTo;
                TLS.fingerprint = x.fingerprint256;
                TLS.sans = x.subjectAltName || null;
            } catch (e) { /* cert parse is best-effort */ }
            console.log(`Val Ark HTTPS running at https://localhost:${TLS.httpsPort} (bind ${WEB_BIND})`);
        });
    } catch (e) {
        console.error('TLS: could not start HTTPS —', e.message, '— serving HTTP only');
    }
}

// Reachable URLs — advertise LAN addresses too, so the site is easy to find
// (not just localhost) from other machines on the network.
function reachableURLs(port) {
    const os = require('os');
    const urls = [`http://localhost:${port}`];
    const ifaces = os.networkInterfaces();
    for (const name of Object.keys(ifaces)) {
        for (const ni of ifaces[name] || []) {
            if (ni.family === 'IPv4' && !ni.internal) urls.push(`http://${ni.address}:${port}`);
        }
    }
    return urls;
}

// Warm caches, start HTTPS + Kiwix + the reconciler once, on the first port
// that binds (with extra ports, any successful bind counts).
let started = false;
function onFirstBind() {
    if (started) return;
    started = true;
    startHttps();
    // Sweep the moderation staging dir: scan temps are strictly ephemeral (unlinked the
    // instant the runner returns), so anything present at boot leaked when a prior process
    // was killed mid-check. Remove it — each file holds screened user content at rest.
    sweepModerationScan();
    // Warm the cache on startup
    getToolsStatus();
    getContentStatus();
    getModelsStatus();
    getStorageStatus();   // kicks off the (async, non-blocking) storage walk
    // Auto-start Kiwix content server, then keep its status eventually-consistent
    // (catches a late-binding library and a died instance — see reconcileKiwix).
    startKiwix();
    setInterval(reconcileKiwix, 30000);
    // Metrics-history ring buffer: the always-on server is the SINGLE writer. Load any
    // prior samples, then self-sample on a cadence (never faster than the 10s disk cache).
    _loadMetricsRing();
    const _sampleMs = Math.max(10000, Number(cfg('VALARK_METRICS_SAMPLE_MS', '30000')) || 30000);
    setInterval(sampleMetricsToRing, _sampleMs);
    setTimeout(sampleMetricsToRing, 2000);   // seed a baseline shortly after boot
    // Tailscale userspace-networking check (#311): once at boot, then periodically.
    refreshTailscaleMode();
    setInterval(refreshTailscaleMode, TAILSCALE_CHECK_MS).unref();
    // <name>.local (#306): publish on a commissioned box (check only before setup), and
    // keep the publisher up between loop cycles. Plus the cron (24/7 loop) lookup.
    refreshMdns();
    setInterval(refreshMdns, MDNS_CHECK_MS).unref();
    loopInstalled();
}

let boundPorts = 0;
function listenOn(port, attempt = 0) {
    const srv = (port === PORT) ? server : http.createServer(guardedHandler);
    srv.on('error', (e) => {
        if (e.code === 'EACCES') {
            console.warn(`[port ${port}] permission denied — ports <1024 need:  sudo setcap 'cap_net_bind_service=+ep' $(command -v node)   (skipping)`);
        } else if (e.code === 'EADDRINUSE') {
            // The predecessor process may still be releasing the port (the
            // self-heal loop kills + relaunches in quick succession). Retry
            // the primary port — skipping it would leave a listener-less
            // zombie the loop's health check can never see past.
            if (port === PORT && attempt < 15) {
                setTimeout(() => listenOn(port, attempt + 1), 1000);
                return;
            }
            console.warn(`[port ${port}] already in use — skipping`);
        } else {
            console.warn(`[port ${port}] ${e.message} — skipping`);
        }
    });
    srv.listen(port, WEB_BIND, () => {
        console.log(`Val Ark listening on :${port} (bind ${WEB_BIND})`);
        for (const u of reachableURLs(port)) console.log(`    ${u}`);
        boundPorts++;
        onFirstBind();
    });
}

console.log('==================================================');
console.log(`Val Ark web server — serving from ${ROOT}`);
console.log('==================================================');
// First-boot: an un-commissioned box prints its claim code so the setup wizard
// (from another device on the LAN) can prove physical possession. On the box
// itself / localhost you don't need it. The code is consumed once setup completes.
try {
    const _sm = safeModeState();
    if (_sm.safeMode) {
        // Config present but CORRUPT → Safe Mode wins. Do NOT grandfather/ensureClaim
        // (that would silently overwrite the broken config, masking it + losing the
        // recovery code). The box boots into the recovery-only UI; content is untouched.
        console.log('');
        console.log(`  ⚠ Val Ark is in SAFE MODE — ${_sm.reasons.join('; ')}.`);
        console.log('  Open the box and choose "Reset & recover", or run: scripts/valark setpassword');
        console.log('  Your Library, models and content are safe.');
        console.log('');
    } else if (process.env.VALARK_COMMISSIONED !== '1' && !commission.isCommissioned(STATE_DIR)) {
        if (_legacyActive()) {
            // Existing install (already has a content/model library) → snapshot it as
            // commissioned ONCE. This both stops the wizard hijacking a working Ark and
            // freezes the decision, so later library files (e.g. an attacker POSTing to
            // a download endpoint) can never flip an un-owned box to "commissioned".
            commission.grandfather(STATE_DIR);
            console.log('  (existing library detected — marked as already set up)');
        } else {
            const claim = commission.ensureClaim(STATE_DIR);
            console.log('');
            console.log('  This Val Ark is NOT set up yet. Open it and follow the wizard:');
            console.log('     at one of the addresses printed below (http://<name>.local/ works once setup');
            console.log('     publishes it, when avahi runs on this box)');
            console.log(`  Setup claim code (enter it in the wizard from another device): ${claim}`);
            console.log('  (On this box / localhost you can skip the code.)');
            console.log('');
        }
    }
} catch (_) { /* never let commissioning banner block startup */ }
for (const p of ALL_PORTS) listenOn(p);

// A web server with no listener is a zombie: it holds no port, serves nothing,
// and the loop's health probe can't distinguish it from "down". Exit non-zero
// instead so the next self-heal cycle starts a fresh process.
setTimeout(() => {
    if (boundPorts === 0) {
        console.error('No port bound within 30s — exiting for the self-heal loop to restart');
        process.exit(1);
    }
}, 30000).unref();
