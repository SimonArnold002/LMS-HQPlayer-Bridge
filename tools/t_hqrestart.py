"""The restart helper must never stop an HQPlayer it cannot start again.
Fakes /proc, the platform and the process calls; stops and starts nothing real.
usage: python3 tools/t_hqrestart.py [path to hqrestart.py]"""
import builtins, importlib.util, io, json, os, sys, tempfile

_here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('hq', sys.argv[1] if len(sys.argv) > 1 else os.path.join(_here, 'hqrestart', 'hqrestart.py')); hq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hq)
P = F = 0
def ok(c, name):
    """c may be a callable, so a missing attribute or a raise inside the check
    FAILS here instead of killing the run - which is what an older build under
    test does, and a suite that dies reports nothing at all."""
    global P, F
    if callable(c):
        try:
            c = c()
        except Exception as e:
            c = False
            name = '%s [%s: %s]' % (name, type(e).__name__, e)
    if c: P += 1; print('  ok  ', name)
    else: F += 1; print('  FAIL', name)

tmp = tempfile.mkdtemp()
BIN = os.path.join(tmp, 'opt', 'hqplayer'); os.makedirs(BIN)
EXE = os.path.join(BIN, 'hqplayerd')
open(EXE, 'w').write('#!/bin/sh\n'); os.chmod(EXE, 0o755)

# ---- fake /proc for one pid (Linux)
PROC = {}
real_open, real_readlink = builtins.open, os.readlink
def f_open(p, *a, **k):
    if isinstance(p, str) and p.startswith('/proc/'):
        v = PROC.get(p)
        if isinstance(v, Exception): raise v
        if v is None: raise FileNotFoundError(p)
        return io.BytesIO(v) if 'b' in (a[0] if a else k.get('mode', 'r')) else io.StringIO(v.decode())
    return real_open(p, *a, **k)
def f_readlink(p):
    if p.startswith('/proc/'):
        v = PROC.get(p)
        if isinstance(v, Exception): raise v
        if v is None: raise FileNotFoundError(p)
        return v
    return real_readlink(p)
hq.open = f_open             # module-level name lookup for open()
os.readlink = f_readlink

calls = []
ORIG_DETECT, ORIG_RESTART_SERVICE = hq.detect, hq.restart_service
def setup(platform, proc=None, state=None, pinned=None):
    # some cases below replace these; a leaked patch would silently answer the
    # NEXT case and its assertions would be measuring nothing
    hq.detect, hq.restart_service = ORIG_DETECT, ORIG_RESTART_SERVICE
    global PROC
    PROC = proc or {}
    calls.clear()
    hq.PLATFORM = platform
    d = tempfile.mkdtemp()
    cfgp = os.path.join(d, 'hqrestart.json')
    json.dump({'token': 't', 'start_command': pinned, 'respawn_wait': 0, 'start_timeout': 0.5}, real_open(cfgp, 'w'))
    cfg = hq.Config(cfgp)
    if state is not None:
        json.dump(state, real_open(cfg.state_path, 'w'))
    alive_pids = {100}
    hq.find_pid = lambda names: min(alive_pids) if alive_pids else None
    def stop(pid, c, b): calls.append(('stop', pid)); alive_pids.discard(pid)
    def popen(argv, **kw): calls.append(('start', list(argv), kw.get('cwd'))); alive_pids.add(200)
    hq.stop_app = stop
    hq.own_unit = lambda: None
    hq.subprocess.Popen = popen
    return cfg

def linux_proc(argv0, cwd, exe=EXE, args=('--x',)):
    return {'/proc/100/cmdline': b'\0'.join([argv0.encode()] + [a.encode() for a in args]) + b'\0',
            '/proc/100/cwd': cwd, '/proc/100/exe': exe,
            '/proc/100/environ': PermissionError('environ'), '/proc/100/cgroup': b'0::/user.slice/user-1000.slice/session-2.scope\n'}

def run(cfg):
    try: return hq.restart(cfg), None
    except Exception as e: return None, str(e)

DENY = PermissionError('ptrace')

