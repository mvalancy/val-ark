# Skill: release — cut and tag a `dev → main` release

## When to use
`dev` is green and carries a wave of reviewed fixes/features; you are shipping a versioned release
to `main`.

## Background: main's history model
`main` is a series of **squash "Release X.Y.Z" commits** (one per release). Because of that, the
git **merge-base between `main` and `dev` is ancient** — every past release squashed dev's many
commits into one, so the branches share content but diverge by SHA. Consequences:
- Use **two-dot** `git diff origin/main..origin/dev` to see the *real* release surface. Three-dot
  (`...`) shows the whole project (ancient merge-base) and is misleading.
- A naive GitHub merge of a `dev`-based branch into `main` reports **CONFLICTING** even when the
  two-dot diff is clean — the 3-way merge from the ancient base produces spurious conflicts.

## Steps
1. **Bump `VERSION`** (single source of truth, served at `/api/health`) on `dev` via its own
   `chore(version)` PR — the tag is derived from it and `scripts/release.sh` refuses a double
   release. Tags are **unprefixed** (`0.1.10`, matching the `0.1.x` series), per issue #64.
2. **Freeze the release** on a dedicated branch so ongoing `dev` work can't leak in:
   `git push origin origin/dev:refs/heads/release/<ver>`.
3. **Re-parent the release onto `main`'s tip** to avoid the squash-divergence conflict. The release
   tree is identical to `dev`'s tree; give it `main` as its parent so the PR is a clean
   one-commit-ahead merge:
   ```sh
   NEWTREE=$(git rev-parse origin/dev^{tree})
   MAINTIP=$(git rev-parse origin/main)
   C=$(git commit-tree "$NEWTREE" -p "$MAINTIP" -F msg.txt)   # msg.txt = "Release X.Y.Z — …"
   git push origin "$C:refs/heads/release/<ver>" --force-with-lease
   ```
   First confirm the two-dot diff has **no deletions** (overlay is safe) and that
   `origin/release/<ver>^{tree} == origin/dev^{tree}`.
4. **Open the release PR** `release/<ver> → main`. It is now MERGEABLE (main + 1 clean commit).
5. **Gate 2:** an independent full-diff review (see [`review.md`](review.md)) must return
   release-ready, AND the required `Bash validators + Playwright` check must be green on the PR
   head. `main` protection: linear history, required check, `enforce_admins`, 0 required human
   approvals — the automated review IS the gate.
6. **Squash-merge** the PR → a single `Release X.Y.Z — …` commit on `main` (linear history holds).
7. **Tag `main`'s tip** unprefixed and push: `git tag -a <ver> <main-sha> -m "Release <ver>"` then
   `git push origin <ver>`. The release workflow (`.github/workflows/release.yml`) fires on the
   tag and builds the release artifacts.
8. **Post-release:** open follow-up tickets for the Gate-2 non-blocking notes; verify on real
   hardware anything CI could only stub (e.g. moderation with the real llama.cpp binaries).

## Gotchas
- **Don't let a heartbeat/other tick merge held wave-N+1 PRs into `dev` before you freeze the
  release branch.** Freezing (step 2) makes the release immune to further `dev` churn.
- `release.sh`'s clean-tree check ignores untracked files (e.g. a local `.memsearch/`) but blocks
  on uncommitted tracked changes (issue #64).
- `required_approving_review_count = 0` means no human approval is required; your review is the
  gate — be rigorous.

## Checklist
- [ ] VERSION bumped on dev (own PR), unprefixed tag free
- [ ] release/<ver> frozen; tree == dev tree; no deletions in two-dot diff
- [ ] Re-parented onto main tip; PR MERGEABLE
- [ ] Gate-2 review release-ready + CI green
- [ ] Squash-merged; single Release commit; main linear
- [ ] Tag pushed; release workflow fired
- [ ] Follow-up tickets + real-box verification queued
