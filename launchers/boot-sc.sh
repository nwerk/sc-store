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
    # as root (old button scripts) directly, as `patch` through sudo -n (no password prompt)
    systemctl stop sc-boot.service 2>/dev/null || sudo -n systemctl stop sc-boot.service || true
    sleep 2
fi

# Stops every process with this exact name. One started by another user (the pisound button, a manual sudo) cannot
# be killed by a plain pkill; then it is tried with sudo -n (no password prompt), and SIGKILL if SIGTERM was not
# enough. Returns 1, with a message naming the owner, if the process is still there: a second patch must not start
# next to it (it would not get the OSC port and the audio interface).
stop_process() {
    local name="$1" i
    pgrep -x "$name" > /dev/null || return 0
    echo "[boot-sc] Stopping $name ($(ps -o user=,pid= -C "$name" | awk '{printf "%s%s pid %s", (NR > 1 ? ", " : ""), $1, $2}'))..."
    pkill -x "$name" 2>/dev/null || sudo -n pkill -x "$name" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$name" > /dev/null || return 0
        sleep 0.5
    done
    pkill -9 -x "$name" 2>/dev/null || sudo -n pkill -9 -x "$name" 2>/dev/null || true
    sleep 0.5
    pgrep -x "$name" > /dev/null || return 0
    echo "[boot-sc] ERROR: cannot stop $name ($(ps -o user=,pid= -C "$name" | awk '{printf "%s%s pid %s", (NR > 1 ? ", " : ""), $1, $2}')); it belongs to another user. Stop it by hand: sudo pkill -x $name"
    return 1
}

# ---- 1. Kill any running SuperCollider instances ----
# (a failure here used to end the script under set -e: sc-boot.service then restarted it every 10 s, for ever)
for proc in sclang scsynth; do
    stop_process "$proc" || exit 1
done
# leftover pitch tracker, if any ([p]: the pattern must not match the command line of sudo itself)
pkill -f '[p]olytracker run' 2>/dev/null || sudo -n pkill -f '[p]olytracker run' 2>/dev/null || true

# ---- 2. Checkout requested branch (power-loss safe) ----
# The Pi can lose power at any moment, also in the middle of a git command. That leaves two kinds of damage:
#   - lock files (.git/index.lock, refs/heads/<branch>.lock, ...): every later git command then refuses with
#     "Another git process seems to be running", the patch never starts and systemd restarts this in a loop;
#   - files that were being written (checked-out files, objects): empty or half-written.
# So: remove locks no running git owns, write nothing when the right branch is already checked out and intact,
# repair (forced checkout) otherwise, flush everything to the SD card, and if git itself is broken, start the
# patch from the files that are there instead of not starting at all.
# The presets (osc/presets/) are saved on the Pi and never overwritten by a checkout or repair.
GIT_TIMEOUT=60
PRESET_DIR="osc/presets"
git_repo() { timeout "$GIT_TIMEOUT" git -C "$REPO" "$@"; }

clear_stale_git_locks() {
    local lock found=0
    if pgrep -x git > /dev/null; then
        echo "[boot-sc] A git command is running; leaving its lock files alone."
        return 1
    fi
    while IFS= read -r -d '' lock; do
        echo "[boot-sc] Removing stale git lock ${lock#"$REPO"/} (left by an interrupted git command, e.g. power loss)."
        rm -f "$lock"
        found=1
    done < <(find "$REPO/.git" -name '*.lock' -type f -print0 2>/dev/null)
    [[ "$found" -eq 1 ]]
}

# Forced checkout that keeps the presets and saves every discarded local change as a patch in .git/
force_checkout() {
    local backup patch
    backup="$REPO/.git/boot-sc-presets"
    patch="$REPO/.git/boot-sc-discarded-$(date +%Y%m%d-%H%M%S).patch"
    if ! git_repo diff --quiet HEAD -- . ":(exclude)$PRESET_DIR" 2>/dev/null; then
        git_repo diff --binary HEAD -- . ":(exclude)$PRESET_DIR" > "$patch" 2>/dev/null || true
        echo "[boot-sc] Local changes outside $PRESET_DIR are replaced; saved as ${patch#"$REPO"/}."
    fi
    rm -rf "$backup"; mkdir -p "$backup"
    cp -a "$REPO/$PRESET_DIR/." "$backup/" 2>/dev/null || true
    sync
    if git_repo checkout -f "$BRANCH"; then
        cp -a "$backup/." "$REPO/$PRESET_DIR/" 2>/dev/null || true
        rm -rf "$backup"
        return 0
    fi
    cp -a "$backup/." "$REPO/$PRESET_DIR/" 2>/dev/null || true
    return 1
}

checkout_branch() {
    local interrupted=0 current damaged=0
    clear_stale_git_locks && interrupted=1

    if ! git_repo rev-parse --verify -q HEAD > /dev/null || ! git_repo rev-parse --verify -q "$BRANCH^{commit}" > /dev/null; then
        echo "[boot-sc] ERROR: git cannot read HEAD or branch $BRANCH (repository damaged?)."
        git_repo fsck --no-dangling 2>&1 | head -n 20 || true
        return 1
    fi
    current=$(git_repo symbolic-ref --short -q HEAD || true)
    # tracked files that differ from the checked-out commit (an interrupted checkout, half-written files);
    # the presets are left out: they are expected to change on the Pi
    git_repo diff --quiet HEAD -- . ":(exclude)$PRESET_DIR" 2>/dev/null || damaged=1

    if [[ "$current" == "$BRANCH" && "$interrupted" -eq 0 && "$damaged" -eq 0 ]]; then
        echo "[boot-sc] Already on $BRANCH, files intact: nothing to check out."
        return 0
    fi

    if [[ "$interrupted" -eq 1 || "$damaged" -eq 1 ]]; then
        echo "[boot-sc] Repairing the checkout of $BRANCH (interrupted git command or changed files)..."
        force_checkout || return 1
    else
        echo "[boot-sc] Checking out $BRANCH in $REPO..."
        if ! git_repo checkout "$BRANCH"; then
            echo "[boot-sc] Plain checkout failed; forcing it."
            force_checkout || return 1
        fi
    fi
    sync   # flush the checked-out files to the SD card before anything else happens
    return 0
}

# Python bytecode caches of the pitch tracker: it runs with -B (writes none), so any that are left are from
# an older version and may be half-written by a power loss. Python would crash on a damaged one.
find "$REPO/tracker/polytracker" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true

if checkout_branch; then
    echo "[boot-sc] On branch: $(git_repo branch --show-current 2>/dev/null || echo '?')"
else
    echo "[boot-sc] WARNING: could not check out $BRANCH; starting the patch from the files as they are."
fi

# ---- 4. Hand off to multi launcher ----
if [[ ! -x "$MULTI_LAUNCHER" ]]; then
    echo "[boot-sc] ERROR: $MULTI_LAUNCHER not found or not executable."
    exit 1
fi

echo "[boot-sc] Launching $MULTI_LAUNCHER..."
exec "$MULTI_LAUNCHER"
