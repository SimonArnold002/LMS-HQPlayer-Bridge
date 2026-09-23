// Drive the live page's REAL script against a payload, with a DOM shim.
//
// The rest of t_live.pl asserts against the SERVED BYTES, which cannot see
// behaviour: a grep says a function exists, not that choosing an instance
// moves the panel to it. This runs the page, so a defect in the logic fails
// here rather than in a screenshot.
//
// It is JavaScriptCore via osascript, because there is no node on this Mac.
// t_live.pl skips this file when osascript is missing, so a Linux checkout
// still runs everything else.
//
// usage: osascript -l JavaScript t_live_page.js <rendered page.html>
// A DOM faithful enough to catch a typo'd id: getElementById answers ONLY ids
// that exist in the page's markup, or in markup the page itself has written.
var KNOWN = {}, ELS = {};
function learn(html) {
    var re = /id="([^"]+)"/g, m;
    while ((m = re.exec(String(html)))) { KNOWN[m[1]] = 1; }
}
function El(id) {
    this.id = id; this.className = ''; this._html = ''; this.textContent = '';
    this.attrs = {}; this.listeners = {}; this.style = {}; this.value = '';
    this.parentNode = null; this.children = [];
}
El.prototype = {
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = String(v); learn(v); },
    setAttribute: function (k, v) { this.attrs[k] = String(v); },
    getAttribute: function (k) { return this.attrs.hasOwnProperty(k) ? this.attrs[k] : null; },
    removeAttribute: function (k) { delete this.attrs[k]; },
    addEventListener: function (e, fn) { (this.listeners[e] = this.listeners[e] || []).push(fn); },
    removeEventListener: function () {},
    appendChild: function (c) { this.children.push(c); c.parentNode = this; return c; },
    removeChild: function (c) { return c; },
    fire: function (e, ev) { (this.listeners[e] || []).forEach(function (fn) { fn(ev || {}); }); },
    focus: function () {}, blur: function () {},
    classList: null
};
function El2(id) { El.call(this, id);
    var self = this;
    this.classList = { add: function (c) { self.className += (self.className ? ' ' : '') + c; },
                       remove: function () {}, contains: function (c) { return self.className.indexOf(c) >= 0; } };
}
El2.prototype = El.prototype;
var documentEl = new El2('html');
var document = {
    documentElement: documentEl,
    body: new El2('body'),
    fonts: { check: function () { return true; }, ready: { then: function () {} } },
    getElementById: function (id) {
        if (!KNOWN[id]) { return null; }
        return ELS[id] || (ELS[id] = new El2(id));
    },
    createElement: function (t) { return new El2('<' + t + '>'); },
    addEventListener: function () {}
};
var STORE = {};
var localStorage = {
    getItem: function (k) { return STORE.hasOwnProperty(k) ? STORE[k] : null; },
    setItem: function (k, v) { STORE[k] = String(v); },
    removeItem: function (k) { delete STORE[k]; }
};
var window = { self: {}, localStorage: localStorage, close: function () {}, location: { href: '' } };
window.top = window.self;   // framed === false
var TIMERS = [];
function setTimeout(fn, ms) { TIMERS.push({ fn: fn, ms: ms }); return TIMERS.length; }
function clearTimeout() {}
var XHRS = [];
function XMLHttpRequest() {
    this.headers = {}; this.readyState = 0; this.status = 0; this.responseText = '';
    XHRS.push(this);
}
XMLHttpRequest.prototype.open = function (m, u) { this.method = m; this.url = u; };
XMLHttpRequest.prototype.setRequestHeader = function (k, v) { this.headers[k] = v; };
XMLHttpRequest.prototype.send = function (b) { this.body = b; };
var console = { log: function () {}, error: function () {} };
// JXA has no print(); ObjC's stdout does.
ObjC.import("Foundation");
function print(x) {
    $.NSFileHandle.fileHandleWithStandardOutput.writeData(
        $.NSString.alloc.initWithUTF8String(String(x) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
}

// --- the page itself -------------------------------------------------------
var ARGS = $.NSProcessInfo.processInfo.arguments;
var PAGE_PATH = ObjC.unwrap(ARGS.objectAtIndex(ARGS.count - 1));
var PAGE = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
    PAGE_PATH, $.NSUTF8StringEncoding, null));

learn(PAGE);   // every id the served markup carries; getElementById answers no others

var BLOCKS = PAGE.match(/<script[^>]*>[\s\S]*?<\/script>/g) || [];
var SRC = '';
for (var i = 0; i < BLOCKS.length; i++) {
    var body = BLOCKS[i].replace(/^<script[^>]*>/, '').replace(/<\/script>$/, '');
    if (body.indexOf('signalpath') >= 0 && body.length > SRC.length) { SRC = body; }
}
if (!SRC) { print('  FAIL no page script found in ' + PAGE_PATH); print('0 passed, 1 failed'); }
else { (0, eval)(SRC); }
// Scenario: three instances, one playing. Drives the REAL page script.
var pass = 0, fail = 0;
function ok(c, n) { if (c) { pass++; print('  ok   ' + n); } else { fail++; print('  FAIL ' + n); } }

