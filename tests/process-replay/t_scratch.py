import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, git_ok, is_, ok, put

ROOT = helpers.tmp_root()
# A distinctive operator identity, so any trace of it in a scratch repository shows.
OPERATOR = "Operator Zed"
OPERATOR_MAIL = "operator.zed@host.example"
with open(os.path.join(ROOT, "operator.gitconfig"), "w") as f:
    f.write("[user]\n\tname = {}\n\temail = {}\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n".format(OPERATOR, OPERATOR_MAIL))
os.environ["GIT_CONFIG_GLOBAL"] = os.path.join(ROOT, "operator.gitconfig")
os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
os.environ["GIT_CEILING_DIRECTORIES"] = ROOT
helpers.setup()
from process_replay import common, scratch  # noqa: E402

SRC = helpers.make_repo(ROOT, "src")
put(SRC, "base.txt", "base\n")
put(SRC, "lib.py", "def f(x):\n    return x + 2\n")
B = helpers.commit(SRC, "base")
git(SRC, "checkout", "-q", "-b", "feat")
put(SRC, "feature.txt", "feature\n")
C1 = helpers.commit(SRC, "feature")
put(SRC, "lib.py", "def f(x):\n    return x + 1  # FIXED\n")
C2 = helpers.commit(SRC, "fix")
put(SRC, "later.txt", "later\n")
T = helpers.commit(SRC, "later")
OBJECTS = os.path.join(SRC, ".git", "objects")
TREE1 = git(SRC, "rev-parse", C1 + "^{tree}")


def exported(commit, name):
    dest = os.path.join(ROOT, name)
    scratch.export(OBJECTS, commit, dest)
    return dest


FILES = exported(C1, "files1")
OUT = os.path.join(ROOT, "out1")
TIP = scratch.build(OBJECTS, B, FILES, OUT, "main", "feat", expect_tree=TREE1)

# ---- scratch_hides_later_fix
ok("scratch_hides_later_fix: the later fix commit is not in the scratch repository", not git_ok(OUT, "cat-file", "-e", C2))
ok("scratch_hides_later_fix: the later tip commit is not in the scratch repository", not git_ok(OUT, "cat-file", "-e", T))
unreach = git(OUT, "fsck", "--unreachable", "--no-reflogs")
ok("scratch_hides_later_fix: fsck --unreachable names neither commit", C2 not in unreach and T not in unreach, unreach)


def blobs_with(repo, needle):
    hits = []
    for line in git(repo, "rev-list", "--all", "--objects").splitlines():
        sha = line.split()[0]
        if git(repo, "cat-file", "-t", sha) == "blob" and needle in git(repo, "cat-file", "-p", sha):
            hits.append(sha)
    return hits


ok("scratch_hides_later_fix: no reachable blob holds the fix", blobs_with(OUT, "FIXED") == [], blobs_with(OUT, "FIXED"))
ok("scratch_hides_later_fix: control: the source repository does", blobs_with(SRC, "FIXED") != [])
ok("scratch_hides_later_fix: no alternates", not os.path.exists(os.path.join(OUT, ".git", "objects", "info", "alternates")))
is_("scratch_hides_later_fix: no remote", git(OUT, "remote"), "")


def object_ids(repo):
    stored = set(git(repo, "cat-file", "--batch-all-objects", "--batch-check=%(objectname)").split())
    reachable = set(l.split()[0] for l in git(repo, "rev-list", "--objects", "--all").splitlines())
    return stored, reachable


stored, reachable = object_ids(OUT)
ok("scratch_hides_later_fix: the whole object store is the base history plus the tip, nothing unreachable", stored == reachable,
   sorted(stored ^ reachable)[:5])
ctl_out = os.path.join(ROOT, "ctl-out")
shutil.copytree(OUT, ctl_out, symlinks=True)
subprocess.run(["git", "-C", ctl_out, "hash-object", "-w", "--stdin"], input=b"FIXED\n", capture_output=True)
stored2, reachable2 = object_ids(ctl_out)
ok("scratch_hides_later_fix: control: a loose unreachable blob holding the fix fails the same check", stored2 != reachable2)
# the control that makes the checks above mean something: a clone borrowing the source's objects reaches the fix
borrowed = os.path.join(ROOT, "borrowed")
git(ROOT, "init", "-q", borrowed)
os.makedirs(os.path.join(borrowed, ".git", "objects", "info"), exist_ok=True)
with open(os.path.join(borrowed, ".git", "objects", "info", "alternates"), "w") as f:
    f.write(OBJECTS + "\n")
ok("scratch_hides_later_fix: control: alternates would resolve the fix", git_ok(borrowed, "cat-file", "-e", C2))

