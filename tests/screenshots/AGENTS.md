# tests/screenshots/ — the Playwright browser suite

Playwright specs that exercise the zero-dependency web UI two ways: as a static `file://` page
(fully offline) and API-connected against an ephemeral `scripts/server.js` on **:3001**. Work here
when a UI behavior or an API contract the UI depends on needs browser-level coverage.

↑ [Repo root](/AGENTS.md) · [Doc map](/docs/README.md)

## What's here

| File / dir | Purpose |
|------------|---------|
| `specs/web-ui.spec.ts` | The mega-spec (~33 `describe` blocks) — runs against static `file://web-ui/index.html`. Holds the **`TOOL_IDS` (49) and `MODEL_SLUGS` (19) SOURCE OF TRUTH**; every tool id must have a card, detail page, icon/logo and a `scripts/tools/<id>.sh`. |
| `specs/server-api.spec.ts` | Live-API contract tests (`request.get/post` on `:3001`): health, tools/content/models/status, setup/state, auth, downloads. |
| `specs/install-icons.spec.ts` | Install-state badges/icons ↔ `scripts/tools/*` ↔ `server.js` target parity (drives `/api/download/tools`). Live `:3001`. |
| `specs/nav.spec.ts` | Hash-route navigation smoke against static `file://` (avoids the first-boot wizard because `/api/setup/state` fails offline). |
| `specs/notifications.spec.ts` | Notification center — stubs `**/api/status/notifications` via `page.route` for deterministic bell/badge/dismiss-persist assertions. Live `:3001`. |
| `specs/escattr-sweep.spec.ts` | HTML-escaping / attribute-injection sweep across the flow. Live `:3001`. |
| `specs/health.spec.ts` | Health/self-heal page (`/#/health`) + settings; needs `/api/status/health`. Live `:3001`. |
| `specs/metrics.spec.ts` | Metrics tiles + history ring buffer (zero-dep live gauges; no telegraf/grafana). Live `:3001`. |
| `specs/packages.spec.ts` | Packages page (`/#/packages`) direct-download list on an empty mirror. Live `:3001`. |
| `specs/ui-exercise.spec.ts` | Broad click-through / link-crawl of routes. Live `:3001` (override with `VALARK_TEST_URL`). |
| `playwright.config.ts` | `testDir: ./specs`, chromium-only, dark colorScheme; `webServer` spawns `server.js` on **:3001**. |
| `package.json` / `package-lock.json` | `@playwright/test` dependency (run `npm install` once). |
| `node_modules/`, `test-results/` | **Generated** (git-ignored). |

## How to work here

- **Run:** `cd tests/screenshots && npx playwright test [spec]` (or a single test with `-g`). One-time
  `npm install`; browsers live in the shared `~/.cache/ms-playwright`.
- **The :3001 server is deliberately bare.** `playwright.config.ts` starts it with
  `VALARK_DISABLE_KIWIX=1 VALARK_COMMISSIONED=1 VALARK_TEST_NO_SPAWN=1 VALARK_HTTPS_PORT=13443` — no
  kiwix, no first-boot wizard, no child spawns, an empty mirror. Specs must tolerate that (see below).
- **`file://` vs `:3001`:** `web-ui.spec.ts` and `nav.spec.ts` run against the static file; the rest hit
  `:3001` (most honor `VALARK_TEST_URL` to point at a live Ark instead).

## Gotchas (load-bearing)

- **WORKTREE — `node_modules` is per-directory and git-ignored, so a parallel worktree has none.**
  `npx playwright test` then fails with `Cannot find module '@playwright/test'`. **Fix:** symlink the
  main checkout's install — `ln -sfn <main>/tests/screenshots/node_modules node_modules` — then run
  `./node_modules/.bin/playwright test <spec>`. The ignore rule `tests/screenshots/node_modules/`
  (trailing slash = **directory**) does NOT match that **symlink**, so `git status` shows it untracked:
  `rm -f node_modules` before committing and **never `git add -A`** (add touched files explicitly). See
  [`gotchas.md#playwright-in-worktree-69`](../../docs/knowledge/gotchas.md#playwright-in-worktree-69).
- **Empty-mirror tolerance.** The :3001 server has no downloaded tools/models/content and won't spawn
  helpers, so `test.skip` on shape (e.g. zero catalog rows) instead of asserting content, and **stub
  mutating endpoints with `page.route`** so a shared box's real state never makes a test flaky.
- **`esc()` is a TEXT escape; attributes need `escAttr()` (#121/#123).** `esc()` leaves quotes intact,
  so a value in a double-quoted attribute can break out and inject a real event-handler attribute — no
  `<>` needed. Test injection by stubbing an id with a `"` + `onmouseover` payload and asserting no
  handler attribute is added and `window.__xss` stays undefined on hover. See
  [`gotchas.md#esc-not-onclick-safe-121`](../../docs/knowledge/gotchas.md#esc-not-onclick-safe-121).

## Related

- [`../AGENTS.md`](../AGENTS.md) — the one test library (run-all orchestration)
- [`../../web-ui/AGENTS.md`](../../web-ui/AGENTS.md) — the SPA these specs drive · [`../../web-ui/index.html`](../../web-ui/index.html)
- [`../../docs/knowledge/gotchas.md`](../../docs/knowledge/gotchas.md#playwright-in-worktree-69) — worktree + `escAttr` gotchas
