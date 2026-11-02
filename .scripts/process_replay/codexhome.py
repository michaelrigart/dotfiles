"""Replay Codex homes (spec section 7.2, ruling R1): a second app-server daemon with its own CODEX_HOME,
one home per memories setting. `nomem` serves the runs that must not see memories; `mem-<hash12>` holds
one snapshot of the memories directory. Every home logs in through one shared login of its own
(auth_dir), never Michael's, so no replay daemon rotates the token of his daemon and no replay rollout
lands in ~/.codex, where it could feed memory generation.

  $XDG_STATE_HOME/cxh/<name>/      the home (a short undated root: its socket path must fit the 103 bytes a
                                   unix socket allows), listed in <state>/codex-homes.json (name -> path);
                                   mode 700; config.toml (the source's, with a [memories] table),
                                   AGENTS.md, skills/rules/plugins as links, auth.json as a link into
                                   auth_dir, memories/ (a snapshot, when given), replay-home.json (its record)
  $XDG_STATE_HOME/process-replay/codex-auth/   the shared login; daemon.json names the home running now

At most one replay daemon runs at a time. While one runs, Codex replaces its auth.json link with a
regular file when it refreshes the token; `stop` (and the next `ensure`) copies that file back to the
shared login when newer and restores the link.

Nothing here reads the source home's auth.json or writes below the source home.
"""
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import time

from . import common
from .common import Failed, XR, jload, jsave, say

RECORD = "replay-home.json"
LINKED = ("skills", "rules", "plugins")
SOCKET = os.path.join("app-server-control", "app-server-control.sock")
SOCKET_LIMIT = 103      # bytes a unix socket path may have on macOS
PROMPT = "Reply with the single word ok.\n"
PROBE_SCHEMA = {"type": "object"}
PROBE_BUDGET = 600
DAEMON_TIMEOUT = 180
MEMORY_LINES = 3


# ------------------------------------------------------------------ paths
def auth_dir():
    return os.path.join(common.L.state_home(), "process-replay", "codex-auth")


def _auth_file():
    return os.path.join(auth_dir(), "auth.json")


def _marker():
    return os.path.join(auth_dir(), "daemon.json")


def home_path(name):
    common._check_id(name)
    return os.path.join(common.L.state_home(), "cxh", name)


def _default_source():
    return os.path.expanduser("~/.codex")


def _socket(home):
    return os.path.join(home, SOCKET)


def real_bin():
    """The real Codex binary: CODEX_REAL_BIN, else what `codex-daemon real-bin` prints."""
    env = os.environ.get("CODEX_REAL_BIN")
    if env:
        return env
    script = os.path.join(common.SCRIPTS, "..", "dot_local", "bin", "executable_codex-daemon")
    if not os.path.isfile(script):
        script = os.path.expanduser("~/.local/bin/codex-daemon")
    p = subprocess.run(["/bin/sh", script, "real-bin"], capture_output=True)
    out = p.stdout.decode("utf-8", "replace").strip()
    if p.returncode != 0 or not out:
        raise Failed("cannot find the real codex binary (set CODEX_REAL_BIN): " + p.stderr.decode("utf-8", "replace").strip())
    return out


def login_cmd():
    return "CODEX_HOME={} {} login".format(shlex.quote(auth_dir()), shlex.quote(real_bin()))


# ------------------------------------------------------------------ the home
def _memories_config(text, use):
    """`text` with a [memories] table holding use_memories and generate_memories = false. Textual: the
    table's other keys, comments and every other table stay as they were."""
    lines = text.splitlines()
    head = None
    for i, line in enumerate(lines):
        if re.match(r"\s*\[memories\]\s*(#.*)?$", line):
            head = i
            break
    own = ["use_memories = " + ("true" if use else "false"), "generate_memories = false"]
    if head is None:
        out = lines + ([""] if lines and lines[-1].strip() else []) + ["[memories]"] + own
    else:
        end = len(lines)
        for j in range(head + 1, len(lines)):
            if re.match(r"\s*\[", lines[j]):
                end = j
                break
        kept = [l for l in lines[head + 1:end] if not re.match(r"\s*(use_memories|generate_memories)\s*=", l)]
        out = lines[:head + 1] + own + kept + lines[end:]
    return "\n".join(out) + "\n"


def _link(target, path):
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)
    os.symlink(target, path)


