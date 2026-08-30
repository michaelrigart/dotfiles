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
- **Test runner:** `zsh .scripts/test-wt-functions.sh` and `zsh .scripts/test-dev.sh`. Both must exit 0. Assertions pin exact values — a test that cannot go red is not coverage.
- **Sandbox:** run Bash sandboxed by default. `op` genuinely needs `dangerouslyDisableSandbox` (its config path is denied); so does writing `~/.claude/**`.
- **This work happens in the worktree** `.claude/worktrees/remove-zellij` on branch `worktree-remove-zellij`. A second session owns the main checkout — never `git checkout` there.
- **`chezmoi apply` must run from the canonical source** `~/.local/share/chezmoi`, which this worktree is not. Task 9 is therefore gated on the branch being merged; do not attempt a real apply from the worktree.

---

### Task 1: Delete the Zellij `dev` and `wt`, and the Zellij branch of `wt-rm`

Removes the Zellij code paths while leaving `hdev`/`hwt` under their trial names. Renaming is Task 2 — splitting them keeps each diff reviewable.

**Files:**
- Modify: `dot_config/zsh/functions` — delete `_wt_session_name()` (109-136), `dev()` (139-238), `wt()` (835-838); delete the Zellij shutdown block inside `wt-rm()` (1181-1192)
- Modify: `.scripts/test-wt-functions.sh` — stubs (63-76, 107), env (190-199), Zellij `dev` cases (428-463), assertions at 1033-1035, 1121-1138, 1290, 1807, 1852, 1918-1919, 1930, 1946

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: a functions file where `hdev`/`hwt`/`hwt-prompt` are the only entry points and `wt-rm` has exactly one multiplexer teardown step (`_wt_stop_herdr_workspaces`).

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

- [ ] **Step 5: Run the test to verify it fails**

Run: `zsh .scripts/test-wt-functions.sh`
Expected: FAIL — `dev`, `wt` and `wt-rm` still call `zellij`, which is no longer on the stub PATH. Errors will name `zellij: command not found`.

- [ ] **Step 6: Delete the Zellij code from the functions file**

In `dot_config/zsh/functions`:
- delete `_wt_session_name()` and its comment block (109-136)
- delete `dev()` and its comment block (139-238)
- delete `wt()` (835-838) — the four-line Zellij wrapper, **not** `_wt_create_or_prepare` above it
- inside `wt-rm()`, delete the Zellij shutdown block (1181-1192), from the `# Stop the Zellij session.` comment through the closing `}` of the `if` — leaving `_wt_stop_herdr_workspaces "$dest" || return 1` as the sole shutdown step

Then fix `wt-rm`'s own header comment (1079-1103): step 3 in the numbered sequence says "Stop the Zellij session"; it becomes "Stop every matching Herdr workspace". Keep the invariant sentence — "a live process holding the directory open is exactly how an empty tmp/ husk is left behind" — it is the reason the ordering exists.

- [ ] **Step 7: Run the test to verify it passes**

Run: `zsh .scripts/test-wt-functions.sh`
Expected: PASS, all sections.

- [ ] **Step 8: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "Delete the Zellij dev, wt and wt-rm shutdown path

