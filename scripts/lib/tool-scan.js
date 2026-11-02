// Val Ark — mirrored-tool directory scan + post-mirror verification (zero-dep, pure).
//
// Why this exists: the web UI decides "Mirrored" vs "Not Mirrored" from a SHALLOW scan
// of tools/<platform>/<tool>/. Most upstream archives wrap their payload in one top
// directory (piper -> piper/piper, onnxruntime -> onnxruntime-linux-x64-1.2x/, vosk,
// syncthing, ...). download_and_extract() unpacks them as-is, so the real files sit a
// level or two down — and the old scan, which only looked at the top level, called the
// tool "empty". The Mirror button then kept coming back, and re-clicking it "finished"
// in a second ("Already extracted — skipping") while the badge never changed: the
// "fake download that never finishes" the owner hit on piper-tts.
//
// scanToolDir() fixes the detection: it descends through wrapper dirs under a small,
// bounded budget (never the 45k-file walk the shallow scan was written to avoid).
// verifyToolMirror() is the post-job check the job manager reports to the UI.
'use strict';
const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');

function readdirSafe(dir) {
    try { return fs.readdirSync(dir); }
    catch { return []; }
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

const MIN_BINARY_SIZE = 50000;
const SRC_EXT = /\.(c|cpp|h|py|rs|go|txt|md)$/;
const SOURCE_MARKERS = ['CMakeLists.txt', 'setup.py', 'Cargo.toml', 'go.mod', '.git'];

// Wrapper-aware scan of ONE tools/<platform>/<tool> directory. Same result shape as
// shallowDirInfo (size, files, contentType, installHint, lastModified) so callers and
// the UI are unchanged, but when the top level shows nothing (empty / only tiny files)
// it walks the non-hidden subdirectories breadth-first — at most `maxDepth` levels and
// `maxEntries` stat calls — looking for a real binary or a source marker. Hidden dirs
// (.dist archive history, .git) are never entered. `scanned: 'wrapped'` marks a result
// that was found below the top level.
function scanToolDir(dirPath, opts) {
    const maxDepth = (opts && opts.maxDepth) || 3;
    const maxEntries = (opts && opts.maxEntries) || 400;
    const info = shallowDirInfo(dirPath);
    if (info.contentType !== 'empty' && info.contentType !== 'unknown') return info;

    let budget = maxEntries;
    let files = info.files || 0, size = info.size || 0, newest = Date.parse(info.lastModified) || 0;
    let hasBinary = false, isSource = false;
    let level = [dirPath];
    for (let depth = 0; depth < maxDepth && level.length && budget > 0 && !hasBinary; depth++) {
        const next = [];
        for (const dir of level) {
            for (const entry of readdirSafe(dir)) {
                if (budget-- <= 0) break;
                if (entry.startsWith('.') && !SOURCE_MARKERS.includes(entry)) continue;
                const full = path.join(dir, entry);
                let st;
                try { st = fs.statSync(full); } catch { continue; }
                if (st.isDirectory()) {
                    if (entry === '.git') { isSource = true; continue; }
                    next.push(full);
                } else if (st.isFile()) {
                    if (dir === dirPath) continue;          // top level was already counted
                    files++; size += st.size;
                    if (st.mtimeMs > newest) newest = st.mtimeMs;
                    if (SOURCE_MARKERS.includes(entry)) isSource = true;
                    if (!SRC_EXT.test(entry) && st.size > MIN_BINARY_SIZE) hasBinary = true;
                }
            }
        }
        level = next;
    }
    let contentType = info.contentType;
    if (hasBinary) contentType = 'binary';
    else if (isSource) contentType = 'source';
    else if (files > 0) contentType = 'unknown';
    return {
        size, files,
        lastModified: new Date(newest || Date.now()).toISOString(),
        contentType,
        installHint: contentType === 'hint',
        scanned: (contentType !== info.contentType) ? 'wrapped' : undefined,
    };
}

// ── archive verification ─────────────────────────────────────────────────────
// Mirrors keep the pristine upstream archive under <tool>/.dist/. Test each one so a
// truncated / corrupt download is reported instead of shown as "Mirrored". Async (the
// server's event loop must not stall on a big archive) and bounded: archives bigger
// than maxBytes are reported as "not deep-checked", never silently passed.
function _run(cmd, args, timeoutMs) {
    return new Promise((resolve) => {
        execFile(cmd, args, { timeout: timeoutMs, stdio: 'ignore' }, (err) => {
            if (!err) return resolve({ status: 0 });
            if (err.code === 'ENOENT') return resolve({ missing: true });
            resolve({ status: typeof err.code === 'number' ? err.code : 1 });
        });
    });
}
async function testArchive(file, maxBytes) {
    let st; try { st = fs.statSync(file); } catch { return { ok: false, reason: 'missing' }; }
    if (!st.isFile() || st.size === 0) return { ok: false, reason: 'zero bytes' };
    if (st.size > maxBytes) return { ok: null, reason: 'too large to deep-check' };
    let r;
    if (/\.(tar\.gz|tgz)$/i.test(file)) r = await _run('tar', ['-tzf', file], 600000);
    else if (/\.(tar\.xz|txz)$/i.test(file)) r = await _run('tar', ['-tJf', file], 600000);
    else if (/\.zip$/i.test(file)) r = await _run('unzip', ['-tqq', file], 600000);
    else if (/\.gz$/i.test(file)) r = await _run('gzip', ['-t', file], 600000);
    else return { ok: true, reason: 'size > 0' };     // AppImage / raw binary: non-empty is all we can assert
    if (r.missing) return { ok: null, reason: 'no checker available' };
    return r.status === 0 ? { ok: true } : { ok: false, reason: 'archive is corrupt or truncated' };
}

const PLATFORM_DIRS = ['linux-arm64', 'linux-x86_64', 'macos-arm64', 'windows-x64'];

// What is on disk for <toolName> across every platform dir, plus archive integrity.
// platforms[]: { platform, state: 'mirrored'|'source'|'hint'|'empty'|'absent', files,
//                size, verified: true|false|null, detail }
async function verifyToolMirror(toolsDir, toolName, opts) {
    const maxBytes = (opts && opts.maxArchiveBytes) || 600 * 1024 * 1024;
    const platforms = [];
    for (const platform of PLATFORM_DIRS) {
        const dir = path.join(toolsDir, platform, toolName);
        let st; try { st = fs.statSync(dir); } catch { platforms.push({ platform, state: 'absent', files: 0, size: 0, verified: null }); continue; }
        if (!st.isDirectory()) { platforms.push({ platform, state: st.size > 0 ? 'mirrored' : 'empty', files: 1, size: st.size, verified: st.size > 0 }); continue; }
        const info = scanToolDir(dir);
        const state = info.contentType === 'binary' ? 'mirrored'
            : info.contentType === 'source' ? 'source'
            : info.contentType === 'hint' ? 'hint'
            : info.contentType === 'unknown' ? 'mirrored' : 'empty';
        let verified = null, detail = '';
        if (state === 'mirrored' || state === 'source') {
            const dist = path.join(dir, '.dist');
            const arcs = readdirSafe(dist).filter(f => !f.startsWith('initial-') && !f.startsWith('prev-'));
            if (arcs.length) {
                verified = true;
                for (const a of arcs) {
                    const t = await testArchive(path.join(dist, a), maxBytes);
                    if (t.ok === false) { verified = false; detail = `${a}: ${t.reason}`; break; }
                    if (t.ok === null && verified === true) { verified = null; detail = `${a}: ${t.reason}`; }
                }
            } else if (info.files > 0) { verified = true; detail = 'files present (no archive kept)'; }
        }
        platforms.push({ platform, state, files: info.files || 0, size: info.size || 0, verified, detail: detail || undefined });
    }
    return platforms;
}

module.exports = { shallowDirInfo, scanToolDir, verifyToolMirror, testArchive, readdirSafe, PLATFORM_DIRS };
