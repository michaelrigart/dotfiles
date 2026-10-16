# Post-evaluation optimisations Implementation Plan

**Status:** Implemented on `feat/post-evaluation-optimisations`; executed once, do not run again.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the measured friction from the +14-day evaluation: subagents' `cd` denials, status-check turns, `xreview --help` failures and about 40 prompts per two weeks, without adding a prompt.

**Architecture:** Five independent changes to the chezmoi source: two instruction rules, a statusline segment that reads the SDD ledger, a help path in `xreview`, an allowlisted `sdd-clean` command, and a merged-branch exemption in rule 4 of the push guard. Each ships with its suite under `tests/`.

**Tech Stack:** bash (the statusline under `/bin/bash` 3.2), Python 3 (`/usr/bin/python3`, the push guard), git, jq, chezmoi templates.

**Spec:** `docs/superpowers/specs/2026-10-16-post-evaluation-optimisations-design.md` (Approved).

## Global Constraints

- No change adds a permission prompt. A check that fails falls back to today's behaviour (an ask), never to allow.
- `.chezmoitemplates/agents/global.md` stays at most 180 lines, `claude-code.md` at most 50; no rule is removed to make room.
- The fragments are public plain text: no template actions (`{{`), nothing private.
- The statusline runs under `/bin/bash` 3.2 and its source stays pure ASCII: glyphs are built from `printf` bytes.
- Every suite is `tests/<subject>.test.sh`, mode 755, and is executed (`./tests/x.test.sh`), never run through an interpreter. Report results as passed/total.
- Never start a Bash call with `cd`; use absolute paths or `git -C`.
- Implementers do not commit. They run only their task's suite and report back; the controller commits each task on its own.

## Review Focus

1. A ledger whose plan path is absolute, relative, or resolves outside the repository: only a plan file that resolves inside the top level counts (Task 2, "plan path outside the top level" and "absolute plan path" cases).
2. A session whose working directory is a subdirectory of the repository: the plan segment still shows (Task 2, "from a subdirectory" case).
3. A delete of several merged branches where only some are pinned: the deny's command pins every one (Task 5, "a partly pinned pair" case).
4. The default branch spelled `refs/heads/main`, and a remote whose `HEAD` names another branch than the local `origin/HEAD`: both still ask (Task 5, "the default branch as refs/heads/main" and "the remote's HEAD names another branch" cases).
5. `sdd-clean` given a relative path with a trailing slash works, and a workspace that is itself a git work tree is refused (Task 4, "relative path with a trailing slash" and "a nested work tree" cases).

## Execution

All five tasks have no dependency, touch disjoint files, and share no test resource, so they form one batch: dispatch the five implementers together, then commit and review each task on its own commit, one at a time, and run the full suite (`./tests/run.sh`) once for the batch.

Controller steps outside the tasks:
- Before dispatching: set the spec's `**Status:**` to `In progress` and commit it ("Mark the post-evaluation optimisations spec in progress").
- After the batch: run `./tests/run.sh` and the whole-branch review, and fix what they find.
- Then the final pre-merge commit: the spec's status `Implemented`, and this plan marked so it is not run again (a `**Status:** Implemented` line under the title).
- Then the Codex pre-merge review of the whole branch, that commit included (`xreview round --reset`, then `--checkpoint pre-merge --diff main...feat/post-evaluation-optimisations`). Every fix round gets a fresh full-range round, so no commit lands after the last approval. Then push the branch.

---

### Task 1: Instruction rules

**Depends on:** none

**Files:**
- Modify: `.chezmoitemplates/agents/claude-code.md:15-17`
- Modify: `.chezmoitemplates/agents/global.md:95-96`, `:130-131`, `:136-137`
- Test: `tests/agent-instructions.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the instruction text naming `sdd-clean <workspace>` (Task 4 builds the command).

- [ ] **Step 1: Write the failing tests**

In `tests/agent-instructions.test.sh`, insert before the final `printf '\npassed: …` line:

```bash
# The rules spec 2026-10-16 adds: both shapes the path-resolution guard denies, the plan
# workspace cleaner, and progress on a long run. Each is a fixed string on one line.
need() { # need <fragment> <fixed text> <label>
  if grep -qF -- "$2" "$FRAG/$1"; then _pass "$3"; else _fail "$3" "missing: $2"; fi
}
need claude-code.md '- **Path-resolution guard.** Never start a Bash call with `cd`: use absolute paths,' \
  "claude-code.md carries the path-resolution guard rule"
need claude-code.md '`grep`/`rg` over `.`, which re-prompts in any tree that could hold a deny-glob match.' \
  "the path-resolution rule keeps the recursive-search shape"
need claude-code.md '`sdd-clean <workspace>`, never `rm -rf`.' \
  "claude-code.md deletes a finished plan workspace with sdd-clean"
need global.md 'to take over about 15 minutes, give its size and ETA at the start and one line per' \
  "global.md's Momentum rule asks for size and ETA on a long run"
if grep -qF -- '**Recursive search.**' "$FRAG/claude-code.md"; then
  _fail "the Recursive search bullet is folded into the path-resolution rule" "still present"
else
  _pass "the Recursive search bullet is folded into the path-resolution rule"
fi
```

- [ ] **Step 2: Run the suite to verify the new cases fail**

Run: `./tests/agent-instructions.test.sh`
Expected: the five new cases FAIL, every other case PASSes.

- [ ] **Step 3: Replace the Recursive search bullet in `claude-code.md`**

Replace lines 15-17:

```markdown
- **Recursive search.** A recursive `grep`/`rg` over `.` in a tree that could hold a
  deny-glob match (such as `**/secrets.*.yml`) re-prompts every time. Name the directories
  instead.
```

with:

```markdown
- **Path-resolution guard.** Never start a Bash call with `cd`: use absolute paths,
  `git -C`, or a `cd` in a call of its own. Name directories instead of a recursive
  `grep`/`rg` over `.`, which re-prompts in any tree that could hold a deny-glob match.
- **Plan workspaces.** Delete a finished `.superpowers/sdd/<plan>` workspace with
  `sdd-clean <workspace>`, never `rm -rf`.
```

The file goes from 48 to 50 lines.

- [ ] **Step 4: Edit `global.md`, keeping it at 180 lines**

Replace lines 95-96:

```markdown
- Be concise and direct. Lead with the answer, diff or command, and skip preamble and
  flattery.
```

with:

```markdown
- Be concise and direct. Lead with the answer, diff or command; skip preamble and flattery.
```

Replace lines 130-131:

```markdown
- **Fix now.** Fix in-scope findings in the same branch. No follow-up MRs unless Michael
  asks.
```

with:

```markdown
- **Fix now.** Fix in-scope findings on this branch. No follow-up MRs unless Michael asks.
```

Replace the Momentum bullet (lines 136-137):

