#!/bin/bash
# Creates tracker/.venv with the runtime dependencies (numpy + JACK-Client).
# On the Raspberry Pi the system numpy is reused (apt install python3-numpy libjack-jackd2-0).
# Training dependencies are only needed on a workstation:  ./scripts/install.sh --train
set -e
cd "$(dirname "$0")/.."

if [[ "$1" == "--train" ]]; then
    python3 -m venv .venv
    .venv/bin/pip install --upgrade pip
    .venv/bin/pip install -r requirements-train.txt
else
    python3 -m venv --system-site-packages .venv
    .venv/bin/pip install --upgrade pip
    .venv/bin/pip install -r requirements.txt
fi

.venv/bin/python -m polytracker info
echo "Done. Benchmark this machine with:  .venv/bin/python -m polytracker bench"
