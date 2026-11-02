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
({defect: {repair: patch path, group, hunks}}, from injected/<branch>.json when the run was made), judging (what the run
waits for), failures (consecutive failed rounds), leak, error, and for a voided run replaced_by (its replacement's label)
or, for the replacement, replaces. A voided run keeps end "void" and voids 1; its replacement starts at voids 1 and ends
"void" with voids 2 if it leaks as well.

The final review's id is the run's label: final/<label>/, and `Review id: <label>` in the brief. The driving session dispatches
the reviewer with the brief's text as its prompt (so the id line is in the subagent's first prompt, where the leak scan finds
its transcript under --projects-dir) and writes the reply to final/<label>/answer.md.
"""
import concurrent.futures as cf
import glob
import json
import os
import random
import re
import shutil
import subprocess
import tempfile

from . import codex as K
from . import codexhome
from . import common as C
from . import scratch
from .common import Failed, L, XR, jload, jsave, say

RUNS = 2                  # runs per case (spec 4.4)
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
        self._inj, self._inv, self._saved = {}, {}, {}
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

    def save(self, run):
        """Write the run's state, unless it is what the file holds already."""
        path = os.path.join(self.a.state, "runs", run["case"], run["label"], "state.json")
        text = json.dumps(run, indent=2)
        if self._saved.get(path) == text:
            return
        try:
            with open(path, encoding="utf-8") as f:
                same = f.read() == text
        except OSError:
            same = False
        if not same:
            jsave(path, text)
        self._saved[path] = text


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
        raise Failed("the daemon of the replay home {} is not running: `process-replay.py home --name {} --start`".format(home, HOME))
    return home


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
        repairs[did] = {"repair": rec["repair"], "group": rec.get("group") or did, "hunks": rec.get("hunks") or []}
    tmp = tempfile.mkdtemp(prefix="loop-files.")
    try:
        files = os.path.join(tmp, "files")
        scratch.export(os.path.join(work, ".git", "objects"), commit, files)
        tip = scratch.build(objects, branch["base"], files, out, branch["dest"], branch["branch"], branch.get("dest_ref"),
                            expect_tree=C.git(work, "rev-parse", commit + "^{tree}"), cache=os.path.join(a.state, "packs"))
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
        for _ in range(RUNS - len([r for r in mine if not r.get("replaces")])):
            label = C.label(_taken(a) | have)
            have.add(label)
            runs.append(start_run(ctx, case, label))
            made = True
    return made


# ------------------------------------------------------------------ the final review
def _version(path):
    return [int(x) for x in re.findall(r"\d+", re.search(r"/superpowers/([^/]+)/skills/", path).group(1))]


def superpowers_root():
    """The superpowers version directory: PROCESS_REPLAY_SUPERPOWERS (tests), else the newest under ~/.claude/plugins/cache."""
    env = os.environ.get("PROCESS_REPLAY_SUPERPOWERS")
    if env:
        return env
    found = glob.glob(os.path.join(glob.escape(os.path.expanduser("~/.claude/plugins/cache")), "*", "superpowers", "*", "skills",
                                   "requesting-code-review", "code-reviewer.md"))
    if not found:
        raise Failed("no superpowers skills under ~/.claude/plugins/cache (set PROCESS_REPLAY_SUPERPOWERS)")
    return max(found, key=_version).split("/skills/")[0]


def _prompt(template):
    """The prompt of code-reviewer.md: the fenced block's `prompt: |` body, dedented. The whole file if it has none."""
    lines = template.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"\s*prompt:\s*\|\s*\Z", line):
            body = []
            for x in lines[i + 1:]:
                if x == "```":
                    break
                body.append(x[4:] if x.startswith("    ") else x)
            return "\n".join(body).strip("\n") + "\n"
    return template


def _plan(scratch_dir):
    names = [n for n in C.git(scratch_dir, "ls-files", "docs/superpowers/plans").splitlines() if n.endswith(".md")]
    if not names:
        raise Failed("the scratch repository {} holds no plan under docs/superpowers/plans".format(scratch_dir))
    return os.path.join(scratch_dir, sorted(names)[-1])


