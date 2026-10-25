# Review packets that fit the reviewer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented
**Goal:** xreview chooses review packets that fit Codex's context: framing, fit check, fresh
threads, slices, delta rounds and bound plans. The merge gate opens only on whole reviews.
Each behaviour sits behind a switch that a replay of past reviews must pass before it is
turned on.

**Architecture:**
- **Packet module.** A new Python module, `dot_claude/xreview-packet.py`, decides and renders
  packets. It imports the ledger the way the guard does. `xreview` (bash) calls its CLI once
  per dispatch and acts on the JSON decision it prints.
- **RPC.** `xreview-rpc` gains thread listing, fork and a turn report.
- **Gate.** The ledger's `decide()` gains the wholeness rules.
- **Replay.** A replay harness in `.scripts/` reuses the packet module and `xreview-rpc`
  primitives.

**Tech Stack:** bash 5 (`/opt/homebrew/bin/bash`), `/usr/bin/python3` 3.9 (no `match`, no
`X | Y`), jq, git, the Codex app-server daemon over `xreview-rpc`.

**Spec:** `docs/superpowers/specs/2026-10-25-xreview-review-packets-design.md` (read it
whole; section numbers below are the spec's).

## Global Constraints

- Constants, all in `xreview-packet.py`:
  - `BYTES_PER_TOKEN = 3.5`, `FRESH_CONTEXT = 30000`, `RESERVE = 60000`,
    `LIMIT_FRACTION = 0.9`;
  - `MISSING_CAP = 50`, `FILE_LIST_SHARE = 0.1`;
  - `PLAN_PREFIX = "docs/superpowers/plans/"`.
- Switch file `~/.config/xreview/packets.conf`: four lines `framing=off`, `fit=off`,
  `delta=off`, `omit_plans=off`.
  - A missing file, a missing key or any value other than `on` means off.
  - With `framing` off, the other three act as off.
- **With every switch off, the packet is byte-for-byte today's** (reviewer.md, body, DIFFS
  blocks), and the 100 KB cap with `XREVIEW_MAX_DIFF_BYTES` behaves as today.
- The gate never reads `packets.conf`. It judges from the `switches` recorded in each receipt.
- Code that the gate or xreview runs lives in `~/.claude` (`dot_claude/`), never in a
  sandbox-writable directory. Every new managed file under `~/.claude` gets its own
  `.chezmoiignore` re-include.
- No keystroke reaches the pane while a turn runs on its thread (C1). Pane steps run under the
  pane lock.
- Run suites as `./tests/<name>.test.sh` or `./tests/run.sh <name>`, never with an interpreter
  prefix. Report totals as passed/total.
- Implementers do not commit. The controller commits each task on its own.

## Review Focus

1. **A multi-target dispatch** where one target qualifies for a delta and another does not.
   Each target gets its own packet kind. `packet`, `delta_from`, `history`, `plans_from` and
   `missing` live on each target; `clean`, `compacted` and `switches` live on the receipt.
   (Task 5 and Task 8 tests.)
2. **Paths git quotes** (spaces, non-ASCII, quotes, tabs) in the file list and coverage. Match
   on the unquoted path, so a reviewer listing the plain path covers it. (Task 4 test.)
3. **Binary files** in slices and coverage. A binary summary line is a unit whose label is its
   path; it fits any slice and counts as shown. (Task 4 test.)
4. **Collect interrupted between slices.** Exit 3, daemon down, or the pane lock held by
   another dispatch. The next collect resumes at the first unfinished slice and never starts a
   slice twice. (Task 8 test.)
5. **An existing thread whose rollout cannot be read.** Its context is unknown, so it counts as
   not fitting: move to a fresh thread. Only an unreadable window refuses. (Task 5 test.)

---

### Task 1: Protocol spike (controller, unsandboxed)

**Files:**
- Create (scratch, not committed): `$SCRATCH/spike.py`.
- Modify: spec §7, adding "Verified <date>" under step 1.

**Depends on:** none.

