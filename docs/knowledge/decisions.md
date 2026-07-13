# Val Ark — Decisions & Progress Log

Architecturally significant decisions and notable progress, newest first. Format:
**context → decision → why.** Append when you make a call worth remembering (or reversing
later). See [README](README.md).

---

## 2026‑07 — Safety card ships without "restore"; review is remove/dismiss only (Phase 7, 4/n)

- **Context:** the admin Safety card's review queue needs actions on held items. The natural
  set is remove (delete) / restore (release a false positive back to its store) / dismiss
  (acknowledge, keep quarantined). An adversarial review of the endpoints flagged that
  **restore is the entire risky surface** (4 of 5 findings, incl. a HIGH): its destination is
  `item.path` read from `queue.jsonl`, an append-only log living in the in-`<state>` tree that
  this project's OWN threat model treats as attacker-writable (a same-uid service or an
  NFS-mesh peer). An unconfined write-back is an arbitrary-file-write → RCE-if-root
  confused-deputy (admin clicks "Approve" → server writes attacker bytes to e.g. `/etc/cron.d`),
  plus a TOCTOU symlink-swap on the copy source that exfiltrates arbitrary readable files.
- **Decision:** **drop restore** for 4/n. The queue supports only **remove** (`unlinkSync` the
  quarantine entry — never follows a final symlink, basename-confined) and **dismiss** (append
  `reviewed.jsonl`, keep the file). Both are provably safe. A false positive is released on the
  box itself for now.
- **Why not just harden it:** doing restore safely needs the destination realpath-confined to an
  allowlist of the sweep's store roots (which the server would have to duplicate from
  `mod-sweep.sh` — a drift hazard) **and** an `O_NOFOLLOW` fd-based copy. That's a real feature,
  not a patch; better shipped deliberately later than rushed into a security-sensitive path. The
  fail-closed instinct applies to our OWN write-backs too: if we can't confine it simply, don't
  do it. Follow-up: store-root-confined + `O_NOFOLLOW` restore.

## 2026‑07 — Moderation ENFORCEMENT is a post-store loop sweep (Phase 7, 3/n)

- **Context:** the endpoints + settings (2/n) can screen content on request, but nothing on
  the box actually ran community content through them — so the Safety card's "screening" claim
  was hollow. Two ways to enforce: a **pre-store proxy intercept** (screen the POST body in
  `pipeProxy` before NodeBB/MicroBin stores it) or a **post-store sweep** (the self-heal loop
  screens already-stored files each cycle).
- **Decision:** post-store **file sweep** (`scripts/lib/mod-sweep.sh`, wired as `loop.sh` step
  7c). It walks configured community stores (paste files, mail, upload dirs — `VALARK_MODERATION_DIRS`
  overrides), screens each new file with `moderation.sh check`, and on any non-`allow` verdict
  **quarantines** the file (moves it out of the store) + appends a `state/moderation/queue.jsonl`
  review entry. Idempotent via a `screened.tsv` (path+size+mtime) marker; bounded per run; the
  admin's `action` (block/quarantine/flag) decides move-vs-copy. **Fail-closed:** an unparseable
  verdict, a classifier error, or node-unavailable settings all resolve to hold→quarantine, never
  "left served."
- **Why the sweep, not the intercept:** the pre-store intercept must parse each app's POST format
  (NodeBB CSRF/multipart, MicroBin forms) — fragile and app-coupled — and NodeBB's post store is
  **Redis**, not files. The sweep is app-agnostic, offline-testable with fixtures + a stub
  classifier (`test-mod-sweep.sh`, 16/0), and fits the loop's "reconcile reality each cycle"
  model. It's reactive (content is briefly visible before the next cycle) — an acceptable first
  cut; a NodeBB/Redis screener and a pre-store paste intercept are documented follow-ups.
