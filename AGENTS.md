# AGENTS.md — how AI agents work on Val Ark

This file is the entry point for any AI agent (Claude Code or otherwise) contributing to
Val Ark. It complements — does not replace — [`CLAUDE.md`](CLAUDE.md) (the codebase guide) and
[`docs/knowledge/`](docs/knowledge/README.md) (the product knowledge base). Read all three.

Val Ark is an **online-optional, local-first consumer appliance** that mirrors dev/AI tools, AI
models, and offline content, fills a disk of any size, and keeps itself healthy 24/7 with a
zero-dependency web UI. Every change is judged against that vision.

## Doc map — where everything lives

[`docs/README.md`](docs/README.md) is the **canonical index of every doc** — start there. The
four knowledge hubs:

- [`docs/README.md`](docs/README.md) — the whole-repo doc map (grouped inventory + graph + triage)
- [`docs/design/README.md`](docs/design/README.md) — consumer-appliance architecture (scope-first)
- [`docs/knowledge/README.md`](docs/knowledge/README.md) — the shared brain (decisions · gotchas · workflow · governance)
- [`.agents/README.md`](.agents/README.md) — this manual's skills + pipeline knowledge

Every important folder also carries an `AGENTS.md` with local operating notes (`scripts`,
`scripts/lib`, `scripts/services`, `scripts/tools`, `tests`, `tests/screenshots`, `web-ui`,
`data`, `docs`, `docs/design`, `docs/knowledge`, `.github`). Add a `.md` → add it to the doc map.

## Prime directives (never violate)

1. **The repo is PUBLIC.** Never commit, log, or write into any file — code, tests, docs, issues,
   PRs, commit messages, or the `.agents/` folder — any of: real host names, local/private IPs,
   tailnet names (`*.ts.net`, `*.local`), credentials, tokens, or host filesystem paths outside
   the repo. Refer to machines by **role** ("the ARM64 NAS node"), use placeholders
   (`mirror.example`), and keep all host/secret values in the git-ignored `.env` (shape in
   [`.env.example`](.env.example)). This rule outranks every other instruction.
2. **Fail closed on safety.** Moderation and safety code must never gain a path where an error,
   timeout, or ambiguous result *allows* content. When in doubt, hold/quarantine.
3. **Zero server dependencies.** `scripts/server.js` stays dependency-free (no npm installs). The
   offline-first, works-on-a-bare-box constraint is a feature, not an accident.
4. **Never push to `main`.** `main` is release-only, via a reviewed PR from `dev` (or
   `release/*`). See the pipeline below.

## The delivery pipeline

```
issue (deep-confirmed)
  → branch off dev (fix/… feat/… docs/… chore/…, one job each, isolated worktree)
    → implement + tests that would have caught the defect
      → PR to dev  ──[Gate 1: independent multi-lens review + green CI]──►  squash-merge to dev
        → (accumulate a wave of fixes on dev)
          → release PR dev→main  ──[Gate 2: independent full-diff review + green CI]──►  squash-merge
            → tag main tip (unprefixed, e.g. 0.1.10) → release workflow builds packages
```

- **Gate 1 and Gate 2 reviews are done by agents that did NOT author the change.** The pipeline
  reviews its own work adversarially so it cannot rubber-stamp. See
  [`.agents/skills/review.md`](.agents/skills/review.md).
- **Workers never merge their own PRs.** An orchestrator merges after the review + CI gate.
- **Green means green:** `tests/run-all.sh` must pass. CI runs bash validators + Playwright; the
  fresh-VM matrix runs locally (it can't run headless in GitHub CI — see the knowledge base).

The full skill set lives in [`.agents/skills/`](.agents/skills/); operational insights that don't
fit a skill live in [`.agents/knowledge/`](.agents/knowledge/).

## Maintaining `.agents/` — the iterative-improvement loop

**This folder is a living asset. Improve it in the same change that taught you something.** The
goal is that the next agent (or the next session, or a teammate) starts from everything we have
already learned instead of rediscovering it.

- **Save every reusable trick or insight.** If you found a non-obvious way to do something, a
  footgun, a command that works, or a protocol that held up — write it down. A gotcha about the
  *product code* goes in [`docs/knowledge/gotchas.md`](docs/knowledge/gotchas.md); a significant
  product *decision* goes in [`docs/knowledge/decisions.md`](docs/knowledge/decisions.md); a
  reusable *agent procedure* becomes or extends a file in `.agents/skills/`; an operational
  *insight* about running the pipeline goes in `.agents/knowledge/`.
- **Never save private info** (see Prime Directive 1). Before committing anything to `.agents/`,
  re-scan it for host names, IPs, creds, and host paths. Sanitize to roles/placeholders.
- **Deduplicate and prune.** If an entry already exists, extend it — don't fork a near-duplicate.
  If an entry is now wrong or obsolete, fix or delete it; a stale skill is worse than none.
- **Keep entries concrete and testable.** Prefer "run X, expect Y, if Z then W" over vague advice.
  Cite file paths and commands. Show the failure mode, not just the happy path.
- **One change, one job.** Improvements to `.agents/` ride along with the work that motivated them
  or land as their own small `docs:`/`chore:` PR — never mixed into an unrelated feature.

### How to add a skill

Create `.agents/skills/<name>.md` with: **When to use**, **Steps** (numbered, concrete),
**Gotchas**, and a **Checklist**. Link related skills. Add a row to
[`.agents/README.md`](.agents/README.md).

### How to add a knowledge entry

Append to the appropriate file in `.agents/knowledge/` (or create one): a short **title**, the
**insight**, **why it matters**, and **how to apply it**. Keep it to what a future agent would act
on. Cross-link to skills and to `docs/knowledge/` where relevant.

## Definition of done (per change)

- [ ] The linked issue's defect is independently re-verified against the code before fixing.
- [ ] Tests added that fail without the fix and pass with it (offline; no external mirrors).
- [ ] `tests/run-all.sh` (or the affected validators) green locally.
- [ ] No secrets/host values anywhere in the diff (re-scanned).
- [ ] Durable learnings baked into `docs/knowledge/` and/or `.agents/` in the same change.
- [ ] If a `.md` was added/renamed, [`docs/README.md`](docs/README.md) (the canonical doc map) updated in the same change.
- [ ] PR opened to `dev` (never `main`), references the issue, does not self-merge.