def _settle_auth(home):
    """Make <home>/auth.json a link to the shared login. A regular file there is a refreshed token:
    it replaces the shared login when newer."""
    link, target = os.path.join(home, "auth.json"), _auth_file()
    if os.path.isfile(link) and not os.path.islink(link):
        if not os.path.exists(target) or os.stat(link).st_mtime > os.stat(target).st_mtime:
            fd, tmp = tempfile.mkstemp(prefix=".auth.", dir=auth_dir())
            try:
                with os.fdopen(fd, "wb") as out, open(link, "rb") as src:
                    out.write(src.read())
                os.chmod(tmp, 0o600)
                os.replace(tmp, target)
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)
    if os.path.islink(link) and os.readlink(link) == target:
        return
    if os.path.lexists(link):
        os.unlink(link)
    os.symlink(target, link)


def ensure(state, name, memories_src=None, use_memories=False, source=None):
    """The replay home $XDG_STATE_HOME/cxh/<name>, made or brought up to date and recorded in
    <state>/codex-homes.json; returns its path.
    Sessions, sqlite and the rest of what the daemon creates are left alone, so an existing home keeps
    its rollouts."""
    source = os.path.abspath(source or _default_source())
    home = home_path(name)
    real_home, real_source = os.path.realpath(home), os.path.realpath(source)
    if real_home == real_source or real_home.startswith(real_source + os.sep):
        raise Failed("{} is the source home or lies inside it: a replay home never is".format(home))
    if memories_src is not None and os.path.realpath(memories_src) == os.path.join(real_source, "memories"):
        raise Failed("{} is the live memories directory: give a snapshot".format(memories_src))
    if len(_socket(home).encode("utf-8")) > SOCKET_LIMIT:
        raise Failed("the daemon socket {} would be over {} bytes, more than a unix socket allows: use a shorter XDG_STATE_HOME".format(
            _socket(home), SOCKET_LIMIT))
    if use_memories and memories_src is None:
        raise Failed("use_memories needs a memories snapshot")
    config = os.path.join(source, "config.toml")
    if not os.path.isfile(config):
        raise Failed("the source home has no config.toml: " + config)
    if memories_src is not None and not os.path.isdir(memories_src):
        raise Failed("not a directory: " + memories_src)
    with open(config, encoding="utf-8") as f:
        text = f.read()
    os.makedirs(home, exist_ok=True)
    os.chmod(home, 0o700)
    os.makedirs(auth_dir(), exist_ok=True)
    os.chmod(auth_dir(), 0o700)
    jsave(os.path.join(home, "config.toml"), _memories_config(text, use_memories))
    os.chmod(os.path.join(home, "config.toml"), 0o600)
    agents = os.path.join(source, "AGENTS.md")
    if os.path.isfile(agents):
        shutil.copyfile(agents, os.path.join(home, "AGENTS.md"))
    for item in LINKED:
        if os.path.exists(os.path.join(source, item)):
            _link(os.path.join(real_source, item), os.path.join(home, item))
    _settle_auth(home)
    mem = os.path.join(home, "memories")
    if os.path.lexists(mem):
        if os.path.isdir(mem) and not os.path.islink(mem):
            shutil.rmtree(mem)
        else:
            os.unlink(mem)
    if memories_src is not None:
        shutil.copytree(memories_src, mem, symlinks=True, ignore=shutil.ignore_patterns(".git"))
    jsave(os.path.join(home, RECORD), {"source": source, "use_memories": bool(use_memories)})
    registry = os.path.join(state, "codex-homes.json")
    homes = jload(registry) or {}
    homes[name] = home
    jsave(registry, homes)
    return home


def _record(home):
    rec = jload(os.path.join(home, RECORD))
    if not isinstance(rec, dict) or not rec.get("source"):
        raise Failed("{} is not a replay home (no {}): refusing to touch it".format(home, RECORD))
    return rec


# ------------------------------------------------------------------ the daemon
def _daemon_env(home):
    env = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_")}
    env["CODEX_HOME"] = home
    return env


def _daemon(home, verb):
    try:
        p = subprocess.run([real_bin(), "app-server", "daemon", verb], env=_daemon_env(home), capture_output=True,
                           timeout=DAEMON_TIMEOUT)
    except (OSError, subprocess.SubprocessError) as e:
        raise Failed("daemon {} failed: {}".format(verb, e))
    if p.returncode != 0:
        raise Failed("daemon {} failed ({}): {}".format(verb, p.returncode, p.stderr.decode("utf-8", "replace").strip()))


