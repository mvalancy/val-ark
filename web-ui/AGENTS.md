# web-ui/ — the zero-dependency SPA (navigation map)

A single-file, no-build web app: `index.html` is ~7,400 lines of markup + vanilla JS, styled by
`styles.css`. **Do NOT propose splitting it** — the single-file, open-in-a-browser design is a
feature. This file is a map so you can jump to the right section instead of scrolling 7k lines.

↑ [Repo root](/AGENTS.md) · [Doc map](/docs/README.md)

## What's here

| File / dir | Purpose |
|------------|---------|
| `index.html` | The whole SPA: DATA arrays, utilities, hash router, every `render*` surface, and the API/SSE layer. |
| `styles.css` | All styling (~40 `/* Section */` blocks; a line index sits at the top of the file). Bump the `styles.css?v=N` query in `index.html` when you change it. |
| `logos/` | Per-tool SVG/PNG logos referenced by the `TOOLS` array. |
| `screenshots/` | Tool/detail-page screenshots referenced by `details.screenshots`. |
| `samples/` | Sample prompts / text used by detail pages. |
| `favicon.svg` | App favicon. |
| `README.md` | Human-facing overview + the page-structure diagram. |

## Gotchas — two non-negotiable rules

1. **ZERO dependencies.** No npm, bundler, CDN, or external library — ever. Edit `index.html` /
   `styles.css` directly and open the file in a browser. When you touch CSS, bump the cache-buster
   `styles.css?v=N` in `index.html`.
