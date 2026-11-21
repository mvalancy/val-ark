#!/usr/bin/env python3
"""Pop-up-book chapter art for the Val Ark docs (issue #251).

Every major guide opens with a small animated scene: paper cut-outs unfold up
from the spine of an open book, a pull-tab slides, connectors draw themselves,
a few sparkles twinkle, and then the page folds flat again before it loops.
One engine draws every scene, so the docs share one visual language.

    python3 scripts/docs/popup_art.py          # (re)write docs/img/popup/*.svg
    python3 scripts/docs/popup_art.py --check  # exit 1 if any committed SVG is stale
    python3 scripts/docs/popup_art.py --list   # scene ids + where each is used

Design rules (enforced by tests/test-doc-art.sh):
  * stdlib only, deterministic output (seeded per scene) so --check is exact;
  * pure SVG + CSS: no <script>, no external href, no web fonts;
  * the *resting* state is the fully opened scene, and animations only start
    from "folded", so prefers-reduced-motion simply switches animation off;
  * every file carries <title>, <desc> and role="img".
"""
import math
import pathlib
import random
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs' / 'img' / 'popup'
W, H = 1200, 320
BASE = 272          # where the cut-outs stand on the page
CYCLE = 14.0        # seconds per unfold -> hold -> fold loop

THEMES = {
    'dark': dict(bg0='#111a24', bg1='#0d1117', page='#1f2a37', page2='#1a2430', edge='#2f3e50',
                 ink='#e6edf3', muted='#9aa7b4', card='#18212c', cardline='#3a4a5e',
                 hill1='#15202c', hill2='#192634', shadow='#000000', shadowop='.45',
                 star='#fde68a', tab='#f59e0b', tabink='#1b1206'),
    'light': dict(bg0='#fdf8ef', bg1='#f5ecdb', page='#fffdf8', page2='#f8f1e4', edge='#dccdb4',
                  ink='#1f2328', muted='#59636e', card='#ffffff', cardline='#d9c9ae',
                  hill1='#f0e4cf', hill2='#e8d8bd', shadow='#5a4320', shadowop='.18',
                  star='#d97706', tab='#f59e0b', tabink='#2a1a04'),
}
ACCENTS = ['#f97316', '#22c55e', '#3b82f6', '#a855f7', '#ef4444', '#14b8a6', '#eab308', '#ec4899']

# ---------------------------------------------------------------- icons
# Each icon draws in a 48x48 box centred on (0,0); A = accent colour.
def _gear():
    pts = []
    for i in range(16):
        a = i * math.pi / 8
        r = 17 if i % 2 == 0 else 12
        for da in (-0.17, 0.17):
            pts.append(f'{r*math.cos(a+da):.1f},{r*math.sin(a+da):.1f}')
    return f'<polygon points="{" ".join(pts)}" class="s"/><circle r="5" class="f"/>'

