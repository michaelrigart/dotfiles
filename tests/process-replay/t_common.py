import json
import os
import re
import subprocess
import sys
import shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, git_ok, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402

ROOT = helpers.tmp_root()
KINDS = ("judge-task", "judge-known", "judge-present", "judge-split", "judge-dedup", "judge-same", "judge-match", "judge-class")


def jfile(path, doc):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(doc, f)


def raises(fn, *args):
    try:
        fn(*args)
    except C.Failed:
        return True
    return False


# ---- the shared names come from xreview-replay, loaded once
ok("xr_reused: Failed, L, XP and the file helpers are xreview-replay's, not copies",
   C.Failed is C.XR.Failed and C.L is C.XR.L and C.XP is C.XR.XP and C.jload is C.XR.jload and C.jsave is C.XR.jsave
   and C.say is C.XR.say)
ok("xr_reused: loaded once, under one module name", sys.modules.get("xreview_replay") is C.XR)

# ---- state_default and label
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "xdg")
sd = C.state_default()
ok("state_default: $XDG_STATE_HOME/process-replay/<date>", re.fullmatch(re.escape(os.path.join(ROOT, "xdg", "process-replay")) + r"/\d{4}-\d\d-\d\d", sd), sd)
taken = set()
labels = [C.label(taken) for _ in range(300)]
ok("label: 8 hex, unique, recorded in the set", all(re.fullmatch(r"[0-9a-f]{8}", x) for x in labels) and len(set(labels)) == 300
   and taken == set(labels), labels[:3])

# ---- blind_refuses_keys
state = os.path.join(ROOT, "st1")
ok("blind_refuses_keys: a nested class key is refused", raises(C.judge_write, state, "judge-present", "p1", {"x": [{"class": "task"}]}))
for key in ("run", "arm", "label", "purpose", "class"):
    ok("blind_refuses_keys: {} is refused".format(key), raises(C.judge_write, state, "judge-present", "p1", {"a": {"b": [{key: 1}]}}))
ok("blind_refuses_keys: nothing was written", not os.path.exists(os.path.join(state, "judge-present")))
path = C.judge_write(state, "judge-present", "p1", {"finding": {"summary": "s"}, "files": {"a.py": "x\n"}})
is_("blind_refuses_keys: a clean document is written under <state>/<kind>/<id>.json", path, os.path.join(state, "judge-present", "p1.json"))
is_("blind_refuses_keys: with the document as given", C.jload(path), {"finding": {"summary": "s"}, "files": {"a.py": "x\n"}})
ok("blind_refuses_keys: an unknown kind is refused", raises(C.judge_write, state, "judge-other", "p1", {}))
ok("blind_refuses_keys: so is an id that leaves the directory", raises(C.judge_write, state, "judge-present", "../p1", {}))

# ---- pending_lists_unanswered
state = os.path.join(ROOT, "st2")
a = C.judge_write(state, "judge-present", "a1", {"finding": 1})
b = C.judge_write(state, "judge-present", "b2", {"finding": 2})
is_("pending_lists_unanswered: both unanswered", sorted(p[1] for p in C.pending(state)), ["a1", "b2"])
jfile(os.path.join(state, "judge-present", "a1.answer.json"), {"answer": "yes"})
got = C.pending(state)
d_b2 = C.item_dir(state, "judge-present", "b2")
is_("pending_lists_unanswered: an answer takes its input off the list; the input is the harness's, the answer and brief the staged ones",
    got, [("judge-present", "b2", b, os.path.join(d_b2, "answer.json"), os.path.join(d_b2, "brief.md"))])
is_("judge_answer: the parsed answer, or None", (C.judge_answer(state, "judge-present", "a1"), C.judge_answer(state, "judge-present", "b2")),
    ({"answer": "yes"}, None))
put(state, "final/f1/brief.md", "review the branch\n")
put(state, "final/f2/brief.md", "done already\n")
put(state, "final/f2/answer.md", "findings\n")
jfile(os.path.join(state, "recreate", "r1.json"), {"finding": "x"})
os.makedirs(os.path.join(state, "recreate", "r1"))
jfile(os.path.join(state, "recreate", "r2.json"), {"finding": "y"})
put(state, "recreate/r2/done", "")
got = C.pending(state)
d_f1 = C.item_dir(state, "final", "f1")
want = [("judge-present", "b2", b, os.path.join(d_b2, "answer.json"), os.path.join(d_b2, "brief.md")),
        ("final", "f1", os.path.join(state, "final", "f1", "brief.md"), os.path.join(d_f1, "answer.md"), os.path.join(d_f1, "brief.md")),
        ("recreate", "r1", os.path.join(state, "recreate", "r1.json"), os.path.join(state, "recreate", "r1", "done"),
         C.aliased(state, os.path.join(state, "recreate", "r1.json")))]
is_("pending_lists_unanswered: final reviews without answer.md and recreations without done are listed too", got, want)
is_("pending_lists_unanswered: an empty state has nothing", C.pending(os.path.join(ROOT, "nowhere")), [])

# ---- needed: a manifest leaves out the questions its writer asked and no longer needs, and nothing else
state = os.path.join(ROOT, "st-needed")
for kind, jid in (("judge-present", "dold-0"), ("judge-present", "dnow-1"), ("judge-present", "other-1-d"), ("judge-same", "dold-0")):
    C.judge_write(state, kind, jid, {"finding": jid})
jfile(os.path.join(state, "judge-present", "needed.json"), {"owned": ["dold-0", "dnow-1"], "needed": ["dnow-1"]})
is_("needed: a question its writer owns and no longer needs is not pending; one it needs is, and so is one it does not own; a kind with no manifest is as before",
    sorted((p[0], p[1]) for p in C.pending(state)), [("judge-present", "dnow-1"), ("judge-present", "other-1-d"), ("judge-same", "dold-0")])
ok("needed: the manifest itself is not an input", "needed" not in [p[1] for p in C.pending(state)])
jfile(os.path.join(state, "judge-present", "needed.json"), {"owned": ["dold-0", "dnow-1"], "needed": ["dold-0", "dnow-1"]})
is_("needed: needed again, it is pending again", sorted(p[1] for p in C.pending(state) if p[0] == "judge-present"), ["dnow-1", "dold-0", "other-1-d"])
for rid in ("rold", "rnow"):
    jfile(os.path.join(state, "recreate", rid + ".json"), {"finding": rid})
