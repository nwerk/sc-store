#!/bin/bash
# Double press → checkout dev and launch granular patch
. /usr/local/pisound/scripts/common/common.sh

flash_leds 255

# Run in background so this script exits immediately and the button handler
# returns to listening for new presses.
nohup /usr/local/sc-patches/boot-sc.sh dev </dev/null >/tmp/boot-sc.log 2>&1 &
