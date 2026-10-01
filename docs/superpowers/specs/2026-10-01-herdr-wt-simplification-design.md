# Herdr/wt simplification

**Status:** Implemented (branch herdr-wt-simplify; the dotfiles have no MR, so the rulings and deviations are recorded in "Implementation notes" at the end)
**Date:** 2026-10-01
**Branch:** `herdr-wt-simplify`

## Goal

Fix three verified bugs in the worktree and Herdr tooling, and delete the machinery that
caused two of them. This track was deferred from the 2026-09 setup review, whose goals are
simplify, improve and more safe autonomy. The review's audit was written against herdr
0.9.2, so every item below was re-checked against the current code, herdr 0.9.3 and git
2.56 before it went into this design.

**Constraints.**
- `wt-rm` is always run by Michael. Nothing here makes it an autonomy target, and no agent
  runs it against a real worktree; the test suites drive it only against scratch fixtures.
- Prompt budget: nothing here may add a permission prompt. The guard keeps denying silently
  with a reason the agent can act on.
- The `xreview-option-b` branch owns `dot_local/bin/executable_codex`,
  `dot_local/bin/executable_xreview`, `dot_codex/executable_herdr-codex-pane-map.py`,
  `dot_codex/modify_private_config.toml`, the cross-review skill, `AGENTS.md` and their tests.
  This branch does not edit them until Option B is merged and main is merged in here. The
  build starts only after that merge.

**Kept as they are:** the wt core lifecycle (`wt`, `wt-prepare`, `wt-rm`'s check ordering,
the `.worktreehook` protocol), label-based `tab-goto.sh`, the phase LaunchAgent and the
`dev.phase` startup and event hooks.

**Rejected alternatives, not reopened:** one typed CLI over herdr's socket API in place of
the shell tooling; merging the Claude and Codex agent-state hooks; replacing `wt` with Claude
Code native worktrees.

## Baseline (verified 2026-10-01)

| Item | Finding |
|---|---|
| Bug 1: `wt-rm` closes the wrong workspaces | `_wt_herdr_runtime_matches` (`dot_config/zsh/functions`) collects every workspace that has any pane whose cwd is at or under the checkout, and `_wt_stop_herdr_workspaces` closes them all. Pane cwd follows `cd`, so a pane in the primary checkout's workspace that has `cd`'d into the worktree gets the whole primary workspace closed, agents included. |
| Bug 2: `dev`/`wt` refuse to focus | `hl_classify` (`dot_config/herdr/executable_layout.sh`) returns `malformed` for any pane-count or split-direction change in the agents, runtime or editor tab, and for two tabs sharing a managed label. `hl_reconcile` and `hl_open_worktree` then `die` instead of focusing. One manual split locks the user out of their own workspace through `dev` and `wt`. |
| Bug 3: `dev-topology` tests the deployed copy | It runs `~/.config/herdr/layout.sh`, sources `~/.config/zsh/functions` and calls the deployed `wt-rm`, so it never tests the source tree. It leaves lock files in `~/.local/state/herdr-layout` (30 from test fixtures today). An interrupted run left a `dev.layout.test` plugin registered against a deleted temp directory; it is still listed by `herdr plugin list`. |
| Phase pins | `~/.local/state/herdr-phase/pins` has never existed. `pin`/`unpin` and the `parked` phase are unused. |
| Zellij leftovers | None outside the dated specs (permanent records) and the `.chezmoiremove` tombstone. Nothing to do. |
| Git locks | All 12 live wt worktrees carry the lock reason `wt-managed; remove with command wt-rm`, applied by `dev` when it opens a linked checkout. Gap: `wt` runs the copy and the setup hook before `dev` locks, and a failed setup leaves the worktree unlocked. |
| Named Herdr sessions | None in use: `herdr session list` reports the default session only. The live gate creates and deletes `dev-test`. |
| `.worktreeinclude` | Four manifests in use, all literal file paths: `mise.local.toml` everywhere, plus `config/master.key` in curato. |

