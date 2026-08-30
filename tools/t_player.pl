# Regression tests for the player object itself.
#
# These exist because of a real bug: Slim::Player::Client objects are BLESSED
# ARRAYS (Slim::Utils::Accessor slots), so $client->{field} = ... is a fatal
# "Not a HASH reference".  Player.pm did exactly that in new(), which killed
# player creation on a live server - and because it ran inside a timer callback
# the only symptom was "Timer ..._roundDone failed" with the cause swallowed.
use strict; use warnings;
BEGIN { package main; use constant DEBUGLOG=>0; use constant INFOLOG=>0; use constant WEBUI=>1; }
use lib '.';
require Plugins::HQPlayerBridge::Player;

my ($pass,$fail)=(0,0);
sub is { my($got,$want,$name)=@_; $got//='(undef)'; $want//='(undef)';
  if ($got eq $want){$pass++; printf "  ok   %s\n",$name}
  else {$fail++; printf "  FAIL %s\n        got: %s\n       want: %s\n",$name,$got,$want} }
# TRAP: ok($src =~ /re/, 'name') evaluates the match in LIST context, where a
# FAILED match returns the empty list - so @_ collapses to just the name, the
# name lands in $c as a true value, and a broken assertion prints "ok" with a
# blank label and counts as a pass.  Two assertions in this file had been dead
# that way.  Take the name off the END and treat everything left as the
# condition, so an empty list reads as false.
sub ok { my $n = pop; my $c = @_ ? $_[0] : 0;
  $c ? ($pass++, printf "  ok   %s\n",$n) : ($fail++, printf "  FAIL %s\n",$n) }

print "-- player construction --\n";
my $c = eval { Plugins::HQPlayerBridge::Player->new('02:ab:88:42:4c:69', 'paddr', 1.0, undef, 12, undef) };
ok($c && !$@, "new() does not die".($@ ? " ($@)" : ""));
is(ref($c), 'Plugins::HQPlayerBridge::Player', 'correct class');
ok(ref($c) && UNIVERSAL::isa($c,'ARRAY'), 'object is a blessed ARRAY, not a hash');

print "-- accessor defaults set in new() --\n";
is($c->hqStarted, '0', 'hqStarted initialised to 0');
is($c->hqExpectStop, '0', 'hqExpectStop initialised to 0');
is($c->hqPosition, '(undef)', 'hqPosition initialised to undef');
is($c->hqLastStatus, '0', 'hqLastStatus initialised to 0');

print "-- accessors store falsy values correctly --\n";
$c->hqStarted(1); is($c->hqStarted,'1','set to 1');
$c->hqStarted(0); is($c->hqStarted,'0','set back to 0 (not swallowed as a get)');
$c->hqPosition(0); is($c->hqPosition,'0','position 0 stores');
$c->hqTier(undef); is($c->hqTier,'(undef)','undef stores');
$c->hqRate('96000'); is($c->hqRate,'96000','rate stores');

print "-- accessors do not collide across the ISA chain --\n";
$c->id('02:ab:88:42:4c:69');
$c->hqStarted(7);
is($c->id,'02:ab:88:42:4c:69','base-class slot survives subclass writes');
is($c->hqStarted,'7','subclass slot survives base-class writes');