jfile(os.path.join(state, "recreate", "needed.json"), {"owned": ["rold", "rnow"], "needed": ["rnow"]})
is_("needed: recreations too: one its writer no longer needs is not pending, and the manifest is not a recreation",
    sorted(p[1] for p in C.pending(state) if p[0] == "recreate"), ["rnow"])

# ---- answers_complete: an answer gives an allowed value for everything the input asks about; anything else is set aside and asked again
TASK_IN = {"reports": [{"index": 0, "text": "t"}], "changes": [{"index": 0, "note": "n", "diff": "d"}]}
TASK_OK = {"index": 0, "report": 0, "summary": "s", "file": "f", "line": 1, "failure_scenario": "x", "severity": "P1", "introduced_by": None,
           "fixed_by": [0], "answer": "yes"}
MATCH_IN = {"defects": [{"index": 0}, {"index": 1}], "findings": [{"index": 0}, {"index": 1}]}
CASES = [
    ("judge-task", TASK_IN, {"findings": [TASK_OK]},
     [{}, {"findings": None}, {"findings": ["x"]}, {"findings": [dict(TASK_OK, answer="maybe")]}, {"findings": [dict(TASK_OK, severity=None)]},
      {"findings": [dict(TASK_OK, report=3)]}, {"findings": [dict(TASK_OK, fixed_by=[4])]}, {"findings": [dict(TASK_OK, fixed_by=None)]},
      {"findings": [dict(TASK_OK, introduced_by=9)]}, {"findings": [dict(TASK_OK, summary="")]}]),
    ("judge-known", {"findings": [{"index": 0}, {"index": 2}], "interdiff": ""}, {"verdicts": [{"index": 0, "answer": "yes"}, {"index": 2, "answer": "unclear"}]},
     [{}, {"verdicts": None}, {"verdicts": [{"index": 0, "answer": "yes"}]}, {"verdicts": [{"index": 0, "answer": "yes"}, {"index": 1, "answer": "no"}]},
      {"verdicts": [{"index": 0, "answer": "yes"}, {"index": 2, "answer": "maybe"}]},
      {"verdicts": [{"index": 0, "answer": "yes"}, {"index": 0, "answer": "yes"}, {"index": 2, "answer": "no"}]}]),
    ("judge-present", {"finding": 1}, {"answer": "no"}, [{}, {"answer": "maybe"}, {"answer": None}, []]),
    ("judge-split", {"defects": [{"index": 0}, {"index": 1}], "hunks": [{"index": 0}, {"index": 1}]},
     {"hunks": [{"index": 0, "defect": 1}, {"index": 1, "defect": "unsure"}]},
     [{}, {"hunks": None}, {"hunks": [{"index": 0, "defect": 1}]}, {"hunks": [{"index": 0, "defect": 5}, {"index": 1, "defect": None}]},
      {"hunks": [{"index": 0}, {"index": 1, "defect": None}]}, {"hunks": [{"index": 0, "defect": 0}, {"index": 0, "defect": 0}]},
      {"hunks": [{"index": 0, "defect": "maybe"}, {"index": 1, "defect": 0}]}]),
    ("judge-dedup", {"defects": [{"index": 0}, {"index": 1}, {"index": 2}]}, {"groups": [[0, 2], [1]]},
     [{}, {"groups": None}, {"groups": [[0], [1]]}, {"groups": [[0, 1, 2, 2]]}, {"groups": [[0], [1], [2], []]}, {"groups": [[0, 1], [2, "x"]]}]),
    ("judge-same", {"original": 1}, {"answer": "unclear"}, [{}, {"answer": "perhaps"}]),
    ("judge-class", {"finding": 1}, {"class": "design"}, [{}, {"class": "other"}, {"class": None}]),
    ("judge-match", MATCH_IN, {"matches": [{"defect": 0, "finding": 1}, {"defect": 1, "finding": None}], "unmatched": [{"finding": 0, "ruling": "real"}]},
     [{}, {"matches": None, "unmatched": []}, {"matches": [{"defect": 0, "finding": 1}], "unmatched": [{"finding": 0, "ruling": "real"}]},
      {"matches": [{"defect": 0, "finding": 1}, {"defect": 1, "finding": None}], "unmatched": []},
      {"matches": [{"defect": 0, "finding": 1}, {"defect": 1, "finding": None}]},
      {"matches": [{"defect": 0, "finding": 1}, {"defect": 1, "finding": None}], "unmatched": [{"finding": 0, "ruling": "maybe"}]},
      {"matches": [{"defect": 0, "finding": 1}, {"defect": 1, "finding": 5}], "unmatched": [{"finding": 0, "ruling": "real"}]},
      {"matches": [{"defect": 0, "finding": 1}, {"defect": 1}], "unmatched": [{"finding": 0, "ruling": "real"}]},
      {"matches": [{"defect": 0, "finding": 1}, {"defect": 0, "finding": None}], "unmatched": [{"finding": 0, "ruling": "real"}]},
      {"matches": [{"defect": 0, "finding": 1}, {"defect": 7, "finding": None}], "unmatched": [{"finding": 0, "ruling": "real"}]},
      {"matches": [{"defect": 0, "finding": 1}, {"defect": 1, "finding": None}], "unmatched": [{"finding": 0, "ruling": "real"}, {"finding": 0, "ruling": "real"}]}]),
    ("judge-match", {"defects": [{"index": 0}], "report": "r"},
     {"findings": [{"index": 0, "summary": "a"}], "matches": [{"defect": 0, "finding": None}], "unmatched": [{"finding": 0, "ruling": "false_positive"}]},
     [{"matches": [{"defect": 0, "finding": None}], "unmatched": []}, {"findings": None, "matches": [{"defect": 0, "finding": None}]},
      {"findings": [{"index": 3, "summary": "a"}], "matches": [{"defect": 0, "finding": None}], "unmatched": []},
      {"findings": [{"index": 0, "summary": "a"}], "matches": [{"defect": 0, "finding": 4}], "unmatched": []},
      {"findings": [{"index": 0, "summary": "a"}], "matches": [{"defect": 0, "finding": None}], "unmatched": []}]),
    ("judge-match", {"known": [{"index": 0}, {"index": 1}], "runs": {"x": [{"summary": "a"}], "y": []}},
     {"matches": [{"known_index": 0, "label": "x", "finding_index": 0}, {"known_index": 1, "label": "x", "finding_index": None},
                  {"known_index": 0, "label": "y", "finding_index": None}, {"known_index": 1, "label": "y", "finding_index": None}]},
     [{}, {"matches": None}, {"matches": [{"known_index": 0, "label": "x", "finding_index": 0}]},
      {"matches": [{"known_index": 0, "label": "x", "finding_index": 3}, {"known_index": 1, "label": "x", "finding_index": None},
                   {"known_index": 0, "label": "y", "finding_index": None}, {"known_index": 1, "label": "y", "finding_index": None}]},
      {"matches": [{"known_index": 0, "label": "z", "finding_index": None}, {"known_index": 1, "label": "x", "finding_index": None},
                   {"known_index": 0, "label": "y", "finding_index": None}, {"known_index": 1, "label": "y", "finding_index": None}]},
      {"matches": [{"known_index": 0, "label": "x"}, {"known_index": 1, "label": "x", "finding_index": None},
                   {"known_index": 0, "label": "y", "finding_index": None}, {"known_index": 1, "label": "y", "finding_index": None}]}]),
]
for n, (kind, inp, good, bads) in enumerate(CASES):
    state = os.path.join(ROOT, "st-complete-{}".format(n))
    C.judge_write(state, kind, "c1", inp)
    ans = os.path.join(state, kind, "c1.answer.json")
    for i, bad in enumerate(bads):
        jfile(ans, bad)
        listed = [p[1] for p in C.pending(state)] == ["c1"]
        got = C.accepted_answer(state, kind, "c1")
        aside = os.path.join(state, kind, "c1.rejected-{}.answer.json".format(i + 1))
        ok("answers_complete: {} #{} {}: refused, set aside unchanged, and the item is pending again".format(kind, n, i),
           listed and got is None and not os.path.exists(ans) and C.jload(aside) == bad and [p[1] for p in C.pending(state)] == ["c1"], (listed, got, bad))
    jfile(ans, good)
    ok("answers_complete: {} #{}: the complete answer is accepted and the item is not pending".format(kind, n),
       C.accepted_answer(state, kind, "c1") == good and C.pending(state) == [])
