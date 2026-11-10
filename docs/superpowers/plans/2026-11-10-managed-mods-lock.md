# Claude Code Managed Mods Lock Implementation Plan

**Status:** In progress (branch `feat/managed-mods-lock`; the dotfiles have no MR)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The repo carries the Claude Code managed policy that turns on `allowManagedModsOnly`, an installer that puts it under `/Library` safely, and a `configure.sh` call that installs it on every provisioned Mac.

**Architecture:** `.scripts/claude-managed-settings.json` is the policy. `.scripts/install-claude-managed-settings.sh` validates it, checks the installed file and every directory above it (owner, write bits, allow ACL entries, symlinks), and either reports "unchanged", refuses, or installs through a checked staged copy and a rename, with sudo for the writes only. A test mode, selected by one environment variable, points it at a scratch root without sudo, so the suite and the provision harness run it sandboxed.

**Tech Stack:** macOS `/bin/bash` 3.2, `/usr/bin/jq`, BSD `stat`/`ls -le`/`chmod +a`; zsh (`configure.sh`); bash test suites.

**Spec:** `docs/superpowers/specs/2026-11-10-managed-mods-lock-design.md` (signed off 2026-11-10).

## Global Constraints

- Policy bytes, exactly this line plus one `\n`: `{"pluginConfigs":{"cc-plugin-sec-default@builtin":{"options":{"allowManagedModsOnly":true}}}}`
- Real target: `/Library/Application Support/ClaudeCode/managed-settings.json`. A normal run (no test variable) writes nowhere else and expects owner uid 0.
- The installer is `#!/bin/bash` and runs under macOS's bash 3.2: no `mapfile`, associative arrays, `${x,,}` or `;&`.
- Every external command in the installer is called by absolute path (`/usr/bin/jq`, `/usr/bin/stat`, `/bin/ls`, `/usr/bin/cmp`, `/usr/bin/diff`, `/usr/bin/mktemp`, `/bin/cp`, `/bin/chmod`, `/bin/mkdir`, `/bin/mv`, `/bin/rm`, `/usr/bin/id`, `/usr/bin/sudo`), so a user's `PATH` cannot fake a check.
- sudo only for writes, only in a normal run. The "unchanged" path and every check run without sudo.
- Nobody on this plan runs the installer without `CLAUDE_MANAGED_SETTINGS_TEST_ROOT`, runs `sudo`, or writes under `/Library`. The spec's Migration steps are Michael's, after merge.
- Suites are executed directly (`./tests/<name>.test.sh`), never through an interpreter; the new suite runs sandboxed and carries no `# test-requires:` line. Report results as passed/total.
- New scripts and suites are mode 755; the policy file is 644.
- Never start a Bash call with `cd`; use absolute paths or `git -C`.
- Implementers do not commit. They run only their task's suites and report back; the controller re-checks `git branch --show-current` (must be `feat/managed-mods-lock`) and commits each task.

## Review Focus

1. A symlink at the target, pointing at a user-owned file with the right bytes: never "unchanged", refused even with `--replace`, and the link and its target are left alone (Task 1, case I1).
2. A symlinked directory on the walk (`ClaudeCode` → elsewhere): refused as an unsafe directory, with and without `--replace` (Task 1, case I2).
3. A broken source run with `--replace` over an existing policy: the existing file stays byte-identical (Task 1, case F, last item).
4. A mistyped option (`--repalce`) or the failure-injection variable set outside test mode: exit 2 before anything is read or written (Task 1, case I4).
5. An existing target its user cannot read, by mode or by a deny ACL entry: never "unchanged", whatever its bytes, and replaced cleanly with `--replace` (Task 1, cases I5 and G).

## Calls made in this plan, not in the spec

