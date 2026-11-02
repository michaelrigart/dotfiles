"""cases: the merged October branches that ran the full path, and their two classes of known defect (spec 4.1, 4.2).

A branch is a chain of pre-merge receipts (same repository, branch and destination, by dispatched_at) from
the ledgers, de-duplicated by nonce across ledgers. It is a candidate when its round 1 reviewed the whole
branch, its last round approved, every round tip exists (in the repository or the snapshot), it was merged
inside the window (R3: merge evidence read from the destination's current tip, never assumed) and task
reviews from <state>/reviews.json join it. Every git object is read through the private view (common.view),
because a round tip may survive only in the snapshot.

The defects are decided by blind judges, in phases; `cases` is run again after each phase:
  judge-task/<group>.json      one per joined task group: its reports, and one change per fix range
  judge-known/<nonce>.json     one per round that has a next round and a P0-P2 finding
  judge-present/<nonce>-<i>    one per known-real finding of a round k >= 2: round 1's text of its file
  judge-dedup/<branch>.json    one per branch, over every known-real defect, once the rest has answered
and, when everything a branch needs has answered, inventory/<branch>.json = {branch, defects, dropped}.
branches.json holds every chain examined, with its reason when it is not a candidate.
"""
import calendar
import collections
import hashlib
import json
import os
import re
import time

from . import common as C
from . import planreview
from .common import Failed

XR, L = C.XR, C.L

WINDOW = (calendar.timegm((2026, 10, 1, 0, 0, 0)), calendar.timegm((2026, 11, 2, 0, 0, 0)))   # merge date, [from, to)
SEVERITIES = XR.KNOWN_SEVERITIES                                  # Codex findings that enter judge-known: P0-P2
RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}
KEYS = ("severity", "file", "line", "summary", "failure_scenario")
ROUND_KEYS = ("k", "nonce", "tip", "base", "thread", "turns", "at", "verdict")
DOCS = "docs/superpowers/"
FILE_CAP, REPORT_CAP = 60000, 60000
OPEN = 16                              # candidates whose judge inputs are written
SKEW = 3 * 86400                       # how far before the final tip's date a merge commit is still looked for
_HEX = re.compile(r"\A[0-9a-fA-F]{4,40}\Z")
_NOTE = re.compile(r"^.*Finding under verification.*$", re.I | re.M)


def add_args(ap):
    ap.add_argument("--plans", action="store_true", help="the plan-review checkpoint (spec 5) instead of the branches")
    ap.add_argument("--open", type=int, default=OPEN, metavar="N",
                    help="write judge inputs for the first N candidates, most recent merge first (default %(default)s); "
                         "a later run with a larger N opens more and leaves existing inputs alone")


# ------------------------------------------------------------------ small helpers
def _epoch(stamp):
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)", stamp if isinstance(stamp, str) else "")
    return calendar.timegm(tuple(int(x) for x in m.groups()) + (0, 0, 0)) if m else None


def _iso(sec):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(sec))


def _cap(text, limit):
    return text if len(text) <= limit else text[:limit] + "\n[truncated]\n"


def _hash(*parts):
    return hashlib.sha1("\0".join(parts).encode("utf-8")).hexdigest()[:8]


def _text(x):
    return x if isinstance(x, str) else ""


# ------------------------------------------------------------------ the rounds
def _pair(x):
    if isinstance(x, dict):
        x = (x.get("thread"), x.get("turn"))
    if isinstance(x, (list, tuple)) and len(x) == 2 and all(isinstance(y, str) and y for y in x):
        return (x[0], x[1])
    return None


def _target(e):
    """The one target of a pre-merge receipt, or None."""
    ts = [t for t in (e.get("targets") or []) if isinstance(t, dict)]
    if (e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "pre-merge"
            and all(isinstance(e.get(k), str) and e[k] for k in ("nonce", "thread", "turn", "dispatched_at"))
            and len(ts) == 1 and all(isinstance(ts[0].get(k), str) and ts[0][k] for k in ("base", "tip", "dest"))):
        return ts[0]
    return None


def _turns(e):
    """[[thread, turn]] of a receipt: its own turn, then every slice's, each once."""
    out = []
    for x in [(e["thread"], e["turn"])] + list(e.get("slice_turns") or []):
        p = _pair(x)
        if p and list(p) not in out:
            out.append(list(p))
    return out


