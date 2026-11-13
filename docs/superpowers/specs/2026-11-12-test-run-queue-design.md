# Test-run queue: heavy suites by changed subject, and a lock that reports

**Status:** Approved

## Intent

Sessions queue for long stretches behind the per-machine test-run lock. Measured on 2026-11-12,
with about ten dotfiles lines open: a pre-merge heavy run
(`./tests/run.sh xreview git-forge-guard wt-functions`, about 17 minutes of work) waited more than
30 minutes without starting, for a branch that added one TOML file under `dot_config/`. The
waiting runner printed one line and then nothing.

Two rules produce the queue:

- `AGENTS.md` (Testing) requires all three heavy suites before every pre-merge review, whatever
  the branch touches (workflow-tuning spec, implementation note 8).
- `tests/run.sh` takes one `lockf` lock per machine for every invocation, so each of those runs
  holds the machine for its full length.

This is item 29 of the 2026-11-11 setup review ("`run.sh --changed`, heavy suites run only when
their subject changed"), which Michael approved.

## Why the current rules exist

- **The lock** (workflow-tuning spec §11, commit 7c14663) is a mechanism, not caution: a
  `# test-serial` suite must never share the machine with another runner, and a heavy suite must
  not overlap another branch's full run. `xreview` T4b asserts a dispatch returns within 2 s; run
  beside the `xreview-*` suites it took 2.35 s. Six default suites assert on timing and passed
  under three times CPU oversubscription, the only evidence that default suites tolerate
  overlap.
- **All heavy suites before every pre-merge review** (commit de09950, note 8) replaced "when its
  subject changed", because a subject described in prose was vague enough to let a change to
  `git-push-guard.py` merge with no heavy run. The fix then was to list the loaded files in each
  heavy tag and keep the stricter rule anyway. The list is a comment nothing reads, and it is
  already incomplete: `wt-functions` names only `dot_config/zsh/functions`, while the test
  audit's subject map records five more files it loads.

So the selection may go back to "when its subject changed" only if the subject is read by the
runner from a checked map, and fails safe.

## Goals

1. A branch that touches no heavy suite's subject runs no heavy suite before its pre-merge
   review, and the runner decides that, not the agent.
2. The selection fails safe: anything the runner cannot read or decide runs the suite.
3. A runner that waits says who holds the lock and since when, keeps saying so, and can be told
   not to wait.

## Non-goals

- Narrowing the lock so parallel suites of different runners overlap (Approaches, B).
- Selecting default (non-heavy) suites by changed files. The default run stays whole.
- Making the heavy suites faster (setup-review items 30 and 33, a separate line).
- Changing the requirement gate, the serial phase, `passed/total` or `INCONSISTENT` reporting.

## Anti-goals

- A heavy suite silently skipped when its subject did change.
- A selection an agent can satisfy by reading a comment and judging for itself.
- A waiting or refused runner whose exit status or output can be read as a pass.

## Approaches

**A. Select heavy suites from the branch diff (chosen).** Removes most heavy runs, which are
where the lock time goes: the default run is about 3 minutes, the heavy run about 17. The
concurrency guarantees are untouched.

**B. Narrow the lock: slots for parallel suites, exclusive only for the serial phase (not now).**
`lockf` has no shared mode, so this needs K slot files, with the serial phase taking all K in
order. It adds a second way for suites of different checkouts to overlap, and the only evidence
that they tolerate it is one oversubscription run of six suites. Its gain after A is small: a
heavy `xreview` run still needs the machine alone for 11 minutes, and what would overlap is
3-minute default runs. Revisit with numbers: C makes every runner report how long it waited.

**C. A lock that reports, and can refuse to wait (chosen).** Does not shorten the queue; makes it
visible and lets a session choose focused suites instead of sitting.

A alone leaves the silent wait; C alone leaves the 17-minute holds. Both are in.

## Design

### 1. The subject map

The map is `.scripts/test-audit/subjects.tsv`, which the test audit (`chore/test-audit`) adds:
tab-separated `file, lang, own_suite, loaded_by`, where `loaded_by` is a comma list of every suite
that sources, executes, renders, copies or greps the file. It becomes a live file the runner
reads, no longer a snapshot for the audit. Its header drops "at 523a95d" and says the runner
reads it.

This branch is rebased onto main once `chore/test-audit` has merged, before anything reads the
real map. The lock that reports and the `--changed` selection are built and tested on fixtures
only, so they may be built before that merge (amended 2026-11-13, with Michael's approval); the
drift check, the map's header, the heavy tags and `AGENTS.md` wait for the rebase.

A suite's **subjects** are:

- every `file` whose `loaded_by` lists the suite;
- the suite's own file, `tests/<name>.test.sh`;
- `tests/run.sh`.

The heavy tags' "loads …" comments are removed (one source for the rule); the tag keeps its
timing.

**The map is pinned against drift** by a new check in `tests/run.test.sh`, run on the real
repository, not fixtures: for each suite tagged `heavy`, every repository path the suite file
names (a literal `dot_…`, `.scripts/…`, `.chezmoi…` or `tests/…` path that exists in the tree,
after expanding the suite's `$SRC`-style root) has a map row listing that suite; and every `file`
in a row listing a heavy suite exists. A heavy suite with no row at all fails the check. The
check names the missing pair. It is a floor, not a proof: a file reached only through a computed
path is not seen, and is the map author's to list.

### 2. `--changed [<base>]`

```
./tests/run.sh --changed          # default suites, plus each heavy suite whose subject changed against main
./tests/run.sh --changed=<ref>    # the same against another base
```

`--changed` lifts the `heavy` gate, and only that gate, for each heavy suite with a changed
subject. Everything else is as without it: default suites all run, other requirement gates stay,
filters still narrow by name, an exact name or `--all` still lifts a gate regardless of the diff.

**Changed files** are, with `B = git merge-base <base> HEAD`:

- `git diff --name-only --no-renames -z B` (commits, the index and the working tree; both sides
  of a rename);
- plus untracked, unignored files (`git ls-files --others --exclude-standard -z`).

Both lists are read NUL-delimited, so git never quotes or escapes a name, and a name is compared
with the map's `file` field byte for byte.

**A file selects a suite** when it is one of the suite's subjects under the map at `HEAD`'s
working tree *or* under the map at `B` (`git show B:<map>`). Reading both means removing a row on
the branch cannot unselect its suite, and editing the map does not by itself select everything.
When `B` has no map (the branch that introduces it), only the working-tree map is read.

**Fail safe.** Each of these selects the heavy suite, with the reason printed:

| Condition | Selects |
|---|---|
| not a git work tree, `<base>` does not resolve, no merge base, or any git command fails | every heavy suite |
| the working-tree map is missing, unreadable, or has a malformed row (not four tab-separated fields) | every heavy suite |
| the map at `B` exists but cannot be read, or has a malformed row (the same validation) | every heavy suite |
| the suite has no row in the working-tree map | that suite |

Nothing else is inferred. `HEAD` equal to `B` with a clean tree selects no heavy suite: nothing
changed.

**Reporting.** A heavy suite left out prints
`  skip  xreview   needs: heavy (no subject changed since <B, short>)`, and counts as skipped. One
that runs carries `[needs: heavy; changed: <first changed subject>(, +N more)]`, or
`[needs: heavy; <fail-safe reason>]`. The closing lines are unchanged. A pre-merge report quotes
these lines, so the reader sees which heavy suites ran and why the others did not.

Outside `--changed`, behaviour is byte-identical to today.

### 3. The pre-merge rule

`AGENTS.md` (Testing) changes from "all three before every pre-merge review" to:

- before every pre-merge review, run `./tests/run.sh --changed`: the default suites plus each
  heavy suite whose subject the branch changed, decided by the runner from the subject map;
- a new or moved file a suite loads gets its row in the same commit, and the drift check fails
  until it does;
- an exact name or `--all` still runs a heavy suite whatever the diff.

The heavy-suite table row, the invocation block, the lock paragraph and the suite-tag paragraph
are updated to match. No other instruction file states the rule (`global.md` does not).

Accepted residual: a heavy suite can break with no repository change (a tool upgrade). The old
rule caught that at the next pre-merge of any branch; the new one catches it at the next branch
that touches the subject. A heavy run by exact name after `brew upgrade` covers it, and
`AGENTS.md` says so.

### 4. A lock that reports

- **Holder record.** On taking the lock, the runner writes `<lock>.holder`: one line with its
  start time (epoch), its checkout (`RUN_SH_START_DIR`) and its arguments, written to a temporary
  file and renamed. It removes the record on exit. The record is advisory: only a runner that
  found the lock held reads it, and a missing, stale or unparsable record degrades to today's
  message. It holds no environment and nothing but those three fields.
- **Waiting.** A runner that finds the lock held prints, on stderr,
  `run.sh: waiting for the test-run lock <lock>, held for 14 min by 'run.sh xreview' in <checkout>`,
  and prints it again each minute while it waits, with the then-current holder. It waits with
  `lockf -k -t 60` in a loop instead of one unbounded `lockf`; exit 75 means still held, any
  other failure to take the lock is an error (exit 2), never a wait.
- **After waiting,** the runner prints `run.sh: waited 9 min for the test-run lock` before its
  report. That line is the measurement approach B would need.
- **Not waiting.** `RUN_SH_LOCK_WAIT=<seconds>` bounds the wait; `0` does not wait. When the
  bound passes the runner prints the same holder line with "giving up after N s", runs no suite,
  prints no totals, and exits 75. Unset, it waits without bound, as today. A value that is not a
  non-negative integer is an error (exit 2).
- A nested runner (`RUN_SH_LOCKED=1`) and `--run-one` neither lock nor write a record, as today.

### 5. Tests (`tests/run.test.sh`, fixture runner and fixture git repository)

Each names its behaviour and the bug it catches, and fails with its fix reverted.

Selection:
- a changed subject selects its heavy suite; an unrelated change does not (the suite is listed
  as skipped with the reason);
- a change to the suite's own file, and to `run.sh`, selects it;
- an uncommitted change, a staged change and an untracked file each select;
- a rename away from a subject path selects;
- a changed subject whose name git would quote (a non-ASCII character, a double quote) selects;
- a malformed row in the map at `B` selects every heavy suite, even when the working-tree map is
  valid;
- a row removed on the branch still selects (map at `B`);
- a map edit that does not concern the suite does not select it;
- each fail-safe row of the table selects, and prints its reason: no git repository, unresolvable
  base, missing map, malformed row, suite without a row;
- `--changed` does not lift a non-heavy gate; an exact name still runs a heavy suite with no
  changed subject; without `--changed` the output equals today's on the same fixtures;
- the drift check: passes on the real map; on a fixture, fails naming a loaded file with no row,
  a row whose file is gone, and a heavy suite with no row.

Lock:
- a waiter names the holder's checkout, arguments and age; it repeats the line while waiting
  (interval shortened through a test seam, `RUN_SH_LOCK_POLL`);
- a missing or garbage holder record still waits and still runs;
- `RUN_SH_LOCK_WAIT=0` against a held lock exits 75, runs no suite, prints no totals line;
- a bounded wait that the holder outlasts exits 75; one the holder releases in time runs;
- an invalid `RUN_SH_LOCK_WAIT` exits 2;
- the record is removed after a run, and a runner that waited prints how long;
- the existing lock cases (waits, nested runner, unopenable lock file) stay green unchanged.

## Constraints

- bash 3.2 and the tools already used (`lockf`, `git`, `awk`, `sed`); no new dependency.
- `tests/run.sh` stays one file; the map parser lives in it.
- `AGENTS.md` and the heavy-suite table change on this branch, with the code.
- This branch changes `tests/run.sh`, a subject of every heavy suite, so its own pre-merge run
  includes all three.

## Left to the builder

- Function layout inside `run.sh`, the exact wording of messages beyond the fields named here,
  and the holder record's field separator.
- How the drift check extracts paths from a suite file, provided the three fixture failures
  above are caught.

## Implementation notes

(none yet)