- Test mode is the environment variable `CLAUDE_MANAGED_SETTINGS_TEST_ROOT`, not a flag, so it reaches the installer through `configure.sh` and the provision harness stays contained. It only lowers the expected owner to the invoking user's uid, which cannot weaken the real path: that user cannot write a root-owned location.
- Failure injection is `CLAUDE_MANAGED_SETTINGS_TEST_STAGE=truncate`, refused (exit 2) without the test root.
- A target that is not a regular file (symlink, directory, anything else) is refused even with `--replace`: `mv` onto a symlink to a directory would move the policy into it.
- The walk checks the test root itself, and stops there.
- "Documented shape" means exactly one JSON value, an object, whose `.pluginConfigs["cc-plugin-sec-default@builtin"].options.allowManagedModsOnly` is the boolean `true`. Extra keys are pinned out by case A, not by the installer, so a future policy change needs `--replace`, not an installer change.
- Exit codes: 0 installed or unchanged; 1 refused or failed; 2 usage or environment error.
- The installed file's group is whatever root's `mktemp` gives it in that directory (the spec does not check the group).

---

### Task 1: The policy file and its installer

**Depends on:** none.

**Files:**
- Create: `.scripts/claude-managed-settings.json` (644)
- Create: `.scripts/install-claude-managed-settings.sh` (755)
- Test: `tests/install-claude-managed-settings.test.sh` (755)

**Interfaces:**
- Produces: `install-claude-managed-settings.sh [--replace]`. Source: `claude-managed-settings.json` in the installer's own physical directory. Environment: `CLAUDE_MANAGED_SETTINGS_TEST_ROOT=<absolute existing directory>` → target `<root>/ClaudeCode/managed-settings.json`, expected owner `$(/usr/bin/id -u)`, no sudo, walk stops at `<root>` inclusive; a relative or missing root → exit 2. `CLAUDE_MANAGED_SETTINGS_TEST_STAGE=truncate` (test mode only) truncates the staged copy to its first 10 bytes before its check.
- Output lines (exact prefixes, Task 2 and the tests key on them):
  - `unchanged: <target>` (exit 0)
  - `installed: <target>` (exit 0), then `Restart Claude Code sessions, then check /status (Enterprise managed settings (file)) and /plugin → Installed (cc-plugin-sec-default).`
  - `invalid policy source: <source>` (exit 1)
  - `refused: <target>: <reason>`, one line per failed check, then `re-run with --replace to install the repo's policy over it` when `--replace` would help (exit 1)
  - `unsafe directory: <dir>: <reason>` (exit 1, also with `--replace`)
  - `staged copy failed: <reason>; target left as it was` (exit 1)
  - `verify failed: <target>: <reason>` (exit 1)
  - `unknown option: <arg>` and `test variable set outside test mode` (exit 2)
- Reasons (exact): `not a regular file`, `symbolic link`, `not a directory`, `owner uid <actual>, expected <expected>`, `writable by group or others`, `not readable by everyone`, `allow ACL entry`, `unreadable`, `content differs from <source>` (followed by `diff -u <target> <source>` output), `mode <octal>, expected 644` (staged copy only).

