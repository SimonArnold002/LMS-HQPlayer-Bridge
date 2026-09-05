# HQPlayer Bridge — LMS Plugin

A plugin for **Lyrion Music Server (LMS)** that presents each **HQPlayer** instance on your network as a native LMS player. Play to it, pause it, seek it, set its volume and see its artwork from Material or any LMS control point — while HQPlayer does the upsampling, filtering and modulation exactly as it always has. It replaces the `squeeze2upnp` UPnP bridge: **no external helper, and no audio through the plugin.**

Tested on LMS 9.x against **HQPlayer Embedded 6** feeding a network audio adaptor (NAA) endpoint.

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **Appears as a real player** | Each HQPlayer instance shows up in LMS's player list, ready to select | Nothing |
| **Found automatically** | Instances are discovered on the network; nothing to type in | HQPlayer reachable from the server |
| **No audio through the plugin** | HQPlayer fetches the music from LMS itself — the bridge only moves control messages | Nothing |
| **Your library, bit-perfect** | FLAC, WAV, AIFF, DSF/DFF, WavPack, MP3 and Ogg are handed over as the original file | Nothing |
| **Streaming, straight from the source** | Qobuz and Tidal tracks are fetched by HQPlayer directly from the service, at full rate and gapless | The matching service plugin |
| **Everything else too** | Deezer, radio and formats HQPlayer can't read are served through LMS on the fly | The matching service plugin |
| **ReplayGain everywhere** | Library *and* streaming tracks are normalised in HQPlayer using exactly the figure LMS worked out | Replay gain set to anything but Off in LMS |
| **Artwork on the endpoint** | Cover art reaches HQPlayer and its display, for library *and* streaming tracks | Nothing |
| **Volume, both ways** | The LMS slider moves HQPlayer, and HQPlayer's own volume moves the slider | Nothing |
| **Pause from either end** | Pausing at HQPlayer, or on the endpoint's remote, pauses LMS too | Nothing |
| **Stable player identity** | Prefs, playlist and sync group survive HQPlayer changing IP address | Nothing |
| **Status page** | What was discovered, whether the control link is up, and what HQPlayer is doing | Nothing |

---

## Requirements

- **Lyrion Music Server 8.0.0+**.
- **HQPlayer** with its control API enabled, reachable from the LMS server. Verified against HQPlayer Embedded 6; the same control API is present in HQPlayer Desktop but hasn't been tested here.
- **HQPlayer must be able to reach the LMS server over HTTP**, because it fetches the audio itself. Both on the same LAN is the normal case.
- For streaming, the matching service plugin installed and signed in (**Qobuz**, **Tidal**, **Deezer**, and so on). Library playback needs nothing extra.

Nothing has to be configured on either side beyond that — no shared filesystem, no matching library paths, no audio device setup in LMS.

---

## Installation

**Via repository (recommended).** In LMS go to **Settings → Plugins → Additional Repositories** and add:

```
https://simonarnold002.github.io/LMS-HQPlayer-Bridge/repo.xml
```

Then install **HQPlayer Bridge** from the plugin list and restart.

