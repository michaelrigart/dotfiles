"""inject: the injected tree of each inventoried branch, its defects' validation, the coverage gate and qualification (spec 4.3, 4.1).

For every opened candidate of branches.json, in order of its final round, newest first, up to MAX_CASES in all and PER_REPO from one
repository (a branch that waits on a judge holds its place, one that fails gives it up):

  1. fix groups     a fix range that two counted defects share is split by a blind judge (judge-split/<branch>-<range>);
                    a hunk it cannot place ("unsure") makes those defects one group, reverted and re-applied together.
  2. injected tree  <state>/work/<branch>, private to the harness: the final tip's tree (scratch.build), each group's fix reverted
                    with `git apply -R --index`, latest fix first, tests included, docs/superpowers pinned to the plan commit.
                    A patch that does not apply is dropped-revert. A revert that fails the cheap coherence check on a file it
                    changed is undone: incoherent. A Rust repository gets `cargo check` once, undoing reverts latest first.
  3. validation     judge-present/<defect>: is the defect's failure scenario reachable in the finished tree.
  4. coverage gate  a per-task defect that did not revert or validate gets one hand re-creation (recreate/<defect>.json, the agent
                    writes recreate/<defect>/done), confirmed by judge-same/<defect>, applied to the injected tree and validated
                    again (judge-present/<defect>-r).
  5. qualification  two or more assessable per-task defects and every P0/P1 of both classes assessable.

Writes injected/<branch>.json, repairs/<defect>.patch (the patch that puts the fix back: `git apply` on the injected tree) and
cases.json. `inject` is run again after each judge phase; it reads what has answered and goes on.
"""
import collections
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

from . import common as C
from . import inventory as I
from . import scratch
from .common import Failed

XR, L = C.XR, C.L

DOCS = "docs/superpowers"
MAX_CASES = 12                       # spec 4.1: 10-12 cases
PER_REPO = 4                         # at most four from one repository
MIN_TASK = 2                         # assessable per-task defects a branch needs
FILE_CAP, FILES_CAP, HUNK_CAP = 60000, 150000, 20000
CHECK_TIMEOUT = 60
OK = ("present", "recreated")
FAILED = ("dropped-revert", "incoherent", "not-present")
SEVERE = ("P0", "P1")


# ------------------------------------------------------------------ patches
def _diff(repo, a, b):
    """`git diff a b` outside docs/superpowers, as text that applies as it stands (binary files included)."""
    out = C.git(repo, *(["diff", "--no-color", "--binary", "--full-index"] + L.DIFF_FLAGS + L.DIFF_PREFIXES
                        + [a, b, "--", ":(top)", ":(top,exclude)" + DOCS]), raw=True)
    return out.decode("utf-8", "surrogateescape")


def fix_patch(view, a, b):
    """The change from commit a to commit b, read through `view`, without docs/superpowers."""
    return _diff(view, a, b)


def _bytes(text):
    return text.encode("utf-8", "surrogateescape")


def _judge_text(text):
    return _bytes(text).decode("utf-8", "replace")


_HUNK = re.compile(r"\A@@ -(\d+(?:,\d+)?) \+(\d+)((?:,\d+)?) @@(.*)\Z", re.S)


def _file_of(line):
    rest = line[len("diff --git "):]
    m = re.match(r"a/(.*) b/\1\Z", rest, re.S)
    return m.group(1) if m else rest


def parse_patch(text):
    """[{file, head: [line], hunks: [{old, ns, nlraw, nl, ol, tail, header, lines}]}], one per file of a git diff.
    A file with no hunk (binary, mode change, empty file) has `hunks: []`; its whole section is its head."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    sections = []
    for line in lines:
        if line.startswith("diff --git "):
            sections.append({"file": _file_of(line), "head": [line], "hunks": []})
            continue
        if not sections:
            raise Failed("not a git diff: {!r}".format(line[:60]))
        sec = sections[-1]
        m = _HUNK.match(line)
        if m:
            old, ns, nlraw, tail = m.groups()
            ol = int(old.split(",")[1]) if "," in old else 1
            sec["hunks"].append({"old": old, "ns": int(ns), "nlraw": nlraw, "nl": int(nlraw[1:]) if nlraw else 1, "ol": ol, "tail": tail,
                                 "header": line, "lines": []})
        elif sec["hunks"]:
            sec["hunks"][-1]["lines"].append(line)
        else:
            sec["head"].append(line)
    return sections


def item_list(sections):
    """The units a judge places: each hunk, or a file section that has none. [(section, hunk or None)]."""
    return [(si, hi) for si, sec in enumerate(sections) for hi in (range(len(sec["hunks"])) if sec["hunks"] else [None])]


def item_text(sections, item):
    si, hi = item
    sec = sections[si]
    if hi is None:
        return "\n".join(sec["head"]) + "\n"
    h = sec["hunks"][hi]
    return "\n".join(sec["head"] + [h["header"]] + h["lines"]) + "\n"


def select(sections, chosen):
    """The patch of the chosen items. A hunk's new-side start drops by what the hunks left out above it changed."""
    out = []
    for si, sec in enumerate(sections):
        if not sec["hunks"]:
            if (si, None) in chosen:
                out += sec["head"]
            continue
        keep = [hi for hi in range(len(sec["hunks"])) if (si, hi) in chosen]
        if not keep:
            continue
        out += sec["head"]
        left_out = 0
        for hi, h in enumerate(sec["hunks"]):
            if hi not in keep:
                left_out += h["nl"] - h["ol"]
                continue
            out.append("@@ -{} +{}{} @@{}".format(h["old"], h["ns"] - left_out, h["nlraw"], h["tail"]))
            out += h["lines"]
    return "\n".join(out) + "\n" if out else ""


