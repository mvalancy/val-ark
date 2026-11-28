#!/usr/bin/env python3
"""Storybook illustrations for the Val Ark docs: one hand-composed animated scene per idea.

popup_art.py draws the pop-up header of each guide and flow_art.py the precise
boxes-and-arrows diagrams. This draws the picture book itself (docs/HOW-IT-WORKS.md): each
chapter gets its own scene in a form that fits the idea (a landscape, a cutaway, a frieze),
so no two look alike. Output: docs/img/story/<id>-{light,dark}.svg, deterministic, stdlib
only, no scripts or external references.

  python3 scripts/docs/story_art.py           # rewrite the SVGs
  python3 scripts/docs/story_art.py --check   # exit 1 if any SVG is stale (tests/test-doc-art.sh)
  python3 scripts/docs/story_art.py --list    # which docs embed each scene

Adding a scene: write a draw function that returns the SVG body for a theme, add it to
SCENES with its title, description (the facts it shows, in words), height and used= docs,
then embed it as a light/dark <picture>. Every scene must be complete at rest: with
animations off (prefers-reduced-motion) the whole picture still shows, and only the
travellers (class "go") disappear. Check each new scene in a browser in both themes.
"""
import pathlib
import random
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))   # share the icons and accents with the other doc art
from popup_art import ACCENTS, ICONS, esc  # noqa: E402

ROOT = HERE.parents[1]
OUT = ROOT / 'docs' / 'img' / 'story'
W = 1200

THEMES = {
    'dark': dict(sky0='#0a1322', sky1='#1c2d49', far='#15263a', near='#1b3246', ground='#13212d',
                 wood='#9a6a3a', wood2='#6e4722', cream='#eadfc6', water='#143150', water2='#1c4268',
                 glow='#fde68a', ink='#e6edf3', muted='#a3b1bf', halo='#0f1b2b', cloud='#263850',
                 cloudline='#40587a', wall='#2a3d55', wall2='#22334a', roof='#b4533a', lit='#fcd34d',
                 orb='#f4f1de', tab='#f59e0b', line='#5d7391'),
    'light': dict(sky0='#cfe6f5', sky1='#fdf3dc', far='#d3e3c2', near='#b9d49f', ground='#a3c68a',
                  wood='#b97c42', wood2='#8a5626', cream='#fff8e7', water='#a6d3ea', water2='#86bfdc',
                  glow='#f59e0b', ink='#1f2328', muted='#4b5563', halo='#fdf6e6', cloud='#ffffff',
                  cloudline='#b4c4d4', wall='#e9dcc3', wall2='#dccdb0', roof='#c2553a', lit='#f59e0b',
                  orb='#fbbf24', tab='#d97706', line='#8a7a5c'),
}


def css(t):
    return f"""
.s{{fill:none;stroke:var(--a);stroke-width:2.6;stroke-linecap:round;stroke-linejoin:round}}
.t{{stroke-width:2}}.w{{stroke-width:6}}.f{{fill:var(--a)}}
.ch{{font:700 12px system-ui,-apple-system,'Segoe UI',sans-serif;letter-spacing:.22em;fill:{t['tab']};text-transform:uppercase}}
.tt{{font:italic 600 30px Georgia,'Times New Roman',serif;fill:{t['ink']}}}
.lb{{font:600 15px system-ui,-apple-system,'Segoe UI',sans-serif;fill:{t['ink']}}}
.cp{{font:13px system-ui,sans-serif;fill:{t['muted']}}}
.sm{{font:600 12px system-ui,sans-serif;fill:{t['ink']}}}
.xs{{font:11px system-ui,sans-serif;fill:{t['muted']}}}
.it{{font:italic 14px Georgia,'Times New Roman',serif;fill:{t['ink']}}}
.h{{paint-order:stroke;stroke:{t['halo']};stroke-width:4px;stroke-linejoin:round}}
.m{{text-anchor:middle}}.e{{text-anchor:end}}
.ld{{fill:none;stroke:{t['line']};stroke-width:1.5;stroke-dasharray:2 4;stroke-linecap:round}}
.go{{offset-rotate:0deg;animation:go 9s linear infinite both}}
.drift{{animation:drift 26s ease-in-out infinite alternate}}
.tw{{animation:tw 4s ease-in-out infinite}}
.pulse{{transform-box:fill-box;transform-origin:50% 50%;animation:pulse 3s ease-in-out infinite}}
.spin{{transform-box:fill-box;transform-origin:50% 50%;animation:spin 14s linear infinite}}
.rise{{transform-box:fill-box;transform-origin:50% 100%;animation:rise 1.1s cubic-bezier(.2,.9,.3,1) both}}
.bob{{animation:bob 6s ease-in-out infinite}}
.wave{{animation:wave 7s linear infinite}}
.win{{animation:win 24s linear infinite both}}
.pop{{transform-box:fill-box;transform-origin:50% 50%;animation:pop .6s cubic-bezier(.3,1.4,.5,1) both}}
.bar{{transform-box:fill-box;transform-origin:0 50%;animation:bar 5s ease-in-out infinite}}
.ring{{animation:ring 2.4s ease-out infinite}}
.sway{{transform-box:fill-box;transform-origin:50% 0;animation:sway 5s ease-in-out infinite alternate}}
@keyframes go{{0%{{offset-distance:0%;opacity:0}}8%,90%{{opacity:1}}100%{{offset-distance:100%;opacity:0}}}}
@keyframes drift{{to{{transform:translateX(26px)}}}}
@keyframes tw{{50%{{opacity:.25}}}}
@keyframes pulse{{50%{{transform:scale(1.35);opacity:.35}}}}
@keyframes spin{{to{{transform:rotate(360deg)}}}}
@keyframes rise{{from{{transform:scaleY(0)}}}}
@keyframes bob{{50%{{transform:translateY(46px)}}}}
@keyframes wave{{to{{transform:translateX(-80px)}}}}
@keyframes pop{{from{{transform:scale(.8)}}}}
@keyframes bar{{0%{{transform:scaleX(.04)}}70%,100%{{transform:none}}}}
@keyframes ring{{0%{{opacity:0}}30%{{opacity:1}}100%{{opacity:.15}}}}
@keyframes sway{{from{{transform:rotate(-4deg)}}to{{transform:rotate(4deg)}}}}
@keyframes win{{0%,30%,100%{{opacity:.28}}3%,14%{{opacity:1}}}}
@media (prefers-reduced-motion:reduce){{*{{animation:none!important}}.go{{display:none}}}}
@supports not (offset-path:path('M0 0')){{.go{{display:none}}}}
"""


