import glob
import json
import os
import re
import sys
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import final as F  # noqa: E402
from process_replay import scratch  # noqa: E402
from process_replay.common import Failed  # noqa: E402

ROOT = helpers.tmp_root()
PROJECTS = os.path.join(ROOT, "projects")
KEY = re.sub(r"[^A-Za-z0-9]", "-", os.path.expanduser("~/Code/.replay"))
os.makedirs(PROJECTS)

# ---- a superpowers fixture shaped like the real skills directory
SP = os.path.join(ROOT, "superpowers")
put(SP, "skills/requesting-code-review/code-reviewer.md", """# Code Reviewer Prompt Template

Use this template when dispatching a code reviewer subagent.

```
Subagent (general-purpose):
  description: "Review code changes"
  prompt: |
    You are a Senior Code Reviewer.

    ## What Was Implemented

    [DESCRIPTION]

    ## Requirements / Plan

    [PLAN_OR_REQUIREMENTS]

    **Base:** [BASE_SHA]
    **Head:** [HEAD_SHA]

    ```bash
    git diff [BASE_SHA]..[HEAD_SHA]
    ```
```

**Placeholders:**
- `[DESCRIPTION]` is brief
""")
PKG = os.path.join(SP, "skills/subagent-driven-development/scripts/review-package")
put(os.path.dirname(PKG), "review-package", """#!/usr/bin/env bash
set -euo pipefail
plan=$1; base=$2; head=$3; out=$4
[ -f "$plan" ] || { echo "no such plan file: $plan" >&2; exit 2; }
git merge-base --is-ancestor "$base" "$head" || exit 3
mkdir -p "$(dirname "$out")"
{ echo "# Review package: ${base}..${head}"; git diff --stat "${base}..${head}"; } > "$out"
echo "wrote ${out}"
""")
os.chmod(PKG, 0o755)

# ---- superpowers_root
CACHE = os.path.join(os.path.expanduser("~"), ".claude", "plugins", "cache", "market", "superpowers")
for v in ("7.0.0", "9.1.0", "10.0.0"):
    put(os.path.join(CACHE, v), "skills/requesting-code-review/code-reviewer.md", "x")
os.environ["PROCESS_REPLAY_SUPERPOWERS"] = SP
is_("superpowers: PROCESS_REPLAY_SUPERPOWERS wins", F.superpowers_root(), SP)
del os.environ["PROCESS_REPLAY_SUPERPOWERS"]
is_("superpowers: else the newest version under the plugin cache, compared as numbers", F.superpowers_root(), os.path.join(CACHE, "10.0.0"))
os.environ["PROCESS_REPLAY_SUPERPOWERS"] = SP


# ---- the world: an original repository, a scratch built from it, a run, a branch record
def world(name, plans=("docs/superpowers/plans/2026-10-20-x.md",), plan_commit_index=None):
    orig = helpers.make_repo(ROOT, "orig-" + name)
    put(orig, "README", "base\n")
    base = helpers.commit(orig, "base")
    git(orig, "checkout", "-q", "-b", "feat")
    commits = []
    for i, plan in enumerate(plans):
        put(orig, plan, "# plan %d\n" % i)
        put(orig, "src/a%d.py" % i, "x = %d\n" % i)
        commits.append(helpers.commit(orig, "step %d" % i))
    common = os.path.realpath(os.path.join(orig, ".git"))
    files = os.path.join(ROOT, "files-" + name)
    scratch.export(os.path.join(common, "objects"), commits[-1], files)
    out = os.path.join(os.environ["XDG_STATE_HOME"], "review-work", "scratch", "lab-" + name)
    scratch.build(os.path.join(common, "objects"), base, files, out, "main", "feat", expect_tree=git(orig, "rev-parse", commits[-1] + "^{tree}"))
    state = os.path.join(ROOT, "state-" + name)
    os.makedirs(state)
    a = Namespace(state=state, snapshot_root=os.path.join(ROOT, "snapshots"), projects_dir=PROJECTS, transcript=[])
    run = {"label": "lab-" + name, "scratch": out}
    branch = {"repo": common, "objects": os.path.join(common, "objects"), "view": None, "base": base, "branch": "feat",
              "plan_commit": commits[plan_commit_index] if plan_commit_index is not None else None}
    return a, run, branch, os.path.dirname(common)


