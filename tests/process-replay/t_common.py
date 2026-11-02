import json
import os
import re
import subprocess
import sys
import shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, git_ok, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402

ROOT = helpers.tmp_root()
KINDS = ("judge-task", "judge-known", "judge-present", "judge-split", "judge-dedup", "judge-same", "judge-match", "judge-class")


def jfile(path, doc):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(doc, f)


def raises(fn, *args):
    try:
        fn(*args)
    except C.Failed:
        return True
    return False


# ---- the shared names come from xreview-replay, loaded once
ok("xr_reused: Failed, L, XP and the file helpers are xreview-replay's, not copies",
   C.Failed is C.XR.Failed and C.L is C.XR.L and C.XP is C.XR.XP and C.jload is C.XR.jload and C.jsave is C.XR.jsave
   and C.say is C.XR.say)
ok("xr_reused: loaded once, under one module name", sys.modules.get("xreview_replay") is C.XR)

# ---- state_default and label
os.environ["XDG_STATE_HOME"] = os.path.join(ROOT, "xdg")
sd = C.state_default()
ok("state_default: $XDG_STATE_HOME/process-replay/<date>", re.fullmatch(re.escape(os.path.join(ROOT, "xdg", "process-replay")) + r"/\d{4}-\d\d-\d\d", sd), sd)
taken = set()
labels = [C.label(taken) for _ in range(300)]
ok("label: 8 hex, unique, recorded in the set", all(re.fullmatch(r"[0-9a-f]{8}", x) for x in labels) and len(set(labels)) == 300
   and taken == set(labels), labels[:3])

# ---- blind_refuses_keys
state = os.path.join(ROOT, "st1")
ok("blind_refuses_keys: a nested class key is refused", raises(C.judge_write, state, "judge-present", "p1", {"x": [{"class": "task"}]}))
for key in ("run", "arm", "label", "purpose", "class"):
    ok("blind_refuses_keys: {} is refused".format(key), raises(C.judge_write, state, "judge-present", "p1", {"a": {"b": [{key: 1}]}}))
ok("blind_refuses_keys: nothing was written", not os.path.exists(os.path.join(state, "judge-present")))
path = C.judge_write(state, "judge-present", "p1", {"finding": {"summary": "s"}, "files": {"a.py": "x\n"}})
is_("blind_refuses_keys: a clean document is written under <state>/<kind>/<id>.json", path, os.path.join(state, "judge-present", "p1.json"))
is_("blind_refuses_keys: with the document as given", C.jload(path), {"finding": {"summary": "s"}, "files": {"a.py": "x\n"}})
ok("blind_refuses_keys: an unknown kind is refused", raises(C.judge_write, state, "judge-other", "p1", {}))
ok("blind_refuses_keys: so is an id that leaves the directory", raises(C.judge_write, state, "judge-present", "../p1", {}))

# ---- pending_lists_unanswered
state = os.path.join(ROOT, "st2")
a = C.judge_write(state, "judge-present", "a1", {"finding": 1})
b = C.judge_write(state, "judge-present", "b2", {"finding": 2})
is_("pending_lists_unanswered: both unanswered", sorted(p[1] for p in C.pending(state)), ["a1", "b2"])
jfile(os.path.join(state, "judge-present", "a1.answer.json"), {"answer": "yes"})
is_("pending_lists_unanswered: an answer takes its input off the list",
    C.pending(state), [("judge-present", "b2", b, os.path.join(state, "judge-present", "b2.answer.json"),
                        C.aliased(state, os.path.join(state, "judge-present", "b2.brief.md")))])
is_("judge_answer: the parsed answer, or None", (C.judge_answer(state, "judge-present", "a1"), C.judge_answer(state, "judge-present", "b2")),
    ({"answer": "yes"}, None))
