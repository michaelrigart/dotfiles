# Replay set Amendment 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (plan review pending).

**Goal:** Fix the harness defects and change the two limits that §11.4 found, so a rerun of §4 on the kept
state can pass the coverage gate and its leak scan voids only runs that read something forbidden; then
move the kept state's snapshot out of the driving session's directory.

**Architecture:** Every change stays in `.scripts/process_replay/`, `.scripts/process-replay.py` and their
suite. One new module, `excerpts.py`, builds the file list of every judge-present input (§14.2). One new
module, `relocate.py`, is the `relocate-snapshot` subcommand: it renames the snapshot and rewrites the kept
state's references under the state's exclusive lock (§14.3 a). The leak-scan changes (§14.3 b, c) stay in
`codex.py`'s `_Scan`, the one matcher that Codex rounds, final reviewers and §6's arms share. The
recreation change (§14.4) stays in `inject.Fixpoint` and `gate.recreation`.

**Tech Stack:** Python 3.9 stdlib (`/usr/bin/python3`), git, bash. One test runs the real `chezmoi`
(v2.74.0 here), and one verification step runs the real mise shim.

**Spec:** `docs/superpowers/specs/2026-11-02-replay-set-design.md`, §14 (Amendment 1: Michael's sign-off
2026-11-03, Codex approved xr-1793742614-0a194fb1). Read §11.4 (the causes), §13 (the rulings it amends)
and §14 in full first. §14 fixes the methods, pass bars, coverage gate, one recreation per defect and
judge blindness, and this plan changes none of them. The completed plan
`docs/superpowers/plans/2026-11-02-replay-set.md` holds the shared records and conventions this plan
builds on. Its Part B runbook still holds, except for the paths that "After this plan" below changes.

## Global Constraints

- **Where.** Work in a `wt` checkout of `replay-set` (Michael's), and run every command from its root.
  Touch only `.scripts/`, `tests/` and `docs/superpowers/`. Before Task 1, the controller commits this
  plan and, in the same commit, makes the spec's Status line name both plans (`In progress (plans
  docs/superpowers/plans/2026-11-02-replay-set.md and docs/superpowers/plans/2026-11-03-replay-set-amendment-1.md,
  …)`) and corrects §14.3 (a)'s list of rewritten references to the views' alternates and `branches.json`
  (ruling R10). It then runs Codex's plan review on the committed plan (the `cross-review` skill,
  `--checkpoint plan --diff main...replay-set`), commits each round's fixes before re-dispatching, and puts
  the approving receipt in this plan's Status line.
- **Commits.** Use the imperative mood and no agent attribution. Before each commit, confirm
  `git branch --show-current` prints `replay-set` and read `git diff --cached`.
- **Batches.** Implementers do not commit. Each runs only its own task's test files:
  `/usr/bin/python3 -I -B tests/process-replay/t_<module>.py`, which passes when it prints no `  FAIL:`
  line and exits 0. The controller commits each task on its own, reviews it on that commit, and runs
  `./tests/run.sh process-replay xreview-replay measure-interventions` once per batch (report
  passed/total). The batches:

  | Batch | Tasks | Why they can share a batch |
  |---|---|---|
  | 1 | 1, 2, 3 | disjoint files; `t_checks`/`t_inject`, `t_excerpts` and `t_codex` load none of the other tasks' modules |
  | 2 | 4, 5 | `codex.py` vs `inject.py`/`gate.py`; `t_codex` loads neither, `t_inject`/`t_gate` do not load `codex` |
  | 3 | 6 | it touches `gate`, `inventory`, `loop`, `inject` and `bar`; `t_loop` loads every module |
  | 4 | 7 | it changes `common.py`, which every suite loads |
  | 5 | 8, 9 | `loop.py`/`inject.py` vs `relocate.py`/`process-replay.py`; Task 8 runs `t_loop`/`t_inject`, which do not load the CLI; Task 9 runs `t_relocate`, which loads only the CLI, `relocate` and `common`. `t_e2e` (Task 8 adds one line to it) runs in the batch's full suite |

- **Python.** `#!/usr/bin/python3`, 3.9-compatible (no `match`, no `X | Y`), stdlib only. New package
  modules are mode `100644`. Tests run with `-B`, and no `__pycache__` is ever committed.
- **Real data.** No task (except Task 10) and no test reads or writes the kept state
  `~/.local/state/process-replay/2026-11-03`, either snapshot location, `~/Code/.replay`, an original
  repository, `~/.codex` or `~/.claude`. The suites keep their fixture `HOME`, `XDG_STATE_HOME` and
  `CODEX_HOME` (`helpers.setup`). `helpers.py` does not change: a task that needs fixture code writes it in
  its own test file.
- **Existing failures.** A failure counts as pre-existing only if the same suite fails on this plan's
  commit.
- **Spec values**, used verbatim:
  - Window input (§14.2). A file of up to 60,000 characters is shown whole. A longer one is shown as
    windows of at least 150 lines either side of each anchor, each headed with its line range and the
    file's length, with overlapping windows merged. The total stays at 150,000 characters, with the
    finding's own file first. Windows show no diff and no mark of what changed. A file in which no anchor
    can be located keeps the cut from the top, and the report counts those inputs. The anchors are the
    hunks of the defect's repair (for presence at the round-1 tip, its fix's), located in the tree the judge
    sees, and the finding's line when the finding gives one.
  - Checks (§14.1). `MISE_IGNORED_CONFIG_PATHS` covers the state directory and
    `$XDG_STATE_HOME/review-work/scratch`, set for the check child processes only.
  - Paths (§14.3 a). The snapshot lives at `$XDG_STATE_HOME/process-replay/snapshot/2026-11-02/` and gets
    there by a rename on the same volume. Harness exports live at `$XDG_STATE_HOME/process-replay/harness-<commit>`,
    and each is a forbidden root in every case. `run` refuses to start while a forbidden root lies beneath
    its working directory.
  - chezmoi (§14.3 b). `--version` and `help` read nothing. A call that gives `--source`/`-S` is judged by
    its paths: the source, `--config`, `--cache`, `--persistent-state` and the destination
    (`--destination`/`-D`, default `~`). The destination is a search root unless the subcommand is
    `managed` or `source-path`. Any other call reads the original. The exemption holds only after a test
    against a real chezmoi.
  - Assignments (§14.3 c). `NAME=value` or `export NAME=value` with a literal value adds that value for
    later uses in the same call. It never removes one, and one that may not run still adds. A use with more
    values than the scan expands is a leak. A value that is not literal adds nothing.
  - Recreations (§14.4). Each per-task defect gets one, against the final tree with every other active
    group reverted and docs/superpowers pinned, and its patch and repair are relative to that tree. `locate`
    treats a recreation as it treats a group. `check_invariant` is unchanged, and the fixpoint's bound
    `4*D + G + 1` stays.
  - `run` (§14.5) starts only if the coverage gate passes, or with an explicit option, under which the
    verdict stays inconclusive.

## Review Focus

1. A run's oracle commit inserted lines above a remaining defect, then touched it. Its revalidation window
   must follow the shifted hunk, not the injected tree's line numbers (Task 6,
   `revalidation_window_follows_shift`).
2. The finding's `line` lies past the end of the file the judge sees (October's numbering, a shorter injected
   file). It is ignored as an anchor, the located hunks still give the window, and the input is not counted
   as a fallback (Task 2, `stale_line_ignored`).
3. A long file made of a few huge lines (a minified JSON). A window cannot shrink it, and the 150,000-character
   total still bounds the input (Task 2, `huge_lines_capped`).
