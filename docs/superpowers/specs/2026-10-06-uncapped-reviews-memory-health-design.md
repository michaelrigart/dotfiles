# Uncapped review rounds and memory health

**Status:** In progress (branch `feat/review-convergence-memory-health`; the dotfiles have no MR)
**Date:** 2026-10-06
**Scope:** `dot_local/bin/executable_xreview` (the round cap), the cross-review skill,
`.chezmoitemplates/agents/global.md` (one phrase), a new SessionStart hook
(`dot_claude/hooks/executable_memory-health.sh`), the settings template, `.chezmoiignore`,
and their test suites.

Two independent changes, both prompted by a review of a colleague's agent setup and kept only
where they improve results or the daily workflow.

## 1. Problem

**The round cap stops reviews that are still finding real problems.** `xreview dispatch`
refuses an eleventh round per branch (`XREVIEW_MAX_ROUNDS`, default 10), and the cross-review
skill then escalates to Michael. A count says nothing about whether a review is converging.
The skill already escalates the case a cap was meant to catch, two models circling: "the
reviewer re-raises a finding you already addressed". Michael wants every finding fixed,
however many rounds that takes.

**Rounds spent on the previous round's fixes.** With no cap, every avoidable round is pure
wall clock. Fixes are where the next findings come from. The colleague measured 14 of 16
second-round findings landing on text the first round's fixes had created, and graded
earlier fixes 15 complete, 8 partial and 2 regressed. Typical causes are a fix applied to the
one cited instance while the same defect sits elsewhere, a fix that changes the line without
removing the failure, and a summary or cross-reference left contradicting the fixed text.

**Memory index past Claude Code's limits.** Claude Code 2.1.289 caps `MEMORY.md` at 200
lines and 25,000 characters (constants beside the `MEMORY.md` name in the binary; its own
consolidation prompt says to stay under both). Nothing warns before a project's index nears
that, and nothing notices an index entry whose file is gone or a memory file the index never
mentions. The curato project's index is at 139 lines and 16.9 KB.

## 2. Goals and non-goals

Goals:

- No default limit on review rounds. A review stops when it converges or on a real
  disagreement.
- Every finding is still fixed in the round that raised it (unchanged).
- Each fix round leaves less for the next one, without narrowing what any round reviews.
- An agent learns at session start when its project's memory index needs attention, and is
  silent otherwise.

Non-goals:

- No change to what a dispatch sends, to the findings schema or to the reviewer
  instructions. Rounds are never scoped to the fixes alone.
- No change to the pre-merge guard.
- The memory hook never edits memory and never blocks a session.

## 3. Design — review rounds

### 3.1 No default cap

`xreview dispatch` caps rounds only when `XREVIEW_MAX_ROUNDS` is set and not empty. Unset,
there is no limit. Set to anything other than a whole number, dispatch refuses before
touching the pane, naming the bad value. Today a non-numeric value makes the `-gt` test fail
quietly and the cap vanish without a word. With the override set, behaviour is unchanged:
round N+1 is refused before any turn starts, and the counter still advances.

The round counter stays. `xreview round` still shows it and `round --reset` still clears it,
so a long review is visible even though it is no longer stopped.

### 3.2 What stops a review

Convergence (the reviewer returns no actionable findings) or a trigger on the skill's existing
escalation list. The list loses only the cap line, which moves to a note: the cap refuses a
round only when Michael has set `XREVIEW_MAX_ROUNDS`, and that refusal is then escalated as
before. The re-raise trigger is what catches two models circling.

The skill's sentences that call the cap "the only limit" ("Rounds within a checkpoint…",
"Staleness is mechanical…") are reworded: convergence and the escalation list are the limits.
`global.md` drops "bounded by the round cap" from its Dispatches bullet. That changes no line
count, and the file stays within its 180 lines.

### 3.3 Fix rounds that leave less behind

Added to the skill's "Acting on findings", after the existing rule to verify each finding:

1. **Fix the class, not the instance.** For each verified finding, look for the same defect
   elsewhere in the artifact (at pre-merge, the whole branch diff) and fix every occurrence in
   the same round.
2. **One cause, one fix.** Findings that share a cause get one fix at the cause, not one patch
   per symptom.
3. **Check each fix against its failure scenario.** The scenario must now be impossible, not
   just the cited line changed. A fix that comes with a test runs it.
4. **Re-read what depends on the changed text.** Summaries, derived sections,
   cross-references, and tests or docs that restate it are where a fix leaves a
   contradiction. Fix those in the same round.
