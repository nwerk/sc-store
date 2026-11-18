#!/bin/bash
# Double press → checkout dev and launch granular patch
. /usr/local/pisound/scripts/common/common.sh

flash_leds 255

# pisound-btn runs this as root. The patch must run as the user `patch`, like sc-boot.service: as root, boot-sc.sh
# would write root-owned files into the repository (git checkout) that the service can no longer replace, and leave
# an sclang / scsynth the service cannot stop. Same environment as the service (launchers/sc-boot.service).
# setsid puts boot-sc.sh in its own session so it is fully detached from the
# button handler's process group — pisound-btn can return to listening immediately.
# Installed to /usr/local/pisound/scripts/pisound-btn/ by launchers/install-pi.sh.
RUN_AS=patch
if [[ "$(id -u)" -eq 0 ]]; then
    runuser -u "$RUN_AS" -- env HOME="/home/$RUN_AS" JACK_NO_AUDIO_RESERVATION=1 JACK_PROMISCUOUS_SERVER=jack \
        setsid /usr/local/sc-patches/boot-sc.sh dev >/tmp/boot-sc.log 2>&1 &
else
    setsid /usr/local/sc-patches/boot-sc.sh dev >/tmp/boot-sc.log 2>&1 &
fi
