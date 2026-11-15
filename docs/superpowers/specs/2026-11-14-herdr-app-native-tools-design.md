# xreview and wt on the Herdr desktop app

**Status:** Approved
**Date:** 2026-11-14
**Branch:** `feat/herdr-app-native-tools`
**Sign-off:** Michael, 2026-11-15; Codex spec review approved (round 2; round 1's two findings
fixed).

Michael is moving from the herdr TUI to the Herdr desktop app (decided 2026-11-14: the TUI repo has
had no commits since Oct 29, while herdr-core and herdr-app get 100+ a month). Today the app reaches
his tools only through adapters in `~/.config/herdr-app`, built while the app was a trial and kept
out of the dotfiles on purpose:

- `bin/xreview-app` runs the real xreview with `xreview-shim/herdr` first on its PATH. The shim
  answers xreview's `herdr pane …` calls from the app (`herdr-app ls`, `hc get/keys/send/read`).
- `bin/wt-app` runs wt's lifecycle (`_wt_create_or_prepare`) and opens the checkout with
  `bin/open-space` instead of the TUI's `layout.sh`.
- `bin/claude-app` starts every app Claude session with an appended system prompt that reroutes
  `xreview` to `xreview-app` and `wt --no-focus` to `wt-app --no-focus`, and with
  `--settings claude-settings.json`, which puts those two full paths outside the sandbox.

This line makes `xreview` and `wt` act on the app themselves when they run from it, so the hint and
the extra settings have nothing left to do, while the TUI keeps working until Michael retires it.

## Goals

- `xreview`, run from an app terminal, finds and drives the checkout's Codex pane in the app,
  through `hc` and `herdr-app`, with every safety rule the shim has today.
- `wt` (and `dev`, which `wt` goes through), run from an app terminal, opens the checkout as an app
  space; `--no-focus` leaves Michael's focus where it was.
- New app Claude sessions need no appended prompt and no extra settings: the instructions already
  name `xreview` and `wt`, and `sandbox.excludedCommands` already holds `xreview *` and `wt *`.
- Run from a TUI pane, or from neither front end, both tools behave exactly as today.
- App sessions started before this applies keep working, resumed ones included.

## Non-goals

- Retiring the TUI, its backend in xreview, `layout.sh`, the `herdr *` exclusion or the
  compatibility wrappers. That is a later line, when Michael retires the TUI (§5.7).
- `wt-rm` closing app spaces. The app's Retire worktree action (`bin/retire`) closes the checkout's
  spaces and then runs `wt-rm`; a space left on a removed checkout shows the "gone" badge.
- Letting agents call `hc` or `herdr-app` outside the sandbox. Only xreview and wt need them, and
  both already run unsandboxed.
- The statusline, the phase badges, the Codex pane-map hook and where `codex-pane-command` lives.

## Anti-goals

- Typing into a live Codex. Any process state the app cannot report with certainty stays a failed
  read, never "freed".
- A new unsandboxed path that runs a program found through a PATH the sandbox could have written.
- One global switch that breaks whichever front end it does not select while both are in use.

## Decisions (Michael, 2026-11-14)

1. **The shim becomes a dotfiles helper** (approach B below), not app calls written into xreview.
2. **The caller's terminal picks the front end**, not a config switch or a probe of both.
3. **When both front ends have a Codex pane for one checkout, the caller's wins,** and xreview's
   lock moves from the pane to the checkout, so the two can never run reviews of one checkout at
   once.
4. **`xreview-app`, `wt-app` and `claude-settings.json` stay as thin wrappers until the TUI is
   retired;** the TUI-retirement line removes them with the TUI path.
5. **The helper calls `hc` without the caller's terminal identity** (2026-11-15), rather than
   `notes = false` in herdr-core's config for everything (§5.3).

## Approaches

- **A. App calls written into xreview (bash).** Every pane function branches to `hc` /
  `herdr-app`. Everything lives in one file, but the shim's checks (the root process must be a
  shell, process-group reads, hc and ps must agree) and their 28k suite would be rewritten in
  bash, and xreview's pane code would carry both front ends' logic until the TUI goes.
- **B. The shim moves into the dotfiles as `~/.local/bin/xreview-app-pane` (chosen).** xreview
  calls either `herdr` or the helper. The 11 `herdr pane …` call sites change mechanically; the
  helper's code, reviewed by Codex with its P1 fixes in, is kept but for one fix found live
  (§5.3), and so is its suite. When
  the TUI goes, the `herdr` branch is deleted and nothing else moves.
- **C. Pane I/O in `xreview-rpc` (python).** Rewrites both front ends; nothing gained for the cost.

## Design

### 5.1 Which front end

