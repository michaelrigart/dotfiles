# mise trust across a repository's checkouts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented on `feat/mise-trust-worktrees` (no MR; dotfiles end at the pushed
branch). Do not run it again. The spec's "Rulings and accepted residuals" records what changed
after this plan was approved:
- **The reopen helper** is `_wt_mise_reopen_carry <main> <dest> <branch>`, not
  `_wt_mise_reopen_warn <main> <dest>`.
- **A carrying reopen** prints a never-prepared `wt-prepare` line and holds the popup, so Y14's
  popup expectation is flipped.
- **The `wt-rm` gates** are `hook_rc != 2`, not "On 0".
- **Identity pinning** (inode and nanosecond change time) closes the check-then-trust window,
  and a symlinked `<dest>` is refused.
- **The candidate list** also returns 1 when the porcelain holds no `worktree ` record.
- **Added cases:**
  - X25b–d, X32's carry checks, X33–X36's trust and hook assertions;
  - XC4b, XC6, XR6b, XR6c, XR8, XR9;
  - Y15–Y17;
  - the flip-race case, the symlinked-`<dest>` case, and the `wt-rm` no-mise and invalid-hook
    cases;
  - the list-read-once case and the carried-count reset case.
- **Sweeps:** a Y18 sweep of section Y, with X13 and Y18 made allowlists.
- **The suite** gained a `jq` stub that skips a mise-shim `jq`, and the FUNCS target check exits 2.
- **The earlier task reviews' minor fixes,** folded into Task 3 as A1–A7.

**Goal:** Ruby's idiomatic version files stop being mise configs, and `wt`, `wt-prepare`, a reopen and `wt-rm` carry mise trust from any checkout of the repository that trusts byte-identical content.

**Architecture:** One global setting in `dot_config/mise/config.toml`. In `dot_config/zsh/functions`, a new candidate-list helper and a per-file "is this a plain regular file" helper feed a rewritten `_wt_mise_trust`; its report and withdraw helpers gain the base checkout; `_wt_create_or_prepare` threads the base branch through `_wt_do_prepare`; the reopen runs the carry; `wt-rm` runs it in step 1 and re-reads trust right before teardown. Tests extend sections X and Y of `tests/wt-functions.test.sh` with real sibling worktrees and the existing `mise` stub.

**Tech Stack:** zsh (`emulate -L zsh`), git worktrees, mise 2026.10.19 in paranoid mode (stubbed in tests), bash stubs.

**Spec:** `docs/superpowers/specs/2026-10-27-mise-trust-worktrees-design.md` (extends `docs/superpowers/specs/2026-10-19-wt-mise-trust-design.md`; "old §X" refers to that one).

## Global Constraints

- Every rule of the old spec holds unless the new spec replaces it: `command mise` only when `(( $+commands[mise] ))`, stdin from `/dev/null` on every mise call, only stdout parsed, lexical membership, `mise trust` only with exactly one destination path, never bare, never `--all`, never on any other checkout's path.
- Every new function starts with `emulate -L zsh`; diagnostics go to stderr with `print -ru2 --`; the carried line goes to stdout.
- Headlines show paths with `_wt_tilde` (unquoted); lines Michael pastes use `_wt_tilde_q` / `_wt_q`.
- A refusal record stays `<reason><TAB><rel>` with the path last, so a filename holding a tab is never cut.
- Fixed copy (tests match it; `<p>` is a tilde path):
  - carried: `wt: mise trust carried to <dest-path> (trusted in <checkout>)`
  - reasons: `it is a symlink or not a regular file` · `it matches no trusted copy in this repository's checkouts` · `it changed while wt was trusting it`
  - review: `    review: diff <baseline-path> <dest-path>` or `    review: cat <dest-path>`; then `    then:   mise trust <dest-path>` (unchanged)
  - candidate read failure: `wt: cannot read mise's trust status for <checkout> — it cannot vouch.`
  - list read failure: `wt: cannot read Git's worktree list for <main> — trusting nothing.`
  - reopen: `wt: opening <dest> anyway — its shells load no project mise config until the files above are trusted.`
  - wt-rm step 1: `wt-rm: nothing was closed or removed — review the mise config above, then: wt-rm <qb>`
  - wt-rm before teardown: `wt-rm: <dest> has untrusted mise config (<rel>[, <rel>…]) — teardown not run, Herdr workspaces closed.` or `wt-rm: cannot read mise's trust status for <dest> — teardown not run, Herdr workspaces closed.`, then `    Review the mise config, then retry: wt-rm <qb>`
  - Unchanged: the `<dest>` read failure (`… — trusting nothing.`), `mise trust failed …`, the withdraw line, the `changed while wt was trusting it — trusting nothing more.` stop line, and `_wt_do_prepare`'s recovery line.
