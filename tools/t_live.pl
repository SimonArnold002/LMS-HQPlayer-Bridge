# The standalone live page.
#
# It exists because the settings page's in-place poller never updated on
# Simon's Material and no measurement could locate the fault. This route drops
# every variable the settings page cannot shed - the classic-skin settings
# shell, the skin's own JS, two nested forms, and Material's iframe - by being
# a raw handler that owns the whole document and opening as a TOP-LEVEL page.
#
# So the assertions below are mostly about what is ABSENT.
use strict; use warnings;
BEGIN { package main; use constant DEBUGLOG=>0; use constant INFOLOG=>0; use constant WEBUI=>1; }
use lib '.';
require Plugins::HQPlayerBridge::Live;
Plugins::HQPlayerBridge::Live->init('9.9.9');

my ($pass,$fail)=(0,0);
sub is { my($got,$want,$name)=@_; $got//='(undef)'; $want//='(undef)';
  if ($got eq $want){$pass++; printf "  ok   %s\n",$name}
  else {$fail++; printf "  FAIL %s\n        got: %s\n       want: %s\n",$name,$got,$want} }
sub ok { my $n = pop; my $c = @_ ? $_[0] : 0;
  $c ? ($pass++, printf "  ok   %s\n",$n) : ($fail++, printf "  FAIL %s\n",$n) }

# --- a response object faithful enough to catch the status-code trap ---------
{
    package FakeResponse;
    sub new { bless { code => undef, headers => {}, ct => undef }, shift }
    sub code         { my $s=shift; $s->{code} = shift if @_; return $s->{code} }
    sub content_type { my $s=shift; $s->{ct}   = shift if @_; return $s->{ct} }
    sub header       { my ($s,$k,$v)=@_; $s->{headers}{lc $k} = $v if defined $v;
                       return $s->{headers}{lc $k} }
    package FakeHttpClient;
    sub new { bless {}, shift }
    sub connected { 1 }
}

our $SENT;
{
    no warnings 'redefine', 'once';
    *Slim::Web::HTTP::addHTTPResponse = sub { $SENT = ${ $_[2] }; return };
}

print "-- the raw handler owns its response --\n";
my $res = FakeResponse->new;
Plugins::HQPlayerBridge::Live::_handler( FakeHttpClient->new, $res );

# THE TRAP THIS FILE EXISTS FOR. LMS builds the status line as
# sprintf("%s %s %s", protocol, code, message) and fills in NOTHING, so a raw
# handler that never sets a code emits a literal "HTTP/1.1  ". That shipped in
# this plugin once and broke every m4a track from 0.2.32 to 0.2.45. Assert the
# code on the response OBJECT - a body assertion cannot see this.
is($res->code, '200', 'the handler sets an explicit status code (never a blank status line)');
ok(scalar($res->content_type && $res->content_type =~ m{^text/html}),
   'and an HTML content type');
ok(scalar(($res->header('cache-control') || '') =~ /no-store/),
   'and no-store - a cached copy of a LIVE view is a lie');
ok(defined $SENT && length $SENT, 'a body is sent');

# The version is HANDED IN at init. A page module that reached into its own
# Plugin.pm would die mid-handler and LMS would render the half-built page with
# nothing in the log - the Eversolo 1.5.0 failure, exactly.
ok(scalar($SENT =~ /v9\.9\.9/), 'the version handed to init reaches the page');
ok(scalar($SENT !~ /HQPlayerBridge::Plugin/), 'and the page module never calls into Plugin.pm');

print "-- it is a WHOLE document, owing nothing to the skin --\n";
ok(scalar($SENT =~ /^<!DOCTYPE html>/i), 'starts with its own doctype');
ok(scalar($SENT =~ m{</html>\s*$}i),     'and closes its own html');
ok(scalar($SENT =~ /<head>/i && $SENT =~ /<body>/i), 'carries its own head and body');

