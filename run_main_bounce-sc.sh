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

# 3. Start the SuperCollider script
# Define the path to your main.scd script
SCLANG_SCRIPT="/usr/local/sc-patches/sc-store/main_bounce.scd"

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

# Optional: Exit the script
exit 0

