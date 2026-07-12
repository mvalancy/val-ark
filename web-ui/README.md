# Web UI

A no-build single-page app. Markup and logic live in `index.html`; styling
is in a separate `styles.css`. No npm, no bundler -- open the file in a
browser. Navigation uses hash-based routing (`window.location.hash`) with a
`hashchange` listener that calls a central `router()` function.

## Page Structure

```mermaid
graph TD
    HR[Hash Router] --> HOME["#/ (Home)"]
    HR --> TOOLS["#/tools (Software)"]
    HR --> TOOL_D["#/tools/:id (Tool Detail)"]
    HR --> MODELS["#/models (Models)"]
    HR --> MODEL_D["#/models/:id (Model Detail)"]
    HR --> CONTENT["#/content (Content Library)"]
    HR --> CONTENT_D["#/content/:id (Content Detail)"]
    HR --> QS["#/quickstart (Getting Started)"]

    TOOLS --> TOOLS_ARR[(TOOLS array)]
    TOOL_D --> TOOL_META_OBJ[(TOOL_META object)]
    MODELS --> MODELS_DATA[(inline model data)]
    CONTENT --> CL_ARR[(CONTENT_LIBRARY array)]

    HR -- "static file:// (no API)" --> GRACEFUL["Graceful degradation"]
    HR -- "served by server.js" --> SRV[server.js]
    SRV --> STATUS["/api/status/* (live status)"]
    SRV --> DL["/api/download/* (trigger jobs)"]
    SRV --> SSE["/api/downloads/stream (SSE progress)"]
    SRV --> KIWIX["kiwix-serve auto-launch (.zim)"]
```

The app works fully offline as a static file (`file://`). When served by
[`scripts/server.js`](../scripts/server.js) (zero-dependency Node) it adds a
JSON API and live data:

| Endpoint | Purpose |
|----------|---------|
| `/api/status/{tools,models,content,kiwix,disk,all}` | Live install + disk status |
| `/api/download/{tools,models,content,update,cancel}` | Trigger / cancel mirror jobs |
| `/api/downloads/stream` | Server-Sent Events: live download progress |
| `/api/health` | Server liveness |

The server also auto-launches `kiwix-serve` for any complete `.zim` it finds
in `content/zim`, so offline encyclopedias work without manual setup. Without
the server, the UI degrades gracefully (no live status, static data only).

## Data Model

**TOOLS array** -- one entry per tool (43 tools across 6 categories):
`id`, `name`, `category`, `icon`, `iconBg`, `logo`, `desc`, `platforms`,
`downloads` (source/releases/binaries), and `details` (overview, features).
Per-platform status for the aarch64 aliases (Thor, GB10) and OpenWRT is
derived at runtime by `deriveToolPlatforms()`, so each tool only declares its
base `jetson`/`ubuntu`/`mac`/`windows` status.

**TOOL_META object** -- keyed by tool id: `license`, `licenseUrl`, `maker`,
`website`.

**CONTENT_LIBRARY array** -- offline ZIM files for Kiwix, each with:
`id`, `name`, `category`, `size`, `file`, `source`, `articles`, `details`.

### Tool Categories (`TOOL_CATEGORIES`)

| ID | Label |
|----|-------|
| `ai-inference` | AI Inference |
| `ai-platform` | AI Platform |
| `creative` | Creative & Engineering |
| `media` | Media |
| `infrastructure` | Infrastructure |
| `dev-tools` | Dev Tools |

### Platforms (`PLATFORMS`)

Selectable in the UI: `jetson` (Jetson Orin), `thor` (Jetson Thor), `gb10`
(GB10 Grace-Blackwell), `ubuntu`, `mac`, `windows`, `openwrt`. All aarch64
boards share the `linux-arm64` artifacts and differ only by GPU/CUDA profile;
OpenWRT routers expose the content/sync/infra subset only.

## File Structure

```
web-ui/
  index.html     -- markup + application logic (HTML + JS)
  styles.css     -- all styling (linked from index.html)
  logos/         -- SVG/PNG tool logos
  screenshots/   -- tool screenshots
  samples/       -- sample prompts / text used by detail pages
  README.md      -- this file
```

## Running

1. **Static** -- open `index.html` directly in a browser (`file://`).
2. **Via server** -- `node ../scripts/server.js [port]` (default `3000`), or
   `./start.sh serve [port]` from the project root. The 24/7 loop and verify
   scripts honor `VALARK_WEB_PORT` (set in `.env`) when launching the server.

---

[Back to Project Root](../README.md)
