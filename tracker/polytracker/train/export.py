"""Export a training checkpoint (.pt) to the numpy inference format (.npz).

    python -m polytracker.train.export runs/final.best.pt models/guitar_v1.npz [--name guitar_v1]
"""
from __future__ import annotations

import argparse

import torch

from ..config import FrontendConfig
from .model import PitchNet


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("checkpoint")
    ap.add_argument("out")
    ap.add_argument("--width", type=int, default=64)
    ap.add_argument("--fine-width", type=int, default=32)
    ap.add_argument("--name", default="guitar_v1")
    a = ap.parse_args()
    m = PitchNet(FrontendConfig(), fine_width=a.fine_width, width=a.width)
    m.load_state_dict(torch.load(a.checkpoint, map_location="cpu"))
    m.eval()
    m.export(a.out, {"name": a.name})
    print(f"wrote {a.out} ({m.n_params():,} parameters)")


if __name__ == "__main__":
    main()
