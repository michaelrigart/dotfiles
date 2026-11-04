import os
import re
import sys
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import gate as G  # noqa: E402
from process_replay import scratch  # noqa: E402

ROOT = helpers.tmp_root()
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "xdg")
os.makedirs(os.environ["XDG_STATE_HOME"])
STATE = os.path.join(ROOT, "state")
A = Namespace(state=STATE)

R = helpers.make_repo(ROOT, "repo")
put(R, "README.md", "r\n")
BASE = helpers.commit(R, "base")
put(R, "src/e.py", "line1\nline2 fixed\nline3\n")
BIG_LINES = ["line {:04d} ".format(i).ljust(30, "x") for i in range(1, 3001)]
put(R, "src/big.py", "".join(x + "\n" for x in BIG_LINES))
put(R, "docs/superpowers/plans/p.md", "plan\n")
FINAL = helpers.commit(R, "final")
TREE = git(R, "rev-parse", FINAL + "^{tree}")
FILES = os.path.join(ROOT, "files")
scratch.export(os.path.join(R, ".git", "objects"), FINAL, FILES)
WORK = os.path.join(ROOT, "work")
F = scratch.build(os.path.join(R, ".git", "objects"), BASE, FILES, WORK, "main", "feat", expect_tree=TREE)
D = {"id": "d00000001", "class": "task", "severity": "P1", "counted": True, "summary": "s", "file": "src/e.py", "line": 2, "failure_scenario": "when",
     "fixes": [], "files": ["src/e.py", "src/big.py", "missing.py"], "at": "x"}

# ---- finding, files_input
is_("finding: only what a judge or an agent may see: no class, no id", sorted(G.finding(D)), ["failure_scenario", "file", "line", "severity", "summary"])
files, cut = G.files_input(WORK, F, D, [])
is_("files_input: the finding's file first, then the fix's, a missing one skipped", [f["path"] for f in files], ["src/e.py", "src/big.py"])
ok("files_input: a long file with no hunk is cut to 60000 characters with a [truncated] line", len(files[1]["text"]) < 60100 and files[1]["text"].endswith("[truncated]\n"), len(files[1]["text"]))
is_("files_input: and is the cut, named", cut, ["src/big.py"])
is_("files_input: a path written ./src/e.py or a/src/e.py is the repository's own", G.files_input(WORK, F, dict(D, file="./src/e.py", files=[]), [])[0][0]["path"], "src/e.py")
files, cut = G.files_input(WORK, F, D, [{"file": "src/big.py", "start": 2000, "end": 2000}])
ok("files_input: a long file with a hunk is its window", files[1]["text"].startswith("[lines 1850-2150 of 3000]\n") and cut == [], (files[1]["text"][:40], cut))
files, cut = G.files_input(WORK, F, dict(D, file="./src/big.py", line=1000, files=[]), [])
ok("files_input: the finding's line under a ./ path anchors the normalised file", files[0]["text"].startswith("[lines 850-1150 of 3000]\n") and cut == [], (files[0]["text"][:40], cut))

# ---- validate: a question keyed by what the judge sees
counts = __import__("collections").Counter()
HUNKS = []
jid, ans = G.validate(STATE, WORK, F, D, HUNKS, counts)
is_("validate: no answer yet is None", ans, None)
ok("validate: the id is the defect and 12 hex digits of the input's digest", re.match(r"\Ad00000001-[0-9a-f]{12}\Z", jid) is not None, jid)
doc = C.jload(os.path.join(STATE, "judge-present", jid + ".json"))
is_("validate: the input is the finding and the files, as a list", (sorted(doc), [f["path"] for f in doc["files"]]), (["files", "finding"], ["src/e.py", "src/big.py"]))
is_("validate: the id is the digest of exactly that input", jid, G.question_id("d00000001", doc))
is_("validate: asking again is the same question, written once", (G.validate(STATE, WORK, F, D, HUNKS, counts)[0], counts["judge-present"]), (jid, 1))
for given, want in (("yes", "yes"), ("no", "no")):
    C.jsave(os.path.join(STATE, "judge-present", jid + ".answer.json"), {"answer": given})
    is_("validate: the answer {!r} is {!r}".format(given, want), G.validate(STATE, WORK, F, D, HUNKS, counts)[1], want)
