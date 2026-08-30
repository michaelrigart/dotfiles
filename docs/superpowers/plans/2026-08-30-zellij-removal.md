# Zellij Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Approved

**Goal:** Retire Zellij from the dotfiles, leaving Herdr as the only multiplexer and `dev` / `wt` / `wt-prepare` / `wt-rm` as the only worktree lifecycle.

**Architecture:** Delete Zellij's configuration, layout, WASM navigator, socket workaround, Homebrew package and every lifecycle branch that spoke to it; rename the Herdr entry points (`hdev`→`dev`, `hwt`→`wt`, `hwt-prompt`→`wt-prompt`, `HDEV_*`→`DEV_*`) onto the names the Zellij functions held. The zsh functions file is the load-bearing change; everything else is deletion, renaming, or comment text.

**Tech Stack:** zsh (functions + mocked test harness), chezmoi 2.72.1, Herdr 0.8.2, Homebrew, Neovim/Lua, Ghostty.

**Spec:** `docs/superpowers/specs/2026-08-30-zellij-removal-design.md`

## Global Constraints

- **Never hand-edit a deployed dotfile.** Edit the chezmoi source under `~/.local/share/chezmoi`, then `chezmoi apply`.
- **No agent attribution** in commit messages, PR titles or descriptions. No `Co-authored-by`, no session links, no "Generated with".
- **Commit at task boundaries**, imperative mood, small and focused.
- **Lock marker, exact string:** old `hwt-managed; remove with command wt-rm`, new `wt-managed; remove with command wt-rm`. Matched exactly, never by substring.
- **Test runner:** `zsh .scripts/test-wt-functions.sh` and `zsh .scripts/test-dev.sh`. Both must exit 0. **Run them as separate commands** — `test-a; test-b` reports only the last command's exit status, so a failure in the first passes silently. Assertions pin exact values; a test that cannot go red is not coverage.
- **Verification commands must be able to pass.** Three in earlier drafts could not: `grep -ri zellij` (walks `.git`), a sweep including `.chezmoiremove` (whose purpose is to name `.config/zellij`), and a marker gate globbing `~/Code/*/*` (sees 37 of 84 repos). Before writing a check, ask what it returns on a correct tree.
- **Sandbox:** run Bash sandboxed by default. `op` genuinely needs `dangerouslyDisableSandbox` (its config path is denied); so does writing `~/.claude/**`.
- **This work happens in the worktree** `.claude/worktrees/remove-zellij` on branch `worktree-remove-zellij`. A second session owns the main checkout — never `git checkout` there.
- **`chezmoi apply` must run from the canonical source** `~/.local/share/chezmoi`, which this worktree is not. Task 8 is therefore gated on the branch being merged; do not attempt a real apply from the worktree.

---

### Task 1: Collapse the lifecycle onto `dev` / `wt`

**This task is atomic and cannot be split.** An earlier draft made deletion Task 1 and renaming Task 2, with the suite expected green in between. It cannot be: the harness contains 65 `run "$REPO" wt …` calls and 75 `dev`/`wt` invocations in total, so the moment the Zellij `wt()` is deleted and before `hwt` is renamed into its place, the suite is red. The names are mutually entangled — `hdev` cannot become `dev` until the Zellij `dev` is gone — so deletion and renaming are one green-to-green step.

**Files:**
- Modify: `dot_config/zsh/functions` — delete `_wt_session_name()` (109-136), `dev()` (139-238), `wt()` (835-838), the Zellij shutdown block inside `wt-rm()` (1181-1192); rename `hdev()`→`dev()`, `hwt()`→`wt()`, `hwt-prompt()`→`wt-prompt()`, `HDEV_LAYOUT`→`DEV_LAYOUT`, and the `hdev:` message prefixes in `_wt_ensure_herdr_lock` and `_wt_prepare_for_herdr`
- Modify: `dot_config/herdr/executable_layout.sh:474,477` — `HDEV_NO_ATTACH`→`DEV_NO_ATTACH`
- Modify: `dot_config/herdr/config.toml` — the `prefix+shift+g` popup command `hwt-prompt`→`wt-prompt`
- Rename: `.scripts/test-hdev.sh`→`.scripts/test-dev.sh`, `.scripts/test-hdev-topology.sh`→`.scripts/test-dev-topology.sh`, `.scripts/test-hdev-integrations.sh`→`.scripts/test-dev-integrations.sh`
- Modify: `.scripts/test-wt-functions.sh` — stubs (63-76, 107), env (149, 190-199), Zellij `dev` cases (428-463), assertions at 1033-1035, 1121-1138, 1290, 1807, 1852, 1918-1919, 1930, 1946

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `dev()`, `wt()`, `wt-prompt()`; env seams `DEV_LAYOUT`, `DEV_NO_ATTACH`; a `wt-rm` with exactly one multiplexer teardown step (`_wt_stop_herdr_workspaces`).

