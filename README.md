# HQPlayer Bridge — LMS Plugin

A plugin for **Lyrion Music Server** that presents each **HQPlayer** instance on your network as a native LMS player. Play to it, pause, seek, set its volume and see its artwork from Material or any control point, while HQPlayer does the upsampling, filtering and modulation exactly as it always has.

It replaces the `squeeze2upnp` UPnP bridge, with **no external helper and no audio stage of its own**. LMS and HQPlayer are both *pull* engines, so the bridge hands HQPlayer a URL pointing back at LMS and then stays out of the audio path — what crosses it is control messages, over HQPlayer's own XML control API, on one socket. That is why there is no buffer to tune, no transcoder to configure and no helper process to keep alive.

Tested on LMS 9.x against **HQPlayer Embedded 6** feeding an NAA endpoint.

---

## Features

| Feature | What it gives you | Needs |
|---|---|---|
| **Appears as a real player** | Each instance shows up in LMS's player list, ready to select | Nothing |
| **Found automatically** | Discovered on the network; nothing to type in | HQPlayer reachable from the server |
| **No extra audio hop** | HQPlayer fetches the music itself — no buffer, helper or UPnP hop in between | Nothing |
| **Your library, bit-perfect** | FLAC, WAV, AIFF, DSF/DFF, WavPack, MP3 and Ogg go over as the original file, including native DSD | Nothing |
| **Everything else plays too** | ALAC, AAC and M4A are converted by LMS on the way out | Nothing |
| **Streaming at full rate** | Qobuz and Tidal are fetched by HQPlayer straight from the service; Deezer and radio go through LMS | The matching service plugin |
| **Gapless** | Library and direct streaming hand the next track over early, so HQPlayer makes the join itself | Nothing |
| **ReplayGain everywhere** | Library *and* streaming normalised using exactly the figure LMS worked out | Replay gain not set to Off |
| **Artwork on the endpoint** | Cover art reaches HQPlayer and its display, from your library or a service | Nothing |
| **Volume, both ways** | The LMS slider moves HQPlayer, and HQPlayer's own volume moves the slider | Nothing |
| **Pause from either end** | Pausing at HQPlayer or on the endpoint's remote pauses LMS too, within a second | Nothing |
| **Stable player identity** | Prefs, playlist and sync group survive HQPlayer changing IP address | Nothing |
| **Live view** | A page of its own: what's playing, transport, volume and the signal path, updating every second in your Material theme | Nothing |

---

## Requirements

- **Lyrion Music Server 8.0.0+**.
- **HQPlayer** with its control API enabled. Verified against HQPlayer Embedded 6; HQPlayer Desktop has the same API but is untested here.
- **HQPlayer must reach the LMS server over HTTP**, because it fetches the audio itself. Both on the same LAN is the normal case.
- For streaming, the matching service plugin installed and signed in.

Nothing else has to be set up on either side — no shared filesystem, no matching library paths, no audio device in LMS.

---

## Installation

**Via repository (recommended).** In LMS go to **Settings → Plugins → Additional Repositories** and add:

```
https://simonarnold002.github.io/LMS-HQPlayer-Bridge/repo.xml
```

Install **HQPlayer Bridge** from the plugin list and restart. Then open the player menu in Material — the HQPlayer instance is listed by name. Select it and play something.

