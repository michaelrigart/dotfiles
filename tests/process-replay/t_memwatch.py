import argparse
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import is_, ok, put

helpers.setup()
from process_replay import memwatch as M  # noqa: E402
from process_replay.common import Failed  # noqa: E402

ROOT = helpers.tmp_root()
XDG = os.path.join(ROOT, "xdg")
os.environ["XDG_STATE_HOME"] = XDG
WDIR = os.path.join(XDG, "process-replay", "memwatch")


def raises(fn, *args, **kw):
    try:
        fn(*args, **kw)
    except Failed:
        return True
    return False


def jl(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def tree(root):
    """Every path below root, relative, with .git trees included (for 'nothing else was written')."""
    out = []
    for d, dirs, files in os.walk(root):
        for n in dirs + files:
            out.append(os.path.relpath(os.path.join(d, n), root))
    return sorted(out)


def namespace(source, **kw):
    base = dict(source=source, interval=60, seed=None, seed_at=None, once=True, dry_run=False, state=ROOT)
    base.update(kw)
    return argparse.Namespace(**base)


clock = {"n": 0}


def tick():
    clock["n"] += 1
    return "2026-11-03T10:{:02d}:00Z".format(clock["n"])


M.now = tick

# ---- digest
SRC = os.path.join(ROOT, "mem")
put(SRC, "memory_summary.md", "summary\n")
put(SRC, "MEMORY.md", "memory\n")
put(SRC, "rollout_summaries/a.md", "a\n")
put(SRC, ".git/HEAD", "ref: refs/heads/main\n")
put(SRC, ".git/objects/aa/bb", "blob")
D0 = M.digest(SRC)
ok("digest: a 64-hex SHA-256", len(D0) == 64 and all(c in "0123456789abcdef" for c in D0), D0)
copy = os.path.join(ROOT, "mem-copy")
shutil.copytree(SRC, copy)
is_("digest: the same files in another directory have the same digest", M.digest(copy), D0)
put(copy, ".git/HEAD", "ref: refs/heads/other\n")
put(copy, ".git/new", "x")
is_("digest: .git is excluded", M.digest(copy), D0)
put(copy, "MEMORY.md", "memory!\n")
ok("digest: a changed content changes it", M.digest(copy) != D0)
shutil.copytree(SRC, copy + "2")
os.rename(os.path.join(copy + "2", "rollout_summaries", "a.md"), os.path.join(copy + "2", "rollout_summaries", "b.md"))
ok("digest: a renamed file changes it", M.digest(copy + "2") != D0)
other = os.path.join(ROOT, "mem-split")
put(other, "ab", "c")
other2 = os.path.join(ROOT, "mem-split2")
put(other2, "a", "bc")
ok("digest: a path/content boundary cannot be shifted", M.digest(other) != M.digest(other2))
ok("digest: a missing directory is an error", raises(M.digest, os.path.join(ROOT, "nope")))

# ---- polls_and_snapshots
before_src = helpers.listing(SRC)
before_all = tree(ROOT)
for _ in range(3):
    M.cmd_memories_watch(namespace(SRC))
polls = jl(os.path.join(WDIR, "polls.jsonl"))
is_("polls_and_snapshots: three polls with no change log three lines", len(polls), 3)
is_("polls_and_snapshots: each line has the poll time, the hash and the watcher's interval", [sorted(p)[:3] for p in polls[:1]], [["at", "hash", "interval"]])
is_("polls_and_snapshots: the interval is the one the watcher sleeps", set(p["interval"] for p in polls), {60})
is_("polls_and_snapshots: every poll holds the digest of the source", set(p["hash"] for p in polls), {D0})
snaps = [p for p in polls if p.get("snapshot")]
is_("polls_and_snapshots: only the first poll took a snapshot", [p is polls[0] for p in snaps], [True])
snap_dir = os.path.join(WDIR, "snapshots")
is_("polls_and_snapshots: one snapshot directory, named <at>-<hash12>", os.listdir(snap_dir), [polls[0]["at"] + "-" + D0[:12]])
S1 = os.path.join(snap_dir, os.listdir(snap_dir)[0])
is_("polls_and_snapshots: the line names it", polls[0]["snapshot"], os.path.basename(S1))
is_("polls_and_snapshots: the snapshot's own digest is the poll's hash", M.digest(S1), D0)
ok("polls_and_snapshots: .git is never copied", not os.path.exists(os.path.join(S1, ".git")) and ".git" not in " ".join(tree(S1)), tree(S1))
ok("polls_and_snapshots: the contents are there", os.path.isfile(os.path.join(S1, "rollout_summaries", "a.md")))
is_("polls_and_snapshots: the source's listing is unchanged (names, sizes, mtimes)", helpers.listing(SRC), before_src)
new_paths = [p for p in tree(ROOT) if p not in before_all]
MW = os.path.join("xdg", "process-replay", "memwatch")
ok("polls_and_snapshots: nothing was written outside the watch dir",
   all(p in ("xdg", os.path.join("xdg", "process-replay"), MW) or p.startswith(MW + os.sep) for p in new_paths), new_paths)
ok("polls_and_snapshots: no temporary copy is left", not [n for n in os.listdir(snap_dir) if n.endswith(".tmp")])

put(SRC, "MEMORY.md", "memory changed\n")
D1 = M.digest(SRC)
M.cmd_memories_watch(namespace(SRC))
polls = jl(os.path.join(WDIR, "polls.jsonl"))
is_("polls_and_snapshots: a change logs a new poll with a new snapshot", (len(polls), polls[-1]["hash"] == D1, bool(polls[-1].get("snapshot"))), (4, True, True))
is_("polls_and_snapshots: both snapshots are kept", len(os.listdir(snap_dir)), 2)
is_("polls_and_snapshots: the new snapshot holds the new text", open(os.path.join(snap_dir, polls[-1]["snapshot"], "MEMORY.md")).read(), "memory changed\n")
is_("polls_and_snapshots: the old snapshot still holds the old", open(os.path.join(S1, "MEMORY.md")).read(), "memory\n")
M.cmd_memories_watch(namespace(SRC))
polls = jl(os.path.join(WDIR, "polls.jsonl"))
ok("polls_and_snapshots: a later unchanged poll takes none", len(polls) == 5 and not polls[-1].get("snapshot"), polls[-1])
put(SRC, "MEMORY.md", "memory\n")
M.cmd_memories_watch(namespace(SRC))
polls = jl(os.path.join(WDIR, "polls.jsonl"))
ok("polls_and_snapshots: a change back to an earlier text is a new snapshot", len(os.listdir(snap_dir)) == 3 and bool(polls[-1].get("snapshot")), polls[-1])
ok("polls_and_snapshots: a watch directory inside the source is refused", raises(M.cmd_memories_watch, namespace(os.path.dirname(WDIR))))

# ---- a stale half-made copy is swept at the start of a poll
stale = os.path.join(snap_dir, "2026-11-03T09:00:00Z-deadbeefdead.tmp")
put(stale, "x/y", "half")
M.cmd_memories_watch(namespace(SRC))
ok("polls_and_snapshots: a leftover snapshots/*.tmp is removed at the start of a poll, the snapshots stay",
   not os.path.exists(stale) and len(os.listdir(snap_dir)) == 3, os.listdir(snap_dir))

# ---- the loop polls until it is stopped
slept = []


def stop_after_two(seconds):
    slept.append(seconds)
    if len(slept) == 2:
        raise KeyboardInterrupt()


M.sleep = stop_after_two
n_polls = len(jl(os.path.join(WDIR, "polls.jsonl")))
is_("loop: an interrupt ends the watcher cleanly", M.cmd_memories_watch(namespace(SRC, once=False, interval=7)), 0)
is_("loop: it polled between sleeps of the interval", (slept, len(jl(os.path.join(WDIR, "polls.jsonl"))) - n_polls), ([7, 7], 2))

# ---- dry run
n_before = len(tree(XDG))
M.cmd_memories_watch(namespace(SRC, dry_run=True))
is_("dry run: writes nothing", len(tree(XDG)), n_before)

# ---- copy_verified
XDG2 = os.path.join(ROOT, "xdg2")
os.environ["XDG_STATE_HOME"] = XDG2
WDIR2 = os.path.join(XDG2, "process-replay", "memwatch")
SRC2 = os.path.join(ROOT, "mem2")
put(SRC2, "MEMORY.md", "one\n")
put(SRC2, "b.md", "b\n")
H1 = M.digest(SRC2)


def change():
    put(SRC2, "b.md", "changed while copying\n")


M.BETWEEN = change
M.cmd_memories_watch(namespace(SRC2))
M.BETWEEN = None
polls = jl(os.path.join(WDIR2, "polls.jsonl"))
is_("copy_verified: the poll is logged, with the hash it computed", (len(polls), polls[0]["hash"]), (1, H1))
ok("copy_verified: marked unstable, with no snapshot", polls[0].get("unstable") is True and not polls[0].get("snapshot"), polls[0])
ok("copy_verified: the copy is discarded", not os.path.exists(os.path.join(WDIR2, "snapshots")) or os.listdir(os.path.join(WDIR2, "snapshots")) == [],
   tree(WDIR2))
M.cmd_memories_watch(namespace(SRC2))
polls = jl(os.path.join(WDIR2, "polls.jsonl"))
H2 = M.digest(SRC2)
ok("copy_verified: the next stable poll snapshots the new text", len(polls) == 2 and polls[1]["hash"] == H2 and bool(polls[1].get("snapshot"))
   and not polls[1].get("unstable"), polls)
is_("copy_verified: and only that snapshot exists", os.listdir(os.path.join(WDIR2, "snapshots")), [polls[1]["snapshot"]])
ok("copy_verified: no snapshot is recorded for the unstable hash", all(p.get("snapshot") is None for p in polls if p["hash"] == H1) and H1 != H2)


def vanish():
    os.unlink(os.path.join(SRC2, "b.md"))


put(SRC2, "b.md", "b again\n")
M.BETWEEN = vanish
M.cmd_memories_watch(namespace(SRC2))
M.BETWEEN = None
polls = jl(os.path.join(WDIR2, "polls.jsonl"))
ok("copy_verified: a file that vanishes mid-copy is an unstable poll too", polls[-1].get("unstable") is True and not polls[-1].get("snapshot"), polls[-1])

# ---- a missing source is an unstable poll, and the watcher keeps going
XDG4 = os.path.join(ROOT, "xdg4")
os.environ["XDG_STATE_HOME"] = XDG4
WDIR4 = os.path.join(XDG4, "process-replay", "memwatch")
GONE = os.path.join(ROOT, "mem-not-yet")
is_("missing source: a poll of it returns", M.cmd_memories_watch(namespace(GONE)), 0)
polls = jl(os.path.join(WDIR4, "polls.jsonl"))
ok("missing source: logged unstable, with no hash and a reason, no snapshot",
   len(polls) == 1 and polls[0].get("unstable") is True and polls[0]["hash"] is None and polls[0].get("reason") and not polls[0].get("snapshot"), polls)
slept = []


def appear(seconds):
    slept.append(seconds)
    if len(slept) == 1:
        put(GONE, "MEMORY.md", "now here\n")
    else:
        raise KeyboardInterrupt()


M.sleep = appear
M.cmd_memories_watch(namespace(GONE, once=False, interval=5))
polls = jl(os.path.join(WDIR4, "polls.jsonl"))
ok("missing source: the loop went on, and snapshotted once the directory existed", len(polls) == 3 and polls[1].get("unstable") is True
   and polls[2]["hash"] == M.digest(GONE) and bool(polls[2].get("snapshot")), polls)
ok("missing source: a dispatch beside the unstable poll is not usable", M.snapshot_for(WDIR4, polls[0]["at"])[0] is None)

# ---- links: any symlink in the tree makes the poll unstable and keeps no snapshot
XDG5 = os.path.join(ROOT, "xdg5")
os.environ["XDG_STATE_HOME"] = XDG5
WDIR5 = os.path.join(XDG5, "process-replay", "memwatch")
REASON = "the memories directory holds a symlink"


def with_link(name, make):
    tree_ = os.path.join(ROOT, "mem-link-" + name)
    put(tree_, "real.md", "real\n")
    put(tree_, "dir/inner.md", "inner\n")
    put(os.path.dirname(tree_), "outside/s.md", "secret live memory\n")
    make(tree_)
    return tree_


def link_poll(tree_):
    n_snaps = len(os.listdir(os.path.join(WDIR5, "snapshots"))) if os.path.isdir(os.path.join(WDIR5, "snapshots")) else 0
    M.cmd_memories_watch(namespace(tree_))
    rec = jl(os.path.join(WDIR5, "polls.jsonl"))[-1]
    left = len(os.listdir(os.path.join(WDIR5, "snapshots"))) if os.path.isdir(os.path.join(WDIR5, "snapshots")) else 0
    return rec, left == n_snaps


def chain(t_):      # here -> . ; peek -> here/../outside/s.md: every target is textually inside, the chain reaches outside
    os.symlink(".", os.path.join(t_, "here"))
    os.symlink("here/../outside/s.md", os.path.join(t_, "peek"))


for name, make in (("plain", lambda t_: os.symlink("real.md", os.path.join(t_, "alias.md"))),
                   ("chain", chain),
                   ("dirlink", lambda t_: os.symlink("dir", os.path.join(t_, "dirlink"))),
                   ("nested", lambda t_: os.symlink("../real.md", os.path.join(t_, "dir", "up.md"))),
                   ("abs", lambda t_: os.symlink("/etc/hosts", os.path.join(t_, "out.md"))),
                   ("broken", lambda t_: os.symlink("nowhere", os.path.join(t_, "dangling.md")))):
    t_ = with_link(name, make)
    rec, unchanged = link_poll(t_)
    ok("links: a {} symlink makes the poll unstable, with the reason, and keeps no snapshot".format(name),
       rec.get("unstable") is True and rec.get("reason") == REASON and not rec.get("snapshot") and rec["hash"] == M.digest(t_) and unchanged, rec)
git_only = with_link("gitlink", lambda t_: (os.makedirs(os.path.join(t_, ".git")), os.symlink("/etc/hosts", os.path.join(t_, ".git", "l"))))
rec, _u = link_poll(git_only)
ok("links: a link inside .git, which is never read or copied, does not matter", bool(rec.get("snapshot")) and not rec.get("unstable"), rec)
nolink = with_link("none", lambda t_: put(t_, "extra.md", "a file, no link\n"))
rec, _u = link_poll(nolink)
ok("links: control: the same tree without a link is snapshotted", bool(rec.get("snapshot")) and not rec.get("unstable"), rec)
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "xdg6")
WDIR6 = os.path.join(ROOT, "xdg6", "process-replay", "memwatch")
for name in ("plain", "chain"):
    ok("links: a seed holding a {} symlink is refused".format(name),
       raises(M.cmd_memories_watch, namespace(nolink, seed=os.path.join(ROOT, "mem-link-" + name), seed_at="2026-11-02T13:21:00Z")))
