import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import is_, ok

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import transcripts as T  # noqa: E402

ROOT = helpers.tmp_root()
PROJECTS = os.path.join(ROOT, "projects")
STATE_HOME = os.environ["XDG_STATE_HOME"]
PROJECT = "-f-Code-repo"


def ts(minute, second=0, day=20, month=10):
    return "2026-{:02d}-{:02d}T10:{:02d}:{:02d}.000Z".format(month, day, minute, second)


def user(text, minute, cwd, blocks=False):
    content = [{"type": "text", "text": text}] if blocks else text
    return {"type": "user", "timestamp": ts(minute), "cwd": cwd, "message": {"role": "user", "content": content}}


def tool_result(minute, cwd):
    return {"type": "user", "timestamp": ts(minute), "cwd": cwd, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t", "content": "ok"}]}}


def asst(mid, text, minute, cwd, usage=None, model="claude-opus-5", second=0):
    content = [{"type": "text", "text": text}] if text is not None else [{"type": "tool_use", "id": "t", "name": "Read", "input": {}}]
    msg = {"id": mid, "role": "assistant", "model": model, "content": content}
    if usage is not None:
        msg["usage"] = usage
    return {"type": "assistant", "timestamp": ts(minute, second), "cwd": cwd, "message": msg}


def usage(i, o, cc, cr):
    return {"input_tokens": i, "output_tokens": o, "cache_creation_input_tokens": cc, "cache_read_input_tokens": cr}


def sub(aid, agent_type, description, entries, parent=None, depth=1):
    meta = {"agentType": agent_type, "description": description, "toolUseId": "toolu_" + aid, "spawnDepth": depth}
    if parent:
        meta["parentAgentId"] = parent
    return {"id": aid, "meta": meta, "entries": entries}


def review_entries(prompt, report, start, cwd):
    return [user(prompt, start, cwd), asst("m1" + report[:3], "looking", start, cwd, usage(10, 5, 100, 1000), second=10),
            tool_result(start + 1, cwd), asst("m2" + report[:3], report, start + 2, cwd, usage(20, 7, 0, 2000))]


def tree(root):
    out = []
    for d, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            st = os.lstat(p)
            out.append((os.path.relpath(p, root), st.st_size, st.st_mtime_ns))
    return sorted(out)


def run(projects, state):
    a = argparse.Namespace(state=state, projects_dir=projects, dry_run=False, snapshot_root=os.path.join(ROOT, "no-snapshot"))
    return T.cmd_snapshot(a)


# ---- a repository with a ledger, so the snapshot knows which working directories are repositories
REPO = helpers.make_repo(ROOT, "repo")
helpers.put(REPO, "a.txt", "a\n")
helpers.commit(REPO, "one")
GITDIR = C.L.common_dir(REPO)
helpers.write_ledger(STATE_HOME, REPO, [])
WORK = os.path.dirname(GITDIR)             # the repository's work dir
WT_CWD = WORK + "-feat"                    # a wt checkout
WT2_CWD = WORK + "/.claude/worktrees/x"    # a harness worktree

# ---- finds_task_reviews
SESS = "11111111-aaaa"
RE_PROMPT = ("Finding under verification (Important): the flag is ignored.\nFix base 997f08a, head edd1f33.\n"
             "Diff file: /x/review-997f08a..edd1f33.diff\n")
subs = [
    sub("r1", "sp-reviewer", "Review W2 Task 3", review_entries("Review the task.\nBASE_SHA: a1b2c3d\nHEAD_SHA: e4f5a6b\n", "Findings: none critical", 1, WT_CWD)),
    sub("r2", "sp-reviewer", "Re-review W2 Task 3 fix round 1", review_entries(RE_PROMPT, "Fixed.", 10, WT_CWD)),
    sub("r3", "sp-architect", "Review Task 4 (spec + quality)", review_entries("Review task 4", "Task 4 report", 20, WT_CWD)),
    sub("r4", "sp-reviewer", "Re-review pre-merge fix round 1", review_entries("x", "pm", 30, WT_CWD)),
    sub("r5", "sp-reviewer", "Cold review of commit x", review_entries("x", "cold", 31, WT_CWD)),
    sub("r6", "sp-architect", "Final review", review_entries("x", "final", 32, WT_CWD)),
    sub("r7", "sp-mechanical", "Review W2 Task 9", review_entries("x", "wrong agent type", 33, WT_CWD)),
]
main_entries = [user("start", 0, WT_CWD), asst("mm1", "ok", 0, WT_CWD, usage(1, 1, 1, 1))]
helpers.write_transcript(PROJECTS, PROJECT, SESS, main_entries, subs)
state = os.path.join(ROOT, "state1")
is_("snapshot exits 0", run(PROJECTS, state), 0)
doc = C.jload(os.path.join(state, "reviews.json"))
groups = {(g["session"], g["prefix"], g["task"]): g for g in doc["groups"]}
is_("finds_task_reviews: exactly the two groups (session, W2, 3) and (session, '', 4)",
    sorted(groups), [(SESS, "", 4), (SESS, "W2", 3)])
g3 = groups[(SESS, "W2", 3)]
is_("finds_task_reviews: the W2 Task 3 kinds, in time order", [r["kind"] for r in g3["reviews"]], ["review", "re-review"])
is_("finds_task_reviews: the group's project, cwd and repository", (g3["project"], g3["cwd"], g3["repo"]), (PROJECT, WT_CWD, GITDIR))
is_("finds_task_reviews: the group id is a usable id", C._ID.match(g3["id"]) is not None, True)
is_("finds_task_reviews: ids differ between groups", len({g["id"] for g in doc["groups"]}), 2)
r1, r2 = g3["reviews"]
is_("finds_task_reviews: the review's agent and description", (r1["agent"], r1["description"]), ("r1", "Review W2 Task 3"))
is_("finds_task_reviews: the prompt is the first user entry's text", r1["prompt"], "Review the task.\nBASE_SHA: a1b2c3d\nHEAD_SHA: e4f5a6b\n")
is_("finds_task_reviews: the report is the last assistant text", (r1["report"], r2["report"]), ("Findings: none critical", "Fixed."))
is_("finds_task_reviews: ranges come from the prompt", (r1["ranges"], r2["ranges"]),
    ([["a1b2c3d", "e4f5a6b"]], [["997f08a", "edd1f33"]]))
is_("finds_task_reviews: reviewed_head is the range's head", (r1["reviewed_head"], r2["reviewed_head"]), ("e4f5a6b", "edd1f33"))
is_("finds_task_reviews: model", r1["model"], "claude-opus-5")
is_("finds_task_reviews: start and end are the first and last timestamps", (r1["start"], r1["end"]), (ts(1), ts(3)))
is_("finds_task_reviews: tokens add both messages", r1["tokens"], (10 + 5 + 100 + 1000) + (20 + 7 + 0 + 2000))
g4 = groups[(SESS, "", 4)]
is_("finds_task_reviews: an sp-architect task review counts", [r["agent"] for r in g4["reviews"]], ["r3"])
rel = r1["transcript"]
copied = os.path.join(state, rel)
ok("finds_task_reviews: the reviewer's transcript is copied and its path is relative to the state",
   not os.path.isabs(rel) and os.path.isfile(copied) and rel.startswith("transcripts/" + PROJECT + "/" + SESS + "/"), rel)
ok("finds_task_reviews: its meta.json is copied beside it", os.path.isfile(copied[:-len(".jsonl")] + ".meta.json"))
ok("finds_task_reviews: the main session is copied",
   os.path.isfile(os.path.join(state, "transcripts", PROJECT, SESS + ".jsonl")))
ok("finds_task_reviews: a non-review subagent is not copied",
   not os.path.exists(os.path.join(state, "transcripts", PROJECT, SESS, "subagents", "agent-r5.jsonl")))
with open(os.path.join(PROJECTS, PROJECT, SESS, "subagents", "agent-r1.jsonl"), "rb") as f1, open(copied, "rb") as f2:
    ok("finds_task_reviews: the copy is byte-identical", f1.read() == f2.read())
before = tree(os.path.join(state, "transcripts"))
run(PROJECTS, state)
is_("a second snapshot leaves the copies as they were", tree(os.path.join(state, "transcripts")), before)

# ---- no_date_filter
SEPT = "22222222-bbbb"
sept = [user("p", 1, WORK, ), asst("s1", "old report", 2, WORK, usage(1, 1, 1, 1))]
for e in sept:
    e["timestamp"] = ts(1, month=9, day=3)
helpers.write_transcript(PROJECTS, PROJECT, SEPT, [], [sub("s9", "sp-reviewer", "Review Task 2", sept)])
state2 = os.path.join(ROOT, "state2")
run(PROJECTS, state2)
g = {(g["session"], g["prefix"], g["task"]): g for g in C.jload(os.path.join(state2, "reviews.json"))["groups"]}
ok("no_date_filter: a September reviewer is found", (SEPT, "", 2) in g, sorted(g))
ok("no_date_filter: and copied", os.path.isfile(os.path.join(state2, "transcripts", PROJECT, SEPT, "subagents", "agent-s9.jsonl")))
is_("no_date_filter: its start keeps its September date", g[(SEPT, "", 2)]["reviews"][0]["start"][:10], "2026-09-03")
is_("no_date_filter: a cwd equal to the work dir maps to the repository", g[(SEPT, "", 2)]["repo"], GITDIR)

# ---- nested_controller_copied
NEST = "33333333-cccc"
ctl = sub("aCTRL", "sp-standard", "Run plan W2", [user("run the plan", 1, WT_CWD), asst("c1", "dispatching", 2, WT_CWD, usage(1, 1, 1, 1))])
nested = sub("rNEST", "sp-reviewer", "Review W3 Task 5", review_entries("Review.\nFIX_BASE=abc1234 and later HEAD=def5678\n", "nested report", 3, WT_CWD),
             parent="aCTRL", depth=2)
other = sub("aOTHER", "sp-standard", "Another controller", [user("x", 1, WT_CWD)])
helpers.write_transcript(PROJECTS, PROJECT, NEST, [user("go", 0, WT_CWD)], [ctl, nested, other])
state3 = os.path.join(ROOT, "state3")
run(PROJECTS, state3)
g = {(g["session"], g["prefix"], g["task"]): g for g in C.jload(os.path.join(state3, "reviews.json"))["groups"]}
ok("nested_controller_copied: the nested reviewer is found", (NEST, "W3", 5) in g, sorted(g))
sdir = os.path.join(state3, "transcripts", PROJECT, NEST)
ok("nested_controller_copied: the controller's transcript and meta are copied",
   os.path.isfile(os.path.join(sdir, "subagents", "agent-aCTRL.jsonl")) and os.path.isfile(os.path.join(sdir, "subagents", "agent-aCTRL.meta.json")))
ok("nested_controller_copied: and the main session's", os.path.isfile(os.path.join(state3, "transcripts", PROJECT, NEST + ".jsonl")))
ok("nested_controller_copied: an unrelated controller is not", not os.path.exists(os.path.join(sdir, "subagents", "agent-aOTHER.jsonl")))
is_("nested_controller_copied: the nested reviewer's range is read", g[(NEST, "W3", 5)]["reviews"][0]["ranges"], [["abc1234", "def5678"]])

# ---- a controller chain two levels up, and a parent that is missing
CH = "44444444-dddd"
c1 = sub("aTop", "sp-standard", "Top", [user("x", 1, WT_CWD)])
c2 = sub("aMid", "sp-standard", "Mid", [user("x", 1, WT_CWD)], parent="aTop", depth=2)
lost = sub("rLost", "sp-reviewer", "Review Task 1", review_entries("p", "r", 2, WT_CWD), parent="aGone", depth=2)
deep = sub("rDeep", "sp-reviewer", "Review Task 2", review_entries("p", "r", 5, WT_CWD), parent="aMid", depth=3)
helpers.write_transcript(PROJECTS, PROJECT, CH, [user("go", 0, WT_CWD)], [c1, c2, lost, deep])
state4 = os.path.join(ROOT, "state4")
is_("a parent id with no transcript does not fail the snapshot", run(PROJECTS, state4), 0)
cdir = os.path.join(state4, "transcripts", PROJECT, CH, "subagents")
ok("nested_controller_copied: the whole chain above a reviewer is copied",
   all(os.path.isfile(os.path.join(cdir, "agent-{}.jsonl".format(x))) for x in ("aMid", "aTop", "rDeep", "rLost")))

# ---- ranges_table
for name, text, want in [
    ("prose", "Fix base 997f08a, head edd1f33.", [("997f08a", "edd1f33")]),
    ("diff file name", "Diff file: /x/y/review-997f08a..edd1f33.diff", [("997f08a", "edd1f33")]),
    ("three dots in the file name", "review-997f08a...edd1f33.diff", [("997f08a", "edd1f33")]),
    ("FIX_BASE and HEAD", "FIX_BASE=abc1234 … HEAD=def5678", [("abc1234", "def5678")]),
    ("FIX_BASE and HEAD across lines", "FIX_BASE=abc1234\nsome words\nHEAD=def5678\n", [("abc1234", "def5678")]),
    ("BASE_SHA and HEAD_SHA", "BASE_SHA: a1b2c3d\nHEAD_SHA: e4f5a6b", [("a1b2c3d", "e4f5a6b")]),
    ("the same range three ways is listed once",
     "Fix base 997f08a, head edd1f33. Diff file: review-997f08a..edd1f33.diff FIX_BASE=997f08a HEAD=edd1f33", [("997f08a", "edd1f33")]),
    ("two different ranges keep their order", "Fix base 1111111, head 2222222.\nFix base 3333333, head 4444444.",
     [("1111111", "2222222"), ("3333333", "4444444")]),
    ("full length SHAs", "Fix base {}, head {}.".format("a" * 40, "b" * 40), [("a" * 40, "b" * 40)]),
    ("upper case is lowered", "Fix base ABCDEF1, head 1234ABC.", [("abcdef1", "1234abc")]),
    ("a six digit word is no SHA", "Fix base 99f08a, head edd1f3.", []),
    ("Markdown list with colons", "- Fix base: 7342495\n- Head: b52b520", [("7342495", "b52b520")]),
    ("bold label then a later Head line",
     "**Fix base:** 7342495 (the head the previous review saw)\n- Diff: review-7342495..b52b520.diff\nHead: b52b520", [("7342495", "b52b520")]),
    ("bold labels in a list", "- **Base:** 669fd2c\n- **Head:** e4dfa89", [("669fd2c", "e4dfa89")]),
    ("a bare range in parentheses", "Review the change (669fd2c..e4dfa89) please", [("669fd2c", "e4dfa89")]),
    ("lower case base_sha and head_sha", "base_sha: a1b2c3d\nhead_sha: e4f5a6b", [("a1b2c3d", "e4f5a6b")]),
    ("a head with no base is no range", "Head: b52b520", []),
    ("base HEAD in prose about uncommitted work is no range", "The change is uncommitted (base HEAD 13ca7437)", []),
    ("plain spaces do not make Base and Head labels", "Base 1111111 and Head 2222222", []),
    ("bracketed labels", "[FIX_BASE_SHA]: 1111111\n[HEAD_SHA]: 2222222", [("1111111", "2222222")]),
    ("labelled outranks a diff file name",
     "- BASE_SHA: 8672e38c. HEAD_SHA: 6b364a90.\n- DIFF_FILE: `x/review-8672e38c..6b364a90.diff`\nIts diff is `x/review-vminference-a2fa02f..4bf2a83.diff`.",
     [("8672e38c", "6b364a90")]),
    ("a diff file name outranks mentioned bare ranges",
     "MR ranges: plan 1 b7cec6c7..add5fe12, 141be49c..e2bed282\nreview-vminference-a2fa02f..4bf2a83.diff", [("a2fa02f", "4bf2a83")]),
    ("mentioned bare ranges when nothing stronger", "MR ranges: plan 1 b7cec6c7..add5fe12, 141be49c..e2bed282",
     [("b7cec6c7", "add5fe12"), ("141be49c", "e2bed282")]),
    ("a head followed by ^ is no range", "see 1111111..2222222^ and 3333333..4444444~2", []),
    ("a labelled range outranks a diff-file name for the same commits",
     "**Base:** 18f644e\n**Head:** ab58108\nreview-18f644e8..ab58108c.diff", [("18f644e", "ab58108")]),
    ("one pair at two lengths in the same source",
     "Fix base: 18f644e, Head: ab58108\nFix base: 18f644e8 Head: ab58108c", [("18f644e8", "ab58108c")]),
    ("a prose word after base is no range", "the base branch is main; head of the work is fine", []),
    ("none", "Review the task carefully. Nothing about commits.", []),
    ("empty", "", []),
]:
    is_("ranges_table: " + name, T.parse_ranges(text), want)
is_("ranges_table: a list of tuples", all(isinstance(r, tuple) for r in T.parse_ranges("Fix base 997f08a, head edd1f33.")), True)

# ---- reviewed_head and reviewed_commits
is_("reviewed_head: the head of the range", T.reviewed_head(RE_PROMPT), "edd1f33")
is_("reviewed_head: the last range's head", T.reviewed_head("Fix base 1111111, head 2222222. Fix base 3333333, head 4444444."), "4444444")
is_("reviewed_head: a lone HEAD_SHA", T.reviewed_head("HEAD_SHA: e4f5a6b"), "e4f5a6b")
is_("reviewed_head: none", T.reviewed_head("Review the task."), None)
is_("reviewed_head: Markdown labels", T.reviewed_head("- Fix base: 7342495\n- Head: b52b520"), "b52b520")
for name, text, commits, head in [
    ("a task commit", "Review Task 4 (commit 97fe373)", ["97fe373"], "97fe373"),
    ("a diff by git show", "Diff (commit 97fe373 via `git show`)", ["97fe373"], "97fe373"),
    ("two commits", "Diff (commits 97fe373 and 1a2b3c4 \u2026)", ["97fe373", "1a2b3c4"], None),
    ("a comma list", "commits 97fe373, 1a2b3c4 and 5d6e7f8", ["97fe373", "1a2b3c4", "5d6e7f8"], None),
    ("a diff file with its commit", "Diff file: /x/review-97fe373.diff (commit 97fe373)", ["97fe373"], "97fe373"),
    ("a bare range", "Diff (669fd2c..e4dfa89)", ["e4dfa89"], "e4dfa89"),
    ("a range outranks a commit", "Fix base 1111111, head 2222222. Also commit 3333333.", ["2222222"], "2222222"),
    ("a commit list with parentheticals", "Commits a765639 (the case) and d11eaed (the bytecode fix)", ["a765639", "d11eaed"], None),
    ("a backticked commit list", "commits `97fe373` and `1a2b3c4`", ["97fe373", "1a2b3c4"], None),
    ("the fix commit is", "The fix commit is af20a74", ["af20a74"], "af20a74"),
    ("a follow-up commit", "a follow-up commit, 573acfa", ["573acfa"], "573acfa"),
    ("uncommitted work with base HEAD", "The change is uncommitted (base HEAD 13ca7437)", [], None),
    ("the same commit at two lengths", "commits 18f644e and 18f644e8", ["18f644e8"], "18f644e8"),
    ("a lone HEAD_SHA is a commit, weaker than a diff file name", "HEAD_SHA: 6b364a90\nsee review-vminference-a2fa02f..4bf2a83.diff", ["4bf2a83"], "4bf2a83"),
    ("a backticked commit", "Review commit `97fe373`.", ["97fe373"], "97fe373"),
    ("a commit word with no SHA", "Review the commit message and commit history.", [], None),
    ("uncommitted work", "Review the working tree changes for Task 4.", [], None),
]:
    is_("reviewed_commits: " + name, T.reviewed_commits(text), commits)
    is_("reviewed_head: " + name, T.reviewed_head(text), head)

# ---- repo_for_cwd_prefix
REPOS = ["/f/Code/repo/.git", "/f/Code/repo-extra/.git", "/f/Code/other.git"]
is_("repo_for_cwd_prefix: wt checkout", T.repo_for_cwd("/f/Code/repo-feat", ["/f/Code/repo/.git"]), "/f/Code/repo/.git")
is_("repo_for_cwd_prefix: harness worktree", T.repo_for_cwd("/f/Code/repo/.claude/worktrees/x", ["/f/Code/repo/.git"]), "/f/Code/repo/.git")
is_("repo_for_cwd_prefix: the work dir itself", T.repo_for_cwd("/f/Code/repo", ["/f/Code/repo/.git"]), "/f/Code/repo/.git")
is_("repo_for_cwd_prefix: repox is not repo", T.repo_for_cwd("/f/Code/repox", ["/f/Code/repo/.git"]), None)
is_("repo_for_cwd_prefix: an unrelated directory", T.repo_for_cwd("/elsewhere", ["/f/Code/repo/.git"]), None)
is_("repo_for_cwd_prefix: the longest work dir wins", T.repo_for_cwd("/f/Code/repo-extra-w", REPOS), "/f/Code/repo-extra/.git")
is_("repo_for_cwd_prefix: and repo-extra still matches repo-extra", T.repo_for_cwd("/f/Code/repo-extra", REPOS), "/f/Code/repo-extra/.git")
is_("repo_for_cwd_prefix: a bare name.git has its work dir without .git", T.repo_for_cwd("/f/Code/other-x", REPOS), "/f/Code/other.git")
is_("repo_for_cwd_prefix: no cwd", T.repo_for_cwd(None, REPOS), None)
is_("repo_for_cwd_prefix: no repos", T.repo_for_cwd("/f/Code/repo", []), None)
g = {(g["session"], g["prefix"], g["task"]): g for g in C.jload(os.path.join(state, "reviews.json"))["groups"]}
is_("repo_for_cwd_prefix: a worktree session's group maps to its repository", g[(SESS, "W2", 3)]["repo"], GITDIR)

# ---- cost_dedupes_messages
cpath = os.path.join(ROOT, "cost.jsonl")
rows = [
    user("hi", 1, WORK),
    asst("dup", "partial", 2, WORK, usage(10, 1, 100, 1000), second=5),
    asst("dup", None, 2, WORK, usage(10, 9, 100, 1000), second=30),
    asst("solo", "end", 4, WORK, usage(1, 2, 3, 4), second=2),
    {"type": "system", "timestamp": ts(5), "message": {}},
    {"type": "user", "cwd": WORK, "message": {"content": "no timestamp"}},
]
with open(cpath, "w") as f:
    f.write("".join(json.dumps(r) + "\n" for r in rows) + "not json\n")
c = T.cost(cpath)
is_("cost_dedupes_messages: one message id counts once (its last, complete usage) and tokens add all four kinds",
    c["tokens"], (10 + 9 + 100 + 1000) + (1 + 2 + 3 + 4))
is_("cost_dedupes_messages: start and end are the first and last timestamps", (c["start"], c["end"]), (ts(1), ts(5)))
empty = os.path.join(ROOT, "empty.jsonl")
open(empty, "w").close()
is_("cost: an empty transcript costs nothing", T.cost(empty), {"tokens": 0, "start": None, "end": None})
is_("cost: a missing transcript costs nothing", T.cost(os.path.join(ROOT, "nope.jsonl")), {"tokens": 0, "start": None, "end": None})

# ---- text shapes: blocks content, streamed report text, tool-use-only last message
SH = "55555555-eeee"
shape = [
    user("", 1, WORK),
    user("block prompt", 1, WORK, blocks=True),
    asst("a", "first", 2, WORK, usage(1, 1, 1, 1)),
    asst("b", "part one.", 3, WORK, usage(1, 1, 1, 1)),
    asst("b", "part two.", 3, WORK, usage(1, 2, 1, 1), second=5),
    asst("c", None, 4, WORK, usage(1, 1, 1, 1)),
]
helpers.write_transcript(PROJECTS, PROJECT, SH, [], [sub("rS", "sp-reviewer", "Review Task 7", shape)])
state5 = os.path.join(ROOT, "state5")
run(PROJECTS, state5)
rv = [g for g in C.jload(os.path.join(state5, "reviews.json"))["groups"] if g["session"] == SH][0]["reviews"][0]
is_("text: the prompt is the first user entry with text, from blocks", rv["prompt"], "block prompt")
is_("text: the report is the last assistant text, a streamed message joined", rv["report"], "part one.\npart two.")
is_("text: tokens count the streamed message once and the tool-use message", rv["tokens"], 4 + 5 + 4)

# ---- the report is the SubagentHandback message
HB = "77777777-aaaa"


def handback(mid, message, minute, name="SubagentHandback"):
    return {"type": "assistant", "timestamp": ts(minute), "cwd": WORK, "message": {
        "id": mid, "role": "assistant", "model": "claude-opus-5", "usage": usage(1, 1, 1, 1),
        "content": [{"type": "tool_use", "id": "tu_" + mid, "name": name, "input": {"message": message}}]}}


with_hb = [user("Review Task 8 (commit 97fe373)", 1, WORK), asst("h1", "Thinking about it.", 2, WORK, usage(1, 1, 1, 1)),
           handback("h2", "early draft", 3), tool_result(4, WORK),
           asst("h3", "I will now report.", 5, WORK, usage(1, 1, 1, 1)), handback("h4", "## Findings\n- Important: x is wrong", 6)]
ends_text = [user("Review Task 9", 1, WORK), handback("e1", "not the report: a handback earlier than the last text is still the handback", 2),
             asst("e2", "closing words", 3, WORK, usage(1, 1, 1, 1))]
other_tool = [user("Review Task 10", 1, WORK), handback("o1", "wrong tool", 2, name="SendMessage"), asst("o2", "plain closing", 3, WORK, usage(1, 1, 1, 1))]
helpers.write_transcript(PROJECTS, PROJECT, HB, [], [sub("hb1", "sp-reviewer", "Review Task 8", with_hb),
                                                     sub("hb2", "sp-reviewer", "Review Task 9", ends_text),
                                                     sub("hb3", "sp-reviewer", "Review Task 10", other_tool)])
state_hb = os.path.join(ROOT, "state-hb")
run(PROJECTS, state_hb)
hbg = {g["task"]: g["reviews"][0] for g in C.jload(os.path.join(state_hb, "reviews.json"))["groups"] if g["session"] == HB}
is_("handback: the report is the last SubagentHandback call's message, not a text before it", hbg[8]["report"], "## Findings\n- Important: x is wrong")
is_("handback: a handback wins over a later plain text", hbg[9]["report"], ends_text[1]["message"]["content"][0]["input"]["message"])
is_("handback: another tool's message is no report, so the last text is", hbg[10]["report"], "plain closing")
is_("handback: reviewed_commits and reviewed_head are recorded per review", (hbg[8]["reviewed_commits"], hbg[8]["reviewed_head"]), (["97fe373"], "97fe373"))
is_("handback: a prompt naming no commit has none", (hbg[9]["reviewed_commits"], hbg[9]["reviewed_head"]), ([], None))
is_("handback: a plain-text reviewer still reports its last text (fixture r1)", r1["report"], "Findings: none critical")

# ---- a copy that fails leaves no temp file
src = os.path.join(ROOT, "src.txt")
open(src, "w").write("x")
cdest = os.path.join(ROOT, "cdest", "f.txt")
real_copy2 = T.shutil.copy2


def boom(a_, b_):
    open(b_, "w").write("partial")
    raise OSError("disk full")


T.shutil.copy2 = boom
try:
    T._copy(src, cdest)
except OSError:
    pass
T.shutil.copy2 = real_copy2
is_("copy failure: no temp file is left behind", os.listdir(os.path.dirname(cdest)), [])

# ---- a group whose reviewer has no cwd is not given a repository; a bad meta is skipped
NC = "66666666-ffff"
nocwd = [{"type": "user", "timestamp": ts(1), "message": {"content": "p"}},
         {"type": "assistant", "timestamp": ts(2), "message": {"id": "z", "model": "m", "content": [{"type": "text", "text": "r"}], "usage": usage(1, 1, 1, 1)}}]
helpers.write_transcript(PROJECTS, PROJECT, NC, [], [sub("rN", "sp-reviewer", "Review Task 1", nocwd)])
badmeta = os.path.join(PROJECTS, PROJECT, NC, "subagents", "agent-bad.meta.json")
with open(badmeta, "w") as f:
    f.write("{not json")
with open(os.path.join(PROJECTS, PROJECT, NC, "subagents", "agent-bad.jsonl"), "w") as f:
    f.write("")
state6 = os.path.join(ROOT, "state6")
is_("a meta.json that does not parse is skipped", run(PROJECTS, state6), 0)
gnc = [g for g in C.jload(os.path.join(state6, "reviews.json"))["groups"] if g["session"] == NC][0]
is_("no cwd: the group has none and no repository", (gnc["cwd"], gnc["repo"]), (None, None))

# ---- read_only
snap = tree(PROJECTS)
run(PROJECTS, os.path.join(ROOT, "state7"))
is_("read_only: the projects dir's listing is unchanged", tree(PROJECTS), snap)

# ---- dry run writes nothing
state8 = os.path.join(ROOT, "state8")
a = argparse.Namespace(state=state8, projects_dir=PROJECTS, dry_run=True, snapshot_root=os.path.join(ROOT, "no-snapshot"))
is_("dry run exits 0", T.cmd_snapshot(a), 0)
ok("dry run writes neither reviews.json nor transcripts", not os.path.exists(state8) or os.listdir(state8) == [], os.listdir(state8) if os.path.exists(state8) else "")

# ---- an empty projects dir
state9 = os.path.join(ROOT, "state9")
os.makedirs(os.path.join(ROOT, "empty-projects"))
is_("an empty projects dir yields no groups", (run(os.path.join(ROOT, "empty-projects"), state9), C.jload(os.path.join(state9, "reviews.json"))), (0, {"groups": []}))
