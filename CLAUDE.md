# LMS-HQPlayer-Bridge

## Review Ledger

Verdicts already reached on review findings. **Read this before reporting one** —
a finding listed here has been considered and settled, and raising it again
costs a review round. Record every declined verdict in the same session it is
declined.

### DECLINED / SETTLED INDEX — GREP THIS FIRST

**One grep before reporting any finding.** Find the symbol or subject in this table, then grep
the phrase in the last column to jump to the full row below. A hit means it is already decided:
read the row and either drop the finding, or answer its stated reason with new evidence. Do not
re-report it as new. Phrases are used instead of line numbers because line numbers rot.

The fleet-wide non-findings (uncommitted tree, unpushed commits, stale zip or `repo.xml <sha>`,
CHANGELOG/README behind `install.xml`) are NOT repeated here — they live in Gate 1 of
`~/Documents/GitHub/CLAUDE.md`, which auto-loads. Run those gates first.

| symbol / subject | verdict | find it with |
|---|---|---|
| `volume`, `_onStatus`, echo guard, `_lmsToDb` round trip | SUPERSEDED — now compares in dB via `_volTol` | `_lmsToDb(_dbToLms($db)) == $db` |
| `_followVolume`, endpoint re-register jumping the level | REVERSED — we follow it anyway | `An endpoint re-registering can jump the output` |
| volume curve, taper, knee, sqrt | DECLINED — linear in dB, deliberately | `The volume curve should be tapered` |
| `<Volume>` returning `result="Error"` | DECLINED | `` `<Volume>` answers `result="Error"` `` |
| `<VolumeRange/>` `enabled`, fixed-volume detection | WRONG, MEASURED — there is no fixed-volume state | `` `enabled` on `<VolumeRange/>` is the fixed-volume flag `` |
| `digitalVolumeControl`, `_setFixed`, `_watchForFixed` | REVERSED, Simon's call — the plugin never writes it | `should detect a non-attenuating HQPlayer` |
| `_replayGain` scaling, convolution gain, peak cap, unity | REVERSED, Simon's call — the figure goes out VERBATIM | `The bridge should scale LMS's ReplayGain figure at all` |
| `_replayGain` headroom trim against `_volMax` | WRONG — reversed in 0.2.44 | `A boost must be trimmed against the room` |
| `_replayGain` adding headroom back to every figure | WRONG for the NO-FIGURE case — fixed 0.2.47 | `The headroom should be added back to every figure` |
| `_convGainFromFile`, `Volume scaler` vs convolution gain | WRONG — fixed 0.2.48 | `` `Volume scaler` is the headroom `` |
| `album_gain` on local tiers, double-applied tags | WRONG — it OVERRIDES the file's tags; fixed 0.2.44 | `Local tiers must not send `album_gain`` |
| `album_gain` on `PlaylistAdd`, streaming ReplayGain route | WRONG — the control-API route exists | `hqplayerd ignores a gain figure on `PlaylistAdd`` |
| tier 3, chunked transcode, "verified working" by API numbers | WRONG — judge playback by hqplayerd's log, never the control API | `Tier 3 (transcoded local files) is verified working` |
| tier 3 moved onto the tier 4 endpoint | WRONG | `Tier 3 must go on the tier 4 player-stream endpoint` |
| query strings in a URL, path-only rule | WRONG — DISPROVEN, `?` URLs are fetched | `HQPlayer cannot fetch a URL containing a `?`` |
| `_downloadHandler`, raw function status code | WRONG — it must set its OWN code; fixed 0.2.45 | `A raw function's response needs no explicit status code` |
| `<Status/>` subscribe attribute, `_startPolling`, `_statusWatchdog` | DECLINED | `A bare `<Status/>` is not a subscribe` |
| stranded `mode=play`, frozen clock, Eversolo screen | ACCEPTED — FIXED in 0.2.50 | `stranded in `mode=play` with a frozen clock` |
| hand-over gated on the uri | WRONG for tier 5 — fixed same day | `The hand-over is safe to gate on the uri` |
| `track` needing only an INCREASE, `track="0"` | WRONG — fixed 0.2.37 | `` `track` only ever needs an INCREASE `` |
| `tracks_total` / `track_serial` as a boundary signal | WRONG — proposed here, disproven here, DO NOT RE-PROPOSE | `` `tracks_total`, or `track_serial`, can tell a track boundary `` |
| `_appendTrack` / `_endOfStream`, refused pre-queue | WRONG inside the grace window — fixed | `A refused pre-queue is safely demoted to a held load` |
| `_onStatus` / `_endOfStream`, stop with a hand-over pending | WRONG — observed live, fixed 0.2.81 | `A stop with a hand-over pending is resolved by waiting `END_GRACE`` |
| `_artMatch` / `_metadata`, album id comparison | WRONG across services — fixed same day | `Two albums are told apart by the album id` |
| `playerStreamingFailed`, `PROBLEM_OPENING` on a failed load | ACCEPTED — BUILT in 0.2.60 | `A failed load should always be handed to LMS as `PROBLEM_OPENING`` |
| HQPlayer's playlist showing the whole LMS queue | DECLINED, Simon's call: "stick with it as is" | `HQPlayer's playlist should show the whole LMS queue` |
| `UPnP.pm`, `refreshVolumeRange`, keeping UPnP for the range | REMOVED in 0.2.54 | `UPnP must stay for the volume range` |
| `_onStatus` `HQP_STOPPED` branch ORDER, held tier 4 track vs abandoned stop | WRONG — fixed 0.2.82, **CONFIRMED LIVE** | `The abandoned-stop test can sit anywhere` |
| `_endOfStream` `mode eq 'queue'`, "the held track has NEVER PLAYED", missed advance | INCOMPLETE — fixed 0.2.82, CLOSED as unprovable in the wild; the guard SELF-REPORTS | `A pending hand-over proves the held track has NEVER PLAYED` |
| `_teardown` leaving `_startDeadline` / `_tripStop` / `_endOfStream` / `_fadeDone` armed on a forgotten client | NOT A DEFECT — already guarded via `controller->stop` | `Timer balance` |
| `_completeResponse` vs `_extractMessage`, two framers in `Control.pm` | REMOVED in 0.2.83 — it was dead, kept alive only by its own test | `was dead, and only its own test kept it alive` |
| `nowPlayingFor` still building an UNBOUNDED `/music/<id>/cover.jpg` for the live page | DELIBERATE 0.2.84 — its consumer is a browser, not the endpoint | `THE SECOND CARRIER, LEFT ALONE ON PURPOSE` |
| a remote track's cover not being size-capped like the local one | DELIBERATE 0.2.84 — scoped out, service URLs differ per service | `THE REMOTE ROUTE IS DELIBERATELY UNTOUCHED` |

**Two standing rules that kill most repeat findings:**

1. **Name the WRITER, not just the branch.** A hand-built input proves the branch, never the
   population. If nothing upstream can reach a guarded branch, say so in the finding instead
   of reporting it as live.
2. **A comment is not the contract.** Where a comment claims an invariant the code does not
   enforce, the comment is the defect. Fix the prose and pin the behaviour in a suite.

### HOW TO LOG A VERDICT so the next round finds it

Every new decision gets a row in the table below AND a row in the index above, in the SAME
edit. The index row's first column names the **symbols** a future review would grep for; the
"find it with" column carries a phrase that exists verbatim in the full row. State the reason
as a fact that can be DISPROVEN ("HQPlayer answers X"), never as "unlikely" — a rarity claim
invites the next round to find one counter-example and reopen the entry.

Note this repo's ledger is mostly **WRONG** verdicts: beliefs the bridge was built on and
later disproved live. Those rows are as load-bearing as the declined ones, because the wrong
belief is the thing a fresh review will re-derive from the code and propose again.

### THE FULL ROWS