**Workspace provenance.** Herdr 0.9.3 reports `worktree.checkout_path` for primary-checkout
workspaces as well as linked ones (18 of the 21 live workspaces carry it; the three without
it predate provenance). Unlike pane cwd, it does not follow `cd`. This design makes it the
identity for both `dev` and `wt-rm`.

## 1. `wt-rm`: close only the checkout's own workspace

Replaces `_wt_herdr_runtime_matches` and the session loop in `_wt_stop_herdr_workspaces`.
Everything else in `wt-rm` keeps its order: hook validation, check 1, Herdr step, check 2,
teardown, check 3, check 4, removal, branch deletion.

**Sessions.** The target sessions are the default session, plus the session named by
`$HERDR_SESSION` when it is set (in practice only the live gate sets it). If
`herdr session list --json` reports any other session, running or stopped, `wt-rm` refuses
and names it. The session-list shape validation stays.

**Per target session:**
- Stopped: the persisted-state check stays as it is. A reference to the checkout, or state
  it cannot read, is a refusal that says how to start the session.
- Running: read the workspace list and the pane list, each validated as today. A running
  session whose API answers `server_not_running` is still a refusal.
- **Own** workspaces: `worktree.checkout_path`, resolved, equals the checkout path. These are
  the only workspaces `wt-rm` ever closes.
- **Foreign** occupancy, which makes `wt-rm` refuse:
  - a pane whose cwd is at or under the checkout, in a workspace that is not own;
  - a workspace whose `checkout_path` is strictly under the checkout (a nested repository).

  The refusal names each one by workspace label, workspace id, pane id and cwd, and says to
  `cd` out or close it, then retry.
- **Self-close**: when `$HERDR_WORKSPACE_ID` is set, `wt-rm` finds the caller's session
  independently of `$HERDR_SESSION`. It is the session whose `socket_path` in the session
  list equals `$HERDR_SOCKET_PATH`, or the default session when that variable is unset or
  matches no listed session. If `$HERDR_WORKSPACE_ID` is an own workspace of the caller's
  session, `wt-rm` refuses with "run wt-rm from another workspace". Closing it would SIGHUP
  the shell running `wt-rm` between the close and the removal.

**Order.** All refusals are decided from reads of every target session before the first
close. Then the own workspaces are closed, and each session is re-read: any remaining own
workspace, or any pane at or under the checkout, is a refusal, as today.

## 2. One process scanner

`wt-teardown` gains a `scan` verb:

```
WT_WORKTREE=<abs-dir> wt-teardown scan
```

It validates `WT_WORKTREE` exactly as `teardown` does, moves to `/`, runs the existing `_scan`
and prints one `<pid> <command>` line per process whose cwd is at or under the directory. It
exits 0 with the list (empty when idle) and 1 when the listing cannot be trusted. It filters
nothing out: an ancestor sitting in the checkout is an occupant from `wt-rm`'s point of view.
`scan` takes no `--pidfile` or `--sweep`; passing either is a usage error, and `scan` never
signals anything.

Check 4 in `wt-rm` becomes `busy="$(WT_WORKTREE="$dest" command wt-teardown scan)" || return 1`,
resolved through PATH, so a missing helper fails closed. `_wt_live_processes` and
`_wt_lsof_render` are deleted from `functions`. The bounds of the scan (other users'
processes, descriptors held from elsewhere, the time window) move into one short comment on
`_scan`, and the full argument stays in the hook-protocol and teardown-helper specs.

## 3. Lock at creation

`_wt_create_or_prepare` creates both kinds of new worktree locked:

```
git worktree add --lock --reason "<reason>" "$dest" "$branch"
git worktree add --lock --reason "<reason>" "$dest" -b "$branch" [start]
```

The reason string stays byte-identical (`wt-managed; remove with command wt-rm`), so the 12
existing locked worktrees are still recognised. `dev`'s `_wt_ensure_herdr_lock` stays, so a
worktree someone unlocked by hand is locked again on the next open. `wt-rm`'s classification
of the lock is unchanged.