function bridge(id, name, playing, title) {
    return { id: id, name: name, playerid: 'pid:' + id, connected: 'Connected - 10.0.0.' + id + ':4321',
             source: '44100 Hz / 16 bit FLAC', output: '11289600 Hz / 1 bit SDM (DSD)',
             filter: 'poly-sinc-gauss-long', shaper: 'ASDM7EC-fast', speed: '3.3x realtime',
             np_title: title || undefined, np_artist: 'An Artist', np_album: 'An Album',
             np_state: playing ? 'playing' : 'stopped', np_volume: 61, np_volctl: 1,
             np_position: 10, np_duration: 200 };
}
var LOOP3 = [ bridge(1, 'Lounge', false), bridge(2, 'ManCave', true, 'A Song'), bridge(3, 'Study', false) ];

function answer(loop) {
    var x = null;
    for (var i = XHRS.length - 1; i >= 0; i--) { if (XHRS[i].url === '/jsonrpc.js') { x = XHRS[i]; break; } }
    if (!x) { ok(false, 'a signalpath poll went out'); return; }
    x.responseText = JSON.stringify({ result: { bridges_loop: loop } });
    x.onload();
}
function pickEl()  { return document.getElementById('pick'); }
function chips()   { return (pickEl().innerHTML.match(/data-id="[^"]*"/g) || []); }
function titleTxt(){ var t = document.getElementById('np-title'); return t ? t.textContent : '(none)'; }
function cardsHtml(){ return document.getElementById('cards').innerHTML; }
// WHICH instance the panel is driving, read the way a user sees it: the card
// marked as selected. The idle panel HIDES its title in CSS rather than
// clearing the text, so the title element is not the place to ask.
function selName() {
    var m = cardsHtml().match(/<div class="card sel"><div class="name">([^<]*)</);
    return m ? m[1] : '(none)';
}
function idle() { var c = document.getElementById('npcard'); return c && /idle/.test(c.className); }

// A page WITHOUT the chooser throws in here rather than answering: report
// that as a failure with its message, so the run still prints a tally and
// t_live.pl sees a failure instead of a crash with no numbers.
try {
print('== three instances: the chooser appears, Auto follows the playing one');
answer(LOOP3);
ok(pickEl().className.indexOf('hidden') < 0, 'the chooser is shown');
ok(chips().length === 4, 'Auto plus one chip per instance (' + chips().length + ')');
ok(titleTxt() === 'A Song', 'the panel shows the playing instance (' + titleTxt() + ')');
ok(/class="card sel"/.test(cardsHtml()), 'and that instance\'s card is marked');

print('== choosing another instance switches the panel at once');
pickEl().fire('click', { target: { className: 'chip', getAttribute: function () { return 'pid:3'; },
                                   parentNode: pickEl() } });
ok(STORE['hqplive::player'] === 'pid:3', 'the choice is remembered (' + STORE['hqplive::player'] + ')');
ok(selName() === 'Study' && idle(), 'the panel moved to the chosen instance (' + selName() + ', idle=' + idle() + ')');
var sel = pickEl().innerHTML.match(/class="chip on" data-id="([^"]*)"/);
ok(sel && sel[1] === 'pid:3', 'its chip is the selected one');
ok(/<span class="pdot">/.test(pickEl().innerHTML), 'the playing instance still shows a playing dot');

print('== the choice survives the next poll');
answer(LOOP3);
ok(selName() === 'Study', 'still on the chosen instance, not the playing one (' + selName() + ')');

print('== a chosen instance that goes away falls back, and comes back');
answer([ LOOP3[0], LOOP3[1] ]);
ok(selName() === 'ManCave' && titleTxt() === 'A Song', 'falls back to the playing one (' + selName() + ')');
answer(LOOP3);
ok(selName() === 'Study', 'and is selected again when it returns (' + selName() + ')');

print('== back to Auto');
pickEl().fire('click', { target: { className: 'chip', getAttribute: function () { return ''; },
                                   parentNode: pickEl() } });
ok(!STORE.hasOwnProperty('hqplive::player'), 'the remembered choice is cleared');
ok(titleTxt() === 'A Song', 'and the panel follows the playing instance again');

print('== one instance: no chooser at all');
answer([ bridge(2, 'ManCave', true, 'A Song') ]);
ok(pickEl().className.indexOf('hidden') >= 0, 'the chooser is hidden');
ok(pickEl().innerHTML === '', 'and empty');

} catch (e) { ok(false, 'the page threw: ' + (e && e.message)); }

print(pass + ' passed, ' + fail + ' failed');
