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
MEASURED_SAVING = (19, 100)                    # packets 9: about 19% fewer tokens per pre-merge turn
REGULAR = (b"100644", b"100755")


# ------------------------------------------------------------------ small helpers
def _in_window(at):
    return isinstance(at, str) and WINDOW[0] <= at < WINDOW[1]


_cap = C.cap


def _epoch(stamp):
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?", stamp if isinstance(stamp, str) else "")
    if not m:
        return None
    parts = [int(x) for x in m.groups()[:6]]
    return calendar.timegm(tuple(parts) + (0, 0, 0)) + (float(m.group(7)) if m.group(7) else 0.0)


epoch = _epoch


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


_norm = C.norm


def _plan_of(finding, plans):
    """The plan a finding is about: the one its file names (any ./ or a/ b/ prefix aside), else the
    round's only plan, else None."""
    name = _norm(finding.get("file"))
    for path in sorted(plans):
        if name and (name == path or path.endswith("/" + name) or name.endswith("/" + path)):
            return path
    return next(iter(plans)) if len(plans) == 1 else None


# ------------------------------------------------------------------ reading git through the view
class Reader(C.Reader):
    """common.Reader, and the reads that belong to the plan-review checkpoint."""

    def __init__(self, state, gitdir, root):
        C.Reader.__init__(self, state, gitdir, root)
        self._diffs = {}

    def plan_blobs(self, base, tip):
        """{plan path: blob at tip} of the plans base..tip changes and still has (regular files under
        docs/superpowers/plans/, as the packet builder lists them), or None when the range cannot be read."""
        if not (self.has_commit(base) and self.has_commit(tip)):
            return None
        try:
            out = C.git(self.view, *(L.DIFF_RAW + [base, tip, "--"]), raw=True)
        except Failed:
            return None
        fields, found, i = out.split(b"\0"), {}, 0
        while i + 1 < len(fields) and fields[i]:
            meta = fields[i][1:].split(b" ")
            path = fields[i + 1].decode("utf-8", "replace")
            if len(meta) == 5 and path.startswith(PLAN_DIR) and meta[1] in REGULAR:
                found[path] = meta[3].decode("ascii")
            i += 2
        return found

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
def collect(state, root):
    """(rounds, saving, skips) from the ledgers: the October plan-checkpoint rounds, each linked to its
    next round; the October pre-merge receipts that omitted a plan (once per nonce): their plans_from
    blob bytes and the Codex tokens of their turns (the receipt's and every slice_turns entry, once each); and skips, [{kind: round, nonce, reason}]."""
    rounds, readers, skips, seen = [], {}, [], set()
    saving = {"bytes": 0, "receipts": 0, "with_plans": 0, "unresolved": 0, "omit_tokens": 0}
    for gitdir, entries in XR.ledgers():
        reader = readers.setdefault(gitdir, Reader(state, gitdir, root))
        chains = collections.defaultdict(list)
        for e in entries:
            at = e.get("dispatched_at")
            if e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "plan":
                target = _plan_target(e)
                if target is None:
                    continue
                blobs = target.get("plan_blobs")
                if not isinstance(blobs, dict):
                    blobs = reader.plan_blobs(target["base"], target["tip"])
                    if blobs is None:
                        blobs = {}
                        if _in_window(at):
                            skips.append({"kind": "round", "nonce": e["nonce"],
                                          "reason": "plan blobs not derivable: the range's commits cannot be read"})
                chains[e["thread"]].append({
                    "nonce": e["nonce"], "at": at, "gitdir": gitdir, "reader": reader, "repo": C.repo_name(gitdir),
                    "thread": e["thread"], "turn": e["turn"], "verdict": e.get("verdict"), "base": target["base"],
                    "tip": target["tip"], "counted": _in_window(at), "next": None,
                    "plans": dict((p, b) for p, b in blobs.items() if isinstance(p, str) and isinstance(b, str))})
            elif (e.get("v") == 2 and e.get("kind") == "receipt" and e.get("checkpoint") == "pre-merge" and _in_window(at)
                  and isinstance(e.get("nonce"), str) and e["nonce"] not in seen):
                seen.add(e["nonce"])
                saving["receipts"] += 1
                listed = [p for t in e.get("targets") or [] if isinstance(t, dict) for p in t.get("plans_from") or []
                          if isinstance(p, dict)]
                if listed:
                    saving["with_plans"] += 1
                    turns = [(e.get("thread"), e.get("turn"))] + [(t.get("thread"), t.get("turn")) for t in e.get("slice_turns") or []
                                                                     if isinstance(t, dict)]
                    saving["omit_tokens"] += sum(XR.turn_usage(th, tu)["tokens"]
                                                 for th, tu in sorted(set(x for x in turns if all(isinstance(y, str) and y for y in x))))
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
        r["plan_of"] = dict((f["index"], _plan_of(f, r["plans"])) for f in r["findings"])
    return rounds, saving, skips


