#!/bin/bash
# ============================================================
# boot-sc.sh — System boot wrapper for the SC granular patch
# ============================================================
# Responsibilities:
#   1. Ensure Jack is running on pisound (starts it if not)
#   2. git checkout prod  (local only — Pi is the remote)
#   3. exec run-sc-main_granular.sh  (hands off PID to systemd)
#
# Deployed to: /usr/local/sc-patches/boot-sc.sh
# Called by:   sc-boot.service (systemd)
# ============================================================

set -e

REPO="/usr/local/sc-patches/sc-store"
GRANULAR_LAUNCHER="$REPO/run-sc-main_granular.sh"

# ---- 1. Checkout prod branch ----
echo "[boot-sc] Checking out prod branch in $REPO..."
git -C "$REPO" checkout prod
echo "[boot-sc] On branch: $(git -C "$REPO" branch --show-current)"

# ---- 4. Hand off to granular launcher ----
if [[ ! -x "$GRANULAR_LAUNCHER" ]]; then
    echo "[boot-sc] ERROR: $GRANULAR_LAUNCHER not found or not executable."
    exit 1
fi

echo "[boot-sc] Launching $GRANULAR_LAUNCHER..."
exec "$GRANULAR_LAUNCHER"