ICONS = {
    'gear': _gear(),
    'disk': '<path d="M-16-11v22a16 5 0 0 0 32 0v-22" class="s"/><ellipse cy="-11" rx="16" ry="5" class="s"/>'
            '<path d="M-16 0a16 5 0 0 0 32 0" class="s"/><circle cx="10" cy="8" r="2" class="f"/>',
    'book': '<path d="M0-11C-6-15-14-15-20-13v25c6-2 14-2 20 2zM0-11C6-15 14-15 20-13v25c-6-2-14-2-20 2z" class="s"/>'
            '<path d="M-15-7h9M-15-2h9M6-7h9" class="s t"/>',
    'chip': '<rect x="-12" y="-12" width="24" height="24" rx="3" class="s"/><rect x="-5" y="-5" width="10" height="10" class="f"/>'
            '<path d="M-7-12v-6M0-12v-6M7-12v-6M-7 12v6M0 12v6M7 12v6M-12-7h-6M-12 0h-6M-12 7h-6M12-7h6M12 0h6M12 7h6" class="s t"/>',
    'chat': '<path d="M-18-14h36v22h-20l-9 8v-8h-7z" class="s"/><circle cx="-8" cy="-3" r="2" class="f"/>'
            '<circle cy="-3" r="2" class="f"/><circle cx="8" cy="-3" r="2" class="f"/>',
    'mail': '<rect x="-18" y="-12" width="36" height="24" rx="3" class="s"/><path d="M-18-10 0 3l18-13" class="s"/>',
    'board': '<rect x="-18" y="-15" width="36" height="30" rx="3" class="s"/><path d="M-12-7h24M-12 0h18M-12 7h12" class="s t"/>'
             '<circle cx="13" cy="7" r="3" class="f"/>',
    'paste': '<rect x="-14" y="-13" width="28" height="31" rx="3" class="s"/><rect x="-7" y="-18" width="14" height="8" rx="2" class="f"/>'
             '<path d="M-8-1h16M-8 6h16M-8 13h9" class="s t"/>',
    'lock': '<rect x="-14" y="-3" width="28" height="21" rx="4" class="s"/><path d="M-8-3v-6a8 8 0 0 1 16 0v6" class="s"/>'
            '<circle cy="6" r="3" class="f"/><path d="M0 8v5" class="s"/>',
    'key': '<circle cx="-9" cy="0" r="8" class="s"/><circle cx="-9" cy="0" r="2.5" class="f"/><path d="M-1 0h20M13 0v6M18 0v5" class="s"/>',
    'shield': '<path d="M0-18 15-12V0c0 10-7 16-15 19-8-3-15-9-15-19v-12z" class="s"/><path d="m-6 1 4 5 9-10" class="s"/>',
    'wifi': '<path d="M-19-5a27 27 0 0 1 38 0M-12 3a17 17 0 0 1 24 0M-5 10a7 7 0 0 1 10 0" class="s"/><circle cy="15" r="2.5" class="f"/>',
    'house': '<path d="M-17-1 0-16 17-1M-12-5v20h24V-5" class="s"/><rect x="-4" y="5" width="8" height="10" class="f"/>',
    'cloud': '<path d="M-12 11h24a8 8 0 0 0 0-16 11 11 0 0 0-21-3 8 8 0 0 0-3 19z" class="s"/>',
    'terminal': '<rect x="-19" y="-14" width="38" height="28" rx="4" class="s"/><path d="m-11-5 6 5-6 5M0 6h10" class="s"/>',
    'wrench': '<path d="M-4-4 13 13" class="s w"/><circle cx="-9" cy="-9" r="8" class="s"/><path d="m-13-13 5 5" class="s"/>',
    'cube': '<path d="M0-17 15-9v17L0 17l-15-9V-9z" class="s"/><path d="M-15-9 0-1 15-9M0-1v18" class="s"/>',
    'brain': '<path d="M-14-8 0-14 14-8M-14-8-2 4 14-8M-2 4-12 12M-2 4 12 12M0-14-2 4" class="s t"/>'
             '<circle cx="-14" cy="-8" r="4" class="f"/><circle cy="-14" r="4" class="f"/><circle cx="14" cy="-8" r="4" class="f"/>'
             '<circle cx="-2" cy="4" r="4" class="f"/><circle cx="-12" cy="12" r="3.5" class="f"/><circle cx="12" cy="12" r="3.5" class="f"/>',
    'check': '<circle r="16" class="s"/><path d="m-7 0 5 6 10-11" class="s"/>',
    'server': '<rect x="-17" y="-16" width="34" height="13" rx="3" class="s"/><rect x="-17" y="2" width="34" height="13" rx="3" class="s"/>'
              '<circle cx="-10" cy="-9.5" r="2" class="f"/><circle cx="-10" cy="8.5" r="2" class="f"/><path d="M0-9.5h10M0 8.5h10" class="s t"/>',
    'globe': '<circle r="16" class="s"/><ellipse rx="7" ry="16" class="s"/><path d="M-16 0h32M-13-9h26M-13 9h26" class="s t"/>',
    'leaf': '<path d="M-14 14C-14-6-2-15 15-15c0 17-9 29-29 29zM-14 14 6-6" class="s"/>',
    'magnifier': '<circle cx="-4" cy="-4" r="11" class="s"/><path d="m4 4 11 11" class="s w"/>',
    'play': '<rect x="-19" y="-14" width="38" height="28" rx="5" class="s"/><path d="M-5-7v14l11-7z" class="f"/>',
    'flask': '<path d="M-6-16h12M-4-16v10l-12 20h32L4-6v-10" class="s"/><path d="M-10 6h20" class="s t"/><circle cx="2" cy="10" r="2.5" class="f"/>',
    'map': '<path d="m-19-11 12-5 14 5 12-5v27l-12 5-14-5-12 5z" class="s"/><path d="M-7-16v27M7-11v27" class="s t"/>',
    'ark': '<path d="M-20 4h40l-7 11h-26z" class="s"/><path d="M0 4v-21M0-17l13 17H0" class="s"/><path d="M-22 18c4-3 8-3 11 0s8 3 11 0 8-3 11 0 7 3 11 0" class="s t"/>',
    'eye': '<path d="M-19 0C-12-11 12-11 19 0 12 11-12 11-19 0z" class="s"/><circle r="5" class="f"/>',
    'spark': '<path d="M0-16 4-4 16 0 4 4 0 16-4 4-16 0-4-4z" class="f"/>',
    'tree': '<path d="M0-18 14 6H-14zM0 6v12" class="s"/>',
    'mic': '<rect x="-6" y="-17" width="12" height="22" rx="6" class="s"/><path d="M-12 0a12 12 0 0 0 24 0M0 12v6" class="s"/>',
}

