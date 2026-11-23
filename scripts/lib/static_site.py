#!/usr/bin/env python3
"""Static catalog of an archive: explore it from a plain file server (no server.js).

Writes <out>/index.html, <out>/browse/<section>.html (a card grid per section) and
<out>/browse/item/<id>.html (one detail page per entry), plus browse/thumbs/ (logos, model-card
images, ZIM illustrations, generated badges), browse/art/ (pop-up art) and browse/summary.json.
Self-contained HTML: inline CSS, RELATIVE links only, no external URLs, no JavaScript requirement
(the search box is progressive). Works over file://, an SMB share opened in a file explorer, a USB
disk or `python3 -m http.server`.

Usage (stdlib only):
  static_site.py --root DIR [--out DIR] [--section NAME=PATH ...] [--listing TSV] [--pending TSV]
                 [--walk NAME ...] [--max-rows N] [--max-files N] [--meta-limit N] [--zim-limit N]
                 [--max-details N] [--walk-limit N] [--title TEXT] [--web-ui DIR] [--data-dir DIR]
                 [--art-dir DIR] [--now EPOCH]

  --root       the archive root; sections are its known sub-directories (models, content, tools,
               installers, dev-stack, software, datasets, sources). --section NAME=PATH moves one
               (relative to --root or absolute; NAME=- drops it).
  --out        where index.html + browse/ go (default --root).
  --listing    TSV of the files present, `path<TAB>size[<TAB>mtime]`, relative to --root ('-' =
               stdin). With a listing nothing is walked, so a caller with its own index never walks
               a slow network share; --walk NAME still walks section NAME (one the listing misses).
  --pending    the same TSV for files still on the way ("queued" on the cards).
  --max-rows   cards per section page (default 3000; the rest are summarised).
  --max-files  files listed on a detail page (default 60, largest first).
  --meta-limit README / model-card reads per run (default 4000; 64 KiB each, images 1 MiB).
  --zim-limit  ZIM files opened per run for their title / description / illustration (default
               400; results are cached in browse/zim-meta.json, so later runs fill in the rest).
  --max-details detail pages per run (default 8000).
  --web-ui / --data-dir  where the curated descriptions come from (default: this checkout's
               web-ui/ and data/): tool, model-family and library entries, installers, dev stack.

What a card shows, by section: tools and library entries use the web UI's curated name, logo,
description, features and screenshots; models and datasets use their model / dataset card (first
paragraphs, licence, pipeline tag, first image in the repo); ZIM files their own metadata
(title, description, 48x48 illustration, read from the ZIM header + directory, never the whole
file) plus Kiwix catalog counts; installers and the dev stack their catalog notes. Anything
without a picture gets a generated badge.

Never followed or listed: dot files, *.part / *.tmp / *.oversize-* leftovers, symlinked
directories, and every directory that is not a section (state/, private/, the repo's code).
Writes are temp + rename (no chmod: network shares refuse it) and unchanged files are not
rewritten. Exit 0 ok, 1 root missing or output unwritable, 64 usage.
"""
import argparse, fnmatch, hashlib, heapq, html, json, lzma, os, re, shutil, struct, subprocess, sys, time, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# name, default dir, title, blurb, art scene, entry depth by path prefix: a key is matched (fnmatch)
# against as many leading path components, the longest matching key wins, '*' is the default.
# tools is special: an entry is one tool across every platform folder (tools/<platform>/<tool>).
SECTIONS = [
    ('models', 'models', 'AI models',
     'Language, speech, vision and image models. GGUF files run in llama.cpp; safetensors folders load '
     'in transformers, vLLM or similar.', 'models', {'huggingface': 3, '*': 2}),
    ('content', 'content', 'Library',
     'Offline encyclopedias, manuals, Q&A sites and maps. ZIM files open in Kiwix (desktop, Android or '
     'kiwix-serve).', 'knowledge', {'lastbook': 1, '*': 2}),
    ('tools', 'tools', 'Tools & apps',
     'Portable programs for Linux (x86_64 + arm64), macOS and Windows.', 'tools', {'*': 2}),
    ('installers', 'installers', 'OS installers',
     'Operating-system images, netboot files, router firmware and board support packages.',
     'platforms', {'*': 2}),
    ('dev-stack', 'dev-stack', 'Developer stack',
     'Current releases of compilers, languages, databases, containers, cloud and security tools.',
     'design', {'*': 3}),
    ('software', 'software', 'Software releases',
     'Upstream release assets and offline package sets.', 'architecture', {'releases': 3, '*': 2}),
    ('datasets', 'datasets', 'Datasets',
     'Training and reference data: robotics, agriculture, weather, climate, earth observation.',
     'nas', {'open-data/*/huggingface': 5, 'open-data': 4, '*': 3}),
    ('sources', 'sources', 'Source code',
     'Source archives and full-history git bundles of the projects in the archive.',
     'community', {'github': 3, '*': 1}),
]
SKIP = re.compile(r'(^\.)|(\.part$)|(\.tmp(-\d+)?$)|(\.oversize-\d+$)|(\.source\.json$)')
README = ('README.md', 'readme.md', 'README.txt', 'README')
LICENSE = re.compile(r'(?i)^(license|licence|copying|notice)(\.[a-z]+)?$')
IMG_EXT = ('.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg')
PLATFORMS = {'linux-x86_64': 'Linux x86_64', 'linux-arm64': 'Linux arm64', 'macos-arm64': 'macOS',
             'windows-x64': 'Windows', 'sources': 'Source'}


# --------------------------------------------------------------------------- small helpers
def human(n):
    n = float(n or 0)
    for unit in ('B', 'KB', 'MB', 'GB', 'TB', 'PB'):
        if n < 1000 or unit == 'PB':
            return f'{n:.0f} {unit}' if unit == 'B' or n >= 100 else f'{n:.1f} {unit}'
        n /= 1000


def queued_text(files, size):
    """'3 files, 1.2 GB' (size left out when the queue does not know it)."""
    n = f'{files:,} file' + ('' if files == 1 else 's')
    return f'{n}, {human(size)}' if size else n


def href(path):
    """A relative path -> an escaped href value (each segment percent-encoded)."""
    return html.escape(urllib.parse.quote(path.replace(os.sep, '/'), safe='/'), quote=True)


def esc(s):
    return html.escape(str(s), quote=True)


def plain_url(u):
    """An upstream URL shown as text, never as a link (pages stay offline-only)."""
    return re.sub(r'^[a-z]+://(www\.)?', '', str(u or '')).rstrip('/')


def sha(s, n=12):
    return hashlib.sha1(s.encode('utf-8', 'replace')).hexdigest()[:n]


def write_atomic(path, data, known=None):
    """Write via temp + rename; skip when the file already holds exactly these bytes."""
    data = data.encode('utf-8') if isinstance(data, str) else data
    try:
        if known is None or os.path.basename(path) in known:
            with open(path, 'rb') as f:
                if f.read() == data:
                    return
    except OSError:
        pass
    tmp = f'{path}.tmp-{os.getpid()}'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)


def listdir(path):
    try:
        return {d.name for d in os.scandir(path)}
    except OSError:
        return set()


