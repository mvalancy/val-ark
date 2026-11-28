<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/popup/how-it-works-dark.svg">
  <img src="img/popup/how-it-works-light.svg" width="100%" alt="Pop-up book scene: How it works, in pictures. Ten moving pictures, in reading order, from one disk to a whole network.">
</picture>

# Val Ark — How It Works, in Pictures

[Back to Docs](README.md) | [Back to Project Root](../README.md)

Ten short chapters, one picture each, and every picture moves. The first six are storybook
scenes; the rest are diagrams whose dots travel along the arrows to show what flows where. Each
chapter links to the guide that goes deeper, where the precise diagram lives.

## 1. The whole thing on one page

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/story/voyage-dark.svg">
  <img src="img/story/voyage-light.svg" width="100%" alt="Storybook scene: One Ark, end to end. A landscape. On the left a cloud, the internet while it lasts, rains books (Wikipedia and more), AI models, and apps and installers into an ark on a hill. On the Ark the Librarian picks what fits, one disk holds it all, and the loop mends it every 30 minutes. A road leads down to a village, your network, which gets the web UI in any browser and plain pages on a file share, with no internet needed.">
</picture>

An Ark is one computer with one big disk. It downloads things once while it has internet: reference libraries like Wikipedia, AI models, apps and installers. Then it keeps them healthy and shares them with everyone nearby, internet or not.

**More:** [Architecture](ARCHITECTURE.md)

## 2. Filling the disk

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/story/hold-dark.svg">
  <img src="img/story/hold-light.svg" width="100%" alt="Storybook scene: Filling the hold. A ship's hold in cutaway, filling from the keel up. 1: grid-down essentials (water, medicine, a pocket Wikipedia, a tiny assistant). 2: apps and tools, mirrored next, each within a share of the space. 3: the library (Wikipedia and other ZIMs, Lastbook's books and maps, installers). 4: AI models, after the whole library is planned. The top stays empty: the reserve, by default 2% of the disk or 50 GB, whichever is larger. A crane lowers crates in: one of each kind first, then the most value per byte. Ask for something specific and, if it needs room, the least valuable unpinned item is removed.">
</picture>

