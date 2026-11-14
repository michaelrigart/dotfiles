# Forge push protection, merge 3: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (merge 3, branch feat/forge-push-protection; pull request held until the verification of spec section 6)

**Goal:** Retire the guard's spelling hunt, make every push of a default branch a silent deny, make
`forge-protection check` judge `main-merge-owner`, and bring the instructions and Michael's steps
in line with revision 3.

**Architecture:** Three code changes on what merges 1 and 2 put on `main`: deletions in the push
helper, its shell fast path and their suite (Task 2), one verdict change in the helper's `evaluate`
(Task 3), and the `update` half of the GitHub target in the check (Task 1). Documentation and
instruction edits follow them (Tasks 4 to 6).

**Tech stack:** Python 3.9 (`/usr/bin/python3`), bash 3.2, jq; suites under `tests/`, run through
`./tests/run.sh` or directly by name.

**Spec:** `docs/superpowers/specs/2026-11-12-forge-push-protection-design.md`, revision 3
(2026-11-14): sections 2.1, 3, 4.1 to 4.4, 6, Residual, Tests, "Revision 3" and "Corrections from
planning merge 3" (M1 to M7, which bind this plan). The map the line numbers below come from was
read at `6fb6ce1`; Task 2's implementer re-reads each range before cutting it.

## Global constraints

- No forge is touched; `forge-protection.sh` runs only through its mocked suite.
- This repository is public: no private host, organisation, client or repository name in code,
  tests or documents. Fixtures use invented names.
- No change adds a permission prompt. Asks are only removed: the default-branch push, a delete of
  the default branch, `--all` and `--mirror` (M5).
- `.chezmoitemplates/agents/global.md` is at its limit of 150 lines: an edit there adds no line.
- Test behaviour, not wording; extend a case before adding one. A removed feature's rows are
  deleted, not skipped. Each retired class keeps one row pinning that the guard is now silent on it.
- Implementers run only the suites of their task (`./tests/git-forge-guard.test.sh` is heavy, about
  four minutes: run it directly, at most twice per round), never the full suite.
- The Bash guard refuses a command line that holds both the word git and the word that names
  sending commits (file names and this checkout's path count): use the Read and Edit tools for
  such files, relative paths, and a character class in shell globs (`pu[s]h`).
- Commit messages: imperative, no agent attribution.

## Review focus

1. A delete of the default branch (`--delete main`, `:main`), and `--all` or `--mirror` with a known
   default branch, must be a silent deny with the section 4.2 reason, never an ask; `--prune` and a
   delete of another branch still ask. Task 3 pins each.
2. A dry run of a default-branch push: outside canonical text, the section 4.2 deny (M6); the
   canonical `git push -n origin main` stays allowed. Task 3 pins both.
3. An ANSI-C quote must not hide a force push to `main` (`git log --grep $'a\'b' ; git push -f
   origin main # '`): `outside_grammar` stays (M4). Task 2 keeps the row.
4. An `update` ruleset whose bypass list is hidden, empty, in another mode or with another actor
   must never read `ok`. Task 1 pins each.
5. A 160 KB padded line must not run the helper past the hook's 60 s timeout (the linear
   `push_shape` and `alias_text_hit`). Task 2 moves the R12 row and the equivalence check out of the
   deleted range.

## Rulings

Recorded here and in the spec's corrections M1 to M7; the driver decided M5 on Michael's
delegation on 2026-11-14, and the rest stand as stated there.

- Row 3557 (`git push origin feat:main` with a secret, "a secret beats an ask") is deleted: the
  section 4.2 deny now comes before the scan. Rows 3545 and 3553 keep the Tests bullet.
- `tests/hook-path.test.sh` drives a default-branch push to reach the scan; it moves to
  `git push --force origin feat` (an ask after the scan) so its hostile-configuration coverage stays.
- `tests/run.test.sh`'s `DRIFT_PART_DIRS` entry `git-forge-guard:dot_claude` and its comment go:
  the only command line it served is in the deleted range.
- `claude-code.md`'s Pushing paragraph stays: it is still true, and with the heavy tag staying (M7)
  nothing in it changes.

