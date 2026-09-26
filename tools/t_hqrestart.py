"""The restart helper must never stop an HQPlayer it cannot start again.
Fakes /proc, the platform and the process calls; stops and starts nothing real.
usage: python3 tools/t_hqrestart.py [path to hqrestart.py]"""
import builtins, importlib.util, io, json, os, sys, tempfile

_here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('hq', sys.argv[1] if len(sys.argv) > 1 else os.path.join(_here, 'hqrestart', 'hqrestart.py')); hq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hq)
# The helper logs to stderr on nearly every call. Silencing it HERE, rather
# than with 2>/dev/null in run_checks.sh, keeps a real traceback visible.
_said = []
hq.log = lambda msg: _said.append(msg)
def logged():
    """Everything the helper has logged since the last look, as one string."""
    out = '\n'.join(_said); del _said[:]; return out
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
REAL_FIND_PID = hq.find_pid
REAL_STOP_APP = hq.stop_app       # setup() stubs it and never puts it back
REAL_POPEN = hq.subprocess.Popen
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

print('== a command that FAILS must not look like output')
# run() used to return the exception text in the stdout slot, and find_pid scrapes
# bare digits out of that: "timed out after 30 seconds" IS pid 30 - a real,
# unrelated process, which a root helper would then SIGTERM.
import subprocess as _sp
real_run = hq.run
hq.PLATFORM = 'darwin'
stub_popen, hq.subprocess.Popen = hq.subprocess.Popen, REAL_POPEN   # the cases above recorded starts
try:
    hq.run = lambda argv, timeout=30: (1, '')                              # pgrep: no match
    ok(lambda: REAL_FIND_PID(['hqplayerd']) is None, 'nothing matching means no pid')
    hq.run = lambda argv, timeout=30: (127, str(_sp.TimeoutExpired(argv, 30)))
    ok(lambda: REAL_FIND_PID(['hqplayerd']) is None, 'a TIMED-OUT pgrep yields no pid, not 30')
    hq.run = lambda argv, timeout=30: (0, '  12345\n')
    ok(lambda: REAL_FIND_PID(['hqplayerd']) == 12345, 'and a real answer still yields its pid')
    # the text itself never reaches a caller
    logged()
    rc, out = real_run(['/no/such/binary/hqrestart-test'])
    ok(rc == 127 and out == '', 'run() gives EMPTY output on failure (%r)' % (out,))
    ok('failed:' in logged(), 'and puts the reason in the log instead')
finally:
    hq.run = real_run
    hq.subprocess.Popen = stub_popen

print('== a bind that fails is reported once, and blames the right thing')
# Driven through server_for rather than a real port: whether binding `::` clashes
# with a socket held on 127.0.0.1 differs by platform, and a test that sometimes
# BINDS would hang in serve_forever instead of failing.
import errno as _errno
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
    logged()                                        # start from a clean slate
    code = 'no exit'
    try:
        hq.main()
    except SystemExit as e:
        code = e.code
    except Exception as e:
        code = '%s: %s' % (type(e).__name__, e)
    finally:
        sys.argv = argv; hq.server_for = real_server_for
    return code, logged(), tries

print('== any OS but macOS and Linux is refused at start, before a config is read')
was = hq.PLATFORM
d5 = tempfile.mkdtemp(); c5 = os.path.join(d5, 'hqrestart.json')
argv, sys.argv = sys.argv[:], ['hqrestart.py', c5]
real_stderr, sys.stderr = sys.stderr, io.StringIO()
def no_bind(listen, port):                          # a build without the refusal must FAIL here,
    raise SystemExit('reached the bind')            # not serve on a real port
real_server_for, hq.server_for = hq.server_for, no_bind
try:
    hq.PLATFORM = 'win32'
    try:
        code = hq.main()
    except SystemExit as e:
        code = e.code
    except Exception as e:
        code = '%s: %s' % (type(e).__name__, e)
    said = sys.stderr.getvalue()
finally:
    sys.argv, sys.stderr, hq.PLATFORM, hq.server_for = argv, real_stderr, was, real_server_for
