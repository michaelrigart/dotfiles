# Uncapped review rounds and memory health — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented — completed 2026-10-06; do not run again
**Goal:** Remove xreview's default round cap, make each fix round leave less for the next, and add a silent-unless-broken SessionStart check of the project memory index.

**Architecture:** Three independent changes. (1) `xreview dispatch` caps rounds only when `XREVIEW_MAX_ROUNDS` is set, and validates it; the cross-review skill and `global.md` stop describing a cap. (2) The cross-review skill gains five fix-round rules. (3) A new read-only bash hook, `memory-health.sh`, wired as a SessionStart hook, reports a `MEMORY.md` near Claude Code's limits, dangling index links and unindexed memory files to the agent.

**Tech Stack:** bash (hooks bash 3.2 compatible), jq, chezmoi source layout, the repo's bash test suites (`tests/*.test.sh`, `./tests/run.sh`).

**Spec:** `docs/superpowers/specs/2026-10-06-uncapped-reviews-memory-health-design.md`

## Global Constraints

- Work on branch `feat/review-convergence-memory-health`. This checkout is shared: run `git branch --show-current` immediately before every `git add`/`git commit` and stop if it is not that branch.
- Never run `chezmoi apply`, never push, never touch `~/.claude` directly; edit only the chezmoi source tree.
- Hook scripts are bash 3.2 compatible (macOS `/bin/bash`): no associative arrays, no `mapfile`, no `${var,,}`.
- Hooks fail open and silent: on any internal error, exit 0 with no stdout.
- Test suites: shebang `#!/usr/bin/env bash`, git mode 755 (`git add --chmod=+x`), exit 2 when the file under test is missing, `  PASS: …` / `  FAIL: …` lines, end with `passed: N  failed: M` and a non-zero exit when anything failed.
- Execute suites directly (`./tests/x.test.sh`), never `bash tests/x.test.sh`.
- The settings template `dot_claude/modify_private_settings.json` is one single-quoted jq program: no apostrophes anywhere in its comments.
- `~/.claude` is an allowlist in `.chezmoiignore`: a new managed file needs its own `!` line.
- `.chezmoitemplates/agents/global.md` stays within 180 lines.
- Commit messages: imperative mood, no prefix convention, no agent attribution of any kind.
- Report test totals as passed/total.

## Review Focus

- `XREVIEW_MAX_ROUNDS` set but empty must mean "no cap", not a refusal; ` 5`, `5x`, `-1`, `abc` must be refused before the pane is touched, naming the value. (Task 1)
- An index with trailing blank lines must be counted trimmed, as Claude Code counts it — 179 content lines plus blank lines must not warn. (Task 3)
- An index must be counted in UTF-16 units, as Claude Code counts it — 8,000 `—` (24,000 bytes) must not warn, and 11,250 emoji (22,500 units) must. (Task 3)
- Memory file names with spaces or regex characters (`my note.md`, `a+b.md`) must match their index links exactly. (Task 3)
- A memory directory with files but no `MEMORY.md` must name every file as unindexed, not stay silent. (Task 3)

---

### Task 1: No default round cap

**Files:**
- Modify: `dot_local/bin/executable_xreview` (comment at lines 667-669; preconditions in `cmd_dispatch` after `pane_command >/dev/null`; the cap check at lines 869-879)
- Modify: `dot_claude/skills/cross-review/SKILL.md` ("Iterating" section)
- Modify: `.chezmoitemplates/agents/global.md` (Dispatches bullet, lines 163-165)
- Test: `tests/xreview.test.sh` (block A at lines 303-315, a new block before `echo "B. inline diffs"`, case R2 at line 1330)
- Test: `tests/xreview-skill.test.sh` (the round-cap check at lines 99-123)

**Interfaces:**
- Consumes: nothing.
- Produces: `XREVIEW_MAX_ROUNDS` semantics — unset or empty: no cap; a whole number N: round N+1 refused with the existing message `round <n> exceeds the cap of <N> for this branch.`; anything else: `die "XREVIEW_MAX_ROUNDS must be a whole number, not '<value>'; no review was started"` before any pane step. Task 2 edits the same SKILL.md and test file, after this task.

- [ ] **Step 1: Rewrite block A of `tests/xreview.test.sh` as failing tests**

