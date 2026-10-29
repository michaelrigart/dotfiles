# The push guard catches escaped spellings

**Status:** In progress
**Date:** 2026-10-29
**Branch:** `fix/push-guard-escaped-spellings`

Design approved by Michael on 2026-10-29. It tightens rule 4 (`dot_claude/git-push-guard.py` and
the fast path in `dot_claude/executable_git-forge-guard.sh`) of
[spec 2026-10-28](2026-10-28-reload-functions-merged-deletes-design.md), section 2.

## Problem

After Michael's apply of 9702750, that spec's live check 4 failed:
`$'\x67it' -C <tmp repo> push --force-with-lease=refs/heads/done:<sha> origin --delete done` ran
unprompted, with the hook silent and the classifier accepting. The dotfiles `main` reports
`protected: false`, with 0 rulesets. These are main's verdicts, measured through the whole hook:

| Command | Main | Here |
|---|---|---|
| `$'\x67it' push origin --delete wip`, `$'\147it' push …`, `$'\x67it' push --force origin main` | silent | deny |
| `${X:-gi}t push origin --delete wip`, `$G push …` | silent | deny |
| `git $'\x70ush' …`, `git pu$'\x73'h …` (the helper alone denies) | silent | deny |
| `git pu"sh" --force origin main` (the helper alone asks) | silent | deny |
| `true; g"it" push origin main`, `true; git -c 'x.y=a;b' push origin main` | silent | deny |
| `$'git' push …`, `$"git" push …`, `{git,} push …`, `/usr/bin/gi? push …` | deny | deny |
| `"git" push …`, `g\it push …`, `'git' push …`, `g''it push …` (plain commands) | ask | ask |
| `IFS=$'\n'; echo hi`, `printf $'a\tb'` | silent | silent |

Rows 3 and 4 are silent because the fast path starts the helper only on a literal push word, a
selector or an alias. `$'git' push …` is denied on 9702750: its raw text holds git and push.

## 1. Decode ANSI-C quotes

**Finding them.** One left-to-right scan follows the shell's quoting. Outside quotes: a backslash
takes the next character; `'…'` is literal; `"` and `$"` open double quotes; `#` at a word start
runs to the end of the line; `<<WORD` and `<<-WORD` skip the here-document body to its delimiter
line; `$'` opens an ANSI-C quote, which ends at the first `'` no backslash takes. Inside double
quotes, a backslash takes the next character and `$'` is literal, while `$(`, a backtick and `${`
open a nested context that the outside rules scan up to its closing `)`, backtick or `}`. So
`"$( … $'…' … )"` is decoded, and so is `"${X:-$'…'}"` (bash decodes it; zsh does not, so
decoding it only adds a deny).

**Decoding them,** byte-exact, in one reading per shell the Bash tool can run:
- **zsh 5.9:** `\a \b \e \E \f \n \r \t \v \\ \' \"`, octal `\nnn`, `\xHH`, `\u` (≤ 4 digits) and
  `\U` (≤ 8), each a NUL with no digit, and `\C-X`, `\CX`, `\M-X`. Any other escaped character
  drops its backslash: `$'\g\it'` is `git` and `$'\pus\h'` is `push` (measured). A NUL stays.
- **bash 5.3:** the same letters plus `\?`, octal, `\xHH`, `\x{H…}`, `\u`, `\U`, `\cX`. Any other
  escaped character keeps its backslash. A NUL ends the quote's value; the word goes on after it.
- **bash 3.2:** as 5.3, except that `\u` and `\U` stay literal and `\c?` and a lone `\c` are 3.2's.

**Judging them.** As the design says, `$'` is unsplittable: a command in which the scan finds an
ANSI-C quote is outside the grammar. Each reading's decoded command replaces every ANSI-C quote
with its value, bare when it is all `PLAIN_WORD` characters and otherwise single-quoted (`'` as
`'\''`). That is a matching device, not a faithful rewrite inside double quotes. `could_push`
judges the raw command, as on main, and then each decoded command. If any could push, the command
gets the PLAIN silent deny, never an ask. Tokens are read up to their first NUL, as `execve` reads
them: zsh runs `$'git\0'x push` as git push (measured).

