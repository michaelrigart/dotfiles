# Suite speed: jq without the mise shim, process-replay in parallel, slow suites first

**Status:** In progress (branch `chore/suite-speed`; signed off 2026-11-14)

## Intent

Items 30 and 33 of the 2026-11-11 setup review ("suite speed"), approved by Michael on
2026-11-12: make the default run (`./tests/run.sh`) and the heavy suites `xreview`,
`wt-functions` and `test-audit` faster without losing what they catch. `git-forge-guard` is out:
forge-push-protection's merge 3 deletes most of it. Item 29 (`--changed`, the subject map, the
lock holder record) is merged and stays as it is. Every change below answers a measured cost,
and its effect was measured with a prototype before this spec was written.

## Measured

On fenrir (14 CPUs, so `RUN_JOBS` defaults to 7), sandboxed, under the real runner and its lock,
on 2026-11-14, with the runner unchanged. How each number was taken:

- **Per suite and per case.** `run.sh --run-one` sends each suite's stdout and stderr to
  `$RUN_SH_WORK/<name>.out` as the suite runs, and writes `<name>.rc` when it exits. A poller
  outside the runner (every 0.1 s) timestamps each new line of each `.out` file: a suite starts
  when its file appears and ends when its `.rc` appears, and a case's time is the gap since the
  previous line. This is the suites' own output as they write it, not the runner's report.
- **Inside a wrapper that buffers.** `process-replay` printed `== <module>` before running each
  module and its output after, so a module's time is the gap between headers; `t_inject.py` was
  then profiled alone with `cProfile`. `xreview-replay` prints its in-process block at the end,
  so only its total is used.
- **Inside `xreview`.** A `BASH_ENV` trace of the script under test (timestamp and pid on each
  line) gave the count of each external command it starts.
- **Process start-up.** Ten to twenty calls of each command, timed, outside the runner.

| Run | Before | After (prototype) |
|---|---|---|
| Default, `./tests/run.sh` | 482 s (main `50f0421`, 59 suites, one flaky FAIL) | 242 s (main `f292740`, 60 suites, 10774/10774) |
| Heavy, `./tests/run.sh xreview wt-functions test-audit` | 987 s (`bd6c18c`, 11 suites, 5012/5012) | 550 s (`f292740`, 11 suites, 5024/5024) |
| `xreview` alone in that run | 804 s, serial | 549 s, beside the others |

Process start-up, per call: `bash -c :` 7 ms, `git` 7 ms, `/usr/bin/jq` 5 ms, Homebrew `jq` 6 ms,
`jq` through the agent shell's `PATH` 74-94 ms, `/usr/bin/python3 -I` 34 ms, the same importing
`json` and `subprocess` 75 ms.

### Where the time went