- [ ] **Step 1: Replace the vacuous failure-order assertions in the test**

Three sites assert `unlogged "delete-session" "Zellij is not disrupted…"`. Zellij was the observable proxy for an ordering guarantee; the guarantee must keep an assertion. At each of lines 1807, 1852, 1930 and 1946, delete the `unlogged "delete-session" …` line and ensure the surrounding block asserts **both**:

```zsh
# Removal is strictly after teardown in wt-rm's sequence, so "teardown never ran"
# proves Git removal was never reached. Registration is the direct observation
# that replaces a bare `-d` check: a directory can survive a *failed* removal,
# but a still-registered worktree proves `git worktree remove` did not succeed.
[[ -f "$REPO/herdr-close-teardown-ran" ]] && _fail "teardown is skipped after a Herdr close failure" \
                                                  || _pass "teardown is skipped after a Herdr close failure"
run "$REPO" git worktree list --porcelain
has "$HFAIL" "the checkout is still a registered worktree after a Herdr close failure"
```

Adapt the path variable (`$HFAIL`, `$PROTECTED`, …) and the message to each site. Where a site already has the teardown assertion, keep it and add only the registration one.

- [ ] **Step 2: Run the test to see the new assertions pass against unchanged code**

Run: `zsh .scripts/test-wt-functions.sh`
Expected: PASS. The code has not changed yet, so this proves the replacements are correct assertions about current behaviour before anything is deleted — not that they accidentally encode the post-change state.

- [ ] **Step 3: Delete the Zellij `dev` regression tests**

Delete lines 428-463 of `.scripts/test-wt-functions.sh` — the two 2026-08-25 regression guards (`switch-session`/`new-tab` and the `go-to-tab-name` close-tab bug) and the `MOCK_ZJ_SWITCH_RC=1` failure case. They test a function this task deletes.

- [ ] **Step 4: Delete the zellij stub and its mock state**

In `.scripts/test-wt-functions.sh`:
- delete the `cat > "$STUBS/zellij" <<'STUB' … STUB` block (63-76)
- change line 107 from `chmod +x "$STUBS/zellij" "$STUBS/wtcp"` to `chmod +x "$STUBS/wtcp"`
- in `setup()`, drop `ZLOG` from the export at 190 and the `: > "$ZLOG";` at 192
- drop `MOCK_ZJ_SESSIONS`, `MOCK_ZJ_ATTACH_RC`, `MOCK_ZJ_NEWTAB_RC`, `MOCK_ZJ_SWITCH_RC`, `MOCK_ZJ_DELETE_RC`, `MOCK_ZJ_DELETE_TOUCH` from the export at 194-199
- delete `unset ZELLIJ` (199)
- delete any remaining `export MOCK_ZJ_SESSIONS=…` in individual cases (e.g. inside the `herdr-fail` block at ~1845)

Then delete the three `[[ -s "$ZLOG" ]]` assertions at 1033-1035 and 1121-1138 and the `MOCK_ZJ_DELETE_TOUCH` fixture at ~1290. These assert "prepare makes no Zellij calls" — with no Zellij to call, they are unfalsifiable.

- [ ] **Step 5: Rename in the test files**

```bash
git mv .scripts/test-hdev.sh .scripts/test-dev.sh
git mv .scripts/test-hdev-topology.sh .scripts/test-dev-topology.sh
git mv .scripts/test-hdev-integrations.sh .scripts/test-dev-integrations.sh
```

Then in all three plus `.scripts/test-wt-functions.sh`, replace whole words only: `hdev`→`dev`, `hwt-prompt`→`wt-prompt`, `hwt`→`wt`, `HDEV_LAYOUT`→`DEV_LAYOUT` (including the `export` at `test-wt-functions.sh:149`), `HDEV_NO_ATTACH`→`DEV_NO_ATTACH`.

**`test-dev-integrations.sh` is in this list because line 64 passes `HDEV_NO_ATTACH=1`** — the rename touches it even though it otherwise covers hook wiring this change does not affect.

Two hazards. `test-dev.sh:880` asserts `edit_scrollback = "alt+s"` under the comment "Alt-s retains the Zellij scrollback mnemonic" — reword the comment, do not touch the assertion. And a blind `hwt`→`wt` also rewrites `$HWT` fixture variables; rename those deliberately rather than ending up with two names for one variable.

- [ ] **Step 6: Run both suites to verify they fail**

Run each as its own command — **never `test-a; test-b`**, which reports the exit status of the last command only and would hide a failure in the first:

```bash
zsh .scripts/test-wt-functions.sh
zsh .scripts/test-dev.sh
```

Expected: FAIL, both. The tests now call `dev`/`wt`, which still resolve to the Zellij functions that call the now-absent `zellij` stub.

