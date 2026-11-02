"""One Codex pre-merge round of a replay run (spec 4.4, 7.1, 8).

The round is what xreview runs today for a pre-merge review: today's reviewer instructions, findings
schema and packet builder with today's switches (dot_config/xreview/packets.conf), through xreview-rpc
primitives on the replay's own Codex daemon, so no pane, ledger, gate or round counter is touched.

codex_round(a, run, case, branch, home) reads from the run state `run`:
  scratch    the scratch repository (its work tree), physically under a neutral path (Task 8 puts it under
             $XDG_STATE_HOME/review-work/scratch/<label>: Codex may resolve a symlinked cwd to its real path).
             It is the cwd and <scratch>/.git the target's repository; a path (or realpath) naming
             process-replay is refused, so no path a reviewer sees names the replay
  thread     the review thread so far (None before round 1)
  reviews    the reviews so far: this round is k = 1 + the Codex ones; `round` is not read
  rejected   identifiers of the findings judged not defects, accumulated over the run
  addressed  identifiers (`identifier`) of the findings matched in the previous review, set by the caller
             (the run state of the Shared records has no such key; absent reads as none)
  ledger     the run's ledger (prepare_ledger, called for every run at setup); codex_round raises Failed without it
  tokens     Codex tokens spent by this run so far
  case, label  the run's place under <state>/runs/<case>/<label>/
and from `a`: state, max_tokens, budget. It returns the review, which the caller appends to
run["reviews"] and whose `thread` it makes the run's thread:
  {kind: "codex", k, findings, verdict, tokens, turns: [[thread, turn]], model, effort, missing, decision, thread}
or one of
  {paused: str, resets_at: int}         the weekly window is at WEEKLY_PAUSE percent or more; no turn was started
  {stopped: str}                        the token stop was reached; no turn was started
  {leak: [str], tokens, thread, turns}  a turn named the original checkout: the round is void
A round that fails raises RoundFailed (a Failed that carries the tokens its turns used, the thread, and `.leak`:
what the scan of whatever turns it ran found). The caller adds `tokens` of every outcome to the run's.

The leak scan is lexical. It reads a tool call's text for the original checkout's absolute path, its HOME-relative
tail (Code/Org/repo, which also catches ~/, $HOME/, ${HOME}/ and ../../ spellings, and Code/Org/repo-<sibling>), a
token naming the checkout beside its parent directory in one call (cd ~/Code/Org && cat repo-feat/x), and each
path-like token with `..` resolved against the call's cwd (options glued to the path, -C../x, --git-dir=../x and
NAME=../x, are stripped first), the parent directory counting only when spelled as a path, never as a bare tail
(Code, .local/share). A repo-specific tool that reads the checkout without naming it (TOOLS: chezmoi for the chezmoi
source) is a leak when run as a command. Known limits of a lexical scan: a path assembled across separate commands
(`cd ~/Code/Org`, then `cat repo/x`) is caught only when a token still names the repo, and `cd .. && cat x` is not
followed.

Codex homes are paths (codexhome.py): this module sets CODEX_HOME to the replay home for the rpc calls and the
rollout reads of a round, and drops an inherited XREVIEW_RPC_SOCK or XREVIEW_RPC_STDIO, which would aim a call
elsewhere. The environment is process-wide: rounds on one home may run together, a second home may not.
"""
import calendar
import contextlib
import glob
import json
import os
import re
import shlex
import subprocess
import threading
import time

from . import common as C
from . import planreview
from .common import Failed, L, XP, XR, jload, jsave

WEEKLY_MINUTES = 10080
WEEKLY_PAUSE = 80          # percent of the weekly window at which runs wait for the reset (spec 8)
WEEKLY_SCAN = 8            # newest rollouts looked through for a weekly figure
IDENTIFIER_SUMMARY = 80
CALLS = (b'"custom_tool_call"', b'"function_call"', b'"local_shell_call"')
DROPPED = ("XREVIEW_RPC_SOCK", "XREVIEW_RPC_STDIO")


