# Design and Decision Record

Why each component is here, what was rejected, and what it costs — so you can
audit this kit rather than trust it.

The governing constraint is that your machine is running consensus:
**telemetry must never be able to compete with the node for CPU, memory, disk
or file descriptors.** Every decision below follows from that.

---

## Footprint

| Component | Long-running? | Configured cap | Notes |
|---|---|---|---|
| `node_exporter` | yes | `MemoryMax=80M`, `CPUQuota=10%` | whitelisted collectors only |
| `otelcol-contrib` | yes | `MemoryMax=256M`, `CPUQuota=20%`, `memory_limiter` 128 MiB | the only network-facing process |
| `jmdn-health-collector` | no — 30s oneshot | `TimeoutStartSec=15` | shell + curl + jq; zero resident memory between runs |
| **Total resident** | — | **≤ 336 MB hard ceiling, 30% of one core** | |

### Measured on two real nodes — AWS, 2 vCPU, Ubuntu 26.04

| Component | Cap | **Measured RSS** | Headroom |
|---|---|---|---|
| `node_exporter` | 80 MB | **8.6–9.0 MB** | 9x |
| `otelcol-contrib` | 256 MB | **36.0–40.8 MB** | 6x |
| **Total resident** | 336 MB | **44.6–49.8 MB** | — |

The caps are 7–9x measured usage. They stay as they are rather than being
tightened: otelcol's footprint grows with disk-queue depth during a gateway
outage, which is exactly when we least want systemd to kill it. The point of the
cap is to bound a leak, not to fit the steady state.

**Series count: 315 measured on 2 vCPU, 424 on a 4-core box.** The count scales
with CPU cores (`node_cpu_seconds_total` is 8 series per core — 16 vs 32 here),
disks, network interfaces and mounted filesystems. Budget **300–450 per node**
and expect the upper end on larger machines. Constant contributors regardless of
machine size: `netstat` (~60), `meminfo` (~50), `sockstat` (~15), `timex` (~12).

---

## D-1 — No Prometheus on the operator VM

**Decision:** do not install Prometheus, Grafana, Loki, Promtail, Alertmanager,
or cAdvisor.

**Why:** Prometheus does three things, and here each is either duplicated or
unwanted. Scraping is already done by the agent's `prometheus` receiver.
Storage is not wanted — we cannot query an operator's TSDB, so it would be a
second, invisible source of truth. Alerting belongs on the hub, which is the
only place with a fleet-wide view. What remains is 200–500 MB of RSS, a local
disk consumer, and a CVE feed to track on machines we do not own.

**Rejected:** Prometheus in agent mode (`--enable-feature=agent`) with
`remote_write`. Genuinely light, but it would require a second ingest path on
the hub (a remote-write receiver behind nginx) when an authenticated OTLP
gateway already exists and works.

---

## D-2 — Keep `node_exporter`; do not use the `hostmetrics` receiver

**Decision:** the agent scrapes `node_exporter` on loopback rather than using
OTel's native `hostmetrics` receiver, even though that would remove a daemon.

**Why:** three reasons, in order of weight.

1. **Metric vocabulary.** Jupiter Meta's dashboards and alert rules are written
   against node_exporter names — `node_cpu_seconds_total`,
   `node_memory_MemAvailable_bytes`, `node_filesystem_avail_bytes`,
   `node_load1`, `node_systemd_unit_state`. `hostmetrics` emits
   `system_cpu_utilization` and friends. Adopting it would mean maintaining two
   metric vocabularies indefinitely, and your node would be described in a
   different language from every other node on the network.
2. **`hostmetrics` has no systemd scraper.** Unit state — "is jmdn actually
   running" — is only available from node_exporter's systemd collector. That
   signal is the entire reason this kit exists, so node_exporter is required
   regardless.
3. **`hostmetrics` has no textfile equivalent.** The chain-health layer (D-5)
   needs a place to put locally-derived metrics.

**Cost:** one extra daemon at 15–25 MB. Accepted.

---

## D-3 — Whitelist collectors instead of blacklisting

