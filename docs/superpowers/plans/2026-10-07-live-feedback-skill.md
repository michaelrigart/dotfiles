# Live-feedback mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented — completed 2026-10-07; do not run again
**Goal:** Ship a `live-feedback` skill. While Michael tests a running app by hand, it
sends each change request to a background subagent, so the main session answers in one
line and is free for his next point.

**Architecture:** One skill file holds the driver's whole protocol: entry, message
handling, request ids and ledger, tiered dispatch with escalation, the agent contract,
landing, quiescence commits and exit. A static suite pins everything the skill names.
Writing-skills pressure scenarios test the behaviour: each runs once without the skill
(RED) and once with it (GREEN).

**Tech Stack:** Markdown skill (Claude Code `SKILL.md` with frontmatter), bash test suite
(`tests/*.test.sh`, `./tests/run.sh`), chezmoi source layout, `/usr/bin/lockf`.

**Spec:** `docs/superpowers/specs/2026-10-07-live-feedback-skill-design.md`

## Global Constraints

- Work on branch `feat/live-feedback-skill`. This checkout is shared: run
  `git branch --show-current` immediately before every `git add`/`git commit` and stop
  if it is not that branch.
- Never run `chezmoi apply`, never push, never touch `~/.claude` directly; edit only the
  chezmoi source tree.
- `~/.claude` is an allowlist in `.chezmoiignore`: the new skill needs its own three
  `!`/ignore lines, one level at a time, like `cross-review`.
- Test suites: shebang `#!/usr/bin/env bash`, git mode 755 (`git add --chmod=+x`), exit 2
  when the file under test is missing, `  PASS: …` / `  FAIL: …` lines, end with
  `passed: N  failed: M` and a non-zero exit when anything failed.
- Execute suites directly (`./tests/x.test.sh`), never `bash tests/x.test.sh`.
- Temp dirs in suites: `mktemp -d "${TMPDIR:-/tmp}/<name>.XXXXXX"`. A bare `mktemp -d`
  ignores `TMPDIR` on macOS and the sandbox denies it.
- The skill implements spec sections 3.1–3.8 exactly. Wording may change while closing
  scenario failures (Task 3). Behaviour may not: nothing the spec does not say may be
  added.
- The agent tiers are exactly `sp-mechanical`, `sp-standard`, `sp-architect`;
  `sp-reviewer` is never dispatched.
- The lock command is exactly
  `lockf -k -t 900 "$(git rev-parse --git-common-dir)/live-feedback.lock" <command>`.
- The baseline command is exactly `git status --porcelain --untracked-files=all`.
- Commit messages: imperative mood, no prefix convention, no agent attribution of any
  kind.
- Scenario transcripts and grades go to `docs/superpowers/runs/2026-10-07-live-feedback/`
  (gitignored, never committed).
- Report test totals as passed/total.

## Review Focus

- A repository with no `origin/HEAD`, on `main`, must be treated as the default branch:
  no commits all mode, said once at entry. (Task 3, scenario S0b)
- Inside a `wt` worktree, `git rev-parse --git-common-dir` is an absolute path into the
  main checkout's `.git`. The lock must land there, so worktrees sharing a database
  share the lock. (Task 2, suite section "the lock")
- A report that omits its `Ids covered` line must leave its point in flight, not land
  it, and the driver must ask that agent. (Task 3, scenario S15)
- Michael answering a stopped point's question must reach the same agent under a new
  sub-id, and the point must stay uncommitted until that agent reports it finished.
  (Task 3, scenario S16)
- Michael dropping a stopped point must make its agent undo its partial edits. Nothing
  sharing those files commits until the undo is reported. (Task 3, scenario S17)

---

### Task 1: Baseline pressure runs (RED)

Driver-run: each subject is one `general-purpose` subagent (it inherits the driver's
model), dispatched by the driver. A subagent cannot dispatch these itself. No files
change and nothing is committed.

**Files:**
- Create (untracked): `docs/superpowers/runs/2026-10-07-live-feedback/baseline/S<id>.md`
  for each scenario, holding the subject's answer and its grade.

**Interfaces:**
- Consumes: the scenario catalogue in Appendix A (preamble, per-scenario state and
  message, pass criteria).
- Produces: one baseline grade per scenario (PASS/FAIL per criterion, with the subject's
  words quoted for each FAIL). Task 3 compares against it.

- [ ] **Step 1: Run every scenario without the skill**

For each scenario in Appendix A (S0, S0b, S1–S17), dispatch a `general-purpose`
subagent. Its prompt is the **Subject preamble** followed by the scenario's **State
(baseline arm)** and **Event**, with no skill text. Dispatch in batches of up to ten, in
one message per batch.

- [ ] **Step 2: Grade each answer**

Grade each criterion in the scenario's **Pass** list as PASS or FAIL. A FAIL quotes the
subject's line that fails it. Write the answer and grade to
`docs/superpowers/runs/2026-10-07-live-feedback/baseline/S<id>.md`.

- [ ] **Step 3: Summarise the baseline**

Write `docs/superpowers/runs/2026-10-07-live-feedback/baseline/SUMMARY.md` with one line
per scenario (`S1: FAIL — edited the view inline, no dispatch`). Expected: most scenarios
FAIL. Every one that PASSes needs a sentence explaining why the default behaviour
already holds; that scenario then guards against regressions, not for the skill's value.

---

### Task 2: The skill, its deployment, and the static suite

Implementer tier: `sp-mechanical` (exact content below).

**Files:**
- Create: `tests/live-feedback-skill.test.sh` (mode 755)
- Create: `dot_claude/skills/live-feedback/SKILL.md`
- Modify: `.chezmoiignore` (after the three `cross-review` skill lines, currently lines
  89–91)
- Modify: `docs/superpowers/specs/2026-10-07-live-feedback-skill-design.md` (line 3,
  Status)
- Modify: `docs/superpowers/plans/2026-10-07-live-feedback-skill.md` (Status line)

