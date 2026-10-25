#!/usr/bin/python3
"""xreview-replay - measure each review-packet switch against today's packets on past reviews.

Design: docs/superpowers/specs/2026-10-25-xreview-review-packets-design.md, section 5. It imports
the working tree's packet builder and calls the working tree's xreview-rpc (XREVIEW_REPLAY_RPC
overrides it), so nothing needs deploying. It never calls `xreview dispatch` and never touches
the pane, the review ledger or the round counter. `run` needs the daemon socket: run it unsandboxed.

  cases   [--state DIR]   pick candidate rounds from the ledgers and rollouts, write the blind
                          judge inputs judge-known/<round>.json, and, once judge-known/<round>.answer.json
                          exist, select the cases per switch into cases.json
  run     [--state DIR]   build every arm's packet, run the arms through the daemon (3 turns at
                          once, hard stop at --max-tokens), archive every thread it used
  match   [--state DIR]   write the blind matching inputs judge-match/<case>.json
  report  [--state DIR]   read judge-match/<case>.answer.json, print the pass bar per switch
  cleanup [--state DIR]   archive the threads a crashed run left behind

--dry-run builds and selects but starts no turn and calls no daemon. The default state directory is
$XDG_STATE_HOME/xreview/replay/<date>. Raw run files are never committed.

Judge files (the controller dispatches the judges between phases):
  judge-known/<round>.json         {case, findings:[{index, severity, ...}], interdiff}
  judge-known/<round>.answer.json  {verdicts:[{index, answer: yes|no|unclear}]}
  judge-match/<case>.json          {case, known:[...], runs:{label:[findings]}}
  judge-match/<case>.answer.json   {matches:[{known_index, label, finding_index|null}]}
A round is named by its review's nonce; a case by <nonce>.<class>: pre (pre-merge, fresh thread),
inc (incremental: delta), big (round 1, too big for a fresh thread), ctx (a later round whose thread
would have been full). The class names are neutral on purpose: judges see them.

Written for /usr/bin/python3 (3.9).
"""
import argparse
import collections
import concurrent.futures as cf
import copy
import glob
import importlib.util
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
TURN_BUDGET = 3600                                     # seconds one turn may take
UNLIMITED = 10 ** 12                                   # the cap of today's dispatch with the override set
SWITCH_ORDER = ("framing", "omit_plans", "delta", "fit")
KNOWN_SEVERITIES = ("P0", "P1", "P2")
MAX_INTERDIFF = 150000
COVERAGE_LIMIT = 0.1                                   # spec 5.5
MARKS = (b'"task_started"', b'"task_complete"', b'"token_count"', b'"compacted"', b'"turn_context"')

STOP = threading.Event()
CHILDREN = set()
LOCK = threading.RLock()


class Failed(Exception):
    pass


def say(msg):
    print(msg, flush=True)


def jload(path, default=None):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return default


