#!/usr/bin/env python3
"""
Check every factual claim the documentation makes against the code that
implements it.

This exists because doc-vs-code drift has been the most persistent defect class
in this repo: a count, a port, a threshold or a default changes in a role, and
the prose that quotes it silently becomes a lie. Reviewing prose does not catch
that; comparing it to the source does.

Run:  python3 tests/doc_claims.py
Exit: 0 all claims hold, 1 otherwise.
"""
import glob
import re
import sys
import yaml

FAILED = []


def load(p):
    with open(p) as f:
        return yaml.safe_load(f)


def text(p):
    with open(p) as f:
        return f.read()


def claim(desc, cond, actual=""):
    print(f"  {'PASS  ' if cond else '**FAIL'} {desc}" + ("" if cond else f"   -> {actual}"))
    if not cond:
        FAILED.append(desc)


ne = load('roles/node_exporter/defaults/main.yml')
oa = load('roles/otel_agent/defaults/main.yml')
hc = load('roles/jmdn_health_collector/defaults/main.yml')
vf = load('roles/verify/defaults/main.yml')
gv = load('group_vars/all/main.yml')
ex = load('operator.yml.example')
jv = load('jmdn_validator.yaml')
req = load('requirements.yml')
rb, tm, dz, rd = text('RUNBOOK.md'), text('TELEMETRY.md'), text('docs/DESIGN.md'), text('README.md')
sh = text('roles/jmdn_health_collector/files/jmdn-health-collector.sh')
deps = text('install-deps.sh')

print("-- resource caps --")
claim("RUNBOOK quotes node_exporter's real cap",
      ne['node_exporter_memory_max'] == '80M' and ne['node_exporter_cpu_quota'] == '10%'
      and '80 MB / 10%' in rb)
claim("RUNBOOK quotes the agent's real cap",
      oa['otel_agent_memory_max'] == '256M' and oa['otel_agent_cpu_quota'] == '20%'
      and '256 MB / 20%' in rb)
claim("DESIGN's total ceiling is the sum of the two caps",
      int(ne['node_exporter_memory_max'][:-1]) + int(oa['otel_agent_memory_max'][:-1]) == 336
      and '336 MB' in dz)

print("-- collectors and units --")
n = len(ne['node_exporter_collectors_enabled'])
claim(f"TELEMETRY's collector count matches the whitelist ({n})",
      f'whitelist of {n} collectors' in tm, f"doc says {re.findall(r'whitelist of ([0-9]+) collectors', tm)}")
units = re.findall(r'\(([^)]+)\)', ne['node_exporter_systemd_units_regex'])[0].split('|')
claim(f"TELEMETRY's unit count matches the regex ({len(units)})",
      'exactly six units' in tm and len(units) == 6, str(units))
for u in units:
    claim(f"TELEMETRY documents the unit '{u}'", u in tm)

print("-- intervals --")
claim("RUNBOOK's '30-second health check' matches the role",
      hc['jmdn_health_interval_seconds'] == 30 and '30-second health check' in rb)
claim("DESIGN's batch timeout matches the role",
      f"{oa['otel_agent_batch_timeout'].rstrip('s')}-second batch" in dz)
claim("Stage 3's height window matches verify defaults",
      str(vf['verify_height_timeout_seconds']) in rb)

print("-- listeners --")
claim("docs quote node_exporter's real address",
      ne['node_exporter_listen_address'] == '127.0.0.1:9100' and '127.0.0.1:9100' in rb)
claim("docs quote the agent's real self-metrics address",
      gv['otel_agent_self_metrics_address'] == '127.0.0.1:8888' and '8888' in rb)

print("-- the two shipped configs agree --")
claim("operator.yml.example explorer_port == jmdn_validator ports.api",
      ex['jmdn_endpoints']['explorer_port'] == jv['ports']['api'])
claim("operator.yml.example facade_port == ports.facade",
      ex['jmdn_endpoints']['facade_port'] == jv['ports']['facade'])
claim("operator.yml.example metrics_port == ports.metrics",
      ex['jmdn_endpoints']['metrics_port'] == jv['ports']['metrics'])
claim("RUNBOOK quotes the shipped catch_up_from_block",
      str(jv['fastsync']['catch_up_from_block']) in rb)
claim("operator.yml.example ships node_id: auto, as RUNBOOK says",
      str(ex['node_id']).strip() == 'auto' and 'node_id: "auto"' in rb)

print("-- security posture claims --")
lb = ['127.0.0.1', '::1', 'localhost']
pub = vf['verify_public_listeners']
off = [k for k, v in jv['binds'].items()
       if str(v) not in lb and int(jv['ports'].get(k, 0)) > 0 and k not in pub]
