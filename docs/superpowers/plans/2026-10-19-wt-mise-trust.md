# wt mise trust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress

**Goal:** `wt` carries the main checkout's mise trust into a new worktree for byte-identical configs, refuses everything else with a reviewable message, warns on an untrusted reopen, and keeps the Herdr popup open when there is something to read.

**Architecture:** Three new zsh helpers in `dot_config/zsh/functions` beside the `wt` family: a reader of `mise trust --show` scoped to one checkout, the carry step called from `_wt_do_prepare` before the setup hook, and a reopen warning called from `_wt_create_or_prepare`'s reopen branch. `wt-prompt` waits for Enter on failure or on the warning. A `mise` stub on the test `PATH` keeps a fake, content-hashed trust store.

**Tech Stack:** zsh (`emulate -L zsh`), git worktrees, mise 2026.10.15 (paranoid mode), bash test stubs.

**Spec:** `docs/superpowers/specs/2026-10-19-wt-mise-trust-design.md`

## Global Constraints

- Every new function starts with `emulate -L zsh`, like its neighbours; diagnostics go to stderr with `print -ru2 --`.
- mise is always invoked as `command mise`, and only when `(( $+commands[mise] ))`.
- `mise trust` is only ever called with exactly one file path; never bare, never with `--all`, never on a main-checkout path.
- Worktree membership is lexical: canonicalise the checkout root only (`${dir:A}`), map a leading `~/` in mise's output back to `$HOME/`, match on the prefix `<canonical root>/`. Never resolve an entry path.
- Read only mise's stdout; its stderr (e.g. "No trusted config files found", warnings) is never parsed.
- Paths shown to Michael abbreviate a leading `$HOME/` to `~/`; paths passed to commands are absolute.
- Fixed copy (tests match it):
  - carried: `wt: mise trust carried to <path>`
  - refused: `wt: <path> is not trusted: <reason>.` then `    review: diff <main-path> <path>` (or `    review: cat <path>` when the main checkout has no such file), then `    then:   mise trust <path>`
  - reasons: `it differs from the main checkout's` · `the main checkout has no such file` · `the main checkout's is not trusted` · `it or its main-checkout counterpart is a symlink or not a regular file` · `it changed while wt was trusting it`
  - read failure: `wt: cannot read mise's trust status for <dir> — trusting nothing.`
  - trust or untrust failure: `wt: mise trust failed for <path> — trusting nothing more.`
  - `_wt_do_prepare` recovery: `    The worktree exists — review the mise config above, then: wt-prepare <qb> && wt <qb>`
  - reopen warning: `wt: <dest> has untrusted mise config (<rel>[, <rel>…]) — run: wt-prepare <qb>`
  - reopen read failure: `wt: cannot read mise's trust status for <dest> — opening anyway.`
  - popup: `Press Enter to close.`
- Suite: `./tests/wt-functions.test.sh` (zsh; execute it, never prefix an interpreter).

## Review Focus

1. A checkout path containing `: ` (e.g. `~/Code/Org/co: lon`): split each `--show` line on its trailing `: trusted` / `: untrusted`, never on the first colon. Test X14.
2. mise printing nothing on stdout and only noise on stderr: "nothing to carry", not "unreadable". Test X15.
3. A partial carry followed by `wt-prepare`: files already carried are skipped (no second `mise trust`), the rest are handled. Test X16.
4. A config below a subdirectory (`.config/mise.toml`) with no main-checkout counterpart: refused with `cat`, `<rel>` keeps its `/`. Test X4.
5. A symlinked directory on the way to a config (`.config -> outside`): refused as a symlink, never skipped as outside. Test X5b.

---

### Task 1: The mise stub and the `--show` reader

**Depends on:** none

