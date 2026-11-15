# wt-rm closes the checkout's app spaces; outside both front ends means the app

**Status:** In progress (amendment of 2026-11-15, branch `fix/checkout-spaces-caller`, its PR
against `main`; plan `docs/superpowers/plans/2026-11-15-checkout-spaces-caller.md`). The design
before it: Implemented (branch `feat/wt-rm-app-spaces`, PR #22; plan
`docs/superpowers/plans/2026-11-15-wt-rm-app-spaces.md`).
**Date:** 2026-11-15
**Branch:** `feat/wt-rm-app-spaces`
**Sign-off:** Michael, 2026-11-15, with the five rulings below as written; Codex spec review
approved (round 2; round 1's three findings fixed).
**Amended:** 2026-11-15, after PR #22's acceptance: check 5 reads the foreground job's folders
(`ps`, `lsof`) of a terminal that answers without a folder, instead of refusing it at once. See
"Amendment (2026-11-15)" below; §2 says so where check 5 stands.

Builds on `docs/superpowers/specs/2026-11-14-herdr-app-native-tools-design.md` (its §5.1 rule and
its non-goal "wt-rm closing app spaces"), which stays as written; this spec replaces those two
parts.

## Why

Michael works in the Herdr desktop app now. Two gaps remain from the native-tools line:

1. **`wt-rm` ignores app spaces.** It closes the checkout's TUI workspaces
   (`_wt_stop_herdr_workspaces`, `dot_config/zsh/functions`) and knows nothing of the app. With
   an app space open, the space's shells sit in the checkout, so `wt-rm` runs the teardown hook
   and then refuses at check 4 (`wt-teardown scan`): "still in use by a running process". Only the
   space menu's **Retire worktree** (`dot_config/herdr-app/bin/executable_retire`) closes app
   spaces, and it carries its own copy of the rule for which spaces are the checkout's and safe
   to close. A third, partial copy sits in the menu patch
   (`dot_config/herdr-app/patches/worktree-actions.js`: `closing()` and a busy-agent check).
2. **A caller outside both front ends gets the TUI.** xreview and `dev` (so `wt`) pick a TUI pane
   (`HERDR_ENV`/`HERDR_PANE_ID`), else an app terminal (`HC_TERMINAL_ID`), else the TUI. A Claude
   Code driver in plain Ghostty therefore reviews and opens worktrees in the TUI, which Michael no
   longer watches. His call (2026-11-15): outside both, the app.

## Goals

- `wt-rm <branch>` closes the checkout's own app spaces as it closes its TUI workspaces, from any
  terminal (an app terminal, a TUI pane, plain Ghostty), and refuses before closing anything when
  closing would lose work or touch something that is not the checkout's.
- The rule for which app spaces are the checkout's, and when they are safe to close, lives in one
  file. `wt-rm` and Retire both use it; the menu patch keeps no copy.
- Retire keeps what it adds over `wt-rm`: it runs in a tab of its own, closes that tab after a
  clean run, and after a failure offers to reopen the space with its agents resumed.
- xreview and `dev` pick the TUI only from a TUI pane; everywhere else, the app. One rule, the
  same in both, tested by the same case table.

## Non-goals

- Changing how `wt-rm` treats TUI workspaces (`_wt_stop_herdr_workspaces` is untouched, busy TUI
  agents included). The TUI is on its way out (native-tools spec §5.7).
- App spaces on other machines (`machine` not null): a remote terminal cannot hold a local
  checkout, so they are never read or closed.
- Closing the app's windows, quitting the app, or starting, stopping or restarting herdr-core.
- An override variable for the front end (as before, tests set the variables themselves).

## Anti-goals

- Closing a space that is not the checkout's, or a terminal of Michael's that merely sits in it.
- Closing anything while a Herdr-side refusal is still possible: every check of both front ends
  runs before the first close. (Processes Herdr cannot see, such as another terminal app's shell
  in the checkout, stay check 4's, after the close, as today.)
- Losing work in progress: a busy agent or an open editor. Agent sessions themselves are not lost
  by a close: Claude Code and Codex keep every session on disk, and the printed resume commands
  are a shortcut to them, not their only copy.
- A front-end pick that depends on a probe of what is running.

## Approaches

- **A. A helper script in the app's own folder, `bin/checkout-spaces` (chosen).** `wt-rm` and
  Retire call it by absolute path; it pins its own PATH (as `open-space` does). The app's JSON
  shapes and `hc` knowledge stay in `~/.config/herdr-app`, next to the other app scripts, and its
  tests extend the retire cases already in `tests/herdr-app.test.sh` on the same stubs. `wt-rm`
  gains three call sites and one case in `wt-functions.test.sh`. When the TUI goes, nothing here
  moves.
- **B. zsh functions beside `_wt_stop_herdr_workspaces`.** Both front ends' rules in one file, and
  Retire already sources it. But the app's listing format and `hc` move into an 1,800-line file
  whose suite is heavy (149 s), `herdr-app` and `hc` would run from the caller's PATH unless each
  function pins it, and the app-side suite would test a function from another tree.
- **C. `wt-rm` calls Retire for the app part.** Retire runs `wt-rm`, so this is circular, and it
  would mix Retire's tab handling into a non-interactive tool. Dropped.

## Design

### 1. Which front end (replaces native-tools §5.1)

1. `HERDR_ENV` or `HERDR_PANE_ID` is set and not empty: the **TUI**.
2. Otherwise: the **app**.

`HC_TERMINAL_ID` no longer decides anything. xreview (`dot_local/bin/executable_xreview`, the
`FRONT_END` lines) and `dev` (`dot_config/zsh/functions`, the `app=` line) carry the same rule,
each with its comment updated.

What this changes in practice:

- From plain Ghostty, `xreview` drives the checkout's Codex pane in the app, and `dev`/`wt` open
  an app space through `open-space`. With the app's window closed, both refuse as they do today
  from an app terminal (xreview: "cannot list the Herdr app's panes - is its window open?").
  `herdr-app ls` answers a caller with no app identity (measured 2026-11-15 from this line's
  session, `HC_TERMINAL_ID`, `HC_SCOPE` and `HC_TERMINAL_SOCKET` removed: 24 spaces listed).
- `dev` from plain Ghostty no longer builds a TUI workspace and attaches to the TUI
  (`layout.sh`'s `hl_attach`). That is the intent.
- The TUI's worktree popup (`wt-prompt`, `prefix+shift+g`) must carry `HERDR_ENV`, or `wt` from it
  would now open an app space. It does by inference: without `HERDR_ENV`, `layout.sh` would have
  started a server check and handed the popup over to a nested TUI (`hl_attach`), which the popup
  has never done. Not measured; it is an acceptance item.
- `claude-code.md`'s sub-bullet becomes: "`xreview` and `wt` act on the Herdr front end the caller
  runs in, the TUI's workspace from a TUI pane and the app's space from anywhere else; a pane only
  in the other one is not found." (Same line count; its `rules.tsv` row follows.)

### 2. `checkout-spaces` — the one rule

`dot_config/herdr-app/bin/executable_checkout-spaces`, deployed
`~/.config/herdr-app/bin/checkout-spaces`, zsh, mode 755. It pins PATH to
`$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin` before running anything, as
`open-space` does: `wt-rm` runs it unsandboxed with whatever PATH the caller had. It reads the
caller's `HC_TERMINAL_ID` once, for the caller check below, and runs every `hc` call with
`HC_TERMINAL_ID` and `HC_SCOPE` removed (native-tools §5.3).

```
checkout-spaces list  <checkout>   read-only: JSON {spaces, terminals, records}
checkout-spaces check <checkout>   read-only: 0 safe to close, 1 refused (reasons on stderr)
checkout-spaces close <checkout>   check, print resume commands, close, verify
```

`<checkout>` is an absolute path that need not exist (`wt-rm` also finishes removals whose folder
is already gone). Exit 0 also when there is nothing to do.

**No app.** `herdr-app` is not on the pinned PATH: exit 0 for every verb, nothing read
(`list` prints the empty set). The app was never installed, so it holds no space.

**The app is not reachable.** `herdr-app ls` fails or does not answer a `{spaces: [...]}` object:
`check` and `close` refuse ("cannot read the Herdr app's spaces — open its window, then retry");
`list` exits 1. The window answers only while it is open, and terminals keep running in herdr-core
while it is closed, so "no answer" is never read as "no spaces". (My call: see Rulings to confirm,
below.)

**The checkout's own spaces** (the close set): local spaces (`machine` null) whose `.folder`,
resolved, is the checkout or lies under it (`<checkout>/…`, so a sibling such as
`proj-feat-other` never matches `proj-feat`). `.folder` is where the space was made, the app's
provenance, as `worktree.checkout_path` is the TUI's; where its terminals have wandered since
never adds or removes a space. Closing a space ends all its terminals, wherever they now are, as
closing a TUI workspace does. The exact folder's spaces come first in every list (Retire's reopen
prefers their records). This is Retire's rule today, unchanged.

**`check` refuses, naming each cause, when:**

1. the caller's `HC_TERMINAL_ID` is a terminal of the close set ("run it from another space");
2. an agent or sub-agent of the set is `working` or `blocked`. A pane terminal's status is the
   app's; a sub-agent's is only in the core's `hc ls`, which the app lists by address only, so
   when the set has a sub-agent, `hc ls` must answer a valid listing that includes every one of
   them, or `check` refuses (Retire today ignores a failed `hc ls`);
3. a terminal of the set cannot be asked about (`hc get`, five seconds): it cannot be vouched for;
4. an editor of the Vim family (`mods/nav`'s pattern) is in the foreground of a terminal of the
   set: its unsaved buffers would die with it;
5. a terminal of any other local space is now (`hc get`'s foreground folder, raw or resolved)
   in the checkout: that space is not ours, so Michael is told to `cd` out or close it. Such a
   terminal that cannot be asked about, or answers without a folder, refuses too, naming it and
   its space: where it is cannot be told, so neither front end may close yet. (Retire today lets
   it pass and leaves it to check 4, which runs only after the close.)

> **2026-11-15 — amended.** A terminal that answers without a folder is no longer refused at
> once: the folders of every process in its foreground group (`ps`, `lsof`) are tested instead,
> and it refuses only when one is in the checkout or the group cannot be read. See "Amendment
> (2026-11-15)".

Everything else in the set closes with it: idle and done agents, shells, servers. A process that
survives the close is still caught by check 4.

**`close`** runs `check`; prints `cd <cwd> && <cmd>` for every resume record of the set's
terminals (the window forgets them on close; `"resume.sessions"` in `$HERDR_APP_HOME/shared.json`,
read as Retire reads it today). When the file exists but cannot be read as JSON, or an agent of
the set has no record, it says so on stderr, naming each such agent, instead of printing nothing
(`claude --resume` and `codex resume` still list its session); this never refuses. It then closes
each space with
`herdr-app do space.close {id, confirmed: true}`; then lists again and refuses if any space of the
set is still there. A failed close stops at once and names the spaces already closed and the one
that failed.

**`list`** prints `{spaces: [ids], terminals: [addresses], records: [...]}` for the close set, in
the order above, without refusing on anything but an unreachable app. Retire uses it (§4).

### 3. `wt-rm`

Step 2 ("stop the checkout's Herdr workspaces") becomes three calls, in this order:

1. `checkout-spaces check "$dest"`: any refusal stops `wt-rm` before anything closes.
2. `_wt_stop_herdr_workspaces "$dest"`, unchanged: the TUI decides its own refusals, then closes.
3. `checkout-spaces close "$dest"`: checks again (the TUI close took time, and an agent may have
   started) and closes.

A checkout open in both front ends is therefore checked in both before either closes; the only
partial state is a refusal in call 3 after the TUI closed, which needs a change between calls 1
and 3, and its message says the TUI workspaces were closed and nothing was removed.

`_wt_rm_registration` (the checkout already gone, Git's registration left) makes the same three
calls around its `_wt_stop_herdr_workspaces`.

The helper is called as `$HOME/.config/herdr-app/bin/checkout-spaces`. When that file is not
executable, the app part is skipped, as `_wt_stop_herdr_workspaces` skips the TUI when `herdr` is
not installed: chezmoi deploys it with the app's folder. No environment override; the
`wt-functions` cases put a stub at that path in their scratch `HOME`.

Messages that say "Herdr workspaces closed" (teardown failed, check 4, removal failed) say
"Herdr workspaces and app spaces closed". `wt-rm`'s header comment (step 2) says what it now does.

`wt-rm` closes both front ends whatever the caller's front end: removal is about the checkout,
not about where `wt-rm` was typed. Its own check that the caller is not inside `$dest` stays.

### 4. Retire

Retire keeps its tab, its outcome handling and its reopen, and drops what `wt-rm` now does:

1. Usage, the folder exists, and the three refusals that make `retire <folder>` act on the same
   folder as `wt-rm <branch>`: not the main checkout, not a detached HEAD, and the folder is where
   `wt` puts that branch's worktree. Its other read-only checks go (`_wt_assert_worktree`, the hook
   check, the lock class, `_wt_clean`): `wt-rm` makes each of them before it closes anything.
2. `checkout-spaces list "$folder"`: keeps the records for a reopen. An unreachable app refuses,
   nothing closed or removed.
3. `wt-rm <branch>` from the main checkout, stderr through `tee` as today. `wt-rm` checks, prints
   the resume commands, closes the spaces and removes the checkout.
4. Success: as today (close its own tab, or wait for Enter after a warning).
5. Failure: as today, except that the reopen is offered only when the set was not empty in step 2
   and `checkout-spaces list` now shows none of those spaces (they closed and the checkout is still
   there). A refusal before any close leaves the spaces open, so there is nothing to reopen.

### 5. The menu patch

`patches/worktree-actions.js` drops `closing()` and the busy-agent notification: a busy agent is
now refused in the retire tab, with the same wording as `wt-rm`'s. The retire tab goes in the main
checkout's space if one is open, else in a new space at the main checkout; never "the space in
front", which could be one about to close. The main checkout is never in the close set: `wt` puts
every worktree beside it, and Retire refuses any other folder. After merge Michael runs `respaces`
to copy it into the `michael-menu` clone.

## Safety

- **Deletion order.** No space closes until `wt-rm`'s check 1, hook check, lock class and mise
  trust carry have passed, and the app's and the TUI's refusals have all been decided.
- **Process termination** is limited to the close set, decided by provenance, after every refusal;
  Michael's terminals in other spaces are never closed, only named.
- **Sandbox write boundary.** The helper pins PATH before running anything; `~/.local/bin`,
  `~/.config` and `/opt/homebrew` are outside `allowWrite`. Agents do not run it: `wt-rm` is
  Michael's to run, and Retire runs from the app's menu.
- **Never type into an agent.** The helper reads (`ls`, `get`) and closes; it sends no keys.

## Tests

Michael's rule: one case per new behaviour or plausible regression, extending existing cases
first, no variant matrices.

- `tests/herdr-app.test.sh`: Retire's refusal and close-set cases (busy, sub-agent, inside,
  subfolder space, sibling prefix, wandered out/in, unaskable, editor, all resume commands
  printed) move to `checkout-spaces check`/`close` unchanged in substance, except that the
  unaskable-foreign-terminal case now expects a refusal. New: a sub-agent missing from `hc ls` (or
  `hc ls` failing) refuses; unreadable records warn on stderr and still close; `close` refuses
  when a space survives the close; an unreachable app refuses `check`; no `herdr-app` on the
  pinned PATH is exit 0 with nothing called. Retire keeps its main-checkout, not-a-repository,
  misplaced, detached, success, warned, failure, reopen, own-records and no-records cases (the
  `wt-rm` stub closes the spaces through the helper when a case needs them closed); its dirty
  case goes (`wt-rm` covers it). New: a `wt-rm` that fails before closing offers no reopen.
- `tests/wt-functions.test.sh`: a stub `checkout-spaces` in the scratch `HOME`, logging its
  verbs. One case: `check` runs before the TUI close and `close` after it, and the removal follows;
  one: `check` refusing leaves the TUI workspaces open and nothing removed; one: the registration
  path calls both. `setup()` exports `HERDR_PANE_ID` so the existing `wt`/`dev` cases keep the
  TUI; the app case clears it.
- `tests/dev.test.sh` K table and `tests/xreview.test.sh` FE table: K4/FE4 (an empty
  `HC_TERMINAL_ID`) become "neither variable: the app"; the other rows stand. Suites that ran the
  TUI path with no variable set now export `HERDR_PANE_ID` at their top, and the app rows unset it.
- `tests/dev-topology.test.sh` (real `herdr`) exports `HERDR_PANE_ID` and sets
  `DEV_OPEN_SPACE=/usr/bin/false`, so a mistake can never reach the real app.
- `tests/agent-instructions.test.sh`: `rules.tsv` row `cc-excluded-front-end`.
- `.scripts/test-audit/subjects.tsv`: the helper's row (suite `herdr-app`).
- Pre-merge: `./tests/run.sh --changed` (runs the heavy `xreview` and `wt-functions` suites),
  plus `herdr-app`. Nothing from this branch runs against the live app before merge.

**Acceptance, Michael's, after merge, `chezmoi apply` and `respaces`** (unchecked items in the PR):

- From plain Ghostty, a Claude Code driver's `xreview -C <checkout>` drives that checkout's app
  Codex pane, and `wt --no-focus <branch>` opens an app space.
- From a TUI pane, `xreview` still drives the TUI's Codex pane, and the TUI popup's `wt` still
  opens a TUI workspace.
- On a scratch worktree with its app space open (idle Claude and Codex): `wt-rm <branch>` from
  another space prints the resume commands, closes the space and removes the checkout; with an
  agent working there it refuses and closes nothing; run from a terminal of that space it refuses.
- From plain Ghostty and from a TUI pane, `wt-rm` on a scratch worktree with an idle app space
  prints the resume commands, closes the space and removes the checkout.
- `wt-rm` succeeds while another line's agents are running sub-agents in their own spaces (check 5
  reads every local terminal).
- The menu's Retire worktree on a scratch worktree removes it and closes its tab; with an agent
  working it refuses in the retire tab.
- This line's own `wt-rm feat/wt-rm-app-spaces`, run from the main checkout's space once this
  line's session is done, is a real case of the third item.

## Order and coordination

- `feat/herdr-app-popups` (popup mod, `keys.json`, `wt-app --prompt`) and
  `feat/herdr-app-auto-resume` (`mods/resume`) run in parallel; this line stays out of their files.
  The helper reads `mods/resume`'s records exactly as Retire does today; if auto-resume changes
  their shape, whichever line merges second adapts `checkout-spaces`.

## Rulings to confirm at sign-off (my calls)

1. App window not reachable: refuse rather than proceed when herdr-core shows no app terminal in
   the checkout. Simpler and fail-closed; the cost is opening the window before a `wt-rm`.
2. `wt-rm` takes Retire's refusals for app spaces (busy agent, open editor), so it now refuses
   where the TUI path would close; the TUI path is left alone.
3. `close` prints the resume commands it has and names any agent without one; a missing record
   warns, never refuses.
4. The menu patch keeps no copy of the rule (§5), at the cost of a retire tab, not a toast, for a
   busy agent.
5. Two of Retire's lenient reads become refusals (§2, checks 2 and 5): a failed `hc ls` when the
   set has a sub-agent, and another space's terminal that cannot be asked where it is. The cost is
   a refusal whenever one local terminal anywhere in the app stops answering `hc get`.

## Left to the builder

- Exact refusal wording, and whether the helper's messages carry its own name or the caller's.
- How the `wt-rm` stub in `herdr-app.test.sh` closes spaces for the reopen cases.
- Where in `dev.test.sh` and `xreview.test.sh` the top-level `HERDR_PANE_ID` export goes.

## Amendment (2026-11-15): check 5 and a terminal that answers without a folder

**Branch:** `fix/checkout-spaces-caller`. **Plan:**
`docs/superpowers/plans/2026-11-15-checkout-spaces-caller.md`.
**Sign-off:** Michael, 2026-11-15; Codex spec review approved (round 3; rounds 1 and 2's three
findings fixed).

**What happened.** In PR #22's acceptance, `wt-rm accept-wtrm` from Michael's app shell `t10s`
passed `wt-rm`'s first `check`, then refused at the re-check inside `close`: "cannot tell where
terminal t10s (chezmoi / runtime) is: hc get gave no folder". Nothing was closed or removed. In
that shell, the helper's own call, `hc get "$HC_TERMINAL_ID" --json`, answered `.foreground.cwd`
3 times in 10 and `"state": "live"` with `"foreground": null` 7 times. Idle and agent terminals,
asked read-only the same day, answered with a folder 96 times in 96.

**Cause.** Check 5 asks hc about every terminal of every other local space. When `wt-rm` runs
from an app terminal outside the close set (inside it, check 1 refuses), the caller's own terminal
is one of them. While the helper runs, that terminal's foreground is the helper's own short-lived
process chain (the helper, `perl`, `env`, `hc`), and hc mostly answers it as no foreground.
Retire runs `wt-rm` from its own tab, so it trips the same way.

**Check 5, amended.** A terminal of another local space that answers `hc get` without a folder is
no longer refused at once; its foreground job is read directly:

1. `ps -o tpgid=` on the terminal's root process (`hc get`'s top-level `.pid`) gives the process
   group in that terminal's foreground;
2. `lsof -a -g <group> -d cwd` gives the folder of every process in that group, bounded to five
   seconds as `hc get` is;
3. `check` refuses when any of those folders, raw or resolved, is the checkout or lies under it,
   naming the terminal and the folder. It also refuses ("cannot tell where terminal … is") when
   the answer names no root pid, `ps` or `lsof` fails, or `lsof` names no folder.

A terminal that answers with a folder is tested as before: hc's one foreground process stands for
its job, as in the design above. A terminal that does not answer still refuses. Background jobs,
outside the foreground group, stay check 4's, as before.

The caller's own terminal gets no exception, and it needs none. While the helper runs from it,
that terminal's foreground job is the helper's own: the helper, whatever started it in the same
group (`wt-rm`, or Retire and its subshell) and their children. So `lsof` names their folders,
the helper's own among them. If the caller does not own its terminal's foreground, the group read
is whatever does: `HC_TERMINAL_ID` is inherited by every process started in that terminal.
Measured 2026-11-15 from this line's own app terminal, read-only:

- `hc get` names the root shell as `.pid` and `claude` as the foreground;
- `ps` gives the root's `tpgid` as `claude`'s group;
- `lsof -a -g <that group> -d cwd -Fn` lists both of its processes with their folders, in 12 ms;
- the Claude Code session's own Bash command has no controlling terminal (`tpgid` 0, tty `??`),
  so it is outside that group.

**Considered and declined.**

- Skipping the caller's terminal and testing the helper's own folder in its place. It sees
  neither another process of the caller's foreground job in the checkout (a script there that
  starts `wt-rm` from another folder) nor a foreground that is not the helper's.
