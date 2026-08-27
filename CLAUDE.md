# LMS-HQPlayer-Bridge

## Review Ledger

Verdicts already reached on review findings. **Read this before reporting one** —
a finding listed here has been considered and settled, and raising it again
costs a review round. Record every declined verdict in the same session it is
declined.

| Finding | Verdict | Why |
|---|---|---|
| The volume echo guard assumes `_lmsToDb(_dbToLms($db)) == $db`, which the clamp breaks below −100 dB, so an endpoint muted at −120 dB is written back up to −100 dB (`Player.pm`, `volume` / `_onStatus`) | **DECLINED** 2026-08-27 | No endpoint mutes below that level, and the LMS scale has to match what HQPlayer gives, which is −100. The clamp is the intended mapping, not a rounding bug. **Not to be confused with** the range being configurable at all — that is real, and scoped below. |

Presents each HQPlayer instance on the network as a native Lyrion player,
driven over HQPlayer's own XML control API. Replaces the `squeeze2upnp` UPnP
bridge path.

**No audio passes through this plugin.** LMS and HQPlayer are both *pull*
engines: LMS hands a player a URL and the player fetches the bytes; HQPlayer
does the same. So the bridge only moves control messages, and hands HQPlayer a
URL pointing back at LMS's own HTTP server. That removes the UPnP hop, the
external binary and the bridge's own buffer.

**The core premise is verified end to end** (2026-08-26, live hqplayerd 6.0.4):
`PlaylistAdd` accepts an arbitrary `http://` URI, and HQPlayer fetches it
itself — `HEAD` then `GET`, logged arriving at a plain Python HTTP server —
then plays it.

## Layout

| File | Role |
|---|---|
| `HQPlayerBridge/Plugin.pm` | Lifecycle, discovery wiring, player create/teardown |
| `HQPlayerBridge/Discovery.pm` | UDP multicast probe, instance list |
| `HQPlayerBridge/Control.pm` | Async TCP XML client + tiny XML helpers |
| `HQPlayerBridge/UPnP.pm` | Async SOAP to HQPlayer's UPnP renderer (metadata, artwork, volume) |
| `HQPlayerBridge/Player.pm` | `Slim::Player::Player` subclass - the virtual player |
| `HQPlayerBridge/Settings.pm` | Read-only status page |
| `tools/` | Stub LMS tree + checks, runnable without an LMS install |

## Branches and releasing

Work happens on **`dev`**. `main` is the release branch, and the two differ only
in `repo.xml`'s `<url>` — **different hosts, not a different branch segment**:

| branch | `repo.xml` `<url>` |
|---|---|
| `dev` | `https://raw.githubusercontent.com/SimonArnold002/LMS-HQPlayer-Bridge/dev/HQPlayerBridge.zip` |
| `main` | `https://simonarnold002.github.io/LMS-HQPlayer-Bridge/HQPlayerBridge.zip` |

`<sha>` is the same on both — the zip is identical, only where users fetch it
from differs. **Reconcile that one line on every merge**, and never let the dev
URL land on main: it points the production plugin repository at the dev zip, so
every user's next update installs a dev build. That has happened before on
LMS-ListenBrainz-New-Releases (2026-06-18), from exactly this cause — a
fast-forward merge silently carrying dev's `<url>` across. The first
`dev` → `main` merge here is the most exposed, because `main` doesn't exist yet
and will fast-forward by definition.

The **`plugin-ship` agent** does this reconciliation as part of a release; invoke
it by name once `plugin-build` has produced the zip. It verifies the URL on both
branches before pushing. Check the line by hand anyway — it is one grep:

```
git -C /Users/simona/Documents/GitHub/LMS-HQPlayer-Bridge show main:repo.xml | grep '<url>'
```

**`CHANGELOG.md` is written at the merge to main, never on a dev build.** A dev
build updates `CLAUDE.md`, `docs/*.md` and the memory notes only — a CHANGELOG
whose newest entry is several versions behind `install.xml` is CORRECT on `dev`,
not a defect.

**What the merge writes.** One new CHANGELOG entry, headed with the version being
released, listing **every change since the last commit on `main`** — not just
those from the final dev build. A release usually spans many dev versions, and
all of them ship at once, so the entry is compiled from the whole `main..dev`
range:

```
git -C /Users/simona/Documents/GitHub/LMS-HQPlayer-Bridge log main..dev --oneline
```

Group the result by what a user would notice (new features, fixes, behaviour
changes), not commit by commit — intermediate dead ends and their reverts cancel
out and belong in the per-version notes in this file instead. `README.md` is
refreshed in the same pass, and `README.html` / `index.html` regenerated from it
with `python3 tools/make_readme_html.py`.

## HQPlayer control protocol — all verified live

**Discovery** — UDP to `239.192.0.199:4321`, payload
`<?xml version="1.0" encoding="UTF-8"?><discover>hqplayer</discover>`:

```
<discover name="HQPlayerEmbedded" result="OK"
  version="Signalyst HQPlayer Embedded 6">hqplayer</discover>
```

The instance address is the datagram's **sender address** — not in the payload.

**Framing** — TCP 4321. Request is the literal `<?xml version="1.0"
encoding="UTF-8"?>` immediately followed by the command element. No newline, no
length prefix. **One command in flight at a time.** The connection is
persistent and survives many sequential commands, and survives `Stop`.

**Unknown commands do NOT drop the link.** They return
`result="Error"` with the text `Unknown command`, and the connection stays up.
An earlier note here claimed HQPlayer closes the socket on unrecognised XML —
that came from a third-party client and is **wrong**. The `%KNOWN` whitelist in
`Control.pm` is kept anyway: it keeps typos off the wire and gives callers a
clean failed callback rather than a puzzling Error reply.

**`<Status/>` is a SUBSCRIBE, not a poll.** Verified by isolation: playing
pushes nothing, seeking pushes nothing, but once a single `<Status/>` has been
sent HQPlayer streams Status messages at roughly 1/s, unsolicited, for as long
as the link is up. Consequences, both of which bit here:

* Several messages arrive in one read (a 7679-byte read where one Status is
  1286 bytes is six of them), so the reader must extract **one complete message
  at a time** — `Control::_extractMessage` — not treat a whole read as one
  reply.
* A push can land between a request and its reply, so replies are matched **by
  root element name**. Every command answers with its own tag: `<Pause/>`
  answers `<Pause>`, `<Stop/>` answers `<Stop>`. An earlier note here claimed
  those two answer with `<Status>` — that was an artifact of reading the push
  stream without framing it, and matching on it would let a pushed Status
  resolve a Pause.

Because the subscription does the work, the plugin **never polls**. It sends one
`<Status/>` and then only keeps a 10s watchdog to re-subscribe if the stream
dries up.

Only an explicit `result="Error"` counts as failure.

`PlaylistAdd` makes HQPlayer fetch and probe the media before answering, so it
can take many seconds against a slow origin — hence a 30s reply window.

**Volume is `<Volume value="-53"/>`, in dB** — probed against the live daemon
2026-08-27. `SetVolume`, `SetVolumeDB`, `GetVolume` and `GetVolumeDBRange` all
answer `Unknown command`; those exist in the binary as UPnP RenderingControl
actions, and an earlier note here inferred the wrong command name from them.
There is no *read* command either — but none is needed, because every
`<Status/>` carries the current level as `volume="-53"`.

### `<Status/>` — the shape that matters

```xml
<Status active_bits="24" active_mode="PCM" active_rate="11289600"
        length="153.40842708333332" min="0" position="0"
        remain_min="2" remain_sec="33" sec="0" state="2"
        track="1" tracks_total="1" volume="-39">
  <metadata bits="24" channels="2" mime="audio/x-flac" samplerate="96000"
            song="HTTP stream" uri="http://host/x.flac"/>
</Status>
```

* **`state` is an INTEGER**: `0` = Stopped, `1` = Paused, `2` = Playing.
  Matching it as a word silently never fires — this was a real bug here.
* `length` is the true duration in seconds, correctly read from the FLAC.
* Position is `position` (seconds), with a `min`/`sec` pair as a fallback.
* **`active_rate` is the DSD/output rate, not the source rate.** The source
  format is on the `<metadata/>` **child** (`samplerate`, `bits`).

## Two channels, and why both are needed

The XML API on 4321 is the better **state** channel — `<Status/>` is a subscribe
and pushes ~1/s. But it cannot do two things, and HQPlayer's **UPnP
MediaRenderer** (`http://<ip>:8019/root.xml`, `MediaRenderer:3`) can:

| | XML API (4321) | UPnP (8019) |
|---|---|---|
| transport + state | **used** — subscribe, pause, stop, seek | available |
| track + metadata + artwork | attributes silently ignored | **used** — `SetAVTransportURI` + DIDL-Lite |
| volume | **used** — `<Volume value="-53"/>` in dB, ~9ms | available but slow (300–550ms) |

So: **UPnP sets the URI and starts playback, the XML API reports state.** Both
drive the same engine — verified, `<Status/>` tracks a UPnP-started session
exactly, and an XML `<Stop/>` cleanly stops one.

**Artwork is the whole reason for this split.** Over the XML API HQPlayer labels
any http source `song="HTTP stream"` and ignores `title`/`artist`/`album`/`song`
attributes on `PlaylistAdd`. Over UPnP it honours all of them, including
`<upnp:albumArtURI>`, which it then re-serves from its own web server at
`/cover/current` — and that is where an endpoint's display fetches the cover.
This is exactly what squeeze2upnp was relying on, and why artwork appeared
through the UPnP bridge but not through the first version of this plugin.