- Run the suite as `./tests/wt-functions.test.sh` (zsh shebang; never prefix an interpreter). Its last line is `passed: N  failed: M`. Full run: `./tests/run.sh`, reported as passed/total.
- Never run `chezmoi apply`, `wt`, `wt-rm` or `wt-prepare` outside the suite, and never touch the real mise trust store.
- Every task touches `tests/wt-functions.test.sh` (and all but Task 1 `dot_config/zsh/functions`), so tasks run one at a time, in order.

## Review Focus

- A Claude Code harness worktree nested inside the main checkout (`<main>/.claude/worktrees/<name>`) as a candidate: `mise -C` lists main's configs as its parents, and they must not answer for it. Test X33 (Task 3).
- Two untrusted files in one run: each candidate's `trust --show` is read once for the search, however many files consult it. Test X34 (Task 3).
- A sibling checkout whose path holds `: `: its tilde path in the carried line, and the quoted `diff` baseline. Test X35 (Task 3).
- A detached-HEAD sibling (no `branch` record) is still a candidate; a start point that is no local branch leaves the base empty. Test XC5 (Task 2).
- `wt` run from inside a sibling with no start point: the caller's checkout is the base checkout and vouches first. Test X36 (Task 3).

---

### Task 1: Ruby's idiomatic version files off

**Depends on:** none

**Files:**
- Modify: `dot_config/mise/config.toml:19-20` (`[settings]`)
- Test: `tests/wt-functions.test.sh` (top-of-file target check; new case in section X after X0s)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other tasks call.

- [ ] **Step 1: Write the failing test**

Near the top, beside the `FUNCS` check, add `MISECONF="$(cd "${0:h}/.." && pwd)/dot_config/mise/config.toml"` and `[[ -r "$MISECONF" ]] || { print -ru2 -- "cannot read $MISECONF"; exit 2 }`. In section X, after the X0s block:

```zsh
# X22: the global mise config keeps Ruby's idiomatic files (Gemfile, .ruby-version) out of mise,
# so they never become configs paranoid mode hashes. The [settings] table is read up to the next header.
settings="$(awk '/^\[/{ s = ($0 == "[settings]") ; next } s' "$MISECONF")"
eq "$(print -r -- "$settings" | grep -c '^idiomatic_version_file_enable_tools = \[\]$')" "1" \
   "X22 [settings] sets idiomatic_version_file_enable_tools = [] exactly once"
eq "$(print -r -- "$settings" | grep -c '^idiomatic_version_file_enable_tools')" "1" \
   "X22 ... and no other value for it"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/wt-functions.test.sh 2>&1 | grep -E 'X22|^passed'`
Expected: `FAIL: X22 [settings] sets idiomatic_version_file_enable_tools = [] exactly once`.

- [ ] **Step 3: Change the setting**

Replace `idiomatic_version_file_enable_tools = ["ruby"]` with `idiomatic_version_file_enable_tools = []`, above it a comment of at most four lines: through mise a Gemfile only selects a Ruby version, and bundler executes the whole Gemfile on every `bin/rails` anyway, so dropping it from mise's trust costs nothing paranoid mode protects; pin Ruby in `mise.toml` or `.tool-versions`; set explicitly so a changed mise default cannot bring it back; spec 2026-10-27 mise trust worktrees.

- [ ] **Step 4: Run the suite**

Run: `./tests/wt-functions.test.sh 2>&1 | tail -1`
Expected: `passed: N  failed: 0`.

- [ ] **Step 5: Commit** — `Keep Ruby's idiomatic version files out of mise's trust`

---

### Task 2: The candidate list

**Depends on:** Task 1

**Files:**
- Modify: `dot_config/zsh/functions` (new helper after `_wt_mise_show`)
- Test: `tests/wt-functions.test.sh` (section X, after X22)