## 4. `worktree-guard.sh`: add the lock-crossing shapes

Every wt worktree is now locked from creation, so Git itself refuses a plain
`git worktree remove`, and its error quotes the lock reason, which says to use `wt-rm`. The
lock stops an agent only until it crosses it, and it does not cover a wt worktree Michael
unlocked by hand and has not reopened through `dev`. The guard therefore keeps today's rule
and adds the two shapes that cross a lock.

**Rules.** Any one of these denies:
1. `git worktree unlock`, any target.
2. `git worktree remove` with a force count of two or more, any target. `--force` counts one,
   and a short bundle counts one per `f` (`-f -f`, `-ff`, `-f --force`).
3. Today's sibling rule, unchanged in substance: `git worktree remove` with any force count
   whose literal absolute target exists right now as a wt sibling of a real repository
   (`<parent>/<repo>-<slug>` next to `<parent>/<repo>/.git`). It still extracts the target
   from quotes as it does today.

**Matching.**
- Fast path: no `worktree` in the payload means allow, with no subprocess.
- The command is split into segments by a quote-aware scan. It splits on newlines, `;`,
  `&&`, `||`, `|`, `&` and `(` only outside single and double quotes; outside single quotes a
  backslash escapes the next character. A quoted target such as `"/path/repo-x|y"` therefore
  stays whole, and quoted text never starts a segment of its own. Each segment then goes
  through today's target extraction, quote handling included.
- A segment matches when, after optional `sudo` and `NAME=value` prefixes, it starts with
  `git`, git's global options (`-C <path>`, `-c <k=v>`, `--long[=v]`), then `worktree unlock`
  or `worktree remove`. Every segment is checked; today only the start of the first line is.
- A command hidden inside a quoted string, such as `bash -c "git worktree unlock x"`, is not a
  segment start and is allowed, as today. The guard is a correctness catch, not a security
  boundary; the lock is the boundary.
- `WT_GUARD=off` anywhere in the command still allows. The guard stays bash 3.2
  compatible, and any internal failure allows.

The deny reason names the rule that fired and points to `command wt-rm <branch>`, or to the
owning tool's lifecycle for a harness worktree.

Coverage is a strict superset of today's: rules 1 and 2 catch relative, `-C`-relative and
variable targets that the sibling rule cannot resolve, and every rule now applies to chained
segments. The file gets smaller by cutting comments, not rules. The `PreToolUse` comment in
`dot_claude/modify_private_settings.json` is updated to match.

## 5. `layout.sh`: focus first, add missing tabs

**Deleted:** `hl_classify`, `hl_reconcile`, `hl_repair`, `hl_is_native_worktree_workspace`,
the `--current` mode with `hl_notify`, `hl_die_notify` and `HL_DIE`, the `(building)` label
suffix, and the blank-workspace verification in `hl_adopt_worktree`.

**Kept:** `hl_api`/`hl_api_json`/`hl_id`, server start and readiness, `hl_label` and
`hl_shorten`, the per-repo `hl_lock` with its test hooks (`HL_LOCK_DELAY`, `HL_SCAN_DELAY`,
`HL_TRACE_LOCK`), `hl_make_tab`, `hl_populate_tab`, `hl_ensure_tab`, `hl_attach`,
`MANAGED_TABS=(agents editor runtime)` and `EAGER_TABS=(agents runtime)`.

**Finding a workspace** (`hl_find_workspace <repo>`, under the lock):
1. Workspaces whose resolved `worktree.checkout_path` equals the repo path. One match is the
   answer. With several, take the first in Herdr's order and warn on stderr.
2. If none matched: workspaces that carry no `worktree` field and have a pane whose cwd equals
   the repo path. This fallback exists for workspaces created before provenance. A workspace
   with provenance for another checkout is never adopted through a pane that `cd`'d here.
3. Otherwise there is no workspace.

**Ensuring tabs** (`hl_ensure_eager_tabs <ws> <repo>`): for each label in `EAGER_TABS`, if no
tab carries it, create it with `hl_make_tab`. Tab shapes, pane counts, split directions,
duplicate labels and the workspace label are never inspected, never repaired and never a
reason to refuse. A user's rename of the workspace is kept.

