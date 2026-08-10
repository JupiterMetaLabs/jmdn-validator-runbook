# Running a JMDN Validator Node

Complete procedure for a fresh machine: install and run a JMDN node, then report
its health to Jupiter Meta over a single outbound connection.

Every step states the command, what you should see, and what to do if you see
something else.

| Stage | What it does | Time |
|---|---|---|
| [Stage 0](#stage-0--before-you-start) | Prerequisites and firewall. Read this first. | 10 min |
| [Stage 1](#stage-1--install-and-run-the-node) | Install and run jmdn | 30–60 min |
| [Stage 2](#stage-2--install-health-reporting) | Install health reporting | 5 min |
| [Stage 3](#stage-3--verify) | Verify the whole thing | 5 min |

**Already running a JMDN node?** Skip to [Stage 2](#stage-2--install-health-reporting).

---

## What gets installed

Two long-running services and one timer, on top of the node itself.

| Unit | Purpose | Listens on | Resource cap |
|---|---|---|---|
| `jmdn`, `immudb`, `redis-server` | the node | per your `jmdn.yaml` | — |
| `node_exporter` | host metrics, service state, chain health | `127.0.0.1:9100` | 80 MB / 10% of a core |
| `otelcol-contrib` | sends telemetry to Jupiter Meta | `127.0.0.1` only | 256 MB / 20% of a core |
| `jmdn-health.timer` | 30-second health check | nothing | no resident memory |

`observability.yml` also bounds your system journal, because five services log to
it and the distro default **discards** messages beyond 10,000 per 30 seconds per
service — silently truncating logs during exactly the bursts you would want to
read. Details in [docs/DESIGN.md](docs/DESIGN.md); nothing for you to run.

Measured across two 2 vCPU installs: node_exporter **8.6–9.0 MB**, the agent
**36–41 MB**. The caps are 6–9× that, sized so a leak can never compete with
your node for resources.

**No Prometheus, Grafana, Loki or Alertmanager is installed.** Nothing listens on
a public interface. Telemetry leaves over **one outbound HTTPS connection**, so
this works behind NAT, CGNAT or a dynamic IP with no inbound firewall change.

**What we can see** is listed exhaustively in [TELEMETRY.md](TELEMETRY.md). In
short: standard host metrics, the run state of a few systemd units, block height,
and whether your local endpoints answer. We receive no keys, no configuration
files, no transaction contents, and we have no access to your machine.

Setting `telemetry.enabled: false` installs the local exporters and sends
nothing — the metrics stay available to you at `curl -s localhost:9100/metrics`.

---

# Stage 0 — before you start

## 0.1 Machine

| Requirement | Minimum |
|---|---|
| vCPU | 2 |
| RAM | 8 GB |
| Disk | **100 GB SSD** |
| OS | Ubuntu 24.04 LTS recommended; 22.04+ or Debian 12 also supported, with systemd |
| Architecture | x86_64 or aarch64 |

Check what you have:

```bash
nproc && free -g && df -h /opt / && lsblk
```

**The disk figure is not padding.** The chain snapshot is ~16 GiB compressed, and
the bootstrap keeps the downloaded parts and the extracted data under `/opt/jmdn`
at the same time. Expect a **peak of 40–60 GB** during setup. If you have less
than 60 GB free on the filesystem holding `/opt`, see [1.7](#17-bootstrap-from-the-chain-snapshot)
for the alternative.

## 0.2 Inbound firewall — required

These four are the only ports that should be reachable from the internet:

| Port | Protocol | Source | Why |
|---|---|---|---|
| **15000** | **TCP *and* UDP** | `0.0.0.0/0` | P2P gossip, block propagation, peer discovery. **A node that cannot receive inbound traffic on this port cannot participate in the network.** |
| 15001 | TCP | `0.0.0.0/0` | Yggdrasil direct messaging. Bare metal only, optional |
| 8545 | TCP | `0.0.0.0/0` | JSON-RPC |
| 8546 | TCP | `0.0.0.0/0` | WebSocket |

**Both protocols on 15000.** A TCP-only rule looks correct and leaves QUIC dead —
this is the single most common setup mistake.

### Everything else is internal

Every other listener is either disabled or bound to `127.0.0.1`, and needs no
firewall rule at all. You should not need to enable or expose any of them, and
doing so is very unlikely to be the right answer — if you think you need one, ask
us first.

This is what `jmdn_validator.yaml` — the config you install in
[1.6](#16-configure-the-node) — sets for you:

| Listener | Port | In `jmdn_validator.yaml` |
|---|---|---|
| Explorer API | 8090 | enabled, `127.0.0.1` |
| Metrics | 8081 | enabled, `127.0.0.1` — the telemetry agent scrapes this |
| DID service | 15052 | **disabled** — not used by a validator |
| Profiler | 6060 | **disabled** |
| Admin CLI | 15053 | **disabled**, `127.0.0.1` |
| Block generation | 15050 | **disabled**, `127.0.0.1` |
| Block gRPC | 15055 | **disabled**, `127.0.0.1` |

**Do not use the config templates in the jmdn repository.** Both enable the DID
service and bind it to `0.0.0.0`, and `jmdn_exchange.yaml` also binds the
Explorer API there. `jmdn_validator.yaml` disables DID outright and keeps the
Explorer API on loopback. Stage 3 fails if either is left open, whichever file
you started from.

### ImmuDB opens four more ports, on all interfaces

Your node's database is started as `immudb --dir /opt/jmdn/data` with no other
flags, so ImmuDB's own defaults apply. It binds **all interfaces**:

| Port | What it is |
|---|---|
| **8080** | web console, Swagger UI and web API |
| 9497 | metrics |
| 5432 | PostgreSQL wire protocol |
| 3322 | gRPC — how jmdn itself talks to it |

**None of these may be reachable from the internet.** ImmuDB runs with its
built-in `immudb/immudb` credentials, so an exposed 8080 is a web console into
your chain database for anyone who finds it.

[1.5](#confine-immudb-to-loopback--do-this-before-starting-it) switches off the
three jmdn does not use and confines the rest to loopback, so after that step
only `127.0.0.1:3322` remains. Keep them closed in your firewall or security
group regardless — that is the point of having more than one control.

The admin surfaces — `cli`, `blockgen`, `blockgrpc` — plus DID and the profiler
are disabled and loopback-bound. Leave them that way. If you ever enable the CLI, keep
`binds.cli: 127.0.0.1` and reach it over an SSH tunnel; never expose it, and
never rely on a firewall rule alone to protect it.

### If you are not serving public RPC, close 8545 and 8546 too

8545 and 8546 are public by default because JMDN nodes are expected to serve
JSON-RPC. A validator that does **not** need to serve it is safer with both bound
to loopback: public unauthenticated RPC costs nothing to hammer, discloses node
state, and competes with consensus for CPU on a 2 vCPU machine. Nothing in this
runbook needs them public — the health collector reads them on `127.0.0.1`.

To harden, set `binds.facade` and `binds.ws` to `127.0.0.1` in
[1.6](#16-configure-the-node), then tell Stage 3 to enforce it:

```bash
sudo ansible-playbook verify.yml -e '{"verify_public_listeners":[]}'
```

If you do serve public RPC, put a rate-limiting reverse proxy in front of it.

## 0.3 Outbound access

| Destination | Why |
|---|---|
| the seed node host you were given | peer discovery |
| the mempool host you were given | transaction routing |
| `storage.googleapis.com:443` | chain snapshot |
| `github.com:443`, `objects.githubusercontent.com:443` | source and binaries |
| `otel.jmdt.io:443` | health reporting |
| your distribution's apt archives | packages |

No inbound rules are needed for any of these.

## 0.4 From Jupiter Meta

None of these are published. Jupiter Meta supplies all of them when you are
onboarded, and you cannot complete the runbook without them:

| What | Used in | Why it cannot be guessed |
|---|---|---|
| **operator ID** and **telemetry token** (64 hex) | [0.5](#05-get-this-runbook-onto-the-machine) | the token authenticates your node to the gateway |
| **seed node** host and port | [1.6](#16-configure-the-node) | peer discovery and the committee snapshot |
| **mempool** host and port | [1.6](#16-configure-the-node) | transaction routing |
| **chain snapshot prefix** and its **tip block number** | [1.7](#17-bootstrap-from-the-chain-snapshot), [1.8](#18-confirm-the-catch-up-block) | a tip from the wrong snapshot makes your node skip blocks **silently** |

Ask for anything you are missing before you start. The snapshot tip is the one
that fails quietly — every other missing value produces an obvious error.

## 0.5 Get this runbook onto the machine

**Required, not optional.** Stage 1.6 installs a config file from this
repository, and Stage 2 runs its playbooks.

```bash
sudo apt-get update && sudo apt-get install -y git

# /opt is owned by root, so create the directory and take ownership first.
# Everything after this — editing operator.yml, git pull — then works without
# sudo, and git will not complain about "dubious ownership".
sudo mkdir -p /opt/jmdn-validator-runbook
sudo chown "$(id -un):$(id -gn)" /opt/jmdn-validator-runbook

git clone https://github.com/JupiterMetaLabs/jmdn-validator-runbook.git /opt/jmdn-validator-runbook
cd /opt/jmdn-validator-runbook

sudo ./install-deps.sh

cp operator.yml.example operator.yml
chmod 600 operator.yml          # it will hold your telemetry token
${EDITOR:-nano} operator.yml
```

Set **three fields and nothing else**:

```yaml
operator_id: "acme-capital"       # as issued by Jupiter Meta — the same identity
                                  #   your telemetry token was issued against
network: mainnet

telemetry:
  token: "<the token we issued you>"
```

**Leave `node_id: "auto"` alone.** Your node's name is taken from `node.alias` in
`/etc/jmdn/jmdn.yaml`, which you set once in [1.6](#16-configure-the-node). One
place to name a node, nothing to keep in sync.

Set `node_id` explicitly only if this machine will never run jmdn — a
telemetry-only host has no `node.alias` to derive from.

Everything else in the file is already correct if you follow this runbook — the
endpoint ports match the config you install in
[1.6](#16-configure-the-node). You revisit the file once more in
[2.2](#22-check-operatoryml-against-your-node), only to confirm.

Only `install-deps.sh` and the two playbooks in Stage 2 need `sudo`. If you
cloned with `sudo git clone` instead, the tree ends up root-owned and the `cp`
above fails — fix it with
`sudo chown -R "$(id -un):$(id -gn)" /opt/jmdn-validator-runbook`.

`install-deps.sh` installs `ansible-core` (for the playbooks) plus `curl`, `jq`
and `iproute2`, which the health collector and Stage 3 use at runtime. No Ansible
Galaxy collections are needed. It starts nothing and touches no jmdn state.

This is unrelated to jmdn's `Scripts/bootstrap_sync.sh` in
[1.7](#17-bootstrap-from-the-chain-snapshot), which downloads the chain snapshot.

### Then run the pre-flight check

Read-only, changes nothing, needs no privileges. Do this before you commit to an
install:

```bash
ansible-playbook preflight.yml
```

It verifies your OS, architecture, disk, clock, base tools, and that every
outbound destination above is reachable. It refuses to change anything.

**Two notes here are expected on a fresh machine**, because jmdn does not exist
yet: the node name cannot be resolved from `node.alias`, and preflight's probe of
jmdn's metrics port prints `WARNING: ... nothing is serving /metrics there`. That is correct at this point — it becomes a real
signal only if you still see it after Stage 1. It is a warning, not a failure;
`failed=0` is what matters.

---

# Stage 1 — install and run the node

Follows `GETTING_STARTED.md` in the jmdn repository, with the mainnet values
filled in.

## 1.1 Base tools

```bash
sudo apt-get update && sudo apt-get install -y git curl build-essential
```

`build-essential` is required — the node is built with CGO and needs gcc.

## 1.2 Get the source at a pinned release

```bash
git clone https://github.com/JupiterMetaLabs/jmdn.git /opt/jmdn-src
cd /opt/jmdn-src
git tag --sort=-v:refname | head -5      # newest first
git checkout v2.0.1
```

**v2.0.1** is the current release. The `git tag` line above lists what is actually
available — if it shows something newer, take the newest tag rather than this one,
and tell us so we can update this runbook.

**Pin a tag.** Do not track `main` on a node you intend to keep running: you would
be deploying whatever was merged most recently, on a machine participating in
consensus.

Verify you are where you think you are:

```bash
git describe --tags
```

## 1.3 Dependencies

```bash
sudo ./Scripts/setup_dependencies.sh --all
```

Installs Go, ImmuDB, Yggdrasil and Redis. Takes several minutes.

It also generates a random Redis password into `/etc/jmdn/redis.env` (root-only)
on first run and reuses it afterwards. The service wrapper reads it
automatically — **you never set a Redis password by hand.**

```bash
export PATH="/usr/local/go/bin:$PATH"     # or: source ~/.bashrc
go version && gcc --version | head -1
systemctl is-active redis-server
```

## 1.4 Build

```bash
./Scripts/build.sh
./jmdn --version
```

## 1.5 Install services

```bash
sudo ./Scripts/install_services.sh
```

Installs the binary to `/usr/local/bin`, creates `/opt/jmdn` and `/var/log/jmdn`,
and registers the `immudb` and `jmdn` systemd units. Both run as root, which is
the upstream default.

Confirm both units registered:

```bash
systemctl list-unit-files | grep -E '^(jmdn|immudb)'
```

### Confine ImmuDB to loopback — do this before starting it

ImmuDB serves four listeners on `0.0.0.0` by default: **8080** (web console,
Swagger, web API), **9497** (metrics), **5432** (PostgreSQL wire) and **3322**
(gRPC). It runs with the built-in `immudb/immudb` credentials, and
`install_services.sh` passes no bind flags, so all four are open on every
interface.

**jmdn only ever uses 3322, over loopback.** Nothing needs the other three.

```bash
sudo mkdir -p /etc/systemd/system/immudb.service.d
sudo tee /etc/systemd/system/immudb.service.d/10-loopback-only.conf >/dev/null <<'EOF'
# Confine ImmuDB. jmdn uses only gRPC 3322 over loopback; the web console,
# pgsql wire and Prometheus servers are pure attack surface on a validator.
[Service]
# ExecStart= clears the unit's original line — without it, systemd appends.
ExecStart=
ExecStart=/usr/local/bin/immudb --dir /opt/jmdn/data --address 127.0.0.1 --web-server=false --pgsql-server=false --metrics-server=false

# Independent second layer, enforced by the kernel. Survives a dropped flag, an
# ImmuDB upgrade, or a re-run of install_services.sh.
IPAddressAllow=localhost
IPAddressDeny=any
EOF
sudo systemctl daemon-reload
```

Three controls, deliberately overlapping:

| Control | Effect |
|---|---|
| `--web-server=false --pgsql-server=false --metrics-server=false` | those three servers never start. A server that does not exist cannot be misconfigured |
| `--address 127.0.0.1` | the remaining gRPC listener binds loopback only |
| `IPAddressAllow` / `IPAddressDeny` | kernel-level and unit-scoped. Holds even if a flag is dropped by a future release |

The kernel layer cannot affect SSH, P2P or anything else on the box — it applies
only to this unit's cgroup — and it holds even if a firewall rule or security
group is opened by mistake. Supported on every current Ubuntu and Debian release:
the directives have existed since systemd 235, and 22.04 ships 249 while 24.04
ships 255.

**Verify it actually filters — do not trust `systemctl show`.** If the kernel
cannot load the BPF program, systemd logs a warning and runs the service
*unfiltered*, while `systemctl show` still reports the directives as configured.
Test the behaviour instead:

```bash
sudo systemctl restart immudb        # NOT while bootstrap_sync.sh is running
systemctl show immudb -p IPAddressAllow -p IPAddressDeny
journalctl -u immudb -n 30 --no-pager | grep -iE 'bpf|ip address' || echo "no BPF warnings — good"

# only 127.0.0.1:3322 should remain — 8080, 9497 and 5432 should be gone entirely
sudo ss -tlnp | grep -E ':(3322|8080|9497|5432)' || echo "no ImmuDB port listening — did the service start?"

# off-loopback must FAIL, loopback must still WORK
PRIV=$(hostname -I | awk '{print $1}')
curl -sS --max-time 3 "http://$PRIV:8080" >/dev/null 2>&1 \
  && echo "*** NOT FILTERED — fall back to firewall rules, see below" \
  || echo "off-loopback blocked (expected)"
timeout 3 bash -c '</dev/tcp/127.0.0.1/3322' \
  && echo "loopback 3322 still reachable (required)" \
  || echo "*** loopback broken — jmdn cannot reach its database"
```

Both lines must read as expected. If the first says `NOT FILTERED`, BPF is
unavailable on your kernel and this layer is doing nothing — your security group
becomes the only control, so make certain 8080, 9497, 5432 and 3322 are closed
there, and consider a host firewall.

If you ever move ImmuDB to a separate host, remove this file — the node would
then need to reach it over a real network address.

## 1.6 Configure the node

Use the validator config **shipped with this runbook**, not the templates in the
jmdn repository:

```bash
sudo mkdir -p /etc/jmdn
sudo cp /opt/jmdn-validator-runbook/jmdn_validator.yaml /etc/jmdn/jmdn.yaml
sudo ${EDITOR:-nano} /etc/jmdn/jmdn.yaml
```

**Do not start from `jmdn_default.yaml`.** It is stale. `jmdn_exchange.yaml` is
current but Docker-shaped — it points the database at the container hostnames
`immudb` and `redis:6379`, which do not resolve on bare metal. `jmdn_validator.yaml`
is derived from the exchange template with bare-metal addresses, the correct
binds, and the two footguns described below already removed.

Fill in the `REQUIRED` fields:

```yaml
node:
  alias: "acme-validator-1"        # THIS is your node's name. Everything derives from it.

network:
  seednode: "<the seed node host we gave you>"
  mempool: "<the mempool host we gave you>"

logging:
  service_name: "acme-validator-1" # SAME value again — see below

fastsync:
  catch_up_from_block: 13450       # already set; confirm it in 1.8
```

**`node.alias` is this node's name everywhere.** Set it here and it flows out:

| Field | Where | How it is set |
|---|---|---|
| `node.alias` | `jmdn.yaml` | **you set this** — jmdn's logs and its seednode registration |
| `logging.service_name` | `jmdn.yaml` | **copy `node.alias`** — the `service.name` on logs and traces |
| `node_id` → `server` label | `operator.yml` | derived automatically from `node.alias`, because `node_id` is `"auto"` |

So two fields to type, both in this file, both the same string. `logging.service_name`
is easy to miss because it sits far below `node.alias` — Stage 3 warns you if they
disagree.

Once jmdn defaults `logging.service_name` to `node.alias`, this becomes one field.

Everything else is already set for a validator. The binds in particular:

| Listener | Bind | |
|---|---|---|
| `facade` 8545, `ws` 8546 | `0.0.0.0` | public JSON-RPC / WebSocket |
| `api` 8090, `metrics` 8081 | `127.0.0.1` | internal |
| `did`, `cli`, `blockgen`, `blockgrpc`, `profiler` | `127.0.0.1` | internal **and disabled** |

Two things this file fixes that you would otherwise hit:

- **DID is enabled and bound to `0.0.0.0` upstream.** A validator does not use
  the DID service, so this file disables it (`ports.did: 0`). Stage 3 fails if
  you leave it enabled and exposed.
- **`database.password: ""` is a bare-metal trap.** The Docker templates carry
  that line because Compose supplies the real value through the environment. On
  bare metal an explicit empty string *overrides* the password compiled into
  jmdn and breaks ImmuDB authentication. `jmdn_validator.yaml` omits the key
  instead, so the built-in default applies. Same for the Redis password, which
  `setup_dependencies.sh` already generated into `/etc/jmdn/redis.env`.

If you ever hand-write a config instead, write the **whole** `binds` block out
explicitly. The values compiled into jmdn and those in the YAML templates do not
agree for every key — `binds.api` is `0.0.0.0` in the binary and `127.0.0.1` in
the shipped file — so an omitted key can silently expose a listener.

`facade` and `ws` are public because JMDN nodes are expected to serve JSON-RPC.
If yours does not need to, close them —
see [0.2](#if-you-are-not-serving-public-rpc-close-8545-and-8546-too).

Leave `fastsync.enable_catchup: true`. It is what wires your node's committee
source; with it off your node accepts no block certificates and makes no
progress while still looking healthy.

**Nothing to set for consensus.** Your node learns the committee authority key
from the seed node on first contact and pins it to
`/opt/jmdn/config/seedAuth.json`. [1.10](#110-confirm-the-node-works) checks that
the pin was created.

### Generate the two Explorer API secrets

`jmdn_validator.yaml` enables the Explorer API on loopback (`ports.api: 8090`),
so these are **required**, not optional. You generate them yourself — they
protect *your* node's API, are never shared with Jupiter Meta, and the runbook
never transmits them:

```bash
openssl rand -hex 32     # -> security.explorer_api_key
openssl rand -hex 32     # -> security.jwt_secret
```

Put both into the `security` block of `/etc/jmdn/jmdn.yaml`. Keep a copy of
`explorer_api_key` — Stage 2.2 optionally uses it so the health collector can
report ImmuDB connectivity.

Prefer environment variables in production
(`JMDN_SECURITY_EXPLORER_API_KEY`, `JMDN_SECURITY_JWT_SECRET`); those outrank
the file.

**Or skip the Explorer API entirely:** set `ports.api: 0`, leave both secrets
empty, and set `explorer_port: 0` in `operator.yml`. Health checks then report
less detail — no version string, no ImmuDB connectivity — but everything else,
including block height, still works.

## 1.7 Bootstrap from the chain snapshot

Start the database first, so nothing is holding the data directory open:

```bash
sudo systemctl enable --now immudb
systemctl status immudb --no-pager
```

**Check what it opened**, before you spend half an hour on a download:

```bash
sudo ss -tlnp | awk 'NR==1 || $4 !~ /^(127\.0\.0\.1|\[::1\])/'
```

ImmuDB will appear on `0.0.0.0:8080`, `:9497`, `:5432` and `:3322` — that is its
default and jmdn does not change it. Those must not be reachable from outside;
see [0.2](#immudb-opens-four-more-ports-on-all-interfaces). Verify from another
machine:

```bash
# FROM ANOTHER MACHINE — set NODE_IP to this node's public address
NODE_IP=203.0.113.10
nc -vz "$NODE_IP" 8080 && echo "*** ImmuDB CONSOLE IS PUBLIC — close it now"
```

Then:

**First, confirm which snapshot you are about to download.** This is a two-second
check that can save you half an hour: `jmdn_validator.yaml` ships
`catch_up_from_block: 13450`, which is correct only for the
`bootstrap-26072026` snapshot (chain tip 13449).

```bash
grep -E 'GCS_BUCKET=|GCS_PREFIX=|chain tip' ./Scripts/bootstrap_sync.sh
```

Expect `jmdn-bootstrap`, `bootstrap-26072026`, tip `13449`. If the prefix differs,
your checkout fetches a different snapshot and you must set
`catch_up_from_block` to *that* snapshot's tip plus one in
[1.8](#18-confirm-the-catch-up-block). Getting this wrong makes the node skip
blocks silently.

Then download:

```bash
df -h /opt                       # note the starting figure
sudo bash ./Scripts/bootstrap_sync.sh
```

Downloads and verifies the chain snapshot over plain HTTPS — no credentials
required. **10–30 minutes** depending on your bandwidth. Safe to re-run: it exits
immediately if the data has already been bootstrapped.

Watch disk in a second terminal while it runs:

```bash
watch -n 30 'df -h /opt; du -sh /opt/jmdn/bootstrap_tmp /opt/jmdn/data_tmp 2>/dev/null'
```

**If you have less than 60 GB free**, skip the snapshot and let the node build
its own history from the first block instead. Set `catch_up_from_block: 0` in
`1.8` and leave it. The node will take considerably longer to become current, and
this is not recommended for a node you intend to keep, but it works and needs
almost no disk.

To force a fresh snapshot later:

```bash
sudo rm /opt/jmdn/data/.bootstrapped && sudo bash ./Scripts/bootstrap_sync.sh
```

## 1.8 Confirm the catch-up block

**Get this wrong and your node silently skips blocks — no error appears
anywhere.** It must be the tip block of the snapshot you actually downloaded,
**plus one**.

You already checked the *intended* snapshot in [1.7](#17-bootstrap-from-the-chain-snapshot).
This confirms what you **actually got**, which is the part that matters.

`bootstrap_sync.sh` printed the snapshot it extracted, for example:

```
[bootstrap] Data root found: /opt/jmdn/data_tmp/sandbox/data-snapshot-20260726_133519
```

That date identifies the snapshot. For `20260726` the tip is `13449`, so
`catch_up_from_block` must be `13450` — the shipped value.

```bash
grep -A1 catch_up_from_block /etc/jmdn/jmdn.yaml
```

If your snapshot directory carries a different date, set `catch_up_from_block` to
that snapshot's tip plus one instead:

```bash
sudo ${EDITOR:-nano} /etc/jmdn/jmdn.yaml
```

If you skipped the snapshot in 1.7, set it to `0` instead.

## 1.9 Start the node

```bash
sudo systemctl enable --now jmdn
journalctl -u jmdn -f
```

A healthy node logs peer connections and block synchronisation within seconds of
starting.

## 1.10 Confirm the node works

```bash
systemctl status jmdn immudb --no-pager

# block height — run twice, 30 seconds apart. It must increase.
curl -s -X POST http://127.0.0.1:8545 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'

# peers
curl -s localhost:8081/metrics | grep -E '^p2p_(connected|active|managed)_peers_total'

# inbound P2P — RUN THESE FROM A DIFFERENT MACHINE, not this one.
# Set NODE_IP to this node's public address first.
NODE_IP=203.0.113.10
nc -vz  "$NODE_IP" 15000     # TCP — must succeed
nc -vzu "$NODE_IP" 15000     # UDP — weak evidence, see note below

# the committee trust anchor was established (absent = certificates cannot verify)
sudo test -s /opt/jmdn/config/seedAuth.json && echo "authority key pinned" || \
  journalctl -u jmdn | grep -i '\[Committee\]'
```

That last check is worth doing even though nothing else will complain about it.
If the authority key never gets established, your node keeps running and keeps
rejecting certificates — it looks alive while making no progress.

**If height does not advance, or you have no peers, check inbound 15000 first**
(both TCP and UDP). That is the cause the overwhelming majority of the time.

UDP has no handshake, so `nc -vzu` reporting success is weak evidence — a
filtered port can still look open. The authoritative signal is a non-zero peer
count with an advancing height. **If TCP 15000 succeeds but you have no peers,
suspect a missing UDP rule** — a TCP-only firewall entry looks correct and leaves
QUIC dead.

### Confirm nothing is exposed that you did not intend

This is the check for the `binds` edits in [1.6](#16-configure-the-node). Only
P2P should be listening on a non-loopback address:

```bash
sudo ss -tlnp | awk 'NR==1 || ($4 !~ /^(127\.0\.0\.1|\[::1\])/)'
```

Every row other than P2P (`15000`, and `15001` if you enabled Yggdrasil) means
something is reachable from the internet. If `8545`, `8546` or `15052` appear
here, the `binds` edits did not take effect — check for a stray
`-facade`/`-ws` command-line flag in the service unit, which overrides the
config file, then `sudo systemctl restart jmdn`.

Verify from outside as well, because a permissive host firewall and a cloud
security group are two different things:

```bash
# FROM ANOTHER MACHINE — set NODE_IP to this node's public address
NODE_IP=203.0.113.10
nc -vz "$NODE_IP" 8545 && echo "*** JSON-RPC IS PUBLIC — fix before continuing"
```

---

# Stage 2 — install health reporting

## 2.1 Go to the repository

Stage 1 left you in `/opt/jmdn-src`. **Every command from here runs from the
runbook repository instead:**

```bash
cd /opt/jmdn-validator-runbook
```

**This is not cosmetic.** Ansible looks for `ansible.cfg` — which is what points
it at `inventory.ini` — in the directory you run from, **not** the directory the
playbook lives in. Run a playbook by absolute path from somewhere else and you
get:

```
[WARNING]: No inventory was parsed, only implicit localhost is available
[WARNING]: Could not match supplied host pattern, ignoring: operator_node
skipping: no hosts matched
```

…and an exit code of **0**. Nothing installed, no error. The playbooks now refuse
to run in that state rather than doing nothing quietly, but the fix is simply to
`cd` here first.

**Already cloned it in [0.5](#05-get-this-runbook-onto-the-machine)?** Then that
`cd` is all you need — skip the rest of this section.

**Coming straight to Stage 2 because jmdn already runs on this machine?** Do the
clone now:

```bash
sudo apt-get update && sudo apt-get install -y git
sudo mkdir -p /opt/jmdn-validator-runbook
sudo chown "$(id -un):$(id -gn)" /opt/jmdn-validator-runbook
git clone https://github.com/JupiterMetaLabs/jmdn-validator-runbook.git /opt/jmdn-validator-runbook
cd /opt/jmdn-validator-runbook
sudo ./install-deps.sh
cp operator.yml.example operator.yml && chmod 600 operator.yml
${EDITOR:-nano} operator.yml
```

`install-deps.sh` installs `ansible-core`, `curl`, `jq` and `iproute2`. Nothing else is needed —
this kit requires no Ansible collections.

## 2.2 Check `operator.yml` against your node

You already set the four identity fields in
[0.5](#05-get-this-runbook-onto-the-machine). This is a **confirmation step**, not
a second round of configuration — if you installed `jmdn_validator.yaml` in
[1.6](#16-configure-the-node) unchanged, the ports already agree and there is
nothing to edit.

Confirm what your node actually serves — from `/opt/jmdn-validator-runbook`, so
the last command finds your `operator.yml`:

```bash
grep -A12 '^ports:' /etc/jmdn/jmdn.yaml
ss -tlnp | grep -E '8090|8545|8081'
grep -E 'explorer_port|facade_port|metrics_port' /opt/jmdn-validator-runbook/operator.yml
```

Only these three are probed, and they must match:

| `operator.yml` | `/etc/jmdn/jmdn.yaml` | Default |
|---|---|---|
| `explorer_port` | `ports.api` | 8090 |
| `facade_port` | `ports.facade` | 8545 |
| `metrics_port` | `ports.metrics` | 8081 |

**WebSocket (8546) is deliberately absent**, even though your node serves it. The
health collector makes plain HTTP requests; a WebSocket endpoint needs a protocol
upgrade to answer meaningfully, and it carries no health signal the facade does
not already give us — block height and chain id both come from `ports.facade`.
Nothing is wrong if `ws: 8546` is enabled and unlisted here. Same for `did`,
`cli`, `blockgen`, `blockgrpc` and `profiler`.

`ss` should show `8090` and `8081` on `127.0.0.1`, and `8545` on `*` — the facade
is your one public listener, by design. See
[0.2](#if-you-are-not-serving-public-rpc-close-8545-and-8546-too) if you would
rather it were not.

Use `0` on the `operator.yml` side for any listener you chose not to enable.
Stage 3 reads your `jmdn.yaml` and fails if the two files disagree, so a mistake
here is caught rather than silently producing a permanently-down target.

**Only if you enabled the Explorer API** (`ports.api` non-zero) and want ImmuDB
connectivity reported, add the key you generated in
[1.6](#16-configure-the-node):

```yaml
explorer_api_key: "<the key from your jmdn.yaml>"
```

It is used for loopback calls only and is never transmitted. Leave it empty to
skip those two metrics.

## 2.3 Logs and traces — nothing to do

*No commands in this section — it explains a default so you know it is
deliberate.*

`jmdn_validator.yaml` ships `logging.otel.enabled: true` pointing at
`127.0.0.1:4317`, so your node's own logs and traces flow through the agent
alongside the metrics. Nothing to do, and no restart needed.

That is safe even though the agent did not exist when you started jmdn in 1.9 —
the OTLP exporter does not dial at startup, so a closed port costs background
retries and nothing more.

All three signal types therefore share one credential, one outbound connection,
and one on-disk buffer that survives a network outage.

To turn it off, set `telemetry.forward_node_logs: false` in `operator.yml` and
re-run `observability.yml`; the agent then stops accepting OTLP and you can set
`logging.otel.enabled: false` in `jmdn.yaml` at your next restart.

## 2.4 Install

```bash
cd /opt/jmdn-validator-runbook
sudo ansible-playbook observability.yml
```

**Expect `failed=0`**, roughly thirty tasks reporting `changed` on a first run,
and a `PLAY RECAP` naming `localhost`.

If instead you see `skipping: no hosts matched`, you are not in the repository —
see [2.1](#21-go-to-the-repository). The playbook now stops with an explanatory
error in that case rather than exiting 0 having done nothing.

Do not use `--check` on a first install — Ansible cannot simulate services that
do not exist yet. `--check --diff` becomes useful from the second run onward, to
preview changes.

Re-running is always safe. A second run with no configuration change reports
`changed=0`.

---

# Stage 3 — verify

```bash
sudo ansible-playbook verify.yml
```

Read-only. It changes nothing and is safe to run at any time, including during an
incident.

Expect `VERDICT: HEALTHY` and a summary like:

```
node          : your-node-name  (operator your-operator-id, chain 7000700)
jmdn          : running
immudb        : running
redis         : running
block height  : 13871 → 13873  ADVANCING
probes failed : 0
metrics age   : 12s
health timer  : active / enabled
exported      : 12920 points, 0 failures
VERDICT       : HEALTHY
```

What it checks, and why each matters:

| Check | Meaning |
|---|---|
| Telemetry units active | node_exporter and the agent are running |
| Health timer active and enabled | the 30-second health check will survive a reboot |
| jmdn / immudb running | your node is up |
| Required metrics present | including service state and chain health |
| No textfile errors | the health collector's output is readable |
| Metrics are fresh | stale metrics are worse than missing ones, so this is checked explicitly |
| Endpoints match your config | catches a mismatch between the two files |
| All endpoint probes succeeded | your node is answering locally |
| **Block height advancing** | your node is actually syncing — see below |
| **Telemetry reaching Jupiter Meta** | your data is arriving. This is your proof |

### The height check takes up to two minutes

It samples block height, then re-reads it every 10 seconds for up to **120
seconds** waiting for an increase. You will see lines like
`FAILED - RETRYING: ... (11 retries left)` during that window — **that is the
retry loop working, not a failure.**

If the height never moves, the outcome depends on your peer count, because flat
height alone cannot tell "caught up to the chain tip" from "stalled":

| Height | Peers | Result |
|---|---|---|
| advancing | any | passes |
| flat | non-zero | **passes**, with a NOTE — this is what sitting at the tip looks like |
| flat | zero | **fails** — neither syncing nor peered means not participating |

A flat height with healthy peers on a quiet chain is normal and expected. If you
want to skip the gate entirely, re-run with `-e verify_height_required=false`.

## Confirm locally

```bash
ss -tlnp | grep -E '9100|8888|4317'          # all must show 127.0.0.1
curl -s localhost:9100/metrics | grep -E '^jmdn_'
curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_(sent|send_failed)_metric_points'
systemctl show node_exporter otelcol-contrib -p MemoryCurrent
```

`send_failed` should be `0`. Memory should be far below the caps.

---

# Day-2 operations

```bash
# health at a glance
sudo ansible-playbook verify.yml

# what is this node reporting right now?
curl -s localhost:9100/metrics | grep -E '^(jmdn_|node_systemd_unit_state)'

# is telemetry being delivered?
curl -s localhost:8888/metrics | grep otelcol_exporter

# logs
journalctl -u jmdn -f
journalctl -u otelcol-contrib -n 50
journalctl -u jmdn-health.service -n 20

# rotate your telemetry token: edit operator.yml, then
sudo ansible-playbook observability.yml --tags agent

# take a kit update
cd /opt/jmdn-validator-runbook && git pull
sudo ansible-playbook observability.yml && sudo ansible-playbook verify.yml
```

`operator.yml` is excluded from version control, so your configuration and token
survive every update.

**Never edit files under `/opt/jmdn-validator-runbook` directly.** The next `git pull`
will either conflict or silently revert your change. If something needs to differ,
tell us — it probably needs fixing in the kit.

## Upgrading the node

```bash
cd /opt/jmdn-src
git fetch --tags
git tag --sort=-v:refname | head -5      # pick the tag you want

NEW_TAG=v2.0.2                           # set this to that tag
git checkout "$NEW_TAG" && git describe --tags
sudo ./Scripts/deploy.sh
```

`deploy.sh` builds the new binary, swaps it atomically, restarts the service, runs
health checks, and rolls back to the previous version automatically if the checks
fail.

## Removing health reporting

```bash
sudo systemctl disable --now otelcol-contrib jmdn-health.timer node_exporter
sudo rm -f /etc/systemd/system/{otelcol-contrib,node_exporter,jmdn-health}.service \
           /etc/systemd/system/jmdn-health.timer
sudo systemctl daemon-reload
sudo rm -rf /etc/otelcol /etc/jmdn-health /var/lib/otelcol /var/lib/jmdn-health \
            /var/lib/node_exporter
sudo rm -f /usr/local/bin/{node_exporter,otelcol-contrib,jmdn-health-collector}
sudo userdel node_exporter; sudo userdel otelcol; sudo userdel jmdn-health
```

Your node is untouched by this.

---

# Troubleshooting

| Symptom | Cause | Diagnose | Fix |
|---|---|---|---|
| No peers, height stuck | inbound 15000 blocked | from another host: `nc -vz <IP> 15000` **and** `nc -vzu <IP> 15000` | open 15000 **TCP and UDP** to `0.0.0.0/0` |
| `server state is older than the client one` | database state ahead of the client cache | — | `sudo systemctl restart immudb && sudo systemctl restart jmdn` |
| Disk fills during bootstrap | peak is 40–60 GB | `df -h /opt` | abort safely — parts are only removed at the end — then grow the disk or skip the snapshot |
| preflight: cannot reach `otel.jmdt.io` | outbound 443 blocked | `curl -v https://otel.jmdt.io/health` | allow outbound 443. No inbound rule is needed |
| preflight: binary sources unreachable | GitHub egress blocked | `curl -I https://objects.githubusercontent.com` | allow outbound 443 to github.com and objects.githubusercontent.com |
| verify: `exported 0 metric points` | token rejected, or egress blocked | `journalctl -u otelcol-contrib -n 80` | check your token; then the row above |
| verify: metrics are stale | the health collector stopped | `systemctl status jmdn-health.timer`; `journalctl -u jmdn-health.service -n 50` | this is checked explicitly because stale metrics look healthy |
| verify: endpoints do not match | `operator.yml` and `jmdn.yaml` disagree | the failure message prints both | make them match, re-run `observability.yml` |
| verify: `probe_failures > 0` | a configured port your node does not serve | `ss -tlnp \| grep -E '8090\|8545\|8081'` | set the unserved port to `0` |
| `node_systemd_unit_state` missing | the metrics collector cannot reach systemd | `journalctl -u node_exporter -n 50` | send us the output |
| Rate limited (`429`) in the agent log | too many nodes on one token | `journalctl -u otelcol-contrib \| grep 429` | ask us for a token per node |

---

# Getting help

Send us:

1. The full output of `sudo ansible-playbook verify.yml` — it is designed to be
   safe to share and contains no secrets.
2. `journalctl -u jmdn -n 200`
3. Your `node_id` and `operator_id`.

**Do not send `/etc/jmdn/jmdn.yaml`.** It contains your secrets. If we need
configuration details we will ask for specific fields.
