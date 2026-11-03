import difflib
import io
import json
import contextlib
import fcntl
import os
import re
import subprocess
import sys
import threading
import time
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import codex as K  # noqa: E402
from process_replay import common as C  # noqa: E402
from process_replay import loop as P  # noqa: E402
from process_replay import scratch  # noqa: E402
from process_replay.common import Failed  # noqa: E402

XR, L = C.XR, C.L
ROOT = helpers.tmp_root()
SNAPSHOTS = os.path.join(ROOT, "snapshots")
PROJECTS = os.path.join(ROOT, "projects")
PLAN = "docs/superpowers/plans/2026-10-20-x.md"
KEY = re.sub(r"[^A-Za-z0-9]", "-", os.path.expanduser("~/Code/.replay"))
NOMEM = os.path.join(os.environ["XDG_STATE_HOME"], "cxh", "nomem")
helpers.put(NOMEM, "replay-home.json", json.dumps({"source": "x"}))
helpers.put(NOMEM, "probe.json", json.dumps({"at": "2026-11-03T00:00:00Z", "ok": True, "checks": {"daemon": True}, "expect_memories": False}))
os.makedirs(PROJECTS)

# ---- a superpowers fixture (PROCESS_REPLAY_SUPERPOWERS), shaped like the real 7.x skills directory
SP = os.path.join(ROOT, "superpowers")
put(SP, "skills/requesting-code-review/code-reviewer.md", """# Code Reviewer Prompt Template

Use this template when dispatching a code reviewer subagent.

```
Subagent (general-purpose):
  description: "Review code changes"
  prompt: |
    You are a Senior Code Reviewer.

    ## What Was Implemented

    [DESCRIPTION]

    ## Requirements / Plan

    [PLAN_OR_REQUIREMENTS]

    ## Git Range to Review

    **Base:** [BASE_SHA]
    **Head:** [HEAD_SHA]

    ```bash
    git diff [BASE_SHA]..[HEAD_SHA]
    ```
```

**Placeholders:**
- `[DESCRIPTION]` is brief
""")
PKG = os.path.join(SP, "skills/subagent-driven-development/scripts/review-package")
put(os.path.dirname(PKG), "review-package", """#!/usr/bin/env bash
set -euo pipefail
plan=$1; base=$2; head=$3; out=$4
[ -f "$plan" ] || { echo "no such plan file: $plan" >&2; exit 2; }
git merge-base --is-ancestor "$base" "$head" || exit 3
mkdir -p "$(dirname "$out")"
{ echo "# Review package: ${base}..${head}"; git diff --stat "${base}..${head}"; } > "$out"
echo "wrote ${out}"
""")
os.chmod(PKG, 0o755)
os.environ["PROCESS_REPLAY_SUPERPOWERS"] = SP

# ---- the defects: where they sit in a 40-line file. ("replace", line, text) or ("drop", first, last), fixed coordinates.
FIXED = {"src/%s.py" % n: ["%s%d\n" % (n, i) for i in range(1, 41)] for n in "abck"}
DEFECTS = {
    "dA": ("src/a.py", ("replace", 5, "A_BUG\n"), "task", "P1"),
    "dF": ("src/a.py", ("replace", 8, "F_BUG\n"), "task", "P2"),
    "dG": ("src/a.py", ("replace", 25, "G_BUG\n"), "pre", "P2"),
    "dB": ("src/b.py", ("replace", 5, "B_BUG\n"), "pre", "P1"),
    "dC": ("src/c.py", ("replace", 5, "C_BUG\n"), "task", "P0"),
    "dD": ("src/c.py", ("replace", 30, "D_BUG\n"), "pre", "P2"),
    "dK": ("src/k.py", ("drop", 3, 4), "task", "P1"),
    "dL": ("src/k.py", ("replace", 30, "L_BUG\n"), "pre", "P2"),
    "dM": ("src/k.py", ("replace", 26, "M_BUG\n"), "task", "P2"),
}
GROUPS = {"dC": "gcd", "dD": "gcd"}


def render(path, bugged):
    lines = list(FIXED[path])
    drop = set()
    for did in bugged:
        f, (op, a, b), _c, _s = DEFECTS[did]
        if f != path:
            continue
        if op == "replace":
            lines[a - 1] = b
        else:
            drop |= set(range(a - 1, b))
    return [l for i, l in enumerate(lines) if i not in drop]


def make_patch(path, before, after):
    return "".join(difflib.unified_diff(before, after, "a/" + path, "b/" + path, n=3))


def parse_hunks(path, patch):
    out = []
    for m in re.finditer(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", patch, re.M):
        s, ol, ns, nl = int(m.group(1)), int(m.group(2) or 1), int(m.group(3)), int(m.group(4) or 1)
        out.append({"file": path, "start": s, "end": s + max(ol, 1) - 1, "new_start": ns, "new_end": ns + max(nl, 1) - 1})
    return out


class World(object):
    """An original repository, the work repository inject would have built (a tree with the defects in), the records
    inject and cases leave in the state, and a state directory."""

    def __init__(self, name, ids=("dA", "dB", "dC", "dD"), cases=1, original_rounds=3):
        self.name = name
        self.state = os.path.join(ROOT, "state-" + name)
        self.orig = helpers.make_repo(ROOT, "orig-" + name)
        put(self.orig, "README", "base\n")
        self.base = helpers.commit(self.orig, "base")
        git(self.orig, "checkout", "-q", "-b", "feat")
        put(self.orig, PLAN, "# plan\n")
        paths = sorted(FIXED)
        for p in paths:
            put(self.orig, p, "".join(render(p, ids)))
        self.buggy = helpers.commit(self.orig, "buggy tree")
        self.common = os.path.realpath(os.path.join(self.orig, ".git"))
        self.objects = os.path.join(self.common, "objects")
        self.ids = list(ids)
        self.cases = []
        bid = "b" + name
        self.bid = bid
        work = os.path.join(self.state, "work", bid)
        files = os.path.join(ROOT, "files-" + name)
        scratch.export(self.objects, self.buggy, files)
        self.wc = scratch.build(self.objects, self.base, files, work, "main", "feat", expect_tree=git(self.orig, "rev-parse", self.buggy + "^{tree}"))
        self.work = work
        defects, drec, self.patches = [], {}, {}
        for did in ids:
            f, _op, cls, sev = DEFECTS[did]
            members = [d for d in ids if GROUPS.get(d) == GROUPS.get(did)] if did in GROUPS else [did]
            fixed_ids = [d for d in ids if d not in members]
            path = f
            put(work, path, "".join(render(path, fixed_ids)))                 # a real git diff, so it carries the blobs' ids (--3way needs them)
            patch = git(work, "diff", "--no-color", "--", path) + "\n"
            git(work, "checkout", "-q", "--", path)
            repair = os.path.join(self.state, "repairs", did + ".patch")
            put(os.path.dirname(repair), os.path.basename(repair), patch)
            self.patches[did] = patch
            drec[did] = {"status": "present", "reason": "", "group": GROUPS.get(did, did), "repair": repair, "hunks": parse_hunks(path, patch)}
            defects.append({"id": did, "class": cls, "severity": sev, "counted": True, "summary": "bug in " + did, "file": f, "line": DEFECTS[did][1][1],
                            "failure_scenario": "it breaks " + did, "fixes": [], "files": [f], "at": "2026-10-20T10:00:00Z"})
        C.jsave(os.path.join(self.state, "inventory", bid + ".json"), {"branch": bid, "defects": defects})
        C.jsave(os.path.join(self.state, "injected", bid + ".json"), {"work": work, "work_commit": self.wc, "plan_commit": self.base, "defects": drec,
                                                                      "complete": True})
        C.jsave(os.path.join(self.state, "branches.json"), {"branches": [
            {"id": bid, "repo": self.common, "objects": self.objects, "view": None, "dest": "main", "dest_ref": "main", "branch": "feat",
             "base": self.base, "rounds": [{"k": 1, "nonce": "n1", "tip": self.buggy, "base": self.base, "thread": "t", "turns": [], "at": "2026-10-20T10:00:00Z",
                                            "verdict": "changes"}], "plan_commit": self.base}]})
        cases = [{"id": "c%s%d" % (name, i), "branch": bid, "repo": self.common, "defects": list(ids), "original_rounds": original_rounds,
                  "work_commit": self.wc} for i in range(cases)]
        C.jsave(os.path.join(self.state, "cases.json"), {"cases": cases, "examined": [], "coverage": {"unassessable_task": []}})
        self.case_ids = [c["id"] for c in cases]

    def args(self, **kw):
        return Namespace(**dict({"state": self.state, "dry_run": False, "snapshot_root": SNAPSHOTS, "projects_dir": PROJECTS,
                                 "max_tokens": 10 ** 9, "budget": 60}, **kw))

    def runs(self):
        out = []
        for cid in self.case_ids:
            d = os.path.join(self.state, "runs", cid)
            for lab in sorted(os.listdir(d)) if os.path.isdir(d) else []:
                run = C.jload(os.path.join(d, lab, "state.json"))
                if run:
                    out.append(run)
        return out

    def live(self):
        return [r for r in self.runs() if r["end"] != "void" or not r.get("replaced_by")]


# ---- the fakes: the ledger and the Codex round
CALLS, PREP = [], []
INFLIGHT = {"n": 0, "max": 0}
LOCK = threading.Lock()
BEHAVE = {"fn": None, "delay": 0}


def fake_prepare(a, run, case, branch):
    PREP.append((run["label"], K._ENV["n"]))
    d = os.path.join(a.state, "runs", case["id"], run["label"], "ledger")
    os.makedirs(d, exist_ok=True)
    run["ledger"] = d
    return d


def fake_round(a, run, case, branch, home):
    with LOCK:
        INFLIGHT["n"] += 1
        INFLIGHT["max"] = max(INFLIGHT["max"], INFLIGHT["n"])
    try:
        k = 1 + sum(1 for r in run["reviews"] if r["kind"] == "codex")
        CALLS.append({"label": run["label"], "k": k, "tip": git(run["scratch"], "rev-parse", "HEAD"), "rejected": list(run["rejected"]),
                      "addressed": list(run["addressed"]), "home": home, "thread": run["thread"]})
        time.sleep(BEHAVE["delay"])
        out = BEHAVE["fn"](run, k)
        if isinstance(out, Exception):
            raise out
        if isinstance(out, tuple):
            verdict, findings = out
            th = run["thread"] or "th-" + run["label"]
            return {"kind": "codex", "k": k, "findings": findings, "verdict": verdict, "tokens": 100, "turns": [[th, "tu%d" % k]],
                    "model": "m-1", "effort": "high", "missing": None, "decision": {"action": "send"}, "thread": th}
        return out
    finally:
        with LOCK:
            INFLIGHT["n"] -= 1


K.prepare_ledger = fake_prepare
K.codex_round = fake_round
P.codexhome.alive = lambda home: True


def F(did, severity="P1", **kw):
    f, (_op, line, _t), _c, _s = DEFECTS[did]
    return dict({"severity": severity, "file": f, "line": line, "summary": "found " + did, "failure_scenario": "x"}, **kw)


def OTHER(summary="something else", severity="P2"):
    return {"severity": severity, "file": "src/z.py", "line": 3, "summary": summary, "failure_scenario": "y"}


def behave(fn, delay=0):
    BEHAVE["fn"], BEHAVE["delay"] = fn, delay
    del CALLS[:]
    INFLIGHT.update(n=0, max=0)


# ---- the driver's part: answer what is pending
def final_transcript(jid, commands=(), prompt=None, key=None):
    first = prompt or "You are a Senior Code Reviewer.\n\nReview id: {}\n".format(jid)
    entries = [{"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": first}]}}]
    for c in commands:
        entries.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": c}}]}})
    helpers.write_transcript(PROJECTS, key or KEY, "sess-" + jid, [{"type": "user", "message": {"role": "user", "content": "drive"}}],
                             subagents=[{"id": jid, "meta": {"agentType": "sp-architect"}, "entries": entries}])


