# Claude Code managed mods lock

**Status:** In progress (spec under review; the dotfiles have no MR)
**Date:** 2026-11-10
**Branch:** `feat/managed-mods-lock`

## Why

Claude Code 2.1.321 (2026-11-09) changed two things about mods, the plugins that hook into
Claude Code's own behaviour (CHANGELOG, verbatim):

- "Changed mods Claude writes to turn on without asking in auto and bypass modes, even with
  managed `allowUnsandboxedCommands: false` or `allowManagedDomainsOnly`, and not to load in
  `dontAsk` mode"
- "Changed mods' own tool calls (`$.tool.call`, `$.mcp.call`) to raise no permission prompt,
  even under your own ask rules or in `dontAsk` and `-p` runs; deny rules and organization
  policy still apply"

Michael's sessions default to auto mode. His ask rules gate destructive commands
(`git reset --hard`, `git clean -f`, `git branch -D`, `git filter-branch`, `sudo`,
`glab mr merge`). Since 2.1.321, a mod Claude writes in a session can run any of them without
a prompt.

There was an older gap too. On a Max-plan Mac with no managed settings, Claude Code's built-in
mod guard (`cc-plugin-sec-default`) does not load. Without the guard, a user's mod can approve
calls that deny or ask rules or `PreToolUse` hooks stop (Claude Code docs,
`plugins/mods/admin`).

The docs give one switch that closes both gaps: the guard's `allowManagedModsOnly` option, set
in managed settings. Its effect, quoted from the docs: "No mod a user brings runs its hooks:
that covers a mod in a plugin the user installed, a mod loaded with `--plugin-dir`, and a mod
Claude wrote during a session". On fenrir, Michael installed that file by hand on 2026-11-10,
right after upgrading to 2.1.322. `/status` then showed "Enterprise managed settings (file)"
and `/plugin` listed `cc-plugin-sec-default`. This design puts the file and its installer in
the repo, so that hercules and any newly provisioned Mac get the same lock.

## Goals

- Every Mac provisioned from these dotfiles carries the managed policy that turns on
  `allowManagedModsOnly`, and nothing else.
- The policy's source lives in this public repo, versioned and tested.
- Installing the policy can never leave a file that stops Claude Code from starting. Claude
  Code refuses to start when a managed settings file is invalid JSON.
- Re-running the installer on a Mac that already has the policy changes nothing. fenrir's
  hand-installed file is byte-identical to the repo's, so the installer leaves it alone.

## Non-goals

- Other managed keys, such as `allowManagedHooksOnly`, managed permission rules,
  `disableSideloadFlags` or a marketplace allowlist.
- Deploying through `chezmoi apply`. chezmoi manages `$HOME`, and the file lives under
  `/Library`, which needs root.
- An automated live test of the refusal. It would need a real `claude` start with a mod. A
  one-time manual check covers it (Migration).
- Using mods. With this lock, no user or Claude-written mod runs on these Macs. None is in use
  today: no enabled plugin ships one, and `~/.claude/dev-mods` is empty.

## Design

### 1. The policy file

`.scripts/claude-managed-settings.json` holds exactly one line and a trailing newline, the
form the docs give (`plugins/mods/admin`):

```
{"pluginConfigs":{"cc-plugin-sec-default@builtin":{"options":{"allowManagedModsOnly":true}}}}
```

- The option takes effect only inside `pluginConfigs`, keyed by the guard's id
  `cc-plugin-sec-default@builtin`. The docs state that `pluginConfigs` accepts no other form of
  the id, and a top-level `allowManagedModsOnly` key matches no documented form. A typo in the
  key path would therefore install a file that does nothing.
- The bytes match fenrir's hand-installed file, so the installer's no-op check holds there.
- `.scripts/` is already ignored by chezmoi, so the file never lands in `$HOME`.

### 2. The installer

`.scripts/install-claude-managed-settings.sh` makes
`/Library/Application Support/ClaudeCode/managed-settings.json` equal to the repo's policy
file:

1. **Validate first.** The source must parse with `/usr/bin/jq` (part of macOS) and match the
   documented shape. If not, exit non-zero and write nothing.
2. **Leave an identical target alone.** If the target exists and is byte-identical, report
   "unchanged" and exit 0 without sudo.
3. **Refuse a different target.** If the target exists and differs, print the difference and
   exit non-zero without touching it. `--replace` overwrites it; that is the way to roll out a
   future change to the policy. Nothing else writes that file on these Macs, so a difference
   means a stale policy or a hand edit, and either one should be seen before it is replaced.
