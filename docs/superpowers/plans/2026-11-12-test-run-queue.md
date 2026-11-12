# Test-run queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress

**Goal:** `tests/run.sh --changed` runs a heavy suite only when its subject changed on the branch, and a runner waiting on the per-machine lock says who holds it and can refuse to wait.

**Architecture:** Everything lives in `tests/run.sh` (bash 3.2). The lock block stops `exec`ing one unbounded `lockf` and instead loops over `lockf -k -t <poll>`, reading a holder record the locked runner writes. `--changed` computes the changed files once (NUL-delimited git output), reads the subject map at the working tree and at the merge-base, and feeds one decision per heavy suite into the existing `select_suite` gate. `tests/run.test.sh` pins both on fixtures, and pins the real map against drift.

**Tech Stack:** bash 3.2, macOS `lockf`, `git`, `awk`, `sed`. No new dependency.

**Spec:** `docs/superpowers/specs/2026-11-12-test-run-queue-design.md`. Read it first; this plan does not restate its tables.

## Global Constraints

- bash 3.2 and the tools already used (`lockf`, `git`, `awk`, `sed`); no new dependency.
- `tests/run.sh` stays one file; the map parser lives in it.
- Without `--changed` and with a free lock, the runner's output is byte-identical to today's.
- `passed/total`, `INCONSISTENT`, the requirement gate and the serial phase do not change.
- The locked runner never exits 75; 75 from `lockf` always means "still held".
- Each test names its behaviour and the bug it catches, and is shown to fail with its fix reverted (revert, watch it fail, restore) before the task's commit.
- Execute suites, never prefix an interpreter: `./tests/run.test.sh`.
- Fixture git repositories follow the pattern the existing suites use (`GIT_CONFIG_GLOBAL=/dev/null`, `-c commit.gpgsign=false`, under `$T`).
- No comments beyond what the surrounding code's style carries; no agent attribution in commits.
- All tasks run in this checkout (`~/.local/share/chezmoi-chore-test-run-queue`), in order. They share `tests/run.sh` and `tests/run.test.sh`, so there is no parallel batch.

## Review Focus

1. `--changed` started from a subdirectory or from `tests/`: git must run against the repository root (`git -C "$repo_root"`), not the start directory. Test in Task 3.
2. A map with comment lines, blank lines, and a `file` containing a space: comments and blanks are not malformed rows; the space-named file selects. Test in Task 3.
3. `--changed` with a name filter that excludes every heavy suite: no heavy suite is listed, selected, or given a fail-safe line. Test in Task 3.
4. Holder arguments or checkout containing a tab or newline: the waiter's line stays one line and the wait still ends in a run. Test in Task 2.
5. The lock directory missing when a waiter looks for the record, and a record left by a killed runner while the lock is free: no waiting line, the run starts. Test in Task 2.

---

### Task 1: Rebase onto the merged test audit