put(state, "final/f1/brief.md", "review the branch\n")
put(state, "final/f2/brief.md", "done already\n")
put(state, "final/f2/answer.md", "findings\n")
jfile(os.path.join(state, "recreate", "r1.json"), {"finding": "x"})
os.makedirs(os.path.join(state, "recreate", "r1"))
jfile(os.path.join(state, "recreate", "r2.json"), {"finding": "y"})
put(state, "recreate/r2/done", "")
got = C.pending(state)
want = [("judge-present", "b2", b, os.path.join(state, "judge-present", "b2.answer.json"),
         C.aliased(state, os.path.join(state, "judge-present", "b2.brief.md"))),
        ("final", "f1", os.path.join(state, "final", "f1", "brief.md"), os.path.join(state, "final", "f1", "answer.md"),
         C.aliased(state, os.path.join(state, "final", "f1", "brief.md"))),
        ("recreate", "r1", os.path.join(state, "recreate", "r1.json"), os.path.join(state, "recreate", "r1", "done"),
         C.aliased(state, os.path.join(state, "recreate", "r1.json")))]
is_("pending_lists_unanswered: final reviews without answer.md and recreations without done are listed too", got, want)
is_("pending_lists_unanswered: an empty state has nothing", C.pending(os.path.join(ROOT, "nowhere")), [])

# ---- per_input_briefs and briefs_neutral
state = os.path.join(ROOT, "st3")
x = C.judge_write(state, "judge-present", "i-one", {"finding": 1})
y = C.judge_write(state, "judge-present", "i-two", {"finding": 2})
C.write_briefs(state)
kind_brief = open(os.path.join(state, "judges", "judge-present.md")).read()
texts = {}
for kind, jid, inp, ans, brief in C.pending(state):
    is_("per_input_briefs: brief_for returns the path pending() names", C.brief_for(state, kind, jid), brief)
    texts[jid] = open(brief).read()
    ok("per_input_briefs: {} lives beside its input, under the alias".format(jid),
       brief == C.aliased(state, os.path.join(state, "judge-present", jid + ".brief.md")) and os.path.samefile(brief, os.path.join(state, "judge-present", jid + ".brief.md")), brief)
    tail = "Input: {}\nWrite your answer to: {}\n".format(C.aliased(state, inp), C.aliased(state, ans))
    ok("per_input_briefs: {} is the kind's brief, then exactly the two path lines".format(jid),
       texts[jid].startswith(kind_brief) and texts[jid].endswith(tail) and texts[jid][len(kind_brief):-len(tail)].strip() == "", texts[jid][-300:])
ok("per_input_briefs: each names its own input and answer (by alias)", C.aliased(state, x) in texts["i-one"] and C.aliased(state, C.pending(state)[0][3]) in texts["i-one"]
   and C.aliased(state, y) in texts["i-two"] and C.aliased(state, C.pending(state)[1][3]) in texts["i-two"])
ok("per_input_briefs: and not the other's", C.aliased(state, y) not in texts["i-one"] and "i-two" not in texts["i-one"]
   and C.aliased(state, x) not in texts["i-two"] and "i-one" not in texts["i-two"])
ok("per_input_briefs: and never the real state path", state not in texts["i-one"] and state not in texts["i-two"])
ok("per_input_briefs: a brief is not an input", [p[1] for p in C.pending(state)] == ["i-one", "i-two"])
ok("per_input_briefs: a final review is its own brief; nothing is written for it", C.brief_for(os.path.join(ROOT, "st2"), "final", "f1")
   == C.aliased(os.path.join(ROOT, "st2"), os.path.join(ROOT, "st2", "final", "f1", "brief.md")))

forbidden = re.compile(r"replay|inject|removal|per-task|\barm\b|\brun\b", re.I)
missing = [k for k in KINDS if not os.path.isfile(os.path.join(state, "judges", k + ".md"))]
is_("briefs_neutral: every kind has a brief", missing, [])
bad = {}
for k in KINDS:
    text = open(os.path.join(state, "judges", k + ".md")).read()
    if forbidden.search(text) or " arm" in text.lower():
        bad[k] = forbidden.search(text).group(0) if forbidden.search(text) else " arm"
