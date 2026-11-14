"""Bus-block layout shared with ``classes/inputtracker.scd`` and the OSC output stage.

The tracker writes one contiguous block of control buses (``/c_setn``) every
hop. Offsets, with ``V`` voices::

    [0]            mono frequency in Hz (0 = no note)
    [1]            mono amplitude 0..1
    [2]            number of sounding notes
    [3]            heartbeat counter (changes every update; lets SC detect a dead tracker)
    [4 .. 4+V)     voice frequency in Hz (holds the last value after release)
    [4+V .. 4+2V)  voice amplitude 0..1
    [4+2V .. 4+3V) voice gate (1 while the note sounds)
"""
from __future__ import annotations

import time

import numpy as np

from .decoder import NoteEvent, VoiceState
from .oscmini import UdpSender, encode, encode_floats

HEADER = 4
MONO_MODES = ("latest", "lowest", "highest", "loudest")


def block_size(voices: int) -> int:
    return HEADER + 3 * voices


def pick_mono(mode: str, vs: VoiceState) -> int:
    idx = np.flatnonzero(vs.active)
    if idx.size == 0:
        return -1
    if mode == "lowest":
        return int(idx[np.argmin(vs.midi[idx])])
    if mode == "highest":
        return int(idx[np.argmax(vs.midi[idx])])
    if mode == "loudest":
        return int(idx[np.argmax(vs.amp[idx])])
    return int(idx[np.argmax(vs.t_on[idx])])  # latest


class OscOutput:
    """Writes the bus block straight into scsynth and sends note events to sclang."""

    def __init__(self, scsynth: tuple[str, int], lang: tuple[str, int], bus_base: int, voices: int,
                 mono_mode: str = "latest"):
        self.sc = UdpSender(*scsynth)
        self.lang = UdpSender(*lang)
        self.base = bus_base
        self.voices = voices
        self.mono_mode = mono_mode
        self.block = np.zeros(block_size(voices), dtype=np.float32)
        self._last = None
        self._last_t = 0.0
        self._beat = 0

    def build(self, vs: VoiceState) -> np.ndarray:
        V = self.voices
        b = self.block
        m = pick_mono(self.mono_mode, vs)
        b[0] = vs.freq[m] if m >= 0 else 0.0
        b[1] = vs.amp[m] if m >= 0 else 0.0
        b[2] = float(vs.active.sum())
        b[HEADER:HEADER + V] = vs.freq
        b[HEADER + V:HEADER + 2 * V] = vs.amp
        b[HEADER + 2 * V:HEADER + 3 * V] = vs.active.astype(np.float32)
        return b

    def send_block(self, vs: VoiceState, force: bool = False):
        b = self.build(vs)
        now = time.monotonic()
        key = np.concatenate([b[:3], b[HEADER:]])
        changed = self._last is None or not np.array_equal(key, self._last)
        if not (changed or force or now - self._last_t > 0.05):
            return
        self._beat = (self._beat + 1) % 16_000_000
        b[3] = self._beat
        self.sc.send(encode_floats("/c_setn", (self.base, len(b)), b))
        self._last, self._last_t = key.copy(), now

    def send_events(self, events: list[NoteEvent]):
        for e in events:
            if e.kind == "on":
                self.lang.send(encode("/polytracker/noteOn", (e.voice, e.pitch, e.freq, e.amp)))
            else:
                self.lang.send(encode("/polytracker/noteOff", (e.voice, e.pitch)))

    def send_stats(self, load: float, frames: int, dropped: int, worst_ms: float):
        self.lang.send(encode("/polytracker/stats", (float(load), int(frames), int(dropped), float(worst_ms))))

    def hello(self, model_name: str):
        self.lang.send(encode("/polytracker/ready", (model_name, self.base, self.voices)))

    def clear(self):
        self.block[:] = 0.0
        self._beat += 1
        self.block[3] = self._beat
        self.sc.send(encode_floats("/c_setn", (self.base, len(self.block)), self.block))
        self._last = None
