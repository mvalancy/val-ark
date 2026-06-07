#!/usr/bin/env node
// Val Ark API Server - Zero dependency Node.js server
// Serves web UI + provides status/control endpoints

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync, execFile, spawn } = require('child_process');

const PORT = parseInt(process.argv[2] || '3000', 10);
const ROOT = path.resolve(__dirname, '..');
const MODEL_ROOT = path.join(process.env.HOME || require('os').homedir(), 'models');

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
const VALID_MODEL_TIERS = new Set(['all', 'tier1', 'tier2', 'tier3']);
const VALID_CONTENT_TARGETS = new Set(['all', 'wikipedia', 'serve']);

function isAlphanumDash(str) {
    return typeof str === 'string' && /^[a-zA-Z0-9_-]+$/.test(str);
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
        // Measure the DATA disk (where content/models actually live), not the
        // repo's home disk — the trees are symlinks onto the data mount.
        let target = ROOT;
        try { target = fs.realpathSync(path.join(ROOT, 'content')); } catch {}
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

function sendJSON(res, req, data, status = 200) {
    const body = JSON.stringify(data);
    const corsOrigin = getCORSOrigin(req);
    res.writeHead(status, {
        'Content-Type': 'application/json',
        ...(corsOrigin ? { 'Access-Control-Allow-Origin': corsOrigin } : {}),
        'Content-Length': Buffer.byteLength(body),
        ...SECURITY_HEADERS,
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
    const addr = req.socket?.remoteAddress || '';
    // IPv4 localhost
    if (addr === '127.0.0.1' || addr === '::1') return true;
    // IPv6 localhost
    if (addr === '::ffff:127.0.0.1') return true;
    // Socket file (always local)
    if (!addr) return true;
    return false;
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

    // GET endpoints
    if (req.method === 'GET') {
        switch (urlPath) {
            case '/api/health':
                return sendJSON(res, req, {
                    status: 'ok',
                    uptime: process.uptime(),
                    version: '1.0.0',
                    timestamp: new Date().toISOString()
                });
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

    // POST endpoints - restricted to localhost for security
    if (req.method === 'POST') {
        // Download/control endpoints are restricted to localhost only
        // This prevents remote exploitation while allowing local browser access
        if (!isLocalhost(req)) {
            return sendJSON(res, req, {
                error: 'Download operations are only available from localhost for security.'
            }, 403);
        }

        readBody(req).then((body) => {
            let result;
            switch (urlPath) {
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

function serveStatic(res, filePath) {
    fs.stat(filePath, (err, stat) => {
        if (err) return send404(res);

        // Handle directories with a simple file listing
        if (stat.isDirectory()) {
            return serveDirectory(res, filePath);
        }

        const ext = path.extname(filePath).toLowerCase();
        const mime = MIME[ext] || 'application/octet-stream';

        res.writeHead(200, {
            'Content-Type': mime,
            'Content-Length': stat.size,
            'Cache-Control': (ext === '.html' || ext === '.css' || ext === '.js') ? 'no-cache' : 'max-age=3600',
            ...SECURITY_HEADERS,
        });
        fs.createReadStream(filePath).pipe(res);
    });
}

// HTML-escape untrusted text (filenames from the data disk, paths) before it
// goes into the autoindex / error pages — prevents stored XSS via attacker-named
// files. encodeURI keeps href path slashes while encoding metacharacters.
function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
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
    const proxyReq = http.request({
        host: '127.0.0.1', port, method: req.method, path: pathOverride || req.url,
        headers: { ...req.headers, host: `127.0.0.1:${port}` },
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
let _svcCache = { data: null, ts: 0 };
async function getServicesStatus() {
    const now = Date.now();
    if (_svcCache.data && (now - _svcCache.ts) < 5000) return _svcCache.data;
    const ids = Object.keys(APP_SERVICES);
    const ups = await Promise.all(ids.map((id) => probePort(APP_SERVICES[id].port)));
    const data = {};
    ids.forEach((id, i) => { data[id] = { port: APP_SERVICES[id].port, path: `/app/${id}/`, running: ups[i] }; });
    _svcCache = { data, ts: now };
    return data;
}

// =============================================================================
// Server
// =============================================================================
const server = http.createServer((req, res) => {
    // Block path traversal attempts early (before URL normalization resolves ..)
    if (req.url.includes('..') || req.url.includes('%2e%2e') || req.url.includes('%2E%2E')) {
        return send404(res);
    }

    const parsedUrl = new URL(req.url, `http://localhost:${PORT}`);
    let urlPath = decodeURIComponent(parsedUrl.pathname);

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
        return serveStatic(res, path.join(ROOT, 'web-ui', 'index.html'));
    }

    // Serve from project root for known directories
    const segments = normalized.split(path.sep).filter(Boolean);
    const topLevel = segments[0];
    const projectDirs = ['tools', 'content', 'sources', 'models', 'assets', 'docs'];
    if (projectDirs.includes(topLevel)) {
        const fullPath = path.join(ROOT, normalized);
        if (!isPathSafe(fullPath, ROOT)) return send404(res);
        return serveStatic(res, fullPath);
    }

    // Serve LICENSE from project root
    if (normalized === '/LICENSE' || normalized === path.sep + 'LICENSE') {
        return serveStatic(res, path.join(ROOT, 'LICENSE'));
    }

    // Everything else from web-ui/
    const webPath = path.join(ROOT, 'web-ui', normalized);
    if (!isPathSafe(webPath, path.join(ROOT, 'web-ui'))) return send404(res);

    serveStatic(res, webPath);
});

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

function startKiwix() {
    // Opt-out (used by the test harness so an ephemeral instance doesn't fight
    // the production kiwix for the port, and for content-less dev runs).
    if (process.env.VALARK_DISABLE_KIWIX) { kiwixStatus = { running: false, port: KIWIX_PORT, url: '', path: KIWIX_ROOT + '/', files: 0 }; return; }
    const kiwixBin = findKiwixServe();
    const zimFiles = findZimFiles();
    if (!kiwixBin || zimFiles.length === 0) { kiwixStatus = { running: false, port: KIWIX_PORT, url: '', path: KIWIX_ROOT + '/', files: 0 }; return; }
    serveWithRetry(kiwixBin, zimFiles, 0);
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
    setTimeout(() => probe(90), 1000);
}

// Cleanup on exit
process.on('exit', () => { if (kiwixProcess) kiwixProcess.kill(); });
process.on('SIGINT', () => { if (kiwixProcess) kiwixProcess.kill(); process.exit(0); });
process.on('SIGTERM', () => { if (kiwixProcess) kiwixProcess.kill(); process.exit(0); });

// Bind address: defaults to all interfaces (Val Ark is a LAN hub by design), but
// honor VALARK_BIND so a security-conscious operator can restrict it (e.g.
// 127.0.0.1 for host-only access).
const WEB_BIND = process.env.VALARK_BIND || '0.0.0.0';
server.listen(PORT, WEB_BIND, () => {
    console.log(`Val Ark server running at http://localhost:${PORT} (bind ${WEB_BIND})`);
    console.log(`Serving from: ${ROOT}`);
    // Warm the cache on startup
    getToolsStatus();
    getContentStatus();
    getModelsStatus();
    getStorageStatus();   // kicks off the (async, non-blocking) storage walk
    // Auto-start Kiwix content server
    startKiwix();
});