Replace these lines (303-315):

```bash
echo "A. the round cap binds before a turn is spent"
fresh
capped() { bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1 | grep -c 'exceeds the cap'; }
is "round counter starts at zero" "$(bash "$XREVIEW" round)" 0
for _ in $(seq 9); do capped >/dev/null; done
is "nine rounds are permitted"        "$(bash "$XREVIEW" round)" 9
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "the tenth round is still allowed"    "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 0
is "and the tenth round produces a nonce" "$(printf '%s' "$out" | grep -c '^xr-')" 1
starts="$(called 'xreview-rpc turn-start')"
is "the eleventh round is refused"    "$(capped)" 1
is "and starts no turn"               "$(called 'xreview-rpc turn-start')" "$starts"
is "a refused round still increments, so retrying stays refused" "$(bash "$XREVIEW" round)" 11
```

with:

```bash
echo "A. rounds are not capped by default; XREVIEW_MAX_ROUNDS is an opt-in bound"
fresh
capped() { bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1 | grep -c 'exceeds the cap'; }
is "round counter starts at zero" "$(bash "$XREVIEW" round)" 0
for _ in $(seq 11); do capped >/dev/null; done
is "eleven rounds are dispatched with no cap set" "$(bash "$XREVIEW" round)" 11
starts="$(called 'xreview-rpc turn-start')"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "the twelfth round is not refused"       "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 0
is "and the twelfth round produces a nonce" "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "and starts a turn"                      "$(called 'xreview-rpc turn-start')" "$((starts + 1))"
out="$(XREVIEW_MAX_ROUNDS= bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "an empty XREVIEW_MAX_ROUNDS is no cap either" "$(printf '%s' "$out" | grep -c '^xr-')" 1
starts="$(called 'xreview-rpc turn-start')"
out="$(XREVIEW_MAX_ROUNDS=13 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "XREVIEW_MAX_ROUNDS=13 refuses the fourteenth round" "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1
is "and starts no turn"               "$(called 'xreview-rpc turn-start')" "$starts"
is "a refused round still increments, so retrying stays refused" "$(bash "$XREVIEW" round)" 14
```

Leave the lines after it (`bash "$XREVIEW" round --reset …` through `export NEW_UUID="$U1"`) unchanged.

- [ ] **Step 2: Add the validation block before `echo "B. inline diffs"`**

Insert immediately above the line `echo "B. inline diffs"`:

```bash
echo "A2. a malformed XREVIEW_MAX_ROUNDS is refused before the pane is touched"
for v in abc 5x ' 5' -1; do
  fresh
  out="$(XREVIEW_MAX_ROUNDS="$v" bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
  is "A2 XREVIEW_MAX_ROUNDS='$v' is refused, naming the value" \
     "$rc/$(printf '%s' "$out" | grep -c -F "not '$v'")" "1/1"
  is "A2 and with '$v' nothing reaches the pane or the reviewer" "$(untouched)" yes
done
fresh
out="$(XREVIEW_MAX_ROUNDS=0 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "A2 a whole number (0) is accepted as a bound" "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1

```

- [ ] **Step 3: Make case R2 set its cap explicitly**

R2 seeds `rc-a=10` and expects the eleventh round refused, which relied on the old default. In `tests/xreview.test.sh` line 1330, replace:

```bash
out="$(RPC_SWITCH_BRANCH_EARLY=rc-b bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
```

with:

```bash
out="$(XREVIEW_MAX_ROUNDS=10 RPC_SWITCH_BRANCH_EARLY=rc-b bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
```

- [ ] **Step 4: Rewrite the round-cap check in `tests/xreview-skill.test.sh` as failing tests**

Replace the whole block from `# --- the round cap ---…` (line 99) through the closing `fi` of the `doc_cap`/`code_cap` comparison (line 123) with:

```bash
# --- the round cap -----------------------------------------------------------
# There is no default cap (spec 2026-10-06 section 3.1): the skill must not state one and the
# code must not carry one, or an escalation would fire on a count instead of on the review.
# XREVIEW_MAX_ROUNDS stays as Michael's opt-in bound, so the skill has to name it: a refusal
# under it would otherwise read as an unexplained failure.
doc_caps="$(grep -oE 'capped at [0-9]+' "$SKILL" | sort -u)"
code_default="$(printf '%s\n' "$xreview_code" | grep -oE 'XREVIEW_MAX_ROUNDS:-[0-9]+' | sort -u)"
if [ -n "$doc_caps" ]; then
  _fail "the skill states no default round cap" "SKILL.md says: $(printf '%s' "$doc_caps" | tr '\n' ' ')"
else _pass "the skill states no default round cap"; fi
if [ -n "$code_default" ]; then
  _fail "the CLI carries no default round cap" "found: $code_default"
else _pass "the CLI carries no default round cap"; fi
if grep -q 'XREVIEW_MAX_ROUNDS' "$SKILL" && printf '%s\n' "$xreview_code" | grep -q 'XREVIEW_MAX_ROUNDS'; then
  _pass "the opt-in XREVIEW_MAX_ROUNDS is named in the skill and read by the CLI"
else _fail "the opt-in XREVIEW_MAX_ROUNDS is named in the skill and read by the CLI" "missing on one side"; fi
if grep -qF 'there is no limit on rounds' "$SKILL"; then
  _pass "the skill says rounds are not limited"
else _fail "the skill says rounds are not limited" "missing"; fi
if grep -q 'round cap' "$SKILL" "$ROOT/.chezmoitemplates/agents/global.md"; then
  _fail "neither the skill nor global.md calls on a round cap" "$(grep -n 'round cap' "$SKILL" "$ROOT/.chezmoitemplates/agents/global.md")"
else _pass "neither the skill nor global.md calls on a round cap"; fi
```

`xreview_code` is captured at line 79 of this file, above the block; use it, never a live `strip_comments | grep -q` pipe (see the comment at lines 73-78).

- [ ] **Step 5: Run both suites and confirm the new checks fail**

Run: `./tests/xreview.test.sh 2>&1 | grep -E 'FAIL|passed:'` and `./tests/xreview-skill.test.sh 2>&1 | grep -E 'FAIL|passed:'`
Expected: FAILs on "eleven rounds are dispatched with no cap set", "the twelfth round is not refused", the A2 refusals, "the skill states no default round cap", "the CLI carries no default round cap", "the skill says rounds are not limited", and "neither the skill nor global.md calls on a round cap".

- [ ] **Step 6: Change the cap in `dot_local/bin/executable_xreview`**

Replace the comment at lines 667-669:

```bash
# Review rounds iterate until the models converge or genuinely disagree, so the stop
# condition cannot be "one round" — but it cannot be unbounded either. The cap is mechanical
# because a limit that depends on noticing you have hit it is not a limit.
```

with:

```bash
# Review rounds iterate until the models converge or genuinely disagree. The cross-review
# skill escalates two models circling, so there is no default cap (spec 2026-10-06): the
# counter is kept so a long review stays visible, and XREVIEW_MAX_ROUNDS, when set, turns it
# into a mechanical bound.
```

In `cmd_dispatch`, directly after the line `  pane_command >/dev/null`, add:

```bash
  # XREVIEW_MAX_ROUNDS is an opt-in bound: unset or empty means no limit. Anything else must
  # be a whole number, checked before the pane is touched - a value [ -gt ] cannot compare
  # would otherwise make the cap vanish without a word.
  local max="${XREVIEW_MAX_ROUNDS:-}"
  case "$max" in
    *[!0-9]*) die "XREVIEW_MAX_ROUNDS must be a whole number, not '$max'; no review was started" ;;
  esac
```

Then replace the cap check (lines 869-879):

```bash
  # The cap binds before the pane is touched at all: a round over the cap is refused
  # without so much as a ctrl+c, and the counter still advances so a retry stays refused.
  local max="${XREVIEW_MAX_ROUNDS:-10}" round
  round=$(( $(current_round "$branch") + 1 ))
  if [ "$round" -gt "$max" ]; then
```

with:

```bash
  # With XREVIEW_MAX_ROUNDS set, the cap binds before the pane is touched at all: a round over
  # it is refused without so much as a ctrl+c, and the counter still advances so a retry stays
  # refused. Unset, a review stops when it converges or on a real disagreement, never on a count.
  local round
  round=$(( $(current_round "$branch") + 1 ))
  if [ -n "$max" ] && [ "$round" -gt "$max" ]; then
```

