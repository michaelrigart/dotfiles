# Replay set: deciding the quality-relevant removals from October's record

**Status:** In progress
**Date:** 2026-11-02
**Branch:** `replay-set` (the dotfiles have no MR; the pushed branch is the end)
**Sign-off:** pending

## 1. Why

The lab-guidance review (vault, `1. Inbox/2026-10-31-agent-setup-vs-lab-guidance` and
`2026-11-01-agent-setup-sources-and-security`) found a process layer built for older models.
Anthropic's harness-removal method is to drop one quality-relevant component at a time and
measure each removal. No published study compares a heavy and a light process on the same work, so
October's own record has to.

The goal: for each removal, a measured answer to "does quality hold without it, and what does it
save?", cheap enough to give results within days. Michael then rules on each one. He wants the way of
working to improve in quality and in speed; quality is the bar, speed the payoff.

## 2. Scope

| Removal | In scope | Measured by |
|---|---|---|
| Per-task reviewer: the reviewer subagent per task in subagent-driven execution, its fix rounds and re-reviews | yes | §4, re-injection |
| Codex memories in review turns | yes | §6, a switch in `xreview-replay.py` |
| Codex plan-review checkpoint | yes | §5, retrospective |
| Main-session effort | **no.** Michael, 2026-11-02: the main session stays at xhigh, and any effort cut needs measured proof that results hold | — |

Non-goals:
- Re-running October changes as full sessions. An earlier draft did that: about 80 multi-hour
  sessions, rejected on cost. The one exception is §4.7's confirmation, and only on Michael's go.
- Changing the setup. This spec measures. Each removal that passes becomes its own small change
  after Michael's ruling.
- The review-loop policy (round caps, triage). It stays as it is (Michael, 2026-11-01).
- Replacing the per-task reviewer with something else, such as a deterministic diff check. Each
  removal is tested as a pure removal, one component at a time.

Anti-goals:
- A pass that only looks like one because the replay leaked the answer (§7.1).
- A replay that moves the 2026-11-15 reading or later ones (§7.3).

## 3. Method

All three decisions are answered from what October recorded (review transcripts, xreview ledgers
and rollouts, git history) plus fresh Codex review turns on reconstructed trees. No agent writes
code. Judges are blind: they see findings, diffs and neutral labels, never the arm, the defect's
class or the purpose (prior art: `2026-10-25-xreview-review-packets-design.md` §5.4).

## 4. Per-task reviewer: re-inject what it caught

The question: had no per-task reviewer run, would the final gate have caught what it caught? If the
Codex pre-merge review finds those defects about as readily as it finds its own, the per-task
reviewer only catches them earlier, at the cost of an Opus subagent per task.

### 4.1 Cases

10–12 branches merged between 2026-10-01 and 2026-11-01 that ran the full path: a spec, a plan,
subagent-driven execution with per-task reviews, and a Codex pre-merge review. They are spread
across repositories (the dotfiles, tagteam, VM.Portal, VM.Inference, curato and any other with
surviving transcripts), at most four from one repository, most recent first. A branch qualifies
when it has a full-branch pre-merge round 1 (not a manual slice or a single-commit range), its round
tips exist locally or in the snapshot (§9), and at least two of its per-task defects (§4.2) can be
re-injected (§4.3). Branches whose ledgers point at deleted scratch clones (tagteam `m5-admin` and
`token-report`) cannot qualify.

The final whole-branch review that subagent-driven development runs before pre-merge stays in both
worlds, because the removal is the per-task reviewer alone. Its fix wave stays applied in the
injected tree and its findings form no class. It would also have seen the re-injected defects and is
not replayed, so the result is conservative: the real gate is stronger than the one measured.
*(My call.)*

### 4.2 Two classes of known defect

- **Per-task class.** Findings of the task reviewers on that branch: subagents whose `meta.json`
  has `agentType` `sp-reviewer`, or `sp-architect` used as a task reviewer, with a description
  that names a task number, such as "Review Task 16" or "Re-review W3 Task 2 fix round 3". The task
  number keeps out Claude's re-reviews of Codex fixes ("Re-review pre-merge fix round 1"). The fix
  is the range the re-review prompt names (`FIX_BASE`/`HEAD` or a `review-<a>..<b>.diff` path);
  where a prompt names none, the commits between the reviewed commit and the re-review. A blind
  judge sees the finding and that fix and answers yes, no or unclear, as in packets §5.2; only yes
  counts. The judge also maps the finding's severity to P0–P3.
- **Pre-merge class.** The branch's Codex pre-merge findings at P0–P2 that are known-real by the
  existing method (fixed between that round's tip and the next round's), restricted to defects
  already present at the round-1 tip: round-1 findings, and later findings whose faulty code
  already existed at the round-1 tip. A later round often finds a defect Codex missed in round 1,
  and counting those would lower pre-merge recall and loosen §4.6 towards a false pass.

