# node_exporter

A small program that publishes one machine's vital signs (CPU, memory, disks, network,
temperatures) so Prometheus can collect them. Run it on every machine you want to watch.

## Install

Linux and macOS only: `node_exporter-<version>.linux-amd64.tar.gz`, `.linux-arm64` or `.darwin-arm64`.

```
tar xzf node_exporter-*.linux-amd64.tar.gz
sudo cp node_exporter-*.linux-amd64/node_exporter /usr/local/bin/
node_exporter --version
```

## First steps offline

Start it:

```
node_exporter
```

It listens on port 9100. Check from another machine: `curl http://<this machine>:9100/metrics`

To keep it running after a reboot, create `/etc/systemd/system/node_exporter.service`:

```
[Unit]
Description=node_exporter
After=network.target

[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
```

Then `sudo systemctl daemon-reload && sudo systemctl enable --now node_exporter`.

Last, add `<this machine>:9100` to the `targets` list in Prometheus's `prometheus.yml`
(see the Prometheus guide) and restart Prometheus.
