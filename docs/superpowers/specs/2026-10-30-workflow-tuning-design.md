# Workflow tuning: faster runs at the same quality bar

**Status:** In progress (branch `improvements`; the dotfiles have no MR)
**Date:** 2026-10-30
**Branch:** `improvements`
**Sign-off:** delegated. On 2026-10-31 Michael said "do what needs to be done so that you can run
much faster without lowering the quality", then "continue in full autonomy". Codex approved
round 6 (xr-1793410751-c1fc5622).

Follows the whole-flow review of 2026-10-30 against Michael's five goals: safe autonomy, simple
high-quality code, lean meaningful tests, honest pushback, and willingness to refactor and
reopen past decisions. It was measured against official Anthropic and OpenAI guidance, and Codex
was consulted on the recommendations and Michael's answers. On 2026-10-31 Michael added the
goal that shapes §9–§12: "run much faster without lowering the quality". Every change here adds
zero permission prompts, and none removes a check that guards quality: the bar (tests, the
Engineering judgement rules, Codex's pre-merge review and its merge gate, Michael's merge) is the
same for every change.

## Problem

Measured over 2026-10-16..30 (91 sessions; costs are API-price estimates, and plan limits are
not a constraint today):

1. **Context, not caching, drives usage.** The cache hit rate is 97%. Cache reads are 67% of
   cost and cache writes 23%; 18% of calls carried 400k or more tokens of context. Sessions
   longer than 8 hours of wall time (44 of 91) carry 95% of spend; the largest ran 73–206 hours.
   Michael already runs `/clear` before unrelated work, but nothing tells him when a session is
   big, or offers a natural point to start fresh.
2. **sp-architect does work outside its charter.** It took 33% of all spend in 254 dispatches.
   By task: implementation, plan-run controllers and merges 27%, fix rounds 25%, writing specs
   and plans 23%, reviews 21%. On 2026-10-29 Michael already decided that controllers run as
   sp-standard, but nothing in the agent descriptions or the subagent table says so.
3. **The instructions barely cover code quality, test scope and pushback.** `global.md` says
   "Suggest improvements when something better exists" and nothing about overengineering, design
   quality, which tests to write, or disagreeing. Anthropic's prompting guidance supplies
   wording for each (avoid over-engineering, no test-specific hacks, say so when a request seems
   mistaken). In this repo, October added 17.6k lines of tests against 13.5k of code; that ratio
   is a signal, not proof that tests are redundant.
4. **No room to add them.** `global.md` is at its 180-line cap and `claude-code.md` at its 50.
   Anthropic recommends under 200 lines per CLAUDE.md; the rendered `~/.claude/CLAUDE.md` is
   230. Two sections are procedures needed only at one moment: Merge requests (17 lines) and
   Second brain (11).
5. **The path-resolution guard misleads subagents.** Its denial
   (`dot_claude/executable_path-resolution-guard.sh`, rule 1) tells the agent to send `cd` as a
   separate call because "the working directory persists between calls". That holds only in the
   main session (`claude-code.md` says so). It denied 1,397 calls in 14 days, 1,322 of them in
   subagents, up from 1,102.
6. **The memory index has become a status log.** `MEMORY.md` is 12.4 KB for 44 entries;
   three run past 400 characters of merge SHAs and check results. The index is
   loaded in every session; the topic files load on demand.

Measured over October for speed (2026-10-31):

7. **Every change takes the heaviest path, and loops have no convergence check.** Codex is not
   the bottleneck: its review turns take a median 0.5 minutes (p90 about 2), about 11 hours in
   three weeks. The weight is around the reviews.
   - Every change, however small, gets a spec, a plan, three Codex checkpoints, per-task
     reviews and a final review. The `.git/config` plant fix was 54 lines of code, 411 of tests
     and 1,130 of docs; mise-trust was 296, 887 and 698. In mid-September small fixes were code
     and tests with no docs.
   - 30–45% of reviews return `changes`; one thread ran 27 rounds. The push-guard branch took
     15 rounds of 1–2 hours each, and from about round 9 each round mostly found bugs that the
     previous round's fixes had introduced. Nothing told the driver to stop and escalate.
8. **Verification runs in full on every round, one suite at a time.** Agents spent about 185
   hours in test runs in October. `tests/run.sh` runs its suites sequentially, and a fix round
   re-runs the full suite before every re-dispatch. Heavy checks (the push guard's replay of
   about 880,000 commands, about 25 minutes) re-ran on rounds that changed only comments.
   Three branches running suites at once slowed every step 2–3× and made a timing test fail.
