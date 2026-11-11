# Test Audit Implementation Plan

**Status:** In progress (branch `chore/test-audit`; the dotfiles have no MR)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure what every in-scope suite catches by mutation, propose cuts backed by evidence for Michael's approval, then cut, replace the instruction pins, tighten the testing rule, and show that nothing caught before escapes after.

**Architecture:** A Python harness in `.scripts/test-audit/` builds a throwaway git copy of a pinned commit under `$TMPDIR/test-audit/`, runs one suite at a time under the `run.sh` machine lock, and attributes each mutant to the named assertions that failed against a green baseline from the same session. Results are append-only JSONL in `.superpowers/test-audit/` (never tracked), so sessions resume. Subagents classify every suite and write targeted mutants for deletion candidates. The findings document beside this plan is the phase 2 deliverable.

**Tech Stack:** Python 3 (stdlib only, `#!/usr/bin/env python3`, mise's 3.13), bash and zsh suites, `git archive`, `fcntl.flock` (the same lock `lockf -k` takes).

**Spec:** `docs/superpowers/specs/2026-11-11-test-audit-design.md` (signed off 2026-11-11).

## Global Constraints

- Phases 1 and 2 measure main at `523a95d`. The harness binds its state to that SHA (`--ref 523a95d`), whatever main does meanwhile.
- Phases 1 and 2 change no suite and no script under test. The tracked additions are the harness (`.scripts/test-audit/`), its suite `tests/test-audit.test.sh` with fixtures under `tests/fixtures/test-audit/`, the subject map, the targeted-mutant manifest, the rule sets, this plan, and the findings.
- Mutants are applied only in a copy under `--copy-root` (default `$TMPDIR/test-audit`). The harness refuses a copy root inside the repository.
- The harness takes the `run.sh` lock (`$RUN_SH_LOCK`, else `/tmp/claude-$(id -u)/tests-run.lock`) for each suite run and releases it after the run, never for a session. Waiting for the lock does not count toward a run's time or timeout.
- Mutants run only sandboxed: the harness refuses (exit 2) when it can create a file in `$HOME`.
- In scope: every suite except the non-goals `live-agent-auth`, `live-agent-signing`, `live-codex-daemon`, `live-credential-boundary`, `live-deny-modes`, `live-write-boundary`, `ssh-credential-inventory`, `zshrc`, `dev-topology`, `dev-integrations`. `reconcile-agents` is inventoried and classified, never mutated.
- Safety suites, where only targeted-mutant evidence counts: `agent-instructions` (its safety-rule pins), `chezmoi-wrapper`, `claude-settings`, `codex-config`, `deny-modes-probe`, `git-forge-guard`, `git-signing-config`, `ha-mcp`, `hook-path`, `install-claude-managed-settings`, `path-resolution-guard`, `sdd-clean`, `ssh-sandbox-proxy`, `unifi-network-mcp`, `worktree-guard`, `write-boundary-probe`, `wt-functions`, `wt-teardown`, `xreview`, `xreview-apply-guard`, `xreview-guard`, `xreview-ledger`, `xreview-skill`. Classification may add a suite to this list, never remove one.
- Suites are executed, never run through an interpreter. Report totals as passed/total.
- No Bash call starts with `cd`; use absolute paths or `git -C`.
- Implementers do not commit. They run only their task's focused tests; the controller re-checks `git branch --show-current` is `chore/test-audit` before each commit.
- `chezmoi apply`, `wt-rm` and merging are Michael's. Anything that would change the spec goes to the driver (chezmoi-c2) first.
- Fragment caps: `global.md` ≤ 150 lines, `claude-code.md` ≤ 50, `codex.md` ≤ 30.

## Review Focus

1. **Label drift.** A label carrying a temp path differs between the baseline and the mutant run. The kill must still go to the right assertion. A failing label missing from the baseline still counts as a kill and is listed as `unmatched` (Task 1, case B2).
2. **The lock held elsewhere for minutes.** Another line's heavy run holds the lock. The harness says it is waiting, and the wait does not trip the timeout (Task 1, case G2).
3. **A hanging mutant with children.** The whole process group is killed, the run is `inconclusive`, and nothing of it is left running (Task 1, case C1).
4. **A session killed mid-run.** No mutated file reaches the checkout, the killed run's copy is removed on SIGTERM, and the next run's baseline is green (Task 1, case F).
5. **Line shifts between phase 1 and phase 3.** A mutant on an unchanged line keeps its id. A mutant whose line is gone is `stale`, never `survived` (Task 2, case M3).

## Calls made in this plan, not in the spec

- **The harness:** `.scripts/test-audit/audit.py` (CLI, copy, lock, runner, attribution, store), `mutators.py` (code mutants), `rules.py` (rule mutants). Python stdlib only.
- **The copy** is a fresh git repository holding one commit of `git archive <sha>`. Each harness process builds its own copy at `<copy-root>/<sha12>-<command>-<pid>`. Every exit path (normal, exception, SIGINT, SIGTERM) runs the same cleanup, in this order: kill and reap the running suite's process group, restore any mutated file, remove the copy, and only then release the lock. Concurrent processes never share a copy.
- **Run conditions** copy `run.sh`'s: the suite runs as `./<name>.test.sh`, with `cwd` the copy's `tests/` and stdin from `/dev/null`. It sees `RUN_SH_LOCKED=1`, `RUN_SH_START_DIR=<copy>` and `RUN_SH_LOCK=<lock>`, and gets its `# test-args:` with `{repo}` set to the copy. The timeout is `max(--timeout-floor, 3 × the session's baseline seconds)`. On timeout the process group is killed.
- **Labels:** an assertion is a line `run.sh` counts: `^\s*(ok|PASS)(\s|:)` passed, `^\s*(FAIL|not ok)(\s|:)` failed. The label is the rest of the line after the token and an optional `:`. Whitespace is collapsed. The copy's path becomes `<copy>`, and any path under `/tmp`, `/private/tmp`, `/var/folders` or `/private/var/folders` becomes `<tmp>`. The n-th repeat of a label (n ≥ 2) gets ` #n`.
- **Attribution:** the baseline is green when it exits 0 and has at least one passed and no failed assertion. Without a green baseline, every mutant of that suite in that session is `baseline-red` and is not run. A mutant run is:
  - `inconclusive` when it did not complete: it timed out, printed fewer assertions (passed plus failed) than the baseline, or exited non-zero with no failed label. This test comes first, so a run that printed a FAIL and then hung or crashed is never `killed`.
  - `killed` when it completed and a label failed. A failed label is a killer when it passed in the baseline, or when it is a baseline-passed label followed by ` (` and failure detail (`FAIL x (want a, got b)` against `ok x`) and exactly one baseline-passed label qualifies; such killers are listed in `via_detail`. With two or more qualifying labels the failed label is `ambiguous`, never a killer, and a run whose only failed labels are ambiguous is `inconclusive`. The other failed labels are `unmatched`.
  - `survived` otherwise.
  A survivor runs once more. A second-run kill makes the mutant `killed` with `flaky: true`, listed separately in the findings.
- **Code mutants** apply only to shell (`bash`, `zsh`, `sh`) and Python files. Data files and chezmoi data templates get none. Prose gets rule mutants only where a rule is pinned.
- **Random sample size** for a file whose own suite takes `t` seconds: `clamp(floor(900 / t), 4, 20)`, capped by the valid mutants the file has. Fixed counts apply where the own suite is heavy: `xreview` 3, `git-forge-guard` 6, `wt-functions` 8. The sample is stratified: round-robin over the operators in the order `negate, delete, exit, andor, compare`, random within an operator. The RNG is `random.Random(seed ^ zlib.crc32(file))`, with seed `20261111`.
- **Targeted mutants** always run the candidate's own suite. A claimed cross-suite duplicate also runs every suite that loads the mutated file (`subjects.tsv`).
  - A candidate is `evidenced` when it kills each of its mutants and another assertion kills each of them too.
  - It is `unique` when some mutant is killed only by the candidate, and `mis-targeted` when the candidate does not kill one of its mutants.
  - The ranked list accepts deletions greedily, in rank order, and checks the whole set each time (`accept`, Task 2).
    - Every `delete` and `merge` candidate takes part, class-evidence ones included, because a deleted wording pin can be another candidate's only other killer. A merge counts all its labels as removed.
    - A candidate X joins the accepted set D only if, after adding X, every targeted mutant of every candidate in D still has a killer whose label is outside the labels of the whole set. A mutant that would lose its last remaining killer rejects X, whichever candidate the mutant belongs to.
    - So an accepted deletion never relies on a test that another accepted deletion removes.
- **Phase 3 validation** also re-runs the targeted mutants of the approved deletions.
- **Rule mutants:**
  - Operators: the sentence deleted; one strength word weakened (`Never`→`Prefer not to`, `never`→`preferably not`, `must`→`should`, `Must`→`Should`, `always`→`usually`, `Always`→`Usually`, `only`→`mostly`, `Every`→`Most`, `every`→`most`, one occurrence per mutant); one item dropped from a list of three or more (at most 4 per rule).
  - The block prefix (bullet marker plus a leading bold label such as `**Sizing.**`) is never deleted.
  - Phase 3 passes when every regenerated mutant on an approved rule is killed. The only exception is a survivor whose phase 1 counterpart (same rule id, operator and removed word or item) also survived the old pins; each such survivor is listed.
- **The approved rule set** is data, `tests/fixtures/agent-instructions/rules.tsv`, read by one loop in `agent-instructions.test.sh`. Each row holds a rule's anchor and the terms that must sit in the same block as it. In phase 1 it is proposed as `.scripts/test-audit/proposed-rules.tsv`, with a draft checker `.scripts/test-audit/rule-check.sh`, and measured against the rule mutants.
- **`live-feedback-skill` is in scope.** It measures neither the sandbox nor the daemon; `live-` there is the skill's name.
- **`reconcile-agents` is never mutated.** Its suite needs an unsandboxed shell, and an unsandboxed mutant of a config writer could write outside its temp directory.
- **The harness has its own suite**, `tests/test-audit.test.sh`. Main lacks it, so before and after numbers report it on a separate line.
- **Time saved per test** is estimated as suite seconds × the test's assertions ÷ the suite's assertions. A whole suite saves its full time.

---

## Phase 1: measure

### Task 1: Harness core: copy, lock, runner, attribution, inventory

**Depends on:** none.

**Files:**
- Create: `.scripts/test-audit/audit.py` (755)
- Create: `tests/fixtures/test-audit/` (a small repository: `bin/s.sh`, `bin/p.py`, `tests/s.test.sh`, `tests/s2.test.sh`, `tests/red.test.sh`, `tests/lock.test.sh`, `tests/gated.test.sh`, `subjects.tsv`)
- Test: `tests/test-audit.test.sh` (755)

**Interfaces:**
- Produces the CLI `audit.py [global options] <command> [args]`. Global options:
  - `--repo DIR`: default the git top level of the harness's checkout.
  - `--ref REF`: default the SHA the state is bound to, else `main`. It is resolved to a SHA, which is written to `<state>/meta.json` on first use; a later different SHA exits 2 with `state is bound to <sha>; use another --state`.
  - `--state DIR`: default `<repo>/.superpowers/test-audit`.
  - `--subjects FILE`: default `<harness dir>/subjects.tsv`.
  - `--copy-root DIR`: default `$TMPDIR/test-audit`.
  - `--lock FILE`: default `$RUN_SH_LOCK`, else `/tmp/claude-<uid>/tests-run.lock`.
  - `--timeout-floor SECONDS`: default 60.
  - `--probe-dir DIR`: default `$HOME`.
  - `--seed N`: default 20261111.
- Commands in this task:
  - `inventory [SUITE...]` runs a baseline of every in-scope suite, or the named ones. It writes `<state>/inventory.jsonl` rows `{suite, lines, assertions, passed, failed, labels, rc, seconds, requires, serial}`, where `passed` and `failed` are counts and `labels` lists the normalized passed labels. `requires` is the `# test-requires:` value; a suite with a requirement other than `heavy` is listed with `seconds: null` and not run.
  - `try FILE FIND REPLACE SUITE` replaces the one occurrence of FIND in FILE in its own copy, runs the baseline, then the mutant, and prints one JSON line `{verdict, killers, unmatched, rc, seconds, timed_out}`. It writes no state. More than one occurrence, or none, exits 2.
  - `report --section inventory` prints a markdown table: suite, lines, assertions, seconds, requires, files loaded.
- `subjects.tsv` has four tab-separated columns, with `#` comment lines:
  - `file`: repository-relative path.
  - `lang`: one of `bash|zsh|sh|py|prose|data|deployed`.
  - `own_suite`: a suite name, or `-`.
  - `loaded_by`: a comma list of suites, including `own_suite`.
- Python, for Task 2 and Task 3:
  - `build_copy(repo, sha, root, command) -> Path`
  - `run_suite(copy, suite, timeout, lock) -> Run`, where `Run` has `rc: int | None`, `seconds: float`, `timed_out: bool`, `passed: list[str]`, `failed: list[str]`, `output: str`
  - `baseline_ok(run) -> bool`
  - `attribute(baseline, run) -> (verdict, killers, unmatched)`
  - `Store(state)` with `append(kind, record)`, `records(kind)` and `meta()`, over `<state>/runs-<kind>.jsonl`
- Exact messages:
  - `refusing: <dir> is writable, so this shell is not sandboxed` (exit 2)
  - `refusing: copy root <dir> is inside the repository` (exit 2)
  - `waiting for the test-run lock <path>` (stderr)

- [ ] **Step 1: Write the failing suite.**
  - Shape: `#!/usr/bin/env bash`, `set -u`, and the `  PASS: …`/`  FAIL: …` idiom with a `RESULT:` line, as in `tests/provision.test.sh`. Exit 2 with `missing script under test: <path>` when `audit.py` is absent.
  - Setup: each case copies the fixture into `$T/repo`, runs `git init` and commits it, and calls the harness with `--repo $T/repo --state $T/state --copy-root $T/copies --lock $T/lock --probe-dir $T/ro`, where `$T/ro` is mode 555.
  - Cases, each naming its bug in a comment:
  - **A. refusals** (mutants run with full write access; a mutated copy inside the repo): a writable `--probe-dir` exits 2 with the refusal line, and `s.test.sh`'s run marker is absent. `--copy-root $T/repo/x` exits 2.
  - **B1. kill attribution** (a kill with no named assertion): `try bin/s.sh <covered expression> <broken> s` gives `killed`, with killers exactly `["add returns the sum"]`.
  - **B2. label drift** (a kill lost to a temp path in the label): `s.test.sh` prints a label holding its `mktemp` path. A mutant breaking that case gives `killed`, with the killer label ending in `<tmp>`. A mutant that makes `s.test.sh` print a FAIL label absent from the baseline gives `killed`, with that label in `unmatched`.
  - **B3. survivor** (an uncovered line counted as killed): a mutant on `s.sh`'s uncovered line gives `survived`.
  - **C1. hang** (a timeout counted as a kill, or orphans left behind): a mutant that makes `s.sh` loop forever around `sleep 30 # audit-hang-marker`, with `--timeout-floor 2`, gives `inconclusive` and `timed_out: true` in under 10 s, and `pgrep -f audit-hang-marker` finds nothing afterwards.
  - **C2. died partway** (a crash counted as a kill): each of these mutants gives `inconclusive`:
    - the suite exits 3 with no FAIL line;
    - it exits 0 after fewer PASS lines than the baseline;
    - it prints a FAIL and then hangs (`--timeout-floor 2`);
    - it prints a FAIL and then exits before its remaining cases.
  - **D. red baseline** (kills measured against a failing suite): `try` against `red` gives `baseline-red`, and the mutant's run marker is absent.
  - **E. checkout untouched** (mutants applied in the checkout): after every case, `git -C $T/repo status --porcelain` is empty.
  - **F. interrupted** (a mutated copy reused, or one reaching the checkout): start the C1 mutant with `--timeout-floor 60` in the background, wait 2 s, then send SIGTERM. The harness exits, `pgrep -f audit-hang-marker` finds nothing, its copy directory is gone, `lockf -t 0 $T/lock true` exits 0, and `$T/repo` is clean. A following B1 `try` gives `killed`.
  - **G1. lock per run** (the lock never taken, or held after the run): `lock.test.sh` passes `lock is held during the run` only when `lockf -t 0 "$RUN_SH_LOCK" true` exits 75 and `RUN_SH_LOCKED` is `1`. `try bin/s.sh <covered expression> <broken> lock` gives `survived`, which needs a green baseline. After the harness exits, `lockf -t 0 $T/lock true` exits 0.
  - **G2. lock wait not timed** (another line's run trips the timeout): with `lockf -k $T/lock sleep 4 &` holding the lock, a B1 `try` with `--timeout-floor 2` gives `killed`, and stderr has `waiting for the test-run lock`.
  - **H. inventory** (miscounted assertions; gated suites run): `inventory` writes one row per fixture suite. `s` has the assertion count `run.sh` reports for it (check by running this repository's `tests/run.sh`, copied into `$T/repo/tests/` at setup, with `RUN_SH_LOCK=$T/lock`). `gated` (`# test-requires: unsandboxed`) has `seconds: null` and its run marker is absent. `report --section inventory` prints a row for `s`.
  - **I. state binding** (two commits measured into one state): a second `inventory` with `--ref` set to another commit exits 2 with `state is bound to`.
- [ ] **Step 2: Run it and watch it fail.** `./tests/test-audit.test.sh` exits 2 with `missing script under test`.
- [ ] **Step 3: Implement `audit.py`.**
  - The probe: `os.open(<probe-dir>/.test-audit-probe-<pid>, O_CREAT|O_EXCL|O_WRONLY)`; on success, unlink it and refuse.
  - The lock: `fcntl.flock(LOCK_EX|LOCK_NB)`. On `BlockingIOError`, print the waiting line and take `LOCK_EX`. The clock starts after the lock is held.
  - The run: `subprocess.Popen(..., start_new_session=True)`, with `os.killpg(SIGKILL)` on timeout.
  - The copy: `git archive <sha> | tar -x`, then `git init -q`, `git add -A` and a commit with `-c user.name=test-audit -c user.email=test-audit@localhost -c commit.gpgsign=false`.
  - Exit handling: SIGINT and SIGTERM raise `SystemExit`, so they reach the same `finally` cleanup as a normal or failing exit, in the order given under "The copy" above.
- [ ] **Step 4: Run the suite.** `./tests/test-audit.test.sh` passes all cases (report passed/total). It takes under 60 s.
- [ ] **Step 5: Commit** `Add the test-audit harness core and its suite`.

### Task 2: Code mutants, the frozen sample, sample and targeted runs, kill reports

**Depends on:** Task 1.

**Files:**
- Create: `.scripts/test-audit/mutators.py`
- Modify: `.scripts/test-audit/audit.py`, `tests/test-audit.test.sh`, `tests/fixtures/test-audit/`

**Interfaces:**
- Consumes everything Task 1 produces.
- A `Mutant` is a dict:
  - `id`: 12 hex characters, `sha1(kind\0file\0op\0context\0occurrence\0col\0before\0after)`.
  - `kind`: `code`, `rule` or `targeted`.
  - `file`, `op` and `line`; `line` is 1-based and informational only.
  - `context`: the original line, or for a rule mutant the original block.
  - `occurrence`: the 0-based index of `context` among identical contexts in the file.
  - `col`, `before`, `after`: the offset of `before` in `context`, and its replacement.
- `mutators.code_mutants(file: str, text: str, lang: str) -> list[Mutant]` returns only valid mutants. Validity is `bash -n`, `zsh -n` or `sh -n` by `lang`, or `compile()` for Python. Comment lines and heredoc bodies are skipped. Operators:
  - **shell:**
    - `negate`: `!` inserted after `if`, `elif`, `while` or `until`.
    - `delete`: a simple-command or assignment line becomes `:` (keywords, braces, `;;` and function headers are never deleted).
    - `exit`: `exit N` and `return N` swap 0 and non-zero, and bare `exit` or `return` gets `1`.
    - `andor`: one `&&` and `||` swapped, outside quotes.
    - `compare`, inside `[ ]`, `[[ ]]` or `(( ))`: `-eq↔-ne`, `-lt↔-ge`, `-gt↔-le`, `=`/`==`↔`!=`, `-z↔-n`, `<↔>=`, `>↔<=`.
  - **python:**
    - `negate`: `if X:`, `elif X:` and `while X:` become `… not (X):`.
    - `delete`: a simple statement becomes `pass`.
    - `exit`: `sys.exit(0)↔sys.exit(1)`, `return True↔return False`, `return 0↔return 1`.
    - `andor`: ` and ↔ or `.
    - `compare`: `==↔!=`, `<↔>=`, `>↔<=`, ` in ↔ not in `, ` is ↔ is not `.
- `apply(text, mutant) -> str | None` finds the `occurrence`-th `context`, checks `before` at `col`, and returns the mutated text. `None` means `stale`.
- New commands:
  - `mutants FILE` prints every valid code mutant of FILE as JSONL and runs nothing.
  - `plan` needs the inventory (otherwise it exits 2 with `run inventory first`). It freezes the random sample into `<state>/sample.jsonl` (once), then prints a row per file (`file, own suite, valid, sampled, est. minutes`) and `total: <n> mutants, ~<h> h`. ETA: Σ sampled × own-suite baseline × 1.2, plus one baseline per suite.
  - `sample [--max-minutes N] [--only FILE...] [--sample-from STATE]`
    - It runs the frozen sample (or another state's) against each file's own suite and skips mutants that already have a final record.
    - It prints `[sample] <file>: <done>/<n> (killed a, survived b, inconclusive c)` as each file completes, and `remaining: <n>` at exit.
    - A second process on the same state and command exits 2 with `another sample run holds <state>`.
  - `targeted [--max-minutes N] MANIFEST`: the same resume and lock rules, over `runs-targeted.jsonl`.
  - `report --section kills|gaps|targeted [--compare STATE --kind KIND [--only FILE...]]`:
    - `kills`: a row per file (`sampled, killed, flaky, survived, inconclusive, baseline-red, stale, kill rate = killed ÷ (killed + survived)`) and a row per assertion (`suite, label`, and the count and ids of the mutants it killed).
    - `gaps`: every survivor (`file:line, op, before → after`).
    - `targeted`: a row per candidate with its verdict and each mutant's killers.
    - `--compare STATE --kind code|targeted|rule [--only FILE...]`: of STATE's killed mutants of that kind on the selected files, it lists `lost` (run here, not killed) and `not run` (no final record here). `--kind` is required. Without `--only`, the selection is the files with a final record of that kind here, so mutants that were never rerun do not show as lost.
  - `accept CLASSIFICATION_TSV MANIFEST` runs the greedy acceptance above over the `delete` and `merge` rows, in rank order: estimated seconds saved from the inventory, descending, with ties broken by suite and line. It prints one row per candidate: `accepted`, or `rejected` with the reason. The reasons are `not evidenced` (a targeted candidate whose verdict is not `evidenced`), `class evidence in a safety suite`, or `would leave <mutant id> without a killer`. Labels and killers are compared as `suite::label`.
- The manifest is one JSONL object per candidate:
  - `candidate`, `suite`, `labels` (normalized as in Task 1), `claim` (`duplicate|wording|stub|other`), `duplicate_of` (`["suite::label"]`), `safety` (bool).
  - `mutants`: `[{file, find, replace, line?}]`. `find` must occur exactly once in the file, or exactly once on `line` when that is given. Otherwise the run exits 2 naming the candidate.

- [ ] **Step 1: Extend the suite.** Add the fixture lines each case needs: a comment line holding `&&`, a heredoc holding `exit 0`, and `s2.test.sh` loading `bin/s.sh`. Cases:
  - **M1. operators** (broken syntax counted as an easy kill): `mutants bin/s.sh` lists each of the five operators at least once, and so does `mutants bin/p.py`. Each listed mutant, applied, passes `bash -n` or `python3 -m py_compile`. None sits on the comment line or inside the heredoc.
  - **M2. frozen sample** (a sample that changes between sessions): `plan` in two fresh state directories with the same seed writes identical `sample.jsonl`. Every operator present in a file appears in its sample. The output has `total:`.
  - **M3. id stability** (a rebase turning killed mutants into survivors): a second commit inserts a line at the top of `s.sh` and deletes one covered line. `mutants` gives the same ids for mutants on unchanged lines. `sample --sample-from <first state>` on the second commit records the deleted line's mutants as `stale`.
  - **M4. run and resume** (a lost or repeated run): `sample` leaves a final record for every sampled mutant, and every survivor has an attempt 2. A second `sample` prints `remaining: 0` and adds no line to `runs-sample.jsonl`. `--max-minutes 0` runs nothing and prints the remaining count.
  - **M5. reports** (miscounted kill rate): `report --section kills` shows the fixture's exact killed and survived counts and its rate. `gaps` names the uncovered line's mutants.
  - **M6. targeted verdicts** (a deletion justified by its own kill, or by an untargeted mutant): a fixture manifest with four candidates gets `evidenced`, `unique`, `mis-targeted`, and a cross-suite duplicate whose second killer lives in `s2`, which runs only because the claim is `duplicate`, so that one is `evidenced` too. A `find` that occurs twice exits 2 naming its candidate.
  - **M7. compare** (a cut that loses a kill, or unrun mutants reported as lost): in a state against a commit where `s.test.sh` lacks the killing case, `sample --sample-from <first> --only bin/s.sh` then `report --compare <first> --kind code` lists that mutant as `lost`. It does not list `bin/p.py`'s killed mutants, nor a targeted mutant on `bin/s.sh` that `<first>` killed. `--only bin/s.sh bin/p.py` lists `bin/p.py`'s as `not run`.
  - **M8. acceptance** (two deletions that each rely on the other's test): a classification has candidates A, B and W in rank order. A's mutant is killed by A and B; B's mutant is killed by B and C; W is a class-evidence wording pin and is the only other killer of a fourth candidate D's mutant (D ranked after W). `accept` accepts A, rejects B with `would leave <A's mutant> without a killer`, accepts W, and rejects D. A class-evidence row in a safety suite is rejected with `class evidence in a safety suite`.
- [ ] **Step 2: Watch the new cases fail.** Run the suite.
- [ ] **Step 3: Implement** `mutators.py` and the new commands. A per-state, per-command `flock` on `<state>/<command>.lock` gives the "another run holds" refusal.
- [ ] **Step 4: Run the suite.** All cases pass (passed/total), in under 90 s.
- [ ] **Step 5: Commit** `Add code mutants, the frozen sample and the kill reports to the harness`.

### Task 3: Rule mutants

**Depends on:** Task 2.

**Files:**
- Create: `.scripts/test-audit/rules.py`
- Modify: `.scripts/test-audit/audit.py`, `tests/test-audit.test.sh`, `tests/fixtures/test-audit/`

**Interfaces:**
- Consumes `Mutant`, `apply`, `Store` and the run machinery.
- A rules TSV has tab-separated columns `id, file, anchor, safety (yes|no|?), terms, note`. `terms` is `;`-separated, or `-`.
- `pins SUITE_FILE` prints a rules TSV with one row per `need`, `need_flat` or `need_in` call in the suite:
  - `id` is `p<line of the call>`.
  - `file` is `.chezmoitemplates/agents/<fragment>` for `need` and `need_flat`, and the resolved path for `need_in`.
  - `anchor` is the pinned text, `safety` is `?`, and `note` is the label.
  - It resolves the suite's `NAME=value` assignments. An argument it cannot resolve exits 1, naming the line.
- `rules.rule_mutants(file, text, rule_id, anchor) -> list[Mutant]` finds the anchor in the whitespace-flattened text. Sentences end at `.`, `?` or `!` followed by whitespace, outside backticks; blocks are bullets and paragraphs. The operators are those under "Rule mutants" above. An anchor that is not found yields no mutants and marks the rule `missing`.
- `rules [--max-minutes N] [--check-cmd CMD] RULES_TSV` runs each rule mutant against every suite in the file's `loaded_by`. With `--check-cmd`, it runs only CMD instead, as the pseudo-suite `check`, split with `shlex` and with `{copy}` replaced by the copy's path. Resume and lock rules as in Task 2, over `runs-rules.jsonl`.
  - Binding: on first use, `meta.json` records the sha256 of RULES_TSV, the `--check-cmd` string, and the sha256 of each of its arguments that names an existing file. A later `rules` on that state with any of these different exits 2 with `state is bound to another rule set or check; use another --state`. Resumed results therefore always belong to the same rules and the same checker.
  - Missing rules: each rule whose anchor is not found prints `missing: <id>`, and `rules` exits 1 after its runs.
- `report --section rules` prints a row per rule (`id, safety, mutants, killed, survivors as op:item`), then the `missing` rules.

- [ ] **Step 1: Extend the suite.** Add a fixture `docs/rules.md` with a wrapped bullet:

  ```
  - **Confirm.** Never push, delete or merge
    without asking. Keep notes.
  ```

  Add a fixture suite `tests/pins.test.sh` that defines `need`, `need_flat` and `need_in` as `agent-instructions.test.sh` does, and pins the full sentence with `need_in "$R"`, where `R=docs/rules.md`. Cases:
  - **R1. pin extraction** (a pin dropped silently, so its rule has no baseline): `pins` on a fixture with one `need`, one `need_flat` with a continuation line, and one `need_in "$X"` prints exactly three rows with the right files and anchors. A `need_in "$UNSET"` exits 1, naming its line.
  - **R2. mutants** (a mutant that deletes the rule's label, or misses a wrapped line): anchor `Never push` yields `delete-sentence`, one `weaken` (`Prefer not to push`) and three `drop-item` mutants.
    - Applied, `delete-sentence` leaves `- **Confirm.** Keep notes.` once whitespace is flattened.
    - Dropping `delete` leaves `Never push or merge without asking.`
  - **R3. runs** (rule kills misattributed): `rules` with the exact pin in `pins.test.sh` kills all five. With `--check-cmd` set to a script that only greps `**Confirm.**`, all five survive, and `report --section rules` lists five survivors.
  - **R4. binding and missing rules** (a revised checker never exercised; an approved rule silently untested):
    - After R3's `--check-cmd` run, editing that check script and running `rules` on the same state exits 2 with `state is bound to another rule set or check`.
    - A rules TSV row whose anchor is absent prints `missing: <id>`, and `rules` exits 1.
- [ ] **Step 2: Watch the new cases fail.**
- [ ] **Step 3: Implement** `rules.py`, `pins` and `rules`.
- [ ] **Step 4: Run the suite.** All cases pass (passed/total).
- [ ] **Step 5: Commit** `Add rule mutants for pinned instruction text to the harness`.

### Task 4: The subject map

**Depends on:** Task 1. It runs in a batch with Task 2 (disjoint files).

**Files:**
- Create: `.scripts/test-audit/subjects.tsv`

- [ ] **Step 1: Read every suite** in `tests/` at `523a95d`. List each file it sources, executes, renders or greps, with its `lang`.
  - `own_suite` follows the `<subject>.test.sh` naming; otherwise it is the suite that exercises the file most directly.
  - `deployed` marks a file the suite reads from `$HOME` instead of the source (`claude-desktop-config` reads `$HOME/.local/bin/ha-mcp`).
  - Prose files loaded by `agent-instructions`, `agent-skills`, `review`, `live-feedback-skill` and `xreview-skill` are `prose`.
  - The heavy suites' tags name the files they load.
- [ ] **Step 2: Verify the map.**
  - Every `file` exists at the pinned commit: `git -C <checkout> cat-file -e 523a95d:<file>` for each row.
  - Every in-scope suite appears in some `loaded_by`.
  - Every `bash|zsh|sh|py` file has an `own_suite`.
  - Print the counts by `lang`.
- [ ] **Step 3: Commit** `Map each suite to the files it tests`.

### Task 5: Inventory and the before-run times (controller)

**Depends on:** Tasks 3 and 4.

- [ ] **Step 1: Run the inventory**, sandboxed: `.scripts/test-audit/audit.py --ref 523a95d inventory`. All in-scope suites run one at a time, heavy ones included (about 30 minutes). This binds `.superpowers/test-audit` to `523a95d`, so later phase 1 commands on that state need no `--ref`. Every other phase 1 state passes `--ref 523a95d`.
- [ ] **Step 2: Investigate every baseline that is not green** in the copy.
  - A cold chezmoi external cache prints `INCONCLUSIVE:` and the warm-up command. Run that warm-up outside the sandbox, then `inventory <suite>` again.
  - A suite that stays red is `copy-red`: it gets no mutants, and the findings name it and the cause.
- [ ] **Step 3: Time main's whole runs** with `/usr/bin/time -p`, in a copy of `523a95d` built with `git archive` under `$TMPDIR/test-audit/runs`:
  - the default run, `<copy>/tests/run.sh`;
  - the heavy run, `<copy>/tests/run.sh xreview git-forge-guard wt-functions`.
  Time `reconcile-agents` once, unsandboxed, with `./tests/run.sh reconcile-agents` in this checkout (its suite is unchanged from main). Record all three, with passed/total.
- [ ] **Step 4: Freeze the sample.** Run `audit.py plan` and keep its size and ETA for Task 6.
- [ ] **Step 5: Commit** any `subjects.tsv` corrections the baseline exposed.

### Task 6: Random-sample sessions (controller, unattended)

**Depends on:** Task 5.

- [ ] **Step 1: Send the driver the size and ETA** from `plan` before the first session (`SendMessage` to chezmoi-c2).
- [ ] **Step 2: Run sessions** in the background: `audit.py sample --max-minutes 180`. Repeat until `remaining: 0`.
  - After each session, send the driver one line: done, remaining, the kill rate so far, and anything inconclusive.
  - Send one push notification when the sample completes or blocks.
- [ ] **Step 3: Check that it finished:** `report --section kills` shows no file with unrun mutants, and inconclusive runs are counted.

### Task 7: Classification (subagents, during Task 6)

**Depends on:** Task 5 (it needs the baseline labels).

**Files:**
- Create, untracked: `.superpowers/test-audit/classification/<suite>.tsv` and `.superpowers/test-audit/targeted/<suite>.jsonl`

- [ ] **Step 1: Dispatch six `sp-standard` classifiers together**, one per family, each under about 7,000 lines:
  1. `xreview`, `xreview-rpc`, `xreview-apply-guard`, `review`
  2. `xreview-replay`, `xreview-packet`, `xreview-guard`, `xreview-ledger`, `xreview-skill`
  3. `git-forge-guard`, `worktree-guard`, `path-resolution-guard`, `hook-path`, `git-config`, `git-signing-config`, `ssh-sandbox-proxy`
  4. `wt-functions`, `wt-teardown`, `sdd-clean`, `chezmoi-wrapper`, `zsh-config`, `zshenv`, `zshrc-reload`
  5. `dev`, `herdr-*`, `codex-*`, `statusline`, `alfred-relay`, `claude-desktop-config`, `mise-config`, `tagteam-config`, `ha-mcp`, `unifi-network-mcp`
  6. `agent-instructions`, `agent-skills`, `agent-text-scan`, `claude-settings`, `live-feedback-skill`, `memory-health`, `prompt-audit`, `measure-interventions`, `process-replay`, `provision`, `install-claude-managed-settings`, `skill-updates`, `run`, `deny-modes-probe`, `write-boundary-probe`, `reconcile-agents`

  Each brief carries:
  - the spec's Design §3 and Anti-goals;
  - this plan's Global Constraints and its "Targeted mutants" call;
  - the suite's baseline labels from `.superpowers/test-audit/inventory.jsonl`;
  - the `subjects.tsv` rows;
  - the output formats below.
- [ ] **Step 2: Each classifier writes one TSV row per test.** A test is the assertions one case block emits. Columns:
  - `suite`; `test` (`<start>-<end>` lines); `labels` (` | `-joined, normalized);
  - `kind` (`behaviour|wording|duplicate|stub|live`); `duplicate_of` (`suite:line`, or `-`);
  - `verdict` (`keep|delete|merge`); `merge_with` (`suite:line`, or `-`);
  - `evidence` (`class|targeted`); `safety` (`yes|no`); `note` (one line).

  Rules:
  - Only `wording`, `stub` and `duplicate` tests can be `delete`.
  - `merge` means two or more cases that one table-driven case covers.
  - A `delete` or `merge` in a safety suite, and every `duplicate`, needs `evidence=targeted`. For those, the classifier writes a manifest object (Task 2's format) with 1 to 3 mutants that break the code the test exercises.
  - Classifiers may check a mutant with `audit.py try` on a suite that is not heavy, never on a heavy one.
  - In `agent-instructions`, each pin row also says whether its rule is a safety rule (Anti-goals list).
- [ ] **Step 3: Collect the classifications.** Concatenate the TSVs into `docs/superpowers/plans/2026-11-11-test-audit-classification.tsv` and the manifests into `.scripts/test-audit/targeted.jsonl`.
  - Check that every in-scope suite has rows.
  - Check that every `delete` or `merge` row with `evidence=targeted` has a manifest entry.

### Task 8: Rule-mutant baseline and the proposed replacement

**Depends on:** Task 5. Its machine runs interleave with Task 6 on the lock.

**Files:**
- Create: `.scripts/test-audit/pinned-rules.tsv`, `.scripts/test-audit/proposed-rules.tsv`, `.scripts/test-audit/rule-check.sh` (755)

- [ ] **Step 1: Extract the pins.** Run `audit.py pins tests/agent-instructions.test.sh > .scripts/test-audit/pinned-rules.tsv`. The row count must equal `rg -c '^(need|need_flat|need_in) ' tests/agent-instructions.test.sh`, which is 77 at `523a95d`.
  - Add a row by hand for each direct `grep -q` check that pins a rule. Rows for other suites' pins on fragment text come from Task 7.
  - Fill `safety` from the Anti-goals list.
- [ ] **Step 2: Measure the baseline.** `audit.py --state .superpowers/test-audit-rules --ref 523a95d rules .scripts/test-audit/pinned-rules.tsv`, then `report --section rules`. Every pin passes at `523a95d`, so a `missing` rule means the locator is wrong: fix the harness, not the TSV. Step 4's states pass `--ref 523a95d` too.
- [ ] **Step 3: Write the proposal.**
  - `proposed-rules.tsv`: one row per rule whose loss would matter, including every `safety=yes` rule. `anchor` is a short, stable phrase, preferably the bullet's bold label. `terms` must cover what the rule mutants change:
    - each strength word in the rule's sentence, together with the words it governs (`only if its bug`, not `only`), since the word alone may occur elsewhere in the block;
    - each item of each list of three or more, one term per item;
    - text that only a sentence deletion removes.
  - `rule-check.sh <rules.tsv> <source root>`: for each row, find the block that holds the anchor in the whitespace-flattened file, check each term is in that block, and print `  PASS: rule <id>` or `  FAIL: rule <id>`. Exit with the failure count.
- [ ] **Step 4: Measure the proposal against the old pins.**
  Each revision `<n>` of the proposal (1, 2, …) gets fresh states. The harness refuses a reused state anyway, because it binds the rule set and the checker.
  - `audit.py --state .superpowers/test-audit-pins-<n> --ref 523a95d rules .scripts/test-audit/proposed-rules.tsv` runs the old pins on the proposal's mutants.
  - `audit.py --state .superpowers/test-audit-checks-<n> --ref 523a95d rules --check-cmd '<checkout>/.scripts/test-audit/rule-check.sh <checkout>/.scripts/test-audit/proposed-rules.tsv {copy}' .scripts/test-audit/proposed-rules.tsv` runs the draft checks on the same mutants.
  - `report --section rules --compare .superpowers/test-audit-pins-<n> --kind rule`, in the checks state, must list nothing `lost` and nothing `not run`, and no rule may be `missing`. Revise the terms until it is clean, or record the rule as a gap.
  - The final revision's states are the ones Task 15 compares against. Record `<n>` in the findings.
- [ ] **Step 5: Commit** `Measure the pinned instruction rules and propose their replacement`.

### Task 9: Targeted runs

**Depends on:** Task 7.

- [ ] **Step 1: Send the driver the size and ETA:** the number of targeted mutants, and the suite runs they need, heavy ones counted.
- [ ] **Step 2: Run** `audit.py targeted --max-minutes 180 .scripts/test-audit/targeted.jsonl` in sessions until `remaining: 0`.
- [ ] **Step 3: Rewrite each `mis-targeted` mutant once.** Read the candidate, rewrite the mutant, and run `targeted` again. A candidate that is still mis-targeted stays `keep`.
- [ ] **Step 4: Commit** the final `targeted.jsonl`.

### Task 10: Findings and the phase 2 report

**Depends on:** Tasks 6, 8 and 9.

**Files:**
- Create: `docs/superpowers/plans/2026-11-11-test-audit-findings.md`
- Modify: `docs/superpowers/plans/2026-11-11-test-audit-classification.tsv`, `.scripts/test-audit/targeted.jsonl` (committed with the findings)

- [ ] **Step 1: Write the findings**, in this order:
  1. **Before-numbers:**
     - suites (in scope and all), `tests/` lines, assertions;
     - default and heavy wall times, and per-suite seconds;
     - kill rate overall and per file, with flaky, inconclusive, `copy-red` and `stale` counts;
     - the harness suite on its own line.
  2. **Ranked list:** every `delete` and `merge`, ordered by estimated seconds saved. Columns: rank, suite, test (lines and labels), verdict, kind, evidence (class; or the targeted mutant ids with their killers, R8 attributions marked `*`; or `duplicate of`), seconds saved, safety, and accepted. "Accepted" is the `audit.py accept docs/superpowers/plans/2026-11-11-test-audit-classification.tsv .scripts/test-audit/targeted.jsonl` result, with the reason for each rejection.
  3. **Keep summary:** a row per suite, counting its tests by kind.
  4. **Proposed replacement checks:** the `proposed-rules.tsv` table, the measured comparison, and each safety rule marked.
  5. **Gaps:** survivors counted per file, with the full list in an appendix.
  6. **Not measured:** inconclusive and flaky mutants, `copy-red` suites, and the non-goal suites.
  7. **Method notes for the next audit:** what to reuse, and what cost the most time.
- [ ] **Step 2: Get a cold check.** An `sp-reviewer` checks the findings against the spec's Anti-goals:
  - every `delete` has admissible evidence;
  - safety suites rely only on targeted evidence;
  - every safety rule is in the proposed set;
  - the accepted set has no mutual reliance.
  Fix what it finds.
- [ ] **Step 3: Commit** `Record the test audit's findings`.
- [ ] **Step 4: Stop for phase 2.** Send the driver the findings path and commit, the ranked list summary, the proposed replacement checks, the gaps, the before-numbers, and any friction on the `wt` path. Delete nothing until Michael's approval arrives through the driver.

## Phase 2: Michael's checkpoint

No task. Michael approves the list, wholly or in part, through the driver. Gaps are reported, not fixed.

## Phase 3: cut, replace, tighten, validate

### Task 11: Rebase and refresh

**Depends on:** Task 10; Michael's approval; `feat/wt-dotfiles`, `feat/draft-status` and `feat/archive-review-threads` all merged into `main`.

- [ ] **Step 1: Record the approval.** Add an "Approved" section to the findings with the date and the approved items. Record any partial approval under Rulings.
- [ ] **Step 2: Rebase.** `git -C <checkout> rebase main`, and resolve any conflicts. Run `./tests/test-audit.test.sh` afterwards.
- [ ] **Step 3: Find what changed.** `git -C <checkout> diff --name-only 523a95d main -- tests/` plus the `subjects.tsv` files give the affected suites and files. Update `subjects.tsv` for new or moved files.
- [ ] **Step 4: Refresh against the new main** in `--state .superpowers/test-audit-refresh --ref <new main SHA>` (record the SHA in the findings; every refresh state below takes the same `--ref`):
  - `inventory` of the affected suites;
  - `sample --sample-from .superpowers/test-audit --only <affected files>`;
  - `targeted` for the approved candidates in affected suites;
  - when a fragment changed: `rules .scripts/test-audit/pinned-rules.tsv` there, and `rules .scripts/test-audit/proposed-rules.tsv` in `--state .superpowers/test-audit-refresh-pins --ref <new main SHA>` (the old pins on the proposal's mutants, Task 15's counterpart).

  An approved deletion whose evidence no longer holds is dropped from the cut and reported to the driver.
- [ ] **Step 5: Commit** the refreshed findings section.

### Task 12: Delete and merge

**Depends on:** Task 11.

**Files:** the approved suites, except `tests/agent-instructions.test.sh` (Task 13).

- [ ] **Step 1: Dispatch implementers in batches** of suites with disjoint files, one batch at a time. Each implementer:
  - deletes or merges exactly the approved items, keeping the suite's existence check and output idiom;
  - updates a heavy suite's `# test-requires: heavy  # <s> s on <date>` comment when its time changes;
  - runs each suite it touched (passed/total).
- [ ] **Step 2: Commit each suite group separately.** The controller commits each one (`Cut <suite>'s surplus tests per the audit`) and reviews each commit with `sp-reviewer` against its approved items.

### Task 13: Replace the pins

**Depends on:** Task 11. It runs in a batch with Task 12 (disjoint files).

**Files:**
- Modify: `tests/agent-instructions.test.sh`
- Create: `tests/fixtures/agent-instructions/rules.tsv`, from the approved `proposed-rules.tsv`
- Delete: `.scripts/test-audit/proposed-rules.tsv`, `.scripts/test-audit/rule-check.sh`

- [ ] **Step 1: Port the checks.** Move the approved rows to `tests/fixtures/agent-instructions/rules.tsv` (`git mv`, then edit). Port `rule-check.sh`'s loop into `agent-instructions.test.sh` as one `rule` helper over that file, labelled `rule <id>: <note>`. Exit 2 if the TSV is missing.
- [ ] **Step 2: Remove the replaced pins.** Delete every `need`, `need_flat` and `need_in` call, and every hand pin, that the approved set replaces. Keep the render, structure and line-cap checks unless the approved list says otherwise.
- [ ] **Step 3: Run** `./tests/agent-instructions.test.sh`: green (passed/total).
- [ ] **Step 4: Commit** `Replace the sentence pins with checks on the rules that matter`.

### Task 14: Tighten the testing rule

**Depends on:** Task 13.

**Files:**
- Modify: `.chezmoitemplates/agents/global.md` (the bullet that starts `- Each test names the behaviour it pins`), `dot_claude/skills/cross-review/SKILL.md` (`Test paths stay writable, because…`), `dot_claude/agents/sp-architect.md` and `dot_claude/agents/sp-reviewer.md` (the `Judge the change against the Engineering judgement section` bullet), `tests/fixtures/agent-instructions/rules.tsv`, and `tests/agent-instructions.test.sh` if a pin on the clause remains.

- [ ] **Step 1: Replace the `global.md` bullet** with this text. Rewrapping is allowed. It must not add a line, so `global.md` stays within 150:

  ```
  - Test behaviour, not wording; extend a case before adding one. A real bug fix ships with a test;
    a review finding, only if its bug could plausibly return. Each test passes the revert check
    (revert the fix, see it fail, restore it). Never special-case code to pass a test; report it.
  ```

- [ ] **Step 2: Make the restatements say the same.**
  - `SKILL.md`: `Test paths stay writable, because a real bug fix ships with a test that fails without it.`
  - `sp-architect.md` and `sp-reviewer.md`: the finding list becomes `a speculative abstraction, a workaround where a refactor belongs, a test that pins wording instead of behaviour, a test added for a review finding whose bug could not plausibly return, or a test that would still pass with the bug back`.
- [ ] **Step 3: Update the rule set.** The testing rule's row in `rules.tsv` gets the anchor `Test behaviour, not wording` and these terms, following Task 8's terms rule: `extend a case before adding one;A real bug fix ships with a test;a review finding, only if its bug could plausibly return;revert the fix;see it fail;restore it;Never special-case code to pass a test`. Rows for the `SKILL.md` and agent restatements, if approved, are updated to the new text by the same rule.
- [ ] **Step 4: Run** `./tests/run.sh agent-instructions xreview-skill review agent-skills`: green (passed/total).
- [ ] **Step 5: Mutate the rows this task changed.** Commit, then, in a new state for each attempt with `--ref` set to that commit's SHA, run `audit.py rules` on a TSV holding only those rows. It must exit 0, and `report --section rules` must show every mutant killed. Fix the terms until it does.
- [ ] **Step 6: Commit** `Tighten the testing rule: behaviour over wording, findings tested only when they can recur`.

### Task 15: Validate the final state

**Depends on:** Tasks 12, 13 and 14.

Validation runs against one committed SHA, `<v>` (`git -C <checkout> rev-parse HEAD` after the last edit is committed). Every state in this task is new for that SHA and passes `--ref <v>`. The names are `.superpowers/test-audit-after-<v12>-code`, `-targeted` and `-rules`, where `<v12>` is the SHA's first 12 characters. A repeat after a fix gets a new `<v>`, and so new states. The findings record which `<v>` supplied the final results.

- [ ] **Step 1: Code mutants.**
  - The selection is every file whose own suite this branch changed: `git diff --name-only main...chore/test-audit -- tests/`, joined with `subjects.tsv`.
  - `<before>` is the refresh state for files Task 11 refreshed, and the phase 1 state otherwise.
  - In the `-code` state, run `sample --sample-from <before> --only <selection>`, once per `<before>` with its share of the selection.
  - `report --compare <before> --kind code --only <the same files>` must list nothing `lost` and nothing `not run`.
- [ ] **Step 2: Targeted mutants.** In the `-targeted` state, run `targeted` over a manifest holding only the approved deletions' entries. Every mutant must still be killed, now by an assertion that remains.
- [ ] **Step 3: Rule mutants.** In the `-rules` state, run `rules tests/fixtures/agent-instructions/rules.tsv`, regenerated from the final text at `<v>`. It must exit 0: every approved rule resolves, and none is `missing`. Every approved rule must have at least one mutant. Every mutant must be killed. The only exception is a survivor whose counterpart (same rule id, operator and removed word or item) also survived in the counterpart state, which is `.superpowers/test-audit-refresh-pins` if Task 11 made one and otherwise Task 8's final `.superpowers/test-audit-pins-<n>`; list each one. The tightened testing rule has no counterpart, so all its mutants must be killed.
- [ ] **Step 4: The whole runs.** Run `./tests/run.sh` and `./tests/run.sh xreview git-forge-guard wt-functions`: both green, with passed/total and wall times recorded.
- [ ] **Step 5: Record the after-numbers** beside the before-numbers in the findings, then commit `Record the test audit's after-numbers`. A fix after this step repeats Task 15.

### Task 16: Pre-merge review and push

**Depends on:** Task 15.

- [ ] **Step 1: Whole-branch review.** An `sp-architect` reviews `main...chore/test-audit` against the spec and this plan. Fix its findings, repeating Task 15 for any fix to a suite.
- [ ] **Step 2: Set the Status.** Set the spec's and this plan's Status to `Implemented (branch chore/test-audit; the dotfiles have no MR)`, mark this plan executed once, and commit.
- [ ] **Step 3: Codex pre-merge review.**
  - Run `xreview -C <checkout> round --reset`.
  - Run `xreview -C <checkout> dispatch --checkpoint pre-merge --diff main...chore/test-audit <body-file>`, then collect.
  - Iterate to `approve`. Each round's fixes are committed before the next dispatch.
  - Record the rulings below.
- [ ] **Step 4: Push** with `git -C <checkout> push origin chore/test-audit`, run on its own.
- [ ] **Step 5: Final report to the driver:**
  - the state line;
  - the before and after numbers;
  - the rulings;
  - `wt-rm chore/test-audit` for Michael once the branch is merged;
  - `rm -rf "$TMPDIR/test-audit"` for leftover copies;
  - a `/clear` line.

## Rulings

Rulings made during the run are recorded here, because the dotfiles have no MR. Each gives the decision, why, and the cost if wrong.

- **R1.** `report --compare STATE --kind K [--only …]` works with any `--section`, rules included; its lost and not-run lists print after the section. Task 8 needs it for rules, and validation compares rule mutants the same way. Cost: one more flag combination.
- **R2.** `accept` reads Task 7's classification layout (a header row, labels split on ` | `), and the M8 fixture uses it. Cost: a parser change if Task 7's layout moves.
- **R3.** Implementers do not commit; the controller commits each task after checking the branch. Cost: none.
- **R4.** Task 4 ran beside Task 1: it needs only the `subjects.tsv` format, which the plan fixes. Cost: a format tweak.
- **R5.** The survivor re-run and the `flaky` flag live in Task 2's sample and targeted loops, not in `try`, which writes no state. Cost: moving one call.
- **R6.** The baseline run's own timeout is a constant 1800 s; the spec bounds only the mutant timeout, and the slowest baseline (`xreview`, 672 s) fits. Cost: a flag.
- **R7.** Task 5's inventory and whole-run timings start once Task 1 is approved, beside Tasks 2 and 3; `plan` waits for Task 2. The suite uses its own lock. Cost: re-running `inventory` if a later task changes its rows; the timings carry some implementer load, noted in the findings.
- **R8.** Killers include a failed label that extends a baseline-passed label with ` (` detail (Attribution, above). Twenty FAIL formats in six suites, `git-forge-guard` among them, append `(want …, got …)` or `(rc …)` to the failing label only, so the plan's exact-match rule left those kills with no killer and would have marked their targeted candidates `mis-targeted`. The spec's "a named assertion failed" is unchanged. The driver accepted it with two guards: a prefix that fits two or more baseline labels is `ambiguous` (an ambiguous-only run is `inconclusive`), and every R8 attribution is listed in `via_detail` and marked in the reports and findings, so deletion evidence that rests on it can be traced. Cost: a few kills read as inconclusive; Task 5 checks the inventory's labels for prefix pairs.
- **R9.** No `negate` mutant for a `while` or `until` whose condition is a `read` command: negating it loops forever by construction, so each one is a guaranteed timeout of at least 60 s that carries no information. Cost: those loop conditions get no negate mutant.
- **R10.** `baseline-red` is not a final record: the next session retries those mutants, as the Attribution bullet scopes it to "that session". Suites that stay red become `copy-red` in Task 5. Cost: one baseline run per retry.
- **R11.** Task 2 additions, accepted as built: an unparseable tail is truncated before an append; a survivor's re-run is recorded on its own record (`attempts: 2`, `rerun`); flaky kills count in `killed` and are also counted apart; `accept` joins a manifest candidate to the classification as `<suite>:<test>`; a targeted candidate whose runs are inconclusive gets the verdict `inconclusive`, which `accept` treats as not evidenced. Cost: Task 7's classifiers must name candidates `<suite>:<test>`.
