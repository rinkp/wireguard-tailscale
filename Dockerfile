FROM golang:1.24-alpine3.22 AS ts-build
WORKDIR /go/src/tailscale

COPY tailscale/go.mod tailscale/go.sum ./
RUN go mod download

RUN go install \
    github.com/aws/aws-sdk-go-v2/aws \
    github.com/aws/aws-sdk-go-v2/config \
    gvisor.dev/gvisor/pkg/tcpip/adapters/gonet \
    gvisor.dev/gvisor/pkg/tcpip/stack \
    golang.org/x/crypto/ssh \
    golang.org/x/crypto/acme \
    github.com/coder/websocket \
    github.com/mdlayher/netlink

COPY tailscale/ ./
RUN go build -o tailscaled -tags ts_include_cli,ts_omit_aws,ts_omit_bird,ts_omit_tap,ts_omit_kube,ts_omit_completion,ts_omit_completion_scripts,ts_omit_desktop_sessions,ts_omit_ssh,ts_omit_wakeonlan,ts_omit_capture,ts_omit_relayserver,ts_omit_taildrop,ts_omit_tpm -ldflags "-w -s" ./cmd/tailscaled

# This is the final container
FROM alpine:3.22.0

RUN apk add --no-cache --update wireguard-tools-wg-quick iptables ip6tables

ENV TS_TAILSCALED_EXTRA_ARGS="--no-logs-no-support --tun=userspace-networking" \
    TS_STATE_DIR=/var/lib/tailscale \
    TS_LOGIN_SERVER="https://controlplane.tailscale.com" \
    TS_AUTHKEY=¨¨ \
    TS_ACCEPT_ROUTES=False \
    TS_ADVERTISE_ROUTES="" \
    TS_EXTRA_ARGS="--accept-dns=false --netfilter-mode=off" \
    WGTS_TEST_HOST="example.com" \
    WGTS_TEST_PORT="443" \
    WGTS_ALWAYS_UP=False \
    WGTS_CHECK_INTERVAL=300 \
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