- [ ] **Step 1: Write the failing suite.** `#!/usr/bin/env bash`, `set -u`, the `_pass`/`_fail` (`  PASS: …`/`  FAIL: …`) and `RESULT: N passed, M failed` idiom of `tests/provision.test.sh`; exit 2 with `missing script under test: <path>` when the installer or the policy file is absent. `T=$(mktemp -d …)`, resolved with `pwd -P`, removed on EXIT (restore write bits first: `chmod -R u+w`). `fresh()` makes a new `R` under `$T` (resolved) and sets `TGT="$R/ClaudeCode/managed-settings.json"`; `run [args]` sets `OUT` (stdout+stderr) and `RC` from `CLAUDE_MANAGED_SETTINGS_TEST_ROOT="$R" "$INST" "$@"`. `nostage` asserts no `$R/ClaudeCode/.managed-settings.json.*` remains. Cases, each naming its bug in a comment:
  - **A. policy bytes** (wrong guard id, top-level key, extra keys): `printf '%s\n' "$POLICY" | cmp -s - "$SRC/.scripts/claude-managed-settings.json"`.
  - **B. fresh install** (root-only mode, writable directory): `fresh; run` → RC 0; OUT has `installed: $TGT` and `Restart Claude Code sessions`; `cmp` with the policy; `stat -f %Lp "$TGT"` is `644`; `stat -f %Lp "$R/ClaudeCode"` is `755`; `nostage`.
  - **C. idempotent** (rewrites every run): after B, record `stat -f '%i %m'`, `sleep 1`, `run` → RC 0, OUT has `unchanged: $TGT`, OUT lacks `installed:`, inode and mtime unchanged.
  - **D. different file refused** (overwrites an unseen policy): `fresh`; `mkdir -m 755 "$R/ClaudeCode"`; write `{"pluginConfigs":{}}` + newline, mode 644; `run` → RC 1; bytes unchanged; OUT has `refused: $TGT: content differs from`, `-{"pluginConfigs":{}}`, `+$POLICY` and `--replace`.
  - **E. replace** (dead update path): D's state, `run --replace` → RC 0, `installed:`, `cmp` with the policy, mode 644, `nostage`.
  - **F. broken source** (the file that stops Claude Code starting): copy the installer into `$T/broken/` beside a `claude-managed-settings.json` holding, one per run, `{"pluginConfigs":`, an empty file, `{"allowManagedModsOnly":true}`, the policy with `"allowManagedModsOnly":"true"`, the policy keyed `cc-plugin-sec-default` (no `@builtin`), and the policy line twice on one line. Each: `fresh`, run the copy → RC 1, OUT has `invalid policy source:`, `$R/ClaudeCode` does not exist. Last item: D's state, the first broken source, `--replace` → RC 1 and the existing file byte-identical.
  - **G. unsafe target or directory with the right bytes** (blessing a policy another user could rewrite). Each from a `fresh; run` install:
    - file `chmod 664`, then `646`: RC 1, OUT has `refused: $TGT: writable by group or others`, lacks `unchanged`. `--replace` → RC 0, mode 644; next `run` → `unchanged`.
    - `chmod +a "group:everyone allow write" "$TGT"`: RC 1, `refused: $TGT: allow ACL entry`. `--replace` → RC 0, `/bin/ls -lde "$TGT"` prints one line (no ACL); next `run` → `unchanged`.
    - `chmod 775`, then `757`, on `$R/ClaudeCode`: RC 1, `unsafe directory: $R/ClaudeCode: writable by group or others`; `--replace` → RC 1, same line, target inode unchanged.
    - `chmod +a "user:$(id -un) allow add_file,delete_child" "$R/ClaudeCode"`: `unsafe directory: $R/ClaudeCode: allow ACL entry`, with and without `--replace`.
    - `chmod 777 "$R"`: `unsafe directory: $R: writable by group or others` (the walk reaches the test root).
    - deny only, `chmod +a "group:everyone deny delete" "$TGT"`: RC 0, `unchanged`.
    - a deny entry that blocks reading, `chmod +a "user:$(id -un) deny read" "$TGT"`, with the right bytes and mode 644 (a policy Claude Code cannot read): RC 1, `refused: $TGT: unreadable`, lacks `unchanged` and `content differs`. Repeat with different bytes: still RC 1, never `unchanged`. `--replace` → RC 0; next `run` → `unchanged`.
  - **H. staged copy checked before publish** (in-place copy dying midway): D's state, `CLAUDE_MANAGED_SETTINGS_TEST_STAGE=truncate run --replace` → RC 1, OUT has `staged copy failed:`, the old bytes intact, `nostage`. Same on a `fresh` root without `--replace`: RC 1, no target, `nostage`.
  - **I. Review Focus:**
    1. `mkdir -m 755 "$R/ClaudeCode"`; the policy in `$R/elsewhere.json` (644); `ln -s ../elsewhere.json "$TGT"` → RC 1, `refused: $TGT: not a regular file`; `--replace` → RC 1, `$TGT` still a symlink, `elsewhere.json` bytes unchanged.
    2. `$R/real/managed-settings.json` correct (dir 755, file 644); `ln -s real "$R/ClaudeCode"` → RC 1, `unsafe directory: $R/ClaudeCode: symbolic link`, with and without `--replace`.
    3. Covered by F's last item.
    4. `run --repalce`, `run --force`, `run replace`: RC 2, `unknown option:`, `$R/ClaudeCode` absent. `env -u CLAUDE_MANAGED_SETTINGS_TEST_ROOT CLAUDE_MANAGED_SETTINGS_TEST_STAGE=truncate "$INST"` → RC 2, `test variable set outside test mode`. A relative test root (`CLAUDE_MANAGED_SETTINGS_TEST_ROOT=rel`) → RC 2.
    5. Installed file `chmod 200`: RC 1, `refused: $TGT: not readable by everyone` and `refused: $TGT: unreadable`, lacks `unchanged` and `content differs`; `--replace` → RC 0, mode 644, bytes equal the policy.
