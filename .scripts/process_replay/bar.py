"""`report`: the per-run pass bar (spec 4.6), the per-task reviewer's October cost, and the plan-checkpoint section.

Reads <state>/cases.json, runs/<case>/<label>/state.json, inventory/<branch>.json, injected/<branch>.json, branches.json,
cuts/judge-present/ (the judge-present inputs that fell back to the cut from the top, counted per site) and reviews.json, and writes
report.md and report.json beside them (with --dry-run it prints the report and writes nothing).

bar(cases, runs, coverage) takes each case with the inventory records of its defects attached as case["info"] ({id: defect}), because
the class, severity and summary of a defect are not in the run states. Precedence: fail > pass > inconclusive,
except that a failing or unsettled coverage gate makes every verdict inconclusive (spec 4.3, 14.5): the fails stay in the reasons, first.

  assessable  the run ended approve, rounds or stalled, recovered at least 80% of its pre-merge class and censored at most 25% of its
              per-task class (counted defects, P0-P2).
  fail        an assessable run left a per-task P0/P1 unrecovered while it recovered every pre-merge P0/P1 of its case.
  pass        every case has all its runs, every run is assessable, every counted per-task defect is recovered in every run, and the
              coverage gate holds and is settled (coverage.unassessable_task and coverage.waiting are empty; a cases.json without
              `waiting` reads as empty).
  inconclusive anything else.

A run voided and replaced by a re-run is not counted; a final void (no replacement) or an error run is not assessable.

A run counts only for the case inputs it began with: it records common.case_digest of its case (run["case_digest"]), `bar` takes each
case's current one as case["digest"], and a run with another digest, or one `run` marked superseded, is set aside: not counted, not
tallied, listed apart (bar()["superseded"], the report). `run` then makes fresh runs of the case as it is now.
"""
import collections
import glob
import json
import os

from . import common as C
from . import excerpts
from . import planreview
from .common import Failed, jload, say

RECALL = (4, 5)               # assessable: at least 4/5 of the pre-merge class recovered (spec 4.6)
CENSORED = (1, 4)             # assessable: at most 1/4 of the per-task class censored
ENDED = ("approve", "rounds", "stalled")
SEVERE = ("P0", "P1")
OK = ("present", "recreated")                      # an injected defect that counts (inject.OK)
NO_PRE = "no pre-merge defects to calibrate against"
STATES = ("recovered", "unrecovered", "censored", "present")


# ------------------------------------------------------------------ the bar
def _info(case, did):
    try:
        return case["info"][did]
    except KeyError:
        raise Failed("case {}: defect {} is not in the inventory of branch {}".format(case["id"], did, case.get("branch")))


def _tally(case, run):
    """{task|pre: {state: n}} and the counted defect ids of each class with their state, for one run."""
    out = {"task": dict((s, 0) for s in STATES), "pre": dict((s, 0) for s in STATES), "ids": {"task": [], "pre": []}}
    for did, state in sorted(run["defects"].items()):
        d = _info(case, did)
        if not d.get("counted"):
            continue
        klass = "task" if d.get("class") == "task" else "pre"
        out[klass][state if state in STATES else "present"] += 1
        out["ids"][klass].append((did, d.get("severity"), state))
    return out


def _why_not(run, tally):
    """Why the run is not assessable, or None."""
    if run.get("end") not in ENDED:
        return "it did not finish ({})".format(run.get("end") or "still running")
    left = tally["task"]["present"] + tally["pre"]["present"]
    if left:
        return "{} defect(s) were never settled".format(left)
    pre, task = tally["pre"], tally["task"]
    n_pre, n_task = sum(pre.values()), sum(task.values())
    if not n_pre:
        return NO_PRE
    if pre["recovered"] * RECALL[1] < n_pre * RECALL[0]:
        return "pre-merge recall {}/{} is under 80%".format(pre["recovered"], n_pre)
    if task["censored"] * CENSORED[1] > n_task * CENSORED[0]:
        return "{}/{} per-task defects censored is over 25%".format(task["censored"], n_task)
    return None


def runs_of(a):
    """Every run state under <state>/runs/<case>/<label>/state.json."""
    out = []
    for path in sorted(glob.glob(os.path.join(glob.escape(a.state), "runs", "*", "*", "state.json"))):
        run = jload(path)
        if isinstance(run, dict) and isinstance(run.get("label"), str) and isinstance(run.get("case"), str):
            out.append(run)
    return out