is_("links: and the refused seed left no log", M.first_poll(WDIR6), None)

# ---- seed
XDG3 = os.path.join(ROOT, "xdg3")
os.environ["XDG_STATE_HOME"] = XDG3
WDIR3 = os.path.join(XDG3, "process-replay", "memwatch")
SEED = os.path.join(ROOT, "seed")
put(SEED, "MEMORY.md", "frozen\n")
put(SEED, ".git/HEAD", "x")
SRC3 = os.path.join(ROOT, "mem3")
put(SRC3, "MEMORY.md", "live now\n")
SEED_AT = "2026-11-02T13:21:00Z"
ok("seed: --seed needs --seed-at", raises(M.cmd_memories_watch, namespace(SRC3, seed=SEED)))
M.cmd_memories_watch(namespace(SRC3, seed=SEED, seed_at=SEED_AT))
polls = jl(os.path.join(WDIR3, "polls.jsonl"))
SD = M.digest(SEED)
ok("seed: the seed is the first snapshot, at the given time, hashed from the seed itself",
   polls[0]["at"] == SEED_AT and polls[0]["hash"] == SD and SD != M.digest(SRC3) and bool(polls[0].get("snapshot")), polls[0])
is_("seed: first_poll is the seed's time", M.first_poll(WDIR3), SEED_AT)
is_("seed: the snapshot is named <at>-<hash12>", polls[0]["snapshot"], SEED_AT + "-" + SD[:12])
is_("seed: its contents are the seed's, without .git", sorted(tree(os.path.join(WDIR3, "snapshots", polls[0]["snapshot"]))), ["MEMORY.md"])
ok("seed: the live poll after it snapshots the live text", len(polls) == 2 and polls[1]["hash"] == M.digest(SRC3) and bool(polls[1].get("snapshot")), polls)
ok("seed: a seed on a log that has polls is refused", raises(M.cmd_memories_watch, namespace(SRC3, seed=SEED, seed_at="2026-11-02T13:22:00Z")))
is_("seed: first_poll of an empty watch dir is None", M.first_poll(os.path.join(ROOT, "nothing")), None)

