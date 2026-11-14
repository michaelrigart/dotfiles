# Suite speed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (branch `chore/suite-speed`)

**Goal:** Cut the default run from 482 s to at most 250 s and a run with every heavy suite from
987 s to at most 600 s, with every suite asserting what it asserted before.

**Architecture:** The runner links the non-shim `jq` first on the suites' `PATH` and dispatches
suites marked `# test-slow` first; the `process-replay` wrapper runs its modules four at a time;
two timing rows become exact enough that `xreview-rpc` stops flaking and `xreview` can leave the
serial phase.

**Tech Stack:** bash 3.2-compatible shell (`tests/run.sh`, the `process-replay` wrapper), bash 5
suites, `.scripts/test-audit/audit.py` for mutants.

**Spec:** `docs/superpowers/specs/2026-11-14-suite-speed-design.md` (signed off 2026-11-14).

## Global Constraints

- `tests/run.sh` stays one bash 3.2-compatible file with no new dependency; check every edit with
  `/bin/bash -n tests/run.sh`.
- No verdict, count or report line of `run.sh` changes; `--changed`, the subject map, the lock
  and the holder record stay as they are.
- No suite asserts less. No product file changes (`dot_*`, `.scripts/` stay untouched).
- The `live-*` suites are not touched.
- Repository is public: no machine-private paths or names in committed text beyond what the
  repository already holds.
- Run suites only through `./tests/run.sh <exact-name>`; never wrap it in `lockf`; never prefix an
  interpreter. Leave a few minutes between long runs: other lines share the test lock.
- The runner prints only failing output. To keep a suite's full output, run it through the
  poller: `python3 .superpowers/suite-speed/profile.py <checkout> <outdir> <suite>...` drives the
  real `./tests/run.sh` (and its lock) and writes `<outdir>/<suite>.lines` (seconds, gap, line)
  and `<outdir>/summary.tsv`. Its `<outdir>` goes under `.superpowers/suite-speed/`.
- `.scripts/test-audit/audit.py` measures `main` unless told otherwise: every `try` and `targeted`
  call here passes `--ref HEAD` (global options go before the subcommand), on a committed tree.
- Commit messages: imperative mood, no agent attribution.

## Review Focus

1. A `PATH` entry that is empty, relative, or holds a directory named `jq`: the runner must skip it
   and never link a directory (Task 1, row J4).
2. A machine where the only `jq` on `PATH` is the mise shim: the runner exits 2 with one line and
   runs no suite (Task 1, row J3).
3. A suite that is both `# test-slow` and `# test-serial`, or `# test-slow` and gated: serial and
   the gate win; the marker only orders the parallel phase (Task 2, rows S3-S4).
4. A `process-replay` module that exits non-zero without a FAIL line, or never writes its result
   file: it still counts as one failure (Task 3, step 4).
5. The `xreview-rpc` budget rows on a bash without `EPOCHREALTIME`: the row must fail loudly, not
   pass (Task 4, step 3).

---

### Task 1: The runner gives suites `jq` without the shim (spec §1)

**Depends on:** none

**Files:**
- Modify: `tests/run.sh` (after `RUN_SH_WORK` is created and its traps are set, before
  `compute_selection`; help block lines 2-65)
- Modify: `tests/run.test.sh` (a new section after the serial-tag section)
- Modify: `AGENTS.md` (Testing, the paragraph that starts "Suites run in parallel")

**Interfaces:**
- Produces: the locked runner exports `PATH="$RUN_SH_WORK/bin:$PATH"` when, and only when, it
  linked `$RUN_SH_WORK/bin/jq`.

- [ ] **Step 1: Write the failing rows in `run.test.sh`**

