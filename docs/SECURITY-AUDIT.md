# Val Ark Security Audit

**Audit date:** 2026-06-06 (point-in-time record — findings and line numbers reflect
the tree as scanned; see the dated addendum at the end for what changed since).
**Scope:** Public GitHub repo, web server / reverse proxy (`scripts/server.js`),
service standup scripts (`scripts/services/*.sh`), download supply chain
(`scripts/tools/_common.sh`), and the live runtime posture (binds, NFS exports,
filesystem permissions, auth gates).
**Deployment model assumed:** offline / trusted-LAN hub. Not internet-exposed.
Methodology: a 6-dimension sweep (secrets, proxy, scripts, runtime, web UI, network)
with adversarial verification — every finding below was independently reproduced via
`grep` / `git`-history search / `stat` / `ss -tlnp` / live `curl` probes. False
positives were removed.

---

## Executive Summary

**Overall posture for an offline, trusted-LAN deployment: acceptable for the
application layer, but undermined at the host/infrastructure layer.**

The application-level design is sound and largely does what the maintainer intends:

- **No secrets are committed** to the public repo or its history. The real
  `GITHUB_TOKEN`, fleet hostnames, and data path live only in a git-ignored `.env`.
- **The reverse proxy is well-built**: no SSRF (host hardcoded, app id allowlisted),
  no path traversal (raw `..` gate before decode + `isPathSafe`), no command injection
  (argv `spawn`, target allowlists), localhost-only CORS, and CSP/X-Frame-Options
  stripped only on proxied responses (not globally).
- **Mail is genuinely offline**: SASL auth is mandatory, outbound relay/federation is
  absent, and external recipients are refused.
- **Internal web UIs (MicroBin, The Lounge) bind `127.0.0.1` and enforce auth.**

The serious problems are **not in the repo or the proxy code — they are in the host's
NFS and filesystem configuration**, which is operator/machine state, not committed code:

1. **`/home/<user>` is NFS-exported read-write to the whole `/24` with
   `no_root_squash` (CRITICAL).** This single misconfiguration exposes the operator's
   SSH private key, `authorized_keys`, and the live `GITHUB_TOKEN` in `.env` to any host
   on the LAN, and allows persistent SSH backdooring. It defeats every per-service auth
   gate by handing over the credential files directly.
2. **The NTFS/exfat (fuseblk) data disk forces every file to mode 777**, silently
   nullifying the `chmod 600` the scripts apply to credential files. Combined with the
   `ro` NFS export of that disk, generated MicroBin/maddy/NodeBB secrets are readable by
   any local user and any LAN NFS client (HIGH).
3. **ngIRCd accepts unauthenticated connections on `0.0.0.0:6667`** with no connect
   password, reachable on the LAN and the tailnet, bypassing The Lounge's login gate (HIGH).
4. **The web origin and several internal services bind `0.0.0.0`** and are reachable on
   the tailscale interface — a broader trust domain than the LAN (MEDIUM). The documented
   `VALARK_BIND` knob is honored by the service scripts but **not** by `server.js` or the
   kiwix-serve spawn.
5. **Two web-UI XSS sinks** (directory-autoindex filenames, content Overview) are
   unescaped (HIGH/LOW), and there is **no CSP** as a second layer (MEDIUM). These are
   stored / second-order (require planting an attacker-named file or future API-fed data)
   and bounded by the offline posture, but real.

**Bottom line:** the committed code meets the public-repo secret-hygiene requirement and
the proxy is hardened. The exploitable risk concentrates in **host NFS/permissions
configuration** and a handful of **bind-address** and **output-escaping** gaps. Tighten
the NFS exports and relocate secrets off the FUSE disk first; these are the highest-impact
fixes and most live entirely outside the repo.

---

## Findings by Severity

Legend — **Auto-fix safe?** = the change can be applied without breaking a running
service or a committed file. "No" generally means it needs an operator-coordinated
restart, a mount/NFS change that affects fleet nodes, or alters a request contract.

### Critical