ok(code == 2 and 'macOS and Linux only' in said, 'Windows exits 2, saying why (%r)' % (code,))
ok(not os.path.exists(c5), 'and writes no config (no token generated)')

code, said, tries = bind_test(OSError(_errno.EADDRINUSE, 'Address already in use'))
ok(code == 2, 'a port already in use stops the helper (exit %r)' % (code,))
ok('already in use' in said and 'no IPv6' not in said,
   'and blames the port, not IPv6 - which would send the reader the wrong way')
ok(tries == ['::'], 'it does not retry the same busy port on 0.0.0.0 (%r)' % (tries,))

# IPv6 switched off: `::` is unbindable, and falling back is the whole point.
code, said, tries = bind_test(OSError(_errno.EAFNOSUPPORT, 'Address family not supported'), second=None)
ok(tries == ['::', '0.0.0.0'], 'no IPv6 here falls back to 0.0.0.0 (%r)' % (tries,))
ok('no IPv6' in said and 'listening on 0.0.0.0' in said, 'and says so once')

print('== the unit and the exit code agree about a refusal')
# The helper says why ONCE and exits 2; a unit that retries that every 3s buries
# the line under its own repeats, which is the whole point of saying it once.
_inst = real_open(os.path.join(_here, 'hqrestart', 'install.sh')).read()
ok('RestartPreventExitStatus=2' in _inst, 'the systemd unit does not retry exit 2')
import re as _re
ok(len(_re.findall(r'^Restart=always$', _inst, _re.M)) == 1, 'and still restarts a crash')
_src = real_open(os.path.join(_here, 'hqrestart', 'hqrestart.py')).read()
ok(_src.count('raise SystemExit(2)') == 2, 'both refusals use that code (config, and bind)')

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

print('== a ROOT helper against a USER\'s app: LEFT RUNNING, not restarted as root')
# kill(pid, 0) always succeeds for root, so may_signal cannot see this one.
real_geteuid = os.geteuid
def owned_by(uid):
    pr = linux_proc(EXE, BIN, exe=EXE)
    pr['/proc/100/status'] = ('Name:\thqplayerd\nUid:\t%d\t%d\t%d\t%d\n' % ((uid,) * 4)).encode()
    return pr
try:
    os.geteuid = lambda: 0
    cfg = setup('linux', owned_by(1000))
    ok(lambda: hq.may_signal(100) is True, 'may_signal alone lets root through (why same_owner exists)')
    r, e = run(cfg)
    ok(e and 'another user' in e and 'left running' in e, 'refused, and says why (%s)' % e)
    ok(not any(c[0] in ('stop', 'start') for c in calls), 'nothing stopped, nothing started as root')
    # CONTROLS: root against root's own app, and an owner that cannot be read
    cfg = setup('linux', owned_by(0))
    r, e = run(cfg)
    ok(e is None and any(c[0] == 'stop' for c in calls), 'the same owner still restarts (%s)' % e)
    cfg = setup('linux', linux_proc(EXE, BIN, exe=EXE))            # no status file
    r, e = run(cfg)
    ok(e is None and any(c[0] == 'stop' for c in calls), 'an unreadable owner is not a refusal (%s)' % e)
    os.geteuid = lambda: 1000                                        # a per-user helper, its own app
    cfg = setup('linux', owned_by(1000))
    r, e = run(cfg)
    ok(e is None and any(c[0] == 'stop' for c in calls), 'a user helper and its own app restart (%s)' % e)
    # macOS reads the owner from ps
    real_run = hq.run
    hq.PLATFORM = 'darwin'
    os.geteuid = lambda: 0
    hq.run = lambda argv, timeout=30: (0, '  501\n') if argv[:3] == ['ps', '-o', 'uid='] else (1, '')
    ok(lambda: hq.same_owner(100) is False, 'macOS: a root helper and uid 501 are not the same owner')
    hq.run = lambda argv, timeout=30: (1, '')
    ok(lambda: hq.same_owner(100) is True, 'macOS: ps failing is not a refusal')
finally:
    os.geteuid = real_geteuid
    hq.run = real_run

print('== HQPlayer NOT running: what is PINNED starts it, with no saved state')
def not_running(cfg):
    # nothing runs until something is started
    hq.find_pid = lambda names: 200 if any(c[0] in ('start', 'service') for c in calls) else None
    return cfg
