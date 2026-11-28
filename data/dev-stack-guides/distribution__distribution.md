# Registry (distribution)

A container image registry: the place `docker pull` and `docker push` talk to. Offline it
replaces Docker Hub, so every box on the LAN can pull the same images from one machine.

## Install

Linux only: `registry_<version>_linux_amd64.tar.gz` or `registry_<version>_linux_arm64.tar.gz`.

```
tar xzf registry_*_linux_amd64.tar.gz
./registry --version
```

Write a small `config.yml`:

```
version: 0.1
storage:
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :5000
```

Start it: `./registry serve config.yml`

## Let Docker use it

Without TLS, each client must be told the registry is trusted. In `/etc/docker/daemon.json`
on every client (use the registry machine's address):

```
{ "insecure-registries": ["<ark>:5000"] }
```

Then restart Docker (`sudo systemctl restart docker`). With a TLS certificate from a local
CA (see the Caddy guide) this step is not needed.

## First steps offline

```
docker load -i image.tar
docker tag name:tag <ark>:5000/name:tag
docker push <ark>:5000/name:tag
docker pull <ark>:5000/name:tag        # on any other box
```

List what it holds: `curl http://<ark>:5000/v2/_catalog`
