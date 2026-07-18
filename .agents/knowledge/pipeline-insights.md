# Pipeline insights

Operational insights about running the Val Ark multi-agent pipeline. Append here when you learn
something that doesn't fit a single skill. Keep it concrete and actionable. **No host names, IPs,
creds, or host paths.**

## Releases

- **main's squash history makes the merge-base ancient.** Use two-dot `git diff main..dev` for the
  real release surface; a GitHub merge of a dev-based branch into main falsely reports CONFLICTING.
  Fix by re-parenting the release tree onto main's tip with `git commit-tree` (see
  [`../skills/release.md`](../skills/release.md)). This is the single most important release trick.
- **VERSION is the tag source of truth** (served at `/api/health`). Bump it on dev *before* cutting
  the release, or `release.sh` refuses ("tag already exists"). Tags are unprefixed (`0.1.10`).
- **Freeze the release on `release/<ver>` before merging held PRs to dev** — otherwise an open
  `dev → main` PR grows as new commits land on dev, and later work leaks into the release.

## Reviews & verification

- **CI green ≠ works on the box.** Offline stubs accept any argv, so CI can't prove real binaries
  (e.g. the llama.cpp build) accept new flags. Changes to how an external binary is invoked need a
  real-hardware verification item, tracked as a follow-up (non-blocking for merge).
- **Pin the PR head SHA when reviewing** — parallel reviewers clobber `FETCH_HEAD`.
- **Review workflows resume from cache.** After an interruption, re-running replays unchanged agents
  instantly and only re-runs the ones that failed — cheap to recover a partial review.

## Workers & worktrees

- **A resumed agent's file-edit tools stay pinned to its original worktree.** After a restart,
  prefer spawning a *fresh* worker over resuming a dead one; if you must resume, expect it to edit
  via shell heredocs in a new worktree.
- **Workers must commit + push before stopping** (WIP clearly marked). Proven: a worker's finished
  fix survived a credit-death because it had been pushed as a branch; unpushed workers lost nothing
  because they hadn't started editing.
- **Stacked chains and doc anchors:** parallel workers appending to the same
  `docs/knowledge/gotchas.md` section conflict — use distinct anchors, and when rebasing keep both
  entries in issue order.
- **Screenshot binary churn:** some Playwright runs regenerate `docs/screenshots/*.png`; don't
  commit that churn unless the change intentionally alters those screens.
- **Merging a stacked chain is a trap with squash.** Squash-merging a stacked PR's *parent* gives
  the merged commit a new SHA, so the *child* branch (which still contains the parent's original
  commit) conflicts against dev; worse, `--delete-branch` on the parent auto-**closes** the child
  (its base branch vanished). Recover by dropping the already-merged parent commit:
  `git rebase --onto origin/dev <parent-tip-sha> <child-branch>`, push to a fresh branch, open one
  PR (reference both issues). Do this *before* deleting the parent branch. Prefer rebasing each
  child onto dev right after its parent lands over relying on GitHub auto-retarget.

## Issue tracking

- **Merges to `dev` do NOT auto-close issues** — `Fixes #N` keywords only fire on merge to the
  repository's **default branch** (`main`). In this dev-integration model, close issues manually
  when their fix lands on `dev` (comment the PR + target release), and again confirm at release.
  Otherwise fixed issues pile up open and the discovery sweep may re-file them.

## Test hygiene

- **Everything offline.** Stub `curl`/`aria2c`/binaries via PATH shims or fixtures; use scratch
  dirs under a temp root and local bare git origins; never touch real mirrors, the real data disk,
  or the real crontab. A canary shim that logs any real network call is a good way to *prove* a
  test is hermetic.
- **The fresh-VM (multipass) matrix can't run in headless GitHub CI** — it runs locally. CI covers
  bash validators + Playwright; treat the VM matrix as a local/release-time gate.
- **Loopback TCP buffers autotune large** (~tens of MiB): a backpressure-dependent test needs a
  payload big enough that streaming is still in progress when the assertion runs.

## Scaling & cadence

- **More agents is not always better.** Match parallelism to the work; a methodical few beats a
  swarm when tasks interact or when a credit budget is at risk. Keep independent work on disjoint
  files to avoid merge collisions.