The body of the `if` (the `bump_round` and the `die "round $round exceeds the cap of $max …"`) stays as it is. An empty value matches no arm of the `case`, so it passes as "no cap".

- [ ] **Step 7: Reword the skill's limit sentences**

In `dot_claude/skills/cross-review/SKILL.md`, replace:

```markdown
**Rounds within a checkpoint stay on the same thread.** Round 4 of a spec sign-off is
normal operation, not degradation — iterating on one thread is how a review converges,
and the round cap is the only limit on it. Never stop, rotate or escalate because a
thread has answered a few rounds.

**Staleness is mechanical, not a judgement.** Each checkpoint starts on a fresh thread, so a
thread only ever holds the rounds of one checkpoint, and the round cap bounds those.
```

with:

```markdown
**Rounds within a checkpoint stay on the same thread.** Round 4 of a spec sign-off is
normal operation, not degradation — iterating on one thread is how a review converges,
and there is no limit on rounds: a review ends when it converges or on a trigger in the
escalation list below. Never stop, rotate or escalate because a thread has answered a few
rounds.

**Staleness is mechanical, not a judgement.** Each checkpoint starts on a fresh thread, so a
thread only ever holds the rounds of one checkpoint.
```

and replace the escalation bullet:

```markdown
- `xreview` refuses the round (capped at 10; `XREVIEW_MAX_ROUNDS` overrides)
```

with:

```markdown
- `xreview` refuses the round because Michael set `XREVIEW_MAX_ROUNDS` and the review
  reached it. Unset, rounds are not limited.
```

- [ ] **Step 8: Reword `global.md`**

In `.chezmoitemplates/agents/global.md`, replace:

```markdown
  checkpoint it iterates until the review converges or a disagreement is real, bounded by
  the round cap and never prolonged for consensus; Michael hears about disagreements, not
```

with:

```markdown
  checkpoint it iterates until the review converges or a disagreement is real, with no
  round limit and never prolonged for consensus; Michael hears about disagreements, not
```

The line count does not change.

- [ ] **Step 9: Run the suites and confirm they pass**

Run: `./tests/xreview.test.sh 2>&1 | tail -1`, `./tests/xreview-skill.test.sh 2>&1 | tail -1`, `./tests/agent-instructions.test.sh 2>&1 | tail -1`
Expected: each ends `passed: N  failed: 0` (agent-instructions: unchanged count, 19 at plan time).

- [ ] **Step 10: Commit**

```bash
git branch --show-current   # must print feat/review-convergence-memory-health
git add dot_local/bin/executable_xreview dot_claude/skills/cross-review/SKILL.md \
        .chezmoitemplates/agents/global.md tests/xreview.test.sh tests/xreview-skill.test.sh
git commit -m "Drop the default review round cap and validate XREVIEW_MAX_ROUNDS"
```

---

### Task 2: Fix rounds that leave less behind

**Files:**
- Modify: `dot_claude/skills/cross-review/SKILL.md` ("Acting on findings" section)
- Test: `tests/xreview-skill.test.sh` (new block above the final `printf '\npassed: …'`)

**Interfaces:**
- Consumes: the SKILL.md and test file as Task 1 left them.
- Produces: nothing other tasks use.

- [ ] **Step 1: Add the failing pins**

In `tests/xreview-skill.test.sh`, insert immediately above the final `printf '\npassed: %d  failed: %d\n' "$pass" "$fail"`:

```bash
# --- fix rounds (spec 2026-10-06 section 3.3) --------------------------------
# With no round cap, every avoidable round is wall clock. These rules make a fix round leave
# less for the next one; they must sit under "Acting on findings", where the model reads
# them while fixing.
acting="$(sed -n '/^## Acting on findings/,/^## /p' "$SKILL")"
for rule in 'Fix the class, not the instance.' 'One cause, one fix.' \
            'Check each fix against its failure scenario.' \
            'Re-read what depends on the changed text.' 'One dispatch per round.'; do
  if printf '%s\n' "$acting" | grep -qF "**$rule**"; then
    _pass "the fix-round rule '$rule' is under Acting on findings"
  else _fail "the fix-round rule '$rule' is under Acting on findings" "missing"; fi
done
```

