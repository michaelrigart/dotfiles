# Replay set Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (plan review, then Part A).

**Goal:** Build the harness that answers, from October's record, whether the per-task reviewer and
the plan-review checkpoint can go, and that sets up the forward Codex-memories test; then run §4
and §5 of the spec and record the results.

**Architecture:** `.scripts/process-replay.py` is a thin command line over a stdlib package,
`.scripts/process_replay/`, one module per responsibility. It imports `xreview-replay.py` (turn
runner, rollout reading, judge-file conventions) and, through it, the packet builder and ledger.
Every phase is idempotent and file-driven: it writes blind judge inputs, stops, and continues once
the driving session has written the answers. Codex turns run on a second app-server daemon with its
own `CODEX_HOME`, so no replay content reaches Michael's daemon, rollouts or memories.

**Tech Stack:** Python 3.9 stdlib (`/usr/bin/python3`), git, bash, the Codex 0.166 app-server
through `xreview-rpc`, Claude subagents (`sp-standard` judges, `sp-architect` final reviewers).

**Spec:** `docs/superpowers/specs/2026-11-02-replay-set-design.md` (Approved; Codex
xr-1793626109-f7b04e58). Read it whole first. Section numbers (§4.3, …) below refer to it. Its
pass bars and judging rules are fixed; this plan changes none.

The plan has two parts. **Part A** (Tasks 1–12) builds and tests the harness in this checkout and
ends with the branch pushed. **Part B** runs it, from a separate Claude session rooted at
`~/Code/.replay` (§7.3), and fills in §11.

## Global Constraints

- **Where.** Part A runs in `~/.local/share/chezmoi` on branch `replay-set`. It touches only
  `.scripts/`, `tests/` and `docs/`, which chezmoi ignores, so `chezmoi apply` stays safe. Before
  Task 1 the controller commits this plan and sets the spec's Status to `In progress`.
- **Commits.** Imperative mood, no agent attribution. Run `git branch --show-current` right before
  every `git add` and commit (other sessions switch branches in this checkout); read
  `git diff --cached` first.
- **Batches.** Implementers do not commit and run only their own test file
  (`/usr/bin/python3 -I -B tests/process-replay/t_<module>.py`, or the named suite). The controller
  commits each task on its own and runs `./tests/run.sh process-replay xreview-replay
  measure-interventions` once per batch.
- **Python.** `#!/usr/bin/python3`, 3.9-compatible (no `match`, no `X | Y` annotations), stdlib
  only. `process-replay.py` sets `sys.dont_write_bytecode = True` before importing the package;
  tests run with `-B`. No `__pycache__` is ever committed. `process-replay.py` is mode `100755`;
  package modules are `100644`.
- **Never write** into an original repository, `~/.claude/projects`, `~/.codex` (the live home),
  the live `~/.codex/memories`, or `~/Code/.replay/snapshot/`. Reads of the snapshot go through a
  private view repository (`common.view`). Scratch repositories never use alternates (§7.1).
- **State.** Default `$XDG_STATE_HOME/process-replay/<YYYY-MM-DD>/` (`--state` overrides); the
  memories watcher and the shared Codex login live beside it, undated:
  `$XDG_STATE_HOME/process-replay/memwatch/` and `…/codex-auth/`. Replay Codex homes live at
  `$XDG_STATE_HOME/cxh/<name>`, short enough for the daemon's unix socket (≤ 103 bytes), and
  `<state>/codex-homes.json` lists the ones a state used. Tests use temp dirs only.
- **Spec values**, used verbatim: P0–P2 counted, P3 listed only; window 2026-10-01 to 2026-11-01,
  applied to the merge date only (`[2026-10-01T00:00:00Z, 2026-11-02T00:00:00Z)`); a qualifying
  branch keeps every review and pre-merge round it had, whatever its date; 10–12
  cases, at most 4 per repository, most recent first; 2 runs per case; at most 6 Codex rounds;
  assessable run: ≥ 80% of the pre-merge class recovered and ≤ 25% of the per-task class censored;
  Codex stops: 100M tokens for §4, 20M for §6; at most 3 turns at once; pause while the weekly
  window is at ≥ 80%; per-turn budget 3600 s.
- **Blind judges.** Every judge input goes through `common.judge_write`, which refuses a document
  holding a key named `class`, `run`, `arm`, `label` or `purpose` at any depth. Brief texts never
  say replay, inject, removal, per-task, arm or run. Indices in judge inputs are fresh per input.
  Every path handed to a judge, a final reviewer or a Codex turn (brief paths, input and answer
  paths, scratch repositories used as a cwd) goes through `common.aliased`, a neutral symlink
  `$XDG_STATE_HOME/review-work/<8 hex>` to the state dir, so no path a reviewer or judge sees
  names the replay; the harness itself uses the real paths. Scratch repositories are not reached
  through that symlink: they live physically under `$XDG_STATE_HOME/review-work/scratch/<label>`,
  because Codex may resolve a symlinked cwd to its real path.
- **Dry run.** `--dry-run` starts no daemon and no turn, and writes nothing but judge inputs and
  briefs (as `xreview-replay` does).
- **Existing failures.** A failure counts as pre-existing only if the same suite fails on `main`.

## Review Focus

1. A sliced pre-merge round: its findings are the union of every `slice_turns` answer, not the
   receipt turn's alone (Task 5 pins it).
2. A re-review prompt naming a short or ambiguous SHA, or commits that survive only in the
   snapshot: resolved through the view, an ambiguous one skipped and counted, never guessed
   (Tasks 1 and 5).
3. A review session whose worktree was removed (`wt-rm`): its cwd maps to the repository by path
   prefix, and `~/Code/repox` never matches `~/Code/repo` (Task 4).
4. One fix commit that fixes two defects and also edits `docs/superpowers/`: hunks split per
   defect, docs never in a repair patch, docs pinned (Task 6).
5. A Codex answer with `line: null`, a path written `a/x` or `./x`, or `approve` with only P3
   findings: matching normalizes the path, and the run ends at `approve` (Task 8).

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `.scripts/process-replay.py` | argparse, subcommand table (lazy imports), signals | 1 |
| `.scripts/process_replay/__init__.py` | empty | 1 |
| `.scripts/process_replay/common.py` | `XR` import, state paths, judge file protocol and briefs, labels, snapshot views | 1 |
| `.scripts/process_replay/scratch.py` | the one scratch-repository builder (§7.1) | 1 |
| `.scripts/process_replay/codexhome.py` | replay `CODEX_HOME`s, their daemon, shared login, probe (§7.2) | 3 |
| `.scripts/process_replay/transcripts.py` | `snapshot`: task-review discovery, ranges, cost, transcript copies | 4 |
| `.scripts/process_replay/inventory.py` | `cases`: branches, both defect classes (§4.1, §4.2) | 5 |
| `.scripts/process_replay/inject.py` | `inject`: fix groups, reverts, coherence, docs pin, validation, coverage gate, qualification (§4.3) | 6 |
| `.scripts/process_replay/codex.py` | one Codex pre-merge round on a scratch repo, budget, pause, leak scan (§4.4, §7.1) | 7 |
| `.scripts/process_replay/loop.py` | `run`, `match`: final review, oracle fixer, revalidation, endings (§4.4, §4.5) | 8 |
| `.scripts/process_replay/bar.py` | `report`: pass bar (§4.6), costs | 9 |
| `.scripts/process_replay/planreview.py` | `cases --plans` and its report section (§5) | 10 |
| `.scripts/process_replay/memwatch.py` | `memories-watch`, snapshot lookup (§6) | 11 |
| `.scripts/xreview-replay.py` | `memories` switch; scratch clones via `scratch.py` | 11 |
| `.scripts/measure-interventions.py` | `--exclude-project` | 2 |
| `tests/process-replay.test.sh` | runs every `tests/process-replay/t_*.py`, counts PASS/FAIL | 1 |
| `tests/process-replay/helpers.py` | shared fixtures: git repos, ledgers, transcripts, rollouts, stub rpc, stub codex | 1 |
| `tests/process-replay/t_<module>.py` | one test file per module | each |

