"""Replay Codex homes (spec section 7.2, ruling R1): a second app-server daemon with its own CODEX_HOME,
one home per memories setting. `nomem` serves the runs that must not see memories; `mem-<hash12>` holds
one snapshot of the memories directory. Every home logs in through one shared login of its own
(auth_dir), never Michael's, so no replay daemon rotates the token of his daemon and no replay rollout
lands in ~/.codex, where it could feed memory generation.

  $XDG_STATE_HOME/cxh/<name>/      the home (a short undated root: its socket path must fit the 103 bytes a
                                   unix socket allows), listed in <state>/codex-homes.json (name -> path);
                                   mode 700; config.toml (the source's without its notify command, with a
                                   [memories] table), AGENTS.md, skills/rules/plugins as copies (the daemon
                                   writes into them at run time, so none may link into the source home),
                                   auth.json as a link into auth_dir, memories/ (a snapshot, when given),
                                   replay-home.json (its record)
  $XDG_STATE_HOME/process-replay/codex-auth/   the shared login; daemon.json names the home running now

At most one replay daemon runs at a time, and a process that starts one holds an flock on <auth_dir>/run.lock until it
stops it; a process that only uses a daemon (the loop's `run`) holds it for as long as it does (hold). A daemon that answers
while no process holds that lock was left by a run that died: `start` and `reclaim` stop it (and say so) rather than refuse. While one runs, Codex replaces its auth.json link with a
regular file when it refreshes the token; `stop` (and the next `ensure`) copies that file back to the
shared login when newer and restores the link.

Nothing here reads the source home's auth.json or writes below the source home.
"""
import contextlib
import fcntl
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
PROBED = "probe.json"       # the result of the last probe of a home; start() removes it
COPIED = ("skills", "rules", "plugins")
CLONED = ("plugins",)      # copied as an APFS clone when possible: it is large
SOCKET = os.path.join("app-server-control", "app-server-control.sock")
SOCKET_LIMIT = 103      # bytes a unix socket path may have on macOS
PROMPT = 'Reply with the JSON object {"word": "ok"}.\n'
PROBE_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["word"],
                "properties": {"word": {"type": "string"}}}
PROBE_BUDGET = 600
HEALTH_TIMEOUT = 15
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


def _without_notify(text):
    """`text` without its top-level `notify` key (a command Codex runs after a turn): replay turns run
    no notifier. The key may span lines; a `notify` inside a table is another key and stays."""
    out, skipping, depth, in_table = [], False, 0, False
    for line in text.splitlines():
        if skipping:
            depth += _depth(line)
            skipping = depth > 0
            continue
        if not in_table and re.match(r"\s*notify\s*=", line):
            depth = _depth(line.split("=", 1)[1])
            skipping = depth > 0
            continue
        if re.match(r"\s*\[", line):
            in_table = True
        out.append(line)
    return "\n".join(out) + "\n"


def _depth(text):
    """Brackets opened minus closed in `text`, outside quoted strings and comments."""
    depth, quote, skip = 0, None, False
    for ch in text:
        if skip:
            skip = False
        elif quote:
            if ch == "\\" and quote == '"':
                skip = True
            elif ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#":
            break
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
    return depth


def _remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif os.path.lexists(path):
        os.unlink(path)


def _copy(src, dst, clone=False):
    """A fresh copy of `src` at `dst`. Links inside stay links and are never followed; `clone` asks
    for an APFS clone first (cp -c), falling back to a plain copy."""
    _remove(dst)
    if clone and subprocess.run(["/bin/cp", "-cR", src, dst], capture_output=True).returncode == 0:
        return
    _remove(dst)
    shutil.copytree(src, dst, symlinks=True)


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


def _health(home):
    """"up" when the daemon of `home` answers health, "down" when it has no socket or refuses, "unknown"
    when it does not answer within HEALTH_TIMEOUT (it may be busy, not dead)."""
    if not os.path.exists(_socket(home)):
        return "down"
    rc = _call(None, home, "health", timeout=HEALTH_TIMEOUT)[0]
    return "up" if rc == 0 else "unknown" if rc is None else "down"