**Manual.** Download `HQPlayerBridge.zip` from the [repository](https://github.com/SimonArnold002/LMS-HQPlayer-Bridge) and unzip it so it sits as `Plugins/HQPlayerBridge/`:

```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/HQPlayerBridge
sudo unzip HQPlayerBridge.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/HQPlayerBridge
sudo systemctl restart lyrionmusicserver
```

---

## How your music reaches HQPlayer

The plugin picks the route per track. You don't configure any of this.

| What you play | How it gets there | Gapless |
|---|---|---|
| Library file HQPlayer can decode | The original file, byte for byte — nothing re-encoded | Yes, pre-queued |
| Library ALAC / AAC / M4A | LMS converts to FLAC and the plugin serves it on a route of its own | Yes, pre-queued |
| **Qobuz, Tidal** | The service's own URL, handed straight over — LMS stays out of the audio path | Yes, pre-queued |
| **Deezer, internet radio** | Through LMS on a plain path of its own, FLAC first so usually no transcoding | Next track loads at the end |

Everything is addressed by URL, so nothing about your files needs to match between the two machines.

Where a track is pre-queued, HQPlayer has the next one in its own playlist before the current ends and makes the join itself. On the last route the next track loads when the current one finishes — about half a second, against roughly a second and a half of audio already in flight, so nothing is heard.

**ReplayGain** is sent with the track, exactly as LMS calculated it — nothing scaled or trimmed, and a *boost* goes through in full. This covers streaming, where there are no tags, and beats letting HQPlayer read library tags itself, which it does at the moment playback starts and so misses the first tracks of a fresh album. LMS's choice between album and track gain is the one you get. A track LMS has no figure for is left completely alone. If you have HQPlayer's **convolution gain compensation** set, that applies on top — deliberately not cancelled out.

---

## Volume

HQPlayer holds the real level in dB and decides how to split it between the endpoint's hardware attenuator and its own software gain; LMS has an 0–100 slider. The two are kept in step both ways, within about a second.

**One LMS step is one dB, with LMS 100 being 0 dB.** The range is read from HQPlayer at connect, so a ceiling below 0 dB is handled.

The level you start with is **HQPlayer's own**, not one the plugin asserts. To stop Lyrion driving the volume at all, set **Volume Control: fixed** on the player's Audio settings page; the plugin honours that and never changes it for you. HQPlayer's own "fixed volume" is a *startup level*, not a lock.

---

## Seeing what it's doing

**HQPlayer Live View** — open it from **Apps → HQPlayer Bridge**, or pin it for a Material home-screen tile. It updates every second and shows what's playing, transport and volume controls, and the live signal path:

```
Control link       Connected - 192.168.1.109:4321
Source             44100 Hz / 16 bit FLAC
Output format      96000 Hz / 24 bit PCM
Filter             poly-sinc-gauss-long
Shaper             TPDF
Processing speed   30.3x realtime
```

HQPlayer reports the filter *really* in use, so a 44.1 kHz album shows your 1x filter and a 96 kHz one your Nx filter. The page follows Material's theme and icons and works on a phone in either orientation. Until HQPlayer is found it says it is waiting for the player to connect. It costs HQPlayer nothing — the values are already in memory from the status stream the plugin subscribes to.

**The Apps entry** behind it is a browse list, which Material draws once and never refreshes, so it shows HQPlayer's **settings** — output mode, filter, shaper, transport id — rather than moving numbers that would go stale. It reports the transport **id**, not your endpoint's name: HQPlayer doesn't expose the NAA name over any control command.

---

## Known limitations

- **The player shows as present even when HQPlayer isn't reachable.** A discovered instance that is currently off is a normal state; tying the player's presence to the control link would churn prefs and sync groups every time it went away.
- **A silent output-format mismatch is HQPlayer's to report.** If its output format is something your endpoint can't accept, it reports itself as playing and answers every command while rendering nothing. That can't be detected over the control API — the evidence is in HQPlayer's own log (`NAA output requested format not available!`). If a track looks like it's playing but you hear nothing, check the output format there first.
- **A sample-rate change between tracks is audible**, on every route. HQPlayer needs a couple of seconds to retune its output.
- **Radio track names are right when the stream starts, then stop updating.** HQPlayer's control API can't change the metadata on an item already playing, and re-sending it would restart the stream. LMS itself keeps up to date as usual.
- **HQPlayer's repeat setting is turned off** whenever the control link comes up. LMS owns the queue and needs to see HQPlayer's playlist end; with repeat on it never does. Set repeat and shuffle in LMS.

---

## Not supported

- **Selecting HQPlayer's DSP settings.** Filter, shaper, modulator, output mode and rate are set in HQPlayer, as before. The plugin reports them but cannot change them.
- **Browsing HQPlayer's own library.** Music comes from LMS; this makes HQPlayer a destination, not a source.
- **HTTP authentication.** If your LMS server is password-protected, HQPlayer can't fetch the audio URLs it's given.
- **Multi-room sync with hardware players.** Nothing blocks it, but it is unverified, and a bridged player can't be sample-accurate with a Squeezebox.
- **A settings page.** There is nothing to configure: instances find themselves, and everything shown is read from HQPlayer.

---

## Licence and attribution

This plugin is released under the **MIT licence** — see [LICENSE](LICENSE).

**It is not affiliated with, endorsed by, or supported by Signalyst.** For
anything to do with HQPlayer itself, go to Signalyst, not here; and please don't
take a problem caused by this plugin to them.

**HQPlayer** and **Signalyst** are trademarks of their respective owner. They are
used here only to identify the software this plugin works with.

The control protocol was implemented with reference to **Signalyst's own
`hqp-control` source**, © 2011–2026 Jussi Laako, which Signalyst publish under
the MIT licence. A copy is included in this repository at
`hqp-control-601-src/` together with its licence (`COPYING`); it is reference
material only and none of it is compiled into or shipped with the plugin. The
HQPlayer Control API is offered by Signalyst for exactly this purpose —
"implementing a custom GUI or other type of front-end utilizing the HQPlayer
playback engine".