is_("briefs_neutral: none says replay, inject, removal, per-task, arm or run", bad, {})
shape = {"judge-task": "findings", "judge-known": "verdicts", "judge-present": "answer", "judge-split": "hunks",
         "judge-dedup": "groups", "judge-same": "answer", "judge-match": "matches", "judge-class": "class"}
no_shape = [k for k, w in shape.items() if w not in open(os.path.join(state, "judges", k + ".md")).read()]
is_("briefs_neutral: each brief names its answer's shape", no_shape, [])
scale = ["P0 (it cannot work) to P3 (minor)"]
for k in ("judge-task", "judge-known", "judge-match"):
    t = open(os.path.join(state, "judges", k + ".md")).read()
    ok("briefs_neutral: {} gives the severity scale".format(k), scale[0] in t and all("P{}".format(i) in t for i in range(4)), t[:200])
before = open(os.path.join(state, "judges", "judge-task.md")).read()
C.write_briefs(state)
is_("briefs_neutral: writing the briefs again changes nothing", open(os.path.join(state, "judges", "judge-task.md")).read(), before)

# ---- briefs_neutral, on the default state layout: nothing handed to a judge says replay
state = C.state_default()
ok("briefs_neutral: control: the real state path does say replay", "replay" in state, state)
for k in KINDS:
    C.judge_write(state, k, "n-" + k, {"finding": 1})
put(state, "final/nf/brief.md", "review\n")
jfile(os.path.join(state, "recreate", "nr.json"), {"finding": "x"})
C.write_briefs(state)
seen = []
for kind, jid, inp, ans, brief in C.pending(state):
    C.brief_for(state, kind, jid)
    text = open(brief).read()
    seen.append(kind)
    ok("briefs_neutral: {} {} and its path say nothing of replay, inject, removal, per-task, arm or run".format(kind, jid),
       not forbidden.search(text) and "replay" not in brief and "process-replay" not in text, text[-200:])
is_("briefs_neutral: every kind's per-input brief was scanned", sorted(seen), sorted(KINDS + ("final", "recreate")))

# ---- the alias
link = C.alias(state)
al_base = os.path.join(os.environ["XDG_STATE_HOME"], "review-work")
ok("alias: a symlink $XDG_STATE_HOME/review-work/<8 hex> to the state", os.path.islink(link) and os.path.dirname(link) == al_base
   and re.fullmatch(r"[0-9a-f]{8}", os.path.basename(link)) and os.path.realpath(link) == os.path.realpath(state), link)
is_("alias: recorded in <state>/alias", open(os.path.join(state, "alias")).read().strip(), link)
is_("alias: stable across calls", (C.alias(state), C.alias(state)), (link, link))
is_("aliased: a path under the state, as the same path under the alias", C.aliased(state, os.path.join(state, "judge-task", "n-judge-task.json")),
    os.path.join(link, "judge-task", "n-judge-task.json"))
ok("aliased: a path outside the state is refused", raises(C.aliased, state, os.path.join(ROOT, "elsewhere")))
jfile(os.path.join(link, "judge-task", "n-judge-task.answer.json"), {"findings": []})
is_("alias: an answer written through the aliased path is read by judge_answer", C.judge_answer(state, "judge-task", "n-judge-task"), {"findings": []})
os.unlink(link)
is_("alias: recreated at its recorded path when the symlink is gone", (C.alias(state), os.path.islink(link), os.path.realpath(link) == os.path.realpath(state)),
    (link, True, True))
other = os.path.join(ROOT, "st-other")
os.makedirs(other)
lo = C.alias(other)
ok("alias: another state gets its own", lo != link and os.path.realpath(lo) == os.path.realpath(other), lo)