**Manual.** Download `HQPlayerBridge.zip` from the [repository](https://github.com/SimonArnold002/LMS-HQPlayer-Bridge), unzip it into your LMS `Plugins/` directory so it sits as `Plugins/HQPlayerBridge/`, and restart:

```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/HQPlayerBridge
sudo unzip HQPlayerBridge.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/HQPlayerBridge
sudo systemctl restart lyrionmusicserver
```

---

## Quick start

1. Start HQPlayer and make sure its output is going somewhere that works — the same setup you'd use to play from HQPlayer's own interface.
2. Install the plugin and restart LMS.
3. Open the player menu in Material (or any control point). The HQPlayer instance is listed by name. Select it.
4. Play an album. HQPlayer fetches it from LMS and renders it through your usual pipeline.

---

## Using it

### What actually moves where

LMS and HQPlayer are both *pull* engines: each is used to being handed a URL and fetching the bytes itself. So the bridge hands HQPlayer a URL pointing back at LMS's own HTTP server and then stays out of the audio path entirely. What crosses the bridge is control messages — play, pause, seek, volume, and a status stream coming back the other way.

That's the whole reason there's no buffer to tune, no transcoder to configure and no helper process to keep alive.

Everything goes over **HQPlayer's own XML control API**: the track and its URL, the title, artist and album, the **cover art**, transport, volume, and a status stream coming back about once a second that drives the progress bar, the play/pause state and the volume slider.

That is the whole conversation — **one socket, nothing else**. Even the **volume range**, which the plugin reads once at connect because the top and bottom are both settings the user can move, comes back on the same channel.

### Playing your library

A library track HQPlayer can decode is handed over as **the original file**, byte for byte — FLAC, WAV, AIFF, DSF/DFF, WavPack, MP3 and Ogg, including native DSD. Nothing is re-encoded, and nothing about your files needs to match between the two machines: everything is addressed by URL, never by filesystem path.

HQPlayer has no decoder for **ALAC, AAC or anything else in an MP4/M4A container**, so those don't go over as files — LMS converts them to FLAC and the plugin serves them itself, on a route of its own. You don't have to do anything; the plugin checks the format and picks the route, and converted tracks stay gapless like any other library track.

### Streaming services and radio

The service plugin handles its own authentication as usual — the HQPlayer player looks like any other player to it. There are two routes, and the plugin picks between them for you.

**Qobuz and Tidal are handed over directly.** LMS resolves the track and gives HQPlayer the service's own URL, so HQPlayer fetches the audio straight from the service and LMS stays out of the audio path entirely — exactly as it does for a library file. Nothing is re-encoded, a 24/96 Qobuz track arrives at full rate, and because there is a real URL to hand over, the next track can be queued up early: **streaming is gapless the same way your library is.**

**Deezer and internet radio go through LMS instead**, which serves the audio on a plain path of its own (FLAC first, so usually there's no transcoding at all). Deezer's LMS plugin doesn't offer a URL that can be handed over, and radio streams need LMS to read the stream's own headers. That is not a detail you have to care about, with one consequence you might notice: see the note on gapless below.

Artwork works here too: the cover comes from the service via LMS's image proxy and is passed on to HQPlayer.

### Volume

HQPlayer holds the real volume in dB and decides how to split it between the endpoint's hardware attenuator and its own software gain. LMS has an 0–100 slider. The plugin keeps the two in step in both directions: moving the LMS slider sets HQPlayer's level, and changing the volume anywhere else — HQPlayer's own UI, the endpoint's remote — moves the LMS slider within about a second.

**One LMS step is one dB**, with LMS 100 being 0 dB. The range is read from HQPlayer at connect, so a ceiling below 0 dB (say −60 to −20) is handled.

The volume you start with is **HQPlayer's**, not one the plugin asserts — its own software level, or the device volume on an NAA like an Eversolo. If you want Lyrion to stop driving the volume altogether, set **Volume Control: fixed** on the player's own Audio settings page; the plugin honours that and never changes it for you. (HQPlayer's own "fixed volume" setting is a *startup level*, not a lock — it sets the output once and the volume stays adjustable.)

### Pause from either end

Pause and play work from LMS, and also *at* HQPlayer — if you pause on the endpoint's remote or in HQPlayer's own interface, LMS follows within a second rather than carrying on counting time against silent audio. Stop, seek and end-of-track are likewise reported back, so the LMS progress bar tracks what's really happening.

### The status page

**Settings → Advanced → HQPlayer Bridge** is a read-only status page: which instances were discovered and at what address, whether the control link is currently up, and what HQPlayer last reported — state, sample rate, bit depth and output mode.

It reports HQPlayer's **transport id** rather than your endpoint's name. HQPlayer doesn't expose the NAA name over any control command — it only appears in HQPlayer's own log — so the page says so plainly instead of guessing.

---

## Notes & limitations

- **The player shows as present even when HQPlayer isn't reachable.** An HQPlayer instance that's discovered but currently off is a normal state, and tying the LMS player's presence to the control link would have LMS churning prefs and sync groups every time it went away.
- **A silent output-format mismatch is HQPlayer's to report, not the plugin's.** If HQPlayer's output format is set to something your endpoint can't accept, it reports itself as playing and answers every command normally while rendering nothing at all. There's no way to detect that from the control API — the evidence is only in HQPlayer's own log (`NAA output requested format not available!`). If a track looks like it's playing but you hear nothing, check the output format there first.
- **Gapless works on streaming too — properly on Qobuz and Tidal.** Those are handed over as the service's own URL, so the next track goes into HQPlayer's playlist while the current one is still playing and HQPlayer makes the transition itself, with no gap at all. **Deezer, radio and converted files work differently**, because that audio passes through LMS and a player has only one such stream at a time: the next track is loaded when the current one ends. That load takes about half a second and HQPlayer still has around a second and a half of audio in flight to your endpoint, so nothing is heard. A **sample rate change** between tracks is the exception there: HQPlayer has to retune its output, which takes a couple of seconds and is audible. Within an album that's rarely an issue.
- **Gapless on your local library.** The next track is handed to HQPlayer's own playlist while the current one is still playing, so HQPlayer makes the transition itself with no gap at all. A **sample rate change** between tracks is the one exception — HQPlayer needs a couple of seconds to retune its output, and no bridge can avoid that.
- **Every local format plays, including ones HQPlayer can't decode.** HQPlayer has no decoder for ALAC, AAC or m4a, so LMS converts those to FLAC on the way out and the plugin serves them itself. They play, seek and stay gapless like any other library track. Formats HQPlayer decodes natively (FLAC, WAV, AIFF, DSD, WavPack, MP3, Ogg) are passed through untouched, byte for byte, and stay gapless.
- **ReplayGain reaches HQPlayer for everything you play.** Set **Replay Gain** to anything other than Off in LMS's player settings and the plugin sends HQPlayer the figure LMS worked out, with the track. That covers streaming, where the file has no tags of its own, and your library, where it's better than leaving HQPlayer to read the tags: HQPlayer applies them at the moment playback starts, which on a fresh album is before it has finished fetching the file, so the first tracks would play unnormalised. It also means LMS's choice between album and track gain is the one you get — HQPlayer only does album gain. What you get from a streaming service depends on the service: Qobuz publishes both album and track figures, so LMS can pick between them, while a service that publishes only track gain gives you per-track normalisation.
- **The figure is sent exactly as LMS calculated it.** Nothing is added, scaled or trimmed on the way through, and the plugin reads nothing back from HQPlayer to adjust it. If a track calls for a *boost* — quietly mastered albums often do — the boost goes through in full. **A track LMS has no ReplayGain figure for is left completely alone**: nothing is sent, and HQPlayer reads a library file's own tags exactly as it would without the plugin. That is also what happens for every track if you have replay gain switched **off** in LMS. One thing worth knowing: if you have HQPlayer's **convolution gain compensation** set, HQPlayer applies that on top of whatever the plugin sends, so normalised tracks sit that much lower. That is HQPlayer doing what you configured it to do — the plugin deliberately does not cancel it out, so if it is not what you want, change it in HQPlayer.
- **Radio track names are right when the stream starts, then stop updating.** The track playing when you tune in is sent to HQPlayer correctly, but a station moving on to the next song can't be reflected: HQPlayer's control API has no way to change the metadata on an item that's already playing, and re-sending it would restart the stream. LMS itself keeps up to date as usual.
- **HQPlayer's repeat setting is turned off while the bridge is connected.** LMS owns the queue, and the plugin needs to see HQPlayer's playlist actually end in order to stop. With repeat on it never ends, so the queue never advances — the plugin asserts repeat off whenever the control link comes up. Set repeat and shuffle in LMS, as you would for any other player.
- **HQPlayer's DSP settings aren't exposed.** Filter, shaper, modulator, output mode and rate are set in HQPlayer, as before — the plugin doesn't change them and can't select them.
- **HQPlayer's own library isn't browsed.** Music comes from LMS; this plugin makes HQPlayer a destination, not a source.
- **Multi-room sync with hardware players is untested.** The player registers as a normal LMS player, so nothing blocks it, but it hasn't been verified and a bridged player can't be sample-accurate with a Squeezebox.
- **No HTTP authentication.** If your LMS server is password-protected, HQPlayer can't fetch the audio URLs it's given.
- **The settings page is read-only** — there's nothing to configure yet.

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

The plugin icon is original artwork drawn for this plugin. It is not Signalyst's
application icon and does not reproduce any part of it.
