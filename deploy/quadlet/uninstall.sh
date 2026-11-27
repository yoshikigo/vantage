#!/usr/bin/env bash
# Stops Vantage and removes its Quadlet units and the tailscale serve entry.
# Keeps data volumes, Podman secrets and ~/.config/vantage unless --purge is given.
#   VANTAGE_TS_PORT  the tailnet HTTPS port used at install (default 8448)
set -euo pipefail

UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd
CONF=${XDG_CONFIG_HOME:-$HOME/.config}/vantage
TS_PORT=${VANTAGE_TS_PORT:-8448}
purge=0
[ "${1:-}" = --purge ] && purge=1

systemctl --user stop vantage-frontend vantage-prometheus vantage-backend \
    vantage-node-exporter vantage-network 2>/dev/null || true
rm -f "$UNITS"/vantage-*.container "$UNITS/vantage.network"
systemctl --user daemon-reload

if command -v tailscale >/dev/null; then
    tailscale serve "--https=$TS_PORT" off 2>/dev/null \
        || sudo tailscale serve "--https=$TS_PORT" off 2>/dev/null || true
fi

if [ "$purge" = 1 ]; then
    echo "Purging data, secrets and $CONF (the master key is gone unless you backed it up)."
    read -r -p "Type 'purge' to continue: " ok
    [ "$ok" = purge ] || { echo "Aborted."; exit 1; }
    podman volume rm -f vantage-backend-data vantage-prometheus-data 2>/dev/null || true
    podman secret rm vantage-master-key vantage-prometheus-token vantage-tls-cert vantage-tls-key 2>/dev/null || true
    podman network rm vantage 2>/dev/null || true
    rm -rf "$CONF"
fi
echo "Vantage removed."
