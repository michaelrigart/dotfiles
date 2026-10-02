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
def git(repo, *args, raw=False):
    """stdout of `git -C repo args` (stripped text, or bytes when raw), or None on failure."""
    try:
        p = subprocess.run(["git", "-C", repo] + list(args), capture_output=True,
                           timeout=CALL_TIMEOUT)
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
    out = git(repo, *DIFF_RAW, base, tip, "--", raw=True)
    if out is None:
        raise Fail("cannot diff {}..{} in {}".format(base, tip, repo))
    fields, records, i = out.split(b"\0"), [], 0
    while i + 1 < len(fields) and fields[i]:
        meta = fields[i][1:].split(b" ")
        if not fields[i].startswith(b":") or len(meta) != 5 or meta[4][:1] in (b"R", b"C"):
            raise Fail("unexpected raw diff output for {}..{}".format(base, tip))
        old_mode, new_mode, old_blob, new_blob = meta[:4]
        records.append(b"\t".join([fields[i + 1], old_mode, new_mode, old_blob, new_blob]))
        i += 2
    if not records:
        return None
    digest = hashlib.sha256()
    for record in sorted(records):
        digest.update(record + b"\0")
    return digest.hexdigest()


def patch(repo, base, tip):
    """The change base..tip as a patch, with the fingerprint's own flags, so the reviewer reads
    every path and every byte the fingerprint names. Raises Fail when git cannot diff it."""
    out = git(repo, *DIFF_PATCH, base, tip, "--", raw=True)
    if out is None:
        raise Fail("cannot diff {}..{} in {}".format(base, tip, repo))
    return out


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
    merge-base of dest_ref and the tip, and the target is full. Any other left side keeps its
    literal base in both forms (spec 3.1), has no dest, and is partial; the packet shows
    exactly base..tip, so the reviewed diff and the record always agree."""
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


# ------------------------------------------------------------------ the ledger
def state_home():
    return os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"),
                                                             ".local", "state")


def ledger_key(common):
    return hashlib.sha256(common.encode("utf-8", "surrogateescape")).hexdigest()


def ledger_file(common):
    return os.path.join(state_home(), "xreview", "ledgers", ledger_key(common), "reviews.jsonl")


# ------------------------------------------------------------------ the command line
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
    except (Fail, OSError) as e:
        print("xreview-ledger: {}".format(e), file=sys.stderr)
        return 1
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