def _judge_known_id(nonce):
    return "plan-" + nonce


def _class_id(nonce, index):
    return "plan-{}-{}".format(nonce, index)


def _excerpt(text, line):
    rows = text.splitlines(True)
    if isinstance(line, int) and not isinstance(line, bool) and line >= 1:
        text = "".join(rows[max(0, line - 1 - CONTEXT):line + CONTEXT])
    return _cap(text, EXCERPT_CAP)


def plan_cases(a):
    """cases --plans: write the judge inputs and, unless --dry-run, plan-cases.json. Returns 0."""
    C.write_briefs(a.state)
    rounds, saving, skips = collect(a.state, a.snapshot_root)
    written = {"judge-known": 0, "judge-class": 0}
    keys = ("severity", "file", "line", "summary", "failure_scenario")
    for r in rounds:
        r["asked"] = False
        if r["next"] is None or not r["findings"]:
            continue
        reader = r["reader"]
        diff = reader.interdiff(r["tip"], r["next"]["tip"], r["changed"])
        if diff is None:
            skips.append({"kind": "round", "nonce": r["nonce"],
                          "reason": "the next round's tip cannot be read, or does not follow this tip"})
            continue
        C.judge_write(a.state, "judge-known", _judge_known_id(r["nonce"]),
                      {"case": r["nonce"], "findings": r["findings"], "interdiff": diff})
        r["asked"] = True
        written["judge-known"] += 1
        ans = C.judge_answer(a.state, "judge-known", _judge_known_id(r["nonce"]))
        if not isinstance(ans, dict):
            continue
        yes = set(v.get("index") for v in ans.get("verdicts") or [] if isinstance(v, dict) and v.get("answer") == "yes")
        for f in r["findings"]:
            if f["index"] not in yes:
                continue
            plan = r["plan_of"][f["index"]]
            paths = [plan] if plan else sorted(r["plans"])
            texts = [(p, reader.text(r["plans"][p])) for p in paths]
            if not texts or any(t is None for _p, t in texts):
                skips.append({"kind": "finding", "nonce": r["nonce"], "index": f["index"],
                              "reason": "the plan text cannot be read" if texts else "the round lists no plan"})
                continue
            body = _excerpt(texts[0][1], f.get("line")) if plan else _cap(
                "".join("== {} ==\n{}\n".format(p, t) for p, t in texts), EXCERPT_CAP)
            fix = reader.interdiff(r["tip"], r["next"]["tip"], [plan] if plan in r["changed"] else r["changed"])
            C.judge_write(a.state, "judge-class", _class_id(r["nonce"], f["index"]),
                          {"finding": dict((k, f.get(k)) for k in keys), "plan_excerpt": body,
                           "fix": fix if fix is not None else ""})
            written["judge-class"] += 1
    by_kind = collections.Counter(s["kind"] for s in skips)
    C.say("plan rounds: {} in October; judge-known inputs {}, judge-class inputs {}; skipped {} round(s), {} finding(s)".format(
        len(rounds), written["judge-known"], written["judge-class"], by_kind["round"], by_kind["finding"]))
    for s in skips:
        C.say("  skipped {} {}{}: {}".format(s["kind"], s["nonce"], "" if "index" not in s else " #{}".format(s["index"]), s["reason"]))
    if not a.dry_run:
        C.jsave(os.path.join(a.state, CASES), {
            "window": list(WINDOW), "skips": skips, "lost_saving": saving,
            "rounds": [{"nonce": r["nonce"], "at": r["at"], "repo": r["repo"], "plans": sorted(r["plans"]), "thread": r["thread"],
                        "turn": r["turn"], "verdict": r["verdict"], "minutes": r["minutes"], "tokens": r["tokens"],
                        "next": r["next"]["nonce"] if r["next"] else None, "asked": r["asked"],
                        "findings": [dict(f, plan=r["plan_of"][f["index"]]) for f in r["findings"]]} for r in rounds]})
    return 0