wt-rm keeps one multiplexer teardown step. The failure-order assertions
that used Zellij as their observable move to teardown-not-run plus
still-registered, which a bare directory check could not prove."
```

---

### Task 2: Rename the Herdr entry points onto `dev` / `wt`

**Files:**
- Modify: `dot_config/zsh/functions` — `hdev()`→`dev()`, `hwt()`→`wt()`, `hwt-prompt()`→`wt-prompt()`, `HDEV_LAYOUT`→`DEV_LAYOUT`, and the `hdev:` message prefixes in `_wt_ensure_herdr_lock` and `_wt_prepare_for_herdr`
- Modify: `dot_config/herdr/executable_layout.sh:474,477` — `HDEV_NO_ATTACH`→`DEV_NO_ATTACH`
- Modify: `dot_config/herdr/config.toml` — the `prefix+shift+g` popup command `hwt-prompt`→`wt-prompt`
- Rename: `.scripts/test-hdev.sh`→`.scripts/test-dev.sh`, `.scripts/test-hdev-topology.sh`→`.scripts/test-dev-topology.sh`, `.scripts/test-hdev-integrations.sh`→`.scripts/test-dev-integrations.sh`
- Modify: `.scripts/test-wt-functions.sh:149` — `HDEV_LAYOUT`→`DEV_LAYOUT`, plus every `hdev`/`hwt` invocation

**Interfaces:**
- Consumes: Task 1's functions file (no `dev`/`wt` defined).
- Produces: `dev()`, `wt()`, `wt-prompt()`; env seams `DEV_LAYOUT`, `DEV_NO_ATTACH`.

- [ ] **Step 1: Rename in the test files first**

```bash
git mv .scripts/test-hdev.sh .scripts/test-dev.sh
git mv .scripts/test-hdev-topology.sh .scripts/test-dev-topology.sh
git mv .scripts/test-hdev-integrations.sh .scripts/test-dev-integrations.sh
```

Then in `.scripts/test-dev.sh`, `.scripts/test-dev-topology.sh`, `.scripts/test-dev-integrations.sh` and `.scripts/test-wt-functions.sh`, replace whole words only: `hdev`→`dev`, `hwt-prompt`→`wt-prompt`, `hwt`→`wt`, `HDEV_LAYOUT`→`DEV_LAYOUT`, `HDEV_NO_ATTACH`→`DEV_NO_ATTACH`.

**`test-dev-integrations.sh` is in this list because line 64 passes `HDEV_NO_ATTACH=1`** — it is touched by the rename even though it covers hook wiring this change does not otherwise affect.

Two hazards. `test-dev.sh:880` asserts `edit_scrollback = "alt+s"` with the comment "Alt-s retains the Zellij scrollback mnemonic" — reword the comment (the mnemonic is kept, the mechanism differs), do not touch the assertion. And a blind `hwt`→`wt` also rewrites `$HWT` fixture variables; rename those deliberately or leave them, but do not end up with two different names for one variable.

- [ ] **Step 2: Run both suites to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh; zsh .scripts/test-dev.sh`
Expected: FAIL — the tests now call `dev`/`wt`, which after Task 1 do not exist.

- [ ] **Step 3: Rename in the source**

In `dot_config/zsh/functions`:

```zsh
# hdev → dev, hwt → wt, hwt-prompt → wt-prompt
```

Rename the three function definitions and every internal reference, including:
- the `${HDEV_LAYOUT:-$HOME/.config/herdr/layout.sh}` fallbacks (293, 297) → `${DEV_LAYOUT:-…}`
- the `hdev:` error prefixes in `dev()` itself, `_wt_ensure_herdr_lock` and `_wt_prepare_for_herdr` → `dev:`
- `wt-prompt`'s body calls `hwt` → `wt`
- the `usage: hwt <branch>` string → `usage: wt <branch> [start-point]`, matching `_wt_create_or_prepare`'s own usage line

Update `dev()`'s header comment: it currently says "The Herdr-side counterpart to `dev`, running beside it during the trial; `dev` is unchanged." That is now self-referential nonsense. Replace with a plain description of the cascade, and **keep** the note that resolution is all it does — "Everything about Herdr lives in layout.sh, which is also what the `dev.layout.apply` plugin action calls — one topology definition, two entry points."

In `dot_config/herdr/executable_layout.sh`, rename `HDEV_NO_ATTACH` at 474 (comment) and 477 (the test).

In `dot_config/herdr/config.toml`, change the `prefix+shift+g` popup command from `hwt-prompt` to `wt-prompt`. **This binding breaks silently if missed** — the popup would open and fail to find the command.

- [ ] **Step 4: Run both suites to verify they pass**

Run: `zsh .scripts/test-wt-functions.sh; zsh .scripts/test-dev.sh`
Expected: PASS, both.

- [ ] **Step 5: Verify no `hdev`/`hwt` identifier survives outside the design records**

Run: `git grep -nE '\b(hdev|hwt|HDEV_)' -- ':!docs'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Rename hdev/hwt to dev/wt

The Herdr entry points take the names the Zellij ones held. wt-prepare
and wt-rm were already unprefixed and already covered both paths, which
is what makes these the right names to reclaim."
```

---

### Task 3: Change the ownership lock marker to `wt-managed`

**Files:**
- Modify: `dot_config/zsh/functions:414-416` — `_wt_herdr_lock_reason()`
- Modify: `.scripts/test-wt-functions.sh` — the `locked hwt-managed` assertion at ~1782 and any other literal
- Modify: `.scripts/test-dev-topology.sh:148` — the live lock-reason comparison

**Interfaces:**
- Consumes: Task 2's renamed functions.
- Produces: `_wt_herdr_lock_reason()` returning `wt-managed; remove with command wt-rm`.

