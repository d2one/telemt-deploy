#!/usr/bin/env bash
# Render all per-host configs from a single instance file (instances/<host>.env)
# into deploy/.generated/<host>/ (gitignored). The generated files are what
# docker compose mounts. Re-run whenever the instance .env changes.
#
#   ./render.sh <instance-name>     # e.g. ./render.sh chained
#
# This is the whole point of the single-folder layout: every per-host value and
# secret lives in ONE ini-style file; telemt.toml / nginx.conf / panel.toml /
# .htpasswd / regru.ini are generated, never hand-edited.
set -euo pipefail

HOST="${1:?usage: render.sh <instance-name>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/instances/$HOST.env"
[ -f "$ENVF" ] || { echo "render: no such instance file: $ENVF" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; . "$ENVF"; set +a

# required for every host
: "${DOMAIN:?set in instance env}" "${EGRESS:?direct|chained}" \
  "${USERS:?space-separated name:secret pairs}" "${API_TOKEN:?}" \
  "${PANEL_BASE_PATH:?}" "${PANEL_ADMIN_USER:?}" "${PANEL_ADMIN_PASS_HASH:?}" \
  "${PANEL_JWT_SECRET:?}" "${PANEL_BASIC_USER:?}" "${PANEL_BASIC_PASS_HASH:?}" \
  "${CERT_EMAIL:?}" "${REGRU_USER:?}" "${REGRU_PASS:?}" >/dev/null
case "$EGRESS" in
  direct) ;;
  chained) : "${SS_URL:?required when EGRESS=chained}" >/dev/null ;;
  *) echo "render: EGRESS must be 'direct' or 'chained', got '$EGRESS'" >&2; exit 1 ;;
esac

GEN="$HERE/.generated/$HOST"
mkdir -p "$GEN"

# ---------------- telemt.toml ----------------
{
  cat <<EOF
# GENERATED from instances/$HOST.env by render.sh — DO NOT EDIT (edit the .env).
[general]
use_middle_proxy = false
# RST instead of FIN for unauthenticated connections (scanners, DPI probes) —
# frees kernel sockets instantly; authenticated sessions close gracefully.
rst_on_close = "errors"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
public_host = "$DOMAIN"
public_port = 443

[server]
port = 443

[server.api]
enabled = true
# Default whitelist is 127.0.0.0/8; the docker subnet lets the panel reach the API
# via host.docker.internal. The bearer token is the real gate.
whitelist = ["127.0.0.0/8", "172.16.0.0/12"]
auth_header = "Bearer $API_TOKEN"
EOF

  # Per-IP SYN limiter (V2 two-tier). Chained hosts always need burst staggering;
  # direct hosts can opt in with SYNLIMIT=1 when RU clients hit TSPU throttling.
  # V2 adds a separate iOS bucket (TTL<65, pktlen=64) with higher burst to
  # accommodate iOS Telegram's aggressive reconnect pattern.
  if [ "$EGRESS" = chained ] || [ "${SYNLIMIT:-0}" = 1 ]; then
    cat <<EOF

[[server.listeners]]
ip = "0.0.0.0"
port = 443
synlimit = "nftables"
synlimit_seconds = ${SYNLIMIT_SECONDS:-60}
synlimit_hitcount = ${SYNLIMIT_HITCOUNT:-48}
synlimit_burst = ${SYNLIMIT_BURST:-1}
synlimit_ios_seconds = ${SYNLIMIT_IOS_SECONDS:-1}
synlimit_ios_hitcount = ${SYNLIMIT_IOS_HITCOUNT:-12}
synlimit_ios_burst = ${SYNLIMIT_IOS_BURST:-24}
EOF
  fi

  cat <<EOF

[censorship]
tls_domain = "$DOMAIN"
# Reject unknown SNI with TLS alert (like nginx ssl_reject_handshake) instead of
# silent drop — looks like a normal web server to DPI active probes.
unknown_sni_action = "reject_handshake"
mask_host = "127.0.0.1"
mask_port = 8443
EOF
  [ "$EGRESS" = chained ] && echo 'tls_fetch_scope = "mask"'
  cat <<EOF
# Raised so the admin panel (mask-relayed behind the storefront) keeps long-lived
# sessions/websockets alive. Affects only the mask path, not Telegram proxying.
mask_relay_timeout_ms = 1800000
mask_relay_idle_timeout_ms = 60000

[access.users]
EOF
  for u in $USERS; do printf '%s = "%s"\n' "${u%%:*}" "${u#*:}"; done

  # Egress routing — chained sends DC traffic through the Shadowsocks exit.
  if [ "$EGRESS" = chained ]; then
    cat <<EOF

[[upstreams]]
type = "direct"
scopes = "mask"

[[upstreams]]
type = "shadowsocks"
url = "$SS_URL"
EOF
  fi
} > "$GEN/telemt.toml"

# ---------------- panel.toml ----------------
cat > "$GEN/panel.toml" <<EOF
# GENERATED from instances/$HOST.env by render.sh — DO NOT EDIT (edit the .env).
listen = "0.0.0.0:8080"
base_path = "$PANEL_BASE_PATH"

[telemt]
url = "http://host.docker.internal:9091"
auth_header = "Bearer $API_TOKEN"
container_name = "telemt"
config_path = "/etc/telemt/telemt.toml"

[auth]
username = "$PANEL_ADMIN_USER"
password_hash = "$PANEL_ADMIN_PASS_HASH"
jwt_secret = "$PANEL_JWT_SECRET"
session_ttl = "24h"
EOF

# ---------------- nginx.conf ----------------
sed -e "s#__DOMAIN__#$DOMAIN#g" -e "s#__PANEL_PATH__#$PANEL_BASE_PATH#g" \
  "$HERE/templates/nginx.conf.tmpl" > "$GEN/nginx.conf"

# ---------------- nginx .htpasswd ----------------
printf '%s:%s\n' "$PANEL_BASIC_USER" "$PANEL_BASIC_PASS_HASH" > "$GEN/.htpasswd"

# ---------------- certbot regru.ini ----------------
cat > "$GEN/regru.ini" <<EOF
dns_username = $REGRU_USER
dns_password = $REGRU_PASS
EOF
chmod 600 "$GEN/regru.ini"

echo "render: wrote $GEN/{telemt.toml,panel.toml,nginx.conf,.htpasswd,regru.ini}  (EGRESS=$EGRESS)"