ok("answers_complete: an answer that is not a JSON object is refused too", (jfile(os.path.join(ROOT, "st-obj", "judge-present", "c1.answer.json"), ["yes"]),
   C.judge_write(os.path.join(ROOT, "st-obj"), "judge-present", "c1", {"finding": 1}), C.accepted_answer(os.path.join(ROOT, "st-obj"), "judge-present", "c1"))[2] is None)
state = os.path.join(ROOT, "st-byhand")
BYHAND = {"matches": [{"known_index": 0, "label": "x", "finding_index": None}]}
jfile(os.path.join(state, "judge-match", "h1.answer.json"), BYHAND)
is_("answers_complete: an answer put by hand before its input exists has no input to be checked against, and counts", C.accepted_answer(state, "judge-match", "h1"), BYHAND)
jfile(os.path.join(state, "judge-match", "h2.answer.json"), {"matches": ["by hand"]})
ok("answers_complete: but without an input its matches must still be objects, or it is set aside, unused",
   C.accepted_answer(state, "judge-match", "h2") is None and C.jload(os.path.join(state, "judge-match", "h2.rejected-1.answer.json")) == {"matches": ["by hand"]})

# ---- staged items: one real directory per item, outside the state, holding only that item's files
state = os.path.join(ROOT, "st-staged")
x1 = C.judge_write(state, "judge-present", "s1", {"finding": "one"})
x2 = C.judge_write(state, "judge-match", "s2", {"defects": []})
C.jsave(os.path.join(state, "inventory", "secret.json"), {"defects": ["the answers"]})
C.write_briefs(state)
b1, b2 = C.brief_for(state, "judge-present", "s1"), C.brief_for(state, "judge-match", "s2")
d1, d2 = os.path.dirname(b1), os.path.dirname(b2)
root = os.path.join(os.environ["XDG_STATE_HOME"], "review-work", "items")
ok("staged: each item has a real directory of its own, under review-work/items/<16 hex>, outside the state",
   d1 != d2 and os.path.dirname(d1) == root and re.fullmatch(r"[0-9a-f]{16}", os.path.basename(d1)) and not os.path.islink(d1)
   and os.path.realpath(d1) == d1.replace(os.environ["XDG_STATE_HOME"], os.path.realpath(os.environ["XDG_STATE_HOME"])) and state not in d1, (d1, d2))
is_("staged: a judge's directory holds its input and brief and nothing else", sorted(os.listdir(d1)), ["brief.md", "input.json"])
is_("staged: input.json is the input", C.jload(os.path.join(d1, "input.json")), {"finding": "one"})
ok("staged: the brief names the staged input and answer, never the state", ("Input: " + os.path.join(d1, "input.json")) in open(b1).read()
   and open(b1).read().endswith("Write your answer to: " + os.path.join(d1, "answer.json") + "\n") and state not in open(b1).read())
ok("staged: nothing in the directory leads into the state (no link, no state path in any file)",
   all(not os.path.islink(os.path.join(d1, n)) and state not in open(os.path.join(d1, n)).read() for n in os.listdir(d1)))
is_("staged: the same item gets the same directory", C.item_dir(state, "judge-present", "s1"), d1)
jfile(os.path.join(d1, "answer.json"), {"answer": "no"})
is_("staged: an answer written in the item's directory is read", C.judge_answer(state, "judge-present", "s1"), {"answer": "no"})
is_("staged: and copied into the state", C.jload(os.path.join(state, "judge-present", "s1.answer.json")), {"answer": "no"})
ok("staged: the staged copy is gone, so a later input cannot meet a stale answer", not os.path.exists(os.path.join(d1, "answer.json")))
jfile(os.path.join(d2, "answer.json"), {"matches": []})
ok("staged: an answer written but not yet collected takes the item off the pending list", [p[1] for p in C.pending(state)] == [])
open(os.path.join(d2, "answer.json"), "w").write("{half")
ok("staged: an answer that does not parse yet is not collected, and the item stays pending", C.judge_answer(state, "judge-match", "s2") is None
   and [p[1] for p in C.pending(state)] == ["s2"])
open(os.path.join(state, "judge-match", "s2.answer.json"), "w").write("{half")
ok("staged: nor is a half-written answer already in the state an answer", C.judge_answer(state, "judge-match", "s2") is None
   and [p[1] for p in C.pending(state)] == ["s2"])
