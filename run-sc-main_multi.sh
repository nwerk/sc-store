#!/bin/bash
# ============================================================
# run-sc-main_multi.sh — start main_multi.scd (Pi and laptop)
# ============================================================
# Kills running SuperCollider / Pd instances, makes sure JACK runs on the right audio interface, tells the
# patch where the TouchOSC tablet is (TOUCHOSC_IP) and starts main_multi.scd with sclang. Ctrl+C stops it.
# While the patch runs, the tablet layout of this checkout is served at http://<this machine>:8080/main.tosc
# (UI_HTTP_PORT, 0 = off): open it in the tablet's browser to load the matching layout into TouchOSC.
#
#   ./run-sc-main_multi.sh
#   TOUCHOSC_IP=192.168.0.50 ./run-sc-main_multi.sh     # settings already in the environment win
#
# Pi (detected by its pisound install): if a Focusrite interface (Scarlett, Clarett, ...) is connected, the
#   pisound JACK service is replaced by jackd on the Focusrite and restored on exit; otherwise the running
#   pisound JACK is used. Called by launchers/boot-sc.sh (sc-boot.service, pisound button).
#   The CPU governor is set to `performance` (CPU_GOVERNOR, empty = leave it) and under-voltage / throttling
#   reported by the firmware is printed at start and exit.
# Any other Linux machine (laptop): a JACK server that is already running is used as it is. Otherwise jackd is
#   started on JACK_DEVICE (default: the Focusrite if connected, else the built-in card) and stopped on exit.
# ============================================================

# ---- Where am I? ----
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCLANG_SCRIPT="$REPO/main_multi.scd"

PISOUND_COMMON=/usr/local/pisound/scripts/common/common.sh
if [[ -f "$PISOUND_COMMON" ]]; then
    ON_PI=1
    . "$PISOUND_COMMON"
else
    ON_PI=0
fi

# ============================================================
# MACHINE SETTINGS
# ============================================================
if [[ "$ON_PI" -eq 1 ]]; then
    : "${TOUCHOSC_IP:=172.24.1.107}"    # tablet on the Pi's hotspot
else
    : "${TOUCHOSC_IP:=192.168.0.110}"   # tablet on the home network
    : "${JACK_DEVICE:=}"                # ALSA device, e.g. hw:USB; empty = Focusrite if connected, else hw:0
    # 128 samples = 2.7 ms per period, about 5 ms less from guitar to speaker than 256. The laptop has the CPU for it;
    # if it crackles (xruns in the PERF_LOG=1 lines), go back with JACK_PERIOD=256 ./run-sc-main_multi.sh
    : "${JACK_PERIOD:=128}"
fi
: "${JACK_RATE:=48000}"                 # must match s.options.sampleRate in config/serversetup.scd
: "${JACK_PERIOD:=256}"                 # Pi: 256 samples = 5.3 ms per period (must be a multiple of scsynth's
                                        # blockSize, 64, config/serversetup.scd)
: "${JACK_NPERIODS:=2}"
: "${UI_HTTP_PORT:=8080}"               # serves ui/main.tosc to the tablet; 0 = off
if [[ "$ON_PI" -eq 1 ]]; then
    : "${CPU_GOVERNOR=performance}"     # Pi: CPU frequency governor while the patch runs; empty = leave it alone
fi
: "${SC_SERVER:=scsynth}"              # scsynth (one core) or supernova (several cores; package supercollider-supernova)
export SC_SERVER                        # read by config/serversetup.scd
export TOUCHOSC_IP                      # read by osc/oscconfig_multi.scd
export UI_HTTP_PORT                     # read by osc/ui_version.scd (for its hints)
# ============================================================

if [[ "$ON_PI" -eq 1 ]]; then
    flash_leds 1000
    # Headless: Qt offscreen (no s.meter window)
    export QT_QPA_PLATFORM=offscreen
    export DISPLAY=:0
fi

# Exit immediately if a command exits with a non-zero status.
set -e