1. **`jq` through an inactive mise shim.** Agent shells put `~/.local/share/mise/shims` before
   Homebrew. mise holds `jq` 1.8.1 for another repository; here it is inactive, so every `jq`
   runs mise, which resolves the whole global toolset (including `rustup show profile` and
   `rustup component list`, twice, for the global `rust` entry's component) before it execs
   Homebrew's `jq` 1.8.2: about 90 ms against 6 ms. The suites pay it twice over:
   - they call `jq` themselves (`xreview-rpc` at 310 sites, `xreview` 161, `xreview-ledger` 85,
     `claude-settings` 42, `worktree-guard` 28, …);
   - they hand the session `PATH` to the scripts they test (`PINNED_PATH="$STUB:$PATH"` in 18
     suites), so a script that pins `PATH=/usr/bin:…` in production reaches the shim under test.
     In the first quarter of the `xreview` suite, the script under test made 2,435 `jq` calls.

   Production hooks do not pay it: every guard and hook script pins `PATH=/usr/bin:…` before its
   first `jq`, and starts under an absolute `/opt/homebrew/bin/bash`. Measured with a tripwire
   `jq` first on the caller's `PATH`: the four Bash guards never called it, and cost 36 ms per
   Bash tool call in all (8-10 ms each).

   With the shim bypassed and nothing else changed (heavy run, 987 → 708 s): `xreview` 804 →
   504 s, `xreview-rpc` 173 → 77 s, `xreview-ledger` 100 → 53 s, `xreview-guard` 150 → 89 s. In
   the default run (prototype, with §2 and §3): `dev` 87 → 22 s, `review` 72 → 33 s, `hook-path`
   45 → 19 s, `worktree-guard` 28 → 4 s, `memory-health` 15 → 4 s.
2. **`process-replay` was the default run's critical path.** 429 s, started 52 s into the run;
   for its last 161 s it ran alone with six slots idle. Its wrapper ran 20 Python modules one
   after another; `t_inject.py` alone takes 202-218 s, as about 22,000 `git` subprocesses at
   7.5 ms inside the package's own code. It is still the critical path after this design
   (240 s, everything else ends by 210 s).
3. **Dispatch order.** `xargs` starts suites in name order, so long suites late in the alphabet
   (`process-replay`, the `xreview-*` suites) started behind short ones.
4. **`xreview-rpc`'s budget rows.** Two rows check that `hooks-status` against a silent daemon
   ends within 5 s, timed with `$SECONDS` (whole seconds): the silent-`initialize` row runs out
   the 5.0 s budget, and 5.1 s of real time reads 5 or 6 depending on where the second boundary
   falls. It failed two of three measured runs (`got: 5//`). The silent-`hooks/list` row ends at
   the 3 s call timeout, so its 5 s bound cannot tell that timeout from the budget.
5. **`xreview` serial.** Its tag cites T4b, a dispatch that must return inside
   `XREVIEW_PANE_WAIT=2`. With the shim gone a dispatch takes about 0.9 s alone and T4b took
   1.21 s beside the other heavy suites: green, but with too little margin for a 2 s bound.
   Serial, `xreview` adds its whole length to every run that includes it.
6. **What is left in `xreview`** is process start-up spread across its 488 script invocations
   (a dispatch still runs `git`, the ledger and packet helpers, and the stubs) and the waits its
   sliced-round cases need. Its sections build on repository state earlier sections leave, so
   it cannot be sharded without a rewrite.
7. **`wt-functions`** (166 s) already pins a non-shim `jq` for itself (`mkjqstub`) and stubs
   `sleep`; each case is a real `wt`/`wt-rm` lifecycle of many short processes. No single cost
   stands out. It runs in the parallel phase, under `xreview`'s or `process-replay`'s length.
8. **`test-audit`** (98 s) spends its time in real harness runs (copies and suite runs); three
   cases wait out a 4-second lock holder, about 8 s in all. It also runs under a longer suite.
9. **Python start-up (item 33).** After §1, the Python-subject suites take 282 suite-seconds in
   the default run (`xreview-guard` 99, `xreview-rpc` 81, `xreview-ledger` 51, `xreview-packet`
   31, `herdr-codex-pane-map` 17, the rest under 3), and all of them end before
   `process-replay` does.

## Goals

1. The default run takes at most 250 s on this machine (measured 242 s; was 482 s).
2. A run that includes all heavy suites takes at most 600 s (measured 550 s; was 987 s).
3. Nothing a suite catches is lost: each suite keeps its assertion labels, and the mutants named
   under Validation are killed.
4. `xreview-rpc`'s budget rows stop flaking.

## Non-goals

- `git-forge-guard`.
- `process_replay`'s own code, and splitting `t_inject.py`: item 37 decides the package's fate
  after the 11-17 reading, and the default run meets its goal without it.
- The machine's mise configuration. The inactive-shim cost is reported, not changed here: the
  shim belongs to another repository's tools and stays.
- Narrowing the lock or changing `RUN_JOBS` (the test-run-queue spec, approach B).
- Item 33's conversion, `wt-functions` and `test-audit` (Approaches, D to F).

## Anti-goals

- A suite made faster by asserting less, or by a seam that lets the subject skip what production
  does.
- A sandbox-measuring suite run differently: nothing below touches the `live-*` suites or how
  the sandbox is entered.
- A runner change that alters a verdict, a count or the report.

## Approaches

**A. Give suites the `jq` the shim falls through to, without the shim (chosen).** The runner
puts a private directory first on the suites' `PATH` that holds only `jq`, linked to the first
`jq` on `PATH` that is not a mise shim: today Homebrew's 1.8.2, the binary the shim ends up
running. The suites run exactly the `jq` they run today, minus about 85 ms a call. One place, no
suite edits; `wt-functions` already does the same for itself.

Tried first and rejected on evidence: linking `/usr/bin/jq` (1.7.1), the binary every
`PATH`-pinned script resolves in production. `claude-settings` failed 427 assertions and
`hook-path` stopped: `dot_claude/modify_private_settings.json` uses syntax only `jq` 1.8 parses,
and `chezmoi apply` runs it with Michael's `PATH`, which reaches Homebrew's `jq`. So the
production `jq` depends on the script (Open questions, 1). Every other suite passed on 1.7.1 in
that run, so no pinned script the suites exercise needs 1.8 today.

Also rejected: drop the mise shims directory from the suites' `PATH` (it also changes the
interpreter behind an unqualified `python3` and hides every mise tool); call a `jq` by path in
each suite or script (hundreds of edits); take the shim out of agent shells' `PATH` (other
repositories' tools need it); remove `jq` from mise (another repository's).