**Volume goes over the XML channel**, not UPnP — see the volume section below.
UPnP `RenderingControl` does work and speaks 0–100, but measured against the
live daemon it takes **300–550ms** per call where an XML command on the already
open control socket answers in **~9ms**. That was the volume lag.

### TRAP: artwork comes from two different places

**Local track** -> the **direct** `/music/<coverid>/cover.jpg`.
`Slim::Web::ImageProxy::proxiedImage` is for REMOTE artwork; handed a local LMS
path it returns the "no artwork" placeholder (a 16.7 KB 512x512 PNG) instead of
the real cover (a 79 KB 700x700 JPEG) - which is exactly the blank icon that
appeared on the endpoint. `tools/t_player.pl` asserts a local cover URL never contains `/imageproxy/`.

**Remote track (Qobuz, Tidal, radio)** -> ask the protocol handler.  A remote
track has a **negative** track id and no coverid, so the local route builds
`/music/-94543041325440/cover.jpg` and gets the placeholder back - the same
blank icon, from a completely different cause.  `Slim::Player::ProtocolHandlers
->handlerForURL(...)->getMetadataFor(...)` yields `cover`/`icon`, usually
already an `/imageproxy/` path, which is what the proxy is genuinely for.  If
the handler has no artwork, emit **no** `albumArtURI` rather than a bad one.

### TRAP: Play races SetAVTransportURI

`SetAVTransportURI` returns as soon as it has *accepted* the URI, but HQPlayer
then fetches and probes the media before the transport actually holds anything.
`Play` issued too early fails with UPnP **702 "no contents"** — measured: at
~0.5s it fails, the identical call ~1s later succeeds. Nothing in
`GetMediaInfo` reflects it (`NrTracks` already reads 1), so
`UPnP::playWhenReady` simply retries (8 × 0.4s).

The retry is deliberately **blind to which error came back**: a UPnP fault is an
HTTP 500 whose `errorCode` is in the body, not in the status line the async
client hands us, so "is this the transient 702" is not reliably answerable from
`$err` — and guessing wrong breaks the ordinary case, where a failed first Play
is normal. What is bounded instead is the **wait**: `PLAY_TIMEOUT` (5s) per
attempt and a `PLAY_DEADLINE` (12s) across the loop. Eight attempts at the
general 15s SOAP timeout was ~2 minutes of a player that looks like it is
buffering before it admits the track failed.

### TRAP: describe() must retry itself

Without a device description there is no control path, and `_queueTrack` fails
every track with `PROBLEM_OPENING` — the player exists but can never play
anything. `describe` runs when the player is created and again when the control
link comes **up**, and *neither of those recurs*: LMS and hqplayerd starting
together (a server reboot) is exactly the case where the first fetch fails and
the control link then stays up, so no further attempt would ever be made. It now
retries itself with backoff (5s → 60s) until it succeeds, and `UPnP::close` —
called from `_teardown` — stops that and the Play retry loop when the player
goes away.

Note `SetAVTransportURI` is logged by hqplayerd as `Playlist clear` +
`Playlist add URI` — it lands on the same playlist the XML API uses.

## One thing HQPlayer still will not do

**The NAA name is not exposed.** `GetTransport` answers with a bare numeric
id (`arg="" value="240"`) and no device name. `GetInputs` lists sources
(`cd:`), not outputs. The endpoint name appears only in hqplayerd's own log
(`NAA output endpoint 'Eversolo:DMP-A8(ManCave)' : 'hw:0'`), which is not
reachable from another host. The status page therefore reports the transport id
and says plainly that the name is unavailable.

## TRAP: the client object is a blessed ARRAY

`Slim::Player::Client` inherits `Slim::Utils::Accessor`, which stores each field
in a numbered array slot (`$_[0]->[$n]`) — **not** a hash key. So

```perl
$client->{_myField} = 0;      # fatal: Not a HASH reference
```

Every piece of per-player state must be a declared accessor:

```perl
__PACKAGE__->mk_accessor( 'rw', qw( hqControl hqStarted hqPosition ... ) );
$client->init_accessor( hqStarted => 0, ... );
```

`'rw'` switches on argument count (`@_ == 2`), so storing `0` and `undef` both
work — it is not a truthiness test.

This cost a live debugging round. `Player::new` set hash keys, so every player
creation died; and because `_create` runs inside a discovery **timer callback**,
the only symptom was `Error: Timer ...Discovery::_roundDone failed:` with the
cause swallowed. `_onInstances` now evals per instance and logs the real error,
and `tools/t_player.pl` builds a real player object and asserts a hash write
dies — the stub `Slim::Utils::Accessor` is array-based precisely so this class of
bug fails offline instead of on the server.

## Why `Slim::Player::Player`, not `Squeezebox`