# ---- cmd_pending
state = os.path.join(ROOT, "st3")
import io  # noqa: E402
import contextlib  # noqa: E402


class A(object):
    pass


a_ = A()
a_.state = state
a_.dry_run = False
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = C.cmd_pending(a_)
lines = buf.getvalue().splitlines()
ok("cmd_pending: one line per pending item, with its brief", rc == 0 and len(lines) == 2 and "judge-present" in lines[0]
   and "i-one" in lines[0] and lines[0].rstrip().endswith(C.aliased(state, os.path.join(state, "judge-present", "i-one.brief.md"))), lines)
ok("cmd_pending: and the briefs exist", all(os.path.isfile(os.path.join(state, "judge-present", i + ".brief.md")) for i in ("i-one", "i-two")))

# ---- view_reads_snapshot_only_objects
org =os.path.join(ROOT, "Code", "Org")
os.makedirs(org)
repo = helpers.make_repo(org, "curato")
put(repo, "a.txt", "a\n")
c0 = helpers.commit(repo, "base")
put(repo, "a.txt", "a\nb\n")
c1 = helpers.commit(repo, "work")
gitdir = os.path.join(repo, ".git")
snaproot = os.path.join(ROOT, "snap")
os.makedirs(os.path.join(snaproot, "curato"))
shutil.copytree(os.path.join(gitdir, "objects"), os.path.join(snaproot, "curato", "objects"))
git(repo, "reset", "-q", "--hard", c0)
git(repo, "reflog", "expire", "--expire=now", "--all")
git(repo, "gc", "-q", "--prune=now")
ok("view_reads_snapshot_only_objects: control: the original no longer has the commit", not git_ok(repo, "cat-file", "-e", c1))
snap_before = helpers.listing(snaproot)
orig_before = helpers.listing(os.path.join(gitdir, "objects"))
state = os.path.join(ROOT, "st4")
v = C.view(state, gitdir, snaproot)
is_("view_reads_snapshot_only_objects: the view is <state>/views/<name>.git", v, os.path.join(state, "views", "curato.git"))
is_("view_reads_snapshot_only_objects: the commit resolves", C.git(v, "cat-file", "-t", c1), "commit")
is_("view_reads_snapshot_only_objects: a short id resolves", C.git(v, "rev-parse", "--verify", c1[:9] + "^{commit}"), c1)
is_("view_reads_snapshot_only_objects: history reads", C.git(v, "log", "-1", "--format=%s", c1), "work")
is_("view_reads_snapshot_only_objects: the diff reads", C.git(v, "diff", "--stat", c0, c1).splitlines()[-1].strip(), "1 file changed, 1 insertion(+)")
ok("view_reads_snapshot_only_objects: git_ok answers", C.git_ok(v, "cat-file", "-e", c1) and not C.git_ok(v, "cat-file", "-e", "0" * 40))
ok("view_reads_snapshot_only_objects: git raises Failed on an error", raises(C.git, v, "cat-file", "-t", "0" * 40))
is_("view_reads_snapshot_only_objects: a second call returns the same view", C.view(state, gitdir, snaproot), v)
alt = open(os.path.join(v, "objects", "info", "alternates")).read().split()
is_("view_reads_snapshot_only_objects: alternates name the snapshot's objects", alt, [os.path.join(snaproot, "curato", "objects")])
is_("view_reads_snapshot_only_objects: the snapshot listing (paths, sizes, mtimes) is unchanged", helpers.listing(snaproot), snap_before)
is_("view_reads_snapshot_only_objects: so is the original's object store", helpers.listing(os.path.join(gitdir, "objects")), orig_before)
v2 = C.view(state, gitdir, os.path.join(ROOT, "no-snapshots"))
alt2 = open(os.path.join(v2, "objects", "info", "alternates")).read().split()
is_("view_reads_snapshot_only_objects: without a snapshot the alternates are the original's objects", alt2, [os.path.join(gitdir, "objects")])
ok("view_reads_snapshot_only_objects: and an object the original has resolves", C.git_ok(v2, "cat-file", "-e", c0))