---

### Task 1: The check judges `main-merge-owner`

**Depends on:** nothing.

**Files:**
- Modify: `.scripts/forge-protection.sh` (`check_github`, a new `body_main_merge_owner`, the comment
  above `PR_RULE`)
- Test: `tests/forge-protection.test.sh` (section A)

**Interfaces:** Produces `body_main_merge_owner`, printing exactly
`{"name":"main-merge-owner","target":"branch","enforcement":"active","bypass_actors":[{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"pull_request"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"update","parameters":{"update_allows_fetch_and_merge":false}}]}`.
Task 6's steps quote the check's output.

The judgement (spec 2.1, revision 3):

- The rulesets read are those carrying `deletion`, `non_fast_forward`, `pull_request` or `update`.
  An active one that does not show `bypass_actors` makes the row `unreadable`, as today.
- A ruleset is **merge-owner** when it is active, carries `update` and none of the other three, and
  its bypass list is exactly one actor whose `actor_type` is `RepositoryRole`, `actor_id` 5 and
  `bypass_mode` `pull_request` (other keys of the actor ignored).
- The `update` half holds when at least one ruleset is merge-owner and every active ruleset carrying
  `update` is merge-owner. A ruleset that is not active is ignored for this half: it enforces nothing.
- `ok` needs the existing three-rule half and the `update` half.
- Remedies, in this order: the `protect-main` POST and the `main-pr-only` POST as today; the
  `main-merge-owner` POST when no ruleset is merge-owner; the existing UI notes; then, for each
  active ruleset carrying `update` that is not merge-owner, one note:
  - if it also carries `deletion`, `non_fast_forward` or `pull_request`:
    `in the UI: https://github.com/<repo>/rules/<id>: remove Restrict updates; main-merge-owner carries it`
  - otherwise: `in the UI: https://github.com/<repo>/rules/<id>: bypass list only Repository admin, For pull requests only`
- The word `update` never stands on a line that calls `gh`, `gh_get` or `forge_call` (the suite's
  write-verb pin reads those lines).

- [ ] **Step 1: Fixtures and failing rows.** `gh_michael` gains `update` from ruleset 4 with the
  merge-owner actor; `gh_agent` gains ruleset 4 without `bypass_actors`. Rows whose fixture now lacks
  an `update` carrier print the `main-merge-owner` POST too: update their `posts_are` counts and
  assertions. Replace the "update and creation are not part of the target" row (it asserts ruleset 9
  is never read) and line 156's `out_hasnt '"update"'`. New rows, each with `row_is` and `rc_is`:
  - `gh_michael`: `ok`, exit 0;
  - the three rules, no `update`: `drift`, exactly one POST, carrying `"name":"main-merge-owner"`,
    `"bypass_mode":"pull_request"`, `"actor_id":5`, `"type":"update"`, `"include":["~DEFAULT_BRANCH"]`;
  - no ruleset (`'[]'`): two POSTs, `protect-main` then `main-merge-owner`;
  - ruleset 4's list `[]`, `[{User 42 always}]`, the admin in `always`, in `exempt`, the admin in
    `pull_request` plus `User 42`: each `drift`, the "bypass list only" note naming `rules/4`, no POST;
  - `update` carried by closed ruleset 1 and no merge-owner: `drift`, the "remove Restrict updates"
    note naming `rules/1`, one POST (`main-merge-owner`);
  - two merge-owner rulesets: `ok`; an `update` ruleset in `evaluate` beside a merge-owner: `ok`;
  - ruleset 4 without `bypass_actors`: `unreadable` naming ruleset 4; ruleset 4 answering HTTP 404:
    `unreadable` naming HTTP 404.
- [ ] **Step 2: Run** `./tests/forge-protection.test.sh`: the new rows fail.
- [ ] **Step 3: Implement** the judgement and `body_main_merge_owner` in `check_github`.
- [ ] **Step 4: Run** `./tests/forge-protection.test.sh`: all pass, the remedy-execution and zsh
  paste rows included (they now run the `main-merge-owner` line too), and the write-verb pins.
