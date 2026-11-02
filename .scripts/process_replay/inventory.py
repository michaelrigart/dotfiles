"""cases: the merged October branches that ran the full path, and their two classes of known defect (spec 4.1, 4.2).

A branch is a chain of pre-merge receipts (same repository, branch and destination, by dispatched_at) from
the ledgers, de-duplicated by nonce across ledgers. It is a candidate when its round 1 reviewed the whole
branch, its last round approved, every round tip exists (in the repository or the snapshot), it was merged
inside the window (R3: merge evidence read from the destination's current tip, never assumed) and task
reviews from <state>/reviews.json join it. A review joins the one branch whose own commits (reachable from its
final tip, not from the last full round's base nor from the destination before the merge) contain the commit it
looked at, by ancestry or else by patch id; one that fits several branches joins none. Every git object is read through the private view (common.view),
because a round tip may survive only in the snapshot.

The defects are decided by blind judges, in phases; `cases` is run again after each phase:
  judge-task/<group>-<branch>  one per (task group, branch): the reviews that belong to that branch, one change per fix range
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

from . import common as C
from . import merges
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
MIN_RANGES = 2                         # fix ranges a branch needs: spec 4.1 asks for two per-task defects
OPEN = 16                              # candidates whose judge inputs are written
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
class Repo(C.Reader):
    """common.Reader, with the resolved task groups of this repository."""

    def __init__(self, state, gitdir, root):
        C.Reader.__init__(self, state, gitdir, root)
        self._groups = {}


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
    """Per review of the group: commits (the commit it looked at, full id or None), named (it names a commit,
    resolved or not), ranges ([(base, head)] that resolved), lost (ranges that did not: absent, ambiguous, a
    companion repository's), heads (the ends that say which branch it is about)."""
    if group["id"] not in repo._groups:
        res = {"commits": [], "named": [], "ranges": [], "lost": [], "heads": []}
        for r in group.get("reviews") or []:
            named, lost, heads = [], 0, []
            for pair in r.get("ranges") or []:
                b, h = (repo.commit(x) for x in pair) if isinstance(pair, (list, tuple)) and len(pair) == 2 else (None, None)
                if b and h:
                    named.append((b, h))
                    heads.append(h)
                else:
                    lost += 1
            c = reviewed_commit(repo, r)
            if c and c not in heads:
                heads.append(c)
            res["commits"].append(c)
            res["named"].append(bool(r.get("reviewed_head") or r.get("reviewed_commits")))
            res["ranges"].append(named)
            res["lost"].append(lost)
            res["heads"].append(heads)
        repo._groups[group["id"]] = res
    return repo._groups[group["id"]]


# ------------------------------------------------------------------ a branch's own commits
def copies(scope):
    """{patch id: the branch's own commit}, built when first asked for."""
    if scope["copies"] is None:
        scope["copies"] = scope["repo"].branch_patch_ids(scope["base"], scope["tip"], scope["exclude"])
    return scope["copies"]


def place(scope, c):
    """c itself when it is one of the branch's own commits; else the branch's own copy of it (rewritten by a
    rebase or a cherry-pick: the same patch id); else None."""
    if c in scope["own"]:
        return c
    pid = scope["repo"].patch_id(c)
    return copies(scope).get(pid) if pid else None


def owners(scopes, c):
    """The indices of the branches a commit belongs to: those whose own commits contain it; failing that, those
    that have a copy of it by patch id."""
    direct = [i for i, s in enumerate(scopes) if c in s["own"]]
    if direct or not scopes:
        return set(direct)
    pid = scopes[0]["repo"].patch_id(c)
    return set(i for i, s in enumerate(scopes) if pid and pid in copies(s))


def assign(repo, scopes, groups):
    """Give each review to the one branch whose own commits contain it (by ancestry, else patch id), and set
    scope["joined"] to what each branch got, per group. A review that matches several branches is listed in
    the returned [{group, review, branches}] and belongs to none; a review that names no commit belongs where
    the nearest earlier review of its task with commits does."""
    for s in scopes:
        s["assigned"] = collections.OrderedDict()
    ambiguous = []
    for g in groups:
        res = resolve_group(repo, g)
        before = None
        for i, r in enumerate(g.get("reviews") or []):
            if res["heads"][i]:
                found = set()
                for h in res["heads"][i]:
                    found |= owners(scopes, h)
                before = sorted(found)
            if before is None or not before:
                continue
            if len(before) > 1:
                ambiguous.append({"group": g["id"], "review": i, "branches": [scopes[n]["br"]["id"] for n in before]})
            else:
                scopes[before[0]]["assigned"].setdefault(g["id"], []).append(i)
    return ambiguous


def _gone(group, i, kind, why, rng=None):
    return {"group": group["id"], "review": i, "range": rng and list(rng), "kind": kind, "why": why}


def _own_range(repo, scope, b, h):
    """Every commit of b..h is one of the branch's own, there is at least one, and b is an ancestor of h."""
    inside = repo.commits(b, h)
    return bool(inside) and all(s in scope["own"] for s, _t in inside) and repo.is_ancestor(b, h)


def fix_range(repo, scope, b, h):
    """(b, h) in the branch's own terms when b is an ancestor of h and every commit of b..h is one of its own,
    else None. Only when that fails, a base that was one of the chain's rounds' bases (the branch has since been
    rebased onto another, or main merged into it) stands for the branch's base now."""
    h2 = place(scope, h)
    if h2 is None:
        return None
    b2 = place(scope, b) or b
    if _own_range(repo, scope, b2, h2):
        return (b2, h2)
    if b in scope["bases"] and b != scope["base"] and _own_range(repo, scope, scope["base"], h2):
        return (scope["base"], h2)
    return None


def derive(repo, scope, res, i, r, mine):
    """((base, end), None) for a re-review that names no range, else (None, why). The base is the commit the
    nearest earlier review of the task that belongs to this branch (`mine`, the indices assigned to it) looked at. The end is the commit the re-review itself names when it
    descends from that base; otherwise the last of the branch's own commits committed at or before the
    re-review began. Nothing is guessed past an earlier or own commit that does not resolve."""
    j = next((j for j in range(i - 1, -1, -1) if j in mine and res["named"][j]), None)
    if j is None:
        return None, "no earlier review of the task on this branch names a commit"
    base = res["commits"][j]
    if base is None:
        return None, "the commit an earlier review looked at does not resolve"
    if res["named"][i]:
        c = res["commits"][i]
        if c is None:
            return None, "the commit the re-review names does not resolve"
        cp, bp = place(scope, c), place(scope, base) or base
        if cp and cp != bp and repo.is_ancestor(bp, cp):
            return (base, c), None
    start = _epoch(r.get("start"))
    ends = [row for row in scope["rows"] if start is not None and row[1] <= start]
    if not ends:
        return None, "no commit of the branch was made before the re-review began"
    return (base, max(ends, key=lambda row: row[1])[0]), None


def changes_of(repo, scope, group, res, idxs):
    """([{range, note}], [unjoined]): one change per fix range of the group's re-reviews that belong to this
    branch. A range the prompt names is that range; where it names none, see derive. A range is kept only when
    its commits are the branch's own; one that is not, or that did not resolve, is listed in unjoined."""
    out, index, unjoined = [], {}, []
    reviews = group.get("reviews") or []
    for i in idxs:
        r = reviews[i]
        if r.get("kind") != "re-review":
            continue
        note = "\n".join(m.strip() for m in _NOTE.findall(_text(r.get("prompt"))))
        unjoined += [_gone(group, i, "unresolved", "a named range does not resolve in this repository")] * res["lost"][i]
        pairs = res["ranges"][i]
        if not pairs and not r.get("ranges"):
            pair, why = derive(repo, scope, res, i, r, idxs)
            if pair is None:
                unjoined.append(_gone(group, i, "unresolved", why))
            pairs = [pair] if pair else []
        for b, h in pairs:
            if b == h:
                continue
            rng = fix_range(repo, scope, b, h)
            if rng is None:
                unjoined.append(_gone(group, i, "off-branch", "the range's commits are not all the branch's own", (b, h)))
            elif rng in index:
                have = out[index[rng]]
                have["note"] = "\n".join(have["note"].splitlines() + [x for x in note.splitlines() if x not in have["note"].splitlines()])
            else:
                index[rng] = len(out)
                out.append({"range": rng, "note": note})
    return out, unjoined


# ------------------------------------------------------------------ branches
def examine(a, repo, chain):
    """(Branch record, scope) of one chain. The scope is None when the chain fails before its merge is known;
    otherwise it holds the branch's own commits: reachable from the final tip, not from the last full round's
    base and not from the destination's commit before the merge."""
    first, last = chain[0], chain[-1]
    br = {"id": "b" + _hash(repo.gitdir, _text(last["branch"]), last["dest"], first["nonce"]), "repo": repo.gitdir,
          "objects": C.snapshot_objects(a.snapshot_root, repo.gitdir), "view": repo.view, "dest": last["dest"],
          "dest_ref": last["dest_ref"], "branch": last["branch"], "base": first["base"],
          "rounds": [dict((k, r[k]) for k in ROUND_KEYS) for r in chain], "round1_tip": first["tip"], "final_tip": last["tip"],
          "plan_commit": None, "groups": [], "joined": [], "candidate": False, "opened": False, "why": None, "merged": None,
          "unresolved_ranges": 0, "off_branch_ranges": 0, "skipped_rounds": []}

    def no(why):
        br["why"] = why
        return br, None

    if not isinstance(last["branch"], str) or not last["branch"]:
        return no("no branch name")
    if not first["full"]:
        return no("round 1 is not a full-branch review")
    if last["verdict"] != "approve":
        return no("the last round did not approve")
    tips_, exist = merges.dest_tips(repo, last["dest"])
    if exist and not tips_:
        return no("destination tip not in the snapshot")
    tips = [repo.commit(r["tip"]) for r in chain]
    if not all(tips):
        return no("a round tip is gone")
    base = repo.commit([r for r in chain if r["full"]][-1]["base"])
    if base is None:
        return no("the base commit is gone")
    for r, rec, tip in zip(chain, br["rounds"], tips):
        r["tip"] = rec["tip"] = tip
    br.update(base=base, round1_tip=tips[0], final_tip=tips[-1])
    evidence = merges.merge_evidence(repo, last["dest"], base, tips[-1], tips_)
    if evidence is None:
        return no("no merge evidence")
    br["merged"] = dict((k, evidence[k]) for k in ("how", "commit", "at"))
    exclude = [evidence["before"]] if evidence["before"] else []
    rows = repo.commits(base, tips[-1], exclude)
    scope = {"repo": repo, "br": br, "chain": chain, "base": base, "tip": tips[-1], "exclude": exclude, "rows": rows,
             "own": set(s for s, _t in rows), "copies": None, "bases": set(repo.commit(r["base"]) for r in chain), "assigned": {}, "joined": [],
             "in_window": WINDOW[0] <= _epoch(evidence["at"]) < WINDOW[1]}
    return br, scope


def settle(repo, scope, groups):
    """Build what each branch got from assign(): the changes, and the reasons ranges were left out."""
    by_id = dict((g["id"], g) for g in groups)
    for gid, idxs in scope["assigned"].items():
        g = by_id[gid]
        changes, unjoined = changes_of(repo, scope, g, resolve_group(repo, g), idxs)
        scope["joined"].append({"id": "{}-{}".format(gid, scope["br"]["id"]), "group": g, "idxs": idxs, "changes": changes,
                                "unjoined": unjoined})
    scope["joined"].sort(key=lambda j: (j["group"]["reviews"][j["idxs"][0]].get("start") or "", j["group"]["id"]))


def plan_commit(repo, entries, scope):
    """The tip of the branch's newest approved, clean plan receipt; with none, the last commit touching
    docs/superpowers/plans/ before the first task review joined to this branch began."""
    br, best = scope["br"], None
    for e in entries:
        ts = [t for t in (e.get("targets") or []) if isinstance(t, dict)]
        if not (e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "plan" and e.get("verdict") == "approve"
                and e.get("clean") is True and len(ts) == 1 and isinstance(e.get("dispatched_at"), str)):
            continue
        tip = repo.commit(ts[0].get("tip"))
        if tip and (tip in scope["own"] or (ts[0].get("branch") == br["branch"] and repo.is_ancestor(tip, br["final_tip"]))):
            if best is None or e["dispatched_at"] > best[0]:
                best = (e["dispatched_at"], tip)
    if best:
        return best[1]
    starts = [_epoch(j["group"]["reviews"][i].get("start")) for j in scope["joined"] for i in j["idxs"]]
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
    name = C.norm(name)
    text = repo.file(tip, name) if name else None
    return [] if text is None else [{"path": name, "text": C.cap(text, FILE_CAP)}]


def _digest(doc):
    return hashlib.sha256(json.dumps(doc, sort_keys=True).encode("utf-8")).hexdigest()


def _put(state, kind, jid, doc, counts):
    """Write a judge's input, once. A digest of what was written sits beside it. When a run computes other
    content for an id that exists, the input is rewritten and its answer is set aside (kept, as
    <id>.stale-<digest>.answer.json): an answer is for the content it saw. The input then waits for an answer."""
    path = os.path.join(state, kind, jid + ".json")
    mark = os.path.join(state, kind, jid + ".digest")
    want = _digest(doc)
    if os.path.exists(path):
        try:
            with open(mark) as f:
                have = f.read().strip()
        except OSError:
            have = _digest(C.jload(path))
        if have == want:
            return
        old = os.path.join(state, kind, jid + ".answer.json")
        if os.path.exists(old):
            os.replace(old, os.path.join(state, kind, "{}.stale-{}.answer.json".format(jid, have[:8])))
        counts["stale"] += 1
    C.judge_write(state, kind, jid, doc)
    C.jsave(mark, want + "\n")
    counts[kind] += 1


def _item(cls, key, f, fixes, at):
    return {"key": key, "class": cls, "severity": f["severity"], "summary": f["summary"], "file": f.get("file"), "line": f.get("line"),
            "failure_scenario": f.get("failure_scenario"), "fixes": [list(x) for x in fixes], "at": at}


def _task_items(jid, reports, changes, answer):
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
            items.append(_item("task", "t:{}:{}".format(jid, n), dict(f, summary=summary), [changes[i]["range"] for i in fixed], at))
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


def judge_branch(a, br, scope, counts):
    """Write the judge inputs this branch has reached, read the answers, and return (inventory or None, pending).
    The inventory is None while any judge it needs has not answered. Rounds that could not be judged are put in
    br["skipped_rounds"] and in the inventory's `dropped`."""
    state, repo, chain = a.state, scope["repo"], scope["chain"]
    pending, items, dropped = 0, [], []
    br["skipped_rounds"] = []
    for j in scope["joined"]:
        g = j["group"]
        reports = [g["reviews"][i] for i in j["idxs"] if _text(g["reviews"][i].get("report")).strip()]
        if not reports or not j["changes"]:
            continue
        _put(state, "judge-task", j["id"], {
            "reports": [{"index": i, "text": C.cap(r["report"], REPORT_CAP)} for i, r in enumerate(reports)],
            "changes": [{"index": i, "note": c["note"], "diff": repo.patch(*c["range"])} for i, c in enumerate(j["changes"])]}, counts)
        ans = C.judge_answer(state, "judge-task", j["id"])
        if not isinstance(ans, dict):
            pending += 1
            continue
        got, lost = _task_items(j["id"], reports, j["changes"], ans)
        items += got
        dropped += lost
    for i, r in enumerate(chain[:-1]):
        found = round_findings(r)
        if not found:
            continue
        nxt = chain[i + 1]
        if not repo.is_ancestor(r["tip"], nxt["tip"]):
            why = "round {} not judged: round {}'s tip does not follow it".format(r["k"], nxt["k"])
            br["skipped_rounds"].append({"k": r["k"], "why": why})
            dropped += [{"summary": f["summary"], "why": why} for f in found]
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
        return None, pending
    groups = [[n] for n in range(len(items))]
    if len(items) >= 2:
        _put(state, "judge-dedup", br["id"], {"defects": [dict([(k, it[k]) for k in ("summary", "file", "line", "failure_scenario")], index=n)
                                                         for n, it in enumerate(items)]}, counts)
        ans = C.judge_answer(state, "judge-dedup", br["id"])
        groups = _partition(ans, len(items))
        if groups is None:
            return None, 1
    return {"branch": br["id"], "defects": _defects(repo, br["id"], _merge(items, groups)), "dropped": dropped}, 0


# ------------------------------------------------------------------ the command
def collect(a):
    """[(Repo, ledger entries, chains)] per repository: its ledgers' entries together, a nonce counted once
    (across ledgers too)."""
    seen, repos, entries_of = set(), collections.OrderedDict(), collections.OrderedDict()
    for gitdir, entries in XR.ledgers():
        repos.setdefault(gitdir, Repo(a.state, gitdir, a.snapshot_root))
        fresh = entries_of.setdefault(gitdir, [])
        for e in entries:
            n = e.get("nonce")
            if e.get("kind") == "receipt" and isinstance(n, str):
                if n in seen:
                    continue
                seen.add(n)
            fresh.append(e)
    return [(repos[g], entries_of[g], chains(entries_of[g], g)) for g in repos]


def _record(scope):
    """Put what settle() found into the branch's record."""
    br = scope["br"]
    br["groups"] = [j["group"]["id"] for j in scope["joined"]]
    br["joined"] = [{"id": j["id"], "group": j["group"]["id"], "reviews": j["idxs"], "changes": [list(c["range"]) for c in j["changes"]],
                     "unjoined": j["unjoined"]} for j in scope["joined"]]
    kinds = collections.Counter(u["kind"] for j in scope["joined"] for u in j["unjoined"])
    br["unresolved_ranges"], br["off_branch_ranges"] = kinds["unresolved"], kinds["off-branch"]


def _drop_inventories(state, current):
    """An inventory is only as good as the answers behind it: remove every one whose branch is pending, no
    longer a candidate or not opened."""
    d = os.path.join(state, "inventory")
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if name.endswith(".json") and name[:-5] not in current:
            os.unlink(os.path.join(d, name))


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
    records, contexts, why, ambiguous = [], [], collections.Counter(), []
    for repo, entries, found in collect(a):
        scopes = []
        for chain in found:
            br, scope = examine(a, repo, chain)
            records.append(br)
            if scope is None:
                why[br["why"]] += 1
            else:
                scopes.append(scope)
        ambiguous += assign(repo, scopes, by_repo.get(repo.gitdir, []))
        for scope in scopes:
            br = scope["br"]
            settle(repo, scope, by_repo.get(repo.gitdir, []))
            if not scope["in_window"]:
                br["why"] = "merged outside the window"
            elif not scope["joined"]:
                br["why"] = "no task review joined"
            elif sum(len(j["changes"]) for j in scope["joined"]) < MIN_RANGES:
                br["why"] = "fewer than two task-review fix ranges"
            if br["why"]:
                why[br["why"]] += 1
                continue
            _record(scope)
            br.update(candidate=True, plan_commit=plan_commit(repo, entries, scope))
            contexts.append((br, scope))
    contexts.sort(key=lambda bc: (_epoch(bc[0]["merged"]["at"]), bc[0]["rounds"][-1]["at"]), reverse=True)
    limit = getattr(a, "open", OPEN)
    counts, pending, written, current = collections.Counter(), 0, 0, set()
    for br, scope in contexts[:max(limit, 0)]:
        br["opened"] = True
        inventory, wait = judge_branch(a, br, scope, counts)
        pending += wait
        if inventory is not None:
            written += 1
            current.add(br["id"])
            if not a.dry_run:
                C.jsave(os.path.join(a.state, "inventory", br["id"] + ".json"), inventory)
    if not a.dry_run:
        _drop_inventories(a.state, current)
    multi = collections.Counter(g for br, _ in contexts for g in br["groups"])
    C.say("chains examined: {}; candidates: {} ({} opened); not candidates: {}".format(
        len(records), len(contexts), sum(1 for br, _ in contexts if br["opened"]), ", ".join("{} {}".format(n, w) for w, n in sorted(why.items())) or "none"))
    C.say("judge inputs: " + ", ".join("{} {}".format(k, counts[k]) for k in ("judge-task", "judge-known", "judge-present", "judge-dedup")))
    C.say("inventories written: {}; judge answers pending: {}; stale inputs rewritten: {}".format(written, pending, counts["stale"]))
    C.say("unresolved ranges: {}; ranges not on their branch: {}; reviews matching several branches: {}; groups split across branches: {}".format(
        sum(br["unresolved_ranges"] for br, _ in contexts), sum(br["off_branch_ranges"] for br, _ in contexts), len(ambiguous),
        sum(1 for n in multi.values() if n > 1)))
    for br, _ in contexts:
        for k in br["skipped_rounds"]:
            C.say("  branch {}: {}".format(br["id"], k["why"]))
    if not a.dry_run:
        C.jsave(os.path.join(a.state, "branches.json"), {
            "branches": records, "ambiguous_reviews": ambiguous,
            "unresolved_ranges": sum(br["unresolved_ranges"] for br, _ in contexts),
            "off_branch_ranges": sum(br["off_branch_ranges"] for br, _ in contexts)})
    return 0