# Stops every process with this exact name. One started by another user (the pisound button, a manual sudo) cannot
# be killed by a plain pkill; then it is tried with sudo -n (no password prompt), and SIGKILL if SIGTERM was not
# enough. Returns 1, with a message naming the owner, if the process is still there: a second patch must not start
# next to it (it would not get the OSC port and the audio interface).
stop_process() {
    local name="$1" i
    pgrep -x "$name" > /dev/null || return 0
    echo "Stopping $name ($(ps -o user=,pid= -C "$name" | awk '{printf "%s%s pid %s", (NR > 1 ? ", " : ""), $1, $2}'))..."
    pkill -x "$name" 2>/dev/null || sudo -n pkill -x "$name" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$name" > /dev/null || return 0
        sleep 0.5
    done
    pkill -9 -x "$name" 2>/dev/null || sudo -n pkill -9 -x "$name" 2>/dev/null || true
    sleep 0.5
    pgrep -x "$name" > /dev/null || return 0
    echo "Error: cannot stop $name ($(ps -o user=,pid= -C "$name" | awk '{printf "%s%s pid %s", (NR > 1 ? ", " : ""), $1, $2}')); it belongs to another user. Stop it by hand: sudo pkill -x $name"
    return 1
}

# ---- CPU (Pi) ----
# The audio load comes in short bursts (one block every few ms). A governor that scales the clock with the load
# (ondemand, schedutil) sees a mostly idle CPU, clocks down, and each burst then takes several times longer:
# dropouts at a low average load. Pin the clock to its maximum while the patch runs. Not undone on exit.
set_cpu_governor() {
    local want="$1" g changed=0 failed=0
    [[ -z "$want" ]] && return 0
    for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -r "$g" ]] || continue
        [[ "$(cat "$g")" == "$want" ]] && continue
        if echo "$want" | sudo -n tee "$g" >/dev/null 2>&1; then changed=1; else failed=1; fi
    done
    if [[ "$failed" -eq 1 ]]; then
        echo "Warning: could not set the CPU governor to '$want' (now: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)). Expect dropouts under load."
    elif [[ "$changed" -eq 1 ]]; then
        echo "CPU governor set to '$want'."
    fi
}

