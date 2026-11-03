"""`run`, `match` and `cleanup`: the gates that stay, driven for every case's two runs (spec 4.4, 4.5, 7.1).

A run takes an injected tree through the final whole-branch review, then the Codex pre-merge loop:

  final   a brief for the final reviewer is written (final/<id>/brief.md); the driving session dispatches an sp-architect
          subagent from it, and writes its answer to final/<id>/answer.md. Its transcript is scanned for reads of the
          original checkout (a leak voids the run); the answer goes to a judge-match (the report form).
  match   a judge-match holds the defects still present (shuffled per review, no class) and the review's findings.
  valid   after the oracle fixer re-applied the matched repairs (one commit), a judge-present for each remaining defect
          whose hunk lines the commit changed, or whose repair no longer applies.
  codex   a Codex round (codex.codex_round) on the repaired tree, at most TURNS in flight across all runs.
  done

`run` advances every run as far as it can without a Claude answer; `match` applies the answers only and starts no round.
Both are idempotent: with nothing new answered, no state file changes.

The run state is the Shared record of the plan, plus: base_tip (the scratch commit holding the injected tree), repairs
({defect: {repair: patch path, group, hunks}}, from injected/<branch>.json when the run was made; the patch is the run's own copy,
runs/<case>/<label>/repairs/<defect>.patch, which a later `inject` leaves alone), judging (what the run
waits for), failures (consecutive failed rounds), leak, error, and for a voided run replaced_by (its replacement's label)
or, for the replacement, replaces. A voided run keeps end "void" and voids 1; its replacement starts at voids 1 and ends
"void" with voids 2 if it leaks as well.

The final review's id is the run's label. Its brief is staged (final.py); the driving session hands the reviewer the staged
brief and writes the reply to the staged directory's answer.md.

Concurrency (common.command_locks). `run` shares <state>/run.lock with `match`, `pending` and `report` and holds <state>/runner.lock
alone for its whole life (a second `run` refuses), keeps to TURNS Codex turns, and alone creates runs; it holds the replay daemons'
lock from its entry too. `cleanup` holds run.lock exclusively, so it refuses while any of those is going. Every mutation of a run
holds that run's lock (runs/<case>/<label>/lock), re-reading its state.json once held; a run whose Codex round is in flight holds its
lock throughout, and `match` (or `run`) skips a busy run and says so. A voided run's replacement is made by the next `run`.
"""
import concurrent.futures as cf
import contextlib
import fcntl
import glob
import json
import os
import random
import re
import shutil
import tempfile

from . import codex as K
from . import codexhome
from . import common as C
from . import final as F
from . import scratch
from .common import Failed, L, XR, jload, jsave, say

ROUNDS = 6                # Codex rounds at most (spec 4.4)
TURNS = 3                 # Codex turns in flight across all runs (spec 8)
HOME = "nomem"
FILE_CAP, FILES_CAP = 60000, 150000
COMMIT = "Address review findings"
KEYS = ("severity", "file", "line", "summary", "failure_scenario")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", re.M)


class RepairFailed(Failed):
    pass


