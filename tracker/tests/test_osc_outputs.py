import socket
import struct
import time

import numpy as np

from polytracker import oscmini
from polytracker.decoder import VoiceState
from polytracker.outputs import HEADER, OscOutput, block_size, pick_mono


def test_encode_matches_osc_spec():
    msg = oscmini.encode("/c_setn", (2, 3, 0.5, 1.0, -2.0))
    assert msg.startswith(b"/c_setn\0,iifff\0\0")
    body = msg[len(b"/c_setn\0,iifff\0\0"):]
    assert struct.unpack(">iifff", body) == (2, 3, 0.5, 1.0, -2.0)
    assert len(msg) % 4 == 0


def test_fast_path_equals_generic_encoder():
    vals = np.array([1.5, -3.25, 0.0], dtype=np.float32)
    assert oscmini.encode_floats("/c_setn", (7, 3), vals) == oscmini.encode("/c_setn", (7, 3, *vals.tolist()))


def test_roundtrip_with_strings_and_bundle():
    pkt = oscmini.encode("/polytracker/set", ("on", 0.6))
    assert oscmini.decode(pkt) == [("/polytracker/set", ["on", np.float32(0.6).item()])]
    inner = oscmini.encode("/a", (1,))
    bundle = b"#bundle\0" + b"\0" * 8 + struct.pack(">i", len(inner)) + inner
    assert oscmini.decode(bundle) == [("/a", [1])]
    assert oscmini.decode(oscmini.encode("/ping")) == [("/ping", [])]


def test_control_server_dispatches():
    got = []
    srv = oscmini.ControlServer(0, {"/polytracker/set": lambda *a: got.append(a)})
    port = srv.sock.getsockname()[1]
    srv.start()
    s = oscmini.UdpSender("127.0.0.1", port)
    s.message("/polytracker/set", "onset", 0.7)
    s.send(b"garbage")  # must not kill the server
    s.message("/polytracker/set", "on", 0.4)
    for _ in range(50):
        if len(got) == 2:
            break
        time.sleep(0.02)
    srv.stop()
    assert [g[0] for g in got] == ["onset", "on"]


def _voices(active, midi, freq, amp, t_on):
    return VoiceState(np.array(active), np.array(midi), np.array(freq, float), np.array(amp, float), np.array(t_on, float))


def test_mono_modes():
    vs = _voices([True, True, False, True, False, False], [50, 60, 0, 55, 0, 0], [100, 200, 0, 150, 0, 0],
                 [0.2, 0.9, 0, 0.5, 0, 0], [1.0, 3.0, 0, 2.0, 0, 0])
    assert pick_mono("lowest", vs) == 0
    assert pick_mono("highest", vs) == 1
    assert pick_mono("loudest", vs) == 1
    assert pick_mono("latest", vs) == 1
    none = _voices([False] * 6, [0] * 6, [0] * 6, [0] * 6, [0] * 6)
    assert pick_mono("latest", none) == -1


def test_block_layout_and_udp_delivery():
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(("127.0.0.1", 0))
    rx.settimeout(1.0)
    out = OscOutput(("127.0.0.1", rx.getsockname()[1]), ("127.0.0.1", rx.getsockname()[1]), bus_base=40, voices=6, mono_mode="lowest")
    vs = _voices([True, False, True, False, False, False], [52, 0, 64, 0, 0, 0], [164.8, 0, 329.6, 0, 0, 0],
                 [0.4, 0, 0.7, 0, 0, 0], [1, 0, 2, 0, 0, 0])
    out.send_block(vs)
    (addr, args), = oscmini.decode(rx.recv(4096))
    assert addr == "/c_setn" and args[0] == 40 and args[1] == block_size(6) == 22
    v = args[2:]
    assert abs(v[0] - 164.8) < 1e-3 and abs(v[1] - 0.4) < 1e-6 and v[2] == 2.0   # mono = lowest, count
    assert abs(v[HEADER + 2] - 329.6) < 1e-3                                       # voice freq slot 2
    assert abs(v[HEADER + 6 + 2] - 0.7) < 1e-6                                     # voice amp slot 2
    assert v[HEADER + 12 + 0] == 1.0 and v[HEADER + 12 + 1] == 0.0                 # gates
    out.send_block(vs)  # unchanged -> suppressed (heartbeat refresh only after 50 ms)
    rx.settimeout(0.01)
    try:
        rx.recv(4096)
        raise AssertionError("unchanged block should not be resent immediately")
    except socket.timeout:
        pass
    from polytracker.decoder import NoteEvent
    out.send_events([NoteEvent("on", 1.0, 2, 64, 329.6, 0.7), NoteEvent("off", 1.2, 2, 64, 329.6, 0.0)])
    rx.settimeout(1.0)
    m1, m2 = oscmini.decode(rx.recv(4096))[0], oscmini.decode(rx.recv(4096))[0]
    assert m1[0] == "/polytracker/noteOn" and m1[1][:2] == [2, 64]
    assert m2 == ("/polytracker/noteOff", [2, 64])
    rx.close()