def icon(name, x, y, scale, colour, extra=''):
    return f'<g transform="translate({x:.1f} {y:.1f}) scale({scale})" style="--a:{colour}"{extra}>{ICONS[name]}</g>'


def text(x, y, cls, s, extra=''):
    return f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}"{extra}>{esc(s)}</text>'


def sky(t, h, rnd, theme, orb, stars=46, horizon=.55):
    """Sky gradient, stars (dark) and a moon or sun at orb=(x, y, r)."""
    p = [f'<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{t["sky0"]}"/>'
         f'<stop offset="1" stop-color="{t["sky1"]}"/></linearGradient>'
         f'<clipPath id="page"><rect width="{W}" height="{h}" rx="18"/></clipPath></defs>',
         f'<rect width="{W}" height="{h}" rx="18" fill="url(#sky)"/>']
    if theme == 'dark':
        for _ in range(stars):
            x, y, r = rnd.uniform(20, W - 20), rnd.uniform(14, h * horizon), rnd.choice((1, 1, 1.4, 1.9))
            p.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="{r}" fill="{t["glow"]}" class="tw" '
                     f'style="animation-delay:-{rnd.uniform(0, 4):.1f}s"/>')
    if not orb:
        return ''.join(p)
    ox, oy, r = orb
    p.append(f'<circle cx="{ox}" cy="{oy}" r="{r * 1.7:.0f}" fill="{t["orb"]}" opacity=".16" class="pulse"/>'
             f'<circle cx="{ox}" cy="{oy}" r="{r}" fill="{t["orb"]}"/>')
    if theme == 'dark':   # a crescent: the sky colour bites the moon
        p.append(f'<circle cx="{ox + r * .42:.0f}" cy="{oy - r * .22:.0f}" r="{r * .86:.0f}" fill="{t["sky0"]}"/>')
    return ''.join(p)


def cloud(x, y, k, t, cls='drift'):
    return (f'<g class="{cls}"><g transform="translate({x} {y}) scale({k})" fill="{t["cloud"]}" stroke="{t["cloudline"]}" '
            f'stroke-width="2"><ellipse cx="-58" cy="14" rx="46" ry="30"/><ellipse cx="56" cy="16" rx="52" ry="30"/>'
            f'<ellipse cx="-8" cy="-12" rx="56" ry="42"/><rect x="-96" y="16" width="196" height="30" rx="15" stroke="none"/>'
            f'<path d="M-90 46H96" /></g></g>')


def house(x, y, w, hgt, t, delay):
    """A cottage standing on (x, y): walls, roof and one window that glows."""
    return (f'<rect x="{x - w / 2}" y="{y - hgt}" width="{w}" height="{hgt}" fill="{t["wall"]}" stroke="{t["line"]}"/>'
            f'<path d="M{x - w / 2 - 7} {y - hgt}L{x} {y - hgt - w * .5:.0f}L{x + w / 2 + 7} {y - hgt}Z" fill="{t["roof"]}"/>'
            f'<rect x="{x - 8}" y="{y - hgt + 12}" width="16" height="16" rx="2" fill="{t["lit"]}" class="tw" '
            f'style="animation-delay:-{delay}s"/>')