C.jsave(os.path.join(STATE, "judge-present", jid + ".answer.json"), {"answer": "maybe"})
is_("validate: an answer that is not yes, no or unclear is not taken for 'unclear': there is none, and it is set aside",
    (G.validate(STATE, WORK, F, D, HUNKS, counts)[1], os.path.exists(os.path.join(STATE, "judge-present", jid + ".answer.json")),
     C.jload(os.path.join(STATE, "judge-present", jid + ".rejected-1.answer.json"))), (None, False, {"answer": "maybe"}))
C.jsave(os.path.join(STATE, "judge-present", jid + ".answer.json"), {"answer": "unclear"})
is_("validate: the answer 'unclear' is 'unclear'", G.validate(STATE, WORK, F, D, HUNKS, counts)[1], "unclear")
put(R, "src/e.py", "line1\nline2 changed\nline3\n")
OTHER = helpers.commit(R, "other")
git(WORK, "fetch", "-q", R, OTHER)
jid2, ans2 = G.validate(STATE, WORK, OTHER, D, HUNKS, counts)
ok("validate: another tree is another question, with its own id, unanswered", jid2 != jid and ans2 is None, (jid, jid2))
is_("validate: and the first question keeps its input and its answer: nothing is set aside",
    (C.jload(os.path.join(STATE, "judge-present", jid + ".json")) == doc, C.jload(os.path.join(STATE, "judge-present", jid + ".answer.json")),
     sorted(n for n in os.listdir(os.path.join(STATE, "judge-present")) if "stale" in n)), (True, {"answer": "unclear"}, []))
is_("validate: back on the first tree, the first answer serves", G.validate(STATE, WORK, F, D, HUNKS, counts), (jid, "unclear"))

# ---- validate_window, validate_fallback, cut_reasked_old_kept
CUTS = os.path.join(STATE, "cuts", "judge-present")
is_("validate_fallback: with no hunk in big.py and a line only in e.py, the long file is cut from the top and the question records it",
    C.jload(os.path.join(CUTS, jid + ".json")), {"site": "validation", "files": ["src/big.py"]})
is_("validate_fallback: the input's big.py ends [truncated]", C.jload(os.path.join(STATE, "judge-present", jid + ".json"))["files"][1]["text"].endswith("[truncated]\n"), True)
WIN = [{"file": "src/big.py", "start": 2000, "end": 2000}]
wid, _ = G.validate(STATE, WORK, F, D, WIN, counts)
wdoc = C.jload(os.path.join(STATE, "judge-present", wid + ".json"))
is_("validate_window: a hunk at line 2000 gives the window around it", wdoc["files"][1]["text"].split("\n")[0], "[lines 1850-2150 of 3000]")
ok("validate_window: it is another question than the cut one, and no cut record is made for it", wid != jid and not os.path.exists(os.path.join(CUTS, wid + ".json")), (wid, jid))
is_("cut_reasked_old_kept: the answer already given to the cut-from-top question stays on disk under its old id", C.jload(os.path.join(STATE, "judge-present", jid + ".answer.json")), {"answer": "unclear"})
ok("cut_reasked_old_kept: and the windowed question, with its own id, is unanswered", G.validate(STATE, WORK, F, D, WIN, counts) == (wid, None) and wid != jid)
is_("cut_reasked_old_kept: the cut question's input is untouched", C.jload(os.path.join(STATE, "judge-present", jid + ".json")), doc)

# ---- tree_patches, recreation
a_ = Namespace(state=STATE)
RID = G.recreation_id("d00000001", TREE)
is_("recreation_id: the defect and the first 12 hex digits of the base's tree id", RID, "d00000001-" + TREE[:12])
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
is_("recreation: before the agent signals it is finished, the recreation waits for the agent", (got["kind"], got["wait"], got["rid"]), ("agent", "d00000001", RID))
TREE_DIR = os.path.join(STATE, "recreate", RID, "tree")
brief = C.jload(os.path.join(STATE, "recreate", RID + ".json"))
is_("recreation: the brief is {finding, fix, tree}", (sorted(brief), brief["fix"]), (["finding", "fix", "tree"], "FIX TEXT"))
ok("recreation: and the tree is a plain copy of the base tree", open(os.path.join(TREE_DIR, "src", "e.py")).read() == "line1\nline2 fixed\nline3\n"
   and not os.path.exists(os.path.join(TREE_DIR, ".git")))