def _running_elsewhere(home):
    cur = jload(_marker())
    other = cur.get("home") if isinstance(cur, dict) else None
    if other and os.path.realpath(other) != os.path.realpath(home) and os.path.exists(_socket(other)):
        return other
    return None


def start(home):
    """Start the replay daemon of `home`. One at a time: a second home is refused while another runs."""
    _record(home)
    other = _running_elsewhere(home)
    if other:
        raise Failed("the replay daemon of {} is running: stop it first".format(other))
    os.makedirs(auth_dir(), exist_ok=True)
    _daemon(home, "start")
    jsave(_marker(), {"home": home})


def stop(home):
    """Stop the replay daemon of `home`, then take back a refreshed login."""
    _record(home)
    try:
        _daemon(home, "stop")
    finally:
        _settle_auth(home)
        cur = jload(_marker())
        if isinstance(cur, dict) and cur.get("home") == home:
            os.unlink(_marker())


# ------------------------------------------------------------------ the probe
def _call(rpc, home, *args):
    """(rc, stdout, stderr) of one xreview-rpc call against the daemon of `home`."""
    exe = rpc or XR.RPC
    argv = [exe] if os.access(exe, os.X_OK) else ["/usr/bin/python3", "-I", exe]
    env = dict(os.environ, CODEX_HOME=home)
    try:
        p = subprocess.run(argv + list(args), capture_output=True, env=env, timeout=PROBE_BUDGET + 60)
    except (OSError, subprocess.SubprocessError) as e:
        return 1, "", str(e)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def _rollouts(home, thread):
    found = []
    for sub in ("sessions", "archived_sessions"):
        base = glob.escape(os.path.join(home, sub))
        found += glob.glob(os.path.join(base, "**", "rollout-*-" + glob.escape(thread) + ".jsonl*"), recursive=True)
    return sorted(found)


def _read_rollout(path):
    """(model, effort, [developer message text]) of a plain rollout."""
    model = effort = None
    texts = []
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return model, effort, texts
    for line in raw.splitlines():
        try:
            rec = json.loads(line.decode("utf-8"))
        except ValueError:
            continue
        p = rec.get("payload") if isinstance(rec, dict) and isinstance(rec.get("payload"), dict) else {}
        if rec.get("type") == "turn_context":
            model, effort = p.get("model") or model, p.get("effort") or effort
        elif rec.get("type") == "response_item" and p.get("type") == "message" and p.get("role") == "developer":
            for part in p.get("content") or []:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    texts.append(part["text"])
    return model, effort, texts


def _memory_lines(summary):
    """Up to three of the longest distinct lines of a memory summary: what a developer message holds
    only when that memory reached the model."""
    try:
        with open(summary, encoding="utf-8") as f:
            lines = {l.strip() for l in f if len(l.strip()) >= 20 and not l.lstrip().startswith("#")}
    except OSError:
        return []
    return sorted(lines, key=lambda l: (-len(l), l))[:MEMORY_LINES]


