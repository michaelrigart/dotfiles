# Archive finished review threads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented (branch `feat/archive-review-threads`; no MR, a dotfiles line)

> **Completed 2026-11-11.** Executed on `feat/archive-review-threads`; do not run it again. Its banners and execution notes bind that run only.

**Goal:** Record which threads `xreview` starts, so that `wt-rm` can archive them for good once a checkout is removed. Add a re-runnable cleanup for the leftovers, and stop `archive_superseded` dropping ids it failed to archive.

**Architecture:**
- `xreview-rpc` (Python, stdlib only) owns everything new:
  - the per-checkout `started` list: written by `thread-start --started`;
  - `archive-checkout --dir`, the step `wt-rm` calls last;
  - `cleanup [--archive]`, the one-off command;
  - an idempotent `thread-archive`.
- `xreview` passes `--started` at its two thread starts, and keeps failed ids in its `superseded` queue.
- `wt-rm` calls `archive-checkout` only after Git has removed the checkout. It reports failures without changing its own exit status.

**Tech Stack:** `/usr/bin/python3` 3.9 (stdlib only), bash 5 (`xreview`), zsh (`wt-rm`), the existing shell suites.

**Spec:** `docs/superpowers/specs/2026-11-11-archive-review-threads-design.md` (as amended 2026-11-11).

## Global Constraints

- Nothing writes into the app's files: `~/.codex/sqlite/codex.db`, `~/Library/Application Support/Codex` and the rest (spec Non-goals).
- Only ids in a `started` list are ever archived by `wt-rm`. A pinned thread (`pin`, `XREVIEW_THREAD`) is never in one, and `pin` is never touched.
- A thread is archived for good only when both of these lie under the removed checkout: its `started` path, and the `cwd` the daemon records for it (`thread/read`). Paths are compared whole components at a time, by real path, through the existing `under()`.
- A failed or unconfirmed archive never changes `wt-rm`'s order, refusals or exit status. It prints the id and the retry command.
- Release (`xreview-rpc release`) keeps today's behaviour for every thread: archive, then restore.
- A thread with no turns and no `started` entry is never selected by the cleanup.
- The cleanup never touches a thread whose recorded `cwd` exists, and never selects a thread whose origin differs from its recorded `cwd` (spec §3, amended).
- `xreview-rpc` keeps its pinned `#!/usr/bin/python3` and pinned `PATH`. A compressed rollout is read with `zstd -dc --`, as `dot_claude/xreview-packet.py` does; `zstd` is in the Brewfile.
- Suites fake the daemon only: `XREVIEW_RPC_STDIO` (`tests/xreview-rpc.test.sh`), or the `xreview-rpc` stubs in `tests/xreview.test.sh` and `tests/wt-functions.test.sh`. Never the real daemon.
- Off-limits files belong to other lines and stay untouched:
  - `feat/wt-dotfiles`: `dot_claude/modify_private_settings.json`, `.chezmoitemplates/agents/*`, the sandbox suites;
  - `feat/draft-status`: `dot_config/herdr/*`, the herdr-phase LaunchAgent plist, `tests/herdr-*`.

## Review Focus

1. **A checkout reached through a symlinked parent.** `--dir` is given as written, while `started` holds the real path. The checkout must still match. Test AC10.
2. **A crash mid-append leaves a partial last line in `started`.** Readers skip it, and the next append starts on a fresh line, so neither record is lost. Test ST3.
3. **The daemon is down with nothing to archive** (a checkout `xreview` never reviewed). `archive-checkout` exits 0 without connecting, so `wt-rm` prints nothing. Test AC6.
4. **A retry after a partial run, or a thread archived by hand.** An already-archived thread counts as done: its record is dropped and `review-thread` is cleared. Tests AC9, K2.
5. **A path whose existence cannot be read** (a stat error other than "no such file"). It is never treated as gone. Tests AC5b, CL5b.

---

### Task 1: the `started` list, written by `thread-start --started`

**Depends on:** none.

**Files:**
- Modify: `dot_local/bin/executable_xreview-rpc`: the usage docstring, the new helpers next to the release records, `cmd_thread_start`, `main`'s parser.
- Test: `tests/xreview-rpc.test.sh`: new section `ST`, after `B2`.