# ---- snapshot_for
W = os.path.join(ROOT, "wsf")
HA, HB = "a" * 64, "b" * 64


def snapdir(name):
    os.makedirs(os.path.join(W, "snapshots", name), exist_ok=True)
    return os.path.join(W, "snapshots", name)


def write_polls(lines):
    os.makedirs(W, exist_ok=True)
    with open(os.path.join(W, "polls.jsonl"), "w") as f:
        f.write("".join(json.dumps(l) + "\n" for l in lines))


snapdir("2026-11-03T10:00:00Z-" + HA[:12])
snapdir("2026-11-03T10:07:00Z-" + HB[:12])
P = [{"at": "2026-11-03T10:00:00Z", "hash": HA, "snapshot": "2026-11-03T10:00:00Z-" + HA[:12]},
     {"at": "2026-11-03T10:01:00Z", "hash": HA},
     {"at": "2026-11-03T10:02:00Z", "hash": HA},
     {"at": "2026-11-03T10:03:00Z", "hash": HA}]
write_polls(P)
path, h = M.snapshot_for(W, "2026-11-03T10:01:30.250000Z")
is_("snapshot_for: equal hashes around the dispatch give that hash's snapshot", (path, h),
    (os.path.join(W, "snapshots", "2026-11-03T10:00:00Z-" + HA[:12]), HA))