**Interfaces:**
- Consumes: `_wt_git`.
- Produces: `_wt_mise_candidates <main> <dest> [<base-branch>]`. Returns 0 and sets two globals: `_WT_MISE_CANDS`, an array of checkout roots, and `_WT_MISE_BASEDIR`, the base checkout's root or empty. Returns 1 with the list-read-failure line when `_wt_git -C <main> worktree list --porcelain -z` fails or yields no records.
  - Order: `<main>` exactly as passed; then the root whose record reads `branch refs/heads/<base-branch>`; then the others in Git's order. Each root once.
  - Left out: the record whose `${path:A}` equals `${dest:A}`; any whose path is not a directory (`[[ -d ]]`); any non-main root for which `_wt_git -C <root> rev-parse --path-format=absolute --git-common-dir` fails or does not equal `<main>`'s (compared `:A`).
  - Paths other than `<main>` are as Git prints them.

- [ ] **Step 1: Write the failing tests**

Two helpers, defined in the test file (`run` sees them, as X14f's `xw_caller` shows), used by every later task:

```zsh
xc_list() { _wt_mise_candidates "$@" || return; print -rl -- $_WT_MISE_CANDS "base=$_WT_MISE_BASEDIR" }
# xsib <git worktree add args…> — a registered sibling checkout, arguments exactly as git takes them.
xsib() { git -C "$REPO" worktree add -q "$@" >/dev/null 2>&1 || _fail "xsib $*" }
```

Siblings live at `$HOME/Code/Org/sib-*`, e.g. `xsib -b a "$HOME/Code/Org/sib-a"`.

- XC1 order: siblings `sib-a` (`-b a`, created first), `sib-b` (`-b b`), destination `repo-d` (`-b d`). `run "$REPO" xc_list "$REPO" "$HOME/Code/Org/repo-d" b` prints exactly `$REPO`, `…/sib-b`, `…/sib-a`, `base=…/sib-b` (one per line); the destination is absent.
- XC2 missing directory: `rm -rf sib-a` (registration stays): it is absent; rc 0.
- XC3 another repository: `git init -q "$HOME/Code/Org/other"`, then replace `sib-a` with `ln -s "$HOME/Code/Org/other" "$HOME/Code/Org/sib-a"`: it is absent.
- XC4 failed list read: with the git failure injector, `PATH="$FAILSTUBS:$PATH" WT_FAIL_MATCH='worktree list' WT_FAIL_NTH=1 WT_FAIL_LOG="$FLOG" run "$REPO" xc_list "$REPO" "$HOME/Code/Org/repo-d"`: rc 1, output has `wt: cannot read Git's worktree list for ~/Code/Org/repo — trusting nothing.`
- XC5 (Review Focus): a detached sibling (`worktree add --detach`) is listed; a base of `origin/main` or of `main` itself yields no duplicate and, for `origin/main`, `base=` empty; no base argument gives main first, then the rest.

- [ ] **Step 2: Run them to verify they fail**

Run: `./tests/wt-functions.test.sh 2>&1 | grep -E 'XC[0-9]|^passed'`
Expected: every XC assertion FAILs (`command not found: _wt_mise_candidates` in the captured output).

- [ ] **Step 3: Implement `_wt_mise_candidates`**

Parse the NUL porcelain as `_wt_git_lock_state` and `_wt_worktree_record` do (one `${(0)…}` assignment that also yields the status; a `worktree ` token starts a record, `branch refs/heads/` names its branch). Read `<main>`'s common dir once. A header comment cites spec §2.

- [ ] **Step 4: Run the suite** — Expected: `passed: N  failed: 0`.

- [ ] **Step 5: Commit** — `List the checkouts that can vouch for a worktree's mise config`

---

### Task 3: Carry from any checkout, with the new report

**Depends on:** Task 2

**Files:**
- Modify: `dot_config/zsh/functions`: `_wt_mise_trust_report`, `_wt_mise_withdraw`, `_wt_mise_trust`, `_wt_do_prepare`, `_wt_create_or_prepare`, and a new `_wt_mise_plain`. Update their header comments.
- Test: `tests/wt-functions.test.sh`: the mise stub, `setup()`'s unset list, section X (new cases X23 to X36, edits to existing ones), the section list at the top, and Y5's reason.

**Interfaces:**
- Consumes: `_wt_mise_candidates`, `_WT_MISE_CANDS`, `_WT_MISE_BASEDIR`, `_wt_mise_show`.
- Produces:
  - `_wt_mise_plain <root> <rel>`: 0 when no component of `<root>/<rel>` below `<root>` is a symlink and `<root>/<rel>` is a regular file.
  - `_wt_mise_trust <main> <dest> [<base-branch>]`: 0 when nothing was left to carry or all was carried; 1 otherwise. Same contract as before.
  - `_WT_MISE_SHOWN`: a global associative array, reset at the start of every `_wt_mise_trust`. Key: a candidate root. Value: its `_wt_mise_show` result, or a marker for a failed read. The search reads go through it; the re-check never does.
  - `_wt_mise_trust_report <main> <dest> <basedir> <reason<TAB>rel>...`. A `matches no trusted copy` record gets `diff` against `<basedir>/<rel>`, else `<main>/<rel>`. A copy qualifies when it passes `_wt_mise_plain`, `_WT_MISE_SHOWN` says it is `trusted`, and `cmp -s` finds it different. Every other record gets `cat`. The report never calls mise.
  - `_wt_mise_withdraw <main> <dest> <basedir> <rel> <stop-message> <reason<TAB>rel>...`.
  - `_wt_do_prepare <main> <dest> <branch> <slug> [<base-branch>]`.

- [ ] **Step 1: Extend the stub and fixtures**

- Stub: `MOCK_MISE_SHOW_FAIL_DIR=<dir>` fails `-C <dir> trust --show` (exact match on the argument) with exit 1, from the start. Document it in the stub's header comment, and add it to `setup()`'s unset list.
- Siblings come from Task 2's `xsib`, at `$HOME/Code/Org/sib-*` so X13 can tell them apart.
- Fixtures in which main cannot vouch for `mise.local.toml` give the sibling an identical, seeded copy, or remove `$REPO/.worktreeinclude` and `$REPO/mise.local.toml` before `wt`.

- [ ] **Step 2: Write the failing tests**

Update existing cases to the new copy:
- X2, X18, X20: reason `it matches no trusted copy in this repository's checkouts`; the `review: diff` lines stay against main's copy.
- X3, X4, X14b, X21, X18's second file: the new reason; the `review: cat` lines stay.
- X5a, X5b: reason `it is a symlink or not a regular file` (set `XSYM` to it).
- X5c, X5d: main is the symlinked side, so main cannot vouch: the new reason, `review: cat`.
- Y5: the new reason.
- X14f: `_wt_mise_withdraw "$REPO" "$X" "" mise.toml ""`.
- X13: also flag `trust …` and `trust --untrust …` lines aimed under `*/Code/Org/sib-*`.

New cases. Each asserts rc, which file was or was not trusted (`mlog_line` / `mlog_no_line`), the lines, and that the hook ran or did not:
- X23 sibling vouches when main differs. `xbranch x23-src` with `a=2`; `xseed`; `xsib "$HOME/Code/Org/sib-x23" x23-src`; seed its `mise.toml`; `wt x23 x23-src`. Expect rc 0 and `wt: mise trust carried to ~/Code/Org/repo-x23/mise.toml (trusted in ~/Code/Org/sib-x23)`.
- X24 main's copy untrusted, a sibling's identical copy trusted. Seed only main's `mise.local.toml`; `xsib -b s24 "$HOME/Code/Org/sib-x24"`; seed the sibling's `mise.toml`; `wt x24`. Expect carried, `(trusted in ~/Code/Org/sib-x24)`.
- X25 only untrusted or differing copies. The base sibling's copy (`a=2`) is unseeded; another sibling holds `a=1`, seeded; main `a=1` is trusted. Expect rc 1, the new reason, and `review: diff ~/Code/Org/repo/mise.toml ~/Code/Org/repo-x25/mise.toml`.
- X26 re-check bound to the vouching candidate. As X23 with sibling `sib-x26`, plus a second identical trusted sibling `sib-x26b` created after it (`xsib -b s26b "$HOME/Code/Org/sib-x26b" x26-src`); `MOCK_MISE_MAIN_FLIP="$HOME/Code/Org/sib-x26/mise.toml"`. Expect `trust --untrust $X/mise.toml`, reason `it changed while wt was trusting it`, `mlog_count "trust $X/mise.toml"` = 1 (the second sibling is not tried), and the hook not run.
- X27a a registered sibling whose directory is gone, ahead of one that vouches: carried, and no `-C <gone> trust --show` in MLOG.
- X27b `MOCK_MISE_SHOW_FAIL_DIR="$REPO"`, a sibling vouches for both files: rc 0, `wt: cannot read mise's trust status for ~/Code/Org/repo — it cannot vouch.` exactly once, and `-C $REPO trust --show` logged exactly once.
- X28 a registered sibling replaced by a symlink to another repository's checkout. That checkout holds an identical, seeded `mise.toml`, and main differs: refused, never trusted.
- X29 base first. `sib-a` is created first, on another branch, with an identical trusted copy; the base sibling is `sib-z` on the start-point branch, identical and trusted. `wt x29 <base>`: `(trusted in ~/Code/Org/sib-z)`, and no `-C …/sib-a trust --show` line. If Git lists `sib-z` before `sib-a`, swap the names so the test fails when base ordering is removed.
- X30 review against the base checkout. The base sibling's `mise.toml` is edited to `a=3` and seeded, so it is trusted and differs; main `a=1` is trusted and differs: `review: diff ~/Code/Org/sib-x30/mise.toml ~/Code/Org/repo-x30/mise.toml`. Then `wt-prepare x30` (no base): the diff is against `~/Code/Org/repo/mise.toml`.
- X31 failed list read during the carry. On an existing worktree with an untrusted config, `PATH="$FAILSTUBS:$PATH" WT_FAIL_MATCH='worktree list' WT_FAIL_NTH=1 … run "$REPO" _wt_mise_trust "$REPO" "$X"`: rc 1, the list-failure line, no `trust ` line.
- X32 the destination's own side. After a refused `wt x32`, replace `$X/mise.local.toml` with a directory (never a FIFO, which would block the stub's `shasum`). A sibling holds a trusted regular copy. `wt-prepare x32`: reason `it is a symlink or not a regular file`, `review: cat`, no `trust` line.
- X33 (Review Focus) a nested harness checkout. `xsib -b h1 "$REPO/.claude/worktrees/h1" x33-src` holds the destination's content (`a=2`); main's `a=1` is trusted and differs.
  - With h1's copy unseeded: refused, never trusted. h1's own `trust --show` also lists main's trusted `mise.toml` as a parent, and it must not answer for h1.
  - After `mise_seed` of h1's copy, `wt-prepare x33` carries `(trusted in ~/Code/Org/repo/.claude/worktrees/h1)`.