print('== detect_linux keeps the command line when the cwd link is denied')
cfg = setup('linux', linux_proc(EXE, DENY, exe=DENY))
how = hq.detect_linux(100, cfg)
ok(how['argv'] == [EXE, '--x'], 'argv survives a denied cwd (%r)' % how['argv'])
ok(how['cwd'] is None, 'cwd is None')

print('== absolute argv, cwd denied: restarts normally')
cfg = setup('linux', linux_proc(EXE, DENY, exe=DENY))
r, e = run(cfg)
ok(e is None and r and r['new_pid'] == 200, 'restart succeeds (%s)' % e)
ok(calls[:2] == [('stop', 100), ('start', [EXE, '--x'], None)], 'stopped then started with the same argv')

print('== relative argv, cwd denied, nothing saved: LEFT RUNNING')
cfg = setup('linux', linux_proc('./hqplayerd', DENY, exe=DENY))
r, e = run(cfg)
ok(e and 'left running' in e, 'refused: %s' % e)
ok(not any(c[0] == 'stop' for c in calls), 'nothing was stopped')
ok(cfg.load_state() == {}, 'no recipe saved')

print('== relative argv, cwd readable: resolved against it')
cfg = setup('linux', linux_proc('./hqplayerd', BIN, exe=DENY))
r, e = run(cfg)
ok(e is None, 'restart succeeds (%s)' % e)
ok(('start', [EXE, '--x'], BIN) in calls, 'started as %s in %s' % (EXE, BIN))

GOOD = {'mode': 'app', 'os': 'linux', 'argv': [EXE, '--saved'], 'cwd': BIN, 'env': {}}
print('== relative argv, cwd denied, a GOOD recipe saved: uses it, keeps it')
cfg = setup('linux', linux_proc('./hqplayerd', DENY, exe=DENY), state=GOOD)
r, e = run(cfg)
ok(e is None, 'restart succeeds (%s)' % e)
ok(('start', [EXE, '--saved'], BIN) in calls, 'started with the saved argv')
ok(cfg.load_state().get('argv') == [EXE, '--saved'], 'saved recipe NOT overwritten')

print('== bare name off PATH, /proc exe readable: started by exe path')
cfg = setup('linux', linux_proc('hqplayerd-not-on-path', DENY, exe=EXE))
r, e = run(cfg)
ok(e is None, 'restart succeeds (%s)' % e)
ok(('start', [EXE, '--x'], None) in calls, 'argv[0] replaced by /proc exe')

print('== bare name off PATH, exe denied: LEFT RUNNING')
cfg = setup('linux', linux_proc('hqplayerd-not-on-path', DENY, exe=DENY))
r, e = run(cfg)
ok(e and 'left running' in e and not any(c[0] == 'stop' for c in calls), 'refused, nothing stopped (%s)' % e)

print('== binary deleted since launch (upgrade): LEFT RUNNING')
cfg = setup('linux', linux_proc('/usr/lib/gone/hqplayerd', '/', exe='/usr/lib/gone/hqplayerd (deleted)'))
r, e = run(cfg)
ok(e and not any(c[0] == 'stop' for c in calls), 'refused, nothing stopped (%s)' % e)

print('== pinned start_command wins, and is checked too')
cfg = setup('linux', linux_proc('./x', DENY, exe=DENY), pinned=[EXE, '--pinned'])
r, e = run(cfg)
ok(e is None and ('start', [EXE, '--pinned'], None) in calls, 'pinned command used (%s)' % e)
cfg = setup('linux', linux_proc(EXE, '/', exe=EXE), pinned=['/nope/hqplayerd'])
r, e = run(cfg)
ok(e and not any(c[0] == 'stop' for c in calls), 'a pinned command that does not exist: nothing stopped')

print('== service mode is untouched by the check')
cfg = setup('linux', dict(linux_proc('./x', DENY, exe=DENY), **{'/proc/100/cgroup': b'0::/system.slice/hqplayerd.service\n'}))
hq.restart_service = lambda how, b: calls.append(('service', how['target']))
r, e = run(cfg)
ok(('service', 'hqplayerd.service') in calls, 'service restarted (%s)' % e)

