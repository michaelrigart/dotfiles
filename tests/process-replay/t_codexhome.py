import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import is_, ok, put

helpers.setup()
from process_replay import codexhome as H  # noqa: E402
from process_replay.common import Failed  # noqa: E402

ROOT = helpers.tmp_root()
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "xdg")
FAKE = os.path.join(ROOT, "fakecodex")
os.environ["CODEX_REAL_BIN"] = helpers.stub_codex(FAKE)
LOG = os.path.join(FAKE, "codex.log")
ANSWER = {"verdict": "approve", "findings": []}
# the rpc the module itself uses (XR.RPC) for liveness checks: a daemon that answers health, or one that does not
UP = helpers.stub_rpc(os.path.join(ROOT, "rpc-up"), ROOT, {"health_rc": 0, "default": {"answer": ANSWER}})
DOWN = helpers.stub_rpc(os.path.join(ROOT, "rpc-down"), ROOT, {"health_rc": 5})
H.XR.RPC = UP

SUMMARY = ("# Memory summary\n\nThe deploy script lives in bin/deploy-zebra and needs the --quiet flag.\n"
           "Reviews of the quokka module always hit the same off-by-one in the tail.\n"
           "Michael prefers fixture names that start with an unusual marker word: plinth.\n\nshort\n")
CONFIG = ('model = "m-1"\nnotify = [\n  "/bin/notifier", "--flag",  # [x]\n]\nsandbox = "workspace"\n\n[features]\nmemories = true\n\n[memories]\nuse_memories = true\nmax_items = 7  # keep\n'
          'generate_memories = true\n\n[mcp_servers.x]\ncommand = "x"\nnotify = "stays"\n')


def raises(fn, *args, **kw):
    try:
        fn(*args, **kw)
    except Failed:
        return True
    return False


def make_source(name, config=CONFIG, links=True):
    src = os.path.join(ROOT, name)
    put(src, "config.toml", config)
    put(src, "AGENTS.md", "# agents\n")
    put(src, "memories/memory_summary.md", SUMMARY)
    put(src, "sessions/2026/10/01/rollout-2026-10-01T00-00-00-old.jsonl", "{}\n")
    put(src, ".codex-global-state.json", "{}")
    put(src, "auth.json", "SOURCE-LOGIN-NEVER-COPIED")
    if links:
        for d in ("skills", "rules", "plugins"):
            put(src, d + "/f.txt", d)
            put(src, d + "/sub/g.txt", d)
        os.symlink("f.txt", os.path.join(src, "skills", "ln"))
        os.symlink("/outside/target", os.path.join(src, "rules", "abs"))
    return src


def H_json(path):
    with open(path) as f:
        return json.load(f)


def table(text, name):
    m = re.search(r"^\[" + name + r"\]\n((?:(?!\[).*\n)*)", text, re.M)
    return m.group(1) if m else None


SRC = make_source("src")
STATE = os.path.join(ROOT, "state")

# ---- home_config
home = H.ensure(STATE, "nomem", source=SRC)
is_("home_config: the home lies under $XDG_STATE_HOME/cxh/<name>", home, os.path.join(ROOT, "xdg", "cxh", "nomem"))
is_("home_config: mode 700", stat.S_IMODE(os.stat(home).st_mode), 0o700)
cfg = open(os.path.join(home, "config.toml")).read()
mem = table(cfg, "memories")
ok("home_config: [memories] holds use_memories = false and generate_memories = false",
   mem is not None and re.search(r"^use_memories = false$", mem, re.M) and re.search(r"^generate_memories = false$", mem, re.M)
   and mem.count("use_memories") == 1 and mem.count("generate_memories") == 1, cfg)
ok("home_config: a source [memories] key keeps its place, comment included", "max_items = 7  # keep" in (mem or ""), mem)
ok("home_config: [features] memories is unchanged", table(cfg, "features") == "memories = true\n\n", cfg)
ok("home_config: every other table and key is untouched", 'model = "m-1"' in cfg and '[mcp_servers.x]\ncommand = "x"' in cfg, cfg)
bare = make_source("src-bare", config='model = "m-1"\n[features]\nmemories = false\n', links=False)
h2 = H.ensure(STATE, "bare", source=bare)
cfg2 = open(os.path.join(h2, "config.toml")).read()
ok("home_config: a source without [memories] gets the table added",
   table(cfg2, "memories") == "use_memories = false\ngenerate_memories = false\n" and table(cfg2, "features") == "memories = false\n\n", cfg2)
ok("home_config: AGENTS.md is copied", open(os.path.join(home, "AGENTS.md")).read() == "# agents\n")
ok("home_config: skills, rules and plugins are copies with their contents",
   all(os.path.isdir(os.path.join(home, d)) and not os.path.islink(os.path.join(home, d))
       and open(os.path.join(home, d, "sub", "g.txt")).read() == d for d in ("skills", "rules", "plugins")))
ok("home_config: a link inside a copy stays a link and is not followed",
   os.readlink(os.path.join(home, "skills", "ln")) == "f.txt" and os.readlink(os.path.join(home, "rules", "abs")) == "/outside/target"
   and os.path.islink(os.path.join(home, "skills", "ln")))
into_source = []
for d, dirs, files in os.walk(home):
    for n in dirs + files:
        full = os.path.join(d, n)
        if os.path.islink(full) and os.path.realpath(full).startswith(os.path.realpath(SRC) + os.sep):
            into_source.append(full)
is_("home_config: nothing in the home links into the source home", into_source, [])
before_src = helpers.listing(SRC)
put(home, "plugins/.plugin-appserver", "x")
put(home, "plugins/cache/c", "x")
put(home, "skills/.system/s", "x")
put(home, "plugins/sub/g.txt", "changed")
put(home, "skills/f.txt", "changed")
is_("home_config: writing into the home's plugins and skills leaves the source unchanged", helpers.listing(SRC), before_src)
ok("home_config: and another ensure refreshes the copies", (H.ensure(STATE, "nomem", source=SRC),
   not os.path.exists(os.path.join(home, "plugins", ".plugin-appserver")), open(os.path.join(home, "skills", "f.txt")).read() == "skills")[1:] == (True, True))
