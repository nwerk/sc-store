"""Training-time definition of the pitch network (PyTorch)."""
from __future__ import annotations

import json

import numpy as np
import torch
from torch import nn

from ..config import FrontendConfig


class ConvBN(nn.Module):
    def __init__(self, cin, cout, k, stride=1, dilation=1, pad=0, relu=True, bn=True):
        super().__init__()
        self.conv = nn.Conv1d(cin, cout, k, stride=stride, dilation=dilation, padding=pad, bias=not bn)
        self.bn = nn.BatchNorm1d(cout) if bn else None
        self.relu = relu
        self.spec = dict(k=k, stride=stride, dilation=dilation, pad=pad, relu=relu)

    def forward(self, x):
        y = self.conv(x)
        if self.bn is not None:
            y = self.bn(y)
        return torch.relu(y) if self.relu else y


class PitchNet(nn.Module):
    """Fine-grid convs (sub-semitone detail) -> stride-3 to semitone axis -> dilated residual blocks.

    The dilations (12, 7, 5, ...) let a pitch look at its octave and fifth, which is where
    harmonic confusions of a polyphonic guitar signal come from.
    """

    def __init__(self, cfg: FrontendConfig, fine_width=32, width=64, dilations=(1, 12, 7, 5, 12)):
        super().__init__()
        self.cfg = cfg
        self.fine_width, self.width, self.dilations = fine_width, width, tuple(dilations)
        self.stem1 = ConvBN(cfg.n_channels, fine_width, 3, pad=1)
        self.stem2 = ConvBN(fine_width, fine_width, 3, pad=1)
        self.down = ConvBN(fine_width, width, cfg.bins_per_semitone, stride=cfg.bins_per_semitone)
        self.blocks = nn.ModuleList([ConvBN(width, width, 3, dilation=d, pad=d) for d in dilations])
        self.head = ConvBN(width, 2, 1, relu=False, bn=False)

    def forward(self, x):
        h = self.stem2(self.stem1(x))
        h = self.down(h)
        for blk in self.blocks:
            h = h + blk(h)
        return self.head(h)

    def n_params(self):
        return sum(p.numel() for p in self.parameters())

    def export_arrays(self):
        """Fold BatchNorm into the convs and describe the layer graph for the numpy engine."""
        layers, arrays = [], {}

        def add(m: ConvBN, **flags):
            w = m.conv.weight.detach().cpu().numpy().astype(np.float32)
            if m.bn is not None:
                bn = m.bn
                scale = (bn.weight / torch.sqrt(bn.running_var + bn.eps)).detach().cpu().numpy()
                bias = (bn.bias - bn.running_mean * bn.weight / torch.sqrt(bn.running_var + bn.eps)).detach().cpu().numpy()
                w = w * scale[:, None, None]
            else:
                bias = m.conv.bias.detach().cpu().numpy()
            i = len(layers)
            arrays[f"l{i}_w"] = w
            arrays[f"l{i}_b"] = bias.astype(np.float32)
            layers.append({**m.spec, **flags})

        add(self.stem1)
        add(self.stem2)
        add(self.down)
        for blk in self.blocks:
            add(blk, residual_in=True, residual_out=True)
        add(self.head)
        return layers, arrays

    def export(self, path, extra_meta=None):
        layers, arrays = self.export_arrays()
        meta = {"frontend": self.cfg.to_dict(), "layers": layers, "arch": "pitchnet-v1",
                "fine_width": self.fine_width, "width": self.width, "dilations": list(self.dilations)}
        meta.update(extra_meta or {})
        np.savez_compressed(path, meta=np.array(json.dumps(meta)), **arrays)