- [ ] **Step 1: Run the pre-apply gate — this is a hard gate, not a formality**

```zsh
for d in ~/Code/*/*/.git; do
  r="${d%/.git}"
  while IFS= read -r -d '' line; do
    [[ "$line" == "locked hwt-managed; remove with command wt-rm" ]] \
      && print -r -- "STALE MARKER: $r"
  done < <(git -C "$r" worktree list --porcelain -z 2>/dev/null)
done
```

Expected: no output. **Any hit aborts this task.** Retire that worktree with the current `command wt-rm` — which still understands the old marker — and only then proceed. Do not edit the marker with a stale lock outstanding: `wt-rm` classifies a non-matching reason as a foreign lock and refuses, leaving the checkout removable only by hand.

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

### Task 4: Remove the wrapper preflight and `ZELLIJ_SOCKET_DIR`

The one deletion that removes a safety check. The property it guarded — an unreachable multiplexer misread as "no session running", leading to removal while processes still hold the directory — is already reimplemented for Herdr inside `_wt_stop_herdr_workspaces`, which fails closed on an API-level `server_not_running` from a session `session list` just called running.

**Files:**
- Modify: `dot_local/bin/executable_wt-rm` — the preflight (38-68) and the zshenv comment (19)
- Modify: `dot_config/zsh/zshenv:29-34` — `ZELLIJ_SOCKET_DIR`
- Modify: `.scripts/test-wt-functions.sh` — section R (1556-1651), the fixture at 1504-1510, section S's comment at ~1661

**Interfaces:**
- Consumes: Task 3's functions.
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

### Task 5: Retire the Zellij configuration artifacts

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

### Task 6: Update the stale comments, and verify `cmd+k` still clears

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

Run: `git grep -i zellij -- ':!docs'`
Expected: no output.

Do **not** use `grep -ri zellij`: it walks `.git` and matches ref and reflog metadata, including this branch's own name, so it can never come back clean.

- [ ] **Step 4: Run both suites**

Run: `zsh .scripts/test-wt-functions.sh; zsh .scripts/test-dev.sh`
Expected: PASS. `test-dev.sh` asserts on `herdr/config.toml` content, so a careless comment edit there can go red.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Update the comments that named Zellij

Comment text only. cmd+k still clears in a Herdr pane: Herdr binds no
alt+k, so the chord reaches zsh's clear-screen binding."
```

---

### Task 7: Record the outcome on the Herdr trial spec

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

### Task 8: Update GLOBAL.md in 1Password

Four statements go stale. This is the only task that writes outside git, and it cannot be reverted by `git revert`.

**Files:**
- Modify: `op://Private/Agent instructions/notes` via `op-edit`

