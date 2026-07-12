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

- **A mirrored binary can be the WRONG arch but still have the `+x` bit** (e.g. an x86_64
  `redis` in the arm64 tree → "Exec format error"). **Fix:** verify it actually runs
  (`"$bin" --version`) before preferring it; fall back to a system/other binary
  (`forum.sh find_redis_server`).
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

## Storage / data root

- **`VAL_ARK_DATA` autodetect can pick the wrong mount** (once landed on a backup target that
  got pruned overnight). **Fix:** set `VAL_ARK_DATA` explicitly in `.env` on multi‑mount hosts.
- **Default footprint cap can be tiny** — a box with 7 TB free had `VALARK_MAX_GB=500`, so almost
  nothing mirrored. Check the cap when "nothing downloads."

## Test / VM harness

- **multipass is snap‑confined:** its `home` interface reads only **non‑hidden files under
  `$HOME`**. Staging a transfer from `/tmp` → "sftp cannot access"; from `~/.cache` (hidden) →
  "permission denied." **Fix:** stage under a non‑hidden repo path (e.g. `tests/results/`).
- **Unattended `setup.sh` needs headless mode** (`VALARK_YES` / non‑tty) or it prompts forever
  and the box ends up with no Node. For a truly offline bootstrap, `setup.sh` fetches Node from
  the source Ark (`VALARK_HOST`) before nodejs.org.

## Benign, don't "fix"

- **NodeBB `/app/forum/` 503s under rapid bursts** — a transient of `pipeProxy`, self‑recovers.
  Render as "recovering," not an error; don't rework the proxy.
