#!/usr/bin/env python3
"""Run the helper's REAL installers end to end, with the service managers stubbed.

Why this exists: three review rounds in a row found a bug the previous fix had
introduced, and each one was a question of ORDER - what runs between stopping
the old helper and starting the new one, and what the user can do in between
(press Ctrl-C at a prompt, mistype an address, have no Python). A test that
extracts one fragment of an installer cannot see order. This one runs the
whole script and reads the order off a log the stubs write.

  * install.sh  - `launchctl` / `systemctl` are stubs on PATH that log each call
                  and, on start, write a token the way the helper's first start
                  does. HOME is a temp dir, so the plist and config land there.
  * install.ps1 - the ScheduledTask and firewall cmdlets are stub FUNCTIONS
                  (a function outranks a cmdlet, and on macOS the cmdlets do not
                  exist anyway); `python.exe` / `pythonw.exe` are stubs on PATH.
                  Skipped, out loud, without pwsh.

SAFETY: the stub `launchctl` MUST win on PATH. The real one, handed
`bootout gui/<uid>/com.hqrestart.webhook`, would stop the helper installed on
this machine. That is checked before install.sh is run at all, and the run is
refused if it does not hold.

usage: python3 tools/t_installers.py [install.sh] [install.ps1]
"""
import json, os, pty, select, shutil, signal, subprocess, sys, tempfile, time

_here = os.path.dirname(os.path.abspath(__file__))
HQ = os.path.join(_here, 'hqrestart')
INSTALL_SH = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HQ, 'install.sh')
INSTALL_PS1 = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(HQ, 'install.ps1')
HELPER = os.path.join(HQ, 'hqrestart.py')
PY = sys.executable

P = F = 0
def ok(c, name):
    global P, F
    if callable(c):
        try:
            c = c()
        except Exception as e:
            c = False
            name = '%s [%s: %s]' % (name, type(e).__name__, e)
    if c: P += 1; print('  ok  ', name)
    else: F += 1; print('  FAIL', name)

def before(out, a, b):
    """True when line `a` appears in `out`, and before any `b` (or `b` never does)."""
    ia, ib = out.find(a), out.find(b)
    return ia >= 0 and (ib < 0 or ia < ib)

# The installers find their helper beside themselves. A control run points at
# an older installer elsewhere, so give it a private copy of the dir to live in.
def staged(installer):
    d = tempfile.mkdtemp()
    for f in os.listdir(HQ):
        if os.path.isfile(os.path.join(HQ, f)):
            shutil.copy(os.path.join(HQ, f), d)
    shutil.copy(installer, os.path.join(d, os.path.basename(installer)))
    return os.path.join(d, os.path.basename(installer))

# ===========================================================================
# install.sh
# ===========================================================================
print('== install.sh, run for real with launchctl/systemctl stubbed')

STUB = r'''#!/bin/sh
# log every call, in order, to the installer's own stdout
echo "STUB {name} $*"
case "$*" in
  bootstrap*|*"enable --now"*)
    # what the helper's first start does: add a token, keep everything else
    for c in "$HOME/Library/Application Support/hqrestart/hqrestart.json" \
             "$HOME/.config/hqrestart/hqrestart.json"; do
      [ -d "$(dirname "$c")" ] || continue
      "{py}" -c 'import json,os,sys
p=sys.argv[1]; d=json.load(open(p)) if os.path.exists(p) else {{}}
d.setdefault("token","tok-from-first-start"); json.dump(d,open(p,"w"))' "$c"
    done ;;
esac
exit 0
'''

def sh_env():
    home = tempfile.mkdtemp()
    stubs = tempfile.mkdtemp()
    for name in ('launchctl', 'systemctl'):
        p = os.path.join(stubs, name)
        open(p, 'w').write(STUB.format(name=name, py=PY))
        os.chmod(p, 0o755)
    path = os.pathsep.join([stubs, os.path.dirname(PY), '/usr/bin', '/bin', '/usr/sbin', '/sbin'])
    env = dict(os.environ, HOME=home, PATH=path)
    return env, home, stubs

def stubs_win(env, stubs):
    """The whole safety of this section: the stub must be what `launchctl` means."""
    for name in ('launchctl', 'systemctl'):
        r = subprocess.run(['sh', '-c', 'command -v %s' % name], env=env,
                           stdout=subprocess.PIPE, universal_newlines=True)
        if r.stdout.strip() != os.path.join(stubs, name):
            return False
    return True

def conf_path(home):
    if sys.platform == 'darwin':
        return os.path.join(home, 'Library', 'Application Support', 'hqrestart', 'hqrestart.json')
    return os.path.join(home, '.config', 'hqrestart', 'hqrestart.json')

