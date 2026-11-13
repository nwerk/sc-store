"""Frontend + network + decoder wired together (shared by realtime, CLI and evaluation)."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .config import FrontendConfig
from .decoder import Decoder, DecoderParams, NoteEvent
from .frontend import Frontend
from .net import PitchNetNP

DEFAULT_MODEL = Path(__file__).resolve().parent.parent / "models" / "guitar_v1.npz"


class Tracker:
    def __init__(self, model: PitchNetNP, params: DecoderParams | None = None,
                 sample_rate: int | None = None, hop: int | None = None):
        base = model.cfg
        self.cfg = base.with_rate(sample_rate or base.sample_rate, hop or base.hop)
        if self.cfg.delta_samples % self.cfg.hop:
            raise ValueError(f"hop {self.cfg.hop} must divide the delta lag ({self.cfg.delta_samples} samples)")
        self.model = model
        self.fe = Frontend(self.cfg)
        self.dec = Decoder(self.cfg, params, n_fft=self.fe.n_long)
        self._db_short: dict[int, np.ndarray] = {}  # frame end sample -> short log spectrum, for the flux channel

    @staticmethod
    def load(path: str | Path | None = None, **kw) -> "Tracker":
        return Tracker(PitchNetNP.load(path or DEFAULT_MODEL), **kw)

    @property
    def history(self) -> int:
        return self.cfg.history

    def process(self, hist: np.ndarray, t: float) -> list[NoteEvent]:
        """One frame: ``hist`` holds the newest ``history`` samples (float32), ending at time ``t``.

        ``t`` must be the absolute stream time of the last sample (as the realtime loop and ``bench`` pass it):
        it identifies the frame whose short spectrum is reused, so frames do not need to be consecutive.
        """
        end = int(round(t * self.cfg.sample_rate))
        cache = self._db_short
        f = self.fe.compute(hist[None, :], cache.pop(end - self.cfg.delta_samples, None))
        cache[end] = f.db_short
        if len(cache) > 2 * (self.cfg.delta_samples // self.cfg.hop) + 2:  # frames were skipped: forget stale ones
            for k in [k for k in cache if k <= end - self.cfg.delta_samples]:
                del cache[k]
        pr = self.model.predict_one(f.x[0])
        return self.dec.step(t, pr[0], pr[1], f.mag_long[0], float(f.rms_db[0]))

    def frame_probabilities(self, audio: np.ndarray, batch: int = 256):
        """Per-frame network output for a whole signal. Returns ``(times, probs[N,2,P], mags, rms_db)``."""
        hop, sr = self.cfg.hop, self.cfg.sample_rate
        ends = np.arange(hop - 1, len(audio), hop)
        padded = self.fe.pad(audio)
        probs, mags, rms = [], [], []
        for i in range(0, len(ends), batch):
            f = self.fe.compute(self.fe.frames_from_padded(padded, ends[i:i + batch]))
            probs.append(self.model.predict(f.x))
            mags.append(f.mag_long)
            rms.append(f.rms_db)
        return (ends + 1) / sr, np.concatenate(probs), np.concatenate(mags), np.concatenate(rms)

    def run_signal(self, audio: np.ndarray, batch: int = 256, return_probs: bool = False):
        """Offline run that mirrors the realtime path frame by frame."""
        r = self.run_full(audio, batch)
        return (r.events, r.times, r.probs) if return_probs else r.events

    def run_full(self, audio: np.ndarray, batch: int = 256) -> "Run":
        return self.decode(self.frame_probabilities(audio, batch))

    def decode(self, frames) -> "Run":
        """Run the decoder over precomputed ``frame_probabilities`` (lets parameter sweeps skip the network)."""
        times, probs, mags, rms = frames
        self.dec.reset()
        events: list[NoteEvent] = []
        v = self.dec.p.max_voices
        midi = np.full((len(times), v), -1, dtype=np.int64)
        freq = np.zeros((len(times), v))
        for i, t in enumerate(times):
            events += self.dec.step(float(t), probs[i, 0], probs[i, 1], None if mags is None else mags[i], float(rms[i]))
            vs = self.dec.voices()
            midi[i] = np.where(vs.active, vs.midi, -1)
            freq[i] = vs.freq
        return Run(events, times, probs, midi, freq)


@dataclass
class Run:
    events: list
    times: np.ndarray  # frame end times (s)
    probs: np.ndarray  # [N, 2, n_pitch] frame / onset probabilities
    voice_midi: np.ndarray  # [N, voices] sounding MIDI note per voice (-1 = free)
    voice_freq: np.ndarray  # [N, voices] reported frequency per voice (Hz)
