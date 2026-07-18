# Skill: review — independent adversarial review (Gate 1 & Gate 2)

## When to use
Gate 1: a worker's PR into `dev`. Gate 2: a `dev → main` release PR. You must **not** be the author
— the pipeline reviews its own work adversarially so it cannot rubber-stamp.

## Principle
A wrong approval ships a bug to every deployed box; a wrong block stalls the pipeline. Approve only
what you verified yourself against the actual code — not the PR description.

## Steps
1. **Pin the head SHA** (`gh pr view <n> --json headRefOid`). Concurrent reviewers clobber
   `FETCH_HEAD`; always work against the pinned SHA.
2. **Review through multiple independent lenses**, each a separate reviewer:
   - **Correctness & regression:** does it fix the linked issue per its evidence? Trace changed
     paths in surrounding context. Hunt out-of-scope changes, broken callers, edge cases
     (empty/missing files, spaces/newlines/control chars in names, cross-arch).
   - **Invariants, safety, leaks:** fail-closed preserved? Downloads size-verified + atomic? Server
     still zero-dep? Full secrets sweep of the whole diff (hosts/IPs/tailnet/creds/host paths).
   - **Test adequacy:** would the new tests fail *without* the fix? Read them line by line; if
     stubbed and offline, run them in a pinned scratch worktree and report exact counts. Flag
     vacuous passes.
3. **Verify every blocking finding adversarially.** A second pass tries to *refute* each block:
   is it real and reachable, and must it block *this* merge vs a follow-up ticket? Default to
   "does not block" unless shipping causes real harm.
4. **Decide:** mergeable = ≥2 lenses approve AND zero *confirmed* blocking findings. Route confirmed
   blocks back to a worker; capture non-blocking notes as follow-up tickets or release notes.

## Gotchas
- **Run offline tests in a throwaway worktree** under `/tmp` pinned to the head SHA; remove it
  (`git worktree remove --force`) when done. Never run networked tests or touch external mirrors.
- **`git diff main...dev` (three-dot)** shows the whole project because main's squash releases make
  the merge-base ancient. Use **two-dot** `git diff main..dev` for the true release surface. (See
  [`release.md`](release.md).)
- **CI green ≠ works on the box.** Offline stubs can't prove real binaries accept new flags. If a
  fix changes how an external binary is invoked, flag a real-box verification item (non-blocking).

## Checklist
- [ ] Head SHA pinned
- [ ] Correctness, invariants/leaks, and test-adequacy lenses all run
- [ ] Blocking findings adversarially verified (real + must-block)
- [ ] Secrets sweep clean
- [ ] Verdict + non-blocking follow-ups recorded