```markdown
- **Momentum.** Don't stop while the next step is already authorised. Send one
  notification when an unattended stretch ends or is blocked, not one per step.
```

with:

```markdown
- **Momentum.** Don't stop while the next step is already authorised. For a run expected
  to take over about 15 minutes, give its size and ETA at the start and one line per
  milestone, without stopping. Send one notification when an unattended stretch ends or
  is blocked, not one per step.
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `./tests/agent-instructions.test.sh`
Expected: every case PASSes, including `global.md is at most 180 lines (180)` and `claude-code.md is at most 50 lines (50)`. Also run `awk 'length > 92' .chezmoitemplates/agents/global.md .chezmoitemplates/agents/claude-code.md | wc -l` and confirm no edited line is longer than 92 characters (one pre-existing line of 96 is not yours).

- [ ] **Step 6: Report back.** The controller commits `.chezmoitemplates/agents/claude-code.md`, `.chezmoitemplates/agents/global.md` and `tests/agent-instructions.test.sh` as "Tell agents about the path-resolution guard, sdd-clean and progress on long runs".

---

### Task 2: Statusline plan progress, without directory and branch inside Herdr

**Depends on:** none

**Files:**
- Modify: `dot_claude/executable_statusline.sh`
- Test: `tests/statusline.test.sh`

**Interfaces:**
- Consumes: the SDD ledger format: `<top>/.superpowers/sdd/<name>/progress.md`, first line `# SDD ledger — plan: <plan path>` (an em dash, U+2014), progress lines containing `Task <N>: complete`; plans use `### Task <N>` headings.
- Produces: nothing other tasks use.

- [ ] **Step 1: Write the failing tests**

In `tests/statusline.test.sh`, change `run()` so a case can set `HERDR_PANE_ID` (the existing cases leave it unset, as `env -i` already does):

```bash
# run <bin: none|tt> <cols> [TT_OUT] [TT_RC] [TT_ERR] -> the statusline's stdout.
# Its stderr goes to $T/stderr, so a leak can be asserted on. HERDR_PANE, when set, is passed
# as HERDR_PANE_ID: the statusline then runs as inside a Herdr pane.
run() {
  printf '%s' "$INPUT" | env -i HOME="$T" PATH="$T/$1:/usr/bin:/bin" COLUMNS="$2" \
    ${HERDR_PANE:+HERDR_PANE_ID=$HERDR_PANE} \
    STUB_ARGS="$T/args" TT_OUT="${3:-}" TT_RC="${4:-0}" TT_ERR="${5:-}" bash "$SL" 2>"$T/stderr"
}
```

Then insert before the final `echo "statusline: $pass passed, $fail failed"`:

```bash
# --- plan progress: the newest SDD ledger in the session's repository ---
INPUT_PLAIN=$INPUT
ORANGE='38;2;255;158;100'
mkrepo repo-plan main
PR="$T/repo-plan"; WS="$PR/.superpowers/sdd/p"; WS2="$PR/.superpowers/sdd/q"
mkdir -p "$WS" "$PR/docs" "$PR/sub" "$T/outside"
printf '# Plan\n\n### Task 1: a\n\n### Task 2: b\n\n### Task 3: c\n\n### Task 4: d\n' > "$PR/docs/plan.md"
cp "$PR/docs/plan.md" "$T/outside/plan.md"
LHEAD="# SDD ledger $DASH plan: docs/plan.md"
# ago <minutes>: a touch -t stamp that many minutes in the past.
ago() { date -v-"$1"M +%Y%m%d%H%M.%S; }
# ledger <dir> <created minutes ago> <first line> [done task numbers...]: a ledger created
# that long ago and modified now. touch -t to an earlier time moves the birth time back as
# well; the appends after it move only the modification time.
ledger() {
  local dir=$1 age=$2 first=$3 n; shift 3
  mkdir -p "$dir"; rm -f "$dir/progress.md"
  printf '%s\n' "$first" > "$dir/progress.md"
  touch -t "$(ago "$age")" "$dir/progress.md"
  for n in "$@"; do printf 'Task %s: complete (abc1234)\n' "$n" >> "$dir/progress.md"; done
  printf 'note\n' >> "$dir/progress.md"
}
# plan_is <label> <expected segment text>: shown in orange, exactly 200 wide.
plan_is() {
  local out; out=$(run none 200)
  if has "$(strip "$out")" " $2 " && has "$out" "$ORANGE" && [ "$(vis "$out")" = 200 ]; then
    _pass "$1 shows '$2', exactly 200 wide"
  else _fail "$1 should show '$2'" "$(strip "$out")"; fi
}
# no_plan <label>: no plan segment at all.
no_plan() {
  local out; out=$(run none 200)
  if ! has "$(strip "$out")" "plan " && ! has "$out" "$ORANGE" && [ "$(vis "$out")" = 200 ]; then
    _pass "$1 shows no plan segment"
  else _fail "$1 should show no plan segment" "$(strip "$out")"; fi
}
in_dir repo-plan
ledger "$WS" 10 "$LHEAD" 1;            plan_is "1 of 4 done after 10 minutes" "plan 1/4 $DOT ~30m"
ledger "$WS" 120 "$LHEAD" 1 2 3;       plan_is "3 of 4 done after 2 hours" "plan 3/4 $DOT ~40m"
ledger "$WS" 90 "$LHEAD" 1 2 2;        plan_is "a task completed twice counts once" "plan 2/4 $DOT ~1.5h"
ledger "$WS" 120 "$LHEAD" 1;           plan_is "1 of 4 done after 2 hours" "plan 1/4 $DOT ~6h"
ledger "$WS" 780 "$LHEAD" 1 2;         plan_is "a ledger created 13 hours ago" "plan 2/4"
has "$(strip "$(run none 200)")" "plan 2/4 $DOT" && _fail "no ETA past 12 hours" "ETA shown" \
  || _pass "no ETA past 12 hours"
ledger "$WS" 10 "$LHEAD";              plan_is "no finished task yet" "plan 0/4"
has "$(strip "$(run none 200)")" "plan 0/4 $DOT" && _fail "no ETA before the first finished task" "ETA shown" \
  || _pass "no ETA before the first finished task"
ledger "$WS" 10 "$LHEAD" 1 2 3 4;      no_plan "a finished plan"
ledger "$WS" 500 "$LHEAD" 1; touch -t "$(ago 420)" "$WS/progress.md"
no_plan "a ledger last modified 7 hours ago"
ledger "$WS" 10 "# notes" 1;           no_plan "a ledger whose first line names no plan"
ledger "$WS" 10 "# SDD ledger $DASH plan: docs/missing.md" 1; no_plan "a ledger whose plan file is missing"
ledger "$WS" 10 "# SDD ledger $DASH plan: ../outside/plan.md" 1; no_plan "a plan path outside the top level"
ledger "$WS" 10 "# SDD ledger $DASH plan: $T/outside/plan.md" 1; no_plan "an absolute plan path outside the top level"
ln -s "$T/outside/plan.md" "$PR/docs/link.md"
ledger "$WS" 10 "# SDD ledger $DASH plan: docs/link.md" 1; no_plan "a plan file that is a symlink to one outside the top level"
ledger "$WS" 10 "# SDD ledger $DASH plan: $PR/docs/plan.md" 1;  plan_is "an absolute plan path" "plan 1/4 $DOT ~30m"
ledger "$WS2" 60 "$LHEAD" 1 2 3; touch -t "$(ago 30)" "$WS2/progress.md"
ledger "$WS" 10 "$LHEAD" 1;            plan_is "the most recently modified ledger" "plan 1/4 $DOT ~30m"
rm -rf "$WS2"
in_dir repo-plan/sub;                  plan_is "from a subdirectory" "plan 1/4 $DOT ~30m"
in_dir repo-plan

# Inside a Herdr pane the directory and branch segments go; the plan stays.
out=$(HERDR_PANE=w1:p2 run none 200)
if ! has "$(strip "$out")" "repo-plan" && ! has "$(strip "$out")" "$BR main" \
   && has "$(strip "$out")" "plan 1/4" && [ "$(vis "$out")" = 200 ]; then
  _pass "inside a Herdr pane there is no directory or branch segment"
else _fail "inside a Herdr pane" "$(strip "$out")"; fi
out=$(run none 200)
if has "$(strip "$out")" "repo-plan" && has "$(strip "$out")" "$BR main"; then
  _pass "outside a Herdr pane the directory and branch segments stay"
else _fail "outside a Herdr pane" "$(strip "$out")"; fi

# The fit boundary: the plan segment is the first one dropped.
wide=$(strip "$(run none 500)")
trail=${wide##*[! ]}
with_w=$((500 - 1 - ${#trail}))
out=$(run none "$((with_w + 2))")
if has "$(strip "$out")" "plan 1/4" && [ "$(vis "$out")" = "$((with_w + 2))" ]; then
  _pass "at COLUMNS - 2 the plan segment is shown"
else _fail "plan segment should fit at $((with_w + 2)) columns" "$(strip "$out")"; fi
narrow=$(run none "$((with_w + 1))")
mv "$WS/progress.md" "$T/progress.md.off"
if [ "$narrow" = "$(run none "$((with_w + 1))")" ]; then
  _pass "at COLUMNS - 1 the plan segment is left out and the line is byte-identical"
else _fail "plan segment should be left out at $((with_w + 1)) columns" "$(strip "$narrow")"; fi
# With tagteam too, plan goes before tagteam: where only one fits, tagteam stays.
tt_alone=$(strip "$(run tt 500 "$TT\n")"); trail=${tt_alone##*[! ]}
tt_w=$((500 - 1 - ${#trail}))
mv "$T/progress.md.off" "$WS/progress.md"
out=$(run tt "$((tt_w + 2))" "$TT\n")
mv "$WS/progress.md" "$T/progress.md.off"
if [ "$out" = "$(run tt "$((tt_w + 2))" "$TT\n")" ] && has "$(strip "$out")" "$TT"; then
  _pass "where only one fits, the plan segment goes and tagteam stays"
else _fail "plan should drop before tagteam" "$(strip "$out")"; fi
mv "$T/progress.md.off" "$WS/progress.md"
INPUT=$INPUT_PLAIN
```

