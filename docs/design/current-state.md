# Val Ark — Current State & Gap Analysis

> Honest baseline for the consumer-appliance redesign. This answers, directly, the
> questions: *Can a non-technical person commission it from a web UI? Is there an
> admin menu? What happens if they forget their password? Can they choose open vs.
> account-gated? Are there real access controls?* Short answer today: **no, no, N/A,
> no, and not really.** Val Ark is currently a power-user / CLI tool. The redesign
> turns it into a router-app / health-app appliance.

Part of the [design hierarchy](README.md).

---

## Who Val Ark is built for today vs. who it must serve

| | Today (implicit) | Target |
|---|---|---|
| User | A Linux admin comfortable with `.env`, `ssh`, `bash` | A person who "barely knows what GitHub is" |
| Setup | Edit files + run scripts in a terminal | A guided wizard in a browser (or on a plugged-in monitor) |
| Manage | Read logs, run CLI commands | Simple menus; the box explains itself |
| Recover | Know the right script/flag | An obvious "I'm locked out / start over" path |
| Mental model | "A mirror engine you configure" | "One EASY button that just works" |

---

## What exists today

**Setup is entirely command-line.**
- `cp .env.example .env`, then hand-edit `VAL_ARK_DATA` and other keys.
- `./start.sh setup` (installs deps + Node; interactive y/N prompts — now also headless via `VALARK_YES`).
- `./start.sh serve` starts the web server; `./scripts/loop.sh install 30` installs the 24/7 self-heal cron.
- There is an interactive **terminal** menu (`./start.sh` with no args) — but nothing in a browser.

**The web UI is a catalog + a download console, not an admin console.**
- Home / Software / Models / **Library** / **Community** / Getting Started.
- It can now browse the live catalog and one-click **request** downloads, show live download progress (SSE), start community services, and download mirrored app artifacts.
- It has **no** settings/config screen, no first-run wizard, no admin area, no user management, no system/health dashboard, no log/error viewer.

**Access control is "open on the trusted network," with action-gating.**
- The UI has **no login** — anyone who can reach the address sees everything.
- Write actions (`POST /api/download/*`, `/api/request`, `/api/service/start`) are gated to **LAN + tailnet + localhost** with a per-IP rate limit. Reads are open.
- The appliance is assumed reachable only on the LAN + tailscale (never the public internet).

**Identity/accounts live *inside individual community services*, not in Val Ark.**
- Forum (NodeBB): self-service register. Chat (The Lounge): host runs `chat.sh adduser`. Mail (maddy): host runs `mail.sh creds create`. Paste (MicroBin): a shared credential written to `<data>/credentials.txt`.
- There is **no Val Ark account, no Val Ark password, and therefore no Val Ark password-recovery.**

**Configuration is files + env, not UI.**
- Footprint caps (`VALARK_MAX_GB`, `VALARK_MODEL_MAX_GB`), ports, services enabled (`VALARK_SERVICES`), curation weights (`catalog.sh`), tool-refresh cadence — all live in `.env` or source. None are editable from the UI.

**Monitoring is logs + a self-heal loop, no dashboard.**
- `loop.sh` repairs/verifies/fills every cycle and writes `state/health.json`; `verify.sh` checks apps. Metrics tooling (Telegraf/InfluxDB/Grafana) is *mirrored* but **not running**.
- The UI shows a disk/storage bar and live download progress, but no system health, no service uptime history, no alerts, no error surface.

**Errors are surfaced as raw text / files.**
- Failures land in `logs/` and `state/logs/`; the UI shows an `alert()` or an inline "run this script" hint. There is no friendly "something went wrong → here's what and how to fix it" experience, and no in-UI retry/repair.

---

## Direct answers to the questions raised

1. **Easy web-UI commissioning of a new system?** — *No.* Setup is CLI-only. The first thing a new user hits is a shell, an `.env`, and `./start.sh`.
2. **An actual admin menu?** — *No web admin.* Only a terminal menu.
3. **Forgot the password — recovery on a local monitor / different localhost experience?** — *N/A / no.* There is no Ark password to forget, no recovery flow, and no distinct localhost/console "rescue" experience beyond write-actions being localhost/LAN-gated.
4. **Can the operator choose open vs. account-gated?** — *No.* It is always open-on-LAN; there is no setting to require accounts.
5. **Real access controls (roles, admin vs. user)?** — *No.* No Ark identity, no roles, no admin/guest distinction. Only network-position gating on writes.

---

## The gaps to close (what the redesign must add)

1. **First-boot commissioning wizard** — browser-based (and console-friendly for headless boxes): pick disk, set the box's name, choose the access model, create the first admin, choose what to mirror first, one-click "make it reachable at http://<name>/". No `.env` editing.
2. **A real admin console in the web UI** — a settings/system area with clear IA: Storage, Downloads & Priorities, Services, Network & Access, Users, Health, Logs/Errors, Update, Backup/Replicate.
3. **A Val Ark identity + access model the operator chooses** — Open / Passworded / Accounts, with an admin vs. everyone distinction and real controls; localhost/console always trusted.
4. **Recovery** — forgot-password + lockout + factory-reset, workable both on a plugged-in monitor (console rescue) and headless (localhost-only reset), with a clear, safe path.
5. **Priority picker + download/monitoring dashboard** — pick "what matters to me" in plain language; watch ZIM/software/model downloads with progress, queue, and pause/resume.
6. **Error & self-heal UX** — surface problems in plain language, auto-fix what the loop can, and offer a one-click "try to repair" for the rest — never a raw stack trace.
7. **Monitoring foundation** — stand up the metrics stack (Telegraf/InfluxDB, Grafana optional) so health/alerts are real and drive self-healing.
8. **"Baked-in intelligence"** — sensible defaults, plain-language everything, progressive disclosure, and the offline setup-assistant model wired in so the box can literally help the user.

The rest of this hierarchy specifies each of these, informed by how the best comparable products (Synology DSM, TrueNAS, Home Assistant, Umbrel/CasaOS, consumer routers, and health apps) solve them.