- [x] Write `spike.py`. It loads `~/.local/bin/xreview-rpc` with `importlib` (SourceFileLoader)
  for its `Client`, then works on a **scratch thread** whose cwd is a scratch git repo, never
  Michael's pane. In order:
  1. `thread/start`, then one tiny turn ("reply OK").
  2. `thread/turns/list` with `itemsView` `"summary"` and `"full"`. Record each item `type`.
  3. `thread/compact/start` on the scratch thread, then list turns again. Record how the
     compaction appears: an item type, a turn, or neither.
  4. `thread/fork` on the scratch thread, and on one archived review thread from
     `~/.codex/archived_sessions`. Record what the fork copies and the parameters it accepts
     (try `turnId`/`forkAt`-like keys from the binary's strings:
     `strings $(codex-daemon real-bin) | rg -o 'fork[A-Za-z]*'`).
  5. `thread/revert`, or the rollback method the strings name, on a fork, to before a given
     turn. Record the parameter names and the turn list after.
  6. `turn/start` with a `cwd` parameter set to a second scratch dir. Record whether the turn's
     `turn_context` record in the rollout shows that cwd.
  7. In the rollout: the record that carries the context size after a turn
     (`token_count.info.last_token_usage` vs `token_usage_record.usage`), and where
     `model_context_window` appears.
  8. Archive every thread the spike created.
- [x] Run it: `/usr/bin/python3 -I $SCRATCH/spike.py` with the sandbox disabled (daemon
  socket). Expected: a JSON report on stdout.
- [x] Write the facts into spec §7 step 1 as "Verified 2026-10-25:" bullets.
- [x] **If a fact does not hold**, stop and amend the spec and this plan before Task 2. The
  facts this plan relies on are:
  - compaction is visible per turn;
  - fork plus rewind exists, else the spec's replay fallback;
  - turn/start takes a cwd, else the replay runs every arm in a clone at the right tip and
    forks are not used.
- [x] Commit (controller): `git add docs/superpowers/specs/…; git commit -m "Record the verified Codex protocol facts"`.

### Task 2: xreview-rpc — thread turns, fork, turn cwd, turn report

**Files:**
- Modify: `dot_local/bin/executable_xreview-rpc` (argparse in `main`, new `cmd_*` functions).
- Test: `tests/xreview-rpc.test.sh`.

**Depends on:** Task 1.

**Interfaces — Produces:**
- `xreview-rpc thread-turns --thread T` prints `{"turns":[{"id":str,"status":str,"compacted":bool}],"thread_compactions":int|null}`,
  oldest first, every page followed. It lists with `itemsView: "full"`, because `summary`
  hides compactions (spec §7, verified).
  - `compacted` is true when the turn holds a `contextCompaction` item.
  - `thread_compactions` counts the turns whose items are only `contextCompaction` (a TUI
    `/compact`).
  - When any page could not be read in full, the whole answer is exit 1, never a partial
    list. `null` is kept for a listing whose items came back not loaded.
  - Exit 0 ok, 1 cannot list, 5 daemon unreachable.
- `xreview-rpc thread-fork --thread T [--last-turn X] [--cwd DIR]` prints the new thread id.
  It sends `thread/fork` with `lastTurnId` and `cwd` (verified), and `excludeTurns: true`.
  Exit 1 if refused.
- `xreview-rpc thread-unarchive --thread T` sends `thread/unarchive` (exit 1 if refused). It
  is for the replay, which unarchives a historical thread, forks it, and archives it again.
- `xreview-rpc turn-start … [--cwd DIR]` passes `cwd` on `turn/start` (verified).
- `xreview-rpc turn-wait … [--report FILE]`: on exit 0 or 4 it writes
  `{"turn":id,"compacted":bool|null}` to FILE. It re-reads that one turn with `itemsView:
  "full"` for the flag, because turn_state's `summary` hides compactions. It writes `null`
  when the full read fails. Stdout is unchanged.

