# .github/ — CI, release automation, contributor scaffolding

GitHub Actions workflows plus the issue/PR scaffolding. This is the enforcement layer for the
delivery pipeline: CI is the test gate on every PR, and the Release workflow ships the offline
self-replication artifacts.

↑ [Repo root](/AGENTS.md) · [Doc map](/docs/README.md)

## What's here

| File | Purpose |
|------|---------|
| `workflows/ci.yml` | Test gate. Runs `tests/run-all.sh` (bash validators + Playwright) on every PR + `dev` push; uploads the offline HTML report. |
| `workflows/release.yml` | Fires on an unprefixed `0.x` tag; builds a full-history git bundle + a `val-ark/`-prefixed source tarball + `SHA256SUMS` and attaches them to the Release. |
| `dependabot.yml` | Weekly npm (`/tests/screenshots`) + github-actions (`/`) updates, targeted at `dev`. |
| `PULL_REQUEST_TEMPLATE.md` | The PR checklist (targets `dev`, one job, no secrets, tests, `Closes #`). |
| `ISSUE_TEMPLATE/` | `bug.md`, `feature.md`, `agent-task.md`, and `config.yml` (blank issues off; security → private advisories). |

## Key behaviors

- **CI trigger is `pull_request` (NOT `pull_request_target`) with `permissions: contents: read`.** Fork
  PRs therefore run with a read-only token and **no repository secrets** — a stranger PR cannot
  exfiltrate secrets or write to the repo just by triggering CI. CI only tests; it never deploys.
- CI sets `VALARK_DISABLE_KIWIX=1` (no kiwix binary on the runner) and `VALARK_NO_VM=1`, and it never
  sets the opt-in `VALARK_RUN_VM=1`, so the fresh-VM matrix is skipped in CI (see Gotchas).
- **Release** matches unprefixed `[0-9]*.[0-9]*.[0-9]*` tags (legacy `v*.*.*` kept as a safety net) with
  `permissions: contents: write`. It builds the SAME payload `scripts/mirror-self.sh` serves at
  `/sources/val-ark/` and `bootstrap.sh` consumes: `git bundle create --all` (clonable offline) + `git
  archive --prefix=val-ark/` (tarball `--strip-components=1` extracts) + `sha256sum` → `SHA256SUMS`.
  Version comes from the tag, never hardcoded — this contract is load-bearing for self-replication.

## How to work here

- **Pin third-party actions by commit SHA** (the existing convention — note the `# vN` trailing
  comment), not a floating tag.
- Keep `permissions:` least-privilege per workflow (`contents: read` for CI, `contents: write` only for
  Release).
- **Don't rename or drop the release artifacts casually** — `mirror-self.sh` / `bootstrap.sh` depend on
  the bundle / `val-ark-*.tar.gz` / `SHA256SUMS` names and shapes.

## Gotchas

- **Never switch CI to `pull_request_target`.** That trigger runs with the base repo's secrets and a
  writable token even for fork PRs — it would hand secrets to any stranger's PR code. This is the single
  most important line in `ci.yml`.
- **The fresh-VM matrix can't run in GitHub CI** (hosted runners can't launch KVM VMs). It is opt-in via
  `VALARK_RUN_VM=1` on a capable host — a release PR (`dev → main`) is where it should be run.
- **Dependabot reads `dependabot.yml` from the default branch (`main`).** Until a change to it ships to
  `main`, `target-branch: dev` doesn't take effect and PRs still open against `main`.

## Related

- [`../AGENTS.md`](../AGENTS.md) — the delivery pipeline + Gate 1 / Gate 2 review model
- [`../docs/knowledge/governance.md`](../docs/knowledge/governance.md) — trust / branch / release governance
