#!/usr/bin/env python3
"""Read HQPlayer's volume range off the control API, and settle what the
attributes on <VolumeRange/> actually mean.

    python3 tools/probe_volrange.py [<hqplayer-ip> ...]

With no argument it finds instances by the documented UDP multicast discovery.
READ-ONLY: it sends only queries (VolumeRange, State, Status subscribe="0",
GetInfo, GetTransport) and never a Volume or a transport command.

TWO RULES IT EXISTS TO KEEP:
  * Port 4321 ONLY.  A bare HTTP GET on hqplayerd's UPnP port 8019 spins its
    log at ~68k lines/sec until the connection closes - see CLAUDE.md.
  * NEVER sweep a subnet.  Multicast discovery, or an address you pass in.

ANSWERED 2026-09-05 against engine 6.0.4, and recorded in the Review Ledger:

  `enabled` IS NOT A FIXED-VOLUME FLAG.  With HQPlayer's own fixed volume
  configured AND applied (<fixed volume="-3"/> in ~/.hqplayer/hqplayerd.xml),
  the answer was unchanged:

      <VolumeRange adaptive="1" enabled="1" max="0" min="-100"/>

  The range does not collapse either.  hqplayerd's log agrees - `Volume max: 0`
  / `Volume min: -100` / `Control active volume range: -100 - 0 dB` at the
  restart that applied the setting - and the word "fixed" appears ZERO times in
  it.  HQPlayer's "fixed volume" is a STARTUP LEVEL, not a lock: it sets the
  output once and the volume stays changeable from HQPlayer's UI or the
  endpoint's device volume.  So there is no HQPlayer-side state to detect, the
  plugin reads min/max only, and the sole fixed-volume switch is LMS's own.

  Signalyst's own client settles the TYPES and nothing more:
  ControlInterface.cpp:2177 parses min/max as double and enabled/adaptive as
  bool; ControlApplication.cpp:668 only qDebug()s them.

STILL OPEN: `<engine volume_fixed="1">` in hqplayerd.xml is a DIFFERENT knob
from the <fixed volume="..."/> element, and was 0 throughout. By elimination it
is the only remaining engine attribute `enabled` could mirror (volume_hw was 0
while enabled was 1, ruling that out). Set it, restart hqplayerd, re-run this.
"""

import socket
import sys
import time

HDR = b'<?xml version="1.0" encoding="UTF-8"?>'
QUERIES = ('<VolumeRange/>', '<GetInfo/>', '<State/>',
           '<Status subscribe="0"/>', '<GetTransport/>')


def discover(timeout=3):
    """Instances answer the multicast probe; the address is the SENDER's."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.settimeout(0.5)
    s.sendto(HDR + b'<discover>hqplayer</discover>', ('239.192.0.199', 4321))

    found, end = [], time.time() + timeout
    while time.time() < end:
        try:
            _, addr = s.recvfrom(4096)
        except socket.timeout:
            continue
        if addr[0] not in found:
            found.append(addr[0])
            print(f"  discovered {addr[0]}")
    return found


class Control:
    """Framing per CLAUDE.md: no newline, no length prefix, and several
    messages can arrive in one read - so pull one complete message at a time."""

    def __init__(self, host, port=4321):
        self.sock = socket.create_connection((host, port), 5)
        self.buf = b''

    # ALWAYS CLOSE.  hqplayerd holds control connections open, and leaking one
    # per run will eventually get the next connect reset by peer.
    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def ask(self, cmd, wait=2.0):
        self.sock.sendall(HDR + cmd.encode())
        self.sock.settimeout(0.4)
        end, out = time.time() + wait, []
        while time.time() < end and not out:
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError as err:      # the daemon closed on us mid-probe
                out.append(f'(connection lost: {err})')
                break
            if not data:
                break
            self.buf += data
            while b'>' in self.buf:
                i = self.buf.index(b'>') + 1
                msg, self.buf = self.buf[:i].strip(), self.buf[i:]
                if msg and not msg.startswith(b'<?xml'):
                    out.append(msg.decode('utf-8', 'replace'))
        return out


def main():
    hosts = sys.argv[1:] or discover()
    if not hosts:
        print("no HQPlayer instance answered discovery")
        return 1

    for host in hosts:
        print(f"\n=== {host} ===")
        try:
            ctl = Control(host)
        except OSError as err:
            print(f"  cannot connect: {err}")
            continue
        with ctl:
            for cmd in QUERIES:
                try:
                    replies = ctl.ask(cmd)
                except OSError as err:
                    print(f"  {cmd:24} !! {err}")
                    break
                for line in replies or ['(no reply)']:
                    print(f"  {cmd:24} -> {line}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