def current(case, run):
    """Whether `run` was made for the case's inputs as they are now (and not set aside)."""
    return not run.get("superseded") and run.get("case_digest") == case.get("digest")


def set_aside(runs, case):
    """The case's runs made for other inputs than it has now, by label."""
    return sorted((r for r in runs if r["case"] == case["id"] and not current(case, r)), key=lambda r: r["label"])


def live_runs(runs, case):
    """The case's runs that count: those made for its inputs as they are, and not replaced by a re-run after a void."""
    return sorted((r for r in runs if r["case"] == case["id"] and current(case, r) and not (r.get("end") == "void" and r.get("replaced_by"))),
                  key=lambda r: r["label"])


def bar(cases, runs, coverage):
    fails, blocks = [], []
    assessable, unrecovered, uncounted, no_pre, superseded = {}, [], [], [], {}
    for case in cases:
        if not [d for d in case["defects"] if _info(case, d).get("class") != "task"]:
            no_pre.append(case["id"])
        mine = live_runs(runs, case)
        old = [r["label"] for r in set_aside(runs, case)]
        if old:
            superseded[case["id"]] = old
        if len(mine) < C.RUNS:
            blocks.append("case {}: {} of {} runs{}".format(case["id"], len(mine), C.RUNS, " ({} more set aside as superseded: the case's inputs changed since they ran; "
                                                            "`run` makes fresh ones)".format(len(old)) if old else ""))
        uncounted += [{"case": case["id"], "defect": d["id"], "severity": d.get("severity"), "summary": d.get("summary")}
                      for d in sorted(case["info"].values(), key=lambda x: x["id"]) if d.get("class") == "task" and not d.get("counted")]
        for run in mine:
            tally = _tally(case, run)
            why = _why_not(run, tally)
            assessable[run["label"]] = why is None
            where = "case {} run {}".format(case["id"], run["label"])
            missed = [(did, sev, st) for did, sev, st in tally["ids"]["task"] if st == "unrecovered"]
            for did, sev, _st in missed:
                unrecovered.append({"case": case["id"], "run": run["label"], "defect": did, "severity": sev, "summary": _info(case, did).get("summary")})
            if why:
                blocks.append("{} is not assessable: {}".format(where, why))
            pre_severe_missed = [did for did, sev, st in tally["ids"]["pre"] if sev in SEVERE and st != "recovered"]
            severe = [did for did, sev, _st in missed if sev in SEVERE]
            if why is None and severe and not pre_severe_missed:
                fails.append("{}: per-task {} unrecovered while every pre-merge P0/P1 was recovered".format(
                    where, ", ".join("{} {}".format(_info(case, d)["severity"], d) for d in severe)))
            left = [(did, sev, st) for did, sev, st in tally["ids"]["task"] if st != "recovered"]
            if left:
                blocks.append("{}: per-task defects not recovered: {}".format(where, ", ".join("{} {} {}".format(sev, did, st) for did, sev, st in left)))
            if severe and pre_severe_missed:
                blocks.append("{}: a per-task P0/P1 miss is no fail while pre-merge P0/P1 {} went unrecovered".format(where, ", ".join(pre_severe_missed)))
    held = (coverage or {}).get("unassessable_task") or []
    if held:
        blocks.append("coverage gate: per-task defects unassessable after the second attempt: {}".format(", ".join(held)))
    unsettled = (coverage or {}).get("waiting") or []
    if unsettled:
        blocks.append("coverage gate: not settled, branch(es) still waiting for answers: {}".format(", ".join(unsettled)))
    if not cases:
        blocks.append("there are no cases")
    if fails and not held and not unsettled:
        status, reasons = "fail", fails
    elif blocks:
        status, reasons = "inconclusive", fails + blocks     # under a failing or unsettled gate the fails stay in the report, first
    else:
        status, reasons = "pass", ["every run of every case is assessable and every per-task defect was recovered in every run"]
    return {"status": status, "assessable": assessable, "reasons": reasons, "unrecovered_task": unrecovered, "uncounted_task": uncounted, "no_pre_cases": no_pre,
            "superseded": superseded}