def alive(home):
    """Whether the daemon of `home` answers; a timeout counts as not answering."""
    return _health(home) == "up"


def _may_run(home):
    """Whether a daemon of `home` might be running: never refresh a home under one that could be alive."""
    return _health(home) != "down"


def _register(state, name, home):
    registry = os.path.join(state, "codex-homes.json")
    homes = jload(registry) or {}
    homes[name] = home
    jsave(registry, homes)


def ensure(state, name, memories_src=None, use_memories=False, source=None):
    """The replay home $XDG_STATE_HOME/cxh/<name>, made or brought up to date and recorded in
    <state>/codex-homes.json; returns its path. Without a snapshot the home has no memories.
    Sessions, sqlite and the rest of what the daemon creates are left alone, so an existing home keeps
    its rollouts. A home whose daemon is running is refused."""
    return _make(state, name, memories_src, use_memories, source, False)


def _make(state, name, memories_src, use_memories, source, keep_memories):
    """ensure(); with keep_memories an existing memories/ stays as it is when there is no snapshot."""
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
    mem = os.path.join(home, "memories")
    old = os.path.join(home, ".memories.old")
    if _may_run(home):
        raise Failed("the replay daemon of {} is running (or does not answer health): stop it first".format(home))
    if not os.path.lexists(mem) and os.path.isdir(old):
        os.rename(old, mem)         # a crash between the two renames of a snapshot swap
    if use_memories and memories_src is None and not (keep_memories and os.path.isdir(mem)):
        raise Failed("{} would use memories but has no memories snapshot".format(home))
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
    new = os.path.join(home, ".memories.new")
    _remove(new)
    _remove(old)
    if memories_src is not None:
        try:
            shutil.copytree(memories_src, new, symlinks=True, ignore=shutil.ignore_patterns(".git"))
        except BaseException as e:
            _remove(new)
            if isinstance(e, OSError):      # shutil.Error is one
                raise Failed("cannot copy the memories snapshot {}: {}".format(memories_src, e))
            raise
    jsave(os.path.join(home, "config.toml"), _memories_config(_without_notify(text), use_memories))
    os.chmod(os.path.join(home, "config.toml"), 0o600)
    agents = os.path.join(source, "AGENTS.md")
    if os.path.isfile(agents):
        shutil.copyfile(agents, os.path.join(home, "AGENTS.md"))
    for item in COPIED:
        if os.path.isdir(os.path.join(source, item)):
            _copy(os.path.join(real_source, item), os.path.join(home, item), item in CLONED)
        else:
            _remove(os.path.join(home, item))
    _settle_auth(home)
    if memories_src is not None:        # the old copy goes only once the new one is in place
        if os.path.lexists(mem):
            os.rename(mem, old)
        os.rename(new, mem)
        _remove(old)
    elif not keep_memories:
        _remove(mem)
    jsave(os.path.join(home, RECORD), {"source": source, "use_memories": bool(use_memories)})
    _register(state, name, home)
    return home


def _owned(home):
    """Failed unless `home` lies under $XDG_STATE_HOME/cxh/: stopping a daemon is done only for the homes this
    module makes, whatever a record or a marker file says."""
    root = os.path.realpath(os.path.join(common.L.state_home(), "cxh"))
    if not os.path.realpath(home).startswith(root + os.sep):
        raise Failed("{} is not a replay home under {}: refusing to stop its daemon".format(home, root))


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


_HELD = {"home": None, "fd": None}      # the run lock this process holds, and for which home


def _lock_path():
    return os.path.join(auth_dir(), "run.lock")


def _same(a, b):
    return bool(a) and bool(b) and os.path.realpath(a) == os.path.realpath(b)


def _release():
    if _HELD["fd"] is not None:
        os.close(_HELD["fd"])       # closing drops the flock
    _HELD.update(home=None, fd=None)