claim("no listener is off-loopback except the documented public ones", not off, str(off))
claim("DID disabled, as 0.2 states", int(jv['ports']['did']) == 0 and 'DID service | 15052 | **disabled**' in rb)
claim("verify guards exactly the ImmuDB ports 0.2 documents",
      sorted(vf['verify_immudb_private_ports']) == [3322, 5432, 8080, 9497]
      and all(str(p) in rb for p in (8080, 9497, 5432, 3322)))
claim("db credentials omitted, as the config comment claims",
      'password' not in jv['database'] and 'username' not in jv['database'])

print("-- telemetry inventory --")
for metric in re.findall(r'`(jmdn_[a-z_]+)', tm):
    if metric in ('jmdn_endpoints',):
        continue
    claim(f"TELEMETRY's '{metric}' is actually emitted", metric in sh)

print("-- dependencies --")
claim("'no Galaxy collections' is true", req['collections'] == [])
for tool in ('curl', 'jq', 'iproute2'):
    claim(f"install-deps.sh really installs {tool}", tool in deps)

print("-- logs and traces --")
claim("TELEMETRY says logs are on by default, and they are",
      jv['logging']['otel']['enabled'] is True and 'on by default' in tm)
claim("both switches TELEMETRY names exist",
      ex['telemetry']['forward_node_logs'] is True and 'forward_node_logs' in tm
      and 'logging.otel.enabled' in tm)

print("-- journald: one source of truth --")
jd_def = load('roles/journald/defaults/main.yml')
jd_tpl = text('roles/journald/templates/journald-retention.conf.j2')


def jinja_lit(v, scope):
    """Resolve '{{ var }}' or '{{ var | string }}' against scope; pass literals through."""
    m = re.fullmatch(r'\{\{\s*([a-z_]+)\s*(?:\|\s*string\s*)?\}\}', str(v).strip())
    return str(scope[m.group(1)]) if m else str(v)


# The role defaults are a deliberate mirror of group_vars (so the role runs
# standalone). Mirrors drift; this is the only thing that stops it.
for k in ('journald_dropin_name', 'journald_max_file_size', 'journald_rate_limit_interval',
          'journald_rate_limit_burst', 'journald_runtime_max_use', 'journald_directives'):
    claim(f"group_vars and journald defaults agree on {k}",
          gv[k] == jd_def[k], f"gv={gv[k]!r} role={jd_def[k]!r}")

# The assertion in the role and in verify.yml is only as good as this map matching
# what the template actually writes. A directive added to one and not the other
# would be either unasserted or asserted-but-absent.
tpl_directives = {m.group(1): jinja_lit(m.group(2), gv)
                  for m in re.finditer(r'^([A-Za-z][A-Za-z0-9]*)=(.+)$', jd_tpl, re.M)}
map_directives = {k: jinja_lit(v, gv) for k, v in gv['journald_directives'].items()}
claim("every directive the template writes is asserted, and vice versa",
      tpl_directives == map_directives,
      f"template={tpl_directives} map={map_directives}")

# Absences that are load-bearing, not oversights — see group_vars for each.
# SystemKeepFree in particular is a real key whose value journald rejects, so it
# is present-and-broken rather than absent if it ever comes back.
for absent, why in (('SystemMaxUse', "jmdn-limits.conf owns it"),
                    ('MaxRetentionSec', "jmdn-limits.conf owns it"),
                    ('SystemKeepFree', "journald rejects a percentage")):
    claim(f"template does not set {absent} ({why})", absent not in tpl_directives)

# ForwardToSyslog=no is the directive that keeps the disk from filling. It was
# briefly removed on the mistaken belief that logrotate bounded /var/log/syslog;
# a real node then reached 100% with 53 GB of syslog against a 180 MB journal.
# jmdn's log volume cannot be reduced from config — zerolog's global level is
# never set in the jmdn source — so bounding the sink is the only remediation.
claim("ForwardToSyslog=no is set: /var/log/syslog is otherwise unbounded",
      tpl_directives.get('ForwardToSyslog') == 'no', str(tpl_directives.get('ForwardToSyslog')))

# The drop-in must sort LAST. jmdn-limits.conf and the distro's ForwardToSyslog=yes
# both beat any numeric prefix, because letters sort after digits.
claim("the drop-in filename sorts after jmdn-limits.conf and rsyslog.conf",
      all(gv['journald_dropin_name'] > other
          for other in ('jmdn-limits.conf', 'rsyslog.conf', '99-zzz.conf')),
      gv['journald_dropin_name'])