# ------------------------------------------------------------------- scenes
def voyage(t, theme, h):
    """Chapter 1: the whole system as a landscape. Cloud -> Ark on its hill -> the village."""
    rnd = random.Random(11)
    p = [sky(t, h, rnd, theme, (1068, 96, 30)),
         f'<g clip-path="url(#page)">',
         f'<path d="M0 372C150 322 300 346 430 366S700 300 860 346S1100 330 1200 356V{h}H0Z" fill="{t["far"]}"/>',
         f'<path d="M250 {h}C380 400 500 352 600 352S820 400 950 {h}Z" fill="{t["near"]}"/>',
         f'<path d="M0 470C220 440 420 478 640 462S1010 430 1200 452V{h}H0Z" fill="{t["ground"]}"/>']
    # the road from the Ark down to the village, with lights travelling along it
    road = 'M700 372C790 400 820 452 930 452'
    p.append(f'<path d="{road}" fill="none" stroke="{t["cream"]}" stroke-width="9" stroke-linecap="round" opacity=".5"/>'
             f'<path d="{road}" class="ld"/>')
    for k in range(3):
        p.append(f'<circle r="5" fill="{t["lit"]}" class="go" style="offset-path:path(\'{road}\');'
                 f'animation-duration:5s;animation-delay:{k * 1.6:.1f}s"/>')
    # the village
    for i, (x, w, hg) in enumerate(((952, 54, 44), (1024, 64, 58), (1102, 52, 40))):
        p.append(house(x, 462, w, hg, t, i * 1.3))
    p.append(f'<path d="M1160 470V428M1140 430H1182l8 7-8 7h-42Z" fill="{t["cream"]}" stroke="{t["line"]}" stroke-width="1.5"/>')
    p.append(text(1026, 348, 'ch h m', 'Your network') + text(1026, 500, 'lb h m', 'The web UI, in any browser')
             + text(1026, 522, 'cp h m', 'and plain pages on a file share'))
    p.append(text(812, 388, 'it h', 'no internet needed', ' transform="rotate(24 812 388)"'))
    # the Ark on the hill
    p.append(f'<path d="M462 300H738C730 334 700 356 660 356H540C500 356 470 334 462 300Z" fill="{t["wood"]}" '
             f'stroke="{t["wood2"]}" stroke-width="3"/>'
             f'<path d="M474 316H726M492 334H708" stroke="{t["wood2"]}" stroke-width="2" fill="none" opacity=".7"/>'
             f'<rect x="540" y="246" width="120" height="54" fill="{t["cream"]}" stroke="{t["wood2"]}" stroke-width="2.5"/>'
             f'<path d="M526 248L600 208L674 248Z" fill="{t["roof"]}" stroke="{t["wood2"]}" stroke-width="2.5"/>'
             f'<rect x="556" y="262" width="22" height="22" rx="3" fill="{t["lit"]}" class="tw"/>'
             f'<rect x="622" y="262" width="22" height="22" rx="3" fill="{t["lit"]}" class="tw" style="animation-delay:-2s"/>'
             f'<path d="M592 300v-30a8 8 0 0 1 16 0v30Z" fill="{t["wood2"]}"/>')
    p.append(f'<circle cx="600" cy="327" r="17" fill="{t["halo"]}" stroke="{t["wood2"]}" stroke-width="3"/>'
             + icon('disk', 600, 327, .5, t['lit'], ' class="spin"'))
    p.append(f'<path d="M704 300V214" stroke="{t["wood2"]}" stroke-width="4" stroke-linecap="round"/>'
             f'<circle cx="704" cy="204" r="24" fill="{t["glow"]}" opacity=".3" class="pulse"/>'
             f'<circle cx="704" cy="204" r="8" fill="{t["glow"]}" stroke="{t["wood2"]}" stroke-width="2"/>')
    p.append(f'<path d="M446 290L536 278" class="ld"/><path d="M716 198L762 184" class="ld"/>')
    p.append(text(440, 290, 'lb h e', 'The Librarian') + text(440, 309, 'cp h e', 'picks what fits')
             + text(768, 180, 'lb h', 'The loop') + text(768, 199, 'cp h', 'mends it every 30 minutes')
             + text(600, 384, 'lb h m', 'One disk holds it all'))
    # the internet: a cloud that rains books, models and apps into the Ark
    arcs = ('M286 158C380 56 520 88 596 204', 'M292 176C400 108 500 128 572 222', 'M282 194C380 168 480 178 548 240')
    for d in arcs:
        p.append(f'<path d="{d}" class="ld" opacity=".8"/>')
    for i, (d, ic) in enumerate(zip(arcs, ('book', 'brain', 'cube'))):
        for k in range(2):
            p.append(f'<g class="go" style="offset-path:path(\'{d}\');animation-delay:{i * 1.1 + k * 4.5:.1f}s">'
                     f'<circle r="13" fill="{t["halo"]}" stroke="{ACCENTS[i]}" stroke-width="2"/>'
                     + icon(ic, 0, 0, .42, ACCENTS[i]) + '</g>')
    p.append(cloud(196, 160, 1.0, t))
    p.append(f'<g class="drift">' + text(190, 162, 'lb m', 'The internet') + text(190, 182, 'cp m', 'while it lasts') + '</g>')
    for i, (ic, s) in enumerate((('book', 'Wikipedia and more'), ('brain', 'AI models'), ('cube', 'Apps and installers'))):
        y = 292 + i * 27
        p.append(icon(ic, 64, y - 5, .42, ACCENTS[i]) + text(84, y, 'cp h', s))
    for x in (40, 150, 300, 420, 560, 760, 880, 1150):
        p.append(f'<path d="M{x} {h - 22}q4-14 0-22M{x + 7} {h - 22}q7-10 9-18M{x - 7} {h - 22}q-7-10-9-18" '
                 f'stroke="{t["near"]}" stroke-width="2.5" fill="none" stroke-linecap="round"/>')
    p.append('</g>')
    return ''.join(p)


HOLD = (  # bottom-up: (top y, bottom y, accent index, icons, label, caption)
    (466, 524, 4, ('leaf', 'flask', 'book'), '1  Grid-down essentials', 'water, medicine, pocket Wikipedia, tiny assistant'),
    (396, 466, 0, ('cube', 'wrench', 'terminal', 'cube'), '2  Apps and tools', 'mirrored next, each within a share of the space'),
    (290, 396, 2, ('book', 'map', 'globe', 'book', 'tree'), '3  The library', "Wikipedia, Lastbook's books and maps, installers"),
    (226, 290, 3, ('brain', 'chip', 'brain', 'spark', 'brain'), '4  AI models', 'after the whole library is planned'),
)