def final_brief(a, run, branch):
    """final/<label>/brief.md: code-reviewer.md's prompt for the scratch's range, the review package and the id."""
    root = superpowers_root()
    sd = run["scratch"]
    with open(os.path.join(root, "skills", "requesting-code-review", "code-reviewer.md"), encoding="utf-8") as f:
        text = _prompt(f.read())
    tip = C.git(sd, "rev-parse", "HEAD")
    plan = _plan(sd)
    package = os.path.join(a.state, "final", run["label"], "package.diff")
    os.makedirs(os.path.dirname(package), exist_ok=True)
    p = subprocess.run(["bash", os.path.join(root, "skills", "subagent-driven-development", "scripts", "review-package"), plan, branch["base"], tip, package],
                       cwd=sd, capture_output=True, env=C.git_env())
    if p.returncode != 0:
        raise Failed("review-package failed ({}): {}".format(p.returncode, p.stderr.decode("utf-8", "replace").strip()))
    for key, value in (("[DESCRIPTION]", "The change on {}.".format(branch["branch"])), ("[PLAN_OR_REQUIREMENTS]", plan),
                       ("[BASE_SHA]", branch["base"]), ("[HEAD_SHA]", tip)):
        text = text.replace(key, value)
    text += "\nReview package (read it first): {}\nRepository: {}\nReview id: {}\n".format(C.aliased(a.state, package), sd, run["label"])
    jsave(os.path.join(a.state, "final", run["label"], "brief.md"), text)


def _key():
    return re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(os.path.expanduser("~/Code/.replay")))


def _first_prompt(path):
    """The text of the first user message of a Claude transcript."""
    try:
        with open(path, "rb") as f:
            for line in f:
                if b'"user"' not in line:
                    continue
                try:
                    rec = json.loads(line.decode("utf-8"))
                except ValueError:
                    continue
                if rec.get("type") != "user":
                    continue
                content = (rec.get("message") or {}).get("content")
                if isinstance(content, list):
                    content = "\n".join(x.get("text", "") for x in content if isinstance(x, dict))
                return content if isinstance(content, str) else ""
    except OSError:
        pass
    return ""


def transcripts(a, jid):
    """The transcripts, under the projects of ~/Code/.replay, whose first prompt carries the line `Review id: <jid>` or the aliased
    path of final/<jid>/brief.md (a driver hands a reviewer its brief by path)."""
    key, found = _key(), []
    try:
        names = sorted(os.listdir(a.projects_dir))
    except OSError:
        return found
    line = re.compile(r"^Review id: " + re.escape(jid) + r"\s*$", re.M)
    brief = C.aliased(a.state, os.path.join(a.state, "final", jid, "brief.md"))
    for name in names:
        if name != key and not name.startswith(key + "-"):
            continue
        root = os.path.join(a.projects_dir, name)
        for path in sorted(glob.glob(os.path.join(glob.escape(root), "**", "*.jsonl"), recursive=True)):
            first = _first_prompt(path)
            if line.search(first) or brief in first:
                found.append(path)
    return found


def add_args_match(ap):
    ap.add_argument("--transcript", action="append", default=[], metavar="ID=PATH",
                    help="the transcript of final review ID, when the search finds none or several")


def overrides(a):
    """{review id: transcript path} of --transcript ID=PATH."""
    out = {}
    for item in getattr(a, "transcript", None) or []:
        jid, sep, path = item.partition("=")
        if not (sep and jid and path):
            raise Failed("--transcript wants ID=PATH, not {!r}".format(item))
        out[jid] = os.path.abspath(os.path.expanduser(path))
    return out


def transcript_leaks(path, forbidden, cwd):
    """The original checkouts a transcript's tool calls name (Bash commands, Read/Grep/Glob paths), by codex.py's matcher."""
    found = set()
    with open(path, "rb") as f:
        for line in f:
            if b"tool_use" not in line:
                continue
            try:
                rec = json.loads(line.decode("utf-8"))
            except ValueError:
                continue
            content = (rec.get("message") or {}).get("content") if isinstance(rec, dict) else None
            for item in content if isinstance(content, list) else []:
                if not (isinstance(item, dict) and item.get("type") == "tool_use" and isinstance(item.get("input"), dict)):
                    continue
                inp = item["input"]
                parts = [inp[k] for k in ("command", "file_path", "path", "notebook_path") if isinstance(inp.get(k), str)]
                if item.get("name") == "Glob" and isinstance(inp.get("pattern"), str):
                    parts.append(inp["pattern"])
                commands = [inp["command"]] if isinstance(inp.get("command"), str) else []
                for name in K.named("\n".join(parts), rec.get("cwd") or cwd, forbidden, commands):
                    found.add(name)
    return sorted(found)


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
def oracle(run, ids):
    """Re-apply the repairs of `ids` (each group's patch once) as one commit, `Address review findings`; its sha.
    Raises RepairFailed, leaving the tree as it was, when they do not apply."""
    texts, seen = [], set()
    for did in sorted(ids):
        rec = run["repairs"][did]
        if rec["group"] in seen:
            continue
        seen.add(rec["group"])
        with open(rec["repair"], "rb") as f:
            texts.append(f.read().decode("utf-8", "surrogateescape"))
    sha = scratch.commit_patch(run["scratch"], "".join(t if t.endswith("\n") else t + "\n" for t in texts), COMMIT)
    if sha is None:
        raise RepairFailed("the repair of {} does not apply to the tree".format(", ".join(sorted(ids))))
    return sha


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