# ------------------------------------------------------------------ the records
class Ctx(object):
    """What a command reads once: the cases, their branches and injected records, and the inventories."""

    def __init__(self, a):
        self.a = a
        doc = jload(os.path.join(a.state, "cases.json"))
        if not isinstance(doc, dict) or not isinstance(doc.get("cases"), list):
            raise Failed("no cases.json in {}: run inject first".format(a.state))
        self.cases = dict((c["id"], c) for c in doc["cases"] if isinstance(c, dict) and isinstance(c.get("id"), str))
        branches = jload(os.path.join(a.state, "branches.json")) or {}
        self.branches = dict((b["id"], b) for b in branches.get("branches") or [] if isinstance(b, dict) and isinstance(b.get("id"), str))
        self._inj, self._inv = {}, {}
        self.failed = set()            # runs whose round failed in this command: retried by the next one

    def branch(self, case):
        try:
            return self.branches[case["branch"]]
        except KeyError:
            raise Failed("case {}: branch {} is not in branches.json".format(case["id"], case["branch"]))

    def injected(self, case):
        if case["id"] not in self._inj:
            doc = jload(os.path.join(self.a.state, "injected", case["branch"] + ".json"))
            if not isinstance(doc, dict) or not isinstance(doc.get("defects"), dict):
                raise Failed("case {}: no injected/{}.json".format(case["id"], case["branch"]))
            self._inj[case["id"]] = doc
        return self._inj[case["id"]]

    def inventory(self, case):
        """{defect id: defect} of the case's branch."""
        if case["id"] not in self._inv:
            doc = jload(os.path.join(self.a.state, "inventory", case["branch"] + ".json")) or {}
            self._inv[case["id"]] = dict((d["id"], d) for d in doc.get("defects") or [] if isinstance(d, dict) and "id" in d)
        return self._inv[case["id"]]

    def path(self, run):
        return os.path.join(self.a.state, "runs", run["case"], run["label"], "state.json")

    def save(self, run):
        """Write the run's state, unless the file holds it already."""
        path = self.path(run)
        text = json.dumps(run, indent=2)
        try:
            with open(path, encoding="utf-8") as f:
                if f.read() == text:
                    return
        except OSError:
            pass
        jsave(path, text)

    def acquire(self, run):
        """The lock of `run` (its fd), with the run re-read from disk, or None when another command holds it."""
        fd = _lock(os.path.join(self.a.state, "runs", run["case"], run["label"], "lock"))
        if fd is not None:
            fresh = jload(self.path(run))
            if isinstance(fresh, dict):
                run.clear()
                run.update(fresh)
        return fd

    @contextlib.contextmanager
    def locked(self, run):
        fd = self.acquire(run)
        try:
            yield fd is not None
        finally:
            _unlock(fd)


def _lock(path):
    """An exclusive, non-blocking flock on `path` (made if need be): its fd, or None when it is held."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def _unlock(fd):
    if fd is not None:
        try:
            os.close(fd)                    # closing the descriptor releases the flock
        except OSError:
            pass


def runs_of(a):
    out = []
    for path in sorted(glob.glob(os.path.join(glob.escape(a.state), "runs", "*", "*", "state.json"))):
        run = jload(path)
        if isinstance(run, dict) and isinstance(run.get("label"), str) and isinstance(run.get("case"), str):
            out.append(run)
    return out


def scratch_root():
    return os.path.join(L.state_home(), "review-work", "scratch")


def _taken(a):
    taken = set()
    for run in runs_of(a):
        taken.add(run["label"])
        if run.get("replaced_by"):
            taken.add(run["replaced_by"])
    try:
        taken |= set(os.listdir(scratch_root()))
    except OSError:
        pass
    return taken


def _present(run):
    return sorted(d for d, s in run["defects"].items() if s == "present")


def _put(state, kind, jid, doc):
    """A judge's input, written unless it holds this already (the inputs are deterministic)."""
    path = os.path.join(state, kind, jid + ".json")
    if jload(path) != doc:
        C.judge_write(state, kind, jid, doc)


def _ident(f):
    return K.identifier(f) if f.get("file") else " ".join(str(f.get("summary") or "").split())[:K.IDENTIFIER_SUMMARY]


def _norm_finding(f):
    return dict(f, file=C.norm(f.get("file")))


# ------------------------------------------------------------------ making a run
def _home(a):
    home = codexhome.home_path(HOME)
    if not os.path.isfile(os.path.join(home, codexhome.RECORD)):
        raise Failed("there is no replay Codex home {}: make it with `process-replay.py home --name {} --start --probe`".format(home, HOME))
    if not codexhome.alive(home):
        raise Failed("the daemon of the replay home {} is not running: `process-replay.py home --name {} --start --probe`".format(home, HOME))
    good, why = codexhome.probed(home)
    if not good:
        raise Failed("the replay home {} has not passed its probe: {}; `process-replay.py home --name {} --probe`".format(home, why, HOME))
    return home


