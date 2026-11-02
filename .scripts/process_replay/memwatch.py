"""The Codex memories watcher (spec section 6) and the lookup that tells a case which memories its reviewer had.

`memories-watch` hashes the live memories directory every minute, logs every poll, and copies the
directory on each change into
  $XDG_STATE_HOME/process-replay/memwatch/
    polls.jsonl                   one {at, hash, interval} line per poll (interval: the seconds the watcher sleeps
                                  after it), plus snapshot (a directory name) when the poll took one, unstable: true
                                  when the directory changed while it was copied, holds a symlink or was missing (hash is then null when it changed or vanished while it was read, and a
                                  reason is given), seed: true for the seed
    snapshots/<at>-<hash12>/      a copy without .git, kept only when its own digest equals the poll's hash

It reads the source and writes nothing outside that directory, and never the live memories.

A poll's hash is a SHA-256 over the sorted relative paths and contents of the tree, `.git` excluded. A snapshot
is `cp -c -R` (an APFS clone), falling back to a plain copy, and is kept only when the copy's digest equals the
poll's: a directory that changes between the digest and the copy leaves an unstable poll and no snapshot. A link
anywhere in the tree does too: a reviewer on a snapshot must never be able to read the live memories through it.
"""
import calendar
import hashlib
import json
import os
import re
import shutil
import subprocess
import time

from . import common
from .common import Failed, say

POLLS = "polls.jsonl"
SNAPSHOTS = "snapshots"
GRACE = 30
CHANGED = "memories changed around the dispatch"
BETWEEN = None      # a test hook: called between a poll's digest and its copy
sleep = time.sleep
_AT = re.compile(r"\A(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(?:Z|\+00:?00)\Z")


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def watch_dir():
    return os.path.join(common.L.state_home(), "process-replay", "memwatch")


def parse_at(text):
    """Seconds since the epoch of an ISO UTC time (Z, optional fraction); Failed for any other spelling."""
    m = _AT.match(text) if isinstance(text, str) else None
    if m is None:
        raise Failed("not a UTC time (YYYY-MM-DDTHH:MM:SS[.fff]Z): {!r}".format(text))
    return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")) + float(m.group(2) or 0)


# ------------------------------------------------------------------ digest and copy
def _files(src):
    """(relative path, absolute path) of every file and link below src, sorted, `.git` anywhere excluded."""
    out = []
    for d, dirs, files in os.walk(src):
        dirs[:] = [x for x in dirs if x != ".git"]
        for n in files + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
            if n != ".git":
                full = os.path.join(d, n)
                out.append((os.path.relpath(full, src), full))
    return sorted(out)


def digest(src):
    """SHA-256 over the sorted relative paths and contents of src, `.git` excluded; each file is framed by its
    path and size, so no content can pass for a path. A link counts by its target. Failed for a missing
    directory; OSError when a file vanishes while being read."""
    if not os.path.isdir(src):
        raise Failed("not a directory: " + src)
    h = hashlib.sha256()
    for rel, full in _files(src):
        if os.path.islink(full):
            data, kind = os.readlink(full).encode("utf-8", "surrogateescape"), b"L"
        else:
            with open(full, "rb") as f:
                data, kind = f.read(), b"F"
        h.update(kind + b"\0" + rel.encode("utf-8", "surrogateescape") + b"\0" + str(len(data)).encode() + b"\0" + data)
    return h.hexdigest()


SYMLINK = "the memories directory holds a symlink"


def _has_symlink(root):
    """Whether any link lies below `root` (`.git` excluded). A snapshot is read by a reviewer, and a link in it could
    lead to the live memories by a route no text check of its target can rule out (a chain of links, `..` through a
    link), so a tree holding any link is not snapshotted. Codex's memories hold none."""
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x != ".git"]
        if any(os.path.islink(os.path.join(d, n)) for n in files + dirs if n != ".git"):
            return True
    return False


