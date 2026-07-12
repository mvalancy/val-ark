# Val Ark — Knowledge Base (agents bake learnings here)

This directory is the **git‑tracked, shared brain** for anyone (human or AI agent) working
on Val Ark. Unlike a single assistant's private session memory, everything here travels with
the repo — so learnings **compound across sessions, machines, and teammates** instead of
being relearned (or lost) each time.

## The rule (read this, then keep it true)

> **When you learn something durable, write it down here — in the same change that acts on it.**
> A non‑obvious gotcha, a decision and *why*, a fix that isn't self‑evident from the diff, a
> platform quirk: it belongs in git, not just in one session's head.

Where things go:

| Kind of knowledge | Home | Loaded every session? |
|-------------------|------|-----------------------|
| **Rules, architecture, "how to add X"** | [`CLAUDE.md`](../../CLAUDE.md) | ✅ (auto‑loaded) |
| **Product/system architecture** | [`docs/design/`](../design/README.md) | on demand |
| **Git / branch / PR / parallelization strategy** | [`workflow.md`](workflow.md) | on demand |
| **Self‑guided agent governance, CI & trust model** | [`governance.md`](governance.md) | on demand |
| **Operational gotchas & hard‑won fixes** | [`gotchas.md`](gotchas.md) | on demand |
| **Significant decisions + progress log** | [`decisions.md`](decisions.md) | on demand |
| **Host‑specific values (IPs, names, creds, paths)** | git‑ignored `.env` (shape in `.env.example`) | never in git/memory |
| **Personal / ephemeral working notes** | your assistant's session memory | per‑user only |

`CLAUDE.md` is the front page — it points here, so every session discovers the base.

## How agents keep it current (the "continually bake in" mechanism)

1. **At the end of substantial work**, before you're done: update the relevant file here.
   - New durable rule / pattern → add it to `CLAUDE.md`.
   - A gotcha that cost you time → add it to `gotchas.md` (symptom → cause → fix).
   - An architecturally significant choice → append to `decisions.md` (context → decision → why).
   - Design scope changes → edit `docs/design/`.
2. **Prefer editing an existing entry** over adding a duplicate; delete entries that become wrong.
3. **Keep it terse and true.** One fact per entry, the *why* included.
4. **NEVER store secrets or host‑specific values** — host names, local IPs (LAN/tailnet), creds,
   or host paths (`/mnt/…`, `/data_…`). They belong in the **git‑ignored `.env`** (keys/shape in
   the **git‑tracked `.env.example`**), never in git, docs, PRs, issues, or session memory. Refer
   to machines by role ("the ARM64 NAS node"), use placeholders (`<ark-host>`, `<data>`). The repo
   is PUBLIC.
4. **Commit the knowledge with the code** it describes, so history stays coherent.

Session‑private, per‑user notes still belong in an assistant's own memory; this base is only
for what's worth **sharing and version‑controlling**.

## Want shared custom agents / slash‑commands too?

`.claude/` is git‑ignored today (it also holds local settings). To share project‑specific
subagents or commands, un‑ignore just those paths — add to `.gitignore`:

```
!.claude/agents/
!.claude/commands/
```

…and keep `.claude/settings.local.json` ignored. Then `.claude/agents/*.md` and
`.claude/commands/*.md` become part of the repo. (Not done yet — this is the switch to flip
if/when we author shared agents.)
