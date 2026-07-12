# Val Ark — Decisions & Progress Log

Architecturally significant decisions and notable progress, newest first. Format:
**context → decision → why.** Append when you make a call worth remembering (or reversing
later). See [README](README.md).

---

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
  subprocesses — only cancel exists today); noted as a follow‑up. Profiles→curation weighting is the
  next Phase‑5 branch.

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