class RoundFailed(Failed):
    """A round that could not finish. `tokens` is what its turns used before it failed, `thread` the last
    thread it used (None before any)."""

    def __init__(self, message, tokens=0, thread=None):
        Failed.__init__(self, message)
        self.tokens = tokens
        self.thread = thread
        self.leak = []


# ------------------------------------------------------------------ the replay home in the environment
_ENV = {"home": None, "n": 0, "saved": None}
_ENV_LOCK = threading.Lock()


@contextlib.contextmanager
def _homed(home):
    with _ENV_LOCK:
        if _ENV["n"] and _ENV["home"] != home:
            raise Failed("CODEX_HOME is already set to {}: rounds on two homes cannot share a process".format(_ENV["home"]))
        if not _ENV["n"]:
            _ENV["saved"] = dict((v, os.environ.get(v)) for v in ("CODEX_HOME",) + DROPPED)
            os.environ["CODEX_HOME"] = home
            for v in DROPPED:
                os.environ.pop(v, None)
        _ENV["home"] = home
        _ENV["n"] += 1
    try:
        yield
    finally:
        with _ENV_LOCK:
            _ENV["n"] -= 1
            if not _ENV["n"]:
                for v, old in _ENV["saved"].items():
                    if old is None:
                        os.environ.pop(v, None)
                    else:
                        os.environ[v] = old
                _ENV["home"] = None


@contextlib.contextmanager
def _state_home(home):
    """L.state_home answers `home` for the calling thread while it builds a packet (as XR.prepare swaps it,
    which XP.build's ledger read needs); other threads still see the real one."""
    me = threading.get_ident()
    with XR.LOCK:
        old = L.state_home          # read under the lock: an overlapping swap would otherwise be restored as "real"
        L.state_home = lambda: home if threading.get_ident() == me else old()
        try:
            yield
        finally:
            L.state_home = old


# ------------------------------------------------------------------ text
def identifier(finding):
    """`<file>:<line> <first 80 chars of the summary>`: how a finding is named to the next round's reviewer."""
    summary = " ".join(str(finding.get("summary") or "").split())[:IDENTIFIER_SUMMARY]
    line = finding.get("line")
    return "{}{} {}".format(finding.get("file"), "" if line is None else ":{}".format(line), summary)


def _range(branch):
    return "{}...{}".format(branch.get("dest_ref") or branch["dest"], branch.get("branch") or "HEAD")


def body(branch, k, addressed, rejected):
    """The request's body. Round 1's is the body XR.prepare writes for the same target; later rounds add
    what a fix round's dispatch adds: the findings addressed since the last round and those judged not defects."""
    text = ("Pre-merge review of {} against {}: the change is {}. Review the change as it "
            "now stands. Your working directory is this repository at this round's tip: read files only there. Paths "
            "from earlier turns of this thread name other checkouts; ignore them.\n".format(
                branch.get("branch") or "the branch", branch["dest"], _range(branch)))
    if k >= 2:
        if addressed:
            text += "Addressed since the last round: {}.\n".format("; ".join(addressed))
        if rejected:
            text += "Judged not defects: {}.\n".format("; ".join(rejected))
    return text


# ------------------------------------------------------------------ the scratch ledger
def _entries(branch):
    """The receipts of the branch's repository, a nonce once, from every ledger that names it."""
    want = os.path.realpath(branch["repo"])
    out, seen = [], set()
    for repo, entries in XR.ledgers():
        if os.path.realpath(repo) != want:
            continue
        for e in entries:
            if e.get("nonce") in seen:
                continue
            seen.add(e.get("nonce"))
            out.append(e)
    return out


def _repo(a, run):
    """The scratch repository's git directory, as the packet builder and the ledger name it. The scratch path
    must be neutral: one naming process-replay (itself or its realpath) is refused."""
    scratch = run["scratch"].rstrip("/")
    for p in (scratch, os.path.realpath(scratch)):
        if "process-replay" in p:
            raise Failed("the scratch repository {} names the replay; it must live under a neutral path".format(p))
    return scratch + "/.git"


