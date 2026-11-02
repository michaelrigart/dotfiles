"""Shared by every process-replay module: the xreview-replay import, state paths, the judge file
protocol and its briefs, labels, git calls and the snapshot views.

Judge files (the controller dispatches the judges between phases; docs/superpowers/plans/
2026-11-02-replay-set.md, "Shared records"):
  <state>/<kind>/<id>.json           the judge's input, written by judge_write
  <state>/<kind>/<id>.answer.json    the judge's answer
  <state>/<kind>/<id>.brief.md       this input's brief (brief_for): the kind's brief and two path lines
  <state>/judges/<kind>.md           the kind's brief (write_briefs)
A final review is <state>/final/<id>/brief.md with answer.md beside it; a recreation is
<state>/recreate/<id>.json, finished when <state>/recreate/<id>/done exists.
"""
import importlib.util
import os
import re
import subprocess
import sys
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
    "judge-present": """The input is {"finding": {...}, "files": {"path": "text"}}: a reported defect, and the text of
the files as they stand.

Decide whether the finding's failure scenario can happen in these files. Answer "yes" when the code
shown has the flaw and the scenario is reachable, "no" when the flaw is absent or the scenario cannot
be reached, "unclear" when the files shown cannot settle it.

""" + SCALE + """
Answer: {"answer": "yes"}
""",
    "judge-split": """The input is {"defects": [{"index", "summary", "file", "line"}], "hunks": [{"index", "file",
"text"}]}: some defects, and the hunks of one change that fixed them.

For each hunk give the one defect it fixes, by its index. Give null when the hunk belongs to none of
the defects (a test, a rename, an unrelated edit). Give "unsure" when you cannot tell which defect
it belongs to, or when it fixes more than one.

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
    jsave(path, doc)
    return path


def judge_answer(state, kind, jid):
    return jload(os.path.join(state, kind, jid + ".answer.json"))


def _inputs(state, kind):
    d = os.path.join(state, kind)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    return [n[:-5] for n in names if n.endswith(".json") and not n.endswith(".answer.json")]


def pending(state):
    """[(kind, id, input path, answer path, brief path)] of everything waiting for an agent: judge
    inputs without an answer, final reviews (final/<id>/brief.md) without answer.md, and
    recreations (recreate/<id>.json) without recreate/<id>/done."""
    out = []
    for kind in JUDGE_KINDS:
        for jid in _inputs(state, kind):
            base = os.path.join(state, kind, jid)
            if not os.path.exists(base + ".answer.json"):
                out.append((kind, jid, base + ".json", base + ".answer.json", base + ".brief.md"))
    fdir = os.path.join(state, "final")
    for jid in sorted(os.listdir(fdir)) if os.path.isdir(fdir) else []:
        brief = os.path.join(fdir, jid, "brief.md")
        answer = os.path.join(fdir, jid, "answer.md")
        if os.path.isfile(brief) and not os.path.exists(answer):
            out.append(("final", jid, brief, answer, brief))
    for jid in _inputs(state, "recreate"):
        spec = os.path.join(state, "recreate", jid + ".json")
        done = os.path.join(state, "recreate", jid, "done")
        if not os.path.exists(done):
            out.append(("recreate", jid, spec, done, spec))
    return out


def write_briefs(state):
    """<state>/judges/<kind>.md for every kind."""
    for kind in JUDGE_KINDS:
        jsave(os.path.join(state, "judges", kind + ".md"), COMMON + "\n" + BRIEFS[kind])


def brief_for(state, kind, jid):
    """The brief of one pending item. A judge's is <kind>/<id>.brief.md: the kind's brief, then
    `Input: <input path>` and `Write your answer to: <answer path>`, and nothing else. A final
    review and a recreation are their own briefs; nothing is written for them."""
    for item in pending(state):
        if item[0] == kind and item[1] == jid:
            return _write_brief(state, item)
    raise Failed("nothing pending for {} {}".format(kind, jid))


def _write_brief(state, item):
    kind, _jid, inp, ans, brief = item
    if kind not in JUDGE_KINDS:
        return brief
    kind_brief = os.path.join(state, "judges", kind + ".md")
    if not os.path.isfile(kind_brief):
        write_briefs(state)
    with open(kind_brief, encoding="utf-8") as f:
        text = f.read()
    jsave(brief, text.rstrip("\n") + "\n\nInput: {}\nWrite your answer to: {}\n".format(inp, ans))
    return brief


def cmd_pending(a):
    """Print one line per pending judge, final review and recreation: kind, id, brief. The briefs
    of the judges are written first."""
    write_briefs(a.state)
    items = pending(a.state)
    for item in items:
        say("{}\t{}\t{}".format(item[0], item[1], _write_brief(a.state, item)))
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