**Interfaces:**
- Produces:
  - `xreview_state_root() -> str`: `$XDG_STATE_HOME/xreview`, else `~/.local/state/xreview`.
  - `started_lock(path: str, deadline: float) -> int | None`: an fd holding `flock(LOCK_EX)` on `path + ".lock"`, or None at the deadline.
  - `started_append(path: str, tid: str, checkout: str) -> None`. It appends one line `{"id": tid, "path": os.path.realpath(checkout)}` under the lock, then fsyncs. When the file does not end in `\n`, a `\n` goes first. It waits up to `XREVIEW_STARTED_LOCK_WAIT` seconds (`env_secs`, default 10). It raises `RecordError` for an id `THREAD_ID` refuses, `TimeoutError` at the deadline, and `OSError`.
  - `read_started(path: str) -> list[tuple[str, str]]`: (id, path) for each well-formed line, in order. A malformed line is skipped; a missing file is `[]`.
  - CLI: `xreview-rpc thread-start --cwd DIR [--started FILE]`.

- [ ] **Step 1: Write the failing tests (section `ST`)**, with `XDG_STATE_HOME="$T/st"` and `F="$T/st/xreview/r/started"`. The section makes its own fixtures, because section R's `$T/w` does not exist yet when ST runs: `SR="$(mkdir -p "$T/st/repo" && cd "$T/st/repo" && pwd -P)"`, and `ln -s "$SR" "$T/st/link"`.
  - ST1: `rpc thread-start --cwd "$T/st/link" --started "$F"` prints `th-new-1` and exits 0. `F` holds exactly `{"id": "th-new-1", "path": "$SR"}` (compare with `jq -c`).
  - ST2: two starts (`th-new-1`, then `th-new-2`) leave two lines, in that order.
  - ST3: with `F` pre-seeded with `{"id":"a","path":"/x"}` and no newline, a start leaves `read_started(F)` = `[("a","/x"),("th-new-1",<path>)]`. With `F` seeded as `{"id":"a","pa` (a partial line), it is `[("th-new-1",<path>)]`.
  - ST4: when `F` is a directory, the id is still printed and the exit status is 0. Stderr contains `could not record th-new-1`.
  - ST5: a background `/usr/bin/python3` holds `flock` on `F.lock` for 3 s, with `XREVIEW_STARTED_LOCK_WAIT=0.3`. The id is printed, the exit status is 0, stderr contains `could not record th-new-1`, and `F` gains no line.
  - ST6: `thread/start` refused: exit 1, and `F` does not exist.
  - ST7: `thread/start` answers the id `../x`: it is printed, nothing is appended, and stderr contains `could not record ../x`.
- [ ] **Step 2: Run them; they fail.** `./tests/run.sh xreview-rpc`. Expected: the ST cases FAIL (unknown argument `--started`).
- [ ] **Step 3: Implement.**
  - Add the helpers above.
  - `cmd_thread_start`: after `thread/start` answers an id, and when `a.started` is set, call `started_append(a.started, tid, a.cwd)` before printing. On `RecordError`, `TimeoutError` or `OSError`, print `err(f"could not record {tid} in {a.started}: {e}; it will not be archived when its checkout is removed")` and still print the id and return 0.
  - Add `--started` to `main`'s parser, and the line to the usage docstring.
- [ ] **Step 4: Run them; they pass.** `./tests/run.sh xreview-rpc`. Expected: PASS, every section.
- [ ] **Step 5: Commit.** `Record the review threads xreview-rpc starts`

### Task 2: `archive-checkout --dir`, and `thread-archive` that accepts an archived thread

**Depends on:** Task 1.

**Files:**
- Modify: `dot_local/bin/executable_xreview-rpc`: `cmd_thread_archive`, the new helpers and command, `main`, the docstring.
- Test: `tests/xreview-rpc.test.sh`. Extend `fake.py` with `by_thread`. Add section `K2` after `K`, and section `AC` after `R`.