cfg = not_running(setup('linux'))
cfg.c['service'] = 'hqplayerd.service'
hq.restart_service = lambda how, b: calls.append(('service', how['target'], how.get('user')))
r, e = run(cfg)
ok(e is None and ('service', 'hqplayerd.service', False) in calls, 'a pinned service is started (%s)' % e)
cfg = not_running(setup('linux', pinned=[EXE]))
r, e = run(cfg)
ok(e is None and any(c[0] == 'start' and c[1] == [EXE] for c in calls), 'a pinned start_command is run (%s)' % e)
cfg = not_running(setup('linux'))
r, e = run(cfg)
ok(e and 'set "service" or "start_command"' in e, 'nothing pinned or saved still says what to set (%s)' % e)
# pinned beats saved, as it does in detect()
cfg = not_running(setup('linux', state={'mode': 'app', 'os': 'linux', 'argv': [EXE, '--old']}))
cfg.c['service'] = 'hqplayerd.service'
hq.restart_service = lambda how, b: calls.append(('service', how['target'], how.get('user')))
r, e = run(cfg)
ok(e is None and any(c[0] == 'service' for c in calls) and not any(c[0] == 'start' for c in calls),
   'the pinned service wins over a saved app recipe (%s)' % e)
# CONTROL: with nothing pinned, the saved recipe is still used
cfg = not_running(setup('linux', state={'mode': 'app', 'os': 'linux', 'argv': [EXE, '--old']}))
r, e = run(cfg)
ok(e is None and any(c[0] == 'start' and c[1] == [EXE, '--old'] for c in calls), 'the saved recipe still starts it (%s)' % e)
hq.find_pid = REAL_FIND_PID

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

# The Bridge gives up at 120s (Plugin.pm), so a longer bound here is reported
# there as a failure while the restart carries on and succeeds unseen.
logged()
conf(total_timeout=300); loud = logged()
conf(total_timeout=90);  quiet = logged()
ok('gives up at 120' in loud, 'a total_timeout past the Bridge\'s wait is warned about')
ok(quiet == '', 'and the default is not (%r)' % quiet[:60])

# respawn_wait 0 is a CHOICE - "start it myself, do not wait for launchd" - and
# round 9's blanket "must be positive" quietly overrode it with the default.
c7 = conf(respawn_wait=0, port=70000, stop_timeout=0)
ok(c7['respawn_wait'] == 0, 'respawn_wait 0 is kept (%r)' % (c7['respawn_wait'],))
ok(c7['port'] == 8090, 'a port outside 1-65535 falls back (%r)' % (c7['port'],))
ok(c7['stop_timeout'] == 20, 'but a zero stop_timeout does not - it would mean give up at once (%r)'
   % (c7['stop_timeout'],))

print('== a kill that did NOT take: LEFT RUNNING, never a second copy')
real_run, real_kill, real_wait = hq.run, os.kill, getattr(hq, 'KILL_WAIT', 3)
hq.KILL_WAIT = 0.3
kcfg = conf(stop_timeout=0.3)
try:
    # POSIX: a process that outlives SIGKILL
    hq.PLATFORM = 'linux'
    os.kill = lambda pid, sig: None                 # every signal "sent", nothing dies
    try:
        REAL_STOP_APP(100, kcfg, 5); e = None
    except RuntimeError as ex:
        e = str(ex)
    ok(e and 'left running' in e, 'POSIX: a process that outlives SIGKILL is not restarted over (%s)' % e)
    # and restart() starts nothing after it
    os.kill = real_kill
    cfg = setup('linux', linux_proc(EXE, BIN, exe=EXE))
    def stuck(pid, c, b):
        calls.append(('stop', pid)); raise RuntimeError('HQPlayer (pid %d) would not stop, so it was left running' % pid)
    hq.stop_app = stuck
    r, e = run(cfg)
    ok(e and not any(c[0] == 'start' for c in calls), 'restart() starts no second copy (%s)' % e)
finally:
    hq.run, os.kill, hq.KILL_WAIT = real_run, real_kill, real_wait