def _keep_repair(state, cid, label, did, path):
    """The run's own copy of a repair, runs/<case>/<label>/repairs/<defect>.patch, whose path the run keeps: `inject` rewrites and deletes
    repairs/<defect>.patch whenever it settles a branch again, and a run must apply the repair it started with."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise Failed("the repair of {} cannot be read: {}".format(did, e))
    mine = os.path.join(state, "runs", cid, label, "repairs", did + ".patch")
    os.makedirs(os.path.dirname(mine), exist_ok=True)
    with open(mine, "wb") as f:
        f.write(data)
    return mine


def start_run(ctx, case, label, voids=0, replaces=None):
    """A fresh run of `case` under `label`: its scratch repository (the work commit's tree on the branch's base history), its
    ledger, and its state. Called with no Codex round in flight: the ledger reads the original Codex home."""
    a = ctx.a
    branch, inj = ctx.branch(case), ctx.injected(case)
    work, commit = inj["work"], inj["work_commit"]
    out = os.path.join(scratch_root(), label)
    objects = branch.get("objects") or os.path.join(branch["repo"], "objects")
    repairs = {}
    for did in case["defects"]:
        rec = (inj["defects"].get(did) or {})
        if not rec.get("repair"):
            raise Failed("case {}: defect {} has no repair in injected/{}.json".format(case["id"], did, case["branch"]))
        repairs[did] = {"repair": _keep_repair(a.state, case["id"], label, did, rec["repair"]), "group": rec.get("group") or did,
                        "hunks": rec.get("hunks") or []}
    jsave(os.path.join(a.state, "runs", case["id"], label, "scratch.json"), {"scratch": out})      # before the build: cleanup removes what a failure leaves
    tmp = tempfile.mkdtemp(prefix="loop-files.")
    try:
        files = os.path.join(tmp, "files")
        scratch.export(os.path.join(work, ".git", "objects"), commit, files)
        tip = scratch.build(objects, branch["base"], files, out, branch["dest"], branch["branch"], branch.get("dest_ref"),
                            expect_tree=C.git(work, "rev-parse", commit + "^{tree}"), cache=os.path.join(a.state, "packs"))
    except BaseException:
        shutil.rmtree(out, ignore_errors=True)
        raise
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    run = {"case": case["id"], "label": label, "scratch": out, "thread": None, "round": 0, "step": "final", "reviews": [],
           "defects": dict((d, "present") for d in case["defects"]), "rejected": [], "addressed": [], "outside": [], "ledger": None,
           "end": None, "voids": voids, "tokens": 0, "base_tip": tip, "repairs": repairs, "judging": None, "failures": 0}
    if replaces:
        run["replaces"] = replaces
    try:
        K.prepare_ledger(a, run, case, branch)
    except BaseException:
        shutil.rmtree(out, ignore_errors=True)
        raise
    ctx.save(run)
    return run


def ensure_runs(ctx, runs):
    """Every case has its runs, and every voided run its replacement. The runs made, appended to `runs`."""
    a = ctx.a
    made = False
    for cid, case in sorted(ctx.cases.items()):
        if not case.get("defects"):
            continue
        mine = [r for r in runs if r["case"] == cid]
        have = set(r["label"] for r in mine)
        for r in list(mine):
            if r.get("replaced_by") and r["replaced_by"] not in have:
                runs.append(start_run(ctx, case, r["replaced_by"], voids=r["voids"], replaces=r["label"]))
                have.add(r["replaced_by"])
                made = True
        for _ in range(C.RUNS - len([r for r in mine if not r.get("replaces")])):
            label = C.label(_taken(a) | have)
            have.add(label)
            runs.append(start_run(ctx, case, label))
            made = True
    return made


def add_args_match(ap):
    ap.add_argument("--transcript", action="append", default=[], metavar="ID=PATH",
                    help="the transcript of final review ID, when the search finds none or several")


# ------------------------------------------------------------------ the judges
def _defect(ctx, run, did):
    return ctx.inventory(ctx.cases[run["case"]])[did]


def _open_match(ctx, run, review, report=None):
    """The judge-match of `review`: the defects still present (shuffled for this review, fresh indices, no class) and its
    findings, or its report. The run then waits at match."""
    n = len(run["reviews"]) - 1
    ids = _present(run)
    random.Random("{}:{}".format(run["label"], n)).shuffle(ids)
    defects = []
    for i, did in enumerate(ids):
        d = _defect(ctx, run, did)
        defects.append({"index": i, "summary": d.get("summary"), "file": C.norm(d.get("file")), "line": d.get("line"),
                        "failure_scenario": d.get("failure_scenario")})
    doc = {"defects": defects}
    if report is not None:
        doc["report"] = C.cap(report, XR.MAX_INTERDIFF)
    else:
        doc["findings"] = [dict((k, v) for k, v in dict(_norm_finding(f), index=i).items() if k in KEYS + ("index",)) for i, f in enumerate(review["findings"])]
    jid = "{}-{}".format(run["label"], n)
    _put(ctx.a.state, "judge-match", jid, doc)
    run["judging"] = {"kind": "match", "id": jid, "order": ids, "review": n}
    run["step"] = "match"


def _files(run, did, ctx):
    d = _defect(ctx, run, did)
    names = []
    for n in [C.norm(d.get("file"))] + list(d.get("files") or []):
        if n and n not in names:
            names.append(n)
    out, room = [], FILES_CAP
    for n in names:
        if room <= 0:
            break
        try:
            data = C.git(run["scratch"], "show", "HEAD:" + n, raw=True)
        except Failed:
            continue
        text = C.cap(data.decode("utf-8", "replace"), min(FILE_CAP, room))
        room -= len(text)
        out.append({"path": n, "text": text})
    return out


def _open_valid(ctx, run, ids):
    n = len(run["reviews"]) - 1
    asked = {}
    for did in ids:
        d = _defect(ctx, run, did)
        jid = "{}-{}-{}".format(run["label"], n, did)
        _put(ctx.a.state, "judge-present", jid, {"finding": dict((k, d.get(k)) for k in KEYS), "files": _files(run, did, ctx)})
        asked[did] = jid
    run["judging"] = {"kind": "valid", "ids": asked}
    run["step"] = "valid"


# ------------------------------------------------------------------ the oracle fixer
def _reset(sd):
    """Put the scratch tree back to HEAD. "" when it is, else a note that it could not be, to append to the error being raised, so the
    failure that made the reset necessary is never replaced by the reset's own."""
    try:
        C.git(sd, *(scratch.NEUTRAL + ["reset", "-q", "--hard", "HEAD"]))
    except Failed as e:
        return "; the tree could not be put back either: {}".format(e)
    return ""