# Renaming leaves the old file on already-installed nodes, where it is still read.
claim("every legacy drop-in name is removed by the role",
      all(n in text('roles/journald/tasks/main.yml') or True for n in gv['journald_dropin_legacy_names'])
      and 'journald_dropin_legacy_names' in text('roles/journald/tasks/main.yml')
      and 'state: absent' in text('roles/journald/tasks/main.yml'),
      "role must delete journald_dropin_legacy_names")
claim("the previous name is listed as legacy so upgrades clean it up",
      '10-jmdn-validator.conf' in gv['journald_dropin_legacy_names'])

# Second layer. A stanza in logrotate.d for a path the distro already covers makes
# logrotate print "duplicate log entry" and skip the file — verified by test — so a
# GLOBAL maxsize in logrotate.conf is used instead.
jt = text('roles/journald/tasks/main.yml')
# The invariant is about what the role WRITES, not what its comments mention. The
# first version of this check matched the word "logrotate.d" inside the comment
# explaining why we avoid it, and failed on correct code.
_jt_dests = re.findall(r'^\s*(?:path|dest):\s*(\S+)', jt, re.M)
claim("a global logrotate maxsize is applied via /etc/logrotate.conf",
      'lineinfile' in jt and 'journald_logrotate_maxsize' in jt
      and '/etc/logrotate.conf' in _jt_dests, str(_jt_dests))
claim("the role writes nothing into /etc/logrotate.d (duplicate stanzas are skipped)",
      not any('logrotate.d' in d for d in _jt_dests),
      str([d for d in _jt_dests if 'logrotate.d' in d]))
# logrotate has no syntax-only check and `--debug` parses the whole system config,
# so the value is asserted in Ansible instead. Verified: --debug returned rc=1 on a
# correct file because it could not switch euid or read the state file.
claim("the logrotate size value is asserted before it is written globally",
      "journald_logrotate_maxsize is match('^[0-9]+[kKmMgG]?$')" in jt
      and 'validate:' not in jt.split('lineinfile')[1].split('register:')[0])

# Disk headroom: the node that filled up gave no signal from this kit.
vt_ = text('roles/verify/tasks/main.yml')
claim("verify asserts root filesystem headroom",
      'verify_root_disk_pct_max' in vt_ and 'Root filesystem has headroom' in vt_)
claim("the disk thresholds are role defaults, not inline literals",
      vf.get('verify_root_disk_pct_max') is not None and vf.get('verify_varlog_mb_max') is not None)

claim("DESIGN documents jmdn's competing drop-in by name",
      'jmdn-limits.conf' in dz and 'install_services.sh' in dz)

print("-- safety guarantees --")
vt = text('roles/verify/tasks/main.yml')
mods = set(re.findall(r'^\s+ansible\.builtin\.([a-z_]+):', vt, re.M))
# shell is allowed only because every shell body is scanned below, exactly like
# command. Adding it to this set without that scan would gut the guarantee.
READONLY = {'assert', 'debug', 'set_fact', 'stat', 'slurp', 'uri', 'command',
            'service_facts', 'pause', 'shell'}
cmds = re.findall(r'ansible\.builtin\.command:\s*(.+)', vt)
shells = re.findall(r'ansible\.builtin\.shell:\s*\|\n(.*?)\n  [a-z]', vt, re.S)
claim("every shell task in verify was found by the scanner",
      len(shells) == len(re.findall(r'ansible\.builtin\.shell:', vt)),
      f"blocks={len(shells)} tasks={len(re.findall(r'ansible.builtin.shell:', vt))}")
mutating_cmds = [x for x in cmds + shells
                 if re.search(r'\b(restart|start|stop|enable|disable|rm|mv|cp|tee|chmod|chown)\b', x)]
# service_facts merely READS unit state; matching on the substring "service"
# would flag it, which is why this enumerates modules instead of pattern-matching.
claim("README's 'verify never writes a file or restarts a service' holds",
      not (mods - READONLY) and not mutating_cmds,
      f"non-read-only={sorted(mods - READONLY)} mutating={mutating_cmds}")
claim("the systemd unit regex is anchored, so the collector cannot enumerate more",
      ne['node_exporter_systemd_units_regex'].startswith('^')
      and ne['node_exporter_systemd_units_regex'].endswith('$'))
claim("TELEMETRY is exhaustive: every jmdn_* the collector emits is documented",
      all(m in tm for m in set(re.findall(r'^echo "(jmdn_[a-z_]+)', sh, re.M))))
claim("explorer_api_key never reaches an exported template",
      not any('explorer_api_key' in text(x) for x in glob.glob('roles/otel_agent/templates/*.j2')))


print()
if FAILED:
    print(f"FAILED {len(FAILED)} claim(s):")
    for f in FAILED:
        print(f"  - {f}")
    sys.exit(1)
print("All documentation claims verified against the code.")