9. **Runs stop on approval prompts.** About 86 hours of agent time sat on a prompt in October.
   Almost all of it was cleanup of artifacts the agent itself created: plan workspaces deleted
   with `rm -rf` instead of the prompt-free `sdd-clean`, test containers (`docker rm`), and
   scratch directories. The run stood still until Michael came back.

## Design

### 1. Fresh-session prompts and a context figure

- **Instruction.** `global.md`, Autonomy, gains a bullet:

  > **Fresh sessions.** When asking for spec sign-off and in a final report, end with one line
  > suggesting `/clear` plus a paste-ready prompt (checkout, branch, artifact paths, next
  > step). Persist anything not yet on disk first; never stop only to suggest it.

  Those are the two points where Michael is in the loop anyway; Momentum keeps the run going
  everywhere else. At spec sign-off the prompt reads, for example: "Spec
  `docs/superpowers/specs/<file>` is signed off: commit it, then write and run the plan." A
  session resumed from it starts with the spec and plan on disk, not the brainstorming history.
- **Statusline.** The model segment gains the context size beside the effort:
  `Opus 5.5 · xhigh · 230k`. Its source is `.context_window.total_input_tokens`. Below 200k the
  figure is muted, from 200k it is yellow, and from 400k it is red. It is omitted when the field
  is absent, null or 0. It is part of the model segment, so it needs no new drop logic.
- **Not built.** A SessionStart hook that reloads a handoff after `/clear` (the paste-ready
  prompt does the same with no machinery), and any automatic `/clear` (agents cannot run it).

### 2. Subagent routing

- `claude-code.md` subagent table:
  - `sp-standard`: "integration, debugging, scoped review, fix rounds, plan-run controllers,
    merges".
  - `sp-architect`: "design, plan review, the final whole-branch review".
  - The existing "Go up a tier when a task is harder than its label" line stays.
- `dot_claude/agents/sp-architect.md` description gains: "Not for implementation, fix rounds,
  plan-run controllers or merges; those go to sp-standard."
- `dot_claude/agents/sp-standard.md` description gains fix rounds, plan-run controllers and
  merge-conflict resolution.
- `sp-architect.md` body, plan-review bullet, gains: "Every planned test must name the
  regression it catches; challenge the ones that don't."

No model or effort changes: sp-architect stays opus/xhigh, and the session stays xhigh.

### 3. Engineering judgement

`global.md` gains a section after "How to work", replacing the "Suggest improvements" bullet:

```markdown
## Engineering judgement

- Solve today's problem with well-structured code: clear responsibilities, honest names,
  invariants in one place. A pattern or abstraction must solve a problem you can name now.
- Prefer an in-scope refactor over a workaround when it removes duplicated rules, invalid
  states or a design that makes the change hard; outside scope, propose it with its cost.
  No unrequested features, files, docs or options.
- Each test names the behaviour it pins and the bug it catches; reuse existing coverage; a
  fix gets a test that fails first. Never special-case code to pass a test; report it.
- Disagree when you have reason to (a mistaken request, a weak spec, a stale decision, a
  wrong review finding): say it once, with evidence, then follow Michael's call.
```

It renders into all three targets, so Codex reviews against the same bar.

The Claude reviewers apply it explicitly. `sp-reviewer.md` and `sp-architect.md` each gain one
line: "Judge the change against the Engineering judgement section too: a speculative
abstraction, a workaround where a refactor belongs, or a test that would still pass with the bug
back is a finding, with its concrete cost as the failure scenario." This adds no reviewer and no
round; it sharpens the reviews that already run.

### 4. Procedures move to shared skills

- **`merge-request`** takes the Merge requests mechanics: where templates live, how to fill
  them, and rendering the body for `gh`, `glab` and `az`.
- **`second-brain`** takes the vault conventions: search for a related note first, new
  captures go in `1. Inbox/`, and what is never stored.
- Each lives in `dot_agents/skills/<name>/SKILL.md` (deployed to `~/.agents/skills/`, which
  Codex reads natively), with a `symlink_<name>` in `dot_claude/skills/` and a `.chezmoiignore`
  re-include, the same wiring as `clarity`. Codex keeps them for the day it drives.
- **What stays in `global.md`**, as bullets under "How to work":
  - **Merge requests:** "Load the `merge-request` skill before opening an MR or PR." The
    no-attribution rule stays here in full: it binds commits, issues and review comments too.
  - **Second brain:** the vault's name and path, "offer a note when work produces durable
    knowledge and write it only when asked", the full never-store list ("secrets,
    credentials, customer data, raw conversations or transient working notes"), and a pointer
    to the skill.
