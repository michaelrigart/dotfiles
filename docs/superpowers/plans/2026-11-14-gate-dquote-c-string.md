# Pre-merge gate: nested shell strings read as handed on — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented. Completed on 2026-11-14 (Task 1, two fix rounds and the final review's fix wave); do not run it again.

**Goal:** The gate reads a `-c` or `env -S` string, and a backtick body inside double quotes, as
the shells hand it on, and treats a quote inside a double-quoted `${…}` as unreadable.

**Architecture:** Three changes in `dot_claude/xreview-guard.py`, deny direction only. R1: a
second `tokenize` reading whose double-quoted `\$` and `` \` `` lose their backslash; `scan`
rescans its shell strings beside today's. R2: a second body for a backtick substitution inside
double quotes, with `\"` undone too. R3: `lex` marks a `"` or `'` inside a `${…}` that stands in
double quotes, and `scan` denies a marked text that `crude` finds a gated verb in; no reading is
taken away.

**Tech Stack:** `/usr/bin/python3` 3.9 (no match statements, no `X | Y` unions), bash test suite.

**Spec:** `docs/superpowers/specs/2026-11-14-gate-dquote-c-string-design.md`

## Global Constraints

- Deny direction only: no reading the gate makes today is removed or changed, `crude`'s
  included; the top-level tokens `scan` returns stay the first reading (spec §4). Nothing new
  may raise `ValueError`: it would send the command to `crude`, which reads `lex`'s text too.
- No new file, so no `.scripts/test-audit/subjects.tsv` row.
- The suite is a bash suite: run it as `./tests/xreview-guard.test.sh`, never through an
  interpreter. Never wrap `tests/run.sh` in `lockf`; the test lock is shared.
- Never run a gated forge verb or `git merge` in a Bash call of your own, `--help` included; the
  suite's rows are the only place these commands appear. Write a command that names one to a
  file with the Write tool instead of echoing it from Bash: the live gate and push guard read
  every Bash command's text.

## Review Focus

- A `\\` pair before `$` or a backtick inside double quotes (`"\\$x"`, spec row 7): the
  rewrite must pair backslashes, or it moves the wrong character out of the quotes.
- A single-quoted `\$` or `` \` `` in the outer command stays escaped (spec row 14).
- One word mixing quotes (`'echo '"\`git merge feature\`"`), a nested shell inside the string
  (`bash -c "bash -c 'echo \`git merge feature\`'"`), and `$"…"`
  (`bash -c $"echo \`git merge feature\`"`): each runs the merge in every shell.
- R3 must not fire on an escaped quote (`"${x:-\"}"`), on a `$(…)` with its own quotes inside a
  double-quoted `${…}` (`"${x:-$(echo "c d")}"`: the quotes belong to the substitution), on bash
  5.3's `${ cmd; }`, or outside double quotes (`${x:-"a b"}` unquoted reads as the shells do).
- A large command with no nested shell pays no extra pass: the second reading is built only
  when the first finds a shell string.

---

### Task 1: Read nested shell strings, quoted backtick bodies and quoted `${…}` as the shells do

**Depends on:** nothing

**Files:**
- Modify: `dot_claude/xreview-guard.py` (header comment `:28-31`; a new message beside
  `UNPARSEABLE` `:75-76`; `lex`'s docstring, `close()`, its `"` branch and its return
  `:392-589`; `tokenize` `:655-662`; `scan` `:717-765`)
- Test: `tests/xreview-guard.test.sh` (new rows right after B50, `:253-255`)

**Interfaces:**
- Produces: `dquote_escapes(text: str) -> str` (module level, beside `strip_redirections`);
  `tokenize(text, digits=BASH_DIGITS, escapes=False)`; `lex` returns a fourth value,
  `nested_quote: bool` (its two unpacking callers in `scan` change; `crude` and the indexed
  callers keep working); `NESTED_QUOTE`, the new message. No other signature changes.

- [ ] **Step 1: Write the failing rows** after B50. Each command below is the exact text the
  gate must receive (the spec's §2 row number in brackets). Where a command holds a single
  quote, build it with a quoted here-document so no escaping is needed:
  `X=$(cat <<'CMD'` / the command / `CMD` / `)`.

```text
B99  deny ×3   [1] bash -c "echo \`git merge feature\`"
               [2] bash -c "echo \`glab mr merge 7\`"
               [3] sh -c "x=\`gh pr merge 9\`"
B100 deny ×3   [4] bash -c "echo \"\$(git merge feature)\""
               [5] zsh -c "print \"\$(glab mr merge 7)\""
               [6] bash -c "echo \"\`git merge feature\`\""
B101 deny ×2   [7] bash -c "echo \\\\\`git merge feature\`"
               [8] env -S "bash -c 'echo \`git merge feature\`'"
B102 deny ×1   [9] echo "`bash -c \"git merge feature\"`"
B103 deny ×3   bash -c 'echo '"\`git merge feature\`"
               bash -c "bash -c 'echo \`git merge feature\`'"
               bash -c $"echo \`git merge feature\`"
B104 deny ×2   [17] bash -c "${x:-"git merge y"}"
               [18] echo "${x:-"'"}"; git merge y; echo "'" #"
B106 deny ×1   git -C "$(
                 pwd
               )" merge feature; printf '%s\n' "${MSG:-"done"}"
               (three lines; the second is two spaces then pwd; main denies it already)