- [x] **Step 1: Write the failing tests** in the suite's fake-server style:
  - `TT1`: a two-page `thread/turns/list` gives both pages oldest first.
  - `TT2`: a turn holding the compaction item reports `compacted:true`, and others `false`.
  - `TT3`: a list error gives exit 1.
  - `TT4`: with no way to observe a thread-level compaction, `thread_compactions` is
    `null`.
  - `TF1`: `thread-fork --last-turn X --cwd D` sends `thread/fork` with `lastTurnId: X`,
    `cwd: D` and `excludeTurns: true`, and prints the fork's id.
  - `TF2`: a refused fork gives exit 1.
  - `TF3`: `thread-unarchive` sends `thread/unarchive`, and a refusal gives exit 1.
  - `TT5`: thread-turns sends `itemsView: "full"`, and a turn whose only item is
    `contextCompaction` counts in `thread_compactions`.
  - `TC1`: `turn-start --cwd /x` puts `cwd` in the `turn/start` params.
  - `TC2`: without `--cwd`, there is no `cwd` key.
  - `TW1`: `turn-wait --report F` writes the compaction flag of the collected turn, and stdout
    still equals today's findings JSON.
  - `TW2`: a turn whose items are not in the listing writes `compacted: null`.
- [x] **Step 2:** `./tests/xreview-rpc.test.sh`. Expected: the new cases FAIL, the old ones
  pass.
- [x] **Step 3: Implement.** Add `cmd_thread_turns(c, a)` and `cmd_thread_fork(c, a)`, the
  `--cwd` on turn-start and `--report` on turn-wait. Reuse `turn_state`'s paging pattern for
  thread-turns. The compaction check lives in one function, `turn_compacted(turn) -> bool`,
  which turn-wait's report uses as well.
- [x] **Step 4:** `./tests/xreview-rpc.test.sh`. Expected: all pass, as passed/total.

### Task 3: Ledger — plan patches, plan blobs, the wholeness gate

**Files:**
- Modify: `dot_claude/xreview-ledger.py`.
- Test: `tests/xreview-ledger.test.sh`, `tests/xreview-guard.test.sh`.

**Depends on:** none (runs beside Task 2).

**Interfaces — Produces:**
- `patch(repo, base, tip, exclude=())`: `exclude` is a tuple of literal top-level paths left
  out of the text patch. The header-count check counts only rendered records. Binary
  handling is unchanged.
- `blob_patch(repo, path, old_blob, new_blob) -> bytes`: a `diff --git a/<path> b/<path>`
  patch between two blobs, with `DIFF_FLAGS` and `--text`. `old_blob` may be None
  (`/dev/null`).
- `plan_blobs(repo, base, tip) -> dict[str, str]`: each path under
  `docs/superpowers/plans/` added within `base..tip` (old mode `000000`), mapped to its new
  blob id.
- `decide()` adds the §3.7 rules through
  `whole(entries, receipt, target) -> tuple[bool, str]`.
  - A receipt without `packet` on its target is whole.
  - Otherwise, read `receipt["switches"]`, `receipt["clean"]`, `receipt["compacted"]`,
    `target["missing"]`, `target["packet"]`, `target["delta_from"]`, `target["history"]` and
    `target["plans_from"]`.
  - Coverage applies when `switches.framing`. Compaction applies to delta and slices always,
    and to full when `switches.fit`. Where it applies, `compacted` must be exactly `False`:
    `None` (unknown), a missing key or any other value is denied, never read for
    truthiness. The same goes for every other field the rules read:
    - `clean` must be exactly `True` on chain links and plan receipts;
    - `missing` must be exactly `[]` under `framing`;
    - `switches` values must be exactly `True` for a rule to treat that switch as on, and any
      other value counts as off.
  - Walk the chain iteratively, with a visited set, to a `full` root on the same thread. The
    approving target's `history` must list every chain turn, root first.
  - Check `plans_from` entries `{path, nonce, blob}` against the named receipt's
    `plan_blobs`. It must be a `plan`-checkpoint approve, and clean.
  - A false result makes the deny reason
    `"the latest approval is not whole: <reason>"`.
- CLI: `diff REPO BASE TIP [--exclude PATH]...`, and `blob-patch REPO PATH OLD NEW`
  (`OLD` may be `-`).