def hold(t, theme, h):
    """Chapter 2: the disk as a ship's hold seen in cutaway, filling in strata from the keel up."""
    rnd = random.Random(23)
    hull = 'M360 168H840C840 384 760 524 600 524C440 524 360 384 360 168Z'
    p = [sky(t, h, rnd, theme, (1112, 84, 26), stars=30, horizon=.45),
         f'<defs><clipPath id="hull"><path d="{hull}"/></clipPath></defs><g clip-path="url(#page)">']
    # the sea behind the ship, and the quay the crane stands on
    wave = ''.join(f'q20-12 40 0t40 0' for _ in range(17))
    p.append(f'<rect y="330" width="{W}" height="{h - 330}" fill="{t["water"]}"/>'
             f'<path d="M-80 330{wave}V352H-80Z" fill="{t["water"]}" class="wave"/>'
             f'<path d="M-80 380{wave}" fill="none" stroke="{t["water2"]}" stroke-width="3" class="wave" style="animation-duration:11s"/>'
             f'<path d="M-80 452{wave}" fill="none" stroke="{t["water2"]}" stroke-width="3" class="wave" style="animation-duration:9s"/>')
    p.append(f'<rect x="900" y="316" width="320" height="{h - 316}" fill="{t["wall"]}" stroke="{t["line"]}" stroke-width="2"/>'
             f'<path d="M900 350H1200M900 392H1200M960 316V350M1060 350V392M1140 316V350" stroke="{t["wall2"]}" stroke-width="2"/>')
    # the hold
    p.append(f'<path d="{hull}" fill="{t["halo"]}"/><g clip-path="url(#hull)">')
    for i, (y0, y1, ai, icons, _, _) in enumerate(HOLD):
        a = ACCENTS[ai]
        g = [f'<rect x="360" y="{y0}" width="480" height="{y1 - y0}" fill="{a}" opacity=".3"/>'
             f'<path d="M360 {y0}H840" stroke="{a}" stroke-width="2.5"/>']
        span = (70, 150, 195, 210)[i]
        for k, ic in enumerate(icons):
            x = 600 - span + (2 * span) * (k + .5) / len(icons)
            g.append(icon(ic, x, (y0 + y1) / 2 + 2, .58, a))
        p.append(f'<g class="rise" style="animation-delay:{.3 + i * .9:.1f}s">{"".join(g)}</g>')
    p.append(f'<path d="M360 226H840" stroke="{t["ink"]}" stroke-width="2" stroke-dasharray="7 6" opacity=".7"/></g>')
    p.append(f'<path d="{hull}" fill="none" stroke="{t["wood2"]}" stroke-width="7"/>'
             f'<path d="M344 168H856" stroke="{t["wood"]}" stroke-width="12" stroke-linecap="round"/>')
    p.append(text(600, 204, 'it m', 'kept free, always'))
    # the labels, with leaders into each layer
    for (y0, y1, ai, _, label, cap), tx in zip(HOLD, (468, 410, 380, 372)):
        yc = (y0 + y1) / 2
        p.append(f'<path d="M332 {yc}H{tx}" class="ld"/><circle cx="{tx}" cy="{yc}" r="4" fill="{ACCENTS[ai]}"/>')
        p.append(text(324, yc - 2, 'lb h e', label) + text(324, yc + 16, 'xs h e', cap))
    p.append(f'<path d="M332 198H372" class="ld"/>' + text(324, 196, 'lb h e', 'The reserve')
             + text(324, 214, 'xs h e', 'by default 2% of the disk or 50 GB, whichever is larger'))
    # the crane lowers the next crate in
    p.append(f'<path d="M940 316V96M940 104H690M940 150L870 104M920 316h40" fill="none" stroke="{t["wood2"]}" '
             f'stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>')
    p.append(f'<defs><clipPath id="rope"><rect x="680" y="104" width="80" height="140"/></clipPath></defs>'
             f'<g clip-path="url(#rope)"><g class="bob"><path d="M720 50V118" stroke="{t["ink"]}" stroke-width="2"/>'
             f'<rect x="699" y="118" width="42" height="34" rx="3" fill="{t["wood"]}" stroke="{t["wood2"]}" stroke-width="2.5"/>'
             f'<path d="M699 118l42 34M741 118l-42 34" stroke="{t["wood2"]}" stroke-width="2"/></g></g>')
    p.append(text(966, 190, 'lb h', 'The Librarian lowers in') + text(966, 211, 'cp h', 'one of each kind first, then')
             + text(966, 229, 'cp h', 'the most value per byte'))
    p.append(text(1050, 440, 'sm m', 'Ask for something specific') + text(1050, 459, 'xs m', 'and, if it needs room, the least')
             + text(1050, 475, 'xs m', 'valuable unpinned item is put ashore'))
    p.append(icon('cube', 1050, 500, .5, t['muted']))
    p.append('</g>')
    return ''.join(p)


WATCH = (   # (icon, label, caption): the loop's round, in order
    ('disk', 'Disk check', 'mounted, writable'), ('wrench', 'Repair layout', 'folders, symlinks'),
    ('globe', 'Keep it up', 'server, apps, network'), ('ark', 'Copy itself', 'for new nodes'),
    ('map', 'Refresh', 'live catalogs'), ('magnifier', 'Fix dead links', 'tool, installer URLs'),
    ('check', 'Check files', 'sizes, re-fetch short'), ('cube', 'Update apps', 'tools, dev stack'),
    ('play', 'Top up', 'essentials, library, models'), ('flask', 'Does it run?', 'tools, LLM, API, UI'),
    ('shield', 'Safety sweep', 'new uploads'), ('eye', 'Report', 'Health page, events'),
)


