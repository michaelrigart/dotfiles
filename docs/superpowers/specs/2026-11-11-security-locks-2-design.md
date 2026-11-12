# Security locks 2: seven small locks from the 2026-11-11 setup review

**Status:** Implemented (branch `fix/security-locks`; the dotfiles use no MR)
**Date:** 2026-11-11
**Branch:** `fix/security-locks`, in the `wt` checkout `~/.local/share/chezmoi-fix-security-locks`
**Related:** `2026-11-01-security-locks-design.md` (first round; unchanged). Item 5 supersedes one
decision of `2026-10-23-ha-mcp-design.md` (D3).

## Why

A setup review on 2026-11-11 reported seven gaps. Each was re-checked on fenrir against this checkout
(`main` at `fc6cf19`) and the installed Claude Code 2.1.322, Neovim 0.12.6, Codex cask 0.167.0, Ruby 4.0.9
with Bundler 4.0.20 and macOS 27.2.1. "Verified" means read in a file or measured with the command named;
"inferred" means reasoned from code or binary strings, not run. Five claims held. Item 1's `--cmd` would be
undone by LazyVim, and item 4's settings switch is undocumented. Item 7 became a manual step, with no code.

## 1. `op-edit` leaves the note's plaintext in Neovim's state

- **Problem.** `dot_config/zsh/functions:17-18` promises a private temp file; `:67` runs
  `"${EDITOR:-nvim}" "$tmp"`. LazyVim sets `opt.undofile = true` (its `config/options.lua:109`), so a save
  writes an undo file. Verified: `~/.local/state/nvim/undo/` holds `…%T%op-edit.45WHypL1zr` and
  `…%T%op-edit.Q0wSzRMw7c` (29 Jul, 0600; contents not read), readable by any sandboxed command. Swap
  files and ShaDa (registers, so yanked lines) persist note text too.
- **Correction.** `--cmd` runs "before any config" (`nvim --help`); LazyVim then loads its options
  (`config/init.lua:332`) and turns `undofile` back on. `-c` runs "after config and first file".
- **Change.** `nvim -n -i NONE -c 'set noundofile nobackup nowritebackup' -- "$tmp"`, always `nvim`, not
  `$EDITOR` (`zshenv:42-46` picks `vim` over SSH): the guarantee holds only for known flags. Not done:
  `--clean` (drops LazyVim; the flags suffice), purging backups that hold the two files.
- **Test.** No suite covers `op-edit`: new `tests/op-edit.test.sh` on `chezmoi-wrapper.test.sh`'s stub
  pattern (`op`, `chezmoi`, an `nvim` recording its argv) asserts `-n`, `-i NONE` and a `-c` carrying
  `noundofile`, also under `EDITOR=vim`. Fails today (argv is the path alone).
- **After apply.** `rm ~/.local/state/nvim/undo/*op-edit.*`, optionally also `…/nvim/shada/main.shada`
  (may hold yanked note text; costs nvim history). After one edit, `ls …/nvim/undo | grep -c op-edit` is 0.

## 2. Bundler's forge tokens are readable by everyone

- **Problem.** `dot_config/bundler/config.tmpl:2-3` renders a GitHub and a GitLab token without `private_`;
  `~/.config/bundler/config` is 0644 (verified, `ls`). The deny rules
  (`dot_claude/modify_private_settings.json:132-135`), `credentials.files` (`:381-399`) and the session's
  sandbox read-deny list all omit it. Codex has no credential deny list to extend
  (`dot_codex/modify_private_config.toml`; Codex reading every file is a non-goal since 2026-10-23).
