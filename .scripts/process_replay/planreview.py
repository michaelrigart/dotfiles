"""The plan-review checkpoint: what its findings were (spec 5).

`cases --plans` calls plan_cases: it finds October's plan-checkpoint rounds, writes the blind judge
inputs that decide which P0-P2 findings were real (judge-known: did the next plan round's diff fix it)
and what kind each real one was (judge-class), and records the rounds, their cost and the lost
omit_plans saving in <state>/plan-cases.json. `report` calls report_section for the checkpoint's part
of the report.

A round is a plan-checkpoint receipt. Its plans are the keys of its target's plan_blobs (derived from
git for old receipts). Its next round is the next one on the same thread that lists one of its plans
with another blob, so a thread that carries two plans on a null branch matches each plan to its own.
"""
import calendar
import collections
import json
import os
import re

from . import common as C
from .common import Failed

XR, L, XP = C.XR, C.L, C.XP

WINDOW = ("2026-10-01", "2026-11-01")          # dispatched_at, [from, to)
SEVERITIES = XR.KNOWN_SEVERITIES               # P0-P2 are counted, P3 is not
CLASSES = ("diff-visible", "design", "plan-only")
CONTEXT = 40                                   # lines either side of a finding's line
EXCERPT_CAP = 60000
PLAN_DIR = "docs/superpowers/plans/"
CASES = "plan-cases.json"
FAR = "9999-12-31T23:59:59.999999Z"


# ------------------------------------------------------------------ small helpers
def _in_window(at):
    return isinstance(at, str) and WINDOW[0] <= at < WINDOW[1]


def _cap(text, limit):
    return text if len(text) <= limit else text[:limit] + "\n[truncated]\n"


def _epoch(stamp):
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?", stamp if isinstance(stamp, str) else "")
    if not m:
        return None
    parts = [int(x) for x in m.groups()[:6]]
    return calendar.timegm(tuple(parts) + (0, 0, 0)) + (float(m.group(7)) if m.group(7) else 0.0)


def wall_minutes(thread, turn):
    """Minutes from the first to the last record of one turn, 0 when the rollout has no timestamps."""
    start = end = None
    inside = False
    for rec in XR.rollout_records(thread):
        p = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
        kind, ptype = rec.get("type"), p.get("type")
        if kind == "event_msg" and ptype == "task_started":
            if inside:
                break
            inside = p.get("turn_id") == turn
        if not inside:
            continue
        at = _epoch(rec.get("timestamp"))
        if at is not None:
            start = at if start is None else start
            end = at
        if kind == "event_msg" and ptype == "task_complete" and p.get("turn_id") == turn:
            break
    return (end - start) / 60.0 if start is not None and end is not None else 0.0


def _findings(thread, turn):
    """The round's P0-P2 findings, indexed from 0 (the answer's findings that parse)."""
    info = XR.turns_of(thread).get(turn)
    if not info or not info["final"]:
        return []
    try:
        found = [f for f in json.loads(info["final"])["findings"]
                 if isinstance(f, dict) and f.get("severity") in SEVERITIES and isinstance(f.get("summary"), str)]
    except (ValueError, KeyError, TypeError):
        return []
    keys = ("severity", "file", "line", "summary", "failure_scenario")
    return [dict(index=i, **dict((k, f.get(k)) for k in keys)) for i, f in enumerate(found)]


def _plan_target(e):
    ts = [t for t in (e.get("targets") or []) if isinstance(t, dict)]
    if (e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "plan"
            and all(isinstance(e.get(k), str) and e[k] for k in ("nonce", "thread", "turn", "dispatched_at"))
            and len(ts) == 1 and all(isinstance(ts[0].get(k), str) and ts[0][k] for k in ("repo", "base", "tip"))):
        return ts[0]
    return None


def _plan_blobs(e, target):
    """{plan path: blob} of a round: as recorded, else derived from git as enriched() does for old receipts."""
    blobs = target.get("plan_blobs")
    if not isinstance(blobs, dict):
        done = XR.enriched([e], FAR, e["thread"])
        blobs = done[0]["targets"][0].get("plan_blobs") if done and done[0].get("targets") else None
    return dict((p, b) for p, b in (blobs or {}).items() if isinstance(p, str) and isinstance(b, str))