**Decision:** run with `--collector.disable-defaults` and enable exactly 19
collectors.

**Why:** upstream enables roughly 40 by default, many meaningless on a cloud VM
(`mdadm`, `ipvs`, `infiniband`, `xfs`, `zfs`, `nfsd`, `fibrechannel`,
`tapestats`, `bcache`). Each costs CPU on every scrape and series storage
forever. A whitelist also means the series count is deterministic and a
node_exporter upgrade cannot silently switch new collectors on.

Included beyond the dashboard's needs, each for a specific reason:

| Collector | Why |
|---|---|
| `timex` | `node_timex_offset_seconds` / `sync_status` — clock discipline, which consensus depends on. Free NTP monitoring with no extra exporter. |
| `pressure` | PSI is the earliest warning for CPU/IO/memory contention, well before load average moves. Requires kernel ≥ 4.20. |
| `netstat`, `sockstat` | TCP retransmits and socket exhaustion are real failure modes for a libp2p node. |
| `filefd` | FD exhaustion is a classic P2P node death. |
| `systemd` | unit state + restart counters (D-4). |
| `textfile` | chain health (D-5). |

`--web.disable-exporter-metrics` drops ~40 `go_*`/`promhttp_*` self series.
`up` and `node_scrape_collector_success` still report exporter health, so this
is free.

---

## D-4 — Enable the systemd collector, with a unit include-list and restart counters

**Decision:** `--collector.systemd` with
`--collector.systemd.unit-include='^(jmdn|immudb|redis-server|otelcol-contrib|jmdn-health)[.]service$'`,
plus `--collector.systemd.enable-restarts-metrics` and
`--collector.systemd.enable-start-time-metrics`.

**Why:** `node_systemd_unit_state` is what makes "is jmdn running" answerable.
Restart counters matter independently: a crash-looping node reports
`state="active"` every time you look at it, and only
`node_systemd_service_restart_total` /
`node_systemd_unit_start_time_seconds` expose it.

**Why the include-list:** left open, this collector enumerates every unit on
the host and is a well-known cardinality amplifier.

**Two traps, both handled:**

- The collector talks D-Bus over a unix socket. The hardened unit therefore
  **must** include `AF_UNIX` in `RestrictAddressFamilies` and tolerate
  `ProtectSystem=strict` making `/run` read-only (`ReadWritePaths=-/run/dbus`,
  `-/run/systemd/private`). Omit either and the metric is silently absent while
  the service still reports `active`.
- `\.service` in `ExecStart=` makes systemd log *"Ignoring unknown escape
  sequences"*. The regex is written `[.]service` instead — identical semantics,
  no escaping ambiguity.

Both are caught before they can hide: the role scrapes its own `/metrics` after
starting and **fails the play** if `node_systemd_unit_state` is missing.

---

## D-5 — Chain health via textfile + timer, not a daemon and not a receiver

**Decision:** a 30-second `systemd` oneshot writes
`/var/lib/node_exporter/textfile/jmdn_health.prom`.

**Why it is needed at all:** jmdn's Prometheus registry contains **no block
height and no sync signal**. Verified contents: `p2p_*` (peers, heartbeats,
messages, blocks_rejected), `main_db_*` / `accounts_db_*` pool gauges, `gro_*`
goroutine accounting, `libp2p_*`. "Am I in sync?" — the only question an
operator really cares about — is currently unanswerable from metrics.

**Why a timer:** ~5 ms of CPU per run and zero resident memory between runs. A
daemon would cost 30–80 MB permanently to do the same three HTTP calls.

**Why not a jmdn code change instead:** it should also happen —
`jmdn_block_height` belongs in jmdn's own registry. But the timer works against
*any* jmdn version an operator is running, including releases older than that
change, so it earns its place either way.

**Two safety properties, both load-bearing:**

- **Atomic write.** `mktemp` + `mv`. node_exporter reads that directory
  continuously and a half-written file breaks the *entire* scrape, not just
  these metrics.