# --------------------------------------------------------------------------- JS literal reader
class JSLit:
    """Reads a JavaScript object / array literal (the web UI's data tables) into Python values.
    Strings, numbers, true/false/null, nested objects/arrays, comments, trailing commas and
    'a' + 'b' concatenation; anything else (identifiers, calls) becomes None."""

    def __init__(self, text, pos):
        self.t, self.p = text, pos

    def ws(self):
        t = self.t
        while self.p < len(t):
            if t[self.p].isspace():
                self.p += 1
            elif t.startswith('//', self.p):
                self.p = t.find('\n', self.p) + 1 or len(t)
            elif t.startswith('/*', self.p):
                self.p = t.find('*/', self.p) + 2
            else:
                break

    def value(self):
        self.ws()
        c = self.t[self.p]
        if c == '{':
            v = self.obj()
        elif c == '[':
            v = self.arr()
        elif c in '\'"`':
            v = self.string()
        elif c.isdigit() or c in '-.':
            m = re.compile(r'-?[\d.]+(e[-+]?\d+)?').match(self.t, self.p)
            self.p = m.end()
            v = float(m.group(0)) if any(x in m.group(0) for x in '.e') else int(m.group(0))
        else:
            m = re.compile(r'[A-Za-z_$][\w$.]*').match(self.t, self.p)
            if not m:
                raise ValueError(f'unexpected {c!r} at {self.p}')
            self.p = m.end()
            self.ws()
            if self.t[self.p] == '(':        # a call: skip its balanced arguments
                depth = 0
                while True:
                    ch = self.t[self.p]; self.p += 1
                    depth += ch == '('
                    depth -= ch == ')'
                    if depth == 0:
                        break
            v = {'true': True, 'false': False, 'null': None}.get(m.group(0))
        self.ws()
        while self.p < len(self.t) and self.t[self.p] == '+':
            self.p += 1
            nxt = self.value()
            v = f'{v if v is not None else ""}{nxt if nxt is not None else ""}'
        return v

    def string(self):
        q = self.t[self.p]; self.p += 1; out = []
        esc_map = {'n': '\n', 't': '\t', 'r': '', 'b': '', 'f': '', 'v': '', '0': ''}
        while True:
            c = self.t[self.p]; self.p += 1
            if c == q:
                return ''.join(out)
            if c == '\\':
                d = self.t[self.p]; self.p += 1
                if d == 'u':
                    out.append(chr(int(self.t[self.p:self.p + 4], 16))); self.p += 4
                elif d == 'x':
                    out.append(chr(int(self.t[self.p:self.p + 2], 16))); self.p += 2
                elif d == '\n':
                    pass
                else:
                    out.append(esc_map.get(d, d))
            else:
                out.append(c)

    def obj(self):
        self.p += 1; out = {}
        while True:
            self.ws()
            if self.t[self.p] == '}':
                self.p += 1
                return out
            if self.t[self.p] in '\'"':
                key = self.string()
            else:
                m = re.compile(r'[\w$-]+').match(self.t, self.p)
                key = m.group(0); self.p = m.end()
            self.ws()
            if self.t[self.p] != ':':
                raise ValueError(f'expected : at {self.p}')
            self.p += 1
            out[key] = self.value()
            self.ws()
            if self.t[self.p] == ',':
                self.p += 1

    def arr(self):
        self.p += 1; out = []
        while True:
            self.ws()
            if self.t[self.p] == ']':
                self.p += 1
                return out
            out.append(self.value())
            self.ws()
            if self.t[self.p] == ',':
                self.p += 1


def js_const(text, name):
    m = re.search(r'\bconst\s+' + re.escape(name) + r'\s*=\s*', text)
    if not m:
        return None
    try:
        return JSLit(text, m.end()).value()
    except (ValueError, IndexError, KeyError):
        return None


class Curated:
    """Descriptions and pictures the web UI and the data/ catalogs already carry."""

    def __init__(self, web_ui, data_dir):
        self.web_ui = web_ui
        text = ''
        try:
            with open(os.path.join(web_ui, 'index.html'), encoding='utf-8') as f:
                text = f.read()
        except OSError:
            pass
        self.tools = {t['id']: t for t in (js_const(text, 'TOOLS') or []) if isinstance(t, dict) and t.get('id')}
        self.tool_meta = js_const(text, 'TOOL_META') or {}
        self.content = [c for c in (js_const(text, 'CONTENT_LIBRARY') or []) if isinstance(c, dict)]
        self.families = [f for f in (js_const(text, 'MODEL_FAMILIES') or []) if isinstance(f, dict)]
        self.model_meta = js_const(text, 'MODEL_META') or {}
        self.model_files = {}                 # 'llm/x/y.gguf' or its folder -> family
        for fam in self.families:
            for m in (fam.get('variants') or fam.get('models') or []):
                f = (m or {}).get('file') if isinstance(m, dict) else None
                if f:
                    self.model_files[f] = (fam, m)
                    self.model_files.setdefault(os.path.dirname(f), (fam, m))
        self.installers, self.devstack, self.sources = {}, {}, {}
        for row in self._rows(os.path.join(data_dir, 'installers.tsv')):
            if len(row) >= 6:
                note = row[8] if len(row) > 8 else ''
                self.installers[row[5].rsplit('/', 1)[-1]] = {'name': row[2], 'cat': row[3], 'arch': row[4], 'note': note}
        for row in self._rows(os.path.join(data_dir, 'dev-stack.tsv')):
            if len(row) >= 5:
                note, ref = row[-1], row[2]
                self.devstack.setdefault(ref.lower(), note)
                self.devstack.setdefault(ref.rsplit('/', 1)[-1].lower(), note)
        for row in self._rows(os.path.join(data_dir, 'source-repos.tsv')):   # value|owner/repo|group
            if len(row) >= 3:
                self.sources[row[1].lower()] = row[2]

    @staticmethod
    def _rows(path):
        try:
            with open(path, encoding='utf-8') as f:
                return [ln.rstrip('\n').split('|') for ln in f if ln.strip() and not ln.lstrip().startswith('#')]
        except OSError:
            return []

    def content_for(self, filename):
        for c in self.content:
            pat = c.get('match')
            try:
                if pat and re.search(pat, filename, re.I):
                    return c
            except re.error:
                continue
        return None


# --------------------------------------------------------------------------- ZIM metadata
def zim_meta(path, want=('Title', 'Description', 'Language', 'Creator', 'Illustration_48x48@1')):
    """Metadata entries of a ZIM file, read with a handful of small random reads: header, a binary
    search of the URL pointer list for each M/<name>, then the blob from its cluster (uncompressed
    or xz; zstd clusters are skipped, since the stdlib has no zstd before Python 3.14)."""
    out = {}
    try:
        f = open(path, 'rb')
    except OSError:
        return out
    with f:
        def rd(off, n):
            f.seek(off)
            return f.read(n)
        try:
            h = rd(0, 80)
            if len(h) < 80 or h[:4] != b'ZIM\x04':
                return out
            (entries, clusters, url_ptr, _title_ptr, cluster_ptr) = struct.unpack('<IIQQQ', h[24:56])

            def dirent(i):
                off = struct.unpack('<Q', rd(url_ptr + 8 * i, 8))[0]
                b = rd(off, 1024)
                mime = struct.unpack('<H', b[:2])[0]
                ns = b[3:4].decode('latin-1')
                if mime == 0xFFFF:
                    rest = b[12:]
                    return ns, rest.split(b'\0', 1)[0].decode('utf-8', 'replace'), None
                cl, blob = struct.unpack('<II', b[8:16])
                url = b[16:].split(b'\0', 1)[0].decode('utf-8', 'replace')
                return ns, url, (cl, blob)

            def blob(cl, n):
                if cl >= clusters:
                    return None
                off = struct.unpack('<Q', rd(cluster_ptr + 8 * cl, 8))[0]
                info = rd(off, 1)[0]
                comp, ext = info & 0x0F, bool(info & 0x10)
                size = 8 if ext else 4
                fmt = '<Q' if ext else '<I'
                if comp in (0, 1):
                    first = struct.unpack(fmt, rd(off + 1, size))[0]
                    if n + 1 >= first // size:
                        return None
                    a, b = struct.unpack('<' + fmt[1] * 2, rd(off + 1 + size * n, size * 2))
                    if b - a > 2_000_000:
                        return None
                    return rd(off + 1 + a, b - a)
                if comp == 5 and shutil.which('zstd'):
                    # stdlib has no zstd before 3.14: the zstd CLI decodes a growing prefix
                    want = 262144
                    while want <= 8_388_608:
                        raw = rd(off + 1, want)
                        r = subprocess.run(['zstd', '-dcq'], input=raw, capture_output=True, timeout=30)
                        data = r.stdout
                        if len(data) >= size:
                            first = struct.unpack(fmt, data[:size])[0]
                            if len(data) >= first and len(data) >= size * (n + 2):
                                a, b = struct.unpack('<' + fmt[1] * 2, data[size * n:size * n + size * 2])
                                if len(data) >= b:
                                    return data[a:b]
                        if len(raw) < want:
                            break
                        want *= 4
                    return None
                if comp == 4:
                    dec = lzma.LZMADecompressor()
                    data, pos = b'', off + 1
                    while len(data) < 4_000_000:
                        chunk = rd(pos, 65536)
                        if not chunk:
                            break
                        pos += len(chunk)
                        data += dec.decompress(chunk)
                        if len(data) >= size:
                            first = struct.unpack(fmt, data[:size])[0]
                            if len(data) >= first:
                                a, b = struct.unpack('<' + fmt[1] * 2, data[size * n:size * n + size * 2])
                                if len(data) >= b:
                                    return data[a:b]
                        if dec.eof:
                            break
                return None

            for name in want:
                lo, hi = 0, entries - 1
                while lo <= hi:
                    mid = (lo + hi) // 2
                    ns, url, loc = dirent(mid)
                    if (ns, url) == ('M', name):
                        if loc:
                            v = blob(*loc)
                            if v is not None:
                                out[name] = v
                        break
                    if (ns, url) < ('M', name):
                        lo = mid + 1
                    else:
                        hi = mid - 1
        except (OSError, struct.error, lzma.LZMAError, IndexError, ValueError, subprocess.SubprocessError):
            pass
    return out


