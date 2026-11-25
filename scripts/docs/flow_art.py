#!/usr/bin/env python3
"""Animated "how it works" diagrams for the Val Ark docs (the picture book's explainer pages).

Where popup_art.py draws one pop-up scene at the top of each guide, this draws the
system itself: boxes for the parts, arrows for what flows between them, and dots that
travel along the arrows so a reader can follow the data. Output: docs/img/flow/
<id>-{light,dark}.svg, deterministic, stdlib only, no scripts or external references.

  python3 scripts/docs/flow_art.py           # rewrite the SVGs
  python3 scripts/docs/flow_art.py --check   # exit 1 if any SVG is stale (tests/test-doc-art.sh)
  python3 scripts/docs/flow_art.py --list    # which docs embed each diagram

Each diagram ends fully drawn and stays that way, so under prefers-reduced-motion (or in a
renderer that ignores CSS animation) the whole picture shows; only the travelling dots and
pulses stop. A renderer that snapshots at t=0 with animations on sees it mid-build.
"""
import math
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))   # share the palette and icons with the pop-up scenes
from popup_art import ACCENTS, ICONS, THEMES, esc  # noqa: E402

ROOT = HERE.parents[1]
OUT = ROOT / 'docs' / 'img' / 'flow'
W = 1200
NW, NH = 150, 92          # node card size

