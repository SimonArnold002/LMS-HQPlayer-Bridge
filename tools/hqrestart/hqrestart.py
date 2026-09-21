#!/usr/bin/env python3
"""hqrestart - a tiny webhook that restarts HQPlayer on the machine it runs on.

Run it on the HQPlayer host. It finds the running HQPlayer, works out HOW it
was started - as a service (launchd job, systemd unit, Windows service) or as
an app - and restarts it the same way:

    macOS    service: launchctl kickstart -k <domain>/<label>
             app:     SIGTERM, wait for exit, `open` the bundle unless macOS respawns it
    Linux    service: systemctl [--user] restart <unit>   (unit read from /proc/<pid>/cgroup)
             app:     SIGTERM, relaunch the recorded /proc/<pid>/cmdline, detached
    Windows  service: Restart-Service <name>              (the service owning the pid)
             app:     Stop-Process, Start-Process <recorded exe path>

The last launch recipe seen is saved, so HQPlayer can be STARTED when it is not
running at all. Every guess can be pinned in the config file.

Endpoints (token required - `Authorization: Bearer <token>`, `X-Token`, or `?token=`).
An address in the config's `allow` list is let in WITHOUT the token only on a POST
sent as `Content-Type: application/json`: a GET would let anything that can make
that host fetch a URL - LMS's own image proxy, a browser there - restart HQPlayer,
and a JSON POST is one a browser will not send cross-site without a CORS preflight
this server never answers.

    GET  /ping      {"ok", "service": "hqrestart"} - NO token; how the HQPlayer Bridge
                    finds out this host can be restarted
    GET  /status    {"running", "pid", "mode", "how"}
    POST /restart   {"ok", "old_pid", "new_pid", "mode", "how", "seconds"}
    GET  /restart   same, WITH the token, so a browser bookmark or phone shortcut works

Standard library only; Python 3.7+.
"""

import hmac
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
PLATFORM = sys.platform  # 'darwin' | 'linux' | 'win32'

DEFAULT_NAMES = {
    'darwin': ['hqplayerd', 'HQPlayer6Desktop', 'HQPlayer5Desktop'],
    'linux':  ['hqplayerd', 'hqplayer6desktop', 'hqplayer5desktop'],
    'win32':  ['hqplayerd.exe', 'HQPlayer6Desktop.exe', 'HQPlayer5Desktop.exe'],
}

DEFAULTS = {
    'listen':        '0.0.0.0',
    'port':          8090,
    'token':         '',
    'allow':         [],      # addresses that need no token, e.g. the LMS server
    'process_names': None,  # None -> DEFAULT_NAMES for this OS
    'mode':          'auto',  # auto | app | service
    'service':       '',      # pin the launchd label / systemd unit / Windows service name
    'user_service':  None,    # Linux: True for `systemctl --user`; None = detect
    'start_command': None,    # pin the app relaunch, as an argv list
    'stop_timeout':  20,      # seconds for a clean exit before SIGKILL
    'respawn_wait':  6,       # macOS app: seconds to let launchd relaunch it before we do
    'start_timeout': 30,      # seconds for the new process to appear
    'total_timeout': 90,      # the whole restart; the HQPlayer Bridge waits a little longer
}


def log(msg):
    sys.stderr.write(time.strftime('%Y-%m-%d %H:%M:%S ') + msg + '\n')
    sys.stderr.flush()


def run(argv, timeout=30):
    """Run a command; return (rc, stdout). Never raises for a missing binary."""
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, universal_newlines=True)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, str(e)


def powershell(script, timeout=60):
    return run(['powershell', '-NoProfile', '-NonInteractive', '-Command', script], timeout)


# ---------------------------------------------------------------- config / state

class Config:
    def __init__(self, path):
        self.path = path
        self.state_path = os.path.join(os.path.dirname(path), 'hqrestart-state.json')
        data = {}
        if os.path.exists(path):
            with open(path) as f:
                data = json.load(f)
        self.c = dict(DEFAULTS, **data)
        if not self.c['token']:
            self.c['token'] = secrets.token_urlsafe(24)
            data['token'] = self.c['token']
            with open(path, 'w') as f:
                json.dump(data, f, indent=2)
            try:
                os.chmod(path, 0o600)
            except OSError:
                pass
            log('generated a token and saved it to %s' % path)

    def __getitem__(self, k):
        return self.c[k]

    def names(self):
        return self.c['process_names'] or DEFAULT_NAMES.get(PLATFORM, ['hqplayerd'])

    def load_state(self):
        try:
            with open(self.state_path) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def save_state(self, how):
        try:
            with open(self.state_path, 'w') as f:
                json.dump(how, f, indent=2)
        except OSError as e:
            log('could not save state: %s' % e)


