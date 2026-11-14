# Herdr app config under chezmoi: implementation plan

> **For agentic workers:** run this with the `plan-run` skill (it overrides
> superpowers:subagent-driven-development). Steps use checkbox (`- [ ]`) syntax.

**Status:** Completed 2026-11-15 (branch `chore/herdr-app-in-chezmoi`, its PR against `main`).
Do not run it again; its execution notes bind that run only.
**Goal:** Michael's authored Herdr app config (`~/.config/herdr-app`) becomes a chezmoi-managed
tree whose render is byte-identical to the live files. The app's two suites move into `tests/`,
and the cask joins the Brewfile.
**Architecture:** The authored files are copied verbatim into `dot_config/herdr-app/`, with
three JSON files templated on `{{ .chezmoi.homeDir }}` and `settings.json` as a `create_` seed.
A folder-level allowlist in `.chezmoiignore` admits only those files. The suites render the tree
through real chezmoi, from a scratch source holding only `.chezmoiignore` and
`dot_config/herdr-app`, into a scratch home, and test that render.
**Tech stack:** chezmoi 2.74, zsh suites, `tests/run.sh`.
**Spec:** `docs/superpowers/specs/2026-11-14-herdr-app-in-chezmoi-design.md` (read it first; the
plan argues from it).

`CO` below is the checkout, `/Users/michael/.local/share/chezmoi-chore-herdr-app-in-chezmoi`.
`LIVE` is `/Users/michael/.config/herdr-app`, which is read-only for this run: no task writes,
moves or deletes anything under `LIVE` or `~/.config/herdr`.

## Global constraints

- No change to how the app behaves, and no change to any authored file's content. The only
  change is the home path written `{{ .chezmoi.homeDir }}`, which renders to the same bytes.
- `command chezmoi --source $CO diff ~/.config/herdr-app` prints nothing, and so does `status`.
  `create_settings.json` is also `cmp`-identical to `LIVE/settings.json`.
- Not touched: `dot_config/herdr/`, the TUI scripts, plugins and hooks, `brew "herdr"`, xreview,
  wt, `.chezmoitemplates/agents/`, `dot_claude/`.
- Never committed: runtime state, Herdr's shipped mods, layouts, themes, `frame/`, `icons/`,
  `AGENTS.md`, the `.d.ts` files, `mods/*/jsconfig.json`, `mods/michael-spaces`,
  `mods/michael-menu`.
- `keys.json` and `layouts/michael.json` have no trailing newline. Copy with `cp`, and template
  with `perl -pe` (which keeps the missing newline), never an editor or `sed`.
- Suites: executed, never through an interpreter. Each passing check prints `  PASS: <what>`.
  A missing subject exits 2 and names its repository-relative path. Report totals as
  passed/total.
- Implementers run only the suites for what they changed. The controller runs the full suite.

## Review focus

1. **A live file edited after it was copied.** Michael is working in the app, and an apply
   after merge would revert his edit. The controller re-runs Task 1 step 4 just before the PR
   and before the final report. A difference means the live file is copied in again and the
   report names it.
2. **A lost or added trailing newline, or a wrong mode.** This shows as a `chezmoi diff` line
   (Task 1 step 4) or a failing suite case (Task 2, which renders through chezmoi).
3. **An authored file without its allowlist entry**, which never deploys and doesn't fail
   loudly. Task 1 step 4 compares the exact managed list. Task 2's render fails the cases of
   any script that is missing.
4. **A runtime or shipped file reaching the source through `chezmoi add`.** Task 2's allowlist
   cases.
5. **A machine without the app** (new machine, other host). Task 2's skip path, run with an
   empty `HERDR_APP_HOME`, must skip exactly the ten `patch-mod` checks and stay green.

---

### Task 1: The managed tree and its allowlist

**Depends on:** none
**Files:**
- Create: `dot_config/herdr-app/**` (27 files, listed in step 1)
- Modify: `.chezmoiignore` (a new block after the `.codex/*` block)

