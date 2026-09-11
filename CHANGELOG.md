# Changelog

All notable changes to **HQPlayer Bridge** are recorded here. This file records
what users receive: one entry per release published to `main`. Per-version
development notes live in `CLAUDE.md`.

## 1.0.0 — 2026-09-11

**First stable release.** No functional change from 0.2.87 — this build marks
the plugin as feature-complete and ready for general use, and is the version
submitted to Lyrion's own plugin repository. See the 0.2.87 entry below, and
the full per-version history in `CLAUDE.md`, for everything that led here.

## 0.2.87 — 2026-09-11

A reliability release for track hand-overs, pre-queuing and control-command
ordering. No new features — every item below fixes a way the bridge could
already lose a beat, most of them narrow timing cases rather than anything
heard on ordinary playback.

### Playback

- **A stop is now told apart from the playlist running out.** HQPlayer's own
  playlist cursor is read on every stopped push, so a track stopped at
  HQPlayer's own front end is followed as a stop — instead of, in a narrow
  case, silently loading the next queued track and carrying on.
- **A held next track is no longer reloaded once it has already played.**
  The same cursor tells a hand-over that never happened apart from one that
  played through and was missed, so a track can no longer be replayed after
  a missed hand-over.
- **Slow and refused pre-queues no longer force an audible full reload.** An
  append still in flight when the current track ends is now given the same
  grace window already used for an acknowledged one, instead of falling
  straight through to a Stop/Clear/Add/Play reload.
- **The current track's reported format no longer flips early.** Resolving
  the next track no longer overwrites the tier shown for the one still
  playing; it is promoted only once the hand-over is confirmed.
- **A skip or playlist edit that arrives mid-load no longer waits behind
  stale work.** Commands superseded by a newer one are now cancelled out of
  the control queue by scope, so the load the user actually asked for is not
  held up by one that no longer matters.

### Artwork

- **Cover art now stays with its own track through a hand-over**, instead of
  flashing off and back on at the boundary.
- **Local artwork is capped at 600×600 before it reaches the endpoint**,
  instead of serving the original file at full resolution — some library
  covers ran to several megabytes at full size.

### Housekeeping

- Removed an unused, superseded framer left over from before the live status
  reader, and a vendor source copy that had been committed twice. No
  behaviour change.

## 0.2.77 — 2026-09-06

**First published release.** Presents each HQPlayer instance on the network as a
native Lyrion player, driven over HQPlayer's own XML control API. It replaces the
`squeeze2upnp` UPnP bridge and adds no audio stage of its own: HQPlayer fetches
the music from Lyrion itself.

### Playback

- **Your library, bit-perfect.** FLAC, WAV, AIFF, DSF/DFF, WavPack, MP3 and Ogg
  are handed over as the original file, including native DSD. ALAC, AAC and M4A —
  which HQPlayer cannot decode — are converted by Lyrion on the way out and
  served on a route of the plugin's own.
- **Streaming at full rate.** Qobuz and Tidal are handed to HQPlayer as the
  service's own URL, so it fetches them directly with no proxy or transcode.
  Deezer and internet radio go through Lyrion.
- **Gapless** on the library and on direct streaming: the next track goes into
  HQPlayer's own playlist before the current one ends, so HQPlayer makes the join.
- **ReplayGain** for library *and* streaming tracks, sent with the track exactly
  as Lyrion calculated it.
- **Artwork** reaches HQPlayer and its display, from the library or a service.

### Control

- **Volume both ways** — the Lyrion slider moves HQPlayer, and HQPlayer's own
  volume moves the slider. One slider step is one dB, and the range is read from
  HQPlayer at connect. Setting the player to fixed volume in Lyrion's own audio
  settings is honoured and never overridden.
- **Pause from either end** — pausing at HQPlayer or on the endpoint's remote
  pauses Lyrion too, within a second. Stop, seek and end-of-track likewise.
- **Found automatically**, with a stable player identity: prefs, playlist and
  sync group survive HQPlayer changing IP address.

### HQPlayer Live View

A page of its own, opened from **Apps → HQPlayer Bridge** or pinned as a Material
home-screen tile. Updates every second and shows what's playing, transport and
volume controls, and the live signal path — source format, output format, filter,
shaper and processing speed. It follows Material's theme and icons, and works on
a phone in either orientation.

### Known limitations

The player shows as present even when HQPlayer is off; a silent output-format
mismatch can only be seen in HQPlayer's own log; a sample-rate change between
tracks is audible; radio track names stop updating after the stream starts; and
HQPlayer's repeat setting is turned off while the bridge is connected. Selecting
HQPlayer's DSP settings, browsing HQPlayer's library, HTTP authentication and
multi-room sync with hardware players are not supported. See the README.
