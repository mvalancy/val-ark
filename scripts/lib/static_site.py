#!/usr/bin/env python3
"""Static browse pages for an archive: explore it from a plain file server (no server.js).

Writes <out>/index.html and <out>/browse/<section>.html (+ browse/art/*.svg, browse/summary.json):
self-contained HTML with inline CSS, RELATIVE links only, no external URLs and no JavaScript
requirement (one small inline filter box is progressive). Works over file://, an SMB share
opened in a file explorer, a USB disk, or `python3 -m http.server`.

Usage (stdlib only):
  static_site.py --root DIR [--out DIR] [--section NAME=PATH ...] [--listing TSV] [--pending TSV]
                 [--walk NAME ...] [--max-rows N] [--max-files N] [--meta-limit N] [--walk-limit N]
                 [--title TEXT]
                 [--art-dir DIR] [--now EPOCH]

  --root      the archive root; sections are found as known sub-directories of it
              (models, content, tools, installers, dev-stack, software, datasets, sources).
              Works for the data-root layout (pass --section models=<MODELS_DIR> when models live
              elsewhere) and for a flat mirror where everything sits under one root.
  --out       where index.html + browse/ go (default --root).
  --section   NAME=PATH overrides a section's directory (relative to --root, or absolute);
              NAME=- drops the section.
  --listing   TSV of the files that are present, `path<TAB>size[<TAB>mtime]`, path relative to
              --root ('-' = stdin). With a listing nothing is walked: a caller that keeps its own
              index (a download queue, a manifest) never has to walk a slow network share.
  --walk      with --listing: also walk section NAME on disk (a tree the listing does not cover).
  --pending   the same TSV format for files still on the way; shown as "queued" per entry.
  --max-rows  entries listed per section page (default 3000); the rest are summarised.
  --max-files files listed under one entry (default 8, largest first).
  --meta-limit model-card / README reads per run (default 4000; small files only, 64 KiB max).
  --walk-limit stop walking after this many files (default 5,000,000) and say so on the page.
  --now       fixed "generated" time (tests).

Never followed or listed: dot files, *.part / *.tmp / *.oversize-* leftovers, symlinked
directories, and every directory that is not a section (state/, private/, the repo's own code).
Pages are written with temp + rename (no chmod: network shares refuse it); art is copied only
when it changed. Exit 0 ok, 1 root missing or output unwritable, 64 usage.
"""
import argparse, heapq, html, json, os, re, sys, time, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# name, default dir, title, blurb, art scene, entry depth per first path component ('*' = default)
SECTIONS = [
    ('models', 'models', 'AI models',
     'Language, speech, vision and image models. Each row is one model folder; GGUF files run in '
     'llama.cpp, safetensors in PyTorch / vLLM / transformers.', 'models', {'huggingface': 3, '*': 2}),
    ('content', 'content', 'Library',
     'Offline encyclopedias, manuals and maps. ZIM files open in Kiwix (desktop, Android or kiwix-serve).',
     'knowledge', {'*': 2}),
    ('tools', 'tools', 'Tools & apps',
     'Portable programs, one folder per platform (linux-x86_64, linux-arm64, macos-arm64, windows-x64).',
     'tools', {'*': 2}),
    ('installers', 'installers', 'OS installers',
     'Operating-system images, netboot files, router firmware and board support packages.',
     'platforms', {'*': 2}),
    ('dev-stack', 'dev-stack', 'Developer stack',
     'Current releases of compilers, languages, databases, containers, cloud and security tools.',
     'design', {'*': 2}),
    ('software', 'software', 'Software releases',
     'Upstream release assets and offline package sets.', 'architecture', {'releases': 3, '*': 2}),
    ('datasets', 'datasets', 'Datasets',
     'Training and reference datasets: robotics, agriculture, weather, climate, earth observation.',
     'nas', {'open-data': 4, '*': 3}),
    ('sources', 'sources', 'Source code', 'Source archives and git bundles of the projects in the archive.',
     'community', {'*': 1}),
]
SKIP = re.compile(r'(^\.)|(\.part$)|(\.tmp(-\d+)?$)|(\.oversize-\d+$)')
README = ('README.md', 'readme.md', 'README.txt', 'README')
LICENSE = re.compile(r'(?i)^(license|licence|copying|notice)(\.[a-z]+)?$')