**Path mode** (`layout.sh <repo>`): lock, then find. If found, ensure the tabs and focus. If
not found, build. Then attach.

**Build:** `workspace create --cwd <repo> --label <final-label> --no-focus`, arm the close
trap, populate the root tab as agents (`hl_populate_agents`: rename, split right, run `claude`
and the Codex pane command), create the remaining eager tabs, disarm the trap, focus the
workspace and the agents tab.

**Worktree mode** (`layout.sh --worktree <primary> <checkout>`): the primary check, the lock,
`worktree open` and its response validation (checkout path, linked flag, `already_open`) stay.
- `already_open: false`: arm the close trap, then populate the root tab with
  `hl_populate_agents`, create the remaining eager tabs, disarm, focus.
- `already_open: true`: ensure the tabs, focus.

**`--make-tab <label>`** (alt+e, through `tab-goto.sh --create`): the workspace comes from the
environment as today. Its repo is the workspace's `worktree.checkout_path` if present,
otherwise the first pane's cwd resolved to its git toplevel; outside a git repo it refuses.
Then lock and `hl_ensure_tab`.

## 6. Delete the `dev.layout` plugin

Delete `dot_config/herdr/plugin/` and add `.config/herdr/plugin` to `.chezmoiremove`. Running
`dev .` from any pane does what the plugin's "Apply project layout" action did. Comments in
`functions` and `layout.sh` that name the plugin are updated.

## 7. `phase.sh`: drop pins

Delete `pin`, `unpin`, `pin_file`, `path_of`, the pin branch of `derive`, the `parked` phase
and `ICON_FLAG`. `report` clears `active`, `review` and `merged` only. The two plugin actions
leave `plugin-phase/herdr-plugin.toml`, and the `$parked` token leaves the sidebar rows in
`config.toml`. The derivation order, the MR cache, the startup and event hooks and the
LaunchAgent are unchanged.

## 8. Carry `.worktreeinclude` files with `cp`

`_wt_do_prepare` copies each entry `_wt_manifest` returns with:

```
mkdir -p -- "$dest/${entry:h}" && cp -pR -- "$main/$entry" "$dest/$entry"
```

`_wt_manifest` stays the safety boundary: entries must be repo-relative with no `..` and no
symlink component on either side, and an entry already present at the destination is skipped.
Without `wtcp` there is no `cd` into the new worktree, so the `MISE_NO_ENV` workaround goes. The
first failed copy stops the run with the existing "fix the copy, then: wt-prepare" message.
`-p` keeps `master.key` at mode 600.

The Brewfile loses `brew "satococoa/tap/wtcp"` and `tap "satococoa/tap", trusted: true`. The
`wt-rm` and `wt-prepare` wrapper comments that mention `wtcp` on PATH are corrected. The
"(via wtcp)" comment inside each project's untracked `.worktreeinclude` is cosmetic and out of
scope.

## 9. `dev-topology` tests the source

- `layout.sh` is the source copy, passed through `DEV_LAYOUT` and run directly. It reads
  `codex-pane-command` from beside itself, which exists in the source tree.
- The lifecycle functions are sourced from `dot_config/zsh/functions` in the repo, and
  `wt-rm` is called as that function, not through the deployed wrapper, with
  `HERDR_SESSION="$SESSION"` like every other gate call. Without it, `wt-rm` would refuse
  `dev-test` as an unexpected named session (§1).
- A scratch `bin` directory, first on PATH, links `wt-teardown` to the source copy.
- `XDG_STATE_HOME` points inside the scratch directory, so lock files die with it.
- Section 7, the plugin link and invoke, is deleted. The smart-splits navigation check, which
  uses its own permanently linked plugin, stays as a standalone section.

The suite keeps its `test-requires: unsandboxed, herdr` tag and its `dev-test` session.

## 10. Comments