- [ ] **Step 2: Run the suite to verify the new cases fail**

Run: `./tests/statusline.test.sh`
Expected: the plan and Herdr cases FAIL (no plan segment exists yet), every earlier case PASSes.

- [ ] **Step 3: Implement**

In `dot_claude/executable_statusline.sh`:

1. Header comment (lines 3-4) becomes:

```bash
# Segments: dir  git branch (both left out inside a Herdr pane, whose workspace shows
# them)  model  tagteam  most-recent skill/plugin  plan progress, then a bar to the right
# edge. Receives the session JSON on stdin; terminal width from $COLUMNS.
```

2. The branch block computes the branch only outside Herdr:

```bash
# --- git branch (only if cwd is a work tree; Herdr's workspace shows it inside a pane) ---
branch=""
if [ -z "${HERDR_PANE_ID:-}" ] && [ -n "$cwd" ] \
   && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi
```

3. Add the palette entry after `RED=…`:

```bash
ORANGE="255;158;100"  # #ff9e64  plan progress text
```

4. After the tagteam block (the `tt_fg` lines) and before the `model_seg` block, add:

```bash
# --- plan progress: the newest subagent-driven plan run in this repository ---
# The ledger is the most recently modified <top>/.superpowers/sdd/*/progress.md. It counts
# when it was modified within 6 hours and its first line names a plan file that resolves
# inside <top>. total counts the plan's "### Task <N>" headings, done the distinct N on the
# ledger's "Task <N>: complete" lines; the segment shows while 0 < total and done < total.
# The ETA (ledger age / done x tasks left) needs a finished task and a ledger created within
# 12 hours: minutes under an hour, half hours above. Any failure leaves plan empty.
plan=""
plan_progress() {
  local top best f now mt bt first path pdir total finished age eta m halves
  top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return
  [ -n "$top" ] || return
  best=""
  for f in "$top"/.superpowers/sdd/*/progress.md; do
    [ -f "$f" ] || continue
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best=$f; fi
  done
  [ -n "$best" ] || return
  now=$(date +%s)
  mt=$(stat -f %m "$best" 2>/dev/null) || return
  [ $((now - mt)) -le 21600 ] || return
  first=""
  IFS= read -r first < "$best" || [ -n "$first" ] || return
  first=${first%$'\r'}
  case $first in "# SDD ledger $DASH plan: "?*) ;; *) return ;; esac
  path=${first#"# SDD ledger $DASH plan: "}
  case $path in /*) ;; *) path=$top/$path ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] || return
  pdir=$(CDPATH= cd -P -- "${path%/*}" 2>/dev/null && pwd -P) || return
  case $pdir/ in "$top"/*) ;; *) return ;; esac
  total=$(grep -cE '^### Task [0-9]+([^0-9]|$)' "$path" 2>/dev/null) || return
  finished=$(grep -oE 'Task [0-9]+: complete' "$best" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  [ "$total" -gt 0 ] && [ "$finished" -lt "$total" ] || return
  plan="plan $finished/$total"
  bt=$(stat -f %B "$best" 2>/dev/null) || return
  age=$((now - bt))
  [ "$finished" -ge 1 ] && [ "$age" -ge 0 ] && [ "$age" -le 43200 ] || return
  eta=$((age * (total - finished) / finished))
  m=$(((eta + 30) / 60))
  if [ "$m" -lt 60 ]; then
    [ "$m" -ge 1 ] || m=1
    plan="$plan $DOT ~${m}m"
  else
    halves=$(((eta + 900) / 1800))
    if [ $((halves % 2)) -eq 1 ]; then plan="$plan $DOT ~$((halves / 2)).5h"
    else plan="$plan $DOT ~$((halves / 2))h"; fi
  fi
}
[ -n "$cwd" ] && plan_progress
```