def _acquire(home):
    """Hold the run lock for `home` (this process may move it from one home to the next); Failed when another
    process holds it: a run is going."""
    if _HELD["fd"] is not None and _same(_HELD["home"], home):
        return
    _release()
    os.makedirs(auth_dir(), exist_ok=True)
    fd = os.open(_lock_path(), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        raise Failed("a replay run holds the replay daemon (lock {}): wait for it to finish".format(_lock_path()))
    _HELD.update(home=home, fd=fd)


@contextlib.contextmanager
def hold(home):
    """Hold the run lock for as long as a process uses the daemon of `home` that it did not start itself (a `run` finds the
    daemon `home --start` left): without it that daemon looks left by a crashed run, and another `home --start`, or a `reclaim`,
    would stop it mid-run. Failed, at once, when another process holds the lock. A lock this process already holds for `home`
    (it started the daemon) stays held when the block ends."""
    had = _same(_HELD["home"], home)
    _acquire(home)
    try:
        yield
    finally:
        if not had and _same(_HELD["home"], home):
            _release()


def _leftover(home, keep):
    """Stop the daemon of `home` when it answers and no run holds it: one left behind by a run that died. Returns
    whether it did; Failed when a run holds it. The lock stays held with `keep` (a start follows), else it is let go."""
    if _same(_HELD["home"], home) or _health(home) == "down":
        return False
    _acquire(home)
    say("the replay daemon of {} was left running by a run that did not stop it: stopping it".format(home))
    stop(home)
    if keep:
        _acquire(home)
    else:
        _release()
    return True


def reclaim(home):
    """Before a run makes or refreshes `home`: stop a daemon of it that a crashed run left running. Returns
    whether it stopped one; a home that does not exist yet has none; Failed when a live run holds it."""
    if not os.path.isfile(os.path.join(home, RECORD)):
        return False
    _owned(home)
    return _leftover(home, False)


def start(home):
    """Start the replay daemon of `home`. One at a time: a second home is refused while this process runs another.
    A daemon that answers while no process holds the run lock was left by a crashed run and is stopped first. One whose health
    request times out is neither: start is refused and the marker and the login are left as they are. Only a home confirmed down
    (no socket, or the socket refuses) is settled and replaced."""
    _record(home)
    os.makedirs(auth_dir(), exist_ok=True)
    cur = jload(_marker())
    last = cur.get("home") if isinstance(cur, dict) else None
    if last and not _same(last, home):
        health = _health(last)
        if health == "unknown":
            # It did not answer in time: it may be busy, not dead. Settling its login and replacing the marker would leave it running
            # beside the next daemon on one login, so nothing changes until it is stopped or confirmed down.
            raise Failed("the replay daemon of {} did not answer its health request within {} s: it may still be running. Stop that home first "
                         "(process-replay home --name {} --stop), then start this one".format(last, HEALTH_TIMEOUT, os.path.basename(last.rstrip("/"))))
        if health == "up":
            if _same(_HELD["home"], last):
                raise Failed("the replay daemon of {} is running: stop it first".format(last))
            _acquire(home)
            say("the replay daemon of {} was left running by a run that did not stop it: stopping it".format(last))
            stop(last)
        elif os.path.isfile(os.path.join(last, RECORD)):
            _settle_auth(last)      # a dead daemon's refreshed token is carried forward before another home logs in
        if os.path.exists(_marker()):
            os.unlink(_marker())
    _leftover(home, True)
    _acquire(home)
    if os.path.exists(os.path.join(home, PROBED)):
        os.unlink(os.path.join(home, PROBED))        # a probe proved the daemon before this start, not this one
    _daemon(home, "start")
    jsave(_marker(), {"home": home})


def stop(home):
    """Stop the replay daemon of `home`, then take back a refreshed login. The one-daemon marker goes
    only when the daemon stopped (its stop succeeded or its socket is gone)."""
    _record(home)
    _owned(home)
    failure = None
    try:
        _daemon(home, "stop")
    except Failed as e:
        failure = e
    _settle_auth(home)
    cur = jload(_marker())
    if (failure is None or not os.path.exists(_socket(home))) and isinstance(cur, dict) and cur.get("home") == home:
        os.unlink(_marker())
    if (failure is None or not os.path.exists(_socket(home))) and _same(_HELD["home"], home):
        _release()
    if failure is not None:
        raise failure


# ------------------------------------------------------------------ the probe
def _call(rpc, home, *args, timeout=None):
    """(rc, stdout, stderr) of one xreview-rpc call against the daemon of `home`; rc None when it timed out."""
    exe = rpc or XR.RPC
    argv = [exe] if os.access(exe, os.X_OK) else ["/usr/bin/python3", "-I", exe]
    env = dict(os.environ, CODEX_HOME=home)
    for var in ("XREVIEW_RPC_SOCK", "XREVIEW_RPC_STDIO"):      # each outranks CODEX_HOME and would aim the call elsewhere
        env.pop(var, None)
    try:
        p = subprocess.run(argv + list(args), capture_output=True, env=env, timeout=timeout or PROBE_BUDGET + 60)
    except subprocess.TimeoutExpired as e:
        return None, "", str(e)
    except (OSError, subprocess.SubprocessError) as e:
        return 1, "", str(e)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def _rollouts(home, thread):
    found = []
    for sub in ("sessions", "archived_sessions"):
        base = glob.escape(os.path.join(home, sub))
        found += glob.glob(os.path.join(base, "**", "rollout-*-" + glob.escape(thread) + ".jsonl*"), recursive=True)
    return sorted(found)


def _strings(obj):
    """Every string value in a decoded JSON document, and in the JSON a string value itself holds (tool
    arguments are JSON text): a memory line with a quote or a backslash in it is found as it reads."""
    if isinstance(obj, str):
        yield obj
        if obj.lstrip()[:1] in ("{", "["):
            try:
                inner = json.loads(obj)
            except ValueError:
                return
            for x in _strings(inner):
                yield x
    elif isinstance(obj, dict):
        for v in obj.values():
            for x in _strings(v):
                yield x
    elif isinstance(obj, list):
        for v in obj:
            for x in _strings(v):
                yield x


def _read_rollout(path):
    """(model, effort, [developer message text], [every string in the rollout]) of a plain rollout."""
    model = effort = None
    texts, everything = [], []
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return model, effort, texts, everything
    for line in raw.splitlines():
        try:
            rec = json.loads(line.decode("utf-8"))
        except ValueError:
            continue
        everything.extend(_strings(rec))
        p = rec.get("payload") if isinstance(rec, dict) and isinstance(rec.get("payload"), dict) else {}
        if rec.get("type") == "turn_context":
            model, effort = p.get("model") or model, p.get("effort") or effort
        elif rec.get("type") == "response_item" and p.get("type") == "message" and p.get("role") == "developer":
            for part in p.get("content") or []:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    texts.append(part["text"])
    return model, effort, texts, everything


def _memory_lines(summary):
    """Up to three of the longest distinct lines of a memory summary: what a developer message holds
    only when that memory reached the model."""
    try:
        with open(summary, encoding="utf-8") as f:
            lines = {l.strip() for l in f if len(l.strip()) >= 20 and not l.lstrip().startswith("#")}
    except OSError:
        return []
    return sorted(lines, key=lambda l: (-len(l), l))[:MEMORY_LINES]


def probed(home):
    """(True, "") when the last probe of `home`, since its daemon was last started, passed, else (False, why)."""
    rec = jload(os.path.join(home, PROBED))
    if not isinstance(rec, dict):
        return False, "it has not been probed since it was started"
    if rec.get("ok") is not True:
        failed = ", ".join(k for k, v in sorted((rec.get("checks") or {}).items()) if not v)
        return False, "its last probe ({}) failed{}".format(rec.get("at"), ": " + failed if failed else "")
    return True, ""


def probe(home, expect_memories, rpc=None):
    """Prove the isolation before any replay turn runs: one turn on the replay daemon, which must
    answer, leave its rollout under `home` and none under the source home, leave the source home's own
    daemon answering, and show the memory text in its developer message exactly when `expect_memories`.
    `rpc` is an xreview-rpc to use (default: the replay's). Returns {ok, checks, model, effort, notes}."""
    source = _record(home)["source"]
    checks, notes, res = {}, [], {"model": None, "effort": None}

    def done():
        res.update(ok=bool(checks) and all(checks.values()), checks=checks, notes=notes)
        try:
            jsave(os.path.join(home, PROBED), {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "ok": res["ok"], "checks": checks,
                                              "expect_memories": bool(expect_memories)})
        except OSError:
            pass
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
            res["model"], res["effort"], texts, whole = _read_rollout(mine[-1])
        else:
            texts, whole = [], []
        wanted = _memory_lines(os.path.join(home if expect_memories else source, "memories", "memory_summary.md"))
        if not wanted:
            notes.append("no memory lines to look for in {} memory_summary.md".format("the replay home's" if expect_memories else "the source's"))
        haystack = "\n".join(texts if expect_memories else texts + whole)      # nothing of it anywhere when none is expected
        shown = [haystack.find(l) >= 0 for l in wanted]
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
    ap.add_argument("--codex-source", help="the home whose config the replay homes copy (default: the home's own, else ~/.codex)")


def _ensure_for(a, home):
    """ensure() with the flags given. What a flag leaves out comes from the home's record: its source and
    whether it uses memories (--memories replaces the snapshot, never that setting); without --memories
    an existing snapshot stays."""
    rec = jload(os.path.join(home, RECORD)) if os.path.isfile(os.path.join(home, RECORD)) else None
    rec = rec if isinstance(rec, dict) else {}
    source = os.path.expanduser(a.codex_source) if a.codex_source else rec.get("source")
    use = bool(a.use_memories or rec.get("use_memories"))
    return _make(a.state, a.name, a.memories, use, source, keep_memories=not a.memories)


def cmd_home(a):
    """Only a creation, a refresh or --start (which refreshes first) changes a home's files; --stop and
    --probe read its record and leave its files alone, so --stop works on a home whose files are broken."""
    if a.login_cmd:
        if not a.dry_run:
            os.makedirs(auth_dir(), exist_ok=True)
            os.chmod(auth_dir(), 0o700)
        say(login_cmd())
        return 0
    if not a.name:
        raise Failed("home needs --name (or --login-cmd)")
    home = home_path(a.name)
    if a.dry_run:
        say("would use the replay home {} (source {})".format(home, a.codex_source or "its own, else ~/.codex"))
        return 0
    if a.probe:      # the probe is a turn: at the weekly pause level or the token stop nothing starts (not even --start), and no probe record is written
        from . import codex
        spent = codex.spent_now(a, {})
        if spent >= a.max_tokens:      # the token stop blocks every new turn, this one too
            say("stopped: the Codex token stop: {} tokens spent, stop at {}; the probe was not run".format(spent, a.max_tokens))
            return 1
        hold = codex.weekly_hold(home, os.path.abspath(os.path.expanduser(a.codex_source or "~/.codex")))
        if hold:
            say("paused: {}; the probe was not run, run it again after the reset".format(hold["paused"]))
            return 1
    status, stopped = 0, False
    if a.start or a.memories or a.use_memories or not (a.stop or a.probe):
        if _may_run(home):
            if not a.stop:
                raise Failed("the replay daemon of {} is running: stop it first (--stop)".format(home))
            stop(home)
            stopped = True
            say("stopped: " + home)
        home = _ensure_for(a, home)
        say("home: " + home)
    else:
        _record(home)
        _register(a.state, a.name, home)
    if a.start:
        start(home)
        say("started: " + home)
    if a.probe:
        res = probe(home, bool(_record(home).get("use_memories")))
        say(json.dumps(res, indent=2))
        status = 0 if res["ok"] else 1
    if a.stop and (a.start or not stopped):
        stop(home)
        say("stopped: " + home)
    return status
