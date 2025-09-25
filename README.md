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
This setup has been tested against a server running Juan Font's headscale [v0.25.1](https://github.com/juanfont/headscale/releases/tag/v0.25.1). It is expected to work with tailscale.com and some instructions have been provided below.

This setup has been tested with Windscribe VPN provider. You can generate a Wireguard config on [https://windscribe.com/getconfig/wireguard](https://windscribe.com/getconfig/wireguard).

This setup has been tested with a `wg0.conf` file having 1 endpoint and 1 peer. When multiple peers are present, the `AllowedIPs` are combined for the purposes of advertising routes. Likely, you want to set `TS_ADVERTISE_ROUTES` manually. See also [GH-2](https://github.com/rinkp/wireguard-tailscale/issues/2).

## Build
1. Clone this repository including submodules: `git clone --recurse-submodules https://github.com/rinkp/wireguard-tailscale.git`
2. Copy `compose.override.yml.dist` to `compose.override.yml` and uncomment the `build:` line 
3. Build using `docker compose build`

## Setup
1. Create the necessary `compose.yml` and `compose.override.yml` files
2. In the `config/wireguard` folder, create a `wg0.conf` config file
3. Ensure that tailscale traffic is not routed through your VPN, you may exclude those IP ranges using `WGTS_AUTO_ROUTE` or a tool like [this](https://www.procustodibus.com/blog/2021/03/wireguard-allowedips-calculator/)
4. Set the `TS_AUTHKEY` and other necessary environment variables

### Set up in headscale
When using headscale, perform the following steps:

1. Obtain list of users: `headscale users list`
1. Create an auth key: `headscale pre create -u 1 --tags=tag:wgts-client` and set this as `TS_AUTHKEY`
2. In your `policies.json`, add the route to the `autoApprovers`, either in `exitNode` or a specific route in `routes`.
3. Ensure that your `policies.json` allows one or more hosts/users to connect to destinations in your published subnets. It is not possible to publish a bigger subnet (e.g. `8.8.0.0/16`) to your tailnet and only allow traffic to a subset of the destinations (e.g. `8.8.8.0/22`). You can solve this by publishing the subnet in one or more smaller parts, either by updating your wireguard config or by using `TS_ADVERTISE_ROUTES`.
4. Start the container

Example snippet from `policies.json`:
```json
"autoApprovers": {
    "routes": {
        "192.168.10.0/24":  ["tag:wgts-client"],
    },
    "exitNode": ["tag:wgts-exit"],
},
"hosts": {
    "net-example": "192.168.10.0/24",
},
"acls": [
    {
        "action": "accept",
        "src":    ["group:wgts-users"],
        "dst":    ["net-example:*"],
    },
]
```

### Set up in tailscale.com
When using tailscale.com, perform the following steps:

1. Create an auth key on https://login.tailscale.com/admin/settings/keys (with appropriate tags)
2. Optional: in your `policies.json`, add the route(s) to the `autoApprovers`
3. Ensure that your `policies.json` allows one or more hosts/users to connect to destinations in your published subnets. It is not possible to publish a bigger subnet (e.g. `8.8.0.0/16`) to your tailnet and only allow traffic to a subset of the destinations (e.g. `8.8.8.0/22`). You can solve this by publishing the subnet in one or more smaller parts, either by updating your wireguard config or by using `TS_ADVERTISE_ROUTES`.
4. Start the container
5. If you skipped step 2, approve the new subnets for the node. This can be recognised by the `This machine has unapproved routes.` remark.

### Environment variables

| **Variable**          | **Default value**                    | **Description**                                                                                                                   |
|-----------------------|--------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| `TS_LOGIN_SERVER`     | `https://controlplane.tailscale.com` | Optional, tailscale login server (e.g. when using headscale)                                                                      |
| `TS_AUTHKEY`          | ` `                                  | Mandatory, auth key                                                                                                               |
| `TS_ADVERTISE_ROUTES` | ` `                                  | Optional, forces advertising specific routes rather than using the routes from wireguard                                          |
| `WGTS_TEST_HOST`      | `google.com`                         | Optional, host to verify that the wireguard connection is working (make sure this host is in an accepted wireguard route)         |
| `WGTS_TEST_PORT`      | `443`                                | Optional, port for the above                                                                                                      |
| `WGTS_ALWAYS_UP`      | `False`                              | Optional, when ¨True¨ always enables tailscale and advertises the ¨TS_ADVERTISE_ROUTES¨ routes, even when wireguard does not work |
| `WGTS_AUTO_ROUTE`     | `True`                               | Optional, when ¨True¨ automatically excludes the wireguard and tailscale hosts from being routed over the Wireguard tunnel        |
| `WGTS_CHECK_INTERVAL` | `300`                                | Optional, how frequently to check status of wireguard tunnel (in sec)                                                             |

## Included work / Licenses
This image includes several other tools.

### Tailscale
This repository includes a submodule and will build the `tailscale` CLI and 
`tailscaled` daemon from [tailscale/tailscale](https://github.com/tailscale/tailscale). 

License: BSD 3-Clause, copy [here](https://github.com/tailscale/tailscale/blob/main/LICENSE)

### Wireguard
During build, `wireguard-tools-wg-quick` will be installed. Wireguard licenses 
can be found [here](https://www.wireguard.com/#license).