- [ ] **Step 7: Delete the Zellij code and rename the Herdr entry points, in one edit**

In `dot_config/zsh/functions`:
- delete `_wt_session_name()` and its comment block (109-136)
- delete `dev()` and its comment block (139-238)
- delete `wt()` (835-838) — the four-line Zellij wrapper, **not** `_wt_create_or_prepare` above it
- inside `wt-rm()`, delete the Zellij shutdown block (1181-1192), from the `# Stop the Zellij session.` comment through the closing `}` of the `if` — leaving `_wt_stop_herdr_workspaces "$dest" || return 1` as the sole shutdown step

Then fix `wt-rm`'s own header comment (1079-1103): step 3 in the numbered sequence says "Stop the Zellij session"; it becomes "Stop every matching Herdr workspace". Keep the invariant sentence — "a live process holding the directory open is exactly how an empty tmp/ husk is left behind" — it is the reason the ordering exists.

**In the same edit**, rename the survivors:
- `hdev()`→`dev()`, `hwt()`→`wt()`, `hwt-prompt()`→`wt-prompt()`
- `${HDEV_LAYOUT:-$HOME/.config/herdr/layout.sh}` (293, 297) → `${DEV_LAYOUT:-…}`
- the `hdev:` error prefixes in the renamed `dev()`, `_wt_ensure_herdr_lock` and `_wt_prepare_for_herdr` → `dev:`
- `wt-prompt`'s body calls `hwt` → `wt`
- `usage: hwt <branch>` → `usage: wt <branch> [start-point]`, matching `_wt_create_or_prepare`'s own usage line

Update the renamed `dev()`'s header comment: it says "The Herdr-side counterpart to `dev`, running beside it during the trial; `dev` is unchanged", which is now self-referential nonsense. Replace with a plain description of the cascade and **keep** the note that resolution is all it does — "Everything about Herdr lives in layout.sh, which is also what the `dev.layout.apply` plugin action calls — one topology definition, two entry points."

Also record the retired input form there: the Zellij `dev` accepted `dev netronix--curato` (a session name); the new `dev` does not, and such an argument now falls through to the `fzf` picker.

- [ ] **Step 8: Rename in the two remaining source files**

In `dot_config/herdr/executable_layout.sh`, rename `HDEV_NO_ATTACH` at 474 (comment) and 477 (the test).

In `dot_config/herdr/config.toml`, change the `prefix+shift+g` popup command from `hwt-prompt` to `wt-prompt`. **This binding breaks silently if missed** — the popup would open and fail to find the command.

- [ ] **Step 9: Run both suites to verify they pass**

```bash
zsh .scripts/test-wt-functions.sh
zsh .scripts/test-dev.sh
```

Expected: PASS, both. Separate commands, for the reason in Step 6.

- [ ] **Step 10: Verify no `hdev`/`hwt` identifier survives outside the design records**

Run: `git grep -nE '\b(hdev|hwt|HDEV_)' -- ':!docs'`
Expected: no output.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "Collapse the worktree lifecycle onto dev and wt

Delete the Zellij dev, wt and wt-rm shutdown path, and rename the Herdr
entry points onto the names they held. wt-prepare and wt-rm were already
unprefixed and already covered both paths.

The failure-order assertions that used Zellij as their observable become
teardown-not-run plus still-registered, which a bare directory check
could not prove."
```

---

### Task 2: Change the ownership lock marker to `wt-managed`

**Files:**
- Modify: `dot_config/zsh/functions:414-416` — `_wt_herdr_lock_reason()`
- Modify: `.scripts/test-wt-functions.sh` — the `locked hwt-managed` assertion at ~1782 and any other literal
- Modify: `.scripts/test-dev-topology.sh:148` — the live lock-reason comparison

**Interfaces:**
- Consumes: Task 1's renamed functions.
- Produces: `_wt_herdr_lock_reason()` returning `wt-managed; remove with command wt-rm`.

- [ ] **Step 1: Run the marker gate — a hard gate, and the first of two runs**

```zsh
emulate -L zsh
setopt local_options null_glob extended_glob
want="hwt-managed; remove with command wt-rm"
typeset -A seen; typeset -a hits
for g in ~/Code/**/.git(N/) ~/Code/**/.git(N.); do
  common="$(git -C "${g:h}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
  [[ -n "${seen[$common]:-}" ]] && continue
  seen[$common]=1
  cur=""
  while IFS= read -r -d '' rec; do
    case "$rec" in
      "worktree "*)   cur="${rec#worktree }" ;;
      "locked $want") hits+=( "$cur" ) ;;
    esac
  done < <(git -C "${g:h}" worktree list --porcelain -z 2>/dev/null)
