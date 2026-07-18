# Skill: worker-protocol — implement one issue as a reviewable PR

## When to use
You are assigned one issue (or a small stacked chain) to fix. You are a *worker*: you produce a
PR; you never merge it.

## Steps
1. **Read the context first.** `CLAUDE.md`, `AGENTS.md`, `docs/knowledge/workflow.md`, and
   `gh issue view <n>` (the ticket carries file:line evidence + review notes).
2. **Re-verify the defect against the real code before writing a fix.** Read the cited lines;
   reproduce the failure scenario mentally or with a probe. If the ticket is wrong or already
   fixed, comment your findings on the issue and stop — do not force a fix.
3. **Work in an isolated worktree** off the latest `dev`: `git fetch origin dev` then branch
   `fix/<n>-<slug>` (or `feat/…`, `docs/…`, `chore/…`) from `origin/dev`. One job per branch.
4. **Implement the minimal correct fix.** Honor the ticket's adversarial-review scope notes — no
   over-engineering, no unrelated changes. Preserve the prime directives (fail-closed, zero-dep
   server, no secrets).
5. **Add tests that fail without the fix and pass with it.** Offline only — stub network/binaries
   via PATH shims or injected fixtures (see how `tests/test-*.sh` do it); never hit real mirrors,
   real data disks, or the real crontab. Run the affected validators to green.
6. **Bake durable learnings** into `docs/knowledge/gotchas.md`/`decisions.md` and/or `.agents/`
   in the same change. Use a distinct doc anchor to avoid merge conflicts with parallel workers.
7. **Commit** with a conventional message referencing the issue, ending with the `Co-Authored-By:`
   trailer for your model.
8. **Push and open a PR to `dev`** (never `main`): title conventional; body = what was broken (one
   paragraph), the fix, tests added, `Fixes #<n>`, and the Claude Code footer. Do NOT merge.
9. **Report** back structured facts: PR URL, one-sentence fix, exact test counts, discoveries/risks
   for the orchestrator (interactions with other in-flight work especially).

## Gotchas
- **Stacked chains:** when several issues touch the same file, branch each on the previous
  (`#52` off the `#51` branch), state the merge order in each PR body, and force-push only your
  own feature branches with `--force-with-lease`.
- **`dev` moves under you.** If another PR merges to `dev` mid-task, `git fetch` and rebase your
  base branch; resolve doc-anchor overlaps by keeping both entries in issue order.
- **Commit and push before you stop** — even WIP (clearly marked). A session restart or usage-limit
  can kill you mid-task; pushed work survives, unpushed work is lost. See
  [`recovery.md`](recovery.md).
- **Parallel port clashes:** if a test starts the server, export a unique `VALARK_WEB_PORT`.

## Checklist
- [ ] Defect independently re-verified against code
- [ ] Minimal fix, in-scope, prime directives intact
- [ ] Fail-without / pass-with tests, offline
- [ ] Affected validators green locally
- [ ] Learnings baked into docs/`.agents/`; no secrets in diff
- [ ] PR to `dev`, references issue, not self-merged
- [ ] Committed + pushed before stopping