4. **Install atomically, owned by root.**
   - Create the directory if missing: mode 0755, root:wheel.
   - Write a hidden temporary file in the same directory, then rename it over the target, so
     Claude Code never reads a half-written file.
   - The result is mode 0644, root:wheel. Claude Code silently skips a managed file the user
     cannot read, and only an administrator may write it.
5. **Verify.** Read the target back and compare it with the source. Exit non-zero on any
   difference.
6. **Remind.** End by telling the user to restart Claude Code sessions and check `/status`
   and `/plugin`.

It runs with sudo for the writes only. The target directory and the sudo step can be pointed
at a scratch directory with no sudo, so the test suite runs inside the Claude Code sandbox.
How that override is spelled is the plan's choice. It must not let a normal run write
anywhere other than the real path.

### 3. Provisioning

`.scripts/configure.sh`, which `provision.sh` runs on a new Mac and which already holds sudo,
gains a section that calls the installer without `--replace`. A Mac that already has a
different policy file reports it and carries on. configure.sh does not stop on it, matching
how it reports other problems.

### 4. Documentation

- AGENTS.md: the `.scripts/` rule names the installer and says that the policy is installed by
  `configure.sh` or by hand, never by `chezmoi apply`.
- README: one line under the configure.sh description, plus the uninstall command
  (`sudo rm "/Library/Application Support/ClaudeCode/managed-settings.json"`).

## Tests

`tests/install-claude-managed-settings.test.sh`, a bash suite that runs sandboxed, with one
case per behaviour. Each case names the bug it catches:

1. The repo's policy file is exactly the documented single line. Catches a wrong guard id, a
   top-level key or extra keys: a file that installs cleanly and enforces nothing.
2. An install into an empty scratch directory creates the file with identical bytes and mode
   0644, and leaves no temporary file behind. Catches a partial write or a root-only mode,
   which Claude Code would silently skip.
3. A second run reports "unchanged" and does not rewrite the file (same inode and
   modification time). Catches an installer that rewrites on every run.
4. A different existing file makes the run exit non-zero, leaves the file byte-for-byte as it
   was, and prints the difference. Catches an installer that overwrites a policy nobody has
   seen.
5. `--replace` on a different existing file replaces it. Catches a dead update path.
6. A broken source (invalid JSON, or valid JSON in the wrong shape) makes the run exit
   non-zero and writes nothing. Catches the one failure that would stop Claude Code from
   starting.
7. A configure.sh check asserts that configure.sh calls the installer without `--replace`.
   Catches a provisioning path that silently drops the lock.

The suite must fail loudly, exiting 2, when the installer or the policy file is missing,
following the repo's suite convention.

## Migration (after merge)

- **fenrir:** run `.scripts/install-claude-managed-settings.sh`. It must report "unchanged".
  The optional refusal check runs once: start `claude --debug --plugin-dir <dir>` with a
  throwaway mod, and the debug log must contain "refused by cc-plugin-sec-default: mods are
  limited to your organization's by policy (allowManagedModsOnly)".
- **hercules:** run the installer there (it asks for sudo), then restart Claude Code sessions.
  `/status` must show "Enterprise managed settings (file)" and `/plugin` → Installed must list
  `cc-plugin-sec-default`.

## Acceptance

- The suite passes sandboxed, and the default `./tests/run.sh` stays green.
- On fenrir the installer reports "unchanged".
- On hercules, `/status` and `/plugin` show the two lines above after the install.

## Known limits

- **Remote settings outrank the file.** Settings pushed from a claude.ai organization rank
  first. If they ever deliver a policy key, Claude Code ignores this file's plugin keys.
  Michael's account delivers none today (its remote settings file is `{}`).
- **Embedding apps.** With any managed file present, apps that embed Claude Code (Claude
  Desktop's Code tab, the IDE extension, the Agent SDK) stop passing their own parent settings.
- **Ignored user keys.** User-level `prependPlugins` and `appendPlugins` are ignored. Neither is
  set today.
- **No mods.** No user or Claude-written mod runs while the file is in place. To use one,
  change the policy in the repo or remove the file.
- **A broken file blocks startup.** A hand edit of the installed file that breaks its JSON stops
  Claude Code from starting until it is fixed or removed. The installer's validation covers
  only its own writes.

## Calls made while writing, not by Michael

- The main `managed-settings.json` file rather than a `managed-settings.d/` drop-in. fenrir
  already has the main file, and no MDM writes these Macs.
- Refuse a different target unless `--replace` is given, rather than always overwriting it.
- Install via a temporary file and a rename, rather than writing the target in place.
- Validate with `/usr/bin/jq` (part of macOS), so a fresh Mac needs no Homebrew `jq` first.
- Check the refusal by hand once, rather than with a live suite.
