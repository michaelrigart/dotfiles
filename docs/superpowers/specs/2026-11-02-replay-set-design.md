# Replay set: deciding the quality-relevant removals from October's record

**Status:** In progress (plan docs/superpowers/plans/2026-11-02-replay-set.md, Codex-approved xr-1793629001-9de89da9)
**Date:** 2026-11-02
**Branch:** `replay-set` (the dotfiles have no MR; the pushed branch is the end)
**Sign-off:** Michael, 2026-11-02 (Codex approved round 4, xr-1793626109-f7b04e58)

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

The question: had no per-task reviewer run, would the gates that stay have caught what it caught?
If they recover those defects at the rate they recover their own, the per-task reviewer only
catches them earlier, at the cost of an Opus subagent per task.

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
worlds, because the removal is the per-task reviewer alone. Its October fix wave stays applied in
the injected tree and its findings form no class, and §4.4 runs it again as the first gate on the
injected tree. *(My call.)*

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

**Validation.** A defect counts only once it is shown present in the finished injected tree. A
blind judge sees the finding and the tree and answers whether the defect's failure scenario is
reachable there: yes, no or unclear. Only yes counts; the rest are unassessable. A later refactor
can leave a reverted helper unused, and a revert can break later code; the judge catches the first
case, and a coherence check catches the second wherever a repository has a cheap one (`bash -n` or
`zsh -n` on changed shell files, `cargo check`, a Ruby or Python syntax and load check). A revert
that breaks coherence is undone, and its defect is unassessable.

**Fix groups.** A defect's patch is the part of its fix range that belongs to it. Where one commit
fixes several defects, a judge splits its hunks by defect; hunks it cannot split make those defects
one group, reverted and re-applied together.

**Coverage gate.** A per-task defect that will not revert cleanly or validate gets one second
attempt: an `sp-standard` agent re-creates it by hand in the final tree from the finding and its
fix, and a blind judge confirms that the result is the same defect. If any per-task defect (P0–P2)
on the candidate branches is still unassessable after that, §4 is inconclusive and the report names
it, because a removal would give up a catch nobody measured. A branch qualifies only when all its
P0/P1 defects of both classes are assessable; its unassessable pre-merge P2s are counted.

`docs/superpowers/` is pinned to its state at plan approval. Spec and plan text edited during
execution often describes the fixed behaviour, and where it landed outside the fix commits it would
sit beside the reverted code and give the answer away. Pinning loses spec edits made for other
reasons, which can only add findings, never hide one. *(My call.)*

The tree goes into a scratch repository built as §7.1 describes, so the reviewer cannot read the
original fixes from git.

### 4.4 Runs: the gates that stay

Equal detectability is not enough: the question is whether the gates that stay would actually
recover what the per-task reviewer caught. So each run puts the injected tree through those gates,
in today's order, and two runs per case give the noise:

1. **The final whole-branch review:** an `sp-architect` subagent with the final-review prompt that
   subagent-driven development uses today, on the scratch repository.