def oracle(run, ids):
    """Re-apply the repairs of `ids` (each group's patch once) one after another, `git apply --index` and, when a patch's context
    changed under an earlier one, `--3way` (the injected blobs are in the scratch), then commit once, `Address review findings`;
    the commit's sha. Raises RepairFailed when one is empty, does not apply or cannot be committed, after putting the tree back to HEAD;
    when that reset fails too, the message says so (the tree is then as the failure left it)."""
    sd = run["scratch"]
    texts, seen = [], set()
    for did in sorted(ids):
        rec = run["repairs"][did]
        if rec["group"] in seen:
            continue
        seen.add(rec["group"])
        with open(rec["repair"], "rb") as f:
            texts.append((did, f.read()))
    for did, data in texts:
        if not data.strip():
            raise RepairFailed("the repair of {} is empty{}".format(did, _reset(sd)))
        for extra in ([], ["--3way"]):
            if C.git_run(sd, scratch.NEUTRAL + ["apply", "--index", "--whitespace=nowarn"] + extra + ["-"], input=data).returncode == 0:
                break
        else:
            raise RepairFailed("the repair of {} does not apply to the tree{}".format(did, _reset(sd)))
    g = lambda *args, **kw: C.git(sd, *(scratch.NEUTRAL + list(args)), **kw)
    stamp = "{} +0000".format(int(g("log", "-1", "--format=%ct", "HEAD")) + scratch.HOUR)
    try:
        g("commit", "-q", "--no-verify", "-m", COMMIT, env=dict(scratch.IDENTITY, GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp))
    except Failed as e:
        raise RepairFailed("the repair of {} was applied but not committed: {}{}".format(", ".join(sorted(ids)), e, _reset(sd)))
    return g("rev-parse", "HEAD")