# ---------------------------------------------------------------- diagrams
# zones: (x, y, w, h, title) shaded areas.  nodes: id -> (x, y, icon, label, caption, accent index)
# edges: (from, to, label or '', kind) ; kind 0 = straight, 'elbow' = down, across, down (snaking rows).
# A 'ring' diagram instead lays its nodes on a circle and pulses them in turn.
DIAGRAMS = {
    'system': dict(
        title='How an Ark works, end to end',
        sub='Fetch once from the internet, keep it healthy on one disk, share it on the LAN.',
        h=500,
        zones=[(28, 104, 250, 372, 'The internet (once)'), (306, 104, 584, 372, 'The Ark'),
               (918, 104, 254, 372, 'Your network')],
        nodes={
            'kiwix': (153, 200, 'book', 'Kiwix library', 'Wikipedia and more', 0),
            'hf': (153, 310, 'brain', 'Model hubs', 'AI models', 1),
            'gh': (153, 420, 'cube', 'Releases', 'OS images, apps', 2),
            'lib': (410, 200, 'disk', 'Librarian', 'plans what fits', 3),
            'loop': (410, 420, 'gear', 'Loop', 'heals every 30 min', 4),
            'disk': (600, 310, 'server', 'Data disk', 'tools, models, ZIMs', 5),
            'srv': (790, 200, 'globe', 'Web server', 'live UI, library, apps', 6),
            'site': (790, 420, 'paste', 'Static pages', 'written to the disk', 7),
            'people': (1045, 200, 'house', 'People', 'browsers, phones', 0),
            'share': (1045, 420, 'wifi', 'File share', 'SMB, NFS, USB', 1),
        },
        edges=[('kiwix', 'lib', 'catalogs', 0), ('hf', 'lib', '', 0), ('gh', 'lib', 'installers', 0),
               ('gh', 'loop', 'weekly app refresh', 0),
               ('lib', 'disk', 'downloads', 0), ('loop', 'disk', 'repairs', 0), ('loop', 'lib', 'tops up', 0),
               ('loop', 'site', 'rewrites', 0), ('disk', 'srv', '', 0),
               ('srv', 'people', 'web UI', 0), ('site', 'share', 'plain HTML', 0)],
        used=['docs/ARCHITECTURE.md', 'README.md']),
    'fill': dict(
        title='How the Librarian fills a disk',
        sub='Four passes, most important first, until the disk reaches its reserve.',
        h=470,
        zones=[(28, 104, 230, 340, 'Catalogs'), (286, 104, 650, 340, 'The planner, in order'),
               (964, 104, 208, 340, 'The disk')],
        nodes={
            'cat': (143, 200, 'globe', 'Catalogs', 'Kiwix, models, ISOs', 0),
            'cand': (143, 360, 'board', 'Candidates', 'size and value', 1),
            'p0': (390, 200, 'leaf', '0 Essentials', 'water, medicine', 2),
            'p1': (610, 200, 'map', '1 Diversity', 'one of each kind', 3),
            'p2': (830, 200, 'spark', '2 Small', 'value per byte', 4),
            'p3': (390, 360, 'disk', '3 Fill', 'big flagships', 5),
            'dl': (610, 360, 'play', 'Download', 'resumable, checked', 7),
            'disk': (1068, 200, 'server', 'Data disk', 'stops at the reserve', 0),
            'trade': (1068, 360, 'wrench', 'Trade up', 'on request, to fit', 6),
        },
        edges=[('cat', 'cand', '', 0), ('cand', 'p0', '', 0), ('p0', 'p1', '', 0), ('p1', 'p2', '', 0),
               ('p2', 'p3', '', 'elbow'), ('p3', 'dl', '', 0), ('dl', 'disk', '', 0), ('trade', 'disk', 'evicts', 0)],
        used=['docs/LIBRARIAN.md', 'docs/ARCHITECTURE.md']),
    'heal-loop': dict(
        title='The self-healing loop',
        sub='Every 30 minutes, and after a reboot, the Ark checks itself and fixes what it can.',
        h=670, ring=(600, 382, 470, 232),
        nodes={
            'disk': (0, 0, 'disk', 'Disk check', 'mounted, writable', 0),
            'layout': (0, 0, 'wrench', 'Repair layout', 'folders, symlinks', 1),
            'web': (0, 0, 'globe', 'Web up', 'server, services', 2),
            'self': (0, 0, 'ark', 'Copy itself', 'for new nodes', 3),
            'catalog': (0, 0, 'map', 'Refresh', 'live catalogs', 4),
            'links': (0, 0, 'magnifier', 'Fix dead links', 'tool, installer URLs', 5),
            'verify': (0, 0, 'check', 'Check files', 'sizes, re-fetch short', 6),
            'fill': (0, 0, 'play', 'Top up', 'pins, then fill', 7),
            'tools': (0, 0, 'cube', 'Update apps', 'weekly', 0),
            'run': (0, 0, 'flask', 'Does it run?', 'tools, LLM, API, UI', 1),
            'mod': (0, 0, 'shield', 'Safety sweep', 'new uploads', 2),
            'report': (0, 0, 'eye', 'Report', 'Health page, events', 3),
        },
        centre=('gear', 'loop.sh', 'every 30 min'),
        used=['docs/ARCHITECTURE.md', 'docs/design/errors-selfheal.md']),
    'request': dict(
        title='What happens when you tap Request',
        sub='From one tap on any device to a file on the disk, with live progress on the way.',
        h=500,
        zones=[(28, 104, 230, 372, 'You'), (286, 104, 420, 372, 'The web server'),
               (734, 104, 438, 372, 'The Librarian')],
        nodes={
            'tap': (143, 200, 'play', 'Tap Request', 'web UI, any device', 0),
            'activity': (143, 400, 'eye', 'Activity page', 'live progress', 1),
            'gate': (390, 200, 'shield', 'Gates', 'LAN or tailnet, limit', 2),
            'mode': (600, 200, 'lock', 'Use Mode', 'Open, or signed in', 3),
            'job': (495, 400, 'gear', 'Job', 'runs in the background', 4),
            'pin': (845, 200, 'key', 'Pin it', 'never evicted', 5),
            'room': (1060, 200, 'wrench', 'Make room', 'only if it won\'t fit', 6),
            'dl': (1060, 400, 'disk', 'Download', 'resumable, checked', 7),
            'lib': (845, 400, 'book', 'In the library', 'loop keeps it filled', 0),
        },
        edges=[('tap', 'gate', '', 0), ('gate', 'mode', '', 0), ('mode', 'job', 'checked id', 0),
               ('job', 'pin', 'request', 0), ('pin', 'room', '', 0), ('room', 'dl', '', 0),
               ('dl', 'lib', '', 0), ('job', 'activity', 'progress', 0)],
        used=['docs/ARCHITECTURE.md', 'docs/design/downloads-monitoring.md']),
    'access': dict(
        title='Who can do what',
        sub='The box is always the Admin; the LAN gets what the Use Mode allows; the internet gets no library.',
        h=540,
        zones=[(28, 104, 300, 412, 'Who is asking'), (356, 104, 420, 412, 'The gate'),
               (804, 104, 368, 412, 'What they can do')],
        nodes={
            'box': (178, 190, 'house', 'The box itself', 'localhost, console', 0),
            'lan': (178, 330, 'wifi', 'Your network', 'LAN and tailnet', 1),
            'net': (178, 460, 'globe', 'The internet', 'everyone else', 2),
            'admin': (566, 190, 'key', 'Admin', 'box, or passcode', 3),
            'mode': (566, 330, 'lock', 'Use Mode', 'Open, or sign in', 4),
            'block': (566, 460, 'shield', 'Refused', 'no reads, no changes', 5),
            'set': (988, 190, 'gear', 'Settings, repair', 'moderation, accounts', 6),
            'use': (988, 330, 'book', 'Browse, request', 'library, downloads', 7),
        },
        edges=[('box', 'admin', 'always', 0), ('lan', 'admin', 'passcode', 0), ('lan', 'mode', '', 0),
               ('net', 'block', '', 0), ('admin', 'set', '', 0), ('admin', 'use', '', 0),
               ('mode', 'use', 'Open: anyone here', 0)],
        used=['docs/design/access-identity.md', 'docs/SERVING.md']),
    'fleet': dict(
        title='One Ark, many machines',
        sub='Share one Ark across the LAN, or set up new ones from it, without the internet.',
        h=600,
        zones=[(28, 104, 330, 470, 'The Ark'), (386, 104, 786, 470, 'Over the local network')],
        nodes={
            'ark': (193, 245, 'ark', 'The Ark', 'one data disk', 0),
            'src': (193, 455, 'terminal', 'Its own source', 'bundle, bootstrap.sh', 1),
            'peer': (700, 180, 'wifi', 'Syncthing peer', 'syncs models, content', 2),
            'mesh': (700, 290, 'chip', 'GPU node', 'runs models over NFS', 3),
            'laptop': (700, 400, 'paste', 'Any laptop', 'static pages, a share', 4),
            'new': (700, 510, 'cube', 'New machine', 'curl bootstrap.sh', 5),
            'ark2': (1040, 510, 'ark', 'Another Ark', 'fills when online', 6),
        },
        edges=[('ark', 'src', 'copies itself', 0), ('ark', 'peer', 'P2P sync', 0), ('ark', 'mesh', 'NFS export', 0),
               ('ark', 'laptop', 'file share', 0), ('src', 'new', 'installs offline', 0), ('new', 'ark2', '', 0)],
        used=['docs/OFFLINE.md', 'docs/ARCHITECTURE.md']),
    'community': dict(
        title='The village square',
        sub='Chat, mail, boards and file drops run on the box and open inside the web UI.',
        h=500,
        zones=[(28, 104, 250, 372, 'You turn it on'), (306, 104, 584, 372, 'The Ark'),
               (918, 104, 254, 372, 'People nearby')],
        nodes={
            'env': (153, 200, 'key', 'Enable in .env', 'VALARK_SERVICES', 0),
            'start': (153, 400, 'play', 'Start button', 'Community page', 1),
            'loop': (410, 200, 'gear', 'Loop', 'starts, keeps them up', 2),
            'svc': (600, 310, 'server', 'Services', 'web UIs on 127.0.0.1', 3),
            'acct': (790, 420, 'lock', 'Mail logins', 'added by the Admin', 4),
            'proxy': (790, 200, 'globe', 'Web server', 'proxies /app/<id>/', 5),
            'chat': (1045, 200, 'chat', 'Chat, mail', 'IRC and webmail', 6),
            'board': (1045, 420, 'board', 'Boards, files', 'forum and pastes', 7),
        },
        edges=[('env', 'loop', '', 0), ('env', 'start', 'enables', 0), ('start', 'svc', '', 0), ('loop', 'svc', '', 0),
               ('acct', 'svc', '', 0), ('svc', 'proxy', '', 0),
               ('proxy', 'chat', '', 0), ('proxy', 'board', '', 0)],
        used=['docs/COMMUNITY.md']),
    'moderation': dict(
        title='Keeping shared files safe',
        sub='Files in the uploads folder are checked on the box by a local model. Doubtful ones wait for the Admin.',
        h=500,
        zones=[(28, 104, 250, 372, 'Shared'), (286, 104, 650, 372, 'On the box, every loop'),
               (964, 104, 208, 372, 'The Admin')],
        nodes={
            'up': (143, 200, 'paste', 'Uploads folder', 'VAL_ARK_UPLOADS', 0),
            'shared': (143, 400, 'check', 'Stays shared', 'nothing found', 1),
            'sweep': (390, 200, 'magnifier', 'Sweep', 'new files only', 2),
            'model': (610, 200, 'chip', 'Local model', 'text and images', 3),
            'hold': (830, 200, 'shield', 'Fail closed', 'error means hold', 4),
            'quar': (610, 400, 'lock', 'Quarantine', 'moved aside', 5),
            'review': (1068, 300, 'eye', 'Review', 'remove or dismiss', 6),
        },
        edges=[('up', 'sweep', '', 0), ('sweep', 'model', '', 0), ('model', 'hold', '', 0),
               ('hold', 'quar', 'flagged or unsure', 0), ('model', 'shared', 'clean', 0),
               ('quar', 'review', '', 0)],
        used=['docs/design/safety-moderation.md']),
    'setup': dict(
        title='Setting up a new box',
        sub='A few screens in a browser. Then the 24/7 loop fills the disk on its own.',
        h=470,
        zones=[(28, 104, 1144, 340, 'The setup wizard, in order')],
        nodes={
            'welcome': (143, 200, 'house', 'Welcome', 'in any browser', 0),
            'claim': (363, 200, 'key', 'Claim code', 'from another device', 1),
            'name': (583, 200, 'board', 'Name it', 'a name for the box', 2),
            'pass': (803, 200, 'lock', 'Admin passcode', 'optional', 3),
            'focus': (1023, 200, 'leaf', 'Focus', 'survival, AI, tools…', 4),
            'card': (803, 360, 'paste', 'Recovery card', 'print or save it', 5),
            'fill': (583, 360, 'disk', 'Filling', 'by the 24/7 loop', 6),
            'open': (363, 360, 'globe', 'Open mode', 'change it later', 7),
        },
        edges=[('welcome', 'claim', '', 0), ('claim', 'name', '', 0), ('name', 'pass', '', 0),
               ('pass', 'focus', '', 0), ('focus', 'card', '', 'elbow'), ('card', 'fill', '', 0), ('fill', 'open', '', 0)],
        used=['docs/design/commissioning.md']),
    'serving': dict(
        title='Two ways to open an Ark',
        sub='Static pages on any file share, or the live web server. Both work fully offline.',
        h=470,
        zones=[(28, 104, 250, 340, 'One disk'), (306, 104, 584, 340, 'Two ways'),
               (918, 104, 254, 340, 'Readers')],
        nodes={
            'disk': (153, 280, 'server', 'Data disk', 'everything mirrored', 0),
            'site': (410, 200, 'paste', 'librarian site', 'writes plain pages', 1),
            'share': (790, 200, 'wifi', 'File share', 'SMB, NFS, USB', 2),
            'srv': (410, 360, 'globe', 'server.js', 'live web UI', 3),
            'live': (790, 360, 'chat', 'Live features', 'requests, chat, mail', 4),
            'lap': (1045, 200, 'book', 'Any device', 'read-only catalog', 5),
            'ppl': (1045, 360, 'house', 'Your LAN', 'the full web UI', 6),
        },
        edges=[('disk', 'site', '', 0), ('site', 'share', 'static', 0), ('share', 'lap', '', 0),
               ('disk', 'srv', '', 0), ('srv', 'live', 'dynamic', 0), ('live', 'ppl', '', 0)],
        used=['docs/SERVING.md']),
}


