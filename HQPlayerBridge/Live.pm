package Plugins::HQPlayerBridge::Live;

# THE LIVE SIGNAL PATH, AS A STANDALONE PAGE.
#
# WHY THIS EXISTS AND THE SETTINGS PAGE DOES NOT DO IT.
#
# The settings page polls itself the same way, and on Simon's Material it never
# updated. Everything measurable about it checked out - the query answers live,
# the served script is syntactically clean and, executed against a real
# response, writes every row correctly; Material uses a plain <iframe :src> with
# no sandbox and no CSP, and its applyModifications() only adds CSS classes to a
# plugin page. So the fault was never located, and defending that page further
# was costing rounds.
#
# What the settings page CANNOT shed is its surroundings: it is a
# Slim::Web::Settings page rendered through `[% PROCESS settings/header.html %]`,
# so it arrives wrapped in the whole classic-skin settings shell - mousetrap,
# custom-select, the theme bootstrap, chooseSettings, two nested forms - and
# Material then loads that inside its iframe dialog.
#
# This route removes every one of those variables instead of reasoning about
# them. It is a raw handler, so the bytes below are the WHOLE document: no
# template, no skin, no settings chrome. Reached from the Apps feed or from the
# Material Home tile, it is the same footing as any ordinary web page - and it
# works framed (Material's iframe dialog) or standalone; see the back button.
#
# TRAP: THE JS BELOW LIVES IN AN INTERPOLATING PERL HEREDOC (<<"HTML").
# Every backslash escape is PERL's before it is JavaScript's. `\u2014` is not an
# em dash here - it is Perl's "titlecase the next character", and it rendered
# live as the literal text "Luluc 2014 Passerby". `\d`, `\.`, `\x` and `\U` are
# all the same class of hazard, so a JS REGEX cannot be written literally here
# either. Build such characters at runtime (String.fromCharCode, new RegExp with
# a doubled backslash) rather than escaping them, and there is nothing for Perl
# to eat. `$` and `@` are already escaped throughout for the same reason.
#
# TRAP: A RAW HANDLER OWNS ITS STATUS CODE. LMS builds the status line as
# sprintf("%s %s %s", protocol, code, message) and fills in nothing, so a
# handler that never calls $response->code() emits a literal "HTTP/1.1  ".
# That shipped once in this plugin and broke every m4a track for 13 versions.
# See Stream.pm and the ledger.

use strict;
use warnings;

use Slim::Utils::Strings qw(cstring);
use Slim::Web::Pages;
use Slim::Web::HTTP;

# Path-only, and deliberately short: it is typed by hand as often as it is
# clicked.
use constant PATH => '/hqplive';

# THE VERSION IS HANDED IN, NOT FETCHED. A page module must not call into its
# own Plugin.pm at request time unless it `use`s it: the call dies, the handler
# dies PART WAY THROUGH, and LMS renders whatever was built before the die - so
# the symptom is a page that merely looks mis-built, with nothing in the log
# saying "crash". That shipped Eversolo Screen Control 1.5.0 completely broken
# with every check green. Nothing here reaches outside this file.
my $VERSION = '';

sub init {
    my ( $class, $version ) = @_;

    $VERSION = defined $version ? $version : '';

    Slim::Web::Pages->addRawFunction( qr{^/hqplive}, \&_handler );

    return;
}

sub _handler {
    my ( $httpClient, $response ) = @_;

    return unless $httpClient && $httpClient->connected;

    my $body = _page();

    # The code, FIRST and explicitly - see the trap at the top of this file.
    $response->code(200);
    $response->content_type('text/html; charset=utf-8');

    # This page is a live view. A cached copy of it is a lie, and the settings
    # page's lack of any cache header was one of the things that could not be
    # ruled out while diagnosing it.
    $response->header( 'Cache-Control' => 'no-cache, no-store, must-revalidate' );
    $response->header( Pragma          => 'no-cache' );

    Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$body );

    return;
}

