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
reports beyond tier has nowhere to go: the point is stopped, and you relay it to Michael as a question.

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
   - escalated, if its status is beyond tier (stopped instead, if its agent is already
     `sp-architect`).
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

The mode ends when Michael says he is done testing, or runs `/live-feedback done`. A bare
"done" in answer to something else does not end it. Messages after that are ordinary
session messages.

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
