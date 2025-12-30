FROM golang:1.25-alpine3.23 AS ts-build
WORKDIR /go/src/tailscale

COPY tailscale/go.mod tailscale/go.sum ./
RUN --mount=type=cache,target=/go/pkg,sharing=locked \
    go mod download && \
    go install \
        gvisor.dev/gvisor/pkg/tcpip/adapters/gonet \
        gvisor.dev/gvisor/pkg/tcpip/stack \
        github.com/coder/websocket \
        github.com/mdlayher/netlink

COPY tailscale/ ./
RUN --mount=type=cache,target=/go/pkg,sharing=locked \
    go build -o tailscaled -trimpath -buildvcs=false -tags ts_include_cli,ts_omit_aws,ts_omit_acme,ts_omit_bird,ts_omit_tap,ts_omit_portlist,ts_omit_resolved,ts_omit_captiveportal,ts_omit_kube,ts_omit_completion,ts_omit_completion_scripts,ts_omit_desktop_sessions,ts_omit_ssh,ts_omit_wakeonlan,ts_omit_capture,ts_omit_debugportmapper,ts_omit_portmapper,ts_omit_relayserver,ts_omit_serve,ts_omit_outboundproxy,ts_omit_bird,ts_omit_systray,ts_omit_syspolicy,ts_omit_taildrop,ts_omit_drive,ts_omit_tpm,ts_omit_doctor,ts_omit_dbus,ts_omit_capture,ts_omit_debugeventbus,ts_omit_webclient,ts_omit_linuxdnsfight,ts_omit_logtail -ldflags "-w -s -buildid=" ./cmd/tailscaled

# This is the final container
FROM alpine:3.23

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add wireguard-tools-wg-quick iptables ip6tables

ENV TS_TAILSCALED_EXTRA_ARGS="--no-logs-no-support --tun=userspace-networking" \
    TS_STATE_DIR=/var/lib/tailscale \
    TS_LOGIN_SERVER="https://controlplane.tailscale.com" \
    TS_AUTHKEY=¨¨ \
    TS_ACCEPT_ROUTES=False \
    TS_ADVERTISE_ROUTES="" \
    TS_VERBOSE="0" \
    TS_EXTRA_ARGS="--accept-dns=false --netfilter-mode=off" \
    WGTS_AUTO_ROUTE="False" \
    WGTS_TEST_HOST="example.com" \
    WGTS_TEST_PORT="443" \
    WGTS_ALWAYS_UP=False \
    WGTS_CHECK_INTERVAL=300 \
    WGTS_VERBOSE=False \
    WG_INTERFACE="wg0"

COPY --from=ts-build /go/src/tailscale/tailscaled /usr/sbin
RUN ln -s /usr/sbin/tailscaled /usr/bin/tailscale

# We use sysctl using docker, so we skip sysctl in wg-quick
RUN sed -i '/net\.ipv4\.conf\.all\.src_valid_mark/d' /usr/bin/wg-quick

COPY *.sh ./
COPY sysctl/ /etc/sysctl.d/
RUN chmod +x ./run.sh; chmod +x ./updatestate.sh

HEALTHCHECK --interval=10s --timeout=10s --start-period=5m --retries=3 CMD [ "grep", "-E", "^0$", "/tmp/wgts-status" ]
VOLUME /etc/wireguard/config
EXPOSE 41641/udp

ENTRYPOINT  ["./run.sh"]