- [ ] **Step 5: Commit** `Judge main-merge-owner in the GitHub target of the check`.

### Task 2: Retire the spelling hunt

**Depends on:** nothing.

**Files:**
- Modify: `dot_claude/git-push-guard.py`, `dot_claude/executable_git-forge-guard.sh`,
  `tests/git-forge-guard.test.sh`, `tests/run.test.sh` (the `DRIFT_PART_DIRS` entry)

**Interfaces:** Produces the helper without `PUSH_GUARD_LITERAL`; Task 3 edits its `evaluate`.

Every range below is named by its contents as well as its lines, since lines move as the task
deletes.

**Helper** (spec 4.4, M2 to M4):
- Delete: the strict-path block (`GLUE_STOP` … `strict_could_push`, about 921–1817); the views and
  decoder block (`READINGS` … `view_could_push`, about 2082–2461); the glob readings (`GIT_NAMES`,
  `GLOB_ONLY`, `case_pattern`, `GLOB_REGEX_MAX` … `glob_git_word`); the built words and
  `dynamic_git_word` (`PUSH_SLOT` … `dynamic_git_word`); the nested shell-string readers
  (`SHELL_NAMES` … `alias_slot_hit`); `literal_trigger`, `strict_only`, `raw_checks_enabled`; the
  dead `PUSH_SHAPE` regex; the `bisect` and `namedtuple` imports.
- Keep: `outside_grammar`, `probe_refuses` (M4); `push_shape`, `alias_text_hit` and their helpers;
  the inert block; `runs_command_string`; everything from `canonical` to `hook_will_run`; the
  fail-closed `return True` when an alias listing fails.
- Change: `could_push` back to main's shape (`inert_text` and `push_shape`; the dash name; `\bgit\b`
  in the text; the `GIT_CONFIG` check; selectors from the top-level tokens; `push_aliases`;
  `alias_text_hit`); `main` without the strict, literal and payload-rest paths (outside the grammar,
  `could_push(...) or probe_refuses(...)` gives the `PLAIN` deny; on an exception, the internal-error
  deny only when `shape is not None or push_shape(cmd)`); `command_words` without its `runners`
  parameter; `odd_command_word` keeps only its dash-name branch, renamed `dash_push_word`; `PLAIN`
  drops "; a word split by quotes or backslashes is read as a hidden push."
- Header: the threat model (about 40–57), the residual list (58–137) and the glob/strict/flag block
  (152–167) become at most eight lines: rule 4 judges the plain push an agent is told to write and
  refuses a literal push it cannot parse (git and push in one segment, M3); anything else is not
  its job, the forge refuses what matters on a protected default branch and the classifier sees
  the rest; the spec's Residual names the remotes the forge does not cover.

**Shell guard:** lines 153–204 (`literal`, `push_hidden`, `push_glob`) become main's two lines,
`push_candidate=0` and `[ "$push_word$push_selector$push_alias" = 000 ] || push_candidate=1`; the
helper call drops `PUSH_GUARD_LITERAL=$literal`; the header's fast-path sentence says the helper
starts only on a literal push word, a selector or an alias.

**Suite** (M1):
- Delete records E, F and G (about 87–143); delete from "spellings the fast path used to miss"
  (about 1599) through the end of "hidden spellings" (about 3380), after moving out what stays:
  `expect_raw` and `rawpayload` with their `G`/`P` fixture (row 3497 calls them); the surrogate and
  unreadable-payload rows (about 1738–1772, less the two that become allows); the `probe_refuses`
  judge-failure row N1 without `PUSH_GUARD_LITERAL=1`; the `outside_grammar` pins (1613–1620 and
  the bypass 1651–1656); the exception unit's "push shape" rows and N7; R12 and the
  `push_shape`/`alias_text_hit` equivalence check.