- [ ] **Step 2: Run and confirm the five pins fail**

Run: `./tests/xreview-skill.test.sh 2>&1 | grep -E 'FAIL|passed:'`
Expected: five FAILs, one per rule.

- [ ] **Step 3: Add the rules to the skill**

In `dot_claude/skills/cross-review/SKILL.md`, directly after the bullet `- **You disagree, or cannot verify it** — Michael decides.` (the last bullet of "Acting on findings") and before `## Iterating`, insert:

```markdown

**Make each fix round leave less for the next one.** Every round re-reviews the whole
artifact, and fixes are where the next round's findings come from. Before re-dispatching:

1. **Fix the class, not the instance.** For each verified finding, look for the same
   defect elsewhere in the artifact (at pre-merge, the whole branch diff) and fix every
   occurrence in this round.
2. **One cause, one fix.** Findings that share a cause get one fix at the cause, not one
   patch per symptom.
3. **Check each fix against its failure scenario.** The scenario must now be impossible,
   not just the cited line changed. A fix that comes with a test runs it.
4. **Re-read what depends on the changed text.** Summaries, derived sections,
   cross-references, and tests or docs that restate it are where a fix leaves a
   contradiction. Fix those in the same round.
5. **One dispatch per round.** Re-dispatch once every finding of the round has been fixed,
   ruled on or escalated, never per finding.
```

- [ ] **Step 4: Run and confirm it passes**

Run: `./tests/xreview-skill.test.sh 2>&1 | tail -1`
Expected: `passed: N  failed: 0`.

- [ ] **Step 5: Commit**

```bash
git branch --show-current   # must print feat/review-convergence-memory-health
git add dot_claude/skills/cross-review/SKILL.md tests/xreview-skill.test.sh
git commit -m "Add fix-round rules so each review round leaves less for the next"
```

---

### Task 3: Memory health SessionStart hook

**Files:**
- Create: `dot_claude/hooks/executable_memory-health.sh`
- Create: `tests/memory-health.test.sh` (mode 755)
- Modify: `.chezmoiignore` (after `!.claude/hooks/prompt-audit.sh`, line 85)
- Modify: `dot_claude/modify_private_settings.json` (the `SessionStart` array)
- Test: `tests/claude-settings.test.sh` (the SessionStart checks near line 470)

**Interfaces:**
- Consumes: the SessionStart hook payload on stdin — JSON with `transcript_path` (absolute path of the session transcript, `~/.claude/projects/<project>/<session>.jsonl`).
- Produces: on stdout, nothing when healthy; otherwise one line of JSON
  `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Memory health check for <dir>:\n- …"}}`. Always exit 0.

- [ ] **Step 1: Write the failing test suite**

