"""Shared fixtures for the process-replay suites: git repositories, ledgers, rollouts, Claude
transcripts, a fake xreview-rpc and a fake codex binary.

Stdlib only at import time (the fake xreview-rpc imports this module), so process_replay is
imported lazily where a fixture needs it. Every t_*.py calls setup() first: it isolates git's
configuration (unless the wrapper already did) and puts .scripts on sys.path.
"""
import atexit
import json
import os
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(os.path.dirname(HERE))
SCRIPTS = os.path.join(SRC, ".scripts")
_ROOTS = []
_REDIRECTED = set()


def setup():
    if "GIT_CONFIG_GLOBAL" not in os.environ:
        base = tmp_root()
        cfg = os.path.join(base, "gitconfig")
        with open(cfg, "w") as f:
            f.write("[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n")
        os.environ["GIT_CONFIG_GLOBAL"] = cfg
        os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
        os.environ["GIT_CEILING_DIRECTORIES"] = base
    # A backstop whatever isolated git already: no suite reaches the real home, state or Codex home.
    # The wrapper's own redirect (under T_ROOT) is kept.
    wrapped = os.environ.get("T_ROOT")
    for var, sub in (("HOME", "home"), ("XDG_STATE_HOME", "state"), ("CODEX_HOME", "codex")):
        current = os.environ.get(var, "")
        if wrapped and current.startswith(wrapped + os.sep) or var in _REDIRECTED:
            continue
        path = os.path.join(tmp_root(), sub)
        os.makedirs(path, exist_ok=True)
        os.environ[var] = path
        _REDIRECTED.add(var)
    real = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
    if os.path.realpath(os.path.expanduser("~")) == real or os.path.realpath(os.environ.get("CODEX_HOME", "")) == os.path.join(real, ".codex"):
        raise SystemExit("helpers.setup: this process still reaches the account's own home or ~/.codex: {}".format(os.environ.get("HOME")))
    if SCRIPTS not in sys.path:
        sys.path.insert(0, SCRIPTS)


def tmp_root():
    """A fresh temporary directory, removed when the process exits."""
    path = tempfile.mkdtemp(prefix="pr.", dir=os.environ.get("T_ROOT") or os.environ.get("TMPDIR") or None)
    _ROOTS.append(path)
    return path


@atexit.register
def _cleanup():
    for path in _ROOTS:
        shutil.rmtree(path, ignore_errors=True)


# ------------------------------------------------------------------ assertions
def ok(name, cond, got=""):
    print("  PASS: " + name if cond else "  FAIL: {}\n    | got: {}".format(name, str(got)[:400]))


def is_(name, got, want):
    ok(name, got == want, repr(got) + " want " + repr(want))


