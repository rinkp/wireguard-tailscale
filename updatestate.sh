#!/bin/sh

# This script will update the tailscale state matching availability of the wireguard interface

sleep 10

# If there is a reason (e.g. to avoid traffic flowing outside), it is possible to keep the routes always advertised
# This requires the routes to be set in TS_ADVERTISE_ROUTES as well
if [ "${WGTS_ALWAYS_UP}" == "True" ]; then
  echo "[wgts] Tailscale should always be up, skipping checks and setting routes from TS_ADVERTISE_ROUTES: ${TS_ADVERTISE_ROUTES}"
  tailscale set --advertise-routes="$TS_ADVERTISE_ROUTES" --accept-routes=false
  tailscale status &> /dev/null || tailscale up
  echo "0" > /tmp/wgts-status
  exit 0
fi

# If the wireguard is DOWN, tailscale should not advertise non-working routes
wg show wg0 peers &> /dev/null
if [ $? -eq 1 ]; then
    echo "[wgts] Wireguard is down, stop advertising routes and exit node"
    tailscale down
    echo "1" > /tmp/wgts-status
    exit 0
fi

# This means the tunnel is up so we can perform additional checks

# Check if the network is available before advertising routes
if [[ -n "${WGTS_TEST_IP}" && -n "${WGTS_TEST_PORT}" ]]; then
  nc -z -w10 "${WGTS_TEST_IP}" "${WGTS_TEST_PORT}"
  if [ $? -eq 1 ]; then
    echo "[wgts] TCP port ${WGTS_TEST_IP}:${WGTS_TEST_PORT} could not be reached, assuming network is down; stop advertising routes and exit node"
    tailscale set --advertise-routes="" --advertise-exit-node=false
    echo "1" > /tmp/wgts-status
    exit 1
  fi
fi

# If we don't know the routes, we can deduct these from wireguard output
if [[ -z "${TS_ADVERTISE_ROUTES}" ]]; then
  export TS_ADVERTISE_ROUTES=$(wg show wg0 allowed-ips | sed -e 's/^.*=\t//' | tr '\n' ' ' | sed -E 's/([[:blank:]]+)(.+)/,\2/g' | tr ' ' '\n')
  echo "[wgts] Discovered routes: ${TS_ADVERTISE_ROUTES}"
fi

if [[ $TS_ADVERTISE_ROUTES == *"0.0.0.0/0"* ]]; then
  # remove the exit-node routes (0.0.0.0/0 & ::/0)
  EXTRA_TS_ADVERTISE_ROUTES="${TS_ADVERTISE_ROUTES//0.0.0.0\/0/}"
  EXTRA_TS_ADVERTISE_ROUTES="${EXTRA_TS_ADVERTISE_ROUTES//::\/0/}"

  # Remove trailing, leading, or duplicate commas
  EXTRA_TS_ADVERTISE_ROUTES="${EXTRA_TS_ADVERTISE_ROUTES//,,/,}"
  EXTRA_TS_ADVERTISE_ROUTES="${EXTRA_TS_ADVERTISE_ROUTES#,}"
  EXTRA_TS_ADVERTISE_ROUTES="${EXTRA_TS_ADVERTISE_ROUTES%,}"

  echo "[wgts] Advertising exit node w/ \"$EXTRA_TS_ADVERTISE_ROUTES\""
  tailscale set --advertise-routes="$EXTRA_TS_ADVERTISE_ROUTES" --advertise-exit-node=true --accept-routes=false
else
  echo "[wgts] Advertising routes: ${TS_ADVERTISE_ROUTES}"
  tailscale set --advertise-routes="$TS_ADVERTISE_ROUTES" --advertise-exit-node=false --accept-routes=false
fi

echo "[wgts] Wireguard is up, setting tailscale up"
tailscale status &> /dev/null || tailscale up

# Obtain the real status of tailscale+wireguard and store it (0 is up)
tailscale netcheck | grep 'IPv4: yes' &> /dev/null && wg show wg0 peers &> /dev/null
echo $? > /tmp/wgts-status