# ---- scratch_refs
is_("scratch_refs: refs/heads/main is the base", git(OUT, "rev-parse", "refs/heads/main"), B)
is_("scratch_refs: HEAD is refs/heads/feat", git(OUT, "symbolic-ref", "HEAD"), "refs/heads/feat")
is_("scratch_refs: refs/heads/feat is the tip", git(OUT, "rev-parse", "refs/heads/feat"), TIP)
is_("scratch_refs: the tip's parent is the base", git(OUT, "rev-parse", TIP + "^"), B)
is_("scratch_refs: the tip is a single commit past the base", git(OUT, "rev-list", "--count", B + ".." + TIP), "1")
is_("scratch_refs: no ref but the two branches", git(OUT, "for-each-ref", "--format=%(refname)"), "refs/heads/feat\nrefs/heads/main")
plain = os.path.join(ROOT, "plain")
shutil.copytree(OUT, plain, symlinks=True, ignore=shutil.ignore_patterns(".git"))
rc = subprocess.run(["git", "diff", "--no-index", "--exit-code", "--quiet", FILES, plain]).returncode
is_("scratch_refs: the checkout is the files dir", rc, 0)
is_("scratch_refs: the work tree is clean", git(OUT, "status", "--porcelain"), "")
out2 = os.path.join(ROOT, "out2")
tip2 = scratch.build(OBJECTS, B, FILES, out2, "main", "feat", dest_ref="origin/main", expect_tree=TREE1)
is_("scratch_refs: dest_ref gives refs/remotes/origin/main at the base", git(out2, "rev-parse", "refs/remotes/origin/main"), B)
is_("scratch_refs: dest_ref makes no remote", git(out2, "remote"), "")
is_("scratch_refs: the same tree gives the same tip", tip2, TIP)
out3 = os.path.join(ROOT, "out3")
tip3 = scratch.build(OBJECTS, B, FILES, out3, "main", "main", expect_tree=TREE1)
is_("scratch_refs: a branch that is the destination has the tip", (git(out3, "rev-parse", "refs/heads/main"), git(out3, "symbolic-ref", "HEAD")),
    (tip3, "refs/heads/main"))

# ---- scratch_commit_neutral
fmt = git(OUT, "log", "-1", "--format=%s|%an|%ae|%cn|%ce", TIP)
is_("scratch_commit_neutral: message and identity", fmt, "Change under review|Developer|developer@example.invalid|Developer|developer@example.invalid")
base_ct = int(git(OUT, "log", "-1", "--format=%ct", B))
is_("scratch_commit_neutral: dated an hour after the base", (int(git(OUT, "log", "-1", "--format=%ct", TIP)),
                                                              int(git(OUT, "log", "-1", "--format=%at", TIP))), (base_ct + 3600, base_ct + 3600))

ok("scratch_commit_neutral: no reflog", not os.path.exists(os.path.join(OUT, ".git", "logs")))
leaks = []
for d, dirs, files in os.walk(os.path.join(OUT, ".git")):
    if os.path.basename(d) == "objects" and os.path.dirname(d) == os.path.join(OUT, ".git"):
        dirs[:] = []
        continue
    for name in files:
        data = open(os.path.join(d, name), "rb").read()
        if OPERATOR.encode() in data or OPERATOR_MAIL.encode() in data:
            leaks.append(os.path.join(d, name))
is_("scratch_commit_neutral: nothing outside the object store names the operator", leaks, [])
ok("scratch_commit_neutral: control: the source repository's reflog does", OPERATOR in open(os.path.join(SRC, ".git", "logs", "HEAD")).read())