def prepare_ledger(a, run, case, branch):
    """The run's ledger, a state home for XP.build, written once under <state>/runs/<case>/<label>/ledger and
    recorded in run["ledger"]: the branch's entries up to its original round 1, as XR.enriched reads them, with
    the plan receipts rebound to the scratch repository (`targets[].repo`) and the plan_blobs of those the original
    cannot derive (a plan commit that survives only in the snapshot) read through the private view
    (planreview.Reader). It reads the ORIGINAL Codex home's rollouts for cleanliness, so call it for every run at
    setup, before any replay home is in the environment; codex_round only uses it."""
    if _ENV["n"]:
        raise Failed("the run's ledger reads the original Codex home; a replay home is set")
    repo = _repo(a, run)
    home = os.path.join(a.state, "runs", case["id"], run["label"], "ledger")
    first = branch["rounds"][0]
    entries = XR.enriched(_entries(branch), first["at"], first["thread"])
    reader = planreview.Reader(a.state, branch["repo"], a.snapshot_root)
    for e in entries:
        if e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "plan":
            for t in e.get("targets") or []:
                if not t.get("plan_blobs"):
                    t["plan_blobs"] = reader.plan_blobs(t["base"], t["tip"]) or {}
                t["repo"] = repo
    jsave(os.path.join(home, "xreview", "ledgers", L.ledger_key(repo), "reviews.jsonl"),
          "".join(json.dumps(e) + "\n" for e in entries))
    run["ledger"] = home
    return home


# ------------------------------------------------------------------ rollouts
def _lines(path):
    """The lines of a rollout, plain or zstd."""
    if path.endswith(".zst"):
        p = subprocess.run(["zstd", "-dc", "--", path], capture_output=True, timeout=300)
        return p.stdout.splitlines() if p.returncode == 0 else []
    with open(path, "rb") as f:
        return f.read().splitlines()


def _mtime(path):
    """A file's modification time, 0 for one that moved away since it was listed."""
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def _rollouts(home):
    found = []
    for sub in ("sessions", "archived_sessions"):
        base = glob.escape(os.path.join(home, sub))
        found += glob.glob(os.path.join(base, "**", "rollout-*.jsonl*"), recursive=True)
    found = [p for p in found if re.search(r"\.jsonl(\.zst)?\Z", p)]
    return sorted(found, key=_mtime, reverse=True)


def _live_home():
    """Michael's Codex home, whose rate limits are the account's: CODEX_HOME as the process had it before a round
    set the replay home, else ~/.codex. Read only."""
    with _ENV_LOCK:
        env = _ENV["saved"]["CODEX_HOME"] if _ENV["n"] else os.environ.get("CODEX_HOME")
    return env or os.path.join(os.path.expanduser("~"), ".codex")


def _epoch(stamp):
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?", stamp if isinstance(stamp, str) else "")
    return calendar.timegm(tuple(int(x) for x in m.groups()[:6]) + (0, 0, 0)) + float(m.group(7) or 0) if m else None


def weekly(home, live=None):
    """(used percent, resets_at epoch seconds or None) of the weekly window: the figure of the token_count record
    with the greatest timestamp (a record without one counts at its file's modification time) among the 8 newest
    rollouts of `home` and of the live home (`live`, default _live_home(); read only), because the limit is
    account-wide and the replay home's own figures go stale across an idle gap. None when no record reports one.
    The weekly window is whichever of `primary` and `secondary` has window_minutes == 10080; one that reports
    used_percent without resets_at counts, with resets_at None."""
    live = _live_home() if live is None else live
    homes = [home] + ([live] if live and os.path.realpath(live) != os.path.realpath(home) else [])
    best, best_key = None, None
    for h in homes:
        for path in _rollouts(h)[:WEEKLY_SCAN]:
            try:
                lines, mtime = _lines(path), os.path.getmtime(path)
            except (OSError, subprocess.SubprocessError):
                continue            # a live rollout may move or vanish while it is read
            for n, line in enumerate(lines):
                if b'"rate_limits"' not in line:
                    continue
                try:
                    rec = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                p = rec.get("payload") if isinstance(rec, dict) and rec.get("type") == "event_msg" else None
                limits = p.get("rate_limits") if isinstance(p, dict) and p.get("type") == "token_count" else None
                for key in ("primary", "secondary"):
                    w = limits.get(key) if isinstance(limits, dict) else None
                    if not (isinstance(w, dict) and w.get("window_minutes") == WEEKLY_MINUTES
                            and isinstance(w.get("used_percent"), (int, float))):
                        continue
                    stamp = _epoch(rec.get("timestamp"))
                    rank = (mtime if stamp is None else stamp, n)
                    if best_key is None or rank >= best_key:
                        resets = w.get("resets_at")
                        best = (float(w["used_percent"]), int(resets) if isinstance(resets, (int, float)) else None)
                        best_key = rank
    return best