**Interfaces:**
- Produces: the source tree at `dot_config/herdr-app/`, whose render is the live authored set.
  Task 2 renders it, and Task 3 documents it.

- [ ] **Step 1: Copy the authored files.** `cp` from `LIVE` to `CO/dot_config/herdr-app/`:

  | Live | Source |
  |---|---|
  | `bin/<name>` ×10 (claude-app, close-own-tab, folder-gone, open-space, patch-mod, respaces, retire, session-written, wt-app, xreview-app) | `bin/executable_<name>` |
  | `xreview-shim/herdr` | `xreview-shim/executable_herdr` |
  | `patches/phases.js`, `patches/worktree-actions.js` | same names |
  | `mods/<m>/main.js`, `mods/<m>/mod.json` for m in nav, resume, usage, respaces-guard | same names (never the mod's `gpui-kit.d.ts` or `jsconfig.json`) |
  | `layouts/michael.json`, `themes/tokyo-night.json` | same names |
  | `settings.json` | `create_settings.json` |

  Then template the other three:
  `perl -pe 's|/Users/michael|{{ .chezmoi.homeDir }}|g' LIVE/<f>.json > CO/dot_config/herdr-app/<f>.json.tmpl`
  for f in keys, programs, claude-settings.

- [ ] **Step 2: Add the allowlist block to `.chezmoiignore`,** after the `.codex/*` block, with a
  comment in the style of the Claude Code and Alfred blocks. The comment says that the tree
  mixes Michael's files with app state (`view.json` and `shared.json` hold repo paths and
  session ids), Herdr's shipped code and the generated `michael-*` clones.

  ```
  .config/herdr-app/*
  !.config/herdr-app/bin
  !.config/herdr-app/patches
  !.config/herdr-app/xreview-shim
  !.config/herdr-app/keys.json
  !.config/herdr-app/programs.json
  !.config/herdr-app/claude-settings.json
  !.config/herdr-app/settings.json
  !.config/herdr-app/layouts/
  .config/herdr-app/layouts/*
  !.config/herdr-app/layouts/michael.json
  !.config/herdr-app/themes/
  .config/herdr-app/themes/*
  !.config/herdr-app/themes/tokyo-night.json
  !.config/herdr-app/mods/
  .config/herdr-app/mods/*
  !.config/herdr-app/mods/nav
  !.config/herdr-app/mods/resume
  !.config/herdr-app/mods/usage
  !.config/herdr-app/mods/respaces-guard
  .config/herdr-app/mods/*/gpui-kit.d.ts
  .config/herdr-app/mods/*/jsconfig.json
  ```

  A prototype on 2026-11-15 confirmed this behaviour with chezmoi 2.74.1: the later
  `mods/*/gpui-kit.d.ts` ignore beats the earlier `!mods/nav`, `layouts/*` covers
  `layouts/.state`, and `.chezmoi.homeDir` follows `HOME`.

- [ ] **Step 3: Check the managed set.**
  Run: `command chezmoi --source $CO managed --include files --path-style relative ~/.config/herdr-app`
  Expected: exactly the 27 targets, `.config/herdr-app/` followed by: `bin/` ×10,
  `xreview-shim/herdr`, `patches/` ×2, `mods/{nav,resume,usage,respaces-guard}/{main.js,mod.json}`,
  `layouts/michael.json`, `themes/tokyo-night.json`, `keys.json`, `programs.json`,
  `claude-settings.json`, `settings.json`.

- [ ] **Step 4: Check that the render equals the live tree.**
  Run: `command chezmoi --source $CO diff ~/.config/herdr-app`, then
  `command chezmoi --source $CO status ~/.config/herdr-app`, then
  `cmp $CO/dot_config/herdr-app/create_settings.json ~/.config/herdr-app/settings.json`.
  Expected: no output from any of the three, and exit 0.

