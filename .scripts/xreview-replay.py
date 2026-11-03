#!/usr/bin/python3
"""xreview-replay - measure each review-packet switch against today's packets on past reviews.

Design: docs/superpowers/specs/2026-10-25-xreview-review-packets-design.md, section 5. It imports
the working tree's packet builder and calls the working tree's xreview-rpc (XREVIEW_REPLAY_RPC
overrides it), so nothing needs deploying. It never calls `xreview dispatch` and never touches
the pane, the review ledger or the round counter. `run` needs the daemon socket: run it unsandboxed.

  cases   [--state DIR]   pick candidate rounds from the ledgers and rollouts, write the blind
                          judge inputs judge-known/<round>.json, and, once the judges have answered,
                          select the cases per switch into cases.json
  run     [--state DIR]   build every arm's packet, run the arms through the daemon (3 turns at
                          once, hard stop at --max-tokens), archive every thread it used
  match   [--state DIR]   write the blind matching inputs judge-match/<case>.json
  report  [--state DIR]   read the matching answers, print the pass bar per switch
  pending [--state DIR]   stage every judge input that waits for an answer and print kind, id and brief (tab-separated), one line each
  cleanup [--state DIR]   archive the threads a crashed run left behind

`cases --switch memories --memwatch DIR` selects the memories switch's cases instead (spec 2026-11-02-replay-set, section 6):
the first pre-merge round of branches that started after the memories watcher (process-replay memories-watch) whose
surrounding polls show one hash. Arms A and A2 run on a replay Codex home holding that snapshot, B on a home with no
memories; the replay daemons run one at a time (process_replay.codexhome), so `run` takes the homes in turn. The
switch has its own state directory ($XDG_STATE_HOME/xreview/replay/memories; pass --switch memories to every command
or the same --state), each arm's packet is built against its own checkout under $XDG_STATE_HOME/review-work/scratch,
and a turn whose rollout shows a leak (a path the reviewer must not read: see process_replay.codex.forbidden) is void and runs once
more (a second leak is an error run).

--dry-run builds and selects but starts no turn and calls no daemon. The default state directory is
$XDG_STATE_HOME/xreview/replay/<date>. Raw run files are never committed.

Every command holds the state's lock, <state>/run.lock, from its entry to its exit (process_replay.common.command_locks):
`report` and `pending` share it, every other command holds it alone (a dry `run` too: it builds packets and checkouts; a dry
`cleanup` takes none). A live `run` or `cleanup` that touches a replay home holds the replay daemons' lock as well. A command
that finds a lock held exits 1, naming it, before it has changed anything.

Judge files (the controller dispatches the judges between phases). The judge protocol is process_replay.common's: a judge is
never handed a path in the state. `pending` stages each input in a real directory of its own, $XDG_STATE_HOME/review-work/items/<hex>/,
holding only input.json and brief.md; the judge writes answer.json there, and `cases`, `match` and `report` collect it:
  judge-known/<round>.json         {findings:[{index, severity, ...}], interdiff}
  judge-known answer               {verdicts:[{index, answer: yes|no|unclear}]}
  judge-match/<case>.json          {known:[...], runs:{label:[findings]}}  (no case id in either: it names the class)
  judge-match answer               {matches:[{known_index, label, finding_index|null}]}
(<kind>/<id>.answer.json in the state, once collected, is where the answer lives; an answer put there by hand counts too.)
An answer is used only when complete for its input: a verdict for every finding, a match for every known finding and review. One
that is not is set aside (<id>.rejected-<n>.answer.json) and the input is pending again.
A round is named by its review's nonce; a case by <nonce>.<class>: pre (pre-merge, fresh thread),
inc (incremental: delta), big (round 1, too big for a fresh thread), ctx (a later round whose thread
would have been full). The class names are neutral on purpose: judges see them.

Written for /usr/bin/python3 (3.9).
"""
import argparse
import collections
import concurrent.futures as cf
import contextlib
import copy
import functools
import glob
import importlib.util
import itertools
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from datetime import date

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONF = os.path.join(ROOT, "dot_config", "xreview")
RPC = os.environ.get("XREVIEW_REPLAY_RPC") or os.path.join(ROOT, "dot_local", "bin", "executable_xreview-rpc")
os.environ.setdefault("XREVIEW_LEDGER", os.path.join(ROOT, "dot_claude", "xreview-ledger.py"))
_spec = importlib.util.spec_from_file_location("xreview_packet", os.path.join(ROOT, "dot_claude", "xreview-packet.py"))
XP = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(XP)
L = XP._ledger()

QUOTA, FIT_FRESH, POOL_EXTRA, MAX_BIG = 10, 5, 5, 12   # spec 5.1 (the pool is judged; the quota is kept)
JOBS = 3                                               # spec 5.6: at most 3 turns at once
TOKEN_CAP = 60000000                                   # spec 5.6: the hard stop
TOKEN_CAPS = {"memories": 20000000}                    # replay-set spec 8: this switch stops at 20M
MEMORIES_QUOTA = 10                                    # replay-set spec 6: up to 10 cases, taken as they accrue
TURN_BUDGET = 3600                                     # seconds one turn may take
UNLIMITED = 10 ** 12                                   # the cap of today's dispatch with the override set
SWITCH_ORDER = ("framing", "omit_plans", "delta", "fit")
REPORT_ORDER = SWITCH_ORDER + ("memories",)
KNOWN_SEVERITIES = ("P0", "P1", "P2")
MAX_INTERDIFF = 150000
COVERAGE_LIMIT = 0.1                                   # spec 5.5
MARKS = (b'"task_started"', b'"task_complete"', b'"token_count"', b'"compacted"', b'"turn_context"')

STOP = threading.Event()
CHILDREN = set()
PROTECTED = set()       # thread-creating calls: an interrupt lets them finish, so their thread is recorded
LOCK = threading.RLock()
TALLY = threading.RLock()     # guards FLIGHT and the move of a job's tokens from FLIGHT into its run file
FLIGHT = {}                   # (state, case, label) -> the tokens the turns of a job in flight have completed (voided attempts too), not yet in its run file


class Failed(Exception):
    pass


class Paused(Failed):
    """The weekly usage is at the pause level (replay-set spec 8): no further turn starts. `hold` is weekly_hold's answer."""

    def __init__(self, hold):
        Failed.__init__(self, hold["paused"])
        self.hold = hold


class Stopped(Failed):
    """The token stop is reached (spec 8): no further turn starts. The turns that ran are charged to the job, which stays resumable."""


def say(msg):
    print(msg, flush=True)


def pkg(name):
    """A process_replay module, imported on first use: process_replay.common loads this file, so importing the
    package at the top would loop. Run as a script, this module is the one the package finds as xreview_replay."""
    sys.dont_write_bytecode = True
    scripts = os.path.dirname(os.path.abspath(__file__))
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    if __name__ == "__main__":
        sys.modules.setdefault("xreview_replay", sys.modules["__main__"])
    return importlib.import_module("process_replay." + name)


def locked(mode, daemon=False):
    """process_replay.common.locked (the command's locks, taken at its entry and held to its exit), looked up when the command runs: the
    package imports this file, so it cannot be imported while this file loads."""
    def wrap(fn):
        @functools.wraps(fn)
        def command(a, *args, **kw):
            return pkg("common").locked(mode, daemon)(fn)(a, *args, **kw)
        return command
    return wrap


def replay_homes(a):
    """Whether a live `run` or `cleanup` of this state touches a replay daemon: the memories switch's arms run on replay homes, and a thread
    left to archive on one is archived on its daemon. The packet switches' arms run on the daemon the environment names, never a replay one."""
    if getattr(a, "dry_run", False):
        return False
    cj = jload(os.path.join(a.state, "cases.json")) or {}
    if cj.get("switch") == "memories" or any(isinstance(c, dict) and c.get("class") == "mem" for c in cj.get("cases") or []):
        return True
    threads = (jload(os.path.join(a.state, "threads.json")) or {}).get("threads") or []
    return any(isinstance(t, dict) and t.get("home") and not t.get("done") for t in threads)


def jload(path, default=None):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return default


_WRITES = itertools.count()       # one number per write in this process (next() on it is atomic under the GIL)


def tmp_name(path):
    """A temporary name beside `path` that no other write uses: this process, this thread and a number of its own. Two writes of one path,
    from two threads or two processes, never share a temporary file, so each os.replace puts a whole file in place."""
    return "{}.tmp{}.{}.{}".format(path, os.getpid(), threading.get_ident(), next(_WRITES))