2. **XSS — pick the escape by context.** `escAttr()` for ANY value placed in a double-quoted HTML
   attribute; `esc()` only for text between tags (`esc()` leaves quotes intact → attribute break-out,
   #121). Prefer `data-*` + event delegation over inline handlers with interpolated data. See
   [`gotchas.md#esc-not-onclick-safe-121`](../docs/knowledge/gotchas.md#esc-not-onclick-safe-121).

## Section → line index

Line numbers **drift** — treat them as a starting point and `grep -n` the name to get the current
line (e.g. `grep -n "function renderHealth" web-ui/index.html`).

**DATA arrays / constants (top of file)**
- `PLATFORMS` ≈ 26 · `ARM64_ALIAS_PLATFORMS` ≈ 94 · `OPENWRT_TOOLS` ≈ 97
- `GLOSSARY` ≈ 120 · `TOOL_CATEGORIES` ≈ 150 · `TOOLS` (big array) ≈ 163
- `TOOL_META` ≈ 2221 · `TOOL_INFO` ≈ 2330 · `INSTALLED_TOOLS` ≈ 2329
- `CONTENT_LIBRARY` ≈ 2276 · `CONTENT_STATUS`/`CONTENT_INFO` ≈ 5654
- `MODEL_FAMILIES` ≈ 2644 · `MODEL_META` ≈ 2489 · `MODEL_PATHS` ≈ 2593 (no `MODEL_SLUGS` here — that lives in the Playwright spec)
- `STORAGE_DATA` ≈ 3012 · `TESTIMONIALS` ≈ 2512 · `SETTINGS_SECTIONS` ≈ 3755 · `COMMUNITY_NAV_LABELS` ≈ 3455

**Utility layer**
- `esc` ≈ 3025 · `escAttr` ≈ 3038 · `toggleTheme` ≈ 3063 (theme applied inline; no `applyTheme`)
- `copyText` ≈ 3084 · `openLightbox` ≈ 3118 · `handleDownload` ≈ 3229 · `checkDownloads` ≈ 3267

**Hash router**
- `getRoute` ≈ 3339 · `getAnchor` ≈ 3349 · `router` (main) ≈ 3355
- `renderNav` (four-tab) ≈ 3457 · `renderLibraryNav` ≈ 3507 · `renderBreadcrumb` ≈ 3517 · `renderFooter` ≈ 3531
- bottom: `window.addEventListener('hashchange', router)` ≈ 7382 · `DOMContentLoaded` init ≈ 7383 (checkSafeMode → checkSetup → refreshAuthState → checkAccess → initFromAPI → connectSSE)

**Render surfaces**
- Home: `renderHomeStatus` ≈ 3588 · `renderHome` ≈ 4739 · Ask card `renderAskCard` ≈ 3618 / `initAskCard` ≈ 3641 / `askSubmit` ≈ 3693
- Settings `renderSettings` ≈ 3769 · Activity `renderActivity` ≈ 3834
- Packages/Downloads: `renderPackages` ≈ 3878 · `renderDownloadCard` ≈ 3906 / `loadDownloads` ≈ 3958 (no `renderDownloads`)
- Notification center: `renderNotifBell` ≈ 4074 · `renderNotifPanelBody` ≈ 4137 · `loadNotifications` ≈ 4055
- Health/Safety/self-heal: `renderHealth` ≈ 4413 · `renderSafety` ≈ 4464 · `runSelfHeal` ≈ 4556 · `setDownloadProfile` ≈ 4654
- Tools: `renderToolsList` ≈ 4903 · `renderToolDetail` ≈ 4966
- Models: `renderModelsList` ≈ 5262 · `renderModelDetail(slug)` ≈ 5328
- Content: `renderContentLibrary` ≈ 5516 · `renderContentDetail` ≈ 5590 · `renderFullWikipediaHero` ≈ 5487 · `renderServiceFrame` ≈ 5465
- Quickstart `renderQuickStart` ≈ 5703 · Glossary `renderGlossary` ≈ 6091 · Ollama guide `renderOllama` ≈ 6138
- Community `renderCommunity` ≈ 6890 · `renderAppFrame` ≈ 6488 · `renderStorageBreakdown` ≈ 6542 · `renderDiskBar` ≈ 6635
- Setup wizard `renderSetup` ≈ 6997 / `paintSetup` ≈ 7065 · Admin sign-in `signIn` ≈ 7175 / `wallSignIn` ≈ 7231
- Access wall `renderAccessWall` ≈ 7215 · Recovery `recoverFlow` ≈ 7294 · Safe Mode `renderSafeMode` ≈ 7327 / `checkSafeMode` ≈ 7338 · `renderProgressPanel` ≈ 7348

**API / SSE layer**
- `initFromAPI` ≈ 6571 · `connectSSE` ≈ 6643 · `triggerRequest` ≈ 6721 / `triggerRequestFromEl` ≈ 6745 · `startCommunityService` ≈ 6758
- `loadCatalog` ≈ 6845 · `renderCatalogSection` ≈ 6832 · `catalogCardHtml` ≈ 6860 · `filterCatalog` ≈ 6887

**Inline per-view CSS blocks** (`const *_CSS` template literals injected into `innerHTML`)
- `_PACKAGES_CSS` ≈ 3862 · `_HEALTH_CSS` ≈ 4576 · `_SHELL_CSS` ≈ 4664 · `_SETUP_CSS` ≈ 7126 · `_REC_CSS` ≈ 7252

## How to work here

- **Routes deep-link & bookmark** (`#/tools/:id`, `#/models/:id`, `#/content/:id`, `#/health`, …); a
  fresh, un-commissioned box force-routes to `/setup`.
- **Graceful degradation:** the app runs fully as a static `file://` page (no API); `initFromAPI`
  layers live data on top when `server.js` is serving.
- **Adding a tool is multi-file** (`TOOLS` + `TOOL_META` entries, a logo, a screenshot, a
  `scripts/tools/<id>.sh`, and the spec's `TOOL_IDS`). Follow the checklist in
  [`/CLAUDE.md`](/CLAUDE.md) ("Adding a New Tool"). `web-ui.spec.ts` `TOOL_IDS` is the test source of truth.

## Related

- [`../scripts/AGENTS.md`](../scripts/AGENTS.md) — `server.js` + the API this UI calls
- [`./README.md`](./README.md) — page-structure diagram (this file carries the code-level nav map)
- [`../tests/screenshots/AGENTS.md`](../tests/screenshots/AGENTS.md) — the specs that exercise this SPA
