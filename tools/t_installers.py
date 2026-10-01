#!/usr/bin/env python3
"""Run the helper's REAL installer end to end, with the service managers stubbed.

Why this exists: three review rounds in a row found a bug the previous fix had
introduced, and each one was a question of ORDER - what runs between stopping
the old helper and starting the new one, and what the user can do in between
(press Ctrl-C at a prompt, mistype an address, have no Python). A test that
extracts one fragment of an installer cannot see order. This one runs the
whole script and reads the order off a log the stubs write.

  * install.sh  - `launchctl` / `systemctl` are stubs on PATH that log each call
                  and, on start, write a token the way the helper's first start
                  does. HOME is a temp dir, so the plist and config land there.

SAFETY: the stub `launchctl` MUST win on PATH. The real one, handed
`bootout gui/<uid>/com.hqrestart.webhook`, would stop the helper installed on
this machine. That is checked before install.sh is run at all, and the run is
refused if it does not hold.

usage: python3 tools/t_installers.py [install.sh]
"""
import json, os, pty, re, select, shutil, signal, subprocess, sys, tempfile, time

_here = os.path.dirname(os.path.abspath(__file__))
HQ = os.path.join(_here, 'hqrestart')
INSTALL_SH = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HQ, 'install.sh')
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
    # NOT an unconditional waitpid.  The read loop above also exits on the 60s
    # deadline with the child STILL ALIVE - a prompt that never returns, a
    # blocking `launchctl bootstrap`, the token wait - and os.waitpid(pid, 0)
    # then blocked for ever.  run_checks.sh runs this file under `set -e` with
    # no timeout, so the whole suite stopped with no output and no failing
    # assertion, which reads as a HANG (see the fleet note on suites that hang).
    # run_sh directly above bounds itself with timeout=120; same rule here.
    #
    # `signal` was already imported and never used, which is where the kill was
    # meant to go.
    def reap(secs):
        for _ in range(int(secs * 10)):
            done, st = os.waitpid(pid, os.WNOHANG)
            if done:
                return st
            time.sleep(0.1)
        return None

    status = reap(4)

    if status is None:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(pid, sig)
            except OSError:
                pass
            status = reap(2)
            if status is not None:
                break

        # A killed child is a FAILED case, not a quiet one: the installer did
        # not finish, so whatever the assertions below read out of `out` is
        # describing a run that never completed.  Say so where it counts.
        ok(False, 'pty_sh: the installer child had to be killed - this case did'
                  ' not complete, and the assertions below judge a partial run')

    try:
        os.close(fd)
    except OSError:
        pass

    return -1 if status is None else status, out.decode(errors='replace')

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

        # --- read_key, lifted out of install.sh and run by sh on its own.  A
        # JSON null has to read as UNWRITTEN: the helper treats a null token as
        # missing and generates one, but read_key printed Python's `None`, so
        # the wait loop took "None" for a token, stopped waiting, and printed
        # `token:   None` and a curl line with `Bearer None` in it.  Not
        # reachable through the whole-install run above - the stub writes the
        # token synchronously, before the loop starts - so tested here.
        src = open(INSTALL_SH).read()
        fn = re.search(r'^read_key\(\) \{\n.*?^\}\n', src, re.S | re.M)
        ok(fn, 'read_key is found in install.sh')
        if fn:
            def read_key(conf, key, dflt):
                return subprocess.run(
                    ['sh', '-c', fn.group(0) + 'read_key "$1" "$2"', 'sh', key, dflt],
                    env=dict(os.environ, PY=sys.executable, CONF=conf,
                             SRC=os.path.join(HQ, 'hqrestart.py')),
                    capture_output=True, text=True).stdout.rstrip('\n')
            kc = os.path.join(tempfile.mkdtemp(), 'k.json')
            json.dump({'token': None, 'port': 9000}, open(kc, 'w'))
            ok(read_key(kc, 'token', '') == '', 'a null token reads as EMPTY, so the wait loop keeps waiting')
            ok(read_key(kc, 'nope', '8090') == '8090', 'a missing key reads as its default')
            ok(read_key(kc, 'port', '8090') == '9000', 'CONTROL: a real value is read as itself')
            # ONE RULE: read through the helper, so a value the helper would
            # correct reads as what it will USE, not as the raw text in the file.
            json.dump({'port': 'abc'}, open(kc, 'w'))
            ok(read_key(kc, 'port', 'x') == '8090',
               "a port the helper would refuse reads as the helper's own default")

        # --- a RE-install over a config that no longer PARSES.  The running
        # helper parsed it at its own start; the new one would exit 2 and stay
        # down.  It used to read as "allow not set", stop the good helper and
        # start one that could not run.  It must be refused BEFORE the stop.
        env, home, stubs = sh_env()
        c = conf_path(home)
        os.makedirs(os.path.dirname(c), exist_ok=True)
        broken = '{"token": "keepme", "allow": ["192.168.1.234"],}'
        open(c, 'w').write(broken)
        rc, out = run_sh(sh, [], env)
        ok(rc != 0, 'a config that does not parse stops the install (rc %s)' % rc)
        ok(stop not in out and start not in out,
           'and the running helper is neither stopped nor replaced')
        ok('cannot read' in out and 'left alone' in out,
           "and says why, in the helper's own words")
        ok(lambda: open(c).read() == broken, 'and the file, token and all, is untouched')

        # CONTROL: the same install over a config that parses runs through
        env, home, stubs = sh_env()
        rc, out = run_sh(sh, [], env, seed={'token': 'keepme', 'allow': ['192.168.1.234']}, home=home)
        ok(rc == 0 and stop in out and start in out,
           'CONTROL: a config that parses re-installs as before (rc %s)' % rc)

        # --- uninstall asks nothing and stops it
        env, home, stubs = sh_env()
        status, out = pty_sh(sh, ['--uninstall'], env, [])
        ok('IP address' not in out and stop in out and start not in out,
           'an uninstall asks nothing, stops it, and starts nothing')

print('\n%d passed, %d failed' % (P, F))
sys.exit(1 if F else 0)
