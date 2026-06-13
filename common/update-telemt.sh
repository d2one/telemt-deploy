#!/usr/bin/env bash
# Auto-update telemt to the latest GitHub release for one instance.
#
#   update-telemt.sh <instance>        # e.g. update-telemt.sh chained
#
# Reads TELEMT_VERSION from instances/<instance>.env. If a newer release exists:
# bumps the version line, re-renders configs, rebuilds + recreates the telemt
# container, then health-checks it (running + not restart-looping). On any failure
# it rolls the version back and rebuilds. No-op when already up to date.
# Set TELEMT_HOLD=1 in the instance env to pin (skip auto-update).
#
# Driven by systemd (common/systemd/telemt-update.{service,timer}) or `make update`.
set -euo pipefail

HOST="${1:-${HOST:-}}"
[ -n "$HOST" ] || { echo "usage: update-telemt.sh <instance>  (or HOST=<instance>)" >&2; exit 1; }

SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"
DEPLOY="$ROOT/deploy"
ENV_FILE="$ROOT/instances/$HOST.env"
SERVICE="telemt"; CONTAINER="telemt"
GH_API="https://api.github.com/repos/telemt/telemt/releases/latest"
HEALTH_WAIT="${HEALTH_WAIT:-20}"

log() { echo "[$(date -Is)] telemt-update($HOST): $*"; }

if [ ! -f "$ENV_FILE" ] || ! grep -q '^TELEMT_VERSION=' "$ENV_FILE"; then
  log "TELEMT_VERSION not found in $ENV_FILE; aborting."; exit 1
fi
CURRENT="$(grep '^TELEMT_VERSION=' "$ENV_FILE" | head -n1 | cut -d= -f2)"

# Hold: pin this instance at its current version (set when a release is known-broken).
if grep -qiE '^TELEMT_HOLD=(1|true|yes)$' "$ENV_FILE"; then
  log "TELEMT_HOLD set; holding at $CURRENT (auto-update skipped)."; exit 0
fi

LATEST="$(curl -fsSL "$GH_API" | jq -r '.tag_name')"
[ -n "$LATEST" ] && [ "$LATEST" != "null" ] || { log "Could not fetch latest tag; aborting."; exit 1; }

log "current=$CURRENT latest=$LATEST"
[ "$CURRENT" = "$LATEST" ] && { log "Already up to date."; exit 0; }
log "Updating $CURRENT -> $LATEST"

cd "$DEPLOY"
# render + run compose with the instance env exported (so ${HOST}/${*_VERSION} resolve)
apply() { "$DEPLOY/render.sh" "$HOST" >/dev/null; set -a; . "$ENV_FILE"; set +a; HOST="$HOST" docker compose "$@"; }

rollback() {
  log "Rolling back to $CURRENT"
  sed -i "s/^TELEMT_VERSION=.*/TELEMT_VERSION=$CURRENT/" "$ENV_FILE"
  apply build "$SERVICE" && apply up -d "$SERVICE" || log "WARNING: rollback rebuild failed — manual intervention needed!"
}

sed -i "s/^TELEMT_VERSION=.*/TELEMT_VERSION=$LATEST/" "$ENV_FILE"
apply build "$SERVICE"  || { log "Build failed.";    rollback; exit 1; }
apply up -d "$SERVICE"  || { log "Recreate failed."; rollback; exit 1; }

sleep "$HEALTH_WAIT"
RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)"
RESTARTING="$(docker inspect -f '{{.State.Restarting}}' "$CONTAINER" 2>/dev/null || echo true)"
if [ "$RUNNING" != "true" ] || [ "$RESTARTING" = "true" ]; then
  log "Container unhealthy after update (running=$RUNNING restarting=$RESTARTING)."
  apply logs --tail=30 "$SERVICE" || true
  rollback; exit 1
fi

log "Update to $LATEST successful."