def watch(t, theme, h):
    """Chapter 3: the loop as a night watch walking the wall, lighting each tower as it checks it."""
    rnd = random.Random(37)
    top, x0, step = 322, 97, 91.5
    p = [sky(t, h, rnd, theme, (1090, 92, 28), stars=60, horizon=.5), f'<g clip-path="url(#page)">',
         f'<path d="M0 330C200 300 420 318 640 306S1010 292 1200 312V{h}H0Z" fill="{t["far"]}"/>',
         f'<rect y="392" width="{W}" height="{h - 392}" fill="{t["ground"]}"/>']
    p.append(text(1028, 90, 'lb h e', 'Every 30 minutes,') + text(1028, 109, 'cp h e', 'and after every reboot'))
    teeth = ''.join(f'M{x} {top}v-12h20v12' for x in range(46, 1150, 40))
    p.append(f'<rect x="36" y="{top}" width="1128" height="72" fill="{t["wall"]}" stroke="{t["line"]}" stroke-width="2"/>'
             f'<path d="{teeth}" fill="{t["wall"]}" stroke="{t["line"]}" stroke-width="2"/>'
             f'<path d="M36 346H1164M36 370H1164" stroke="{t["wall2"]}" stroke-width="2"/>')
    walk = f'M40 {top - 14}H1160'
    for i, (ic, label, cap) in enumerate(WATCH):
        x = x0 + i * step
        hgt = (64, 92, 76)[i % 3]
        a = ACCENTS[i % len(ACCENTS)]
        y = top - hgt
        cap_shape = (f'<path d="M{x - 33} {y}L{x} {y - 34}L{x + 33} {y}Z" fill="{t["roof"]}"/>' if i % 2 == 0 else
                     f'<path d="M{x - 30} {y}v-12h14v12h9v-12h14v12h9v-12h14v12Z" fill="{t["wall2"]}" stroke="{t["line"]}" stroke-width="1.5"/>')
        delay = (x - 40) / 1120 * 24 - .8
        p.append(f'<rect x="{x - 27}" y="{y}" width="54" height="{hgt + 72}" fill="{t["wall2"]}" stroke="{t["line"]}" stroke-width="2"/>'
                 + cap_shape +
                 f'<path d="M{x - 9} {y + 38}v-16a9 9 0 0 1 18 0v16Z" fill="{t["lit"]}" class="win" style="animation-delay:{delay:.2f}s"/>'
                 + icon(ic, x, top + 40, .52, a))
        ly = 424 if i % 2 == 0 else 474
        p.append(f'<path d="M{x} 396V{ly - 14}" class="ld"/>' + text(x, ly, 'sm m', label) + text(x, ly + 15, 'xs m', cap))
    # the watch: a cloaked figure with a lantern, walking the wall
    p.append(f'<g class="go" style="offset-path:path(\'{walk}\');animation-duration:24s"><g transform="scale(1.45)">'
             f'<circle cx="13" cy="-12" r="26" fill="{t["glow"]}" opacity=".28"/>'
             f'<path d="M-9 14L0-12L9 14Z" fill="{t["roof"]}"/><circle cy="-17" r="6" fill="{t["cream"]}"/>'
             f'<path d="M4-6L13-12M13-28V8" stroke="{t["ink"]}" stroke-width="2" stroke-linecap="round"/>'
             f'<circle cx="13" cy="-12" r="5" fill="{t["glow"]}" stroke="{t["ink"]}" stroke-width="1"/></g></g>')
    p.append('</g>')
    return ''.join(p)


def laptop(x, y, w, t, screen=''):
    """A laptop whose screen's top-left is (x, y); screen content is drawn in screen coordinates."""
    hgt = w * .62
    return (f'<rect x="{x - 5}" y="{y - 5}" width="{w + 10}" height="{hgt + 10}" rx="7" fill="{t["ink"]}"/>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{hgt:.0f}" rx="3" fill="{t["halo"]}"/>'
            f'<g transform="translate({x} {y})">{screen}</g>'
            f'<path d="M{x - 22} {y + hgt + 5:.0f}h{w + 44}l-8 11h-{w + 28}Z" fill="{t["ink"]}"/>')


def book(t, theme, h):
    """Chapter 4: two ways in, as the two facing pages of an open book."""
    rnd = random.Random(41)
    p = [sky(t, h, rnd, theme, None, stars=0), '<g clip-path="url(#page)">']
    # the book: cover, two pages, the gutter and a ribbon
    p.append(f'<rect x="52" y="112" width="1096" height="424" rx="14" fill="{t["wood2"]}"/>'
             f'<path d="M70 124C240 108 470 112 600 134V522C470 500 240 496 70 512Z" fill="{t["wall"]}" stroke="{t["line"]}" stroke-width="1.5"/>'
             f'<path d="M1130 124C960 108 730 112 600 134V522C730 500 960 496 1130 512Z" fill="{t["wall"]}" stroke="{t["line"]}" stroke-width="1.5"/>'
             f'<path d="M600 134V522" stroke="{t["line"]}" stroke-width="3" opacity=".6"/>'
             f'<path d="M560 130C580 132 590 134 600 138V522C590 512 580 508 560 506Z" fill="{t["wall2"]}" opacity=".7"/>'
             f'<path d="M640 130C620 132 610 134 600 138V522C610 512 620 508 640 506Z" fill="{t["wall2"]}" opacity=".7"/>'
             f'<path d="M593 132v414l7-9 7 9V132Z" fill="{t["roof"]}"/>')
    # left page: plain pages on a file share
    p.append(text(112, 176, 'ch', 'The side door') + text(112, 204, 'it', 'Plain pages, on any file share', ' style="font-size:21px"'))
    arc = 'M186 300C240 224 330 224 392 270'
    p.append(icon('disk', 160, 306, 1.5, ACCENTS[5]) + f'<path d="{arc}" class="ld"/>')
    for k in range(3):
        p.append(f'<g class="go" style="offset-path:path(\'{arc}\');animation-duration:6s;animation-delay:{k * 2:.0f}s">'
                 f'<path d="M-9-12h13l5 5v19h-18Z" fill="{t["cream"]}" stroke="{t["line"]}" stroke-width="1.5"/>'
                 f'<path d="M-5-3h10M-5 2h10M-5 7h6" stroke="{t["line"]}" stroke-width="1.5"/></g>')
    rows = ''.join(f'<rect x="12" y="{14 + i * 19}" width="12" height="12" rx="2" fill="{ACCENTS[i]}"/>'
                   f'<rect x="32" y="{17 + i * 19}" width="{(86, 64, 96, 52)[i]}" height="6" rx="3" fill="{t["muted"]}"/>' for i in range(4))
    p.append(laptop(372, 244, 150, t, rows))
    p.append(f'<path d="M334 330h30v14h-30Z" fill="{t["muted"]}"/><path d="M318 326h18v22h-18Z" fill="{t["roof"]}"/>')
    p.append(text(160, 362, 'sm m', 'The data disk') + text(440, 386, 'sm m', 'Any device: a share or a USB stick'))
    for i, s in enumerate(('The Librarian writes plain HTML pages onto the disk.',
                           'Open them from SMB, NFS or USB. No server needed.',
                           'Read-only: browse the catalog and copy what you need.')):
        p.append(text(112, 428 + i * 22, 'cp', s))
    # right page: the live web server
    p.append(text(650, 176, 'ch', 'The front door') + text(650, 204, 'it', 'The live web UI, on your network', ' style="font-size:21px"'))
    p.append(icon('ark', 716, 300, 1.7, ACCENTS[0]))
    for k in range(3):
        r = 40 + k * 16
        p.append(f'<path d="M{716 + r * .707:.0f} {296 - r * .707:.0f}A{r} {r} 0 0 1 {716 + r * .707:.0f} {296 + r * .707:.0f}" fill="none" '
                 f'stroke="{ACCENTS[0]}" stroke-width="3" stroke-linecap="round" class="ring" style="animation-delay:{k * .4:.1f}s"/>')
    ui = (''.join(f'<circle cx="{16 + i * 14}" cy="12" r="4" fill="{t["muted"]}"/>' for i in range(4))
          + f'<rect x="10" y="24" width="52" height="42" rx="4" fill="{ACCENTS[2]}" opacity=".5"/>'
            f'<rect x="68" y="24" width="52" height="42" rx="4" fill="{ACCENTS[3]}" opacity=".5"/>'
            f'<rect x="74" y="52" width="40" height="9" rx="4" fill="{t["lit"]}" class="tw"/>')
    p.append(f'<rect x="866" y="244" width="50" height="92" rx="8" fill="{t["ink"]}"/><rect x="871" y="252" width="40" height="72" rx="3" fill="{t["halo"]}"/>'
             f'<rect x="877" y="260" width="28" height="22" rx="3" fill="{ACCENTS[1]}" opacity=".5"/>'
             f'<rect x="877" y="290" width="28" height="9" rx="4" fill="{t["lit"]}" class="tw" style="animation-delay:-2s"/>')
    p.append(laptop(950, 250, 130, t, ui))
    p.append(text(716, 386, 'sm m', 'The Ark, switched on') + text(970, 386, 'sm m', 'Phones and laptops nearby'))
    for i, s in enumerate(('The web server shows the whole library in a browser.',
                           'Request more, ask the assistant; chat and mail if switched on.',
                           'Open to your LAN and tailnet, never to the internet.')):
        p.append(text(650, 428 + i * 22, 'cp', s))
    p.append('</g>')
    p.append(text(1144, 82, 'it h e', 'Both work with no internet at all.'))
    return ''.join(p)