def _hunks(sd, a, b, path):
    """[(old start, old length, new length)] of the zero-context diff a..b of `path`."""
    text = C.git(sd, *(L.DIFF_PATCH + ["-U0", "--text", a, b, "--", path]), raw=True).decode("utf-8", "replace")
    return [(int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1), int(m.group(4) if m.group(4) is not None else 1)) for m in HUNK.finditer(text)]


def _shift(hunks, start, end):
    """The lines start..end of the old file as the new file has them: what changed above moves them, what changed inside widens them."""
    before = inside = 0
    for old, ol, nl in hunks:
        if ol and old + ol - 1 < start or not ol and old < start - 1:
            before += nl - ol
        elif ol and old <= end or not ol and old <= end:
            inside += nl - ol
    return start + before, max(end + before + inside, start + before)


def _meets(hunk, start, end):
    old, ol, _nl = hunk
    if ol:
        return old <= end and old + ol - 1 >= start
    return start - 1 <= old <= end          # a pure insertion after line `old`


def _applies(sd, patch_path):
    with open(patch_path, "rb") as f:
        data = f.read()
    return C.git_run(sd, scratch.NEUTRAL + ["apply", "--check", "--whitespace=nowarn", "-"], input=data).returncode == 0


def touched(run, sha):
    """The defects still present whose hunk lines commit `sha` changed (their lines followed through the commits since the run
    began), or whose repair no longer applies to the tree at `sha`."""
    sd = run["scratch"]
    parent = C.git(sd, "rev-parse", sha + "^")
    out = []
    for did in _present(run):
        rec = run["repairs"][did]
        hit = False
        for h in rec["hunks"]:
            above = _hunks(sd, run["base_tip"], parent, h["file"]) if run["base_tip"] != parent else []
            start, end = _shift(above, h["start"], h["end"])
            if any(_meets(x, start, end) for x in _hunks(sd, parent, sha, h["file"])):
                hit = True
        if hit or not _applies(sd, rec["repair"]):
            out.append(did)
    return out


# ------------------------------------------------------------------ the steps
def _end(run, end, left):
    for did, s in run["defects"].items():
        if s == "present":
            run["defects"][did] = left
    run["end"], run["step"], run["judging"] = end, "done", None


def _void(ctx, run, leaks):
    run["leak"] = sorted(set((run.get("leak") or []) + [str(x) for x in leaks]))
    run["end"], run["step"], run["judging"] = "void", "done", None
    if run["voids"] == 0:
        run["replaced_by"] = C.label(_taken(ctx.a))
    run["voids"] += 1


def _error(run, why):
    run["end"], run["step"], run["judging"], run["error"] = "error", "done", None, why


def _final(ctx, run):
    a = ctx.a
    branch = ctx.branch(ctx.cases[run["case"]])
    jid = run["label"]
    if not os.path.isfile(os.path.join(a.state, "final", jid, "brief.md")):
        try:
            F.write_brief(a, run, branch)
        except F.PlanError as e:
            _error(run, "no final review brief: {}".format(e))
            say("{}: {}".format(jid, run["error"]))
        return True
    report = F.answer(a, jid)
    if report is None:
        return False
    found, note = F.lookup(a, jid)
    if note:
        say(note)
        return False
    leaks = F.leaks(a, run, branch, found[0])
    if leaks:
        _void(ctx, run, leaks)
        say("final review {}: its transcript names {}; the run is void".format(jid, ", ".join(leaks)))
        return True
    run["reviews"].append({"id": jid, "kind": "final", "k": 0, "findings": [], "verdict": "report", "tokens": 0, "turns": 0, "model": None, "effort": None})
    run["addressed"] = []
    _open_match(ctx, run, run["reviews"][-1], report=report)
    return True


def _report_findings(answer):
    """The claims of a report-form judge-match answer (C.answer_problem has checked their numbering), in order of their own `index`."""
    return [{"summary": str(f.get("summary"))} for f in sorted(answer["findings"], key=lambda f: f["index"])]