Rejected: a full shell parser. It is larger and still not the shell. The scan covers the quoting
the shell resolves before anything runs; section 7 names what it misses.

## 2. Words, not only text

Section 1 needs these for mixed quoting (`gi$'t'`, `$'g\x69'"t"`), and they close main's gaps
without `$'` (rows 4–5). Both only add denies, and only outside the grammar.
- **Unquoted text.** `could_push` also matches `PUSH_SHAPE` and the alias pattern against the
  same text (after `inert_text`) with `'`, `"` and backslashes removed, each backslash-newline
  first made a space: `g"it"`, `g\it`, `pu"sh"`, `$"g"it`, `{g\it,p\ush}`, continuations.
- **The push shape on tokens.** `dynamic_git_word` is also true when the slot past git's global
  options is `push`, `send-pack` or `http-push`: a quoted `;`, `|` or newline in an option value
  before push, and `git send-pack` in a compound, which `PUSH_SHAPE` never matched.

## 3. Fast path: start on hidden spellings, never ask for them

The fast path also starts the helper when the payload holds `$'`, or holds `push` or `send-pack`
once every `"`, `'` and `\` is removed (a builtin substitution, no subprocess). It passes
`PUSH_GUARD_LITERAL=1` when one of main's triggers fired (literal push word, selector, alias) and
`0` otherwise; on `0`, an ask the helper would return becomes the PLAIN deny. So nothing asks
where main did not, and a lost variable only turns an ask into a deny. An exception in the helper
also denies a command holding `$'`. The fallback for a helper that cannot run is unchanged: `$'`
alone is as common as the bare word push.

## 4. Command words the shell builds

`dynamic_git_word` covers git's subcommand slot when git is literal (`git ${X:-pu}sh`), and
`odd_command_word` covers globs and dash names. Neither covers a command word built by expansion,
so `${X:-gi}t push` and `$G push` pass on main. The fix, in `odd_command_word`: a command word
counts as a possible git when its last path component holds `$`, a backtick, `{` or `}`, and its
simple command (that word included) holds a token matching `\b(push|send-pack)\b`. That also
covers `${X:-/usr/bin/gi}t` (last component `gi}t`) and `$((0))git`. `$HOME/bin/helm push x` and
`$EDITOR f` stay silent. The case-pattern exception applies as before.

## 5. Rule wording

RULE in `autoMode.allow` gains, after "…or other commands in it.": "It never applies when git or
push is spelled any way other than those literal words, is built at run time, or is run through a
script or interpreter." The fixed opening stays, so the overlay drops the carried main-era text.

Measured during execution in the merged spec's `TASK.md` harness (nested `claude -p`, haiku, auto
mode, `--permission-prompts none`, auto-allow on, RULE through `--settings`, a scratch repository
with a bare origin):
- the plain merged pinned delete is still allowed, in both lease spellings;
- an interpreter-built delete, `python3 -c` running `subprocess.run(['g'+'it', 'pu'+'sh', …,
  '--delete', 'done'])`, which no guard sees, is run 3 times under each wording and recorded;
- nested runs set `XDG_STATE_HOME` to a scratch directory, and the line count of Michael's
  `~/.local/state/agent-audit/prompts.jsonl` is read before and after. The plan reports any
  lines added and never edits that log.

## 6. GitHub ruleset on the dotfiles `main`

Created during execution, never earlier:
`gh api --method POST repos/michaelrigart/dotfiles/rulesets --input <file>`, the file being

```json
{"name": "protect-main", "target": "branch", "enforcement": "active", "bypass_actors": [],
 "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
 "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}]}
```

Verified by `gh api repos/michaelrigart/dotfiles/rules/branches/main --jq '[.[].type] | sort'`
printing `["deletion","non_fast_forward"]`, and by
`gh api repos/michaelrigart/dotfiles/rulesets/<id>
--jq '{enforcement, bypass_actors, include: .conditions.ref_name.include}'` printing
`{"enforcement":"active","bypass_actors":[],"include":["refs/heads/main"]}`. Pushes and merges to
`main` still pass; to force-push or delete it, Michael too must disable the ruleset first.

## 7. Threat model and residual

The guard header's threat model becomes: every spelling of git and push that the text fixes
before anything runs is in scope (quoting, escapes, ANSI-C quotes as zsh and bash decode them,
`$"…"`, brace lists, globs). A word built at run time is judged where it stands: as git's
subcommand, or as a command word beside a push word. A command with no git or push in its text,
literal or decoded, stays out of scope as on main: a script file, an interpreter assembling the
words, `${A}${B}`, and `git ${X:-pu}sh`, on which the fast path never starts the helper. The
classifier and section 6 cover those. The header also records the scan's residual:
- a `case` pattern's `)` inside `$( )` within double quotes ends that context early;
- after a here-document or quote that shlex cannot split, the token checks (sections 2 and 4,
  `dynamic_git_word`) do not run, as on main; the text checks still do;
- a push alias behind a built command word (`$G pom`) holds no push word.

## Non-goals

The other guards; the `.git/config` plant (its own spec, next); rule 4's verdicts on plain
commands, except two tightenings: a command holding `$'` leaves the grammar (section 1), and an
ask on a spelling main never sent to the helper becomes a deny (section 3).

