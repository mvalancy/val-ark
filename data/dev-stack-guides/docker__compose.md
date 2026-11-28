# Docker Compose

Starts a group of containers from one `compose.yaml` file. Most self-hosted apps ship one.

## Install (as a Docker plugin)

Take the file for your machine: `docker-compose-linux-x86_64`, `docker-compose-linux-aarch64`,
`docker-compose-darwin-aarch64` or `docker-compose-windows-x86_64.exe`. It is one program.

Linux / macOS, for your user only:

```
mkdir -p ~/.docker/cli-plugins
cp docker-compose-linux-x86_64 ~/.docker/cli-plugins/docker-compose
chmod +x ~/.docker/cli-plugins/docker-compose
docker compose version
```

For every user on Linux, put it in `/usr/local/lib/docker/cli-plugins/` instead.
Windows: copy the `.exe` to `%USERPROFILE%\.docker\cli-plugins\docker-compose.exe`.

It needs a running Docker Engine: see the Docker Engine guide.

## First steps offline

```
docker compose up -d      # start what compose.yaml describes
docker compose ps         # what is running
docker compose logs -f    # follow the logs
docker compose down       # stop and remove
```

Offline, every image named in the file must already be on the machine (`docker load -i`)
or come from a LAN registry: write `image: <ark>:5000/name:tag` in `compose.yaml`.
A `build:` section only works if its base image is local too.