- X34 (Review Focus) the search reads a candidate once.
  - Fixture: the destination's `mise.toml` (listed first) is refused, with main's and the sibling's copies trusted but differing. Its `mise.local.toml` is identical to the sibling's trusted copy, and main's copy is untrusted.
  - Expect: exactly one `-C <sibling> trust --show` line before the first `trust $X/` line in MLOG (`mlog_ln` for the cut-off); `mise.local.toml` carried; `mise.toml` refused.
- X35 (Review Focus) a sibling at `$HOME/Code/Org/sib: x35`.
  - The carried line shows `(trusted in ~/Code/Org/sib: x35)`.
  - In a second fixture set up like X30, the refusal quotes the baseline: `review: diff ~/'Code/Org/sib: x35/mise.toml' …`.
- X36 (Review Focus) the caller's checkout is the base.
  - Fixture: a sibling `sib-a`, created first on another branch, with an identical trusted copy; the caller sibling `sib-c` on branch `c36`, committed `a=2`, seeded; main differs.
  - `run "$HOME/Code/Org/sib-c" wt x36`, with no start point: carried `(trusted in ~/Code/Org/sib-c)`, and no `-C …/sib-a trust --show` line.

- [ ] **Step 3: Run them to verify they fail**

Run: `./tests/wt-functions.test.sh 2>&1 | grep -E 'FAIL|^passed'`
Expected: FAILs on X23–X36 and on the updated reason lines; no FAIL in sections other than X and Y5.