print('== Windows: exe path unreadable (elevated process): LEFT RUNNING')
cfg = setup('win32')
hq.detect = lambda pid, c: {'mode': 'app', 'os': 'win32', 'exe': None}
r, e = run(cfg)
ok(e and not any(c[0] == 'stop' for c in calls), 'refused, nothing stopped (%s)' % e)

print('== macOS: bundle and exe both gone: LEFT RUNNING')
cfg = setup('darwin')
hq.detect = lambda pid, c: {'mode': 'app', 'os': 'darwin', 'exe': '/Applications/gone.app/Contents/MacOS/x', 'bundle': '/Applications/gone.app'}
r, e = run(cfg)
ok(e and not any(c[0] == 'stop' for c in calls), 'refused, nothing stopped (%s)' % e)

print('== a recorded cwd that has gone is dropped, not handed to the launch')
GONE_CWD = os.path.join(tmp, 'gone')
cfg = setup('linux', linux_proc(EXE, GONE_CWD, exe=DENY))
r, e = run(cfg)
ok(e is None, 'restart succeeds (%s)' % e)
started = [c for c in calls if c[0] == 'start']
ok(started and started[0][2] is None, 'started with no cwd rather than a dead one (%r)' % (started and started[0][2]))
# CONTROL: a cwd that EXISTS is still used.
cfg = setup('linux', linux_proc(EXE, BIN, exe=DENY))
r, e = run(cfg)
ok(('start', [EXE, '--x'], BIN) in calls, 'a real cwd is still passed')

print('== relative argv whose cwd has gone: LEFT RUNNING')
cfg = setup('linux', linux_proc('./hqplayerd', GONE_CWD, exe=DENY))
r, e = run(cfg)
ok(e and 'left running' in e and not any(c[0] == 'stop' for c in calls), 'refused, nothing stopped (%s)' % e)

import json as _json

print('== a list key written as a bare string is read as ONE entry')
d = tempfile.mkdtemp(); cfgp = os.path.join(d, 'hqrestart.json')
_json.dump({'token': 't', 'allow': '192.168.1.234', 'hostnames': 'hq.local',
            'start_command': '%s --flag' % EXE}, real_open(cfgp, 'w'))
c2 = hq.Config(cfgp)
ok(c2['allow'] == ['192.168.1.234'], 'allow is a list (%r)' % (c2['allow'],))
# `addr in "192.168.1.234"` is TRUE for 192.168.1.23 - the whole point.
ok('192.168.1.23' not in c2['allow'], 'a shorter address that is a SUBSTRING is not allowed')
ok('192.168.1.234' in c2['allow'], 'the address itself still is')
ok(c2['hostnames'] == ['hq.local'], 'hostnames too')
ok(c2['start_command'] == [EXE, '--flag'], 'a string start_command is split, not read character by character (%r)' % (c2['start_command'],))
# CONTROL: a proper list is untouched.
_json.dump({'token': 't', 'allow': ['10.0.0.1', '10.0.0.2']}, real_open(cfgp, 'w'))
ok(hq.Config(cfgp)['allow'] == ['10.0.0.1', '10.0.0.2'], 'a list is left alone')

print('== a bind that fails is reported once, and blames the right thing')
# Driven through server_for rather than a real port: whether binding `::` clashes
# with a socket held on 127.0.0.1 differs by platform, and a test that sometimes
# BINDS would hang in serve_forever instead of failing.
import errno as _errno, io as _io
def bind_test(err, second=None):
    """(exit code, what was logged) for a server_for that raises `err`."""
    tries = []
    def fake(listen, port):
        tries.append(listen)
        e = second if (len(tries) > 1 and second is not None) else err
        if e is None:
            class S:
                socket = None
                def serve_forever(self): raise SystemExit('served')
            return S()
        raise e
    d4 = tempfile.mkdtemp(); c4 = os.path.join(d4, 'hqrestart.json')
    _json.dump({'token': 't', 'port': 8090}, real_open(c4, 'w'))     # listen: the `::` default
    real_server_for, hq.server_for = hq.server_for, fake
    argv, sys.argv = sys.argv[:], ['hqrestart.py', c4]
    err_out, sys.stderr = sys.stderr, _io.StringIO()
    code = 'no exit'
    try:
        hq.main()
    except SystemExit as e:
        code = e.code
    except Exception as e:
        code = '%s: %s' % (type(e).__name__, e)
    finally:
        said, sys.stderr = sys.stderr.getvalue(), err_out
        sys.argv = argv; hq.server_for = real_server_for
    return code, said, tries