# ---------------------------------------------------------------- finding the process

def find_pid(names):
    """First pid whose process name matches one of `names` exactly."""
    if PLATFORM == 'win32':
        for n in names:
            rc, out = run(['tasklist', '/FI', 'IMAGENAME eq %s' % n, '/FO', 'CSV', '/NH'])
            for line in out.splitlines():
                cols = [c.strip('"') for c in line.split('","')]
                if len(cols) > 1 and cols[0].lower() == n.lower() and cols[1].isdigit():
                    return int(cols[1])
        return None
    for n in names:
        rc, out = run(['pgrep', '-x', n])
        pids = [int(x) for x in out.split() if x.isdigit()]
        if pids:
            return min(pids)
    return None


def alive(pid):
    if pid is None:
        return False
    if PLATFORM == 'win32':
        rc, out = run(['tasklist', '/FI', 'PID eq %d' % pid, '/FO', 'CSV', '/NH'])
        return ('"%d"' % pid) in out
    # A copy WE started (a relaunch) is our child: once it exits it lingers as
    # a zombie that kill(pid, 0) still reports alive, so every stop would wait
    # out stop_timeout and SIGKILL a process that had already gone. Reap first.
    try:
        if os.waitpid(pid, os.WNOHANG)[0] == pid:
            return False
    except ChildProcessError:
        pass                                        # not ours - the usual case
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


# ---------------------------------------------------------------- how was it started?

def detect_darwin(pid, cfg):
    exe = run(['ps', '-o', 'comm=', '-p', str(pid)])[1].strip()
    m = re.match(r'(.*?\.app)/', exe)
    bundle = m.group(1) if m else None

    label = cfg['service']
    domain = 'system' if os.geteuid() == 0 else 'gui/%d' % os.getuid()
    if not label:
        # `launchctl list` covers the caller's domain: the GUI session for a
        # LaunchAgent, the system domain when run as root.
        for line in run(['launchctl', 'list'])[1].splitlines():
            cols = line.split('\t')
            if len(cols) == 3 and cols[0].strip() == str(pid):
                label = cols[2].strip()
                break
    # An app opened from Finder / a login item gets a throwaway
    # `application.<bundle-id>.<n>` label that changes every launch - not a service.
    is_app_label = bool(label) and label.startswith('application.')
    if cfg['mode'] == 'service' or (cfg['mode'] == 'auto' and label and not is_app_label):
        if not label:
            raise RuntimeError('mode is "service" but no launchd label found; set "service" in the config')
        return {'mode': 'service', 'os': 'darwin', 'target': '%s/%s' % (domain, label)}
    return {'mode': 'app', 'os': 'darwin', 'exe': exe, 'bundle': bundle}


def own_unit():
    """The systemd unit THIS helper runs in, if any."""
    try:
        with open('/proc/self/cgroup') as f:
            m = re.search(r'/([^/\s]+\.service)\s*$', f.read(), re.M)
        return m.group(1) if m else None
    except OSError:
        return None


def detect_linux(pid, cfg):
    try:
        with open('/proc/%d/cmdline' % pid, 'rb') as f:
            argv = [a.decode('utf-8', 'replace') for a in f.read().split(b'\0') if a]
        cwd = os.readlink('/proc/%d/cwd' % pid)
    except OSError:
        argv, cwd = None, None

    unit, user = cfg['service'], cfg['user_service']
    if not unit:
        try:
            with open('/proc/%d/cgroup' % pid) as f:
                cg = f.read()
        except OSError:
            cg = ''
        # e.g. 0::/system.slice/hqplayerd.service
        #      0::/user.slice/user-1000.slice/user@1000.service/app.slice/hqplayerd.service
        m = re.search(r'/([^/\s]+\.service)\s*$', cg, re.M)
        # A copy WE relaunched without systemd-run sits in our own unit's
        # cgroup; restarting "that service" would restart this helper and
        # take HQPlayer down with it, starting nothing.
        if (m and not m.group(1).startswith('user@') and 'session-' not in cg
                and m.group(1) != own_unit()):
            unit = m.group(1)
            if user is None:
                user = '/user@' in cg
    if cfg['mode'] == 'service' or (cfg['mode'] == 'auto' and unit):
        if not unit:
            raise RuntimeError('mode is "service" but no systemd unit found; set "service" in the config')
        return {'mode': 'service', 'os': 'linux', 'target': unit, 'user': bool(user)}
    return {'mode': 'app', 'os': 'linux', 'argv': argv, 'cwd': cwd}