a, run, branch, orig = world("one")
F.write_brief(a, run, branch)
jid = run["label"]
d = C.item_dir(a.state, "final", jid)
brief = open(os.path.join(d, "brief.md")).read()
tip = git(run["scratch"], "rev-parse", "HEAD")
plan = os.path.join(run["scratch"], "docs/superpowers/plans/2026-10-20-x.md")
ok("final_brief: the description names the branch", "The change on feat." in brief, brief)
ok("final_brief: the plan is the scratch's plan file", plan in brief)
ok("final_brief: base and tip are the scratch's", "**Base:** " + branch["base"] in brief and "**Head:** " + tip in brief
   and "git diff {}..{}".format(branch["base"], tip) in brief, brief)
ok("final_brief: no placeholder is left", not re.search(r"\[(DESCRIPTION|PLAN_OR_REQUIREMENTS|BASE_SHA|HEAD_SHA)\]", brief))
ok("final_brief: the template's framing is not in the brief, its prompt is", "Subagent (general-purpose)" not in brief and "You are a Senior Code Reviewer." in brief)
pkg = [l.split(": ", 1)[1] for l in brief.splitlines() if l.startswith("Review package")]
ok("final_brief: the review package is staged beside the brief, written by review-package in the scratch",
   pkg == [os.path.join(d, "package.diff")] and open(pkg[0]).read().startswith("# Review package: {}..{}".format(branch["base"], tip)), pkg)
is_("final_brief: the staged directory holds the brief and the package and nothing else", sorted(os.listdir(d)), ["brief.md", "package.diff"])
ok("final_brief: the directory is a real one outside the state", not os.path.islink(d) and os.path.dirname(d) == C.items_root() and a.state not in d and "replay" not in brief)
ok("final_brief: it names the scratch repository and its id once", "Repository: " + run["scratch"] in brief and brief.count("Review id: ") == 1 and "\nReview id: {}\n".format(jid) in brief)
ok("final_brief: it says nothing of the replay", not re.search(r"replay|inject|per-task", brief, re.I), re.findall(r"(?i).{20}(?:replay|inject|per-task).{20}", brief))
is_("final_brief: the state keeps a copy of the brief as the marker pending lists", open(os.path.join(a.state, "final", jid, "brief.md")).read(), brief)
is_("final_brief: and pending hands the staged brief out", [(k, i, b) for k, i, _x, _y, b in C.pending(a.state)], [("final", jid, os.path.join(d, "brief.md"))])

# ---- the answer comes back from the staged directory
is_("answer: none yet", F.answer(a, jid), None)
put(d, "answer.md", "### Issues\nnone\n")
is_("answer: the text the driver wrote in the staged directory", F.answer(a, jid), "### Issues\nnone\n")
ok("answer: now held by the state, and gone from the staged directory", os.path.isfile(os.path.join(a.state, "final", jid, "answer.md")) and not os.path.exists(os.path.join(d, "answer.md")))
is_("answer: and read again from there", F.answer(a, jid), "### Issues\nnone\n")

# ---- plan_path
is_("plan_path: the plan the branch changed", F.plan_path(a, run, branch), plan)
a2, run2, branch2, _o = world("two", plans=("docs/superpowers/plans/2026-10-01-old.md", "docs/superpowers/plans/2026-10-02-new.md"), plan_commit_index=0)
is_("plan_path: of several, the one the branch's plan commit changed (not the one that sorts last)", F.plan_path(a2, run2, branch2),
    os.path.join(run2["scratch"], "docs/superpowers/plans/2026-10-01-old.md"))
a3, run3, branch3, _o = world("three", plans=("docs/superpowers/plans/2026-10-01-old.md", "docs/superpowers/plans/2026-10-02-new.md"))
try:
    F.plan_path(a3, run3, branch3)
    got = "no error"
except F.PlanError as e:
    got = str(e)