- **Change.** Rename to `dot_config/bundler/private_config.tmpl` (0600). Add `Read(~/.config/bundler/**)`
  and `Edit(~/.config/bundler/**)` beside ha-mcp's rules and `{ "path": "~/.config/bundler/config",
  "mode": "deny" }` to `credentials.files`. Move the non-secret keys to `zshenv` exports beside
  `BUNDLE_USER_CONFIG` (`:57`): `BUNDLE_JOBS=8`, `BUNDLE_BUILD__PG=--with-opt-dir=/opt/homebrew/opt/libpq`;
  Bundler ranks env above the user file (`settings.rb`, `configs`). `AGENTS.md:11` names the new path.
- **Consequence.** The 2.1.322 profile denies `file-read*` on denied paths and re-allows metadata only for
  directories (binary strings), so Bundler's `file.exist?` is false and it skips the file silently
  (`settings.rb:480-484`; inferred). Sandboxed, a private HTTPS git gem then fails to authenticate, and that
  `bundle install` runs unsandboxed via the classifier. No `Gemfile.lock` in `~/Code` (depth 4) needs one:
  the only `GIT` source is the public prawn. The `zshenv` move keeps sandboxed `pg` builds working
  (`pg_config` is not on `PATH`; libpq is keg-only). Not done: retiring or rotating the tokens (D1).
- **Test.** `claude-settings.test.sh`: `EXP_DENY` (`:25`) and `EXP_CREDENTIALS` (`:339`) are exact lists,
  so the new entries fail without the fix. `zshenv.test.sh`: its clean login shell exports both keys. The
  mode is checked after apply; a suite could only pin the file name.
- **After apply.** `stat -f %Lp ~/.config/bundler/config` prints 600; restart Claude Code sessions.

## 3. Claude Code runs unsandboxed when the sandbox cannot start

- **Problem.** The sandbox block (`modify_private_settings.json:371-379`) and the live
  `~/.claude/settings.json` (verified, `jq`) lack `failIfUnavailable`. The 2.1.322 schema (binary
  strings): "When false (default), a warning is shown and commands run unsandboxed."
- **Change.** `"failIfUnavailable": true` in the sandbox block. User settings is honoured: with true there,
  a project-settings false is ignored (same schema). Managed rejected: its one line is pinned by
  install-claude-managed-settings test 1, needs sudo per Mac, and the sandbox already denies writes to
  `~/.claude/settings.json`. A `claude` started inside another sandbox now refuses to start; both scripted
  starts here run outside one (`review` is excluded, `live-deny-modes` runs unsandboxed).
- **Test.** `claude-settings.test.sh`: `jq_is '.sandbox.failIfUnavailable' true` (null today). After apply,
  restart sessions. If Seatbelt ever breaks, sessions refuse to start until the sandbox is repaired; the
  key is never removed to get going again.

## 4. The Codex daemon updates itself outside Homebrew

- **Problem (verified).** The LaunchAgent runs Homebrew's `codex` (0.167.0) `app-server daemon start`; the
  daemon runs `~/.codex/packages/app-server-daemon/current`, which moved to 0.167.1 on 2026-11-11 00:11.
  `daemon-updater.stderr.log` records `installer_fetch`, `installer_run`, `package_selected` every 3601 s
  (trigger `scheduled`), bypassing Homebrew and the `live-codex-daemon` canary.
- **Correction.** No README ships with the package or the cask. The 0.167.0 binary holds
  `app-server-daemon/settings.json` and an `updater` struct (`autoUpdateEnabled`, `updateIntervalMinutes`);
  whether a partial object parses is unknown. Its CLI documents a pin instead: `update --from-cli` ("Copy
  and pin this CLI package"; "Run `codex app-server daemon update` to return to production updates").
- **Change (D2).** A, recommended: Michael runs the `--from-cli` pin now and after each `brew upgrade
  codex`, then the canary; `AGENTS.md`'s `codex` launcher bullet says so; chezmoi owns no file. B, only if
  A's measurement fails: a merge-preserving `dot_codex/private_app-server-daemon/modify_settings.json`
  setting `updater.autoUpdateEnabled` false (the daemon writes this file too), plus three `.chezmoiignore`
  lines re-including it. Trade-off: upgrades come only through Homebrew; a forgotten re-pin leaves the
  daemon behind the TUI, which the canary catches. The pin moves the daemon back to 0.167.0.
- **Test.** No suite can see the pin. Measured before the pre-merge review and recorded here:
  `codex app-server daemon version` shows equal CLI and running versions (its socket is denied to the
  sandbox, so Michael runs it), and after two scheduled cycles `current` still names the CLI's release.
  B would be tested in `codex-config.test.sh`, like `modify_private_hooks.json`.
- **Measured (2026-11-12, fenrir).** Homebrew's `codex` was 0.167.2 by then, so the pin kept the daemon
  at 0.167.2 and did not move it back to 0.167.0. Michael ran the pin at 12:05; `codex app-server daemon
  version` showed `cliVersion`, `managedCodexVersion` and `appServerVersion` all 0.167.2. `current` moved
  from `releases/0.167.2-aarch64-apple-darwin` to a `releases/local-<sha256>-aarch64-apple-darwin` copy
  of the CLI's package, so it names that copy, not a version. The updater's pid file, its socket and
  `auto-update-version` were gone. The pin ran in a Herdr pane, so the daemon needed `codex-daemon
  restart` (12:23). At 14:26, two scheduled cycles later, `current` still named the `local-` release and
  `daemon-updater.stderr.log` held nothing after 11:25, its last `scheduled` selection before the pin. A
  holds; B is not needed. The canary gave 62/63: R1's precondition expects `node_repl` and `cua_repl`
  helpers, which the Codex config disables since `7aab009`, so that failure is unrelated to the pin.
- **After apply.** The pin, when no review is active ("may interrupt running work"); hercules too.

## 5. ha-mcp runs whatever PyPI serves, holding the Home Assistant token

- **Problem.** `dot_local/bin/executable_ha-mcp:42` runs `uvx … ha-mcp@latest`; the UniFi launcher pins
  (`version=0.27.3`, `:10`, `:45`). `@latest` was Michael's accepted trade-off ("a new release runs with
  the Home Assistant token without review", `2026-10-23-ha-mcp-design.md:142-143`); this reverses it (D3).
  The uv cache holds 9.1.0 (11-05), 9.1.1 (11-07) and 9.1.2 (11-08).
- **Change.** `version=9.1.2` and `uvx --python "$python" "ha-mcp==$version"`, as for UniFi. 9.1.2 is the
  newest `ha_mcp-*.dist-info` in `~/.cache/uv/archive-v0`, built 2026-11-10 23:21 (inferred, no network).
  Bump: read the release's changes, edit `version=` and the two test lines, apply, restart the apps.
- **Test.** `ha-mcp.test.sh:82,141` assert the exact exec line; they move to `ha-mcp==9.1.2`. After
  apply, restart Claude Desktop and any Claude Code session using ha-mcp.

## 6. The apply-window guard runs on every tool call

- **Problem.** `modify_private_settings.json:347` registers `xreview-apply-guard.sh` with matcher `*`; the
  script exits when no window is open (`:42-50`) and allows every tool but `Edit|Write|NotebookEdit`
  (`:54`), so an unsandboxed bash runs per call for nothing. Depending on `*`: the pin at
  `claude-settings.test.sh:818-819` and comments (settings `:313-315`, `:324-326`;
  `xreview-apply-guard.test.sh:4`). Nothing else; prompt-audit's `*` is its own entry.
- **Change.** Matcher `Edit|Write|NotebookEdit` (2.1.322 hook text: a "pipe-separated list"), the script's
  own set; comments updated. Hygiene more than a lock: any Bash write bypasses the guard, so failing
  closed would protect nothing (D5). No `MultiEdit`: this 2.1.322 session offers no such tool.
- **Test.** `claude-settings.test.sh:818` expects `Edit|Write|NotebookEdit` and fails on `*`.

## 7. sshd on fenrir accepts passwords

- **Problem (verified).** `launchctl print-disabled system` shows `com.openssh.sshd => enabled`;
  `/etc/ssh/sshd_config.d/` holds only `100-macos.conf` (`UsePAM yes`); `sshd_config:65,69` leave
  `PasswordAuthentication` and `KbdInteractiveAuthentication` at their default, yes.
- **No key on fenrir.** A sandboxed `ls` finds no `~/.ssh/authorized_keys` (ENOENT; the `~/.ssh` deny
  could mask it, so Michael confirms). With no key a password is the only way in.
- **Change: none in the repository.** This is a manual step of Michael's on each Mac (D4), not code. A
  `configure.sh` block was rejected: getting it safe needs sshd's StrictModes checks on the file and its
  parent directories, plus rollback of an existing drop-in, and on fenrir it would write nothing.
  - Remote Login unused: `sudo systemsetup -setremotelogin off`.
  - Remote Login used: add the client's public key to `~/.ssh/authorized_keys`, confirm a key login
    works, then install `/etc/ssh/sshd_config.d/000-hardening.conf` (root, 0644) with
    `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, and run
    `sudo /usr/sbin/sshd -t`. `000-` sorts before `100-macos.conf` and sshd keeps the first value per
    keyword (`sshd_config(5)`); launchd starts sshd per connection, so nothing restarts.
