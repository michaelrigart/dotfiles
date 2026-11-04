"""relocate-snapshot: rename the snapshot directory and rewrite the state's references to it (spec 14.3 a, ruling R10).

Every case builds its own synthetic state under a temporary directory: views whose alternates name a fixture snapshot, a
branches.json, and records that mention the snapshot's path as recorded text (a run's `leak` verdict and prose, reviews.json, a
copied transcript), which a relocation must leave alone. The command is driven through the CLI module, in this process.
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import relocate as R  # noqa: E402

spec = importlib.util.spec_from_file_location("process_replay_cli", os.path.join(helpers.SCRIPTS, "process-replay.py"))
CLI = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CLI)


def cli(*argv):
    """(exit status, output) of `process-replay.py relocate-snapshot <argv>` run in this process."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        rc = CLI.main(["relocate-snapshot"] + list(argv))
    return rc, out.getvalue()


def read(path):
    with open(path, "rb") as f:
        return f.read()


class Fx:
    """One synthetic state: OLD holds 2026-11-02/chezmoi/objects (a copy of a fixture repository's), NEW does not exist yet."""

    def __init__(self):
        self.root = helpers.tmp_root()
        self.old = os.path.join(self.root, "under-claude-projects", "snapshot")
        self.new = os.path.join(self.root, "state-home", "process-replay", "snapshot")
        self.state = os.path.join(self.root, "state")
        self.day = os.path.join(self.old, "2026-11-02")
        repo = helpers.make_repo(self.root, "chezmoi")
        put(repo, "a.txt", "one\n")
        self.tip = helpers.commit(repo, "one")
        self.gitdir = os.path.join(repo, ".git")
        os.makedirs(os.path.join(self.day, "chezmoi"))
        shutil.copytree(os.path.join(self.gitdir, "objects"), os.path.join(self.day, "chezmoi", "objects"))
        other = helpers.make_repo(self.root, "other")
        put(other, "b.txt", "two\n")
        self.tip2 = helpers.commit(other, "two")
        self.gitdir2 = os.path.join(other, ".git")
        # two views: one reads OLD's objects, one an original's
        self.view = C.view(self.state, self.gitdir, self.day)
        self.view2 = C.view(self.state, self.gitdir2, self.day)
        self.objects = os.path.join(self.day, "chezmoi", "objects")
        branch = lambda i, objects, view, tip: {"id": i, "repo": self.gitdir, "objects": objects, "view": view, "final_tip": tip,
                                                "branch": "b-" + i, "candidate": True}
        self.branches = {"branches": [branch("b1", self.objects, self.view, self.tip), branch("b2", self.objects, self.view, self.tip),
                                      branch("b3", os.path.join(self.gitdir2, "objects"), self.view2, self.tip2)],
                         "ambiguous_reviews": [], "unresolved_ranges": 0, "off_branch_ranges": 0}
        C.jsave(os.path.join(self.state, "branches.json"), self.branches)
        self.records = {
            "runs/case1/ab12cd34/state.json": json.dumps({"leak": [self.old], "findings": [{"summary": "it read {}/2026-11-02 once".format(self.old)}]}),
            "reviews.json": json.dumps({"groups": [{"note": "snapshot at " + self.old}]}),
            "transcripts/x.jsonl": json.dumps({"text": "cat {}/2026-11-02/chezmoi/objects/info".format(self.old)}) + "\n",
        }
        for rel, text in self.records.items():
            put(self.state, rel, text)

    def args(self, *extra, to=True):
        return ["--state", self.state, "--from", self.old] + (["--to", self.new] if to else []) + list(extra)

    def alt(self, view):
        return read(os.path.join(view, "objects", "info", "alternates")).decode()

    def branches_doc(self):
        return json.load(open(os.path.join(self.state, "branches.json")))

    def untouched(self):
        return {rel: read(os.path.join(self.state, rel)) for rel in self.records}

    def snap(self, strict=False):
        """What a refusal must leave as it found it. run.lock, made by the lock a command holds, is left out unless `strict`."""
        return ([r for r in helpers.listing(self.state) if strict or r[0] != "run.lock"], helpers.listing(self.old) if os.path.exists(self.old) else None,
                os.path.exists(os.path.dirname(self.new)), os.path.exists(self.new))


