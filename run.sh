#!/bin/sh

set -e

stop_handler()
{
    echo "[WGTS] Received SIGTERM, stopping tailscaled and wireguard"
    pkill -TERM tailscaled &
    wg-quick down wg0 & wg_quick_pid=$!
    pkill -KILL sleep &

    echo "[WGTS] Signals sent, waiting for tailscaled and wireguard to stop"
    wait $tailscale_pid
    echo "[WGTS] Stopped tailscaled, waiting for wireguard to stop"
    wait $wg_quick_pid
    echo "[WGTS] Stopped wireguard, exiting"
    exit 0
}

route_outside_wireguard()
{
  local default_route=$(ip -4 route | grep default | head -n1 | sed 's/default[[:space:]]//g')
  nslookup -query=a $1 | \
    grep "Address" | tail -n +2 | sed -e 's/Address:[[:space:]]\+//g' | grep -v : | \
    xargs -r -n1 ip -4 route add $default_route table 41
  
  # If IPv6 default route present
  local default_route6=$(ip -6 route | grep default | head -n1 | sed 's/default[[:space:]]//g')
  if [[ ! -z "${default_route6}" ]]; then
    nslookup -query=aaaa $1 | \
      grep "Address" | tail -n +2 | sed -e 's/Address:[[:space:]]\+//g' | grep : | \
      xargs -r -n1 ip -6 route add $default_route6 table 41
  fi
}

trap stop_handler SIGTERM

# Add routes to ensure that tailscale/wireguard traffic goes outside the wireguard tunnel
if [ "${WGTS_AUTO_ROUTE}" == "True" ]; then
  hostname_logon_server=$(echo $TS_LOGIN_SERVER | sed 's/https\?:\/\///g' | cut -d: -f1)
  route_outside_wireguard $hostname_logon_server

  cat "/etc/wireguard/config/$WG_INTERFACE.conf" | grep Endpoint | \
    sed 's/Endpoint[[:space:]]*=[[:space:]]*//g' | cut -d: -f1 | \
    while IFS= read -r hostname; do route_outside_wireguard $hostname; done

  ip rule add preference 30000 from all lookup 41
  ip -6 rule add preference 30000 from all lookup 41
fi

# Userspace networking for tailscale is used by default to ensure broad compatibility
# See https://tailscale.com/kb/1177/kernel-vs-userspace-routers
# This container still requires NET_ADMIN because of wireguard
# It is possible to set TS_STATE_DIR to "mem:" for ephemeral mode -> may require automatic subnet route approvals
(tailscaled --statedir="$TS_STATE_DIR" --verbose="$TS_VERBOSE" $TS_TAILSCALED_EXTRA_ARGS > >(sed 's/^/[tailscaled] /') 2> >(sed 's/^/[tailscaled] /' >&2)) & tailscale_pid=$!

# Attempt to start wireguard
cp "/etc/wireguard/config/$WG_INTERFACE.conf" /etc/wireguard/wg0.conf
# Add hooks for our state update
sed -ie '/^\[Interface\]/a PostUp=/updatestate.sh' /etc/wireguard/wg0.conf
sed -ie '/^\[Interface\]/a PreDown=/updatestate.sh' /etc/wireguard/wg0.conf
sed -ie '/^\[Interface\]/a Table=40' /etc/wireguard/wg0.conf
# Don't use provided DNS configuration (tailscale clients will not use it)
sed -ie '/^DNS/d' /etc/wireguard/wg0.conf

# Start wireguard and add lookup table after tailscale
wg-quick up wg0 > >(sed 's/^/[wg] /') 2> >(sed 's/^/[wg] /' >&2)
ip rule add preference 30001 from all lookup 40
ip -6 rule add preference 30001 from all lookup 40

# Now it is time to bring up tailscale if not done automatically yet
while [ $(tailscale status --json | jq -r ".BackendState") = "NoState" ]; do
  echo "[wgts] Tailscale is not running yet, waiting..."
  sleep 5
done

if [ -z $(tailscale status --json | jq -r ".Self.ID") ] || [ $(tailscale status --json | jq -r ".BackendState") = "NeedsLogin" ]; then
  tailscale up \
    --reset \
    --login-server="$TS_LOGIN_SERVER" \
    --auth-key="$TS_AUTHKEY" \
    --accept-routes="$TS_ACCEPT_ROUTES" \
    --timeout=300s $TS_EXTRA_ARGS || (echo "Could not switch Tailscale on; exiting"; exit 1)
fi

if [ ! $(tailscale status --json | jq -r ".BackendState") = "Running" ]; then
  tailscale up || (echo "Could not switch Tailscale to Running; exiting"; exit 1)
fi

if [ $(tailscale status --json | jq -r .BackendState) != "Running" ]; then
  echo "[wgts] Tailscale is not running, exiting with error"
  exit 1
fi

sleep 60
# If tailscaled is stopped for whatever reason, exit the container
while pidof tailscaled &> /dev/null; do
  sleep "$WGTS_CHECK_INTERVAL"
  ./updatestate.sh
done