def _norm(path):
    path = path if isinstance(path, str) else ""
    while path.startswith("./"):
        path = path[2:]
    if path[:2] in ("a/", "b/"):
        path = path[2:]
    return path


def _plan_of(finding, plans):
    """The plan a finding names (its file, any ./ or a/ b/ prefix aside), or None."""
    name = _norm(finding.get("file"))
    if not name:
        return None
    for path in sorted(plans):
        if name == path or path.endswith("/" + name) or name.endswith("/" + path):
            return path
    return None


# ------------------------------------------------------------------ reading git through the view
class Reader(object):
    """The reads of one repository, through the private view (the snapshot's objects when it has any)."""

    def __init__(self, state, gitdir, root):
        self.state, self.gitdir, self.root = state, gitdir, root
        self._view = None
        self._diffs = {}

    @property
    def view(self):
        if self._view is None:
            self._view = C.view(self.state, self.gitdir, self.root)
        return self._view

    def has_commit(self, rev):
        return C.git_ok(self.view, "cat-file", "-e", rev + "^{commit}")

    def text(self, blob):
        try:
            return C.git(self.view, "cat-file", "blob", blob, raw=True).decode("utf-8", "replace")
        except Failed:
            return None

    def size(self, blob):
        try:
            return int(C.git(self.view, "cat-file", "-s", blob))
        except (Failed, ValueError):
            return None

    def interdiff(self, tip, next_tip, keep):
        """The change from tip to next tip, with every plan but those in `keep` left out (another
        plan's edits between the two tips are not this round's fix). None when it cannot be read."""
        key = (tip, next_tip, tuple(sorted(keep)))
        if key not in self._diffs:
            self._diffs[key] = self._interdiff(tip, next_tip, keep)
        return self._diffs[key]

    def _interdiff(self, tip, next_tip, keep):
        if not (self.has_commit(tip) and self.has_commit(next_tip)) or not C.git_ok(self.view, "merge-base", "--is-ancestor", tip, next_tip):
            return None
        try:
            names = C.git(self.view, "diff", "--name-only", "-z", *(L.DIFF_FLAGS + [tip, next_tip, "--"]), raw=True)
            skip = [n for n in names.decode("utf-8", "replace").split("\0") if n.startswith(PLAN_DIR) and n not in keep]
            out = C.git(self.view, *(L.DIFF_PATCH + ["--text", tip, next_tip, "--", ":(top)"]
                                     + [":(top,exclude,literal)" + n for n in skip]), raw=True)
        except Failed:
            return None
        return _cap(out.decode("utf-8", "replace"), XR.MAX_INTERDIFF)


# ------------------------------------------------------------------ the rounds
def collect(state, root, dry=False):
    """(rounds, saving, skipped) from the ledgers: the October plan-checkpoint rounds, each linked to its
    next round, the October pre-merge receipts' plans_from sizes, and the count of rounds left out because
    their commits cannot be read."""
    rounds, readers = [], {}
    saving = {"bytes": 0, "receipts": 0, "with_plans": 0, "unresolved": 0}
    for gitdir, entries in XR.ledgers():
        reader = readers.setdefault(gitdir, Reader(state, gitdir, root))
        chains = collections.defaultdict(list)
        for e in entries:
            at = e.get("dispatched_at")
            if e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "plan":
                target = _plan_target(e)
                if target is None:
                    continue
                chains[e["thread"]].append({
                    "nonce": e["nonce"], "at": at, "gitdir": gitdir, "reader": reader, "repo": C.repo_name(gitdir),
                    "thread": e["thread"], "turn": e["turn"], "verdict": e.get("verdict"), "base": target["base"],
                    "tip": target["tip"], "plans": _plan_blobs(e, target), "counted": _in_window(at), "next": None})
            elif e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "pre-merge" and _in_window(at):
                saving["receipts"] += 1
                listed = [p for t in e.get("targets") or [] if isinstance(t, dict) for p in t.get("plans_from") or []
                          if isinstance(p, dict)]
                saving["with_plans"] += 1 if listed else 0
                for p in listed:
                    size = reader.size(p["blob"]) if isinstance(p.get("blob"), str) and p["blob"] else None
                    if size is None:
                        saving["unresolved"] += 1
                    else:
                        saving["bytes"] += size
        for chain in chains.values():
            chain.sort(key=lambda r: r["at"])
            for i, r in enumerate(chain):
                for later in chain[i + 1:]:
                    changed = sorted(p for p, b in r["plans"].items() if p in later["plans"] and later["plans"][p] != b)
                    if changed:
                        r["next"], r["changed"] = later, changed
                        break
            rounds += [r for r in chain if r["counted"]]
    rounds.sort(key=lambda r: r["at"])
    for r in rounds:
        r["minutes"] = wall_minutes(r["thread"], r["turn"])
        r["tokens"] = XR.turn_usage(r["thread"], r["turn"])["tokens"]
        r["findings"] = _findings(r["thread"], r["turn"])
    return rounds, saving