`git rev-parse --show-toplevel` prints the physical path, so `pdir` is compared physically too. The plan file itself must not be a symlink: `cd -P` resolves only its directory, so a symlinked file could point outside the top level.

5. Replace `build_segs` with a two-flag version:

```bash
# segments: "fg|bg|text"  (';' is used inside colors, so '|' is a safe delimiter)
# build_segs <tagteam 0|1> <plan 0|1>: 1 adds that segment. The tagteam segment goes after
# the model and gives the skill segment the NIGHT shade; the plan segment goes last, in the
# shade the skill segment does not use, so neighbouring backgrounds keep alternating. Inside
# a Herdr pane the directory and branch segments are left out.
build_segs() {
  local skill_bg=$BGHL plan_bg
  segs=()
  if [ -z "${HERDR_PANE_ID:-}" ]; then
    segs+=("$BLUE|$NIGHT|$dir")
    [ -n "$branch" ] && segs+=("$GREEN|$BGHL|$BR $branch")
  fi
  segs+=("$CYAN|$NIGHT|$model_seg")
  if [ "$1" = 1 ]; then
    segs+=("$tt_fg|$BGHL|$tt")
    skill_bg=$NIGHT
  fi
  if [ -n "$skill" ]; then
    segs+=("$MAGENTA|$skill_bg|$ARR $skill")
  else
    segs+=("$COMMENT|$skill_bg|$ARR $DASH")
  fi
  if [ "$2" = 1 ]; then
    plan_bg=$BGHL; [ "$skill_bg" = "$BGHL" ] && plan_bg=$NIGHT
    segs+=("$ORANGE|$plan_bg|$plan")
  fi
}
```

6. Replace the tagteam fit block (the comment starting "The renderer never truncates" and the `if [ -n "$tt" ]; then … fi` after it) with:

```bash
# The renderer never truncates, so an optional segment (plan, tagteam) is kept only when the
# closing separator and at least one column of filler still fit (w <= cols - 2) and every
# character's width is known (unknown = 0). Then each character takes exactly the one column
# w counts for it, so the line ends exactly at $cols. The plan segment is dropped first,
# then tagteam; without both the line is what it always was.
fits() { [ "$w" -le $((cols - 2)) ] && [ "$unknown" -eq 0 ]; }
use_tt=0; [ -n "$tt" ] && use_tt=1
kept=0
if [ -n "$plan" ]; then build_segs "$use_tt" 1; render; fits && kept=1; fi
if [ "$kept" = 0 ] && [ "$use_tt" = 1 ]; then build_segs 1 0; render; fits && kept=1; fi
[ "$kept" = 0 ] && { build_segs 0 0; render; }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./tests/statusline.test.sh`
Expected: every case PASSes, the earlier tagteam and width cases unchanged. Also confirm the source is still ASCII: `LC_ALL=C grep -c $'[^\t -~]' dot_claude/executable_statusline.sh` prints 0.

- [ ] **Step 5: Report back.** The controller commits `dot_claude/executable_statusline.sh` and `tests/statusline.test.sh` as "Show plan progress in the statusline, and leave directory and branch to Herdr".

---

### Task 3: `xreview --help`

**Depends on:** none

**Files:**
- Modify: `dot_local/bin/executable_xreview:1052-1062`
- Test: `tests/xreview.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other tasks use.

- [ ] **Step 1: Write the failing tests**

In `tests/xreview.test.sh`, insert before the final `printf '\npassed: …` line (the working directory there is `$ROOT/repo`, with every collaborator stubbed on `PATH` and logging to `$CALLS`):

```bash
# H1-H6: every help form prints the usage of every subcommand on stdout and exits 0,
# touching nothing.
: > "$CALLS"
for form in "help" "-h" "--help" "dispatch --help" "collect xr-1-a -h" "apply --help"; do
  # shellcheck disable=SC2086
  out="$(bash "$XREVIEW" $form 2>"$ROOT/help-err")"; rc=$?
  missing=""
  for sub in "dispatch --checkpoint spec|plan|pre-merge" "collect <nonce>" "apply <nonce>" \
             "apply --done" "round [--reset]" "receipts [--tiers]" "tier [thread]" "thread" "init [id]"; do
    printf '%s' "$out" | grep -qF -- "$sub" || missing="$missing [$sub]"
  done
  is "H xreview $form exits 0 with every subcommand's usage on stdout and nothing on stderr" \
     "$rc/${missing:-all}/$(wc -c < "$ROOT/help-err" | tr -d ' ')" "0/all/0"
done
is "H7 no help form called herdr, the daemon or the reviewer" "$(wc -c < "$CALLS" | tr -d ' ')" 0
```

- [ ] **Step 2: Run the suite to verify the new cases fail**

Run: `./tests/xreview.test.sh`
Expected: the H cases FAIL (`unknown option: --help`, or the usage on stderr with exit 1), every other case PASSes.

- [ ] **Step 3: Implement**

In `dot_local/bin/executable_xreview`, replace the final `case` (line 1052 to the end) with:

```bash
usage() {
  cat <<'EOF'
usage: xreview <command> [args]

  dispatch --checkpoint spec|plan|pre-merge [--diff [<repo-path>:]<range>]... <body-file>
                          start a review turn; prints its nonce
  collect <nonce> [budget]
                          wait for the reviewer's answer (budget in whole seconds)
  apply <nonce>           open the apply window for that review's findings
  apply --done            close the apply window
  round [--reset]         print the round counter; --reset drops the cached thread and pin
  receipts [--tiers]      list the reviews on record
  tier [thread]           print the reviewer's model and effort
  thread                  print the checkpoint's review thread
  init [id]               pin a review thread (the pane's own without an id)
  help, -h, --help        print this
EOF
}

# A help flag anywhere, or the help command, prints the usage and does nothing else.
for a in "$@"; do
  case $a in -h|--help) usage; exit 0 ;; esac
done

case "${1:-}" in
  help)     usage; exit 0 ;;
  dispatch) shift; cmd_dispatch "$@" ;;
  collect)  shift; cmd_collect "$@" ;;
  init)     shift; cmd_init "$@" ;;
  thread)   shift; cmd_thread ;;
  tier)     shift; cmd_tier "$@" ;;
  receipts) shift; cmd_receipts "$@" ;;
  apply)    shift; cmd_apply "$@" ;;
  round)    shift; cmd_round "$@" ;;
  *) die "usage: xreview init [id] | thread | receipts [--tiers] | apply <nonce>|--done | round [--reset] | dispatch --checkpoint spec|plan|pre-merge [--diff [<repo-path>:]<range>]... <body-file> | tier [thread] | collect <nonce> [budget]" ;;
esac
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./tests/xreview.test.sh`
Expected: every case PASSes.