def _copy(src, dst):
    """src's contents at dst (new), without `.git`: APFS clones where the volume has them, else plain copies."""
    os.makedirs(dst)
    for name in sorted(os.listdir(src)):
        if name == ".git":
            continue
        from_, to = os.path.join(src, name), os.path.join(dst, name)
        if subprocess.run(["/bin/cp", "-c", "-R", from_, to], capture_output=True).returncode == 0:
            continue
        if os.path.lexists(to):
            shutil.rmtree(to, ignore_errors=True) if os.path.isdir(to) and not os.path.islink(to) else os.unlink(to)
        if os.path.isdir(from_) and not os.path.islink(from_):
            shutil.copytree(from_, to, symlinks=True, ignore=shutil.ignore_patterns(".git"))
        else:
            shutil.copy2(from_, to, follow_symlinks=False)
    for d, dirs, files in os.walk(dst):      # a nested .git
        for n in [x for x in dirs + files if x == ".git"]:
            p = os.path.join(d, n)
            shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) and not os.path.islink(p) else os.unlink(p)
        dirs[:] = [x for x in dirs if x != ".git"]


# ------------------------------------------------------------------ the log
def polls(wdir):
    """The log's polls in file order; a line that does not parse (a half-written last one) is skipped."""
    out = []
    try:
        with open(os.path.join(wdir, POLLS), encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict) and isinstance(rec.get("at"), str):
                    try:
                        parse_at(rec["at"])
                    except Failed:
                        continue
                    out.append(rec)
    except OSError:
        pass
    return out


def first_poll(wdir):
    """The time of the first poll in the log (the seed counts), or None."""
    found = polls(wdir)
    return found[0]["at"] if found else None