4. chezmoi's persistent flags after the subcommand (`chezmoi managed --source <scratch>`, `chezmoi diff -S
   <scratch>`). The source is found wherever it stands, and the verdict follows the subcommand (Task 4,
   `flags_after_subcommand`).
5. A second `inject` over the same answers. It produces the same recreation ids, requests nothing twice and
   rewrites no brief (Task 5, `recreation_replay_stable`).

---

## File structure

| File | Change | Task |
|---|---|---|
| `.scripts/process_replay/checks.py` | `tool_env`; every check runs with it | 1 |
| `.scripts/process_replay/excerpts.py` | **new**: the one judge-present file list (windows, anchors, fallback record) | 2 |
| `.scripts/process_replay/codex.py` | assignments (3); the chezmoi rule (4); snapshot home, exports, `beneath` (7) | 3, 4, 7 |
| `.scripts/process_replay/gate.py` | recreation against a base (5); window input (6) | 5, 6 |
| `.scripts/process_replay/inject.py` | env (1); base, request timing, units (5); anchors to judges (6); coverage line (8) | 1, 5, 6, 8 |
| `.scripts/process_replay/inventory.py` | presence input through `excerpts` | 6 |
| `.scripts/process_replay/loop.py` | revalidation through `excerpts` (6); `run`'s refusals (8) | 6, 8 |
| `.scripts/process_replay/bar.py` | the fallback count in the report | 6 |
| `.scripts/process_replay/common.py` | `snapshot_home`, `harness_root`; lock wording | 7 |
| `.scripts/process-replay.py` | snapshot default, lock wording (7); `relocate-snapshot` (9) | 7, 9 |
| `.scripts/process_replay/relocate.py` | **new**: `relocate-snapshot` | 9 |
| `tests/process-replay.test.sh` | the new modules in its files-under-test list | 2, 9 |
| `tests/process-replay/t_*.py` | each task's own; `t_excerpts.py`, `t_relocate.py` new | each |

## Shared records (what changes)

- **Recreation ids.** A recreation is `<defect>-<first 12 hex of its base tree id>`. Every recreation
  file uses that id: `recreate/<rid>.json`, `.brief.md`, `recreate/<rid>/tree`, `recreate/<rid>/done`,
  `recreated/<rid>.patch` and `.repair.patch`. The kept state's `recreate/<defect>…` files (made against the
  final tree) are never asked for again, and they stay where they are. `cleanup` already works by basename.
- **Units.** In `injected/<branch>.json`, a defect's `group` is its unit's id (the smallest member id), and
  its `repair` is the unit's repair. The members of one unit share group, repair bytes and hunks.
  `loop.oracle` (one repair per group, the others censored) is unchanged.
- **Fallback record.** `<state>/cuts/judge-present/<question id>.json` = `{site, files}`, written only when
  a file was cut from the top for want of an anchor. `site` is one of `presence`, `validation` or
  `revalidation`. `report.json` gains `cut_inputs: {presence, validation, revalidation}`.

---

### Task 1: Checks ignore the work tree's mise configuration (§14.1)

**Depends on:** none.

**Files:**
- Modify: `.scripts/process_replay/checks.py` (`_run_check`, `coherent`, `cargo_check`, docstring),
  `.scripts/process_replay/inject.py` (`Fixpoint.__init__` and the two `K.coherent` calls in `build`)
- Test: `tests/process-replay/t_checks.py`, `tests/process-replay/t_inject.py`

**Interfaces:**
- Produces: `checks.tool_env(state: str) -> dict`, which is `os.environ` plus
  `MISE_IGNORED_CONFIG_PATHS` = `":".join` of `os.path.abspath(state)`,
  `os.path.join(L.state_home(), "review-work", "scratch")` and then the entries of an inherited value, with
  duplicates dropped. It never changes `os.environ`. Next, `coherent(work, files, env, notes=None)`, where
  `env` is required so no caller can forget it, and `_run_check(argv, cwd, notes, env)`.
  `cargo_check(a, work, repo_name)` keeps its signature and runs with `tool_env(a.state)` plus
  `CARGO_TARGET_DIR`. Finally, `Fixpoint.env = K.tool_env(a.state)`, which both `coherent` calls pass.

- [ ] **Step 1: Write the failing tests.** Each file writes its own stub shim (a bash script installed as
  `python3`, `ruby` and `cargo` in a temp bin directory put first on `PATH`). The stub walks up from `$PWD`
  to the nearest `mise.toml`. Unless that file's directory lies at or under an entry of the colon-separated
  `MISE_IGNORED_CONFIG_PATHS`, it prints `mise ERROR Config files in <dir>/mise.toml are not trusted.` on
  stderr and exits 1; otherwise it exits 0. This models the real shim, as measured on 2026-11-03. `t_checks.py`:
  - `tool_env_paths`: with `MISE_IGNORED_CONFIG_PATHS=/inherited` in `os.environ`,
    `tool_env(S)["MISE_IGNORED_CONFIG_PATHS"].split(":") == [abspath(S), $XDG_STATE_HOME/review-work/scratch,
    "/inherited"]`, and `os.environ` still holds `/inherited` afterwards. With nothing inherited, the list
    has two entries.
  - `untrusted_mise_toml` (§14.6): use a tree `S/work/b` holding `mise.toml`, `ok.py` and `ok.rb`, with the
    stub first on `PATH`. `coherent(W, ["ok.py", "ok.rb"], tool_env(S)) == (True, "")`. With `os.environ`
    minus `MISE_IGNORED_CONFIG_PATHS` it returns `(False, "ok.py: mise ERROR Config files in … are not
    trusted.")`, which is §11.4's failure and shows the stub is live.
    `cargo_check(Namespace(state=S, budget=60), W, "r")[0] is True`.
  - The existing `coherent` cases pass `tool_env(STATE)`.

  `t_inject.py`:
  - `mise_config_ignored`: use a branch whose final tree has a root `mise.toml` and a per-task fix of
    `src/m.py`, with the stub first on `PATH`. After `inject` and a `yes`, the defect is `present`, not
    `incoherent`. This catches an inject call site that drops the env.
- [ ] **Step 2: Run** both files. They fail (`AttributeError: … has no attribute 'tool_env'`).
- [ ] **Step 3: Implement** as Interfaces says.
- [ ] **Step 4: Check the variable against the real mise** (nothing is committed). Make a temp dir holding
  a `mise.toml` with `[env]` and `REPLAY_PROBE = "1"`. With `command -v python3` resolving to a mise shim,
  `python3 -c 'print(1)'` fails with "are not trusted", and
  `MISE_IGNORED_CONFIG_PATHS="/elsewhere:<the dir's parent>" python3 -c 'print(1)'` prints `1`. A preview on
  2026-11-03 matched. If python3 is not a shim, or the sandbox denies it, say so in the report.
- [ ] **Step 5: Run** both files. They pass.
- [ ] **Step 6: Commit.** `Run the build checks with the work tree's mise configuration ignored`

### Task 2: The window input (§14.2)

**Depends on:** none.

**Files:**
- Create: `.scripts/process_replay/excerpts.py`, `tests/process-replay/t_excerpts.py`
- Modify: `tests/process-replay.test.sh` (add `excerpts.py` to its files under test)

**Interfaces:**
- Consumes: `common.cap`, `common.norm`, `common.jsave`, `patches.parse_patch`, `patches.item_list`,
  `patches.select`, `patches.locate`.
- Produces (Task 6 wires them in):
  - `FILE_CAP, TOTAL_CAP, CONTEXT = 60000, 150000, 150`; `SITES = ("presence", "validation", "revalidation")`.
  - `paths_of(d) -> list[str]`, moved here from `gate.paths_of` unchanged: the finding's file, then the
    files its fix changes.
  - `anchors(finding: dict, hunks: list) -> dict` returns `{path: [(start, end)]}`. It holds each hunk's
    `(start, end)` under its `file`, and `(line, line)` under `norm(finding["file"])` when `line` is an int
    ≥ 1 (bool excluded).
  - `located(repo: str, rev: str, patch: str) -> list` returns `[{file, start, end}]`. Each file section of
    `patch` is located on its own with `patches.locate` (applying `patches.select` of that section), and a
    section that does not apply at `rev` adds nothing.
  - `windows(text: str, marks: list) -> str | None` returns the windowed text, or None when no mark falls
    within the file's lines.
  - `files_input(names: list, read, marks: dict) -> (list, list)`, where `read(path) -> str | None`. It
    returns `[{path, text}]` in `names` order, and the paths cut from the top for want of an anchor.
  - `note_cut(state, jid, site, cut) -> None` writes `<state>/cuts/judge-present/<jid>.json` = `{site,
    files}` when `cut` is non-empty. `count_cuts(state) -> dict` returns `{site: inputs}` for each site in
    `SITES`.
- What the signatures leave open:
  - Lines are counted as git counts them: split on `"\n"` only, with a last line that lacks `"\n"` still
    counting. `str.splitlines` would also split on `\r`, `\x0c` and `\u2028`.
  - A mark `(s, e)` overlapping `1..n` gives `[max(1, s - 150), min(n, e + 150)]`. A mark wholly outside
    `1..n` is dropped.
  - Windows that overlap or touch (`b.start <= a.end + 1`) merge. Each window is the line
    `[lines <a>-<b> of <n>]` followed by lines a..b as they are.
  - In `files_input`, `room` starts at `TOTAL_CAP`:
    - Text of ≤ `FILE_CAP` characters is `cap(text, min(FILE_CAP, room))`, byte for byte what the three
      copies it replaces produce, so unchanged inputs keep their ids and answers.
    - A longer text with windows is `cap(windows, room)`.
    - A longer text without windows is `cap(text, min(FILE_CAP, room))`, and its path joins `cut`.
    - A name that `read` gives None for is skipped, and the loop stops once `room <= 0`.

- [ ] **Step 1: Write the failing tests.** The fixture `big.txt` has 3000 lines of 31 characters
  (`line 0001 …`, about 93,000 characters).
  - `short_file_unchanged`: a 500-character file gives `([{"path": "a.py", "text": <the file>}], [])`,
    whatever the marks.
  - `one_window`: `{"big.txt": [(1000, 1002)]}` gives text equal to `"[lines 850-1152 of 3000]\n"` plus
    lines 850–1152. It contains neither `line 0849` nor `line 1153`.
  - `windows_merged`: `(1000,1000)` and `(1250,1250)` give one header, `[lines 850-1400 of 3000]`.
    `(100,100)` and `(2000,2000)` give two headers in that order. `(100,100)` and `(401,401)` touch and give
    one window, `[lines 1-551 of 3000]`.
  - `edges_clamped`: `(10, 10)` gives `[lines 1-160 of 3000]`; `(2990, 2995)` gives
    `[lines 2840-3000 of 3000]`.
  - `fallback_counted`: a long file with no mark gets `cap(text, 60000)` (ending `\n[truncated]\n`) and
    `cut == ["big.txt"]`. `note_cut(S, "q1", "validation", cut)` then `count_cuts(S)` gives
    `{"presence": 0, "validation": 1, "revalidation": 0}`. `note_cut` with `[]` writes nothing.
  - `total_cap_finding_first`: names `["own.txt", "big.txt", "c.txt"]`, where `own.txt` and `big.txt` are
    long with a mark every 250 lines. `own.txt` comes first as one window `[lines 1-3000 of 3000]`,
    `big.txt` is cut to the room left (ending `[truncated]`), and `c.txt` is absent.
  - `git_lines`: in a long file with a CRLF line, a form feed and a `\u2028` inside lines, and no final
    newline, a mark on line N shows line N as `git show` numbers it, and n counts the last line.
  - `anchors_of`: `anchors({"file": "./a.py", "line": 7}, [{"file": "b.py", "start": 3, "end": 5}]) ==
    {"a.py": [(7, 7)], "b.py": [(3, 5)]}`. A `line` of None, 0, `"7"` or True adds nothing.
  - `located_per_section`: for a two-file patch whose second file's context does not match the tree,
    `located` gives the first file's hunks only.
  - `stale_line_ignored` (Review Focus 2): marks `[(5000, 5000), (1000, 1000)]` give one window around
    1000, and `cut == []`.
  - `huge_lines_capped` (Review Focus 3): a 4-line file of 70,000-character lines with a mark on line 2
    gives `[lines 1-4 of 4]` capped at 150,000 characters with `[truncated]`.
- [ ] **Step 2: Run** `t_excerpts.py`. It fails (no module).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it. It passes.
- [ ] **Step 5: Commit.** `Show a judge a long file around the defect, not from the top`

### Task 3: Literal assignments add values within a call (§14.3 c)

**Depends on:** none.

**Files:**
- Modify: `.scripts/process_replay/codex.py` (`_expand`, `_Scan.__init__`, `resolved`, `dirs`, `simple`;
  the docstring's known limits)
- Test: `tests/process-replay/t_codex.py`

**Interfaces:**
- Produces:
  - `LITERAL`, a sentinel value meaning "this variable may also hold what the scan does not know, so keep
    its spelling".
  - `TOO_MANY = "{} (more values than the scan expands)"`, a leak label.
  - `_expand(token, values) -> (list[str], bool)`, which returns the results and False when expanding would
    exceed `MAX_EXPANSIONS`.
  - A `_Scan` holds its own copy of `values`. `named()` makes one `_Scan` per tool call, so an assignment
    never carries to the next call.
- Rules:
  - An assignment is a word matching `ASSIGNMENT` that stands before a simple command's effective command
    (a bare assignment, a prefix assignment, or `env NAME=value`), or an argument of `export`. Its value is
    literal when, after quote removal, it holds no `$`. `_logical` already turned backticks into `$(`.
  - `_Scan.simple` records a command's assignments before it scans the command's words. The command's own
    later words (`SRC=x sh -c 'cat $SRC'`) and every later command of the call see the value, and so do
    heredoc bodies, which are scanned last.
  - A known variable (`HOME`, `XDG_STATE_HOME`, `XDG_DATA_HOME`, `CODEX_HOME`, `PWD`) keeps its values and
    gains the literal. An unknown one gets `[LITERAL, value]`.
  - `resolved()` adds `TOO_MANY.format(token)` to `found` when `_expand` is incomplete. `dirs()` does the
    same when a cd leads to more than `MAX_CWDS` directories; today it silently keeps four.
  - A use that stands before its assignment in the text is not affected ("later in its text"). The
    docstring's known limits gain "a loop body that runs a use again after a later assignment", and change
    "a variable set earlier" to "a variable set in another call, or to a value that is not literal".

- [ ] **Step 1: Write the failing tests** (the existing `leaked`/`forbid` helpers and the `CHZ` wall).
  - `assignment_within_call` (§14.6): `D=~/.local/share; cat $D/chezmoi/AGENTS.md` names
    `~/.local/share/chezmoi`. Today `$D` stays literal and the call is clean. The same holds for
    `export D=~/.local/share; …`, for the prefix form `D=~/.local/share sh -c 'cat $D/chezmoi/x'`, and for
    `echo $(D=~/.local/share; cat $D/chezmoi/x)`.
  - `assignment_not_across_calls` (§14.6): one turn holding two function calls, `D=~/.local/share` and then
    `cat $D/chezmoi/AGENTS.md`, gives `[]`.
  - `assignment_never_hides` (§14.6): `false && HOME=/tmp; cat "$HOME/.codex/x"` still names `~/.codex`
    (fwall), as do `(HOME=/tmp); cat $HOME/.codex/x` and `XDG_STATE_HOME=/tmp; cat $XDG_STATE_HOME/xreview/x`
    (the real one). This catches an implementation that replaces a variable's values.
  - `unknown_keeps_spelling`: `K._expand("$D/x", {"D": [K.LITERAL, "/a"]})` gives
    `["$D/x", "/a/x"]` (in any order) and True.
  - `too_many_values`: seventeen assignments, `A=/a1; …; A=/a17; cat $A/x`, give the leak
    `"$A/x (more values than the scan expands) in t1"`. Five `D=/dN;` then `cd $D && ls` give a `TOO_MANY`
    leak.
- [ ] **Step 2: Run** `t_codex.py`. The new cases fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it. It passes, the existing cases included.
- [ ] **Step 5: Commit.** `Let a literal assignment in a tool call give its variable a value in the leak scan`

### Task 4: chezmoi judged by what it names (§14.3 b)

**Depends on:** Task 3 (codex.py; the `$SRC` case needs assignments).

**Files:**
- Modify: `.scripts/process_replay/codex.py` (`named`, `_Scan.script`, `_Scan.simple`, new `_chezmoi`,
  `_runs` removed, docstring)
- Test: `tests/process-replay/t_codex.py`

**Interfaces:**
- Produces:
  - `CHEZMOI_VALUED`, the value-taking global flags of chezmoi v2.74.0's `chezmoi help`: `--age-recipient
    --age-recipient-file --cache --color -c --config --config-format -D --destination --mode -o --output
    --override-data --override-data-file --persistent-state --progress -S --source --use-builtin-age
    --use-builtin-git -W --working-tree`.
  - `CHEZMOI_FLAGS`, its boolean flags: `--debug -n --dry-run --error-on-conflict --force --interactive -k
    --keep-going --less-interactive --no-pager --no-tty -R --refresh-externals --skip-secrets --source-path
    --use-builtin-diff -v --verbose`. `--refresh-externals` takes a value only as `--refresh-externals=x`.
  - `SOURCE_ONLY = ("managed", "source-path")`.
  - `_chezmoi(plain: list) -> (str, list)`, where `plain` is the effective words without redirections. It
    returns one of:
    - `("none", [])` when `--version` stands before any operand, or the subcommand is `help`;
    - `("original", [])` when no `-S`/`--source` stands anywhere (glued `-Sx` and `--source=x` included);
    - `("paths", roots)`, where `roots` is every source value, then the destination (the last
      `-D`/`--destination` value, else `"~"`). The destination is left out only when the subcommand is in
      `SOURCE_ONLY` and every option before it is in `CHEZMOI_VALUED` or `CHEZMOI_FLAGS`. After an unknown
      option the subcommand cannot be told, so the destination stays.
  - `_Scan.simple(words, cwds, depth, piped=False, running=True)`: when `running`, and the effective
    command's basename is a root's TOOLS word, "original" adds that root's label and "paths" reads each
    root as a search root (`self.search`, which judges the path too). `--config`, `--cache` and
    `--persistent-state` are words of the command, judged as paths as every word already is.
  - `_Scan.script(command, cwds, depth=0, running=True)`: heredoc bodies are scanned with
    `running=False`, so their paths are read and their commands are not run, which is what the existing
    heredoc tests pin. `running` passes down into `sh -c` and `$( )`.
  - `named()` stops calling `_runs`, which has no other caller and is removed.
- Ruling R2: the source is read as a search root too, because chezmoi walks it.

- [ ] **Step 1: Write the failing tests** (`CHZ`, `fc`, `leaked` as in the existing tool_words cases;
  `SCR` is the scratch the call runs in).
  - `version_and_help`: `chezmoi --version`, `chezmoi help` and `chezmoi help diff` give `[]`.
  - `source_into_scratch_managed` (§14.6): `chezmoi --source {SCR} managed`, `chezmoi -S {SCR} managed`,
    `chezmoi --source={SCR} source-path x` and `chezmoi -S. managed` give `[]`, and so does
    `SRC={SCR}; chezmoi --source "$SRC" managed`.
  - `default_destination_search_root` (§14.6): `chezmoi --source {SCR} diff` gives `CHZN`, because the
    default destination `~` holds the original. `chezmoi --source {SCR} --destination {SCR}/home diff` and
    `chezmoi -S {SCR} -D{SCR}/home diff` give `[]`.
  - `source_judged`: `chezmoi --source ~/.local/share/chezmoi managed` gives `CHZN`. So does
    `chezmoi --source ~ managed`, as a search root only (R2).
  - `no_source_reads_original`: `chezmoi managed` and `chezmoi --destination {SCR} managed` give `CHZN`.
    The existing tool_words cases keep their expectations.
  - `unknown_option`: `chezmoi --frobnicate --source {SCR} managed` gives `CHZN`;
    `chezmoi --color on --source {SCR} managed` gives `[]`.
  - `records_2026_11_03`: 7f3b624a's two kinds of call, `chezmoi --version` and
    `chezmoi --source {SCR} managed`, give `[]`. 3819843a's two kinds,
    `git -C ~/.local/share/chezmoi log` and `ls ~/.claude/skills` (a dotfiles-case wall), still leak.
  - `flags_after_subcommand` (Review Focus 4): `chezmoi managed --source {SCR}` gives `[]`;
    `chezmoi diff -S {SCR}` gives `CHZN`.
  - `real_chezmoi_source_only`, the spec's test against a real chezmoi.
    - Find the binary with `shutil.which("chezmoi")`. If there is none, print one FAIL line:
      `no chezmoi on PATH: the exemption is not shown`.
    - In a temp dir, set up a source holding `dot_bashrc` and `private_dot_config/app/settings.toml`, a
      destination holding `.bashrc`, an empty `chezmoi.toml`, a cache dir and a persistent-state path.
    - Run each subcommand of `SOURCE_ONLY` (`managed`; `source-path <dest>/.bashrc`) and the control
      `status` as `chezmoi --source S --destination D --config C --cache K --persistent-state P --no-tty
      --no-pager <sub>`, twice: once with D readable, then with D at mode 000 (restored in `finally`).
    - A `SOURCE_ONLY` subcommand passes when both runs exit 0 with the same output. The control must
      differ, in exit status or output; if it does not, the test FAILs because the probe cannot see a read.
- [ ] **Step 2: Run** `t_codex.py`. The new scan cases fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it until every case passes. **If `real_chezmoi_source_only` fails for a
  subcommand,** that failure decides, and nothing else does:
  - Remove the subcommand from `SOURCE_ONLY`.
  - Change its `source_into_scratch_managed` cases to expect `CHZN` with the default destination and `[]`
    with an explicit scratch destination.
  - Record it as ruling R3 in this plan and in the commit message.

  A preview on 2026-11-03 (v2.74.0) passed both subcommands, and the control failed with
  `lstat …: permission denied`.
- [ ] **Step 5: Commit.** `Judge a chezmoi call by the paths it names`

### Task 5: Recreations made against the injected tree (§14.4)

**Depends on:** Task 1 (inject.py, t_inject.py).

**Files:**
- Modify: `.scripts/process_replay/gate.py` (`recreation`, `tree_patches`, new `recreation_id`,
  docstring), `.scripts/process_replay/inject.py` (`Fixpoint`: new `recreation_base`; `second_attempts`,
  `locate`, `resolve`, `repair`, `run`; module docstring)
- Test: `tests/process-replay/t_inject.py`, `tests/process-replay/t_gate.py`

**Interfaces:**
- Produces:
  - `gate.recreation_id(did, tree) -> str` returns `"<did>-<tree[:12]>"`.
  - `gate.recreation(a, work, base, d, fix_text, counts) -> dict` returns today's dict plus `rid`, where
    `base` is a commit of `work`. Its tree is an export of `base`, and its patches come from
    `tree_patches(work, base, tree_dir)` (base's tree against the edit). Its judge-same question keeps the
    defect id as prefix.
  - `Fixpoint.recreation_base() -> str` returns a commit: the final tree with the pieces of every group in
    `self.reverted()` reverted (as `build` reverts them; they passed this round's checks) and
    docs/superpowers pinned, with no recreation applied. It leaves the work tree at the round's head.
  - `Fixpoint.second_attempts()` works as today. It builds `recreation_base()` once, when the round's
    first request is due, and notes `("recreate", rid)`.
  - `Fixpoint.repair(did) -> (unit id, unit repair | None)`. `steps()` and `check_invariant` are
    unchanged.
- Rules:
  - **When a recreation is requested (ruling R1).** Only in a round whose judge answers are all in and in
    which no defect leaves: `run()` calls `second_attempts` after the `gone` check, not before. That round's
    `recreation_base()` is the base.
  - **Held defects** keep §13's rule. The settle-time reason becomes `its group's revert stays in the tree
    for another member`.
  - **Units at locate:**
    - A unit is a set of steps (reverted groups and recreations in the tree), one step each at first. Its
      repair is its steps' repairs in `steps()` order.
    - When a unit's repair does not apply to the head, `locate` tries each recreation unit in the tree (on
      trial too), the last applied first, with that unit's repair applied first. The first one that makes it
      apply joins it, and locating continues in the same round. A join changes no tree, so it costs no
      round, and the bound `4*D + G + 1` holds.
    - A unit no join helps goes to `resolve` as a group does today: merge with an older group, blame the
      trials when trials are on, else its members leave.
    - Joins only grow. A recreation that leaves the tree leaves its unit, and the defect is out for good.
  - **Kept recreations.** The kept state's `recreate/<did>…` files were made against the final tree. They
    are never asked for again, and they stay. `pending` leaves them out (`needed.json`).

- [ ] **Step 1: Write the failing tests.** The fixture is a branch whose `a.txt` has 40 lines
  `l1`…`l40`, with three fixes in separate commits and groups: A (per-task) changes line 10 `A bad`→`A good`,
  B (per-task) changes line 15 `B bad`→`B good`, and C (pre-merge) changes line 35. A and B revert
  independently, five lines apart. `t_inject.py`:
  - `recreation_against_round_tree`: answer A `no` and B and C `yes`. Once a round is settled,
    `recreate/<rid A>/tree/a.txt` has `B bad` on line 15, `A good` on line 10 and `C bad` on line 35.
    Its `docs/superpowers` equals the plan commit's, and the rid is `recreation_id(A, <that commit's tree
    id>)`.
  - `sibling_context_applies_and_merges` (§14.6): the agent's edit puts `A bad` back on line 10 and changes
    line 12 to `l12 # by hand` (written by the test, then `done`). Judge-same and judge-present answer
    `yes`, and B and C answer `yes` again on the changed file.
    - A is `recreated`. Under the final-tree rule this edit's context would hold `B good` and could not
      apply: §11.4 item 4.
    - B's repair alone does not apply to the head, but applies after A's recreation repair. So A and B
      carry the same `group`, the same repair bytes and the same hunks.
    - `inject` completes, so `check_invariant` held, and that repair applied to the work commit gives the
      final `a.txt`.
  - `settled_round_requests` (R1): while the round's answers are pending, no `recreate/` item exists. In a
    round where another per-task defect D (another file) leaves beside A, none is requested either. The
    next settled round requests A with a base whose D file is the final one.
  - `stale_recreation_out_for_good`: after A is recreated, B's question is asked again on the changed file
    and answered `no`. A's recreation no longer applies, so A is `unassessable` with "the recreation does not
    apply to the injected tree", and no second `recreate/` item is written for A.
  - `old_recreation_set_aside`: a state already holds `recreate/<A>.json`, `.brief.md`, `<A>/tree`,
    `<A>/done` and `recreated/<A>.patch` from the final-tree rule. `inject` asks for `recreate/<A>-<hex>`,
    the old files are byte-identical afterwards, and `pending` lists only the new item.
  - `recreation_replay_stable` (Review Focus 5): a second `inject` with no new answer writes no
    `recreate/` item and rewrites no brief (a listing with mtimes is unchanged).
  - Existing tests: every `recreate/<did>` path becomes the rid, through a helper `rid_of(state, did)` that
    returns the single `recreate/<did>-*.json`'s id. Some tests pin a request in a round whose answers are
    still pending, and they now expect it once the round's answers are in (R1). These are at least "…gets
    its recreation request at once…" (S5), "waiting: a defect with no fix range is out from the start and
    its recreation is requested" and the S41b waiting case after it. Any other test that reads
    `inputs(S, "recreate")` while its round still waits moves that read after the answers. The commit
    message names each test whose expectation changed. Nothing else changes.

  `t_gate.py`:
  - `recreation_patches_against_base`: `tree_patches(work, base, dir)` diffs against base's tree. An edit
    of a file the base already reverted shows only the edit.
- [ ] **Step 2: Run** both files. The new cases fail.
- [ ] **Step 3: Implement.** Update the docstrings of `inject.py` (the fixpoint and "Why it ends", which
  now counts joins as free) and `gate.py` (the recreation files).
- [ ] **Step 4: Run** both files. They pass.
- [ ] **Step 5: Commit.** `Make each recreation against the round's injected tree and join it to what its repair needs`

### Task 6: Window inputs at every judge-present site, and their count (§14.2)

**Depends on:** Task 2 (excerpts), Task 5 (gate.py, inject.py), Task 4 (`t_loop.py` loads codex.py).

**Files:**
- Modify: `.scripts/process_replay/gate.py` (`files_input`, `validate`; `paths_of` and the caps removed),
  `.scripts/process_replay/inject.py` (`Fixpoint.judge`, its call in `run`),
  `.scripts/process_replay/inventory.py` (the presence input; `_files_input` and `FILE_CAP` removed),
  `.scripts/process_replay/loop.py` (`_files`, `_open_valid`, new `_anchors`; the caps removed),
  `.scripts/process_replay/bar.py` (report)
- Test: `tests/process-replay/t_gate.py`, `t_inject.py`, `t_inventory.py`, `t_loop.py`, `t_bar.py`

**Interfaces:**
- Consumes: Task 2's `excerpts.*`.
- Produces:
  - Validation:
    - `gate.files_input(work, rev, d, hunks) -> (files, cut)`: names `excerpts.paths_of(d)`, read through
      `git show <rev>:<path>` (None when absent), marks `excerpts.anchors(finding(d), hunks)`.
    - `gate.validate(state, work, rev, d, hunks, counts) -> (jid, verdict)` notes the cut under `jid` with
      site `validation`.
    - `Fixpoint.judge(head, ids, located)` passes `located.get(did, [])`.
  - Presence (inventory): the input's files are `excerpts.files_input([norm(f["file"])], lambda p:
    repo.file(<round-1 tip>, p), anchors(f, excerpts.located(repo.view, <round-1 tip>, P.fix_patch(repo.view,
    <tip k>, <tip k+1>))))`. The file set is the same as today (ruling R5), and site `presence` is noted
    under `<nonce>-<i>`.
  - Revalidation (loop):
    - `loop._anchors(run, did) -> list` gives the run's hunks of `did`, followed from `base_tip` to `HEAD`
      with `_hunks`/`_shift` as `touched` follows them.
    - `loop._files(run, did, ctx) -> (files, cut)`.
    - `_open_valid` notes site `revalidation`.
  - Report (bar): `report.md` gains the line `judge-present inputs cut from the top (no anchor located): N
    (presence a, validation b, revalidation c)`, and `report.json` gains `cut_inputs`.

- [ ] **Step 1: Write the failing tests.**
  - `t_gate.py`: update the `files_input` and `validate` cases to the new signatures.
    - `validate_window`: a `big.py` of 3000 lines with a hunk at 2000–2000 gives a text starting
      `[lines 1850-2150 of 3000]`, and no `cuts/` record.
    - `validate_fallback`: with no hunk in `big.py` and `line` null, the text is cut from the top and
      `cuts/judge-present/<jid>.json == {"site": "validation", "files": ["src/big.py"]}`.
    - `cut_reasked_old_kept`: an answer already given to the cut-from-top question stays on disk under its
      old id, and the windowed question has a new id.
  - `t_inject.py`, `validation_uses_located_hunks`: on a branch whose injected `big.py` (3000 lines) holds a
    per-task revert at line 2000, the fixpoint's judge-present input shows the window around 2000. This
    catches a call site that passes no hunks.
  - `t_inventory.py`:
    - `presence_window`: a round-2 known-real finding in a 3000-line `big.py` whose fix changes line 2000
      gives a presence input that starts `[lines 1850-2150 of 3000]`.
    - `presence_short_unchanged`: a finding in a short file gives an input byte-identical to today's
      `[{"path", "text"}]`, and its `.digest` mark and answer stay as they were.
    - `presence_fallback`: a fix that does not apply at the round-1 tip, with `line` null, gives a cut from
      the top and a record with site `presence`.
  - `t_loop.py`, `revalidation_window_follows_shift` (Review Focus 1): in a case with X's hunk at line
    2000 of a 3000-line file, the matched Y's repair inserts 400 lines at line 100 and edits line 2000.
    X's revalidation input is windowed at `[lines 2250-2550 of 3400]`.
  - `t_bar.py`, `report_counts_cut_inputs`: records for two presence inputs and one revalidation input give
    that line with `3 (presence 2, validation 0, revalidation 1)`, and the same in `report.json`.
- [ ] **Step 2: Run** the five files. The new cases fail.
- [ ] **Step 3: Implement.** Remove the three old copies of the cut (`gate.files_input`'s body,
  `loop._files`'s, `inventory._files_input`) and their caps, so `excerpts` is the only place the rule lives.
- [ ] **Step 4: Run** the five files. They pass.
- [ ] **Step 5: Commit.** `Build every judge-present input with the window input and count the fallbacks`

### Task 7: The snapshot's new home, the exports forbidden, the lock wording (§14.3 a)

**Depends on:** Task 4 (codex.py, t_codex.py), Task 6 (it changes `common.py`, which every suite loads, so it
runs alone).

**Files:**
- Modify: `.scripts/process_replay/common.py` (`snapshot_home`, `harness_root`; module docstring and
  `command_locks` docstring), `.scripts/process_replay/codex.py` (`SNAPSHOT` removed; `exports`,
  `forbidden`, new `beneath`; docstring), `.scripts/process-replay.py` (`snapshot_root_default`, the
  `--snapshot-root` default, docstring)
- Test: `tests/process-replay/t_common.py`, `t_codex.py`, `t_final.py`

**Interfaces:**
- Produces:
  - In `common`: `snapshot_home() -> str` = `os.path.join(L.state_home(), "process-replay", "snapshot")`,
    and `harness_root() -> str` = `os.path.dirname(SCRIPTS)`, the running harness's checkout or export.
  - `codex.exports() -> list[str]`: `[C.harness_root()]` plus the sorted existing directories
    `$XDG_STATE_HOME/process-replay/harness-*` (ruling R4).
  - `codex.forbidden()` roots, in this order: objects, view, state; review-work, `C.snapshot_home()`,
    `snapshot_root` when given; `exports()`; ANSWERS; xreview, cxh; memwatch for §6.
  - `codex.beneath(cwd, bounds) -> list[str]`: the labels of the roots of `bounds` whose real path is at or
    below `cwd`'s real path (component prefix).
  - `process-replay.py`'s `snapshot_root_default() -> str` = `os.path.join(common.snapshot_home(),
    "2026-11-02")`.
- Wording, as §13's lock bullet now reads:
  - `process-replay.py`: "A command that finds a lock held in a mode that conflicts with its own exits 1,
    naming it, before it has changed anything."
  - `common.py`'s module docstring: "a lock held in a conflicting mode is a refusal at once, never a wait".
  - `command_locks`: "a lock held in a mode that conflicts with this one is a Failed at once".

- [ ] **Step 1: Write the failing tests.**
  - `t_common.py`, `snapshot_home_and_harness_root`: `C.snapshot_home() ==
    $XDG_STATE_HOME/process-replay/snapshot` and `C.harness_root() == helpers.SRC`. With the CLI loaded as
    `t_e2e` loads it, `CLI.snapshot_root_default()` is that home joined with `2026-11-02`.
  - `t_codex.py`:
    - The roots-list case becomes `[~/Code/Org/repo, FSTATE, XSH/review-work, XSH/process-replay/snapshot,
      helpers.SRC, ~/.codex, ~/.claude, XSH/xreview, XSH/cxh]`.
    - `exports_forbidden`: reading `XSH/process-replay/harness-abc1234/dot_claude/x` (a fixture directory)
      is a leak labelled that directory.
    - `snapshot_new_home`: `ls $XDG_STATE_HOME/process-replay/snapshot/2026-11-02` is a leak.
    - `old_home_no_root`: `ls ~/Code/.replay/snapshot` gives `[]`.
    - The existing cases that name `~/Code/.replay/snapshot` follow suit: the snapshot-root read uses the new
      path, `rg foo ~/Code` reports only the checkout, and `ABOVE` drops the old snapshot.
    - `beneath_cwd`: `beneath(XSH, fwall)` includes review-work, the snapshot home, xreview and cxh;
      `beneath(<a fresh empty temp dir>, fwall) == []`; `beneath(FSTATE, fwall) == [FSTATE]` (a root at the
      cwd counts); `beneath(house, fwall)` includes the checkout, `~/.codex` and `~/.claude`.
  - `t_final.py`, replacing the two "from ~/Code/.replay … is a leak" cases:
    - (§14.6) From `REPLAY`, a Grep without a path and `rg -n defect` give `[]`.
    - The 66ad81cc false positive: `sed -E 's/:\s*/ /' notes.md` and `tar --include='*/SKILL.md' -cf o.tar .`
      from `REPLAY` give `[]`. The same `sed` call from `$XDG_STATE_HOME/process-replay`, which holds the
      snapshot, names the snapshot home: the matcher is unchanged, and the new layout is the fix.
- [ ] **Step 2: Run** the three files. The new cases fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the three files. They pass.
- [ ] **Step 5: Commit.** `Keep the snapshot and every harness export out of the driving session's directory and forbid them`

### Task 8: `run` refuses a forbidden root beneath it and a failing coverage gate (§14.3 a, §14.5)

**Depends on:** Task 6 (loop.py, inject.py), Task 7 (`beneath`, the harness root forbidden).

**Files:**
- Modify: `.scripts/process_replay/loop.py` (new `add_args_run`, `preflight`; `cmd_run`; docstring),
  `.scripts/process_replay/inject.py` (the coverage line in `cmd_inject`), `tests/process-replay/t_e2e.py`
  (one `os.chdir`)
- Test: `tests/process-replay/t_loop.py`, `tests/process-replay/t_inject.py`

**Interfaces:**
- Produces:
  - `loop.add_args_run(ap)`, which adds `--despite-coverage-gate` (store_true; ruling R9).
  - `loop.preflight(a, ctx) -> None`. `cmd_run` calls it first, dry run included (ruling R8); `match` and
    `cleanup` do not call it. It raises `Failed`, having changed nothing, in two cases:
    - The coverage gate fails: `cases.json`'s `coverage.unassessable_task` is non-empty and
      `getattr(a, "despite_coverage_gate", False)` is false. The message:
      `run refuses: the coverage gate fails: <N> per-task defect(s) are unassessable (<ids>), so §4 is
      inconclusive whatever the runs show. Give Michael the report; run with --despite-coverage-gate only on
      his request (the verdict stays inconclusive)`. With the option, it says `the coverage gate fails (<N>
      unassessable): running anyway for the recovery evidence; §4 stays inconclusive` instead.
    - A forbidden root lies beneath the working directory: `K.beneath(os.getcwd(), wall)` is non-empty for
      the wall of any case (`K.forbidden(a.state, branch, [], a.snapshot_root)`; with no case,
      `K.forbidden(a.state, {}, [], a.snapshot_root)`). The message: `run refuses: forbidden root(s) beneath
      its working directory <cwd>: <labels>. A final reviewer resolves relative text from there; run it from
      a directory with none beneath it`.
  - `inject`'s output gains `coverage gate: passes`, `coverage gate: fails: <N> per-task defect(s)
    unassessable; run refuses without --despite-coverage-gate`, or `coverage gate: not settled (answers
    wait)` while a branch waits.
  - `t_loop.py` and `t_e2e.py` call `os.chdir(helpers.tmp_root())` before their first command. The suites'
    own cwd is the checkout, which is now a forbidden root (the running harness's).

- [ ] **Step 1: Write the failing tests.** `t_loop.py`:
  - `refuses_forbidden_beneath_cwd` (§14.6): from `os.path.dirname(os.environ["XDG_STATE_HOME"])`, which
    holds the state, review-work, cxh, xreview and the snapshot home, `cmd_run` raises `Failed` naming
    `review-work`. No run directory appears, and no state file other than the lock files changes (listing
    with mtimes). From a fresh empty temp dir, the runs start.
  - `refuses_failed_gate`: with `cases.json` holding `coverage.unassessable_task == ["d00000099"]`,
    `cmd_run` and a dry run both raise `Failed` containing `--despite-coverage-gate`, and no run is made.
    With `despite_coverage_gate=True` the runs start, and the output says §4 stays inconclusive.
  - `option_parses`: `add_args_run` on an `ArgumentParser` gives True for `--despite-coverage-gate` and False
    without it.

  `t_inject.py`:
  - `coverage_line`: a complete branch with no unassessable defect prints `coverage gate: passes`, one with
    one prints `coverage gate: fails: 1 …`, and a waiting branch prints `coverage gate: not settled`.
- [ ] **Step 2: Run** `t_loop.py` and `t_inject.py`. The new cases fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both files. They pass. (`t_e2e.py` runs in the batch's full suite.)
- [ ] **Step 5: Commit.** `Let run refuse a forbidden root beneath it and a failing coverage gate`

### Task 9: `relocate-snapshot` (§14.3 a)

**Depends on:** Task 7 (`common.snapshot_home`, process-replay.py).

**Files:**
- Create: `.scripts/process_replay/relocate.py`, `tests/process-replay/t_relocate.py`
- Modify: `.scripts/process-replay.py` (`COMMANDS`, docstring command and lock lists),
  `tests/process-replay.test.sh` (add `relocate.py` to its files under test)

**Interfaces:**
- Produces:
  - `COMMANDS["relocate-snapshot"] = ("relocate", "cmd_relocate_snapshot")`.
  - `add_args_relocate_snapshot(ap)`: `--from DIR` (required; no legacy path in code) and `--to DIR`
    (default `C.snapshot_home()`).
  - `cmd_relocate_snapshot(a) -> int`, under `@C.locked(lambda a: None if a.dry_run else "exclusive")`.
  - `rewrite_value(value, old, new) -> (value, int)`: each string inside a JSON value that equals `old` or
    starts with `old + "/"` gets `new` for that prefix, and any other string, prose that mentions `old`
    included, is left alone.
  - `rewrite_alternates(text, old, new) -> (str, int)`: the same rule, line by line.
  - `_device(path) -> int`: the `st_dev` of the nearest existing ancestor. Tests replace it.
- Behaviour:
  - It refuses (`Failed`, exit 1, nothing changed) when `<state>/branches.json` is missing (not a state),
    when `--to` lies inside `--from` or the reverse, when both exist or neither does, and when
    `_device(--from)` differs from `_device(parent of --to)`.
  - If the old directory exists and the new one does not, it makes the new one's parent and runs
    `os.rename(old, new)`. It never copies.
  - It then rewrites `<state>/views/*.git/objects/info/alternates` and `<state>/branches.json`, each
    written whole (`C.jsave`, `XR.write_whole`) and only when changed. Run records are recorded verdicts and
    are never rewritten (R10).
    If the old directory is gone and the new one exists, it only rewrites (a resumed move).
  - It verifies two things, and raises `Failed` naming the first that does not hold. No string with the old
    prefix is left in those files. Every branch whose `objects` it rewrote resolves its `final_tip` through
    its `view` (`git --git-dir <view> cat-file -e <tip>^{commit}`).
  - It prints the rename (or `already moved`), the references rewritten per file, the totals, and
    `verified: no reference to <old> remains in the views or branches.json; every rewritten view resolves
    its branches' final tips`.
  - `--dry-run` takes no lock, changes nothing, and prints the same plan and counts.
  - The `process-replay.py` docstring lists `relocate-snapshot` ("move the snapshot and rewrite the state's
    references to it") and that it holds run.lock alone.

- [ ] **Step 1: Write the failing tests** (`t_relocate.py`, through the CLI module loaded as `t_e2e`
  loads it). The fixture state has:
  - a `branches.json` with two branches whose `objects` lie under OLD, and one with an original's objects;
  - two views, one with alternates under OLD and one with an original's;
  - a run `state.json` with `leak: [OLD]` and a finding summary that mentions OLD in prose;
  - a `reviews.json` and a `transcripts/x.jsonl` that mention OLD;
  - and OLD itself, holding `2026-11-02/chezmoi/objects` copied from a fixture repository.

  The cases:
  - `dry_run_changes_nothing`: the counts printed are 1 view and 2 `objects`. The listings
    (paths, sizes, mtimes) of the state and of OLD are unchanged, and NEW does not exist.
  - `moves_and_rewrites`:
    - NEW's inode is OLD's (a rename, not a copy), and OLD is gone.
    - The alternates and `objects` now name NEW.
    - The run `state.json` (its `leak` list and prose), `reviews.json` and the transcript are
      byte-identical, and the view resolves the branch's final tip.
    - The command exits 0 and prints `verified:`.
  - `resumes`: a state renamed but not rewritten gets rewritten, and one rewritten but not renamed gets
    renamed. A second run prints `already moved`, rewrites 0 and exits 0.
  - `refuses`: both OLD and NEW existing, `_device` giving two devices, no `branches.json`, and `--to`
    inside `--from` each exit 1 with nothing changed.
  - `lock`: while `C.command_locks(state, "shared")` is held, the command exits 1 with nothing changed.
- [ ] **Step 2: Run** `t_relocate.py`. It fails (unknown command).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it. It passes.
- [ ] **Step 5: Commit.** `Add relocate-snapshot: move the snapshot and rewrite the state's references`

### Finishing the code

- [ ] `./tests/run.sh` (every default suite) and `./tests/run.sh xreview git-forge-guard wt-functions`
  (the heavy ones, as before every pre-merge review). Report passed/total.
- [ ] Final whole-branch review (`sp-architect`) of this plan's commits against §14 and this plan, then its
  fix wave.
- [ ] Codex pre-merge review of the whole branch (`cross-review` skill, `--checkpoint pre-merge --diff
  main...replay-set`; the body names this plan's commits as the new ones), fixing every finding. Then the full and heavy suites again on the final commit.
- [ ] Push `replay-set` (a plain `git push origin replay-set` in a call of its own).

### Task 10: Relocate the kept state (operator step, run by the driver)

**Depends on:** Tasks 1–9 and "Finishing the code" (pushed, Codex pre-merge approved).

This is the only step that touches real data. It moves data and never deletes any: the snapshot and the old
harness export are renamed on the same volume (`/System/Volumes/Data` holds both `~/Code` and
`~/.local/state`). Use `S=~/.local/state/process-replay/2026-11-03`, `OLD=/Users/michael/Code/.replay/snapshot`,
and `H=~/.local/state/process-replay/harness-<sha7>` for the export of the reviewed tip.

- [ ] **Step 1: Export the reviewed tip:** `mkdir -p "$H"`, then `git -C <checkout> archive <sha> | tar
  -x -C "$H"`. This export is also the rerun's harness.
- [ ] **Step 2: Nothing runs.** `pgrep -fl 'process-replay|xreview-replay'` prints nothing. If a
  `memories-watch` runs (from `~/Code/.replay/harness-f0919ec`, or as a launchd job), stop and ask Michael
  to stop it, and say he restarts it in Step 6. Stop on anything else that is running.
- [ ] **Step 3: Dry run:** `$H/.scripts/process-replay.py relocate-snapshot --state "$S" --from "$OLD"
  --dry-run`. It must show the rename to `~/.local/state/process-replay/snapshot`. The counts measured
  2026-11-03 are: alternates in 6 views (chezmoi, curato, opsmaster, tagteam, VM.Inference, VM.Portal), 1
  each; `branches.json` 138 `objects` strings. Any other count: stop and report.
- [ ] **Step 4: Move:** the same command without `--dry-run`. It prints `verified: …` and exits 0.
- [ ] **Step 5: Move the old export** (ruling R4): `mv -n ~/Code/.replay/harness-f0919ec
  ~/.local/state/process-replay/harness-f0919ec`. Then `test ! -e ~/Code/.replay/harness-f0919ec`.
- [ ] **Step 6: Check, then restart the watcher.**
  - `ls -A ~/Code/.replay` lists no `snapshot` and no `harness-*`.
  - `fd -H -t d -g .git ~/Code/.replay` and `fd -H -t d -g objects ~/Code/.replay` print nothing: no copy
    of a repository is left.
  - `rg -uu -l -F "$OLD" "$S"` lists exactly `report.md`, two files under `transcripts/` and the
    `state.json` of runs 66ad81cc, 7f3b624a and 3819843a (measured 2026-11-03). That is recorded text, left
    as written (ruling R10); `reviews.json` and other transcripts name the snapshot only as
    `~/Code/.replay/…` in prompts.
  - `rg -uu -l -F "$OLD" "$S/views" "$S/branches.json"` prints nothing.
  - `ls ~/.local/state/process-replay/snapshot/2026-11-02` lists the six object stores, `codex-memories` and
    `codex-memories.frozen-at`.
  - From `~/Code/.replay`, `$H/.scripts/process-replay.py run --state "$S" --dry-run --despite-coverage-gate`
    exits 0 without a "forbidden root(s) beneath" refusal. It starts nothing.
  - If Step 2 stopped the watcher, Michael restarts it:
    `$H/.scripts/process-replay.py memories-watch --seed ~/.local/state/process-replay/snapshot/2026-11-02/codex-memories --seed-at 2026-11-02T13:21:43Z`
    (a launchd job's plist gets the same paths).

### Task 11: Mark this plan implemented

**Depends on:** Task 10.

The spec stays `In progress`: the rerun and its §11 results are still to come. Its Status line already
names this plan (Global Constraints).

- [ ] **Step 1:** Set this plan's Status to `Implemented (Codex pre-merge approved <receipt>; snapshot
  relocated <date>; next: the rerun of §14.5)`, and tick the boxes.
- [ ] **Step 2: Commit.** `Mark the replay-set amendment 1 plan implemented`
- [ ] **Step 3:** This commit follows the last pre-merge review, so dispatch a Codex pre-merge review
  (`cross-review` skill, `--diff main...replay-set`, the body naming this commit). Then push.

## After this plan: the rerun (§14.5)

This is not part of this plan, and Michael starts it. In a session rooted at `~/Code/.replay`, with `H` from
Task 10 and `S` the kept state, every command is `$H/.scripts/process-replay.py <command> --state "$S"`:

1. Run `inject`, dispatch what `pending` lists (judges, and recreations under the new rids), and run `inject`
   again. Repeat until it prints neither "answers wait" nor the hint to open more (completed plan, Part B
   step 4). Read its `coverage gate:` line.
2. If the gate fails, run `report` and give Michael the report: §4 stays inconclusive, and no Codex budget is
   spent. `run` refuses on its own. If it passes, follow Part B steps 1–2 and 5–8 of the completed plan with
   these paths, and run `run` from `~/Code/.replay`.
3. The results go into §11 in a later change.

## Rulings

These are the builder's calls on what §14 leaves open. The controller records any further ones here.

- **R1, when a recreation is requested (§14.4):** in the first round after its defect left whose answers
  are all in and in which nothing leaves. Its base is that round's groups, so "the tree of the round in which
  it left" is read as "the groups still active once the departures are settled". This rejects requesting at
  once, as today, because a sibling leaving in that round or the next would leave the recreation unable to
  apply. The cost is one more `inject` cycle when the departures cascade.
- **R2, the chezmoi source is read as a search root (§14.3 b)**, beside the destination, because chezmoi
  walks it. It is stricter than "judged by its paths", and it changes no verdict §14.3 predicts for the
  2026-11-03 records.
- **R3** is reserved for Task 4: a subcommand that fails the real-chezmoi test loses its exemption.
- **R4, the old export moves too, and every export is forbidden (§14.3 a):** `~/Code/.replay/harness-f0919ec`
  is a copy of the repository under the driving session's directory, so Task 10 renames it beside the new
  exports. `forbidden()` covers every `$XDG_STATE_HOME/process-replay/harness-*` and the running harness's
  own root.
- **R5, the file set per site is unchanged (§14.2):** presence still shows the finding's file alone, and
  validation and revalidation show the finding's file and the fix's files. Only how a file is shown changes.
- **R6, window details (§14.2):** the header is `[lines <a>-<b> of <n>]`, windows that touch merge, and lines
  are counted on `"\n"` as git counts them. A finding's line past the file's end is not an anchor.
- **R7, the fallback count (§14.2)** lives in `cuts/judge-present/<id>.json` and is reported by `report` per
  site.
- **R8, `run`'s refusals (§14.3 a, §14.5)** apply to dry runs too. A root at the cwd counts as beneath it.
  The wall is the union over the cases.
- **R9, the option is `--despite-coverage-gate` (§14.5)**, and `inject` prints a `coverage gate:` line.
- **R10, the relocation (§14.3 a):**
  - `--from` is required.
  - Only strings that are the old path, or lie under it, are rewritten, and only in the views' alternates
    and `branches.json`, the references the harness reads objects through.
  - Recorded text keeps its words: the run records (their only such strings are their `leak` verdicts),
    copied transcripts, `reviews.json` and the derived `report.md`. A verdict names what the scan saw then.
    §14.3 (a) listed "the run records" among the rewritten references; the plan's commit corrects that line.
  - Because `branches.json`'s `objects` is part of `case_digest`, the four 2026-11-03 runs are set aside as
    superseded at the next `run`, kept and marked.
- **R11, assignments are positional (§14.3 c):** "later in its text", so a loop body that runs a use again
  after a later assignment is a listed limit.
- **R12, checks (§14.1):** inherited `MISE_IGNORED_CONFIG_PATHS` entries are kept after ours, and
  `coherent` requires its env so no call site can drop it.