ZIM = re.compile(r'^(?P<proj>[a-z0-9.-]+?)_(?P<lang>[a-z]{2,3}(?:-[a-z]+)?)_(?P<rest>.+?)(?:_(?P<date>\d{4}-\d{2})[a-z]?)?\.zim$', re.I)
FLAVOURS = {'maxi': 'full, with images', 'nopic': 'text only', 'mini': 'introductions only'}


def zim_parts(name):
    m = ZIM.match(name)
    if not m:
        return None
    rest = m.group('rest').split('_')
    flav = rest[-1] if rest and rest[-1] in FLAVOURS else ''
    topic = '_'.join(rest[:-1] if flav else rest)
    return {'proj': m.group('proj'), 'lang': m.group('lang'), 'topic': topic, 'flavour': flav,
            'date': m.group('date') or '', 'name': f'{m.group("proj")}_{m.group("lang")}_{topic}'}


def zim_note(name):
    z = zim_parts(name)
    if not z:
        return 'Kiwix ZIM archive'
    bits = [z['proj'].replace('.', ' ').title(), f'({z["lang"]})']
    if z['topic'] and z['topic'] != 'all':
        bits.append('· ' + z['topic'].replace('-', ' ').replace('_', ' '))
    if z['flavour']:
        bits.append('· ' + FLAVOURS[z['flavour']])
    if z['date']:
        bits.append('· ' + z['date'])
    return ' '.join(bits)


def zim_title(z):
    """A readable title from the file name when the ZIM itself can't be read (not downloaded yet)."""
    if not z:
        return ''
    proj = z['proj']
    if proj.endswith('.stackexchange.com'):
        base = proj[:-len('.stackexchange.com')].replace('-', ' ').title() + ' Stack Exchange'
    elif '.' in proj:
        base = proj
    else:
        base = proj.replace('_', ' ').replace('-', ' ').title()
    topic = z['topic'] if z['topic'] not in ('', 'all') else ''
    return f'{base} — {topic.replace("_", " ").replace("-", " ")}' if topic else base


def zim_group(z):
    if not z:
        return 'other'
    if z['proj'].endswith(('stackexchange.com', 'stackoverflow.com', 'superuser.com', 'serverfault.com', 'askubuntu.com')):
        return 'stack_exchange'
    return 'other' if '.' in z['proj'] else z['proj']


def kiwix_counts(root):
    """name|flavour -> (category, articles, media) from a cached Kiwix catalog, if any."""
    out = {}
    for path in (os.path.join(root, 'state', 'catalog', 'zim.tsv'), os.path.join(root, 'state', 'catalog', 'kiwix-raw.json')):
        try:
            with open(path, encoding='utf-8') as f:
                rows = json.load(f) if path.endswith('.json') else [ln.rstrip('\n').split('\t') for ln in f]
        except (OSError, ValueError):
            continue
        for r in rows:
            if isinstance(r, list) and len(r) >= 7:
                out.setdefault(f'{r[0]}|{r[1]}', (r[2], r[5], r[6]))
    return out


# --------------------------------------------------------------------------- model / dataset cards
FRONT = re.compile(r'\A---\s*\n(.*?)\n---\s*\n', re.S)


def clean_md(p):
    p = re.sub(r'!\[[^\]]*\]\([^)]*\)', '', p)
    p = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', p)
    p = re.sub(r'<[^>]+>', '', p)
    p = re.sub(r'https?://\S+', '', p)
    p = re.sub(r'[*_`]+', '', p)
    return ' '.join(p.split())


def card(text):
    """{excerpt, long, licence, pipeline, tags, images} from a README / model card."""
    info = {'excerpt': None, 'long': None, 'license': None, 'pipeline': None, 'tags': [], 'images': []}
    m = FRONT.match(text)
    if m:
        key = None
        for line in m.group(1).splitlines():
            if re.match(r'^\s*-\s+', line) and key == 'tags':
                info['tags'].append(line.split('-', 1)[1].strip().strip('"\''))
                continue
            k, _, v = line.partition(':')
            key = k.strip()
            v = v.strip().strip('"\'')
            if key in ('license', 'license_name') and v and not info['license']:
                info['license'] = v
            elif key == 'pipeline_tag' and v:
                info['pipeline'] = v
        text = text[m.end():]
    info['images'] = [u for u in re.findall(r'!\[[^\]]*\]\(\s*<?([^)\s>]+)', text) +
                      re.findall(r'<img[^>]+src\s*=\s*["\']([^"\']+)', text, re.I)]
    paras = []
    for para in re.split(r'\n\s*\n', text):
        p = para.strip()
        if not p or p[0] in '#<|![>`-*=+' or p.startswith(('```', '[!', '[![')):
            continue
        if re.match(r'^(import |from \S+ import|pip |\$ |>>>|def |class |git clone|python |curl )', p) or \
                sum(c.isalpha() or c == ' ' for c in p) < 0.75 * len(p):
            continue
        p = clean_md(p)
        if len(p) < 40:
            continue
        paras.append(p)
        if sum(len(x) for x in paras) > 1400 or len(paras) >= 4:
            break
    if paras:
        first = paras[0]
        info['excerpt'] = first if len(first) <= 260 else first[:257].rsplit(' ', 1)[0] + '…'
        joined = '\n\n'.join(paras)
        info['long'] = joined if len(joined) <= 1600 else joined[:1597].rsplit(' ', 1)[0] + '…'
    return info


def read_small(path, limit=65536):
    try:
        with open(path, 'rb') as f:
            return f.read(limit).decode('utf-8', 'replace')
    except OSError:
        return None


# --------------------------------------------------------------------------- generated badges
PALETTE = ['#b5562f', '#2f6f6a', '#5b4fb5', '#a0407a', '#3d7a2f', '#9a6a12', '#2f5f9a', '#7a3d2f']
GLYPHS = {'text-generation': 'Aa', 'image-text-to-text': '👁', 'text-to-image': '🖼', 'image-to-image': '🖼',
          'automatic-speech-recognition': '🎙', 'text-to-speech': '🔊', 'text-to-audio': '🎵', 'audio-to-audio': '🎧',
          'robotics': '🤖', 'image-to-3d': '◆', 'text-to-3d': '◆', 'text-to-video': '🎬', 'image-to-video': '🎬',
          'feature-extraction': '⇄', 'sentence-similarity': '⇄', 'time-series-forecasting': '📈',
          'any-to-any': '✦', 'video-text-to-text': '🎬'}


def badge_svg(label, color, sub=''):
    lab = esc(label[:3])
    size = 34 if len(label) <= 2 else 26
    sub_el = (f'<text x="48" y="80" font-family="system-ui,sans-serif" font-size="11" fill="#fff" '
              f'fill-opacity=".85" text-anchor="middle">{esc(sub[:14])}</text>' if sub else '')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96" width="96" height="96">'
            f'<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{color}"/>'
            f'<stop offset="1" stop-color="{color}" stop-opacity=".72"/></linearGradient></defs>'
            f'<rect x="2" y="2" width="92" height="92" rx="20" fill="url(#g)"/>'
            f'<rect x="2" y="2" width="92" height="46" rx="20" fill="#fff" fill-opacity=".08"/>'
            f'<text x="48" y="{58 if sub else 62}" font-family="Georgia,serif" font-size="{size}" font-weight="700" '
            f'fill="#fff" text-anchor="middle">{lab}</text>{sub_el}</svg>\n')


def initials(name):
    words = re.findall(r'[A-Za-z0-9]+', name)
    if not words:
        return '?'
    if len(words) == 1:
        return words[0][:2].title()
    return (words[0][0] + words[1][0]).upper()


# --------------------------------------------------------------------------- the model
TOOL_SUFFIX = re.compile(r'(?i)(\.(tar\.(zst|gz|xz|bz2)|tgz|zip|exe|dmg|appimage|msi|txt|md|readme)|[-_]src|[-_]v?\d[\w.]*)$')


def tool_key(name):
    """tools/<platform>/<name>: 'blender.tar.zst.README.txt', 'maddy-0.9.7-src' -> 'blender', 'maddy'."""
    name = name.split('.stale-', 1)[0]
    while True:
        new = TOOL_SUFFIX.sub('', name)
        if new == name or not new:
            return name
        name = new