def chains(entries, repo=None):
    """The pre-merge rounds of `entries` as chains, one per (repo, branch, dest) and ascending by
    dispatched_at, each round {k, nonce, tip, base, thread, turn, turns, at, verdict, full, branch, dest,
    dest_ref}. `repo` (the ledger's repository) replaces the target's own repo in the key, which in old
    receipts names a worktree. A nonce counts once."""
    by, seen = collections.OrderedDict(), set()
    for e in entries:
        t = _target(e)
        if t is None or e["nonce"] in seen:
            continue
        seen.add(e["nonce"])
        key = (repo if repo is not None else t.get("repo"), t.get("branch"), t["dest"])
        by.setdefault(key, []).append({
            "nonce": e["nonce"], "tip": t["tip"], "base": t["base"], "thread": e["thread"], "turn": e["turn"],
            "turns": _turns(e), "at": e["dispatched_at"], "verdict": e.get("verdict"), "full": t.get("full") is True,
            "branch": t.get("branch"), "dest": t["dest"], "dest_ref": t.get("dest_ref") or t["dest"]})
    out = []
    for chain in by.values():
        chain.sort(key=lambda r: (r["at"], r["nonce"]))
        for i, r in enumerate(chain):
            r["k"] = i + 1
        out.append(chain)
    return out


def round_findings(rnd):
    """The P0-P2 findings of a round, indexed from 0: the final answers of every turn in rnd["turns"]
    (the receipt's own turn and each slice's, once each), in that order."""
    out, seen = [], set()
    for x in rnd.get("turns") or []:
        p = _pair(x)
        if p is None or p in seen:
            continue
        seen.add(p)
        info = XR.turns_of(p[0]).get(p[1])
        if not info or not info["final"]:
            continue
        try:
            found = [f for f in json.loads(info["final"])["findings"]
                     if isinstance(f, dict) and f.get("severity") in SEVERITIES and isinstance(f.get("summary"), str)]
        except (ValueError, KeyError, TypeError):
            continue
        out += [dict((k, f.get(k)) for k in KEYS) for f in found]
    return [dict(f, index=i) for i, f in enumerate(out)]


# ------------------------------------------------------------------ git, through the view
class Repo(planreview.Reader):
    """The reads of one repository, through the private view (the snapshot's objects when it has any)."""

    def __init__(self, state, gitdir, root):
        planreview.Reader.__init__(self, state, gitdir, root)
        self._commit, self._groups, self._pid = {}, {}, {}

    def commit(self, rev):
        """The full id of the commit that `rev` (hex, any length) names, or None: absent, ambiguous or not hex."""
        if not isinstance(rev, str) or not _HEX.match(rev):
            return None
        key = rev.lower()
        if key not in self._commit:
            try:
                self._commit[key] = C.git(self.view, "rev-parse", "--verify", "--quiet", key + "^{commit}") or None
            except Failed:
                self._commit[key] = None
        return self._commit[key]

    def is_ancestor(self, older, newer):
        return C.git_ok(self.view, "merge-base", "--is-ancestor", older, newer)

    def commits(self, base, tip):
        """[(sha, committer epoch)] of base..tip, newest first."""
        try:
            out = C.git(self.view, "log", "--format=%H %ct", base + ".." + tip)
        except Failed:
            return []
        return [(s, int(t)) for s, t in (line.split() for line in out.splitlines())]

    def names(self, older, newer):
        out = C.git(self.view, "diff", "--name-only", "-z", *(L.DIFF_FLAGS + [older, newer, "--"]), raw=True)
        return [n for n in out.decode("utf-8", "replace").split("\0") if n]

    def patch(self, older, newer):
        out = C.git(self.view, *(L.DIFF_PATCH + ["--text", older, newer, "--"]), raw=True)
        return _cap(out.decode("utf-8", "replace"), XR.MAX_INTERDIFF)

    def _patch_ids(self, *args):
        """[(patch id, commit)] of `git log -p <args>`, by `git patch-id --stable` (a merge or an empty commit has none)."""
        try:
            log = C.git(self.view, "log", "-p", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--format=commit %H",
                        *args, raw=True)
            out = C.git(self.view, "patch-id", "--stable", input=log, raw=True)
        except Failed:
            return []
        return [tuple(line.split()) for line in out.decode("utf-8", "replace").splitlines() if len(line.split()) == 2]

    def patch_id(self, commit):
        """The stable patch id of one commit, or None."""
        if commit not in self._pid:
            found = self._patch_ids("-1", commit)
            self._pid[commit] = found[0][0] if found else None
        return self._pid[commit]

    def branch_patch_ids(self, base, tip):
        """{patch id: commit} of base..tip; the oldest commit when two share one."""
        return dict(self._patch_ids(base + ".." + tip)[::-1])

    def file(self, rev, path):
        """The text of `path` at `rev`, or None."""
        try:
            return C.git(self.view, "cat-file", "blob", "{}:{}".format(rev, path), raw=True).decode("utf-8", "replace")
        except Failed:
            return None


