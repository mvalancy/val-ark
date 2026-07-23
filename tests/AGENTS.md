# tests/ — the one test library

The single offline, self-contained test suite for Val Ark; work here whenever you add or change
test coverage. `run-all.sh` is the **only entry point** — it auto-discovers every suite and folds
them into one hostable HTML report.

↑ [Repo root](/AGENTS.md) · [Doc map](/docs/README.md)

## What's here

| File / dir | Purpose |
|------------|---------|
| `run-all.sh` | Orchestrator + node-free failure gate. Wipes `results/*.json`, resolves a node dir, then runs five stages: bash validators → Playwright → community-services e2e → VM matrix → unified report. |
| `lib/results.sh` | Common result schema. `results_init` / `results_case` / `results_run` / `results_finish` — **source this in any new bash suite** so it emits `results/<suite>.json` and joins the report + both failure gates. |
| `lib/md_link_check.py` | Offline internal-Markdown link + `#anchor` resolver (GitHub-slug compatible) behind `test-doc-links.sh` — keeps the `.md` hierarchy interconnected. |
| `lib/secret_scan.py` + `lib/secrets-allowlist.txt` | Offline secret/private-host leak scanner behind `test-secrets.sh` (LAN IPs, private-TLD + bare URL hosts, tracked secret files); reviewed exceptions live in the allowlist. |
| `report/generate.mjs` | Reads every common-schema `results/*.json` and renders ONE self-contained offline `results/report.html` (inline CSS/JS, failures-first, dark/light). Exits 1 if any case failed. |
| `report/from-playwright.mjs` | Converts Playwright's JSON reporter output into the common schema (one file per spec, id `playwright-<spec>`) so it feeds `generate.mjs`. |
| `test-*.sh` | Bash validators (deps, models, tls, tools, urls, moderation, loop-lock, path-containment, **doc-links**, **secrets**, …). Auto-discovered by the `test-*.sh` glob; no registration. |
| `services/run.sh` | Community-services e2e (chat/mail/forum/paste) against a **live Ark** (`VALARK_URL`) — status shape, `/app/<id>/` proxy frames, account model, localhost-only sign-up. |
| `vm/run.sh` | Host-side multipass fresh-Ubuntu matrix (default `22.04 24.04 26.04`); `git archive`s source into a VM, runs `provision.sh` inside, folds `STEP\|…` lines into report cases. Opt-in. |
| `vm/provision.sh` | Runs **inside** the clean VM as a first-time user: unpack source → headless `setup.sh` → start `server.js` → smoke-test `/api/health`, `/`, `/bootstrap.sh`, metrics, `/api/setup/state`. |
| `screenshots/` | The Playwright browser suite — see [`screenshots/AGENTS.md`](screenshots/AGENTS.md). |
| `results/` | **Generated** (git-ignored): per-suite JSON + `report.html`. |
| `README.md` | Human-facing suite overview + run recipes. |

## How to work here

- **Run everything:** `tests/run-all.sh` → `tests/results/report.html`. Playwright runs whenever
  `tests/screenshots/node_modules/.bin/playwright` exists; services e2e runs only if an Ark
  answers `GET /api/health` at `VALARK_URL` (default `http://127.0.0.1:3000`).
- **Add a bash suite:** drop `tests/test-<x>.sh` that sources `lib/results.sh` and emits a matching
  `results/<suite>.json`. The `for test_file in "${TEST_DIR}"/test-*.sh` glob picks it up
  automatically — no list to edit.
- **Env flags:** `VALARK_URL` (point services e2e at a specific Ark), `VALARK_RUN_VM=1` (opt into the
  slow VM matrix; `VALARK_VM_VERSIONS="24.04"` for one), `VALARK_NO_PLAYWRIGHT=1` (skip the browser
  suite), `VALARK_DISABLE_KIWIX=1` (content view runs kiwix-disabled).
- **Tests that would have caught the defect.** A fix without a fail-without/pass-with test isn't done.

## Gotchas

- **HARD RULE — offline + self-contained.** Suites must never depend on an external mirror or a
  populated host. Stub HTTP (Playwright `page.route`, or `curl`/`node`/`sleep` shell-function shims),
  build sandboxes with `mktemp`, and `test.skip` on empty-mirror shape rather than asserting content
  exists. See [`gotchas.md#catalog-empty-feed-95`](../docs/knowledge/gotchas.md#catalog-empty-feed-95).
- **The green/red gate must not go green just because node is missing.** `run-all.sh`'s exit code
  can't come solely from `generate.mjs`; with no node it greps `"failed":[1-9]` across `results/*.json`
  instead. Sandbox-tested by `test-runner-exit.sh`. See
  [`gotchas.md#test--vm-harness`](../docs/knowledge/gotchas.md#test--vm-harness).
- **`test-urls.sh` is the ONE deliberately-online validator** (real dead-link detection: 404/410 fail;
  a sustained 429/403 is a WARN under CI). Its guard logic is unit-tested **offline** by
  `test-urls-logic.sh` (stubs `curl`/`sleep`). Don't add other network dependencies.
- **Structural asserts must skip the comment line** — a `grep` for a token that also appears in a
  nearby `#` comment passes vacuously. See
  [`gotchas.md#grep-operative-not-comment-96`](../docs/knowledge/gotchas.md#grep-operative-not-comment-96).
- **multipass is snap-confined** (VM matrix): stage transfers under a non-hidden repo path like
  `tests/results/`, never `/tmp` or a dotfile dir.
- **`test-secrets.sh` failing = fix the leak, not the test.** It flags LAN IPs, private-TLD/bare URL
  hosts, and tracked secret files (public repo — Prime Directive 1). If it's a genuine non-secret
  (a doc example, a protocol constant, a test fixture), add ONE reviewed line to
  `lib/secrets-allowlist.txt` — never broaden `secret_scan.py` to wave a class through. Public dotted
  domains, `localhost`/loopback, and `$`/`{}`/`<>` placeholders already pass automatically.
- **`test-doc-links.sh` is offline** — internal `.md` links + anchors only. A renamed heading breaks
  every TOC/breadcrumb pointing at it; fix the link or restore the slug. External URL liveness stays
  in `test-urls.sh`. Both guards also run as a **fail-fast CI step before the browser install** (#130).

## Related

- [`screenshots/AGENTS.md`](screenshots/AGENTS.md) — the Playwright browser suite
- [`README.md`](README.md) — run recipes + the common result schema
- [`../docs/knowledge/gotchas.md`](../docs/knowledge/gotchas.md#test--vm-harness) — test/VM harness gotchas
- [`../scripts/AGENTS.md`](../scripts/AGENTS.md) — the scripts under test · [`../CLAUDE.md`](../CLAUDE.md) — the Tests row
