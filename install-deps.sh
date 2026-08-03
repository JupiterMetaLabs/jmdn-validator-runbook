#!/bin/sh
#
# install-deps.sh — installs everything this runbook needs to RUN, and nothing
# more. It touches no jmdn state and starts no services.
#
#   ansible-core   the playbooks in this repository
#   curl, jq       used by the chain-health collector at runtime
#
# No Ansible Galaxy collections are required: every module used is
# ansible.builtin.
#
# Safe to re-run: it checks before it installs.
#
#   sudo ./install-deps.sh
#
# NOTE: this is unrelated to jmdn's Scripts/bootstrap_sync.sh, which downloads
# the chain snapshot in Stage 1.7. Different job entirely.
#
set -eu

MIN_ANSIBLE="2.15"

die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
info() { printf '==> %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./install-deps.sh)"

# --- Already present and new enough? ------------------------------------------
if command -v ansible-playbook >/dev/null 2>&1; then
    have="$(ansible-playbook --version 2>/dev/null | head -1 | sed 's/[^0-9.]*\([0-9]*\.[0-9]*\).*/\1/')"
    if [ -n "$have" ] && [ "$(printf '%s\n%s\n' "$MIN_ANSIBLE" "$have" | sort -V | head -1)" = "$MIN_ANSIBLE" ]; then
        info "ansible-playbook $have already installed — nothing to do"
        ANSIBLE_OK=1
    fi
fi

# --root-user-action=ignore silences pip's "Running pip as the 'root' user"
# warning, which is expected here (we are invoked via sudo) and alarming to read.
# It landed in pip 22.1; older pip treats an unknown flag as a hard error, so
# detect it rather than assume. Empty expands to nothing.
pip_root_flag() {
    if python3 -m pip install --help 2>/dev/null | grep -q -- '--root-user-action'; then
        printf '%s' '--root-user-action=ignore'
    fi
}

if [ "${ANSIBLE_OK:-0}" != "1" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        info "installing python3-pip via apt"
        apt-get update -qq
        apt-get install -y -qq python3-pip ca-certificates
        # PEP 668 marks the system Python as externally managed on newer
        # Debian/Ubuntu; ansible-core is a CLI tool, so this is the intended
        # escape hatch rather than a virtualenv the operator has to remember.
        info "installing ansible-core"
        python3 -m pip install --quiet $(pip_root_flag) --break-system-packages ansible-core
    elif command -v dnf >/dev/null 2>&1; then
        info "installing python3-pip via dnf"
        dnf install -y -q python3-pip
        info "installing ansible-core"
        python3 -m pip install --quiet $(pip_root_flag) ansible-core
    elif command -v yum >/dev/null 2>&1; then
        info "installing python3-pip via yum"
        yum install -y -q python3-pip
        info "installing ansible-core"
        python3 -m pip install --quiet $(pip_root_flag) ansible-core
    else
        die "no supported package manager found (apt-get, dnf, yum). Install ansible-core manually."
    fi
fi

# pip may place the entry points outside the default PATH.
if ! command -v ansible-playbook >/dev/null 2>&1; then
    for d in /usr/local/bin "$HOME/.local/bin"; do
        [ -x "$d/ansible-playbook" ] && { info "found ansible-playbook in $d — add it to PATH"; export PATH="$PATH:$d"; break; }
    done
fi
command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook still not on PATH after install"

info "ansible-playbook: $(ansible-playbook --version | head -1)"

# --- Runtime dependencies used by the health collector -----------------------
# ss is needed by verify.yml's exposure check; without it that check silently
# skips while the config-level check still runs.
for pkg in curl jq; do
    command -v "$pkg" >/dev/null 2>&1 && continue
    info "installing $pkg"
    if   command -v apt-get >/dev/null 2>&1; then apt-get install -y -qq "$pkg"
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q "$pkg"
    elif command -v yum     >/dev/null 2>&1; then yum install -y -q "$pkg"
    fi
done

if ! command -v ss >/dev/null 2>&1; then
    info "installing iproute2 (provides ss, used by verify.yml)"
    if   command -v apt-get >/dev/null 2>&1; then apt-get install -y -qq iproute2
    elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q iproute
    elif command -v yum     >/dev/null 2>&1; then yum install -y -q iproute
    fi
fi

cat <<'NEXT'

Dependencies installed. Next:

  cp operator.yml.example operator.yml
  chmod 600 operator.yml                     # it will hold your telemetry token
  ${EDITOR:-nano} operator.yml               # operator_id, node_id, token
  ansible-playbook preflight.yml             # read-only machine check

Then follow RUNBOOK.md from Stage 1. Do not run observability.yml yet — on a
machine with no jmdn installed there is nothing for it to report on.

NEXT