os.unlink(os.path.join(state, "judge-match", "s2.answer.json"))
os.unlink(os.path.join(d2, "answer.json"))
ok("staged: with no answer there, the item is pending again", [p[1] for p in C.pending(state)] == ["s2"])
jfile(os.path.join(d2, "answer.json"), {"matches": ["old"]})
C.judge_write(state, "judge-match", "s2", {"defects": [{"index": 0}]})
ok("staged: a changed input drops an uncollected answer to the old one", not os.path.exists(os.path.join(d2, "answer.json")) and C.judge_answer(state, "judge-match", "s2") is None)
# a changed input also sets aside the answer already collected into the state (its content kept), not only a staged one
jfile(os.path.join(d2, "answer.json"), {"matches": ["old"]})
is_("stale: the judge answers the input as it stands, and the answer is collected", C.judge_answer(state, "judge-match", "s2"), {"matches": ["old"]})
jfile(os.path.join(d2, "answer.json"), {"matches": ["staged-too"]})
C.judge_write(state, "judge-match", "s2", {"defects": [{"index": 0}, {"index": 1}]})
mdir = os.path.join(state, "judge-match")
ok("stale: a collected answer to the old input is not the answer to the new one", C.judge_answer(state, "judge-match", "s2") is None
   and not os.path.exists(os.path.join(mdir, "s2.answer.json")) and not os.path.exists(os.path.join(d2, "answer.json")))
is_("stale: the collected answer is kept aside, unchanged", C.jload(os.path.join(mdir, "s2.stale-1.answer.json")), {"matches": ["old"]})
ok("stale: the item is pending again, and the set-aside answer is not an input", [p[1] for p in C.pending(state) if p[0] == "judge-match"] == ["s2"]
   and "s2.stale-1" not in C._inputs(state, "judge-match"))
jfile(os.path.join(mdir, "s2.answer.json"), {"matches": ["new"]})
C.judge_write(state, "judge-match", "s2", {"defects": [{"index": 0}, {"index": 1}]})
is_("stale: writing the same input again keeps its answer", C.judge_answer(state, "judge-match", "s2"), {"matches": ["new"]})
C.judge_write(state, "judge-match", "s2", {"defects": []})
is_("stale: a second change sets aside under a name of its own", (sorted(n for n in os.listdir(mdir) if ".stale-" in n), C.jload(os.path.join(mdir, "s2.stale-2.answer.json"))),
    (["s2.stale-1.answer.json", "s2.stale-2.answer.json"], {"matches": ["new"]}))
jfile(os.path.join(mdir, "s3.answer.json"), {"matches": ["by hand"]})
C.judge_write(state, "judge-match", "s3", {"defects": []})
is_("stale: an answer put in the state before the input ever existed still counts", C.judge_answer(state, "judge-match", "s3"), {"matches": ["by hand"]})
put(state, "final/sf/brief.md", "review it\nReview id: sf\n")
df = C.item_dir(state, "final", "sf")
put(df, "package.diff", "diff\n")
bf = C.brief_for(state, "final", "sf")
is_("staged: a final review's directory holds its brief and package", (bf, sorted(os.listdir(df))), (os.path.join(df, "brief.md"), ["brief.md", "package.diff"]))
is_("staged: its brief is a copy of the harness's", open(bf).read(), "review it\nReview id: sf\n")
ok("staged: a final review with no answer is pending, and collect_final finds none", [p[1] for p in C.pending(state) if p[0] == "final"] == ["sf"] and C.collect_final(state, "sf") is None)
put(df, "answer.md", "")
put(state, "final/sf/answer.md", " \n")
ok("staged: an empty answer.md (a write not yet begun), staged or in the state, is no answer: the final review stays pending",
   [p[1] for p in C.pending(state) if p[0] == "final"] == ["sf"] and C.collect_final(state, "sf") is None)
os.unlink(os.path.join(state, "final", "sf", "answer.md"))
put(df, "answer.md", "### Issues\n")
got = C.collect_final(state, "sf")
is_("staged: an answer.md written in the item's directory is moved into the state", (got, open(got).read(), os.path.exists(os.path.join(df, "answer.md"))),
    (os.path.join(state, "final", "sf", "answer.md"), "### Issues\n", False))
ok("staged: and the final review is no longer pending", not [p for p in C.pending(state) if p[0] == "final"])

# ---- per_input_briefs and briefs_neutral
state = os.path.join(ROOT, "st3")
x = C.judge_write(state, "judge-present", "i-one", {"finding": 1})
y = C.judge_write(state, "judge-present", "i-two", {"finding": 2})
C.write_briefs(state)
kind_brief = open(os.path.join(state, "judges", "judge-present.md")).read()
texts = {}
for kind, jid, inp, ans, brief in C.pending(state):
    is_("per_input_briefs: brief_for returns the path pending() names", C.brief_for(state, kind, jid), brief)
    texts[jid] = open(brief).read()
    d = os.path.dirname(brief)
    ok("per_input_briefs: {} is staged beside its copy of the input and its answer".format(jid),
       brief == os.path.join(d, "brief.md") and ans == os.path.join(d, "answer.json") and os.path.dirname(d) == os.path.join(os.environ["XDG_STATE_HOME"], "review-work", "items"), brief)
    tail = "Input: {}\nWrite your answer to: {}\n".format(os.path.join(d, "input.json"), ans)
    ok("per_input_briefs: {} is the kind's brief, then exactly the two path lines".format(jid),
       texts[jid].startswith(kind_brief) and texts[jid].endswith(tail) and texts[jid][len(kind_brief):-len(tail)].strip() == "", texts[jid][-300:])
ok("per_input_briefs: each names its own input and answer", all(os.path.join(os.path.dirname(C.brief_for(state, "judge-present", i)), "input.json") in texts[i] for i in texts))
ok("per_input_briefs: and not the other's", "i-two" not in texts["i-one"] and "i-one" not in texts["i-two"]
   and os.path.dirname(C.brief_for(state, "judge-present", "i-two")) not in texts["i-one"])
ok("per_input_briefs: and never the real state path", state not in texts["i-one"] and state not in texts["i-two"])
ok("per_input_briefs: a brief is not an input", [p[1] for p in C.pending(state)] == ["i-one", "i-two"])
ok("per_input_briefs: a final review's brief is its staged copy", C.brief_for(os.path.join(ROOT, "st2"), "final", "f1")
   == os.path.join(C.item_dir(os.path.join(ROOT, "st2"), "final", "f1"), "brief.md"))