Create `tests/memory-health.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for dot_claude/hooks/executable_memory-health.sh, the SessionStart hook that reports
# a project memory index nearing Claude Code's limits, index links to missing files and
# memory files the index never lists (spec 2026-10-06 section 4). Healthy is silent.
#
#   ./tests/memory-health.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SRC/dot_claude/hooks/executable_memory-health.sh"
[ -f "$HOOK" ] || { echo "missing script under test: $HOOK" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
has() { case "$2" in *"$3"*) _pass "$1" ;; *) _fail "$1" "$2" ;; esac; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/memhealth.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# mem <project> -> creates a fresh project with an empty memory dir; prints the memory dir
mem() { rm -rf "${ROOT:?}/$1"; mkdir -p "$ROOT/$1/memory"; printf '%s' "$ROOT/$1/memory"; }
# fire <project> -> the hook's stdout for a session whose transcript lives in that project
fire() {
  jq -cn --arg t "$ROOT/$1/sess.jsonl" \
    '{hook_event_name:"SessionStart",source:"startup",session_id:"s",transcript_path:$t}' \
    | bash "$HOOK"
}
ctx() { fire "$1" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
# note <dir> <file> -> a memory file; link <file> -> an index line linking it
note() { printf -- '---\nname: x\n---\nbody\n' > "$1/$2"; }
link() { printf -- '- [%s](%s) — hook\n' "$1" "$1"; }
filler() { i=0; while [ "$i" -lt "$1" ]; do printf -- '- plain line %d\n' "$i"; i=$((i + 1)); done; }

echo "A. healthy is silent"
d="$(mem ok)"; note "$d" a.md; note "$d" b.md
{ link a.md; link b.md; } > "$d/MEMORY.md"
is "a small, consistent index prints nothing" "$(fire ok)" ""
fire ok >/dev/null; is "and exits 0" "$?" 0

echo "B. size"
d="$(mem lines)"; { filler 179; } > "$d/MEMORY.md"
is "179 lines is silent" "$(fire lines)" ""
{ filler 180; } > "$d/MEMORY.md"
has "180 lines warns, with the count" "$(ctx lines)" "180 lines"
{ filler 179; printf '\n\n\n   \n'; } > "$d/MEMORY.md"
is "179 lines plus trailing blank lines is silent (counted trimmed)" "$(fire lines)" ""
d="$(mem chars)"; printf '%*s' 22499 '' | tr ' ' x > "$d/MEMORY.md"
is "22,499 characters is silent" "$(fire chars)" ""
printf '%*s' 22500 '' | tr ' ' x > "$d/MEMORY.md"
has "22,500 characters warns, with the count" "$(ctx chars)" "22500 characters"
d="$(mem dashes)"; printf '—%.0s' $(seq 8000) > "$d/MEMORY.md"
is "8,000 em dashes (24,000 bytes) is silent: characters, not bytes" "$(fire dashes)" ""
d="$(mem emoji)"; printf '😀%.0s' $(seq 11249) > "$d/MEMORY.md"
is "11,249 emoji (22,498 UTF-16 units) is silent" "$(fire emoji)" ""
printf '😀%.0s' $(seq 11250) > "$d/MEMORY.md"
has "11,250 emoji (22,500 UTF-16 units) warns: an emoji counts two, as in Claude Code" "$(ctx emoji)" "22500 characters"

echo "C. index consistency"
d="$(mem dangling)"; note "$d" a.md; { link a.md; link gone.md; } > "$d/MEMORY.md"
has "a link to a missing file is named" "$(ctx dangling)" "gone.md"
d="$(mem orphan)"; note "$d" a.md; note "$d" orphan.md; link a.md > "$d/MEMORY.md"
has "an unindexed memory file is named" "$(ctx orphan)" "orphan.md"
d="$(mem names)"; note "$d" 'my note.md'; note "$d" 'a+b.md'
{ link 'my note.md'; link 'a+b.md'; } > "$d/MEMORY.md"
is "names with spaces and regex characters match exactly" "$(fire names)" ""
d="$(mem dotslash)"; note "$d" a.md; printf -- '- [a](./a.md) — hook\n' > "$d/MEMORY.md"
is "a ./ link prefix is the same file" "$(fire dotslash)" ""
d="$(mem wiki)"; note "$d" a.md; { link a.md; printf -- '- see [[not-yet]]\n'; } > "$d/MEMORY.md"
is "a [[wiki-link]] to a memory not yet written is not flagged" "$(fire wiki)" ""
d="$(mem noindex)"; note "$d" a.md; note "$d" b.md
out="$(ctx noindex)"
has "no MEMORY.md: every file is named as unindexed (a.md)" "$out" "a.md"
has "no MEMORY.md: every file is named as unindexed (b.md)" "$out" "b.md"

echo "D. output shape"
d="$(mem shape)"; note "$d" a.md; { link a.md; link gone.md; } > "$d/MEMORY.md"
is "the output is SessionStart additionalContext" \
   "$(fire shape | jq -r '.hookSpecificOutput.hookEventName')" SessionStart
has "it names the memory directory" "$(ctx shape)" "$d"
before="$(find "$d" -type f -exec shasum {} + | sort)"
fire shape >/dev/null
is "the hook never writes to the memory directory" "$(find "$d" -type f -exec shasum {} + | sort)" "$before"

echo "E. fails open and silent"
mkdir -p "$ROOT/nomem"
is "no memory directory is silent" "$(fire nomem)" ""
out="$(printf '%s' '{"hook_event_name":"SessionStart"}' | bash "$HOOK")"; rc=$?
is "no transcript_path is silent, exit 0" "$rc/$out" "0/"
out="$(printf '%s' 'not json' | bash "$HOOK")"; rc=$?
is "malformed input is silent, exit 0" "$rc/$out" "0/"
out="$(bash "$HOOK" </dev/null)"; rc=$?
is "empty input is silent, exit 0" "$rc/$out" "0/"
stub="$ROOT/stub"; mkdir -p "$stub"; printf '#!/bin/sh\nexit 2\n' > "$stub/grep"; chmod +x "$stub/grep"
d="$(mem greperr)"; note "$d" a.md; note "$d" orphan.md; link a.md > "$d/MEMORY.md"
out="$(jq -cn --arg t "$ROOT/greperr/sess.jsonl" '{transcript_path:$t}' | PATH="$stub:$PATH" bash "$HOOK")"; rc=$?
is "a grep read error is silent, exit 0, never 'unindexed' advice" "$rc/$out" "0/"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Section B writes 8,000 `—` characters with no newline (24,000 bytes, 8,000 UTF-16 units) and 11,249/11,250 emoji (two UTF-16 units each).

- [ ] **Step 2: Run it and confirm it fails for the right reason**

Run: `chmod 755 tests/memory-health.test.sh && ./tests/memory-health.test.sh; echo "exit=$?"`
Expected: `missing script under test: …executable_memory-health.sh` and `exit=2`.

- [ ] **Step 3: Write the hook**

Create `dot_claude/hooks/executable_memory-health.sh`:

```bash
#!/usr/bin/env bash
# SessionStart hook: checks the session's project memory index and, only when something is
# wrong, tells the agent what to fix (spec 2026-10-06 section 4). Healthy is silent.
#
#   - MEMORY.md at 90% or more of the limits Claude Code loads it under, 200 lines and
#     25,000 characters (read from the Claude Code 2.1.289 binary), counted on the trimmed
#     content as Claude Code counts it: characters are UTF-16 code units (a JavaScript
#     string length), so an emoji counts two.
#   - an index link ](name.md) whose file does not exist;
#   - a memory file that no index link names.
# [[name]] links are not checked: a link to a memory not yet written is allowed.
#
# Read-only. Fails open and silent on every error. Bash 3.2 compatible.
set -uo pipefail
exec 2>/dev/null