def detect_win32(pid, cfg):
    name = cfg['service']
    if not name:
        rc, out = powershell(
            "(Get-CimInstance Win32_Service -Filter 'ProcessId=%d' | Select-Object -First 1).Name" % pid)
        name = out.strip() if rc == 0 else ''
    if cfg['mode'] == 'service' or (cfg['mode'] == 'auto' and name):
        if not name:
            raise RuntimeError('mode is "service" but no Windows service owns the process; set "service"')
        return {'mode': 'service', 'os': 'win32', 'target': name}
    rc, out = powershell('(Get-Process -Id %d).Path' % pid)
    return {'mode': 'app', 'os': 'win32', 'exe': out.strip() or None}


def detect(pid, cfg):
    return {'darwin': detect_darwin, 'linux': detect_linux, 'win32': detect_win32}[PLATFORM](pid, cfg)


# ---------------------------------------------------------------- stop / start

def stop_app(pid, cfg, budget):
    if PLATFORM == 'win32':
        run(['taskkill', '/PID', str(pid)])            # polite close first
    else:
        try:
            os.kill(pid, signal.SIGTERM)                  # hqplayerd shuts down cleanly on TERM
        except ProcessLookupError:
            return
    deadline = time.time() + min(cfg['stop_timeout'], budget)
    while time.time() < deadline and alive(pid):
        time.sleep(0.25)
    if alive(pid):
        log('pid %d ignored the polite stop, killing' % pid)
        if PLATFORM == 'win32':
            run(['taskkill', '/F', '/PID', str(pid)])
        else:
            os.kill(pid, signal.SIGKILL)
        time.sleep(1)


def start_app(how, cfg):
    argv = cfg['start_command']
    if not argv:
        if how['os'] == 'darwin':
            if how.get('bundle'):
                argv = ['open', '-a', how['bundle']]
            elif how.get('exe'):
                argv = [how['exe']]
        elif how['os'] == 'linux':
            argv = how.get('argv')
        elif how['os'] == 'win32' and how.get('exe'):
            argv = ['powershell', '-NoProfile', '-Command',
                    "Start-Process -FilePath '%s'" % how['exe'].replace("'", "''")]
    if not argv:
        raise RuntimeError('do not know how to start HQPlayer; set "start_command" in the config')
    log('starting: %s' % ' '.join(argv))
    kw = {'stdin': subprocess.DEVNULL, 'stdout': subprocess.DEVNULL, 'stderr': subprocess.DEVNULL,
          'close_fds': True, 'cwd': how.get('cwd') or None}
    if PLATFORM == 'win32':
        kw['creationflags'] = 0x00000008 | 0x00000200   # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    else:
        kw['start_new_session'] = True                  # outlive this webhook
        # Under systemd a new session is NOT a new cgroup: the app would stay
        # in this helper's unit, be killed by its stop, and be mistaken for
        # it next time. A transient scope gives it a cgroup of its own.
        if PLATFORM == 'linux' and own_unit() and run(['systemd-run', '--version'])[0] == 0:
            argv = (['systemd-run', '--scope', '--quiet', '--collect']
                    + (['--user'] if os.geteuid() != 0 else []) + ['--'] + list(argv))
    subprocess.Popen(argv, **kw)


def restart_service(how, budget):
    if how['os'] == 'darwin':
        argv = ['launchctl', 'kickstart', '-k', how['target']]
    elif how['os'] == 'linux':
        argv = ['systemctl'] + (['--user'] if how.get('user') else []) + ['restart', how['target']]
    else:
        argv = ['powershell', '-NoProfile', '-Command',
                "Restart-Service -Name '%s' -Force" % how['target'].replace("'", "''")]
    log('restarting service: %s' % ' '.join(argv))
    rc, out = run(argv, timeout=max(1, budget))
    if rc != 0:
        raise RuntimeError('%s failed (rc %d): %s' % (argv[0], rc, out.strip()[:300]))