done
(( ${#hits} )) && print -rl -u2 -- "STALE MARKER:" ${(u)hits}
```

Expected: no output.

**The glob must recurse — do not simplify it.** An earlier draft used `~/Code/*/*/.git`, on the strength of the documented `~/Code/<Org>/<repo>` convention. The tree actually holds 84 Git entries and that glob sees 37. A safety gate blind to more than half of what it guards is worse than none, because it reports clean with authority. Enumerating by unique **common directory** also stops linked worktrees being counted as separate repositories, and tracking `cur` across records is what makes a hit name the worktree to retire rather than just the repo containing it.

**Any hit aborts this task.** Retire that worktree with the current `command wt-rm` — which still understands the old marker — and only then proceed. Editing the marker with a stale lock outstanding leaves `wt-rm` treating it as a foreign lock and refusing, so the checkout becomes removable only by hand.

This gate runs again in Task 8, immediately before the apply. Both runs are required; see the spec's §"Behaviour changes" for why one is not enough.

- [ ] **Step 2: Update the test's expected marker**

In `.scripts/test-wt-functions.sh`, the assertion that ordinary creation now locks (rewritten in this task's Step 4) and every other literal `hwt-managed` becomes `wt-managed`. In `.scripts/test-dev-topology.sh:148`, the live comparison `"$lock_reason" == "hwt-managed; remove with command wt-rm"` becomes `"wt-managed; remove with command wt-rm"`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `zsh .scripts/test-wt-functions.sh`
Expected: FAIL — the source still emits `hwt-managed`.

- [ ] **Step 4: Change the marker and replace the obsolete unlocked-`wt` test**

In `dot_config/zsh/functions`:

```zsh
_wt_herdr_lock_reason() {
  print -r -- "wt-managed; remove with command wt-rm"
}
```

The old test at ~1779-1783 asserted the opposite of the new behaviour:

```zsh
# wt remains a Zellij-only flow and must not acquire the Herdr ownership lock.
setup
run "$REPO" wt zellij-only
run "$REPO" git worktree list --porcelain
hasnt "locked hwt-managed" "ordinary wt keeps its existing unlocked Git semantics"
```

Replace it with its inverse — there is now one creation path and it always locks:

```zsh
# There is one creation path now, and it always takes ownership: wt-rm is the only
# supported removal route, so a wt worktree that were left unlocked could be removed
# by a raw `git worktree remove` that skips teardown entirely.
setup
run "$REPO" wt locked-by-default
run "$REPO" git worktree list --porcelain
has "locked wt-managed; remove with command wt-rm" "wt takes lifecycle ownership of every checkout it creates"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `zsh .scripts/test-wt-functions.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh .scripts/test-dev-topology.sh
git commit -m "Rename the worktree ownership marker to wt-managed

One creation path means every wt checkout is locked and wt-rm is the only
supported removal route. Verified no worktree carries the old marker
before changing it."
```

---

### Task 3: Remove the wrapper preflight and `ZELLIJ_SOCKET_DIR`

The one deletion that removes a safety check. The property it guarded — an unreachable multiplexer misread as "no session running", leading to removal while processes still hold the directory — is already reimplemented for Herdr inside `_wt_stop_herdr_workspaces`, which fails closed on an API-level `server_not_running` from a session `session list` just called running.

**Files:**
- Modify: `dot_local/bin/executable_wt-rm` — the preflight (38-68) and the zshenv comment (19)
- Modify: `dot_config/zsh/zshenv:29-34` — `ZELLIJ_SOCKET_DIR`
- Modify: `.scripts/test-wt-functions.sh` — section R (1556-1651), the fixture at 1504-1510, section S's comment at ~1661

**Interfaces:**
- Consumes: Task 2's functions.
- Produces: a wrapper whose only responsibilities are sourcing, the recursion guard, and dispatch.

- [ ] **Step 1: Delete section R and its fixture**

In `.scripts/test-wt-functions.sh`:
- delete section R entirely (1556-1651), from the `# --- zellij-unreachable preflight` banner to just before the `# --- \`command\` defeats function shadowing` banner
- delete the two `ZELLIJ_SOCKET_DIR` fixture lines at 1509-1510 and rewrite the comment at 1504-1508, which exists only to explain them
- in section S's comment (~1661), "never runs the zellij-unreachable preflight proven above in section R" becomes a reference to the dispatch the wrapper still performs. The section's actual subject — `command` defeating function shadowing — is unchanged and still valuable; only its example is stale.

- [ ] **Step 2: Run the test to verify it still passes**

Run: `zsh .scripts/test-wt-functions.sh`
Expected: PASS. Deleting tests cannot fail; this confirms nothing else depended on the fixture.

- [ ] **Step 3: Delete the preflight from the wrapper**

In `dot_local/bin/executable_wt-rm`, delete the whole `# Preflight: is zellij actually reachable…` block through its closing `fi` (38-68), leaving `wt-rm "$@"` as the last statement. Then fix the zshenv comment at 19: "without it a bare zsh has no XDG variables, no wtcp or zellij on PATH, and no ZELLIJ_SOCKET_DIR — which wt-rm needs to find the session it must stop" becomes a statement about `wtcp` and `herdr` on PATH.

- [ ] **Step 4: Delete `ZELLIJ_SOCKET_DIR`**

In `dot_config/zsh/zshenv`, delete lines 29-34 — the comment block and the export.

- [ ] **Step 5: Run the test to verify it passes**

Run: `zsh .scripts/test-wt-functions.sh`
Expected: PASS, including sections that dispatch through the wrapper.

- [ ] **Step 6: Commit**

```bash
git add dot_local/bin/executable_wt-rm dot_config/zsh/zshenv .scripts/test-wt-functions.sh
git commit -m "Drop the zellij-unreachable preflight and socket workaround

The property it guarded is already enforced for Herdr inside
_wt_stop_herdr_workspaces, which fails closed when a session that
session list reports running answers server_not_running."
```

---

### Task 4: Retire the Zellij configuration artifacts

**Files:**
- Delete: `dot_config/zellij/config.kdl.tmpl`, `dot_config/zellij/layouts/dev.kdl`
- Delete: `.chezmoiexternal.toml`
- Create: `.chezmoiremove`
- Modify: `dot_config/homebrew/Brewfile.tmpl:58,86`
- Modify: `CLAUDE.md` — the file-structure tree, if it names `dot_config/zellij`

**Interfaces:**
- Consumes: nothing.
- Produces: a source tree with no Zellij artifacts and a removal tombstone for the deployed one.

- [ ] **Step 1: Delete the Zellij source tree and external**

```bash
git rm -r dot_config/zellij
git rm .chezmoiexternal.toml
```

`.chezmoiexternal.toml`'s only entry is the `vim-zellij-navigator` WASM, so the file goes rather than the stanza.

- [ ] **Step 2: Create the removal tombstone**

```bash
cat > .chezmoiremove <<'EOF'
# Targets chezmoi removes from $HOME. chezmoi acts on these only while this file
# exists, so entries stay permanently — a removal entry is a tombstone, not stale
# configuration. Removing an absent path is a no-op.

# Zellij, retired 2026-08-30. Removes the config, the dev layout and the
# vim-zellij-navigator WASM that .chezmoiexternal.toml used to fetch beneath it.
.config/zellij
EOF
```

- [ ] **Step 3: Edit the Brewfile**

Delete `brew "zellij"` (86). Then fix the stale comment on the surviving herdr line (58), which reads `# agent multiplexer; the hdev() function in zsh/functions + ~/.config/herdr. On trial alongside zellij` — both halves are now wrong:

```ruby
brew "herdr"                           # agent multiplexer; the dev() function in zsh/functions + ~/.config/herdr
```

- [ ] **Step 4: Verify the Brewfile template still renders**

Run: `chezmoi --source . cat ~/.config/homebrew/Brewfile | grep -c zellij`
Expected: `0`. If the command errors on config-template drift, add `--no-tty`; a rendering failure here is a real problem, a warning about the config file is not.

- [ ] **Step 5: Update CLAUDE.md's file-structure tree if it lists zellij**

Run: `grep -n zellij CLAUDE.md`
If there are hits in the ASCII tree, remove those lines. If there are none, skip — do not invent edits.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Delete the Zellij configuration, layout and WASM navigator

.chezmoiremove takes the deployed tree; it stays in the source, because
chezmoi acts on the entry only while the file exists."
```

---

### Task 5: Update the stale comments, and verify `cmd+k` still clears

Comment text everywhere except one live assertion.

**Files:**
- Modify: `dot_config/ghostty/config:35,71-72`
- Modify: `dot_zshrc:10-13`
- Modify: `dot_config/zsh/config:97-98`
- Modify: `dot_config/nvim/lua/plugins/smart-splits.lua:1-4`
- Modify: `dot_config/herdr/config.toml:8,32,46,105`
- Modify: `dot_config/herdr/executable_layout.sh:51`

**Interfaces:** none — no behaviour changes.

- [ ] **Step 1: Verify `cmd+k` clears inside a Herdr pane before rewording its comment**

This is the one comment whose replacement text makes a factual claim. In a Herdr shell pane, type some output, press `cmd+k`, and confirm the screen clears.

The mechanism: Ghostty maps `cmd+k`→`text:\x1bk`; Herdr binds no `alt+k` (deliberately — 0.8.2's `pane.*` API has no clear method), so it falls through to `bindkey '\ek' clear-screen` from `dot_zshrc`.

If it does **not** clear, stop and report rather than writing a comment that claims it does. The fallback is to describe only what is verified.

- [ ] **Step 2: Rewrite the comments**

`dot_config/ghostty/config:35` — "left Option = Alt (Zellij/shell shortcuts)" → "(Herdr/shell shortcuts)". Keep the AZERTY rationale verbatim; it is the reason for `left` and has nothing to do with the multiplexer.

`dot_config/ghostty/config:71-72` — replace the Zellij explanation with what Step 1 verified: Herdr binds no `alt+k`, so the chord reaches zsh's `clear-screen` binding. Keep "Works in and out of" the multiplexer if Step 1 confirmed both.

`dot_zshrc:10-13` — same substitution; the binding itself is unchanged.

`dot_config/zsh/config:97-98` — "Ctrl-s is no longer a Zellij leader (clear-defaults)" → Herdr's prefix is `ctrl+b` and it does not claim `ctrl+s`. The `stty -ixon` line stays.

`dot_config/nvim/lua/plugins/smart-splits.lua:1-4` — the header describes both multiplexers; drop the `vim-zellij-navigator` sentence, keep the Herdr description and the `:verbose map <C-h>` verification note.

`dot_config/herdr/config.toml` — line 8 "mirrors the Zellij setup it runs beside", line 32 "Alt-q is the Zellij quit mnemonic", line 46 "Unlike Zellij's stock Ctrl leaders", line 105 "better than Zellij's floating layer". These are comparative rationale for choices that remain correct. Rewrite as statements about Herdr rather than deleting the reasoning.

`dot_config/herdr/executable_layout.sh:51` — "Zellij shape returned 0 from every step while the layout silently failed" is a historical justification for checking output rather than exit status. Keep the lesson, drop the name: "a previous shape returned 0 from every step while the layout silently failed".

- [ ] **Step 3: Verify no Zellij reference survives outside the design records**

```bash
git grep -i zellij -- ':!docs' ':!.chezmoiremove'   # expected: no output
grep -c '^\.config/zellij$' .chezmoiremove          # expected: 1
```

Two exclusions, both load-bearing. `.chezmoiremove` exists precisely to name `.config/zellij`, so a zero-hit sweep including it can never pass — hence the positive assertion of its exact tombstone entry instead. And do **not** substitute `grep -ri zellij`: it walks `.git` and matches ref and reflog metadata, including this branch's own name. Both variants report a failure that is not one.

- [ ] **Step 4: Run both suites**

Separate commands, never `test-a; test-b` — that reports only the last command's status and would hide a failure in the first:

```bash
zsh .scripts/test-wt-functions.sh
zsh .scripts/test-dev.sh
```

Expected: PASS, both. `test-dev.sh` asserts on `herdr/config.toml` content, so a careless comment edit there can go red.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Update the comments that named Zellij

Comment text only. cmd+k still clears in a Herdr pane: Herdr binds no
alt+k, so the chord reaches zsh's clear-screen binding."
```

---

### Task 6: Record the outcome on the Herdr trial spec

**Files:**
- Modify: `docs/superpowers/specs/2026-08-27-herdr-trial-design.md` — the header block

**Interfaces:** none.

- [ ] **Step 1: Add the outcome note**

Below the existing `**Status:**` and `**Amended:**` lines, add:

```markdown
**Outcome, 2026-08-30:** migrated. Zellij is removed — see
[Zellij removal](./2026-08-30-zellij-removal-design.md). The four-week window in
"Exit criteria" was ended after three days by decision, not by measuring the criteria;
none of them were formally evaluated. The removal spec records the reasoning.
```

**Status stays `Implemented`** — the trial was implemented. This is not `Superseded`: the removal follows the trial rather than replacing its design.

Note this file may carry an unrelated uncommitted amendment in the main checkout (a cross-review-broker pointer under "Non-goals"). If the branches have diverged there, keep both edits — they touch different sections.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-08-27-herdr-trial-design.md
git commit -m "Record the Herdr trial outcome as migrated"
```
---

### Task 7: Land the branch

Ends at a merged branch. Nothing is deployed yet — activation is Task 8, and the split is deliberate: publishing before deploying is the ordering defect this structure exists to prevent.

**Files:**
- Modify: `docs/superpowers/specs/2026-08-30-zellij-removal-design.md`, `docs/superpowers/plans/2026-08-30-zellij-removal.md` — status lines

**Interfaces:**
- Consumes: Tasks 1-6 complete and both suites green.
- Produces: the merge commit on `main`.

- [ ] **Step 1: Mark the design records implemented — before merging, not after**

Set `**Status:** Implemented` with the PR reference on both the spec and this plan, then commit. The design-records policy makes this the **final pre-merge commit**, so it lands with the implementation. An earlier draft of this plan merged first and set the status afterwards, which inverts the policy and leaves `main` briefly carrying an `Approved` spec for shipped code.

```bash
git add docs/superpowers/specs/2026-08-30-zellij-removal-design.md docs/superpowers/plans/2026-08-30-zellij-removal.md
git commit -m "Mark the Zellij removal design and plan implemented"
```

- [ ] **Step 2: Open the PR**

Check for a template first: `.github/pull_request_template.md`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/PULL_REQUEST_TEMPLATE/*.md`, the repo root, `docs/`. If none fits, use a short *what / why / how to verify*. No agent attribution anywhere in the title or body.

Use `gh pr create --body-file <file>` — the CLI does not expand a template from a `--body` flag, so render the filled-in text yourself.

- [ ] **Step 3: Get explicit merge approval, then merge**

Merging is the owner's call, not an automated step. Ask, then merge on a yes.

- [ ] **Step 4: Wait for the canonical checkout to contain the merge**

**This is a real gate, and it is the owner's action.** Merging a PR updates the remote; it does not update `~/.local/share/chezmoi`, which is presently on `feat/cross-review-broker` with unrelated uncommitted work belonging to another session. Task 8 applies from that checkout, so it cannot start until someone has safely brought it to the merged `main` without disturbing that session's work.

Confirm before proceeding:

```bash
git -C ~/.local/share/chezmoi rev-parse --abbrev-ref HEAD   # expected: main
git -C ~/.local/share/chezmoi log --oneline -1              # expected: the merge commit
git -C ~/.local/share/chezmoi status --short                # expected: no unexpected changes
```

---

### Task 8: Activate — gates, apply, verify, uninstall

Everything here runs from `~/.local/share/chezmoi`, not this worktree.

**Files:** none modified.

**Interfaces:**
- Consumes: Task 7's merge, present in the canonical checkout.
- Produces: a machine with no Zellij.

- [ ] **Step 1: Re-run the marker gate**

Run the recursive scan from the spec's §"Behaviour changes", with `want="hwt-managed; remove with command wt-rm"`.

Expected: `clean`. **This is the second required run, and it is not ceremony.** Until this apply, the deployed `~/.config/zsh/functions` still carries the old code, so ordinary use during review — in another session, on another day — can have created a fresh worktree bearing the old marker. Applying over it strands exactly the checkout the gate protects. Any hit aborts: retire it with `command wt-rm` while the deployed code still understands the old marker.

- [ ] **Step 2: Re-check Zellij runtime state**

```bash
pgrep -l zellij            # expected: no output
zellij list-sessions       # expected: "No active zellij sessions found."
ls -d /tmp/zellij-$UID     # expected: No such file or directory
```

These were confirmed on 2026-08-30 and nothing maintains them. A live session at apply time is the one way this removal can interrupt work.

- [ ] **Step 3: Dry-run the apply**

Run: `chezmoi apply --dry-run --verbose`

Expected: `~/.config/zellij` removed; `~/.config/zsh/functions`, `~/.zshrc`, `~/.config/zsh/zshenv`, `~/.config/ghostty/config`, `~/.config/herdr/*`, `~/.local/bin/wt-rm`, `~/.config/homebrew/Brewfile` updated. Read this rather than skim it — a target chezmoi will prompt about because it was modified shows up here.

- [ ] **Step 4: Apply**

**Needs an unsandboxed shell with `op` signed in and the 1Password desktop app approved** — a full apply renders the `op`-backed templates under `private_dot_ssh/` and `dot_config/bundler/config.tmpl`. Without it the apply fails partway, having already removed some targets.

Run: `chezmoi apply`
Then: `ls ~/.config/zellij` → expected "No such file or directory".

- [ ] **Step 5: Run the mocked suites**

Separate commands, never `test-a; test-b`:

```bash
zsh .scripts/test-wt-functions.sh
zsh .scripts/test-dev.sh
```

Expected: PASS, both. They read the repo source rather than the deployed copy, but running them here catches a merge that lost something.

- [ ] **Step 6: Run the live topology gate**

Run: `zsh .scripts/test-dev-topology.sh`

Expected: PASS. It exercises `wt` creation, the new lock marker and label-resolved tab jumps against the real binary — all three change here — inside its own named session and scratch repos. **The live `dev` / `wt` / `wt-rm` round trip runs inside this fixture**, not against a real project under `~/Code`.

- [ ] **Step 7: Syntax-check the integrations script**

Run: `zsh -n .scripts/test-dev-integrations.sh`
Expected: no syntax errors. **Stop there.**

An earlier draft also said to "run it far enough" to exercise `DEV_NO_ATTACH`. Don't: partial execution of this script starts real agents against real `~/.claude` and `~/.codex`, and a run truncated by hand is not reproducible. Step 6 already exercises the same control in seven places against the real binary, which is stronger evidence than a partial run of a script whose subject is something else.

- [ ] **Step 8: Uninstall the Zellij binary**

```bash
brew uninstall zellij
```

Expected: removes 0.45.1. Step 2 already established nothing is running.

- [ ] **Step 9: Final sweep**

```bash
git grep -i zellij -- ':!docs' ':!.chezmoiremove'   # expected: no output
grep -c '^\.config/zellij$' .chezmoiremove          # expected: 1
which zellij                                        # expected: not found
ls ~/.config/zellij                                 # expected: No such file or directory
```

**`.chezmoiremove` must be excluded from the zero-hit sweep and asserted positively instead.** Its whole purpose is to name `.config/zellij`, so including it makes the sweep unpassable — the same defect as the `grep -ri zellij` an earlier draft specified, which walks `.git` and matches this branch's own name.

Then open a new shell and confirm `which dev` and `which wt` resolve to the new functions.

---

### Task 9: Publish GLOBAL.md — last

Four statements go stale. **This runs after the apply, not before.** `op-edit` re-applies its chezmoi targets as part of editing, so doing this earlier would publish instructions describing a Herdr-only lifecycle — including "agents do not create these worktrees because `wt` attaches a Herdr client" — while the deployed `wt` was still the Zellij one. It is also the only task `git revert` cannot undo.

**Files:**
- Modify: `op://Private/Agent instructions/notes` via `op-edit`

**Interfaces:**
- Consumes: Task 8's deployed behaviour.
- Produces: instruction text matching the running lifecycle, rendered to `~/.config/agents/GLOBAL.md`, `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.

- [ ] **Step 1: Make the four edits**

Run `op-edit` (needs `dangerouslyDisableSandbox` — `op`'s config path is a denied credential — and a 1Password desktop approval).

1. "in its own Zellij dev session" → "in its own Herdr worktree workspace"
2. "Raw removal skips the Zellij session shutdown and the project teardown hook" → "skips the Herdr workspace shutdown and the project teardown hook"
3. "for `wt-rm` that also bypasses the zellij safety preflight, which lives only in that wrapper" → this change **deletes** that preflight, so the clause goes. **Keep the surrounding rule**: invoke as `command wt-rm` / `command wt-prepare`, because a shell function of the same name shadows the `$PATH` wrapper.
4. "Agents do not create `wt`-managed sibling worktrees — that stays an interactive command, because `wt` attaches to a Zellij session." → "…because `wt` attaches a Herdr client."

**The rule in (4) must survive.** Deleting it along with the word "Zellij" would silently license agents to create interactive worktrees. The paragraph's carve-out for native and harness worktrees is unaffected.

- [ ] **Step 2: Verify all three rendered copies**

```bash
grep -c -i zellij ~/.config/agents/GLOBAL.md ~/.claude/CLAUDE.md ~/.codex/AGENTS.md
grep -n "Agents do not create" ~/.config/agents/GLOBAL.md
grep -n "command wt-rm" ~/.config/agents/GLOBAL.md
```

Expected: `0` for all three files; the agents rule still present; the `command wt-rm` invocation rule still present.

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: Deleted → 1, 3, 4; Renamed → 1; Behaviour change 1 (lock) → 2; Behaviour change 2 (`dev <session-name>`) → 1, where deleting the Zellij `dev` and inheriting `hdev`'s cascade is what retires it, recorded in the renamed function's header comment; Comment-only → 5; Out of repo → 4 (`.chezmoiremove`, Brewfile), 8 (apply, uninstall), 9 (GLOBAL.md); Activation order → 7, 8, 9; Design records → 6, 7; Testing → the test steps throughout plus 8.

**Defects found and fixed in review.** Deletion and renaming were two tasks with a green suite expected between them; they cannot be, because 65 `run "$REPO" wt …` calls go red the moment `wt()` is deleted — now one atomic task. The marker gate globbed `~/Code/*/*/.git`, which sees 37 of 84 Git entries — now recursive, deduplicated by common directory, reporting the worktree path, and run twice. The final sweep included `.chezmoiremove`, which necessarily names `.config/zellij` — now excluded and asserted positively. GLOBAL.md published before the apply, and the status commit landed after the merge — both reordered.

**Ordering.** Task 2's gate runs immediately before its own edit and again in Task 8; a design-time observation authorises nothing. Task 3 deletes `ZELLIJ_SOCKET_DIR` and the wrapper preflight together because the preflight reads the variable. Tasks 7-9 are separate because landing, activating and publishing are separate events, and doing them in the wrong order publishes instructions for behaviour that is not yet running.

**Naming consistency.** `DEV_LAYOUT` and `DEV_NO_ATTACH` appear identically in Tasks 1, 5 and 8. The lock reason `wt-managed; remove with command wt-rm` appears identically in Task 2 and in the spec's rollback scan; the old `hwt-managed; …` appears only in the two gate runs.
