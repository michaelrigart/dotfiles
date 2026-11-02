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


def _pending(state):
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


def pending(state):
    """[(kind, id, input path, answer path, brief path)] of everything waiting for an agent: judge
    inputs without an answer, final reviews (final/<id>/brief.md) without answer.md, and
    recreations (recreate/<id>.json) without recreate/<id>/done. The brief path is the one to hand
    out, under the state's alias; the others are the harness's own."""
    return [item[:4] + (aliased(state, item[4]),) for item in _pending(state)]


def write_briefs(state):
    """<state>/judges/<kind>.md for every kind."""
    for kind in JUDGE_KINDS:
        jsave(os.path.join(state, "judges", kind + ".md"), COMMON + "\n" + BRIEFS[kind])


def brief_for(state, kind, jid):
    """The brief of one pending item. A judge's is <kind>/<id>.brief.md: the kind's brief, then
    `Input: <input path>` and `Write your answer to: <answer path>`, and nothing else, both under
    the state's alias. A final review and a recreation are their own briefs; nothing is written for
    them. Returns the brief's path under the alias."""
    for item in _pending(state):
        if item[0] == kind and item[1] == jid:
            _write_brief(state, item)
            return aliased(state, item[4])
    raise Failed("nothing pending for {} {}".format(kind, jid))


def _write_brief(state, item):
    kind, _jid, inp, ans, brief = item
    if kind not in JUDGE_KINDS:
        return
    kind_brief = os.path.join(state, "judges", kind + ".md")
    if not os.path.isfile(kind_brief):
        write_briefs(state)
    with open(kind_brief, encoding="utf-8") as f:
        text = f.read()
    jsave(brief, text.rstrip("\n") + "\n\nInput: {}\nWrite your answer to: {}\n".format(aliased(state, inp), aliased(state, ans)))


def cmd_pending(a):
    """Print one line per pending judge, final review and recreation: kind, id, brief. The briefs
    of the judges are written first."""
    write_briefs(a.state)
    items = _pending(a.state)
    for item in items:
        _write_brief(a.state, item)
        say("{}\t{}\t{}".format(item[0], item[1], aliased(a.state, item[4])))
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