- [x] **Step 1: Write the failing tests.**
  - Ledger suite:
    - `PX1`: `diff --exclude` drops that file's patch and keeps the header check passing.
    - `PX2`: excluding a path that is binary in the range removes its summary line too.
    - `PB1`: `blob-patch` from `-` renders a whole-file add; between two blobs it renders their
      diff.
    - `PL1`: `plan_blobs` names an added plan, and not a plan that was only modified or was
      unchanged in the range.
  - `W1`–`W12`, in the order of spec §6:
    - legacy whole;
    - framing coverage gap denied;
    - framing off ignores `missing`;
    - compacted delta denied;
    - compacted slices denied;
    - compacted full denied with `fit` on;
    - compacted full allowed with `fit` off;
    - chain valid;
    - broken link, wrong base, unclean link, sliced root, cycle — each denied;
    - `changes` link allowed;
    - `history` missing a chain turn denied;
    - `plans_from` bad receipt, path or blob denied;
    - `W13`: `compacted: null` denied on full with `fit` on, on delta and on slices, and
      allowed on full with every switch off, as today.
  - Guard suite: one end-to-end deny for an unclean approval and one allow for a whole delta
    chain, through `glab mr create`. Use the suite's existing ledger fixtures.
  - Flipping a `packets.conf` file in `XDG_CONFIG_HOME` changes no `decide` result.
- [x] **Step 2:** `./tests/xreview-ledger.test.sh` and `./tests/xreview-guard.test.sh`.
  Expected: the new cases FAIL.
- [x] **Step 3:** Implement the interfaces above. Keep Python 3.9 syntax.
- [x] **Step 4:** Run both suites. Expected: all pass.

### Task 4: Packet module core — switches, framing, units, fit, today's packet

**Files:**
- Create: `dot_claude/xreview-packet.py`.
- Create: `dot_config/xreview/packets.conf` (the four `off` lines).
- Create: `dot_config/xreview/findings.framed.schema.json` (today's schema plus a required
  `reviewed_files`, an array of strings).
- Create: `dot_config/xreview/reviewer-framing.md`.
- Modify: `.chezmoiignore` (`!.claude/xreview-packet.py` beside the other xreview lines).
- Test: `tests/xreview-packet.test.sh` (new; header comment, `missing file under test` exit 2,
  passed/total like the others).

**Depends on:** none (runs beside Tasks 2 and 3; it calls the ledger's existing `patch` and
`raw_records`).

**Interfaces — Produces** (in `xreview-packet.py`; it loads the ledger with
`importlib.util.spec_from_file_location`, path from `XREVIEW_LEDGER` or beside itself):
- `read_switches(path) -> dict[str, bool]`.
- `Unit` (namedtuple): `label, path, text: bytes, plus, minus, binary: bool`.
- `units_for(repo, base, tip, exclude=()) -> list[Unit]`: one per file from `ledger.patch`,
  split at `diff --git` headers.
  - Binary summary lines become `binary=True` units labelled by path.
  - Labels are unquoted paths.
- `split_unit(u, max_bytes) -> list[Unit]`: whole-hunk groups, then line ranges with
  recomputed `@@ -a,b +c,d @@`, then byte ranges at UTF-8 boundaries (never splitting a
  continuation byte), each carrying the `diff --git` header. Labels are `<path>#<i>/<n>`.
- `file_list(entries) -> str`, where `entries` is `[(mark, plus, minus, label)]`. Its fixed
  copy:
  - the header: `Files in this change (<n>):`;
  - one line per entry: `  <mark:9> +<plus> -<minus>  <label>`.
- `estimate_tokens(nbytes) -> int` = `ceil(nbytes / BYTES_PER_TOKEN)`.
- `fits(context_now, nbytes, window) -> bool` =
  `context_now + estimate_tokens(nbytes) + RESERVE <= LIMIT_FRACTION * window`.
- `today_packet(reviewer_md, body, diffs: list[tuple[spec, bytes]]) -> bytes`. It must equal
  what `cmd_dispatch` writes today:
  - `<cross-review-request>\n`, reviewer.md, `\n`, then the body as is;
  - then each `\n\n--- diff (<spec>) ---\n<d>\n--- end diff ---` block. After the last block
    comes one `\n`, and only when there is at least one block (today's
    `[ -z "$DIFFS" ] || printf '%s\n' "$DIFFS"`);
  - then `</cross-review-request>\n`.

  Note that `$(…)` in today's `add_target` strips trailing newlines from each diff `<d>`.
  Reproduce that.
