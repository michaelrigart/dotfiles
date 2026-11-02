import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, git_ok, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import patches as P  # noqa: E402

ROOT = helpers.tmp_root()
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "xdg")
os.makedirs(os.environ["XDG_STATE_HOME"])
NO_SNAPSHOT = os.path.join(ROOT, "no-snapshot")

R = helpers.make_repo(ROOT, "repo")
LINES = ["line{}".format(i) for i in range(1, 41)]
SS = lambda lines: "".join(x + "\n" for x in lines)
put(R, "big.txt", SS(LINES))
put(R, "docs/superpowers/plans/p.md", "plan\n")
put(R, "bin.dat", b"\0\1\2\3")
A = helpers.commit(R, "a")
new = list(LINES)
new[2] = "line3 CHANGED"                    # hunk 1 (replaces a line)
new[19:19] = ["added 1", "added 2"]         # hunk 2 (adds two lines)
new[-3] = "line38 CHANGED"                  # hunk 3
put(R, "big.txt", SS(new))
put(R, "docs/superpowers/plans/p.md", "plan changed\n")
put(R, "bin.dat", b"\0\1\2\4")
put(R, "new.txt", "brand new\n")
B = helpers.commit(R, "b")
VIEW = C.view(os.path.join(ROOT, "state"), os.path.join(R, ".git"), NO_SNAPSHOT)

# ---- fix_patch and diff
text = P.fix_patch(VIEW, A, B)
ok("docs_pinned: fix_patch holds the code of the range and no docs/superpowers path", "big.txt" in text and "docs/superpowers" not in text, text)
ok("revert_whole_with_tests: fix_patch holds a binary change as a binary patch", "GIT binary patch" in text and "bin.dat" in text)
p = subprocess.run(["git", "-C", R, "apply", "--check", "-R", "-"], input=text.encode("utf-8", "surrogateescape"), capture_output=True)
is_("fix_patch: the text reverts on the second tree as it stands", p.returncode, 0)

# ---- parse_patch, items
secs = P.parse_patch(text)
is_("parse_patch: one section per file, in git's order", [s["file"] for s in secs], ["big.txt", "bin.dat", "new.txt"])
is_("parse_patch: the three hunks of the first file, with their numbers", [(h["old"], h["ns"], h["nl"]) for h in secs[0]["hunks"]][:1], [("1,6", 1, 6)])
is_("parse_patch: a binary file has no hunk, its whole section is its head", (secs[1]["hunks"], any("GIT binary patch" in x for x in secs[1]["head"])), ([], True))
items = P.item_list(secs)
is_("item_list: each hunk, and a file with none as one item", [(si, hi) for si, hi in items][-3:], [(0, len(secs[0]["hunks"]) - 1), (1, None), (2, 0)])
ok("item_text: a hunk comes with its file header", P.item_text(secs, items[0]).startswith("diff --git a/big.txt b/big.txt") and "@@ -1,6 +1,6 @@" in P.item_text(secs, items[0]))
is_("files_of: sorted files of a patch", P.files_of(text), ["big.txt", "bin.dat", "new.txt"])

# ---- select
is_("select: every item gives back the patch as it was", P.select(secs, set(items)), text)
n_big = len(secs[0]["hunks"])
last = (0, n_big - 1)
only_last = P.select(secs, {last})
is_("select: a hunk alone has the new-side start taken down by what the hunks above it added", [(h["old"], h["ns"]) for s in P.parse_patch(only_last) for h in s["hunks"]],
    [(secs[0]["hunks"][-1]["old"], int(secs[0]["hunks"][-1]["old"].split(",")[0]))])
subprocess.run(["git", "-C", R, "read-tree", A], env=dict(os.environ, GIT_INDEX_FILE=os.path.join(ROOT, "idx")), check=True)
p = subprocess.run(["git", "-C", R, "apply", "--check", "--cached", "-"], input=only_last.encode(), capture_output=True, env=dict(os.environ, GIT_INDEX_FILE=os.path.join(ROOT, "idx")))
is_("select: and the patch of that hunk alone applies to the first tree", p.returncode, 0)
is_("select: nothing chosen is nothing", P.select(secs, set()), "")
is_("select: a file with no hunk is kept whole when chosen", "GIT binary patch" in P.select(secs, {(1, None)}), True)

# ---- locate
work = os.path.join(ROOT, "work")
subprocess.run(["git", "clone", "-q", R, work], check=True, capture_output=True)
hunks, why = P.locate(work, A, text)
ok("locate: the forward patch of a change applies to the tree before it and reports old and new lines", hunks is not None and hunks[0]["file"] == "big.txt"
   and (hunks[0]["start"], hunks[0]["end"], hunks[0]["new_start"], hunks[0]["new_end"]) == (1, 6, 1, 6), (hunks, why))
hunks, why = P.locate(work, B, text)
is_("locate: a patch that does not apply to the tree is None and says why", (hunks, bool(why)), (None, True))
hunks, _ = P.locate(work, A, text)
new_file = [h for h in hunks if h["file"] == "new.txt"]
is_("locate: a file the patch adds is at line 1 of nothing, then lines 1 to 1", [(h["start"], h["end"], h["new_start"], h["new_end"]) for h in new_file], [(1, 1, 1, 1)])
