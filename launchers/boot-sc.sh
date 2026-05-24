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

# ---- 1. Checkout requested branch ----
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
