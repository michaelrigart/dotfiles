"""The whole process-replay pipeline, through the command line, on a stubbed daemon.

One fixture branch goes through snapshot -> cases -> inject -> home -> run -> match -> report -> cleanup. The judges, the final
reviewers and the recreating agent are played by answer() whenever `pending` lists an item (judges answer in their staged item
directories, final reviews by writing answer.md where pending says); Codex is a stub xreview-rpc whose rounds find one defect each,
on a stub codex binary that only makes and removes the daemon's socket.
"""
import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402

XR = C.XR
ROOT = helpers.tmp_root()
os.chdir(helpers.tmp_root())        # `run` refuses to start from the checkout, a forbidden root
STATE_HOME = os.environ["XDG_STATE_HOME"]
ORIGINAL_HOME = os.environ["CODEX_HOME"]
PROJECTS = os.path.join(ROOT, "projects")
SNAPSHOTS = os.path.join(ROOT, "no-snapshot")
KEY = re.sub(r"[^A-Za-z0-9]", "-", os.path.expanduser("~/Code/.replay"))
os.makedirs(PROJECTS)

spec = importlib.util.spec_from_file_location("process_replay_cli", os.path.join(helpers.SCRIPTS, "process-replay.py"))
CLI = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CLI)


def cli(*argv, state=None):
    """(exit status, output) of `process-replay.py <argv>` run in this process."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        rc = CLI.main(list(argv) + ["--state", state or STATE, "--snapshot-root", SNAPSHOTS, "--projects-dir", PROJECTS])
    return rc, out.getvalue()


# ---------------------------------------------------------------- the superpowers the final review's brief is made from
SP = os.path.join(ROOT, "superpowers")
put(SP, "skills/requesting-code-review/code-reviewer.md", """# Code Reviewer Prompt Template