**Interfaces:**
- Consumes: `xreview_state_root`, `started_lock`, `read_started` (Task 1); `under`, `archived`, `SOURCE_KINDS`, `THREAD_ID` (existing).
- Produces:
  - `gone(path: str) -> bool | None`. `os.lstat` raising `FileNotFoundError` is True, success is False, and any other `OSError` is None.
  - `started_drop(path: str, ids: set[str]) -> None`: under the lock, rewrites `path` without those ids (tmp + `os.replace`), and removes the file when nothing is left.
  - `clear_review_thread(sd: str, tid: str) -> bool`: removes `sd/review-thread` when its stripped content is `tid`.
  - `archive_for_good(c, tid: str, cwd: str) -> str | None`. It sends `thread/archive`, then always asks `archived(c, tid, cwd)`. It returns None only when that answer is True, whether `thread/archive` answered or was refused (spec §2: the archived listing confirms, C9). Otherwise it returns the reason:
    - `archive failed: <message>` when the archive was refused and the listing does not show the thread;
    - `archive not confirmed` when the archive answered but the listing is False or unreadable.
  - CLI: `xreview-rpc archive-checkout --dir DIR`.
    - stdout: one `archived <id>` per confirmed thread.
    - Exit codes: 0 when everything is done or there is nothing to do; 1 on any failure; 2 when `DIR` still exists; 5 when the daemon is unreachable and there are candidates.
    - On every non-zero exit but 2, the last stderr line is `xreview-rpc: retry: xreview-rpc archive-checkout --dir <shlex.quote(DIR)>`.

- [ ] **Step 1: Extend the fake daemon.** A run may hold `"by_thread": {method: {threadId: response-or-list}}`. It is consulted before `responses`, keyed on `params.threadId`; a list answers successive calls, as `responses` lists do.
- [ ] **Step 2: Write the failing tests.**
  - `K2`:
    - a refused `thread/archive`, with `thread/read` giving a `cwd` and `thread/list` listing the id, exits 0;
    - the same with `thread/list` not listing it exits 1.
  - `AC`: fixtures under `XDG_STATE_HOME="$T/ac"`, using the root `"$T/ac/xreview"`. `W=$(realpath "$T/w")`, and `G="$W/gone"` never created.
    - AC1:
      - state dir `g` has a `started` file with `a` (path `G`) and a `review-thread` naming `a`;
      - state dir `n` has a `started` file with `x` (path `G/.claude/worktrees/x`) and a `pin` naming `a`;
      - the daemon reads `a` at cwd `G` and `x` at its own path.
      - Expected: stdout is `archived a`, then `archived x`; exit 0; both `started` files are gone; `g/review-thread` is gone; `n/pin` still names `a`.
    - AC2: a thread at cwd `G` that is in no `started` list is never asked for. The fake log has no `thread/read` and no `thread/archive` for it.
    - AC3 (the collision): one state dir's `started` holds `p` (path `"$W/r/a_b"`, gone) and `q` (path `"$W/r/a/b"`, created). Its `review-thread` names `q`. `--dir "$W/r/a_b"` archives only `p`, and `review-thread` still names `q`.
    - AC4: `started` path `G`, but the daemon's cwd is `"$W/elsewhere"`. Nothing is archived; exit 0; stderr has `kept <id>`; the entry stays.
    - AC5: `--dir` exists: exit 2, stderr `still exists; nothing archived`, and the fake log is empty.
    - AC5b: `--dir` under a directory with mode 000 (skipped when running as root): exit 1, `cannot tell whether`, and nothing is archived.
    - AC6: no candidates and `XREVIEW_RPC_STDIO=false`: exit 0, and no output.
    - AC7: candidates and `XREVIEW_RPC_STDIO=false`: exit 5, and the last stderr line is the retry line.
    - AC8:
      - `thread/archive` is refused and `thread/list` does not list the thread;
      - expected: exit 1, stderr has `<id>: archive failed`, then the retry line;
      - the entry and `review-thread` stay.
    - AC9: `thread/archive` is refused but `thread/list` lists the thread. It is printed `archived <id>`, its entry is dropped, and the exit status is 0.
    - AC10: the section makes its own symlink, `ln -s "$W" "$T/ac/wlink"`. Section R's `$T/w/link` points at `$W/repo`, so it is not used. `--dir "$T/ac/wlink/gone"` matches `started` paths recorded under `$W/gone`.
    - AC11: the daemon reads the thread as `active`. Exit 1, `<id>: running a turn`, and no `thread/archive` is sent.
    - AC12: `thread/archive` answers, but `thread/list` does not list the thread. Exit 1, stderr has `<id>: archive not confirmed`, and the entry and `review-thread` stay.
    - AC13: `thread/archive` answers, but `thread/list` errors. The result is the same as AC12.