- [ ] **Step 5: Check for secrets and names, then commit.** `git -C $CO diff --cached` must show
  no token and no customer name. Then, on branch `chore/herdr-app-in-chezmoi`:
  `git add dot_config/herdr-app .chezmoiignore`, and commit
  "Bring the Herdr app config under chezmoi".

### Task 2: The app suites in `tests/`

**Depends on:** Task 1 (renders `dot_config/herdr-app` through its allowlist)
**Files:**
- Create: `tests/herdr-app.test.sh`, from `LIVE/tests/run.zsh`
- Create: `tests/herdr-app-xreview.test.sh`, from `LIVE/tests/xreview-app.zsh`
- Create: `tests/fixtures/herdr-app/stubs/{claude,fzf,hc,herdr-app,ps,wt-rm}` (mode 755) and
  `tests/fixtures/herdr-app/tui-shapes.json`, copied from `LIVE/tests/`
- Create: `tests/fixtures/herdr-app/render.zsh`
- Modify: `tests/missing-subject.test.sh`, `.scripts/test-audit/subjects.tsv`

**Interfaces:**
- Consumes: Task 1's `dot_config/herdr-app/` and `.chezmoiignore`.
- Produces: `render.zsh`, sourced by both suites, which defines
  `herdr_app_render <root>`. It copies `$SRC/.chezmoiignore` and `$SRC/dot_config/herdr-app`
  into `<root>/src` and runs
  `HOME=<root>/home chezmoi --config <root>/aux/empty.toml --source <root>/src --destination <root>/home --persistent-state <root>/aux/state.db --cache <root>/aux/cache apply --force`.
  The tree is then at `<root>/home/.config/herdr-app`. On failure it returns nonzero with
  chezmoi's stderr. `aux` must not be an ancestor of `home`, or chezmoi refuses to write.

- [ ] **Step 1: Move the suites with the smallest edits.** Copy both suites verbatim, then change
  only these things:
  - `SRC=${0:A:h:h}`. `bin` and `shim` point into the render:
    `$root/r/home/.config/herdr-app/{bin,xreview-shim/herdr}`, rendered once at the start with
    `herdr_app_render $root/r`.
  - Stubs come from `$here/fixtures/herdr-app/stubs`, and `shapes` from
    `$here/fixtures/herdr-app/tui-shapes.json`.
  - `herdr-app.test.sh` links `$SRC/dot_config/zsh` in place of `$real_home/.config/zsh`.
  - `check` prints `  PASS: $what` on a pass and `  FAIL: $what` on a failure. It is still
    counted, and the exit status is still `(( passed == total ))`.
  - The ten `patch-mod` checks read `shipped=${HERDR_APP_HOME:-$HOME/.config/herdr-app}/mods`,
    captured at the top before any `newworld` exports `HERDR_APP_HOME`. If
    `$shipped/menu/main.js` or `$shipped/spaces/main.js` is missing, the suite prints
    `SKIP: no installed Herdr app mods in <path>; the 10 patch-mod checks did not run`, adds 10
    to `skipped`, and runs none of them.
  - Guard: before rendering, each suite checks the source files it tests and exits 2 with
    `missing <repo-relative path>`. For `herdr-app`: every `bin/executable_*` it runs, and
    `dot_config/zsh/functions`. For `herdr-app-xreview`: `bin/executable_xreview-app` and
    `xreview-shim/executable_herdr`.
  - No assertion is changed, dropped or weakened.