```
Subagent (general-purpose):
  prompt: |
    You are a Senior Code Reviewer.

    ## What Was Implemented

    [DESCRIPTION]

    ## Requirements / Plan

    [PLAN_OR_REQUIREMENTS]

    **Base:** [BASE_SHA]
    **Head:** [HEAD_SHA]
```
""")
PKG = os.path.join(SP, "skills/subagent-driven-development/scripts/review-package")
put(os.path.dirname(PKG), "review-package", """#!/usr/bin/env bash
set -euo pipefail
plan=$1; base=$2; head=$3; out=$4
[ -f "$plan" ] || { echo "no such plan file: $plan" >&2; exit 2; }
git merge-base --is-ancestor "$base" "$head" || exit 3
mkdir -p "$(dirname "$out")"
{ echo "# Review package: ${base}..${head}"; git diff --stat "${base}..${head}"; } > "$out"
""")
os.chmod(PKG, 0o755)
os.environ["PROCESS_REPLAY_SUPERPOWERS"] = SP

# ---------------------------------------------------------------- the original repository: one branch, merged in October
# letter -> (file, fixed line, buggy line, severity, class). D's buggy line is one the judge cannot see (D_BUG_ORIG), so D is
# recreated by hand (D_BUG_REC) and judged present then.
BUGS = {
    "A": ("src/a.py", "    return y + 2\n", "    return y + 1  # A_BUG\n", "P1", "task"),
    "B": ("src/b.py", "    return y + 3\n", "    return y + 2  # B_BUG\n", "P1", "task"),
    "D": ("src/d.py", "    return y + 6\n", "    return y + 5  # D_BUG_ORIG\n", "P2", "task"),
    "C": ("src/c.py", "    return y + 7\n", "    return y + 4  # C_BUG\n", "P1", "pre"),
}
FILE = '"""module {}"""\n\n\ndef f(v):\n    y = v\n{}'


def source(letter, fixed):
    _file, good, bad, _s, _c = BUGS[letter]
    return FILE.format(letter.lower(), good if fixed else bad)


class dated(object):
    def __init__(self, when):
        self.when = when

    def __enter__(self):
        self.old = dict((k, os.environ.get(k)) for k in ("GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE"))
        os.environ["GIT_AUTHOR_DATE"] = os.environ["GIT_COMMITTER_DATE"] = self.when

    def __exit__(self, *exc):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


REPO = helpers.make_repo(ROOT, "erepo")
with dated("2026-09-20T10:00:00Z"):
    put(REPO, "README.md", "readme\n")
    BASE = helpers.commit(REPO, "base")
git(REPO, "checkout", "-q", "-b", "feat")
STEPS = [
    ("plan", "2026-10-01T08:00:00Z", {"docs/superpowers/plans/plan.md": "# plan\n"}),
    ("task 1", "2026-10-01T09:00:00Z", dict((BUGS[x][0], source(x, False)) for x in "ABCD")),
    ("fix A", "2026-10-01T10:00:00Z", {BUGS["A"][0]: source("A", True)}),
    ("fix B", "2026-10-01T11:00:00Z", {BUGS["B"][0]: source("B", True)}),
    ("fix D", "2026-10-01T12:00:00Z", {BUGS["D"][0]: source("D", True)}),
    ("fix C", "2026-10-03T09:00:00Z", {BUGS["C"][0]: source("C", True)}),
]
SHA = {}
for name, when, files in STEPS:
    for path, text in files.items():
        put(REPO, path, text)
    with dated(when):
        SHA[name] = helpers.commit(REPO, name)
git(REPO, "checkout", "-q", "main")
with dated("2026-10-10T10:00:00Z"):
    git(REPO, "merge", "--no-ff", "-q", "-m", "merge feat", "feat")
GITDIR = C.L.common_dir(REPO)
WORK = os.path.dirname(GITDIR)

# the ledger (two pre-merge rounds: C is found in round 1 and fixed after it) and Codex's answers to them
CODEX_FOUND = {"verdict": "changes", "reviewed_files": [], "findings": [
    {"severity": "P1", "file": BUGS["C"][0], "line": 6, "summary": "C_BUG: f() adds four where it should add seven",
     "failure_scenario": "f(0) returns 4"}]}
helpers.write_rollout(ORIGINAL_HOME, "th-orig", [{"turn": "tr1", "answer": CODEX_FOUND},
                                                 {"turn": "tr2", "answer": {"verdict": "approve", "findings": [], "reviewed_files": []}}])


def receipt(nonce, at, turn, tip, verdict):
    return {"v": 2, "kind": "receipt", "checkpoint": "pre-merge", "nonce": nonce, "dispatched_at": at, "verdict": verdict, "thread": "th-orig",
            "turn": turn, "clean": True,
            "targets": [{"repo": GITDIR, "dest": "main", "dest_ref": "main", "branch": "feat", "range": "main...feat", "base": BASE, "tip": tip,
                         "full": True}]}


helpers.write_ledger(STATE_HOME, REPO, [
    receipt("xr-e2e-1", "2026-10-03T08:00:00.000000Z", "tr1", SHA["fix D"], "changes"),
    receipt("xr-e2e-2", "2026-10-03T12:00:00.000000Z", "tr2", SHA["fix C"], "approve")])


# ---------------------------------------------------------------- the task reviews, as Claude Code transcripts
def stamp(minute):
    return "2026-10-01T%02d:%02d:00.000Z" % (minute // 60, minute % 60)


def subagent(aid, description, prompt, report, start):
    return {"id": aid, "meta": {"agentType": "sp-reviewer", "description": description, "toolUseId": "toolu_" + aid, "spawnDepth": 1},
            "entries": [
                {"type": "user", "timestamp": stamp(start), "cwd": WORK, "message": {"role": "user", "content": prompt}},
                {"type": "assistant", "timestamp": stamp(start + 1), "cwd": WORK, "message": {
                    "id": "m" + aid, "role": "assistant", "model": "claude-opus-5", "content": [{"type": "text", "text": report}],
                    "usage": {"input_tokens": 10, "output_tokens": 5, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 1000}}}]}


def re_review(n, start, base, head, note):
    return subagent("rr%d" % n, "Re-review W1 Task 1 fix round %d" % n,
                    "Re-review.\nFinding under verification (Important): {}\nFix base {}, head {}.\n".format(note, base, head),
                    "Fixed (round %d)." % n, start)


helpers.write_transcript(PROJECTS, "-e2e-erepo", "sess-e2e", [{"type": "user", "timestamp": stamp(0), "cwd": WORK, "message": {"role": "user", "content": "go"}}], [
    subagent("rv", "Review W1 Task 1", "Review task 1.\nBASE_SHA: {}\nHEAD_SHA: {}\n".format(SHA["plan"], SHA["task 1"]),
             "Task 1: A, B and D are wrong.", 9 * 60 + 30),
    re_review(1, 10 * 60 + 30, SHA["task 1"], SHA["fix A"], "A_BUG in a.py"),
    re_review(2, 11 * 60 + 30, SHA["fix A"], SHA["fix B"], "B_BUG in b.py"),
    re_review(3, 12 * 60 + 30, SHA["fix B"], SHA["fix D"], "D_BUG in d.py")])

# ---------------------------------------------------------------- the stubs: a Codex binary and an rpc
STATE = os.path.join(ROOT, "state")
SOURCE_HOME = os.path.join(ROOT, "codex-src")
put(SOURCE_HOME, "config.toml", 'model = "m-1"\n')
FAKE_CODEX = os.path.join(ROOT, "fakecodex")
os.environ["CODEX_REAL_BIN"] = helpers.stub_codex(FAKE_CODEX)
RPC_DIR = os.path.join(ROOT, "rpc")
XR.RPC = helpers.stub_rpc(RPC_DIR, ORIGINAL_HOME, {"default": {"answer": {"word": "ok"}}})      # the probe's turn
CODEX_LOG, RPC_LOG = os.path.join(FAKE_CODEX, "codex.log"), os.path.join(RPC_DIR, "rpc.log")
NOMEM = os.path.join(STATE_HOME, "cxh", "nomem")


# ---------------------------------------------------------------- the judges, the final reviewers and the recreating agent
def letter_of(text):
    m = re.search(r"\b([A-D])_BUG", text or "")
    return m.group(1) if m else None


def inventory(state=None):
    """{letter: defect} of the one inventoried branch."""
    d = os.path.join(state or STATE, "inventory")
    names = sorted(os.listdir(d)) if os.path.isdir(d) else []
    return dict((letter_of(x["summary"]), x) for n in names for x in C.jload(os.path.join(d, n))["defects"])


def final_transcript(jid):
    entries = [{"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "You are a Senior Code Reviewer.\n\nReview id: {}\n".format(jid)}]}},
               {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": "Bash",
                                                                                 "input": {"command": "git diff HEAD~1"}}]}}]
    helpers.write_transcript(PROJECTS, KEY, "sess-" + jid, [{"type": "user", "message": {"role": "user", "content": "drive"}}],
                             subagents=[{"id": jid, "meta": {"agentType": "sp-architect"}, "entries": entries}])


def recreate(inp, done):
    """The recreating agent: undo D's fix in the copy of the tree, through the aliased path it is given."""
    tree = C.jload(inp)["tree"]
    path = os.path.join(tree, BUGS["D"][0])
    with open(path) as f:
        text = f.read()
    with open(path, "w") as f:
        f.write(text.replace(BUGS["D"][1], "    return y + 5  # D_BUG_REC\n"))
    put(os.path.dirname(done), "done", "")


