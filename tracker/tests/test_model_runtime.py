import socket
import threading
import time

import numpy as np
import pytest

from polytracker import oscmini
from polytracker.audio import WavSource
from polytracker.engine import Tracker
from polytracker.net import PitchNetNP
from polytracker.outputs import OscOutput
from polytracker.realtime import Runner
from conftest import chord


def test_numpy_engine_matches_torch(cfg, tiny_model_path):
    torch = pytest.importorskip("torch")
    m, path = tiny_model_path
    x = np.random.default_rng(0).standard_normal((4, cfg.n_channels, cfg.n_fine)).astype(np.float32)
    with torch.no_grad():
        ref = m(torch.from_numpy(x)).numpy()
    got = PitchNetNP.load(path).forward(x)
    assert got.shape == ref.shape == (4, 2, cfg.n_pitch)
    np.testing.assert_allclose(got, ref, atol=1e-4)


def test_single_frame_fast_path_equals_batched(cfg, tiny_model_path):
    _, path = tiny_model_path
    net = PitchNetNP.load(path)
    x = np.random.default_rng(3).standard_normal((3, cfg.n_channels, cfg.n_fine)).astype(np.float32)
    ref = net.predict(x)
    for i in range(3):  # repeated calls reuse buffers: results must not leak between calls
        np.testing.assert_allclose(net.predict_one(x[i]), ref[i], atol=1e-5)
    np.testing.assert_allclose(net.predict_one(x[0]), ref[0], atol=1e-5)


def test_single_frame_equals_batched(cfg, tiny_model_path):
    _, path = tiny_model_path
    tr = Tracker.load(path)
    x = chord([110.0, 165.0], seconds=1.0)
    times, probs, mags, rms = tr.frame_probabilities(x)
    i = 100
    end = int(round(times[i] * cfg.sample_rate))
    hist = tr.fe.pad(x)[end:end + tr.history]
    f = tr.fe.compute(hist[None])
    np.testing.assert_allclose(tr.model.predict(f.x)[0], probs[i], atol=1e-5)


def test_hop_must_divide_delta_lag(tiny_model_path):
    _, path = tiny_model_path
    with pytest.raises(ValueError):
        Tracker.load(path, hop=300)


def test_set_messages_from_sclang(cfg, tiny_model_path, capsys):
    """sclang sends camelCase names (\\monoMode, \\gateDb); every documented setting must take effect."""
    _, path = tiny_model_path
    tr = Tracker.load(path)
    out = OscOutput(("127.0.0.1", 9), ("127.0.0.1", 9), bus_base=0, voices=6)
    runner = Runner(tr, WavSource(chord([196.0], seconds=0.1), cfg.sample_rate), out)
    runner._on_set("monoMode", "lowest")
    assert out.mono_mode == "lowest"
    runner._on_set("mono_mode", "highest")
    assert out.mono_mode == "highest"
    runner._on_set("on", 0.8)
    runner._on_set("gateDb", -60.0)
    runner._on_set("refine", 0)
    runner._on_set("pause", 1)
    p = tr.dec.p
    assert (p.on_thresh, p.gate_db, p.refine, runner.paused) == (0.8, -60.0, False, True)
    runner._on_set("monoMode", "bogus")
    runner._on_set("nonsense", 1)
    assert out.mono_mode == "highest"  # invalid values are rejected, not applied
    msg = capsys.readouterr().out
    assert "mono_mode must be one of" in msg and "unknown setting 'nonsense'" in msg


def test_pause_skips_analysis(cfg, tiny_model_path):
    _, path = tiny_model_path
    tr = Tracker.load(path)
    runner = Runner(tr, WavSource(chord([196.0], seconds=0.5), cfg.sample_rate, speed=8.0), None)
    runner._on_set("pause", 1.0)
    runner.run()
    assert runner.frames == 0


def test_runner_streams_blocks_and_exits(cfg, tiny_model_path):
    _, path = tiny_model_path
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("127.0.0.1", 0))
    rx.settimeout(0.2)
    port = rx.getsockname()[1]
    tr = Tracker.load(path)
    audio = chord([196.0], seconds=1.0)
    out = OscOutput(("127.0.0.1", port), ("127.0.0.1", port), bus_base=9, voices=6)
    runner = Runner(tr, WavSource(audio, cfg.sample_rate, speed=8.0), out)
    th = threading.Thread(target=runner.run)
    th.start()
    th.join(timeout=15)
    assert not th.is_alive(), "runner did not stop after the source finished"
    msgs = []
    try:
        while True:
            msgs += oscmini.decode(rx.recv(4096))
    except socket.timeout:
        pass
    rx.close()
    addrs = [a for a, _ in msgs]
    assert "/polytracker/ready" in addrs
    sets = [args for a, args in msgs if a == "/c_setn"]
    assert sets and sets[0][0] == 9 and sets[0][1] == 22
    # the final message clears the block (no stuck notes after shutdown)
    assert all(v == 0 for v in sets[-1][2:5]) and sets[-1][2 + 3] > 0
    expected = len(audio) // cfg.hop
    assert runner.frames > 0 and runner.frames + runner.dropped >= expected - 12  # slow machines may skip frames