| ID | Finding | Location | Recommendation | Auto-fix safe? |
|----|---------|----------|----------------|----------------|
| `nfs-home-rw-norootsquash-1` | `/home/<user>` exported **rw + `no_root_squash`** to `<mesh-subnet>/24`; exposes `~/.ssh/id_ed25519`, `authorized_keys`, and `.env` (live `GITHUB_TOKEN`) to any LAN host; remote root can backdoor SSH | `/etc/exports`; nfsd `0.0.0.0:2049`, rpcbind `0.0.0.0:111` | Stop exporting `/home`. Export only the read-only data subtree the mesh needs. Remove `no_root_squash` everywhere. Scope to explicit fleet IPs, not a `/24`. Rotate the SSH key + token (they were LAN-readable). | **No** (will break fleet nodes mounting it; re-validate mesh mount set) |

### High

| ID | Finding | Location | Recommendation | Auto-fix safe? |
|----|---------|----------|----------------|----------------|
| `creds-world-readable-fuseblk-1` / `service-creds-777-on-nfs-tree-1` | Generated secrets are **world-readable (777)** on the fuseblk/NTFS data disk; `umask 077`/`chmod 600` are silently ignored. Affects `paste/credentials.txt` (plaintext basic-auth + admin pw), `maddy/credentials.db`, `forum/config.json` (NodeBB `secret`), `chat` configs | data disk `<DATA_DISK>/val-ark/state/services/*`; `paste.sh:89,97` | Relocate secrets to a POSIX (ext4) path that honors mode 600, owned by the service user; never on the FUSE mount or inside an NFS export. Add a post-`chmod` `stat` check that fails loudly. Rotate exposed passwords. | **No** (relocating live cred files needs service reconfig/restart + rotation) |
| `creds-nfs-exported-1` | The world-readable credential/secret tree is **NFS-exported (ro)** to the LAN; any `/24` host can mount and read all service secrets | `/etc/exports` + `state/services/*` | Exclude the `state/`/secrets subtree from the NFS export (export only models/tools/content), or keep credentials off the exported disk entirely. | **No** (editing exports can disrupt fleet mounts) |
| `ngircd-no-password-lan-1` | **ngIRCd accepts unauthenticated connections** on `0.0.0.0:6667` (no `Password`, `PAM = no`); reachable on LAN **and tailnet**, bypassing The Lounge login | `state/.../chat/ngircd/ngircd.conf:7-9`; `chat.sh:38,158` | Bind ngIRCd to `127.0.0.1` (`VALARK_BIND=127.0.0.1`; The Lounge connects via loopback) and/or set a connect `Password` in `[Global]` + The Lounge `defaults.password`. | **No** (restart drops The Lounge backend link briefly; auto-reconnects) |
| `iframe-no-sandbox-1` | Same-origin reverse-proxied sub-apps (paste/chat/forum/mail) embedded in an **iframe with no `sandbox`**, and pipeProxy strips their CSP/X-Frame-Options. A stored-XSS in any user-content sub-app runs in the SPA origin | `web-ui/index.html:4947`; `server.js:830-831,863-868` | Serve sub-apps from a distinct origin (cross-origin frame), or add `sandbox` + stop stripping CSP (replace with `frame-ancestors 'self'`). Escape `id`/`src`/`title` in `renderAppFrame`. | **No** (sandbox/CSP changes can blank NodeBB/The Lounge frames; needs per-service testing) |
| `autoindex-filename-xss-1` | Directory autoindex interpolates **raw data-disk filenames into HTML** (no escaping); a file named `<img src=x onerror=...>.zim` planted via the NFS-exported disk/catalog executes in the SPA origin | `scripts/server.js:798` (`serveDirectory`) | HTML-escape `name`, HTML-escape + URL-encode `href` segments. Add a shared escape helper; consider disabling autoindex for data trees. | **Yes** (pure output hardening; no behavior change) |

### Medium