- Fixed framing copy, also in `reviewer-framing.md`:
  - Marks: `shown`, `earlier`, `elsewhere`, `listed`.
  - `reviewer-framing.md` text: "List in `reviewed_files` every file or part label marked
    shown that you reviewed. Do not list a file you did not read."

- [x] **Step 1: Write the failing tests:**
  - `K1`: every switch off gives `today_packet` byte-identical to **golden packets** in
    `tests/fixtures/xreview-packet/`. Capture them once in this task, before Task 6 changes
    the dispatcher: run the unmodified `executable_xreview` with `tests/xreview.test.sh`'s
    stubs and copy `$P/packet`. Six fixtures: no diff, one diff, and two diffs, each with a
    body that ends in a newline and one that does not. Commit them with the task, together
    with the fixture repo recipe as a script beside them, so they can be regenerated from
    `git show 7aab009:dot_local/bin/executable_xreview`.
  - `K2`: switch parsing: a missing file, `fit=yes` and `framing` off each force off.
  - `K3`: `units_for` labels a quoted path (`a b.txt`, `ä.txt`) unquoted (Review Focus 2).
  - `K4`: a binary file is one binary unit (Review Focus 3).
  - `K5`: `split_unit` by hunks, then by lines (the `@@` counts re-add up to the original),
    then a 2 MB single line on a multibyte boundary. Every part ≤ `max_bytes`, and the parts
    concatenate back to the original lines.
  - `K6`: `fits` at the exact boundary: true at equality, false one byte over.
  - `K7`: the framed schema validates `reviewed_files` with xreview-rpc's `validate`.
- [x] **Step 2:** `./tests/xreview-packet.test.sh`. Expected: FAIL (the module is missing).
- [x] **Step 3:** Implement the interfaces, the config files and the `.chezmoiignore` line.
- [x] **Step 4:** Run the suite. Expected: all pass. `command chezmoi --source <checkout>
  managed | rg xreview-packet` lists `.claude/xreview-packet.py`.

### Task 5: Packet module — context, delta, plans, slices, the decision CLI

**Files:**
- Modify: `dot_claude/xreview-packet.py`.
- Test: `tests/xreview-packet.test.sh`.

**Depends on:** Tasks 2, 3 and 4.

**Interfaces — Consumes:**
- Task 2: `thread-turns` JSON.
- Task 3: `blob_patch`, `plan_blobs`, `patch(exclude=)`.
- Task 4: everything.

**Interfaces — Produces:**
- `thread_context(codex_home, thread) -> tuple[int | None, int | None]`: context now, and the
  window, from the thread's newest rollout. Use Task 1's records. Return None for an
  unreadable value. (`Optional` from typing, Python 3.9.)
- `fresh_window(codex_home, repo_common) -> int | None`: the newest `model_context_window`
  among this repository's review threads (ledger receipts' `thread`), else any rollout.
- `delta_base(entries, thread, target, turns) -> dict | None`: the receipt to follow, or
  None. It applies spec §3.4's conditions in order, with `turns` from `thread-turns`.
- `plan_listing(entries, repo, target) -> dict[path, {nonce, blob}]`, per spec §3.5.
- `build(request) -> decision`.
  - The request JSON:
    `{checkpoint, body_file, reviewer_md, framing_md, cap, switches_file, codex_home,
    thread: str|null, turns_file: str|null, targets: [normalized targets], specs: [str],
    missed: [labels]}`.
  - The decision JSON:
    `{action: "send"|"fresh"|"slices"|"refuse", reason, kind: "full"|"delta"|"slices",
    packets: [{file, shown: [labels]}], targets: [target + {packet, delta_from, history,
    plans_from}], switches}`.
  - With `fit` off, `cap` (bytes) applies exactly as today. The `refuse` reason is today's
    `too large` message, verbatim.
  - With `fit` on: delta or full, then the fit on this thread, then a fresh thread, then
    slices (§3.2).
  - Slices are packed with each slice's `need` ≤ limit at `FRESH_CONTEXT`. The file list is cut
    to own-units lines when it exceeds `FILE_LIST_SHARE` of a slice (§3.3).
