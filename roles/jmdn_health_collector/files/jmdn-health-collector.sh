#!/bin/sh
#
# jmdn-health-collector — emits JMDN chain-health metrics for the
# node_exporter textfile collector.
#
# Managed by jmdn-validator-runbook. Configuration comes entirely from the
# environment (see /etc/jmdn-health/collector.env), so this file is static and
# is never templated — one less place for a rendering mistake to hide.
#
# DESIGN NOTES
#   * `set -e` is deliberately NOT used. A failed probe must still produce a
#     metrics file, otherwise a partially-unhealthy node becomes an invisible
#     node.
#   * The output file is written via mktemp + mv. node_exporter reads this
#     directory continuously and a half-written file breaks the entire scrape,
#     not just these metrics.
#   * jmdn_health_collector_last_run_timestamp_seconds exists because stale
#     textfile metrics are served forever. A frozen block height and a dead
#     collector look identical without it. Alert on this metric's age.
#   * Only loopback is contacted. Nothing here reaches the network.
#
set -u

TEXTFILE_DIR="${JMDN_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
STATE_DIR="${JMDN_STATE_DIR:-/var/lib/jmdn-health}"
# A port of 0 means the operator deliberately did not enable that listener
# (jmdn ships ports.api and several others at 0). Probing a disabled service
# would report a permanent failure for a correctly configured node, so those
# probes are skipped entirely and no series is emitted for them.
EXPLORER_PORT="${JMDN_EXPLORER_PORT:-8090}"
FACADE_PORT="${JMDN_FACADE_PORT:-8545}"
EXPLORER="http://127.0.0.1:${EXPLORER_PORT}"
FACADE="http://127.0.0.1:${FACADE_PORT}"
TIMEOUT="${JMDN_CURL_TIMEOUT:-2}"
API_KEY="${JMDN_EXPLORER_API_KEY:-}"

OUT="${TEXTFILE_DIR}/jmdn_health.prom"
TMP="$(mktemp "${TEXTFILE_DIR}/.jmdn_health.XXXXXX" 2>/dev/null)" || exit 1
BODY="$(mktemp 2>/dev/null)" || { rm -f "$TMP"; exit 1; }
trap 'rm -f "$TMP" "$BODY"' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# http_probe <method> <url> [json_body] [auth_header]
# Body lands in $BODY. Echoes exactly "<http_code> <seconds>". Never fails the
# script, and never emits a third field: curl already writes "000 <t>" and
# exits non-zero on a refused connection, so a `|| printf` fallback would
# append to that and shift the fields.
# ---------------------------------------------------------------------------
http_probe() {
    _m="$1"; _u="$2"; _d="${3:-}"; _a="${4:-}"
    _out=""
    if [ -n "$_d" ]; then
        if [ -n "$_a" ]; then
            _out="$(curl -s -o "$BODY" -w '%{http_code} %{time_total}' \
                 --max-time "$TIMEOUT" -X "$_m" \
                 -H 'Content-Type: application/json' -H "$_a" \
                 -d "$_d" "$_u" 2>/dev/null)"
        else
            _out="$(curl -s -o "$BODY" -w '%{http_code} %{time_total}' \
                 --max-time "$TIMEOUT" -X "$_m" \
                 -H 'Content-Type: application/json' \
                 -d "$_d" "$_u" 2>/dev/null)"
        fi
    else
        if [ -n "$_a" ]; then
            _out="$(curl -s -o "$BODY" -w '%{http_code} %{time_total}' \
                 --max-time "$TIMEOUT" -H "$_a" "$_u" 2>/dev/null)"
        else
            _out="$(curl -s -o "$BODY" -w '%{http_code} %{time_total}' \
                 --max-time "$TIMEOUT" "$_u" 2>/dev/null)"
        fi
    fi
    # Normalise: exactly two whitespace-separated fields, always.
    set -- $_out
    printf '%s %s' "${1:-000}" "${2:-0}"
}

code_of() { printf '%s' "$1" | cut -d' ' -f1; }
time_of() { printf '%s' "$1" | cut -d' ' -f2; }

# 1 if HTTP 2xx, else 0.
#
# NOTE: this is always called inside a command substitution, which is a
# subshell — so it must be side-effect free. An earlier version incremented a
# `failures` counter here and it silently stayed 0 forever, reporting a totally
# unreachable node as having zero probe failures. The count is derived from the
# returned values below instead.
up_of() {
    case "$1" in
        2??) printf '1' ;;
        *)   printf '0' ;;
    esac
}

# Hex quantity ("0x1a") -> decimal. Returns non-zero on anything unexpected
# rather than emitting a wrong number.
hex_to_dec() {
    _h="$(printf '%s' "$1" | tr 'ABCDEF' 'abcdef')"
    case "$_h" in
        0x*[!0-9a-fx]*) return 1 ;;
        0x) return 1 ;;
        0x*) printf '%s' "$((_h))" 2>/dev/null || return 1 ;;
        *) return 1 ;;
    esac
}