ok("plan_path: of several with nothing to tell them apart it refuses, naming them, and does not guess", "ambiguous" in got and "old.md" in got and "new.md" in got, got)
a4, run4, branch4, _o = world("four")
git(run4["scratch"], "rm", "-q", "-r", "docs")
git(run4["scratch"], "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "no plan")
try:
    F.plan_path(a4, run4, dict(branch4, base=git(run4["scratch"], "rev-parse", "HEAD")))
    got = "no error"
except F.PlanError as e:
    got = str(e)
ok("plan_path: no plan changed is a PlanError too", "missing" in got, got)


# ---- transcripts
def transcript(jid, commands=(), prompt=None, key=None, agent=None, parent=None, session="sess", calls=None):
    first = prompt if prompt is not None else "You are a Senior Code Reviewer.\n\nReview id: {}\n".format(jid)
    entries = [{"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": first}]}}]
    for c in commands:
        entries.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": c}}]}})
    for name, inp in calls or []:
        entries.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": name, "input": inp}]}})
    meta = {"agentType": "sp-architect"}
    if parent:
        meta["parentAgentId"] = parent
    helpers.write_transcript(PROJECTS, key or KEY, session, [{"type": "user", "message": {"role": "user", "content": "drive"}}],
                             subagents=[{"id": agent or jid, "meta": meta, "entries": entries}])
    return os.path.join(PROJECTS, key or KEY, session, "subagents", "agent-%s.jsonl" % (agent or jid))


a, run, branch, orig = world("t1")
jid = run["label"]
F.write_brief(a, run, branch)
staged = os.path.join(C.item_dir(a.state, "final", jid), "brief.md")
is_("transcripts: none yet", F.lookup(a, jid)[0], [])
ok("transcripts: and the operator is told how to point at one", "--transcript" in F.lookup(a, jid)[1], F.lookup(a, jid)[1])
t1 = transcript(jid)
is_("transcripts: the first prompt's `Review id:` line finds it", F.lookup(a, jid), ([t1], None))
os.unlink(t1)
t2 = transcript(jid, prompt="Read {} and follow it.".format(staged))
is_("transcripts: so does the staged brief path (a driver hands a brief by path)", F.lookup(a, jid), ([t2], None))
t3 = transcript(jid, key=KEY + "-wt")
got, note = F.lookup(a, jid)
ok("transcripts: two matches (a project dir that merely starts with the key is searched too): none is picked, and it says so",
   got == [] and note and "none is picked" in note and t2 in note and t3 in note, note)
other = transcript(jid, key="-Users-x-Code-other", session="other")
ok("transcripts: a project that is not ~/Code/.replay's is not searched", other not in F.lookup(a, jid)[1])
elsewhere = os.path.join(ROOT, "elsewhere.jsonl")
put(ROOT, "elsewhere.jsonl", json.dumps({"type": "user", "message": {"role": "user", "content": "x"}}) + "\n")
a.transcript = ["%s=%s" % (jid, elsewhere)]
is_("transcripts: --transcript names one, whatever the search finds", F.lookup(a, jid), ([elsewhere], None))
a.transcript = ["%s=%s" % (jid, os.path.join(ROOT, "nope.jsonl"))]
ok("transcripts: a --transcript that is not a file is reported", "not a file" in F.lookup(a, jid)[1])
a.transcript = ["nonsense"]
try:
    F.lookup(a, jid)
    got = "no error"
except Failed as e:
    got = str(e)
ok("transcripts: one that is not ID=PATH is refused", "ID=PATH" in got, got)
a.transcript = []

# ---- the leak scan
a, run, branch, orig = world("leak")
jid = run["label"]
F.write_brief(a, run, branch)
own = C.item_dir(a.state, "final", jid)
alias = C.alias(a.state)
mine_other = C.item_dir(a.state, "judge-match", "m1")
put(mine_other, "input.json", "{}")


def leaks_of(commands=(), calls=None, name="x"):
    path = transcript(jid, commands=commands, calls=calls, session="s-" + name)
    return F.leaks(a, run, branch, path)