is_("snapshot_for: a dispatch time with fractional seconds and Z parses", M.snapshot_for(W, "2026-11-03T10:01:30Z")[1], HA)
CHANGED = "memories changed around the dispatch"
write_polls(P[:2] + [{"at": "2026-11-03T10:02:00Z", "hash": HB, "snapshot": "2026-11-03T10:07:00Z-" + HB[:12]}] + P[3:])
is_("snapshot_for: different hashes around the dispatch", M.snapshot_for(W, "2026-11-03T10:01:30Z"), (None, CHANGED))
is_("snapshot_for: a dispatch clear of the change is still fine", M.snapshot_for(W, "2026-11-03T10:00:30Z")[1], HA)
write_polls(P[:2] + [dict(P[2], unstable=True)] + P[3:])
is_("snapshot_for: an unstable poll after, equal hashes and an earlier snapshot", M.snapshot_for(W, "2026-11-03T10:01:30Z"), (None, CHANGED))
write_polls([P[0], dict(P[1], unstable=True)] + P[2:])
is_("snapshot_for: an unstable poll before", M.snapshot_for(W, "2026-11-03T10:01:30Z"), (None, CHANGED))
write_polls([P[0], dict(P[1], unstable=True)] + P[2:])
is_("snapshot_for: an unstable poll not adjacent does not matter", M.snapshot_for(W, "2026-11-03T10:02:30Z")[1], HA)
write_polls([P[0], {"at": "2026-11-03T10:06:00Z", "hash": HA}])
is_("snapshot_for: polls more than 2 x interval + 30 s apart (default interval 60)", M.snapshot_for(W, "2026-11-03T10:03:00Z"), (None, "missing poll"))
write_polls([P[0], {"at": "2026-11-03T10:02:30Z", "hash": HA}])
is_("snapshot_for: exactly 2 x interval + 30 s apart is allowed", M.snapshot_for(W, "2026-11-03T10:01:00Z")[1], HA)
write_polls([P[0], {"at": "2026-11-03T10:04:00Z", "hash": HA}])
is_("snapshot_for: a longer interval widens the limit", M.snapshot_for(W, "2026-11-03T10:01:00Z", interval=120)[1], HA)
write_polls(P)
is_("snapshot_for: no poll after the dispatch", M.snapshot_for(W, "2026-11-03T10:05:00Z"), (None, "no poll after the dispatch"))
is_("snapshot_for: no poll before the dispatch", M.snapshot_for(W, "2026-11-03T09:59:00Z"), (None, "missing poll"))
os.makedirs(W, exist_ok=True)
os.unlink(os.path.join(W, "polls.jsonl"))
is_("snapshot_for: no log at all", M.snapshot_for(W, "2026-11-03T10:01:00Z"), (None, "no poll after the dispatch"))
write_polls([{"at": "2026-11-03T10:01:00Z", "hash": HB}, {"at": "2026-11-03T10:02:00Z", "hash": HB}])
is_("snapshot_for: equal hashes with no snapshot of them", M.snapshot_for(W, "2026-11-03T10:01:30Z"), (None, "no snapshot of those memories"))
write_polls([dict(P[0], snapshot="2026-11-03T10:00:00Z-gone"), P[1]])
is_("snapshot_for: a snapshot whose directory is gone", M.snapshot_for(W, "2026-11-03T10:00:30Z"), (None, "no snapshot of those memories"))
# the latest snapshot of the hash taken before the dispatch: A, then B, then A again
snapdir("2026-11-03T10:09:00Z-" + HA[:12])
write_polls([P[0], {"at": "2026-11-03T10:07:00Z", "hash": HB, "snapshot": "2026-11-03T10:07:00Z-" + HB[:12]},
             {"at": "2026-11-03T10:09:00Z", "hash": HA, "snapshot": "2026-11-03T10:09:00Z-" + HA[:12]},
             {"at": "2026-11-03T10:10:00Z", "hash": HA}])
