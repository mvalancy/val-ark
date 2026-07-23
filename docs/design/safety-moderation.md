# Val Ark — Safety & On-Device Content Moderation

Part of the [design hierarchy](README.md). A household/community file-sharing box must keep
shared content appropriate (protect kids, prevent abuse). Val Ark's advantage: boxes like
the **UniFi UT2 / RK3588 have an on-board AI accelerator (NPU)** — so moderation runs
**locally, privately, by default**, with no cloud and no data leaving the box.

> **As shipped (0.1.9, Phase 7).** This page is the design *intent*. The moderation that actually
> shipped keeps the fail-closed, on-device, private posture below, but runs on **llama.cpp** rather
> than the originally-planned ONNX-on-NPU head: text is classified by **Llama-Guard-3-8B** and images
> by a mirrored **tiny VLM** (SmolVLM / moondream2) via **`llama-mtmd-cli`** — see the decision core
> `scripts/lib/moderation.sh` (a stub is injectable with `VALARK_MODERATION_CMD`). A dedicated NSFW
> ONNX classifier remains a possible later add. Where this doc says "ONNX / NPU" below, read it as the
> design goal, not the current runtime. Rationale and scope are logged in
> [`../knowledge/decisions.md`](../knowledge/decisions.md) (the "On-device moderation" and "Moderation
> ENFORCEMENT" entries); the shipped surfaces are tracked in [roadmap.md](roadmap.md) Phase 7.

## Principle

> **Screen shared uploads on the box, with the box's own AI, on by default — privately.**
> Nothing a user shares (files, pastes, forum posts, mail attachments, mesh shares) is
> published to others until it's been checked locally. No image or text is ever sent off the
> box to do it.

This is the trust-and-safety half of "baked-in intelligence": the same on-device AI that
runs the setup assistant also guards what gets shared.

## What gets screened

Any **user-generated / uploaded** content on the sharing surfaces:

| Surface | What's checked |
|---------|----------------|
| **Files & Pastebin** (MicroBin) | uploaded images/files, paste text |
| **Message Boards** (NodeBB) | post images/attachments, post text |
| **Files across computers** (SeaweedFS shares) | uploaded media |
| **Mail** (maddy) attachments *(optional)* | image attachments |

Not screened: the *mirrored Library* (Wikipedia/ZIMs) and models — those are curated
content the operator chose, not user uploads.

## What it detects (default profile)

- **Images:** NSFW / nudity / explicit content via a small on-device image classifier
  (ONNX — runs on the NPU, else GPU/CPU; fast enough to gate an upload).
- **Text (optional, on by default for public boards):** abuse/harassment/explicit via a
  small safety LLM — Val Ark already curates **Llama-Guard** for exactly this
  (`models-extra.tsv`), and the setup assistant models can serve double duty.
- Extensible: CSAM-hash lists, spam, malware-signature checks can slot into the same hook
  later; the architecture is "a pipeline of local checks."

## What happens on a hit

Configurable action, default **Block with a kind message**:

- **Block** *(default)* — the upload is refused before anyone else sees it. The uploader
  gets a plain, non-shaming message: *"This didn't look appropriate to share here, so it
  wasn't posted. If that's a mistake, ask whoever runs this box."*
- **Quarantine for review** — the item is held, not published, and lands in an **admin
  moderation queue** (Approve / Remove). Good for a community board.
- **Flag** — allowed but marked for the admin. (Least strict.)

Sensitivity is a simple slider (Strict / Balanced / Lenient), Balanced by default.

## The owner/admin experience

- **Default-on, invisible when clean.** A family sets nothing up; it just works. The admin
  sees a Safety card only when there's something to know.
- **Settings** (Admin → Apps & Services → Safety): master toggle (on), sensitivity, which
  surfaces to screen, action on hit, and a **Review queue** for quarantined items.
- **Plain framing:** *"Val Ark checks shared files and posts for inappropriate content, right
  on this box, using its own AI. Nothing is sent to the internet."*
- **Kids mode / stricter default** available as a one-tap profile for family boxes.

## Architecture (implementation notes)

- A small **moderation service/hook** (`scripts/services/moderation.sh` or a module in
  `server.js`) exposing a local `check(content) → allow | block | quarantine`.
- The sharing services call it **before accepting** an upload (a pre-store hook in the
  reverse-proxy / a MicroBin/NodeBB upload interceptor / a SeaweedFS filer hook).
- **Model runtime:** the NSFW ONNX classifier via `onnxruntime` (mirrored tool) on the NPU
  where present (RK3588/UT2), else GPU/CPU; text via `llama.cpp` + Llama-Guard. Both are
  small and already in Val Ark's tool/model orbit.
- **Curated models** (add to `data/models-extra.tsv`, mirrored + prioritized when moderation
  is on): a small NSFW image classifier (ONNX) + Llama-Guard (already present).
- **Fully local & offline:** no external API, no telemetry; runs with the internet unplugged.
- **Fails safe:** if the classifier can't load, the default is to **hold uploads for admin
  review** (fail-closed on public surfaces), not silently allow — with a clear admin notice.
- **Performance:** gate on upload; screen asynchronously for large batches with a "checking…"
  state, so the UI never blocks.

## Honest scope

- On-device moderation is **strong for casual protection** (accidental/obvious content) and
  privacy-preserving, but it is **not perfect** — no classifier is. Framed honestly to the
  admin; the review queue + block-by-default cover the gaps for stricter settings.
- It's about keeping a **shared LAN space appropriate**, consistent with the appliance being
  a trusted household/community device — not a legal-grade filter.

> This leans on the on-device AI already central to Val Ark (assistant models, NPU/GPU) and
> the curated Llama-Guard safety model. See [downloads-monitoring.md](downloads-monitoring.md)
> (models), [access-identity.md](access-identity.md) (who can share), and the on-device AI
> notes in [research-brief.md](research-brief.md).