# The whole point of the route: none of the settings-shell surroundings that
# could not be ruled out on the settings page may reappear here.
for my $bad ( [ 'settings/header' => qr{settings/header} ],
              [ 'a form'          => qr{<form}i ],
              [ 'mousetrap'       => qr{mousetrap}i ],
              [ 'custom-select'   => qr{custom-select}i ],
              [ 'chooseSettings'  => qr{chooseSettings} ],
              [ 'slimserver.css'  => qr{slimserver\.css} ],
              [ 'a TT directive'  => qr{\[%} ] ) {
    my ( $what, $re ) = @$bad;
    ok(scalar($SENT !~ $re), "no $what in the page");
}

print "-- it polls, and it never gives up quietly --\n";
# It polls on a CHAINED timer, not a repeating one - see the connection-pool
# section below for why the distinction is not cosmetic.
ok(scalar($SENT =~ /setTimeout\(poll,/),            'it polls on a timer');
ok(scalar($SENT =~ /hqplayerbridge.{0,4}.{0,4}signalpath/s), 'and asks the signalpath query');
ok(scalar($SENT =~ m{'POST', '/jsonrpc\.js'}),      'over jsonrpc.js');

# THE SETTINGS PAGE'S WORST PROPERTY, WHICH THIS MUST NOT INHERIT: it called
# clearInterval after five errors, so a dead page and a working one looked
# identical - which is exactly the ambiguity that cost several rounds.
ok(scalar($SENT !~ /clearInterval/),
   'it does NOT stop itself on error - a silent stop is indistinguishable from a frozen value');

print "-- ONE request in flight, because this page shares Material's connection pool --\n";
# It was setInterval with no guard: a `signalpath` answer costs a full status
# query per bridge, so once the server takes over a second the polls OVERLAP,
# and with a 5s timeout up to five can be open at once. A browser allows about
# SIX per origin over HTTP/1.1 - all LMS speaks - and Material holds one of them
# permanently for the CometD subscription its Now Playing runs on. The Home tile
# opens THIS PAGE AS AN IFRAME INSIDE MATERIAL, so it is the same pool.
ok(scalar($SENT !~ /setInterval/),
   'the fixed-cadence timer is gone - it could not know a poll was still open');
ok(scalar($SENT =~ /if \(inFlight\) \{ schedule\(\); return; \}/),
   'a tick that finds a request already open reschedules instead of adding one');
ok(scalar($SENT =~ /pollTimer = setTimeout\(poll,/),
   'the next poll is a TIMEOUT set after the last settled - the period is a gap');

# Every exit from a request must reschedule, or "never gives up" becomes "stops
# on the first timeout" - which is the settings page's failure with extra steps.
ok(scalar($SENT =~ /function done\(ok, msg\) \{/), 'both outcomes go through one done()');
ok(scalar($SENT =~ /inFlight = false;\s*\n\s*stampNow\(ok, msg\);\s*\n\s*schedule\(\);/),
   'which clears the flag, reports, and always schedules the next one');
ok(scalar($SENT =~ /xhr\.ontimeout = function \(\) \{ done\(false, 'request timed out'\); \}/),
   'a timeout reschedules rather than ending the page');

# A command polls straight back so the button feels immediate - but it must
# BRING THE NEXT POLL FORWARD, not add one on top of a request already open.
ok(scalar($SENT =~ /xhr\.onload    = function \(\) \{ schedule\(0\); \}/),
   'a command brings the next poll forward instead of stacking a request');
# The clock this used to assert is GONE (0.2.71) - and this assertion carried on
# passing, because the only "updated " left in the page is the COMMENT saying so.
# The liveness signal is the dot, and a failure still names itself.
ok(scalar($SENT =~ /dot\.className = 'dot ' \+ \(ok \? 'live' : 'err'\)/),
   'and it shows live-or-failed, so "is it alive" is never a guess');

print "-- values are placed, never parsed --\n";
# The server answers finished display strings. A page that took one apart would
# break the moment anyone translated them.
ok(scalar($SENT =~ /function esc\(/), 'it escapes what it inserts');
ok(scalar($SENT !~ /\.split\(' - '\)/ && $SENT !~ /realtime/),
   'and never splits or re-formats a value the server already formatted');

print "-- the name reaches the page --\n";
# The card is headed with the instance name; the query used to send only `id`,
# which is a MAC address.
{
    open my $fh, '<', 'Plugins/HQPlayerBridge/Plugin.pm' or die $!;
    my $mod = do { local $/; <$fh> }; close $fh;
    ok(scalar($mod =~ /addResultLoop\( 'bridges_loop', \$i, 'name'/),
       'the signalpath query sends the instance name');
}

print "-- the truthiness bug must stay fixed --\n";
# process_speed is "0" whenever HQPlayer is not processing, and 0 is FALSE in
# Perl - so a truthiness guard deleted the speed from the string instead of
# reporting 0.0x. Measured live: one sample carried no speed while samples 2s
# either side carried 69.2x.
{
    open my $fh, '<', 'Plugins/HQPlayerBridge/Plugin.pm' or die $!;
    my $mod = do { local $/; <$fh> }; close $fh;
    ok(scalar($mod !~ /if \$c->hqPath->\{process_speed\};/),
       'process_speed is no longer guarded on truthiness');
    ok(scalar($mod =~ /defined \$v && \$v ne ''/),
       'and the guard tests DEFINED instead');
}

print "-- getting back to Material --\n";
# This page is opened as a new window from the app list, so there is no browser
# Back to return with. window.close() works on a window a script opened and is
# a NO-OP on a tab the user opened themselves (and inside a frame), so the
# fallback is not optional - without it the button does nothing for half the
# ways this page can be reached.
ok(scalar($SENT =~ /id="back"/),          'there is a back control');
ok(scalar($SENT =~ /window\.close\(\)/), 'it tries to close a window it was given');
ok(scalar($SENT =~ m{'/material/'}),      'and falls back to navigating to Material');
ok(scalar($SENT =~ /window\.top !== window\.self/),
   'it detects being framed');
ok(scalar($SENT =~ /removeChild\(back\)/),
   'and REMOVES the button when framed - Material\'s dialog has its own close, and '
 . 'navigating the top window would throw away the whole session');
ok(scalar($SENT !~ /window\.top\.location\.href\s*=/),
   'so it never navigates the top window - that was destructive once the tile opened inline');

print "-- there is no settings page left to link to --\n";
# Nothing in this plugin is configurable. The settings page existed only to
# read numbers off, could not keep them current, and put a link inside a link
# on the way to the one page that works.
ok(scalar(!-e '../HQPlayerBridge/Settings.pm'), 'Settings.pm is gone');
ok(scalar(!-e '../HQPlayerBridge/HTML/EN/plugins/HQPlayerBridge/settings/basic.html'),
   'and so is its template');
{
    open my $fh, '<', 'Plugins/HQPlayerBridge/Plugin.pm' or die $!;
    my $mod = do { local $/; <$fh> }; close $fh;
    ok(scalar($mod !~ /HQPlayerBridge::Settings/),
       'and Plugin.pm no longer registers one');
}

print "-- it follows MATERIAL's theme, by LMS's own recipe --\n";
# Material records the user's choice in localStorage on the SAME ORIGIN as this
# page, and the classic skin's settings header reads it exactly this way. The
# normalisation is the part that must not drift: `darker` renders as dark,
# `auto` follows the OS, a trailing -colored/-standard is a VARIANT and not part
# of the theme name, and `user:` themes live under a different path.
ok(scalar($SENT =~ /lms-material::theme/),  'it reads Material\'s theme key');
ok(scalar($SENT =~ /lms-material::color/),  'and its accent colour key');
ok(scalar($SENT =~ /'darker'/),             "and normalises 'darker' to dark");
ok(scalar($SENT =~ /prefers-color-scheme: light/), "and resolves 'auto' against the OS");
ok(scalar($SENT =~ /'colored'|'standard'/), 'and strips the variant suffix');
ok(scalar($SENT =~ m{/material/usertheme/}), 'and handles a user: theme');
ok(scalar($SENT =~ m{/html/css/themes/}) && scalar($SENT =~ m{/html/css/colors/}),
   'and loads both of Material\'s stylesheets');

# A localStorage read THROWS in some privacy modes - it must not take the page
# with it, because the signal path is the point and the theme is decoration.
ok(scalar($SENT =~ /catch \(e\)/), 'a localStorage read that throws is caught');

# The stylesheets carry no TEXT colour (Vuetify supplies it in Material), so
# that half is ours - and the fallbacks must be real values so the page is still
# right on a server with no Material installed.
ok(scalar($SENT =~ /var\(--std-background-color, #/),
   'colours come from Material\'s variables WITH a real fallback');
ok(scalar($SENT =~ /--fg:/), 'and the page supplies its own text colour');

print "-- the Perl heredoc must not eat a JS escape --\n";
# The JS lives in an INTERPOLATING heredoc, so `\u2014` is PERL's "titlecase the
# next character" and not an em dash. It shipped as the literal "2014" and
# rendered live as "Luluc 2014 Passerby". Assert on the SERVED bytes: whatever
# is in the source, what reaches the browser must carry no stray escape.
ok(scalar($SENT !~ /2014/),
   'no titlecased \u escape survived into the page (the "Luluc 2014 Passerby" bug)');
ok(scalar($SENT =~ /String\.fromCharCode\(8212\)/),
   'the em dash is built at runtime instead of escaped');
ok(scalar($SENT !~ /\\u[0-9a-fA-F]{4}/),
   'and no backslash-u escape is written literally anywhere in the page');

print "-- now playing --\n";
ok(scalar($SENT =~ /np_title/),   'the page reads the now-playing fields');
ok(scalar($SENT =~ /np_artwork/), 'including artwork');

# NOTHING PLAYING STILL DRAWS NO TRACK. The `idle` class is what hides the
# artwork, the title and the progress bar; what it deliberately does NOT hide is
# the control row, because a volume slider you can only reach while music is
# already playing is not a control.
ok(scalar($SENT =~ /card np idle/),
   'nothing playing collapses the panel to its controls, drawing no empty track');
ok(scalar($SENT =~ m{\.np\.idle \.np-title}),
   'and the idle rule hides the title');
ok(scalar($SENT !~ m{\.np\.idle \.np-ctl \{ display: none}),
   'but NOT the controls');

# BUILT ONCE, UPDATED IN PLACE. The old panel was an innerHTML string guarded by
# a signature - and the position was IN that signature, so it was rebuilt every
# second regardless. Rebuilding markup under a slider replaces the element
# mid-drag, so the DOM and its handlers must now be created exactly once.
ok(scalar($SENT !~ /npSig/),
   'the every-second innerHTML rebuild is gone - it would replace the slider mid-drag');
ok(scalar($SENT =~ /if \(!el\) \{ build\(\); bindDrag\(\); \}/),
   'the panel is built once and then written into');
ok(scalar($SENT =~ /el\.title\.textContent = b\.np_title/),
   'and the title is assigned, not re-rendered');
ok(scalar($SENT =~ /getAttribute\('src'\) !== b\.np_artwork/),
   'artwork is only assigned when it CHANGES - rewriting the same src flickers');

print "-- it SCALES, which was the desktop complaint --\n";
# A hard 96px cover on a full-bleed card is what looked tiny on a PC and fine on
# a phone. Both halves are fixed here: the sizes are viewport-relative with the
# old mobile size as their floor, and the content is centred at a max width so a
# 1900px row cannot dwarf it.
ok(scalar($SENT =~ /--art:\s*clamp\(96px/),
   'the artwork scales with the viewport, from the old mobile size upwards');
ok(scalar($SENT =~ /\.wrap \{ max-width:/),
   'and the page is centred at a max width rather than full-bleed');
ok(scalar($SENT !~ /flex: 0 0 96px/),
   'the fixed 96px artwork is gone');
ok(scalar($SENT =~ /\.np-title \{ font-size: clamp\(/),
   'the type scales with it, in the same proportion');

print "-- the volume row fits the card, on a phone --\n";
# Reported on an iPhone against 0.2.74: the level sat OUTSIDE the card. A flex
# item defaults to `flex: 0 1 auto`, so all four buttons were also offering to
# shrink and none of them can - the browser spreads the overflow across items
# that refuse it and the remainder runs off the end. Exactly one thing may give,
# and it has to be the slider.
ok(scalar($SENT =~ /\.tbtn \{[^}]*flex: 0 0 auto/s),
   'the buttons are pinned - they cannot shrink, so they must not offer to');
ok(scalar($SENT =~ /input\[type=range\] \{[^}]*flex: 1 1 0;/s),
   'the slider has a ZERO basis, so it takes exactly what is left');
ok(scalar($SENT !~ /flex: 1 1 auto; min-width: 0; height: 20px/),
   'not an AUTO basis - that starts at the UA intrinsic width and only shrinks pro-rata');

# A fixed basis on the level clips a three-digit volume.
ok(scalar($SENT =~ /\.np-volv \{[^}]*flex: 0 0 auto; min-width: 2\.4em/s),
   'the level is a MINIMUM width, so 100 does not clip');
ok(scalar($SENT =~ /\.np-vol \{[^}]*min-width: 0;/s),
   'and the volume box itself may shrink below its content');

print "-- the volume basis covers its furniture at EVERY width --\n";
# THE ARITHMETIC, DONE AGAINST THE SERVED CSS - because doing it by eye has now
# failed twice on the same row. The furniture (buttons, gaps, the level) cannot
# shrink, so whatever is left of the flex basis IS the slider. 22vw was chosen
# when the row had four controls; the mute button made it five and nothing
# re-derived it, so an iPhone in LANDSCAPE got a 29px slider - a dot.
#
# The button COUNT is read from the markup, so adding a fourth control to this
# row fails here instead of arriving as a screenshot.
{
    my ($vlo, $vvw, $vhi) =
        $SENT =~ /\.np-vol \{[^}]*flex: 0 1 clamp\((\d+)px, ([\d.]+)vw, (\d+)px\)/s;
    my ($szlo, $szvw, $szhi) =
        $SENT =~ /\.tbtn\.vol \{ --sz: clamp\((\d+)px, ([\d.]+)vw, (\d+)px\)/;
    my ($blo, $bvw, $bhi) =
        $SENT =~ /font: clamp\((\d+)px, ([\d.]+)vw, (\d+)px\)/;
    my ($lblem) = $SENT =~ /\.np-volv \{[^}]*min-width: ([\d.]+)em/s;
    my ($gap)   = $SENT =~ /\.np-vol \{[^}]*gap: (\d+)px/s;
    my $nbtn    = () = $SENT =~ /class="tbtn vol"/g;

    ok(scalar( $vlo && $szlo && $blo && $lblem && $gap && $nbtn ),
       'every number the volume row is built from is readable from the page');

    sub cl { my ($lo,$v,$hi) = @_; return $v < $lo ? $lo : $v > $hi ? $hi : $v }

    # Below the breakpoint the volume takes a full line, so the clamp basis does
    # not govern - only check the widths where it does.
    # The MEDIA QUERY's breakpoint specifically - a bare /max-width: (\d+)px/
    # matches `.wrap { max-width: 1100px }` first, which silently skipped almost
    # every viewport below and left this assertion checking nothing.
    my ($bp) = $SENT =~ /[@]media \(max-width: (\d+)px\)/;
    my $worst = 1e9;
    my $at    = 0;

    for my $vw ( 640, 700, 800, 852, 1024, 1180, 1400 ) {
        next if $vw <= ( $bp || 0 );
        my $base  = cl( $blo,  $vw / 100,        $bhi );
        my $sz    = cl( $szlo, $szvw * $vw / 100, $szhi );
        my $furn  = $nbtn * ( $sz + 4 )          # buttons, 2px padding each side
                  + ( $nbtn + 1 ) * $gap         # gaps: buttons + slider + level
                  + $lblem * ( 0.86 * $base );   # the level, at its own font size
        my $basis = cl( $vlo, $vvw * $vw / 100,  $vhi );
        my $slide = $basis - $furn;
        if ( $slide < $worst ) { $worst = $slide; $at = $vw }
    }

    # 72px is the floor for something you can actually put a thumb on. The 0.2.76
    # basis gave 29px at 800px wide, which is what a dot looks like.
    ok(scalar( $worst >= 72 ),
       sprintf( 'the slider keeps a usable width at every shared-line size (worst %dpx at %dpx wide)',
                $worst, $at ) );

    # THE CONTROL: the basis that shipped in 0.2.76 must FAIL this, or the
    # assertion is passing against a rule that changed nothing.
    my $old = cl( 160, 22 * 800 / 100, 280 );
    my $oldbase = cl( $blo, 800 / 100, $bhi );
    my $oldsz   = cl( $szlo, $szvw * 800 / 100, $szhi );
    my $oldfurn = $nbtn * ( $oldsz + 4 ) + ( $nbtn + 1 ) * $gap
                + $lblem * ( 0.86 * $oldbase );
    ok(scalar( $old - $oldfurn < 72 ),
       sprintf( "and 0.2.76's own basis would NOT have (%dpx at 800px wide)",
                $old - $oldfurn ) );
}

print "-- transport and volume, using MATERIAL's own commands --\n";
# Read from Material's source rather than invented, so these buttons behave
# exactly like the ones on its Now Playing page. `jump_rew` is the
# restart-then-previous the hardware button does - an index of -1 is NOT the
# same thing and skips a track the user expected to restart.
ok(scalar($SENT =~ /'button', 'jump_rew'/),  "prev is Material's jump_rew");
ok(scalar($SENT =~ /'playlist', 'index', '\+1'/), 'next is playlist index +1');
ok(scalar($SENT =~ /\? 'pause' : 'play'/),   'and play/pause toggles the way Material does');
ok(scalar($SENT =~ /'mixer', 'muting'/),     'mute is mixer muting');
ok(scalar($SENT =~ /'mixer', 'volume', el\.vol\.value/), 'and the slider sets mixer volume');

# BUTTONS AND A SLIDER, in Material's own arrangement - down, slider, up, level
# - because that is what Material's volume-control widget is.
ok(scalar($SENT =~ /id="c-vdn"/) && scalar($SENT =~ /id="c-vup"/),
   'the volume has step BUTTONS either side of the slider, as Material does');
ok(scalar($SENT =~ /icon\(el\.ivdn,\s+'volume_down'\)/),
   "and they use Material's volume_down / volume_up glyphs");
# A DEDICATED MUTE BUTTON, which Material does not have - it hides that gesture
# on the level label (middle-click / long-press). Once there IS a button, the
# step buttons must stop flipping to volume_off: three of that glyph at once
# says the state three times and leaves the user guessing which one mutes.
ok(scalar($SENT =~ /id="c-mute"/),
   'there is a real mute button, not just Material\'s hidden label gesture');
ok(scalar($SENT !~ /b\.np_muted \? 'volume_off'/),
   'and the step buttons no longer flip glyph - one control shows the state');
ok(scalar($SENT =~ /icon\(g\('i-mute'\), 'volume_off'\)/),
   'the mute button carries volume_off as its ACTION, set once');
ok(scalar($SENT =~ /b\.np_muted \? 'tbtn vol on' : 'tbtn vol'/),
   'it lights in the accent colour while muted');
ok(scalar($SENT =~ /b\.np_muted \? 'np-volv dimmed' : 'np-volv'/),
   "and the level dims alongside it - Material's own treatment for that label");

# Both routes to the same command, bound to ONE function. Two copies of a
# toggle is how they drift apart.
ok(scalar($SENT =~ /el\.mute\.addEventListener\('click', toggleMute\)/)
   && scalar($SENT =~ /el\.volv\.addEventListener\('click', toggleMute\)/),
   'button and label share one toggle, so they cannot disagree');

# The command is RELATIVE, like Material's. A computed level would make this
# page, rather than the server, decide where the ends of the range are.
ok(scalar($SENT =~ /\(dir > 0 \? '\+' : '-'\) \+ VOLSTEP/),
   'a step sends a RELATIVE +n / -n, not a computed level');

# The step size is the user's own. Material keeps it in localStorage on the SAME
# ORIGIN as this page - exactly how the theme is read - so both move by the same
# amount instead of this page inventing one.
ok(scalar($SENT =~ /lms-material::volumeStep/),
   "the step is read from Material's own setting");
ok(scalar($SENT =~ /var VOLSTEP = 5;/),
   "with Material's default when Material has never run in this browser");

# Without a local move the widget looks stuck: the reply is held off for a
# moment after any volume command, so a second press would step from a stale
# value.
ok(scalar($SENT =~ /el\.vol\.value = v;/),
   'a step moves the slider at once rather than waiting for the server');

print "-- the signal path is three rows, not one sentence --\n";
# Simon asked for filter, shaper and processing speed as separate rows. They
# used to arrive joined - "Filter X - Shaper Y - 30.3x realtime" - which put the
# labels inside the value and left nothing to align.
ok(scalar($SENT =~ /row\(L\.filter,\s+b\.filter\)/),     'filter has a row of its own');
ok(scalar($SENT =~ /row\(L\.shaper,\s+b\.shaper\)/),     'shaper has a row of its own');
ok(scalar($SENT =~ /row\(L\.processing, b\.speed\)/),     'and the processing speed has a row of its own');
ok(scalar($SENT !~ /b\.processing/),
   'the joined processing string is no longer read - it does not exist any more');

print "-- the poll does not churn the DOM it did not change --\n";
# The signal-path card is rewritten once a second, and an innerHTML rewrite
# drops any text selection inside it - so a user copying a filter name could
# never finish. While a track plays the speed really does change every second;
# stopped, paused or waiting for a player, the card must hold still.
ok(scalar($SENT =~ /if \(html !== lastCards\)/),
   'the signal-path card is only rewritten when it actually differs');

# The "updated HH:MM:SS" clock existed to prove the page was ticking while the
# settings page's poller was being diagnosed. That is settled, and a number
# changing in the corner is not information.
ok(scalar($SENT !~ /not yet updated/) && scalar($SENT !~ /'updated '/),
   'the updated-at ticker is gone');
ok(scalar($SENT =~ /id="dot"/) && scalar($SENT =~ /id="err"/),
   'but the live/failed dot and the reason for a failure remain');

print "-- no player yet is a STATE, not an error --\n";
# THE ALARMIST STARTUP. `signalpath` omits bridges_loop entirely when it has
# nothing to put in it - addResultLoop is simply never called - so treating a
# missing loop as a bad reply painted a red dot and a "bad reply" string for the
# whole time between the server starting and HQPlayer being discovered. Nothing
# is wrong there.
ok(scalar($SENT !~ /no bridges_loop in reply/),
   'a missing bridges_loop is no longer reported as a bad reply');
ok(scalar($SENT =~ /var loop = r\.bridges_loop \|\| \[\];/),
   'it is read as an empty list - the poll answered, there is just no player yet');
ok(scalar($SENT =~ /if \(!r\) \{ throw new Error\('no result in reply'\)/),
   'a genuinely malformed reply is still an error');
ok(scalar($SENT !~ /No HQPlayer instances found/),
   'and the alarming empty-list wording is gone');
ok(scalar($SENT !~ /Starting/),
   'as is the placeholder that said Starting');

# A command is addressed to a PLAYER, and `id` in the loop is the INSTANCE key.
# Sending to the wrong one silently controls nothing.
ok(scalar($SENT =~ /params: \[ CUR\.playerid, params \]/),
   'commands are addressed to the bridge PLAYER id, not the instance key');

# The reply to a volume set is racing a poll that already left, and that poll
# carries the OLD level. Writing it back is what makes a slider snap backwards.
ok(scalar($SENT =~ /volHold = Date\.now\(\)/),
   'the server volume is ignored briefly after we set it');
ok(scalar($SENT =~ /if \(!dragging && Date\.now\(\) > volHold/),
   'and while the user is holding the thumb');

# use_volume_control is the flag every other skin hides its slider on - it is
# already 0 when the user has set this player to fixed volume in LMS.
ok(scalar($SENT =~ /np_volctl === 0/),
   'the slider hides on LMS\'s own fixed-volume flag');

print "-- the icons are Material's, and survive Material being absent --\n";
ok(scalar($SENT =~ m{/material/html/font/font\.css}),
   "it loads Material's own icon font rather than a lookalike");
ok(scalar($SENT =~ /play_circle_filled/) && scalar($SENT =~ /skip_next/),
   'and uses its glyph names');

# A Material Icons glyph is selected by its LIGATURE, so with the font missing
# the element's text - the literal word "play_circle_filled" - is what the user
# reads. That is the failure mode this check exists for.
ok(scalar($SENT =~ /noicons/),
   'a missing icon font is detected rather than rendering the ligature TEXT');
ok(scalar($SENT =~ /content: attr\(data-alt\)/),
   'and each glyph carries a Unicode stand-in to draw instead');
ok(scalar($SENT =~ /String\.fromCharCode\(9654\)/),
   'built from a code point, never a backslash escape (this is a Perl heredoc)');

print "-- nowPlayingFor: the resolution the server does --\n";
# Exercised against the REAL sub with a staged status result, so the artwork
# order and the remoteMeta fallbacks are what is tested - not a restatement.
{
    require Plugins::HQPlayerBridge::Plugin;

    my $c = bless {}, 'NpClient';
    $Slim::Player::Source::SONGTIME = 12.5;

    # A LOCAL track: artwork comes from /music/<coverid>/cover.jpg.
    $Slim::Control::Request::RESULTS = {
        mode => 'play',
        playlist_loop => [ { title => 'One', artist => 'A', album => 'B',
                             coverid => '6d07af45', duration => 200 } ],
    };
    my $np = Plugins::HQPlayerBridge::Plugin::nowPlayingFor($c);
    is($np->{title},    'One',   'title');
    is($np->{artist},   'A',     'artist');
    is($np->{artwork},  '/music/6d07af45/cover.jpg', 'a local cover comes off /music/<coverid>');
    is($np->{state},    'playing', 'and the mode maps to a state');
    is($np->{position}, '12.5',  'position comes from songTime, not the status result');

    # A REMOTE track: artwork_url WINS, and the metadata is at the TOP level.
    $Slim::Control::Request::RESULTS = {
        mode => 'play',
        playlist_loop => [ { coverid => '-94350071504528',
                             artwork_url => '/imageproxy/xyz/image.jpg' } ],
        remoteMeta => { title => 'R', artist => 'RA', album => 'RB', duration => 99 },
    };
    $np = Plugins::HQPlayerBridge::Plugin::nowPlayingFor($c);
    is($np->{artwork}, '/imageproxy/xyz/image.jpg',
       'artwork_url is preferred over any coverid');
    is($np->{title},  'R',  'title falls back to remoteMeta');
    is($np->{album},  'RB', 'and album');
    is($np->{duration}, '99', 'and duration');

    # THE NEGATIVE-COVERID RULE. LMS mints synthetic NEGATIVE ids for remote
    # tracks and /music/ answers 404 for them - a cover URL built from one is a
    # BROKEN image, which is worse than none.
    $Slim::Control::Request::RESULTS = {
        mode => 'play',
        playlist_loop => [ { title => 'N', coverid => '-94350071504528' } ],
    };
    $np = Plugins::HQPlayerBridge::Plugin::nowPlayingFor($c);
    ok(scalar(!exists $np->{artwork}),
       'a NEGATIVE coverid yields no artwork at all - /music/ 404s on those');

    # NOTHING PLAYING DROPS THE TRACK, NOT THE PLAYER. The track keys are still
    # absent rather than blank - that is what makes the page draw no artwork and
    # no title. What must SURVIVE is the endpoint's own state, because the
    # transport and volume controls are exactly what a user reaches for while
    # the queue is stopped, and a mute button with no idea whether it is muted
    # is not a control.
    $Slim::Control::Request::RESULTS = {
        mode => 'stop', playlist_loop => [],
        'mixer volume' => 42, use_volume_control => 1,
    };
    $np = Plugins::HQPlayerBridge::Plugin::nowPlayingFor($c);
    ok(scalar(!grep { exists $np->{$_} } qw( title artist album artwork duration position )),
       'nothing playing yields no TRACK keys, not blank strings');
    is($np->{state},  'stopped', 'but the player state survives');
    is($np->{volume}, '42',      'and its volume');

    # THE SIGN IS THE MUTE FLAG. There is no separate muting field in a status
    # result: LMS stores the level NEGATED while muted. A reader that misses
    # this shows "-42" on the slider and never lights the mute button. Material
    # does exactly this (server.js: volume<0, then Math.abs).
    $Slim::Control::Request::RESULTS = {
        mode => 'play',
        playlist_loop => [ { title => 'M', duration => 10 } ],
        'mixer volume' => -42, use_volume_control => 1,
    };
    $np = Plugins::HQPlayerBridge::Plugin::nowPlayingFor($c);
    is($np->{muted},  '1',  'a NEGATIVE mixer volume is what muted means');
    is($np->{volume}, '42', 'and the level shown is its magnitude');

    # use_volume_control is 0 when the user set this player to fixed volume in
    # LMS's own audio settings - the one switch that means LMS stops driving
    # HQPlayer's level. Every skin hides its slider on it, so this page must too.
    $Slim::Control::Request::RESULTS = {
        mode => 'play',
        playlist_loop => [ { title => 'F', duration => 10 } ],
        'mixer volume' => 42, use_volume_control => 0,
    };
    $np = Plugins::HQPlayerBridge::Plugin::nowPlayingFor($c);
    is($np->{volctl}, '0', 'a fixed-volume player reports no volume control');

    # ABSENT is not the same as 0 - a status result without the field at all
    # must not be read as "fixed", which would hide a working slider.
    $Slim::Control::Request::RESULTS = {
        mode => 'play', playlist_loop => [ { title => 'F', duration => 10 } ],
    };
    $np = Plugins::HQPlayerBridge::Plugin::nowPlayingFor($c);
    is($np->{volctl}, '1', 'and a MISSING use_volume_control is not read as fixed');
    ok(scalar(!exists $np->{volume}),
       'a missing mixer volume yields no volume key rather than 0');

    # A failed request must not yield half a snapshot either.
    $Slim::Control::Request::ERROR = 1;
    $np = Plugins::HQPlayerBridge::Plugin::nowPlayingFor($c);
    ok(scalar(!exists $np->{title}), 'and a failed status request yields no title');
    $Slim::Control::Request::ERROR = 0;
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
