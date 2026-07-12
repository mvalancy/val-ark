# Val Ark — Product Vision

Part of the [design hierarchy](README.md). Read [current-state.md](current-state.md) first.

## The one-liner

**Val Ark is a knowledge-and-comms appliance for when the internet isn't there.**
Plug it in, follow a few friendly screens, and your home/community has offline
Wikipedia, AI helpers, software, and private chat/mail/boards — set up and managed as
easily as a Wi-Fi router, kept healthy by the box itself.

## The person we build for

> "Assume I have no idea at all how to use this."

Meet **Jordan** — capable, not technical. Jordan can set up a router by following the
app, uses a fitness app daily, and has *heard* of GitHub but couldn't explain it.
Jordan wants a box that keeps Wikipedia, some AI help, and a way to talk to family
around them when the power or internet is out. Jordan will **never** open a terminal,
edit a config file, or read a log. If something breaks, Jordan expects the device to
either fix it or tell them, in plain words, what to tap.

Everything in this design is measured against Jordan. If a step needs a keyboard
command, a file path, or a word like `iptables`, it has failed — we hide it or automate it.

## Jobs to be done

1. **"Set it up."** From a fresh box to a working Ark, in a few taps, on a browser or the box's own screen.
2. **"Get what I care about."** Pick topics/apps in plain language; the box downloads the right things in the right order.
3. **"See that it's working."** A calm home screen that says *good / needs attention*, with progress for anything downloading.
4. **"Let the right people in."** Decide who can use it and who can change it — or leave it open for the household.
5. **"Get back in."** Recover from a forgotten password or a lockout without wiping anything.
6. **"Give one to a neighbor."** Copy the whole thing to another box over the LAN, offline.
7. **"Fix it when it hiccups."** Understand a problem in one sentence and tap **Repair** — or have it already fixed.

## Experience pillars

- **A calm home screen, not a control panel.** Like a health app's summary: one status, a few big cards ("Library ready," "AI ready," "3 downloads"), details a tap away.
- **Guided, never blank.** Wizards and defaults over empty forms. The box always suggests the next best action.
- **Plain language everywhere.** "How much space Val Ark can use" not `VALARK_MAX_GB`; "Who can get in" not "auth policy."
- **Progressive disclosure.** Simple by default; an "Advanced" drawer holds the power-user knobs (which still exist for the CLI crowd).
- **The box is the expert.** Baked-in intelligence: smart defaults, self-healing, and an **offline AI assistant** that can literally answer "how do I…" and even trigger the fix.
- **Honest and reassuring.** Never a stack trace; never fake-green. "Here's what's wrong and what I'm doing about it."
- **Offline-first and local.** Every screen works with no internet, on the LAN, or on a monitor plugged into the box.

## "Intelligence baked in" — what that means concretely

- **Smart commissioning:** auto-detect the biggest disk, a sensible cap, a good default topic set, and offer to enable port 80 — all pre-filled, all changeable.
- **Self-healing:** the loop already repairs links, restarts services, verifies content; the UI surfaces this as "handled it for you," and escalates only real decisions.
- **The assistant is a first-class helper:** a small on-box LLM (already prioritized in curation) paired with the Linux/setup docs, wired into a "Ask Val Ark" affordance so a stuck user gets an answer — and, where safe, a button to apply it.
- **Guardrails over gates:** dangerous actions are guarded (confirm, cap-aware, reversible), not hidden behind expertise.

## What success looks like

- Jordan unboxes, plugs in, opens `http://valark.local/` (or the on-screen setup), and is done in under 5 minutes with zero jargon.
- A week later Jordan checks the home screen, sees "All good · Library 92% full," and closes the tab.
- Jordan forgets the password, taps "I'm locked out," follows a safe local reset, and is back in.
- When a download stalls, the box shows "Retrying — poor connection to source," fixes itself, and Jordan never had to know.

The following docs specify how each pillar is realized — grounded in how the best
comparable products do it (see [research-brief.md](research-brief.md)).