forbidden = re.compile(r"replay|inject|removal|per-task|\barm\b|\brun\b", re.I)
missing = [k for k in KINDS if not os.path.isfile(os.path.join(state, "judges", k + ".md"))]
is_("briefs_neutral: every kind has a brief", missing, [])
bad = {}
for k in KINDS:
    text = open(os.path.join(state, "judges", k + ".md")).read()
    if forbidden.search(text) or " arm" in text.lower():
        bad[k] = forbidden.search(text).group(0) if forbidden.search(text) else " arm"
is_("briefs_neutral: none says replay, inject, removal, per-task, arm or run", bad, {})
shape = {"judge-task": "findings", "judge-known": "verdicts", "judge-present": "answer", "judge-split": "hunks",
         "judge-dedup": "groups", "judge-same": "answer", "judge-match": "matches", "judge-class": "class"}
no_shape = [k for k, w in shape.items() if w not in open(os.path.join(state, "judges", k + ".md")).read()]
is_("briefs_neutral: each brief names its answer's shape", no_shape, [])
scale = ["P0 (it cannot work) to P3 (minor)"]
for k in ("judge-task", "judge-known", "judge-match"):
    t = open(os.path.join(state, "judges", k + ".md")).read()
    ok("briefs_neutral: {} gives the severity scale".format(k), scale[0] in t and all("P{}".format(i) in t for i in range(4)), t[:200])
before = open(os.path.join(state, "judges", "judge-task.md")).read()
C.write_briefs(state)
is_("briefs_neutral: writing the briefs again changes nothing", open(os.path.join(state, "judges", "judge-task.md")).read(), before)

# ---- briefs_neutral, on the default state layout: nothing handed to a judge says replay
state = C.state_default()
ok("briefs_neutral: control: the real state path does say replay", "replay" in state, state)
for k in KINDS:
    C.judge_write(state, k, "n-" + k, {"finding": 1})
put(state, "final/nf/brief.md", "review\n")
jfile(os.path.join(state, "recreate", "nr.json"), {"finding": "x"})
C.write_briefs(state)
seen = []
for kind, jid, inp, ans, brief in C.pending(state):
    C.brief_for(state, kind, jid)
    text = open(brief).read()
    seen.append(kind)
    ok("briefs_neutral: {} {} and its path say nothing of replay, inject, removal, per-task, arm or run".format(kind, jid),
       not forbidden.search(text) and "replay" not in brief and "process-replay" not in text, text[-200:])
    if kind in KINDS + ("final",):
        ok("briefs_neutral: {} {}: the staged directory leads nowhere into the state".format(kind, jid),
           all(state not in open(os.path.join(os.path.dirname(brief), n)).read() for n in os.listdir(os.path.dirname(brief))))
is_("briefs_neutral: every kind's per-input brief was scanned", sorted(seen), sorted(KINDS + ("final", "recreate")))

# ---- the alias
link = C.alias(state)
al_base = os.path.join(os.environ["XDG_STATE_HOME"], "review-work")
ok("alias: a symlink $XDG_STATE_HOME/review-work/<8 hex> to the state", os.path.islink(link) and os.path.dirname(link) == al_base
   and re.fullmatch(r"[0-9a-f]{8}", os.path.basename(link)) and os.path.realpath(link) == os.path.realpath(state), link)
is_("alias: recorded in <state>/alias", open(os.path.join(state, "alias")).read().strip(), link)
is_("alias: stable across calls", (C.alias(state), C.alias(state)), (link, link))
is_("aliased: a path under the state, as the same path under the alias", C.aliased(state, os.path.join(state, "judge-task", "n-judge-task.json")),
    os.path.join(link, "judge-task", "n-judge-task.json"))
ok("aliased: a path outside the state is refused", raises(C.aliased, state, os.path.join(ROOT, "elsewhere")))
jfile(os.path.join(link, "judge-task", "n-judge-task.answer.json"), {"findings": []})
is_("alias: an answer written through the aliased path is read by judge_answer", C.judge_answer(state, "judge-task", "n-judge-task"), {"findings": []})
os.unlink(link)
is_("alias: recreated at its recorded path when the symlink is gone", (C.alias(state), os.path.islink(link), os.path.realpath(link) == os.path.realpath(state)),
    (link, True, True))
other = os.path.join(ROOT, "st-other")
os.makedirs(other)
lo = C.alias(other)
ok("alias: another state gets its own", lo != link and os.path.realpath(lo) == os.path.realpath(other), lo)

# ---- cmd_pending
state = os.path.join(ROOT, "st3")
import io  # noqa: E402
import contextlib  # noqa: E402


class A(object):
    pass


a_ = A()
a_.state = state
a_.dry_run = False
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = C.cmd_pending(a_)
lines = buf.getvalue().splitlines()
ok("cmd_pending: one line per pending item, with its staged brief", rc == 0 and len(lines) == 2 and "judge-present" in lines[0]
   and "i-one" in lines[0] and lines[0].rstrip().endswith(os.path.join(C.item_dir(state, "judge-present", "i-one"), "brief.md")), lines)
ok("cmd_pending: and the briefs exist", all(os.path.isfile(os.path.join(C.item_dir(state, "judge-present", i), "brief.md")) for i in ("i-one", "i-two")))

