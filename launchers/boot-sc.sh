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

# ---- Pisound JACK parameters ----
# Adjust PISOUND_CARD if your pisound registers under a different name.
# Check with:  aplay -l | grep -i pisound
PISOUND_CARD="pisound"
JACK_RATE=48000
JACK_PERIOD=128
JACK_NPERIODS=3

# ---- 1. Ensure Jack is running and connectable ----
# First check if Jack is actually connectable (not just if the process exists).
# A stale/zombie jackd process will pass pgrep but fail jack_lsp.
if jack_lsp > /dev/null 2>&1; then
    echo "[boot-sc] Jack already running and connectable, skipping start."
else
    # Kill any stale jackd before starting fresh
    if pgrep -x jackd > /dev/null; then
        echo "[boot-sc] Stale jackd found — killing before restart..."
        pkill -x jackd || true
        sleep 1
    fi
    echo "[boot-sc] Starting jackd on $PISOUND_CARD..."
    jackd -d alsa -d hw:"$PISOUND_CARD" -r "$JACK_RATE" -p "$JACK_PERIOD" -n "$JACK_NPERIODS" &
    JACKD_PID=$!
    echo "[boot-sc] jackd started (PID: $JACKD_PID)"
fi

# ---- 2. Wait for Jack to be ready ----
echo "[boot-sc] Waiting for Jack to become available..."
JACK_TIMEOUT=15
JACK_ELAPSED=0
until jack_lsp > /dev/null 2>&1; do
    if [[ $JACK_ELAPSED -ge $JACK_TIMEOUT ]]; then
        echo "[boot-sc] ERROR: Jack did not become ready within ${JACK_TIMEOUT}s. Aborting."
        exit 1
    fi
    sleep 1
    JACK_ELAPSED=$((JACK_ELAPSED + 1))
done
echo "[boot-sc] Jack is ready (waited ${JACK_ELAPSED}s)."

# ---- 3. Checkout prod branch ----
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