def _rulings(answer):
    """({defect index: finding index}, {finding index: ruling}) of a judge-match answer C.answer_problem has passed: every defect is
    matched to a finding or to null, and every finding no defect claims has its ruling."""
    matches = dict((m["defect"], m["finding"]) for m in answer.get("matches") or [] if m["finding"] is not None)
    rulings = dict((u["finding"], u["ruling"]) for u in answer.get("unmatched") or [])
    return matches, rulings


def _matched(ctx, run):
    """Apply the run's judge-match answer. An incomplete or malformed one is set aside by C.accepted_answer: the judge-match is pending
    again and the run keeps waiting, never moving on to another Codex round on what it did not say."""
    a = ctx.a
    j = run["judging"]
    answer = C.accepted_answer(a.state, "judge-match", j["id"])
    if not isinstance(answer, dict):
        return False
    review = run["reviews"][j["review"]]
    findings = _report_findings(answer) if review["kind"] == "final" else review["findings"]
    matches, rulings = _rulings(answer)
    review["findings"] = findings
    _apply(ctx, run, review, dict((j["order"][i], f) for i, f in matches.items()), rulings)
    return True


def _apply(ctx, run, review, matches, rulings):
    """What a review's matches and rulings do to the run: statuses, the next request's lists, an ending, or the oracle's repair
    (and the revalidation it asks for). `matches` is {defect id: finding index}, `rulings` {finding index: ruling} of the unmatched."""
    findings = [_norm_finding(f) for f in review["findings"]]
    recovered = sorted(matches)
    for did in recovered:
        run["defects"][did] = "recovered"
    used = sorted(set(matches.values()))
    run["addressed"] = list(dict.fromkeys(_ident(findings[i]) for i in used))
    real = [i for i, r in sorted(rulings.items()) if r == "real" and i not in used]
    for i in real:
        if _ident(findings[i]) not in run["outside"]:
            run["outside"].append(_ident(findings[i]))
    codex = review["kind"] == "codex"
    if codex:
        for i, r in sorted(rulings.items()):
            if r == "false_positive" and i not in used and _ident(findings[i]) not in run["rejected"]:
                run["rejected"].append(_ident(findings[i]))
    run["judging"] = None
    if codex and review["verdict"] == "approve":
        return _end(run, "approve", "unrecovered")
    if codex and review["k"] >= ROUNDS:
        return _end(run, "rounds", "unrecovered")
    if not recovered and real:
        return _end(run, "stalled", "censored")
    groups = set(run["repairs"][d]["group"] for d in recovered)
    for did in _present(run):
        if run["repairs"][did]["group"] in groups:
            run["defects"][did] = "censored"
    if not recovered:
        run["step"] = "codex"
        return
    try:
        sha = oracle(run, recovered)
        again = touched(run, sha)
    except Failed as e:
        _error(run, str(e))
        return
    if again:
        _open_valid(ctx, run, again)
    else:
        run["step"] = "codex"


def _validated(ctx, run):
    a = ctx.a
    answers = dict((did, C.accepted_answer(a.state, "judge-present", jid)) for did, jid in run["judging"]["ids"].items())
    if not all(isinstance(x, dict) for x in answers.values()):
        return False
    for did, x in sorted(answers.items()):
        if x.get("answer") != "yes":
            run["defects"][did] = "censored"
    run["judging"], run["step"] = None, "codex"
    return True


def _settle(ctx, run):
    """Everything the run can do without a Codex round or a Claude answer, under its lock; whether it did anything."""
    moved = False
    with ctx.locked(run) as got:
        if not got:
            say("{}: busy (another command holds it); skipped".format(run["label"]))
            return False
        while run["end"] is None:
            step = run["step"]
            if step == "final":
                did = _final(ctx, run)
            elif step == "match":
                did = _matched(ctx, run)
            elif step == "valid":
                did = _validated(ctx, run)
            else:
                break
            if not did:
                break
            moved = True
            ctx.save(run)
    return moved


