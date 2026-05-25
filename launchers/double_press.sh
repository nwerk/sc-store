#!/bin/bash
# Double press → checkout dev and launch granular patch
. /usr/local/pisound/scripts/common/common.sh

flash_leds 255

# setsid puts boot-sc.sh in its own session so it is fully detached from the
# button handler's process group — pisound-btn can return to listening immediately.
setsid /usr/local/sc-patches/boot-sc.sh dev >/tmp/boot-sc.log 2>&1 &