def drive(w, report=(), real=(), valid="yes", transcripts=True, commands=()):
    """Answer every pending item once; the number answered. `report`: the summaries the final review reports; `real`: summaries ruled real
    (the rest false_positive); `valid`: judge-present's answer, a string or {defect: answer}."""
    n = 0
    for kind, jid, inp, ans, _brief in C.pending(w.state):
        if kind == "final":
            with open(ans, "w") as f:
                f.write("### Issues\n" + "".join("FINDING: %s\n" % s for s in report) + "### Assessment\nReady to merge? With fixes\n")
            if transcripts:
                final_transcript(jid, commands)
        elif kind == "judge-match":
            doc = C.jload(inp)
            if "report" in doc:
                found = [m.group(1) for m in re.finditer(r"^FINDING: (.*)$", doc["report"], re.M)]
                findings = [{"index": i, "summary": s} for i, s in enumerate(found)]
            else:
                found = [f["summary"] for f in doc["findings"]]
                findings = None
            by = {}
            matches = []
            for d in doc["defects"]:
                want = "found " + d["summary"].split()[-1]
                at = found.index(want) if want in found else None
                matches.append({"defect": d["index"], "finding": at})
                if at is not None:
                    by[at] = True
            out = {"matches": matches, "unmatched": [{"finding": i, "ruling": "real" if s in real else "false_positive"} for i, s in enumerate(found) if i not in by]}
            if findings is not None:
                out["findings"] = findings
            C.jsave(ans, out)
        elif kind == "judge-present":
            doc = C.jload(inp)
            did = doc["finding"]["summary"].split()[-1]
            C.jsave(ans, {"answer": valid.get(did, "yes") if isinstance(valid, dict) else valid})
        else:
            continue
        n += 1
    return n


def go(w, rounds=True, **kw):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        (P.cmd_run if rounds else P.cmd_match)(w.args(**kw))
    return out.getvalue()


def settle(w, limit=40, **kw):
    """run, answer, run, ... until nothing is pending; the last output."""
    text = ""
    for _ in range(limit):
        text = go(w)
        if not drive(w, **kw):
            return text
    raise AssertionError("did not settle")


def to_codex(w, **kw):
    """Every run at the Codex step with no round started: the final review answered and matched with nothing."""
    go(w)
    drive(w, **kw)
    go(w, rounds=False)
    drive(w, **kw)
    go(w, rounds=False)


def snap(state):
    out = {}
    for d, _dirs, files in os.walk(state):
        for f in files:
            p = os.path.join(d, f)
            if os.path.islink(p):
                continue
            out[os.path.relpath(p, state)] = (os.stat(p).st_mtime_ns, open(p, "rb").read())
    return out


def by_status(run):
    return dict(run["defects"])


# ================================================================== setup
w = World("setup", cases=2)
behave(lambda run, k: ("approve", []))
del PREP[:]
text = go(w)
runs = w.runs()
is_("setup: two runs per case", sorted((r["case"] for r in runs)), sorted(w.case_ids * 2))
labels = [r["label"] for r in runs]
ok("setup: neutral 8-hex labels, all different", len(set(labels)) == 4 and all(re.match(r"\A[0-9a-f]{8}\Z", l) for l in labels), labels)
want_root = os.path.join(os.environ["XDG_STATE_HOME"], "review-work", "scratch")
ok("setup: each scratch is physically under review-work/scratch/<label>, a path that does not name the replay",
   all(r["scratch"] == os.path.join(want_root, r["label"]) and "replay" not in r["scratch"] and os.path.isdir(r["scratch"] + "/.git") for r in runs),
   [r["scratch"] for r in runs])
ok("setup: a scratch holds the work commit's tree and one commit above the base",
   all(git(r["scratch"], "rev-parse", "HEAD^{tree}") == git(w.work, "rev-parse", w.wc + "^{tree}") and git(r["scratch"], "rev-parse", "HEAD~1") == w.base for r in runs))
ok("setup: run states start at the final review with every defect present",
   all(r["step"] == "final" and r["end"] is None and r["voids"] == 0 and r["tokens"] == 0 and set(r["defects"].values()) == {"present"}
       and sorted(r["defects"]) == sorted(w.ids) for r in runs), runs[0])
ok("setup: every run's ledger was prepared before any replay home was active", len(PREP) == 4 and all(n == 0 for _l, n in PREP), PREP)
ok("setup: each run has its ledger recorded", all(r["ledger"] and os.path.isdir(r["ledger"]) for r in runs))
ok("setup: a final brief waits for every run, and nothing else ran", len(CALLS) == 0 and sorted(i for k, i, *_ in C.pending(w.state) if k == "final") == sorted(labels),
   C.pending(w.state))

# ---- runs_per_case: the number of runs per case is common.RUNS (report reads the same one)
w3 = World("runs3")
C.RUNS = 3
try:
    go(w3)
finally:
    C.RUNS = 2
is_("runs_per_case: with common.RUNS at 3, run makes three runs of the case", len(w3.runs()), 3)

# ---- the final review's brief is staged (the content tests are in t_final.py)
r0 = w.runs()[0]
brief_path = os.path.join(C.item_dir(w.state, "final", r0["label"]), "brief.md")
ok("final_brief: the run's brief is staged and the state keeps its marker copy", os.path.isfile(brief_path)
   and open(brief_path).read() == open(os.path.join(w.state, "final", r0["label"], "brief.md")).read() and "Review id: " + r0["label"] in open(brief_path).read())
ok("final_brief: pending hands out the staged brief, not a state path", sorted(b for k, i, _x, _y, b in C.pending(w.state) if k == "final") ==
   sorted(os.path.join(C.item_dir(w.state, "final", r["label"]), "brief.md") for r in w.runs()))

# ---- idempotent: nothing moves without a new answer
before = snap(w.state)
go(w)
go(w, rounds=False)
after = snap(w.state)
ok("idempotent: run then match with no new answers changes no state file", before == after, [k for k in set(before) | set(after) if before.get(k) != after.get(k)])

# ---- the final review's answer needs its transcript, which must be found under --projects-dir
drive_none = drive(w, transcripts=False)
text = go(w)
ok("final_transcript_missing: with no transcript the final review is not accepted, and the run says why and how to point at one",
   all(r["step"] == "final" and r["reviews"] == [] for r in w.runs()) and "transcript" in text and "--transcript" in text, text)
before = snap(w.state)
go(w, rounds=False)
ok("final_transcript_missing: and waiting changes no state file", before == snap(w.state))
for r in w.runs():
    final_transcript(r["label"], prompt="Read {} and follow it.".format(os.path.join(C.item_dir(w.state, "final", r["label"]), "brief.md")))
go(w, rounds=False)
ok("transcript_lookup: a transcript whose first prompt holds the staged brief path (no id line) is found", all(r["step"] == "match" for r in w.runs()), [r["step"] for r in w.runs()])