# ------------------------------------------------------------------ the leak scan
_TOKEN = re.compile(r"[^\s\"'`;|&<>()\\]+")
_NOT_WORD = r"(?![A-Za-z0-9_])"


# Tools that read an original checkout without naming it, by the work dir they read (HOME-relative): the
# command words that run them, and other spellings of the checkout's path.
TOOLS = {".local/share/chezmoi": {"words": ("chezmoi",), "spellings": ("$XDG_DATA_HOME/chezmoi", "${XDG_DATA_HOME}/chezmoi")}}
SHELLS = ("sh", "bash", "zsh", "dash")
PREFIXES = ("command", "env", "sudo", "exec", "time", "nohup")


def _forbidden(paths):
    """[(path, [regex naming it], [regex naming its parent directory as a path], regex naming its last component)]
    for the original checkouts: a git directory stands for its work tree. Under $HOME a path is also matched by its
    HOME-relative tail wherever a command spells the prefix (~/, $HOME/, ${HOME}/, ../../, /Users/x/). A parent
    directory counts only when spelled as a path (absolute, or ~/, $HOME/, ${HOME}/ + its tail), never as a bare
    tail (Code, .local/share), and not at all when it is $HOME or /."""
    house = os.path.expanduser("~").rstrip("/")
    out, seen = [], set()
    for path in paths:
        if not (isinstance(path, str) and path):
            continue
        path = path.rstrip("/")
        if path.endswith("/.git"):
            path = path[:-len("/.git")]
        if not path or path in seen:
            continue
        seen.add(path)
        names = [re.compile(r"(?<![A-Za-z0-9_])" + re.escape(path) + _NOT_WORD)]
        parent = os.path.dirname(path)
        parents = []
        if parent not in ("", "/", house):
            parents.append(re.compile(r"(?<![A-Za-z0-9_])" + re.escape(parent) + _NOT_WORD))
        if house and path.startswith(house + "/"):
            tail = path[len(house) + 1:]
            # a tail of one component is a bare word (foo for ~/foo): it names the checkout only behind ~/ or $HOME/
            lead = r"(?<![A-Za-z0-9_.-])" if "/" in tail else r"(?:~|\$HOME|\$\{HOME\})/"
            names.append(re.compile(lead + re.escape(tail) + _NOT_WORD))
            if os.path.dirname(tail):
                parents.append(re.compile(r"(?:~|\$HOME|\$\{HOME\})/" + re.escape(os.path.dirname(tail)) + _NOT_WORD))
            for spelling in TOOLS.get(tail, {}).get("spellings", ()):
                names.append(re.compile(r"(?<![A-Za-z0-9_])" + re.escape(spelling) + _NOT_WORD))
        out.append((path, names, parents, re.compile(r"(?<![A-Za-z0-9_./-])" + re.escape(os.path.basename(path)) + _NOT_WORD)))
    return out


def _tool_words(path):
    house = os.path.expanduser("~").rstrip("/")
    return TOOLS.get(path[len(house) + 1:] if house and path.startswith(house + "/") else None, {}).get("words", ())


