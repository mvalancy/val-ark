# Skill: release — cut and tag a `dev → main` release

## When to use
`dev` is green and carries a wave of reviewed fixes/features; you are shipping a versioned release
to `main`.

## Background: main's history model
`main` is a series of **squash "Release X.Y.Z" commits** (one per release). If `main` is not merged
back into `dev` after a release (step 8), the **merge-base between `main` and `dev` goes stale**.
Each release squashes dev's many commits into one, so the branches share content but diverge by
SHA. Up to 0.1.18 no back-merge was ever done, so the merge-base was ancient. Consequences while
that is the case:
- Use **two-dot** `git diff origin/main..origin/dev` to see the *real* release surface. Three-dot
  (`...`) shows the whole project (ancient merge-base) and is misleading.
- A naive GitHub merge of a `dev`-based branch into `main` reports **CONFLICTING** even when the
  two-dot diff is clean — the 3-way merge from the ancient base produces spurious conflicts.

## Steps
1. **Bump `VERSION`** (single source of truth, served at `/api/health`) on `dev` via its own
   `chore(version)` PR — the tag is derived from it and `scripts/release.sh` refuses a double
   release. Tags are **unprefixed** (`0.1.10`, matching the `0.1.x` series), per issue #64.
2. **Freeze the release** on a dedicated branch so ongoing `dev` work can't leak in, and **record
   the frozen dev commit `F`** (step 8 needs it, and step 3 replaces the branch tip):
   `F=$(git rev-parse origin/dev); git push origin "$F:refs/heads/release/<ver>"`.
3. **Only if `main` is not an ancestor of `dev`** (`git merge-base --is-ancestor origin/main "$F"`
   fails, meaning the previous release skipped step 8): **re-parent the release onto `main`'s tip** to
   avoid the squash-divergence conflict. When `main` *is* an ancestor, skip this step: `release/<ver>`
   at `F` is already a clean PR. The release tree is `F`'s tree; give it `main` as its parent so
   the PR is a clean one-commit-ahead merge:
   ```sh
   NEWTREE=$(git rev-parse "$F^{tree}")
   MAINTIP=$(git rev-parse origin/main)
   C=$(git commit-tree "$NEWTREE" -p "$MAINTIP" -F msg.txt)   # msg.txt = "Release X.Y.Z — …"
   git push origin "$C:refs/heads/release/<ver>" --force-with-lease
   ```
   First confirm the two-dot diff has **no deletions** (overlay is safe) and that
   `origin/release/<ver>^{tree} == $F^{tree}`.
4. **Open the release PR** `release/<ver> → main`. It is now MERGEABLE.
5. **Gate 2:** an independent full-diff review (see [`review.md`](review.md)) must return
   release-ready, AND the required `Bash validators + Playwright` check must be green on the PR
   head. `main` protection: linear history, required check, `enforce_admins`, 0 required human
   approvals — the automated review IS the gate.
6. **Squash-merge** the PR → a single `Release X.Y.Z — …` commit on `main` (linear history holds).
7. **Tag `main`'s tip** unprefixed and push: `git tag -a <ver> <main-sha> -m "Release <ver>"` then
   `git push origin <ver>`. The release workflow (`.github/workflows/release.yml`) fires on the
   tag and builds the release artifacts.
8. **Back-merge `main` into `dev`** so `dev` contains the new release commit and every earlier
   one. `dev` has usually moved on since the freeze, so this is a real three-way merge with the
   frozen commit `F` as its base. Whatever the squash put on `main` beyond `F` is kept, and
   everything `dev` gained since `F` is kept. Run it as one `&&` chain, so any failure (`F` not on
   `dev`, or a conflict, where `merge-tree` exits 1) stops before anything is pushed. Needs git ≥ 2.40:
   ```sh
   git fetch origin
   F=<the dev commit frozen in step 2>
   git merge-base --is-ancestor "$F" origin/dev &&
   T=$(git merge-tree --write-tree --merge-base="$F" origin/dev origin/main) &&
   M=$(git commit-tree "$T" -p origin/dev -p origin/main -m "Merge main (release <ver>) back into dev") &&
   git push origin "$M:refs/heads/chore/sync-main-<ver>"
   ```
   If the squash commit's tree equals `F`'s tree (the normal case), `T` is exactly `dev`'s tree and
   the PR has an empty file diff. Open `chore/sync-main-<ver> → dev` and land it with a **merge
   commit** (`gh pr merge --merge`). A squash would drop the second parent, and keeping it is the
   whole point. Afterwards `git rev-list --count origin/dev..origin/main` is 0, the merge-base is
   the release, and step 3 is not needed next time. Skipping this is how `dev` drifted to
   "95 ahead, 33 behind" with nothing actually missing (cleaned up in #156).
9. **Post-release:** open follow-up tickets for the Gate-2 non-blocking notes; verify on real
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
- [ ] release/<ver> frozen at `F` (recorded); no deletions in two-dot diff
- [ ] Re-parented onto main tip only if main is not an ancestor of `F`; PR MERGEABLE
- [ ] Gate-2 review release-ready + CI green
- [ ] Squash-merged; single Release commit; main linear
- [ ] Tag pushed; release workflow fired
- [ ] `main` back-merged into `dev` (merge commit); `origin/dev..origin/main` is empty
- [ ] Follow-up tickets + real-box verification queued
