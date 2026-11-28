# Caddy

A web server and reverse proxy in one program. It has its own certificate authority, so
LAN services get real HTTPS with no internet and no Let's Encrypt.

## Install

- Linux: `caddy_<version>_linux_amd64.tar.gz` (or `_linux_arm64`). The program inside is `caddy`.
- macOS: `caddy_<version>_mac_arm64.tar.gz`.
- Windows: `caddy_<version>_windows_amd64.zip`; the program is `caddy.exe`.

```
tar xzf caddy_*_linux_amd64.tar.gz caddy
sudo mv caddy /usr/local/bin/
caddy version
```

## A LAN site with HTTPS

Save this as `Caddyfile`. `tls internal` tells Caddy to sign the certificate with its own
local CA instead of asking the internet.

```
wiki.lan {
    tls internal
    reverse_proxy 127.0.0.1:8080
}

files.lan {
    tls internal
    root * /srv/files
    file_server browse
}
```

Run it from that folder: `sudo caddy run` (or `sudo caddy start` to leave it in the background).
The names must resolve on your LAN (your router's DNS, or a line in each client's hosts file).

## Trust the root on clients

Browsers warn until they trust Caddy's root certificate. On the Caddy machine it is at
`~/.local/share/caddy/pki/authorities/local/root.crt` (for a Caddy run with `sudo`:
`/root/.local/share/caddy/...`). Copy that file to each client, then:

- Linux: `sudo cp root.crt /usr/local/share/ca-certificates/caddy-root.crt && sudo update-ca-certificates`
- macOS: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root.crt`
- Windows (admin prompt): `certutil -addstore -f Root root.crt`
- Firefox keeps its own list: Settings, Certificates, Import.

`caddy trust` does the same for the machine Caddy runs on. Copy only `root.crt`; the
`root.key` beside it must never leave the Caddy machine.
