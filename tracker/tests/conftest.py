import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from polytracker.config import FrontendConfig  # noqa: E402


@pytest.fixture(scope="session")
def cfg():
    return FrontendConfig()


@pytest.fixture(scope="session")
def tiny_model_path(tmp_path_factory, cfg):
    """A randomly initialised (untrained) network exported like a real one."""
    torch = pytest.importorskip("torch")
    from polytracker.train.model import PitchNet

    torch.manual_seed(0)
    m = PitchNet(cfg, fine_width=8, width=16, dilations=(1, 12))
    # non-trivial BatchNorm statistics so folding is actually exercised
    for mod in m.modules():
        if isinstance(mod, torch.nn.BatchNorm1d):
            mod.running_mean.normal_(0, 0.3)
            mod.running_var.uniform_(0.5, 2.0)
            mod.weight.data.uniform_(0.5, 1.5)
            mod.bias.data.normal_(0, 0.2)
    m.eval()
    path = tmp_path_factory.mktemp("model") / "tiny.npz"
    m.export(path)
    return m, path


def chord(freqs, seconds=1.0, sr=48000, harmonics=8, amp=0.1, decay=0.0):
    t = np.arange(int(seconds * sr)) / sr
    x = np.zeros_like(t)
    for f in freqs:
        for h in range(1, harmonics + 1):
            x += amp / h * np.sin(2 * np.pi * f * h * t) * np.exp(-decay * h * t)
    return x.astype(np.float32)