**Interfaces:**
- Consumes: the finished behaviour from Tasks 1-6.
- Produces: instruction text matching the shipped lifecycle, rendered to `~/.config/agents/GLOBAL.md`, `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.

- [ ] **Step 1: Make the four edits**

Run `op-edit` (needs `dangerouslyDisableSandbox` — `op`'s config path is a denied credential — and a 1Password desktop approval).

1. "in its own Zellij dev session" → "in its own Herdr worktree workspace"
2. "Raw removal skips the Zellij session shutdown and the project teardown hook" → "skips the Herdr workspace shutdown and the project teardown hook"
3. "for `wt-rm` that also bypasses the zellij safety preflight, which lives only in that wrapper" → this change **deletes** that preflight, so the clause goes. **Keep the surrounding rule**: invoke as `command wt-rm` / `command wt-prepare`, because a shell function of the same name shadows the `$PATH` wrapper.
4. "Agents do not create `wt`-managed sibling worktrees — that stays an interactive command, because `wt` attaches to a Zellij session." → "…because `wt` attaches a Herdr client."

**The rule in (4) must survive.** Deleting it along with the word "Zellij" would silently license agents to create interactive worktrees. The paragraph's carve-out for native and harness worktrees is unaffected.

- [ ] **Step 2: Verify all three rendered copies**

After `chezmoi apply` (Task 9), confirm:

```bash
grep -c -i zellij ~/.config/agents/GLOBAL.md ~/.claude/CLAUDE.md ~/.codex/AGENTS.md
grep -n "Agents do not create" ~/.config/agents/GLOBAL.md
```

Expected: `0` for all three files, and the agents rule still present.

---

### Task 9: Merge, apply, and run the live gates

**`chezmoi apply` must run from `~/.local/share/chezmoi`**, which is the canonical source path — not this worktree. This task therefore starts after the branch merges.

**Files:** none modified.

- [ ] **Step 1: Open the PR and merge**

Check for a template first (`.github/pull_request_template.md`, `.github/PULL_REQUEST_TEMPLATE.md`, repo root, `docs/`). If none fits, use a short *what / why / how to verify*. No agent attribution anywhere in the title or body.

- [ ] **Step 2: Dry-run the apply from the canonical source**

Run: `chezmoi apply --dry-run --verbose`
Expected: shows `~/.config/zellij` being removed, `~/.config/zsh/functions`, `~/.zshrc`, `~/.config/ghostty/config`, `~/.config/herdr/*`, `~/.local/bin/wt-rm` and `~/.config/homebrew/Brewfile` updating. Read this output rather than skimming it — an apply that will prompt about a modified target shows up here.

- [ ] **Step 3: Apply**

Run: `chezmoi apply`
Then confirm the deployed tree is gone: `ls ~/.config/zellij` → expected "No such file or directory".

- [ ] **Step 4: Uninstall the Zellij binary**

```bash
brew uninstall zellij
```

Expected: removes 0.45.1. No sessions are running and `/tmp/zellij-$UID` does not exist, so nothing is interrupted.

- [ ] **Step 5: Run the mocked suites against the deployed state**

Run: `zsh .scripts/test-wt-functions.sh; zsh .scripts/test-dev.sh`
Expected: PASS, both. These read the repo source, not the deployed copy, but running them post-apply catches a merge that lost something.

- [ ] **Step 6: Run the live topology gate**

Run: `zsh .scripts/test-dev-topology.sh`
Expected: PASS. It exercises `wt` creation, the new lock marker and label-resolved tab jumps against the real binary — all three change here. It uses its own named `hdev-test` session and scratch repos.

**The live `dev` / `wt` / `wt-rm` round trip runs inside this script's existing fixture**, not against a real project under `~/Code`. A round trip should not be proving itself on a checkout that matters.

- [ ] **Step 7: Check the renamed no-attach control in the integrations script**

Run: `zsh -n .scripts/test-dev-integrations.sh`
Expected: no syntax errors.

Then run it far enough to confirm `DEV_NO_ATTACH=1` still suppresses the blocking TUI at line 64. A full cold-restore rerun is **optional** — Step 6 already exercises the same control in seven places. This script touches real `~/.claude` and `~/.codex`; do not run it in full without a reason to.

- [ ] **Step 8: Final sweep**

```bash
git grep -i zellij -- ':!docs'          # expected: no output
which zellij                            # expected: not found
ls ~/.config/zellij                     # expected: No such file or directory
grep -c -i zellij ~/.claude/CLAUDE.md   # expected: 0
```

Open a new shell and confirm `dev` and `wt` resolve to the new functions: `which dev`, `which wt`.

- [ ] **Step 9: Mark the design records implemented**

Set `**Status:** Implemented` with the PR reference on both `docs/superpowers/specs/2026-08-30-zellij-removal-design.md` and this plan, then commit. Per the design-records policy this is the final pre-merge commit — do it before merging, not after.

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: Deleted → 1, 4, 5; Renamed → 2; Behaviour change 1 (lock) → 3; Behaviour change 2 (`dev <session-name>`) → 2, where deleting the Zellij `dev` and inheriting `hdev`'s cascade is what retires it; Comment-only → 6; Out of repo → 5 (`.chezmoiremove`, brew), 8 (GLOBAL.md), 9 (uninstall, apply); Design records → 7, 9; Testing → the test steps throughout plus 9.

**Two gaps found and closed while reviewing.** The spec's `dev <session-name>` change had no task of its own — it is a consequence of Task 2 rather than an action, so Task 2's Step 3 now covers the header comment that documented it. And nothing verified the Brewfile template still renders after editing a `.tmpl`; that is Task 5 Step 4.

**Ordering.** Task 3's gate must run immediately before its own edit, not at plan time. Task 4 deletes `ZELLIJ_SOCKET_DIR` and the wrapper preflight together because the preflight reads the variable — splitting them leaves a wrapper referencing an unset variable. Task 9 is gated on merge because `chezmoi apply` must run from the canonical source path.

**Naming consistency.** `DEV_LAYOUT` and `DEV_NO_ATTACH` are used identically in Tasks 2, 3 and 9. The lock reason `wt-managed; remove with command wt-rm` appears identically in Tasks 3 and 9 and in the spec's rollback scan.
