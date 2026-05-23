#!/bin/bash
# Single press → checkout prod and launch granular patch
. /usr/local/pisound/scripts/common/common.sh

flash_leds 100

/usr/local/sc-patches/boot-sc.sh prod