# ------------------------------------------------------------------ the position of a fix
class Order(object):
    """Where a fix range's head stands in `git log --topo-order base..tip`, newest first. A head that is not there (a commit of
    rewritten history, kept as it was) stands where its committer date puts it among those that are."""

    def __init__(self, view, base, tip):
        self.view = view
        out = C.git(view, "log", "--topo-order", "--format=%H %ct", "{}..{}".format(base, tip))
        self.rows = [(s, int(t)) for s, t in (line.split() for line in out.splitlines())]
        self.index = dict((s, i) for i, (s, _t) in enumerate(self.rows))

    def rank(self, head):
        """Smaller is later: revert in ascending order."""
        if head in self.index:
            return float(self.index[head])
        when = int(C.git(self.view, "show", "-s", "--format=%ct", head))
        for i, (_s, t) in enumerate(self.rows):
            if t <= when:
                return i - 0.5
        return float(len(self.rows))


# ------------------------------------------------------------------ fix groups
def _is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def merge_ranges(view, keys):
    """{range: the range it stands for}. Ranges that share a commit are one change: they become the range from the earliest base to the
    latest head, so no commit is reverted twice. Ranges whose bases or heads are not in one line stay as they were."""
    shared = {}
    for k in keys:
        try:
            shared[k] = set(C.git(view, "rev-list", "{}..{}".format(*k)).split())
        except Failed:
            shared[k] = set()
    parent = dict((k, k) for k in keys)

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for i, k in enumerate(keys):
        for j in range(i):
            if shared[k] & shared[keys[j]]:
                parent[find(k)] = find(keys[j])
    clusters = collections.defaultdict(list)
    for k in keys:
        clusters[find(k)].append(k)
    out = dict((k, k) for k in keys)
    for members in clusters.values():
        if len(members) < 2:
            continue
        old = [m for m in members if all(m[0] == o[0] or C.git_ok(view, "merge-base", "--is-ancestor", m[0], o[0]) for o in members)]
        new = [m for m in members if all(m[1] == o[1] or C.git_ok(view, "merge-base", "--is-ancestor", o[1], m[1]) for o in members)]
        if old and new:
            for m in members:
                out[m] = (old[0][0], new[0][1])
    return out