- Excusing the caller's terminal when its foreground group is the helper's own, and testing the
  helper's folder in its place. It has the first blind spot above.
- A bounded retry for a terminal that answers without a foreground. Reading the group answers
  it: a terminal whose foreground group changed between hc's lookup and its read is read the
  same way, and refuses only when its group cannot be read or is in the checkout.

**Tests** (`tests/herdr-app.test.sh`). The `ps` stub gains a `tpgid=` answer, from
`$STUB_DIR/tpgid-<pid>`. A new `lsof` stub answers `-g <group>` from `$STUB_DIR/lsof-<group>`
and fails without it; it gets a `subjects.tsv` row and is linked into the scratch
`$HOME/.local/bin` beside the other stubs. One new case beside `nofolder`, for the caller t9 in
the main checkout's space, answering `{"state":"live","pid":<root>}`:

- its foreground group's folders all outside the checkout: `check` passes;
- one of them inside the checkout: `check` refuses, naming t9 and the folder;
- `lsof` failing for the group: `check` refuses.

The `nofolder` case (another terminal answering `{"state":"live"}`, no root pid) still refuses.
Each assertion passes the revert check.

**Acceptance, Michael's, after merge and `chezmoi apply`** (unchecked items in the PR):

- On a scratch worktree with its app space open, `wt-rm <branch>` from an app shell in another
  space prints the resume commands, closes the space and removes the checkout, with no "gave no
  folder" refusal.
- Retire worktree on a second scratch worktree removes it and closes its tab.
