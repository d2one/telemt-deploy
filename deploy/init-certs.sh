#!/usr/bin/env bash
# First-time TLS bootstrap for one instance: dummy cert -> nginx -> real cert via
# reg.ru DNS-01 -> restart nginx. The host's public IP must be whitelisted in the
# reg.ru API settings first.
#
#   ./init-certs.sh <instance>        # e.g. ./init-certs.sh chained
set -euo pipefail

HOST="${1:?usage: ./init-certs.sh <instance>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENVF="$ROOT/instances/$HOST.env"
[ -f "$ENVF" ] || { echo "no instance file: $ENVF" >&2; exit 1; }

"$HERE/render.sh" "$HOST"
set -a; . "$ENVF"; set +a
export HOST
cd "$HERE"
compose() { docker compose "$@"; }

echo "==> Creating dummy certificate for nginx bootstrap (${DOMAIN})..."
compose run --rm --entrypoint "" certbot sh -c "
  mkdir -p /etc/letsencrypt/live/${DOMAIN} &&
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout /etc/letsencrypt/live/${DOMAIN}/privkey.pem \
    -out /etc/letsencrypt/live/${DOMAIN}/fullchain.pem \
    -subj '/CN=${DOMAIN}'
"

echo "==> Starting nginx with dummy cert..."
compose up -d nginx

echo "==> Removing dummy certificate before real issuance..."
compose run --rm --entrypoint "" certbot sh -c "
  rm -rf /etc/letsencrypt/live/${DOMAIN} \
         /etc/letsencrypt/archive/${DOMAIN} \
         /etc/letsencrypt/renewal/${DOMAIN}.conf
"

echo "==> Requesting real certificate via DNS-01 (reg.ru)..."
compose run --rm --entrypoint "" certbot \
  certbot certonly -a dns -d "${DOMAIN}" --email "${CERT_EMAIL}" \
    --agree-tos --no-eff-email -n --dns-propagation-seconds 300

echo "==> Restarting nginx with real cert..."
compose restart nginx
echo "==> Done. Bring everything up:  make up HOST=${HOST}"