# several transcripts match: none is picked; --transcript names one, and also stands in when the search finds none
w = World("transcripts")
behave(lambda run, k: ("approve", []))
go(w)
drive(w, transcripts=False)
t0, t1 = sorted(r["label"] for r in w.runs())
final_transcript(t0)
final_transcript(t0, key=KEY + "-b")
text = go(w, rounds=False)
ok("transcript_lookup: with two matching transcripts the run waits and says so, picking none",
   all(r["step"] == "final" for r in w.runs()) and "none is picked" in text and "--transcript {}=".format(t0) in text, text)
before = snap(w.state)
go(w, rounds=False)
ok("transcript_lookup: and waiting changes no state file", before == snap(w.state))
chosen = os.path.join(PROJECTS, KEY, "sess-" + t0, "subagents", "agent-%s.jsonl" % t0)
elsewhere = os.path.join(ROOT, "elsewhere-transcript.jsonl")
with open(elsewhere, "w") as f:
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "anything"}}) + "\n")
go(w, rounds=False, transcript=["%s=%s" % (t0, chosen), "%s=%s" % (t1, elsewhere)])
st = dict((r["label"], r) for r in w.runs())
ok("transcript_lookup: --transcript settles both: the one of several, and the one the search could not find",
   st[t0]["step"] == "match" and st[t1]["step"] == "match", [(r["label"], r["step"]) for r in st.values()])
w = World("transcripts2")
behave(lambda run, k: ("approve", []))
go(w)
drive(w, transcripts=False)
with open(elsewhere, "w") as f:
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "x"}}) + "\n"
            + json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "cat %s/src/a.py" % os.path.dirname(w.common)}}]}}) + "\n")
t0 = sorted(r["label"] for r in w.runs())[0]
go(w, rounds=False, transcript=["%s=%s" % (t0, elsewhere)])
ok("transcript_lookup: the transcript --transcript names is scanned for leaks like any other",
   [r for r in w.runs() if r["label"] == t0][0]["end"] == "void")
try:
    go(w, rounds=False, transcript=["nonsense"])
    got = "no error"
except Failed as e:
    got = str(e)
ok("transcript_lookup: a --transcript that is not ID=PATH is refused", "ID=PATH" in got, got)

# ================================================================== match_blind_shuffled, oracle_one_commit
w = World("match", cases=1)
behave(lambda run, k: ("changes", [F("dB")]) if k == 1 else ("approve", []))
settle_text = go(w)
drive(w, report=["found dA", "found dC"])
go(w, rounds=False)
inputs = []
for r in w.runs():
    doc = C.jload(os.path.join(w.state, "judge-match", "%s-0.json" % r["label"]))
    inputs.append(doc)
ok("match_blind_shuffled: the final review's judge-match is the report form", all(set(d) == {"defects", "report"} for d in inputs), [sorted(d) for d in inputs])
ok("match_blind_shuffled: it holds every present defect of both classes, fresh indices, no class",
   all(sorted(x["index"] for x in d["defects"]) == [0, 1, 2, 3] and sorted(x["summary"] for x in d["defects"]) == ["bug in dA", "bug in dB", "bug in dC", "bug in dD"]
       and all(set(x) == {"index", "summary", "file", "line", "failure_scenario"} for x in d["defects"]) for d in inputs), inputs[0])
ok("match_blind_shuffled: the report is the final review's answer", all("FINDING: found dA" in d["report"] for d in inputs))
ok("match_blind_shuffled: the order differs from the defects' own order (by id) in some input",
   any([x["summary"] for x in d["defects"]] != ["bug in dA", "bug in dB", "bug in dC", "bug in dD"] for d in inputs), inputs)
ok("match_blind_shuffled: the judge input carries no class, run, arm, label or purpose key anywhere",
   not re.search(r'"(class|run|arm|label|purpose)"', json.dumps(inputs)))
drive(w, report=["found dA", "found dC"])
text = go(w)
# the final review matched dA and dC (group gcd): one oracle commit, dD censored
runs = w.runs()
r = runs[0]
ok("oracle: the matched defects are recovered, the group-mate censored, the rest present",
   all(by_status(x) == {"dA": "recovered", "dB": "present", "dC": "recovered", "dD": "censored"} for x in runs), [by_status(x) for x in runs])
ok("oracle_one_commit: one commit named Address review findings above the scratch tip",
   all(git(x["scratch"], "log", "-1", "--format=%s") == "Address review findings" and git(x["scratch"], "rev-list", "--count", "HEAD~1..HEAD") == "1"
       and git(x["scratch"], "rev-parse", "HEAD~2") == w.base for x in runs))
ok("oracle_one_commit: its diff is the repairs of the matched defects: A's line, and the whole group's patch (both of its lines)",
   all(git(x["scratch"], "show", "HEAD:src/a.py").splitlines()[4] == "a5" and git(x["scratch"], "show", "HEAD:src/c.py").splitlines()[4] == "c5"
       and git(x["scratch"], "show", "HEAD:src/c.py").splitlines()[29] == "c30" and git(x["scratch"], "show", "HEAD:src/b.py").splitlines()[4] == "B_BUG"
       and git(x["scratch"], "diff", "--name-only", "HEAD~1", "HEAD").split() == ["src/a.py", "src/c.py"] for x in runs))
ok("oracle_one_commit: it is neutral (no operator identity, fixed author)", all(git(x["scratch"], "log", "-1", "--format=%an <%ae>") == "Developer <developer@example.invalid>" for x in runs))
ok("oracle: the run moved to Codex round 1, one per run", len(CALLS) == 2 and all(c["k"] == 1 for c in CALLS), CALLS)
ok("oracle: round 1 started from each scratch's repaired HEAD", sorted(c["tip"] for c in CALLS) == sorted(git(x["scratch"], "rev-parse", "HEAD") for x in runs))
ok("oracle: run state after the round waits at match with the review recorded", all(x["step"] == "match" and len(x["reviews"]) == 2 and x["round"] == 1 and x["tokens"] == 100
                                                                             and x["thread"] == "th-" + x["label"] for x in runs), runs[0])
ok("oracle: the final review's record", all(x["reviews"][0]["kind"] == "final" and x["reviews"][0]["id"] == x["label"] and x["reviews"][0]["k"] == 0
                                            and [f["summary"] for f in x["reviews"][0]["findings"]] == ["found dA", "found dC"] for x in runs), runs[0]["reviews"][0])
inp1 = C.jload(os.path.join(w.state, "judge-match", "%s-1.json" % runs[0]["label"]))
ok("match_blind_shuffled: round 1's input holds only the defects still present (dB), and its findings", [d["summary"] for d in inp1["defects"]] == ["bug in dB"]
   and [f["summary"] for f in inp1["findings"]] == ["found dB"], inp1)
ok("match_blind_shuffled: a Codex review's findings carry severity, file, line, summary and failure_scenario",
   set(inp1["findings"][0]) == {"index", "severity", "file", "line", "summary", "failure_scenario"})
settle(w, report=["found dA", "found dC"])
runs = w.runs()
ok("oracle: round 1 matched dB, whose repair was applied; round 2 approved: dD, censored before, stays censored",
   all(x["end"] == "approve" and by_status(x) == {"dA": "recovered", "dB": "recovered", "dC": "recovered", "dD": "censored"} for x in runs), [by_status(x) for x in runs])

# ================================================================== touched_revalidated
def touched_world(name, valid):
    w = World(name, ids=("dA", "dF", "dG", "dB"))
    behave(lambda run, k: ("changes", [F("dB")]) if k == 1 else ("approve", []))
    go(w)
    drive(w, report=["found dA"])
    go(w)
    drive(w, report=["found dA"])
    go(w)
    return w


w = touched_world("touch", "no")
r = w.runs()[0]
ok("touched_revalidated: the commit changes dF's hunk lines and its repair no longer applies: dF is touched, dG (same file, far away) is not",
   P.touched(r, git(r["scratch"], "rev-parse", "HEAD")) == ["dF"], P.touched(r, git(r["scratch"], "rev-parse", "HEAD")))
narrow = dict(r, repairs=dict(r["repairs"], dF=dict(r["repairs"]["dF"], hunks=[dict(r["repairs"]["dF"]["hunks"][0], start=8, end=8)])))
ok("touched_revalidated: a repair that no longer applies is touched even when the commit changed none of its recorded lines",
   P.touched(narrow, git(r["scratch"], "rev-parse", "HEAD")) == ["dF"], P.touched(narrow, git(r["scratch"], "rev-parse", "HEAD")))
inputs = sorted(os.listdir(os.path.join(w.state, "judge-present")))
ok("touched_revalidated: a judge-present is written for dF only, per run", sorted(i for i in inputs if i.endswith(".json") and not i.endswith(".answer.json")) ==
   sorted("%s-0-dF.json" % x["label"] for x in w.runs()), inputs)
doc = C.jload(os.path.join(w.state, "judge-present", "%s-0-dF.json" % r["label"]))
ok("touched_revalidated: its input is the finding and the files as the repaired tree has them",
   set(doc) == {"finding", "files"} and doc["finding"]["summary"] == "bug in dF" and set(doc["finding"]) == {"severity", "file", "line", "summary", "failure_scenario"}
   and [f["path"] for f in doc["files"]] == ["src/a.py"] and "a5\n" in doc["files"][0]["text"] and "A_BUG" not in doc["files"][0]["text"], doc)