# ------------------------------------------------------------------ the report's numbers
def run_row(case, run):
    tally = _tally(case, run)
    codex = [r for r in run.get("reviews") or [] if r.get("kind") == "codex"]
    original = case.get("original_rounds") or 0
    models = sorted(set("{} {}".format(r.get("model") or "?", r.get("effort") or "?") for r in codex))
    return {"label": run["label"], "end": run.get("end"), "voids": run.get("voids", 0), "replaced_by": run.get("replaced_by"),
            "replaces": run.get("replaces"), "leak": run.get("leak") or [], "error": run.get("error"),
            "task": dict((s, tally["task"][s]) for s in STATES if s != "present"), "pre": dict((s, tally["pre"][s]) for s in STATES if s != "present"),
            "codex_rounds": len(codex), "original_rounds": original, "extra_rounds": len(codex) - original,
            "codex_tokens": sum(r.get("tokens") or 0 for r in codex), "tokens": run.get("tokens") or 0, "models": models}


def october(branch, groups):
    """The per-task reviewer's October cost on a branch, per task: dispatches, tokens and wall minutes of the reviews that joined it."""
    tasks = []
    for j in (branch or {}).get("joined") or []:
        g = groups.get(j.get("group"))
        if not g:
            continue
        reviews = [g["reviews"][i] for i in j.get("reviews") or [] if isinstance(i, int) and 0 <= i < len(g["reviews"])]
        minutes = 0.0
        for r in reviews:
            start, end = planreview.epoch(r.get("start")), planreview.epoch(r.get("end"))
            if start is not None and end is not None:
                minutes += (end - start) / 60.0
        tasks.append({"task": g.get("task"), "prefix": g.get("prefix"), "dispatches": len(reviews),
                      "tokens": sum(r.get("tokens") or 0 for r in reviews), "minutes": minutes})
    return {"tasks": tasks, "dispatches": sum(t["dispatches"] for t in tasks), "tokens": sum(t["tokens"] for t in tasks),
            "minutes": sum(t["minutes"] for t in tasks)}


def drops(cases, inventories, injected):
    """Counts of what the injection and the inventory lost, by reason, over the case branches."""
    inj = collections.defaultdict(collections.Counter)
    inv = collections.Counter()
    pre_p2 = 0
    for case in cases:
        for d in (inventories.get(case["branch"]) or {}).get("dropped") or []:
            inv[d.get("why") or "(no reason)"] += 1
        defects = (injected.get(case["branch"]) or {}).get("defects") or {}
        for did, rec in sorted(defects.items()):
            if rec.get("status") in OK:
                continue
            inj[rec.get("status")][rec.get("reason") or "(no reason)"] += 1
            d = case["info"].get(did) or {}
            if d.get("class") == "pre" and d.get("severity") == "P2" and d.get("counted"):
                pre_p2 += 1
    return {"injected": dict((s, dict(c)) for s, c in sorted(inj.items())), "inventory": dict(inv), "unassessable_pre_p2": pre_p2}


# ------------------------------------------------------------------ the command
def _load(a):
    doc = jload(os.path.join(a.state, "cases.json"))
    if not isinstance(doc, dict) or not isinstance(doc.get("cases"), list):
        raise Failed("no cases.json in {}: run inject first".format(a.state))
    inventories, injected = {}, {}
    branches = dict((b["id"], b) for b in (jload(os.path.join(a.state, "branches.json")) or {}).get("branches") or []
                    if isinstance(b, dict) and isinstance(b.get("id"), str))
    cases = []
    for c in doc["cases"]:
        if not isinstance(c, dict):
            continue
        inv = jload(os.path.join(a.state, "inventory", c["branch"] + ".json"))
        if not isinstance(inv, dict):
            raise Failed("case {}: no inventory/{}.json".format(c["id"], c["branch"]))
        inventories[c["branch"]] = inv
        injected[c["branch"]] = jload(os.path.join(a.state, "injected", c["branch"] + ".json")) or {}
        info = dict((d["id"], d) for d in inv.get("defects") or [] if isinstance(d, dict) and "id" in d)
        cases.append(dict(c, info=info, digest=C.case_digest(c, branches.get(c["branch"]), injected[c["branch"]], info)))
    return doc, cases, inventories, injected, branches


def _mins(x):
    return "{:.1f}".format(x)