The Librarian decides what fits. Grid-down essentials come first, the tiny offline assistant included. Then apps (the tool mirror and the developer stack), then the library (Wikipedia and the other ZIMs, Lastbook's books and maps, the installers), and only then more AI models, then bulk data. Inside each of those it takes one of each kind, then the small and valuable, then big flagships, until the disk reaches its reserve. The loop also runs its weekly app mirrors (the tool mirror and the developer stack) before the top-up fill, so apps never wait behind models. Filling never evicts anything (it only drops a smaller copy once a fuller version of the same item is on disk); making room for something else only happens when someone asks for it.

**More:** [The Librarian](LIBRARIAN.md)

## 3. Keeping it healthy

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/story/watch-dark.svg">
  <img src="img/story/watch-light.svg" width="100%" alt="Storybook scene: The night watch. A watchman with a lantern walks a wall of twelve towers every 30 minutes and after every reboot, lighting each as it is checked: Disk check (mounted, writable); Repair layout (folders, symlinks); Keep it up (server, apps, network); Copy itself (for new nodes); Refresh (live catalogs); Fix dead links (tool, installer URLs); Check files (sizes, re-fetch short); Update apps (tools, dev stack); Top up (essentials, library, models); Does it run? (tools, LLM, API, UI); Safety sweep (new uploads); Report (Health page, events).">
</picture>

Every 30 minutes, and after a reboot, the loop walks the same round: check the disk, repair the layout, keep the web server and apps up, copy its own source for new machines, refresh catalogs, fix dead links, check files, update apps, top up, test that things run, sweep new uploads, and report what it did.

**More:** [The self-healing loop](ARCHITECTURE.md#self-healing-loop)

## 4. Two ways to open it

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/story/book-dark.svg">
  <img src="img/story/book-light.svg" width="100%" alt="Storybook scene: Two ways in. An open book. Left page, the side door: the Librarian writes plain HTML pages onto the data disk; open them on any device from an SMB or NFS share or a USB stick, with no server needed; read-only, to browse the catalog and copy what you need. Right page, the front door: with the Ark switched on, its web server shows the whole library in a browser to phones and laptops nearby; request more, chat, send mail, ask the assistant; open to your LAN and tailnet, never to the internet. Both work with no internet at all.">
</picture>

The same disk can be read two ways. Static pages need nothing but a file share. The live web server adds the library reader (Wikipedia and friends, with full-text search), requests, chat and mail. Use either, or both at once.

**More:** [Serving: static or dynamic](SERVING.md)

## 5. Asking for something new

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/story/strip-dark.svg">
  <img src="img/story/strip-light.svg" width="100%" alt="Storybook scene: One tap, four panels. A four-panel comic strip. 1: You tap Request (on any device nearby): one tap, on something, the Ark does not have yet. 2: Three questions (the web server checks first): on the LAN or tailnet?, within the rate limit?, allowed by the Use Mode?. 3: Pinned, then fitted (the librarian takes the job): pinned: never evicted, room is made only if it won't fit. 4: It lands (watch it on the activity page): resumable, size-checked, the loop keeps it there.">
</picture>

Tap Request on any device on the network. The server checks who you are and what you asked for, the Librarian pins it and makes room only if it won't fit, and the Activity page shows the download as it happens.

**More:** [Downloads and monitoring](design/downloads-monitoring.md)

## 6. Who can do what

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/story/island-dark.svg">
  <img src="img/story/island-light.svg" width="100%" alt="Storybook scene: The island and the sea. A map of an island. In the middle a keep: the box itself, always the Admin. Around it, inside a wall, your network (the LAN and your tailnet): people browse and read the whole library and request more with one tap, if the Use Mode allows; the admin passcode opens the keep for settings, repair and moderation. Outside the wall is the sea, the internet: ships come near and are refused, with no reads and no changes. A sign gives the Use Mode: Open, Passworded or Accounts; the Admin chooses who gets in, and a new box starts Open.">
</picture>

The box itself is always the Admin. People on your network get what the Use Mode allows: open to everyone, or behind a passcode. The internet gets no library and can change nothing.

**More:** [Access and identity](design/access-identity.md)

## 7. Setting up a new box

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/flow/setup-dark.svg">
  <img src="img/flow/setup-light.svg" width="100%" alt="Animated diagram: Setting up a new box. A few screens in a browser. Then the 24/7 loop fills the disk on its own.">
</picture>

A few screens in a browser: name the box, optionally set a passcode, pick a focus, and save the recovery card. Then the 24/7 loop fills the disk on its own, once it is installed (`./scripts/loop.sh install 30`).

**More:** [First-boot setup](design/commissioning.md)

## 8. The village square

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/flow/community-dark.svg">
  <img src="img/flow/community-light.svg" width="100%" alt="Animated diagram: The village square. Chat, mail, boards and file drops run on the box and open inside the web UI.">
</picture>

Chat, mail, message boards and a file drop run on the box and open inside the web UI. Turn them on in `.env`, and the loop keeps them running.

**More:** [Community and comms](COMMUNITY.md)

## 9. Keeping shared files safe

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/flow/moderation-dark.svg">
  <img src="img/flow/moderation-light.svg" width="100%" alt="Animated diagram: Keeping shared files safe. Files in the uploads folder are checked on the box by a local model. Doubtful ones wait for the Admin.">
</picture>

Files in the uploads folder are checked on the box by a local model, with nothing sent anywhere. Anything flagged or uncertain is set aside until the Admin reviews it.

**More:** [Safety and moderation](design/safety-moderation.md)

## 10. One Ark, many machines

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="img/flow/fleet-dark.svg">
  <img src="img/flow/fleet-light.svg" width="100%" alt="Animated diagram: One Ark, many machines. Share one Ark across the LAN, or set up new ones from it, without the internet.">
</picture>

Other machines can share one Ark over the network: mount its models, sync a copy, or browse a file share. A new machine can even install Val Ark from an Ark, with no internet at all.

**More:** [Offline and P2P](OFFLINE.md)

---

The pictures are drawn by [`scripts/docs/flow_art.py`](../scripts/docs/flow_art.py) and checked
against the code; see [Pop-up art](AGENTS.md#pop-up-art-the-chapter-scenes) to add one.