def write_whole(path, data):
    """Write `data` (bytes or text) to `path` atomically, through a temporary file of this write's own (tmp_name)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = tmp_name(path)
    try:
        with open(tmp, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def jsave(path, data):
    write_whole(path, data if isinstance(data, str) else json.dumps(data, indent=2))


def sh(argv, timeout=None, protect=False):
    """(rc, stdout, stderr) of a child, which an interrupt can terminate unless it is protected.
    The stop flag is checked under the lock that registers the child, so a signal cannot slip between."""
    env = L.git_env() if argv and argv[0] == "git" else None
    with LOCK:
        if STOP.is_set():
            return 1, "", "stopped"
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        CHILDREN.add(proc)
        if protect:
            PROTECTED.add(proc)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
    finally:
        CHILDREN.discard(proc)
        PROTECTED.discard(proc)
    return proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def rpc(*args):
    argv = [RPC] if os.access(RPC, os.X_OK) else ["/usr/bin/python3", "-I", RPC]
    return sh(argv + list(args), protect=bool(args) and args[0] in ("thread-start", "thread-fork", "thread-unarchive"))


# ------------------------------------------------------------------ rollouts
def codex_home():
    return os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")


def rollout_path(thread):
    """The newest rollout of a thread, in sessions or archived_sessions, plain or zstd."""
    found = []
    for sub in ("sessions", "archived_sessions"):
        base = glob.escape(os.path.join(codex_home(), sub))
        found += glob.glob(os.path.join(base, "**", "rollout-*-" + glob.escape(thread) + ".jsonl*"), recursive=True)
    found = [p for p in found if re.search(r"-" + re.escape(thread) + r"\.jsonl(\.zst)?\Z", p)]
    return max(found, key=os.path.getmtime) if found else None


def rollout_records(thread):
    path = rollout_path(thread)
    if path is None:
        return []
    try:
        if path.endswith(".zst"):
            raw = subprocess.run(["zstd", "-dc", "--", path], capture_output=True, timeout=300).stdout
        else:
            with open(path, "rb") as f:
                raw = f.read()
    except (OSError, subprocess.SubprocessError):
        return []
    recs = []
    for line in raw.splitlines():
        if any(m in line for m in MARKS):
            try:
                rec = json.loads(line.decode("utf-8"))
            except ValueError:
                continue
            if isinstance(rec, dict):
                recs.append(rec)
    return recs


def turn_usage(thread, turn):
    """What one turn used: the last_token_usage of the token_count records between its task_started and
    its task_complete (or the end of the rollout, for a turn still running), and the model and effort of
    its turn_context. A record counts only when the cumulative total_token_usage moved past the previous
    record's, wherever that record is: after a compaction Codex repeats the total with a last_token_usage
    that is the compacted context's size, not new usage, and a fork's inherited history precedes the turn."""
    use, inside, prev = {"tokens": 0, "model": None, "effort": None}, False, None
    for rec in rollout_records(thread):
        p = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
        kind, ptype = rec.get("type"), p.get("type")
        if kind == "event_msg" and ptype == "token_count" and isinstance(p.get("info"), dict):
            total, last = p["info"].get("total_token_usage"), p["info"].get("last_token_usage")
            total = total.get("total_tokens") if isinstance(total, dict) else None
            last = last.get("total_tokens") if isinstance(last, dict) else None
            moved = not isinstance(total, int) or prev is None or total > prev
            if inside and isinstance(last, int) and moved:
                use["tokens"] += last
            prev = total if isinstance(total, int) else prev
        elif kind == "event_msg" and ptype == "task_started":
            inside = p.get("turn_id") == turn
        elif inside and kind == "event_msg" and ptype == "task_complete" and p.get("turn_id") == turn:
            break
        elif inside and kind == "turn_context" and p.get("turn_id") == turn:
            use.update(model=p.get("model"), effort=p.get("effort"))
    return use


_TURNS = {}


def turns_of(thread):
    """{turn id: {ctx_before, window, compacted, final, model, effort}} of a thread, in order."""
    if thread not in _TURNS:
        info, cur, ctx, window = collections.OrderedDict(), None, None, None
        for rec in rollout_records(thread):
            p = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
            kind, ptype = rec.get("type"), p.get("type")
            if kind == "event_msg" and ptype == "task_started":
                cur = p.get("turn_id")
                window = p.get("model_context_window") or window
                info[cur] = {"ctx_before": ctx, "window": window, "compacted": False, "final": None,
                             "model": None, "effort": None}
            elif kind == "event_msg" and ptype == "task_complete" and p.get("turn_id") in info:
                info[p["turn_id"]]["final"] = p.get("last_agent_message")
                cur = None
            elif kind == "event_msg" and ptype == "token_count" and isinstance(p.get("info"), dict):
                last = p["info"].get("last_token_usage")
                ctx = last.get("total_tokens") if isinstance(last, dict) else ctx
                window = p["info"].get("model_context_window") or window
            elif kind == "compacted" and cur in info:
                info[cur]["compacted"] = True
            elif kind == "turn_context" and p.get("turn_id") in info:
                info[p["turn_id"]].update(model=p.get("model"), effort=p.get("effort"))
        _TURNS[thread] = info
    return _TURNS[thread]


# ------------------------------------------------------------------ rounds and candidates
def ledgers():
    """(repo, entries) of every ledger whose repository still exists."""
    base = os.path.join(L.state_home(), "xreview", "ledgers")
    for d in sorted(glob.glob(os.path.join(glob.escape(base), "*"))):
        try:
            with open(os.path.join(d, "repo")) as f:
                repo = f.read().strip()
            if L.git(repo, "rev-parse", "--git-dir") is not None:
                yield repo, L.read_entries(os.path.join(d, "reviews.jsonl"))
        except OSError:
            continue


def load_rounds():
    """Every pre-merge round on record as a dict, most recent first: its target, thread, turn, its
    place k in the thread's chain, and the rounds before and after it on that thread."""
    rounds = []
    for repo, entries in ledgers():
        chains = collections.defaultdict(list)
        for e in entries:
            ts = [t for t in (e.get("targets") or []) if isinstance(t, dict)]
            if (e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "pre-merge"
                    and all(isinstance(e.get(k), str) and e[k] for k in ("nonce", "thread", "turn", "dispatched_at"))
                    and len(ts) == 1 and ts[0].get("full") is True
                    and all(isinstance(ts[0].get(k), str) for k in ("repo", "base", "tip", "dest"))):
                chains[(e["thread"], ts[0].get("branch"), ts[0]["dest"])].append({"nonce": e["nonce"], "at": e["dispatched_at"], "thread": e["thread"],
                                            "turn": e["turn"], "target": ts[0], "entries": entries})
        for chain in chains.values():
            chain.sort(key=lambda r: r["at"])
            for i, r in enumerate(chain):
                r.update(k=i + 1, prev=chain[i - 1] if i else None, next=chain[i + 1] if i + 1 < len(chain) else None)
                rounds.append(r)
    return sorted(rounds, key=lambda r: r["at"], reverse=True)


def clean(thread, turn):
    info = turns_of(thread).get(turn)
    return bool(info) and not info["compacted"]


def candidate(r):
    """The round as a candidate case source, or None: its answer parses, holds a P0-P2 finding, and a
    next round's tip follows its tip (so the change between them can be judged)."""
    t, nxt = r["target"], r["next"]
    info = turns_of(r["thread"]).get(r["turn"])
    if nxt is None or not info or not info["final"]:
        return None
    try:
        doc = json.loads(info["final"])
        found = [f for f in doc["findings"] if isinstance(f, dict) and f.get("severity") in KNOWN_SEVERITIES
                 and isinstance(f.get("summary"), str)]
    except (ValueError, KeyError, TypeError):
        return None
    repo, nt = t["repo"], nxt["target"]
    if not found or not all(L.commit_of(repo, x) for x in (t["base"], t["tip"], nt["tip"])):
        return None
    if not L.is_ancestor(repo, t["tip"], nt["tip"]):
        return None
    keys = ("severity", "file", "line", "summary", "failure_scenario")
    return {"round": r, "info": info,
            "findings": [dict(index=i, **dict((k, f.get(k)) for k in keys)) for i, f in enumerate(found)]}


