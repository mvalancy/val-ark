# Skill: recovery — survive restarts, usage limits, and worker death

## When to use
A session restarted, a usage/credit limit was hit, the model was switched, or a worker agent died
mid-task. Resume the pipeline without losing work or double-doing it.

## Principle
**GitHub is the canonical state.** Branches, PRs, issues, and CI status are the source of truth;
in-session memory is a cache. Anything not pushed to a branch can be lost — so workers commit and
push (WIP if needed) before stopping.

## Steps
1. **Re-derive state from GitHub, not memory:** `git fetch --all --prune`, `gh pr list`,
   `gh issue list`, `git worktree list`, and read the session's cycle-state notes if present.
2. **Recover partial work.** A dead worker's worktree may hold committed-and-pushed branches
   (recover them into a PR) or only uncommitted edits (usually cheaper to redo from a fresh
   worker). Check `git -C <worktree> log origin/dev..HEAD` and `git status`.
3. **Reconcile in-flight PRs:** for each open PR check the review verdict + CI; merge only those
   that pass both. Re-run any review that was cut off (workflows resume from cache — unchanged
   agents replay instantly, only the interrupted ones re-run).
4. **Respawn workers on the *current* model.** If the model was switched (e.g. a credit limit moved
   you off one model), spawn new workers on the model that actually has capacity — don't re-spawn on
   an exhausted one, it fails instantly. Prefer a *fresh* spawn over resuming a dead agent (a
   resumed agent's file-edit tools stay pinned to its original worktree).
5. **Re-arm the recovery layers** (below) and continue.

## Recovery layers (defense in depth)
1. **In-session pacing:** re-arm a wakeup every tick.
2. **In-session backstop:** a recurring, *idempotent* tick that reads state, merges what's ready,
   respawns dead workers, and re-arms the wakeup — so one missed wakeup can't stall the loop.
3. **Cross-restart:** GitHub state + committed knowledge (`docs/knowledge/`, `.agents/`, memory).
   Workers push before stopping, so process/credit death never loses landed work.
4. **On worker death:** recover any pushed branch → PR it; respawn a fresh worker for the remainder.

## Gotchas
- **The in-session schedulers are session-only.** A fully dead CLI process needs a human (or a
  host-level cron) to relaunch — that gap is real; surface it rather than assume auto-resume.
- **Don't trust a cached "done".** Verify against `gh pr view`/CI before acting on a remembered
  result; re-read a workflow's journal before assuming its results were non-empty.

## Checklist
- [ ] State re-derived from GitHub, not memory
- [ ] Partial work recovered or cleanly redone
- [ ] In-flight PRs reconciled against review + CI
- [ ] Workers respawned on a model with capacity
- [ ] Recovery layers re-armed