def _final(ctx, run):
    a = ctx.a
    branch = ctx.branch(ctx.cases[run["case"]])
    jid = run["label"]
    brief = os.path.join(a.state, "final", jid, "brief.md")
    answer = os.path.join(a.state, "final", jid, "answer.md")
    if not os.path.isfile(brief):
        final_brief(a, run, branch)
        return True
    if not os.path.isfile(answer):
        return False
    given = overrides(a).get(jid)
    found = [given] if given else transcripts(a, jid)
    if given and not os.path.isfile(given):
        say("final review {}: --transcript names {}, which is not a file".format(jid, given))
        return False
    if not found:
        say("final review {}: its answer is in, but no transcript with `Review id: {}` or its brief path was found under {}; point at it "
            "with `match --transcript {}=<path>`; it is not accepted until then".format(jid, jid, a.projects_dir, jid))
        return False
    if len(found) > 1:
        say("final review {}: {} transcripts match ({}); none is picked: name the right one with `match --transcript {}=<path>`".format(
            jid, len(found), ", ".join(found), jid))
        return False
    forbidden = K.forbidden_paths(K.orig_paths(branch))
    leaks = sorted(set(x for path in found for x in transcript_leaks(path, forbidden, run["scratch"])))
    if leaks:
        _void(ctx, run, leaks)
        say("final review {}: its transcript names the original checkout ({}); the run is void".format(jid, ", ".join(leaks)))
        return True
    with open(answer, encoding="utf-8", errors="replace") as f:
        report = f.read()
    run["reviews"].append({"id": jid, "kind": "final", "k": 0, "findings": [], "verdict": "report", "tokens": 0, "turns": 0, "model": None, "effort": None})
    run["addressed"] = []
    _open_match(ctx, run, run["reviews"][-1], report=report)
    return True


def _rulings(answer, count):
    """({defect index: finding index}, {finding index: ruling}) of a judge-match answer; Failed when it does not fit the input."""
    matches, rulings = {}, {}
    for m in answer.get("matches") or []:
        if not isinstance(m, dict) or not isinstance(m.get("defect"), int) or isinstance(m.get("defect"), bool):
            raise Failed("a match has no defect index: {!r}".format(m))
        f = m.get("finding")
        if f is None:
            continue
        if not isinstance(f, int) or isinstance(f, bool) or not 0 <= f < count:
            raise Failed("a match names finding {!r}, and there are {} finding(s)".format(f, count))
        matches[m["defect"]] = f
    for u in answer.get("unmatched") or []:
        if isinstance(u, dict) and isinstance(u.get("finding"), int) and 0 <= u["finding"] < count and u.get("ruling") in ("real", "false_positive"):
            rulings[u["finding"]] = u["ruling"]
    return matches, rulings


def _matched(ctx, run):
    a = ctx.a
    j = run["judging"]
    answer = C.judge_answer(a.state, "judge-match", j["id"])
    if not isinstance(answer, dict):
        return False
    review = run["reviews"][j["review"]]
    if review["kind"] == "final":
        review["findings"] = [{"summary": str(f.get("summary"))} for f in answer.get("findings") or [] if isinstance(f, dict)]
    count = len(review["findings"])
    matches, rulings = _rulings(answer, count)
    for index in matches:
        if not 0 <= index < len(j["order"]):
            raise Failed("{}: a match names defect {}, and the input has {}".format(j["id"], index, len(j["order"])))
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
    real = [i for i, r in sorted(rulings.items()) if r == "real"]
    for i in real:
        if _ident(findings[i]) not in run["outside"]:
            run["outside"].append(_ident(findings[i]))
    codex = review["kind"] == "codex"
    if codex:
        for i, r in sorted(rulings.items()):
            if r == "false_positive" and _ident(findings[i]) not in run["rejected"]:
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
    except RepairFailed as e:
        run["end"], run["step"], run["error"] = "error", "done", str(e)
        return
    again = touched(run, sha)
    if again:
        _open_valid(ctx, run, again)
    else:
        run["step"] = "codex"


def _validated(ctx, run):
    a = ctx.a
    answers = dict((did, C.judge_answer(a.state, "judge-present", jid)) for did, jid in run["judging"]["ids"].items())
    if not all(isinstance(x, dict) for x in answers.values()):
        return False
    for did, x in sorted(answers.items()):
        if x.get("answer") != "yes":
            run["defects"][did] = "censored"
    run["judging"], run["step"] = None, "codex"
    return True