Everything that assumes a live SlimProto socket (`$client->tcpsock`) lives in
`Slim::Player::Squeezebox` and below. Subclassing `Player` sidesteps all of it.
`tcpsock(1)` is a literal `1`, never a socket. Same approach as philippe44's
LMS-Groups.

**Do not** copy LMS-Groups' `sub chunks { [] }` — that class deliberately
carries no audio, whereas tier 2 below needs the real chunk pipeline.

## Track resolution — two URL tiers

Everything is addressed **by URL, never by filesystem path**: HQPlayer's view of
the library mount will not match LMS's, and reconciling them would need exactly
the per-install configuration this plugin exists to avoid.

1. **Local library track HQPlayer can actually decode** →
   `/music/<trackid>/download.<ext>` — original file bytes, range-seekable,
   native DSD. Confirmed live end to end: a 48/24 FLAC from the library played
   through to the NAA with `mime=audio/x-flac` and position advancing.

   **HQPlayer chooses its decoder by HTTP Content-Type, not by filename.**
   Verified the hard way — it refused a track with
   `clPlaylist::AddURI(): unknown mime type: audio/m4a` despite a sensible
   extension, then reported `Play(): Empty transport` because nothing had been
   added. Its mime table (from the binary) covers flac, wav, aiff, dsf/dff,
   wavpack, mpeg/mp3 and ogg, and has **no m4a, mp4, aac or alac entry at all**.
   So `%HQP_PLAYS` in `Player.pm` gates tier 1 by LMS content_type, and anything
   else falls through to tier 2 for LMS to transcode.

   The extension is still worth setting, but for LMS's benefit rather than
   HQPlayer's: `downloadMusicFile` only transcodes when the resolved type differs
   from the track's own, so a truthful extension keeps it a byte-for-byte
   passthrough.
2. **Anything remote** → `/stream.mp3?player=<mac>` — transcoded per `formats()`
   (`flc` first, so no transcoder in the common case).