def make_plan(a, view, br, defects, counts):
    """(plan, pending). plan = {groups: [{id, members, pieces: [{range, rank, text}], patch, files}], bad: {defect: reason}};
    None while a judge-split has not answered (pending counts them)."""
    order = Order(view, br["base"], br["final_tip"])
    ranges, bad = collections.OrderedDict(), {}
    fixes = {}
    for d in defects:
        fixes[d["id"]] = [(r[0], r[1]) for r in d.get("fixes") or [] if isinstance(r, (list, tuple)) and len(r) == 2]
    merged = merge_ranges(view, sorted(set(k for ks in fixes.values() for k in ks)))
    for d in defects:
        fixes[d["id"]] = list(collections.OrderedDict((merged[k], None) for k in fixes[d["id"]]))
        if not fixes[d["id"]]:
            bad[d["id"]] = "the inventory gives it no fix range"
        for key in fixes[d["id"]]:
            if key not in ranges:
                try:
                    text = fix_patch(view, *key)
                    secs = parse_patch(text)
                    ranges[key] = {"text": text, "sections": secs, "items": item_list(secs), "ids": []}
                except Failed as e:
                    ranges[key] = {"error": str(e)}
            if "error" in ranges[key]:
                bad.setdefault(d["id"], "its fix range cannot be read: " + ranges[key]["error"])
            elif d["id"] not in ranges[key]["ids"]:
                ranges[key]["ids"].append(d["id"])
    live = [d for d in defects if d["id"] not in bad]
    by_id = dict((d["id"], d) for d in defects)
    parent = dict((d["id"], d["id"]) for d in live)

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    owners, pending = {}, 0
    for key, r in ranges.items():
        ids = sorted(i for i in r.get("ids", []) if i not in bad)
        if len(ids) < 2 or not r["items"]:
            continue
        jid = "{}-{}".format(br["id"], I._hash(*key))
        budget = [FILES_CAP]
        hunks = []
        for n, it in enumerate(r["items"]):
            text = C.cap(_judge_text(item_text(r["sections"], it)), min(HUNK_CAP, max(budget[0], 0)))
            budget[0] -= len(text)
            hunks.append({"index": n, "file": r["sections"][it[0]]["file"], "text": text})
        I._put(a.state, "judge-split", jid, {
            "defects": [{"index": n, "summary": by_id[i].get("summary"), "file": by_id[i].get("file"), "line": by_id[i].get("line")}
                        for n, i in enumerate(ids)], "hunks": hunks}, counts)
        ans = C.judge_answer(a.state, "judge-split", jid)
        if not isinstance(ans, dict):
            pending += 1
            continue
        given = {}
        for e in ans.get("hunks") or []:
            if isinstance(e, dict) and _is_int(e.get("index")) and 0 <= e["index"] < len(hunks):
                given[e["index"]] = e.get("defect")
        owner = []
        for n in range(len(hunks)):
            v = given.get(n, "unsure")
            owner.append(None if v is None else ids[v] if _is_int(v) and 0 <= v < len(ids) else "*")
        if "*" in owner:
            for i in ids[1:]:
                parent[find(i)] = find(ids[0])
        owners[key] = owner
    if pending:
        return None, pending
    comps = collections.defaultdict(list)
    for d in live:
        comps[find(d["id"])].append(d["id"])
    groups = []
    for root, members in comps.items():
        members.sort()
        pieces = []
        for key in sorted(set(k for m in members for k in fixes[m])):
            r = ranges[key]
            if not r["items"]:
                continue
            own = owners.get(key)
            chosen = list(range(len(r["items"]))) if own is None else [n for n, o in enumerate(own) if o is not None and (o == "*" or find(o) == root)]
            if not chosen:
                continue
            text = r["text"] if len(chosen) == len(r["items"]) else select(r["sections"], set(r["items"][n] for n in chosen))
            pieces.append({"range": key, "rank": order.rank(key[1]), "text": text})
        if not pieces:
            for m in members:
                bad[m] = "no hunk of its fix is assigned to it" if any(ranges[k]["items"] for k in fixes[m]) else "its fix changes nothing outside docs/superpowers"
            continue
        pieces.sort(key=lambda p: p["rank"])
        patch = "".join(p["text"] for p in reversed(pieces))
        files = sorted(set(sec["file"] for p in pieces for sec in parse_patch(p["text"])))
        groups.append({"id": members[0], "members": members, "pieces": pieces, "patch": patch, "files": files})
    groups.sort(key=lambda g: (g["pieces"][0]["rank"], g["id"]))
    return {"groups": groups, "bad": bad}, 0


# ------------------------------------------------------------------ coherence
def _kind(path, name):
    try:
        with open(path, "rb") as f:
            first = f.readline(200).decode("utf-8", "replace")
    except OSError:
        return None
    if first.startswith("#!"):
        if "zsh" in first:
            return "zsh"
        if "bash" in first:
            return "bash"
    ext = os.path.splitext(name)[1]
    if ext in (".sh", ".bash"):
        return "bash"
    if ext == ".zsh" or "/zsh/functions/" in "/" + name:
        return "zsh"
    return {".py": "python", ".rb": "ruby", ".json": "json"}.get(ext)


def _run_check(argv, cwd):
    try:
        p = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, timeout=CHECK_TIMEOUT)
    except FileNotFoundError:
        return True, ""
    except subprocess.TimeoutExpired:
        return False, "timed out"
    lines = p.stderr.decode("utf-8", "replace").strip().splitlines()
    return p.returncode == 0, lines[-1] if lines else ""


def coherent(work, files):
    """(True, "") when every file of `files` (paths below `work`) that has a cheap syntax check passes it, else (False, "<path>: <why>").
    bash -n for .sh, .bash and a bash shebang; zsh -n for .zsh, a zsh shebang or a file under zsh/functions; Python's ast for .py;
    ruby -c for .rb; a JSON parse for .json. A file that is gone, or has no check, passes; so does one whose tool is not installed."""
    for name in sorted(files):
        path = os.path.join(work, name)
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        kind = _kind(path, name)
        if kind in ("bash", "zsh"):
            good, why = _run_check([kind, "-n", path], work)
        elif kind == "python":
            good, why = _run_check([shutil.which("python3") or sys.executable, "-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())", path], work)
        elif kind == "ruby":
            good, why = _run_check(["ruby", "-c", path], work)
        elif kind == "json":
            try:
                with open(path, "rb") as f:
                    json.loads(f.read().decode("utf-8"))
                good, why = True, ""
            except (ValueError, OSError) as e:
                good, why = False, str(e)
        else:
            continue
        if not good:
            return False, "{}: {}".format(name, why)
    return True, ""


