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
put(R, "src/big.py", "x = 1\n" * 30000)
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
files = G.files_input(WORK, F, D)
is_("files_input: the finding's file first, then the fix's, a missing one skipped", [f["path"] for f in files], ["src/e.py", "src/big.py"])
ok("files_input: each file is capped at 60000 characters with a [truncated] line", len(files[1]["text"]) < 60100 and files[1]["text"].endswith("[truncated]\n"), len(files[1]["text"]))
is_("files_input: a path written ./src/e.py or a/src/e.py is the repository's own", G.files_input(WORK, F, dict(D, file="./src/e.py", files=[]))[0]["path"], "src/e.py")

# ---- validate: a question keyed by what the judge sees
counts = __import__("collections").Counter()
jid, ans = G.validate(STATE, WORK, F, D, counts)
is_("validate: no answer yet is None", ans, None)
ok("validate: the id is the defect and 12 hex digits of the input's digest", re.match(r"\Ad00000001-[0-9a-f]{12}\Z", jid) is not None, jid)
doc = C.jload(os.path.join(STATE, "judge-present", jid + ".json"))
is_("validate: the input is the finding and the files, as a list", (sorted(doc), [f["path"] for f in doc["files"]]), (["files", "finding"], ["src/e.py", "src/big.py"]))
is_("validate: the id is the digest of exactly that input", jid, G.question_id("d00000001", doc))
is_("validate: asking again is the same question, written once", (G.validate(STATE, WORK, F, D, counts)[0], counts["judge-present"]), (jid, 1))
for given, want in (("yes", "yes"), ("no", "no"), ("unclear", "unclear"), ("maybe", "unclear")):
    C.jsave(os.path.join(STATE, "judge-present", jid + ".answer.json"), {"answer": given})
    is_("validate: the answer {!r} is {!r}".format(given, want), G.validate(STATE, WORK, F, D, counts)[1], want)
put(R, "src/e.py", "line1\nline2 changed\nline3\n")
OTHER = helpers.commit(R, "other")
git(WORK, "fetch", "-q", R, OTHER)
jid2, ans2 = G.validate(STATE, WORK, OTHER, D, counts)
ok("validate: another tree is another question, with its own id, unanswered", jid2 != jid and ans2 is None, (jid, jid2))
is_("validate: and the first question keeps its input and its answer: nothing is set aside",
    (C.jload(os.path.join(STATE, "judge-present", jid + ".json")) == doc, C.jload(os.path.join(STATE, "judge-present", jid + ".answer.json")),
     sorted(n for n in os.listdir(os.path.join(STATE, "judge-present")) if "stale" in n)), (True, {"answer": "maybe"}, []))
is_("validate: back on the first tree, the first answer serves", G.validate(STATE, WORK, F, D, counts), (jid, "unclear"))

# ---- tree_patches, recreation
TREE_DIR = os.path.join(STATE, "recreate", "d00000001", "tree")
a_ = Namespace(state=STATE)
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
is_("recreation: before the agent signals it is finished, the recreation waits for the agent", (got["kind"], got["wait"]), ("agent", "d00000001"))
brief = C.jload(os.path.join(STATE, "recreate", "d00000001.json"))
is_("recreation: the brief is {finding, fix, tree}", (sorted(brief), brief["fix"]), (["finding", "fix", "tree"], "FIX TEXT"))
ok("recreation: and the tree is a plain copy of the final tree", open(os.path.join(TREE_DIR, "src", "e.py")).read() == "line1\nline2 fixed\nline3\n"
   and not os.path.exists(os.path.join(TREE_DIR, ".git")))
text = open(os.path.join(STATE, "recreate", "d00000001.brief.md")).read()
ok("recreation: the agent's brief names the three paths and what to do", brief["tree"] in text and "create an empty file" in text and "Do not use git" in text, text)
first = open(os.path.join(STATE, "recreate", "d00000001.brief.md")).read()
G.recreation(a_, WORK, F, D, "OTHER FIX TEXT", counts)
is_("recreation: the briefs are written once", open(os.path.join(STATE, "recreate", "d00000001.brief.md")).read(), first)
put(os.path.join(STATE, "recreate", "d00000001"), "done", "")
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
is_("recreation: finished with nothing edited, it changed nothing", (got["kind"], got["why"]), ("unassessable", "the recreation changed nothing"))
put(TREE_DIR, "src/e.py", "line1\nline2 BROKEN\nline3\n")
put(TREE_DIR, "docs/superpowers/plans/p.md", "an edit of the docs\n")
os.unlink(os.path.join(STATE, "recreated", "d00000001.patch"))
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
same = got["wait"]
ok("recreation: an edit waits for judge-same, a question keyed by its input", got["kind"] == "judge" and same == G.question_id("d00000001", C.jload(os.path.join(STATE, "judge-same", same + ".json"))), got)
ok("recreation: the patch is the final tree against the edit, outside docs/superpowers", "+line2 BROKEN" in open(os.path.join(STATE, "recreated", "d00000001.patch")).read()
   and "docs/superpowers" not in open(os.path.join(STATE, "recreated", "d00000001.patch")).read())
C.jsave(os.path.join(STATE, "judge-same", same + ".answer.json"), {"answer": "no"})
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
is_("recreation: judge-same no is unassessable", (got["kind"], got["why"]), ("unassessable", "the judge did not find the same defect (no)"))
C.jsave(os.path.join(STATE, "judge-same", same + ".answer.json"), {"answer": "yes"})
got = G.recreation(a_, WORK, F, D, "FIX TEXT", counts)
is_("recreation: judge-same yes gives the patch and the reverse patch", (got["kind"], "+line2 BROKEN" in got["patch"], "-line2 BROKEN" in got["reverse"]), ("candidate", True, True))
