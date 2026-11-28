# Alertmanager

Prometheus decides when something is wrong; Alertmanager decides who hears about it. It
groups alerts, silences repeats and sends them on. Offline that means a mail server or a
webhook on the LAN, not a cloud paging service.

## Install

`alertmanager-<version>.linux-amd64.tar.gz`, `.linux-arm64`, `.darwin-arm64` or `.windows-amd64.zip`.

```
tar xzf alertmanager-*.linux-amd64.tar.gz
cd alertmanager-*.linux-amd64
./alertmanager --version
```

## First steps offline

Edit `alertmanager.yml`. This sends every alert to a webhook on your LAN (any small
service that accepts a POST, such as a chat bridge):

```
route:
  receiver: lan
receivers:
  - name: lan
    webhook_configs:
      - url: http://<a LAN service>/alert
```

Start it: `./alertmanager --config.file=alertmanager.yml` and open `http://<this machine>:9093`.

Tell Prometheus where it is, and give it a rule. In `prometheus.yml`:

```
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["localhost:9093"]
rule_files:
  - rules.yml
```

And in `rules.yml` beside it:

```
groups:
  - name: basics
    rules:
      - alert: MachineDown
        expr: up == 0
        for: 2m
```

Restart Prometheus. Stop a node_exporter to test: the alert shows up in both web pages.
`amtool`, in the same folder, checks a config: `./amtool check-config alertmanager.yml`