def _append(wdir, rec):
    os.makedirs(wdir, exist_ok=True)
    fd = os.open(os.path.join(wdir, POLLS), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, (json.dumps(rec) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def _last_snapshot_hash(wdir):
    for rec in reversed(polls(wdir)):
        if rec.get("snapshot"):
            return rec.get("hash")
    return None


def _keep(wdir, src, at, want):
    """Copy src into snapshots/<at>-<hash12>: (the directory name, None) when the copy's digest is `want` and the tree
    holds no symlink, else (None, why) with the copy discarded."""
    name = "{}-{}".format(at, want[:12])
    final = os.path.join(wdir, SNAPSHOTS, name)
    tmp = final + ".tmp"
    os.makedirs(os.path.join(wdir, SNAPSHOTS), exist_ok=True)
    shutil.rmtree(tmp, ignore_errors=True)
    why = SYMLINK if _has_symlink(src) else None
    try:
        if why is None:
            _copy(src, tmp)
            if digest(tmp) != want:
                why = "the directory changed while it was copied"
            elif _has_symlink(tmp):
                why = SYMLINK
    except OSError as e:
        why = "the copy failed: {}".format(e)
    if why:
        shutil.rmtree(tmp, ignore_errors=True)
        return None, why
    shutil.rmtree(final, ignore_errors=True)
    os.rename(tmp, final)
    return name, None


def _sweep(wdir):
    """A copy a killed watcher left half made."""
    base = os.path.join(wdir, SNAPSHOTS)
    if os.path.isdir(base):
        for n in os.listdir(base):
            if n.endswith(".tmp"):
                shutil.rmtree(os.path.join(base, n), ignore_errors=True)


def poll_once(wdir, source, at=None, interval=None):
    """One poll: hash the source, copy it when it differs from the last snapshot, log the poll. Returns the
    logged record. A source that is missing or changes under the poll is an unstable poll, not an error."""
    at = at or now()
    rec = {"at": at, "hash": None}
    if interval is not None:
        rec["interval"] = int(interval) if float(interval).is_integer() else interval
    _sweep(wdir)
    try:
        want = digest(source)
    except (OSError, Failed) as e:
        rec.update(unstable=True, reason=str(e))
        _append(wdir, rec)
        return rec
    rec["hash"] = want
    if want != _last_snapshot_hash(wdir):
        if BETWEEN is not None:
            BETWEEN()
        name, why = _keep(wdir, source, at, want)
        if name:
            rec["snapshot"] = name
        else:
            rec.update(unstable=True, reason=why)
    _append(wdir, rec)
    return rec


def register_seed(wdir, seed, at):
    """The seed directory as the first snapshot, at the time given; its hash is the seed's own digest. A log whose first poll is already
    that seed (the same time and digest: the watcher is restarting with the same command) is left as it is and its record returned;
    any other log with polls, or another seed, is refused."""
    parse_at(at)
    want = digest(seed)
    found = polls(wdir)
    if found:
        first = found[0]
        if first.get("seed") and first.get("hash") == want and isinstance(first.get("at"), str) and parse_at(first["at"]) == parse_at(at):
            return first
        raise Failed("the watch log already has polls: a seed goes first, into an empty watch directory")
    name, why = _keep(wdir, seed, at, want)
    if name is None:
        raise Failed("the seed cannot be kept ({}): {}".format(why, seed))
    rec = {"at": at, "hash": want, "snapshot": name, "seed": True}
    _append(wdir, rec)
    return rec


# ------------------------------------------------------------------ the lookup
def snapshot_for(wdir, dispatched_at, interval=60):
    """(snapshot directory, hash) of the memories a review dispatched at `dispatched_at` had, or (None, why).
    The poll just before and the poll just after the dispatch must be at most 2 x interval + 30 s apart, where
    the interval is the one the polls logged (`interval` only for polls that logged none), both stable and of
    one hash, and that hash must have a snapshot taken at or before the dispatch."""
    when = parse_at(dispatched_at)
    found = polls(wdir)
    before = [p for p in found if parse_at(p["at"]) <= when]
    after = [p for p in found if parse_at(p["at"]) > when]
    if not after:
        return None, "no poll after the dispatch"
    if not before:
        return None, "missing poll"
    b, a = before[-1], after[0]
    logged = [p["interval"] for p in (b, a) if isinstance(p.get("interval"), (int, float)) and p["interval"] > 0]
    if parse_at(a["at"]) - parse_at(b["at"]) > 2 * (max(logged) if logged else interval) + GRACE:
        return None, "missing poll"
    if b.get("unstable") or a.get("unstable") or b.get("hash") is None or b.get("hash") != a.get("hash"):
        return None, CHANGED
    h = b["hash"]
    for p in reversed(before):
        name = p.get("snapshot")
        if p.get("hash") == h and name and os.path.isdir(os.path.join(wdir, SNAPSHOTS, name)):
            return os.path.join(wdir, SNAPSHOTS, name), h
    return None, "no snapshot of those memories"


# ------------------------------------------------------------------ the command
def add_args(ap):
    ap.add_argument("--source", default="~/.codex/memories", help="the live memories directory (read only)")
    ap.add_argument("--interval", type=float, default=60, help="seconds between polls")
    ap.add_argument("--seed", metavar="DIR", help="a frozen copy to register as the first snapshot")
    ap.add_argument("--seed-at", metavar="ISO", help="the time the seed was frozen, UTC (with --seed)")
    ap.add_argument("--once", action="store_true", help="poll once and stop")


def cmd_memories_watch(a):
    source = os.path.abspath(os.path.expanduser(a.source))
    wdir = watch_dir()
    if bool(a.seed) != bool(a.seed_at):
        raise Failed("--seed and --seed-at go together")
    if a.dry_run:
        say("would watch {} every {:g} s into {}{}".format(source, a.interval, wdir, ", seeded from " + a.seed if a.seed else ""))
        return 0
    if not os.path.isdir(source):
        say("warning: {} is not a directory: every poll is unstable until it is".format(source))
    if os.path.realpath(wdir) == os.path.realpath(source) or os.path.realpath(wdir).startswith(os.path.realpath(source) + os.sep):
        raise Failed("the watch directory lies inside the source")
    if a.seed:
        rec = register_seed(wdir, os.path.abspath(os.path.expanduser(a.seed)), a.seed_at)
        say("seed: {} at {}".format(rec["hash"][:12], rec["at"]))
    try:
        while True:
            rec = poll_once(wdir, source, interval=a.interval)
            say("{} {}{}{}".format(rec["at"], (rec["hash"] or "-")[:12], " snapshot" if rec.get("snapshot") else "",
                                   " UNSTABLE: " + rec.get("reason", "") if rec.get("unstable") else ""))
            if a.once:
                return 0
            sleep(a.interval)
    except KeyboardInterrupt:
        return 0