Comments keep three things: footgun warnings (for example "never name a local `path` in zsh"),
the reason for a non-obvious line, and a pointer to the spec that holds the full argument.
Incident narratives, measurements and design restatements that the dated specs already hold
are cut. The plan puts comment-only cuts in their own commits, separate from logic changes,
so a review can confirm that no code moved.

## 11. Rollout

**Sequencing.** Spec and plan now. The build waits for `xreview-option-b` to merge, then merges
main into this branch, then runs the plan. `AGENTS.md` changes (the `dev-topology` row, if its
wording changes) happen only after that merge.

**Post-apply, one time, run by Michael** (each is listed in the final report):
- `herdr plugin unlink dev.layout`: chezmoi removes the directory, but the registration is
  Herdr's.
- `herdr plugin unlink dev.layout.test`: the stale registration left by an interrupted gate.
- `brew uninstall wtcp && brew untap satococoa/tap`.

`.chezmoiremove` also gains `.local/state/herdr-layout/*dev-live.*` and
`.local/state/herdr-layout/*scratchpad-probe*`. Both match leaked test-fixture lock files
only; no real repository's lock file has either string in its name.

## 12. Testing

Test first, per plan task. All suites run through `./tests/run.sh`, never with an interpreter
prefix, and one full suite at a time.

| Suite | Changes |
|---|---|
| `wt-functions` | Own-workspace-only close; a foreign pane refuses before any close; a nested-provenance workspace refuses; a named session refuses; the `$HERDR_SESSION` target is handled; self-close refuses, including with `$HERDR_SESSION` set (caller session found by `socket_path`); a worktree is locked at creation (both branch forms); check 4 goes through `wt-teardown scan` and fails closed when it fails; `cp` copies, keeps mode 600, skips present entries, and a failure stops prepare; the `wtcp` stubs and cases go. |
| `wt-teardown` | `scan` prints occupants, exits 0 when idle, exits 1 on an untrustworthy listing, rejects `--pidfile` and `--sweep`, and signals nothing. |
| `dev` | A manual split, a changed split direction, a duplicate label and a renamed workspace each still focus; a missing eager tab is added; provenance wins over a pane that `cd`'d in; the fallback adopts only a workspace without provenance; build and fresh-worktree populate are unchanged; `--make-tab` resolves the repo from provenance. The classify, repair and `--current` sections go. |
| `worktree-guard` | Existing sibling cases keep passing, including quoted targets containing separators (`"…-x\|y"`, with and without a trailing `;`). Two allow cases flip to deny by design, because chained segments are now checked: "preceding command" and "removal in a second clause". New: unlock and double-force forms deny for any target (bundled, split, `-C`, `sudo`, env prefix, chained segment); single-force removal of a non-sibling, `prune`, `list`, `add` and `lock` allow; the fast path; `WT_GUARD=off`; jq absent allows. |
| `herdr-phase` | The pin cases go; a check that `report` clears exactly three tokens. |
| `dev-topology` | Runs unsandboxed against the source, per §9. It must leave no new file in `~/.local/state/herdr-layout` and no new plugin registration. |

`claude-settings` keeps passing, since it finds the guard by its command. The final
pre-merge pass runs every suite `./tests/run.sh` selects by default, plus `dev-topology` by
exact name, unsandboxed.

## 13. Risks

- **Provenance missing on a workspace.** `dev` falls back to pane cwd, as today. `wt-rm` never
  closes a workspace without provenance; one with a pane in the checkout makes it refuse. That
  costs a manual close and never a wrong close.
- **A later Herdr renames `worktree.checkout_path`.** Every reader validates the field's type.
  `wt-rm` then finds no own workspace and the foreign-pane rule still refuses for any pane in
  the checkout. `dev-topology` asserts the field against the real binary.
- **A new named session** stops `wt-rm` until it is deleted. That is intended: none exist in
  normal use, and a scan over all of them is the code this design removes.

## Implementation notes

What shipped differs from the sections above in the ways listed here. The dated text above is
left as it was signed off; these notes are the record of each change. The dotfiles have no
MR, so this list is the place the rulings land.