# ---- snapshot_map
snap = os.path.join(ROOT, "snapmap")
os.makedirs(os.path.join(snap, "curato", "objects"))
os.makedirs(os.path.join(snap, "chezmoi", "objects"))
is_("snapshot_map: a repository under Code", C.snapshot_objects(snap, "/x/Code/Netronix/curato/.git"), os.path.join(snap, "curato", "objects"))
is_("snapshot_map: the dotfiles", C.snapshot_objects(snap, "/x/.local/share/chezmoi/.git"), os.path.join(snap, "chezmoi", "objects"))
is_("snapshot_map: a trailing slash", C.snapshot_objects(snap, "/x/Code/Netronix/curato/.git/"), os.path.join(snap, "curato", "objects"))
is_("snapshot_map: an unknown name", C.snapshot_objects(snap, "/x/Code/Netronix/unknown/.git"), None)
os.makedirs(os.path.join(snap, "empty"))
is_("snapshot_map: a name whose dir has no objects", C.snapshot_objects(snap, "/x/empty/.git"), None)

# ---- the command line
CLI = os.path.join(helpers.SCRIPTS, "process-replay.py")
ok("cli: process-replay.py is executable", os.access(CLI, os.X_OK))


def cli(*args, cwd=None):
    env = dict(os.environ, XDG_STATE_HOME=os.path.join(ROOT, "xdg"))
    return subprocess.run(["/usr/bin/python3", "-I", "-B", CLI] + list(args), capture_output=True, cwd=cwd, env=env)


work = os.path.join(ROOT, "cwd")
os.makedirs(work)
p = cli("pending", "--state", "rel-state", cwd=work)
ok("cli: --state is made absolute and created", p.returncode == 0 and os.path.isdir(os.path.join(work, "rel-state")), p.stderr)
is_("cli: nothing pending says so", p.stdout.decode().strip(), "nothing pending")
C.judge_write(os.path.join(work, "rel-state"), "judge-class", "k1", {"finding": 1})
p = cli("pending", "--state", "rel-state", cwd=work)
out = p.stdout.decode()
ok("cli: pending lists the input and writes its brief", p.returncode == 0 and "judge-class" in out and "k1" in out
   and os.path.isfile(os.path.join(work, "rel-state", "judge-class", "k1.brief.md")), out + p.stderr.decode())
p = cli("nonsense")
ok("cli: an unknown command exits 2", p.returncode == 2 and b"nonsense" in p.stderr, p.stderr)
p = cli("--help")
ok("cli: help lists the subcommands", p.returncode == 0 and all(c.encode() in p.stdout for c in
   ("snapshot", "cases", "inject", "run", "match", "report", "cleanup", "pending", "home", "memories-watch")), p.stdout)
p = cli("pending", "--state", "rel-state", "--max-tokens", "5", "--budget", "7", "--snapshot-root", "/x", "--projects-dir", "/y", "--dry-run", cwd=work)
ok("cli: the shared flags parse", p.returncode == 0, p.stderr)

# ---- the fixtures later suites build on: rollouts, ledgers, transcripts, the fake rpc and the fake codex
XRM = C.XR
chome = os.path.join(ROOT, "chome")
helpers.write_rollout(chome, "thR", [
    {"turn": "t1", "answer": {"verdict": "changes", "findings": []}, "tokens": 700, "rate_limits": {"primary": {"used_percent": 81.0, "window_minutes": 10080, "resets_at": 5}}},
    {"turn": "t2", "ctx": 175000, "answer": "plain text", "tokens": 400, "compacted": True, "model": "m-2", "effort": "low",
     "tools": [{"type": "function_call", "name": "shell", "arguments": {"cmd": "ls /work"}}, {"type": "custom_tool_call", "arguments": "cat /work/x"}]},
    ("t3", None, {"verdict": "approve", "findings": []}, False)])
