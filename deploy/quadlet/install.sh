#!/usr/bin/env bash
# Vantage on rootless Podman Quadlet, monitoring this host only, published on the
# tailnet with `tailscale serve`. Run as your normal user (not root), from anywhere:
#
#   ./deploy/quadlet/install.sh
#
# Safe to re-run: the master key, Prometheus token, certificate, vantage.env and data
# volumes are kept. Settings (environment variables, all optional):
#   VANTAGE_LOCAL_PORT  loopback port of the frontend           (default 8450)
#   VANTAGE_TS_PORT     HTTPS port on the tailnet                (default 8448)
#   VANTAGE_NODE_PORT   port of the bundled node_exporter        (default 9101)
#   VANTAGE_TS_NAME     MagicDNS name, if auto-detection fails   (e.g. myhost.tailnet-example.ts.net)
#   VANTAGE_NO_SERVE=1  don't touch `tailscale serve`
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
CONF=${XDG_CONFIG_HOME:-$HOME/.config}/vantage
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd
LOCAL_PORT=${VANTAGE_LOCAL_PORT:-8450}
TS_PORT=${VANTAGE_TS_PORT:-8448}
NODE_PORT=${VANTAGE_NODE_PORT:-9101}

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "run as your normal user (rootless Podman), not root"
for c in podman systemctl openssl tailscale ss curl; do
    command -v "$c" >/dev/null || die "missing command: $c"
done
pv=$(podman version --format '{{.Client.Version}}')
[ "${pv%%.*}" -ge 5 ] || die "Podman 5 or newer is needed (found $pv)"
[ -x /usr/lib/systemd/user-generators/podman-user-generator ] \
    || [ -x /usr/libexec/podman/quadlet ] || [ -x /usr/lib/podman/quadlet ] \
    || warn "couldn't find the Quadlet generator; units may not be picked up"
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]; then
    warn "linger is off: Vantage stops when you log out. Fix: sudo loginctl enable-linger $USER"
fi

TS_IP=$(tailscale ip -4 2>/dev/null | head -n1)
[ -n "$TS_IP" ] || die "tailscale has no IPv4 address; is tailscaled up and logged in?"
TS_NAME=${VANTAGE_TS_NAME:-}
if [ -z "$TS_NAME" ]; then
    json=$(tailscale status --json 2>/dev/null || true)
    if command -v jq >/dev/null; then
        TS_NAME=$(printf '%s' "$json" | jq -r '.Self.DNSName // empty')
    else
        TS_NAME=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"])' 2>/dev/null || true)
    fi
    TS_NAME=${TS_NAME%.}
fi
[ -n "$TS_NAME" ] || die "couldn't detect the MagicDNS name; set VANTAGE_TS_NAME=<host>.<tailnet>.ts.net"

if ss -Hltn "sport = :$LOCAL_PORT" | grep -q . && ! podman container exists vantage-frontend; then
    die "port $LOCAL_PORT is already in use on this host; pick another with VANTAGE_LOCAL_PORT"
fi
say "Tailscale: $TS_NAME ($TS_IP) — dashboard will be https://$TS_NAME:$TS_PORT"

# --- config dir and secrets --------------------------------------------------------
umask 077
mkdir -p "$CONF/secrets" "$UNITS"
chmod 700 "$CONF" "$CONF/secrets"

new_secret_file() {  # $1 file, rest: openssl rand args
    local f=$1; shift
    openssl rand "$@" > "$f.tmp" && mv "$f.tmp" "$f"
}

if [ -f "$CONF/secrets/master.key" ]; then
    say "Keeping existing master key"
elif podman secret exists vantage-master-key || podman volume exists vantage-backend-data; then
    die "master.key is missing but an earlier install exists (podman secret or data volume).
Restore your backup to $CONF/secrets/master.key and re-run; a new key can't decrypt stored credentials."
else
    new_secret_file "$CONF/secrets/master.key" -base64 32
    say "Created master key — BACK UP $CONF/secrets/master.key somewhere off this server"
fi
[ -f "$CONF/secrets/prometheus_token" ] || new_secret_file "$CONF/secrets/prometheus_token" -hex 32

if [ ! -f "$CONF/secrets/tls.crt" ] || [ ! -f "$CONF/secrets/tls.key" ]; then
    # Only the hop tailscale serve -> nginx uses it, so self-signed is fine.
    cfg=$(mktemp)
    cat > "$cfg" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $TS_NAME
O = Vantage self-signed
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1,DNS:$TS_NAME,IP:$TS_IP
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 -config "$cfg" \
        -keyout "$CONF/secrets/tls.key" -out "$CONF/secrets/tls.crt" >/dev/null 2>&1 \
        || { rm -f "$cfg"; die "openssl couldn't create the certificate"; }
    rm -f "$cfg"
    say "Created self-signed certificate"
    podman secret rm vantage-tls-cert vantage-tls-key >/dev/null 2>&1 || true
fi

