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
import re
import subprocess
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
        links=[(0, 1, 'side'), (0, 2, 'arc'), (1, 3, 'arc'), (2, 3, 'side'), (2, 4, 'arc'), (4, 5, 'side')],
        used=['docs/ARCHITECTURE.md']),
    'librarian': dict(chapter='Chapter 2', title='The Librarian fills the shelves',
        sub='Essentials first, then diversity, small and valuable, then fill the rest.', backdrop='shelf',
        cards=[('shield', 'Essentials', '0'), ('cube', 'Diversity', '1'), ('leaf', 'Small + valuable', '2'),
               ('disk', 'Fill the rest', '3'), ('magnifier', 'Trade up', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side')],
        used=['docs/LIBRARIAN.md']),
    'tools': dict(chapter='Chapter 3', title='A toolbox for every job',
        sub='Dev tools, AI runtimes, creative suites and media, mirrored for each platform.', backdrop='hills',
        cards=[('terminal', 'Dev tools', None), ('brain', 'AI inference', None), ('cube', 'Creative', None),
               ('play', 'Media', None), ('gear', 'Infrastructure', None), ('cloud', 'AI platforms', None)],
        links=[], used=['docs/TOOLS.md']),
    'models': dict(chapter='Chapter 4', title='A menagerie of models',
        sub='Flagship LLM, speech, vision and image models, plus small diversity picks.', backdrop='hills',
        cards=[('brain', 'Language', None), ('eye', 'Vision', None), ('mic', 'Speech', None),
               ('play', 'Image gen', None), ('cube', 'Embeddings', None)],
        links=[(0, 1, 'arc'), (1, 2, 'arc'), (2, 3, 'arc'), (3, 4, 'arc')],
        used=['docs/MODEL_INVENTORY.md']),
    'platforms': dict(chapter='Chapter 5', title='Every kind of machine',
        sub='One mirror serves x86_64, arm64, Jetson, macOS, Windows and OpenWRT.', backdrop='city',
        cards=[('chip', 'x86_64', None), ('chip', 'arm64', None), ('brain', 'Jetson', None),
               ('cube', 'macOS', None), ('globe', 'Windows', None), ('wifi', 'OpenWRT', None)],
        links=[], used=['docs/PLATFORMS.md']),
    'community': dict(chapter='Chapter 6', title='The village square',
        sub='Chat, mail, message boards, pastes and shared files: no internet needed.', backdrop='village',
        cards=[('chat', 'Chat', None), ('mail', 'Mail', None), ('board', 'Forum', None),
               ('paste', 'Paste', None), ('disk', 'Shared files', None)],
        links=[(0, 1, 'arc'), (1, 2, 'arc'), (2, 3, 'arc'), (3, 4, 'arc')],
        used=['docs/COMMUNITY.md']),
    'offline': dict(chapter='Chapter 7', title='Off the grid, together',
        sub='Pull everything once, then share it across the LAN with no internet.', backdrop='waves',
        cards=[('house', 'Home', None), ('house', 'Workshop', None), ('ark', 'The Ark', None),
               ('house', 'School', None), ('house', 'Clinic', None)],
        links=[(2, 0, 'arc'), (2, 1, 'arc'), (2, 3, 'arc'), (2, 4, 'arc')],
        used=['docs/OFFLINE.md']),
    'serving': dict(chapter='Chapter 8', title='Two ways to serve',
        sub='Static pages on any file share, or a live server with chat, mail and requests.', backdrop='city',
        cards=[('disk', 'Plain files', None), ('book', 'Static pages', None), ('lock', 'File share', None),
               ('server', 'server.js', None), ('globe', 'Live web UI', None), ('chat', 'Chat + mail', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (3, 4, 'side'), (4, 5, 'side')],
        used=['docs/SERVING.md']),
    'nas': dict(chapter='Appendix', title='The Ark on an arm64 NAS',
        sub='Boxes built on chips such as the Rockchip RK3588: setup notes and fixes.', backdrop='city',
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
        sub='A dated audit: what was swept, what was found, what is still open.', backdrop='vault',
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
        used=['tests/README.md']),
    'how-it-works': dict(chapter='The Picture Book', title='How it works, in pictures',
        sub='Ten moving diagrams, in reading order, from one disk to a whole network.', backdrop='hills',
        cards=[('disk', 'Fill', None), ('gear', 'Heal', None), ('globe', 'Serve', None),
               ('lock', 'Protect', None), ('chat', 'Gather', None), ('ark', 'Spread', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side'), (4, 5, 'side')],
        used=['docs/HOW-IT-WORKS.md']),
    # ---- design hierarchy (docs/design/)
    'vision': dict(chapter='Design', title='What the Ark is for',
        sub='A knowledge-and-comms appliance for when the internet is not there.', backdrop='village',
        cards=[('house', 'Your home', None), ('ark', 'The Ark', None), ('book', 'Wikipedia', None),
               ('brain', 'AI helper', None), ('chat', 'Chat + mail', None)],
        links=[(0, 1, 'side'), (1, 2, 'arc'), (1, 3, 'arc'), (1, 4, 'arc')],
        used=['docs/design/vision.md']),
    'current-state': dict(chapter='Design', title='Where it stands today',
        sub='Shipped: setup in a browser, an admin area, recovery and real access controls.', backdrop='hills',
        cards=[('check', 'Set up', None), ('lock', 'Admin', None), ('key', 'Recovery', None),
               ('shield', 'Use Mode', None), ('terminal', 'CLI too', None)],
        links=[], used=['docs/design/current-state.md']),
    'research-brief': dict(chapter='Design', title='What we learned first',
        sub='Eight research tracks, from NAS boxes to fitness apps, boiled down to advice.', backdrop='shelf',
        cards=[('server', 'NAS boxes', None), ('house', 'Home hubs', None), ('wifi', 'Routers', None),
               ('leaf', 'Health apps', None), ('magnifier', 'Findings', None)],
        links=[(0, 4, 'arc'), (1, 4, 'arc'), (2, 4, 'arc'), (3, 4, 'side')],
        used=['docs/design/research-brief.md']),
    'roadmap': dict(chapter='Design', title='The road, phase by phase',
        sub='Each phase ships something an owner can feel. Recovery lands before any gate.', backdrop='hills',
        cards=[('check', 'Setup', '1'), ('key', 'Access', '2'), ('eye', 'Home', '3'),
               ('disk', 'Storage', '4'), ('play', 'Downloads', '5'), ('brain', 'Assistant', '8')],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side'), (4, 5, 'side')],
        used=['docs/design/roadmap.md']),
    'commissioning': dict(chapter='Design', title='The first five minutes',
        sub='A fresh box becomes a working Ark in a browser: no files, flags or jargon.', backdrop='city',
        cards=[('wifi', 'Find it', None), ('disk', 'Storage', None), ('shield', 'Who can use', None),
               ('book', 'Topics', None), ('check', 'Ready', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side')],
        used=['docs/design/commissioning.md']),
    'access-identity': dict(chapter='Design', title='Who can come in',
        sub='One Admin, a choosable Use Mode, and the box itself is always trusted.', backdrop='vault',
        cards=[('house', 'Localhost', None), ('lock', 'Admin', None), ('globe', 'Open', None),
               ('key', 'Passworded', None), ('chat', 'Accounts', None)],
        links=[(0, 1, 'side'), (1, 2, 'arc'), (1, 3, 'arc'), (1, 4, 'arc')],
        used=['docs/design/access-identity.md']),
    'admin-console': dict(chapter='Design', title='Home screen and console',
        sub='A calm summary for everyone; settings and system for the Admin.', backdrop='city',
        cards=[('eye', 'Is it well?', None), ('disk', 'Storage', None), ('play', 'Activity', None),
               ('gear', 'Settings', None), ('wrench', 'Repair', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (3, 4, 'side')],
        used=['docs/design/admin-console.md']),
    'storage': dict(chapter='Design', title='Add and remove drives',
        sub='A small fixed brain plus a content pool that grows and shrinks.', backdrop='shelf',
        cards=[('chip', 'Brain', None), ('disk', 'Primary', None), ('disk', 'USB drive', None),
               ('disk', 'Another', None), ('check', 'Keeps going', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side')],
        used=['docs/design/storage.md']),
    'deployment': dict(chapter='Design', title='Shipping it safely',
        sub='Native or Docker, locked down and reliable, still offline and self-copying.', backdrop='city',
        cards=[('terminal', 'Native', None), ('cube', 'Docker', None), ('shield', 'Hardened', None),
               ('ark', 'Self-copy', None), ('check', 'Reliable', None)],
        links=[(0, 2, 'arc'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side')],
        used=['docs/design/deployment.md']),
    'downloads-monitoring': dict(chapter='Design', title='Pick what matters',
        sub='Plain-language profiles sized to the disk, and downloads you can watch.', backdrop='hills',
        cards=[('book', 'Wikipedia', None), ('wrench', 'How-to', None), ('brain', 'AI helper', None),
               ('disk', 'Fits disk', None), ('play', 'Progress', None)],
        links=[(0, 3, 'arc'), (1, 3, 'arc'), (2, 3, 'side'), (3, 4, 'side')],
        used=['docs/design/downloads-monitoring.md']),
    'errors-selfheal': dict(chapter='Design', title='One big easy button',
        sub='The loop repairs itself every half hour; the rest is one tap in plain words.', backdrop='hills',
        cards=[('eye', 'Notice', None), ('gear', 'Self-heal', None), ('check', 'Verify', None),
               ('wrench', 'One tap', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 0, 'arc'), (2, 3, 'side')],
        used=['docs/design/errors-selfheal.md']),
    'recovery': dict(chapter='Design', title='Forgot the password?',
        sub='At the box, or on localhost, you are the Admin. Nobody stays locked out.', backdrop='vault',
        cards=[('lock', 'Locked out', None), ('house', 'At the box', None), ('paste', 'Paper code', None),
               ('key', 'New passcode', None)],
        links=[(0, 1, 'side'), (0, 2, 'arc'), (1, 3, 'arc'), (2, 3, 'side')],
        used=['docs/design/recovery.md']),
    'safety-moderation': dict(chapter='Design', title='Keeping shared files safe',
        sub='On-device checks that fail closed: a doubtful file waits for review.', backdrop='vault',
        cards=[('paste', 'Upload', None), ('chip', 'On-box AI', None), ('shield', 'Fail closed', None),
               ('eye', 'Review', None), ('check', 'Shared', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side')],
        used=['docs/design/safety-moderation.md']),
    # ---- knowledge base (docs/knowledge/)
    'decisions': dict(chapter='Knowledge', title='Why it is this way',
        sub='Each big call: the context, the decision and the reason. Newest first.', backdrop='shelf',
        cards=[('magnifier', 'Context', None), ('map', 'Decision', None), ('book', 'Why', None)],
        links=[(0, 1, 'side'), (1, 2, 'side')],
        used=['docs/knowledge/decisions.md']),
    'gotchas': dict(chapter='Knowledge', title='Hard-won fixes',
        sub='Symptom, cause, fix: the traps that cost real time, so nobody falls in twice.', backdrop='shelf',
        cards=[('eye', 'Symptom', None), ('magnifier', 'Cause', None), ('wrench', 'Fix', None)],
        links=[(0, 1, 'side'), (1, 2, 'side')],
        used=['docs/knowledge/gotchas.md']),
    'workflow': dict(chapter='Knowledge', title='How work flows',
        sub='Issue, branch off dev, PR, review, green tests, then main by release.', backdrop='hills',
        cards=[('board', 'Issue', None), ('tree', 'Branch', None), ('check', 'Review', None),
               ('flask', 'Tests', None), ('gear', 'dev', None), ('ark', 'main', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side'), (4, 5, 'side')],
        used=['docs/knowledge/workflow.md']),
    'governance': dict(chapter='Knowledge', title='Agents you can trust',
        sub='Agents work issues and merge PRs, but strangers cannot steer the repo.', backdrop='vault',
        cards=[('brain', 'Agents', None), ('board', 'Issues', None), ('shield', 'Trust gate', None),
               ('flask', 'CI', None), ('check', 'Merge', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side')],
        used=['docs/knowledge/governance.md']),
    # ---- code guides and policies
    'scripts': dict(chapter='Workshop', title='The scripts',
        sub='Orchestration, curation and the server; all find the data through one file.', backdrop='city',
        cards=[('key', 'valark-env', None), ('terminal', 'start.sh', None), ('disk', 'Librarian', None),
               ('gear', 'loop.sh', None), ('server', 'server.js', None)],
        links=[(0, 1, 'arc'), (0, 2, 'arc'), (0, 3, 'arc'), (0, 4, 'arc')],
        used=['scripts/README.md']),
    'tool-scripts': dict(chapter='Workshop', title='One script per tool',
        sub='Each mirrors its tool for every platform, using shared download helpers.', backdrop='shelf',
        cards=[('wrench', '_common.sh', None), ('cube', 'Linux x86', None), ('chip', 'Linux arm', None),
               ('leaf', 'macOS', None), ('house', 'Windows', None)],
        links=[(0, 1, 'arc'), (0, 2, 'arc'), (0, 3, 'arc'), (0, 4, 'arc')],
        used=['scripts/tools/README.md']),
    'web-ui': dict(chapter='Workshop', title='The web UI',
        sub='One no-build page: open it in a browser, no npm and no bundler.', backdrop='city',
        cards=[('globe', 'index.html', None), ('paste', 'styles.css', None), ('map', 'Router', None),
               ('server', 'JSON API', None)],
        links=[(0, 1, 'side'), (0, 2, 'arc'), (2, 3, 'side')],
        used=['web-ui/README.md']),
    'contributing': dict(chapter='Join in', title='Helping build the Ark',
        sub='Read the workflow, open an issue, send a small PR with green tests.', backdrop='village',
        cards=[('book', 'Read', None), ('board', 'Issue', None), ('wrench', 'Change', None),
               ('flask', 'Test', None), ('check', 'PR', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side'), (3, 4, 'side')],
        used=['CONTRIBUTING.md']),
    'security-policy': dict(chapter='Policy', title='Reporting a problem',
        sub='A LAN appliance, never on the open internet. Report it privately, fixed in private.', backdrop='vault',
        cards=[('magnifier', 'Found one', None), ('mail', 'Tell us', None), ('shield', 'Fix', None),
               ('check', 'Release', None)],
        links=[(0, 1, 'side'), (1, 2, 'side'), (2, 3, 'side')],
        used=['SECURITY.md']),
}

# ---------------------------------------------------------------- drawing
def sentence(title):
    """A title as a sentence: 'Forgot the password?' stays, 'The scripts' gains a period."""
    return title if title[-1] in '.?!' else title + '.'

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
        for col, amp, base in ((t['hill1'], 46, BASE - 64), (t['hill2'], 30, BASE - 30)):
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
        for col, hmin, hmax in ((t['hill1'], 70, 130), (t['hill2'], 30, 70)):
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

def link(a, b, kind, delay):
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
    desc = (f"Pop-up book scene for {spec['chapter']}: {sentence(spec['title'])} Paper cut-outs for "
            + ', '.join(c[1] for c in spec['cards'])
            + ' unfold from the spine of an open book, then fold flat and repeat. ' + spec['sub'])
    css = f"""
.s{{fill:none;stroke:var(--a);stroke-width:2.6;stroke-linecap:round;stroke-linejoin:round}}
.t{{stroke-width:2}}.w{{stroke-width:6}}.f{{fill:var(--a)}}
.lb{{font:600 16px system-ui,-apple-system,'Segoe UI',sans-serif;fill:{t['ink']};text-anchor:middle}}
.bd{{font:700 13px system-ui,sans-serif;fill:#fff;text-anchor:middle}}
.ch{{font:700 12px system-ui,sans-serif;letter-spacing:.22em;fill:{t['tab']};text-transform:uppercase}}
.tt{{font:italic 600 30px Georgia,'Times New Roman',serif;fill:{t['ink']}}}
.st{{font:16px system-ui,sans-serif;fill:{t['muted']}}}
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
        p.append(link(boxes[a], boxes[b], kind, ld + k * 0.12))
    # sparkles
    for k in range(7):
        sx, sy = rnd.randint(90, 1110), rnd.randint(100, 150)
        sc = rnd.uniform(0.35, 0.6)
        p.append(f'<g transform="translate({sx} {sy}) scale({sc:.2f})"><g class="tw" style="animation-delay:{rnd.uniform(0, 2.8):.2f}s;--a:{t["star"]}">'
                 f'{ICONS["spark"]}</g></g>')
    # the pull-tab, sticking out of the right page (decorative: an arrow, not a word that reads as a button)
    p.append(f'<g class="tab"><rect x="1100" y="{BASE+6}" width="58" height="24" rx="6" fill="{t["tab"]}"/>'
             f'<path d="M1138 {BASE+12}l-9 6 9 6M1148 {BASE+12}l-9 6 9 6" fill="none" stroke="{t["tabink"]}" stroke-width="2.4" '
             f'stroke-linecap="round" stroke-linejoin="round"/></g>')
    p.append('</svg>\n')
    return ''.join(p)

# ---------------------------------------------------------------- the docs tree
# A generated map of every human-facing doc, several levels deep: docs-tree-{light,dark}.svg.
# Each node is (label, path-or-None, children). tree_missing() keeps it honest: a tracked
# doc that is not on the tree fails --check (nested AGENTS.md guides, .github/ templates
# and .agents/ skills are agent-only and stay off it).
DOC_TREE = ('Val Ark', 'README.md', [
    ('Docs map', 'docs/README.md', [
        ('Guides', None, [
            ('How it works, in pictures', 'docs/HOW-IT-WORKS.md', []),
            ('Screenshots', 'docs/SCREENSHOTS.md', []),
            ('Static or dynamic serving', 'docs/SERVING.md', []),
            ('The Librarian', 'docs/LIBRARIAN.md', []),
            ('Tools catalog', 'docs/TOOLS.md', []),
            ('AI models', 'docs/MODEL_INVENTORY.md', []),
            ('Platforms', 'docs/PLATFORMS.md', []),
            ('Offline and P2P', 'docs/OFFLINE.md', []),
            ('Community and comms', 'docs/COMMUNITY.md', []),
            ('ARM64 NAS boxes', 'docs/ARM64-NAS.md', []),
            ('Encryption and TLS', 'docs/ENCRYPTION.md', []),
            ('Architecture', 'docs/ARCHITECTURE.md', []),
            ('Security audit', 'docs/SECURITY-AUDIT.md', []),
        ]),
        ('Design', 'docs/design/README.md', [
            ('Vision', 'docs/design/vision.md', []),
            ('Current state', 'docs/design/current-state.md', []),
            ('Research brief', 'docs/design/research-brief.md', []),
            ('Roadmap', 'docs/design/roadmap.md', []),
            ('First-boot setup', 'docs/design/commissioning.md', []),
            ('Access and identity', 'docs/design/access-identity.md', []),
            ('Recovery', 'docs/design/recovery.md', []),
            ('Home and admin console', 'docs/design/admin-console.md', []),
            ('Flexible storage', 'docs/design/storage.md', []),
            ('Downloads and monitoring', 'docs/design/downloads-monitoring.md', []),
            ('Errors and self-heal', 'docs/design/errors-selfheal.md', []),
            ('Safety and moderation', 'docs/design/safety-moderation.md', []),
            ('Deployment', 'docs/design/deployment.md', []),
        ]),
        ('Knowledge', 'docs/knowledge/README.md', [
            ('Decisions', 'docs/knowledge/decisions.md', []),
            ('Gotchas', 'docs/knowledge/gotchas.md', []),
            ('Workflow', 'docs/knowledge/workflow.md', []),
            ('Governance', 'docs/knowledge/governance.md', []),
        ]),
    ]),
    ('Workshop', None, [
        ('Scripts', 'scripts/README.md', [
            ('Tool scripts', 'scripts/tools/README.md', []),
        ]),
        ('Web UI', 'web-ui/README.md', []),
        ('Tests', 'tests/README.md', []),
    ]),
    ('Policies', None, [
        ('Contributing', 'CONTRIBUTING.md', []),
        ('Security policy', 'SECURITY.md', []),
    ]),
    ('For AI agents', None, [
        ('Development guide', 'CLAUDE.md', []),
        ('Agent manual', 'AGENTS.md', []),
        ('Skills and pipeline', '.agents/README.md', []),
    ]),
])
TREE_COLS = [(40, 128), (206, 150), (394, 176), (608, 236)]   # (x, width) per depth
TREE_ROW, TREE_TOP = 25, 118

def tree_paths(node=DOC_TREE):
    label, path, kids = node
    return ([path] if path else []) + [p for k in kids for p in tree_paths(k)]

def tree_missing():
    """Tracked human docs that are not on the tree, and tree paths that no longer exist."""
    try:
        tracked = subprocess.run(['git', 'ls-files', '*.md'], cwd=ROOT, capture_output=True,
                                 text=True, check=True).stdout.split()
    except (OSError, subprocess.CalledProcessError):
        tracked = None   # not a git checkout (e.g. a release tarball)
    have = set(tree_paths())
    gone = sorted(p for p in have if not (ROOT / p).is_file())
    if tracked is None:
        # Without git we can't tell docs from other .md files on disk (model cards,
        # tool READMEs when the data root is the repo), so only check the tree's own paths.
        return [], gone
    want = {p for p in tracked if not re.search(r'(^|/)AGENTS\.md$|^\.github/|^\.agents/(skills|knowledge)/', p)}
    want.add('AGENTS.md')
    return sorted(want - have), gone

def render_tree(theme):
    t = THEMES[theme]
    nodes, links = [], []
    rows = [0]

    colours = iter(range(len(ACCENTS) * 4))

    def place(node, depth, branch):
        label, path, kids = node
        # each top-level branch, and each big sub-branch (3+ pages), gets its own colour
        own = [next(colours) if depth == 0 or len(k[2]) >= 3 else branch for k in kids]
        ys = [place(k, depth + 1, c) for k, c in zip(kids, own)]
        if kids:
            y = (ys[0] + ys[-1]) / 2
        else:
            y = TREE_TOP + rows[0] * TREE_ROW
            rows[0] += 1
        nodes.append((depth, y, label, path, branch, bool(kids)))
        links.extend((depth, y, ky, c) for ky, c in zip(ys, own))
        return y

    place(DOC_TREE, 0, 0)
    h = TREE_TOP + rows[0] * TREE_ROW + 30
    title = 'Val Ark: every page, as a tree'
    desc = ('A map of every Val Ark guide as a branching tree, four levels deep: the README leads to '
            'the docs map, the workshop guides, the policies and the AI-agent manuals; the docs map '
            'branches into the guides, the design hierarchy and the knowledge base. Branches draw '
            'in level by level.')
    css = f"""
.nd{{font:600 13px system-ui,-apple-system,'Segoe UI',sans-serif;fill:{t['ink']}}}
.pa{{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;fill:{t['muted']}}}
.ch{{font:700 12px system-ui,sans-serif;letter-spacing:.22em;fill:{t['tab']};text-transform:uppercase}}
.tt{{font:italic 600 30px Georgia,'Times New Roman',serif;fill:{t['ink']}}}
.st{{font:16px system-ui,sans-serif;fill:{t['muted']}}}
.br{{fill:none;stroke-width:2;stroke-linecap:round;stroke-dasharray:1;animation:draw 0.7s ease-out both}}
.pop{{transform-box:fill-box;transform-origin:0 50%;animation:pop .55s cubic-bezier(.3,1.4,.5,1) both}}
@keyframes draw{{from{{stroke-dashoffset:1}}to{{stroke-dashoffset:0}}}}
@keyframes pop{{from{{transform:scaleX(.05);opacity:0}}to{{transform:none;opacity:1}}}}
@media (prefers-reduced-motion:reduce){{*{{animation:none!important}}}}
"""
    p = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {h}" width="{W}" height="{h}" role="img" '
         f'aria-label="{esc(title)}"><title>{esc(title)}</title><desc>{esc(desc)}</desc>',
         f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{t["bg0"]}"/>'
         f'<stop offset="1" stop-color="{t["bg1"]}"/></linearGradient></defs><style>{css}</style>',
         f'<rect width="{W}" height="{h}" rx="18" fill="url(#bg)"/>',
         f'<rect x="24" y="96" width="{W-48}" height="{h-112}" rx="14" fill="{t["page"]}" stroke="{t["edge"]}"/>',
         f'<text x="64" y="44" class="ch">The Map</text><text x="64" y="80" class="tt">Every page, as a tree</text>'
         f'<text x="{W-64}" y="44" class="st" text-anchor="end">Start at the left and follow a branch to any guide.</text>']
    for depth, py, cy, b in links:
        x0 = TREE_COLS[depth][0] + TREE_COLS[depth][1]
        x1 = TREE_COLS[depth + 1][0]
        mx = (x0 + x1) / 2
        p.append(f'<path d="M{x0} {py:.1f}C{mx:.1f} {py:.1f} {mx:.1f} {cy:.1f} {x1} {cy:.1f}" pathLength="1" class="br" '
                 f'stroke="{ACCENTS[b % len(ACCENTS)]}" style="animation-delay:{0.2 + depth * 0.45:.2f}s"/>')
    for depth, y, label, path, b, inner in sorted(nodes, key=lambda n: (n[0], n[1])):
        x, w = TREE_COLS[depth]
        acc = t['tab'] if depth == 0 else ACCENTS[b % len(ACCENTS)]
        fill = acc if inner else t['card']
        ink = '#fff' if inner else t['ink']
        body = (f'<rect x="{x}" y="{y-10:.1f}" width="{w}" height="20" rx="10" fill="{fill}" stroke="{acc}" stroke-width="1.5"/>'
                f'<text x="{x+12}" y="{y+4.5:.1f}" class="nd" style="fill:{ink}">{esc(label)}</text>')
        if path and not inner:
            body += f'<text x="{x+w+14}" y="{y+4.5:.1f}" class="pa">{esc(path)}</text>'
        p.append(f'<g class="pop" style="animation-delay:{0.1 + depth * 0.45 + (y / h) * 0.3:.2f}s">{body}</g>')
    p.append('</svg>\n')
    return ''.join(p)

def build():
    files = {f'{sid}-{theme}.svg': render(sid, spec, theme) for sid, spec in SCENES.items() for theme in THEMES}
    files.update({f'docs-tree-{theme}.svg': render_tree(theme) for theme in THEMES})
    return files

def main(argv):
    files = build()
    if '--list' in argv:
        for sid, spec in SCENES.items():
            print(f"{sid}\t{', '.join(spec['used'])}")
        return 0
    if '--check' in argv:
        bad = [n for n, body in files.items() if not (OUT / n).is_file() or (OUT / n).read_bytes() != body.encode()]
        extra = sorted(p.name for p in OUT.glob('*.svg') if p.name not in files) if OUT.is_dir() else []
        for n in bad:
            print(f'stale or missing: docs/img/popup/{n}')
        for n in extra:
            print(f'not produced by the generator: docs/img/popup/{n}')
        unused = [(sid, md) for sid, spec in SCENES.items() for md in spec['used']
                  if f'popup/{sid}-light.svg' not in ((ROOT / md).read_text(errors='replace') if (ROOT / md).is_file() else '')]
        for sid, md in unused:
            print(f'{md} is listed in used= for {sid} but does not embed it')
        missing, gone = tree_missing()
        for n in missing:
            print(f'not on the docs tree (DOC_TREE in scripts/docs/popup_art.py): {n}')
        for n in gone:
            print(f'on the docs tree but missing: {n}')
        if bad or extra:
            print('run: python3 scripts/docs/popup_art.py')
        if bad or extra or missing or gone or unused:
            return 1
        print(f'ok: {len(files)} pop-up SVGs match the generator')
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for n, body in files.items():
        (OUT / n).write_bytes(body.encode())  # LF on every OS, so --check is exact
    print(f'wrote {len(files)} SVGs to docs/img/popup/')
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