class Entry:
    __slots__ = ('key', 'is_dir', 'bytes', 'files', 'mtime', 'top', 'pending_bytes', 'pending_files',
                 'readme', 'license', 'names', 'platforms')

    def __init__(self, key, is_dir):
        self.key, self.is_dir = key, is_dir
        self.bytes = self.files = self.pending_bytes = self.pending_files = 0
        self.mtime = 0.0
        self.top = []           # min-heap of (size, path inside the section)
        self.readme = self.license = None
        self.names = set()      # small set of file names inside (README image lookup)
        self.platforms = {}     # tools: platform -> bytes


class Section:
    def __init__(self, name, path, title, blurb, art, depth):
        self.name, self.path, self.title, self.blurb, self.art, self.depth = name, path, title, blurb, art, depth
        self.entries = {}
        self.truncated = False

    def depth_for(self, parts):
        best, d = -1, self.depth['*']
        for key, depth in self.depth.items():
            kp = key.split('/')
            if key != '*' and len(kp) < len(parts) and len(kp) > best and \
                    all(fnmatch.fnmatchcase(p, k) for p, k in zip(parts, kp)):
                best, d = len(kp), depth
        return d

    def entry_for(self, rel):
        """-> (entry, path inside the entry, platform)."""
        parts = rel.split('/')
        if self.name == 'tools' and len(parts) >= 2 and parts[0] in PLATFORMS:
            tool = tool_key(parts[1])
            e = self.entries.setdefault(tool, Entry(tool, True))
            return e, '/'.join(parts[1:]), parts[0]
        d = self.depth_for(parts) if len(parts) > 1 else 1
        if len(parts) <= d:
            return self.entries.setdefault(rel, Entry(rel, False)), parts[-1], None
        key = '/'.join(parts[:d])
        e = self.entries.setdefault(key, Entry(key, True))
        return e, '/'.join(parts[d:]), None

    def add(self, rel, size, mtime, max_files, pending=False):
        if self.name == 'tools' and re.fullmatch(r'[^/]+/(INSTALL|README)(\.(txt|md))?', rel, re.I):
            return
        e, inner, plat = self.entry_for(rel)
        if pending:
            e.pending_bytes += size; e.pending_files += 1
            return
        e.bytes += size; e.files += 1
        e.mtime = max(e.mtime, mtime)
        if plat:
            e.platforms[plat] = e.platforms.get(plat, 0) + size
        if e.is_dir:
            if inner in README:
                e.readme = inner
            elif '/' not in inner and LICENSE.match(inner):
                e.license = inner
            if inner.lower().endswith(IMG_EXT) and len(e.names) < 400:
                e.names.add(inner)
            item = (size, rel)
            if len(e.top) < max_files:
                heapq.heappush(e.top, item)
            elif item > e.top[0]:
                heapq.heapreplace(e.top, item)


def walk(section, max_files, budget):
    """Recursive os.scandir of one section; returns what is left of the file budget."""
    stack = ['']
    while stack:
        rel = stack.pop()
        try:
            it = os.scandir(os.path.join(section.path, rel) if rel else section.path)
        except OSError:
            continue
        with it:
            for d in it:
                if SKIP.search(d.name):
                    continue
                child = f'{rel}/{d.name}' if rel else d.name
                try:
                    if d.is_dir(follow_symlinks=False):
                        stack.append(child)
                    elif d.is_file(follow_symlinks=True):
                        if budget <= 0:
                            section.truncated = True
                            return 0
                        st = d.stat(follow_symlinks=True)
                        section.add(child, st.st_size, st.st_mtime, max_files)
                        budget -= 1
                except OSError:
                    continue
    return budget


def read_listing(path, sections, root, max_files, pending):
    """Feed a path<TAB>size[<TAB>mtime] listing (paths relative to root) into the sections."""
    prefixes = []
    for s in sections:
        rp = os.path.relpath(s.path, root).replace(os.sep, '/')
        if not rp.startswith('..'):
            prefixes.append((rp.rstrip('/') + '/', s))
    prefixes.sort(key=lambda p: -len(p[0]))
    fh = sys.stdin if path == '-' else open(path, encoding='utf-8', errors='replace')
    with fh:
        for line in fh:
            cols = line.rstrip('\n').split('\t')
            if len(cols) < 2:
                continue
            rel = cols[0].lstrip('/')
            if any(SKIP.search(p) for p in rel.split('/')) or '..' in rel.split('/'):
                continue
            try:
                size = int(float(cols[1] or 0))
                mtime = float(cols[2]) if len(cols) > 2 and cols[2] else 0.0
            except ValueError:
                continue
            for pre, s in prefixes:
                if rel.startswith(pre) and len(rel) > len(pre):
                    s.add(rel[len(pre):], size, mtime, max_files, pending=pending)
                    break


# --------------------------------------------------------------------------- page chrome
CSS = """
:root{--bg:#f6f0e4;--paper:#fffaf0;--ink:#2b2622;--muted:#6f655b;--line:#e3d7c3;--accent:#b5562f;
--accent2:#2f6f6a;--chip:#efe4cf;--shadow:0 1px 0 #e9dcc6,0 8px 24px -12px rgba(80,50,20,.35);color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#1c1a17;--paper:#262320;--ink:#efe7da;--muted:#a89d8f;
--line:#3a352f;--accent:#e58a5c;--accent2:#6cc0b8;--chip:#332e28;--shadow:0 1px 0 #2f2b26,0 10px 28px -14px #000;color-scheme:dark}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
a{color:var(--accent2)}a:hover{color:var(--accent)}code{font-size:.92em;background:var(--chip);padding:1px 5px;border-radius:6px}
.wrap{max-width:1240px;margin:0 auto;padding:0 16px 48px}
header.top{display:flex;flex-wrap:wrap;gap:8px 18px;align-items:baseline;padding:18px 0 8px}
header.top .brand{font:700 20px/1.2 Georgia,"Iowan Old Style",serif;text-decoration:none;color:var(--ink)}
nav.sections{display:flex;flex-wrap:wrap;gap:6px}nav.sections a{padding:3px 10px;border-radius:99px;background:var(--chip);
text-decoration:none;color:var(--ink);font-size:14px}nav.sections a[aria-current]{background:var(--accent);color:#fff}
.hero{background:var(--paper);border:1px solid var(--line);border-radius:18px;box-shadow:var(--shadow);overflow:hidden;margin:10px 0 22px}
.hero img{display:block;width:100%;height:auto}.hero .txt{padding:14px 22px 20px}
h1{font:700 clamp(26px,4vw,38px)/1.15 Georgia,"Iowan Old Style",serif;margin:4px 0 6px}
h2{font:700 22px/1.2 Georgia,serif;margin:28px 0 10px}h3{font:700 18px Georgia,serif;margin:18px 0 8px}.muted{color:var(--muted)}
.stats{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0 0}.stat{background:var(--chip);border-radius:12px;padding:8px 14px}
.stat b{display:block;font-size:20px}.stat span{font-size:13px;color:var(--muted)}
.sections-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:16px}
.scard{background:var(--paper);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);overflow:hidden;
display:flex;flex-direction:column;text-decoration:none;color:var(--ink);transition:transform .2s}
.scard:hover{transform:translateY(-3px) rotate(-.3deg)}.scard img{width:100%;height:auto;display:block;border-bottom:1px solid var(--line)}
.scard .body{padding:12px 16px 16px}.scard h3{margin:0 0 4px}.scard p{margin:0 0 8px;font-size:14px;color:var(--muted)}
.scard .nums{font-size:14px}.peek{display:flex;gap:6px;margin-top:10px}.peek img{width:34px;height:34px;border-radius:9px;border:0;object-fit:cover;background:var(--chip)}
.tools{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:4px 0 14px}
input[type=search],select{font:inherit;padding:8px 12px;border-radius:10px;border:1px solid var(--line);background:var(--paper);color:var(--ink)}
input[type=search]{flex:1 1 260px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px}
.item{display:flex;gap:14px;background:var(--paper);border:1px solid var(--line);border-radius:16px;padding:14px;
box-shadow:var(--shadow);text-decoration:none;color:var(--ink);transition:transform .15s,border-color .15s;min-width:0}
.item:hover{transform:translateY(-2px);border-color:var(--accent)}
.item .ic{flex:0 0 64px;width:64px;height:64px;border-radius:14px;object-fit:contain;background:var(--chip)}
.item .tx{min-width:0;flex:1}.item h4{margin:0;font:700 16px/1.25 Georgia,serif;word-break:break-word}
.item .sub{font-size:12px;color:var(--muted);margin:1px 0 4px;word-break:break-word}
.item p{margin:0;font-size:14px;color:var(--muted);display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.chips{margin-top:6px}.chip{display:inline-block;font-size:12px;padding:1px 8px;border-radius:99px;background:var(--chip);margin:2px 4px 0 0;color:var(--ink)}
.chip.q{background:var(--accent);color:#fff}.chip.ok{background:var(--accent2);color:#fff}
.group{grid-column:1/-1;font:700 15px Georgia,serif;color:var(--muted);margin:10px 0 -4px;text-transform:none}
.more{margin:14px 0;padding:10px 14px;border:1px dashed var(--line);border-radius:12px}
footer{margin-top:36px;font-size:13px;color:var(--muted)}
.panel{background:var(--paper);border:1px solid var(--line);border-radius:16px;padding:8px 20px 14px;box-shadow:var(--shadow);margin:14px 0}
.detail-head{display:flex;gap:20px;align-items:center;flex-wrap:wrap}.detail-head .ic{width:120px;height:120px;border-radius:24px;object-fit:contain;background:var(--chip)}
.desc-long p{margin:.5em 0}.facts{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;font-size:14px}
.facts dt{color:var(--muted)}.facts dd{margin:0;word-break:break-word}
.shots{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px}.shots img{width:100%;border-radius:12px;border:1px solid var(--line)}
.files{font-size:14px;padding-left:18px}.files li{margin:2px 0;word-break:break-all}
.plat a{margin-right:8px}
@media (prefers-reduced-motion:reduce){.scard,.item{transition:none}}
"""