`process-replay.py` maps each subcommand to `(module, function)` and imports the module only when
that subcommand runs, so later tasks never edit it: `snapshot→transcripts.cmd_snapshot`,
`cases→inventory.cmd_cases`, `inject→inject.cmd_inject`, `run→loop.cmd_run`,
`match→loop.cmd_match`, `report→bar.cmd_report`, `cleanup→loop.cmd_cleanup`,
`pending→common.cmd_pending`, `home→codexhome.cmd_home`,
`memories-watch→memwatch.cmd_memories_watch`. Shared flags: `--state`, `--dry-run`,
`--snapshot-root` (default `~/Code/.replay/snapshot/2026-11-02`), `--projects-dir` (default
`~/.claude/projects`), `--max-tokens` (default 100000000), `--budget` (default 3600). Each module
adds its own flags through an `add_args(parser)` the table also names.

Helpers live in `helpers.py` from Task 1 on and change only in Tasks 1 and 12; a task that needs
more fixture code writes it in its own test file, so parallel tasks never share a file.

## Shared records

Later tasks rely on these shapes; field names are fixed.

- **Judge files.** Input `<state>/<kind>/<id>.json`, answer `<state>/<kind>/<id>.answer.json`,
  brief `<state>/judges/<kind>.md` (written by `common.write_briefs`). Kinds and answer shapes:

  | kind | input | answer |
  |---|---|---|
  | `judge-task` | `{reports: [{index, text}], changes: [{index, note, diff}]}` | `{findings: [{index, report, summary, file, line, failure_scenario, severity: P0-P3, introduced_by: change index/null, fixed_by: [change index], answer: yes/no/unclear}]}` |
  | `judge-known` | xreview-replay's `{case, findings, interdiff}` | `{verdicts: [{index, answer}]}` |
  | `judge-present` | `{finding: {...}, files: [{path, text}]}` | `{answer}` |
  | `judge-split` | `{defects: [{index, summary, file, line}], hunks: [{index, file, text}]}` | `{hunks: [{index, defect: int/null/"unsure"}]}` |
  | `judge-dedup` | `{defects: [{index, summary, file, line, failure_scenario}]}` | `{groups: [[index, ...]]}` |
  | `judge-same` | `{original: {finding, fix}, candidate: {patch}}` | `{answer}` |
  | `judge-match` | `{defects: [{index, summary, file, line, failure_scenario}], findings: [...]}` or `{defects, report: str}` | `{findings: [{index, summary}]` (report form only)`, matches: [{defect, finding: int/null}], unmatched: [{finding, ruling: false_positive/real}]}` |
  | `judge-class` | `{finding, plan_excerpt, fix}` | `{class: diff-visible/design/plan-only}` |

  Briefs give the severity scale of `dot_config/xreview/reviewer.md` ("P0 (it cannot work) to P3
  (minor)") with one line each: P0 cannot work, loses data or opens a hole; P1 wrong on a normal
  path; P2 wrong on an edge path, or a required behaviour left untested; P3 minor, style or docs.
  A judge reads its input and writes its answer file itself, nothing else.
  Diffs in judge inputs are capped at 150000 characters (`XR.MAX_INTERDIFF`), files at 60000
  each and 150000 in all, with a `[truncated]` line.
- **Defect** (`inventory/<branch>.json` → `defects`): `{id, class: task|pre, severity, counted:
  bool, summary, file, line, failure_scenario, fixes: [[a, b]], files: [path], at}`; `id` is `d` +
  8 hex; `files` are the paths its fix ranges change outside `docs/superpowers/`.
- **Branch** (`branches.json`): `{id, repo, objects, view, dest, dest_ref, branch, base,
  rounds: [{k, nonce, tip, base, thread, turns: [[thread, turn]], at, verdict}], round1_tip,
  final_tip, plan_commit, groups: [group id], candidate: bool, why}`; `id` is `b` + 8 hex.
- **Case** (`cases.json` → `cases`): `{id, branch, repo, defects: [id], original_rounds,
  work_commit}` plus top-level `examined: [{branch, qualified, why}]` and
  `coverage: {unassessable_task: [id]}`.
- **Run state** (`runs/<case>/<label>/state.json`): `{case, label, scratch, thread, round,
  step: final|codex|match|valid|done, reviews: [{id, kind: final|codex, k, findings, verdict,
  tokens, turns, model, effort}], defects: {id: present|recovered|unrecovered|censored},
  rejected: [str], addressed: [str], outside: [str], ledger: path, end:
  approve|rounds|stalled|void|error|null, voids, tokens}`. `addressed` holds the identifiers of the
  findings the previous review matched; `ledger` is the per-run scratch ledger `codex.prepare_ledger`
  writes before any replay home is active (`CODEX_HOME` is process-wide).

---

## Part A — build

### Task 1: Package, suite, scratch builder (§7.1)

**Depends on:** none.

**Files:**
- Create: `.scripts/process-replay.py`, `.scripts/process_replay/__init__.py`,
  `.scripts/process_replay/common.py`, `.scripts/process_replay/scratch.py`,
  `tests/process-replay.test.sh`, `tests/process-replay/helpers.py`,
  `tests/process-replay/t_common.py`, `tests/process-replay/t_scratch.py`

**Interfaces:**
- Produces, `common.py`: `XR` (xreview-replay loaded once by importlib), `L = XR.L`,
  `XP = XR.XP`, `Failed = XR.Failed`, `jload`, `jsave`, `say` (from `XR`);
  `state_default() -> str`; `label(taken: set) -> str` (8 hex, unique);
  `judge_write(state, kind, jid, doc) -> str`; `judge_answer(state, kind, jid) -> dict|None`;
  `pending(state) -> list[(kind, jid, input_path, answer_path, brief_path)]` (judges without an
  answer, final briefs without `answer.md`, recreations without `done`); `write_briefs(state) ->
  None`; `brief_for(state, kind, jid) -> str` (writes `<kind>/<id>.brief.md`: the kind's brief
  followed by `Input: <input path>` and `Write your answer to: <answer path>`, and nothing else);
  `cmd_pending(a) -> int` (prints one line per pending judge, final review and recreation, with its
  brief); `snapshot_objects(root, gitdir) -> str|None`; `view(state, gitdir, root) -> str`;
  `git(gitdir, *args) -> str` (raises `Failed`) and `git_ok(gitdir, *args) -> bool`.
- Produces, `scratch.py`: `build(objects, base, files_dir, out, dest, branch, dest_ref=None,
  expect_tree=None) -> str` (tip sha; raises `Failed` when the tip's tree id is not
  `expect_tree`, which every caller passes: the tree id of the commit it exported); `export(objects, commit, dest_dir) -> None`;
  `commit_patch(scratch, patch_text, message) -> str|None` (None when the patch does not apply).
- Produces, `helpers.py`: `ok`, `is_`, `git`, `put`, `commit`, `make_repo(root, name) -> path`,
  `write_ledger(state_home, repo, entries)`, `write_rollout(codex_home, thread, turns)` (records
  `task_started`, `turn_context`, `token_count` with optional `rate_limits`, tool calls,
  `task_complete` with `last_agent_message`), `write_transcript(projects, key, session, entries,
  subagents)`, `stub_rpc(dir, codex_home, script) -> path` (a fake `xreview-rpc` for
  `thread-start`, `turn-start`, `turn-wait`, `thread-archive`, `health` that answers from a JSON
  script, logs argv and `CODEX_HOME` per call, and writes rollouts), `stub_codex(dir) -> path` (a
  fake real binary for `app-server daemon start|stop` and `login`, logging argv and `CODEX_HOME`).

- [ ] **Step 1: Write the suite runner.** `tests/process-replay.test.sh` follows
  `tests/xreview-replay.test.sh`'s preamble (missing file under test → exit 2; temp `ROOT` with
  isolated git config, `GIT_CEILING_DIRECTORIES`), then runs each `tests/process-replay/t_*.py` with
  `/usr/bin/python3 -I -B`, prints its output, and exits with the number of `  FAIL:` lines (a
  `t_*.py` that exits non-zero without printing FAIL counts as one failure).