ok("home_config: the top-level notify key is dropped, whatever its length",
   "notify = [" not in cfg and "/bin/notifier" not in cfg and re.search(r"^notify\s*=", cfg.split("[features]")[0], re.M) is None, cfg)
ok("home_config: its neighbours stay, and a notify key inside a table too",
   'sandbox = "workspace"' in cfg and 'model = "m-1"' in cfg and '[mcp_servers.x]\ncommand = "x"\nnotify = "stays"' in cfg, cfg)
single = make_source("src-single", config='notify = ["/bin/n", "a"]\nmodel = "m"\n', links=False)
ok("home_config: a one-line notify is dropped too", "notify" not in open(os.path.join(H.ensure(STATE, "single", source=single), "config.toml")).read())
ok("home_config: and absent when the source has none", not any(os.path.lexists(os.path.join(h2, d)) for d in ("skills", "rules", "plugins")))
auth = os.path.join(home, "auth.json")
is_("home_config: auth.json is a link to the shared login", (os.path.islink(auth), os.readlink(auth)),
    (True, os.path.join(H.auth_dir(), "auth.json")))
is_("home_config: the shared login lives under $XDG_STATE_HOME/process-replay/codex-auth", H.auth_dir(),
    os.path.join(ROOT, "xdg", "process-replay", "codex-auth"))
ok("home_config: the source's own login is never copied", not os.path.exists(os.path.join(H.auth_dir(), "auth.json"))
   and "SOURCE-LOGIN" not in "".join(open(os.path.join(home, f)).read() for f in os.listdir(home) if os.path.isfile(os.path.join(home, f))))
ok("home_config: no sessions, archived_sessions, sqlite, memories or global state",
   not any(os.path.lexists(os.path.join(home, x)) for x in ("sessions", "archived_sessions", "sqlite", "memories", ".codex-global-state.json")),
   os.listdir(home))
before = os.listdir(home)
H.ensure(STATE, "nomem", source=SRC)
is_("home_config: ensure again changes nothing", sorted(os.listdir(home)), sorted(before))
put(home, "sessions/keep.txt", "k")
H.ensure(STATE, "nomem", source=SRC)
ok("home_config: and keeps what the daemon wrote there", os.path.exists(os.path.join(home, "sessions", "keep.txt")))

# ---- notify_escapes
ESC = 'notify = ["sh", "-c", "echo \\"[\\""]\nmodel = "m"\n\n[mcp_servers.x]\ncommand = "x"\n'
got = H._without_notify(ESC)
ok("notify_escapes: a quoted bracket behind a backslash does not hide what follows", got == 'model = "m"\n\n[mcp_servers.x]\ncommand = "x"\n', got)
got = H._without_notify('notify = [\n  "a\\\\", "b",\n]\nmodel = "m"\n')
is_("notify_escapes: nor does an escaped backslash end a string early", got, 'model = "m"\n')

# ---- home_short_path
is_("home_short_path: the registry lists the homes by name", H_json(os.path.join(STATE, "codex-homes.json")).get("nomem"), home)
xdg_saved = os.environ["XDG_STATE_HOME"]
os.environ["XDG_STATE_HOME"] = "/Users/michael/.local/state"
sock_len = len(H._socket(H.home_path("mem-0123456789ab")).encode("utf-8"))
os.environ["XDG_STATE_HOME"] = xdg_saved
ok("home_short_path: a mem-<hash12> home under a realistic XDG_STATE_HOME has a socket path within 103 bytes", sock_len <= 103, sock_len)
xdg_saved = os.environ["XDG_STATE_HOME"]
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "x" * 90)
ok("home_short_path: a long XDG_STATE_HOME makes ensure raise", raises(H.ensure, STATE, "mem-0123456789ab", source=SRC))
ok("home_short_path: and nothing was made", not os.path.exists(os.path.join(ROOT, "x" * 90)))
os.environ["XDG_STATE_HOME"] = xdg_saved

# ---- home_memories
SNAP = os.path.join(ROOT, "snap")
put(SNAP, "memory_summary.md", SUMMARY)
put(SNAP, "notes/a.md", "a")
put(SNAP, ".git/HEAD", "ref")
hm = H.ensure(STATE, "mem-x", memories_src=SNAP, use_memories=True, source=SRC)
mcfg = open(os.path.join(hm, "config.toml")).read()
mmem = table(mcfg, "memories") or ""
ok("home_memories: use_memories = true, generate_memories = false",
   re.search(r"^use_memories = true$", mmem, re.M) and re.search(r"^generate_memories = false$", mmem, re.M)
   and mmem.count("use_memories") == 1 and mmem.count("generate_memories") == 1, mcfg)
ok("home_memories: the snapshot is copied to memories/ without .git",
   open(os.path.join(hm, "memories", "notes", "a.md")).read() == "a" and os.path.exists(os.path.join(hm, "memories", "memory_summary.md"))
   and not os.path.lexists(os.path.join(hm, "memories", ".git")), os.listdir(os.path.join(hm, "memories")))
ok("home_memories: a copy, not a link into the snapshot", not os.path.islink(os.path.join(hm, "memories")))
put(SNAP, "notes/b.md", "b")
H.ensure(STATE, "mem-x", memories_src=SNAP, use_memories=True, source=SRC)
ok("home_memories: ensure again refreshes the copy", os.path.exists(os.path.join(hm, "memories", "notes", "b.md")))
H.ensure(STATE, "mem-x", source=SRC)
ok("home_memories: and without a snapshot leaves no memories behind", not os.path.lexists(os.path.join(hm, "memories")))
ok("home_memories: use_memories without a snapshot is refused", raises(H.ensure, STATE, "mem-y", use_memories=True, source=SRC))