- **CORRECTION (real-box investigation, 0.1.9 deploy):** the sweep must **NOT** target the
  community services' internal stores at all — they are **DB-backed**. MicroBin keeps text pastes
  in SQLite (`microbin.db` under `STATE_DIR/services/paste`); maddy keeps mail in an imapsql/bbolt
  store (`STATE_DIR/services/mail/maddy/`). The files on disk are referenced *from* a database, so
  the sweep's move-to-quarantine would **corrupt the store**, not screen it (and pastes/mail bodies
  often aren't standalone files). The original default paths (`services/paste/data`,
  `services/mail/messages`) were also just plain **wrong** (off by the real subdir), so the sweep
  was a harmless no-op on the real box — but "correcting" them would have caused corruption. So the
  sweep now screens **only** an explicit plain-file uploads area (`VAL_ARK_UPLOADS` /
  `VALARK_MODERATION_DIRS`), never a service store. Real per-service enforcement (paste/mail/forum)
  requires a **pre-store intercept or a service-native hook** — a deliberate follow-up, not a path
  tweak. This is the fail-closed instinct applied to integrity: don't let the safety mechanism
  itself break the thing it guards.

## 2026‑07 — Community chat is open (no-login) by default
- **Context:** on the real box a visitor opening `/app/chat/` hit The Lounge's **private-mode login
  wall with no way to create an account** (accounts were host-only, via `thelounge add`) — chat was
  effectively unusable without shell access. Plus ngIRCd's default `MaxNickLength=9` rejected
  ordinary names ("nickname too long"), and there was only one empty room.
- **Decision:** default chat to **public / no-login** (`VALARK_CHAT_PUBLIC=1`) — pick a nickname and
  join. Val Ark's reverse proxy + Use Mode already gate *who* reaches `/app/chat/`, so The Lounge
  needn't re-auth. Operators wanting per-user logins + persistent history set `VALARK_CHAT_PUBLIC=0`.
  Also: `MaxNickLength=30`, starter channels (`#valark #general #help #random`), a MOTD teaching
  `/list` + `/join`, an ark-themed leave message, and an idempotent start (real pid + port fallback).
- **Why:** the appliance principle is "it just works" — a trusted-LAN community box should let people
  in with zero friction, not gate casual chat behind account provisioning. `COMMUNITY_ACCOUNTS.chat`
  tracks the mode (`open`↔`host`) so the account panel and `adduser` stay correct either way.
- **Proven on the deployed ARM64 box** (not just CI): a 20-char nick registers, `/list` shows the
  channels, `/join` creates one, repeat `start` is a no-op. Real-box verification caught what the
  green test suite didn't — the login wall, the nick limit, the write-once config.

## 2026‑07 — Versioning re-baselined to honest pre‑1.0 (0.1.x)
- **Context:** early releases had jumped to a 1.x line (v1.0.0–v1.5.0), which implies a real,
  supported 1.0 user release we are nowhere near.
- **Decision:** we are **pre‑1.0**. Deleted the premature v1.0.0–v1.5.0 tags + GitHub releases
  (nobody depended on them) and re-baselined to **0.1.x**; the Phase 6 release (Health UX + live
  metrics) is **0.1.7**. The app version now has a single source of truth — the repo‑root
  `VERSION` file, read by `scripts/server.js` (`APP_VERSION`, served at `/api/health`).
- **Rule going forward:** stay on **0.x** until there's a genuine, stable 1.0 user release; **bump
  the `VERSION` file as part of each release** (the release-branch commit), so `/api/health` never
  goes stale again. Don't reach for 1.0 by increment — it's a deliberate "this is ready for real
  users" call.

## 2026‑07 — Reframe to a consumer appliance (scope‑first)
- **Context:** Val Ark was a power‑user/CLI tool; the goal is a router‑app / health‑app
  experience for a non‑technical owner ("one big EASY button").
- **Decision:** Scope the whole consumer experience *before* coding, as a cohesive 14‑doc
  hierarchy in [`docs/design/`](../design/README.md), grounded in a research sweep of 8
  comparable products ([research‑brief](../design/research-brief.md)). Implement per
  [roadmap](../design/roadmap.md); first sprint = **Commission + Recover**.
