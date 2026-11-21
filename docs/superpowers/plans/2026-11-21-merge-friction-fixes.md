# Merge friction fixes, fix 1: per-suite subject files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: the `plan-run` skill (it overrides
> superpowers:subagent-driven-development). Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (branch `chore/merge-friction-fixes`)

**Goal:** Replace `.scripts/test-audit/subjects.tsv` and `tests/missing-subject.test.sh`'s row list
with one subject file per suite, `tests/subjects/<suite>.tsv`, so two PRs that each add a suite
touch no common line, with every check the readers make today kept.

**Architecture:** A subject file lists what its suite loads, one row per file:
`file<TAB>lang<TAB>role`, role `-`, `own`, `guard` or `own,guard`. `run.sh --changed` reads the
suite's own file (working tree and merge base); `audit.py` merges the directory into the per-file
rows it uses today; `missing-subject` runs a case per `guard` row; `run.test.sh` lints the directory.

**Tech Stack:** bash (runner and suites), Python 3 (`audit.py`), awk.

**Spec:** `docs/superpowers/specs/2026-11-21-merge-friction-fixes-design.md` (signed 2026-11-21,
the three recommended decisions). Fixes 2 and 3 are already committed (`4baad2c`, `5dcac5b`).

## Global Constraints

- Read `tests/AGENTS.md` before editing anything under `tests/`. Execute suites
  (`./tests/x.test.sh`), never `bash tests/x.test.sh`. Run only the suites named in your task, never
  the full suite or `./tests/run.sh` without a filter.
- Public repository: nothing private. No agent attribution anywhere. Do not commit; the controller
  commits.
- No `rm` through a variable; name literal paths. Use `git -C <checkout>` instead of `cd … &&`.
- Keep function names `compute_selection`, `changed_subjects`, `map_check` in `tests/run.sh`:
  `run.test.sh` injects errors after those lines by name.
- `AGENTS.md` stays at or under 240 lines (237 today).
- Never weaken an assertion. A case whose subject no longer exists (a `loaded_by` shape) is
  replaced by the case for the new shape, named in the task.

## The format (every task)