- **`jmdn_health_collector_last_run_timestamp_seconds`.** node_exporter serves
  stale textfile metrics indefinitely. Without an age signal, a frozen block
  height and a dead collector are indistinguishable — which would make this
  layer worse than having no layer. `verify` and the hub-side rules both alert
  on its age.

**Sync lag is computed hub-side**, as `jmdn_reference_head - jmdn_block_height`.
Doing it on the operator's box would mean trusting their view of the network
head.

---

## D-6 — `otelcol-contrib`, pinned to the hub's version

**Decision:** `otelcol-contrib` 0.144.0 — byte-for-byte the distribution and
version already running on the observability hub.

**Why:** one binary to learn, one config language, one CVE feed, one upgrade
path across hub and operator fleet.

**Rejected:** Grafana Alloy (second agent technology, larger footprint);
`vmagent` (no OTLP, would need a new hub ingest path); Prometheus agent mode
(same).

**Tracked follow-up (D-6a):** contrib bundles every upstream component, which
is why the binary is large. This kit uses only `prometheus` + `otlp` receivers,
`memory_limiter`/`attributes`/`resource`/`batch` processors, `otlphttp`
exporter, and `file_storage`. A purpose-built distribution via `ocb` with
exactly that manifest would cut binary size substantially and shrink the attack
surface to the components in use. Deliberately *not* on the phase-1 path:
upstream releases are signed and checksummed and ours would not be yet, so
shipping our own build first would trade a real supply-chain guarantee for a
size win. Swapping later is two variables: `otel_agent_dist`,
`otel_agent_install_path`.

---

## D-7 — Drop the `httpcheck` receiver; fold endpoint liveness into the collector script

**Decision:** no `httpcheck` receiver. `jmdn_endpoint_up` and
`jmdn_endpoint_response_seconds` come from the health collector.

**Why:** the collector script already curls those exact endpoints to get block
height and version. Emitting up/latency from the same responses costs nothing,
removes a receiver, removes a second set of HTTP requests against a node that
may be struggling, and shortens the `ocb` manifest for D-6a.

---

## D-8 — Identity as metric datapoint attributes, not OTLP resource attributes

**Decision:** `server`, `operator_id`, `node_role` and `chain_id` are attached
as scrape labels **and** re-asserted by an `attributes/identity` processor on
the metrics pipeline. The `resource/identity` processor is used only for logs
and traces.

**Why:** on the hub, OTLP resource attributes become labels on a separate
`target_info` series — only `job`/`instance` are promoted onto the metrics
themselves. Identity carried only in the resource would yield series with **no
`server` label**, and every existing dashboard panel filters on `server`. This
is the single most likely way to build the whole pipeline and end up with data
that no dashboard can display.

Logs and traces are the opposite case: Loki and Tempo index on resource
attributes, so that is the right home there.

**Server-side note:** these labels are client-supplied and therefore
untrusted. The hub must overwrite `operator_id` from the authenticated bearer
identity (`X-JMDT-Client-ID`) rather than accept it.

---

## D-9 — One egress path, one credential

**Decision:** jmdn's own OTLP logs and traces are sent to the **local agent** on
loopback, which forwards them alongside metrics.

**Why:** one credential to issue, rotate and revoke per operator; one firewall
rule; one endpoint to document; and — the reason that actually matters — one
**disk-backed queue**, so logs and traces survive a gateway outage instead of
being dropped in memory.

**Escape hatch:** `telemetry.forward_node_logs: false` leaves jmdn's own logging
configuration untouched, so you can point it wherever you prefer — including
your own collector, or nowhere at all.

---

## D-10 — Every listener on loopback; nothing inbound

`node_exporter` → `127.0.0.1:9100`. Agent OTLP receiver → `127.0.0.1:4317/4318`.
Agent self-telemetry → `127.0.0.1:8888`. jmdn app metrics → `127.0.0.1:<port>`.

Binding any of these to `0.0.0.0` is only safe behind a firewall you fully
control, and an exposed `node_exporter` is a well-understood information
disclosure — it publishes your kernel version, filesystem layout, network
interfaces and uptime to anyone who asks. Nothing in this kit needs to be
reachable from off-box, so nothing is.