# ---- home_refuses_live
src3 = make_source("xdg/cxh/same")
ok("home_refuses_live: a home that would be the source home", raises(H.ensure, STATE, "same", source=src3))
ok("home_refuses_live: and the source was not modified", open(os.path.join(src3, "config.toml")).read() == CONFIG)
xdg_saved = os.environ["XDG_STATE_HOME"]
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "xdg-b")
src4 = make_source("xdg-b/cxh")
ok("home_refuses_live: a home that would lie below the source home", raises(H.ensure, STATE, "inside", source=src4))
ok("home_refuses_live: and nothing was made there", not os.path.exists(os.path.join(src4, "inside")))
os.environ["XDG_STATE_HOME"] = xdg_saved
ok("home_refuses_live: memories_src that is the source's memories", raises(H.ensure, STATE, "mem-live", os.path.join(SRC, "memories"), True, SRC))
link = os.path.join(ROOT, "memlink")
os.symlink(os.path.join(SRC, "memories"), link)
ok("home_refuses_live: also through a link", raises(H.ensure, STATE, "mem-live", link, True, SRC))
ok("home_refuses_live: nothing was made for the refused name", not os.path.exists(os.path.join(ROOT, "xdg", "cxh", "mem-live")))
ok("home_refuses_live: a source without config.toml", raises(H.ensure, STATE, "nocfg", source=os.path.join(ROOT, "nowhere")))
ok("home_refuses_live: a name that leaves the directory", raises(H.ensure, STATE, "../x", source=SRC))

# ---- real_bin and login_cmd
is_("real_bin: CODEX_REAL_BIN wins", H.real_bin(), os.environ["CODEX_REAL_BIN"])
is_("login_cmd: CODEX_HOME=<auth_dir> <real> login", H.login_cmd(),
    "CODEX_HOME={} {} login".format(H.auth_dir(), os.environ["CODEX_REAL_BIN"]))
saved = os.environ.pop("CODEX_REAL_BIN")
os.environ["PINNED_PATH"] = FAKE
is_("real_bin: else what codex-daemon real-bin prints", os.path.realpath(H.real_bin()), os.path.realpath(os.path.join(FAKE, "codex")))
os.environ["PINNED_PATH"] = os.path.join(ROOT, "empty")
ok("real_bin: and a refusal when there is none", raises(H.real_bin))
del os.environ["PINNED_PATH"]
os.environ["CODEX_REAL_BIN"] = saved

# ---- start_stop
SOCK = os.path.join(home, "app-server-control", "app-server-control.sock")
ok("start_stop: a directory that is not a replay home is refused", raises(H.start, SRC) and raises(H.stop, SRC)
   and helpers.read_log(LOG) == [])
H.start(home)
log = helpers.read_log(LOG)
is_("start_stop: start runs <real> app-server daemon start with CODEX_HOME=<home>",
    log, [{"argv": ["app-server", "daemon", "start"], "codex_home": home}])
ok("start_stop: the daemon's socket exists", os.path.exists(SOCK))
H.start(home)
ok("start_stop: starting the same home again is allowed", len(helpers.read_log(LOG)) == 2)
ok("start_stop: a second home is refused while one runs", raises(H.start, hm) and len(helpers.read_log(LOG)) == 2)
# a refreshed token: codex replaced the link with a regular file
os.unlink(auth)
put(home, "auth.json", "REFRESHED-TOKEN")
shared = os.path.join(H.auth_dir(), "auth.json")
put(os.path.dirname(shared), "auth.json", "OLD-TOKEN")
os.utime(shared, (time.time() - 100, time.time() - 100))
H.stop(home)
is_("start_stop: stop runs daemon stop with CODEX_HOME=<home>", helpers.read_log(LOG)[-1],
    {"argv": ["app-server", "daemon", "stop"], "codex_home": home})
ok("start_stop: the daemon's socket is gone", not os.path.exists(SOCK))
is_("start_stop: a newer auth.json is copied over the shared login", open(shared).read(), "REFRESHED-TOKEN")
is_("start_stop: with mode 600", stat.S_IMODE(os.stat(shared).st_mode), 0o600)
is_("start_stop: and the link is restored", (os.path.islink(auth), os.readlink(auth)), (True, shared))
H.start(hm)
ok("start_stop: after stop, another home may start", os.path.exists(os.path.join(hm, "app-server-control", "app-server-control.sock")))
os.unlink(os.path.join(hm, "auth.json"))
put(hm, "auth.json", "STALE-TOKEN")
os.utime(os.path.join(hm, "auth.json"), (time.time() - 1000, time.time() - 1000))
H.stop(hm)
is_("start_stop: an older auth.json does not replace the shared login", open(shared).read(), "REFRESHED-TOKEN")
ok("start_stop: yet the link is restored", os.path.islink(os.path.join(hm, "auth.json")))
H.start(home)
os.unlink(SOCK)    # the daemon died without a stop, having refreshed its token
os.unlink(auth)
put(home, "auth.json", "CRASHED-TOKEN")
os.utime(os.path.join(home, "auth.json"), (time.time() + 100, time.time() + 100))
H.start(hm)
is_("start_stop: a crashed daemon's refreshed token is carried forward by the next start", open(shared).read(), "CRASHED-TOKEN")
ok("start_stop: and its link is restored", os.path.islink(auth))
ok("one_daemon_at_a_time: a marker whose socket is gone does not block", os.path.exists(os.path.join(hm, "app-server-control", "app-server-control.sock")))
H.stop(hm)
failing = os.path.join(ROOT, "failing-codex")
with open(failing, "w") as f:
    f.write("#!/bin/sh\nif [ \"$3\" = start ]; then mkdir -p \"$CODEX_HOME/app-server-control\"; : > \"$CODEX_HOME/app-server-control/app-server-control.sock\"; exit 0; fi\n"
            "[ -n \"$STOP_REMOVES\" ] && rm -f \"$CODEX_HOME/app-server-control/app-server-control.sock\"\nexit 1\n")
os.chmod(failing, 0o755)
good_bin = os.environ["CODEX_REAL_BIN"]
os.environ["CODEX_REAL_BIN"] = failing
H.start(hm)
ok("start_stop: a failed daemon stop raises", raises(H.stop, hm))
ok("start_stop: and the marker stays while the socket is still there", raises(H.start, home))
os.environ["STOP_REMOVES"] = "1"
ok("start_stop: a failed stop that leaves no socket still raises", raises(H.stop, hm))
ok("start_stop: and then the marker is gone", not os.path.exists(H._marker()))
H.start(home)
del os.environ["STOP_REMOVES"]
os.environ["CODEX_REAL_BIN"] = good_bin
H.stop(home)

