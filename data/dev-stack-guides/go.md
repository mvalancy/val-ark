# Go

The Go programming language: compiler and tools in one folder. A lot of infrastructure
software is written in Go (Caddy, Gitea, Docker, Prometheus, rclone), and Go can build for
any other platform from the machine you are on.

## Install

- Linux: `go<version>.linux-amd64.tar.gz` (or `linux-arm64` for Jetson and other ARM64).
- macOS: `go<version>.darwin-arm64.pkg` (double-click) or the `.tar.gz`.
- Windows: `go<version>.windows-amd64.msi` (installer) or the `.zip`.
- `go<version>.src.tar.gz` is the source code of Go itself.

Linux:

```
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go*.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
go version
```

Add the `export` line to `~/.profile` to keep it.

## First steps offline

```
mkdir hello && cd hello
go mod init example.com/hello
```

Write `main.go`, then `go run .` to run it and `go build` to make a program.
Build for another platform: `GOOS=windows GOARCH=amd64 go build`

Go normally downloads libraries, and even newer Go versions, on demand. Offline, switch that off:

```
go env -w GOPROXY=off GOTOOLCHAIN=local
```

A program that uses only the standard library builds with nothing else. For a project
with dependencies, their code must already be on disk: either the project carries a `vendor/`
folder (build with `go build -mod=vendor`), or copy a filled module cache
(`~/go/pkg/mod` from a machine that built it online) to the same place here.