- [ ] **Step 4: Implement**

- `_wt_mise_trust`: per spec §3, as summarised under Interfaces.
  - Read `<dest>`. Read the candidates lazily, at the first `untrusted` entry.
  - Per entry: the destination side via `_wt_mise_plain`, then each candidate (rules 1–3) until one vouches.
  - Re-check as old §Closing the check-then-trust window, with "main" replaced by the vouching candidate. Failure → `_wt_mise_withdraw`, reason `it changed while wt was trusting it`, as now.
  - A failed candidate read prints its line once and marks the candidate out.
- `_wt_create_or_prepare`: keep the base branch in a function-level `local base=""`. A new branch gets `$start` when given, else the caller's `symbolic-ref --short HEAD` when that succeeds; an existing branch and a detached caller pass none. Pass it to `_wt_do_prepare`, which passes it to `_wt_mise_trust`. The `branching … from …` message is unchanged.

- [ ] **Step 5: Run the suite** — Expected: `passed: N  failed: 0`.

- [ ] **Step 6: Commit** — `Carry mise trust from any checkout of the repository`

---

### Task 4: A reopen carries

**Depends on:** Task 3

**Files:**
- Modify: `dot_config/zsh/functions`: `_wt_mise_reopen_warn`, and its call in `_wt_create_or_prepare`.
- Test: `tests/wt-functions.test.sh`, section Y.