B105 allow ×6  [12] bash -c "echo \"merge is a word\""
               [13] bash -c "git log --format=\"%h\" -1"
               [14] bash -c "echo '\`git merge feature\`'"
               [15] echo "$(bash -c \"git merge feature\")"
               [16] cat <<EOF
                    `bash -c \"git merge feature\"`
                    EOF
               [19] printf '%s\n' "${MSG:-"it's done"}"
```

  Each row joins its decisions with spaces, as B50 does, and expects `"deny deny deny"` (and so
  on) or `"allow allow allow allow allow allow"`. B104 also pins, with `reason`, that row 17's
  deny names a quote inside a double-quoted `${...}` (grep for `double-quoted \${`). B106 pins
  that R3 takes no reading away: main denies it, and R3 in a form that took `crude`'s reading
  away allowed it. Row names
  say what each pins, in the suite's voice; B105's says the inner command's own quoting, single
  quotes, `$( )`, a here-document and a nested quote with no gated verb keep the command
  allowed. Before running, print each command once (`printf '%s\n' "$X"`) and check it is byte
  for byte the text above.

- [ ] **Step 2: Run the suite and see the new deny rows fail**

Run: `./tests/xreview-guard.test.sh 2>&1 | grep -E 'FAIL|B99|B10[0-5]|^[0-9]+/'`
Expected: B99 to B104 FAIL with `got: allow …`; B105 and B106 PASS (main already decides them
so); every other row PASS.

- [ ] **Step 3: Implement R1.** `dquote_escapes(text)` returns `text` with each `\$` and
  `` \` `` that stands inside double quotes written as `"\$"` / ``"\`"`` (out of the quotes and
  back in), so `shlex` drops the backslash as the shells do. It tracks quoting exactly as
  `strip_redirections` does: inside `'…'` nothing is special; elsewhere a backslash takes the
  next character with it (a `\\` pair is never split). `tokenize(..., escapes=True)` applies it
  to the text after `strip_redirections`. In `scan`, replace
  `nested.extend(shell_strings(tokens))` with: take `shell_strings(tokens)`; when it is
  non-empty, add each string of `shell_strings(tokenize(text, escapes=True))` not already in it
  (the two readings put a shell word at the same positions, so an empty first list means an
  empty second); extend `nested` with the result. If the second `tokenize` raises `ValueError`,
  keep the first list alone. Update `scan`'s docstring: a shell's `-c`
  string and `env -S`'s are read twice, as the gate's words hold them and as the outer shell
  hands them on.

- [ ] **Step 4: Implement R2.** In `lex`'s `close()`, for a backtick frame whose enclosing
  frame (after the pop) is a `"` frame, also append the body with `` \` ``, `\\`, `\$` and `\"`
  undone, beside today's body. A backtick in a here-document body or outside quotes is
  unchanged. Add to `lex`'s docstring: inside double quotes a backtick body is also read with
  `\"` undone, as the shells read it.

- [ ] **Step 5: Implement R3.** In `lex`'s `"`/`body` branch, for a `"` frame only: a `${`
  that is not a funsub (the funsub branch keeps running first) adds one to the frame's third
  field (unused by `"` frames today; say so in a comment), a `}` while it is open takes one
  away, and a `"` or `'` while it is open sets `nested_quote`, then is handled exactly as today.
  The text, substitutions and here-document bodies `lex` returns do not change. Escaped
  characters never count: the backslash branch above runs first. A `$(` or backtick opened
  inside keeps its own frame, so its quotes are its own. `lex` returns `nested_quote` as a
  fourth value. In `scan`, right after the first `lex(cmd)`: when `nested_quote` and
  `crude(cmd)`, raise `Deny(NESTED_QUOTE)`; `main` already prints a `Deny` raised inside
  `scan`. `NESTED_QUOTE` = "Pre-merge gate: this command has a quote inside a double-quoted
  ${...}, where the shells nest quotes by rules the gate does not read, and it may propose or
  merge a change. Put the value in a variable first, and run the verb as a plain command."
  Update `lex`'s docstring (the fourth value) and `scan`'s (it may raise `Deny`).

- [ ] **Step 6: Header comment.** In the comment at `:28-31`, after "or env -S '...'.", add:
  "Such a string is read as written and as the outer shell hands it on, its double-quoted \$
  and \` unescaped; a backtick body inside double quotes is read with \" unescaped too. A
  command holding a quote inside a double-quoted ${...}, where the shells nest quotes by rules
  the gate does not model, is denied when it also mentions a gated verb." Rewrap to the file's
  width.

- [ ] **Step 7: Run the suite**

Run: `./tests/xreview-guard.test.sh 2>&1 | tail -3`
Expected: every row PASS, B99 to B106 included; the summary line `N/N`.

- [ ] **Step 8: Revert check.** Revert each change alone and restore it before the next:
  without R1, B99, B100, B101 and B103 fail; without R2, only B102 fails; without R3, only B104
  fails. Then make R3 raise `ValueError` where it sets `nested_quote`: B106 fails. Restore.

- [ ] **Step 9: Commit**

```bash
git add dot_claude/xreview-guard.py tests/xreview-guard.test.sh
git commit -m "Read a nested shell's string, a quoted backtick body and a quoted \${...} as the shells do"
```

Report: the commit, the suite's `N/N`, and which rows each revert in Step 8 turned red.
