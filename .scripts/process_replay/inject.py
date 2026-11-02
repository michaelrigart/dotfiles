"""inject: the injected tree of each inventoried branch, its defects' validation, the coverage gate and qualification (spec 4.3, 4.1).

For every opened candidate of branches.json, in order of its merge date (newest first, then final round), up to MAX_CASES in all and
PER_REPO from one repository (a branch that waits on a judge holds its place, one that fails gives it up):

  1. fix groups     a fix range that two defects share (counted or not) is split by a blind judge (judge-split/<branch>-<range>); a
                    test hunk goes with the defect it tests. A hunk it cannot place ("unsure") makes those defects one group,
                    reverted and re-applied together. Overlapping ranges are one range. A group with no counted defect is not reverted.
  2. injected tree  <state>/work/<branch>, private to the harness: the final tip's tree (scratch.build), each group's fix reverted
                    with `git apply -R --index`, latest fix first, tests included, docs/superpowers pinned to the plan commit.
                    A patch that does not apply is dropped-revert. A revert that fails the cheap coherence check is undone:
                    incoherent. A Rust repository gets `cargo check` once, undoing reverts latest first.
  3. validation     judge-present/<defect>: is the defect's failure scenario reachable in that tree.
  4. settling       the tree a case ships is REBUILT from the final tree: the reverts of the groups with a present defect, then the
                    accepted recreations (gate.py), then docs pinned. Nothing else is in it. Each assessable defect's repair is
                    located in it (patches.locate); one that does not apply there is demoted and the tree rebuilt, until none is.
                    check_invariant then re-applies every repair and restores docs/superpowers: the result must be the final tree.
  5. coverage gate  gate.py: a per-task defect that did not revert or validate (or was demoted) gets one hand re-creation.
  6. qualification  two or more assessable per-task defects and every P0/P1 of both classes assessable.

Build checks (spec 12, R2) are cheap and lexical, not a build: bash -n, zsh -n, Python's ast, ruby -c and a JSON parse on the files a
revert changed; a revert that removes a definition (def, class, function, fn, a top-level assignment, a shell function) that another
tracked file still mentions as a word is incoherent; `cargo check --offline --all-targets` once for a Rust repository. A tool that is
not installed, and a cargo that times out, are recorded (checks_skipped, build_check), never silent and never fatal.

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
from . import gate as G
from . import inventory as I
from . import patches as P
from . import scratch
from .common import Failed

XR, L = C.XR, C.L

DOCS = P.DOCS
MAX_CASES = 12                       # spec 4.1: 10-12 cases
PER_REPO = 4                         # at most four from one repository
MIN_TASK = 2                         # assessable per-task defects a branch needs
HUNK_CAP, FILES_CAP = 20000, 150000
CHECK_TIMEOUT = 60
OK = ("present", "recreated")
FAILED = ("dropped-revert", "incoherent", "not-present")
SEVERE = ("P0", "P1")

fix_patch = P.fix_patch


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


def make_plan(a, view, br, defects, counted, counts):
    """(plan, pending). `defects` are all the branch's, counted or not; `counted` the ids of those whose fix is reverted. A range two
    of them share is split by a judge, so an uncounted defect's hunks stay applied. plan = {groups: [{id, members, pieces: [{range,
    rank, text}], patch, files}], bad: {defect: reason}}, with no group that has no counted member; None while a judge-split has not
    answered (pending counts them)."""
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
                    text = P.fix_patch(view, *key)
                    secs = P.parse_patch(text)
                    ranges[key] = {"text": text, "sections": secs, "items": P.item_list(secs), "ids": []}
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
            text = C.cap(P.judge_text(P.item_text(r["sections"], it)), min(HUNK_CAP, max(budget[0], 0)))
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
        if not any(m in counted for m in members):
            continue
        pieces = []
        for key in sorted(set(k for m in members for k in fixes[m])):
            r = ranges[key]
            if not r["items"]:
                continue
            own = owners.get(key)
            chosen = list(range(len(r["items"]))) if own is None else [n for n, o in enumerate(own) if o is not None and (o == "*" or find(o) == root)]
            if not chosen:
                continue
            text = r["text"] if len(chosen) == len(r["items"]) else P.select(r["sections"], set(r["items"][n] for n in chosen))
            pieces.append({"range": key, "rank": order.rank(key[1]), "text": text})
        if not pieces:
            for m in members:
                bad[m] = "no hunk of its fix is assigned to it" if any(ranges[k]["items"] for k in fixes[m]) else "its fix changes nothing outside docs/superpowers"
            continue
        pieces.sort(key=lambda p: p["rank"])
        patch = "".join(p["text"] for p in reversed(pieces))
        groups.append({"id": members[0], "members": members, "pieces": pieces, "patch": patch, "files": P.files_of(patch)})
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


def _run_check(argv, cwd, notes):
    try:
        p = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True, timeout=CHECK_TIMEOUT)
    except FileNotFoundError:
        if notes is not None and "{} not found".format(argv[0]) not in notes:
            notes.append("{} not found".format(argv[0]))
        return True, ""
    except subprocess.TimeoutExpired:
        return False, "timed out"
    lines = p.stderr.decode("utf-8", "replace").strip().splitlines()
    return p.returncode == 0, lines[-1] if lines else ""


def coherent(work, files, notes=None):
    """(True, "") when every file of `files` (paths below `work`) that has a cheap syntax check passes it, else (False, "<path>: <why>").
    bash -n for .sh, .bash and a bash shebang; zsh -n for .zsh, a zsh shebang or a file under zsh/functions; Python's ast for .py;
    ruby -c for .rb; a JSON parse for .json. A file that is gone, or has no check, passes. So does one whose tool is not installed,
    but the tool is then named in `notes` (a list), to be recorded."""
    for name in sorted(files):
        path = os.path.join(work, name)
        if not os.path.isfile(path) or os.path.islink(path):
            continue
        kind = _kind(path, name)
        if kind in ("bash", "zsh"):
            good, why = _run_check([kind, "-n", path], work, notes)
        elif kind == "python":
            good, why = _run_check([shutil.which("python3") or sys.executable, "-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())", path], work, notes)
        elif kind == "ruby":
            good, why = _run_check(["ruby", "-c", path], work, notes)
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


_DEFINES = [re.compile(x) for x in (
    r"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)", r"^\s*class\s+([A-Za-z_]\w*)", r"^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_][\w:-]*)",
    r"^\s*([A-Za-z_][\w-]*)\s*\(\)\s*\{?\s*$", r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+([A-Za-z_]\w*)",
    r"^([A-Za-z_]\w*)\s*=[^=]")]


def defined_by(lines):
    out = set()
    for line in lines:
        for rx in _DEFINES:
            m = rx.match(line)
            if m:
                out.add(m.group(1))
    return out


def removed_names(patch):
    """The names a revert of `patch` (a fix) removes: defined by the lines the fix added and not by those it removed."""
    plus, minus = [], []
    for line in patch.split("\n"):
        if line.startswith("+") and not line.startswith("+++"):
            plus.append(line[1:])
        elif line.startswith("-") and not line.startswith("---"):
            minus.append(line[1:])
    return sorted(defined_by(plus) - defined_by(minus))


def dangling(work, patch, files):
    """(True, "") unless a name the revert of `patch` removed is still used, as a word, by a tracked file it did not change (outside
    docs/superpowers): then (False, "<name> is still used by <file>"). Lexical: a comment or a string that says the name counts."""
    skip = [":(top,exclude)" + f for f in [DOCS] + list(files)]
    for name in removed_names(patch)[:50]:
        p = C.git_run(work, ["grep", "-l", "-w", "-F", "-I", "-e", name, "--", ":(top)"] + skip)
        if p.returncode == 0:
            return False, "{} is still used by {}".format(name, p.stdout.decode("utf-8", "replace").split("\n")[0])
    return True, ""


def cargo_check(a, work, repo_name):
    """(passed, why) of `cargo check --offline --all-targets` in `work`; None when cargo is not installed; (None, why) on a timeout."""
    env = dict(os.environ, CARGO_TARGET_DIR=os.path.join(a.state, "cargo", repo_name))
    budget = getattr(a, "budget", 3600)
    try:
        p = subprocess.run(["cargo", "check", "--offline", "--all-targets"], cwd=work, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=budget)
    except FileNotFoundError:
        return None
    except subprocess.TimeoutExpired:
        return None, "cargo check did not finish within {} s".format(budget)
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


def run_reverts(work, final, groups, notes=None):
    """Reset `work` to `final` and revert each group in order, latest fix first. {group id: (status, reason)}, status reverted,
    dropped-revert or incoherent; a group that is not reverted leaves the tree as it found it."""
    _clean(work, final)
    results = {}
    for g in groups:
        before = C.git(work, "write-tree")
        why = None
        for piece in g["pieces"]:
            p = C.git_run(work, scratch.NEUTRAL + ["apply", "-R", "--index", "--whitespace=nowarn", "-"], input=P.to_bytes(piece["text"]))
            if p.returncode != 0:
                why = "its fix does not revert: " + (p.stderr.decode("utf-8", "replace").strip().splitlines() or ["git apply failed"])[0]
                break
        if why:
            C.git(work, "read-tree", "--reset", "-u", before)
            results[g["id"]] = ("dropped-revert", why)
            continue
        good, why = coherent(work, g["files"], notes)
        if good:
            good, why = dangling(work, g["patch"], g["files"])
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
    """The first injected tree: every group reverted, to be judged. Reused from `prev` when its key (tips, plan commit, every group's
    patches) is the same and the work repository still has its commit. {key, final_commit, injected_commit, build_check, checks_skipped,
    groups: {id: {status, reason, members}}}."""
    key = hashlib.sha256(json.dumps([br["final_tip"], br["base"], br["plan_commit"], sorted(plan["bad"].items()),
                                     [[g["id"], g["members"], [hashlib.sha1(P.to_bytes(p["text"])).hexdigest() for p in g["pieces"]]] for g in plan["groups"]]]
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
    groups, notes = plan["groups"], []
    results = run_reverts(work, final, groups, notes)
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
            if checked[0] is None or not active:
                for g in active:
                    results[g["id"]] = ("incoherent", checked[1])
                run_reverts(work, final, [], notes)
                build_check = ("timed out: " if checked[0] is None else "failed with every revert undone: ") + checked[1]
                break
            undone += 1
            victim = active.pop(0)
            results[victim["id"]] = ("incoherent", checked[1])
            again = run_reverts(work, final, active, notes)
            for g in list(active):
                if again[g["id"]][0] != "reverted":
                    results[g["id"]] = again[g["id"]]
                    active.remove(g)
    pin_docs(work, view, br["plan_commit"])
    injected = _commit(work, scratch.MESSAGE)
    return {"key": key, "final_commit": final, "injected_commit": injected, "build_check": build_check, "checks_skipped": sorted(notes),
            "groups": dict((g["id"], {"status": results[g["id"]][0], "reason": results[g["id"]][1], "members": g["members"]}) for g in groups)}


def assemble(work, final, view, plan_commit, groups, patches, notes):
    """Rebuild `work` from the final tree with nothing but: the reverts of `groups`, docs/superpowers pinned, then `patches` [(id, text)]
    one commit each. (head, {group id: (status, reason)} of the groups that did not revert, [ids of the patches that did not apply])."""
    results = run_reverts(work, final, groups, notes)
    pin_docs(work, view, plan_commit)
    head = _commit(work, scratch.MESSAGE)
    failed = []
    for did, text in patches:
        sha = scratch.commit_patch(work, text, "Apply change")
        if sha is None:
            failed.append(did)
        else:
            head = sha
    return head, dict((g, r) for g, r in results.items() if r[0] != "reverted"), failed


def check_invariant(br, work, final, head, steps):
    """The injected tree holds no edit the harness does not track: re-applying the repairs `steps` [(label, patch)] in order to the tree at
    `head` and restoring docs/superpowers from the final tree gives exactly the final tree. Failed (naming the branch and the defects) if not."""
    tmp = tempfile.mkdtemp(prefix="inject-invariant.")
    try:
        env = {"GIT_INDEX_FILE": os.path.join(tmp, "index")}
        C.git(work, "read-tree", head, env=env)
        for label, text in steps:
            p = C.git_run(work, scratch.NEUTRAL + ["apply", "--cached", "--whitespace=nowarn", "-"], input=P.to_bytes(text), env=env)
            if p.returncode != 0:
                raise Failed("branch {}: the repair of {} does not apply to its injected tree: {}".format(
                    br["id"], label, (p.stderr.decode("utf-8", "replace").strip().splitlines() or ["git apply failed"])[0]))
        C.git(work, "rm", "-r", "--cached", "-q", "--ignore-unmatch", "--", DOCS, env=env)
        if C.git_ok(work, "cat-file", "-e", "{}:{}".format(final, DOCS)):
            C.git(work, "read-tree", "--prefix=" + DOCS + "/", "{}:{}".format(final, DOCS), env=env)
        got = C.git(work, "write-tree", env=env)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    want = C.git(work, "rev-parse", final + "^{tree}")
    if got != want:
        names = C.git(work, "diff", "--name-only", want, got).split("\n")
        raise Failed("branch {}: the injected tree holds an edit that no repair undoes ({}); defects: {}".format(
            br["id"], ", ".join(n for n in names if n)[:300], ", ".join(label for label, _t in steps) or "none"))


# ------------------------------------------------------------------ settling: the tree a case ships
class Tree(object):
    """The injected tree of one branch as the statuses say it should be. status {defect: (status, reason)}; rec {defect: (patch, reverse)}
    of the accepted recreations. settle() rebuilds the tree from the final tree, locates every assessable defect's repair in it and
    demotes the ones that do not apply there, until none is demoted."""

    def __init__(self, a, br, view, work, s1, plan, status, notes):
        self.a, self.br, self.view, self.work, self.notes = a, br, view, work, notes
        self.final, self.head = s1["final_commit"], s1["injected_commit"]
        self.ordered, self.status, self.rec, self.located = plan["groups"], status, {}, {}

    def active(self):
        return [g for g in self.ordered if any(self.status.get(m, ("",))[0] == "present" for m in g["members"])]

    def _demote(self, g, status, why):
        for m in g["members"]:
            if self.status.get(m, ("",))[0] == "present":
                self.status[m] = (status, why)

    def _resolve(self, active, g, why, demote):
        """The repair of `g` does not apply to the tree. A repair made with an older fix's lines in place needs that fix not reverted:
        drop the oldest other group whose absence lets it apply; failing that, drop `g`."""
        for h in sorted((x for x in active if x is not g), key=lambda x: -x["pieces"][0]["rank"]):
            head, _dropped, _failed = assemble(self.work, self.final, self.view, self.br["plan_commit"], [x for x in active if x is not h], [], self.notes)
            if P.locate(self.work, head, g["patch"])[0] is not None:
                self._demote(h, demote, "dropped so that the repair of {} applies to the finished tree".format(g["id"]))
                return
        self._demote(g, demote, "its repair does not apply to the finished tree: " + why)

    def build(self, patches):
        return assemble(self.work, self.final, self.view, self.br["plan_commit"], self.active(), patches, self.notes)

    def settle(self, demote):
        while True:
            active = self.active()
            head, dropped, failed = self.build(sorted((i, p) for i, (p, _r) in self.rec.items()))
            changed = False
            for g in active:
                if g["id"] in dropped:
                    self._demote(g, "dropped-revert", dropped[g["id"]][1])
                    changed = True
            for did in failed:
                self.status[did] = ("unassessable", "the recreation does not apply to the injected tree")
                del self.rec[did]
                changed = True
            if changed:
                continue
            located, failing = {}, []
            for g in active:
                hunks, why = P.locate(self.work, head, g["patch"])
                if hunks is None:
                    failing.append((g, why))
                else:
                    for m in g["members"]:
                        if self.status.get(m, ("",))[0] == "present":
                            located[m] = hunks
            if failing:
                self._resolve(active, failing[0][0], failing[0][1], demote)
                continue
            for did, (_p, reverse) in sorted(self.rec.items()):
                hunks, why = P.locate(self.work, head, reverse)
                if hunks is None:
                    self.status[did] = ("unassessable", "its repair does not apply to the finished tree: " + why)
                    del self.rec[did]
                    changed = True
                else:
                    located[did] = hunks
            if not changed:
                self.head, self.located = head, located
                return head

    def steps(self):
        """The repairs in the order that undoes the build: the recreations (last first), then the groups, oldest fix first."""
        return ([(did, r) for did, (_p, r) in sorted(self.rec.items(), reverse=True)]
                + [(g["id"], g["patch"]) for g in reversed(self.active())])


# ------------------------------------------------------------------ one branch
def _write_repair(state, did, text):
    path = os.path.join(state, "repairs", did + ".patch")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(P.to_bytes(text))
    return path


def process(a, br, counts):
    """The outcome of one branch: {state: waiting|qualified|disqualified, why, counts, case_defects, unassessable_task, ...}."""
    state = a.state

    def done(kind, why, **more):
        return dict({"state": kind, "why": why, "counts": {}, "case_defects": [], "unassessable_task": []}, **more)

    inv = C.jload(os.path.join(state, "inventory", br["id"] + ".json"))
    everything = sorted((d for d in (inv or {}).get("defects") or [] if isinstance(d, dict) and isinstance(d.get("id"), str)), key=lambda d: d["id"])
    defects = [d for d in everything if d.get("counted")]
    counted = set(d["id"] for d in defects)
    task = [d for d in defects if d.get("class") == "task"]
    if len(task) < MIN_TASK:
        return done("disqualified", "fewer than two per-task defects (P0-P2)")
    if not br.get("plan_commit"):
        return done("disqualified", "no plan commit to pin docs/superpowers to")
    view = C.view(state, br["repo"], a.snapshot_root)
    if not C.git_ok(view, "cat-file", "-e", br["plan_commit"] + "^{commit}"):
        return done("disqualified", "the plan commit is gone")
    plan, wait = make_plan(a, view, br, everything, counted, counts)
    if plan is None:
        return done("waiting", "waiting on {} fix-split judge(s)".format(wait))
    if a.dry_run:
        return done("waiting", "waiting: dry run")
    path = os.path.join(state, "injected", br["id"] + ".json")
    prev = C.jload(path) or {}
    work = os.path.join(state, "work", br["id"])
    s1 = stage1(a, br, view, plan, prev.get("stage1"), work)
    final, first = s1["final_commit"], s1["injected_commit"]
    notes = list(s1.get("checks_skipped") or [])
    groups = dict((g["id"], g) for g in plan["groups"])
    status = {}
    for gid, res in s1["groups"].items():
        for m in res["members"]:
            if m in counted:
                status[m] = (res["status"], res["reason"])
    for did, why in plan["bad"].items():
        if did in counted:
            status[did] = ("dropped-revert", why)
    group_of = dict((m, gid) for gid, g in groups.items() for m in g["members"])
    fix_text = {}
    for d in defects:
        g = groups.get(group_of.get(d["id"]))
        try:
            fix_text[d["id"]] = g["patch"] if g else "".join(P.fix_patch(view, r[0], r[1]) for r in d.get("fixes") or [])
        except Failed:
            fix_text[d["id"]] = ""
    tree = Tree(a, br, view, work, s1, plan, status, notes)

    wait_judge = wait_agent = 0
    for d in defects:
        if status[d["id"]][0] != "reverted":
            continue
        ans = G.validate(state, work, first, d, d["id"], counts)
        if ans is None:
            wait_judge += 1
        elif ans == "yes":
            status[d["id"]] = ("present", "")
        else:
            status[d["id"]] = ("not-present", "the judge answered {}".format(ans))

    if wait_judge == 0:
        tree.settle("dropped-revert")
        failed_task = [d for d in task if status[d["id"]][0] in FAILED]
        got = {}
        for d in failed_task:
            got[d["id"]] = G.recreation(a, work, final, d, fix_text[d["id"]], counts)
            wait_agent += got[d["id"]][0] == "agent"
            wait_judge += got[d["id"]][0] == "judge"
        if failed_task and not wait_agent and not wait_judge:
            cands = {}
            for d in failed_task:
                kind, why, patch, reverse = got[d["id"]]
                if kind == "unassessable":
                    status[d["id"]] = ("unassessable", why)
                else:
                    cands[d["id"]] = (patch, reverse)
            if cands:
                head_all, _dropped, failed = tree.build(sorted((i, pr[0]) for i, pr in cands.items()))
                for did in failed:
                    status[did] = ("unassessable", "the recreation does not apply to the injected tree")
                    del cands[did]
                accepted = {}
                for d in failed_task:
                    if d["id"] not in cands:
                        continue
                    ans = G.validate(state, work, head_all, d, d["id"] + "-r", counts)
                    if ans is None:
                        wait_judge += 1
                    elif ans == "yes":
                        accepted[d["id"]] = cands[d["id"]]
                    else:
                        status[d["id"]] = ("unassessable", "the judge answered {} on the finished tree".format(ans))
                if not wait_judge:
                    for did, pr in accepted.items():
                        status[did] = ("recreated", "")
                        tree.rec[did] = pr
            if not wait_judge:
                tree.settle("unassessable")
                touched = set(f for _p, _r in tree.rec.values() for f in P.files_of(_p))
                for d in defects:
                    if status[d["id"]][0] != "present":
                        continue
                    g = groups.get(group_of.get(d["id"]))
                    near = set(g["files"] if g else []) | set(d.get("files") or []) | set([C.norm(d.get("file"))])
                    if near & touched:
                        ans = G.validate(state, work, tree.head, d, d["id"] + "-v", counts)
                        if ans is None:
                            wait_judge += 1
                        elif ans != "yes":
                            status[d["id"]] = ("not-present", "the judge answered {} once the recreations were in".format(ans))
                if not wait_judge:
                    tree.settle("unassessable")
    complete = wait_judge == 0 and wait_agent == 0
    head = tree.head
    build_check = s1.get("build_check")
    if complete:
        check_invariant(br, work, final, head, tree.steps())
        if os.path.isfile(os.path.join(work, "Cargo.toml")) and set(g["id"] for g in tree.active()) != set(
                gid for gid, r in s1["groups"].items() if r["status"] == "reverted"):
            checked = cargo_check(a, work, C.repo_name(br["repo"]))
            if checked is not None and not checked[0]:
                build_check = "the final tree: " + checked[1]

    drec = {}
    for d in defects:
        did = d["id"]
        s, why = status[did]
        text = groups[group_of[did]]["patch"] if s == "present" else tree.rec[did][1] if s == "recreated" else None
        if text is not None and complete:
            drec[did] = {"status": s, "reason": why, "group": group_of.get(did, did) if s == "present" else did,
                         "repair": _write_repair(state, did, text), "hunks": tree.located.get(did) or []}
        else:
            stale = os.path.join(state, "repairs", did + ".patch")
            if os.path.exists(stale):
                os.unlink(stale)
            drec[did] = {"status": s, "reason": why, "group": group_of.get(did, did), "repair": None, "hunks": []}
    skipped = sorted(set(notes))
    C.jsave(path, {"work": work, "work_commit": head, "plan_commit": br["plan_commit"], "defects": drec, "complete": complete,
                   "build_check": build_check, "checks_skipped": skipped, "final_commit": final, "injected_commit": first, "stage1": s1})
    tally = dict(collections.Counter(v["status"] for v in drec.values()))
    ok_ids = [d["id"] for d in defects if drec[d["id"]]["status"] in OK]
    lost = [d for d in defects if drec[d["id"]]["status"] not in OK]
    unassessable = [d["id"] for d in task if drec[d["id"]]["status"] == "unassessable"]
    more = {"counts": tally, "unassessable_task": unassessable, "build_check": build_check, "checks_skipped": skipped}
    severe = [d["id"] for d in lost if d.get("severity") in SEVERE]
    if not complete:
        doomed = any(d.get("class") == "pre" and d.get("severity") in SEVERE and drec[d["id"]]["status"] in FAILED for d in defects)
        cause = ("waiting on {} recreation(s) for the coverage gate".format(wait_agent) if wait_agent
                 else "waiting on {} judge answer(s)".format(wait_judge))
        if doomed:
            return done("waiting", "P0/P1 defect(s) not shown present: {}; {}".format(", ".join(severe), cause), doomed=True, **more)
        return done("waiting", cause, **more)
    if build_check and build_check.startswith("the final tree"):
        return done("disqualified", "the injected tree does not build: " + build_check, **more)
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
    ranked = sorted((b for b in candidates if b.get("opened")), key=lambda b: _merged_key(b) + (b["id"],), reverse=True)
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
            entry["checks_skipped"] = o["checks_skipped"]
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
        o = outcome[b["id"]]
        if (o.get("build_check") or "").startswith(("skipped", "timed out")):
            C.say("warning: branch {}: the build check was {}".format(b["id"], o["build_check"]))
        for tool in o.get("checks_skipped") or []:
            C.say("warning: branch {}: a syntax check was skipped: {}".format(b["id"], tool))
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