```
tests/subjects/<suite>.tsv     one per suite that loads at least one file; <suite> = tests/<suite>.test.sh
file<TAB>lang<TAB>role         no header; `#` lines and blank lines are skipped by every reader
lang  bash|zsh|sh|py|prose|data|deployed (audit.py's LANGS)
role  -  |  own  |  guard  |  own,guard
```

A file's `loaded_by` is every suite whose file lists it, in suite-name order; its `own_suite` is the
one suite that marks it `own`, else `-`. A file listed by no suite is absent. Rows are sorted by
file (`LC_ALL=C`). Shape rule for `run.sh`: exactly three tab-separated fields, no CR, no whitespace
at either end of a field.

## Review Focus

- No check is lost: compare each changed assertion with the one it replaces (the spec's table).
- `run.sh`: every path that cannot decide still runs the suite, and both suite loops reach the same
  decision for a suite (the decision is computed once per suite per run).
- `audit.py`: the loaded rows equal today's for every file (Task 1's equivalence check).
- Input classes: file names with spaces, quotes and non-ASCII bytes (the `--changed` fixture's
  `lib/has space.sh` and `lib/naïve".sh`); a CR; a missing, empty, unreadable or malformed suite
  file, in the working tree or at the merge base; a base with no `tests/subjects`.

---

### Task 1: Generate the subject files

**Depends on:** nothing

**Files:**
- Create: `tests/subjects/<suite>.tsv` (75 files)
- Scratch only, never committed: the converter and the equivalence check

- [ ] **Step 1: Write a converter** (Python, in the session scratchpad) that reads
  `.scripts/test-audit/subjects.tsv` and the `missing <suite> <path>` rows of
  `tests/missing-subject.test.sh` (expand `"$RELAY/…"` with the `RELAY=` line). For each map row and
  each suite in `loaded_by`, emit `file<TAB>lang<TAB>role` into `tests/subjects/<suite>.tsv`, role
  `own` when the suite is the row's `own_suite`, plus `guard` when a `missing` row names that
  (suite, file). Skip the row for `.scripts/test-audit/subjects.tsv` itself (spec decision 3) and
  the `missing run .scripts/test-audit/subjects.tsv` row (it becomes an explicit case in Task 2).
  Abort if a `missing` row names a pair the map does not have, or an `own_suite` is not in its
  `loaded_by`. Sort each file's rows by file, `LC_ALL=C` byte order; end each file with a newline.

- [ ] **Step 2: Check equivalence.** Load the old map with today's `audit.load_subjects` and the new
  directory with a throwaway merge (per file: the one `lang`, the `own` suite or `-`, the sorted set
  of listing suites). Expect the same 190 files (191 minus the map's own row) with the same `lang`,
  `own_suite` and `loaded_by` set, and 48 `guard` pairs equal to the `missing` rows minus `run`'s.
  Save the old loader's rows as the baseline, `<scratchpad>/subjects-baseline.json` (per file:
  `lang`, `own_suite`, sorted `loaded_by`), before any later task deletes the old map; Task 3
  compares against it. Record the command and its output for the ledger.

- [ ] **Step 3: Check the old suites still pass:** `./tests/run.test.sh` and
  `./tests/missing-subject.test.sh` (nothing reads the new files yet).

### Task 2: `run.sh --changed` reads the suite's file; `run.test.sh` follows

**Depends on:** Task 1

**Files:**
- Modify: `tests/run.sh` (header comment lines 61-74; `map_check`, `map_rows`, `compute_selection`,
  `changed_subjects`, lines 208-285)
- Modify: `tests/run.test.sh` (guard lines 19-20; `--changed` fixture from line 698; drift check
  from line 1005; stale check from line 1120; well-formedness case from line 1155)
- Modify: `tests/missing-subject.test.sh` (only `missing()` and the `run` row)
- Delete: `.scripts/test-audit/subjects.tsv`

- [ ] **Step 1: Port the tests first** (`run.test.sh`), so they fail against today's `run.sh`:
  - Guard: `SUBJECTS="$SRC/tests/subjects"`, `[ -d "$SUBJECTS" ] || { echo "missing subject map
    the drift checks read: $SUBJECTS" >&2; exit 2; }`.
  - Fixture: `SUBJ=tests/subjects` replaces `MAP`. `row <file> <suite>` prints
    `<suite>\t<file>\tsh\t-`, a spec `write_map` files under its suite. `write_map [row]...` empties
    `$R/$SUBJ` and writes `heavya.tsv` (a `# comment` line, a blank line, `lib/a.sh`,
    `lib/has space.sh`), `heavyb.tsv` (`lib/b.sh`, `$NAIVE`), then each row given into its suite's
    file. `drop_row <file>` removes that file's rows from every suite file; `drop_suite <suite>`
    removes the suite's file. Replace every `drop_rows 1 <file>` with `drop_row` and every
    `drop_rows 4 <suite>` with `drop_suite`.
  - The awk stub fails the program of the new `map_files` (detect `{ print $1 }` instead of
    `ENVIRON["SUITE"]`); `STUB_AWK_FILE` stays `map.wt` / `map.base`.
  - A malformed or unreadable suite file now runs that suite only: the cases "a malformed row",
    `malformed()`, "a malformed row at the base", "an unreadable map" and "a base map whose blob
    cannot be read" assert `ok +heavya .*\[needs: heavy; <reason>\]` and `skip +heavyb`, with the
    same reasons as today (`subject map malformed`, `subject map at <sha> malformed`,
    `subject map unreadable`, `subject map at <sha> unreadable`). The blob case edits
    `heavya.tsv` on the branch (`write_map "$(row lib/c.sh heavya)"`) before deleting the base blob.
  - `malformed()` writes `write_map` and then appends one raw line to `heavya.tsv`. Shapes: a
    leading space in the file, a trailing space in the file, a trailing space in another field, a
    CR inside the file name, two fields, four fields (today's format). The four `loaded_by` shapes
    (whitespace inside, empty name, leading comma, trailing comma) have no counterpart: suite
    identity is the file name.
  - "A missing map": `G rm -rq "$SUBJ"`, still `both … 'subject map missing'`. "A base without a
    map": `G rm -rq "$SUBJ"` on main, `write_map` on the branch, still `neither` and no reason.
  - New: "an empty suite file is selected" (`: > "$R/$SUBJ/heavyb.tsv"`, committed) →
    `ok +heavyb .*\[needs: heavy; no subject-map row\]`.
  - New: "a subject file a suite edits mid-run does not change the report": with `lib/a.sh`
    edited, `heavya`'s fixture body appends `lib/a.sh\tsh\t-` to `heavyb.tsv` when it runs; the
    report must still show `skip +heavyb … (no subject changed since …)` and no `left no result`
    line. Today's runner passes it (the maps are read once); a runner that decides twice fails it.
  - `drift_check` reads the heavy suite's rows from `$1/tests/subjects/<suite>.tsv` (first field,
    `#` and blank lines skipped; no file means no rows). Its fixture calls keep their meaning.
  - Replace the stale check with `map_lint <repo root>`, one line per problem: a subject file not
    named after an existing suite; a row whose file is not a regular file; a row without three
    fields; a role other than `-`, `own`, `guard`, `own,guard`; a file listed with two langs; a file
    two suites mark `own`. Fixture cases (a throwaway root, one problem each, with the exact line
    expected) for all six, and a clean fixture that prints nothing; then `map_lint "$SRC"` prints
    nothing ("every subject file is well-formed and consistent").
  - Replace "the runner reads the real subject map as well-formed": in a fresh fixture repository,
    copy every real `tests/subjects/*.tsv`, create a heavy fixture suite `tests/<name>.test.sh` for
    each, commit, run `rr --changed`, and assert no line carries `subject map malformed` or
    `subject map unreadable` and every one of those suites is skipped as unchanged.
  Run `./tests/run.test.sh` against today's `run.sh`: the ported `--changed` cases must fail.

- [ ] **Step 2: Change `run.sh`:**
  - `map_check <file>`: 0 when every row (skipping `#` and blank lines) has exactly three
    tab-separated fields, no CR and no field with whitespace at either end; 1 otherwise; 2 when awk
    cannot read it.
  - `map_files <file>`: the first field of every row, one per line (`awk -F'\t' '/^#/ || $0 == ""
    { next } { print $1 }'`). `map_rows` goes.
  - `compute_selection`: as today up to the merge base, then `[ -d "$repo_root/tests/subjects" ]`
    or `sel_reason="subject map missing"`; keep `sel_short`, and keep the merge base in `sel_base`.
    The working-tree and base map reads move to `changed_subjects`. The changed-file collection is
    unchanged.
  - `changed_subjects <suite>`: computed once per suite per run: the first call writes its return
    status and `why` to `$RUN_SH_WORK/sel.<suite>` and later calls read them back, so the dispatch
    and report loops agree. Order: `sel_reason` set → run with it; no `tests/subjects/<suite>.tsv`
    → `no subject-map row`; copy to `$RUN_SH_WORK/map.wt` (failure → `subject map unreadable`);
    `map_check` (1 → `subject map malformed`, other non-zero → `subject map unreadable`);
    `map_files` (failure → `subject map unreadable`; empty → `no subject-map row`); `git ls-tree
    "$sel_base" -- tests/subjects/<suite>.tsv` (failure → `git failed`); when it names the file,
    `git show` it to `$RUN_SH_WORK/map.base` (failure → `subject map at <short> unreadable`),
    `map_check` (1 → `subject map at <short> malformed`, else → `… unreadable`), `map_files`
    (failure → `… unreadable`); then the hit search exactly as today.
  - Header comment (lines 61-74): say a suite's subjects are the files of
    `tests/subjects/<suite>.tsv` in the working tree or at the merge base, and that a missing
    directory runs every heavy suite while a missing, empty, unreadable or malformed suite file
    runs that suite.

- [ ] **Step 3: `missing-subject.test.sh`:** `missing()` accepts a directory (`[ -e ]` for the
  hidden path); the `run` row becomes `missing run tests/subjects`. Delete
  `.scripts/test-audit/subjects.tsv`.

- [ ] **Step 4: Verify:** `./tests/run.test.sh`, `./tests/missing-subject.test.sh`; then revert-check
  three cases by hand and record the result: let `map_check` accept two fields; drop the lang
  comparison from `map_lint`; skip the per-suite decision file so the report loop decides again
  (the mid-run case must fail).

### Task 3: `audit.py` reads the directory; the `test-audit` fixture follows

**Depends on:** Task 1, Task 2 (`test-audit.test.sh` copies `tests/run.sh` into its fixture)

**Files:**
- Modify: `.scripts/test-audit/audit.py` (`load_subjects`, lines 425-440; the default in `main`,
  line 1453; a `ROLES` constant beside `LANGS`)
- Modify: `tests/test-audit.test.sh` (lines 46, 768-772, 869, 930)
- Delete: `tests/fixtures/test-audit/subjects.tsv`
- Create: `tests/fixtures/test-audit/subjects/{s,s2,pins,gated}.tsv`
- Modify: `tests/subjects/test-audit.tsv` (the fixture file rows)

- [ ] **Step 1: Tests first.** The fixture directory holds `s.tsv` (`bin/s.sh bash own`), `s2.tsv`
  (`bin/p.py py own`, `bin/s.sh bash -`), `pins.tsv` (`docs/rules.md prose own`), `gated.tsv`
  (`docs/gated.md prose own`); `bin/loop.sh` is in none (spec: a file appears only through a suite
  that lists it). `aud` and `audb` pass `--subjects "$T/repo/subjects"`. Line 869 writes
  `bin/res.sh bash own` into `res-a.tsv` and `bin/res.sh bash -` into `res-b.tsv`. Q4's synthetic map
  becomes the directory `$T/subj` (`s.tsv`: `bin/s.sh bash own`; `s2.tsv`: `bin/s.sh bash -`,
  `bin/esc.py py -`; `gated.tsv`: `bin/loop.sh bash own`; `red.tsv`: `bin/p.py py own`), and Q4
  gains `has "| bin/esc.py | - | - | 0 |" "Q4: a file no suite owns keeps its dash row" "$OUT"`.
  New refusal cases (each `rc_is 2` and `has` on the message): two suite files giving one file two
  langs, two suite files both marking it `own`, a role outside the four, a row without three
  fields, and an explicit `--subjects` naming a directory that does not exist.
  In `tests/subjects/test-audit.tsv`, replace the `tests/fixtures/test-audit/subjects.tsv` row with
  one `data -` row per new fixture file.

- [ ] **Step 2: `load_subjects(path, explicit)`** reads `path` as a directory: missing and explicit →
  `die(f"missing subjects directory: {path}")`, missing and not explicit → `[]`. For each `*.tsv` in
  name order (suite = file stem), each row not blank and not `#`: three columns, `lang` in `LANGS`,
  `role` in `ROLES`, else `die(f"{sub}:{n}: want file, lang, role")`; a second `lang` for a file →
  `die(f"{sub}:{n}: {file} is {lang} here and {other} in another subject file")`; a second `own` →
  `die(f"{sub}:{n}: {file} is owned by {owner} and {suite}")`. Return the rows today's callers use,
  `{"file", "lang", "own_suite", "loaded_by"}`, sorted by file, `own_suite` `-` when none,
  `loaded_by` in suite-name order. The default becomes `Path(args.repo) / "tests" / "subjects"`.

- [ ] **Step 3: Verify:** `./tests/test-audit.test.sh` (about 100 s); compare the new
  `load_subjects` on the real `tests/subjects` with Task 1's baseline after exactly these changes to
  the baseline: drop `.scripts/test-audit/subjects.tsv` and `tests/fixtures/test-audit/subjects.tsv`;
  add `tests/fixtures/test-audit/subjects/{gated,pins,s,s2}.tsv`, each `data`, `own_suite` `-`,
  `loaded_by` `[test-audit]`. Expect 193 files, all equal. Revert-check one refusal case.

### Task 4: `missing-subject` runs a case per `guard` row

**Depends on:** Task 1, Task 2

**Files:**
- Modify: `tests/missing-subject.test.sh` (the `missing` rows, lines 62-112)

- [ ] **Step 1:** Replace the literal rows (all but the `run` directory case from Task 2) with a loop
  over `$COPY/tests/subjects/*.tsv` in name order: for each row whose role contains `guard`, run
  `missing <suite> <file>` (suite = file stem; read with `IFS=$'\t' read -r file lang role`, skipping
  `#` and blank lines; file names may contain spaces). If the loop finds no `guard` row, print
  `missing file under test: guard rows in tests/subjects` on stderr and exit 2. Keep the
  `codex-config` missing-tool case and the `run` directory case. Update the header comment: each
  case comes from a `guard` role.

- [ ] **Step 2: Verify:** `./tests/missing-subject.test.sh` runs 50 cases (48 guard rows, `run`'s
  directory, `codex-config`'s tool), all passing; revert check: drop `guard` from one row, see its
  case disappear and the count fall to 49, restore; and blank all roles, see exit 2.

### Task 5: Documentation

**Depends on:** Task 2, Task 3, Task 4

**Files:**
- Modify: `AGENTS.md` (line 169, the heavy row: "its rows in `.scripts/test-audit/subjects.tsv`" →
  "its file in `tests/subjects/`"; line 181: a new or moved file a suite loads gets a row in that
  suite's `tests/subjects/<suite>.tsv` in the same commit). No net new lines.
- Modify: `tests/AGENTS.md` ("A new suite": the format section above in prose, what `-`, `own` and
  `guard` mean, that a file no suite loads is absent, and that `missing-subject` hides every `guard`
  row's file; keep the `t-missing-subject` pin's terms "exits 2 if not" and "Exit 2, never 1").

- [ ] **Step 1:** Edit both; `./tests/agent-instructions.test.sh` passes (the AGENTS.md cap and the
  pins).