# ---- stale_marker: a dead daemon that left its socket does not block another home
H.start(home)
os.unlink(auth)
put(home, "auth.json", "DEAD-TOKEN")
os.utime(os.path.join(home, "auth.json"), (time.time() + 200, time.time() + 200))
H.XR.RPC = DOWN
H.start(hm)
is_("stale_marker: a marker home whose socket does not answer health is settled and passed over",
    (open(shared).read(), os.path.islink(auth), json.load(open(H._marker()))["home"]), ("DEAD-TOKEN", True, hm))
H.XR.RPC = UP
ok("stale_marker: while one that answers still blocks", raises(H.start, home))
H.stop(hm)
os.unlink(os.path.join(home, "app-server-control", "app-server-control.sock"))      # the dead daemon's leftover
# a marker home whose record is gone still counts while it answers
H.start(home)
record = open(os.path.join(home, H.RECORD)).read()
os.unlink(os.path.join(home, H.RECORD))
ok("stale_marker: a marker home without its record, whose daemon answers, still blocks another start", raises(H.start, hm))
ok("stale_marker: and a second daemon was not started", helpers.read_log(LOG)[-1]["codex_home"] == home)
put(home, H.RECORD, record)
H.stop(home)
# a health call that hangs is a daemon that might be alive, for a refresh and for another start alike: neither changes anything
HANG = os.path.join(ROOT, "hang-rpc")
with open(HANG, "w") as f:
    f.write("#!/bin/sh\nexec sleep 60\n")
os.chmod(HANG, 0o755)
H.HEALTH_TIMEOUT = 1
H.start(home)
H.XR.RPC = HANG
t0 = time.time()
ok("stale_marker: a health call that times out blocks a refresh of that home", raises(H.ensure, STATE, "nomem", source=SRC))
os.unlink(auth)         # the daemon refreshed its token, which only a stop (or a confirmed death) takes back
put(home, "auth.json", "BUSY-TOKEN")
os.utime(os.path.join(home, "auth.json"), (time.time() + 300, time.time() + 300))
shared_before = open(shared).read()
daemon_starts = lambda: [c for c in helpers.read_log(LOG) if c["argv"][:3] == ["app-server", "daemon", "start"]]
n_starts = len(daemon_starts())
try:
    H.start(hm)
    refusal = None
except Failed as e:
    refusal = str(e)
# the hung call sleeps 60 s and is cut off at HEALTH_TIMEOUT (1 s here); 30 s is half the sleep, so only a call that is waited out fails the bound,
# however loaded the machine is
ok("stale_marker: a marker home whose health request times out refuses another start, naming that home and the stop", refusal is not None
   and home in refusal and "--stop" in refusal and time.time() - t0 < 30, refusal)
is_("stale_marker: and starts no second daemon", len(daemon_starts()), n_starts)
is_("stale_marker: and the marker still names the home that might be running", json.load(open(H._marker()))["home"], home)
ok("stale_marker: and its login is not settled: the shared login is as it was and the home keeps its own token",
   open(shared).read() == shared_before and not os.path.islink(auth) and open(auth).read() == "BUSY-TOKEN")
H.XR.RPC = UP
H.stop(home)
is_("stale_marker: once that home is stopped its token is taken back", (open(shared).read(), os.path.islink(auth)), ("BUSY-TOKEN", True))
H.start(hm)
ok("stale_marker: and another home starts", json.load(open(H._marker()))["home"] == hm and len(daemon_starts()) == n_starts + 1)
H.stop(hm)
H.HEALTH_TIMEOUT = 15

# ---- refresh_refused_while_running
H.start(home)
before_files = helpers.listing(home)
ok("refresh_refused_while_running: ensure on a home whose daemon answers is refused", raises(H.ensure, STATE, "nomem", source=SRC))
is_("refresh_refused_while_running: and changes nothing", helpers.listing(home), before_files)
H.XR.RPC = DOWN
ok("refresh_refused_while_running: a socket whose daemon does not answer is not running", H.ensure(STATE, "nomem", source=SRC) == home)
H.XR.RPC = UP
H.stop(home)
# a daemon that answers guards a refresh whether or not the home still has its record (a refresh never lands under a live daemon)
H.start(home)
record = open(os.path.join(home, H.RECORD)).read()
os.unlink(os.path.join(home, H.RECORD))
before_files = helpers.listing(home)
ok("refresh_refused_while_running: ensure on a recordless home whose daemon answers is refused", raises(H.ensure, STATE, "nomem", source=SRC))
is_("refresh_refused_while_running: and changes nothing", helpers.listing(home), before_files)
ns = __import__("argparse").Namespace(state=os.path.join(ROOT, "norecord"), dry_run=False, name="nomem", memories=None, use_memories=False, start=True,
                                       stop=False, probe=False, login_cmd=False, codex_source=SRC)
ok("refresh_refused_while_running: cmd_home --start on it is refused too, and writes no record", raises(H.cmd_home, ns) and not os.path.exists(os.path.join(home, H.RECORD)))
put(home, H.RECORD, record)
H.stop(home)

# ---- crashed_run: a daemon left by a run that died is stopped; one a live run holds is not
import contextlib
import io
CHILD = r"""
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from process_replay import codexhome as H
H.start(sys.argv[2])
print("started", flush=True)
if sys.argv[3] == "die":
    os._exit(0)
sys.stdin.read()
"""