def enriched(entries, before, thread):
    """The ledger as it stood before a round, with what the historical receipts lack, so the packet
    module reads them as it would today's: cleanliness (from the rollouts), full packets, and for plan
    reviews the plans their range added."""
    out = []
    for e in entries:
        if not (isinstance(e.get("dispatched_at"), str) and e["dispatched_at"] < before):
            continue
        e = copy.deepcopy(e)
        if e.get("v") == 2 and e.get("kind") == "receipt":
            e["clean"] = bool(e.get("thread") and clean(e["thread"], e.get("turn"))
                              and (e.get("checkpoint") == "plan" or e["thread"] == thread))
            for t in e.get("targets") or []:
                t.update(packet="full", plans_from=[], delta_from=None)
                if e.get("checkpoint") == "plan":
                    try:
                        t["plan_blobs"] = L.plan_blobs(t["repo"], t["base"], t["tip"])
                    except (L.Fail, KeyError):
                        t["plan_blobs"] = {}
        out.append(e)
    return out


def listed_plans(r):
    return XP.plan_listing(enriched(r["entries"], r["at"], r["thread"]), r["target"]["repo"], r["target"])


def judge_input(c):
    r = c["round"]
    t, nt = r["target"], r["next"]["target"]
    diff = L.patch(t["repo"], t["tip"], nt["tip"]).decode("utf-8", "replace")
    if len(diff) > MAX_INTERDIFF:
        diff = diff[:MAX_INTERDIFF] + "\n[truncated]\n"
    return {"case": r["nonce"], "findings": c["findings"], "interdiff": diff}


FINDING_KEYS = ("severity", "file", "line", "summary", "failure_scenario")

MATCH_BRIEF = """The input is {"known": [{"index", "severity", "file", "line", "summary", "failure_scenario"}],
"runs": {"<id>": [{"severity", "file", "line", "summary", "failure_scenario"}]}}. The known findings are defects
known to be in some code. Each entry of runs is the list of findings from one review of that code, under an id of its own.

For each known finding and for each review, name the position (0, 1, 2, ... in that review's list) of the finding that
reports it, or null. A finding reports a known defect when it points at the same flaw: the same cause and the same
failure, though it may word it differently or cite other lines. A finding that is merely near the defect, or in the same
file, does not. One finding can report several known defects. A review with an empty list reports none.

Answer: {"matches": [{"known_index": 0, "label": "<the review's id>", "finding_index": 2}]}, one entry per known finding
and review, with null as the finding_index when none reports it.
"""


def judge_briefs():
    """The kinds whose brief is not process-replay's: its judge-match reads {defects, findings}, this one {known, runs}."""
    return {"judge-match": MATCH_BRIEF, "judge-known": pkg("common").BRIEFS["judge-known"].replace('{"case", "findings"', '{"findings"')}


def judge_put(a, kind, jid, doc):
    """Write a judge input through the shared protocol (process_replay.common): the judge gets it staged in a directory of its own,
    by `pending`, never as a file of this state. The input carries no `case`: its id ends in the class (<nonce>.mem, .pre, ...), which names
    the experiment; the file name in the state is the harness's mapping, and `cases` and `report` look the answer up by it."""
    return pkg("common").judge_write(a.state, kind, jid, dict((k, v) for k, v in doc.items() if k != "case"))


def judge_got(a, kind, jid):
    """The judge's answer, or None: the file the judge wrote in its staged directory, collected into the state, else an answer already there."""
    return pkg("common").accepted_answer(a.state, kind, jid)


def case_of(c, klass, **extra):
    r = c["round"]
    t = r["target"]
    case = {"id": "{}.{}".format(r["nonce"], klass), "round": r["nonce"], "class": klass, "repo": t["repo"],
            "thread": r["thread"], "turn": r["turn"], "k": r["k"], "at": r["at"], "target": t, "findings": c["findings"],
            "fork": None, "switches": []}
    case.update(extra)
    return case


def branch_receipts(r, pre_merge_only=False):
    """Seconds since the epoch of every receipt of the round's branch and destination in its ledger, on any
    thread (only the pre-merge ones with `pre_merge_only`)."""
    t, mw = r["target"], pkg("memwatch")
    times = []
    for e in r["entries"]:
        if e.get("v") == 2 and e.get("kind") == "receipt" and isinstance(e.get("dispatched_at"), str) \
                and (not pre_merge_only or e.get("checkpoint") == "pre-merge") \
                and any(isinstance(x, dict) and x.get("branch") == t.get("branch") and x.get("dest") == t["dest"]
                        for x in e.get("targets") or []):
            try:
                times.append(mw.parse_at(e["dispatched_at"]))
            except pkg("common").Failed:
                continue
    return times


def branch_start(r):
    """Seconds since the epoch of the first receipt, of any checkpoint, that the round's branch has in its ledger."""
    times = branch_receipts(r)
    if not times:
        raise pkg("common").Failed("no receipt of branch {} has a usable time".format(r["target"].get("branch")))
    return min(times)


def first_pre_merge(r):
    """Whether no pre-merge receipt of the round's branch and destination precedes it, on any thread: a branch
    restarted on a fresh thread starts its chain over, but its first round is still the one before."""
    mine = pkg("memwatch").parse_at(r["at"])
    return not any(t < mine for t in branch_receipts(r, True))


def guard_cases(a, switch):
    """Refuse to put one switch set's cases where another's are: the state's cases.json and judge answers belong
    to the set that wrote them."""
    have = jload(os.path.join(a.state, "cases.json"))
    if isinstance(have, dict) and have.get("switch") != switch:
        raise Failed("{} holds cases of {}; use another --state for {}".format(
            os.path.join(a.state, "cases.json"), have.get("switch") or "the packet switches", switch or "the packet switches"))


def cases_memories(a):
    """The memories switch's cases: the first pre-merge round of a branch that started after the watcher's first poll, with a
    known-real P0-P2 finding, and one snapshot of the memories its dispatch had (the poll before and the poll
    after show the same hash). Oldest first, up to MEMORIES_QUOTA: the cases accrue as the watcher runs."""
    mw, common = pkg("memwatch"), pkg("common")
    if not getattr(a, "memwatch", None):
        raise Failed("cases --switch memories needs --memwatch DIR (the watcher's directory)")
    guard_cases(a, "memories")
    first = mw.first_poll(a.memwatch)
    if first is None:
        say("the watcher has not polled yet: no case can have a snapshot")
        return 0
    started, early, kept, dropped = mw.parse_at(first), 0, [], []
    for r in sorted(load_rounds(), key=lambda r: r["at"]):
        try:
            if not first_pre_merge(r):
                continue
            if branch_start(r) <= started:
                early += 1
                continue
            c = candidate(r)
            if not c:
                continue
            path, why = mw.snapshot_for(a.memwatch, r["at"])
        except common.Failed as e:
            dropped.append({"round": r["nonce"], "why": str(e)})
            continue
        if path is None:
            dropped.append({"round": r["nonce"], "why": why})
            say("dropped {}: {}".format(r["nonce"], why))
        else:
            kept.append((c, {"dir": path, "hash": why}))
    pool = [case_of(c, "mem", switches=["memories"], memories=m) for c, m in kept[:MEMORIES_QUOTA + POOL_EXTRA]]
    for case, (c, _m) in zip(pool, kept):
        n = case["round"]
        judge_put(a, "judge-known", n, judge_input(c))
        ans = judge_got(a, "judge-known", n)
        yes = set(v.get("index") for v in (ans or {}).get("verdicts", []) if isinstance(v, dict) and v.get("answer") == "yes")
        case["known"] = None if ans is None else [dict(f, index=i) for i, f in enumerate(f for f in case["findings"] if f["index"] in yes)]
    chosen = [c for c in pool if (c["known"] if not a.dry_run else c["known"] != [])][:MEMORIES_QUOTA]
    say("memories: {} case(s); {} dropped; {} on branches that started before the watcher".format(len(chosen), len(dropped), early))
    say("judge inputs: {} round(s); `pending` lists them with their briefs".format(len(pool)))
    if not a.dry_run:
        jsave(os.path.join(a.state, "cases.json"), {"created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "switch": "memories",
              "memwatch": os.path.abspath(a.memwatch), "cases": chosen, "selected": {"memories": [c["id"] for c in chosen]},
              "dropped": dropped})
    return 0


