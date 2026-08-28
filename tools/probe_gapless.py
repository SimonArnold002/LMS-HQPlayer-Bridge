#!/usr/bin/env python3
"""Answer the questions the gapless hand-over design rests on.

Nothing here uses LMS or the plugin: it drives hqplayerd directly over the XML
control API, exactly the way Control.pm does, so the answers are about
HQPlayer's own behaviour and nothing else.

    python3 tools/probe_gapless.py <hqplayer-ip> <url-A> <url-B> [playlist|nexturi|both]

ANSWERED 2026-08-28 against engine 6.0.4.  Both arms were run; the results are
in CLAUDE.md.  In short:

  playlist   <PlaylistAdd uri="B" queued="1"> - append behind the playing item
             and let HQPlayer walk its own playlist.  *** THIS ONE WORKS. ***
             tracks_total 1->2, track 1->2 with no state 0 between them, clean
             state 0 at the end of the last item, daemon alive throughout.
             It is what Player.pm implements.

  nexturi    <PlayNextURI value="B"><metadata/></PlayNextURI> - a command that
             exists for exactly this.  *** IT KILLED THE DAEMON. ***  Answered
             result="OK", the next status showed it had REPLACED the playing
             uri rather than queuing behind it, and hqplayerd then exited: both
             4321 and 8019 stopped listening, and it did not restart itself.
             It is the default-off arm for that reason.

The questions each arm answers:

  Q1  Does the second track get accepted while the first one is playing?
  Q2  Does HQPlayer advance into it BY ITSELF, and is the advance observable
      in the status stream?  -> `track` moves on, and/or the <metadata uri="">
                                changes to url B, with NO state="0" in between
  Q3  Does state still reach 0 at the end of the LAST track, with repeat off?
      -> the run ends 2 -> 0, and the daemon is still answering afterwards

Whichever arm answers yes to all three is the mechanism to ship.  Repeat is
asserted off first, because repeat on makes the playlist never end (see
CLAUDE.md).
"""

import re
import socket
import sys
import time

HDR = b'<?xml version="1.0" encoding="UTF-8"?>'


class Control:
    """The framing rules from CLAUDE.md: no newline, no length prefix, and
    several messages can arrive in one read, so pull ONE complete message at a
    time rather than treating a read as a reply."""

    def __init__(self, host, port=4321):
        self.sock = socket.create_connection((host, port), 5)
        self.buf = b''

    def send(self, cmd):
        self.sock.sendall(HDR + cmd.encode())

    def read(self, timeout):
        end = time.time() + timeout
        while True:
            msg = self._extract()
            if msg is not None:
                return msg
            left = end - time.time()
            if left <= 0:
                return None
            self.sock.settimeout(left)
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not data:
                raise EOFError('hqplayerd closed the control link')
            self.buf += data

    def _extract(self):
        b = self.buf
        i = b.find(b'<')
        while i != -1 and b[i:i + 2] == b'<?':
            j = b.find(b'?>', i)
            if j == -1:
                return None
            b = b[j + 2:]
            i = b.find(b'<')
        if i == -1:
            return None
        j = b.find(b'>', i)
        if j == -1:
            return None
        head = b[i:j + 1]
        if head.endswith(b'/>'):
            self.buf = b[j + 1:]
            return head.decode('utf-8', 'replace')
        name = re.match(rb'<([A-Za-z0-9_]+)', head).group(1)
        close = b'</' + name + b'>'
        k = b.find(close, j)
        if k == -1:
            return None
        self.buf = b[k + len(close):]
        return b[i:k + len(close)].decode('utf-8', 'replace')

    def command(self, cmd, timeout=30):
        """Send and wait for the reply with the MATCHING ROOT TAG - a pushed
        Status can land between a request and its answer."""
        tag = re.match(r'<([A-Za-z0-9_]+)', cmd).group(1)
        self.send(cmd)
        end = time.time() + timeout
        while time.time() < end:
            msg = self.read(end - time.time())
            if msg is None:
                return None
            if re.match(r'<' + tag + r'\b', msg):
                return msg
        return None


def attrs(xml):
    return dict(re.findall(r'([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"', xml or ''))


def child(xml, name):
    m = re.search(r'<' + name + r'\b[^>]*/?>', xml or '')
    return attrs(m.group(0)) if m else {}


def esc(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;')
             .replace('>', '&gt;').replace('"', '&quot;'))