def listed(state):
    """[(kind, id, input path, answer path)] as the driving session of Part B reads them: from `pending`'s output, each brief's own lines.
    A judge's brief names its staged input and answer (`Input:`, `Write your answer to:`); a final review's answer.md sits beside its
    brief; a recreation's brief names its spec and the done marker. Every path is checked to lie where an agent may be sent."""
    rc, out = cli("pending", state=state)
    assert rc == 0, out
    items = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            assert line == "nothing pending", line
            continue
        kind, jid, brief = parts
        with open(brief) as f:
            text = f.read()
        here = os.path.dirname(brief)
        if kind == "final":
            items.append((kind, jid, None, os.path.join(here, "answer.md")))
        elif kind == "recreate":
            items.append((kind, jid, re.search(r"Read (\S+\.json)\.", text).group(1), re.search(r"create an empty file at (\S+)\.", text).group(1)))
        else:
            inp, ans = re.search(r"^Input: (\S+)\nWrite your answer to: (\S+)$", text, re.M).groups()
            assert os.path.dirname(inp) == here and os.path.dirname(ans) == here and here.startswith(C.items_root() + os.sep), (inp, ans, brief)
            items.append((kind, jid, inp, ans))
    return items


def answer(state, finals="AB"):
    """Answer everything `pending` lists once, working from the staged briefs only; how many items. `finals`: the defects the final
    reviews report. A kind the fixture does not expect fails the test."""
    n = 0
    for kind, jid, inp, ans in listed(state):
        doc = C.jload(inp) if inp and inp.endswith(".json") and kind != "recreate" else None
        if kind == "judge-task":
            found = []
            for ch in doc["changes"]:
                x = letter_of(re.search(r"^-.*_BUG.*$", ch["diff"], re.M).group(0))
                file_, _g, _b, sev, _c = BUGS[x]
                found.append({"index": len(found), "report": 0, "summary": "{}_BUG: {}".format(x, file_), "file": file_, "line": 6,
                              "failure_scenario": "f(0) is wrong in " + file_, "severity": sev, "introduced_by": None, "fixed_by": [ch["index"]],
                              "answer": "yes"})
            C.jsave(ans, {"findings": found})
        elif kind == "judge-known":
            C.jsave(ans, {"verdicts": [{"index": f["index"], "answer": "yes"} for f in doc["findings"]]})
        elif kind == "judge-dedup":
            C.jsave(ans, {"groups": [[d["index"]] for d in doc["defects"]]})
        elif kind == "judge-present":
            x, text = letter_of(doc["finding"]["summary"]), "\n".join(f["text"] for f in doc["files"])
            C.jsave(ans, {"answer": "yes" if x + "_BUG" in text and "D_BUG_ORIG" not in text else "no"})
        elif kind == "judge-same":
            C.jsave(ans, {"answer": "yes"})
        elif kind == "judge-match":
            if "report" in doc:
                claims = re.findall(r"^FINDING: (.*)$", doc["report"], re.M)
                found = claims
            else:
                claims = None
                found = [f["summary"] for f in doc["findings"]]
            matches = [{"defect": d["index"], "finding": next((i for i, s in enumerate(found) if s == d["summary"]), None)} for d in doc["defects"]]
            used = set(m["finding"] for m in matches)
            out = {"matches": matches, "unmatched": [{"finding": i, "ruling": "false_positive"} for i in range(len(found)) if i not in used]}
            if claims is not None:
                out["findings"] = [{"index": i, "summary": s} for i, s in enumerate(claims)]
            C.jsave(ans, out)
        elif kind == "final":
            with open(ans, "w") as f:
                f.write("### Issues\n" + "".join("FINDING: {}\n".format(inventory(state)[x]["summary"]) for x in finals) + "### Assessment\nReady to merge? With fixes\n")
            final_transcript(jid)
        elif kind == "recreate":
            recreate(inp, ans)
        else:
            raise AssertionError("the fixture does not expect a {} ({})".format(kind, jid))
        n += 1
    return n