def _judge_known_id(r):
    return "plan-" + r["nonce"]


def _class_id(r, index):
    return "plan-{}-{}".format(r["nonce"], index)


def _excerpt(text, line):
    rows = text.splitlines(True)
    if isinstance(line, int) and not isinstance(line, bool) and line >= 1:
        text = "".join(rows[max(0, line - 1 - CONTEXT):line + CONTEXT])
    return _cap(text, EXCERPT_CAP)


def plan_cases(a):
    """cases --plans: write the judge inputs and, unless --dry-run, plan-cases.json. Returns 0."""
    C.write_briefs(a.state)
    rounds, saving = collect(a.state, a.snapshot_root, a.dry_run)
    skipped = 0
    written = {"judge-known": 0, "judge-class": 0}
    for r in rounds:
        r["known"], r["classes"] = None, {}
        for f in r["findings"]:
            f["plan"] = _plan_of(f, r["plans"])
        if r["next"] is None or not r["findings"]:
            continue
        reader = r["reader"]
        diff = reader.interdiff(r["tip"], r["next"]["tip"], r["changed"])
        if diff is None:
            skipped += 1
            continue
        C.judge_write(a.state, "judge-known", _judge_known_id(r), {"case": r["nonce"], "findings": r["findings"], "interdiff": diff})
        written["judge-known"] += 1
        ans = C.judge_answer(a.state, "judge-known", _judge_known_id(r))
        if not isinstance(ans, dict):
            continue
        yes = set(v.get("index") for v in ans.get("verdicts") or [] if isinstance(v, dict) and v.get("answer") == "yes")
        r["known"] = [f["index"] for f in r["findings"] if f["index"] in yes]
        for f in r["findings"]:
            if f["index"] not in yes:
                continue
            plan = f["plan"]
            paths = [plan] if plan else sorted(r["plans"])
            texts = [(p, reader.text(r["plans"][p])) for p in paths]
            if any(t is None for _p, t in texts):
                skipped += 1
                continue
            body = _excerpt(texts[0][1], f.get("line")) if plan or len(texts) == 1 else _cap(
                "".join("== {} ==\n{}\n".format(p, t) for p, t in texts), EXCERPT_CAP)
            fix = reader.interdiff(r["tip"], r["next"]["tip"], [plan] if plan in r["changed"] else r["changed"])
            keys = ("severity", "file", "line", "summary", "failure_scenario")
            cid = _class_id(r, f["index"])
            C.judge_write(a.state, "judge-class", cid, {"finding": dict((k, f.get(k)) for k in keys), "plan_excerpt": body,
                                                         "fix": fix if fix is not None else ""})
            r["classes"][str(f["index"])] = cid
            written["judge-class"] += 1
    C.say("plan rounds: {} in October; judge-known inputs {}, judge-class inputs {}, skipped {}".format(
        len(rounds), written["judge-known"], written["judge-class"], skipped))
    if not a.dry_run:
        C.jsave(os.path.join(a.state, CASES), {
            "window": list(WINDOW), "skipped": skipped, "lost_saving": saving,
            "rounds": [{"nonce": r["nonce"], "at": r["at"], "repo": r["repo"], "plans": sorted(r["plans"]), "thread": r["thread"],
                        "turn": r["turn"], "verdict": r["verdict"], "minutes": r["minutes"], "tokens": r["tokens"],
                        "next": r["next"]["nonce"] if r["next"] else None, "findings": r["findings"],
                        "known": r["known"], "classes": r["classes"]} for r in rounds]})
    return 0


# ------------------------------------------------------------------ the report
def _fmt(x):
    return "n/a" if x is None else "{:.1f}".format(x)