def run(host, url_a, url_b, arm):
    print()
    print('=' * 62)
    print('== arm: %s ==' % arm)
    print('=' * 62)

    c = Control(host)

    print('== setup ==')
    for cmd in ('<SetRepeat value="0"/>', '<Stop/>', '<PlaylistClear/>'):
        print('  %-28s %s' % (cmd, c.command(cmd)))

    add_a = ('<PlaylistAdd uri="%s" queued="0"><metadata song="probe A"/>'
             '</PlaylistAdd>' % esc(url_a))
    print('  A ->', c.command(add_a))

    if arm == 'playlist':
        # Append behind the playing item and let HQPlayer walk its playlist.
        hand = ('<PlaylistAdd uri="%s" queued="1"><metadata song="probe B"/>'
                '</PlaylistAdd>' % esc(url_b))
    else:
        # The purpose-built hand-over.  Note the attribute is `value`, not
        # `uri` - see playNextURI() in ControlInterface.cpp.
        hand = ('<PlayNextURI value="%s"><metadata song="probe B"/>'
                '</PlayNextURI>' % esc(url_b))

    print('  play ->', c.command('<Play/>'))

    # The hand-over goes in AFTER Play, which is the situation the plugin is
    # actually in: it only asks LMS for the next track once the current one is
    # confirmed playing.
    print('  B    ->', c.command(hand))

    print()
    print('== status stream ==')
    print('  %-8s %-5s %-6s %-5s %-4s %-9s  %s'
          % ('t', 'state', 'track', 'of', 'q', 'position', 'uri'))

    c.send('<Status/>')

    t0 = time.time()
    seen_track = None
    seen_total = None
    seen_queued = None
    advanced_without_stop = None
    stopped_at = None
    stops = 0
    last = None

    while time.time() - t0 < 180:
        try:
            msg = c.read(5)
        except EOFError as e:
            print('  *** %s ***' % e)
            return
        if msg is None:
            continue
        if not msg.startswith('<Status'):
            continue

        a = attrs(msg)
        m = child(msg, 'metadata')
        state = a.get('state')
        track = a.get('track')
        total = a.get('tracks_total')
        queued = a.get('queued')
        uri = m.get('uri', '')

        line = (state, track, total, queued, uri)
        if line != last:
            print('  %-8.1f %-5s %-6s %-5s %-4s %-9s  %s'
                  % (time.time() - t0, state, track, total, queued,
                     a.get('position', '')[:8], uri))
            last = line

        # `queued` is a BOOLEAN on <Status/> (onStatusResponse takes it as a
        # bool), so it should read 1 for as long as HQPlayer is holding the
        # hand-over and drop to 0 when it consumes it.  If it does, it is a
        # cleaner signal than either `track` or the uri.
        if queued and queued != '0':
            seen_queued = queued

        # The HIGH WATER MARK, not the first value: the append lands a second
        # or two after Play, so the first push still says 1.
        try:
            if total is not None and int(total) > int(seen_total or 0):
                seen_total = total
        except ValueError:
            pass

        if seen_track is None:
            seen_track = track
        elif track != seen_track:
            # The advance itself.  If we never saw state 0 before it, HQPlayer
            # made the transition under its own steam - which is the whole
            # point of pre-queuing.
            if advanced_without_stop is None:
                advanced_without_stop = (stops == 0)
            seen_track = track

        if state == '0':
            stops += 1
            if stopped_at is None and advanced_without_stop is not None:
                stopped_at = time.time() - t0
                break
            if stops > 3:
                break

    print()
    print('== answers (%s) ==' % arm)
    print('  Q1 second track held while playing    : tracks_total=%s queued=%s'
          % (seen_total, seen_queued))
    print('  Q2 HQPlayer advanced by itself        : %s'
          % ('YES, with no state 0 in between' if advanced_without_stop
             else 'NO - see the stream above' if advanced_without_stop is False
             else 'never advanced'))
    print('  Q3 state reached 0 at the end         : %s'
          % ('yes, at t=%.1fs' % stopped_at if stopped_at else 'NO'))

    try:
        alive = c.command('<GetInfo/>', 10)
        print('  daemon still alive afterwards         : %s'
              % ('yes' if alive else 'NO REPLY'))
    except (EOFError, OSError) as e:
        print('  daemon still alive afterwards         : NO - %s' % e)


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)

    host, url_a, url_b = sys.argv[1:4]
    arm = sys.argv[4] if len(sys.argv) == 5 else 'playlist'

    if arm == 'both':
        sys.exit('refusing: "both" runs the nexturi arm, which KILLS hqplayerd.\n'
                 'Run "playlist" (the default), or "nexturi" deliberately.')

    if arm == 'nexturi':
        print('*** WARNING: <PlayNextURI> TOOK HQPLAYERD DOWN on engine 6.0.4,')
        print('*** 2026-08-28, sent over a playing playlist item.  The daemon')
        print('*** exited outright - both 4321 and 8019 stopped listening and')
        print('*** it did not come back on its own.  Only run this knowing that.')
        print()

    try:
        run(host, url_a, url_b, arm)
    except (EOFError, OSError) as e:
        print('  *** arm %s died: %s ***' % (arm, e))
        print('  *** check hqplayerd is still running ***')


if __name__ == '__main__':
    main()
