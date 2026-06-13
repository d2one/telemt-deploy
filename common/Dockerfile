FROM debian:bookworm-slim

ARG TELEMT_VERSION=latest

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl jq && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) ASSET_ARCH="x86_64" ;; \
      arm64) ASSET_ARCH="aarch64" ;; \
      *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    if [ "$TELEMT_VERSION" = "latest" ]; then \
      DOWNLOAD_URL=$(curl -s https://api.github.com/repos/telemt/telemt/releases/latest \
        | jq -r ".assets[] | select(.name == \"telemt-${ASSET_ARCH}-linux-gnu.tar.gz\") | .browser_download_url"); \
    else \
      DOWNLOAD_URL="https://github.com/telemt/telemt/releases/download/${TELEMT_VERSION}/telemt-${ASSET_ARCH}-linux-gnu.tar.gz"; \
    fi && \
    curl -fSL "$DOWNLOAD_URL" -o /tmp/telemt.tar.gz && \
    tar -xzf /tmp/telemt.tar.gz -C /usr/bin/ && \
    chmod +x /usr/bin/telemt && \
    rm /tmp/telemt.tar.gz && \
    apt-get purge -y curl jq && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Runtime netfilter tooling for telemt's built-in per-listener SYN limiter
# ([[server.listeners]] synlimit=...). telemt shells out to these binaries to
# install/reconcile the per-source token-bucket rule, so they must be on PATH;
# it also needs cap_add: NET_ADMIN at runtime. nftables is the backend we use;
# iptables/ip6tables kept for the alternative synlimit="iptables" backend.
RUN apt-get update && \
    apt-get install -y --no-install-recommends nftables iptables && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/telemt/cache /opt/telemt/tlsfront /etc/telemt

WORKDIR /opt/telemt

EXPOSE 443

ENTRYPOINT ["/usr/bin/telemt"]
CMD ["/etc/telemt/telemt.toml"]