- Edit, do not delete, the three older sections (about 1464–1597): rows that relied on
  `dynamic_git_word`, the glob readings or the built words (`X=push; git $X …`, `git ${X:-pu}sh …`,
  `/usr/bin/gi? push …`, the `$DOCKER push` and `$G push` rows) take their new verdict, silent or
  main's allow; the glob case-arm and bullet rows (about 1567–1574, 1580–1588), vacuous now, go;
  the dash-branch rows and `runs_command_string` rows stay.
- "Rule 4 costs nothing on commands that do not push" (about 3445–3453): the tripwire asserts that a
  hidden spelling does **not** start the helper. "Fails closed when its helper is missing" (about
  3484–3510): the rows without a literal push word flip to allow; fix its comment.
- `PLAIN_REASON` (about 1006, 1070) follows the new `PLAIN`.
- A section "retired spellings: the guard is silent" with one row per retired class, each a
  command the hunt denied: a normalized view (`cd /tmp; git status; echo pu''sh`), an escape
  (`$'\x67it' push origin --delete wip`), the strict path (`cd /tmp; /usr/bin/[g][i][t] p?sh origin
  main` through the helper), a glob word (`/usr/bin/gi? push origin main`), a built word
  (`$G push origin main`), `dynamic_git_word` (`git ${X:-pu}sh origin main` through the helper), a
  nested shell string (`sh -c 'git -c "a;b" pom'`), and `PUSH_GUARD_LITERAL=0` on
  `git push --force origin feat` (an ask, the flag ignored). Each expects the silent answer; and two
  literal-word rows (`echo $'git push'`, `git ${X:-push} origin main`) expect the `PLAIN` deny.
- Leave every default-branch ask row as it is: Task 3 moves them.

- [ ] **Step 1:** Write the "retired spellings" section; run the suite; its rows fail.
- [ ] **Step 2:** Delete and change the helper and the shell guard as above.
- [ ] **Step 3:** Delete, move and edit the suite as above; drop the `run.test.sh` entry.
- [ ] **Step 4: Run** `./tests/git-forge-guard.test.sh`, `./tests/run.test.sh`,
  `./tests/hook-path.test.sh` and `./tests/git-pre-push-hook.test.sh`: all pass. `wc -l` the three
  files and report the counts.
- [ ] **Step 5: Commit** `Retire the guard's spelling hunt`.

### Task 3: Every push of a default branch is a silent deny

**Depends on:** Task 2 (the same files).

**Files:**
- Modify: `dot_claude/git-push-guard.py` (`evaluate`, a constant, `dry_run_deny`'s docstring),
  `dot_claude/executable_git-forge-guard.sh` (header), `tests/git-forge-guard.test.sh`,
  `tests/hook-path.test.sh`

**Interfaces:** Consumes Task 2's helper.

- `DEFAULT_DENY = "Push guard: the default branch is Michael's; push the branch and open a merge
  request or pull request."`
- In `evaluate`, after the refspec loop, the push touches the default branch when a destination
  names it (the test of today's lines 3036–3039), a delete names it (`--delete`/`-d` with that ref,
  or a `:<default>` refspec, with `refs/heads/` stripped as today), or `--all` or `--mirror` is
  given and `default` is known. Then `raise Deny(DEFAULT_DENY)`, before the merged-delete check, the
  dry-run deny and the scan (M5, M6). The canonical dry run still returns earlier.
- The `asks` entry "it updates <default>, the default branch of <remote>" goes; `--prune`, deletes
  of other branches, force without a lease and `--tags` keep their asks.
- The suite: every row of the map's list (about 520–536, 549, 551, 710–712, 720–721, 798–799, 1157,
  1227–1238 less the canonical 1238, 1304–1313, 1373, 1404, 1454, 1473, 1498, and the moved
  surrogate row) expects the deny with `DEFAULT_DENY`'s text; 1307 checks that text; 3557 goes; the
  header's lines 7–8 say a default-branch push is denied. New rows: `git push --prune origin` and
  `git push origin --delete feat` still ask; `--all` against a remote whose default branch cannot be
  read keeps its ask.
- `tests/hook-path.test.sh`: `COMMANDS` and the control use `git push --force origin feat`, and the
  control still expects the missing-scan reason.