- Design records stay in `global.md`: they are policy that both tools review against.

Line budget for `global.md` (180 today): −17 (Merge requests) −11 (Second brain) −1 (Suggest
improvements) +6 (the two bullets, three lines each) +12 (Engineering judgement) +3 (Fresh
sessions) +5 (Sizing, §9) +3 (Convergence, §10) = 180. `claude-code.md` (50 today) gains two
a line in §12, so the plan tightens wording elsewhere in it without dropping a rule. Both caps
are unchanged.

### 5. Path-resolution guard message

Rule 1's denial keeps its cause and its first fix (absolute paths, directory flags). The second
fix becomes:

> If the command genuinely needs a working directory: in the main session, send
> `cd /abs/dir` on its own first, and the following calls inherit it. A subagent's working
> directory does not persist between calls, and it starts in the session's directory, so drop
> the `cd` when that is already the directory, and otherwise use absolute paths or the tool's
> directory flag.

The rules the guard enforces do not change. Guard retirement stays with the evaluation due
around 2026-10-31.

### 6. Memory index

- **One-time consolidation** of `~/.claude/projects/-Users-michael--local-share-chezmoi/memory/MEMORY.md`.
  This is not in the repo; it runs as a plan task in the main session.
  - Each index line becomes `- [Title](file.md) — hook` of at most 200 characters: what the
    memory covers and when it is relevant.
  - Status history moves from the index line into its topic file, unless the topic file already
    holds it. Nothing is deleted from a topic file.
  - No memory is deleted in this pass.
- **memory-health hook.** `dot_claude/hooks/executable_memory-health.sh` also warns when an
  index line exceeds 200 characters, naming the entry, so the index does not grow back. This
  uses the hook's existing warning path.

### 7. Codex reviews quality, not only defects

`dot_config/xreview/reviewer.md` ends with "Skip anything you cannot tie to a concrete failure."
That keeps out speculation, but it also keeps out the problems goals 2, 3 and 5 are about: a
speculative abstraction, a workaround where a refactor belongs, duplicated logic, a test that
pins nothing. The `code-review-and-quality` skill from the `agent-skills` plugin, which Codex
loaded in 312 of 393 sessions over the last 30 days, already reviews simplicity, architecture and
tests. The prompt is what filters those findings out. The closing line becomes:

> A finding is a defect, or a quality problem with a concrete cost: a speculative abstraction, a
> workaround where a refactor belongs, duplicated logic, or a test that would still pass with
> the bug back. Its failure_scenario names the inputs or state and what goes wrong, or the
> concrete cost (for example: a second caller must change this in two places). Skip style
> preferences and anything you cannot tie to a failure or a cost.

This makes reviews stricter, not lighter. Early rounds may return more findings.

### 8. Codex config seeds

`dot_codex/modify_private_config.toml` seeds four keys only when they are absent, so a fresh
machine starts from them. They lag what Michael runs, and the `fast` tier costs 2.5× usage
(OpenAI pricing). The seeds become:

| Key | Now | Becomes |
|---|---|---|
| `model` | `gpt-5.6-sol` | `gpt-6-astra` |
| `model_reasoning_effort` | `high` | `medium` |
| `service_tier` | `fast` | `default` |
| `plan_mode_reasoning_effort` | `xhigh` | `high` |

Existing values are untouched, as before.

### 9. Size the process to the change, not the quality bar

`global.md`, Autonomy, gains:

> **Sizing.** Size the process to the change, never the quality bar. A small change (a fix,
> config change or contained addition: under ~150 lines of non-test code, no open design
> choice, no safety boundary such as permissions, sandbox, guards, auth, secrets, deletion,
> push or merge tooling, migrations) skips the spec and plan: test first, implement, then a
> cold diff review and Codex's pre-merge review together. Unsure means not small; say which.

| | Small change | Everything else |
|---|---|---|
| Spec, plan, their Codex checkpoints, Michael's spec sign-off | — | yes |
| Per-task implementer and reviewer | — (one diff, no tasks) | yes |
| Test first for a fix; Engineering judgement rules | yes | yes |
| Cold Claude review of the diff | sp-reviewer, in parallel with Codex | final sp-architect review |
| Codex pre-merge review and the merge gate | yes | yes |
| Full suite on the final commit; Draft MR; Michael merges | yes | yes |

- The Design records section opens with "Every change except a small one (see Sizing) has a
  spec and a plan, versioned with the code" in place of its first sentence.