os.environ["CODEX_HOME"] = chome
XRM._TURNS.clear()
turns = XRM.turns_of("thR")
is_("rollouts: turns come back in order with their answers", (list(turns), json.loads(turns["t1"]["final"])["verdict"], turns["t2"]["final"]),
    (["t1", "t2", "t3"], "changes", "plain text"))
is_("rollouts: context before a turn, compaction, model and effort", (turns["t2"]["ctx_before"], turns["t2"]["compacted"], turns["t2"]["model"], turns["t2"]["effort"], turns["t1"]["compacted"]),
    (175000, True, "m-2", "low", False))
is_("rollouts: a turn's tokens are its own", (XRM.turn_usage("thR", "t1")["tokens"], XRM.turn_usage("thR", "t2")["tokens"]), (700, 400))
lines = [json.loads(l) for l in open(helpers.rollout_file(chome, "thR"))]
tools = [r["payload"] for r in lines if r["type"] == "response_item"]
ok("rollouts: a function_call carries arguments, a custom_tool_call input (the real shapes)",
   tools[0]["type"] == "function_call" and "/work" in tools[0]["arguments"] and tools[1]["type"] == "custom_tool_call"
   and tools[1]["input"] == "cat /work/x", tools)
rl = [r["payload"]["rate_limits"] for r in lines if r["type"] == "event_msg" and r["payload"].get("rate_limits")]
is_("rollouts: rate_limits sit in the token_count payload", rl[0]["primary"]["window_minutes"], 10080)

xdg = os.path.join(ROOT, "xdg2")
os.environ["XDG_STATE_HOME"] = xdg
lrepo = helpers.make_repo(ROOT, "ledgered")
put(lrepo, "f", "1\n")
helpers.commit(lrepo, "c")
helpers.write_ledger(xdg, lrepo, [{"v": 2, "kind": "receipt", "nonce": "n1"}])
found = list(XRM.ledgers())
is_("ledger: xreview-replay finds the fixture ledger", [(os.path.realpath(r), [e["nonce"] for e in es]) for r, es in found],
    [(os.path.realpath(C.L.common_dir(lrepo)), ["n1"])])

proj = os.path.join(ROOT, "projects")
helpers.write_transcript(proj, "-key", "sess", [{"type": "user", "n": 1}], [{"id": "ab12", "meta": {"agentType": "sp-reviewer", "description": "Review Task 1"},
                                                                            "entries": [{"type": "assistant"}]}])
is_("transcript: the session, its subagent and the subagent's meta", (
    json.loads(open(os.path.join(proj, "-key", "sess.jsonl")).readline()),
    json.load(open(os.path.join(proj, "-key", "sess", "subagents", "agent-ab12.meta.json")))["agentType"],
    os.path.isfile(os.path.join(proj, "-key", "sess", "subagents", "agent-ab12.jsonl"))), ({"type": "user", "n": 1}, "sp-reviewer", True))

# the fake rpc, driven through xreview-replay's own client
FAKE = os.path.join(ROOT, "fake")
ANS1 = {"verdict": "changes", "findings": [{"severity": "P1", "file": "a.py", "line": 1, "summary": "s", "failure_scenario": "f"}], "reviewed_files": ["a.py"]}
ANS2 = {"verdict": "approve", "findings": [], "reviewed_files": []}
script = {"turns": [{"answer": ANS1, "tokens": 1500, "rate_limits": {"primary": {"used_percent": 10, "window_minutes": 10080}}},
                    {"answer": ANS2, "rc3": 2, "compacted": True}],
          "threads": {"th2": [{"answer": ANS2, "rc": 4, "raw": "not json"}]}}
