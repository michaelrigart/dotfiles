# tagteam integration

**Status:** Implemented (branch `feat/tagteam-integration`). The dotfiles have no MR, so the
rulings are recorded under "Implementation notes" at the end.

**Date:** 2026-10-13

## Goal

Fit tagteam into the dotfiles. tagteam is Michael's multi-account switcher for Claude Code;
the Brewfile installs it (96893a8). This spec covers three things. tagteam's credential files
stay out of agent reach and out of transcripts, as far as the existing boundary allows. The
live account and its usage show in the Claude Code statusline. And its auto-switch settings
are managed in chezmoi, so an always-on auto-switch can be added later without new decisions.

## Decisions

Michael, 2026-10-13:

- **No directory mapping.** There is no `tagteam map`, and no `tagteam shell-init` wrapper
  in `dot_zshrc`. `claude` keeps starting as the live login everywhere, Herdr panes included.
- **Auto-switching comes later.** No launchd agent now. When it is added, it switches at
  95%.
- **Strategy `consume-first`**, confirmed at sign-off. It switches to the account whose weekly window resets
  soonest, while that account is under the threshold. The weekly window is the one Michael
  runs out of: on 2026-10-13 it stood at 86%, burning about 1.2 points an hour, with almost
  4 days to the reset. `best` would spread usage across accounts, so more capacity would
  expire unused.

## Findings this design rests on

Measured on 2026-10-13 with tagteam 20261013.2030.0 and Claude Code 2.1.296.

1. **Hooks and the statusline still run in `tagteam run` profiles.** `settings.json` is
   shared with profiles, and every hook and the statusline are invoked by absolute
   `$HOME/.claude/…` path. Doctor warns that the guard scripts are not on a share list, but
   that needs no action.
2. **tagteam does not work inside the sandbox.** Opening its store needs write access under
   `~/.local/share/tagteam`, which the sandbox denies: `history` and `statusline` both fail
   with `store error: unable to open database file`. Only `doctor` and `config` work there.
   The failure is visible, so tagteam needs no `excludedCommands` entry. An agent cannot
   switch accounts from inside the sandbox; running tagteam outside it is an escape like
   any other and is judged by the classifier.
3. **Three places can hold a login in plaintext, and agents can read them today.**
   `~/.local/share/tagteam/rescue/`, `~/.local/share/tagteam/displaced/` and
   `~/.local/share/tagteam/sessions/<id>/.credentials.json`. None of them is on a deny list.
4. **The Keychain is readable from the sandbox.** Run sandboxed,
   `security find-generic-password -w` succeeds for tagteam's items (service `tagteam`) and
   for Claude Code's own login (`Claude Code-credentials`). The probe sent the secret to
   `/dev/null` and printed only the exit code. The sandbox has no Keychain control. Cutting
   Keychain access off would also break `gh` and `glab`, which keep their tokens there. This
   predates tagteam; what tagteam adds is every stored account and its previous token
   generation.

## Design

### 1. Credential files

Add these rules to `permissions.deny` in `dot_claude/modify_private_settings.json`, each as
a `Read`/`Edit` pair, matching the existing ones:

```
Read(~/.local/share/tagteam/rescue/**)                    Edit(…same…)
Read(~/.local/share/tagteam/displaced/**)                 Edit(…same…)
Read(~/.local/share/tagteam/sessions/*/.credentials.json) Edit(…same…)
```

Claude Code copies `Read()` deny rules into the sandbox's read-deny list, the way
`Read(~/.ssh/**)` already appears there. One rule therefore covers both the Read tool and
sandboxed Bash. `tagteam run` keeps working: the profile's Claude Code process reads its own
credential itself, outside both the Read tool and the sandbox.

### 2. Keeping secrets out of the transcript

These rules follow the existing `op read*` block and its rationale: a secret must never
enter the transcript.

```
Bash(tagteam *export*)
Bash(security *find-generic-password*)    Bash(/usr/bin/security *find-generic-password*)
Bash(security *find-internet-password*)   Bash(/usr/bin/security *find-internet-password*)
Bash(security *dump-keychain*)            Bash(/usr/bin/security *dump-keychain*)
Bash(security *export*)                   Bash(/usr/bin/security *export*)
```