# ---- view_reads_snapshot_only_objects
org =os.path.join(ROOT, "Code", "Org")
os.makedirs(org)
repo = helpers.make_repo(org, "curato")
put(repo, "a.txt", "a\n")
c0 = helpers.commit(repo, "base")
put(repo, "a.txt", "a\nb\n")
c1 = helpers.commit(repo, "work")
gitdir = os.path.join(repo, ".git")
snaproot = os.path.join(ROOT, "snap")
os.makedirs(os.path.join(snaproot, "curato"))
shutil.copytree(os.path.join(gitdir, "objects"), os.path.join(snaproot, "curato", "objects"))
git(repo, "reset", "-q", "--hard", c0)
git(repo, "reflog", "expire", "--expire=now", "--all")
git(repo, "gc", "-q", "--prune=now")
ok("view_reads_snapshot_only_objects: control: the original no longer has the commit", not git_ok(repo, "cat-file", "-e", c1))
snap_before = helpers.listing(snaproot)
orig_before = helpers.listing(os.path.join(gitdir, "objects"))
state = os.path.join(ROOT, "st4")
v = C.view(state, gitdir, snaproot)
is_("view_reads_snapshot_only_objects: the view is <state>/views/<name>.git", v, os.path.join(state, "views", "curato.git"))
is_("view_reads_snapshot_only_objects: the commit resolves", C.git(v, "cat-file", "-t", c1), "commit")
is_("view_reads_snapshot_only_objects: a short id resolves", C.git(v, "rev-parse", "--verify", c1[:9] + "^{commit}"), c1)
is_("view_reads_snapshot_only_objects: history reads", C.git(v, "log", "-1", "--format=%s", c1), "work")
is_("view_reads_snapshot_only_objects: the diff reads", C.git(v, "diff", "--stat", c0, c1).splitlines()[-1].strip(), "1 file changed, 1 insertion(+)")
ok("view_reads_snapshot_only_objects: git_ok answers", C.git_ok(v, "cat-file", "-e", c1) and not C.git_ok(v, "cat-file", "-e", "0" * 40))
ok("view_reads_snapshot_only_objects: git raises Failed on an error", raises(C.git, v, "cat-file", "-t", "0" * 40))
is_("view_reads_snapshot_only_objects: a second call returns the same view", C.view(state, gitdir, snaproot), v)
alt = open(os.path.join(v, "objects", "info", "alternates")).read().split()
is_("view_reads_snapshot_only_objects: alternates name the snapshot's objects", alt, [os.path.join(snaproot, "curato", "objects")])
is_("view_reads_snapshot_only_objects: the snapshot listing (paths, sizes, mtimes) is unchanged", helpers.listing(snaproot), snap_before)
is_("view_reads_snapshot_only_objects: so is the original's object store", helpers.listing(os.path.join(gitdir, "objects")), orig_before)
v2 = C.view(state, gitdir, os.path.join(ROOT, "no-snapshots"))
alt2 = open(os.path.join(v2, "objects", "info", "alternates")).read().split()
is_("view_reads_snapshot_only_objects: without a snapshot the alternates are the original's objects", alt2, [os.path.join(gitdir, "objects")])
ok("view_reads_snapshot_only_objects: and an object the original has resolves", C.git_ok(v2, "cat-file", "-e", c0))

# ---- snapshot_map
snap = os.path.join(ROOT, "snapmap")
os.makedirs(os.path.join(snap, "curato", "objects"))
os.makedirs(os.path.join(snap, "chezmoi", "objects"))
is_("snapshot_map: a repository under Code", C.snapshot_objects(snap, "/x/Code/Netronix/curato/.git"), os.path.join(snap, "curato", "objects"))
is_("snapshot_map: the dotfiles", C.snapshot_objects(snap, "/x/.local/share/chezmoi/.git"), os.path.join(snap, "chezmoi", "objects"))
is_("snapshot_map: a trailing slash", C.snapshot_objects(snap, "/x/Code/Netronix/curato/.git/"), os.path.join(snap, "curato", "objects"))
is_("snapshot_map: an unknown name", C.snapshot_objects(snap, "/x/Code/Netronix/unknown/.git"), None)
os.makedirs(os.path.join(snap, "empty"))
is_("snapshot_map: a name whose dir has no objects", C.snapshot_objects(snap, "/x/empty/.git"), None)

# ---- the command line
CLI = os.path.join(helpers.SCRIPTS, "process-replay.py")
ok("cli: process-replay.py is executable", os.access(CLI, os.X_OK))


def cli(*args, cwd=None):
    env = dict(os.environ, XDG_STATE_HOME=os.path.join(ROOT, "xdg"))
    return subprocess.run(["/usr/bin/python3", "-I", "-B", CLI] + list(args), capture_output=True, cwd=cwd, env=env)


work = os.path.join(ROOT, "cwd")
os.makedirs(work)
p = cli("pending", "--state", "rel-state", cwd=work)
ok("cli: --state is made absolute and created", p.returncode == 0 and os.path.isdir(os.path.join(work, "rel-state")), p.stderr)
is_("cli: nothing pending says so", p.stdout.decode().strip(), "nothing pending")
C.judge_write(os.path.join(work, "rel-state"), "judge-class", "k1", {"finding": 1})
p = cli("pending", "--state", "rel-state", cwd=work)
out = p.stdout.decode()
ok("cli: pending lists the input and stages its brief", p.returncode == 0 and "judge-class" in out and "k1" in out
   and os.path.isfile(out.split("\t")[-1].strip()) and "rel-state" not in out, out + p.stderr.decode())
p = cli("nonsense")
ok("cli: an unknown command exits 2", p.returncode == 2 and b"nonsense" in p.stderr, p.stderr)
p = cli("--help")
ok("cli: help lists the subcommands", p.returncode == 0 and all(c.encode() in p.stdout for c in
   ("snapshot", "cases", "inject", "run", "match", "report", "cleanup", "pending", "home", "memories-watch")), p.stdout)
p = cli("pending", "--state", "rel-state", "--max-tokens", "5", "--budget", "7", "--snapshot-root", "/x", "--projects-dir", "/y", "--dry-run", cwd=work)
ok("cli: the shared flags parse", p.returncode == 0, p.stderr)

# ---- the fixtures later suites build on: rollouts, ledgers, transcripts, the fake rpc and the fake codex
XRM = C.XR
chome = os.path.join(ROOT, "chome")
helpers.write_rollout(chome, "thR", [
    {"turn": "t1", "answer": {"verdict": "changes", "findings": []}, "tokens": 700, "rate_limits": {"primary": {"used_percent": 81.0, "window_minutes": 10080, "resets_at": 5}}},
    {"turn": "t2", "ctx": 175000, "answer": "plain text", "tokens": 400, "compacted": True, "model": "m-2", "effort": "low",
     "tools": [{"type": "function_call", "name": "shell", "arguments": {"cmd": "ls /work"}}, {"type": "custom_tool_call", "arguments": "cat /work/x"}]},
    ("t3", None, {"verdict": "approve", "findings": []}, False)])
os.environ["CODEX_HOME"] = chome
XRM._TURNS.clear()
turns = XRM.turns_of("thR")
is_("rollouts: turns come back in order with their answers", (list(turns), json.loads(turns["t1"]["final"])["verdict"], turns["t2"]["final"]),
    (["t1", "t2", "t3"], "changes", "plain text"))
is_("rollouts: context before a turn, compaction, model and effort", (turns["t2"]["ctx_before"], turns["t2"]["compacted"], turns["t2"]["model"], turns["t2"]["effort"], turns["t1"]["compacted"]),
    (175000, True, "m-2", "low", False))