- [ ] **Step 3: Run them; they fail.** `./tests/run.sh xreview-rpc`. Expected: K2 and AC FAIL.
- [ ] **Step 4: Implement.**
  - `cmd_thread_archive`: on an error answer, `thread/read` the thread. When its `cwd` is a non-empty string and `archived(c, tid, cwd) is True`, return 0.
  - `cmd_archive_checkout`, in this order:
    1. Check `gone(a.dir)`.
    2. Collect `(state_dir, id, path)` from every `<root>/*/started` with `under(path, a.dir)`. With none, return 0 before connecting.
    3. Connect.
    4. Per unique id: `thread/read` (`includeTurns: False`). Keep a thread only when its `cwd` is `under(cwd, a.dir)`, and refuse it when its status is `active`.
    5. Call `archive_for_good`.
    6. On a confirmed archive: `started_drop` from each state dir that listed the id, and `clear_review_thread` there.
  - The stderr forms are exact:
    - `<id>: cannot read it from the daemon`
    - `<id>: running a turn`
    - `<id>: <reason>`
    - `kept <id>: the daemon records it in <cwd>, outside <DIR>`
    - `<DIR> still exists; nothing archived`
    - `cannot tell whether <DIR> exists (<strerror>); nothing archived`
  - A connection lost mid-run is exit 1, with the retry line.
- [ ] **Step 5: Run them; they pass.** `./tests/run.sh xreview-rpc`. Expected: PASS.
- [ ] **Step 6: Commit.** `Archive a removed checkout's review threads for good`

### Task 3: `cleanup [--archive]`

**Depends on:** Task 2.

**Files:**
- Modify: `dot_local/bin/executable_xreview-rpc`: the new helpers and command, `main`, the docstring.
- Test: `tests/xreview-rpc.test.sh`: new section `CL`, after `AC`.

**Interfaces:**
- Consumes: `gone`, `archive_for_good`, `started_drop`, `clear_review_thread`, `read_started`, `xreview_state_root` (Tasks 1 and 2).
- Produces:
  - `is_packet(text: str) -> bool`: `text.lstrip().startswith("<cross-review-request>")`.
  - `classify(messages: list[str]) -> str | None`:
    - `"packet"` when the first message is a packet;
    - `"old pane"` when there are at least two messages, the first is not a packet, and every later one is;
    - otherwise None.
  - `user_messages(c, tid: str) -> list[str] | None`: the texts of every `userMessage` item, oldest first, from `thread/turns/list` with `itemsView: "summary"`, following `nextCursor` across every page. None when any page answers with an error, or when a cursor repeats. Such a thread goes under "could not read", never selected.
  - `rollout_origin(path: str) -> str | None`: the `payload.cwd` of the rollout's first `session_meta` line. A `.zst` file goes through `zstd -dc --`. None when the file cannot be read.
  - CLI: `xreview-rpc cleanup [--archive]`. Exit 0, or 1 when an archive fails, or 5 when the daemon is unreachable.