# ---------------------------------------------------------------- the two rewriting rules
doc = {"objects": "/o/snap/2026-11-02/x", "list": ["/o/snap", "/o/snapper", "/o/snap-x/y", "see /o/snap/a in prose"],
       "nested": {"/o/snap/k": [{"p": "/o/snap/deep"}], "n": 3, "none": None, "t": True}}
new_doc, n = R.rewrite_value(doc, "/o/snap", "/n/snap")
is_("rewrite_value: strings that are the path or lie under it get the new prefix, nothing else", new_doc, {
    "objects": "/n/snap/2026-11-02/x", "list": ["/n/snap", "/o/snapper", "/o/snap-x/y", "see /o/snap/a in prose"],
    "nested": {"/n/snap/k": [{"p": "/n/snap/deep"}], "n": 3, "none": None, "t": True}})
is_("rewrite_value: it counts the strings rewritten, keys included", n, 4)
is_("rewrite_value: it does not change its argument", doc["objects"], "/o/snap/2026-11-02/x")
is_("rewrite_value: a value with nothing to rewrite is counted 0", R.rewrite_value({"a": ["/o/other"]}, "/o/snap", "/n/snap"), ({"a": ["/o/other"]}, 0))
text = "/o/snap/2026-11-02/chezmoi/objects\n# /o/snap/note\n/o/snapper/objects\n/o/snap\r\n/elsewhere/objects"
is_("rewrite_alternates: the rule per line, line endings kept", R.rewrite_alternates(text, "/o/snap", "/n/snap"),
    ("/n/snap/2026-11-02/chezmoi/objects\n# /o/snap/note\n/o/snapper/objects\n/n/snap\r\n/elsewhere/objects", 2))
is_("rewrite_alternates: no trailing newline is not added", R.rewrite_alternates("/o/snap/x", "/o/snap", "/n/snap"), ("/n/snap/x", 1))
is_("rewrite_alternates: empty text", R.rewrite_alternates("", "/o/snap", "/n/snap"), ("", 0))

# ---------------------------------------------------------------- dry_run_changes_nothing
f = Fx()
before = f.snap()
rc, out = cli(*f.args("--dry-run"))
is_("dry_run_changes_nothing: exit 0", rc, 0)
ok("dry_run_changes_nothing: it prints 1 view and 2 objects", "1 in views' alternates, 2 in branches.json" in out and "would rewrite 3 references" in out, out)
ok("dry_run_changes_nothing: it prints how many tips it will check", "final tips to check: 2" in out, out)
ok("dry_run_changes_nothing: it names the rename", "would rename: {} -> {}".format(f.old, f.new) in out, out)
is_("dry_run_changes_nothing: the listings of the state and of OLD are unchanged and NEW does not exist", f.snap(), before)
ok("dry_run_changes_nothing: no verification claim", "verified:" not in out, out)
with C.command_locks(f.state, "exclusive"):
    rc, out = cli(*f.args("--dry-run"))
is_("dry_run_changes_nothing: a dry run takes no lock, so one held does not stop it", rc, 0)

# ---------------------------------------------------------------- moves_and_rewrites
f = Fx()
ino = os.stat(f.old).st_ino
recorded = f.untouched()
rc, out = cli(*f.args())
is_("moves_and_rewrites: exit 0", rc, 0)
ok("moves_and_rewrites: it prints the rename, the counts and the verification", "rename: {} -> {}".format(f.old, f.new) in out
   and "rewrote 3 references (1 in views' alternates, 2 in branches.json)" in out
   and "verified: no reference to {} remains in the views or branches.json; every rewritten view resolves its branches' final tips".format(f.old) in out, out)