- **Check.** From the other Mac, `ssh -o PubkeyAuthentication=no fenrir` is refused; with a key in place,
  `ssh fenrir` still works. The same on hercules.

## Permission prompts

Zero new prompts: items 2 and 3 add denials and a startup refusal, never an ask; 1, 4, 5 and 6 change no
rule; item 7 is a manual step.

## Rollout

1. On the branch: the settings task (items 3, 2's rules and 6: one template, one suite), the bundler rename
   and `zshenv` move, `op-edit`, the ha-mcp pin, the `AGENTS.md` lines. Another line edits
   the same template and suites (the `.sandbox.enabled` assertion); the second to merge rebases.
2. Before the pre-merge review: item 4's measurement, after Michael's pin.
3. After merge, Michael: `chezmoi apply`, restart Claude Code and Claude Desktop, the per-item checks; on
   hercules the same, plus the Codex pin. Item 7's step on both Macs.

## Out of scope

Codex reviewer isolation (its own spec); forge-side push protection; anything in `~/Code`; a release
watcher for PyPI pins; provisioning the Codex pin on a new Mac.

## Decisions for sign-off

Michael signed off on 2026-11-11 with every default below (Codex spec review: approve, round 2,
`xr-1794431956-ee5076c3`).

- **D1, bundler tokens.** No lockfile needs them today. Default: lock and keep them; if you know of no
  private-gem use, delete lines 2-3 instead and revoke both tokens.
- **D2, Codex updates.** Default: A, the `--from-cli` pin; B only if the measurement fails.
- **D3, ha-mcp.** Reverses your 2026-10-23 trade-off. Default: pin at 9.1.2.
- **D4, sshd on fenrir.** Do you SSH into fenrir? If not (default): `sudo systemsetup -setremotelogin off`,
  If you do: add your client's public key to `~/.ssh/authorized_keys` first, then install the drop-in.
- **D5, apply-window guard.** Default: stays fail-open (no `onFailure: "block"`).