def _runs(command, words):
    """Whether the shell command `command` (a string, or an argv list) runs one of `words` as a command: its
    first word, or the first after && || ; | and command/env/sudo-like prefixes, looking through `sh -c '...'`.
    A word that is only an argument, a path component or inside a quoted string does not count."""
    if isinstance(command, (list, tuple)):
        argv = [str(x) for x in command]
        if len(argv) >= 3 and os.path.basename(argv[0]) in SHELLS and any(re.match(r"-[a-z]*c[a-z]*\Z", x) for x in argv[1:-1]):
            return _runs(argv[-1], words)
        command = " ".join(shlex.quote(x) for x in argv)
    if not isinstance(command, str):
        return False
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = command.split()
    start = True
    for i, tok in enumerate(tokens):
        if tok in ("&&", "||", ";", "|", ";;", "&", "(", ")"):
            start = True
            continue
        if not start:
            continue
        if tok in PREFIXES or re.match(r"[A-Za-z_][A-Za-z0-9_]*=", tok) or (tok.startswith("-") and i and tokens[i - 1] in PREFIXES):
            continue
        start = False
        if os.path.basename(tok) in words:
            return True
        if os.path.basename(tok) in SHELLS:
            for j in range(i + 1, len(tokens) - 1):
                if re.match(r"-[a-z]*c[a-z]*\Z", tokens[j]):
                    return _runs(tokens[j + 1], words)
    return False


def _named(text, cwd, forbidden, commands=()):
    """The forbidden paths one tool call's text names (see the module docstring for what that covers). `commands`
    are the call's shell commands, read for the tools of TOOLS."""
    house = os.path.expanduser("~").rstrip("/")
    hit = set()
    for path, names, parents, base in forbidden:
        if any(rx.search(text) for rx in names) or (any(rx.search(text) for rx in parents) and base.search(text)):
            hit.add(path)
        words = _tool_words(path)
        if words and any(_runs(c, words) for c in commands):
            hit.add(path)
    resolved = []
    for token in _TOKEN.findall(text):
        if ".." not in token:
            continue
        t = re.sub(r"\A(?:--?[A-Za-z][A-Za-z0-9-]*=|-[A-Za-z]|[A-Za-z_][A-Za-z0-9_]*=)", "", token)       # --git-dir=.., -C.., GIT_DIR=..
        t = t.replace("${HOME}", house).replace("$HOME", house)
        if t == "~" or t.startswith("~/"):
            t = house + t[1:]
        if not os.path.isabs(t):
            if not cwd:
                continue
            t = os.path.join(cwd, t)
        t = os.path.normpath(t)
        resolved.append(t)
        for path, names, _parents, _base in forbidden:
            if names[0].search(t):
                hit.add(path)
    for path, _names, parents, base in forbidden:
        if base.search(text) and any(parents[:1] and parents[0].search(t) for t in resolved):
            hit.add(path)
    return hit


_WORKDIR = re.compile(r"""["']?workdir["']?\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')""")
_CMD = re.compile(r"""["']?cmd["']?\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')""")


def _js_string(literal):
    try:
        return json.loads(literal) if literal.startswith('"') else literal[1:-1]
    except ValueError:
        return literal[1:-1]


def _from(cwd, given):
    return given if os.path.isabs(given) or not cwd else os.path.join(cwd, given)


def _calls(p, cwd):
    """[(text, workdir, [shell commands])] of one tool call payload: its text as it is searched, the directory its
    relative paths start from (the call's own workdir when it names one, else `cwd`) and its commands. A function_call
    carries JSON arguments {cmd, workdir}; a local_shell_call an action {command, working_directory}; a Codex `exec`
    custom_tool_call JavaScript, tools.exec_command({cmd: "...", workdir: "..."}), perhaps several in one input."""
    kind = p.get("type")
    if kind == "custom_tool_call" and isinstance(p.get("input"), str):
        parts = re.split(r"(?=exec_command\s*\()", p["input"])
        out = []
        for part in parts:
            wd, cmds = cwd, [_js_string(m) for m in _CMD.findall(part)]
            m = _WORKDIR.search(part)
            if m and _js_string(m.group(1)):
                wd = _from(cwd, _js_string(m.group(1)))
            out.append((part, wd, cmds))
        return out
    wd, cmds = cwd, []
    if kind == "function_call":
        try:
            doc = json.loads(p.get("arguments"))
        except (TypeError, ValueError):
            doc = None
        if isinstance(doc, dict):
            given = doc.get("workdir") or doc.get("cwd")
            if isinstance(given, str) and given:
                wd = _from(cwd, given)
            cmds = [doc[k] for k in ("cmd", "command") if isinstance(doc.get(k), (str, list))]
    elif kind == "local_shell_call" and isinstance(p.get("action"), dict):
        given = p["action"].get("working_directory")
        if isinstance(given, str) and given:
            wd = _from(cwd, given)
        if isinstance(p["action"].get("command"), (str, list)):
            cmds = [p["action"]["command"]]
    return [(json.dumps(p, ensure_ascii=False), wd, cmds)]