def report_section(state):
    """(lines, data) for the report's plan-checkpoint section; ([], {}) when plan_cases has found no round."""
    doc = C.jload(os.path.join(state, CASES))
    if not isinstance(doc, dict) or not doc.get("rounds"):
        return [], {}
    rounds = doc["rounds"]
    classes = dict((c, dict((s, 0) for s in SEVERITIES)) for c in CLASSES)
    plans = collections.OrderedDict()

    def plan_row(repo, path):
        return plans.setdefault((repo, path), {"repo": repo, "plan": path, "rounds": 0, "minutes": 0.0, "known": 0, "design_p0p1": 0})

    known = classified = 0
    for r in rounds:
        for path in r["plans"] or ["(none listed)"]:
            row = plan_row(r["repo"], path)
            row["rounds"] += 1
            row["minutes"] += r["minutes"]
        by_index = dict((f["index"], f) for f in r["findings"])
        for idx in r["known"] or []:
            f = by_index[idx]
            known += 1
            row = plan_row(r["repo"], f.get("plan") or (r["plans"] or ["(none listed)"])[0])
            row["known"] += 1
            cid = r["classes"].get(str(idx))
            ans = C.judge_answer(state, "judge-class", cid) if cid else None
            klass = ans.get("class") if isinstance(ans, dict) else None
            if klass in CLASSES:
                classified += 1
                classes[klass][f["severity"]] += 1
                if klass == "design" and f["severity"] in ("P0", "P1"):
                    row["design_p0p1"] += 1
    design = classes["design"]["P0"] + classes["design"]["P1"]
    minutes = sum(r["minutes"] for r in rounds)
    tokens = sum(r["tokens"] for r in rounds)
    saving = doc.get("lost_saving") or {}
    lost = saving.get("bytes", 0) / XP.BYTES_PER_TOKEN
    data = {"rounds": len(rounds), "wall_minutes": minutes, "tokens": tokens, "known": known, "classified": classified,
            "pending": known - classified, "classes": classes, "design_p0p1": design,
            "minutes_per_design": minutes / design if design else None, "tokens_per_design": tokens / design if design else None,
            "lost_saving_tokens": lost, "premerge_receipts": saving.get("receipts", 0),
            "premerge_with_plans": saving.get("with_plans", 0), "unresolved_blobs": saving.get("unresolved", 0),
            "skipped": doc.get("skipped", 0), "plans": list(plans.values()),
            "recommendation": "keep" if design else "inconclusive"}
    out = ["Plan-review checkpoint (spec 5)",
           "  rounds: {} over {} plan(s); wall minutes {}; Codex tokens {}".format(len(rounds), len(plans), _fmt(minutes), tokens),
           "  known-real P0-P2 findings: {} ({} classified, {} awaiting a class)".format(known, classified, known - classified),
           "  {:<14}{:>4}{:>4}{:>4}".format("class", "P0", "P1", "P2")]
    out += ["  {:<14}{:>4}{:>4}{:>4}".format(c, *(classes[c][s] for s in SEVERITIES)) for c in CLASSES]
    if design:
        out.append("  design-class P0/P1: {}; per one caught: {} wall minutes, {:.0f} Codex tokens".format(
            design, _fmt(data["minutes_per_design"]), data["tokens_per_design"]))
    else:
        out.append("  design-class P0/P1: none; cost per one caught: n/a")
    out.append("  lost omit_plans saving: {:.0f} tokens ({} plan bytes / {} per token, over {} October pre-merge receipts, {} listing a plan)".format(
        lost, saving.get("bytes", 0), XP.BYTES_PER_TOKEN, saving.get("receipts", 0), saving.get("with_plans", 0)))
    if saving.get("unresolved"):
        out.append("  {} plans_from blob(s) could not be read and are not in that number".format(saving["unresolved"]))
    if doc.get("skipped"):
        out.append("  {} round(s)/finding(s) skipped: their commits or plan could not be read".format(doc["skipped"]))
    out.append("  per plan:")
    out += ["    {}:{}  rounds {}  wall {} min  known {}  design P0/P1 {}".format(
        p["repo"], p["plan"], p["rounds"], _fmt(p["minutes"]), p["known"], p["design_p0p1"]) for p in plans.values()]
    out.append("  recommendation: {}".format(data["recommendation"]) + (
        " (a design-class P0/P1 occurred: the pre-merge diff cannot show it)" if design else
        " (no design-class P0/P1; removal needs downstream evidence, never this count)"))
    return out, data