def edge_path(a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    d = math.hypot(dx, dy) or 1
    ux, uy = dx / d, dy / d
    # leave and enter at the card's edge (a rectangle), not its centre
    def clip(ux, uy):
        tx = (NW / 2 + 6) / abs(ux) if ux else 1e9
        ty = (NH / 2 + 6) / abs(uy) if uy else 1e9
        return min(tx, ty)
    c = clip(ux, uy)   # every card is the same size, so both ends clip alike
    sx, sy = ax + ux * c, ay + uy * c
    ex, ey = bx - ux * c, by - uy * c
    mx, my = (sx + ex) / 2, (sy + ey) / 2
    return f'M{sx:.1f} {sy:.1f}Q{mx:.1f} {my:.1f} {ex:.1f} {ey:.1f}', (mx, my), (ex, ey, ex - mx, ey - my)


def elbow_path(a, b):
    """Down out of a, across the gap between rows, down into b (for snaking rows)."""
    (ax, ay), (bx, by) = a, b
    assert abs(ax - bx) > 20, 'elbow needs the cards apart horizontally'
    sy, ey = ay + NH / 2 + 6, by - NH / 2 - 6
    my = (sy + ey) / 2
    r = 10 if bx < ax else -10
    d = (f'M{ax:.1f} {sy:.1f}V{my - 10:.1f}Q{ax:.1f} {my:.1f} {ax - r:.1f} {my:.1f}'
         f'H{bx + r:.1f}Q{bx:.1f} {my:.1f} {bx:.1f} {my + 10:.1f}V{ey:.1f}')
    return d, ((ax + bx) / 2, my), (bx, ey, 0, 1)


def css(t):
    return f"""
.s{{fill:none;stroke:var(--a);stroke-width:2.6;stroke-linecap:round;stroke-linejoin:round}}
.t{{stroke-width:2}}.w{{stroke-width:6}}.f{{fill:var(--a)}}
.lb{{font:600 15px system-ui,-apple-system,'Segoe UI',sans-serif;fill:{t['ink']};text-anchor:middle}}
.cp{{font:12px system-ui,sans-serif;fill:{t['muted']};text-anchor:middle}}
.el{{font:italic 12px system-ui,sans-serif;fill:{t['muted']};stroke:{t['page']};stroke-width:4px;paint-order:stroke;stroke-linejoin:round}}
.zt{{font:700 11px system-ui,sans-serif;letter-spacing:.18em;fill:{t['muted']};text-transform:uppercase}}
.ch{{font:700 12px system-ui,sans-serif;letter-spacing:.22em;fill:{t['tab']};text-transform:uppercase}}
.tt{{font:italic 600 30px Georgia,'Times New Roman',serif;fill:{t['ink']}}}
.st{{font:16px system-ui,sans-serif;fill:{t['muted']}}}
.nd{{transform-box:fill-box;transform-origin:50% 50%;animation:pop .6s cubic-bezier(.3,1.4,.5,1) both}}
.ar{{fill:none;stroke:{t['muted']};stroke-width:2;opacity:.75;stroke-dasharray:1;animation:draw .8s ease-out both}}
.ah{{fill:{t['muted']};opacity:.75;animation:fade .4s ease-out both}}
.dot{{fill:{t['tab']};stroke:{t['page']};stroke-width:1.5px;animation:run 3.2s linear infinite both}}
.pl{{fill:none;stroke:{t['tab']};stroke-width:3;opacity:0;animation:pulse 8s ease-in-out infinite}}
.spin{{transform-box:fill-box;transform-origin:50% 50%;animation:spin 8s linear infinite}}
@keyframes pop{{from{{transform:scale(.2);opacity:0}}to{{transform:none;opacity:1}}}}
@keyframes draw{{from{{stroke-dashoffset:1}}to{{stroke-dashoffset:0}}}}
@keyframes fade{{from{{opacity:0}}}}
@keyframes run{{0%{{offset-distance:0%;opacity:0}}8%,88%{{opacity:1}}100%{{offset-distance:100%;opacity:0}}}}
@keyframes pulse{{0%,14%,100%{{opacity:0}}4%,9%{{opacity:.95}}}}
@keyframes spin{{to{{transform:rotate(360deg)}}}}
@media (prefers-reduced-motion:reduce){{*{{animation:none!important}}.dot{{display:none}}}}
@supports not (offset-path:path('M0 0')){{.dot{{display:none}}}}
"""


def node_svg(x, y, icon, label, caption, acc, t, delay):
    x0, y0 = x - NW / 2, y - NH / 2
    return (f'<g class="nd" style="animation-delay:{delay:.2f}s">'
            f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{NW}" height="{NH}" rx="12" fill="{t["card"]}" '
            f'stroke="{t["cardline"]}" stroke-width="1.5"/>'
            f'<rect x="{x0:.1f}" y="{y0:.1f}" width="6" height="{NH}" rx="3" fill="{acc}"/>'
            f'<g transform="translate({x:.1f} {y0 + 28:.1f}) scale(.72)" style="--a:{acc}">{ICONS[icon]}</g>'
            f'<text x="{x:.1f}" y="{y0 + 63:.1f}" class="lb">{esc(label)}</text>'
            f'<text x="{x:.1f}" y="{y0 + 80:.1f}" class="cp">{esc(caption)}</text></g>')


def render(did, spec, theme):
    t = THEMES[theme]
    h = spec['h']
    labels = [n[3] for n in spec['nodes'].values()]
    title = f"Val Ark: {spec['title']}"
    desc = f"Animated diagram: {spec['title']}. Parts: {', '.join(labels)}. {spec['sub']}"
    p = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {h}" width="{W}" height="{h}" role="img" '
         f'aria-label="{esc(title)}"><title>{esc(title)}</title><desc>{esc(desc)}</desc>',
         f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{t["bg0"]}"/>'
         f'<stop offset="1" stop-color="{t["bg1"]}"/></linearGradient></defs><style>{css(t)}</style>',
         f'<rect width="{W}" height="{h}" rx="18" fill="url(#bg)"/>',
         f'<text x="64" y="44" class="ch">How it works</text><text x="64" y="80" class="tt">{esc(spec["title"])}</text>'
         f'<text x="{W - 64}" y="44" class="st" text-anchor="end">{esc(spec["sub"])}</text>']
    nodes = dict(spec['nodes'])
    if 'ring' in spec:
        cx, cy, rx, r = spec['ring']
        n = len(nodes)
        for i, k in enumerate(list(nodes)):
            a = -math.pi / 2 + i * 2 * math.pi / n
            _, _, *rest = nodes[k]
            nodes[k] = (cx + rx * math.cos(a), cy + r * math.sin(a), *rest)
        p.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{rx:.0f}" ry="{r}" fill="none" stroke="{t["edge"]}" '
                 f'stroke-width="10" opacity=".7"/>')
        # arc length to each step, so a step pulses when the dots (constant speed) reach it
        steps = 2000
        pts = [(rx * math.cos(-math.pi / 2 + 2 * math.pi * k / steps), r * math.sin(-math.pi / 2 + 2 * math.pi * k / steps))
               for k in range(steps + 1)]
        cum = [0.0]
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            cum.append(cum[-1] + math.hypot(x1 - x0, y1 - y0))
        frac = [cum[round(steps * i / n)] / cum[-1] for i in range(n)]
        ring = f'M{cx} {cy - r}A{rx:.0f} {r} 0 1 1 {cx - .1} {cy - r}'
        ci, cl, cc = spec['centre']
        p.append(f'<g class="spin" style="--a:{t["tab"]}"><g transform="translate({cx} {cy - 14}) scale(1.6)">'
                 f'{ICONS[ci]}</g></g>'
                 f'<text x="{cx}" y="{cy + 34}" class="lb">{esc(cl)}</text><text x="{cx}" y="{cy + 52}" class="cp">{esc(cc)}</text>')
        for i, (k, (x, y, icon, label, cap, ai)) in enumerate(nodes.items()):
            acc = ACCENTS[ai % len(ACCENTS)]
            p.append(node_svg(x, y, icon, label, cap, acc, t, 0.2 + i * 0.12))
            # pulse each step as the dots pass it
            p.append(f'<rect x="{x - NW/2 - 5:.1f}" y="{y - NH/2 - 5:.1f}" width="{NW + 10}" height="{NH + 10}" rx="15" '
                     f'class="pl" style="animation-delay:{frac[i] * 8 - .45:.2f}s"/>')
        # chevrons (drawn over the cards) halfway between steps show the direction (clockwise) even with motion off
        for i in range(n):
            a = -math.pi / 2 + (i + .5) * 2 * math.pi / n
            px, py = cx + rx * math.cos(a), cy + r * math.sin(a)
            ang = math.degrees(math.atan2(r * math.cos(a), -rx * math.sin(a)))
            p.append(f'<path d="M-5-6 3 0-5 6" fill="none" stroke="{t["tab"]}" stroke-width="3" stroke-linecap="round" '
                     f'stroke-linejoin="round" transform="translate({px:.1f} {py:.1f}) rotate({ang:.1f})"/>')
        # the travelling dots ride on top of the cards, so they stay visible all the way round
        for k in range(3):
            p.append(f'<circle r="6" class="dot" style="offset-path:path(\'{ring}\');animation-duration:8s;'
                     f'animation-delay:{-k * 8 / 3:.2f}s"/>')
    else:
        labels = []
        for (x, y, w, zh, ztitle) in spec['zones']:
            p.append(f'<rect x="{x}" y="{y}" width="{w}" height="{zh}" rx="14" fill="{t["page"]}" stroke="{t["edge"]}" '
                     f'stroke-dasharray="6 6"/><text x="{x + 16}" y="{y + 24}" class="zt">{esc(ztitle)}</text>')
        for i, (a, b, label, kind) in enumerate(spec['edges']):
            if kind == 'elbow':
                d, (mx, my), (ex, ey, vx, vy) = elbow_path(nodes[a][:2], nodes[b][:2])
            else:
                d, (mx, my), (ex, ey, vx, vy) = edge_path(nodes[a][:2], nodes[b][:2])
            delay = 0.9 + i * 0.12
            ang = math.degrees(math.atan2(vy, vx))
            p.append(f'<path d="{d}" pathLength="1" class="ar" style="animation-delay:{delay:.2f}s"/>'
                     f'<path d="M0 0l-10-5v10z" class="ah" transform="translate({ex:.1f} {ey:.1f}) rotate({ang:.1f})" '
                     f'style="animation-delay:{delay + .5:.2f}s"/>')
            for k in range(2):
                p.append(f'<circle r="4.5" class="dot" style="offset-path:path(\'{d}\');'
                         f'animation-delay:{delay + 1 + k * 1.6 + i * 0.37:.2f}s"/>')
            if label:
                # steep arrows get the label beside them, flat ones above; drawn last, with a halo
                if abs(vy) > abs(vx) * 0.6:
                    labels.append(f'<text x="{mx + 10:.1f}" y="{my + 4:.1f}" class="el" text-anchor="start">{esc(label)}</text>')
                else:
                    labels.append(f'<text x="{mx:.1f}" y="{my - 11:.1f}" class="el" text-anchor="middle">{esc(label)}</text>')
        for i, (x, y, icon, label, cap, ai) in enumerate(nodes.values()):
            p.append(node_svg(x, y, icon, label, cap, ACCENTS[ai % len(ACCENTS)], t, 0.2 + i * 0.08))
        p.extend(labels)
    p.append('</svg>\n')
    return ''.join(p)


