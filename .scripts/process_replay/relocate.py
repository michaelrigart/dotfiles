"""`relocate-snapshot`: move the object snapshot to another directory on the same volume and rewrite the state's references to it
(spec 14.3 a, ruling R10).

The snapshot is renamed (os.rename, never a copy, never a delete). The references the harness reads objects through are then
rewritten: <state>/views/*.git/objects/info/alternates and <state>/branches.json, each written whole and only when it changed. Only a
string that is the old path, or lies under it, is rewritten. Run records, copied transcripts, reviews.json and report.md keep their
words: a verdict names what the scan saw then.

It refuses, before anything changes, when the state has no branches.json, when either path lies inside the other, when both
directories exist or neither does, and when the move would cross a volume. The state is held exclusively. A rename done and a
rewrite that failed is finished by running the command again: with the old directory gone and the new one there, it only rewrites.
It ends by checking two things: no string with the old prefix is left in those files, and every branch whose objects now lie under
the new directory resolves its final tip through its view.
"""
import glob
import os

from process_replay import common as C
from process_replay.common import Failed

VERIFIED = ("verified: no reference to {} remains in the views or branches.json; "
            "every rewritten view resolves its branches' final tips")


def add_args_relocate_snapshot(ap):
    ap.add_argument("--from", dest="from_dir", required=True, metavar="DIR", help="the snapshot directory to move")
    ap.add_argument("--to", dest="to_dir", default=C.snapshot_home(), metavar="DIR",
                    help="where it goes, on the same volume (default: %(default)s)")


def _inside(path, root):
    """`path` is `root` or lies under it."""
    return path == root or path.startswith(root.rstrip("/") + "/")


def _swap(s, old, new):
    """(s with `new` for its `old` prefix, 1) when s is `old` or lies under it, else (s, 0)."""
    if _inside(s, old):
        return new + s[len(old):], 1
    return s, 0


def rewrite_value(value, old, new):
    """(value, n): every string inside a JSON value (keys too) that equals `old` or starts with `old` + "/" has `new` for that prefix; n
    counts them. Any other string, prose that mentions `old` included, is left alone. `value` itself is not changed."""
    if isinstance(value, str):
        return _swap(value, old, new)
    if isinstance(value, list):
        out, n = [], 0
        for v in value:
            v, k = rewrite_value(v, old, new)
            out.append(v)
            n += k
        return out, n
    if isinstance(value, dict):
        out, n = {}, 0
        for key, v in value.items():
            key, k1 = rewrite_value(key, old, new)
            v, k2 = rewrite_value(v, old, new)
            out[key] = v
            n += k1 + k2
        return out, n
    return value, 0


def rewrite_alternates(text, old, new):
    """(text, n): the same rule, line by line; line endings stay as they were."""
    out, n = [], 0
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        body, k = _swap(body, old, new)
        out.append(body + line[len(line.rstrip("\r\n")):])
        n += k
    return "".join(out), n


def _device(path):
    """The st_dev of the nearest existing ancestor of `path` (itself, when it exists)."""
    path = os.path.abspath(path)
    while not os.path.lexists(path):
        parent = os.path.dirname(path)
        if parent == path:
            break
        path = parent
    return os.stat(path).st_dev


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except (OSError, ValueError) as e:
        raise Failed("cannot read {}: {}".format(path, e))


def _alternates(state):
    return sorted(glob.glob(os.path.join(glob.escape(state), "views", "*.git", "objects", "info", "alternates")))


def _scan(state, old, new):
    """What rewriting the state's references would do: ([(rel, path, text, n)] for the views' alternates, (path, doc, n) for
    branches.json). Reads only."""
    views = []
    for path in _alternates(state):
        text, n = rewrite_alternates(_read(path), old, new)
        views.append((os.path.relpath(path, state), path, text, n))
    path = os.path.join(state, "branches.json")
    doc = C.jload(path)
    if not isinstance(doc, dict):
        raise Failed("{} is not a JSON object: not a state to relocate".format(path))
    doc, n = rewrite_value(doc, old, new)
    return views, (path, doc, n)


