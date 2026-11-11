import numpy as np
import pytest

pytest.importorskip("scipy")

from polytracker.train.data import ONSET_WINDOW, choose_ends, labels_at  # noqa: E402
from polytracker.train.evaluate import match_onsets, prf  # noqa: E402
from polytracker.train.synth import ROLL_RATE, TUNINGS, render_excerpt  # noqa: E402


def test_labels_follow_roll_and_onset_window():
    sr = 48000
    roll = np.zeros((2000, 51), dtype=np.uint8)
    roll[500:1500, 7] = 1
    ends = np.array([int(0.4 * sr), int(0.6 * sr), int(1.6 * sr)])
    frame, onset = labels_at(ends, sr, roll, [(0.5, 7)])
    assert frame[:, 7].tolist() == [0.0, 1.0, 0.0]
    assert onset[:, 7].tolist() == [0.0, 0.0, 0.0]  # 0.6 s is past the 30 ms onset window of the 0.5 s note
    _, onset2 = labels_at(np.array([int(0.51 * sr)]), sr, roll, [(0.5, 7)])
    assert onset2[0, 7] == 1.0 and onset2.sum() == 1.0


def test_choose_ends_in_range_and_near_onsets():
    rng = np.random.default_rng(0)
    ends = choose_ends(rng, 48000 * 6, [(3.0, 5)], 48000, 100)
    assert len(ends) == 100 and ends.min() >= 0 and ends.max() < 48000 * 6
    assert np.sum(np.abs(ends / 48000 - 3.0) < 0.2) >= 30


@pytest.mark.parametrize("seed", [0, 1, 2])
def test_synth_excerpt_is_consistent(cfg, seed):
    ex = render_excerpt(np.random.default_rng(seed), cfg, 3.0)
    assert ex.audio.dtype == np.float32 and len(ex.audio) == 3 * cfg.sample_rate
    assert np.isfinite(ex.audio).all() and np.abs(ex.audio).max() <= 1.0
    assert ex.roll.shape == (3 * ROLL_RATE + 1, cfg.n_pitch)
    for t, p in ex.onsets:
        assert 0.0 <= t < 3.0 and 0 <= p < cfg.n_pitch
        # a labelled onset must be active in the roll right after it starts
        assert ex.roll[min(int(t * ROLL_RATE) + 5, ex.roll.shape[0] - 1), p] == 1
    lowest = min(min(t) for t in TUNINGS.values())
    assert cfg.pitch_lo <= lowest


def test_match_onsets_is_one_to_one_and_pitch_aware():
    ref = [(1.0, 5), (1.02, 5), (2.0, 9)]
    est = [(1.01, 5), (2.04, 9), (2.0, 10), (5.0, 5)]
    tp, deltas = match_onsets(ref, est, tol=0.05)
    assert tp == 2 and len(deltas) == 2
    p, r, f = prf(tp, len(est) - tp, len(ref) - tp)
    assert (p, r) == (0.5, pytest.approx(2 / 3))