print('== a PINNED unit still has its user/system kind detected')
for cg, want, label in ((b'0::/user.slice/user-1000.slice/user@1000.service/app.slice/hqplayerd.service\n', True, 'a user unit'),
                        (b'0::/system.slice/hqplayerd.service\n', False, 'a system unit')):
    pr = dict(linux_proc(EXE, BIN, exe=EXE), **{'/proc/100/cgroup': cg})
    setup('linux', pr)
    how = hq.detect_linux(100, conf(service='hqplayerd.service'))
    ok(how['mode'] == 'service' and how['user'] is want, '%s, pinned by name, is restarted as one (%r)' % (label, how.get('user')))
setup('linux', dict(linux_proc(EXE, BIN, exe=EXE), **{'/proc/100/cgroup': b'0::/user.slice/user-1000.slice/user@1000.service/app.slice/hqplayerd.service\n'}))
how = hq.detect_linux(100, conf(service='hqplayerd.service', user_service=False))
ok(how['user'] is False, 'an explicit user_service still wins over the detection')

print('== an `allow` entry that can never match says so')
logged()
conf(allow=['nuc.local', '192.168.1.234'])
_said_now = logged()
ok('not an IP address' in _said_now, 'a host name in `allow` is called out (%r)' % _said_now[-70:])
logged(); conf(allow=['192.168.1.234'])
ok('not an IP address' not in logged(), 'and an address is not')

# Round 19 put a floor of ONE second on the timeouts, and a start_timeout of 0.5
# - this suite's own setting - was swapped for the 30s default in silence. The
# only symptom was a suite 30s slower. A fraction of a second is a real value.
logged()
c8 = conf(start_timeout=0.5, stop_timeout=2.5)
ok(c8['start_timeout'] == 0.5 and c8['stop_timeout'] == 2.5, 'fractional timeouts are kept (%r, %r)'
   % (c8['start_timeout'], c8['stop_timeout']))
ok('must be' not in logged(), 'and nothing is logged as corrected')

# CONTROL: sane values are untouched.
c5 = conf(allow=['10.0.0.1'], stop_timeout=5, port=9099)
ok(c5['allow'] == ['10.0.0.1'] and c5['stop_timeout'] == 5 and c5['port'] == 9099, 'sane values are left alone')

print('== `user_service` is read for what it SAYS, not for being non-empty')
# bool("false") is True: a quoted false restarted with `systemctl --user`.
for raw, want in (('false', False), ('False', False), ('no', False), ('0', False), (0, False),
                  ('true', True), ('yes', True), (1, True), (True, True), (False, False),
                  (None, None), ('', None), ('auto', None)):
    got = conf(user_service=raw)['user_service']
    ok(got is want, 'user_service %r reads as %r (%r)' % (raw, want, got))