- [ ] **Step 1: Write the failing tests (section `CL`).** Every listed thread has a cwd under `G` (gone) unless named otherwise. Its `path` is a small rollout fixture whose first line is `{"type":"session_meta","payload":{"cwd":<cwd>}}`.
  - CL1: one dry run over these threads, all listed by `thread/list` (archived false):
    - `s`: in `started`;
    - `p`: a packet first;
    - `o`: `hi`, then two packets;
    - `m`: `hi`, then a packet, then `thanks`;
    - `e`: the cwd exists, and its first message is a packet;
    - `pn`: a packet first, and named in a `pin`;
    - `z`: no turns and no started record;
    - `d`: a packet first, but its rollout origin is `"$W/other"`;
    - `zs`: like `p`, with a `.jsonl.zst` rollout made with `zstd -q`. Without `zstd` on `PATH`, the `zs` case prints `  SKIP: zstd not installed (CL1 zs)` and is left out, as `tests/xreview-packet.test.sh` does.
    - Expected: `s` appears under `== Started by xreview (started record)`.
    - Expected: `p` and `zs` appear under `== First message is a review packet`.
    - Expected: `o` appears under `== Old pane sessions (a greeting, then only review packets)`.
    - Expected: `pn` appears under `== Not selected: pinned`.
    - Expected: `d` appears under `== Not selected: recorded cwd differs from the origin`, with `origin $W/other`.
    - Expected: `m` and `e` appear nowhere.
    - Expected: there is no `thread/turns/list` for `e` and no `thread/archive` at all.
    - Expected: the output contains the line `Not selected: 1 threads in gone checkouts with no turns and no started record (the historical coverage limit).`
    - Expected: exit 0.
  - CL2: the same fixtures with `--archive`.
    - `thread/archive` goes to exactly `s`, `p`, `zs` and `o`.
    - A `review-thread` naming `p` is cleared, and the `started` entry of `s` is dropped.
    - The `pin` naming `pn` is untouched.
    - The output ends `Archived 4 of 4.` (`3 of 3` when the `zs` case is skipped), and the exit status is 0.
  - CL3: `--archive` with `p`'s archive refused and unconfirmed. The others are archived, stderr names `p`, and the exit status is 1.
  - CL4: `s`'s `started` path is `"$W/other"`, so it is listed under the differs heading and not selected.
  - CL5: `p`'s rollout is missing, so it is listed under `== Not selected: could not read` and not selected.
  - CL5b: a cwd whose existence cannot be read (a mode 000 parent) goes under `could not read`.
  - CL6: `XREVIEW_RPC_STDIO=false` exits 5.
  - CL7: `thread/list` in two pages (`nextCursor`) lists threads from both pages.
  - CL8: user history across pages (`by_thread` lists for `thread/turns/list`):
    - `h1` has a greeting and packets on one page, and a personal message on the next. It is listed nowhere, and is not archived with `--archive`.
    - `h2` has packets on its first page, and its second page errors. It goes under `could not read`, and is not archived with `--archive`.
    - `h3` has a greeting on one page and packets only on the next. It goes under the old pane heading, which shows the pages are joined in order.
- [ ] **Step 2: Run them; they fail.** `./tests/run.sh xreview-rpc`. Expected: CL FAIL.
- [ ] **Step 3: Implement `cmd_cleanup(a)`.**
  1. List every unarchived thread (`thread/list`, `archived: False`, every source kind, all pages).
  2. Skip a thread whose `gone(cwd)` is False. File one whose `gone(cwd)` is None under "could not read".
  3. File pinned ids (any `<root>/*/pin`) under "pinned".
  4. A thread in some `started` list is `started`, and its origin is its `started` path. Otherwise classify it from `user_messages`:
     - a None answer goes under "could not read";
     - a thread with no messages is counted for the limit line and not listed;
     - an unclassified one is not listed.
     Its origin is `rollout_origin(thread.path)`.
  5. An unreadable origin goes under "could not read". An origin whose real path is not the real path of `cwd` goes under "differs".
  - Each line: `  <id>  <cwd>  <%Y-%m-%d %H:%M of updatedAt>  <started|packet|old pane>`, plus the reason or `origin <path>` for the not-selected headings.
  - Print every heading, in the order above, as `== <heading> (<n>)`.
  - Then the three limit lines:
    - `Selected: <n>. Only threads whose recorded cwd is gone are considered; a checkout that exists is never touched.`
    - the coverage line above;
    - `Selection uses the daemon's recorded cwd; a thread whose origin differs is listed above and never selected.`
  - Without `--archive`, then print `Dry run: nothing archived. Run again with --archive to archive the selected threads.`
  - With `--archive`, archive each selected thread with `archive_for_good`:
    - print `archived <id>`;
    - drop the id from every `started` list;
    - clear every `review-thread` that names it;
    - end with `Archived <m> of <n>.`
- [ ] **Step 4: Run them; they pass.** `./tests/run.sh xreview-rpc`. Expected: PASS.
- [ ] **Step 5: Commit.** `Add a cleanup for review threads left by removed checkouts`

### Task 4: `xreview` records its threads and keeps unarchived superseded ids

**Depends on:** Task 1. It runs alone: the `xreview` suite is `# test-serial`.