- [ ] **Step 5: Report back.** The controller commits `dot_local/bin/executable_xreview` and `tests/xreview.test.sh` as "Print xreview's usage for help, -h and --help".

---

### Task 4: `sdd-clean`

**Depends on:** none

**Files:**
- Create: `dot_local/bin/executable_sdd-clean` (mode 755)
- Create: `tests/sdd-clean.test.sh` (mode 755)
- Modify: `dot_claude/modify_private_settings.json` (the `permissions.allow` list, after the `chezmoi status` rules)
- Modify: `tests/claude-settings.test.sh` (section A)

**Interfaces:**
- Consumes: the SDD workspace layout: `<top>/.superpowers/sdd/<name>/`, git-ignored.
- Produces: `sdd-clean <workspace>...`: exit 0 when every workspace was deleted, 1 when any argument was refused (nothing deleted), 2 on usage. Refusals go to stderr as `sdd-clean: refusing <arg>: <reason>`.

- [ ] **Step 1: Write the failing tests**

Create `tests/sdd-clean.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for dot_local/bin/executable_sdd-clean: it deletes a finished SDD plan workspace,
# <top>/.superpowers/sdd/<name>, only when git ignores it and tracks nothing in it, and
# refuses everything else without deleting anything.
#
#   ./tests/sdd-clean.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SC="$SRC/dot_local/bin/executable_sdd-clean"
[ -f "$SC" ] || { echo "missing script under test: $SC" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/sdd-clean.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"

# repo <name>: a work tree that ignores .superpowers/, as this repository does.
repo() {
  git init -q "$T/$1"
  printf '.superpowers/\n' > "$T/$1/.gitignore"
  git -C "$T/$1" add .gitignore && git -C "$T/$1" commit -q -m init
}
# ws <path>: a workspace with a ledger in it.
ws() { mkdir -p "$1" && printf '# SDD ledger\n' > "$1/progress.md"; }
# deleted <label> <args...>: exit 0, and every argument is gone.
deleted() {
  local label=$1 a gone=1 rc; shift
  "$SC" "$@" 2>"$T/err"; rc=$?
  for a in "$@"; do [ -e "$a" ] && gone=0; done
  if [ "$rc" = 0 ] && [ "$gone" = 1 ]; then _pass "$label"
  else _fail "$label" "rc=$rc, stderr: $(cat "$T/err")"; fi
}
# refused <label> <reason text> <args...>: exit 1, the reason on stderr, and every argument
# that existed before the call still in place.
refused() {
  local label=$1 why=$2 a kept=1 rc pre=(); shift 2
  for a in "$@"; do if [ -e "$a" ] || [ -L "$a" ]; then pre+=("$a"); fi; done
  "$SC" "$@" 2>"$T/err"; rc=$?
  for a in ${pre[@]+"${pre[@]}"}; do [ -e "$a" ] || [ -L "$a" ] || kept=0; done
  if [ "$rc" = 1 ] && [ "$kept" = 1 ] && grep -qF -- "$why" "$T/err"; then _pass "$label"
  else _fail "$label" "rc=$rc kept=$kept, stderr: $(cat "$T/err")"; fi
}

repo r; R="$T/r"
ws "$R/.superpowers/sdd/a";             deleted "an ignored workspace is deleted" "$R/.superpowers/sdd/a"
ws "$R/.superpowers/sdd/b"; ws "$R/.superpowers/sdd/c"
deleted "two workspaces in one call" "$R/.superpowers/sdd/b" "$R/.superpowers/sdd/c"
ws "$R/.superpowers/sdd/d"
( CDPATH= cd -- "$R" && "$SC" .superpowers/sdd/d/ ) 2>"$T/err"
[ ! -e "$R/.superpowers/sdd/d" ] && _pass "a relative path with a trailing slash" \
  || _fail "a relative path with a trailing slash" "$(cat "$T/err")"

mkdir -p "$R/docs";                     refused "a directory outside .superpowers/sdd/" "not a workspace directly under" "$R/docs"
ws "$R/.superpowers/sdd/e/deeper";      refused "a directory two levels down" "not a workspace directly under" "$R/.superpowers/sdd/e/deeper"
refused "the sdd directory itself" "not a workspace directly under" "$R/.superpowers/sdd"
refused "a path that does not exist" "not a directory" "$R/.superpowers/sdd/none"
ws "$T/elsewhere"; ln -s "$T/elsewhere" "$R/.superpowers/sdd/link"
refused "a symlink to a directory elsewhere" "symlink" "$R/.superpowers/sdd/link"
ws "$R/.superpowers/sdd/nested"; git init -q "$R/.superpowers/sdd/nested"
refused "a nested work tree" "not a workspace directly under" "$R/.superpowers/sdd/nested"
ws "$R/.superpowers/sdd/tracked"; git -C "$R" add -f .superpowers/sdd/tracked/progress.md
git -C "$R" commit -q -m "track a workspace"
refused "a workspace git tracks files in" "tracks" "$R/.superpowers/sdd/tracked"

repo plain; printf '' > "$T/plain/.gitignore"; git -C "$T/plain" commit -q -am "ignore nothing"
ws "$T/plain/.superpowers/sdd/x";       refused "a workspace git does not ignore" "does not ignore" "$T/plain/.superpowers/sdd/x"
ws "$T/norepo/.superpowers/sdd/x";      refused "a directory outside any repository" "not inside a git work tree" "$T/norepo/.superpowers/sdd/x"
repo other; ws "$T/other/real/sdd/x"; mkdir -p "$T/other/.superpowers"
ln -s "$T/other/real/sdd" "$T/other/.superpowers/sdd"
refused "a workspace reached through a symlinked sdd directory" "not a workspace directly under" "$T/other/.superpowers/sdd/x"

ws "$R/.superpowers/sdd/f"
refused "one refusal deletes nothing" "not a workspace directly under" "$R/.superpowers/sdd/f" "$R/docs"

"$SC" 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && grep -qF 'usage: sdd-clean' "$T/err" && _pass "no argument is a usage error (exit 2)" \
  || _fail "no argument is a usage error (exit 2)" "rc=$rc, stderr: $(cat "$T/err")"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then `chmod 755 tests/sdd-clean.test.sh`.

In `tests/claude-settings.test.sh`, section A, after the `"glab api stays out — it is not read-only"` assertion, add:

```bash
# sdd-clean is the one allowlisted command that deletes: it refuses anything but a
# git-ignored .superpowers/sdd/<plan> workspace (tests/sdd-clean.test.sh pins that).
jq_is '.permissions.allow | index("Bash(sdd-clean *)") != null' true \
      "sdd-clean is allowlisted, so a finished plan's cleanup needs no prompt"
