#!/usr/bin/env python3
"""Two simulated consoles against bbnet_server: hello/list/join/start, then
a burst of relayed INPUT+CRC frames both ways.  Exit 0 = all assertions pass.
"""
import socket
import subprocess
import sys
import time

PORT = 9139


def frame(t, payload=b""):
    body = bytes([t]) + payload
    return bytes([len(body)]) + body


class Cli:
    def __init__(self, name):
        self.s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""
        self.name = name
        self.send(frame(0x01, bytes([1]) + name.encode()))

    def send(self, data):
        self.s.sendall(data)

    def recv_frame(self, timeout=5):
        self.s.settimeout(timeout)
        while True:
            if self.buf and len(self.buf) >= self.buf[0] + 1:
                n = self.buf[0] + 1
                body, self.buf = self.buf[1:n], self.buf[n:]
                return body[0], body[1:]
            chunk = self.s.recv(4096)
            if not chunk:
                raise EOFError
            self.buf += chunk


def main():
    srv = subprocess.Popen(
        [sys.executable, "server/intv_relay_server.py", "--port", str(PORT)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(0.4)
        a = Cli("ALICE")
        t, p = a.recv_frame()
        assert t == 0x03 and p[0] == 0, f"expected empty lobby, got {t:#x} {p!r}"

        b = Cli("BOB")
        t, p = b.recv_frame()
        assert t == 0x03 and p[0] == 1 and p[1:9].rstrip(b"\0") == b"ALICE"

        b.send(frame(0x04, b"ALICE"))          # BOB joins ALICE
        t, p = a.recv_frame()
        assert t == 0x05 and p[0] == 0, "ALICE should be host"
        seed_a, delay_a = p[1] | (p[2] << 8), p[3]
        assert p[4:12].rstrip(b"\0") == b"BOB"
        t, p = b.recv_frame()
        assert t == 0x05 and p[0] == 1, "BOB should be guest"
        seed_b = p[1] | (p[2] << 8)
        assert seed_a == seed_b and delay_a == p[3]
        assert p[4:12].rstrip(b"\0") == b"ALICE"

        # relay: 50 ticks of INPUT both ways + CRC every 10
        for tick in range(50):
            a.send(frame(0x06, bytes([tick & 255, tick >> 8, 0x11])))
            b.send(frame(0x06, bytes([tick & 255, tick >> 8, 0x22])))
            if tick % 10 == 0:
                crc = bytes([tick & 255, tick >> 8, 0x34, 0x12])
                a.send(frame(0x07, crc))
                b.send(frame(0x07, crc))
        got_a = got_b = 0
        deadline = time.time() + 5
        while (got_a < 50 or got_b < 50) and time.time() < deadline:
            if got_a < 50:
                t, p = a.recv_frame()
                if t == 0x06:
                    assert p[2] == 0x22
                    got_a += 1
            if got_b < 50:
                t, p = b.recv_frame()
                if t == 0x06:
                    assert p[2] == 0x11
                    got_b += 1
        assert got_a == 50 and got_b == 50, f"relay lost frames {got_a}/{got_b}"

        # disconnect handling
        a.s.close()
        t, p = b.recv_frame()
        assert t == 0x0B, f"expected PEER_LEFT, got {t:#x}"
        b.send(frame(0x02))
        t, p = b.recv_frame()
        assert t == 0x03 and p[0] == 0, "lobby should be empty after drop"

        print("bbnet server sim: ALL PASS "
              f"(seed=${seed_a:04X} delay={delay_a})")
    finally:
        srv.terminate()
        out = srv.stdout.read()
        if "--verbose" in sys.argv or "MISMATCH" in out:
            print(out)


if __name__ == "__main__":
    main()
