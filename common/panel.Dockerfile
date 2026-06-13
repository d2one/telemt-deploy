# telemt_panel (https://github.com/amirotin/telemt_panel) — web admin panel for telemt.
# Mirrors common/Dockerfile: downloads the release binary for the host arch.
# Pinned via PANEL_VERSION (.env). Runs on plain HTTP bound to 127.0.0.1; TLS is
# terminated by the masking nginx, which reverse-proxies a secret base_path to it.
FROM debian:bookworm-slim

ARG PANEL_VERSION=latest

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl jq && \
    ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) ASSET_ARCH="x86_64" ;; \
      arm64) ASSET_ARCH="aarch64" ;; \
      *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    if [ "$PANEL_VERSION" = "latest" ]; then \
      DOWNLOAD_URL=$(curl -s https://api.github.com/repos/amirotin/telemt_panel/releases/latest \
        | jq -r ".assets[] | select(.name == \"telemt-panel-${ASSET_ARCH}-linux-gnu.tar.gz\") | .browser_download_url"); \
    else \
      DOWNLOAD_URL="https://github.com/amirotin/telemt_panel/releases/download/${PANEL_VERSION}/telemt-panel-${ASSET_ARCH}-linux-gnu.tar.gz"; \
    fi && \
    curl -fSL "$DOWNLOAD_URL" -o /tmp/panel.tar.gz && \
    tar -xzf /tmp/panel.tar.gz -C /usr/local/bin/ && \
    mv "/usr/local/bin/telemt-panel-${ASSET_ARCH}-linux" /usr/local/bin/telemt-panel && \
    chmod +x /usr/local/bin/telemt-panel && \
    rm /tmp/panel.tar.gz && \
    apt-get purge -y curl jq && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

EXPOSE 8080

ENTRYPOINT ["telemt-panel"]
CMD ["--config", "/etc/telemt-panel/config.toml"]