Telemetry leaves via **one outbound HTTPS connection**, which also means the kit
works behind NAT, CGNAT and dynamic IPs with no inbound firewall change. The only
inbound port you open on this machine is the one your node needs for P2P.

---

## D-11 — The token exists in exactly one place

`/etc/otelcol/otelcol.env`, mode `0640` root:otelcol, referenced from the config
as `${env:JMDT_OTEL_TOKEN}`. Never in `config.yaml`, never in `ExecStart` (so
never in `ps`), and every Ansible task that touches it sets `no_log: true` —
including the preflight assertion that checks it is not a placeholder.

---

## D-12 — Nothing is installed without a verified checksum

Both binaries are installed by fetching the release's **own** published
checksum file (`sha256sums.txt` / `<dist>_<ver>_checksums.txt`), extracting the
digest for the exact artifact, and passing it to `get_url`'s `checksum:`. If no
digest is found the play **fails rather than installing** — no digests are
hardcoded in this repo, so a version bump cannot silently skip verification.

---

## D-13 — Validate before activate, at every layer

| Layer | Gate |
|---|---|
| collector shell script | `copy` with `validate: sh -n %s` — Ansible validates the temp file and only then moves it into place, so a syntax error cannot reach the running system |
| node_exporter flag set | the flags are run against the **real binary** with a 3s timeout before the unit is written; kingpin rejects unknown flags on parse, so this catches a version-removed flag before it becomes a service that will not start |
| agent config | rendered to a staging path, checked with the collector's own `validate` subcommand, then promoted |
| systemd units | `systemd-analyze verify` in the render gate (see below) |
| whole node | `verify.yml`, read-only, non-zero exit |

---

## D-14 — Idempotency

Both binary installs are **version-aware**, not presence-aware: the install
block runs only when the installed `--version` differs from the pinned one, so
a re-run is a no-op rather than a re-download. Config and unit files are
templates with change-triggered handlers, so nothing restarts unless content
actually changed. `preflight` only asserts — it never mutates, so it is safe
under `--check`. Read-only probe tasks carry `check_mode: false` so `--check`
reports truthfully instead of skipping them and guessing.

---

## D-15 — 30-second scrape, 10-second batch

Half the collection rate Jupiter Meta uses on its own nodes. It halves the volume
leaving your machine with no meaningful loss of fidelity for VM health, and keeps
a node at roughly 6 export requests per minute per signal — comfortably inside
the gateway's per-client rate limit even if you run several nodes on one token.

If you run enough nodes on a single token to approach that limit, ask for a token
per node rather than raising the interval.

---

## D-16 — Self-checks that fail loudly

Silent partial failure is the enemy of remote observability. Three checks exist
purely to make failures loud:

1. After starting node_exporter, the role scrapes its own `/metrics` and
   **fails the play** if `node_systemd_unit_state` is absent (catches the
   AF_UNIX / read-only-`/run` trap in D-4).
2. After the first collector run, the role **fails the play** if no textfile
   was produced.
3. `verify.yml` asserts textfile freshness against the collector interval, and
   asserts the agent's `otelcol_exporter_sent_metric_points` counter is
   non-zero — the operator's own evidence that we are receiving their data.

---

## D-17 — Control-side posture

`host_key_checking = True`. Disabling it is common and defensible for playbooks
that only ever run against `localhost`, but this kit is a distributed artifact
and may be run across a network, where the check is what stops a substituted
host from being accepted silently.

No Ansible Vault — you edit one plain file, `operator.yml`, which is gitignored so
your token cannot be committed by accident.

**Zero Galaxy collections.** Every module used is `ansible.builtin`, so
`ansible-core` is the entire control-side dependency. That keeps the install path
short and the whole kit auditable by reading it.

---

## D-18 — Stop journald dropping logs under load

**Decision:** `observability.yml` installs a journald drop-in. The operator runs
no extra command.

**Why this is in scope for a telemetry kit:** this kit forwards your node's logs.
A journald rate limit truncates the local copy and the forwarded copy at the same
instant, so log retention is not somebody else's problem here.

