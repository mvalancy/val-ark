# Contributing to Val Ark

Thanks! The full, authoritative process lives in the knowledge base:

- **Git / branch / PR strategy:** [`docs/knowledge/workflow.md`](docs/knowledge/workflow.md)
- **Governance, automation & the trust model:** [`docs/knowledge/governance.md`](docs/knowledge/governance.md)
- **Project rules & how to add a tool:** [`CLAUDE.md`](CLAUDE.md)
- **Gotchas & decisions (bake learnings back here):** [`docs/knowledge/`](docs/knowledge/README.md)

## TL;DR

1. Work off **`dev`** in a `feat/…` / `fix/…` / `docs/…` branch — **never push to `main`**.
2. One job per branch/PR; reference an issue (`Closes #n`); keep it focused.
3. **Add/update tests** and run `tests/run-all.sh` (green) before opening a PR into `dev`.
4. **Never commit secrets, local IPs, or host names** — those go in the git‑ignored `.env`
   (shape in `.env.example`).
5. Record durable learnings in `docs/knowledge/` in the same PR.

Maintainers gate merges to `main` (release PRs) and any PR from a fork.
