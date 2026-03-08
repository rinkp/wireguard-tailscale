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

# Because we build with ts_omit_logtail, we must filter verbosity here
if [ -z "$TS_VERBOSE" ] || [ "$TS_VERBOSE" -le 2 ]; then
  WGTS_VERBOSE2_FILTER="[v2]"
else
  WGTS_VERBOSE2_FILTER="[v99]"
fi
if [ -z "$TS_VERBOSE" ] || [ "$TS_VERBOSE" -le 1 ]; then
  WGTS_VERBOSE1_FILTER="[v1]"
else
  WGTS_VERBOSE1_FILTER="[v99]"
fi

# Userspace networking for tailscale is used by default to ensure broad compatibility
# See https://tailscale.com/kb/1177/kernel-vs-userspace-routers
# This container still requires NET_ADMIN because of wireguard
# It is possible to set TS_STATE_DIR to "mem:" for ephemeral mode -> may require automatic subnet route approvals
echo "[wgts] Starting tailscaled with state dir $TS_STATE_DIR and verbosity $TS_VERBOSE"
(tailscaled --statedir="$TS_STATE_DIR" --verbose="$TS_VERBOSE" $TS_TAILSCALED_EXTRA_ARGS > >(grep -vF -e "$WGTS_VERBOSE1_FILTER" -e "$WGTS_VERBOSE2_FILTER" | sed 's/^\d*\/\d*\/\d*\s\d*:\d*:\d*/[tailscaled]/') 2> >(grep -vF -e "$WGTS_VERBOSE1_FILTER" -e "$WGTS_VERBOSE2_FILTER" | sed 's/^\d*\/\d*\/\d*\s\d*:\d*:\d*/[tailscaled]/' >&2)) & tailscale_pid=$!

# Attempt to start wireguard
cp "/etc/wireguard/config/$WG_INTERFACE.conf" /etc/wireguard/wg0.conf
# Add hooks for our state update
sed -ie '/^\[Interface\]/a PostUp=/updatestate.sh' /etc/wireguard/wg0.conf
sed -ie '/^\[Interface\]/a PreDown=/updatestate.sh' /etc/wireguard/wg0.conf
sed -ie '/^\[Interface\]/a Table=40' /etc/wireguard/wg0.conf
# Don't use provided DNS configuration (tailscale clients will not use it)
sed -ie '/^DNS/d' /etc/wireguard/wg0.conf

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
    --timeout=300s $TS_EXTRA_ARGS || \
    (echo "[wgts] Could not authenticate to $TS_LOGIN_SERVER; exiting"; exit 1)
fi

# Start wireguard and add lookup table after tailscale
echo "[wgts] Starting wireguard and adding routing rules"
wg-quick up wg0 > >(sed '/wgts/!s/^/[wg] /') 2> >(sed '/wgts/!s/^/[wg] /' >&2)
ip rule add preference 30001 from all lookup 40
ip -6 rule add preference 30001 from all lookup 40

if [ ! "${WGTS_VERBOSE}" = "False" ]; then
  echo "[wgts] Wireguard and tailscale started, showing status"
  tailscale status
  wg show wg0
  echo "[wgts] Showing all routes"
  ip route list table all
fi

if [ ! $(tailscale status --json | jq -r ".BackendState") = "Running" ]; then
  echo "[wgts] Tailscale is not running, attempting to bring it up"
  tailscale up || (echo "[wgts] Could not switch Tailscale to Running; exiting"; exit 1)
fi

if [ $(tailscale status --json | jq -r .BackendState) != "Running" ]; then
  echo "[wgts] Tailscale is not running, exiting with error"
  exit 1
fi

# If tailscaled is stopped for whatever reason, exit the container
while pidof tailscaled &> /dev/null; do
  sleep "$WGTS_CHECK_INTERVAL"
  ./updatestate.sh
done