**Interfaces:**
- Consumes: `_wt_mise_trust <main> <dest>`.
- Produces: `_wt_mise_reopen_warn <main> <dest>` (was `<dest> <branch>`). It runs the carry with no base. When the carry returns 1, it prints the reopen line and sets `_WT_NOTICE=1`. It always returns 0 and never runs a hook.

- [ ] **Step 1: Write the failing tests**

- Y1: after the edit to `$X/mise.local.toml`, the reopen has these lines:
  - `wt: ~/Code/Org/repo-y1/mise.local.toml is not trusted: it matches no trusted copy in this repository's checkouts.`
  - `    review: diff ~/Code/Org/repo/mise.local.toml ~/Code/Org/repo-y1/mise.local.toml`
  - `wt: opening ~/Code/Org/repo-y1 anyway — its shells load no project mise config until the files above are trusted.`

  It also has `hasnt "wt-prepare"`; the workspace still opens, and nothing is trusted. Y6's warning assertion becomes `has "is not trusted"`.
- Y4: has `wt: cannot read mise's trust status for ~/Code/Org/repo-y4 — trusting nothing.` and the opening-anyway line; the workspace opens.
- Y10: has `    then:   mise trust ~/'Code/Org/repo-fix!foo/mise.local.toml'`, and never `repo-fix!foo/mise.local.toml` unquoted after `mise trust `.
- Y14 (new) reopen carries. `xfix y14` with only main's `mise.toml` seeded, then `wt y14`: rc 1, the setup hook does not run. `mise_seed "$REPO/mise.local.toml"`, then reopen through the popup, `ypop "$REPO" y14`:
  - `STATUS=0`;
  - `wt: mise trust carried to ~/Code/Org/repo-y14/mise.local.toml (trusted in ~/Code/Org/repo)`;
  - no opening-anyway line, and `hasline "REST=SENTINEL"`: a reopen that carried everything does not hold the popup;
  - the setup hook still has not run.

- [ ] **Step 2: Run them to verify they fail** — Expected: FAILs on Y1, Y4, Y6, Y10, Y14.

- [ ] **Step 3: Implement** — `_wt_mise_reopen_warn` as above; the reopen branch calls it as `_wt_mise_reopen_warn "$main" "$dest"`.

- [ ] **Step 4: Run the suite** — Expected: `passed: N  failed: 0`.

- [ ] **Step 5: Commit** — `Carry mise trust when wt reopens a worktree`

---

### Task 5: `wt-rm` checks trust before it disrupts anything

**Depends on:** Task 3

**Files:**
- Modify: `dot_config/zsh/functions`: `wt-rm`, and its step-list comment above it (both checks named in steps 1 and 4).
- Test: `tests/wt-functions.test.sh`: the mise stub, `setup()`'s unset list, and section X. New XR cases go before the X13 sweep so it covers their calls.

**Interfaces:**
- Consumes: `_wt_mise_trust <main> <dest>`, `_wt_mise_show`, `_wt_hook_check`.
- Produces: nothing new. `wt-rm` keeps `_wt_hook_check`'s status from step 1.
  - On 0, after `_wt_rm_lock_class` and before `_wt_stop_herdr_workspaces`, it runs `_wt_mise_trust "$main" "$dest"`. On 1 it prints the step-1 line and returns 1.
  - On 0 again, right before `_wt_hook_run … teardown`, `_wt_mise_show "$dest"` must succeed and list no `untrusted` entry; otherwise the before-teardown lines are printed and `wt-rm` returns 1.
  - `_wt_rm_registration` is unchanged.

