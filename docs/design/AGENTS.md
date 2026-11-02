# docs/design/ — the scope-first product design

The consumer-appliance design hierarchy: what Val Ark should *feel* like and in what order it gets built. Work here when you shape intent — then verify against code before claiming it shipped.

↑ [Repo root](/AGENTS.md) · [Doc map](/docs/README.md)

These specs are written **scope-first**: we design the whole experience here, iteratively, before building it. Treat them as design **intent**, not API truth. [README.md](README.md) is the hub (owned elsewhere — link it, don't restructure it); [vision.md](vision.md) fixes the persona we build for ("Jordan"); [research-brief.md](research-brief.md) is the evidence base.

## What's here

| File | Maps to | Purpose |
|------|---------|---------|
| [vision.md](vision.md) | Foundation | Product vision, the person we build for ("Jordan"), simplicity principles. |
| [research-brief.md](research-brief.md) | Foundation | Evidence base — patterns from 8 comparable products. |
| [roadmap.md](roadmap.md) | **Tracker** | The **live** phased build plan — what shipped in which release, what's still open. |
| [current-state.md](current-state.md) | **Tracker** | The as-of-`VERSION` snapshot of the shipped appliance. |
| [commissioning.md](commissioning.md) | Phase 1 | First-boot wizard — screens, claim token, console path. |
| [access-identity.md](access-identity.md) | Phase 2 | Access model (Open / Passworded / Accounts), roles, real controls. |
| [recovery.md](recovery.md) | Phase 2 | Forgot-password, lockout, factory reset — paper card, beep-reset, console menu. |
| [admin-console.md](admin-console.md) | Phase 3 | Home screen + the 4-tab admin/settings information architecture. |
| [storage.md](storage.md) | Phase 4 | Multi-volume pool + SeaweedFS. **Not yet shipped.** |
| [downloads-monitoring.md](downloads-monitoring.md) | Phase 5 | Disk-sized profiles, priority picker, live download/health monitoring. |
| [errors-selfheal.md](errors-selfheal.md) | Phase 6 | Errors in plain language + auto-repair + one-click fixes + the notification center. |
| [safety-moderation.md](safety-moderation.md) | Phase 7 | On-device content moderation for shared uploads, default-on, private. |
| [deployment.md](deployment.md) | Cross-cutting | Docker containerization + security posture + reliability. |

## The two trackers move in lockstep

[roadmap.md](roadmap.md) (live phase tracker) and [current-state.md](current-state.md) (as-of-`VERSION` snapshot) describe the **same reality** from two angles. When a slice ships you **MUST**:

1. move it to shipped in **roadmap.md** *and* reflect it in **current-state.md**;
2. bump the `0.1.x` stamp in **both** to match `VERSION`;
3. log the call in [../knowledge/decisions.md](../knowledge/decisions.md).

Skipping either half is how the trackers drift out of sync (they go stale first — see Gotchas).

## How to work here

- **Design intent, not API truth.** Before you trust any "shipped" claim in these docs, verify it against the real code (`scripts/`, `web-ui/`). If reality diverges, correct the doc — don't propagate the wrong claim.
- **Keep the plain-language voice.** These are written for "Jordan," a person who "barely knows what GitHub is" — "Storage," "Downloads," "Who can access this," not `VALARK_MAX_GB` / `iptables` / `flock`.
- **Carry durable decisions up.** A significant design call belongs in [../knowledge/decisions.md](../knowledge/decisions.md) (context → decision → why), not only here.
- **Per-phase specs map to roadmap Phases** (table above) — keep that mapping intact when you add a spec.

## Gotchas

- **The trackers go stale first.** [roadmap.md](roadmap.md) and [current-state.md](current-state.md) lag the code; audit their version stamp and open/shipped markers before quoting them.
- **[safety-moderation.md](safety-moderation.md) still describes the ONNX-on-NPU design**, but the **shipped** moderation runs on **llama.cpp** (Llama-Guard-3 text + a tiny VLM via `llama-mtmd-cli`). The page carries an "As shipped" note; treat its ONNX/NPU wording as the design goal. See [../knowledge/gotchas.md](../knowledge/gotchas.md#content-moderation-phase-7) and the moderation entries in [../knowledge/decisions.md](../knowledge/decisions.md).
- **[storage.md](storage.md) (Phase 4) is unshipped.** `valark-env.sh` is still single-root; the pool descriptor / add-remove-drive / union mount are future work. Don't cite it as current behavior.
- **HTTPS-guide links point to [../ENCRYPTION.md](../ENCRYPTION.md)** — the canonical TLS doc. Don't invent a new HTTPS page or link into `web-ui/`.
- **PUBLIC repo** — roles and placeholders only; no host names, IPs, creds, or host paths.

## Related

- [../AGENTS.md](../AGENTS.md) — the top-level guide/reference set (ARCHITECTURE, LIBRARIAN, …).
- [../knowledge/AGENTS.md](../knowledge/AGENTS.md) — where decisions and gotchas live.
- [../../AGENTS.md](../../AGENTS.md) — the delivery pipeline and prime directives.