def settle(command, limit=12, state=None, finals="AB"):
    """`command`, answer, `command`, ... until nothing is left to answer; the last output."""
    for _ in range(limit):
        rc, out = cli(command, state=state)
        if rc != 0:
            raise AssertionError("{} exited {}: {}".format(command, rc, out))
        if not answer(state or STATE, finals):
            return out
    raise AssertionError("{} did not settle".format(command))


def tree_listing(root, ignore=("items.json", "items.lock", "alias")):
    return [x for x in helpers.listing(root) if os.path.basename(x[0]) not in ignore and not x[0].startswith("judges" + os.sep)]


# ================================================================ the dry runs, before anything real
rc, out = cli("snapshot", "--dry-run")
is_("dry run: snapshot exits 0 and writes nothing", (rc, os.path.exists(os.path.join(STATE, "reviews.json"))), (0, False))

# ================================================================ snapshot
rc, out = cli("snapshot")
is_("snapshot: exits 0", rc, 0)
reviews = C.jload(os.path.join(STATE, "reviews.json"))
is_("snapshot: one task group of four reviews, mapped to the repository",
    [(g["task"], len(g["reviews"]), g["repo"]) for g in reviews["groups"]], [(1, 4, GITDIR)])

# ================================================================ cases (the judge-task, judge-known and judge-dedup phases)
rc, out = cli("cases", "--dry-run")
is_("dry run: cases exits 0 and writes no branches.json and no inventory", (rc, os.path.exists(os.path.join(STATE, "branches.json")),
                                                                         os.path.exists(os.path.join(STATE, "inventory"))), (0, False, False))