def render(status, doc, cases, runs, rows, cost, dropped, branches, plan_lines, cut):
    out = ["Replay report: the per-task reviewer's pass bar (spec 4.6)", "", "status: {}".format(status["status"].upper()), "reasons:"]
    out += ["  - " + r for r in status["reasons"]]
    out += ["", "coverage gate: per-task defects unassessable after the second attempt: {}; branches still waiting: {}".format(
        ", ".join((doc.get("coverage") or {}).get("unassessable_task") or []) or "none", ", ".join((doc.get("coverage") or {}).get("waiting") or []) or "none"),
            "judge-present inputs cut from the top (no anchor located): {} (presence {}, validation {}, revalidation {})".format(
                sum(cut.values()), cut["presence"], cut["validation"], cut["revalidation"]), "", "Cases"]
    total = {True: collections.Counter(), False: collections.Counter()}
    for case in cases:
        br = branches.get(case["branch"]) or {}
        out.append("case {}  branch {} ({}); {} per-task and {} pre-merge counted defects; original pre-merge rounds {}".format(
            case["id"], br.get("branch") or case["branch"], case.get("repo"),
            sum(1 for d in case["defects"] if _info(case, d).get("class") == "task"),
            sum(1 for d in case["defects"] if _info(case, d).get("class") != "task"), case.get("original_rounds")))
        for r in rows[case["id"]]:
            ok_ = status["assessable"].get(r["label"])
            total[bool(ok_)].update({"runs": 1, "extra": r["extra_rounds"], "tokens": r["codex_tokens"]})
            out.append("  run {}: ended {}; assessable {}; Codex rounds {} (original {}, extra {:+d}); Codex tokens {} (run total {}); model/effort {}; voids {}".format(
                r["label"], r["end"], "yes" if ok_ else "no", r["codex_rounds"], r["original_rounds"], r["extra_rounds"], r["codex_tokens"], r["tokens"],
                ", ".join(r["models"]) or "none", r["voids"]))
            for k, name in (("task", "per-task"), ("pre", "pre-merge")):
                out.append("      {}: recovered {}, unrecovered {}, censored {}".format(name, r[k]["recovered"], r[k]["unrecovered"], r[k]["censored"]))
            if r["replaces"]:
                out.append("      re-run of void run {}".format(r["replaces"]))
        live = set(x["label"] for x in live_runs(runs, case))
        for r in sorted((x for x in runs if x["case"] == case["id"] and current(case, x) and x["label"] not in live), key=lambda x: x["label"]):
            out.append("  void run {}: replaced by {}; leak {}".format(r["label"], r.get("replaced_by"), ", ".join(r.get("leak") or []) or "none"))
        old = status["superseded"].get(case["id"])
        if old:
            out.append("  {} run(s) set aside as superseded, not counted: the case's inputs (its injected tree, defects, repairs or branch) changed after they began: {}".format(
                len(old), ", ".join(old)))
    out += ["", "Extra Codex rounds the simulation needed (simulated minus original), over the {} assessable run(s): {:+d}; Codex tokens: {}".format(
        total[True]["runs"], total[True]["extra"], total[True]["tokens"]),
            "  over the {} run(s) that are not assessable (error, final void, unfinished, too much censored or missed, or no pre-merge class): {:+d}; Codex tokens: {}".format(
                total[False]["runs"], total[False]["extra"], total[False]["tokens"]),
            "", "Cases with no pre-merge defects, so no run of them is assessable ({}): {}".format(NO_PRE, ", ".join(status["no_pre_cases"]) or "none"),
            "", "Per-task defects left unrecovered in any run: {}".format(len(status["unrecovered_task"]))]
    for u in status["unrecovered_task"]:
        out.append("  case {} run {}: {} {}: {}".format(u["case"], u["run"], u["severity"], u["defect"], u["summary"]))
    out += ["", "Per-task P3 defects (listed, not counted): {}".format(len(status["uncounted_task"]))]
    for u in status["uncounted_task"]:
        out.append("  case {}: {} {}: {}".format(u["case"], u["severity"], u["defect"], u["summary"]))
    out += ["", "The per-task reviewer's October cost, per task (dispatches, tokens, wall minutes from the transcripts)"]
    if cost is None:
        out.append("  unavailable: no reviews.json")
    else:
        all_ = collections.Counter()
        for case in cases:
            o = cost[case["id"]]
            if o is None:
                out.append("case {}: unknown, branch {} is not in branches.json".format(case["id"], case["branch"]))
                all_["unknown"] += 1
                continue
            out.append("case {}: dispatches {}, tokens {}, wall minutes {}".format(case["id"], o["dispatches"], o["tokens"], _mins(o["minutes"])))
            for t in o["tasks"]:
                out.append("  task {}{}: dispatches {}, tokens {}, wall minutes {}".format(t["task"], " ({})".format(t["prefix"]) if t.get("prefix") else "",
                                                                                           t["dispatches"], t["tokens"], _mins(t["minutes"])))
            all_.update({"d": o["dispatches"], "t": o["tokens"], "m": o["minutes"]})
        out.append("all cases: dispatches {}, tokens {}, wall minutes {}{}".format(
            all_["d"], all_["t"], _mins(all_["m"]), " ({} case(s) unknown, not included)".format(all_["unknown"]) if all_["unknown"] else ""))
    out += ["", "What the injection and the inventory lost, by reason (case branches)"]
    for s, reasons in sorted(dropped["injected"].items()):
        out.append("  {}: {}".format(s, "; ".join("{}: {}".format(w, n) for w, n in sorted(reasons.items()))))
    out.append("  inventory: " + ("; ".join("{}: {}".format(w, n) for w, n in sorted(dropped["inventory"].items())) or "none"))
    out.append("  unassessable pre-merge P2 defects (counted, not disqualifying): {}".format(dropped["unassessable_pre_p2"]))
    gone = [e for e in doc.get("examined") or [] if isinstance(e, dict) and not e.get("qualified")]
    out += ["", "Examined branches that did not become cases: {}".format(len(gone))]
    for e in gone:
        br = branches.get(e.get("branch")) or {}
        out.append("  {} ({} {}): {}".format(e.get("branch"), br.get("repo") or "?", br.get("branch") or "?", e.get("why")))
    if plan_lines:
        out += [""] + plan_lines
    return "\n".join(out) + "\n"