In both classes, a defect that a fix introduced ("new breakage in the fix diff") is dropped: once
every fix is reverted it is not in the injected tree. Both classes count P0–P2 only; per-task
findings the judge maps to P3 are listed in the report but not counted. Several findings of one
defect are merged into one. Each defect records its severity, its fix commits and its files.
*(The round-1 restriction, the P0–P2 limit and the task-number filter are my calls.)*

### 4.3 The injected tree

Start from the branch's final tip and revert the fixes of every known defect of both classes
together. Each fix is reverted whole, tests included, so its regression test does not give the
defect away. The result approximates the tree the first pre-merge round would have met had no
per-task reviewer run. A fix that does not revert cleanly is dropped, and the drops are counted.

`docs/superpowers/` is pinned to its state at plan approval. Spec and plan text edited during
execution often describes the fixed behaviour, and where it landed outside the fix commits it would
sit beside the reverted code and give the answer away. Pinning loses spec edits made for other
reasons, which can only add findings, never hide one. *(My call.)*

The tree goes into a scratch repository whose history is the merge base plus one squashed commit,
so the reviewer cannot read the original fixes from git. It has no remote, no alternates and
nothing else that refers to the original checkout, so `xreview-replay.py`'s `scratch_clone`, which
reads the source's objects through alternates, is not reused for it.

### 4.4 Runs

Three independent round-1 pre-merge reviews per case, each on a fresh thread, with today's
reviewer instructions, findings schema and packet builder (`fit` on). The packet is built as
today's dispatch would build it for that branch, so the branch's spec and plan files are shown or
omitted by today's switches. Turns run through `xreview-rpc` primitives, as in packets §5.6: no
pane, ledger, gate or round counter is touched. Codex memories are off for these turns (§7.2). The
daemon's model and effort stay as they are and are recorded.

### 4.5 Matching

One blind judge per case gets the defect list (both classes, shuffled, without class labels) and
each run's findings under random labels. For each defect it names the run finding that reports it,
or none.

### 4.6 Pass bar

Recall per class is the share of that class's defects a run found, pooled over the cases, and the
comparison uses the mean of the three runs. Noise is the pre-merge class's highest run recall minus
its lowest.

- **Pass:** per-task recall is at least pre-merge recall minus the noise, *and* the share of
  per-task P0/P1 defects found in no run is no higher than the same share in the pre-merge class.
- **Fail:** both rules fail.
- **Borderline:** exactly one fails. §4.7 applies.

Single-round recall is low in absolute terms (packets §9: 0.17–0.25 on pre-merge rounds), so the
bar compares the two classes rather than setting a threshold. The pre-merge class is
Codex-detectable by construction, since Codex found each of its defects once; the per-task class is
not. That tilts the comparison towards keeping the reviewer, so a pass is strong evidence.

The report also lists every per-task defect that no run found, with its severity and one line on
what it was, for Michael to read. It gives the reviewer's October cost as well: dispatches, tokens,
and wall time per task, from the transcripts.

### 4.7 What it cannot see, and the confirmation

It cannot see knock-on effects: later tasks built on a defect, or an implementer working
differently because no review follows. After a borderline result, or on Michael's request after a
pass, a confirmation replay runs: 4 cases × 2 runs × 2 arms (with and without the per-task
reviewer), each from the case's plan commit, in a scratch clone with no refs past it, through to
Codex pre-merge approval. That is 16 sessions, and only on Michael's go. Its design is settled
then, as an amendment to this spec.

## 5. Plan-review checkpoint: what its findings were

The question: do plan reviews catch anything the pre-merge review would not?

### 5.1 Cases

Every October plan-checkpoint review round with at least one P0–P2 finding judged known-real: the
next plan round's diff fixed it.

### 5.2 Classification

A blind judge per plan sees each known-real finding, the plan excerpt it names and its fix, and
classifies it:
- **Diff-visible:** a defect in code or tests that the plan dictates, which the pre-merge diff would
  show.
- **Design:** scope, sequencing, a missing or wrong requirement, a task that cannot be satisfied,
  or a risk only the plan shows. The pre-merge review sees only the result, so this class either
  ships or costs rework.
- **Plan-only:** wording, bookkeeping or plan format, with no effect on the code.

### 5.3 Report and recommendation

Per plan: rounds, wall time spent in plan review, and findings by class and severity, plus the cost
per design-class P0/P1 caught.

The saving is reported net. `omit_plans` leaves a plan out of the pre-merge packet only when an
approved plan receipt covers it (packets §3.5), so without the checkpoint every pre-merge packet
shows the whole plan again; packets §9 measured about 19% fewer tokens per pre-merge turn with it.
The report estimates that lost saving from October's pre-merge receipts.

The recommendation: keep the checkpoint if design-class P0/P1 findings occur in at least two plans;
otherwise propose removing it. Michael rules. *(My call: an absolute count, because a single
design-level P0/P1 caught before execution saves a rework.)*

## 6. Codex memories: a switch in `xreview-replay.py`