The leading `*` also matches global options placed before the verb (`tagteam --json export -`,
`security -q find-generic-password`). `tagteam export -` writes every login to stdout, so a
plain export is denied as well. `tagteam purge` and `remove` are left to the classifier, as
deletes already are; they also cannot run inside the sandbox (finding 2).

This protects only the transcript, not the secret. A script can still call `security`
itself. See "The Keychain: accepted as known" below.

### 3. Statusline segment

`dot_claude/executable_statusline.sh` gains one segment after the model:

- Its text is the first line of `tagteam --no-color statusline`, which defaults to
  `{account} · 5h {5h}% · 7d {7d}%{stale}`. That command reads only stored data, with no
  network and no Keychain access, and took 15 ms.
- It is shown in Tokyo Night teal (`#73daca`), or red (`#f7768e`) once any percentage in it
  reaches 90.
- It is left out when `tagteam` is not installed, exits non-zero, or prints nothing, and the
  rest of the line renders as before. That includes a statusline run inside the sandbox
  (finding 2).
- It is also left out when it does not fit. The renderer pads up to `$COLUMNS` but never
  truncates anything. So the segment is added only if the line, segment included, takes at
  most `$COLUMNS - 2` visible columns. That leaves room for the closing separator and at
  least one column of filler, so a line with the segment always ends exactly at `$COLUMNS`
  (at `$COLUMNS - 1`, the renderer emits neither and the line ends one column short). Otherwise the
  line is exactly what it is today, overflow included: a long branch name can already push it
  past the edge, and changing that is out of scope.

### 4. Managed settings

A new file, `dot_config/private_tagteam/private_config.toml`, deploys with directory mode
0700 and file mode 0600, because `doctor` checks that tagteam's directories are private:

```toml
[autoswitch]
threshold = 95
strategy = "consume-first"
```

Only the keys that differ from tagteam's defaults are set. `tagteam config list` then reports
both keys with source `global`. Settings change through chezmoi from now on: a
`tagteam config set` shows up as a chezmoi diff, and the next apply offers to put the managed
file back.

## Out of scope

- **A launchd agent for `tagteam auto`.** It comes later (see Decisions). The settings above
  are what it will use.
- **`map` and `shell-init`.** Ruled out (see Decisions).
- **`claude-code.md`.** It stays unchanged. Agents have no use for tagteam, and inside the
  sandbox it fails visibly.
- **Follow-ups in the tagteam repository.** The tested Claude Code version is 2.1.292, and
  2.1.296 is installed. zsh completions belong in the Homebrew formula. SECURITY.md should
  say that the stored logins are readable by anything that can run `/usr/bin/security` as the
  user.

## The Keychain: accepted as known

Finding 4 is not closed by this spec. At sign-off on 2026-10-13, Michael accepted it as
known. The rules in section 2 keep secrets out of the transcript, and the exposure stays
recorded here. Claude Code's own login and the `gh`/`glab` tokens are exposed the same way,
and nothing at the settings level closes it.

The alternative was a spec in the tagteam repository moving its vault to a separate keychain
that stays locked between uses. It was not taken, because it would stop `auto` from running
unattended.

## Testing

- **`tests/claude-settings.test.sh`:** `EXP_DENY` gains every new rule. The exact-list
  assertion fails if one goes missing.
- **New `tests/statusline.test.sh`:** stubs `tagteam` on `PATH` and asserts:
  - normal output → the segment is present, in teal;
  - a percentage of 90 or more → the segment is red;
  - exit 1, empty output, and no `tagteam` at all → no segment, and the rest is unchanged;
  - a `COLUMNS` too narrow for the segment (for example 80 columns, directory `chezmoi`,
    branch `feat/tagteam-integration`, a model with an effort level, and
    `personal · 5h 25% · 7d 86%`) → no segment, and the output is byte-identical to the same
    input without `tagteam`;
  - the exact boundary: the line with the segment at `COLUMNS - 2` columns → shown, with
    visible width `COLUMNS`; at `COLUMNS - 1` → no segment;
  - whenever the segment is shown, the visible width equals `COLUMNS`.

  The suite exits 2 if `statusline.sh` is missing.
- **`tests/live-credential-boundary.test.sh`:** probes the three tagteam paths and reports
  each as `READABLE`, `DENIED` or `ABSENT`, using `dd`'s errno to tell `EPERM` from
  `ENOENT`. Only `READABLE` counts as a failure. `ABSENT` means the path does not exist yet,
  so it was not measured. A sandboxed suite cannot create a fixture there itself.