def child(mode, which):
    env = dict(os.environ, XREVIEW_REPLAY_RPC=UP)
    proc = subprocess.Popen(["/usr/bin/python3", "-I", "-B", "-c", CHILD, helpers.SCRIPTS, which, mode], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
    first = proc.stdout.readline().strip()
    return proc, first


def stops():
    return [(c["argv"][2], c["codex_home"]) for c in helpers.read_log(LOG) if c["argv"][:2] == ["app-server", "daemon"]]


def said(fn, *a):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        res = fn(*a)
    return res, buf.getvalue()


H.XR.RPC = UP
proc, first = child("wait", home)
is_("crashed_run: a run in another process starts the daemon", (first, os.path.exists(SOCK)), ("started", True))
n_calls = len(stops())
ok("crashed_run: a daemon a live run holds is not reclaimed", raises(H.reclaim, home) and len(stops()) == n_calls)
ok("crashed_run: nor stopped by another home's start", raises(H.start, hm) and len(stops()) == n_calls)
ok("crashed_run: nor by a start of the same home", raises(H.start, home) and len(stops()) == n_calls)
proc.stdin.close()
proc.wait(30)
ok("crashed_run: the run ended without stopping the daemon", os.path.exists(SOCK))
res, out = said(H.reclaim, home)
ok("crashed_run: reclaim stops the daemon nobody holds, and says so", res is True and stops()[-1] == ("stop", home) and not os.path.exists(SOCK)
   and "left running" in out, (res, stops()[-2:], out))
is_("crashed_run: with nothing running it does nothing", (H.reclaim(home), H.reclaim(os.path.join(ROOT, "no-such-home"))), (False, False))
proc, first = child("die", home)
proc.wait(30)
ok("crashed_run: a run that died leaves its daemon and marker", os.path.exists(SOCK) and json.load(open(H._marker()))["home"] == home)
_res, out = said(H.start, hm)
ok("crashed_run: another home's start stops the dead run's daemon first and says so", stops()[-2:] == [("stop", home), ("start", hm)], stops()[-3:])
ok("crashed_run: and the new home runs", json.load(open(H._marker()))["home"] == hm and "left running" in out and not os.path.exists(SOCK), out)
H.stop(hm)
proc, first = child("die", home)
proc.wait(30)
_res, out = said(H.start, home)
ok("crashed_run: starting the same home stops its left daemon, then starts it", stops()[-2:] == [("stop", home), ("start", home)] and "left running" in out, stops()[-3:])
H.stop(home)

# ---- hold: a process using a daemon it did not start keeps it from looking like a crashed run's
CHILD2 = r"""
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from process_replay import codexhome as H
from process_replay.common import Failed
for label, fn, arg in (("reclaim", H.reclaim, sys.argv[2]), ("start", H.start, sys.argv[3])):
    try:
        fn(arg)
        print(label, "went ahead", flush=True)
    except Failed as e:
        print(label, "refused", flush=True)
"""
proc, first = child("die", home)
proc.wait(30)
ok("hold: a run that died leaves its daemon", os.path.exists(SOCK) and first == "started")
n_calls = len(stops())
with H.hold(home):
    got = subprocess.run(["/usr/bin/python3", "-I", "-B", "-c", CHILD2, helpers.SCRIPTS, home, hm], capture_output=True, text=True,
                         env=dict(os.environ, XREVIEW_REPLAY_RPC=UP)).stdout.split("\n")
    is_("hold: while one process holds the daemon, another's reclaim and start of another home refuse", got[:2], ["reclaim refused", "start refused"])
    ok("hold: and neither stopped it", os.path.exists(SOCK) and len(stops()) == n_calls, stops()[n_calls:])
res, out = said(H.reclaim, home)
ok("hold: once the block ends the lock is let go: the daemon is a leftover again", res is True and not os.path.exists(SOCK) and "left running" in out, (res, out))
proc, first = child("wait", home)


def enter_hold():
    with H.hold(home):
        pass


ok("hold: it refuses at once while another process holds the home", raises(enter_hold))
proc.stdin.close()
proc.wait(30)
H.start(home)
with H.hold(home):
    pass
ok("hold: a lock this process holds for the home (it started the daemon) stays held after the block", H._same(H._HELD["home"], home))
H.stop(home)

# ---- probe_record: a probe proves the daemon it ran against, not the next one
put(home, H.PROBED, json.dumps({"at": "2026-11-03T00:00:00Z", "ok": True, "checks": {"daemon": True}, "expect_memories": False}))
is_("probe_record: a passing record is a pass", H.probed(home), (True, ""))
H.start(home)
good, why = H.probed(home)
ok("probe_record: starting the daemon removes it: the home has not been probed since it was started", good is False and "since it was started" in why
   and not os.path.exists(os.path.join(home, H.PROBED)), (good, why))
H.stop(home)

# ---- outside_cxh: a recorded home that is not under $XDG_STATE_HOME/cxh is never stopped
outside = os.path.join(ROOT, "elsewhere", "home")
put(outside, H.RECORD, json.dumps({"source": SRC, "use_memories": False}))
put(outside, "app-server-control/app-server-control.sock", "")
n_calls = len(helpers.read_log(LOG))
ok("outside_cxh: stop refuses a recorded home outside cxh", raises(H.stop, outside))
ok("outside_cxh: reclaim refuses it too, though its socket answers", raises(H.reclaim, outside))
ok("outside_cxh: and no daemon command ran", len(helpers.read_log(LOG)) == n_calls)
link_in = os.path.join(ROOT, "xdg", "cxh", "linked")
os.symlink(outside, link_in)
ok("outside_cxh: nor does a link under cxh that leads out of it", raises(H.stop, link_in) and raises(H.reclaim, link_in))
os.unlink(link_in)

# ---- snapshot_swap
bad = os.path.join(ROOT, "snap-bad")
put(bad, "memory_summary.md", "new")
put(bad, "unreadable.md", "x", mode=0)
H.ensure(STATE, "mem-sw", memories_src=SNAP, use_memories=True, source=SRC)
swhome = H.home_path("mem-sw")
ok("snapshot_swap: a snapshot that cannot be copied raises", raises(H.ensure, STATE, "mem-sw", bad, True, SRC))
ok("snapshot_swap: the old snapshot is untouched and nothing is left beside it",
   open(os.path.join(swhome, "memories", "memory_summary.md")).read() == SUMMARY
   and not any(n.startswith(".memories") for n in os.listdir(swhome)), os.listdir(swhome))
os.chmod(os.path.join(bad, "unreadable.md"), 0o644)
H.ensure(STATE, "mem-sw", memories_src=bad, use_memories=True, source=SRC)
ok("snapshot_swap: a good one replaces it", open(os.path.join(swhome, "memories", "memory_summary.md")).read() == "new"
   and not any(n.startswith(".memories") for n in os.listdir(swhome)))

# ---- probe_checks
def summary_lines():
    return [l.strip() for l in SUMMARY.splitlines() if len(l.strip()) >= 20 and not l.startswith("#")]


def probe_fresh(home_dir, expect, rpc=None):
    """The stubs all name their first thread th1, so a home's earlier rollouts are cleared first."""
    for d in ("sessions", "archived_sessions"):
        shutil.rmtree(os.path.join(home_dir, d), ignore_errors=True)
    return H.probe(home_dir, expect, rpc=rpc)


def rpc_for(name, home_dir, developer, health_rc=0):
    stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-" + name), home_dir,
                            {"default": {"answer": {"verdict": "approve", "findings": []}, "model": "m-9", "effort": "low",
                                         "developer": developer}, "health_rc": health_rc})
    return stub


