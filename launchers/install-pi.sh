#!/bin/bash
# ============================================================
# install-pi.sh — install the Pi's start scripts from this checkout
# ============================================================
# sc-boot.service and the pisound button scripts do not run launchers/boot-sc.sh from the repository but a copy
# in /usr/local/sc-patches/: boot-sc.sh checks out a branch of the repository it would otherwise be running from,
# and bash reads a script while it runs. So changes to launchers/boot-sc.sh or launchers/sc-boot.service only
# take effect after this script has copied them into place:
#
#   /usr/local/sc-patches/sc-store/launchers/install-pi.sh
#
# Installs:
#   launchers/boot-sc.sh     -> /usr/local/sc-patches/boot-sc.sh
#   launchers/sc-boot.service -> /etc/systemd/system/sc-boot.service (+ systemctl daemon-reload)
# Each file is written under a temporary name and renamed when complete (power-loss safe); the previous version
# is kept next to it as *.old. A patch that is running keeps running; the new files apply from the next start.
# run-sc-main_multi.sh warns at every start while an installed copy differs from the repository.
# ============================================================
set -e

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
BOOT_DEST=/usr/local/sc-patches/boot-sc.sh
UNIT_DEST=/etc/systemd/system/sc-boot.service

install_file() {   # source, destination, mode
    local src="$1" dest="$2" mode="$3"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        echo "up to date: $dest"
        return 1
    fi
    sudo install -m "$mode" "$src" "$dest.tmp"
    sync
    [[ -f "$dest" ]] && sudo cp -p "$dest" "$dest.old"
    sudo mv -f "$dest.tmp" "$dest"
    sync
    echo "installed:  $dest$([[ -f "$dest.old" ]] && echo "  (previous version: $dest.old)")"
    return 0
}

install_file "$REPO/launchers/boot-sc.sh" "$BOOT_DEST" 755 || true
if install_file "$REPO/launchers/sc-boot.service" "$UNIT_DEST" 644; then
    sudo systemctl daemon-reload
    echo "systemd reloaded; the service uses the new unit from its next start (sudo systemctl restart sc-boot.service)."
fi