rpc = helpers.stub_rpc(FAKE, os.path.join(ROOT, "rpc-home-default"), script)
XRM.RPC = rpc
rhome = os.path.join(ROOT, "rhome")
os.environ["CODEX_HOME"] = rhome
XRM._TURNS.clear()
rc, out, _err = XRM.rpc("thread-start", "--cwd", ROOT)
th1 = out.strip()
is_("stub_rpc: thread-start numbers its threads", (rc, th1), (0, "th1"))
inp = os.path.join(ROOT, "packet.md")
put(ROOT, "packet.md", "the packet\n")
rc, out, _err = XRM.rpc("turn-start", "--thread", th1, "--input", inp, "--schema", "/s", "--cwd", ROOT)
tu1 = out.strip()
is_("stub_rpc: turn-start gives the first scripted turn an id and keeps its input", (rc, tu1, open(os.path.join(FAKE, "inputs", tu1)).read()),
    (0, "tu1", "the packet\n"))
rep = os.path.join(ROOT, "report.json")
rc, out, _err = XRM.rpc("turn-wait", "--thread", th1, "--turn", tu1, "--budget", "5", "--report", rep)
is_("stub_rpc: turn-wait answers with the scripted document", (rc, json.loads(out)), (0, ANS1))
is_("stub_rpc: and reports the compaction", C.jload(rep), {"turn": tu1, "compacted": False})
is_("stub_rpc: the rollout lands under the call's CODEX_HOME and reads back", (os.path.isdir(os.path.join(rhome, "sessions")), XRM.turn_usage(th1, tu1)["tokens"],
    json.loads(XRM.turns_of(th1)[tu1]["final"])["verdict"]), (True, 1500, "changes"))
rc, out, _err = XRM.rpc("thread-start", "--cwd", ROOT)
th2 = out.strip()
rc, out, _err = XRM.rpc("turn-start", "--thread", th2, "--input", inp, "--schema", "/s")
tu2 = out.strip()
rc, out, _err = XRM.rpc("turn-wait", "--thread", th2, "--turn", tu2, "--budget", "5")
is_("stub_rpc: a turn keyed by thread beats the global order, and rc 4 prints the raw text", (rc, out.strip()), (4, "not json"))
rc, out, _err = XRM.rpc("thread-start", "--cwd", ROOT)
th3 = out.strip()
rc, out, _err = XRM.rpc("turn-start", "--thread", th3, "--input", inp, "--schema", "/s")
tu3 = out.strip()
waits = [XRM.rpc("turn-wait", "--thread", th3, "--turn", tu3, "--budget", "5")[0] for _ in range(3)]
is_("stub_rpc: the global order's second turn, still running for two waits (exit 3)", (tu3, waits), ("tu3", [3, 3, 0]))
rc, _out, err = XRM.rpc("turn-start", "--thread", th3, "--input", inp, "--schema", "/s")
ok("stub_rpc: a turn past the end of the script fails loudly", rc == 1 and "no turn left" in err, err)
is_("stub_rpc: archive and health succeed", (XRM.rpc("thread-archive", "--thread", th1)[0], XRM.rpc("health")[0]), (0, 0))
is_("stub_rpc: an unknown command exits 2", XRM.rpc("thread-fork", "--thread", th1)[0], 2)
calls = helpers.read_log(os.path.join(FAKE, "rpc.log"))
ok("stub_rpc: every call is logged with its argv and CODEX_HOME", len(calls) == 15 and all(c["codex_home"] == rhome for c in calls)
   and calls[0]["argv"] == ["thread-start", "--cwd", ROOT] and calls[0]["cmd"] == "thread-start", calls[:2])
os.environ.pop("CODEX_HOME")
XRM.rpc("health")
ok("stub_rpc: without a CODEX_HOME the call is logged as such", helpers.read_log(os.path.join(FAKE, "rpc.log"))[-1]["codex_home"] is None)

# the fake codex binary
codex = helpers.stub_codex(os.path.join(ROOT, "fakecodex"))
chm = os.path.join(ROOT, "codexhome")
sock = os.path.join(chm, "app-server-control", "app-server-control.sock")