is_("snapshot_for: the latest snapshot of that hash", M.snapshot_for(W, "2026-11-03T10:09:30Z"),
    (os.path.join(W, "snapshots", "2026-11-03T10:09:00Z-" + HA[:12]), HA))
with open(os.path.join(W, "polls.jsonl"), "a") as f:
    f.write('{"at": "2026-11-03T10:11:00Z", "ha')
is_("snapshot_for: a half-written last line is ignored", M.snapshot_for(W, "2026-11-03T10:09:30Z")[1], HA)

# ---- the interval the polls logged
W2 = os.path.join(ROOT, "wsf180")
write_polls_to = lambda path, lines: (os.makedirs(path, exist_ok=True), open(os.path.join(path, "polls.jsonl"), "w").write("".join(json.dumps(l) + "\n" for l in lines)))
os.makedirs(os.path.join(W2, "snapshots", "2026-11-03T11:00:00Z-" + HA[:12]))
slow = [{"at": "2026-11-03T11:00:00Z", "hash": HA, "interval": 180, "snapshot": "2026-11-03T11:00:00Z-" + HA[:12]},
        {"at": "2026-11-03T11:03:00Z", "hash": HA, "interval": 180}]
write_polls_to(W2, slow)
is_("interval: a 180 s watcher's polls 180 s apart are not a missing poll (the logged interval, not the 60 s default)",
    M.snapshot_for(W2, "2026-11-03T11:01:00Z")[1], HA)
write_polls_to(W2, [dict(p, interval=60) for p in slow])
is_("interval: control: the same polls logged at 60 s are a missing poll", M.snapshot_for(W2, "2026-11-03T11:01:00Z"), (None, "missing poll"))
write_polls_to(W2, [slow[0], {"at": "2026-11-03T11:07:00Z", "hash": HA, "interval": 180}])
is_("interval: more than 2 x 180 + 30 s apart is a missing poll", M.snapshot_for(W2, "2026-11-03T11:01:00Z"), (None, "missing poll"))
write_polls_to(W2, [dict(slow[0], interval=180), {"at": "2026-11-03T11:03:00Z", "hash": HA}])
is_("interval: a poll that logged none falls back on its neighbour's", M.snapshot_for(W2, "2026-11-03T11:01:00Z")[1], HA)