**Files:**
- Modify: `tests/wt-functions.test.sh` (stubs block ~56-178, `setup()` ~257-282, header comment's section list, new section X helpers)
- Modify: `dot_config/zsh/functions` (new helper above `_wt_do_prepare`, ~line 517)

**Interfaces:**
- Produces: `_wt_mise_show <dir>` — runs `command mise -C <dir> trust --show`; prints one line per entry inside `<dir>` as `trusted<TAB><rel>` or `untrusted<TAB><rel>` (rel relative to `${dir:A}`, may contain `/`); returns 0, or 1 when mise exits non-zero or a stdout line is neither `<path>: trusted` nor `<path>: untrusted`. Entries outside `<dir>` (parents, global) are dropped silently.
- Produces (tests): the `mise` stub protocol below, `MISESTUBS`, `MLOG`, `MISE_STUB_STORE`, `nomise_path`, and `mise_seed <file>` (records the file's current content as trusted).

- [ ] **Step 1: Add the `mise` stub in its own directory, `$MISESTUBS`** (created and cleaned up like `$STUBS`, prepended to `PATH` ahead of it, so a test can drop it alone), plus `nomise_path`, which prints the current `PATH` without `$MISESTUBS` and without every directory holding an executable `mise` (here `/opt/homebrew/bin`; git then resolves to `/usr/bin/git`). The stub is bash and logs `"$*"` to `$MLOG`:
  - `-C <dir> trust --show`: unless overridden, walks `$(cd -P <dir> && pwd -P)` up to `/`; for each of `mise.toml mise.local.toml .mise.toml .config/mise.toml` that exists (`-e` or `-L`), prints `<path>: trusted|untrusted` with `$HOME/` printed as `~/`. Trusted iff `$MISE_STUB_STORE` has the line `<path><TAB><sha256 of the file's current content>`. No entries: `mise No trusted config files found.` on stderr. `MOCK_MISE_SHOW_RC` (non-zero: exit with it, print nothing), `MOCK_MISE_SHOW_RAW` (print it with `%b` instead), `MOCK_MISE_SHOW_STDERR` (also print it on stderr), `MOCK_MISE_SHOW_FAIL_AFTER_TRUST` (exit 1, print nothing, once `$MLOG` holds a `trust /…` line, i.e. only the reads after a trust fail).
  - `trust <file>`: if `MOCK_MISE_RACE_CONTENT` is set, writes it (`%b`) to `<file>` first; if `MOCK_MISE_MAIN_FLIP` names a path, drops that path's store line; then records `<file><TAB><sha>`. `MOCK_MISE_TRUST_RC` non-zero: records nothing, exits with it. `MOCK_MISE_TRUST_NOOP` set: records nothing, exits 0 (a trust that silently did not hold).
  - `trust --untrust <file>`: drops `<file>`'s line. `MOCK_MISE_UNTRUST_RC` as above.
  - `trust` with no path, any `--all`, or anything else: `mise stub: unexpected invocation: …` on stderr, exit 3.
  - `setup()` exports fresh `MLOG` and `MISE_STUB_STORE` (empty files under `$ROOTTMP`) and unsets every `MOCK_MISE_*`.

- [ ] **Step 2: Write the failing tests** (section `X. wt — mise trust carried into a new worktree`, reader cases first):
  - `X0a`: repo with `mise.toml` seeded and `mise.local.toml` unseeded → `_wt_mise_show "$REPO"` prints exactly `trusted\tmise.toml` and `untrusted\tmise.local.toml` (order-insensitive), rc 0.
  - `X0b`: `$HOME/Code/Org/mise.toml` (a parent) exists → not in the output.
  - `X0c`: `MOCK_MISE_SHOW_RC=1` → rc 1. `MOCK_MISE_SHOW_RAW='garbage\n'` → rc 1.
  - `X0d`: `.config/mise.toml` → printed with rel `.config/mise.toml`.

- [ ] **Step 3: Run** `./tests/wt-functions.test.sh 2>&1 | grep -E 'X0|passed:'` — expected: the X0 cases FAIL (`_wt_mise_show` not found); every pre-existing case still passes (the stub prints nothing for repos without configs).

- [ ] **Step 4: Implement `_wt_mise_show <dir>`** in `dot_config/zsh/functions` per the Interfaces block and Global Constraints (suffix-anchored parse, `~/` mapping, lexical `<canonical dir>/` prefix).

- [ ] **Step 5: Run** `./tests/wt-functions.test.sh` — expected: all pass, `passed: N  failed: 0`.

- [ ] **Step 6: Commit** (controller): `git add tests/wt-functions.test.sh dot_config/zsh/functions` — "Read mise's trust status for one checkout in the wt functions".

### Task 2: Carry trust in `_wt_do_prepare`

**Depends on:** Task 1

**Files:**
- Modify: `dot_config/zsh/functions` (`_wt_do_prepare` ~521-556, new helper beside `_wt_mise_show`)
- Modify: `tests/wt-functions.test.sh` (section X)

**Interfaces:**
- Consumes: `_wt_mise_show <dir>`; the stub, `mise_seed`, `MLOG`.
- Produces: `_wt_mise_trust <main> <dest>` — returns 0 when there was nothing to carry or everything was carried, 1 when any file stays untrusted or a read or trust failed (after printing every refused file). Called in `_wt_do_prepare` after the `.worktreeinclude` copy loop and before `_wt_hook_run … setup`; on 1, `_wt_do_prepare` prints its recovery line and returns 1.

- [ ] **Step 1: Write the failing tests.** Each uses `mkhook` with a hook that touches `$ROOTTMP/hook-ran`, a tracked `mise.toml` and a `.worktreeinclude` listing `mise.local.toml`; "seeded" means `mise_seed` on the main-checkout file.
  - `X1` identical, both seeded → `wt x1`: rc 0; `MLOG` has `trust <dest>/mise.toml` and `trust <dest>/mise.local.toml`; output has `wt: mise trust carried to ~/Code/Org/repo-x1/mise.toml`; hook ran; `DLOG` has `--worktree $REPO <dest>`.
  - `X2` branch commits a different `mise.toml` → rc 1; no `trust <dest>/mise.toml` in `MLOG`; output has `is not trusted: it differs from the main checkout's.`, `review: diff ~/Code/Org/repo/mise.toml ~/Code/Org/repo-x2/mise.toml`, `then:   mise trust ~/Code/Org/repo-x2/mise.toml`, `wt-prepare x2 && wt x2`; hook did not run; no `--worktree` for it in `DLOG`.
  - `X3` main `mise.local.toml` not seeded → rc 1, reason `the main checkout's is not trusted`.
  - `X4` branch adds `.config/mise.toml` → rc 1, reason `the main checkout has no such file`, `review: cat ~/Code/Org/repo-x4/.config/mise.toml`.
  - `X5a` branch commits `mise.toml` as a symlink to `$ROOTTMP/outside.toml` → rc 1, the symlink reason naming `…/repo-x5a/mise.toml`. `X5b` worktree `.config` is a symlink to `$ROOTTMP/ext` holding `mise.toml` → refused the same way.
  - `X5c` main side, leaf: the commit has a regular `mise.toml`; in the main checkout's working tree it is then replaced by a symlink to an outside file with identical content, seeded → the worktree's regular copy is refused with the symlink reason, and `MLOG` has no `trust <dest>/mise.toml`. `X5d` main side, directory: the commit has `.config/mise.toml`; the main checkout's `.config` is then replaced by a symlink to an outside directory holding an identical, seeded `mise.toml` → refused the same way.
  - `X6` no `mise` on `PATH` (`PATH="$(nomise_path)"`) → rc 0, hook ran, `MLOG` empty.
  - `X7` `MOCK_MISE_SHOW_RC=1` → rc 1, `cannot read mise's trust status`, no `trust <` line without `--show` in `MLOG`. Same with `MOCK_MISE_SHOW_RAW`.
  - `X8` `MOCK_MISE_RACE_CONTENT='[env]\nX = "evil"\n'` → `MLOG` has `trust --untrust <dest>/mise.toml`, reason `it changed while wt was trusting it`, rc 1.
  - `X9` `MOCK_MISE_MAIN_FLIP="$REPO/mise.toml"` → untrust follows, rc 1.
  - `X10` an unseeded `$HOME/Code/Org/mise.toml` (parent) → rc 0, no message mentions it.
  - `X11` both files identical and seeded, `MOCK_MISE_TRUST_RC=1` → `mise trust failed for <dest>/mise.toml`, rc 1, hook did not run, and `MLOG` has exactly one `trust <dest>/` line: nothing more is tried after the failure.
  - `X11b` both files identical and seeded, `MOCK_MISE_RACE_CONTENT` and `MOCK_MISE_UNTRUST_RC=1` → `mise trust failed for <dest>/mise.toml` (the rollback failed), rc 1, hook did not run, no `trust <dest>/mise.local.toml` in `MLOG`.
  - `X12` recovery: after an X2-style refusal, `mise_seed <dest>/mise.toml`, then `wt-prepare x12` → rc 0, hook ran; `wt x12` then opens it.
  - `X13` over the whole section: no `MLOG` line is `trust`, ends in ` trust`, contains `--all`, or is `trust <path in the main checkout>` (with or without `--untrust`).
  - `X14` (Review Focus 1) repo dir `co: lon` → carried as in X1.
  - `X15` (Review Focus 2) no configs anywhere plus `MOCK_MISE_SHOW_STDERR='mise WARN noise'` → rc 0, hook ran, no read-failure message and no `mise trust carried` line.
  - `X16` (Review Focus 3) `mise.toml` identical, `mise.local.toml` main unseeded → rc 1, `mise.toml` carried; then seed only the main checkout's `mise.local.toml` and run `wt-prepare` → rc 0, hook ran; over both runs `MLOG` has exactly one `trust <dest>/mise.toml` and exactly one `trust <dest>/mise.local.toml` (the retry carries the remaining file itself).
  - `X17` both files identical and seeded, `MOCK_MISE_TRUST_NOOP=1` (files stay identical, main stays trusted, only the worktree's trust record is missing) → `trust --untrust <dest>/mise.toml` follows, rc 1, hook did not run.
  - `X18` two refusals: the branch changes `mise.toml` and adds `.config/mise.toml` → rc 1; the output names both paths, each with its own reason and review line.
  - `X19` both files identical and seeded, `MOCK_MISE_SHOW_FAIL_AFTER_TRUST=1` → `MLOG` has `trust <dest>/mise.toml`, then `trust --untrust <dest>/mise.toml`, and no `trust <dest>/mise.local.toml`; output has `cannot read mise's trust status`; rc 1; hook did not run.

- [ ] **Step 2: Run** `./tests/wt-functions.test.sh 2>&1 | grep -E 'X[0-9]|passed:'` — expected: X1-X18 FAIL (X6, X10 and X15 may already pass, since nothing is trusted yet); X0 and pre-existing pass.

- [ ] **Step 3: Implement `_wt_mise_trust <main> <dest>`** and wire it into `_wt_do_prepare`. Per untrusted entry: per-component symlink check below each root (as `_wt_manifest` does) and `-f` on both; main's status from one `_wt_mise_show <main>`; `cmp -s`; `command mise trust <abs dest path>`; then re-check `cmp -s`, `_wt_mise_show <dest>` and `_wt_mise_show <main>`, and `command mise trust --untrust <abs dest path>` on any failure. Collect ordinary refusals and print them all before returning 1. A failed `trust`, a failed `--untrust`, or a failed read stops at once with no further carrying: print it, return 1. The one call still made after a failure is the rollback: a read that fails in the re-check after a successful `trust` first runs `--untrust` on that file, then stops.

- [ ] **Step 4: Run** `./tests/wt-functions.test.sh` — expected: all pass.

- [ ] **Step 5: Commit** (controller) — "Carry the main checkout's mise trust into a new wt worktree".

### Task 3: Reopen warning and the popup

**Depends on:** Task 2

**Files:**
- Modify: `dot_config/zsh/functions` (`_wt_create_or_prepare` reopen branch ~613-616, `wt` ~648, `wt-prompt` ~656-666, new helper beside the others)
- Modify: `tests/wt-functions.test.sh` (new section `Y. wt — reopen warning and the popup`; one assertion added to the existing wt-prompt test ~2026)

**Interfaces:**
- Consumes: `_wt_mise_show <dir>`.
- Produces: `_wt_mise_reopen_warn <dest> <branch>` — prints the reopen warning (or the read-failure line) and sets `typeset -g _WT_NOTICE=1` when it printed anything; always returns 0; never calls `mise trust`. `wt` resets `_WT_NOTICE=` before `_wt_create_or_prepare`. `wt-prompt` prints `Press Enter to close.` and reads one line when `wt` returned non-zero or `_WT_NOTICE` is set, then returns `wt`'s status.

- [ ] **Step 1: Write the failing tests.**
  - `Y1` carry succeeds (as X1), then the dest `mise.local.toml` is edited; `: > $MLOG`; `wt y1` → rc 0; output has `has untrusted mise config (mise.local.toml) — run: wt-prepare y1`; `DLOG` has the reopen; `MLOG` has no line starting `trust ` (only `-C … trust --show`).
  - `Y2` reopen with everything trusted → no `untrusted mise config` in output.
  - `Y3` reopen with `PATH="$(nomise_path)"` → rc 0, no warning.
  - `Y4` reopen with `MOCK_MISE_SHOW_RC=1` → rc 0, `— opening anyway.`, `DLOG` has the reopen.
  - The waiting is proven by what `wt-prompt` reads, not by its text: each popup case pipes two lines, `<branch>` then `SENTINEL`, into `{ wt-prompt; s=$?; IFS= read -r rest; print -r -- "REST=$rest"; print -r -- "STATUS=$s" }`. A popup that waited consumed the sentinel (`REST=`); one that did not leaves it (`REST=SENTINEL`). `STATUS=` carries `wt-prompt`'s own exit status, since the group's is always 0.
  - `Y5` an `x2`-style failing branch → `STATUS=1`, output has `Press Enter to close.` and `REST=` with no `SENTINEL`.
  - `Y6` reopening Y1's worktree → `STATUS=0`, output has the warning, `Press Enter to close.` and `REST=` with no `SENTINEL`.
  - `Y7` a clean success → `STATUS=0`, no `Press Enter to close.`, and `REST=SENTINEL`.

- [ ] **Step 2: Run** `./tests/wt-functions.test.sh 2>&1 | grep -E 'Y[0-9]|popup|passed:'` — expected: Y1-Y6 FAIL (Y7 may already pass), the rest pass.

- [ ] **Step 3: Implement** `_wt_mise_reopen_warn` (called right after `print -ru2 -- "wt: reopening $dest"`), the `_WT_NOTICE` reset in `wt`, and the wait in `wt-prompt`.

- [ ] **Step 4: Run** `./tests/wt-functions.test.sh` then `./tests/run.sh` — expected: wt-functions all pass; the full run reports every suite OK (judge by exit status).

- [ ] **Step 5: Commit** (controller) — "Warn on an untrusted wt reopen, and keep the popup open when wt has something to say".