ok("leak_scan: reading the review's own staged directory is fine", leaks_of(["cat {}/brief.md".format(own), "git -C {} log".format(run["scratch"])], name="own") == [])
ok("leak_scan: a command naming the original checkout is a leak", leaks_of(["git -C {} show HEAD".format(orig)], name="orig") != [])
ok("leak_scan: a Read in the original checkout is a leak", leaks_of(calls=[("Read", {"file_path": os.path.join(orig, "src", "a0.py")})], name="read") != [])
ok("leak_scan: a final reviewer reading the state directory is a leak", leaks_of(["ls {}".format(a.state)], name="state") != [])
ok("leak_scan: and a file in it", leaks_of(calls=[("Read", {"file_path": os.path.join(a.state, "inventory", "b.json")})], name="inv") != [])
ok("leak_scan: through the state's alias too", leaks_of(["cat {}/inventory/b.json".format(alias)], name="alias") != [])
ok("leak_scan: another staged item is a leak", leaks_of(["cat {}/input.json".format(mine_other)], name="item") != [])
ok("leak_scan: a Glob over another item is a leak", leaks_of(calls=[("Glob", {"pattern": mine_other + "/*"})], name="glob") != [])
review_work = os.path.dirname(C.items_root())
ok("leak_scan: a glob over every item, reached from the review's own directory, is a leak", leaks_of(["cat {}/../*/input.json".format(own)], name="dotdot") != [])
ok("leak_scan: a Grep whose path is the items root is a leak", leaks_of(calls=[("Grep", {"pattern": "answer", "path": C.items_root()})], name="grep") != [])
ok("leak_scan: listing the items root is a leak", leaks_of(["ls {}".format(C.items_root())], name="ls") != [])
ok("leak_scan: so is listing it by a spelling relative to where the command runs", leaks_of(["cd {} && ls review-work/items".format(os.path.dirname(review_work))], name="rel") != [])
ok("leak_scan: or from the home directory", leaks_of(["ls $XDG_STATE_HOME/review-work/items", "ls ../../review-work/items"], name="home") != [])
ok("leak_scan: listing review-work itself is a leak", leaks_of(["ls {}".format(review_work)], name="rw") != [])
ok("leak_scan: another run's scratch is a leak", leaks_of(["cat {}/scratch/other-run/README".format(review_work)], name="scr") != [])
ok("leak_scan: and so is the scratch root", leaks_of(["ls {}/scratch".format(review_work)], name="scrroot") != [])
ok("leak_scan: its own staged directory and its own scratch are not (a file, the directory, a relative path from the scratch)",
   leaks_of(["cat {}/package.diff".format(own), "ls {}".format(own), "ls {}".format(run["scratch"]), "cat src/a0.py", "git diff HEAD~1..HEAD"], name="allowed") == [])
ok("leak_scan: a Glob inside its own directory is not", leaks_of(calls=[("Glob", {"pattern": own + "/*.diff"})], name="globown") == [])
for n, (label, cmd) in enumerate((("the snapshot root", "ls ~/Code/.replay/snapshot"), ("October's Codex rollouts", "rg -n x ~/.codex/sessions"),
                                 ("October's Codex memories", "cat ~/.codex/memories/MEMORY.md"), ("the Claude transcripts", "ls ~/.claude/projects"),
                                 ("the xreview ledgers", "cat $XDG_STATE_HOME/xreview/ledgers/k/reviews.jsonl"))):
    ok("leak_scan: a final reviewer reading {} is a leak".format(label), leaks_of([cmd], name="root{}".format(n)) != [], cmd)

ok("leak_scan: a Grep for a root's name in its own scratch, by absolute path, is not a leak",
   leaks_of(calls=[("Grep", {"pattern": "xreview", "path": run["scratch"]}), ("Read", {"file_path": run["scratch"] + "/dot_claude/xreview-packet.py"})], name="grepown") == [])
ok("leak_scan: a final reviewer reading the replay homes is a leak", leaks_of(["ls $XDG_STATE_HOME/cxh/nomem/sessions"], name="cxh") != [])
ok("leak_scan: reading $XDG_STATE_HOME/xreview/ledgers is still a leak", leaks_of(calls=[("Read", {"file_path": os.path.join(os.environ["XDG_STATE_HOME"], "xreview", "ledgers", "x")})], name="xrv") != [])

# ---- a reviewer's own saved tool results (Claude Code keeps them in the session's tool-results/) are its to read; another session's are not
CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")