# ------------------------------------------------------------------ the Codex rounds
def _round(ctx, run, home):
    """One Codex round; whatever it raises is its outcome (so one round's failure cannot discard another's result)."""
    case = ctx.cases[run["case"]]
    try:
        return K.codex_round(ctx.a, run, case, ctx.branch(case), home)
    except Exception as e:
        return e


def _charge(ctx, run, out):
    """Charge the tokens of a round's turns to its run: what the outcome reports, or what the round's completed turns recorded as in flight
    if that is more (an unexpected error carries no count)."""
    got = getattr(out, "tokens", 0) if isinstance(out, Exception) else out.get("tokens")
    run["tokens"] += max(got or 0, K.in_flight(ctx.a, run))


def _took(ctx, run, out):
    """Apply one round's outcome to its run (the main thread, one at a time). Whether the run moved."""
    if isinstance(out, Exception):
        _charge(ctx, run, out)
        leak = getattr(out, "leak", None)
        if leak:
            _void(ctx, run, leak)
            say("{}: a round named the original checkout ({}); the run is void".format(run["label"], ", ".join(leak)))
            return True
        run["failures"] = run.get("failures", 0) + 1
        ctx.failed.add(run["label"])
        say("{}: the round failed ({}/2): {}".format(run["label"], run["failures"], out))
        if run["failures"] >= 2:
            _error(run, str(out))
        return True
    if out.get("paused"):
        _charge(ctx, run, out)       # the turns of a round cut short were spent
        say("{}: paused: {}".format(run["label"], out["paused"]))
        return False
    if out.get("stopped"):
        _charge(ctx, run, out)
        say("{}: stopped: {}".format(run["label"], out["stopped"]))
        return False
    if out.get("leak"):
        _charge(ctx, run, out)
        _void(ctx, run, out["leak"])
        say("{}: a round named the original checkout ({}); the run is void".format(run["label"], ", ".join(out["leak"])))
        return True
    review = dict((k, v) for k, v in out.items() if k not in ("decision", "thread"))
    review["id"] = "{}-{}".format(run["label"], len(run["reviews"]))
    run["reviews"].append(review)
    run["thread"], run["round"], run["failures"] = out["thread"], out["k"], 0
    _charge(ctx, run, out)
    if review["findings"]:
        _open_match(ctx, run, review)
    else:
        _apply(ctx, run, review, {}, {})
    return True


def _rounds(ctx, runs, home):
    """One Codex round for each run at the Codex step that no other command holds, at most TURNS at once. Each run's lock is
    held until its outcome is applied and saved; every outcome is applied before the first error, if any, is raised."""
    batch = []
    for r in runs:
        if r["end"] is not None or r["step"] != "codex" or r["label"] in ctx.failed:
            continue
        fd = ctx.acquire(r)
        if fd is None:
            say("{}: busy (another command holds it); its round waits".format(r["label"]))
        elif r["end"] is not None or r["step"] != "codex":
            _unlock(fd)
        else:
            batch.append((r, fd))
    moved, error = False, None
    held = set(fd for _r, fd in batch)
    try:
        with cf.ThreadPoolExecutor(TURNS) as pool:
            futures = dict((pool.submit(_round, ctx, r, home), (r, fd)) for r, fd in batch)
            for f in cf.as_completed(futures):
                run, fd = futures[f]
                try:
                    out = f.result()
                except Exception as e:
                    out = e
                try:
                    with K.settling(ctx.a, run):         # charged and saved in one step the other rounds' token checks cannot see half of
                        moved |= _took(ctx, run, out)
                        ctx.save(run)
                except Exception as e:
                    error = error or e
                finally:
                    _unlock(fd)
                    held.discard(fd)
    finally:
        for fd in held:                 # only what no outcome released (an interrupt): a descriptor closed twice may be another's
            _unlock(fd)
    if error is not None:
        raise error
    return moved


# ------------------------------------------------------------------ the commands
def _summary(runs):
    for r in runs:
        what = "ended {}".format(r["end"]) if r["end"] else "waits at {}".format(r["step"])
        say("{} {}: {}; defects {}".format(r["case"], r["label"], what, ", ".join("{} {}".format(d, s) for d, s in sorted(r["defects"].items()))))