ok("touched_revalidated: the run waits at valid, and no Codex round started",
   all(x["step"] == "valid" for x in w.runs()) and len(CALLS) == 0, [x["step"] for x in w.runs()])
drive(w, valid="no")
go(w)
ok("touched_revalidated: no -> dF censored; dG stays present; the loop moves on to round 1",
   all(x["defects"]["dF"] == "censored" and x["defects"]["dG"] == "present" and x["step"] == "match" for x in w.runs()), [by_status(x) for x in w.runs()])

w = touched_world("touch2", "yes")
drive(w, valid={"dF": "yes"})
go(w)
ok("touched_revalidated: yes -> dF stays present", all(x["defects"]["dF"] == "present" for x in w.runs()), [by_status(x) for x in w.runs()])
w = touched_world("touch3", "unclear")
drive(w, valid="unclear")
go(w)
ok("touched_revalidated: unclear -> censored", all(x["defects"]["dF"] == "censored" for x in w.runs()), [by_status(x) for x in w.runs()])

# lines are followed through earlier commits: K's repair inserts two lines, which moves L; M's change then sits beside L's hunk, not in it
w = World("shift", ids=("dK", "dL", "dM"))
behave(lambda run, k: ("approve", []))
go(w)
r = w.runs()[0]
tip0 = git(r["scratch"], "rev-parse", "HEAD")
c1 = P.oracle(r, ["dK"])
r["defects"]["dK"] = "recovered"
ok("touched: the first repair is one commit", git(r["scratch"], "rev-list", "--count", tip0 + ".." + c1) == "1" and git(r["scratch"], "log", "-1", "--format=%s", c1) == "Address review findings")
ok("touched: a repair inserting lines above does not touch dL or dM", P.touched(r, c1) == [], P.touched(r, c1))
c2 = P.oracle(r, ["dM"])
r["defects"]["dM"] = "recovered"
ok("touched: dM's repair, whose change sits at line 26 of the shifted file, is beside dL's hunk (lines 27-33 once shifted), not in it",
   P.touched(r, c2) == [], P.touched(r, c2))
ok("touched: sanity, the same coordinates unshifted would have claimed dL (hunk 25-31 holds line 26)", any(h["start"] <= 26 <= h["end"] for h in r["repairs"]["dL"]["hunks"]))

# ================================================================== endings
# approve: every present defect unrecovered
w = World("end-approve")
behave(lambda run, k: ("approve", []))
settle(w)
ok("endings: approve -> end approve, every present defect unrecovered", all(x["end"] == "approve" and set(x["defects"].values()) == {"unrecovered"} and x["step"] == "done"
                                                                         for x in w.runs()), [by_status(x) for x in w.runs()])
ok("endings: approve with no findings needs no judge", not [p for p in C.pending(w.state)])

# six Codex rounds
w = World("end-rounds")
behave(lambda run, k: ("changes", [F("dA")]) if k == 1 else ("changes", [F("dB")]) if k == 2 else ("changes", [OTHER("fp %d" % k)]))
settle(w)
runs = w.runs()
ok("endings: six Codex rounds -> end rounds, the rest unrecovered, the matched recovered, the group-mate censored",
   all(x["end"] == "rounds" and x["round"] == 6 and by_status(x) == {"dA": "recovered", "dB": "recovered", "dC": "unrecovered", "dD": "unrecovered"} for x in runs),
   [(x["end"], by_status(x)) for x in runs])
ok("endings: there were exactly six rounds per run", max(c["k"] for c in CALLS) == 6 and len([c for c in CALLS if c["label"] == runs[0]["label"]]) == 6)
ok("endings: tokens add up", all(x["tokens"] == 600 for x in runs), [x["tokens"] for x in runs])

# stalled: the final review
w = World("end-stall-final")
behave(lambda run, k: ("approve", []))
settle(w, report=["a real problem"], real=["a real problem"])
ok("endings: the final review with no match and a real ruling -> stalled, the present ones censored, no Codex round",
   all(x["end"] == "stalled" and set(x["defects"].values()) == {"censored"} and x["reviews"][0]["kind"] == "final" for x in w.runs()) and not CALLS,
   [(x["end"], by_status(x)) for x in w.runs()])
ok("endings: the real defect outside the inventory is recorded", all(x["outside"] == ["a real problem"] for x in w.runs()), w.runs()[0]["outside"])

# stalled: Codex round 1, and a later one
w = World("end-stall-1")
behave(lambda run, k: ("changes", [OTHER("outside defect")]))
settle(w, real=["outside defect"])
ok("endings: a Codex round with no match and a real ruling -> stalled", all(x["end"] == "stalled" and set(x["defects"].values()) == {"censored"} and x["round"] == 1 for x in w.runs()),
   [(x["end"], x["round"], by_status(x)) for x in w.runs()])
ok("endings: the outside defect is named by its identifier", all(x["outside"] == ["src/z.py:3 outside defect"] for x in w.runs()), w.runs()[0]["outside"])

w = World("end-stall-2")
behave(lambda run, k: ("changes", [F("dA")]) if k == 1 else ("changes", [OTHER("outside defect")]))
settle(w, real=["outside defect"])
ok("endings: a later Codex round stalls too, and only the defects still present are censored",
   all(x["end"] == "stalled" and x["round"] == 2 and by_status(x) == {"dA": "recovered", "dB": "censored", "dC": "censored", "dD": "censored"} for x in w.runs()),
   [(x["end"], x["round"], by_status(x)) for x in w.runs()])

# a match and a real ruling together: no stall, the loop goes on
w = World("end-nostall")
behave(lambda run, k: ("changes", [F("dA"), OTHER("outside defect")]) if k == 1 else ("approve", []))
settle(w, real=["outside defect"])
ok("endings: a round that matches a defect and also reports a real one does not stall", all(x["end"] == "approve" and x["round"] == 2 for x in w.runs()),
   [(x["end"], x["round"]) for x in w.runs()])

# a false positive alone does not stall either, and is carried
w = World("rejected")
behave(lambda run, k: ("changes", [F("dA"), OTHER("bogus claim")]) if k == 1 else ("changes", [OTHER("another bogus")]) if k == 2 else ("approve", []))
settle(w)
c2 = [c for c in CALLS if c["k"] == 2][0]
c3 = [c for c in CALLS if c["k"] == 3][0]
ok("rejected_carried: the false positive of round 1 reaches round 2's run state, and the matched finding is addressed",
   c2["rejected"] == ["src/z.py:3 bogus claim"] and c2["addressed"] == ["src/a.py:5 found dA"], c2)
ok("rejected_carried: rejections accumulate, and the addressed list is the previous review's", c3["rejected"] == ["src/z.py:3 bogus claim", "src/z.py:3 another bogus"] and c3["addressed"] == [], c3)
ok("rejected_carried: the run then ended at approve in round 3", all(x["end"] == "approve" and x["round"] == 3 for x in w.runs()))

# approve with only P3 findings, line null, paths a/x and ./x
w = World("p3")
behave(lambda run, k: ("approve", [dict(F("dA", "P3"), line=None, file="a/src/a.py", summary="style nit"), dict(F("dB", "P3"), file="./src/b.py", summary="docs nit")]))
go(w)
drive(w)
go(w)
drive(w)
go(w)
inp = C.jload(os.path.join(w.state, "judge-match", "%s-1.json" % w.runs()[0]["label"]))
ok("path_normalized: line null and the paths a/x and ./x reach the judge as x",
   [(f["file"], f["line"]) for f in inp["findings"]] == [("src/a.py", None), ("src/b.py", 5)], inp["findings"])
ok("approve_p3_only: the review waits for the judge as for any findings", all(x["step"] == "match" for x in w.runs()))
drive(w, real=["style nit", "docs nit"])
go(w)
ok("approve_p3_only: approve with only P3 findings ends the run at approve even when the judge calls them real",
   all(x["end"] == "approve" and set(x["defects"].values()) == {"unrecovered"} for x in w.runs()), [(x["end"], by_status(x)) for x in w.runs()])

# approve with a match: the matched defect counts as recovered
w = World("approve-match")
behave(lambda run, k: ("approve", [F("dA", "P3")]))
settle(w)
ok("endings: a defect matched by the approving review is recovered, the others unrecovered",
   all(x["end"] == "approve" and by_status(x) == {"dA": "recovered", "dB": "unrecovered", "dC": "unrecovered", "dD": "unrecovered"} for x in w.runs()), [by_status(x) for x in w.runs()])

# ================================================================== leaks
w = World("void")
behave(lambda run, k: ("approve", []))
go(w)
drive(w)
first = sorted(r["label"] for r in w.runs())[0]
LEAK = {"leak": ["%s in tu1" % w.common], "tokens": 50, "thread": "th", "turns": [["th", "tu1"]]}
behave(lambda run, k: LEAK if run["label"] == first else ("approve", []))
go(w)
drive(w)
del PREP[:]
text = go(w)
runs = w.runs()
old = [r for r in runs if r["label"] == first][0]
new = [r for r in runs if r.get("replaces") == first]
ok("void_once_more: a leak voids the run, which records the replacement", old["end"] == "void" and old["voids"] == 1 and len(new) == 1 and old["replaced_by"] == new[0]["label"]
   and old["tokens"] == 50 and old["leak"] == ["%s in tu1" % w.common], old)