def human(n):
    n = float(n or 0)
    for unit in ('B', 'KB', 'MB', 'GB', 'TB', 'PB'):
        if n < 1000 or unit == 'PB':
            return (f'{n:.0f} {unit}' if unit == 'B' or n >= 100 else f'{n:.1f} {unit}')
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


class Entry:
    __slots__ = ('key', 'is_dir', 'bytes', 'files', 'mtime', 'top', 'pending_bytes', 'pending_files',
                 'readme', 'license')

    def __init__(self, key, is_dir):
        self.key, self.is_dir = key, is_dir
        self.bytes = self.files = self.pending_bytes = self.pending_files = 0
        self.mtime = 0.0
        self.top = []          # min-heap of (size, relpath-inside-entry)
        self.readme = self.license = None


class Section:
    def __init__(self, name, path, title, blurb, art, depth):
        self.name, self.path, self.title, self.blurb, self.art, self.depth = name, path, title, blurb, art, depth
        self.entries = {}
        self.truncated = False

    def entry_for(self, rel):
        parts = rel.split('/')
        d = self.depth.get(parts[0], self.depth['*']) if len(parts) > 1 else 1
        if len(parts) <= d:
            return self.entries.setdefault(rel, Entry(rel, False)), parts[-1]
        key = '/'.join(parts[:d])
        e = self.entries.setdefault(key, Entry(key, True))
        return e, '/'.join(parts[d:])

    def add(self, rel, size, mtime, max_files, pending=False):
        e, inner = self.entry_for(rel)
        if pending:
            e.pending_bytes += size; e.pending_files += 1
            return
        e.bytes += size; e.files += 1
        e.mtime = max(e.mtime, mtime)
        if e.is_dir:
            if inner in README and '/' not in inner:
                e.readme = inner
            elif '/' not in inner and LICENSE.match(inner):
                e.license = inner
            item = (size, inner)
            if len(e.top) < max_files:
                heapq.heappush(e.top, item)
            elif item > e.top[0]:
                heapq.heapreplace(e.top, item)


def walk(section, max_files, budget):
    """Recursive os.scandir of one section; returns files left in the walk budget."""
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


FRONT = re.compile(r'\A---\s*\n(.*?)\n---\s*\n', re.S)


def card(path):
    """(excerpt, licence, pipeline) from a small README / model card; never more than 64 KiB."""
    try:
        with open(path, 'rb') as f:
            text = f.read(65536).decode('utf-8', 'replace')
    except OSError:
        return None, None, None
    lic = pipe = None
    m = FRONT.match(text)
    if m:
        for line in m.group(1).splitlines():
            k, _, v = line.partition(':')
            v = v.strip().strip('"\'')
            if k.strip() in ('license', 'license_name') and v and not lic:
                lic = v
            elif k.strip() == 'pipeline_tag' and v:
                pipe = v
        text = text[m.end():]
    excerpt = None
    for para in re.split(r'\n\s*\n', text):
        p = para.strip()
        if not p or p[0] in '#<|![>`-*=' or p.startswith(('```', '[!', '[![')):
            continue
        p = re.sub(r'!\[[^\]]*\]\([^)]*\)', '', p)
        p = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', p)
        p = re.sub(r'<[^>]+>', '', p)
        p = re.sub(r'[*_`]+', '', p)
        p = ' '.join(p.split())
        if len(p) < 40:
            continue
        excerpt = p if len(p) <= 320 else p[:317].rsplit(' ', 1)[0] + '…'
        break
    return excerpt, lic, pipe


ZIM = re.compile(r'^(?P<proj>[a-z0-9.-]+?)_(?P<lang>[a-z]{2,3}(?:-[a-z]+)?)_(?P<rest>.+?)(?:_(?P<date>\d{4}-\d{2}))?\.zim$', re.I)
FLAVOURS = {'maxi': 'full, with images', 'nopic': 'text only', 'mini': 'introductions only', 'all': 'everything'}


def zim_note(name):
    m = ZIM.match(name)
    if not m:
        return 'Kiwix ZIM archive'
    rest = m.group('rest').split('_')
    flav = FLAVOURS.get(rest[-1], '') if rest else ''
    topic = ' '.join(rest[:-1] if flav else rest)
    bits = [m.group('proj').replace('.', ' ').title(), f'({m.group("lang")})']
    if topic and topic != 'all':
        bits.append('· ' + topic.replace('-', ' '))
    if flav:
        bits.append('· ' + flav)
    if m.group('date'):
        bits.append('· ' + m.group('date'))
    return ' '.join(bits)


