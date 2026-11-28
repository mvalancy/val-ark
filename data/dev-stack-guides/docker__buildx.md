# Docker Buildx

The image builder behind `docker build`. You need it to build your own images, and to
build for another CPU type (for example ARM64 images on an Intel machine).

## Install (as a Docker plugin)

Take the file for your machine: `buildx-<version>.linux-amd64`, `.linux-arm64`,
`.darwin-arm64` or `.windows-amd64.exe`. It is one program.

```
mkdir -p ~/.docker/cli-plugins
cp buildx-*.linux-amd64 ~/.docker/cli-plugins/docker-buildx
chmod +x ~/.docker/cli-plugins/docker-buildx
docker buildx version
```

For every user on Linux, put it in `/usr/local/lib/docker/cli-plugins/` instead.
Windows: copy the `.exe` to `%USERPROFILE%\.docker\cli-plugins\docker-buildx.exe`.

## First steps offline

```
docker buildx build -t myapp:1 .
docker buildx build -t <ark>:5000/myapp:1 --push .
```

Offline, the `FROM` image in your Dockerfile must already be on the machine or in a LAN
registry; a build cannot fetch it from Docker Hub. Package installs inside the build
(`apt-get`, `pip`) need a local mirror too: point them at the Ark's offline APT sets and
wheelhouse.

Stay with the default builder. Other builder types (`docker buildx create`) download a
BuildKit image the first time, which fails offline unless that image is in your registry.
