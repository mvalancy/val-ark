## What & why
<!-- One focused job. What changed and the reason. -->

Closes #

## Testing
<!-- Paste evidence: tests/run-all.sh result / the offline report summary. -->
- [ ] `tests/run-all.sh` is green (bash validators + Playwright; services e2e if an Ark was reachable)
- [ ] For a release PR (dev → main): the fresh‑VM matrix (`VALARK_RUN_VM=1`) was run on a capable host

## Checklist
- [ ] Targets **`dev`** (not `main`) unless this is a release/hotfix PR
- [ ] One focused job; no unrelated changes
- [ ] **No secrets / local IPs / host names** committed (host values live in git‑ignored `.env`)
- [ ] Durable learnings baked into `docs/knowledge/` (gotcha/decision) if applicable
- [ ] Tests added/updated for the change