```

- [ ] **Step 2: Run the suites to verify they fail**

Run: `./tests/sdd-clean.test.sh` — Expected: exits 2, "missing script under test".
Run: `./tests/claude-settings.test.sh` — Expected: the new sdd-clean case FAILs, every other case PASSes.

- [ ] **Step 3: Implement `sdd-clean`**

Create `dot_local/bin/executable_sdd-clean`, then `chmod 755` it:

```bash
#!/usr/bin/env bash
# sdd-clean <workspace>...: delete finished subagent-driven-development plan workspaces.
#
# A workspace is deleted only when it is not a symlink, its real path is
# <top>/.superpowers/sdd/<name> where <top> is the top level of the git work tree holding
# it, git ignores it, and git tracks no file inside it. Every argument is checked before
# anything is deleted, so one refusal deletes nothing. The command is allowlisted
# (Bash(sdd-clean *)): these checks are all that stands between an agent and a silent
# rm -rf, so each one fails closed.
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: sdd-clean <workspace>..." >&2; exit 2; }

refused=0
targets=()
refuse() { printf 'sdd-clean: refusing %s: %s\n' "$1" "$2" >&2; refused=1; }

for arg in "$@"; do
  p=$arg
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  if [ -L "$p" ]; then refuse "$arg" "it is a symlink"; continue; fi
  if [ ! -d "$p" ]; then refuse "$arg" "it is not a directory"; continue; fi
  real=$(CDPATH= cd -P -- "$p" 2>/dev/null && pwd -P) \
    || { refuse "$arg" "its real path cannot be resolved"; continue; }
  top=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null) || top=""
  [ -n "$top" ] || { refuse "$arg" "it is not inside a git work tree"; continue; }
  top=$(CDPATH= cd -P -- "$top" 2>/dev/null && pwd -P) \
    || { refuse "$arg" "its work tree cannot be resolved"; continue; }
  name=${real##*/}
  case $name in ''|.|..) refuse "$arg" "it names no workspace"; continue ;; esac
  if [ "$real" != "$top/.superpowers/sdd/$name" ]; then
    refuse "$arg" "it is not a workspace directly under $top/.superpowers/sdd/"; continue
  fi
  tracked=$(git -C "$top" ls-files -- ".superpowers/sdd/$name") \
    || { refuse "$arg" "git cannot list what it tracks"; continue; }
  if [ -n "$tracked" ]; then refuse "$arg" "git tracks files inside it"; continue; fi
  if ! git -C "$top" check-ignore -q -- ".superpowers/sdd/$name"; then
    refuse "$arg" "git does not ignore it"; continue
  fi
  targets+=("$real")
done

[ "$refused" = 0 ] || { echo "sdd-clean: nothing deleted" >&2; exit 1; }
for t in "${targets[@]}"; do
  rm -rf -- "$t" || { printf 'sdd-clean: could not delete %s\n' "$t" >&2; exit 1; }
done
```

A nested repository or worktree has its own top level, so its real path never equals `<top>/.superpowers/sdd/<name>` and it is refused.

- [ ] **Step 4: Allowlist it**

In `dot_claude/modify_private_settings.json`, in `permissions.allow`, after the line `"Bash(chezmoi status)",     "Bash(chezmoi status *)",`, add:

```
          # sdd-clean deletes only a git-ignored .superpowers/sdd/<plan> workspace and
          # refuses anything else, so a finished plan's cleanup needs no prompt.
          "Bash(sdd-clean *)",
```

- [ ] **Step 5: Run the suites to verify they pass**

Run: `./tests/sdd-clean.test.sh` — Expected: every case PASSes.
Run: `./tests/claude-settings.test.sh` — Expected: every case PASSes, the "no mutating verb is allowlisted" case included.

- [ ] **Step 6: Report back.** The controller commits `dot_local/bin/executable_sdd-clean`, `tests/sdd-clean.test.sh`, `dot_claude/modify_private_settings.json` and `tests/claude-settings.test.sh` as "Add sdd-clean, an allowlisted cleaner for finished plan workspaces", after checking `git ls-files -s` shows mode 100755 for both new files.

---

### Task 5: Merged-branch deletes in the push guard

**Depends on:** none

**Files:**
- Modify: `dot_claude/git-push-guard.py` (constants near `DWIM_PREFIXES`; new functions after `default_branch()`; `evaluate()` before its final `if asks:`)
- Test: `tests/git-forge-guard.test.sh` (a new section after the line `expect ask   "--all" …`)

**Interfaces:**
- Consumes: `Repo.run`, `Repo.has_ref`, `Deny`, `DWIM_PREFIXES`, `CURRENT_BRANCH`, and in `evaluate()` the locals `flags`, `refspecs`, `args`, `remote`, `default`, `asks`, `repo`.
- Produces: `delete_targets(flags, refspecs) -> list[str] | None`, `push_leases(args) -> list[tuple[str, str]]`, `merged_delete(repo, remote, default, names, leases) -> True | str | None` (and `check_merged_delete`, the same without the timeout fallback).

- [ ] **Step 1: Write the failing tests**

In `tests/git-forge-guard.test.sh`, after the line `expect ask   "--all"                                  "$R" 'git push --all origin'`, insert:

```bash
echo "== rule 4: merged-branch deletes =="
# A remote of its own, so the cases that move it never touch the fixtures above. done and
# done2 are merged into main, here and on the remote; open is not merged; v1 is a tag; gone
# exists only here. The cases that move the remote run last.
git init -q --bare "$REMOTES/del.git"
DEL="$TMP/delwork"
git init -q "$DEL"
git -C "$DEL" commit -q --allow-empty -m init
git -C "$DEL" remote add origin "$REMOTES/del.git"
git -C "$DEL" switch -q -c done;  git -C "$DEL" commit -q --allow-empty -m done
git -C "$DEL" switch -q -c done2; git -C "$DEL" commit -q --allow-empty -m done2
git -C "$DEL" switch -q main;     git -C "$DEL" merge -q --ff-only done2
git -C "$DEL" switch -q -c open;  git -C "$DEL" commit -q --allow-empty -m open
git -C "$DEL" switch -q -c gone main; git -C "$DEL" commit -q --allow-empty -m gone
git -C "$DEL" tag v1 main
git -C "$DEL" switch -q -c work main
git -C "$DEL" push -q origin main done done2 open v1 2>/dev/null
git -C "$DEL" remote set-head origin main
DONE=$(git -C "$DEL" rev-parse done); DONE2=$(git -C "$DEL" rev-parse done2)
OPEN=$(git -C "$DEL" rev-parse open); MAIN=$(git -C "$DEL" rev-parse main)
GONE=$(git -C "$DEL" rev-parse gone)
[ "$(git -C "$DEL" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" = origin/main ] \
  && [ -n "$(git ls-remote "$REMOTES/del.git" refs/heads/done)" ] \
  || { echo "merged-delete fixture setup failed" >&2; exit 1; }