ok("void_once_more: the replacement is a fresh run under a new label and scratch, back at the final review",
   new[0]["step"] == "final" and new[0]["scratch"] != old["scratch"] and os.path.isdir(new[0]["scratch"]) and new[0]["voids"] == 1 and new[0]["reviews"] == []
   and set(new[0]["defects"].values()) == {"present"} and os.path.isfile(os.path.join(w.state, "final", new[0]["label"], "brief.md")), new)
ok("void_once_more: its ledger was prepared when no replay home was active", PREP and all(n == 0 for _l, n in PREP) and PREP[0][0] == new[0]["label"], PREP)
ok("void_once_more: the other run is unaffected, and the case has three runs in all", len(runs) == 3 and [r for r in runs if r["label"] not in (first, new[0]["label"])][0]["end"] != "void")
settle(w)
new = [r for r in w.runs() if r.get("replaces") == first][0]
ok("void_once_more: the replacement runs the whole path, and a case ends with two runs that count", new["end"] == "approve" and len([r for r in w.live()]) == 2, new["end"])

w = World("void2")
behave(lambda run, k: ("approve", []))
go(w)
drive(w)
first = sorted(r["label"] for r in w.runs())[0]
LEAK = {"leak": ["%s in tu1" % w.common], "tokens": 50, "thread": "th", "turns": [["th", "tu1"]]}
behave(lambda run, k: LEAK if (run["label"] == first or run.get("replaces") == first) else ("approve", []))
settle(w)
new = [r for r in w.runs() if r.get("replaces") == first][0]
ok("void_once_more: a second leak ends the replacement void for good, with no third run", new["end"] == "void" and new["voids"] == 2 and "replaced_by" not in new and len(w.runs()) == 3, new)
go(w)
ok("void_once_more: and that is final", len(w.runs()) == 3)

# a leak in the final reviewer's transcript counts the same
w = World("void-final")
behave(lambda run, k: ("approve", []))
go(w)
first = sorted(r["label"] for r in w.runs())[0]
drive(w, transcripts=False)
for r in w.runs():
    final_transcript(r["label"], commands=["git -C {} show HEAD".format(os.path.dirname(w.common))] if r["label"] == first else ["git show HEAD"])
text = go(w)
runs = w.runs()
old = [r for r in runs if r["label"] == first][0]
ok("void_once_more: a leak in the final reviewer's transcript voids the run, as a Codex leak does",
   old["end"] == "void" and old["voids"] == 1 and any(l.startswith(os.path.dirname(w.common)) for l in old["leak"]) and len([r for r in runs if r.get("replaces") == first]) == 1 and old["reviews"] == [], old)
ok("void_once_more: no judge-match was opened for the voided final review", not os.path.exists(os.path.join(w.state, "judge-match", first + "-0.json")))
clean = [r for r in runs if r["label"] not in (first,) and r.get("replaces") != first][0]
ok("void_once_more: the clean transcript's run goes on", clean["step"] == "match" and len(clean["reviews"]) == 1, clean["step"])

# the matcher is codex.py's: reads through Read/Grep/Glob paths count, a path elsewhere does not
w = World("void-tools")
behave(lambda run, k: ("approve", []))
go(w)
labs = sorted(r["label"] for r in w.runs())
drive(w, transcripts=False)
for lab in labs:
    entries = [{"type": "user", "message": {"role": "user", "content": "Review id: %s\n" % lab}}]
    path = {labs[0]: os.path.join(os.path.dirname(w.common), "src", "a.py"), labs[1]: os.path.join(os.path.dirname(os.path.dirname(w.common)), "elsewhere", "x.py")}[lab]
    entries.append({"type": "assistant", "cwd": os.path.dirname(w.common), "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": path}}]}})
    helpers.write_transcript(PROJECTS, KEY + "-sub", "sess-" + lab, [], subagents=[{"id": lab, "meta": {}, "entries": entries}])
go(w, rounds=False)
st = dict((r["label"], r) for r in w.runs())
ok("void_once_more: a Read of a file in the original checkout is a leak", st[labs[0]]["end"] == "void", st[labs[0]]["leak"] if "leak" in st[labs[0]] else st[labs[0]]["step"])
ok("void_once_more: a Read elsewhere is not, and project dirs that merely start with the key are searched", st[labs[1]]["end"] is None and st[labs[1]]["step"] == "match")

# a judge answer that does not fit its input is reported and not used, never halts the command, and does not strand the run:
# it is set aside and the judge-match is pending again in its staged directory, where the judge answers anew
w = World("badanswer")
behave(lambda run, k: ("approve", []))
to_codex(w)
behave(lambda run, k: ("changes", [F("dA")]))
go(w)
r = sorted(w.runs(), key=lambda x: x["label"])[0]
jid = "%s-1" % r["label"]
staged = os.path.dirname([p[4] for p in C.pending(w.state) if p[1] == jid][0])
C.jsave(os.path.join(staged, "answer.json"), {"matches": [{"defect": 0, "finding": 5}], "unmatched": []})
text = go(w, rounds=False)
ok("bad_answer: a match naming a finding the input does not have is reported and not used", "finding 5" in text and "not used" in text and "pending again" in text, text)
ok("bad_answer: the bad answer is set aside, not left as the answer", not os.path.exists(os.path.join(w.state, "judge-match", jid + ".answer.json"))
   and C.jload(os.path.join(w.state, "judge-match", jid + ".rejected-1.answer.json")) == {"matches": [{"defect": 0, "finding": 5}], "unmatched": []})
ok("bad_answer: the judge-match is pending again, in its staged directory, and the run keeps waiting",
   [(p[1], os.path.dirname(p[4])) for p in C.pending(w.state) if p[1] == jid] == [(jid, staged)] and dict((x["label"], x) for x in w.runs())[r["label"]]["step"] == "match")
before = snap(w.state)
go(w, rounds=False)
ok("bad_answer: and waiting for the new answer changes no state file", before == snap(w.state))
inp = C.jload(os.path.join(w.state, "judge-match", jid + ".json"))
C.jsave(os.path.join(staged, "answer.json"), {"matches": [{"defect": [d["index"] for d in inp["defects"] if d["summary"] == "bug in dA"][0], "finding": 0}], "unmatched": []})
go(w, rounds=False)
st = dict((x["label"], x) for x in w.runs())
ok("bad_answer: the judge's second answer, written in the staged directory, is applied", st[r["label"]]["defects"]["dA"] == "recovered" and st[r["label"]]["step"] == "codex",
   (st[r["label"]]["step"], st[r["label"]]["defects"]))
other = [x for l, x in st.items() if l != r["label"]][0]
C.jsave(os.path.join(w.state, "judge-match", "%s-1.answer.json" % other["label"]), {"matches": [{"defect": 9, "finding": 0}], "unmatched": []})
text = go(w, rounds=False)
ok("bad_answer: an answer put straight into the state is set aside the same way, naming the defect it got wrong", "names defect 9" in text and
   os.path.exists(os.path.join(w.state, "judge-match", "%s-1.rejected-1.answer.json" % other["label"])), text)

# a final review's findings are taken by their own index; one out of range spoils that review only
w = World("badindex")
behave(lambda run, k: ("approve", []))
go(w)
drive(w, report=["found dA", "found dB"])
go(w, rounds=False)
runs = sorted(w.runs(), key=lambda x: x["label"])
for r, idx in zip(runs, ([1, 0], [0, 7])):
    C.jsave(os.path.join(w.state, "judge-match", "%s-0.answer.json" % r["label"]),
            {"findings": [{"index": idx[0], "summary": "second claim"}, {"index": idx[1], "summary": "first claim"}], "matches": [], "unmatched": []})
text = go(w, rounds=False)
st = dict((x["label"], x) for x in w.runs())
ok("final_findings: the judge's own indices order the findings (not their position in the list)",
   [f["summary"] for f in st[runs[0]["label"]]["reviews"][0]["findings"]] == ["first claim", "second claim"], st[runs[0]["label"]]["reviews"])
ok("final_findings: an index out of range spoils that review only, is reported, and halts nothing",
   st[runs[1]["label"]]["step"] == "match" and st[runs[1]["label"]]["reviews"][0]["findings"] == [] and "not used" in text and "out of range" in text, text)

# a finding a match uses is not also an outside defect
w = World("usedreal")
behave(lambda run, k: ("changes", [F("dA")]) if k == 1 else ("approve", []))
go(w)
drive(w)
go(w, rounds=False)
for r in w.runs():
    inp = C.jload(os.path.join(w.state, "judge-match", "%s-0.json" % r["label"]))
    C.jsave(os.path.join(w.state, "judge-match", "%s-0.answer.json" % r["label"]), {"findings": [{"index": 0, "summary": "claim"}],
            "matches": [{"defect": d["index"], "finding": 0} for d in inp["defects"] if d["summary"] == "bug in dA"], "unmatched": [{"finding": 0, "ruling": "real"}]})
go(w)
ok("used_finding_not_outside: a finding some match uses is neither outside nor rejected, whatever the judge also ruled on it",
   all(x["outside"] == [] and x["rejected"] == [] and x["defects"]["dA"] == "recovered" for x in w.runs()), [(x["outside"], x["rejected"]) for x in w.runs()])

# ================================================================== two commands at once
# a second `run` refuses while one holds run.lock
w = World("lock")
behave(lambda run, k: ("approve", []))
go(w)
held = os.open(os.path.join(w.state, "run.lock"), os.O_RDWR | os.O_CREAT)
fcntl.flock(held, fcntl.LOCK_EX)
try:
    go(w)
    got = "no error"