- **Why:** the surface area (commissioning, admin, access, recovery, storage, monitoring,
  moderation, deployment) is large and interdependent; getting the architecture right first
  avoids expensive rework.

### Key design calls (see the design docs for detail)
- **Access model:** operator chooses **Open (default) / Passworded / Accounts**; **two roles**
  (Admin + optional Viewer), never a usable default credential (only a one‑time claim token),
  **localhost/console always trusted as admin**. *Why:* a knowledge appliance's happy path is
  open‑on‑LAN; full RBAC is over‑engineering for the persona.
- **Recovery is paper‑backed + fully local:** a printed recovery card + two‑tier reset (button
  beeps / console menu / `valark setpassword`) + Safe Mode. *Why:* offline → no email reset;
  this is the single most important thing for "a box in a closet."
- **Content‑safety invariant:** the tiny `valark/state` (config) is physically separate from the
  multi‑TB content/model library; **no reset ever wipes Wikipedia/models** — only an explicit
  type‑the‑word disk‑erase does. *Why:* a panic reset must never re‑trigger a multi‑day download.
- **Storage is a growable pool:** primary (fixed, holds the brain) + add/remove drives (USB DAS),
  scaling to **SeaweedFS across computers**; track drives by UUID/label, graceful‑degrade on unplug.
- **Downloads:** disk‑sized **profiles** ("class roles") + **emphasis** (Knowledge/AI/Tools) drive
  curation weights + caps; "Fill everything (Recommended)" default.
- **On‑device moderation** (NPU) for shared uploads, default‑on, private, fail‑closed.
- **Deployment:** ship both a **Docker appliance image** *and* the bare‑metal bootstrap; both
  offline, both commissioned from the same wizard.

## 2026‑07 — Live host metrics, live-first (roadmap Phase 6, part 2 — monitoring)
- A scout→3-design→judge **workflow** weighed live-first vs stack-faithful vs MVP for the
  Telegraf+InfluxDB phase. Verdict: ship an **S-effort live-first MVP** and DEFER the whole
  named stack — because the zero-dep server can read `/proc` + `os` itself, so the Health
  page's **System tiles work day one on a bare box** (CI/VM, no services) and the retention
  layer becomes a pure enhancement, never a dependency.
- **This branch (`feat/metrics-live-gauges`):** one read-gated `GET /api/status/metrics`
  (`getHostMetrics()` — CPU%/mem/load/net-rate/temp/uptime + reused `getDiskStatus()`), a client
  `loadMetrics()` on the existing 15s Health cadence, a friendly **System tiles** strip + ONE
  additive `{key:'system'}` component card (informational: good/warn, `repair:null`, never red),
  and a **neutral "History: live-only"** indicator. NO new POST, NO service, NO secret, NO npm
  dep — so its adversarial surface is a pure local read (same class as `/api/status/disk`).
- **Why live-first beats stack-faithful here:** InfluxDB 2.x needs token-authed first-run setup
  (a real secret + onboarding dance); coupling the visible gauges to that daemon would make the
  Health strip blank whenever it's down. Live-first inverts it — always-on gauges, optional history.
- **Deferred to focused follow-up branches** (named precisely so they graft in additively):
  `scripts/services/{influxdb,telegraf}.sh` daemons + `telegraf.conf` (branch 2); a
  `GET /api/status/metrics/history` **InfluxDB passthrough** via a zero-dep `queryInflux()` —
  THE adversarial-review deliverable (injection/SSRF: never interpolate client range/metric into
  the Flux/URL, pin host to 127.0.0.1, `ECONNREFUSED → {influx:false}` at 200); `.env` token/URL
  keys (git-ignored / auto-minted to 0600 state, PUBLIC repo); `scripts/services/grafana.sh` at
  `/app/grafana/` under Advanced (branch 3); fleet aggregation + SSE metrics push (later).

