#!/usr/bin/python3
# Pinned to the system interpreter, not `env python3`: an untrusted mise.toml in a reviewed
# repository can shadow `python3` on PATH, and the pre-merge gate must not be shadowable.
"""xreview-ledger - the pre-merge review ledger, and the identity of a reviewed change.

Managed by chezmoi (source: dot_claude/xreview-ledger.py). xreview runs it to write the
ledger; xreview-guard.py beside it imports it to decide the gate. It lives in ~/.claude, not
~/.local/bin, so the gate never executes code from a directory the sandbox can write.
Design: docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md, sections 3.1-3.3
and the decision in 3.6.

  key            COMMON_DIR                 SHA-256 of an absolute git common directory
  path           REPO                       the ledger file of the repository REPO is in
  default-branch REPO                       origin/HEAD's branch, else main, else master
  default-range  REPO                       <origin/default or default>...<current branch or HEAD>
  fingerprint    REPO BASE TIP              the change's exact content identity (exit 3: empty)
  diff           REPO BASE TIP              the change as a patch, for the review packet
  normalize      REPO RANGE                 one review target, as JSON
  now                                       the UTC time, to the microsecond
  append         COMMON_DIR ENTRY_JSON      one v2 entry, locked, idempotent per (nonce, kind)
  decide         REPO DEST DEST_REV TIP [--branch NAME]   the gate's decision, as JSON
  show           REPO                       every line on record: the ledger, then the legacy file

Exit codes: 0 ok (decide: allow), 1 failed (decide: deny), 2 usage, 3 empty change.
Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

LOCK_WAIT = 5.0          # seconds an append waits for the ledger lock
LOCK_STALE = 60.0        # a lock older than this was left by a crashed writer
CALL_TIMEOUT = 20.0      # per git call; the guard lowers it to fit its own budget
# The flags of every diff the ledger names or renders - the fingerprint, and the patch the
# reviewer reads - so the two always cover the same paths and content. Each pins an input the
# user's configuration could change: diff.relative would drop paths outside the current
# directory, an external or textconv driver would rewrite or hide content, renames would merge
# a delete and an add, and diff.ignoreSubmodules or submodule.<name>.ignore would hide a gitlink.
DIFF_FLAGS = ["--no-relative", "--no-ext-diff", "--no-textconv", "--no-renames",
              "--ignore-submodules=none"]
PATHSPEC_VARS = ("GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS",
                 "GIT_ICASE_PATHSPECS")
DIFF_RAW = ["diff", "--raw", "-z", "--no-abbrev"] + DIFF_FLAGS
DIFF_PATCH = ["diff", "--no-color"] + DIFF_FLAGS
USAGE = ("usage: xreview-ledger key COMMON_DIR | path REPO | default-branch REPO | "
         "default-range REPO | fingerprint REPO BASE TIP | diff REPO BASE TIP | "
         "normalize REPO RANGE | now | "
         "append COMMON_DIR ENTRY_JSON | decide REPO DEST DEST_REV TIP [--branch NAME] | "
         "show REPO")


class Fail(Exception):
    """A step that could not be completed, carrying the reason a caller shows."""


# ------------------------------------------------------------------ git
def git_env():
    """The environment of every git call, without the variables that change how a pathspec is
    read: a reviewed repository's mise.toml or direnv could set them, and the packet's
    pathspecs would then match other paths than the ones the fingerprint names."""
    return {k: v for k, v in os.environ.items() if k not in PATHSPEC_VARS}


def git(repo, *args, raw=False):
    """stdout of `git -C repo args` (stripped text, or bytes when raw), or None on failure."""
    try:
        p = subprocess.run(["git", "-C", repo] + list(args), capture_output=True,
                           timeout=CALL_TIMEOUT, env=git_env())
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    return p.stdout if raw else p.stdout.decode("utf-8", "replace").strip()


def common_dir(repo):
    """The repository's git common directory, absolute and with symlinks resolved, so every
    worktree and every spelling of the path (/var vs /private/var) names one ledger."""
    out = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not out:
        raise Fail("not inside a git repository ({})".format(repo))
    return os.path.realpath(out)


def has_ref(repo, ref):
    return git(repo, "show-ref", "--verify", "--quiet", ref) is not None


def commit_of(repo, rev):
    """The full id of the commit rev names, or None."""
    if not rev or rev.startswith("-"):
        return None
    return git(repo, "rev-parse", "--verify", "--quiet", rev + "^{commit}") or None


def current_branch(repo):
    return git(repo, "symbolic-ref", "--quiet", "--short", "HEAD") or None


def default_branch(repo):
    """origin/HEAD's branch, else main, else master (a local or remote-tracking branch of
    that name), else main."""
    head = git(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    if head and head.startswith("origin/"):
        return head[len("origin/"):]
    for name in ("main", "master"):
        if has_ref(repo, "refs/heads/" + name) or has_ref(repo, "refs/remotes/origin/" + name):
            return name
    return "main"


def default_range(repo):
    """A pre-merge dispatch's target when none is named: the current branch against the
    default branch, as origin has it when origin has it (that is what a forge merges into)."""
    dest = default_branch(repo)
    left = "origin/" + dest if has_ref(repo, "refs/remotes/origin/" + dest) else dest
    return "{}...{}".format(left, current_branch(repo) or "HEAD")


def merge_base(repo, a, b):
    out = git(repo, "merge-base", a, b)
    if not out:
        raise Fail("{} and {} share no history in {}".format(a, b, repo))
    return out.splitlines()[0]


# ------------------------------------------------------------------ the change
def fingerprint(repo, base, tip):
    """SHA-256 over the sorted records <path> TAB <old mode> TAB <new mode> TAB <old blob>
    TAB <new blob>, one per changed path, each ended by NUL (git paths cannot hold NUL, so
    the encoding is unambiguous). None when nothing changed."""
    records = [b"\t".join(r) for r in raw_records(repo, base, tip)]
    if not records:
        return None
    digest = hashlib.sha256()
    for record in sorted(records):
        digest.update(record + b"\0")
    return digest.hexdigest()


def raw_records(repo, base, tip):
    """The changed paths of base..tip as (path, old mode, new mode, old blob, new blob) byte
    tuples, from the raw diff both the fingerprint and the patch read."""
    out = git(repo, *DIFF_RAW, base, tip, "--", raw=True)
    if out is None:
        raise Fail("cannot diff {}..{} in {}".format(base, tip, repo))
    fields, records, i = out.split(b"\0"), [], 0
    while i + 1 < len(fields) and fields[i]:
        meta = fields[i][1:].split(b" ")
        if not fields[i].startswith(b":") or len(meta) != 5 or meta[4][:1] in (b"R", b"C"):
            raise Fail("unexpected raw diff output for {}..{}".format(base, tip))
        old_mode, new_mode, old_blob, new_blob = meta[:4]
        records.append((fields[i + 1], old_mode, new_mode, old_blob, new_blob))
        i += 2
    return records


def has_nul(repo, blobs):
    """The subset of blobs whose content holds a NUL byte, from one `git cat-file --batch`."""
    blobs = sorted(set(blobs))
    if not blobs:
        return set()
    try:
        p = subprocess.run(["git", "-C", repo, "cat-file", "--batch"], capture_output=True,
                           input=b"".join(b + b"\n" for b in blobs), timeout=CALL_TIMEOUT,
                           env=git_env())
    except (OSError, subprocess.TimeoutExpired):
        raise Fail("cannot read blobs in {}".format(repo))
    if p.returncode != 0:
        raise Fail("cannot read blobs in {}".format(repo))
    out, pos, found = p.stdout, 0, set()
    for blob in blobs:
        end = out.find(b"\n", pos)
        head = out[pos:end].split(b" ") if end >= 0 else []
        if len(head) != 3 or head[0] != blob or head[1] != b"blob":
            raise Fail("cannot read blob {} in {}".format(blob.decode("ascii", "replace"), repo))
        size = int(head[2])
        if b"\0" in out[end + 1:end + 1 + size]:
            found.add(blob)
        pos = end + 1 + size + 1
    return found


def patch(repo, base, tip):
    """The change base..tip as a patch the reviewer can read in full. Binary is decided by the
    content, never by gitattributes (a path marked -diff would otherwise show only a "Binary
    files differ" line for text the fingerprint binds): a path whose old or new blob holds a NUL
    byte gets one summary line after the text patch,
    `Binary file <path>: <old mode> <old blob> -> <new mode> <new blob>`, with the path quoted
    as git quotes a header path (see quote_path), so a file name cannot forge a line. Every
    other path is rendered by one `git diff --text` over the whole range with the fingerprint's
    own flags, the binary paths excluded as literal top-level pathspecs. The output never holds
    a NUL byte (a blob with a NUL anywhere, not only in git's first 8000 bytes, is summarized).
    The number of `diff --git` headers must equal the number the text records call for: one
    each, two for a change between a regular file, a symlink or a gitlink (git renders that as
    a delete and a create). Otherwise the packet does not match the fingerprint and Fail is
    raised. Raises Fail when git cannot diff it."""
    records = sorted(raw_records(repo, base, tip))
    want = set()
    for _path, old_mode, new_mode, old_blob, new_blob in records:
        if old_mode != b"160000" and old_blob.strip(b"0"):
            want.add(old_blob)
        if new_mode != b"160000" and new_blob.strip(b"0"):
            want.add(new_blob)
    binary = has_nul(repo, want)
    texts, skip, lines = 0, [], []
    for path, old_mode, new_mode, old_blob, new_blob in records:
        if old_blob in binary or new_blob in binary:
            skip.append(b":(top,exclude,literal)" + path)
            lines.append(b"Binary file " + quote_path(path) + b": " + old_mode + b" " + old_blob
                         + b" -> " + new_mode + b" " + new_blob + b"\n")
        else:
            both = old_mode != b"000000" and new_mode != b"000000"
            texts += 2 if both and old_mode[:2] != new_mode[:2] else 1
    out = b""
    if texts:
        pathspec = ["--", ":(top)"] + skip if skip else []
        out = git(repo, *(DIFF_PATCH + ["--text", base, tip] + pathspec), raw=True)
        if out is None:
            raise Fail("cannot diff {}..{} in {}".format(base, tip, repo))
    headers = sum(1 for line in out.split(b"\n") if line.startswith(b"diff --git "))
    if headers != texts:
        raise Fail("the review packet does not match the change: {} diffs expected, {} found, "
                   "for {}..{} in {}".format(texts, headers, base, tip, repo))
    return out + b"".join(lines)


def quote_path(path):
    """path as git quotes it in a header under its default core.quotePath: when it holds a
    control character, DEL, a byte of 0x80 or more, a double quote or a backslash, it is in
    double quotes with \\a \\b \\t \\n \\v \\f \\r \\" \\\\ and three-digit octal for the rest;
    any other path as it is."""
    if not any(c < 0x20 or c >= 0x7f or c in b'"\\' for c in path):
        return path
    names = {0x07: b"\\a", 0x08: b"\\b", 0x09: b"\\t", 0x0a: b"\\n", 0x0b: b"\\v",
             0x0c: b"\\f", 0x0d: b"\\r", 0x22: b'\\"', 0x5c: b"\\\\"}
    return b'"' + b"".join(names.get(c) or (b"\\%03o" % c if c < 0x20 or c >= 0x7f else
                                            bytes([c])) for c in path) + b'"'


def branch_of(repo, right):
    """The branch a range's right side names: the current branch for HEAD, a local branch,
    or the branch of an origin/<b> remote-tracking ref; None for anything else."""
    if right in ("HEAD", "@"):
        return current_branch(repo)
    if has_ref(repo, "refs/heads/" + right):
        return right
    if right.startswith("origin/") and has_ref(repo, "refs/remotes/" + right):
        return right[len("origin/"):]
    return None


def normalize(repo, rng):
    """One review target for rng (<left>..<tip> or <left>...<tip>). A left side naming a
    branch (X, or origin/X) is normalized: dest is X, dest_ref the ref as written, base the
    merge-base of dest_ref and the tip, and the target is full. A symbolic ref (origin/HEAD) is
    read as the branch it points at; one that names no branch is refused. Any other left side
    keeps its literal base in both forms (spec 3.1), has no dest, and is partial; the packet
    shows exactly base..tip, so the reviewed diff and the record always agree."""
    for dots in ("...", ".."):
        if dots in rng:
            left, right = rng.split(dots, 1)
            break
    else:
        raise Fail("a review range is <base>..<tip> or <base>...<tip>, not {}".format(rng))
    left, right = left or "HEAD", right or "HEAD"
    common = common_dir(repo)
    tip = commit_of(repo, right)
    if tip is None:
        raise Fail("cannot resolve {} in {}".format(right, repo))
    dest = dest_ref = full_ref = None
    if has_ref(repo, "refs/heads/" + left):
        dest, dest_ref, full_ref = left, left, "refs/heads/" + left
    elif left.startswith("origin/") and has_ref(repo, "refs/remotes/" + left):
        dest, dest_ref, full_ref = left[len("origin/"):], left, "refs/remotes/" + left
    if full_ref is not None:
        # A symbolic ref (origin/HEAD) names the branch it points at; HEAD is no destination.
        target = git(repo, "symbolic-ref", "--quiet", full_ref)
        if target and target.startswith("refs/heads/"):
            dest = dest_ref = target[len("refs/heads/"):]
            full_ref = target
        elif target and target.startswith("refs/remotes/origin/"):
            dest, dest_ref, full_ref = (target[len("refs/remotes/origin/"):],
                                        target[len("refs/remotes/"):], target)
        elif target:
            raise Fail("{} points at {}, which is neither a branch nor origin's: name the branch "
                       "the change lands on".format(left, target))
        if dest == "HEAD":
            raise Fail("{} names HEAD, not a branch: name the branch the change lands on, as "
                       "origin/<branch> or <branch>".format(left))
        base = merge_base(repo, full_ref, tip)
    else:
        base = commit_of(repo, left)
        if base is None:
            raise Fail("cannot resolve {} in {}".format(left, repo))
    return {"repo": common, "dest": dest, "dest_ref": dest_ref,
            "branch": branch_of(repo, right), "range": rng, "base": base, "tip": tip,
            "full": dest is not None, "fingerprint": fingerprint(repo, base, tip)}


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


# Reviews are ordered by comparing dispatched_at as strings, so only now()'s format is kept.
AT_FORMAT = re.compile(r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z\Z")


# ------------------------------------------------------------------ the ledger
def state_home():
    return os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"),
                                                             ".local", "state")


def ledger_key(common):
    return hashlib.sha256(common.encode("utf-8", "surrogateescape")).hexdigest()


def ledger_file(common):
    return os.path.join(state_home(), "xreview", "ledgers", ledger_key(common), "reviews.jsonl")


def legacy_file(repo):
    """The per-checkout v1 receipt file of the checkout repo is in (keyed by its top-level
    path, / mapped to _), or None outside a work tree."""
    top = git(repo, "rev-parse", "--show-toplevel")
    if not top:
        return None
    key = top.replace("/", "_")
    return os.path.join(state_home(), "xreview", key[1:] if key.startswith("_") else key,
                        "reviews.jsonl")


def read_entries(path):
    """The JSON objects on record in path, one per line. A damaged line is skipped, as jq's
    fromjson? skips it. Raises OSError when the file cannot be read."""
    entries = []
    with open(path, "rb") as fh:
        for line in fh:
            try:
                entry = json.loads(line.decode("utf-8"))
            except ValueError:
                continue
            if isinstance(entry, dict):
                entries.append(entry)
    return entries


def lock_wait():
    try:
        return float(os.environ.get("XREVIEW_LEDGER_LOCK_WAIT", LOCK_WAIT))
    except ValueError:
        return LOCK_WAIT


# The ledger lock is a directory (mkdir is atomic, and macOS has no flock(1)) holding one file,
# owner, with its holder's unique token. A lock older than LOCK_STALE was left by a crashed
# writer. Breaking it is serialized by a second directory, <lock>.break, and only removes a
# lock that still carries the token seen when it was judged stale: two writers that both saw
# it stale can never remove the fresh lock one of them took in between. A release removes the
# lock only while it carries the releaser's own token, checked and removed under the same
# break lock, so a breaker cannot slip in between the check and the removal.
#
# The break lock is held only for those few steps, and is never broken automatically: two
# writers that both judged it stale could each remove it and then each break or release
# under a break lock of its own. One older than LOCK_STALE means a writer died holding it, so
# every writer fails closed, naming it, until it is removed by hand.
def owner_of(lock):
    try:
        with open(os.path.join(lock, "owner"), encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def stale(path):
    try:
        return time.time() - os.stat(path).st_mtime > LOCK_STALE
    except FileNotFoundError:
        return False


def check_break_lock(guard):
    """Fail when the break lock guard is stale: a writer died holding it, and only a person
    may remove it."""
    if stale(guard):
        raise Fail("the break lock {0} is older than {1:.0f} s: a writer died holding it, and "
                   "it is never removed automatically. Check that no xreview is running, "
                   "remove it by hand (rmdir {0}), then retry".format(guard, LOCK_STALE))


def break_stale(lock, seen):
    """Remove lock if it is still stale and still carries the token seen (None: no owner
    file). Returns True when it removed the lock, False when it did not or another writer
    holds the break lock. Raises Fail when the break lock is stale."""
    guard = lock + ".break"
    try:
        os.mkdir(guard)
    except FileExistsError:
        check_break_lock(guard)
        return False
    try:
        if owner_of(lock) != seen or not stale(lock):
            return False
        try:
            os.unlink(os.path.join(lock, "owner"))
        except OSError:
            pass
        try:
            os.rmdir(lock)
        except OSError:
            return False
        return True
    finally:
        try:
            os.rmdir(guard)
        except OSError:
            pass


def acquire(lock):
    """Take the ledger lock, waiting up to lock_wait(); returns this holder's token. Fails at
    once while a stale break lock stands."""
    token = "{}-{}".format(os.getpid(), uuid.uuid4().hex)
    deadline = time.monotonic() + lock_wait()
    while True:
        check_break_lock(lock + ".break")
        try:
            os.mkdir(lock)
        except FileExistsError:
            seen = owner_of(lock)
            if stale(lock) and break_stale(lock, seen):
                continue
            if time.monotonic() >= deadline:
                raise Fail("the ledger lock {} is held".format(lock))
            time.sleep(0.05)
            continue
        with open(os.path.join(lock, "owner"), "w", encoding="utf-8") as fh:
            fh.write(token + "\n")
        return token


RELEASE_PAUSE = None    # a test seam: called between a release's token check and its removal


def release(lock, token):
    """Remove the lock, only while it carries token. The check and the removal run under
    <lock>.break, the breakers' own lock, so no breaker can replace the lock in between. A
    release that cannot take the break lock in time, or finds it stale, leaves the lock and
    only warns."""
    guard = lock + ".break"
    deadline = time.monotonic() + lock_wait()
    while True:
        try:
            os.mkdir(guard)
            break
        except FileExistsError:
            pass
        try:
            check_break_lock(guard)
        except Fail as e:
            print("xreview-ledger: {}; {} is left in place".format(e, lock), file=sys.stderr)
            return
        if time.monotonic() >= deadline:
            print("xreview-ledger: could not take {} to release {}; it will be broken once "
                  "stale".format(guard, lock), file=sys.stderr)
            return
        time.sleep(0.05)
    try:
        if owner_of(lock) != token:
            return
        if RELEASE_PAUSE:
            RELEASE_PAUSE()
        try:
            os.unlink(os.path.join(lock, "owner"))
        except OSError:
            pass
        try:
            os.rmdir(lock)
        except OSError:
            pass
    finally:
        try:
            os.rmdir(guard)
        except OSError:
            pass


def append(common, entry):
    """Append one v2 entry to common's ledger, under its lock. Returns "appended", or
    "present" when the ledger already holds an entry of that kind for that nonce."""
    common = os.path.realpath(common)
    if not (isinstance(entry, dict) and entry.get("v") == 2
            and entry.get("kind") in ("pending", "receipt")
            and isinstance(entry.get("nonce"), str) and entry["nonce"]
            and isinstance(entry.get("dispatched_at"), str)
            and AT_FORMAT.match(entry["dispatched_at"])
            and isinstance(entry.get("targets"), list) and entry["targets"]
            and all(isinstance(t, dict) and t.get("repo") == common for t in entry["targets"])):
        raise Fail("not a v2 ledger entry for {}".format(common))
    path = ledger_file(common)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    note = os.path.join(os.path.dirname(path), "repo")
    if not os.path.exists(note):
        with open(note, "w", encoding="utf-8") as fh:
            fh.write(common + "\n")
    lock = path + ".lock"
    token = acquire(lock)
    try:
        if os.path.lexists(path):
            for held in read_entries(path):
                if (held.get("v") == 2 and held.get("nonce") == entry["nonce"]
                        and held.get("kind") == entry["kind"]):
                    return "present"
        line = (json.dumps(entry, separators=(",", ":")) + "\n").encode("utf-8")
        if os.path.lexists(path) and os.path.getsize(path) > 0:
            with open(path, "rb") as fh:
                fh.seek(-1, os.SEEK_END)
                if fh.read(1) != b"\n":
                    line = b"\n" + line
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            if os.write(fd, line) != len(line):
                raise Fail("a short write to {}".format(path))
        finally:
            os.close(fd)
        return "appended"
    finally:
        release(lock, token)


# ------------------------------------------------------------------ the decision
def states_of(entries, match):
    """Each review's state - its receipt if one exists, otherwise its pending entry - for
    the v2 entries with a target that satisfies match, oldest dispatch first. Reviews
    dispatched in the same microsecond keep the order they reached the ledger."""
    first, state = {}, {}
    for index, entry in enumerate(entries):
        if entry.get("v") != 2 or entry.get("kind") not in ("pending", "receipt"):
            continue
        nonce, at = entry.get("nonce"), entry.get("dispatched_at")
        targets = entry.get("targets") if isinstance(entry.get("targets"), list) else []
        if not isinstance(nonce, str) or not isinstance(at, str):
            continue
        if not any(isinstance(t, dict) and match(t) for t in targets):
            continue
        first.setdefault(nonce, index)
        held = state.get(nonce)
        if held is None or (held["kind"] == "pending" and entry["kind"] == "receipt"):
            state[nonce] = entry
    return sorted(state.values(), key=lambda e: (e["dispatched_at"], first[e["nonce"]]))


def describe(entry):
    if entry.get("v") != 2:
        return "{}/{} (v1, never opens the gate)".format(entry.get("checkpoint") or "unrecorded",
                                                          entry.get("verdict") or "")
    state = entry.get("verdict") if entry.get("kind") == "receipt" else "pending"
    return "{}/{} {} at {}".format(entry.get("checkpoint"), state or "", entry.get("nonce"),
                                   entry.get("dispatched_at"))


def branch_record(entries, branch):
    """What is on record for a branch name: every v2 review with a target on that branch,
    then every v1 receipt naming it."""
    lines = []
    for entry in states_of(entries, lambda t: t.get("branch") == branch):
        target = next(t for t in entry["targets"]
                      if isinstance(t, dict) and t.get("branch") == branch)
        lines.append("{} (dest {}, {}, fingerprint {})".format(
            describe(entry), target.get("dest") or "none",
            "full" if target.get("full") is True else "partial",
            str(target.get("fingerprint") or "none")[:12]))
    lines.extend(describe(e) for e in entries if e.get("v") is None and e.get("branch") == branch)
    return lines


def decide(repo, dest, dest_rev, tip, branch=None):
    """The gate's decision for the change tip would land on dest, whose commit is dest_rev,
    in the repository repo is in. A dict: allow, reason (no final period), repo, dest, tip,
    base, fingerprint, on_record (this change's reviews) and on_record_branch."""
    out = {"allow": False, "reason": "", "repo": None, "dest": dest, "tip": None,
           "base": None, "fingerprint": None, "on_record": [], "on_record_branch": []}
    try:
        common = common_dir(repo)
    except Fail as e:
        out["reason"] = str(e)
        return out
    out["repo"] = common
    head = commit_of(repo, tip)
    if head is None:
        out["reason"] = ("the head {} is not available locally; fetch it (git fetch origin), "
                         "then retry".format(tip))
        return out
    out["tip"] = head
    target = commit_of(repo, dest_rev)
    if target is None:
        out["reason"] = ("the destination {} ({}) is not available locally; fetch it (git "
                         "fetch origin), then retry".format(dest, dest_rev))
        return out
    try:
        base = merge_base(repo, target, head)
        change = fingerprint(repo, base, head)
    except Fail as e:
        out["reason"] = str(e)
        return out
    out["base"], out["fingerprint"] = base, change
    if change is None:
        out["reason"] = "the change is empty: {} holds nothing that {} lacks".format(tip, dest)
        return out
    path = ledger_file(common)
    try:
        entries = read_entries(path) if os.path.lexists(path) else []
    except OSError as e:
        out["reason"] = "the review ledger {} is unreadable ({})".format(path, e.strerror or e)
        return out
    legacy = []
    old = legacy_file(repo)
    if old and os.path.exists(old):
        try:
            legacy = read_entries(old)
        except OSError:
            legacy = []
    reviews = states_of([e for e in entries if e.get("checkpoint") == "pre-merge"],
                        lambda t: (t.get("repo") == common and t.get("dest") == dest
                                   and t.get("full") is True and t.get("fingerprint") == change))
    out["on_record"] = [describe(e) for e in reviews]
    if branch:
        out["on_record_branch"] = branch_record(entries + legacy, branch)
    if reviews and reviews[-1]["kind"] == "receipt" and reviews[-1].get("verdict") == "approve":
        out["allow"] = True
        out["reason"] = "approved by the pre-merge review {}".format(reviews[-1]["nonce"])
    elif reviews:
        out["reason"] = "the latest review of this change is {}, not an approval".format(
            describe(reviews[-1]))
    else:
        out["reason"] = "no full-range pre-merge review of this change is on record"
    return out


# ------------------------------------------------------------------ the command line
def show(repo):
    """Print every line on record for repo: its ledger, then its checkout's legacy file.
    False when neither exists."""
    found = False
    for path in (ledger_file(common_dir(repo)), legacy_file(repo)):
        if path and os.path.exists(path):
            found = True
            with open(path, "rb") as fh:
                sys.stdout.write(fh.read().decode("utf-8", "replace"))
    return found


def main(argv):
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "key" and len(args) == 1:
            print(ledger_key(args[0]))
            return 0
        if cmd == "path" and len(args) == 1:
            print(ledger_file(common_dir(args[0])))
            return 0
        if cmd == "default-branch" and len(args) == 1:
            common_dir(args[0])
            print(default_branch(args[0]))
            return 0
        if cmd == "default-range" and len(args) == 1:
            common_dir(args[0])
            print(default_range(args[0]))
            return 0
        if cmd == "fingerprint" and len(args) == 3:
            change = fingerprint(*args)
            if change is None:
                return 3
            print(change)
            return 0
        if cmd == "diff" and len(args) == 3:
            sys.stdout.flush()
            sys.stdout.buffer.write(patch(*args))
            return 0
        if cmd == "normalize" and len(args) == 2:
            print(json.dumps(normalize(args[0], args[1]), separators=(",", ":")))
            return 0
        if cmd == "now" and not args:
            print(now())
            return 0
        if cmd == "append" and len(args) == 2:
            try:
                entry = json.loads(args[1])
            except ValueError:
                raise Fail("the entry is not JSON")
            print(append(args[0], entry))
            return 0
        if cmd == "show" and len(args) == 1:
            return 0 if show(args[0]) else 1
        if cmd == "decide" and (len(args) == 4 or (len(args) == 6 and args[4] == "--branch")):
            result = decide(args[0], args[1], args[2], args[3], args[5] if len(args) == 6 else None)
            print(json.dumps(result, separators=(",", ":")))
            return 0 if result["allow"] else 1
    except (Fail, OSError) as e:
        print("xreview-ledger: {}".format(e), file=sys.stderr)
        return 1
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