**B. Run `process-replay`'s modules concurrently (chosen).** The modules are separate processes
over separate temporary trees; only `HOME`, `XDG_STATE_HOME` and `CODEX_HOME` were shared.

**C. Start the known-slow suites first (chosen).** A one-line marker, read only for order. In the
prototype it started `process-replay` at 1 s instead of 52 s.

**D. Item 33, the Python-subject suites as in-process tests (not now).** The review's estimate
(about 12k lines of bash calling Python, to about 5k lines under 30 s, labelled inferred) counted
whole suite time as interpreter start-up; measured, most of it was the shim. After A those suites
take 282 suite-seconds and none is on the critical path, so converting them changes the default
run's wall time by 0 s. The cost: rewriting about 8,100 lines of tests, four of them safety
suites (`xreview-guard`, `xreview-ledger`, `xreview-rpc`, `agent-text-scan`). It becomes worth
weighing only if `t_inject.py` is split and the run is bound by total work (1,365 suite-seconds
over 7 slots, 195 s) instead of one suite.

**E. `wt-functions` and `test-audit` (no change).** Neither has a removable waste: no shim, no
real sleep in `wt-functions`, 8 s of lock-holder waits in `test-audit`. Both run beside a longer
suite, so their length moves no run's wall time; only a run of one of them alone would gain, and
sharding either is a rewrite.

**F. Shard `xreview` (not now).** Its sections depend on state earlier sections leave. Running it
beside the others (§5) recovers most of what sharding would.

## Design

### 1. The runner gives suites `jq` without the shim