- [ ] **Step 1: Extend the stub and fixture**

- Stub: `MOCK_MISE_SHOW_FAIL_WHEN=<file>` fails every `trust --show` while `<file>` exists. Document it and add it to `setup()`'s unset list.
- Helper `mise_unseed <file>`: drops the file's entries from `$MISE_STUB_STORE`, keyed as the stub's `drop` is.
- Fixture `xrfix <slug>`: `xfix <slug>` followed by:
  - a committed `.gitignore` holding `mise.local.toml`, so the worktree stays clean;
  - `mkhook "$REPO"` with a hook that touches `$ROOTTMP/setup-ran` on `setup` and `$ROOTTMP/teardown-ran` on `teardown`;
  - `xseed`, then `wt <slug>`, which must succeed;
  - `: > "$HLOG"; : > "$MLOG"`.

- [ ] **Step 2: Write the failing tests**

- XR1 untrusted config. Make `$X/mise.local.toml` `b=2`, so no copy matches. `wt-rm xr1`:
  - rc 1;
  - the refusal with the new reason;
  - `wt-rm: nothing was closed or removed — review the mise config above, then: wt-rm xr1`;
  - `$HLOG` empty; no `teardown-ran`; `$X` exists.
- XR2 carried. `mise_unseed "$X/mise.local.toml"` (content unchanged). `wt-rm xr2`:
  - rc 0;
  - `trust $X/mise.local.toml` logged, then the carried line;
  - `teardown-ran` exists; `$X` is gone.
- XR3 main's read fails, a sibling vouches. As XR2, plus a sibling holding an identical, seeded `mise.local.toml`, and `MOCK_MISE_SHOW_FAIL_DIR="$REPO"`:
  - the cannot-vouch line for `~/Code/Org/repo`;
  - carried, `teardown-ran`, rc 0.
- XR4 the destination's read fails. `MOCK_MISE_SHOW_FAIL_DIR="$X"`:
  - rc 1;
  - `wt: cannot read mise's trust status for ~/Code/Org/repo-xr4 — trusting nothing.` (the carry's own line);
  - the step-1 line;
  - `$HLOG` empty.
- XR5a no hook. A repository with a tracked `mise.toml` and no `.worktreehook`, after `wt`, then `mise_unseed "$X/mise.toml"`: `wt-rm` succeeds, and `$MLOG` stays empty.
- XR5b already gone. `xrfix`, then `rm -rf "$X"`: `wt-rm` finishes the registration, and `$MLOG` stays empty.
- XR6 untrusted after step 1. A running default session holds a workspace at `$X` (section E's fixture), with `MOCK_H_CLOSE_TOUCH="$X/mise.local.toml"`, which empties it on close:
  - rc 1;
  - `wt-rm: ~/Code/Org/repo-xr6 has untrusted mise config (mise.local.toml) — teardown not run, Herdr workspaces closed.`;
  - `    Review the mise config, then retry: wt-rm xr6`;
  - `hlogged "workspace close"`; no `teardown-ran`.
- XR7 the before-teardown read fails. As XR6 with `MOCK_H_CLOSE_TOUCH="$ROOTTMP/closed"` and `MOCK_MISE_SHOW_FAIL_WHEN="$ROOTTMP/closed"`:
  - `wt-rm: cannot read mise's trust status for ~/Code/Org/repo-xr7 — teardown not run, Herdr workspaces closed.`;
  - no `teardown-ran`.

- [ ] **Step 3: Run them to verify they fail** — Expected: FAILs on XR1, XR3, XR4, XR6, XR7 (XR2 may pass early, since teardown's own `mise` is a stub).

- [ ] **Step 4: Implement** — as under Interfaces.

- [ ] **Step 5: Run the suite** — Expected: `passed: N  failed: 0`; sections O, U, V and W unchanged (their repositories hold no mise configs).

- [ ] **Step 6: Commit** — `Check mise trust in wt-rm before closing anything`

---

## After the last task

- Run `./tests/run.sh` (sandboxed) and report passed/total. Then the whole-branch review, then pre-merge, per the execution brief. In the commit before the first pre-merge dispatch, the spec's and this plan's `**Status:**` become `Implemented on \`feat/mise-trust-worktrees\` (no MR; dotfiles end at the pushed branch)`.