def probe(home, expect_memories, rpc=None):
    """Prove the isolation before any replay turn runs: one turn on the replay daemon, which must
    answer, leave its rollout under `home` and none under the source home, leave the source home's own
    daemon answering, and show the memory text in its developer message exactly when `expect_memories`.
    `rpc` is an xreview-rpc to use (default: the replay's). Returns {ok, checks, model, effort, notes}."""
    source = _record(home)["source"]
    checks, notes, res = {}, [], {"model": None, "effort": None}

    def done():
        res.update(ok=bool(checks) and all(checks.values()), checks=checks, notes=notes)
        return res

    rc, _out, err = _call(rpc, home, "health")
    checks["daemon"] = rc == 0
    if rc != 0:
        notes.append("the replay daemon does not answer health ({}): {}".format(rc, err.strip()))
        return done()
    work = tempfile.mkdtemp(prefix="probe.")
    thread = None
    try:
        rc, out, err = _call(rpc, home, "thread-start", "--cwd", work)
        thread = out.strip().splitlines()[-1] if rc == 0 and out.strip() else None
        if thread is None:
            checks["answered"] = False
            notes.append("thread-start failed ({}): {}".format(rc, err.strip()))
            return done()
        packet, schema = os.path.join(work, "packet.txt"), os.path.join(work, "schema.json")
        jsave(packet, PROMPT)
        jsave(schema, PROBE_SCHEMA)
        rc, out, err = _call(rpc, home, "turn-start", "--thread", thread, "--input", packet, "--schema", schema, "--cwd", work)
        answered, turn = False, out.strip().splitlines()[-1] if rc == 0 and out.strip() else None
        if turn is None:
            notes.append("turn-start failed ({}): {}".format(rc, err.strip()))
        else:
            deadline = time.time() + PROBE_BUDGET
            while True:
                left = max(1, int(deadline - time.time()))
                rc, out, err = _call(rpc, home, "turn-wait", "--thread", thread, "--turn", turn, "--budget", str(left),
                                     "--schema", schema)
                if rc != 3 or time.time() >= deadline:
                    break
            answered = rc in (0, 4)
            if rc == 4:
                notes.append("the answer did not match the minimal schema (it did answer)")
            elif rc != 0:
                notes.append("turn-wait failed ({}): {}".format(rc, err.strip()))
        checks["answered"] = answered
        mine = _rollouts(home, thread)
        checks["rollout_in_home"] = bool(mine) and all(
            os.path.realpath(p).startswith(os.path.realpath(home) + os.sep) for p in mine)
        if not mine:
            notes.append("no rollout of the probe thread under the replay home")
        leaked = _rollouts(source, thread)
        checks["source_untouched"] = not leaked
        if leaked:
            notes.append("the probe thread has a rollout under the source home: " + ", ".join(leaked))
        if mine:
            res["model"], res["effort"], texts = _read_rollout(mine[-1])
        else:
            texts = []
        wanted = _memory_lines(os.path.join(home if expect_memories else source, "memories", "memory_summary.md"))
        if not wanted:
            notes.append("no memory lines to look for in {} memory_summary.md".format("the replay home's" if expect_memories else "the source's"))
        shown = ["\n".join(texts).find(l) >= 0 for l in wanted]
        checks["memories"] = (bool(shown) and all(shown)) if expect_memories else not any(shown)
        if not checks["memories"]:
            notes.append("memory lines {} in the developer message while expect_memories is {}".format(
                "missing" if expect_memories else "present", expect_memories))
        src_rc = _call(rpc, source, "health")[0]
        checks["source_daemon"] = src_rc == 0
        if src_rc != 0:
            notes.append("health on the source home's socket failed ({})".format(src_rc))
    finally:
        if thread is not None:
            _call(rpc, home, "thread-archive", "--thread", thread)
        shutil.rmtree(work, ignore_errors=True)
    return done()


# ------------------------------------------------------------------ the command
def add_args(ap):
    ap.add_argument("--name", help="the home's name: nomem, or mem-<hash12> for one snapshot")
    ap.add_argument("--memories", metavar="DIR", help="a memories snapshot to copy into the home")
    ap.add_argument("--use-memories", action="store_true", help="let the home's turns read its memories")
    ap.add_argument("--start", action="store_true", help="start the home's app-server daemon")
    ap.add_argument("--stop", action="store_true", help="stop it and take back a refreshed login")
    ap.add_argument("--probe", action="store_true", help="prove the isolation with one turn")
    ap.add_argument("--login-cmd", action="store_true", help="print the command that logs the shared login in")
    ap.add_argument("--codex-source", default="~/.codex", help="the home whose config the replay homes copy")


def cmd_home(a):
    if a.login_cmd:
        if not a.dry_run:
            os.makedirs(auth_dir(), exist_ok=True)
            os.chmod(auth_dir(), 0o700)
        say(login_cmd())
        return 0
    if not a.name:
        raise Failed("home needs --name (or --login-cmd)")
    source = os.path.expanduser(a.codex_source)
    home = home_path(a.name)
    if a.dry_run:
        say("would use the replay home {} (source {})".format(home, source))
        return 0
    if a.memories or a.use_memories or not os.path.isfile(os.path.join(home, RECORD)):
        home = ensure(a.state, a.name, a.memories, a.use_memories, source)
        say("home: " + home)
    status = 0
    if a.start:
        start(home)
        say("started: " + home)
    if a.probe:
        res = probe(home, bool(_record(home).get("use_memories")))
        say(json.dumps(res, indent=2))
        status = 0 if res["ok"] else 1
    if a.stop:
        stop(home)
        say("stopped: " + home)
    return status
