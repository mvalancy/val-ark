# docs/knowledge/ — the product knowledge base

The git-tracked "why" of Val Ark — gotchas, decisions, and the rules of how work flows. Route each learning to the right file and bake it in the same change that taught it.

↑ [Repo root](/AGENTS.md) · [Doc map](/docs/README.md)

This is the **product** knowledge base (the "why" half of the shared brain): what the code does and why it's built that way. It is distinct from [`.agents/`](../../.agents/README.md) — the "how I run the pipeline" half (the agent procedures and operational insight). [README.md](README.md) is the hub (owned elsewhere — link it, don't restructure it).

## What's here

| File | Holds | Shape |
|------|-------|-------|
| [gotchas.md](gotchas.md) | Code/ops gotchas & hard-won fixes | symptom → cause → fix, grouped by area |
| [decisions.md](decisions.md) | Architecturally significant decisions + progress log | context → decision → why, newest first |
| [workflow.md](workflow.md) | Git / branch / PR / parallelization strategy | rules |
| [governance.md](governance.md) | Self-guided agent governance, CI & trust model | rules |

## Where does this learning go? (route table)

| You have… | It goes in… |
|-----------|-------------|
| A symptom → cause → fix (a footgun that cost you time) | [gotchas.md](gotchas.md) |
| A context → decision → why (an architecturally significant call) | [decisions.md](decisions.md) |
| A new durable **rule / pattern** every session must know | [../../CLAUDE.md](../../CLAUDE.md) |
| A change to **git flow** (branching, PRs, releases) | [workflow.md](workflow.md) |
| A change to **trust / CI / the agent loop** | [governance.md](governance.md) |

## How to work here

- **The logs are append-only history — never reorder or rewrite past entries.** Add a new entry (in [decisions.md](decisions.md) it goes at the **top**, newest-first; in [gotchas.md](gotchas.md) under the right area section). Correcting an obsolete entry is fine; silently rewriting history is not.
- **Add a matching TOC / index row when you append** so the entry is discoverable.
- **Use a DISTINCT anchor** (`<a id="...">`) for each new entry — parallel workers appending at once will merge-conflict on a shared or positional anchor.
- **Prefer editing an existing entry over forking a near-duplicate**; delete an entry that becomes wrong.

## Gotchas

- **Never write host names, local IPs, tailnet names, creds, or host paths — this outranks every other rule here.** The repo is PUBLIC. Refer to machines by role ("the ARM64 NAS node"), use placeholders; real values live only in the git-ignored `.env`. Re-scan before you commit.
- **A wrong "now safe" note is worse than none.** A gotcha or decision that claims something is fixed/safe when it isn't gives false confidence and gets trusted downstream — verify against the code before writing "resolved" (see #121 / #123). If unsure, say what's unverified.
- **This base is for shared, version-controlled knowledge only** — session-private, per-user notes belong in your assistant's own memory, not in git.

## Related

- [../../.agents/README.md](../../.agents/README.md) — the agent procedures & operational insight that **implement** [governance.md](governance.md)'s loop (the "how", to this base's "why").
- [../design/AGENTS.md](../design/AGENTS.md) — product design intent; durable design calls land back here in [decisions.md](decisions.md).
- [../AGENTS.md](../AGENTS.md) — the top-level guide/reference set.