**The setting that matters is the rate limit, not the size.** journald discards
messages beyond `RateLimitBurst` per `RateLimitIntervalSec` **per service**,
recording only "Suppressed N messages". The default is 10,000/30s ≈ 333/s. A
validator at idle was measured at ~2,200 lines/hour from `jmdn` alone (~18 per
30s), so the default looks generous — but the moment that matters is a
block-processing burst, and losing *new* logs during an incident is worse than
losing old ones. Raised to 100,000/30s ≈ 3,300/s: ~180x measured idle,
deliberately finite rather than `0`, so a pathological log loop still cannot
saturate disk I/O.

**Total journal size is not ours to set.** jmdn's own
`Scripts/install_services.sh:83` already writes a second drop-in,
`/etc/systemd/journald.conf.d/jmdn-limits.conf`, containing
`SystemMaxUse=5G` and `MaxRetentionSec=30d`. systemd merges drop-ins in
**lexical filename order** and the last assignment of a key wins, so
`jmdn-limits.conf` beats `10-jmdn-validator.conf` — and beats a `99-` prefix too,
since every digit sorts before every letter.

The first version of this role set `SystemMaxUse=2G` anyway. On a live node
journald reported `max 5G`: jmdn's value won, the role's own summary line printed
"capped at 2G", and the assertion passed because it only checked that our
*filename* appeared in `cat-config`. Presence is not effect.

The fix is not a rename. Winning a fight over a key another component
deliberately sets is still two components fighting; 5 GB with 30-day retention on
the 100 GB disk this runbook specifies is not a problem worth having. So this role
sets only directives nothing else on a JMDN node sets, and **asserts the effective
value** of each — resolving the merge the way systemd does rather than checking
for its own filename.

**Deliberately not set, each for its own reason:**

| Directive | Why not |
|---|---|
| `SystemMaxUse`, `MaxRetentionSec` | `jmdn-limits.conf` owns them and wins on filename order |
| `SystemKeepFree` | journald's parser **rejects a percentage**: `Failed to parse SystemKeepFree=15%, ignoring: Invalid argument`, observed on Ubuntu 26.04. The man page states the *default* as 15% of the filesystem, which is the behaviour wanted, so not setting it beats hard-coding a size that cannot scale |
| `ForwardToSyslog` | a drop-in sorting after ours sets `yes` on a stock node. The earlier claim here — that `/var/log/syslog` is "the only unbounded path" — was never verified, and Ubuntu ships logrotate for rsyslog. Fighting an unidentified component over a key, on a claim that was not checked, is not a trade worth making |
| `Compress`, `SyncIntervalSec` | already the defaults; restating one creates a value that can drift out of sync with systemd |
| `MaxFileSec` | `SystemMaxFileSize` is sufficient — one rotation trigger is easier to reason about than two |

**A drop-in, not a replacement for `journald.conf`.** The operator's machine is
theirs: overwriting the distro file would discard their settings and be reverted
by a package upgrade. `rm` the drop-in and restart journald to revert completely.

**Verified by three checks, each covering a way the previous one failed:**

1. **journald accepted every line.** After the restart, its own messages are read
   back filtered on its *current* `MainPID` and asserted free of `Failed to parse`
   and `Unknown key name`. A rejected directive is otherwise invisible — the file
   is correct on disk, `cat-config` shows the line, the service is active, and the
   value simply never applies. This is what `SystemKeepFree=15%` did.
2. **Our value is the winning value.** `cat-config` is reduced to one assignment
   per key, last-wins, and compared against `journald_directives`. This is what
   catches an override by a later drop-in.
3. **`verify.yml` re-runs both** on every invocation, plus reports any "Suppressed
   N messages" entries from the last 24 hours — the only evidence journald leaves
   when it discards logs.

`tests/doc_claims.py` closes the loop statically: it asserts the assertion map
matches the directives the template actually writes, that the role defaults mirror
`group_vars`, and that each of the four deliberate absences is still absent.
