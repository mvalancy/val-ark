# Val Ark — Encryption & TLS

Val Ark is an offline LAN appliance, so there is no public Certificate Authority
and no internet to reach Let's Encrypt. To still get encrypted connections, Val
Ark runs its **own tiny local Certificate Authority** and issues itself a server
certificate that covers every name and address a device might reach the Ark by
(`localhost`, `valark.lan`, and the box's LAN + Tailscale IPs).

## Threat model — read this first

Encryption is not one thing. These are three different guarantees:

| Layer | Protects against | Status |
|-------|------------------|--------|
| **Transport (TLS/HTTPS)** | other people on your network sniffing traffic & stealing passwords | **shipped** (this doc) |
| **At-rest (disk encryption)** | someone stealing/reading the powered-off disk | future (host/sudo) |
| **End-to-end (E2EE)** | *the Ark operator / root* reading users' mail & files | future (large redesign) |

> **Important:** TLS and disk encryption do **not** stop the machine's operator
> (root) from reading mail or files on a *running* box. The only thing that does
> is end-to-end encryption, where keys live with each user and the server only
> ever sees ciphertext. That is a separate, larger project — see *Future layers*.

## What's encrypted today

With TLS enabled (the default when `openssl` is present):

- **Web UI + everything proxied through it** (chat / forum / files / Kiwix library)
  is served over **HTTPS** on port `8443`.
- **Mail** (maddy) offers **STARTTLS** on IMAP (`1143`) and submission (`1587`).
  With a cert present maddy refuses plaintext `AUTH`, so credentials are never
  sent in the clear.
- **Chat** (ngIRCd) is bound to **loopback only**; the plaintext IRC hop never
  leaves the box. Users reach chat through The Lounge over the Ark's HTTPS proxy.
  (The mirrored ngIRCd build has no native TLS, so loopback + HTTPS is how chat
  is kept off the wire.)

Still in the clear: data **at rest** on the data disk (the FUSE/NTFS mount is
world-readable — see `docs/SECURITY-AUDIT.md`). That's the "at-rest" layer above.

## Trusting the Ark (one-time, per device)

Because the CA is local, browsers and mail clients don't know it yet. Install the
CA certificate once on each device and everything Val Ark serves becomes trusted:

1. On the Val Ark home page, click **Download certificate** (or fetch
   `http://<ark>:8088/ca.crt` directly — this is intentionally available over
   plain HTTP, since you can't require trusted HTTPS to fetch the trust anchor).
2. Install it as a trusted **root** CA:
   - **Windows:** double-click → *Install Certificate* → *Local Machine* →
     *Trusted Root Certification Authorities*.
   - **macOS:** open in *Keychain Access* → *System* → set to *Always Trust*.
   - **iOS:** install the profile, then *Settings → General → About → Certificate
     Trust Settings* → enable it.
   - **Android:** *Settings → Security → Encryption & credentials → Install a
     certificate → CA certificate*.
   - **Linux:** copy to `/usr/local/share/ca-certificates/valark.crt` and run
     `sudo update-ca-certificates`.
   - **Firefox** keeps its own store: *Settings → Privacy & Security →
     Certificates → View Certificates → Authorities → Import*.
3. Visit **`https://<ark>:8443`** (or click *Switch to HTTPS* in the banner).

## How it works / configuration

`scripts/lib/tls.sh` generates and maintains the CA + server cert. It is
idempotent and reissues the leaf only when the cert is expiring or the host's
addresses change.

| Env var | Default | Purpose |
|---------|---------|---------|
| `VALARK_TLS_DIR` | `~/.config/val-ark/tls` | where CA + key live (kept **off** the world-readable data disk on purpose) |
| `VALARK_TLS_DOMAIN` | `valark.lan` | primary cert name (+ wildcard) |
| `VALARK_HTTPS_PORT` | `8443` | HTTPS listen port |
| `VALARK_FORCE_HTTPS` | unset | when `1`, LAN HTTP requests 301-redirect to HTTPS (CA download + API + loopback excepted) |
| `VALARK_DISABLE_TLS` | unset | when `1`, serve HTTP only |

```bash
scripts/lib/tls.sh ensure     # generate / refresh the CA + server cert
scripts/lib/tls.sh info       # show cert subject, expiry, SANs
scripts/lib/tls.sh print-ca   # print the CA cert (PEM)
```

> The CA **private key** is the master key for the whole LAN — anyone who has it
> can impersonate the Ark. It is stored at `~/.config/val-ark/tls/ca.key` with
> `0600` perms, deliberately **not** on the FUSE/NTFS data tree (which ignores
> `chmod`). Keep that filesystem off any world-readable NFS export.

## Mail is local-only

Val Ark mail is offline by design: maddy has no outbound relay and hard-rejects
non-local recipients, so mail only ever moves between local mailboxes on this
Ark. (A future option is linking Arks to each other — the same local-CA trust
model would extend to Ark-to-Ark.)

## Future layers

- **At-rest disk encryption** (LUKS / gocryptfs): protects the disk when
  powered off. Requires `sudo` and is somewhat involved; does not hide data from
  root on a running box.
- **Operator-blind E2EE**: the only thing that makes it so the operator cannot
  read users' mail/files. Requires client-side keys (PGP-style mail, an encrypted
  file store) and trades away ease/features — a deliberate, separate design.