def _write(path, data, how):
    try:
        how(path, data)
    except OSError as e:
        raise Failed("cannot write {}: {} (the move is done as far as it got; run the command again to finish)".format(path, e))


def _rename(old, new):
    """os.rename(old, new), making new's parent first; a parent made here and left empty by a failed rename is removed again."""
    made = []
    parent = os.path.dirname(new)
    while parent and not os.path.lexists(parent) and parent not in made:
        made.append(parent)
        parent = os.path.dirname(parent)
    try:
        os.makedirs(os.path.dirname(new), exist_ok=True)
        os.rename(old, new)
    except OSError as e:
        for d in made:
            try:
                os.rmdir(d)
            except OSError:
                pass
        raise Failed("cannot rename {} to {}: {}".format(old, new, e))


def _verify(state, old, new):
    views, (bpath, _doc, bn) = _scan(state, old, new)
    for rel, _path, _text, n in views:
        if n:
            raise Failed("verification failed: {} still has {} reference(s) to {}".format(rel, n, old))
    if bn:
        raise Failed("verification failed: {} still has {} reference(s) to {}".format(bpath, bn, old))
    checked = 0
    for b in (C.jload(bpath) or {}).get("branches") or []:
        objects = b.get("objects") if isinstance(b, dict) else None
        if not isinstance(objects, str) or not _inside(objects, new):
            continue
        view, tip = b.get("view"), b.get("final_tip")
        if not isinstance(view, str) or not isinstance(tip, str) or C.git_run(view, ["cat-file", "-e", tip + "^{commit}"]).returncode != 0:
            raise Failed("verification failed: branch {} does not resolve its final tip {} through its view {}".format(b.get("id"), tip, view))
        checked += 1
    return checked


@C.locked(lambda a: None if a.dry_run else "exclusive")
def cmd_relocate_snapshot(a):
    old, new, state = os.path.abspath(a.from_dir), os.path.abspath(a.to_dir), a.state
    if not os.path.isfile(os.path.join(state, "branches.json")):
        raise Failed("{} is not a state: it has no branches.json".format(state))
    if _inside(new, old) or _inside(old, new):
        raise Failed("{} and {} lie inside one another (or are one): nothing is moved".format(old, new))
    has_old, has_new = os.path.lexists(old), os.path.lexists(new)
    if has_old and has_new:
        raise Failed("both {} and {} exist: nothing is moved".format(old, new))
    if not has_old and not has_new:
        raise Failed("neither {} nor {} exists: nothing is moved".format(old, new))
    if has_old:
        if os.path.islink(old) or not os.path.isdir(old):
            raise Failed("{} is not a directory (a link is not followed): nothing is moved".format(old))
        if _device(old) != _device(os.path.dirname(new)):
            raise Failed("{} and {} are on different volumes: a rename cannot cross one, and nothing is copied".format(old, os.path.dirname(new)))
    views, (bpath, bdoc, bn) = _scan(state, old, new)
    vn = sum(n for _rel, _path, _text, n in views)
    dry = a.dry_run
    C.say(("would rename: {} -> {}" if dry else "rename: {} -> {}").format(old, new) if has_old else
          "already moved: {} is there and {} is gone".format(new, old))
    for rel, _path, _text, n in views:
        if n:
            C.say("  {}: {}".format(rel, n))
    if bn:
        C.say("  branches.json: {}".format(bn))
    C.say("{} {} references ({} in views' alternates, {} in branches.json)".format("would rewrite" if dry else "rewrote", vn + bn, vn, bn))
    if dry:
        return 0
    if has_old:
        _rename(old, new)
    for _rel, path, text, n in views:
        if n:
            _write(path, text, C.XR.write_whole)
    if bn:
        _write(bpath, bdoc, C.jsave)
    checked = _verify(state, old, new)
    C.say("checked {} final tips through their views".format(checked))
    C.say(VERIFIED.format(old))
    return 0