FILTER_JS = ("<script>(function(){var q=document.getElementById('q'),g=document.getElementById('g');if(!q)return;"
             "q.hidden=false;if(g)g.hidden=false;function f(){var t=q.value.toLowerCase(),k=g?g.value:'';"
             "document.querySelectorAll('[data-k]').forEach(function(r){r.hidden=(t&&r.getAttribute('data-k')"
             ".indexOf(t)<0)||(k&&r.getAttribute('data-g')!==k);});"
             "document.querySelectorAll('.group').forEach(function(h){h.hidden=!!(t||k);});}"
             "q.addEventListener('input',f);if(g)g.addEventListener('change',f);})();</script>")


def picture(art, prefix, alt, have_art):
    if art not in have_art:
        return ''
    return (f'<picture><source media="(prefers-color-scheme: dark)" srcset="{prefix}art/{art}-dark.svg">'
            f'<img src="{prefix}art/{art}-light.svg" width="1200" height="320" alt="{esc(alt)}"></picture>')


def page(title, body, nav):
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{esc(title)}</title><style>{CSS}</style></head><body><div class="wrap">'
            f'{nav}{body}</div></body></html>\n')


# --------------------------------------------------------------------------- build
class Builder:
    def __init__(self, a, root, out, sections):
        self.a, self.root, self.out, self.sections = a, root, out, sections
        self.browse = os.path.join(out, 'browse')
        self.items_dir = os.path.join(self.browse, 'item')
        self.thumbs_dir = os.path.join(self.browse, 'thumbs')
        self.cur = Curated(a.web_ui, a.data_dir)
        self.kiwix = kiwix_counts(root)
        self.reads = a.meta_limit
        self.zim_left = a.zim_limit
        self.thumbs_have = set()
        self.thumbs_used = set()
        self.items_used = set()
        self.zim_cache_path = os.path.join(self.browse, 'zim-meta.json')
        try:
            with open(self.zim_cache_path, encoding='utf-8') as f:
                self.zim_cache = json.load(f)
        except (OSError, ValueError):
            self.zim_cache = {}
        self.zim_seen = {}

    # -- thumbnails ----------------------------------------------------------------------
    def thumb_bytes(self, name, data):
        self.thumbs_used.add(name)
        if name not in self.thumbs_have:
            write_atomic(os.path.join(self.thumbs_dir, name), data, known=self.thumbs_have)
            self.thumbs_have.add(name)
        return 'thumbs/' + name

    def thumb_file(self, src, max_bytes=1_048_576):
        ext = os.path.splitext(src)[1].lower()
        if ext not in IMG_EXT:
            return None
        name = sha(src, 16) + ext
        if name in self.thumbs_have:
            self.thumbs_used.add(name)
            return 'thumbs/' + name
        try:
            if os.path.getsize(src) > max_bytes:
                return None
            with open(src, 'rb') as f:
                return self.thumb_bytes(name, f.read())
        except OSError:
            return None

    def badge(self, label, key, sub=''):
        color = PALETTE[int(sha(key, 4), 16) % len(PALETTE)]
        name = 'b-' + sha(f'{label}|{color}|{sub}', 12) + '.svg'
        return self.thumb_bytes(name, badge_svg(label, color, sub))

    def badge_color(self, label, color, sub=''):
        if not re.fullmatch(r'#[0-9a-fA-F]{3,8}', str(color or '')):
            color = PALETTE[0]
        name = 'b-' + sha(f'{label}|{color}|{sub}', 12) + '.svg'
        return self.thumb_bytes(name, badge_svg(label, color, sub))

    # -- per-entry information -------------------------------------------------------------
    def describe(self, s, e):
        """-> dict(title, sub, desc, long, icon, chips, facts, extra_html, group, shots)."""
        g = e.key.split('/')[0] if '/' in e.key else ''
        info = {'title': e.key.rsplit('/', 1)[-1] if s.name != 'models' else e.key, 'sub': '', 'desc': '',
                'long': '', 'icon': None, 'chips': [], 'facts': [], 'extra': '', 'group': g, 'shots': []}
        abs_dir = os.path.join(s.path, e.key)
        rcard = None
        if e.is_dir and e.readme and self.reads > 0:
            self.reads -= 1
            text = read_small(os.path.join(abs_dir, e.readme))
            if text:
                rcard = card(text)
        getattr(self, 'd_' + s.name.replace('-', '_'), self.d_generic)(s, e, info, rcard, abs_dir)
        if rcard:
            info['desc'] = info['desc'] or rcard['excerpt'] or ''
            info['long'] = info['long'] or rcard['long'] or ''
            if rcard['pipeline']:
                info['chips'].append(rcard['pipeline'])
            if rcard['license']:
                info['chips'].append('licence: ' + rcard['license'])
                info['facts'].append(('Licence', rcard['license']))
            if not info['icon']:
                info['icon'] = self.card_image(s, e, rcard, abs_dir)
        if not info['icon']:
            glyph = GLYPHS.get((rcard or {}).get('pipeline') or '', None)
            info['icon'] = self.badge(glyph or initials(info['title']), info['title'], (rcard or {}).get('pipeline') or '')
        return info

    def card_image(self, s, e, rcard, abs_dir):
        repo = '/'.join(e.key.split('/')[-2:])
        for u in rcard['images'][:6]:
            u = u.split('#')[0].split('?')[0]
            m = re.match(r'https?://huggingface\.co/(?:datasets/)?([^/]+/[^/]+)/(?:resolve|blob)/[^/]+/(.+)$', u)
            if m:
                if m.group(1).lower() != repo.lower():
                    continue
                u = m.group(2)
            elif re.match(r'^[a-z]+:', u) or u.startswith('/'):
                continue
            u = os.path.normpath(urllib.parse.unquote(u)).replace(os.sep, '/')
            if u.startswith('..') or not u.lower().endswith(IMG_EXT):
                continue
            # with a listing, only use images we know are present (no blind stat over a share)
            rel_in_section = f'{e.key}/{u}'
            known = any(n == u for n in e.names) if e.names else False
            if not known and self.a.listing and s.name not in self.a.walk:
                continue
            t = self.thumb_file(os.path.join(s.path, rel_in_section))
            if t:
                return t
        return None

    def d_generic(self, s, e, info, rcard, abs_dir):
        pass

    def d_models(self, s, e, info, rcard, abs_dir):
        parts = e.key.split('/')
        if parts[0] == 'huggingface' and len(parts) >= 3:
            info['title'] = parts[-1]
            info['sub'] = parts[-2]
        else:
            fam = self.cur.model_files.get(e.key.split('/', 1)[-1]) or self.cur.model_files.get(e.key)
            if not fam:
                for f, v in self.cur.model_files.items():
                    if f.startswith(e.key.split('/', 1)[-1] + '/') or f.startswith(e.key + '/'):
                        fam = v
                        break
            if fam:
                family, model = fam
                info['sub'] = f'{family.get("family", "")} family · {family.get("category", "")}'
                info['desc'] = family.get('desc') or ''
                info['long'] = family.get('overview') or ''
                meta = self.cur.model_meta.get(family.get('slug') or '') or {}
                if meta.get('maker'):
                    info['facts'].append(('Maker', meta['maker']))
                if meta.get('license'):
                    info['chips'].append('licence: ' + meta['license'])
                tips = family.get('usageTips') or []
                if tips:
                    info['extra'] += '<h3>Usage tips</h3><ul>' + ''.join(f'<li>{esc(t)}</li>' for t in tips[:8]) + '</ul>'
                logo = family.get('logo')
                if logo:
                    info['icon'] = self.thumb_file(os.path.join(self.a.web_ui, logo))
            else:
                info['sub'] = parts[0]

    def d_datasets(self, s, e, info, rcard, abs_dir):
        parts = e.key.split('/')
        info['title'] = parts[-1]
        info['sub'] = ' / '.join(parts[:-1])

    def d_tools(self, s, e, info, rcard, abs_dir):
        t = self.cur.tools.get(e.key)
        if t:
            info['title'] = t.get('name') or e.key
            info['sub'] = (t.get('category') or '').replace('-', ' ')
            info['desc'] = t.get('desc') or ''
            det = t.get('details') or {}
            info['long'] = det.get('overview') or ''
            feats = det.get('features') or []
            if feats:
                info['extra'] += '<h3>Features</h3><ul>' + ''.join(f'<li>{esc(x)}</li>' for x in feats[:12]) + '</ul>'
            cli = det.get('cli') or []
            if cli:
                info['extra'] += '<h3>Command line</h3><ul>' + ''.join(
                    f'<li><code>{esc((c or {}).get("cmd", ""))}</code> — {esc((c or {}).get("desc", ""))}</li>'
                    for c in cli[:10] if isinstance(c, dict)) + '</ul>'
            meta = self.cur.tool_meta.get(e.key) or {}
            if meta.get('maker'):
                info['facts'].append(('Maker', meta['maker']))
            if meta.get('license'):
                info['chips'].append('licence: ' + meta['license'])
            if meta.get('website'):
                info['facts'].append(('Website', plain_url(meta['website'])))
            logo = t.get('logo')
            if logo:
                info['icon'] = self.thumb_file(os.path.join(self.a.web_ui, logo))
            if not info['icon'] and t.get('icon'):
                info['icon'] = self.badge_color(t['icon'], t.get('iconBg'))
            for shot in (det.get('screenshots') or t.get('screenshots') or [])[:4]:
                p = self.thumb_file(os.path.join(self.a.web_ui, shot), max_bytes=2_500_000)
                if p:
                    info['shots'].append(p)
        info['group'] = ''
        info['chips'] += [PLATFORMS.get(p, p) for p in sorted(e.platforms)]

    def d_installers(self, s, e, info, rcard, abs_dir):
        fn = e.key.rsplit('/', 1)[-1]
        m = self.cur.installers.get(fn)
        info['sub'] = e.key.split('/')[0]
        if m:
            info['title'] = m['name'] or fn
            info['desc'] = m['note'] or ''
            if m['arch']:
                info['chips'].append(m['arch'])
        info['icon'] = self.badge(initials(info['sub'] if not m else m['cat']), info['sub'], info['sub'])

    def d_dev_stack(self, s, e, info, rcard, abs_dir):
        parts = e.key.split('/')
        info['title'] = parts[-1]
        info['sub'] = ' / '.join(parts[:-1])
        ref = '/'.join(parts[1:3]).lower()
        info['desc'] = self.cur.devstack.get(ref) or self.cur.devstack.get(parts[-1].lower()) or ''

    def d_software(self, s, e, info, rcard, abs_dir):
        parts = e.key.split('/')
        if parts[0] == 'releases' and len(parts) >= 3:
            info['title'] = parts[2]; info['sub'] = parts[1]
            info['desc'] = self.cur.devstack.get(f'{parts[1]}/{parts[2]}'.lower(), '')
        elif parts[0] == 'linux' and len(parts) >= 2:
            info['title'] = parts[1]
            info['desc'] = 'Offline APT package set: point apt at this folder (deb [trusted=yes] file:<dir> ./).'

    def d_sources(self, s, e, info, rcard, abs_dir):
        parts = e.key.split('/')
        if parts[0] == 'github' and len(parts) == 3:
            repo = parts[2][:-len('.bundle')] if parts[2].endswith('.bundle') else parts[2]
            info['title'] = repo; info['sub'] = parts[1]
            grp = self.cur.sources.get(f'{parts[1]}/{repo}'.lower())
            info['desc'] = ('Full-history git bundle' + (f' ({grp})' if grp else '') +
                            ': clone it offline with git clone <file>.bundle.') if parts[2].endswith('.bundle') else ''

    def d_content(self, s, e, info, rcard, abs_dir):
        fn = e.key.rsplit('/', 1)[-1]
        if e.is_dir or not fn.lower().endswith('.zim'):
            info['sub'] = e.key.split('/')[0]
            if e.key.split('/')[0] == 'lastbook':
                c = next((c for c in self.cur.content if c.get('id') == 'lastbook'), None)
                if c:
                    info['title'] = c.get('name') or info['title']
                    info['sub'] = ''
                    info['desc'] = c.get('desc') or ''
                    info['long'] = (c.get('details') or {}).get('overview') or ''
                    info['icon'] = self.badge_color(c.get('icon') or 'L', c.get('iconBg'))
            return
        z = zim_parts(fn) or {}
        info['sub'] = zim_note(fn)
        cur = self.cur.content_for(fn)
        meta = self.zim_info(os.path.join(s.path, e.key), fn, e.bytes)
        info['title'] = meta.get('title') or (cur or {}).get('name') or zim_title(z) or fn[:-4]
        info['desc'] = meta.get('description') or (cur or {}).get('desc') or ''
        if cur:
            det = cur.get('details') or {}
            info['long'] = det.get('overview') or ''
            feats = det.get('features') or []
            if feats:
                info['extra'] += '<h3>What is inside</h3><ul>' + ''.join(f'<li>{esc(x)}</li>' for x in feats[:10]) + '</ul>'
        k = self.kiwix.get(f'{z.get("name")}|{z.get("flavour")}')
        if k:
            try:
                info['facts'].append(('Articles', f'{int(k[1]):,}'))
                if int(k[2]):
                    info['facts'].append(('Media files', f'{int(k[2]):,}'))
            except ValueError:
                pass
        if z.get('lang'):
            info['chips'].append(z['lang'])
        if meta.get('creator'):
            info['facts'].append(('Creator', meta['creator']))
        if meta.get('icon'):
            info['icon'] = meta['icon']
            self.thumbs_used.add(meta['icon'].split('/', 1)[1])
        elif cur and cur.get('icon'):
            info['icon'] = self.badge_color(cur['icon'], cur.get('iconBg'))
        else:
            info['icon'] = self.badge(initials(z.get('proj', fn)), z.get('proj', fn), z.get('lang', ''))
        info['extra'] += ('<h3>How to open</h3><p>Open the file in Kiwix (desktop or Android), or serve it on the '
                          f'network with <code>kiwix-serve {esc(fn)}</code>.</p>')
        info['group'] = (k[0] if k else '') or zim_group(z)

    def zim_info(self, path, fn, size):
        key = f'{fn}|{size}'
        if key in self.zim_cache:
            self.zim_seen[key] = self.zim_cache[key]
            return self.zim_cache[key]
        if self.zim_left <= 0:
            return {}
        self.zim_left -= 1
        m = zim_meta(path)
        info = {}
        for k, name in (('Title', 'title'), ('Description', 'description'), ('Creator', 'creator')):
            if k in m:
                info[name] = m[k].decode('utf-8', 'replace').strip()[:400]
        ill = m.get('Illustration_48x48@1')
        if ill and ill[:8] == b'\x89PNG\r\n\x1a\n':
            info['icon'] = self.thumb_bytes('z-' + sha(key, 16) + '.png', ill)
        self.zim_seen[key] = info
        return info

    # -- pages ------------------------------------------------------------------------------
    def nav(self, prefix, current, shown):
        links = ''.join(f'<a href="{prefix}browse/{s.name}.html"' + (' aria-current="page"' if s.name == current else '')
                        + f'>{esc(s.title)}</a>' for s in shown)
        return (f'<header class="top"><a class="brand" href="{prefix}index.html">📖 {esc(self.a.title)}</a>'
                f'<nav class="sections" aria-label="Sections">{links}</nav></header>')

    def rel(self, target, from_dir):
        return os.path.relpath(target, from_dir)

    @staticmethod
    def entry_path(s, e):
        """The entry's own folder / file (a tool: its biggest platform folder)."""
        if e.platforms:
            plat = max(e.platforms.items(), key=lambda kv: kv[1])[0]
            return os.path.join(s.path, plat, e.key)
        return os.path.join(s.path, e.key)

    def detail_page(self, s, e, info, shown, item_name, stamp):
        d = self.items_dir
        abs_t = self.entry_path(s, e)
        tgt = href(self.rel(abs_t, d) + ('/' if e.is_dir else ''))
        long = info['long'] or info['desc']
        paras = ''.join(f'<p>{esc(p)}</p>' for p in long.split('\n\n') if p.strip()) or \
            '<p class="muted">No description was published with this item.</p>'
        facts = [('Size', human(e.bytes)), ('Files', f'{e.files:,}')]
        if e.mtime:
            facts.append(('Updated', time.strftime('%Y-%m-%d', time.gmtime(e.mtime))))
        if e.pending_files:
            facts.append(('Still queued', queued_text(e.pending_files, e.pending_bytes)))
        facts += info['facts']
        facts.append(('Location', f'{os.path.relpath(s.path, self.root)}/{e.key}'.lstrip('./')))
        facts_html = '<dl class="facts">' + ''.join(f'<dt>{esc(k)}</dt><dd>{esc(v)}</dd>' for k, v in facts) + '</dl>'
        links = []
        if e.files:
            links.append(f'<a href="{tgt}">{"Open the folder" if e.is_dir else "Open the file"}</a>')
        if e.readme and not e.platforms:
            links.append(f'<a href="{href(self.rel(os.path.join(abs_t, e.readme), d))}">Read the full README</a>')
        if e.license and not e.platforms:
            links.append(f'<a href="{href(self.rel(os.path.join(abs_t, e.license), d))}">Licence file</a>')
        plat = ''
        if e.platforms:
            plat = '<p class="plat">' + ''.join(
                f'<a href="{href(self.rel(os.path.join(s.path, p, e.key), d))}/">{esc(PLATFORMS.get(p, p))}</a>'
                f'<span class="muted">{human(b)}</span> ' for p, b in sorted(e.platforms.items())) + '</p>'
        shots = ''
        if info['shots']:
            shots = '<h3>Screenshots</h3><div class="shots">' + ''.join(
                f'<img src="../{href(p)}" alt="{esc(info["title"])} screenshot" loading="lazy">' for p in info['shots']) + '</div>'
        files = ''
        if e.is_dir and e.top:
            items = ''.join(f'<li><a href="{href(self.rel(os.path.join(s.path, r), d))}">{esc(r[len(e.key) + 1:] if r.startswith(e.key + "/") else r)}</a> '
                            f'<span class="muted">{human(sz)}</span></li>' for sz, r in sorted(e.top, reverse=True))
            more = f'<li class="muted">… {e.files - len(e.top):,} more in the folder</li>' if e.files > len(e.top) else ''
            files = f'<h3>Files (largest first)</h3><ul class="files">{items}{more}</ul>'
        chips = ''.join(f'<span class="chip">{esc(c)}</span>' for c in info['chips'])
        body = (f'<section class="hero"><div class="txt"><div class="detail-head">'
                f'<img class="ic" src="../{href(info["icon"])}" alt="" width="120" height="120">'
                f'<div><div class="muted">{esc(s.title)}{" · " + esc(info["sub"]) if info["sub"] else ""}</div>'
                f'<h1>{esc(info["title"])}</h1><div class="chips">{chips}</div>'
                f'<p>{" · ".join(links)}</p></div></div></div></section>'
                f'<div class="panel desc-long">{paras}{plat}</div>'
                f'<div class="panel">{facts_html}</div>'
                + (f'<div class="panel">{info["extra"]}</div>' if info['extra'] else '')
                + (f'<div class="panel">{shots}</div>' if shots else '')
                + (f'<div class="panel">{files}</div>' if files else '')
                + f'<p><a href="../{s.name}.html">← All {esc(s.title.lower())}</a></p>'
                f'<footer>Static snapshot generated {esc(stamp)}.</footer>')
        self.items_used.add(item_name)
        write_atomic(os.path.join(d, item_name), page(f'{info["title"]} · {s.title}', body, self.nav('../../', s.name, shown)),
                     known=self.items_have)

    def build(self):
        a = self.a
        os.makedirs(os.path.join(self.browse, 'art'), exist_ok=True)
        os.makedirs(self.items_dir, exist_ok=True)
        os.makedirs(self.thumbs_dir, exist_ok=True)
        self.thumbs_have = listdir(self.thumbs_dir)
        self.items_have = listdir(self.items_dir)
        have_art = set()
        for art in ['docs-map'] + [x[4] for x in SECTIONS]:
            ok = True
            for mode in ('light', 'dark'):
                try:
                    with open(os.path.join(a.art_dir, f'{art}-{mode}.svg'), 'rb') as f:
                        write_atomic(os.path.join(self.browse, 'art', f'{art}-{mode}.svg'), f.read())
                except OSError:
                    ok = False
            if ok:
                have_art.add(art)

        now = a.now if a.now is not None else time.time()
        stamp = time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime(now))
        shown = [s for s in self.sections if s.entries]
        details_left = a.max_details
        summary = {'generated_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now)), 'sections': []}
        peeks = {}
        for s in self.sections:
            page_path = os.path.join(self.browse, f'{s.name}.html')
            if not s.entries:
                try:
                    os.remove(page_path)
                except OSError:
                    pass
                continue
            entries = sorted(s.entries.values(), key=lambda e: (e.key.split('/')[0] if '/' in e.key else '', e.key.lower()))
            if s.name in ('tools',):
                entries.sort(key=lambda e: ((self.cur.tools.get(e.key) or {}).get('name') or e.key).lower())
            sb = sum(e.bytes for e in entries); sf = sum(e.files for e in entries)
            spb = sum(e.pending_bytes for e in entries); spf = sum(e.pending_files for e in entries)
            summary['sections'].append({'name': s.name, 'title': s.title, 'entries': len(entries), 'bytes': sb, 'files': sf,
                                        'pending_bytes': spb, 'pending_files': spf, 'truncated': s.truncated})
            # what is on disk first, then what is still queued; cards then group by kind
            listed = sorted(entries, key=lambda e: not e.files)[:a.max_rows]
            described = [(e, self.describe(s, e)) for e in listed]
            described.sort(key=lambda t: (t[1]['group'].lower(), not t[0].files, t[1]['title'].lower()))
            cards, groups, last = [], [], None
            for e, info in described:
                g = info['group']
                if g != last and g:
                    cards.append(f'<div class="group">{esc(g)}</div>')
                    groups.append(g)
                last = g
                item_name = f'{s.name}-{sha(e.key)}.html'
                if details_left > 0:
                    details_left -= 1
                    self.detail_page(s, e, info, shown, item_name, stamp)
                    link = f'item/{item_name}'
                else:
                    link = self.rel(self.entry_path(s, e), self.browse) + ('/' if e.is_dir else '')
                chips = []
                if e.files:
                    chips.append(f'<span class="chip">{human(e.bytes)}</span>')
                else:
                    chips.append('<span class="chip">not downloaded yet</span>')
                if e.pending_files:
                    chips.append(f'<span class="chip q">queued: {queued_text(e.pending_files, e.pending_bytes)}</span>')
                chips += [f'<span class="chip">{esc(c)}</span>' for c in info['chips'][:4]]
                if len(peeks.setdefault(s.name, [])) < 6 and not info['icon'].startswith('thumbs/b-'):
                    peeks[s.name].append(info['icon'])
                key = esc(f'{e.key} {info["title"]} {info["sub"]} {info["desc"]} {" ".join(info["chips"])}'.lower())
                cards.append(f'<a class="item" href="{href(link)}" data-k="{key}" data-g="{esc(g)}">'
                             f'<img class="ic" src="{href(info["icon"])}" alt="" width="64" height="64" loading="lazy">'
                             f'<div class="tx"><h4>{esc(info["title"])}</h4>'
                             + (f'<div class="sub">{esc(info["sub"])}</div>' if info['sub'] else '')
                             + (f'<p>{esc(info["desc"])}</p>' if info['desc'] else '')
                             + f'<div class="chips">{"".join(chips)}</div></div></a>')
            rest = sorted(entries, key=lambda e: not e.files)[a.max_rows:]
            more = ''
            folder = self.rel(s.path, self.browse) + '/'
            if rest:
                more = (f'<p class="more">… and {len(rest):,} more entries ({human(sum(e.bytes for e in rest))}, '
                        f'{sum(e.files for e in rest):,} files) not shown here — <a href="{href(folder)}">open the folder</a>.</p>')
            trunc = ('<p class="more">This section is larger than the scan limit; the totals cover only part of it.</p>'
                     if s.truncated else '')
            queued = f' · {queued_text(spf, spb)} still queued' if spf else ''
            gsel = ''
            if len(groups) > 1:
                gsel = ('<select id="g" aria-label="Group" hidden><option value="">All groups</option>' +
                        ''.join(f'<option value="{esc(g)}">{esc(g)}</option>' for g in groups) + '</select>')
            body = (f'<section class="hero">{picture(s.art, "", s.title, have_art)}<div class="txt">'
                    f'<h1>{esc(s.title)}</h1><p class="muted">{esc(s.blurb)}</p>'
                    f'<p><b>{len(entries):,}</b> entries · <b>{human(sb)}</b> in {sf:,} files{queued} · '
                    f'<a href="{href(folder)}">open the folder</a></p></div></section>{trunc}'
                    f'<div class="tools"><input id="q" type="search" placeholder="Search {esc(s.title.lower())}…" '
                    f'aria-label="Search" hidden>{gsel}</div>'
                    f'<div class="grid">{"".join(cards)}</div>{more}'
                    f'<footer>Static snapshot generated {esc(stamp)}. Click a card for details, files and links.</footer>'
                    f'{FILTER_JS}')
            write_atomic(page_path, page(f'{s.title} · {a.title}', body, self.nav('../', s.name, shown)))

        # index
        tot = {k: sum(x[k] for x in summary['sections']) for k in ('bytes', 'files', 'pending_bytes', 'pending_files')}
        summary.update(tot)
        scards = []
        for s in self.sections:
            info = next((x for x in summary['sections'] if x['name'] == s.name), None)
            if not info:
                continue
            q = (f'<br><span class="chip q">queued {queued_text(info["pending_files"], info["pending_bytes"])}</span>'
                 if info['pending_files'] else '')
            pk = ''.join(f'<img src="browse/{href(p)}" alt="" width="34" height="34" loading="lazy">' for p in peeks.get(s.name, []))
            scards.append(f'<a class="scard" href="browse/{s.name}.html">{picture(s.art, "browse/", s.title, have_art)}'
                          f'<div class="body"><h3>{esc(s.title)}</h3><p>{esc(s.blurb)}</p>'
                          f'<div class="nums"><b>{info["entries"]:,}</b> entries · <b>{human(info["bytes"])}</b>{q}</div>'
                          + (f'<div class="peek">{pk}</div>' if pk else '') + '</div></a>')
        pf = tot['pending_files']
        big = human(tot['pending_bytes']) if tot['pending_bytes'] else f'{pf:,}'
        label = f'queued ({pf:,} files)' if tot['pending_bytes'] else 'queued files'
        queued = f'<div class="stat"><b>{big}</b><span>{label}</span></div>' if pf else ''
        empty = '' if scards else '<p class="more">Nothing has been downloaded into this archive yet.</p>'
        body = (f'<section class="hero">{picture("docs-map", "browse/", "An open pop-up book of the archive", have_art)}'
                f'<div class="txt"><h1>{esc(a.title)} offline archive</h1>'
                '<p class="muted">Everything here is a plain file: browse it from any file explorer, USB disk or simple '
                'file server. No server or internet connection is needed to read these pages.</p>'
                f'<div class="stats"><div class="stat"><b>{human(tot["bytes"])}</b><span>stored</span></div>'
                f'<div class="stat"><b>{tot["files"]:,}</b><span>files</span></div>'
                f'<div class="stat"><b>{len(scards)}</b><span>collections</span></div>{queued}</div></div></section>'
                f'{empty}<div class="sections-grid">{"".join(scards)}</div>'
                '<h2>Using the archive</h2><div class="panel"><ul>'
                '<li><b>Library (ZIM files)</b>: open with Kiwix desktop / Android, or <code>kiwix-serve file.zim</code>.</li>'
                '<li><b>Models</b>: GGUF files run with llama.cpp (<code>llama-server -m model.gguf</code>); safetensors '
                'folders load in transformers, vLLM or similar.</li>'
                '<li><b>Tools &amp; installers</b>: pick the folder for your platform; checksums sit next to the files '
                'where upstream publishes them.</li>'
                '<li>When the Val Ark server runs on this box, its web UI adds search, chat and downloads; these pages are '
                'the server-free view.</li></ul></div>'
                f'<footer>Static snapshot generated {esc(stamp)} · <a href="browse/summary.json">summary.json</a></footer>')
        write_atomic(os.path.join(self.browse, 'summary.json'), json.dumps(summary, indent=1) + '\n')
        write_atomic(os.path.join(self.out, 'index.html'), page(f'{a.title} archive', body, self.nav('', None, shown)))

        # caches + stale cleanup (only files this tool owns)
        cache = dict(self.zim_seen)
        write_atomic(self.zim_cache_path, json.dumps(cache, indent=0, sort_keys=True) + '\n')
        for icon in (v.get('icon') for v in cache.values()):
            if icon:
                self.thumbs_used.add(icon.split('/', 1)[1])
        for name in self.items_have - self.items_used:
            if name.endswith('.html') and details_left > 0:
                try:
                    os.remove(os.path.join(self.items_dir, name))
                except OSError:
                    pass
        for name in self.thumbs_have - self.thumbs_used:
            try:
                os.remove(os.path.join(self.thumbs_dir, name))
            except OSError:
                pass
        return len(scards), tot


def main(argv=None):
    ap = argparse.ArgumentParser(description='Static catalog pages for an archive.')
    ap.add_argument('--root', required=True)
    ap.add_argument('--out')
    ap.add_argument('--section', action='append', default=[])
    ap.add_argument('--listing')
    ap.add_argument('--pending')
    ap.add_argument('--walk', action='append', default=[])
    ap.add_argument('--max-rows', type=int, default=3000)
    ap.add_argument('--max-files', type=int, default=60)
    ap.add_argument('--meta-limit', type=int, default=4000)
    ap.add_argument('--zim-limit', type=int, default=400)
    ap.add_argument('--max-details', type=int, default=8000)
    ap.add_argument('--walk-limit', type=int, default=5_000_000)
    ap.add_argument('--title', default='Val Ark')
    ap.add_argument('--web-ui', default=os.path.join(REPO, 'web-ui'))
    ap.add_argument('--data-dir', default=os.path.join(REPO, 'data'))
    ap.add_argument('--art-dir', default=os.path.join(REPO, 'docs', 'img', 'popup'))
    ap.add_argument('--now', type=float)
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 64
    if a.max_rows < 1 or a.max_files < 0 or a.meta_limit < 0 or a.walk_limit < 1 or a.zim_limit < 0 or a.max_details < 0:
        print('static_site: limits must be positive', file=sys.stderr)
        return 64
    names = {s[0] for s in SECTIONS}
    bad = [w for w in a.walk if w not in names]
    if bad:
        print(f'static_site: unknown --walk section {bad[0]!r}', file=sys.stderr)
        return 64
    root = os.path.abspath(a.root)
    out = os.path.abspath(a.out or root)
    if not os.path.isdir(root):
        print(f'static_site: no such root: {a.root}', file=sys.stderr)
        return 1
    over = {}
    for spec in a.section:
        name, sep, path = spec.partition('=')
        if not sep or not name or not path or name not in names:
            print(f'static_site: bad --section {spec!r} (NAME=PATH, NAME one of '
                  f'{", ".join(s[0] for s in SECTIONS)})', file=sys.stderr)
            return 64
        over[name] = path
    sections = []
    for name, d, title, blurb, art, depth in SECTIONS:
        p = over.get(name, d)
        if p == '-':
            continue
        sections.append(Section(name, os.path.abspath(os.path.join(root, p)), title, blurb, art, depth))

    if a.listing:
        try:
            read_listing(a.listing, sections, root, a.max_files, False)
        except OSError as e:
            print(f'static_site: listing: {e}', file=sys.stderr)
            return 1
    budget = a.walk_limit
    for s in sections:
        if a.listing and s.name not in a.walk:
            continue
        if os.path.isdir(s.path) and budget > 0:
            budget = walk(s, a.max_files, budget)
        elif budget <= 0 and os.path.isdir(s.path):
            s.truncated = True
    if a.pending:
        try:
            read_listing(a.pending, sections, root, a.max_files, True)
        except OSError as e:
            print(f'static_site: pending: {e}', file=sys.stderr)
            return 1
    try:
        n, tot = Builder(a, root, out, sections).build()
    except OSError as e:
        print(f'static_site: cannot write {out}: {e}', file=sys.stderr)
        return 1
    print(f'static_site: {n} sections, {tot["files"]:,} files, {human(tot["bytes"])} -> {os.path.join(out, "index.html")}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