logged(); got = conf(user_service='maybe')['user_service']
ok(got is None and 'user_service' in logged(), 'nonsense means DETECT, and says so (%r)' % (got,))
logged(); conf(user_service='false')
ok('user_service' not in logged(), 'a word it understands is not complained about')
# and at the layer that acts on it: the unit is restarted WITHOUT --user
setup('linux', linux_proc(EXE, '/'))
how = hq.detect_linux(100, conf(service='hqplayerd.service', mode='service', user_service='false'))
ok(how['mode'] == 'service' and how['user'] is False, 'a quoted false restarts the SYSTEM unit (%r)' % (how,))

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
    logged()                                       # drain the request lines so far
    code, _ = call('http://[::1]:%d/restart' % port, 'POST',
                   {'Content-Type': 'application/json'}, b'{}')
    ok(code == 401, 'an address outside `allow` is refused (%s)' % code)

    # A 401 alone tells the one person who can fix this nothing. The refused
    # request CARRIES the address that would fix it, so the log must name it.
    said = logged()
    ok('not in "allow"' in said, 'and the log says WHY it was refused')
    ok('--allow ::1' in said, 'naming the command that would fix it')

    # CONTROL: a GET with a bad token is a bookmark typo or a scanner; it must
    # not be told to add itself to `allow`.
    logged()
    code, _ = call('http://[::1]:%d/status' % port, 'GET', {'Authorization': 'Bearer wrong'})
    ok('allow' not in logged(), 'a bad token on a GET gets no such advice (%s)' % code)

    # CONTROL: one line per address per EXPLAIN_EVERY, so a scanner cannot fill
    # the log with advice.
    logged()
    for _ in range(3):
        call('http://[::1]:%d/restart' % port, 'POST',
             {'Content-Type': 'application/json'}, b'{}')
    ok(logged().count('not in "allow"') == 0, 'and it is not repeated for the same address')

    # The advice names the installer and the flag for a service install.
    def advice(platform):
        was = hq.PLATFORM
        hq.PLATFORM = platform
        hq.Handler.SAID.clear()                    # the throttle, not the subject here
        try:
            logged()
            call('http://[::1]:%d/restart' % port, 'POST',
                 {'Content-Type': 'application/json'}, b'{}')
            return logged()
        finally:
            hq.PLATFORM = was

    ok(lambda: './install.sh --allow' in advice('linux'), 'on Linux it names install.sh')
    ok(lambda: './install.sh --allow' in advice('darwin'), 'on macOS it names install.sh')
    ok(lambda: '--system' in advice('darwin'), 'and says to add --system if HQPlayer runs as a service')

    # The throttle bounds the LOG. Nothing bounded the MAP, so one entry per
    # distinct address accumulated for ever on a host anything scans.
    def pruned():
        hq.Handler.SAID.clear()
        for i in range(50):                        # 50 addresses that have gone quiet
            hq.Handler.SAID['10.0.0.%d' % i] = 0   # epoch: far older than EXPLAIN_EVERY
        call('http://[::1]:%d/restart' % port, 'POST',
             {'Content-Type': 'application/json'}, b'{}')
        return hq.Handler.SAID

    ok(lambda: len(pruned()) == 1, 'addresses that have gone quiet are dropped from the map')
    ok(lambda: '10.0.0.0' not in hq.Handler.SAID, 'so it cannot grow without bound')
    code, _ = call('http://[::1]:%d/status' % port, 'GET', {'Authorization': 'Bearer tok'})
    ok(code == 200, 'and the token works over IPv6 (%s)' % code)
    code, _ = call('http://127.0.0.1:%d/status' % port, 'GET', {'Authorization': 'Bearer wrong'})
    ok(code == 401, 'a wrong token is refused (%s)' % code)
finally:
    srv.shutdown(); srv.server_close()

# ---------------------------------------------------------------------------
# `allow`, as the installer sets it. One validator, called by install.sh - two
# copies of this rule would drift.
# ---------------------------------------------------------------------------
print('== the installers\' --allow, which is the only way a user sets this')
CONF = os.path.join(tmp, 'allow.json')

# Every check is a CALLABLE, so a build without set_allow FAILS here rather
# than killing the run - a control run that dies reports nothing at all.
ok(lambda: hq.set_allow(CONF) == [], 'a config that does not exist yet reads as no addresses')
ok(lambda: hq.set_allow(CONF, '192.168.1.234') == ['192.168.1.234'], 'one address is written')
ok(lambda: hq.set_allow(CONF) == ['192.168.1.234'], 'and reads back')

# The token is generated on the helper's FIRST START, which is after the
# installer has written allow - so writing it must never lose the rest.
def wrote(key, want):
    json.dump({'token': 'keepme', 'port': 9999, 'allow': ['10.0.0.1']}, open(CONF, 'w'))
    hq.set_allow(CONF, '192.168.1.234, 10.0.0.5 10.0.0.5')
    return json.load(open(CONF)).get(key) == want

ok(lambda: wrote('token', 'keepme'), 'an existing token SURVIVES the write')
ok(lambda: wrote('port', 9999), 'and so does every other key')
ok(lambda: wrote('allow', ['192.168.1.234', '10.0.0.5']),
   'commas and spaces both separate, and a repeat is dropped')

# `allow` is matched against the address a request ARRIVES FROM, so a name can
# never match. Refusing it while the user is still at the prompt beats logging
# it at the next start, which is where round 20 left it.
def refuses(raw):
    try:
        hq.set_allow(CONF, raw); return False
    except ValueError:
        return True