Fixtures under `$T/jq/`: `mise` (an executable printing `shim`), `shims/jq` (a symlink to
`../mise`), `shims2/jq` (another symlink to `../mise`), `real/jq` (an executable that answers
`--version` with `jq-1.8.2` and otherwise prints `real`), `old/jq` (answers `--version` with
`jq-1.7.1-apple`), `odd/jq` (answers `--version` with `garbage`),
`dirjq/jq/` (a directory). A fixture suite `jqprobe.test.sh` writes what `jq` prints to
`$MARK/jq.says` and its `PATH` to `$MARK/jq.path`, then prints `  ok  probed` (the runner prints
only a passing suite's report line, so the rows read the files, not the output).
A helper `narrow` builds `$T/jq/tools/` holding symlinks to every tool the copied runner and the
fixture suite call (`bash`, `env`, `lockf`, `mktemp`, `rm`, `mkdir`, `ln`, `readlink`, `dirname`,
`basename`, `sed`, `grep`, `head`, `awk`, `xargs`, `getconf`, `cat`, `date`, `mv`, `id`, `sort`,
`tr`, `wc`; add any the run shows missing), and no `jq`. Rows, each running the copied runner on
`jqprobe` alone:
  - J1 `PATH=$T/jq/shims:$T/jq/real:<narrowed>`: `jq.says` is `real`.
  - J2 `PATH=$T/jq/shims:$T/jq/shims2:$T/jq/real:<narrowed>`: `real` (a second shim is skipped
    too).
  - J3 `PATH=$T/jq/shims:<narrowed>` (no non-shim `jq`): the runner exits 2, prints one line on
    stderr naming the missing `jq` (it contains `jq`), and runs no suite (`jq.says` is absent).
  - J6 under J1, the directory first on the suite's `PATH` (from `jq.path`) holds exactly one
    entry, `jq`, and it resolves to `$T/jq/real/jq`.
  - J7 `PATH=$T/jq/shims:$T/jq/old:<narrowed>`: the runner exits 2, prints one line on stderr
    naming `1.7.1` and `1.8.1`, and runs no suite; with `$T/jq/odd` instead of `old`, the same
    exit and a line naming `garbage` and `1.8.1`. `PATH=$T/jq/shims:$T/jq/real:<narrowed>` with a
    `real/jq` answering `jq-1.8.1` runs (the floor itself passes), and one answering `jq-1.10.0`
    runs (versions compare as numbers, not text).
  - J4 `PATH=:relative-dir:$T/jq/dirjq:$T/jq/shims:$T/jq/real:<narrowed>`: `real`, and the
    runner's stderr is empty.
  - J5 the runner's report line and closing totals under J1 equal those of the same fixture run
    with `real/jq` alone on the narrowed `PATH` (no shim): the link changes nothing in the report.

- [ ] **Step 2: Run the rows; J1, J2 and J4 fail**

Run: `./tests/run.sh run`
Expected: FAIL on J1, J2, J4 (`jq.says` is `shim`), J3 and J7 (the runner does not stop) and J6.

- [ ] **Step 3: Implement the link in `tests/run.sh`**

Walk `PATH` split on `:`; skip an empty or non-absolute entry, a non-executable `jq`, a
directory named `jq`, and a `jq` whose `readlink` target's last component is `mise`; take the
first other one. Link it as `$RUN_SH_WORK/bin/jq` and prepend `$RUN_SH_WORK/bin`; with none,
print one line on stderr naming what is missing (`run.sh: no jq on PATH other than a mise shim;
the suites need one`) and exit 2 before any suite runs. Read the chosen one's `--version`
(`jq-<major>.<minor>[.<patch>][-suffix]`); when it is older than 1.8.1 (compared as numbers) or
does not parse, print one line naming the version found and `1.8.1`, and exit 2 the same way. Restore `IFS` after the split. Add one
help line under the runner's comment block: suites get the first `jq` on `PATH` that is not a
mise shim, because an inactive mise shim
costs about 90 ms a call. Add the same as one sentence to `AGENTS.md` (Testing).

- [ ] **Step 4: Run the rows; all pass**

Run: `/bin/bash -n tests/run.sh && ./tests/run.sh run`
Expected: `ok    run  N/N` with J1-J6 passing.

- [ ] **Step 4b: Check the change stays inside the runner**

Run: `git diff --name-only <base>` (the commit before this task).
Expected: only `tests/run.sh`, `tests/run.test.sh`, `AGENTS.md`: no mise configuration, shim,
shell start-up file, hook or settings file. The `AGENTS.md` sentence gives the measured cost
(about 90 ms a call through the shim against 6 ms).

- [ ] **Step 5: Commit**

`git add tests/run.sh tests/run.test.sh AGENTS.md && git commit -m "Give suites jq without the mise shim"`

---

### Task 2: Slow suites first (spec §3)

**Depends on:** Task 1 (same files)

**Files:**
- Modify: `tests/run.sh` (the dispatch group, today lines 336-347; help block)
- Modify: `tests/run.test.sh`
- Modify: `AGENTS.md` (Testing, the same paragraph)
- Modify: the second line of `tests/{process-replay,xreview-replay,herdr-phase,run,xreview-guard,forge-protection,xreview-rpc,xreview,wt-functions,test-audit}.test.sh`

**Interfaces:**
- Consumes: Task 1's runner.
- Produces: `# test-slow` (at the start of a line, optionally followed by whitespace and a
  comment) marks a suite for early dispatch.

- [ ] **Step 1: Write the failing rows in `run.test.sh`**

Assemble the tag at runtime (`slowtag="# test-slow"`), as the file already does for
`# test-requires`, so no literal line in `run.test.sh` matches by accident; Step 4 adds the one
literal marker line `run.test.sh` itself gets. Fixtures: `aa-first.test.sh` (unmarked),
`zz-late.test.sh` (marked), `zz-serial-slow.test.sh` (marked and `# test-serial`),
`zz-gated-slow.test.sh` (marked and behind a requirement tag). Each appends its name to
`$MARK/order` when it starts. Rows:
  - S1 with `RUN_JOBS=1`, filtered to `aa-first zz-late`: `zz-late` starts before `aa-first`.
  - S2 the report lists `aa-first` before `zz-late` (name order, as today).
  - S3 filtered to `aa-first zz-late zz-serial-slow`: `zz-serial-slow` starts after both
    parallel suites (serial wins over the marker).
  - S4 `zz-gated-slow` is skipped with its `needs:` line (the gate wins).
  - S5 a marker with a trailing comment (`# test-slow  # 99 s`) counts; `# test-slowish` does not.

- [ ] **Step 2: Run; S1 and S5 fail**

Run: `./tests/run.sh run`
Expected: FAIL on S1 and S5's first half; S2-S4 pass.

- [ ] **Step 3: Implement in `tests/run.sh`**

In the dispatch loop, a non-serial suite whose file matches `^# test-slow([[:space:]]|$)` goes to
a `slow` array, the rest to `parallel`; feed `slow` then `parallel` to the one `xargs -P "$jobs"`.
Guard both arrays against bash 3.2's unbound empty-array expansion under `set -u`. The serial
phase and the report loop are unchanged. Help block and `AGENTS.md`: one sentence each (the marker
orders dispatch only).

- [ ] **Step 4: Mark the slow suites**

Insert as line 2 of each file listed above `# test-slow  # <s> s on 2026-11-14`, with these
measured seconds: `process-replay` 240, `xreview-replay` 176, `herdr-phase` 133, `run` 110,
`xreview-guard` 99, `forge-protection` 96, `xreview-rpc` 81, `xreview` 549, `wt-functions` 166,
`test-audit` 98.

- [ ] **Step 5: Run; all pass**

Run: `/bin/bash -n tests/run.sh && ./tests/run.sh run`
Expected: `ok    run  N/N`.

- [ ] **Step 6: Commit**

`git add -A tests AGENTS.md && git commit -m "Dispatch the suites marked test-slow first"`

---

### Task 3: `process-replay` runs its modules concurrently (spec §2)

**Depends on:** none

**Files:**
- Modify: `tests/process-replay.test.sh`

- [ ] **Step 1: Record the baseline output**

Run: `python3 .superpowers/suite-speed/profile.py "$PWD" .superpowers/suite-speed/pr-before process-replay`
Expected: its `runner.out` shows `ok    process-replay  N/N`; keep N and `pr-before/process-replay.lines`.

- [ ] **Step 2: Implement**

Run the `t_*.py` modules through `xargs -0 -n1 -P 4` in `ls -S` order (largest first), each as
`/usr/bin/python3 -I -B <module>` with `HOME`, `XDG_STATE_HOME` and `CODEX_HOME` set to
`$ROOT/m.<module>/{home,state,codex}` (created first), output to `$ROOT/out/<module>.out`, exit
status to `$ROOT/out/<module>.rc`. Then the existing loop, in name order, prints `== <module>` and
that module's output, counts PASS and FAIL lines, and counts a module whose `.rc` is missing or
non-zero without a FAIL line as one failure (`rc` read as 70 when the file is missing). The
shared `GIT_CONFIG_*` exports and `T_ROOT` stay.

- [ ] **Step 3: Verify the same output**

Run: `python3 .superpowers/suite-speed/profile.py "$PWD" .superpowers/suite-speed/pr-after process-replay`
Expected: `ok    process-replay  N/N` with the same N, and
`diff <(cut -f3- .superpowers/suite-speed/pr-before/process-replay.lines | grep -E '^(==|  PASS|  FAIL)') <(cut -f3- .superpowers/suite-speed/pr-after/process-replay.lines | grep -E '^(==|  PASS|  FAIL)')`
prints nothing.

- [ ] **Step 4: Verify the failure rules (not committed)**

Add a throwaway `tests/process-replay/t_zz_probe.py` that prints `  PASS: probe` and exits 3, and
run `./tests/run.sh process-replay`: expected FAIL with
`FAIL: t_zz_probe.py exited 3 without a FAIL line`. Change the probe to kill itself with signal 9
before printing: expected the same FAIL line with a non-zero status. Delete the probe;
`git status --short` shows nothing under `tests/process-replay/`.

- [ ] **Step 5: Commit**

`git add tests/process-replay.test.sh && git commit -m "Run process-replay's modules four at a time"`

---

### Task 4: `xreview-rpc`'s budget rows time in milliseconds (spec §4)

**Depends on:** none

**Files:**
- Modify: `tests/xreview-rpc.test.sh` (the two rows after `scenario '{"silent":["hooks/list"]}'`)

- [ ] **Step 1: Implement**

A helper `in_budget <t0> <bound>` prints `in-budget` when `EPOCHREALTIME - t0 <= bound`, else
`took <s>s` (two decimals), computed with `awk`. Each row takes `t0=$EPOCHREALTIME` before the
call. Bounds: the silent `hooks/list` row 3.75 (the 3 s call timeout plus 0.75), the silent
`initialize` row 5.75 (the 5 s budget plus 0.75). Labels and the other fields of both rows are
unchanged.

- [ ] **Step 2: Run**

Run: `./tests/run.sh xreview-rpc`
Expected: `ok    xreview-rpc  N/N`, N unchanged.

- [ ] **Step 3: Kill the bound mutants**

Commit first. Run each with
`.scripts/test-audit/audit.py --ref HEAD try <file> <find> <replace> xreview-rpc` (it builds its
own copy and takes the lock):
  - `dot_local/bin/executable_xreview-rpc`, `HOOKS_STATUS_BUDGET = 5.0` → `HOOKS_STATUS_BUDGET = 6.0`: verdict `killed`.
  - `dot_local/bin/executable_xreview-rpc`, `HOOKS_STATUS_CALL = 3.0` → `HOOKS_STATUS_CALL = 6.0`: verdict `killed`.
Also confirm a bash without `EPOCHREALTIME` fails the row rather than passing: run the helper
under `/bin/bash` (3.2) with `set -u` in a one-off shell; expected an unbound-variable error.

- [ ] **Step 4: Commit**

`git add tests/xreview-rpc.test.sh && git commit -m "Time xreview-rpc's budget rows in milliseconds, each against its own bound"`

---

### Task 5: `xreview` leaves the serial phase (spec §5)

**Depends on:** Task 2 (the `# test-slow` line sits beside the tag removed here)

**Files:**
- Modify: `tests/xreview.test.sh` (line 17, the `# test-serial` tag; the T4b case)
- Modify: `AGENTS.md` (Testing: "(today only `xreview`)")

- [ ] **Step 1: Implement**

In T4b, run the dispatch with `XREVIEW_PANE_WAIT=5` in its own environment and compare `took`
against 5 (not the suite's `XREVIEW_PANE_WAIT=2`); the label stays. Delete the `# test-serial`
line. `AGENTS.md`: the serial sentence no longer names `xreview` (no suite carries the tag today;
the mechanism stays).

- [ ] **Step 2: Kill the T4b mutant**

Commit first. Run: `.scripts/test-audit/audit.py --ref HEAD try dot_local/bin/executable_xreview '      pane_gone "$pane" && { warn_pane_unwatched "$pane"; return 1; }' '      false && { warn_pane_unwatched "$pane"; return 1; }' xreview`.
Expected: verdict `killed`, by `T4b it returns quickly, not waiting out XREVIEW_PANE_WAIT`. (If
the find string is not unique, widen it with the line before; `try` refuses anything but exactly
one match.)

- [ ] **Step 3: Run**

Run: `./tests/run.sh xreview wt-functions test-audit`
Expected: all 11 suites ok; `xreview` runs in the parallel phase (it starts with the others).

- [ ] **Step 4: Commit**

`git add tests/xreview.test.sh AGENTS.md && git commit -m "Run xreview beside the other suites; give T4b its own pane wait"`

---

### Task 6: Validation and records (spec, Validation)

**Depends on:** Tasks 1-5

**Files:**
- Modify: `docs/superpowers/specs/2026-11-14-suite-speed-design.md` (an "Implementation notes"
  section)
- Modify: the `# test-requires: heavy` comments of `xreview`, `wt-functions`, `test-audit`
  (timings), and the heavy row of `AGENTS.md` (Testing table) with the measured seconds
- Untracked: `.superpowers/suite-speed/` (manifests, states, captured outputs)

- [ ] **Step 1: Labels at base and tip**

At the merge base (`git switch --detach $(git merge-base origin/main HEAD)` in this checkout, with
nothing uncommitted; switch back after) and at the tip, run `./tests/run.sh` and
`./tests/run.sh xreview wt-functions test-audit`, each through the poller
(`profile.py … base-default`, `… base-heavy xreview wt-functions test-audit`, and `tip-…` the
same). Compare each suite's PASS/FAIL label sequence at base and tip (`cut -f3-` of the `.lines`
files, filtered to `^\s*(ok|PASS|FAIL|not ok)`). Expected: identical for every suite except
`run`, whose tip sequence is its base sequence plus exactly the rows J1-J5 and S1-S5 added by
Tasks 1 and 2; any other difference (a label lost, changed or added) is a finding. The four
timings go into Step 4.

- [ ] **Step 2: Targeted mutants**

Write `.superpowers/suite-speed/targeted.jsonl` with the `process-replay` (16), `xreview-rpc`
(3) and `run` (1, `run:156-157`) rows of `.scripts/test-audit/targeted.jsonl`, and run
`.scripts/test-audit/audit.py --ref HEAD --state .superpowers/suite-speed/state targeted .superpowers/suite-speed/targeted.jsonl`
at the tip, then `audit.py --state .superpowers/suite-speed/state report --section targeted`.
Expected: every mutant `killed`. The `try` results of Tasks 4 and 5 and the J/S rows'
mutants complete the list: for each J and S row, a `try` on `tests/run.sh` that removes the link
block, drops the shim check, or swaps `slow` and `parallel` in the dispatch: each `killed` by
`run`.

- [ ] **Step 3: Three heavy runs**

Run `./tests/run.sh xreview wt-functions test-audit` three times in all (Step 1's tip run counts),
with gaps. Expected: all green each time.

- [ ] **Step 4: Record**

Write "Implementation notes" in the spec: the before/after table (default and heavy, from Step 1),
the label comparison, every mutant with its verdict, the three heavy runs; update the heavy tags'
timing comments and the `AGENTS.md` heavy row with the tip's seconds. Set the spec's and this
plan's status for pre-merge.

- [ ] **Step 5: Commit**

`git add docs tests AGENTS.md && git commit -m "Record the suite-speed validation"`

- [ ] **Step 6: The pre-merge run on the final tree**

Run: `./tests/run.sh --changed` on the committed tree of Step 5. `tests/run.sh` changed, so it
runs all four heavy suites, `git-forge-guard` included.
Expected: every suite ok; each heavy suite's line carries `[needs: heavy; changed: …]`. Quote the
heavy lines and the totals in the final report.