def run_sh(installer, args, env, seed=None, home=None):
    if seed is not None:
        c = conf_path(home)
        os.makedirs(os.path.dirname(c), exist_ok=True)
        json.dump(seed, open(c, 'w'))
    r = subprocess.run(['sh', installer] + args, env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       universal_newlines=True, timeout=120)
    return r.returncode, r.stdout

def pty_sh(installer, args, env, keys):
    """Run under a real terminal; `keys` is what to type at each prompt. A key of
    None sends Ctrl-C there instead."""
    out = b''; sent = 0
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.clear(); os.environ.update(env)
        os.execvp('sh', ['sh', installer] + args)
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            r, _, _ = select.select([fd], [], [], 0.3)
        except OSError:
            break
        if not r:
            continue
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        out += d
        if b'IP address' in out.split(b'\n')[-1] and sent < len(keys):
            k = keys[sent]; sent += 1
            os.write(fd, b'\x03' if k is None else (k + '\n').encode())
    _, status = os.waitpid(pid, 0)
    return status, out.decode(errors='replace')

if not shutil.which('sh'):
    print('  skip install.sh: no sh')
else:
    env, home, stubs = sh_env()
    safe = stubs_win(env, stubs)
    ok(safe, 'the stub launchctl/systemctl win on PATH (else nothing below may run)')
    if safe:
        start = 'STUB launchctl bootstrap' if sys.platform == 'darwin' else 'STUB systemctl --user enable --now'
        stop = 'STUB launchctl bootout' if sys.platform == 'darwin' else 'STUB systemctl --user disable --now'
        sh = staged(INSTALL_SH)

        # --- a fresh install, answered on the command line
        rc, out = run_sh(sh, ['--allow', '192.168.1.234'], env)
        c = conf_path(home)
        ok(rc == 0 and start in out, 'a fresh install starts the helper (rc %s)' % rc)
        ok(lambda: json.load(open(c)).get('allow') == ['192.168.1.234'], 'and writes the address')
        ok('token:   tok-from-first-start' in out, 'and prints the token the first start wrote')
        ok('IP address' not in out, 'and asks nothing when stdin is not a terminal')

        # --- a RE-install with a typo: must not leave the helper down
        env, home, stubs = sh_env()
        seed = {'token': 'keepme', 'allow': ['192.168.1.234']}
        rc, out = run_sh(sh, ['--allow', '192.168.1'], env, seed=seed, home=home)
        ok(rc == 0 and start in out, 'a bad --allow still ends with the helper STARTED (rc %s)' % rc)
        ok(before(out, 'not accepted', stop),
           'and is refused BEFORE the running helper is stopped')
        ok(lambda: json.load(open(conf_path(home))) == seed,
           'and the previous address and token stand, untouched')

        # --- the prompt, and a user who presses Ctrl-C at it
        env, home, stubs = sh_env()
        status, out = pty_sh(sh, [], env, [None])
        ok('IP address' in out, 'on a terminal it asks')
        ok(stop not in out,
           'and Ctrl-C at the prompt has stopped NOTHING (the helper keeps running)')

        # --- the prompt, answered
        env, home, stubs = sh_env()
        status, out = pty_sh(sh, [], env, ['192.168.1.234'])
        ok(before(out, 'IP address', stop) and start in out,
           'an answered prompt comes before the stop, and the helper starts')
        ok(lambda: json.load(open(conf_path(home))).get('allow') == ['192.168.1.234'],
           'and the answer is written')

        # --- uninstall asks nothing and stops it
        env, home, stubs = sh_env()
        status, out = pty_sh(sh, ['--uninstall'], env, [])
        ok('IP address' not in out and stop in out and start not in out,
           'an uninstall asks nothing, stops it, and starts nothing')

# ===========================================================================
# install.ps1
# ===========================================================================
print('== install.ps1, run for real with the ScheduledTask cmdlets stubbed')
pwsh = shutil.which('pwsh')