def codex_run(*args, home=chm):
    env = dict(os.environ)
    env.pop("CODEX_HOME", None)
    if home:
        env["CODEX_HOME"] = home
    return subprocess.run([codex] + list(args), capture_output=True, env=env)


p = codex_run("app-server", "daemon", "start")
ok("stub_codex: daemon start makes the socket a plain file", p.returncode == 0 and os.path.isfile(sock) and not os.path.islink(sock), p.stderr)
p = codex_run("app-server", "daemon", "stop")
ok("stub_codex: daemon stop removes it", p.returncode == 0 and not os.path.exists(sock), p.stderr)
is_("stub_codex: login succeeds", codex_run("login").returncode, 0)
is_("stub_codex: with no CODEX_HOME a daemon command fails", codex_run("app-server", "daemon", "start", home=None).returncode, 2)
is_("stub_codex: an unknown command exits 2", codex_run("exec").returncode, 2)
log = helpers.read_log(os.path.join(ROOT, "fakecodex", "codex.log"))
is_("stub_codex: argv and CODEX_HOME are logged", (log[0], len(log)), ({"argv": ["app-server", "daemon", "start"], "codex_home": chm}, 5))
p = cli()
ok("cli: no command prints the usage to stderr and exits 2", p.returncode == 2 and p.stdout == b"" and b"usage:" in p.stderr, (p.stdout, p.stderr))

# ---- alias: a copied state, a dangling link
orig = os.path.join(ROOT, "al-orig")
os.makedirs(orig)
orig_link = C.alias(orig)
copy = os.path.join(ROOT, "al-copy")
shutil.copytree(orig, copy, symlinks=True)
copy_link = C.alias(copy)
ok("alias: a state copied with cp -r gets a link of its own", copy_link != orig_link and os.path.realpath(copy_link) == os.path.realpath(copy), copy_link)
ok("alias: and the original's link still resolves to the original", os.path.realpath(orig_link) == os.path.realpath(orig)
   and open(os.path.join(orig, "alias")).read().strip() == orig_link and C.alias(orig) == orig_link)
moved = os.path.join(ROOT, "al-moved")
os.rename(orig, moved)
ok("alias: control: moving a state leaves its link dangling", os.path.islink(orig_link) and not os.path.exists(orig_link))
is_("alias: a dangling link is re-pointed at the same name", C.alias(moved), orig_link)
ok("alias: and now resolves to the moved state", os.path.realpath(orig_link) == os.path.realpath(moved))

# ---- setup() redirects home, state and Codex home even when git is already isolated
probe = "import sys; sys.path.insert(0, %r); import helpers, os; helpers.setup(); print(os.environ['HOME'], os.environ['XDG_STATE_HOME'], os.environ['CODEX_HOME'])" % helpers.HERE
real = {"HOME": "/real/home", "XDG_STATE_HOME": "/real/state", "CODEX_HOME": "/real/codex"}
env = dict(os.environ, GIT_CONFIG_GLOBAL=os.environ["GIT_CONFIG_GLOBAL"], **real)
env.pop("T_ROOT", None)
out = subprocess.run(["/usr/bin/python3", "-I", "-B", "-c", probe], capture_output=True, env=env).stdout.decode().split()
ok("helpers.setup: redirects the three variables although GIT_CONFIG_GLOBAL is set", len(out) == 3 and not any(v.startswith("/real") for v in out), out)
env["T_ROOT"] = ROOT
env.update(HOME=ROOT + "/h", XDG_STATE_HOME=ROOT + "/s", CODEX_HOME=ROOT + "/c")
out = subprocess.run(["/usr/bin/python3", "-I", "-B", "-c", probe], capture_output=True, env=env).stdout.decode().split()
is_("helpers.setup: keeps the wrapper's own redirect", out, [ROOT + "/h", ROOT + "/s", ROOT + "/c"])
