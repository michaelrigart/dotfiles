"""inject: the injected tree of each inventoried branch, its defects' validation, the coverage gate and qualification (spec 4.3, 4.1).

For every opened candidate of branches.json, in order of its merge date (newest first, then final round), up to MAX_CASES in all and
PER_REPO from one repository (a branch that waits on a judge holds its place, one that fails or can no longer qualify gives it up):

  1. fix groups  a fix range that two defects share (counted or not) is split by a blind judge (judge-split/<branch>-<range>); a test
                 hunk goes with the defect it tests. A hunk it cannot place ("unsure") makes those defects one group, reverted and
                 re-applied together. Overlapping ranges are one range. A group with no counted defect is never reverted.
  2. fixpoint    the tree a case ships, and which of the branch's counted (P0-P2) defects it holds, settled as below.
  3. qualifying  two or more assessable per-task defects, every P0/P1 of both classes assessable, and at least one assessable counted
                 pre-merge defect (a case without one has nothing to calibrate against; its slot passes to the next candidate).

The fixpoint. A counted defect is in the tree by its revert (its group reverted), on trial or by its recreation, or out. Each round:

  build    the tree of the active set, from F (the final tip's tree, commit `final_commit` of <state>/work/<branch>): each group with a
           member in by revert, reverted with `git apply -R --index`, latest fix first (topo position, else committer date), tests
           included, and checked (checks.py: syntax and dangling names; a group that does not revert, or fails, is left out); then
           each recreation, those on trial last (one that does not apply is left out); then `cargo check` for a Rust repository (a
           pass is remembered per tree id across runs, a failure or a timeout only within the run, so the next run checks again; on
           failure the newest step is left out: a trial, a recreation, then the latest fix's revert; a timeout is recorded and
           leaves nothing out); then docs/superpowers pinned to the plan commit.
  locate   the steps of the tree (the reverted groups and the recreations) form units, one step each at first. Every unit's repair (its
           steps' repairs, in the order that undoes the build) is applied to that tree on a temporary index (patches.locate), and its
           members share the hunks. A unit whose repair does not apply tries each recreation unit in the tree, those on trial too, the
           last applied first: the first whose steps, with the unit's, apply in that order joins it (a sibling's recreation changed
           the lines its context holds). A join changes no tree and is never undone. A unit no join helps goes to resolve. If
           recreations are on trial and none is in the unit, they are blamed and leave; else the trials in the unit leave; else a unit
           with no group loses its recreations; else each of its groups is tried for a merge with the oldest other group whose repair,
           applied first, lets the unit apply (two fixes too close to revert apart are one group); failing that, the members of its
           groups are out, and its recreations stay (if they no longer apply, they go out for good at the next build).
  judge    judge-present for every member on that tree (or, while recreations are on trial, for those alone), keyed by what the
           judge sees (gate.py; a long file as windows around the located hunks, excerpts.py): a tree state already judged reuses its answer, and no question is ever overwritten. A member
           answered no or unclear is out. A round whose answers are all in and in which no defect leaves is settled. In it, a
           per-task defect that is out gets its one recreation (gate.recreation), made against the round's injected tree: the final
           tree with the settled round's reverted groups reverted and docs/superpowers pinned, no recreation applied (recreation_base).
           When judge-same accepts it, it joins on trial; when judge-present then finds it in the tree, it is in by its recreation. Not
           while its group stays reverted for another member: it waits, and if the tree settles with the group still reverted it is
           unassessable. A recreation that no longer applies once the tree changes under it is out for good.
  Rounds repeat until a round changes nothing. A round stops the fixpoint while any of its judge-present questions is unanswered,
  or, when it would end or take recreations on trial, while a recreation it could take is unfinished (judge-same unanswered, or
  no `done`); the next `inject` replays the same rounds from the answers on disk and goes on from there.

Why it ends. Give each counted defect a stage: 0 in by revert, 1 out awaiting its recreation (per-task only), 2 on trial, 3 in by
recreation, 4 out for good. A defect only ever moves to a higher stage: nothing that is out comes back by revert, and a recreation is
tried once. Groups only ever merge, and units only ever grow. Every round that does not stop or finish moves a defect up a stage or
merges two groups; a join changes no tree and costs no round. So a branch with D counted defects and G groups settles in at most
4*D + G + 1 rounds (exceeding it raises Failed). Its questions are a function of the answers on disk, never overwritten, so every run
replays the same rounds: there is nothing to alternate between.

The shipped tree is the fixpoint's last tree. check_invariant re-applies every repair to it and restores docs/superpowers: the result
must be the final tree. Repairs (repairs/<defect>.patch) and hunks (where each repair applies in the shipped tree) are written only when
the branch is complete: a defect's group is its unit's id (the smallest id of its steps), and its repair and hunks are the unit's.

Known limits: joins are pairwise, as group merges are, so a repair that needs two recreations at once joins neither.
A group stays reverted while any member is in, so a member judged absent (of a split the judge could not make, or of
two fixes too close to revert apart) still has its revert in the shipped tree, inside the group's repair. The invariant holds; a
reviewer who reports it finds a defect that is not in the case's list.

Writes injected/<branch>.json and cases.json, and per kind of item it asks for (judge-split, judge-present, judge-same, recreate) a
manifest <kind>/needed.json, {owned: every id it has asked for, needed: the ids it waits on now}: `pending` leaves out an item inject
asked for and no longer needs (one an earlier inventory, a branch now beyond the limit, or a cargo result since changed led to).
`inject` is run again after each judge phase; it reads what has answered and goes on. It ends by saying what `run` will make of the coverage
gate: passes, fails (run refuses without --despite-coverage-gate), or not settled while a branch waits.
"""
import collections
import os
import shutil
import tempfile