# ------------------------------------------------------------------ git
def git(repo, *args):
    """stdout of `git -C repo args`, trailing newline removed; raises on a non-zero exit."""
    p = subprocess.run(["git", "-C", repo] + list(args), capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("git {} failed: {}".format(" ".join(args), p.stderr.decode("utf-8", "replace")))
    return p.stdout.decode("utf-8", "replace").rstrip("\n")


def git_ok(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True).returncode == 0


def put(repo, path, text, mode=None):
    full = os.path.join(repo, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as f:
        f.write(text if isinstance(text, bytes) else text.encode("utf-8"))
    if mode is not None:
        os.chmod(full, mode)


def commit(repo, msg):
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", msg)
    return git(repo, "rev-parse", "HEAD")


def make_repo(root, name):
    """An empty repository on main at <root>/<name> (no commit yet)."""
    path = os.path.join(root, name)
    os.makedirs(path)
    git(path, "init", "-q", "-b", "main")
    return path


def listing(root):
    """Sorted (relative path, size, mtime_ns) of every file below root."""
    out = []
    for d, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            st = os.lstat(p)
            out.append((os.path.relpath(p, root), st.st_size, st.st_mtime_ns))
    return sorted(out)


# ------------------------------------------------------------------ ledgers
def write_ledger(state_home, repo, entries):
    """<state_home>/xreview/ledgers/<key of repo's common dir>/{reviews.jsonl,repo}; returns that dir."""
    from process_replay import common
    comm = common.L.common_dir(repo)
    ldir = os.path.join(state_home, "xreview", "ledgers", common.L.ledger_key(comm))
    os.makedirs(ldir, exist_ok=True)
    with open(os.path.join(ldir, "reviews.jsonl"), "w") as f:
        f.write("".join(json.dumps(e) + "\n" for e in entries))
    with open(os.path.join(ldir, "repo"), "w") as f:
        f.write(comm + "\n")
    return ldir


# ------------------------------------------------------------------ Codex rollouts
def rollout_lines(turn, total_before=0):
    """The rollout records of one turn, and the cumulative token total after it.

    turn: a dict with
      turn      the turn id
      answer    dict (dumped to JSON) or str: task_complete's last_agent_message; None for none
      tokens    last_token_usage of the turn (default 1000); the total moves by it
      ctx       when set, a token_count before the turn whose last_token_usage is ctx (the context size)
      compacted True adds a compacted record
      model, effort, window     turn_context and context window (m-1, high, 200000)
      rate_limits   a dict placed in the turn's token_count record (as Codex does)
      tools     [{type: function_call|custom_tool_call, name, arguments}] tool-call records; a
                function_call carries `arguments`, a custom_tool_call `input` (the real shapes)
      developer a developer message text
      complete  False leaves the turn without task_complete (still running)
    """
    window = turn.get("window", 200000)
    tid = turn["turn"]
    recs = []
    if turn.get("ctx") is not None:
        recs.append({"type": "event_msg", "payload": {"type": "token_count", "info": {
            "total_token_usage": {"total_tokens": total_before}, "last_token_usage": {"total_tokens": turn["ctx"]},
            "model_context_window": window}}})
    recs.append({"type": "event_msg", "payload": {"type": "task_started", "turn_id": tid, "model_context_window": window}})
    recs.append({"type": "turn_context", "payload": {"turn_id": tid, "model": turn.get("model", "m-1"),
                                                      "effort": turn.get("effort", "high")}})
    if turn.get("developer"):
        recs.append({"type": "response_item", "payload": {"type": "message", "role": "developer", "content": [
            {"type": "input_text", "text": turn["developer"]}]}})
    if turn.get("compacted"):
        recs.append({"type": "compacted", "payload": {"message": ""}})
    for i, tool in enumerate(turn.get("tools") or []):
        kind = tool.get("type", "function_call")
        text = tool.get("arguments", "")
        text = text if isinstance(text, str) else json.dumps(text)
        payload = {"type": kind, "name": tool.get("name", "exec"), "call_id": "call_{}_{}".format(tid, i)}
        payload["input" if kind == "custom_tool_call" else "arguments"] = text
        recs.append({"type": "response_item", "payload": payload})
    tokens = turn.get("tokens", 1000)
    total = total_before + tokens
    payload = {"type": "token_count", "info": {"total_token_usage": {"total_tokens": total},
                                               "last_token_usage": {"total_tokens": tokens},
                                               "model_context_window": window}}
    if turn.get("rate_limits") is not None:
        payload["rate_limits"] = turn["rate_limits"]
    recs.append({"type": "event_msg", "payload": payload})
    if turn.get("complete", True):
        answer = turn.get("answer")
        recs.append({"type": "event_msg", "payload": {
            "type": "task_complete", "turn_id": tid,
            "last_agent_message": answer if isinstance(answer, str) or answer is None else json.dumps(answer)}})
    return recs, total


def rollout_file(codex_home, thread, stamp="2026-10-20T10-00-00", sub="sessions/2026/10/20"):
    return os.path.join(codex_home, sub, "rollout-{}-{}.jsonl".format(stamp, thread))


def write_rollout(codex_home, thread, turns, stamp="2026-10-20T10-00-00", sub="sessions/2026/10/20"):
    """A whole rollout. turns: dicts as in rollout_lines, or (turn id, ctx, answer, compacted) tuples."""
    recs, total = [], 0
    for t in turns:
        if isinstance(t, (tuple, list)):
            t = {"turn": t[0], "ctx": t[1], "answer": t[2], "compacted": t[3]}
        more, total = rollout_lines(t, total)
        recs += more
    path = rollout_file(codex_home, thread, stamp, sub)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in recs))
    return path


