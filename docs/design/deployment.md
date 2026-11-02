# Val Ark — Deployment, Security & Reliability

Part of the [design hierarchy](README.md). "Wrap it all up: containerized with Docker,
secure, and reliable." This defines how Val Ark **ships and stays trustworthy** — without
losing the offline, self-replicating, hardware-integrated soul that makes it Val Ark.

## Two deployment paths, one appliance (don't pick — offer both)

| Path | What it is | For |
|------|------------|-----|
| **Appliance image** *(the "easy button")* | A Docker/Compose stack: `docker compose up -d` and Val Ark is running; commission it in the browser. | The 90% case — reliable, reproducible, one-command. |
| **Bare-metal bootstrap** *(already built)* | `curl http://<ark>/bootstrap.sh \| bash` → clone + setup, no Docker. | Boxes without Docker, max control, tiniest footprint, or where device access is easier bare. |

Both land on the **same web UI + commissioning wizard** — Docker is a packaging choice, not a
different product. The offline **self-replication** carries *both*: a source Ark serves the
code/bundle **and** a saved image tarball (`docker save`), so a new node can `docker load` +
`compose up` with no internet, exactly as it already serves the Node runtime.

## Container topology

- **`valark-core`** — the zero-dep Node web server + the librarian + the self-heal loop.
- **Community services** as their own containers in Compose (`chat`, `mail`, `forum`+`redis`,
  `paste`) — or managed in-core as today; Compose is cleaner for isolation + restart policy.
- **`kiwix`** — content server. **`seaweedfs`** (optional) for the multi-computer pool.
- **AI runtimes** (`llama.cpp`, `onnxruntime`) — in-core or a sidecar, with device access for
  the assistant + moderation.

## Host integration (the hard, appliance-specific parts)

- **Storage pool** → bind-mount the data volumes; the multi-drive/DAS add-remove
  ([storage.md](storage.md)) is a host-mount concern the container simply sees. `state`
  (the brain) and `content` (the multi-TB library) are **separate volumes** — the
  content-safety invariant, enforced at the volume layer.
- **NPU / GPU** → device passthrough (`/dev/dri`, `/dev/kfd`, the NVIDIA runtime, or the
  RK3588/UT2 NPU device nodes) so on-device AI (assistant + [moderation](safety-moderation.md))
  works in-container.
- **Discovery + LAN + port 80** → **host networking** (or macvlan) so `valark.local` mDNS,
  LAN reachability, and `:80` work like an appliance; avoids double-NAT.
- **Least privilege** → run as a **non-root** user; drop capabilities; grant only what a
  feature needs (e.g. the port-80 redirect prefers host `setcap`/config over a privileged
  container). Nothing runs privileged by default.

## Security posture (consolidated)

Val Ark's security is defense-in-depth for a **trusted-LAN appliance, never the public
internet**:

- **Never a usable default credential** — only the one-time claim token; admin is created at
  first boot ([access-identity.md](access-identity.md)).
- **Network floor:** public internet denied for writes; LAN/tailnet allowed; localhost/console
  trusted (already built: the LAN gate + rate limiter).
- **Access model** the operator chooses (Open default) + two roles + optional 2FA.
- **Encrypted transport:** the local CA + HTTPS, with a real trust guide ([the HTTPS guide](../ENCRYPTION.md)).
- **On-device content moderation** default-on for shared uploads.
- **Offline by construction:** no phone-home, no telemetry, no cloud — the smallest possible
  attack surface. Fail-closed on un-owned/broken states.
- **Container hardening:** non-root, read-only root filesystem + writable volumes only, dropped
  caps, pinned base image, no secrets baked into the image (generated on first run, kept in the
  `state` volume at `600`).
- **Provenance:** reproducible builds; the served image/bundle carries a version + checksum so a
  node can verify what it loaded.
- **Honest scope:** protects against casual LAN access, accidental changes, and inappropriate
  shares; it is a household/community appliance, not a hardened bastion, and whoever physically
  holds the box controls it (stated plainly, and why — [access-identity.md](access-identity.md)).

## Reliability

- **Restart policy** `unless-stopped` + Docker **healthchecks** on `/api/health`; a crashed
  service comes back on its own.
- **The self-heal loop** runs inside and keeps everything converged (links, services, content,
  verification) — the same autonomy, now with container restart underneath it.
- **Atomic updates + rollback:** image tags + "keep the previous image"; an update that fails
  its healthcheck **auto-rolls back** (surfaced in [errors-selfheal.md](errors-selfheal.md)),
  and a half-finished update trips **Safe Mode** ([recovery.md](recovery.md)) rather than a dead
  box. The bare-metal path mirrors this via the git bundle + previous checkout.
- **Data durability:** content/state on named volumes survive container replacement, updates,
  and rebuilds; nothing important lives in the container's writable layer.
- **Resource guards:** memory/CPU limits so no one service starves the box; the footprint cap
  bounds disk.
- **Reliability is *tested*:** the fresh-VM matrix already proves clean setup on Ubuntu 22/24/26;
  add a **container-up e2e** (compose up → healthy → commission → survive restart) and a
  **recovery e2e** to the [test library](../../tests/README.md).

## What we build (→ [roadmap.md](roadmap.md), folds into Phases 1–8)

- A **`Dockerfile`** (`valark-core`, non-root, multi-arch: amd64 + arm64) + a **`compose.yml`**
  (core + kiwix + optional services + optional seaweedfs), with device/host-net/volume wiring.
- **Image mirroring** into self-replication (`docker save` → served under `/sources/val-ark/`),
  so the appliance image travels offline like the code + Node runtime.
- **Healthchecks, restart policies, resource limits, atomic-update + rollback** wired in.
- Container hardening (non-root, read-only rootfs, dropped caps) + a security checklist doc
  reconciled with the existing [SECURITY-AUDIT.md](../SECURITY-AUDIT.md).
- CI-style **container e2e** in the test harness.

> Docker is the *reliable, easy* front door; the bare-metal bootstrap is the *maximal-control,
> minimal-dependency* one. Both are first-class, both offline, both commissioned from the same
> friendly wizard.