## 2026‑07 — On-device moderation: fail-closed decision core first (Phase 7)
- A scout→3-design→judge **workflow** designed Phase 7 (screen user uploads with the box's own AI,
  offline). Key inversion it surfaced: **the model + inference is NOT the risky part** — text
  (llama-cli + the already-mirrored Llama-Guard-3-8B) and image (llama-mtmd-cli + moondream2/SmolVLM)
  run today via the exact `verify.sh` single-turn invocation. The **risky part is wiring to a
  surface**: pre-store multipart interception in the zero-dep proxy would replace pipeProxy's
  streaming `req.pipe`, break Range/resumability, risk OOM, add a hand-rolled multipart parser, and
  open a scan-vs-store TOCTOU. So that is **deferred**.
- **Branch order:** ship the fail-closed **decision core in isolation first** (`scripts/lib/moderation.sh`
  + `test-moderation.sh`), adversarial-review it, then wire surfaces. `moderation.sh check <file> --kind
  --sensitivity` → one JSON line + exit code (0 allow / 1 block / 2 hold); a pure `decide(signal,
  sensitivity)` unit; type by **magic bytes** (never the client extension/Content-Type; SVG screened as
  a script-bearing document); `VALARK_MODERATION_CMD` stub hook for tests.
- **FAIL-CLOSED is the invariant** (same class as the Safe-Mode `useMode` fix): absent binary/model,
  timeout, nonzero, unparseable stdout, or a NaN/out-of-range/unknown signal → **hold**, never a silent
  allow. The common bare-box/CI/VM case has no model → that IS the fail-closed path (needs no inference).
- **Deferred (own branches, each reviewed):** the real enforcement surfaces — a NodeBB post-store
  quarantine sweep (highest-risk: open self-registration, plain-file uploads, no proxy surgery) then a
  pre-store paste multipart intercept; the server endpoints (`/api/moderation/{check,queue,review}`,
  `/api/status/moderation`) + the admin Safety card + Sensitivity slider; and a dedicated NSFW **ONNX**
  head (Xenova/nsfw_image_detection) which needs a mirrored onnxruntime CLI/wheels — the mirrored ORT is
  library-only/CPU-only today. NPU (.rknn on RK3588/UT2) later.

## 2026‑07 — Metrics HISTORY is a zero-dep ring buffer (Phase 6b part 2)
- A scout→3-design→judge **workflow** pitted InfluxDB-v2-Flux vs InfluxDB-v1-InfluxQL vs a
  **zero-dep on-disk ring-buffer challenger**. The ring won (9/10): the server already produces
  every datapoint via `getHostMetrics()`, so it **samples itself** into a capped
  `state/metrics-history.jsonl` (~24h) and serves it at read-gated `GET /api/status/metrics/history`
  — sparklines under the shipped System tiles with **NO service, NO token, NO npm dep, NO outbound
  call**. Decisively, the ring is the ONLY path where sparklines render on a bare box/CI/VM (the
  InfluxDB path shows nothing until ~1GB of daemons + token onboarding run) — consistent with the
  live-first call above.
- **Fixed a real bug found in the design:** `getHostMetrics()` mutated a single module-global
  `_metricsPrev` for its two-sample deltas — the live endpoint and a sampler would contend over one
  baseline. Refactored to `getHostMetrics(prev = _metricsPrev)` returning the fresh counters as a
  non-enumerable `_sample` (never serialized); the live endpoint and the sampler each keep their OWN
  baseline. The always-on server is the SINGLE writer (like `heal-events.jsonl`); `loop.sh` never
  touches this file. `?window` is allowlist-mapped to a fixed point cap (never a path/slice index).
- **InfluxDB/Telegraf/Grafana are the deferred, opt-in Advanced/fleet upgrade** — grafted onto the
  SAME endpoint later under an allowlisted `?source=influx`, for long retention + cross-node rollup
  (the genuine InfluxDB payoff a single appliance may not need yet). That branch carries the
  injection/SSRF-sensitive `queryInflux()` passthrough → its own adversarial review.