In the locked runner, before any suite starts: walk `PATH` in order and take the first
executable `jq` that is not a mise shim (a link whose target's name is `mise`); create
`$RUN_SH_WORK/bin/jq` as a symlink to it and prepend `$RUN_SH_WORK/bin` to the `PATH` the suites
inherit. The `--run-one` children inherit it through `xargs`. A suite that builds its own `PATH`
or stubs `jq` is unaffected.

Amended 2026-11-14 on Michael's word (through the driver), so that bypassing mise in the tests
cannot surprise anyone later:

1. Nothing outside the runner's own child processes changes: no mise configuration, no shim, no
   agent-shell or hook `PATH`.
2. The private directory holds only `jq`, linked to the binary the shim resolves to today (the
   first non-shim `jq` on `PATH`), so the suites run the same `jq` as now, minus the lookup.
3. When no non-shim `jq` is found, the runner stops with exit 2 and one line naming what is
   missing, and runs no suite: never a silent fallback. (This replaces "`PATH` is unchanged".)
4. One sentence in `AGENTS.md` (Testing) says what the runner does with `jq` and why (measured
   about 90 ms a call through the shim against 6 ms), so it reads as deliberate; `run.sh --help`
   says the same.

### 2. `process-replay` runs its modules concurrently

`tests/process-replay.test.sh` runs the modules at most four at a time, largest file first (the
slow modules are the largest), each with its own `HOME`, `XDG_STATE_HOME` and `CODEX_HOME` under
its own directory, and the same isolated git configuration. Each module's output is buffered and
printed in name order with its `== <module>` header, as today; the counting, the "exited
without a FAIL line" rule and the exit status are unchanged. Measured: 429 → 240 s.

### 3. Slow suites first

A suite may carry `# test-slow  # <seconds> s on <date>`. The runner dispatches the marked
parallel suites before the unmarked ones, each group in name order. The marker changes nothing
else: not the gate, the serial phase, the report or its order. It goes on the suites over 60 s in
the measured runs after §1: `process-replay`, `xreview-replay`, `herdr-phase`, `run`,
`xreview-guard`, `forge-protection`, `xreview-rpc`, and the heavy `xreview`, `wt-functions` and
`test-audit`.

### 4. `xreview-rpc`'s budget rows time in milliseconds

The two rows read `EPOCHREALTIME` before and after, and each passes when the call ended within
its own bound plus 0.75 s for interpreter start-up: the silent `hooks/list` row within the 3 s
call timeout (`HOOKS_STATUS_CALL`), the silent `initialize` row within the 5 s budget
(`HOOKS_STATUS_BUDGET`). A call that runs past its bound (what the rows catch) still fails: a
call timeout of 6 s, which the 5 s budget caps at about 5 s, fails the first row, and a budget of
6 s fails the second. No product change.

### 5. `xreview` leaves the serial phase

T4b passes its own `XREVIEW_PANE_WAIT=5` to the dispatch it times and compares against that same
5 s, so the bug it catches (a dispatch that waits the bound out when the pane is gone) costs at
least 5 s against the 1.2 s measured under load. The rest of the suite keeps
`XREVIEW_PANE_WAIT=2`. The `# test-serial` tag goes, and `xreview` runs in the parallel phase,
dispatched first (§3).

## Validation

- **Same assertions.** Every suite's assertion labels at the tip equal those at the base, label
  for label, from a default and a heavy run at each, except `run`, which gains only the new rows
  for §1 and §3; §4 and §5 keep their labels.
- **Mutants.** With `.scripts/test-audit/audit.py targeted` at the tip, every mutant killed:
  - `process-replay`: the 16 rows of `.scripts/test-audit/targeted.jsonl` (the concurrency);
  - `xreview-rpc`: its 3 rows (6 mutants), plus `HOOKS_STATUS_BUDGET` 5.0 → 6.0 and
    `HOOKS_STATUS_CALL` 3.0 → 6.0 against the two rows of §4;
  - `xreview`: T4b against a dispatch that waits the bound out when the pane is gone;
  - `run`: its row, plus the new `run.test.sh` rows of §1 and §3 against a runner that links the
    shim, links nothing, or dispatches the marked suites last.
- **No flake.** Three heavy runs green with `xreview` in the parallel phase.
- **Timings.** The default and heavy runs at the tip, against the before column above.

## Constraints

- bash 3.2-compatible runner and wrapper, no new dependency; `tests/run.sh` stays one file.
- `run.sh` is a subject of every heavy suite, so this branch's pre-merge run includes all four.
- The test lock is shared: measurement runs leave gaps for waiting runners and never wrap the
  runner in `lockf`.

## Rulings at sign-off

Signed off 2026-11-14 by the driver session, on Michael's delegation, after Codex approved the
spec (round 2).

1. **A known test-fidelity gap: the `jq` pinned scripts are tested against.** The pinned scripts
   (the guards and hooks, `xreview`) run `/usr/bin/jq` 1.7.1 in production but Homebrew's 1.8.2
   under test, before and after this change. No suite fails on 1.7.1 today. Closing the gap means
   each such suite passes the production `PATH` as its `PINNED_PATH`: 18 suites. Not in this
   line.
2. **Item 33: not now.** Measured gain on the default run's critical path: 0 s (Approaches, D).
3. **`wt-functions` and `test-audit`: no change** (Approaches, E).
4. **The inactive-shim cost outside the suites** (about 90 ms per `jq` in any agent shell in a
   repository where mise's `jq` is inactive, from the global `rust` component's `rustup` calls):
   reported only; the driver takes it to Michael.

## Left to the builder

- Where in `run.sh` the `jq` directory is made, and the wording of the help line.
- The concurrency mechanism in the `process-replay` wrapper, within §2.
