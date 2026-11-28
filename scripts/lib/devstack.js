// Val Ark — the developer stack as the web UI sees it (zero-dep, #397).
//
// data/dev-stack.tsv lists projects; scripts/lib/release_mirror.py mirrors their current
// release into DEVSTACK_DIR. This module joins the two for GET /api/devstack: one entry per
// catalog row with what is on disk (versions, files, sizes, platforms), so the web UI's
// Library ▸ Developer stack cards are generated from the list, never hand-written.
//
// Layout (the same rules as release_mirror.py's "Dest layout" and static_site.py):
//   gh        <group>/<owner>/<repo>/<tag>/<file>
//   gnu       <group>/gnu/<ref>/<version>/<file>
//   pypi      <group>/pypi/<ref>/<version>/<file>      snap  <group>/snap/<ref>/<version>/<file>
//   go        <group>/go/<version>/<file>               python <group>/python/<version>/<file>
//   template  <group>/<host>/<version>/<up to 3 dirs>/<file>
//   index     <group>/<host>/<dir path>/<file>          (no version dir)
//   pypi-top  <group>/pypi/<project>/...                (counted, not listed)
//
// Cheap on a big tree: every read is one directory with an entry cap, nothing recurses
// beyond the layout above, all I/O is async, and symlinks are never followed.
'use strict';
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');

const PLATFORMS = ['linux-x86_64', 'linux-arm64', 'macos-arm64', 'windows-x64', 'source'];
const ARCHIVE_PREFIX = '/api/archive/dev-stack/';
const MAX_ENTRIES = 500;    // entries read from any one directory
const MAX_VERSIONS = 3;     // newest versions listed per project
const MAX_FILES = 200;      // files listed per version
const POOL = 16;            // projects scanned at once
// Files the mirror writes for itself, not for people.
const SIDECAR = /^\.|\.part$|\.verified$|\.source\.json$|^INSTALL\.txt$/;

// release_mirror.py safe(): one path component built from an upstream name.
function safe(part) {
    return String(part).replace(/[^A-Za-z0-9._+@=-]/g, '-').replace(/^[.-]+|[.-]+$/g, '') || '_';
}

