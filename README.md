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
| **Everything else too** | Streaming services, radio and formats HQPlayer can't read are transcoded by LMS on the fly | The matching service plugin |
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

Two connections are used, because each does something the other can't:

- **HQPlayer's XML control API** carries transport and state. It pushes a status message about once a second, which is what drives the progress bar, the play/pause state and the volume slider.
- **HQPlayer's UPnP renderer** carries the track — its URL, title, artist, album and **cover art**. Over the control API, HQPlayer labels anything arriving over HTTP as *"HTTP stream"* and ignores track details, so artwork would never reach the endpoint's display. Over UPnP it accepts all of it, and re-serves the cover from its own web server, which is where an endpoint's screen looks for it.

### Playing your library

A library track HQPlayer can decode is handed over as **the original file**, byte for byte — FLAC, WAV, AIFF, DSF/DFF, WavPack, MP3 and Ogg, including native DSD. Nothing is re-encoded, and nothing about your files needs to match between the two machines: everything is addressed by URL, never by filesystem path.

HQPlayer has no decoder for **ALAC, AAC or anything else in an MP4/M4A container**, so those don't go over as files — LMS transcodes them instead, the same way it would for any other player. You don't have to do anything; the plugin checks the format and picks the route.

### Streaming services and radio

Qobuz, Tidal, Deezer, internet radio and everything else remote is streamed through LMS, which transcodes as needed (FLAC first, so usually there's no transcoding at all). The service plugin handles its own authentication as usual — the HQPlayer player looks like any other player to it.

Artwork works here too: the cover comes from the service via LMS's image proxy and is passed on to HQPlayer.

### Volume

HQPlayer holds the real volume in dB and decides how to split it between the endpoint's hardware attenuator and its own software gain. LMS has an 0–100 slider. The plugin keeps the two in step in both directions: moving the LMS slider sets HQPlayer's level, and changing the volume anywhere else — HQPlayer's own UI, the endpoint's remote — moves the LMS slider within about a second.

**One LMS step is one dB**, with LMS 100 being 0 dB. That's the same mapping HQPlayer's UPnP endpoint applied to the 0–100 it received, so if you're coming from the UPnP bridge the slider behaves as it did before.

### Pause from either end

Pause and play work from LMS, and also *at* HQPlayer — if you pause on the endpoint's remote or in HQPlayer's own interface, LMS follows within a second rather than carrying on counting time against silent audio. Stop, seek and end-of-track are likewise reported back, so the LMS progress bar tracks what's really happening.

### The status page

**Settings → Advanced → HQPlayer Bridge** is a read-only status page: which instances were discovered and at what address, whether the control link is currently up, and what HQPlayer last reported — state, sample rate, bit depth and output mode.

It reports HQPlayer's **transport id** rather than your endpoint's name. HQPlayer doesn't expose the NAA name over any control command — it only appears in HQPlayer's own log — so the page says so plainly instead of guessing.

---

## Notes & limitations

- **The player shows as present even when HQPlayer isn't reachable.** An HQPlayer instance that's discovered but currently off is a normal state, and tying the LMS player's presence to the control link would have LMS churning prefs and sync groups every time it went away.
- **A silent output-format mismatch is HQPlayer's to report, not the plugin's.** If HQPlayer's output format is set to something your endpoint can't accept, it reports itself as playing and answers every command normally while rendering nothing at all. There's no way to detect that from the control API — the evidence is only in HQPlayer's own log (`NAA output requested format not available!`). If a track looks like it's playing but you hear nothing, check the output format there first.
- **Not gapless.** The next track is handed over when the current one ends, so there's a brief gap between tracks. Pre-queuing isn't implemented.
- **HQPlayer's DSP settings aren't exposed.** Filter, shaper, modulator, output mode and rate are set in HQPlayer, as before — the plugin doesn't change them and can't select them.
- **HQPlayer's own library isn't browsed.** Music comes from LMS; this plugin makes HQPlayer a destination, not a source.
- **Multi-room sync with hardware players is untested.** The player registers as a normal LMS player, so nothing blocks it, but it hasn't been verified and a bridged player can't be sample-accurate with a Squeezebox.
- **No HTTP authentication.** If your LMS server is password-protected, HQPlayer can't fetch the audio URLs it's given.
- **The settings page is read-only** — there's nothing to configure yet.