ok(lambda: refuses('nuc.local'), 'a host name is refused, not written')
ok(lambda: refuses('192.168.1'), 'and so is a half-written address .NET would read as 192.0.0.1')
ok(lambda: refuses('192.168.1.234 nuc.local'), 'one bad entry refuses the whole list')
ok(lambda: json.load(open(CONF)).get('allow') == ['192.168.1.234', '10.0.0.5'],
   'and a refusal leaves the previous value alone')

# The token lives in this file. A config a user has broken with a stray comma
# must never be rewritten from under them.
open(CONF, 'w').write('{"token": "keepme",}')
ok(lambda: refuses('192.168.1.234'), 'a config that does not PARSE is refused')
ok(lambda: open(CONF).read() == '{"token": "keepme",}', 'and is left exactly as it was')

# ...and neither is a write that DIES HALF WAY.  Opening the real path 'w'
# truncates it first, so a torn write left exactly the unparseable config the
# check above refuses to create - with the token gone and Config.__init__
# exiting 2, so the helper would not start again.  set_allow writes a sibling
# and os.replace()s it.
json.dump({'token': 'keepme', 'port': 9999, 'allow': ['10.0.0.1']}, open(CONF, 'w'))
_realdump = hq.json.dump

def _torndump(data, f, **kw):
    f.write('{"token": "keep')                       # half a config, then the disk goes
    raise IOError('no space left on device')

def torn():
    hq.json.dump = _torndump
    try:
        try:
            hq.set_allow(CONF, '192.168.1.234')
        except (IOError, OSError):
            pass
    finally:
        hq.json.dump = _realdump
    was = json.load(open(CONF))                      # raises if it no longer parses
    return was.get('token') == 'keepme' and was.get('allow') == ['10.0.0.1']

ok(torn, 'a write that fails half way leaves the ORIGINAL config, parseable, token and all')
ok(lambda: not os.path.exists(CONF + '.new'), 'and does not leave its temp file behind')
ok(lambda: hq.set_allow(CONF, '192.168.1.234') == ['192.168.1.234'],
   'CONTROL: a write that does not fail still lands')
ok(lambda: oct(os.stat(CONF).st_mode & 0o777) == oct(0o600), 'and the config it lands is 0600 - it holds the token')

# ---------------------------------------------------------------------------
# `--allow` WITH NO CONFIG PATH.  main() matched the flag on `len(argv) > 2`,
# so a bare `--allow` fell THROUGH to serve mode with sys.argv[1] as the config
# path: it wrote a file literally named `--allow`, minted a token into it, and
# went on to bind the port.  It must refuse instead, and touch nothing.
# ---------------------------------------------------------------------------
print('== --allow with no config path is refused, and writes nothing')

def run_main(*args):
    argv, err = sys.argv[:], sys.stderr
    sys.argv = ['hqrestart.py'] + list(args)
    sys.stderr = io.StringIO()
    try:
        return hq.main(), sys.stderr.getvalue()
    finally:
        sys.argv, sys.stderr = argv, err

_here_before = set(os.listdir('.'))
# NB: not `_said` - that name is the suite's own log buffer (hq.log appends to
# it), and rebinding it to a string breaks every later test that calls logged().
_code, _usage = run_main('--allow')
ok(_code == 2, 'a bare --allow exits 2, not into serve mode (%r)' % (_code,))
ok('usage' in _usage.lower(), 'and says how to call it (%r)' % _usage.strip())
ok(not os.path.exists('--allow'), 'no config file named `--allow` is created')
ok(set(os.listdir('.')) == _here_before, 'and nothing else is left behind either')

# CONTROL: the installers' real call still works, on the same code path.
ok(run_main('--allow', CONF, '10.0.0.7')[0] == 0, 'CONTROL: --allow <config> <addr> still returns 0')
ok(lambda: hq.set_allow(CONF) == ['10.0.0.7'], 'and still writes the address')
ok(run_main('--allow', CONF)[0] == 0, 'CONTROL: --allow <config> still reads back')