out = settle("cases")
branches = C.jload(os.path.join(STATE, "branches.json"))["branches"]
is_("cases: the branch is a candidate and opened", [(b["branch"], b["candidate"], b["opened"]) for b in branches], [("feat", True, True)])
inv = inventory()
is_("cases: the inventory holds the three per-task defects and the pre-merge one",
    sorted((x, d["class"], d["severity"], d["counted"]) for x, d in inv.items()),
    [("A", "task", "P1", True), ("B", "task", "P1", True), ("C", "pre", "P1", True), ("D", "task", "P2", True)])

# ================================================================ inject (judge-present, the recreation, judge-same)
out = settle("inject")
cases = C.jload(os.path.join(STATE, "cases.json"))
ok("inject: the branch qualified, with all four defects", len(cases["cases"]) == 1 and len(cases["cases"][0]["defects"]) == 4, cases)
CASE = cases["cases"][0]
injected = C.jload(os.path.join(STATE, "injected", CASE["branch"] + ".json"))
is_("inject: complete, with D recreated by hand and the others present",
    (injected["complete"], dict((letter_of(inv_d["summary"]), injected["defects"][inv_d["id"]]["status"]) for inv_d in inv.values())),
    (True, {"A": "present", "B": "present", "C": "present", "D": "recreated"}))
is_("inject: coverage holds, no per-task defect is unassessable", cases["coverage"]["unassessable_task"], [])

# ================================================================ the dry runs of the gates: no daemon, no turn, nothing written
before = tree_listing(STATE)
for argv in (("run", "--dry-run"), ("match", "--dry-run"), ("report", "--dry-run"), ("cleanup", "--dry-run"), ("home", "--name", "nomem", "--start", "--probe",
                                                                                                               "--dry-run", "--codex-source", SOURCE_HOME)):
    rc, out = cli(*argv)
    is_("dry run: {} exits 0".format(argv[0]), rc, 0)
is_("dry run: no daemon was started and no rpc call was made", (helpers.read_log(CODEX_LOG), helpers.read_log(RPC_LOG)), ([], []))
is_("dry run: run, match, report, cleanup and home wrote nothing into the state", tree_listing(STATE), before)
ok("dry run: and made no replay home and no run", not os.path.exists(NOMEM) and not os.path.exists(os.path.join(STATE, "runs")))

# the same state before any run, for the variant that must fail (a copy takes a name of its own, the original's alias stays)
STATE2 = os.path.join(ROOT, "state-fail")
shutil.copytree(STATE, STATE2, symlinks=True)

# ================================================================ home
rc, out = cli("home", "--login-cmd")
ok("home: --login-cmd prints the login line for the stub binary", rc == 0 and "login" in out and FAKE_CODEX in out, out)
rc, out = cli("home", "--name", "nomem", "--start", "--probe", "--codex-source", SOURCE_HOME)
is_("home: --start --probe exits 0 (the probe passes against the stubs)", rc, 0)
ok("home: the daemon was started on the replay home and its socket exists", any(e["argv"][:3] == ["app-server", "daemon", "start"] and e["codex_home"] == NOMEM
                                                                               for e in helpers.read_log(CODEX_LOG))
   and os.path.exists(os.path.join(NOMEM, "app-server-control", "app-server-control.sock")))