| Finding | Verdict | Why |
|---|---|---|
| The volume echo guard assumes `_lmsToDb(_dbToLms($db)) == $db`, which the clamp breaks below −100 dB, so an endpoint muted at −120 dB is written back up to −100 dB (`Player.pm`, `volume` / `_onStatus`) | **SUPERSEDED** 2026-08-27 | Was declined on the grounds that the mapping was 1:1 and the clamp intended. The round trip is no longer assumed at all: both directions now compare **in dB with a half-step tolerance** (`_volTol`), which is what the range work needed anyway. |
| Tier 3 (transcoded local files) is verified working - `state=2`, `process_speed` 3.298, `input_fill` 0.73, position advancing | **WRONG** 2026-08-28, corrected same day | The audio was GARBLED for every build tier 3 shipped in. HQPlayer's decoder was throwing `ReadFLACErrorCB(): lost sync` / `CRC error` on every frame because LMS serves a transcode `Transfer-Encoding: chunked` and HQPlayer does not de-chunk. **None of the numbers above can see that** - the DSP runs at full speed on whatever it decodes. Nor does downloading the file prove anything: curl de-chunks silently, so the copy is a perfect FLAC (0.9998 envelope correlation vs the original m4a). Judge playback by hqplayerd's log at `:8088/log`, never by the control API. See [[hqplayer-verify-playback-not-state]]. |
| A bare `<Status/>` is not a subscribe - the vendor's client always writes the attribute, so a missing one reads as `subscribe="0"`, no pushes ever arrive, the clock freezes and LMS is stranded in `play` (`Player.pm` `_startPolling` / `_statusWatchdog`) | **DECLINED** 2026-08-28 | Measured A/B against engine 6.0.4 on one connection each, 6s: bare `<Status/>` -> **2** pushes, `subscribe="1"` -> **2**, `subscribe="0"` -> **1**. Bare is equivalent to `subscribe="1"`; the "missing attribute reads as 0" step was flagged as unproven by the reporter and is the step that is false. The log pattern has a different cause: **HQPlayer stops pushing when it is not playing**. Watchdog firings during the healthy sweep 16:21-16:27 = **0**; continuous from 16:29:36, right after a pause at 16:29:06. Sending `subscribe="1"` explicitly is harmless and slightly clearer, but fixes nothing. THE REPORT'S SYMPTOM IS REAL WITH ANOTHER CAUSE - see the row below. |
| LMS can be stranded in `mode=play` with a frozen clock, leaving the Eversolo screen on for ever | **ACCEPTED 2026-08-28, FIXED in 0.2.50** | `_endOfStream` opens `return unless $self->hqStarted`, and `hqStarted` is only set when HQPlayer REPORTS playing. So a `Play` that is acked but never becomes playback tells LMS nothing, for ever. That is the state every tier 4 bug fixed in 0.2.27 produced; the causes are gone but the gap is not. Fix: a start timeout - if HQPlayer has not reported playing ~10s after the Play ack, report the load as failed. Would have surfaced the 0.2.24-0.2.27 bugs in seconds. Note the screen plugin already has its own net (`_reconcile` spots a non-advancing clock and asks the device); it failed here only because the Eversolo was unreachable at that moment. **Built as specified**: `START_DEADLINE` (10s) armed where the Play ack sets `hqPlayAck`, cancelled at the `hqStarted` latch, in `stop()` and in `_newGeneration`; on expiry it reports `playerStreamingFailed('PROBLEM_OPENING')` once. Three things it deliberately does NOT fail: a load superseded by a newer one (generation check), a track paused inside the window (LMS can pause a track that has not started, and HQPlayer then correctly never reports playing), and one that started (belt-and-braces `hqStarted` guard on top of the cancel). |
| `<Volume>` answers `result="Error"` — the command is wrong or unsupported | **DECLINED** 2026-08-27 | The level is applied regardless. With an **empty playlist** every `<Volume>` returns `result="Error"` carrying `clPlaylist::GetAlbumGain(): trackn > last`, which is HQPlayer recomputing replaygain over a playlist with no tracks. Verified against the live daemon: `GetVolumeDB` confirms the new level to 1/256 dB. `Control.pm`'s `%BENIGN` logs it at debug. |
| The volume curve should be tapered (a knee, or `denonavpcontrol`'s sqrt) rather than linear | **DECLINED** 2026-08-27 | Linear in dB **is** a logarithmic taper on the signal — equal dB per step. A bend would make a fixed skin increment (Material's volume step is 1, 3 or 5) worth a different number of dB depending on slider position, and it only pays off for a listener with one habitual level. It would also break agreement with HQPlayer's own 0-100 scale, which is linear over the range (`GetVolume` 61 at −39 dB on −100…0). |
| An endpoint re-registering can jump the output +21 dB, so an increase just after a link-up should be refused and pulled back (`Player.pm`, `_followVolume`) | **REVERSED** 2026-08-30 | Shipped in 0.2.31, removed in 0.2.32. The event is real, but the guard's trigger was `transport_serial`, which **increments at every track boundary** (measured 4→5→6→7→8→9 across five boundaries of one album). So it armed for 10s after every track change and pulled back the user's own volume changes. Simon's call: the volume is the user's. Do not re-propose without a trigger that means "the endpoint re-registered" and nothing else. |
| Tier 3 must go on the tier 4 player-stream endpoint, because that is the only unchunked route | **WRONG** 2026-08-30 | It is not the only one. `downloadMusicFile` chunks **only** when `$response->request->protocol eq 'HTTP/1.1'`; declaring the request `HTTP/1.0` gets LMS's own transcode with raw close-delimited framing. Routing tier 3 through the player stream fixed the framing and silently cost gapless, because that endpoint draws on the single per-player `$client->chunks`. Fixed in 0.2.32 with `/hqp3/`. **The lesson: "one player, one stream" was our own constraint, not LMS's** — check whether a limit is imposed or inherited before designing around it. |
| HQPlayer cannot fetch a URL containing a `?`, so everything must be path-only (the rule the whole tier structure was built on) | **WRONG** 2026-08-28, acted on 2026-08-30 | Disproven on the wire: HQPlayer sends query strings verbatim, `&`s and all, and plays the track. Two artefacts faked it — HQPlayer **strips the query from everything it reports** (`<Status/>` and its own log), and the one confirming probe was measuring **LMS returning 400 for any query string on that path**, not HQPlayer. It also proves the opposite: LMS could only answer 400 if it received the query string. Tier 2 was retired for this non-reason, and `Stream.pm` exists because of it. Only the **no-302** half survives. Superseded by tier 5 (0.2.33). **Lesson: read the wire, not the daemon's rendering of it.** |
| The hand-over is safe to gate on the uri, because on tier 1 every track has a url of its own | **WRONG for tier 5** 2026-08-30, fixed same day | HQPlayer STRIPS THE QUERY STRING from every uri it reports — the same display quirk that faked the no-query-string rule. On tier 5 the whole identity of a track is in that query string, so every Qobuz track reports the identical `.../file` and the uri carries zero discriminating information. As a veto that made the hand-over **undetectable**: live, `track` went 1→2 and every check said "not yet", so LMS never advanced, the next track was never armed, and HQPlayer ran out of playlist and stopped mid-album with time still on the counter. `_handedOver` now compares the query-stripped form on both sides; identical stripped urls fall through to the index test that already existed for the ambiguous case. **Local tiers are unaffected — no query string, so the veto still applies.** |
| HQPlayer's playlist should show the whole LMS queue, as Roon and HQPlayer's own library do — or at least be trimmed so it is not a list of finished tracks | **DECLINED** 2026-08-30, Simon's call: "stick with it as is" | Both halves were understood and neither is being changed. **All at once is not possible**: `_NextIfMore` caps LMS's song queue at two (`scalar @{$self->{songqueue}} < 2`), so only two URLs ever exist — LMS mints them lazily because service URLs are signed and time-limited and the queue is mutable. Roon differs because Roon OWNS the queue; here LMS does and we model a Squeezebox, which is also two-deep. **The growth is ours**: `_appendTrack` only adds and `<PlaylistClear/>` runs only on a full load, so HQPlayer accumulates a HISTORY of the run while LMS stays at two. Trimming with `PlaylistRemove` was offered and declined. So the list is expected to grow, and only its LAST entry is "next". |
| `track` only ever needs an INCREASE to count as a hand-over, because HQPlayer reports `track="0"` when it is not playing and `>` already rejects that | **WRONG** 2026-08-30, fixed same day in 0.2.37 | `>` rejects an advance *into* 0; it does nothing about 0 being the **BASELINE**, and 0 → 1 is an increase. HQPlayer reports `track="0"` in the push that lands between the `<Play/>` ack and its index catching up — `state` already says playing — so that 0 got stored as `hqTrackNo` and the very next push read as an advance into the pre-queued track. Live: `12:47:07.7074 HQPlayer is playing` (track 0) → `12:47:08.0498 track=1 seen=0 -> ADVANCED` → a SECOND `_armNextTrack` 4ms later. LMS moved to Movement 6 while HQPlayer played Movement 5, queued a third track (`tracks_total="3"` where two was right), and stayed **exactly one track ahead for the rest of the album**, its counter running out on every track. This is the spurious advance the `_handedOver` comment already calls the worst failure in the file — it just came in by a route nobody had covered. Fixed at BOTH ends: 0 is refused where it would be stored, and `_handedOver` requires `$seen > 0`. **Whether it fires is a race on how fast HQPlayer's index catches up**, which is why identical code was clean on the three loads before it. Arrived with 0.2.35's index fallback; not a 0.2.36 regression. |
| hqplayerd ignores a gain figure on `PlaylistAdd`, so there is no control-API route for streaming ReplayGain | **WRONG** 2026-08-30, corrected same day | The evidence was real — `gain="-4.07"` went over verbatim and was ignored — but the CONCLUSION generalised from one attribute name to the whole channel. `album_gain` works, overrides the file's own tags, and is stored per playlist item. Two things made the wrong reading look safe: `<Status/>` reports `gain="…"`, which is HQPlayer echoing what it read out of the FILE and not an input field; and the live queue's `<PlaylistItem>` carries no gain attribute, which was taken as proof the daemon holds no per-item gain when it simply does not report one. **The lesson is the probe, not the finding:** the whole matrix (`album_gain`, `track_gain`, `gain`, `adaptive_volume`, both as metadata and as PlaylistAdd attributes) was settled in minutes over port 4321 — append with `queued="0"`, `SelectTrack`, `Play`, read `:8088/log`, `Stop`, `PlaylistRemove` — against ONE local file with a known tag. Two builds were spent guessing at what one probe answered. |
| A boost must be trimmed against the room between the current volume and `_volMax`, because that room is the headroom (`Player.pm`, `_replayGain`) | **WRONG** 2026-08-30, shipped in 0.2.41 and reversed in 0.2.44 | It measured the wrong domain. **With hardware volume enabled the level is the endpoint's ANALOGUE preamp**, downstream of where digital clipping happens, so it buys no digital headroom at all in the path `album_gain` is applied in. hqplayerd splits the level and says so, measured across a whole session: `Set volume: -38 -> hardware: -34 software: -4`, `-33 -> hardware: -29 software: -4`, and hardware taking every bit of the movement (−30/−35/−39/−41/−43/−47) while **software stayed −4 throughout**. A different configuration splits differently again (`hardware: 0 software: -18` is in the same log), so the split must not be modelled either. **THE VOLUME MUST NOT ENTER THIS CALCULATION.** The real ceiling is HQPlayer's configured headroom, read from its log. |
| Local tiers must not send `album_gain`, because HQPlayer reads the file's own REPLAYGAIN tags and ours would be applied twice | **WRONG** 2026-08-30, fixed in 0.2.44 | The first half is true and the second is not. **`album_gain` REPLACES the tag, it does not add to it** — proven by isolating one local FLAC tagged −8.61 dB, sending `album_gain="-15"`, and watching it play at −15, not −23.61. And deferring to HQPlayer **loses the gain outright on a fresh load**: it applies the figure at Play time from tags it has already parsed, and the bridge goes Stop → PlaylistClear → PlaylistAdd → Play in ~300ms, so playback starts before the file has been fetched. Live on a fully-tagged album (`album_replay_gain -9.6`): three adds all played `0 dB (1)` and the −9.6 arrived only when the playlist next changed — **a whole album unnormalised**. It is also the better answer, because LMS has already chosen album vs track gain and HQPlayer only does album gain. Reported by Simon as a regression, and it was one. |
| A raw function's response needs no explicit status code — LMS fills one in (`Stream.pm`, `_downloadHandler`) | **WRONG** 2026-08-30, fixed in 0.2.45 | It does not, and the omission broke **every m4a, ALAC and AAC track** from 0.2.32 to 0.2.45. LMS builds the status line as `sprintf("%s %s %s", protocol, code, status_message(code))`, and a raw function is handed the response object "almost unmodified" — its own dispatcher comment is `$rawFunc shall call addHTTPResponse`. `downloadMusicFile` sets a code only on its ERROR paths (406, 400), so a successful tier 3 download went out as literally `HTTP/1.1  ` — protocol, two spaces, no code. HQPlayer said so precisely and nobody read it as a status line: `clStreamReaderHTTP::clStreamReaderHTTP(): clString::ToUInt(): not an integer ''`. `_handler` (tier 4) and `_fail` both set a code, which is exactly why tier 4 and our 404s worked throughout. **Invisible to the offline suite because it stubs `downloadMusicFile` and never sees a socket** — the test now asserts the code on the response object itself. |
| The headroom should be added back to every figure, so a track always lands on its ReplayGain target (`Player.pm`, `_replayGain`) | **WRONG for the NO-FIGURE case** 2026-08-30, shipped 0.2.44-0.2.46, fixed in 0.2.47 | Compensation only means something when there is a TARGET to land on. With no figure at all there is no target, and adding the headroom back turned "we know nothing" into a **+3.01 dB boost** that ate exactly the room HQPlayer reserves for its DSP. Reported by Simon — *"no replaygain no adaptive volume"* — and visible at both ends on a Qobuz album that publishes no gain: `replay gain none -> 3.01 dB` in the bridge's log, `Adaptive transport gain: 3.01 dB (1.41416)` in hqplayerd's. A 1.41× multiplier on material nobody asked to be normalised. **The distinction that survives:** a track whose figure IS `0.00` dB has a target of unity and still gets the compensation. Only the ABSENCE of a figure is inert. The unity assertion for a remote track stays — it just sends a flat `0.00` now instead of a compensated one. **SUPERSEDED by the 0.2.49 reversal** — the compensation, the log reader and the unity assertion are all gone; this row is kept for the reasoning, not the behaviour. |
| `Volume scaler` is the headroom, in a more precise form than `Convolution gain compensation` (`Player.pm`, `_convGainFromFile`) | **WRONG** 2026-08-30, shipped 0.2.44-0.2.47, fixed in 0.2.48 | Two different numbers that coincided. `20*log10(0.707107) = -3.01` matched the compensation of the day, and that was taken as confirmation. Simon set the compensation to **0**, played a fresh track, and the plugin kept compensating — because the scaler had not moved. Across a whole log it appears **21 times, 0.707107 every time**, spanning the change, while the compensation tracked the setting (18 × −3, then 5 × 0). They live in different sections of the init: the compensation after `Playback engine ratio:` in the DSP block, the scaler after `Network endpoint has volume range` in the OUTPUT stage. 0.707107 = 1/√2, the SDM/DSD full-scale convention (hypothesis; the constancy is measured). **Two lessons.** The value is now read from the NEWEST init block only, because "last match in the tail" picks up a stale compensation when convolution is switched off. And the wrong NAME caused this: hunting for something called "headroom" is what made a −3.01-looking constant persuasive — Simon: *"its called convolution gain compensation not headroom"*. **SUPERSEDED by the 0.2.49 reversal** — the compensation, the log reader and the unity assertion are all gone; this row is kept for the reasoning, not the behaviour. |
| The bridge should scale LMS's ReplayGain figure at all — compensate for HQPlayer's convolution gain, cap it against the peak, or assert unity when there is none (`Player.pm`, `_replayGain`) | **REVERSED** 2026-08-31, Simon's call | Every layer built over 0.2.39-0.2.48 is removed in 0.2.49 and the figure now goes out **verbatim, on every tier**, with no attribute at all when LMS has none: *"Adaptive gain for replay gain is just applied with no compensation at all as we originally had it. Do not read the gains from Convolution."* / *"all tiers operate the same, no replay gain provided by LMS no Adaptive Gain added"*. **The facts underneath the compensation were sound** — HQPlayer really does apply its convolution gain compensation on top of `album_gain`, so a -10.03 album with -3.01 of compensation really did land at -13.04 — but that is HQPlayer doing what the user configured, and cancelling it out is not the bridge's job. **The lesson is the pattern, not the arithmetic:** five builds each corrected the previous build's ceiling (volume room, then headroom, then peak-vs-0dB base) and every one was a new way to disagree with a number LMS had already computed correctly. When a correction needs its own correction three times over, the thing to question is whether to be correcting at all. `readConvGain`, `_convGainFromFile`, `_watchDsp`, `_dspSignature`, the three accessors and both constants are DELETED, and `t_player.pl` asserts their absence so a dormant reader cannot be quietly rewired. |
| `enabled` on `<VolumeRange/>` is the fixed-volume flag, and should replace `_watchForFixed` (`Player.pm`) | **WRONG** 2026-09-05, measured | It is not, and there is no HQPlayer-side fixed-volume state for any flag to report. Probed live against engine 6.0.4 with `<fixed volume="-3"/>` configured **and applied**: `<VolumeRange adaptive="1" enabled="1" max="0" min="-100"/>` — `enabled` unchanged, and the range did not collapse either. hqplayerd's own log agrees, printing `Volume max: 0` / `Volume min: -100` / `Control active volume range: -100 - 0 dB` at the restart that applied the setting, with `Set volume: -3.000000` alongside — and the word "fixed" appears **zero times in 10.9 MB of log**. **HQPlayer's "fixed volume" is a STARTUP LEVEL, not a lock:** it sets the output once, bypassing the startup/default volume, and the level stays changeable from HQPlayer's UI or from the endpoint's device volume on an NAA. Simon: *"It does not lock out volume control."* Signalyst's own client settles the type and nothing more — `ControlInterface.cpp:2177` parses `enabled` as a bool and `ControlApplication.cpp:668` only `qDebug`s it. **Nothing reads `enabled` or `adaptive`; both are logged at debug so a future engine changing them is visible without anything depending on them.** |
| The plugin should detect a non-attenuating HQPlayer and set the player's `digitalVolumeControl` pref to 0 itself (`Player.pm`, `_setFixed` / `_watchForFixed`) | **REVERSED** 2026-09-05, Simon's call | Both detectors — a zero-width range, and three sends that changed nothing — were inferring the state disproven in the row above, and on that inference `_setFixed` **wrote the user's pref**. A coincidence of three (the user holding the volume on HQPlayer's own UI across three sends) would silently switch the LMS player to fixed volume. Same over-reach class as the volume guard reversed in 0.2.32, and the same ruling: *"we should not be setting anything to 0"*. **The only fixed-volume switch is LMS's own radio**, and it means one thing — LMS stops driving HQPlayer's volume. The startup level is whatever HQPlayer holds (its software volume, or the device volume on an NAA like the Eversolo) and LMS mirrors it rather than asserting one. `_setFixed`, `_watchForFixed`, `hqVolFixed`, `hqVolForced`, `hqVolMissed`, `FIXED_STRIKES` and `MISS_DELAY` are DELETED; `digitalVolumeControl` is now READ and never written, and `t_player.pl` asserts both subs' absence and that no `set('digitalVolumeControl'` survives in `Player.pm`. |
| A failed load should always be handed to LMS as `PROBLEM_OPENING`, because skipping the track is the right recovery (`Player.pm`, the four `playerStreamingFailed` sites) | **ACCEPTED 2026-09-05, BUILT in 0.2.60** | It is right for ONE bad track and wrong for a sick link. Every failure LMS is told about makes it skip and load the next track, which fails the same way: measured against a wedged hqplayerd, **five full `Stop/Stop/PlaylistClear/PlaylistAdd` cycles in under one second**, racing the whole album while hammering a daemon that is already sick. The bridge does not cause the wedge — the daemon throws on a bare `<VolumeRange/>` from an uninvolved host — but it is the thing turning one failure into a hundred. Built as `FAIL_LIMIT` (**3**) + `_loadFailed`: all four routes to a failed load funnel through one sub so the run is counted across them, below the limit nothing changes, and at the limit the bridge stops the player instead of reporting another skippable failure. **The run is cleared in exactly two places** — the `hqStarted` latch (a track that really played is proof the link is healthy) and the trip itself (so the player is never left permanently armed; the user's next play gets a fresh three). **Deliberately NOT cleared in `stop()` or `play()`**: LMS calls both on the very skip path this exists to bound, so resetting there would defeat the count entirely. |
| UPnP must stay for the volume range, because the control API cannot report one (`UPnP.pm`, `Player.pm` `refreshVolumeRange`) | **REMOVED** 2026-09-05 in 0.2.54 | `<VolumeRange/>` is a control command and answers the same range in **plain dB** on the socket that is already open, in ~9 ms against UPnP's 300-550 ms. `UPnP.pm` (414 lines), `t_upnp.pl`, the `describe` handshake and its 5s->60s backoff, the SOAP client, the dormant Play-retry loop and `cancelPlay` are all deleted, and the range now rides the control link's own reconnect via `refreshInfo` on link-up — one retry carrier instead of two. The plugin no longer speaks HTTP at all (`SimpleAsyncHTTP` had no live caller left). **The 1/256 fixed-point discriminator did NOT come across**: that was RenderingControl's unit, and `<VolumeRange/>` is plain dB. Makes the port-8019 log-flood hazard structurally unreachable. |
| A refused pre-queue is safely demoted to a held load, because "the ordinary load runs at end of track" (`Player.pm`, `_appendTrack` / `_endOfStream`) | **WRONG inside the grace window** 2026-09-10, fixed same day | The demotion is right; the promise it rests on had one hole. `PlaylistAdd` is the ONE ordinary command that makes HQPlayer fetch and probe the media before replying, so a refusal can arrive AFTER the track it was queued behind has ended — i.e. inside the `END_GRACE` window that its own lateness opened. `_endOfStream` then cleared `hqNext` and reported the end of the playlist over a song LMS had already handed over and was still streaming, so **a single refused append stopped an album mid-way**. Nothing recovered it: the held-track branch in `_onStatus` needs a fresh `state=0`, and a stopped instance says nothing until the watchdog speaks `STATUS_WATCHDOG` (10s) later — long after the 3s timer has fired. Fixed by loading a demoted hand-over at expiry, reporting nothing to LMS, exactly as the tier 4 branch in `_onStatus` already does. **Note the trigger is a `result="Error"` REPLY, not a timeout** — `REPLY_TIMEOUT` is 30s and cannot land inside a 3s grace. **The remedy as reported said "the expiry OR failure callback"; only the expiry is correct** — at demotion time the current track is normally still playing, and loading from the callback would cut it off, which is the exact thing that callback's comment refuses to do. Reproduced and controlled in `t_player.pl`; **offline suite only, not yet run against a live daemon**. |
| Two albums are told apart by the album id, so `_artMatch` can compare the raw value (`Player.pm`, `_artMatch` / `_metadata`) | **WRONG across services** 2026-09-10, fixed same day | Within ONE service it is sound, and that is the case the rule was written for. Across two it is not: Qobuz's `albumId` and Tidal's `album_id` are unrelated numbering schemes, and the id test short-circuits **ahead of** the album name — so an id shared by chance overrode even a different title and one service's cover landed on another service's album. The name half collides far more easily still, and was the already-documented "residual risk": Deezer and Spotty publish no id at all, so any album title shared across two services matched on the name alone. Fixed by recording the **url scheme** on the art identity and treating a difference as a veto ahead of both tests — it costs nothing, it is already on the track, and it is stable across an album because an album is served by one service, so the Various Artists case the album key exists for is untouched. Vetoed only when BOTH sides name a service, the same shape as the id rule. The old fixtures had been writing `qobuz:111` into the id field, which is the namespace the production path never applied. Controlled in `t_player.pl` (the same service and album must still reuse, so the veto cannot pass by simply switching the feature off); **offline suite only, not yet run against a live daemon**. |
| A stop with a hand-over pending is resolved by waiting `END_GRACE`, and on expiry it is the end of the playlist (`Player.pm`, `_onStatus` / `_endOfStream`) | **WRONG** 2026-09-10, observed live, fixed in 0.2.81 | Simon's challenge, and he was right: *"we should not be sending end of playlist unless last track is reached"*. The timer is armed ONLY when `hqNext` is set, and `hqNext` exists only because LMS resolved a NEXT TRACK — so on that path the playlist provably has more to come and end-of-playlist is the one answer that CANNOT be true. **Seen in the wild the same evening**: 20:47:59, track 5 of an 11-track playlist with track 6 already queued, LMS told the playlist had finished. Four grace arms were observed that evening; three were cancelled by a normal advance and the ONE that expired was wrong. **The genuine end never uses the timer** — at the last track LMS arms no hand-over, `hqNext` stays undef and the stop is reported immediately (confirmed twice). The debounce itself is NOT the mistake and stays: measured raw, a boundary push and an end-of-playlist push are byte-identical (`state=0 track=0 tracks_total=0`, everything zeroed), so "did playback resume" is a fair question to ask with a short wait. Only the CONCLUSION changed. |
| `tracks_total`, or `track_serial`, can tell a track boundary from the end of the playlist | **WRONG** 2026-09-10 — proposed here, disproven here, do not re-propose | Both were measured off port 4321 and both fail. **`tracks_total` is NOT the playlist length**: it is HQPlayer's OWN accumulated list (played + playing + the one pre-queued), because `_appendTrack` only adds and `<PlaylistClear/>` runs only on a full load. Measured simultaneously: LMS `playlist_tracks`=**11**, HQPlayer `tracks_total`=**3**. Since LMS hands over exactly one track ahead, `track < tracks_total` means only "a hand-over is pending", which `hqNext` already says. **`track_serial` is not an advance signal either**: it stepped 5→6 at the END of a one-track list where no next track existed. It counts PLAYLIST-CURSOR ADVANCES, including the step past the final item. Three boundary observations agreed with the advance hypothesis and the first end-of-list observation killed it — every sample had been the same event type. What the serial DOES say is whether the track ran out or was abandoned, which is what 0.2.81 uses it for. |
| The abandoned-stop test can sit anywhere in the `HQP_STOPPED` branch, because the held tier 4 track above it is only ever consumed at a REAL end of track (`Player.pm`, `_onStatus`) | **WRONG** 2026-09-10, fixed in 0.2.82 | Order matters, and it was the wrong way round. The held-track branch does not read the cursor at all, so with a tier 4 track already handed over it answered a stop made at HQPlayer's own UI by LOADING AND PLAYING THE NEXT TRACK. The window is narrow — it needs the CURRENT track on tier 1/3/5, the NEXT one on tier 4, and the stop to land after LMS handed it over — which is why Simon's live stop test (0.2.81, tier 1 throughout) followed the stop correctly and did not reach it. **CONFIRMED LIVE 2026-09-10 23:38**, on the third attempt — the first two never reached it because Qobuz is tier 5 and a local file is tier 3, so the playlist needed **Deezer** (the one service that declines the direct hook) behind a local track. Sequence: `23:36:56` tier 1 playing, `23:37:59` tier 4 resolved and `the next track is tier 4 - holding it`, `23:38:26` stop at HQPlayer's own UI 27s into that window -> `stopped outside LMS part way through the track - following`. **The load line is ABSENT**, which is the whole verdict: on 0.2.81 the next entry would have been `end of track - loading the tier 4 track LMS handed over early` and Deezer would have started playing. Nothing loaded afterwards either. Fixed by testing the cursor FIRST. Safe in that direction because a track that genuinely RAN OUT moves the cursor, so the abandoned test cannot fire at a real end of track and the tier 4 load still runs there untouched — pinned by a control assertion. |
| A pending hand-over proves the held track has NEVER PLAYED, so loading it at expiry restarts nothing the listener has heard (`Player.pm`, `_endOfStream`) | **INCOMPLETE** 2026-09-10, fixed in 0.2.82 | True whenever `_handedOver` is right, and `_handedOver` can be wrong in the MISSING direction: it returns 0 before the `PlaylistAdd` ack, it treats a non-matching uri as a **veto** rather than a hint, and on tier 5 every reported uri strips to the same string so the index is all it has. A real advance that trips one of those leaves `hqNext` set on a track HQPlayer then plays to the end — and 0.2.81's new `mode eq 'queue'` branch would load it again, replaying a song just heard. **Not observed live, and CLOSED that way deliberately: it cannot be provoked from outside.** Every route needs `_handedOver` to fail spontaneously, which no playlist, service or transport action can force. **So the guard reports itself instead of being tested**: whenever it suppresses a reload it logs `the hand-over was entered after all (cursor N -> M) - not reloading it`. That line appearing in the wild IS the measurement. If it never appears, the case never happens and the guard costs one comparison. Fixed by stamping the cursor onto the held item at append time and reloading only when it has since moved AT MOST ONCE. **This is not row 38 re-proposed** — see §0.2.82. |
| `_appendTrack` stamps the cursor as it stands at the append, so the held item always carries the value HQPlayer was at when it was queued (`Player.pm`, `_onStatus` / `_appendTrack`) | **WRONG** 2026-09-11, fixed in 0.2.85 | True for the FIRST append of a run and **stale for every one chained off a hand-over** — track 3 onward. `_onStatus` called `_handedOver` ~50 lines ABOVE `$self->hqTrackSerial($serial)`, and `_handedOver` ends in `_armNextTrack` -> `playerReadyToStream`, which real LMS answers by re-entering `play()` SYNCHRONOUSLY for a LOCAL track — chain walked in LMS `public/9.0`: ReadyToStream -> _NextIfMore -> _getNextTrack -> `getNextSong` (a file has no `scanUrl` and no `getNextTrack`, so it falls to "the simple case" and calls its success callback INLINE) -> NextTrackReady -> _StreamIfReady -> _Stream -> `play()`, every step a direct call with no timer. So `_appendTrack` ran INSIDE the push and stamped the PREVIOUS cursor, one low. `_endOfStream` then read the difference as 2 rather than 1, decided the held track had already played, and reported end of playlist — reintroducing the 20:47:59 mid-album stop for every boundary but the first. **Tier 5 is unaffected** (the service handler DOES implement `getNextTrack`, so the append lands after the store) and tier 4 never pre-queues; this is tier 1/3, local files. Bounded in one direction only: a stale stamp can suppress a reload, never cause a spurious one, so nothing is ever replayed. **Nothing released was affected — `main` ships 0.2.77**, and the cursor arrived in 0.2.81. Invisible to the suites because `LoadController` answers `playerReadyToStream` through AUTOLOAD and never re-enters `play()`, so only the first append was ever exercised. Fixed by moving the cursor read and store ABOVE the hand-over check, `$seenSerial`/`$cursorMoved` still captured before the store. See §0.2.85. |


Presents each HQPlayer instance on the network as a native Lyrion player,
driven over HQPlayer's own XML control API. Replaces the `squeeze2upnp` UPnP
bridge path.

**The plugin adds no audio stage of its own.** LMS and HQPlayer are both *pull*
engines: LMS hands a player a URL and the player fetches the bytes; HQPlayer
does the same. So the bridge only moves control messages, and hands HQPlayer a
URL pointing back at LMS's own HTTP server. That removes the UPnP hop, the
external binary and the bridge's own buffer.

**BUT "no audio through the plugin" IS NOT TRUE, AND MUST NOT BE WRITTEN THAT
WAY.** It was, in every description, until Simon corrected it 2026-09-05. Per
tier: **tier 1** and **tier 5** genuinely are untouched — the file is served
byte-for-byte and a service URL is fetched by HQPlayer from the service itself.
**Tier 3 is a TRANSCODE**: a format HQPlayer cannot decode (m4a/ALAC/AAC, 3.8%
of Simon's library) is converted by LMS on the fly. **Tier 4** carries its bytes
through LMS's streaming machinery and this plugin's own `/hqp/` endpoint. So the
honest claim is about the plugin adding no stage, never about LMS not touching
the audio.

**The core premise is verified end to end** (2026-08-26, live hqplayerd 6.0.4):
`PlaylistAdd` accepts an arbitrary `http://` URI, and HQPlayer fetches it
itself — `HEAD` then `GET`, logged arriving at a plain Python HTTP server —
then plays it.

## Layout

| File | Role |
|---|---|
| `HQPlayerBridge/Plugin.pm` | Lifecycle, discovery wiring, player create/teardown, the Apps feed |
| `HQPlayerBridge/Discovery.pm` | UDP multicast probe, instance list |
| `HQPlayerBridge/Control.pm` | Async TCP XML client + tiny XML helpers |
| `HQPlayerBridge/Player.pm` | `Slim::Player::Player` subclass - the virtual player |
| `HQPlayerBridge/Stream.pm` | Tier 4: the plugin's own audio endpoint, serving LMS's transcoded stream. Its paths carry no query string, but that is a convention, NOT the constraint the ledger disproves at the top of this file |
| `HQPlayerBridge/Live.pm` | The standalone live page - a raw handler owning the WHOLE document |
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

That is what one live instance sent. The **full** attribute set, from the
vendor client's own parser (`ControlInterface.cpp`, `cmd == "Status"`), is
larger and several of them matter here:

`state track track_id min sec volume clips tracks_total track_serial
transport_serial queued position length begin_min begin_sec remain_min
remain_sec total_min total_sec output_delay apod active_mode active_filter
active_shaper active_rate active_bits active_channels filter_junk correction
random repeat input_fill output_fill process_speed`

* **`queued` is a BOOLEAN**, not a count — the client reads it as `bool`.
  Observed live it reads 1 from a gapless advance onward, so it means "this
  track came off the queue" rather than "a hand-over is pending". See
  "Gapless".
* `track_serial` and `transport_serial` are per-track / per-transport
  counters; the vendor client marks both `Q_UNUSED`, so their exact semantics
  are unconfirmed, but a serial that bumps per track would be a cleaner
  advance signal than the playlist index.
* `input_fill` / `output_fill` are HQPlayer's own buffer levels, which is the
  one honest answer this bridge could give to `bufferFullness` — it currently
  reports a fixed healthy-but-not-full figure instead. **Careful**: `usage()`
  is `bufferFullness / bufferSize`, and `_CheckPaused` closes the source stream
  outright above 98% on a paused remote track, which for this player is always
  wrong. Any move to a real figure has to keep it off that ceiling.

The `<metadata/>` **child** of `<Status/>` carries, in full:

`uri` (or `secure_uri` + `nonce`) `mime artist composer performer album song
genre date albumartist track_id samplerate bits channels float sdm bitrate
features extrainfo gain`

`gain` is the replaygain HQPlayer actually applied — the figure the log prints
as `Adaptive transport gain: -6.31 dB`, available on every push rather than
only in a log nobody can reach. `float` and `sdm` say what the *source* was.
The plugin reads only `uri`, `samplerate` and `bits`.

### `<Status subscribe="0|1"/>` — the flag nobody knew about

Verified live 2026-08-28: `subscribe="0"` is a **one-shot poll** (one reply, no
push stream) and `subscribe="1"` subscribes. The bare `<Status/>` the plugin
sends behaves as `subscribe="1"`.

This matters in two places the plugin gets slightly wrong today. `refreshInfo`
and the settings page have no way to ask for the current state without
(re-)subscribing, and `_statusWatchdog` re-sends a bare `<Status/>` every time
the stream dries up — so a subscription is repeatedly re-asserted and never
turned off, including on a player sitting idle. Sending the flag explicitly
makes both intentional.

* **`state` is an INTEGER**: `0` = Stopped, `1` = Paused, `2` = Playing.
  Matching it as a word silently never fires — this was a real bug here.
* `length` is the true duration in seconds, correctly read from the FLAC.
* Position is `position` (seconds), with a `min`/`sec` pair as a fallback.
* **`active_rate` is the DSD/output rate, not the source rate.** The source
  format is on the `<metadata/>` **child** (`samplerate`, `bits`).

## One channel

**Everything runs on the XML control API on 4321** — transport, state, track,
metadata, artwork, volume level *and* volume range. `<Status/>` is a subscribe
pushing ~1/s, and a command answers in **~9–150 ms**.

| | XML API (4321) |
|---|---|
| transport + state | subscribe, play, pause, stop, seek |
| track + metadata + artwork | `PlaylistAdd` + `<metadata cover="…"/>` |
| volume level | `<Volume value="-53"/>`, in dB |
| volume **range** | `<VolumeRange/>`, once at connect |

**UPnP is gone as of 0.2.54.** The range was the last thing on port 8019, and
`<VolumeRange/>` answers it on the socket that is already open. Verified live
2026-08-28 against engine 6.0.4, and again 2026-09-05:

```xml
<VolumeRange adaptive="1" enabled="1" max="0" min="-100"/>
```

Same range `GetVolumeDBRange` reported, in **plain dB** rather than 1/256, in
~9 ms instead of 300–550 ms. Removing it took `UPnP.pm`, the device-description
dance (`describe`, its 5s→60s backoff, `root.xml`, the SOAP client), the
dormant Play-retry loop and the plugin's only HTTP client with it — and made
the port-8019 log-flood hazard structurally unreachable.

**`min` and `max` are read; `enabled` and `adaptive` are NOT.** `enabled` was
assumed to be the fixed-volume flag and is measured not to be — see the Review
Ledger. Both are logged at debug so a future engine changing them is visible
without anything depending on them. **Do not carry the 1/256 fixed-point
conversion across**: that was RenderingControl's unit, not this one's.

`GetVolumeDBRange` and `GetVolumeDB` really are absent from the control API —
but they are the **UPnP action names**, and the earlier note here inferred "so
there is no way to ask" from their absence. It stopped one command short. The
range was always available; nobody had read the vendor's list.

### The artwork field is `cover`, and it takes a plain URL

This cost a lot of time, so it is written down precisely. `PlaylistAdd` is not
a self-closing element — it has a **body**, and that body takes a `<metadata/>`
child:

```xml
<PlaylistAdd uri="http://lms:9000/music/101/download.flac" queued="0" clear="1">
  <metadata song="…" artist="…" album="…" cover="http://lms:9000/music/abc/cover.jpg"/>
</PlaylistAdd>
```

Verified against engine **6.0.4** on 2026-08-28 by writing an item both ways and
reading it back with `<PlaylistGet picture="1"/>`. The results are
byte-identical — same `cover`, same 68-char `picture`:

| written | `picture` read back |
|---|---|
| `<metadata cover="http://…/cover.jpg"/>` | `aHR0cDovLzE5Mi4x…` (68) |
| `SetAVTransportURI` + `<upnp:albumArtURI>` | `aHR0cDovLzE5Mi4x…` (68) |
| `<metadata cover="<base64 url>"/>` | 92 chars — **double-encoded** |
| `picture=`, `albumArtURI=`, `art=`, `<picture>` child | empty |

**HQPlayer base64-encodes the URL into `picture` itself.** Pass the URL exactly
as it is. And HQPlayer *merges* rather than overrides: it fills in
`albumartist`, `date`, `bitrate` and `bits` from the file's own tags while
keeping the `song`/`artist`/`album` set here. The item also carries
`album_artist`, `genre`, `composer` and `performer` if they are ever wanted.

**The earlier claim that only DIDL could do this was wrong**, and it was wrong
in a specific way worth remembering: the probing tested `picture=` as an
attribute and `<picture>` as a child, concluded "everything is ruled out", and
wrote that conclusion down as fact. It never tested the field HQPlayer's own
`library.xml` uses for exactly this, which is `cover`.

### TRAP: a remote track's metadata is the HANDLER's, not the track row's

`artistName` and `albumname` are populated for a library track and **empty for
a streaming one** - Tidal/Qobuz/Deezer keep that with the protocol handler,
which is where LMS's own displays read it. A Tidal track reached HQPlayer as
`song` + `cover` + `length` and nothing else, 2026-08-28. The artwork was right
the whole time, because `_coverURL` was the only thing asking the handler; that
asymmetry made it look like a display fault rather than a send fault.

**And the handler WINS - it is not a fallback.** On radio the row's title is
populated and it is the wrong one: it is the STATION.

| | track row | handler |
|---|---|---|
| Tidal | `ONLY THING LEFT` | `ONLY THING LEFT` |
| Radio Paradise | `Main Mix - FLAC Interactive` | `Road to Joy` |

Preferring the row is wrong for every remote track; it just takes a stream
whose row title is filled in to reveal it. `_handlerMeta` returns `{}` for a
local url, so the library path never reaches the handler at all.

A handler may return artist/album as a plain string, a hash, or an object -
unwrap all three, or a reference gets stringified into what the endpoint shows.

**Radio metadata goes stale, and cannot be fixed from here.** The metadata is
sent once, with `PlaylistAdd`, so when the station moves to the next song
HQPlayer still shows the one that was playing when the stream started. There is
no update path: the vendor's complete command vocabulary (see
`hqp-control-601-src/`) has `PlaylistAdd`, `PlaylistDelete`, `PlaylistRemove`,
`PlaylistGetSingle` and the moves, and **nothing that rewrites an existing
item's metadata**. Re-adding the item would restart the stream. The one
untested avenue is ICY metadata in the stream itself - our tier 4 endpoint
sends no `icy-metaint`, and whether HQPlayer would even ask for it is unknown.

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

### GONE with UPnP in 0.2.54: the Play/SetAVTransportURI race and the describe retry

Two traps lived in `UPnP.pm` and are recorded here because they explain why the
file looked the way it did, not because any of it still runs. **Both are
deleted**, along with `UPnP.pm` itself.

**Play raced SetAVTransportURI.** `SetAVTransportURI` returned as soon as it had
*accepted* the URI, but HQPlayer then fetched and probed the media before the
transport actually held anything, so a `Play` issued too early failed with UPnP
**702 "no contents"** — measured: at ~0.5s it failed, the identical call ~1s
later succeeded. Nothing in `GetMediaInfo` reflected it (`NrTracks` already read
1), so `playWhenReady` retried blindly (8 × 0.4s), bounded by `PLAY_TIMEOUT` (5s
per attempt) and `PLAY_DEADLINE` (12s across the loop). It was **dormant from
0.2.13**, when the load moved to the control socket: `<Play/>` there is chained
off `PlaylistAdd`'s reply and answered OK first time in every live test.

**`describe` had to retry itself.** Without a device description there was no
control path at all. It ran when the player was created and again when the
control link came up, and *neither of those recurs* — LMS and hqplayerd starting
together (a server reboot) is exactly the case where the first fetch fails and
the link then stays up, so no further attempt would ever be made. Hence a 5s→60s
backoff, and `UPnP::close` from `_teardown` to stop it.

**That whole retry carrier is gone, not replaced.** The range now rides the
control link, which already owns reconnect and backoff, and `refreshInfo` re-asks
on every link-up — so the reboot case is covered by the one mechanism instead of
two. **The lesson worth keeping: a second transport brings its own liveness
problem, and its own retry loop to get wrong.**

## The signal path on the settings page (0.2.55)

**Everything HQPlayer reports about what it is doing arrives on the `<Status/>`
push we are already subscribed to.** Reading it costs no command and no round
trip; `_onStatus` simply stops throwing it away.

**The two halves are on different elements, and showing them together is the
point:**

| half | where | fields |
|---|---|---|
| **source** — what LMS handed over | the `<metadata/>` **child** | `samplerate`, `bits`, `mime` |
| **output** — what HQPlayer feeds the NAA | the `<Status/>` **root** | `active_rate`, `active_bits`, `active_mode`, `active_filter`, `active_shaper`, `process_speed` |

Measured live 2026-09-05: a `44100/16` FLAC going out as `96000/24` PCM through
`poly-sinc-gauss-long` + `TPDF` at `30.3x`.

**Three rows, not one** (0.2.56, Simon's call - the single packed row was
messy): `Source`, `Output format`, and `Processing`, with the tier prose as the
description under `Processing`. `PLUGIN_HQPLAYER_STREAM` is retired.

**`active_filter` and `active_shaper` arrive as NAMES**, so there is no
`GetFilters`/`GetShapers` id lookup to do. `<State/>` carries only the numeric
ids (`filter1x=37`, `filterNx=40`, `shaper=7`) and *would* need one — which is
exactly why these are read off `<Status/>` and not there.

**It reports the filter ACTUALLY IN USE**, so a 44.1k source shows the 1x filter
and a 96k source the Nx one. That is the honest answer to "what is it doing now"
rather than a copy of both dropdowns in HQPlayer's UI.

`hqPath` is a lazily-created hash (`Slim::Utils::Accessor` hands back undef
until something is stored). A push that omits the fields leaves the last known
values alone, and nothing is cleared on stop — the same way `hqRate`/`hqBits`
have always behaved.

### Live signal path: ONE formatter, three surfaces (0.2.59)

`Plugin::signalPathFor` formats the display strings, and **the Apps feed, the
settings page and the `signalpath` query all render what it returns.** The
template does no formatting at all. Three surfaces showing the same facts is
exactly where one concept grows three carriers and they drift; there is one.

A key is **absent, not empty**, when HQPlayer has not reported it, so a caller
tests the key and skips the row rather than drawing a label with nothing after
it.

**The settings page polls; the Apps feed cannot.** Material renders a browse
response once and never polls it - hence the manual Refresh row there
(`nextWindow => 'refresh'`, 0.2.58). The settings page is ordinary HTML in an
iframe, so a small poller updates it in place, the same client-side route LBF
uses because Material swallows the server-side `warning` channel.

**Why polling is not a flood, and costs HQPlayer NOTHING:** every value is
already in memory from the `<Status/>` push the plugin subscribes to whether
anyone is looking or not. A poll reads a hash - **no command goes out on 4321**.
The poller runs only while the page is open, stops on `document.hidden`, uses a
2s period (HQPlayer pushes ~1/s, so faster cannot be fresher), and gives up
after 5 consecutive errors rather than hammering a restarting server.

**The query returns the formatted strings, not raw fields**, so the JS only
assigns `textContent`. Parsing a formatted row apart in JS would break the
moment anyone translates the strings.

### The Apps feed: how the settings page is reached from Material (0.2.57)

**The plugin is `Slim::Plugin::OPMLBased`, not `Slim::Plugin::Base`, for exactly
one reason:** OPMLBased is what registers a top-level app entry, and that entry
is the only way to reach the settings page from Material without going through
LMS's server settings menu, which is several taps deep. Reported by Simon
2026-09-05: *"its hard to access from the main server menu"*.

`topLevel` serves a read-only feed:

* **the settings row FIRST**, `type => 'link'` with
  `weblink => '/plugins/HQPlayerBridge/settings/basic.html'` — Material opens
  that in its own iframe dialog. The same pattern LMS-Listen-to-Later and
  LMS-ListenBrainz-New-Releases use.
* then, per instance, the name, the link state with the address, and the same
  Source / Output format / Processing facts the settings page shows.

**Every status row is `type => 'text'`.** A non-playable item with no action
still gets an `addAction` forced onto it by XMLBrowser, which is how a feed
"divider" ends up navigating somewhere when tapped — `text` avoids it outright.

**`menu` is DISCARDED when `is_app` is set** - checked against LMS's own
`Slim/Plugin/OPMLBased.pm`, which does `if ($args{is_app}) { $args{menu} =
'apps' }` before `initJive`, `initCLI` and `webPages` read it. So the value
passed in never survives, and the four siblings that pass `'radios'` land under
Apps because of `is_app`, not because of `'radios'`. Do not read meaning into
that argument.

**Why OPMLBased at all:** `Slim::Plugin::Base` has no menu mechanism whatsoever
- it is `initPlugin`/`shutdownPlugin`/`getDisplayName` and nothing else - so
there is no way to get a Material entry from it. OPMLBased `use base
'Slim::Plugin::Base'`, so it is a strict superset and costs nothing that was
already working; what it adds is `initJive` (the Material/Jive menu entry) and
`initCLI` (the `[tag, 'items', ...]` dispatch Material queries). The only
alternative is calling `Slim::Control::Jive::registerPluginMenu` and
`addDispatch` by hand, which is reimplementing OPMLBased with less testing.

**`_shortMime` lives in `Plugin.pm`, not `Settings.pm`.** Both surfaces need it
and `Settings.pm` is only `require`d under `main::WEBUI` — calling it from the
feed would die on a headless build.

### Material: why this is settings-page only

**Material cannot show live plugin text on the Now Playing screen**, and Simon
has ruled out an upstream PR for it (2026-09-05), so the settings page is the
whole feature. Checked against the installed **Material 6.4.9**:

* **No NP hook.** Material builds Now Playing from track metadata; there is no
  plugin mechanism for arbitrary status text there. It would need the
  conditional/placement capability parked in the Material asks.
* **`registerInfoProvider` WOULD work** — the track info menu already renders 18
  items from Spotify/Qobuz/TIDAL/Deezer/Lyrics on this box, and it reaches every
  control point, not just Material. It lands under **"… → More Info"**, two taps
  from Now Playing, as a snapshot when opened. **Offered and declined** — Simon:
  *"just stick with plugin settings"*.
* `registerCustomAction` is fully available on 6.4.9 (PR #1257 shipped there),
  but it delivers an ACTION ROW, not a live display — the wrong shape for this.

**If this is ever revisited**, the design point to settle first is that the
signal path belongs to the PLAYER, not the track: an info provider must only
offer itself when the track being inspected is the one actually playing on that
client, or it shows a path for a track that is not running.

## One thing HQPlayer still will not do

**The NAA name is not exposed.** `GetTransport` answers `value` (a numeric id)
and `arg` (a string) — corrected from the vendor source, which reads exactly
those two; the earlier note here said there was no name field at all, when in
fact `arg` **is** that field and simply came back **empty** on this instance
(`arg="" value="240"`). `SetTransport` takes the same pair, so `arg` is a
device path rather than a display name in any case. `GetInputs` lists sources
(`cd:`), not outputs. The endpoint name appears only in hqplayerd's own log
(`NAA output endpoint 'Eversolo:DMP-A8(ManCave)' : 'hw:0'`), which is not
reachable from another host. The status page therefore reports the transport id
and says plainly that the name is unavailable.

## ReplayGain — LMS computes it, we carry it, on every tier

**HQPlayer can read a local file's own tags.** Verified live 2026-08-30: an
album carrying `REPLAYGAIN_ALBUM_GAIN=-6.31 dB`
(`REPLAYGAIN_REFERENCE_LOUDNESS=-18.00 LUFS`) produced exactly

```
Adaptive transport gain: -6.31 dB (0.483615)
```

with nothing sent from the bridge. **That was taken as a reason to send nothing
on local tiers, and it was wrong — see the ledger row.** `album_gain` REPLACES
the file's tag rather than adding to it, and HQPlayer reads the tags too late to
catch a fresh load. **`_replayGain` runs for every tier, and every tier is
treated identically** — see the 0.2.49 reversal below.

**A service CDN file carries no ReplayGain tags at all.** Every streamed track
logged `Adaptive transport gain: 0 dB (1)`, and `<Status/>` for a playing
24/96 Qobuz FLAC reported `gain="0"`. That is the gap this section is about.

**LMS HAS the number, and getting it costs one accessor.** With Smart Gain on
(`replayGainMode = 3`) the bridge player's `status` answers:

```
"replay_gain": -4.07,
"remoteMeta": { "url": "qobuz://420452060.flac", "bitrate": "2493kbps" }
```

`StreamingController` computes it via `Slim::Player::ReplayGain::fetchGainMode`
and stores it on the Song ("store this for status queries") before calling
`play()`. **No per-service code is needed.** Earlier plans to read Qobuz's
`audio_info`, Tidal's `replay_gain`/`peak` and Deezer's `gain` out of the
plugins' own caches are unnecessary — do not build them.

**The album-vs-track decision is NOT ours and must not be reimplemented.** For
a remote track `fetchGainMode` hands straight off to the service plugin's
`trackGain` *before* any of LMS's own mode logic runs. Qobuz publishes both
album and track figures so its choice is a real one; a service that publishes
only track gain simply yields a track figure. **And because the choice is
context-sensitive** — Smart Gain compares a song's playlist neighbours, so the
same track is legitimately −4.07 inside its album and something else in a
mixed queue — **the value is read per queue event and never cached against the
track.** `$song->replayGain` for the track being started, `fetchGainMode` at
arm time for a pre-queued one.

### SETTLED: enabling replay gain does NOT cause a transcode

Checked against the 9.1 source, because the premise was that turning it on
would put LMS in the audio path. It does not. `Slim/Player/TranscodingHelper.pm`
and `Slim/Player/Source.pm` contain **zero** occurrences of "gain" or "replay" —
there is no gain stage anywhere in the transcode pipeline. The only consumer is
`Slim::Player::Squeezebox::stream_s`, which does
`$client->canDoReplayGain($params->{replay_gain})` and packs the result into the
`strm` command as a 16.16 fixed-point multiplier, applied **by the player**.

On this player it is doubly inert: `canDoReplayGain` returns 0, so LMS computes
the figure, stores it on the Song, passes it to `play()` — and we are the only
thing that ever looks at it.

### ANSWERED: `album_gain` WORKS. `gain`, `track_gain` and `adaptive_volume` do not

**Isolated live 2026-08-30** by appending ONE local FLAC whose own tag is
−8.61 dB and watching what HQPlayer actually applied:

| sent on `<metadata/>` | applied |
|---|---|
| `album_gain="-15"` | **−15 dB** — overrode the file's own tag |
| `track_gain="-11"` | −8.61 dB — ignored, the file's tag won |
| `album_gain="-15" track_gain="-11"` | −15 dB — `album_gain` wins |
| `gain="-4.07"` | ignored |
| `adaptive_volume="-20"` (metadata **and** `PlaylistAdd` attribute) | ignored |

**`gain` is a REPORT, not an input.** `<Status/>` echoes back whatever HQPlayer
read out of the file — with that FLAC loaded it answered `gain="-8.61"`. That is
what made it look settable, and it is why 0.2.36 (which put `gain="-4.07"` on the
wire verbatim) changed nothing.

**And `track_gain` is ignored for a structural reason, not an API quirk: album
gain is HQPlayer's ONLY replaygain mode.** `playlist_album_gain` in
`~/.hqplayer/hqplayerd.xml` is the single switch and `clPlaylist::GetAlbumGain()`
the only reader — see the note on `assertRepeatOff`. There is no track-gain path
for a `track_gain` attribute to feed. **The feature therefore depends on that
switch being on**; if `album_gain` is ever seen doing nothing, check
`playlist_album_gain="1"` before looking anywhere else.

**The volume commands cannot carry it either.** `<SetAdaptiveVolume>` parses an
unsigned int — it answered `clString::ToUInt(): not an integer '-4.07'` — so it
is a bool toggle and nothing more. Adaptive volume was already ON throughout
(`<State adaptive="1"/>`, `<VolumeRange adaptive="1" enabled="1" max="0"
min="-100"/>`), which is why local files were already being normalised.
`<Volume>` is the endpoint's HARDWARE level (hqplayerd logs it splitting a level
as `hardware: -29 software: -4`) and is **off limits** — Simon's call, 2026-08-30:
moving it would move the Eversolo's own volume.

### REVERSED in 0.2.49: the figure goes out VERBATIM, and nothing is read from HQPlayer

**What LMS says is what HQPlayer gets.** `_replayGain` returns
`$song->replayGain` (or `fetchGainMode` for a pre-queued track) and
`_metadata` formats it to two decimals. There is no scaling, no ceiling, no
trim and no assertion of unity. Simon's call, 2026-08-31: *"Adaptive gain for
replay gain is just applied with no compensation at all as we originally had
it. Do not read the gains from Convolution."*

**Every tier behaves identically.** A figure from LMS is sent; **no figure from
LMS means no `album_gain` attribute at all** — local and streaming alike —
*"all tiers operate the same, no replay gain provided by LMS no Adaptive Gain
added"*. The local/remote asymmetry that used to live here is gone with the
rest of it.

**WHAT WAS DELETED, and it must not come back.** 0.2.39–0.2.48 built up four
layers on top of LMS's figure, and all four are removed:

| Removed in 0.2.49 | What it did |
|---|---|
| Headroom compensation | added HQPlayer's convolution gain compensation back to every figure |
| `readConvGain` / `_convGainFromFile` | fetched `:8088/log` once per track and parsed the newest engine-init block for `Convolution gain compensation:` |
| `_watchDsp` / `_dspSignature` | watched the DSP fields on every `<Status/>` push to force a re-read when processing changed |
| The clipping ceiling | held the combined figure under `-20*log10(peak)`, reading `$track->replay_peak` |

The `hqConvGain` / `hqConvGainAt` / `hqDspSig` accessors, the `LOG_TAIL` and
`CONVGAIN_MAX_AGE` constants, the `catfile` import and the whole
`Slim::Player::ReplayGain::preventClipping` line of reasoning went with them.
`tools/t_player.pl` asserts their **absence** — a dormant reader would be one
edit away from being wired back in.

**The reasoning that motivated the compensation was not wrong on its facts.**
HQPlayer really does apply its convolution gain compensation on top of
`album_gain`, so a −10.03 dB album with −3.01 of compensation really does land
at −13.04. **That is HQPlayer doing what the user configured it to do**, and
cancelling it out is not the bridge's job. Five builds were spent trying to
land tracks on a computed target and each one moved the goalposts somewhere
else; sending the number LMS states is the behaviour 0.2.38 shipped and the
behaviour to keep.

**If normalised playback seems quiet, the compensation setting is the thing to
change** — in HQPlayer, by the user. Do not reintroduce a reader for it, and do
not reach for the peak either: LMS applies its own clip prevention upstream of
anything the bridge sees.

`_replayGain` logs the raw figure and the sent one on every track. They are now
always the same number, which is the point.

### CORRECTED: there IS a live meter, on control port + 1

**Recorded here as "the client source has no metering command" and that was
wrong.** Simon said twice that the levels are visible in the desktop client's
meters and therefore available; the sweep that "disproved" it only ever looked
for an XML command name on 4321. **The metering channel is a SECOND SOCKET
carrying PACKED BINARY, so no command sweep could ever have found it** —
[[exhaust-the-api-reference]], read the client's classes, not just its verbs.

`clMeterInterface` in Signalyst's own `ControlInterface.cpp`:

```cpp
void clMeterInterface::setServer (QString hostname, quint16 hostport)
{
    serverHost = hostname;
    serverPort = hostport + 1;          // <- control port + 1, so 4322
}
```

Connecting **is** the subscribe (hqplayerd logs `Meter connection from …` /
`Metering enabled`); disconnecting unsubscribes. The stream is a repeating
header plus per-channel data, `#pragma pack`, little-endian:

```c
typedef struct { unsigned version, channels, xformLength;
                 int xformBits;                       // negative = float
                 float bandwidth, xformTime, xformGain, reserved2; } head_t;   // 32 bytes
typedef struct { float peakMax, peak, rms, rmsMax; } data_t;                   // per channel
```

then `xformLength` floats twice per channel — the spectrum. So one frame is
`32 + channels * (16 + xformLength*4*2)` bytes.

**Verified on the wire 2026-08-30** against the live daemon while playing:

```
version=1 channels=2 xformLength=1025 xformBits=16 bandwidth=22050.0 xformGain=2.0
  ch0: peakMax=-10.15882  peak=-14.84330  rms=-24.17408  rmsMax=-18.65369
  ch1: peakMax=-10.09222  peak=-16.54959  rms=-26.51343  rmsMax=-17.58654
```

Levels are already in **dB**. One frame is 65,792 bytes at these settings and
they arrive continuously, so anything reading this must be prepared to drop
frames rather than queue them.

**Nothing uses it today**, and it must not be pressed into the ReplayGain
calculation — see above. It is the obvious source for a level display if one is
ever wanted.

**Do NOT probe port 8019 to find any of this.** A bare `GET /` on hqplayerd's
UPnP port spins its log at ~68k lines/sec — `clUPnP::OnRequest():
clString::SubString(): uIdx >= sizeStr` — and cost 683,892 lines in ten seconds
once. Only `/root.xml` and SOAP paths are safe there. Probe **4321** (control)
and **8088** (log) and nothing else.

### NO FIGURE MEANS NO ATTRIBUTE — on every tier

**LMS gives nothing, we send nothing.** No `album_gain` at all: not a flat
`0.00`, not a computed unity. That covers a track with no ReplayGain data, a
non-numeric figure from a handler, and the user having replay gain switched
**off** in LMS (`fetchGainMode` returns undef for `replayGainMode = 0`).

**Why unity is not asserted.** `album_gain` OVERRIDES a local file's own tags,
so a 0.00 sent to mean "nothing to apply" silently disables HQPlayer's own
`playlist_album_gain` for a user who never asked LMS to do this. 0.2.39–0.2.48
asserted unity for streaming only and omitted for local, on the reasoning that
a CDN file has no tags for a 0.00 to override and that asserting stops anything
carrying over between playlist items. **That asymmetry is gone as of 0.2.49** —
Simon: *"all tiers operate the same"*. A carry-over between items has never
been observed; it was a theoretical worry, and it is not worth a rule that
behaves differently depending on where the track came from.

**A real figure of `0.00` dB is still sent.** That is LMS saying "this track is
already at target", which is not the same as saying nothing.

**So: one attribute, `album_gain`, on every tier, carrying LMS's figure
unaltered.** Shipped for streaming in 0.2.38; the ceiling in 0.2.39, the trim
in 0.2.41, the compensation and local tiers in 0.2.44, the local-omit
gate in 0.2.46 — and everything but the local tiers reverted in 0.2.49.

**The end-to-end shape to expect** (bridge log and hqplayerd's, on two clocks):

```
LMS       22:19:52  replay gain -8.23 -> -8.23 dB for file:///...
hqplayerd 22:19:49  Adaptive transport gain: -8.23 dB
hqplayerd 22:19:49  Set volume: -38.000000 +          <- unmoved, all session
```

The two figures match, and it lands as **adaptive** gain with the endpoint's
own volume untouched — which is the constraint: *"do not touch main volume as
this will move everosolos volume it must only be the adaptive volume"*.

## Icons: the plugin's own, and the Material player icon

Two different mechanisms, often confused.

**The plugin icon** is `install.xml`'s `<icon>`, pointing at
`plugins/HQPlayerBridge/html/images/HQPlayerBridgeIcon_svg.png`. The `_svg.png`
suffix is the whole signal: Material sees it and swaps in the sibling `.svg` so
it can recolour it per theme. Three files, the PFR convention:

| file | what |
|---|---|
| `HQPlayerBridgeIcon.png` | 256x256 RGBA, transparent ground |
| `HQPlayerBridgeIcon_svg.png` | a BYTE-IDENTICAL copy - the name is the marker |
| `HQPlayerBridgeIcon.svg` | the vector Material actually themes |

**The Material PLAYER icon** is chosen by `$client->model`, which this player
reports as `hqplayer`. It needs an entry in lms-material's
`html/misc/player-icons.json` plus `html/images/hqplayer.svg` - two files, in
THAT repo, nothing here. Staged in `docs/material-pr/`.

**The artwork is a single pulse-trace path**, hand-authored, the same file in
both places. Earlier designs (a traced Signalyst logo, a redrawn ECG-and-note, a
wordmark knocked out of a waveform) were all scrapped; their generators are
parked in `docs/material-pr/old-designs/` with a note on each. Nothing in the
shipped icon needs generating.

**The PNGs are rendered from the SVG**, and `qlmanage` FLATTENS ALPHA onto white
- so a thumbnail cannot be saved as the transparent PNG directly. The artwork is
pure `#000` on `#fff`, so alpha is recovered exactly as `255 - luminance` with
the RGB left at black. Render at 1024 and downsample to 256 for clean edges.

**The PNG is monochrome black.** Material never shows it (the `_svg.png` swap
themes the vector instead), and LMS's own skins are light-ground, so this is
safe - but it WOULD be near-invisible on a dark non-Material skin. The previous
icon was Signalyst's colour logo, which was not.

### AUTHOR MONOCHROME, AND KNOW WHAT THE RECOLOUR DOES

Material's `_svgHandler` rewrites the file as it serves it:

```perl
$svg =~ s/#000/$colour/g;
$svg =~ s/fill\s*=\s*"[#0-9a-fA-F\.]+"/fill="${colour}"/g;
$svg =~ s/stroke\s*=\s*"[#0-9a-fA-F\.]+"/stroke="${colour}"/g;
if (index($svg, "fill=\"")==-1) { $svg =~ s/\<path /\<path fill="${colour}" /g; }
```

So a two-colour logo cannot survive - it comes out flat whatever you do.
`fill="none"` and `fill-rule="evenodd"` DO survive, because the colour pattern
cannot match `none` and `fill-rule=` has a `-` where the pattern wants `=`.
Strokes are recoloured too, so a stroked path is a legitimate way to draw a thin
line rather than outlining it as a fill.

**SIMULATE THOSE FOUR LINES OVER ANY CANDIDATE BEFORE SHIPPING IT.** It is five
lines of perl and it is the whole contract. Every icon supplied for this plugin
has failed it in a way that is invisible in a local preview:

* **`fill="currentColor"` is NOT themed and BLOCKS the fallback.** It contains
  letters outside `[#0-9a-fA-F.]` so the substitution skips it - and its mere
  presence makes `index($svg,'fill="')` non-negative, so the bare-`<path>`
  injection never fires either. Served standalone, `currentColor` resolves to the
  document default: **black, in every theme.** Put `fill="#000"` on the path.
* **`fill="#FFF"` IS themed.** White knockout text is repainted in the theme
  colour and vanishes. Use a hole (`fill-rule="evenodd"`), not white ink.
* **One element's `fill=` can stop another being themed** - the injection is a
  whole-file check, so any `fill=` anywhere disables it for every bare `<path>`.

**Also check the namespace.** Three supplied files carried
`xmlns="http://w3.org"`, which is not the SVG namespace. It happens to render in
some viewers and is wrong; it must be `http://www.w3.org/2000/svg`.

**And check the ink actually fits.** `2..22` on both axes is the Material live
area. A stroked path extends half its `stroke-width` beyond its coordinates, and
an outlined ribbon extends by its half-width on top of that - both have clipped
silently here before.

## TRAP: `queued="1"` ON A MID-PLAYBACK APPEND KILLS THE DAEMON

**Isolated live 2026-08-28, engine 6.0.4, four controlled runs.** This is the
end-of-album crash, and it is not the album-gain setting.

| what | outcome |
|---|---|
| both items added **before** `Play`, `queued="0"` | plays through, **survives** |
| append **mid-playback**, `queued="0"` | plays through, **survives** (×2) |
| append **mid-playback**, `queued="1"` | end of playlist, **daemon exits** (×2) |
| same, playlist trimmed back to one item before the end | **daemon exits anyway** |

`queued="1"` leaves HQPlayer's own track index inconsistent, and at the end of
the **last** item the engine walks past it —
`clPlaylist::GetAlbumGain(): trackn > last`, unhandled out of
`clPlayerDaemon::Main()`, process gone. The control port then answers
`Connection refused` rather than resetting; on this install launchd brings it
back in ~7 s, which is why it reads as a link blip rather than a crash.

**Trimming the playlist first does not undo it**, so the damage is done at
append time, not at the end. That also rules out the workarounds worth trying:
a pre-emptive `<Stop/>` would have to truncate audio, and `<Play last="1"/>`
makes no difference (a one-item playlist survives either way).

**`queued="0"` appends identically and advances identically** — `tracks_total`
1 → 2, `track` 1 → 2 with no `state` 0 between tracks. It is what
`_appendTrack` sends. The whole feature, and the daemon lives.

This also revises the older note that the `GetAlbumGain` crash "no longer
happens". It happens, deterministically, and `playlist_album_gain="0"` is not
needed to avoid it — not sending `queued="1"` is.

## HQPlayer does not probe an http:// item for its duration

A bridge-added track came back from `<PlaylistGet/>` with `length="0"` — and
`rate`, `bits`, `channels` and `bitrate` all `0` too. HQPlayer accepts the URI
and plays it without reading a duration out of it, so its own UI showed no
length. The old UPnP path filled it in only because DIDL carries
`<res duration="">`.

**`<metadata length="…"/>` is accepted, in seconds.** Verified live:
`length="12.7"` reads back as `length="13"` on the playlist item and
`length="12.699"` on `<Status/>`. `_metadata` now sends it, guarded — a zero
duration is omitted rather than sent as `length="0"`, which is the bug it fixes.

## TRAP: THE CONTROL SOCKET CARRIES OCTETS, NOT CHARACTERS

**This one took the player out completely, and it is invisible on an
ASCII-only library.** Found live 2026-08-28 on *Orbital 2*.

LMS hands out track titles as Perl **character** strings. The album has a track
called `Lush 3‒1` — a **U+2012 FIGURE DASH**. That went into the
`<metadata song="..."/>` of a `PlaylistAdd`, and:

```
onStatus handler died: Wide character in syswrite at Control.pm line 299.
```

**The die is catastrophic, not cosmetic.** It threw out of the status handler
that was pumping the command queue, so the command stayed `inflight` **forever**
— and because exactly one command may be in flight at a time, *every*
subsequent command was queued behind it and never sent. Symptoms, none of which
point at encoding:

* **skip, stop and pause silently do nothing** — the player is deaf
* **LMS's position freezes while HQPlayer plays on**
* 30 s later, `no reply to <PlaylistAdd> after 30s` tears the link down
* on reconnect LMS floods the log with `HQPlayer would not accept the track URI`

The fix is one line, in `Control::_pump`: `wbuf` is a **byte** buffer, encoded
once with `Encode::encode('UTF-8', ...)` as the command is queued, and each
complete message is decoded back on the way in. HQPlayer was never the problem
— verified live, `song="Lush 3‒1"` round-trips byte-perfect through
`PlaylistAdd` + `PlaylistGet`.

**The quieter half of the same bug:** `_flush` does
`substr($wbuf, 0, $wrote, '')`, cutting by **character** while `syswrite`
counts **bytes**. A partial write of a non-ASCII command would have resumed
mid-character and corrupted the stream. Encoding once makes both agree.

Same family as the LMS characters-vs-octets trap: anything that reaches a
**socket, a database or a digest** needs bytes. `tools/t_control.pl` asserts
both directions.

## TRAP: a spurious hand-over is unrecoverable

The first cut of `_handedOver` fired on *"the playlist index changed **or** the
uri matches"*. Live, it declared the hand-over **0.2 s** after queueing the
track, while HQPlayer was still playing the previous one.

**That failure does not self-correct.** `hqURL` then names a track HQPlayer is
not playing and `hqPrevURL` names the one it **is**, so `_isStale` suppresses
*every* push from then on as "the previous track" — position frozen, LMS
showing the wrong track, no way out short of restarting the player.

Two changes, and both are needed:

* **The uri is a VETO, not a hint.** On tier 1 every track has its own url, so a
  push naming a url that is *not* the one we queued is positive evidence the
  hand-over has **not** happened, whatever the index says. The index is used
  alone only when the push carries no uri at all, and then only an **increase**
  counts — HQPlayer reports `track="0"` whenever it is not playing, so
  "changed" reads an ordinary stop as an advance. The append must also be
  **acknowledged** first.
* **The stale suppression is bounded** (`STALE_LIMIT`, 5). A track change
  straddles one or two pushes; it never legitimately straddles five. Past that,
  HQPlayer's account of what it is playing beats ours — adopt it, log a
  warning, carry on. A few seconds of wrong elapsed time is a far better
  failure than a player that has to be restarted.

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
carries no audio, whereas tier 4 below needs the real chunk pipeline.

## Track resolution — four live URL tiers (1, 3, 4, 5)

Everything is addressed **by URL, never by filesystem path**: HQPlayer's view of
the library mount will not match LMS's, and reconciling them would need exactly
the per-install configuration this plugin exists to avoid.

### CORRECTED: the "no query string, ever" rule was WRONG

**This section used to open "HQPlayer cannot fetch a URL containing a `?`" and
present it as the rule the whole tier structure was built around. It is false,
and it was disproven on the wire on 2026-08-28.**

Serving a FLAC from a throwaway `python3 -m http.server` on the HQPlayer box and
reading the request lines it actually sent:

```
"HEAD /test.flac?x=1 HTTP/1.1" 200
"GET  /test.flac?x=1 HTTP/1.1" 200      -> state=2, proc 3.17, position advancing

"HEAD /test.flac?uid=355122&eid=423471918&fmt=7&ts=...&hmac=abc123def" 200
"GET  /test.flac?uid=355122&eid=423471918&fmt=7&ts=...&hmac=abc123def" 200  -> plays
```

**Query strings are transmitted verbatim, `&`s and all, and the track plays.**

**Two things faked the original conclusion, and both are instructive:**

* **HQPlayer strips the query string everywhere it *reports* a URI.**
  `<Status/>` answered `uri="http://…:8899/test.flac"` while it was
  demonstrably fetching `?uid=…&hmac=…`, and all 89 `PlaylistAdd`s of
  `/stream.mp3?player=<mac>` appear in hqplayerd's log as a bare
  `.../stream.mp3`. Reading "the query string is gone" off those lines is the
  whole error. **Read the wire, not the daemon's rendering of it.**
* **The one probe that "confirmed" it was measuring LMS.**
  `/music/458773/download.flac?x=1` -> `GetHead(): 400` — but **LMS returns 400
  for ANY query string on that path**, reproducible with curl, including with a
  parameter it knows. It also proves the opposite of what was concluded: LMS
  could only answer 400 if it RECEIVED the query string.

Corroboration: `clControlInterface::playlistAdd` in Signalyst's own
`hqp-control-601-src` writes the URI through `writeAttribute` verbatim, and
HQPlayer Embedded streams Qobuz natively — HTTPS with signed query strings by
definition.

**So `/stream.mp3?player=<mac>` did not fail because of the URL.** The real
causes are the one-`streamingsocket`-per-player traps and the inherited
end-of-stream marker, both fixed in `Stream.pm`.

#### What DOES still constrain the URL

* **HQPlayer does not follow a 302.** Pointed at a server answering one, the
  HEAD arrived and no GET ever came. Independently verified and unaffected by
  the above. **The URL handed over must be the final one.**
* **HTTPS works** — `https://www.signalyst.com` returned a real `404` over TLS.
* **Content-Type, not filename**, picks the decoder — see tier 1 below.
* **Framing**: no chunked transfer encoding (the tier 3 trap below).

### The tiers

1. **Local track HQPlayer can decode** -> `/music/<trackid>/download.<ext>` —
   original file bytes, range-seekable, native DSD. Confirmed live end to end.

   **HQPlayer chooses its decoder by HTTP Content-Type, not by filename.**
   Verified the hard way — it refused a track with
   `clPlaylist::AddURI(): unknown mime type: audio/m4a` despite a sensible
   extension, then reported `Play(): Empty transport` because nothing had been
   added. Its mime table (from the binary) covers flac, wav, aiff, dsf/dff,
   wavpack, mpeg/mp3 and ogg, and has **no m4a, mp4, aac or alac entry at all**.
   So `%HQP_PLAYS` in `Player.pm` gates tier 1 by LMS content_type.

   The extension still matters for LMS's benefit: `downloadMusicFile` only
   transcodes when the resolved type differs from the track's own, so a truthful
   extension keeps it a byte-for-byte passthrough.

2. **Retired.** Tier 2 *was* `/stream.mp3?player=<mac>`. Its number is left
   unused rather than recycled, so an old log line still means what it said.
   **Note the retirement reason recorded at the time — the query string — was
   wrong**; see above. It failed on the socket traps.

3. **Local track in a format HQPlayer cannot decode** ->
   `/hqp3/<id>/download.<ext>`, LMS's own transcode with the request declared
   HTTP/1.0 so it is not chunked **and an explicit `200` on the response**.
   Pre-queueable, not seekable. This is the m4a/ALAC/AAC route, and both of
   those two lines are load-bearing — see the chunked-transcode and
   status-code traps below.

4. **Anything genuinely remote** (Qobuz, Tidal, Deezer, radio) ->
   `/hqp/<token>/<seq>.<ext>`, served by `Stream.pm` off LMS's player stream.
   Not pre-queued: one `streamingsocket` per player.

   **Only reached when tier 5 declines** — see below.

5. **A remote track LMS will stream directly** -> the service's OWN final URL,
   query string and all. See "Direct streaming" below.

### Direct streaming (tier 5): LMS hands us the service's own URL

`Slim::Player::Song::open` has always had this branch:

```perl
if ($transcoder->{command} eq '-' && ($directUrl = $client->canDirectStream($url, $self)) && (!$redir || $client->canHTTPS)) {
    $self->directstream(1);
    $self->streamUrl($directUrl);
```

`canDirectStream` is the **one uniform hook** for the resolved, signed CDN URL —
no per-service code. Our implementation is the same few lines as
`Slim::Player::Squeezebox2::canDirectStream`: ask the song's handler for
`canDirectStreamSong`, else `canDirectStream`.

`Player.pm` returned a flat `0` until 0.2.33, purely because of the
query-string rule above — which was wrong. With it returning a URL:

* `Song::open` sets `directstream(1)` and **opens no socket**. It still returns
  a `SongStreamController` (with an undef sock), so the controller proceeds
  normally and `play()` is called as usual.
* Nothing draws on `$client->chunks`, so **tier 4's one-stream-per-player limit
  does not apply** and a streaming track can be pre-queued like a local one.
  That is real gapless on Qobuz/Tidal, not the buffer-margin kind.
* No proxy hop and no transcode: HQPlayer fetches the service's bytes itself.

**THE GATING IS IN `canDirectStream`, NOT IN `_resolveURL`, AND THAT IS
STRUCTURAL.** Once `Song::open` has taken the direct branch there is no source
socket to fall back to, so anything we cannot serve must be refused *before*
LMS commits. Three refusals, all falling back to tier 4:

| refused | why |
|---|---|
| handler with `handlesStreamHeaders` | it expects the player to call `directHeaders` back with the response headers. A Squeezebox can — it makes the request. **We never see them**: HQPlayer fetches the URL. Radio and ICY metadata live here. |
| a URL that is not `http(s)://` | HQPlayer does not follow a 302, so the URL must be final |
| handler returning false/undef | nothing to stream directly |

LMS applies its own gates first — `$transcoder->{command} eq '-'` means this can
only fire when no transcoding is wanted, and the bitrate cap that would force
MP3 is already cleared by `initBitrateLimit`.

`canHTTPS` is now `1`. LMS only consults it when the URL redirects, but the
answer is genuinely yes: `https://www.signalyst.com` returned a real 404 over
TLS.

**VERIFIED LIVE 2026-08-30 on Qobuz.** `canDirectStream` returned the signed
Akamai URL, `_resolveURL` reported tier 5, the next track was pre-queued, and
the hand-over was clean:

```
canDirectStream: qobuz://193171335.flac -> https://streaming-qobuz-std.akamaized.net/file?uid=355122&eid=193171335&fmt=7&profile=raw
11:34:13  Playlist add URI: ...qobuz...      <- track
11:34:13  Playlist add URI: ...qobuz...      <- pre-queued
11:35:24  End of track at 71/71/0            <- tail exact
11:35:24  Next (0)                           <- no Playlist clear, no Play, no Idle request
```

Note the URL carries a query string with `&`s — the thing the retired rule above
said was impossible. **Streaming is now pre-queued gapless, not the
buffer-margin kind.**

**VERIFIED ACROSS ALL THREE SERVICES 2026-08-30 (0.2.35):**

| | tier | gapless | concurrent | seek |
|---|---|---|---|---|
| Qobuz | 5 direct | yes, pre-queued | yes | yes |
| Tidal | 5 direct | yes, pre-queued | yes | yes |
| Deezer | **4 fallback** | buffer-margin only | yes | yes |

**Deezer declines the hook** and falls back to tier 4 — the safety net working,
not a failure. Its gapless is therefore the `output_delay` margin, not a real
hand-over, so a sample-rate change WILL be audible there. Which of the three
gates it fails (no hook / `handlesStreamHeaders` / returns false) is not yet
established.

**The two services differ in where a track's identity lives, and it matters.**
Qobuz puts it in the QUERY STRING, Tidal in the PATH. Since HQPlayer strips the
query from every uri it reports, only Qobuz hit the hand-over bug — see the
Review Ledger row. Tidal would have worked either way.

**A SEEK ON TIER 5 DROPS TO TIER 4, AUTOMATICALLY AND CORRECTLY.** `canDirectStream`
is not even consulted: LMS will not take the direct branch when it has to open
the source at a byte offset, so it keeps the seek on its own stream and
`Stream.pm` serves it, with `_flacPrelude` synthesising the header a seeked FLAC
lacks. Verified on both Qobuz and Tidal. **Consequence: the track you seek into
is NOT pre-queued, so the boundary after a seek is buffer-margin rather than
true gapless.** It recovers on the following track.

**SCROBBLING AND PLAY COUNTS WORK ON TIER 5** — confirmed by Simon 2026-08-31,
*"scrobbles have been working fine"*. They were expected to be at risk because
they normally ride the stream socket and direct streaming removes it; they do
not depend on it. Do not re-raise this as an open question.

**STILL UNVERIFIED:** signed-URL expiry, since pre-queuing hands the url over a
whole track early.

### TRAP: a transcode is served CHUNKED, and HQPlayer does not de-chunk

`/music/<id>/download.<ext>` is a fine URL for a **native** file and a trap for
a **transcoded** one. A transcode has no known length, so LMS cannot send a
`Content-Length` and falls back to `Transfer-Encoding: chunked`:

| | tier 1, native file | tier 3, transcoded |
|---|---|---|
| framing | `Content-Length: 24851636` | `Transfer-Encoding: chunked` |

**HQPlayer does not de-chunk.** It reads the chunk-size lines as audio, and its
decoder tears itself apart on them:

```
ReadFLACErrorCB(): lost sync
ReadFLACErrorCB(): unparseable stream
ReadFLACErrorCB(): CRC error
```

Reported 2026-08-28 as garbled mp4 playback, and it had been shipping since
tier 3 was written.

**Two things make this genuinely hard to catch, and both fooled this repo once
already:**

* **The file is perfect.** Fetched with `curl` — which de-chunks silently — the
  transcode is a valid FLAC: right rate, right duration, and a **0.9998**
  loudness-envelope correlation against the original m4a. Analysing the
  downloaded file proves nothing about what HQPlayer receives off the socket.
* **`state`, `process_speed` and `input_fill` all look healthy** while every
  frame fails to decode. Tier 3 was called "verified" on exactly those three
  numbers (`proc=3.298 in_fill=0.73`). They do not mean the audio is right.
  **Only hqplayerd's own log says so** — see `:8088/log`, and the standing rule
  under "Verified working": never conclude playback works from `state` alone.

**THE CHUNKING IS ONE `if`, AND IT IS DRIVEN BY THE REQUEST'S HTTP VERSION.**
From LMS's own `Slim::Web::HTTP::downloadMusicFile`:

```perl
my $is11 = $response->request->protocol eq 'HTTP/1.1';
if ($is11) {
    # Use chunked TE for HTTP/1.1 clients
    $response->header( 'Transfer-Encoding' => 'chunked' );
}
```

`$is11` is what **every** write in its non-blocking writer then branches on:
false means raw bytes and close-at-EOF — the same framing tier 4 hand-rolls, and
the framing HQPlayer wants. Confirmed against the live server 2026-08-30: the
same URL over HTTP/1.0 answers with no `Transfer-Encoding` and a valid body;
over HTTP/1.1 it chunks. HQPlayer asks in 1.1, which is why it broke.

So **tier 3 has its own route, `/hqp3/<id>/download.<ext>`**, which declares the
request `HTTP/1.0` and delegates straight to `downloadMusicFile`. LMS does the
transcode and the non-blocking write; we change one field.

**0.2.31 solved the framing a different way and it cost gapless.** It routed
tier 3 through the tier 4 player-stream endpoint. That endpoint *is* the player
stream: it draws on `$client->chunks`, there is one per player, and `_handler`
closes any previous connection outright — so a pre-queued second track would
fight the one playing. Local non-FLAC went from gapless to a full reload at
every track boundary, which is how it was reported (2026-08-29). Restored in
0.2.32: every `/hqp3/` request is an independent transcode of a numbered track,
so two can be open at once and **tier 3 is pre-queued exactly like tier 1**.

Still **not seekable** — a transcode has no length, so LMS answers
`Accept-Ranges: none` and `_queueTrack` sends no `<Seek>` for this tier.

### TRAP: a raw function must set its OWN status code, or the line goes out blank

**This broke every m4a, ALAC and AAC track from 0.2.32 to 0.2.45**, and it
shipped in the very build that fixed the chunking above. Reported by Simon,
2026-08-30: *"Apple lossless alac and aac all in m4a wrapper do not play"*.

A raw socket request to `/hqp3/…` answered with a status line of literally:

```
HTTP/1.1  
```

Protocol, two spaces, **no status code**. LMS builds it as

```perl
sprintf( "%s %s %s", $response->protocol(), $code, HTTP::Status::status_message($code) || "", $CRLF )
```

and `$code` was empty. **HQPlayer said so precisely and it was misread as a
codec problem for two days:**

```
clPlaylist::AddURI("http://…/hqp3/470893/download.flac"):
  clStreamReaderHTTP::clStreamReaderHTTP(): clString::ToUInt(): not an integer ''
```

That is HQPlayer parsing the **response code**, not the audio.

**Why it happens:** a raw function is handed the response object almost
unmodified — LMS's own dispatcher comment is `$rawFunc shall call
addHTTPResponse` — and setting the code is part of that. `downloadMusicFile`
sets one only on its ERROR paths (406, 400), never on success. `_handler`
(tier 4) sets `$response->code(200)` and `_fail` sets one, **which is exactly
why tier 4 and our 404s worked throughout while every tier 3 download did not.**

**Why the offline suite could not see it:** it stubs `downloadMusicFile` and
never opens a socket, so nothing was looking at the response object at all.
`t_stream.pl` now asserts the code on the object itself.

Note the HTTP/1.0 declaration above is unrelated and still required — both were
needed and only one was there.

### Tier 4: the plugin's own audio endpoint (`Stream.pm`)

**There is no proxying and no second HTTP request.** The handler hands the
socket to LMS's own player-streaming machinery — which is exactly what
`/stream.mp3` does. Registered with `Slim::Web::Pages->addRawFunction`, whose
`%rawFunctions` is tied to `Tie::RegexpHash`, so a key registered as a regex
matches by path.

A raw function is called as `($httpClient, $response)` from the top of
`processHTTP`, **before `processURL`** — so nothing has guessed at a client for
us and nothing runs after we return. The whole handover is five lines lifted
from LMS's own `stream.mp3` branch:

```perl
$Slim::Web::HTTP::peerclient{$httpClient} = $client->id;
delete $Slim::Web::HTTP::keepAlives{$httpClient};
Slim::Utils::Timers::killTimers( $httpClient, \&Slim::Web::HTTP::closeHTTPSocket );
my $headers = Slim::Web::HTTP::_stringifyHeaders($response) . CRLF;
$Slim::Web::HTTP::metaDataBytes{$httpClient} = -length($headers);
Slim::Web::HTTP::addStreamingResponse( $httpClient, $headers );
```

`%peerclient` is the load-bearing line: `addStreamingResponse` reads it to find
the player to attach the socket to, and without it the connection is adopted as
an orphan and closed on the first pass through `sendStreamingResponse`. All
four of those variables are `our` in LMS 9.1 — `t_stream.pl` asserts against
stubs carrying the same names, so a rename upstream fails a test rather than
silently killing the endpoint.

**Answer the HEAD, but do not hand it the socket.** HQPlayer HEADs before it
GETs. Attaching the player's stream to a HEAD would pour the track into a
connection that is about to be closed and leave the real GET with nothing.

**Content-Type is read at serve time, not mint time** — from
`songStreamController->song->streamformat`. The transcode table and the bitrate
cap both get a say after the URL has been handed over, and HQPlayer picks its
decoder by Content-Type and ignores the extension entirely.

**The token is the player id with `:` → `-`**, resolved by scanning the client
list rather than by a registry, so there is nothing to get out of step with the
players that exist. `<seq>` makes each track's URL unique, which is what stops
HQPlayer treating a repeat of the same URL as the item it is already holding.

**Tier 4 is NOT pre-queued for gapless, and its unique URLs are not enough to
change that.** A client has one `streamingsocket` and one
`songStreamController`. Appending would have LMS resolve and *open* the next
song's source now, replacing the controller feeding bytes down the socket
HQPlayer is still pulling — so the rest of the playing track would arrive as
the beginning of the next one. A real Squeezebox survives this because it
buffers a whole track ahead of itself; HQPlayer pulls progressively. So a tier 4
next track is **held** and loaded when the current one ends, which is what
`_armNextTrack` already arranges.

### TRAP: declaring `flc` first does not get you FLAC

`Slim::Utils::Prefs::maxRate` applies a bitrate cap whenever the `maxBitrate`
client pref **has never been set**, and the default is by player family: wired
Squeezeboxen and all SB2s get `0` (no limit), and **every other player gets
320kbps**. This player is deliberately not a Squeezebox, so it lands in "every
other player" — and LMS transcodes to MP3 to fit under the cap.

The effect, found 2026-08-28 after a user reported HQPlayer showing MP3: a
750kbps Qobuz FLAC arrived as MP3 320, and every tag the original carried —
replaygain included — was destroyed on the way. `formats()` listing `flc` first
made no difference at all; the cap is applied downstream of the preference
order.

**Verified on the live server, same endpoint, same player, pref the only
change:**

| `maxBitrate` | what `/stream.mp3?player=` serves |
|---|---|
| unset (LMS default → 320) | MP3 |
| `0` | `Content-Type: audio/x-flac`, body opens `fLaC` + STREAMINFO |

So `Player::initBitrateLimit` sets it to `0` at player creation, **only when it
is undef** — an explicit choice belongs to the user, and undef is exactly LMS's
own "not been set yet". `Plugin::_create` calls it after `init`, because the
client's prefs have to exist before an unset cap can be told from a chosen one.

**Tier 1 was never affected**, which is why this hid for so long: a plain file
download does not go through the streaming path and never meets the cap. Local
playback always sounded right; only streaming was quietly downgraded.

philippe_44's bridges (CastBridge, UPnPBridge) never hit this — their players
connect over slimproto, so LMS builds them as `Squeezebox2` subclasses and the
default hands them no limit for free. Comparing player prefs across the three
is what identified it: two bridge players both showing `maxBitrate` unset, but
only ours resolving to a cap.

## State machine

`<Status/>` is a subscribe (see above), so `Player::_onStatus` runs on each
pushed message and maps it onto the controller callbacks:

| HQPlayer | LMS |
|---|---|
| `state` → 2, first time **for an acknowledged track** | `playerTrackStarted`, then `playerReadyToStream` (the request for the next track — see Gapless) |
| `track` moves on with something pre-queued | `playerTrackStarted`, then `playerReadyToStream` |
| position advancing | `playerStatusHeartbeat` |
| `state` 2 → 0, not ours, nothing held | `playerEndOfStream` + `playerReadyToStream` + `playerStopped` |
| `state` 2 → 0, not ours, a tier 4 track held | nothing — the held track is loaded instead |
| command rejected **on a full load** | `playerStreamingFailed('PROBLEM_OPENING')` |
| Play acked but `state` never reaches 2 within `START_DEADLINE` | `playerStreamingFailed('PROBLEM_OPENING')`, once |

### The start deadline: an ack is not a start (0.2.50)

**`hqPlayAck` and `hqStarted` are two different facts, and the gap between them
was unmonitored.** The ack means HQPlayer *accepted* `<Play/>`; `hqStarted` only
latches when a pushed `<Status/>` reports state 2. Everything downstream is gated
on `hqStarted` — `_endOfStream` opens `return unless $self->hqStarted` — so an
ack that never became playback reported **nothing to anybody, for ever**: LMS
stranded in `mode=play` with a frozen clock, and the Eversolo's screen lit
indefinitely. That is the state every tier 4 bug fixed in 0.2.27 produced. The
causes were fixed; the gap was carried as an open ledger row for three days.

**A retry loop used to cover the ack never ARRIVING** (~17s over 8 attempts, on
the UPnP path, removed with it in 0.2.54 — `<Play/>` on the control socket is
chained off `PlaylistAdd`'s reply and has never needed one). `START_DEADLINE`
covers the opposite case, which is the one that actually strands LMS: the ack
arrives, and nothing happens after it.

`START_DEADLINE` is **10 seconds** — roughly 4x the worst legitimate delay. A
track normally reports playing in ~0.33s; the slowest known real case is a
sample-rate change forcing an engine reinit at ~2.3s.

**Armed** in `_queueTrack`, immediately after the Play ack sets `hqPlayAck`, with
the load's generation. **Cancelled** in three places: the `hqStarted(1)` latch in
`_onStatus` (the success path), `stop()`, and `_newGeneration`.

**THREE THINGS IT MUST NOT FAIL, and each is a test:**

* **A superseded load.** Track one's deadline firing while track two is loading
  would skip a perfectly healthy track. The generation check is the authority;
  the timer is killed on those paths too.
* **A track paused inside the window.** LMS can pause a track that has not
  started yet, and HQPlayer will then correctly never report playing. Guarded on
  `hqWanted eq 'play'` — only a load still being *waited on* has failed.
* **A track that started.** The cancel at the latch handles it; `_startDeadline`
  re-checks `hqStarted` anyway. Deliberate belt and braces — and note the
  behavioural tests cannot catch a missing cancel *because* of that guard, which
  is why there is a source-level assertion that the latch cancels.

**It reports ONCE and does not reschedule.** The 0.2.13 lesson is a failure
reported per track in ~100ms racing an entire album; one report per load, a
deadline apart, is the opposite shape — but only as long as it does not repeat
itself, which is asserted.

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
  normalised uri, no metadata child, or a uri HQPlayer never echoed back — is treated as current, so this can only ever suppress
  a push positively identified as the previous track's. It can never wedge
  playback. Volume is still followed from a stale push; it belongs to the
  instance, not the track.

### TRAP: an async load outlives the track that started it

A stop or a skip during the load window used to leave the *previous* track's
completion callback to fire anyway — re-asserting `bufferReady`, restarting the
poll, and applying that track's `<Seek>` and `hqSeekOffset` to whatever is
playing now, so elapsed time was wrong for the whole track.

`play()` and `stop()` both call `_newGeneration`: it bumps `hqGen`, which every
in-flight callback compares itself against (`_superseded`). Until 0.2.54 it also
called `UPnP::cancelPlay` to bump an epoch the UPnP Play retry loop checked —
that loop was a *timer*, so it needed cancelling separately from the callback.
With UPnP gone there is no timer in the load path and the generation bump is the
whole mechanism.

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

### TRAP: songElapsedSeconds is stream-relative, and the tiers differ

`playingSongElapsed` computes `startOffset + songElapsedSeconds`. LMS adds the
offset itself, so what we report must be elapsed **within the stream we were
handed**, never absolute position in the track.

The tiers put the offset in different places:

| | who applies the seek | HQPlayer's `position` |
|---|---|---|
| tier 1 (`/music/<id>/download.ext`) | us, via `<Seek>` — LMS is not in the byte path | absolute in the file |
| tier 4 (`/hqp/<token>/<seq>.<ext>`) | LMS, when it opens the source (`canDirectStream` is 0) | relative, starts at 0 |
| tier 3 (`/hqp/…`, a transcode) | LMS, as tier 4 — same endpoint, same rules | relative, starts at 0 |

So `<Seek>` goes out on tier 1 only — sending it on tier 4 skips a second time
and lands at twice the offset, and tier 3 cannot honour it at all — and `songElapsedSeconds` subtracts
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

**Where they come from.** `<VolumeRange/>` on the control socket, asked once per
link-up by `Player::refreshVolumeRange` (off `refreshInfo`). VERIFIED live
2026-08-28 and again 2026-09-05 against hqplayerd 6.0.4:

```
<VolumeRange/>  ->  <VolumeRange adaptive="1" enabled="1" max="0" min="-100"/>
```

**`min` and `max` are PLAIN dB and are stored verbatim.** Only those two are
read: see the Review Ledger for why `enabled` is not a fixed-volume flag.

*Historical, for anyone reading an old build:* until 0.2.54 this came from UPnP
RenderingControl's `GetVolumeDBRange` on port 8019, which answered
`<MinValue>-25600</MinValue><MaxValue>0</MaxValue>` — the AV spec's **1/256 dB**
units, needing an `abs(v) > 200` discriminator to tell them from whole dB, and
costing a 300–550 ms SOAP round trip. **None of that came across**, and it must
not: it was that transport's unit, not this one's. hqplayerd's own log agrees
with the control API, printing `Volume max: 0` / `Volume min: -100` and
`Control active volume range: -100 - 0 dB`.

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

### An endpoint re-registering announces its own level, LOUDLY — and we follow it anyway

When a network endpoint drops and comes back, HQPlayer re-splits the level
between the endpoint's hardware volume and its own software attenuator, and the
endpoint announces whatever level it had stored. That arrives on exactly the
same channel as the endpoint's own remote, so `_followVolume` reads it as the
user's intent and moves the slider to match.

LIVE 2026-08-28, an Eversolo NAA re-registering, two pushes 600ms apart:

```
volume changed outside LMS to -39dB - following
volume changed outside LMS to -18dB - following      <- +21dB
```

and at the same moment hqplayerd's own log shows the split going from
`hardware: 0  software: -27` to `hardware: -43  software: -4`. Nothing had
asked for any of it. It was very loud.

**0.2.31 added a guard for this. 0.2.32 removed it, and the removal is the
current behaviour: a level that arrives from the endpoint is ALWAYS followed.**

The guard refused an increase beyond 3 dB inside a 10-second settling window and
re-asserted LMS's own level to pull the endpoint back down. Its problem was the
trigger. Two things armed it: `refreshInfo` on a control link-up, and
`transport_serial` on `<Status/>` — and **`transport_serial` turns over at every
track boundary**, not just on a re-registration. Measured across one album,
2026-08-29:

```
23:21:29  output transport reinitialised (4 -> 5)
23:25:05  output transport reinitialised (5 -> 6)
23:28:45  output transport reinitialised (6 -> 7)
23:33:12  output transport reinitialised (7 -> 8)
23:35:38  output transport reinitialised (8 -> 9)
```

One per track. So the guard was armed for ten seconds after every track change,
and inside that window it refused and pulled back **the user's own volume
changes**, made on the endpoint's own remote. Reported 2026-08-29 and removed at
Simon's call: a control that second-guesses the person holding the remote is
worse than the noise it was protecting against.

**If this is ever revisited, the trigger is the hard part, not the response.**
It needs a signal that means "the endpoint re-registered" and nothing else.
`transport_serial` is not that signal. Note the +21 dB event is also visible in
hqplayerd's log as the hardware/software split changing — but that is only in
its log, not on the control API.

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
tree, runs 622 assertions across five files, and sweeps called-vs-defined subs.

| file | covers |
|---|---|
| `t_control.pl` | XML framing, attribute parsing, escaping, **real captured hqplayerd payloads** |
| `t_player.pl` | player construction, `<metadata>`/artwork, the controller handshake, seek accounting, two-way transport, volume, **track changes and fade duration** |
| `t_stream.pl` | the tier 4 endpoint: path-only urls, the socket handover, the stale-connection and end-of-stream-marker traps, **the synthesised FLAC header** |
| `t_plugin.pl` | player identity across a DHCP move and duplicate names, version drift |
| `t_live.pl` | the standalone live page: **the status code on the response object**, that the document owes nothing to the skin, and that the poller never stops itself |

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
* **The 0.2.9 volume path, on the live LMS** — 2026-08-27, read out of
  `log.txt` and a JSON-RPC `status` while the bridge was running: at every
  link-up `UPnP GetVolumeDBRange ok` → `volume range -100dB to 0dB` →
  `HQPlayer volume range is -100dB to 0dB (1.00dB per LMS step)`; the inbound
  mirror followed the endpoint's own remote (`volume changed outside LMS to
  -39dB / -51dB - following`); `status` reported `"mixer volume": 61` against
  −39 dB, which is the mapping agreeing with HQPlayer's own 0-100 scale, with
  `digital_volume_control: 1` and `use_volume_control: 1` — so fixed-volume
  detection correctly stayed off on a variable instance.

* **`<VolumeRange/>` on the control API** — 2026-08-28:
  `<VolumeRange adaptive="1" enabled="1" max="0" min="-100"/>`. Same range UPnP
  reports, in plain dB, on the socket already open.
* **`<Status subscribe="0"/>` is a one-shot poll** — 2026-08-28: one reply and
  no push stream, against `subscribe="1"` (and the bare `<Status/>`) which
  subscribes.
* **`<metadata length="…"/>` is accepted, in seconds** — 2026-08-28:
  `length="12.7"` reads back `length="13"` on the playlist item and
  `length="12.699"` on `<Status/>`. Without it HQPlayer shows no duration at
  all for an http:// item.
* **Non-ASCII metadata survives the wire as UTF-8 octets** — 2026-08-28:
  `song="Lush 3‒1"` (U+2012 FIGURE DASH) written with `PlaylistAdd` and read
  back byte-identical with `PlaylistGet`. HQPlayer was never the problem; the
  plugin was sending characters.
* **Gapless, end to end on the protocol** — 2026-08-28, two tracks of 12.7 s
  and 17.9 s: `tracks_total` 1 → 2 on the append, `track` 1 → 2 at 12.5 s with
  **no `state` 0 between the tracks**, clean `state` 0 at the end of the last
  item, daemon alive. See "Gapless".
* **`queued="1"` kills the daemon and `queued="0"` does not** — 2026-08-28,
  four controlled runs. See the trap section above.
* **`<PlayNextURI>` kills the daemon** — 2026-08-28. See "Gapless".
* **TIER 4 END TO END, and the whole transport swept** — 2026-08-28 on 0.2.27,
  driven from a real LMS queue against the live daemon:

  | | play | seek | skip | pause/resume | track change |
  |---|---|---|---|---|---|
  | tier 1 (local FLAC) | ok | **ok** | ok | ok | ok, gapless |
  | tier 3 (local ALAC/MP4) | see below | n/a | ok | ok | ok |
  | tier 4 (Qobuz) | ok | **ok** | ok | ok | ok, and gapless in practice |

  Qobuz arrives as 24/96 FLAC (`process_speed` 3.1-3.2, `input_fill` 0.8-0.94)
  and is upsampled to DSD256. Tier 1 seek had been unverified since the player
  was written; it works.

  **CORRECTION, and the reason this table is dangerous.** The tier 3 row above
  was `ok` for TRANSPORT and the audio was GARBLED the entire time - the
  chunked-transcode trap. Every number this sweep looked at (`state`,
  `process_speed`, `input_fill`, position advancing) was healthy while
  HQPlayer's FLAC decoder failed on every frame. Nothing in LMS or in the
  control API said a word. **A transport sweep is not a playback test.** Read
  hqplayerd's log at `:8088/log` for `ReadFLACErrorCB` before writing `ok` in a
  table like this one.
* **Gapless END TO END through the plugin** — 2026-08-28, driven from a real
  LMS queue on 0.2.20-0.2.21. Three album boundaries seamless; skip x3 clean;
  a playlist edit mid-hand-over (`flush()` -> `<PlaylistClear/>` -> re-arm)
  kept the playing track and re-armed correctly. A **sample-rate change** costs
  ~2.3 s while HQPlayer retunes the output - physics, not a bug; it correlated
  exactly with 96k -> 44.1k and never appeared within a fixed-rate album.
* **HQPlayer does not follow a 302** — 2026-08-28. The other half of this
  bullet, "cannot fetch a URL containing `?`", was **disproven** on the wire
  2026-08-30: query strings go over verbatim and the track plays. See the
  ledger and "Track resolution".
* **Tier 3 (transcode-on-download) renders** — 2026-08-28: an m4a requested as
  `/music/<id>/download.flac` answers `Content-Type: audio/x-flac`, body opens
  `fLaC`, HQPlayer plays it (`state=2 pos=3.526 proc=3.298 in_fill=0.73`).
  `Accept-Ranges: none`, so no `<Seek>` on this tier. **This bullet was true of
  the BYTES and false of playback twice over** — first the chunking, then the
  missing status code. Both are fixed; see the traps.
* **Tier 3 plays m4a end to end, with ReplayGain** — 2026-08-30 on 0.2.45, a
  tagged AAC album from a real LMS queue: `PlaylistGet` shows the queued items
  as `mime="audio/x-flac"`, playback advances, and the gain the bridge computed
  (`-8.23 -> -5.22 dB`, headroom −3.01, `peak 0.985198`) arrives at hqplayerd as
  `Adaptive transport gain: -5.22 dB (0.548277)` with `Set volume` unmoved.
  **On 0.2.49 the same track would send `-8.23`** — the compensation that made
  this −5.22 is gone. What this bullet still proves is that the figure reaches
  hqplayerd on tier 3 at all, and that `Set volume` stays put.
* **TIER 3 IS GAPLESS ACROSS A TRACK BOUNDARY, AAC and ALAC** — 2026-08-30,
  reported by Simon and matched in hqplayerd's log. The signature is exactly the
  one this file predicted: an add with **no `Playlist clear` and no `Play`**.

  ```
  22:39:33  Playlist clear
  22:39:33  Playlist add URI: .../hqp3/473567/download.flac    <- load
  22:39:33  Playlist add URI: .../hqp3/473568/download.flac    <- armed
  22:44:35  Adaptive transport gain: -5.22 dB
  22:44:36  Playlist add URI: .../hqp3/473569/download.flac    <- HAND-OVER, no clear
  ```

  302 s track, boundary at 22:44:35 — to the second. So both "still unverified"
  bullets that used to sit here are closed, and `_armNextTrack` genuinely does
  keep two `/hqp3/` transcodes open at once.
* **NOT VERIFIED, AND THE ENTRY THAT USED TO SIT HERE WAS WRONG.** A
  `Adaptive transport gain: 3.01 dB (1.41416)` was recorded here as the
  positive-gain trim firing. **It was the no-figure bug** (see the ledger):
  +3.01 is what BOTH paths produce with a −3.01 headroom, and the LMS log line
  that would have separated them — `replay gain none` vs `replay gain 6.68` —
  was not checked. **The trim was never once seen fire live, over five builds,
  and it is now deleted.** Lesson:
  when two code paths produce the same number, the daemon's log cannot tell you
  which one ran; go to the line that carries the input.
* **hqplayerd confirms the switch we depend on** — `Playlist uses album gain`
  in its log, i.e. `playlist_album_gain="1"`. If `album_gain` ever stops
  working, that line is the first thing to look for.

**Watch for a silent output-format mismatch.** When HQPlayer's output format
exceeds what the endpoint accepts, it reports `state=2` and returns OK to
everything while rendering nothing. The only evidence is `process_speed=0` /
`output_fill=0`, and in the log:

```
% NAA output requested format not available!
! NAA output clNetEngine::PushPCM(): engine not ready
```

Never conclude "playback works" from `state` alone.

## TRAP: racing tracks mean hqplayerd is dying, not the bridge

The symptom is "it is not streaming at all": LMS tears through the whole
playlist in a couple of seconds and lands on stopped. In `log.txt` each track
reads

```
buffer ready [playing=PLAYING streaming=STREAMING]
HQPlayer is playing
end of track            <- ~180ms later
tier 4 (plugin stream endpoint) http://.../hqp/02-ab-88-42-4c-69/7.flac
```

That is the state machine working correctly on a daemon that keeps exiting: the
engine stops under us, `state` goes to 0, and 0 is also how end-of-track
presents, so LMS advances — over and over.

**ROOT CAUSE, verified 2026-08-27 from hqplayerd's own log** (`/tmp/hqplayerd.log`
on the HQPlayer host; on a Mac instance `lsof -p <pid> | grep '\.log'` finds it):

```
End of track at 0.008/195/194.992
Next  (0)
! clHQPlayerEngine::Execute(): clHQPlayerEngine::NextNL(): clPlaylist::GetAlbumGain(): trackn > last
  Stop request (reset)
! clPlayerDaemon::Main(): clHQPlayerEngine::Stop(): clPlaylist::GetAlbumGain(): trackn > last
- Server stopping...
```

`clPlaylist::GetAlbumGain()` throws `trackn > last` when the playlist index has
run past the end, and in `clPlayerDaemon::Main()` that throw is **unhandled and
takes the process down**. It is an HQPlayer defect: no control input should be
able to kill the daemon.

**Two things reach it, and both are ordinary:**

* **End of track.** HQPlayer auto-advances (`Next (0)`) when a track finishes.
  The bridge fed it exactly one URI at a time, so *every* track end was an
  end-of-playlist and every one of them called `GetAlbumGain` past the end.
  (Since gapless the playlist holds up to two items, so this is reached once per
  run rather than once per track — see "Gapless" below.)
* **Stop.** `clHQPlayerEngine::Stop()` takes the same path, which is why
  pressing Stop in HQPlayer's own UI crashes it, with no LMS involved at all.

**The switch that disarms it** is `playlist_album_gain` in
`~/.hqplayer/hqplayerd.xml` (the album-gain / playlist volume-levelling option
in the web UI). At `1`, `GetAlbumGain` is consulted on every advance and stop;
at `0` it is not called and the throw cannot happen. Nothing in the bridge
changes this — it is the user's setting.

**Same defect, harmless elsewhere.** With an empty playlist a `<Volume>` command
returns the identical error through `clControlThread::ParseMsg()`, where it is
caught and merely answered as `result="Error"` — the level still applies. That
is the `%BENIGN` entry in `Control.pm`. Do not confuse the two: caught in the
control path, fatal in the daemon's main loop.

**A spurious end-of-track makes it fire immediately.** On a transcoded stream the log shows
`MP3 stream format changed` then `End of track at 0.008/195/194.992` — HQPlayer
read LMS's `/stream.mp3` as ending 8ms in, advanced, and died. So a tier-2
track can crash the daemon at the *start* rather than the end.

**Diagnosing it from the LMS side**, since the player still *looks* connected
(`Player::connected` returns `tcpsock`, a literal 1):

1. `control link down - connect: Connection refused`, then again on the 2/4/8/16s
   backoff. Refused is not "HQPlayer closed the link" — nothing is listening.
2. `<Play> failed: ... Empty transport` — the engine is up but has no playlist.
3. Port 4321 flapping. From any machine on the subnet, no shell on the host:

```
python3 -c 'import socket,time
for i in range(30):
    r=[]
    for p in (4321,8019):
        try: socket.create_connection(("<hqplayer-ip>",p),1).close(); r.append("up")
        except Exception: r.append("DOWN")
    print(time.strftime("%H:%M:%S"), r, flush=True); time.sleep(1)'
```

A daemon that answers `GetInfo` one second and refuses the next is exiting and
being restarted. The bridge has nothing to fix here: it reconnects on its own,
and did.

**Do not read the requested output rate as the cause.** `Requested output rate:
12288000` against an endpoint that lists only 44.1-family DSD rates looks like
[hqplayerd-naa-format-mismatch], but the NAA reconciles it — the next lines are
`NAA output network format: 11289600/1/2 [sdm]` and `engine started at:
11289600`. That mismatch is a *silence* symptom, not a crash symptom.

## Repeat must be OFF — and why it was briefly ON

`Player::assertRepeatOff` sends `<SetRepeat value="0"/>` at every link-up.

For one build it sent `value="1"`. That was an attempt to stop HQPlayer walking
off the end of a one-entry playlist — it advances by itself at the end of a
track, and the overrun throws out of `clPlayerDaemon::Main()` and kills the
daemon ([hqplayerd-album-gain-crash]). Repeat does make the advance wrap. It
also means **the playlist never ends**, so `state` never reaches 0,
`_onStatus` never reports end-of-track, and LMS never sends the next track: a
full LMS queue played its **first track on repeat, forever**.

That section of this file asked exactly the right question — *"with repeat on,
does HQPlayer still report `state` 0 at end of track, or loop at 2?"* — and the
guard shipped without answering it. **It loops.** Answer the question before
shipping the workaround, not after.

**Verified live 2026-08-28**, engine 6.0.4, repeat off, a complete 13.5 s track
played to its natural end:

```
t=6s   state="2" position="11.6"
t=8s   state="0" position="0"     <- clean end, daemon ALIVE
t=10s  state="2" position="0"     <- LMS sent the next track by itself
```

No crash. The overrun needed the **two-channel load**: Stop on the control
socket racing a UPnP `SetAVTransportURI` emptied the engine's playlist
underneath a renderer that still believed it was playing, and that is what
walked `trackn` past `last`. On one ordered socket the playlist and the engine
never disagree.

If `GetAlbumGain(): trackn > last` is ever seen again, the fallback is the
user-side switch — `playlist_album_gain="0"` in `~/.hqplayer/hqplayerd.xml` —
**not** repeat. Repeat trades a crash for a player that cannot advance.

**Pre-queueing is now built** — see "Gapless" below. The objection recorded
here, that a playlist HQPlayer can advance into on its own stops reporting
`state` 0 at end of track, was right and is answered rather than dodged: the
transition is read off the playlist index instead, and `state` 0 now means end
of *playlist*, which is what the end-of-stream path always wanted it to mean.
The tier 4 objection stands unchanged and is why tier 4 is excluded.

## SETTLED: the API is free to use, and the licensing is not a grey area

Researched 2026-09-02, before release. **Do not re-litigate this.**

**Signalyst publish their own reference client for this API under the MIT
licence.** `hqp-control-601-src/COPYING` is the verbatim MIT text, © 2011–2026
Jussi Laako. MIT grants use, copy, modify, merge, publish, distribute,
sublicense and sell. A vendor licensing their reference client this way is not
reserving the protocol.

Corroborating, all checked:

* Signalyst's HQPlayer Embedded page offers the Control API for "implementing a
  custom GUI or other type of front-end utilizing the HQPlayer playback engine"
  — third-party front-ends are the STATED purpose.
* Third-party clients are established and public: HQPWV (GPL-3.0, GitHub),
  HQPDcontrol (App Store), Roon and JPLAY drive the same surface.
* **There is no EULA or API terms page on signalyst.com** — `/terms`, `/eula`
  and `/licence` all 404; the privacy and delivery policies cover neither the
  API nor development.

**THE ONE MIT OBLIGATION IS ALREADY MET.** The notice must travel with any copy,
and this repo does redistribute the vendor source — `COPYING` is present in
`hqp-control-601-src/`. **The shipped plugin zip contains none of it**
(verified: zero matches), so the released
artefact carries no vendor code at all. Our own `LICENSE` is MIT too, so there
is no compatibility question either.

**WHAT IS *NOT* SETTLED BY ANY OF THAT IS TRADEMARK.** MIT covers the code and
says nothing about the marks. "HQPlayer" and "Signalyst" are trademarks, used
here nominatively — in the plugin name, the icon, and the Material PR. That is
normal practice (Material already ships Ubuntu, Windows, Chrome and Bandcamp
marks for the same reason) but it is a judgement call, not a licence grant.
README.md carries the disclaimer: not affiliated, not endorsed, marks belong to
their owner, protocol implemented with reference to the MIT-licensed source.

## THE API IS DOCUMENTED — read the vendor's client, do not probe blind

`hqp-control-601-src/` in the repo root is **Signalyst's own source** for
their `hqp-control` client. It is committed unpacked so it can be grepped
directly, and it is MIT licensed
(`COPYING`), so redistributing it here is fine. `ControlInterface.cpp` writes every command this API
has and parses every reply, so it is the authority. Months of this file's
protocol notes were reconstructed by probing a live daemon and guessing at
attribute names — several of them wrongly, each recorded and then corrected in
place. **Read `ControlInterface.cpp` first.** The complete command list is now
copied into `Control.pm` above `%KNOWN`.

**TRAP WHEN EXTRACTING THE COMMAND LIST.** One command — the most useful one
here — is written as `writeEmptyElement("VolumeRange")` with a **plain string
literal**, while every other command uses `QStringLiteral(...)`. A grep for
`QStringLiteral` misses it, and this file did exactly that the first time
round. Match both forms.

What it settles that had been open or wrong:

* **`<VolumeRange/>` IS A CONTROL COMMAND — it retired `UPnP.pm` in 0.2.54.**
* **`<Status subscribe="0|1"/>` takes an explicit flag.** Verified live:
  `subscribe="0"` is a genuine **one-shot poll** — one reply, no push stream —
  and `subscribe="1"` (or the bare `<Status/>` the plugin sends) subscribes.
  So a status *query* need not touch the subscription at all.
* **`<PlayNextURI value="…"><metadata/></PlayNextURI>` exists** — note `value`,
  not `uri`. **It kills the daemon; see "Gapless".**
* **`<Play last="0|1"/>` takes a flag** saying whether this is the last track.
  The plugin sends a bare `<Play/>`.
* `PlaylistAdd` also takes `start` and `freewheel`, neither of which the plugin
  sends. `start` looks like "begin playing on accept", which would fold the
  chained `<Play/>` into one command.
* **Keep-alive is a single space** written raw to the socket
  (`csocket->write(" ")`), not an XML command.
* **HQPlayer DOUBLE-ESCAPES text metadata.** The client runs `fromEscaped()` —
  a second `&amp;`/`&lt;`/`&quot;` pass — over every text field it reads *after*
  the XML parser has already unescaped once. It does **not** double-escape on
  the way in, so `Control::escape` is right; but `Control::parseChildren`
  unescapes only once, so any text read back is one pass short. Harmless today
  (the plugin only reads `uri`, `samplerate` and `bits`, and neither tier's URL
  contains `&`) — but a URL that ever grows a query string with `&` would break
  the exact-match `uri` comparisons in `_isStale` and `_handedOver`.
* **Session authentication is Ed25519** with a Signalyst-issued per-client key
  (`SessionAuthentication`, then `secure_uri`/`secure_value` ChaCha20Poly1305).
  Not available to a third party and not needed — plain `uri` works.

## Gapless

**VERIFIED live 2026-08-28, engine 6.0.4.** Two mechanisms were candidates and
the probe settled it — decisively, in both directions.

### `PlaylistAdd queued="0"` — appending is the mechanism, and this spelling is safe.

```
t      state track  of   queued  position  uri
0.0    2     1      1    0       0         .../458773/download.flac   <- A playing
2.7    2     1      2    0       2.59      .../458773/download.flac   <- B accepted, still on A
12.5   2     2      2    1       0         .../458770/download.flac   <- ADVANCE, no state 0
29.7   0     0      0    0       0                                    <- clean end of playlist
```

Track A is 12.7 s and the advance is at 12.5 s; A+B is 30.6 s and the stop is at
29.7 s. Every question answered yes:

* the second item lands **while the first is playing** — `tracks_total` 1 → 2
* HQPlayer advances **by itself**, and `track` 1 → 2 marks it with **no
  `state` 0 in between**
* `state` still reaches **0 at the end of the last item**, repeat off
* the daemon was **alive** afterwards (`GetInfo` answered)

The `queued="0"` sent on `PlaylistAdd` is deliberate: `queued="1"` on a
mid-playback append kills engine 6.0.4 at the end of its playlist (see the trap
above). The `queued` field on `<Status/>` nevertheless reads 1 from the advance
onward, so the request attribute and status field do not mean the same thing.
The status field appears to mean "this track came off the queue"; either way
`track` is the signal `_handedOver` should keep using.

### `<PlayNextURI>` — DO NOT SEND IT. IT KILLS THE DAEMON.

Sent over a playing playlist item, it answered `result="OK"`, the very next
`<Status/>` showed it had **replaced** the playing uri rather than queuing
behind it, and then **hqplayerd exited**: both 4321 and 8019 stopped listening
(`Connection refused`, not a reset) and it did not come back on its own.

This is the same class of failure as `clPlaylist::GetAlbumGain(): trackn > last`
— an unhandled throw out of `clPlayerDaemon::Main()`. It is in `%KNOWN` only so
`tools/probe_gapless.py` can re-test it deliberately on a future engine; the arm
is **default-off** and prints a warning.

**The inference that led here was reasonable and still wrong.** `<Status/>`
carrying a `queued` boolean and `<Play last="0|1"/>` taking a "more is coming"
flag both pointed at `PlayNextURI` being the intended primitive, and it is
plainly *meant* for this. It is simply not safe on this engine. Inference from
an API's shape is a reason to test, never a reason to ship.

```
python3 tools/probe_gapless.py 192.168.1.238 \
  http://192.168.1.234:9000/music/458773/download.flac \
  http://192.168.1.234:9000/music/458770/download.flac
```

**The gap was ours, not HQPlayer's.** HQPlayer is gapless between the items of
its own playlist. The bridge fed it exactly one item at a time, so every track
end was an end of playlist: HQPlayer stopped, LMS noticed the stop on the next
status push, resolved the next track, and ran a fresh four-command load. That
round trip is the gap.

The fix is to be a **two-deep player**, which is what a real Squeezebox is.

### The LMS half

`play()` is called for two different things now, and telling them apart is the
whole of it:

| | trigger | what it sends |
|---|---|---|
| **start this track** | any ordinary `play()` | the four-command load in `_startTrack` / `_queueTrack` |
| **here is the next one** | `play()` after **we** asked, via `_armNextTrack` | one `<PlaylistAdd … queued="0">`, nothing else |

The request is recognised by **our own flag** (`hqArmNext`), never guessed from
the controller's state — a guess would misread the first `play()` after a
pause, a jump or a sync change. The flag is consumed by *every* `play()`, so a
stale one cannot swallow a later call.

`_armNextTrack` sends `playerReadyToStream` while the track is playing, which
is exactly what a Squeezebox's decoder does when it can take another stream.
`ReadyToStream` in the PLAYING/STREAMING cell is `_NextIfMore`: LMS resolves the
next playlist entry and calls `play()` again, leaving the playing track alone.
At the end of the playlist it does nothing at all, which is why nothing here has
to know how long the playlist is.

**This is the note that used to say the opposite.** `_onStatus` carried
"ReadyToStream must NOT be sent while a track is playing… we are not gapless".
That was true while every `play()` replaced the playing track. It is now the
first half of the feature.

### The status half — there is no `state` 0 between tracks

With two items on the playlist HQPlayer never stops at the boundary, so the
signal the whole state machine was built on is simply absent there. Two
attributes carry the transition instead, and `_handedOver` takes either:

* **`track`** — HQPlayer's own playlist index, numbered from 1, on every
  `<Status/>` next to `tracks_total`. Primary.
* **the `<metadata uri="">` child**, which on tier 1 is unique per track. Kept
  for an engine that does not report `track`.

Both are **one-sided**: the check only runs while something has actually been
pre-queued, and the uri test must match the exact url we queued. The worst
either can do is *fail to notice* an advance, which degrades to the old
behaviour — HQPlayer reaches the end of its playlist, reports `state` 0, and LMS
loads the next track the slow way. Neither can misfire on ordinary playback.

`state` 0 therefore now means **end of playlist**, which is what the
end-of-stream path always wanted it to mean.

### TRAP: a seeked stream has no container header, and HQPlayer sniffs

On a seek LMS re-opens the source at a byte offset, so a FLAC stream starts in
the middle of the container: no `fLaC` marker, no STREAMINFO. **A Squeezebox is
told the format out of band, in the `strm` command**, so its decoder just
resyncs on the next frame. HQPlayer has no such channel — it identifies audio
by sniffing the stream — so it cannot play it at all.

The failure is completely silent on the control API. `PlaylistAdd` and `Play`
both answer OK; only hqplayerd's log tells you, and only by contrast:

```
good start:  Stream buffer 2880000/393216   <- format known, prefill sized
after seek:  Stream buffer  262144/0        <- default buffer, nothing
             Stop request (tail)
```

**LMS will not do this for you.** `Song::initialAudioBlock` exists for exactly
this purpose, but `Protocols::HTTP::request` only builds it when the track has
a `processor` for the wanted format. A straight FLAC passthrough has none, so
LMS sets `initialAudioBlock('')` and sends the frames bare.

So `Stream::_flacPrelude` synthesises a 42-byte header. The sample rate,
channels and depth come from the track; total samples 0 ("length unknown") and
a zero MD5 ("do not verify") are both accepted. **The block size is the part
that bites**: it reads like a hint, since every frame carries its own, but a
decoder sizes its buffers from the maximum. Established by decoding 3MB taken
from the MIDDLE of a real FLAC — the seek case exactly:

| min / max block size | result |
|---|---|
| no header at all | refused — this is the bug |
| 16 / 65535 (the "unknown" form) | refused |
| 4096 / 16384 | refused — min must equal max |
| **4096 / 4096** | **decodes**, 4.8MB of PCM out |

Only on a seek, and only on FLAC: an unseeked stream already carries a real
header and a second one reads as corrupt audio, while MP3 frames are
self-describing and need nothing.

### Why HQPlayer's playlist grows, and why it is never the whole queue

Expected behaviour, decided 2026-08-30 — see the Review Ledger. Recorded here
because it looks like a bug every time somebody notices it.

**Two-deep is LMS's law, not our choice.** `StreamingController::_NextIfMore`:

```perl
# if we already have a playing and a streaming track, then wait until the streaming
# one starts to play before getting the next one.
if (scalar @{$self->{'songqueue'}} < 2) {
    _getNextTrack($self, $params, 1);
} else {
    $log->info("streaming track not started yet, will wait until then to try next track");
}
```

However often we ask, LMS will not resolve track N+2 while two are outstanding.
**Only two URLs exist at any moment, so there is nothing to push.** LMS mints
them lazily on purpose: a service URL is signed and time-limited (more so since
tier 5 hands the signed one straight to HQPlayer), and the queue is mutable —
reorder, remove, shuffle, repeat, a second controller — so LMS refuses to commit
to what is next until it has to.

Roon and HQPlayer's own library browser look different because **they own the
queue**. Here LMS owns it and we model a Squeezebox, which is also exactly
two-deep: current track plus one buffered.

**The growth is ours.** `_appendTrack` only adds; nothing removes a finished
item, and `<PlaylistClear/>` runs only on a full load (new album, or a skip). So
across one album HQPlayer accumulates every track it has played while LMS's own
queue stays at two. **What you are looking at is a history, not a queue — only
the last entry is actually next.** `PlaylistRemove` would trim it to two; that
was offered and declined.

### Tiers 3 and 4 sound gapless anyway, and here is why

**Reported by Simon 2026-08-28: Dark Side of the Moon streamed from Tidal
played gapless.** That was not designed for and it is worth understanding
rather than just believing, because it is a MARGIN, not a guarantee.

The held-track reload really does run - `end of playlist`, then the full
four-command load. Measured over 13 live transitions it takes **392-756ms**,
median about 470ms. But HQPlayer reports `state` 0 when its INPUT is
exhausted, and its output pipeline still holds `output_delay` microseconds of
already-decoded audio on its way to the NAA. On this setup:

```
output_delay = 1502902     -> 1.50s still in flight
reload       = 0.39-0.76s
```

So the next track starts roughly a second before the previous one drains, and
nothing is ever heard.

Tier 3 no longer relies on this margin at all: since 0.2.32 it is pre-queued on
HQPlayer's own playlist like tier 1, which is real gapless rather than a
buffer's grace. Only tier 4 (genuinely remote) still hands over this way.

**What eats the margin — do not promise this unconditionally:**

* **A sample-rate change.** That forces an engine reinit, measured at ~2.3s
  earlier the same day, which is longer than the buffer and IS audible. An
  album at one rate is fine; a mixed-rate playlist is not.
* **`output_delay` is this setup's, not a constant.** It comes from DSD256 plus
  convolution. A lower-latency output would shrink the window, and a short
  enough one would make the reload audible.
* **A slow resolve.** The 470ms assumes LMS already has the next track, which
  it does because the hand-over held it minutes ago.

Pre-queuing would remove the dependency entirely, but it cannot be done here -
see below.

### Tier 4 is excluded, and holds instead of appending

`_armNextTrack` appends on **tiers 1 and 3** and declines on tier 4. The
dividing line is **not** whether the URLs are unique — tier 4's are — it is
whether LMS is in the byte path.

Tiers 1 and 3 are a plain file download: LMS is not streaming them to a player
at all, so a second URL can be handed over while the first is still being read.
Tier 4 *is* the player stream, and a client has one `streamingsocket` and one
`songStreamController` — see "Tier 4" under Track resolution for why appending
there would tear the playing track.

So a tier 4 next track is **held**, not appended, and loaded the ordinary way
when the current track ends (`hqNext` with `mode => 'load'`). `_armNextTrack`
also declines to ask at all while a tier 4 track is playing, so LMS is never
made to open a source stream minutes before it is needed.

### Three things that had to change with it

* **`flush()` was a no-op stub** and is now real. `_FlushGetNext` calls it when
  LMS discards the track it handed over — a playlist edit, or a jump — and
  `<PlaylistClear/>` is exactly right: verified live, it keeps the item that is
  **playing** and drops the rest. If the append is still in flight the clear
  queues behind it on the same socket, so it cannot overtake the item it is
  meant to remove.
* **A refused pre-queue is not reported as a failed load.**
  `playerStreamingFailed` leads to `_SyncStopNext` → `_getNextTrack` →
  `play()`, and *that* `play()` is a full load — it would stop a track that is
  playing perfectly well. The track is demoted to `mode => 'load'` instead and
  the ordinary load reports the failure at end of track, in the state the error
  handling was written for.
* **`playerBufferReady` is skipped when the controller is already PLAYING.**
  `BufferReady` in the PLAYING row is `_Invalid` — a warning and a backtrace.
  The deferred tier 4 load is the case that hits it.

### What is deliberately NOT done

`hqGen` is **not** bumped for a hand-over. The generation belongs to the track
that is playing and its callbacks must keep running; bumping it there would make
the running track supersede itself. A hand-over also cannot carry a **seek** —
`<Seek>` acts on what is playing now, not on a queued item — so an armed
`play()` with seekdata falls back to the full load.

## Why the load runs on the control socket: the crash

The load is **four ordered commands on one socket**:

```
<Stop/> → <PlaylistClear/> → <PlaylistAdd …><metadata …/></PlaylistAdd> → <Play/>
```

`<Play/>` is chained off `PlaylistAdd`'s reply; the first two are
fire-and-forget, because ordering comes from the socket rather than from the
callbacks.

**This is what stopped hqplayerd crashing.** The load used to be split: `<Stop/>`
on the control socket while `SetAVTransportURI` and `Play` went over UPnP. Those
two channels cannot be ordered against each other — a control command answers in
~9–150 ms and a UPnP round trip in 300–550 ms — so a `Stop` meant for the *old*
track could land after the `Play` for the new one and kill it. Worse, HQPlayer's
AVTransport never saw a Stop at all: from the renderer's side the transport went
straight from PLAYING into `SetAVTransportURI` while the XML Stop emptied the
engine's playlist underneath it. That is the shape of
`clPlaylist::GetAlbumGain(): trackn > last`, the fatal that took the daemon down
**whenever an album was loaded over a playing one** — the exact reproducer.

Verified 2026-08-28: this sequence run five times in rapid succession over a
playing track swapped cleanly every time, correct metadata each time, daemon
alive throughout.

### Discovery: the CONTROL LINK decides how hard to probe

**The period is chosen from link state, not from whether anything is in
`%found`.** `_schedule` picks one of three:

| state | period | why |
|---|---|---|
| nothing known | ladder **2, 4, 8, 10 s** (`COLD_PERIOD` cap) | there is no player at all; be quick |
| known, a link **down** | `COLD_PERIOD` (10 s) | "is it back yet?" — the address may have moved too |
| known, every link **up** | `IDLE_PERIOD` (10 min) | nothing a probe could say that the link will not say sooner |

**Why this is safe, and it is the whole design:** an instance that goes away —
powered off, asleep, moved by DHCP — drops its control link, which puts
discovery straight back on `COLD_PERIOD`. So the quiet period can never delay
finding it again. That in turn depends on the link state being *true*, which is
why `_statusWatchdog` now runs for as long as the link does — see below.

`Plugin::_linkUpFor` is the predicate, passed to `Discovery->start` as a second
argument. It is deliberately pessimistic: no predicate, no instances, or an
instance with no bridge yet all answer false, and false only ever means "keep
looking".

**Each round sends `PROBE_BURST` (3) probes `PROBE_GAP` (0.2 s) apart, plus a
unicast probe to every address already in `%found`.** One datagram per round was
one point of failure — measured against a live hqplayerd, of five rounds it
logged receiving only **three**: the probes at 17:47:49 (it was restarting) and
17:50:54 (it was initialising its audio engine) never arrived at all, and those
are exactly the two rounds where the plugin logged no reply.

**Unicast discovery works** — VERIFIED live 2026-09-04 against hqplayerd 6.0.4.
The same datagram sent straight to the instance's address on **4321/udp** is
answered identically to the multicast one, so a known instance is reached
without depending on group membership, IGMP snooping or which interface the
kernel picked. (The vendor's own client only ever multicasts, so this is not
in `ControlInterface.cpp`.)

**A new instance is announced the moment it replies**, not at the end of the
round — `_reply` calls `$onChange->(instances(), 1)`. That second argument is
load-bearing: **a partial list is additive only**. `Plugin::_onInstances`
returns before its removal pass when it is set, because a list still being
collected says nothing about who is absent, and reading it as a complete round
would tear down every other instance's player — playlist, prefs and sync group
— simply because it had not answered yet.

**What this fixed, measured 2026-09-04.** Simon's HQPlayer endpoint had been off
for a week. In that time the plugin collected a probe a minute that bought
nothing, and when hqplayerd came back the player still took **63 s** to appear:
the cold ladder had saturated at the old 60 s cap, the probe at 17:47:49 went
into hqplayerd's 27 s restart window, and the reply that did arrive at 17:48:51
then waited `LISTEN_TIME` before `_roundDone` announced it. All three are gone.

Covered in `t_plugin.pl`: the ladder and its cap, all three periods driven off a
fake predicate, the immediate partial announce, and that a partial round removes
nothing.

### TRAP: hqplayerd ACCEPTS the socket and then throws — a handshake is not a link

**Its control thread accepts the connection before it decides it cannot serve**,
which is what it does whenever its output endpoint is missing — the NAA switched
off, say. Its log says so in pairs:

```
+ Control connection from 192.168.1.234:42766
# clControlThread::HandleConnection(): std::exception
```

`_connectResolved` used to reset `backoff` to `BACKOFF_MIN` as soon as the TCP
handshake completed, so **every one of those looked like a success and the
ladder never climbed**. Measured over one such spell: **2,327 connections and
2,324 exceptions in 9.5 hours** — four attempts inside two seconds, every
minute, for as long as the endpoint stayed off.

So the reset moved to `_dispatch`: a **complete message off the wire** is the
first real evidence the link works. `proven` gates it, and `_dropLink` clears it.
`t_control.pl` asserts both halves at source level and drives the ladder to its
cap.

### The status watchdog's lifetime is the control link's, not a track's

`_statusWatchdog` (10 s) re-subscribes if the `<Status/>` stream lapses. It is
also **the only thing that ever proves the link is alive**: `_readable` learns a
link is dead from an EOF, and a host that is powered off, asleep or unplugged
sends no EOF at all — the socket goes quiet and `connected` stays 1 for ever.
The watchdog's `<Status/>` puts a command in flight, so `REPLY_TIMEOUT` drops
the link properly. A dead peer is therefore noticed in about
`STATUS_WATCHDOG + REPLY_TIMEOUT` ≈ **40 s**.

It used to be started at a track load and stopped at a stop, so an **idle**
player — the state a switched-off endpoint leaves you in for days — had no
watchdog and no command in flight, and nothing could ever notice. It is now
armed in `Plugin::_onLinkState` on the way up and stopped on the way down;
`stop()` and `_endOfStream` no longer touch it. Discovery reads exactly this
link state to decide how hard to probe, so a zombie "connected" would have kept
it quiet while the instance was long gone.

It never becomes a busy poll: it sends only when nothing has arrived for
`STATUS_WATCHDOG` seconds, so against a playing instance — which pushes ~1/s —
it fires not at all.

### TRAP: `Control::send`'s callback is `($attrs, $raw)`, not `($res, $err)`

`$raw` is the **raw reply on success as well as on failure** — it is never an
error string. Failure is `$attrs` being **undef**:

```perl
$req->{cb}->( undef,  $raw );   # result="Error"
$req->{cb}->( $attrs, $raw );   # OK
```

`SimpleAsyncHTTP` uses the opposite shape, `($res, $err)` — as did `UPnP.pm`,
which is where the confusion came from before it was deleted in 0.2.54 — and
0.2.13 shipped with `_queueTrack` reading the control callback that way. Every
**successful** `PlaylistAdd` was therefore logged as
`HQPlayer would not accept the track URI: <PlaylistAdd result="OK"/>`, reported
`PROBLEM_OPENING`, and LMS skipped to the next track — the player raced an
entire album in ~100 ms and played nothing. Test `!$res`, never `$err`.

The unit tests did not catch it because the mock answered with `''` as the
second argument where the real code answers with the reply. **A mock that is
laxer than the contract is worse than no mock.** `_answer` now returns real
reply XML on both outcomes, and both directions are asserted.

### TRAP: `clear="1"` is ignored

It is in the documented attribute set and `PlaylistAdd` answers `result="OK"`,
but engine 6.0.4 **appends anyway** — a swap over a playing track left a
two-item playlist with the engine still on item 1. The explicit
`<PlaylistClear/>` is load-bearing. It is safe during playback: HQPlayer keeps
the currently playing item and drops the rest. The attribute is still sent as
the documented spelling, in case a later engine honours it.

### TRAP: `<Stop/>` is required first

`PlaylistClear` leaves the current track playing, so a following `<Play/>` is a
no-op on an already-playing engine and the new track never starts.

### What HQPlayer supplies by itself

Title, artist, album, genre and **replaygain**, all read from the file's own
tags once `initBitrateLimit` stopped LMS transcoding to MP3 —
`Adaptive transport gain: -6.31 dB` matched the file's `REPLAYGAIN_ALBUM_GAIN`
exactly. `<metadata>`'s `song`/`artist`/`album` are therefore belt-and-braces;
`cover` is the part that earns its place.

**`/cover/current` is not evidence of anything.** It serves the correct embedded
JPEG whichever way the track was loaded, because it is HQPlayer's own web
surface — not the channel that reaches the NAA. Judge artwork by
`<PlaylistGet picture="1"/>`, which is the item HQPlayer forwards.

## hqplayerd "crashes": it is NOT crashing, and it is not the plugin

Investigated 2026-09-05 after Simon reported the daemon "keeps crashing".
**Three separate things were being conflated.** Do not re-run this from scratch.

**1. It never crashed.** macOS writes a `.ips` crash report for any segfault and
there are **none** for hqplayerd - only a `cpu_resource.diag` from 2026-08-30
(52% avg CPU over 175s, `Action taken: none`, which is normal for DSD256 +
convolution). Every session ends with an orderly `Server stopping...` ->
`Metering disabled` -> `Engine stopping...`.

**2. Every stop was a Dock-issued FORCE QUIT, and the process exited cleanly.**
From the system log (`/usr/bin/log show`, absolute path - `log` is shadowed by a
shell function on this Mac):

```
15:01:44.586  Dock[651] [com.apple.libquit] hqplayerd [89085] force quit (caller responsible for termination)
15:01:44.590  Dock[651] hqplayerd [89085] calling back to client to terminate
15:01:45.284  launchd  exited due to exit(0), ran for 1970076ms
```

Identical at 12:31:59 and 14:28:38. `exit(0)` every time. The CrashReporter
plist's `ForceQuitDate` is the same event **in UTC** - do not read it as a
separate incident, which this file did once. No hang was recorded either: the
`watchdogd` / WindowServer lines near those timestamps are routine noise and
never name hqplayerd.

**3. The REAL fault is hqplayerd's control thread wedging**, which is what makes
playback stop and prompts the restart that looked like a crash. Two signatures:

| signature | meaning |
|---|---|
| `clControlThread::HandleConnection(): std::exception` | the socket is accepted and never "starts" - no `Control started`, no `Control ended` |
| `clControlThread::ParseMsg(): std::exception` | an established link rejects a message, and `PlaylistAdd` is the one seen failing |

Once wedged it stays wedged; a restart clears it. In one session 32 connections
were accepted and only **6 ever started**.

**Why the plugin is not the cause:**

* **The first failure of the 11:46 session was triggered by a bare
  `<VolumeRange/>` probe from another machine**, with the plugin uninvolved.
  A daemon that throws on the simplest well-formed connection from an
  uninvolved host is broken on its own account.
* The commands that drew `ParseMsg` are plain-ASCII tier 1 loads
  (`"Gold on the Leaves" / "Luluc" / "Passerby"`). **Replayed verbatim on a
  healthy daemon they answer `result="OK"`** - so does the curly apostrophe
  (U+2019) that was briefly suspected, and `cover=` / `album_gain=` alone.
* The reconnect backoff is correct and was measured doing 2 -> 4 -> 8 -> 16 ->
  32 -> 60s.

**What the plugin DOES make worse, and should fix.** A failed `PlaylistAdd`
becomes `PROBLEM_OPENING`, LMS skips to the next track, that load fails too -
**five full `Stop/Stop/PlaylistClear/PlaylistAdd` cycles in under a second** at
15:01:29. It does not cause the wedge but it hammers a daemon that is already
sick. **A circuit breaker after N consecutive load failures is worth building
whatever the root cause turns out to be.** **BUILT in 0.2.60** — see
`FAIL_LIMIT` and `_loadFailed` below.

**The trigger is still unknown** - nothing is logged between the last healthy
event and the first exception in any of three sessions. **To catch it, leave a
wedged daemon RUNNING** and probe it: whether `Status`/`GetInfo` still answer
while `PlaylistAdd` throws separates "the parser is broken" from "the playlist
engine is broken", and that is the fork logs cannot settle.

## 0.2.60 (2026-09-05): the circuit breaker

The last "owed but not built" item from the wedge investigation. No change to
playback, transport, volume or the signal path — only to what happens when a
load fails three times running.

`FAIL_LIMIT` is **3**, and `_loadFailed` is now the ONE place a failed load is
reported. All four routes reach it — no control link, a refused
`<PlaylistAdd>`, a refused `<Play/>`, and the `START_DEADLINE` expiring on an
ack that never became playback — because a wedged daemon does not fail by one
route at a time, and a breaker wired to a single call site leaves the other
three stampeding. `t_player.pl` asserts that count directly: exactly one
non-comment `playerStreamingFailed` survives in `Player.pm`.

Below the limit **nothing changes** — LMS is told, and LMS gets to skip, which
is the right answer for one bad track. At the limit the failure is deliberately
NOT reported, because reporting it *is* the skip; instead `_tripStop` runs
`execute(['stop'])` one event-loop turn later. The defer matters: two of the
four routes are inside a call LMS made into us (`play()` with no link) or
inside a control-socket callback, and dispatching a stop re-entrantly from
either is a tangle. The turn is guarded by the same generation check
`_startDeadline` uses, so a load superseded in the meantime stops nothing.

**Where the run is cleared is the whole design.** Two places only: the
`hqStarted` latch, and the trip. Clearing it in `stop()` or `play()` would be
the obvious thing and would defeat the breaker outright — LMS calls both on the
skip path this exists to bound.

545 assertions green; **not yet tested on the live LMS.**

## 0.2.61 (2026-09-05): the live page, because the settings page could not be proved

**Simon: the settings page never updated for him, and no measurement located
the fault.** Everything checkable checked out: the `signalpath` query answers
live and its values move (63.2 -> 68.5 -> 64.3 -> 55.0x, sampled 2s apart); the
served script is syntactically clean and, **executed against a real server
response with a stub DOM, writes every row correctly**; Material uses a plain
`<iframe :src>` with **no `sandbox` and no CSP anywhere**, and its
`applyModifications()` only adds CSS classes to a plugin page (the DOM-rewriting
paths are gated to `server`/`player`/`extras`/`lms`). His own disproof of the
"your browser" theory was correct and decisive: Now Playing and scan progress
update live for him — though both run in Material's OWN document, not in the
settings iframe, which is the distinction that kept the question open.

**His call, and it is the right one:** stop defending that page and open a
proper one. What the settings page cannot shed is its surroundings — it is a
`Slim::Web::Settings` page rendered through `[% PROCESS settings/header.html %]`,
so it arrives wrapped in the entire classic-skin settings shell (mousetrap,
custom-select, the theme bootstrap, `chooseSettings`, **two nested forms**) and
Material then loads that inside its iframe dialog.

`Live.pm` removes every one of those variables rather than reasoning about
them. It is a **raw handler at `/hqplive`**, so the bytes it returns are the
whole document: no template, no skin, no settings chrome. The settings page
gains a link that opens it with `target="_blank"`, so it runs as a **top-level
document** on the same footing as any ordinary web page. It polls at 1s and
**never stops itself** — the settings poller's `clearInterval` after five errors
made a dead page and a frozen value look identical, which is precisely the
ambiguity that cost several rounds — and it stamps a visible `updated HH:MM:SS`
plus a live/error dot, so "is it alive" is never again a matter of opinion.

**Two real defects fixed on the way:**

* **`process_speed` was guarded on TRUTHINESS.** HQPlayer reports `0` whenever
  it is not actively processing, and 0 is false in Perl, so the speed was
  DELETED from the string rather than reported as `0.0x`. Caught live: one
  sample carried no speed while samples 2s either side carried 69.2x. The row's
  content silently depended on transport state. `active_filter` and
  `active_shaper` had the same guard; all three now test `defined`.
* **The query sent only `id`**, which is a MAC address, so the live page had no
  name to head a card with. It now sends `name` too.

**`Live.pm` never calls into `Plugin.pm`** - the version is handed in at
`init`. A page module that reaches into its own Plugin.pm without `use`-ing it
dies PART WAY THROUGH the handler, and LMS renders the half-built page with
nothing in the log; that shipped Eversolo Screen Control 1.5.0 completely broken
with every check green. `t_live.pl` asserts the absence.

571 assertions green, and the page's own JS was **executed against a real
`signalpath` response** before shipping - live dot, timestamp, all rows.
**Not yet tested on the live LMS.**

## 0.2.62 (2026-09-05): no settings page, and the app opens the live view

**Simon: "We dont need settings at all as we dont change anything, lets have
the app just load the signal path."** `Settings.pm`, its template and its
registration are DELETED. Nothing in this plugin is configurable, so the page
only ever existed to read numbers off - and it could not keep them current.

**A MATERIAL BROWSE LIST CANNOT REFRESH ITSELF, and that is settled from
Material's source rather than inferred:** every `refreshList` trigger in
`browse-page.js` is a USER ACTION inside Material (a playlist edit, a favourite
change, random mix), and no LMS notification is wired to it. There is no
plugin-reachable path. So the app's rows are a snapshot permanently, and the
live reading has to live on a page of its own.

The app feed is now **one action row** that opens `/hqplive`, then the snapshot.
**The manual Refresh row is GONE** - Simon asked for a live view, not a button
to press - and so is the link-inside-a-link that reaching the live page used to
require (Apps -> Settings -> another link -> the page).

**0.2.61's button never worked, and the cause is worth keeping.** Material binds
`otherClickHandler` on the settings iframe's DOCUMENT and it captures EVERY
`<a href>` click: it reads `getAttribute('href')`, **IGNORES `target=`
entirely**, and re-emits the href as `iframe-href`, which loads it back into
that same iframe. So `target="_blank"` was silently discarded and the live page
opened in the very context it exists to escape - which is why 0.2.61 looked
identical to 0.2.60. Its own condition names the escape hatch: it skips hrefs
starting with `#`. Material's `openWebLink` splits the same way - a RELATIVE
weblink goes to the iframe dialog, an absolute `http://` one to `window.open`.
An absolute URL is not available to us: `IPDetect::IP()` answers `127.0.0.1` on
this server ([[lms-server-ip-is-loopback]]).

**VERIFIED WORKING by Simon on 0.2.61**, opened directly at
`http://plex:9000/hqplive`: *"it refreshes as I loaded the page works well"*.
That is the first confirmed live reading on any surface.

A **Back to Material** button was added at his request: `window.close()` first
(this page is normally a script-opened window, which can close itself), then a
fallback to `/material/` - and if it is framed, the TOP window is navigated,
not the frame. The fallback is not optional: `window.close()` is a no-op on a
tab the user opened and inside a frame.

577 assertions green; the page's own JS was executed against a real
`signalpath` response, back button included. **Not yet tested on the live LMS.**

## 0.2.63 (2026-09-05): the description was wrong, in six places

**Simon: "we have it saying LMS doesnt touch the audio this isnt 100% correct as
it does when transcoding formats HQPlayer doesnt support."** He is right, and
the claim had been copied into every user-facing surface.

"No audio through the plugin" is true of tiers 1 and 5 and FALSE of the other
two. **Tier 3 is an LMS transcode** of a format HQPlayer cannot decode
(m4a/ALAC/AAC), and **tier 4** runs its bytes through LMS's streaming machinery
and this plugin's own `/hqp/` endpoint. The defensible claim is that the plugin
adds **no audio stage of its own** - no buffer, no helper binary, no UPnP hop -
which is a statement about the BRIDGE, not about LMS.

Corrected in `strings.txt` (the description LMS displays), `repo.xml`,
`README.md` (tagline and the feature table), `README.html` **and
`tools/make_readme_html.py`, which had it hardcoded as a STATIC_BADGE** - the
generator would have put it straight back on the next regeneration. Also in
`Player.pm`'s header and in this file, both of which now say per-tier what is
and is not touched.

**The lesson is the copy, not the sentence:** one appealing line was written
once and then propagated to six places, including a generator, where correcting
the visible copies would have left it to come back.

## 0.2.64 (2026-09-05): a Home tile, because an Apps entry CANNOT open a page

**Simon: "its loading a page I still need to click on to open up the live view.
We agreed to load straight to the view."** He is right that 0.2.62 did not do
that, and here is why it could not.

**AN APPS ENTRY CAN NEVER OPEN A URL.** Material's `apps` command builds every
plugin entry itself, hardcoded (`MaterialSkin/Plugin.pm`):

```perl
$request->addResultLoop('item_loop', $cnt, 'type', 'redirect');
my $actions = { go => { cmd => [ $app->tag, 'items' ], params => {...} } };
```

There is **no `weblink` field a plugin can supply**, and `browse-resp.js` does
not auto-open a single-item feed (its one special case just wraps a lone `text`
item in a div). So tapping an app in Apps ALWAYS browses into its feed. One tap
to a page is not achievable from that surface, by anyone.

**What IS achievable is a HOME TILE.** Material 6.4.6+ takes plugin-registered
custom actions, and `loadCustomPinned` in `browse-page.js` turns any action in
the **`pinned`** section carrying a `weblink` into a tile on the Home screen
that opens that link **on one tap**. `postinitPlugin` now registers exactly
that. Simon reached the same place independently by pinning it by hand.

**TRAP: `registerCustomAction` PUSHES** - no unregister, no de-dupe - so
registering twice puts the tile on Home twice. It runs once per server run,
from `postinitPlugin`, and `t_plugin.pl` asserts a second call would add a
second entry (which is why nothing re-enterable may call it). Registration goes
through the `->can` code ref, and `->can` on a package that was never loaded
answers undef, so no Material means no tile and no error - asserted too.

The idiom, including the two-argument-only call, is LMS-Listen-to-Later's;
**the dangerous one-argument `registerCustomAction($section)` form is NOT used
here** - on Material 6.4.6/6.4.7 it pushes undef and takes out every custom
action in that section, other plugins' included.

**Still open:** a relative `weblink` goes to Material's iframe dialog rather
than a real window (`openWebLink` uses `window.open` only for an absolute
`http(s)://` URL, and `IPDetect::IP()` answers 127.0.0.1 here, so an absolute
one cannot be built). Whether the live page ticks inside that dialog is
UNTESTED - the page's `updated HH:MM:SS` clock answers it in one look.

## 0.2.65 (2026-09-05): the tile is named "HQPlayer Live View"

**Simon: "the name of the link is whats added to the homepage."** It is - Material
writes the custom action's `title` straight onto the Home tile - so the string
has to NAME THE PLUGIN, not describe an action. "Open live view" was fine as a
row inside the app and useless as a tile sitting next to Albums and Radio.

`PLUGIN_HQPLAYER_LIVE_OPEN` -> `PLUGIN_HQPLAYER_LIVE_TITLE`, EN **"HQPlayer
Live View"**. The Apps row uses the SAME string deliberately, and `t_plugin.pl`
asserts the two are identical: two labels for one destination is how they drift
apart. `PLUGIN_HQPLAYER_LIVE_DESC` is deleted - it was the settings page's hint
text and that page is gone.

## 0.2.66 (2026-09-06): the Apps list shows SETTINGS, the live page shows the path

**Simon: "the page when entered from apps shows the signal path and the link.
So we should just show the current settings for HQPlayer at this point with the
button link to open the live view."**

The Apps list was showing a stale copy of what the live page now does properly.
It is a snapshot that **can never refresh itself** - Material has no
plugin-reachable path to re-render a browse page - so a per-track source format
and a speed that moves every second were guaranteed to be wrong there.

**The split is by how long a fact stays TRUE**, and it falls out of the same
formatter:

| surface | shows | why |
|---|---|---|
| Apps list (snapshot) | output mode, filter, shaper, transport | still true a minute later - these are what you would go into HQPlayer to change |
| `/hqplive` (1s poll) | source format, output format, processing + speed | moves per track and per second |

`signalPathFor` now returns `mode`, `filter`, `shaper` and `transport` as
individual fields alongside the live `processing` line, so **neither surface
formats anything itself** - the thing that keeps them from disagreeing about
what "Filter" reads like. `t_plugin.pl` asserts BOTH halves: the settings rows
are present AND the source/output/speed rows are gone, so the change cannot
pass as merely additive.

**`PLUGIN_HQPLAYER_TRANSPORT_ID` is the word "id", not a label** - it is a
VALUE ("id 5"), which is why the old settings page paired it with
`PLUGIN_HQPLAYER_OUTPUT` as the heading. The row reads "Output transport: id 5".
That is the closest thing to naming the NAA that exists: `<GetTransport/>`
answers a single value+arg and **there is no `TransportItem` response at all**,
so the available endpoints cannot even be enumerated (verified in Signalyst's
own client - see below).

## HQPlayer's control API: what is settable, and the one thing that is not

Read out of `hqp-control-601-src/` (Signalyst's own client), 2026-09-06,
against Simon's proposal to make output mode, filter, shaper and the NAA
editable. **Not built - he parked it - but the reference is settled.**

**Enumerable, so a picker is buildable:**

| what | list -> item | set |
|---|---|---|
| PCM / SDM | `<GetModes/>` -> `ModesItem index name value` | `<SetMode value="N"/>` |
| filter | `<GetFilters/>` -> `FiltersItem` | `<SetFilter value="N" value1x="M"/>` |
| shaper | `<GetShapers/>` -> `ShapersItem` | `<SetShaping value="N"/>` |
| output rate | `<GetRates/>` -> `RatesItem` | `<SetRate value="N"/>` |
| junk filter | `<GetJunkFilters/>` -> `JunkFiltersItem` | `<SetJunkFilter value="N"/>` |
| saved configs | `<ConfigurationList/>` -> `ConfigurationItem` | `<ConfigurationLoad/>` |

Also `<SetConvolution>`, `<SetInvert>`, `<SetAdaptiveVolume>`, `<SetTransportPath>`,
`<SetTransportRate>`, `<MatrixListProfiles/>`/`<MatrixSetProfile>`.

**NOT enumerable - the NAA.** `<GetTransport/>` answers ONE current
value + arg, and the complete set of `*Item` responses is
`ConfigurationItem, FiltersItem, InputsItem, JunkFiltersItem, ModesItem,
PlaylistItem, RatesItem, ShapersItem`. **There is no `TransportItem`.** So the
current transport can be read and a specific one can be set, but the available
endpoints cannot be discovered - a picker is not buildable from this API. The
practical route to switching endpoints is `ConfigurationList`/`ConfigurationLoad`,
since a saved HQPlayer configuration bundles the output device.

**Three things to settle before any of it is built:** these are GLOBAL HQPlayer
settings (they apply when LMS is not driving it too, a real departure from
"the bridge only reflects"); changing mode or filter mid-playback forces an
engine reinit, which is the same ~2.3s of silence a sample-rate change costs;
and `SetFilter` carries TWO values, because HQPlayer keeps separate filters for
1x and Nx rates (hence `filter1x` on `<State/>`).

**The live lists are UNPROBED.** Confirming what Simon's daemon actually offers
needs `GetModes`/`GetFilters`/`GetShapers`/`ConfigurationList` on 4321, and a
bare read-only probe once preceded a control-thread wedge - so it must not be
run while he is listening. See [[hqplayerd-control-thread-wedge]].

## 0.2.67 (2026-09-06): the Home tile opens INLINE

`weblink` -> **`iframe`** on the registered custom action. One key, and it is
the whole behaviour, because a pinned tile is dispatched as a CUSTOM ACTION and
not as a browse row:

```js
// browse-functions.js
if (item.isPinned) { if (item.custom) { performCustomAction(item, ...); return; } }
// customactions.js doCustomAction
if (action.iframe)       bus.$emit('dlg.open', 'iframe', ...);   // INLINE dialog
else if (action.weblink) window.open(...);                       // separate window
```

**`weblink` ALWAYS tears off a separate browser window on this path** - there is
no relative-vs-absolute test here. That test lives in `openWebLink`, which is
the BROWSE-ROW route, and confusing the two is what made 0.2.64 open a window
when the earlier reasoning said it would embed. Two dispatch paths, opposite
answers, same-looking data. `loadCustomPinned` accepts either key, so the tile
appears either way; only where it opens changes.

**The Back button is now removed when framed.** Simon: *"its not needed though
as you use materials back"* - and it was worse than redundant: from inside the
frame the only exit is `window.top.location`, which navigates the WHOLE Material
app away and throws out whatever the user was doing. Standalone (opened by URL,
or by anything using `weblink`) it stays, because there is no browser Back in a
fresh window; there `window.close()` runs first and falls back to `/material/`.
Both paths were EXECUTED against a real `signalpath` response before shipping -
framed: button removed, no listener, poller live; standalone: button present,
click closes then navigates.

## 0.2.68 (2026-09-06): now playing on the live page, in Material's theme

Two asks. **Now playing, laid out like Material's** — small cover left,
title/artist/album right, a progress bar and elapsed/total — **and the page
matching Material's own light/dark theme and accent colour.**

**The now-playing resolution is LMS-NowPlayingDisplay's, reused rather than
re-derived.** Simon: *"we have a now playing project local, you can check there
as we did the same."* That plugin has already been through these traps in this
order, and the ARTWORK ORDER in particular is not guessable:

1. **`artwork_url` wins** — streaming and remote tracks set it to an LMS
   imageproxy path, already server-relative.
2. **`/music/<coverid>/cover.jpg`** otherwise — but ONLY when the coverid does
   not start with `-`. LMS mints synthetic NEGATIVE ids for remote tracks and
   `/music/` **404s** on them, so a URL built from one is a BROKEN image, which
   is worse than none.

`remoteMeta` is the other half: for a remote track the useful metadata sits at
the TOP LEVEL of the status result, not in `playlist_loop`, so every field falls
back to it. Position comes from `Slim::Player::Source::songTime`, which is not
in the status result at all. Nothing playing yields an **empty hash**, so the
page draws no panel rather than an empty one. All of it rides the SAME
`signalpath` poll — one round trip, and the page never has to know which player
id belongs to which bridge.

**The theme follows Material, by LMS's own recipe** — the classic skin's
settings header does exactly this, and it is the supported way for a non-Material
page to match. Material records the choice in `localStorage` on the same origin:
`lms-material::theme` (`dark|darker|light|auto|<name>[-colored]|user:<name>`) and
`lms-material::color`. The normalisation is copied in behaviour — `darker`
renders as dark, `auto` follows `prefers-color-scheme`, a trailing
`-colored`/`-standard` is a VARIANT and not part of the name, `user:` themes
live under `/material/usertheme/`. The page then loads Material's own
`/html/css/themes/<name>.min.css` and `/html/css/colors/<col>.min.css` and
styles from `--std-background-color`, `--std-popup-background-color`,
`--primary-color` and `--accent-color`. **Those stylesheets carry no TEXT
colour** (Vuetify supplies it inside Material), so the page sets its own from
the light/dark decision, and every variable has a real Material value as a
fallback so a server without Material still renders correctly. The
`localStorage` read is wrapped — it THROWS in some privacy modes, and the theme
is decoration while the signal path is the point.

### TRAP: the JS lives in an INTERPOLATING Perl heredoc

`<<"HTML"` means **every backslash escape is Perl's before it is JavaScript's**.
`\u2014` is not an em dash here — it is Perl's *titlecase the next character* —
and it shipped as the literal text `2014`, rendering live as
**"Luluc 2014 Passerby"**. Caught by executing the served page against a real
payload, not by reading it.

`\d`, `\.`, `\x` and `\U` are the same hazard, so **a JS regex cannot be
written literally in this file either**. Build such characters at runtime
(`String.fromCharCode`, `new RegExp` with a doubled backslash). `t_live.pl`
asserts the SERVED BYTES carry no `\uXXXX` anywhere — and note the first cut of
that assertion failed against this file's own comment explaining the trap, which
is the second time a crude source-grep has matched its own warning.

622 assertions green; the page was executed against a real payload with
now-playing fields, both framed and standalone. **Not yet tested on the live
LMS** — and HQPlayer was off while this was built, so the now-playing panel has
never been seen against a real track.

## 0.2.69 (2026-09-06): the live page scales, and gains Material's transport + volume

Simon: *"the now playing is very small on a pc screen, looks ok on mobile so its
not scaling properly which material does. I also think we need transport
controls and volume control controls need to match to material skin so reuse
those icons if possible."*

### It was two problems, not one

The cover was a hard `96px` **and** the page was full-bleed, so on a desktop a
phone-sized cover sat at the end of a 1900px row. Both are fixed: every size is
now `clamp(min, <viewport>, max)` with the OLD MOBILE SIZE AS THE FLOOR — which
is why nothing changes on a phone, exactly as asked — and `.wrap` centres the
content at `max-width: 1100px`. Artwork `clamp(96px, 15vw, 208px)`, title
`clamp(17px, 1.5vw, 25px)`, and the body, gaps and label column scale with them
so the proportion holds rather than a big cover next to small type.

`vw` inside Material's iframe dialog resolves against the IFRAME's width, not
the screen's, so the page scales to the dialog it is shown in.

### The controls send Material's own commands, read from Material's source

Not equivalents — the same ones, so a button here behaves like the one on
Material's Now Playing page:

| | command | why not the obvious one |
|---|---|---|
| prev | `['button','jump_rew']` | restart-then-previous, like the hardware button. `['playlist','index','-1']` SKIPS a track the user expected to restart |
| next | `['playlist','index','+1']` | |
| play/pause | `['pause']` when playing, else `['play']` | |
| mute | `['mixer','muting', muted ? 0 : 1]` | |
| volume | `['mixer','volume', v]` on `change` | firing per `input` puts a request on the wire for every pixel of the drag |

A command is addressed to the **player id**, added to the query as `playerid`.
`id` in `bridges_loop` is the INSTANCE key and the two are not interchangeable —
sending to the wrong one silently controls nothing.

### Volume state: the SIGN is the mute flag

There is no muting field in a status result. LMS stores the level **negated**
while muted, so `abs()` is the level and `< 0` is the flag — Material's own rule
(`server.js`: `player.muted = ... player.volume<0`). A reader that misses this
shows `-69` on the slider and never lights the mute button.

Whether a slider should exist at all is `use_volume_control`, which
`Slim::Control::Queries` computes as
`(digitalVolumeControl || !hasDigitalOut) ? 1 : 0` — so it already accounts for
the user setting this player to **fixed volume** in LMS's audio settings, the one
switch that means LMS stops driving HQPlayer's level (see
`Player::_volumeIsFixed`). Every skin hides its slider on that flag and so does
this page. **Both fields ride the status request `nowPlayingFor` ALREADY makes**
— no extra round trip, no pref read. Verified live before writing the code:

    'mixer volume' = 69    'use_volume_control' = 1    'digital_volume_control' = 1

An ABSENT `use_volume_control` is read as 1, not 0 — reading missing as "fixed"
would hide a working slider.

### Nothing playing drops the TRACK, not the player

`nowPlayingFor` used to `return {}` with no title. It now deletes only the track
keys and keeps `state`, `volume`, `muted`, `volctl`, because those describe the
ENDPOINT and are exactly what the controls need while the queue is stopped — a
mute button that cannot know whether it is muted is not a control. The panel
still draws no artwork, no title and no progress bar; the card takes an `idle`
class and collapses to its control row. The rule that an empty panel is worse
than none is unchanged.

### The icons are Material's actual font

`/material/html/font/font.css` — verified serving (200, and the `.ttf` beside it
200), so the glyphs are the same artwork as Material's, at whatever size this
page asks for. Roboto comes with it, so the type matches too.

**A Material Icons glyph is selected by its LIGATURE**, so the element's text is
the literal word `play_circle_filled`. On a server with no MaterialSkin that
stylesheet 404s and **that word is what the user reads**. So the page checks
`document.fonts.check('24px "Material Icons"')`, sets `html.noicons` when the
font never arrived, and a CSS rule then hides the word and draws a Unicode
stand-in from each glyph's `data-alt`. Built with `String.fromCharCode` — this
is still the interpolating heredoc.

### The panel is now built ONCE and updated in place

It used to be an `innerHTML` string guarded by a signature — but the POSITION was
in that signature, so it was rebuilt every second regardless. That was survivable
for a cover and some text; it is not survivable with controls, because
rebuilding the markup under a slider replaces the element mid-drag and a focused
button loses focus once a second. The DOM and its handlers are created once and
each poll writes values into it.

And a volume reply races the poll that already left, which carries the OLD level;
written back, that reads as the slider snapping backwards. So the server's volume
is ignored for 1.2s after we set it, while the thumb is held, and while the
slider has focus.

### Executed against the real page, not just grepped

The served bytes were extracted, both `<script>` blocks syntax-checked, and the
whole page RUN against a live `signalpath` payload (Patti Smith, "Gone Again")
under a DOM shim whose element ids come out of the markup `build()` writes — so
the harness cannot agree with a typo'd id. It caught a real defect no source
assertion would have: the mute button was reached as `el.imute.parentNode`, one
assumption about the markup away from a TypeError that aborted the entire
update. Every element the updater touches is now held directly.

Rendered: title, `Patti Smith — Gone Again` (em dash correct), bar `33.4%`,
`1:05 / 3:16`, `play_circle_filled` for a paused player, volume 69. Idle, muted
and fixed-volume payloads were run through the same page: `card np idle`,
`volume_off`, and `np-vol off` respectively. All five buttons put the right
command on the wire addressed to the right player id.

**A fourth crude source-grep matched its own explanatory comment** — the `2014`
assertion failed against the new JS comment describing the bug. The comment now
says the digits cannot be repeated there, and why.

652 assertions green. **Not yet tested on the live LMS.**

## 0.2.70 (2026-09-06): volume buttons, and a startup message that is not alarming

Simon: *"would prefer buttons for volume rather than a slider or both if
possible as material offers both, also we get some error message when it starts
up and not connected which is alarmist, it should say waiting for player to
connect."*

### The volume widget is now Material's, arrangement and all

Material's `volume-control.js` is `volume_down | slider | volume_up | level`, so
that is what this is — both, as asked. The mute button is gone as a separate
control and the **level itself is the mute toggle**, which is where Material puts
that gesture (`toggleMuteLabel`); it is a real `<button>` with a Mute/Unmute
title, so it is more discoverable here than Material's middle-click. **Both step
buttons show `volume_off` while muted**, which is how Material shows the muted
state.

**The step is the user's own, not one picked here.** Material keeps it at
`lms-material::volumeStep` in localStorage — the same origin this page already
reads the theme from — so its buttons and these move by the same amount. Default
5, Material's own, when Material has never run in that browser.

The command is **relative** (`["mixer","volume","+5"]`), like Material's, so the
server and not this page decides where the ends of the range are. But the slider
moves **locally first**: a volume reply is held off for 1.2s (see 0.2.69), so
without the local move a second press would step from a stale value and the
widget would look stuck while the level was actually moving.

### The alarming startup was a real defect, not just wording

`signalpath` **omits `bridges_loop` entirely** when it has nothing to put in it —
`addResultLoop` is simply never called — and the page treated a missing loop as a
malformed reply. So for the whole window between the server starting and
HQPlayer being discovered it painted a **red dot and a bad-reply string naming
the missing key**. Nothing was wrong: the poll answered, and the answer was that
the player had not turned up yet.

Now `r.bridges_loop || []`, a green dot, and
`PLUGIN_HQPLAYER_LIVE_WAITING` — *"Waiting for the player to connect"* — which
also replaces the hardcoded English "No HQPlayer instances found." and the
"Starting…" placeholder. **A genuinely malformed reply is still an error**: a
missing `result` throws as before.

Executed against a pre-discovery reply (`{"count":0}` and no loop): panel hidden,
`dot live`, empty error, waiting card. Against the live playing payload: the
three volume gestures put `["mixer","volume","-5"]`, `["mixer","volume","+5"]`
and an absolute set on the wire, and the muted payload flips both buttons to
`volume_off` with the label offering Unmute.

**A fifth crude source-grep matched its own explanatory comment** — the new
comment naming the old bad-reply string failed the assertion that the string is
gone. Same fix as the `2014` one: the comment says the wording cannot be
repeated there, and why.

664 assertions green. **Not yet tested on the live LMS.**

## 0.2.71 (2026-09-06): the ticker goes, and a cleanup pass

### The "updated HH:MM:SS" ticker is gone

It existed to prove the page was ticking while the settings page's poller was
being diagnosed. That question is settled and the page visibly moves on its own,
so it was a number changing in the corner. **The dot and the failure text stay** —
live/failed and the reason for a failure were never decoration. Proven by
execution, not grep: the shim no longer pre-registers a `stamp` element and the
page never asks for one.

### Optimisation and cleanup pass

**Dead code removed** (all confirmed unreferenced first, not assumed):

| Removed | Where | How it was confirmed |
|---|---|---|
| `PLUGIN_HQPLAYER_INSTANCE` label | `Live.pm` | resolved by `cstring`, shipped into the page's `L` object, **never read** |
| `my $log` + `use Slim::Utils::Log` | `Live.pm` | one occurrence in the whole file — the declaration |
| `use Slim::Utils::Timers`, `use Slim::Utils::Prefs` | `Plugin.pm` | zero `::` and zero `->` references |
| `use Slim::Utils::Misc` | `Player.pm` | zero references, and none of its exports (`assert`/`bt`/`msg`/`msgf`/`errorMsg`/`specified`) called bare either — checked, because removing a `use` DOES break a bare imported call |
| 6 orphaned strings | `strings.txt` | `_NONE`, `_OUTPUT_DESC`, `_VOLUME`, `_VOLUME_NOW`, `_VOLUME_STEP`, `_INSTANCE` — all settings-page leftovers |
| `ICON_SETTINGS` -> `ICON` | `Plugin.pm` | there is no settings page for it to be the icon of |

Every `sub` was checked for references too. **Nothing dead**: the 16 that look
unreferenced (`model`, `isPlayer`, `hasVolumeControl`, `playPoint`,
`pauseForInterval`, `getDisplayName`, `shutdownPlugin` …) are all called by LMS
by name. Every accessor in the `mk_accessor` list is used, and `hqPath` — which
looks undeclared — is a real sub wrapping `hqPathData`.

**A regression found by the orphan sweep.** `PLUGIN_HQPLAYER_NONE` / `_NONE_DESC`
being orphaned meant the Apps feed had **stopped saying anything at all** when
nothing was discovered — just a bare live-view link and no explanation. Restored,
in the live page's wording: *"Waiting for the player to connect"* plus the
discovery diagnostic under it. Waiting, not failed: discovery keeps probing and
a switched-off instance appears on its own.

**One optimisation.** `render()` rewrote the signal-path card's `innerHTML`
**every second regardless**, which drops any text selection inside it — a user
copying a filter name could never finish, and the waiting screen was rewriting
itself once a second saying the same thing. Now written only when it differs.
While a track plays the processing speed really does change every second and it
rewrites anyway; stopped, paused or waiting, the card holds still. Same class of
defect as the panel rebuild fixed in 0.2.69, in the half that was left.

### Docs: the README described a page that no longer exists

`Settings -> Advanced -> HQPlayer Bridge` was still documented as a read-only
status page, along with a **Refresh** row that was removed and a poller that
"refreshes about every two seconds, pauses when the page isn't visible, and
stops when you close it" — none of which is true of the live page (1s, never
gives up). Rewritten: the two surfaces and why they differ, the live view's now
playing / transport / volume / signal path, the Material theming, and the
waiting state. `README.html` and `index.html` regenerated.

**Stale comments in the source too** — `Plugin.pm` still justified its dispatch
registration as *"registered here rather than in Settings.pm because Settings.pm
is only required under main::WEBUI"* for a module deleted several builds ago,
and `signalPathFor` claimed **three** surfaces when there are two. `Live.pm`
said the page is *"opened from the settings page with target=_blank"*. All
corrected. The remaining settings-page mentions are deliberate: Live.pm's header
explains why this route exists at all, and `Player.pm:1809` means LMS's own
per-player Audio settings page.

### Bugs looked for and NOT found

Recorded so the next pass does not repeat them: no `each %hash` iteration (safe
against `delete`), no `delete` while iterating anything but a `keys` snapshot, no
`my $x = @_` scalar-context slips, no `return eval {}` in an argument list, no
`$client->{field}` hash access on a blessed ARRAY, and no `setTimer` callback
mis-signature.

709 assertions green (62 + 370 + 63 + 68 + 109). **Not yet tested on the live
LMS.**

## 0.2.72 (2026-09-06): a mute button, and design is signed off

Simon: *"its all worked and looks good, lets just add a mute button as well and
design is complete."*

### One control, one meaning

Material has **no** mute button in its volume widget: it hides that gesture on
the level label (middle-click, or long-press) and shows the muted state by
flipping **both** step buttons to `volume_off`. Undiscoverable, so this adds a
real button in front of the widget.

**Once there is a button, the step buttons have to stop flipping.** Three
`volume_off` glyphs in a row state the muted state three times and leave the
user guessing which one un-mutes it. So:

| control | shows | changes |
|---|---|---|
| mute button | `volume_off` always, **accent-coloured while muted** | mute |
| step buttons | `volume_down` / `volume_up`, **never change** | volume |
| level | the number, **dimmed while muted** | mute (kept - Material's own gesture) |

The dim is Material's own treatment for that label (`'dimmed':muted`). Between
the lit button and the dimmed level the state is unmistakable without any other
control having to change meaning.

**The button and the label share one `toggleMute`.** Two copies of a toggle is
how they drift apart.

Executed against the live payload in both states: unmuted `tbtn vol` /
`np-volv` / title Mute; muted `tbtn vol on` / `np-volv dimmed` / title Unmute;
step glyphs `volume_down`/`volume_up` in **both**; and both the button and the
label send `["mixer","muting",1]` unmuted and `["mixer","muting",0]` muted.

678 assertions green. **Design signed off by Simon at this build.**

## 0.2.73 (2026-09-06): the signal path is three rows

Simon: *"Split processing out into three sections - Filter, Shaper, Processing
Speed."*

They used to be joined by `signalPathFor` into one `processing` string,
`"Filter X - Shaper Y - 30.3x realtime"`, which put the LABELS INSIDE THE VALUE
and left the page a sentence it could not align. Each is its own field now
(`filter`, `shaper`, `speed`) and each gets its own row:

```
Filter             poly-sinc-gauss-hires-lp
Shaper             ASDM7EC-light
Processing speed   2.3x realtime
```

**The joined string is deleted, not kept alongside.** Two ways to say one thing
is how they drift apart, and nothing rendered it any more - the Apps feed draws
only the settings half (mode/filter/shaper), because a speed that changes every
second has no business in a snapshot that can never tick.

`row()` already draws nothing for a fact HQPlayer has not reported, so a missing
shaper leaves no empty label behind. `PLUGIN_HQPLAYER_PROCESSING` is now
"Processing speed"; no key was added or orphaned.

**A stale assertion surfaced doing this.** `t_live.pl` still asserted the page
"stamps a visible time" - and it was PASSING, on the comment that explains the
ticker's removal in 0.2.71. It now asserts the dot instead. That is the second
false pass of this shape and the SIXTH self-matching grep: the new comment
describing the joined string quoted its unit, which the "never re-formats a
server value" assertion greps for.

684 assertions green.

## 0.2.74 (2026-09-06): FOUND - the FLAC header was being prepended to streams that already had one

**BBC Sounds is choppy on this bridge and clean on squeezelite. This is why.**

`Stream::_flacPrelude` synthesises a `fLaC` + STREAMINFO header for a stream
that arrives without one. Its guard was:

```perl
return '' unless $seek && ( $seek->{timeOffset} || $seek->{sourceStreamOffset} );
```

i.e. **any seek at all**. But the two offsets are not alternatives, and only one
of them loses the header:

| | what it is | does the header survive? |
|---|---|---|
| `sourceStreamOffset` | a **byte** position. `Protocols::HTTP::requestString` puts it in the Range header, so the source re-opens PART WAY INTO the container | **No** - this is the case the prelude exists for |
| `timeOffset` | **seconds**. Handed to a transcoder as its start time, or to a protocol handler that fetches from there. The audio is encoded FRESH | **Yes** - a complete container with its own header |

A passthrough seek sets **both**; a transcoded or handler-driven one sets **only
`timeOffset`**. So testing for either prepended a **second** header onto a stream
that already had one - and `_flacPrelude`'s own comment already said what that
does: *"a second one would be read as corrupt audio."*

### How it was pinned down

Simon's test settled the half that mattered: **"iPlayer plays fine in Kitchen."**
A squeezelite player is fed over slimproto - no HTTP, no Content-Type, and it
never sees this header - so a fault appearing only here is in the hand-over.

Then, live, with the station playing:

* `signalpath` -> `source: 48000 Hz / 16 bit FLAC`. **The rate is RIGHT**, which
  killed the previous candidate (a hardcoded 44100 fallback) outright.
* hqplayerd's log: correct init at `Rate: 48000`, `Stream buffer 960000/262144`,
  and **no decoder error of any kind** - it syncs on our header, eats the real
  one as audio, and resyncs.
* LMS's log, at the moment of the play:

```
Stream::_flacPrelude (339) 02:ab:88:42:4c:69: seeked stream -
    prepending a FLAC header (48000Hz 16bit 2ch)
```

* And BBC Sounds **cannot** set the byte offset. Its `ProtocolHandler::getSeekData`
  is `return { timeOffset => $newtime };` - that and nothing else. LMS opens a
  live station at the live edge (`time` was 10281 of 10803), so `timeOffset` is
  set on an ORDINARY PLAY and the prelude fired every single time.

### The fix

```perl
return '' unless $seek && $seek->{sourceStreamOffset};
```

The original case is untouched and still verified by its own test: a passthrough
seek sets both offsets, gets its 42-byte header, and every field is still
asserted. The new control asserts a **time-only** seek gets nothing - which is
the assertion that would have FAILED before the change, so it cannot pass against
a fix that does nothing.

### Two things NOT yet explained

* A duplicate header is ~50 bytes at the START of the stream, so on its own it
  predicts a glitch at the beginning rather than continuous choppiness. If it is
  still choppy after this, that difference is the clue.
* `Stream reader freewheel mode disabled` appears for this stream where a local
  file gets `freewheel mode enabled`. The bridge sends `freewheel="1"` on every
  `PlaylistAdd`, so HQPlayer is turning it off itself - reasonable for live
  content, but it means no read-ahead, and `input_fill` is not currently exposed
  anywhere the page or the log can see it. **That is the next thing to
  instrument** if this is not the whole story.

685 assertions green.

## 0.2.75 (2026-09-06): the live page could starve Material's own Now Playing

Simon, after switching sources with the live page open: *"materials now playing
... didnt update to show the file playing from Qobuz and also when I paused the
BBC stream it was slow to respond to play. It rectified itself with a browser
refresh but ive not seen it do this before."*

**This is a defect this page introduced, and the mechanism reaches outside it.**

### What was wrong

The poller was a fixed one-second repeating timer with **nothing stopping a
second request going out while the first was still open**. A `signalpath` answer
costs a full `status` query per bridge, so as soon as the server takes longer
than a second the polls OVERLAP - and with a 5s timeout several can be open at
once. A command made it worse: it polled straight back, ADDING a request on top
of whatever was already in flight.

### Why that hurts MATERIAL and not just this page

A browser allows about **six concurrent connections per origin** over HTTP/1.1,
which is all LMS speaks. Material holds one of those open permanently for its
**CometD subscription** - that long poll is how its Now Playing learns anything
at all. And the Home tile opens **this page as an iframe INSIDE Material**, so it
is not a separate tab competing at arm's length: same origin, same pool.

A stack of overlapping polls can starve that subscription, and the symptoms are
exactly the three reported - Now Playing stops updating, commands are slow to
take, and a **browser refresh** (fresh connections) clears it.

Modelled with a 2.5s server and a 5s timeout:

```
OLD  repeating timer, no guard    peak concurrent = 3   requests in 20s = 20
NEW  single-flight, chained       peak concurrent = 1   requests in 20s = 6
```

### The fix

One request at a time, and **the period is a GAP, not a cadence**: the next poll
is scheduled only once the last has SETTLED. A tick that finds a request still
open reschedules instead of adding one, and a command now brings the next poll
FORWARD rather than stacking a new one. At worst this page costs one connection.

**"Never gives up" is preserved and now asserted properly**: both outcomes go
through one `done()` which clears the flag, reports, and always schedules the
next - so a timeout reschedules rather than quietly ending the page, which would
have been the settings page's failure with extra steps.

### CONFIRMED by Simon, 2026-09-06

Shipped as a strong hypothesis that could not be proven from the logs - Material's
CometD connection can also drop on its own, so the plan was to watch for a
recurrence with the live page CLOSED. **Simon confirmed the fix worked**, so the
starvation was the cause. The rule generalises beyond this repo and is recorded
in memory as [[plugin-page-shares-material-connection-pool]]: a plugin's own
polling page runs in Material's connection pool - and a Home tile makes it an
IFRAME INSIDE Material - so an unguarded poller starves the subscription its Now
Playing runs on.

### Two stale assertions surfaced

`t_live.pl` required `setInterval(` to be present - correct before, wrong after.
And the new comment naming that call tripped the assertion that it is gone: the
**seventh** time a crude source-grep has matched its own explanation.

691 assertions green.

## 0.2.76 (2026-09-06): the volume level sat outside the card on a phone

Simon, with a screenshot from an iPhone on 0.2.74: *"We have a slight rendering
issue on the UI on iphone, volume level is outside the box."*

**It was not the breakpoint.** The `@media (max-width: 480px)` rule is served
correctly and was applying - measured off the screenshot, the row started at the
left edge of `.np-txt`, which is what `margin-left: 0` does. The fault was flex
SIZING inside the row.

### Exactly one thing may give, and it has to be the slider

A flex item defaults to `flex: 0 1 auto` - **shrink: 1**. So all four buttons
were offering to shrink, and none of them can: an icon glyph is its own content
width. The browser distributes the overflow across items that refuse it, and the
remainder runs off the end of the card.

The slider made it worse: `flex: 1 1 auto` means it STARTS at its intrinsic
width - a range input carries a UA-defined one of about 130px - and then shrinks
only pro-rata, so it stays far wider than the space actually left.

```
viewport 393   card content 345   .np-txt 237
volume row: 3 buttons 78 + gaps 40 + level 29 = 147 fixed

BEFORE  slider ~130 intrinsic -> needs 277 against 237  -> OVERFLOW 40px
AFTER   slider basis 0        -> takes the leftover 90  -> fits exactly
```

The measured overflow off the screenshot was the same order and direction.

**The fix:** `.tbtn { flex: 0 0 auto }` pins every button, and
`input[type=range] { flex: 1 1 0 }` gives the slider a ZERO basis so it takes
precisely what remains. `min-width: 0` stays - it defeats the automatic
content-based minimum a flex item gets.

**And `.np-volv` is now `flex: 0 0 auto; min-width: 2.4em`** rather than a fixed
`2.4em` basis, which would have clipped a three-digit volume. That one had not
been reported yet; it was sitting there.

### What tipped it over

The mute button, added in 0.2.72. Three buttons plus a level need 147px of the
237px that a 96px cover leaves on a 393px screen - the row had been surviving on
very little slack, and one more control spent it.

696 assertions green.

## 0.2.77 (2026-09-06): the volume slider collapsed to a dot in landscape

Simon, screenshot from an iPhone rotated: *"slider disappears into a dot and is
unusable."*

**Same row, same root cause as 0.2.76, different viewport - and that is the
point.** Landscape is about 800px, which is ABOVE the 480px breakpoint, so the
volume box kept its `clamp(160px, 22vw, 280px)` basis:

```
basis 22vw of 800  = 176px
furniture          = 147px   (3 buttons + 4 gaps + the level - NONE of it shrinks)
slider             =  29px   <- a thumb with nothing either side of it
```

`flex-grow` is 0 and `margin-left: auto` eats the free space, so the box never
grows out of it even with room to spare on the line.

**22vw was chosen when this row had FOUR controls.** The mute button in 0.2.72
made it five and nothing re-derived it. 0.2.76 fixed the portrait overflow from
the same oversight; this is the landscape half of the same mistake, and after
that build the note said *"worth me checking that arithmetic next time I add a
control to that row"* - which is exactly the promise a comment cannot keep.

### So the arithmetic is now a test

`t_live.pl` reads the numbers out of the SERVED css - the basis clamp, the button
size clamp, the base font clamp, the level's min-width and the gap - **counts the
buttons in the markup**, and asserts the slider keeps at least 72px at every
width where the row shares a line. Adding a fourth control to that row now fails
a test instead of arriving as a screenshot.

```
the slider keeps a usable width at every shared-line size (worst 103px at 640px wide)
and 0.2.76's own basis would NOT have (29px at 800px wide)
```

The second line is the control: without it the assertion could pass against a
rule that changed nothing.

**The first cut of that guard was itself broken and passing.** It took the
breakpoint from a bare `/max-width: (\d+)px/`, which matches
`.wrap { max-width: 1100px }` long before the media query - so it skipped every
viewport below 1100 and reported its worst case as 203px. Caught only because
the assertion PRINTS the number and 203 was implausible for a worst case. An
assertion that reports a figure is worth more than one that reports a verdict.

Basis is now `clamp(250px, 30vw, 360px)`, and the breakpoint moves 480px -> 600px
so a ~500px screen gets its own full-width line rather than sitting just above
the breakpoint and just below a comfortable shared line.

699 assertions green.

## 0.2.79 (2026-09-09): slow pre-queues stay pre-queues, and album art holds steady

Two intermittent symptoms were reported together: some album and playlist
boundaries took the full load path, and the Eversolo's artwork flashed off and
back on. There was no live playback trace to time in this session — HQPlayer was
offline and LMS's archived log contained discovery only — so this build fixes
the deterministic races visible in the code and adds timing evidence for the
next occurrence rather than claiming a measured live cure.

### A slow `PlaylistAdd` could lose the very pre-queue it was building

HQPlayer fetches and probes a URI before answering `PlaylistAdd`, so an append
can still be in flight when the playing item reaches `state=0`. The end path
only waited when `hqNext->{queued}` was already true — which is set by the
callback that had not arrived. It therefore discarded the pending append and
started the next song as a full Stop/Clear/Add/Play load. That is both the slow
boundary and a credible artwork blank: HQPlayer temporarily has no playlist
item while the clear/re-add runs.

An unresolved pre-queue now gets the same bounded `END_GRACE` (3s) already used
for an acknowledged append. A refusal or a genuinely slow origin still falls
back after the deadline; normal playback no longer converts a near-complete
append into the expensive recovery path.

### Superseded loads no longer sit in front of the current one

Every track command is tagged with a `track` scope. `_newGeneration` advances
the generation first and then removes older commands that are still waiting in
the control queue, invoking their callbacks as superseded. This matters when a
skip or playlist edit arrives behind a slow append: stale Stop/Clear/Add/Play
work no longer runs before the load the user actually requested.

The command already on the wire is deliberately not cancelled. HQPlayer permits
one request in flight and tearing down that socket to interrupt a media probe
would also discard reply framing, status subscription and ordering. What can be
cancelled safely is cancelled; the unavoidable in-flight time is now visible.

Every `PlaylistAdd` taking at least one second logs one line splitting total
latency into **control-queue wait** and **HQPlayer/media-probe time**. It does not
log the URI, so signed service URLs are not exposed. The next live slow load can
therefore be assigned to the bridge queue or to HQPlayer/the origin instead of
being inferred from the audible pause.

### The next track no longer changes the current track's tier early

Resolving an armed item called `_resolveURL`, which writes `hqTier`, before the
item had handed over. The player could therefore describe the current song as
the next song's tier for minutes. The resolver's result is now stored on
`hqNext`; the current tier is restored immediately and the next tier is promoted
only when `_handedOver` confirms the transition.

### Artwork has a narrow continuity rule

Remote metadata can briefly omit its cover while the protocol handler refreshes.
Sending that omission replaces a valid picture with no picture at all. The
bridge now remembers the artwork of the last item HQPlayer accepted and reuses
it only when the new item's non-empty album name is an exact match. A different
album, or an item with no trustworthy album identity, still sends no cover — so
radio art and unrelated playlist items cannot inherit stale artwork merely to
avoid a blank.

The same cached pair is promoted with a pre-queued hand-over. It is
deliberately retained across a full-load generation so another track from that
album can use it. Tests cover same-album reuse, refusal across albums and
unknown albums, current/next tier separation, pending-append grace, command
scopes and cancellation order.

### What the anchor is keyed on, and the two ways the first cut got it wrong

The continuity cache above was first written as **two parallel accessors
(`hqAlbum`, `hqArtwork`) written at three sites**, with the storage rule stated
at none of them. One concept on four carriers, and it failed in both of the
ways that shape always fails. Neither fault ever reached a release — 0.2.77 is
the last tag and the review that found them ran before this build left the
working tree — but they are recorded because the SHAPE is the lesson:

* **The anchor was overwritten with an empty pair.** `hqTier` was guarded on
  `defined`; the album and cover were not. A pre-queued item whose handler
  cache was still cold carries `album=''` and `cover=''`, so it wiped the
  anchor — and the *next* cold append then had nothing to fall back on and sent
  no cover at all, which is the exact blank the feature exists to prevent. The
  same wipe reached it from `_handedOver` and from `_metadata`'s early return,
  which leaves `%item` unpopulated and stored `undef`.
* **Reuse was keyed on the album NAME alone.** Two different albums sharing a
  title — *Live*, *Greatest Hits*, anything self-titled — compared equal, so in
  a mixed playlist one artist's cover was written into another's `PlaylistAdd`
  and stayed for the whole track. That contradicts the invariant the comment
  directly above it claimed.

Both are now structural rather than remembered. The concept lives on **one
carrier, `hqArt`** (`{ id, album, cover }` or undef), it is written **only**
through `_rememberArt` and read **only** through `_reusableArt`, and the
storage rule lives inside the writer: a pair without a non-empty cover *and* an
identity to key it on is ignored, **leaving the existing anchor standing**. A
stale anchor cannot cause the opposite fault, because the reader only ever
hands it back for the same album.

The key is the album, **not the artist**. Keying on the artist would look
stricter and would break the case the feature is for: on a compilation the
track artist changes from track to track while the album does not, so every
hand-over inside a Various Artists album would decline its own cover. What
tells two same-named albums apart is the **album id**, which `_handlerMeta` now
carries off the hash `getMetadataFor` already returned — `albumId` on Qobuz,
`album_id` on Tidal (verified 2026-07-25 from each plugin's source). This is
not a reach into plugin internals; it is one more key alongside the four
artwork keys already read there, and it never goes on the wire.

| both sides have an album id | ids must be equal |
|---|---|
| either side has none | album names must be equal and non-empty |
| neither has an identity | no anchoring, no reuse — radio cannot inherit art |

Deezer and Spotty flatten their album to a title before the bridge ever sees
it, so they take the name row. **The residual risk is stated, not hidden:** on
an id-less service, two *adjacent* items sharing an album title can still
inherit each other's art. That was the accepted trade — the alternative
(matching the artist too) blanks the cover on every id-less compilation, which
is the more common case by far.

The stale source comments and this file's contradictory gapless recipe were
also corrected: HQPlayer supports query strings, and the safe mid-playback
append is `queued="0"`, not `queued="1"`.

732 assertions green (67 + 395 + 64 + 73 + 133), called-vs-defined sweep clean.
**Not yet tested on the live LMS — HQPlayer was offline while this build was
made.**

## 0.2.80 (2026-09-10): the two ways 0.2.79's own fixes could still lose the thing they protected

A review of the 0.2.79 working tree raised two findings against the code that
build had just written. Both were real, both were reproduced in the offline
suite before anything was changed, and both are the same shape: a rule that is
correct inside the case it was written for, applied one step outside it.

**Neither has been run against a live daemon.** HQPlayer was not available in
this session. What follows is verified by `t_player.pl` driving the real subs,
with a control assertion on each so the test cannot pass against a build that
does nothing.

### A refused pre-queue was dropped by the grace period 0.2.79 gave it

0.2.79 extended `END_GRACE` to an append that had not acknowledged yet, because
`PlaylistAdd` makes HQPlayer fetch and probe the media before replying and the
playing item can reach `state=0` inside that window. That is right. What it did
not cover is the other thing that can arrive in the same window: **the refusal**.

`_appendTrack` answers `result="Error"` by demoting the item to a held load
rather than reporting a failed load, on the stated promise that *the ordinary
load runs at end of track*. When the refusal lands inside the grace period, the
end of that track has already happened. `_endOfStream` then cleared `hqNext` and
reported the end of the playlist — over a song LMS had handed over a track
earlier and was still streaming. **One refused append stopped an album mid-way.**

Nothing recovered it. The held-track branch in `_onStatus` needs a fresh
`state=0`, and a stopped instance says nothing at all until the watchdog speaks
`STATUS_WATCHDOG` (10s) later, long after the 3s timer has fired.

`_endOfStream` now loads a demoted hand-over at expiry and reports nothing to
LMS, exactly as the tier 4 held-track branch in `_onStatus` already does. A load
that cannot run is not silent either — `_queueTrack` answers a missing control
link with `_loadFailed`, and a second refusal is reported properly there, which
is the entire point of demoting to a load instead of failing at append time.

**The trigger is a reply, not a timeout.** `REPLY_TIMEOUT` is 30s and cannot
land inside a 3s grace; only `result="Error"` arrives fast enough. The finding
as reported offered "the expiry or the failure callback" as the place to fix it.
**Only the expiry is correct**: at demotion time the current track is normally
still playing, and loading from the callback would cut it off — which is the
exact thing that callback's own comment refuses to do.

### An album id is not a global identifier, and neither is a title

The artwork anchor from 0.2.79 tells two same-named albums apart by the album
id, and `_artMatch` returns on the id **before** it looks at the name. Within
one service that is sound, and that is the case it was written for. Across two
it is not: Qobuz's `albumId` and Tidal's `album_id` are unrelated numbering
schemes, so an id shared by chance overrode even a different album title and one
service's cover landed on another service's album.

The name half collides far more easily, and it was already written down as the
feature's "residual risk": Deezer and Spotty publish no id at all, so **any**
album title shared across two services matched on the name alone.

The identity now records the **url scheme**, and a difference is a veto ahead of
both tests. It costs nothing, it is already on the track, and it is stable
across an album because an album is served by one service — so the Various
Artists case the album key exists for is untouched. The veto applies only when
both sides name a service, the same shape as the id rule and for the same
reason: an anchor with no service recorded is not evidence of a *different* one.

A detail worth keeping: the old fixtures had been writing `qobuz:111` into the
id field. **The tests had been describing a namespace the production path never
applied** — which is why a test suite this size did not catch it.

### What the two findings have in common

Both fixes are one branch each, and both were found by asking what happens one
step outside the window a rule was written for. 0.2.79 wrote the grace period
for a *slow* append and the anchor for a *single service*, and each was right
about that. The failures were the neighbouring case in the same code, arriving
by a route nobody had walked.

Both tests carry a control assertion, because both fixes are of the kind that
passes trivially: an end-of-stream test passes against a build that loads the
track *and* wrongly tells LMS the playlist ended, and an artwork veto passes
against a build that has simply switched artwork reuse off. The tests assert
what must **not** happen alongside what must.

## 0.2.81 (2026-09-10): a stop is not the end of the playlist, and HQPlayer says which is which

0.2.80 fixed a REFUSED pre-queue being dropped at the end of a track. Simon read
that fix and asked the harder question underneath it: *"we should not be sending
end of playlist unless last track is reached, basing it on a duration seems
wrong."* He was right, and the answer came off the wire rather than out of the
code.

### What HQPlayer actually sends, measured rather than assumed

Captured raw off port 4321 across every transition type, ~1000 pushes. The full
`<Status/>` attribute set is confirmed against Signalyst's own parser
(`hqp-control-601-src/ControlInterface.cpp`, in this repo): `state`, `track`,
`track_id`, `min`, `sec`, `volume`, `clips`, `tracks_total`, `track_serial`,
`transport_serial`, `queued`, `position`, `length`, `begin/remain/total_min+sec`,
`output_delay`, `apod`. The bridge had been parsing five of those.

**The original comment was right about the hard part.** A boundary push and an
end-of-playlist push really are indistinguishable - both send `state="0"
track="0" tracks_total="0"` with position, length and the metadata child all
gone. Nothing in that message separates them. The debounce is therefore a fair
way to ask "did playback resume", and it stays.

**But two fields that looked like the answer are not.** `tracks_total` is
HQPlayer's own accumulated list, not the playlist: it read **3** while LMS's
`playlist_tracks` read **11**. And `track_serial` is not an advance signal - it
stepped at the end of a ONE-track list where nothing followed. Both are recorded
as declined in the Review Ledger so they are not proposed again.

**What `track_serial` really counts is playlist-cursor advances**, and that IS
the useful question:

| event | track_serial |
|---|---|
| track started | 4 → 5 |
| gapless boundary | 2 → 3 |
| end of the playlist | 3 → 4 (past the last item) |
| pause, then resume | 5 → 5 |
| stopped 12s into a track | 5 → 5 |
| stopped 35s into a track | 1 → 1 |

So at a stopped push: **cursor unchanged means the track was ABANDONED, cursor
moved means it RAN OUT.** That is what HQPlayer knows. Whether a track that ran
out was a boundary or the end of the list is **LMS's** to answer, and it already
has: a pending `hqNext` exists only because LMS resolved a next track.

### The three outcomes, each answered by whoever actually knows

* **Cursor unchanged** - a stop nothing on our side asked for, part way through a
  track. Now followed into LMS as a STOP, the way the paused branch already
  follows an outside pause, with the wanted state set first so the controller
  calling back into `stop()` cannot bounce. The playlist is left intact. This
  case previously had NO handling at all.
* **Cursor moved, hand-over pending** - a boundary. Keeps the bounded grace,
  because "did it resume" is exactly what the grace is good at. On expiry it now
  LOADS the held track instead of reporting the end of the playlist. 0.2.80 did
  this only for a refused pre-queue; an accepted one that HQPlayer never entered
  fell through to the end-of-playlist report.
* **Cursor moved, nothing pending** - the genuine end. Reported immediately, no
  timer, exactly as before. This path was always correct and is untouched.

**Nothing already heard is ever restarted.** The held item has never played -
that distinction is the entire licence for loading it, and it is why a stalled
track is followed as a stop rather than reloaded.

### The bug, seen in the wild before it was fixed

20:47:59, track 5 of an 11-track playlist, track 6 already queued and
acknowledged: `end of playlist [playing=PLAYING streaming=STREAMING]`. HQPlayer
simply stopped sending status mid-track; whatever ended it, the playlist had ten
more tracks and one of them was already queued, so the right report was a stop
and end of playlist was never available as a correct answer. Four grace arms were
observed that evening - three cancelled by a normal advance, and the single one
that expired was wrong.

### A test that asserted the defect

`t_player.pl` REQUIRED the old behaviour: "a stop that stays stopped IS reported,
once the grace period expires", with the queued track dropped. That is the
defect, written down as an expectation. Its real intent - a stop at HQPlayer's
own front end must still be reported - is now served by the cursor test, and
served faster and without the timer. It is replaced by two cases, each with a
control assertion.

### What is NOT established

Every stop measured was one the BRIDGE caused, and those never reach this branch
because `hqExpectStop` already covers them. The inference to an uncaused stop
rests on the cursor being a property of HQPlayer rather than of who asked for the
stop. The abandoned-track rule rests on two observations. And a stop initiated at
HQPlayer's own front end remains unobserved - on this rig everything is driven
from LMS, where "stop" means clearing the playlist.

## 0.2.82 (2026-09-10): the two ways 0.2.81's own answers could still be asked in the wrong order, or of the wrong track

0.2.81 introduced the playlist cursor as the discriminator for a stop, and a
branch that reloads a hand-over HQPlayer never entered. Both were right. Both
were reachable in a state their author had not considered.

Neither was observed live. Both were traced in code, reproduced offline, and
pinned by tests that FAIL against 0.2.81 and pass against this build. Simon's
own live stop test the same evening — stop and pause at HQPlayer's front end,
then a restart from LMS — behaved correctly throughout, and the first finding
below explains why it could not have reached the defect.

### The cursor test has to run BEFORE the held-track branch

`_onStatus`'s `HQP_STOPPED` arm had these in order:

1. start-up noise (`age < START_GRACE`) — unchanged, still first
2. **a held tier 4 track: load it, this is the end of the track**
3. **the cursor did not move: the track was abandoned, follow the stop**
4. a hand-over is pending: wait `END_GRACE` and see

Step 2 does not read the cursor. So a stop made at HQPlayer's own UI, part way
through a track, with a tier 4 track already held, was answered by starting the
next track. The listener presses stop and the music carries on with the next
song.

**Why it never showed up in testing.** The hold is written in exactly one place,
`_handOver`, and only when the NEXT track resolves to tier 4 while the current
one is on tier 1, 3 or 5. Tier 4 is now only a genuinely REMOTE track — a local
file of any format is tier 3 — so it needs a streaming track that could not be
direct-streamed, queued behind a local one, and the stop must land after LMS
handed it over, which is the last stretch of the current track. Simon's live
test was tier 1 throughout and had nothing held.

**The fix is a reorder**, 3 above 2, with no change to either branch. It is safe
in that direction and the reason is the measurement in §0.2.81: a track that
RAN OUT steps the cursor. So at a real end of track `cursorMoved` is true, the
abandoned test abstains, and the held load runs exactly as before. Only a stop
with a still cursor overtakes it. An engine that reports no `track_serial`
cannot enter the abandoned branch at all, so old daemons are untouched.

### "The held track has never played" is `_handedOver`'s answer, and it can be wrong

0.2.81 widened the expiry branch from a REFUSED pre-queue (`mode 'load'`) to an
accepted one HQPlayer never entered (`mode 'queue'`), on the stated licence that
"either way the held track has NEVER PLAYED". That licence is `_handedOver`
returning 0, and `_handedOver` is deliberately conservative — it would rather
miss an advance than invent one, because **a spurious advance is the worst
failure in the file** and is not self-correcting. Its three ways of missing one
are written into its own comments:

* it returns 0 before `acked`, so an ack that never arrives blinds it entirely
* a uri that does not match is a **VETO**, not a hint
* on tier 5 every reported uri strips to the same `.../file`, so the index is
  the only evidence, and it must strictly INCREASE from a non-zero baseline

An advance that trips one of those leaves `hqNext` set on a track HQPlayer is
playing. It plays to the end, reports the end of its list, the grace timer arms
because a hand-over is still pending, and the expiry loads the track the
listener has just finished hearing.

### The discriminator, and why it is NOT row 38 coming back

Row 38 disproved the cursor as a way to tell **a track boundary from the end of
the playlist**. That question is not asked here. The question here is **how many
times the cursor has moved since the append**, which is precisely what row 38's
own measurement established that it counts — the step past the final item
included:

| what happened to the queued item | advances since the append |
|---|---|
| never entered; HQPlayer stepped past the end of its list | **1** |
| entered, played through, then the end of the list | **2** |

So `_appendTrack` now stamps `serial => $self->hqTrackSerial` onto the held
item, and `_endOfStream` loads it only when the cursor has moved at most once
since. Two or more means the listener has already heard it: report the end of
the stream and let LMS move on.

**Undef on either side loads, as before.** The failure actually seen in the wild
is an album stopping mid-way (§0.2.81, 20:47:59, track 5 of 11), so an engine
that does not report the field must keep 0.2.81's behaviour rather than gain a
guess.

### The tests, and the controls that stop them being vacuous

Six assertions in `t_player.pl` FAIL against 0.2.81's `Player.pm` and pass
against this one. Nine more pass against BOTH, deliberately — they are the
controls, and without them a guard that refused every reload, or an ordering
that followed every stop, would still look green:

* one advance still LOADS the held track — the §0.2.81 live case, unchanged
* no cursor reported anywhere still loads, exactly as before the guard
* a held tier 4 track still loads at a REAL end of track (cursor moved)
* and that end is not mistaken for a stop

The missed advance is modelled the way it actually happens rather than by
poking numbers: the cursor steps 7 → 8 while the pushed uri is the one HQPlayer
just LEFT, so the veto in `_handedOver` answers "not yet" and the hand-over is
still pending when the track ends at 9.

`sh tools/run_checks.sh`: 759 assertions across five suites, 0 failed, sweep
clean.

### CLOSED 2026-09-10: the reorder is confirmed live, the guard is closed unprovable

**The reorder — CONFIRMED LIVE, 23:38.** It took three attempts to reach, and the
two failures are the useful part: Qobuz is **tier 5** and a local file is **tier
3**, so neither can ever produce the hold. The branch needs a service that
DECLINES the direct hook, and per the verified table above that is **Deezer**.
Local track playing, Deezer queued behind it:

```
23:36:56.447  tier 1 (native passthrough) .../music/537912/download.flac
23:37:59.529  tier 4 (plugin stream endpoint) .../hqp/02-ab-88-42-4c-69/1.flac
23:37:59.529  the next track is tier 4 - holding it for a normal load at end of track
23:38:26.658  stopped outside LMS part way through the track - following
```

The stop landed 27s into the hold window, `streaming=STREAMING` — LMS was still
feeding the local track, which is the mid-track abandonment the cursor test
exists to recognise. **The verdict is the line that is ABSENT**: on 0.2.81 the
next entry would have been `end of track - loading the tier 4 track LMS handed
over early`. Nothing loaded afterwards; the only later activity is the idle
watchdog. Done.

**The guard — CLOSED, and deliberately not "pending".** It cannot be provoked
from outside. Every route into it requires `_handedOver` to fail spontaneously,
and no playlist, service or transport action can force that: the ack either
arrives or the link is down (which clears `hqNext` anyway), and the uri either
matches or the track is genuinely a different one. **Simulating it needs a
DEBUG BUILD that breaks the check on purpose** — see below — which proves the
guard's arithmetic, something `t_player.pl` already proves more cheaply.

**So the guard reports itself instead.** When it suppresses a reload it logs:

```
the hand-over was entered after all (cursor N -> M) - not reloading it
```

That line appearing in the wild IS the measurement, and it is the only honest
one available. If it never appears, the case never happens and the guard costs
one comparison. **Do not reopen this as an open question** — grep the log for
that phrase and let the answer arrive.

### If it ever needs simulating anyway

Three ways, in order of faithfulness. All need a temporary build; none can be
done from the wire.

1. **Poison `want` after the append.** In `_appendTrack`, store a deliberately
   wrong `url` on `hqNext` while sending the REAL one to HQPlayer. The gapless
   advance then genuinely happens and every `_handedOver` check answers "not
   yet". Use two LOCAL tracks: tier 1 urls are unique, so the uri veto is the
   discriminator and nothing else interferes. Expected on 0.2.82: at the end of
   track 2, `the hand-over was entered after all (cursor N -> N+2)` and end of
   stream. On 0.2.81: **track 2 plays a second time.**
2. **Swallow the ack.** Ignore the `PlaylistAdd` reply so `acked` never sets.
   Faithful to route 1, but `_handedOver` then returns at its first line, so it
   tests less of the sub than (1) does.
3. **Starve the index.** Only reachable on tier 5, where the stripped uris are
   identical and the index is the only evidence: clear `hqTrackNo` just before
   the advance so `$seen` is undef. The narrowest route, and the least like
   anything that happens by itself.

(1) is the one worth doing if the self-reporting line ever shows up and the
arithmetic needs confirming against real audio rather than the harness.

## 0.2.83 (2026-09-11): a housekeeping pass - one dead sub, and a vendor copy kept twice

No behaviour change. A sweep for stale code and dangling references across the
plugin, the tools and the docs, run against the three gates. Two things were
worth removing; everything else the sweep touched was already correct and is
listed below so the next pass does not repeat it.

### `_completeResponse` was dead, and only its own test kept it alive

`Control.pm` carried two framers. `_extractMessage` is the live one, called from
`_readable`, and it takes ONE message at a time off `rbuf` - which is the whole
reason it exists, because a subscribed read delivers several concatenated.
`_completeResponse` answered a different question ("is this buffer one complete
element?"), came in with the initial commit, and **nothing in the plugin has
called it since `_extractMessage` landed**. It survived because `t_control.pl`
exercised it directly through a code ref, so the called-vs-defined sweep in
`run_checks.sh` could not see it: that sweep greps for
`Plugins::HQPlayerBridge::<Mod>::<fn>` spelled out in the `.pm` files, and a
test-only caller is not in one.

Removed, with its comment block. Of its seven assertions, five duplicated cases
`_extractMessage` already covers (self-closing root, truncated mid-attribute,
nested with and without a close tag, declaration only) and went with it. **The
other two were kept and re-pointed at the live framer** - they check that a REAL
captured `<Status/>` payload and a real `result="Error"` reply frame cleanly,
which is worth having, and it is worth having against the code that runs. Each
now frames a COPY of its string: `_extractMessage` consumes the buffer it is
given, and both originals are read again afterwards by `parseAttrs`.

The suite went 67 -> 62 assertions, which is exactly the five. The other four
suites are untouched at 422, 64, 73 and 133.

### The vendor source was committed twice

`hqp-control-601-src/` and `hqp-control-601-src.zip` held identical file lists,
and the two references pointed at different copies - `Control.pm` cited the zip,
`README.md` the directory. Git already versions the directory, and it is
committed unpacked precisely so it can be grepped. The zip is deleted and
`Control.pm` now points at the directory.

**The MIT obligation is unaffected**, and the note above that said so has been
corrected rather than left to rot: `COPYING` travels in the directory, which is
the copy that remains. Re-verified on this build that the shipped plugin zip
contains no vendor code at all (zero matches for `hqp-control`, `.cpp`, `.hpp`
or `COPYING`).

### Checked and already correct - do not re-report these

The sweep covered more than it changed. All of the following came back clean and
are recorded so a later pass can skip them:

* **String keys** - no orphans in `strings.txt`, and nothing referenced from code
  that the file lacks. Both directions.
* **Unused constants and unused imports** - none, in any of the six modules.
* **Timer balance** - every `setTimer` has a matching `killTimers`. `_teardown`
  looked exposed (it kills only the watchdog, leaving `_startDeadline`,
  `_tripStop`, `_endOfStream` and `_fadeDone` armed on a client about to be
  forgotten) but is **already guarded**: `controller->stop` reaches the player's
  own `stop()`, which calls `_newGeneration` and clears `hqStarted`, so the
  gen-guarded pair drop out at `_superseded` and `_endOfStream` returns at its
  `hqStarted` test. Writers are real - an instance going quiet, and DHCP moving
  one - so the guard is what makes this a non-finding, not the reachability.
* **Volume arithmetic** - both divisions are guarded. `_dbToLms` returns 100 on a
  zero span; `_volQuantum` returns 1/256 on a non-positive step and can never
  reach zero.
* **The live page escapes everything it interpolates** - track metadata through
  `textContent`, every card value through the page's own `esc`. No injection
  path from a service-supplied title.
* **Comment references to `_getNextTrack`, `_readNextChunk` and `_stopClient`**
  are LMS core symbols, correctly attributed. They are not stale plugin refs.
* **`PlayNextURI` in `%KNOWN`** - looked like the allowlist permitting the one
  command documented to kill the daemon. It is deliberate, and the entry above
  says why: `tools/probe_gapless.py` re-tests it on a future engine behind a
  default-off arm. Confirmed the probe still carries that arm.

## 0.2.84 (2026-09-11): the local cover went out at whatever size it was stored

Simon, on the endpoint: *"i dont think Eversolo likes artwork larger than
600x600 as it might have impact on memory."* He was right, and the bridge was
asking for no size at all.

### What was actually being sent

`_coverURL` built the local route as `/music/<coverid>/cover.jpg`. **A bare
`cover.jpg` serves the STORED ORIGINAL** - LMS resizes only when asked, and
nothing here asked. Measured against the live library 2026-09-11, sampling 50
random albums:

| | dimensions | bytes |
|---|---|---|
| largest local cover in the library | 3000x3000 | 8.33 MB |
| the same cover at `cover_600x600_o` | 600x600 | 36 KB |
| a non-square original (1000x986) | 600x591 | 141 KB |

HQPlayer hands that URL to the endpoint's display, so the endpoint is what has
to hold it. Nothing downstream ever wanted the original.

### The mode letter is not decoration

Tested all of them against a NON-SQUARE cover, because that is where they
diverge and a square test would have shown nothing:

* `_o` - fits inside the box, aspect preserved, no padding. **This one.**
* `_m` / `_p` - pad to a forced square with black bars. Also measured **six
  times larger** than `_o` on the same source (863 KB vs 141 KB).
* `cover_600` with no `x<height>` - **silently serves the original.** It looks
  like a cap, returns 200, and caps nothing. This is the trap worth remembering.

LMS resizes on demand and caches, so the cost is one resize per album, once.

### The number has ONE carrier

`ART_SIZE` in `Player.pm`, next to the artwork notes. The size is now a single
constant rather than a string baked into the URL, so there is one place to
change it if 600 turns out to be the wrong ceiling. **The Eversolo limit is
Simon's read, not a measured figure** - it has not been confirmed against the
device, and if it is ever measured, `ART_SIZE` is the line to edit.

### THE REMOTE ROUTE IS DELIBERATELY UNTOUCHED

A remote track's cover is the service's own URL and goes out verbatim. Qobuz
already serves 600 (confirmed live: the currently playing item was
`..._600.jpg`, 600x600 / 99 KB). **The other services are NOT checked**, and
capping them means either rewriting a service URL - which differs per service -
or pushing it through the image proxy. That is a bigger change than this one and
was scoped out, not overlooked. If an endpoint ever chokes on a remote cover,
this is the paragraph that says where to start.

### THE SECOND CARRIER, LEFT ALONE ON PURPOSE

`Plugin.pm`'s `nowPlayingFor` builds its own local cover URL for the live page
(`$np{artwork} = "/music/$cover/cover.jpg"`), and it is STILL UNBOUNDED. That is
a deliberate divergence, decided 2026-09-11: **its consumer is a browser, not
the endpoint**, so the memory argument that motivated this change does not apply
to it. Recorded here so the next sweep reads it as a decision rather than drift.
Capping it would be a bandwidth optimisation for the page, nothing more.

### The tests pin the traps, not just the happy path

Three assertions in `t_player.pl`, and each was confirmed to FAIL against the
form it is guarding - the fix was reverted three ways and the suite re-run each
time, rather than trusting that a passing test means anything:

* the unbounded `cover.jpg` - caught by two assertions
* the bare-width `cover_600.jpg` - caught, and this is the one that would
  otherwise have shipped looking correct
* the padding mode `cover_600x600_m.jpg` - caught by its own assertion

The suite is 425, up 3.

## 0.2.85 (2026-09-11): the cursor stamp was one low on every hand-over but the first

0.2.82 stamps `serial => $self->hqTrackSerial` onto the held item in
`_appendTrack` and has `_endOfStream` reload it only when the cursor has moved
**at most once** since. The arithmetic is right. The value it was reading was
not.

### `_handedOver` runs ABOVE the store, and the append happens inside it

`_onStatus` called `_handedOver` roughly fifty lines above
`$self->hqTrackSerial($serial)`. `_handedOver` ends by calling `_armNextTrack`,
which calls `playerReadyToStream` — and for a LOCAL track LMS answers that by
re-entering `play()` **synchronously**, so `_appendTrack` runs inside the very
push whose cursor has not been stored yet. The append therefore stamped the
PREVIOUS cursor, one low.

Only the FIRST append of a run was right, because that one is armed from the
PLAYING branch, which sits BELOW the store. Every append chained off a
hand-over — track 3 onward — was stale.

### The carrier, named from LMS's own source rather than from our comment

`_armNextTrack`'s comment already asserted the synchronous re-entry, but a
comment is not the contract. The chain was walked in the real LMS tree
(`public/9.0`), and every step is a direct call with no timer:

```
playerReadyToStream -> _eventAction('ReadyToStream')      StreamingController.pm
  -> PLAYING row -> _NextIfMore -> _getNextTrack
  -> $song->getNextSong(successCb)                        Song.pm
     -> local file has no scanUrl and no getNextTrack,
        so it falls to "the simple case": &$successCb()   <- called INLINE
  -> _nextTrackReady -> _eventAction('NextTrackReady')
  -> PLAYING/TRACKWAIT -> _StreamIfReady -> _Stream
  -> $player->play(\%params)
```

**So the writer is LMS itself, on any local album.** It is not reachable by
hand-built input only.

**Tier 5 is NOT affected.** A streaming service's handler DOES implement
`getNextTrack`, which returns and calls back later, so the append lands after
`_onStatus` has returned and the store has already run. Tier 4 never pre-queues
at all. The defect is tier 1 and tier 3, which is to say local files.

### What it actually cost

Nothing during playback. The stamp is read in exactly one place, the `played`
test in `_endOfStream`, and that runs only when the END_GRACE timer fires. At an
ordinary gapless boundary HQPlayer does emit a zeroed state-0 push and the timer
IS armed, but the next PLAYING push cancels it about 2s later, inside the 3s
window. Gapless never reads the stamp.

It cost the 0.2.82 fix itself. When the timer does fire — the 20:47:59 case,
queued-but-never-entered — the difference came out as 2 instead of 1, so the
guard declared the held track already played and reported the end of the
playlist. That is precisely the mid-album stop 0.2.82 exists to remove:

| where the stop lands | 0.2.82 behaved as |
|---|---|
| end of track 1 | fixed — the held track loads |
| end of track 2 onward | 0.2.81 — end of playlist reported |

The stamp is low by exactly one, never more, so past the first boundary the
guard suppressed the reload **every** time rather than occasionally.

The failure direction is bounded: a stale stamp can only make the difference
LARGER, so it can only ever suppress a reload. It can never cause a spurious
one, and no track can be replayed by it.

### Nothing released was ever affected — `main` ships 0.2.77

The cursor arrived in 0.2.81 and the guard in 0.2.82, both unreleased. Judged
against what `main` ships today this is a dev-branch defect caught before it
reached anyone.

### Why five suites and 759 assertions did not see it

`t_player.pl`'s `LoadController` answers `playerReadyToStream` through AUTOLOAD:
it records the call and returns. So every existing block calls `play()` by hand
AFTER `_onStatus` has already returned, which is after the store. The chained
shape was structurally unreachable, and the one shape the suite exercised was
the one that happened to be correct.

### The fix, and the control that stops it being the guard switched off

The cursor read, the `$seenSerial` capture, the `$cursorMoved` comparison and
the store all move together to ABOVE the `_handedOver` call. `$seenSerial` and
`$cursorMoved` are still taken before the store, so the stop classification is
untouched.

`ChainController` re-enters `play()` the way LMS does. Three assertions fail
against the pre-fix file and pass after; six more pass against BOTH and are the
controls:

* the chained append stamps 8, not 7 — **fails before**
* one advance loads the held track — **fails before**
* and does not report end of playlist — **fails before**
* TWO advances still suppress the reload, so the guard is intact — control
* the end of the stream is still reported there — control
* a stop that left the cursor alone is still followed as a STOP — control
* not as the end of the playlist, and nothing loads over it — control

`sh tools/run_checks.sh`: 766 assertions across five suites, 0 failed, sweep
clean.

### One consequence for row 109's self-reporting claim

Row 109 closed the guard as unprovable from outside and left it to report
itself, treating `the hand-over was entered after all (cursor N -> M)` in a live
log as the measurement. With the stale stamp that line would have fired on
ORDINARY chained hand-overs, so it would have read as confirmation of a case
that never happened. The line is only trustworthy as evidence from this fix
forward.

## BBC Sounds ("iPlayer") choppy playback - what is established

Reported 2026-09-06: *"iPlayer doesnt play correctly ... they sound choppy and
like its a sample rate mismatch somewhere as to how its transcoded. I believe it
uses DASH or HLS."* **NOT diagnosed.** Recorded so the next session does not
re-derive it.

### The chain, from source

The plugin is **expectingtofly's LMS_BBC_Sounds_Plugin**, installed here as the
`bbcsounds` radio app. Its `ProtocolHandler.pm` confirms Simon's guess:

* It is **DASH**, not HLS - it parses an **MPD manifest** (`getMPD`).
* The audio is **AAC**: `push @allowDASH, ([ 'audio_eng=320000', 'aac', 320_000 ]...)`,
  and `contentType` answers that format.
* It reports the rate it read from the manifest -
  `samplingRate => $selRepres->{'audioSamplingRate'}` - which for BBC content is
  **48 kHz**. Fragments go through its own `M4a.pm`.

Its URLs are `sounds://_LIVE_bbc_radio_fourfm` - a **custom protocol handler**,
so there is no URL HQPlayer could ever fetch itself. That rules out tiers 1, 3
and 5 by construction: it is **tier 4**, LMS's own player stream on the plugin's
endpoint.

### What the bridge does on that path - and does not

`formats` is `flc pcm aif mp3`, so **LMS must transcode AAC to FLAC**; HQPlayer
never sees AAC (it has no decoder for it at all). Tier 4 then serves whatever
`$song->streamformat` already decided - `_contentType` READS that, it does not
choose. **There is no format selection, no rate logic and no resampling anywhere
on this path**, so the bridge has no code that could produce a rate mismatch.

What it CAN do is make a **framing** fault audible, and this repo has already
been bitten by exactly that: HQPlayer does not de-chunk, and a chunked transcode
made tier 3 produce `ReadFLACErrorCB(): lost sync / unparseable stream / CRC
error` - which sounds like choppy audio, not like an error. Tier 4 sends
`Connection: close` with no `Content-Length`, which should terminate by close
rather than chunk, but that has not been VERIFIED on this path.

The one thing the bridge does that no other player does is `initBitrateLimit`,
which sets `maxBitrate` to 0 (unlimited) when the pref was never set - so this
player gets FLAC where a capped player would get MP3 320.

### Upstream evidence

The plugin's own wiki documents this symptom class and ties it to the rate:
*"Most BBC content is in a 48000 sample rate. If your player is having problem
with the (slightly) unusual sample rate of 48000, try selecting the 'hide sample
rate from LMS' in the BBC Sounds preference settings."* **That preference is not
in the current source** (no sample-rate string in `strings.txt`), so it looks to
have been removed - the wiki may be stale. Issue #134 ("stuttering sound") is
open and unresolved, reported on a **Squeezebox Radio** - i.e. with no bridge
involved.

### UPDATE 2026-09-06: it IS the bridge, and two causes are now RULED OUT

Simon ran the test: **"iPlayer plays fine in Kitchen."** A squeezelite player is
fed over slimproto - no HTTP, no Content-Type, no synthesised header, and it is
told the format out of band - so a fault that appears only on this bridge is in
the HTTP hand-over, not in the plugin or the AAC->FLAC transcode.

**RULED OUT - chunked framing.** This was the leading hypothesis, because
HQPlayer does not de-chunk and that is exactly what garbled tier 3. It is wrong:
tier 4 does not go through `addHTTPResponse` at all. It stringifies its own
headers and calls `Slim::Web::HTTP::addStreamingResponse`, which is LMS's raw
streaming path - the same one `/stream.mp3` uses - and never chunks.

**RULED OUT - decoder failure.** hqplayerd's own log for 2026/09/05 19:47 to
2026/09/06 12:36 carries **no** `ReadFLACErrorCB`, no `lost sync`, no CRC error
and no `not available`. If the bytes were being mis-framed the decoder would be
screaming, and it is silent.

**AND THE LOG CONTAINS NO `/hqp/` URI AT ALL** in that whole 17-hour window -
only `/music/<id>/download.flac` (tier 1) and Qobuz direct (tier 5). So no BBC
Sounds play has reached HQPlayer since the daemon started. **There is no
evidence of the failure yet**; everything above is elimination.

### CANDIDATE, NOT CONFIRMED: the synthesised FLAC header is hardcoded to 44100

`Stream::_flacPrelude` builds a `fLaC` + STREAMINFO header for a stream that
arrives without one, and takes its rate from the TRACK:

```perl
my $rate = ( eval { $track->samplerate } ) || 44100;
```

A REMOTE track usually has no `samplerate`, so that falls to **44100**. BBC
content is **48 kHz** (confirmed from the plugin's own MPD parsing). A STREAMINFO
declaring 44.1 on 48 kHz audio is precisely "choppy, like a sample rate mismatch"
- and it is invisible to a squeezelite player, which never sees this header.

**Why it is only a candidate:** the prelude fires ONLY when `$song->seekdata` is
set - a seek. Whether a BBC Sounds play sets seekdata (it supports live rewind
and start offsets) is UNVERIFIED, and on a plain live start no prelude is written
at all and the transcoder's own header would carry the right rate.

**Note the 44100 fallback has never yet been wrong by luck**: tier 5 does not use
Stream.pm, and the tier 4 sources tested (Deezer, radio) are 44.1.

### THE TEST THAT SPLITS IT - do this before writing any code

~~Play the same station on a squeezelite player.~~ **DONE - it is the bridge.**

What is needed now is **one BBC Sounds play on the HQPlayer player**, watched
live. Two things to capture while it runs, both available without touching the
box:

1. `["hqplayerbridge","signalpath"]` - the `source` row is the rate HQPlayer
   believes it is decoding. **44100 against a 48 kHz BBC stream confirms the
   candidate above outright.**
2. `http://192.168.1.109:8088/log` - reachable from here (verified). Look for the
   `/hqp/` URI, the `Stream buffer` line beside it, and any decoder error.

**Judge by that log, never by the control API** - `state`, `process_speed` and
`input_fill` all read healthy through the tier 3 garbling. See the Review
Ledger.

The live page's **Source** row now shows what HQPlayer thinks it is decoding,
which is a diagnostic that did not exist when this class of bug was last chased.

## Still unverified

* ~~How HQPlayer presents fixed volume.~~ **ANSWERED 2026-09-05: it doesn't.**
  HQPlayer's fixed volume is a startup LEVEL, not a lock — the range stays full
  width, `enabled` stays 1, and the volume remains changeable. There is no state
  to present. See the Review Ledger; the detectors that assumed one are deleted.
* `Player::connected` returns `tcpsock` (a literal 1) as LMS-Groups does, so LMS
  shows the player as present even when the control link is down. Discovered-but-
  unreachable is a normal recurring state here (the NAA lives at home), and
  tying the two together would risk LMS churning prefs and sync groups.
* ~~Whether the track-boundary lag survived 0.2.34/0.2.35/0.2.37.~~
  **CLOSED 2026-09-06, Simon: *"Not noticed any issues with track boundaries."***
  The uri-as-veto plus `STALE_LIMIT` (5) is doing its job in normal listening.
* ~~The hqplayerd control-thread wedge TRIGGER.~~ **CLOSED 2026-09-06, Simon's
  call:** *"I think 3 is hqplayer itself, its temperamental when changing things
  and I am switching from wired to wireless which often doesnt help."* The
  network transition is a far better explanation than anything in the bridge,
  and it fits the evidence that nothing is logged between the last healthy event
  and the first exception. **The circuit breaker (0.2.60) stands regardless** -
  it bounds the damage whatever the cause, which was always the argument for
  building it. Do not reopen this without new evidence: the probe-a-wedged-daemon
  plan is retired.

### OPEN: BBC Sounds ("iPlayer") streams sound choppy

Reported 2026-09-06. **Not diagnosed - see the 0.2.72 note for what is
established and the one test that splits it.**

## Not in v1

HQPlayer DSP/filter/mode selection from LMS, HQPlayer's own
library browsing, multi-room sync with hardware players, editable settings,
plugin icon artwork, HTTP auth on the LMS URLs when a server password is set.
