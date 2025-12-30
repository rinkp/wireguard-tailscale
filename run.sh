#!/bin/sh

set -e

route_outside_wireguard()
{
  local default_route=$(ip -4 route | grep default | head -n1 | sed 's/default[[:space:]]//g')
  nslookup -query=a $1 | \
    grep "Address" | tail -n +2 | sed -e 's/Address:[[:space:]]\+//g' | grep -v : | \
    xargs -r -n1 ip -4 route add $default_route
  
  # If IPv6 default route present
  local default_route6=$(ip -6 route | grep default | head -n1 | sed 's/default[[:space:]]//g')
  if [[ ! -z "${default_route6}" ]]; then
    nslookup -query=aaaa $1 | \
      grep "Address" | tail -n +2 | sed -e 's/Address:[[:space:]]\+//g' | grep : | \
      xargs -r -n1 ip -6 route add $default_route6
  fi
}

# Userspace networking for tailscale is used by default to ensure broad compatibility
# See https://tailscale.com/kb/1177/kernel-vs-userspace-routers
# This container still requires NET_ADMIN because of wireguard
# It is possible to set TS_STATE_DIR to "mem:" for ephemeral mode -> may require automatic subnet route approvals
tailscaled --statedir="$TS_STATE_DIR" --verbose="$TS_VERBOSE" $TS_TAILSCALED_EXTRA_ARGS &

# Attempt logging in if not signed in; exit if that fails (allow for 5min delay)
tailscale status | grep 'Logged out.' && (tailscale up --reset --force-reauth --login-server="$TS_LOGIN_SERVER" --auth-key="$TS_AUTHKEY" --accept-routes="$TS_ACCEPT_ROUTES" --timeout=300s $TS_EXTRA_ARGS || exit 1)

# If tailscale is up, stop advertising routes, then go down
tailscale status && tailscale set --advertise-routes="" --advertise-exit-node=false && tailscale down

# Add routes to ensure that tailscale/wireguard traffic goes outside the wireguard tunnel
if [ "${WGTS_AUTO_ROUTE}" == "True" ]; then
  hostname_logon_server=$(echo $TS_LOGIN_SERVER | sed 's/https\?:\/\///g' | cut -d: -f1)
  route_outside_wireguard $hostname_logon_server

  cat "/etc/wireguard/config/$WG_INTERFACE.conf" | grep Endpoint | \
    sed 's/Endpoint[[:space:]]*=[[:space:]]*//g' | cut -d: -f1 | \
    while IFS= read -r hostname; do route_outside_wireguard $hostname; done
fi

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
