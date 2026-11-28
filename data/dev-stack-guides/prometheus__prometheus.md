# Prometheus

Collects numbers from your machines and services every few seconds (CPU, disk, requests,
temperatures), keeps their history, and lets you graph and alert on them. It needs no
internet: it only talks to machines on your LAN.

## Install

`prometheus-<version>.linux-amd64.tar.gz`, `.linux-arm64`, `.darwin-arm64` or `.windows-amd64.zip`.

```
tar xzf prometheus-*.linux-amd64.tar.gz
cd prometheus-*.linux-amd64
./prometheus --version
```

## First steps offline

Edit `prometheus.yml` in that folder. This watches Prometheus itself and two machines that
run node_exporter (see its guide):

```
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
  - job_name: machines
    static_configs:
      - targets: ["box-one.lan:9100", "box-two.lan:9100"]
```

Start it:

```
./prometheus --config.file=prometheus.yml
```

Open `http://<this machine>:9090`. Under **Status, Targets** every machine should say UP.
Try a query such as `up`, or `node_filesystem_avail_bytes` for free disk space.

Data is kept in the `data/` folder beside the program, 15 days by default
(`--storage.tsdb.retention.time=90d` keeps more).

For dashboards, add this server to Grafana (on the Ark's Software page) as a Prometheus
data source with the URL above. For alerts, see the Alertmanager guide.
