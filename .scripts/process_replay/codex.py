"""One Codex pre-merge round of a replay run (spec 4.4, 7.1, 8).

The round is what xreview runs today for a pre-merge review: today's reviewer instructions, findings
schema and packet builder with today's switches (dot_config/xreview/packets.conf), through xreview-rpc
primitives on the replay's own Codex daemon, so no pane, ledger, gate or round counter is touched.

codex_round(a, run, case, branch, home) reads from the run state `run`:
  scratch    the scratch repository (its work tree); Codex gets its alias as the cwd, and the packet
             builder gets <alias>/.git as the target's repository, so no path a reviewer sees names the replay
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
A round that fails raises RoundFailed (a Failed that carries the tokens its turns used and the thread).
The caller adds `tokens` of every outcome to the run's.

Codex homes are paths (codexhome.py): this module sets CODEX_HOME to the replay home for the rpc calls and the
rollout reads of a round, and drops an inherited XREVIEW_RPC_SOCK or XREVIEW_RPC_STDIO, which would aim a call
elsewhere. The environment is process-wide: rounds on one home may run together, a second home may not.
"""
import contextlib
import glob
import json
import os
import re
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
    me, old = threading.get_ident(), L.state_home
    with XR.LOCK:
        L.state_home = lambda: home if threading.get_ident() == me else old()
        try:
            yield
        finally:
            L.state_home = old


# ------------------------------------------------------------------ text
def identifier(finding):
    """`<file>:<line> <first 80 chars of the summary>`: how a finding is named to the next round's reviewer."""
    summary = " ".join(str(finding.get("summary") or "").split())[:IDENTIFIER_SUMMARY]
    return "{}:{} {}".format(finding.get("file"), finding.get("line"), summary)


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
    """The scratch repository's git directory as the packet builder and the ledger name it: through the alias."""
    return C.aliased(a.state, run["scratch"]).rstrip("/") + "/.git"


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


def _rollouts(home):
    found = []
    for sub in ("sessions", "archived_sessions"):
        base = glob.escape(os.path.join(home, sub))
        found += glob.glob(os.path.join(base, "**", "rollout-*.jsonl*"), recursive=True)
    found = [p for p in found if re.search(r"\.jsonl(\.zst)?\Z", p)]
    return sorted(found, key=os.path.getmtime, reverse=True)


def weekly(home):
    """(used percent, resets_at epoch seconds) of the weekly window, as the newest rollout of `home` that
    reports one last said, or None. The weekly window is whichever of `primary` and `secondary` has
    window_minutes == 10080."""
    for path in _rollouts(home)[:WEEKLY_SCAN]:
        got = None
        try:
            lines = _lines(path)
        except (OSError, subprocess.SubprocessError):
            continue
        for line in lines:
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
                if (isinstance(w, dict) and w.get("window_minutes") == WEEKLY_MINUTES
                        and isinstance(w.get("used_percent"), (int, float)) and isinstance(w.get("resets_at"), (int, float))):
                    got = (float(w["used_percent"]), int(w["resets_at"]))
        if got:
            return got
    return None


# ------------------------------------------------------------------ the leak scan
def _spellings(path):
    """A path as a command may write it: absolute, ~/, $HOME/. A git directory stands for its work tree."""
    path = path.rstrip("/")
    if path.endswith("/.git"):
        path = path[:-len("/.git")]
    out = [path]
    house = os.path.expanduser("~").rstrip("/")
    if house and path.startswith(house + "/"):
        out += ["~" + path[len(house):], "$HOME" + path[len(house):]]
    return out


def leaks(home, turns, paths):
    """The tool calls of `turns` ([(thread, turn)]) in `home`'s rollouts that name one of `paths` (the original
    checkout, and so each wt sibling <path>-<branch>, whose name continues the path): ["<path> in <turn>"].
    Only the reviewer's own calls (custom_tool_call, function_call, local_shell_call) are read, never a user or
    developer message, which may carry the paths legitimately."""
    wanted, spell = {}, []
    for thread, turn in turns:
        wanted.setdefault(thread, set()).add(turn)
    for p in paths:
        if isinstance(p, str) and p:
            spell += _spellings(p)
    pats = [(s, re.compile(re.escape(s) + r"(?![A-Za-z0-9_])")) for s in sorted(set(spell))]
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
                    text = json.dumps(p, ensure_ascii=False)
                    for s, rx in pats:
                        if rx.search(text):
                            found.add("{} in {}".format(s, turn))
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
    if wk and wk[0] >= WEEKLY_PAUSE and wk[1] > time.time():
        return {"paused": "the weekly window is at {:g}%, resets_at {} ({})".format(
            wk[0], wk[1], time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(wk[1]))), "resets_at": wk[1]}

    scratch = run["scratch"]
    cwd = C.aliased(a.state, scratch)
    repo = _repo(a, run)
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
    with _state_home(ledger_home):
        dec = XP.build(req, os.path.join(out, "packets"))
    jsave(os.path.join(out, "decision.json"), dec)
    if dec["action"] == "refuse":
        raise RoundFailed("refused: " + dec["reason"])
    framed = bool(dec["switches"]["framing"])
    schema = os.path.join(XR.CONF, "findings.framed.schema.json" if framed else "findings.schema.json")

    res = {"findings": [], "reviewed": [], "tokens": 0, "turns": [], "shown": [], "models": [], "approvals": []}
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
                raise RoundFailed(str(e), res["tokens"], thread)
            res["findings"] += [f for f in doc["findings"] if isinstance(f, dict)]
            res["reviewed"] += [x for x in doc.get("reviewed_files") or [] if isinstance(x, str)]
            res["approvals"].append(doc.get("verdict") == "approve")
            res["shown"] += pk.get("shown") or []
    found = leaks(home, res["turns"], _orig_paths(branch))
    if found:
        return {"leak": found, "tokens": res["tokens"], "thread": thread, "turns": res["turns"]}
    missing = None
    if framed:
        seen = set(XR.norm(x) for x in res["reviewed"])
        missing = sorted(l for l in set(res["shown"]) if XR.norm(l) not in seen)[:XP.MISSING_CAP]
    return {"kind": "codex", "k": k, "findings": res["findings"], "verdict": "approve" if all(res["approvals"]) else "changes",
            "tokens": res["tokens"], "turns": res["turns"],
            "model": ",".join(sorted(set(m or "?" for m, _e in res["models"]))),
            "effort": ",".join(sorted(set(e or "?" for _m, e in res["models"]))),
            "missing": missing, "decision": dec, "thread": thread}