def cargo_check(a, work, repo_name):
    """(passed, why) of `cargo check --offline --all-targets` in `work`, or None when cargo is not installed."""
    env = dict(os.environ, CARGO_TARGET_DIR=os.path.join(a.state, "cargo", repo_name))
    try:
        p = subprocess.run(["cargo", "check", "--offline", "--all-targets"], cwd=work, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                           timeout=getattr(a, "budget", 3600))
    except FileNotFoundError:
        return None
    except subprocess.TimeoutExpired:
        raise Failed("cargo check in {} did not finish within {} s".format(work, getattr(a, "budget", 3600)))
    tail = p.stderr.decode("utf-8", "replace").strip().splitlines()[-3:]
    return p.returncode == 0, "cargo check failed: " + " | ".join(x.strip() for x in tail)


# ------------------------------------------------------------------ the work repository
def _clean(work, rev):
    C.git(work, "reset", "-q", "--hard", rev)
    C.git(work, "clean", "-fdxq")


def _commit(work, message):
    stamp = "{} +0000".format(int(C.git(work, "log", "-1", "--format=%ct", "HEAD")) + scratch.HOUR)
    C.git(work, *(scratch.NEUTRAL + ["commit", "-q", "--allow-empty", "--no-verify", "-m", message]),
          env=dict(scratch.IDENTITY, GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp))
    return C.git(work, "rev-parse", "HEAD")


def run_reverts(work, final, groups):
    """Reset `work` to `final` and revert each group in order, latest fix first. {group id: (status, reason)}, status reverted,
    dropped-revert or incoherent; a group that is not reverted leaves the tree as it found it."""
    _clean(work, final)
    results = {}
    for g in groups:
        before = C.git(work, "write-tree")
        why = None
        for piece in g["pieces"]:
            p = C.git_run(work, scratch.NEUTRAL + ["apply", "-R", "--index", "--whitespace=nowarn", "-"], input=_bytes(piece["text"]))
            if p.returncode != 0:
                why = "its fix does not revert: " + (p.stderr.decode("utf-8", "replace").strip().splitlines() or ["git apply failed"])[0]
                break
        if why:
            C.git(work, "read-tree", "--reset", "-u", before)
            results[g["id"]] = ("dropped-revert", why)
            continue
        good, why = coherent(work, g["files"])
        if not good:
            C.git(work, "read-tree", "--reset", "-u", before)
            results[g["id"]] = ("incoherent", why)
            continue
        results[g["id"]] = ("reverted", "")
    return results


def pin_docs(work, view, plan_commit):
    """docs/superpowers of the work tree becomes the plan commit's."""
    C.git(work, "rm", "-r", "-q", "-f", "--ignore-unmatch", "--", DOCS)
    shutil.rmtree(os.path.join(work, DOCS), ignore_errors=True)
    listing = C.git(view, "ls-tree", "-r", "-z", "--full-tree", plan_commit, "--", DOCS, raw=True)
    for rec in filter(None, listing.split(b"\0")):
        meta, path = rec.split(b"\t", 1)
        mode, kind, sha = meta.decode().split()
        if kind != "blob":
            continue
        full = os.path.join(work, os.fsdecode(path))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        data = C.git(view, "cat-file", "blob", sha, raw=True)
        if mode == "120000":
            os.symlink(data, full)
        else:
            with open(full, "wb") as f:
                f.write(data)
            os.chmod(full, 0o755 if mode == "100755" else 0o644)
    if os.path.isdir(os.path.join(work, DOCS)):
        C.git(work, *(scratch.NEUTRAL + ["add", "-A", "-f", "--", DOCS]))