**Files:**
- Modify: `dot_local/bin/executable_xreview`:
  - `archive_superseded`, around line 717;
  - the `thread-start` calls in `cmd_dispatch` (around line 1385) and `_slice_start` (around line 1844).
- Test: `tests/xreview.test.sh`: the stub's `thread-archive` knob, `T1`, `M3`, and the slice section that starts threads.

**Interfaces:**
- Consumes: `xreview-rpc thread-start --cwd DIR --started FILE` (Task 1).

- [ ] **Step 1: Write the failing tests.**
  - The stub: `thread-archive` exits 1 when `--thread` equals `RPC_ARCHIVE_FAIL_FOR`.
  - T1: `called "xreview-rpc thread-start --cwd $CWD --started $STATE/started"` is 1.
  - A dispatch whose `turn-start` fails (`RPC_START_FAIL=1`) still called `thread-start` with `--started`.
  - In the slice section, every slice's `thread-start` carries `--started $STATE/started`.
  - M3b: superseded is `[U1, U2]` and `RPC_ARCHIVE_FAIL_FOR=$U1`. After a successful dispatch, `$STATE/superseded` holds exactly `$U1`. A second dispatch without the knob archives `U1` and removes the file.
- [ ] **Step 2: Run them; they fail.** `./tests/run.sh xreview`. Expected: the new cases FAIL.
- [ ] **Step 3: Implement.**
  - Add `--started "$(state_dir)/started"` to both `thread-start` calls.
  - `archive_superseded` collects each id whose `thread-archive` fails, in a newline-joined string. At the end, it removes the file when none failed. Otherwise it writes them to `$f.tmp` and `mv -f` it over `$f`, best effort (`|| true`), keeping order.
  - Update its comment: a failed id stays queued.
- [ ] **Step 4: Run them; they pass.** `./tests/run.sh xreview`. Expected: PASS, the full suite.
- [ ] **Step 5: Commit.** `Record xreview's review threads and keep failed superseded archives queued`

### Task 5: `wt-rm` archives a removed checkout's review threads last

**Depends on:** Task 2's CLI contract only; the suite stubs `xreview-rpc`.

**Files:**
- Modify: `dot_config/zsh/functions`:
  - a new `_wt_rm_archive <dest>` above `_wt_rm_registration`;
  - calls in `wt-rm`, after the "still exists" warning, before `return 0`;
  - a call in `_wt_rm_registration`, after `_wt_rm_branch`, keeping its status;
  - step 8 in `wt-rm`'s header comment.
- Test: `tests/wt-functions.test.sh`: the stub, section `W` (new cases `W9`–`W13`), and W1's exact `XLOG` expectation.

**Interfaces:**
- Consumes: `xreview-rpc archive-checkout --dir DIR`. Stdout carries `archived <id>` lines; the exit codes are 0, 1, 2 and 5; on failure the stderr's last line is a retry line.
- Produces: `_wt_rm_archive <dest>`, which always returns 0.
  - Each `archived <id>` prints `✓ archived review thread <id>`.
  - Exit 5 prints `wt-rm: the Codex daemon is not reachable — review threads not archived; the removal stands.`
  - Any other non-zero exit prints `wt-rm: could not archive every review thread of <dest> (status <n>); the removal stands.`, then the command's stderr lines indented by four spaces.
  - A missing command prints `wt-rm: xreview-rpc is missing — review threads not archived; the removal stands.`
  - Every failure ends with `    Retry: xreview-rpc archive-checkout --dir <_wt_q dest>`.

- [ ] **Step 1: Write the failing tests.**
  - The stub: when `$1` is `archive-checkout`, answer from `MOCK_XARCH_OUT`, `MOCK_XARCH_ERR` and `MOCK_XARCH_RC` instead of `MOCK_XRPC_*`. Both calls still log to `XLOG`.
  - W1's `XLOG` expectation becomes the release call, then `---\narchive-checkout\n--dir\n$RO`.
  - W9: a removal with `MOCK_XARCH_OUT='archived th-1\n'` returns 0, prints `✓ archived review thread th-1`, and calls `archive-checkout` after `release`.
  - W10: `MOCK_XARCH_RC=1` with an error line returns 0. It prints the "could not archive" line, the indented error, and `Retry: xreview-rpc archive-checkout --dir`.
  - W11: `MOCK_XARCH_RC=5` returns 0 and prints the daemon line and the retry.
  - W12: aborts after the release never call `archive-checkout`. These are check 4 finding a process (the existing busy-scan fixture) and Git refusing the removal (the existing git-fail fixture).
  - W13: the `_wt_rm_registration` path calls `archive-checkout` once its registration is removed, and its status is still `_wt_rm_branch`'s.