code, said, tries = bind_test(OSError(_errno.EADDRINUSE, 'Address already in use'))
ok(code == 2, 'a port already in use stops the helper (exit %r)' % (code,))
ok('already in use' in said and 'no IPv6' not in said,
   'and blames the port, not IPv6 - which would send the reader the wrong way')
ok(tries == ['::'], 'it does not retry the same busy port on 0.0.0.0 (%r)' % (tries,))

# IPv6 switched off: `::` is unbindable, and falling back is the whole point.
code, said, tries = bind_test(OSError(_errno.EAFNOSUPPORT, 'Address family not supported'), second=None)
ok(tries == ['::', '0.0.0.0'], 'no IPv6 here falls back to 0.0.0.0 (%r)' % (tries,))
ok('no IPv6' in said and 'listening on 0.0.0.0' in said, 'and says so once')

print('== HQPlayer running as ANOTHER user: LEFT RUNNING, and the message says why')
# kill(pid, 0) asks without sending anything; os.kill is shared, so it is restored.
real_kill = os.kill
def denied(pid, sig):
    raise PermissionError(1, 'Operation not permitted')
cfg = setup('linux', linux_proc(EXE, BIN, exe=EXE))
try:
    os.kill = denied
    ok(lambda: hq.may_signal(100) is False, 'may_signal says no when the signal is refused')
    try:
        r, e = run(cfg)
    except Exception as ex:
        r, e = None, '%s: %s' % (type(ex).__name__, ex)
finally:
    os.kill = real_kill
ok(e and 'another user' in e and 'left running' in e, 'the error names the cause (%s)' % e)
ok(not any(c[0] == 'stop' for c in calls), 'nothing was stopped')
# CONTROL: the same case when the signal IS allowed still restarts.
cfg = setup('linux', linux_proc(EXE, BIN, exe=EXE))
r, e = run(cfg)
ok(e is None and any(c[0] == 'stop' for c in calls), 'a process we may signal still restarts (%s)' % e)

print('== a config key of the WRONG SHAPE is corrected, not carried into the code')
def conf(**kw):
    d = tempfile.mkdtemp(); f = os.path.join(d, 'hqrestart.json')
    _json.dump(dict({'token': 't'}, **kw), real_open(f, 'w'))
    return hq.Config(f)

# `addr in None` raises inside the handler; `min("20", 5.0)` raises INSIDE the
# stop, i.e. after the SIGTERM - HQPlayer stopped and then left down.
c3 = conf(allow=None, hostnames=123, stop_timeout='20', total_timeout=0, port='8090')
ok(c3['allow'] == [] and c3['hostnames'] == [], 'a non-list allow/hostnames becomes an empty list, not a crash')
ok(c3['stop_timeout'] == 20.0, 'a numeric string timeout is a number (%r)' % (c3['stop_timeout'],))
ok(c3['total_timeout'] == 90, 'a nonsense timeout falls back to the default (%r)' % (c3['total_timeout'],))
ok(c3['port'] == 8090 and isinstance(c3['port'], int), 'port is an int (%r)' % (c3['port'],))
ok('1.2.3.4' not in c3['allow'], 'and nothing is trusted by an empty allow')
c4 = conf(allow=[' 192.168.1.234 ', ''], process_names=None, start_command={'x': 1})
ok(c4['allow'] == ['192.168.1.234'], 'entries are stripped and blanks dropped (%r)' % (c4['allow'],))
ok(c4.names() == hq.DEFAULT_NAMES.get(hq.PLATFORM, ['hqplayerd']), 'process_names null still means the defaults')
ok(c4['start_command'] is None, 'a start_command that is not a list is ignored')
c6 = conf(mode='Service', token=12345, listen=0)
ok(c6['mode'] == 'service', 'a capitalised mode is understood, not read as app (%r)' % (c6['mode'],))
ok(conf(mode='servce')['mode'] == 'auto', 'a typo falls back to auto rather than silently meaning app')
# `cfg['token'].encode()` raises on a number, so every tokened request 500s.
ok(c6['token'] == '12345' and c6['listen'] == '0', 'token and listen are text (%r, %r)' % (c6['token'], c6['listen']))