LIMIT_LINES=200 LIMIT_CHARS=25000   # Claude Code 2.1.289
WARN_LINES=180 WARN_CHARS=22500     # 90% of each

command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat) || exit 0
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty') || exit 0
[ -n "$transcript" ] || exit 0
dir="$(dirname "$transcript")/memory"
[ -d "$dir" ] || exit 0
index="$dir/MEMORY.md"

problems=""
add() { problems="${problems}- $1
"; }

linked=""
if [ -f "$index" ]; then
  content=$(cat "$index") || exit 0
  # Trim leading and trailing whitespace, as Claude Code does before counting.
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  lines=0 units=0
  if [ -n "$content" ]; then
    lines=$(printf '%s' "$content" | awk 'END { print NR }') || exit 0
    units=$(printf '%s' "$content" | iconv -f UTF-8 -t UTF-16LE | wc -c | tr -d ' ') || exit 0
  fi
  case "$lines" in ''|*[!0-9]*) exit 0 ;; esac
  case "$units" in ''|*[!0-9]*) exit 0 ;; esac
  chars=$((units / 2))
  if [ "$lines" -ge "$WARN_LINES" ] || [ "$chars" -ge "$WARN_CHARS" ]; then
    add "MEMORY.md is at $lines lines and $chars characters; Claude Code loads at most $LIMIT_LINES lines and $LIMIT_CHARS characters of it. Consolidate the index (merge or shorten entries, one line each) to under $WARN_LINES lines and $WARN_CHARS characters."
  fi
  raw=$(grep -oE '\]\([^)]+\.md\)' "$index"); rc=$?
  # grep exits 1 when the index has no links; anything above that is a read error, and a
  # read error must stay silent rather than report every file as unindexed.
  [ "$rc" -le 1 ] || exit 0
  linked=$(printf '%s\n' "$raw" | sed -e 's/^](//' -e 's/)$//' -e 's|^\./||' \
             | awk 'NF && !/:\/\//' | sort -u) || exit 0
