FROM dhi.io/golang:1.26.4-alpine3.24 AS ts-build
WORKDIR /go/src/tailscale

ENV GOCACHE=/go-cache \
    GOMODCACHE=/go-modcache

COPY tailscale/go.mod tailscale/go.sum ./
RUN --mount=type=cache,target=/go-cache,sharing=locked,uid=65532 \
    --mount=type=cache,target=/go-modcache,sharing=locked,uid=65532 \
    go mod download && \
    go install \
        gvisor.dev/gvisor/pkg/tcpip/adapters/gonet \
        gvisor.dev/gvisor/pkg/tcpip/stack \
        github.com/coder/websocket \
        github.com/mdlayher/netlink

COPY tailscale/ ./
RUN --mount=type=cache,target=/go-cache,sharing=locked,uid=65532 \
    --mount=type=cache,target=/go-modcache,sharing=locked,uid=65532 \
    go build -o tailscaled -trimpath -buildvcs=false -tags "\
        ts_include_cli \
        ts_omit_ace \
        ts_omit_acme \
        ts_omit_appconnectors \
        ts_omit_aws \
        ts_omit_bakedroots \
        ts_omit_bird \
        ts_omit_cachenetmap \
        ts_omit_captiveportal \
        ts_omit_capture \
        ts_omit_cliconndiag \
        ts_omit_clientupdate \
        ts_omit_cloud \
        ts_omit_completion \
        ts_omit_completion_scripts \
        ts_omit_conn25 \
        ts_omit_dbus \
        ts_omit_debug \
        ts_omit_debugeventbus \
        ts_omit_debugportmapper \
        ts_omit_desktop_sessions \
        ts_omit_doctor \
        ts_omit_drive \
        ts_omit_hujsonconf \
        ts_omit_ipnbus \
        ts_omit_kube \
        ts_omit_linkspeed \
        ts_omit_linuxdnsfight \
        ts_omit_logtail \
        ts_omit_netlog \
        ts_omit_networkmanager \
        ts_omit_outboundproxy \
        ts_omit_portlist \
        ts_omit_portmapper \
        ts_omit_posture \
        ts_omit_qrcodes \
        ts_omit_relayserver \
        ts_omit_resolved \
        ts_omit_sdnotify \
        ts_omit_serve \
        ts_omit_ssh \
        ts_omit_synology \
        ts_omit_syspolicy \
        ts_omit_systray \
        ts_omit_taildrop \
        ts_omit_tap \
        ts_omit_tpm \
        ts_omit_tundevstats \
        ts_omit_useproxy \
        ts_omit_usermetrics \
        ts_omit_useexitnode \
        ts_omit_useroutes \
        ts_omit_wakeonlan \
        ts_omit_webbrowser \
        ts_omit_webclient" \
        -ldflags "-w -s -buildid=" ./cmd/tailscaled

# Use apk.static from the alpine dev image to install packages in the final image
# Verified working: https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/apk-tools-static-3.0.6-r0.apk
FROM dhi.io/alpine-base:3.24-alpine3.24-dev AS ts-apk
RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk --no-cache fetch apk-tools-static && \
    tar -zxvf apk-tools-static-*.apk

# This is the final container
FROM dhi.io/alpine-base:3.24

USER 0

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    --mount=type=tmpfs,target=/var/log \
    --mount=type=bind,target=/sbin/apk.static,from=ts-apk,source=/sbin/apk.static \
    sed -i '/^https:\/\/dhi.io/! s/./#&/' /etc/apk/repositories && \
    apk.static add wireguard-tools-wg-quick iptables jq

ENV TS_TAILSCALED_EXTRA_ARGS="--no-logs-no-support --tun=userspace-networking" \
    TS_STATE_DIR=/var/lib/tailscale \
    TS_LOGIN_SERVER="https://controlplane.tailscale.com" \
    TS_AUTHKEY=¨¨ \
    TS_ACCEPT_ROUTES=False \
    TS_ADVERTISE_ROUTES="" \
    TS_VERBOSE=0 \
    TS_EXTRA_ARGS="--accept-dns=false" \
    WGTS_AUTO_ROUTE="False" \
    WGTS_TEST_HOST="example.com" \
    WGTS_TEST_PORT="443" \
    WGTS_ALLOW_SHARED_ADDRESS_ROUTING=False \
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