# ================================================================ run and match
FINDING = dict((x, {"severity": d["severity"], "file": d["file"], "line": d["line"], "summary": d["summary"], "failure_scenario": d["failure_scenario"]})
               for x, d in inv.items())


def codex_turn(x):
    return {"answer": {"verdict": "changes", "findings": [FINDING[x]], "reviewed_files": [FINDING[x]["file"]]}, "tokens": 1000}


ROUNDS = [codex_turn("C"), codex_turn("D"), {"answer": {"verdict": "approve", "findings": [], "reviewed_files": []}, "tokens": 1000}]
XR.RPC = helpers.stub_rpc(RPC_DIR, ORIGINAL_HOME, {"threads": dict(("th%d" % i, ROUNDS) for i in range(1, 9))})
rc, out = cli("run")
is_("run: exits 0 and leaves the two final reviews to answer", rc, 0)
rc, out = cli("pending")
lines = [l.split("\t") for l in out.splitlines()]
is_("pending: lists the two final reviews", sorted(l[0] for l in lines), ["final", "final"])
ok("pending: each brief is the staged one, in a directory of its own outside the state, holding the brief and the package",
   all(os.path.dirname(l[2]).startswith(C.items_root() + os.sep) and os.path.basename(l[2]) == "brief.md"
       and os.path.isfile(os.path.join(os.path.dirname(l[2]), "package.diff")) for l in lines), lines)
ok("pending: and no path it prints names the state", not any(STATE in x or "process-replay" in x for l in lines for x in l), lines)
def turn_starts():
    return len([e for e in helpers.read_log(RPC_LOG) if e["cmd"] == "turn-start"])


probe_turns = turn_starts()                         # the probe's own turn
answer(STATE)                                       # the final reviews
rc, out = cli("run")
answer(STATE)                                       # their judge-matches
rc, out = cli("match")
is_("match: applies the answers and starts no Codex round", (rc, turn_starts()), (0, probe_turns))
ok("run: every run now waits for a Codex round", all(C.jload(os.path.join(STATE, "runs", CASE["id"], lab, "state.json"))["step"] == "codex"
                                                     for lab in os.listdir(os.path.join(STATE, "runs", CASE["id"]))))
before = tree_listing(STATE)
rc, out = cli("run", "--dry-run")
is_("dry run: run with Codex rounds due exits 0, starts no turn and changes no state file",
    (rc, turn_starts(), tree_listing(STATE)), (0, probe_turns, before))
out = settle("run", 30)
rc, match_out = cli("match")
is_("match: exits 0 with nothing left to apply", rc, 0)
runs = sorted((C.jload(os.path.join(STATE, "runs", CASE["id"], lab, "state.json")) for lab in os.listdir(os.path.join(STATE, "runs", CASE["id"]))),
              key=lambda r: r["label"])
is_("run: two runs of the case", len(runs), 2)
for r in runs:
    is_("run: run {} ended at approve".format(r["label"][:2]), (r["end"], r["step"], r["voids"], r.get("error")), ("approve", "done", 0, None))
    is_("run: it recovered every defect: the final review found A and B, the Codex rounds C and D",
        dict((letter_of(inv_d["summary"]), r["defects"][inv_d["id"]]) for inv_d in inv.values()), dict((x, "recovered") for x in "ABCD"))
    is_("run: one final review and three Codex rounds, one defect found by each",
        [(v["kind"], len(v["findings"])) for v in r["reviews"]], [("final", 2), ("codex", 1), ("codex", 1), ("codex", 0)])
    is_("run: it spent the Codex tokens of three turns", r["tokens"], 3000)