# ---- scratch_tree_identity
tsrc = helpers.make_repo(ROOT, "tsrc")
put(tsrc, "keep.txt", "keep\n")
put(tsrc, ".gitignore", "")
tb = helpers.commit(tsrc, "base")
put(tsrc, ".gitignore", "*.log\n")
put(tsrc, "x.log", "ignored but tracked\n")
put(tsrc, "tool.sh", "#!/bin/sh\necho hi\n", mode=0o755)
os.symlink("tool.sh", os.path.join(tsrc, "link"))
git(tsrc, "add", "-A")
git(tsrc, "add", "-f", "x.log")
git(tsrc, "commit", "-q", "-m", "work")
tw = git(tsrc, "rev-parse", "HEAD")
tobjects = os.path.join(tsrc, ".git", "objects")
ttree = git(tsrc, "rev-parse", tw + "^{tree}")
tfiles = os.path.join(ROOT, "tfiles")
scratch.export(tobjects, tw, tfiles)
ok("scratch_tree_identity: export keeps the ignored tracked file", os.path.exists(os.path.join(tfiles, "x.log")))
ok("scratch_tree_identity: export keeps the symlink", os.path.islink(os.path.join(tfiles, "link")) and os.readlink(os.path.join(tfiles, "link")) == "tool.sh")
ok("scratch_tree_identity: export keeps the executable bit", os.access(os.path.join(tfiles, "tool.sh"), os.X_OK))
tout = os.path.join(ROOT, "tout")
ttip = scratch.build(tobjects, tb, tfiles, tout, "main", "work", expect_tree=ttree)
is_("scratch_tree_identity: the tip's tree is the source commit's", git(tout, "rev-parse", ttip + "^{tree}"), ttree)
is_("scratch_tree_identity: x.log is tracked", git(tout, "ls-tree", "--name-only", ttip, "x.log"), "x.log")
modes = sorted(l.split()[0] for l in git(tout, "ls-tree", ttip).splitlines() if l.split()[-1] in ("tool.sh", "link"))
is_("scratch_tree_identity: modes are kept", modes, ["100755", "120000"])
try:
    scratch.build(tobjects, tb, tfiles, os.path.join(ROOT, "tout2"), "main", "work", expect_tree=git(tsrc, "rev-parse", tb + "^{tree}"))
    raised = False
except common.Failed:
    raised = True
ok("scratch_tree_identity: a wrong expect_tree raises Failed", raised)
try:
    scratch.build(tobjects, tb, tfiles, os.path.join(ROOT, "tout3"), "main", "work", expect_tree=None)
    raised = False
except common.Failed:
    raised = True
ok("scratch_tree_identity: expect_tree=None raises Failed", raised)
try:
    scratch.build(tobjects, tb, tfiles, os.path.join(ROOT, "tout4"), "main", "work")
    raised = False
except TypeError:
    raised = True
ok("scratch_tree_identity: expect_tree is required", raised)

# ---- scratch_pack_cache
cache = os.path.join(ROOT, "cache")
c1 = scratch.build(OBJECTS, B, FILES, os.path.join(ROOT, "oc1"), "main", "feat", expect_tree=TREE1, cache=cache)
c2 = scratch.build(OBJECTS, B, FILES, os.path.join(ROOT, "oc2"), "main", "feat", expect_tree=TREE1, cache=cache)
packs = [n for n in os.listdir(cache) if n.endswith(".pack")]
is_("scratch_pack_cache: one pack serves both builds", (len(packs), c1, c2), (1, TIP, TIP))
ok("scratch_pack_cache: a cached build still hides the fix", not git_ok(os.path.join(ROOT, "oc2"), "cat-file", "-e", C2))

# ---- commit_patch_one_commit
patch = git(SRC, "diff", C1, C2) + "\n"
before = git(OUT, "rev-parse", "HEAD")
new = scratch.commit_patch(OUT, patch, "Fix the offset")
ok("commit_patch_one_commit: returns the new commit", new is not None and new == git(OUT, "rev-parse", "HEAD"), new)
is_("commit_patch_one_commit: one commit on the tip", (git(OUT, "rev-list", "--count", before + "..HEAD"), git(OUT, "rev-parse", "HEAD^")), ("1", before))
is_("commit_patch_one_commit: the given message", git(OUT, "log", "-1", "--format=%s"), "Fix the offset")
is_("commit_patch_one_commit: neutral identity", git(OUT, "log", "-1", "--format=%an <%ae>"), "Developer <developer@example.invalid>")
is_("commit_patch_one_commit: the tree is the fixed commit's", git(OUT, "rev-parse", "HEAD^{tree}"), git(SRC, "rev-parse", C2 + "^{tree}"))
is_("commit_patch_one_commit: the work tree is clean", git(OUT, "status", "--porcelain"), "")
head = git(OUT, "rev-parse", "HEAD")
with open(os.path.join(OUT, "lib.py")) as f:
    lib_before = f.read()
bad = "diff --git a/lib.py b/lib.py\n--- a/lib.py\n+++ b/lib.py\n@@ -1,2 +1,2 @@\n def nothing(y):\n-    return y\n+    return y * 2\n"
is_("commit_patch_one_commit: a patch that does not apply returns None", scratch.commit_patch(OUT, bad, "Nope"), None)
with open(os.path.join(OUT, "lib.py")) as f:
    lib_after = f.read()
is_("commit_patch_one_commit: HEAD and the work tree are unchanged", (git(OUT, "rev-parse", "HEAD"), lib_after, git(OUT, "status", "--porcelain")),
    (head, lib_before, ""))
is_("commit_patch_one_commit: an empty patch returns None", scratch.commit_patch(OUT, "", "Nothing"), None)
