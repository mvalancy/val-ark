# Docker Engine (static binaries)

Docker runs software in containers. These are the plain Linux programs (`dockerd`,
`docker`, `containerd`, `runc`), with no package manager needed. Many self-hosted apps
only document `docker run`, so this is what makes them usable offline.

Linux only. Take the folder for your CPU: `x86_64` (Intel/AMD) or `aarch64` (ARM64, Jetson).

## Install

```
tar xzvf docker-<version>.tgz
sudo cp docker/* /usr/local/bin/
sudo dockerd &
sudo docker version
```

`dockerd` is the engine; it runs as root and must stay running. It needs `iptables`
(in the Ark's offline APT sets if your system lacks it).

To start it at boot, create `/etc/systemd/system/docker.service`:

```
[Unit]
Description=Docker Engine
After=network-online.target

[Service]
ExecStart=/usr/local/bin/dockerd
Restart=always
LimitNOFILE=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
```

Then `sudo systemctl daemon-reload && sudo systemctl enable --now docker`.
To use Docker without `sudo`: `sudo groupadd docker; sudo usermod -aG docker $USER`, then log in again.

`docker-rootless-extras-<version>.tgz` holds the extra programs for rootless mode.

## First steps offline

There is no Docker Hub offline, so images come from files or from a registry on the LAN.

- Load an image file: `docker load -i image.tar`
- Save one for another box: `docker save -o image.tar name:tag`
- Pull from a LAN registry: see the **distribution** (registry) guide.
- Add Compose and Buildx as plugins: see their guides.