log = helpers.read_log(RPC_LOG)
ok("run: every rpc call but the probe's check of the source home ran against the replay home, never the original", log and all(e["codex_home"] == NOMEM for e in log if e["cmd"] != "health")
   and any(e["cmd"] == "turn-start" for e in log), set(e["codex_home"] for e in log))

# ================================================================ report
rc, out = cli("report")
is_("report: exits 0", rc, 0)
data = C.jload(os.path.join(STATE, "report.json"))
is_("report: the status is computed: every run assessable and every per-task defect recovered, so pass", data["bar"]["status"], "pass")

# ================================================================ a variant that fails: the final reviews leave B out, so B stays unrecovered
rc, out = cli("run", state=STATE2)
out = settle("run", 30, state=STATE2, finals="A")
runs2 = [C.jload(os.path.join(STATE2, "runs", CASE["id"], lab, "state.json")) for lab in sorted(os.listdir(os.path.join(STATE2, "runs", CASE["id"])))]
is_("variant: both runs end at approve, with B unrecovered and the rest recovered",
    [(r["end"], dict((letter_of(d["summary"]), r["defects"][d["id"]]) for d in inv.values())) for r in runs2],
    [("approve", {"A": "recovered", "B": "unrecovered", "C": "recovered", "D": "recovered"})] * 2)
rc, out = cli("report", state=STATE2)
data2 = C.jload(os.path.join(STATE2, "report.json"))
is_("variant: the status follows the defect outcomes: a per-task P1 unrecovered while the pre-merge P1 was recovered is a fail", (rc, data2["bar"]["status"]), (0, "fail"))
ok("variant: and the reason names B", any(inv["B"]["id"] in r for r in data2["bar"]["reasons"]), data2["bar"]["reasons"])

# ================================================================ cleanup
threads = [t["thread"] for t in C.jload(os.path.join(STATE, "threads.json"))["threads"]]
items = C.jload(os.path.join(STATE, "items.json"))
scratches = [r["scratch"] for r in runs]
ok("cleanup: control: the threads, scratches, work, views and staged items exist before",
   threads and all(os.path.isdir(s) for s in scratches) and os.path.isdir(os.path.join(STATE, "work"))
   and os.path.isdir(os.path.join(STATE, "views")) and all(os.path.isdir(os.path.join(C.items_root(), n)) for n in items.values()))
def rid_of(state, did):
    names = [n[:-5] for n in os.listdir(os.path.join(state, "recreate")) if n.startswith(did + "-") and n.endswith(".json")]
    assert len(names) == 1, (did, names)
    return names[0]


CASE_D = rid_of(STATE, inv["D"]["id"])
ok("cleanup: control: the recreation's working copy exists before", os.path.isdir(os.path.join(STATE, "recreate", CASE_D, "tree")))
rc, out = cli("cleanup")
is_("cleanup: exits 0", rc, 0)
rc2, out2 = cli("cleanup")
is_("cleanup: and a second cleanup is a no-op that exits 0", rc2, 0)
archived = C.jload(os.path.join(RPC_DIR, "rpc-state.json"))["archived"]
ok("cleanup: every thread of threads.json is archived (the probe's own thread was archived by the probe)", set(threads) <= set(archived) and len(threads) == 2, (threads, archived))
ok("cleanup: and recorded as done", all(t["done"] for t in C.jload(os.path.join(STATE, "threads.json"))["threads"]))
ok("cleanup: the stub daemon was stopped", any(e["argv"][:3] == ["app-server", "daemon", "stop"] and e["codex_home"] == NOMEM
                                               for e in helpers.read_log(CODEX_LOG)) and not os.path.exists(os.path.join(NOMEM, "app-server-control", "app-server-control.sock")))
rc, out = cli("pending")
ok("cleanup: and nothing is left pending", rc == 0 and "nothing pending" in out, out)
ok("cleanup: the daemon marker is gone with the daemon", not os.path.exists(os.path.join(STATE_HOME, "process-replay", "codex-auth", "daemon.json")))
rc, out = cli("report", "--dry-run")
ok("cleanup: report still works from the JSON that stays", rc == 0 and "status: PASS" in out, out[:200])