is_("rollouts: a turn's tokens are its own", (XRM.turn_usage("thR", "t1")["tokens"], XRM.turn_usage("thR", "t2")["tokens"]), (700, 400))
lines = [json.loads(l) for l in open(helpers.rollout_file(chome, "thR"))]
tools = [r["payload"] for r in lines if r["type"] == "response_item"]
ok("rollouts: a function_call carries arguments, a custom_tool_call input (the real shapes)",
   tools[0]["type"] == "function_call" and "/work" in tools[0]["arguments"] and tools[1]["type"] == "custom_tool_call"
   and tools[1]["input"] == "cat /work/x", tools)
rl = [r["payload"]["rate_limits"] for r in lines if r["type"] == "event_msg" and r["payload"].get("rate_limits")]
is_("rollouts: rate_limits sit in the token_count payload", rl[0]["primary"]["window_minutes"], 10080)

xdg = os.path.join(ROOT, "xdg2")
os.environ["XDG_STATE_HOME"] = xdg
lrepo = helpers.make_repo(ROOT, "ledgered")
put(lrepo, "f", "1\n")
helpers.commit(lrepo, "c")
helpers.write_ledger(xdg, lrepo, [{"v": 2, "kind": "receipt", "nonce": "n1"}])
found = list(XRM.ledgers())
is_("ledger: xreview-replay finds the fixture ledger", [(os.path.realpath(r), [e["nonce"] for e in es]) for r, es in found],
    [(os.path.realpath(C.L.common_dir(lrepo)), ["n1"])])

proj = os.path.join(ROOT, "projects")
helpers.write_transcript(proj, "-key", "sess", [{"type": "user", "n": 1}], [{"id": "ab12", "meta": {"agentType": "sp-reviewer", "description": "Review Task 1"},
                                                                            "entries": [{"type": "assistant"}]}])
is_("transcript: the session, its subagent and the subagent's meta", (
    json.loads(open(os.path.join(proj, "-key", "sess.jsonl")).readline()),
    json.load(open(os.path.join(proj, "-key", "sess", "subagents", "agent-ab12.meta.json")))["agentType"],
    os.path.isfile(os.path.join(proj, "-key", "sess", "subagents", "agent-ab12.jsonl"))), ({"type": "user", "n": 1}, "sp-reviewer", True))

# the fake rpc, driven through xreview-replay's own client
FAKE = os.path.join(ROOT, "fake")
ANS1 = {"verdict": "changes", "findings": [{"severity": "P1", "file": "a.py", "line": 1, "summary": "s", "failure_scenario": "f"}], "reviewed_files": ["a.py"]}
ANS2 = {"verdict": "approve", "findings": [], "reviewed_files": []}
script = {"turns": [{"answer": ANS1, "tokens": 1500, "rate_limits": {"primary": {"used_percent": 10, "window_minutes": 10080}}},
                    {"answer": ANS2, "rc3": 2, "compacted": True}],
          "threads": {"th2": [{"answer": ANS2, "rc": 4, "raw": "not json"}]}}
rpc = helpers.stub_rpc(FAKE, os.path.join(ROOT, "rpc-home-default"), script)
XRM.RPC = rpc
rhome = os.path.join(ROOT, "rhome")
os.environ["CODEX_HOME"] = rhome
XRM._TURNS.clear()
rc, out, _err = XRM.rpc("thread-start", "--cwd", ROOT)
th1 = out.strip()
is_("stub_rpc: thread-start numbers its threads", (rc, th1), (0, "th1"))
inp = os.path.join(ROOT, "packet.md")
put(ROOT, "packet.md", "the packet\n")
rc, out, _err = XRM.rpc("turn-start", "--thread", th1, "--input", inp, "--schema", "/s", "--cwd", ROOT)
tu1 = out.strip()
is_("stub_rpc: turn-start gives the first scripted turn an id and keeps its input", (rc, tu1, open(os.path.join(FAKE, "inputs", tu1)).read()),
    (0, "tu1", "the packet\n"))
rep = os.path.join(ROOT, "report.json")
rc, out, _err = XRM.rpc("turn-wait", "--thread", th1, "--turn", tu1, "--budget", "5", "--report", rep)
is_("stub_rpc: turn-wait answers with the scripted document", (rc, json.loads(out)), (0, ANS1))
is_("stub_rpc: and reports the compaction", C.jload(rep), {"turn": tu1, "compacted": False})
is_("stub_rpc: the rollout lands under the call's CODEX_HOME and reads back", (os.path.isdir(os.path.join(rhome, "sessions")), XRM.turn_usage(th1, tu1)["tokens"],
    json.loads(XRM.turns_of(th1)[tu1]["final"])["verdict"]), (True, 1500, "changes"))
rc, out, _err = XRM.rpc("thread-start", "--cwd", ROOT)
th2 = out.strip()
rc, out, _err = XRM.rpc("turn-start", "--thread", th2, "--input", inp, "--schema", "/s")
tu2 = out.strip()
rc, out, _err = XRM.rpc("turn-wait", "--thread", th2, "--turn", tu2, "--budget", "5")
is_("stub_rpc: a turn keyed by thread beats the global order, and rc 4 prints the raw text", (rc, out.strip()), (4, "not json"))
rc, out, _err = XRM.rpc("thread-start", "--cwd", ROOT)
th3 = out.strip()
rc, out, _err = XRM.rpc("turn-start", "--thread", th3, "--input", inp, "--schema", "/s")
tu3 = out.strip()
waits = [XRM.rpc("turn-wait", "--thread", th3, "--turn", tu3, "--budget", "5")[0] for _ in range(3)]
is_("stub_rpc: the global order's second turn, still running for two waits (exit 3)", (tu3, waits), ("tu3", [3, 3, 0]))
rc, _out, err = XRM.rpc("turn-start", "--thread", th3, "--input", inp, "--schema", "/s")
ok("stub_rpc: a turn past the end of the script fails loudly", rc == 1 and "no turn left" in err, err)
is_("stub_rpc: archive and health succeed", (XRM.rpc("thread-archive", "--thread", th1)[0], XRM.rpc("health")[0]), (0, 0))
is_("stub_rpc: an unknown command exits 2", XRM.rpc("thread-fork", "--thread", th1)[0], 2)
calls = helpers.read_log(os.path.join(FAKE, "rpc.log"))
ok("stub_rpc: every call is logged with its argv and CODEX_HOME", len(calls) == 15 and all(c["codex_home"] == rhome for c in calls)
   and calls[0]["argv"] == ["thread-start", "--cwd", ROOT] and calls[0]["cmd"] == "thread-start", calls[:2])