from . import checks as K
from . import common as C
from . import gate as G
from . import inventory as I
from . import patches as P
from . import scratch
from .common import Failed

DOCS = P.DOCS
MAX_CASES = 12                       # spec 4.1: 10-12 cases
PER_REPO = 4                         # at most four from one repository
MIN_TASK = 2                         # assessable per-task defects a branch needs
HUNK_CAP, FILES_CAP = 20000, 150000
OK = ("present", "recreated")
SEVERE = ("P0", "P1")
NO_PRE = "no pre-merge defect to calibrate against"

fix_patch = P.fix_patch
coherent = K.coherent


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


def _group_order(g):
    return (g["pieces"][0]["rank"], g["id"])


def make_plan(a, view, br, defects, counted, counts, questions):
    """(plan, [ids of the judge-split questions still waiting]). `defects` are all the branch's, counted or not; `counted` the ids of
    those whose fix is reverted. A range two of them share is split by a judge, so an uncounted defect's hunks stay applied. plan =
    {groups: [{id, members, pieces: [{range, rank, text}], patch, files}], bad: {defect: reason}}, with no group that has no counted
    member; None while a judge-split has not answered. Every split question is noted in `questions`."""
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

    owners, pending = {}, []
    for key, r in ranges.items():
        ids = sorted(i for i in r.get("ids", []) if i not in bad)
        if len(ids) < 2 or not r["items"] or not any(i in counted for i in ids):
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
        ans = C.accepted_answer(a.state, "judge-split", jid)
        questions.note("judge-split", jid, isinstance(ans, dict))
        if not isinstance(ans, dict):
            pending.append(jid)
            continue
        given = dict((e["index"], e["defect"]) for e in ans["hunks"])        # an accepted answer rules on every hunk
        owner = []
        for n in range(len(hunks)):
            v = given[n]
            owner.append(None if v is None else "*" if v == "unsure" else ids[v])
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
    groups.sort(key=_group_order)
    return {"groups": groups, "bad": bad}, []


def merge_groups(g, h):
    """One group of two: the members, the pieces (latest fix first) and the repair (oldest fix first) of both."""
    members = sorted(set(g["members"]) | set(h["members"]))
    pieces = sorted(g["pieces"] + h["pieces"], key=lambda p: p["rank"])
    patch = "".join(p["text"] for p in reversed(pieces))
    return {"id": members[0], "members": members, "pieces": pieces, "patch": patch, "files": P.files_of(patch)}