- [ ] **Step 1:** Change the rows; run both suites; they fail.
- [ ] **Step 2:** Implement in `evaluate`; update `dry_run_deny`'s docstring and the shell header.
- [ ] **Step 3: Run** `./tests/git-forge-guard.test.sh`, `./tests/hook-path.test.sh` and
  `./tests/git-pre-push-hook.test.sh`: all pass.
- [ ] **Step 4: Commit** `Deny every push of a default branch`.

### Task 4: The suite's time and tag

**Depends on:** Task 3.

**Files:** `tests/git-forge-guard.test.sh` (line `# test-requires: heavy  # 242 s …`), `AGENTS.md`
(the Testing table row and the sentence naming the four heavy suites).

- [ ] **Step 1:** `./tests/run.sh git-forge-guard` alone, and read its seconds.
- [ ] **Step 2:** Under 60 s: drop the tag, the suite leaves the heavy row and the "run all four by
  name" command of `AGENTS.md`. Otherwise keep it and write the new time in both places (M7).
- [ ] **Step 3: Run** `./tests/run.test.sh` and `./tests/run.sh test-audit` (the drift check and
  the subject map).
- [ ] **Step 4: Commit** `Record the guard suite's time after the retirement`.

### Task 5: The instructions

**Depends on:** nothing.

**Files:** `.chezmoitemplates/agents/global.md` (lines 70–73),
`tests/fixtures/agent-instructions/rules.tsv` (row `g-confirm-first`), `AGENTS.md` (lines 61–62).

- `global.md` 70–73 become exactly:

  ```
  - **Every agent confirms first** before force-pushing without a lease, rewriting history others
    have, deleting branches, tags, data or infrastructure, or discarding uncommitted work it did not
    create. Exempt: a lease on your own branch, a merged branch's pinned delete, `git branch -d`.
    Harness prompts are a backstop, not the check. No agent pushes a default branch.
  ```

- `rules.tsv` `g-confirm-first` pins those four sentences and the fifth.
- `AGENTS.md`: `gh pr merge <number> --merge --admin --match-head-commit <sha>`.

- [ ] **Step 1:** Change `rules.tsv`; `./tests/run.sh agent-instructions` fails.
- [ ] **Step 2:** Edit `global.md` and `AGENTS.md`; `wc -l` shows 150 for `global.md`.
- [ ] **Step 3: Run** `./tests/run.sh agent-instructions`: passes.
- [ ] **Step 4: Commit** `Say no agent pushes a default branch, and merge with --admin`.

### Task 6: Michael's steps and the records

**Depends on:** Task 1 (the check's output) and Task 4.

**Files:** `docs/superpowers/plans/2026-11-12-forge-push-protection-michael-steps.md`, the spec's
"Implementation notes", this plan's Status.

- The steps file: "Where things stand" for 2026-11-14 (merges 1 and 2 applied, GitHub done with
  `main-merge-owner`, GitLab and Azure outstanding); step 12 records `main-merge-owner` as done; a
  new group for merge 3:
  1. before the pull request, his check from the line's checkout,
     `~/.local/share/chezmoi-feat-forge-push-protection/.scripts/forge-protection.sh check; echo "exit $?"`:
     `exit 0`, the GitHub rows `ok` (now judging `main-merge-owner`), the excepted count as in
     step 14; then he tells the line, which opens the pull request;
  2. the merge: `gh pr merge <n> --merge --admin --match-head-commit <sha>`, the pull, `chezmoi apply`;
  3. after the apply, in a new agent session: `./tests/run.sh git-forge-guard` passes, and the check
     from the main checkout still exits 0;
  4. `wt-rm feat/forge-push-protection`.
- The spec's "Implementation notes": merge 3's measured line counts per file against section 4.4's
  expectation, and the suite's time.
- Final pre-merge commit: this plan's Status `Implemented` with the completed banner; the spec's
  Status `Implemented`, citing the pull request from `feat/forge-push-protection`.

- [ ] **Step 1:** Edit the three documents.
- [ ] **Step 2: Commit** `Write Michael's merge 3 steps and record the retirement's size`.