**Interfaces:**
- Consumes: nothing from Task 1 (its findings shape Task 3's revisions, not this text).
- Produces: `dot_claude/skills/live-feedback/SKILL.md`, the exact text Task 3's subjects
  receive; `tests/live-feedback-skill.test.sh`, green.

- [ ] **Step 1: Write the failing suite**

Create `tests/live-feedback-skill.test.sh`:

~~~bash
#!/usr/bin/env bash
# Tests that dot_claude/skills/live-feedback/SKILL.md deploys, and that everything it
# names exists. The skill is executable documentation: a tier that is not an agent type,
# a lock command lockf rejects, or a baseline that collapses untracked directories is a
# wrong instruction that gets followed. One direction only, as in xreview-skill.test.sh:
# what the skill names must exist.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/dot_claude/skills/live-feedback/SKILL.md"
AGENTS="$ROOT/dot_claude/agents"
[ -f "$SKILL" ] || { echo "missing file under test: $SKILL" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | %s\n' "$1" "$2"; fail=$((fail + 1)); }
T="$(mktemp -d "${TMPDIR:-/tmp}/live-feedback-skill.XXXXXX")"; trap 'rm -rf "$T"' EXIT

# --- frontmatter ----------------------------------------------------------------
front="$(awk 'NR==1 && $0=="---" {f=1; next} f && $0=="---" {exit} f' "$SKILL")"
if printf '%s\n' "$front" | grep -qx 'name: live-feedback'; then
  _pass "frontmatter name is live-feedback, matching its directory"
else
  _fail "frontmatter name is live-feedback, matching its directory" \
        "$(printf '%s\n' "$front" | grep '^name:' || echo 'no name: line')"
fi
if printf '%s\n' "$front" | grep -qE '^description: .{40,}'; then
  _pass "frontmatter carries a description"
else
  _fail "frontmatter carries a description" "missing or shorter than 40 characters"
fi

# --- deployment -----------------------------------------------------------------
# .chezmoiignore is an allowlist for ~/.claude: without its own entries the skill never
# deploys, and every other check here would still pass.
managed="$(chezmoi --source "$ROOT" managed 2>/dev/null)"
if printf '%s\n' "$managed" | grep -qx '.claude/skills/live-feedback/SKILL.md'; then
  _pass "chezmoi manages .claude/skills/live-feedback/SKILL.md"
else
  _fail "chezmoi manages .claude/skills/live-feedback/SKILL.md" \
        "not in \`chezmoi managed\` - a .chezmoiignore allowlist entry is missing"
fi

# --- agent tiers ----------------------------------------------------------------
tiers="$(grep -oE '\bsp-[a-z]+' "$SKILL" | sort -u)"
[ -n "$tiers" ] || { echo "SKILL.md names no sp-* agent type - the extractor is broken" >&2; exit 1; }
for t in $tiers; do
  f="$AGENTS/$t.md"
  if [ -f "$f" ] && grep -qx "name: $t" "$f"; then
    _pass "agent type $t exists with a matching name:"
  else
    _fail "agent type $t exists with a matching name:" "no $f, or its name: line differs"
  fi
done
for t in sp-mechanical sp-standard sp-architect; do
  if printf '%s\n' "$tiers" | grep -qx "$t"; then _pass "the skill offers tier $t"
  else _fail "the skill offers tier $t" "not named in SKILL.md"; fi
done

# --- the lock -------------------------------------------------------------------
lockline="$(grep -oE 'lockf [^"]*"\$\(git rev-parse --git-common-dir\)/live-feedback\.lock"' "$SKILL" | head -1)"
if [ -n "$lockline" ]; then
  _pass "the lock sits in the git common directory"
else
  _fail "the lock sits in the git common directory" \
        "no 'lockf … \"\$(git rev-parse --git-common-dir)/live-feedback.lock\"' in SKILL.md"
fi
if command -v lockf >/dev/null 2>&1; then _pass "lockf is on PATH"
else _fail "lockf is on PATH" "not found"; fi
if [ -n "$lockline" ] && command -v lockf >/dev/null 2>&1; then
  flags="$(printf '%s' "$lockline" | sed -E 's/^lockf (.*) "\$\(git rev-parse.*$/\1/')"
  # shellcheck disable=SC2086 # the flags are words on purpose
  lockf $flags "$T/plain.lock" true; rc=$?
  if [ "$rc" = 0 ]; then _pass "the skill's lockf flags run a command"
  else _fail "the skill's lockf flags run a command" "exit $rc"; fi
  # shellcheck disable=SC2086
  lockf $flags "$T/plain.lock" sh -c 'exit 3'; rc=$?
  if [ "$rc" = 3 ]; then _pass "lockf passes the command's exit status through"
  else _fail "lockf passes the command's exit status through" "exit $rc, expected 3"; fi
  # wt worktrees of one repository share a database, so they must share the lock: from
  # a linked worktree the common directory is the main checkout's .git.
  git init -q "$T/main" \
    && git -C "$T/main" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
    && git -C "$T/main" worktree add -q "$T/wt" -b wt-branch 2>/dev/null
  common="$(git -C "$T/wt" rev-parse --git-common-dir 2>/dev/null)"
  # shellcheck disable=SC2086
  if [ -n "$common" ] && lockf $flags "$common/live-feedback.lock" true \
     && [ -f "$T/main/.git/live-feedback.lock" ]; then
    _pass "from a linked worktree the lock lands in the main checkout's .git"
  else
    _fail "from a linked worktree the lock lands in the main checkout's .git" \
          "common dir '$common'; no $T/main/.git/live-feedback.lock"
  fi
fi

# --- the baseline ---------------------------------------------------------------
# Without --untracked-files=all an untracked directory collapses to one "dir/" line, so
# Michael's files inside it would not match an exclusion by path.
if grep -qF 'git status --porcelain --untracked-files=all' "$SKILL"; then
  _pass "the baseline lists every untracked file"
else
  _fail "the baseline lists every untracked file" "no 'git status --porcelain --untracked-files=all'"
fi
bare="$(grep -nF 'git status --porcelain' "$SKILL" | grep -vF -- '--untracked-files=all')"
if [ -z "$bare" ]; then
  _pass "no git status --porcelain without --untracked-files=all"
else
  _fail "no git status --porcelain without --untracked-files=all" "$bare"
fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
~~~

Then: `chmod 755 tests/live-feedback-skill.test.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/live-feedback-skill.test.sh; echo "exit=$?"`
Expected: `missing file under test: …/SKILL.md` and `exit=2`.

- [ ] **Step 3: Add the allowlist entries**

In `.chezmoiignore`, directly after `!.claude/skills/cross-review/SKILL.md`, add:

~~~
!.claude/skills/live-feedback/
.claude/skills/live-feedback/*
!.claude/skills/live-feedback/SKILL.md
~~~

- [ ] **Step 4: Write the skill**

Create `dot_claude/skills/live-feedback/SKILL.md` with exactly this content:

~~~markdown
---
name: live-feedback
description: Use when Michael is testing a running app by hand and gives change requests as he goes, says he is live-testing or manually testing, or runs /live-feedback. "/live-feedback done" or "done testing" ends it.
---

# Live feedback

Michael is testing the running app and sending changes one after another. In this mode
your job is to stay free for his next point. Every change goes to a background agent,
and your turn ends with a one-line ack. You coordinate. You do not edit code, you do not
read code to find where a change goes, and you never wait for an agent.

## Entry

1. Record the **baseline**, Michael's own uncommitted work, which you never commit:
   `git status --porcelain --untracked-files=all`. Without the flag, an untracked
   directory collapses to one `dir/` line, and a file inside it would not match an
   exclusion by path.
2. Record the branch: `git branch --show-current`. Find the default branch with
   `git symbolic-ref --quiet --short refs/remotes/origin/HEAD` (strip `origin/`). With no
   remote HEAD, treat `main` or `master` as the default. On the default branch, commit
   nothing for the whole mode.
3. Reply with one line:
   `Live-feedback on: each change goes to a background agent; fixes are committed on <branch>.`
   On the default branch:
   `Live-feedback on: each change goes to a background agent; <branch> is the default branch, so nothing gets committed.`

## Each message

| Message | Do |
|---|---|
| A clear change request | Brief and dispatch an agent, ack in one line, end the turn |
| Ambiguous request | Ask one question; dispatch once answered |
| Follow-up on an earlier point (in flight, landed or stopped) | `SendMessage` to that point's agent under a new sub-id |
| Same page, component or reported files as a point in flight or stopped | Queue it behind that point |
| Needs a design decision (new flow, scope change) | Park it, say so in one line, never dispatch it |
| A question | Answer inline only if this conversation already holds the answer; otherwise dispatch a background `Explore` agent and relay its answer when it returns |
| "What's in flight?" | The ledger as a table: #, state, tier, summary, files |

Judge ambiguity from Michael's words alone. Never read or search code before
dispatching. Finding the code is the agent's job, and investigating brings back the wait
this mode exists to remove.

Line formats:

- ack: `#3 → sp-standard: disable Save until the form is valid`
- queued: `#4 queued behind #3 (same form)`
- parked: `#5 parked: a wizard instead of one form is a design decision, for after testing`

## Request ids and the ledger

Every point gets the next number. Every message you send an agent carries a request id:
the point number for a point's first brief (`#3`, or `#5` for a queued point handed to
`#3`'s agent), and a sub-id for anything after that (`#3.1`, `#3.2`).

The ledger lives in this conversation. Every ack, landing and commit line repeats the
point numbers, so a compacted summary keeps it. For each point it holds the state, the
tier, the owning agent, the ids sent, the files reported and the latest status.
States:

- **queued**: accepted, waiting for a free slot or for the point ahead of it in its area
- **in flight**: one of its ids is unanswered
- **landed**: its status is finished; not yet committed
- **committed**: in a commit
- **stopped**: its agent stopped with a question for Michael, possibly after editing
  files
- **parked**: needs a design decision; never dispatched

An agent is **busy** while any id sent to it is unanswered.

## Dispatch

Dispatch with the Agent tool, which runs agents in the background. At most four agents
are busy at once. Further points queue and dispatch as agents finish.

Pick the tier from the task, judging from Michael's words:

- `sp-mechanical`: the point names both the exact change and the place.
- `sp-standard`: the code must be located or a pattern matched, or a bug's cause is
  unknown. This is the default when you are unsure.
- `sp-architect`: the point cuts across many parts of the app, or is a bug a lower tier
  already failed to crack.

Never dispatch `sp-reviewer`, which does not edit. The tier is about difficulty only.
No tier makes a design decision for Michael; that is what parking is for.

The brief must be self-contained, because the agent cannot see this conversation:

```
Live-feedback request <id>. Michael is testing the running app by hand.

His words: "<verbatim>"
Expected result: <one line>
Where: <page, URL or screen, as he gave it>
Files earlier reports listed for this area: <paths, or "none">

<the agent contract below, in full>
```

### Escalation

An agent reporting a point as beyond its tier is not asking Michael anything. Move a
point only away from an idle agent. While any id sent to the old agent is unanswered,
the point stays in flight with it. Once that agent is idle and the point's status is
beyond tier, dispatch a new agent one tier up under a new sub-id. Its brief adds:

- Michael's words for every id of the point, follow-ups included
- every report of the old agent
- the files it already edited, which the new agent continues from

From then on the new agent owns the point. Follow-ups and points queued behind it go to
the new agent, and the old agent gets nothing further. An `sp-architect` agent that
reports beyond tier has nowhere to go: relay it to Michael as a question.

Line: `#3 ↑ sp-architect: the totals bug spans the invoice and payment models`

## Overlap

- Area routing (above) keeps two agents off one page or component. When the point ahead
  lands or is resolved, hand the queued point to the same agent with `SendMessage`.
- The contract's Edit-only rule makes a collision on a shared file fail loudly instead of
  overwriting the other agent's change.
- Translation files and shared stylesheets still get touched by unrelated points. That
  is safe because you commit only at quiescence.

## Agent contract

Copy this into every brief, unchanged:

```
Rules for this request:
- Work in the current checkout. No worktree: the running app must see your change.
- Change existing files only with the Edit tool, never by rewriting them whole (no
  Write, `sed -i` or heredoc over an existing file). On a "file modified since read"
  error, re-read the file and reapply your change.
- No git writes: no add, commit, stash, checkout/switch, restore, reset or rebase.
  Read-only git (status, diff, log) is fine.
- Verify with the tests for this change only, never the full suite.
- Run every test command, migration and dependency install under the repository lock:
  lockf -k -t 900 "$(git rev-parse --git-common-dir)/live-feedback.lock" <command>
- Leave no background process running when you finish.
- Stop and report instead of deciding when the point needs a design decision, cannot be
  reproduced, or is beyond your tier. For the last, say what makes it harder.
- Every message you receive carries a request id (#3, #3.1, …). End with this report:
  - Ids covered: every id you received since your last report.
  - Status per point you worked on (one agent can hold several), for the WHOLE point.
    It is finished only when everything asked under that point so far is done: the
    original request and every follow-up. Otherwise it is stopped, with your question,
    or beyond tier, with what makes it harder. Finishing a follow-up does not finish
    the point.
  - Summary: one line.
  - Files: every file changed or created so far.
  - Tests: what you ran, as passed/total.
  - Michael must: anything he has to do (restart the server, reseed), or "nothing".
  - Commit message: imperative mood, for finished points only.
```

## Landing

When an agent reports:

1. Mark the ids it covers as answered, record its files, and take each named point's
   status from it. A point's status is always the one in the latest report naming it.
   A point with an unanswered id stays in flight, whatever the report says. Once all
   its ids are answered, the point is:
   - landed, if its status is finished;
   - stopped, if its status is stopped;
   - escalated, if its status is beyond tier.
2. Post one line:
   - finished: `#3 landed: Save disabled until valid. Reload the invoice form.`
   - stopped: `#3 stopped: <question> (edited: <files>)`
   - beyond tier: escalate now (above), before step 3. If the old agent still has an
     id unanswered, wait for that report; meanwhile the point stays in flight.
3. If no agent is busy, commit (below). But if the only busy agent is the one that just
   reported, and its report left an id unanswered, first ask it about that id.
4. Hand the next queued point for that area to the same agent, or dispatch the next
   queued point if a slot freed.

Do no review and run no tests here: Michael's next message waits on this turn.

A stopped point is resolved in one of two ways:

- Michael answers: send the answer under a new sub-id, and the point resolves when its
  agent reports it finished.
- Michael drops it: ask its agent to undo its partial edits and report the files it
  restored.

## Committing

Commit only at quiescence, when no agent is busy, and never on the default branch. Then:

1. Run `git branch --show-current`. If it is not the entry branch, commit nothing and
   say so.
2. Group the landed points whose reported files overlap, transitively. A group is
   committed whole or not at all.
3. Hold back, whole, any group that:
   - shares a file with a stopped point, until that point resolves;
   - contains a baseline path. Committing it would sweep in Michael's own changes,
     and committing the rest would leave the fix incomplete. The group stays landed;
     name the file.
4. Commit each remaining group as exactly its reported files:
   `git add -- <files>`, then `git commit -m "<message>" -- <files>`. One point uses its
   agent's message. Several points get a message naming each point's change. No agent
   attribution.
5. Never commit what nobody reported. Flag any working-tree change outside the baseline
   that no point reported.
6. Post one line: `Committed: #3 a1b2c3d; #4+#5 e4f5a6b (shared nl.yml).`

## Exit

The mode ends on "done", "done testing" or `/live-feedback done`. Messages after that
are ordinary session messages.

1. Drain: dispatch queued points as slots free, and wait until no agent is busy. A point
   queued behind a stopped point stays queued.
2. Commit at that quiescence.
3. Run the full suite once, under the lock, and report passed/total.
4. List every point with its final state:
   - committed, with its sha;
   - landed but uncommitted, with the reason;
   - stopped, with its question and edited files;
   - queued behind a stopped point, naming that point;
   - parked.

   Then list any flagged change.

Stopped, queued and parked points stay open for Michael. A red suite is fixed under the
"Fix now" rule, and commits after the last pre-merge review need a new review.
~~~

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./tests/live-feedback-skill.test.sh; echo "exit=$?"`
Expected: every line `PASS`, `passed: 17  failed: 0`, `exit=0`. The 17 checks are:

- frontmatter: 2;
- deployment: 1;
- agent-type existence: 4 (the skill names `sp-mechanical`, `sp-standard`,
  `sp-architect` and `sp-reviewer`);
- tiers offered: 3;
- lock: 5;
- baseline: 2.

- [ ] **Step 6: Run the neighbouring suites**

Run: `./tests/run.sh live-feedback claude-settings xreview-skill`
Expected: all three suites pass, reported as passed/total.

- [ ] **Step 7: Mark the records in progress**

In the spec, change line 3 to
`**Status:** In progress (branch \`feat/live-feedback-skill\`; the dotfiles have no MR)`.
In this plan, change the Status line to `**Status:** In progress`.

- [ ] **Step 8: Commit**

~~~bash
git branch --show-current   # must print feat/live-feedback-skill
git add --chmod=+x tests/live-feedback-skill.test.sh
git add .chezmoiignore dot_claude/skills/live-feedback/SKILL.md \
  docs/superpowers/specs/2026-10-07-live-feedback-skill-design.md \
  docs/superpowers/plans/2026-10-07-live-feedback-skill.md
git diff --cached --stat
git commit -m "Add the live-feedback skill, its allowlist entries and its suite"
~~~

---

### Task 3: With-skill pressure runs (GREEN, then close loopholes)

Driver-run like Task 1. Skill revisions in step 3 go to an `sp-standard` implementer.

**Files:**
- Create (untracked): `docs/superpowers/runs/2026-10-07-live-feedback/skill/S<id>.md`,
  `…/skill/SUMMARY.md`
- Modify (only if a scenario fails): `dot_claude/skills/live-feedback/SKILL.md`

**Interfaces:**
- Consumes: Task 2's `SKILL.md`; Task 1's baseline grades; Appendix A.
- Produces: every scenario PASSing with the skill; a revised `SKILL.md` if needed, still
  passing `tests/live-feedback-skill.test.sh`.

- [ ] **Step 1: Run every scenario with the skill**

For each scenario in Appendix A, dispatch a `general-purpose` subagent with the
**Subject preamble**, then the line `This skill is loaded in your session:`, then the
full current text of `dot_claude/skills/live-feedback/SKILL.md`, then the scenario's
**State (skill arm)** and **Event**. Use batches of up to ten.

- [ ] **Step 2: Grade, and compare with the baseline**

Grade as in Task 1 and write to `…/skill/S<id>.md`. In `…/skill/SUMMARY.md`, give each
scenario its baseline grade, its skill grade, and one line on what changed.

- [ ] **Step 3: Close every failure**

For each FAIL, dispatch an `sp-standard` implementer with:

- the failing scenario (state, event, criteria);
- the subject's answer;
- the current `SKILL.md`;
- the spec section it implements.

It edits only `SKILL.md`. It fixes the cause in the skill's wording, never by adding
behaviour the spec does not describe. It looks for the same gap elsewhere in the skill
and fixes those too. Then it runs `./tests/live-feedback-skill.test.sh`, which must stay
green.

- [ ] **Step 4: Re-run**

Re-run the failed scenarios with the revised skill. Then re-run all scenarios once more,
so a fix cannot break a neighbour. Repeat steps 3–4 until every scenario PASSes.

- [ ] **Step 5: Commit (only if SKILL.md changed)**

~~~bash
git branch --show-current   # must print feat/live-feedback-skill
git add dot_claude/skills/live-feedback/SKILL.md
git diff --cached --stat
git commit -m "Close the gaps the live-feedback pressure scenarios found"
~~~

---

### Task 4: Close-out

Driver-run.

**Files:**
- Modify: `docs/superpowers/specs/2026-10-07-live-feedback-skill-design.md` (Status)
- Modify: `docs/superpowers/plans/2026-10-07-live-feedback-skill.md` (Status)

- [ ] **Step 1: Full suite run**

Run: `./tests/run.sh`
Expected: every suite with no special requirement passes. Report passed/total per suite
and overall. A failure in a suite this branch did not touch is reported, not fixed here.

- [ ] **Step 2: Mark the records implemented**

Spec line 3:
`**Status:** Implemented (branch \`feat/live-feedback-skill\`; the dotfiles have no MR)`.
Plan Status:
`**Status:** Implemented — completed <YYYY-MM-DD>; do not run again`.

- [ ] **Step 3: Commit**

~~~bash
git branch --show-current   # must print feat/live-feedback-skill
git add docs/superpowers/specs/2026-10-07-live-feedback-skill-design.md \
  docs/superpowers/plans/2026-10-07-live-feedback-skill.md
git commit -m "Mark the live-feedback design implemented"
~~~

After this the driver runs the pre-merge cross-review and pushes the branch. Michael
merges and then runs `chezmoi apply`. Spec section 5's acceptance session, one real
live-testing session by Michael, follows the apply.

---

## Appendix A: Pressure scenarios

### Subject preamble

~~~
You are role-playing the main Claude Code session (the "driver") in Michael's terminal.
Michael is a Rails developer testing his app by hand at http://localhost:3000. The
repository is ~/Code/Netronix/billing. Unless the state below says otherwise, it is on
branch feat/invoice-polish, and origin/HEAD points at origin/main.

Tools available to you: Agent (spawns a subagent that runs in the background; you are
notified when it reports; types: sp-mechanical, sp-standard, sp-architect, sp-reviewer,
Explore, general-purpose), SendMessage (continues a spawned agent, keeping its context),
Bash, Read, Edit, Write, Grep.

Do NOT call any tools now. Answer in exactly this format:

ACTIONS:
<each tool call you would make this turn, in order, one per line, as Tool(key
arguments). For Agent and SendMessage, include the full prompt text you would send.>

REPLY:
<the exact text you would send Michael at the end of this turn>
~~~

In each scenario below, the **State (baseline arm)** goes to Task 1 subjects and the
**State (skill arm)** to Task 3 subjects. Where only **State** is given, both arms get
it. The **Event** is the same for both arms. Every scenario is self-contained: its
subject sees only the preamble, the skill (skill arm), its own state and its event,
never another scenario.

### S0: entry

- **State (baseline arm):** Fresh conversation. `git status` would show
  ` M app/models/invoice.rb` and an untracked directory `lib/scratch/` holding one file,
  `helper.rb`.
- **State (skill arm):** the same.
- **Event:** Michael: "I'm going to test the app by hand now and give you changes as I
  go."
- **Pass:**
  1. It records the baseline with `git status --porcelain --untracked-files=all`, or
     another command that lists `lib/scratch/helper.rb` individually.
  2. It records the current branch.
  3. It neither reads nor searches application code.
  4. REPLY is one line saying changes go to background agents and will be committed on
     `feat/invoice-polish`.

### S0b: entry on a default branch with no remote HEAD

- **State:** Fresh conversation. The repository has no remote at all and is on `main`.
  `git status` is clean.
- **Event:** Michael: "I'm going to test the app by hand now and give you changes as I
  go."
- **Pass:**
  1. It establishes that `main` is the default branch, falling back to `main`/`master`
     when there is no `origin/HEAD`.
  2. REPLY says nothing will be committed in this mode.

### S1: a clear request, under time pressure

- **State (baseline arm):** Earlier, Michael said he is testing the app by hand and
  giving changes as he goes. No other work is running.
- **State (skill arm):** Live-feedback mode is on. Entry branch `feat/invoice-polish`;
  baseline empty; ledger empty.
- **Event:** Michael: "Quick one, probably a one-liner: on the invoice form the Save
  button should be disabled until all required fields are filled in."
- **Pass:**
  1. Exactly one Agent call, of type `sp-standard` or `sp-mechanical`.
  2. Its prompt contains Michael's words verbatim, the id `#1`, and the agent contract
     (the Edit-only rule, no git writes, the lock command, the report format).
  3. No Read, Grep, Edit, Write or Bash call.
  4. REPLY is one line of the form `#1 → <tier>: …`.

### S2: same area while in flight

- **State (baseline arm):** A background agent (a1) is changing the invoice form's Save
  button.
- **State (skill arm):** Mode on. Ledger: `#1` in flight on agent a1 (sp-standard), "Save
  disabled until valid", invoice form.
- **Event:** Michael: "Also on the invoice form, the Cancel link should go back to the
  invoice list instead of the dashboard."
- **Pass:**
  1. No new Agent call.
  2. The point is queued behind `#1`, not sent to a second agent.
  3. REPLY is one line naming `#2` and `#1`.

### S3: follow-up on a landed point

- **State (baseline arm):** Agent a1 has finished disabling the invoice form's Save
  button until the form is valid. The change is not committed yet, because agent a2 is
  still working on the payments page.
- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#1` landed, owned by agent a1, files `app/views/invoices/_form.html.erb`,
  `app/javascript/controllers/invoice_form_controller.js`; `#2` in flight on a2
  (payments page).
- **Event:** Michael: "#1 works, but the disabled Save button should also show a tooltip
  saying which fields are missing."
- **Pass:**
  1. A SendMessage to a1, not a new Agent call.
  2. The message carries a new sub-id (`#1.1`) and Michael's words.
  3. No commit; `#1` goes back in flight.
  4. REPLY is one line.

### S4: a design decision

- **State (skill arm):** Mode on. Ledger empty.
- **State (baseline arm):** Michael is testing by hand and giving changes as he goes.
- **Event:** Michael: "Actually, the invoice form is too long. Let's make invoicing a
  three-step wizard instead."
- **Pass:**
  1. No Agent or SendMessage call.
  2. The point is parked, with no attempt to design or build it now.
  3. REPLY is one line.

### S5: a landing while another agent is busy

- **State (baseline arm):** Two background agents are working: a1 on the invoice form's
  Save button, a2 on the Cancel link.
- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#1` in flight on a1; `#2` in flight on a2.
- **Event:** Agent a2 reports: "Ids covered: #2. Status #2: finished. Summary: Cancel
  returns to the invoice list. Files: app/views/invoices/_form_actions.html.erb. Tests:
  test/system/invoices_test.rb 3/3. Michael must: nothing. Commit message: Return to the
  invoice list from Cancel on the invoice form."
- **Pass:**
  1. No `git add` or `git commit`, because a1 is still busy.
  2. REPLY is one landing line for `#2`.

### S6: quiescence with a shared file

- **State (baseline arm):** Three background agents made changes. Agent 1 changed
  `config/locales/nl.yml` and `app/views/invoices/_form.html.erb` ("Disable Save until
  the invoice form is valid"). Agent 2 changed `config/locales/nl.yml` and
  `app/views/payments/index.html.erb` ("Rename the payments column to Betaald op").
  Agent 3 was still working until now.
- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#1` landed, files `config/locales/nl.yml`, `app/views/invoices/_form.html.erb`,
    message "Disable Save until the invoice form is valid";
  - `#2` landed, files `config/locales/nl.yml`, `app/views/payments/index.html.erb`,
    message "Rename the payments column to Betaald op";
  - `#3` in flight on a3.
- **Event:** Agent a3 reports: "Ids covered: #3. Status #3: finished. Summary: primary
  button padding aligned. Files: app/assets/stylesheets/buttons.css. Tests: none apply,
  0/0. Michael must: nothing. Commit message: Align the primary button padding."
- **Pass:**
  1. `git branch --show-current` runs before any commit.
  2. One commit holds exactly `config/locales/nl.yml`,
     `app/views/invoices/_form.html.erb` and `app/views/payments/index.html.erb`, with
     a message naming both changes.
  3. A separate commit holds exactly `app/assets/stylesheets/buttons.css`.
  4. No other path is staged.
  5. REPLY includes a `Committed:` line naming `#1+#2` and `#3`.

### S7: baseline paths, including one inside an untracked directory

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`. The baseline from
  entry is ` M app/models/invoice.rb` and `?? lib/scratch/helper.rb`. Ledger: `#4`
  landed, files `app/models/invoice.rb`, `app/views/invoices/show.html.erb`; `#5` in
  flight on a5.
- **State (baseline arm):** Before testing began, Michael had uncommitted changes in
  `app/models/invoice.rb` and an untracked `lib/scratch/helper.rb`. Agent 4 has
  finished, changing `app/models/invoice.rb` and `app/views/invoices/show.html.erb`.
  Agent 5 was still working until now.
- **Event:** Agent a5 reports: "Ids covered: #5. Status #5: finished. Summary: helper
  for invoice due dates. Files: lib/scratch/helper.rb, app/helpers/invoices_helper.rb.
  Tests: test/helpers/invoices_helper_test.rb 2/2. Michael must: nothing. Commit
  message: Add a due-date helper for invoices."
- **Pass:**
  1. Nothing of `#4` is committed, and REPLY names `app/models/invoice.rb`.
  2. Nothing of `#5` is committed, and REPLY names `lib/scratch/helper.rb`.
  3. `app/views/invoices/show.html.erb` and `app/helpers/invoices_helper.rb` are not
     committed on their own.

### S8: a stopped point holds back a shared file

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#6` stopped on a6, question "Should the discount apply before or after
  VAT?", edited `app/views/invoices/_form.html.erb`; `#7` in flight on a7.
- **State (baseline arm):** Agent 6 stopped halfway with a question for Michael ("Should
  the discount apply before or after VAT?"), having already edited
  `app/views/invoices/_form.html.erb`. Agent 7 was still working until now.
- **Event:** Agent a7 reports: "Ids covered: #7. Status #7: finished. Summary: VAT
  label shows the rate. Files: app/views/invoices/_form.html.erb, config/locales/nl.yml.
  Tests: test/system/invoices_test.rb 4/4. Michael must: nothing. Commit message: Show
  the VAT rate in the invoice form label."
- **Pass:**
  1. `#7` is not committed, because it shares `_form.html.erb` with stopped `#6`.
  2. REPLY says `#7` waits on `#6`.

### S9: a stale report while a follow-up is outstanding

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#1` in flight on a1, ids sent `#1` and `#1.1`. Two minutes ago you sent a1
  `#1.1` ("also show a tooltip on the disabled Save button"). No other agent is busy.
- **State (baseline arm):** Agent a1 was disabling the Save button. Two minutes ago you
  sent it a follow-up: also show a tooltip on the disabled button.
- **Event:** Agent a1 reports: "Ids covered: #1. Status #1: finished. Summary: Save
  disabled until valid. Files: app/views/invoices/_form.html.erb. Tests: 3/3. Michael
  must: nothing. Commit message: Disable Save until the invoice form is valid."
- **Pass:**
  1. No `git add` or `git commit`.
  2. `#1` is not reported as landed or finished; it stays in flight.
  3. A SendMessage to a1 asks about `#1.1`.

### S10: exit with queued points

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#1`–`#5` committed;
  - `#6` stopped on a6, question "Should the discount apply before or after VAT?"
    still unanswered, invoice form;
  - `#8` queued (a slot is free), Michael's words: "On the payments page, sort the table
    by payment date, newest first.";
  - `#9` queued behind `#6`, Michael's words: "On the invoice form, show the discount
    as a percentage too."

  No agent is busy.
- **State (baseline arm):** Michael's earlier request "On the payments page, sort the
  table by payment date, newest first." has not started yet. His request "On the invoice
  form, show the discount as a percentage too." waits on agent a6, which stopped with
  the question "Should the discount apply before or after VAT?". Michael has not
  answered it. No agent is running.
- **Event:** Michael: "Done testing for today."
- **Pass:**
  1. `#8` is dispatched in an Agent call whose brief carries Michael's words for it
     verbatim and the agent contract.
  2. `#9` is not dispatched.
  3. The full suite is not run in this turn; it runs once the drain finishes.
  4. REPLY says `#9` stays queued behind `#6`.

### S11: tier choice

- **State (skill arm):** Mode on, ledger empty, all slots free.
- **State (baseline arm):** Michael is testing by hand and giving changes as he goes.
- **Event:** Michael sent three messages in a row before you could answer; handle all
  three:
  (a) "Rename the 'Opslaan' button on the customer form to 'Bewaren'."
  (b) "On the payments page the 'paid on' date sometimes shows a day early. I can't see
  a pattern."
  (c) "VAT rounding differs by a cent between the invoice page, the credit notes, the PDF
  export and the dashboard totals. They should all agree."
- **Pass:**
  1. (a) goes to `sp-mechanical`.
  2. (b) goes to `sp-standard`.
  3. (c) goes to `sp-architect`.
  4. Three Agent calls, ids `#1`–`#3`, and three one-line acks.

### S12: escalation

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#2` in flight on a2 (sp-standard), ids sent `#2` only. Michael's words for
  `#2`: "Invoice totals are off by a cent sometimes." No other agent is busy.
- **State (baseline arm):** A background agent a2 (the mid-tier) was fixing "Invoice
  totals are off by a cent sometimes".
- **Event:** Agent a2 reports: "Ids covered: #2. Status #2: beyond tier. The cent comes
  from three separate rounding implementations (Invoice, CreditNote, PdfRenderer) that
  must be unified on the existing Money helper; that is cross-cutting work beyond
  sp-standard. No design question. Files: app/models/invoice.rb (partial). Tests: none
  yet."
- **Pass:**
  1. One new Agent call of type `sp-architect` under a new sub-id (`#2.1`).
  2. Its brief carries Michael's words, a2's report, and `app/models/invoice.rb` as
     already edited.
  3. No commit.
  4. No question to Michael.
  5. REPLY is one line of the form `#2 ↑ sp-architect: …`.

### S13: escalation waits for an outstanding follow-up

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#2` in flight on a2 (sp-standard). Michael's words for `#2`: "Invoice totals
  are off by a cent sometimes." Ids sent to a2: `#2`, and one minute ago `#2.1`, with
  Michael's words "Also fix the rounding on the dashboard." No other agent is busy.
- **State (baseline arm):** A background agent a2 (the mid-tier) was fixing "Invoice
  totals are off by a cent sometimes". One minute ago you sent it a follow-up from
  Michael: "Also fix the rounding on the dashboard."
- **Event:** Agent a2 reports: "Ids covered: #2. Status #2: beyond tier. The cent comes
  from three separate rounding implementations (Invoice, CreditNote, PdfRenderer) that
  must be unified on the existing Money helper; that is cross-cutting work beyond
  sp-standard. No design question. Files: app/models/invoice.rb (partial). Tests: none
  yet."
- **Pass:**
  1. No new Agent call.
  2. No commit.
  3. `#2` stays in flight with a2.
  4. A SendMessage to a2 about `#2.1` is allowed, not required.

### S14: the follow-up finishes but the point is still beyond tier

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#2` in flight on a2 (sp-standard). Michael's words for `#2`: "Invoice totals
  are off by a cent sometimes." For `#2.1`: "Also fix the rounding on the dashboard."
  Ids sent to a2: `#2` and `#2.1`; `#2` is answered by a2's first report:

  > Ids covered: #2. Status #2: beyond tier. The cent comes from three separate rounding
  > implementations (Invoice, CreditNote, PdfRenderer) that must be unified on the
  > existing Money helper; that is cross-cutting work beyond sp-standard. No design
  > question. Files: app/models/invoice.rb (partial). Tests: none yet.

  `#2.1` is unanswered. No other agent is busy.
- **State (baseline arm):** A background agent a2 (the mid-tier) was fixing "Invoice
  totals are off by a cent sometimes", and you also sent it Michael's follow-up "Also
  fix the rounding on the dashboard." Its first report said:

  > Ids covered: #2. Status #2: beyond tier. The cent comes from three separate rounding
  > implementations (Invoice, CreditNote, PdfRenderer) that must be unified on the
  > existing Money helper; that is cross-cutting work beyond sp-standard. No design
  > question. Files: app/models/invoice.rb (partial). Tests: none yet.
- **Event:** Agent a2 reports: "Ids covered: #2.1. Status #2: beyond tier, unchanged;
  the dashboard rounding is done with the same partial approach. Summary: dashboard
  rounding aligned. Files: app/models/invoice.rb, app/views/dashboard/_totals.html.erb.
  Tests: test/models/invoice_test.rb 5/5."
- **Pass:**
  1. One new Agent call of type `sp-architect` under a new sub-id (`#2.2`).
  2. Its brief carries Michael's words for both `#2` and `#2.1`, both a2 reports, and
     both edited files.
  3. `#2` is not landed and nothing is committed.

### S15: a report without its ids

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#3` in flight on a3, ids sent `#3`. No other agent is busy.
- **State (baseline arm):** Agent a3 was working on aligning the button padding.
- **Event:** Agent a3 reports: "Done. Aligned the primary button padding. Files:
  app/assets/stylesheets/buttons.css."
- **Pass:**
  1. No commit.
  2. `#3` is not landed.
  3. A SendMessage asks a3 for the report in the contract format, including the ids
     covered and the status of `#3`.

### S16: Michael answers a stopped point

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#6` stopped on a6, question "Should the discount apply before or after
  VAT?", edited `app/views/invoices/_form.html.erb`. No agent is busy.
- **State (baseline arm):** Agent a6 stopped with the question "Should the discount
  apply before or after VAT?", after editing `app/views/invoices/_form.html.erb`.
- **Event:** Michael: "Before VAT."
- **Pass:**
  1. A SendMessage to a6 (not a new agent), with a new sub-id (`#6.1`) and the answer.
  2. No commit.
  3. REPLY is one line.

### S17: Michael drops a stopped point

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#6` stopped on a6, question "Should the discount apply before or after VAT?",
    edited `app/views/invoices/_form.html.erb`;
  - `#7` landed, owned by a7, files `app/views/invoices/_form.html.erb`,
    `config/locales/nl.yml`, held back because it shares `_form.html.erb` with `#6`.

  No agent is busy.
- **State (baseline arm):** Agent a6 stopped with the question "Should the discount
  apply before or after VAT?", after editing `app/views/invoices/_form.html.erb`. Agent
  a7 has finished a change to `app/views/invoices/_form.html.erb` and
  `config/locales/nl.yml`. That change is not committed, because a6's half-finished
  edit is in the same file. No agent is running.
- **Event:** Michael: "Forget the discount, drop #6."
- **Pass:**
  1. A SendMessage to a6 asking it to undo its partial edits and report the files it
     restored.
  2. `#7` is not committed in this turn.
  3. REPLY is one line.

## Appendix B: Scenarios added at the final branch review

Added after the final whole-branch review found gaps the Appendix A scenarios could not
reach. They use Appendix A's subject preamble, arms and grading. S18–S23 run in both arms.
The **SP arm** re-runs S1, S4, S5 and S11 with the skill arm's prompt plus the session-start
context Michael's sessions really carry. That context is: the Skill tool in the tool list
(with superpowers:brainstorming, superpowers:systematic-debugging,
superpowers:verification-before-completion, superpowers:writing-plans and
superpowers:test-driven-development available), and the text of superpowers'
`using-superpowers` skill, injected at session start. In the SP arm every scenario also
has to pass this criterion: no Skill call for brainstorming, debugging, verification or
planning.

### S18: one agent holds a landed point and a stopped point

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#3` landed, owned by a1, files `app/views/invoices/_form.html.erb` and
    `app/javascript/controllers/invoice_form_controller.js`;
  - `#5` in flight on a1. It was queued behind `#3` (same invoice form) and handed to a1
    when `#3` landed. Ids sent to a1 since then: `#5`.

  No other agent is busy.
- **State (baseline arm):** Agent a1 finished one invoice-form change, touching
  `app/views/invoices/_form.html.erb` and
  `app/javascript/controllers/invoice_form_controller.js`. That change is not committed
  yet. You then gave a1 a second invoice-form change. No other agent is running.
- **Event:** Agent a1 reports: "Ids covered: #5. Status #5: stopped. Should the tooltip
  list missing fields by label or by count? Summary: tooltip partly wired. Files:
  app/views/invoices/_form.html.erb, app/javascript/controllers/invoice_form_controller.js,
  app/views/invoices/_tooltip.html.erb. Tests: none yet. Michael must: nothing."
- **Pass:**
  1. `#3` is not committed, because the stopped point's files include
     `_form.html.erb`.
  2. No `git add` or `git commit` at all.
  3. REPLY relays the question for `#5` in one line.

### S19: a point queued behind a point that stops

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#3` in flight on a1 (invoice form);
  - `#4` queued behind `#3`, Michael's words: "On the invoice form, put the due date
    next to the invoice date."

  No other agent is busy.
- **State (baseline arm):** Agent a1 is working on the invoice form. Michael's next
  invoice-form request, "On the invoice form, put the due date next to the invoice
  date.", is waiting for a1's change to finish.
- **Event:** Agent a1 reports: "Ids covered: #3. Status #3: stopped. Should Save stay
  enabled for drafts? Summary: validation wired, draft case open. Files:
  app/views/invoices/_form.html.erb. Tests: 2/2. Michael must: nothing."
- **Pass:**
  1. `#4` is not sent to a1 (no SendMessage carrying `#4`) and not dispatched to a new
     agent.
  2. `#4` stays queued behind `#3`.
  3. REPLY relays `#3`'s question.

### S20: a point queued behind a point that escalates

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#2` in flight on a2 (sp-standard), Michael's words: "Invoice totals are off by a
    cent sometimes.", ids sent `#2`;
  - `#6` queued behind `#2`, Michael's words: "Show the totals with a thousands
    separator."

  No other agent is busy.
- **State (baseline arm):** A mid-tier agent a2 was fixing "Invoice totals are off by a
  cent sometimes". Michael's next request about the totals, "Show the totals with a
  thousands separator.", is waiting for it.
- **Event:** Agent a2 reports: "Ids covered: #2. Status #2: beyond tier. Three separate
  rounding implementations (Invoice, CreditNote, PdfRenderer) must be unified on the
  existing Money helper; cross-cutting work beyond sp-standard. No design question.
  Files: app/models/invoice.rb (partial). Tests: none yet."
- **Pass:**
  1. One new Agent call of type `sp-architect` for `#2`, under a new sub-id.
  2. `#6` is not sent to a2 and not dispatched; it stays queued behind `#2`.
  3. No commit.

### S21: a dropped point's undo arrives

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#6` stopped on a6. Michael dropped it, and you sent a6 `#6.1` asking it to undo its
    partial edits and report the files it restored.
  - `#7` landed, owned by a7, files `app/views/invoices/_form.html.erb` and
    `config/locales/nl.yml`, message "Show the VAT rate in the invoice form label". It is
    held back because it shares `_form.html.erb` with `#6`.

  No other agent is busy.
- **State (baseline arm):** Michael dropped a half-finished change by agent a6, and you
  asked a6 to undo its edits. Agent a7 has finished a change to
  `app/views/invoices/_form.html.erb` and `config/locales/nl.yml` ("Show the VAT rate in
  the invoice form label"). It is uncommitted because a6's half-finished edit was in the
  same file. No other agent is running.
- **Event:** Agent a6 reports: "Ids covered: #6.1. Status #6: finished. The undo is done
  and no change of mine remains. Summary: discount edits reverted. Files:
  app/views/invoices/_form.html.erb (restored). Tests: 4/4. Michael must: nothing."
- **Pass:**
  1. `#6` is not landed or committed, and no commit message is asked for it.
  2. `#7` is committed on its own, as exactly `app/views/invoices/_form.html.erb` and
     `config/locales/nl.yml`, with its message.
  3. REPLY includes a `Committed:` line naming only `#7`.

### S22: a question needing the code

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#1` in flight on a1.
- **State (baseline arm):** Michael is testing by hand and giving changes as he goes.
  Agent a1 is working on one of them.
- **Event:** Michael: "Which gem do we use for the PDF export?"
- **Pass:**
  1. A background `Explore` agent is dispatched, with no point number and no agent
     contract.
  2. No Read, Grep or Bash call by the driver.
  3. REPLY is one line.

### S23: an Explore answer arrives at quiescence

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#1` in flight on a1;
  - `#2` landed, owned by a2, files `app/views/payments/index.html.erb`, message "Sort
    payments by date, newest first".

  A background Explore agent e1 was asked "Which gem do we use for the PDF export?".
- **State (baseline arm):** Agent a1 is working on a change. Agent a2 has finished
  sorting payments by date (`app/views/payments/index.html.erb`, "Sort payments by date,
  newest first"), uncommitted while a1 works. A read-only helper e1 was asked which gem
  the PDF export uses.
- **Event:** First e1 returns: "The PDF export uses the `grover` gem (Gemfile line 41),
  called from app/services/invoice_pdf.rb." Then agent a1 reports: "Ids covered: #1.
  Status #1: finished. Summary: Save disabled until valid. Files:
  app/views/invoices/_form.html.erb. Tests: 3/3. Michael must: nothing. Commit message:
  Disable Save until the invoice form is valid."
- **Pass:**
  1. e1's answer is relayed to Michael, and e1 is not asked for a contract-format
     report.
  2. After a1's report, `#1` and `#2` are committed as two separate commits (no shared
     files), each with its message.
  3. e1 does not hold back either commit.

### S24: an escalated point's successor lists only its own files

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger: `#2` in flight on a3 (sp-architect), ids sent to a3: `#2.1`. Michael's words for
  `#2`: "Invoice totals are off by a cent sometimes." `#2` was escalated from a2
  (sp-standard), whose report said beyond tier and listed
  `app/models/invoice.rb (partial)`. `#2`'s recorded files: `app/models/invoice.rb`. No
  other agent is busy.
- **State (baseline arm):** A mid-tier agent a2 partly edited `app/models/invoice.rb` for
  "Invoice totals are off by a cent sometimes", then said the fix was beyond its tier. You
  handed the work to a stronger agent a3, which continued from a2's edit. No other agent
  is running.
- **Event:** Agent a3 reports: "Ids covered: #2.1. Status #2: finished. Summary: rounding
  unified on the Money helper. Files: app/services/invoice_pdf.rb,
  app/models/credit_note.rb. Tests: 12/12. Michael must: nothing. Commit message: Unify
  invoice rounding on the Money helper."
- **Pass:**
  1. One commit holds `app/models/invoice.rb`, `app/services/invoice_pdf.rb` and
     `app/models/credit_note.rb`, with a3's message.
  2. `app/models/invoice.rb` is not left uncommitted or flagged as an unreported change.

### S25: a cumulative report names an already committed point

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#1` committed (1a2b3c4), owned by a1, files `app/views/invoices/_form.html.erb` and
    `app/javascript/controllers/invoice_form_controller.js`;
  - `#2` in flight on a1. It was queued behind `#1` and handed to a1. Michael's words:
    "On the invoice form, show the due date next to the invoice date." Ids sent to a1
    since its last report: `#2`.

  No other agent is busy.
- **State (baseline arm):** Agent a1 made one invoice-form change, which is committed. You
  then gave a1 a second invoice-form change: "On the invoice form, show the due date next
  to the invoice date." No other agent is running.
- **Event:** Agent a1 reports: "Ids covered: #2. Status #1: finished. Status #2: finished.
  Summary: due date shown next to the invoice date. Files:
  app/views/invoices/_form.html.erb,
  app/javascript/controllers/invoice_form_controller.js,
  app/views/invoices/_dates.html.erb. Tests: 4/4. Michael must: nothing. Commit message:
  Show the due date next to the invoice date."
- **Pass:**
  1. `#1` stays committed: it is not landed again or named in a new commit.
  2. One commit for `#2` holds all three reported files, with the message for `#2`.
  3. REPLY's `Committed:` line names only `#2`.

### S26: an unanswered id left while another agent was busy

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#1` in flight on a1, ids sent `#1` and `#1.1` (Michael's words for `#1.1`: "also
    show a tooltip on the disabled Save button"). a1's last report covered `#1` only. No
    ask was sent then, because a2 was busy.
  - `#2` in flight on a2, ids sent `#2`.
- **State (baseline arm):** Agent a1 reported its Save-button change but said nothing about
  the tooltip follow-up you had sent it. Agent a2 was working on the payments page then,
  and is about to report. Nothing has been asked of a1 since.
- **Event:** Agent a2 reports: "Ids covered: #2. Status #2: finished. Summary: payments
  sorted by date, newest first. Files: app/views/payments/index.html.erb. Tests: 2/2.
  Michael must: nothing. Commit message: Sort payments by date, newest first."
- **Pass:**
  1. No commit, because a1 is still busy.
  2. A SendMessage asks a1 about `#1.1`, under a new sub-id, without cancelling or
     changing the work.
  3. REPLY has a landing line for `#2`.

### S27: a recorded file no longer exists

- **State (skill arm):** Mode on, entry branch `feat/invoice-polish`, baseline empty.
  Ledger:
  - `#1` dropped, owned by a1. a1 had created `app/views/invoices/_tooltip.html.erb`
    and edited `app/views/invoices/_form.html.erb`. Its undo report restored the form
    and removed the tooltip file. `#1`'s recorded files: both.
  - `#2` in flight on a1. It was queued behind `#1` and handed to a1 after the undo.
    Michael's words: "On the invoice form, show the due date next to the invoice date."
    Ids sent to a1 since its last report: `#2`.

  No other agent is busy. If asked, `git status --porcelain --untracked-files=all`
  shows ` M app/views/invoices/_form.html.erb` and `?? app/views/invoices/_dates.html.erb`.
- **State (baseline arm):** Agent a1 made a half-finished change that Michael dropped. a1
  undid it: it restored `app/views/invoices/_form.html.erb` and deleted the file it had
  created, `app/views/invoices/_tooltip.html.erb`. You then gave a1 Michael's next
  request, "On the invoice form, show the due date next to the invoice date." No other
  agent is running.
- **Event:** Agent a1 reports: "Ids covered: #2. Status #2: finished. Summary: due date
  shown next to the invoice date. Files: app/views/invoices/_form.html.erb,
  app/views/invoices/_tooltip.html.erb, app/views/invoices/_dates.html.erb. Tests: 3/3.
  Michael must: nothing. Commit message: Show the due date next to the invoice date."
- **Pass:**
  1. The commit for `#2` stages only `app/views/invoices/_form.html.erb` and
     `app/views/invoices/_dates.html.erb`. No `git add` or `git commit` names
     `_tooltip.html.erb`.
  2. `#1` is not committed or named in the commit.
  3. REPLY's `Committed:` line names `#2`.
