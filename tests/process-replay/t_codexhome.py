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

SUMMARY = ("# Memory summary\n\nThe deploy script lives in bin/deploy-zebra and needs the --quiet flag.\n"
           "Reviews of the quokka module always hit the same off-by-one in the tail.\n"
           "Michael prefers fixture names that start with an unusual marker word: plinth.\n\nshort\n")
CONFIG = ('model = "m-1"\n\n[features]\nmemories = true\n\n[memories]\nuse_memories = true\nmax_items = 7  # keep\n'
          'generate_memories = true\n\n[mcp_servers.x]\ncommand = "x"\n')


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
ok("home_config: skills, rules and plugins are links to the source's",
   all(os.path.islink(os.path.join(home, d)) and os.path.realpath(os.path.join(home, d)) == os.path.realpath(os.path.join(SRC, d))
       for d in ("skills", "rules", "plugins")))
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

# ---- home_short_path
is_("home_short_path: the registry lists the homes by name", H_json(os.path.join(STATE, "codex-homes.json")).get("nomem"), home)
sock_len = len(os.path.join("/Users/michael/.local/state", "cxh", "mem-0123456789ab", H.SOCKET).encode("utf-8"))
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
os.unlink(SOCK)    # the daemon died without a stop
H.start(hm)
ok("one_daemon_at_a_time: a marker whose socket is gone does not block", os.path.exists(os.path.join(hm, "app-server-control", "app-server-control.sock")))
H.stop(hm)

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
calls = rpc_log(stub)
ok("probe_checks: the replay calls carry CODEX_HOME=<home>; the source health call carries the source",
   [c["codex_home"] for c in calls if c["cmd"] != "health"] == [phome] * 3 + [phome]
   and [c["codex_home"] for c in calls if c["cmd"] == "health"] == [phome, SRC], calls)
ok("probe_checks: the thread is archived at the end", calls[-1]["cmd"] == "thread-archive")
ok("probe_checks: the turn runs in a temp dir that is gone afterwards",
   calls[1]["cmd"] == "thread-start" and not os.path.exists(calls[1]["cwd"] or ""))
sent = open(os.path.join(os.path.dirname(stub), "inputs", "tu1")).read()
is_("probe_checks: the prompt is the single word ok", sent.strip(), "Reply with the single word ok.")
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
stub = rpc_for("e", phome, "Memory:\n" + lines3[0])
res = probe_fresh(phome, False, rpc=stub)
ok("probe_checks: even one memory line in a nomem home fails", res["checks"]["memories"] is False, res)
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
