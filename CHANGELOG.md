# Changelog

All notable changes to **HQPlayer Bridge** are recorded here. This file records
what users receive: one entry per release published to `main`. Per-version
development notes live in `CLAUDE.md`.

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
