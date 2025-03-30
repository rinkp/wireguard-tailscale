# Wireguard subnet for tailscale
This repository provides a small docker image that allows connecting wireguard tunnels to a tailnet. 

Example use cases:
- Use any commercial VPN with wireguard support as **exit node** (similar to tailscale.com's support for [Mullvad](https://tailscale.com/kb/1258/mullvad-exit-nodes))
- Connect a your tailnet with a remote router that does not support tailscale (several router brands support wireguard out of the box)
- Use a wireguard VPN while simultaneously allowing connections to your tailnet (e.g. on Android which has a limitation for 1 VPN client)

## Prerequisites
Please note that any docker container running this image requires:
- the `NET_ADMIN` [capability](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- access to the `/dev/net/tun` device
- two kernel parameters:
    - `net.ipv6.conf.all.forwarding=1`
    - `net.ipv4.ip_forward=1`

When using the provided [`docker-compose.yml`](https://raw.githubusercontent.com/rinkp/osticket-dockerized/main/docker-compose.yml), these settings are automatically set.

## Compatibility
This setup has been tested against a server running Juan Font's headscale [v0.25.1](https://github.com/juanfont/headscale/releases/tag/v0.25.1). It is expected to work with tailscale.com.

This setup has been tested with Windscribe VPN provider. You can generate a Wireguard config on [https://windscribe.com/getconfig/wireguard](https://windscribe.com/getconfig/wireguard).

## Build
1. Clone this repository including submodules: `git clone --recurse-submodules https://github.com/rinkp/wireguard-tailscale.git`
2. Copy `compose.override.yml.dist` to `compose.override.yml` and uncomment the `build:` line 
3. Build using `docker compose build`

## Setup
1. Create the necessary `compose.yml` and `compose.override.yml` files
2. In the `config/wireguard` folder, create a `wg0.conf` config file
3. Set the `TS_AUTHKEY` and other necessary environment variables

### Set up in headscale
When using headscale, perform the following steps:

1. Create an auth key: `headscale pre create -u server --tags=tag:wireguard-client`
2. Start the container
3. Enable the route: `headscale routes ls`, `headscale routes enable -r 123` replacing 123 with the ID of the route you want to enable
4. Ensure that your `policies.json` allows one or more hosts/users to connect to destinations in your published subnets. It is not possible to publish a bigger subnet (e.g. `8.8.0.0/16`) to your tailnet and only allow traffic to a subset of the destinations (e.g. `8.8.8.0/22`). You can solve this by publishing the subnet in one or more smaller parts, either by updating your wireguard config or by using `TS_ADVERTISE_ROUTES`.

### Environment variables

| **Variable**          | **Default value**                    | **Description**                                                                                                                   |
|-----------------------|--------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| `TS_LOGIN_SERVER`     | `https://controlplane.tailscale.com` | Optional, tailscale login server (e.g. when using headscale)                                                                      |
| `TS_AUTHKEY`          | ` `                                  | Mandatory, auth key                                                                                                               |
| `TS_ADVERTISE_ROUTES` | ` `                                  | Optional, forces advertising specific routes rather than using the routes from wireguard                                          |
| `WGTS_TEST_HOST`      | `google.com`                         | Optional, host to verify that the wireguard connection is working (make sure this host is in an accepted wireguard route)         |
| `WGTS_TEST_PORT`      | `443`                                | Optional, port for the above                                                                                                      |
| `WGTS_ALWAYS_UP`      | `False`                              | Optional, when ¨True¨ always enables tailscale and advertises the ¨TS_ADVERTISE_ROUTES¨ routes, even when wireguard does not work |
| `WGTS_CHECK_INTERVAL` | `300`                                | Optional, how frequently to check status of wireguard tunnel (in sec)                                                             |
