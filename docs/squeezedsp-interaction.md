# SqueezeDSP interaction — investigation and proposed upstream fix

**Status 2026-09-28: PARKED. Nothing built, nothing sent, nothing verified live.**

A user running both plugins reported dropouts and loss of gapless. Cause traced to SqueezeDSP
(https://github.com/Foxenfurter/SqueezeDSP), which registers conversion profiles with
`Slim::Player::TranscodingHelper` for **every** connected player and deletes LMS's generic native
entries server-wide. Everything below is **read from source** (SqueezeDSP `main`, config revision
0.2.02; LMS 9.1) — SqueezeDSP is not installed on the rig and none of it is measured.

## Effect on this plugin, per tier

| tier | effect |
|---|---|
| 1 — local, HQPlayer-decodable | **safe.** `download.flac` on an `flc` track resolves back to the same type (`isSong(undef,'flac')` is false, `typeFromSuffix` gives `flc`), so `downloadMusicFile` never calls the transcoder |
| 3 — local, needs transcode | **broken.** That route calls `getConvertCommand2($obj, undef, ...)` with no client, so SqueezeDSP's MAC-bound profiles cannot match — and the generic `mp4 flc * *` it would use has been deleted. Transcoder undef, HTTP 400, track fails to load |
| 5 — Qobuz/Tidal direct | **gone.** `Song::open:469` gates `canDirectStream` on `$transcoder->{command} eq '-'`. SqueezeDSP's `flc-flc-*-<id>` is matched first, so the gate never opens and every streaming track drops to tier 4 |
| 4 — plugin stream endpoint | **not gapless, and slow.** Single-stream and never pre-queued by design, and the bytes now run flac -> DSP binary -> FLAC re-encode |

Key mechanism facts, all from source:

* `Configuration.pm` `@foundClients = @clientIDs` — profiles written for every client, no opt-in.
* `Bypass = 1` means **DSP off** (UI checkbox is inverted, `sqdsp_core.js:125-136`), and
  `upgradePrefs` creates new clients with `Bypass => "1"`. So its own default is off, and the
  transcode table ignores that.
* `removeNativeConversion` has no clientid filter; `%players = _getEnabledPlayers()` is fetched and
  never used. `_getEnabledPlayers` returns every connected client regardless of `Bypass`.
* `TranscodingHelper.pm:368-386` pushes `$type-$fmt-*-$clientid` before `$type-$fmt-*-*`, and
  `PROFILE: foreach` takes the first match — so the global deletion is redundant for its purpose.
* `Configuration.pm:27` has a bare `sleep 1` on the main event loop, in the `client new` /
  `client reconnect` handlers.

## If we pick this up: what a build-and-test would need

1. Install SqueezeDSP on the rig (it is NOT currently installed — only Qobuz is) and reproduce
   first: confirm tier 5 collapses to tier 4 and tier 3 returns 400, before changing anything.
2. Patch SqueezeDSP locally per the proposal below, re-test the same two paths.
3. Only then send the issue / PR upstream.

Also still open as our own fallback, if upstream declines: detect a non-`-` command bound to our
clientid at load time and warn on the settings page. Discussed, not built.

---

# Conversion profiles are written for every player, including ones with DSP off

Hi — I maintain [LMS-HQPlayer-Bridge](https://github.com/SimonArnold002/LMS-HQPlayer-Bridge), which
creates a virtual LMS player that hands tracks to an HQPlayer instance. A user running both plugins
reported dropouts and loss of gapless, and tracing it led back to how SqueezeDSP registers itself
with `Slim::Player::TranscodingHelper`. I think there's a straightforward fix that also makes your
own per-player DSP switch do what its help text promises.

All of the below is read from `main` (config revision 0.2.02) and LMS 9.1, not measured on a rig.

## What happens

`Configuration.pm::initConfiguration` builds its client list as:

```perl
my @clientIDs = sort map { $_->id() } Slim::Player::Client::clients();
...
@foundClients = @clientIDs;   # Include all current clients
```

and then writes a full template block (`FLAC24` + `MP3`, or `WAV16` + `MP3`) for every one of them.
There's no consultation of the per-player `Bypass` setting, so a player whose DSP is **off** still
gets `flc flc * <its-MAC>`, `mp4 flc * <its-MAC>` and the rest installed into the conversion table.
Since `upgradePrefs` creates new clients with `Bypass => "1"` — DSP off — that means *every newly
discovered player on the server* gets a full set of SqueezeDSP profiles it was never opted in to.

Two consequences for a player that isn't meant to be processed:

**1. Direct streaming is disabled.** `Slim::Player::Song::open` only offers a track to the player's
`canDirectStream` hook when the resolved transcoder is the passthrough sentinel:

```perl
# Slim/Player/Song.pm:469
if ($transcoder->{'command'} eq '-' && ($directUrl = $client->canDirectStream($url, $self)) && ...)
```

With a SqueezeDSP profile bound to that player's MAC, the command is never `-`, so the branch is
never taken. For Qobuz/Tidal that costs the signed-CDN handoff, and in my plugin's case it drops
streaming from a pre-queued gapless path onto a single-socket proxy path that can't be gapless at
all. That is most of what my user was hearing.

**2. `removeNativeConversion` deletes entries that aren't yours.** The loop has no clientid filter:

```perl
# Configuration.pm
my %players = %{Plugins::SqueezeDSP::Utils::_getEnabledPlayers()};   # fetched, never used below
...
for my $profile (sort keys %$conv) {
    my ($inputtype, $outputtype, $clienttype, $clientid) = _inspectProfile($profile);
    ...
    if ($enabled == 1 && $command eq "-") { delete ... }
    elsif ($enabled == 1 && ($outputtype eq "flc" || ... )) { delete ... }
}
```

So the generic `flc flc * *`, `mp4 flc * *`, `alc flc * *` … entries go from the table server-wide.
Those generics are what LMS uses for **client-less** lookups — `Slim::Web::HTTP::downloadMusicFile`
calls `getConvertCommand2($obj, undef, ['F'], [], [], $outFormat, ...)` with no client, so a
MAC-bound profile can never match it and there's nothing left to fall back to. The download route
then returns HTTP 400 for any track needing a transcode. My plugin uses that route to feed HQPlayer
formats it can't decode (m4a/ALAC), so those tracks fail outright; anything else on the server that
downloads with a format suffix is affected the same way.

The `%players` hash being fetched and never used suggests the filter was intended and got lost.

## Suggested fix

### 1. Honour `Bypass` when writing the config

In the `foreach my $clientID ( @foundClients )` loop in `initConfiguration`, write the section
markers but no profiles when DSP is off for that player. Keeping the markers matters: they're what
the "was not yet registered" check reads, so dropping them entirely would trigger a full rewrite on
every client event.

```perl
foreach my $clientID ( @foundClients ) {
    print OUT "# #$Plugins::SqueezeDSP::Plugin::confBegin#rev:$Plugins::SqueezeDSP::Plugin::myconfigrevision#client:$clientID# ***** BEGIN AUTOMATICALLY GENERATED SECTION - DO NOT EDIT ****\n";

    my $client = Slim::Player::Client::getClient($clientID);

    # DSP is off for this player (Bypass ne 0), which is also the default for a
    # newly registered client. Write no conversion profiles at all, so LMS keeps
    # its native passthrough and its direct-streaming path for that player.
    if ( !defined($client) || Plugins::SqueezeDSP::Utils::getPref($client, 'Bypass') ne '0' ) {
        Plugins::SqueezeDSP::Utils::debug("DSP off for $clientID - no conversion profiles written");
        print OUT "# DSP is off for this player - no profiles generated\n";
        print OUT "# #$Plugins::SqueezeDSP::Plugin::confEnd#client:$clientID# ***** END AUTOMATICALLY GENERATED SECTION - DO NOT EDIT *****\n\n";
        next;
    }

    my @formats;
    ... unchanged from here ...
}
```

### 2. Make `_getEnabledPlayers` mean what it says

```perl
sub _getEnabledPlayers {
    my %enabled = ();
    for my $client (Slim::Player::Client::clients()) {
        next unless getPref($client, 'Bypass') eq '0';   # 0 = DSP on
        $enabled{$client->id()} = 1;
    }
    return \%enabled;
}
```

### 3. Drop the global deletion in `removeNativeConversion`

I think this sub can go entirely, because profile precedence already does its job.
`getConvertCommand2` builds its candidate list client-bound-first:

```perl
# Slim/Player/TranscodingHelper.pm:368-386
if ( $clientid && $player ) {
    push @profiles, (
        "$type-$checkFormat-$player-$clientid",
        "$type-$checkFormat-*-$clientid",      # <- yours
        "$type-$checkFormat-$player-*"
    );
}
push @profiles, "$type-$checkFormat-*-*";      # <- generic native, tried after
```

and `PROFILE: foreach (@profiles)` takes the first one that exists and satisfies the stream-mode and
capability checks. So for a player you *are* processing, your `*-$clientid` profile already wins over
the generic native — deleting the generic buys nothing, and costs every other player and every
client-less lookup on the server.

The one behaviour that changes: if your profile is rejected by the capability check (no matching
stream mode, or a required `D` resample the profile doesn't declare), LMS will now fall back to the
native entry instead of failing the track. That seems like the better outcome, but if you'd rather
keep suppressing it, scoping the deletion to enabled clientids preserves the intent:

```perl
next unless defined $clientid && $clientid ne '*' && $players{$clientid};
```

### 4. Apply the toggle without a server restart

Neither the revision nor the registered-client list changes when someone flips the DSP switch, so
`needUpgrade` stays false and the config isn't rewritten. In `UI_Functions::saveallCommand`, read the
old value before saving and rebuild if it moved:

```perl
my $wasBypassed = Plugins::SqueezeDSP::Utils::getPref($client, 'Bypass');

Plugins::SqueezeDSP::Utils::SaveJSONFile($data, $myJSONFile);

if ( ($data->{Client}->{Bypass} // 1) ne $wasBypassed ) {
    $Plugins::SqueezeDSP::Plugin::needUpgrade = 1;
    Plugins::SqueezeDSP::Configuration::initConfiguration($client);
}
```

## Separately: the blocking `sleep 1`

`initConfiguration` has a bare `sleep 1` near the top, and it runs from the `client new` and
`client reconnect` request handlers — i.e. on LMS's main event loop. That stalls the whole server for
a second every time any player connects or reconnects, which on a busy server with players coming and
going is its own source of audible dropouts. Worth moving the delay off the event loop or removing it.

## Why not just special-case my plugin

I could send a patch that skips players whose `model()` is `hqplayer`, and I'm happy to if you'd
prefer it as a stopgap. But it only helps my plugin, it hard-codes a string I control into yours, and
it leaves the underlying behaviour — profiles written for players with DSP off, and generic entries
deleted server-wide — in place for everyone else. Honouring `Bypass` fixes the class.

Happy to test any of this against my setup, or to open a PR if you'd rather review a diff.