# A trailing comma used to raise a traceback and leave the service manager
# restarting the helper for ever, with the file's own name nowhere in sight.
bad = os.path.join(tempfile.mkdtemp(), 'hqrestart.json')
real_open(bad, 'w').write('{ "token": "abc", }')
try:
    hq.Config(bad); ok(False, 'a broken config stops the helper')
except SystemExit as e:
    ok(e.code == 2, 'a broken config stops the helper with a plain message, not a traceback')
except Exception as e:
    ok(False, 'a broken config raised %s instead' % type(e).__name__)
ok(real_open(bad).read() == '{ "token": "abc", }', 'and the file is NOT rewritten over the user\'s edits')
ok(conf(start_command=[EXE, 7])['start_command'] == [EXE, '7'], 'start_command elements are text - a number raises on the way to Popen')

# CONTROL: sane values are untouched.
c5 = conf(allow=['10.0.0.1'], stop_timeout=5, port=9099)
ok(c5['allow'] == ['10.0.0.1'] and c5['stop_timeout'] == 5 and c5['port'] == 9099, 'sane values are left alone')

print('== the endpoint itself, over a REAL socket (v4 and v6 on one dual-stack helper)')
# Nothing above this point opens a socket, so a handler that had stopped being a
# handler - do_POST lost to a bad edit, say - passed every test and answered 501.
import threading, urllib.request, urllib.error
d3 = tempfile.mkdtemp(); c3 = os.path.join(d3, 'hqrestart.json')
_json.dump({'token': 'tok', 'listen': '::', 'port': 0, 'allow': ['127.0.0.1']}, real_open(c3, 'w'))
hq.PLATFORM = sys.platform
scfg = hq.Config(c3)
hq.Handler.cfg = scfg
hq.find_pid = lambda names: None            # nothing to restart: /restart answers, /ping is the point
srv = hq.server_for('::', 0)
port = srv.socket.getsockname()[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

def call(url, method='GET', headers=None, data=None):
    req = urllib.request.Request(url, method=method, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

try:
    code, body = call('http://127.0.0.1:%d/ping' % port)
    ok(code == 200 and 'hqrestart' in body, '/ping over IPv4 answers (%s)' % code)
    code, _ = call('http://[::1]:%d/ping' % port)
    ok(code == 200, '/ping over IPv6 answers on the same helper (%s)' % code)
    # the v4 client arrives as ::ffff:127.0.0.1; `allow` names it the ordinary way
    code, body = call('http://127.0.0.1:%d/restart' % port, 'POST',
                      {'Content-Type': 'application/json'}, b'{}')
    ok(code != 401, 'a v4 client in `allow` is trusted through the mapped form (%s)' % code)
    ok(code != 501, 'and POST is still a method this handler knows (%s)' % code)
    # CONTROL: an address NOT in allow gets nothing without the token
    code, _ = call('http://[::1]:%d/restart' % port, 'POST',
                   {'Content-Type': 'application/json'}, b'{}')
    ok(code == 401, 'an address outside `allow` is refused (%s)' % code)
    code, _ = call('http://[::1]:%d/status' % port, 'GET', {'Authorization': 'Bearer tok'})
    ok(code == 200, 'and the token works over IPv6 (%s)' % code)
    code, _ = call('http://127.0.0.1:%d/status' % port, 'GET', {'Authorization': 'Bearer wrong'})
    ok(code == 401, 'a wrong token is refused (%s)' % code)
finally:
    srv.shutdown(); srv.server_close()

print('\n%d passed, %d failed' % (P, F))
sys.exit(1 if F else 0)