Range support matters: HQPlayer logs `clStreamReaderHTTP::Skip(): not seekable!`
against servers that lack it (Python's `http.server` does). LMS's download route
supports ranges, so seeking should work — untested.

## State machine

`<Status/>` is a subscribe (see above), so `Player::_onStatus` runs on each
pushed message and maps it onto the controller callbacks:

| HQPlayer | LMS |
|---|---|
| `state` → 2, first time **for an acknowledged track** | `playerTrackStarted` **only** |
| position advancing | `playerStatusHeartbeat` |
| `state` 2 → 0, not ours | `playerEndOfStream` + `playerReadyToStream` + `playerStopped` |
| command rejected | `playerStreamingFailed('PROBLEM_OPENING')` |

### TRAP: a track change straddles the status stream

HQPlayer pushes status ~1/s and a track change is several async round trips
(`<Stop/>`, then `SetAVTransportURI`, then `Play` with retries), so **a push
describing the previous track routinely arrives after the next one has been set
up**. Read as current, that push starts a track HQPlayer has not begun, and the
stop that follows it then reads as end-of-track — LMS advances, and the track it
has just started is *skipped*. Three things stop it, and all three are needed:

* **`hqExpectStop` is ARMED by `play()`, not cleared by it.** Between `play()`
  and HQPlayer confirming the new track, any stop it reports is the one we sent
  to end the previous track. It is disarmed only when the new track is
  confirmed playing.
* **`hqPlayAck`** — set when `Play` is accepted for *this* track. Until then a
  PLAYING push is not evidence that this track is running, so it neither starts
  the track nor disarms the guard.
* **The `<metadata uri="">` child** is the only per-track identity in the status
  stream. `_isStale` uses it *one-sidedly*: a push counts as stale only when its
  uri is exactly `hqPrevURL` and not `hqURL`. Anything unrecognised — a
  normalised uri, no metadata child, or tier 2, where every track comes off the
  same `/stream.mp3` URL — is treated as current, so this can only ever suppress
  a push positively identified as the previous track's. It can never wedge
  playback. Volume is still followed from a stale push; it belongs to the
  instance, not the track.

### TRAP: an async load outlives the track that started it

A stop or a skip during the load window used to leave the *previous* track's
completion callback to fire anyway — re-asserting `bufferReady`, restarting the
poll, and applying that track's `<Seek>` and `hqSeekOffset` to whatever is
playing now, so elapsed time was wrong for the whole track.

`play()` and `stop()` both call `_newGeneration`: it bumps `hqGen`, which every
in-flight callback compares itself against (`_superseded`), and calls
`UPnP::cancelPlay`, which bumps an epoch the Play retry loop checks — the retry
is a timer, so it needs cancelling separately from the callback.

### Two-way transport: `hqWanted`, and why not the controller's state

Pausing at HQPlayer's own UI, or on the endpoint's remote, has to pull LMS with
it — otherwise LMS keeps counting time against silent audio. `_onStatus`
therefore compares HQPlayer's reported state against **`hqWanted`: the last
transport state we asked HQPlayer for**. Agreement means the change was ours;
divergence means somebody else caused it, and LMS follows.

It must not be keyed off the controller's `playingState`. `_Pause` sets PAUSED
and *then* fades the volume, calling our `pause()` only from the fade's
completion callback ~300ms later. A status push arriving in that window shows
HQPlayer still PLAYING while the controller already says PAUSED — which reads
as an external resume and un-pauses the player. `hqWanted` is still `play`
through that whole window, so there is no divergence to react to.

Both directions then suppress the echo: the `pause()` / `resume()` that LMS
calls in response finds `hqWanted` already at its target and sends nothing.

Two traps in the follow-up call:

- **`$controller->pause` is a toggle.** The `Pause` event in the PAUSED row of
  the state table is `_Resume` / `_JumpOrResume`. Guard it with `isPaused`.
- **`$controller->resume` outside PAUSED is `_Invalid`** and only logs an
  error. Same guard, inverted.

`<Pause/>` is likewise never sent twice in a row, in case HQPlayer treats it as
a toggle rather than a set.

### TRAP: a full buffer makes pause tear the stream down

`bufferFullness` / `bufferSize` is not a free-choice constant. `usage()` is the
ratio of the two, and `_CheckPaused` — reached from our *own*
`playerStatusHeartbeat` while PAUSED — does this:

```perl
if ($song->currentTrackHandler()->isRemote() && $self->master()->usage() > 0.98) {
    ... _pauseStreaming($self, $song);   # closes the source stream
}
```

That is LMS bug 10645: on a paused remote track whose buffer is full, release
the remote connection, because the player has all the audio it needs. **That
assumption is false for this player** — HQPlayer keeps pulling from us for as
long as it is paused. `_pauseStreaming` calls `_stopClient` on every player,
which is our `stop()`, which sends `<Stop/>`. HQPlayer's engine stops and the
NAA disconnects, which reads exactly like a crash but is not one: hqplayerd
logs an orderly `Pause` → `Stop...` → `...stopped`, and no diagnostic report is
written.

Resume then finds `streamingState` IDLE, so `Pause` in PAUSED/IDLE routes to
`_JumpOrResume` — a full re-stream plus a seek to `resumeTime`, not a resume.

So report a buffer that is healthy but never full. The answer to "is it safe to
close the stream" is, for this player, always no.

### TRAP: songElapsedSeconds is stream-relative, and the two tiers differ

`playingSongElapsed` computes `startOffset + songElapsedSeconds`. LMS adds the
offset itself, so what we report must be elapsed **within the stream we were
handed**, never absolute position in the track.

The tiers put the offset in different places:

| | who applies the seek | HQPlayer's `position` |
|---|---|---|
| tier 1 (`/music/<id>/download.ext`) | us, via `<Seek>` — LMS is not in the byte path | absolute in the file |
| tier 2 (`/stream.mp3?player=`) | LMS, when it opens the source (`canDirectStream` is 0) | relative, starts at 0 |

So `<Seek>` goes out on tier 1 only — sending it on tier 2 skips a second time
and lands at twice the offset — and `songElapsedSeconds` subtracts
`hqSeekOffset`, which is set only when we actually asked HQPlayer to skip.
Getting this wrong makes LMS run at double the real elapsed time.

### TRAP: a virtual player must assert `bufferReady` itself

This is the one that made pause look dead while audio played perfectly.

`playerBufferReady` does **not** mean "the controller now believes the buffer is
ready". It is only an *event*: `BufferReady` in `BUFFERING` routes to
`_WaitToSync`, which immediately calls `_StartIfReady`, and that loops over every
player asking `$player->isBufferReady()` — which returns the client's own
`bufferReady` accessor. On real hardware that flag is set by the Squeezebox STAT
handler. **Nothing sets it for a virtual player.** So `_StartIfReady` always
declines, and the controller parks in `WAITING_TO_SYNC` for the whole track.

That state is near-invisible: a status query still reports `mode="play"`, the
progress bar still advances (we feed `songElapsedSeconds` from HQPlayer), and
audio is fine because HQPlayer is pulling regardless. But look at the state
table for `WAITING_TO_SYNC`:

| event | action |
|---|---|
| `Pause` | `_NoOp` — **silently discarded** |
| `Started` | `_Invalid` — our `playerTrackStarted` thrown away |
| `Stop` / `Play` | `_Stop` / `_StopGetNext` — these *do* work |

Which is exactly the reported symptom: stop and play fine, pause does nothing.

So: `$self->bufferReady(1)` **before** `playerBufferReady`, and back to 0 in
`play()` and `stop()` so a stale 1 can never start the next track early. The
`waitingToPlay: 1` field in a JSON-RPC `status` reply is the tell.

## Volume is shared, not owned

HQPlayer holds the real level in dB and splits it between the endpoint's
hardware attenuator and its own software gain (`Set volume: -53` →
`hardware: -49  software: -4`). LMS holds an 0-100 slider. Neither owns it:

| direction | how |
|---|---|
| LMS → HQPlayer | `volume()` sends `<Volume value="…"/>` on the control socket |
| HQPlayer → LMS | `_onStatus` reads `volume=""` off the status push, ~1/s, free |

`hqVolDb` is the last level we know HQPlayer is at, and it is what stops the two
directions chasing each other: neither side re-sends a value already equal to it.
The inbound direction goes through `execute(['mixer','volume',…])` rather than
the accessor, so Material and anything else watching the slider is notified.

`dB = LMS − 100`, so LMS 100 is 0 dB and **one LMS step is 1 dB** — the same
mapping HQPlayer's UPnP endpoint was applying to the 0-100 it received, so the
slider feels unchanged.

**That 1:1 is only correct because this instance's range is set to −100…0.**
See the scoped section below — HQPlayer's range is user-configurable and
defaults to −60…0, which the mapping does not currently account for.

### TRAP: the second argument to `volume()` is `$temp`, not "force"

`Client::volume($vol, $temp)` stores a *temporary* level that is not persisted,
and `Client::volume()` returns a temporary level in preference to the real one.
LMS ramps the volume down and back up around every pause and resume — one write
every 50ms for 0.3s each way — and **every step of that ramp arrives with
`$temp` set**. Forwarding them floods HQPlayer, dips the endpoint's volume on
each pause, and races to land out of order (which can strand it at zero).

So only a persisted change is forwarded. Mute goes through the persisted path,
so it still reaches HQPlayer.

`fade_volume` is then overridden to skip the ramp. The ramp is inaudible here
anyway now that its steps are dropped, and `_Pause` fires the actual pause
**from that callback** — so for a pause it was pure latency, delaying every
pause by 300ms. The override must also clear the temporary volume, because
`_Resume` parks a temporary 0 before its fade-in and the slider would otherwise
read zero after every resume.

**But the DURATION still matters.** `fade_volume` is not only the pause ramp:
the sleep timer calls it with the whole fade-out time (up to a minute) and
**stops the player from the same completion callback**. Firing that immediately
ended playback a full fade early — the sleep timer appearing to fire at the
wrong time. So short ramps (≤ `FADE_IMMEDIATE`, 1s) complete immediately and
anything longer is deferred to a timer, which a subsequent `fade_volume`
cancels. The audio genuinely does not fade: a real ramp would have to move
HQPlayer's own level, which is *shared*, so `_onStatus` would mirror every step
back into the slider and an interrupted fade would leave the endpoint turned
down for good. The timing — which is what the user set — is exact.

### SCOPED, not built: the volume range is configurable

`HQP_VOL_MIN_DB => -100` is not a property of HQPlayer, it is a property of
**this** instance's configuration. HQPlayer's output volume range is a user
setting and **defaults to −60…0**; −100…0 is what the development machine
happens to be set to, which is why a 1:1 dB-per-step mapping has looked right
throughout. On a default instance the current mapping is wrong in two visible
ways:

* **The bottom 40% of the slider is dead.** LMS 40 already maps to −60 dB, the
  floor; LMS 39…0 map to −61…−100, which HQPlayer clamps back to −60.
* **The slider snaps back.** Worse than the dead zone, and easy to misread as a
  UI bug. HQPlayer reports the *clamped* level in the next `<Status/>`, the
  mirror in `_onStatus` sees a level that differs from `hqVolDb`, and pushes it
  into LMS as an external change — so dragging to 20 bounces the slider to 40.

**The mapping.** Proportional across a known range, with max fixed at 0 dB:

```
dB  = min * (1 - lms/100)          # lms 100 -> 0 dB,  lms 0 -> min
lms = 100 * (1 - dB/min)
```

At `min = -100` this is arithmetically identical to `dB = lms - 100`, so this
instance's feel and the existing assertions are unchanged — the generalisation
is free here. `min` becomes a per-player accessor (`hqVolMinDb`), so
`_lmsToDb` / `_dbToLms` become methods rather than plain functions, and the
tests that call them directly move with them.

**Where `min` comes from**, best first:

1. **UPnP `GetVolumeDBRange`** on RenderingControl (`/control/rendering-control`),
   at describe time and again whenever the control link comes up. The action is
   known to exist in the binary — it is what the XML API answers `Unknown
   command` for. One SOAP call per connect, off the hot path, so its 300-550ms
   does not matter. **Unverified: whether HQPlayer implements it, and in which
   units** — the UPnP AV spec says `VolumeDB` is in **1/256 dB**, so −60 dB
   should arrive as −15360, but implementations often return whole dB. Treat
   `abs(value) > 200` as 1/256 units and divide.
2. **Derive it from one `GetVolume` + one `<Status/>`.** RenderingControl's
   `GetVolume` answers 0-100 on HQPlayer's own scale; the status stream gives
   the same moment in dB. Assuming a linear map with max 0,
   `min = D / (1 - V/100)` for `V < 100`. Passive, no volume change, nothing new
   to configure — a good cross-check on (1) and a fallback if it is missing.
   Undefined as V approaches 100.
3. **Learn the floor from the clamp.** Send a level below the floor and
   HQPlayer reports the clamped one back: that value *is* `min`. Self-correcting
   and the only option that survives the user reconfiguring HQPlayer without a
   reconnect, but it only learns once the user drags to the bottom. Keep it as
   the safety net behind (1)/(2), and discriminate it from a genuine external
   change by requiring the push to follow our own send closely and to be higher
   than what we asked for.
4. **A pref.** One number on the settings page. Cheap and honest, but the page
   is read-only today and the plugin's premise is zero configuration — so this
   is an override for when the probes disagree, not the primary route.

**The fallback stays −100 for now.** The asymmetry argues for −60: guessing
−60 when the truth is −100 costs resolution but leaves every slider position
working, while guessing −100 when the truth is −60 gives the dead zone and the
snap-back. But the only instance in the field is configured −100, so flipping
the fallback before (1) is verified would regress the one real user. Flip it
once the probe is proven.

**The echo guard has to change with the scale.** At 1:1 every dB has exactly one
LMS step, so comparing against `hqVolDb` is safe. At −60, one LMS step is 0.6 dB
and several steps share a dB — so the guard must compare **in dB, against the
slider's own current position** (`_lmsToDb($self->volume) != $db`), not against
the last value we sent. Otherwise the mirror fights the user on every drag.
This is the same round-trip question as the declined finding in the ledger, but
it becomes real as soon as the mapping is not 1:1.

Whatever is learned should be shown on the status page alongside the transport
id — it is the one number that explains the whole feel of the slider.

**Verify before building** (needs the live instance; substitute its address):

```
curl -s -X POST http://<hqplayer-ip>:8019/control/rendering-control \
  -H 'Content-Type: text/xml; charset="utf-8"' \
  -H 'SOAPACTION: "urn:schemas-upnp-org:service:RenderingControl:3#GetVolumeDBRange"' \
  --data '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetVolumeDBRange xmlns:u="urn:schemas-upnp-org:service:RenderingControl:3"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetVolumeDBRange></s:Body></s:Envelope>'

curl -s -X POST http://<hqplayer-ip>:8019/control/rendering-control \
  -H 'Content-Type: text/xml; charset="utf-8"' \
  -H 'SOAPACTION: "urn:schemas-upnp-org:service:RenderingControl:3#GetVolume"' \
  --data '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetVolume xmlns:u="urn:schemas-upnp-org:service:RenderingControl:3"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetVolume></s:Body></s:Envelope>'
```

and, to find out whether the clamp is observable at all — this one works on a
−100…0 instance without reconfiguring anything, because −120 is below its floor
too:

```
{ printf '<?xml version="1.0" encoding="UTF-8"?><Volume value="-120"/>'; sleep 1; printf '<?xml version="1.0" encoding="UTF-8"?><Status/>'; sleep 3; } | nc <hqplayer-ip> 4321
```

Read the `volume=` in the pushed `<Status/>`: **−100 means the clamp is
observable** and route (3) works; an error reply or the level unchanged means it
is not, and (1)/(2) carry the whole design. Set the volume back afterwards.

### TRAP: never send ReadyToStream while a track is playing

`playerReadyToStream` means "I can accept another stream", and LMS answers it by
streaming the **next** song and calling `play()` again. For this player that
means `SetAVTransportURI` + `Play` — clobbering the track still playing. Sending
it alongside `playerTrackStarted` (which is what a gapless Squeezebox does)
churned the controller and left it stuck short of `PLAYING`. We are not gapless,
so it belongs at end-of-track only.

That matters because **`pause` is a silent no-op unless `playingState` is
`PLAYING`(3) or `PAUSED`(4)**, while `BUFFERING`(1) and `WAITING_TO_SYNC`(2)
*both still report `mode="play"`* to a status query. So a stuck controller looks
exactly like a playing one: `stop` and `play` work, `pause` does nothing, and no
`<Pause/>` ever reaches HQPlayer. `Player::_ctlState` logs the real
`playingState`/`streamingState` alongside our own, because LMS will not write
`player.source` debug into `log.txt` even with the category set to DEBUG.

`stop()` sets `hqExpectStop` so a *user* stop is not misread as end-of-track —
and `play()` leaves it armed, see the track-change trap above.
End-of-track detection is confirmed working: `state` goes 2 → 0 on its own when
a track finishes.

## Player identity

Synthetic MAC derived from the instance **name** (not its address), so a DHCP
move does not orphan the player's prefs, playlist and sync group. The `02:`
prefix marks it locally administered, so it can never collide with real
hardware.

**TRAP: the discovery name is a PRODUCT string, not an identity.** Every
HQPlayer Embedded instance answers `HQPlayerEmbedded`, so on the name alone two
instances are one player: every discovery round found the id it already had
arriving with the other one's address, took that for a DHCP move, tore the
player down and rebuilt it — killing playback every 60 seconds. (A real DHCP
move has the same shape, because the old address lingers in the discovery table
for `INSTANCE_TTL`.)

So `_idsFor` assigns ids across the **whole discovered list** at once: a name
only one instance answers to keeps the plain name-derived id and its DHCP
immunity, and a name more than one instance answers to is qualified by address
for all of them — id *and* display name, since two identically named players
are unusable anyway. Re-keying when a second instance appears costs that
player's prefs once; the thrash cost them every round.

## Testing without LMS

`sh tools/run_checks.sh` — syntax-checks all six modules against the stub Slim
tree, runs 189 assertions across four files, and sweeps called-vs-defined subs.

| file | covers |
|---|---|
| `t_control.pl` | XML framing, attribute parsing, escaping, **real captured hqplayerd payloads** |
| `t_player.pl` | player construction, DIDL, artwork, the controller handshake, seek accounting, two-way transport, volume, **track changes and fade duration** |
| `t_upnp.pl` | the describe retry, the bounded Play loop, cancellation |
| `t_plugin.pl` | player identity across a DHCP move and duplicate names, version drift |

The stub `Slim::Utils::Accessor` is deliberately array-based, mirroring the real
one, so hash-slot mistakes fail here rather than on the server.
`Slim::Utils::Timers` is a real enough scheduler (`_pending` / `_fireAll`),
mirroring LMS's `setTimer($obj, $when, $cb, @args)` → `$cb->($obj, @args)`, so
timer-driven behaviour is testable offline.

**TRAP: `ok($src =~ /re/, 'name')` evaluates the match in LIST context.** A
*failed* match returns the empty list, so `@_` collapses to just the name, the
name lands in the condition slot as a true value, and the broken assertion
prints `ok` with a blank label and counts as a pass. Two assertions in
`t_player.pl` had been dead that way — naming a `_flushVolume` debounce that no
longer exists — while the suite reported 83/83. `ok()` now takes the name off
the *end* and treats what is left as the condition, so an empty list reads as
false. A blank assertion label is the tell.

**The version is not written down twice.** `PLUGIN_VERSION` was a hand-maintained
constant sitting at 0.2.3 while `install.xml` and `repo.xml` were at 0.2.7, so
the startup log and the settings page both named a build that had not run for
months. `Plugin::version` reads what LMS parsed out of `install.xml`, and
`t_plugin.pl` asserts `install.xml` and `repo.xml` agree and that no module
keeps a copy.

The stub tree is not a simulator and proves nothing about runtime behaviour.
And remember `perl -c` will not catch a call to a sub that does not exist —
hence the sweep.

## Verified working against the live daemon

With HQPlayer's output set to PCM 48k (it had been on SDM/DSD 11289600, which
the NAA endpoint could not accept — see below), a real 96/24 FLAC served over
HTTP played correctly:

* **Audio renders and `position` advances** (`process_speed` ~80), so the LMS
  progress bar has a real source.
* **`Seek` works** — `<Seek position="45"/>` returns OK and moves playback.
* Transport verbs all answer OK and behave: `PlaylistClear`, `PlaylistAdd`,
  `Play`, `Pause`, `Stop`.
* Volume works over the XML channel: `<Volume value="-54"/>` → `result="OK"`,
  the level moves, and hqplayerd logs the hardware/software split to the NAA.
  `SetVolume`/`SetVolumeDB`/`GetVolume` all answer `Unknown command`.
* End of track is detectable: `state` goes 2 → 0 on its own.

**Watch for a silent output-format mismatch.** When HQPlayer's output format
exceeds what the endpoint accepts, it reports `state=2` and returns OK to
everything while rendering nothing. The only evidence is `process_speed=0` /
`output_fill=0`, and in the log:

```
% NAA output requested format not available!
! NAA output clNetEngine::PushPCM(): engine not ready
```

Never conclude "playback works" from `state` alone.

## Still unverified

* Seek initiated from LMS, and tier 2 (`/stream.mp3?player=`) Content-Type
  matching the format actually streamed.
* `Player::connected` returns `tcpsock` (a literal 1) as LMS-Groups does, so LMS
  shows the player as present even when the control link is down. Discovered-but-
  unreachable is a normal recurring state here (the NAA lives at home), and
  tying the two together would risk LMS churning prefs and sync groups.

## Not in v1

Gapless pre-queuing, HQPlayer DSP/filter/mode selection from LMS, HQPlayer's own
library browsing, multi-room sync with hardware players, editable settings,
plugin icon artwork, HTTP auth on the LMS URLs when a server password is set.