json_valid() { jq -e . >/dev/null 2>&1 < "$BODY"; }

# ---------------------------------------------------------------------------
# Probe 1 — explorer root health (unauthenticated). Skipped if port is 0.
# ---------------------------------------------------------------------------
root_up=""; root_t=""; ver_up=""; ver_t=""
if [ "$EXPLORER_PORT" != "0" ]; then
    r="$(http_probe GET "${EXPLORER}/")"
    root_up="$(up_of "$(code_of "$r")")"
    root_t="$(time_of "$r")"
fi

# ---------------------------------------------------------------------------
# Probe 2 — explorer node version (unauthenticated)
# Response shape is not contractually fixed, so rather than assume a key name
# we take the first semver-looking string anywhere in the document.
# ---------------------------------------------------------------------------
version=""
if [ "$EXPLORER_PORT" != "0" ]; then
    r="$(http_probe GET "${EXPLORER}/api/v1/node/version")"
    ver_up="$(up_of "$(code_of "$r")")"
    ver_t="$(time_of "$r")"
fi
if [ "${ver_up:-0}" = "1" ] && json_valid; then
    version="$(jq -r '[.. | strings]
                      | map(select(test("^v?[0-9]+\\.[0-9]+")))
                      | .[0] // empty' < "$BODY" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# Probe 3 — facade JSON-RPC: block height and chain id
# ---------------------------------------------------------------------------
facade_up=""; facade_t=""; height=""
if [ "$FACADE_PORT" != "0" ]; then
    r="$(http_probe POST "$FACADE" '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}')"
    facade_up="$(up_of "$(code_of "$r")")"
    facade_t="$(time_of "$r")"
fi
if [ "${facade_up:-0}" = "1" ] && json_valid; then
    raw="$(jq -r '.result // empty' < "$BODY" 2>/dev/null)"
    [ -n "$raw" ] && height="$(hex_to_dec "$raw")" || height=""
fi

chain_id=""
if [ "${facade_up:-0}" = "1" ]; then
    r="$(http_probe POST "$FACADE" '{"jsonrpc":"2.0","id":2,"method":"eth_chainId","params":[]}')"
    case "$(code_of "$r")" in
        2??) if json_valid; then
                 raw="$(jq -r '.result // empty' < "$BODY" 2>/dev/null)"
                 [ -n "$raw" ] && chain_id="$(hex_to_dec "$raw")" || chain_id=""
             fi ;;
    esac
fi

# ---------------------------------------------------------------------------
# Probe 4 (optional) — ImmuDB connectivity via the authenticated explorer API.
# Skipped entirely unless an API key was configured.
#
# Auth flow verified in explorer/api.go: POST /api/auth/token with
# {"api_key": "..."} returns a Bearer JWT valid for 24h. The token is cached
# and refreshed every 12h so this costs one extra request twice a day, not one
# every 30 seconds.
# ---------------------------------------------------------------------------
db_default=""
db_accounts=""
if [ -n "$API_KEY" ] && [ "$EXPLORER_PORT" != "0" ]; then
    JWT_FILE="${STATE_DIR}/explorer.jwt"
    jwt=""
    if [ -f "$JWT_FILE" ]; then
        now="$(date +%s)"
        mtime="$(stat -c %Y "$JWT_FILE" 2>/dev/null || echo 0)"
        if [ "$((now - mtime))" -lt 43200 ]; then
            jwt="$(cat "$JWT_FILE" 2>/dev/null)"
        fi
    fi
    if [ -z "$jwt" ]; then
        r="$(http_probe POST "${EXPLORER}/api/auth/token" \
             "$(jq -n --arg k "$API_KEY" '{api_key:$k}')")"
        case "$(code_of "$r")" in
            2??) if json_valid; then
                     jwt="$(jq -r '.token // empty' < "$BODY" 2>/dev/null)"
                     if [ -n "$jwt" ]; then
                         umask 077
                         printf '%s' "$jwt" > "$JWT_FILE"
                     fi
                 fi ;;
        esac
    fi
    if [ -n "$jwt" ]; then
        r="$(http_probe GET "${EXPLORER}/api/block/health" "" "Authorization: Bearer ${jwt}")"
        case "$(code_of "$r")" in 2??) db_default=1 ;; *) db_default=0 ;; esac
        r="$(http_probe GET "${EXPLORER}/api/did/health" "" "Authorization: Bearer ${jwt}")"
        case "$(code_of "$r")" in 2??) db_accounts=1 ;; *) db_accounts=0 ;; esac
    fi
fi