def own_session(session, commands=(), calls=None, agent=None, others=()):
    """A driver session under ~/.claude/projects/proj whose subagent `agent` (default rev) is the reviewer, beside `others`: other
    subagents of the same session (the judges a driver dispatches), each {id, meta}."""
    entries = [{"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "You are a Senior Code Reviewer.\n\nReview id: {}\n".format(jid)}]}}]
    for c in commands:
        entries.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": "Bash", "input": {"command": c}}]}})
    for name, inp in calls or []:
        entries.append({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": name, "input": inp}]}})
    return helpers.write_transcript(CLAUDE_PROJECTS, "proj", session, [{"type": "user", "message": {"role": "user", "content": "drive"}}],
                                    subagents=[{"id": agent or "rev", "meta": {"agentType": "sp-architect"}, "entries": entries}] + [
                                        dict({"entries": [{"type": "user", "message": {"role": "user", "content": "judge"}}]}, **o) for o in others])


def rev(session):
    return os.path.join(CLAUDE_PROJECTS, "proj", session, "subagents", "agent-rev.jsonl")


mine_dir = os.path.join(CLAUDE_PROJECTS, "proj", "s-mine")
top = own_session("s-mine", calls=[("Read", {"file_path": mine_dir + "/tool-results/x.txt"}), ("Grep", {"pattern": "y", "path": mine_dir + "/tool-results"})],
                  commands=["cat ~/.claude/projects/proj/s-mine/tool-results/x.txt", "head {}/subagents/agent-rev.jsonl".format(mine_dir)])
sub = os.path.join(mine_dir, "subagents", "agent-rev.jsonl")
is_("leak_scan: a reviewer reading its own session's tool-results (absolute or ~ spelling) and its own transcript is clean, whether its transcript is the subagent's or the session's",
    (F.leaks(a, run, branch, sub), F.leaks(a, run, branch, top)), ([], []))
own_session("s-mine2", calls=[("Read", {"file_path": CLAUDE_PROJECTS + "/proj/s-other/tool-results/x.txt"})])
is_("leak_scan: ... but another session's files are a leak", F.leaks(a, run, branch, rev("s-mine2")), [CLAUDE_PROJECTS])
own_session("s-mine3", commands=["cat {}-evil/tool-results/x".format(CLAUDE_PROJECTS + "/proj/s-mine3")])
is_("leak_scan: a sibling that merely starts like the session's is a leak, read alone (D)", F.leaks(a, run, branch, rev("s-mine3")), [CLAUDE_PROJECTS])
own_session("s-mine4", commands=["ls ~/.claude/projects"])
is_("leak_scan: ... and so is the projects root itself, alone", F.leaks(a, run, branch, rev("s-mine4")), [CLAUDE_PROJECTS])
# C: the driver session's subagents/ holds the judges' transcripts beside the reviewer's; only the reviewer's own (and its descendants') are its own
S5 = os.path.join(CLAUDE_PROJECTS, "proj", "s-mine5")
judge = {"id": "judge1", "meta": {"agentType": "sp-standard"}}
kid = {"id": "kid1", "meta": {"agentType": "sp-reviewer", "parentAgentId": "rev"}}
own_session("s-mine5", calls=[("Read", {"file_path": S5 + "/subagents/agent-judge1.jsonl"})], others=(judge, kid))
is_("leak_scan: a final reviewer reading a judge's transcript in its driver session is a leak (C)", F.leaks(a, run, branch, rev("s-mine5")), [CLAUDE_PROJECTS])
own_session("s-mine5", commands=["cat {}/subagents/agent-rev.jsonl {}/subagents/agent-kid1.jsonl {}/tool-results/toolu_1.txt".format(S5, S5, S5)], others=(judge, kid))
is_("leak_scan: ... while its own transcript, its subagent's and the session's tool-results are clean", F.leaks(a, run, branch, rev("s-mine5")), [])
for label, path in (("its own session up and over to another (B)", S5 + "/../s-other/tool-results/x"),
                    ("its tool-results up and over to another session", S5 + "/tool-results/../../s-other/tool-results/x"),
                    ("its tool-results up and into a judge's transcript", S5 + "/tool-results/../subagents/agent-judge1.jsonl")):
    own_session("s-mine5", calls=[("Read", {"file_path": path})], others=(judge, kid))
    is_("leak_scan: an escape from an allowed directory is judged where it lands: {}".format(label), F.leaks(a, run, branch, rev("s-mine5")), [CLAUDE_PROJECTS])
# E: a Bash search for a root's name in its own scratch is not a read; the root itself is
is_("leak_scan: a Bash rg for a root's name in its own scratch is clean (E)",
    leaks_of(["rg -n xreview {}/dot_claude".format(run["scratch"]), "grep -rn '.claude/projects' {}".format(run["scratch"])], name="bashgrep"), [])
is_("leak_scan: ... and reading $XDG_STATE_HOME/xreview is a leak", leaks_of(["cat $XDG_STATE_HOME/xreview/ledgers/x"], name="bashxr"),
    [os.path.join(os.environ["XDG_STATE_HOME"], "xreview")])
is_("leak_scan: a Grep whose pattern names a forbidden path, in its own scratch, is clean",
    leaks_of(calls=[("Grep", {"pattern": "~/.claude/projects", "path": run["scratch"], "glob": "*.py"})], name="greppat"), [])
# a recursive search rooted at an ancestor of a forbidden root walks into it: the Grep and Glob tools by their path, or the cwd without one
USERS = os.path.dirname(os.path.expanduser("~"))
REPLAY = os.path.expanduser("~/Code/.replay")
is_("search: a Grep whose path holds the home directory (as /Users does) is a leak", leaks_of(calls=[("Grep", {"pattern": "x", "path": USERS})], name="s-users") != [], True)
is_("search: a Glob over the home directory is a leak", leaks_of(calls=[("Glob", {"pattern": "**/*.jsonl", "path": "~"})], name="s-glob") != [], True)


def at_cwd(cwd, calls, name):
    entries = [{"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "Review id: {}\n".format(jid)}]}}]
    entries += [{"type": "assistant", "cwd": cwd, "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": n, "input": i}]}} for n, i in calls]
    helpers.write_transcript(PROJECTS, KEY, "s-" + name, [], subagents=[{"id": jid, "meta": {}, "entries": entries}])
    return F.leaks(a, run, branch, os.path.join(PROJECTS, KEY, "s-" + name, "subagents", "agent-%s.jsonl" % jid))


is_("search: a Grep without a path from ~/Code/.replay (the driver's directory, above the snapshot) is a leak",
    at_cwd(REPLAY, [("Grep", {"pattern": "defect"})], "s-replay"), [os.path.expanduser("~/Code/.replay/snapshot")])
is_("search: ... and so is a Bash rg with no path there", at_cwd(REPLAY, [("Bash", {"command": "rg -n defect"})], "s-replay2"), [os.path.expanduser("~/Code/.replay/snapshot")])
is_("search: a Glob of one literal file in the home directory, without a path, walks nothing: clean",
    leaks_of(calls=[("Glob", {"pattern": os.path.expanduser("~/notes.txt")})], name="s-literal"), [])
is_("search: a Grep or Glob without a path from its own scratch is clean, and so is rg .",
    at_cwd(run["scratch"], [("Grep", {"pattern": "x"}), ("Glob", {"pattern": "**/*.py"}), ("Bash", {"command": "rg foo . && find . -name x"})], "s-scr"), [])
ALIAS_LINK = os.path.join(ROOT, "state-alias")
os.symlink(a.state, ALIAS_LINK)
is_("leak_scan: a Read through a symlink into the state is a leak", leaks_of(calls=[("Read", {"file_path": ALIAS_LINK + "/inventory/b.json"})], name="symlink"),
    [os.path.abspath(a.state)])

# ---- the reviewer's own subagents are scanned too, through the parentAgentId chain
ses = "s-sub"
head = transcript(jid, session=ses)
child = transcript("child", agent="child", parent=jid, session=ses, prompt="look", commands=["cat {}/inventory/b.json".format(a.state)])
grand = transcript("grand", agent="grand", parent="child", session=ses, prompt="look", commands=["git -C {} log".format(orig)])
stranger = transcript("stranger", agent="stranger", parent="somebody", session=ses, prompt="look", commands=["cat {}/inventory/b.json".format(a.state)])
found = F.descendants(head)
is_("subagents: the reviewer's children and their children, not an unrelated agent", sorted(os.path.basename(x) for x in found), ["agent-child.jsonl", "agent-grand.jsonl"])
got = F.leaks(a, run, branch, head)
ok("subagents: their leaks count as the reviewer's own", len(got) >= 2, got)
ses = "s-clean"
head2 = transcript(jid, session=ses)
transcript("kid", agent="kid", parent=jid, session=ses, prompt="look", commands=["git -C {} log".format(run["scratch"])])
is_("subagents: a clean child leaves the review clean", F.leaks(a, run, branch, head2), [])
sess = os.path.join(PROJECTS, KEY, "sess.jsonl")
is_("subagents: a session's own file (named by --transcript) has every subagent of that session as a descendant",
    [os.path.basename(x) for x in F.descendants(sess)], sorted(os.path.basename(x) for x in glob.glob(os.path.join(PROJECTS, KEY, "sess", "subagents", "agent-*.jsonl"))))
transcript("lonely", session="s-lonely", agent="lonely", prompt="look", commands=["cat {}/inventory/b.json".format(a.state)])
top = os.path.join(PROJECTS, KEY, "s-lonely.jsonl")
ok("subagents: a leak by a subagent of a session named by --transcript is found", F.leaks(a, run, branch, top) != [], F.leaks(a, run, branch, top))