2. **The Codex pre-merge loop** on one fresh thread, as xreview runs it today: today's reviewer
   instructions, findings schema and packet builder (`fit` on; the branch's spec and plan shown or
   omitted by today's switches), through `xreview-rpc` primitives as in packets §5.6, so no pane,
   ledger, gate or round counter is touched. Codex memories are off for these turns (§7.2). The
   daemon's model and effort stay as they are and are recorded.

After each review, a blind judge (§4.5) matches its findings to the defects still present, and rules
on each finding it cannot match: a false positive, or a real defect outside the inventory. An
oracle fixer then re-applies the patch of each matched defect, or of its group, as one commit with
a neutral message, standing in for Claude's fix round. Members of a group re-applied for another
member's match are repaired collaterally. After every re-application, each remaining defect whose
reverted hunks it touched is validated again (§4.3). The next round's request names the rejected
false positives, as a fix round's dispatch does today.

A run ends in one of three ways:
- an `approve` verdict;
- six Codex rounds *(my call; the report shows each branch's original round count beside it)*;
- **stalled:** a round matched no remaining defect and reported at least one real defect outside
  the inventory. The real loop would have fixed that defect and changed the tree; the replay has no
  fix for it, and reviewing an unchanged tree again would give detection chances the real loop
  never has.

Per run, each defect ends **recovered** (a review matched it), **unrecovered** (still present at
`approve` or after six rounds) or **censored** (still present when the run stalled, or repaired
collaterally). A censored defect is neither recovered nor missed.

### 4.5 Matching

One blind judge per review gets the defects still present (both classes, shuffled, without class
labels) and that review's findings. For each defect it names the finding that reports it, or none.
No judge learns the run, the class or the purpose.

### 4.6 Pass bar

The bar holds per run, because a real execution gets one run, not the union of two. It is strict on
purpose: a removal has to show that it gives up no catch at all, P2 included, because the quality
constraint covers every defect.

- **Assessable run.** The real loop recovered every pre-merge-class defect in October. A run is
  assessable when the simulation recovered at least 80% of that class in it and censored no more
  than a quarter of its per-task defects.
- **Fail:** in an assessable run, a per-task P0/P1 defect is unrecovered while every pre-merge P0/P1
  defect of that case was recovered. The gates that stay demonstrably missed a consequential catch,
  and the reviewer stays.
- **Pass:** every run of every case is assessable, and every per-task defect (P0–P2) is recovered in
  every run. A censored defect is not recovered, so any censoring rules out a pass.
- **Inconclusive:** anything else, including §4.3's coverage gate and any unrecovered per-task P2.
  §4.7 applies.

The pre-merge class is Codex-detectable by construction (Codex found each of its defects once) and
the per-task class is not, which tilts the comparison towards keeping the reviewer.

The report lists every per-task defect left unrecovered in any run, with its severity and one line
on what it was, for Michael to read. It also gives the reviewer's October cost (dispatches, tokens,
and wall time per task, from the transcripts) and the extra rounds the simulation needed without it.

### 4.7 What it cannot see, and the confirmation

It cannot see knock-on effects: later tasks built on a defect, or an implementer working
differently because no review follows. The oracle fixer is also better than a real fix round, which
can introduce new defects (§10: 39 of 130 known-real pre-merge findings came from round 2 or
later); that tilts towards removal, which is why the P0/P1 rules are absolute. After an
inconclusive result, or on Michael's request after a pass, a confirmation replay runs: 4 cases × 2 runs × 2 arms (with and without the per-task
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

The recommendation can only be **keep** or **inconclusive**, never remove:
- **Keep** when any design-class P0/P1 finding occurred. The pre-merge diff cannot show it, so
  without the checkpoint it ships or costs a rework.
- **Inconclusive** otherwise. Visible in a diff is not the same as detected, so removing the
  checkpoint needs downstream evidence of its own: the §4 simulator on injected plan defects, or a
  §4.7-style replay, designed then as an amendment to this spec.

The inventory and the net cost go to Michael either way, and he rules.

## 6. Codex memories: a switch in `xreview-replay.py`

A `memories` switch in `.scripts/xreview-replay.py`: arms A and A′ with memories on and B with
memories off. The pass bar is packets §5.5: B recalls at least the lower of A and A′ and misses no
P0/P1 that both found. The report adds tokens per turn for each arm.

October's reviews cannot be the cases. Today's memories describe them, which would hand A and A′
the answers, and no older snapshot exists (the memories directory's own git history starts on
2026-11-02). So §6 runs forward, on snapshots taken just before each case:
- **Snapshots.** While §6 collects cases, `process-replay memories-watch` hashes the live memories
  every minute, logs every poll with its time and hash, and copies them on each change (APFS clones,
  without `.git`) into the state directory. It reads `~/.codex/memories` and writes nothing outside
  the state directory.
  Michael starts it as a background process or a launchd job for the collection period. The copy
  frozen on 2026-11-02 at 13:21 UTC (`~/Code/.replay/snapshot/2026-11-02/codex-memories/`) is the
  first snapshot.
- **Arms.** A and A′ read the latest snapshot taken before the case's round-1 dispatch. That is what
  the deployed reviewer had then, the branch's earlier spec and plan reviews included, and nothing
  from the review itself or later. B reads no memories.
- **Cases.** Pre-merge round-1 reviews with at least one known-real P0–P2 finding, from branches
  started after the watcher, up to 10, taken as they accrue; at Michael's usual pace that is about a
  week. A case is kept only when the poll just before its dispatch and the poll just after it log
  the same hash, so the snapshot is exactly what the reviewer had. A case whose surrounding interval
  shows a change, or that has a missing poll, is dropped, because the order of change and dispatch
  cannot be established.

## 7. Isolation

### 7.1 No leaked answers

- One builder makes every scratch repository, §6's included: only the objects reachable from the
  merge base, plus one squashed commit of the tree under review, written into an empty object
  store, with no remote and no alternates. `xreview-replay.py`'s `scratch_clone` is not used,
  because its alternates let `git fsck` and `git show` reach later fix commits. A test proves that
  a later fix commit cannot be resolved in a scratch repository.
- Each run's rollout is scanned for reads or commands that name the original checkout or one of its
  `wt` siblings. Such a run is void and runs once more.
- Each judge gets only its input file.

### 7.2 Codex memories

Replay turns neither read memories (except §6's A and A′, which read a snapshot) nor feed memory
generation, so no replay
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

- Codex: hard stops at 100M tokens for §4 and 20M for §6, with at most three turns at once. Runs
  also pause while the latest rollout reports weekly usage at 80% or more, and resume after the
  reset. For scale, the packets replay ran 88 turns on 38M.
- Claude: judges are `sp-standard` subagents, as in packets §5.4. The final whole-branch reviews of
  §4.4 are `sp-architect`, one per run.
- §4 and §5 run once the harness is built and its tests pass: expected one or two nights. §6 waits
  for its cases, about a week.
- §4 and §5 run in either order, §6 once its cases exist. Adoption follows Michael's order (per-task reviewer, Codex
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
- Tests: `tests/process-replay.test.sh`, a dry run on fixture cases with a stubbed daemon. It covers:
  - case selection and the coverage gate;
  - injection, fix groups, the oracle fixer re-applying exactly one defect's or group's patch,
    collateral repairs counted as censored, and squashing;
  - the stall rule and the false-positive rulings carried into the next round;
  - `memories-watch` logging each poll and snapshotting on change, a case taking the latest
    snapshot before its dispatch, and a case dropped when its surrounding polls differ or one is
    missing;
  - a scratch repository that cannot resolve a later fix commit;
  - judge inputs that carry no class, run or arm;
  - the loop ending at `approve` or after six rounds;
  - the per-run pass bar, assessable runs and censoring included.

  The existing `xreview-replay` and `measure-interventions` suites get additions for their new
  options.
- Results go in §11 of this spec. Raw files stay in `$XDG_STATE_HOME/process-replay/<date>/` and
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

Run of 2026-11-03 (Part B). Harness `f0919ec9b5bec2dee4df56cb5659e9b065dc7a22`, state
`~/.local/state/process-replay/2026-11-03`, replay home `nomem`. Michael stopped it in §4's run
step (runbook Part B step 5) after the leak scan voided three of four runs; no replacement run was
started. **No removal is recommended from this run.**

### 11.1 Per-task reviewer (§4): inconclusive

`report` gives INCONCLUSIVE: two cases, one run, and the coverage gate fails.

**Cases.** 164 branches examined, all 23 candidates opened, 2 qualified. That is below §4.1's 10–12
and is reported, not padded.

| Case | Repository | Branch | Counted defects | October pre-merge rounds |
|---|---|---|---|---|
| c97ff647b | VM.Deployments.Docker | feature/update-edge-stack | 6 per-task, 1 pre-merge | 5 |
| cf4b66353 | dotfiles | feat/agent-skills | 2 per-task, 1 pre-merge | 2 |

| Why the other 162 did not qualify | Branches |
|---|---|
| No task review joined | 68 |
| No merge evidence | 30 |
| Fewer than two task-review fix ranges | 25 |
| No pre-merge defect to calibrate against | 13 |
| Merged outside the window | 10 |
| A P0/P1 defect not shown present | 6 |
| The last round did not approve | 5 |
| A round tip is gone | 3 |
| Fewer than two (assessable) per-task P0–P2 defects | 2 |

**Coverage gate (§4.3): fails.** 75 per-task defects are unassessable after the second attempt, so no
run could pass whatever the runs showed.

| Reason | Defects |
|---|---|
| The recreation does not apply to the injected tree | 34 |
| judge-present answered unclear | 30 |
| judge-present answered no on the injected tree | 6 |
| judge-same did not find the same defect | 3 |
| The recreation changed nothing | 2 |

**Runs (§4.4).** Four started, two per case. The final-review leak scan voided three:

| Run | Case | Outcome |
|---|---|---|
| 93b16f3d | c97ff647b | Final review recovered 4 of 6 per-task defects; 2 censored. Stopped before its first Codex round; the pre-merge defect is still present. |
| 66ad81cc | c97ff647b | Void, a false positive (11.4, item 3) |
| 7f3b624a | cf4b66353 | Void, a false positive (11.4, item 3) |
| 3819843a | cf4b66353 | Void, a real leak: the reviewer ran `git log` on `feat/agent-skills` in `~/.local/share/chezmoi`, the original repository, and listed `~/.claude/skills` |

The reviewer was told the review was read-only. Isolation rests on the scan, not on the brief.

**The per-task reviewer's October cost** over the two cases: 27 dispatches, 13.35M tokens, 49.9 wall
minutes (c97ff647b 15 / 7.99M / 32.8 min; cf4b66353 12 / 5.36M / 17.1 min). 15 per-task P3 defects
are listed in the report, not counted.

### 11.2 Plan checkpoint (§5) and Codex memories (§6)

Not run.

### 11.3 Cost of this run

Claude subagents across both Part B sessions: 566 transcripts, 1.73M output tokens, 192M cache reads,
22.6M cache writes. Codex: no §4 round ran.

### 11.4 What has to change before a rerun

Each item below changed the outcome; items 1–3 are defects, item 4 is a design limit.

1. **Build checks run through mise shims.** `process-replay.py` starts with `#!/usr/bin/python3`, so
   `checks.py` calls the mise shims for `python3`, `ruby` and `cargo` inside the work tree. In a
   repository with a `mise.toml`, every shim exits with "Config files … are not trusted", so every
   syntax check and `cargo check` failed in VM.Deployments.Docker, curato and tagteam. At its worst
   (inject #4) that made 10 defects unassessable and 6 incoherent. It predates this session:
   da2708893 was already out in the previous session's last inject. From inject #5 on, every
   harness command ran with
   `MISE_IGNORED_CONFIG_PATHS=$S/work`, which trusts nothing and lasts for one process. Fix: run the
   checks with tools resolved outside the work tree, or set that variable in the harness.
2. **The 60,000-character cut on judge input.** judge-present sees each file cut at 60,000
   characters. In large files (`dashboard-thuis.json`, `git-push-guard.py` near line 1188,
   `executable_xreview` near line 1095, the forge-guard tests, tagteam's `input.rs`) the cut falls
   before the code the finding is about, and the judge answers unclear. 21 of the 30 unclear answers
   and 5 of the 6 no answers were given on files cut this way. It reached three of the six branches
   disqualified for a P0/P1 defect not shown present (bb2c8d04b, bb1f2a025, b8631963c). Fix: show
   each file around the finding's location and the fix's hunks, not from the top.
3. **The leak scan voids clean runs (§7.1 against §7.3).** §7.3 puts the driving session, and so
   every subagent's cwd, in `~/Code/.replay`, which holds the forbidden `snapshot/`. The matcher
   resolves relative text against that cwd, and glob-shaped text that is not a path matches
   `snapshot`: `:\s*` in a `sed` regex yields the piece `s*`, and
   `tar --include='*/SKILL.md'` yields `*/SKILL.md`. It also counts every `chezmoi` call as reading
   `~/.local/share/chezmoi`, even `chezmoi --version` and `chezmoi --source <own scratch> managed`.
   66ad81cc is the first cause alone; 7f3b624a is both. Rescanned with each run's scratch as the
   cwd, 66ad81cc names nothing and 7f3b624a names only its four `chezmoi` calls; 3819843a still
   names the original. Fix: keep forbidden roots out of the driving session's directory, and judge
   a `chezmoi` call by the source and destination it names.
4. **Recreations that cannot apply.** 34 defects: a recreation is made against the final tree, and a
   sibling group's revert in the injected tree changes the same lines (§4.3's known limit). It
   reached four of the six disqualified branches (b64e632c6, bfb0da41d, bb1f2a025, b8631963c).
   Where fixes sit this close together, this alone fails the coverage gate. It needs a design
   answer, such as recreating against the injected tree, before a rerun can pass.

Items 1–4 do not address the causes of 15 of the 75 unassessable defects: 9 unclear and 1 no answer
on files shown whole, 3 recreations judged not the same defect, and 2 that changed nothing. While
any of them stays unassessable, §4.3's gate fails again. The sixth disqualified branch, b4e316dca,
is neither item: an unclear answer on a whole file and a fix that does not revert.

Smaller issues, each in the run notes:
- A fix range attributed to the wrong finding: d409e8f15, a core-spec A.3 finding in tagteam, maps
  to a range that edits only `SECURITY.md`.
- The lexical dangling-name check reads words in non-code files as names ("local is still used by
  .gitignore", "delete is still used by README.md"): 4 defects marked incoherent.
- 11 receipt nonces carry differing receipts (cross-repository receipts with per-repository targets);
  their rounds are left out, so unifi-mcp, worktreeinclude-vault-password and the VM.Inference copy
  of inference-upload-errors never chained.
- Group g7f4887d8 joined `feat/mise-trust-worktrees` through a quoted range; harmless here.
- Judge 019e0f7a mapped reviewer labels to severities (Critical to P0) instead of the brief's scale.
- Operations: the auto-mode classifier denied judges' shell writes, and about 20 judges reported a
  write that had not happened; every answer was checked on disk and redone with the Write tool.
  Dispatch was capped at 20 subagents at once.

### 11.5 Recommendation

| Removal | Recommendation |
|---|---|
| Per-task reviewer | None: keep it. The result is inconclusive for structural reasons, not on the evidence. A rerun needs items 1–4 fixed, the 15 defects above resolved, and more qualifying cases; with two cases even a clean pass falls short of §4.1. §4.7's confirmation replay remains Michael's call. |
| Plan checkpoint | Not measured; unchanged. |
| Codex memories | Not measured; unchanged. |

## 12. Left to the builder

- Whether an injected tree gets a build check, where a repository has a cheap one.
- The memories mechanism of §7.2.
- Script and subcommand names, if a better fit appears. The judging conventions and the pass bars
  are fixed.

## 13. Implementation notes

Rulings made while building the harness (branch `replay-set`, plan
`docs/superpowers/plans/2026-11-02-replay-set.md`; the full ledger of rulings lives with the plan's
execution). They settle what §12 left open and how the pass bars apply to the data as it is. The
methods and bars above are unchanged except where a line says so.

**Mechanism and isolation (§7)**
- Memories (§7.2): replay turns run on a second Codex daemon with its own home
  (`$XDG_STATE_HOME/cxh/<name>`, short enough for its socket) and its own login. A probe must
  pass before any turn. There is no fallback onto Michael's daemon: if the probe fails, the run
  stops for Michael. The home copies skills, rules and plugins instead of linking them, and drops
  `notify`.
- Scratch repositories live physically under `$XDG_STATE_HOME/review-work/scratch/<label>`.
  Judges and final reviewers each get their item staged in its own directory under
  `review-work/items/`, holding only that item's files.
- The leak scan (§7.1) covers Codex rounds, the final reviewer and its subagents, and §6's arms.
  A run is void when a reviewer reads or runs anything under a forbidden root:
  - the original checkout and its `wt` siblings;
  - the harness's state, staged items and scratches;
  - the snapshot;
  - the whole of `~/.codex` and `~/.claude` (sessions, memories, transcripts, file history);
  - the replay homes, the xreview state, and §6's watcher.

  Each path a tool call names is resolved first: the call's working directory, `cd`, `$PWD`, `~`
  and the home and XDG variables, `..`, and symlinks. It is then tested against those roots by
  real-path containment.

  Allowed subtrees apply after resolving:
  - the run's own scratch or staged item;
  - instruction files: `~/.codex` skills, plugins, rules and `AGENTS.md`, `~/.claude` plugins,
    skills, agents and `CLAUDE.md`, and the replay home's own copies of them. These are not
    allowed in dotfiles cases, where the deployed files are the repository's later state;
  - an A/A′ arm's own memories;
  - a final reviewer's own transcripts and its session's `tool-results/`, under whichever
    project directory Claude Code saved them.

  A recursive search rooted above a forbidden root counts as a read. Grep patterns and
  redirection targets are not search roots (a redirection target is still checked as a path); command substitutions inside a pattern are still scanned.
  Running `chezmoi` counts as reading the original dotfiles. A rollout that cannot be read counts
  as a leak. Dotfiles cases may void more often than others; that verdict is correct. The
  remaining limits (unknown variables, paths built at run time, reads spread over separate calls,
  ANSI-C quoting, `env -C`) are listed in `codex.py` (Michael's restructure, 2026-11-03).
- Merge evidence runs `git merge-tree` in a private view repository whose alternates are the
  snapshot (or the original's objects). Git then refreshes those packs' modification times. The
  content is unchanged.

**Cases and defects (§4.1, §4.2)**
- "Merged" needs local merge evidence (ancestry, a rebase by `git cherry`, or a squash by tree
  equality) dated inside the window. A branch keeps every review it had, whatever the date.
- Each task review joins the one branch whose own commits hold it, by ancestry or else by
  patch-id. A review claimed by two branches joins neither.
- A candidate needs at least two task-review fix ranges of its own. Judge inputs are opened in
  stages, most recent merge first (`cases --open N`).
- **Qualification also needs at least one counted pre-merge defect that is assessable** (Michael,
  2026-11-02). Without one, §4.6 has nothing to calibrate a run against, so such a case could never
  be assessable and would rule out a pass. The slot passes to the next candidate.
- Each (task, branch) gets one judge, which reads every review and re-review report. Findings that
  describe breakage a fix introduced are dropped.

**The injected tree (§4.3)**
- Only counted (P0–P2) defects are reverted. Adjacent fixes that cannot be reverted separately
  form one group. Test hunks belong to the defect they test.
- Validation runs to a monotone fixpoint (Michael's restructure, 2026-11-02):
  - each round builds the tree from the final tree with the active defects reverted;
  - judge questions are keyed by a digest of exactly what the judge sees;
  - whatever fails leaves, and the active set only shrinks;
  - each per-task defect gets one recreation attempt (against the final tree, checked for syntax).
- The shipped tree is the fixpoint tree, and every counted defect was judged present on it. A
  defect whose group stays reverted for another member is unassessable, with no recreation.
- Coherence means a syntax check per revert, a lexical check for names still used elsewhere, and
  `cargo check` once per distinct tree. A missing or timed-out tool is recorded, not fatal.
- The coverage gate covers the branches that were built.

**Runs and the bar (§4.4, §4.6)**
- The stall rule applies after every review, the final review included. At the sixth round,
  approve outranks rounds, which outranks stalled.
- A failed Codex round is retried once. Matched repairs are applied one at a time. Collateral
  group members are censored. The remaining defects are tracked by line.
- A run of a case with no counted pre-merge defect is not assessable (moot after the
  qualification rule above). Report totals count assessable runs only.

**Plan checkpoint (§5)**
- The lost `omit_plans` saving is reported two ways: plan bytes ÷ 3.5, and 0.19 × the tokens of
  the October pre-merge turns that omitted a plan. Each has its net figure. The recommendation is
  `keep` or `inconclusive`, with a flag when classification is incomplete.

**Codex memories (§6)**
- The watcher logs every poll with its interval. A memories directory holding any symlink gives
  an unstable poll.
- A case is the branch's first pre-merge round on any thread.
- Each arm's packet is built on its own scratch, and each memories home is probed before its
  turns.

**Settled in the pre-merge review (Codex, nine rounds, approved xr-1793726019-522e06a8)**
- Every command takes its locks once, at entry, and holds them until it exits: the state's
  `run.lock` (exclusive, shared, or `run` mode), then the replay daemons' lock. A command that
  finds a lock held exits 1 having changed nothing. One replay daemon runs at a time. The lock
  moves to another home only once the previous daemon is confirmed down, and a home's login is
  settled only then.
- Each judge kind declares one answer schema, and one validator checks every answer against it.
  An incomplete or malformed answer is asked again. A staged answer counts only for the input it
  was staged from. Changing an input sets aside its old answers; they are kept, never deleted.
- Evidence is bound to its inputs. Each run, plan-review verdict and §6 arm records a digest of
  what it was made from, and it counts only while those inputs are unchanged. Superseded runs are
  kept and marked, and fresh runs replace them.
- The weekly pause and the Codex token stop are checked before every turn, probes included,
  against one shared tally. The stop blocks only new turns, so the overshoot is at most one turn
  per job in flight. A stopped round is redone whole.
- Receipts are deduplicated by nonce. Copies that conflict are dropped and reported.
- A §4 run needs a home whose record, config, memories directory and probe all say memories are
  off. Each §6 arm's home must match that arm's setting the same way.
- The suites set `HOME`, `CODEX_HOME` and `XDG_STATE_HOME` to fixtures inside the test process
  itself, so no test reads the live homes.

**Part B** runs from an export of the pushed commit, never from the shared checkout, and §11
records that commit.