except Failed as e:
    got = str(e)
ok("run_lock: a second run refuses while another holds run.lock, and says which", "run.lock" in got and "another" in got, got)
text = go(w, rounds=False)
ok("run_lock: match is not stopped by it", "waits at final" in text, text)
fcntl.flock(held, fcntl.LOCK_UN)
os.close(held)
go(w)

# match never creates runs: only the run that holds run.lock does
w = World("nocreate")
go(w, rounds=False)
ok("run_lock: match creates no run", not os.path.exists(os.path.join(w.state, "runs")))

# a run whose Codex round is in flight holds its lock: run refuses a second run and match skips the busy run
w = World("busy")
behave(lambda run, k: ("approve", []))
to_codex(w)
INNER = []


def inside(run, k):
    if run["label"] != sorted(r["label"] for r in w.runs())[0]:
        return ("approve", [])
    try:
        go(w)
        INNER.append("no error")
    except Failed as e:
        INNER.append(str(e))
    INNER.append(go(w, rounds=False))
    return ("approve", [])


behave(inside)
go(w)
ok("run_lock: a run started while another is running refuses", INNER[0].startswith("another `run` holds"), INNER)
ok("busy: match skips a run whose round is in flight, and says so", "busy" in INNER[1], INNER[1:])
ok("busy: and the round finished normally", all(x["end"] == "approve" for x in w.runs()))

# the reviewer's sequence: run loads its runs, match applies an answer in between, run goes on: no second oracle, no lost state
w = World("interleave")
behave(lambda run, k: ("approve", []))
go(w)
drive(w, report=["found dA"])
go(w, rounds=False)
drive(w, report=["found dA"])
real_ensure = P.ensure_runs
seen = []


def interleaved(ctx, runs):
    if not seen:
        seen.append(1)
        go(w, rounds=False)
    return real_ensure(ctx, runs)


P.ensure_runs = interleaved
go(w)
P.ensure_runs = real_ensure
ok("interleave: match ran between run's load and its first step", seen == [1])
runs = w.runs()
ok("interleave: one oracle commit per scratch, not two", all(git(x["scratch"], "rev-list", "--count", x["base_tip"] + "..HEAD") == "1" for x in runs),
   [git(x["scratch"], "log", "--format=%s", x["base_tip"] + "..HEAD") for x in runs])
ok("interleave: no run ended in error, no review twice, dA recovered once", all(x["end"] == "approve" and x["defects"]["dA"] == "recovered"
                                                                          and [r["kind"] for r in x["reviews"]] == ["final", "codex"] for x in runs), [(x["end"], x.get("error")) for x in runs])

# two same-file defects matched in one review: the repairs go on one after another, and the second with --3way
w = World("samefile", ids=("dA", "dF", "dG", "dB"))
behave(lambda run, k: ("approve", []))
go(w)
drive(w, report=["found dA", "found dF"])
go(w, rounds=False)
drive(w, report=["found dA", "found dF"])
go(w, rounds=False)
runs = w.runs()
ok("oracle_same_file: dA (line 5) and dF (line 8) overlap in context, and both are repaired in one commit",
   all(x["defects"]["dA"] == "recovered" and x["defects"]["dF"] == "recovered" and x["end"] is None and x["step"] == "codex"
       and git(x["scratch"], "rev-list", "--count", x["base_tip"] + "..HEAD") == "1"
       and git(x["scratch"], "show", "HEAD:src/a.py").splitlines()[4] == "a5" and git(x["scratch"], "show", "HEAD:src/a.py").splitlines()[7] == "a8"
       and git(x["scratch"], "show", "HEAD:src/a.py").splitlines()[24] == "G_BUG" for x in runs), [(x["end"], x.get("error"), x["defects"]) for x in runs])
ok("oracle_same_file: the commit is the one named Address review findings", all(git(x["scratch"], "log", "-1", "--format=%s") == "Address review findings" for x in runs))

# one round's exception does not discard another's result
for name, exc in (("failed", Failed("cannot open a thread")), ("keyerror", KeyError("surprise"))):
    w = World("mixed-" + name, cases=1)
    behave(lambda run, k: ("approve", []))
    to_codex(w)
    first = sorted(r["label"] for r in w.runs())[0]
    behave(lambda run, k, exc=exc: exc if run["label"] == first else ("changes", [OTHER("x")]))
    text = go(w)
    st = dict((x["label"], x) for x in w.runs())
    other = [x for x in st.values() if x["label"] != first][0]
    ok("round_errors: a round raising {} fails that run's round (retry once), not the command".format(type(exc).__name__),
       st[first]["failures"] == 1 and st[first]["step"] == "codex" and st[first]["end"] is None and "the round failed (1/2)" in text, text)
    ok("round_errors: and the other run's result was applied and saved", len(other["reviews"]) == 2 and other["reviews"][1]["kind"] == "codex" and other["tokens"] == 100
       and other["step"] == "match", (other["step"], other["tokens"]))

# a failed build leaves no scratch, and a crash that does is found by cleanup
w = World("orphan")
real_build = scratch.build


def failing_build(objects, base, files, out, *args, **kw):
    os.makedirs(out)
    put(out, "half", "x")
    raise Failed("the build broke")


scratch.build = failing_build
try:
    go(w)
    got = "no error"
except Failed as e:
    got = str(e)
scratch.build = real_build
orphans = [os.path.join(os.environ["XDG_STATE_HOME"], "review-work", "scratch", d) for d in os.listdir(os.path.join(os.environ["XDG_STATE_HOME"], "review-work", "scratch"))] \
    if os.path.isdir(os.path.join(os.environ["XDG_STATE_HOME"], "review-work", "scratch")) else []
recorded = [C.jload(os.path.join(d, f))["scratch"] for d, _x, fs in os.walk(os.path.join(w.state, "runs")) for f in fs if f == "scratch.json"]
ok("orphan_scratch: a failed build is reported, and removes what it left", "build broke" in got and recorded and not any(os.path.exists(r) for r in recorded), (got, recorded))
crashed = os.path.join(os.environ["XDG_STATE_HOME"], "review-work", "scratch", "feedface")
put(crashed, "half", "x")
C.jsave(os.path.join(w.state, "runs", w.case_ids[0], "feedface", "scratch.json"), {"scratch": crashed})
with contextlib.redirect_stdout(io.StringIO()):
    P.cmd_cleanup(w.args())
ok("orphan_scratch: cleanup removes a scratch recorded before a crash, though no run state names it", not os.path.exists(crashed))

# a final reviewer that reads the state directory voids its run
w = World("void-state")
behave(lambda run, k: ("approve", []))
go(w)
first = sorted(r["label"] for r in w.runs())[0]
drive(w, transcripts=False)
for r in w.runs():
    final_transcript(r["label"], commands=["ls {}/inventory".format(w.state)] if r["label"] == first else ["git show HEAD"])
go(w)
st = dict((x["label"], x) for x in w.runs())
ok("void_once_more: a final reviewer reading the state directory is a leak", st[first]["end"] == "void" and st[first]["replaced_by"], st[first].get("leak"))
ok("void_once_more: and the other reviewer is not", all(x["end"] is None for l, x in st.items() if l != first and not x.get("replaces")))

# a lock descriptor is closed once: a second close could be another file's
w = World("fds")
behave(lambda run, k: ("approve", []))
to_codex(w)
live, bad = set(), []
real_lock, real_unlock = P._lock, P._unlock


def spy_lock(path):
    fd = real_lock(path)
    if fd is not None:
        live.add(fd)
    return fd


def spy_unlock(fd):
    if fd is not None:
        if fd not in live:
            bad.append(fd)
        live.discard(fd)
    return real_unlock(fd)


P._lock, P._unlock = spy_lock, spy_unlock
go(w)
P._lock, P._unlock = real_lock, real_unlock
ok("lock_fds: each lock descriptor is released once, and none is left held", bad == [] and live == set() and len(CALLS) == 2, (bad, live))

# an oracle commit that fails ends the run error instead of crashing every later match
w = World("commitfail")
behave(lambda run, k: ("approve", []))
go(w)
drive(w, report=["found dA"])
go(w, rounds=False)
drive(w, report=["found dA"])
P.COMMIT = ""
try:
    text = go(w, rounds=False)
    got = None
except Failed as e:
    got = str(e)
finally:
    P.COMMIT = "Address review findings"
ok("commit_fails: a repair that applies but cannot be committed does not raise out of the command", got is None, got)
ok("commit_fails: the run ends error, saying what failed, with the tree as it was",
   all(x["end"] == "error" and "not committed" in x["error"] and git(x["scratch"], "status", "--porcelain") == ""
       and git(x["scratch"], "rev-list", "--count", x["base_tip"] + "..HEAD") == "0" for x in w.runs()), [(x["end"], x.get("error")) for x in w.runs()])
go(w, rounds=False)

# a reset that fails after a failed commit does not hide why the commit failed
w = World("commitfail2")
behave(lambda run, k: ("approve", []))
go(w)
drive(w, report=["found dA"])
go(w, rounds=False)
drive(w, report=["found dA"])
real_git = C.git


def no_reset(gitdir, *args, **kw):
    if "reset" in args:
        raise Failed("git reset failed (128): cannot lock the index")
    return real_git(gitdir, *args, **kw)


P.COMMIT = ""
C.git = no_reset
try:
    go(w, rounds=False)
