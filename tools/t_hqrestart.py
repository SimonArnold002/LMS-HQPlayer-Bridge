"""The restart helper must never stop an HQPlayer it cannot start again.
Fakes /proc, the platform and the process calls; stops and starts nothing real.
usage: python3 tools/t_hqrestart.py [path to hqrestart.py]"""
import builtins, importlib.util, io, json, os, sys, tempfile

_here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('hq', sys.argv[1] if len(sys.argv) > 1 else os.path.join(_here, 'hqrestart', 'hqrestart.py')); hq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hq)
P = F = 0
def ok(c, name):
    global P, F
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

print('== a list key written as a bare string is read as ONE entry')
import json as _json
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

print('\n%d passed, %d failed' % (P, F))
sys.exit(1 if F else 0)