fi

dangling=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  [ -f "$dir/$name" ] || dangling="${dangling:+$dangling, }$name"
done <<EOF
$linked
EOF

unindexed=""
for f in "$dir"/*.md; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  [ "$name" = MEMORY.md ] && continue
  # A case match, not a grep pipe: no pipe can lose a match to SIGPIPE under pipefail.
  case "
$linked
" in
    *"
$name
"*) ;;
    *) unindexed="${unindexed:+$unindexed, }$name" ;;
  esac
done

[ -z "$dangling" ] || add "MEMORY.md links to files that do not exist: $dangling. Remove each entry, or restore the file if it was deleted by mistake."
[ -z "$unindexed" ] || add "Memory files that MEMORY.md does not list: $unindexed. Add an index line for each, or delete the file if it is obsolete."
[ -n "$problems" ] || exit 0

jq -cn --arg m "Memory health check for $dir:
$problems" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}' || exit 0
exit 0
```

- [ ] **Step 4: Run the suite and confirm it passes**

Run: `./tests/memory-health.test.sh 2>&1 | tail -1`
Expected: `passed: 25  failed: 0`.

- [ ] **Step 5: Add the failing settings checks**

In `tests/claude-settings.test.sh`, replace:

```bash
jq_is '.hooks.SessionStart | length' 2 "both SessionStart hooks present"
```

with:

```bash
jq_is '.hooks.SessionStart | length' 3 "all three SessionStart hooks present"
jq_is '[.hooks.SessionStart[] | select(has("matcher") | not) | .hooks[]
        | select(.command == "bash $HOME/.claude/hooks/memory-health.sh" and .timeout == 10)] | length' 1 \
      "the memory health hook: no matcher, timeout 10"
```

Run: `./tests/claude-settings.test.sh 2>&1 | grep -E 'FAIL|RESULT'`
Expected: two FAILs ("all three SessionStart hooks present", "the memory health hook…").

- [ ] **Step 6: Wire the hook into the settings template**

In `dot_claude/modify_private_settings.json`, inside `"SessionStart": [ … ]`, after the herdr agent-state entry (the object whose command is `$herdr_hook`, closed by `}` before the array's closing `],`), add a third entry so the array ends:

```
          {
            "matcher": "*",
            "hooks": [
              {
                "type": "command",
                "command": $herdr_hook,
                "timeout": 10
              }
            ]
          },
          # The memory health check (spec 2026-10-06 section 4). Silent when the project
          # memory index is healthy; otherwise it tells the agent what to fix. Read-only.
          {
            "hooks": [
              {
                "type": "command",
                "command": "bash $HOME/.claude/hooks/memory-health.sh",
                "timeout": 10
              }
            ]
          }
        ],
```

No apostrophes in the comment: the whole program is one single-quoted string.

- [ ] **Step 7: Allowlist the hook in `.chezmoiignore`**

After the line `!.claude/hooks/prompt-audit.sh`, add:

```
!.claude/hooks/memory-health.sh
```

Check: `grep -nx '!.claude/hooks/memory-health.sh' .chezmoiignore` prints exactly one line, directly after the prompt-audit line. Do not run `chezmoi` itself: it can reach 1Password.

- [ ] **Step 8: Run the suites and confirm they pass**

Run: `./tests/claude-settings.test.sh 2>&1 | tail -1` and `./tests/memory-health.test.sh 2>&1 | tail -1`
Expected: `RESULT: N passed, 0 failed` and `passed: N  failed: 0`.

- [ ] **Step 9: Commit**

```bash
git branch --show-current   # must print feat/review-convergence-memory-health
git add dot_claude/hooks/executable_memory-health.sh dot_claude/modify_private_settings.json .chezmoiignore \
        tests/claude-settings.test.sh
git add --chmod=+x tests/memory-health.test.sh
git commit -m "Check the project memory index at session start"
```

---

## After the tasks (driver, not a task)

- Run `./tests/run.sh` and report totals as passed/total.
- Set the spec's **Status** to `Implemented (branch feat/review-convergence-memory-health; the dotfiles have no MR)` and this plan's to `Implemented`, then the pre-merge cross-review.
- Michael deploys with `chezmoi apply`.