- [ ] **Step 2: Write the failing tests.**

  `t_scratch.py`, on a fixture repo `B → C1 (feature) → C2 (fix, adds the line FIXED) → T`:
  - `scratch_hides_later_fix`: `build(objects, B, export(C1), out, "main", "feat")`; in `out`,
    `git cat-file -e C2` and `-e T` fail; `git fsck --unreachable --no-reflogs` names neither;
    no blob reachable from `git rev-list --all --objects` contains `FIXED`;
    `.git/objects/info/alternates` does not exist; `git remote` prints nothing.
  - `scratch_refs`: `refs/heads/main` is `B`; with `dest_ref="origin/main"`,
    `refs/remotes/origin/main` is `B`; `HEAD` is `refs/heads/feat`; `tip^` is `B`;
    `git diff --no-index` between the files dir and the checkout (minus `.git`) is empty.
  - `scratch_commit_neutral`: the tip's message is `Change under review` and its author is
    `Developer <developer@example.invalid>`.
  - `scratch_tree_identity`: a source commit holding a `.gitignore` with `*.log` and a force-added
    `x.log` (absent at the base), an executable file and a symlink: the tip's tree id equals the
    source commit's; a wrong `expect_tree` raises `Failed`.
  - `commit_patch_one_commit`: a patch adds one commit with the given message; a patch that does
    not apply returns None and leaves `HEAD` and the work tree unchanged.

  `t_common.py`:
  - `blind_refuses_keys`: `judge_write` raises `Failed` for `{"x": [{"class": "task"}]}` and for
    each of `run`, `arm`, `label`, `purpose`; writes `<state>/judge-present/<id>.json` otherwise.
  - `pending_lists_unanswered`: two inputs, one answer → one pending entry.
  - `per_input_briefs`: two pending `judge-present` inputs get two brief files, each naming its
    own input and answer path and not the other's.
  - `briefs_neutral`: every `judges/<kind>.md` exists after `write_briefs`; none contains
    `replay`, `inject`, `removal`, `per-task` or ` arm` (case-insensitive).
  - `view_reads_snapshot_only_objects`: a commit made, copied into a snapshot objects dir, then
    pruned from the original (`reset --hard`, `reflog expire --expire=now --all`,
    `gc --prune=now`) resolves through `view`; a listing of the snapshot dir (paths, sizes,
    mtimes) is identical before and after every view operation.
  - `snapshot_map`: `/x/Code/Netronix/curato/.git` → `<root>/curato/objects` when that dir
    exists; `/x/.local/share/chezmoi/.git` → `<root>/chezmoi/objects`; an unknown name → None.

- [ ] **Step 3: Run them; they fail** (`./tests/process-replay.test.sh`: missing modules).