- [ ] **Step 2: Run it to see it fail.** `./tests/install-claude-managed-settings.test.sh` exits 2 (`missing script under test`).
- [ ] **Step 3: Create the policy file** with the exact bytes from Global Constraints, mode 644.
- [ ] **Step 4: Implement the installer**, in this order (spec §2):
  1. Parse arguments (`--replace` only) and the test variables; exit 2 on anything else.
  2. Validate the source: `/usr/bin/jq -e -s 'length == 1 and (.[0] | type == "object") and (.[0].pluginConfigs["cc-plugin-sec-default@builtin"].options.allowManagedModsOnly == true)'`. The same function validates the staged copy.
  3. Walk directories from the target's directory (its parent when the directory is missing) up to `/`, or to the test root inclusive: each must not be a symlink, must be a directory, owned by the expected uid, `mode & 022 == 0`, with no allow ACL entry. Any failure → `unsafe directory:` and exit 1, whatever the flags.
  4. If the target exists: not a regular file (or a symlink) → `refused: …: not a regular file`, exit 1, whatever the flags. Otherwise check owner, `mode & 022 == 0`, `mode & 0444 == 0444`, no allow ACL entry, that the invoking user can read it (`[ -r ]`, which honours deny ACL entries; failing is the reason `unreadable`), and `cmp`-equality with the source. The content check and its `diff` run only on a readable target; an unreadable one has already failed. All pass → `unchanged:`, exit 0. Else print every failed reason; without `--replace` exit 1.
  5. Install: create a missing directory (`/bin/mkdir -m 0755`); stage with `/usr/bin/mktemp "<dir>/.managed-settings.json.XXXXXX"`, `/bin/cp` the source into it, `/bin/chmod 0644`; an EXIT trap removes a staged file that was not published. Check the staged copy (valid shape, `cmp`-equal, owner, mode exactly 644, no allow ACL entry); any failure → remove it, `staged copy failed:`, exit 1. Then `/bin/mv -f` it over the target.
  6. Re-run checks 3 and 4 on the result; a failure → `verify failed:`, exit 1. Then `installed:` and the restart line.
  - The writes in step 5 go through one helper that prefixes `/usr/bin/sudo` in a normal run and nothing in test mode.
  - Allow ACL entry: a line after the first of `/bin/ls -lde <path>` that starts with optional spaces, digits and `:` and has a space-delimited field `allow`. Erring towards "allow" is the safe direction.
- [ ] **Step 5: Run it to see it pass.** `./tests/install-claude-managed-settings.test.sh`: all pass; report passed/total. Also `/bin/bash -n .scripts/install-claude-managed-settings.sh`.
- [ ] **Step 6: Commit** (controller): `git -C <checkout> add .scripts/claude-managed-settings.json .scripts/install-claude-managed-settings.sh tests/install-claude-managed-settings.test.sh`; `git -C <checkout> commit -m "Add the Claude Code managed mods lock policy and its installer"`.

### Task 2: Provisioning and documentation