# ------------------------------------------------------------------ Claude transcripts
def write_transcript(projects, key, session, entries, subagents=()):
    """<projects>/<key>/<session>.jsonl, and for each subagent {id, meta, entries}:
    <projects>/<key>/<session>/subagents/agent-<id>.jsonl and agent-<id>.meta.json."""
    base = os.path.join(projects, key)
    os.makedirs(base, exist_ok=True)
    main = os.path.join(base, session + ".jsonl")
    with open(main, "w") as f:
        f.write("".join(json.dumps(e) + "\n" for e in entries))
    sub = os.path.join(base, session, "subagents")
    for s in subagents:
        os.makedirs(sub, exist_ok=True)
        with open(os.path.join(sub, "agent-{}.jsonl".format(s["id"])), "w") as f:
            f.write("".join(json.dumps(e) + "\n" for e in s.get("entries", [])))
        with open(os.path.join(sub, "agent-{}.meta.json".format(s["id"])), "w") as f:
            json.dump(s.get("meta", {}), f)
    return main


# ------------------------------------------------------------------ the fake xreview-rpc
RPC_STUB = r'''#!/usr/bin/python3
import fcntl, json, os, sys, time
sys.path.insert(0, @HERE@)
import helpers
CFG = json.load(open(@CFG@))
D, SCRIPT = CFG["dir"], CFG["script"]
args = sys.argv[1:]
cmd = args[0] if args else ""
HOME = os.environ.get("CODEX_HOME") or CFG["codex_home"]


def opt(name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def log():
    line = json.dumps({"cmd": cmd, "argv": args, "codex_home": os.environ.get("CODEX_HOME"), "cwd": opt("--cwd")}) + "\n"
    fd = os.open(os.path.join(D, "rpc.log"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    os.write(fd, line.encode())
    os.close(fd)


def locked(fn):
    with open(os.path.join(D, "rpc.lock"), "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            st = json.load(open(os.path.join(D, "rpc-state.json")))
        except (OSError, ValueError):
            st = {"threads": 0, "turns": 0, "global": 0, "per_thread": {}, "specs": {}, "totals": {}, "waits": {},
                  "written": [], "archived": []}
        out = fn(st)
        json.dump(st, open(os.path.join(D, "rpc-state.json"), "w"))
        return out


def thread_start(st):
    st["threads"] += 1
    print("th{}".format(st["threads"]))
    return 0


def turn_start(st):
    thread = opt("--thread")
    mine = (SCRIPT.get("threads") or {}).get(thread) or []
    n = st["per_thread"].get(thread, 0)
    if SCRIPT.get("probe") is not None and "Reply with the JSON object" in open(opt("--input")).read():
        spec = SCRIPT["probe"]      # codexhome.probe's turn: served apart, so it consumes no scripted turn
    elif n < len(mine):
        spec = mine[n]
        st["per_thread"][thread] = n + 1
    elif st["global"] < len(SCRIPT.get("turns") or []):
        spec = SCRIPT["turns"][st["global"]]
        st["global"] += 1
    elif SCRIPT.get("default") is not None:
        spec = SCRIPT["default"]
    else:
        sys.stderr.write("fake xreview-rpc: the script has no turn left for thread {}\n".format(thread))
        return 1
    st["turns"] += 1
    turn = "tu{}".format(st["turns"])
    st["specs"][turn] = {"thread": thread, "spec": spec}
    os.makedirs(os.path.join(D, "inputs"), exist_ok=True)
    with open(os.path.join(D, "inputs", turn), "w") as f:
        f.write(open(opt("--input")).read())
    print(turn)
    return 0


def turn_wait(st):
    turn = opt("--turn")
    rec = st["specs"].get(turn)
    if rec is None:
        sys.stderr.write("fake xreview-rpc: unknown turn {}\n".format(turn))
        return 1
    spec, thread = rec["spec"], rec["thread"]
    if st["waits"].get(turn, 0) < spec.get("rc3", 0):
        st["waits"][turn] = st["waits"].get(turn, 0) + 1
        return 3
    if spec.get("sleep"):
        time.sleep(spec["sleep"])
    if turn not in st["written"]:
        st["written"].append(turn)
        turn_spec = dict((k, spec[k]) for k in ("answer", "tokens", "compacted", "model", "effort", "window", "rate_limits",
                                                "tools", "developer", "ctx") if k in spec)
        turn_spec["turn"] = turn
        recs, total = helpers.rollout_lines(turn_spec, st["totals"].get(thread, 0))
        st["totals"][thread] = total
        path = helpers.rollout_file(HOME, thread)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write("".join(json.dumps(r) + "\n" for r in recs))
    if opt("--report"):
        json.dump({"turn": turn, "compacted": bool(spec.get("compacted"))}, open(opt("--report"), "w"))
    rc = spec.get("rc", 0)
    if rc == 4:
        print(spec.get("raw", "not json"))
    elif rc != 0:
        sys.stderr.write("fake xreview-rpc: turn-wait failed\n")
    else:
        print(json.dumps(spec.get("answer"), indent=2))
    return rc


def archive(st):
    thread = opt("--thread")
    if cmd == "thread-archive" and thread not in st["archived"]:
        st["archived"].append(thread)
    elif cmd == "thread-unarchive" and thread in st["archived"]:
        st["archived"].remove(thread)
    return 0


log()
if cmd == "health":
    sys.exit(SCRIPT.get("health_rc", 0))
table = {"thread-start": thread_start, "turn-start": turn_start, "turn-wait": turn_wait,
         "thread-archive": archive, "thread-unarchive": archive}
if cmd not in table:
    sys.stderr.write("fake xreview-rpc: unknown command {}\n".format(cmd))
    sys.exit(2)
sys.exit(locked(table[cmd]))
'''