# The labels are rendered HERE, at request time, so they are localised by the
# same cstring() the other two surfaces use. Everything that CHANGES comes from
# the signalpath query, which already answers finished display strings - the
# page never formats a value and never takes one apart.
sub _page {
    my $c = undef;   # no player context: these are server-wide labels

    my %L = (
        title      => cstring( $c, 'PLUGIN_HQPLAYER_BRIDGE' ),
        status     => cstring( $c, 'PLUGIN_HQPLAYER_STATUS' ),
        source     => cstring( $c, 'PLUGIN_HQPLAYER_SOURCE' ),
        output     => cstring( $c, 'PLUGIN_HQPLAYER_OUTFORMAT' ),
        filter     => cstring( $c, 'PLUGIN_HQPLAYER_FILTER' ),
        shaper     => cstring( $c, 'PLUGIN_HQPLAYER_SHAPER' ),
        processing => cstring( $c, 'PLUGIN_HQPLAYER_PROCESSING' ),
        back       => cstring( $c, 'PLUGIN_HQPLAYER_LIVE_BACK' ),
        prev       => cstring( $c, 'PLUGIN_HQPLAYER_CTL_PREV' ),
        next       => cstring( $c, 'PLUGIN_HQPLAYER_CTL_NEXT' ),
        play       => cstring( $c, 'PLUGIN_HQPLAYER_CTL_PLAY' ),
        pause      => cstring( $c, 'PLUGIN_HQPLAYER_CTL_PAUSE' ),
        mute       => cstring( $c, 'PLUGIN_HQPLAYER_CTL_MUTE' ),
        unmute     => cstring( $c, 'PLUGIN_HQPLAYER_CTL_UNMUTE' ),
        volume     => cstring( $c, 'PLUGIN_HQPLAYER_CTL_VOLUME' ),
        voldn      => cstring( $c, 'PLUGIN_HQPLAYER_CTL_VOLDN' ),
        volup      => cstring( $c, 'PLUGIN_HQPLAYER_CTL_VOLUP' ),
        waiting    => cstring( $c, 'PLUGIN_HQPLAYER_LIVE_WAITING' ),
    );

    $_ = _esc($_) for values %L;

    my $ver = _esc($VERSION);

    return <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$L{title}</title>

<!-- MATERIAL'S OWN FONTS, not a lookalike. Roboto is what Material sets its
     type in, and 'Material Icons' is the font behind every <v-icon> in it - so
     the transport and volume glyphs here are literally the same artwork as the
     ones on Material's Now Playing screen, at whatever size this page asks for.
     Verified serving: /material/html/font/font.css -> 200, and the .ttf it
     pulls beside itself -> 200.

     It is a plain <link>, so if MaterialSkin is not installed this 404s and
     nothing else breaks: the icon check in the script below notices the font
     never arrived and swaps every glyph for a Unicode one. -->
<link rel="stylesheet" href="/material/html/font/font.css">

<script>
// MATCH MATERIAL'S THEME - and this is LMS's OWN recipe, not a guess.
//
// The classic skin's settings header does exactly this to make itself match
// Material, and it is the only supported way for a non-Material page to do so:
// Material records the user's choice in localStorage, and both keys are on the
// SAME ORIGIN as this page, so they can simply be read.
//
//   lms-material::theme   dark | darker | light | auto | <name>[-colored] | user:<name>
//   lms-material::color   blue | <name> | user:<name>
//
// The normalisation below is copied from that header verbatim in behaviour:
// `darker` renders as dark, `auto` follows the OS, a trailing `-colored` /
// `-standard` is a VARIANT and not part of the theme name, and `user:` themes
// live under a different path. Getting this wrong shows a light page inside a
// dark Material, which is worse than not trying.
//
// The stylesheets define --std-background-color, --std-popup-background-color,
// --primary-color and --accent-color. They do NOT define a text colour, because
// Material gets that from Vuetify's theme--dark/theme--light - so the page sets
// its own from the light/dark decision below.
(function () {
    var theme, col;
    try {
        theme = localStorage.getItem('lms-material::theme');
        col   = localStorage.getItem('lms-material::color');
    } catch (e) { /* private mode, or no Material has ever run here */ }

    if (!theme || theme === 'darker') { theme = 'dark'; }
    if (theme === 'auto') {
        theme = (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches)
            ? 'light' : 'dark';
    }

    var parts   = theme.split('-');
    var last    = parts[parts.length - 1];
    if (parts.length > 1 && (last === 'colored' || last === 'standard')) { parts.pop(); }
    var name    = parts.join('-');
    var isLight = theme.indexOf('light') === 0 || theme.indexOf('/light/') >= 0;

    function css(href) {
        var l = document.createElement('link');
        l.rel = 'stylesheet'; l.href = href;
        document.head.appendChild(l);
    }

    css(name.indexOf('user:') === 0
        ? '/material/usertheme/' + name.substring(5)
        : '/html/css/themes/' + (isLight ? 'light' : name) + '.min.css');

    if (col) {
        css(col.indexOf('user:') === 0
            ? '/material/usercolor/' + col.substring(5)
            : '/html/css/colors/' + col + '.min.css');
    }

    document.documentElement.className = isLight ? 'lt' : 'dk';
}());
</script>
<style>
/* Material's own stylesheets supply --std-background-color,
   --std-popup-background-color, --primary-color and --accent-color. They carry
   no TEXT colour (Vuetify provides it there), so that half is set from the
   light/dark class the bootstrap above stamped on <html>. The fallbacks are
   Material's real values, so the page is still right if the stylesheets are
   missing - e.g. a server with no Material installed. */
:root {
  --bg:   var(--std-background-color, #212121);
  --card: var(--std-popup-background-color, #303030);
  --fg:   #ffffff;
  --dim:  rgba(255,255,255,0.55);
  --line: rgba(255,255,255,0.10);
  --accent: var(--accent-color, #82b1ff);
  --ok: #81c784; --bad: #ef9a9a;
}
html.lt {
  --bg:   var(--std-background-color, #fafafa);
  --card: var(--std-popup-background-color, #ffffff);
  --fg:   rgba(0,0,0,0.87);
  --dim:  rgba(0,0,0,0.54);
  --line: rgba(0,0,0,0.10);
  --accent: var(--primary-color, #1976d2);
  --ok: #2e7d32; --bad: #c62828;
}
* { box-sizing: border-box; }

/* IT SCALES, RATHER THAN SITTING AT ONE SIZE.
   Every size below is a clamp(min, viewport-relative, max) so the page grows
   with the window the way Material's does, instead of drawing phone-sized
   furniture in the middle of a desktop browser. The artwork was the visible
   symptom - a hard 96px cover on a full-width card reads as tiny - but the type
   had the same problem, so it scales with it and in the same proportion.
   The min is the old mobile size, which is why nothing changes on a phone. */
:root {
  --art:  clamp(96px, 15vw, 208px);
  --gap:  clamp(12px, 1.6vw, 20px);
}
body { margin: 0; padding: var(--gap); background: var(--bg); color: var(--fg);
       font: clamp(14px, 1vw, 16px)/1.5 Roboto, -apple-system, BlinkMacSystemFont,
             "Segoe UI", sans-serif; }

/* And it CENTRES. Full-bleed rows on a wide screen are the other half of why
   the cover looked lost: the card either side of it was 1900px long. */
.wrap { max-width: 1100px; margin: 0 auto; }

h1 { font-size: clamp(16px, 1.3vw, 21px); margin: 0 0 2px; font-weight: 600; }
.sub { color: var(--dim); font-size: 0.86em; margin-bottom: 16px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 8px;
        padding: var(--gap); margin-bottom: 12px; }
.row { display: flex; gap: 12px; padding: 6px 0; border-top: 1px solid var(--line); }
.row:first-child { border-top: 0; }
.k { color: var(--dim); flex: 0 0 clamp(120px, 12vw, 168px); }
.v { flex: 1 1 auto; word-break: break-word; }
.name { font-weight: 600; font-size: 1.08em; margin-bottom: 6px; }
.ok { color: var(--ok); } .bad { color: var(--bad); }
.foot { color: var(--dim); font-size: 0.86em; display: flex; gap: 10px; align-items: center; }
.top { display: flex; align-items: baseline; gap: 12px; margin-bottom: 16px; }
.top .sub { margin: 0; }
#back { margin-left: auto; flex: 0 0 auto; padding: 5px 12px; border: 1px solid var(--line);
        border-radius: 4px; background: var(--card); color: var(--accent);
        font: inherit; font-size: 0.92em; cursor: pointer; }
#back:hover { border-color: var(--accent); }
.dot { width: 8px; height: 8px; border-radius: 50%; background: var(--dim);
       display: inline-block; transition: background .2s; }
.dot.live { background: var(--ok); }
.dot.err  { background: var(--bad); }
.err { color: var(--bad); }

/* NOW PLAYING - laid out like Material's: cover left, title/artist/album and
   the controls right. */
.np { display: flex; gap: var(--gap); align-items: center; }
.np-art { flex: 0 0 var(--art); width: var(--art); height: var(--art); border-radius: 6px;
          object-fit: cover; background: var(--line); }
.np-txt { min-width: 0; flex: 1 1 auto; }
.np-title { font-size: clamp(17px, 1.5vw, 25px); font-weight: 600; }
.np-sub { color: var(--dim); margin-top: 2px; font-size: clamp(13px, 1.05vw, 17px); }
.np-title, .np-sub { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.np-time { color: var(--dim); font-size: 0.86em; margin-top: 6px;
           font-variant-numeric: tabular-nums; }
.np-bar { height: 3px; border-radius: 2px; background: var(--line); margin-top: 8px; }
.np-bar > i { display: block; height: 100%; border-radius: 2px;
              background: var(--accent); width: 0; }

/* IDLE COLLAPSES TO THE CONTROLS. Nothing playing still draws no artwork, no
   title and no progress bar - the rule that an empty panel is worse than none
   has not changed. But the transport and volume have to live somewhere when the
   queue is stopped, and a mute button you cannot reach unless music is already
   playing is not a control. So the card keeps its control row and drops
   everything else. */
.np.idle > .np-art { display: none; }
.np.idle .np-title, .np.idle .np-sub,
.np.idle .np-bar, .np.idle .np-time { display: none; }
.np.idle .np-ctl { margin-top: 0; }
#np.hidden { display: none; }

.np-ctl { display: flex; align-items: center; gap: var(--gap);
          margin-top: 10px; flex-wrap: wrap; }
.np-tr  { display: flex; align-items: center; gap: 4px; }
.np-vol { display: flex; align-items: center; gap: 10px; min-width: 0;
          margin-left: auto; flex: 0 1 clamp(160px, 22vw, 280px); }
.np-vol.off { display: none; }
/* The level doubles as the mute toggle, so it is a real <button> - Material
   puts that gesture on this label too. It must not look like a form control,
   hence the reset; it must still read as pressable, hence the pointer and the
   accent on hover. */
/* min-width, not a fixed basis: a fixed 2.4em clips a three-digit level. */
.np-volv { color: var(--dim); font: inherit; font-size: 0.86em;
           font-variant-numeric: tabular-nums; flex: 0 0 auto; min-width: 2.4em;
           text-align: right;
           background: none; border: 0; padding: 0; cursor: pointer; }
.np-volv:hover { color: var(--accent); }
/* Material dims this label while muted (`'dimmed':muted` on its own volume
   label), and the mute button lights in the accent colour - between them the
   state is unmistakable without any other control having to change. */
.np-volv.dimmed { opacity: 0.45; }
.tbtn.vol.on { color: var(--accent); }
.np-volv:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

/* MATERIAL ICONS, declared here as well as in Material's font.css, because this
   page has to render correctly on a server that has no Material installed - and
   in that case font.css itself is the thing that is missing. */
.mi { font-family: 'Material Icons'; font-weight: normal; font-style: normal;
      line-height: 1; letter-spacing: normal; text-transform: none;
      display: inline-block; white-space: nowrap; word-wrap: normal; direction: ltr;
      font-size: var(--sz); -webkit-font-feature-settings: 'liga';
      font-feature-settings: 'liga'; }

/* NO FONT, NO LIGATURE - and the failure mode matters. A Material Icons glyph
   is selected by its LIGATURE, so the element's text is the literal word
   "play_circle_filled". With the font absent that word is what the user reads.
   The script sets html.noicons when the font did not arrive; the rule below
   then hides the word and draws the Unicode glyph held in data-alt instead. */
html.noicons .mi { font-size: 0; }
html.noicons .mi::after { content: attr(data-alt); font-family: inherit;
                          font-size: calc(var(--sz) * 0.78); }

/* WHO GIVES WAY WHEN THE ROW IS TOO NARROW - AND IT MUST BE EXACTLY ONE THING.
   A flex item defaults to `flex: 0 1 auto`, so every button was ALSO offering to
   shrink. None of them can (an icon glyph is its content width), so the browser
   distributes the overflow across four items that all refuse, and what is left
   over runs off the end of the card. On Simon's iPhone that pushed the volume
   level outside the box - reported against 0.2.74, and the mute button added in
   0.2.72 is what tipped the row over. Pin the buttons, and let the slider be the
   only thing that gives. */
.tbtn { background: none; border: 0; padding: 2px; margin: 0; line-height: 0;
        flex: 0 0 auto; color: var(--fg); cursor: pointer; }
.tbtn:hover { color: var(--accent); }
.tbtn:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.tbtn.big { --sz: clamp(42px, 4vw, 58px); }
.tbtn.std { --sz: clamp(30px, 2.8vw, 40px); }
.tbtn.vol { --sz: clamp(22px, 1.8vw, 28px); color: var(--dim); }
.tbtn.vol:hover { color: var(--accent); }

/* The slider, styled to Material's: a thin neutral track with an accent thumb.
   Both vendor prefixes are required - a browser DROPS a whole rule containing a
   pseudo-element it does not know, so these cannot be combined into one. */
/* `flex: 1 1 0`, NOT `1 1 auto`. With an auto basis the slider starts at its
   INTRINSIC width - a range input carries a UA-defined one of about 130px - and
   only shrinks proportionally to the overflow, so it stays far wider than the
   space actually left. A zero basis makes it take exactly what remains, and
   min-width:0 defeats the automatic content-based minimum a flex item gets. */
input[type=range] { -webkit-appearance: none; appearance: none; background: transparent;
                    flex: 1 1 0; min-width: 0; height: 20px; margin: 0; cursor: pointer; }
input[type=range]::-webkit-slider-runnable-track { height: 4px; border-radius: 2px;
                    background: var(--line); }
input[type=range]::-webkit-slider-thumb { -webkit-appearance: none; width: 14px; height: 14px;
                    border-radius: 50%; background: var(--accent); margin-top: -5px; }
input[type=range]::-moz-range-track { height: 4px; border-radius: 2px; background: var(--line); }
input[type=range]::-moz-range-thumb { width: 14px; height: 14px; border: 0;
                    border-radius: 50%; background: var(--accent); }

\@media (max-width: 480px) {
  .np-vol { margin-left: 0; flex-basis: 100%; }
}
</style>
</head>
<body>

<div class="wrap">

<h1>$L{title}</h1>
<div class="top">
  <div class="sub">v$ver &middot; live signal path</div>
  <button id="back" type="button">$L{back}</button>
</div>

<div id="np" class="hidden"></div>
<div id="cards"><div class="card"><div class="v">$L{waiting}</div></div></div>

<div class="foot">
  <span class="dot" id="dot"></span>
  <span class="err" id="err"></span>
</div>

</div>

<script>
// A PLAIN TOP-LEVEL PAGE. No skin, no settings shell, no iframe - which is the
// whole point of this route. If this does not tick, nothing about how the page
// is rendered is to blame and the fault is the query or the browser.
(function () {
    var PERIOD = 1000;
    var L = {
        status:     "$L{status}",
        source:     "$L{source}",
        output:     "$L{output}",
        filter:     "$L{filter}",
        shaper:     "$L{shaper}",
        processing: "$L{processing}",
        prev:       "$L{prev}",
        next:       "$L{next}",
        play:       "$L{play}",
        pause:      "$L{pause}",
        mute:       "$L{mute}",
        unmute:     "$L{unmute}",
        volume:     "$L{volume}",
        voldn:      "$L{voldn}",
        volup:      "$L{volup}",
        waiting:    "$L{waiting}"
    };
    var cards = document.getElementById('cards');
    var npEl  = document.getElementById('np');
    var dot   = document.getElementById('dot');
    var errEl = document.getElementById('err');

    function esc(s) {
        return String(s).replace(/[&<>"]/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
        });
    }

    function row(k, v, cls) {
        if (v === undefined || v === null || v === '') return '';
        return '<div class="row"><div class="k">' + esc(k) + '</div>' +
               '<div class="v' + (cls ? ' ' + cls : '') + '">' + esc(v) + '</div></div>';
    }

    // EVERY NON-ASCII CHARACTER ON THIS PAGE IS BUILT FROM ITS CODE POINT.
    // This script sits in an interpolating Perl heredoc, where a backslash
    // escape belongs to PERL, not to JavaScript: a backslash-u for an em dash
    // is read as Perl's "titlecase the next character", and it shipped once as
    // the escape's own four digits, printed between an artist and an album. See
    // the trap note at the top of this file, which also carries the example -
    // it cannot be repeated HERE, because this comment is served to the browser
    // and the test for the bug greps the SERVED BYTES for those digits. A JS
    // regex cannot be written literally here either.
    var EM_DASH = String.fromCharCode(8212);

    // The Unicode stand-ins for the Material glyphs, used only when the font
    // is missing. Keyed by ligature so the two can never drift apart.
    var ALT = {
        skip_previous:      String.fromCharCode(9198),
        skip_next:          String.fromCharCode(9197),
        play_circle_filled: String.fromCharCode(9654),
        pause_circle_filled: String.fromCharCode(9208),
        volume_up:          String.fromCodePoint(128266),
        volume_off:         String.fromCodePoint(128263)
    };

    function icon(el, name) {
        if (el.textContent === name) { return; }
        el.textContent = name;
        el.setAttribute('data-alt', ALT[name] || '');
    }

    // DID THE ICON FONT ACTUALLY ARRIVE? On a server with no MaterialSkin the
    // stylesheet 404s, no font-face rule is ever declared, and every button would
    // otherwise render its LIGATURE TEXT - the user reads "play_circle_filled".
    // load() resolves with an empty list when there is no matching face, so
    // check() is the answer either way and neither call can throw the page.
    function iconCheck() {
        function fail() { document.documentElement.classList.add('noicons'); }
        try {
            if (!document.fonts) { fail(); return; }
            document.fonts.load('24px "Material Icons"').then(function () {
                if (!document.fonts.check('24px "Material Icons"')) { fail(); }
            }, fail);
        } catch (e) { fail(); }
    }

    function clock(s) {
        s = Math.floor(s || 0);
        var m = Math.floor(s / 60);
        var r = s % 60;
        return m + ':' + (r < 10 ? '0' : '') + r;
    }

    // ---------------------------------------------------------------------
    // NOW PLAYING + CONTROLS.
    //
    // BUILT ONCE, THEN UPDATED IN PLACE. The panel used to be re-rendered from
    // an innerHTML string, guarded by a signature so it only happened when
    // something changed - but the position is IN that signature, so in practice
    // it was rebuilt every single second. That was survivable for a cover and
    // some text. It is not survivable now: rebuilding the markup under a slider
    // the user is dragging replaces the element mid-gesture, and a focused
    // button loses focus once a second. So the DOM is created once, the
    // handlers are bound once, and each poll writes values into it.
    // ---------------------------------------------------------------------
    var el   = null;   // the panel's elements, once built
    var CUR  = null;   // the bridge the controls are addressed to

    function build() {
        npEl.innerHTML =
            '<div class="card np" id="npcard">' +
              '<img class="np-art" id="np-art" alt="">' +
              '<div class="np-txt">' +
                '<div class="np-title" id="np-title"></div>' +
                '<div class="np-sub" id="np-sub"></div>' +
                '<div class="np-bar"><i id="np-bar"></i></div>' +
                '<div class="np-time" id="np-time"></div>' +
                '<div class="np-ctl">' +
                  '<div class="np-tr">' +
                    '<button class="tbtn std" id="c-prev" type="button" title="' + esc(L.prev) + '">' +
                      '<span class="mi" id="i-prev"></span></button>' +
                    '<button class="tbtn big" id="c-pp" type="button">' +
                      '<span class="mi" id="i-pp"></span></button>' +
                    '<button class="tbtn std" id="c-next" type="button" title="' + esc(L.next) + '">' +
                      '<span class="mi" id="i-next"></span></button>' +
                  '</div>' +
                  // MATERIAL'S OWN VOLUME WIDGET, in its order - a down button,
                  // the slider, an up button, then the level - with a DEDICATED
                  // MUTE BUTTON added in front of it.
                  //
                  // Material has no such button: it hides that gesture on the
                  // level label (middle-click, or long-press) and shows the
                  // muted state by flipping BOTH step buttons to volume_off.
                  // That is undiscoverable, so this adds a real button - and
                  // once there is one, the step buttons must STOP flipping,
                  // because three volume_off glyphs in a row say the state
                  // three times and leave the user guessing which one mutes.
                  //
                  // So each control now means exactly one thing: the step
                  // buttons always show their own direction, and mute is the
                  // one control that shows and changes the muted state. It
                  // carries the volume_off glyph as its ACTION and lights in
                  // the accent colour while muted; the level dims alongside it,
                  // which is Material's own `dimmed` treatment for that label.
                  // Clicking the level still toggles too - Material's gesture,
                  // kept because removing it would take away something that
                  // already worked.
                  '<div class="np-vol" id="np-vol">' +
                    '<button class="tbtn vol" id="c-mute" type="button">' +
                      '<span class="mi" id="i-mute"></span></button>' +
                    '<button class="tbtn vol" id="c-vdn" type="button" title="' + esc(L.voldn) + '">' +
                      '<span class="mi" id="i-vdn"></span></button>' +
                    '<input type="range" id="c-vol" min="0" max="100" step="1" ' +
                      'title="' + esc(L.volume) + '" aria-label="' + esc(L.volume) + '">' +
                    '<button class="tbtn vol" id="c-vup" type="button" title="' + esc(L.volup) + '">' +
                      '<span class="mi" id="i-vup"></span></button>' +
                    '<button class="np-volv" id="c-volv" type="button"></button>' +
                  '</div>' +
                '</div>' +
              '</div>' +
            '</div>';

        function g(id) { return document.getElementById(id); }

        // Every element the updater touches is held DIRECTLY. An earlier draft
        // reached the mute button as el.imute.parentNode, which works but is
        // one silent assumption about the markup away from a TypeError that
        // aborts the whole update - and it did, when the page was executed
        // against a real payload.
        el = { card: g('npcard'), art: g('np-art'), title: g('np-title'),
               sub: g('np-sub'), bar: g('np-bar'), time: g('np-time'),
               pp: g('c-pp'), ipp: g('i-pp'),
               ivdn: g('i-vdn'), ivup: g('i-vup'), mute: g('c-mute'),
               vol: g('c-vol'), volv: g('c-volv'), volbox: g('np-vol') };

        icon(g('i-prev'), 'skip_previous');
        icon(g('i-next'), 'skip_next');
        icon(el.ipp,      'play_circle_filled');
        icon(el.ivdn,     'volume_down');
        icon(el.ivup,     'volume_up');
        icon(g('i-mute'), 'volume_off');

        // MATERIAL'S OWN COMMANDS, not equivalents. Read from its source so the
        // buttons here behave identically to the ones on its Now Playing page:
        //   prev  ['button','jump_rew']       (restart-then-previous, like the
        //                                      hardware button - NOT index -1)
        //   next  ['playlist','index','+1']
        //   play  ['pause'] when playing, ['play'] otherwise
        g('c-prev').addEventListener('click', function () { cmd(['button', 'jump_rew']); });
        g('c-next').addEventListener('click', function () { cmd(['playlist', 'index', '+1']); });
        el.pp.addEventListener('click', function () {
            cmd([ (CUR && CUR.np_state === 'playing') ? 'pause' : 'play' ]);
        });
        function toggleMute() {
            cmd(['mixer', 'muting', (CUR && CUR.np_muted) ? 0 : 1]);
        }

        el.mute.addEventListener('click', toggleMute);
        el.volv.addEventListener('click', toggleMute);

        g('c-vdn').addEventListener('click', function () { step(-1); });
        g('c-vup').addEventListener('click', function () { step(1); });

        // The number follows the thumb while dragging; the command goes on
        // release. `change` is what Material sends on, and firing per `input`
        // would put a request on the wire for every pixel of the drag.
        el.vol.addEventListener('input',  function () { el.volv.textContent = el.vol.value; });
        el.vol.addEventListener('change', function () {
            cmd(['mixer', 'volume', el.vol.value]);
        });
    }

    // THE STEP IS THE USER'S OWN, read from Material rather than picked here.
    // Material keeps it at `lms-material::volumeStep` on the SAME ORIGIN as
    // this page - the theme is read the same way - so its buttons and these
    // move the volume by the same amount. 5 is Material's default, used when
    // Material has never run in this browser.
    var VOLSTEP = 5;
    try {
        var vs = parseInt(localStorage.getItem('lms-material::volumeStep'), 10);
        if (vs > 0 && vs <= 100) { VOLSTEP = vs; }
    } catch (e) { /* private mode, or no Material has ever run here */ }

    // A STEP MOVES THE SLIDER AT ONCE, then tells the server. The reply is held
    // off for a moment (see volHold), so without this a second press would step
    // from a stale value and the widget would look stuck while the level was
    // actually moving. The command itself is RELATIVE - Material sends "+5" /
    // "-5" rather than a computed level - so the server, not this page, is the
    // one that decides what the ends of the range are.
    function step(dir) {
        if (!CUR || CUR.np_volume === undefined) { return; }
        var v = parseInt(el.vol.value, 10);
        if (!(v >= 0)) { v = CUR.np_volume; }
        v = Math.max(0, Math.min(100, v + dir * VOLSTEP));
        el.vol.value = v;
        el.volv.textContent = v;
        cmd(['mixer', 'volume', (dir > 0 ? '+' : '-') + VOLSTEP]);
    }

    // WHO THE CONTROLS TALK TO. The playing bridge if there is one, otherwise
    // the first bridge that has a player at all - which is what keeps the
    // volume reachable while the queue is stopped.
    function pick(loop) {
        var i, idle = null;
        for (i = 0; i < loop.length; i++) {
            if (loop[i].np_title && loop[i].playerid) { return loop[i]; }
            if (!idle && loop[i].playerid) { idle = loop[i]; }
        }
        return idle;
    }

    // A COMMAND MUST NOT BE UNDONE BY THE NEXT POLL. The server takes a moment
    // to apply a volume change, so a reply that is already in flight still
    // carries the OLD level - written back into the slider, that reads as the
    // control snapping back. Ignore the server's volume briefly after we set
    // it, and for as long as the user is actually holding the thumb.
    var volHold = 0;
    var dragging = false;

    function bindDrag() {
        var v = el.vol;
        ['pointerdown', 'touchstart', 'mousedown'].forEach(function (e) {
            v.addEventListener(e, function () { dragging = true; });
        });
        ['pointerup', 'touchend', 'mouseup', 'blur'].forEach(function (e) {
            v.addEventListener(e, function () { dragging = false; });
        });
    }

    function update(b) {
        if (!b) { npEl.className = 'hidden'; CUR = null; return; }

        if (!el) { build(); bindDrag(); }
        npEl.className = '';
        CUR = b;

        var playing = b.np_state === 'playing';
        icon(el.ipp, playing ? 'pause_circle_filled' : 'play_circle_filled');
        el.pp.title = playing ? L.pause : L.play;

        // VOLUME. `volctl` is LMS's own use_volume_control - 0 means the user
        // set this player to fixed volume in its audio settings, and every
        // other skin hides its slider on exactly that flag.
        if (b.np_volctl === 0 || b.np_volume === undefined) {
            el.volbox.className = 'np-vol off';
        } else {
            el.volbox.className = 'np-vol';

            // The muted state is shown by the mute button lighting up and the
            // level dimming - NOT by the step buttons changing glyph. See the
            // note in build().
            el.mute.className = b.np_muted ? 'tbtn vol on' : 'tbtn vol';
            el.volv.className = b.np_muted ? 'np-volv dimmed' : 'np-volv';
            el.mute.title = el.volv.title = b.np_muted ? L.unmute : L.mute;
            if (!dragging && Date.now() > volHold && document.activeElement !== el.vol) {
                el.vol.value = b.np_volume;
                el.volv.textContent = b.np_volume;
            }
        }

        if (!b.np_title) { el.card.className = 'card np idle'; return; }
        el.card.className = 'card np';

        // The artwork url changes on a track change and rewriting the same src
        // makes it flicker, so it is only assigned when it differs.
        if (b.np_artwork) {
            if (el.art.getAttribute('src') !== b.np_artwork) {
                el.art.setAttribute('src', b.np_artwork);
            }
            el.art.style.display = '';
        } else {
            el.art.removeAttribute('src');
            el.art.style.display = 'none';
        }

        var sub = [ b.np_artist, b.np_album ].filter(function (x) { return x; })
                    .join(' ' + EM_DASH + ' ');
        el.title.textContent = b.np_title;
        el.sub.textContent   = sub;

        var pos = b.np_position || 0, dur = b.np_duration || 0;
        var pct = dur > 0 ? Math.max(0, Math.min(100, (pos / dur) * 100)) : 0;
        el.bar.style.width = pct.toFixed(1) + '%';
        el.time.textContent = dur > 0 ? clock(pos) + ' / ' + clock(dur) : '';
    }

    // A control command is an ordinary jsonrpc request addressed to the bridge
    // PLAYER - the same call any skin makes. It polls straight back rather than
    // waiting up to a second for the next tick, so the button feels immediate.
    function cmd(params) {
        if (!CUR || !CUR.playerid) { return; }
        if (params[0] === 'mixer' && params[1] === 'volume') { volHold = Date.now() + 1200; }

        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/jsonrpc.js', true);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.timeout = 5000;
        // Bring the next poll FORWARD rather than adding one, so a button
        // press cannot stack a request on top of one already in flight.
        xhr.onload    = function () { schedule(0); };
        xhr.onerror   = function () { stampNow(false, 'command failed'); };
        xhr.ontimeout = function () { stampNow(false, 'command timed out'); };
        xhr.send(JSON.stringify({
            id: 1, method: 'slim.request', params: [ CUR.playerid, params ]
        }));
    }

    // The server sends finished display strings. This only ever escapes and
    // places them - it never parses a formatted value apart, which would break
    // the moment the strings are translated.
    // ONLY WRITTEN WHEN IT DIFFERS. This runs once a second, and an innerHTML
    // rewrite drops any text selection inside the card - so a user trying to
    // copy a filter name could never finish. While a track is playing the
    // processing speed really does change every second and it rewrites anyway;
    // stopped, paused, or waiting for a player, the card now holds still.
    var lastCards = null;

    function render(loop) {
        var html;

        if (!loop || !loop.length) {
            html = '<div class="card"><div class="v">' + esc(L.waiting) + '</div></div>';
        } else {
            html = '';
            for (var i = 0; i < loop.length; i++) {
                var b = loop[i];
                var connected = b.connected && b.connected.indexOf('-') > 0;
                html += '<div class="card">';
                html += '<div class="name">' + esc(b.name || b.id || '') + '</div>';
                html += row(L.status,     b.connected, connected ? 'ok' : 'bad');
                html += row(L.source,     b.source);
                html += row(L.output,     b.output);
                // THREE ROWS, NOT ONE SENTENCE. These used to arrive joined into a
            // single string carrying all three facts AND their labels, which
            // gave the page nothing to align - and the test that this page
            // never re-formats a server value greps the served bytes for that
            // string's unit, so it cannot be quoted here.
            // Each is its own field now, so each gets its own row - and `row`
            // already draws nothing at all for a fact HQPlayer has not
            // reported, so a missing shaper leaves no empty label behind.
            html += row(L.filter,     b.filter);
            html += row(L.shaper,     b.shaper);
            html += row(L.processing, b.speed);
                html += row('', b.tier);
                html += '</div>';
            }
        }

        if (html !== lastCards) { lastCards = html; cards.innerHTML = html; }
    }

    // THE DOT IS THE WHOLE STATUS LINE NOW. It used to sit beside an
    // "updated HH:MM:SS" clock, which existed to prove the page was ticking
    // while the settings page's poller was being diagnosed. That question is
    // settled and the page visibly moves on its own, so the clock was just a
    // number changing in the corner. The dot still says live or failed, and a
    // failure still SAYS what went wrong - that part was never decoration.
    function stampNow(ok, msg) {
        dot.className = 'dot ' + (ok ? 'live' : 'err');
        errEl.textContent = ok ? '' : (msg || '');
    }

    // ONE REQUEST AT A TIME, AND THE PERIOD IS A GAP - NOT A CADENCE.
    //
    // This was a fixed one-second repeating timer with nothing stopping a second
    // request going out while the first was still open. (The call's name is not
    // written here: the assertion that it is gone greps the SERVED BYTES for
    // it.) A `signalpath` answer costs a
    // full `status` query per bridge, so once the server takes longer than a
    // second the polls OVERLAP, and with a 5s timeout up to five can be open at
    // once - plus one more for every button press, because a command polls
    // straight back.
    //
    // WHY THAT REACHES OUT OF THIS PAGE AND HURTS MATERIAL. A browser allows
    // about SIX concurrent connections per origin over HTTP/1.1, which is all
    // LMS speaks. Material holds one of those open permanently for its CometD
    // subscription - that long poll is how its Now Playing learns anything. And
    // the Home tile opens THIS PAGE AS AN IFRAME INSIDE MATERIAL, so it is not
    // a separate tab competing at arm's length: it is the same origin and the
    // same pool. A stack of overlapping polls can starve that subscription, and
    // the symptoms are exactly what you would expect - Now Playing stops
    // updating, commands are slow to take, and a browser refresh (new
    // connections) clears it.
    //
    // So: never more than one in flight, and the next is scheduled only once
    // the last has SETTLED. At worst this page now costs one connection.
    var pollTimer = null;
    var inFlight  = false;

    function schedule(ms) {
        if (pollTimer) { clearTimeout(pollTimer); }
        pollTimer = setTimeout(poll, ms === undefined ? PERIOD : ms);
    }

    // DELIBERATELY NEVER GIVES UP. The settings page's poller stopped itself
    // after five errors, which made a dead page and a working one look
    // identical. This one keeps trying and SAYS what went wrong - every path
    // out of a request reschedules, including both failures.
    function poll() {
        if (inFlight) { schedule(); return; }

        inFlight = true;

        function done(ok, msg) {
            inFlight = false;
            stampNow(ok, msg);
            schedule();
        }

        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/jsonrpc.js', true);
        xhr.setRequestHeader('Content-Type', 'application/json');
        xhr.timeout = 5000;
        xhr.onload = function () {
            try {
                var r = JSON.parse(xhr.responseText).result;
                if (!r) { throw new Error('no result in reply'); }

                // NO BRIDGES IS A STATE, NOT A FAILURE - and getting this wrong
                // is what made the page alarming at startup. The query omits
                // `bridges_loop` entirely when it has nothing to put in it
                // (addResultLoop is simply never called), so treating a missing
                // loop as a bad reply painted a red dot and a bad-reply string
                // naming the missing key for the whole time between the server
                // coming up and HQPlayer being discovered. The exact wording is
                // not repeated here: this comment is SERVED to the browser, and
                // the test for this bug greps the served bytes for it.
                // Nothing is wrong there: the poll answered, and the answer is
                // that the player has not turned up yet. Say exactly that.
                var loop = r.bridges_loop || [];
                update(pick(loop));
                render(loop);
                done(true);
            } catch (e) {
                done(false, 'bad reply: ' + e.message);
            }
        };
        xhr.onerror   = function () { done(false, 'request failed'); };
        xhr.ontimeout = function () { done(false, 'request timed out'); };
        xhr.send(JSON.stringify({
            id: 1, method: 'slim.request',
            params: ['', ['hqplayerbridge', 'signalpath']]
        }));
    }

    // BACK TO MATERIAL - and it must NOT exist when we are already inside it.
    //
    // The Home tile opens this page with `iframe`, so it normally arrives as a
    // Material DIALOG, which already has its own close. A "back" button there
    // would be worse than redundant: from inside the frame the only way out is
    // window.top.location, which navigates the WHOLE Material app away and
    // throws out whatever the user was doing. So when framed, hide it.
    //
    // Standalone - opened directly by URL, or from anything using `weblink`,
    // which calls window.open - the button is the only way back, and there is
    // no browser Back to use because it is a fresh window. window.close()
    // works on a window a script opened and is a silent no-op on a tab the
    // user opened themselves, so the navigation fallback is not optional.
    var back = document.getElementById('back');
    var framed = false;
    try { framed = window.top !== window.self; } catch (e) { framed = true; }

    if (framed) {
        back.parentNode.removeChild(back);
    } else {
        back.addEventListener('click', function () {
            window.close();
            setTimeout(function () { window.location.href = '/material/'; }, 80);
        });
    }

    iconCheck();
    poll();
}());
</script>

</body>
</html>
HTML
}

sub _esc {
    my $s = shift;

    return '' unless defined $s;

    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;

    return $s;
}

1;