finally:
    C.git = real_git
    P.COMMIT = "Address review findings"
ok("commit_fails_reset_fails: the run's error names the commit failure and the failed reset",
   all(x["end"] == "error" and "not committed" in x["error"] and "empty commit message" in x["error"].lower() and "cannot lock the index" in x["error"]
       for x in w.runs()), [(x["end"], x.get("error")) for x in w.runs()])

# ================================================================== repair_fails
def set_repair(w, did, text):
    """Replace the repair each run of `w` holds (its own copy)."""
    for x in w.runs():
        with open(x["repairs"][did]["repair"], "w") as f:
            f.write(text)


w = World("repair-fails")
behave(lambda run, k: ("approve", []))
go(w)
set_repair(w, "dA", w.patches["dA"].replace("a3", "not the line"))
drive(w, report=["found dA"])
go(w)
drive(w, report=["found dA"])
text = go(w)
ok("repair_fails: a repair that no longer applies ends the run error, and names the defect", all(x["end"] == "error" and "dA" in x["error"] for x in w.runs()), [(x["end"], x.get("error")) for x in w.runs()])
ok("repair_fails: the tree is unchanged by the failed repair", all(git(x["scratch"], "status", "--porcelain") == "" and git(x["scratch"], "rev-list", "--count", w.base + "..HEAD") == "1" for x in w.runs()))
ok("repair_fails: and no Codex round was started", not CALLS)

# a run applies the repair it started with: inject rewrites and deletes repairs/<defect>.patch whenever it settles the branch again
w = World("repair-own")
behave(lambda run, k: ("approve", []))
go(w)
ok("repair_copy: each run holds its own copy of every repair, under its own directory", all(
    r["repairs"][d]["repair"] == os.path.join(w.state, "runs", r["case"], r["label"], "repairs", d + ".patch") and open(r["repairs"][d]["repair"]).read() == w.patches[d]
    for r in w.runs() for d in r["repairs"]), [r["repairs"]["dA"] for r in w.runs()])
with open(os.path.join(w.state, "repairs", "dA.patch"), "w") as f:
    f.write(w.patches["dA"].replace("a3", "not the line"))
os.unlink(os.path.join(w.state, "repairs", "dC.patch"))
drive(w, report=["found dA", "found dC"])
go(w)
drive(w, report=["found dA", "found dC"])
go(w)
ok("repair_copy: rewriting or deleting repairs/<defect>.patch after the run began changes what its oracle applies",
   all(x["end"] != "error" and by_status(x)["dA"] == "recovered" and by_status(x)["dC"] == "recovered"
       and git(x["scratch"], "show", "HEAD:src/a.py").splitlines()[4] == "a5" for x in w.runs()), [(x["end"], x.get("error"), by_status(x)) for x in w.runs()])

# ... an empty repair is the third site
w = World("repair-empty")
behave(lambda run, k: ("approve", []))
go(w)
set_repair(w, "dA", "")
drive(w, report=["found dA"])
go(w)
drive(w, report=["found dA"])
go(w)
ok("repair_empty: an empty repair ends the run error, naming the defect, with the tree unchanged",
   all(x["end"] == "error" and "dA is empty" in x["error"] and git(x["scratch"], "status", "--porcelain") == "" for x in w.runs()), [(x["end"], x.get("error")) for x in w.runs()])
w = World("repair-empty2")
behave(lambda run, k: ("approve", []))
go(w)
set_repair(w, "dA", "")
drive(w, report=["found dA"])
go(w)
drive(w, report=["found dA"])
C.git = no_reset
try:
    go(w)
finally:
    C.git = real_git
ok("repair_empty_reset_fails: and when the reset fails too, the error still names the empty repair, and the reset",
   all(x["end"] == "error" and "dA is empty" in x["error"] and "cannot lock the index" in x["error"] for x in w.runs()), [(x["end"], x.get("error")) for x in w.runs()])

# ... nor does it hide why a repair would not apply
w = World("repair-fails2")
behave(lambda run, k: ("approve", []))
go(w)
set_repair(w, "dA", w.patches["dA"].replace("a3", "not the line"))
drive(w, report=["found dA"])
go(w)
drive(w, report=["found dA"])
C.git = no_reset
try:
    go(w)
finally:
    C.git = real_git
ok("repair_fails_reset_fails: the run's error names the defect whose repair did not apply and the failed reset",
   all(x["end"] == "error" and "dA" in x["error"] and "does not apply" in x["error"] and "cannot lock the index" in x["error"] for x in w.runs()),
   [(x["end"], x.get("error")) for x in w.runs()])

# ================================================================== the turn limits, pause, stop, failures
w = World("many", cases=3)
behave(lambda run, k: ("approve", []))
go(w)
drive(w)
go(w)
drive(w)
behave(lambda run, k: ("approve", []), delay=0.15)
go(w)
ok("turns: six runs all ran a round", len(CALLS) == 6, len(CALLS))
ok("turns: never more than three Codex turns at once, and three at once were used", INFLIGHT["max"] == 3, INFLIGHT)
ok("turns: every round was handed the replay home", all(c["home"] == NOMEM for c in CALLS), CALLS[0])

w = World("pause")
behave(lambda run, k: ("approve", []))
to_codex(w)
before = snap(w.state)
behave(lambda run, k: {"paused": "the weekly window is at 90%, resets_at 1893456000", "resets_at": 1893456000})
text = go(w)
ok("pause: a paused round changes no state file, and the run says so", before == snap(w.state) and "paused" in text and "resets_at" in text, text)
behave(lambda run, k: {"stopped": "the Codex token stop: 5 tokens spent, stop at 5"})
text = go(w)
ok("stop: a token stop changes no state file either, and is reported", before == snap(w.state) and "token stop" in text, text)

w = World("fail")
behave(lambda run, k: ("approve", []))
to_codex(w)
behave(lambda run, k: K.RoundFailed("the turn failed", tokens=7, thread="th-x"))
text = go(w)
runs = w.runs()
ok("failure: a failed round keeps the run at the Codex step with its tokens counted, and says why",
   all(x["end"] is None and x["step"] == "codex" and x["tokens"] == 7 and x["failures"] == 1 and x["reviews"][-1]["kind"] == "final" for x in runs) and "the turn failed" in text, text)
text = go(w)
ok("failure: a second failure in a row ends the run error", all(x["end"] == "error" and x["tokens"] == 14 and "the turn failed" in x["error"] for x in w.runs()), [(x["end"], x["tokens"]) for x in w.runs()])
w = World("fail2")
n = {"c": 0}
to_codex(w)
behave(lambda run, k: K.RoundFailed("flaky", tokens=1) if CALLS and len(CALLS) <= 2 else ("approve", []))
go(w)
go(w)
ok("failure: a round that works after one failure clears the count", all(x["end"] == "approve" and x["failures"] == 0 for x in w.runs()), [(x["end"], x.get("failures")) for x in w.runs()])

w = World("leak-failed")
to_codex(w)
err = K.RoundFailed("turn broke", tokens=3)
err.leak = ["%s in tu1" % w.common]
behave(lambda run, k: err)
go(w)
ok("void_once_more: a failed round whose scan found a leak is a leak", all(x["end"] == "void" and x["tokens"] == 3 for x in w.runs() if x["voids"] == 1 and x["end"] == "void") and any(x["end"] == "void" for x in w.runs()),
   [(x["end"], x["voids"]) for x in w.runs()])

# the token stop counts in codex_round; a run state carries every key a later task reads
w = World("keys")
behave(lambda run, k: ("changes", [F("dA")]) if k == 1 else ("approve", []))
settle(w, report=["found dB"])
r = w.runs()[0]
ok("run state: the shared keys are all there", all(k in r for k in ("case", "label", "scratch", "thread", "round", "step", "reviews", "defects", "rejected", "addressed", "outside", "ledger",
                                                                     "end", "voids", "tokens")), sorted(r))
ok("run state: every review has its shared keys", all(all(k in rv for k in ("id", "kind", "k", "findings", "verdict", "tokens", "turns", "model", "effort")) for rv in r["reviews"]), r["reviews"])
ok("run state: the Codex reviews keep the model and effort; the verdicts are recorded", [rv["verdict"] for rv in r["reviews"]] == ["report", "changes", "approve"]
   and r["reviews"][1]["model"] == "m-1" and r["reviews"][1]["effort"] == "high")
ok("run state: the decision of a round is not copied into the state (it is in the run's directory)", all("decision" not in rv for rv in r["reviews"]))

# ================================================================== no daemon, no home
w = World("nohome")
behave(lambda run, k: ("approve", []))
to_codex(w)
os.unlink(os.path.join(NOMEM, "replay-home.json"))
try:
    go(w)
    got = "no error"
except Failed as e:
    got = str(e)
ok("home: without the replay home, run says to make it and starts no round", "home" in got and not CALLS, got)
helpers.put(NOMEM, "replay-home.json", json.dumps({"source": "x"}))
P.codexhome.alive = lambda home: True
for label, record in (("never probed", None), ("last probe failed", {"at": "2026-11-03T00:00:00Z", "ok": False, "checks": {"memories": False}})):
    if record is None:
        PROBE_FILE = os.path.join(NOMEM, "probe.json")
        if os.path.exists(PROBE_FILE):
            os.unlink(PROBE_FILE)
    else:
        helpers.put(NOMEM, "probe.json", json.dumps(record))
    try:
        go(w)
        got = "no error"
    except Failed as e:
        got = str(e)
    ok("probe: a home that was {} is refused, naming the probe, and starts no round".format(label), "probe" in got and not CALLS, got)