CSS = """
:root{--bg:#f6f0e4;--paper:#fffaf0;--ink:#2b2622;--muted:#6f655b;--line:#e3d7c3;--accent:#b5562f;
--accent2:#2f6f6a;--chip:#efe4cf;--shadow:0 1px 0 #e9dcc6,0 8px 24px -12px rgba(80,50,20,.35);color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#1c1a17;--paper:#262320;--ink:#efe7da;--muted:#a89d8f;
--line:#3a352f;--accent:#e58a5c;--accent2:#6cc0b8;--chip:#332e28;--shadow:0 1px 0 #2f2b26,0 10px 28px -14px #000;color-scheme:dark}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
a{color:var(--accent2)}a:hover{color:var(--accent)}
.wrap{max-width:1180px;margin:0 auto;padding:0 16px 48px}
header.top{display:flex;flex-wrap:wrap;gap:8px 18px;align-items:baseline;padding:18px 0 8px}
header.top .brand{font:700 20px/1.2 Georgia,"Iowan Old Style",serif;text-decoration:none;color:var(--ink)}
nav.sections{display:flex;flex-wrap:wrap;gap:6px}nav.sections a{padding:3px 10px;border-radius:99px;background:var(--chip);
text-decoration:none;color:var(--ink);font-size:14px}nav.sections a[aria-current]{background:var(--accent);color:#fff}
.hero{background:var(--paper);border:1px solid var(--line);border-radius:18px;box-shadow:var(--shadow);overflow:hidden;margin:10px 0 22px}
.hero img{display:block;width:100%;height:auto}.hero .txt{padding:14px 22px 20px}
h1{font:700 clamp(26px,4vw,38px)/1.15 Georgia,"Iowan Old Style",serif;margin:4px 0 6px}
h2{font:700 22px/1.2 Georgia,serif;margin:28px 0 10px}.muted{color:var(--muted)}
.stats{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0 0}.stat{background:var(--chip);border-radius:12px;padding:8px 14px}
.stat b{display:block;font-size:20px}.stat span{font-size:13px;color:var(--muted)}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:16px}
.card{background:var(--paper);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);overflow:hidden;
display:flex;flex-direction:column;text-decoration:none;color:var(--ink);transition:transform .2s}
.card:hover{transform:translateY(-3px) rotate(-.3deg)}.card img{width:100%;height:auto;display:block;border-bottom:1px solid var(--line)}
.card .body{padding:12px 16px 16px}.card h3{margin:0 0 4px;font:700 19px Georgia,serif}.card p{margin:0 0 8px;font-size:14px;color:var(--muted)}
.card .nums{font-size:14px}.empty{opacity:.6}
.tools{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:4px 0 12px}
input[type=search]{flex:1 1 260px;font:inherit;padding:8px 12px;border-radius:10px;border:1px solid var(--line);background:var(--paper);color:var(--ink)}
.tbl{width:100%;border-collapse:collapse;background:var(--paper);border:1px solid var(--line);border-radius:12px;overflow:hidden}
.tbl th,.tbl td{padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top;text-align:left}
.tbl th{font-size:13px;color:var(--muted);font-weight:600;background:var(--chip)}
.tbl td.n{white-space:nowrap;text-align:right;font-variant-numeric:tabular-nums}
.tbl .name a{font-weight:600;word-break:break-word}.tbl .desc{font-size:14px;color:var(--muted);margin-top:2px}
.chip{display:inline-block;font-size:12px;padding:1px 8px;border-radius:99px;background:var(--chip);margin:2px 4px 0 0}
.chip.q{background:var(--accent);color:#fff}details{font-size:13px;margin-top:4px}details ul{margin:4px 0;padding-left:18px}
.more{margin:10px 0;padding:10px 14px;border:1px dashed var(--line);border-radius:12px}
footer{margin-top:36px;font-size:13px;color:var(--muted)}
.howto{background:var(--paper);border:1px solid var(--line);border-radius:16px;padding:6px 20px 12px}
@media (max-width:640px){.tbl .hide-s{display:none}}
@media (prefers-reduced-motion:reduce){.card{transition:none}}
"""

