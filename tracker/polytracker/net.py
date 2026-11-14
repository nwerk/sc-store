"""Pure-numpy inference for the pitch network (no torch needed on the Pi).

Weights are stored in a single ``.npz`` produced by ``polytracker.train.export``.
Layers are plain 1-D convolutions over the pitch axis with BatchNorm already
folded in, so inference is conv -> ReLU (+ residual) -> sigmoid.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from .config import FrontendConfig


def conv1d(x: np.ndarray, w2: np.ndarray, b: np.ndarray, k: int, stride: int, dilation: int, pad: int) -> np.ndarray:
    """``x`` [B, Cin, L]; ``w2`` [Cout, k*Cin] laid out tap-major (k, Cin)."""
    if pad:
        x = np.pad(x, ((0, 0), (0, 0), (pad, pad)))
    L = x.shape[2]
    l_out = (L - dilation * (k - 1) - 1) // stride + 1
    taps = [x[:, :, i * dilation: i * dilation + (l_out - 1) * stride + 1: stride] for i in range(k)]
    col = np.concatenate(taps, axis=1) if k > 1 else taps[0]
    return np.matmul(w2, col) + b[None, :, None]


class PitchNetNP:
    def __init__(self, layers: list[dict], arrays: dict[str, np.ndarray], cfg: FrontendConfig, meta: dict):
        self.layers = layers
        self.cfg = cfg
        self.meta = meta
        self.w = {}
        self.b = {}
        for i, l in enumerate(layers):
            w = arrays[f"l{i}_w"].astype(np.float32)  # [Cout, Cin, k]
            self.w[i] = np.ascontiguousarray(w.transpose(0, 2, 1).reshape(w.shape[0], -1))
            self.b[i] = arrays[f"l{i}_b"].astype(np.float32)

    @staticmethod
    def load(path: str | Path) -> "PitchNetNP":
        with np.load(str(path), allow_pickle=False) as z:
            arrays = {k: z[k] for k in z.files}
        meta = json.loads(str(arrays.pop("meta")))
        cfg = FrontendConfig.from_dict(meta["frontend"])
        return PitchNetNP(meta["layers"], arrays, cfg, meta)

    def forward(self, x: np.ndarray) -> np.ndarray:
        """``x`` [B, C, n_fine] -> logits [B, 2, n_pitch] (frame, onset)."""
        h = x.astype(np.float32, copy=False)
        skip = None
        for i, l in enumerate(self.layers):
            if l.get("residual_in"):
                skip = h
            y = conv1d(h, self.w[i], self.b[i], l["k"], l["stride"], l["dilation"], l["pad"])
            if l.get("relu", True):
                np.maximum(y, 0.0, out=y)
            if l.get("residual_out"):
                y = y + skip
            h = y
        return h

    def predict(self, x: np.ndarray) -> np.ndarray:
        logits = self.forward(x)
        return 1.0 / (1.0 + np.exp(-np.clip(logits, -30.0, 30.0)))

    # ---- realtime path: one frame, preallocated buffers, no allocation and no slicing per call
    def _plan(self, l_in: int):
        """Build the per-layer buffers and every view the single-frame path needs, once.

        Each layer's output is written straight into the interior of the next layer's zero-padded input
        buffer, and the im2col copies are precomputed (destination, source) view pairs, so a frame costs one
        ``copyto`` per tap plus matmul / bias / ReLU / residual per layer.
        """
        layers = []
        cin = self.cfg.n_channels
        for i, l in enumerate(self.layers):
            k, s, d, p = l["k"], l["stride"], l["dilation"], l["pad"]
            l_out = (l_in + 2 * p - d * (k - 1) - 1) // s + 1
            xpad = np.zeros((cin, l_in + 2 * p), dtype=np.float32)
            col = np.empty((k * cin, l_out), dtype=np.float32)
            span = (l_out - 1) * s + 1
            taps = [(col[t * cin:(t + 1) * cin], xpad[:, t * d: t * d + span: s]) for t in range(k)]
            layers.append(dict(inp=xpad[:, p:p + l_in], taps=taps, col=col, w=self.w[i], b=self.b[i][:, None],
                               relu=l.get("relu", True), res_in=bool(l.get("residual_in")),
                               res_out=bool(l.get("residual_out")), shape=(self.w[i].shape[0], l_out)))
            cin, l_in = self.w[i].shape[0], l_out
        for a, b in zip(layers, layers[1:]):
            a["out"] = b["inp"]  # BLAS writes into the strided interior view directly
        layers[-1]["out"] = np.empty(layers[-1]["shape"], dtype=np.float32)
        self._prob = np.empty(layers[-1]["shape"], dtype=np.float32)
        self._plan_cache = layers
        self._plan_len = layers[0]["inp"].shape[1]
        return layers

    def predict_one(self, x: np.ndarray) -> np.ndarray:
        """``x`` [C, n_fine] -> probabilities [2, n_pitch]; same numbers as ``predict`` but allocation-free.

        The returned array is reused by the next call.
        """
        plan = self._plan_cache if getattr(self, "_plan_len", None) == x.shape[1] else self._plan(x.shape[1])
        copyto, matmul, maximum = np.copyto, np.matmul, np.maximum
        copyto(plan[0]["inp"], x)
        skip = None
        for L in plan:
            if L["res_in"]:
                skip = L["inp"]
            for dst, src in L["taps"]:
                copyto(dst, src)
            out = L["out"]
            matmul(L["w"], L["col"], out=out)
            out += L["b"]
            if L["relu"]:
                maximum(out, 0.0, out=out)
            if L["res_out"]:
                out += skip
        p = self._prob
        np.clip(out, -30.0, 30.0, out=p)
        np.negative(p, out=p)
        np.exp(p, out=p)
        p += 1.0
        np.reciprocal(p, out=p)
        return p