- [ ] **Step 2: Add the allowlist cases to `herdr-app.test.sh`** (spec acceptance 3).
  - **The scratch home** holds `.config/herdr-app/{view.json, shared.json, data/x/s.json,
    layouts/.state/michael.json, mods/michael-spaces/main.js, mods/spaces/main.js,
    mods/nav/gpui-kit.d.ts, mods/nav/jsconfig.json}`, plus `bin/new-script` (mode 755). It holds
    no templated target such as `keys.json`, so `chezmoi add` never stops at its
    "remove template attribute" TTY prompt. Each `chezmoi add` call gets `</dev/null`, so an
    unexpected prompt fails instead of hanging.
  - **Each case** uses a fresh scratch source made the same way as the render, and its own
    `aux` dir outside the home's ancestors. It compares the source's file list before and
    after.
  - **The directory cases:** `check "chezmoi add of <path> adds nothing"` for each of
    `view.json`, `shared.json`, `data`, `layouts/.state`, `mods/michael-spaces`, `mods/spaces`
    (a shipped mod), `mods/nav/gpui-kit.d.ts` and `mods/nav/jsconfig.json`. The source's file
    list is unchanged.
  - **The whole-tree case:** `check "chezmoi add of the whole tree adds only the new script"`.
    `chezmoi add <home>/.config/herdr-app` leaves exactly one new source file,
    `dot_config/herdr-app/bin/executable_new-script`. That is both the recursive check and the
    positive control, so the cases can't pass on an allowlist that refuses everything.

- [ ] **Step 3: Run the moved suites.**
  Run: `./tests/herdr-app.test.sh; ./tests/herdr-app-xreview.test.sh` (sandboxed)
  Expected: `herdr-app` 139 + the allowlist cases, all passing, with `2 skipped` (pty).
  `herdr-app-xreview` 262/262. Each exits 0.

- [ ] **Step 4: Run the skip path.**
  Run: `HERDR_APP_HOME=$(mktemp -d) ./tests/herdr-app.test.sh`
  Expected: the `SKIP: … the 10 patch-mod checks did not run` line, `12 skipped`, 10 fewer
  PASS lines, and exit 0.

- [ ] **Step 5: Stage the new files, then add the missing-subject rows.**
  `tests/missing-subject.test.sh` (and the test audit) copies only files git tracks
  (`git ls-files`), so first `git -C $CO add` the two suites and `tests/fixtures/herdr-app/`.
  Stage them; don't commit. Then add the rows, in name order in
  `tests/missing-subject.test.sh`:
  ```
  missing herdr-app             dot_config/herdr-app/bin/executable_retire
  missing herdr-app             dot_config/zsh/functions
  missing herdr-app-xreview     dot_config/herdr-app/bin/executable_xreview-app
  missing herdr-app-xreview     dot_config/herdr-app/xreview-shim/executable_herdr
  ```
  Run: `./tests/missing-subject.test.sh`. Expected: every row passes, including the four new
  ones.

- [ ] **Step 6: Add the subject-map rows** in `.scripts/test-audit/subjects.tsv`, sorted and in
  the file's format. The renderer copies and renders all 27 files of `dot_config/herdr-app`,
  so every one of them gets a row with `herdr-app,herdr-app-xreview` in `loaded_by`:
  - **Executed and asserted:** each `bin/executable_*`. Its lang comes from the shebang: zsh,
    `py` for `folder-gone` and `patch-mod`, `sh` for `session-written`. own_suite is
    `herdr-app`, except `herdr-app-xreview` for `xreview-app`.
    `xreview-shim/executable_herdr` is zsh with own_suite `herdr-app-xreview`.
  - **Asserted data:** `claude-settings.json.tmpl` and `programs.json.tmpl` (`data`, own_suite
    `herdr-app`, whose claude-app checks read them).
  - **Copied and rendered, never asserted:** `keys.json.tmpl`, `create_settings.json`,
    `layouts/michael.json`, `themes/tokyo-night.json`, `patches/*.js`, and the four mods'
    `main.js` and `mod.json`. Their lang is `data` and their own_suite is `-`, so the audit
    plans no mutant no suite could catch.
  - **Suite fixtures:** the stubs, `tui-shapes.json` and `render.zsh`, with own_suite `-` and
    their suite(s) in `loaded_by`.
  - **Existing rows:** add `herdr-app,herdr-app-xreview` to `.chezmoiignore`'s `loaded_by`, and
    `herdr-app` to `dot_config/zsh/functions`'s.

  Run: `./tests/run.sh test-audit`. Expected: green.

- [ ] **Step 7: Commit** "Move the Herdr app suites into tests/".

