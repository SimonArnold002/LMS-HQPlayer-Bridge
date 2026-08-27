# LMS-HQPlayer-Bridge

## Review Ledger

Verdicts already reached on review findings. **Read this before reporting one** —
a finding listed here has been considered and settled, and raising it again
costs a review round. Record every declined verdict in the same session it is
declined.

| Finding | Verdict | Why |
|---|---|---|
| The volume echo guard assumes `_lmsToDb(_dbToLms($db)) == $db`, which the clamp breaks below −100 dB, so an endpoint muted at −120 dB is written back up to −100 dB (`Player.pm`, `volume` / `_onStatus`) | **SUPERSEDED** 2026-08-27 | Was declined on the grounds that the mapping was 1:1 and the clamp intended. The round trip is no longer assumed at all: both directions now compare **in dB with a half-step tolerance** (`_volTol`), which is what the range work needed anyway. |
| `<Volume>` answers `result="Error"` — the command is wrong or unsupported | **DECLINED** 2026-08-27 | The level is applied regardless. With an **empty playlist** every `<Volume>` returns `result="Error"` carrying `clPlaylist::GetAlbumGain(): trackn > last`, which is HQPlayer recomputing replaygain over a playlist with no tracks. Verified against the live daemon: `GetVolumeDB` confirms the new level to 1/256 dB. `Control.pm`'s `%BENIGN` logs it at debug. |
| The volume curve should be tapered (a knee, or `denonavpcontrol`'s sqrt) rather than linear | **DECLINED** 2026-08-27 | Linear in dB **is** a logarithmic taper on the signal — equal dB per step. A bend would make a fixed skin increment (Material's volume step is 1, 3 or 5) worth a different number of dB depending on slider position, and it only pays off for a listener with one habitual level. It would also break agreement with HQPlayer's own 0-100 scale, which is linear over the range (`GetVolume` 61 at −39 dB on −100…0). |

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

Two things that reply `Unknown command` here **do** work as UPnP
RenderingControl actions, and both matter: `GetVolumeDBRange` (the configured
range, in 1/256 dB) and `GetVolumeDB` (the current level at the same
precision). See "The range is the user's, not HQPlayer's".

The value may be **fractional** — `<Volume value="-39.25"/>` is accepted and
reported back verbatim — and with an **empty playlist** every `<Volume>`
answers `result="Error"` with an album-gain message while applying the level
anyway. Both verified live; see the review ledger.

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

`hqVolDb` is where HQPlayer **actually is** — the last level it reported, not the
last one we sent — and it is what stops the two directions chasing each other:
neither side moves the other over a difference smaller than one LMS step is
worth. The inbound direction goes through `execute(['mixer','volume',…])`
rather than the accessor, so Material and anything else watching the slider is
notified.

The mapping is linear in dB across HQPlayer's **configured** range, which is
read from the renderer rather than assumed. On this −100…0 instance that works
out as `dB = LMS − 100`, one LMS step per dB, so the slider feels unchanged —
but nothing depends on that. The four sections below cover the range, the
resolution, the snap, and fixed volume; they are the whole design.

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

### The range is the user's, not HQPlayer's

`HQP_VOL_MIN_DB => -100` was never a property of HQPlayer. Its output range is
a **setting**: it defaults to −60…0, this development instance is −100…0, and
**both ends move** — a user may cap the top at −20 as much as lift the floor.
A hardcoded −100 on a default instance fails twice: the bottom 40% of the
slider is dead, and worse, HQPlayer reports the *clamped* level back, the
mirror reads it as an external change, and the slider visibly snaps.

So the range is read, not assumed:

```
dB  = max - (max - min) x (100 - lms) / 100
lms = 100 x (dB - min) / (max - min)
```

At −100…0 that is arithmetically `dB = lms - 100`, so this instance's feel is
unchanged. `min`/`max` are per-player accessors (`hqVolMin`, `hqVolMax`), which
is why `_lmsToDb` and `_dbToLms` are methods.

**Where they come from.** VERIFIED live 2026-08-27 against hqplayerd 6.0.4:

```
curl -s -X POST http://<hqplayer-ip>:8019/control/rendering-control \
  -H 'Content-Type: text/xml; charset="utf-8"' \
  -H 'SOAPACTION: "urn:schemas-upnp-org:service:RenderingControl:3#GetVolumeDBRange"' \
  --data '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetVolumeDBRange xmlns:u="urn:schemas-upnp-org:service:RenderingControl:3"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetVolumeDBRange></s:Body></s:Envelope>'

-> <MinValue>-25600</MinValue><MaxValue>0</MaxValue>
```

**HQPlayer does implement `GetVolumeDBRange`**, even though the XML control API
answers `Unknown command` for the name — it is a UPnP RenderingControl action.
The units are the AV spec's **1/256 dB** (−25600 = −100.0 dB). Some renderers
report whole dB and nobody has a range past ±200 dB, so `abs(v) > 200` is a
safe discriminator. One SOAP call per connect, off the hot path, so its
300–550 ms costs nothing. `UPnP::getVolumeDBRange`, called from
`Player::refreshVolumeRange` on every link-up.

The **clamp** is the fallback, and the only route that survives the user
reconfiguring HQPlayer without a reconnect: ask for a level beyond the limit
and HQPlayer answers with the limit itself. Verified — `<Volume value="-120"/>`
on this instance reports back `volume="-100"`. `_learnFromClamp` is
deliberately conservative and only reads a reply as a clamp when we asked for
the limit we already believe in, or beyond it; anything looser would let a knob
turn on the endpoint that landed inside the window collapse the range.