**Deviations and rulings**
- **§1, stopped-session helper.** `_wt_stopped_herdr_has_checkout` built its state path in the
  same `local` line that declared `session_dir`. zsh expands every argument of a `local` line
  before assigning any, so it read the *caller's* `session_dir`. That only worked because the
  old caller happened to use that name. Under the new two-pass loop it would have failed open.
  The fix splits the declaration, a comment warns against re-joining it, and test U22 fails if
  the lines are joined again.
- **§1, tests.** Two assertions mandated by the plan passed whatever the code did, and were
  tightened (U2, U6). U20 and U21 now pin "all refusals before the first close" across a
  second session: a single-pass implementation fails them.
- **§2.** The comment listing the scan's three bounds landed in Task 2's fix round, because no
  task text had assigned it.
- **§4, segment starts.** The guard also treats `do`, `then`, `else`, `elif`, `if`, `while`,
  `until`, `time`, `command`, `!`, `{` and an absolute path before `git` (`/usr/bin/git`) as
  segment starts. §4 named only `sudo` and `NAME=value`. The three rules are unchanged; the
  likeliest way an agent crosses the lock is a `for …; do git worktree remove -ff …; done`
  cleanup loop, and a reasonable reader expects that to be caught.
- **§4, latency.** Spec §4's fast path (`worktree` anywhere in the payload) sent every Bash call
  of a harness-worktree session to the slow path: about 120 ms instead of 8 ms, and seconds on
  long commit messages. The fast path now requires `worktree` followed by whitespace or a
  backslash. A command-level verb check and a per-segment pre-check follow it. A side-by-side
  run of 840 commands shows no input the old guard denied that the new one allows.
- **§4, heredocs and comments.** The scanner treats heredoc bodies and `#` comments as text
  that never starts a segment; §4 named only quoted text. Known remaining false deny: a
  commit-message heredoc inside `"$(cat <<'EOF' …)"` whose body has an odd number of `"` flips
  the quote state, so a later body line starting with `git worktree unlock` is denied. The
  reason it prints is actionable; recorded rather than fixed.
- **§4, not segment starts.** `exec`, `env`, `nohup`, `time -p`, `sudo -u` and quoted
  subcommands (`git work"tree" …`) are not segment starts. The Git lock still refuses those
  removals.
- **§5, provenance on fresh workspaces.** herdr 0.9.3 records no `worktree` provenance on a
  fresh `workspace create --cwd`; only `worktree open` does. The live session's primary
  workspaces carry it (the Baseline's 18 of 21), apparently added later, on restore. So a
  workspace that `dev` has just built is found through the pane-cwd fallback until then.
  Behaviour is correct either way. The live gate accepts either identity and fails when
  neither holds.
- **§5, lock timeout.** Deleting section K removed the only lock-timeout test. It was ported to
  path mode as D10. N7d pins `--make-tab`'s toplevel resolution from a subdirectory pane.
- **§8, partial copy.** A failed `cp -pR` of a directory entry left a partial copy, which the
  prescribed `wt-prepare` recovery then skipped as "already present". On failure the partial
  copy is now removed with `rm -rf` (CP4). Residual: an interrupted copy, or a read-only
  subdirectory that stops the `rm`, can still leave a partial entry.
- **§8, symlinks.** `cp -pR` writes through an existing destination symlink. Unlike `wtcp`, it
  does not refuse existing destinations, so `_wt_manifest`'s present-entry filter is the only
  guard. An end-to-end test (m6) pins it.
- **§9.** Herdr lists a newly split pane directly after the pane it split. The gate therefore
  snapshots the agents panes before the manual split. Three gate checks that could pass
  without testing anything were made to prove their preconditions: the tab close, the split,
  and the plugin listing.

**Not done, by decision:** workspace-id format validation in `_wt_herdr_classify`, comparing
pane cwd unresolved (only provenance is resolved, as §1 asks), and the remaining test-precision
minors. They are recorded in the execution ledger and do not affect behaviour.
