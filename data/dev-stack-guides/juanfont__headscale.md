# Headscale

Tailscale clients need a control server to find each other, and the normal one is on the
internet. Headscale is that server, run by you. With it, the Tailscale apps the Ark already
mirrors keep working as a private mesh VPN with no internet at all.

## Install

One program per platform: `headscale_<version>_linux_amd64`, `_linux_arm64` or
`_darwin_arm64` (a `.deb` is there too). No Windows server; Windows machines join as clients.

```
sudo install headscale_*_linux_amd64 /usr/local/bin/headscale
sudo mkdir -p /etc/headscale /var/lib/headscale /var/run/headscale
headscale version
```

## A minimal config

Save as `/etc/headscale/config.yaml` (every setting is explained in `config-example.yaml`,
inside the source tarball beside the programs). Clients must reach `server_url`, so use the
server's LAN name or address. An empty `derp.urls` plus the built-in relay means nothing
points at the internet.

```
server_url: https://<ark>:8443
listen_addr: 0.0.0.0:8443
tls_cert_path: /etc/headscale/server.crt
tls_key_path: /etc/headscale/server.key
noise:
  private_key_path: /var/lib/headscale/noise_private.key
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
derp:
  server:
    enabled: true
    region_id: 999
    region_code: "ark"
    region_name: "Ark relay"
    stun_listen_addr: "0.0.0.0:3478"
    private_key_path: /var/lib/headscale/derp_server_private.key
    ipv4: <the server's LAN address>
  urls: []
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
dns:
  magic_dns: true
  base_domain: ark.internal
  override_local_dns: false
unix_socket: /var/run/headscale/headscale.sock
```

The built-in relay needs HTTPS: use a certificate from your local CA and trust that CA on
the clients (see the Caddy guide). Start it: `sudo headscale serve`

## Join a machine

```
sudo headscale users create alice
sudo headscale users list                      # note alice's ID
sudo headscale preauthkeys create --user <ID>
```

On each client, with the mirrored Tailscale installed:
`sudo tailscale up --login-server https://<ark>:8443 --auth-key <key>`