STRIP = (  # (narration, title, lines, accent)
    ('On any device nearby', 'You tap Request', ('one tap, on something', 'the Ark does not have yet'), 2),
    ('The web server checks first', 'Three questions', ('on the LAN or tailnet?', 'within the rate limit?', 'allowed by the Use Mode?'), 1),
    ('The Librarian takes the job', 'Pinned, then fitted', ('pinned: never evicted', "room is made only if it won't fit"), 0),
    ('Watch it on the Activity page', 'It lands', ('resumable, size-checked', 'the loop keeps it there'), 5),
)


def strip(t, theme, h):
    """Chapter 5: one request, told as a four-panel comic strip."""
    rnd = random.Random(53)
    p = [sky(t, h, rnd, theme, None, stars=0), '<g clip-path="url(#page)">']
    pw, ph, top = 262, 392, 124
    for i, (nar, title, lines, ai) in enumerate(STRIP):
        x = 44 + i * (pw + 21.3)
        a = ACCENTS[ai]
        cx = x + pw / 2
        g = [f'<rect x="{x:.0f}" y="{top}" width="{pw}" height="{ph}" rx="6" fill="{t["wall"]}" stroke="{t["ink"]}" stroke-width="3.5"/>',
             f'<rect x="{x + 12:.0f}" y="{top - 12}" width="{pw - 60}" height="30" rx="3" fill="{t["cream"]}" stroke="{t["ink"]}" stroke-width="2"/>',
             f'<text x="{x + 22:.0f}" y="{top + 8}" class="sm" style="fill:#2a1a04">{esc(nar)}</text>',
             f'<circle cx="{x + pw - 22:.0f}" cy="{top + 4}" r="17" fill="{a}" stroke="{t["ink"]}" stroke-width="2.5"/>',
             f'<text x="{x + pw - 22:.0f}" y="{top + 10}" class="lb m" style="fill:#fff">{i + 1}</text>']
        py = top + 150
        if i == 0:    # a phone with a Request button, and the tap
            g.append(f'<rect x="{cx - 48:.0f}" y="{py - 96}" width="96" height="176" rx="14" fill="{t["ink"]}"/>'
                     f'<rect x="{cx - 40:.0f}" y="{py - 82}" width="80" height="148" rx="5" fill="{t["halo"]}"/>'
                     + icon('book', cx, py - 44, .9, a) +
                     f'<rect x="{cx - 30:.0f}" y="{py - 12}" width="60" height="7" rx="3" fill="{t["muted"]}"/>'
                     f'<rect x="{cx - 30:.0f}" y="{py + 2}" width="42" height="7" rx="3" fill="{t["muted"]}"/>'
                     f'<rect x="{cx - 32:.0f}" y="{py + 26}" width="64" height="24" rx="12" fill="{t["lit"]}"/>'
                     f'<text x="{cx:.0f}" y="{py + 43}" class="sm m" style="fill:#2a1a04">Request</text>'
                     f'<circle cx="{cx + 22:.0f}" cy="{py + 44}" r="15" fill="none" stroke="{a}" stroke-width="3" class="pulse"/>')
        elif i == 1:  # the gate: a shield and three ticks
            g.append(icon('shield', cx, py - 40, 2.3, a))
            for k in range(3):
                g.append(f'<g class="tw" style="animation-delay:-{k * 1.3:.1f}s">' + icon('check', cx - 44 + k * 44, py + 52, .7, a) + '</g>')
        elif i == 2:  # a crate with a pin through its tag, on a shelf with a gap closing
            g.append(f'<path d="M{x + 30:.0f} {py + 62}H{x + pw - 30:.0f}" stroke="{t["ink"]}" stroke-width="5" stroke-linecap="round"/>'
                     f'<rect x="{cx - 96:.0f}" y="{py + 6}" width="44" height="54" rx="3" fill="{t["wall2"]}" stroke="{t["line"]}" stroke-width="2"/>'
                     f'<rect x="{cx + 52:.0f}" y="{py - 4}" width="44" height="64" rx="3" fill="{t["wall2"]}" stroke="{t["line"]}" stroke-width="2"/>'
                     f'<rect x="{cx - 40:.0f}" y="{py - 20}" width="80" height="80" rx="4" fill="{t["wood"]}" stroke="{t["wood2"]}" stroke-width="3"/>'
                     f'<path d="M{cx - 40:.0f} {py - 20}l80 80M{cx + 40:.0f} {py - 20}l-80 80" stroke="{t["wood2"]}" stroke-width="2.5"/>'
                     f'<g class="sway"><path d="M{cx:.0f} {py - 78}v52" stroke="{t["ink"]}" stroke-width="3" stroke-linecap="round"/>'
                     f'<circle cx="{cx:.0f}" cy="{py - 84}" r="13" fill="{t["roof"]}" stroke="{t["ink"]}" stroke-width="2.5"/></g>')
        else:         # the download bar, then the book on its shelf
            g.append(icon('book', cx, py - 44, 1.9, a) +
                     f'<rect x="{cx - 92:.0f}" y="{py + 26}" width="184" height="20" rx="10" fill="{t["halo"]}" stroke="{t["ink"]}" stroke-width="2.5"/>'
                     f'<rect x="{cx - 88:.0f}" y="{py + 30}" width="176" height="12" rx="6" fill="{a}" class="bar"/>')
        g.append(text(cx, top + 266, 'it m', title, ' style="font-size:20px"'))
        for k, s in enumerate(lines):
            g.append(text(cx, top + 296 + k * 21, 'cp m', s))
        tilt = (-1.2, .9, -.7, 1.1)[i]
        p.append(f'<g transform="rotate({tilt} {cx:.0f} {top + ph / 2})"><g class="pop" style="animation-delay:{.2 + i * .5:.1f}s">{"".join(g)}</g></g>')
    p.append('</g>')
    return ''.join(p)