5. **One dispatch per round.** Re-dispatch once every finding of the round has been dealt
   with, never per finding.

These are discipline; nothing enforces them. They add no review step and send nothing new to
the reviewer.

## 4. Design — memory health

### 4.1 The hook

`~/.claude/hooks/memory-health.sh`, a SessionStart hook (no matcher, timeout 10). It reads
the hook payload from stdin and takes `transcript_path` and `cwd`. Claude Code keys
transcripts on the session cwd but auto-memory on the main repository root, so the memory
directory is derived from the root, not from the transcript's own directory: when
`git -C <cwd> rev-parse --path-format=absolute --git-common-dir` succeeds, the root is that
path's parent (a linked worktree maps to its main checkout, a subdirectory to its
checkout), the project key is the root with every character outside `[A-Za-z0-9]` replaced
by `-`, and the directory is `<projects dir>/<key>/memory`, where the projects dir is the
transcript directory's parent. With no usable `cwd` or no repository it falls back to
`<transcript directory>/memory`. No memory directory, no `transcript_path`, unreadable
input, or any internal error: exit 0 with no output. Bash 3.2 and standard tools only;
read-only.

### 4.2 Checks

1. **Size.** `MEMORY.md` at 180 lines or more, or 22,500 characters or more (90% of each
   limit), counted on the trimmed content as Claude Code counts it.
2. **Dangling entries.** A link `](<name>.md)` in `MEMORY.md` whose file does not exist in
   the directory.
3. **Unindexed files.** A `*.md` file in the directory, other than `MEMORY.md`, that no link
   in `MEMORY.md` names.

`[[name]]` wiki-links are not checked: a link to a memory not yet written is allowed.

### 4.3 Output

Healthy: nothing. Otherwise one SessionStart `additionalContext` block for the agent, naming
each problem and its fix:

- size: consolidate the index (merge or shorten entries, one line each) to under 180 lines
  and 22,500 characters;
- dangling: remove the entry, or restore the file if it was deleted by mistake;
- unindexed: add an index line, or delete the file if it is obsolete.

It goes to the agent, not to Michael: fixing the index is the agent's own memory upkeep.

### 4.4 Wiring

- `.chezmoiignore`: `!.claude/hooks/memory-health.sh`, since `~/.claude/hooks` is an
  allowlist.
- The settings template: a third SessionStart entry,
  `bash $HOME/.claude/hooks/memory-health.sh`, timeout 10.

## 5. Testing

- `tests/xreview.test.sh`:
  - with `XREVIEW_MAX_ROUNDS` unset, rounds past ten are dispatched (each yields a nonce and
    starts a turn);
  - with it set, round N+1 is still refused before any turn starts, and the counter still
    advances;
  - a non-numeric value is refused before any pane step, naming the value;
  - cases that relied on the old default of 10 (the branch-binding case R2) set the override
    explicitly.
- `tests/xreview-skill.test.sh`: the "documented cap matches the code" check becomes "the
  skill states there is no default cap, and the code has no numeric default". It also pins
  the five fix-round rules and the reworded limits sentences.
- `tests/agent-instructions.test.sh`: unchanged, still passing (the `global.md` edit keeps
  its line count).
- `tests/memory-health.test.sh` (new) against fixture directories: healthy is silent; 180
  lines warns; 22,500 characters warns; a dangling link and an unindexed file are each named;
  a `[[link]]` to a missing memory is not flagged; no memory directory, no `transcript_path`
  and malformed input are each silent with exit 0; a linked-worktree session and a
  subdirectory session read the main checkout's memory, and a non-git or missing `cwd`
  falls back to the transcript's own directory.
- `tests/claude-settings.test.sh`: three SessionStart entries, the new one by its command and
  timeout.

## 6. Rollout

`chezmoi apply`. Nothing is in flight that the change could break: the cap is read at each
dispatch.

## 7. Risks and limits

- **Cost of a long review.** A review that keeps finding genuinely new problems keeps going.
  That is the intent. Circling is still caught by the re-raise trigger, and
  `XREVIEW_MAX_ROUNDS` remains for a session where Michael wants a bound.
- **The fix-round rules are prose.** Their effect shows up as fewer rounds per checkpoint,
  which the Codex session logs show, not as a gate.
- **The memory limits are the binary's, today.** If Claude Code changes them, the thresholds
  in the hook need updating; the hook names the version they were read from.
