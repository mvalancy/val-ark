# Val Ark — Operational Gotchas & Hard‑Won Fixes

Non‑obvious things that cost real time. Format: **symptom → cause → fix.** Add to this when
you hit (and solve) something the diff alone wouldn't explain. See [README](README.md).

## Shell / ops

- **`pkill -f "<pat>"` / `pgrep -f "<pat>"` kills your own command.** The shell running the
  command has `<pat>` in its own argv, so the pattern matches itself (and over tailscale‑ssh,
  the `tailscaled --cmd` argv too) → the session dies (exit 144). **Fix:** kill by port
  (`fuser -k 3000/tcp`) or an explicit non‑self PID; never `-f` a pattern that appears in the
  kill command itself.
- **Backgrounded processes die when the Bash tool command exits** (local sandbox kills the
  process group). **Fix:** for a persistent server use the tool's `run_in_background`, or on a
  remote host `setsid nohup … </dev/null & disown`.
- **`date +%s%3N` isn't portable** (busybox in a VM emits garbage) → nonsense durations. **Fix:**
  clamp absurd values in consumers (the report does).

## Cross‑architecture (arm64 boxes: Jetson-, Grace‑Blackwell-, Rockchip-class)

- **Source-compiled tools cross-place a WRONG-arch binary — fix at the mirror, not just at
  runtime.** `redis.sh`/`sqlite.sh` build from source with `make`/`gcc`, which target the
  **build host's** arch. Mirrored on an x86_64 host, they dropped an **x86 binary into
  `tools/linux-arm64/`** (`+x` set, so it looks fine) → "Exec format error" on every arm64 box,
  which the Health page flags as "tool present but won't run". **Root-cause fix:** compile ONLY
  for the platform matching `uname -m`; for the other arch keep source + a build-on-target hint
  and **scrub any binary from both `bin/` and the source dir** (`verify.sh` finds by name
  *anywhere* under the tool dir). Runtime fallback (`forum.sh find_redis_server`, verify's
  `"$bin" --version` gate) is still the belt; `tests/test-tool-arch.sh` guards the class (ELF
  arch of each runnable binary must match its platform dir). To get a working native binary on an
  arm64 box, re-run the tool script **on that box** (or `apt install`).
- **NodeBB (forum) is mirrored x86_64‑only; its native `sharp` module crashes on arm64.**
  **Fix:** `forum.sh ensure_native_deps` reinstalls native deps for the host `--os/--cpu`.
  Same class applies to any Node app with native modules.
- **Runtime discovery must prefer the MIRRORED runtime.** Offline boxes have no system
  `node`/`nvm`; check `tools/<platform>/node/bin/node` first (`chat.sh _chat_node` missed this,
  so The Lounge never built). Mirror the robust pattern from `loop.sh _va_node`.
- **Community‑service webs need heavy builds:** NodeBB (npm), The Lounge (npm/webpack),
  ngIRCd (autotools). alps webmail needs a **Go toolchain** (not present on the RK3588) — maddy
  IMAP/SMTP works without it. paste (MicroBin) is a static binary; auth‑gated by design.

## Downloads / mirroring

- **hf‑repo model downloads (e.g. `rhasspy/piper-voices`) fail with exit 127 if the `hf` CLI
  is missing** — silent for a while, then "command not found." **Fix:** `pip install -U
  huggingface_hub` (provides `hf`); `setup.sh` marks it optional but it's required for repo pulls.
- **`/api/archive` HEAD returned 405**, so the UI's download HEAD‑preflight thought every app
  download was broken. Cause: `handleAPI` only allowed GET/POST. **Fix:** let HEAD flow through
  the GET path; `serveArchive` answers HEAD with headers only. Tool downloads = the real mirrored
  artifact via `/api/archive/tools/<platform>/<downloadTarget>` (dir name = **downloadTarget**,
  not always the id — e.g. `piper-tts` → dir `piper`).
- **Content shown "Not Mirrored" though present:** exact dated‑filename matching (`…_2025‑08.zim`)
  vs. the actual `…_2026‑02.zim`. **Fix:** match a date‑independent pattern (`CONTENT_LIBRARY[].match`).
