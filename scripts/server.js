#!/usr/bin/env node
// Val Ark API Server - Zero dependency Node.js server
// Serves web UI + provides status/control endpoints

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync, spawn } = require('child_process');

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
        const output = execSync('/usr/bin/df -B1 --output=size,used,avail .', {
            cwd: ROOT, encoding: 'utf8', timeout: 5000,
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

// Shallow directory info: stat immediate children only, not recursive
function shallowDirInfo(dirPath) {
    let size = 0;
    let newest = 0;
    let fileCount = 0;
    let hasBinary = false; // Has real binary (>50KB non-txt file)
    const MIN_BINARY_SIZE = 50000; // 50KB threshold for "real" binary
    try {
        const stat = fs.statSync(dirPath);
        newest = stat.mtimeMs;
        const entries = readdirSafe(dirPath);
        for (const entry of entries) {
            try {
                const s = fs.statSync(path.join(dirPath, entry));
                if (s.isFile()) {
                    size += s.size;
                    fileCount++;
                    // Check if this is a real binary (not just a text hint)
                    const isTxt = entry.endsWith('.txt') || entry.endsWith('.md');
                    if (!isTxt && s.size > MIN_BINARY_SIZE) {
                        hasBinary = true;
                    }
                } else if (s.isDirectory()) {
                    // Check subdirectories for binaries too (e.g., nested extracts)
                    const subEntries = readdirSafe(path.join(dirPath, entry));
                    for (const sub of subEntries.slice(0, 10)) { // Limit check
                        try {
                            const subStat = fs.statSync(path.join(dirPath, entry, sub));
                            if (subStat.isFile() && subStat.size > MIN_BINARY_SIZE) {
                                hasBinary = true;
                                break;
                            }
                        } catch (e) {}
                    }
                }
                if (s.mtimeMs > newest) newest = s.mtimeMs;
            } catch (e) {}
        }
    } catch (e) {}
    return {
        size,
        lastModified: new Date(newest).toISOString(),
        files: fileCount,
        installHint: !hasBinary && size < MIN_BINARY_SIZE
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
        if (err || !stat.isFile()) return send404(res);

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
const KIWIX_PORT = 8888;
let kiwixProcess = null;
let kiwixStatus = { running: false, port: KIWIX_PORT, url: '', files: 0 };

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
                // Only serve ZIM files that are at least 95% complete
                try {
                    const stat = fs.statSync(path.join(zimDir, f));
                    const expected = ZIM_EXPECTED_SIZES[f];
                    if (expected && stat.size < expected * 0.95) {
                        console.log(`Skipping incomplete ZIM: ${f} (${(stat.size/1073741824).toFixed(1)}GB / ${(expected/1073741824).toFixed(0)}GB)`);
                        return false;
                    }
                    // For unknown files, require at least 100MB
                    if (!expected && stat.size < 100 * 1048576) return false;
                    return true;
                } catch { return false; }
            })
            .map(f => path.join(zimDir, f));
    } catch { return []; }
}

function startKiwix() {
    const kiwixBin = findKiwixServe();
    const zimFiles = findZimFiles();

    if (!kiwixBin || zimFiles.length === 0) {
        kiwixStatus = { running: false, port: KIWIX_PORT, url: '', files: 0 };
        return;
    }

    try {
        kiwixProcess = spawn(kiwixBin, ['--port', String(KIWIX_PORT), ...zimFiles], {
            stdio: ['ignore', 'ignore', 'pipe'],
            detached: false,
        });

        // Capture stderr for error reporting
        let stderrBuf = '';
        kiwixProcess.stderr.on('data', (chunk) => { stderrBuf += chunk.toString().slice(-500); });

        kiwixProcess.on('error', (err) => {
            console.error(`Kiwix failed to start: ${err.message}`);
            kiwixStatus.running = false;
        });

        kiwixProcess.on('exit', (code) => {
            kiwixStatus.running = false;
            kiwixProcess = null;
            if (code !== 0 && code !== null) {
                console.error(`Kiwix exited with code ${code}${stderrBuf ? ': ' + stderrBuf.trim() : ''}`);
            }
        });

        kiwixStatus = {
            running: true,
            port: KIWIX_PORT,
            url: `http://localhost:${KIWIX_PORT}`,
            files: zimFiles.length,
        };

        console.log(`Kiwix serving ${zimFiles.length} ZIM file(s) at http://localhost:${KIWIX_PORT}`);
    } catch (err) {
        console.error(`Failed to start Kiwix: ${err.message}`);
    }
}

// Cleanup on exit
process.on('exit', () => { if (kiwixProcess) kiwixProcess.kill(); });
process.on('SIGINT', () => { if (kiwixProcess) kiwixProcess.kill(); process.exit(0); });
process.on('SIGTERM', () => { if (kiwixProcess) kiwixProcess.kill(); process.exit(0); });

server.listen(PORT, () => {
    console.log(`Val Ark server running at http://localhost:${PORT}`);
    console.log(`Serving from: ${ROOT}`);
    // Warm the cache on startup
    getToolsStatus();
    getContentStatus();
    getModelsStatus();
    // Auto-start Kiwix content server
    startKiwix();
});