// The stable id of a catalog row: the guide file name, the ?ref= of the guide endpoint and
// the card's route. gh rows are <owner>__<repo>; other kinds are <kind>__<ref slug>
// (release_mirror.py guide_key() is the same rule; tests/test-devstack-ui.sh compares them).
function refKey(kind, ref) {
    const slug = ref.replace(/^[a-z]+:\/\//, '').split('/').filter(Boolean).map(safe).join('__') || '_';
    if (kind === 'gh') return slug;
    return slug === '_' ? kind : `${kind}__${slug}`;
}

// rank|kind|ref|match|group|note — match may contain '|' (everything between ref and the
// last two fields).
function parseTsv(text) {
    const rows = [];
    for (const line of String(text).split('\n')) {
        if (!line.trim() || line.trimStart().startsWith('#')) continue;
        const p = line.split('|');
        if (p.length < 6) continue;
        const [rank, kind, ref] = p;
        const note = p[p.length - 1].trim(), group = p[p.length - 2];
        rows.push({ rank: parseInt(rank, 10) || 0, kind, ref, match: p.slice(3, -2).join('|'), group, note,
                    key: refKey(kind, ref), name: displayName(kind, ref, note) });
    }
    return rows;
}

function displayName(kind, ref, note) {
    if (kind === 'gh' || /^gh(tag)?:/.test(ref)) return ref.split('/').pop();
    if (kind === 'gnu' || kind === 'pypi' || kind === 'snap') return ref;
    if (kind === 'go') return 'Go';
    if (kind === 'python') return 'Python';
    return note.split(/ \(|: /)[0] || ref;      // index / template / pypi-top: the note's first clause
}

// The project's directory under DEVSTACK_DIR, as path segments (null = unknown kind).
function projectPath(row) {
    const g = safe(row.group);
    switch (row.kind) {
        case 'gh': return [g, ...row.ref.split('/').map(safe)];
        case 'gnu': case 'pypi': case 'snap': return [g, row.kind, safe(row.ref)];
        case 'go': case 'python': return [g, row.kind];
        case 'pypi-top': return [g, 'pypi'];
        case 'index': case 'template': {
            const first = row.kind === 'index' ? row.ref : row.match.split(/\s+/).find(Boolean) || '';
            let u; try { u = new URL(first.replace(/[{}]/g, '')); } catch (_) { return null; }
            const dirs = row.kind === 'index' ? u.pathname.split('/').filter(Boolean) : [];
            return [g, safe(u.host), ...dirs.map(safe)];
        }
        default: return null;
    }
}

// Which Val Ark platform a release file is for, from its name ('' = none of ours:
// checksums, 32-bit, other CPUs, macOS Intel-only, Windows on ARM). A name that says nothing
// (docker-29.1.0.tgz, kubectl) is read again with its folders in front: `dir` is the path
// under the group, which names the OS / CPU for index and template rows and the project
// for the rest (git-for-windows, mingw-builds-binaries).
function inferPlatform(name, dir = '') {
    return platformOf(name) || (dir ? platformOf(dir + name) : '');
}
function platformOf(name) {
    const n = String(name).toLowerCase();
    if (/\.(sha\d*|sha256sum|asc|sig|pem|sbom|json|txt|md|yml|yaml|cert|pub|minisig|intoto\.jsonl)$/.test(n)) return '';
    if (/(^|[-_./])(src|sources?)([-_./]|$)/.test(n)) return 'source';
    if (/(^|[^a-z0-9])(i[36]86|386|x86(?![-_]64)|win32|32-?bit|armv\d\w*|armhf|armel|arm(?![a-z0-9])|riscv\w*|ppc\w*|s390x|mips\w*|loong\w*)(?![a-z0-9])/.test(n)) return '';
    const arm = /arm64|aarch64/.test(n);
    const x64 = /x86[-_]64|amd64|(^|[^a-z0-9])x64|win64|64-?bit/.test(n);
    if (/(^|[^a-z])win(dows|64)?(?![a-z])|msvc|mingw|\.(exe|msi|msix)$/.test(n)) return arm ? '' : 'windows-x64';
    if (/darwin|(^|[^a-z])(mac(os|osx)?|osx|apple)(?![a-z])|\.(dmg|pkg)$/.test(n)) return (x64 && !arm) ? '' : 'macos-arm64';
    if (/linux|musl|\.(appimage|deb|rpm|snap)$/.test(n)) return arm ? 'linux-arm64' : 'linux-x86_64';
    return '';
}

// release_mirror.py vkey(): numeric parts compare numerically ('1.10' > '1.9').
function versionCompare(a, b) {
    const parts = (s) => s.replace(/^[vV]/, '').split(/[.\-_+]/);
    const x = parts(a), y = parts(b);
    for (let i = 0; i < Math.max(x.length, y.length); i++) {
        if (x[i] === undefined) return -1;
        if (y[i] === undefined) return 1;
        const nx = /^\d+$/.test(x[i]), ny = /^\d+$/.test(y[i]);
        if (nx && ny) { if (+x[i] !== +y[i]) return +x[i] - +y[i]; }
        else if (nx !== ny) return nx ? -1 : 1;
        else if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1;
    }
    return 0;
}

// Up to MAX_ENTRIES dirents of one directory. A symlink's dirent is neither a file nor a
// directory to the callers, so links are never followed.
async function readDir(dir) {
    const out = [];
    let d;
    try { d = await fsp.opendir(dir); } catch (_) { return out; }
    try {
        for await (const e of d) {
            if (!SIDECAR.test(e.name)) out.push(e);
            if (out.length >= MAX_ENTRIES) break;
        }
    } catch (_) { /* a directory that vanished mid-read: what we have is enough */ }
    return out;
}

// Files under one version dir: `depth` more directory levels (0 for every kind but template).
async function listFiles(dir, rel, depth, files) {
    for (const e of (await readDir(dir)).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))) {
        if (e.isDirectory()) {
            if (depth > 0) await listFiles(path.join(dir, e.name), [...rel, e.name], depth - 1, files);
        } else if (e.isFile()) {
            if (files.length >= MAX_FILES) { files.truncated = true; return; }
            let size = 0;
            try { size = (await fsp.stat(path.join(dir, e.name))).size; } catch (_) { continue; }
            files.push({ name: e.name, size, platform: inferPlatform(e.name, rel.slice(1).join('/') + '/'),
                         url: ARCHIVE_PREFIX + [...rel, e.name].map(encodeURIComponent).join('/') });
        }
    }
}

async function scanProject(base, realBase, row) {
    const p = { key: row.key, ref: row.ref, kind: row.kind, group: row.group, name: row.name, note: row.note,
                mirrored: false, bytes: 0, platforms: [], versions: [] };
    const rel = projectPath(row);
    if (!rel || !realBase) return p;
    const dir = path.join(base, ...rel);
    // A symlinked group / project dir must not lead the listing outside the tree.
    let real; try { real = await fsp.realpath(dir); } catch (_) { return p; }
    if (!real.startsWith(realBase + path.sep)) return p;
    if (row.kind === 'pypi-top') {
        p.packages = (await readDir(dir)).filter((e) => e.isDirectory()).length;
        p.mirrored = p.packages > 0;
        return p;
    }
    let versions;
    if (row.kind === 'index') {
        // No version dir: the version is in the file name, read back with the row's own
        // (?P<v>...) group when it has one.
        versions = [{ version: '', dir, rel }];
    } else {
        const held = (await readDir(dir)).filter((e) => e.isDirectory()).map((e) => e.name)
            .sort(versionCompare).reverse();
        p.versionsHeld = held.length;
        versions = held.slice(0, MAX_VERSIONS).map((v) => ({ version: v, dir: path.join(dir, v), rel: [...rel, v] }));
    }
    for (const v of versions) {
        const files = [];
        await listFiles(v.dir, v.rel, row.kind === 'template' ? 3 : 0, files);
        if (!files.length) continue;
        if (row.kind === 'index') v.version = indexVersion(row.match, files);
        p.versions.push({ version: v.version, bytes: files.reduce((s, f) => s + f.size, 0),
                          files, truncated: !!files.truncated });
    }
    p.mirrored = p.versions.length > 0;
    p.bytes = p.versions.reduce((s, v) => s + v.bytes, 0);
    const seen = new Set(p.versions.flatMap((v) => v.files.map((f) => f.platform)));
    p.platforms = PLATFORMS.filter((x) => seen.has(x));
    return p;
}