ensure_secret() {  # $1 podman secret name, $2 file
    podman secret exists "$1" || podman secret create "$1" "$2" >/dev/null
}
ensure_secret vantage-master-key "$CONF/secrets/master.key"
ensure_secret vantage-prometheus-token "$CONF/secrets/prometheus_token"
ensure_secret vantage-tls-cert "$CONF/secrets/tls.crt"
ensure_secret vantage-tls-key "$CONF/secrets/tls.key"

# --- config files ------------------------------------------------------------------
umask 022
install -m 644 "$REPO/deploy/prometheus/prometheus.yml" "$CONF/prometheus.yml"
PUBLIC_HOSTS="$TS_NAME:$TS_PORT,localhost:$LOCAL_PORT,127.0.0.1:$LOCAL_PORT"
if [ -f "$CONF/vantage.env" ]; then
    say "Keeping existing $CONF/vantage.env"
    grep -q "^VANTAGE_PUBLIC_HOSTS=.*$TS_NAME:$TS_PORT" "$CONF/vantage.env" \
        || warn "VANTAGE_PUBLIC_HOSTS in vantage.env doesn't list $TS_NAME:$TS_PORT"
else
    sed "s|@PUBLIC_HOSTS@|$PUBLIC_HOSTS|" "$HERE/vantage.env.example" > "$CONF/vantage.env"
    chmod 600 "$CONF/vantage.env"
fi

# --- node_exporter for this host ---------------------------------------------------
# The containers reach the host through its Tailscale address (loopback is never
# reachable from them, and Vantage's guard refuses it anyway).
NODE_TARGET=""
if ss -Hltn "sport = :9100" | awk '{print $4}' \
        | grep -qE "^(0\.0\.0\.0|\*|\[::\]|$TS_IP):9100$"; then
    NODE_TARGET="$TS_IP:9100"
    say "Reusing the node_exporter already listening on :9100"
    rm -f "$UNITS/vantage-node-exporter.container"
else
    NODE_TARGET="$TS_IP:$NODE_PORT"
    sed "s|@NODE_LISTEN@|$NODE_TARGET|" "$HERE/vantage-node-exporter.container" \
        > "$UNITS/vantage-node-exporter.container"
    say "Installing node_exporter on $NODE_TARGET (tailnet only)"
fi

# --- units -------------------------------------------------------------------------
install -m 644 "$HERE/vantage.network" "$UNITS/vantage.network"
install -m 644 "$HERE/vantage-backend.container" "$UNITS/vantage-backend.container"
install -m 644 "$HERE/vantage-prometheus.container" "$UNITS/vantage-prometheus.container"
sed "s|@LOCAL_PORT@|$LOCAL_PORT|" "$HERE/vantage-frontend.container" \
    > "$UNITS/vantage-frontend.container"

say "Pulling images"
for img in $(grep -h '^Image=' "$UNITS"/vantage-*.container | cut -d= -f2 | sort -u); do
    podman pull -q "$img" >/dev/null
done

systemctl --user daemon-reload
services=(vantage-backend vantage-prometheus vantage-frontend)
[ -f "$UNITS/vantage-node-exporter.container" ] && services+=(vantage-node-exporter)
say "Starting ${services[*]}"
systemctl --user restart "${services[@]}"

say "Waiting for the dashboard"
ok=0
for _ in $(seq 1 60); do
    if curl -skf -o /dev/null "https://127.0.0.1:$LOCAL_PORT/healthz/live"; then ok=1; break; fi
    sleep 3
done
[ "$ok" = 1 ] || die "frontend didn't answer on 127.0.0.1:$LOCAL_PORT; see: journalctl --user -u vantage-backend -u vantage-frontend -n 80"

# --- tailscale serve ---------------------------------------------------------------
if [ "${VANTAGE_NO_SERVE:-0}" != 1 ]; then
    serve=(serve --bg "--https=$TS_PORT" "https+insecure://127.0.0.1:$LOCAL_PORT")
    if ! tailscale "${serve[@]}" >/dev/null 2>&1; then
        say "tailscale serve needs root (or: sudo tailscale set --operator=$USER)"
        sudo tailscale "${serve[@]}" >/dev/null
    fi
    say "tailscale serve: https://$TS_NAME:$TS_PORT -> 127.0.0.1:$LOCAL_PORT"
fi

# --- done --------------------------------------------------------------------------
code=$(podman exec vantage-backend python -m app.cli setup-code --quiet 2>/dev/null || true)
cat <<EOF

Vantage is running.
  Open:        https://$TS_NAME:$TS_PORT   (from any device on your tailnet)
EOF
if [ -n "$code" ]; then
    echo "  Setup code:  $code   (one-time, to create the first admin)"
else
    echo "  Setup code:  podman exec vantage-backend python -m app.cli setup-code"
fi
cat <<EOF

Add this host in the UI: Devices -> Add -> Linux host
  Host: $TS_IP    Port: ${NODE_TARGET##*:}    Scheme: http

Back up now (off this server): $CONF/secrets/master.key
EOF
