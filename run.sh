#!/bin/sh

set -e

# Userspace networking for tailscale is used by default to ensure broad compatibility
# See https://tailscale.com/kb/1177/kernel-vs-userspace-routers
# This container still requires NET_ADMIN because of wireguard
# It is possible to set TS_STATE_DIR to "mem:" for ephemeral mode -> may require automatic subnet route approvals
tailscaled --statedir="$TS_STATE_DIR" $TS_TAILSCALED_EXTRA_ARGS &

# Attempt logging in if not signed in; exit if that fails (allow for 5min delay)
tailscale status | grep 'Logged out.' && (tailscale up --reset --force-reauth --login-server="$TS_LOGIN_SERVER" --auth-key="$TS_AUTHKEY" --accept-routes="$TS_ACCEPT_ROUTES" --timeout=300s $TS_EXTRA_ARGS || exit 1)

# If tailscale is up, go down for a bit
tailscale status && tailscale down

# Attempt to start wireguard
cp "/etc/wireguard/config/$WG_INTERFACE.conf" /etc/wireguard/wg0.conf
sed -ie '/^\[Interface\]/a PostUp=/updatestate.sh' /etc/wireguard/wg0.conf
sed -ie '/^\[Interface\]/a PreDown=/updatestate.sh' /etc/wireguard/wg0.conf
wg-quick up wg0

sleep 60
# If tailscaled is stopped for whatever reason, exit the container
while pidof tailscaled &> /dev/null; do
  sleep "$WGTS_CHECK_INTERVAL"
  ./updatestate.sh
done