expect allow "a merged delete pinned, by --delete"        "$DEL" "git push --force-with-lease=done:$DONE origin --delete done"
expect allow "a merged delete pinned, by -d"              "$DEL" "git push --force-with-lease=done:$DONE origin -d done"
expect allow "a merged delete pinned, by a :ref refspec"  "$DEL" "git push --force-with-lease=done:$DONE origin :done"
expect allow "a refs/heads/ lease"                        "$DEL" "git push --force-with-lease=refs/heads/done:$DONE origin --delete done"
expect allow "a refs/heads/ destination"                  "$DEL" "git push --force-with-lease=done:$DONE origin --delete refs/heads/done"
expect allow "options after the branch"                   "$DEL" "git push origin --delete done --force-with-lease=done:$DONE"
expect allow "two merged deletes, both pinned"            "$DEL" "git push --force-with-lease=done:$DONE --force-with-lease=done2:$DONE2 origin --delete done done2"
expect deny  "a merged delete with no pin"                "$DEL" 'git push origin --delete done'
has_reason   "the deny names the pinned command" \
             "git push --force-with-lease=done:$DONE origin --delete done" "$DEL" 'git push origin --delete done'
expect deny  "a bare --force-with-lease"                  "$DEL" 'git push --force-with-lease origin --delete done'
expect deny  "a lease without a sha"                      "$DEL" 'git push --force-with-lease=done origin --delete done'
expect deny  "a pin to another sha"                       "$DEL" "git push --force-with-lease=done:$OPEN origin --delete done"
expect deny  "two leases on one branch, one wrong"        "$DEL" "git push --force-with-lease=done:$DONE --force-with-lease=done:$OPEN origin --delete done"
has_reason   "a partly pinned pair: the command pins both" \
             "git push --force-with-lease=done:$DONE --force-with-lease=done2:$DONE2 origin --delete done done2" \
             "$DEL" "git push --force-with-lease=done:$DONE origin --delete done done2"
expect ask   "an unmerged branch, pinned"                 "$DEL" "git push --force-with-lease=open:$OPEN origin --delete open"
expect ask   "a merged and an unmerged branch"            "$DEL" "git push --force-with-lease=done:$DONE --force-with-lease=open:$OPEN origin --delete done open"
expect ask   "the default branch, pinned"                 "$DEL" "git push --force-with-lease=main:$MAIN origin --delete main"
expect ask   "the default branch as refs/heads/main"      "$DEL" "git push --force-with-lease=main:$MAIN origin --delete refs/heads/main"
expect ask   "a tag by name"                              "$DEL" "git push --force-with-lease=v1:$MAIN origin --delete v1"
expect ask   "a tag by ref"                               "$DEL" 'git push origin :refs/tags/v1'
expect ask   "a branch missing on the remote"             "$DEL" "git push --force-with-lease=gone:$GONE origin --delete gone"
expect ask   "--prune beside a pinned delete"             "$DEL" "git push --prune --force-with-lease=done:$DONE origin :done"
expect ask   "--force beside a pinned delete"             "$DEL" "git push --force --force-with-lease=done:$DONE origin --delete done"
expect ask   "a delete mixed with a push"                 "$DEL" "git push --force-with-lease=done:$DONE origin :done work"
DBROKEN=$(cp -R "$DEL" "$TMP/delbroken" && printf '%s' "$TMP/delbroken")
git -C "$DBROKEN" remote set-url origin "$REMOTES/nowhere.git"
expect ask   "a remote that cannot be read"               "$DBROKEN" "git push --force-with-lease=done:$DONE origin --delete done"
cp -R "$REMOTES/del.git" "$REMOTES/delhead.git"
git --git-dir="$REMOTES/delhead.git" symbolic-ref HEAD refs/heads/done2
DHEAD=$(cp -R "$DEL" "$TMP/delhead" && printf '%s' "$TMP/delhead")
git -C "$DHEAD" remote set-url origin "$REMOTES/delhead.git"
expect ask   "the remote's HEAD names another branch"     "$DHEAD" "git push --force-with-lease=done:$DONE origin --delete done"
# A local check that times out after ls-remote has answered asks, as before, rather than
# denying: a git on PATH that hangs on merge-base until the guard's per-call limit (5 s).
SLOWGIT="$TMP/slowgit"; mkdir -p "$SLOWGIT"; REALGIT=$(command -v git)
printf '#!/bin/sh\ncase "$*" in *merge-base*) exec sleep 6 ;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$SLOWGIT/git"
chmod 755 "$SLOWGIT/git"
PATH="$SLOWGIT:$PATH" expect ask "a merge-base that times out" "$DEL" "git push --force-with-lease=done:$DONE origin --delete done"
DPUSH=$(cp -R "$DEL" "$TMP/delpushurl" && printf '%s' "$TMP/delpushurl")
git -C "$DPUSH" config remote.origin.pushurl "$REMOTES/backup.git"
expect deny  "a remote with a separate push URL is still refused" "$DPUSH" "git push --force-with-lease=done:$DONE origin --delete done"

