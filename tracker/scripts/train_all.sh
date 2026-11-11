#!/bin/bash
# Reproduces models/guitar_v1.npz (about 45 min on a 20-core workstation, needs ~8 GB RAM, no GPU).
#   1. render 3072 synthetic guitar excerpts (+ a small validation pool)
#   2. pretrain on synthetic data, validating on GuitarSet player 04
#   3. fine-tune on a synthetic + GuitarSet (players 00-03, pickup mix and mic) stream
#   4. export the numpy inference model
# Players 04 (validation / decoder tuning) and 05 (test) are never trained on.
set -e
cd "$(dirname "$0")/.."
PY="${PYTHON:-.venv/bin/python}"
GS="${GUITARSET:-data/guitarset}"
RUNS="${RUNS:-runs}"
POOL="${POOL:-data/pool}"
WORKERS="${WORKERS:-$(( $(nproc) > 6 ? $(nproc) - 6 : 1 ))}"
export OPENBLAS_NUM_THREADS=1

[[ -d "$GS/annotation" ]] || ./scripts/download_guitarset.sh "$GS"
mkdir -p "$RUNS"

if ! ls "$POOL"/synth_*.npz >/dev/null 2>&1; then
    $PY -m polytracker.train.make_pool --out "$POOL" --excerpts 3072
    $PY -m polytracker.train.make_pool --out "${POOL}_val" --excerpts 64 --seed 999 --procs 2
fi

COMMON=(--pool "$POOL" --val-pool "${POOL}_val" --guitarset "$GS" --eval-every 500
        --workers "$WORKERS" --threads 4 --excerpts-per-batch 6 --frames-per-excerpt 128)

$PY -m polytracker.train.train "${COMMON[@]}" --gs-weight 0.0 --steps 4000 --out "$RUNS/stageA"
$PY -m polytracker.train.train "${COMMON[@]}" --gs-kind both --gs-weight 0.6 --init "$RUNS/stageA.pt" \
    --lr 1e-3 --steps 4000 --out "$RUNS/stageB"

mkdir -p models
$PY -m polytracker.train.export "$RUNS/stageB.pt" models/guitar_v1.npz --name guitar_v1
$PY -m polytracker.train.evaluate --model models/guitar_v1.npz --guitarset "$GS" --split test
