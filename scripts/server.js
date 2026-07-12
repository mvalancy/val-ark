#!/usr/bin/env node
// Val Ark API Server - Zero dependency Node.js server
// Serves web UI + provides status/control endpoints

const http = require('http');
const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execSync, execFile, execFileSync, spawn } = require('child_process');

const ROOT = path.resolve(__dirname, '..');

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
const STATE_DIR = process.env.VALARK_STATE_DIR
    || (process.env.VALARK_HOME ? path.join(process.env.VALARK_HOME, 'state')
        : path.join(DATA_ROOT === ROOT ? ROOT : path.join(DATA_ROOT, 'val-ark'), 'state'));

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
        if (f.endsWith('.sh') && f !== '_common.sh') {
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
const downloads = new Map();
const sseClients = new Set();
let downloadCounter = 0;

const MAX_SSE_CONNECTIONS = 50;

function broadcastSSE(event, data) {
    const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of sseClients) {
        try { res.write(msg); } catch (e) { sseClients.delete(res); }
    }
}

function startDownload(type, scriptPath, args = []) {
    // Reject duplicate concurrent downloads of same type
    for (const [, d] of downloads) {
        if (d.type === type && d.status === 'running') {
            return { error: `Download "${type}" is already running` };
        }
    }

    // Check disk space
    const disk = getDiskStatus();
    if (disk.available < 1024 * 1024 * 1024) {
        return { error: 'Insufficient disk space (less than 1 GB free)' };
    }

    const id = String(++downloadCounter);
    const proc = spawn('/usr/bin/bash', [scriptPath, ...args], {
        cwd: ROOT,
        env: { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:' + (process.env.PATH || ''), FORCE_COLOR: '0' },
    });

    const download = {
        id,
        type,
        pid: proc.pid,
        status: 'running',
        progress: 0,
        lastLine: '',
        startedAt: Date.now(),
    };
    downloads.set(id, download);
    broadcastSSE('start', { id, type });

    const handleOutput = (chunk) => {
        const lines = chunk.toString().split('\n').filter(l => l.trim());
        for (const raw of lines) {
            // Strip ANSI escape codes and timestamp prefixes
            const line = raw.replace(/\x1b\[[0-9;]*m/g, '').replace(/^\[\d{2}:\d{2}:\d{2}\]\s*/, '');
            download.lastLine = line.slice(0, 200);
            // Only match orchestrator progress "Progress: N%" not curl's per-file "11.3%"
            const pctMatch = line.match(/Progress:\s*(\d+)%/);
            if (pctMatch) {
                download.progress = Math.min(100, parseInt(pctMatch[1], 10));
            }
            broadcastSSE('progress', {
                id, type,
                progress: download.progress,
                line: download.lastLine,
            });
        }
    };

    proc.stdout.on('data', handleOutput);
    proc.stderr.on('data', handleOutput);

    proc.on('close', (code) => {
        download.status = code === 0 ? 'complete' : 'failed';
        download.exitCode = code;
        download.finishedAt = Date.now();
        invalidateCache();
        broadcastSSE('complete', { id, type, status: download.status, exitCode: code });
    });

    proc.on('error', (err) => {
        download.status = 'failed';
        download.lastLine = err.message;
        broadcastSSE('complete', { id, type, status: 'failed', error: err.message });
    });

    return { id, type, pid: proc.pid };
}

function cancelDownload(id) {
    if (!id || typeof id !== 'string' || !/^\d+$/.test(id)) {
        return { error: 'Invalid download ID' };
    }
    const d = downloads.get(id);
    if (!d) return { error: 'Download not found' };
    if (d.status !== 'running') return { error: 'Download not running' };
    try {
        process.kill(d.pid, 'SIGTERM');
        d.status = 'cancelled';
        broadcastSSE('complete', { id, type: d.type, status: 'cancelled' });
        return { ok: true };
    } catch (e) {
        return { error: e.message };
    }
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
                    const dirInfo = shallowDirInfo(fullPath);
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

function getContentStatus() {
    const now = Date.now();
    if (statusCache.content.data && (now - statusCache.content.timestamp) < CACHE_TTL) {
        return statusCache.content.data;
    }

    const content = {};
    const contentDir = path.join(ROOT, 'content');
    if (!fs.existsSync(contentDir)) {
        statusCache.content = { data: content, timestamp: now };
        return content;
    }

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
    walk(contentDir, '');
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

function parseCatalogTSV(stdout) {
    // planner --list-absent rows: id bucket cat value bytes source url dest extra phase
    const items = [];
    for (const line of String(stdout).split('\n')) {
        if (!line) continue;
        const p = line.split('\t');
        if (p.length < 9) continue;
        const bytes = parseInt(p[4], 10) || 0;
        const name = path.basename(p[7] || '') || p[8] || p[0];
        items.push({
            id: p[0],
            category: String(p[2] || '').replace(/^zim:|^model:/, '') || 'other',
            value: parseInt(p[3], 10) || 0,
            bytes,
            name,
        });
        if (items.length >= CATALOG_MAX_ITEMS) break;
    }
    return items;
}
function computeCatalog(kind) {
    const arg = kind === 'models' ? 'model' : 'content';
    return new Promise((resolve) => {
        execFile('/usr/bin/bash', [path.join(ROOT, 'scripts/librarian.sh'), 'catalog', arg], {
            cwd: ROOT, timeout: 160000, maxBuffer: 48 * 1024 * 1024,
            env: { ...process.env, FORCE_COLOR: '0', VALARK_ZIM_LANGS: CATALOG_LANGS },
        }, (err, stdout) => {
            const items = err ? (_catalogCache[kind].data || []) : parseCatalogTSV(stdout);
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

// Shallow directory info: stat immediate children only, not recursive
function shallowDirInfo(dirPath) {
    let size = 0;
    let newest = 0;
    let fileCount = 0;
    let hasBinary = false; // Has real binary (>50KB non-txt/non-src file)
    let isSource = false;  // Has source code indicators
    let hasInstallHint = false; // Has INSTALL.txt
    const MIN_BINARY_SIZE = 50000; // 50KB threshold for "real" binary

    // Source code indicators
    const SOURCE_MARKERS = ['CMakeLists.txt', 'setup.py', 'Cargo.toml', 'go.mod', '.git'];
    // Makefile alone doesn't mean source - many packages include prebuilt + Makefile for install

    try {
        const stat = fs.statSync(dirPath);
        newest = stat.mtimeMs;
        const entries = readdirSafe(dirPath);

        // Check for INSTALL.txt hint
        if (entries.includes('INSTALL.txt')) {
            hasInstallHint = true;
        }

        // First pass: look for binaries (including in bin/ subdirectory)
        for (const entry of entries) {
            try {
                const fullPath = path.join(dirPath, entry);
                const s = fs.statSync(fullPath);
                if (s.isFile()) {
                    size += s.size;
                    fileCount++;
                    const isTxt = entry.endsWith('.txt') || entry.endsWith('.md');
                    const isSrc = entry.endsWith('.c') || entry.endsWith('.cpp') || entry.endsWith('.h') || entry.endsWith('.py') || entry.endsWith('.rs') || entry.endsWith('.go');
                    if (!isTxt && !isSrc && s.size > MIN_BINARY_SIZE) {
                        hasBinary = true;
                    }
                } else if (s.isDirectory()) {
                    // Check common binary directories
                    if (entry === 'bin' || entry === 'lib' || entry === 'Release' || entry === 'Debug') {
                        const subEntries = readdirSafe(fullPath);
                        for (const sub of subEntries.slice(0, 20)) {
                            try {
                                const subStat = fs.statSync(path.join(fullPath, sub));
                                if (subStat.isFile() && subStat.size > MIN_BINARY_SIZE) {
                                    hasBinary = true;
                                    break;
                                }
                            } catch (e) {}
                        }
                    }
                }
                if (s.mtimeMs > newest) newest = s.mtimeMs;
            } catch (e) {}
        }

        // Second pass: check for source markers (only if no binaries found)
        if (!hasBinary) {
            for (const marker of SOURCE_MARKERS) {
                if (entries.includes(marker)) {
                    isSource = true;
                    break;
                }
            }
            // Check subdirs for source markers too
            if (!isSource) {
                for (const entry of entries) {
                    try {
                        const s = fs.statSync(path.join(dirPath, entry));
                        if (s.isDirectory()) {
                            const subEntries = readdirSafe(path.join(dirPath, entry));
                            for (const marker of SOURCE_MARKERS) {
                                if (subEntries.includes(marker)) {
                                    isSource = true;
                                    break;
                                }
                            }
                        }
                    } catch (e) {}
                    if (isSource) break;
                }
            }
        }
    } catch (e) {}

    // Determine content type - binary takes priority over source
    let contentType = 'empty';
    if (hasBinary) {
        contentType = 'binary';
    } else if (isSource) {
        contentType = 'source';
    } else if (hasInstallHint) {
        contentType = 'hint';
    } else if (fileCount > 0) {
        contentType = 'unknown';
    }

    return {
        size,
        lastModified: new Date(newest).toISOString(),
        files: fileCount,
        contentType,
        // Legacy field for backward compat
        installHint: contentType === 'hint'
    };
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

function getCORSOrigin(req) {
    const origin = req.headers.origin || '';
    // Allow localhost on any port
    if (/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)) {
        return origin;
    }
    return '';
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
    const addr = req.socket?.remoteAddress || '';
    // IPv4 localhost
    if (addr === '127.0.0.1' || addr === '::1') return true;
    // IPv6 localhost
    if (addr === '::ffff:127.0.0.1') return true;
    // Socket file (always local)
    if (!addr) return true;
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
// in). Gated paths are refused for un-authed LAN visitors in Passworded/Accounts mode.
function isReadGated(urlPath) {
    if (urlPath.startsWith('/api/auth/') || urlPath.startsWith('/api/setup/')) return false;
    if (urlPath === '/api/health' || urlPath === '/api/status/tls') return false;
    if (urlPath.startsWith('/api/status/') || urlPath.startsWith('/api/catalog/') ||
        urlPath.startsWith('/api/archive/') || urlPath === '/api/downloads/stream') return true;
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
    // HttpOnly so JS can't read it; SameSite=Lax to resist CSRF; Path=/ site-wide;
    // Secure ONLY when the request came over TLS (else the browser would drop it on HTTP).
    return `varksid=${encodeURIComponent(token)}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${maxAgeSec}${secure ? '; Secure' : ''}`;
}
// POSTs that CHANGE the box's config/accounts — always admin (localhost or a
// logged-in admin), regardless of Use Mode. "Use" actions (downloads/requests/
// service starts) are gated per Use Mode instead (Open = anyone on the LAN).
const ADMIN_ONLY_POSTS = new Set(['/api/service/adduser']);
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
function isLanOrTailnet(req) {
    if (isLocalhost(req)) return true;
    const a = clientIp(req);
    if (!a) return true;                       // unix socket
    const m = a.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
    if (m) {
        const o = m.slice(1, 5).map(Number);
        if (o.some(n => n > 255)) return false;
        if (o[0] === 127) return true;                                 // loopback
        if (o[0] === 10) return true;                                  // 10.0.0.0/8
        if (o[0] === 172 && o[1] >= 16 && o[1] <= 31) return true;     // 172.16.0.0/12
        if (o[0] === 192 && o[1] === 168) return true;                 // 192.168.0.0/16
        if (o[0] === 100 && o[1] >= 64 && o[1] <= 127) return true;    // 100.64.0.0/10 CGNAT (tailnet)
        if (o[0] === 169 && o[1] === 254) return true;                 // link-local
        return false;
    }
    const low = a.toLowerCase();
    if (low === '::1') return true;
    if (/^f[cd][0-9a-f]{2}:/.test(low)) return true;   // ULA fc00::/7 (tailnet fd7a:…⊂ this)
    if (/^fe[89ab][0-9a-f]:/.test(low)) return true;   // link-local fe80::/10
    return false;
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
                    version: '1.0.0',
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
            case '/api/status/downloads': {
                const active = {};
                for (const [id, d] of downloads) {
                    active[id] = { ...d, pid: undefined };
                }
                return sendJSON(res, req, active);
            }
            case '/api/auth/status':
                // Read-only: is an admin set, which Use Mode, is this caller the
                // trusted box/localhost (`trusted`) and are they an authenticated
                // admin right now (`authed` = localhost or a valid session).
                return sendJSON(res, req, { ...auth.status(STATE_DIR), trusted: isLocalhost(req), authed: isAdmin(req) });
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
                return sendJSON(res, req, st);
            }
            case '/api/setup/recovery-card': {
                // The printable recovery card — box name/address + the one-time recovery
                // code. The code is a SECRET, so this is admin-only (localhost or a signed
                // session); un-authed peers can't read it.
                if (!isAdmin(req)) return sendJSON(res, req, { error: 'Admin only.', needsAuth: true }, 401);
                const s = commission.readSettings(STATE_DIR);
                const host = (req.headers.host || '').split(':')[0] || 'valark.local';
                const nm = (s.name || 'valark').toLowerCase().replace(/[^a-z0-9-]/g, '') || 'valark';
                return sendJSON(res, req, {
                    name: s.name || 'valark',
                    address: `http://${nm}.local/`,
                    addressAlt: `http://${host}/`,
                    recovery: commission.ensureRecovery(STATE_DIR),
                });
            }
            case '/api/catalog/content':
                return sendJSON(res, req, getCatalog('content'));
            case '/api/catalog/models':
                return sendJSON(res, req, getCatalog('models'));
            case '/api/downloads/stream':
                // SSE connection limit
                if (sseClients.size >= MAX_SSE_CONNECTIONS) {
                    res.writeHead(503, { 'Retry-After': '10' });
                    return res.end('Too many SSE connections');
                }
                res.writeHead(200, {
                    'Content-Type': 'text/event-stream',
                    'Cache-Control': 'no-cache',
                    'Connection': 'keep-alive',
                    ...(corsOrigin ? { 'Access-Control-Allow-Origin': corsOrigin } : {}),
                    ...SECURITY_HEADERS,
                });
                res.write(`event: init\ndata: ${JSON.stringify({ connected: true })}\n\n`);
                sseClients.add(res);
                req.on('close', () => sseClients.delete(res));
                return;
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
                case '/api/download/tools': {
                    const target = body.target || 'all';
                    if (!isAlphanumDash(target) || !VALID_TOOL_TARGETS.has(target)) {
                        result = { error: 'Invalid target. Use: ' + [...VALID_TOOL_TARGETS].slice(0, 5).join(', ') + '...' };
                    } else {
                        result = startDownload('tools',
                            path.join(ROOT, 'scripts/download-tools.sh'), [target]);
                    }
                    break;
                }
                case '/api/download/models': {
                    const tier = body.tier || 'all';
                    if (!VALID_MODEL_TIERS.has(tier)) {
                        result = { error: 'Invalid tier. Use: all, tier1, tier2, tier3' };
                    } else {
                        result = startDownload('models',
                            path.join(ROOT, 'scripts/download-models.sh'), [tier]);
                    }
                    break;
                }
                case '/api/download/content': {
                    const target = body.target || 'all';
                    if (!isAlphanumDash(target) && !VALID_CONTENT_TARGETS.has(target)) {
                        result = { error: 'Invalid content target' };
                    } else {
                        result = startDownload('content',
                            path.join(ROOT, 'scripts/download-zims.sh'), [target]);
                    }
                    break;
                }
                case '/api/download/update': {
                    const target = body.target || 'all';
                    if (!isAlphanumDash(target)) {
                        result = { error: 'Invalid update target' };
                    } else {
                        result = startDownload('update',
                            path.join(ROOT, 'scripts/update.sh'), [target]);
                    }
                    break;
                }
                case '/api/download/cancel':
                    result = cancelDownload(body.id);
                    break;
                case '/api/request': {
                    // One-click per-item request: pin + fetch a specific catalog item,
                    // auto-evicting lowest-priority unpinned content to fit the cap.
                    const kind = body.kind;
                    const id = body.id;
                    if (!VALID_REQUEST_KINDS.has(kind)) {
                        result = { error: 'Invalid kind. Use: content, model, tool' };
                    } else if (kind === 'tool') {
                        if (!isAlphanumDash(id) || !VALID_TOOL_TARGETS.has(id)) {
                            result = { error: 'Unknown tool: ' + String(id).slice(0, 40) };
                        } else {
                            result = startDownload('request',
                                path.join(ROOT, 'scripts/librarian.sh'), ['request', 'tool', id]);
                        }
                    } else if (!isCatalogId(id)) {
                        result = { error: 'Invalid item id' };
                    } else {
                        result = startDownload('request',
                            path.join(ROOT, 'scripts/librarian.sh'), ['request', kind, id]);
                    }
                    break;
                }
                case '/api/setup/commission':
                    // First-boot setup. Fail-closed on the claim token from the LAN;
                    // the box/localhost is trusted and may commission without one.
                    // (Public peers are already refused by the isLanOrTailnet gate.)
                    result = commission.commission(STATE_DIR, body, { trusted: isLocalhost(req) });
                    break;
                case '/api/service/start':
                    // Bring up an enabled + mirrored community service (chat/mail/forum/paste).
                    result = startService(body.id);
                    break;
                case '/api/service/adduser':
                    // Provision a login on a host-managed service (chat/mail). An admin
                    // action (ADMIN_ONLY_POSTS): the access gate above already required
                    // localhost or a logged-in admin, so a remote admin can do it too.
                    result = addServiceUser(body.id, body.username, body.password);
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

function serveStatic(res, filePath, req) {
    fs.stat(filePath, (err, stat) => {
        if (err) return send404(res);

        // Handle directories with a simple file listing
        if (stat.isDirectory()) {
            return serveDirectory(res, filePath);
        }

        const ext = path.extname(filePath).toLowerCase();
        const mime = MIME[ext] || 'application/octet-stream';
        const baseHeaders = {
            'Content-Type': mime,
            'Accept-Ranges': 'bytes',
            'Cache-Control': (ext === '.html' || ext === '.css' || ext === '.js') ? 'no-cache' : 'max-age=3600',
            ...SECURITY_HEADERS,
        };

        // HTTP Range support — a mirror serves multi-GB artifacts (models, ZIMs,
        // installers) and interrupted downloads must be resumable (curl -C -,
        // wget -c, browser resume). Single-range only; malformed ranges fall
        // through to a normal 200.
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
            const stream = fs.createReadStream(filePath, { start, end });
            stream.on('error', () => { try { res.destroy(); } catch (_) {} });
            return stream.pipe(res);
        }

        res.writeHead(200, { ...baseHeaders, 'Content-Length': stat.size });
        fs.createReadStream(filePath).pipe(res);
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
const ARCHIVE_DIRS = ['tools', 'models', 'content', 'sources', 'assets', 'installers'];
function serveArchive(res, req, relPath) {
    let clean;
    try { clean = decodeURIComponent(relPath); } catch (_) { clean = relPath; }
    clean = path.normalize(clean).replace(/^([/\\]|\.\.[/\\]?)+/, '');
    const top = clean.split(/[/\\]/)[0];
    if (!ARCHIVE_DIRS.includes(top)) return send404(res);
    const target = path.join(ROOT, clean);
    if (!isPathSafe(target, path.join(ROOT, top))) return send404(res);

    fs.stat(target, (err, stat) => {
        if (err) return send404(res);
        const base = path.basename(target);
        // HEAD preflight (the UI probes availability before downloading) — answer the
        // headers without spawning a tar / opening the file for every probe.
        if (req && req.method === 'HEAD') {
            res.writeHead(200, {
                'Content-Type': stat.isDirectory() ? 'application/gzip' : 'application/octet-stream',
                'Content-Disposition': `attachment; filename="${base}${stat.isDirectory() ? '.tar.gz' : ''}"`,
                ...SECURITY_HEADERS,
            });
            return res.end();
        }
        if (stat.isDirectory()) {
            res.writeHead(200, {
                'Content-Type': 'application/gzip',
                'Content-Disposition': `attachment; filename="${base}.tar.gz"`,
                ...SECURITY_HEADERS,
            });
            const tar = spawn('tar', ['-czf', '-', '-C', path.dirname(target), base]);
            tar.stdout.pipe(res);
            tar.on('error', () => { try { res.destroy(); } catch (_) {} });
            req.on('close', () => { try { tar.kill(); } catch (_) {} });
        } else {
            res.writeHead(200, {
                'Content-Type': 'application/octet-stream',
                'Content-Length': stat.size,
                'Content-Disposition': `attachment; filename="${base}"`,
                ...SECURITY_HEADERS,
            });
            const stream = fs.createReadStream(target);
            stream.on('error', () => { try { res.destroy(); } catch (_) {} });
            stream.pipe(res);
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
function pipeProxy(req, res, port, label, pathOverride) {
    // Fresh upstream socket per request (agent:false) + drop hop-by-hop headers.
    // Reusing the default agent's keep-alive sockets races against backends that
    // close idle connections (e.g. NodeBB): a reused half-closed socket throws
    // ECONNRESET → a spurious 503. The race surfaced intermittently only under
    // the added TLS latency of the HTTPS listener. A new socket each time is the
    // standard, robust behaviour for a small reverse proxy like this.
    // Never leak the Val Ark admin session cookie to backend sub-apps (NodeBB, The
    // Lounge, kiwix, …) — they don't need it and could log/exfiltrate the bearer token.
    const fwdHeaders = { ...req.headers, host: `127.0.0.1:${port}` };
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
        delete headers['content-security-policy'];
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
const APP_SERVICES = {
    chat:  { port: 9000, strip: true },    // The Lounge (web client mounts at root)
    mail:  { port: 1323, strip: true },    // alps webmail
    forum: { port: 4567, strip: false },   // NodeBB serves under its configured url base
    paste: { port: 8085, strip: true },    // MicroBin serves at root; PUBLIC_PATH only prefixes links
};
function proxyAppService(req, res, id, name) {
    const svc = APP_SERVICES[id];
    if (!svc) return send404(res);
    let targetPath = req.url;
    if (svc.strip) {
        targetPath = req.url.replace(new RegExp('^/app/' + id), '');
        if (!targetPath.startsWith('/')) targetPath = '/' + targetPath;
    }
    pipeProxy(req, res, svc.port, name || id, targetPath);
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
const COMMUNITY_ACCOUNTS = {
    chat:  { signup: 'host',   label: 'Chat',              note: 'IRC has no self-signup — the host creates your login, then you sign in at /app/chat/.' },
    mail:  { signup: 'host',   label: 'Mail',              note: 'The host provisions your mailbox (login + IMAP account); sign in at /app/mail/.' },
    forum: { signup: 'self',   label: 'Message Boards',    registerPath: '/app/forum/register', note: 'Create your own account on the forum’s Register page.' },
    paste: { signup: 'shared', label: 'Files & Pastebin',  note: 'One shared, access-gated instance — get the access code from your host (no per-user signup).' },
};

// Create a login on a host-provisioned community service (chat/mail). Minting a
// mail/chat login is an ADMIN action, so the caller localhost-gates it. forum users
// self-register and paste is a shared instance — neither is provisioned here.
function addServiceUser(id, username, password) {
    const model = COMMUNITY_ACCOUNTS[id];
    if (!model) return { error: 'Unknown service' };
    if (model.signup === 'self')   return { error: `Sign up for ${model.label} on its own Register page.`, registerPath: model.registerPath };
    if (model.signup === 'shared') return { error: `${model.label} is a shared instance — ask your host for the access code (no per-user signup).` };
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
    // Block path traversal attempts early (before URL normalization resolves ..)
    if (req.url.includes('..') || req.url.includes('%2e%2e') || req.url.includes('%2E%2E')) {
        return send404(res);
    }

    const parsedUrl = new URL(req.url, `http://localhost:${PORT}`);
    let urlPath = decodeURIComponent(parsedUrl.pathname);

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
    if (isReadGated(urlPath) && !readAllowed(req)) {
        return sendJSON(res, req, { error: 'Sign in to view this Val Ark.', needsAuth: true }, 401);
    }

    // API routes
    if (urlPath.startsWith('/api/')) {
        return handleAPI(req, res, urlPath);
    }

    // Reverse-proxy the embedded Kiwix server under one origin (/kiwix/*). This
    // keeps offline content INSIDE the Val Ark shell: same port to remember, and
    // the fixed top-nav stays on screen as a permanent "back to Val Ark" header
    // instead of stranding readers on a separate :8888 with no way home. Kiwix
    // runs with --urlRootLocation /kiwix, so its own links already point at
    // /kiwix/* — we just pipe bytes through, no HTML rewriting.
    if (urlPath === '/kiwix' || urlPath.startsWith('/kiwix/')) {
        return proxyKiwix(req, res);
    }

    // Community sub-apps (chat/mail/forum/paste, …) reverse-proxied at /app/<id>/
    // so they render inside the Val Ark shell with the same back-to-ark header.
    const appMatch = urlPath.match(/^\/app\/([a-z0-9-]+)(?:\/|$)/);
    if (appMatch) {
        return proxyAppService(req, res, appMatch[1]);
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
    // Warm the cache on startup
    getToolsStatus();
    getContentStatus();
    getModelsStatus();
    getStorageStatus();   // kicks off the (async, non-blocking) storage walk
    // Auto-start Kiwix content server, then keep its status eventually-consistent
    // (catches a late-binding library and a died instance — see reconcileKiwix).
    startKiwix();
    setInterval(reconcileKiwix, 30000);
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
            console.log(`     http://valark.local/   (or  http://<this-ip>/ )`);
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