# ---------------------------------------------------------------- scenes
# card = (icon, label, badge-or-None).  links = (from, to, kind) with kind 'side' | 'arc'.
SCENES = {
    'docs-map': dict(chapter='The Map', title='Every page of the Ark',
        sub='Start here, then follow the paths to any guide.', backdrop='hills',
        cards=[('book', 'Start here', None), ('gear', 'Architecture', None), ('disk', 'Librarian', None),
               ('map', 'Design', None), ('brain', 'Knowledge', None), ('flask', 'Tests', None)],
        links=[(0, 1, 'arc'), (0, 2, 'arc'), (0, 3, 'arc'), (0, 4, 'arc'), (0, 5, 'arc')],
        used=['docs/README.md']),
    'architecture': dict(chapter='Chapter 1', title='How the Ark is built',
        sub='One config, two entry points, a librarian and a zero-dependency web server.', backdrop='city',
        cards=[('key', '.env', None), ('terminal', 'start.sh', None), ('gear', 'loop.sh', None),
               ('disk', 'Librarian', None), ('server', 'server.js', None), ('globe', 'Web UI', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side'), (4, 5, 'side')],
        used=['docs/ARCHITECTURE.md', 'README.md']),
    'librarian': dict(chapter='Chapter 2', title='The Librarian fills the shelves',
        sub='Diversity first, then small and valuable, then fill, then trade up.', backdrop='shelf',
        cards=[('cube', 'Diversity', '1'), ('leaf', 'Small + valuable', '2'), ('disk', 'Fill the rest', '3'),
               ('magnifier', 'Evict for better', '4')],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side')],
        used=['docs/LIBRARIAN.md', 'README.md']),
    'tools': dict(chapter='Chapter 3', title='A toolbox for every job',
        sub='Dev tools, AI runtimes, creative suites and media, mirrored for each platform.', backdrop='hills',
        cards=[('terminal', 'Dev tools', None), ('brain', 'AI inference', None), ('cube', 'Creative', None),
               ('play', 'Media', None), ('gear', 'Infrastructure', None), ('wrench', 'Build kits', None)],
        links=[], used=['docs/TOOLS.md']),
    'models': dict(chapter='Chapter 4', title='A menagerie of models',
        sub='Flagship LLM, speech, vision and image models, plus small diversity picks.', backdrop='hills',
        cards=[('brain', 'Language', None), ('eye', 'Vision', None), ('mic', 'Speech', None),
               ('play', 'Image + video', None), ('cube', 'Embeddings', None)],
        links=[(0, 1, 'arc'), (1, 2, 'arc'), (2, 3, 'arc'), (3, 4, 'arc')],
        used=['docs/MODEL_INVENTORY.md']),
    'platforms': dict(chapter='Chapter 5', title='Every kind of machine',
        sub='One mirror serves x86_64, arm64, Jetson, macOS, Windows and OpenWRT.', backdrop='city',
        cards=[('chip', 'x86_64', None), ('chip', 'arm64', None), ('brain', 'Jetson', None),
               ('cube', 'macOS', None), ('globe', 'Windows', None), ('wifi', 'OpenWRT', None)],
        links=[], used=['docs/PLATFORMS.md', 'README.md']),
    'community': dict(chapter='Chapter 6', title='The village square',
        sub='Chat, mail, message boards, pastes and shared files: no internet needed.', backdrop='village',
        cards=[('chat', 'Chat', None), ('mail', 'Mail', None), ('board', 'Forum', None),
               ('paste', 'Paste', None), ('disk', 'Shared files', None)],
        links=[(0, 1, 'arc'), (1, 2, 'arc'), (2, 3, 'arc'), (3, 4, 'arc')],
        used=['docs/COMMUNITY.md', 'README.md']),
    'offline': dict(chapter='Chapter 7', title='Off the grid, together',
        sub='Pull everything once, then share it across the LAN with no internet.', backdrop='waves',
        cards=[('house', 'Home', None), ('house', 'Workshop', None), ('ark', 'The Ark', None),
               ('house', 'School', None), ('house', 'Clinic', None)],
        links=[(2, 0, 'arc'), (2, 1, 'arc'), (2, 3, 'arc'), (2, 4, 'arc')],
        used=['docs/OFFLINE.md', 'README.md']),
    'offline-gaps': dict(chapter='Field notes', title='Mapping the gaps',
        sub='What still needs the internet, and the plan to close each gap.', backdrop='hills',
        cards=[('map', 'Survey', None), ('magnifier', 'Find gaps', None), ('wrench', 'Close them', None),
               ('check', 'Verified', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side')],
        used=['docs/OFFLINE-GAPS.md']),
    'nas': dict(chapter='Appendix', title='The Ark on an arm64 NAS',
        sub='Off-the-shelf ARM64 boxes such as the RK3588: setup notes, gotchas, fixes.', backdrop='city',
        cards=[('server', 'NAS box', None), ('chip', 'RK3588', None), ('brain', 'NPU', None), ('wifi', 'LAN', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side')],
        used=['docs/ARM64-NAS.md']),
    'encryption': dict(chapter='Safekeeping', title='Encrypted on the LAN',
        sub='Its own tiny certificate authority: HTTPS for every device, no internet.', backdrop='vault',
        cards=[('key', 'Local CA', None), ('paste', 'Certificate', None), ('lock', 'HTTPS', None),
               ('wifi', 'Every device', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side')],
        used=['docs/ENCRYPTION.md']),
    'security': dict(chapter='Safekeeping', title='The security audit',
        sub='Every surface inspected, every finding tracked to a fix.', backdrop='vault',
        cards=[('magnifier', 'Inspect', None), ('shield', 'Harden', None), ('lock', 'Contain', None),
               ('check', 'Prove', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side')],
        used=['docs/SECURITY-AUDIT.md']),
    'design': dict(chapter='Blueprints', title='Designing an appliance',
        sub='Commissioning, access, storage, self-heal and recovery: scope first.', backdrop='hills',
        cards=[('map', 'Vision', None), ('key', 'Access', None), ('disk', 'Storage', None),
               ('gear', 'Self-heal', None), ('shield', 'Recovery', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side')],
        used=['docs/design/README.md']),
    'knowledge': dict(chapter='The shared brain', title='What we have learned',
        sub='Decisions, gotchas, workflow and governance, kept in git.', backdrop='shelf',
        cards=[('book', 'Decisions', None), ('magnifier', 'Gotchas', None), ('map', 'Workflow', None),
               ('shield', 'Governance', None)],
        links=[], used=['docs/knowledge/README.md']),
    'tests': dict(chapter='Proof', title='Proving it works',
        sub='Validators, browser tests and fresh-VM installs, in one offline report.', backdrop='hills',
        cards=[('terminal', 'Validators', None), ('globe', 'Playwright', None), ('server', 'Fresh VMs', None),
               ('check', 'Report', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side')],
        used=['tests/README.md', 'README.md']),
}

# ---------------------------------------------------------------- drawing
def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')

def layout(n):
    left, right = 180, 1040
    step = (right - left) / max(n - 1, 1)
    width = min(150, step * 0.74)
    return [(left + i * step if n > 1 else (left + right) / 2) for i in range(n)], width

def backdrop(kind, t, rnd):
    """Two paper layers behind the cut-outs; they pop first for depth."""
    layers = []
    if kind in ('hills', 'village', 'waves'):
        for li, (col, amp, base) in enumerate(((t['hill1'], 46, BASE - 64), (t['hill2'], 30, BASE - 30))):
            pts = [f'M110 {BASE}']
            x = 110
            while x < 1090:
                nx = min(1090, x + rnd.randint(90, 160))
                pts.append(f'Q{(x+nx)/2:.0f} {base - rnd.randint(amp//2, amp)} {nx} {base + rnd.randint(-6, 6)}')
                x = nx
            pts.append(f'L1090 {BASE}Z')
            layers.append(f'<path d="{" ".join(pts)}" fill="{col}"/>')
        if kind == 'village':
            roofs = ''.join(f'<path d="M{x} {BASE-34}l16-14 16 14v34h-32z" fill="{t["hill1"]}"/>'
                            for x in (150, 300, 860, 1010))
            layers[1] += roofs
        if kind == 'waves':
            waves = ''.join(f'<path d="M110 {y}' + ''.join(f'q25 -9 50 0t50 0' for _ in range(10)) + '" fill="none" '
                            f'stroke="{t["hill2"]}" stroke-width="4" stroke-linecap="round"/>' for y in (BASE - 8,))
            layers[1] += waves
    elif kind == 'city':
        for li, (col, hmin, hmax) in enumerate(((t['hill1'], 70, 130), (t['hill2'], 30, 70))):
            x, s = 110, ''
            while x < 1090:
                w = rnd.randint(40, 90)
                h = rnd.randint(hmin, hmax)
                s += f'<rect x="{x}" y="{BASE-h}" width="{min(w, 1090-x)}" height="{h}" rx="3" fill="{col}"/>'
                x += w + rnd.randint(4, 18)
            layers.append(s)
    elif kind == 'shelf':
        s0 = ''
        for y in (BASE - 118, BASE - 62):
            s0 += f'<rect x="120" y="{y}" width="960" height="7" rx="3" fill="{t["hill2"]}"/>'
            x = 130
            while x < 1060:
                w, h = rnd.randint(10, 22), rnd.randint(30, 50)
                s0 += f'<rect x="{x}" y="{y-h}" width="{w}" height="{h}" rx="2" fill="{t["hill1"]}"/>'
                x += w + rnd.randint(2, 30)
        layers = [s0, '']
    elif kind == 'vault':
        s0 = f'<rect x="130" y="{BASE-150}" width="940" height="150" rx="16" fill="{t["hill1"]}"/>'
        s0 += ''.join(f'<circle cx="{x}" cy="{BASE-75}" r="52" fill="none" stroke="{t["hill2"]}" stroke-width="10"/>'
                      for x in (240, 960))
        layers = [s0, '']
    return layers

def card(i, x, w, icon, label, badge, t, delay):
    h = 118
    top = BASE - h
    acc = ACCENTS[i % len(ACCENTS)]
    x0 = x - w / 2
    out = []
    # glued hinge flap + shadow stay on the page; the card itself pops up from the hinge
    out.append(f'<g class="sh" style="animation-delay:{delay:.2f}s"><ellipse cx="{x:.1f}" cy="{BASE+5}" rx="{w/2+6:.1f}" ry="7" '
               f'fill="{t["shadow"]}" opacity="{t["shadowop"]}"/></g>')
    out.append(f'<path d="M{x0+8:.1f} {BASE}h{w-16:.1f}l-8 9h{-(w-32):.1f}z" fill="{t["edge"]}"/>')
    body = [f'<rect x="{x0:.1f}" y="{top}" width="{w:.1f}" height="{h}" rx="12" fill="{t["card"]}" stroke="{t["cardline"]}" stroke-width="1.5"/>',
            f'<path d="M{x0:.1f} {top+12}a12 12 0 0 1 12-12h{w-24:.1f}a12 12 0 0 1 12 12v6h{-w:.1f}z" fill="{acc}"/>',
            f'<g transform="translate({x:.1f} {top+56})" style="--a:{acc}">{ICONS[icon]}</g>',
            f'<text x="{x:.1f}" y="{top+h-14}" class="lb">{esc(label)}</text>']
    if badge:
        body.append(f'<circle cx="{x0+w-14:.1f}" cy="{top+30}" r="11" fill="{acc}"/>'
                    f'<text x="{x0+w-14:.1f}" y="{top+35}" class="bd">{esc(badge)}</text>')
    sway = 4.2 + (i % 3) * 0.7
    out.append(f'<g class="pop" style="animation-delay:{delay:.2f}s"><g class="sw" style="animation-duration:{sway:.1f}s;'
               f'animation-delay:{-i*0.9:.1f}s">{"".join(body)}</g></g>')
    return ''.join(out), (x, top, w, h)

def link(a, b, kind, idx, delay):
    ax, at, aw, ah = a
    bx, bt, bw, bh = b
    if kind == 'side':
        sx, sy = (ax + aw / 2, at + ah / 2) if bx > ax else (ax - aw / 2, at + ah / 2)
        ex, ey = (bx - bw / 2, bt + bh / 2) if bx > ax else (bx + bw / 2, bt + bh / 2)
        mx = (sx + ex) / 2
        d = f'M{sx:.1f} {sy:.1f}C{mx:.1f} {sy-18:.1f} {mx:.1f} {ey-18:.1f} {ex:.1f} {ey:.1f}'
    else:
        lift = 26 + abs(bx - ax) * 0.06
        sx, sy, ex, ey = ax, at, bx, bt
        d = f'M{sx:.1f} {sy:.1f}C{sx:.1f} {sy-lift:.1f} {ex:.1f} {ey-lift:.1f} {ex:.1f} {ey:.1f}'
    return (f'<path d="{d}" pathLength="1" class="ln" style="animation-delay:{delay:.2f}s"/>'
            f'<path d="{d}" class="fl" style="animation-delay:0s,{delay:.2f}s"/>')

def render(sid, spec, theme):
    t = THEMES[theme]
    rnd = random.Random(sid)
    xs, w = layout(len(spec['cards']))
    title = f"Val Ark: {spec['title']}"
    desc = (f"Pop-up book scene for {spec['chapter']}: {spec['title']}. Paper cut-outs for "
            + ', '.join(c[1] for c in spec['cards'])
            + ' unfold from the spine of an open book, then fold flat and repeat. ' + spec['sub'])
    css = f"""
.s{{fill:none;stroke:var(--a);stroke-width:2.6;stroke-linecap:round;stroke-linejoin:round}}
.t{{stroke-width:2}}.w{{stroke-width:6}}.f{{fill:var(--a)}}
.lb{{font:600 15px system-ui,-apple-system,'Segoe UI',sans-serif;fill:{t['ink']};text-anchor:middle}}
.bd{{font:700 13px system-ui,sans-serif;fill:#fff;text-anchor:middle}}
.ch{{font:700 12px system-ui,sans-serif;letter-spacing:.22em;fill:{t['tab']};text-transform:uppercase}}
.tt{{font:italic 600 30px Georgia,'Times New Roman',serif;fill:{t['ink']}}}
.st{{font:15px system-ui,sans-serif;fill:{t['muted']}}}
.pop,.lay{{transform-box:fill-box;transform-origin:50% 100%;animation:pop {CYCLE}s cubic-bezier(.3,1.4,.5,1) infinite backwards}}
.sw{{transform-box:fill-box;transform-origin:50% 100%;animation:sway 4s ease-in-out infinite alternate}}
.sh{{transform-box:fill-box;transform-origin:50% 50%;animation:shade {CYCLE}s ease-out infinite backwards}}
.ln{{fill:none;stroke:{t['muted']};stroke-width:2;stroke-dasharray:1;opacity:.55;animation:draw {CYCLE}s ease-in-out infinite backwards}}
.fl{{fill:none;stroke:{t['tab']};stroke-width:3;stroke-linecap:round;stroke-dasharray:2 16;
     animation:flow 1.1s linear infinite,show {CYCLE}s linear infinite backwards}}
.tab{{animation:tab {CYCLE}s ease-in-out infinite}}
.tw{{transform-box:fill-box;transform-origin:50% 50%;animation:tw 2.8s ease-in-out infinite}}
@keyframes pop{{0%{{transform:scaleY(.02);opacity:0}}1%{{opacity:1}}5%{{transform:scaleY(1.08)}}7%{{transform:scaleY(.97)}}9%,86%{{transform:none;opacity:1}}
  91%,100%{{transform:scaleY(.02);opacity:0}}}}
@keyframes shade{{0%{{transform:scaleX(.2);opacity:0}}6%,86%{{transform:none;opacity:1}}91%,100%{{transform:scaleX(.2);opacity:0}}}}
@keyframes sway{{from{{transform:rotate(-.8deg)}}to{{transform:rotate(.8deg)}}}}
@keyframes draw{{0%{{stroke-dashoffset:1}}8%,70%{{stroke-dashoffset:0}}76%,100%{{stroke-dashoffset:1}}}}
@keyframes show{{0%,8%{{opacity:0}}12%,68%{{opacity:.9}}73%,100%{{opacity:0}}}}
@keyframes flow{{to{{stroke-dashoffset:-18}}}}
@keyframes tab{{0%,1%{{transform:none}}5%{{transform:translateX(-30px)}}10%,84%{{transform:none}}88%{{transform:translateX(-16px)}}92%,100%{{transform:none}}}}
@keyframes tw{{0%,100%{{transform:scale(.3);opacity:.2}}50%{{transform:scale(1);opacity:1}}}}
@media (prefers-reduced-motion:reduce){{*{{animation:none!important}}.fl{{opacity:0}}}}
"""
    p = []
    p.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
             f'aria-label="{esc(title)}"><title>{esc(title)}</title><desc>{esc(desc)}</desc>')
    p.append(f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{t["bg0"]}"/>'
             f'<stop offset="1" stop-color="{t["bg1"]}"/></linearGradient></defs><style>{css}</style>')
    p.append(f'<rect width="{W}" height="{H}" rx="18" fill="url(#bg)"/>')
    # chapter heading, like the top of a storybook page
    p.append(f'<text x="64" y="44" class="ch">{esc(spec["chapter"])}</text>'
             f'<text x="64" y="80" class="tt">{esc(spec["title"])}</text>'
             f'<text x="{W-64}" y="44" class="st" text-anchor="end">{esc(spec["sub"])}</text>')
    # the open book: two pages meeting at the spine, with stacked page edges
    p.append(f'<path d="M84 {BASE-4}Q340 {BASE-14} 600 {BASE-2}V{BASE+30}Q340 {BASE+18} 64 {BASE+34}z" fill="{t["page"]}"/>'
             f'<path d="M1116 {BASE-4}Q860 {BASE-14} 600 {BASE-2}V{BASE+30}Q860 {BASE+18} 1136 {BASE+34}z" fill="{t["page2"]}"/>'
             + ''.join(f'<path d="M{64-k*3} {BASE+34+k*3}Q340 {BASE+18+k*3} 600 {BASE+30+k*3}Q860 {BASE+18+k*3} {1136+k*3} {BASE+34+k*3}" '
                       f'fill="none" stroke="{t["edge"]}" stroke-width="1.5"/>' for k in (1, 2))
             + f'<path d="M600 {BASE-2}V{BASE+30}" stroke="{t["edge"]}" stroke-width="2"/>')
    for li, layer in enumerate(backdrop(spec['backdrop'], t, rnd)):
        if layer:
            p.append(f'<g class="lay" style="animation-delay:{0.15+li*0.25:.2f}s">{layer}</g>')
    boxes = []
    for i, (icon, label, badge) in enumerate(spec['cards']):
        svg, box = card(i, xs[i], w, icon, label, badge, t, 0.7 + i * 0.32)
        p.append(svg)
        boxes.append(box)
    ld = 0.7 + len(spec['cards']) * 0.32 + 0.3
    for k, (a, b, kind) in enumerate(spec['links']):
        p.append(link(boxes[a], boxes[b], kind, k, ld + k * 0.12))
    # sparkles
    for k in range(7):
        sx, sy = rnd.randint(90, 1110), rnd.randint(100, 150)
        sc = rnd.uniform(0.35, 0.6)
        p.append(f'<g transform="translate({sx} {sy}) scale({sc:.2f})"><g class="tw" style="animation-delay:{rnd.uniform(0, 2.8):.2f}s;--a:{t["star"]}">'
                 f'{ICONS["spark"]}</g></g>')
    # the pull-tab, sticking out of the right page
    p.append(f'<g class="tab"><rect x="1100" y="{BASE+6}" width="70" height="24" rx="6" fill="{t["tab"]}"/>'
             f'<text x="1135" y="{BASE+22}" font-family="system-ui,sans-serif" font-size="11" font-weight="700" '
             f'letter-spacing=".18em" text-anchor="middle" fill="{t["tabink"]}">PULL</text></g>')
    p.append('</svg>\n')
    return ''.join(p)

def build():
    return {f'{sid}-{theme}.svg': render(sid, spec, theme) for sid, spec in SCENES.items() for theme in THEMES}

def main(argv):
    files = build()
    if '--list' in argv:
        for sid, spec in SCENES.items():
            print(f"{sid}\t{', '.join(spec['used'])}")
        return 0
    if '--check' in argv:
        bad = [n for n, body in files.items() if not (OUT / n).is_file() or (OUT / n).read_text() != body]
        extra = sorted(p.name for p in OUT.glob('*.svg') if p.name not in files) if OUT.is_dir() else []
        for n in bad:
            print(f'stale or missing: docs/img/popup/{n}')
        for n in extra:
            print(f'not produced by the generator: docs/img/popup/{n}')
        if bad or extra:
            print('run: python3 scripts/docs/popup_art.py')
            return 1
        print(f'ok: {len(files)} pop-up SVGs match the generator')
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for n, body in files.items():
        (OUT / n).write_text(body)
    print(f'wrote {len(files)} SVGs to docs/img/popup/')
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