- Global instructions outrank skills, so the superpowers brainstorming and planning skills do
  not force a spec onto a small change.
- Safety-boundary work is never small, whatever its size. A branch that grows past the limits
  mid-way moves to the full path before its pre-merge review.

### 10. Escalate a loop that stops converging

`global.md`, Autonomy, gains after "Fix now":

> **Convergence.** A loop converges when each round leaves less to fix. Two rounds in a row
> that mostly find problems in the last round's fixes, or a goal that can never be finished,
> mean it does not: stop and bring Michael the round count, what recurs and a structural option.

- It covers every loop: Codex checkpoints, per-task and final reviews, and adversarial hunts.
- The cross-review skill's escalation list, which is exhaustive, gains the same trigger. Its
  "no round limit" stays: a loop that converges runs as long as it needs.
- This pairs with §7. A stricter Codex lens raises findings per review; this keeps a loop that
  feeds on its own fixes from running for days.

### 11. Verify as much, wait less

- **Focused tests per round, full suite on the final commit.** The "How to work" testing bullet
  becomes: "Iterate on focused tests (the suites for what changed). Before claiming something
  works, run the full suite and linters on the final commit; report totals as passed/total."
  The cross-review skill's fix-round rule 3 gains: "Run the focused tests before
  re-dispatching; the full suite runs once the review approves, and a red suite starts a new
  round." Plan runs keep the full suite once per batch (`claude-code.md`).
- **`tests/run.sh` runs suites in parallel.**
  - A full run executes suites concurrently: half the online CPUs, at least 2. `RUN_JOBS`
    overrides it, and `RUN_JOBS=1` restores sequential order.
  - Each suite's output is buffered and printed in name order. Totals, exit status and the
    `INCONSISTENT` cross-check are unchanged.
  - A suite that cannot share the machine carries `# test-serial` and runs alone after the
    parallel ones: timing assertions, fixed ports, shared state. The timing baseline (plan task
    1) and one parallel run decide which suites carry it.
  - One runner per machine. Every invocation, full or filtered, takes a `lockf` lock on
    `/tmp/claude-$(id -u)/tests-run.lock`, in `$TMPDIR` of every sandboxed session; the runner
    creates the directory when it is missing (a fresh boot, an unsandboxed shell). So a
    `# test-serial` suite never shares the machine with another runner, and a heavy suite run
    by name never overlaps another branch's full run. A runner that has to wait says so. With
    parallel full runs that wait is a few minutes. This replaces "run fewer heavy branches at
    once" with a mechanism.
  - The manual wrapper plans used until now (`lockf -k /tmp/claude-$(id -u)/chezmoi-fullsuite.lock
    ./tests/run.sh`) is retired. `AGENTS.md` says the runner locks itself and is never wrapped.
    The runner's lock is a different file from the wrapper's, so a wrapper still written in a
    plan that is running cannot deadlock it: it only adds a second, harmless lock. Completed
    plans keep their text.
  - A nested runner does not lock again. The runner exports `RUN_SH_LOCKED=1` to its suites,
    and an invocation that sees it runs without locking. Otherwise `run.test.sh`, which drives
    copies of the runner, would wait for the lock its own parent holds. `RUN_SH_LOCK` overrides
    the lock path, so fixtures use their own lock.
- **Heavy suites run when their subject changes.** A suite whose run takes over 2 minutes
  carries `# test-requires: heavy`, so the existing gate skips it by default. The driver runs it
  by exact name when its subject changed on the branch, and always before the pre-merge review
  of such a branch. `AGENTS.md`'s Testing table gains the `heavy` row. The push guard's replay
  check follows the same rule when its branch lands.

### 12. Cleanup never blocks a run

`claude-code.md`'s "Plan workspaces" bullet becomes:

> **Cleanup never blocks a run.** Delete a finished `.superpowers/sdd/<plan>` workspace with
> `sdd-clean <workspace>`, never `rm -rf`. Other deletions and container removals wait until
> the run's work is done and go together, or into the final report as commands.

No permission rule changes: destructive actions still ask, but at the end of a run, not in its
middle.

## Declined (Michael, 2026-10-30)

These are settled: lowering any effort level, turning Codex memories off, dropping the per-task
reviewer from the full path, and automatic `/clear`.

## Testing

Each new test pins one behaviour:
- **`agent-instructions`:** the caps (unchanged); the Engineering judgement section and the
  Sizing and Convergence bullets; the no-attribution rule and every vault boundary (write only
  when asked, and each never-store category) staying in `global.md`.