def island(t, theme, h):
    """Chapter 6: who can do what, as a map. The keep, the walled land, and the sea outside."""
    rnd = random.Random(67)
    cx, cy = 600, 326
    wave = ''.join('q20-10 40 0t40 0' for _ in range(17))
    p = [sky(t, h, rnd, theme, None, stars=0), '<g clip-path="url(#page)">',
         f'<rect width="{W}" height="{h}" fill="{t["water"]}"/>']
    for y, d in ((150, 9), (250, 12), (372, 8), (470, 11), (556, 10)):
        p.append(f'<path d="M-80 {y}{wave}" fill="none" stroke="{t["water2"]}" stroke-width="3" class="wave" style="animation-duration:{d}s"/>')
    # ships from the internet come near, find no way in, and sail off
    for k, d in enumerate(('M-20 190C200 190 250 250 230 330S120 470 -30 500', 'M1220 170C1010 190 950 250 968 330S1080 470 1230 520')):
        for j in range(2):
            p.append(f'<g class="go" style="offset-path:path(\'{d}\');animation-duration:16s;animation-delay:{k * 3 + j * 8}s">'
                     f'<path d="M-15 6h30l-6 9h-18Z" fill="{t["wood2"]}"/><path d="M0 4V-18l13 18Z" fill="{t["cream"]}" stroke="{t["line"]}"/></g>')
    # the land inside the wall, and the keep
    p.append(f'<ellipse cx="{cx}" cy="{cy}" rx="344" ry="226" fill="{t["cream"]}" opacity=".5"/>'
             f'<ellipse cx="{cx}" cy="{cy}" rx="330" ry="214" fill="{t["near"]}" stroke="{t["wall2"]}" stroke-width="12"/>'
             f'<ellipse cx="{cx}" cy="{cy}" rx="330" ry="214" fill="none" stroke="{t["line"]}" stroke-width="2" stroke-dasharray="14 8"/>')
    p.append(f'<ellipse cx="{cx}" cy="{cy}" rx="128" ry="92" fill="{t["wall"]}" stroke="{t["line"]}" stroke-width="3"/>'
             f'<ellipse cx="{cx}" cy="{cy}" rx="150" ry="110" fill="none" stroke="{t["lit"]}" stroke-width="2.5" opacity=".7" class="pulse"/>'
             + icon('ark', cx, cy - 34, 1.25, ACCENTS[0])
             + text(cx, cy + 14, 'lb m', 'The box itself') + text(cx, cy + 33, 'cp m', 'always the Admin'))
    # the keep's gate, where a passcode lets the network in as Admin
    p.append(f'<path d="M{cx - 16} {cy + 100}v-18a16 16 0 0 1 32 0v18Z" fill="{t["wood2"]}" stroke="{t["line"]}" stroke-width="2"/>'
             + icon('key', cx, cy + 128, .6, ACCENTS[6]) + text(cx, cy + 158, 'sm h m', 'In with the admin passcode')
             + text(cx, cy + 174, 'xs h m', 'settings, repair, moderation'))
    p.append(text(cx, cy - 150, 'ch h m', 'Your network') + text(cx, cy - 130, 'cp h m', 'the LAN and your tailnet'))
    for x, ic, a, l1, l2 in ((372, 'book', 2, 'Browse and read', 'the library, if the mode allows'), (836, 'play', 1, 'Request more', 'one tap, if the mode allows')):
        p.append(icon(ic, x, cy - 30, 1.0, ACCENTS[a]) + text(x, cy + 8, 'sm h m', l1) + text(x, cy + 25, 'xs h m', l2))
    for i, (x, y, dl) in enumerate(((318, cy + 104, 0), (452, cy + 150, 1.5), (760, cy + 152, .7), (884, cy + 104, 2.2))):
        p.append(house(x, y, 40, 32, t, dl))
    # the sea, and the rule of the house
    p.append(text(120, 290, 'ch h m', 'The internet') + text(120, 311, 'lb h m', 'Refused') + text(120, 330, 'cp h m', 'no library, no changes'))
    p.append(f'<rect x="968" y="90" width="196" height="92" rx="8" fill="{t["wall"]}" stroke="{t["line"]}" stroke-width="2"/>'
             + text(1066, 114, 'ch m', 'Use Mode') + text(1066, 138, 'sm m', 'Open · Passworded · Accounts')
             + text(1066, 157, 'xs m', 'the Admin chooses who gets in;') + text(1066, 172, 'xs m', 'a new box starts Open'))
    p.append('</g>')
    return ''.join(p)


