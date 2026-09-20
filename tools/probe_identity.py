#!/usr/bin/env python3
"""Settle whether an HQPlayer instance can be identified independently of its
address - and whether a dual-homed host answers discovery twice.

    python3 tools/probe_identity.py [<hqplayer-ip> ...]

With no argument it finds instances by the documented UDP multicast discovery.
READ-ONLY: it sends only queries (GetLicense, GetInfo) and never a transport,
volume or playlist command.

TWO RULES IT EXISTS TO KEEP (same as probe_volrange.py):
  * Port 4321 ONLY.  A bare HTTP GET on hqplayerd's UPnP port 8019 spins its
    log at ~68k lines/sec until the connection closes - see CLAUDE.md.
  * NEVER sweep a subnet.  Multicast discovery, or an address you pass in.

THE TWO QUESTIONS:

1. DOES ONE HOST ANSWER FROM TWO ADDRESSES?  Discovery keys instances by the
   SENDER address of the reply (Discovery.pm), while identity is keyed by the
   reply's `name` - which is a PRODUCT string every HQPlayer Embedded shares.
   So two addresses under one name split into two LMS players.  This counts
   replies per sender address across a burst of probes: two distinct senders
   for one host is the case that needs fixing, one sender means the
   simultaneous case does not exist and only the stale-entry path matters.

2. IS THERE AN ADDRESS-INDEPENDENT IDENTITY?  <GetLicense/> answers with
   valid/name/fingerprint (ControlInterface.cpp:1886).  A fingerprint is
   per-install, so two addresses returning the same one are provably one
   machine.  <GetInfo/> is asked alongside it because it carries `name` AND
   `product` as separate attributes and the plugin currently reads only
   `product` - if `name` is a configurable instance name it is a cheaper key
   than the licence, on a command the plugin already sends.

FIELD EVIDENCE ALREADY IN HAND (Simon, 2026-09-20): the licence keeps working
across a wired/wireless switch, so the fingerprint is stable across exactly the
transition that matters.  Short of proof only because hqplayerd may validate at
startup rather than continuously.  Run this on each interface to close that.
"""

import socket
import sys
import time
import re

HDR = b'<?xml version="1.0" encoding="UTF-8"?>'
MCAST = ('239.192.0.199', 4321)

PROBE_BURST = 3      # mirrors Discovery.pm: one datagram is easy to lose
PROBE_GAP = 0.2


def attrs(msg):
    """Attribute pairs out of one reply element.  Same job as Control::parseAttrs."""
    return dict(re.findall(r'([A-Za-z_][\w-]*)="([^"]*)"', msg))