**Depends on:** `chore/test-audit` merged into `main` (Michael's merge). Do not start before it.

**Files:** none changed.

- [ ] **Step 1:** `git fetch origin main` then check `git -C ~/.local/share/chezmoi log --oneline -1 main` contains the audit merge; `git cat-file -e main:.scripts/test-audit/subjects.tsv` must succeed. If it fails, stop and report: the map is not on main.
- [ ] **Step 2:** `git rebase main` in this checkout. The branch holds only the spec and this plan, so no conflict is expected; a conflict stops the task.
- [ ] **Step 3:** `./tests/run.sh run` → `ok    run` with every assertion passing. Record `passed/total` as the baseline.
- [ ] **Step 4:** Re-read `tests/run.sh`'s lock block and `select_suite`, and `tests/run.test.sh`'s fixtures, as merged. If the audit moved a line this plan cites, the later tasks follow the merged code, not the line numbers.

### Task 2: A lock that reports

**Depends on:** Task 1.

**Files:**
- Modify: `tests/run.sh` (the lock block, lines 62-69 before the rebase; the header comment's lock paragraph)
- Test: `tests/run.test.sh` (the "Locking" section)

**Interfaces:**
- Produces: environment `RUN_SH_LOCK_WAIT` (non-negative integer seconds; unset = unbounded), `RUN_SH_LOCK_POLL` (test seam, seconds between waiting lines, default 60), `RUN_SH_LOCK_WAITED` (set by the outer runner for the locked one: whole seconds waited, `0` when it did not wait). Holder record `<lock>.holder`: one line, `<epoch>\t<checkout>\t<arguments joined by one space>`, tabs and newlines inside a field replaced by a space.
- Messages (stderr), exact shapes the tests match:
  - `run.sh: waiting for the test-run lock <lock>, held for <N> min by 'run.sh <args>' in <checkout>`
  - without a usable record: `run.sh: waiting for the test-run lock <lock>, held by another run` (today's line)
  - `run.sh: waited <N> min for the test-run lock` (minutes rounded down; `<S> s` under a minute)
  - `run.sh: giving up after <S> s: ` followed by the same holder clause; exit 75
  - `run.sh: RUN_SH_LOCK_WAIT must be a non-negative integer`; exit 2

- [ ] **Step 1: Write the failing tests** in the Locking section, reusing `hold`. `hold` gains an optional second argument: a holder-record line it writes to `$L.holder` once it has the lock.

  | Test label | Setup | Assertion |
  |---|---|---|
  | a waiter names the holder | `hold 30 "$(printf '%s\tCHK/x\txreview wt' "$(( $(date +%s) - 840 ))")"` | output matches `held for 14 min by 'run.sh xreview wt' in CHK/x` |
  | a waiter repeats the line while it waits | `RUN_SH_LOCK_POLL=1`, `hold 30` with a record | the waiting line occurs at least twice |
  | a missing holder record still waits and runs | `hold 30`, no record | `held by another run`, then `ok +lockheld` |
  | a garbage holder record still waits and runs | record `not a record` | same two |
  | a record with a tab and a newline in a field prints one line | record built with those bytes | exactly the count of waiting lines expected for the wait; `ok +lockheld` |
  | RUN_SH_LOCK_WAIT=0 against a held lock exits 75 | `hold 600`, release after | `rc=75`; no `ok +`, no `suites run`; `giving up after 0 s` |
  | a bounded wait the holder outlasts exits 75 | `RUN_SH_LOCK_WAIT=2 RUN_SH_LOCK_POLL=1`, `hold 600` | `rc=75`, no `suites run` |
  | a bounded wait the holder releases in time runs | `RUN_SH_LOCK_WAIT=30 RUN_SH_LOCK_POLL=1`, `hold 20` | `ok +lockheld`, `rc=0` |
  | an invalid RUN_SH_LOCK_WAIT exits 2 | `RUN_SH_LOCK_WAIT=soon`, and `-1` | `rc=2`, the message, no suite run |
  | a runner that waited says how long | `hold 20` | `waited [0-9]+ s for the test-run lock` |
  | a runner that did not wait says nothing | free lock | no `waited`, no `waiting` |
  | the holder record is removed after a run | free lock, run `plain` | `[ ! -e "$L.holder" ]` |
  | a running runner's record names its checkout and arguments | fixture suite `holderseen` cats `$RUN_SH_LOCK.holder` into `$MARK` | field 2 equals the start directory, field 3 equals `holderseen` |
  | a stale record with a free lock prints no waiting line | write `$L.holder`, no holder | no `wait`, `ok +plain-alpha` |
  | a missing lock directory is created and the run starts | `RUN_SH_LOCK="$T/newdir/lock"` | `ok +plain-alpha`, no `wait` |

  The existing lock cases stay as they are. This suite itself runs under a locked runner, so
  every case that must take the lock starts the fixture runner with
  `env -u RUN_SH_LOCKED -u RUN_SH_LOCK_WAITED`, as the existing ones do with `RUN_SH_LOCKED`.
- [ ] **Step 2:** `./tests/run.test.sh` → the new cases FAIL, the old ones pass.
- [ ] **Step 3: Implement.** Replace the `exec lockf` block: validate `RUN_SH_LOCK_WAIT`; loop `RUN_SH_LOCKED=1 RUN_SH_LOCK_WAITED=<secs> lockf -k -t <min(poll, remaining)> "$lock" "$self" "$@"`; on 75 print the waiting line (re-reading the record each time) and continue, or give up when the bound has passed; any other status is the run's own and is the exit status. With `RUN_SH_LOCK_WAIT=0` the first attempt uses `-t 0`. A `lockf` that cannot open the lock file is an error, exit 2, never a wait (keep the existing "unopenable lock file" case green). The outer runner forwards INT and TERM to the inner one and exits 130. The locked runner (the branch that today only exports `RUN_SH_LOCKED=1`) writes the record when `RUN_SH_LOCK_WAITED` is set, via a temporary file and `mv`, removes it in its existing EXIT trap, and prints the `waited` line when the value is above 0. A nested runner and `--run-one` do neither. Update the header comment's lock paragraph.
- [ ] **Step 4:** `./tests/run.test.sh` → all pass. Then revert the fix without the stash (`git diff tests/run.sh > "$TMPDIR/t2.patch"`, then `git checkout tests/run.sh`), confirm the new cases fail, and `git apply "$TMPDIR/t2.patch"`.
- [ ] **Step 5: Commit:** `Report the test-run lock's holder and bound the wait`.

### Task 3: `--changed` selects heavy suites from the branch diff

**Depends on:** Task 2.

**Files:**
- Modify: `tests/run.sh` (option parsing, `select_suite`, the report loop's `skip` and `note` lines, the header comment)
- Test: `tests/run.test.sh` (new section "Changed-subject selection")

**Interfaces:**
- Produces: options `--changed` (base `main`) and `--changed=<ref>`; `--changed=` with an empty ref is `unknown option`, exit 2. Map path, relative to the repository root: `.scripts/test-audit/subjects.tsv`.
- `select_suite` keeps its contract (returns 0 run, 1 filtered out, 2 gated) and additionally sets `why`: empty, or the text printed for a heavy suite under `--changed`.
- Report lines, exact shapes:
  - `  skip  <name>  needs: heavy (no subject changed since <short sha of B>)`
  - run note: `  [needs: heavy; changed: <first changed subject>]`, with `, +<N> more` when several
  - run note on fail-safe: `  [needs: heavy; <reason>]`, reason one of `not a git work tree`, `base <ref> does not resolve`, `no merge base with <ref>`, `git failed`, `subject map missing`, `subject map unreadable`, `subject map malformed`, `subject map at <short sha> unreadable`, `subject map at <short sha> malformed`, `no subject-map row`

- [ ] **Step 1: Build the fixture.** A git repository `$T/repo` with `tests/run.sh` (the copy), `.scripts/test-audit/subjects.tsv`, and under `tests/`: `heavya.test.sh` and `heavyb.test.sh` (tag `heavy`, assembled at runtime like the other tags), `gatedlive2.test.sh` (tag `a live herdr`), `plainc.test.sh`; subject files `lib/a.sh`, `lib/b.sh`, `lib/has space.sh`, `lib/naïve".sh`. Map rows: `lib/a.sh`→`heavya`; `lib/b.sh`→`heavyb`; `lib/has space.sh`→`heavya`; the quoted-name file→`heavyb`; plus a comment line and a blank line. One commit on `main`, then `git switch -c work`. A helper `reset_repo` returns the fixture to that state between cases. It uses its own `RUN_SH_LOCK`.
- [ ] **Step 2: Write the failing tests.** Each runs `"$T/repo/tests/run.sh" --changed` unless stated.

  | Test label | Change on `work` | Assertion |
  |---|---|---|
  | a changed subject selects its heavy suite | commit an edit to `lib/a.sh` | `ok +heavya .*\[needs: heavy; changed: lib/a.sh\]` |
  | an unrelated change selects none | commit a new `README` | `skip +heavya +needs: heavy \(no subject changed since [0-9a-f]+\)`, same for `heavyb`; `ok +plainc` |
  | the other heavy suite stays skipped | edit `lib/a.sh` | `skip +heavyb` |
  | the suite's own file is a subject | edit `tests/heavya.test.sh` (keep it passing) | `ok +heavya` |
  | run.sh is a subject of every heavy suite | append a comment to `tests/run.sh` | `ok +heavya` and `ok +heavyb` |
  | an unstaged change selects | edit `lib/a.sh`, no add | `ok +heavya` |
  | a staged change selects | edit and `git add` | `ok +heavya` |
  | an untracked file selects | map row for `lib/new.sh`→`heavya` committed on `main` first; create the file | `ok +heavya` |
  | an ignored untracked file does not | same row, file ignored by `.gitignore` | `skip +heavya` |
  | a rename away from a subject selects | `git mv lib/a.sh lib/z.sh`, commit | `ok +heavya` |
  | a name git would quote selects | edit the `naïve".sh` file | `ok +heavyb` |
  | a name with a space selects | edit `lib/has space.sh` | `ok +heavya` |
  | several changed subjects are counted | edit `lib/a.sh` and `lib/has space.sh` | `changed: lib/a.sh, \+1 more` |
  | a row removed on the branch still selects | delete the `lib/a.sh` row and edit `lib/a.sh` | `ok +heavya` |
  | a map edit about another suite does not select | add a row `lib/c.sh`→`plainc` only | `skip +heavya`, `skip +heavyb` |
  | not a git work tree selects all | copy the tree without `.git` | both run, `\[needs: heavy; not a git work tree\]` |
  | an unresolvable base selects all | `--changed=nosuchref` | both run, `base nosuchref does not resolve` |
  | no merge base selects all | `--changed=orphan`, an orphan branch | both run, `no merge base with orphan` |
  | a missing map selects all | `git rm` the map, commit | both run, `subject map missing` |
  | a malformed row selects all | append a three-field row | both run, `subject map malformed` |
  | a malformed row at the base selects all | malformed row committed on `main`, removed on `work` | both run, `subject map at [0-9a-f]+ malformed` |
  | a suite without a row is selected | delete every `heavyb` row on `main` and `work` | `ok +heavyb .*no subject-map row`; `heavya` skipped |
  | comment and blank lines are not malformed | (the base fixture) | covered by "an unrelated change selects none" |
  | HEAD equal to the base, clean tree, selects none | on `main` | both skipped |
  | `--changed` does not lift another gate | edit `lib/a.sh` | `skip +gatedlive2` |
  | an exact name still runs a heavy suite | no change; `--changed heavyb` | `ok +heavyb` |
  | `--all` still runs every heavy suite | no change; `--changed --all` | both `ok` |
  | a filter that excludes heavy suites lists none | `--changed plainc` | no `heavy` in the output |
  | started from a subdirectory | `cd "$T/repo/lib"`, edit `lib/a.sh` | `ok +heavya` |
  | a skipped heavy suite counts as skipped | unrelated change | the totals line says `2 skipped` plus the live-gated one: `3 skipped` |
  | without `--changed` nothing changes | capture `run.sh` output on the fixture before Step 4 into `$T/before.out`; compare after | identical |
  | `--changed=` is refused | — | `rc=2`, `unknown option` |

- [ ] **Step 3:** `./tests/run.test.sh` → the new cases FAIL (`unknown option: --changed`).
- [ ] **Step 4: Implement.** Parse the option. When set, compute once, before the suite loop: the base commit `B` (`git -C "$repo_root" rev-parse --verify -q "<ref>^{commit}"`, then `merge-base`), the changed files (`git diff --name-only --no-renames -z "$B"` plus `git ls-files --others --exclude-standard -z`, both from the repository root, into a NUL-safe store such as a temporary file read back with `read -r -d ''`), and the two maps (working tree file; `git show "$B:<map>"`, where "absent at `B`" is told apart from "unreadable" with `git cat-file -e`). A row is valid when it has exactly four tab-separated fields; lines starting with `#` and empty lines are skipped. Any global failure sets one fail-safe reason that applies to every heavy suite. In `select_suite`, for a suite whose `req` is exactly `heavy` and that is neither named nor under `--all`: with a global reason, or no working-tree row, return 0 with `why` set; otherwise match each changed file against the suite's subjects (rows of either map listing the suite in `loaded_by`, split on commas, compared as whole names; `tests/<name>.test.sh`; `tests/run.sh`) and return 0 with `why` or 2 with the skip text. The report loop prints `why` in the skip line and the `[needs: …]` note. Update the header comment's usage lines and the `heavy` paragraph.
- [ ] **Step 5:** `./tests/run.test.sh` → all pass; revert-and-restore check as in Task 2.
- [ ] **Step 6: Commit:** `Select heavy suites by changed subject with --changed`.

### Task 4: The subject map goes live

**Depends on:** Task 3.

**Files:**
- Modify: `.scripts/test-audit/subjects.tsv` (header; rows the check exposes)
- Modify: `tests/xreview.test.sh`, `tests/git-forge-guard.test.sh`, `tests/wt-functions.test.sh` (the `# test-requires: heavy` line only)
- Test: `tests/run.test.sh` (new section "Subject-map drift")
- Possibly: whatever pins those lines. `rg -n 'subjects.tsv|523a95d|loads dot_' tests .scripts docs/superpowers/plans/2026-11-11-test-audit*.md` first; a test or rule file that pins the old header or tag text is updated in this task, a completed plan or findings document is not touched.

**Interfaces:**
- Produces in `tests/run.test.sh`: `drift_check <repo root>` prints one line per problem and returns non-zero when any: `<suite>: <path> is loaded but has no subject-map row`, `<suite>: subject-map row for <path> names a missing file`, `<suite>: no subject-map row`.

- [ ] **Step 1: Write the failing tests.** Fixture cases on a copy of the Task 3 fixture, each asserting the exact problem line: a heavy suite file that names `lib/b.sh` (as `"$SRC/lib/b.sh"`) with no row for the pair; a row whose file was deleted; a heavy suite with no row. One passing fixture case. Then the real one: `drift_check "$SRC"` passes, labelled `the subject map covers every file the heavy suites name`.
- [ ] **Step 2:** `./tests/run.test.sh` → fixture cases fail (no `drift_check`); note what the real check reports once Step 3 exists.
- [ ] **Step 3: Implement `drift_check`.** For each `tests/*.test.sh` tagged `heavy`: extract repository paths the file names (tokens beginning `dot_`, `.scripts/`, `.chezmoi`, `tests/` after any `$SRC/`-style prefix; expand a `{a,b}` brace list; keep a token only when that path exists under the root as a file), and require a row listing the suite for each; require every row listing the suite to name an existing file; require at least one row. A directory or a glob token is ignored.
- [ ] **Step 4: Fix what the real check reports** by adding the missing `loaded_by` entries or rows to `subjects.tsv` (never by narrowing the check). List each correction in the commit message.
- [ ] **Step 5:** Change the map's first comment line to say the runner reads it (`tests/run.sh --changed`) and that a new or moved file a suite loads gets its row in the same commit; drop "at 523a95d". Reduce the three heavy tags to their timing: `# test-requires: heavy  # 672 s on 2026-10-31` (keep whatever timing the merged file carries).
- [ ] **Step 6:** `./tests/run.test.sh` and `./tests/run.sh test-audit` → all pass; revert-and-restore check on `drift_check` with one row removed from the real map (the real check must fail naming it), then restore.
- [ ] **Step 7: Commit:** `Make the subject map the runner's source for heavy suites`.

### Task 5: AGENTS.md states the new rule

**Depends on:** Task 4.

**Files:**
- Modify: `AGENTS.md` (Testing: the invocation block, the lock paragraph, the requirement-gate paragraph, the heavy row of the table)
- Possibly: tests or rule files that pin that text. `rg -n 'before every pre-merge|xreview git-forge-guard wt-functions|all three' tests .scripts .chezmoitemplates dot_claude dot_codex` first, and update each live pin and instruction in this task (completed plans, specs and findings keep their text).

- [ ] **Step 1:** If a suite pins the heavy rule's wording, change the pin first and watch it fail.
- [ ] **Step 2: Edit `AGENTS.md`.** The invocation block gains `./tests/run.sh --changed  # default suites plus each heavy suite whose subject changed against main; the pre-merge run`. The heavy row reads: skipped by default for their length; before every pre-merge review run `./tests/run.sh --changed`, which runs each one whose subject (its rows in `.scripts/test-audit/subjects.tsv`, its own file, `tests/run.sh`) changed against main and runs it whenever it cannot tell; an exact name or `--all` runs one regardless; run all three by name after a tool upgrade that could reach them (`brew upgrade`), since no diff shows that. Add: a new or moved file a suite loads gets its map row in the same commit, and `run`'s drift check fails until it does. The lock paragraph gains the holder line, the repeat each minute, the `waited` line and `RUN_SH_LOCK_WAIT` (exit 75, no suites run). Keep "Never wrap it in `lockf` yourself."
- [ ] **Step 3:** `./tests/run.sh agent-instructions run` → pass.
- [ ] **Step 4: Commit:** `Document --changed as the pre-merge run and the reporting lock`.

### Task 6: Verify and finish

**Depends on:** Task 5.

- [ ] **Step 1:** `./tests/run.sh --changed`. This branch changes `tests/run.sh`, so all three heavy suites must be selected with `changed: tests/run.sh`; a skipped heavy suite here is a defect. The run queues on the machine lock: say so in the milestone line, with the holder the runner names. Record `passed/total` per the totals line and the three heavy rows.
- [ ] **Step 2:** Cold review of `main...HEAD` (sp-architect, whole branch) and the Codex pre-merge review (`xreview dispatch --checkpoint pre-merge --diff main...chore/test-run-queue`) together; fix every finding on this branch, each fix with its test; re-run Step 1 after the last fix.
- [ ] **Step 3:** Add implementation notes to the spec (what the drift check found in the map, measured waits if any), set spec and plan to `**Status:** Implemented`, add the completion banner to this plan, commit.
- [ ] **Step 4:** `git push origin chore/test-run-queue`. For the dotfiles the pushed branch is the end.
- [ ] **Step 5:** Report to Michael and to chezmoi-87: what changed, rulings, `passed/total`, the Codex receipt, and `wt-rm chore/test-run-queue`.
