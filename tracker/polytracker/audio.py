"""Audio sources for the realtime tracker: JACK (production) and a paced WAV feeder (testing)."""
from __future__ import annotations

import math
import threading
import time

import numpy as np


class JackSource:
    """Captures one JACK port. The RT callback only copies samples into a lock-free ring buffer."""

    def __init__(self, source_port: str | None, client_name: str = "polytracker", ring_seconds: float = 2.0,
                 connect_timeout: float = 30.0):
        import jack  # JACK-Client; imported lazily so offline use needs no JACK

        self.jack = jack
        self.client = jack.Client(client_name, no_start_server=True)
        self.sample_rate = int(self.client.samplerate)
        self.block_size = int(self.client.blocksize)
        self.inport = self.client.inports.register("in")
        size = 1 << int(math.ceil(math.log2(ring_seconds * self.sample_rate * 4)))
        self.ring = jack.RingBuffer(size)
        self.event = threading.Event()
        self.overruns = 0
        self.xruns = 0
        self.shutdown = False
        self.source_port = source_port
        self.connect_timeout = connect_timeout

        @self.client.set_process_callback
        def _process(frames):
            buf = self.inport.get_buffer()
            if self.ring.write(buf) < len(buf):
                self.overruns += 1
            self.event.set()

        @self.client.set_xrun_callback
        def _xrun(delay):
            self.xruns += 1

        @self.client.set_shutdown_callback
        def _shutdown(status, reason):
            self.shutdown = True
            self.event.set()

    def start(self):
        self.client.activate()
        if self.source_port:
            deadline = time.time() + self.connect_timeout
            while True:
                try:
                    self.client.connect(self.source_port, self.inport)
                    break
                except self.jack.JackError:
                    if time.time() > deadline:
                        ports = [p.name for p in self.client.get_ports(is_output=True, is_audio=True)]
                        raise RuntimeError(f"JACK port {self.source_port!r} not found; available: {ports}")
                    time.sleep(0.5)

    def stop(self):
        try:
            self.client.deactivate()
            self.client.close()
        except Exception:
            pass

    def wait(self, timeout: float) -> bool:
        ok = self.event.wait(timeout)
        self.event.clear()
        return ok

    def read_available(self) -> np.ndarray:
        n = self.ring.read_space // 4 * 4
        if n == 0:
            return np.empty(0, dtype=np.float32)
        return np.frombuffer(self.ring.read(n), dtype=np.float32).copy()


class WavSource:
    """Feeds a mono float array at wall-clock speed (or faster) through the same interface."""

    def __init__(self, audio: np.ndarray, sample_rate: int, speed: float = 1.0, block: int = 128):
        self.audio, self.sample_rate, self.speed, self.block = audio.astype(np.float32), sample_rate, speed, block
        self.xruns = self.overruns = 0
        self.shutdown = False
        self.done = False
        self.event = threading.Event()
        self._lock = threading.Lock()
        self._chunks: list[np.ndarray] = []
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self.shutdown = True

    def _run(self):
        t0 = time.perf_counter()
        pos = 0
        while pos < len(self.audio) and not self.shutdown:
            target = int((time.perf_counter() - t0) * self.sample_rate * self.speed)
            if pos + self.block <= target:
                with self._lock:
                    self._chunks.append(self.audio[pos:pos + self.block])
                pos += self.block
                self.event.set()
            else:
                time.sleep(0.0005)
        self.done = True
        self.event.set()

    def wait(self, timeout: float) -> bool:
        ok = self.event.wait(timeout)
        self.event.clear()
        return ok

    def read_available(self) -> np.ndarray:
        with self._lock:
            chunks, self._chunks = self._chunks, []
        return np.concatenate(chunks) if chunks else np.empty(0, dtype=np.float32)