def stub_rpc(dir, codex_home, script):
    """A fake xreview-rpc in `dir`; returns its path. It logs every call as a JSON line
    {cmd, argv, codex_home (the CODEX_HOME env of the call), cwd} to <dir>/rpc.log, and answers
    thread-start (th1, th2, ...), turn-start (tu1, ...), turn-wait, thread-archive, thread-unarchive
    and health from `script`:

      {"turns":   [spec, ...],            consumed in turn-start order, by turns no per-thread entry serves
       "threads": {"th2": [spec, ...]},   consumed in that thread's turn-start order, first
       "default": spec,                   used when both are exhausted (without it, turn-start fails)
       "probe": spec,                     the answer to codexhome.probe's turn, which consumes no entry of the above
       "health_rc": 0}

    spec: {"answer": {verdict, findings, reviewed_files}, "tokens": 1000, "compacted": false,
           "rate_limits": {...}, "tools": [...], "model", "effort", "window", "ctx", "developer"
           (as helpers.rollout_lines), "rc3": N (turn-wait exits 3 that many times first),
           "rc": 4 with "raw" (the schema failure) or any other non-zero, "sleep": seconds}

    turn-wait appends the turn to <CODEX_HOME>/sessions/2026/10/20/rollout-...-<thread>.jsonl
    (the env's CODEX_HOME, else `codex_home`); turn-start keeps the input file as <dir>/inputs/<turn>."""
    os.makedirs(dir, exist_ok=True)
    cfg = os.path.join(dir, "rpc-config.json")
    with open(cfg, "w") as f:
        json.dump({"dir": dir, "codex_home": codex_home, "script": script}, f)
    path = os.path.join(dir, "xreview-rpc")
    with open(path, "w") as f:
        f.write(RPC_STUB.replace("@HERE@", repr(HERE)).replace("@CFG@", repr(cfg)))
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


# ------------------------------------------------------------------ the fake codex binary
CODEX_STUB = r'''#!/usr/bin/python3
import json, os, sys
D = @DIR@
args = sys.argv[1:]
home = os.environ.get("CODEX_HOME")
with open(os.path.join(D, "codex.log"), "a") as f:
    f.write(json.dumps({"argv": args, "codex_home": home}) + "\n")
sock = os.path.join(home or "/nonexistent", "app-server-control", "app-server-control.sock")
if args[:3] in (["app-server", "daemon", "start"], ["app-server", "daemon", "stop"]):
    if not home:
        sys.stderr.write("fake codex: CODEX_HOME is not set\n")
        sys.exit(2)
    if args[2] == "start":
        os.makedirs(os.path.dirname(sock), exist_ok=True)
        open(sock, "w").close()
    elif os.path.exists(sock):
        os.unlink(sock)
    sys.exit(0)
if args[:1] == ["login"]:
    sys.exit(0)
sys.stderr.write("fake codex: unknown arguments {}\n".format(args))
sys.exit(2)
'''


def stub_codex(dir):
    """A fake real codex binary in `dir`; returns its path. It logs {argv, codex_home} per call to
    <dir>/codex.log. `app-server daemon start` makes $CODEX_HOME/app-server-control/app-server-control.sock
    a plain file and `daemon stop` removes it; `login` succeeds; with no CODEX_HOME the daemon
    commands fail, so a test can never reach the live home."""
    os.makedirs(dir, exist_ok=True)
    path = os.path.join(dir, "codex")
    with open(path, "w") as f:
        f.write(CODEX_STUB.replace("@DIR@", repr(dir)))
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def read_log(path):
    try:
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]
    except OSError:
        return []