print "-- the original bug must stay fixed --\n";
my $died = !eval { $c->{someField} = 1; 1 };
ok($died, 'writing a hash key on the client dies (as it does on a real server)');
ok(!grep({ /->\{_hqp/ } do { open my $fh,'<','../HQPlayerBridge/Player.pm'; <$fh> }),
   'Player.pm contains no $self->{_hqp...} hash-slot access');

print "-- Socket context trap must stay fixed --\n";
# sockaddr_in() switches on wantarray: in a function-call argument list it is in
# LIST context, treats its two args as a request to UNPACK one, and croaks.
# That killed player creation on a live server. Only the explicit pack_/unpack_
# forms are allowed in this codebase.
for my $f (qw(Plugin Player Control Discovery Settings)) {
    open my $fh, '<', "../HQPlayerBridge/$f.pm" or next;
    my @bad = grep { /(?<![_\w])sockaddr_in\s*\(/ && !/^\s*#/ } <$fh>;
    ok(!@bad, "$f.pm uses only pack_/unpack_sockaddr_in".(@bad ? " (found: ".join('',@bad).")" : ""));
}

print "-- DIDL-Lite metadata (the only channel that reaches HQPlayer) --\n";
{
    package FakeTrack;
    sub new { bless {%{$_[1]}}, $_[0] }
    sub title      { $_[0]->{title} }
    sub artistName { $_[0]->{artist} }
    sub albumname  { $_[0]->{album} }
    sub coverid    { $_[0]->{coverid} }
    sub id         { $_[0]->{id} }
    sub secs       { $_[0]->{secs} }
    sub content_type { $_[0]->{ct} }
    sub url        { $_[0]->{url} }
    sub replay_peak { $_[0]->{peak} }
    package FakeSong;
    sub new { bless { t => $_[1] }, $_[0] }
    sub currentTrack { $_[0]->{t} }

    # The direct-streaming half: Song::open sets these when canDirectStream
    # returns a url, and _resolveURL reads them back.
    sub replayGain          { $_[0]->{rg} }
    sub _rg { $_[0]->{rg} = $_[1]; $_[0] }

    sub directstream        { $_[0]->{direct} }
    sub streamUrl           { $_[0]->{streamUrl} }
    sub currentTrackHandler { $_[0]->{handler} }
    sub _direct { my ($s,$u,$h)=@_; $s->{direct}=1; $s->{streamUrl}=$u; $s->{handler}=$h; $s }

    # Stand-ins for LMS protocol handlers, which differ in which hook they
    # offer and whether they need the directHeaders callback we cannot make.
    package FakeHandlerSong;   # Qobuz-shaped: canDirectStreamSong
    sub new { bless { u => $_[1] }, $_[0] }
    sub canDirectStreamSong { $_[0]->{u} }

    package FakeHandlerUrl;    # older shape: canDirectStream($client,$url)
    sub new { bless { u => $_[1] }, $_[0] }
    sub canDirectStream { $_[0]->{u} }

    package FakeHandlerRadio;  # parses response headers itself - must be refused
    sub new { bless { u => $_[1] }, $_[0] }
    sub canDirectStream    { $_[0]->{u} }
    sub handlesStreamHeaders { 1 }
}
my $tr = FakeTrack->new({ title=>'Colony & "Collapse"', artist=>'Johanna <Warren>',
    album=>'Gemini I', coverid=>'abc123', id=>447812, secs=>107, ct=>'flc' });
my $meta = $c->_metadata( FakeSong->new($tr) );

ok(scalar($meta =~ /^<metadata\b/) && scalar($meta =~ m{/>$}), 'metadata is a complete element');
ok(scalar($meta =~ m{\bsong="Colony &amp; &quot;Collapse&quot;"}), 'song is XML-escaped');
ok(scalar($meta =~ m{\bartist="Johanna &lt;Warren&gt;"}), 'artist is XML-escaped');
ok(scalar($meta =~ m{\balbum="Gemini I"}), 'album present');
ok(scalar($meta =~ m{\bcover="[^"]*/music/abc123/cover\.jpg"}),
   'cover points at the LMS cover - this is what lights up the endpoint');

# THE regression guard for 2026-08-28.  HQPlayer base64-encodes the cover URL
# into the playlist item's `picture` field ITSELF; handing it base64 gets that
# base64 encoded a second time and the endpoint shows nothing.  Verified live
# against engine 6.0.4: a plain URL in `cover` reproduces the DIDL path
# byte-for-byte.
ok(scalar($meta =~ m{\bcover="https?://}), 'cover is a PLAIN url - never pre-encoded');

# The field is `cover`.  picture=/albumArtURI=/art= and a <picture> child were
# all tested against the live daemon and are silently ignored.
ok(scalar($meta !~ m{\bpicture=}) && scalar($meta !~ m{albumArtURI}),
   'artwork goes in cover=, not the fields HQPlayer ignores');

# proxiedImage on a LOCAL path returns the "no artwork" placeholder, not the
# cover. That produced a blank icon on the endpoint; it must never come back.
ok(scalar($meta !~ m{/imageproxy/}), 'local cover URL is direct, NOT wrapped in the image proxy');

# A REMOTE TRACK CARRIES ALMOST NOTHING ON THE TRACK ROW. artistName and
# albumname are populated for a library track and EMPTY for Tidal/Qobuz/Deezer,
# where that metadata lives with the protocol handler. Reported live
# 2026-08-28: a Tidal track reached HQPlayer as song + cover + length and
# nothing else - no artist, no album, on the endpoint's screen. The artwork was
# right the whole time, because _coverURL was the only thing asking the handler.
#
# The metadata tests above all use a LOCAL track, which is exactly why this got
# through: keep a remote one here.
print "-- a remote track gets artist and album from the handler --\n";
{
    package TidalHandler;
    sub getMetadataFor {
        return {
            title  => 'ONLY THING LEFT',
            artist => 'Alex Warren',
            album  => 'WILDCHILD',
            cover  => 'http://resources.tidal.com/images/x/1280x1280.jpg',
        };
    }
    package RefHandler;   # a handler that hands back objects, not strings
    sub getMetadataFor {
        return {
            title  => 'Tempest',
            artist => { name => 'Deafheaven' },
            album  => bless({}, 'NamedThing'),
        };
    }
    package NamedThing;
    sub name { 'Infinite Granite' }
}
{
    no warnings qw(redefine once);
    local *Slim::Music::Info::isRemoteURL = sub { $_[0] && $_[0] =~ m{^\w+://} && $_[0] !~ m{^file://} };
    local *Slim::Player::ProtocolHandlers::handlerForURL = sub {
        return $_[1] =~ /^ref:/ ? 'RefHandler' : 'TidalHandler';
    };

    # the track row is empty, as a RemoteTrack's is
    my $rt = FakeTrack->new({ title=>undef, artist=>undef, album=>undef,
                              id=>-94081882758952, secs=>215, url=>'tidal://555260667.flc' });
    my $m = $c->_metadata( FakeSong->new($rt) );

    ok(scalar($m =~ m{\bartist="Alex Warren"}), 'artist comes from the protocol handler');
    ok(scalar($m =~ m{\balbum="WILDCHILD"}),    'album comes from the protocol handler');
    ok(scalar($m =~ m{\bsong="ONLY THING LEFT"}), 'so does the title when the row has none');
    ok(scalar($m =~ m{\bcover="http://resources\.tidal\.com/}), 'artwork still works');
    ok(scalar($m =~ m{\blength="215"}), 'and the duration is still sent');

    # a library track never reaches the handler at all (_handlerMeta returns {}
    # for a local url), so its own row is what gets sent
    my $lt = FakeTrack->new({ title=>'Local Title', artist=>'Local Artist',
                              album=>'Local Album', coverid=>'abc', id=>5, secs=>100,
                              ct=>'flc', url=>'file:///x.flac' });
    my $lm = $c->_metadata( FakeSong->new($lt) );
    ok(scalar($lm =~ m{\bartist="Local Artist"}), 'a local track keeps its own artist');
    ok(scalar($lm =~ m{\balbum="Local Album"}),   'and its own album');

    # RADIO. The row's title is the STATION, and it IS populated - so a rule of
    # "row first, handler as fallback" silently sends the station name as the
    # track for every radio stream. Live 2026-08-28, Radio Paradise:
    #   row     title = 'Main Mix - FLAC Interactive'
    #   handler title = 'Road to Joy'
    {
        package RadioHandler;
        sub getMetadataFor {
            return { title => 'Road to Joy', artist => 'Peter Gabriel', album => 'i/o' };
        }
    }
    {
        no warnings qw(redefine once);
        local *Slim::Player::ProtocolHandlers::handlerForURL = sub { 'RadioHandler' };

        my $radio = FakeTrack->new({ title=>'Main Mix - FLAC Interactive',
                                     id=>-94387584450888, url=>'radioparadise://4.flac' });
        my $rm = $c->_metadata( FakeSong->new($radio) );

        ok(scalar($rm =~ m{\bsong="Road to Joy"}),
           'the handler title wins over the row - the row holds the STATION name');
        ok(scalar($rm !~ m{Main Mix}),
           'and the station name is not sent as the track title');
        ok(scalar($rm =~ m{\bartist="Peter Gabriel"}), 'artist still comes through');
    }

    # a handler returning objects rather than strings must not stringify a ref
    # into the text HQPlayer displays
    my $ot = FakeTrack->new({ id=>-1, secs=>60, url=>'ref://1.flc' });
    my $om = $c->_metadata( FakeSong->new($ot) );
    ok(scalar($om =~ m{\bartist="Deafheaven"}),      'a hash-shaped artist is unwrapped');
    ok(scalar($om =~ m{\balbum="Infinite Granite"}), 'an object-shaped album is unwrapped');
    ok(scalar($om !~ m{=("|)[A-Za-z:]+=HASH}),        'no reference is ever written into the metadata');
}

print "-- remote tracks (Qobuz/Tidal) take their artwork from the handler --\n";
{
    package FakeHandler;
    sub can { my ($s,$m)=@_; return $m eq 'getMetadataFor' ? sub {} : undef }
    sub getMetadataFor { return { cover => '/imageproxy/https%3A%2F%2Fstatic.qobuz.com%2Fx.jpg/image.jpg' } }
    package FakeHandlerAbs;
    sub can { my ($s,$m)=@_; return $m eq 'getMetadataFor' ? sub {} : undef }
    sub getMetadataFor { return { icon => 'https://static.qobuz.com/direct.jpg' } }
}

# -- replay gain rides on <metadata/>, on EVERY tier ---------------------------
#
# LMS decides album-vs-track gain upstream (Smart Gain compares a song's
# playlist neighbours; a service handler's trackGain does its own equivalent),
# so the only job here is to carry the figure it settled on.
#
# It was streaming-only until 0.2.44, on the reasoning that HQPlayer reads a
# local file's own REPLAYGAIN tags and ours would be applied twice. It does not
# add - `album_gain` REPLACES the tag - and leaving it to HQPlayer loses the
# gain outright on a fresh load, because it reads the tags too late. The one
# thing the local line still decides is what happens when LMS gives us NO
# figure: see the omit test below.
{
    no warnings qw(redefine once);
    local *Slim::Music::Info::isRemoteURL = sub { $_[0] && $_[0] =~ m{^\w+://} && $_[0] !~ m{^file://} };
    local *Slim::Player::ProtocolHandlers::handlerForURL = sub { undef };

    my $qt = FakeTrack->new({ title=>'Movement 1 - Fire', artist=>'Floating Points',
                              album=>'Mere Mortals', id=>-949079, secs=>326,
                              url=>'qobuz://420452060.flac' });

    my $g = $c->_metadata( FakeSong->new($qt)->_rg(-4.07) );
    ok(scalar($g =~ m{\balbum_gain="-4\.07"}), 'a streaming track carries the gain LMS computed');

    # A LOCAL FILE GETS ONE TOO - and it is not optional. HQPlayer applies the
    # figure at PLAY time from tags it has ALREADY parsed, and the bridge goes
    # Stop -> PlaylistClear -> PlaylistAdd -> Play in ~300ms, so playback starts
    # before the file has been fetched and read. Live on a fully-tagged album
    # (LMS: album_replay_gain -9.6), three adds all played at 0 dB and the -9.6
    # arrived only when the playlist next changed. Sending it with the item
    # removes the race. Our value REPLACES the file's tag rather than adding to
    # it - proven: a FLAC tagged -8.61 sent album_gain="-15" played at -15.
    my $lt = FakeTrack->new({ title=>'Local', artist=>'A', album=>'B', coverid=>'c',
                              id=>5, secs=>100, ct=>'flc', url=>'file:///x.flac' });

    my $lg = $c->_metadata( FakeSong->new($lt)->_rg(-6.31) );
    ok(scalar($lg =~ m{\balbum_gain="-6\.31"}),
       'a LOCAL track carries the gain too - it is no longer streaming-only');

    $c->hqHeadroom(-3.01);
    my $lgh = $c->_metadata( FakeSong->new($lt)->_rg(-6.31) );
    ok(scalar($lgh =~ m{\balbum_gain="-3\.30"}),
       'and is headroom-compensated exactly like a streaming one');
    $c->hqHeadroom(undef);

    # UNITY IS ASSERTED, NOT OMITTED. Omitting relies on HQPlayer defaulting
    # each item to unity by itself; saying 0.00 means nothing can carry over
    # from the previous track however the daemon handles a hand-over.
    my $zero = $c->_metadata( FakeSong->new($qt)->_rg(0) );
    ok(scalar($zero =~ m{\balbum_gain="0\.00"}), 'a gain of 0 dB is asserted, not left off');

    my $none = $c->_metadata( FakeSong->new($qt) );
    ok(scalar($none =~ m{\balbum_gain="0\.00"}), 'and so is no value at all');

    # ...BUT ONLY FOR A REMOTE TRACK. `album_gain` OVERRIDES a file's own tags,
    # and LMS hands back no figure at all when the user has replay gain switched
    # OFF. Asserting 0.00 there would override a good REPLAYGAIN tag with unity
    # and silently disable HQPlayer's own playlist_album_gain for a user who
    # never asked LMS to do this. So a local track with no figure sends NOTHING.
    my $localNone = $c->_metadata( FakeSong->new($lt) );
    ok(scalar($localNone !~ m{album_gain}),
       'a LOCAL track with no figure sends no album_gain - HQPlayer reads the file itself');


    # THE HEADROOM IS COMPENSATED FOR, NOT SUFFERED.
    #
    # HQPlayer applies BOTH its headroom and our album_gain, so sending the
    # ReplayGain figure raw meant a -10.03 dB album played at -13.04 - the
    # headroom taken off every track on top of the normalisation. Simon,
    # 2026-08-30: "we are now adding -13db of reduction". So the headroom is
    # added back and the COMBINED figure is what is held at or below 0 dBFS.
    $c->hqVolDb(-38);

    my $qnp = FakeTrack->new({ title=>'Speak to Me', id=>-1, secs=>71,
                               url=>'qobuz://193171335.flac' });

    $c->hqHeadroom(-3.01);

    my $cutM = $c->_metadata( FakeSong->new($qnp)->_rg(-10.03) );
    ok(scalar($cutM =~ m{\balbum_gain="-7\.02"}),
       'an attenuation is compensated so the COMBINED figure hits the ReplayGain target');

    my $small = $c->_metadata( FakeSong->new($qnp)->_rg(-0.5) );
    ok(scalar($small =~ m{\balbum_gain="2\.51"}),
       'a small cut can send a POSITIVE figure - it is cancelling the headroom');

    my $trim = $c->_metadata( FakeSong->new($qnp)->_rg(6.68) );
    ok(scalar($trim =~ m{\balbum_gain="3\.01"}),
       'a boost is TRIMMED to the headroom so the combined lands at 0, never refused');

    my $atTarget = $c->_metadata( FakeSong->new($qnp)->_rg(0) );
    ok(scalar($atTarget =~ m{\balbum_gain="3\.01"}),
       'a track already at target cancels the headroom exactly');

    # THE VOLUME MUST NOT ENTER IT - analogue attenuation is downstream of where
    # digital clipping happens, and hqplayerd's split is `software: -4` constant.
    $c->hqVolDb(-90);
    my $lowVol = $c->_metadata( FakeSong->new($qnp)->_rg(6.68) );
    ok(scalar($lowVol =~ m{\balbum_gain="3\.01"}),
       'the volume changes nothing - it is not digital headroom');
    $c->hqVolDb(-38);

    # NO HEADROOM KNOWN: nothing to compensate, nothing to boost into.
    $c->hqHeadroom(undef);
    my $unknown = $c->_metadata( FakeSong->new($qnp)->_rg(-10.03) );
    ok(scalar($unknown =~ m{\balbum_gain="-10\.03"}),
       'with no headroom known the figure goes out untouched');
    my $unkBoost = $c->_metadata( FakeSong->new($qnp)->_rg(6.68) );
    ok(scalar($unkBoost =~ m{\balbum_gain="0\.00"}),
       'and a boost is refused - we do not know what HQPlayer is holding back');
    $c->hqHeadroom(-3.01);

    # THE PEAK now binds only for a source ALREADY past full scale: peak 1.05
    # gives -20*log10(1.05) = -0.42, so the combined must sit there, not at 0.
    my $hot = FakeTrack->new({ title=>'Hot', id=>-2, secs=>60,
                               url=>'qobuz://2.flac', peak=>1.05 });
    my $hotm = $c->_metadata( FakeSong->new($hot)->_rg(6.68) );
    ok(scalar($hotm =~ m{\balbum_gain="2\.59"}),
       'a source past full scale trims further - combined lands below 0, not at it');
    $c->hqHeadroom(-3.01);

    # PARSING hqplayerd's LOG. `Volume scaler` is the precise figure and wins;
    # `Convolution gain compensation` is the whole-dB fallback. The LAST match
    # is the current setting - the log is oldest-first, so a config change
    # leaves stale values behind it.
    {
        my $tmp = "/tmp/hqpb-headroom-$$.txt";
        my $wr  = sub {
            open my $fh, '>', $tmp or die $!;
            print $fh $_[0];
            close $fh;
        };

        $wr->( "Convolution gain compensation: -6\nVolume scaler: 0.707107\nblah\n" );
        $c->hqHeadroom(undef);
        $c->_headroomFromFile($tmp);
        ok(scalar( sprintf('%.2f', $c->hqHeadroom) eq '-3.01' ),
           'Volume scaler is read as dB and preferred over the rounded compensation');

        $wr->( "Volume scaler: 0.707107\nlater...\nVolume scaler: 0.5\n" );
        $c->_headroomFromFile($tmp);
        ok(scalar( sprintf('%.2f', $c->hqHeadroom) eq '-6.02' ),
           'the LAST match wins - a config change leaves stale values behind it');

        $wr->( "nothing here\nConvolution gain compensation: -3\n" );
        $c->hqHeadroom(undef);
        $c->_headroomFromFile($tmp);
        is( $c->hqHeadroom, '-3', 'the compensation line is the fallback when there is no scaler' );

        $wr->( "no headroom line at all\n" );
        $c->hqHeadroom(undef);
        $c->_headroomFromFile($tmp);
        ok(scalar( !defined $c->hqHeadroom ),
           'a log with neither leaves the headroom unknown, so no boost is sent');

        $wr->( "Volume scaler: 2.0\n" );
        $c->_headroomFromFile($tmp);
        is( $c->hqHeadroom, 0, 'a POSITIVE figure is not headroom - nothing is being held back' );

        unlink $tmp;
    }

    # THE HEADROOM CHANGES WHEN HQPLAYER'S PROCESSING DOES, and the value is not
    # in the control API (24 probes, all Unknown command) - so we watch the DSP
    # fields every <Status/> push already carries and re-read the log when they
    # move. `Volume scaler` is derived from the convolution gain, so a DSP
    # change is exactly the event that moves the headroom.
    {
        my @reads;
        no warnings 'redefine';
        local *Plugins::HQPlayerBridge::Player::readHeadroom = sub { push @reads, $_[1] ? 'forced' : 'throttled' };

        my $a = { active_filter=>'poly-sinc-gauss-long', active_shaper=>'ASDM7EC-light',
                  active_mode=>'2', active_rate=>'11289600', correction=>'0',
                  filter_20k=>'0', filter_junk=>'0' };

        $c->hqDspSig(undef);
        $c->_watchDsp($a);
        ok(scalar(@reads == 0), 'the FIRST signature is recorded, not treated as a change');

        $c->_watchDsp($a);
        ok(scalar(@reads == 0), 'an unchanged chain does not re-read the log');

        $c->_watchDsp({ %$a, active_filter => 'poly-sinc-gauss-hires-lp' });
        is( scalar(@reads), 1, 'a filter change re-reads it' );
        is( $reads[0], 'forced', 'and forces past the throttle - it is a real event' );

        $c->_watchDsp({ %$a, active_filter => 'poly-sinc-gauss-hires-lp', correction => '1' });
        is( scalar(@reads), 2, 'so does a correction change' );

        # A push that simply did not carry the fields is NOT a change - treating
        # it as one would re-read the whole log on every stop.
        @reads = ();
        $c->_watchDsp({});
        ok(scalar(@reads == 0), 'a push with none of the fields is not a change');
    }

    # The throttle: a routine re-read is skipped while the value is fresh, but a
    # forced one always goes. Each read costs the WHOLE log - :8088/log has no
    # range or tail support - so an unforced timer would be wasteful.
    {
        open my $pm, '<', 'Plugins/HQPlayerBridge/Player.pm' or die $!;
        my $mod = do { local $/; <$pm> };
        close $pm;
        my ($rh) = $mod =~ /\nsub readHeadroom \{(.*?)\n\}/s;
        ok(scalar($rh && $rh =~ /if \( !\$force \)/),
           'readHeadroom skips a routine re-read while the value is still fresh');
        ok(scalar($rh && $rh =~ /HEADROOM_MAX_AGE/),
           'and the age floor is a named constant, not a bare number');

        # ...and the watcher has to actually BE on the status path. Calling
        # _watchDsp directly in the tests above proves the logic, not the
        # wiring, and unhooking it would otherwise pass silently.
        my ($os) = $mod =~ /\nsub _onStatus \{(.*?)\n\}/s;
        ok(scalar($os && $os =~ /_watchDsp/),
           '_onStatus calls the DSP watcher - every push, for free');
    }


    my $cut = $c->_metadata( FakeSong->new($qt)->_rg(-0.4) );
    ok(scalar($cut =~ m{\balbum_gain="-0\.40"}), 'but a small ATTENUATION is passed through');

    # A PRE-QUEUED track has not reached StreamingController yet, so the song
    # carries nothing and the value has to be asked for directly. By arm time
    # the playlist neighbours are known, which is what the album/track decision
    # needs - this is also why the figure is never cached against the track.
    Slim::Player::ReplayGain->_setTestGain(-8.97);
    my $armed = $c->_metadata( FakeSong->new($qt) );
    ok(scalar($armed =~ m{\balbum_gain="-8\.97"}), 'a pre-queued track falls back to fetchGainMode');

    # The song's own value wins when it has one - it is the figure LMS is
    # actually about to play with.
    my $both = $c->_metadata( FakeSong->new($qt)->_rg(-4.07) );
    ok(scalar($both =~ m{\balbum_gain="-4\.07"}), 'the song wins over the fallback when set');

    # A handler that hands back junk must not reach the wire as gain="junk".
    Slim::Player::ReplayGain->_setTestGain('n/a');
    my $junk = $c->_metadata( FakeSong->new($qt) );
    ok(scalar($junk =~ m{\balbum_gain="0\.00"}), 'a non-numeric gain becomes unity, not gain="n/a"');

    Slim::Player::ReplayGain->_setTestGain(undef);

    # It must not disturb what was already going out.
    my $still = $c->_metadata( FakeSong->new($qt)->_rg(-4.07) );
    ok(scalar($still =~ m{\bsong="Movement 1 - Fire"}), 'song still sent alongside gain');
    ok(scalar($still =~ m{\blength="326"}),             'and length');
    ok(scalar($still =~ m{^<metadata\b}) && scalar($still =~ m{/>$}),
       'the element is still well formed');
}

{
    no warnings 'redefine';
    *Slim::Music::Info::isRemoteURL = sub { $_[0] && $_[0] =~ m{^qobuz://} };
}
# a remote track has a NEGATIVE id and no coverid - the local route would build
# /music/-9454.../cover.jpg and get the placeholder back.
my $remote = FakeTrack->new({ title=>'For Life', artist=>'Jorja Smith',
    id=>-94543041325440, url=>'qobuz://445307221.flac', ct=>'flc' });

Slim::Player::ProtocolHandlers->_setTestHandler('FakeHandler');
my $rart = $c->_coverURL($remote);
ok(defined $rart && $rart =~ m{/imageproxy/}, 'remote cover comes from the protocol handler');
ok($rart !~ m{/music/-}, 'remote cover does NOT use the negative track id');

Slim::Player::ProtocolHandlers->_setTestHandler('FakeHandlerAbs');
is($c->_coverURL($remote), 'https://static.qobuz.com/direct.jpg', 'an absolute handler URL is passed through unchanged');

Slim::Player::ProtocolHandlers->_setTestHandler(undef);
is($c->_coverURL($remote), '(undef)', 'no handler artwork -> no cover attribute rather than a bad one');

# a track with nothing set must still yield a valid element, not broken XML
my $bare = FakeTrack->new({ title=>'X', id=>1, ct=>'flc' });
my $m2 = $c->_metadata( FakeSong->new($bare) );
ok(scalar($m2 =~ m{^<metadata\b}) && scalar($m2 =~ m{/>$}), 'bare track still yields a complete element');
ok(scalar($m2 !~ /\bartist=/) && scalar($m2 !~ /\balbum=/), 'absent fields are omitted, not emitted empty');
ok(scalar($m2 !~ /\bcover=""/), 'a missing cover is omitted rather than sent empty');

# HQPlayer does NOT probe an http:// item for its duration, so a bridge-added
# track showed length="0" in HQPlayer's UI - the old UPnP path only filled it in
# because DIDL carries <res duration="">.  Verified live 2026-08-28 that
# <metadata length="12.7"/> is accepted and reads back on the playlist item.
my $withLen = $c->_metadata( FakeSong->new(
    FakeTrack->new({ title=>'T', id=>7, ct=>'flc', secs=>247 }) ) );
ok(scalar($withLen =~ /\blength="247"/),
   'the metadata carries the track duration, or HQPlayer shows no length at all');

my $noLen = $c->_metadata( FakeSong->new(
    FakeTrack->new({ title=>'T', id=>7, ct=>'flc', secs=>0 }) ) );
ok(scalar($noLen !~ /\blength=/),
   'a zero duration is omitted rather than sent as length="0" - which is the bug it fixes');


# ---------------------------------------------------------------------------
# The controller state machine.  playerBufferReady routes to _WaitToSync ->
# _StartIfReady, which asks every player isBufferReady() - i.e. the client's
# own bufferReady flag, set on real hardware only by the Squeezebox STAT
# handler.  Leave it at 0 and the controller parks in WAITING_TO_SYNC, where
# Pause is _NoOp and Started is _Invalid: playback works but the transport is
# dead.  A virtual player MUST assert the flag itself.
# ---------------------------------------------------------------------------
print "-- controller handshake --\n";
my $src = do { local (@ARGV,$/) = ('Plugins/HQPlayerBridge/Player.pm'); <> };
# strip comments - they name these very calls, and would match the regexes below
$src =~ s/^\s*#.*$//mg;

ok($src =~ /bufferReady\(\s*1\s*\)[^;]*;.*?playerBufferReady/s,
   'bufferReady(1) is set BEFORE playerBufferReady is signalled');
ok($src !~ /playerBufferReady.*?bufferReady\(\s*1\s*\)/s,
   'and never the other way round');

# play() splits two jobs now - start THIS track, or take the next one for a
# gapless hand-over - and the four-command load moved to _startTrack with it.
my ($playSub) = $src =~ /\nsub play \{(.*?)\n\}/s;
ok($playSub && $playSub =~ /_startTrack/,
   'play() routes an ordinary call to the full load');
ok($playSub && $playSub =~ /hqArmNext\(\s*0\s*\)/,
   'and consumes the hand-over flag on EVERY call, so a stale one cannot swallow a later play()');

my ($startSub) = $src =~ /\nsub _startTrack \{(.*?)\n\}/s;
ok($startSub && $startSub =~ /bufferReady\(\s*0\s*\)/,
   '_startTrack clears bufferReady so a stale 1 cannot start the next track early');
my ($stopSub) = $src =~ /\nsub stop \{(.*?)\n\}/s;
ok($stopSub && $stopSub =~ /bufferReady\(\s*0\s*\)/, 'stop() clears bufferReady');

# ReadyToStream in PLAYING/STREAMING is _NextIfMore: LMS answers it by
# resolving the NEXT song and calling play() again.  That was fatal while every
# play() replaced the playing track, so it used to be sent at end-of-track
# only.  It is now the first half of gapless - but it must still go through
# _armNextTrack, which is where the tier and one-at-a-time guards live.
my ($handedSub) = $src =~ /\nsub _handedOver \{(.*?)\n\}/s;
ok($handedSub && $handedSub !~ /playerEndOfStream|playerStopped/,
   'a hand-over reports Started ONLY - an end-of-stream there would reload the track being played');

my ($armSub) = $src =~ /\nsub _armNextTrack \{(.*?)\n\}/s;
ok(scalar($armSub && $armSub =~ /return unless \$tier == 1 \|\| \$tier == 3 \|\| \$tier == 5;/),
   '_armNextTrack pre-queues tiers 1, 3 and 5 - none of them is the player stream');
ok(scalar($armSub && $armSub !~ /\$tier == 4/),
   'but never tier 4 - that one IS the player stream, and there is one per player');
ok($armSub && $armSub =~ /hqArmNext\(\s*1\s*\).*?playerReadyToStream/s,
   'and arms the flag BEFORE the call - LMS re-enters play() synchronously for a local track');

# The hand-over append goes through the same attribute builder, so it carries
# freewheel too - a pre-queued track is fetched the same way as a loaded one.
my ($attrSub) = $src =~ /\nsub _addAttrs \{(.*?)\n\}/s;
ok(scalar($attrSub && $attrSub =~ /freewheel="' \. HQP_FREEWHEEL/), 'one builder writes freewheel for BOTH the load and the hand-over');
ok(scalar($src =~ /use constant HQP_FREEWHEEL => 1;/), 'and it is on');
ok(scalar($src !~ /PlaylistAdd uri=/), 'no hand-built PlaylistAdd attribute list is left behind');

# ISOLATED AGAINST THE LIVE DAEMON 2026-08-30, one local FLAC whose own tag is
# -8.61 dB, watching what HQPlayer actually applied:
#
#   album_gain="-15"                  -> -15 dB   (OVERRODE the file's tag)
#   track_gain="-11"                  -> -8.61 dB (ignored, the tag won)
#   album_gain="-15" track_gain="-11" -> -15 dB   (album_gain wins)
#   gain="-4.07"                      -> ignored  (0.2.36, verbatim on the wire)
#   adaptive_volume="-20", as a metadata AND as a PlaylistAdd attribute
#                                     -> ignored
#
# album gain is HQPlayer's ONLY replaygain mode (`playlist_album_gain`, read by
# clPlaylist::GetAlbumGain - see assertRepeatOff), so there is no track-gain
# path for a track_gain attribute to feed. `gain` is a REPORT: <Status/> echoes
# what HQPlayer read out of the file, which is why it looked settable.
my ($metaSub) = $src =~ /\nsub _metadata \{(.*?)\n\}/s;
ok(scalar($metaSub && $metaSub =~ /album_gain\s*=>/),
   'the gain sidecar goes out as album_gain - the one attribute HQPlayer honours');
ok(scalar($metaSub && $metaSub !~ /\btrack_gain\s*=>/ && $metaSub !~ /\bgain\s*=>/),
   'and NOT as track_gain or gain, both proven ignored on the wire');

# The baseline guard: 0 is not a playlist position, and must not be stored or
# judged against. See the 0 -> 1 block below.
ok(scalar($src =~ /hqTrackNo\(\$track\)\s*\n?\s*if defined \$track && \$track =~ .+ && \$track > 0;/s),
   'track="0" is refused as a baseline at the point it would be stored');
my ($handedSub2) = $src =~ /\nsub _handedOver \{(.*?)\n\}/s;
ok(scalar($handedSub2 && $handedSub2 =~ /\$seen > 0/),
   'and _handedOver refuses to measure an advance from it');

my ($appendSub) = $src =~ /\nsub _appendTrack \{(.*?)\n\}/s;
ok($appendSub && $appendSub !~ /<Stop\/>|<PlaylistClear\/>/,
   'the hand-over never sends Stop or PlaylistClear - either would kill the playing track');

# <PlayNextURI> is the command that LOOKS like the right primitive for this -
# it exists for exactly this and nothing else, and Signalyst's own client has
# it.  Sent over a playing playlist item on engine 6.0.4 it answered
# result="OK" and then TOOK HQPLAYERD DOWN: both 4321 and 8019 stopped
# listening and it did not restart itself.  It stays in Control.pm's %KNOWN so
# tools/probe_gapless.py can re-test it on a future engine, and it must never
# be reachable from the player.
ok($src !~ /PlayNextURI/,
   'Player.pm never sends <PlayNextURI> - it answers OK and then kills the daemon');

# Volume used to go over UPnP RenderingControl, which took 300-550ms per call,
# so it needed a debounce timer (_flushVolume) to survive LMS's 6-step pause
# ramp.  It goes over the XML control link now - ~9ms - and the ramp steps are
# dropped at source instead, so there is no debounce left to test.  These two
# assertions still named _flushVolume, and passed anyway: see the note on ok().
print "-- volume channel --\n";
my ($volSub) = $src =~ /\nsub volume \{(.*?)\n\}/s;
ok($volSub, 'volume() is overridden');
ok($volSub && $volSub !~ /setVolume/,
   'volume() does not push to UPnP - the XML channel answers in ~9ms, UPnP in 300-550ms');
ok($volSub && $volSub =~ /return \$vol if \$temp/,
   'volume() drops LMS temporary levels rather than forwarding the pause ramp');
ok($volSub && $volSub =~ /hqVolDb/,
   'volume() checks the level HQPlayer is already at, so the two directions cannot chase each other');


# ---------------------------------------------------------------------------
# The paused-buffer trap.  _CheckPaused (reached from our own
# playerStatusHeartbeat while PAUSED) stops the source stream outright when a
# paused REMOTE track sits on a buffer over 98% full - LMS bug 10645, meant to
# release a connection LMS no longer needs.  HQPlayer keeps pulling from us the
# whole time it is paused, so a full-buffer claim made pause tear the stream
# down: HQPlayer got <Stop/>, the NAA dropped, and resume came back as a
# re-stream with a seek instead of a resume.
# ---------------------------------------------------------------------------
print "-- buffer reporting --\n";
my $fullness = Plugins::HQPlayerBridge::Player::bufferFullness();
my $bufsize  = Plugins::HQPlayerBridge::Player::bufferSize();
ok($bufsize > 0, 'bufferSize is non-zero');
ok($fullness / $bufsize <= 0.98,
   sprintf('usage() is %.2f - at or below the 0.98 _CheckPaused threshold', $fullness/$bufsize));
ok($fullness > 0, 'but not zero either - a starved buffer has its own consequences');

# ---------------------------------------------------------------------------
# Seek accounting.  playingSongElapsed computes startOffset + songElapsedSeconds,
# so songElapsedSeconds must be elapsed WITHIN THE STREAM.  Tier 1 hands
# HQPlayer a file URL and seeks inside HQPlayer, so its position is absolute
# and the offset has to come back off.  Tier 2 goes through /stream.mp3, which
# LMS already opens at the offset - seeking there would skip twice.
# ---------------------------------------------------------------------------
print "-- seek accounting --\n";
is($c->hqSeekOffset, '0', 'hqSeekOffset initialised to 0');

$c->hqPosition(42); $c->hqSeekOffset(0);
is($c->songElapsedSeconds, '42', 'no seek: position passes through');

$c->hqPosition(52); $c->hqSeekOffset(10);
is($c->songElapsedSeconds, '42', 'after a tier-1 seek the offset is subtracted, not added twice');

$c->hqPosition(3); $c->hqSeekOffset(10);
is($c->songElapsedSeconds, '0', 'a position behind the seek point clamps at zero, never negative');

my ($queueSub) = $src =~ /\nsub _queueTrack \{(.*?)\n\}/s;
ok(scalar($queueSub && $queueSub =~ /\$seekTier == 1 \|\| \$seekTier == 5.*?Seek/s),
   'Seek is sent on tiers 1 and 5 - the two where LMS is not in the byte path');
ok(scalar($queueSub && $queueSub !~ /seekTier == 4/),
   'and never on tier 4 - those bytes already start at the offset, so it would double it');
ok($queueSub && $queueSub =~ /hqSeekOffset\(/,
   'and the offset we asked HQPlayer to skip is recorded');


# ---------------------------------------------------------------------------
# Two-way transport.  Pausing at HQPlayer or on the endpoint's own remote has
# to pull LMS with it, without the follow-up echoing back out as a command.
#
# The comparison is against hqWanted - the last state WE asked HQPlayer for -
# never against the controller's state.  _Pause sets PAUSED about 300ms before
# it calls pause() on us (it fades the volume first), so a status push landing
# in that window would read as an external resume and un-pause the player.
# ---------------------------------------------------------------------------
print "-- two-way transport --\n";
{
    package FakeController;
    sub new { bless { paused => 0, calls => [] }, shift }
    sub isPaused { $_[0]->{paused} }
    sub pause    { push @{$_[0]->{calls}}, 'pause';  $_[0]->{paused} = 1 }
    sub resume   { push @{$_[0]->{calls}}, 'resume'; $_[0]->{paused} = 0 }
    sub playerStatusHeartbeat {}
    sub playerTrackStarted    {}
    sub playerEndOfStream     {}
    sub playerReadyToStream   {}
    sub playerStopped         {}
}

my @sent;
# Loading a track is now two commands on the control socket, each with a
# callback, so the mock has to hold the callbacks for the test to answer -
# @sentCb is the reply the daemon has not sent yet.
my @sentCb;
# TRAP THIS MOCK ONCE HID: Control::send's callback contract is ($attrs, $raw).
# $raw is the RAW REPLY on success as well as on failure - it is never an error
# string - and failure is $attrs being undef.  This mock used to pass '' as the
# second argument, so a callback that read it as ($res, $err) and tested $err
# passed every test here and then reported every SUCCESSFUL PlaylistAdd as
# "HQPlayer would not accept the track URI" on the live daemon, one
# PROBLEM_OPENING per track, playing nothing.  Answer the way Control.pm does.
sub _answer {           # answer the oldest outstanding command, OK unless told
    my $ok = @_ ? shift : 1;
    my $cb = shift @sentCb or return 0;
    my $raw = '<?xml version="1.0" encoding="utf-8"?><PlaylistAdd result="'
            . ( $ok ? 'OK' : 'Error' ) . '"/>';
    $cb->( $ok ? { result => 'OK' } : undef, $raw );
    return 1;
}
{
    no warnings 'redefine';
    *Plugins::HQPlayerBridge::Player::_send      = sub {
        push @sent, $_[1];
        push @sentCb, $_[2] if $_[2];
        return;
    };
    *Plugins::HQPlayerBridge::Player::_startPolling = sub {};
    *Plugins::HQPlayerBridge::Player::_stopPolling  = sub {};
}

my $ctl = FakeController->new;
$c->controller($ctl);
$c->hqStarted(1);
$c->hqWanted('play');

# HQPlayer reports paused, and we did not ask for it -> follow it into LMS
@sent = ();
$c->_onStatus({ state => 1, position => 30 }, '');
is(join(',', @{$ctl->{calls}}), 'pause', 'a pause at HQPlayer pauses LMS');
is($c->hqWanted, 'pause', 'and is recorded as the state we now want');

# LMS answers that by calling pause() on us ~300ms later - it must not go back out
$c->pause;
is(scalar(@sent), '0', 'the follow-up pause() is not echoed back to HQPlayer');

# same in reverse
$ctl->{calls} = [];
$c->_onStatus({ state => 2, position => 30 }, '');
is(join(',', @{$ctl->{calls}}), 'resume', 'a resume at HQPlayer resumes LMS');
is($c->hqWanted, 'play', 'and is recorded');
$c->resume;
is(scalar(@sent), '0', 'the follow-up resume() is not echoed back either');

# a pause that DID start in LMS still reaches HQPlayer, exactly once
$ctl->{calls} = [];
@sent = ();
$c->hqWanted('play');
$c->pause;
is(join(',', @sent), '<Pause/>', 'a pause from LMS is sent on');
$c->pause;
is(scalar(@sent), '1', 'but never sent twice - <Pause/> could toggle');

# and HQPlayer confirming that pause must not bounce back as a command
$ctl->{calls} = [];
$c->_onStatus({ state => 1, position => 31 }, '');
is(scalar(@{$ctl->{calls}}), '0', 'HQPlayer confirming our own pause is not treated as external');

# the race: controller already PAUSED, HQPlayer still reporting PLAYING because
# our <Pause/> has not gone out yet.  Must not read as an external resume.
$ctl->{paused} = 1;
$ctl->{calls}  = [];
$c->hqWanted('pause');
$c->_onStatus({ state => 2, position => 31 }, '');
is(join(',', @{$ctl->{calls}}), 'resume', 'a genuine external resume is followed');
$ctl->{paused} = 1;
$ctl->{calls}  = [];
$c->hqWanted('play');
$c->_onStatus({ state => 2, position => 31 }, '');
is(scalar(@{$ctl->{calls}}), '0',
   'but a PLAYING push during our own 300ms pause fade does NOT un-pause LMS');


# ---------------------------------------------------------------------------
# Volume is SHARED, not owned.  HQPlayer holds the real level in dB and splits
# it between the endpoint's attenuator and its own software gain; LMS holds an
# 0-100 slider.  hqVolDb is the last level we know HQPlayer is at, and it is
# what stops the two directions chasing each other round.
# ---------------------------------------------------------------------------
print "-- volume mapping --\n";
is($c->_lmsToDb(100), '0',    'LMS 100 is 0dB');
is($c->_lmsToDb(50),  '-50',  'on a -100..0 instance one LMS step is 1dB');
is($c->_lmsToDb(0),   '-100', 'LMS 0 is the floor');
is($c->_lmsToDb(150), '0',    'over-range clamps to the ceiling');
is($c->_lmsToDb(-47), '-100', 'mute arrives as a negative level and goes to the floor');
is($c->_dbToLms(-53), '47',   'and back again');
# int() truncates towards zero, and every dB figure here is negative
is($c->_dbToLms(-53.4), '47',  'a fractional dB rounds towards the nearer step, not towards zero');
is($c->_dbToLms(-999),'0',    'under-range clamps to 0');

# THE RANGE IS A SETTING, NOT A CONSTANT.  HQPlayer defaults to -60..0, this
# instance is -100..0, and a user may cap the top as well as the floor.
print "-- volume mapping on other ranges --\n";
$c->hqVolMin(-60); $c->hqVolMax(0);
is($c->_lmsToDb(100), '0',   'a -60..0 instance still tops out at 0dB');
is($c->_lmsToDb(0),   '-60', 'and bottoms out at ITS floor, not at -100');
is($c->_lmsToDb(50),  '-30', 'the slider spans the whole range');
is($c->_dbToLms(-30), '50',  'and inverts');

$c->hqVolMin(-60); $c->hqVolMax(-20);
is($c->_lmsToDb(100), '-20', 'a -60..-20 instance tops out at -20dB');
is($c->_lmsToDb(0),   '-60', 'and bottoms out at -60dB');
is($c->_lmsToDb(50),  '-40', 'mid-slider is mid-range');
is($c->_dbToLms(-40), '50',  'and inverts');

# NO DEAD INCREMENTS.  HQPlayer takes fractional dB (verified live: -39.25 is
# reported back verbatim), so every one of the 101 positions gets a level of
# its own - on any range, however narrow.
for my $range ([-100,0], [-60,0], [-60,-20], [-30,-20]) {
    $c->hqVolMin($range->[0]); $c->hqVolMax($range->[1]);
    my ($mono, $prev) = (1, undef);
    for my $v (0..100) {
        my $db = $c->_lmsToDb($v);
        $mono = 0 if defined $prev && $db <= $prev;
        $prev = $db;
    }
    ok($mono, "every slider step changes the level on a $range->[0]..$range->[1] instance");
}

# It round-trips through a 32-bit float on the wire, so stay on a binary grid.
$c->hqVolMin(-60); $c->hqVolMax(0);
is(Plugins::HQPlayerBridge::Player::_fmtDb($c->_lmsToDb(37)), '-37.75',
   'a fractional level is quantised to a binary fraction of a dB');
$c->hqVolMin(-100); $c->hqVolMax(0);
is(Plugins::HQPlayerBridge::Player::_fmtDb($c->_lmsToDb(47)), '-53',
   'and a whole dB is still sent as a whole number');

print "-- volume both ways --\n";
my @ex;
{
    no warnings 'redefine';
    *Slim::Player::Client::execute = sub { push @ex, join(' ', @{$_[1]}) };
}

@sent = ();
$c->hqVolDb(undef);
$c->volume(47);
is(join(',', @sent), '<Volume value="-53"/>', 'an LMS change is sent on in dB');
$c->volume(47);
is(scalar(@sent), '1', 'the same level again is not re-sent');

# TRAP: the second arg is $temp, not "force".  Every step of LMS's pause/resume
# volume ramp arrives with it set, and none of them are ours to forward.
@sent = ();
$c->volume(30, 1); $c->volume(20, 1); $c->volume(0, 1);
is(scalar(@sent), '0', 'temporary volumes (the pause fade) are never forwarded');

# HQPlayer's own UI, or the endpoint's remote, moved it.  Note the temporary 0
# still parked by the ramp above: the inbound guard has to read the PERSISTED
# level, or a push landing inside _Resume's fade window reads as "the endpoint
# just dropped to the floor".
@sent = (); @ex = ();
$c->_onStatus({ state => 2, position => 5, volume => -40 }, '');
is(join(',', @ex), 'mixer volume 60', 'a change at HQPlayer is mirrored into LMS');
is(scalar(@sent), '0', 'and is NOT sent straight back out');
is($c->hqVolDb, '-40', 'hqVolDb tracks where HQPlayer actually is');
$c->volume(60);
is(scalar(@sent), '0', 'the mixer command it triggers does not echo either');

@ex = ();
$c->_onStatus({ state => 2, position => 6, volume => -40 }, '');
is(scalar(@ex), '0', 'an unchanged volume in the status stream does nothing');

# THE SNAP.  LMS re-asserts its STORED volume at the start of every track that
# begins from stopped (StreamingController, "Bug 10310").  A level set on the
# endpoint's own knob will not land on LMS's 101-step grid, so without a
# tolerance that re-assert drags the endpoint back onto the rounded value -
# which is exactly the reported "LMS changes the volume on the next track".
print "-- a level set on the endpoint survives a track change --\n";
@sent = (); @ex = ();
$c->_onStatus({ state => 2, position => 7, volume => -39.6 }, '');
is(scalar(@ex), '0', 'an off-grid level within half a step does not move the slider');
is($c->hqVolDb, '-39.6', 'but it is recorded as where HQPlayer actually is');
$c->volume(60);   # the track-start re-assert, with LMS's stored 60
is(scalar(@sent), '0', 'and the track-start re-assert does not drag it back');

@sent = ();
$c->volume(58);
is(join(',', @sent), '<Volume value="-42"/>', 'a real slider move is still sent');

# A LEVEL SET OUTSIDE LMS IS ALWAYS FOLLOWED - THE USER OWNS THE VOLUME.
#
# 0.2.31 shipped a guard that refused an INCREASE for ten seconds after a
# "link-up", because a re-registering endpoint announces its own stored level
# and once jumped the output +21dB unasked (LIVE 2026-08-28, an Eversolo NAA,
# two pushes 600ms apart: -39dB then -18dB).
#
# It was removed 2026-08-30: its trigger, `transport_serial`, turns over at
# EVERY TRACK BOUNDARY - measured 4->5->6->7->8->9 across five boundaries in
# one album - so the guard was armed for ten seconds after every track change
# and pulled back the user's own volume changes. These tests pin the removal:
# nothing may second-guess a level that arrives from the endpoint.
print "-- a level set outside LMS is always followed --\n";
{
    my $sp2 = Slim::Utils::Prefs::preferences('server');

    # settle on -40dB (LMS 60)
    @sent = (); @ex = ();
    $c->_onStatus({ state => 2, position => 8, volume => -40 }, '');
    $sp2->client($c)->set('volume', 60);
    $c->hqVolDb(-40);

    # a big jump UP is followed, and nothing is sent back to pull it down
    @sent = (); @ex = ();
    $c->_onStatus({ state => 2, position => 9, volume => -18 }, '');
    is(join(',', @ex), 'mixer volume 82', 'a +22dB jump is followed into LMS');
    is(scalar(@sent), '0', 'and nothing is sent back to pull it down');

    # a drop is followed too
    $sp2->client($c)->set('volume', 60);
    $c->hqVolDb(-40);
    @sent = (); @ex = ();
    $c->_onStatus({ state => 2, position => 10, volume => -60 }, '');
    is(join(',', @ex), 'mixer volume 40', 'a drop is followed');
    is(scalar(@sent), '0', 'and is not echoed back either');

    # THE REGRESSION THIS REPLACES: transport_serial changes at every track
    # boundary, so a volume change that happens to land next to one must still
    # be honoured.
    $sp2->client($c)->set('volume', 60);
    $c->hqVolDb(-40);
    @sent = (); @ex = ();
    $c->_onStatus({ state => 2, position => 13, volume => -18, transport_serial => 8 }, '');
    is(join(',', @ex), 'mixer volume 82',
       'a jump alongside a transport_serial change is STILL followed');
    is(scalar(@sent), '0', 'and is not pulled back');

    $sp2->client($c)->set('volume', 60);
    $c->hqVolDb(-40);
}

# Some HQPlayer setups do not attenuate at all - the DAC or the amp holds the
# volume - and the LMS slider must sit at the top rather than pretend.
print "-- fixed volume --\n";
my $sp = Slim::Utils::Prefs::preferences('server');
@sent = (); @ex = ();
$c->_setFixed(1);
is($c->hqVolFixed, '1', 'a zero-width range locks the volume');
is(join(',', @ex), 'mixer volume 100', 'and parks the LMS slider at the top');
is($sp->client($c)->get('digitalVolumeControl'), '0',
   'via the pref LMS turns into use_volume_control:0, which the skins disable the slider on');
@sent = ();
$c->volume(40);
is(scalar(@sent), '0', 'nothing is sent to HQPlayer while it is not attenuating');
$c->_setFixed(0);
is($sp->client($c)->get('digitalVolumeControl'), '1', 'and it unlocks again');

# LMS's own "Volume Control: fixed" radio means the same thing, and is the
# user's, not ours: honour it, and never write it back to variable.
$sp->client($c)->set('digitalVolumeControl', 0);
@sent = ();
$c->volume(35);
is(scalar(@sent), '0', "a user's own fixed-volume setting stops us sending too");
$c->_setFixed(1); $c->_setFixed(0);
is($sp->client($c)->get('digitalVolumeControl'), '0',
   'and a 0 we did not set is never written back to 1');
$sp->client($c)->set('digitalVolumeControl', 1);

# The range is READ, not assumed.  VERIFIED live: HQPlayer does implement UPnP
# GetVolumeDBRange even though the XML control API calls it an unknown command.
print "-- learning the range --\n";
@ex = ();
$c->hqVolDb(-30);
$c->_setRange(-60, 0);
is($c->_volStep, '0.6', 'the size of a slider step follows the range');
is(join(',', @ex), 'mixer volume 50',
   'and the slider is re-derived from where HQPlayer is, not left reading the old scale');

# The fallback, and the only route that survives a mid-session reconfigure:
# ask for a level below the floor and HQPlayer answers with the floor itself.
@sent = (); @ex = ();
$c->hqVolMin(-100); $c->hqVolMax(0);
$c->volume(0);                                   # asks for the floor we believe in
$c->_onStatus({ state => 0, position => 0, volume => -60 }, '');
is($c->hqVolMin, '-60', 'a clamped reply teaches us the real floor');
is($c->hqVolMax, '0',   'and leaves the ceiling alone');

# The other fixed-volume tell: it accepts the command and does not move.
$c->hqVolMin(-100); $c->hqVolMax(0);
$c->hqVolDb(-50); $c->hqVolMissed(0); $c->hqVolFixed(0);
for ( 1 .. 3 ) {
    $c->hqVolSent(-70);
    $c->hqVolSentAt( Time::HiRes::time() - 5 );
    $c->_followVolume(-50);
}
is($c->hqVolFixed, '1', 'three sends that change nothing mark the volume fixed');
$c->_setFixed(0);
$sp->client($c)->set('digitalVolumeControl', 1);
$c->hqVolDb(undef);

print "-- fade_volume --\n";
my $fired = 0;
$c->_tempVolume(0);
$c->fade_volume(-0.3125, sub { $fired++ });
is($fired, '1', 'the callback fires immediately - it is what actually pauses');
is($c->_tempVolume, '(undef)',
   'and the ramp temporary volume is cleared, or the slider reads zero after a resume');


# ---------------------------------------------------------------------------
# Track changes.  Loading a track is several async round trips, and HQPlayer
# pushes status ~1/s throughout, so a track change always straddles a push or
# two.  Two ways that used to go wrong, both of which skip a track:
#
#   * play() cleared hqExpectStop immediately, so the stop WE sent to end the
#     previous track arrived as an unexplained stop - i.e. end-of-track - and
#     LMS advanced past the track it had just started.
#   * the load's completion callback was never cancelled, so a stop or a skip
#     during the load window still re-asserted bufferReady and applied the OLD
#     track's seek offset to the new one.
# ---------------------------------------------------------------------------
print "-- track changes --\n";
{
    package LoadUPnP;
    sub new   { bless { ready => 1, cancels => 0, uris => [] }, shift }
    sub ready { $_[0]->{ready} }
    sub cancelPlay { $_[0]->{cancels}++ }
    sub setURI {
        my ( $s, $url, $didl, $cb ) = @_;
        push @{ $s->{uris} }, $url;
        $s->{didl}  = $didl;
        $s->{uriCb} = $cb;
    }
    sub playWhenReady { $_[1] and $_[0]->{playCb} = $_[1] }
    # the daemon answering, whenever the test says it does
    sub finishURI  { my $cb = delete $_[0]->{uriCb};  $cb->( 'ok', undef ) if $cb }
    sub finishPlay { my $cb = delete $_[0]->{playCb}; $cb->( 'ok', undef ) if $cb }

    package LoadController;
    sub new { bless { song => $_[1], calls => [] }, $_[0] }
    sub song { $_[0]->{song} }
    sub isPaused { 0 }
    # Declared rather than AUTOLOADed: these are QUERIES, and letting them fall
    # through would record them in {calls} alongside the notifications the
    # tests assert on.  isPlaying(1) is the controller's own "playingState is
    # PLAYING", which _queueTrack uses to skip a BufferReady the state table
    # would answer with _Invalid.
    sub isPlaying { $_[0]->{playing} ? 1 : 0 }
    sub AUTOLOAD {
        our $AUTOLOAD;
        my $m = $AUTOLOAD; $m =~ s/.*:://;
        return if $m eq 'DESTROY';
        push @{ $_[0]->{calls} }, $m;
        return;
    }
}

my $up  = LoadUPnP->new;
my $one = FakeSong->new( FakeTrack->new({ title=>'One', id=>101, ct=>'flc', secs=>200, url=>'file:///one.flac' }) );
my $two = FakeSong->new( FakeTrack->new({ title=>'Two', id=>202, ct=>'flc', secs=>200, url=>'file:///two.flac' }) );

my $p = Plugins::HQPlayerBridge::Player->new('02:11:22:33:44:55', 'paddr', 1.0, undef, 12, undef);
$p->hqUPnP($up);
# _queueTrack refuses to load without a control link now that the load runs on
# it.  _send itself is mocked above, so this only has to be present and true.
$p->hqControl( bless {}, 'FakeCtl' );
my $lc = LoadController->new($one);
$p->controller($lc);

# Pretend the track has been playing a while.  HQPlayer reports PLAYING as soon
# as it accepts a stream and can drop back to STOPPED for a moment while the
# first bytes arrive, so a stop inside START_GRACE of the start is start-up
# noise rather than the end - see the HQP_STOPPED branch.  A test that fires a
# stop microseconds after the start is exercising that guard, not end-of-track,
# so age the player first wherever a REAL end is meant.
sub aged { $_[0]->hqStartedAt( Time::HiRes::time() - 30 ); return }

# helper: one pushed <Status/>, with the metadata child HQPlayer really sends.
# $track is HQPlayer's own playlist index (it reports track="n" tracks_total="n"
# on every push), which is what a gapless hand-over is observed by.
sub status {
    my ( $player, $state, $uri, $pos, $track ) = @_;
    my %a = ( state => $state, position => $pos // 0 );
    $a{track} = $track if defined $track;
    my $raw = qq{<Status state="$state" position="} . ( $pos // 0 ) . q{"}
            . ( defined $track ? qq{ track="$track" tracks_total="$track"} : '' )
            . q{>}
            . ( $uri ? qq{<metadata bits="24" samplerate="96000" uri="$uri"/>} : '' )
            . q{</Status>};
    $player->_onStatus( \%a, $raw );
    return;
}

@sent = (); @sentCb = ();
$p->play({ controller => $lc });

my ($addCmd) = grep { /^<PlaylistAdd\b/ } @sent;
print "  >> EMITTED: $addCmd\n" if $ENV{SHOWCMD};
my ($url1)   = $addCmd ? $addCmd =~ m{\buri="([^"]+)"} : ();

ok($url1 && $url1 =~ m{/music/101/download\.flac}, 'play() hands HQPlayer the tier-1 URL');

# THE ORDER IS THE FIX.  Splitting the load across two channels - <Stop/> on
# the control socket, SetAVTransportURI/Play over UPnP - meant a Stop for the
# OLD track could land after the Play for the new one, because a control
# command answers in ~9-150ms and a UPnP round trip in 300-550ms.  HQPlayer's
# AVTransport never saw a Stop at all, so the engine's playlist was emptied
# underneath a renderer that still thought it was playing: that is
# clPlaylist::GetAlbumGain(): trackn > last, the fatal that killed hqplayerd
# whenever an album was loaded over a playing one.  One socket, one order.
is(join(',', grep { !/^<Seek/ } @sent),
   '<Stop/>,<PlaylistClear/>,' . $addCmd,
   'the load opens with three ordered commands on the control socket');

# <Play/> is deliberately NOT sent yet: it is chained off PlaylistAdd's reply,
# so HQPlayer can never be told to play a queue it has not confirmed loading.
ok(scalar(!grep { $_ eq '<Play/>' } @sent), 'and Play waits for PlaylistAdd to be acknowledged');

# EVERY ATTRIBUTE IS WRITTEN, as Signalyst's own client does - it always emits
# uri/queued/clear/start/freewheel, defaults included.  An omitted attribute has
# cost this repo before (the <Status/> subscribe flag), so nothing is left to
# HQPlayer's own defaults.
#
# clear is 0, not 1: it is IGNORED by engine 6.0.4 - PlaylistAdd answers OK and
# APPENDS anyway - which is why the explicit <PlaylistClear/> above is load
# bearing.  Sending it as 1 asked for something we know is not honoured.
ok(scalar($addCmd =~ m{\bclear="0"}), 'clear is written explicitly as 0 - the explicit PlaylistClear does the work');
ok(scalar($addCmd =~ m{\bstart="0"}), 'start is written explicitly as 0 - the separate <Play/> starts playback');
ok(scalar($addCmd =~ m{\bfreewheel="1"}), 'freewheel is ON - fetch the track rather than pull it at playback rate');
ok(scalar($addCmd =~ m{\bqueued="0"}), 'and queued stays 0 - queued="1" kills the daemon');

# The artwork lever.  cover= takes a PLAIN url and HQPlayer base64-encodes it
# into the item's `picture` itself - verified byte-identical to the DIDL path
# against engine 6.0.4 on 2026-08-28.  picture=/albumArtURI=/art= and a
# <picture> child are all silently ignored.
ok(scalar($addCmd =~ m{<metadata\b[^>]*\bcover="https?://[^"]*/cover\.jpg"}),
   'the load carries <metadata cover="..."> - this is what sets the picture field');
is($p->hqExpectStop, '1',
   'play() leaves the stop guard ARMED - the stop that ended the previous track is still in flight');
is($p->hqPlayAck, '0', 'and the track is not acknowledged until HQPlayer accepts Play');

# a push describing the PREVIOUS track, arriving after play() has set up this one
$p->hqPrevURL('http://127.0.0.1:9000/music/999/download.flac');
status($p, 2, 'http://127.0.0.1:9000/music/999/download.flac', 197);
is($p->hqStarted, '0', 'a PLAYING push for the previous track does not start this one');
is($p->hqPosition, '0',
   "and its position (197s into the previous track) is not adopted as ours");
$p->hqPrevURL(undef);

# ... and even with no way to tell the tracks apart (a push carrying no uri at
# all), an unacknowledged PLAYING is not a start
status($p, 2, undef, 0);
is($p->hqStarted, '0', 'an unacknowledged PLAYING push is never taken as a start');

# the stop we sent to end the previous track finally lands
$lc->{calls} = [];
status($p, 0, undef, 0);
is(scalar(@{$lc->{calls}}), '0',
   'our own stop, arriving during the load, is NOT reported as end-of-track');

# HQPlayer accepts the track and starts playing it: PlaylistAdd answers, which
# sends <Play/>, and then Play answers.
$lc->{calls} = [];
_answer();      # PlaylistAdd -> OK
ok(scalar(grep { $_ eq '<Play/>' } @sent), 'PlaylistAdd acknowledged -> Play follows, in order');

# A SUCCESSFUL reply must never be read as a failure.  0.2.13 shipped reading
# the callback's second argument as an error - it is the raw reply, present on
# success too - so every load reported PROBLEM_OPENING, LMS skipped to the next
# track, and the player raced the whole playlist without playing anything.
ok(scalar(!grep { $_ eq 'playerStreamingFailed' } @{$lc->{calls}}),
   'an OK PlaylistAdd is NOT reported as a failed load');

_answer();      # Play        -> OK
is($p->hqPlayAck, '1', 'Play accepted -> the track is acknowledged');
ok(scalar(!grep { $_ eq 'playerStreamingFailed' } @{$lc->{calls}}),
   'nor is an OK Play');
is($p->bufferReady, '1', 'and the buffer is asserted for the controller');

$lc->{calls} = [];
status($p, 2, $url1, 1);
is($p->hqStarted, '1', 'now a PLAYING push starts the track');
is(join(',', @{$lc->{calls}}), 'playerTrackStarted,playerReadyToStream,playerStatusHeartbeat',
   'and Started is signalled, exactly once, ahead of the heartbeat');
# ReadyToStream rides along with it now: that is the request for the next
# track, and it is what makes the hand-over possible at all.  It must come
# AFTER Started, or LMS is asked for a second song before the first is playing.
is($p->hqArmNext, '1', 'and the next track is asked for, once the first is playing');
is($p->hqExpectStop, '0', 'the stop guard is disarmed only now');

# genuine end of playlist - LMS had no next track to hand over
$lc->{calls} = [];
$p->hqArmNext(0);
aged($p);
status($p, 0, $url1, 200);
is(join(',', @{$lc->{calls}}), 'playerEndOfStream,playerReadyToStream,playerStopped',
   'HQPlayer stopping on its own IS end-of-track');

print "-- a load that genuinely fails --\n";
{
    # The other half of the contract: $attrs undef IS the failure, and it must
    # still reach the controller.  Without this the guard above could simply be
    # inverted and both would pass.
    my $fp = Plugins::HQPlayerBridge::Player->new('02:99:88:77:66:55', 'paddr', 1.0, undef, 12, undef);
    $fp->hqUPnP( LoadUPnP->new );
    $fp->hqControl( bless {}, 'FakeCtl' );
    my $fc = LoadController->new($one);
    $fp->controller($fc);

    @sent = (); @sentCb = ();
    $fp->play({ controller => $fc });
    $fc->{calls} = [];
    _answer(0);     # PlaylistAdd -> Error
    ok(scalar(grep { $_ eq 'playerStreamingFailed' } @{$fc->{calls}}),
       'a rejected PlaylistAdd IS reported as a failed load');
    ok(scalar(!grep { $_ eq '<Play/>' } @sent),
       'and Play is never sent for a track HQPlayer refused');
}

print "-- a load superseded mid-flight --\n";
# skip: play track two, then stop before HQPlayer has answered
$p->play({ controller => LoadController->new($two) });
my $gen = $p->hqGen;
$p->stop;
ok($p->hqGen != $gen, 'stop() supersedes the load that was in flight');
is($up->{cancels}, '3', 'and the UPnP Play retry loop is cancelled each time');

$p->bufferReady(0);
$lc->{calls} = [];
$up->finishURI;
$up->finishPlay;
is($p->bufferReady, '0',
   'the superseded load does not re-assert bufferReady after the stop');
is($p->hqPlayAck, '0', 'nor acknowledge a track that is no longer wanted');

# skip mid-load: the old track's seek must not be applied to the new one
@sent = ();
$p->play({ controller => LoadController->new($one), seekdata => { timeOffset => 90 } });
$p->play({ controller => LoadController->new($two) });   # skipped before it loaded
$up->finishURI;
$up->finishPlay;
is(join(',', grep { /Seek/ } @sent), '',
   "the skipped track's seek is not sent to the track that replaced it");
is($p->hqSeekOffset, '0', 'and no phantom seek offset is left on the elapsed time');


# ---------------------------------------------------------------------------
# GAPLESS.  The bridge used to feed HQPlayer exactly one item at a time, so
# every track end was an end of playlist and the next track only started after
# LMS had seen the stop and run a fresh four-command load - and that round trip
# IS the gap.  HQPlayer is gapless between the items of its own playlist, so
# the fix is to put the next track there before it is needed.
#
# The two halves are asserted separately, because they fail differently:
#
#   * play() must APPEND for a hand-over.  A Stop or a PlaylistClear there
#     kills the track that is playing.
#   * _onStatus must recognise the advance WITHOUT a state 0, because with two
#     items on the playlist HQPlayer never stops between them.  Missing it is
#     not fatal (it degrades to the old behaviour at the end of the playlist)
#     but reporting an end-of-stream for it would reload the track playing.
# ---------------------------------------------------------------------------
print "-- gapless hand-over --\n";
{
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:ee', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer();      # PlaylistAdd
    _answer();      # Play

    # track one starts, and the request for track two rides along with it
    $gc->{calls} = [];
    status( $gp, 2, $u1, 1, 1 );
    is( $gp->hqArmNext, '1', 'a track starting arms the request for the next one' );
    ok( scalar( grep { $_ eq 'playerReadyToStream' } @{ $gc->{calls} } ),
        'and ReadyToStream is what asks LMS for it' );

    # LMS answers with track two WHILE track one is still playing
    @sent = (); @sentCb = ();
    $gc->{song}    = $two;
    $gc->{playing} = 1;      # the controller is PLAYING track one
    $gp->play({ controller => $gc });

    is( $gp->hqArmNext, '0', 'the hand-over consumes the flag' );
    is( scalar(@sent), '1', 'a hand-over is ONE command - no Stop, no PlaylistClear, no Play' );
    ok( scalar( $sent[0] =~ /^<PlaylistAdd\b/ ), 'and that command is the append' );
    # queued="0", NOT queued="1".  Isolated live 2026-08-28: appending
    # mid-playback with queued="1" leaves HQPlayer's track index inconsistent,
    # and at the end of the LAST item the engine walks past it -
    # clPlaylist::GetAlbumGain(): trackn > last, and the DAEMON EXITS.  Four
    # controlled runs: queued="0" survived twice, queued="1" died twice, and
    # trimming the playlist back to one item first did not save it.  queued="0"
    # appends just the same and advances just the same.
    ok( scalar( $sent[0] =~ /\bqueued="0"/ ),
        'the append uses queued="0" - queued="1" corrupts the index and kills hqplayerd' );
    ok( scalar( $sent[0] !~ /\bqueued="1"/ ), 'and queued="1" appears nowhere in it' );
    ok( scalar( $sent[0] =~ m{<metadata\b[^>]*\bcover="} ),
        'the pre-queued item carries its own artwork - HQPlayer forwards it at the transition' );

    my ($u2) = $sent[0] =~ m{\buri="([^"]+)"};
    ok( $u2 && $u2 =~ m{/music/202/download\.flac}, 'and it is track two, not track one again' );
    is( $gp->hqURL, $u1, 'hqURL still names the track that is PLAYING, not the queued one' );
    is( $gp->hqStarted, '1', 'and the playing track is untouched' );

    _answer();      # the append is accepted
    is( $gp->hqNext && $gp->hqNext->{acked}, '1', 'HQPlayer confirms it holds the next track' );

    # HQPlayer advances by itself.  NO state 0 - it never stops - so the
    # playlist index moving from 1 to 2 is the only signal there is.
    $gc->{calls} = [];
    status( $gp, 2, $u2, 0, 2 );

    is( join( ',', @{ $gc->{calls} } ),
        'playerTrackStarted,playerReadyToStream,playerStatusHeartbeat',
        'the advance reports Started - and immediately asks for the track after it' );
    is( $gp->hqURL, $u2, 'the pre-queued track is now the current one' );
    is( $gp->hqPrevURL, $u1, 'and the one it replaced is remembered, so its late pushes read as stale' );
    is( $gp->hqStarted, '1', 'the player never stopped' );
    is( $gp->hqNext, '(undef)', 'and nothing is queued any more' );
    is( $gp->hqTrackNo, '2', "HQPlayer's own playlist index is followed" );

    # end of the LAST item is still a real end of playlist
    $gc->{calls} = [];
    $gp->hqArmNext(0);
    aged($gp);
    status( $gp, 0, $u2, 200, 2 );
    is( join( ',', @{ $gc->{calls} } ), 'playerEndOfStream,playerReadyToStream,playerStopped',
        'state 0 now means end of PLAYLIST, and is still reported as end-of-stream' );
}

print "-- gapless: the spurious advance that froze LMS --\n";
{
    # LIVE FAILURE 2026-08-28.  The first cut fired on "the playlist index
    # changed OR the uri matches", and declared the hand-over 0.2s after
    # queueing the track, while HQPlayer was still playing the previous one.
    #
    # That failure is NOT self-correcting: hqURL then names a track HQPlayer
    # is not playing and hqPrevURL names the one it IS, so _isStale suppresses
    # every subsequent push as "the previous track".  Position freezes, LMS
    # shows the wrong track, nothing recovers.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f3', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    @sent = (); @sentCb = ();
    $gc->{song}    = $two;
    $gc->{playing} = 1;
    $gp->play({ controller => $gc });
    my ($u2) = $sent[0] =~ m{\buri="([^"]+)"};

    # not acknowledged yet - nothing may be read as an advance, whatever the
    # index does
    $gc->{calls} = [];
    status( $gp, 2, $u1, 2, 9 );
    is( $gp->hqURL, $u1, 'an index jump BEFORE the append is acknowledged is not an advance' );

    _answer();      # now HQPlayer confirms it holds the track

    # THE URI IS A VETO.  HQPlayer says it is still playing track one, so the
    # index moving cannot mean the hand-over happened.
    $gc->{calls} = [];
    status( $gp, 2, $u1, 3, 7 );
    is( $gp->hqURL, $u1,
        'an index jump while HQPlayer still names track one is NOT an advance' );
    is( join( ',', @{ $gc->{calls} } ), 'playerStatusHeartbeat',
        'and nothing is reported to LMS' );

    # THE SAME TRACK TWICE.  A duplicate in the queue - or repeat-one - makes
    # the queued url identical to the playing one, so "HQPlayer is playing what
    # we queued" is true BEFORE the advance as well as after.  Live, that fired
    # two advances 0.2s apart and LMS skipped a playlist entry.  With the urls
    # ambiguous the index is the only thing left that can tell them apart.
    {
        my $dp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f8', 'paddr', 1.0, undef, 12, undef);
        $dp->hqUPnP( LoadUPnP->new );
        $dp->hqControl( bless {}, 'FakeCtl' );
        my $dc = LoadController->new($one);
        $dp->controller($dc);

        @sent = (); @sentCb = ();
        $dp->play({ controller => $dc });
        my ($d1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
        _answer(); _answer();
        status( $dp, 2, $d1, 1, 1 );

        # LMS hands over the SAME track again
        @sent = (); @sentCb = ();
        $dc->{song} = $one;
        $dc->{playing} = 1;
        $dp->play({ controller => $dc });
        _answer();

        $dc->{calls} = [];
        status( $dp, 2, $d1, 3, 1 );
        is( join( ',', @{ $dc->{calls} } ), 'playerStatusHeartbeat',
            'the same url queued twice does NOT advance on the uri alone' );

        $dc->{calls} = [];
        status( $dp, 2, $d1, 0, 2 );
        ok( scalar( grep { $_ eq 'playerTrackStarted' } @{ $dc->{calls} } ),
            'it advances when the playlist INDEX moves on, which is all that can tell them apart' );
    }

    # a stop is not an advance either - HQPlayer reports track="0" when idle,
    # so "the index changed" would read every stop as a hand-over
    $gp->hqTrackNo(1);
    status( $gp, 2, undef, 4, 0 );
    is( $gp->hqURL, $u1, 'track going to 0 with no uri is not an advance - only an INCREASE is' );

    # the real thing: HQPlayer names the track we queued
    $gc->{calls} = [];
    status( $gp, 2, $u2, 0, 2 );
    is( $gp->hqURL, $u2, 'HQPlayer naming the queued url IS the advance' );
    is( join( ',', @{ $gc->{calls} } ),
        'playerTrackStarted,playerReadyToStream,playerStatusHeartbeat',
        'and only then is Started reported' );
}

print "-- a gapless boundary must not be read as the end of the playlist --\n";
{
    # LIVE FAILURE 2026-08-28.  200ms after a correct hand-over, HQPlayer
    # pushes a TRANSIENT state 0 with everything zeroed and no metadata child -
    # byte-identical to the push a real end of playlist produces:
    #
    #   state="2" track="2/3" uri=".../437344.flac"   <- handed over
    #   state="0" track="0"   tracks_total="0"        <- 200ms later
    #   state="2" track="3/4" uri=".../437344.flac"   <- 2s later
    #
    # Read as the end it reported EndOfStream/Stopped mid-album: LMS advanced
    # an extra track, stopped, and every push after that arrived at a
    # controller in STOPPED/IDLE where TrackStarted is _Invalid.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f5', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    # LMS hands over track two, HQPlayer acknowledges it
    @sent = (); @sentCb = ();
    $gc->{song}    = $two;
    $gc->{playing} = 1;
    $gp->play({ controller => $gc });
    my ($u2) = $sent[0] =~ m{\buri="([^"]+)"};
    _answer();

    Slim::Utils::Timers::_reset();

    # the transient: stopped, everything zeroed, nothing to distinguish it
    $gc->{calls} = [];
    aged($gp);
    status( $gp, 0, undef, 0, 0 );

    is( join( ',', @{ $gc->{calls} } ), '',
        'a stop with a hand-over queued is NOT reported straight away' );
    is( $gp->hqStarted, '1', 'and the track is still considered playing' );
    is( Slim::Utils::Timers::_pending(), '1', 'it is held on a timer instead' );

    # ...and HQPlayer comes back, so it was a boundary after all
    status( $gp, 2, $u2, 0, 2 );
    is( Slim::Utils::Timers::_pending(), '0',
        'HQPlayer playing again cancels the pending end-of-playlist' );
    is( $gp->hqURL, $u2, 'and the hand-over completes normally' );
}

{
    # The other half: a stop that is REAL must still be reported, just
    # END_GRACE later.  Without this the debounce would swallow a stop made at
    # HQPlayer's own UI whenever a hand-over happened to be queued.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f6', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    $gc->{song} = $two; $gc->{playing} = 1;
    $gp->play({ controller => $gc });
    _answer();

    Slim::Utils::Timers::_reset();
    $gc->{calls} = [];
    aged($gp);
    status( $gp, 0, undef, 0, 0 );
    Slim::Utils::Timers::_fireAll();          # nothing came back in time

    is( join( ',', @{ $gc->{calls} } ), 'playerEndOfStream,playerReadyToStream,playerStopped',
        'a stop that stays stopped IS reported, once the grace period expires' );
    is( $gp->hqStarted, '0', 'and the track is no longer considered playing' );
    is( $gp->hqNext, '(undef)',
        'and anything still queued is dropped - it belongs to the run that ended' );
    is( $gp->hqArmNext, '0', 'as does the arm flag' );
}

{
    # With nothing queued there is nothing for HQPlayer to move into, so a stop
    # can only be real - report it at once, exactly as before gapless.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f7', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );
    $gp->hqArmNext(0);

    Slim::Utils::Timers::_reset();
    $gc->{calls} = [];
    aged($gp);
    status( $gp, 0, $u1, 200, 1 );
    is( join( ',', @{ $gc->{calls} } ), 'playerEndOfStream,playerReadyToStream,playerStopped',
        'with nothing queued the stop is reported immediately - no added delay' );
    is( Slim::Utils::Timers::_pending(), '0', 'and nothing is left on a timer' );
}

print "-- a stop right after a track starts is start-up noise --\n";
{
    # LIVE FAILURE 2026-08-28, on a transcoded stream.  HQPlayer reports PLAYING as soon as it
    # accepts the stream, then drops back to STOPPED for a moment while LMS is
    # still spinning up the transcode - measured at 0.33s.  Read as the end, it
    # skipped the track 0.33s in and jumped to the next one.
    #
    # hqExpectStop covers the window BEFORE the new track is confirmed; this
    # covers the window just after it.
    my $np = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f9', 'paddr', 1.0, undef, 12, undef);
    $np->hqUPnP( LoadUPnP->new );
    $np->hqControl( bless {}, 'FakeCtl' );
    my $nc = LoadController->new($one);
    $np->controller($nc);

    @sent = (); @sentCb = ();
    $np->play({ controller => $nc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $np, 2, $u1, 0, 1 );          # confirmed playing, stamps the clock

    Slim::Utils::Timers::_reset();
    $nc->{calls} = [];
    $np->hqArmNext(0);

    # the transient, a fraction of a second in
    status( $np, 0, $u1, 0, 1 );
    is( join( ',', @{ $nc->{calls} } ), '',
        'a stop a fraction of a second into the track is NOT the end' );
    is( $np->hqStarted, '1', 'the track is still considered playing' );
    is( Slim::Utils::Timers::_pending(), '0',
        'and it is discarded outright, not merely deferred' );

    # the same push, once the track has actually been running
    aged($np);
    $nc->{calls} = [];
    status( $np, 0, $u1, 200, 1 );
    is( join( ',', @{ $nc->{calls} } ), 'playerEndOfStream,playerReadyToStream,playerStopped',
        'the same stop later in the track IS the end' );
}

print "-- the stale suppression is bounded --\n";
{
    # The other half of the same failure.  Even with the advance logic right,
    # a wrong hqURL/hqPrevURL pair must not be able to suppress the status
    # stream forever - that is a player that can only be fixed by restarting.
    my $sp2 = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f4', 'paddr', 1.0, undef, 12, undef);
    $sp2->hqUPnP( LoadUPnP->new );
    $sp2->hqControl( bless {}, 'FakeCtl' );
    my $sc = LoadController->new($one);
    $sp2->controller($sc);

    @sent = (); @sentCb = ();
    $sp2->play({ controller => $sc });
    _answer(); _answer();

    # wedge it by hand: HQPlayer is playing A, we think we moved to B
    my $a = 'http://h/a.flac';
    my $b = 'http://h/b.flac';
    $sp2->hqPrevURL($a);
    $sp2->hqURL($b);
    $sp2->hqStarted(1);

    for my $i ( 1 .. 5 ) {
        $sc->{calls} = [];
        status( $sp2, 2, $a, 10 + $i, 1 );
        is( $sp2->hqURL, $b, "push $i is suppressed as stale, as designed" );
    }

    $sc->{calls} = [];
    status( $sp2, 2, $a, 20, 1 );
    is( $sp2->hqURL, $a,
        "past the limit HQPlayer's account wins - the player un-wedges itself" );
    is( $sp2->hqPrevURL, '(undef)', 'and the bad previous-track marker is cleared' );
    ok( scalar( grep { $_ eq 'playerStatusHeartbeat' } @{ $sc->{calls} } ),
        'the status stream reaches the controller again' );
}

print "-- tier 5: the hand-over when HQPlayer strips the query string --\n";
{
    # LIVE FAILURE 2026-08-30, Qobuz. HQPlayer removes the query string from
    # every uri it REPORTS, and on tier 5 the whole identity of a track is in
    # that query string - so both tracks come back as the identical base url:
    #
    #   uri =.../file                                    <- reported, every track
    #   want=.../file?uid=355122&eid=193171336&hmac=...   <- what we queued
    #
    # The uri was a veto, so the hand-over could never be detected. `track`
    # went 1 -> 2 and every check still said "not yet": LMS never advanced, the
    # next track was never armed, and HQPlayer ran out of playlist and STOPPED
    # MID-ALBUM with time still on the counter.
    my $base = 'https://cdn.example.com/file';
    my $q1   = $base . '?uid=1&eid=100&hmac=aaa';
    my $q2   = $base . '?uid=1&eid=200&hmac=bbb';

    my $mk = sub {
        my $pl = Plugins::HQPlayerBridge::Player->new( shift, 'paddr', 1.0, undef, 12, undef );
        my $cc = LoadController->new($one);
        $pl->controller($cc);
        $pl->hqControl( bless {}, 'FakeCtl' );
        $pl->hqStarted(1); $pl->hqPlayAck(1); $pl->hqWanted('play');
        return ( $pl, $cc );
    };

    # HQPlayer reports the STRIPPED url and an index that has moved on
    my ( $qp, $qc ) = $mk->('02:aa:bb:cc:dd:e1');
    $qp->hqURL($q1); $qp->hqTrackNo(1);
    $qp->hqNext({ mode=>'queue', url=>$q2, acked=>1 });
    $qc->{calls} = [];
    status( $qp, 2, $base, 3, 2 );

    is( $qp->hqURL, $q2,
        'the hand-over IS detected even though the reported uri lost its query string' );
    ok( scalar( grep { $_ eq 'playerTrackStarted' } @{ $qc->{calls} } ),
        'and LMS is told the track started, so the counter advances' );

    # ...and it must NOT fire early, while the index still names track one
    my ( $ep, $ec ) = $mk->('02:aa:bb:cc:dd:e2');
    $ep->hqURL($q1); $ep->hqTrackNo(1);
    $ep->hqNext({ mode=>'queue', url=>$q2, acked=>1 });
    status( $ep, 2, $base, 3, 1 );
    is( $ep->hqURL, $q1,
        'a stripped uri with the index STILL on track one is not an advance' );

    # a local pair has no query string, so the url still discriminates and an
    # index jump alone must NOT be trusted - the original veto is intact
    my ( $lp, $lc ) = $mk->('02:aa:bb:cc:dd:e3');
    $lp->hqURL('http://s/music/1/download.flac'); $lp->hqTrackNo(1);
    $lp->hqNext({ mode=>'queue', url=>'http://s/music/2/download.flac', acked=>1 });
    status( $lp, 2, 'http://s/music/1/download.flac', 3, 2 );
    is( $lp->hqURL, 'http://s/music/1/download.flac',
        'a LOCAL track still vetoes on the url - an index jump alone is not enough there' );

    # THE 0 -> 1 BASELINE, AND WHY IT IS NOT AN ADVANCE.
    #
    # HQPlayer reports track="0" whenever it is not playing - INCLUDING in the
    # push that lands between the <Play/> ack and its index catching up, where
    # `state` already reads as playing. Storing that 0 made the next push
    # (track="1") an increase, and the ambiguous-url path fires on exactly
    # that. Live 2026-08-30 on a fresh Qobuz load:
    #
    #   12:47:07.7074  _onStatus     HQPlayer is playing        <- track="0"
    #   12:47:07.7078  _armNextTrack asking LMS for the next track
    #   12:47:08.0498  _handedOver   track=1 seen=0 -> ADVANCED <- WRONG
    #   12:47:08.0502  _armNextTrack asking LMS for the next track
    #
    # LMS advanced into a track HQPlayer was not playing, armed a SECOND time
    # and queued a third track, then stayed exactly one ahead for the rest of
    # the album with its counter running out on every track. The `>` test was
    # already there to stop a STOP reading as an advance; it cannot help when
    # 0 is the baseline, because 0 -> 1 is an increase.
    my ( $zp, $zc ) = $mk->('02:aa:bb:cc:dd:e4');
    $zp->hqURL($q1);
    $zp->hqNext({ mode=>'queue', url=>$q2, acked=>1 });

    status( $zp, 2, $base, 1, 0 );
    is( $zp->hqTrackNo, undef, 'track="0" is never stored as the baseline' );
    is( $zp->hqURL, $q1,       'and it is not itself an advance' );

    status( $zp, 2, $base, 2, 1 );
    is( $zp->hqURL, $q1,
        '1 AFTER a 0 is not an advance - this is the bug that put LMS a track ahead' );
    is( $zp->hqTrackNo, 1, 'and 1 does become the baseline' );

    status( $zp, 2, $base, 3, 2 );
    is( $zp->hqURL, $q2, 'a real 1 -> 2 advance from that baseline still fires' );

    # A STOP mid-run must not poison the baseline either: 0 is refused, so the
    # index we last really saw survives and the advance is still judged
    # against it rather than against nothing.
    my ( $sp, $sc ) = $mk->('02:aa:bb:cc:dd:e5');
    $sp->hqURL($q1); $sp->hqTrackNo(1);
    $sp->hqNext({ mode=>'queue', url=>$q2, acked=>1 });
    status( $sp, 2, $base, 5, 0 );
    is( $sp->hqTrackNo, 1, 'a 0 mid-run leaves the last real index in place' );
    is( $sp->hqURL, $q1,   'and is not an advance' );
}

print "-- tier 5: direct from the service --\n";
{
    # THE OLD REASON NOT TO DO THIS WAS WRONG. "HQPlayer cannot fetch a url
    # with a query string" was disproven on the wire 2026-08-28 - it fetches
    # them verbatim and merely strips them from what it REPORTS. So a signed
    # CDN url can go straight over, and the service no longer has to be proxied
    # through LMS's single player stream.
    my $signed = 'https://cdn.example.com/x.flac?uid=355122&fmt=7&hmac=abc123';

    my $qobuz = FakeSong->new( FakeTrack->new(
        { title=>'Remote', id=>-1, ct=>'flc', secs=>200, url=>'qobuz://1234.flac' } ) );

    # --- the hook itself ---
    is( $c->canDirectStream( 'qobuz://1234.flac', undef ), '0',
        'no song means no direct streaming' );

    $qobuz->_direct( $signed, FakeHandlerSong->new($signed) );
    is( $c->canDirectStream( 'qobuz://1234.flac', $qobuz ), $signed,
        'canDirectStreamSong is preferred, and its url is returned verbatim' );

    my $older = FakeSong->new( FakeTrack->new(
        { title=>'Remote', id=>-1, ct=>'flc', secs=>200, url=>'x://1.flac' } ) );
    $older->_direct( $signed, FakeHandlerUrl->new($signed) );
    is( $c->canDirectStream( 'x://1.flac', $older ), $signed,
        'a handler with only canDirectStream is used too' );

    # --- what must be REFUSED, because there is no fallback after Song::open ---
    my $radio = FakeSong->new( FakeTrack->new(
        { title=>'Station', id=>-1, ct=>'mp3', secs=>0, url=>'r://1' } ) );
    $radio->_direct( $signed, FakeHandlerRadio->new($signed) );
    is( $c->canDirectStream( 'r://1', $radio ), '0',
        'a handler that parses its own response headers is refused - we cannot call directHeaders back' );

    my $rel = FakeSong->new( FakeTrack->new(
        { title=>'Odd', id=>-1, ct=>'flc', secs=>10, url=>'x://2' } ) );
    $rel->_direct( '/not/absolute.flac', FakeHandlerSong->new('/not/absolute.flac') );
    is( $c->canDirectStream( 'x://2', $rel ), '0',
        'a non-http url is refused - HQPlayer will not follow a redirect to find the real one' );

    my $none = FakeSong->new( FakeTrack->new(
        { title=>'Plain', id=>-1, ct=>'flc', secs=>10, url=>'x://3' } ) );
    $none->_direct( '', FakeHandlerSong->new('') );
    is( $c->canDirectStream( 'x://3', $none ), '0',
        'a handler that declines gets no direct stream' );

    # --- and the url that reaches HQPlayer ---
    my $u = $c->_resolveURL($qobuz);
    is( $u, $signed, 'a direct song is handed the service url unchanged' );
    is( $c->hqTier, '5', 'and is tier 5' );
    ok( scalar( $u =~ /\?/ ),
        'THE QUERY STRING SURVIVES - that is the whole point of tier 5' );

    # a remote song LMS did NOT take direct still goes on the player stream
    # qobuz:// because an earlier block redefines isRemoteURL to that scheme
    my $proxied = FakeSong->new( FakeTrack->new(
        { title=>'Remote', id=>-1, ct=>'flc', secs=>200, url=>'qobuz://9.flac' } ) );
    my $u4 = $c->_resolveURL($proxied);
    is( $c->hqTier, '4', 'a song LMS did not take direct falls back to tier 4' );
    ok( scalar( $u4 =~ m{/hqp/} ), 'on the plugin player-stream endpoint, as before' );

    is( $c->canHTTPS, '1', 'we tell LMS we can do HTTPS - Qobuz and Tidal are' );
}

print "-- tier 3: a local file HQPlayer cannot decode --\n";
{
    # HQPlayer CANNOT FETCH A URL WITH A QUERY STRING.  Isolated live
    # 2026-08-28: /music/458773/download.flac plays, the same url with ?x=1
    # does not, and neither does /stream.mp3?player=...  PlaylistAdd answers
    # result="OK" either way and then never fetches it.
    #
    # So a local file in a format HQPlayer cannot decode must NOT go on the
    # LMS player stream.
    # `download` transcodes whenever the requested extension differs from the
    # track's own, and that url is path-only.
    my $alac = FakeSong->new( FakeTrack->new(
        { title=>'Lossless', id=>303, ct=>'alc', secs=>200, url=>'file:///x.m4a' } ) );

    # NOT /music/<id>/download.flac EITHER. A transcode has no length, so for
    # an HTTP/1.1 client LMS sends it `Transfer-Encoding: chunked`, and
    # HQPLAYER DOES NOT DE-CHUNK: it reads the chunk-size lines as audio and
    # its decoder throws `lost sync` / `CRC error` on every frame. Reported
    # live 2026-08-28 as garbled mp4 playback.
    #
    # 0.2.31 dodged that by routing this tier through the tier 4 player-stream
    # endpoint, which cost it gapless - there is one player stream per player,
    # so a pre-queued track fights the one playing. It goes on its own download
    # route instead, which is LMS's OWN download path with the request declared
    # HTTP/1.0 so the one `if` that chunks it does not fire. Independent per
    # request, so it CAN be pre-queued.
    my $u = $c->_resolveURL($alac);
    ok( scalar( $u =~ m{^http://127\.0\.0\.1:9000/hqp3/303/download\.flac$} ),
        'a local file HQPlayer cannot decode is served on the tier 3 download route' );
    ok( scalar( $u !~ m{^http://127\.0\.0\.1:9000/hqp/} ),
        'NOT the tier 4 player-stream endpoint - that cannot be pre-queued' );
    ok( scalar( $u =~ m{/download\.} ),
        'the url carries download.<ext> - downloadMusicFile reads the output format out of it' );
    is( $c->hqTier, '3', 'and is tier 3' );
    ok( scalar( $u !~ /\?/ ),
        'the url carries NO query string - HQPlayer silently refuses those' );

    # a format it CAN decode is still an untouched passthrough
    my $flac = FakeSong->new( FakeTrack->new(
        { title=>'Native', id=>404, ct=>'flc', secs=>200, url=>'file:///x.flac' } ) );
    is( $c->_resolveURL($flac), 'http://127.0.0.1:9000/music/404/download.flac',
        'a native FLAC is unchanged' );
    is( $c->hqTier, '1', 'and stays tier 1 - it is a byte-for-byte passthrough, and seekable' );

    # only something genuinely remote falls through to the plugin's own
    # endpoint - it is the one case with no file to serve
    my $rem = FakeSong->new( FakeTrack->new(
        { title=>'Streamed', id=>-9454304, ct=>'flc', secs=>200,
          url=>'qobuz://445307221.flac' } ) );
    my $ru = $c->_resolveURL($rem);
    ok( scalar( $ru =~ m{^http://127\.0\.0\.1:9000/hqp/02-ab-88-42-4c-69/\d+\.} ),
        'only a remote track reaches tier 4, the plugin stream endpoint' );
    ok( scalar( $ru !~ /\?/ ),
        'and it too is path-only - /stream.mp3?player= is exactly what HQPlayer will not fetch' );
    is( $c->hqTier, '4', 'and is tier 4' );
}

print "-- gapless: the guards --\n";
{
    # TIER 4 CANNOT RIDE HQPLAYER'S PLAYLIST, even though its urls ARE unique.
    # A client has ONE streamingsocket and one songStreamController, so
    # appending would move LMS on to the next song's source while HQPlayer is
    # still pulling this one down the socket - the rest of the playing track
    # would arrive as the start of the next.  So it is HELD and loaded the
    # ordinary way.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:ef', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    # A LOCAL file of any format is tier 3 now (LMS transcodes it on a
    # path-only url), so only a genuinely REMOTE track reaches tier 4 - it is
    # the one case with no file to serve.
    my $remote = FakeSong->new( FakeTrack->new(
        { title=>'Streamed', id=>-94543041325440, ct=>'flc', secs=>200,
          url=>'qobuz://445307221.flac' } ) );

    @sent = (); @sentCb = ();
    $gc->{song}    = $remote;
    $gc->{playing} = 1;
    $gp->play({ controller => $gc });

    is( scalar(@sent), '0', 'a tier 4 next track is NOT pre-queued - nothing is sent' );
    is( $gp->hqNext && $gp->hqNext->{mode}, 'load', 'it is held for a normal load instead' );
    is( $gp->hqTier, '1', "and the PLAYING track's tier is left alone" );

    # ...and it is loaded when the current track actually ends
    $gc->{calls} = [];
    aged($gp);
    status( $gp, 0, $u1, 200, 1 );
    ok( scalar( grep { /^<PlaylistAdd\b/ } @sent ), 'the held track is loaded at end of track' );
    ok( scalar( grep { $_ eq '<PlaylistClear/>' } @sent ),
        'the ordinary way - a full four-command load' );
    ok( scalar( !grep { $_ eq 'playerEndOfStream' } @{ $gc->{calls} } ),
        'and that stop is NOT reported as end-of-stream - LMS is already streaming it' );
    ok( scalar( !grep { $_ eq 'playerBufferReady' } @{ $gc->{calls} } ),
        'nor BufferReady, which in the PLAYING row of the state table is _Invalid' );
}

{
    # A REFUSED pre-queue must not interrupt anything.  Reporting
    # StreamingFailed here leads to _SyncStopNext -> _getNextTrack -> play(),
    # and THAT play() is a full load - it would stop the track still playing
    # perfectly well.  The track is demoted to a normal load instead, which
    # runs at end of track and reports the failure properly if it is real.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f2', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    $gc->{song}    = $two;
    $gc->{playing} = 1;
    $gp->play({ controller => $gc });

    $gc->{calls} = [];
    @sent = ();
    _answer(0);     # the append -> Error

    ok( scalar( !grep { $_ eq 'playerStreamingFailed' } @{ $gc->{calls} } ),
        'a refused pre-queue is NOT reported as a failed load' );
    is( $gp->hqStarted, '1', 'and the track that is playing keeps playing' );
    is( $gp->hqNext && $gp->hqNext->{mode}, 'load',
        'it is demoted to a normal load at end of track instead' );
}

{
    # A hand-over cannot carry a seek: <Seek> acts on what is playing now, not
    # on a queued item.  The full load can, so it takes that call.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f0', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    @sent = (); @sentCb = ();
    $gc->{song} = $two;
    $gp->play({ controller => $gc, seekdata => { timeOffset => 30 } });
    ok( scalar( grep { $_ eq '<PlaylistClear/>' } @sent ),
        'an armed play() carrying a seek falls back to the full load' );
}

{
    # LMS discarding the track it handed us early - the playlist was edited, or
    # the user jumped.  <PlaylistClear/> keeps the item that is PLAYING and
    # drops the rest, which is exactly a flush here.  It was a no-op stub while
    # the playlist only ever held one item.
    my $gp = Plugins::HQPlayerBridge::Player->new('02:aa:bb:cc:dd:f1', 'paddr', 1.0, undef, 12, undef);
    $gp->hqUPnP( LoadUPnP->new );
    $gp->hqControl( bless {}, 'FakeCtl' );
    my $gc = LoadController->new($one);
    $gp->controller($gc);

    @sent = (); @sentCb = ();
    $gp->play({ controller => $gc });
    my ($u1) = ( grep { /^<PlaylistAdd\b/ } @sent )[0] =~ m{\buri="([^"]+)"};
    _answer(); _answer();
    status( $gp, 2, $u1, 1, 1 );

    $gc->{song} = $two;
    $gp->play({ controller => $gc });
    _answer();

    @sent = ();
    $gp->flush;
    is( join( ',', @sent ), '<PlaylistClear/>',
        'flush drops the pre-queued track from HQPlayer, keeping the one playing' );
    is( $gp->hqNext, '(undef)', 'and forgets it on our side too' );

    # LIVE FAILURE 2026-08-28.  _FlushGetNext drops the streaming song, calls
    # flush(), then immediately asks for a REPLACEMENT - so the next play() is
    # another hand-over.  Clearing the flag made that play() run the full load
    # over a track that was still playing: deleting the pre-queued track six
    # seconds into a twelve-second one cut it off and jumped forward.
    is( $gp->hqArmNext, '1',
        'flush RE-ARMS - the replacement LMS sends next is a hand-over, not a play-now' );

    @sent = (); @sentCb = ();
    $gc->{song} = $one;
    $gp->play({ controller => $gc });
    ok( scalar( !grep { $_ eq '<Stop/>' } @sent ),
        'so the replacement never stops the track that is playing' );
    ok( scalar( grep { /^<PlaylistAdd\b/ } @sent ), 'it is appended instead' );

    # nothing queued -> nothing sent, or an idle flush would clear a playlist
    # that a load is in the middle of building.  (The replacement appended just
    # above is dropped first, so this really is the empty case.)
    $gp->hqNext( undef );
    @sent = ();
    $gp->flush;
    is( join( ',', @sent ), '', 'a flush with nothing queued sends nothing' );
}


# ---------------------------------------------------------------------------
# fade_volume's DURATION.  It is not only the pause ramp: the sleep timer calls
# it with the whole fade-out time and stops the player from the completion
# callback.  Firing that immediately ended playback a full fade early.
# ---------------------------------------------------------------------------
print "-- fade duration --\n";
Slim::Utils::Timers::_reset();

my $stopped = 0;
$c->fade_volume(-0.3125, sub { $stopped++ });
is($stopped, '1', 'a pause ramp still completes immediately - it is what pauses');
is(Slim::Utils::Timers::_pending(), '0', 'and schedules nothing');

$stopped = 0;
$c->fade_volume(-60, sub { $stopped++ });
is($stopped, '0', 'a 60s sleep fade does NOT stop the player straight away');
is(Slim::Utils::Timers::_pending(), '1', 'it is deferred to a timer');
Slim::Utils::Timers::_fireAll();
is($stopped, '1', 'and completes when the fade would have ended');

# a cancelled sleep timer must not still stop the player later
$stopped = 0;
$c->fade_volume(-60, sub { $stopped++ });
$c->fade_volume(-0.3125, sub { });
is(Slim::Utils::Timers::_pending(), '0', 'a new fade cancels the pending one');
Slim::Utils::Timers::_fireAll();
is($stopped, '0', 'so the superseded fade never fires');

print "-- repeat must be OFF, or the player can never advance --\n";
# This shipped the other way round for one build.  <SetRepeat value="1"/> was
# added to stop HQPlayer walking off the end of a one-entry playlist
# (clPlaylist::GetAlbumGain(): trackn > last, unhandled, kills the daemon) -
# but with repeat ON the playlist never ends, `state` never reaches 0,
# end-of-track is never reported, and a full LMS queue plays its FIRST TRACK
# forever.  Verified live 2026-08-28: with repeat OFF a complete track ends at
# state 0, the daemon survives, and LMS advances by itself.  The overrun needed
# the old two-channel load, which no longer exists.
{
    my @sent;
    no warnings 'redefine';
    local *Plugins::HQPlayerBridge::Player::_send = sub { push @sent, $_[1] };

    $c->assertRepeatOff;
    is(scalar(@sent), '1', 'assertRepeatOff sends exactly one command');
    is($sent[0], '<SetRepeat value="0"/>', 'it is <SetRepeat value="0"/>, NOT value="1"');
}
# The whitelist gates what can reach the wire at all - a verb missing from it
# is dropped before it is sent, silently.
ok(do { open my $fh,'<','../HQPlayerBridge/Control.pm'; local $/; <$fh> } =~ /\bSetRepeat\b/,
   'SetRepeat is in Control.pm\'s %KNOWN, or the guard never leaves the plugin');

print "-- bitrate limit: the difference between FLAC and MP3 --\n";
# LMS caps an unset maxBitrate at 320kbps for anything that is not a
# Squeezebox, which silently transcodes every streamed track to MP3.  The pref
# must end up 0, and ONLY when the user has never chosen one.
{
    my $sp = Slim::Utils::Prefs::preferences('server');

    my $fresh = Plugins::HQPlayerBridge::Player->new('02:ab:88:42:4c:70', 'paddr', 1.0, undef, 12, undef);
    my $cp    = $sp->client($fresh);

    is($cp->get('maxBitrate'), '(undef)', 'a new player starts with no bitrate limit set');
    is($fresh->initBitrateLimit, '1', 'initBitrateLimit acts when the pref is unset');
    is($cp->get('maxBitrate'), '0', 'and sets it to 0 - unlimited, so LMS streams FLAC');

    # TRAP: 0 is a real choice and is NOT undef.  Re-running must not treat an
    # already-set 0 as "never set" and must stay idempotent.
    is(scalar($fresh->initBitrateLimit), '(undef)', 'running it again does nothing');
    is($cp->get('maxBitrate'), '0', 'and leaves the value alone');

    # A deliberate user limit is theirs, not ours to overwrite.
    my $chosen = Plugins::HQPlayerBridge::Player->new('02:ab:88:42:4c:71', 'paddr', 1.0, undef, 12, undef);
    my $cp2    = $sp->client($chosen);
    $cp2->set('maxBitrate', 320);
    is(scalar($chosen->initBitrateLimit), '(undef)', 'a chosen limit is not overridden');
    is($cp2->get('maxBitrate'), '320', 'and survives untouched');
}

printf "\n%d passed, %d failed\n",$pass,$fail;
exit($fail?1:0);