ok("moves_and_rewrites: it prints how many tips it checked", "final tips to check: 2" in out and "checked 2 final tips" in out, out)
ok("moves_and_rewrites: OLD is gone", not os.path.exists(f.old))
is_("moves_and_rewrites: NEW is OLD's directory (a rename, not a copy)", os.stat(f.new).st_ino, ino)
is_("moves_and_rewrites: the alternates name NEW", f.alt(f.view), os.path.join(f.new, "2026-11-02", "chezmoi", "objects") + "\n")
is_("moves_and_rewrites: a view of an original's objects is as it was", f.alt(f.view2), os.path.join(f.gitdir2, "objects") + "\n")
b = f.branches_doc()["branches"]
is_("moves_and_rewrites: the two branches' objects name NEW", [x["objects"] for x in b[:2]], [os.path.join(f.new, "2026-11-02", "chezmoi", "objects")] * 2)
is_("moves_and_rewrites: a branch of an original's objects is as it was", b[2]["objects"], os.path.join(f.gitdir2, "objects"))
is_("moves_and_rewrites: nothing else in branches.json changed", [dict(x, objects=None) for x in b], [dict(x, objects=None) for x in f.branches["branches"]])
is_("moves_and_rewrites: the run record (leak and prose), reviews.json and the transcript are byte-identical", f.untouched(), recorded)
ok("moves_and_rewrites: the view resolves the branch's final tip through NEW",
   C.git_ok(f.view, "cat-file", "-e", f.tip + "^{commit}"))
ok("moves_and_rewrites: no scratch file is left beside what it wrote", not [n for n in os.listdir(f.state) if ".tmp" in n]
   and not [n for n in os.listdir(os.path.join(f.view, "objects", "info")) if ".tmp" in n])

# a file is written only when it changed: the view of an original's objects keeps its mtime
f = Fx()
m_view2 = os.stat(os.path.join(f.view2, "objects", "info", "alternates")).st_mtime_ns
cli(*f.args())
is_("moves_and_rewrites: a file with nothing to rewrite is not written", os.stat(os.path.join(f.view2, "objects", "info", "alternates")).st_mtime_ns, m_view2)

# ---------------------------------------------------------------- the default destination
f = Fx()
f.new = os.path.join(C.snapshot_home())
rc, out = cli(*f.args(to=False))
is_("default_to: --to defaults to the snapshot home", (rc, os.path.isdir(os.path.join(C.snapshot_home(), "2026-11-02", "chezmoi", "objects"))), (0, True))
ok("default_to: and the alternates name it", f.alt(f.view).startswith(C.snapshot_home() + "/2026-11-02/"), f.alt(f.view))
try:
    cli("--state", f.state)
    required = False
except SystemExit as e:
    required = e.code == 2
ok("from_required: there is no legacy path in code, so --from is required", required)

# ---------------------------------------------------------------- resumes
f = Fx()
os.makedirs(os.path.dirname(f.new))
os.rename(f.old, f.new)
rc, out = cli(*f.args())
ok("resumes: a state renamed but not rewritten is rewritten, and says it was already moved", rc == 0 and "already moved" in out
   and "rewrote 3 references" in out and "verified:" in out, out)
is_("resumes: the alternates name NEW", f.alt(f.view), os.path.join(f.new, "2026-11-02", "chezmoi", "objects") + "\n")
rc, out = cli(*f.args())
ok("resumes: a second run prints already moved, rewrites 0 and exits 0", rc == 0 and "already moved" in out and "rewrote 0 references" in out
   and "verified:" in out, out)

f = Fx()
cli(*f.args())
os.rename(f.new, f.old)                 # rewritten but not renamed
ino = os.stat(f.old).st_ino
rc, out = cli(*f.args())
ok("resumes: a state rewritten but not renamed is renamed, rewriting 0", rc == 0 and "rename: " in out and "already moved" not in out
   and "rewrote 0 references" in out and os.stat(f.new).st_ino == ino and not os.path.exists(f.old), out)

# a write that dies midway: the rerun finishes
f = Fx()
real_jsave = C.jsave
def failing_jsave(path, data):
    raise OSError(28, "No space left on device")