def leaks(home, turns, paths, cwd=None):
    """The tool calls of `turns` ([(thread, turn)]) in `home`'s rollouts that name one of `paths` (the original
    checkouts; a wt sibling <path>-<branch> continues the name): ["<path> in <turn>"]. `cwd`, the scratch repository,
    is where a relative path of a call without its own workdir starts. Only the reviewer's own calls
    (custom_tool_call, function_call, local_shell_call) are read, never a user or developer message, which may carry
    the paths legitimately."""
    wanted = {}
    for thread, turn in turns:
        wanted.setdefault(thread, set()).add(turn)
    forbidden = _forbidden(paths)
    found = set()
    with _homed(home):
        for thread, ours in wanted.items():
            path = XR.rollout_path(thread)
            if path is None:
                continue
            inside = False
            for line in _lines(path):
                call = any(m in line for m in CALLS)
                if not call and b'"task_started"' not in line and b'"task_complete"' not in line:
                    continue
                try:
                    rec = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                p = rec.get("payload") if isinstance(rec, dict) and isinstance(rec.get("payload"), dict) else {}
                if rec.get("type") == "event_msg" and p.get("type") == "task_started":
                    inside = p.get("turn_id") in ours
                    turn = p.get("turn_id")
                elif rec.get("type") == "event_msg" and p.get("type") == "task_complete":
                    inside = False
                elif inside and rec.get("type") == "response_item" and p.get("type") in ("custom_tool_call", "function_call", "local_shell_call"):
                    for text, where, commands in _calls(p, cwd):
                        for name in _named(text, where, forbidden, commands):
                            found.add("{} in {}".format(name, turn))
    return sorted(found)


# ------------------------------------------------------------------ the round
def _spent(a, run):
    """Codex tokens of every run under the state, this run's as the caller holds it."""
    total = run.get("tokens") or 0
    for path in glob.glob(os.path.join(glob.escape(a.state), "runs", "*", "*", "state.json")):
        other = jload(path) or {}
        if (other.get("case"), other.get("label")) != (run.get("case"), run.get("label")):
            total += other.get("tokens") or 0
    return total


def _orig_paths(branch):
    return [p for p in (branch.get("repo"), branch.get("objects"), branch.get("view")) if isinstance(p, str)]


def _start(a, cwd):
    rc, out, err = XR.rpc("thread-start", "--cwd", cwd)
    if rc != 0 or not out.strip():
        raise Failed("cannot open a thread: {}".format(err.strip()))
    thread = out.strip().splitlines()[-1]
    XR.Threads(a.state).add(thread, "new")
    return thread