def discover(timeout=4):
    """Every reply, NOT deduped: the point is to see a host answer twice."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    s.settimeout(0.3)

    for i in range(PROBE_BURST):
        try:
            s.sendto(HDR + b'<discover>hqplayer</discover>', MCAST)
        except OSError as err:
            print(f"  multicast send failed: {err} (is the network up?)")
            s.close()
            return {}
        if i < PROBE_BURST - 1:
            time.sleep(PROBE_GAP)

    replies = {}
    end = time.time() + timeout
    while time.time() < end:
        try:
            data, addr = s.recvfrom(4096)
        except socket.timeout:
            continue
        if b'<discover' not in data:
            continue
        a = attrs(data.decode('utf-8', 'replace'))
        ip = addr[0]
        seen = replies.setdefault(ip, {'count': 0, 'name': a.get('name', ''),
                                       'version': a.get('version', '')})
        seen['count'] += 1

    s.close()

    for ip, r in sorted(replies.items()):
        print(f"  discovered {ip:15}  name={r['name']!r}  "
              f"version={r['version']!r}  ({r['count']} replies)")

    if not replies:
        print(f"  nothing answered on {MCAST[0]}:{MCAST[1]}")

    return replies


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


def identify(host):
    """Returns the identity attributes for one address, or None."""
    try:
        ctl = Control(host)
    except OSError as err:
        print(f"  cannot connect: {err}")
        return None

    ident = {}

    with ctl:
        for cmd in ('<GetLicense/>', '<GetInfo/>'):
            try:
                replies = ctl.ask(cmd)
            except OSError as err:
                print(f"  {cmd:15} !! {err}")
                break
            for line in replies or ['(no reply)']:
                print(f"  {cmd:15} -> {line}")
            if replies:
                a = attrs(replies[0])
                tag = 'lic' if 'License' in cmd else 'info'
                for k, v in a.items():
                    ident[f'{tag}.{k}'] = v

    return ident


def main():
    given = sys.argv[1:]

    if given:
        hosts = given
        disco_names = {}
        print("=== discovery skipped, addresses given on the command line ===")
    else:
        print("=== discovery ===")
        found = discover()
        hosts = sorted(found)
        disco_names = {ip: r['name'] for ip, r in found.items()}

    if not hosts:
        print("\nno HQPlayer instance answered discovery.  Pass its address "
              "on the command line if this ran off-network.")
        return 1

    idents = {}

    for host in hosts:
        print(f"\n=== {host} ===")
        ident = identify(host)
        if ident:
            idents[host] = ident

    # --- the verdict ------------------------------------------------------
    print("\n=== verdict ===")

    if not idents:
        print("  no address answered on 4321 - nothing to compare")
        return 1

    print(f"  {'address':15}  {'lic.fingerprint':34}  {'info.name':22}  info.product")
    for host, i in sorted(idents.items()):
        print(f"  {host:15}  {i.get('lic.fingerprint', '(none)'):34}  "
              f"{i.get('info.name', '(none)'):22}  {i.get('info.product', '(none)')}")

    prints = {}
    for host, i in idents.items():
        fp = i.get('lic.fingerprint')
        if fp:
            prints.setdefault(fp, []).append(host)

    if not prints:
        print("\n  NO FINGERPRINT in any reply - identity by licence is OUT.")
    elif len(idents) == 1:
        print("\n  One address only.  Re-run on the other interface and compare "
              "the fingerprint by eye to settle whether it is stable.")
    else:
        for fp, hosts_ in prints.items():
            if len(hosts_) > 1:
                print(f"\n  SAME MACHINE, two addresses: {', '.join(hosts_)}")
                print("  -> the fingerprint merges them; the name alone splits them.")
            else:
                print(f"\n  {hosts_[0]} is alone on its fingerprint.")

    # COMPARED AGAINST DISCOVERY'S NAME, not against `product`.  The question
    # is whether `name` is a better key than what the bridge already keys on,
    # which is the discovery string - `product` is a different question, and
    # comparing that pair reported a useless key as a cheap one.  Measured on
    # the rig 2026-09-20: GetInfo name="HQPlayerEmbedded" IS the discovery
    # string, so it buys nothing.
    if not disco_names:
        print("\n  addresses were given by hand, so there is no discovery name "
              "to compare `name` against - re-run with no arguments for that.")
    else:
        named = [h for h, i in idents.items() if i.get('info.name')]
        same = [h for h in named if idents[h]['info.name'] == disco_names.get(h)]
        if not named:
            print("\n  no GetInfo `name` came back - nothing to compare.")
        elif len(same) == len(named):
            print("\n  GetInfo `name` == the DISCOVERY name on every instance - "
                  "it is no better a key than the one the bridge already has.")
        elif same:
            print(f"\n  GetInfo `name` matches discovery on {len(same)} of "
                  f"{len(named)} - not a dependable key either way.")
        else:
            print("\n  GetInfo `name` DIFFERS from the discovery name - it may "
                  "be a configurable instance name, and a cheaper key than the "
                  "fingerprint.  Check it survives an HQPlayer restart first.")

    return 0


if __name__ == '__main__':
    sys.exit(main())