A `memories` switch in `.scripts/xreview-replay.py`: arms A and A′ with memories on, as deployed,
and B with memories off, on up to 10 pre-merge cases with known-real findings, selected as in
packets §5.1. The pass bar is packets §5.5: B recalls at least the lower of A and A′ and misses no
P0/P1 that both found. The report adds tokens per turn for each arm.

Today's memories already contain these very reviews, which helps A and A′. A pass for B is
therefore safe evidence; a fail is ambiguous, and then memories stay on.

## 7. Isolation

### 7.1 No leaked answers

- Scratch repositories hold the merge base plus one squashed commit (§4.3), or, for §6, the
  historical round's tip as in packets §5.3. None has a remote.
- Each run's rollout is scanned for reads or commands that name the original checkout or one of its
  `wt` siblings. Such a run is void and runs once more.
- Each judge gets only its input file.

### 7.2 Codex memories

Replay turns neither read memories (except §6's A and A′) nor feed memory generation, so no replay
content lands in Michael's memories. The builder settles the mechanism (a per-thread setting, or a
second daemon with its own configuration that never touches the daemon Michael's panes use) before
any turn runs. If neither works, stop and report.

### 7.3 The 2026-11-15 reading and later ones

- Codex turns go through `xreview-rpc`, so no ledger entry or receipt is written.
- The Claude session that drives the harness and dispatches the judges runs from
  `~/Code/.replay/`. `measure-interventions.py` excludes that project key by default
  (`--exclude-project`).
- Running the replay changes no setup, so it may run before 2026-11-15. Adopting a removal waits
  until after the 2026-11-15 reading.

## 8. Budget, order and timing

- Codex: a hard stop at 50M tokens across §4 and §6, with at most three turns at once. For scale,
  the packets replay ran 88 turns on 38M.
- Claude: judges are `sp-standard` subagents, one case per judge, as in packets §5.4.
- The replay runs once it is built and its tests pass; expected wall time is under a day.
- §4, §5 and §6 run in any order. Adoption follows Michael's order (per-task reviewer, Codex
  memories, plan checkpoint), one removal per commit, each recorded with its result.

## 9. Deliverables

- `.scripts/process-replay.py`, for §4 and §5: `snapshot`, `cases`, `inject`, `run`, `match`,
  `report`, `cleanup`, and `--dry-run`. It reuses `xreview-replay.py`'s turn runner, rollout
  reading and judge-file conventions by import, never by copy.
- `snapshot` runs first. Transcripts can expire under `cleanupPeriodDays: 30`, and most October
  round tips in the squash- and rebase-merged repositories survive only as unreachable objects
  until `git gc` prunes them (VM.Inference 32 of 35, tagteam 159 of 168, curato 30 of 49). It copies
  the task-review transcripts and their controllers' transcripts (task reviewers often run one level
  down, under a plan-run controller subagent) into the state directory, and reads commits from the
  object snapshot below, writing nothing into the original repositories.
- The object stores of VM.Portal, VM.Inference, curato, opsmaster, tagteam and the dotfiles were
  copied on 2026-11-02, before sign-off, to `~/Code/.replay/snapshot/2026-11-02/<repo>/objects`
  (APFS clones, so no extra space until the originals change). `snapshot` uses them as a
  read-only object source for scratch repositories, never as alternates.
- The `memories` switch in `.scripts/xreview-replay.py`.
- `--exclude-project` in `.scripts/measure-interventions.py`.
- Tests: `tests/process-replay.test.sh`, a dry run on fixture cases covering case selection,
  injection and squashing, judge inputs that carry no class or arm, and the report arithmetic; and
  additions to the existing `xreview-replay` and `measure-interventions` suites.
- Results go in §10 of this spec. Raw files stay in `$XDG_STATE_HOME/process-replay/<date>/` and
  are never committed.

## 10. Data checked before sign-off

Read-only, 2026-11-02:
- Per-task findings link to their fixes. October re-review prompts give 246 distinct fix ranges,
  223 single commits and 23 multi-commit, all linear, none amended; 38 prompts name no range. The
  fixes touch code and tests (168), code only (32), tests only (33) or docs only (13).
- 90 October plan-checkpoint rounds cover about 35 plans in 13 repositories; 31 plans had at least
  one `changes` round, and every round has its rollout. Older receipts lack `plan_blobs`, which are
  derived from git as `enriched()` does. One VM.Portal thread carried several plans with a null
  branch, so "next round" is matched per plan file.
- All 711 October pre-merge receipts have their rollouts. 327 of them are manual slices or
  single-commit ranges, not full-branch reviews.
- 39 of 130 known-real P0–P2 pre-merge findings in full-branch chains came from round 2 or later
  (the reason for §4.2's round-1 restriction).
- 114 final whole-branch reviews and 88 final-wave re-reviews ran in October (§4.1).

## 11. Results

Filled in after the run.

## 12. Left to the builder

- Whether an injected tree gets a build check, where a repository has a cheap one.
- The memories mechanism of §7.2.
- Script and subcommand names, if a better fit appears. The judging conventions and the pass bars
  are fixed.