| ID | Finding | Location | Recommendation | Auto-fix safe? |
|----|---------|----------|----------------|----------------|
| `bind-all-interfaces-1` / `web-origin-tailnet-exposed-1` | Web server binds **all interfaces** (`server.listen(PORT)` no host arg → `*:8088`); reachable on LAN + tailnet. Documented `VALARK_BIND` is **not read by `server.js`** | `scripts/server.js:1090`; `loop.sh:102` | Wire `const BIND = process.env.VALARK_BIND \|\| '127.0.0.1'; server.listen(PORT, BIND, …)`; never default to `0.0.0.0`. Ensure `loop.sh` exports it. Firewall regardless. | **Yes** (code change breaks nothing; a LAN deployment must then set `VALARK_BIND`) |
| `no-auth-web-api-1` | Web `:8088` **GET API + static serving + directory listings have no auth**; unauthenticated clients read disk layout, tool/model inventory, dir indexes (POST is localhost-gated) | `server.js:610-671,749-967` | Add auth (at least on API + dir listings) or front with an authenticating proxy; otherwise bind host-only. Disable autoindex for content/sources trees. | **No** (adding auth/disabling autoindex changes the SPA's unauthenticated fetch contract) |
| `kiwix-8888-lan-unauth-1` / `kiwix-bound-0.0.0.0-bypasses-proxy-1` | **kiwix-serve binds `0.0.0.0:8888`** with no auth; directly reachable on LAN + tailnet, bypassing the `/kiwix/` proxy | `server.js:1037` (spawn missing `--address`) | Add `--address 127.0.0.1` to the kiwix-serve spawn args. The `/kiwix/` proxy already targets `127.0.0.1` so it keeps working. | **Yes** (low-risk; needs a kiwix restart to re-spawn) |
| `paste-credentials-world-rw-1` | MicroBin `credentials.txt` is 0777 (chmod no-op on fuseblk), exposing plaintext basic-auth + admin passwords (LAN NFS clients can read) | `state/.../paste/credentials.txt`; `paste.sh:97` | Same as `creds-world-readable-fuseblk-1`: relocate off the FUSE/NFS path; consider storing hashes; remove silent `\|\| true`. | **No** (chmod ineffective on this FS; real fix is relocation) |
| `csp-absent-1` | **No Content-Security-Policy** header on any response — no second layer behind the XSS sinks | `server.js:535-539` | Add a pragmatic CSP (`default-src 'self'; …; frame-src 'self'; frame-ancestors 'self'; base-uri 'none'`). Migrate inline handlers to drop `'unsafe-inline'` over time. | **No** (SPA relies on inline handlers + framed sub-apps; CSP must be crafted/tested) |
| `chat-admin-pw-stdout-leak-1` | The Lounge first-run admin password is **only printed to stdout**, never stored with restrictive perms; a captured stdout log on the 777/NFS tree exposed it cleartext | `chat.sh:236-257`; live `state/logs/chat_standup*.out` | Write the credential to a chmod-600 file on a perms-respecting FS (and verify), don't echo to capturable stdout, or require `VALARK_CHAT_ADMIN_PASS`. | **Yes** (writing to a file / not echoing doesn't affect the running service) |
| `supply-chain-no-checksum-1` | Download helpers do **no checksum/signature verification** of any mirrored binary/archive (TLS-to-GitHub is intact — good) | `_common.sh:132-178,182-286` | Pin + verify SHA-256 (and signatures where upstream publishes them) per version in `data/installers.tsv`; fail on mismatch before extract. | **Yes** (adding optional verification doesn't affect running services) |
| `state-dir-not-gitignored-1` | Repo-root `state/` tree (where dev/fallback mode writes `credentials.txt`) is **not in `.gitignore`**; a `git add .` in dev mode could stage generated secrets to the public repo | `.gitignore` (missing `/state`); `valark-env.sh:94-96,109`; `paste.sh:42,96` | Add `/state` (anchored, no trailing slash) to `.gitignore`; optionally also ignore `credentials.txt`. | **Yes** (no tracked files under `state/`; gitignore only governs untracked staging) |
| `env-664-github-token-1` | `.env` is mode **664** (group/world-readable) and holds a live `GITHUB_TOKEN`; compounded by the `/home` rw NFS export | `/home/<user>/Code/val-ark/.env` | `chmod 600 ~/Code/val-ark/.env`; verify token scope is minimal; rotate (it was NFS-readable). | **Yes** (chmod sticks on ext4; breaks nothing) |
| `data-tree-777-world-writable-1` | Entire data tree is **world-writable (777)** due to FUSE mount options; any local user can replace mirrored binaries/installers (supply-chain risk for the mesh) | `<DATA_DISK>` (fuseblk `allow_other`) | Remount with `umask=022,uid=<svc>,gid=<svc>` (or move served/state data to ext4). Keep the NFS export `ro`. | **No** (corrective remount requires unmounting the live disk) |
| `nfs-rw-data-and-export-scope-1` | All three NFS exports use `no_root_squash`; `raid1-backup` is **rw**; scoped to a `/24` (coarse) rather than fleet IPs | `/etc/exports` | Remove `no_root_squash` everywhere; make `raid1-backup` `ro` or restrict to backup-client IPs; tighten scope to explicit fleet IPs. | **No** (can break a fleet/backup client depending on root-mapped/rw access) |

### Low

| ID | Finding | Location | Recommendation | Auto-fix safe? |
|----|---------|----------|----------------|----------------|
| `internal-ui-not-forced-localhost-1` | MicroBin (8085) + NodeBB (4567) bind `$VALARK_BIND` rather than forced `127.0.0.1`; a global `VALARK_BIND=0.0.0.0` would expose them to the LAN (latent — not currently triggered) | `paste.sh:36,140`; `forum.sh:36,158` | Hardcode the listen host to `127.0.0.1` (like The Lounge/alps); keep the public/proxy URL separate from the bind. | **Yes** (intended bind anyway; won't break the proxy path) |
| `bind-default-inconsistent-0000-1` | `VALARK_BIND` default is inconsistent (chat/mail `0.0.0.0`; paste/forum `127.0.0.1`); LAN-facing services are live on all interfaces with no visible host firewall | `chat.sh:38`, `mail.sh:45` vs `paste.sh:36`, `forum.sh:36` | Standardize the default (prefer `127.0.0.1`, opt-in to `0.0.0.0`); document one knob; firewall `6667/1143/1587/8888/8088` to the LAN; confirm not internet-routed. | **No** (forcing `127.0.0.1` takes LAN IRC/IMAP/SMTP/kiwix offline for LAN clients) |
| `content-validation-logic-bug-1` | Content download target validation uses `&&` instead of `\|\|`; any alphanumeric/dash string passes the allowlist check (not exploitable — argv spawn + script `case` ignores unknown targets) | `scripts/server.js:709` | Change `&&` → `\|\|`; constrain the update target to a fixed allowlist for consistency with the tools endpoint. | **Yes** (only tightens to the allowlist; no legitimate flow breaks) |
| `env-sourced-as-code-1` | `.env` is dot-sourced (`set -a; . "$VALARK_CONFIG"`), so config = arbitrary code execution if it becomes attacker-writable (amplified by the `/home` rw NFS export) | `scripts/lib/valark-env.sh:48` | Parse `.env` as strict `KEY=VALUE` (reject command substitution); assert ownership/perms before sourcing. | **Yes** (strict parser doesn't affect running services) |
| `csrf-download-localhost-1` | `POST /api/download/*` has no CSRF token; protected by remote-address localhost check + permissive localhost CORS. Remote CSRF blocked; residual = a malicious page/rogue localhost service ON the host | `server.js:674-682,584-593,541-548` | Require a same-origin custom header / CSRF token on state-changing POSTs; validate Origin/Referer; tighten CORS to the exact origin. | **No** (tightening can break SPA fetches reached via LAN hostname/IP) |
| `sse-progress-line-xss-1` | SSE download-progress `lastLine` rendered into `innerHTML` without `esc()`; a catalog/filename containing markup in download output could inject (60-char slice; second-order). `dl.type` and `id` vectors are false positives (server-constant/numeric) | `web-ui/index.html:5186`; `server.js:130-145` | Wrap `dl.lastLine` in `esc()`; strip/escape `<` `>` server-side before broadcasting. | **Yes** (output-only) |
| `content-overview-unescaped-2` | Content-library Overview rendered unescaped while the tool Overview is escaped (asymmetry; data is author-controlled SPA source today — latent) | `web-ui/index.html:4190` vs `3631` | Escape `item.details.overview`; route all dynamic interpolation through `esc()` as a standard. | **Yes** (output-only; matches existing tool path) |
| `kiwix-bind-bypass-1` | (Duplicate of `kiwix-8888-lan-unauth-1` from the proxy dimension) kiwix on `0.0.0.0:8888` bypasses the proxy; read-only public content | `server.js:1037` | Pass `--address 127.0.0.1`. | **Yes** |

### Info / Verified-good

`storage10tb-comment-example-1` (the `<DATA_DISK>` string in `valark-env.sh:37` is a
documentation comment example, not a hardcoded path used by code — optional tidy to
`/mnt/bigdisk`).

---

## Verified Good (confirmed working)

These properties were probed and confirmed to meet the offline trusted-LAN requirements:

- **No committed secrets, anywhere.** `git grep` for token/key shapes over 222 tracked
  files and `git log --all -p` over full history → none. The real `GITHUB_TOKEN`, fleet
  hosts, and data path live only in the git-ignored, untracked `.env`. `.env.example`
  ships only commented placeholders. (`no-secrets-in-tree-or-history-1`,
  `env-ignored-example-clean-1`, `no-private-hostnames-or-ips-committed-1`,
  `no-secrets-in-git-1`)
- **Data trees / node_modules / test-results are not tracked** (anchored gitignore entries).
  (`data-trees-modules-ignored-1`)
- **Mail is genuinely offline:** SASL `AUTH PLAIN` mandatory before any mail command
  (`502` before auth), no `target_remote`/relay/federation, external recipients refused
  (`501`/`550`), domain is LAN-local `valark.lan`. (`maddy-no-relay-sasl-mandatory-1`,
  `maddy-no-relay-federation-1`)
- **The Lounge hardened:** `127.0.0.1`-bound, `public:false` (login required),
  `lockNetwork:true`, `prefetch:false`, no media preview. (`thelounge-private-locked-offline-1`)
- **MicroBin hardened:** `127.0.0.1`-bound, HTTP Basic auth enforced (`401` unauth,
  direct + via proxy), private mode on, telemetry + update-check disabled.
  (`microbin-auth-telemetry-off-1`, `internal-uis-localhost-bound-1`)
- **NodeBB config** has ActivityPub/federation disabled and binds loopback (auth gate
  not exercised — service was building). (`nodebb-federation-off-1`)
- **Reverse proxy is sound:** no SSRF (host hardcoded `127.0.0.1`, app id allowlisted,
  unknown ids `404`); no path traversal (raw `..`/`%2e%2e` gate before decode +
  `isPathSafe`, all encoded variants `404`); upstream `Host` rewritten so client `Host`
  injection can't reach upstream. (`ssrf-fixed-upstream-good`, `path-traversal-blocked-good`,
  `header-stripping-scoped-good`)
- **No command injection** in `POST /api/download/*`: argv `spawn('/usr/bin/bash', […])`
  (no shell), target allowlists, safe script `case` dispatch; POST is localhost-gated
  (remote → `403`). (`no-command-injection-good`)
- **CORS** reflects only anchored `localhost`/`127.0.0.1` origins, no
  `Allow-Credentials`, no cookie/session auth → no cross-origin credential leak.
  (`cors-localhost-only-good`)
- **Security headers** (`X-Content-Type-Options`, `X-Frame-Options: SAMEORIGIN`,
  `Referrer-Policy`) present on static/API responses; CSP/XFO stripped **only** on
  proxied responses (by design, for in-frame embedding). (`header-stripping-scoped-good`)
- **DoS bounds:** SSE connection cap (50), 64 KiB request-body cap, duplicate-download
  rejection, `<1 GB` free-disk guard. (`sse-dos-limited-good`)
- **No TLS bypass** anywhere (`-k`/`--insecure`/`--no-check-certificate`/
  `GIT_SSL_NO_VERIFY`/`NODE_TLS_REJECT` → none); no `eval` on network data; scripts don't
  run as root. (`no-secrets-in-public-repo-verified-good`)
- **Service credentials are generated at runtime** (`openssl rand`/`/dev/urandom`) and are
  env-overridable — never baked into committed source. (`runtime-cred-generation-good-1`)

---

## Completeness Critic — What the sweep did NOT cover

A follow-up review should address the gaps below. None invalidate the findings above; they
are coverage limits of this pass.

1. **NodeBB / forum auth gate was never exercised live.** The service was still
   *building* (`/app/forum/` → `502`, no `:4567` listener at scan time). Its static config
   looks correct (federation off, loopback bind), but the login gate, registration policy,
   social-login/OAuth plugin state, and the `4567` runtime bind all remain **unverified**.
   Re-probe once it is up. (`nodebb-federation-off-1`)
2. **No dependency / CVE scan was run.** `kiwix-serve`, `maddy`, `ngIRCd`, NodeBB (+ its
   npm tree), The Lounge (npm), MicroBin, and the Node runtime serving the SPA were not
   checked against known CVEs. `kiwix-serve` and NodeBB in particular have published
   advisories. Run `npm audit` on the NodeBB/The Lounge trees and check installed daemon
   versions against vendor advisories.
3. **No host firewall state was confirmed.** `ufw` is absent and `nft`/`iptables` rules
   were not readable. The whole offline posture rests on the box not being internet-routed
   and on a LAN/tailnet boundary — verify the firewall and that no port-forward/NAT exposes
   `8088/6667/1143/1587/8888/2049/111`.
4. **Tailnet/tailscale ACLs were not reviewed.** Multiple services answer on the
   `tailscale0` interface (`100.x`), a broader trust domain than the LAN. The tailnet ACL
   policy (who can reach this node, on which ports) was not examined.
5. **The `alps` mail web UI (`:1323`) was not listening** at scan time, so its bind/auth
   could not be verified live (the script hardcodes `127.0.0.1` — confirm at runtime).
6. **maddy `credentials.db` contents / SASL account inventory not enumerated** — whether
   weak/default mailbox passwords exist was out of scope; only the relay/auth-required
   posture was tested.
7. **Cleartext-on-the-wire was noted but not threat-modeled.** maddy (`1143`/`1587`,
   `tls off`) and ngIRCd (`6667`) carry credentials in cleartext over the LAN/tailnet;
   on-path sniffing risk depends on LAN/tailnet trust, which was assumed, not validated.
8. **NFS client-side trust** (which fleet nodes actually mount what, and whether any
   mount the `/home` or `raid1-backup` rw exports) was not enumerated — needed before
   tightening `/etc/exports` so the fix doesn't break the mesh.
9. **Log/state content for other services** (NodeBB logs, redis, maddy spool) was not
   audited for incidental secret/PII leakage beyond the chat standup log finding.
10. **No authenticated/fuzz testing of the sub-apps themselves** (MicroBin paste content
    handling, NodeBB post rendering) — the iframe XSS finding assumes a plausible
    stored-XSS in those apps but did not attempt to find one.

---

## Addendum — 2026-07-10 (status update; the report above is the unedited record)

The audit above describes the tree **before** the same-day fix commit
(`security: apply audit fixes`). Re-verified against the current code
(grep/read of `server.js`, `loop.sh`, `_common.sh`, the service scripts —
host runtime state was **not** re-probed):

**Fixed in-repo (2026-06-06/07):**

- `autoindex-filename-xss-1` — `serveDirectory` now HTML-escapes names and
  `encodeURI`s hrefs via a shared `escapeHtml()` helper.
- `kiwix-8888-lan-unauth-1` / `kiwix-bind-bypass-1` — kiwix-serve is spawned with
  `--address 127.0.0.1`; only the `/kiwix/` proxy reaches it.
- `bind-all-interfaces-1` — `server.js` honors `VALARK_BIND` on every listener
  (default remains `0.0.0.0`: it is a LAN hub by design).
- `state-dir-not-gitignored-1` — `/state`, `credentials.txt`, and
  `admin-credentials.txt` are gitignored.
- `chat-admin-pw-stdout-leak-1` — the generated admin password is written to a
  chmod-600 `admin-credentials.txt` (with a loud warning if the filesystem ignored
  the chmod), no longer echoed to stdout.
- `ngircd-no-password-lan-1` — ngIRCd now defaults to `127.0.0.1` (LAN IRC is opt-in
  via `VALARK_BIND`, with a plaintext/unauthenticated warning); a connect `Password`
  is still not set if opted in.
- `bind-default-inconsistent-0000-1` — mostly resolved: paste/forum/chat all default
  `127.0.0.1`; `mail.sh` still defaults `VALARK_BIND=0.0.0.0`.
- Cleartext-on-the-wire (Completeness item 7) — an Auto-TLS layer (local CA,
  `scripts/lib/tls.sh`) landed 2026-06-07: HTTPS listener (`VALARK_HTTPS_PORT`,
  default 8443), optional `VALARK_FORCE_HTTPS` redirect, CA-download route, and maddy
  gets a real TLS cert (STARTTLS) when the cert exists.

**Still open (re-verified today):** `content-validation-logic-bug-1` (the `&&` is
still there), `sse-progress-line-xss-1` (`dl.lastLine` still unescaped),
`content-overview-unescaped-2`, `csp-absent-1` (no CSP; the proxy still strips
CSP/XFO), `iframe-no-sandbox-1` (frame title/subtitle are now escaped but there is
still no `sandbox`), `env-sourced-as-code-1`, and `supply-chain-no-checksum-1`
(`download_file` now downloads to a `.part` temp, resumes, size-verifies against the
server's Content-Length, and renames atomically — but still no checksums/signatures).
The host-layer findings (NFS exports, FUSE 777 tree, `.env` perms) are machine state
and remain as reported until re-probed.

**New attack surface since the audit (2026-07-09/10) — not covered above:**

- `GET /api/archive/<path>` — unauthenticated download of any file, or any directory
  as a streamed `tar.gz`, under the `tools/models/content/sources/assets/installers`
  trees (traversal-guarded: normalize + top-dir allowlist + `isPathSafe`). Extends the
  `no-auth-web-api-1` read surface from listings to bulk fetch.
- HTTP Range support (206/416) on static files — resumable unauthenticated reads.
- Multi-port listen via `VALARK_WEB_EXTRA_PORTS` (all extra listeners honor
  `VALARK_BIND`).
- `loop.sh` step 2c: when `VALARK_WEB_PUBLIC_PORT` is set (e.g. 80), an
  iptables/ip6tables NAT `PREROUTING` `REDIRECT` to the web port is re-asserted every
  cycle on every real interface (LAN **and** tailnet; loopback untouched) — puts the
  unauthenticated web origin on a standard port.
- `loop.sh` step 6b: weekly **unattended** tool refresh pulls latest upstream releases
  (`VALARK_TOOL_REFRESH_DAYS`, default 7) — raises the stakes of
  `supply-chain-no-checksum-1`, since fetches now happen with no operator watching.
- New services/mirrors: a SeaweedFS launcher (`scripts/services/seaweedfs.sh`, binds
  `127.0.0.1` by default) and Grafana added to the tool mirror. Neither has been
  security-probed.

These deltas have not had the adversarial live-probe treatment of the original sweep;
a follow-up pass should exercise them.