**Depends on:** Task 1 (it extends Task 1's suite and calls its installer).

**Files:**
- Modify: `.scripts/configure.sh` (a new section right after the firewall block in "Security Settings")
- Modify: `tests/provision.test.sh` (`cfg()`, setup, a new section K)
- Modify: `tests/install-claude-managed-settings.test.sh` (case J)
- Modify: `AGENTS.md` (the `.scripts/` rule), `README.md` ("macOS Hardening" list)

**Interfaces:**
- Consumes: the installer's interface and output lines (Task 1).
- Produces: `configure.sh` log lines `Installing the Claude Code managed policy...`, `✓ Claude Code managed policy in place`, and on failure `Claude Code managed policy NOT installed — review the output above; re-run .scripts/install-claude-managed-settings.sh, with --replace to overwrite`.

- [ ] **Step 1: Write the failing tests.**
  - Task 1's suite, **J. configure.sh calls the installer without `--replace`** (a provisioning path that drops the lock): the invocation lines of `.scripts/configure.sh` are those containing `install-claude-managed-settings.sh` whose first non-blank text is neither `#` nor `log_` (the failure message names the script and `--replace` on purpose). At least one exists, and none contains `--replace`. The behavioural proof is provision section K below.
  - `tests/provision.test.sh`: setup creates `$T/managed`; `cfg()` passes `CLAUDE_MANAGED_SETTINGS_TEST_ROOT="$T/managed"` in its `env -i` list (containment: without it the real installer reads `/Library` and calls the sudo stub). New section **K. configure.sh installs the Claude Code managed policy**:
    - `rm -rf "$T/managed/ClaudeCode"` (sections G–J have installed there already), `cfg fenrir fenrir fenrir fenrir`: `has "✓ Claude Code managed policy in place"`; `$T/managed/ClaudeCode/managed-settings.json` is `cmp`-equal to `$SRC/.scripts/claude-managed-settings.json`.
    - that file replaced by `{"pluginConfigs":{}}`: `cfg …`: `has "Claude Code managed policy NOT installed"`, the file still holds `{"pluginConfigs":{}}`, and `has "Configuring keyboard settings"` (configure.sh carried on; under this harness it never reaches its last line, because the LaunchAgents glob has no match).
    - `$CALLS` and `$MUTLOG` contain no `ClaudeCode` (no sudo, nothing outside the scratch root).
- [ ] **Step 2: Run them to see them fail.** `./tests/install-claude-managed-settings.test.sh`: J fails. `./tests/provision.test.sh`: K fails.
- [ ] **Step 3: Implement.**
  - `configure.sh`: a `# ===` section header "Claude Code managed policy" with a one-line comment (why: limits mods to the organization's, see the spec), `log_info` the first line, then `if "${0:A:h}/install-claude-managed-settings.sh"; then` the success line, `else` `log_warn` the failure line, `fi`. No `--replace`; `set -e` must not stop the script on a refusal.
  - `AGENTS.md`: in the `.scripts/` rule, one sentence: `install-claude-managed-settings.sh` installs `claude-managed-settings.json`, the Claude Code mods lock, into `/Library/Application Support/ClaudeCode/`; `configure.sh` runs it, or run it by hand (`--replace` overwrites a different policy); `chezmoi apply` never does.
  - `README.md`, "macOS Hardening" list: one bullet saying configure.sh installs the Claude Code managed policy that limits mods to the organization's (`allowManagedModsOnly`) via `.scripts/install-claude-managed-settings.sh`, refusing a different existing policy unless run with `--replace`; then the uninstall command `sudo rm "/Library/Application Support/ClaudeCode/managed-settings.json"`.
- [ ] **Step 4: Run them to see them pass.** `./tests/install-claude-managed-settings.test.sh` and `./tests/provision.test.sh` (61 assertions before this task): all pass; report passed/total.
- [ ] **Step 5: Commit** (controller): `git -C <checkout> add .scripts/configure.sh tests/provision.test.sh tests/install-claude-managed-settings.test.sh AGENTS.md README.md`; `git -C <checkout> commit -m "Install the managed mods lock from configure.sh"`.

### Finish

- [ ] `./tests/run.sh`, then the heavy suites by exact name (AGENTS.md: before every pre-merge review): `./tests/run.sh xreview git-forge-guard wt-functions`. Report passed/total.
- [ ] Final whole-branch review (sp-architect), then Codex pre-merge on `main...feat/managed-mods-lock`. Record rulings in this plan under "Rulings" (no MR).
- [ ] Set the spec's and this plan's Status to `Implemented (branch feat/managed-mods-lock; the dotfiles have no MR)`, mark this plan executed, commit, then `git -C <checkout> push origin feat/managed-mods-lock`.
- [ ] Final report: the spec's Migration steps for Michael (fenrir: installer must say `unchanged`; hercules: install, restart, `/status`, `/plugin`), the out-of-scope `configure.sh` LaunchAgents glob failure (zsh `nomatch` with no `be.netronix.*.plist`), and the harness worktree cleanup after merge.