# ------------------------------------------------------------------ the work repository
def work_repo(a, br, view, prev):
    """(work, final): <state>/work/<branch>, private to the harness, whose commit `final` holds the final tip's tree. Kept across runs."""
    work = os.path.join(a.state, "work", br["id"])
    tree = C.git(view, "rev-parse", "--verify", br["final_tip"] + "^{tree}")
    final = prev.get("final_commit")
    if (isinstance(final, str) and os.path.isdir(work) and C.git_ok(work, "cat-file", "-e", final + "^{commit}")
            and C.git(work, "rev-parse", final + "^{tree}") == tree):
        return work, final
    if os.path.exists(work):
        shutil.rmtree(work)
    objects = br.get("objects") or os.path.join(br["repo"], "objects")
    tmp = tempfile.mkdtemp(prefix="inject-files.")
    try:
        files = os.path.join(tmp, "files")
        scratch.export(objects, br["final_tip"], files)
        final = scratch.build(objects, br["base"], files, work, br["dest"], br["branch"], br.get("dest_ref"), expect_tree=tree,
                              cache=os.path.join(a.state, "packs"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return work, final


def _clean(work, rev):
    C.git(work, "reset", "-q", "--hard", rev)
    C.git(work, "clean", "-fdxq")


def _commit(work, message):
    stamp = "{} +0000".format(int(C.git(work, "log", "-1", "--format=%ct", "HEAD")) + scratch.HOUR)
    C.git(work, *(scratch.NEUTRAL + ["commit", "-q", "--allow-empty", "--no-verify", "-m", message]),
          env=dict(scratch.IDENTITY, GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp))
    return C.git(work, "rev-parse", "HEAD")


def _apply(work, texts, reverse):
    """Apply each patch of `texts` to the index and work tree (reversed when `reverse`). None, or why one did not apply: the tree is then
    as it was."""
    before = C.git(work, "write-tree")
    for text in texts:
        p = C.git_run(work, scratch.NEUTRAL + ["apply"] + (["-R"] if reverse else []) + ["--index", "--whitespace=nowarn", "-"],
                      input=P.to_bytes(text))
        if p.returncode != 0:
            C.git(work, "read-tree", "--reset", "-u", before)
            return (p.stderr.decode("utf-8", "replace").strip().splitlines() or ["git apply failed"])[0]
    return None


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


# ------------------------------------------------------------------ the fixpoint
REVERT, TRIAL, RECREATED = "revert", "trial", "recreated"


class Fixpoint(object):
    """The injected tree of one branch and where each counted defect stands in it, settled by run() (see the module docstring).

    mode {defect: revert|trial|recreated} holds the defects in the tree; out {defect: (status, reason)} those that are not; tried the
    per-task defects whose one recreation is used; left {defect: (status, reason)} why a defect last left by its revert. A step is
    ("grp", group id) or ("rec", defect); join links the steps of one unit."""

    def __init__(self, a, br, view, work, final, plan, defects, fix_text, counts, cargo_passed, questions):
        self.a, self.br, self.view, self.work, self.final, self.counts, self.questions = a, br, view, work, final, counts, questions
        self.defects = dict((d["id"], d) for d in defects)
        self.fix_text = fix_text
        self.groups = list(plan["groups"])
        self.mode, self.out, self.left, self.rec, self.tried = {}, {}, {}, {}, set()
        self.join = {}
        self.passed, self.failed, self.cargo_checks = set(cargo_passed), {}, []
        self.notes, self.undone, self.rounds = [], 0, 0
        self.env = K.tool_env(a.state)
        self.build_check, self.head, self.located, self.answers, self.waiting = None, None, {}, {}, {}
        for g in self.groups:
            for m in g["members"]:
                if m in self.defects:
                    self.mode[m] = REVERT
        for did, why in plan["bad"].items():
            if did in self.defects:
                self.out[did] = self.left[did] = ("dropped-revert", why)

    # -- where a defect stands
    def task(self, did):
        return self.defects[did].get("class") == "task"

    def gone(self, did):
        """Out for good: no recreation can bring it back."""
        return did in self.out and (not self.task(did) or did in self.tried)

    def leave(self, did, status, why):
        if self.mode.pop(did) == REVERT:
            self.out[did] = self.left[did] = (status, why)
        else:
            del self.rec[did]
            self.out[did] = ("unassessable", why)

    def reverted(self):
        return [g for g in self.groups if any(self.mode.get(m) == REVERT for m in g["members"])]

    def recreations(self):
        """Accepted recreations, then those on trial: the order they are applied in."""
        return sorted(d for d, m in self.mode.items() if m == RECREATED) + sorted(d for d, m in self.mode.items() if m == TRIAL)

    def trials(self):
        return sorted(d for d, m in self.mode.items() if m == TRIAL)

    # -- units: the steps whose repairs must be applied together
    def find(self, step):
        while self.join.get(step, step) != step:
            step = self.join[step]
        return step

    def link(self, one, other):
        self.join[self.find(one)] = self.find(other)

    def step_order(self):
        """[(step, label, repair)] of every step in the tree, in the order that undoes the build: the recreations (last first), then
        the groups, oldest fix first."""
        return ([(("rec", did), did, self.rec[did][1]) for did in reversed(self.recreations())]
                + [(("grp", g["id"]), g["id"], g["patch"]) for g in reversed(self.reverted())])

    def units(self):
        """[[(step, label, repair)]]: the units of the tree, in the order build applied their first step; each in step_order."""
        order = self.step_order()
        roots = list(collections.OrderedDict((self.find(s[0]), None) for s in reversed(order)))
        return [[s for s in order if self.find(s[0]) == r] for r in roots]

    def members(self, unit):
        """The defects in the tree that a unit's steps stand for."""
        groups = dict((g["id"], g) for g in self.groups)
        return [m for kind, ident in (s[0] for s in unit) for m in
                ([x for x in groups[ident]["members"] if self.mode.get(x) == REVERT] if kind == "grp" else [ident])]

    def locate_unit(self, head, unit, cache):
        key = tuple(s[0] for s in unit)
        if key not in cache:
            cache[key] = P.locate(self.work, head, "".join(s[2] for s in unit))
        return cache[key]

    def joined(self, head, unit, cache):
        """True when a recreation unit of the tree lets this unit's repair apply, and the two are one unit now."""
        order = self.step_order()
        position = dict((s[0], n) for n, s in enumerate(order))
        seen = set([self.find(unit[0][0])])
        for did in reversed(self.recreations()):
            root = self.find(("rec", did))
            if root in seen:
                continue
            seen.add(root)
            both = sorted(unit + [s for s in order if self.find(s[0]) == root], key=lambda s: position[s[0]])
            if self.locate_unit(head, both, cache)[0] is not None:
                self.link(unit[0][0], ("rec", did))
                return True
        return False

    # -- one round
    def build(self):
        """(head, {}) of the tree of the defects in, or (None, {defect: (status, why)}) of those that must leave first."""
        work, failed, applied = self.work, {}, []
        _clean(work, self.final)
        for g in self.reverted():
            before = C.git(work, "write-tree")
            why = _apply(work, [p["text"] for p in g["pieces"]], reverse=True)
            if why:
                bad = ("dropped-revert", "its fix does not revert: " + why)
            else:
                good, why = K.coherent(work, g["files"], self.env, self.notes)
                if good:
                    good, why = K.dangling(work, g["patch"], g["files"])
                bad = None if good else ("incoherent", why)
                if bad:
                    C.git(work, "read-tree", "--reset", "-u", before)
            if bad:
                failed.update((m, bad) for m in g["members"] if self.mode.get(m) == REVERT)
            else:
                applied.append(g)
        for did in self.recreations():
            before = C.git(work, "write-tree")
            if _apply(work, [self.rec[did][0]], reverse=False):
                failed[did] = ("unassessable", "the recreation does not apply to the injected tree")
                continue
            good, why = K.coherent(work, P.files_of(self.rec[did][0]), self.env, self.notes)       # a hand edit is checked as a revert is
            if not good:
                C.git(work, "read-tree", "--reset", "-u", before)
                failed[did] = ("unassessable", "the recreation breaks " + why)
        if failed:
            return None, failed
        verdict = self.check_build()
        if verdict is not None and verdict[0] is False:
            newest = [[d] for d in reversed(self.recreations())] + [[m for m in g["members"] if self.mode.get(m) == REVERT] for g in applied]
            if newest:
                self.undone += 1
                return None, dict((m, ("incoherent", verdict[1])) for m in newest[0])
        pin_docs(work, self.view, self.br["plan_commit"])
        return _commit(work, scratch.MESSAGE), {}

    def check_build(self):
        """[passed (True, False, or None for a timeout), why] of `cargo check` on the work tree; None when there is no Cargo.toml or no
        cargo. A pass is remembered per tree id across runs; a failure or a timeout only within this run, since it may come from the
        environment (a crate not fetched for --offline, a cold target directory): the next run checks again. Each check made is
        recorded in cargo_checks. Sets build_check."""
        self.build_check = None
        if not os.path.isfile(os.path.join(self.work, "Cargo.toml")):
            return None
        tree = C.git(self.work, "write-tree")
        if tree in self.passed:
            verdict = [True, ""]
        elif tree in self.failed:
            verdict = self.failed[tree]
        else:
            got = K.cargo_check(self.a, self.work, C.repo_name(self.br["repo"]))
            if got is None:
                self.build_check = "skipped: cargo not found"
                return None
            verdict = [got[0], "" if got[0] else got[1]]
            self.cargo_checks.append({"tree": tree, "passed": verdict[0], "why": verdict[1]})
            if verdict[0]:
                self.passed.add(tree)
            else:
                self.failed[tree] = verdict
        passed, why = verdict
        if passed:
            self.build_check = "passed" if not self.undone else "passed after undoing {} step(s)".format(self.undone)
        elif passed is None:
            self.build_check = "timed out: " + why
        else:
            self.build_check = "failed with every revert undone: " + why
        return verdict

    def locate(self, head):
        """({defect: hunks}, None) when every unit's repair applies to the tree at head, else (_, (unit, why)): the first that does not
        and that no join helps. A join starts the pass again with the bigger unit."""
        cache = {}
        while True:
            located = {}
            for unit in self.units():
                hunks, why = self.locate_unit(head, unit, cache)
                if hunks is None:
                    if self.joined(head, unit, cache):
                        break
                    return located, (unit, why)
                located.update((m, hunks) for m in self.members(unit))
            else:
                return located, None

    def resolve(self, head, unit, why):
        """The repair of `unit` does not apply to the tree at head, and no recreation joins it. If recreations are on trial and none is
        in the unit, the trials broke it: they leave. Else the trials in it leave; failing that, its groups are merged with the oldest
        other reverted group whose repair, applied before it, lets the unit apply (two fixes too close to revert apart); failing that,
        the members of its groups leave, or, with no group in it, its recreations."""
        why = "its repair does not apply to the injected tree: " + why
        trials, recs = self.trials(), [s[0][1] for s in unit if s[0][0] == "rec"]
        if trials and not set(trials) & set(recs):
            for did in trials:
                self.leave(did, "unassessable", "on trial, it stopped the repair of another defect from applying")
            return
        mine = [did for did in recs if did in trials]
        if mine:
            for did in mine:
                self.leave(did, "unassessable", why)
            return
        by_id = dict((g["id"], g) for g in self.groups)
        mine = [by_id[s[0][1]] for s in unit if s[0][0] == "grp"]
        if not mine:
            for did in recs:
                self.leave(did, "unassessable", why)
            return
        inside = set(("grp", g["id"]) for g in mine)
        for step in mine:
            for h in sorted((x for x in self.reverted() if ("grp", x["id"]) not in inside), key=lambda x: -x["pieces"][0]["rank"]):
                both = merge_groups(step, h)
                if self.merge_applies(head, unit, step, h, both):
                    self.groups = sorted([x for x in self.groups if x is not step and x is not h] + [both], key=_group_order)
                    for old in (step, h):
                        self.link(("grp", old["id"]), ("grp", both["id"]))
                    self.link(unit[0][0], ("grp", both["id"]))
                    return
        for step in mine:
            for m in step["members"]:
                if self.mode.get(m) == REVERT:
                    self.leave(m, "dropped-revert", why)

    def merge_applies(self, head, unit, step, other, both):
        """Does the repair of `unit` and of the unit `other` stands in, with the groups `step` and `other` merged into `both`, apply to the
        tree at head."""
        root = self.find(("grp", other["id"]))
        together = unit + [s for s in self.step_order() if self.find(s[0]) == root]
        by_id = dict((g["id"], g) for g in self.groups)
        groups = [by_id[s[0][1]] for s in together if s[0][0] == "grp" and s[0][1] not in (step["id"], other["id"])] + [both]
        recs = [s for s in self.step_order() if s[0][0] == "rec" and s in together]
        text = "".join(s[2] for s in recs) + "".join(g["patch"] for g in sorted(groups, key=_group_order, reverse=True))
        return P.locate(self.work, head, text)[0] is not None

    def judge(self, head, ids, located):
        """({defect: answer}, [ids of the questions still waiting]) of judge-present on the tree at head, where the repairs of `located`
        ({defect: hunks}, from locate) lie: they are what the judge's windows are cut around."""
        answers, waiting = {}, []
        for did in ids:
            jid, ans = G.validate(self.a.state, self.work, head, self.defects[did], located.get(did, []), self.counts)
            self.questions.note("judge-present", jid, ans is not None)
            if ans is None:
                waiting.append(jid)
            else:
                answers[did] = ans
        return answers, waiting

    def held(self, did):
        """A defect that is out while its group stays reverted for another member."""
        g = self.group_of(did)
        return g is not None and any(self.mode.get(m) == REVERT for m in g["members"])

    def recreation_base(self):
        """The commit a recreation is made against: the final tree with the groups of reverted() reverted, as build reverted them (they
        passed this round's checks), and docs/superpowers pinned, with no recreation applied. The work tree is left at the round's head."""
        _clean(self.work, self.final)
        for g in self.reverted():
            why = _apply(self.work, [p["text"] for p in g["pieces"]], reverse=True)
            if why:
                raise Failed("branch {}: the revert of {} no longer applies: {}".format(self.br["id"], g["id"], why))
        pin_docs(self.work, self.view, self.br["plan_commit"])
        base = _commit(self.work, scratch.MESSAGE)
        _clean(self.work, self.head)
        return base

    def second_attempts(self):
        """Every per-task defect that is out, has not had its recreation and is not held: requested (once), then out for good, a
        candidate, or waiting. The recreations are made against the round's injected tree (recreation_base), built when the first is
        due. ({defect: (patch, reverse)} of the candidates, {kind: [what waits]})."""
        cands, waiting, base = {}, {"recreate": [], "judge-same": []}, None
        for did in sorted(self.out):
            if not self.task(did) or did in self.tried or self.held(did):
                continue
            if base is None:
                base = self.recreation_base()
            got = G.recreation(self.a, self.work, base, self.defects[did], self.fix_text[did], self.counts)
            self.questions.note("recreate", got["rid"], got["kind"] != "agent")
            if got["same"]:
                self.questions.note("judge-same", got["same"], got["kind"] != "judge")
            if got["kind"] == "agent":
                waiting["recreate"].append(got["wait"])
            elif got["kind"] == "judge":
                waiting["judge-same"].append(got["wait"])
            elif got["kind"] == "unassessable":
                self.tried.add(did)
                self.out[did] = ("unassessable", got["why"])
            else:
                cands[did] = (got["patch"], got["reverse"])
        return cands, waiting

    def run(self):
        """Settle. True when the fixpoint is reached, False when it waits (self.waiting says on what)."""
        bound = 4 * len(self.defects) + len(self.groups) + 1
        while self.rounds < bound:
            self.rounds += 1
            head, failed = self.build()
            if failed:
                for did, (status, why) in sorted(failed.items()):
                    self.leave(did, status, why)
                continue
            located, broken = self.locate(head)
            if broken:
                self.resolve(head, *broken)
                continue
            trials = self.trials()
            answers, waiting = self.judge(head, trials or sorted(self.mode), located)
            self.head, self.located = head, located
            if trials:
                if waiting:
                    return self.wait({"judge-present": waiting})
                for did in trials:
                    if answers[did] == "yes":
                        self.mode[did] = RECREATED
                    else:
                        self.leave(did, "unassessable", "the judge answered {} on the injected tree".format(answers[did]))
                continue
            self.answers = answers
            if waiting:
                return self.wait({"judge-present": waiting})
            gone = [d for d in sorted(answers) if answers[d] != "yes"]
            for did in gone:
                self.leave(did, "not-present" if self.mode[did] == REVERT else "unassessable", "the judge answered {}".format(answers[did]))
            if gone:
                continue
            cands, more = self.second_attempts()
            if more["recreate"] or more["judge-same"]:
                return self.wait(more)
            if not cands:
                for did in [d for d in sorted(self.out) if self.task(d) and d not in self.tried and self.held(d)]:
                    self.tried.add(did)
                    self.out[did] = ("unassessable", "its group's revert stays in the tree for another member")
                return True
            for did, pair in sorted(cands.items()):
                self.tried.add(did)
                del self.out[did]
                self.mode[did], self.rec[did] = TRIAL, pair
        raise Failed("branch {}: the injected tree did not settle within {} rounds".format(self.br["id"], bound))

    def wait(self, what):
        self.waiting = dict((k, v) for k, v in sorted(what.items()) if v)
        return False

    # -- what it settled on
    def group_of(self, did):
        for g in self.groups:
            if did in g["members"]:
                return g
        return None

    def status(self, did, complete):
        mode = self.mode.get(did)
        if mode == REVERT:
            return ("present" if complete or self.answers.get(did) == "yes" else "reverted"), ""
        if mode == RECREATED:
            return "recreated", ""
        if mode == TRIAL:
            return self.left.get(did, ("dropped-revert", ""))
        return self.out[did]

    def repair(self, did):
        """(unit id, unit repair patch) of a defect in the tree, else (group, None). A unit's id is the smallest id of its steps and its
        repair is theirs, in steps() order."""
        mode, g = self.mode.get(did), self.group_of(did)
        if mode not in (REVERT, RECREATED):
            return (g["id"] if g else did), None
        step = ("grp", g["id"]) if mode == REVERT else ("rec", did)
        unit = [u for u in self.units() if step in [s[0] for s in u]][0]
        return min(s[1] for s in unit), "".join(s[2] for s in unit)

    def steps(self):
        """The repairs in the order that undoes the build: the recreations (last first), then the groups, oldest fix first."""
        return [(label, repair) for _step, label, repair in self.step_order()]


# ------------------------------------------------------------------ one branch
class Questions(object):
    """The judge questions and recreations of one `inject` run, by kind: those it asked for and those it waits on. save() writes
    <kind>/needed.json, {owned: every id inject has asked for in this run or an earlier one, needed: the ids this run waits on}, which
    `common.pending` reads: an item inject owns and no longer needs is not handed out."""
    KINDS = ("judge-split", "judge-present", "judge-same", "recreate")

    def __init__(self):
        self.asked, self.needed = collections.defaultdict(set), collections.defaultdict(set)

    def note(self, kind, jid, answered):
        self.asked[kind].add(jid)
        if not answered:
            self.needed[kind].add(jid)

    def save(self, state):
        for kind in self.KINDS:
            path = os.path.join(state, kind, C.NEEDED)
            prev = C.jload(path)
            owned = set((prev or {}).get("owned") or []) | self.asked[kind]
            if owned:
                C.jsave(path, {"owned": sorted(owned), "needed": sorted(self.needed[kind])})


def _write_repair(state, did, text):
    path = os.path.join(state, "repairs", did + ".patch")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(P.to_bytes(text))
    return path


def _waiting_on(waiting):
    judges = len(waiting.get("judge-present") or []) + len(waiting.get("judge-same") or [])
    parts = (["{} judge answer(s)".format(judges)] if judges else []) + (
        ["{} recreation(s) for the coverage gate".format(len(waiting["recreate"]))] if waiting.get("recreate") else [])
    return "waiting on " + " and ".join(parts)


def process(a, br, counts, questions):
    """The outcome of one branch: {state: waiting|qualified|disqualified, why, counts, case_defects, unassessable_task, ...}. The judge
    questions it asks are noted in `questions`."""
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
    if not any(d.get("class") != "task" for d in defects):
        return done("disqualified", NO_PRE)
    if not br.get("plan_commit"):
        return done("disqualified", "no plan commit to pin docs/superpowers to")
    view = C.view(state, br["repo"], a.snapshot_root)
    if not C.git_ok(view, "cat-file", "-e", br["plan_commit"] + "^{commit}"):
        return done("disqualified", "the plan commit is gone")
    plan, wait = make_plan(a, view, br, everything, counted, counts, questions)
    if plan is None:
        return done("waiting", "waiting on {} fix-split judge(s)".format(len(wait)))
    if a.dry_run:
        return done("waiting", "waiting: dry run")
    path = os.path.join(state, "injected", br["id"] + ".json")
    prev = C.jload(path) or {}
    work, final = work_repo(a, br, view, prev)
    planned = dict((m, g) for g in plan["groups"] for m in g["members"])
    fix_text = {}
    for d in defects:
        try:
            fix_text[d["id"]] = planned[d["id"]]["patch"] if d["id"] in planned else "".join(P.fix_patch(view, r[0], r[1]) for r in d.get("fixes") or [])
        except Failed:
            fix_text[d["id"]] = ""
    fx = Fixpoint(a, br, view, work, final, plan, defects, fix_text, counts, prev.get("cargo_passed") or [], questions)
    complete = fx.run()
    if complete:
        check_invariant(br, work, final, fx.head, fx.steps())

    drec = {}
    for d in defects:
        did = d["id"]
        status, why = fx.status(did, complete)
        group, text = fx.repair(did)
        if complete and text is not None:
            drec[did] = {"status": status, "reason": why, "group": group, "repair": _write_repair(state, did, text), "hunks": fx.located[did]}
        else:
            stale = os.path.join(state, "repairs", did + ".patch")
            if os.path.exists(stale):
                os.unlink(stale)
            drec[did] = {"status": status, "reason": why, "group": group, "repair": None, "hunks": []}
    skipped = sorted(set(fx.notes))
    C.jsave(path, {"work": work, "work_commit": fx.head, "plan_commit": br["plan_commit"], "defects": drec, "complete": complete,
                   "waiting": fx.waiting if not complete else {}, "rounds": fx.rounds, "build_check": fx.build_check, "checks_skipped": skipped,
                   "final_commit": final, "cargo_passed": sorted(fx.passed), "cargo_checks": fx.cargo_checks})
    tally = dict(collections.Counter(v["status"] for v in drec.values()))
    ok_ids = [d["id"] for d in defects if drec[d["id"]]["status"] in OK]
    unassessable = [d["id"] for d in task if drec[d["id"]]["status"] == "unassessable"]
    more = {"counts": tally, "unassessable_task": unassessable, "build_check": fx.build_check, "checks_skipped": skipped}
    severe = [d["id"] for d in defects if d.get("severity") in SEVERE and (fx.gone(d["id"]) if not complete else drec[d["id"]]["status"] not in OK)]
    if not complete:
        cause = _waiting_on(fx.waiting)
        if severe:
            return done("waiting", "P0/P1 defect(s) not shown present: {}; {}".format(", ".join(severe), cause), doomed=True, **more)
        if sum(1 for d in task if not fx.gone(d["id"])) < MIN_TASK:
            return done("waiting", "fewer than two assessable per-task defects; " + cause, doomed=True, **more)
        return done("waiting", cause, **more)
    if severe:
        return done("disqualified", "P0/P1 defect(s) not shown present: " + ", ".join(severe), **more)
    if sum(1 for d in task if drec[d["id"]]["status"] in OK) < MIN_TASK:
        return done("disqualified", "fewer than two assessable per-task defects", **more)
    if not any(drec[d["id"]]["status"] in OK for d in defects if d.get("class") != "task"):
        return done("disqualified", NO_PRE, **more)
    return done("qualified", None, case_defects=ok_ids, work_commit=fx.head, **more)


# ------------------------------------------------------------------ the command
def _final_at(b):
    rounds = b.get("rounds") or [{}]
    return (rounds[-1].get("at") or "", b["id"])


def _merged_key(b):
    return (I._epoch((b.get("merged") or {}).get("at")) or 0, _final_at(b)[0])


@C.locked("exclusive")
def cmd_inject(a):
    doc = C.jload(os.path.join(a.state, "branches.json"))
    if not isinstance(doc, dict) or not isinstance(doc.get("branches"), list):
        raise Failed("no branches.json in {}: run cases first".format(a.state))
    C.write_briefs(a.state)
    records = [b for b in doc["branches"] if isinstance(b, dict) and isinstance(b.get("id"), str)]
    candidates = [b for b in records if b.get("candidate")]
    ranked = sorted((b for b in candidates if b.get("opened")), key=lambda b: _merged_key(b) + (b["id"],), reverse=True)
    counts, questions = collections.Counter(), Questions()
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
            try:
                outcome[br["id"]] = process(a, br, counts, questions)
            except Failed as e:       # one branch that cannot be built gives up its place; the others go on
                outcome[br["id"]] = {"state": "disqualified", "why": "error {}".format(e), "counts": {}, "case_defects": [], "unassessable_task": []}
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
        questions.save(a.state)
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
    C.say(coverage_line(unassessable, states["waiting"]))
    if states["waiting"]:
        C.say("answers wait: run `process-replay.py pending`, then `process-replay.py inject` again")
    if hint:
        C.say("fewer than {} branches qualify or wait, and candidates remain: open more with `process-replay.py cases --open {}`".format(MAX_CASES, hint))
    return 0


def coverage_line(unassessable, waiting):
    """What `run` will make of the coverage gate (spec 14.5): a defect already unassessable fails it whatever else waits; with none, a waiting
    branch leaves it unsettled."""
    held = len(set(unassessable))
    if held:
        return "coverage gate: fails: {} per-task defect(s) unassessable; run refuses without --despite-coverage-gate".format(held)
    if waiting:
        return "coverage gate: not settled (answers wait)"
    return "coverage gate: passes"


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