C.jsave = failing_jsave
try:
    rc, out = cli(*f.args())
finally:
    C.jsave = real_jsave
ok("resumes: a failed write of branches.json is a refusal that names the file, not a traceback", rc == 1 and "branches.json" in out, out)
ok("resumes: the directory has moved and the views were rewritten, branches.json still names OLD",
   not os.path.exists(f.old) and os.path.isdir(f.new) and f.alt(f.view).startswith(f.new) and f.branches_doc()["branches"][0]["objects"].startswith(f.old))
rc, out = cli(*f.args())
ok("resumes: a rerun finishes the job (rewrites only branches.json) and verifies", rc == 0 and "already moved" in out
   and "rewrote 2 references (0 in views' alternates, 2 in branches.json)" in out and "verified:" in out, out)
is_("resumes: branches.json names NEW", f.branches_doc()["branches"][0]["objects"], os.path.join(f.new, "2026-11-02", "chezmoi", "objects"))

# ---------------------------------------------------------------- refuses
def refused(name, fx, argv, want, strict=False):
    before = fx.snap(strict)
    recorded = fx.untouched()
    bj = read(os.path.join(fx.state, "branches.json")) if os.path.exists(os.path.join(fx.state, "branches.json")) else None
    rc, out = cli(*argv)
    ok("refuses: {} exits 1 naming why".format(name), rc == 1 and want in out, (rc, out))
    is_("refuses: {} changes nothing".format(name), (fx.snap(strict), fx.untouched(),
        read(os.path.join(fx.state, "branches.json")) if bj is not None else None), (before, recorded, bj))

f = Fx()
os.makedirs(f.new)
refused("both OLD and NEW existing", f, f.args(), "both")
f = Fx()
shutil.rmtree(f.old)
refused("neither OLD nor NEW existing", f, f.args(), "neither")
f = Fx()
real_device = R._device
R._device = lambda p: 1 if p == f.old else 2
try:
    refused("two devices", f, f.args(), "volume")
finally:
    R._device = real_device
f = Fx()
os.unlink(os.path.join(f.state, "branches.json"))
refused("no branches.json", f, f.args(), "branches.json", strict=True)       # strict: not even a run.lock
f = Fx()
refused("--to inside --from", f, ["--state", f.state, "--from", f.old, "--to", os.path.join(f.old, "inner")], "inside")
f = Fx()
refused("--from inside --to", f, ["--state", f.state, "--from", os.path.join(f.old, "2026-11-02"), "--to", f.old], "inside")
f = Fx()
refused("the same path", f, ["--state", f.state, "--from", f.old, "--to", f.old], "inside")
f = Fx()
os.symlink(f.old, f.old + "-link")
refused("a symlink for --from", f, ["--state", f.state, "--from", f.old + "-link", "--to", f.new], "not a directory")

# a view the real device check passes: the temp directory is one volume
f = Fx()
ok("device: the real _device finds the nearest existing ancestor's device",
   R._device(os.path.join(f.new, "deeper")) == os.stat(f.root).st_dev == R._device(f.old))

# ---------------------------------------------------------------- lock
f = Fx()
with C.command_locks(f.state, "shared"):
    before = f.snap()
    rc, out = cli(*f.args())
    ok("lock: while the state is held shared the command exits 1 naming the lock", rc == 1 and "run.lock" in out, (rc, out))
    is_("lock: and changes nothing", f.snap(), before)

# ---------------------------------------------------------------- verification
def with_branches(fx, edit):
    b = fx.branches_doc()
    edit(b["branches"])
    C.jsave(os.path.join(fx.state, "branches.json"), b)


f = Fx()
with_branches(f, lambda bs: bs[1].update(final_tip="0" * 40))
before = f.snap(strict=True)
rc, out = cli(*f.args("--dry-run"))
ok("tip_dry_run: a candidate whose final tip cannot resolve makes the dry run refuse, naming the branch", rc == 1 and "b2" in out, (rc, out))
is_("tip_dry_run: and nothing changed", f.snap(strict=True), before)
before_loose = f.snap()
rc, out = cli(*f.args())
ok("tip_before_move: the real run refuses too, before anything moves", rc == 1 and "b2" in out and "verified:" not in out
   and os.path.isdir(f.old) and not os.path.exists(f.new), (rc, out))
