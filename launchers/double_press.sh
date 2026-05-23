#!/bin/bash
# Double press → checkout dev and launch granular patch
. /usr/local/pisound/scripts/common/common.sh

flash_leds 255

/usr/local/sc-patches/boot-sc.sh dev
