// Drive the settings page's REAL "checking" script with a DOM shim.
//
// t_settings.pl asserts the template's markup; this RUNS its script, so a
// defect in when the line appears fails here rather than on the rig. Same
// harness shape as t_live_page.js: JavaScriptCore via osascript, because there
// is no node on this Mac, and t_settings.pl skips it out loud without one.
//
// usage: osascript -l JavaScript t_settings_page.js <settings/basic.html>
ObjC.import("Foundation");
function print(x) {
    $.NSFileHandle.fileHandleWithStandardOutput.writeData(
        $.NSString.alloc.initWithUTF8String(String(x) + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
}
var ARGS = $.NSProcessInfo.processInfo.arguments;
var PATH = ObjC.unwrap(ARGS.objectAtIndex(ARGS.count - 1));
var TMPL = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(PATH, $.NSUTF8StringEncoding, null));

var SRC = '';
(TMPL.match(/<script[^>]*>[\s\S]*?<\/script>/g) || []).forEach(function (b) {
    if (b.indexOf('hqp_checking') >= 0) { SRC = b.replace(/^<script[^>]*>/, '').replace(/<\/script>$/, ''); }
});

var pass = 0, fail = 0;
function ok(c, n) { if (c) { pass++; print('  ok   ' + n); } else { fail++; print('  FAIL ' + n); } }

var TEXT = 'Checking that HQPlayer answers at %s - this can take a few seconds.';

// One page load: the saved list, the radio chosen, the box as typed. Returns
// the note and a way to fire each of the two ways a save starts.
function page(saved, mode, typed, disabled, held) {
    var listeners = { submit: [], beforeunload: [] };
    var note = {
        textContent: '', style: { display: 'none' },
        getAttribute: function (k) {
            return k === 'data-text' ? TEXT : k === 'data-saved' ? saved : k === 'data-held' ? (held || '') : null;
        }
    };
    var form = { addEventListener: function (e, fn) { listeners[e].push(fn); } };
    var box  = { value: typed, disabled: !!disabled, form: form };
    var radios = [ { value: '1', checked: mode === 1 }, { value: '0', checked: mode === 0 } ];
    var names = { pref_addresses: [box], pref_autodiscover: radios };
    document = {
        getElementsByName: function (n) { return names[n] || []; },
        getElementById: function (id) { return id === 'hqp_checking' ? note : null; }
    };
    window = { addEventListener: function (e, fn) { listeners[e].push(fn); } };
    (0, eval)(SRC);
    return {
        note: note, box: box, radios: radios,
        submit: function () { listeners.submit.forEach(function (f) { f(); }); },
        unload: function () { listeners.beforeunload.forEach(function (f) { f(); }); }
    };
}
var document, window;
function shown(p) { return p.note.style.display !== 'none'; }

try {
    ok(SRC.length > 0, 'the template carries the checking script');

    print('== a save that ADDS an address says it is checking, naming only the new one');
    var p = page('10.0.0.1', 0, '10.0.0.1, 10.0.0.2');
    ok(!shown(p), 'nothing is shown before Save');
    p.submit();
    ok(shown(p), 'Save pressed: the line appears at once');
    ok(p.note.textContent === 'Checking that HQPlayer answers at 10.0.0.2 - this can take a few seconds.',
       'naming the NEW address only (' + p.note.textContent + ')');

    print('== the other way a save starts: Material\'s save-on-close calls form.submit(), no submit event');
    p = page('', 0, '192.168.1.107');
    p.unload();
    ok(shown(p) && p.note.textContent.indexOf('192.168.1.107') >= 0, 'beforeunload shows it too');

    print('== nothing to check, nothing shown - these saves are instant');
    p = page('10.0.0.1, 10.0.0.2', 0, '10.0.0.1');
    p.submit();
    ok(!shown(p), 'an address REMOVED, none added');
    p = page('10.0.0.1', 0, '10.0.0.1');
    p.submit();
    ok(!shown(p), 'the box unchanged');
    p = page('', 0, '');
    p.submit();
    ok(!shown(p), 'addresses only with an empty box');
    p = page('', 1, '10.0.0.9', true);
    p.submit();
    ok(!shown(p), 'Automatically selected (the box greyed, and cleared by the save)');
    p = page('', 0, '10.0.0.9');
    p.radios[1].checked = false; p.radios[0].checked = true;   // switched to Automatically before saving
    p.submit();
    ok(!shown(p), 'switched to Automatically on the page before saving');

    print('== what is compared is the SAVED list, not what the box held when the page opened');
    // A refused page redraws the TYPED box: the dead address is in it but was
    // never saved, so saving again re-checks it - and must say so.
    p = page('', 0, '192.168.1.230');
    p.submit();
    ok(shown(p) && p.note.textContent.indexOf('192.168.1.230') >= 0,
       'after a refusal, saving the same address again still says it is checking');

    // THE SAME RULE AS THE SAVE (review finding 6, 2026-09-28): the line names
    // exactly the addresses handler() will ask, and appears only when it asks.
    print('== the save\'s own rule: normalised, de-duplicated, one bad entry refuses it all');
    p = page('192.168.1.10', 0, '192.168.001.010');
    p.submit();
    ok(!shown(p), 'a saved address typed with leading zeros is the SAME address - nothing is checked');
    p = page('', 0, '192.168.001.020');
    p.submit();
    ok(shown(p) && p.note.textContent.indexOf('192.168.1.20 ') >= 0,
       'a new one is named as the save reads it, decimal (' + p.note.textContent + ')');
    p = page('', 0, '10.0.0.2 10.0.0.2, 10.0.0.2');
    p.submit();
    ok(p.note.textContent === 'Checking that HQPlayer answers at 10.0.0.2 - this can take a few seconds.',
       'named once, however often it is typed (' + p.note.textContent + ')');
    p = page('', 0, 'nuc.local');
    p.submit();
    ok(!shown(p), 'a host name: the save refuses it at once, so no line');
    p = page('', 0, '10.0.0.5, nuc.local');
    p.submit();
    ok(!shown(p), 'one bad entry beside a good one: the whole save is refused before any check - no line');
    ['300.1.1.1', '0.1.2.3', '224.0.0.1', '10.0.0'].forEach(function (bad) {
        p = page('', 0, bad);
        p.submit();
        ok(!shown(p), 'refused by the save, so no line: ' + bad);
    });

    print('== an address a CONNECTED player holds is not checked, so it is not named');
    p = page('', 0, '10.0.0.7', false, '10.0.0.7');
    p.submit();
    ok(!shown(p), 'only a held address: the save completes at once - no line');
    p = page('', 0, '10.0.0.7, 10.0.0.8', false, '10.0.0.7');
    p.submit();
    ok(p.note.textContent === 'Checking that HQPlayer answers at 10.0.0.8 - this can take a few seconds.',
       'beside a new one: only the new one is named (' + p.note.textContent + ')');
} catch (e) { ok(false, 'the script threw: ' + (e && e.message)); }

print(pass + ' passed, ' + fail + ' failed');