text = open(os.path.join(STATE, "recreate", RID + ".brief.md")).read()
ok("recreation: the agent's brief names the three paths and what to do", brief["tree"] in text and "create an empty file" in text and "Do not use git" in text, text)
first = open(os.path.join(STATE, "recreate", RID + ".brief.md")).read()
G.recreation(a_, WORK, F, D, "OTHER FIX TEXT", counts)
is_("recreation: the briefs are written once", open(os.path.join(STATE, "recreate", RID + ".brief.md")).read(), first)
put(os.path.join(STATE, "recreate", RID), "done", "")
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
is_("recreation: finished with nothing edited, it changed nothing", (got["kind"], got["why"]), ("unassessable", "the recreation changed nothing"))
put(TREE_DIR, "src/e.py", "line1\nline2 BROKEN\nline3\n")
put(TREE_DIR, "docs/superpowers/plans/p.md", "an edit of the docs\n")
os.unlink(os.path.join(STATE, "recreated", RID + ".patch"))
real_to_bytes, made = G.P.to_bytes, []


def crash_on_patch(body):
    made.append(body)
    if len(made) == 2:      # the repair patch is written; the process dies while the patch is
        raise KeyboardInterrupt("killed")
    return real_to_bytes(body)


G.P.to_bytes = crash_on_patch
try:
    G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
except KeyboardInterrupt:
    pass
G.P.to_bytes = real_to_bytes
ok("recreation_atomic: a process killed while recreated/<d>.patch is written leaves no patch file: it is never read half-made (as 'changed nothing') "
   "and cleanup, which keys on it, keeps the tree", not os.path.exists(os.path.join(STATE, "recreated", RID + ".patch")))
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
same = got["wait"]
ok("recreation: an edit waits for judge-same, a question keyed by its input", got["kind"] == "judge" and same == G.question_id("d00000001", C.jload(os.path.join(STATE, "judge-same", same + ".json"))), got)
ok("recreation: the patch is the base tree against the edit, outside docs/superpowers", "+line2 BROKEN" in open(os.path.join(STATE, "recreated", RID + ".patch")).read()
   and "docs/superpowers" not in open(os.path.join(STATE, "recreated", RID + ".patch")).read())
C.jsave(os.path.join(STATE, "judge-same", same + ".answer.json"), {"answer": "no"})
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
is_("recreation: judge-same no is unassessable", (got["kind"], got["why"]), ("unassessable", "the judge did not find the same defect (no)"))
C.jsave(os.path.join(STATE, "judge-same", same + ".answer.json"), {"answer": "yes"})
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
is_("recreation: judge-same yes gives the patch and the reverse patch", (got["kind"], "+line2 BROKEN" in got["patch"], "-line2 BROKEN" in got["reverse"]), ("candidate", True, True))

# ---- a recreation made against a base: its patch is that base's tree against the edit
put(R, "src/e.py", "line1\nline2 reverted\nline3\n")
BASED = helpers.commit(R, "a base that reverted one line")
git(WORK, "fetch", "-q", R, BASED)
EDITED = os.path.join(ROOT, "based-copy")
scratch.export(os.path.join(R, ".git", "objects"), BASED, EDITED)
put(EDITED, "src/e.py", "line1\nline2 reverted\nline3 edited\n")
patch, reverse = G.tree_patches(WORK, BASED, EDITED)
ok("recreation_patches_against_base: an edit of a file the base already reverted shows only the edit",
   "+line3 edited" in patch and "-line3\n" in patch and "line2 fixed" not in patch and "+line2 reverted" not in patch, patch)
ok("recreation_patches_against_base: and the reverse patch undoes only it", "-line3 edited" in reverse and "+line3\n" in reverse and "line2 fixed" not in reverse, reverse)