def codex_round(a, run, case, branch, home):
    ledger_home = run.get("ledger")
    if not ledger_home or not os.path.isdir(ledger_home):
        raise Failed("the run has no prepared ledger (prepare_ledger runs at setup)")
    k = 1 + sum(1 for r in run.get("reviews") or [] if r.get("kind") == "codex")
    spent = _spent(a, run)
    if spent >= a.max_tokens:
        return {"stopped": "the Codex token stop: {} tokens spent, stop at {}".format(spent, a.max_tokens)}
    wk = weekly(home)
    if wk and wk[0] >= WEEKLY_PAUSE and (wk[1] is None or wk[1] > time.time()):
        when = "unknown" if wk[1] is None else "{} ({})".format(wk[1], time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(wk[1])))
        return {"paused": "the weekly window is at {:g}%, resets_at {}".format(wk[0], when), "resets_at": wk[1]}

    repo = _repo(a, run)
    scratch = cwd = run["scratch"].rstrip("/")
    rundir = os.path.join(a.state, "runs", case["id"], run["label"])
    target = {"repo": repo, "dest": branch["dest"], "dest_ref": branch.get("dest_ref") or branch["dest"],
              "branch": branch.get("branch"), "range": _range(branch), "base": branch["base"],
              "tip": C.git(scratch, "rev-parse", "HEAD"), "full": True}
    out = os.path.join(rundir, "codex-{}".format(k))
    jsave(os.path.join(out, "body.md"), body(branch, k, run.get("addressed") or [], run.get("rejected") or []))
    previous = [r for r in run.get("reviews") or [] if r.get("kind") == "codex"]
    thread_in = run.get("thread") if k >= 2 else None
    req = {"checkpoint": "pre-merge", "body_file": os.path.join(out, "body.md"),
           "reviewer_md": os.path.join(XR.CONF, "reviewer.md"), "framing_md": os.path.join(XR.CONF, "reviewer-framing.md"),
           "cap": None, "switches_file": os.path.join(XR.CONF, "packets.conf"), "codex_home": home,
           "targets": [target], "specs": [target["range"]], "missed": (previous[-1].get("missing") or []) if previous else [],
           "thread": thread_in, "turns_file": None}
    try:
        with _state_home(ledger_home):
            dec = XP.build(req, os.path.join(out, "packets"))
    except Exception as e:
        raise RoundFailed("cannot build the packet: {}".format(e))
    jsave(os.path.join(out, "decision.json"), dec)
    if dec["action"] == "refuse":
        raise RoundFailed("refused: " + dec["reason"])
    framed = bool(dec["switches"]["framing"])
    schema = os.path.join(XR.CONF, "findings.framed.schema.json" if framed else "findings.schema.json")

    res = {"findings": [], "judged": [], "tokens": 0, "turns": [], "models": [], "approvals": []}
    thread = None
    with _homed(home):
        for i, pk in enumerate(dec["packets"]):
            try:
                thread = thread_in if (dec["action"] == "send" and thread_in and i == 0) else _start(a, cwd)
                box = {}
                try:
                    doc, _compacted = XR.one_turn(thread, pk["file"], schema, cwd, a.budget, box)
                finally:
                    if box.get("turn"):
                        use = XR.turn_usage(thread, box["turn"])
                        res["tokens"] += use["tokens"]
                        res["models"].append((use["model"], use["effort"]))
                        res["turns"].append([thread, box["turn"]])
            except Failed as e:
                failed = RoundFailed(str(e), res["tokens"], thread)
                try:
                    failed.leak = leaks(home, res["turns"], _orig_paths(branch), cwd)
                except Exception as scan:
                    failed.leak = ["the leak scan failed: {}".format(scan)]
                raise failed
            res["findings"] += [f for f in doc["findings"] if isinstance(f, dict)]
            res["approvals"].append(doc.get("verdict") == "approve")
            res["judged"].append(([x for x in doc.get("reviewed_files") or [] if isinstance(x, str)], pk.get("shown") or []))
    found = leaks(home, res["turns"], _orig_paths(branch), cwd)
    if found:
        return {"leak": found, "tokens": res["tokens"], "thread": thread, "turns": res["turns"]}
    missing = None
    if framed:
        # as xreview's _collect_record: a label is covered only when the turn that showed it lists it (compared
        # after stripping a/, b/ and ./); the uncovered ones keep their shown order before the cap
        missing = []
        for reviewed, shown in res["judged"]:
            listed = set(reviewed) | set(XR.norm(x) for x in reviewed)
            missing += [l for l in shown if l not in listed and XR.norm(l) not in listed]
        missing = missing[:XP.MISSING_CAP]
    return {"kind": "codex", "k": k, "findings": res["findings"], "verdict": "approve" if all(res["approvals"]) else "changes",
            "tokens": res["tokens"], "turns": res["turns"],
            "model": ",".join(sorted(set(m or "?" for m, _e in res["models"]))),
            "effort": ",".join(sorted(set(e or "?" for _m, e in res["models"]))),
            "missing": missing, "decision": dec, "thread": thread}
