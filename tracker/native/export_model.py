"""Convert a trained ``.npz`` model into the ``.ptm`` file the native tracker reads.

The ``.npz`` is zip-compressed and would need zlib in C++; the ``.ptm`` is a text header followed by raw
little-endian float32 weights, so the native build needs nothing but a C++ compiler. Run it again after
training or fine-tuning a model:

    .venv/bin/python native/export_model.py                     # models/guitar_v1.npz -> models/guitar_v1.ptm
    .venv/bin/python native/export_model.py models/mine.npz     # -> models/mine.ptm

Format (version 1)::

    polytracker-model 1
    name <name>
    <frontend field> <value>        one line per FrontendConfig field
    layers <n>
    layer <k> <stride> <dilation> <pad> <relu> <residual_in> <residual_out> <c_out> <c_in>   (n lines)
    end
    <binary> per layer: weights [c_out][k * c_in] (tap-major, as net.py uses them), then bias [c_out]
"""
from __future__ import annotations

import sys
from dataclasses import fields
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from polytracker.config import FrontendConfig  # noqa: E402
from polytracker.net import PitchNetNP  # noqa: E402


def export(src: Path, dst: Path) -> None:
    m = PitchNetNP.load(src)
    head = ["polytracker-model 1", f"name {m.meta.get('name', src.stem)}"]
    for f in fields(FrontendConfig):
        v = getattr(m.cfg, f.name)
        head.append(f"{f.name} {v!r}")
    head.append(f"layers {len(m.layers)}")
    for i, l in enumerate(m.layers):
        c_out, kc = m.w[i].shape
        k = int(l["k"])
        head.append(" ".join(str(int(v)) for v in (
            k, l["stride"], l["dilation"], l["pad"], l.get("relu", True), bool(l.get("residual_in")),
            bool(l.get("residual_out")), c_out, kc // k)).join(("layer ", "")))
    head.append("end")
    with open(dst, "wb") as f:
        f.write(("\n".join(head) + "\n").encode())
        for i in range(len(m.layers)):
            f.write(np.ascontiguousarray(m.w[i], dtype="<f4").tobytes())
            f.write(np.ascontiguousarray(m.b[i], dtype="<f4").tobytes())
    print(f"{src} -> {dst} ({dst.stat().st_size:,} bytes)")


if __name__ == "__main__":
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "models" / "guitar_v1.npz"
    export(src, src.with_suffix(".ptm"))