def rpc_log(stub):
    return helpers.read_log(os.path.join(os.path.dirname(stub), "rpc.log"))


# a daemon-less nomem home: the memory text must be absent
phome = H.ensure(STATE, "p-nomem", source=SRC)
stub = rpc_for("a", phome, "You are Codex. Nothing about the project is remembered.")
res = probe_fresh(phome, False, rpc=stub)
ok("probe_checks: ok when answered, in the home, source untouched, daemon up, no memory text",
   res["ok"] is True and all(res["checks"].values()) and set(res["checks"]) == {"daemon", "answered", "rollout_in_home", "source_untouched",
                                                                              "memories", "source_daemon"}, res)
is_("probe_checks: the model and effort come from the rollout", (res["model"], res["effort"]), ("m-9", "low"))
is_("probe_record: a passing probe is recorded in the home, with the time and the checks, and probed() says so", (H.probed(phome), sorted(json.load(open(os.path.join(phome, H.PROBED)))),
    json.load(open(os.path.join(phome, H.PROBED)))["checks"] == res["checks"]), ((True, ""), ["at", "checks", "expect_memories", "ok"], True))
calls = rpc_log(stub)
ok("probe_checks: the replay calls carry CODEX_HOME=<home>; the source health call carries the source",
   [c["codex_home"] for c in calls if c["cmd"] != "health"] == [phome] * 3 + [phome]
   and [c["codex_home"] for c in calls if c["cmd"] == "health"] == [phome, SRC], calls)
ok("probe_checks: the thread is archived at the end", calls[-1]["cmd"] == "thread-archive")
ok("probe_checks: the turn runs in a temp dir that is gone afterwards",
   calls[1]["cmd"] == "thread-start" and not os.path.exists(calls[1]["cwd"] or ""))
sent = open(os.path.join(os.path.dirname(stub), "inputs", "tu1")).read()
is_("probe_checks: the prompt asks for {\"word\": \"ok\"}", sent.strip(), 'Reply with the JSON object {"word": "ok"}.')
is_("probe_checks: and the probe's schema requires that word", H.PROBE_SCHEMA, {"type": "object", "additionalProperties": False,
    "required": ["word"], "properties": {"word": {"type": "string"}}})
ok("probe_checks: nothing was written under the source home", H._rollouts(SRC, "th1") == [])

# memories present exactly when expected
lines3 = summary_lines()[:3]
phm = H.ensure(STATE, "p-mem", memories_src=SNAP, use_memories=True, source=SRC)
stub = rpc_for("b", phm, "Memory:\n" + "\n".join(lines3))
res = probe_fresh(phm, True, rpc=stub)
ok("probe_checks: ok for a memories home whose developer message holds the lines", res["ok"] is True, res)
stub = rpc_for("c", phm, "Memory:\n" + "\n".join(lines3[:2]))
res = probe_fresh(phm, True, rpc=stub)
ok("probe_checks: a missing memory line fails the memories check only", res["ok"] is False and res["checks"]["memories"] is False
   and sum(1 for v in res["checks"].values() if not v) == 1, res)
stub = rpc_for("d", phome, "Memory:\n" + "\n".join(lines3))
res = probe_fresh(phome, False, rpc=stub)
ok("probe_checks: memory text in a nomem home fails", res["ok"] is False and res["checks"]["memories"] is False, res)
good, why = H.probed(phome)
ok("probe_record: a failing probe is recorded as failing, naming the check", good is False and "memories" in why, (good, why))
stub = rpc_for("e", phome, "Memory:\n" + lines3[0])
res = probe_fresh(phome, False, rpc=stub)
ok("probe_checks: even one memory line in a nomem home fails", res["checks"]["memories"] is False, res)
stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-w"), phome, {"default": {"answer": {}, "developer": "plain",
                       "tools": [{"name": "exec", "arguments": {"cmd": "echo " + lines3[1]}}]}})
res = probe_fresh(phome, False, rpc=stub)
ok("probe_checks: for a home with no memories, memory text anywhere in the rollout fails", res["checks"]["memories"] is False, res)
stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-w2"), phm, {"default": {"answer": {}, "developer": "plain",
                        "tools": [{"name": "exec", "arguments": {"cmd": "echo " + lines3[1]}}]}})
res = probe_fresh(phm, True, rpc=stub)
ok("probe_checks: but a memories home needs it in the developer message", res["checks"]["memories"] is False, res)
qsrc = make_source("src-q", links=False)
QUOTED = 'Run "make test" before pushing any branch to origin, and mind the C:\\\\path too.'
put(qsrc, "memories/memory_summary.md", "# s\n\n" + QUOTED + "\nshort one\n")
qhome = H.ensure(STATE, "p-q", source=qsrc)
for where, spec in (("a tool call", {"tools": [{"name": "exec", "arguments": {"cmd": QUOTED}}]}),
                    ("a developer message", {"developer": "x" + QUOTED + "y"})):
    stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-q" + where[:4]), qhome, {"default": dict({"answer": {}}, **spec)})
    res = probe_fresh(qhome, False, rpc=stub)
    ok("probe_checks: a memory line with quotes and a backslash is found in " + where, res["checks"]["memories"] is False, res)