- **Live, after `chezmoi apply`, in a fresh sandboxed session:**
  - `live-credential-boundary` passes, with a planted probe file under `rescue/` reporting
    `DENIED`. The file is planted outside the sandbox and removed afterwards.
  - The statusline shows the segment.
  - `tagteam config list` shows `threshold` and `strategy` with source `global`.
  - `tagteam doctor` reports the directories as private.

## Implementation notes

Built from `docs/superpowers/plans/2026-10-13-tagteam-integration.md` on 2026-10-13/14.
Codex approved the spec (round 3) and the plan (round 2). Every task passed its own review,
and a final whole-branch review followed. The rulings made during execution:

- **15 deny rules, not 17.** The plan's interface note miscounted. The listed rules are 6
  `Read`/`Edit` rules for the three tagteam paths, 1 `tagteam` rule and 8 `security` rules, and
  `tests/claude-settings.test.sh` pins exactly those.
- **The mid-pattern `*` matches the plain command.** The ruling rested on the Claude Code
  permissions docs ("a `*` in a Bash rule matches any text"). The final whole-branch review
  then traced the 2.1.296 matcher: each `*` becomes `.*`, anchored `^…$`. So `Bash(security *find-generic-password*)`
  also denies a plain `security find-generic-password -w`. The plan's after-merge check 3
  confirms this end to end.
- **Indirect `security` calls stay open.** `env security …`, `xcrun security …` and
  `sh -c …` pass the prefix rules. That is within the transcript-only scope accepted under
  "The Keychain: accepted as known"; Claude Code's own wrapper stripping
  (`command`, `timeout`, `nice`, …) covers the common forms.
- **The statusline test locates jq by probing, not with `command -v`.** On this machine
  `command -v jq` finds a mise shim, which fails under `env -i`. The suite takes the first
  `type -ap jq` candidate that runs under `env -i` and exits 2 if there is none.
- **No timeout around `tagteam statusline`.** It reads stored data only: 15 ms measured, no
  Keychain, no network, and a WAL store with a 5 s busy timeout. Revisit this when the
  launchd auto-switch agent is specified, because it will write to the same store.
- **The sanitiser is broader than the spec's "ANSI escapes".** It strips terminated and
  unterminated OSC, any CSI, and other `ESC` sequences, then every C0 control. Malformed
  input (an OSC containing a stray `ESC`, a truncated CSI), DCS/SOS/PM/APC bodies and C1
  controls in their two-byte UTF-8 form can still leave stray text or a shorter segment, but
  never a wrong width. tagteam runs with `--no-color`, and its format emits none of them. The
  test stub writes escapes with `printf '%b'` and `\x1b`, which relies on macOS `/bin/sh`
  being bash. On a dash `/bin/sh` those tests would fail loudly, never pass falsely.
- **The segment is shown only when the line's width can be established.** The renderer
  counts codepoints, not terminal cells. So a double-width character (CJK, Hangul, most
  emoji) would make a line that "fits" overflow, which the pre-merge review caught. The
  segment is now left out whenever the line contains a UTF-8 lead byte E3–ED or F0–F4, which
  covers U+3000–U+DFFF and every 4-byte character. Measuring true cell width would need a
  wcwidth table in bash 3.2, and this keeps a line without the segment exactly as it was. The
  cost: a line containing CJK or emoji never shows the segment. A rare wide character outside
  those ranges, such as a fullwidth `EF` form, could still overflow by its extra cell.
- **The probes classify by errno, never by `stat`.** The sandbox denies metadata of a denied
  file and returns it only for directories. So the boundary suite reads each candidate
  directly, both inside `rescue/` and `displaced/` and inside each session directory, and
  classifies the result by `dd`'s error. A missing path reports ENOENT even under a deny.
- **The deployed modes rest on the source spelling.** `private_` on the directory and the
  file gives 0700 and 0600; the after-merge `tagteam doctor` check verifies them.
- **`.[!.]*` skips names that start with `..`.** tagteam writes flat `<id>.json` entries:
  the task review traced `displace.rs` and the final review traced `rescue.rs`. So nothing it
  creates is missed.
- **The dated security-posture spec keeps its "(exit 12)".** Specs are point-in-time.
  `AGENTS.md` and the suite header now say "12 or more".