Whatever is learned is shown on the status page — it is the one number that
explains the whole feel of the slider.

### Fractional dB, and why there are no dead steps

**HQPlayer takes and reports fractional dB.** Verified: `<Volume
value="-39.25"/>` comes back from `<Status/>` as `volume="-39.25"` and from
UPnP `GetVolumeDB` as `-10048` (= −39.25 × 256) exactly. So the device is not
the limit on resolution — every one of LMS's 101 slider positions can have a
level of its own, on any range, however narrow. A range with only 41 whole-dB
values does not force steps to share a level.

**But it round-trips through a 32-bit float**: `-38.6` comes back as
`-38.599998474121094`. So `_quantise` snaps every level to a binary fraction of
a dB, which survives both that and HQPlayer's 1/256 dB units exactly. The
quantum is at most **half an LMS step**, which is what guarantees two
consecutive slider positions can never land on the same level.

### The snap, and the tolerance that fixes it

The reported symptom — "LMS changes the volume on the next track to align it",
seen with SqueezeConnect as well — has a definite cause in LMS itself. At the
start of every track that begins from stopped:

```perl
# Slim/Player/StreamingController.pm, "Bug 10310"
my $vol = ... $prefs->client($player)->get("volume") ...;
$player->volume($vol);
```

LMS re-asserts its **stored** volume. So the invariant is: whatever LMS has
stored must map back to HQPlayer's real level, or the next track yanks the
device onto LMS's idea of it. A level set on the endpoint's own knob — the
Eversolo's increments are not LMS's — will not land on the 101-step grid, LMS
rounds it to the nearest step, and without a tolerance that rounding is written
back as a real change on the next track.

Hence `_volTol`, **half an LMS step in dB**, used by *both* directions:

| | rule |
|---|---|
| outbound (`volume`) | send only if the new level differs from where HQPlayer **actually is** by more than `_volTol`. The track-start re-assert then costs nothing. |
| inbound (`_followVolume`) | follow only if the reported level differs from what the **slider itself means** by more than `_volTol` — not from the last value we sent. |

Both must use the same tolerance, or they fight: whatever one side declines to
follow, the other must decline to correct. Anything within half a step is the
same slider position as far as LMS can express it, so the endpoint's own
setting is left exactly where the user put it.

`_followVolume` reads the **persisted** volume rather than `$client->volume`:
`_Resume` parks a temporary 0 before its fade-in, and a status push landing in
that window would otherwise read as "the endpoint just dropped to the floor".
A muted player stores its level negated, and mutes to the floor.

### Linear in dB, deliberately

Equal dB per step **is** a logarithmic taper on the signal — that is what a good
analogue pot approximates. It is also HQPlayer's own convention: its UPnP
`GetVolume` reported `61` at −39 dB on this −100…0 instance, i.e.
`100 x (1 - 39/100)`, so matching it means the LMS slider and HQPlayer's own
0-100 scale read the same number and cannot disagree.

A bent taper — a knee, or the `sqrt` curve `denonavpcontrol` uses — was
considered and rejected. Skins do not agree on the increment (Material's volume
step is configurable 1/3/5, others differ), so a bend makes one press worth a
different number of dB depending on where the slider happens to be; and it only
pays off for a listener with a single habitual level, which is not the case
here. See the review ledger.

### Fixed volume

Many HQPlayer setups do not attenuate at all — the DAC or the amplifier holds
the level — and for those the LMS slider must sit at the top and stay there.

LMS already has the concept, and it is worth using rather than inventing. The
status query emits

```perl
# Slim/Control/Queries.pm
my $useVolumeControl = ($digitalVolumeControl || !$hasDigitalOut) ? 1 : 0;
$request->addResult('use_volume_control', $useVolumeControl);
```

and the skins disable the slider on `use_volume_control: 0`. LMS only allows
`digitalVolumeControl` to go to 0 on a player whose `hasDigitalOut` is true —
which this one is — and the same gate puts LMS's own **Volume Control:
fixed / variable** radio on the player's Audio settings page, so the user gets a
manual override for free.

So `_setFixed(1)` writes the pref to 0, parks the slider at 100, and stops
`volume()` sending. A manual 0 counts as fixed too and is **never** written back
to 1 — only a 0 the plugin set is the plugin's to clear.

Detection, in order: a zero-width range from `GetVolumeDBRange`; failing that,
`_watchForFixed` — three sends that ask for a genuinely different level and
change nothing, one strike per send, cleared the moment any level change is
seen so the state can never stick. **Unverified:** how HQPlayer actually
presents fixed mode, which needs the setting flipped on a live instance. The
passive rule does not depend on knowing.


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
* **The volume range, resolution and clamp** — 2026-08-27, probed directly from
  the Mac (the instance answers discovery on the LAN, so no shell on the box is
  needed): `GetVolumeDBRange` → −25600/0 (1/256 dB); `<Volume value="-39.25"/>`
  → `<Status/>` reports `-39.25` and `GetVolumeDB` reports −10048;
  `<Volume value="-120"/>` clamps and reports back `-100`; `GetVolume` reports
  61 at −39 dB, i.e. HQPlayer's own 0-100 scale is linear over the range. The
  level was restored to −39 dB afterwards.
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

* **How HQPlayer presents fixed volume.** Needs the setting flipped on a live
  instance, then a `<Status/>` and a `GetVolumeDBRange`. Detection currently
  assumes a zero-width range, and falls back to `_watchForFixed` (three sends
  that change nothing), which does not depend on knowing.
* The volume work as a whole is verified at the protocol level and unit-tested,
  but has not yet run on the live LMS — the bridge was not loaded there when
  0.2.9 was built.
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