@C.locked("shared")
def cmd_report(a):
    doc, cases, inventories, injected, branches = _load(a)
    ids = set(c["id"] for c in cases)
    runs = [r for r in runs_of(a) if r["case"] in ids]
    status = bar(cases, runs, doc.get("coverage"))
    rows = dict((c["id"], [run_row(c, r) for r in live_runs(runs, c)]) for c in cases)
    reviews = jload(os.path.join(a.state, "reviews.json"))
    cost = None
    if isinstance(reviews, dict) and isinstance(reviews.get("groups"), list):
        groups = dict((g["id"], g) for g in reviews["groups"] if isinstance(g, dict) and "id" in g)
        cost = dict((c["id"], october(branches[c["branch"]], groups) if c["branch"] in branches else None) for c in cases)
    dropped = drops(cases, inventories, injected)
    plan_lines, plan_data = planreview.report_section(a.state)
    cut = excerpts.count_cuts(a.state)
    text = render(status, doc, cases, runs, rows, cost, dropped, branches, plan_lines, cut)
    data = {"bar": status, "coverage": doc.get("coverage") or {}, "cut_inputs": cut, "drops": dropped, "examined_not_cases": [e for e in doc.get("examined") or []
                                                                                                         if isinstance(e, dict) and not e.get("qualified")],
            "cases": [dict(id=c["id"], branch=c["branch"], repo=c.get("repo"), original_rounds=c.get("original_rounds"), runs=rows[c["id"]],
                           superseded=status["superseded"].get(c["id"], []),
                           october=(cost or {}).get(c["id"]),
                           october_unknown=("branch {} is not in branches.json".format(c["branch"]) if cost is not None and cost.get(c["id"]) is None else None))
                      for c in cases],
            "planreview": plan_data or None}
    if a.dry_run:
        print(text, end="")
        return 0
    C.jsave(os.path.join(a.state, "report.md"), text)
    C.jsave(os.path.join(a.state, "report.json"), json.dumps(data, indent=2))
    aside = sum(len(v) for v in status["superseded"].values())
    say("report: {} ({} case(s), {} run(s){}); written to {}".format(status["status"], len(cases), sum(len(v) for v in rows.values()),
                                                                    ", {} set aside as superseded".format(aside) if aside else "", os.path.join(a.state, "report.md")))
    return 0