def stage1(a, br, view, plan, prev, work):
    """The injected tree. Reused from `prev` when its key (tips, plan commit, every group's patches) is the same and the work
    repository still has its commit. {key, final_commit, injected_commit, groups: {id: {status, reason, members}}}."""
    key = hashlib.sha256(json.dumps([br["final_tip"], br["base"], br["plan_commit"], sorted(plan["bad"].items()),
                                     [[g["id"], g["members"], [hashlib.sha1(_bytes(p["text"])).hexdigest() for p in g["pieces"]]] for g in plan["groups"]]]
                                    ).encode("utf-8")).hexdigest()
    if (prev and prev.get("key") == key and os.path.isdir(work) and C.git_ok(work, "cat-file", "-e", prev["injected_commit"] + "^{commit}")):
        return prev
    if os.path.exists(work):
        shutil.rmtree(work)
    objects = br.get("objects") or os.path.join(br["repo"], "objects")
    tree = C.git(view, "rev-parse", "--verify", br["final_tip"] + "^{tree}")
    tmp = tempfile.mkdtemp(prefix="inject-files.")
    try:
        files = os.path.join(tmp, "files")
        scratch.export(objects, br["final_tip"], files)
        final = scratch.build(objects, br["base"], files, work, br["dest"], br["branch"], br.get("dest_ref"), expect_tree=tree,
                              cache=os.path.join(a.state, "packs"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    groups = plan["groups"]
    results = run_reverts(work, final, groups)
    build_check = None
    if os.path.isfile(os.path.join(work, "Cargo.toml")):
        active = [g for g in groups if results[g["id"]][0] == "reverted"]
        name = C.repo_name(br["repo"])
        undone = 0
        while True:
            checked = cargo_check(a, work, name)
            if checked is None:
                build_check = "skipped: cargo not found"
                break
            if checked[0]:
                build_check = "passed" if not undone else "passed after undoing {} revert(s)".format(undone)
                break
            if not active:
                build_check = "failed with every revert undone: " + checked[1]
                break
            undone += 1
            victim = active.pop(0)
            results[victim["id"]] = ("incoherent", checked[1])
            again = run_reverts(work, final, active)
            for g in list(active):
                if again[g["id"]][0] != "reverted":
                    results[g["id"]] = again[g["id"]]
                    active.remove(g)
    pin_docs(work, view, br["plan_commit"])
    injected = _commit(work, scratch.MESSAGE)
    return {"key": key, "final_commit": final, "injected_commit": injected, "build_check": build_check,
            "groups": dict((g["id"], {"status": results[g["id"]][0], "reason": results[g["id"]][1], "members": g["members"]}) for g in groups)}


def files_input(work, rev, d):
    """[{path, text}]: the finding's file, then the files its fix changes, as `rev` has them."""
    names = []
    for n in [C.norm(d.get("file"))] + list(d.get("files") or []):
        if n and n not in names:
            names.append(n)
    out, room = [], FILES_CAP
    for n in names:
        if room <= 0:
            break
        try:
            data = C.git(work, "show", "{}:{}".format(rev, n), raw=True)
        except Failed:
            continue
        text = C.cap(data.decode("utf-8", "replace"), min(FILE_CAP, room))
        room -= len(text)
        out.append({"path": n, "text": text})
    return out


def _finding(d):
    return dict((k, d.get(k)) for k in I.KEYS)


# ------------------------------------------------------------------ the coverage gate
def tree_patches(work, final, tree_dir):
    """(patch, reverse patch) between the final tree and the edited copy of it, outside docs/superpowers."""
    tmp = tempfile.mkdtemp(prefix="inject-index.")
    try:
        gd = os.path.join(work, ".git")
        env = C.git_env({"GIT_INDEX_FILE": os.path.join(tmp, "index")})
        base = ["git", "--git-dir", gd, "--work-tree", tree_dir] + scratch.NEUTRAL
        for argv in (["add", "-A", "-f", "--", "."], ["write-tree"]):
            p = subprocess.run(base + argv, cwd=tree_dir, env=env, capture_output=True)
            if p.returncode != 0:
                raise Failed("cannot read {}: {}".format(tree_dir, p.stderr.decode("utf-8", "replace").strip()))
        edited = p.stdout.decode().strip()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    old = C.git(work, "rev-parse", final + "^{tree}")
    return _diff(work, old, edited), _diff(work, edited, old)


RECREATE_BRIEF = """Read {spec}. It holds a reported defect (finding), the change that fixed it (fix) and the path of a copy of the code (tree).

Edit only the files under {tree} so that the defect described is present again: undo what the fix did, and nothing else.
Do not use git. Leave every other file as it is.

When you have finished, create an empty file at {done}.
"""


def recreation(a, work, final, d, fix_text, counts):
    """('pending'|'unassessable'|'candidate', why, patch, reverse) of one per-task defect that did not revert or validate."""
    state = a.state
    brief = os.path.join(state, "recreate", d["id"] + ".json")
    tree = os.path.join(state, "recreate", d["id"], "tree")
    if not os.path.exists(brief):
        if not os.path.isdir(tree):
            scratch.export(os.path.join(work, ".git", "objects"), final, tree)
        C.jsave(brief, {"finding": _finding(d), "fix": C.cap(_judge_text(fix_text), I.REPORT_CAP * 2), "tree": C.aliased(state, tree)})
    text = os.path.join(state, "recreate", d["id"] + ".brief.md")
    if not os.path.exists(text):
        C.jsave(text, RECREATE_BRIEF.format(spec=C.aliased(state, brief), tree=C.aliased(state, tree),
                                            done=C.aliased(state, os.path.join(state, "recreate", d["id"], "done"))))
    if not os.path.exists(os.path.join(state, "recreate", d["id"], "done")):
        return "pending", "the recreation is not finished", None, None
    mine = os.path.join(state, "recreated", d["id"])
    if not os.path.exists(mine + ".patch"):
        patch, reverse = tree_patches(work, final, tree)
        for suffix, text in ((".repair.patch", reverse), (".patch", patch)):
            os.makedirs(os.path.dirname(mine), exist_ok=True)
            with open(mine + suffix, "wb") as f:
                f.write(_bytes(text))
    with open(mine + ".patch", "rb") as f:
        patch = f.read().decode("utf-8", "surrogateescape")
    with open(mine + ".repair.patch", "rb") as f:
        reverse = f.read().decode("utf-8", "surrogateescape")
    if not patch.strip():
        return "unassessable", "the recreation changed nothing", None, None
    I._put(state, "judge-same", d["id"], {"original": {"finding": _finding(d), "fix": C.cap(_judge_text(fix_text), XR.MAX_INTERDIFF)},
                                          "candidate": {"patch": C.cap(_judge_text(patch), XR.MAX_INTERDIFF)}}, counts)
    ans = C.judge_answer(state, "judge-same", d["id"])
    if not isinstance(ans, dict):
        return "pending", "judge-same has not answered", None, None
    if ans.get("answer") != "yes":
        return "unassessable", "the judge did not find the same defect ({})".format(ans.get("answer")), None, None
    return "candidate", "", patch, reverse


# ------------------------------------------------------------------ one branch
def locate(work, head, text):
    """(hunks, why): where a repair's change sits in the tree at `head`, found by applying the repair to a temporary index of that tree
    and reading the diff. [{file, start, end, new_start, new_end}]: start and end are lines of the tree as it is (a pure insertion is
    the line it follows), new_start and new_end lines once repaired. None and the reason when the repair does not apply there."""
    tmp = tempfile.mkdtemp(prefix="inject-locate.")
    try:
        env = {"GIT_INDEX_FILE": os.path.join(tmp, "index")}
        C.git(work, "read-tree", head, env=env)
        p = C.git_run(work, scratch.NEUTRAL + ["apply", "--cached", "--whitespace=nowarn", "-"], input=_bytes(text), env=env)
        if p.returncode != 0:
            return None, (p.stderr.decode("utf-8", "replace").strip().splitlines() or ["git apply failed"])[0]
        patch = _diff(work, head + "^{tree}", C.git(work, "write-tree", env=env))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    out = []
    for sec in parse_patch(patch):
        for h in sec["hunks"]:
            first = max(int(h["old"].split(",")[0]), 1)
            out.append({"file": sec["file"], "start": first, "end": first + max(h["ol"], 1) - 1, "new_start": h["ns"],
                        "new_end": h["ns"] + max(h["nl"], 1) - 1})
    return out, ""


def _write_repair(state, did, text):
    path = os.path.join(state, "repairs", did + ".patch")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(_bytes(text))
    return path


def process(a, br, counts):
    """The outcome of one branch: {state: waiting|qualified|disqualified, why, counts, case_defects, unassessable_task}."""
    state = a.state

    def done(kind, why, **more):
        return dict({"state": kind, "why": why, "counts": {}, "case_defects": [], "unassessable_task": []}, **more)

    inv = C.jload(os.path.join(state, "inventory", br["id"] + ".json"))
    defects = sorted((d for d in (inv or {}).get("defects") or [] if isinstance(d, dict) and d.get("counted") and isinstance(d.get("id"), str)),
                     key=lambda d: d["id"])
    task = [d for d in defects if d.get("class") == "task"]
    if len(task) < MIN_TASK:
        return done("disqualified", "fewer than two per-task defects (P0-P2)")
    if not br.get("plan_commit"):
        return done("disqualified", "no plan commit to pin docs/superpowers to")
    view = C.view(state, br["repo"], a.snapshot_root)
    if not C.git_ok(view, "cat-file", "-e", br["plan_commit"] + "^{commit}"):
        return done("disqualified", "the plan commit is gone")
    plan, wait = make_plan(a, view, br, defects, counts)
    if plan is None:
        return done("waiting", "waiting on {} fix-split judge(s)".format(wait))
    if a.dry_run:
        return done("waiting", "waiting: dry run")
    path = os.path.join(state, "injected", br["id"] + ".json")
    prev = C.jload(path) or {}
    work = os.path.join(state, "work", br["id"])
    s1 = stage1(a, br, view, plan, prev.get("stage1"), work)
    final, first = s1["final_commit"], s1["injected_commit"]
    _clean(work, first)
    groups = dict((g["id"], g) for g in plan["groups"])
    status = {}
    for gid, res in s1["groups"].items():
        for m in res["members"]:
            status[m] = (res["status"], res["reason"])
    for did, why in plan["bad"].items():
        status[did] = ("dropped-revert", why)
    group_of = dict((m, gid) for gid, g in groups.items() for m in g["members"])
    fix_text = {}
    for d in defects:
        g = groups.get(group_of.get(d["id"]))
        try:
            fix_text[d["id"]] = g["patch"] if g else "".join(fix_patch(view, r[0], r[1]) for r in d.get("fixes") or [])
        except Failed:
            fix_text[d["id"]] = ""

    waiting = 0
    for d in defects:
        if status[d["id"]][0] != "reverted":
            continue
        I._put(state, "judge-present", d["id"], {"finding": _finding(d), "files": files_input(work, first, d)}, counts)
        ans = C.judge_answer(state, "judge-present", d["id"])
        if not isinstance(ans, dict):
            waiting += 1
        elif ans.get("answer") == "yes":
            status[d["id"]] = ("present", "")
        else:
            status[d["id"]] = ("not-present", "the judge answered {}".format(ans.get("answer")))

    head, repairs, touched, applied = first, {}, set(), []
    hopeless = any(d.get("class") == "pre" and d.get("severity") in SEVERE and status[d["id"]][0] in FAILED for d in defects)
    failed_task = [d for d in task if status[d["id"]][0] in FAILED]
    if waiting == 0 and failed_task:
        got = {}
        for d in failed_task:
            got[d["id"]] = recreation(a, work, final, d, fix_text[d["id"]], counts)
            waiting += got[d["id"]][0] == "pending"
        if waiting == 0:
            for d in failed_task:
                kind, why, patch, reverse = got[d["id"]]
                if kind == "unassessable":
                    status[d["id"]] = ("unassessable", why)
                elif scratch.commit_patch(work, patch, "Apply change") is None:
                    status[d["id"]] = ("unassessable", "the recreation does not apply to the injected tree")
                else:
                    applied.append(d)
                    repairs[d["id"]] = reverse
                    touched |= set(sec["file"] for sec in parse_patch(patch))
            head = C.git(work, "rev-parse", "HEAD")
            for d in applied:
                I._put(state, "judge-present", d["id"] + "-r", {"finding": _finding(d), "files": files_input(work, head, d)}, counts)
                ans = C.judge_answer(state, "judge-present", d["id"] + "-r")
                if not isinstance(ans, dict):
                    waiting += 1
                elif ans.get("answer") == "yes":
                    status[d["id"]] = ("recreated", "")
                else:
                    status[d["id"]] = ("unassessable", "the judge answered {} on the finished tree".format(ans.get("answer")))
            for d in defects:
                if status[d["id"]][0] != "present" or d["id"] in repairs:
                    continue
                g = groups.get(group_of.get(d["id"]))
                near = set(g["files"] if g else []) | set(d.get("files") or []) | set([C.norm(d.get("file"))])
                if not near & touched:
                    continue
                I._put(state, "judge-present", d["id"] + "-v", {"finding": _finding(d), "files": files_input(work, head, d)}, counts)
                ans = C.judge_answer(state, "judge-present", d["id"] + "-v")
                if not isinstance(ans, dict):
                    waiting += 1
                elif ans.get("answer") != "yes":
                    status[d["id"]] = ("not-present", "the judge answered {} once the recreations were in".format(ans.get("answer")))
    complete = waiting == 0

    drec = {}
    for d in defects:
        s, why = status[d["id"]]
        own = d["id"]
        text = groups[group_of[own]]["patch"] if s == "present" else repairs[own] if s == "recreated" else None
        located = None
        if text is not None:
            located, problem = locate(work, head, text)
            if located is None and complete:
                s, why, text = "unassessable", "its repair does not apply to the finished tree: " + problem, None
        if text is not None:
            drec[own] = {"status": s, "reason": why, "group": group_of.get(own, own) if s == "present" else own,
                         "repair": _write_repair(state, own, text), "hunks": located or []}
        else:
            stale = os.path.join(state, "repairs", own + ".patch")
            if os.path.exists(stale):
                os.unlink(stale)
            drec[own] = {"status": s, "reason": why, "group": group_of.get(own, own), "repair": None, "hunks": []}
    C.jsave(path, {"work": work, "work_commit": head, "plan_commit": br["plan_commit"], "defects": drec, "complete": complete,
                   "build_check": s1.get("build_check"), "final_commit": final, "injected_commit": first, "stage1": s1})
    tally = dict(collections.Counter(v["status"] for v in drec.values()))
    ok_ids = [d["id"] for d in defects if drec[d["id"]]["status"] in OK]
    lost = [d for d in defects if drec[d["id"]]["status"] not in OK]
    unassessable = [d["id"] for d in task if drec[d["id"]]["status"] == "unassessable"]
    more = {"counts": tally, "unassessable_task": unassessable, "build_check": s1.get("build_check")}
    severe = [d["id"] for d in lost if d.get("severity") in SEVERE]
    if not complete:
        if hopeless:
            return done("waiting", "P0/P1 defect(s) not shown present: {}; waiting on {} recreation(s) for the coverage gate".format(
                ", ".join(severe), waiting), doomed=True, **more)
        return done("waiting", "waiting on {} judge(s) or recreation(s)".format(waiting), **more)
    if severe:
        return done("disqualified", "P0/P1 defect(s) not shown present: " + ", ".join(severe), **more)
    if sum(1 for d in task if drec[d["id"]]["status"] in OK) < MIN_TASK:
        return done("disqualified", "fewer than two assessable per-task defects", **more)
    return done("qualified", None, case_defects=ok_ids, work_commit=head, **more)


# ------------------------------------------------------------------ the command
def _final_at(b):
    rounds = b.get("rounds") or [{}]
    return (rounds[-1].get("at") or "", b["id"])


def _merged_key(b):
    return (I._epoch((b.get("merged") or {}).get("at")) or 0, _final_at(b)[0])


def cmd_inject(a):
    doc = C.jload(os.path.join(a.state, "branches.json"))
    if not isinstance(doc, dict) or not isinstance(doc.get("branches"), list):
        raise Failed("no branches.json in {}: run cases first".format(a.state))
    C.write_briefs(a.state)
    records = [b for b in doc["branches"] if isinstance(b, dict) and isinstance(b.get("id"), str)]
    candidates = [b for b in records if b.get("candidate")]
    ranked = sorted((b for b in candidates if b.get("opened")), key=_final_at, reverse=True)
    counts = collections.Counter()
    outcome, total, per_repo = {}, 0, collections.Counter()
    for br in ranked:
        if total >= MAX_CASES or per_repo[br["repo"]] >= PER_REPO:
            outcome[br["id"]] = {"state": "over", "why": "beyond the limit ({} per repository, {} in all)".format(PER_REPO, MAX_CASES), "counts": {},
                                 "case_defects": [], "unassessable_task": []}
            continue
        if not os.path.isfile(os.path.join(a.state, "inventory", br["id"] + ".json")):
            outcome[br["id"]] = {"state": "waiting", "why": "waiting on the inventory (cases judges pending)", "counts": {}, "case_defects": [],
                                 "unassessable_task": []}
        else:
            outcome[br["id"]] = process(a, br, counts)
        if outcome[br["id"]]["state"] == "qualified" or (outcome[br["id"]]["state"] == "waiting" and not outcome[br["id"]].get("doomed")):
            total += 1
            per_repo[br["repo"]] += 1
    out_cases, examined, unassessable = [], [], []
    for b in records:
        o = outcome.get(b["id"])
        if o is None:
            why = ("not opened" if b.get("candidate") else b.get("why") or "not a candidate")
            examined.append({"branch": b["id"], "qualified": False, "why": why, "counts": {}})
            continue
        entry = {"branch": b["id"], "qualified": o["state"] == "qualified", "why": o["why"], "counts": o["counts"]}
        if "build_check" in o:
            entry["build_check"] = o["build_check"]
        examined.append(entry)
        unassessable += o["unassessable_task"]
    for b in ranked:
        o = outcome[b["id"]]
        if o["state"] == "qualified":
            out_cases.append({"id": "c" + b["id"][1:], "branch": b["id"], "repo": b["repo"], "defects": o["case_defects"],
                              "original_rounds": len(b.get("rounds") or []), "work_commit": o["work_commit"]})
    hint = more_to_open(candidates, outcome, total, per_repo)
    if not a.dry_run:
        C.jsave(os.path.join(a.state, "cases.json"), {"cases": out_cases, "examined": examined, "coverage": {"unassessable_task": sorted(set(unassessable))}})
    states = collections.Counter(o["state"] for o in outcome.values())
    C.say("branches: {} candidate(s), {} opened; qualified {}, waiting {}, disqualified {}, beyond the limit {}".format(
        len(candidates), len(ranked), states["qualified"], states["waiting"], states["disqualified"], states["over"]))
    C.say("judge inputs: " + ", ".join("{} {}".format(k, counts[k]) for k in ("judge-split", "judge-present", "judge-same")) + "; stale inputs rewritten: {}".format(counts["stale"]))
    for b in ranked:
        o = outcome[b["id"]]
        if o["state"] != "qualified":
            C.say("  branch {} ({}): {}".format(b["id"], o["state"], o["why"]))
    for b in ranked:
        if (outcome[b["id"]].get("build_check") or "").startswith("skipped"):
            C.say("warning: branch {}: the build check was {}".format(b["id"], outcome[b["id"]]["build_check"]))
    if unassessable:
        C.say("per-task defects unassessable after the second attempt: " + ", ".join(sorted(set(unassessable))))
    if states["waiting"]:
        C.say("answers wait: run `process-replay.py pending`, then `process-replay.py inject` again")
    if hint:
        C.say("fewer than {} branches qualify or wait, and candidates remain: open more with `process-replay.py cases --open {}`".format(MAX_CASES, hint))
    return 0


def more_to_open(candidates, outcome, total, per_repo):
    """N for `cases --open N` when the branches that qualify or wait fall short of MAX_CASES and unopened candidates remain, else None.
    `cases` opens candidates by merge date, newest first: N reaches past the opened ones and as many more as could still take a place
    (a repository already at its limit takes none, but its candidates are in the way and are counted)."""
    ordered = sorted(candidates, key=_merged_key, reverse=True)
    last = max((i for i, b in enumerate(ordered) if b.get("opened")), default=-1)
    need, n, held = MAX_CASES - total, last + 1, collections.Counter(per_repo)
    if need <= 0 or last + 1 >= len(ordered):
        return None
    for b in ordered[last + 1:]:
        n += 1
        if held[b["repo"]] < PER_REPO:
            held[b["repo"]] += 1
            need -= 1
            if need == 0:
                break
    return n
