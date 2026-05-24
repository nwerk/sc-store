#!/bin/bash
# ============================================================
# boot-sc.sh — SC multi patch launcher
# ============================================================
# Usage:  boot-sc.sh [branch]
#   branch  git branch to checkout before launching (default: prod)
#
# Called by sc-boot.service (systemd) and pisound button scripts.
# ============================================================

set -e

# Source pisound common helpers
. /usr/local/pisound/scripts/common/common.sh

REPO="/usr/local/sc-patches/sc-store"
MULTI_LAUNCHER="$REPO/run-sc-main_multi.sh"
BRANCH="${1:-prod}"

# ---- 0. Stop systemd service if it is running and we are not it ----
# When called by a button script, killing sclang would cause the service's
# run-sc-main_multi.sh to exit non-zero, triggering Restart=on-failure and
# respawning sclang immediately. Stopping the service first prevents that.
_SERVICE_PID=$(systemctl show sc-boot.service --property=MainPID --value 2>/dev/null || echo "0")
if [[ "$_SERVICE_PID" != "0" && "$_SERVICE_PID" != "$$" ]]; then
    echo "[boot-sc] Stopping sc-boot.service (PID: $_SERVICE_PID)..."
    systemctl stop sc-boot.service || true
    sleep 2
fi

# ---- 1. Kill any running SuperCollider instances ----
for proc in sclang scsynth; do
    if pgrep -x "$proc" > /dev/null; then
        echo "[boot-sc] Killing existing $proc..."
        pkill -x "$proc"
        sleep 1
    fi
done

# ---- 2. Checkout requested branch ----
echo "[boot-sc] Checking out $BRANCH in $REPO..."
git -C "$REPO" checkout "$BRANCH"
echo "[boot-sc] On branch: $(git -C "$REPO" branch --show-current)"

# ---- 4. Hand off to multi launcher ----
if [[ ! -x "$MULTI_LAUNCHER" ]]; then
    echo "[boot-sc] ERROR: $MULTI_LAUNCHER not found or not executable."
    exit 1
fi

echo "[boot-sc] Launching $MULTI_LAUNCHER..."
exec "$MULTI_LAUNCHER"
