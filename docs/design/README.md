# Val Ark — Consumer Appliance Design

> **The goal:** Val Ark should feel like setting up a router or opening a fitness app —
> not administering a Linux server. A person who "barely knows what GitHub is" must be
> able to **set it up, monitor it, recover it, deploy it, and manage it** easily, with
> the intelligence baked into the system. One big **EASY button**, regardless of errors.

This directory is the cohesive architecture for that redesign. It is written
**scope-first**: we design the whole experience here, iteratively, before building it.

## The map

| Doc | Scope | Status |
|-----|-------|--------|
| [current-state.md](current-state.md) | As-of-0.1.17 snapshot of the shipped appliance + what's still open (answers "is there web setup / admin / recovery / access control?" — now yes) | ✅ |
| [vision.md](vision.md) | Product vision, the person we build for ("Jordan"), simplicity principles | ✅ |
| [commissioning.md](commissioning.md) | First-boot wizard — the exact screens, browser *and* plugged-in monitor, claim token | ✅ |
| [admin-console.md](admin-console.md) | Home screen + the 4-tab admin/settings information architecture | ✅ |
| [access-identity.md](access-identity.md) | Access model the operator chooses (Open / Passworded / Accounts), 2 roles, real controls | ✅ |
| [recovery.md](recovery.md) | Forgot-password, lockout, factory reset — paper recovery card, beep-reset, console menu | ✅ |
| [storage.md](storage.md) | Flexible multi-volume pool (primary NVMe + USB DAS, add/remove) + SeaweedFS across computers | ✅ |
| [downloads-monitoring.md](downloads-monitoring.md) | Disk-sized profiles + emphasis, plain-language priority picker, live download/health monitoring | ✅ |
| [errors-selfheal.md](errors-selfheal.md) | Errors in plain language + auto-repair + one-click fixes + fault attribution | ✅ |
| [safety-moderation.md](safety-moderation.md) | On-device (NPU) content moderation for shared uploads, default-on, private | ✅ |
| [deployment.md](deployment.md) | Docker containerization + security posture + reliability | ✅ |
| [roadmap.md](roadmap.md) | Phased implementation plan (what to build, in what order) | ✅ |
| [research-brief.md](research-brief.md) | Evidence base — patterns from 8 comparable products | ✅ |

Research informing these lives in [research-brief.md](research-brief.md) — patterns from
Synology DSM/QNAP, TrueNAS/unRAID, Home Assistant, Umbrel/CasaOS, consumer routers, Pi-hole/
Nextcloud, and consumer health apps.

## Non-negotiable principles (the throughline)

1. **No terminal required — ever — for the happy path.** Setup, management, and recovery all have a browser (or on-screen) path.
2. **Plain language, not sysadmin jargon.** "Storage," "Downloads," "Who can access this," not `VALARK_MAX_GB`, `iptables`, `flock`.
3. **Sensible defaults; progressive disclosure.** It works out of the box; advanced knobs are one tap deeper, never in your face.
4. **The box explains itself.** Every error says what happened and offers a fix; the offline AI assistant can help in-context.
5. **Self-healing first.** Fix automatically what can be fixed; only ask the human for what truly needs a decision.
6. **Recoverable by design.** There is always an obvious, safe way back in — even after a mistake, a lockout, or a bad config.
7. **Offline and local-first.** Everything above works with no internet, on the LAN, on the box's own screen.

---

↑ [Repo root](../../README.md) · [Doc map](../README.md)