os.environ.pop("CODEX_HOME")
XRM.rpc("health")
ok("stub_rpc: without a CODEX_HOME the call is logged as such", helpers.read_log(os.path.join(FAKE, "rpc.log"))[-1]["codex_home"] is None)

# the fake codex binary
codex = helpers.stub_codex(os.path.join(ROOT, "fakecodex"))
chm = os.path.join(ROOT, "codexhome")
sock = os.path.join(chm, "app-server-control", "app-server-control.sock")


def codex_run(*args, home=chm):
    env = dict(os.environ)
    env.pop("CODEX_HOME", None)
    if home:
        env["CODEX_HOME"] = home
    return subprocess.run([codex] + list(args), capture_output=True, env=env)


p = codex_run("app-server", "daemon", "start")
ok("stub_codex: daemon start makes the socket a plain file", p.returncode == 0 and os.path.isfile(sock) and not os.path.islink(sock), p.stderr)
p = codex_run("app-server", "daemon", "stop")
ok("stub_codex: daemon stop removes it", p.returncode == 0 and not os.path.exists(sock), p.stderr)
is_("stub_codex: login succeeds", codex_run("login").returncode, 0)
is_("stub_codex: with no CODEX_HOME a daemon command fails", codex_run("app-server", "daemon", "start", home=None).returncode, 2)
is_("stub_codex: an unknown command exits 2", codex_run("exec").returncode, 2)
log = helpers.read_log(os.path.join(ROOT, "fakecodex", "codex.log"))
is_("stub_codex: argv and CODEX_HOME are logged", (log[0], len(log)), ({"argv": ["app-server", "daemon", "start"], "codex_home": chm}, 5))
p = cli()
ok("cli: no command prints the usage to stderr and exits 2", p.returncode == 2 and p.stdout == b"" and b"usage:" in p.stderr, (p.stdout, p.stderr))

# ---- alias: a copied state, a dangling link
orig = os.path.join(ROOT, "al-orig")
os.makedirs(orig)
orig_link = C.alias(orig)
copy = os.path.join(ROOT, "al-copy")
shutil.copytree(orig, copy, symlinks=True)
copy_link = C.alias(copy)
ok("alias: a state copied with cp -r gets a link of its own", copy_link != orig_link and os.path.realpath(copy_link) == os.path.realpath(copy), copy_link)
ok("alias: and the original's link still resolves to the original", os.path.realpath(orig_link) == os.path.realpath(orig)
   and open(os.path.join(orig, "alias")).read().strip() == orig_link and C.alias(orig) == orig_link)
moved = os.path.join(ROOT, "al-moved")
os.rename(orig, moved)
ok("alias: control: moving a state leaves its link dangling", os.path.islink(orig_link) and not os.path.exists(orig_link))
is_("alias: a dangling link is re-pointed at the same name", C.alias(moved), orig_link)
ok("alias: and now resolves to the moved state", os.path.realpath(orig_link) == os.path.realpath(moved))

# ---- setup() redirects home, state and Codex home even when git is already isolated
probe = "import sys; sys.path.insert(0, %r); import helpers, os; helpers.setup(); print(os.environ['HOME'], os.environ['XDG_STATE_HOME'], os.environ['CODEX_HOME'])" % helpers.HERE
real = {"HOME": "/real/home", "XDG_STATE_HOME": "/real/state", "CODEX_HOME": "/real/codex"}
env = dict(os.environ, GIT_CONFIG_GLOBAL=os.environ["GIT_CONFIG_GLOBAL"], **real)
env.pop("T_ROOT", None)
out = subprocess.run(["/usr/bin/python3", "-I", "-B", "-c", probe], capture_output=True, env=env).stdout.decode().split()
ok("helpers.setup: redirects the three variables although GIT_CONFIG_GLOBAL is set", len(out) == 3 and not any(v.startswith("/real") for v in out), out)
env["T_ROOT"] = ROOT
env.update(HOME=ROOT + "/h", XDG_STATE_HOME=ROOT + "/s", CODEX_HOME=ROOT + "/c")
out = subprocess.run(["/usr/bin/python3", "-I", "-B", "-c", probe], capture_output=True, env=env).stdout.decode().split()
is_("helpers.setup: keeps the wrapper's own redirect", out, [ROOT + "/h", ROOT + "/s", ROOT + "/c"])

# ---- Reader: the view-backed reads planreview and inventory share
RR = helpers.make_repo(ROOT, "readrepo")
put(RR, "a.txt", "one\n")
R1 = helpers.commit(RR, "one")
put(RR, "a.txt", "two\n")
R2 = helpers.commit(RR, "two")
git(RR, "checkout", "-q", "-b", "copy", R1)
git(RR, "cherry-pick", R2)
R2C = git(RR, "rev-parse", "HEAD")
git(RR, "checkout", "-q", "main")
rd = C.Reader(os.path.join(ROOT, "rstate"), C.L.common_dir(RR), os.path.join(ROOT, "no-snapshot"))
is_("Reader.commit: a short hex id resolves to the full id", (rd.commit(R1[:8]), rd.commit(R1.upper())), (R1, R1))
is_("Reader.commit: not hex, absent and too short are None", (rd.commit("main"), rd.commit("f" * 40), rd.commit("abc"), rd.commit(None)), (None, None, None, None))
is_("Reader.commits: tip minus base and excludes, newest first", ([s for s, _t in rd.commits(R1, R2)], rd.commits(R1, R2, [R2])), ([R2], []))
ok("Reader.is_ancestor", rd.is_ancestor(R1, R2) and not rd.is_ancestor(R2, R1))
is_("Reader.file and Reader.names", (rd.file(R2, "a.txt"), rd.file(R2, "nope"), rd.names(R1, R2)), ("two\n", None, ["a.txt"]))
ok("Reader.patch: the change, capped with a [truncated] line", "+two" in rd.patch(R1, R2))
ok("Reader.patch_id: a cherry-pick has its original's id, and branch_patch_ids maps it back",
   rd.patch_id(R2) == rd.patch_id(R2C) and rd.patch_id(R2) is not None and rd.branch_patch_ids(R1, R2C) == {rd.patch_id(R2): R2C})
is_("cap and norm", (C.cap("abcdef", 3), C.cap("abc", 3), C.norm("./a/x"), C.norm("b/x"), C.norm("x"), C.norm(None)), ("abc\n[truncated]\n", "abc", "x", "x", "x", ""))