def _settle(ctx, run):
    """Everything the run can do without a Codex round or a Claude answer; whether it did anything."""
    moved = False
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
    case = ctx.cases[run["case"]]
    try:
        return K.codex_round(ctx.a, run, case, ctx.branch(case), home)
    except K.RoundFailed as e:
        return e


def _took(ctx, run, out):
    """Apply one round's outcome to its run (the main thread, one at a time). Whether the run moved."""
    if isinstance(out, K.RoundFailed):
        run["tokens"] += out.tokens or 0
        if out.leak:
            _void(ctx, run, out.leak)
            say("{}: a round named the original checkout ({}); the run is void".format(run["label"], ", ".join(out.leak)))
            return True
        run["failures"] = run.get("failures", 0) + 1
        ctx.failed.add(run["label"])
        say("{}: the round failed ({}/2): {}".format(run["label"], run["failures"], out))
        if run["failures"] >= 2:
            run["end"], run["step"], run["error"] = "error", "done", str(out)
        return True
    if out.get("paused"):
        say("{}: paused: {}".format(run["label"], out["paused"]))
        return False
    if out.get("stopped"):
        say("{}: stopped: {}".format(run["label"], out["stopped"]))
        return False
    if out.get("leak"):
        run["tokens"] += out.get("tokens") or 0
        _void(ctx, run, out["leak"])
        say("{}: a round named the original checkout ({}); the run is void".format(run["label"], ", ".join(out["leak"])))
        return True
    review = dict((k, v) for k, v in out.items() if k not in ("decision", "thread"))
    review["id"] = "{}-{}".format(run["label"], len(run["reviews"]))
    run["reviews"].append(review)
    run["thread"], run["round"], run["failures"] = out["thread"], out["k"], 0
    run["tokens"] += out["tokens"]
    if review["findings"]:
        _open_match(ctx, run, review)
    else:
        _apply(ctx, run, review, {}, {})
    return True


def _rounds(ctx, runs, home):
    ready = [r for r in runs if r["end"] is None and r["step"] == "codex" and r["label"] not in ctx.failed]
    moved = False
    if not ready:
        return moved
    with cf.ThreadPoolExecutor(TURNS) as pool:
        futures = dict((pool.submit(_round, ctx, r, home), r) for r in ready)
        for f in cf.as_completed(futures):
            run = futures[f]
            moved |= _took(ctx, run, f.result())
            ctx.save(run)
    return moved


# ------------------------------------------------------------------ the commands
def _summary(runs):
    for r in runs:
        what = "ended {}".format(r["end"]) if r["end"] else "waits at {}".format(r["step"])
        say("{} {}: {}; defects {}".format(r["case"], r["label"], what, ", ".join("{} {}".format(d, s) for d, s in sorted(r["defects"].items()))))


def _drive(a, rounds):
    ctx = Ctx(a)
    runs = runs_of(a)
    if a.dry_run:
        for cid, case in sorted(ctx.cases.items()):
            mine = [r for r in runs if r["case"] == cid and not r.get("replaces")]
            if len(mine) < RUNS:
                say("would start {} run(s) of case {}".format(RUNS - len(mine), cid))
        _summary(runs)
        return 0
    home = None
    while True:
        moved = ensure_runs(ctx, runs)
        for run in runs:
            moved |= _settle(ctx, run)
        if rounds and any(r["end"] is None and r["step"] == "codex" and r["label"] not in ctx.failed for r in runs):
            if home is None:
                home = _home(a)
            moved |= _rounds(ctx, runs, home)
        if not moved:
            break
    _summary(runs)
    waits = C.pending(a.state)
    if waits:
        say("{} item(s) wait for an agent: run `process-replay.py pending`, then `{}` again".format(len(waits), getattr(a, "command", "run")))
    return 0


def cmd_run(a):
    return _drive(a, True)


def cmd_match(a):
    return _drive(a, False)


def cmd_cleanup(a):
    """Stop the replay home's daemon and archive the threads the runs used; remove scratch/, work/, views/, packs/ (a cache) and the run scratches
    under review-work/scratch. Every JSON file stays."""
    runs = runs_of(a)
    gone = [os.path.join(a.state, d) for d in ("scratch", "work", "views", "packs")]
    gone += [r["scratch"] for r in runs if isinstance(r.get("scratch"), str)
             and os.path.dirname(os.path.abspath(r["scratch"])) == os.path.abspath(scratch_root())]
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