PS_STUBS = r'''
$ErrorActionPreference = 'Stop'
function _log($m) { [Console]::Out.WriteLine("STUB $m"); [Console]::Out.Flush() }
function Unregister-ScheduledTask { _log 'Unregister-ScheduledTask' }
function New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) 'a' }
function New-ScheduledTaskSettingsSet { 's' }
function New-ScheduledTaskTrigger { 't' }
function New-ScheduledTaskPrincipal { 'p' }
function New-TimeSpan { [TimeSpan]::FromMinutes(1) }
function Register-ScheduledTask { _log 'Register-ScheduledTask' }
function Start-ScheduledTask {
    _log 'Start-ScheduledTask'
    # what the helper's first start does: add a token, keep everything else
    $c = Join-Path $env:LOCALAPPDATA 'hqrestart/hqrestart.json'
    & '{py}' -c 'import json,os,sys
p=sys.argv[1]; d=json.load(open(p)) if os.path.exists(p) else {{}}
d.setdefault("token","tok-from-first-start"); json.dump(d,open(p,"w"))' $c
}
function Get-NetFirewallRule { 'rule' }
function New-NetFirewallRule { }
'''

def ps_env(with_python=True):
    local = tempfile.mkdtemp()
    stubs = tempfile.mkdtemp()
    if with_python:
        for exe in ('python.exe', 'pythonw.exe'):
            p = os.path.join(stubs, exe)
            open(p, 'w').write('#!/bin/sh\nexec "%s" "$@"\n' % PY)
            os.chmod(p, 0o755)
    # no python3 on this PATH: only the .exe stubs, or nothing at all
    path = os.pathsep.join([stubs, os.path.dirname(pwsh), '/usr/bin', '/bin'])
    env = dict(os.environ, LOCALAPPDATA=local, USERNAME='tester', COMPUTERNAME='testbox', PATH=path)
    return env, local

def run_ps(installer, args, env, noninteractive=True, seed=None, local=None):
    if seed is not None:
        c = os.path.join(local, 'hqrestart', 'hqrestart.json')
        os.makedirs(os.path.dirname(c), exist_ok=True)
        json.dump(seed, open(c, 'w'))
    wrap = os.path.join(tempfile.mkdtemp(), 'wrap.ps1')
    open(wrap, 'w').write(PS_STUBS.replace('{py}', PY).replace('{{}}', '{}') +
                          "\n& '%s' %s\n" % (installer, ' '.join(args)))
    cmd = [pwsh, '-NoProfile'] + (['-NonInteractive'] if noninteractive else []) + ['-File', wrap]
    r = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True, timeout=120)
    return r.returncode, r.stdout

if not pwsh:
    print('  skip install.ps1: no pwsh on PATH')
else:
    ps = staged(INSTALL_PS1)
    STOP, START = 'STUB Unregister-ScheduledTask', 'STUB Start-ScheduledTask'

    env, local = ps_env()
    rc, out = run_ps(ps, ['-Allow', '192.168.1.234'], env, local=local)
    c = os.path.join(local, 'hqrestart', 'hqrestart.json')
    ok(rc == 0 and START in out, 'a fresh install starts the task (rc %s)' % rc)
    ok(lambda: json.load(open(c)).get('allow') == ['192.168.1.234'], 'and writes the address')
    ok('token:   tok-from-first-start' in out, 'and prints the token the first start wrote')

    env, local = ps_env()
    seed = {'token': 'keepme', 'allow': ['192.168.1.234']}
    rc, out = run_ps(ps, ['-Allow', '192.168.1'], env, seed=seed, local=local)
    c = os.path.join(local, 'hqrestart', 'hqrestart.json')
    ok(rc == 0 and START in out, 'a bad -Allow still ends with the task STARTED (rc %s)' % rc)
    ok(before(out, 'not accepted', STOP), 'and is refused BEFORE the task is unregistered')
    ok('leaving it as it was' in out, 'and says the previous value stands, not that it is unset')
    ok(lambda: json.load(open(c)) == seed, 'and the previous address and token are untouched')

    env, local = ps_env()
    rc, out = run_ps(ps, [], env, noninteractive=True, local=local)
    ok(rc == 0 and 'not interactive' in out and START in out,
       'under -NonInteractive the prompt is skipped and the install completes (rc %s)' % rc)

    # The Python checks THROW. Before this change they ran after the unregister,
    # so a missing Python left no helper at all.
    env, local = ps_env(with_python=False)
    rc, out = run_ps(ps, ['-Allow', '192.168.1.234'], env, local=local)
    ok(rc != 0 and 'Python not found' in out, 'no Python refuses the install (rc %s)' % rc)
    ok(STOP not in out, 'and has unregistered NOTHING - the existing task is still there')

    env, local = ps_env(with_python=False)
    rc, out = run_ps(ps, ['-Uninstall'], env, local=local)
    ok(rc == 0 and STOP in out and START not in out,
       'an uninstall needs no Python, unregisters it, and starts nothing (rc %s)' % rc)

print('\n%d passed, %d failed' % (P, F))
sys.exit(1 if F else 0)
