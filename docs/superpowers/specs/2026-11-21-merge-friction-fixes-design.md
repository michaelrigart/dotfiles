# Merge friction fixes: a test registry that parallel PRs do not collide in

**Status:** Implemented (branch `chore/merge-friction-fixes`, its PR against `main`)
**Date:** 2026-11-21
**Branch:** `chore/merge-friction-fixes`, in the `wt` checkout
`~/.local/share/chezmoi-chore-merge-friction-fixes`
**Sign-off:** Michael, 2026-11-21, in the line's own pane, with the three recommended decisions
under Decisions for Michael. Codex approved the spec in round 2 (xr-1795291754-89a9de48).
**Source:** the driver's brief of 2026-11-21 (three fixes for friction seen that day, in one line,
as Michael asked). This spec covers fix 1, the only one that is not a small change; fixes 2 and 3
ride in the same line and are summarised at the end.
**Size:** about 90 lines of non-test code (`tests/run.sh` `--changed` selection about 50,
`.scripts/test-audit/audit.py` loader about 40), about 250 lines of test code
(`tests/run.test.sh`'s `--changed` fixture and map checks, `tests/missing-subject.test.sh`,
`tests/test-audit.test.sh`), and a mechanical data move of the 191 map rows and 48 of the 49
guard rows into 75 per-suite files. One increment.
**Real size:** 141 lines of non-test code (`tests/run.sh` 99, `audit.py` 42), 1.57 times the
estimate: the plan added the once-per-run decision and a review round its header and lint fixes.
`change-facts` counts 255, of which 201 are the deleted old map (data). Michael kept it as one
increment on 2026-11-21, in the line's own pane. After the rebase on #40 and #44 the data move is
191 rows and 51 guard rows in 77 files.

## Why

Two files are a shared registry that almost every PR edits:

- `.scripts/test-audit/subjects.tsv`, one row per file: `file, lang, own_suite, loaded_by`. A new
  suite that reads an existing file appends its name to that file's `loaded_by`, so two PRs that
  add suites reading `.chezmoiignore` edit the same line, a certain conflict. New files insert rows
  at their sorted place, so two PRs adding neighbouring files collide too (#40 and #43 both
  inserted a `Library/LaunchAgents/be.netronix.*` row after the same line).
- `tests/missing-subject.test.sh`, one `missing <suite> <path>` row per guarded file, in one list.

On 2026-11-21, #40 needed a rebase and a fresh Codex round for a `subjects.tsv` conflict, and #42
and #43 overlapped in both files. 40 commits touched the map and 24 the guard list since
2026-10-15.

## Design

**One subject file per suite.** `tests/subjects/<suite>.tsv` lists what that suite loads, one row
per file, three tab-separated columns:

```
file	lang	role
dot_local/bin/executable_merge-state	py	own,guard
dot_local/bin/executable_change-facts	py	guard
```

- `file`: repository-relative path; `lang`: as today (`bash|zsh|sh|py|prose|data|deployed`).
- `role`: `-`, or a comma list of `own` (this suite is the file's `own_suite`) and `guard` (the
  suite exits 2 when the file is missing, which `missing-subject` proves by hiding it).
- A file's `loaded_by` is the set of suites whose subject file lists it; its `own_suite` is the one
  suite that marks it `own`, or `-` when none does (which still means "never mutate", as today).
- A new suite adds one new file; a suite reading an existing file lists it in its own file. Two PRs
  collide only when both add rows at the same sorted place in the same existing suite's file.