# a tool's output: records the stub cannot write, appended to the rollout by a wrapper after turn-wait
for kind, payload in (("function_call_output", {"type": "function_call_output", "call_id": "c1", "output": QUOTED}),
                      ("function_call_output holding JSON", {"type": "function_call_output", "call_id": "c1",
                                                              "output": json.dumps({"output": QUOTED, "metadata": {}})}),
                      ("custom_tool_call_output", {"type": "custom_tool_call_output", "call_id": "c2", "output": QUOTED})):
    tag = kind.replace(" ", "_")
    rec = os.path.join(ROOT, "rec-" + tag)
    with open(rec, "w") as f:
        f.write(json.dumps({"type": "response_item", "payload": payload}) + "\n")
    inner = helpers.stub_rpc(os.path.join(ROOT, "rpc-o" + tag), qhome, {"default": {"answer": {}, "developer": "plain"}})
    wrap = os.path.join(ROOT, "out-rpc-" + tag)
    with open(wrap, "w") as f:
        f.write("#!/bin/sh\n%s \"$@\"\nrc=$?\nif [ \"$1\" = turn-wait ]; then cat %s >> \"$CODEX_HOME/sessions/2026/10/20/rollout-2026-10-20T10-00-00-th1.jsonl\"; fi\nexit $rc\n" % (inner, rec))
    os.chmod(wrap, 0o755)
    res = probe_fresh(qhome, False, rpc=wrap)
    ok("probe_checks: a memory line in a {} record is found".format(kind), res["checks"]["memories"] is False, res)
envlog = os.path.join(ROOT, "env.log")
envwrap = os.path.join(ROOT, "env-rpc")
envinner = rpc_for("x", phome, "plain")
with open(envwrap, "w") as f:
    f.write("#!/bin/sh\necho \"${XREVIEW_RPC_SOCK-unset} ${XREVIEW_RPC_STDIO-unset}\" >> %s\nexec %s \"$@\"\n" % (envlog, envinner))
os.chmod(envwrap, 0o755)
os.environ["XREVIEW_RPC_SOCK"] = "/elsewhere/sock"
os.environ["XREVIEW_RPC_STDIO"] = "/bin/false"
probe_fresh(phome, False, rpc=envwrap)
del os.environ["XREVIEW_RPC_SOCK"]
del os.environ["XREVIEW_RPC_STDIO"]
is_("probe_checks: an inherited XREVIEW_RPC_SOCK or XREVIEW_RPC_STDIO never reaches the rpc", set(open(envlog).read().split()), {"unset"})
stub = rpc_for("f", phome, "nothing")
res = probe_fresh(phome, True, rpc=stub)
ok("probe_checks: expecting memories but finding none fails", res["ok"] is False and res["checks"]["memories"] is False, res)

# the answer: a failed turn
stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-g"), phome, {"default": {"rc": 1}})
res = probe_fresh(phome, False, rpc=stub)
ok("probe_checks: a turn that did not answer fails", res["ok"] is False and res["checks"]["answered"] is False, res)
stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-g2"), phome, {"default": {"rc": 4, "raw": "ok"}})
res = probe_fresh(phome, False, rpc=stub)
ok("probe_checks: a schema mismatch is still an answer", res["checks"]["answered"] is True, res)
stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-g3"), phome, {})
res = probe_fresh(phome, False, rpc=stub)
ok("probe_checks: a turn-start that fails fails the answer, and the thread is still archived",
   res["checks"]["answered"] is False and rpc_log(stub)[-1]["cmd"] == "thread-archive", res)

# the daemon down
stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-h"), phome, {"health_rc": 5, "default": {"answer": {}}})
res = probe_fresh(phome, False, rpc=stub)
ok("probe_checks: a replay daemon that does not answer fails at once, with no turn",
   res["ok"] is False and res["checks"] == {"daemon": False} and [c["cmd"] for c in rpc_log(stub)] == ["health"], res)

# rollout under the wrong home: an rpc that talks to the source home's daemon
wrapper = os.path.join(ROOT, "leaky-rpc")
inner = helpers.stub_rpc(os.path.join(ROOT, "rpc-i"), SRC, {"default": {"answer": {"verdict": "approve", "findings": []}}})
with open(wrapper, "w") as f:
    f.write("#!/bin/sh\nCODEX_HOME={}\nexport CODEX_HOME\nexec {} \"$@\"\n".format(SRC, inner))
os.chmod(wrapper, 0o755)
res = probe_fresh(phome, False, rpc=wrapper)
ok("probe_checks: a rollout under the source home fails the probe, and the home check too",
   res["ok"] is False and res["checks"]["source_untouched"] is False and res["checks"]["rollout_in_home"] is False, res)
for p in H._rollouts(SRC, "th1"):
    os.unlink(p)
# an unrelated rollout appearing under the source home (Michael's own daemon) does not
put(SRC, "sessions/2026/11/02/rollout-2026-11-02T10-00-00-someone-else.jsonl", "{}\n")
stub = rpc_for("j", phome, "plain")
ok("probe_checks: a rollout of another thread under the source home is not a leak", probe_fresh(phome, False, rpc=stub)["checks"]["source_untouched"] is True)

# the source daemon down
guard = os.path.join(ROOT, "guard-rpc")
inner = rpc_for("k", phome, "plain")
with open(guard, "w") as f:
    f.write("#!/bin/sh\nif [ \"$1\" = health ] && [ \"$CODEX_HOME\" = \"{}\" ]; then exit 5; fi\nexec {} \"$@\"\n".format(SRC, inner))
os.chmod(guard, 0o755)
res = probe_fresh(phome, False, rpc=guard)
ok("probe_checks: a source daemon that stops answering fails the probe",
   res["ok"] is False and res["checks"]["source_daemon"] is False and res["checks"]["answered"] is True, res)
ok("probe_checks: a directory that is not a replay home is refused", raises(H.probe, SRC, False, rpc=stub))

# ---- the command
sys.argv = ["process-replay.py"]
ap_mod = __import__("argparse")
ap = ap_mod.ArgumentParser()
ap.add_argument("--state")
ap.add_argument("--dry-run", action="store_true")
H.add_args(ap)
a = ap.parse_args(["--state", os.path.join(ROOT, "cmd-state"), "--login-cmd"])
import io
import contextlib
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = H.cmd_home(a)
is_("cmd_home: --login-cmd prints the login command", (rc, buf.getvalue().strip()), (0, H.login_cmd()))
a = ap.parse_args(["--state", os.path.join(ROOT, "cmd-state"), "--name", "nomem", "--codex-source", SRC, "--dry-run", "--start", "--probe"])
n = len(helpers.read_log(LOG))
with contextlib.redirect_stdout(io.StringIO()):
    rc = H.cmd_home(a)