## 2026‑07 — Health & Repairs page (roadmap Phase 6, part 1 — self-heal UX)
- Shipped the **Health/Repairs UX** first (metrics stack is a separate branch): a `#/health`
  page with **strict green/yellow/red** per-component cards, **fault attribution** (drive / this
  box / internet / config), a **healed-events feed**, and **one-click Repair**. Matches
  [errors-selfheal.md](../design/errors-selfheal.md) to the letter.
- **Data flows from reports the loop already should have produced.** `verify.sh` now serialises
  each functional check into `verify.json` as `checks[]` (`{status, comp, label}`); `loop.sh`
  now actually **writes `selfheal.json`** (a long-standing log line promised a file nothing wrote)
  + an append-only, capped **`heal-events.jsonl`** feed of genuine repairs. `GET
  /api/status/health` (read-gated) composes them; the **UI computes the component list
  client-side** (`computeComponents()`) from those + the live disk/services/kiwix status the
  shell already fetches — no duplicated health logic on the server, minimal new server surface.
- **One repair endpoint, not many.** `POST /api/maintenance/repair` (admin-only) runs the loop's
  own fixers via a **fixed argv** (`loop.sh once`) — the honest "fix everything" button — so no
  request data reaches a shell. Targeted fixes reuse what exists: per-service **Restart** →
  `POST /api/service/start`; Safe-Mode → the existing **Recover** flow. Deduped + 30s rate-limit.
- **Adversarial-reviewed** (new gated endpoint) before merge; `test-health.sh` + `health.spec.ts`
  cover the report shapes, the composition endpoint, the read-gate, and the admin-gate (the last
  via the fail-safe `VALARK_TEST_NO_SPAWN` hook so CI never runs the heavy loop).
- **Next:** stand up Telegraf + InfluxDB as mirrored services and feed live metrics into the strip.

## 2026‑07 — Download queue as the monitoring surface (roadmap Phase 5, part 1)
- Rebuilt the **Activity** view into a live download **queue**: rich per‑item cards (plain‑language
  label, animated progress bar + %, **ETA** from `startedAt`+progress, status pill, last line),
  **Cancel** (running) / **Retry** (failed), a "resumes automatically after a power loss" note, and
  **Retry‑not‑error framing** — a failed download reads "Interrupted — retries automatically" (true:
  the self‑heal loop re‑runs it), never a scary red error.
- **Live**: reuses the existing SSE stream — `start` stamps a client `startedAt` (for ETA),
  `progress`/`complete` re‑render the queue only when on `#/activity` (`_activityLive`, rAF‑debounced);
  `loadDownloads()` merges `/api/status/downloads` (server truth incl. `startedAt`) once on load to
  catch downloads already running. No backend changes, no new endpoints.
- **Deferred:** true pause/resume + reorder need backend support (the download scripts are aria2/curl
  subprocesses — only cancel exists today); noted as a follow‑up.
- **Profiles → curation weighting (part 2):** the wizard's profile pick now drives REAL librarian
  priority. `catalog.sh` resolves the profile (`VALARK_PROFILE` env → `settings.json` → `balanced`)
  and applies a **per‑bucket multiplier** on each candidate's value (knowledge 1.6× content, ai 1.6×
  models, tools 1.6× tools; off‑buckets 0.8–0.9×), so the box fills what the owner asked for; the
  planner still sorts by value/bytes. A Settings → **Downloads & Priorities** picker changes it live
  via admin‑only `POST /api/setup/profile` (validated to the 4 profiles). `test-profile.sh` proves a
  profile shifts the fill; requesting a specific item still jumps the queue (pins).

## 2026‑07 — Access-mode enforcement + admin sessions (roadmap Phase 2 depth)
- The access layer now **enforces** (was "no gating yet"): stateless HMAC **admin sessions**
  (`auth.issueSession/verifySession`, `varksid` HttpOnly cookie), `POST /api/auth/login｜logout`
  with a per-IP login cooldown, `isAdmin(req)` = localhost OR valid session, and a POST **access
  gate** — admin-only actions always need admin; use-actions need admin in Passworded/Accounts
  mode; Open stays open. UI: a sign-in modal + Settings sign-in row; 401 `{needsAuth}` prompts it.