FILTER_JS = ("<script>(function(){var q=document.getElementById('q');if(!q)return;q.hidden=false;"
             "q.addEventListener('input',function(){var t=q.value.toLowerCase();"
             "document.querySelectorAll('tr[data-k]').forEach(function(r){"
             "r.hidden=t&&r.getAttribute('data-k').indexOf(t)<0;});});})();</script>")


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


def write_atomic(path, data):
    data = data.encode('utf-8') if isinstance(data, str) else data
    try:
        with open(path, 'rb') as f:
            if f.read() == data:
                return
    except OSError:
        pass
    tmp = f'{path}.tmp-{os.getpid()}'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(description='Static browse pages for an archive.')
    ap.add_argument('--root', required=True)
    ap.add_argument('--out')
    ap.add_argument('--section', action='append', default=[])
    ap.add_argument('--listing')
    ap.add_argument('--pending')
    ap.add_argument('--walk', action='append', default=[])
    ap.add_argument('--max-rows', type=int, default=3000)
    ap.add_argument('--max-files', type=int, default=8)
    ap.add_argument('--meta-limit', type=int, default=4000)
    ap.add_argument('--walk-limit', type=int, default=5_000_000)
    ap.add_argument('--title', default='Val Ark')
    ap.add_argument('--art-dir', default=os.path.join(REPO, 'docs', 'img', 'popup'))
    ap.add_argument('--now', type=float)
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 64
    if a.max_rows < 1 or a.max_files < 0 or a.meta_limit < 0 or a.walk_limit < 1:
        print('static_site: limits must be positive', file=sys.stderr)
        return 64
    root = os.path.abspath(a.root)
    out = os.path.abspath(a.out or root)
    if not os.path.isdir(root):
        print(f'static_site: no such root: {a.root}', file=sys.stderr)
        return 1
    names = {s[0] for s in SECTIONS}
    bad = [w for w in a.walk if w not in names]
    if bad:
        print(f'static_site: unknown --walk section {bad[0]!r}', file=sys.stderr)
        return 64
    over = {}
    for spec in a.section:
        name, sep, path = spec.partition('=')
        if not sep or not name or not path or name not in {s[0] for s in SECTIONS}:
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

    now = a.now if a.now is not None else time.time()
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

    browse = os.path.join(out, 'browse')
    try:
        os.makedirs(os.path.join(browse, 'art'), exist_ok=True)
    except OSError as e:
        print(f'static_site: cannot write {out}: {e}', file=sys.stderr)
        return 1
    have_art = set()
    for s in [('docs-map',)] + [(x[4],) for x in SECTIONS]:
        art = s[0]
        ok = True
        for mode in ('light', 'dark'):
            src = os.path.join(a.art_dir, f'{art}-{mode}.svg')
            try:
                with open(src, 'rb') as f:
                    write_atomic(os.path.join(browse, 'art', f'{art}-{mode}.svg'), f.read())
            except OSError:
                ok = False
        if ok:
            have_art.add(art)

    # Model cards / READMEs (small reads, capped)
    reads = a.meta_limit
    meta = {}
    for s in sections:
        for e in s.entries.values():
            if reads <= 0:
                break
            if e.is_dir and e.readme and e.files:
                meta[(s.name, e.key)] = card(os.path.join(s.path, e.key, e.readme))
                reads -= 1

    stamp = time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime(now))
    shown = [s for s in sections if s.entries]

    def nav(prefix, current):
        links = ''.join(f'<a href="{prefix}browse/{s.name}.html"' + (' aria-current="page"' if s.name == current else '')
                        + f'>{esc(s.title)}</a>' for s in shown)
        home = f'{prefix}index.html'
        return (f'<header class="top"><a class="brand" href="{home}">📖 {esc(a.title)}</a>'
                f'<nav class="sections" aria-label="Sections">{links}</nav></header>')

    tot_b = sum(e.bytes for s in sections for e in s.entries.values())
    tot_f = sum(e.files for s in sections for e in s.entries.values())
    tot_pb = sum(e.pending_bytes for s in sections for e in s.entries.values())
    tot_pf = sum(e.pending_files for s in sections for e in s.entries.values())
    summary = {'generated_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now)), 'bytes': tot_b, 'files': tot_f,
               'pending_bytes': tot_pb, 'pending_files': tot_pf, 'sections': []}

    for s in sections:
        page_path = os.path.join(browse, f'{s.name}.html')
        if not s.entries:
            try:
                os.remove(page_path)
            except OSError:
                pass
            continue
        entries = sorted(s.entries.values(), key=lambda e: (e.key.split('/')[0], e.key.lower()))
        sb = sum(e.bytes for e in entries); sf = sum(e.files for e in entries)
        spb = sum(e.pending_bytes for e in entries); spf = sum(e.pending_files for e in entries)
        summary['sections'].append({'name': s.name, 'title': s.title, 'entries': len(entries), 'bytes': sb, 'files': sf,
                                    'pending_bytes': spb, 'pending_files': spf, 'truncated': s.truncated})
        rows, group, listed = [], None, entries[:a.max_rows]
        grouped = {e.key.split('/')[0] if '/' in e.key else '' for e in listed} != {''}
        for e in listed:
            g = e.key.split('/')[0] if '/' in e.key else ''
            if g != group and grouped:
                group = g
                rows.append(f'<tr><th colspan="4">{esc(g or "(top level)")}</th></tr>')
            name = e.key[len(g) + 1:] if g and grouped else e.key
            target = os.path.relpath(os.path.join(s.path, e.key), browse) + ('/' if e.is_dir else '')
            desc, chips = '', []
            if s.name == 'content' and not e.is_dir and e.key.lower().endswith('.zim'):
                desc = zim_note(os.path.basename(e.key))
            m = meta.get((s.name, e.key))
            if m:
                if m[0]:
                    desc = m[0]
                if m[2]:
                    chips.append(esc(m[2]))
                if m[1]:
                    chips.append('licence: ' + esc(m[1]))
            if e.pending_files:
                chips.append(f'<span class="chip q">queued: {queued_text(e.pending_files, e.pending_bytes)}</span>')
            if not e.files:
                chips.append('not downloaded yet')
            chip_html = ''.join(c if c.startswith('<span') else f'<span class="chip">{c}</span>' for c in chips)
            extra = ''
            if e.license:
                lt = os.path.relpath(os.path.join(s.path, e.key, e.license), browse)
                extra += f' · <a href="{href(lt)}">licence file</a>'
            if e.readme:
                rt = os.path.relpath(os.path.join(s.path, e.key, e.readme), browse)
                extra += f' · <a href="{href(rt)}">readme</a>'
            files = ''
            if e.is_dir and e.top:
                items = ''.join(
                    f'<li><a href="{href(os.path.relpath(os.path.join(s.path, e.key, inner), browse))}">{esc(inner)}</a> '
                    f'<span class="muted">{human(sz)}</span></li>' for sz, inner in sorted(e.top, reverse=True))
                more = f'<li class="muted">… {e.files - len(e.top)} more in the folder</li>' if e.files > len(e.top) else ''
                files = f'<details><summary>Largest files</summary><ul>{items}{more}</ul></details>'
            upd = time.strftime('%Y-%m-%d', time.gmtime(e.mtime)) if e.mtime else ''
            key = esc(f'{e.key} {desc}'.lower())
            link = f'<a href="{href(target)}">{esc(name)}</a>' if e.files else f'<b>{esc(name)}</b>'
            rows.append(f'<tr data-k="{key}"><td class="name">{link}{extra}'
                        f'<div class="desc">{esc(desc)}</div>{chip_html}{files}</td>'
                        f'<td class="n">{human(e.bytes)}</td><td class="n hide-s">{e.files:,}</td>'
                        f'<td class="n hide-s">{upd}</td></tr>')
        rest = entries[a.max_rows:]
        more = ''
        if rest:
            folder = os.path.relpath(s.path, browse) + '/'
            more = (f'<p class="more">… and {len(rest):,} more entries ({human(sum(e.bytes for e in rest))}, '
                    f'{sum(e.files for e in rest):,} files) not listed here — <a href="{href(folder)}">open the folder</a>.</p>')
        trunc = ('<p class="more">This section is larger than the scan limit; the totals cover only part of it.</p>'
                 if s.truncated else '')
        queued = f' · {queued_text(spf, spb)} still queued' if spf else ''
        folder = os.path.relpath(s.path, browse) + '/'
        body = (f'<section class="hero">{picture(s.art, "", s.title, have_art)}<div class="txt">'
                f'<h1>{esc(s.title)}</h1><p class="muted">{esc(s.blurb)}</p>'
                f'<p><b>{len(entries):,}</b> entries · <b>{human(sb)}</b> in {sf:,} files{queued} · '
                f'<a href="{href(folder)}">open the folder</a></p></div></section>{trunc}'
                f'<div class="tools"><input id="q" type="search" placeholder="Filter {esc(s.title.lower())}…" '
                f'aria-label="Filter" hidden></div>'
                f'<table class="tbl"><thead><tr><th>Name</th><th class="n">Size</th><th class="n hide-s">Files</th>'
                f'<th class="n hide-s">Updated</th></tr></thead><tbody>{"".join(rows)}</tbody></table>{more}'
                f'<footer>Static snapshot generated {esc(stamp)}. Links open the files and folders directly.</footer>'
                f'{FILTER_JS}')
        try:
            write_atomic(page_path, page(f'{s.title} · {a.title}', body, nav('../', s.name)))
        except OSError as e:
            print(f'static_site: cannot write {page_path}: {e}', file=sys.stderr)
            return 1

    cards = []
    for s in sections:
        info = next((x for x in summary['sections'] if x['name'] == s.name), None)
        if not info:
            continue
        q = (f'<br><span class="chip q">queued {queued_text(info["pending_files"], info["pending_bytes"])}</span>'
             if info['pending_files'] else '')
        cards.append(f'<a class="card" href="browse/{s.name}.html">{picture(s.art, "browse/", s.title, have_art)}'
                     f'<div class="body"><h3>{esc(s.title)}</h3><p>{esc(s.blurb)}</p>'
                     f'<div class="nums"><b>{info["entries"]:,}</b> entries · <b>{human(info["bytes"])}</b>{q}</div></div></a>')
    queued = (f'<div class="stat"><b>{human(tot_pb) if tot_pb else f"{tot_pf:,}"}</b><span>queued'
              f'{f" ({tot_pf:,} files)" if tot_pb else " files"}</span></div>' if tot_pf else '')
    empty = '' if cards else '<p class="more">Nothing has been downloaded into this archive yet.</p>'
    body = (f'<section class="hero">{picture("docs-map", "browse/", "An open pop-up book of the archive", have_art)}'
            f'<div class="txt"><h1>{esc(a.title)} offline archive</h1>'
            '<p class="muted">Everything here is a plain file: browse it from any file explorer, USB disk or simple '
            'file server. No server or internet connection is needed to read this page.</p>'
            f'<div class="stats"><div class="stat"><b>{human(tot_b)}</b><span>stored</span></div>'
            f'<div class="stat"><b>{tot_f:,}</b><span>files</span></div>'
            f'<div class="stat"><b>{len(cards)}</b><span>collections</span></div>{queued}</div></div></section>'
            f'{empty}<div class="cards">{"".join(cards)}</div>'
            '<h2>Using the archive</h2><div class="howto"><ul>'
            '<li><b>Library (ZIM files)</b>: open with Kiwix desktop / Android, or <code>kiwix-serve file.zim</code>.</li>'
            '<li><b>Models</b>: GGUF files run with llama.cpp (<code>llama-server -m model.gguf</code>); safetensors '
            'folders load in transformers, vLLM or similar.</li>'
            '<li><b>Tools &amp; installers</b>: pick the folder for your platform; checksums sit next to the files '
            'where upstream publishes them.</li>'
            '<li>When the Val Ark server runs on this box, its web UI adds search, chat and downloads; this page is the '
            'server-free view.</li></ul></div>'
            f'<footer>Static snapshot generated {esc(stamp)} · <a href="browse/summary.json">summary.json</a></footer>')
    try:
        write_atomic(os.path.join(browse, 'summary.json'), json.dumps(summary, indent=1) + '\n')
        write_atomic(os.path.join(out, 'index.html'), page(f'{a.title} archive', body, nav('', None)))
    except OSError as e:
        print(f'static_site: cannot write {out}: {e}', file=sys.stderr)
        return 1
    print(f'static_site: {len(cards)} sections, {tot_f:,} files, {human(tot_b)} -> {os.path.join(out, "index.html")}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