### Task 3: Brewfile, new-machine step, AGENTS.md

**Depends on:** none (documents Task 1's tree; reads none of its files)
**Files:**
- Modify: `dot_config/homebrew/Brewfile.tmpl` (the unconditional cask block, alphabetical:
  after `cask "codex"`, before `cask "orbstack"`)
- Modify: `tests/provision.test.sh` (section F, the per-machine Brewfile renders)
- Modify: `README.md` ("Setting Up a New Machine", Manual: a step 10)
- Modify: `.scripts/provision.sh` ("Next steps": a new numbered item)
- Modify: `AGENTS.md` (Rules)

- [ ] **Step 1: Write the failing test.** In `tests/provision.test.sh` section F, next to the
  peripheral-cask checks, add one check per machine render:
  `has 'cask "herdr-app"' "<machine> gets the Herdr app"` for fenrir and hercules.
  Run: `./tests/provision.test.sh`. Expected: the two new checks fail.

- [ ] **Step 2: Add the cask line:** `cask "herdr-app"` followed by a comment in the column
  style, `# Herdr desktop app; config in ~/.config/herdr-app`. Run `./tests/provision.test.sh`.
  Expected: green.

- [ ] **Step 3: Add the new-machine step,** worded the same in both places: "Herdr app: open it
  once, run `~/.config/herdr-app/bin/respaces` with its window open (it builds the
  michael-spaces and michael-menu mods from Herdr's), then pick the michael layout
  (cmd-shift-L)." If `provision.test.sh` pins the Next-steps text, extend that case.

- [ ] **Step 4: Update AGENTS.md.**
  - The allowlist rule's tree list ("for `~/.claude`, `~/.codex`, and Alfred") adds
    `~/.config/herdr-app`.
  - Add one Rules bullet:
    - `~/.config/herdr-app` holds only Michael's files.
    - `settings.json` is a `create_` seed, because the app writes it.
    - `mods/michael-spaces` and `mods/michael-menu` are generated by `bin/respaces` and are
      never added.
    - The three `.json.tmpl` files are edited in the source; `chezmoi add` of one asks to drop
      its template.
    - The suites are `tests/herdr-app*.test.sh`. `herdr-app`'s `patch-mod` checks read the
      installed app's shipped mods: they skip without it, and fail after an app update moves a
      patched line.
  - Run: `./tests/agent-instructions.test.sh`. Expected: green.

- [ ] **Step 5: Commit** "Install the Herdr app and document its new-machine step".

## Batches

Task 1 runs alone. Then Tasks 2 and 3 run together: their files are disjoint, and neither's
suites load the other's files. Task 1 gets a task review (Task 2 renders what it creates).
Tasks 2 and 3 get the controller's check.

## After the last task (controller)

Every gate below (the full run, the final review, Codex's pre-merge review) must see the
branch's final commit. Any later commit sends the sequence back to step 3.

1. **Live check.** Run Task 1 step 4 again (review focus 1). If a live file has moved, copy it in,
   re-run Task 2 step 3, and commit "Take the live <file>".
2. **Records.** Set the spec to `**Status:** Implemented` (branch `chore/herdr-app-in-chezmoi`,
   its PR against `main`), and mark this plan completed. Commit both.
3. **Full run.** Run `./tests/run.sh --changed` on that commit, and quote its heavy-suite lines.
4. **Preview.** `command chezmoi --source $CO apply --dry-run --verbose ~/.config/herdr-app`
   writes nothing. `command chezmoi --source $CO cat ~/.config/homebrew/Brewfile` differs from
   main's render only by the cask line.
5. **Reviews.** The final review (`sp-architect`), then Codex's pre-merge review. A fix wave
   commits, then returns to step 3.
6. **Last live check.** Run step 1 again just before pushing and opening the PR. If it imports a
   file, return to step 3.
7. **Push and open the PR** (merge-request skill). Then run the live check once more, just
   before the final report. If a file has moved by then, import it, return to step 3, and push
   again before reporting.