# ---------------------------------------------------------------------------
# The FIRST-START token write, which is the other writer of this file and had
# its own truncating `open(path, 'w')`. install.sh now writes `allow` BEFORE
# the helper first starts, so this write is no longer writing a file that holds
# nothing worth keeping: torn, it loses the user's allow list, and the config it
# leaves exits 2 - RestartPreventExitStatus=2, so the helper never comes back.
# ---------------------------------------------------------------------------
print('== the first-start token write is atomic too, and keeps what the installer wrote')
TCONF = os.path.join(tmp, 'firststart.json')

def first_start(dump=None):
    json.dump({'port': 9999, 'allow': ['10.0.0.1']}, open(TCONF, 'w'))   # no token yet
    if dump:
        hq.json.dump = dump
    try:
        try:
            return hq.Config(TCONF)
        finally:
            hq.json.dump = _realdump
    except (IOError, OSError):
        return None

def token_torn():
    first_start(_torndump)
    was = json.load(open(TCONF))                     # raises if it no longer parses
    return 'token' not in was and was.get('allow') == ['10.0.0.1'] and was.get('port') == 9999

ok(token_torn, "a torn token write leaves the installer's allow list, parseable")
ok(lambda: not os.path.exists(TCONF + '.new'), 'and leaves no temp file behind')

def token_lands():
    c = first_start()
    on_disk = json.load(open(TCONF))
    return (c['token'] and on_disk.get('token') == c['token']
            and on_disk.get('allow') == ['10.0.0.1'])

ok(token_lands, 'CONTROL: a write that does not fail generates the token and keeps allow')
ok(lambda: oct(os.stat(TCONF).st_mode & 0o777) == oct(0o600),
   'and that file is 0600 BEFORE it is in place - it now holds the token')

# ---------------------------------------------------------------------------
# The installer's closing report. `allow` is now written BEFORE the helper ever
# starts, so the file EXISTS with no token in it - and both installers used to
# treat "the file is there" as "the token has been generated".
# ---------------------------------------------------------------------------
print('== install.sh reports the token honestly, now that the file predates it')
INST = os.path.join(_here, 'hqrestart', 'install.sh')
src = open(INST).read()
body = src[src.index('# The token is generated'):]

def report(conf_json, system=0, current='192.168.1.234'):
    """Run the REAL tail of install.sh against a config we control."""
    c = os.path.join(tmp, 'report.json')
    open(c, 'w').write(conf_json)
    sh = os.path.join(tmp, 'tail.sh')
    open(sh, 'w').write('set -e\nPY=python3\nCONF=%s\nSYSTEM=%d\nCURRENT=%s\n%s'
                        % (c, system, current or "''", body))
    # REAL_POPEN, not subprocess.run: the suite stubs Popen on that same module
    # object, so run() would hand this the recording stub.
    pr = REAL_POPEN(['sh', sh], stdout=hq.subprocess.PIPE, stderr=hq.subprocess.STDOUT,
                    universal_newlines=True)
    out, _ = pr.communicate(timeout=60)
    return out

# THE BUG: allow answered at the prompt, helper not yet started.
no_token = report('{"allow": ["192.168.1.234"]}')
ok('token:   not written yet' in no_token, 'a config without a token says so')
ok('Bearer \'' not in no_token and 'Bearer "' not in no_token,
   'and prints no curl line with an empty Bearer in it')

# CONTROL: once the helper HAS written it, the token and the test line appear.
ready = report('{"token": "abc123", "port": 8091, "allow": ["192.168.1.234"]}')
ok('token:   abc123' in ready, 'a config WITH a token prints it')
ok('Bearer abc123' in ready and ':8091/status' in ready,
   'and the curl line carries the token and the configured port')

# `--allow` must be given the way the helper was installed, or it writes a
# config in the other location that this install never reads.
sys_hint = report('{"token": "abc123"}', system=1, current='')
ok('sudo' in sys_hint and '--system --allow' in sys_hint,
   'a system install tells you to re-run it with sudo and --system')
user_hint = report('{"token": "abc123"}', system=0, current='')
ok('sudo' not in user_hint, 'and a user install does not')

