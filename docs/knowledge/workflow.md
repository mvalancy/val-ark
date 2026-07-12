# Val Ark — Development Workflow & Git Strategy

Part of the [knowledge base](README.md). The rules for how work flows through git so it stays
**well‑traced** (every change tracks back to a reason) while **disparate jobs run in parallel**
without stepping on each other. Applies to humans and AI agents alike.

## Branch model (three tiers)

```
main   ← always releasable · protected · tagged releases        (never push directly)
  ↑ PR (reviewed, green, release‑ready)
dev    ← integration · always green · the default PR target
  ↑ PR (focused, green)
feat/… fix/… docs/… chore/…   ← one job each · branch off dev · where parallel work happens
```

| Branch | Purpose | Push directly? | Merges via |
|--------|---------|----------------|-----------|
| **`main`** | Always releasable; source of tagged releases. The self‑replication mirror serves the tagged release. | **Never.** | reviewed PR from `dev` (or `release/*`), tests green |
| **`dev`** | Integration line; must stay buildable + green. | Prefer PR; small trivial commits OK by the maintainer. | PR from a work branch |
| **`feat/<slug>`** *(also `fix/ docs/ chore/ refactor/ test/`)* | **One** job/topic; isolated so N of them run in parallel. | Yes — it's your branch. | PR into `dev` |
| **`hotfix/<slug>`** | Urgent production fix. | Own branch off `main`. | PR to `main` **and** back‑merge to `dev` |

Name branches after the ticket: `feat/123-commission-wizard`, `fix/145-download-405`.

## Tickets → branches → PRs → commits (the tracing chain)

1. **Every non‑trivial job = a GitHub issue** stating the goal + "done when …". Label it
   (area + priority); large efforts get a tracking issue with sub‑issues.
2. **Branch off `dev`, named for the issue.** One job per branch.
3. **Commits** reference the issue (`… (#123)`), imperative subject, *why* in the body, and end
   with the `Co-Authored-By: Claude …` trailer.
4. **PR into `dev`** links the issue (`Closes #123`), describes scope + what changed, and attaches
   **test evidence** (the offline report / `tests/run-all.sh` result). Keep PRs focused.
5. On merge → the issue closes; `decisions.md` gets an entry for anything architecturally
   significant.

Result: any commit traces to a PR → an issue → a reason; any issue traces to its branch, PR, and
the decisions it produced.

## When can we merge where? (repo rules)

- **`feature → dev`:** when the job is complete, **tests pass**, and it's a focused, reviewed PR.
  Squash‑merge (clean, one commit per job) unless the branch's own history is worth keeping.
- **`dev → main`:** only when `dev` is green and we're cutting a release — a reviewed release PR.
  Then tag (`scripts/release.sh <ver>`); `main` is what the mirror replicates.
- **Nobody pushes to `main` directly.** Hotfixes are the only fast path, and still go via PR +
  back‑merge to `dev`.
- **Green means green:** `tests/run-all.sh` (bash + Playwright + services e2e; VM matrix for
  release PRs) must pass before a merge to `dev`/`main`.

## Parallelizing disparate jobs (without collisions)

- **One job = one branch off `dev`.** Independent jobs (e.g. "commissioning wizard" vs. "storage
  pool" vs. "docs") proceed simultaneously on their own branches.
- **Use git worktrees** for concurrent local/agent work: `git worktree add ../valark-<slug>
  feat/<slug>` — each agent gets an isolated checkout; no shared dirty tree.
- **Rebase/merge `dev` frequently** to stay current and shrink final conflicts.
- **Minimize overlap:** avoid two live branches heavily editing the same file (e.g. the big
  `web-ui/index.html` or `server.js`); if unavoidable, split the work along clear seams or
  sequence the merges. Coordination notes for fleet/parallel agents live under
  `<data>/val-ark/state/coordination/` (the loop reads them) — those agents **don't push to git**.
- **Agents claim before they start:** open/assign the issue so two agents don't take the same job.

## Secrets & config (never in git — see [[val-ark-secrets-hygiene]])

- **Host‑specific values** (host names, local IPs, creds, host paths) go ONLY in the **git‑ignored
  `.env`**; the **git‑tracked `.env.example`** documents the keys/shape with placeholders.
- Never paste secrets/IPs/hostnames into commits, PRs, docs, issues, or memory. Refer to machines
  by role.

## The hierarchy, mapped

```
CLAUDE.md                     ← rules + "how to add a tool" + pointers (auto‑loaded every session)
docs/design/                  ← product/system architecture (the consumer‑appliance scope)
docs/knowledge/
  README.md                   ← how we keep this base current
  workflow.md                 ← THIS FILE — git/branch/PR/parallelization strategy
  gotchas.md                  ← operational hard‑won fixes
  decisions.md                ← significant decisions + progress log
docs/*.md                     ← reference docs (ARCHITECTURE, COMMUNITY, PLATFORMS, …)
.env.example (git)  ·  .env (git‑ignored, per‑box secrets)
```

> Current state: PR #1 (`feature/discover-request-community`) currently targets `main` — per this
> strategy a large branch like it should land on **`dev`** first, then `dev → main` at a release.
> Retarget it to `dev` (or merge to `dev`) to adopt the model going forward.