- Fixed copy:
  - delta header: `This round follows <nonce> on this thread. The change as of that round is
    earlier in this thread; below is what changed since. Judge the change as it now stands,
    including how the new code meets the old.`;
  - slice header: `This is slice <i> of <n> of one change. The other slices are reviewed in
    their own turns. Open any file you need.`;
  - listed plan: `<path> was shown whole in the approved plan review <nonce>; only its changes
    since then are shown here.`;
  - missed: `The last round's reviewed_files did not list: <labels>. Review them too.`
- CLI: `xreview-packet.py build REQUEST.json OUTDIR` writes the packets into OUTDIR and prints
  the decision. `xreview-packet.py plan-blobs REPO BASE TIP` prints the JSON (for collect).

- [x] **Step 1: Write the failing tests:**
  - `C1`–`C6`: delta eligibility, one per §3.4 condition. Include a sliced root, a missing
    chain turn, a foreign compacted turn, `thread_compactions > 0`, and `thread_compactions`
    null, which forces a full packet.
  - `C7`: a multi-target request where one target is delta and one full; each target carries
    its own `packet` (Review Focus 1).
  - `P1`: a bound plan shows only `blob_patch(blob→current)`.
  - `P2`: an unclean, legacy, modified-only or unchanged-in-range plan receipt leaves the whole
    plan shown.
  - `F1`: `fit` off with a cap overflow gives `refuse` with today's text.
  - `F2`: `fit` on and it fits gives `send`.
  - `F3`: thread too full gives `fresh`, rebuilt as full.
  - `F4`: too big for fresh gives `slices`, each ≤ limit.
  - `F5`: an unreadable thread context gives `fresh` (Review Focus 5).
  - `F6`: an unreadable window gives `refuse` naming the window.
  - `F7`: a 20,000-file change cuts the slice file lists.
  - `R1`: rollout fixtures under a fake `CODEX_HOME` give the context and window from the
    records Task 1 named.
- [x] **Step 2:** Run the suite. Expected: the new cases FAIL.
- [x] **Step 3:** Implement.
- [x] **Step 4:** Run the suite. Expected: all pass.

### Task 6: xreview dispatch — use the packet module

**Files:**
- Modify: `dot_local/bin/executable_xreview` (`cmd_dispatch`, `add_target`, new
  `move_pane_to`).
- Test: `tests/xreview.test.sh` (stub `xreview-rpc thread-turns` and `thread-start` for new
  threads).

**Depends on:** Task 5.

**Interfaces:**
- Consumes `xreview-packet.py build`, through `/usr/bin/python3` at
  `${XREVIEW_PACKET:-$HOME/.claude/xreview-packet.py}`, like `ledger()`.
- Produces `move_pane_to <pane> <thread> <proc>`: today's `pane_free` + `pane_resume` +
  `archive_superseded` sequence, as one function that Task 8 reuses. Callers hold the pane
  lock.
- Produces state files:
  - `turns/<nonce>.shown`: the labels shown, one per line, per packet.
  - `turns/<nonce>.slices`:
    `{"packets":[{"file","shown"}],"next":1,"threads":[…],"turns":[…]}`.
  - `turns/<nonce>.targets`, now with each target's packet fields and the receipt-level
    `switches`.

