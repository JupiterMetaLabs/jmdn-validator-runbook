# What leaves your machine

Complete and exhaustive. If it is not listed here, it is not sent.

Everything travels over **one outbound HTTPS connection** to
`https://otel.jmdt.io`, authenticated with the bearer token in your
`operator.yml`. Nothing listens for inbound connections.

To see exactly what is being collected at any moment:

```bash
curl -s localhost:9100/metrics
```

That is the same data we receive. There is no second channel.

---

## 1. Host metrics — from `node_exporter`

Standard Prometheus host metrics, restricted to a whitelist of 18 collectors:

| Area | Metrics |
|---|---|
| CPU | `node_cpu_seconds_total` (per core, per mode) |
| Memory | `node_memory_*` (total, available, cached, swap) |
| Disk | `node_filesystem_*` (size, available, per mount), `node_disk_*` (IO bytes and time) |
| Network | `node_network_*` (bytes, packets, errors, per interface), `node_netstat_*`, `node_sockstat_*` |
| Load | `node_load1/5/15`, `node_pressure_*` (PSI) |
| Clock | `node_time_seconds`, `node_timex_offset_seconds`, `node_timex_sync_status` |
| System | `node_boot_time_seconds`, `node_context_switches_total`, `node_filefd_*`, `node_uname_info`, `node_os_info` |

Deliberately **not** collected: `mdadm`, `ipvs`, `infiniband`, `xfs`, `zfs`,
`nfs`, `nfsd`, `fibrechannel`, `tapestats`, `bcache`, `hwmon`, `thermal_zone`,
and the exporter's own `go_*`/`promhttp_*` series.

## 2. Service state — from `node_exporter`'s systemd collector

Restricted by regex to exactly six units. No other unit on your system is
visible to it — the collector cannot enumerate anything outside this list.

| Metric | Meaning |
|---|---|
| `node_systemd_unit_state{name="jmdn.service"}` | running / stopped / failed |
| `node_systemd_unit_state{name="immudb.service"}` | as above |
| `node_systemd_unit_state{name="redis-server.service"}` | as above |
| `node_systemd_unit_state{name="otelcol-contrib.service"}` | as above — the telemetry agent itself |
| `node_systemd_unit_state{name="jmdn-health.service"}` | as above — the health collector |
| `node_systemd_unit_state{name="node_exporter.service"}` | as above — this exporter |
| `node_systemd_service_restart_total` | restart count — distinguishes a crash loop from a healthy node |
| `node_systemd_unit_start_time_seconds` | when the unit last started |

The last three are the kit's own units. They are included so that a node
reporting nothing can be told apart from a node whose reporting broke.

## 3. Chain health — from the local collector

Derived from three HTTP calls to **your own loopback interface**:

| Metric | Source |
|---|---|
| `jmdn_block_height` | `eth_blockNumber` on the local facade |
| `jmdn_chain_id` | `eth_chainId` on the local facade |
| `jmdn_build_info{version=…}` | `GET /api/v1/node/version` on the local explorer |
| `jmdn_endpoint_up{endpoint=…}` | did the explorer root / version / facade endpoint answer |
| `jmdn_endpoint_response_seconds{endpoint=…}` | how long it took |
| `jmdn_db_healthy{db="defaultdb"\|"accountsdb"}` | **only if** you supplied `explorer_api_key` |
| `jmdn_health_collector_probe_failures` | probes that did not return 2xx |
| `jmdn_health_collector_last_run_timestamp_seconds` | freshness — so a dead collector cannot masquerade as a healthy node |

## 4. jmdn application metrics — only if you enable them

Sent only when `jmdn_endpoints.metrics_port` is non-zero and jmdn is configured
to serve them on loopback: `p2p_*` (peer counts, heartbeat latency, message
counts, rejected blocks), `main_db_*`/`accounts_db_*` (ImmuDB connection
pools), `gro_*` (goroutine accounting), `libp2p_*`.

## 5. Logs and traces — on by default

jmdn's own structured logs and traces, exactly as jmdn emits them, forwarded
through the local agent. This is jmdn's normal OTLP output; the agent only adds
identity labels and a disk buffer.

Two switches control it, and **both** must be on — which they are by default:
`telemetry.forward_node_logs: true` in your `operator.yml` (the agent accepts
OTLP on `127.0.0.1:4317`) and `logging.otel.enabled: true` in your `jmdn.yaml`
(the node sends it). Set either to `false` to stop it.

Your logs are your node's operational logs, not chain data. They contain what you
see in `journalctl -u jmdn`.

## 6. Identity attached to everything above

`server`, `operator_id`, `node_role`, `chain_id`.

| Label | Where it comes from |
|---|---|
| `server` | `node.alias` in your `/etc/jmdn/jmdn.yaml` — the name the network already knows your node by. `operator.yml` ships `node_id: "auto"` to derive it, so you set the name in one place |
| `operator_id` | `operator.yml` — the ID we issued you |
| `node_role` | `operator.yml`, default `validator` |
| `chain_id` | the network profile, not something you set |

All four are sent **as you set them**. Your bearer token authenticates the
connection and the gateway records which token each submission arrived on, so a
mismatch between your labels and your token is visible to us as a support issue —
but the labels themselves are not currently rewritten server-side.

Two practical consequences:

- **Your node's name must be unique across your nodes.** Two machines sharing one
  name produce conflicting series that are rejected on arrival.
- Set `operator_id` to the value we issued you. A wrong value does not gain you
  access to anything, but it does mean your node shows up in the wrong place and
  your alerts do not reach you.

---

## What is never sent

- Private keys, mnemonics, or any key material.
- `/etc/jmdn/jmdn.yaml` or any configuration file. It contains your
  `jwt_secret`, `explorer_api_key`, and database passwords, and is never read
  for transmission. The `explorer_api_key` you optionally supply is used
  **locally only**, to authenticate loopback health calls.
- Transaction contents, account balances, or chain data beyond the head height.
- Shell access, command execution, or any inbound channel. This kit opens no
  listening port off-box and grants Jupiter Meta no access to your machine.
- Anything at all when `telemetry.enabled: false`.

## Turning it off

```yaml
# operator.yml
telemetry:
  enabled: false
```

Then `sudo ansible-playbook observability.yml`. The agent is stopped; the local
exporters keep running for your own use.