# ------------------------------------------------------------------ merge evidence (R3)
def _first_true(items, pred):
    """The index of the first item for which `pred` holds, when it holds from there on to the last."""
    lo, hi = 0, len(items) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if pred(items[mid]):
            hi = mid
        else:
            lo = mid + 1
    return lo


def _applied(repo, dest_tip, base, final_tip):
    """Every commit of base..final_tip has an equivalent in dest_tip (git cherry marks each `-`)."""
    try:
        lines = C.git(repo.view, "cherry", dest_tip, final_tip, base).splitlines()
    except Failed:
        return False
    return bool(lines) and all(line.startswith("- ") for line in lines)


def _squashed(repo, commit, base, final_tip):
    """Merging the branch into the commit's first parent gives the commit's own tree."""
    p = C.git_run(repo.view, ["merge-tree", "--write-tree", "--merge-base=" + base, commit + "^", final_tip])
    if p.returncode != 0:
        return False
    tree = p.stdout.decode("utf-8", "replace").split("\n", 1)[0].strip()
    try:
        return bool(tree) and tree == C.git(repo.view, "rev-parse", commit + "^{tree}")
    except Failed:
        return False


def _brought_in(repo, dest_tip, base, final_tip):
    try:
        born = int(C.git(repo.view, "log", "-1", "--format=%ct", final_tip))
        rows = C.git(repo.view, "log", "--first-parent", "--format=%H %ct", "--max-age={}".format(born - SKEW), dest_tip)
        old = [(s, int(t)) for s, t in (line.split() for line in rows.splitlines())][::-1]
    except (Failed, ValueError):
        return None
    if not old:
        return None
    found = lambda how, row: {"how": how, "commit": row[0], "at": _iso(row[1])}
    if repo.is_ancestor(final_tip, old[-1][0]):
        return found("ancestry", old[_first_true(old, lambda row: repo.is_ancestor(final_tip, row[0]))])
    if _applied(repo, old[-1][0], base, final_tip):
        return found("rebase", old[_first_true(old, lambda row: _applied(repo, row[0], base, final_tip))])
    for row in old:
        if _squashed(repo, row[0], base, final_tip):
            return found("squash", row)
    return None