- [ ] **Step 2: Run them; they fail.** `./tests/run.sh wt-functions`. Expected: the new cases and the updated W1 FAIL.
- [ ] **Step 3: Implement `_wt_rm_archive`** and the two calls. The command's stdout goes to a variable; its stderr goes to a `mktemp` file, removed before returning.
- [ ] **Step 4: Run them; they pass.** `./tests/run.sh wt-functions`. Expected: PASS, the full suite.
- [ ] **Step 5: Commit.** `Archive a removed checkout's review threads at the end of wt-rm`

## Execution order

- Batch 1: Task 1.
- Batch 2: Tasks 2 and 5. Their files are disjoint and their suites share nothing.
- Batch 3: Task 3.
- Batch 4: Task 4, alone (`xreview` is `# test-serial`).
- Then:
  - the full suite: `./tests/run.sh`;
  - `./tests/run.sh xreview git-forge-guard wt-functions`;
  - Codex pre-merge;
  - the cleanup's dry run on the real daemon (`xreview-rpc cleanup`, unsandboxed). Its output goes in the report.

## Rulings

Made by the line inside the approved spec (2026-11-11):

1. **Where the `started` append lives.** It is in `xreview-rpc thread-start --started`, before the id is printed. A failed append, a lock wait over 10 s or a refused id warns and still returns the id, so the dispatch goes on. Archiving is cosmetic, and the cleanup's packet rule is the fallback.
2. **What `started` holds.** It holds the ids not yet archived for good. A confirmed archive drops the entry, so a later checkout at the same path never re-archives a thread Michael unarchived.
3. **`archive-checkout` refuses while `--dir` exists** (exit 2). A checkout whose files were recreated keeps its threads until the retry; that keeps "checkout gone" literal.
4. **`archive-checkout` reads every state directory's `started`.** A harness worktree nested inside the removed checkout is covered too.
5. **`thread-archive` exits 0 for a thread the archived listing already shows.** Retries are idempotent, and `archive_superseded`'s queue drains.
6. **The cleanup excludes pinned ids,** besides §1's rules.
7. **Unknown is never gone.** A path whose existence cannot be read is never treated as gone.
8. **A thread's origin** is its `started` path, else its rollout's first `session_meta` cwd. A differing or unreadable origin is listed and never selected.
9. **`wt-rm` archives last,** after the branch step and the recreated-files warning. Its status never changes `wt-rm`'s.
10. **A `started` thread whose daemon cwd lies outside the removed checkout** is reported as kept, not as a failure.

Made during execution (2026-11-11):

11. **The ids reach the screen.**
    - On exit 5, `archive-checkout` prints one `<id>: not archived: the Codex daemon is unreachable` line per candidate, before its retry line.
    - `kept <id>: …` notes go to stderr with exit 0.
    - `wt-rm` echoes the command's stderr on every status, minus the command's own `xreview-rpc: retry:` line, and prints its own single `Retry:` line.
12. **`archive-checkout`'s budget** is 60 s plus 10 s per candidate (`XREVIEW_RPC_ARCHIVE_UNIT`, a test knob). A spent budget is worded as one, not as a lost connection.
13. **The cleanup decides by the cwd `thread/read` gives,** which is the recorded cwd (C7), never by the listing's: `thread/list` reports a thread's original cwd.
14. **The cleanup lists, under "differs" and never selects, a review thread whose recorded cwd exists but whose origin is gone.** This is the case the amendment was written for, and it was otherwise invisible.
15. **An archive is confirmed through every cwd the thread may be listed under,** because `thread/list`'s `cwd` filter matches the original cwd: the recorded cwd, plus the `started` paths, the listed cwd or the rollout's origin. `xreview-rpc release` keeps its single-cwd calls (spec §2: release keeps today's behaviour).
16. **Before each archive, the cleanup re-checks** that the recorded cwd is still gone, and keeps a thread that is running a turn.