is_("tip_before_move: and nothing changed", f.snap(), before_loose)

f = Fx()
with_branches(f, lambda bs: bs.extend([
    {"id": "n1", "repo": f.gitdir, "objects": f.objects, "view": f.view, "final_tip": "deadbeef" * 5, "candidate": False, "why": "a round tip is gone"},
    {"id": "n2", "repo": f.gitdir, "objects": f.objects, "view": f.view, "final_tip": None, "candidate": False, "why": "no branch name"}]))
rc, out = cli(*f.args())
ok("tip_not_candidate: a record that is not a candidate may carry a tip that is gone or None; the move succeeds and counts only candidates",
   rc == 0 and "checked 2 final tips" in out and "verified:" in out, (rc, out))
is_("tip_not_candidate: the non-candidate's objects were rewritten like the others", f.branches_doc()["branches"][3]["objects"], os.path.join(f.new, "2026-11-02", "chezmoi", "objects"))

f = Fx()                                # after a resume nothing can be checked first: the post-move check names the branch
os.makedirs(os.path.dirname(f.new))
os.rename(f.old, f.new)
with_branches(f, lambda bs: bs[1].update(final_tip="0" * 40))
rc, out = cli(*f.args())
ok("tip_after_resume: a candidate whose tip does not resolve is named by the verification", rc == 1 and "verification failed" in out and "b2" in out and "verified:" not in out, (rc, out))

f = Fx()
real_write = C.XR.write_whole
C.XR.write_whole = lambda path, data: None if path.endswith("alternates") else real_write(path, data)     # a write that does not land
try:
    rc, out = cli(*f.args())
finally:
    C.XR.write_whole = real_write
ok("verify: a reference to OLD left in a view is named, exit 1, no verified line", rc == 1 and "alternates" in out and f.old in out and "verified:" not in out, (rc, out))

# ---------------------------------------------------------------- a spelling of --from the state does not use
f = Fx()
lnk = os.path.join(f.root, "lnk")
os.symlink(os.path.dirname(f.old), lnk)
before = f.snap()
rc, out = cli("--state", f.state, "--from", os.path.join(lnk, "snapshot"), "--to", f.new)
ok("spelling: --from through a symlinked parent matches no recorded path and is refused", rc == 1 and "spelled" in out and "verified:" not in out, (rc, out))
is_("spelling: and nothing changed", f.snap(), before)
ok("spelling: the views still read OLD's objects", C.git_ok(f.view, "cat-file", "-e", f.tip + "^{commit}") and os.path.isdir(f.old))

f = Fx()
cli(*f.args())
put(f.view, "objects/info/alternates", os.path.join(f.new, "2026-11-02", "gone", "objects") + "\n")
rc, out = cli(*f.args())
ok("verify_alternates: a line under NEW that names no directory fails the verification of a rerun that rewrote nothing",
   rc == 1 and "verification failed" in out and "not a directory" in out and "verified:" not in out, (rc, out))

# a view of an original's objects that is already gone: caught before the move, in the dry run too
f = Fx()
gone = os.path.join(f.root, "nowhere", "gone", ".git", "objects")
put(f.state, "views/gone.git/objects/info/alternates", gone + "\n")
before = f.snap(strict=True)
rc, out = cli(*f.args("--dry-run"))
ok("dead_alternate: the dry run refuses, naming the view", rc == 1 and "views/gone.git" in out and gone in out, (rc, out))
is_("dead_alternate: and changes nothing", f.snap(strict=True), before)
before = f.snap()
rc, out = cli(*f.args())
ok("dead_alternate: the real run refuses too, naming the view, before anything moves", rc == 1 and "views/gone.git" in out, (rc, out))
ok("dead_alternate: OLD has not moved", os.path.isdir(f.old) and not os.path.exists(f.new))
is_("dead_alternate: and nothing changed", f.snap(), before)
os.makedirs(gone)
rc, out = cli(*f.args())
ok("dead_alternate: once the directory is there the move goes through", rc == 0 and "verified:" in out, (rc, out))

