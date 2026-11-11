"""Minimal OSC 1.0 encoder/decoder and UDP helpers (no third-party dependency)."""
from __future__ import annotations

import socket
import struct
import threading
from typing import Callable

import numpy as np


def _pad(b: bytes) -> bytes:
    return b + b"\0" * (4 - len(b) % 4)


def encode(address: str, args=()) -> bytes:
    tags = [","]
    payload = []
    for a in args:
        if isinstance(a, (bool, np.bool_)):
            tags.append("T" if a else "F")
        elif isinstance(a, (int, np.integer)):
            tags.append("i")
            payload.append(struct.pack(">i", int(a)))
        elif isinstance(a, (float, np.floating)):
            tags.append("f")
            payload.append(struct.pack(">f", float(a)))
        elif isinstance(a, str):
            tags.append("s")
            payload.append(_pad(a.encode()))
        else:
            raise TypeError(f"unsupported OSC argument {a!r}")
    return _pad(address.encode()) + _pad("".join(tags).encode()) + b"".join(payload)


def encode_floats(address: str, head: tuple, values: np.ndarray) -> bytes:
    """Fast path for ``/c_setn``-style messages: ``head`` ints followed by float32 ``values``."""
    n = len(values)
    tags = "," + "i" * len(head) + "f" * n
    return (_pad(address.encode()) + _pad(tags.encode()) + struct.pack(">" + "i" * len(head), *head)
            + np.asarray(values, dtype=">f4").tobytes())


def _read_str(data: bytes, i: int):
    j = data.index(b"\0", i)
    return data[i:j].decode(), (j + 4) & ~3


def decode(data: bytes):
    """Decode a message (bundles are flattened). Returns a list of ``(address, args)``."""
    if data.startswith(b"#bundle"):
        out, i = [], 16
        while i + 4 <= len(data):
            (size,) = struct.unpack_from(">i", data, i)
            out += decode(data[i + 4:i + 4 + size])
            i += 4 + size
        return out
    addr, i = _read_str(data, 0)
    if i >= len(data):
        return [(addr, [])]
    tags, i = _read_str(data, i)
    args = []
    for t in tags[1:]:
        if t == "i":
            args.append(struct.unpack_from(">i", data, i)[0]); i += 4
        elif t == "f":
            args.append(struct.unpack_from(">f", data, i)[0]); i += 4
        elif t == "d":
            args.append(struct.unpack_from(">d", data, i)[0]); i += 8
        elif t == "s":
            s, i = _read_str(data, i)
            args.append(s)
        elif t == "T":
            args.append(True)
        elif t == "F":
            args.append(False)
    return [(addr, args)]


class UdpSender:
    def __init__(self, host: str, port: int):
        self.addr = (host, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def send(self, packet: bytes):
        try:
            self.sock.sendto(packet, self.addr)
        except OSError:
            pass  # receiver not up yet; UDP is best effort

    def message(self, address: str, *args):
        self.send(encode(address, args))


class ControlServer(threading.Thread):
    """Receives ``/polytracker/...`` control messages from sclang."""

    def __init__(self, port: int, handlers: dict[str, Callable], host: str = "127.0.0.1"):
        super().__init__(daemon=True, name="osc-control")
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, port))
        self.sock.settimeout(0.25)
        self.handlers = handlers
        self.running = True

    def run(self):
        while self.running:
            try:
                data, _ = self.sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                for addr, args in decode(data):
                    h = self.handlers.get(addr)
                    if h:
                        h(*args)
            except Exception as e:  # a malformed packet must never kill the tracker
                print(f"[polytracker] bad control message: {e}", flush=True)

    def stop(self):
        self.running = False
        self.sock.close()