# ---------------------------------------------------------------------------
# Emit. Single ordered pass so every HELP/TYPE precedes its samples.
# ---------------------------------------------------------------------------
# Derived, not accumulated — see the note on up_of above. Only probes that
# actually ran are counted, so a node with the Explorer API deliberately
# disabled does not report permanent failures.
probes_enabled=0; failures=0
for v in "$root_up" "$ver_up" "$facade_up"; do
    [ -z "$v" ] && continue
    probes_enabled=$((probes_enabled + 1))
    [ "$v" = "0" ] && failures=$((failures + 1))
done

total_t="$(awk -v a="${root_t:-0}" -v b="${ver_t:-0}" -v c="${facade_t:-0}" \
              'BEGIN { printf "%.4f", a + b + c }' 2>/dev/null || echo 0)"

{
    echo '# HELP jmdn_endpoint_up Local JMDN endpoint answered with HTTP 2xx. Only enabled endpoints appear.'
    echo '# TYPE jmdn_endpoint_up gauge'
    [ -n "$root_up" ]   && echo "jmdn_endpoint_up{endpoint=\"explorer_root\"} ${root_up}"
    [ -n "$ver_up" ]    && echo "jmdn_endpoint_up{endpoint=\"explorer_version\"} ${ver_up}"
    [ -n "$facade_up" ] && echo "jmdn_endpoint_up{endpoint=\"facade_rpc\"} ${facade_up}"

    echo '# HELP jmdn_endpoint_response_seconds Round-trip time of the local endpoint probe.'
    echo '# TYPE jmdn_endpoint_response_seconds gauge'
    [ -n "$root_t" ]   && echo "jmdn_endpoint_response_seconds{endpoint=\"explorer_root\"} ${root_t}"
    [ -n "$ver_t" ]    && echo "jmdn_endpoint_response_seconds{endpoint=\"explorer_version\"} ${ver_t}"
    [ -n "$facade_t" ] && echo "jmdn_endpoint_response_seconds{endpoint=\"facade_rpc\"} ${facade_t}"

    echo '# HELP jmdn_endpoint_probes_enabled Number of local endpoints this collector was configured to probe.'
    echo '# TYPE jmdn_endpoint_probes_enabled gauge'
    echo "jmdn_endpoint_probes_enabled ${probes_enabled}"

    if [ -n "$height" ]; then
        echo '# HELP jmdn_block_height Latest block height as reported by the local facade (eth_blockNumber).'
        echo '# TYPE jmdn_block_height gauge'
        echo "jmdn_block_height ${height}"
    fi

    if [ -n "$chain_id" ]; then
        echo '# HELP jmdn_chain_id Chain id reported by the local facade (eth_chainId).'
        echo '# TYPE jmdn_chain_id gauge'
        echo "jmdn_chain_id ${chain_id}"
    fi

    if [ -n "$version" ]; then
        echo '# HELP jmdn_build_info Reported jmdn build version (value is always 1).'
        echo '# TYPE jmdn_build_info gauge'
        echo "jmdn_build_info{version=\"${version}\"} 1"
    fi

    if [ -n "$db_default" ] || [ -n "$db_accounts" ]; then
        echo '# HELP jmdn_db_healthy ImmuDB connectivity via the explorer API (1 healthy, 0 unhealthy).'
        echo '# TYPE jmdn_db_healthy gauge'
        [ -n "$db_default" ]  && echo "jmdn_db_healthy{db=\"defaultdb\"} ${db_default}"
        [ -n "$db_accounts" ] && echo "jmdn_db_healthy{db=\"accountsdb\"} ${db_accounts}"
    fi

    echo '# HELP jmdn_health_collector_probe_failures Probes in this run that did not return HTTP 2xx.'
    echo '# TYPE jmdn_health_collector_probe_failures gauge'
    echo "jmdn_health_collector_probe_failures ${failures}"

    echo '# HELP jmdn_health_collector_duration_seconds Total time spent probing in this run.'
    echo '# TYPE jmdn_health_collector_duration_seconds gauge'
    echo "jmdn_health_collector_duration_seconds ${total_t}"

    echo '# HELP jmdn_health_collector_last_run_timestamp_seconds Unix time this file was written. ALERT ON ITS AGE.'
    echo '# TYPE jmdn_health_collector_last_run_timestamp_seconds gauge'
    echo "jmdn_health_collector_last_run_timestamp_seconds $(date +%s)"
} > "$TMP"

# node_exporter runs as a different user and must be able to read this file.
# Files inherit the writer's primary group, so without this the file lands as
# jmdn-health:jmdn-health 0640 and node_exporter cannot open it. The directory
# also carries setgid for the same purpose; either mechanism suffices.
chgrp "${JMDN_TEXTFILE_GROUP:-node_exporter}" "$TMP" 2>/dev/null || true
chmod 0640 "$TMP" 2>/dev/null || true
mv -f "$TMP" "$OUT" || exit 1
exit 0
