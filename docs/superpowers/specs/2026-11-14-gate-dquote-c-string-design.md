# Pre-merge gate: read a nested shell's string as the shell hands it on

**Status:** In progress
**Date:** 2026-11-14
**Sign-off:** pending
**Branch:** `fix/gate-dquote-c-string`, in the `wt` checkout
`~/.local/share/chezmoi-fix-gate-dquote-c-string`, from `main` at `045a931`
**Related:** `2026-11-13-merge-gate-allowlist-design.md` §11.5, first bullet (the hole this
closes) and §11.2 (the attack list: four rounds each found the gate reading words differently
from the shells). `2026-11-12-xreview-trust-design.md` (the gate's threat model; not reopened).

## 1. Why

The gate denies a command that hands a gated verb to another shell (`bash -c '…'`,
`env -S '…'`). It rescans the string it hands on, but reads a different string than the inner
shell gets when that string carries an escaped `$` or backtick inside double quotes. Every
shell then runs a merge the gate allowed.

## 2. Measured

Each command was run under `/bin/zsh` (macOS zsh 5.9), Homebrew zsh 5.9.2, `/bin/bash` 3.2.57
and Homebrew bash 5.3.20, with stub `git`, `glab` and `gh` first on `PATH`, and fed to main's
gate (`045a931`).

| # | Command | Every shell | Main's gate |
|---|---|---|---|
| 1 | `` bash -c "echo \`git merge feature\`" `` | runs the merge | allows |
| 2 | `` bash -c "echo \`glab mr merge 7\`" `` | runs the merge | allows |
| 3 | `` sh -c "x=\`gh pr merge 9\`" `` | runs the merge | allows |
| 4 | `bash -c "echo \"\$(git merge feature)\""` | runs the merge | allows |
| 5 | `zsh -c "print \"\$(glab mr merge 7)\""` | runs the merge | allows |
| 6 | `` bash -c "echo \"\`git merge feature\`\"" `` | runs the merge | allows |
| 7 | `` bash -c "echo \\\\\`git merge feature\`" `` | runs the merge | allows |
| 8 | `` env -S "bash -c 'echo \`git merge feature\`'" `` | runs the merge | allows |
| 9 | `` echo "`bash -c \"git merge feature\"`" `` | runs the merge | allows |
| 10 | `bash -c "echo \$(git merge feature)"` | runs the merge | denies (by luck: the `(` left after `\$` reads as a subshell) |
| 11 | `bash -c "git mer\` and a newline, then `ge feature"` | runs the merge | denies (`lex` joins the continuation first) |
| 12 | `bash -c "echo \"merge is a word\""` | runs nothing gated | allows |
| 13 | `bash -c "git log --format=\"%h\" -1"` | runs nothing gated | allows |
| 14 | `` bash -c "echo '\`git merge feature\`'" `` | runs nothing gated | allows |
| 15 | `echo "$(bash -c \"git merge feature\")"` | runs nothing gated | allows |
| 16 | a here-document body `` `bash -c \"git merge feature\"` `` under `<<EOF` | runs nothing gated | allows |

So the bare `\$( … )` form the hole was first reported with is already denied; the open
`$( … )` forms are those inside a double-quoted string of the inner command.

## 3. Cause

Two places read a double-quoted escape differently from the shells. In double quotes, zsh and
bash drop the backslash of `\$`, `` \` ``, `\"`, `\\` and backslash-newline, and keep every
other backslash (`\!` included, in a non-interactive shell: measured).

- **`tokenize`** reads words with Python's `shlex` (posix), which inside double quotes drops the
  backslash only before `"` and `\`. It keeps `\$` and `` \` ``. `lex` has already joined every
  backslash-newline. So the `-c` string `shell_strings` hands to `scan` keeps backslashes the
  inner shell never sees, and its substitutions read as escaped text.
- **`lex`** takes a backtick body out with its `` \` ``, `\\` and `\$` undone. Inside double
  quotes the shells undo `\"` in that body too; outside them, and in a here-document body, they
  do not (measured, rows 9, 15 and 16).

## 4. Design

Deny direction only: every reading the gate makes today stays, and each change adds a reading
whose substitutions and nested shells are scanned as well. A command is decided differently
only when the new reading holds a gated verb, and then it is denied as hidden.

- **R1, the shell's words.** `tokenize` gains a reading in which each `\$` and `` \` `` inside
  double quotes loses its backslash, as in the shells. The text is rewritten before `shlex`
  reads it: such an escape is moved out of the double quotes (`"a\$b"` is read as `"a"\$"b"`),
  where `shlex` drops the backslash as the shell does. `scan` takes the shell strings of both
  readings and rescans each. The rewrite tracks quoting as `strip_redirections` does, so a
  `\\` pair, a single-quoted `\$` and an escape outside quotes keep their meaning.
- **R2, a backtick body inside double quotes** is also read with `\"` undone. Both bodies are
  rescanned.

The top-level words stay the first reading. The two readings differ only by a backslash before
`$` or a backtick, and every word the gate compares is either fixed text holding neither (a
tool, a verb, an option) or must be `literal`, which refuses both characters (a ref, a `-C`
path, a `cd` target, an endpoint, a field). The mutation names it searches a GraphQL query for
hold neither either, and a backslash before a `$` leaves their word boundaries where they were.
So a plain command is judged as today.

**Rejected: undoing the escapes in the string `shell_strings` returns.** `shlex` has already
dropped the quotes, so which backslashes stood inside double quotes is lost, and `\\` and `\"`
would be undone twice. Measured on a prototype: `` bash -c "echo \\\\\`git merge feature\`" ``
(row 7) is still allowed that way, while every shell runs the merge. R1 reads each escape in its
quote context, so it is exact for this class.

**Rejected: making R1 the only reading.** It is exact, but it drops denies main makes today
(`` bash -c "printf %s \"\\\`git merge feature\\\`\"" `` is denied by main and runs nothing). The
line closes a hole; it does not trade denies.

## 5. Accepted limits

- **`env -S`'s own grammar.** BSD `env -S` splits its string itself and has escapes no shell
  has: `\_` and `\t` separate words, `\'` does not end a single-quoted string, `${X}` expands.
  `env -S 'git\_merge\_feature'` runs the merge under every shell, and main's gate and this
  line allow it. That is a deliberate spelling, which the threat model leaves to the auto-mode
  classifier (decision Q2). R1 still reads `env -S`'s string as the outer shell hands it on.
- `eval` and a script fed to a shell stay out of scope, as the threat model says.

## 6. Tests

Rows in `tests/xreview-guard.test.sh` next to B49 and B50, each shown red on main first:
- **Denied:** rows 1 to 9 of §2.
- **Allowed:** rows 12 to 16 of §2: the inner command's own quoting, an escaped substitution
  in the inner command's single quotes, and the two places where `\"` stays escaped.

## 7. Replay

Every distinct Bash command in the Claude Code transcripts on this Mac (253,468, from 6,910
transcript files), read by main's `scan` and by a prototype of R1 and R2, each command sorted
into clear, gated, hidden or unparseable: no command changed. In 29 of them the two readings
hand a nested shell different strings; 28 are clear and one is gated (a verb at its top level)
under both. The replay is rerun on the built gate before the pre-merge review.

## 8. Decisions

- **Q1, include R2** (the backtick body inside double quotes, row 9). Recommended: yes. Same
  cause, a different site; the cold review would find it.
- **Q2, `env -S`'s own escapes.** Recommended: record as a limit (§5). Reading them needs a
  third grammar (BSD's `env -S`), and only a deliberate spelling reaches it.
- **Q3, the exact reading (R1) over undoing escapes on the returned string.** Recommended: R1,
  for row 7.