- **`run`:** on fixture suites, a parallel run prints the same per-suite lines, in name order,
  and the same totals as `RUN_JOBS=1`; a `# test-serial` suite's run overlaps no other suite's
  (fixtures record start and end); with `RUN_SH_LOCKED` unset, a full run and a filtered run
  each wait while a fixture holds the lock at `RUN_SH_LOCK`, and say so; a runner started with
  `RUN_SH_LOCKED=1` while that lock is held completes, within a timeout. The real suite also
  runs inside a real full run, so a deadlock fails the run rather than hanging it.
- **`path-resolution-guard`:** the denial says a subagent's directory does not persist (this
  replaces the "separate Bash call" expectation).
- **`statusline`:** the context figure at 199,999 (muted), 200,000 (yellow), 400,000 (red), and
  null (omitted).
- **`memory-health`:** an index line of 201 characters warns; one of 200 does not.
- **Skills:** `command chezmoi --source <checkout> managed` lists both new `SKILL.md` files and
  both symlinks.
- **`codex-config`:** the seeded-when-absent cases expect the four new values (they replace
  the `gpt-5.6-sol` and `fast` expectations).
- **xreview suites:** `xreview-packet` K7 pins the shipped `reviewer.md` to the golden
  fixture's copy. `tests/fixtures/xreview-packet/regenerate.sh` copies the new `reviewer.md`
  and rebuilds the golden packets with its pinned reference dispatcher (never a newer one), so
  K1 and K7 hold. `xreview-replay` builds its packets from the shipped file and needs no
  change. No new test: the prompt is prose.

Full suite: `./tests/run.sh`.

## Rollout

Michael runs `chezmoi apply`. Instruction changes take effect in new sessions or after
`/clear`. Expected net prompt change: 0.

**Did it work.** Fourteen days after apply, compare with October, from the xreview ledgers and
the transcripts, as measured on 2026-10-31:
- rounds per checkpoint, and the longest loop;
- agent hours spent in test runs, and the full-suite wall time;
- agent hours blocked on a prompt;
- time from first commit to pushed branch, for small changes and for the rest.

The quality side must not move: Codex pre-merge findings on the first round, and post-merge
fixes.

## Implementation notes (2026-10-31)

**Measured.** Sequential baseline, one suite at a time: 1,783 s for 47 suites. Verdicts are
byte-identical between the parallel runner and `RUN_JOBS=1`.

| Run | Wall time |
|---|---|
| Parallel, all 47 suites | 801 s |
| `RUN_JOBS=1` | 1,708 s |
| Default full run, after the heavy suites are gated | 176–181 s (44 suites, 4,503 assertions) |

The heavy suites, run by name: xreview 672 s, git-forge-guard 242 s, wt-functions 123 s.

**Rulings:**
1. **`sp-architect` description.** "Not for routine implementation, fix rounds, plan-run
   controllers or merges; those go to sp-standard. Implementation only as an escalation after a
   lower tier failed." The spec's verbatim text contradicted the existing "go up a tier" rule and
   the live-feedback skill's escalation to sp-architect.
2. **No `# test-serial` markers.** Six suites assert on timing; they passed under three times
   CPU oversubscription, and five parallel runs were byte-identical. If a parallel run turns
   red, mark these first: herdr-codex-pane-map, xreview-rpc, review, wt-teardown.
3. **`agent-skills` lists `managed` from a scratch source** (the ignore file, `dot_agents`, the
   symlinks), not the checkout source. That keeps the suite off chezmoi's external cache.
4. **`live-feedback-skill` signs no fixture commit.** It now runs `-c commit.gpgsign=false`:
   under parallel load its fixture commit failed whenever the 1Password agent was unavailable.
5. **The runner gives every suite stdin from `/dev/null`.** An interactive suite run through it
   now exits instead of blocking on a prompt nobody can see.
6. **`global.md` stays at 180 lines.** "Claude Code dispatches to Codex itself" became "…
   dispatches to Codex".
7. **The other session's lock was bypassed for focused runs.** It held its full-suite lock for
   45 minutes or more, so implementers ran their focused suites directly. Every full run took
   the lock.

**Open:** `dot_claude/executable_git-forge-guard.sh`, `dot_claude/modify_private_settings.json`
and `tests/git-forge-guard.test.sh` still point at "the Merge requests section of GLOBAL.md".
The rule is now a "How to work" bullet plus the `merge-request` skill. These files belong to
`fix/push-guard-escaped-spellings`, so the reword waits until that branch merges and this one
is rebased onto it.
