# JMDN Validator Runbook

Everything needed to run a JMDN validator node and report its health to
Jupiter Meta — as playbooks you run yourself, on your own machine, with no
inbound access granted to anyone.

## Start here

**[RUNBOOK.md](RUNBOOK.md)** — the complete procedure, from a bare machine to a
running node reporting its health. Every step states the command, what you should
see, and what to do if you see something else.

Already running a node? Go to Stage 2 of the runbook.

| | |
|---|---|
| [RUNBOOK.md](RUNBOOK.md) | the procedure — start here |
| [TELEMETRY.md](TELEMETRY.md) | exactly what leaves your machine |
| [docs/DESIGN.md](docs/DESIGN.md) | why each component is here, what was rejected |

> **Scope of this release.** The **observability layer** is fully automated:
> host metrics, systemd unit health for `jmdn`/`immudb`/`redis`, chain health
> (block height, endpoint liveness, ImmuDB connectivity), and an agent that
> pushes it all to Jupiter Meta over one outbound HTTPS connection.
>
> Node installation itself is a **documented manual procedure** — Stage 1 of the
> runbook, which follows `GETTING_STARTED.md` in the
> [jmdn repo](https://github.com/JupiterMetaLabs/jmdn) with the mainnet values
> filled in. Automating it as `site.yml` is next.

---

## What gets installed

Two long-running services and one timer. Nothing else.

| Unit | What it does | Listens on | Cap |
|---|---|---|---|
| `node_exporter` | host metrics, systemd unit state, textfile metrics | `127.0.0.1:9100` | 80 MB / 10% CPU |
| `otelcol-contrib` | scrapes loopback, pushes to Jupiter Meta | `127.0.0.1` only | 256 MB / 20% CPU |
| `jmdn-health.timer` | 30s oneshot: block height, endpoint health | — | no resident memory |

Notably **not** installed: Prometheus, Grafana, Loki, Promtail, Alertmanager.
Reasoning for every choice is in [docs/DESIGN.md](docs/DESIGN.md).

Nothing listens on a public interface. Telemetry leaves over a single outbound
HTTPS connection, so this works behind NAT, CGNAT or a dynamic IP with no
inbound firewall change.

---

## Quickstart

```bash
# 1. Get the runbook
git clone https://github.com/JupiterMetaLabs/jmdn-validator-runbook.git
cd jmdn-validator-runbook

# 2. Control-side dependency — ansible-core only, no collections
sudo ./install-deps.sh          # or do it yourself:
#   Debian/Ubuntu: sudo apt-get install -y python3-pip \
#                  && sudo python3 -m pip install --break-system-packages ansible-core
#   RHEL/Amazon:   sudo dnf install -y python3-pip \
#                  && sudo python3 -m pip install ansible-core

# 3. Your details: node name, network, the token we issued you
cp operator.yml.example operator.yml && chmod 600 operator.yml
${EDITOR:-nano} operator.yml

# 4. Dry run. Shows every change before anything happens.
sudo ansible-playbook observability.yml --check --diff

# 5. Apply
sudo ansible-playbook observability.yml

# 6. Prove it
sudo ansible-playbook verify.yml
```

`verify.yml` is read-only and safe to run at any time, including during an
incident. It never writes a file or restarts a service.

Both playbooks are idempotent: run them as often as you like. A second run with
no config change reports `changed=0`.

---

## What we can and cannot see

Full list in [TELEMETRY.md](TELEMETRY.md). In short: standard host metrics, the
run state of four systemd units, block height, and whether your local endpoints
answer. We do **not** receive keys, transaction contents, config files, or shell
access.

Setting `telemetry.enabled: false` installs the local exporters and sends
nothing — the metrics remain available to you at
`curl -s localhost:9100/metrics`.

---

## Day-2 operations

```bash
# Health at a glance
sudo ansible-playbook verify.yml

# What is this node reporting right now?
curl -s localhost:9100/metrics | grep -E '^(jmdn_|node_systemd_unit_state)'

# Is telemetry actually being delivered?
curl -s localhost:8888/metrics | grep otelcol_exporter

# Service logs
journalctl -u otelcol-contrib -f
journalctl -u node_exporter -n 50
journalctl -u jmdn-health.service -n 20

# Rotate your telemetry token: edit operator.yml, then
sudo ansible-playbook observability.yml --tags agent

# Upgrade node_exporter or the agent: bump the version in the role defaults,
# then re-run. Both installs are version-aware, so this is a rolling upgrade.
sudo ansible-playbook observability.yml
```

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `preflight` fails on the gateway check | outbound TCP 443 to `otel.jmdt.io` is blocked. No inbound rule is needed, but the outbound connection must be allowed. |
| `verify` says 0 metric points exported | usually a rejected token (HTTP 401). `journalctl -u otelcol-contrib -n 80`. |
| `verify` says metrics are stale | the health collector stopped. `systemctl status jmdn-health.timer`, then `journalctl -u jmdn-health.service`. node_exporter serves stale textfile metrics indefinitely, which is exactly why this check exists. |
| `node_systemd_unit_state` missing | the systemd collector could not reach D-Bus. `journalctl -u node_exporter`. See D-4 in the decision record. |
| Block height not advancing | your node is not syncing — that is a node problem, not a telemetry problem. `journalctl -u jmdn -n 100`. |
| Everything green but nothing in our dashboards | send us your `node_id` and `operator_id`. These are sent as you set them, so a typo puts your node under the wrong identity — that is the usual cause. |

---

## Repository layout

```
observability.yml        telemetry layer (this release)
verify.yml               read-only health gate
operator.yml.example     the only file you edit
profiles/mainnet.yml     network parameters, published by Jupiter Meta
roles/preflight          assert-only; mutates nothing
roles/node_exporter      host + systemd + textfile metrics
roles/jmdn_health_collector  chain health via a 30s timer
roles/otel_agent         the push agent
roles/verify             health gate
tests/render_config.yml  offline template render gate
docs/DESIGN.md           why each component is here, and what was rejected
```

---

## Contributing / reporting

Issues and PRs welcome. When reporting a problem, include the output of
`sudo ansible-playbook verify.yml` — it is designed to be safe to paste.

Licence: see `LICENSE`.
