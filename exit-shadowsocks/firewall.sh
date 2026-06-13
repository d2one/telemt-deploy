#!/bin/sh
# Restrict the Shadowsocks exit port to the front server only (defense-in-depth
# on top of the SS key). Idempotent: safe to re-run. DOCKER-USER is recreated by
# Docker on restart/boot, so this re-applies the allowlist after docker starts.
# Reads SS_PORT / ALLOW_IP from the .env next to this script.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/.env"
PORT="${SS_PORT:?}"
ALLOW="${ALLOW_IP:?}"

# wipe existing rules for this port
iptables -S DOCKER-USER | grep -- "--dport $PORT " | sed 's/^-A/-D/' | while read -r rule; do
  iptables $rule 2>/dev/null || true
done
# re-add: loopback + front allowed, rest dropped (insertion order => ACCEPTs first)
iptables -I DOCKER-USER -p tcp --dport "$PORT" -j DROP
iptables -I DOCKER-USER -p tcp --dport "$PORT" -s "$ALLOW" -j ACCEPT
iptables -I DOCKER-USER -p tcp --dport "$PORT" -s 127.0.0.1 -j ACCEPT