- **`adduser` upgraded** from localhost-only to admin (localhost OR logged-in) — a remote admin can
  now manage service accounts.
- **Scoped:** the read-wall (gating GET views in Passworded/Accounts) and full Accounts-mode named
  users are follow-ups; this ships the write/use + admin gate (the sensitive actions).
- Security surface → ran a 3-lens adversarial-review Workflow before merge. Tests:
  `tests/test-access.sh` (12, real-server gate via `VALARK_TEST_FORCE_REMOTE`) + auth session unit
  tests + server-api login/logout + a web-ui sign-in spec. Full suite 8 validators + Playwright 321/1.

## 2026‑07 — Consumer shell: Home status + Settings + Activity (roadmap Phase 3, issue #12)
- Delivered the shell's essence **additively** (no route regressions): a health‑app **Home
  status summary** (● All good / Working on it / Needs you + one sentence + big area/utility
  cards), a consolidated **Settings** hub (`#/settings`, Basic/Expert, the design's section list +
  inline Storage + About/Rescue), and an **Activity** feed (`#/activity`, live downloads + events
  placeholder). New nav link **Settings**; `computeHealth()` derives green/amber/red from the
  status the app already fetches (disk, services, downloads).
- **Why additive, not a full 4‑tab teardown:** ~15 existing tests click the current nav links
  (Software/Models/Library/Community/Getting Started). Ripping the nav to a literal four tabs would
  churn them for little user gain right now; the summary‑Home + Settings hub deliver the consumer
  experience without regressions. The literal 4‑tab cap (folding Software/Models into Home cards,
  Getting Started into the wizard) is a **noted follow‑up**.
- Tests: 5 Playwright specs (Home status + 6 cards, Settings nav + hub + inline Storage,
  Basic/Expert reveal, Activity, light‑theme render). Full suite 319/1 green, no regressions.

## 2026‑07 — First‑boot commissioning wizard (roadmap Phase 1, issue #11)
- Shipped the commissioning **core**: `scripts/lib/commission.js` (claim‑token gate + settings
  store, builds on `auth.js`), server `GET /api/setup/state` + `POST /api/setup/commission`
  (fail‑closed on the claim token from the LAN; localhost/console trusted), a startup **claim‑code
  console banner**, `valark claim｜setup-status`, and a **full‑page web wizard** (`#/setup`:
  Welcome → Claim → Name → Admin → Focus → Done) that auto‑takes‑over an un‑commissioned box.
- **Grandfather rule** so existing installs aren't hijacked: a box with a content/model library is
  treated as commissioned (see gotchas). Fresh box (empty library) → wizard.
