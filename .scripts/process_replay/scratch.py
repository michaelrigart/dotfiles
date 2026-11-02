"""The one scratch-repository builder (spec 7.1).

A scratch repository holds only the objects reachable from the merge base and one commit of the
tree under review, written into an object store of its own: no remote, no alternates, no tag. A
reviewer cannot reach a later fix commit from it by `git show` or `git fsck`.
"""
import contextlib
import hashlib
import os
import shutil
import subprocess
import tempfile

from . import common as C
from .common import Failed

IDENTITY = {"GIT_AUTHOR_NAME": "Developer", "GIT_AUTHOR_EMAIL": "developer@example.invalid",
            "GIT_COMMITTER_NAME": "Developer", "GIT_COMMITTER_EMAIL": "developer@example.invalid"}
MESSAGE = "Change under review"
HOUR = 3600
# Whatever the user's git configuration says (signing, hooks, line endings, attributes), the scratch
# repository's commits and trees are the same.
NEUTRAL = ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "core.autocrlf=false",
           "-c", "core.safecrlf=false", "-c", "core.attributesFile=/dev/null", "-c", "core.fsmonitor=false",
           "-c", "gc.auto=0", "-c", "core.logAllRefUpdates=false"]


@contextlib.contextmanager
def _borrowed(objects):
    """A throwaway bare repository reading `objects` through alternates: for reading the source only."""
    tmp = tempfile.mkdtemp(prefix="scratch-view.")
    try:
        p = subprocess.run(["git", "init", "-q", "--bare", "--template=", tmp], capture_output=True, env=C.git_env())
        if p.returncode != 0:
            raise Failed("cannot create a view: " + p.stderr.decode("utf-8", "replace").strip())
        os.makedirs(os.path.join(tmp, "objects", "info"), exist_ok=True)
        with open(os.path.join(tmp, "objects", "info", "alternates"), "w") as f:
            f.write(os.path.abspath(objects) + "\n")
        yield tmp
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _cat_file(view, shas):
    """(sha, bytes) for each sha, through one `git cat-file --batch`."""
    proc = subprocess.Popen(["git", "--git-dir", view, "cat-file", "--batch"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=C.git_env())
    try:
        for sha in shas:
            proc.stdin.write(sha.encode() + b"\n")
            proc.stdin.flush()
            head = proc.stdout.readline().split()
            if len(head) != 3 or head[1] != b"blob":
                raise Failed("cannot read blob {}: {}".format(sha, b" ".join(head).decode("utf-8", "replace")))
            size = int(head[2])
            data = proc.stdout.read(size)
            proc.stdout.read(1)
            yield sha, data
    finally:
        proc.stdin.close()
        proc.stdout.close()
        proc.stderr.close()
        proc.wait()


def export(objects, commit, dest_dir):
    """Write exactly the files of `commit`'s tree into dest_dir (a new or empty directory): the
    blobs as stored, with the executable bit and symlinks, ignored files included, no filters."""
    if os.path.isdir(dest_dir) and os.listdir(dest_dir):
        raise Failed("{} is not empty".format(dest_dir))
    os.makedirs(dest_dir, exist_ok=True)
    root = os.path.realpath(dest_dir)
    with _borrowed(objects) as view:
        listing = C.git(view, "ls-tree", "-r", "-z", "--full-tree", commit, raw=True)
        entries = []
        for rec in filter(None, listing.split(b"\0")):
            meta, path = rec.split(b"\t", 1)
            mode, kind, sha = meta.decode().split()
            if kind != "blob":
                raise Failed("{} is a {}, which a scratch repository cannot hold".format(path.decode("utf-8", "replace"), kind))
            entries.append((mode, sha, path))
        paths = {}
        for mode, sha, path in entries:
            paths.setdefault(sha, []).append((mode, path))
        for sha, data in _cat_file(view, sorted(paths)):
            for mode, path in paths[sha]:
                full = os.path.join(root, os.fsdecode(path))
                if os.path.commonpath([root, os.path.realpath(os.path.dirname(full))]) != root:
                    raise Failed("{} leaves the export directory".format(os.fsdecode(path)))
                os.makedirs(os.path.dirname(full), exist_ok=True)
                if mode == "120000":
                    os.symlink(data, full)
                else:
                    with open(full, "wb") as f:
                        f.write(data)
                    os.chmod(full, 0o755 if mode == "100755" else 0o644)


def _pack(view, objects, base, cache):
    """The pack of everything reachable from `base`: a file in `cache` (kept) or in a temp dir (the
    caller removes it). Returns (path, tempdir or None)."""
    if cache:
        os.makedirs(cache, exist_ok=True)
        key = hashlib.sha256((os.path.realpath(objects) + "\0" + base).encode()).hexdigest()[:32]
        path = os.path.join(cache, key + ".pack")
        if os.path.isfile(path):
            return path, None
        tmp, tmpdir = path + ".tmp{}".format(os.getpid()), None
    else:
        tmpdir = tempfile.mkdtemp(prefix="scratch-pack.")
        path = tmp = os.path.join(tmpdir, "base.pack")
    with open(tmp, "wb") as f:
        p = subprocess.run(["git", "--git-dir", view, "pack-objects", "--revs", "--stdout", "-q"], input=base.encode() + b"\n",
                           stdout=f, stderr=subprocess.PIPE, env=C.git_env())
    if p.returncode != 0:
        if tmpdir:
            shutil.rmtree(tmpdir, ignore_errors=True)
        else:
            os.unlink(tmp)
        raise Failed("cannot pack the base: " + p.stderr.decode("utf-8", "replace").strip())
    if tmp != path:
        os.replace(tmp, path)
    return path, tmpdir


def build(objects, base, files_dir, out, dest, branch, dest_ref=None, *, expect_tree, cache=None):
    """Build the scratch repository `out` and return its tip.

    `out` gets the objects reachable from `base` (from the object store `objects`), refs/heads/<dest>
    at base (omitted when branch is dest), refs/remotes/<dest_ref> at base when dest_ref names a remote
    branch (origin/main), HEAD on refs/heads/<branch>, and one commit above base holding exactly the
    files of `files_dir` (ignored ones included), by a fixed identity an hour after base's date.
    `expect_tree` (required), the tree id of the commit `files_dir` was exported from, is checked
    before the commit: a different tree, or none, raises Failed. No reflog is kept: it would carry
    the operator's identity and the build time. `cache`, a directory, keeps the pack per (objects, base)."""
    if os.path.isdir(out) and os.listdir(out):
        raise Failed("{} is not empty".format(out))
    os.makedirs(out, exist_ok=True)
    pack, tmpdir = None, None
    try:
        with _borrowed(objects) as view:
            tip = C.git(view, "rev-parse", "--verify", "--quiet", base + "^{commit}")
            pack, tmpdir = _pack(view, objects, tip, cache)
        p = subprocess.run(["git", "init", "-q", "--template=", out], capture_output=True, env=C.git_env())
        if p.returncode != 0:
            raise Failed("cannot create the scratch repository: " + p.stderr.decode("utf-8", "replace").strip())
        with open(pack, "rb") as f:
            p = subprocess.run(["git", "-C", out, "index-pack", "--stdin"], stdin=f, capture_output=True, env=C.git_env())
        if p.returncode != 0:
            raise Failed("cannot read the base pack: " + p.stderr.decode("utf-8", "replace").strip())
    finally:
        if tmpdir:
            shutil.rmtree(tmpdir, ignore_errors=True)
    g = lambda *args, **kw: C.git(out, *(NEUTRAL + list(args)), **kw)
    if branch != dest:
        g("update-ref", "refs/heads/" + dest, tip)
    if dest_ref and dest_ref != dest:
        g("update-ref", "refs/remotes/" + dest_ref, tip)
    g("update-ref", "refs/heads/" + branch, tip)
    g("symbolic-ref", "HEAD", "refs/heads/" + branch)
    g("read-tree", tip)
    for name in sorted(os.listdir(files_dir)):
        if name == ".git":
            continue
        src, dst = os.path.join(files_dir, name), os.path.join(out, name)
        if os.path.isdir(src) and not os.path.islink(src):
            shutil.copytree(src, dst, symlinks=True)
        else:
            shutil.copy2(src, dst, follow_symlinks=False)
    g("add", "-A", "-f", "--", ".")
    staged = g("write-tree")
    if not isinstance(expect_tree, str) or staged != expect_tree:
        raise Failed("the scratch tree {} is not the exported commit's tree {}".format(staged, expect_tree))
    when = int(g("log", "-1", "--format=%ct", tip)) + HOUR
    stamp = "{} +0000".format(when)
    env = dict(IDENTITY, GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp)
    g("commit", "-q", "--allow-empty", "--no-verify", "-m", MESSAGE, env=env)
    g("fsck", "--connectivity-only")
    shutil.rmtree(os.path.join(out, ".git", "logs"), ignore_errors=True)
    return g("rev-parse", "HEAD")


def commit_patch(scratch, patch_text, message):
    """Apply a patch (a `git diff` or format-patch text) to the scratch repository's index and work
    tree and commit it by the fixed identity, an hour after HEAD. Returns the new commit, or None
    when the patch does not apply (HEAD, the index and the work tree are then unchanged)."""
    data = patch_text if isinstance(patch_text, bytes) else patch_text.encode("utf-8", "surrogateescape")
    if not data.strip():
        return None
    p = C.git_run(scratch, NEUTRAL + ["apply", "--index", "--whitespace=nowarn", "-"], input=data)
    if p.returncode != 0:
        return None
    g = lambda *args, **kw: C.git(scratch, *(NEUTRAL + list(args)), **kw)
    try:
        stamp = "{} +0000".format(int(g("log", "-1", "--format=%ct", "HEAD")) + HOUR)
        g("commit", "-q", "--no-verify", "-m", message, env=dict(IDENTITY, GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp))
    except Failed:
        g("reset", "-q", "--hard", "HEAD")
        raise
    return g("rev-parse", "HEAD")
