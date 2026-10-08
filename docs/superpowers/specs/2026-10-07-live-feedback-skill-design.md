# Live-feedback mode

**Status:** Implemented (branch `feat/live-feedback-skill`; the dotfiles have no MR)
**Date:** 2026-10-07
**Scope:** a new skill (`dot_claude/skills/live-feedback/SKILL.md`), its `.chezmoiignore`
allowlist entries, and a new test suite (`tests/live-feedback-skill.test.sh`).

## 1. Problem

Michael tests an application by hand and gives feedback as he goes: "this label is wrong",
"the table should sort by date", "this button should be disabled when…". Today the main
session makes each change itself. While it works, Michael can type and his messages queue,
but nothing starts on them: point two waits for point one to finish, so the session sets
the pace instead of his testing.

The global rules make plan execution subagent-driven ("Execution is always
subagent-driven"). Ad-hoc feedback is not a plan task, so it falls back to inline work.

## 2. Goals and non-goals

Goals:

- While live-testing, the main session (the driver) answers each change request in one
  short turn, so Michael can go straight on to his next point.
- Fixes land in the checkout the running app serves, so a reload shows them.
- Concurrent fixes never silently overwrite each other's edits.
- On a feature branch, finished fixes are committed, and a commit never holds unfinished
  work. A fix gets a commit of its own unless it shares a file with another fix finished
  in the same stretch; those share one commit that names both.
- Michael's own uncommitted work is never committed.
- No new permission prompts.

Non-goals:

- No change to normal work. Outside this mode, design, debugging and plan execution work
  as they do today.
- No per-fix code review. Michael reviews by testing; the pre-merge cross-review still
  covers the branch.
- No coordination with other sessions working in the same checkout.

## 3. Design

### 3.1 Entry

The mode starts when Michael runs `/live-feedback`, or when he says he is live-testing and
wants changes made as he goes (the skill's description carries that trigger). On entry the
driver:

1. Records the **baseline**, Michael's own uncommitted work, as
   `git status --porcelain --untracked-files=all`. The flag lists every untracked file;
   without it an untracked directory collapses to one `dir/` line, and his files inside
   it would not match an exclusion by path. The driver never commits a baseline path.
2. Records the current branch. On the default branch it makes no commits for the whole
   mode, and says so.
3. Replies with one line, for example: "Live-feedback on: each change goes to a background
   agent; fixes are committed on `feat/x`."

### 3.2 Each incoming message

| Message | Driver action |
|---|---|
| A clear change request | Brief and dispatch a background agent (3.3), ack in one line, end the turn |
| Ambiguous request | Ask one question; dispatch once answered |
| Follow-up on an earlier point (in flight, landed or stopped) | `SendMessage` to that point's agent, which keeps its context |
| Same page or component as a point in flight or stopped | Queue it behind that point (3.4) |
| Needs a design decision (new flow, scope change) | Not dispatched: park it in the ledger, say so in one line |
| A question | Answer inline if the conversation already holds the answer; otherwise a background `Explore` agent, answer relayed when it returns |
| "What's in flight?" | The ledger as a table |

The driver does not investigate the code before dispatching: locating the code is the
agent's job, and investigating would bring back the wait this mode removes. Ambiguity is
judged from Michael's words alone.

Every point gets a number. The ack names it and the agent tier:
`#3 → sp-standard: disable Save until the form is valid`. Every message the driver sends
an agent carries a **request id**: the point number for a point's first brief (`#3`, or
`#5` for a queued point handed to `#3`'s agent), and a sub-id for a follow-up (`#3.1`).
Reports name the ids they cover (3.5), which is how the driver matches a report to the
work it answers.

The **ledger** lists the points with their state and, once reported, their files. An
agent is **busy** while any id sent to it is unreported. A report that arrives after a
follow-up was sent therefore leaves the agent busy until the follow-up's id is reported
too. A point is:

- **queued**: accepted, waiting for a free slot or for the point ahead of it in its area;
- **in flight**: one of its ids is unreported;
- **landed**: its agent finished the fix; not yet committed;
- **committed**: in a commit;
- **stopped**: its agent stopped with a question for Michael, possibly after editing
  files. A stop for being beyond its tier is not this state: the point is escalated and
  stays in flight (3.3);
- **parked**: needs a design decision; never dispatched.

The ledger lives in the conversation. Every ack, landing and commit line repeats the
point numbers, so a compacted summary keeps it.

### 3.3 Dispatch

- **Tier.** The driver picks the tier from the task, as the global tier table describes,
  judging from Michael's words:
  - `sp-mechanical` when the point names both the exact change and the place ("rename
    Save to Opslaan on the invoice form");
  - `sp-standard` when the code must be located or a pattern matched, or for a bug whose
    cause is unknown. This is the default when the driver is unsure;
  - `sp-architect` when the point cuts across many parts of the app, or is a bug a
    lower tier already failed to crack.

  `sp-reviewer` is never dispatched: it does not edit. The tier is about difficulty
  only. Whether Michael must decide something is a separate question, answered by
  parking (3.2), and no tier makes a design decision for him.
- **Escalation.** An agent that finds its point beyond its tier stops and says so
  (3.5). That is not a question for Michael. Ownership moves only from an idle agent.
  While any id sent to the old agent is unanswered, the point stays in flight with it.
  Once it is idle and the point's status is beyond tier (3.6), the driver
  re-dispatches the point one tier up as a new agent, under a new sub-id. Its brief
  carries:
  - Michael's words for every id of the point, follow-ups included;
  - every report of the old agent;
  - the files it has already edited, so the new agent continues from those edits.

  The new agent then owns the point: follow-ups and points queued behind it go to the
  new agent, and the old agent gets nothing further. An `sp-architect` agent has no tier
  above it, so its stop goes to Michael like any other question.
- **Concurrency.** At most four agents busy. Further points queue and dispatch as
  agents finish.
- **Brief.** It is self-contained, because the agent cannot see the conversation:
  - Michael's words verbatim, plus the driver's one-line statement of the expected result;
  - where it shows (page, URL, screen) as he gave it;
  - the files earlier reports listed for the same area, if any;
  - the agent contract (3.5), copied in full.

### 3.4 Overlap control

Two agents editing one file at once is the failure to prevent. The defences:

1. **Area routing.** A point about the same page, component or reported files as a point
   in flight or stopped is queued behind it. When that point lands, or is resolved after
   stopping, the queued one goes to the same agent via `SendMessage`, so it starts with
   that agent's context.
2. **Edit-only rule.** Agents change existing files only with the Edit tool. Edit refuses
   a file that changed since it was read, so a collision fails loudly. The agent then
   re-reads and reapplies its change. A whole-file rewrite (Write, `sed -i`, a heredoc)
   would win the race silently, so the contract forbids it for existing files.

Area routing cannot see every shared file. Translation files and shared stylesheets are
touched by fixes on unrelated pages. So two agents can edit one file at once without
losing either edit. Committing only at quiescence (3.7) keeps that from producing a
commit with unfinished work in it.

### 3.5 Agent contract

Copied into every brief:

- Work in the current checkout. No worktree: the running app must see the change.
- Change existing files only with Edit, never by rewriting them whole. On a "file
  modified since read" error, re-read and reapply.
- No git writes: no `add`, `commit`, `stash`, `checkout`/`switch`, `restore`, `reset` or
  `rebase`. Read-only git (`status`, `diff`, `log`) is fine.
- Verify with the tests for this change only, never the full suite.
- Run every test command, migration and dependency install under the repository lock:
  `lockf -k -t 900 "$(git rev-parse --git-common-dir)/live-feedback.lock" <command>`. The
  lock sits in the git common directory, so `wt` worktrees of the same repository, which
  share one database, also share the lock.
- Leave no background process running: a running process keeps `SendMessage` follow-ups
  from reaching the agent.
- Stop and report instead of deciding when the point needs a design decision, cannot be
  reproduced, or is beyond your tier. In the last case, say what makes it harder than
  described.
- Report, whether finished or stopped:
  - the request ids it covers: every id received since the last report, so a follow-up
    that arrives mid-run is covered by the same report;
  - for each point it has worked on (one agent can hold several, 3.4), the status of the
    **whole point**:
    - **finished** only when everything asked under that point so far is done, the
      original request and every follow-up;
    - otherwise **stopped**, with the question;
    - or **beyond tier**, with what makes it harder.

    Finishing a follow-up does not finish the point: an earlier stop stands until the
    work it stopped is done;
  - a one-line summary;
  - every file changed or created so far;
  - the tests run, as passed/total;
  - anything Michael must do (restart the server, reseed);
  - a commit message in the imperative mood (finished points only).

### 3.6 Landing

When an agent reports, the driver:

1. Marks the ids the report covers as answered, records its files in the ledger, and
   takes each named point's status from it. A point's status is always the one from the
   latest report naming that point. A point with an id still unanswered stays in flight,
   whatever the report says. Once all its ids are answered, the point becomes:
   - landed if its status is finished;
   - stopped if its status is stopped;
   - escalated if its status is beyond tier.
2. Posts one line. A finished point reads
   `#3 landed: Save disabled until valid. Reload the invoice form.` A stopped point gets
   its question relayed in one line, with the files it has edited so far. A point stopped
   as beyond its tier is escalated instead (3.3). Escalation happens before step 3, so
   its partial edits are never committed in between. If the old agent still has an id
   unanswered, escalation waits for that report, and the point stays in flight
   meanwhile. Once escalated it is back in flight:
   `#3 ↑ sp-architect: the totals bug spans the invoice and payment models.`
3. If no agent is still busy, commits (3.7). If the only busy agent is the one that just
   reported, and its report left an id unanswered, the driver asks it about that id
   first. If the agent was already working on the id, the question is covered by its
   next report. This way a forgotten id cannot hold commits, or exit, forever.
4. Hands the next queued point for that area to the same agent, or dispatches the next
   queued point if a slot freed.

Landing does no review and runs no tests. It stays short because Michael's next messages
wait on it.

A stopped point is resolved when its agent finishes after Michael's answer (it then
lands), or when Michael drops it. Then the driver asks the agent to undo its partial edits
and report the files it restored.

### 3.7 Committing

Commits happen only at **quiescence**, when no agent is busy: whenever the last busy
agent's outstanding ids are all answered (before the next dispatch), and at exit. With
nothing running, every edit in the working tree is finished or belongs to a stopped
point, so a commit cannot capture half a fix.

On a feature branch, at quiescence, the driver:

1. Re-checks `git branch --show-current`. If the branch changed since entry, it commits
   nothing and says so.
2. Groups the landed points: points whose reported files overlap go in one group,
   transitively. A group is committed whole or not at all, never in part, so no commit
   holds half of a fix.
3. Holds back, whole, any group that:
   - shares a file with a stopped point, until that point is resolved;
   - contains a baseline path. Committing it would sweep Michael's own changes into the
     fix, and committing the rest would leave the fix incomplete. The group stays
     landed, and the driver names the baseline file.
4. Commits each remaining group as exactly its reported files (`git add -- <files>`,
   then `git commit -m <msg> -- <files>`). A single point uses its agent's message. A
   shared commit gets a message naming each point's change.
5. Commits nothing nobody reported. A working-tree change outside the baseline that no
   point reported is flagged, not committed.
6. Posts one line: `Committed: #3 a1b2c3d; #4+#5 e4f5a6b (shared nl.yml).`

Commits stay with the driver, one at a time, so agents never race on git's index lock.
On the default branch nothing is committed, and landed points stay landed.

### 3.8 Exit

The mode ends when Michael says he is done (or runs `/live-feedback done`). From then on
his messages are ordinary session messages. The driver:

1. Drains the work: it dispatches queued points as slots free, and waits until no agent
   is busy. A point queued behind a stopped point is not dispatched; it stays queued.
2. Commits at that final quiescence (3.7).
3. Runs the full suite once, under the lock, and reports passed/total.
4. Lists every point with its final state and commit:
   - committed;
   - landed but uncommitted, with the reason;
   - stopped, with its question and its edited files;
   - queued behind a stopped point, naming that point;
   - parked.

   Then it lists any flagged change.

Stopped, queued and parked points stay open for Michael. Normal workflow then resumes. A red
suite gets fixed under the "Fix now" rule, and commits after the last pre-merge review
need a new one, as always.

## 4. Files

- `dot_claude/skills/live-feedback/SKILL.md`: the skill, holding 3.1–3.8 as instructions.
  The frontmatter description triggers on `/live-feedback` and on Michael saying he is
  live- or manually testing and giving changes as he goes.
- `.chezmoiignore`: three allowlist lines, following the `cross-review` pattern.
- `tests/live-feedback-skill.test.sh`: covers the parts that can drift (4.1).

### 4.1 Static suite

Like `xreview-skill.test.sh`, it asserts in one direction: everything the skill names
must exist.

- The frontmatter `name:` is `live-feedback`, matching the directory.
- `chezmoi managed` lists `.claude/skills/live-feedback/SKILL.md`.
- Every `sp-*` agent type the skill names exists in `dot_claude/agents/`, with a matching
  `name:`.
- `lockf` is on `PATH`. The skill's lock command, run with `true` and a scratch lock path,
  exits 0.
- The skill's baseline command carries `--untracked-files=all`.
- The suite exits 2 if the skill file is missing.

## 5. Testing

- **Static:** the suite above, through `./tests/run.sh`.
- **Behaviour:** pressure scenarios per the writing-skills method, each run once without
  the skill (the baseline) and once with it. A scenario passes when the driver does what
  3.2–3.8 say:
  1. A clear request is dispatched in the background; the driver makes no edit and acks
     in one line.
  2. A second point on the same page while the first is in flight is queued, not sent to
     a second agent.
  3. A follow-up on a landed point goes to the same agent.
  4. A design-level point is parked.
  5. A point lands while another agent is in flight: nothing is committed until the
     second reports.
  6. At quiescence, two landed points with a shared file share one commit, and a third
     gets its own.
  7. A group with a baseline path is held back whole, including when the path is a file
     inside an untracked directory that was there at entry.
  8. A stopped point's files hold back the commit of any landed point that shares them.
  9. A follow-up is sent while the agent's earlier report is still unprocessed. That
     report leaves the agent busy, and nothing is committed until the follow-up's id is
     reported.
  10. Exit with points queued drains the dispatchable ones before the suite runs. A
      point queued behind a stopped point stays queued, and the final list shows it.
  11. Tier choice follows the task. An exact rename goes to `sp-mechanical`, a vague
      behaviour bug to `sp-standard`, and a change across many parts to `sp-architect`.
  12. An `sp-standard` agent stops as beyond its tier. The driver re-dispatches the
      point to `sp-architect` with the stopped report and edited files, without asking
      Michael. No commit happens in between.
  13. A follow-up reaches the old agent before its beyond-tier report is processed.
      Escalation waits until that agent has answered the follow-up's id. The new
      agent's brief then carries both requests, and the two agents never work the point
      at the same time.
  14. The same agent finishes that follow-up. Its report gives point `#3` as still
      beyond tier, so the point is escalated, not landed, and nothing of it is
      committed.
- **Acceptance:** one real live-testing session by Michael. Each ack takes one short turn,
  every finished fix is committed with nothing unfinished in its commit, no edit is lost,
  and no new permission prompt appears.

## 6. Alternatives rejected

- **An always-on global rule.** Inline work is better for design and debugging, and
  `global.md` is at its 180-line cap.
- **A harness worktree per fix.** The running app would not see the change until it was
  merged back, which defeats live testing.
- **Collecting feedback, then fanning it out at the end.** This loses the
  test–fix–reload loop.
- **Agents commit their own fixes.** Parallel commits race on git's index lock and mix
  each other's staged files.
- **Committing each fix as it lands.** A file shared with an agent still running would
  carry that agent's unfinished edits into the commit.
- **A file-claim registry agents write before editing.** It would give every fix its own
  commit, but it relies on each agent claiming before every edit, which nothing enforces.
  Quiescence commits are exact without any agent-side step. Their cost is that fixes
  sharing a file share a commit.

## 7. Risks

- **Shared commits.** Fixes that share a file share a commit, so reverting one reverts
  both. The commit message names each, so the revert is a deliberate choice.
- **Commit latency.** Under continuous load, commits wait for a pause in agent work. Exit
  always reaches quiescence, so nothing is left behind.
- **Briefs missing context.** Verbatim words plus the ambiguity question cover most of
  it. An agent that guesses wrong shows up on reload, and the follow-up goes to the same
  agent.
- **An unreported file.** An agent that forgets to list a file leaves it uncommitted;
  3.7 flags it rather than guessing its owner.
- **Cost.** Up to four agents run at once while the mode is on. Most are `sp-standard`;
  an `sp-architect` agent costs the most, so the driver picks it from the task, never by
  default.
- **SendMessage to a running agent.** The message may arrive mid-run or after the agent
  finishes. Either way the same agent handles it, and request ids tie each report to the
  work it covers (3.2).
- **An id an agent never reports.** Its agent stays busy and commits wait. Once every
  other agent is idle and no report has answered the id, the driver asks that agent
  about it (3.6). Holding commits until then is the safe failure: a guess would commit
  unfinished work.

## 8. Prompt budget

Expected net change: 0. Agents use the same tools inline work does, and `lockf` runs
sandboxed. The acceptance session checks this.

## 9. Implementation rulings (2026-10-07)

- **Only named ids count (§3.6).** A pressure scenario showed a driver landing and
  committing a point from a report with no "Ids covered" line, by inferring the id from
  what the agent had been sent. The skill now answers only the ids a report names and
  takes a status only from the report. A report outside the contract format answers
  nothing and is asked for again, under a new sub-id.
- **A missing commit message is asked for (§3.7).** The spec says a single point uses its
  agent's message, but not what happens when a finished report gives none. The skill asks
  the agent for it under a new sub-id and commits once it answers, never writing one
  itself. The agent is busy meanwhile, so commits wait for its answer.
- **An architect's beyond-tier stop is a stopped point (§3.3, §3.6).** Landing marks it
  stopped, not escalated, so its files hold back shared groups like any other stopped
  point, and it posts the stopped line.
- **The unanswered-id ask never changes the work (§3.6).** Asking an agent about an
  unanswered id requests its report on that id. It never cancels or redirects a
  follow-up.
- **The exit trigger is "done testing" (§3.8).** A bare "done" in answer to something
  else does not end the mode.
- **The suite pins the lock flags (§4.1).** Besides checking that `lockf` accepts the
  skill's flags, it checks that they are exactly `-k -t 900`.
- **Competing process skills (§3.2).** Michael's sessions load superpowers'
  using-superpowers, which sends bugs to systematic-debugging and features to
  brainstorming. The skill states that the mode is the process for every point: the
  driver invokes no brainstorming, debugging, verification or planning skill for a point,
  since the agent locates, debugs and tests and a point needing design is parked.
  Role-play could not show the risk. The injected text was used with its subagent
  opt-out removed, and neither this skill nor the skill before this sentence led a
  subject to call a competing skill (0 of 8 runs). The sentence stays as stated
  precedence.
- **Files are recorded unsplit (§3.5, §3.6).** One agent can hold several points, and its
  Files line is cumulative. The contract asks for one unsplit list, and landing records
  the whole list against every point the report names. Splitting by guess could leave a
  stopped point's half-finished edit out of the hold-back and commit it with a landed
  point.
- **Hand-off waits for the owner (§3.4, §3.6).** §3.6 step 4 hands the next queued point
  to the same agent unconditionally; the skill follows §3.4 instead. A point queued
  behind a stopped or escalated point waits for that point's owner (after an escalation,
  the new agent) until the point lands or is resolved.
- **A dropped state (§3.2, §3.6, §3.8).** When Michael drops a stopped point and its
  agent reports the undo, the point is dropped: never landed or committed, no longer
  holding back other groups, and listed at exit.
- **Follow-ups on committed points (§3.2).** The follow-up row also covers committed
  points, since commits happen at every quiescence.
- **Explore answers are not points (§3.2).** A question's Explore agent gets no point
  number and no request id, does not count as busy, never holds a commit, and its answer
  is relayed, not landed.
- **No worktree isolation for agents (§3.5).** The driver never passes
  `isolation: worktree`: the running app must see every change.
- **A point's files only grow (§3.3, §3.6).** The files recorded for a point are the
  union of every report naming it, across all its owners. The escalation brief asks the
  new agent to list the files it inherited. Otherwise a successor that listed only its
  own edits would drop its predecessor's edit from the commit or from the hold-back.
- **Statuses only for covered points (§3.5, §3.6).** A report gives a status only for
  points it covers an id of, and the driver ignores any other. A committed or dropped
  point reopens only through a new id for it.
- **Unanswered ids are asked across agents (§3.6).** §3.6 step 3 asks only the agent that
  just reported. The skill asks every busy agent whose latest report left an id
  unanswered, once per id, whenever every busy agent is such an agent. Otherwise an
  omission reported while another agent was still busy could hold commits and exit
  forever.
- **Commit paths come from git (§3.7).** A point's recorded files stay cumulative for
  ownership and hold-backs, but a commit stages only those git still reports as changed.
  A created-then-removed file drops out, a tracked deletion is kept, and a group with
  nothing left needs no commit.
- **Left as they are:** the default-branch fallback stays `main` or `master` when
  `origin/HEAD` is missing; a dropped point has no line format of its own; a borderline
  point naming a page but not a file may get `sp-mechanical`.
- **Pressure scenarios (§5).** Appendix A's 19 scenarios: 1 passed without the skill. With
  the skill at e7f4625 all 19 passed, and the id-less report scenario passed 3 of 3
  independent runs. The final branch review added Appendix B: S18–S23, and an SP arm with
  superpowers' session-start context and Skill tool. With the skill at dd07170 all 25
  passed, and the SP arm passed 4 of 4 with no competing Skill call. Without the skill, 3
  of the 6 new scenarios passed. The pre-merge review's fixes added S24–S27. With the
  skill at 9d721c7 all 28 scenarios then present passed, and with the skill at 95b3b35 the
  7 scenarios that reach the commit step, S27 among them, passed. Without the skill S24,
  S25 and S27 also passed and S26 failed.