function indexVersion(match, files) {
    let rx;
    try { rx = new RegExp(match.replace(/\(\?P</g, '(?<')); } catch (_) { return ''; }
    const found = files.map((f) => (rx.exec(f.name) || {}).groups).map((g) => g && g.v).filter(Boolean);
    return found.sort(versionCompare).pop() || '';
}

// { groups, projects } for every catalog row, in catalog order. Never throws: an unreadable
// catalog is an empty list, an unreadable tree is "not mirrored".
async function listing(tsvPath, guidesDir, base) {
    let rows = [];
    try { rows = parseTsv(await fsp.readFile(tsvPath, 'utf8')); } catch (_) {}
    let realBase = null;
    try { realBase = await fsp.realpath(base); } catch (_) {}
    let guides = [];
    try { guides = await fsp.readdir(guidesDir); } catch (_) {}
    const hasGuide = new Set(guides.filter((n) => n.endsWith('.md')).map((n) => n.slice(0, -3)));
    const projects = new Array(rows.length);
    let next = 0;
    await Promise.all(Array.from({ length: POOL }, async () => {
        while (next < rows.length) {
            const i = next++;
            const row = rows[i];
            const p = await scanProject(base, realBase, row);
            p.guide = hasGuide.has(row.key);
            projects[i] = p;
        }
    }));
    return { groups: [...new Set(rows.map((r) => r.group))], projects };
}

// The offline guide for a catalog key, or null. `keys` is the allowlist (the catalog's own
// keys): the file name is always one of them, never text from a request. A guide whose whole
// body is "see: <key>" stands for that key's guide (one hop: Docker's two engine rows share one).
async function guide(guidesDir, key, keys) {
    const read = async (k) => {
        if (!keys.has(k)) return null;
        try { return await fsp.readFile(path.join(guidesDir, k + '.md'), 'utf8'); } catch (_) { return null; }
    };
    const text = await read(key);
    const see = text && /^see:\s*(\S+)\s*$/.exec(text);
    return see ? read(see[1]) : text;
}

// Run-check plan for scripts/verify.sh (verify_devstack): one line per data/dev-stack-checks.tsv
// row whose project is mirrored, fields joined by US (0x1f):
//   run  <name> <file> <binary> <args> <expect>    the newest version's file for `platform`
//   skip <name>                                     mirrored, but nothing for `platform`
// Check rows are ref|file regex|binary|args|expect; the file regex may contain '|'.
async function checks(checksPath, tsvPath, base, platform) {
    const { projects } = await listing(tsvPath, '', base);
    const lines = [];
    for (const line of (await fsp.readFile(checksPath, 'utf8')).split('\n')) {
        if (!line.trim() || line.trimStart().startsWith('#')) continue;
        const f = line.split('|');
        if (f.length < 5) continue;
        const p = projects.find((x) => x.ref === f[0]);
        if (!p || !p.mirrored) continue;
        let rx; try { rx = new RegExp(f.slice(1, -3).join('|')); } catch (_) { rx = null; }
        const hit = rx && p.versions[0].files.find((x) => x.platform === platform && rx.test(x.name));
        lines.push(hit
            ? ['run', p.name, path.join(base, ...hit.url.slice(ARCHIVE_PREFIX.length).split('/').map(decodeURIComponent)), ...f.slice(-3)]
            : ['skip', p.name]);
    }
    return lines.map((l) => l.join('\x1f'));
}

module.exports = { PLATFORMS, parseTsv, refKey, projectPath, inferPlatform, versionCompare, listing, guide, checks };

// CLI: devstack.js checks <checks.tsv> <dev-stack.tsv> <dev-stack dir> <platform>
if (require.main === module) {
    const [cmd, ...args] = process.argv.slice(2);
    if (cmd !== 'checks' || args.length !== 4) {
        console.error('usage: devstack.js checks <checks.tsv> <dev-stack.tsv> <dev-stack dir> <platform>');
        process.exit(64);
    }
    checks(...args).then((lines) => { if (lines.length) console.log(lines.join('\n')); },
                         (e) => { console.error(String(e && e.message || e)); process.exit(1); });
}