# ------------------------------------------------------------------ the report
def _fmt(x):
    return "n/a" if x is None else "{:.1f}".format(x)


def _blank():
    return dict((c, dict((s, 0) for s in SEVERITIES)) for c in CLASSES)


def _per(total, n):
    return total / n if n else None


def report_section(state):
    """(lines, data) for the report's plan-checkpoint section; ([], {}) when plan_cases has found no round.
    Judge answers are read now, not from plan-cases.json, so the section is current whenever the judges
    have answered; whatever is still missing is counted and makes the recommendation incomplete."""
    doc = C.jload(os.path.join(state, CASES))
    if not isinstance(doc, dict) or not doc.get("rounds"):
        return [], {}
    rounds, skips = doc["rounds"], doc.get("skips") or []
    skipped_findings = set((s["nonce"], s["index"]) for s in skips if s.get("kind") == "finding")
    skipped_rounds = [s for s in skips if s.get("kind") == "round"]
    classes = _blank()
    plans = collections.OrderedDict()

    def row(repo, path):
        return plans.setdefault((repo, path), {"repo": repo, "plan": path, "rounds": 0, "minutes": 0.0, "tokens": 0, "known": 0,
                                               "classes": _blank(), "design_p0p1": 0})

    known = classified = pending_known = no_input = pending_class = unclassifiable = 0
    for r in rounds:
        for path in r["plans"] or ["(none listed)"]:
            p = row(r["repo"], path)
            p["rounds"] += 1
            p["minutes"] += r["minutes"]
            p["tokens"] += r["tokens"]
        if not r.get("asked"):
            continue
        ans = C.judge_answer(state, "judge-known", _judge_known_id(r["nonce"]))
        if not isinstance(ans, dict):
            pending_known += 1
            continue
        yes = set(v.get("index") for v in ans.get("verdicts") or [] if isinstance(v, dict) and v.get("answer") == "yes")
        for f in r["findings"]:
            if f["index"] not in yes:
                continue
            known += 1
            p = row(r["repo"], f.get("plan") or "(unattributed)")
            p["known"] += 1
            cid = _class_id(r["nonce"], f["index"])
            if (r["nonce"], f["index"]) in skipped_findings:
                unclassifiable += 1
                continue
            if not os.path.isfile(os.path.join(state, "judge-class", cid + ".json")):
                no_input += 1
                continue
            ans = C.judge_answer(state, "judge-class", cid)
            klass = ans.get("class") if isinstance(ans, dict) else None
            if klass not in CLASSES:
                pending_class += 1
                continue
            classified += 1
            classes[klass][f["severity"]] += 1
            p["classes"][klass][f["severity"]] += 1
            if klass == "design" and f["severity"] in ("P0", "P1"):
                p["design_p0p1"] += 1
    for p in plans.values():
        counted = p["design_p0p1"] and p["rounds"]      # a row with no rounds credited (unattributed) has no cost to divide
        p["minutes_per_design"] = _per(p["minutes"], p["design_p0p1"]) if counted else None
        p["tokens_per_design"] = _per(p["tokens"], p["design_p0p1"]) if counted else None
    design = classes["design"]["P0"] + classes["design"]["P1"]
    minutes = sum(r["minutes"] for r in rounds)
    tokens = sum(r["tokens"] for r in rounds)
    saving = doc.get("lost_saving") or {}
    lower = saving.get("bytes", 0) / XP.BYTES_PER_TOKEN
    measured = saving.get("omit_tokens", 0) * MEASURED_SAVING[0] / MEASURED_SAVING[1]
    incomplete = bool(pending_known or no_input or pending_class or unclassifiable or skips)
    data = {"rounds": len(rounds), "wall_minutes": minutes, "tokens": tokens, "known": known, "classified": classified,
            "pending": known - classified - unclassifiable, "pending_known": pending_known, "no_input": no_input,
            "pending_class": pending_class, "unclassifiable": unclassifiable, "classes": classes, "design_p0p1": design,
            "minutes_per_design": _per(minutes, design), "tokens_per_design": _per(tokens, design),
            "lost_saving_tokens": lower, "lost_saving_measured_tokens": measured,
            "net_tokens_lower": tokens - lower, "net_tokens_measured": tokens - measured,
            "premerge_receipts": saving.get("receipts", 0), "premerge_with_plans": saving.get("with_plans", 0),
            "premerge_omit_tokens": saving.get("omit_tokens", 0), "unresolved_blobs": saving.get("unresolved", 0),
            "skipped_rounds": len(skipped_rounds), "skipped_findings": len(skipped_findings), "skips": skips,
            "plans": list(plans.values()), "incomplete": incomplete, "recommendation": "keep" if design else "inconclusive"}
    out = ["Plan-review checkpoint (spec 5)",
           "  rounds: {} over {} plan(s); wall minutes {}; Codex tokens {}".format(len(rounds), len(plans), _fmt(minutes), tokens),
           "  known-real P0-P2 findings: {} ({} classified)".format(known, classified)]
    if pending_known or no_input or pending_class or unclassifiable:
        out.append("  pending: {} round(s) awaiting judge-known, {} known-real finding(s) without a judge-class input "
                   "(run cases --plans again), {} awaiting a class, {} not sent to a judge (see skipped)".format(
                       pending_known, no_input, pending_class, unclassifiable))
    out.append("  {:<14}{:>4}{:>4}{:>4}".format("class", "P0", "P1", "P2"))
    out += ["  {:<14}{:>4}{:>4}{:>4}".format(c, *(classes[c][s] for s in SEVERITIES)) for c in CLASSES]
    if design:
        out.append("  design-class P0/P1: {}; per one caught: {} wall minutes, {:.0f} Codex tokens".format(
            design, _fmt(data["minutes_per_design"]), data["tokens_per_design"]))
    else:
        out.append("  design-class P0/P1: none; cost per one caught: n/a")
    out.append("  lost omit_plans saving, two estimates (October pre-merge receipts, once per nonce: {} receipts, {} omitting a plan):".format(
        saving.get("receipts", 0), saving.get("with_plans", 0)))
    out.append("    (a) lower bound, plans_from blob bytes {} / {} per token: {:.0f} tokens; net of plan review: {:.0f} tokens".format(
        saving.get("bytes", 0), XP.BYTES_PER_TOKEN, lower, tokens - lower))
    out.append("    (b) packets 9's measure, {}% of the {} Codex tokens of those pre-merge turns: {:.0f} tokens; net of plan review: {:.0f} tokens".format(
        MEASURED_SAVING[0], saving.get("omit_tokens", 0), measured, tokens - measured))
    out.append("    net = plan-review Codex tokens ({}) minus the lost saving; plan-review wall minutes {}".format(tokens, _fmt(minutes)))
    if saving.get("unresolved"):
        out.append("  {} plans_from blob(s) could not be read and are not in (a)".format(saving["unresolved"]))
    for s in skips:
        out.append("  skipped {} {}{}: {}".format(s["kind"], s["nonce"], "" if "index" not in s else " #{}".format(s["index"]), s["reason"]))
    out.append("  per plan (a round is credited to every plan it lists, so rows can sum above the totals):")
    for p in plans.values():
        out.append("    {}:{}  rounds {}  wall {} min  tokens {}  known {}  design P0/P1 {}  per one: {} min, {} tokens".format(
            p["repo"], p["plan"], p["rounds"], _fmt(p["minutes"]), p["tokens"], p["known"], p["design_p0p1"],
            _fmt(p["minutes_per_design"]), "n/a" if p["tokens_per_design"] is None else "{:.0f}".format(p["tokens_per_design"])))
        out.append("      " + "; ".join("{} {}".format(c, "/".join(str(p["classes"][c][s]) for s in SEVERITIES)) for c in CLASSES)
                   + "  (P0/P1/P2)")
    if design:
        out.append("  recommendation: keep (a design-class P0/P1 occurred: the pre-merge diff cannot show it)"
                   + ("; classification incomplete, more may follow" if incomplete else ""))
    elif incomplete:
        out.append("  recommendation: inconclusive (classification incomplete)")
    else:
        out.append("  recommendation: inconclusive (no design-class P0/P1; removal needs downstream evidence, never this count)")
    return out, data