def build():
    return {f'{d}-{th}.svg': render(d, s, th) for d, s in DIAGRAMS.items() for th in THEMES}


def main(argv):
    files = build()
    if '--list' in argv:
        for d, s in DIAGRAMS.items():
            print(f"{d}\t{', '.join(s['used'])}")
        return 0
    if '--check' in argv:
        bad = [n for n, body in files.items() if not (OUT / n).is_file() or (OUT / n).read_bytes() != body.encode()]
        extra = sorted(p.name for p in OUT.glob('*.svg') if p.name not in files) if OUT.is_dir() else []
        for n in bad:
            print(f'stale or missing: docs/img/flow/{n}')
        for n in extra:
            print(f'not produced by the generator: docs/img/flow/{n}')
        unused = [(d, md) for d, spec in DIAGRAMS.items() for md in spec['used']
                  if f'flow/{d}-light.svg' not in ((ROOT / md).read_text(errors='replace') if (ROOT / md).is_file() else '')]
        for d, md in unused:
            print(f'{md} is listed in used= for {d} but does not embed it')
        if bad or extra:
            print('run: python3 scripts/docs/flow_art.py')
        if bad or extra or unused:
            return 1
        print(f'ok: {len(files)} flow SVGs match the generator')
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for n, body in files.items():
        (OUT / n).write_bytes(body.encode())
    print(f'wrote {len(files)} SVGs to docs/img/flow/')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