# From here on the remote moves: another clone merges far into main and pushes both.
OTHER="$TMP/delother"
git clone -q "$REMOTES/del.git" "$OTHER" 2>/dev/null
git -C "$OTHER" switch -q -c far
git -C "$OTHER" commit -q --allow-empty -m far
git -C "$OTHER" switch -q main && git -C "$OTHER" merge -q --ff-only far
git -C "$OTHER" push -q origin main far 2>/dev/null
FAR=$(git -C "$OTHER" rev-parse far)
expect ask   "a merged tip this repository lacks"         "$DEL" "git push --force-with-lease=far:$FAR origin --delete far"
git -C "$DEL" fetch -q origin
expect ask   "a tip the local default branch lacks"       "$DEL" "git push --force-with-lease=far:$FAR origin --delete far"
expect allow "after the fetch, done is still merged and pinned" "$DEL" "git push --force-with-lease=done:$DONE origin --delete done"
# done moves on the remote after it was merged: the guard reads the new tip and asks, and
# git itself refuses a delete pinned to the old one. That refusal is what the pin relies on.
git -C "$OTHER" switch -q -c done origin/done
git -C "$OTHER" commit -q --allow-empty -m "moved on"
git -C "$OTHER" push -q origin done 2>/dev/null
MOVED=$(git -C "$OTHER" rev-parse done)
expect ask   "a branch that moved past its merge"         "$DEL" "git push --force-with-lease=done:$DONE origin --delete done"
if git -C "$DEL" push -q --force-with-lease="done:$DONE" origin --delete done 2>/dev/null; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "git refuses a delete pinned to a tip the branch has moved past (it deleted it)"
elif [ "$(git ls-remote "$REMOTES/del.git" refs/heads/done | cut -f1)" = "$MOVED" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "git refuses a delete pinned to a tip the branch has moved past"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "git refuses a delete pinned to a moved tip (the branch changed anyway)"
fi
if git -C "$DEL" push -q --force-with-lease="done2:$DONE2" origin --delete done2 2>/dev/null \
   && [ -z "$(git ls-remote "$REMOTES/del.git" refs/heads/done2)" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "git deletes a branch pinned to its current tip"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "git deletes a branch pinned to its current tip"
fi
```

- [ ] **Step 2: Run the suite to verify the new cases fail**

Run: `./tests/git-forge-guard.test.sh`
Expected: the `allow` and `deny` cases of the new section FAIL (today every one of them asks); the `ask` cases, the separate-push-URL deny, the two real-git cases and every earlier case pass.

- [ ] **Step 3: Implement**

In `dot_claude/git-push-guard.py`, after the `DWIM_PREFIXES = …` line, add:

```python
# A delete-only push of merged branches needs no ask once each delete is pinned to the tip
# the guard read (spec 2026-10-16, section 4). A push carrying one of these flags updates,
# prunes or force-pushes more than the branches it names, so it is never delete-only.
NOT_DELETE_ONLY = {"--prune", "--mirror", "--all", "--force", "-f", "--tags", "--follow-tags"}
SHA_RE = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
```

After `default_branch()`, add:

```python
def delete_targets(flags, refspecs):
    """The branch names a delete-only push deletes, or None when the push also updates,
    prunes or force-pushes something, or deletes a ref that is not a plain branch."""
    if flags & NOT_DELETE_ONLY or not refspecs:
        return None
    deleting = "-d" in flags or "--delete" in flags
    names = []
    for spec in refspecs:
        if deleting:
            dst = spec
        elif spec.startswith(":"):
            dst = spec[1:]
        else:
            return None                                # it pushes something
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/"):]
        if not dst or dst in ("HEAD", "@") or dst in CURRENT_BRANCH \
                or dst.startswith(DWIM_PREFIXES) or dst[0] in "+-:" or ":" in dst:
            return None
        names.append(dst)
    return names


def push_leases(args):
    """(ref, expected sha) for every --force-with-lease=<ref>:<sha> on the push; a bare
    --force-with-lease or one without a sha pins nothing."""
    leases = []
    for a in args:
        if a.startswith("--force-with-lease="):
            ref, colon, sha = a[len("--force-with-lease="):].partition(":")
            if colon:
                leases.append((ref, sha))
    return leases


def merged_delete(repo, remote, default, names, leases):
    """Whether a delete-only push of the branches in names goes without an ask: True when
    every one is merged and pinned; a deny reason naming the pinned command when every one
    is merged but a pin is missing or names another tip; None (an ask, as before) otherwise,
    a failed read of the remote included. A timeout anywhere in these checks asks as well:
    Repo.run raises it as a Deny, which here would turn today's ask into a deny."""
    try:
        return check_merged_delete(repo, remote, default, names, leases)
    except Deny:
        return None


def check_merged_delete(repo, remote, default, names, leases):
    """merged_delete without the timeout fallback.

    Merged: one ls-remote of the remote, whose single push URL is its fetch URL (evaluate
    refuses any other remote before this runs), shows its HEAD on the default branch and
    every branch present; the remote's default tip and every branch tip exist here; and
    each branch tip is an ancestor of both the remote's default tip and refs/heads/<default>,
    so its commits survive in both. Pinned: some --force-with-lease=<branch>:<sha> or
    refs/heads/<branch>:<sha> names the tip just read and no lease on that branch names
    another, so git refuses the delete if the branch moved after this read."""
    heads = ["refs/heads/" + n for n in [default] + names]
    out = repo.run("ls-remote", "--symref", remote, "HEAD", *heads,
                   env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
    if out is None:
        return None
    tips, remote_head = {}, None
    for line in out.splitlines():
        left, tab, ref = line.partition("\t")
        if not tab:
            continue
        if left.startswith("ref: "):
            if ref == "HEAD":
                remote_head = left[len("ref: "):].strip()
        elif ref in heads:
            tips[ref] = left.strip()
    local_default = "refs/heads/" + default
    if remote_head != local_default or not repo.has_ref(local_default):
        return None
    if not all(SHA_RE.fullmatch(tips.get(h, "")) for h in heads):
        return None
    if any(repo.run("cat-file", "-e", tips[h] + "^{commit}") is None for h in heads):
        return None
    for n in names:
        for target in (tips[local_default], local_default):
            if repo.run("merge-base", "--is-ancestor", tips["refs/heads/" + n], target) is None:
                return None

    def pinned(n):
        shas = [sha for ref, sha in leases if ref in (n, "refs/heads/" + n)]
        return bool(shas) and all(sha == tips["refs/heads/" + n] for sha in shas)

    if all(pinned(n) for n in names):
        return True
    pins = " ".join("--force-with-lease={}:{}".format(n, tips["refs/heads/" + n]) for n in names)
    return ("Push guard: {} {} merged into {}, on {} and here. Pin the delete to the tip just "
            "read, so git refuses it if the branch has moved, and it needs no ask: "
            "git push {} {} --delete {}").format(
                ", ".join(names), "is" if len(names) == 1 else "are", default, remote,
                pins, remote, " ".join(names))
```

In `evaluate()`, immediately before the final `if asks:`, add:

```python
    # A delete-only push of merged branches, each pinned to the tip read here, needs no ask;
    # merged but unpinned is a silent deny naming the pinned command. delete_targets admits
    # no flag or refspec that adds any other ask, so the asks it replaces are delete asks.
    targets = delete_targets(flags, refspecs)
    if asks and targets is not None and default not in targets:
        verdict = merged_delete(repo, remote, default, targets, push_leases(args))
        if verdict is True:
            return None
        if verdict:
            raise Deny(verdict)
```

Every earlier check in `evaluate()` (the options, the remote and its URLs, the wildcard and DWIM refspecs, the scan) still runs first and unchanged.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./tests/git-forge-guard.test.sh`
Expected: every case passes, the earlier `":ref refspec"`, `"--delete"` and `"-d"` asks included (their branch `old` does not exist on the remote).

- [ ] **Step 5: Report back.** The controller commits `dot_claude/git-push-guard.py` and `tests/git-forge-guard.test.sh` as "Let the push guard delete merged branches pinned to their tip without asking".