ok("cmd_home: --dry-run makes no registry and starts nothing", rc == 0 and not os.path.exists(os.path.join(ROOT, "cmd-state", "codex-homes.json"))
   and len(helpers.read_log(LOG)) == n)
a = ap.parse_args(["--state", os.path.join(ROOT, "cmd-state"), "--name", "nomem", "--codex-source", SRC, "--start", "--stop"])
with contextlib.redirect_stdout(io.StringIO()):
    rc = H.cmd_home(a)
log = helpers.read_log(LOG)[n:]
cmdhome = os.path.join(ROOT, "xdg", "cxh", "nomem")
is_("cmd_home: --name --start --stop makes the home, starts and stops its daemon", (rc, [(l["argv"][2], l["codex_home"]) for l in log]),
    (0, [("start", cmdhome), ("stop", cmdhome)]))
ok("cmd_home: --name without --login-cmd or a name is refused", raises(H.cmd_home, ap.parse_args(["--state", ROOT])))

def run_cmd(*argv, state="cmd-state"):
    with contextlib.redirect_stdout(io.StringIO()):
        return H.cmd_home(ap.parse_args(["--state", os.path.join(ROOT, state)] + list(argv)))


SNAP2 = os.path.join(ROOT, "snap2")
put(SNAP2, "memory_summary.md", "second\n")
cfg_of = lambda h: open(os.path.join(h, "config.toml")).read()
run_cmd("--name", "mem-cmd", "--codex-source", SRC, "--memories", SNAP, "--use-memories")
cmem = os.path.join(ROOT, "xdg", "cxh", "mem-cmd")
put(cmem, "plugins/stale", "x")
run_cmd("--name", "mem-cmd")
ok("cmd_home: an existing home is refreshed again and keeps its memories and setting",
   not os.path.exists(os.path.join(cmem, "plugins", "stale")) and os.path.exists(os.path.join(cmem, "memories", "memory_summary.md"))
   and "use_memories = true" in cfg_of(cmem), cfg_of(cmem))
run_cmd("--name", "mem-cmd", "--memories", SNAP2)
ok("cmd_home: --memories replaces the snapshot but keeps the recorded use_memories",
   open(os.path.join(cmem, "memories", "memory_summary.md")).read() == "second\n" and "use_memories = true" in cfg_of(cmem)
   and json.load(open(os.path.join(cmem, H.RECORD)))["use_memories"] is True, cfg_of(cmem))
shutil.rmtree(os.path.join(cmem, "memories"))
cfg_before = cfg_of(cmem)
ok("cmd_home: a home that wants memories but has none, and no --memories, is refused", raises(run_cmd, "--name", "mem-cmd"))
ok("cmd_home: and nothing flipped", cfg_of(cmem) == cfg_before)
is_("cmd_home: and it is listed in the state's codex-homes.json", H_json(os.path.join(ROOT, "cmd-state", "codex-homes.json")).get("mem-cmd"), cmem)

# --stop and --probe leave a home's files alone; --stop works on a broken home
def files_of(h):
    return [f for f in helpers.listing(h) if not f[0].startswith(("sessions", "archived_sessions", "app-server-control"))]


run_cmd("--name", "nomem", "--codex-source", SRC, "--start")
nm = os.path.join(ROOT, "xdg", "cxh", "nomem")
os.utime(os.path.join(nm, "plugins", "f.txt"), (1000, 1000))
files = files_of(nm)
run_cmd("--name", "nomem", "--probe", state="cmd-state2")
is_("cmd_home: --probe leaves the home's files as they were, but for its own record", [f for f in files_of(nm) if f[0] != H.PROBED], [f for f in files if f[0] != H.PROBED])
ok("cmd_home: ... which it writes", os.path.exists(os.path.join(nm, H.PROBED)))
is_("cmd_home: and registers the home in this state's codex-homes.json", H_json(os.path.join(ROOT, "cmd-state2", "codex-homes.json")), {"nomem": nm})
n_stop = len(helpers.read_log(LOG))
os.unlink(os.path.join(nm, "config.toml"))
shutil.rmtree(os.path.join(nm, "plugins"))
files = files_of(nm)
run_cmd("--name", "nomem", "--stop")
is_("cmd_home: --stop on a home with broken files still stops its daemon",
    [(l["argv"][2], l["codex_home"]) for l in helpers.read_log(LOG)[n_stop:]], [("stop", nm)])
is_("cmd_home: and leaves the files as they were", files_of(nm), files)
ok("cmd_home: --probe on a name that is no home is refused", raises(run_cmd, "--name", "nowhere", "--probe"))

# a refresh under a running daemon is refused unless it is stopped first
run_cmd("--name", "nomem", "--codex-source", SRC, "--start")
ok("cmd_home: a refresh of a running home is refused", raises(run_cmd, "--name", "nomem"))
n_stop = len(helpers.read_log(LOG))
run_cmd("--name", "nomem", "--stop", "--memories", SNAP)
ok("cmd_home: unless --stop comes with it: stopped, then refreshed",
   [l["argv"][2] for l in helpers.read_log(LOG)[n_stop:]] == ["stop"] and os.path.exists(os.path.join(nm, "memories", "memory_summary.md"))
   and os.path.isdir(os.path.join(nm, "plugins")))

# a crash between the two renames of a snapshot swap: memories gone, the old copy beside it
run_cmd("--name", "mem-cmd", "--memories", SNAP2)
os.rename(os.path.join(cmem, "memories"), os.path.join(cmem, ".memories.old"))
run_cmd("--name", "mem-cmd")
ok("cmd_home: a refresh puts a crashed swap's old snapshot back first, so a home that wants memories keeps them",
   open(os.path.join(cmem, "memories", "memory_summary.md")).read() == "second\n" and not os.path.exists(os.path.join(cmem, ".memories.old"))
   and "use_memories = true" in cfg_of(cmem), os.listdir(cmem))