- [x] **Step 1: Write the failing tests:**
  - `B` block, with all switches off: today's assertions unchanged, including the cap refusal.
  - `N1`: `fit` and `framing` on, a big diff sends with no cap refusal.
  - `N2`: decision `fresh` starts a new thread, adds the old one to `superseded`, and resumes
    the pane onto the new one. No send-keys after `turn-start` (C1).
  - `N3`: decision `slices` starts slice 1 only and writes `.slices` with `next:1`.
  - `N4`: `.targets` carries `switches` and per-target `packet`.
  - `N5`: decision `refuse` dies before the pane is touched (the suite's `untouched`).
- [x] **Step 2:** `./tests/xreview.test.sh`. Expected: the new cases FAIL, and today's
  pass.
- [x] **Step 3: Implement.**
  - `add_target` still normalizes, but stops building DIFFS itself.
  - After the thread is chosen and before `pane_free`, call `thread-turns`, if there is a
    thread, then `build`, and act on the decision.
  - The cap check moves into the module, and the bash env read passes `cap`.
  - With `framing` on, `turn-start` gets `findings.framed.schema.json`, and the reviewer
    instructions get `reviewer-framing.md` appended (through the request).
  - `$(state_dir)/missed` (labels, written by Task 8) goes into the request's `missed`, and is
    removed after a successful turn-start.
  - A `fresh` move keeps the round counter: it is not a checkpoint reset.
- [x] **Step 4:** Run the suite. Expected: all pass.

### Task 7: Replay harness

**Files:**
- Create: `.scripts/xreview-replay.py` (mode 755, `#!/usr/bin/python3`).
- Test: `tests/xreview-replay.test.sh` (new).

**Depends on:** Tasks 2 and 5 (runs beside Task 6).

**Interfaces:**
- `xreview-replay.py cases`, then `run`, then `match`, then `report`, each with
  `--state DIR` (default `~/.local/state/xreview/replay/<date>`) and `--dry-run`.
- **`cases`** writes `cases.json` and `judge-known/<case>.json`. Each judge input is
  `{case, findings:[…], interdiff}`. It reads `judge-known/<case>.answer.json`:
  `{verdicts:[{index, answer:"yes"|"no"|"unclear"}]}`. Per spec §5.1:
  - it selects up to 10 cases per switch, and for `fit` all slicing cases plus up to 5
    fresh-thread cases;
  - it reads historical receipts' cleanliness from their rollouts;
  - it computes their `plan_blobs` with the ledger's `plan_blobs`.
- **`run`** writes `runs/<case>/<label>.json`, where labels are random 8 hex characters and
  `arms.json` holds the map. Each run file is the findings plus `{tokens, compacted, slices}`.
  It stops at a 60,000,000-token tally (from rollouts), in the spec's switch order, and records
  `stopped_at`.
- **`match`** writes `judge-match/<case>.json`: `{known:[…], runs:{label:[findings]}}`. It
  reads `judge-match/<case>.answer.json`:
  `{matches:[{known_index, label, finding_index|null}]}`.
- **`report`** prints the per-switch table:
  - n, recall A/A′/F/B;
  - P0/P1 misses;
  - coverage-failure share;
  - tokens and compactions per arm;
  - pass or fail per §5.5.

  It writes `report.md`.

- [x] **Step 1: Write the failing tests** on one fixture case: a fixture git repo, a fake
  ledger, a fake rollout and a fake `xreview-rpc` on PATH.
  - `RP1`: `cases --dry-run` selects the fixture and writes a judge input with the interdiff.
  - `RP2`: `run --dry-run` builds every arm's packet with the module (A and A′ byte-identical
    to `today_packet`, B with that switch) and starts no turn.
  - `RP3`: judge inputs never contain an arm name or `arms.json` content.
  - `RP4`: `report`, on canned answers, computes recall and the pass bar for one pass and one
    fail.
  - `RP5`: a run interrupted mid-way archives every thread it recorded.
  - `RP6`: a run truncated by the token stop, where the cases that finished meet the recall bar,
    still reports that switch `incomplete` and not passed. `report` marks a switch passed
    only when every selected case ran every arm.
- [x] **Step 2:** `./tests/xreview-replay.test.sh`. Expected: FAIL.
- [x] **Step 3:** Implement. Concurrency ≤ 3. Each turn gets a scratch `git clone --shared` at
  the tip of the round it reviews, set per turn with `--cwd`. Use the history method Task 1
  verified, else the §5.3 fallback.
- [x] **Step 4:** Run the suite. Expected: all pass.

### Task 8: xreview collect — clean turns, receipts, slices

**Files:**
- Modify: `dot_local/bin/executable_xreview` (`cmd_collect`, `record_receipts`).
- Test: `tests/xreview.test.sh`.

**Depends on:** Task 6.

**Interfaces:**
- Consumes `move_pane_to`, `.slices`, `.shown`, `.targets` (Task 6) and `turn-wait --report`
  (Task 2).
- Produces receipts:
  - receipt level: `switches`, `compacted`, `clean`;
  - per target: `packet`, `missing` (≤ 50), `delta_from`, `history`, `plans_from`;
  - on plan-checkpoint receipts, per target, `plan_blobs` from `xreview-packet.py
    plan-blobs`.

