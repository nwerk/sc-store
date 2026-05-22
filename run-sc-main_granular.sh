#!/bin/bash
. /usr/local/pisound/scripts/common/common.sh

flash_leds 1000

# Set Qt to use the 'offscreen' platform plugin
export QT_QPA_PLATFORM=offscreen

# Set DISPLAY if necessary
export DISPLAY=:0

# Description:
# This script kills all running instances of SuperCollider and Pure Data (Pd),
# then starts a SuperCollider script located at /usr/local/sc-patches/FFT-FX/main.scd using sclang.
# It also handles Ctrl+C to terminate the sclang process gracefully.

# Exit immediately if a command exits with a non-zero status.
set -e

# Function to kill processes by name
kill_processes() {
    local process_name="$1"
    if pgrep -x "$process_name" > /dev/null; then
        echo "Killing all instances of $process_name..."
        pkill -x "$process_name"
        echo "$process_name terminated."
    else
        echo "No running instances of $process_name found."
    fi
}

# Function to handle cleanup on exit
cleanup() {
    echo ""
    echo "Interrupt received. Cleaning up..."
    if [[ -n "$SCLANG_PID" ]]; then
        echo "Terminating sclang (PID: $SCLANG_PID)..."
        kill "$SCLANG_PID" 2>/dev/null || echo "sclang already terminated."
    fi

    # Restore pisound JACK if we switched away from it
    if [[ "${SCARLETT_JACK_STARTED:-0}" -eq 1 ]]; then
        echo "Stopping Scarlett JACK and restoring pisound JACK..."
        sudo pkill -x jackd 2>/dev/null || true
        sleep 1
        # Restart the JACK systemd service if it exists, otherwise let pisound handle it
        if systemctl list-unit-files jack.service &>/dev/null || systemctl list-unit-files jackd.service &>/dev/null; then
            sudo systemctl start jack jackd 2>/dev/null || true
        elif command -v jack_control &>/dev/null; then
            jack_control start 2>/dev/null || true
        fi
        echo "Pisound JACK restored."
    fi

    exit 1
}

# Trap SIGINT (Ctrl+C) and call cleanup
trap cleanup SIGINT

# 1. Kill all SuperCollider instances
kill_processes "sclang"
kill_processes "scsynth"

# 2. Kill all Pure Data (Pd) instances
kill_processes "pd"

# Optional: Wait a moment to ensure processes have terminated
sleep 1

# 2.5. Detect Scarlett 2i2 and switch JACK to it if present
# Track whether we started a custom JACK session so we can restore it on exit
SCARLETT_JACK_STARTED=0

SCARLETT_LINE=$(aplay -l 2>/dev/null | grep -i "scarlett" | head -n 1)
if [[ -n "$SCARLETT_LINE" ]]; then
    SCARLETT_CARD=$(echo "$SCARLETT_LINE" | sed 's/^card \([0-9]*\):.*/\1/')
    echo "Scarlett 2i2 found on card $SCARLETT_CARD, switching JACK to hw:$SCARLETT_CARD..."

    # Stop any JACK session: try systemd service first, then fall back to pkill
    if systemctl is-active --quiet jack || systemctl is-active --quiet jackd; then
        echo "Stopping JACK systemd service..."
        sudo systemctl stop jack jackd 2>/dev/null || true
    fi
    # Also stop jack_control if present
    if command -v jack_control &>/dev/null; then
        jack_control stop 2>/dev/null || true
        sleep 0.5
    fi
    # Kill any remaining jackd processes
    sudo pkill -x jackd 2>/dev/null || true
    sleep 1
    # Clean up stale JACK shared memory and semaphores
    sudo rm -f /dev/shm/jack_* 2>/dev/null || true
    sudo rm -f /tmp/jack_* 2>/dev/null || true
    # Avoid audio device reservation via session bus (prevents dbus/X11 autolaunch errors)
    export JACK_NO_AUDIO_RESERVATION=1
    # Ensure XDG_RUNTIME_DIR is set (avoids related warnings)
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
    # Start JACK on the Scarlett card
    jackd -d alsa -d hw:"$SCARLETT_CARD" -r 48000 -p 256 -n 2 &
    JACK_PID=$!
    echo "JACK started on Scarlett 2i2 (PID: $JACK_PID)."
    SCARLETT_JACK_STARTED=1

    # Wait until JACK is actually ready (up to 10 seconds)
    echo "Waiting for JACK to become ready..."
    JACK_READY=0
    for i in $(seq 1 20); do
        if jack_lsp &>/dev/null; then
            echo "JACK is ready."
            JACK_READY=1
            break
        fi
        sleep 0.5
    done
    if [[ "$JACK_READY" -eq 0 ]]; then
        echo "Warning: JACK did not become ready in time. SuperCollider may not connect to Scarlett."
    fi
else
    echo "Scarlett 2i2 not found, using pisound via existing JACK."
fi

# 3. Start the SuperCollider script
# Define the path to your main.scd script
SCLANG_SCRIPT="/usr/local/sc-patches/sc-store/main_grain.scd"

# Check if the script exists
if [[ ! -f "$SCLANG_SCRIPT" ]]; then
    echo "Error: SuperCollider script '$SCLANG_SCRIPT' not found."
    exit 1
fi

echo "Starting SuperCollider script: $SCLANG_SCRIPT"
# Start sclang with the script in the background
sclang "$SCLANG_SCRIPT" &
SCLANG_PID=$!

echo "SuperCollider script started successfully with PID: $SCLANG_PID."

# Wait for the sclang process to finish
wait "$SCLANG_PID"

# Restore pisound JACK if we switched to Scarlett
if [[ "${SCARLETT_JACK_STARTED:-0}" -eq 1 ]]; then
    echo "SuperCollider exited. Stopping Scarlett JACK and restoring pisound JACK..."
    sudo pkill -x jackd 2>/dev/null || true
    sleep 1
    if systemctl list-unit-files jack.service &>/dev/null || systemctl list-unit-files jackd.service &>/dev/null; then
        sudo systemctl start jack jackd 2>/dev/null || true
    elif command -v jack_control &>/dev/null; then
        jack_control start 2>/dev/null || true
    fi
    echo "Pisound JACK restored."
fi

# Optional: Exit the script
exit 0