# a view whose alternates line lies under OLD but names a directory that does not exist: caught before the move, not after a complete move
f = Fx()
dead = os.path.join(f.old, "2026-11-02", "gone", "objects")
put(f.state, "views/dead-under-old.git/objects/info/alternates", dead + "\n")
before = f.snap(strict=True)
rc, out = cli(*f.args("--dry-run"))
ok("dead_under_old: the dry run refuses, naming the view", rc == 1 and "views/dead-under-old.git" in out and dead in out, (rc, out))
is_("dead_under_old: and changes nothing", f.snap(strict=True), before)
before = f.snap()
rc, out = cli(*f.args())
ok("dead_under_old: the real run refuses too, naming the view", rc == 1 and "views/dead-under-old.git" in out and "verified:" not in out, (rc, out))
ok("dead_under_old: OLD has not moved", os.path.isdir(f.old) and not os.path.exists(f.new))
is_("dead_under_old: and nothing changed", f.snap(), before)

# ---------------------------------------------------------------- a missing state or one without branches.json takes no lock
missing = os.path.join(helpers.tmp_root(), "no-such-state")
f = Fx()
rc, out = cli("--state", missing, "--from", f.old, "--to", f.new)
ok("no_state: a missing --state is refused", rc == 1 and "branches.json" in out, (rc, out))
is_("no_state: the CLI leaves its empty directory and the command adds no file to it (no run.lock)", os.listdir(missing), [])
ok("no_state: OLD is where it was", os.path.isdir(f.old) and not os.path.exists(f.new))

# ---------------------------------------------------------------- the state may not lie inside what moves
f = Fx()
inner = os.path.join(f.old, "st")
os.makedirs(inner)
shutil.copy(os.path.join(f.state, "branches.json"), inner)
put(inner, "run.lock", "")               # this state is inside OLD, so the lock file a held lock makes would show in OLD's listing
refused("--state inside --from", f, ["--state", inner, "--from", f.old, "--to", f.new], "state")
ok("state_inside: OLD is still there", os.path.isdir(f.old) and not os.path.exists(f.new))
f = Fx()
ns = os.path.join(f.root, "ns")
os.makedirs(os.path.join(ns, "st"))
shutil.copy(os.path.join(f.state, "branches.json"), os.path.join(ns, "st"))
rc, out = cli("--state", os.path.join(ns, "st"), "--from", f.old, "--to", ns)
ok("state_inside: --state inside --to is refused", rc == 1 and "state" in out and os.path.isdir(f.old), (rc, out))

# ---------------------------------------------------------------- a failed rename removes the parents it made
f = Fx()
f.new = os.path.join(f.root, "p1", "p2", "p3", "snapshot")
real_rename = os.rename
def failing_rename(src, dst):
    raise OSError(18, "Invalid cross-device link")
R.os.rename = failing_rename
try:
    rc, out = cli(*f.args())
finally:
    R.os.rename = real_rename
ok("rename_fails: a failed rename is a refusal naming it", rc == 1 and "cannot rename" in out, (rc, out))
ok("rename_fails: the parents it made are gone and OLD is intact", not os.path.exists(os.path.join(f.root, "p1")) and os.path.isdir(f.old), os.listdir(f.root))
f = Fx()
os.makedirs(os.path.join(f.root, "p1"))
f.new = os.path.join(f.root, "p1", "p2", "snapshot")
R.os.rename = failing_rename
try:
    rc, out = cli(*f.args())
finally:
    R.os.rename = real_rename
ok("rename_fails: a parent that was there before stays", rc == 1 and os.path.isdir(os.path.join(f.root, "p1")) and not os.path.exists(os.path.join(f.root, "p1", "p2")), os.listdir(f.root))
