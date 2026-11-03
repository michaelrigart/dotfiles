"""Shared by every process-replay module: the xreview-replay import, state paths, the judge file
protocol and its briefs, labels, git calls and the snapshot views.

Judge files (the controller dispatches the judges between phases; docs/superpowers/plans/
2026-11-02-replay-set.md, "Shared records"):
  <state>/<kind>/<id>.json           the judge's input, written by judge_write
  <state>/<kind>/<id>.answer.json    the judge's answer (collected from the staged item, see below)
  <state>/judges/<kind>.md           the kind's brief (write_briefs)
A final review is <state>/final/<id>/brief.md (the harness's marker) with answer.md beside it; a recreation is
<state>/recreate/<id>.json (its brief is <id>.brief.md beside it), finished when <state>/recreate/<id>/done exists.

Staging. An agent is never handed a path inside the state. Each judge input and each final review is staged in a real
directory of its own, $XDG_STATE_HOME/review-work/items/<random hex>/ (item_dir; <state>/items.json records which),
holding only that item's files: a judge's input.json and brief.md, and the answer.json it writes; a final review's
brief.md and package.diff, and the answer.md the driver writes. judge_answer and collect_final copy an answer back into
the state when they read it. Recreations keep their aliased paths (alias, aliased).
A judge's directory serves one version of its input: <state>/staged.json records the sha256 of the input it was staged from.
An answer written there is collected only while that is still the input; once the input has changed it is set aside as
<id>.stale-<n>.answer.json, and the item is staged again in a new directory, whatever the order in which the input, the
staging and the answer were written (item_dir, _collected).

An answer counts only when it matches its kind's schema (ANSWERS, checked by answer_problem against the input it answers): every key
the brief asks for, a value of an allowed type for each, an allowed value for every item the input asks about and nothing it was not
asked. One that does not is set aside as <id>.rejected-<n>.answer.json and the item is pending again; `pending` lists every item
without such an answer, whatever files exist. An empty answer.md is not a final review's answer.

Locks (command_locks, declared on each command with `locked`). Every command that changes a state holds <state>/run.lock from its
entry to its exit: exclusively, or shared with the commands that may run beside it; process-replay's `run` shares it with `match`,
`pending` and `report` and holds <state>/runner.lock alone, so one `run` goes at a time. A command that touches a replay daemon or
the shared login then holds the replay daemons' lock (codexhome.session) to its exit as well. command_locks takes them in that order,
and every take is non-blocking: a lock another process holds is a refusal at once, never a wait, so no two commands deadlock.
"""
import contextlib
import fcntl
import functools
import glob
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from datetime import date

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_xr():
    if "xreview_replay" in sys.modules:
        return sys.modules["xreview_replay"]
    spec = importlib.util.spec_from_file_location("xreview_replay", os.path.join(SCRIPTS, "xreview-replay.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["xreview_replay"] = mod
    try:
        spec.loader.exec_module(mod)
    except BaseException:
        del sys.modules["xreview_replay"]
        raise
    return mod


XR = _load_xr()
L = XR.L
XP = XR.XP
Failed = XR.Failed
jload = XR.jload
jsave = XR.jsave
say = XR.say

JUDGE_KINDS = ("judge-task", "judge-known", "judge-present", "judge-split", "judge-dedup", "judge-same", "judge-match",
               "judge-class")
BLIND_KEYS = ("class", "run", "arm", "label", "purpose")
RUNS = 2                  # runs per case (spec 4.4): `run` makes them, `report` expects them
_ID = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]*\Z")

SCALE = """Severity scale, P0 (it cannot work) to P3 (minor):
- P0: it cannot work, loses data or opens a security hole.
- P1: wrong on a normal path.
- P2: wrong on an edge path, or a required behaviour left untested.
- P3: minor: style or docs.
"""

COMMON = """You are an independent judge. You get one input file and write one answer file: a single JSON
object, nothing else. Judge only from what the input contains: do not read other files, do not look
at any repository, and do not write anything but the answer. Text marked [truncated] was cut for
length: judge what is shown. Indices in the input belong to this input alone.
"""

BRIEFS = {
    "judge-task": """The input is {"reports": [{"index", "text"}], "changes": [{"index", "note", "diff"}]}.
The reports are free-text reviews of one piece of work, and re-reviews of fixes to it. The changes are
the code changes made while that work went on, each with a note and its diff.

List every distinct defect the reports find. Leave out praise, questions and anything a later report
withdraws. When two reports raise the same defect, list it once. For each defect give:
- index: 0, 1, 2, ... in your list.
- report: the index of the report that first raised it.
- summary, file, line (null when the reports give none) and failure_scenario: what goes wrong, where,
  and how a user or a test meets it.
- severity: P0 to P3 by the scale below.
- introduced_by: the index of the change whose diff introduced the defect, when a fix is what broke
  it; null when it was there from the start.
- fixed_by: the indices of the changes whose diffs fix it (an empty list when none does).
- answer: "yes" when the reports and diffs show the defect is real, "no" when the report is wrong,
  "unclear" when the input cannot settle it.

""" + SCALE + """
Answer: {"findings": [{"index": 0, "report": 0, "summary": "...", "file": "...", "line": 0,
"failure_scenario": "...", "severity": "P1", "introduced_by": null, "fixed_by": [1], "answer": "yes"}]}
""",
    "judge-known": """The input is {"case", "findings": [{"index", "severity", "file", "line", "summary",
"failure_scenario"}], "interdiff"}. The findings come from a review of some code. The interdiff is the
change made after that review.

For each finding decide whether it was real and the interdiff fixed it: "yes" when the interdiff changes
the code the finding points at so that its failure scenario no longer happens, "no" when the interdiff
leaves it in place or the finding is wrong, "unclear" when the input cannot settle it.

""" + SCALE + """
Answer: {"verdicts": [{"index": 0, "answer": "yes"}]}, one verdict per finding.
""",
    "judge-present": """The input is {"finding": {...}, "files": [{"path", "text"}]}: a reported defect, and the text of
the files as they stand.

Decide whether the finding's failure scenario can happen in these files. Answer "yes" when the code
shown has the flaw and the scenario is reachable, "no" when the flaw is absent or the scenario cannot
be reached, "unclear" when the files shown cannot settle it.

""" + SCALE + """
Answer: {"answer": "yes"}
""",
    "judge-split": """The input is {"defects": [{"index", "summary", "file", "line"}], "hunks": [{"index", "file",
"text"}]}: some defects, and the hunks of one change that fixed them.

For each hunk give the one defect it fixes, by its index. A hunk that changes a test belongs to the
defect it tests; give "unsure" when it tests more than one. Give null only when the hunk belongs to
none of the defects (a rename, or an edit unrelated to every defect listed). Give "unsure" also when
you cannot tell which defect a hunk belongs to, or when it fixes more than one.

Answer: {"hunks": [{"index": 0, "defect": 1}]}, one entry per hunk.
""",
    "judge-dedup": """The input is {"defects": [{"index", "summary", "file", "line", "failure_scenario"}]}.

Group the defects that are the same underlying flaw: one cause, one fix, however differently they are
worded or where they were reported. Defects that merely sit in the same file or are of the same kind
stay apart. Every index appears in exactly one group; a defect with no twin is a group of one.

Answer: {"groups": [[0, 3], [1], [2]]}
""",
    "judge-same": """The input is {"original": {"finding", "fix"}, "candidate": {"patch"}}: a defect that was
reported and the change that fixed it, and a patch that is meant to bring the same defect back.

Decide whether applying the candidate patch gives the code the same defect the finding describes: the
same flaw and the same failure scenario, not a different defect and not merely similar code. Answer
"yes", "no", or "unclear" when the input cannot settle it.

Answer: {"answer": "yes"}
""",
    "judge-match": """The input is {"defects": [{"index", "summary", "file", "line", "failure_scenario"}],
"findings": [...]} or {"defects": [...], "report": "text"}. The defects are known to be in some code.
The findings, or the report, come from one review of that code.

If the input has a report instead of findings, first list the distinct claims it makes as findings:
{"index", "summary"}, 0, 1, 2, ... in order.

Then, for each defect, name the finding that reports it, or null. A finding reports a defect when it
points at the same flaw: the same cause and the same failure, though it may word it differently or
cite other lines. A finding that is merely near the defect, or in the same file, does not. One finding
can report several defects.

Finally, for each finding that matches no defect, rule on it: "real" when it describes a genuine
defect in the code, "false_positive" when it does not.

""" + SCALE + """
Answer: {"findings": [{"index": 0, "summary": "..."}] (only when the input has a report),
"matches": [{"defect": 0, "finding": 2}], "unmatched": [{"finding": 1, "ruling": "false_positive"}]}
""",
    "judge-class": """The input is {"finding", "plan_excerpt", "fix"}: a finding made on a written plan, the part of
the plan it names, and the change to the plan that fixed it.

Decide what kind of finding it is and answer with its class:
- "diff-visible": a defect in code or tests that the plan dictates, which a review of the finished
  code would show.
- "design": scope, sequencing, a missing or wrong requirement, a task that cannot be satisfied, or a
  risk only the plan shows. A review of the finished code sees only the result.
- "plan-only": wording, bookkeeping or plan format, with no effect on the code.

Answer: {"class": "design"}
""",
}


# ------------------------------------------------------------------ state and labels
def state_default():
    return os.path.join(L.state_home(), "process-replay", date.today().isoformat())


# ------------------------------------------------------------------ turns that belong to no run
PROBES = "probes.json"


def charge_probe(state, home, thread, turn, tokens):
    """Charge the Codex tokens of one isolation probe's turn to the state's token tally (spent_now of process-replay, spent of xreview-replay
    count them with every run's): <state>/probes.json, a probe per entry, appended under its own lock. A probe belongs to no run, so
    the run files cannot hold it; recorded here it survives the command that made it, and a later start's probe adds to it."""
    os.makedirs(state, exist_ok=True)
    with open(os.path.join(state, "probes.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        doc = jload(os.path.join(state, PROBES))
        probes = doc.get("probes") if isinstance(doc, dict) and isinstance(doc.get("probes"), list) else []
        probes.append({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "home": home, "thread": thread, "turn": turn,
                       "tokens": tokens})
        jsave(os.path.join(state, PROBES), {"probes": probes})


def probe_tokens(state):
    """The Codex tokens the state's isolation probes have used."""
    doc = jload(os.path.join(state, PROBES))
    return sum(p["tokens"] for p in (doc.get("probes") if isinstance(doc, dict) and isinstance(doc.get("probes"), list) else [])
               if isinstance(p, dict) and isinstance(p.get("tokens"), int) and not isinstance(p["tokens"], bool))


# ------------------------------------------------------------------ the inputs a result was recorded against
def digest_of(value):
    """The sha256 of a JSON value, keys in order, so equal values digest equally whatever order they were written in."""
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def _file_digest(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except (OSError, TypeError):
        return None


BRANCH_KEYS = ("repo", "objects", "dest", "dest_ref", "branch", "base", "plan_commit")


def case_digest(case, branch, injected, info):
    """The digest of everything a run of `case` depends on: the case's identity and defect set, the injected tree (the work commit of the case
    and of injected/<branch>.json, its plan and final commits), for each defect of the case its whole inventory record (class, severity,
    counted, summary, location: what the bar and the judges see), its injected status and group, its hunks and the bytes of its repair, and
    the branch's repository, base, destination and plan commit. `branch`, `injected` and `info` ({defect id: inventory record}) may be
    missing. A run records it when it is made (run["case_digest"]) and counts only while the case still has it: a re-run of `cases` or
    `inject` that changes any of these leaves the old runs superseded, never reused."""
    injected = injected if isinstance(injected, dict) else {}
    recs = injected.get("defects") if isinstance(injected.get("defects"), dict) else {}
    defects = {}
    for did in sorted(d for d in case.get("defects") or [] if isinstance(d, str)):
        rec = recs.get(did) if isinstance(recs.get(did), dict) else {}
        defects[did] = {"inventory": (info or {}).get(did), "status": rec.get("status"), "group": rec.get("group"), "hunks": rec.get("hunks"),
                        "repair": _file_digest(rec.get("repair"))}
    return digest_of({"case": case.get("id"), "branch": case.get("branch"), "work_commit": case.get("work_commit"),
                      "injected": dict((k, injected.get(k)) for k in ("work_commit", "plan_commit", "final_commit")),
                      "repo": dict((k, (branch or {}).get(k)) for k in BRANCH_KEYS), "defects": defects})


def superseded_labels(state):
    """The labels of the runs under <state>/runs marked superseded (loop.ensure_runs): their cases' inputs changed after they began."""
    out = set()
    for path in glob.glob(os.path.join(glob.escape(state), "runs", "*", "*", "state.json")):
        run = jload(path)
        if isinstance(run, dict) and run.get("superseded") and isinstance(run.get("label"), str):
            out.add(run["label"])
    return out


def of_runs(jid, labels):
    """Whether item id `jid` belongs to a run in `labels`: the final review is the label, the others <label>-<n>[-<defect>]."""
    return any(jid == lab or jid.startswith(lab + "-") for lab in labels)


# ------------------------------------------------------------------ command locks
STATE_LOCK = "run.lock"         # <state>/run.lock: held by every command that changes the state, shared or exclusive
RUNNER_LOCK = "runner.lock"     # <state>/runner.lock: held alone by process-replay's `run`, which shares run.lock
LOCK_MODES = ("exclusive", "shared", "run")


def _flock(path, how):
    """A non-blocking flock of `path` (made if need be) on a descriptor of its own: the descriptor, or None when another holds it.
    Two descriptors conflict even in one process, so a command run inside another (a test's nested call) is refused like a second process."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, how | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


@contextlib.contextmanager
def command_locks(state, mode, daemon=False):
    """Every lock one command holds, taken once at its entry and held to its exit, always in this order:
      1. <state>/run.lock: `exclusive` for a command nothing else may run beside; `shared` for one that may run beside the others that
         share it (its writes are each atomic, or under a run's own lock); `run` shares it and also holds <state>/runner.lock alone.
         mode None takes no state lock (a dry run that writes nothing, a command that never touches a state).
      2. the replay daemons' lock (codexhome.session), when `daemon` is true, or a function that returns true once the state lock is held
         (it may read the state). Taken before anything reads the daemon marker and held across every step until the command ends.
    Nothing else takes either lock, so this is the one order there is. Each take is non-blocking: a lock another command holds is a
    Failed at once (and nothing of the command has run), never a wait."""
    if mode is not None and mode not in LOCK_MODES:
        raise Failed("not a lock mode: {!r}".format(mode))
    fds = []
    try:
        if mode is not None:
            path = os.path.join(state, STATE_LOCK)
            fd = _flock(path, fcntl.LOCK_EX if mode == "exclusive" else fcntl.LOCK_SH)
            if fd is None:
                raise Failed("another command is using the state {} (it holds {}): run this one once it has finished".format(state, path))
            fds.append(fd)
            if mode == "run":
                runner = os.path.join(state, RUNNER_LOCK)
                fd = _flock(runner, fcntl.LOCK_EX)
                if fd is None:
                    raise Failed("another `run` holds {}: only one runs at a time (it keeps to the Codex turn limit and alone creates runs)".format(runner))
                fds.append(fd)
        if daemon() if callable(daemon) else daemon:
            from . import codexhome
            with codexhome.session():
                yield
        else:
            yield
    finally:
        for fd in reversed(fds):
            os.close(fd)            # closing the descriptor releases the flock


def locked(mode, daemon=False):
    """Declare a command's locks (command_locks) on the command function f(a): `mode` and `daemon` are values, or functions of the
    command's arguments `a` (a `daemon` function runs once the state lock is held)."""
    def wrap(fn):
        @functools.wraps(fn)
        def command(a, *args, **kw):
            want = daemon
            if callable(daemon):
                want = lambda: daemon(a)
            with command_locks(a.state, mode(a) if callable(mode) else mode, want):
                return fn(a, *args, **kw)
        return command
    return wrap


def label(taken):
    """A fresh 8-hex label, added to `taken`."""
    while True:
        lab = os.urandom(4).hex()
        if lab not in taken:
            taken.add(lab)
            return lab


# ------------------------------------------------------------------ the judge file protocol
def _check_id(jid):
    if not isinstance(jid, str) or not _ID.match(jid):
        raise Failed("not a usable id: {!r}".format(jid))


def _blind(doc, where="$"):
    if isinstance(doc, dict):
        for k, v in doc.items():
            if isinstance(k, str) and k.lower() in BLIND_KEYS:
                raise Failed("a judge input may not carry a key named {!r} (at {})".format(k, where))
            _blind(v, where + "." + str(k))
    elif isinstance(doc, (list, tuple)):
        for i, v in enumerate(doc):
            _blind(v, "{}[{}]".format(where, i))


def judge_write(state, kind, jid, doc):
    """Write a judge's input, <state>/<kind>/<id>.json. A document with a key named class, run, arm,
    label or purpose at any depth is refused: no judge learns the class, the run or the purpose."""
    if kind not in JUDGE_KINDS:
        raise Failed("not a judge kind: {!r}".format(kind))
    _check_id(jid)
    _blind(doc)
    path = os.path.join(state, kind, jid + ".json")
    old = jload(path)
    if old != doc:
        # an answer is for the input it saw: the collected one is set aside (kept, as <id>.stale-<n>.answer.json), and so is one
        # written in the staged directory, which is retired, so the item is pending again. An answer with no input before it (put by hand)
        # stays.
        if old is not None:
            set_aside(state, kind, jid, "stale")
        if _staged(state, kind, jid):
            with _items(state) as (rec, _dirs):
                _retire(state, kind, jid, rec)
    jsave(path, doc)
    return path


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


NOTHING = object()      # no answer file, or one that does not parse (yet): a JSON null is an answer, and a malformed one


def _parsed(path):
    """The JSON value in `path`, or NOTHING when there is none or it does not parse."""
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return NOTHING


def _collected(state, kind, jid):
    """The judge's answer, or NOTHING. One written in the staged item's directory is copied into the state (and removed from the item)
    when it parses and the directory was staged from the input as it is now; one written against an earlier input is set aside as stale
    (_retire) and the item is pending again, to be staged anew. The staged answer is read under items.lock, so no staging or retirement
    goes on between the check and the move."""
    path = os.path.join(state, kind, jid + ".answer.json")
    got = _parsed(path)
    if got is not NOTHING:
        return got
    staged = _staged(state, kind, jid)
    if not staged or not os.path.exists(os.path.join(staged, "answer.json")):
        return NOTHING
    with _items(state) as (rec, dirs):
        name = rec.get(kind + "/" + jid)
        theirs = os.path.join(items_root(), name, "answer.json") if isinstance(name, str) else None
        got = _parsed(theirs) if theirs else NOTHING
        if got is NOTHING:
            return NOTHING
        if not _staged_from(dirs, name, _input_digest(state, kind, jid)):
            _retire(state, kind, jid, rec)
            return NOTHING
        with open(theirs, "rb") as f:
            XR.write_whole(path, f.read())
        _unlink(theirs)
    return got


def judge_answer(state, kind, jid):
    """The judge's answer, or None (none yet, or a JSON null). One written in the staged item's directory is collected (_collected)."""
    got = _collected(state, kind, jid)
    return None if got is NOTHING else got


def reject_answer(state, kind, jid):
    """Set a judge's answer aside as <id>.rejected-<n>.answer.json (its content is kept), so the item is pending again in its
    staged directory and the judge can answer anew. The name it was set aside under, or None when there was no answer."""
    return set_aside(state, kind, jid, "rejected")


def set_aside(state, kind, jid, why):
    """Move a collected answer to <id>.<why>-<n>.answer.json (its content is kept). The name it went to, or None without an answer."""
    path = os.path.join(state, kind, jid + ".answer.json")
    if not os.path.exists(path):
        return None
    aside = _aside_name(state, kind, jid, why)
    try:
        os.replace(path, aside)
    except FileNotFoundError:       # a command beside this one (both sharing the state) set it aside first
        _unlink(aside)
        return None
    return aside


def _aside_name(state, kind, jid, why):
    """A new <id>.<why>-<n>.answer.json, reserved (made, empty, only if it did not exist) so two set-asides never take one name."""
    n = 1
    while True:
        aside = os.path.join(state, kind, "{}.{}-{}.answer.json".format(jid, why, n))
        try:
            os.close(os.open(aside, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644))
            return aside
        except FileExistsError:
            n += 1


# ------------------------------------------------------------------ answer schemas
VERDICTS = ("yes", "no", "unclear")
SEVERITY_VALUES = ("P0", "P1", "P2", "P3")
CLASS_VALUES = ("diff-visible", "design", "plan-only")
RULINGS = ("real", "false_positive")

# Every judge kind's answer is declared once, in ANSWERS, as data, and one validator (answer_problem) checks any answer against its
# kind's schema and the input it answers. A schema is built from:
#   Obj(key=spec, ..., *When(...))  an object holding every key named (present even where its spec allows null); other keys are ignored
#   List(spec, what, key=, flat=, unique=, covers=, least=)
#                                   a list of spec; `key` names the fields an item is known by (`flat`: the items are lists, and their
#                                   elements are what is known); `unique`: none known twice; `covers`: every member of a domain known;
#                                   `least`: at least that many items; `what` names a missing member in the message
#   One(*values), Null(spec), Either(*specs), TEXT (a string with something in it), STR, INT (an integer, never a bool)
#   Index(domain), Name(domain)     an integer (never a bool) or a string that is a member of the domain
# A domain is a set the input, or the answer itself, defines: Range(path) its list's positions, Field(path, name) the `name` of each
# object in its list, Keys(path) its object's keys, Pairs(d1, d2), Minus(d1, d2). A path starts at "input" or "answer"; Item(name) in it
# stands for the value of `name` in the object being checked. Without an input (an answer put by hand first) a domain the input defines
# is unknown, and only what needs no input is checked.
UNKNOWN = object()


def Obj(*rules, **keys):
    return {"obj": keys, "rules": rules}


def When(key, value, **then):
    """In an Obj: while `key` holds `value`, each key of `then` must match its spec as well."""
    return {"when": (key, value), "then": then}


def List(item, what, key=None, flat=False, unique=False, covers=None, least=0):
    return {"list": item, "what": what, "key": key, "flat": flat, "unique": unique, "covers": covers, "least": least}


def One(*values):
    return {"one": values}


def Null(spec):
    return {"null": spec}


def Either(*specs):
    return {"either": specs}


TEXT, STR, INT = {"text": True}, {"str": True}, {"int": True}


def Index(domain):
    return {"in": domain, "of": int}


def Name(domain):
    return {"in": domain, "of": str}


def Range(*path):
    return ("range", path)


def Field(path, name):
    return ("field", path, name)


def Keys(*path):
    return ("keys", path)


def Pairs(a, b):
    return ("pairs", a, b)


def Minus(a, b):
    return ("minus", a, b)


def Item(name):
    return ("item", name)


VERDICT, SEVERITY = One(*VERDICTS), One(*SEVERITY_VALUES)
CHANGE = Index(Range("input", "changes"))


def _match_lists(count):
    """process-replay's judge-match: a match for every defect, to a finding of `count` (a domain) or null, and a ruling for every finding
    no defect claims (a ruling for a claimed one is allowed, and unused)."""
    return dict(
        matches=List(Obj(defect=Index(Range("input", "defects")), finding=Null(Index(count))), "match for defect(s)",
                     key=("defect",), unique=True, covers=Range("input", "defects")),
        unmatched=List(Obj(finding=Index(count), ruling=One(*RULINGS)), "ruling for finding(s)", key=("finding",), unique=True,
                       covers=Minus(count, Field(("answer", "matches"), "finding"))))


KNOWN = Field(("input", "known"), "index")
ANSWERS = {     # kind: ((the input key that selects the form, or None for any input), schema), ...
    "judge-task": ((None, Obj(findings=List(Obj(
        When("answer", "yes", severity=SEVERITY),
        index=INT, report=Index(Range("input", "reports")), summary=TEXT, file=Null(STR), line=Null(INT), failure_scenario=Null(STR),
        severity=Null(SEVERITY), introduced_by=Null(CHANGE), fixed_by=List(CHANGE, "change"), answer=VERDICT), "finding"))),),
    "judge-known": ((None, Obj(verdicts=List(Obj(index=Index(Field(("input", "findings"), "index")), answer=VERDICT),
                                             "verdict for finding(s)", key=("index",), unique=True,
                                             covers=Field(("input", "findings"), "index")))),),
    "judge-present": ((None, Obj(answer=VERDICT)),),
    "judge-same": ((None, Obj(answer=VERDICT)),),
    "judge-split": ((None, Obj(hunks=List(Obj(index=Index(Range("input", "hunks")),
                                              defect=Null(Either(One("unsure"), Index(Range("input", "defects"))))),
                                          "entry for hunk(s)", key=("index",), unique=True, covers=Range("input", "hunks")))),),
    "judge-dedup": ((None, Obj(groups=List(List(Index(Range("input", "defects")), "defect", least=1), "group for defect(s)",
                                           flat=True, unique=True, covers=Range("input", "defects")))),),
    "judge-match": (
        # xreview-replay's: a finding of each review, or null, for every known finding
        ("known", Obj(matches=List(Obj(known_index=Index(KNOWN), label=Name(Keys("input", "runs")),
                                       finding_index=Null(Index(Range("input", "runs", Item("label"))))),
                                   "match for known finding/review pair(s)", key=("known_index", "label"), unique=True,
                                   covers=Pairs(KNOWN, Keys("input", "runs"))))),
        # a final review's report: the judge numbers its claims 0..n-1 first, and matches and rules on those
        ("report", Obj(findings=List(Obj(index=Index(Range("answer", "findings")), summary=TEXT), "claim numbered", key=("index",),
                                     unique=True, covers=Range("answer", "findings")),
                       **_match_lists(Range("answer", "findings")))),
        (None, Obj(**_match_lists(Range("input", "findings"))))),
    "judge-class": ((None, Obj(**{"class": One(*CLASS_VALUES)})),),
}


def _shown(v):
    text = json.dumps(v)
    return text if len(text) <= 40 else text[:37] + "..."


def _at(where, step):
    return "{}[{}]".format(where, step) if isinstance(step, int) else "{}.{}".format(where, step) if where else step


def _scalar(v):
    return isinstance(v, str) or (isinstance(v, int) and not isinstance(v, bool))


def _domain(dom, ctx, item=None):
    """The frozenset a domain names, or None when it is the input's and there is no input."""
    if dom[0] in ("pairs", "minus"):
        a, b = _domain(dom[1], ctx, item), _domain(dom[2], ctx, item)
        if a is None or b is None:
            return None
        return frozenset((x, y) for x in a for y in b) if dom[0] == "pairs" else a - b
    path = dom[1]
    cur = ctx[path[0]]
    if cur is UNKNOWN:
        return None
    for step in path[1:]:
        if isinstance(step, tuple):         # Item(name)
            step = item.get(step[1]) if isinstance(item, dict) else None
        cur = cur.get(step) if isinstance(cur, dict) and isinstance(step, str) else None
    if dom[0] == "range":
        return frozenset(range(len(cur))) if isinstance(cur, list) else frozenset()
    if dom[0] == "keys":
        return frozenset(cur) if isinstance(cur, dict) else frozenset()
    return frozenset(e[dom[2]] for e in cur if isinstance(e, dict) and _scalar(e.get(dom[2]))) if isinstance(cur, list) else frozenset()


def _listed(keys, cap=10):
    try:
        keys = sorted(keys)
    except TypeError:
        keys = sorted(keys, key=repr)
    shown = ", ".join("/".join(map(str, k)) if isinstance(k, tuple) else str(k) for k in keys[:cap])
    return shown + (", ... ({} in all)".format(len(keys)) if len(keys) > cap else "")


def _check(spec, v, ctx, where, item=None):
    """Why `v` does not match `spec`, or None. Whatever JSON value `v` is, a mismatch is a reason, never an exception: no value is hashed,
    compared by order or indexed before its type is known."""
    if "null" in spec:
        return None if v is None else _check(spec["null"], v, ctx, where, item)
    if "either" in spec:
        whys = [_check(s, v, ctx, where, item) for s in spec["either"]]
        return None if None in whys else whys[-1]
    if "one" in spec:
        if any(type(v) is type(x) and v == x for x in spec["one"]):
            return None
        return "{} is {}, not one of {}".format(where, _shown(v), "/".join(str(x) for x in spec["one"]))
    if "text" in spec:
        return None if isinstance(v, str) and v.strip() else "{} is {}, not a text".format(where, _shown(v))
    if "str" in spec:
        return None if isinstance(v, str) else "{} is {}, not a string".format(where, _shown(v))
    if "int" in spec:
        return None if isinstance(v, int) and not isinstance(v, bool) else "{} is {}, not an integer".format(where, _shown(v))
    if "in" in spec:
        if not (isinstance(v, str) if spec["of"] is str else isinstance(v, int) and not isinstance(v, bool)):
            return "{} is {}, not {}".format(where, _shown(v), "a name" if spec["of"] is str else "an index")
        dom = _domain(spec["in"], ctx, item)
        if dom is None or v in dom:
            return None
        return "{} is {}, not one of {}".format(where, _shown(v), _listed(dom)) if dom else "{} is {}, and there is none to name".format(where, _shown(v))
    if "obj" in spec:
        if not isinstance(v, dict):
            return "{} is {}, not an object".format(where or "the answer", _shown(v))
        for key, sub in spec["obj"].items():
            if key not in v:
                return "{} is missing".format(_at(where, key))
            why = _check(sub, v[key], ctx, _at(where, key), v)
            if why:
                return why
        for rule in spec["rules"]:
            key, value = rule["when"]
            if type(v[key]) is type(value) and v[key] == value:
                for k, sub in rule["then"].items():
                    why = _check(sub, v[k], ctx, _at(where, k), v)
                    if why:
                        return "{} while {} is {}".format(why, key, _shown(value))
        return None
    if not isinstance(v, list):         # "list"
        return "{} is {}, not a list".format(where, _shown(v))
    for n, x in enumerate(v):
        why = _check(spec["list"], x, ctx, _at(where, n), item)
        if why:
            return why
    if len(v) < spec["least"]:
        return "{} is empty".format(where)
    if spec["flat"]:                    # every item matched its spec: what is known is an integer or a string, so hashable
        known = [e for x in v for e in x]
    elif spec["key"]:
        known = [x[spec["key"][0]] if len(spec["key"]) == 1 else tuple(x[k] for k in spec["key"]) for x in v]
    else:
        known = list(v)
    if spec["unique"]:
        seen, twice = set(), set()
        for k in known:
            (twice if k in seen else seen).add(k)
        if twice:
            return "{}: {} given more than once".format(where, _listed(twice))
    dom = _domain(spec["covers"], ctx) if spec["covers"] else None
    if dom is not None and dom - set(known):
        return "{}: no {} {}".format(where, spec["what"], _listed(dom - set(known)))
    return None


def answer_problem(kind, doc, ans):
    """None when `ans` matches the schema of `kind` (ANSWERS) for the judge input `doc`, else why not. A kind with several forms is
    checked by the one its input has. Without an input to check against (`doc` None: an answer put by hand first) only what needs none
    is checked, and any of the kind's forms will do. Never raises, whatever JSON value `ans` is."""
    forms = ANSWERS[kind]
    if not isinstance(doc, dict):
        whys = [_check(schema, ans, {"input": UNKNOWN, "answer": ans}, "") for _form, schema in forms]
        return None if None in whys else whys[-1]
    schema = next(s for form, s in forms if form is None or form in doc)
    return _check(schema, ans, {"input": doc, "answer": ans}, "")


def _answer_file(state, kind, jid):
    """The answer as a reader finds it, without moving anything: the state's, else the one written in the staged item; NOTHING without one."""
    got = _parsed(os.path.join(state, kind, jid + ".answer.json"))
    if got is NOTHING:
        staged = _staged(state, kind, jid)
        theirs = os.path.join(staged, "answer.json") if staged else None
        if theirs and os.path.exists(theirs) and _staged_from(jload(os.path.join(state, STAGED)), os.path.basename(staged),
                                                                _input_digest(state, kind, jid)):
            got = _parsed(theirs)
    return got


def _answered(state, kind, jid):
    """Whether the item has an answer that parses and matches its kind's schema for its input: the test `pending` and `accepted_answer` share."""
    got = _answer_file(state, kind, jid)
    return got is not NOTHING and answer_problem(kind, jload(os.path.join(state, kind, jid + ".json")), got) is None


def accepted_answer(state, kind, jid):
    """The judge's answer when it parses and is complete for its input, else None. A complete answer gives an allowed value for every item
    the input asks about (answer_problem); one that is not is set aside (reject_answer, content kept) and said so, and the item is pending
    again. No consumer reads a judge's answer by any other way: a missing item is never taken as a default."""
    got = _collected(state, kind, jid)
    if got is NOTHING:
        return None
    why = answer_problem(kind, jload(os.path.join(state, kind, jid + ".json")), got)
    if why is None:
        return got
    aside = reject_answer(state, kind, jid)
    say("{} {}: the judge's answer is not used: {}; it is set aside as {} and the item is pending again".format(
        kind, jid, why, os.path.basename(aside) if aside else "(none)"))
    return None


def _final_text(path):
    """Whether a final review's answer.md says anything: an empty file is a write that has not begun, not an answer."""
    try:
        with open(path, "rb") as f:
            return bool(f.read().strip())
    except OSError:
        return False


def collect_final(state, jid):
    """The path of final review `jid`'s answer.md in the state, or None. An answer.md the driver wrote in the staged
    item's directory is moved into the state first."""
    path = os.path.join(state, "final", jid, "answer.md")
    if _final_text(path):
        return path
    staged = _staged(state, "final", jid)
    theirs = os.path.join(staged, "answer.md") if staged else None
    if theirs and _final_text(theirs):
        with open(theirs, "rb") as f:
            data = f.read()
        XR.write_whole(path, data)
        _unlink(theirs)
        return path
    return None


NEEDED = "needed.json"          # <state>/<kind>/needed.json: the questions of a kind its writer still needs (inject.Questions)


def _inputs(state, kind):
    d = os.path.join(state, kind)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    return [n[:-5] for n in names if n.endswith(".json") and not n.endswith(".answer.json") and n != NEEDED]


def _not_needed(state, kind):
    """The ids of `kind` that <state>/<kind>/needed.json says its writer asked and no longer waits on: {owned: [id], needed: [id]}.
    Empty without one; a question its writer does not own (another module's) is never in it."""
    doc = jload(os.path.join(state, kind, NEEDED))
    if not isinstance(doc, dict):
        return set()
    return set(doc.get("owned") or []) - set(doc.get("needed") or [])


def alias(state):
    """A neutral name for the state directory: a symlink $XDG_STATE_HOME/review-work/<8 hex> to it,
    recorded in <state>/alias. Every path a judge, a final reviewer or a Codex turn is handed goes
    through it, so the state directory's own name (process-replay) never reaches them. It is made
    once, reused on later calls, and made again at its recorded path when the symlink is gone or
    dangling. A record that names a link to another existing directory (a state copied with cp -r)
    is not taken over: the copy gets a name of its own, and the original's link stays as it was."""
    state = os.path.abspath(state)
    record = os.path.join(state, "alias")
    try:
        with open(record) as f:
            link = f.read().strip()
    except OSError:
        link = ""
    if link and os.path.islink(link) and os.path.realpath(link) == os.path.realpath(state):
        return link
    if not link or (os.path.lexists(link) and (not os.path.islink(link) or os.path.exists(link))):
        base = os.path.join(L.state_home(), "review-work")
        os.makedirs(base, exist_ok=True)
        link = os.path.join(base, label(set(os.listdir(base))))
    elif os.path.islink(link):
        os.unlink(link)
    os.makedirs(os.path.dirname(link), exist_ok=True)
    os.symlink(state, link)
    jsave(record, link + "\n")
    return link


def aliased(state, path):
    """`path`, which lies under `state`, as the same path under the state's alias."""
    state, path = os.path.abspath(state), os.path.abspath(path)
    if path != state and not path.startswith(state + os.sep):
        raise Failed("{} is not under {}".format(path, state))
    return alias(state) + path[len(state):]


# ------------------------------------------------------------------ staged items
def items_root():
    return os.path.join(L.state_home(), "review-work", "items")


def _staged(state, kind, jid):
    """The staged directory of an item that has one, else None (nothing is allocated)."""
    rec = jload(os.path.join(state, "items.json"))
    name = rec.get(kind + "/" + jid) if isinstance(rec, dict) else None
    return os.path.join(items_root(), name) if isinstance(name, str) else None


STAGED = "staged.json"      # <state>/staged.json: {staged directory name: {"item": "<kind>/<id>", "input": sha256 of the input it serves}}


def _input_digest(state, kind, jid, data=None):
    """The sha256 of a judge input's bytes (`data`, else the file as it is now), or None without one."""
    if data is None:
        try:
            with open(os.path.join(state, kind, jid + ".json"), "rb") as f:
                data = f.read()
        except OSError:
            return None
    return hashlib.sha256(data).hexdigest()


input_digest = _input_digest


def _staged_from(dirs, name, digest):
    """Whether staged directory `name` serves the input whose digest is `digest` (staged.json's record `dirs`)."""
    rec = dirs.get(name) if isinstance(dirs, dict) else None
    return isinstance(rec, dict) and digest is not None and rec.get("input") == digest


@contextlib.contextmanager
def _items(state):
    """items.json ({<kind>/<id>: its current staged directory}) and staged.json, held under <state>/items.lock and given to the block to
    change in place; each is written back when it changed. Every change to either goes through here."""
    os.makedirs(state, exist_ok=True)
    with open(os.path.join(state, "items.lock"), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rec, dirs = jload(os.path.join(state, "items.json")), jload(os.path.join(state, STAGED))
        rec, dirs = (rec if isinstance(rec, dict) else {}), (dirs if isinstance(dirs, dict) else {})
        before = json.dumps(rec, sort_keys=True), json.dumps(dirs, sort_keys=True)
        yield rec, dirs
        if json.dumps(rec, sort_keys=True) != before[0]:
            jsave(os.path.join(state, "items.json"), rec)
        if json.dumps(dirs, sort_keys=True) != before[1]:
            jsave(os.path.join(state, STAGED), dirs)


def _retire(state, kind, jid, rec):
    """(Inside _items.) The item's current staged directory no longer serves it: an answer in it is set aside as stale (moved into the
    state, content kept, said so), and the item has no directory until it is staged again, in a new one. The old directory stays, listed
    in staged.json for cleanup; an answer written there later is never read."""
    name = rec.pop(kind + "/" + jid, None)
    theirs = os.path.join(items_root(), name, "answer.json") if isinstance(name, str) else None
    if not theirs or not os.path.exists(theirs):
        return
    aside = _aside_name(state, kind, jid, "stale")
    with open(theirs, "rb") as f:
        XR.write_whole(aside, f.read())
    _unlink(theirs)
    say("{} {}: the judge answered an earlier version of its input (it changed after it was staged): the answer is not used; it is set "
        "aside as {} and the item is pending again with the current input".format(kind, jid, os.path.basename(aside)))


def item_dir(state, kind, jid, digest=None):
    """The staged directory of an item, allocated (a random 16-hex name, recorded in <state>/items.json) and made on first use. A judge's
    directory serves one version of its input: staged.json records the digest it was allocated for (`digest`, else the input's as it is
    now), and once the input differs the old directory is retired (_retire) and the item gets a new one."""
    judge = kind in JUDGE_KINDS
    if judge and digest is None:
        digest = _input_digest(state, kind, jid)
    key = kind + "/" + jid
    with _items(state) as (rec, dirs):
        if judge and key in rec and not _staged_from(dirs, rec[key], digest):
            _retire(state, kind, jid, rec)
        if key not in rec:
            while True:
                name = os.urandom(8).hex()
                if name not in rec.values() and name not in dirs and not os.path.exists(os.path.join(items_root(), name)):
                    break
            rec[key] = name
            if judge:
                dirs[name] = {"item": key, "input": digest}
        d = os.path.join(items_root(), rec[key])
    os.makedirs(d, exist_ok=True)
    return d


def _write_if_changed(path, data):
    data = data if isinstance(data, bytes) else data.encode("utf-8")
    try:
        with open(path, "rb") as f:
            if f.read() == data:
                return
    except OSError:
        pass
    XR.write_whole(path, data)


def _pending(state):
    """[(kind, id, input path, answer path, brief path)], the harness's own paths (the state's), of everything unanswered, except a
    question or a recreation its kind's needed.json marks as no longer needed."""
    out = []
    dead = superseded_labels(state)         # a superseded run is not driven: nothing of it waits for an agent
    for kind in JUDGE_KINDS:
        obsolete = _not_needed(state, kind)
        for jid in _inputs(state, kind):
            if jid in obsolete or of_runs(jid, dead):
                continue
            base = os.path.join(state, kind, jid)
            if not _answered(state, kind, jid):
                out.append((kind, jid, base + ".json", base + ".answer.json", base + ".brief.md"))
    fdir = os.path.join(state, "final")
    for jid in sorted(os.listdir(fdir)) if os.path.isdir(fdir) else []:
        if of_runs(jid, dead):
            continue
        brief = os.path.join(fdir, jid, "brief.md")
        staged = _staged(state, "final", jid)
        if os.path.isfile(brief) and not _final_text(os.path.join(fdir, jid, "answer.md")) \
                and not (staged and _final_text(os.path.join(staged, "answer.md"))):
            out.append(("final", jid, brief, os.path.join(fdir, jid, "answer.md"), brief))
    obsolete = _not_needed(state, "recreate")
    for jid in _inputs(state, "recreate"):
        if jid in obsolete:
            continue
        spec = os.path.join(state, "recreate", jid + ".json")
        done = os.path.join(state, "recreate", jid, "done")
        brief = os.path.join(state, "recreate", jid + ".brief.md")
        if not os.path.exists(done):
            out.append(("recreate", jid, spec, done, brief if os.path.isfile(brief) else spec))
    return out


def _agent_paths(state, item):
    """(answer path, brief path) as the agent gets them: in the staged directory for a judge or a final review, the aliased
    state paths for a recreation."""
    kind, jid, _inp, ans, brief = item
    if kind in JUDGE_KINDS:
        d = item_dir(state, kind, jid)
        return os.path.join(d, "answer.json"), os.path.join(d, "brief.md")
    if kind == "final":
        d = item_dir(state, kind, jid)
        return os.path.join(d, "answer.md"), os.path.join(d, "brief.md")
    return ans, aliased(state, brief)


def pending(state):
    """[(kind, id, input path, answer path, brief path)] of everything waiting for an agent: judge inputs without an answer,
    final reviews (final/<id>/brief.md) without answer.md, and recreations (recreate/<id>.json) without recreate/<id>/done.
    The input path is the harness's own. The answer and brief paths are the ones to hand out: in the item's staged
    directory (answer.json or answer.md, brief.md) for a judge or a final review, the aliased paths for a recreation."""
    out = []
    for item in _pending(state):
        ans, brief = _agent_paths(state, item)
        out.append(item[:3] + (ans, brief))
    return out


def write_briefs(state, briefs=None):
    """<state>/judges/<kind>.md for every kind; `briefs` replaces the text of the kinds it names (xreview-replay's judge-match
    has its own input and answer shapes)."""
    table = dict(BRIEFS, **(briefs or {}))
    for kind in JUDGE_KINDS:
        jsave(os.path.join(state, "judges", kind + ".md"), COMMON + "\n" + table[kind])


def brief_for(state, kind, jid):
    """Stage one pending item and return its brief's path. A judge's staged directory holds input.json (a copy of the input)
    and brief.md: the kind's brief, then `Input: <input.json>` and `Write your answer to: <answer.json>`, and nothing else.
    A final review's holds its brief.md (a copy of final/<id>/brief.md) and the package.diff its writer staged; a recreation
    is its own brief and nothing is staged for it. Returns the brief's path."""
    for item in _pending(state):
        if item[0] == kind and item[1] == jid:
            return _stage(state, item)
    raise Failed("nothing pending for {} {}".format(kind, jid))


def _stage(state, item):
    kind, jid, inp, _ans, brief = item
    if kind in JUDGE_KINDS:
        kind_brief = os.path.join(state, "judges", kind + ".md")
        if not os.path.isfile(kind_brief):
            write_briefs(state)
        with open(kind_brief, encoding="utf-8") as f:
            text = f.read()
        with open(inp, "rb") as f:
            data = f.read()
        d = item_dir(state, kind, jid, _input_digest(state, kind, jid, data))      # the directory of exactly the bytes staged into it
        ans, agent_brief = os.path.join(d, "answer.json"), os.path.join(d, "brief.md")
        _write_if_changed(os.path.join(d, "input.json"), data)
        _write_if_changed(agent_brief, text.rstrip("\n") + "\n\nInput: {}\nWrite your answer to: {}\n".format(os.path.join(d, "input.json"), ans))
        return agent_brief
    _ans, agent_brief = _agent_paths(state, item)
    if kind == "final":
        with open(brief, "rb") as f:
            _write_if_changed(agent_brief, f.read())
    return agent_brief


@locked("shared")
def cmd_pending(a, briefs=None):
    """Print one line per pending judge, final review and recreation: kind, id, brief. The judges' and final reviews' items are
    staged first (see the module doc); the brief is the staged one. `briefs` as for write_briefs."""
    write_briefs(a.state, briefs)
    items = _pending(a.state)
    for item in items:
        say("{}\t{}\t{}".format(item[0], item[1], _stage(a.state, item)))
    if not items:
        say("nothing pending")
    return 0


# ------------------------------------------------------------------ git
_DROP_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
             "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_PREFIX")


def git_env(extra=None):
    """The environment of every git call: ledger's (no pathspec variables, no lazy fetch) without the
    variables that would point git at another repository or add object stores to it."""
    env = {k: v for k, v in L.git_env().items() if k not in _DROP_ENV}
    env.update(extra or {})
    return env


def _target(path):
    """git's repository selector: -C for a work tree, --git-dir for a git directory (the user's
    safe.bareRepository=explicit refuses to discover a bare repository)."""
    if os.path.exists(os.path.join(path, ".git")):
        return ["-C", path]
    return ["--git-dir", path]


def git_run(gitdir, args, input=None, env=None):
    return subprocess.run(["git"] + _target(gitdir) + list(args), input=input, capture_output=True, env=git_env(env))


def git(gitdir, *args, raw=False, input=None, env=None):
    """stdout of git on a git directory or a work tree: text with its trailing newlines removed, or
    the bytes as they are when raw. Raises Failed when git exits non-zero."""
    p = git_run(gitdir, args, input, env)
    if p.returncode != 0:
        raise Failed("git {} failed ({}): {}".format(" ".join(args[:3]), p.returncode, p.stderr.decode("utf-8", "replace").strip()))
    return p.stdout if raw else p.stdout.decode("utf-8", "replace").rstrip("\n")


def git_ok(gitdir, *args):
    return git_run(gitdir, args).returncode == 0


# ------------------------------------------------------------------ snapshot views
def repo_name(gitdir):
    """The repository's name: the basename of the git directory's parent (a bare <name>.git: itself)."""
    gitdir = os.path.abspath(gitdir)
    base = os.path.basename(gitdir)
    if base == ".git":
        return os.path.basename(os.path.dirname(gitdir))
    return base[:-4] if base.endswith(".git") else base


def snapshot_objects(root, gitdir):
    """<root>/<name>/objects when that directory exists, else None."""
    path = os.path.join(root, repo_name(gitdir), "objects")
    return path if os.path.isdir(path) else None


def view(state, gitdir, root):
    """A bare repository <state>/views/<name>.git whose alternates name the snapshot's objects (or,
    with no snapshot, the original's). It reads commits the original has since pruned, writes
    nothing into either store, and is private to the harness: never shown to a reviewer."""
    path = os.path.join(state, "views", repo_name(gitdir) + ".git")
    source = snapshot_objects(root, gitdir) or os.path.join(os.path.abspath(gitdir), "objects")
    if not os.path.isfile(os.path.join(path, "HEAD")):
        os.makedirs(path, exist_ok=True)
        p = subprocess.run(["git", "init", "-q", "--bare", "--template=", path], capture_output=True, env=git_env())
        if p.returncode != 0:
            raise Failed("cannot create the view: " + p.stderr.decode("utf-8", "replace").strip())
    alt = os.path.join(path, "objects", "info", "alternates")
    try:
        with open(alt) as f:
            current = f.read()
    except OSError:
        current = None
    if current != source + "\n":
        os.makedirs(os.path.dirname(alt), exist_ok=True)
        jsave(alt, source + "\n")
    return path


# ------------------------------------------------------------------ reading git through a view
_HEX = re.compile(r"\A[0-9a-fA-F]{4,40}\Z")


def cap(text, limit):
    """`text` cut to `limit` characters, with a [truncated] line when it was cut."""
    return text if len(text) <= limit else text[:limit] + "\n[truncated]\n"


def norm(path):
    """A path a reviewer wrote (./x, a/x, b/x) as the repository's own."""
    path = path if isinstance(path, str) else ""
    while path.startswith("./"):
        path = path[2:]
    if path[:2] in ("a/", "b/"):
        path = path[2:]
    return path


class Reader(object):
    """The reads of one repository, through the private view (the snapshot's objects when it has any).
    The original repository is `gitdir`; nothing here writes to it."""

    def __init__(self, state, gitdir, root):
        self.state, self.gitdir, self.root = state, gitdir, root
        self._view = None
        self._commit, self._pid = {}, {}

    @property
    def view(self):
        if self._view is None:
            self._view = view(self.state, self.gitdir, self.root)
        return self._view

    def has_commit(self, rev):
        return git_ok(self.view, "cat-file", "-e", rev + "^{commit}")

    def text(self, blob):
        try:
            return git(self.view, "cat-file", "blob", blob, raw=True).decode("utf-8", "replace")
        except Failed:
            return None

    def size(self, blob):
        try:
            return int(git(self.view, "cat-file", "-s", blob))
        except (Failed, ValueError):
            return None

    def file(self, rev, path):
        """The text of `path` at `rev`, or None."""
        return self.text("{}:{}".format(rev, path))

    def commit(self, rev):
        """The full id of the commit that `rev` (hex, any length) names, or None: absent, ambiguous or not hex."""
        if not isinstance(rev, str) or not _HEX.match(rev):
            return None
        key = rev.lower()
        if key not in self._commit:
            try:
                self._commit[key] = git(self.view, "rev-parse", "--verify", "--quiet", key + "^{commit}") or None
            except Failed:
                self._commit[key] = None
        return self._commit[key]

    def is_ancestor(self, older, newer):
        return git_ok(self.view, "merge-base", "--is-ancestor", older, newer)

    def commits(self, base, tip, exclude=()):
        """[(sha, committer epoch)] reachable from `tip` and not from `base` or any of `exclude`, newest first."""
        try:
            out = git(self.view, "log", "--format=%H %ct", tip, *["^" + x for x in [base] + list(exclude)])
        except Failed:
            return []
        return [(s, int(t)) for s, t in (line.split() for line in out.splitlines())]

    def names(self, older, newer):
        out = git(self.view, "diff", "--name-only", "-z", *(L.DIFF_FLAGS + [older, newer, "--"]), raw=True)
        return [n for n in out.decode("utf-8", "replace").split("\0") if n]

    def patch(self, older, newer):
        """The change from older to newer, capped at XR.MAX_INTERDIFF characters."""
        out = git(self.view, *(L.DIFF_PATCH + ["--text", older, newer, "--"]), raw=True)
        return cap(out.decode("utf-8", "replace"), XR.MAX_INTERDIFF)

    def _patch_ids(self, *args):
        """[(patch id, commit)] of `git log -p <args>`, by `git patch-id --stable` (a merge or an empty commit has none)."""
        try:
            log = git(self.view, "log", "-p", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--format=commit %H",
                      *args, raw=True)
            out = git(self.view, "patch-id", "--stable", input=log, raw=True)
        except Failed:
            return []
        return [tuple(line.split()) for line in out.decode("utf-8", "replace").splitlines() if len(line.split()) == 2]

    def patch_id(self, commit):
        """The stable patch id of one commit, or None."""
        if commit not in self._pid:
            found = self._patch_ids("-1", commit)
            self._pid[commit] = found[0][0] if found else None
        return self._pid[commit]

    def branch_patch_ids(self, base, tip, exclude=()):
        """{patch id: commit} of the commits reachable from `tip` and not from `base` or `exclude`; the oldest when two share one."""
        return dict(self._patch_ids(tip, *["^" + x for x in [base] + list(exclude)])[::-1])