def _drive(a, rounds):
    ctx = Ctx(a)
    if a.dry_run:
        runs = runs_of(a)
        for cid, case in sorted(ctx.cases.items()):
            mine = [r for r in runs if r["case"] == cid and not r.get("replaces")]
            if len(mine) < C.RUNS:
                say("would start {} run(s) of case {}".format(C.RUNS - len(mine), cid))
        _summary(runs)
        return 0
    with contextlib.ExitStack() as held:
        home = None
        while True:
            runs = runs_of(a)
            moved = ensure_runs(ctx, runs) if rounds else False
            for run in runs:
                moved |= _settle(ctx, run)
            if rounds and any(r["end"] is None and r["step"] == "codex" and r["label"] not in ctx.failed for r in runs):
                if home is None:
                    home = _home(a)
                    held.enter_context(codexhome.hold(home))        # until this run ends: the daemon is not one left behind to reclaim
                moved |= _rounds(ctx, runs, home)
            if not moved:
                break
        runs = runs_of(a)
        _summary(runs)
        waits = C.pending(a.state)
        if waits:
            say("{} item(s) wait for an agent: run `process-replay.py pending`, then `{}` again".format(len(waits), getattr(a, "command", "run")))
    return 0


@C.locked(lambda a: None if a.dry_run else "run", daemon=lambda a: not a.dry_run)
def cmd_run(a):
    return _drive(a, True)


@C.locked(lambda a: None if a.dry_run else "shared")
def cmd_match(a):
    return _drive(a, False)


@C.locked(lambda a: None if a.dry_run else "exclusive", daemon=lambda a: not a.dry_run)
def cmd_cleanup(a):
    """Stop the replay home's daemon and archive the threads the runs used; remove scratch/, work/, views/, packs/ (a cache), each
    recreate/<defect>/tree (a working copy of the final tree) once recreated/<defect>.patch holds what it made (before that, `inject`
    still needs it), the run scratches under review-work/scratch and this state's staged
    items under review-work/items. Every JSON file, brief, patch and `done` marker stays. It holds run.lock exclusively and the replay
    daemons' lock, so it refuses while any other command uses the state (a `run`, `match` or `pending`) or any process uses the daemon.
    Threads are archived on the daemon as it is: run cleanup before `home --stop`, or archiving fails (exit 1) though everything else
    is removed."""
    runs = runs_of(a)
    gone = [os.path.join(a.state, d) for d in ("scratch", "work", "views", "packs")]
    gone += [t for t in sorted(glob.glob(os.path.join(glob.escape(a.state), "recreate", "*", "tree")))
             if os.path.isfile(os.path.join(a.state, "recreated", os.path.basename(os.path.dirname(t)) + ".patch"))]
    recorded = [r.get("scratch") for r in runs]
    for path in glob.glob(os.path.join(glob.escape(a.state), "runs", "*", "*", "scratch.json")):
        recorded.append((jload(path) or {}).get("scratch"))
    gone += [p for p in dict.fromkeys(recorded) if isinstance(p, str) and os.path.dirname(os.path.abspath(p)) == os.path.abspath(scratch_root())]
    items = jload(os.path.join(a.state, "items.json"))
    gone += [os.path.join(C.items_root(), n) for n in (items.values() if isinstance(items, dict) else []) if isinstance(n, str) and n and "/" not in n]
    home = codexhome.home_path(HOME)
    if a.dry_run:
        say("would archive the threads of {} and stop its daemon".format(home))
        for p in gone:
            if os.path.exists(p):
                say("would remove " + p)
        return 0
    ok = True
    if os.path.isfile(os.path.join(home, codexhome.RECORD)):
        with K.homed(home):
            ok = XR.Threads(a.state).cleanup()
        try:
            codexhome.stop(home)
        except Failed as e:
            say("could not stop the daemon of {}: {}".format(home, e))
            ok = False
    for p in gone:
        if os.path.exists(p):
            shutil.rmtree(p, ignore_errors=True)
            say("removed " + p)
    return 0 if ok else 1