- [x] **Step 1: Write the failing tests:**
  - `CL1`: a compacted turn with `fit` on prints the answer, exits 0, and prints
    `xreview: this review is not clean (compacted); the merge gate stays closed for it`.
  - `CL2`: a coverage gap with `framing` on prints the same with `(missed: <labels>)`, and
    the next dispatch's request carries `missed`.
  - `CL3`: with everything off, the receipt has `clean` and `compacted` recorded and no
    notice.
  - `CL4`: a report with `compacted: null` records the receipt as not clean. Unknown is never
    clean.
  - `SL1`: three slices. Collect runs slice 2 and 3 on fresh threads, moves the pane under its
    lock each time with no send-keys while a turn runs, and prints one merged answer
    (`approve` only if all did).
  - `SL2`: exit 3 during slice 2, then collect again resumes slice 2 and starts nothing twice.
  - `SL3`: the pane lock held by another dispatch makes collect wait, then proceed (Review
    Focus 4).
  - `SL4`: an unanswered slice turn-start is recovered as dispatch's exit 6.
  - `PB`: a plan-checkpoint receipt carries `plan_blobs`.
- [x] **Step 2:** Run the suite. Expected: the new cases FAIL.
- [x] **Step 3:** Implement.
  - Merge slice answers with jq.
  - Compute `missing` against `.shown`, with the module's label normalization (`a/`, `b/`,
    `./` stripped).
  - `turn-wait` validates against the schema the `.targets` switches name (framed when
    `framing` was on).
  - A coverage gap writes the missing labels to `$(state_dir)/missed` for the next dispatch.
- [x] **Step 4:** Run the suite. Expected: all pass.

### Task 9: Skill and instructions

**Files:**
- Modify: `dot_claude/skills/cross-review/SKILL.md` (spec §4).
- Test: `tests/xreview-skill.test.sh`.

**Depends on:** Task 6 (runs beside Task 8).

- [x] **Step 1: Write the failing pins** in `tests/xreview-skill.test.sh`:
  - no `XREVIEW_MAX_DIFF_BYTES` and no "slice by hand";
  - "dispatch never refuses on size";
  - the mechanical fresh-thread move, while "never rotate a thread by judgement" is kept;
  - "not clean";
  - plan reviews with `--diff` once the plan is committed;
  - the escalation list unchanged (the existing pin).
- [x] **Step 2:** `./tests/xreview-skill.test.sh`. Expected: FAIL.
- [x] **Step 3:** Edit the skill text per spec §4.
- [x] **Step 4:** Run `./tests/xreview-skill.test.sh` only. Expected: all pass. The full
  suite runs once the batch is done, by the controller, after Tasks 8 and 9 are both
  committed.

### Task 10: Replay, results, switches (controller)

**Depends on:** Tasks 1–9.

- [x] `./tests/run.sh` green, as passed/total.
- [x] `cases`, then judge the known-real inputs. Dispatch one `sp-standard` subagent per case
  file. Its prompt holds only the judge input and the answer schema, nothing about the design.
- [x] `run` in the background, sandbox disabled. It takes 3–4 h, with one status line per
  switch's cases finished.
- [x] `match`, then judge it the same way, then `report`.
- [x] Write spec §9: the report table, `stopped_at` if any, and the switch states that follow.
  Commit: "Record the replay results".
- [x] For each switch that passed, in order (`framing` first): set it `on` in
  `dot_config/xreview/packets.conf`, and commit "Turn on <switch>: <one-line result>".
- [x] Update memory `excluded-command-must-lead` if `fit` is on.
- [x] Set spec and plan `**Status:** Implemented` in the pre-merge commit. Run the pre-merge
  cross-review (`xreview round --reset`, then `--checkpoint pre-merge --diff main...<branch>`),
  then push the branch.

## Batches

| Batch | Tasks | Notes |
|---|---|---|
| 1 | 1 | controller, live daemon |
| 2 | 2, 3, 4 | disjoint files; no shared test resource |
| 3 | 5 | |
| 4 | 6, 7 | `executable_xreview` vs `.scripts/` |
| 5 | 8, 9 | `executable_xreview` vs the skill |
| 6 | 10 | controller |

After each batch's tasks are committed, the controller runs `./tests/run.sh` once. No
implementer runs the full suite.