- A file appears only through a suite that lists it, as the real map already requires ("Files no
  suite loads are absent"). The one loader-free row anywhere, `bin/loop.sh bash - -` in the
  `test-audit` fixture map, is dropped: `audit.py mutants bin/loop.sh` infers `bash` from its
  shebang, as for any unmapped file, and the plan's never-mutate path for a file no suite owns
  keeps its own case, a row with role `-` in Q4's synthetic map, asserted in the plan's output.

The directory sits under `tests/`, not `.scripts/test-audit/`, because `test-audit.test.sh` names
`$SRC/.scripts/test-audit` whole, so `run.test.sh`'s drift check would demand a `test-audit` row for
every subject file and bring the shared list back. Like `tests/`, it never reaches `$HOME`.

**Guards move into the subject files.** All 49 `missing` rows today name a file their suite already
lists in `loaded_by`, so a guard is a role on a row the suite has anyway. `missing-subject.test.sh`
reads every `guard` row instead of its list and runs the same hide-and-run case for each; its other
cases (the copy, the 20 s bound, the verdict, the missing-tool case for `codex-config`) are unchanged.
Rows name files only, and the stale check keeps requiring a regular file. `run.test.sh`'s guard on
`tests/subjects` itself is therefore not a row: it stays an explicit case in
`missing-subject.test.sh`, beside the missing-tool case, and `missing()` accepts a directory for it.

**Readers.**

- `tests/run.sh --changed`: a heavy suite's subjects are the files of `tests/subjects/<suite>.tsv`
  in the working tree and at the merge base, plus its own file and `tests/run.sh`, as today. The
  per-suite file replaces the `loaded_by` scan.
- `.scripts/test-audit/audit.py`: `load_subjects` reads the directory and builds the same per-file
  rows it builds today (`file, lang, own_suite, loaded_by`, suites in name order), so nothing after
  the loader changes. `--subjects` names a directory.
- `tests/run.test.sh`: the drift check reads the heavy suite's file; the stale check walks the
  directory.

**Every check stays.**

| Today | After |
|---|---|
| `run.sh`: a missing, unreadable or malformed map, in the working tree or at the merge base, runs every heavy suite | a missing `tests/subjects` runs every heavy suite; a suite file that is unreadable or malformed (three fields, no CR, no whitespace at a field's ends) runs that suite, with the same reasons |
| `run.sh`: a heavy suite with no row runs, "no subject-map row" | the same when the suite has no file or an empty one |
| `run.test.sh`: drift check (every path a heavy suite names has a row; no row names a missing file) | unchanged, on the suite's file |
| `run.test.sh`: every row names an existing file and existing suites | every file is named after an existing suite, every row names an existing file |
| one `lang` and one `own_suite` per file, by construction | `run.test.sh`: every file has one `lang` across the suite files and at most one `own`; every `role` is valid. `audit.py`'s loader refuses the same |
| `audit.py`: four columns, a known `lang` | three columns, a known `lang`, a valid `role` |
| `missing-subject`: 49 rows | the same 48 file cases, read from `guard` roles, and `run`'s guard on the map as an explicit case |
| the fixture map's loader-free `bin/loop.sh` row reaches the plan's never-mutate path | an ownerless row in Q4's synthetic map reaches it, asserted |

The old global fallback for a malformed map existed because an unparsable row could not be tied to
a suite; a malformed suite file belongs to exactly one suite, so it runs that suite.

**What changes beyond layout.** The map no longer lists itself. Today its row
(`loaded_by run,test-audit`) makes every PR that adds a row run `test-audit` (about 100 s) under
`--changed`, but `test-audit.test.sh` reads only its fixture map, never the real one; a change to the
format comes with a change to `audit.py`, which is `test-audit`'s subject. The fixture map moves to
`tests/fixtures/test-audit/subjects/`, listed in `test-audit`'s file as today.

## Alternatives weighed

- **One file, one row per (suite, file), grouped by suite.** Same reader cost; still collides when
  two new suites sort next to each other, or two PRs add files to the same suite's block.
- **`merge=union` in `.gitattributes`.** GitHub's merge ignores merge drivers, and a union of two
  edits of one row keeps both rows.
- **Guards as `# test-guard: <path>` lines in each suite's header.** Also collision-free and close
  to the guard code, but a second registry beside the subject file; the role keeps "a guarded file
  is a loaded file" true by construction.
- **Only the guard move.** Small, test-only, but leaves the map's shared rows.

## Decisions for Michael

1. Per-suite subject files in `tests/subjects/` (recommended), or keep `subjects.tsv` and move only
   the guards (the cheaper half: about 60 lines of test code, the map conflicts stay).
2. Guards as a `guard` role in the subject files (recommended) or as suite header lines.
3. A map edit no longer selects `test-audit` under `--changed` (recommended; see above).

## Sequencing

#40 is open and adds three map rows and three guard rows. This PR merges after #40 and is rebased
on it: its rows go into the new files. If #40 merges later instead, it moves its own rows.

## Testing

- Revert check per moved check: each row of the table above fails when its rule is broken
  (`run.test.sh`'s existing `--changed` fixture cases, ported to suite files; new cases for a
  disagreeing `lang`, two owners and a bad `role`; `missing-subject` dropping a `guard` row's case).
- The data move is checked by comparing `audit.py`'s loaded rows before and after: the same file,
  `lang`, `own_suite` and `loaded_by` set for all 191 files, and the same 48 file guard pairs,
  plus `run`'s directory case.
- `./tests/run.sh --changed` on the final commit (runs `test-audit` through `audit.py`).

## Fixes 2 and 3 (small, same line)

2. **`test-audit` flakes under load.** The two failing runs on `chore/remove-hercules-ci-runner`
   both show `audit.py` exiting 2 between two suite runs of one session (G1 after its baseline,
   M9 midway through a sample), with the reason hidden: `rc_is` prints `${ERR: -900}`, which bash
   expands to nothing when the error is shorter than 900 characters. The cause: `build_copy` piped
   `git archive` into `tar -x`; tar stops reading two records past the end-of-archive marker, and
   when it outran git (under load), git's padding write met a closed pipe and git exited 141
   silently, so the harness died with "cannot archive". Fixed in `4baad2c`: the archive goes
   through a temporary file, Q30 reproduces the late padding with a stub git, and `rc_is` prints
   the error's tail.
3. **A stack's driver outlives the stack.** One sentence in the `wt-line` skill under Increments
   and stacking, pinned in `tests/fixtures/agent-instructions/rules.tsv`.