SCENES = {
    'voyage': dict(
        chapter='Chapter 1', title='One Ark, end to end', h=560, draw=voyage,
        desc='A landscape. On the left a cloud, the internet while it lasts, rains books (Wikipedia and more), AI models, '
             'and apps and installers into an ark on a hill. On the Ark the Librarian picks what fits, one disk holds it '
             'all, and the loop mends it every 30 minutes. A road leads down to a village, your network, which gets the '
             'web UI in any browser and plain pages on a file share, with no internet needed.',
        used=['docs/HOW-IT-WORKS.md']),
    'hold': dict(
        chapter='Chapter 2', title='Filling the hold', h=560, draw=hold,
        desc="A ship's hold in cutaway, filling from the keel up. 1: grid-down essentials (water, medicine, a pocket "
             'Wikipedia, a tiny assistant). 2: apps and tools, mirrored next, each within a share of the space. 3: the '
             'library (Wikipedia and other ZIMs, Lastbook\'s books and maps, installers). 4: AI models, after the whole library is planned. '
             'The top stays empty: the reserve, by default 2% of the disk or 50 GB, whichever is larger. A crane lowers crates in: '
             'one of each kind first, then the most value per byte. Ask for something specific and, if it needs room, the '
             'least valuable unpinned item is removed.',
        used=['docs/HOW-IT-WORKS.md']),
    'watch': dict(
        chapter='Chapter 3', title='The night watch', h=520, draw=watch,
        desc='A watchman with a lantern walks a wall of twelve towers every 30 minutes and after every reboot, lighting '
             'each as it is checked: ' + '; '.join(f'{label} ({cap})' for _, label, cap in WATCH) + '.',
        used=['docs/HOW-IT-WORKS.md']),
    'book': dict(
        chapter='Chapter 4', title='Two ways in', h=560, draw=book,
        desc='An open book. Left page, the side door: the Librarian writes plain HTML pages onto the data disk; open them '
             'on any device from an SMB or NFS share or a USB stick, with no server needed; read-only, to browse the '
             'catalog and copy what you need. Right page, the front door: with the Ark switched on, its web server shows '
             'the whole library in a browser to phones and laptops nearby; request more and ask the assistant, plus '
             'chat and mail if those services are switched on; open to your LAN and tailnet, never to the internet. Both work with no internet at all.',
        used=['docs/HOW-IT-WORKS.md']),
    'strip': dict(
        chapter='Chapter 5', title='One tap, four panels', h=560, draw=strip,
        desc='A four-panel comic strip. ' + ' '.join(
            f'{i + 1}: {title} ({nar.lower()}): {", ".join(lines)}.' for i, (nar, title, lines, _) in enumerate(STRIP)),
        used=['docs/HOW-IT-WORKS.md']),
    'island': dict(
        chapter='Chapter 6', title='The island and the sea', h=600, draw=island,
        desc='A map of an island. In the middle a keep: the box itself, always the Admin. Around it, inside a wall, your '
             'network (the LAN and your tailnet): people browse and read the library and request more with one tap, '
             'both if the Use Mode allows; the admin passcode opens the keep for settings, repair and moderation. Outside the '
             'wall is the sea, the internet: ships come near and are refused: no library and no changes. A sign gives '
             'the Use Mode: Open, Passworded or Accounts; the Admin chooses who gets in, and a new box starts Open.',
        used=['docs/HOW-IT-WORKS.md']),
}


def render(sid, spec, theme):
    t = THEMES[theme]
    h = spec['h']
    title = f"Val Ark: {spec['title']}"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {h}" width="{W}" height="{h}" role="img" '
            f'aria-label="{esc(title)}"><title>{esc(title)}</title><desc>{esc(spec["desc"])}</desc>'
            f'<style>{css(t)}</style>{spec["draw"](t, theme, h)}'
            f'<text x="56" y="46" class="ch h">{esc(spec["chapter"])}</text>'
            f'<text x="56" y="82" class="tt h">{esc(spec["title"])}</text></svg>\n')


def build():
    return {f'{s}-{th}.svg': render(s, spec, th) for s, spec in SCENES.items() for th in THEMES}


def main(argv):
    files = build()
    if '--list' in argv:
        for s, spec in SCENES.items():
            print(f"{s}\t{', '.join(spec['used'])}")
        return 0
    if '--check' in argv:
        bad = [n for n, body in files.items() if not (OUT / n).is_file() or (OUT / n).read_bytes() != body.encode()]
        extra = sorted(p.name for p in OUT.glob('*.svg') if p.name not in files) if OUT.is_dir() else []
        for n in bad:
            print(f'stale or missing: docs/img/story/{n}')
        for n in extra:
            print(f'not produced by the generator: docs/img/story/{n}')
        unused = [(s, md) for s, spec in SCENES.items() for md in spec['used']
                  if f'story/{s}-light.svg' not in ((ROOT / md).read_text(errors='replace') if (ROOT / md).is_file() else '')]
        for s, md in unused:
            print(f'{md} is listed in used= for {s} but does not embed it')
        if bad or extra:
            print('run: python3 scripts/docs/story_art.py')
        if bad or extra or unused:
            return 1
        print(f'ok: {len(files)} story SVGs match the generator')
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for n, body in files.items():
        (OUT / n).write_bytes(body.encode())
    print(f'wrote {len(files)} SVGs to docs/img/story/')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