# Under-voltage or overheating make the Pi's firmware lower the clock, which sounds like an overloaded patch.
# Bits of `vcgencmd get_throttled`: 0x1 under-voltage, 0x2 frequency capped, 0x4 throttled (now);
# 0x10000 / 0x20000 / 0x40000 the same, at some time since boot.
report_pi_throttling() {
    local raw val msg=""
    command -v vcgencmd &>/dev/null || return 0
    raw=$(vcgencmd get_throttled 2>/dev/null) || return 0
    val=$(( ${raw#*=} )) 2>/dev/null || return 0
    [[ "$val" -eq 0 ]] && return 0
    (( val & 0x1 ))     && msg+=" under-voltage NOW;"
    (( val & 0x2 ))     && msg+=" CPU frequency capped NOW;"
    (( val & 0x4 ))     && msg+=" CPU throttled NOW;"
    (( val & 0x10000 )) && msg+=" under-voltage since boot;"
    (( val & 0x20000 )) && msg+=" frequency capped since boot;"
    (( val & 0x40000 )) && msg+=" throttled since boot;"
    echo "Warning ($1): the Pi reports$msg check the power supply and cooling ($raw)."
}

# ---- JACK handling ----
SCARLETT_JACK_STARTED=0   # Pi: we replaced the pisound JACK with jackd on the Focusrite
DESKTOP_JACK_STARTED=0    # laptop: we started jackd ourselves
JACK_PID=""

# card number of the first connected Focusrite interface (empty if none).
# /proc/asound/cards lists every card as a header line " 1 [USB  ]: USB-Audio - Scarlett 2i2 USB" followed by
# its long name "Focusrite Scarlett 2i2 USB at usb-..."; either line may carry the name, depending on the model.
FOCUSRITE_PATTERN="focusrite|scarlett|clarett"
focusrite_card() {
    local card
    card=$(awk -v pat="$FOCUSRITE_PATTERN" '
        /^ *[0-9]+ \[/ { n = $1 }
        tolower($0) ~ pat { print n; exit }' /proc/asound/cards 2>/dev/null)
    if [[ -z "$card" ]]; then
        # fallback: ALSA's own listing
        card=$(LANG=C aplay -l 2>/dev/null | grep -iE "$FOCUSRITE_PATTERN" | head -n 1 | sed 's/^card \([0-9]*\):.*/\1/')
    fi
    echo "$card"
}
# its name as the kernel reports it (for the log)
focusrite_name() {
    # " 1 [USB            ]: USB-Audio - Scarlett 2i2 USB"  ->  "Scarlett 2i2 USB"
    awk -v c="$1" '$1 == c && /\[/ { sub(/^[^]]*\]: [^ ]+ - /, ""); print; exit }' /proc/asound/cards 2>/dev/null
}

# Pi: restore the pisound JACK if we switched away from it
restore_pi_jack() {
    if [[ "${SCARLETT_JACK_STARTED:-0}" -eq 1 ]]; then
        echo "Stopping Focusrite JACK and restoring pisound JACK..."
        sudo pkill -x jackd 2>/dev/null || true
        sleep 1
        # Restart the JACK systemd service if it exists, otherwise let pisound handle it
        if systemctl list-unit-files jack.service &>/dev/null || systemctl list-unit-files jackd.service &>/dev/null; then
            sudo systemctl start jack jackd 2>/dev/null || true
        elif command -v jack_control &>/dev/null; then
            jack_control start 2>/dev/null || true
        fi
        echo "Pisound JACK restored."
        SCARLETT_JACK_STARTED=0
    fi
}

# laptop: stop the jackd we started (a JACK server that was already running is left alone)
stop_desktop_jack() {
    if [[ "${DESKTOP_JACK_STARTED:-0}" -eq 1 && -n "$JACK_PID" ]]; then
        echo "Stopping JACK (PID: $JACK_PID)..."
        kill "$JACK_PID" 2>/dev/null || true
        DESKTOP_JACK_STARTED=0
    fi
}

# ---- Tablet layout server ----
# Serves ui/ of this checkout, so the layout the tablet downloads always belongs to the code that runs.
UI_HTTP_PID=""
start_ui_server() {
    if [[ "$UI_HTTP_PORT" == "0" ]]; then
        return
    fi
    if ! command -v python3 &>/dev/null; then
        echo "python3 not found: the tablet layout is not served."
        return
    fi
    # a server left over from a crashed run would keep the port
    pkill -f "http.server $UI_HTTP_PORT --directory $REPO/ui" 2>/dev/null || true
    local log="${XDG_RUNTIME_DIR:-/tmp}/sc-store-ui-http.log"
    python3 -B -m http.server "$UI_HTTP_PORT" --directory "$REPO/ui" >"$log" 2>&1 &
    UI_HTTP_PID=$!
    sleep 0.5
    if ! kill -0 "$UI_HTTP_PID" 2>/dev/null; then
        echo "Warning: the tablet layout server did not start (port $UI_HTTP_PORT in use?): $(tail -n 1 "$log")"
        UI_HTTP_PID=""
        return
    fi
    # addresses the tablet can reach: IPv4 of the real interfaces (not Docker / VM bridges)
    local iface ip
    while read -r iface ip; do
        case "$iface" in docker*|br-*|veth*|virbr*|lo) continue ;; esac
        echo "Tablet start page: http://${ip%/*}:$UI_HTTP_PORT/   (layout: .../main.tosc, log: $log)"
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}')
    if systemctl is-active --quiet ufw 2>/dev/null; then
        echo "Note: the ufw firewall is active. If the tablet gets a timeout, allow the port once:"
        echo "      sudo ufw allow proto tcp from 192.168.0.0/16 to any port $UI_HTTP_PORT"
    fi
}
stop_ui_server() {
    if [[ -n "$UI_HTTP_PID" ]]; then
        kill "$UI_HTTP_PID" 2>/dev/null || true
        UI_HTTP_PID=""
    fi
}

# Function to handle cleanup on exit
cleanup() {
    echo ""
    echo "Interrupt received. Cleaning up..."
    if [[ -n "$SCLANG_PID" ]]; then
        echo "Terminating sclang (PID: $SCLANG_PID)..."
        kill "$SCLANG_PID" 2>/dev/null || echo "sclang already terminated."
        wait "$SCLANG_PID" 2>/dev/null || true
    fi
    if [[ "$ON_PI" -eq 0 ]]; then
        # sclang does not quit its server when it is killed; on SIGTERM / SIGHUP it would keep playing
        pkill -x scsynth 2>/dev/null || true
        pkill -x supernova 2>/dev/null || true
        pkill -f "polytracker run" 2>/dev/null || true
    fi
    stop_ui_server
    restore_pi_jack
    stop_desktop_jack
    [[ "$ON_PI" -eq 1 ]] && report_pi_throttling "at exit"
    exit 1
}

if [[ "$ON_PI" -eq 1 ]]; then
    trap cleanup SIGINT
else
    trap cleanup SIGINT SIGTERM SIGHUP   # also when the terminal is closed: do not leave our jackd behind
fi

# 1. Kill all SuperCollider instances (another sclang would take port 57120, which the tablet sends to)
stop_process sclang || exit 1
stop_process scsynth || exit 1
stop_process supernova || exit 1
# scsynth keeps its buses in a shared memory segment named after its port. One left by an scsynth of another user
# (e.g. root) makes the next scsynth fail with "Exception in World_New: Permission denied". No scsynth runs now,
# so whatever is there is stale.
for shm in /dev/shm/SuperColliderServer_*; do
    [[ -e "$shm" ]] || continue
    echo "Removing stale scsynth shared memory $shm (owner: $(stat -c %U "$shm"))."
    rm -f "$shm" 2>/dev/null || sudo -n rm -f "$shm" 2>/dev/null || \
        echo "Error: cannot remove $shm; scsynth will not start. Remove it by hand: sudo rm $shm"
done
# A leftover polyphonic pitch tracker normally exits together with sclang; make sure ([p]: see boot-sc.sh)
pkill -f '[p]olytracker run' 2>/dev/null || sudo -n pkill -f '[p]olytracker run' 2>/dev/null || true

# 2. Kill all Pure Data (Pd) instances (Pi only: on the laptop Pd may be in use for something else)
if [[ "$ON_PI" -eq 1 ]]; then
    stop_process pd || true   # Pd is not in our way, only in the way of the CPU
fi

# Optional: Wait a moment to ensure processes have terminated
sleep 1

# 2.4. CPU clock (Pi)
if [[ "$ON_PI" -eq 1 ]]; then
    set_cpu_governor "$CPU_GOVERNOR"
    report_pi_throttling "at start"
fi

# 2.45. Installed start scripts (Pi): sc-boot.service and the buttons run copies outside the repository, which do
# not change with a checkout. Say so when they are older than this checkout's versions.
if [[ "$ON_PI" -eq 1 ]]; then
    for pair in "launchers/boot-sc.sh:/usr/local/sc-patches/boot-sc.sh" \
                "launchers/sc-boot.service:/etc/systemd/system/sc-boot.service" \
                "launchers/single_press.sh:/usr/local/pisound/scripts/pisound-btn/single_press.sh" \
                "launchers/double_press.sh:/usr/local/pisound/scripts/pisound-btn/double_press.sh"; do
        src="$REPO/${pair%%:*}"; dest="${pair#*:}"
        if [[ -f "$src" && -f "$dest" ]] && ! cmp -s "$src" "$dest"; then
            echo "Warning: $dest differs from ${pair%%:*} of this checkout; install it with launchers/install-pi.sh"
        fi
    done
fi

# 2.5. JACK
if [[ "$ON_PI" -eq 1 ]]; then
    # Detect a Focusrite interface and switch JACK to it if present
    SCARLETT_CARD=$(focusrite_card)
    if [[ -n "$SCARLETT_CARD" ]]; then
        echo "Focusrite found on card $SCARLETT_CARD ($(focusrite_name "$SCARLETT_CARD")), switching JACK to hw:$SCARLETT_CARD..."

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
        # Start JACK on the Focusrite card
        jackd -d alsa -d hw:"$SCARLETT_CARD" -r "$JACK_RATE" -p "$JACK_PERIOD" -n "$JACK_NPERIODS" &
        JACK_PID=$!
        echo "JACK started on the Focusrite (PID: $JACK_PID)."
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
            echo "Warning: JACK did not become ready in time. SuperCollider may not connect to the Focusrite."
        fi
    else
        echo "No Focusrite found, using pisound via existing JACK."
    fi
else
    # JACK_NO_START_SERVER: only ask, never let jack_lsp start a default server
    if JACK_NO_START_SERVER=1 jack_lsp &>/dev/null; then
        # its settings are not changed: a JACK started elsewhere keeps its own period (JACK_PERIOD does not apply)
        echo "JACK is already running, using it$(command -v jack_bufsize >/dev/null && JACK_NO_START_SERVER=1 jack_bufsize 2>/dev/null | grep -o '[0-9]\+' | head -n 1 | sed 's/^/ (period: /; s/$/ samples)/')."
    else
        if [[ -z "$JACK_DEVICE" ]]; then
            SCARLETT_CARD=$(focusrite_card)
            if [[ -n "$SCARLETT_CARD" ]]; then
                JACK_DEVICE="hw:$SCARLETT_CARD"
                echo "Focusrite found on card $SCARLETT_CARD ($(focusrite_name "$SCARLETT_CARD"))."
            else
                JACK_DEVICE="hw:0"
                echo "No Focusrite found, using the built-in card."
            fi
        fi
        echo "Starting JACK: jackd -d alsa -d $JACK_DEVICE -r $JACK_RATE -p $JACK_PERIOD -n $JACK_NPERIODS"
        jackd -d alsa -d "$JACK_DEVICE" -r "$JACK_RATE" -p "$JACK_PERIOD" -n "$JACK_NPERIODS" &
        JACK_PID=$!
        DESKTOP_JACK_STARTED=1

        JACK_READY=0
        for i in $(seq 1 20); do
            if ! kill -0 "$JACK_PID" 2>/dev/null; then
                echo "Error: jackd exited (is $JACK_DEVICE in use by another program?)."
                exit 1
            fi
            if JACK_NO_START_SERVER=1 jack_lsp &>/dev/null; then
                echo "JACK is ready."
                JACK_READY=1
                break
            fi
            sleep 0.5
        done
        if [[ "$JACK_READY" -eq 0 ]]; then
            echo "Error: JACK did not become ready in time."
            stop_desktop_jack
            exit 1
        fi
    fi
fi

# 3. Start the SuperCollider script
# Check if the script exists
if [[ ! -f "$SCLANG_SCRIPT" ]]; then
    echo "Error: SuperCollider script '$SCLANG_SCRIPT' not found."
    stop_desktop_jack
    exit 1
fi

start_ui_server

echo "Starting SuperCollider script: $SCLANG_SCRIPT (TouchOSC tablet: $TOUCHOSC_IP)"
# Start sclang with the script in the background
sclang "$SCLANG_SCRIPT" &
SCLANG_PID=$!

echo "SuperCollider script started successfully with PID: $SCLANG_PID."

# Wait for the sclang process to finish
SCLANG_STATUS=0
wait "$SCLANG_PID" || SCLANG_STATUS=$?
echo "SuperCollider exited (status $SCLANG_STATUS)."

stop_ui_server
restore_pi_jack
stop_desktop_jack
if [[ "$ON_PI" -eq 1 ]]; then
    report_pi_throttling "at exit"
fi

# Pass sclang's exit status on: on the Pi, sc-boot.service (Restart=on-failure) restarts the patch after a crash
exit "$SCLANG_STATUS"