- **Deferred to follow‑ups** (noted in the PR): the OS‑level discovery/enablement — mDNS
  `valark.local` (avahi), hostname set, captive‑portal at the network layer, the port‑80 toggle
  wiring, `setup.sh --VALARK_YES` integration, the on‑screen TUI, and the topic‑picker → curation
  weight mapping. The state machine + claim gate + wizard + create‑admin (wired to #10) are the core.
- Tests: `tests/test-commission.sh` (10 checks incl. fail‑closed + single‑use token +
  content‑safety), server‑api `/api/setup/state` shape+no‑leak, web‑ui wizard render+step‑through,
  and a fresh‑VM commissioning assertion in `provision.sh`.

## 2026‑07 — Access identity + recovery foundation (roadmap Phase 2, issue #10)
- **Safety net lands first** (research's #1 lesson). Shipped the backend + CLI foundation, no UI
  gating yet (Open stays default): `scripts/lib/auth.js` (scrypt‑hashed admin store, shared by
  server + CLI), `scripts/valark` (`setpassword｜auth status｜auth list｜verify｜usemode｜reset
  --tier1/--tier2`), and read‑only `GET /api/auth/status`.
- **No usable default credential** — an un‑set admin means Open mode + "localhost/console is
  admin," which is exactly what makes password‑less recovery safe. Passcode is scrypt‑hashed in a
  0600 `<state>/auth.json`; the hash/salt never cross the API.
- **Content‑safety invariant is structural + tested:** `STATE_DIR` is separate from
  content/models, so `reset --tier1/--tier2` provably can't wipe the library
  (`tests/test-auth.sh` sha256‑verifies sentinels survive). Content‑erase is deliberately NOT in
  this CLI (it needs the typed‑confirmation UI flow).

## 2026‑07 — First `dev → main` release (v1.1.0) + community sign‑ups (PR #2/#3)
- **Adopted the branch model in practice:** PR #1 (foundational) landed on `dev`; the
  community‑signups quick win (PR #2) landed on `dev`; then the first **`dev → main` release**
  (PR #3) shipped **v1.1.0**. Release cleared the high bar: CI green + full local Playwright
  (310/1) + services e2e (11/0) + **fresh‑VM matrix 27/0 across Ubuntu 22.04/24.04/26.04**.
- **CI is a real gate now.** A fresh CI checkout has *no mirror*, so host‑population tests
  (on‑disk binaries, non‑empty status maps) **skip‑when‑empty**; CI validates code + endpoint
  shape + upstream URL health, while populated‑system e2e runs locally + in the VM matrix. One
  real strict‑mode locator bug was fixed (`#install-btn-<id>` vs `:has-text("Mirror")`).
- **Community account model = per‑service tech, not one UX** ([[val-ark-forum-proxy-burst-quirk]]):
  `COMMUNITY_ACCOUNTS[id].signup` ∈ `host｜self｜shared`. chat/mail = host‑provisioned
  (`<svc>.sh adduser`, one‑step for mail); forum = NodeBB self‑register; paste = shared gated
  instance. `POST /api/service/adduser` is **localhost‑only** (minting a login is admin).
- **Release merge = rebase (main requires linear history).** Rebase‑merge re‑parents dev's
  commits onto `main`, so after a release `main` and `dev` share *content* but diverge by *SHA*
  (`git diff origin/main origin/dev` is empty; commit counts differ). This is benign: GitHub's
  rebase‑merge skips already‑applied patches, so the next release applies only new commits. Tag
  `main`'s tip directly (`git tag -a vX.Y.Z`) — `scripts/release.sh` wants a clean tree, which the
  untracked local `.memsearch/` trips.

## 2026‑07 — Feature branch: discover/request + self‑replication + tests (PR #1)
- Shipped + deployed to the ARM64 NAS test node + tested (337 tests): Library relabel; Community hub; one‑click
  LAN/tailnet **catalog + request** with **pin + cap‑aware auto‑evict**; **offline
  self‑replication** (git bundle + Node runtime + `bootstrap.sh` + `mirror-self.sh`); fixed
  per‑platform app downloads (`/api/archive`); cross‑arch service fixes; curation (Linux docs +
  setup assistants); the **test library + offline HTML report + fresh‑VM matrix (Ubuntu 22/24/26)**.
- **Why the request/evict shape:** the librarian already did diversity→small‑value→fill→evict;
  a per‑item `request` that pins + evicts the lowest‑priority *unpinned* content extends it
  cleanly and honors the footprint cap.

## Earlier project facts (fleet, curation)
- **Fleet/hardware & mesh:** big shared disk, several boxes (an ARM64 Grace‑Blackwell node, an x86 GPU workstation, a router, an ARM64 NAS),
  NFS/Syncthing sharing, tailscale‑ssh. The data disk is the one shared mirror; GPU nodes infer
  over the network. (Host‑specific addresses/creds are **not** in git — see the deployment host's
  own `.env`.)
- **Curation priority model:** live Kiwix OPDS catalog → planner phases
  diversity → small‑value → fill → evict‑for‑better; value = curated category weight + language +
  density + topic boosts (now including a strong Linux/shell boost, so an offline user can get
  setup help from the box).
