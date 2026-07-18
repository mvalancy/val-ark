# Skill: issue-discovery — find real, confirmed issues worth filing

## When to use
You want to surface work: bugs, gaps, or missing roadmap scope. The bar is **confirmed defects with
file:line evidence**, not speculation or style nits.

## Steps
1. **Fan out per area, in parallel.** Give each investigator one area (CI, a subsystem, docs,
   security, a roadmap phase) and require: read the actual code, quote the load-bearing lines, and
   describe a concrete, reachable failure scenario. No area investigator sees the others' findings.
2. **Verify every candidate adversarially, through independent lenses:**
   - *Is it real?* Re-derive the failure from the code; default to false if you can't reproduce it.
   - *Is it a duplicate / known / decided-against?* Check open+closed issues, `docs/knowledge/`
     gotchas & decisions, and known-benign quirks.
   - *Is the need real and the fix right-shaped?* Judge against the vision; not a band-aid, not
     over-engineering; honest priority/effort.
3. **Confirm = ≥2 lenses say real AND ≥2 say worth-a-ticket.** Drop the rest (record why).
4. **Consolidate** near-duplicate candidates into one ticket each; write crisp evidence + proposed
   fix + priority/effort; **scan every ticket for secrets** before filing (public repo).
5. **File** with area labels. Carry the adversarial-review notes into the ticket body — they guide
   the worker's scope.

## Gotchas
- Investigators are read-only: no edits, only read-only git/gh/grep.
- Prefer roadmap-backed "missing scope" tickets over hypothetical hardening — verify the feature is
  genuinely absent (grep the code) before claiming it.
- A finding that would leak host info even after redaction is not worth a public ticket.

## Checklist
- [ ] Parallel per-area finders with quoted file:line evidence
- [ ] Each candidate verified by ≥3 independent lenses
- [ ] Confirmed-only, consolidated, deduped
- [ ] Secrets-scanned before filing
- [ ] Labeled + review notes included