def merge_evidence(repo, dest, base, final_tip):
    """{how: ancestry|rebase|squash, commit, at} when the destination's current tip brings the branch in,
    else None. `at` is the committer date of the first-parent commit of that tip that does. The tip is read
    from the original repository's refs (origin's, then the local branch; read only) and then walked
    through the view. A rebase merge is `git cherry` marking every branch commit `-`; a squash merge is a
    first-parent commit equal to its parent plus the branch (`git merge-tree`)."""
    for ref in ("refs/remotes/origin/" + dest, "refs/heads/" + dest):
        try:
            tip = C.git(repo.gitdir, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
        except Failed:
            continue
        if tip and repo.has_commit(tip):
            found = _brought_in(repo, tip, base, final_tip)
            if found:
                return found
    return None


# ------------------------------------------------------------------ task groups
def reviewed_commit(repo, review):
    """The commit a review looked at: its reviewed_head; with none, the newest of reviewed_commits by
    ancestry (None when no one of them descends from all the others, or one cannot be resolved)."""
    if review.get("reviewed_head"):
        return repo.commit(review["reviewed_head"])
    found = []
    for x in review.get("reviewed_commits") or []:
        c = repo.commit(x)
        if c is None:
            return None
        if c not in found:
            found.append(c)
    for c in found:
        if all(o == c or repo.is_ancestor(o, c) for o in found):
            return c
    return None


def resolve_group(repo, group):
    """{commits: [full id or None per review], ranges: [[(base, head)] resolved, per review], heads, unresolved}.
    A range with an end that does not resolve in this repository (absent, ambiguous, a companion
    repository's) is dropped and counted."""
    if group["id"] not in repo._groups:
        res = {"commits": [], "ranges": [], "heads": [], "unresolved": 0}
        for r in group.get("reviews") or []:
            named = []
            for pair in r.get("ranges") or []:
                b, h = (repo.commit(x) for x in pair) if isinstance(pair, (list, tuple)) and len(pair) == 2 else (None, None)
                if b and h:
                    named.append((b, h))
                    res["heads"].append(h)
                else:
                    res["unresolved"] += 1
            c = reviewed_commit(repo, r)
            res["ranges"].append(named)
            res["commits"].append(c)
            if c:
                res["heads"].append(c)
        repo._groups[group["id"]] = res
    return repo._groups[group["id"]]


def changes_of(repo, group, res, rows, place):
    """([{range: (a, b), note}], unresolved): one change per fix range of the group's re-reviews. A range the
    prompt names is that range; where it names none, it is (the commit the review looked at, the last commit
    of the branch committed at or before the re-review began). A range that is named but did not resolve
    is never replaced by a guess. `place(commit, base_side)` gives the branch's own commit for one the branch
    has only as a rewritten copy (same patch id), else None; the range is then the branch's."""
    out, index, unresolved = [], {}, 0
    reviews = group.get("reviews") or []
    for i, r in enumerate(reviews):
        if r.get("kind") != "re-review":
            continue
        note = "\n".join(m.strip() for m in _NOTE.findall(_text(r.get("prompt"))))
        pairs = [(place(b, True) or b, place(h, False) or h) for b, h in res["ranges"][i]]
        if not pairs and not r.get("ranges"):
            start = _epoch(r.get("start"))
            base = next((c for c in reversed(res["commits"][:i + 1]) if c), None)
            base = base and (place(base, True) or base)
            ends = [row for row in rows if start is not None and row[1] <= start]
            end = max(ends, key=lambda row: row[1])[0] if ends else None
            if base and end and base != end and repo.is_ancestor(base, end):
                pairs = [(base, end)]
            else:
                unresolved += 1
        for pair in pairs:
            if pair[0] == pair[1]:
                continue
            if pair in index:
                have = out[index[pair]]
                have["note"] = "\n".join(have["note"].splitlines() + [x for x in note.splitlines() if x not in have["note"].splitlines()])
            else:
                index[pair] = len(out)
                out.append({"range": pair, "note": note})
    return out, unresolved


# ------------------------------------------------------------------ branches
def examine(a, repo, chain, entries, groups):
    """(Branch record, context) of one chain; the context is None unless the branch is a candidate."""
    first, last = chain[0], chain[-1]
    br = {"id": "b" + _hash(repo.gitdir, _text(last["branch"]), last["dest"], first["nonce"]), "repo": repo.gitdir,
          "objects": C.snapshot_objects(a.snapshot_root, repo.gitdir), "view": repo.view, "dest": last["dest"],
          "dest_ref": last["dest_ref"], "branch": last["branch"], "base": first["base"],
          "rounds": [dict((k, r[k]) for k in ROUND_KEYS) for r in chain], "round1_tip": first["tip"], "final_tip": last["tip"],
          "plan_commit": None, "groups": [], "candidate": False, "opened": False, "why": None, "merged": None,
          "unresolved_ranges": 0}

    def no(why):
        br["why"] = why
        return br, None

    if not isinstance(last["branch"], str) or not last["branch"]:
        return no("no branch name")
    if not first["full"]:
        return no("round 1 is not a full-branch review")
    if last["verdict"] != "approve":
        return no("the last round did not approve")
    tips = [repo.commit(r["tip"]) for r in chain]
    if not all(tips):
        return no("a round tip is gone")
    base = repo.commit(first["base"])
    if base is None:
        return no("the base commit is gone")
    for r, rec, tip in zip(chain, br["rounds"], tips):
        r["tip"] = rec["tip"] = tip
    br.update(base=base, round1_tip=tips[0], final_tip=tips[-1])
    evidence = merge_evidence(repo, last["dest"], base, tips[-1])
    if evidence is None:
        return no("no merge evidence")
    br["merged"] = evidence
    if not WINDOW[0] <= _epoch(evidence["at"]) < WINDOW[1]:
        return no("merged outside the window")
    rows = repo.commits(base, tips[-1])
    on_branch = set(s for s, _t in rows)
    copies = []

    def place(c, base_side=False):
        """c itself when the branch has it (a base-side c may also be older than the branch); else the branch's
        copy of it, rewritten by a rebase or a cherry-pick, found by patch id; else None."""
        if c in on_branch or (base_side and repo.is_ancestor(c, base)):
            return c
        if not copies:
            copies.append(repo.branch_patch_ids(base, tips[-1]))
        pid = repo.patch_id(c)
        return copies[0].get(pid) if pid else None

    joined = []
    for g in groups:
        res = resolve_group(repo, g)
        if any(h in on_branch for h in res["heads"]) or any(place(h) for h in res["heads"]):
            changes, lost = changes_of(repo, g, res, rows, place)
            joined.append({"group": g, "res": res, "changes": changes, "unresolved": res["unresolved"] + lost})
    if not joined:
        return no("no task review joined")
    joined.sort(key=lambda j: ((j["group"].get("reviews") or [{}])[0].get("start") or "", j["group"]["id"]))
    br.update(candidate=True, groups=[j["group"]["id"] for j in joined], unresolved_ranges=sum(j["unresolved"] for j in joined))
    br["plan_commit"] = plan_commit(repo, entries, br, on_branch, joined)
    return br, {"repo": repo, "chain": chain, "joined": joined}


def plan_commit(repo, entries, br, on_branch, joined):
    """The tip of the branch's newest approved, clean plan receipt; with none, the last commit touching
    docs/superpowers/plans/ before the first task review began."""
    best = None
    for e in entries:
        ts = [t for t in (e.get("targets") or []) if isinstance(t, dict)]
        if not (e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "plan" and e.get("verdict") == "approve"
                and e.get("clean") is True and len(ts) == 1 and isinstance(e.get("dispatched_at"), str)):
            continue
        tip = repo.commit(ts[0].get("tip"))
        if tip and (tip in on_branch or (ts[0].get("branch") == br["branch"] and repo.is_ancestor(tip, br["final_tip"]))):
            if best is None or e["dispatched_at"] > best[0]:
                best = (e["dispatched_at"], tip)
    if best:
        return best[1]
    starts = [_epoch(j["group"]["reviews"][0].get("start")) for j in joined if j["group"].get("reviews")]
    starts = [s for s in starts if s is not None]
    if not starts:
        return None
    try:
        return C.git(repo.view, "rev-list", "-1", "--min-age={}".format(min(starts)), br["final_tip"], "--", DOCS + "plans/") or None
    except Failed:
        return None


# ------------------------------------------------------------------ judge inputs and the defects they decide
def _files_input(repo, tip, name):
    """[{path, text}] for the file a finding names, as the tip has it (60000 characters; one file, so far under the 150000 in all)."""
    name = planreview._norm(name)
    text = repo.file(tip, name) if name else None
    return [] if text is None else [{"path": name, "text": _cap(text, FILE_CAP)}]


def _put(state, kind, jid, doc, counts):
    """judge_write unless the input is already there: an input a judge has seen is not rewritten."""
    if not os.path.exists(os.path.join(state, kind, jid + ".json")):
        C.judge_write(state, kind, jid, doc)
        counts[kind] += 1


def _item(cls, key, f, fixes, at):
    return {"key": key, "class": cls, "severity": f["severity"], "summary": f["summary"], "file": f.get("file"), "line": f.get("line"),
            "failure_scenario": f.get("failure_scenario"), "fixes": [list(x) for x in fixes], "at": at}


def _task_items(group, reports, changes, answer):
    """(items, dropped) from a judge-task answer."""
    items, dropped = [], []
    for n, f in enumerate(answer.get("findings") or []):
        if not isinstance(f, dict):
            continue
        summary = _text(f.get("summary"))
        fixed = [i for i in f.get("fixed_by") or [] if isinstance(i, int) and not isinstance(i, bool) and 0 <= i < len(changes)]
        if f.get("answer") != "yes":
            dropped.append({"summary": summary, "why": "the judge found the report wrong" if f.get("answer") == "no" else "the judge could not settle it"})
        elif f.get("introduced_by") is not None:
            dropped.append({"summary": summary, "why": "introduced by a fix"})
        elif f.get("severity") not in RANK:
            dropped.append({"summary": summary, "why": "no severity"})
        elif not fixed:
            dropped.append({"summary": summary, "why": "no change fixes it"})
        else:
            r = f.get("report")
            at = reports[r if isinstance(r, int) and not isinstance(r, bool) and 0 <= r < len(reports) else 0].get("start") or ""
            items.append(_item("task", "t:{}:{}".format(group["id"], n), dict(f, summary=summary), [changes[i]["range"] for i in fixed], at))
    return items, dropped


def _partition(answer, n):
    groups = answer.get("groups") if isinstance(answer, dict) else None
    if (isinstance(groups, list) and all(isinstance(g, list) and g and all(isinstance(i, int) and not isinstance(i, bool) for i in g) for g in groups)
            and sorted(i for g in groups for i in g) == list(range(n))):
        return groups
    return None


def _merge(items, groups):
    out = []
    for g in sorted(groups, key=min):
        members = [items[i] for i in sorted(g)]
        top = min(members, key=lambda m: RANK[m["severity"]])
        fixes = []
        for m in members:
            fixes += [x for x in m["fixes"] if x not in fixes]
        out.append(dict(top, key="|".join(sorted(m["key"] for m in members)), fixes=fixes, at=min(m["at"] for m in members),
                        **{"class": "task" if any(m["class"] == "task" for m in members) else "pre"}))
    return out


def _defects(repo, bid, items):
    out = []
    for it in items:
        files = sorted(set(n for a, b in it["fixes"] for n in repo.names(a, b) if not n.startswith(DOCS)))
        out.append({"id": "d" + _hash(bid, it["key"]), "class": it["class"], "severity": it["severity"], "counted": it["severity"] in SEVERITIES,
                    "summary": it["summary"], "file": it["file"], "line": it["line"], "failure_scenario": it["failure_scenario"],
                    "fixes": it["fixes"], "files": files, "at": it["at"]})
    return out


def judge_branch(a, br, ctx, counts):
    """Write the judge inputs this branch has reached, read the answers, and return (inventory or None, pending,
    skipped rounds). The inventory is None while any judge it needs has not answered."""
    state, repo, chain = a.state, ctx["repo"], ctx["chain"]
    pending, items, dropped, skipped = 0, [], [], []
    for j in ctx["joined"]:
        g = j["group"]
        reports = [r for r in g.get("reviews") or [] if _text(r.get("report")).strip()]
        if not reports or not j["changes"]:
            continue
        _put(state, "judge-task", g["id"], {
            "reports": [{"index": i, "text": _cap(r["report"], REPORT_CAP)} for i, r in enumerate(reports)],
            "changes": [{"index": i, "note": c["note"], "diff": repo.patch(*c["range"])} for i, c in enumerate(j["changes"])]}, counts)
        ans = C.judge_answer(state, "judge-task", g["id"])
        if not isinstance(ans, dict):
            pending += 1
            continue
        got, lost = _task_items(g, reports, j["changes"], ans)
        items += got
        dropped += lost
    for i, r in enumerate(chain[:-1]):
        found = round_findings(r)
        if not found:
            continue
        nxt = chain[i + 1]
        if not repo.is_ancestor(r["tip"], nxt["tip"]):
            skipped.append(r["k"])
            continue
        _put(state, "judge-known", r["nonce"], {"case": r["nonce"], "findings": found, "interdiff": repo.patch(r["tip"], nxt["tip"])}, counts)
        ans = C.judge_answer(state, "judge-known", r["nonce"])
        if not isinstance(ans, dict):
            pending += 1
            continue
        yes = set(v.get("index") for v in ans.get("verdicts") or [] if isinstance(v, dict) and v.get("answer") == "yes")
        for f in found:
            if f["index"] not in yes:
                continue
            if r["k"] > 1:
                jid = "{}-{}".format(r["nonce"], f["index"])
                _put(state, "judge-present", jid, {"finding": dict((k, f[k]) for k in KEYS),
                                                  "files": _files_input(repo, chain[0]["tip"], f.get("file"))}, counts)
                present = C.judge_answer(state, "judge-present", jid)
                if not isinstance(present, dict):
                    pending += 1
                    continue
                if present.get("answer") != "yes":
                    dropped.append({"summary": f["summary"], "why": "introduced after round 1" if present.get("answer") == "no"
                                    else "not shown to be there at round 1"})
                    continue
            items.append(_item("pre", "p:{}:{}".format(r["nonce"], f["index"]), f, [(r["tip"], nxt["tip"])], r["at"]))
    if pending:
        return None, pending, skipped
    groups = [[n] for n in range(len(items))]
    if len(items) >= 2:
        _put(state, "judge-dedup", br["id"], {"defects": [dict([(k, it[k]) for k in ("summary", "file", "line", "failure_scenario")], index=n)
                                                         for n, it in enumerate(items)]}, counts)
        ans = C.judge_answer(state, "judge-dedup", br["id"])
        groups = _partition(ans, len(items))
        if groups is None:
            return None, 1, skipped
    return {"branch": br["id"], "defects": _defects(repo, br["id"], _merge(items, groups)), "dropped": dropped}, 0, skipped


# ------------------------------------------------------------------ the command
def collect(a):
    """[(Repo, ledger entries, chains)] of every ledger, a nonce counted once across ledgers."""
    seen, repos, out = set(), {}, []
    for gitdir, entries in XR.ledgers():
        fresh = []
        for e in entries:
            n = e.get("nonce")
            if e.get("kind") == "receipt" and isinstance(n, str):
                if n in seen:
                    continue
                seen.add(n)
            fresh.append(e)
        repo = repos.setdefault(gitdir, Repo(a.state, gitdir, a.snapshot_root))
        out.append((repo, fresh, chains(fresh, gitdir)))
    return out


def cmd_cases(a):
    if getattr(a, "plans", False):
        return planreview.plan_cases(a)
    C.write_briefs(a.state)
    doc = C.jload(os.path.join(a.state, "reviews.json"))
    if not isinstance(doc, dict) or not isinstance(doc.get("groups"), list):
        raise Failed("no reviews.json in {}: run snapshot first".format(a.state))
    by_repo = collections.defaultdict(list)
    for g in doc["groups"]:
        if isinstance(g, dict) and isinstance(g.get("repo"), str):
            by_repo[g["repo"]].append(g)
    records, contexts, why = [], [], collections.Counter()
    for repo, entries, found in collect(a):
        for chain in found:
            br, ctx = examine(a, repo, chain, entries, by_repo.get(repo.gitdir, []))
            records.append(br)
            if ctx is None:
                why[br["why"]] += 1
            else:
                contexts.append((br, ctx))
    contexts.sort(key=lambda bc: (_epoch(bc[0]["merged"]["at"]), bc[0]["rounds"][-1]["at"]), reverse=True)
    limit = getattr(a, "open", OPEN)
    counts, pending, written, skipped = collections.Counter(), 0, 0, {}
    for br, ctx in contexts[:max(limit, 0)]:
        br["opened"] = True
        inventory, wait, skip = judge_branch(a, br, ctx, counts)
        pending += wait
        if skip:
            skipped[br["id"]] = skip
        if inventory is not None:
            written += 1
            if not a.dry_run:
                C.jsave(os.path.join(a.state, "inventory", br["id"] + ".json"), inventory)
    C.say("chains examined: {}; candidates: {} ({} opened); not candidates: {}".format(
        len(records), len(contexts), sum(1 for br, _ in contexts if br["opened"]), ", ".join("{} {}".format(n, w) for w, n in sorted(why.items())) or "none"))
    C.say("judge inputs: " + ", ".join("{} {}".format(k, counts[k]) for k in ("judge-task", "judge-known", "judge-present", "judge-dedup")))
    C.say("inventories written: {}; judge answers pending: {}; unresolved ranges: {}".format(
        written, pending, sum(br["unresolved_ranges"] for br, _ in contexts)))
    for bid, ks in sorted(skipped.items()):
        C.say("  branch {}: rounds {} not judged (the next round's tip does not follow)".format(bid, ks))
    if not a.dry_run:
        C.jsave(os.path.join(a.state, "branches.json"), {
            "branches": records, "unresolved_ranges": sum(br["unresolved_ranges"] for br, _ in contexts),
            "groups": dict((j["group"]["id"], {"changes": [list(c["range"]) for c in j["changes"]], "unresolved": j["unresolved"]})
                           for _br, ctx in contexts for j in ctx["joined"])})
    return 0
