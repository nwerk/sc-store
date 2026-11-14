#!/bin/bash
# Creates tracker/.venv with the runtime dependencies (numpy + JACK-Client).
# On the Raspberry Pi the system numpy is reused (apt install python3-numpy libjack-jackd2-0).
# Training dependencies are only needed on a workstation:  ./scripts/install.sh --train
set -e
cd "$(dirname "$0")/.."

if [[ "$1" == "--train" ]]; then
    REQ=requirements-train.txt
    VENV_ARGS=()
else
    REQ=requirements.txt
    VENV_ARGS=(--system-site-packages)
fi

if command -v uv >/dev/null 2>&1; then
    uv venv "${VENV_ARGS[@]}" .venv
    uv pip install --python .venv/bin/python -r "$REQ"
else
    if ! python3 -m venv "${VENV_ARGS[@]}" .venv; then
        rm -rf .venv
        echo "Could not create a virtualenv. On Debian/Ubuntu/Mint/Raspberry Pi OS run:" >&2
        echo "    sudo apt install python3-venv python3-numpy libjack-jackd2-0" >&2
        exit 1
    fi
    .venv/bin/python -m pip install --upgrade pip
    .venv/bin/python -m pip install -r "$REQ"
fi

.venv/bin/python -m polytracker info | tail -1
.venv/bin/python -c "from polytracker.perf import blas_warning as w; m = w(); print('WARNING: ' + m if m else 'numpy BLAS: optimised, ok')"
echo "Done. Benchmark this machine with:  .venv/bin/python -m polytracker bench"