@locked("exclusive")
def cmd_cases(a):
    if getattr(a, "switch", None) == "memories":
        return cases_memories(a)
    guard_cases(a, None)
    cands = [c for c in (candidate(r) for r in load_rounds()) if c]
    pool, plans, other, delta, big, fresh = {}, [], [], [], [], []
    for c in cands:
        r = c["round"]
        t, info = r["target"], c["info"]
        size = len(L.patch(t["repo"], t["base"], t["tip"]))
        window = info["window"]
        if len(plans) < QUOTA + POOL_EXTRA and listed_plans(r):
            plans.append(case_of(c, "pre", switches=["framing", "omit_plans"]))
        elif len(other) < QUOTA + POOL_EXTRA:
            other.append(case_of(c, "pre", switches=["framing"]))
        prev = r["prev"]
        if (prev and len(delta) < QUOTA + POOL_EXTRA and prev["target"]["base"] == t["base"]
                and L.is_ancestor(t["repo"], prev["target"]["tip"], t["tip"]) and clean(prev["thread"], prev["turn"])):
            delta.append(case_of(c, "inc", switches=["delta"], fork={"thread": r["thread"], "last_turn": prev["turn"]}))
        if r["k"] == 1 and window and not XP.fits(XP.FRESH_CONTEXT, size, window) and len(big) < MAX_BIG:
            big.append(case_of(c, "big", switches=["fit"]))
        elif prev and info["ctx_before"] is not None and window and not XP.fits(info["ctx_before"], size, window):
            fork = {"thread": r["thread"], "last_turn": prev["turn"]}
            fresh.append(case_of(c, "ctx", switches=["fit"], fork=fork, own_compacted=info["compacted"],
                                 ctx_before=info["ctx_before"], window=window))
    fresh.sort(key=lambda c: c["at"], reverse=True)
    fresh.sort(key=lambda c: not c["own_compacted"])
    pool = dict((c["id"], c) for c in plans + other + delta + big + fresh[:QUOTA])
    judged = set()
    for c in pool.values():
        n = c["round"]
        if n not in judged:
            judged.add(n)
            src = next(x for x in cands if x["round"]["nonce"] == n)
            judge_put(a, "judge-known", n, judge_input(src))
        ans = judge_got(a, "judge-known", n)
        yes = set(v.get("index") for v in (ans or {}).get("verdicts", []) if isinstance(v, dict) and v.get("answer") == "yes")
        c["known"] = None if ans is None else [dict(f, index=i) for i, f in enumerate(f for f in c["findings"] if f["index"] in yes)]

    def ok(c):
        return c["known"] if not a.dry_run else c["known"] != []
    take = lambda items, n: [c for c in items if ok(c)][:n]
    omit = take(plans, QUOTA)
    frame = omit + take(other, QUOTA - len(omit)) if len(omit) < QUOTA else omit
    selected = {"framing": frame, "omit_plans": omit, "delta": take(delta, QUOTA), "fit": take(big, MAX_BIG) + take(fresh, FIT_FRESH)}
    for c in pool.values():
        c["switches"] = [s for s in c["switches"] if any(c is x for x in selected[s])]
    chosen = [c for c in pool.values() if c["switches"]]
    for s in SWITCH_ORDER:
        say("{}: {} case(s)".format(s, len(selected[s])))
    say("judge inputs: {} round(s); `pending` lists them with their briefs".format(len(judged)))
    if not a.dry_run:
        jsave(os.path.join(a.state, "cases.json"), {"created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "cases": chosen, "selected": dict((s, [c["id"] for c in v]) for s, v in selected.items())})
    return 0


# ------------------------------------------------------------------ threads
ANY = object()


class Threads(object):
    """Every thread the run creates or unarchives, recorded as it happens in threads.json, so
    cleanup archives them even after a crash."""

    def __init__(self, state):
        self.path = os.path.join(state, "threads.json")

    def add(self, thread, kind, home=None):
        with LOCK:
            data = jload(self.path, {"threads": []})
            data["threads"].append(dict({"thread": thread, "kind": kind, "done": False}, **({"home": home} if home else {})))
            jsave(self.path, data)

    def cleanup(self, only=ANY):
        """Archive the threads not yet archived (those of one replay home with `only`). A thread of a replay
        home is archived on that home's daemon, started for the purpose when it is not running."""
        with LOCK:
            data = jload(self.path, {"threads": []})
        homes = collections.OrderedDict()
        for t in data["threads"]:
            if not t["done"] and (only is ANY or t.get("home") == only):
                homes.setdefault(t.get("home"), []).append(t)
        for home, items in homes.items():
            def archive():
                for t in items:
                    rc, _o, err = rpc("thread-archive", "--thread", t["thread"])
                    if rc == 0:
                        t["done"] = True
                    else:
                        say("could not archive {}: {}".format(t["thread"], err.strip()))
            if home is None:
                archive()
            else:
                with_daemon(home, archive)
        with LOCK:
            jsave(self.path, data)
        return all(t["done"] for t in data["threads"] if only is ANY or t.get("home") == only)


TH = None
UNARCHIVE = threading.Lock()


@contextlib.contextmanager
def codex_env(home):
    """CODEX_HOME is `home` for the block, and no socket override aims an rpc call elsewhere (each outranks
    CODEX_HOME). Rollouts are read from codex_home(), which reads the same variable."""
    names = ("CODEX_HOME", "XREVIEW_RPC_SOCK", "XREVIEW_RPC_STDIO")
    saved = dict((k, os.environ.get(k)) for k in names)
    os.environ["CODEX_HOME"] = home
    for k in names[1:]:
        os.environ.pop(k, None)
    try:
        yield
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def with_daemon(home, fn):
    """fn() with the replay daemon of `home` answering: the running one, else one started for the call."""
    cx = pkg("codexhome")
    try:
        with cx.hold(home), codex_env(home):        # the run lock: a daemon another process is using is not touched
            started = not cx.alive(home)
            if started:
                cx.start(home)
            try:
                fn()
            finally:
                if started:
                    cx.stop(home)
    except pkg("common").Failed as e:
        say("could not reach the replay daemon of {}: {}".format(home, e))


def hist_call(thread, *args):
    """An rpc call on a historical thread, unarchiving the thread first when the daemon says it is
    archived. The unarchive is recorded before it is made, so cleanup archives the thread again."""
    r = rpc(*args)
    if r[0] != 0 and "archived" in r[2]:
        with UNARCHIVE:
            r = rpc(*args)
            if r[0] != 0 and "archived" in r[2]:
                TH.add(thread, "unarchived")
                rpc("thread-unarchive", "--thread", thread)
                r = rpc(*args)
    return r


# ------------------------------------------------------------------ the arms
def arms_of(case):
    if case["class"] == "mem":
        return [("A", None), ("A2", None), ("B", "memories")]
    if case["class"] == "pre":
        return [("A", None), ("A2", None), ("F", None)] + ([("B", "omit_plans")] if "omit_plans" in case["switches"] else [])
    return [("A", None), ("A2", None), ("B", "delta" if case["class"] == "inc" else "fit")]


def exercised(case, sw, dec):
    """Why B's packet did not exercise the switch under test, or None. A B that did not is an error
    run: its result would rest on a packet that is not the thing being measured."""
    if dec["action"] == "refuse":
        return "B was refused: " + dec["reason"]
    if sw == "delta" and dec["kind"] != "delta":
        return "B built a {} packet, not a delta".format(dec["kind"])
    if case["class"] == "big" and dec["action"] != "slices":
        return "B was not sliced ({})".format(dec["action"])
    if case["class"] == "ctx":
        size = os.path.getsize(dec["packets"][0]["file"]) if dec["packets"] else 0
        if dec["action"] == "slices" or (case.get("window") and case.get("ctx_before") is not None
                                         and XP.fits(case["ctx_before"], size, case["window"])):
            return "B's packet would have fit the historical thread, so the fit check would not have moved it"
    if sw == "omit_plans" and not any(t.get("plans_from") for t in dec["targets"]):
        return "B listed no plan, so omit_plans changed nothing"
    return None


def forks(case, arm):
    return bool(case.get("fork")) and (case["class"] == "inc" or arm in ("A", "A2"))


def scratch_root():
    """Where the memories arms' checkouts live: a neutral path, as the reviewer will see it in its cut file lists
    and as Codex resolves its working directory."""
    return os.path.join(L.state_home(), "review-work", "scratch")


def prepare(a, cases, live):
    """Build every arm's packet with the module, as dispatch would, and return the jobs in the
    spec's order: framing with omit_plans, then delta, then fit."""
    arms = jload(os.path.join(a.state, "arms.json"), {})
    taken = set(l for m in arms.values() for l in m)
    order = {"pre": 0, "inc": 1, "big": 2, "ctx": 2, "mem": 3}
    rounds = dict((r["nonce"], r) for r in load_rounds())
    jobs = []
    for case in sorted(sorted(cases, key=lambda c: c["at"], reverse=True), key=lambda c: order[c["class"]]):
        cid, t = case["id"], case["target"]
        pdir = os.path.join(a.state, "packets", cid)
        jsave(os.path.join(pdir, "body.md"), "Pre-merge review of {} against {}: the change is {}. Review the change as it "
              "now stands. Your working directory is this repository at this round's tip: read files only there. Paths "
              "from earlier turns of this thread name other checkouts; ignore them.\n".format(
                  t.get("branch") or "the branch", t["dest"], t["range"]))
        home = os.path.join(a.state, "scratch", cid)
        r = rounds[case["round"]]
        entries = enriched(r["entries"], r["at"], r["thread"])
        jsave(os.path.join(home, "xreview", "ledgers", L.ledger_key(t["repo"]), "reviews.jsonl"),
              "".join(json.dumps(e) + "\n" for e in entries))
        turns_file, hist_error = None, None
        if case["class"] == "inc":
            turns_file = os.path.join(pdir, "turns.json")
            try:
                jsave(turns_file, history(case, entries, live))
            except Failed as e:
                hist_error = str(e)
        for arm, sw in arms_of(case):
            label = next((l for l, v in arms.get(cid, {}).items() if v["arm"] == arm), None)
            if label is None:
                label = os.urandom(4).hex()
                while label in taken:
                    label = os.urandom(4).hex()
                taken.add(label)
                arms.setdefault(cid, {})[label] = {"arm": arm, "switch": sw}
            on = {"A": [], "A2": [], "F": ["framing"]}.get(arm) if arm != "B" else ["framing", sw]
            if case["class"] == "mem":      # only the Codex home differs between the arms: one packet for all
                on = []
            conf = os.path.join(pdir, arm + ".conf")
            jsave(conf, "".join("{}={}\n".format(k, "on" if k in on else "off") for k in XP.SWITCHES))
            req = {"checkpoint": "pre-merge", "body_file": os.path.join(pdir, "body.md"),
                   "reviewer_md": os.path.join(CONF, "reviewer.md"), "framing_md": os.path.join(CONF, "reviewer-framing.md"),
                   "cap": UNLIMITED, "switches_file": conf, "codex_home": None, "targets": [t], "specs": [t["range"]],
                   "missed": [], "thread": case["thread"] if (arm == "B" and sw == "delta") else None,
                   "turns_file": turns_file if (arm == "B" and sw == "delta") else None}
            job = {"case": cid, "arm": arm, "switch": sw, "framing": "framing" in on, "repo": t["repo"], "tip": t["tip"], "target": t,
                   "fork": case["fork"] if forks(case, arm) else None, "error": hist_error if (arm == "B" and sw == "delta") else None,
                   "decision": None, "home": None, "memories": None, "scratch": None, "label": label}
            if case["class"] == "mem":
                job["home"] = "nomem" if arm == "B" else "mem-" + case["memories"]["hash"][:12]
                job["memories"] = None if arm == "B" else case["memories"]["dir"]
                # The packet is built against the arm's own checkout, as the reviewer will read it: a cut file list
                # names its repository, and that must never be the original (spec 7.1).
                job["scratch"] = os.path.join(scratch_root(), label)
                try:
                    shutil.rmtree(job["scratch"], ignore_errors=True)
                    build_scratch(a, job, job["scratch"], os.path.join(a.state, "clones"))
                    req["targets"] = [dict(t, repo=job["scratch"] + "/.git", tip=pkg("common").git(job["scratch"], "rev-parse", "HEAD"))]
                except Failed as e:
                    job["error"] = str(e)
            old = L.state_home
            L.state_home = lambda: home
            try:
                if not job["error"]:
                    job["decision"] = XP.build(req, os.path.join(pdir, arm))
                    jsave(os.path.join(pdir, arm, "decision.json"), job["decision"])
                    if arm == "B":
                        job["error"] = exercised(case, sw, job["decision"])
            except Exception as e:
                job["error"] = "cannot build the packet: {}".format(e)
            finally:
                L.state_home = old
            d = job["decision"] or {}
            say("{} {}: {} {} ({} packet(s)){}".format(cid, arm, d.get("action", "error"), d.get("kind", ""), len(d.get("packets") or []),
                                                         " ERROR: " + job["error"] if job["error"] else ""))
            jobs.append(job)
    jsave(os.path.join(a.state, "arms.json"), arms)
    return jobs


def history(case, entries, live):
    """The delta arm's view of the historical thread: its turns up to the fork point. Live, from the
    daemon (unarchiving the thread if needed); dry, the thread's receipts' turns."""
    fork = case["fork"]
    if not live:
        ids = [e["turn"] for e in sorted(entries, key=lambda e: e["dispatched_at"])
               if e.get("kind") == "receipt" and e.get("thread") == case["thread"] and e.get("checkpoint") == "pre-merge"]
        return {"turns": [{"id": i, "status": "completed", "compacted": False} for i in ids], "thread_compactions": 0}
    rc, out, err = hist_call(case["thread"], "thread-turns", "--thread", case["thread"])
    try:
        data = json.loads(out)
    except ValueError:
        raise Failed("cannot read the turns of {}: {}".format(case["thread"], err.strip()))
    ids = [t["id"] for t in data["turns"]]
    if fork["last_turn"] not in ids:
        raise Failed("{} is not a turn of {}".format(fork["last_turn"], case["thread"]))
    data["turns"] = data["turns"][:ids.index(fork["last_turn"]) + 1]
    return data


# ------------------------------------------------------------------ running an arm
def norm(label):
    return re.sub(r"\A(?:\./|a/|b/)", "", label)


def one_turn(thread, packet, schema, cwd, budget, box):
    """Start a turn and wait for it. box["turn"] names the turn as soon as it exists, so the caller can
    charge its tokens whatever happens. A turn that outlives the budget keeps its worker's slot until it
    is seen to finish (it is still running on the daemon, and 3 at once is the limit)."""
    rc, out, err = rpc("turn-start", "--thread", thread, "--input", packet, "--schema", schema, "--cwd", cwd)
    if rc != 0 or not out.strip():
        raise Failed("turn-start failed ({}): {}".format(rc, err.strip()))
    turn = box["turn"] = out.strip().splitlines()[-1]
    fd, report = tempfile.mkstemp(prefix="report.", dir=os.path.dirname(cwd))
    os.close(fd)
    deadline, late = time.time() + budget, False
    while True:
        left = deadline - time.time()
        rc, out, err = rpc("turn-wait", "--thread", thread, "--turn", turn, "--budget", str(min(900, left) if left > 1 else 30),
                           "--schema", schema, "--report", report)
        if rc != 3 or STOP.is_set():
            break
        late = late or left <= 0
    compacted = (jload(report) or {}).get("compacted")
    os.unlink(report)
    late = late or time.time() > deadline
    if rc == 3:
        raise Failed("interrupted while the turn was still running")
    if late:
        raise Failed("the turn outlived the {:g} s budget (it finished with exit {})".format(budget, rc))
    if rc == 4:
        raise Failed("schema-failed: the answer does not match the findings schema")
    if rc != 0:
        raise Failed("turn-wait failed ({}): {}".format(rc, err.strip()))
    try:
        doc = json.loads(out)
        if not isinstance(doc.get("findings"), list):
            raise ValueError
    except ValueError:
        raise Failed("the answer is not findings JSON")
    return doc, compacted


def review(a, job, dec, clone, schema, res, turns):
    """One attempt at a job: a thread and a turn per packet in `clone`, filling `res`. `turns` collects the
    (thread, turn) pairs that ran."""
    flags, shown, approvals, models = [], [], [], []
    for i, pk in enumerate(dec["packets"]):
        hold = weekly_hold(a)
        if hold:
            raise Paused(hold)
        cap = getattr(a, "cap", None)
        if cap is not None:       # every turn asks: any job's completed turn, in flight or in a run file, may have crossed the stop
            now = spent_now(a.state)
            if now >= cap:
                raise Stopped("the token stop: {} tokens spent, stop at {}".format(now, cap))
        fk = job["fork"] if i == 0 else None
        if fk:
            rc, out, err = hist_call(fk["thread"], "thread-fork", "--thread", fk["thread"], "--last-turn", fk["last_turn"], "--cwd", clone)
        else:
            rc, out, err = rpc("thread-start", "--cwd", clone)
        if rc != 0 or not out.strip():
            raise Failed("cannot open a thread ({}): {}".format("fork" if fk else "start", err.strip()))
        thread = out.strip().splitlines()[-1]
        TH.add(thread, "new", job.get("home_path"))
        box = {}
        try:
            doc, compacted = one_turn(thread, pk["file"], schema, clone, a.budget, box)
        finally:
            if box.get("turn"):
                turns.append((thread, box["turn"]))
                use = turn_usage(thread, box["turn"])
                res["tokens"] += use["tokens"]
                flight_add(a.state, job, use["tokens"])
                models.append((use["model"], use["effort"]))
        res["findings"] += [f for f in doc["findings"] if isinstance(f, dict)]
        res["reviewed_files"] += [x for x in doc.get("reviewed_files") or [] if isinstance(x, str)]
        approvals.append(doc.get("verdict") == "approve")
        flags.append(compacted)
        shown += pk.get("shown") or []
        res["slices"] += 1
    res["model"] = ",".join(sorted(set(m or "?" for m, _e in models)))
    res["effort"] = ",".join(sorted(set(e or "?" for _m, e in models)))
    res["verdict"] = "approve" if all(approvals) else "changes"
    res["compacted"] = True if True in flags else (None if None in flags else False)
    if job["framing"]:
        seen = set(norm(x) for x in res["reviewed_files"])
        res["missing"] = sorted(l for l in set(shown) if norm(l) not in seen)[:XP.MISSING_CAP]


def leak_scan(a, job, turns, clone):
    """What the turns' tool calls read that a replayed reviewer must not (spec 7.1; process_replay.codex.forbidden): the original
    checkout and its wt siblings, the replay's state, the snapshot, where October's answers live, the memories watcher's directory,
    every replay home and everything under review-work, but the arm's own checkout and what its own home gives it (skills, plugins,
    rules, AGENTS.md, unless the repository is the chezmoi source; an A/A2 arm also its memories). As process_replay.codex reads a rollout for it: ["<path> in <turn>"]."""
    cx = pkg("codex")
    watch = getattr(a, "memwatch", None) or (jload(os.path.join(a.state, "cases.json"), {}) or {}).get("memwatch") or True
    try:
        home = job.get("home_path") or codex_home()
        # the arms differ only by their home's memories, which an A/A2 arm reads (they are under test); B's home has none
        bounds = cx.forbidden(a.state, {"repo": job["repo"]}, [clone], memwatch=watch, home=home,
                              memories=bool(job.get("memories") and job.get("home_path")))
        return cx.leaks(home, turns, bounds, cwd=clone)
    except pkg("common").Failed as e:
        raise Failed("cannot scan the rollout for leaks: {}".format(e))


def run_job(a, job):
    res = {"verdict": None, "findings": [], "reviewed_files": [], "tokens": 0, "compacted": False, "slices": 0,
           "kind": None, "missing": None, "error": None, "home": job.get("home")}
    clone, own, wasted, voids = None, None, 0, []
    try:
        if job["error"]:
            raise Failed(job["error"])
        dec = job["decision"]
        res["kind"] = dec["kind"]
        if dec["action"] == "refuse":
            raise Failed("refused: " + dec["reason"])
        cdir = os.path.join(a.state, "clones")
        os.makedirs(cdir, exist_ok=True)
        if job.get("scratch"):      # a memories arm: the checkout its packet was built against
            clone = job["scratch"]
        else:
            clone = own = tempfile.mkdtemp(prefix="c.", dir=cdir)
            build_scratch(a, job, clone, cdir)
        schema = os.path.join(CONF, "findings.framed.schema.json" if job["framing"] else "findings.schema.json")
        for attempt in (1, 2):
            turns = []
            review(a, job, dec, clone, schema, res, turns)
            found = leak_scan(a, job, turns, clone) if job.get("scratch") else []
            if not found:
                break
            # a run that leaked (codex.forbidden) may have learned the future: it is void, and runs once more
            voids.append(found)
            if attempt == 2:       # this attempt's tokens are the run's own: spent counts them once, below
                raise Failed("void twice: the reviewer leaked, see codex.forbidden ({})".format("; ".join(found)))
            wasted += res["tokens"]
            res.update(findings=[], reviewed_files=[], tokens=0, compacted=False, slices=0, verdict=None, missing=None)
            shutil.rmtree(clone, ignore_errors=True)
            build_scratch(a, job, clone, cdir)
    except Failed as e:
        res["error"] = str(e)
        res["interrupted"] = STOP.is_set() or isinstance(e, (Paused, Stopped))      # a job that finished before it noticed the stop is complete; a paused or stopped one waits
        if isinstance(e, Paused):
            res["paused"] = e.hold
        if isinstance(e, Stopped):
            res["stopped"] = str(e)
    finally:
        if own:
            shutil.rmtree(own, ignore_errors=True)
        elif clone:
            shutil.rmtree(clone, ignore_errors=True)
    if voids:
        res["voids"] = voids
    path = os.path.join(a.state, "runs", job["case"], job["label"] + ".json")
    prior = jload(path) or {}
    # tokens: this attempt's, which report compares per arm; spent: every attempt's, which the stop counts
    res["spent"] = res["tokens"] + wasted + (prior.get("spent", prior.get("tokens")) or 0)
    with TALLY:         # the run file and the end of the flight in one step: spent_now counts the job's tokens once
        jsave(path, res)
        FLIGHT.pop((a.state, job["case"], job["label"]), None)
    return res


def build_scratch(a, job, clone, cdir):
    """The checkout a reviewer reads, built by the one scratch builder (process_replay.scratch): the objects
    reachable from the round's base and one commit of the round's tree on the branch, the destination at the
    base (as origin/<dest> too when the range names it), so the packet's range resolves. No alternates, no
    remote, no tag, no later commit."""
    sc, common = pkg("scratch"), pkg("common")
    t = job["target"]
    os.makedirs(cdir, exist_ok=True)
    files = tempfile.mkdtemp(prefix="f.", dir=cdir)
    try:
        gitdir, store = job["repo"], os.path.join(job["repo"], "objects")
        tree = common.git(gitdir, "rev-parse", "--verify", t["tip"] + "^{tree}")
        sc.export(store, t["tip"], os.path.join(files, "tree"))
        sc.build(store, t["base"], os.path.join(files, "tree"), clone, t["dest"], t.get("branch") or "replay", t.get("dest_ref"),
                 expect_tree=tree, cache=os.path.join(a.state, "packs"))
    except common.Failed as e:
        raise Failed("scratch checkout failed: {}".format(e))
    finally:
        shutil.rmtree(files, ignore_errors=True)


def flight_add(state, job, tokens):
    with TALLY:
        key = (state, job["case"], job["label"])
        FLIGHT[key] = FLIGHT.get(key, 0) + tokens


def spent_now(state):
    """Tokens spent at this moment: the run files (spent) plus every job in flight's completed turns, so one job sees another's turn the moment
    it completes. The token stop blocks only new turns, so the overshoot is at most one turn per job in flight."""
    with TALLY:
        return spent(state) + sum(n for k, n in FLIGHT.items() if k[0] == state)


def spent(state):
    return sum((lambda r: r.get("spent", r.get("tokens", 0)))(jload(p) or {}) for p in glob.glob(os.path.join(glob.escape(state), "runs", "*", "*.json")))


def on_signal(signum, _frame):
    with LOCK:
        STOP.set()
        victims = [p for p in CHILDREN if p not in PROTECTED]
    for proc in victims:
        try:
            proc.terminate()
        except OSError:
            pass
    raise KeyboardInterrupt()


def token_cap(a, cj):
    """The run's hard stop: --max-tokens, else the cap of the cases' switch (the memories switch has its own)."""
    return a.max_tokens if a.max_tokens is not None else TOKEN_CAPS.get((cj or {}).get("switch"), TOKEN_CAP)


def weekly_hold(a, home=None):
    """{paused, resets_at} when the account's weekly usage is at the pause level, else None (process_replay.codex.weekly_hold). The usage is read from the
    newest rollouts of `home` (default: the Codex home in force) and of the live home, which the replay homes copy from."""
    return pkg("codex").weekly_hold(home or codex_home(), os.path.abspath(getattr(a, "codex_source", None) or os.path.expanduser("~/.codex")))


def reap():
    """Terminate the children a stop left behind and clear the flag, so the archiving that follows can call rpc."""
    STOP.set()
    for proc in list(CHILDREN):
        proc.terminate()
    STOP.clear()


def run_pool(a, pending, total, cap, prog):
    """Run `pending` jobs, JOBS at a time, until they are done or the token stop is reached. Returns what is
    left of them and the tokens spent."""
    running, hold, cut = {}, None, False
    with cf.ThreadPoolExecutor(JOBS) as pool:
        while pending or running:
            while pending and len(running) < JOBS and not hold and not cut:
                total = spent_now(a.state)       # every job in flight counts, not only the finished ones
                if total >= cap:
                    break
                hold = weekly_hold(a)       # before each job; review() asks again before each of its turns
                if hold:
                    prog["paused"] = hold
                    break
                job = pending.popleft()
                running[pool.submit(run_job, a, job)] = job
            if not running:
                break
            done, _left = cf.wait(set(running), return_when=cf.FIRST_COMPLETED, timeout=2)
            jobs_done = [(f, running.pop(f)) for f in done]
            total = spent_now(a.state)
            for f, job in jobs_done:
                res = f.result()
                if res.get("stopped"):      # cut between two packets by the token stop: it is the first to run again
                    cut = True
                    pending.appendleft(job)
                if res.get("paused"):
                    hold = prog["paused"] = res["paused"]
                if res.get("model") and not prog.get("model"):
                    prog.update(model=res["model"], effort=res["effort"])
    return pending, total


def run_home(a, name, jobs, total, cap, prog, source):
    """The jobs of one replay Codex home: stop a daemon a crashed run left on it, make the home (with the case's memories snapshot, when it has one),
    start its daemon, run the jobs with CODEX_HOME aimed at it, archive their threads, stop the daemon. Only
    one replay daemon runs at a time, so the caller takes the homes in turn."""
    cx = pkg("codexhome")
    hold = weekly_hold(a, cx.home_path(name))       # before the daemon starts and before the probe, which is a turn
    if hold:
        prog["paused"] = hold
        return collections.deque(jobs), total
    if spent_now(a.state) >= cap:       # the probe is a turn: the token stop blocks it too
        return collections.deque(jobs), spent_now(a.state)
    snap = next((j["memories"] for j in jobs if j["memories"]), None)
    cx.reclaim(cx.home_path(name))      # a daemon of this home that a crashed run left behind is stopped, not a crash
    home = cx.ensure(a.state, name, snap, bool(snap), source=source)
    cx.start(home)
    try:
        # the arms differ only by this home: prove the daemon serves it (the snapshot's memories reach a turn of A and A2, none reaches B's)
        res = cx.probe(home, bool(snap), rpc=RPC)
        if not res["ok"]:
            raise Failed("the isolation probe of the replay home {} failed ({}); no arm ran: {}".format(
                home, ", ".join(k for k, v in sorted(res["checks"].items()) if not v) or "no check", "; ".join(res["notes"]) or "no note"))
        for j in jobs:
            j["home_path"] = home
        with codex_env(home):
            return run_pool(a, collections.deque(jobs), total, cap, prog)
    finally:
        reap()
        try:
            TH.cleanup(only=home)
        finally:
            try:
                cx.stop(home)
            except pkg("common").Failed as e:
                say("could not stop the replay daemon of {}: {}".format(home, e))


def drop_scratch(jobs):
    """The memories arms' checkouts, which prepare built next to their packets."""
    for j in jobs:
        if j.get("scratch"):
            shutil.rmtree(j["scratch"], ignore_errors=True)


@locked("exclusive", daemon=replay_homes)
def cmd_run(a):
    """Holds the state exclusively from its entry, a dry run too (it builds the packets and the memories arms' checkouts): a second `run`, a
    `cleanup` or any other command on the state refuses before it touches a packet, a checkout, a thread or a daemon. A run that uses
    replay homes holds the replay daemons' lock as well, across every home it takes in turn."""
    global TH
    cj = jload(os.path.join(a.state, "cases.json"))
    if not cj or not cj.get("cases"):
        say("no cases.json (or no cases): run `cases` and have the judges answer first")
        return 2
    TH = Threads(a.state)
    live = not a.dry_run
    cap, source = token_cap(a, cj), getattr(a, "codex_source", None)      # None: codexhome's default, ~/.codex
    a.cap = cap     # review() asks it before each packet's turn
    if live:
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, on_signal)
        TH.cleanup()
    prog = jload(os.path.join(a.state, "progress.json"), {})
    prog.pop("paused", None)
    stopped, interrupted, crash, jobs = None, False, None, []
    try:
        jobs = prepare(a, cj["cases"], live)
        if not live:
            drop_scratch(jobs)
            return 0
        def finished(j):
            run = jload(os.path.join(a.state, "runs", j["case"], j["label"] + ".json"))
            return bool(run) and not (run.get("error") and (a.retry_errors or run.get("interrupted")))
        todo = [j for j in jobs if not finished(j)]
        drop_scratch([j for j in jobs if j not in todo])
        groups = collections.OrderedDict()
        for j in todo:      # a job with a replay home runs on that home's daemon; the others on the one the environment names
            groups.setdefault(j.get("home"), []).append(j)
        total, pending = spent(a.state), collections.deque()
        for name, group in groups.items():
            if name is None:
                pending, total = run_pool(a, collections.deque(group), total, cap, prog)
            else:
                pending, total = run_home(a, name, group, total, cap, prog, source)
            if pending:
                break
        if prog.get("paused"):      # nothing started after the pause; the jobs without a finished run file run on the next `run`
            say("paused: {}; {} job(s) not started (and any a turn was cut from), run again after the reset".format(prog["paused"]["paused"], len(pending)))
        elif pending:
            stopped = {"case": pending[0]["case"], "arm": pending[0]["arm"], "tokens": total}
            say("stopped at the token cap ({} >= {}) before {} {}".format(total, cap, stopped["case"], stopped["arm"]))
    except KeyboardInterrupt:
        interrupted = True
        say("interrupted: archiving every thread this run used")
    except Failed as e:
        crash = str(e)
        say("the run stopped: " + crash)
    except Exception:
        crash = traceback.format_exc()
        say("the run crashed:\n" + crash)
    finally:
        if live:
            reap()
            ok = TH.cleanup()
            drop_scratch(jobs)
            shutil.rmtree(os.path.join(a.state, "clones"), ignore_errors=True)
            prog.update(tokens=spent(a.state), stopped_at=stopped, crashed=crash,
                        finished=not interrupted and stopped is None and crash is None and not prog.get("paused"))
            jsave(os.path.join(a.state, "progress.json"), prog)
            if not ok:
                say("some threads could not be archived: run `cleanup`")
    return 130 if interrupted else (1 if crash else 0)


@locked(lambda a: None if a.dry_run else "exclusive", daemon=replay_homes)
def cmd_cleanup(a):
    global TH
    TH = Threads(a.state)
    if a.dry_run:
        say("would archive: " + ", ".join(t["thread"] for t in jload(TH.path, {"threads": []})["threads"] if not t["done"]))
        return 0
    return 0 if TH.cleanup() else 1


# ------------------------------------------------------------------ match and report
def load_run(state, cid, label):
    run = jload(os.path.join(state, "runs", cid, label + ".json"))
    return run if run and not run.get("error") else None


def match_doc(a, case, arms):
    """The judge-match input of `case` as the finished runs stand now, or None while no run has findings. `match` writes it and
    `report` compares it with what the judge was given: an answer counts only for the input it saw."""
    runs = dict((l, (load_run(a.state, case["id"], l) or {}).get("findings")) for l in sorted(arms.get(case["id"], {})))
    runs = dict((l, [dict((k, f.get(k)) for k in FINDING_KEYS) for f in found if isinstance(f, dict)])
                for l, found in runs.items() if found is not None)
    return {"case": case["id"], "known": case["known"], "runs": runs} if runs else None


def match_current(a, case, arms):
    """Whether an answer to the judge-match of `case` is for the runs and known findings as they stand: false when the input the judge was
    given differs from what `match` would write now. An answer put in the state by hand, with no input beside it, counts."""
    held = jload(os.path.join(a.state, "judge-match", case["id"] + ".json"))
    doc = match_doc(a, case, arms)
    return held is None or (doc is not None and held == dict((k, v) for k, v in doc.items() if k != "case"))


@locked("exclusive")
def cmd_match(a):
    cj, arms = jload(os.path.join(a.state, "cases.json")), jload(os.path.join(a.state, "arms.json"), {})
    for case in (cj or {}).get("cases", []):
        doc = match_doc(a, case, arms)
        if doc is None:
            continue
        say("judge input {}: {} run(s)".format(case["id"], len(doc["runs"])))
        if not a.dry_run:
            judge_put(a, "judge-match", case["id"], doc)
    if not a.dry_run:
        say("`pending` lists the inputs that wait for a judge, with their briefs")
    return 0


def cmd_pending(a):
    """One line per judge input still waiting, kind, id and brief, tab-separated: the input is staged in a directory of its own (process_replay.common),
    and the brief names the input and the answer file there. The judge is handed that brief and nothing else. common.cmd_pending holds the
    state shared."""
    return pkg("common").cmd_pending(a, judge_briefs())


@locked("shared")
def cmd_report(a):
    cj, arms = jload(os.path.join(a.state, "cases.json"), {}), jload(os.path.join(a.state, "arms.json"), {})
    prog = jload(os.path.join(a.state, "progress.json"), {})
    byid = dict((c["id"], c) for c in cj.get("cases", []))
    out, errors, mixed, outdated = {}, [], [], []
    for cid in sorted(set(i for v in (cj.get("selected") or {}).values() for i in v)):
        models = set()
        for label, v in sorted(arms.get(cid, {}).items()):
            run = jload(os.path.join(a.state, "runs", cid, label + ".json"))
            if run and run.get("error"):
                errors.append({"case": cid, "arm": v["arm"], "label": label, "error": run["error"], "tokens": run.get("tokens", 0)})
            if run and run.get("model"):
                models.add((run["model"], run.get("effort")))
        if len(models) > 1:
            mixed.append(cid)
    for sw in REPORT_ORDER:
        ids = (cj.get("selected") or {}).get(sw) or []
        if not ids:
            continue
        x = "F" if sw == "framing" else "B"
        sums = dict((arm, {"hit": 0, "tokens": 0, "compactions": 0, "turns": 0}) for arm in ("A", "A2", "F", "B"))
        n = known = misses = framed = failed = 0
        for cid in ids:
            amap = dict((v["arm"], l) for l, v in arms.get(cid, {}).items())
            ans = judge_got(a, "judge-match", cid)
            if ans is not None and not match_current(a, byid[cid], arms):
                outdated.append(cid)        # its runs or known findings changed since the judge saw them: only `match` and a new answer make it current
                ans = None
            runs = dict((arm, load_run(a.state, cid, l)) for arm, l in amap.items())
            if not amap or ans is None or not all(runs.values()):
                continue
            n += 1
            hits = dict((arm, set()) for arm in amap)
            for m in ans.get("matches", []):
                for arm, l in amap.items():
                    if m.get("label") == l and m.get("finding_index") is not None:
                        hits[arm].add(m.get("known_index"))
            kn = byid[cid]["known"]
            known += len(kn)
            for arm, run in runs.items():
                s = sums[arm]
                s["hit"] += len(hits[arm])
                s["tokens"] += run.get("tokens") or 0
                s["turns"] += run.get("slices") or 0
                s["compactions"] += 1 if run.get("compacted") else 0
            for k in kn:
                if k.get("severity") in ("P0", "P1") and k["index"] in hits.get("A", ()) and k["index"] in hits.get("A2", ()) \
                        and k["index"] not in hits.get(x, ()):
                    misses += 1
            for arm in ("F", "B"):      # every arm with framing counts (spec 5.5); the memories arms have none
                if runs.get(arm) and sw != "memories":
                    framed += 1
                    failed += 1 if runs[arm].get("verdict") == "approve" and runs[arm].get("missing") else 0
        present = set(v["arm"] for cid in ids for v in arms.get(cid, {}).values())
        recall = dict((arm, round(s["hit"] / known, 4) if known else None) for arm, s in sums.items() if arm in present)
        coverage = round(failed / framed, 4) if framed else 0.0
        bar = {"recall": bool(known) and x in present and sums[x]["hit"] >= min(sums["A"]["hit"], sums["A2"]["hit"]),
               "misses": misses == 0, "coverage": coverage <= COVERAGE_LIMIT}
        status = "incomplete" if n < len(ids) or not known else ("pass" if all(bar.values()) else "fail")
        out[sw] = {"status": status, "n": n, "selected": len(ids), "recall": recall, "misses": misses, "coverage": coverage, "bar": bar,
                   "tokens": dict((k, s["tokens"]) for k, s in sums.items() if k in recall),
                   "tokens_per_turn": dict((k, round(s["tokens"] / s["turns"]) if s["turns"] else None) for k, s in sums.items() if k in recall),
                   "compactions": dict((k, s["compactions"]) for k, s in sums.items() if k in recall)}
    first = out.get("framing", {}).get("status")
    for sw, v in out.items():
        if sw not in ("framing", "memories") and v["status"] == "pass" and first != "pass":
            v["status"], v["note"] = "hold", "framing did not pass ({}); every switch stays off".format(first or "not selected")
    lines = ["# Replay report", "", "| switch | status | n | recall A/A2/F/B | P0/P1 misses | coverage failures | tokens A/A2/F/B | compactions A/A2/F/B |",
             "|---|---|---|---|---|---|---|---|"]
    cell = lambda d: "/".join(str(d.get(k, "-")) if d.get(k) is not None else "-" for k in ("A", "A2", "F", "B"))
    for sw, v in out.items():
        lines.append("| {} | {} | {}/{} | {} | {} | {} | {} | {} |".format(
            sw, v["status"], v["n"], v["selected"], cell(v["recall"]), v["misses"], v["coverage"], cell(v["tokens"]), cell(v["compactions"])))
    if "memories" in out:
        lines += ["", "Memories, tokens per turn A/A2/B: " + "/".join(
            str(out["memories"]["tokens_per_turn"].get(k)) if out["memories"]["tokens_per_turn"].get(k) is not None else "-" for k in ("A", "A2", "B"))]
    lines += ["", "Tokens: {}. Model {} effort {}.".format(prog.get("tokens", "unknown"), prog.get("model", "unknown"), prog.get("effort", "unknown"))]
    if prog.get("stopped_at"):
        lines.append("The run stopped at {case} {arm} after {tokens} tokens; the switches that did not finish stay off.".format(**prog["stopped_at"]))
    for sw, v in out.items():
        if v.get("note"):
            lines.append("{}: {}".format(sw, v["note"]))
    if outdated:
        lines.append("The judge-match of these cases was answered for other runs than are there now, so it is not used (run `match`, then `pending`): " + ", ".join(sorted(set(outdated))))
    if mixed:
        lines.append("Arms of these cases ran at different models or efforts, so compare them with care: " + ", ".join(mixed))
    if errors:
        lines += ["", "Error runs ({}; `run --retry-errors` runs them again):".format(len(errors))]
        lines += ["- {case} {arm} ({tokens} tokens): {error}".format(**e) for e in errors]
    text = "\n".join(lines) + "\n"
    say(text)
    if not a.dry_run:
        jsave(os.path.join(a.state, "report.md"), text)
        jsave(os.path.join(a.state, "report.json"), {"switches": out, "progress": prog, "errors": errors, "mixed_models": mixed})
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="xreview-replay")
    ap.add_argument("command", choices=("cases", "run", "match", "report", "cleanup", "pending"))
    ap.add_argument("--switch", choices=("memories",), help="the memories switch: cases selects its cases (needs --memwatch), and every command "
                    "defaults to its own state directory, $XDG_STATE_HOME/xreview/replay/memories")
    ap.add_argument("--memwatch", metavar="DIR", help="cases --switch memories: the memories watcher's directory (memwatch/)")
    ap.add_argument("--codex-source", metavar="DIR", help="run: the Codex home the replay homes copy their config from (default ~/.codex, never an inherited CODEX_HOME)")
    ap.add_argument("--state", default=None, help="default $XDG_STATE_HOME/xreview/replay/<date> (memories: .../replay/memories)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-tokens", type=int, default=None, help="the hard stop (default {}; the memories switch {})".format(TOKEN_CAP, TOKEN_CAPS["memories"]))
    ap.add_argument("--budget", type=float, default=TURN_BUDGET)
    ap.add_argument("--retry-errors", action="store_true", help="run: run again the arms whose run file is an error")
    a = ap.parse_args(argv)
    a.state = os.path.abspath(a.state or os.path.join(L.state_home(), "xreview", "replay", "memories" if a.switch == "memories" else date.today().isoformat()))
    os.makedirs(a.state, exist_ok=True)
    try:
        return {"cases": cmd_cases, "run": cmd_run, "match": cmd_match, "report": cmd_report, "cleanup": cmd_cleanup, "pending": cmd_pending}[a.command](a)
    except (Failed, pkg("common").Failed) as e:
        sys.stderr.write("xreview-replay: {}\n".format(e))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