helpers.put(NOMEM, "probe.json", json.dumps({"at": "2026-11-03T00:00:00Z", "ok": True, "checks": {"daemon": True}, "expect_memories": False}))
P.codexhome.alive = lambda home: False
try:
    go(w)
    got = "no error"
except Failed as e:
    got = str(e)
ok("home: with its daemon not running, run says so and starts no round", "daemon" in got and not CALLS, got)
P.codexhome.alive = lambda home: True

# ---- the run holds the replay home's lock while it uses the daemon, so nothing reclaims or restarts it mid-run
CHILD = r"""
import os, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from process_replay import codexhome as H
from process_replay.common import Failed
for label, fn, arg in (("reclaim", H.reclaim, sys.argv[2]), ("start", H.start, sys.argv[3])):
    try:
        fn(arg)
        print(label, "went ahead", flush=True)
    except Failed:
        print(label, "refused", flush=True)
"""
OTHER_HOME = os.path.join(os.environ["XDG_STATE_HOME"], "cxh", "other")
helpers.put(OTHER_HOME, "replay-home.json", json.dumps({"source": "x"}))
helpers.put(NOMEM, "app-server-control/app-server-control.sock", "")
UP = helpers.stub_rpc(os.path.join(ROOT, "rpc-up"), ROOT, {"health_rc": 0})
DAEMON = helpers.stub_codex(os.path.join(ROOT, "fake-codex"))
HELD = {"out": None, "held": None}


def asks_child(run, k):
    if HELD["out"] is None:
        HELD["held"] = P.codexhome._HELD["home"] == NOMEM
        HELD["out"] = subprocess.run(["/usr/bin/python3", "-I", "-B", "-c", CHILD, helpers.SCRIPTS, NOMEM, OTHER_HOME], capture_output=True, text=True,
                                     env=dict(os.environ, XREVIEW_REPLAY_RPC=UP, CODEX_REAL_BIN=DAEMON)).stdout.split()
    return ("approve", [])


wh = World("holds")
behave(asks_child)
to_codex(wh)
go(wh)
is_("home_lock: while a run uses the replay daemon, a reclaim of it and a start of another home in another process both refuse",
    HELD["out"], ["reclaim", "refused", "start", "refused"])
ok("home_lock: the run held the lock for the home it drove", HELD["held"] is True)
ok("home_lock: and let it go when it ended", P.codexhome._HELD["fd"] is None and P.codexhome._HELD["home"] is None, P.codexhome._HELD)
os.unlink(os.path.join(NOMEM, "app-server-control", "app-server-control.sock"))
behave(lambda run, k: ("approve", []))

before = snap(w.state)
text = go(w, rounds=False)
ok("match: match never starts a Codex round, and does not need the home", not CALLS and before == snap(w.state))

# ================================================================== dry run and missing records
w = World("dry")
behave(lambda run, k: ("approve", []))
before = snap(w.state)
go(w, dry_run=True)
ok("dry_run: writes nothing, starts nothing", before == snap(w.state) and not CALLS and not os.path.exists(os.path.join(w.state, "runs")))
os.unlink(os.path.join(w.state, "cases.json"))
try:
    go(w)
    got = "no error"
except Failed as e:
    got = str(e)
ok("cases: without cases.json run says to run inject first", "cases.json" in got and "inject" in got, got)

# ================================================================== cleanup
w = World("clean")
behave(lambda run, k: ("approve", []))
go(w)
drive(w)
go(w)
os.makedirs(os.path.join(w.state, "views", "x.git"))
os.makedirs(os.path.join(w.state, "scratch", "old"))
os.makedirs(os.path.join(w.state, "work", "other"))
os.makedirs(os.path.join(w.state, "packs"), exist_ok=True)
helpers.put(os.path.join(w.state, "packs"), "k.pack", "x")
helpers.put(os.path.join(w.state, "recreate", "dX"), "tree/src/a.py", "x = 1\n")
helpers.put(os.path.join(w.state, "recreate", "dX"), "tree/package.json", "{}")
helpers.put(os.path.join(w.state, "recreate", "dX"), "done", "")
helpers.put(os.path.join(w.state, "recreate"), "dX.json", "{}")
helpers.put(os.path.join(w.state, "recreate"), "dX.brief.md", "brief")
helpers.put(os.path.join(w.state, "recreated"), "dX.patch", "p")
helpers.put(os.path.join(w.state, "recreate", "dY"), "tree/src/a.py", "y = 1\n")        # done, but inject has not yet read it into recreated/dY.patch
helpers.put(os.path.join(w.state, "recreate", "dY"), "done", "")
other = os.path.join(want_root, "not-ours")
os.makedirs(other)
XR.Threads(w.state).add("th-clean", "new")
items = [os.path.join(C.items_root(), n) for n in C.jload(os.path.join(w.state, "items.json")).values()]
ok("cleanup: control: this state has staged item directories", items and all(os.path.isdir(i) for i in items), items)
held = os.open(os.path.join(w.state, "run.lock"), os.O_RDWR | os.O_CREAT)
fcntl.flock(held, fcntl.LOCK_EX)
try:
    with contextlib.redirect_stdout(io.StringIO()):
        P.cmd_cleanup(w.args())
    got = "no error"
except Failed as e:
    got = str(e)
ok("cleanup: it refuses while a run holds run.lock, and removes nothing", "run.lock" in got and all(os.path.isdir(i) for i in items) and all(os.path.isdir(r["scratch"]) for r in w.runs()), got)
fcntl.flock(held, fcntl.LOCK_UN)
os.close(held)
busy = os.open(os.path.join(w.state, "runs", w.runs()[0]["case"], w.runs()[0]["label"], "lock"), os.O_RDWR | os.O_CREAT)
fcntl.flock(busy, fcntl.LOCK_EX)
try:
    with contextlib.redirect_stdout(io.StringIO()):
        P.cmd_cleanup(w.args())
    got = "no error"
except Failed as e:
    got = str(e)
ok("cleanup: and while any run's lock is held", "busy" in got and all(os.path.isdir(i) for i in items), got)
fcntl.flock(busy, fcntl.LOCK_UN)
os.close(busy)
stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-clean"), NOMEM, {})
XR.RPC = stub
stops = []
P.codexhome.stop = lambda home: stops.append(home)
runs = w.runs()
jsons = sorted(os.path.relpath(os.path.join(d, f), w.state) for d, _x, fs in os.walk(w.state) for f in fs if f.endswith(".json") and "/work/" not in d + "/" and "/scratch/" not in d + "/" and "/tree/" not in d + "/")
dry = io.StringIO()
with contextlib.redirect_stdout(dry):
    P.cmd_cleanup(w.args(dry_run=True))
ok("cleanup: a dry run removes nothing and says what it would", all(os.path.isdir(r["scratch"]) for r in runs) and os.path.isdir(os.path.join(w.state, "work")) and "would" in dry.getvalue() and not stops)
with contextlib.redirect_stdout(io.StringIO()):
    rc = P.cmd_cleanup(w.args())
ok("cleanup: it removes this state's scratch/, work/, views/, packs/ and the run scratches under review-work/scratch",
   rc == 0 and not any(os.path.exists(os.path.join(w.state, d)) for d in ("scratch", "work", "views", "packs")) and not any(os.path.exists(r["scratch"]) for r in runs))
rdir = os.path.join(w.state, "recreate")
ok("cleanup: a recreation's working copy (recreate/<d>/tree) is removed, its spec, brief, done marker and patch stay",
   not os.path.exists(os.path.join(rdir, "dX", "tree")) and os.path.isfile(os.path.join(rdir, "dX", "done")) and os.path.isfile(os.path.join(rdir, "dX.json"))
   and os.path.isfile(os.path.join(rdir, "dX.brief.md")) and os.path.isfile(os.path.join(w.state, "recreated", "dX.patch")))
ok("cleanup: but a working copy whose recreated/<d>.patch is not yet made stays, for inject to read", os.path.isfile(os.path.join(rdir, "dY", "tree", "src", "a.py")))
ok("cleanup: another state's scratch directory stays", os.path.isdir(other))
ok("cleanup: this state's staged item directories are removed, and items.json stays", not any(os.path.exists(i) for i in items) and os.path.isfile(os.path.join(w.state, "items.json")))
after = sorted(os.path.relpath(os.path.join(d, f), w.state) for d, _x, fs in os.walk(w.state) for f in fs if f.endswith(".json") and "/work/" not in d + "/" and "/scratch/" not in d + "/" and "/tree/" not in d + "/")
ok("cleanup: every JSON file stays", jsons == after and "cases.json" in after and any(p.endswith("state.json") for p in after), set(jsons) ^ set(after))
log = helpers.read_log(os.path.join(os.path.dirname(stub), "rpc.log"))
arch = [e for e in log if e["cmd"] == "thread-archive"]
ok("cleanup: the threads are archived with CODEX_HOME set to the replay home", arch and all(e["codex_home"] == NOMEM for e in arch) and "th-clean" in " ".join(arch[0]["argv"]), log)
ok("cleanup: the daemon of the replay home is stopped", stops == [NOMEM], stops)
ok("cleanup: CODEX_HOME is back to what it was", os.environ["CODEX_HOME"] != NOMEM)