- **NEVER mix resumers on one `.part` — `curl -C -` on an aria2 partial silently corrupts** (#54).
  An aria2 (`-x8`) `.part` is *segmented* — 8 non‑contiguous ranges, and with the default
  `--file-allocation=prealloc` it is **full‑length from the start** — not a linear prefix. `curl -C -`
  resumes from the file's byte‑length, so it "completes" a hole‑filled file instantly (curl ≥7.76
  even treats the server's 416 as success); the ≥90 % size gate passes, a size‑only `verify` never
  catches it → a corrupt flagship ZIM is served forever. **Rule:** the `.aria2` control file marks an
  aria2‑owned partial; while it exists only aria2 may touch the `.part` (skip the curl fallback; if
  aria2c was uninstalled, delete the pair and let curl start fresh). **Corollary:** a *transient*
  failure must keep `.part`+`.aria2` (or a ~100 GB download restarts from 0 every cycle), while a
  *size‑short‑after‑"complete"* file is a catalog/serve mismatch — resuming it wedges retries or
  splices two file versions, so clear it. Kept partials are age‑GC'd in `verify`
  (`VALARK_PARTIAL_MAX_AGE_DAYS`, default 14) so dead URLs can't strand gigabytes.

## Storage / data root

- **`VAL_ARK_DATA` autodetect can pick the wrong mount** (once landed on a backup target that
  got pruned overnight). **Fix:** set `VAL_ARK_DATA` explicitly in `.env` on multi‑mount hosts.
- **Default footprint cap can be tiny** — a box with 7 TB free had `VALARK_MAX_GB=500`, so almost
  nothing mirrored. Check the cap when "nothing downloads."

## Test / VM harness

- **`run-all.sh`'s green/red gate must not depend on node.** The runner's exit code came
  solely from `report/generate.mjs`; with no node on the host (fresh appliance, minimal
  container) it exited 0 even when suites failed. Every suite writes `results/*.json` with an
  unspaced `"failed":N` (results.sh), so the no-node path greps `"failed":[1-9]` across them
  and exits non-zero — zero-dep, and it covers bash validators, services e2e and the VM matrix
  uniformly (their sub-runner exit codes are deliberately not the signal; the JSONs are).
  Sandbox-tested by `test-runner-exit.sh` (copied runner + node-free PATH shim).
- **multipass is snap‑confined:** its `home` interface reads only **non‑hidden files under
  `$HOME`**. Staging a transfer from `/tmp` → "sftp cannot access"; from `~/.cache` (hidden) →
  "permission denied." **Fix:** stage under a non‑hidden repo path (e.g. `tests/results/`).
- **Unattended `setup.sh` needs headless mode** (`VALARK_YES` / non‑tty) or it prompts forever
  and the box ends up with no Node. For a truly offline bootstrap, `setup.sh` fetches Node from
  the source Ark (`VALARK_HOST`) before nodejs.org.
- **CI gate vs public-mirror rate limits (`test-urls.sh`):** shared GitHub-runner egress IPs
  get throttled (429/403) by public mirrors, so a *sustained* retryable status (000/429/403/
  408/425/5xx) is a **WARN under CI** (`CI=true`/`GITHUB_ACTIONS`) and a FAIL only locally;
  404/410 stays a hard FAIL everywhere (real dead-link detection). Don't re-add a ranged-GET
  fallback after a definitive HEAD 429/403 — the second request only amplifies the throttle.
  The logic is unit-tested offline by `test-urls-logic.sh` (sources the guarded functions,
  stubs `curl`/`sleep` as shell functions — zero network).

## Community services / accounts

- **`set -u` + optional arg = "unbound variable":** service scripts run under `set -u`, so
  `local user="$1" pass="$2"` **crashes** when `adduser` is called without a password. **Fix:**
  default optional positionals — `local user="${1:-}" pass="${2:-}"`. Bit both `chat.sh` and
  `mail.sh` `cmd_adduser`.
- **Account model differs per service — don't force one signup UX.** chat is **open** by default
  (public/no-login — pick a nickname and join); maddy (mail) has no safe self‑signup → the **host
  provisions** logins (`mail.sh adduser <name>`); NodeBB (forum) has its **own Register page**
  (self‑service); MicroBin (paste) is **one shared gated instance**. The server encodes this as
  `COMMUNITY_ACCOUNTS[id].signup` = `open｜host｜self｜shared`, surfaced in `/api/status/services`
  and the UI panel. **chat's model is dynamic** (`open` unless `VALARK_CHAT_PUBLIC=0`, then `host`)
  — keep it in sync with the mode, or a private operator's `adduser` breaks. `open`/`self`/`shared`
  short‑circuit `addServiceUser` **before** username/password validation, so validation tests must
  target a **host** service (mail), not chat.
- **The Lounge (chat) defaults to PUBLIC / no-login.** A trusted-LAN community box shouldn't make a
  visitor hit a login wall with no way to make an account (the old private-mode default did exactly
  that — the box was unusable without shell access). Val Ark's reverse proxy + Use Mode already gate
  *who* reaches `/app/chat/`, so The Lounge needn't re-auth. `VALARK_CHAT_PUBLIC=0` restores per-user
  logins + persistent history.
- **A "write-once if exists" config can never change on a deployed box.** `chat.sh` used to write
  The Lounge `config.js` only when absent, so flipping the access mode never took effect on a box
  that already had one. Config writers that carry a *setting* must **regenerate every start** (back
  up to `.bak`), like `_write_ngircd_conf` already did.
- **ngIRCd `MaxNickLength` defaults to 9 (classic IRC).** Ordinary names — even The Lounge's own
  default nick — get rejected "nickname too long". Set it in `[Limits]` (30 is safe, within the
  compiled limit). Also pre-create a few `[Channel]` blocks + a multi-line MOTD teaching `/list`
  and `/join`, so a first-timer isn't stuck in one empty room.
- **The Lounge start must capture the REAL pid (nohup, not setsid).** `setsid` forks, so `$!` was
  the dead parent → a wrong pidfile → the loop's per-cycle `start` spawned duplicate instances that
  fought over `:9000`. Use `nohup ... & echo $!` for the true pid, plus a **port-based liveness
  fallback** (`_lounge_up`) so a stale pidfile can never trigger a duplicate start.
- **Minting a login is an admin action → `POST /api/service/adduser` is admin‑gated.** LAN
  users self‑register on the forum, join chat with just a nickname, or ask the host; only the
  operator (localhost/admin) provisions **mail** logins. The UI hides the create form off‑admin
  (`isAdminHost()` mirrors the server gate).

## Auth / recovery (Phase 2)

- **Source `valark-env.sh` BEFORE `set -u`.** The shared env file predates nounset hygiene and
  reads its own guard (`_VALARK_ENV_LOADED`) unguarded → "unbound variable" if you `set -u` first.
  In a new script: source the env, *then* `set -u` (see `scripts/valark`).
- **Content-safety invariant is structural.** `STATE_DIR` (=`<VALARK_HOME>/state`, holds
  `auth.json`) is a sibling of `content/` and a cousin of `models/` (`<DATA_ROOT>/models`) — never a
  parent. So resets that only remove files *under* `STATE_DIR` provably can't touch the multi-TB
  library. `valark reset` still asserts `CONTENT_DIR`/`MODELS_DIR` aren't inside `STATE_DIR` before
  acting, and `tests/test-auth.sh` sha256-checks the sentinels survive a `--tier2` reset.
- **No default credential, ever.** An un-set admin = Open mode + "localhost/console is admin"
  (that's what makes password-less recovery safe). The passcode is scrypt-hashed in a 0600 file;
  the hash/salt must never cross `/api/auth/status`.

## Commissioning (Phase 1)

- **Grandfather existing installs or the wizard hijacks working boxes** — but SNAPSHOT the
  decision, never derive it live. A box has no `commissionedAt` until setup runs, so naive
  first-boot would show the wizard on every deployed Ark. `_legacyActive()` treats a box with a
  **content or model library** as already set up. **Adversarial-review finding (fixed):** deriving
  `commissioned` *live* from the library was a bypass — the `/api/download/*` scripts `mkdir -p`
  into `MODEL_ROOT` *before any download*, so an un-authenticated LAN peer could POST to those
  ungated endpoints, make the library non-empty, and flip a fresh un-owned box to "commissioned",
  permanently locking its owner out of the web wizard. **Fix:** the grandfather decision is made
  **once at first server start** (`commission.grandfather()` writes `commissionedAt`); thereafter
  `boxCommissioned()` reads ONLY the persisted flag, so post-boot library files can't flip it. AND
  every mutating POST is refused with 409 until the box is commissioned (a fresh box serves the
  wizard, not the catalog). `_legacyActive` honors `VALARK_ZIM_DIR`/`VALARK_CONTENT_DIR` so it's
  isolatable; `tests/test-commission.sh` spins a real server to prove the flip is impossible.
- **Claim gate is fail-closed but localhost-trusted.** From the LAN you must present the printed
  claim token; from the box/localhost you commission without one (physical possession = ownership,
  which also keeps recovery possible). The token is single-use (consumed on commission) and never
  crosses `/api/setup/state` — only `needsClaim`/`hasClaim` booleans do.
- **The wizard is a `file://`-safe SPA takeover.** `#/setup` renders with inline CSS and no
  server, so Playwright previews it offline; `checkSetup()` only redirects when it can reach
  `/api/setup/state` and the box is un-commissioned.

## Access control / sessions (Phase 2)

- **The gate has three tiers.** `ADMIN_ONLY_POSTS` (config/account changes, e.g. `adduser`) always
  need admin; **use-actions** (downloads/requests/service starts) need admin only when Use Mode is
  Passworded/Accounts (Open = anyone on the LAN); and the **read-wall** (`isReadGated`/`readAllowed`)
  gates content READS (`/api/status/*`, `/api/catalog/*`, `/api/archive/*`, `/kiwix/*`, `/app/*`) in
  Passworded/Accounts mode. `isAdmin(req)` = **localhost/console** (always admin — physical
  possession) **OR** a valid session. Login/logout/commission are gate-exempt (you can't be authed
  to log in).
- **The read-wall is two-layer.** Server: content endpoints 401 for un-authed LAN visitors in
  Passworded/Accounts mode — but the **UI shell + `/api/auth/*` + `/api/setup/*` + `/api/health` +
  `/ca.crt` stay open** so the login wall can render and you can sign in. Client: `checkAccess()`
  renders a full-page wall (`renderAccessWall`) before loading the app. Open mode is unchanged, so
  the existing (Open-default) tests don't regress; the wall is exercised via `VALARK_TEST_FORCE_REMOTE`
  in `test-access.sh` and a forced-state Playwright render.
- **A read-wall must gate the raw STATIC data dirs, not just the API doors** (adversarial-review
  finding, high). The static router serves `/content`, `/models`, `/tools`, `/sources`, `/assets`,
  `/docs` straight from ROOT (symlinks to the data disk) — the **same library bytes** that `/kiwix/*`
  and `/api/archive/*` gate. Gating only the `/api`/`/kiwix`/`/app` prefixes left the front door
  open (`curl /content/zim/wikipedia.zim` un-authed). `isReadGated` now also matches
  `^/(content|models|tools|sources|assets|installers|docs)(/|$)`. Lesson: gate by **what the bytes
  are**, not just by URL prefix — a mirror has many doors to the same content.
- **Sessions are stateless HMAC tokens** (`payload.hmac`, signed with a per-box secret in the auth
  store), so there's no session table. Cookie `varksid` is HttpOnly + SameSite=Lax. **"Sign out
  everywhere" = rotate the secret** (`auth.rotateSessionSecret`) — a per-client logout only drops
  the cookie (the token stays cryptographically valid until expiry, the usual stateless tradeoff).
- **Testing the LAN gate:** localhost always bypasses, so set `VALARK_TEST_FORCE_REMOTE=1` to make
  the server treat the client as remote and actually exercise the gate. It's **fail-safe** — it only
  REMOVES the localhost admin bypass, never grants access (safe even if set in prod).
  `tests/test-access.sh` spins a Passworded server and proves unauthed use → 401, login → cookie,
  cookie → allowed, forged session → 401.
- **The login cooldown is per-IP + non-permanent** (8 fails / 10 min → 429), never a hard lock —
  localhost/console always bypasses, so the owner is never locked out.
- **Session hardening (from the adversarial review — the HMAC/gate core was sound, these are
  defense-in-depth):** (1) sessions are **IP-bound** (`issueSession(dir, ttl, ip)` / `verifySession(…,
  ip)`) so a cookie captured on the wire can't be replayed from another host; (2) the cookie gets
  **`Secure` only over TLS** (`isSecureReq` — marking it Secure on the default plain HTTP would
  silently drop it); (3) `pipeProxy` **strips `varksid`** before forwarding to sub-apps (NodeBB/
  kiwix/…) so the admin token never reaches third-party backends; (4) a **global** login cap
  (40/10min) on top of per-IP so NIC-alias IP rotation can't multiply guesses; (5) min passcode
  length raised to **8**.

## Recovery card / forgot-password (Phase 2)

- **Recovery code = the paper backup, so it's stored plaintext (0600), like the claim token** —
  the whole point is to reprint it on the recovery card. It lives in `<state>/settings.json`
  (`recovery`), off the world-readable content disk. `verifyRecovery` is a constant-time compare;
  the code is **single-use** (rotated on every successful recover — old card is dead, new one
  returned to reprint).
- **Two recovery paths, mirroring the design:** `localhost`/console resets the admin passcode with
  **no code** (physical possession); a **LAN** device must present the recovery code from the card.
  `POST /api/auth/recover` (in `AUTH_EXEMPT_POSTS` — you can't be authed to recover) enforces both,
  shares the **login cooldown** (it's a code-guessing surface), and auto-signs-in the recovered admin.
- **The card endpoint leaks a secret, so it's admin-only.** `GET /api/setup/recovery-card` returns
  the code ⇒ `isAdmin` required (localhost or a session); un-authed peers get 401. The code is shown
  in the clear exactly twice: the wizard's "All set!" screen and an admin's Settings → Show recovery
  card.

## Safe Mode (Phase 2)

- **Distinguish MISSING config from CORRUPT config.** `readSettings`/`readStore` swallow parse
  errors and return defaults, so a corrupt `settings.json`/`auth.json` would silently look like a
  fresh box. `commission.configHealth` checks explicitly: ENOENT = fine (fresh), present-but-
  unparseable = **Safe Mode**. Surfaced on `/api/health` (`status:"safe-mode"`) + `/api/setup/state`,
  and the UI takes over with a "needs attention → Reset & recover" screen (never a dead port).
- **Safe Mode must WIN over grandfather.** `_legacyActive()` (content present) would otherwise run
  `grandfather()` at startup, which **overwrites** the corrupt `settings.json` — silently masking
  the corruption and losing the recovery code. The startup block now checks Safe Mode FIRST and
  skips grandfather/ensureClaim when corrupt. (This is what the safemode test caught.)
- **Auth/recovery endpoints must bypass the "not set up yet" 409 gate.** A corrupt-config box reads
  as un-commissioned, so the `boxCommissioned()` POST gate would 409 `/api/auth/recover` — locking
  you out of recovery. The gate now exempts all `AUTH_EXEMPT_POSTS` (login/logout/recover/commission),
  not just commission. Recovery from **localhost** (no code) repairs both `auth.json` (setPassword)
  and a corrupt `settings.json` (reset to a minimal commissioned state) so Safe Mode clears with no
  restart; content is never touched.
- **Safe Mode must FAIL CLOSED (adversarial-review finding, medium).** Surfacing `safeMode` isn't
  enough — a corrupt `auth.json` makes `auth.status().useMode` read as the swallowed default `'open'`,
  which would DROP the read-wall + open every use-action. So `readAllowed` and the POST access gate
  now treat `safeModeState().safeMode` as "requires admin" (localhost/session), independent of the
  useMode read from the corrupt store. `safeModeState()` is cached ~3s (it's on the read/POST hot
  path) and invalidated on recover.
- **`loginAllowed` MUST bypass for localhost (review finding).** The doc said "the owner is never
  locked out" but the global login cap applied to localhost too — a LAN peer could trip it and 429
  the owner's own recovery. `loginAllowed` now `return true` for `isLocalhost(req)` first.

## Health / self-heal (Phase 6)

- **The self-heal snapshot is `selfheal.json`, NOT `health.json` — the latter was already taken.**
  Phase 6a's `write_health()` first wrote `state/health.json`, but `librarian.sh maintain` has
  written its OWN `state/health.json` (disk/library stats: `data_root, avail_bytes, managed_items`)
  for ages. Same filename, incompatible schemas → a standalone `librarian maintain` clobbered the
  Health page's data (only a real box running both surfaced it; the isolated tests seeded the file
  directly). Renamed the loop's report to `selfheal.json` (writer `loop.sh` step 8b, reader
  `server.js getHealthDetail`); librarian keeps `health.json` (vestigial — nothing reads its fields).
  **Lesson:** before naming a new state file, grep the repo for that filename — a sibling script may
  already own it.
- **`verify.sh` had only aggregate counts before Phase 6** — `write_health()`/`write_report()` now
  emit the per-check + repair detail the Health page needs. If a doc/log references a state file,
  grep for the *writer* before building a reader on top of it.
- **Emitting JSON from bash — escape, and only trust program-controlled strings.** `verify.sh`
  `_json_str` / `loop.sh` `_hj_str` escape `\` + `"` and strip tab/newline/CR. That's safe
  *because* every interpolated value is our own (check labels, repair sentences, `date -u`,
  integer counts). The moment you interpolate an attacker-influenceable value (a ZIM/model
  **filename**, a URL, a service id) into a bash-built JSON string, that escaper is the only
  thing between you and JSON/field injection — keep such values out, or escape them the same way.
  Write atomically (`.tmp` → `mv`) so a reader never sees a half-written report.
- **`/api/status/health` is read-gated for free — because `isReadGated` matches the prefix.**
  Any new `/api/status/*` GET is caught by `startsWith('/api/status/')`, so it inherits the
  read-wall (Passworded/Accounts LAN visitors must be authed). Don't add a bespoke gate; don't
  put box-revealing detail on an *un*-gated path (only `/api/health` + `/api/status/tls` are
  exempt, and they're deliberately minimal so the login wall can render).
- **The self-heal "Repair" button must carry NO request data into the command.** `POST
  /api/maintenance/repair` runs a **fixed argv** (`bash loop.sh once`) via `spawn` (no shell) —
  the loop's own fixers, nothing from the body. That's what makes a "run a shell script" endpoint
  safe to expose. It's `ADMIN_ONLY_POSTS`, deduped (`_repairProc`) + rate-limited (30s).
- **Test hooks must only ever *subtract* capability.** `VALARK_TEST_NO_SPAWN=1` makes the repair
  endpoint skip the actual `loop.sh` spawn (so CI/Playwright never runs the heavy loop) but it
  runs **after** the auth gate and only *prevents* the action — never grants access. Same
  fail-safe direction as `VALARK_TEST_FORCE_REMOTE=1` (which only removes the localhost bypass).
- **Live metrics are two-sample deltas → the first read is null by design.** `/api/status/metrics`
  computes CPU% and net rate from the *difference* between two `/proc/stat`/`/proc/net/dev`
  snapshots. The server keeps only the previous sample (`_metricsPrev`) and does NOT sleep between
  reads — the client's 15s Health poll spaces them. So the very first call after boot returns
  `cpu.percent: null` / `rxRate: null` (no baseline yet), filled on the next poll. UI shows an
  em-dash, never `NaN`/blank; tests assert the *second* read is a number. Also: guard the
  cumulative-counter wrap/reset (`Δ < 0 → null`), and `mem.used = MemTotal − MemAvailable`
  (NOT `− MemFree`, which excludes reclaimable cache and overstates used).
- **Live gauges must not depend on Telegraf/InfluxDB.** The zero-dep server reads `/proc` + `os`
  itself, so the Health System tiles work on a bare box in CI/VM with no services mirrored. Every
  `/proc`//`sys` read is individually try/caught → the field degrades to `null` off-Linux
  (macOS/Windows/CI get load+uptime+mem-fallback; net/temp/cpu% go null) and the handler NEVER
  throws. Don't shell out per request — reuse the 10s-cached `getDiskStatus()` (its `df` can hang
  on a stale NFS mount) and `fs.readFileSync('/proc/...')` for the rest.

## Content moderation (Phase 7)

- **A permissive WRAPPER can re-open a fail-closed CORE** (adversarial-review finding, **high**).
  `moderation.sh` deliberately decides content type by **magic bytes**, never the client's hint —
  but the first cut of `POST /api/moderation/check` accepted a `?kind=`/`?sensitivity=` query
  param and passed them through. `?kind=text` on image bytes routed them to the **text** classifier
  (which can't see the image) → image screening bypassed → allow; `?sensitivity=lenient` turned a
  score-based *hold* into an *allow*, below the admin's policy floor. **Rule: the web layer must
  never let a caller *weaken* a safety decision.** Type is always server-side magic bytes
  (`kind='auto'`); sensitivity is always the admin-configured `cfg.sensitivity`. When wrapping any
  fail-closed core, audit every caller-supplied field for "can this loosen the verdict?"
- **`realpath`-confine against the intended BASE, not against the resolved dir itself** (adversarial
  finding, medium). `realDir = realpathSync(scanDir); if (path.dirname(cand) !== realDir) hold` is a
  **tautology** — `cand = join(realDir, …)` so it always equals `realDir`; the check never fires and
  a symlinked `<state>/moderation/scan` (planted by a same-uid service or an NFS-mesh peer) silently
  redirects the write outside quarantine. Confine against `join(realpathSync(STATE_DIR),
  'moderation','scan')`, `lstat`-reject symlinked path components, and require the resolved dir to
  **equal the expected path**. (`STATE_DIR` is legitimately a symlink into the data disk → realpath
  it; the components under it must not be.)
- **Screened bytes are content at rest — sweep them.** The `check` endpoint stages the body to a
  0600 temp under `<state>/moderation/scan` and unlinks on the runner's return; a process killed
  mid-check leaks it. `sweepModerationScan()` clears the dir on startup (`onFirstBind`), when nothing
  is in-flight. Also: `req.destroy()` right after `sendJSON(413)` on an over-cap body can reset the
  shared socket before the response flushes → destroy on the response's `finish` event instead.
- **The check endpoint reads its OWN raw body, not `readBody`.** `readBody` caps at 64KB and
  JSON-parses; here the body *is* the content (up to 25MiB, `VALARK_MODERATION_MAX_BYTES`). It's
  intercepted **after** the full POST gate stack (`isLanOrTailnet`+`rateLimitOk`+`boxCommissioned`+
  auth-per-Use-Mode) but **before** `readBody(req).then(...)` consumes the stream. Fail-closed
  everywhere: over-cap→413 hold, empty→hold, unparseable/spawn-fail/timeout→hold; a *disabled*
  engine returns `decision:'skip'` (explicitly **not** allow-by-policy — callers must not treat it
  as approval). Readiness for the status card is probed **async + cached** (`moderation.sh ready`
  runs `find` over the mirror — never `spawnSync` it on the hot path or it blocks the event loop).
- **Never mark a file "screened" unless it's genuinely resolved** (adversarial-review finding,
  **high**). The loop sweep (`mod-sweep.sh`) moves a flagged file to quarantine, then records it in
  a dedupe marker so later sweeps skip it. The first cut wrote the marker **unconditionally** — but
  `mv`'s failure was swallowed (`2>/dev/null`, no `set -e`), so when the loop user couldn't write
  the store (service-owned dir → EACCES) or the copy hit ENOSPC, the flagged file stayed **served
  AND** marked done → never retried, plus a false "quarantined" heal-event. Rule: only mark
  screened on an `allow` **or** a move that actually **succeeded**; on failure leave it unrecorded
  (retried next sweep) and raise a distinct hard-error (`rc 11` → `moderation-error` heal-event).
- **An enabled screener must never leave a flagged file served.** An `action:'flag'` mode (copy to
  quarantine, keep the original) was a third state — *enabled but non-enforcing* — while the Safety
  card still said "screening." Dropped it: both remaining actions (`block`/`quarantine`) **move** the
  file; only an explicit `enabled:false` is the sanctioned no-enforcement state.
- **Dedupe markers: key on a HASH, not a raw `grep -F` of joined fields.** `grep -qF "path\tsize\tmtime"`
  is an unanchored substring match — `mtime` matches as a right-unbounded prefix (200 hits 2001), and
  a filename containing a tab/newline corrupts the marker → a file silently treated as already-screened
  → **served**. Use `sha1(path\0size\0mtime)` and `grep -q "^<hash>"` (fixed-width hex, injection-proof).
  Same reason `_json()` must escape `\n`/`\t`/`\r`, not just `\`/`"`, or an odd filename forges a
  JSONL queue line. And `find` a symlinked store dir with **`-H`** (a `-P` default returns nothing for
  a symlinked top dir → the whole store goes unscreened), while still not following symlinked entries.
- **A write-back destination read from an in-`<state>` log is attacker-controlled** (adversarial-review
  finding, **high**). The Safety card's review queue read `path` from `queue.jsonl` and a "restore"
  action copied the quarantined file back there — with only `isAbsolute + parent-exists + COPYFILE_EXCL`
  guards. But `queue.jsonl` lives in the same in-`<state>` tree the code elsewhere treats as
  attacker-writable (same-uid service / NFS-mesh peer), so a poisoned entry + a planted quarantine file
  turns an admin "Approve" click into an **arbitrary new-file write** (`/etc/cron.d/…` → RCE if root) —
  a confused deputy. `COPYFILE_EXCL` only blocks *overwrite*; `existsSync(dirname)` only blocks *parent
  fabrication*; neither **confines** the write to a store root. Plus a TOCTOU: `realpathSync(src)` then
  `copyFileSync(src)` re-opens and follows a symlink swapped in after the check → exfiltrates any
  readable file. **Decision: dropped restore** — review is remove/dismiss only. If ever re-added:
  realpath the dest parent and require it under an allowlisted store root, and copy from an `O_NOFOLLOW`
  fd, not a re-resolved path. `remove` is safe (`unlinkSync` removes the entry itself — never follows the
  final symlink — and the id is a basename). Also: the item-exists check must scan the FULL pending set,
  not the 200-item display slice, or held items past the cap become un-actionable.
- **Never point the quarantine sweep at a DB-backed store** (real-box investigation). The sweep
  *moves* a flagged file to quarantine — fine for a plain uploads tree, **corrupting** for a store
  whose files a database references. MicroBin (SQLite) and maddy (imapsql/bbolt) both are: their
  on-disk files are DB-referenced (and text pastes / mail bodies often aren't standalone files at
  all), so a move breaks the store. The sweep's default service paths were also just wrong, so it
  no-op'd — but "fixing" them to the real paths would have started corrupting mail/paste. Sweep
  **only** explicit plain-file dirs (`VAL_ARK_UPLOADS` / `VALARK_MODERATION_DIRS`); per-service
  enforcement needs a pre-store intercept or a service-native hook, never a post-store move. The
  fail-closed instinct applies to integrity too: don't let the safety mechanism break what it guards.
- **Newer llama.cpp split `llama-cli` into a REPL — a "fail-closed" classifier can invert into
  block-everything** (#50, confirmed live on the mirrored b7824). `llama-cli` now *rejects*
  `-no-cnv` ("--no-conversation is not supported by llama-cli"), drops into REPL mode, and ECHOES
  the prompt to stdout — so an unsafe-wins substring parse reads the prompt's own "unsafe" and
  blocks 100% of clean text (the model's actual "safe" answer is drowned out). And
  `llama-mtmd-cli` rejects `-st`/`-no-cnv` outright ("error: invalid argument") → nonzero exit →
  every image held + quarantined. Three rules: (1) prefer `llama-completion`, fall back to
  `llama-cli` (verify.sh's fleet pattern) — and keep `mod_ready` probing the same binaries the
  runner resolves; (2) classify in single-turn CONVERSATION mode (`-st`, **no** `-no-cnv`) with
  `--no-display-prompt --temp 0` — raw completion skips the guard model's chat template and
  Llama-Guard *continues* the prompt ("unsafe\n\nsafe") instead of answering it; (3) never trust
  flag suppression alone — end prompts with a fixed sentinel line ("Answer only:") and parse only
  the text AFTER its last occurrence, so an echoing build degrades to hold, never to mass
  false-positives (and never to allow). Flag support differs per binary in the SAME build — test
  each binary's argv against the mirrored build, not just "llama.cpp".
- **The sweep must enumerate symlinks, and quarantine the LINK — never read through it** (#52,
  adversarial-review). `find -H "$d" -type f` skips every symlink found during traversal (with `-H`
  they aren't followed → they fail `-type f`), so a store `innocent.txt → /outside/flagged` was
  neither screened nor moved while the bytes stayed reachable through the store path (a file server
  that follows symlinks re-serves them; a link back into `<state>/moderation/quarantine` re-exposes
  quarantined content). *Reading the target* would be worse — the dedupe key is `stat`-derived, so an
  attacker earns an `allow` on a benign target then `touch -r`-forges size+mtime after retargeting the
  link (TOCTOU → permanent allow for arbitrary bytes). Rule: enumerate `\( -type f -o -type l \)`,
  test `[ -L ]` **before** `[ -f ]` (which follows the link), and quarantine any symlink as a
  fail-closed `hold` — `mv` moves the link itself, never the target, and one branch covers
  link→file, link→dir (a whole out-of-store tree), and dangling links.
- **`_json()` must escape EVERY C0 control byte, not just `\n`/`\r`/`\t`** (#52). A byte `0x01`-`0x1f`
  is legal in a Unix filename but ILLEGAL raw inside a JSON string, so a filename like `evil␁name.txt`
  wrote a `queue.jsonl` line that `server.js` `_readJsonl` (a `try{JSON.parse}catch{}`) silently
  dropped — the quarantined file became an invisible, un-actionable orphan (never in `_modPending`,
  `reviewModerationItem` returns "not found"). Fail-closed on quarantine still held, but review-queue
  state consistency broke. Fix at the WRITER (not by making the reader lenient): after the short
  escapes, replace each remaining `0x01`-`0x1f` byte with `\u00XX`. Forward-only — lines already
  malformed at rest stay orphaned (no migration).

## Git / releases

- **Don't retarget a PR across a rebase-merge divergence.** After a rebase-merge release, `main`
  and `dev` share content but diverge by SHA. Dependabot PRs are cut from the *pre-release* `main`;
  retargeting them to `dev` corrupts the merge base into a huge false diff. Leave them on `main`
  (or set `target-branch: dev` in `dependabot.yml` so future ones start there), don't retarget.

## Benign, don't "fix"

- **NodeBB `/app/forum/` 503s under rapid bursts** — a transient of `pipeProxy`, self‑recovers.
  Render as "recovering," not an error; don't rework the proxy.