- [ ] **Step 4: Implement.**
  - `view`: a bare repository `<state>/views/<name>.git` whose `objects/info/alternates` names the
    snapshot objects dir (or the original's `objects` when there is no snapshot). It is private to
    the harness and never shown to a reviewer.
  - `snapshot_objects`: the name is the basename of the git dir's parent.
  - `scratch.build`: `git init -q out`; `git -C <tmp view> pack-objects --revs --stdout` with `B`
    on stdin, piped to `git -C out index-pack --stdin`; set the refs; check out `B` on `branch`;
    replace the work tree with `files_dir` (everything but `.git`); `git add -A -f` (the files dir
    holds exactly the tracked files, ignored ones included); check the staged tree against
    `expect_tree`; commit with the
    fixed identity and `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` one hour after `B`'s committer date;
    then `git fsck --connectivity-only` must pass. Cache the pack per `(objects, base)` under the
    caller's state when given a `cache` dir (optional keyword, default None).
  - `process-replay.py`: the table above; `--state` made absolute and created; SIGINT/SIGTERM
    install `XR.on_signal`.

- [ ] **Step 5: Run the suite; it passes.** Expected: `./tests/run.sh process-replay` PASS with
  0 failures.

- [ ] **Step 6: Commit.** `Add the replay-set harness skeleton and its scratch-repository builder`

### Task 2: `--exclude-project` in measure-interventions (§7.3)

**Depends on:** none.

**Files:**
- Modify: `.scripts/measure-interventions.py` (`measure()`, `main()`, docstring)
- Test: `tests/measure-interventions.test.sh`

**Interfaces:**
- Produces: `project_key(path: str) -> str` (every character outside `[A-Za-z0-9]` becomes `-`,
  as Claude Code names project dirs); `measure(projects_dir, days, now=None, exclude=())`.

- [ ] **Step 1: Write the failing tests** in the existing suite's style:
  - `excludes_replay_by_default`: with `HOME` set to a fixture home, a session (and its subagent)
    under `project_key("$HOME/Code/.replay")` adds nothing to `human_turns`, `sessions` or
    `xreview`, while the same session under another key does.
  - `excludes_replay_subdirs_only`: `<key>-state` is excluded, `<key>x` is not.
  - `extra_exclusion`: `--exclude-project /some/path` (repeatable) excludes that path's key as
    well, and the default stays excluded.
  - `reports_exclusions`: the JSON gains `"excluded_projects": [keys]`.
- [ ] **Step 2: Run** `./tests/measure-interventions.test.sh`; the new cases fail.
- [ ] **Step 3: Implement.** A project dir is skipped when its name equals a key or starts with
  key + `-`. The default list is `[~/Code/.replay]`, expanded at run time.
- [ ] **Step 4: Run** the suite; it passes.
- [ ] **Step 5: Commit.** `Leave the replay session out of the intervention metrics`

### Task 3: Replay Codex homes (§7.2)

**Depends on:** Task 1.

The mechanism is a second daemon with its own `CODEX_HOME` (ruling R1 below), one home per
memories setting: `nomem` for §4 and §6's B arm, `mem-<hash12>` per snapshot for A and A′. Each
home logs in through one shared login of its own, so no replay daemon ever rotates the token of
Michael's daemon.

**Files:**
- Create: `.scripts/process_replay/codexhome.py`, `tests/process-replay/t_codexhome.py`

**Interfaces:**
- Consumes: `common.*`.
- Produces: `auth_dir() -> str` (`$XDG_STATE_HOME/process-replay/codex-auth`);
  `real_bin() -> str` (`CODEX_REAL_BIN`, else `codex-daemon real-bin`);
  `ensure(state, name, memories_src=None, use_memories=False, source=None) -> str`;
  `start(home) -> None`; `stop(home) -> None`; `probe(home, expect_memories, rpc=None) -> dict`
  (`{ok: bool, checks: {name: bool}, model, effort, notes: [str]}`); `cmd_home(a)` with
  `--name`, `--memories DIR`, `--use-memories`, `--start`, `--stop`, `--probe`, `--login-cmd`,
  `--codex-source` (default `~/.codex`).

- [ ] **Step 1: Write the failing tests** (`CODEX_REAL_BIN` = `helpers.stub_codex`, source home a
  fixture):
  - `home_config`: `ensure(state, "nomem")` gives a mode-700 home whose `config.toml` is the
    source's with a `[memories]` table holding `use_memories = false` and
    `generate_memories = false`; a source `[memories]` table keeps its other keys;
    `[features] memories` is unchanged and the top-level `notify` is dropped; `AGENTS.md`,
    `skills` and `rules` are copied and `plugins` is an APFS clone (a replay daemon writes into
    them, so none may link into the source); `auth.json` is a symlink to `auth_dir()/auth.json`; no
    `sessions`, `archived_sessions`, `sqlite`, `memories` or `.codex-global-state.json`.
  - `home_memories`: `ensure(state, "mem-x", memories_src=snap, use_memories=True)` copies `snap`
    (without `.git`) to `memories/` and sets `use_memories = true`, `generate_memories = false`.
  - `home_refuses_live`: `ensure` raises `Failed` when the home would be the source home, or when
    `memories_src` resolves to `<source>/memories`.
  - `start_stop`: `start` runs `<real> app-server daemon start` with `CODEX_HOME=<home>`; `stop`
    runs `daemon stop`; if the home's `auth.json` has become a regular file, `stop` copies it over
    `auth_dir()/auth.json` when newer and restores the symlink.
  - `one_daemon_at_a_time`: `start` of a second home while one is running raises `Failed`.
  - `login_cmd`: prints exactly `CODEX_HOME=<auth_dir> <real> login`.
  - `probe_checks` (stub rpc writing a rollout whose developer message holds, or lacks, three
    distinctive lines of the source `memories/memory_summary.md`): `ok` is true only when the turn
    answered, its rollout is under the replay home, no new rollout appeared under the source home,
    `health` on the source home's socket still answers, and the memory lines are present exactly
    when `expect_memories`.
- [ ] **Step 2: Run** `t_codexhome.py`; it fails.
- [ ] **Step 3: Implement.** The config edit is textual: drop any `[memories]` table's
  `use_memories`/`generate_memories` lines, then set them (adding the table if absent). The probe
  starts a thread in a temp dir, runs one turn (asking for `{"word":"ok"}`) with the strict schema
  `{"type":"object","additionalProperties":false,"required":["word"],"properties":{"word":{"type":"string"}}}`,
  reads the replay rollout,
  and archives the thread. The probe's turn also gives the home a rollout from which
  `XP.fresh_window` reads the context window.
- [ ] **Step 4: Run** the test file; it passes.
- [ ] **Step 5: Commit.** `Give replay turns their own Codex home, login and daemon`

### Task 4: `snapshot` — task reviews and their cost (§4.2, §9)

**Depends on:** Task 1.

**Files:**
- Create: `.scripts/process_replay/transcripts.py`, `tests/process-replay/t_transcripts.py`

**Interfaces:**
- Produces: `cmd_snapshot(a)` (no date filter: which branches count is decided by merge date in
  Task 5, and a branch merged in October may have been reviewed in September), writing
  `<state>/reviews.json` = `{groups: [{id, project, session, cwd, repo, prefix, task,
  reviews: [{agent, kind: review|re-review, description, start, end, prompt, report,
  ranges: [[a, b]], reviewed_head, reviewed_commits: [sha], tokens, model, transcript}]}]}` and copying transcripts to
  `<state>/transcripts/<project>/<session>/…`;
  `parse_ranges(text) -> list[(str, str)]`; `reviewed_head(prompt) -> str|None`;
  `repo_for_cwd(cwd, repos: list[str]) -> str|None`; `cost(path) -> {tokens, start, end}`.

- [ ] **Step 1: Write the failing tests** on a fixture projects dir:
  - `finds_task_reviews`: an `sp-reviewer` "Review W2 Task 3" and "Re-review W2 Task 3 fix round
    1" form group `(session, "W2", 3)` with kinds `review`, `re-review`; an `sp-architect`
    "Review Task 4 (spec + quality)" forms `(session, "", 4)`; "Re-review pre-merge fix round 1",
    "Cold review of commit x" and an `sp-architect` "Final review" form none.
  - `nested_controller_copied`: a reviewer whose `meta.json` has `parentAgentId` of a controller
    subagent is found, and the controller's transcript and the main session's are copied too.
  - `ranges_table`: `Fix base 997f08a, head edd1f33.` → `[("997f08a","edd1f33")]`;
    `review-997f08a..edd1f33.diff` → same; `FIX_BASE=abc1234 … HEAD=def5678` → `[("abc1234",
    "def5678")]`; `BASE_SHA: a1b2c3d` with `HEAD_SHA: e4f5a6b` → `[("a1b2c3d","e4f5a6b")]`; text
    with none → `[]`.
  - `repo_for_cwd_prefix`: `/f/Code/repo-feat` and `/f/Code/repo/.claude/worktrees/x` map to
    `/f/Code/repo/.git`; `/f/Code/repox` maps to None.
  - `cost_dedupes_messages`: two streamed entries sharing one `message.id` count once; tokens are
    input + output + cache creation + cache read; start and end are the first and last timestamps.
  - `no_date_filter`: a reviewer from September is found and copied like an October one.
  - `read_only`: the fixture projects dir's listing (paths, sizes, mtimes) is unchanged.
- [ ] **Step 2: Run** it; it fails.
- [ ] **Step 3: Implement.** A task review is a subagent whose `meta.json` `agentType` is
  `sp-reviewer` or `sp-architect` and whose `description` matches
  `^(Re-review|Review)\s+(.*?)\s*Task\s+(\d+)\b`; group 2, stripped, is the prefix. The prompt is
  the first user entry's text; the report is the last `SubagentHandback` call's `input.message`,
  else the last assistant text (reviewers hand their report back through that tool). `repos` are the git dirs named
  in the xreview ledgers; a cwd matches the repository whose work dir `W` satisfies
  `cwd == W` or `cwd.startswith(W + "-")` or `cwd.startswith(W + "/")`, longest `W` first.
- [ ] **Step 4: Run** it; it passes.
- [ ] **Step 5: Commit.** `Snapshot October's task reviews and what they cost`

### Task 5: `cases` — branches and the two defect classes (§4.1, §4.2)

**Depends on:** Task 4.

**Files:**
- Create: `.scripts/process_replay/inventory.py`, `tests/process-replay/t_inventory.py`

**Interfaces:**
- Consumes: `reviews.json` (Task 4); `XR.load_rounds`-style ledger reading, `XR.turns_of`,
  `XR.judge_input`; `common.view`.
- Produces: `cmd_cases(a)` (`--plans` hands over to `planreview.plan_cases(a)`, Task 10), writing
  `branches.json` and, once answers exist, `inventory/<branch>.json` = `{branch, defects: [Defect],
  dropped: [{summary, why}]}`; `round_findings(round) -> list[dict]`;
  `chains(entries) -> list[list[round]]`.

- [ ] **Step 1: Write the failing tests** on a fixture repo, ledger, rollouts and `reviews.json`:
  - `candidate_static`: a chain (same repo, branch, dest; ascending `dispatched_at`) whose round 1
    is a full-branch receipt, whose last round approved and whose merge date is in the window is a
    candidate, its September rounds and task reviews included; one whose round 1 has
    `full: false` is not (`why: round 1 is not a full-branch review`); one merged on 2026-11-03 is
    not (`why: merged outside the window`); one with no joined task group is not;
    one with no merge evidence is not (`why: no merge evidence`);
    one whose round tip resolves neither in the repository nor in the snapshot is not
    (`why: a round tip is gone`).
  - `merge_evidence`: a branch counts as merged, at the committer date of the first-parent commit
    of the destination's current tip that brings it in, when (a) the final tip is an ancestor of
    that tip, (b) `git cherry <dest> <final tip> <base>` marks every branch commit `-` (rebase
    merge), or (c) a first-parent commit `S` has `git merge-tree --write-tree --merge-base=<base>
    S^ <final tip>` equal to `S^{tree}` (squash merge); the merge date must fall in
    `[2026-10-01, 2026-11-02)`. A fixture for each of (a), (b), (c), plus one with none.
  - `sliced_round_union`: a round with two `slice_turns` whose answers hold one P1 each yields two
    findings.
  - `task_join`: a group whose re-review fix head is an ancestor of the final tip and not of the
    base joins the branch; a group from another branch does not.
  - `fix_range_unnamed`: a re-review prompt without a range gets `(reviewed head, the last branch
    commit whose committer date is at or before the re-review's start)`.
  - `ambiguous_sha_skipped`: an ambiguous short SHA drops that range and counts it in
    `branches.json` (`unresolved_ranges`).
  - `judge_inputs`: one `judge-task` per group (every review and re-review report of the task, in
    order; one change per fix range, with the re-review prompt's "Finding under verification"
    lines as `note`), one
    `judge-known` per round with a next round, and one `judge-present` per known-real finding of a
    round k ≥ 2, holding the round-1 tip's text of the files it names.
  - `re_review_findings`: a defect first raised by a re-review about code no change introduced
    (`introduced_by: null`) and fixed by a later change becomes a per-task defect; a finding with
    `introduced_by` set (breakage a fix brought in) is dropped (`introduced by a fix`).
  - `inventory_after_answers`: per-task `yes` P1 → defect `class: task, counted: true`; per-task
    P3 → `counted: false`; per-task `no` → dropped; round-1 known-real P2 → `class: pre`;
    round-2 known-real with present `yes` → defect, with present `no` → dropped (`introduced
    after round 1`); a `judge-dedup` answer `[[0, 2]]` merges two into one with the higher
    severity and both fix ranges.
  - `judges_blind`: no judge input names a class, a branch id or the word "pre-merge" as a key.
- [ ] **Step 2: Run** it; it fails.
- [ ] **Step 3: Implement.** Read every git object through `common.view` (round tips may survive
  only in the snapshot). A pre-merge defect's fix is `[tip_k, tip_k+1]`. A round's findings are the
  receipt turn's final answer plus every `slice_turns` answer, de-duplicated by
  `(thread, turn)`. Only P0–P2 Codex findings enter `judge-known`. The dedup judge runs once per
  branch over every known-real defect, after the other judges have answered.
- [ ] **Step 4: Run** it; it passes.
- [ ] **Step 5: Commit.** `Build the replay inventory of task-review and pre-merge defects`

### Task 6: `inject` — the injected tree, validation and qualification (§4.3, §4.1)

**Depends on:** Task 5, Task 1.

**Files:**
- Create: `.scripts/process_replay/inject.py`, `tests/process-replay/t_inject.py`

**Interfaces:**
- Consumes: `inventory/<branch>.json`, `branches.json`, `scratch.export`, `common.view`.
- Produces: `cmd_inject(a)`, writing per branch `injected/<branch>.json` =
  `{work, work_commit, plan_commit, defects: {id: {status: present|dropped-revert|incoherent|
  not-present|recreated|unassessable, group, repair, hunks: [{file, start, end}]}}}` and
  `cases.json` (Shared records); `repairs/<id>.patch` per assessable defect;
  `recreate/<id>.json` briefs; `fix_patch(view, a, b) -> str` (excludes `docs/superpowers/`);
  `coherent(work, files) -> (bool, str)`.

- [ ] **Step 1: Write the failing tests** on a fixture branch `base → task1 (bugs A, B, C in
  three files, plus test files) → fixA (code + its test) → fixBC (one commit, a hunk per bug, plus
  a docs/superpowers edit) → later (uses a helper fixA added) → fixD (pre-merge fix)`, with plan
  commit `task1`:
  - `revert_whole_with_tests`: the injected tree has bug A's code and lacks fixA's test change.
  - `split_groups`: a `judge-split` answer hunk0→B, hunk1→C gives B and C their own repair
    patches; `"unsure"` on either makes B and C one group with one patch.
  - `docs_pinned`: `docs/superpowers/` equals the plan commit's, files added later are gone, and
    no repair patch names a `docs/superpowers/` path.
  - `revert_conflict_dropped`: a fix whose context a later commit rewrote gets
    `status: dropped-revert` and is counted in `examined`.
  - `coherence_undo`: a revert that breaks `bash -n` on a `.sh` file is undone, `incoherent`; a
    stub `cargo` on `PATH` failing after the last revert undoes reverts latest first until it
    passes.
  - `validation`: `judge-present` `yes` → `present`; `no` or `unclear` → `not-present`.
  - `coverage_gate`: an unassessable per-task P1 gets `recreate/<id>.json`
    (`{finding, fix, tree}` where `tree` is a plain copy of the branch's final tree, as §4.3
    says); once `recreate/<id>/tree` has been edited, the harness takes the patch and writes
    `judge-same`; on `yes` it applies the patch to the injected tree (`git apply --index`; a
    failure is `unassessable`) and writes `judge-present` on the finished tree; both `yes` →
    `recreated` with `repair` the reverse patch; otherwise it is
    `unassessable`, listed in `coverage.unassessable_task`, and its branch does not qualify.
    The agent signals that it is finished by writing `recreate/<id>/done`; `pending` lists a
    recreation until then.
  - `qualify`: a branch needs ≥ 2 assessable per-task defects and every P0/P1 of both classes
    assessable; at most 4 per repository and 12 in all, most recent final round first; while
    fewer than 12 qualify or wait on judges, the next candidate opens; unassessable pre-merge P2s
    are counted, not disqualifying.
- [ ] **Step 2: Run** it; it fails.
- [ ] **Step 3: Implement.**
  - The work repo `<state>/work/<branch>` (private) is built with `scratch.build` from the final
    tip's tree, then gets each defect's repair reverted with `git apply -R --index`, latest fix
    first by position in `git rev-list --topo-order base..final_tip`. A failing apply is
    `dropped-revert`.
  - Coherence after each revert, on the files it changed: `bash -n` for `.sh`, `.bash` or a bash
    shebang; `zsh -n` for `.zsh`, a zsh shebang or a file under a `zsh/functions` dir;
    `python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())'` for `.py`; `ruby -c` for
    `.rb`; a JSON parse for `.json`. A repository with `Cargo.toml` at its root gets
    `cargo check --offline --all-targets` once at the end (`CARGO_TARGET_DIR=<state>/cargo/<repo>`,
    3600 s), undoing reverts latest first until it passes.
  - Pin `docs/superpowers/` to `plan_commit`: the tip of the branch's newest approved, clean plan
    receipt; with none, the last commit touching `docs/superpowers/plans/` before the first task
    review began.
  - Each defect's `hunks` are its repair's post-image line ranges, kept for Task 8's
    collateral check.
- [ ] **Step 4: Run** it; it passes.
- [ ] **Step 5: Commit.** `Inject the reviewers' catches back into each branch's final tree`

### Task 7: One Codex pre-merge round (§4.4, §7.1, §8)

**Depends on:** Task 1, Task 3.

**Files:**
- Create: `.scripts/process_replay/codex.py`, `tests/process-replay/t_codex.py`

**Interfaces:**
- Consumes: `XR.one_turn`, `XR.turn_usage`, `XR.Threads`, `XR.rpc`, `XP.build`,
  `XR.enriched`, `codexhome` (the home path only).
- Produces: `codex_round(a, run: dict, case: dict, branch: dict, home: str) -> dict` returning a
  review (`{kind: "codex", k, findings, verdict, tokens, turns, model, effort, missing, decision,
  thread}`) or `{paused: str}` / `{stopped: str}` / `{leak: [str]}`;
  `body(branch, k, addressed: list[str], rejected: list[str]) -> str`;
  `weekly(home) -> (float, int)|None`; `leaks(home, turns, paths) -> list[str]`;
  `scratch_ledger(run, case, branch) -> str` (a state home for `XP.build`).

- [ ] **Step 1: Write the failing tests** (stub rpc, fixture replay home):
  - `plans_omitted_as_today`: with the branch's approved clean plan receipt rebound to the scratch
    repo (`targets[].repo` = the scratch git dir; `plan_blobs` unchanged), the decision's target
    has `plans_from` naming the plan.
  - `thread_continuity`: round 2's `turn-start` names round 1's thread; a `fresh` decision starts
    a thread that rounds after it reuse; a `slices` decision runs one thread per slice, the round's
    findings are their union, its verdict is `approve` only if every slice approves, and the run's
    thread afterwards is the last slice's.
  - `missed_carried`: a framed round whose `reviewed_files` lacks a shown label passes that label
    as `missed` to the next round's request.
  - `body_strings`: round 1's body equals `XR.prepare`'s body for the same target; round 2 appends
    exactly `Addressed since the last round: <a>; <b>.` and `Judged not defects: <c>.` lines
    (each omitted when empty), where an identifier is `<file>:<line> <first 80 chars of summary>`.
  - `weekly_pause`: a newest rollout `token_count` with `rate_limits.primary` `window_minutes:
    10080, used_percent: 81` returns `{paused}` naming `resets_at`, and starts no turn.
  - `token_stop`: spent ≥ `--max-tokens` returns `{stopped}` and starts no turn.
  - `leak_scan`: a `custom_tool_call` or `function_call` whose arguments name the original work
    dir, or a sibling `<dir>-feat`, is a leak; the same path inside a user or developer message is
    not.
  - `home_env`: every rpc call carries `CODEX_HOME=<replay home>` (stub log).
- [ ] **Step 2: Run** it; it fails.
- [ ] **Step 3: Implement.** The request is today's: `checkpoint: pre-merge`,
  `switches_file: dot_config/xreview/packets.conf`, `cap: None`, `codex_home: <home>`,
  `thread: <run thread>` for k ≥ 2, `turns_file: None` (delta is off), the scratch target
  `{repo: <scratch>/.git, dest, dest_ref, branch, range, base, tip: scratch HEAD, full: true}`.
  The schema is `findings.framed.schema.json` when framing is on, else `findings.schema.json`,
  as `XR.run_job` picks. The scratch ledger is the branch's entries up to its original round 1
  (`XR.enriched`) with plan receipts rebound as above, written under a temporary state home keyed
  by `L.ledger_key(<scratch>/.git)` and swapped in for `L.state_home` while building, as
  `XR.prepare` does. Weekly window: whichever of `primary`/`secondary` has
  `window_minutes == 10080`.
- [ ] **Step 4: Run** it; it passes.
- [ ] **Step 5: Commit.** `Run one replay pre-merge round through today's packet builder`

### Task 8: `run` and `match` — the gates that stay (§4.4, §4.5, §7.1)

**Depends on:** Task 6, Task 7.

**Files:**
- Create: `.scripts/process_replay/loop.py`, `tests/process-replay/t_loop.py`

**Interfaces:**
- Consumes: `cases.json`, `injected/<branch>.json`, `codex.codex_round`, `scratch.build`,
  `scratch.commit_patch`, `codexhome`.
- Produces: `cmd_run(a)`, `cmd_match(a)`, `cmd_cleanup(a)`; run states (Shared records);
  `final/<review id>/brief.md` and, from the driver, `final/<review id>/answer.md`;
  `oracle(run, ids) -> str` (commit sha); `touched(run, sha) -> list[str]`.

- [ ] **Step 1: Write the failing tests** (a fake `codex_round` injected through a module
  attribute, canned judge answers):
  - `final_brief`: the brief is `requesting-code-review/code-reviewer.md` (newest superpowers
    version under `~/.claude/plugins/cache`) with `[DESCRIPTION]` = `The change on <branch>.`,
    `[PLAN_OR_REQUIREMENTS]` = the scratch plan path, `[BASE_SHA]`/`[HEAD_SHA]` = scratch base and
    tip, followed by the review package path (`review-package` run in the scratch), the scratch
    path, and `Review id: <id>`; it contains none of `replay`, `inject`, `per-task`.
  - `match_blind_shuffled`: each review's `judge-match` holds only still-present defects of both
    classes with fresh indices in a per-review order, and no class.
  - `oracle_one_commit`: a match re-applies that defect's repair as one commit
    `Address review findings` (the commit's diff is the repair); the other members of its group
    become `censored`.
  - `touched_revalidated`: a re-application that changes a remaining defect's hunk lines, or makes
    its repair stop applying (`git apply --check`), writes `judge-present` for it; `no` or
    `unclear` → `censored`; `yes` → stays `present`.
  - `endings`: `approve` → every present defect `unrecovered`, `end: approve`; six Codex rounds →
    `end: rounds`; a review, the final review or a Codex round, with no match and ≥ 1 `real` ruling
    → `end: stalled`, the present ones `censored` (one test for each kind of review).
  - `rejected_carried`: `false_positive` rulings reach the next round's body.
  - `approve_p3_only` and `path_normalized`: `approve` with only P3 findings ends the run;
    findings with `line: null` and paths `a/x` or `./x` reach the judge as `x`.
  - `void_once_more`: a leak voids the run, which starts once more under a new label and scratch;
    a second leak ends it `void`; a leak in the final reviewer's transcript (the subagent
    transcript holding `Review id: <id>`) counts the same.
  - `repair_fails`: a repair that no longer applies ends the run `error`.
  - `idempotent`: `run` then `match` with no new answers changes no state file.
- [ ] **Step 2: Run** it; it fails.
- [ ] **Step 3: Implement.** Steps per run: build the scratch (`<state>/scratch/<label>`) from the
  work commit's tree; `final` (brief written, waits for `answer.md`); `match` (judge input, waits);
  `valid` (revalidation inputs, waits); then a Codex round, and so on. `run` advances every run
  that can move without a Claude answer, at most 3 turns at once across runs, and exits when every
  run waits or is done. `match` applies every answered judge. The stall rule applies after every
  review, the final review included (§4.4).
- [ ] **Step 4: Run** it; it passes.
- [ ] **Step 5: Commit.** `Drive the replay through the final review and the Codex loop`

### Task 9: `report` — the pass bar and its costs (§4.6)

**Depends on:** Task 8.

**Files:**
- Create: `.scripts/process_replay/bar.py`, `tests/process-replay/t_bar.py`

**Interfaces:**
- Consumes: run states, `cases.json`, `reviews.json`, `planreview.report_section(state)`
  (Task 10; skipped when it has no cases).
- Produces: `bar(cases, runs, coverage) -> {status: pass|fail|inconclusive, assessable: {run:
  bool}, reasons: [str], unrecovered_task: [{case, run, severity, summary}]}`; `cmd_report(a)`
  writing `report.md` and `report.json`.

- [ ] **Step 1: Write the failing tests**, table-driven over synthetic runs:
  - `pass_all_recovered`: every run assessable and every counted per-task defect recovered → pass.
  - `fail_task_p1`: an assessable run with a per-task P1 unrecovered and every pre-merge P0/P1 of
    its case recovered → fail.
  - `not_fail_when_pre_p1_missed`: the same with a pre-merge P1 unrecovered → inconclusive.
  - `assessable_edges`: pre-merge recall 0.8 → assessable, 0.79 → not; per-task censored 25% →
    assessable, 26% → not; a `void` or `error` run → not.
  - `censoring_blocks_pass`, `task_p2_unrecovered_inconclusive`, `p3_not_counted`.
  - `coverage_gate`: `coverage.unassessable_task` non-empty → inconclusive when it would pass;
    a fail stays a fail.
  - `report_contents`: `report.md` lists each case and run (recovered, unrecovered, censored per
    class; Codex rounds beside the original count; end), every unrecovered per-task defect with
    severity and summary, the reviewer's October cost per task of the qualified branches
    (dispatches, tokens, wall minutes, from `reviews.json`), extra rounds (simulated minus
    original), Codex tokens, model and effort, voids, and the drop counts.
- [ ] **Step 2: Run** it; it fails.
- [ ] **Step 3: Implement** the precedence fail > pass > inconclusive.
- [ ] **Step 4: Run** it; it passes.
- [ ] **Step 5: Commit.** `Report the replay against the per-task reviewer's pass bar`

### Task 10: The plan-review checkpoint (§5)

**Depends on:** Task 1.

**Files:**
- Create: `.scripts/process_replay/planreview.py`, `tests/process-replay/t_planreview.py`

**Interfaces:**
- Produces: `plan_cases(a) -> int`; `report_section(state) -> (list[str], dict)`.

- [ ] **Step 1: Write the failing tests** on fixture plan receipts and rollouts:
  - `rounds_per_plan_file`: a thread carrying two plans with a null branch matches each round to
    the next round that changes the same plan file.
  - `judge_inputs`: one `judge-known` per round with a next round (interdiff tip to next tip), and
    after `yes` answers one `judge-class` per known-real finding with the plan excerpt (40 lines
    either side of `line`, the whole plan when `line` is null) and its fix.
  - `report_section`: rounds, wall minutes (first to last record of each round's turns), findings
    by class × severity, cost per design-class P0/P1 (wall minutes and Codex tokens over their
    count); the lost `omit_plans` saving = Σ over October pre-merge receipts of their
    `plans_from` blob sizes ÷ 3.5 tokens (an exact number on the fixture); recommendation `keep`
    when any design-class P0/P1 exists, else `inconclusive`, never `remove`.
- [ ] **Step 2: Run** it; it fails.
- [ ] **Step 3: Implement** with `XR.enriched` for missing `plan_blobs`.
- [ ] **Step 4: Run** it; it passes.
- [ ] **Step 5: Commit.** `Classify October's plan-review findings`

### Task 11: Codex memories — the watcher and the `memories` switch (§6, §7.1)

**Depends on:** Task 1, Task 3.

**Files:**
- Create: `.scripts/process_replay/memwatch.py`, `tests/process-replay/t_memwatch.py`
- Modify: `.scripts/xreview-replay.py` (`scratch_clone`, `cmd_cases`, `arms_of`, `prepare`,
  `run_job`, `cmd_run`, `cmd_report`, `main`), `tests/xreview-replay.test.sh`

**Interfaces:**
- Produces, `memwatch.py`: `cmd_memories_watch(a)` (`--source ~/.codex/memories`,
  `--interval 60`, `--seed DIR`, `--seed-at ISO`, `--once`), writing under
  `$XDG_STATE_HOME/process-replay/memwatch/`: `polls.jsonl` (`{at, hash}` per poll, plus
  `snapshot` when one was taken) and `snapshots/<at>-<hash12>/`;
  `digest(src) -> str`; `snapshot_for(wdir, dispatched_at, interval=60) -> (str|None, str)`;
  `first_poll(wdir) -> str|None`.
- Produces, `xreview-replay.py`: `cases --switch memories --memwatch DIR`, arms `A`, `A2`
  (snapshot home), `B` (`nomem` home), `TOKEN_CAP` 20M for this switch.

- [ ] **Step 1: Write the failing tests.**

  `t_memwatch.py`:
  - `polls_and_snapshots`: three polls with no change log three lines and one snapshot; a change
    logs a new snapshot; `.git` is never copied; the source's listing is unchanged; nothing is
    written outside the watch dir.
  - `copy_verified`: when the source changes between the digest and the copy (a test hook runs
    between them), the copy's digest differs, the copy is discarded, the poll is logged with
    `unstable: true` and no snapshot is recorded for that hash; the next stable poll snapshots.
  - `seed`: `--seed` with `--seed-at` registers the seed as the first snapshot at that time, after
    its digest is computed from the seed itself.
  - `snapshot_for`: equal hashes around the dispatch → that hash's snapshot; different →
    `(None, "memories changed around the dispatch")`; either surrounding poll `unstable` →
    `(None, "memories changed around the dispatch")`, even with equal hashes and an earlier
    snapshot of that hash; polls more than `2 × interval + 30` s apart → `(None, "missing poll")`;
    no poll after → `(None, "no poll after the dispatch")`.

  `tests/xreview-replay.test.sh`, new section RP7:
  - `memories_cases`: only k = 1 rounds of branches whose first receipt follows the watcher's
    first poll are taken, at most 10; one with a changed interval is dropped and reported.
  - `memories_arms`: A and A2 run with `CODEX_HOME` the snapshot's `mem-<hash12>` home and B with
    `nomem` (stub rpc log); all three get the same packet.
  - `scratch_no_alternates`: every switch's clones are built by `scratch.build`: no
    `objects/info/alternates`, and a later fix commit does not resolve.
  - `memories_report`: the §5.5 bar (B ≥ min(A, A2) recall; no P0/P1 that A and A2 both found
    missed by B) plus tokens per turn per arm.
- [ ] **Step 2: Run** both; they fail.
- [ ] **Step 3: Implement.** The digest is SHA-256 over sorted relative paths and contents,
  `.git` excluded. Snapshots are `cp -c -R` (APFS clone), falling back to a plain copy, and kept
  only when the copy's own digest equals the poll's. The
  existing switches keep their behaviour except the clone builder; `scratch_clone` is removed.
- [ ] **Step 4: Run** `t_memwatch.py` and `./tests/xreview-replay.test.sh`; they pass.
- [ ] **Step 5: Commit.** `Watch Codex memories and add the memories switch to the review replay`

### Task 12: `pending`, `cleanup` and the end-to-end dry run

**Depends on:** Tasks 1–11.

**Files:**
- Create: `tests/process-replay/t_e2e.py`
- Modify: `tests/process-replay/helpers.py` (only if the e2e fixture needs a shared builder),
  `.scripts/process_replay/loop.py` (`cmd_cleanup` only, if the e2e test shows a gap)

- [ ] **Step 1: Write the failing test** `e2e_stub_daemon`: one fixture branch through
  `snapshot → cases → inject → run → match → … → report` with canned judge answers (written by the
  test whenever `pending` lists an input) and a stub rpc whose rounds find one defect each; the
  report's status is computed, `cleanup` archives every thread in `threads.json`, stops the stub
  daemon, removes `scratch/`, `work/` and `views/`, and keeps every JSON file. A second case:
  `--dry-run` on the same fixture starts no daemon and no turn (stub logs empty).
- [ ] **Step 2: Run** it; fix what it finds, in the module that owns it.
- [ ] **Step 3: Run** `./tests/run.sh` (every default suite) and
  `./tests/run.sh xreview git-forge-guard wt-functions` (the heavy ones, because `.scripts/` and
  the xreview harness changed); report passed/total.
- [ ] **Step 4: Commit.** `Test the replay harness end to end on a stubbed daemon`

### Finishing Part A

- [ ] Final whole-branch review (`sp-architect`), then the Codex pre-merge review
  (`xreview dispatch --checkpoint pre-merge --diff main...replay-set`), fixing every finding.
- [ ] Mark this plan's Part A done in its Status line; push `replay-set`.
- [ ] Give Michael the watcher command, so §6's collection starts at once:
  `.scripts/process-replay.py memories-watch --seed ~/Code/.replay/snapshot/2026-11-02/codex-memories --seed-at 2026-11-02T13:21:43Z`
  (in a background pane, or as a launchd job if he prefers), and the Part B prompt.

## Part B — the run (a session rooted at `~/Code/.replay`)

Driven from `~/Code/.replay` so `measure-interventions.py` leaves it out (§7.3). Harness commands
run unsandboxed (they read the ledgers, write `$XDG_STATE_HOME`, and talk to the replay daemon).
Judges are `sp-standard`, final reviewers `sp-architect`; each gets its own brief path (the
per-input `<kind>/<id>.brief.md`, the final review's `brief.md`, or the recreation's JSON) and
nothing else (§7.1). `process-replay pending` lists what waits on Claude, with each brief path.

1. **Login.** Michael runs the line `process-replay home --login-cmd` prints, as `! …`.
2. **Mechanism.** `home --name nomem --start --probe`. It must pass every check. If it fails,
   stop and report to Michael, before any replay turn: the other §7.2 option, a per-thread setting,
   would put replay rollouts on his daemon, so it is his call.
3. `snapshot`, then `cases` and its judges until `cases` reports the inventory complete.
4. `inject` and its judges and recreations (`sp-standard`, one per `recreate/<id>.json`) until
   `cases.json` is final. Report the case count; fewer than 10 is reported, not padded.
5. Loop `run` (background, unsandboxed) and `match`, dispatching final reviewers and judges, until
   every run has ended. The driver saves each final reviewer's last message, verbatim, to
   `final/<id>/answer.md`. A weekly-usage pause waits for the reset and resumes.
6. `report`. Then `cases --plans`, its judges, and `report` again for §5.
7. In the dotfiles checkout on `replay-set`: §11 of the spec gets the results (tables from
   `report.md`, the recommendation per removal, the costs); commit; Codex pre-merge review of the
   results commit; push. Michael rules on each removal; adoption waits until after the 2026-11-15
   reading.
8. `cleanup`; `home --name nomem --stop`.

§6 runs once 10 cases have accrued (about a week): `xreview-replay.py cases --switch memories`,
its judges, `run` (unsandboxed; it starts each needed home's daemon in turn), `match`, judges,
`report`; results into §11 the same way.

## Rulings

Builder's calls the spec leaves open (§12) or does not settle in detail. The controller copies
them into a new "Implementation notes" section at the end of the spec with the Part A commits.

- **R1 — memories mechanism (§7.2): a second daemon with its own `CODEX_HOME`**, not a
  per-thread setting. It keeps replay rollouts out of `~/.codex` entirely, so they can never feed
  memory generation, and §6's A and A′ need a home holding a snapshot anyway. Its own login keeps
  token refreshes apart from Michael's daemon. There is no fallback onto the live daemon: if the
  probe fails, the run stops and Michael decides (Part B step 2).
- **R2 — build checks (§12):** syntax checks per revert, `cargo check` once for Rust; no .NET or
  JavaScript build (not cheap).
- **R3 — "merged" (§4.1)** needs local merge evidence (ancestry, a rebase by `git cherry`, or a
  squash by tree equality; Task 5) with the merge inside the window. The destination's tip is read
  from the original repository's refs (read only); a branch without evidence is excluded and
  counted, never assumed merged.
- **R4 — leak scan (§7.1)** also covers the final reviewer's transcript, which can read the
  original checkout just as Codex can.
- **R5 — judges.** The per-task finding list, their severities and their fixes come from one
  `judge-task` per task, which reads every review and re-review report of that task (reviews are
  free text) and marks breakage a fix introduced; one `judge-dedup` per branch merges duplicates;
  a pre-merge finding from round 2 or later counts only when `judge-present` finds it at the
  round-1 tip.
- **R6 — `pending`, `home` and `memories-watch`** are added subcommands (§12 leaves names open).