# ---------------------------------------------------------------------------
# ThreadingHTTPServer runs each request on its own thread, and explain_refusal
# prunes a SHARED map. Unlocked, a prune racing an insert raised "dictionary
# changed size during iteration" (or a KeyError from two threads dropping the
# same entry), so the refused request lost its 401. Measured against 5775983:
# ~6,000 RuntimeErrors in one run of this. Driven on the REAL method.
# ---------------------------------------------------------------------------
print('== the refusal throttle is safe under concurrent requests')
import contextlib, threading as _th

def race():
    lock = getattr(hq.Handler, 'SAID_LOCK', None)
    class Fake:
        command = 'POST'
        SAID = hq.Handler.SAID
        SAID_LOCK = lock
        cfg = {'allow': []}
        def __init__(self, ip):
            self.client_address = (ip, 0)
            self.headers = {'Content-Type': 'application/json'}
        def direct_host(self):
            return True
    Fake.explain_refusal = hq.Handler.explain_refusal
    errors = []
    def worker(n):
        for i in range(300):
            # a stale entry to prune, seeded the way the server would: locked
            with (lock or contextlib.nullcontext()):
                hq.Handler.SAID['10.9.%d.%d' % (n, i % 250)] = 0
            try:
                Fake('10.%d.%d.%d' % (n, i // 250, i % 250)).explain_refusal()
            except Exception as e:
                errors.append(type(e).__name__)
    was = sys.getswitchinterval()
    sys.setswitchinterval(1e-6)                 # preempt often, as load would
    try:
        ts = [_th.Thread(target=worker, args=(n,)) for n in range(12)]
        [t.start() for t in ts]; [t.join() for t in ts]
    finally:
        sys.setswitchinterval(was)
        hq.Handler.SAID.clear()
    logged()
    return errors

ok(lambda: race() == [], 'twelve threads refusing at once raise nothing')

# ---------------------------------------------------------------------------
# A bad --allow on a RE-install. The running helper is stopped before the
# address is checked, so `exit 1` there left it DOWN over a typo.
# ---------------------------------------------------------------------------
print('== a bad --allow does not leave the helper stopped')
src = open(INST).read()
fns = src[src.index('read_allow() {'):src.index('OS="$(uname -s)"')]
blk = src[src.index('CURRENT="$(read_allow "$CONF")"'):]
blk = blk[:blk.index('\nfi\n') + 4]

def reinstall(allow):
    c = os.path.join(tmp, 'reinstall.json')
    open(c, 'w').write('{"token": "keepme", "allow": ["192.168.1.234"]}')
    sh = os.path.join(tmp, 'reinstall.sh')
    open(sh, 'w').write('set -e\nPY=python3\nSRC=%s\nCONF=%s\nUNINSTALL=0\nALLOW_GIVEN=1\nALLOW=%s\n%s%s\n'
                        'echo "REACHED THE START, current=[$CURRENT]"\n'
                        % (os.path.join(_here, 'hqrestart', 'hqrestart.py'), c, allow, fns, blk))
    pr = REAL_POPEN(['sh', sh], stdin=hq.subprocess.DEVNULL, stdout=hq.subprocess.PIPE,
                    stderr=hq.subprocess.STDOUT, universal_newlines=True)
    out, _ = pr.communicate(timeout=60)
    return pr.returncode, out, json.load(open(c))

rc, out, conf = reinstall('192.168.1')
# The fragment has to be given every variable the real script sets before it,
# or it hits a shell error that lands in captured output nobody reads.
ok('operator expected' not in out and 'not found' not in out,
   'the fragment runs without a shell error')
ok(rc == 0 and 'REACHED THE START' in out,
   'a typo carries on to the start rather than exiting with the helper down (rc %s)' % rc)
ok('not accepted' in out, 'and says the address was not accepted')
ok(conf.get('allow') == ['192.168.1.234'] and conf.get('token') == 'keepme',
   'and the previous address and the token both stand')

# CONTROL: a good address on the same path is still written.
rc, out, conf = reinstall('10.0.0.7')
ok(rc == 0 and conf.get('allow') == ['10.0.0.7'], 'a good address is still written')

print('\n%d passed, %d failed' % (P, F))
sys.exit(1 if F else 0)