def jsave(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp{}".format(os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(data if isinstance(data, str) else json.dumps(data, indent=2))
    os.replace(tmp, path)


def sh(argv, timeout=None):
    """(rc, stdout, stderr) of a child, which an interrupt can terminate."""
    if STOP.is_set():
        return 1, "", "stopped"
    env = L.git_env() if argv and argv[0] == "git" else None
    with LOCK:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        CHILDREN.add(proc)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
    finally:
        CHILDREN.discard(proc)
    return proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def rpc(*args):
    argv = [RPC] if os.access(RPC, os.X_OK) else ["/usr/bin/python3", "-I", RPC]
    return sh(argv + list(args))


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
            raw = subprocess.run(["zstd", "-dc", path], capture_output=True, timeout=300).stdout
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


def rollout_total(thread):
    """The thread's cumulative tokens: the latest token_count's total_token_usage."""
    total = 0
    for rec in rollout_records(thread):
        p = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
        if rec.get("type") == "event_msg" and p.get("type") == "token_count" and isinstance(p.get("info"), dict):
            use = p["info"].get("total_token_usage")
            if isinstance(use, dict) and isinstance(use.get("total_tokens"), int):
                total = use["total_tokens"]
    return total


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
                chains[e["thread"]].append({"nonce": e["nonce"], "at": e["dispatched_at"], "thread": e["thread"],
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


def case_of(c, klass, **extra):
    r = c["round"]
    t = r["target"]
    case = {"id": "{}.{}".format(r["nonce"], klass), "round": r["nonce"], "class": klass, "repo": t["repo"],
            "thread": r["thread"], "turn": r["turn"], "k": r["k"], "at": r["at"], "target": t, "findings": c["findings"],
            "fork": None, "switches": []}
    case.update(extra)
    return case


def cmd_cases(a):
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
            fresh.append(case_of(c, "ctx", switches=["fit"], fork=fork, own_compacted=info["compacted"]))
    fresh.sort(key=lambda c: c["at"], reverse=True)
    fresh.sort(key=lambda c: not c["own_compacted"])
    pool = dict((c["id"], c) for c in plans + other + delta + big + fresh[:QUOTA])
    judged = set()
    for c in pool.values():
        n = c["round"]
        if n not in judged:
            judged.add(n)
            src = next(x for x in cands if x["round"]["nonce"] == n)
            jsave(os.path.join(a.state, "judge-known", n + ".json"), judge_input(src))
        ans = jload(os.path.join(a.state, "judge-known", n + ".answer.json"))
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
    say("judge inputs: {} round(s) in {}".format(len(judged), os.path.join(a.state, "judge-known")))
    if not a.dry_run:
        jsave(os.path.join(a.state, "cases.json"), {"created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "cases": chosen, "selected": dict((s, [c["id"] for c in v]) for s, v in selected.items())})
    return 0


# ------------------------------------------------------------------ threads
class Threads(object):
    """Every thread the run creates or unarchives, recorded as it happens in threads.json, so
    cleanup archives them even after a crash."""

    def __init__(self, state):
        self.path = os.path.join(state, "threads.json")

    def add(self, thread, kind):
        with LOCK:
            data = jload(self.path, {"threads": []})
            data["threads"].append({"thread": thread, "kind": kind, "done": False})
            jsave(self.path, data)

    def cleanup(self):
        with LOCK:
            data = jload(self.path, {"threads": []})
        for t in data["threads"]:
            if not t["done"]:
                rc, _o, err = rpc("thread-archive", "--thread", t["thread"])
                if rc == 0:
                    t["done"] = True
                else:
                    say("could not archive {}: {}".format(t["thread"], err.strip()))
        with LOCK:
            jsave(self.path, data)
        return all(t["done"] for t in data["threads"])


TH = None
UNARCHIVE = threading.Lock()


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
    if case["class"] == "pre":
        return [("A", None), ("A2", None), ("F", None)] + ([("B", "omit_plans")] if "omit_plans" in case["switches"] else [])
    return [("A", None), ("A2", None), ("B", "delta" if case["class"] == "inc" else "fit")]


def forks(case, arm):
    return bool(case.get("fork")) and (case["class"] == "inc" or arm in ("A", "A2"))


def prepare(a, cases, live):
    """Build every arm's packet with the module, as dispatch would, and return the jobs in the
    spec's order: framing with omit_plans, then delta, then fit."""
    arms = jload(os.path.join(a.state, "arms.json"), {})
    taken = set(l for m in arms.values() for l in m)
    order = {"pre": 0, "inc": 1, "big": 2, "ctx": 2}
    rounds = dict((r["nonce"], r) for r in load_rounds())
    jobs = []
    for case in sorted(sorted(cases, key=lambda c: c["at"], reverse=True), key=lambda c: order[c["class"]]):
        cid, t = case["id"], case["target"]
        pdir = os.path.join(a.state, "packets", cid)
        jsave(os.path.join(pdir, "body.md"), "Pre-merge review of {} against {}: the change is {}. Review the change as it "
              "now stands.\n".format(t.get("branch") or "the branch", t["dest"], t["range"]))
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
            on = {"A": [], "A2": [], "F": ["framing"]}.get(arm) if arm != "B" else ["framing", sw]
            conf = os.path.join(pdir, arm + ".conf")
            jsave(conf, "".join("{}={}\n".format(k, "on" if k in on else "off") for k in XP.SWITCHES))
            req = {"checkpoint": "pre-merge", "body_file": os.path.join(pdir, "body.md"),
                   "reviewer_md": os.path.join(CONF, "reviewer.md"), "framing_md": os.path.join(CONF, "reviewer-framing.md"),
                   "cap": UNLIMITED, "switches_file": conf, "codex_home": None, "targets": [t], "specs": [t["range"]],
                   "missed": [], "thread": case["thread"] if (arm == "B" and sw == "delta") else None,
                   "turns_file": turns_file if (arm == "B" and sw == "delta") else None}
            job = {"case": cid, "arm": arm, "switch": sw, "framing": "framing" in on, "repo": t["repo"], "tip": t["tip"],
                   "fork": case["fork"] if forks(case, arm) else None, "error": hist_error if (arm == "B" and sw == "delta") else None,
                   "decision": None}
            old = L.state_home
            L.state_home = lambda: home
            try:
                if not job["error"]:
                    job["decision"] = XP.build(req, os.path.join(pdir, arm))
                    jsave(os.path.join(pdir, arm, "decision.json"), job["decision"])
            except Exception as e:
                job["error"] = "cannot build the packet: {}".format(e)
            finally:
                L.state_home = old
            label = next((l for l, v in arms.get(cid, {}).items() if v["arm"] == arm), None)
            if label is None:
                label = os.urandom(4).hex()
                while label in taken:
                    label = os.urandom(4).hex()
                taken.add(label)
                arms.setdefault(cid, {})[label] = {"arm": arm, "switch": sw}
            job["label"] = label
            d = job["decision"] or {}
            say("{} {}: {} {} ({} packet(s))".format(cid, arm, d.get("action", "error"), d.get("kind", ""), len(d.get("packets") or [])))
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


def one_turn(thread, packet, schema, cwd, budget):
    rc, out, err = rpc("turn-start", "--thread", thread, "--input", packet, "--schema", schema, "--cwd", cwd)
    if rc != 0 or not out.strip():
        raise Failed("turn-start failed ({}): {}".format(rc, err.strip()))
    turn = out.strip().splitlines()[-1]
    fd, report = tempfile.mkstemp(prefix="report.", dir=os.path.dirname(cwd))
    os.close(fd)
    deadline = time.time() + budget
    while True:
        rc, out, err = rpc("turn-wait", "--thread", thread, "--turn", turn, "--budget", str(min(900, max(1, deadline - time.time()))),
                           "--schema", schema, "--report", report)
        if rc == 3 and time.time() < deadline and not STOP.is_set():
            continue
        break
    compacted = (jload(report) or {}).get("compacted")
    os.unlink(report)
    if rc not in (0, 4):
        raise Failed("turn-wait failed ({}): {}".format(rc, err.strip()))
    try:
        doc = json.loads(out)
        if not isinstance(doc.get("findings"), list):
            raise ValueError
    except ValueError:
        raise Failed("the answer is not findings JSON")
    return doc, compacted


def run_job(a, job):
    res = {"verdict": None, "findings": [], "reviewed_files": [], "tokens": 0, "compacted": False, "slices": 0,
           "kind": None, "missing": None, "error": None}
    clone = None
    try:
        if job["error"]:
            raise Failed(job["error"])
        dec = job["decision"]
        res["kind"] = dec["kind"]
        if dec["action"] == "refuse":
            raise Failed("refused: " + dec["reason"])
        cdir = os.path.join(a.state, "clones")
        os.makedirs(cdir, exist_ok=True)
        clone = tempfile.mkdtemp(prefix="c.", dir=cdir)
        for argv in (["git", "clone", "--shared", "--no-checkout", "-q", job["repo"], clone],
                     ["git", "-C", clone, "checkout", "-q", "--detach", job["tip"]]):
            rc, _o, err = sh(argv)
            if rc != 0:
                raise Failed("scratch checkout failed: " + err.strip())
        schema = os.path.join(CONF, "findings.framed.schema.json" if job["framing"] else "findings.schema.json")
        flags, shown, approvals = [], [], []
        for i, pk in enumerate(dec["packets"]):
            fk = job["fork"] if i == 0 else None
            if fk:
                rc, out, err = hist_call(fk["thread"], "thread-fork", "--thread", fk["thread"], "--last-turn", fk["last_turn"], "--cwd", clone)
            else:
                rc, out, err = rpc("thread-start", "--cwd", clone)
            if rc != 0 or not out.strip():
                raise Failed("cannot open a thread ({}): {}".format("fork" if fk else "start", err.strip()))
            thread = out.strip().splitlines()[-1]
            TH.add(thread, "new")
            before = rollout_total(thread)
            doc, compacted = one_turn(thread, pk["file"], schema, clone, a.budget)
            res["tokens"] += max(0, rollout_total(thread) - before)
            res["findings"] += [f for f in doc["findings"] if isinstance(f, dict)]
            res["reviewed_files"] += [x for x in doc.get("reviewed_files") or [] if isinstance(x, str)]
            approvals.append(doc.get("verdict") == "approve")
            flags.append(compacted)
            shown += pk.get("shown") or []
            res["slices"] += 1
        res["verdict"] = "approve" if all(approvals) else "changes"
        res["compacted"] = True if True in flags else (None if None in flags else False)
        if job["framing"]:
            seen = set(norm(x) for x in res["reviewed_files"])
            res["missing"] = sorted(l for l in set(shown) if norm(l) not in seen)[:XP.MISSING_CAP]
    except Failed as e:
        res["error"] = str(e)
    finally:
        if clone:
            shutil.rmtree(clone, ignore_errors=True)
    if STOP.is_set():
        return None
    jsave(os.path.join(a.state, "runs", job["case"], job["label"] + ".json"), res)
    return res


def spent(state):
    return sum((jload(p) or {}).get("tokens", 0) for p in glob.glob(os.path.join(glob.escape(state), "runs", "*", "*.json")))


def on_signal(signum, _frame):
    STOP.set()
    for proc in list(CHILDREN):
        try:
            proc.terminate()
        except OSError:
            pass
    raise KeyboardInterrupt()


def cmd_run(a):
    global TH
    cj = jload(os.path.join(a.state, "cases.json"))
    if not cj or not cj.get("cases"):
        say("no cases.json (or no cases): run `cases` and have the judges answer first")
        return 2
    TH = Threads(a.state)
    live = not a.dry_run
    if live:
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, on_signal)
        TH.cleanup()
    prog = jload(os.path.join(a.state, "progress.json"), {})
    stopped, interrupted = None, False
    try:
        jobs = prepare(a, cj["cases"], live)
        if not live:
            return 0
        pending = collections.deque(j for j in jobs if not os.path.isfile(os.path.join(a.state, "runs", j["case"], j["label"] + ".json")))
        total, running = spent(a.state), set()
        with cf.ThreadPoolExecutor(JOBS) as pool:
            while pending or running:
                while pending and len(running) < JOBS and total < a.max_tokens:
                    running.add(pool.submit(run_job, a, pending.popleft()))
                if not running:
                    break
                done, running = cf.wait(running, return_when=cf.FIRST_COMPLETED, timeout=2)
                total = spent(a.state)
                if done and not prog.get("model"):
                    prog.update(model_of(TH))
        if pending:
            stopped = {"case": pending[0]["case"], "arm": pending[0]["arm"], "tokens": total}
            say("stopped at the token cap ({} >= {}) before {} {}".format(total, a.max_tokens, stopped["case"], stopped["arm"]))
    except KeyboardInterrupt:
        interrupted = True
        say("interrupted: archiving every thread this run used")
    finally:
        if live:
            STOP.set()
            for proc in list(CHILDREN):
                proc.terminate()
            STOP.clear()
            ok = TH.cleanup()
            shutil.rmtree(os.path.join(a.state, "clones"), ignore_errors=True)
            prog.update(tokens=spent(a.state), stopped_at=stopped, finished=not interrupted and stopped is None)
            jsave(os.path.join(a.state, "progress.json"), prog)
            if not ok:
                say("some threads could not be archived: run `cleanup`")
    return 130 if interrupted else 0


def model_of(th):
    """The model and effort of the first new thread whose rollout names them (spec 5.6: recorded)."""
    for t in jload(th.path, {"threads": []})["threads"]:
        if t["kind"] != "new":
            continue
        for info in turns_of(t["thread"]).values():
            if info["model"]:
                return {"model": info["model"], "effort": info["effort"]}
        _TURNS.pop(t["thread"], None)
    return {}


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


def cmd_match(a):
    cj, arms = jload(os.path.join(a.state, "cases.json")), jload(os.path.join(a.state, "arms.json"), {})
    for case in (cj or {}).get("cases", []):
        runs = dict((l, (load_run(a.state, case["id"], l) or {}).get("findings")) for l in sorted(arms.get(case["id"], {})))
        runs = dict((l, f) for l, f in runs.items() if f is not None)
        if not runs:
            continue
        doc = {"case": case["id"], "known": case["known"], "runs": runs}
        say("judge-match/{}.json: {} run(s)".format(case["id"], len(runs)))
        if not a.dry_run:
            jsave(os.path.join(a.state, "judge-match", case["id"] + ".json"), doc)
    return 0


def cmd_report(a):
    cj, arms = jload(os.path.join(a.state, "cases.json"), {}), jload(os.path.join(a.state, "arms.json"), {})
    prog = jload(os.path.join(a.state, "progress.json"), {})
    byid = dict((c["id"], c) for c in cj.get("cases", []))
    out = {}
    for sw in SWITCH_ORDER:
        ids = (cj.get("selected") or {}).get(sw) or []
        if not ids:
            continue
        x = "F" if sw == "framing" else "B"
        sums = dict((arm, {"hit": 0, "tokens": 0, "compactions": 0}) for arm in ("A", "A2", "F", "B"))
        n = known = misses = framed = failed = 0
        for cid in ids:
            amap = dict((v["arm"], l) for l, v in arms.get(cid, {}).items())
            ans = jload(os.path.join(a.state, "judge-match", cid + ".answer.json"))
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
                s["compactions"] += 1 if run.get("compacted") else 0
            for k in kn:
                if k.get("severity") in ("P0", "P1") and k["index"] in hits.get("A", ()) and k["index"] in hits.get("A2", ()) \
                        and k["index"] not in hits.get(x, ()):
                    misses += 1
            for arm in ("F", "B"):      # every arm with framing counts (spec 5.5)
                if runs.get(arm):
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
                   "compactions": dict((k, s["compactions"]) for k, s in sums.items() if k in recall)}
    first = out.get("framing", {}).get("status")
    for sw, v in out.items():
        if sw != "framing" and v["status"] == "pass" and first != "pass":
            v["status"], v["note"] = "hold", "framing did not pass ({}); every switch stays off".format(first or "not selected")
    lines = ["# Replay report", "", "| switch | status | n | recall A/A2/F/B | P0/P1 misses | coverage failures | tokens A/A2/F/B | compactions A/A2/F/B |",
             "|---|---|---|---|---|---|---|---|"]
    cell = lambda d: "/".join(str(d.get(k, "-")) if d.get(k) is not None else "-" for k in ("A", "A2", "F", "B"))
    for sw, v in out.items():
        lines.append("| {} | {} | {}/{} | {} | {} | {} | {} | {} |".format(
            sw, v["status"], v["n"], v["selected"], cell(v["recall"]), v["misses"], v["coverage"], cell(v["tokens"]), cell(v["compactions"])))
    lines += ["", "Tokens: {}. Model {} effort {}.".format(prog.get("tokens", "unknown"), prog.get("model", "unknown"), prog.get("effort", "unknown"))]
    if prog.get("stopped_at"):
        lines.append("The run stopped at {case} {arm} after {tokens} tokens; the switches that did not finish stay off.".format(**prog["stopped_at"]))
    for sw, v in out.items():
        if v.get("note"):
            lines.append("{}: {}".format(sw, v["note"]))
    text = "\n".join(lines) + "\n"
    say(text)
    if not a.dry_run:
        jsave(os.path.join(a.state, "report.md"), text)
        jsave(os.path.join(a.state, "report.json"), {"switches": out, "progress": prog})
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="xreview-replay")
    ap.add_argument("command", choices=("cases", "run", "match", "report", "cleanup"))
    ap.add_argument("--state", default=os.path.join(L.state_home(), "xreview", "replay", date.today().isoformat()))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-tokens", type=int, default=TOKEN_CAP)
    ap.add_argument("--budget", type=float, default=TURN_BUDGET)
    a = ap.parse_args(argv)
    a.state = os.path.abspath(a.state)
    os.makedirs(a.state, exist_ok=True)
    return {"cases": cmd_cases, "run": cmd_run, "match": cmd_match, "report": cmd_report, "cleanup": cmd_cleanup}[a.command](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