One rule, used by xreview and by `dev`:

1. `HERDR_ENV` or `HERDR_PANE_ID` is set and not empty: the **TUI** (the caller is in a TUI pane;
   a TUI started inside an app terminal is the innermost front end).
2. Otherwise `HC_TERMINAL_ID` is set and not empty: the **app**.
3. Otherwise: the **TUI**, as today.

App terminals carry `HC_TERMINAL_ID`, `HC_SCOPE` and `HC_TERMINAL_SOCKET` and no `HERDR_*`
variable, and Claude Code passes them into its Bash calls (measured in this session). A wrong pick
is never unsafe: each front end's pane is validated in full before any keystroke, so the cost of a
wrong pick is a "no Codex pane" refusal. No override variable: the tests set or clear the variables
themselves.

The rule is three lines in xreview (bash) and three in `dev` (zsh). Both suites test the same
case table (§7) instead of sharing a helper executable, which would add a file, a failure path and
a PATH dependency to save three lines that die with the TUI. (Builder's call stated, not
Michael's.)

### 5.2 xreview

- At start, after PATH is pinned, xreview sets its pane command from §5.1: `herdr` for the TUI,
  `xreview-app-pane` for the app. Every `herdr pane …` call goes through it.
- Refusals that name a front-end command today ("herdr pane get", "is herdr running?") name the
  front end in use instead: the app's say "the Herdr app" and, where it helps, that its window
  must be open (`herdr-app ls` answers only while it is).
- `warn_pane_map_untrusted` runs for the TUI only: the pane-map hook feeds herdr's session ids,
  and the app reads the title directly. `report_to_herdr` stays as is (the helper answers it with a
  no-op).
- **The lock is per checkout.** `lock_pane` takes its key from `pane_root` (the checkout whose
  Codex pane it is, the main checkout for a harness worktree) instead of the pane id, at both of its
  call sites (dispatch, and a sliced round's collect). Within one front end a checkout has at most
  one Codex pane, so nothing changes there; across front ends, two dispatches for one checkout now
  wait for the same lock. The lock file stays under `$XDG_STATE_HOME/xreview/locks/` and is named
  by the SHA-256 of the pane root: a path squeezed into a file name the way a pane id is today
  would let `/a/b` and `/a_b` share a lock, and a deep checkout would exceed the 255-byte name
  limit and refuse every dispatch.
- Nothing else in xreview changes: find_pane's cwd match, `XREVIEW_PANE`, the guard, the ladder, the
  resume and every rule about the thread read the same JSON as before.

### 5.3 `xreview-app-pane`

The shim (`dot_config/herdr-app/xreview-shim/executable_herdr` once line 1 has merged) moves with
`git mv` to `dot_local/bin/executable_xreview-app-pane` (deployed `~/.local/bin/xreview-app-pane`,
mode 755, zsh). Its behaviour does not change, but for the one fix below:

- It answers exactly the seven call forms xreview makes (`pane list`, `get`, `process-info --pane`,
  `send-keys <id> ctrl+c`, `run`, `read … --source visible --lines <n> --format text`,
  `report-agent-session …`), and anything else fails on stderr and does nothing.
- Pane ids are `app:<terminal>`; only local terminals whose agent is Codex are listed; the calls on
  one id also take a terminal with no agent (a Codex xreview just quit).
- Every uncertain reading is a failed read: an app listing no spaces, an answer that is not a
  terminal, a root process that is not a shell, a foreground in its shell's own process group, hc
  and ps disagreeing. A terminal of another agent, a remote one or an unknown one is "not found",
  and nothing is sent to it.

**The fix: every `hc` call runs with `HC_TERMINAL_ID` and `HC_SCOPE` removed.** `hc send` from a
terminal hc knows wraps a message to an agent terminal as `<hc from="t87">…</hc>` (its sender
notes). A Codex pane xreview has just quit still reports Codex's status for a moment, so the resume
command arrived tagged and zsh refused it (`parse error near '\n'`), leaving the pane at a bare
shell: seen live on this line's spec review, 2026-11-15. On a scratch terminal reporting agent
status, the same send came out tagged with the caller's identity and plain without it. Without
an identity the helper's calls are also not an agent's calls to hc's parent bookkeeping, which
they never were meant to be.

`hc` is not limited to the caller's space: from this line's own app terminal, `hc get` and
`hc read` of another space's Codex terminal both answer (measured 2026-11-15, read-only), so a
driver's `xreview -C <checkout>` reaches a line's pane in its own space. `hc keys` and `hc send`
were not tried on another space's live Codex, by the rule above; the acceptance check (§7)
covers them.

Beyond the fix, only its header comment changes (it is no longer "a `herdr` first on PATH"). It
runs with
xreview's pinned PATH, where `~/.local/bin` holds the `hc` and `herdr-app` links and
`/opt/homebrew/bin` holds `jq`; it is not an excluded command, so called by hand from a sandboxed
shell it stays sandboxed.

### 5.4 `dev` and `wt`

`wt` reaches a front end only through `dev` (`wt` → `_wt_create_or_prepare` → `dev "$_WT_DEST"`),
so the routing goes in `dev`, after the repository is resolved:

- **TUI** (§5.1): unchanged, `layout.sh` as today.
- **App**: a linked checkout still goes through `_wt_prepare_for_herdr` (lock, `_wt_assert_worktree`,
  the Git worktree lock that keeps removal behind `wt-rm`); then `dev` runs
  `${DEV_OPEN_SPACE:-$HOME/.config/herdr-app/bin/open-space} [--no-focus] <repo>`, which builds or
  focuses the space.
- `open-space` pins its own PATH (§5.6), so `dev` calls it as it calls `layout.sh`. The
  repository hooks `_wt_create_or_prepare` runs keep the caller's PATH, as now: they need project
  tools.
- `wt-prompt` (the TUI popup) is unchanged.

`dev` itself gains app routing as a consequence; that is the one seam, not a feature of its own.

### 5.5 Agent instructions and settings

- `sandbox.excludedCommands` does not change: `xreview *` and `wt *` cover both front ends.
- `claude-code.md` gains one sub-bullet under **Excluded tools**: `xreview` and `wt` act on the
  Herdr front end the caller runs in, the app's space or the TUI's workspace. A driver in one front
  end therefore cannot review a line whose Codex pane is only in the other. (45 of 50 lines.)
- `global.md` does not change (it is at its 150-line cap; "its own Herdr workspace" reads for both).

### 5.6 The app side

These files reach the dotfiles through line 1 (`chore/herdr-app-in-chezmoi`, which brings
`~/.config/herdr-app` into chezmoi as `dot_config/herdr-app/`: scripts verbatim as
`bin/executable_<name>`, `programs.json` and `claude-settings.json` as `.tmpl` files with the home
directory templated, the suites as `tests/herdr-app.test.sh` and `tests/herdr-app-xreview.test.sh`,
their stubs and fixture under `tests/fixtures/herdr-app/`). This line changes them only after
rebasing onto its merge.

- `xreview-shim/` is gone (§5.3), and so is its `!` line in `.chezmoiignore`.
- `bin/executable_xreview-app` shrinks to: PATH pinned to `/usr/bin:/bin:/usr/sbin:/sbin` before
  anything runs, then `exec "$HOME/.local/bin/xreview" "$@"`. The caller's `HC_TERMINAL_ID`
  selects the app.
- `bin/executable_wt-app` keeps its `--prompt` and `--no-focus` handling and the tab that closes
  itself, and calls `wt` instead of `_wt_create_or_prepare` and `open-space`. It keeps the caller's
  PATH (it is `wt`).
- `bin/executable_open-space` and `bin/executable_close-own-tab` pin PATH to
  `$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin` (xreview's) before they run
  anything. They need no project tool, and both run unsandboxed after the caller's PATH has been
  used for the hooks: `wt *` and `wt-app` (an excluded command for old sessions) reach them, and a
  repository's mise `_.path` can put a sandbox-writable folder on that PATH.
- `bin/executable_claude-app` becomes `exec claude "$@"`. `open-space` and `programs.json.tmpl`
  start plain `claude`; `claude-app` stays only for commands already recorded with its path.
- `claude-settings.json.tmpl` is unchanged.
- The suites follow: the shim's cases leave `tests/herdr-app-xreview.test.sh` for
  `tests/xreview-app-pane.test.sh` (§7); what remains there, and `tests/herdr-app.test.sh`, pin
  the wrappers' and `open-space`'s new behaviour.

### 5.7 Transition and TUI retirement

- An app session started before this applies keeps its recorded hint and `--settings` path, also on
  resume, so `xreview-app`, `wt-app`, `claude-app` and `claude-settings.json` keep working as thin
  wrappers until the TUI is retired.
- The TUI-retirement line, when Michael calls it, removes `xreview-app`, `claude-app`,
  `claude-settings.json` and `wt-app`'s plain and `--no-focus` forms, xreview's `herdr` branch and
  §5.1 rule, `dev`'s `layout.sh` path, `layout.sh` itself and the `herdr *` exclusion. `wt-app
  --prompt` stays: it is the app's new-worktree key (§5.6).
- Apply when no review is running: a dispatch in flight under the old pane-keyed lock and one
  under the new checkout-keyed lock would not see each other.

## Safety

- **The sandbox write boundary.** xreview pins PATH before it runs anything, and the helper inherits
  it; neither reads a program from a folder the sandbox can write (`~/.local/bin`, `~/.config` and
  `/opt/homebrew` are outside `allowWrite`). `open-space` and `close-own-tab` pin their own PATH,
  and `xreview-app` pins it before its `exec`. Only wt's lifecycle and hooks (`wt`, `wt-app`
  until it hands over) keep the caller's PATH, by design, as today.
- **Never type into a live Codex.** The helper's rules are unchanged (§5.3), and xreview's guard,
  ladder and resume read the helper's answers exactly as they read herdr's.
- **One dispatch per checkout** across both front ends (§5.2).

## Tests

- **Every suite that runs xreview, `dev` or `wt` clears `HC_TERMINAL_ID`, `HC_SCOPE`,
  `HC_TERMINAL_SOCKET`, `HERDR_ENV` and `HERDR_PANE_ID` at its top** unless a case sets them:
  otherwise a run from an app terminal (as this session is) silently takes the app path.
- `xreview.test.sh`: the §5.1 table (TUI variable only, `HC_TERMINAL_ID` only, both, neither), with
  a logging `xreview-app-pane` stub beside the `herdr` stub: the app case calls only the helper,
  the others only `herdr`. The two lock-name pins move to the checkout digest; one case shows a
  dispatch from each front end for the same checkout contending for one lock, one that `/a/b` and
  `/a_b` do not, and one that a checkout path longer than 255 bytes still locks. The pane-map
  warning is not printed on the app path.
- `tests/xreview-app-pane.test.sh` (zsh shebang): the shim's cases from line 1's
  `tests/herdr-app-xreview.test.sh`, on the stubs (`hc`, `herdr-app`, `ps`) and the TUI-shape
  fixture in `tests/fixtures/herdr-app/`. Its contract cases run xreview's own jq filters over the
  helper's answers; a drift check fails the suite when a copied filter no longer appears verbatim in
  `dot_local/bin/executable_xreview`, instead of pinning line numbers. The `hc` stub records
  whether `HC_TERMINAL_ID` or `HC_SCOPE` reached it, and every call asserts neither did.
- `dev.test.sh` and `wt-functions.test.sh`: the §5.1 table with `DEV_OPEN_SPACE` and `DEV_LAYOUT`
  stubs: the app case runs `open-space` (with `--no-focus` passed on, a linked checkout prepared
  first) and never `layout.sh`; the others the reverse. The app-side suites assert that
  `open-space` and `close-own-tab` ignore a caller PATH that shadows `herdr-app` and `jq`.
- `agent-instructions.test.sh` and its fixtures follow the `claude-code.md` line.
- `.scripts/test-audit/subjects.tsv` gets the helper's row (suites `xreview-app-pane`, `xreview`)
  and the new suite's subjects in the same commit.
- Pre-merge: `./tests/run.sh --changed` (runs the heavy `xreview` and `wt-functions` suites), plus the
  app-side suites. The line's own cross-reviews run through the deployed xreview (`xreview-app`,
  as this session's prompt says); no code from this branch runs against the live app, the Codex
  daemon or the ledger before merge.
- **Acceptance, Michael's, after merge and `chezmoi apply`** (listed in the PR as unchecked items):
  from an app session, a plain `xreview` dispatch drives that space's Codex pane; a driver's
  `xreview -C <checkout>` drives a line's pane in another space; `dev --no-focus <existing
  checkout>` focuses or opens its space without taking focus, and the next real `wt --no-focus`
  opens one; from a TUI pane, `xreview` still drives the TUI's Codex pane; a Claude tab started
  from the app's own menu runs plain `claude` (`programs.json` no longer overrides it). (Builder's call: a
  pre-merge run from source needs sandbox escapes, a scratch branch that only `wt-rm` removes,
  and would write a review receipt from unshipped code.)

## Order and coordination

1. xreview (§5.2, its suite on a stub of the helper), `dev`/`wt` (§5.4), the instruction line
   (§5.5): on this branch now.
2. Rebase onto line 1's merge, then the helper's move and suite (§5.3) and §5.6. If line 1 has not
   merged by then, the line waits and says so.
- `feat/forge-push-protection` edits `global.md` 68–73; this line leaves `global.md` alone.
  `fix/codex-resume-cwd` touches Codex's config and `live-codex-daemon`, not xreview.

## Left to the builder

- The exact names of the shell variable and functions for the pane command, and the wording of the
  refusals that name the front end.
- How the drift check finds xreview's filters.
- How the remaining app-side cases pin §5.6.
