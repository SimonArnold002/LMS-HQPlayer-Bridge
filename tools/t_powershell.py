#!/usr/bin/env python3
"""Parse every piece of PowerShell the restart helper ships, with pwsh.

install.ps1, and each command hqrestart.py BUILDS at run time - captured by
calling the real functions with `run` stubbed, fed awkward values (a quote in
a path or a service name) so the quoting is what gets tested.

PARSE ONLY. pwsh on macOS/Linux has no Get-CimInstance, Win32_Process or
Restart-Service, so nothing here proves the commands WORK on Windows - only
that Windows PowerShell will not reject them before running a line. pwsh 7
also accepts syntax Windows PowerShell 5.1 does not, so the 7-only operators
are refused by hand.

usage: python3 tools/t_powershell.py      (skips, and says so, without pwsh)
"""
import importlib.util, os, re, shutil, subprocess, sys, tempfile

_here = os.path.dirname(os.path.abspath(__file__))
pwsh = shutil.which('pwsh')
if not pwsh:
    print('  skip PowerShell parse check: no pwsh on PATH')
    sys.exit(0)

spec = importlib.util.spec_from_file_location('hq', os.path.join(_here, 'hqrestart', 'hqrestart.py'))
hq = importlib.util.module_from_spec(spec); spec.loader.exec_module(hq)

scripts = {}
def capture(*labels):
    """Name each PowerShell call in the order the function makes them."""
    todo = list(labels)
    def fake(argv, timeout=30):
        if argv and argv[0] == 'powershell':
            scripts[todo.pop(0) if todo else 'UNEXPECTED extra call'] = argv[argv.index('-Command') + 1]
        return 1, ''
    return fake

hq.PLATFORM = 'win32'
hq.log = lambda msg: None
AWKWARD_EXE = r"C:\Program Files\O'Brien\HQPlayer\hqplayerd.exe"   # ONE quote: two would pair up and parse

class Cfg(dict):
    pass

hq.run = capture('detect_win32: the owning service', 'detect_win32: the exe path')
hq.detect_win32(1234, Cfg(service='', mode='auto'))
hq.run = capture('win32_owner_sids')
hq.win32_owner_sids(1234)
hq.run = capture("restart_service, a service name with a quote")
try:
    hq.restart_service({'os': 'win32', 'target': "HQPlayer O'Service"}, 5)
except RuntimeError:
    pass                                           # the stub fails it; the text is what counts
# start_argv checks the exe exists and that `powershell` is on PATH - neither is
# true on this machine, and neither is what is being tested here
real_isfile, real_which = os.path.isfile, shutil.which
os.path.isfile = lambda p: p == AWKWARD_EXE or real_isfile(p)
shutil.which = lambda c, *a, **k: c if c == 'powershell' else real_which(c, *a, **k)
try:
    argv = hq.start_argv({'os': 'win32', 'exe': AWKWARD_EXE}, Cfg(start_command=None))
finally:
    os.path.isfile, shutil.which = real_isfile, real_which
if argv and argv[0] == 'powershell':
    scripts["start_argv, an exe path with a quote"] = argv[argv.index('-Command') + 1]

expected = ['detect_win32: the owning service', 'detect_win32: the exe path', 'win32_owner_sids',
            'restart_service, a service name with a quote', 'start_argv, an exe path with a quote']

d = tempfile.mkdtemp()
files = {}
for i, (label, text) in enumerate(scripts.items()):
    p = os.path.join(d, 'cmd%d.ps1' % i)
    open(p, 'w').write(text)
    files[p] = label
files[os.path.join(_here, 'hqrestart', 'install.ps1')] = 'install.ps1'

# One pwsh start for everything: it is slow to launch.
check = ''.join(
    "$e = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile('%s', [ref]$null, [ref]$e); "
    "if ($e) { $e | ForEach-Object { 'ERR %s :: ' + $_.Message } } else { 'OK %s' }; "
    % (p.replace("'", "''"), i, i) for i, p in enumerate(files))
out = subprocess.run([pwsh, '-NoProfile', '-NonInteractive', '-Command', check],
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True).stdout

passed = failed = 0
def ok(cond, name):
    global passed, failed
    print('  %s %s' % ('ok  ' if cond else 'FAIL', name))
    if cond: passed += 1
    else: failed += 1

print('== every PowerShell command the helper builds is captured')
for label in expected:
    ok(label in scripts, label)
ok('UNEXPECTED extra call' not in scripts, 'and no call this check does not know about')

print('== pwsh parses them, and install.ps1')
by_index = {}
for line in out.splitlines():
    m = re.match(r'(OK|ERR) (\d+)(?: :: (.*))?$', line.strip())
    if m:
        by_index.setdefault(int(m.group(2)), []).append((m.group(1), m.group(3)))
for i, (p, label) in enumerate(files.items()):
    res = by_index.get(i)
    if not res:
        ok(False, '%s (pwsh said nothing: %s)' % (label, out.strip()[:200]))
    else:
        errs = [msg for kind, msg in res if kind == 'ERR']
        ok(not errs, '%s parses%s' % (label, (' - ' + '; '.join(errs)) if errs else ''))

print('== nothing that only PowerShell 7 understands (Windows ships 5.1)')
SEVEN_ONLY = [(r'\?\?', '??'), (r'\?\.', '?.'), (r'&&', '&&'), (r'\|\|', '||'),
              (r'\s\?\s[^:]+\s:\s', 'the ternary ? :')]
for p, label in files.items():
    text = open(p).read()
    # comments are not code
    text = '\n'.join(l for l in text.splitlines() if not l.lstrip().startswith('#'))
    hits = [name for rx, name in SEVEN_ONLY if re.search(rx, text)]
    ok(not hits, '%s uses none (%s)' % (label, ', '.join(hits) or 'clean'))

print('%d passed, %d failed' % (passed, failed))
sys.exit(1 if failed else 0)