def wait_new_pid(cfg, old_pid, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        pid = find_pid(cfg.names())
        if pid and pid != old_pid:
            return pid
        time.sleep(0.25)
    return None


def restart(cfg):
    t0 = time.time()
    deadline = t0 + cfg['total_timeout']

    # Every wait is clipped to what is left, so the caller always hears back
    # inside total_timeout - a slow service stop must not outlast the Bridge.
    def left(want):
        return max(0.0, min(want, deadline - time.time()))
    old = find_pid(cfg.names())
    if old:
        how = detect(old, cfg)
        cfg.save_state(how)
    else:
        how = cfg.load_state()
        if not how:
            raise RuntimeError('HQPlayer is not running and has never been seen running, '
                               'so how to start it is unknown; set "mode"/"service"/"start_command"')
    log('restart: pid %s, %s' % (old, json.dumps(how)))

    if how['mode'] == 'service':
        restart_service(how, left(cfg['total_timeout']))
        new = wait_new_pid(cfg, old, left(cfg['start_timeout']))
    else:
        if old:
            stop_app(old, cfg, left(cfg['stop_timeout']))
        new = None
        if how['os'] == 'darwin' and old:
            # A login item / launchd can relaunch it by itself - give it the
            # chance, so we never end up with two copies.
            new = wait_new_pid(cfg, old, left(cfg['respawn_wait']))
            if new:
                how = dict(how, respawned=True)
        if not new:
            start_app(how, cfg)
            new = wait_new_pid(cfg, old, left(cfg['start_timeout']))

    if not new:
        raise RuntimeError('HQPlayer did not come back within %.0fs' % (time.time() - t0))
    return {'ok': True, 'old_pid': old, 'new_pid': new, 'mode': how['mode'], 'how': how,
            'seconds': round(time.time() - t0, 1)}


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    cfg = None
    lock = threading.Lock()
    server_version = 'hqrestart/1'

    def log_message(self, fmt, *args):
        # never write the token: a bookmark call carries it in the query
        log('%s %s' % (self.client_address[0], re.sub(r'(token=)[^&\s"]*', r'\1***', fmt % args)))

    def reply(self, code, body):
        data = (json.dumps(body, indent=2) + '\n').encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def authorised(self, url):
        got = self.headers.get('X-Token') or ''
        auth = self.headers.get('Authorization') or ''
        if auth.lower().startswith('bearer '):
            got = auth[7:].strip()
        if not got:
            got = (parse_qs(url.query).get('token') or [''])[0]
        return hmac.compare_digest(got.encode(), self.cfg['token'].encode())

    def handle_any(self):
        url = urlparse(self.path)
        if url.path == '/ping':
            return self.reply(200, {'ok': True, 'service': 'hqrestart'})
        n = int(self.headers.get('Content-Length') or 0)
        if n:
            self.rfile.read(min(n, 65536))
        trusted = (self.command == 'POST'
                   and self.client_address[0] in self.cfg['allow']
                   and (self.headers.get('Content-Type') or '').split(';')[0].strip() == 'application/json')
        if not (trusted or self.authorised(url)):
            return self.reply(401, {'ok': False, 'error': 'bad or missing token'})
        if url.path == '/status':
            pid = find_pid(self.cfg.names())
            how = None
            if pid:
                try:
                    how = detect(pid, self.cfg)
                except Exception as e:
                    how = {'error': str(e)}
            return self.reply(200, {'ok': True, 'running': bool(pid), 'pid': pid,
                                    'mode': how and how.get('mode'), 'how': how})
        if url.path == '/restart':
            if not self.lock.acquire(blocking=False):
                return self.reply(409, {'ok': False, 'error': 'a restart is already running'})
            try:
                return self.reply(200, restart(self.cfg))
            except Exception as e:
                log('restart failed: %s' % e)
                return self.reply(500, {'ok': False, 'error': str(e)})
            finally:
                self.lock.release()
        return self.reply(404, {'ok': False, 'error': 'unknown path; use /status or /restart'})

    do_GET = handle_any
    do_POST = handle_any


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'hqrestart.json')
    cfg = Config(path)
    Handler.cfg = cfg
    srv = ThreadingHTTPServer((cfg['listen'], int(cfg['port'])), Handler)
    log('hqrestart listening on %s:%s (%s), watching %s'
        % (cfg['listen'], cfg['port'], PLATFORM, ', '.join(cfg.names())))
    srv.serve_forever()


if __name__ == '__main__':
    main()
