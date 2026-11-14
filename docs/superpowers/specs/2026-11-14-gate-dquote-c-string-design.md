# Pre-merge gate: read a nested shell's string as the shell hands it on

**Status:** Implemented (branch `fix/gate-dquote-c-string`; its PR is opened after the pre-merge review)
**Date:** 2026-11-14
**Sign-off:** the driver session, on Michael's delegation, 2026-11-14: Q1 to Q7 as recommended
(§8). Codex spec review: approve in round 1 (`xr-1794658687-c52304dd`), before the cold review
added R3, §5's further limits and §9; the plan review (approve in round 2,
`xr-1794660626-2e107721`) covers those. R4 (Q7) came from the task review, after both; the
pre-merge review is its first cross-model review.
**Branch:** `fix/gate-dquote-c-string`, in the `wt` checkout
`~/.local/share/chezmoi-fix-gate-dquote-c-string`, from `main` at `045a931`
**Related:** `2026-11-13-merge-gate-allowlist-design.md` §11.5, first bullet (the hole this
closes) and §11.2 (the attack list: four rounds each found the gate reading words differently
from the shells). `2026-11-12-xreview-trust-design.md` (the gate's threat model; not reopened).

## 1. Why

The gate denies a command that hands a gated verb to another shell (`bash -c '…'`,
`env -S '…'`). It rescans the string it hands on, but reads a different string than the inner
shell gets when that string carries an escaped `$` or backtick inside double quotes. Every
shell then runs a merge the gate allowed. The reviews found two more readings of double quotes
that differ from the shells': a quote inside a `${…}` that stands inside double quotes, and a
`$(` split by a line continuation (§3). This line closes those four; other quote forms are
recorded limits (§5).

## 2. Measured

Each command was run under `/bin/zsh` (macOS zsh 5.9), Homebrew zsh 5.9.2, `/bin/bash` 3.2.57
and Homebrew bash 5.3.20, with stub `git`, `glab` and `gh` first on `PATH` that record their
arguments one by one, and fed to main's gate (`045a931`).

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
| 17 | `bash -c "${x:-"git merge y"}"` | runs the merge | allows |
| 18 | `echo "${x:-"'"}"; git merge y; echo "'" #"` | runs the merge | allows |
| 19 | `printf '%s\n' "${MSG:-"it's done"}"` | runs nothing gated | allows |
| 20 | `bash -c 'echo "$\` and a newline, then `(git merge y)"'` | runs the merge | allows |

So the bare `\$( … )` form the hole was first reported with is already denied; the open
`$( … )` forms are those inside a double-quoted string of the inner command.

## 3. Cause

Four places read double quotes differently from the shells. In double quotes, zsh and bash
drop the backslash of `\$`, `` \` ``, `\"`, `\\` and backslash-newline, and keep every other
backslash (`\!` included, in a non-interactive shell: measured).

- **`tokenize`** reads words with Python's `shlex` (posix), which inside double quotes drops the
  backslash only before `"` and `\`. It keeps `\$` and `` \` ``. `lex` has already joined every
  backslash-newline. So the `-c` string `shell_strings` hands to `scan` keeps backslashes the
  inner shell never sees, and its substitutions read as escaped text.
- **`lex`** takes a backtick body out with its `` \` ``, `\\` and `\$` undone. Inside double
  quotes the shells undo `\"` in that body too; outside them, and in a here-document body, they
  do not (measured, rows 9, 15 and 16).
- **`lex`** ends a double-quoted string at the next `"`. Inside a `${…}` that stands in double
  quotes, the shells open a nested string there instead (row 17), and a `'` inside the nested
  string is text, which `lex` takes for the start of a single-quoted one (row 18). The shells'
  rule depends on the operator: after `:-` a `'` is literal, after `/` it quotes (measured).
- **`lex`** finds a `$(` by looking two characters ahead in the raw text. Inside double quotes
  bash joins a line continuation first, so a `$`, a backslash-newline and a `(` are a
  substitution there, while zsh reads text; in an unquoted here-document body both join. `lex`
  reads text (row 20: the inner bash joins it, under every outer shell).

## 4. Design

Deny direction only: every reading the gate makes today stays, `crude`'s included. R1 and R2
add a reading whose substitutions and nested shells are scanned as well, and a command is
decided differently only when the new reading holds a gated verb; it is then denied as hidden.
R3 adds a deny for text the gate cannot read exactly, when `crude` finds a gated verb in it.

- **R1, the shell's words.** `tokenize` gains a reading in which each `\$` and `` \` `` inside
  double quotes loses its backslash, as in the shells. The text is rewritten before `shlex`
  reads it: such an escape is moved out of the double quotes (`"a\$b"` is read as `"a"\$"b"`),
  where `shlex` drops the backslash as the shell does. `scan` takes the shell strings of both
  readings and rescans each. The rewrite tracks quoting as `strip_redirections` does, so a
  `\\` pair, a single-quoted `\$` and an escape outside quotes keep their meaning.
- **R2, a backtick body inside double quotes** is also read with `\"` undone. Both bodies are
  rescanned.
- **R3, a quote inside a double-quoted `${…}`.** `lex` reads the text as today and counts the
  `${` it meets inside double quotes; a `"` or `'` while one is open marks the text. An escaped
  character never counts (`\}` does not close the `${`). `scan` denies a marked text that
  `crude` finds a gated verb in, read as written or with its newlines flattened (`crude` reads
  within a line, and a multi-line `$( )` can part the tool from its verb), with a reason naming
  the case, at the top level and in a nested string alike; any other marked text is read as
  today. An exact reading would model each operator's quoting rule (§3) in two shells; the
  fallback needs none.
- **R4, a line continuation inside `$(` or `${`.** In double quotes and in an unquoted
  here-document body, `lex` looks for `$(`, bash 5.3's `${ cmd; }` and R3's `${` past
  backslash-newline pairs (ruling Q7). A `$(` or `${ ` found only that way marks the text as
  R3's quote does, and `lex` reads on as main does: zsh does not join it inside double quotes,
  so bash's reading may not replace zsh's, and reading on as main does is what keeps every deny
  main makes. `scan` applies R3's deny to a mark from the command and from each expanding
  here-document body. In plain shell text the lookaheads stay as they are (§5).

The top-level words stay the first reading. The two readings differ only by a backslash before
`$` or a backtick, and every word the gate compares is either fixed text holding neither (a
tool, a verb, an option) or must be `literal`, which refuses both characters (a ref, a `-C`
path, a `cd` target, an endpoint, a field). The mutation names it searches a GraphQL query for
hold neither either, and a backslash before a `$` leaves their word boundaries where they were.
So a plain command is judged as today, unless R3 or R4 denies it.

**R3's cost.** A command with a quote in a double-quoted `${…}` that also mentions a gated verb
anywhere is denied where main allowed it, read-only verbs included, since `crude` matches a
tool and a word: `git commit -m "${MSG:-"merge notes"}"`,
`base="${BASE:-"$(git merge-base HEAD origin/main)"}"`, or a loop over
`"${(f)"$(gh pr list …)"}"`. No command in the transcripts (§7) holds such a quote; their
`${(f)"…"}` uses stand outside double quotes, where `lex` reads them as the shells do.

**R1's cost.** Every word after a `-c` string is read as a shell string, as on main, so R1 reads
`$0` and `$1` too: `bash -c 'echo' "\`git merge feature\`"` runs nothing, and is denied. So is
`env -S "echo \`git merge feature\`"`, whose `env` runs no shell. Neither is a command an agent
writes, and the transcripts hold none.

**Rejected: undoing the escapes in the string `shell_strings` returns.** `shlex` has already
dropped the quotes, so which backslashes stood inside double quotes is lost, and `\\` and `\"`
would be undone twice. Measured on a prototype: `` bash -c "echo \\\\\`git merge feature\`" ``
(row 7) is still allowed that way, while every shell runs the merge. R1 reads each escape in its
quote context, so it is exact for this class.

**Rejected: R3 as unreadable text** (a `ValueError`, as unbalanced quotes raise, which `crude`
then decides). `crude` reads `lex`'s text too, so the error took that reading away:
`git -C "$(`, a newline, `pwd`, a newline, `)" merge feature; printf '%s\n' "${MSG:-"done"}"`
is denied by main, and was allowed (the plan review, round 1, found it).

**Rejected: R4 as a joined reading that replaced the raw one** (a `$(` frame opened past the
continuation). zsh reads `"$\`, a newline and `("` as text, so the frame swallowed commands zsh
runs: `x="$\`, a newline, `("; git merge y; echo ")"`, which main denies, was allowed, and a
`$((` joined that way skipped the arithmetic check and opened a here-document that hid the next
line (the task review's re-review, round 1).

**Rejected: making R1 the only reading.** It is exact, but it drops denies main makes today
(`` bash -c "printf %s \"\\\`git merge feature\\\`\"" `` is denied by main and runs nothing). The
line closes a hole; it does not trade denies.

## 5. Accepted limits

Each holds on main today; the cold review of this design found the second to fourth, and each was
verified by running it. They are deliberate spellings, which the threat model leaves to the
auto-mode classifier (rulings Q2, Q5, Q6).
- **`env -S`'s own grammar.** BSD `env -S` splits its string itself, with escapes no shell has:
  `\_` separates words outside quotes and is a blank inside double quotes, `\t` is a tab that
  separates nothing, `\'` does not end a single-quoted string, and `${X}` expands.
  `env -S 'git\_merge\_feature'` runs the merge, and so does
  `env -S 'bash -c "git\tmerge\tfeature"'`, where the tabs reach bash.
  Main's gate and this line allow both. R1 still reads `env -S`'s string as the outer shell
  hands it on.
- **zsh's `$'…'`.** zsh drops the backslash of an escape it does not know (`` \` ``, `\ `,
  `\g`), and reads `\c`, `\C-` and `\M-` its own way; the gate decodes as bash does. Under zsh,
  `bash -c $'echo \`git merge x\`'` and `$'\git' merge x` run the merge. The allowlist spec's
  §11.5 records the NUL case of this divergence.
- **bash's `$"…"`.** bash reads a locale string as a double-quoted one; the gate reads a `$`
  before it. `bash -c '$"git" merge x'` runs the merge in every shell.
- **Top-level spellings outside quoting.** A glued empty substitution (`git merge$() x`, every
  shell), a zsh brace group glued to the command word (`{git merge x}`), and brace expansion
  (`bash -c {'git merge x',}`, every shell).
- **Line continuations in plain shell text.** A backslash-newline inside `$((`, `$'`, `<(`, a
  bash 5.3 `${ ` or a here-document operator is joined by the shells, while `lex` reads the
  parts. Most such spellings are denied anyway, since a lone `(` is a token.
- **A hex-escaped verb under R3's or R4's mark.** The mark is acted on by `crude`, which does
  not decode a `$'…'` that `lex` reads as quoted text: `echo "$\`, a newline, then
  `($'\x67it' merge y)"` runs the merge under bash, and
  `echo "${x:-"'"}"; $'\x67it' merge y; echo "'" #"` under every shell; main and this line
  allow both.
- `eval` and a script fed to a shell stay out of scope, as the threat model says.

## 6. Tests

Rows in `tests/xreview-guard.test.sh` next to B49 and B50, each new deny shown red on main first:
- **Denied:** rows 1 to 9, 17, 18 and 20 of §2; row 18 with an escaped `}` in the default
  value; row 17 inside one more `bash -c '…'` with a line continuation between `$` and `{`; row
  18 with a multi-line `git -C "$(…)"`; row 20 in a here-document body; a split bash 5.3
  `${ git merge y; }` inside double quotes; a `-c` string after a single-quoted `"`, which pins
  that R1's rewrite skips single quotes; and, each denied by
  main already, R3's and R4's rejected forms' commands (§4): they pin that neither takes a
  reading away.
- **Allowed:** rows 12 to 16 and 19 of §2: the inner command's own quoting, an escaped
  substitution in the inner command's single quotes, the two places where `\"` stays escaped,
  and a nested quote in a command that mentions no gated verb.

## 7. Replay

Every distinct Bash command in the Claude Code transcripts on this Mac (253,468, from 6,910
transcript files), read by main's `scan` and by this line's, each command sorted into clear,
gated, hidden or unparseable: no command changed, for a prototype of R1 and R2 and for each
built round (R1 to R3, then R4's two forms). In 29 of them the two readings hand a nested shell
different strings; 28 are clear and one is gated (a verb at its top level) under both. No
command holds a quote inside a double-quoted `${…}` as `lex` reads it (a rough scan before the
build counted 32, JavaScript template literals and the like).

**No command main denies is allowed** (the driver's condition for shipping). Measured against
main's gate on 123,566 commands: every case of this line and both review rounds, and a composed
corpus of 18 wrappers (the nested shells, substitutions, here-documents and quote forms of
§2 to §4) nested up to three deep around four gated verbs in five forms. The final gate turns
none from deny to allow; R4's rejected form turned 1,827. The suite's rows run against main's
gate fail only on this line's new denies.

## 8. Rulings

By the driver session on Michael's delegation, 2026-11-14, each as recommended:
- **Q1:** include R2 (row 9): same cause, a different site.
- **Q2:** `env -S`'s own escapes are a limit (§5): reading them needs a third grammar, and only
  a deliberate spelling reaches it.
- **Q3:** the exact reading R1, not undoing escapes on the returned string (row 7).
- **Q4:** fix rows 17 and 18 here with R3's fallback, with the transcripts' count in §7.
- **Q5:** zsh's `$'…'` and bash's `$"…"` are limits (§5).
- **Q6:** the top-level spellings outside quoting are limits (§5).
- **Q7:** fix row 20 here (R4), with the helper that joins R3's `${`; line continuations in plain
  shell text stay limits.

## 9. Direction for a future line

Not built here. This line and the allowlist line hit the same failure, five rounds in a row: a
review of the gate's grammar found a command that one of the shells reads differently from it.
That was rounds 1 to 4 of the allowlist line (its §11.2) and this line's cold review, which found
three more readings (§3, §5) beyond the one it set out to close. The gate reimplements three
shells' lexers in Python, and each fix moves the divergence instead of closing it. The
direction: let zsh, the Bash tool's shell, lex the command itself. zsh's `${(z)…}` splits text
into words and operators as its parser does, and `(Q)` removes one level of quoting, so the gate
would read zsh's words instead of its own. That leaves bash (scripts, `bash -c`) as a second
reader to account for, and it costs a zsh process per gated command.