## Tests

`tests/git-forge-guard.test.sh`, every case through the whole hook:
- every row of the table, with its new verdict;
- git and push each spelled by `\xHH`, `\x{HH}`, octal, `\u`, `\U`, zsh's dropped backslash, a
  NUL (`$'git\0x'`, `$'gi\0x't`, `$'git\0'x`), split across quotes (`gi$'t'`, `$'g\x69'"t"`),
  and both escaped; denied bare, behind `-c $'x.y=\n'`, after `true 'x$';`, after a
  here-document holding an apostrophe, inside `"$( )"` and backticks, as an alias
  (`$'\x67it' pom`), in the dash form and as `send-pack`;
- silent: `IFS=$'\n'; echo hi`, `printf $'a\tb'`, `read -r -d $'\0' x`, `echo $'\x67it push'`,
  `sed -e 's/git|push/x/' f`, `rg "git|push" $'\t'`, `$HOME/bin/helm push x`;
- `git pu"sh" origin main` and `git pu"sh" --force origin main` get the PLAIN deny, not an ask;
  `git pu"sh" origin feature` stays silent.

Recorded in the suite header, not part of it:
- **Decoder differential:** every escape letter, digit count, NUL position and `\c`/`\C`/`\M`
  form; each reading equals its shell's `printf %s` byte for byte (zsh -f, bash 5.3, bash 3.2).
  zsh with Michael's snapshot must match the zsh reading; a mismatch adds a reading.
- **Stub differential:** commands mixing every section 1 construct around a push to `main` (which
  rule 4 asks about in plain words) run under each shell with a stub git first on PATH recording
  its argv. Every command whose stub received push or send-pack as its subcommand gets a deny or
  an ask: 0 silent outside section 7's residual.
- **Differential against main:** the merged spec's B shapes, the cases above, and every Bash
  command in the last 30 days of transcripts (run locally, never committed). 0 looser verdicts,
  0 new asks, new denies counted by class.

`tests/claude-settings.test.sh`: the RULE pin carries the new text; the fixed-opening pin is
unchanged; main's RULE text, carried from a live file, is dropped. The ruleset is checked with
section 6's commands at execution.

## Verification after Michael's apply

1. Live check 4 again: the hook denies the `$'\x67it'` delete, and the transcript shows
   `hook:PreToolUse`, not a classifier accept.
2. A plain pinned delete of a merged branch still runs without a prompt.
3. `IFS=$'\n'; echo hi` runs.
