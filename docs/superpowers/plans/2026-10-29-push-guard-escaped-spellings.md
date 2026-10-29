# Push guard catches escaped spellings: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress (branch `fix/push-guard-escaped-spellings`; the dotfiles have no MR)

**Goal:** Rule 4 denies every spelling of git and push that the command text fixes before
anything runs, adds no prompt, and is never looser than main (9702750).

**Architecture:** The shell fast path in `dot_claude/executable_git-forge-guard.sh` starts the
helper on hidden spellings, and tells it whether one of main's triggers fired. The helper,
`dot_claude/git-push-guard.py`, gains context-free normalized views with a source map. A view
denies only on a git/push pair that has a hidden word. Main's raw checks and grammar are kept;
there are two new grammar exits and two token checks. The rest of the work is one classifier
rule sentence, a GitHub ruleset, and three recorded differentials.

**Tech Stack:** Python 3.9 (`/usr/bin/python3`), bash 3.2, jq, `gh`, the shell test suites in
`tests/`.

**Spec:** `docs/superpowers/specs/2026-10-29-push-guard-escaped-spellings-design.md`. Every
section reference below (§1 to §7, Tests) points into it.

## Global Constraints

- The helper stays one file: `dot_claude/git-push-guard.py`, Python 3.9, with no `match` and no
  `X | Y` types. Putting the views in a separate module would need a new `.chezmoiignore`
  re-include and a deploy check for little gain, so they stay in that file.
- `dot_claude/executable_git-forge-guard.sh` stays bash 3.2 compatible, and its fast path spawns
  no subprocess.
- No new prompts. Every change is a silent deny or a wording change. Nothing may be looser than
  main (9702750).
- The deny for every new path is the existing `PLAIN` constant, unchanged.
- Readings are exactly `zsh` (5.9), `bash5` (5.3) and `bash32` (3.2), as listed in §1.
- In Bash commands, write the helper's name as a glob, `dot_claude/git-pu[s]h-guard.py`.
  Spelling it out can trip the push guard on your own command.
- The repository is public. Never commit transcript content, run artefacts or anything from
  `~/.claude/projects`. Run artefacts go in `docs/superpowers/runs/` (never tracked) or the
  scratchpad.
- Execute suites directly (`./tests/git-forge-guard.test.sh`) or through `./tests/run.sh`.
  Report totals as passed/total.
- Existing cases whose verdict changes, and only these:
  - In `tests/git-forge-guard.test.sh`, `$DOCKER push registry/x:1` and
    `npm run build && $DOCKER push img` go from allow to deny. §4 counts a built command word
    whose subcommand slot holds push, and `$DOCKER push` has the same shape as `$G push`.
  - Every other existing case keeps its verdict.
- RULE gains exactly this sentence (§5), placed after "…or other commands in it.":
  `It never applies when git or push is spelled any way other than those literal words, is built at run time, or is run through a script or interpreter.`

## Review Focus

These are the inputs §1 implies that no row of the spec's test list exercises. Task 4 owns the
test for each.
1. **Malformed escapes and quotes.** An unterminated `$'`, a lone trailing backslash, or `\x`
   with no digit must never raise. Raising would deny through the exception rule.
2. **Out-of-range code points.** `\UFFFFFFFF` and a surrogate `\ud800` must decode without an
   exception and stay silent.
3. **A NUL from any escape form.** `\x00`, `\c@` (bash), `\u0000` and octal `\0` all get the NUL
   variants. `$'gi\x00x't push origin main` runs git push under bash.
4. **Size.** A 200 KB here-document full of `\x41` escapes is decoded in all twelve views well
   inside the hook's 60 s timeout. A hook that outruns that timeout fails open.
5. **The locale quote.** `$"g"it push origin main` runs git push under bash (measured). Main is
   silent on it.

---

### Task 1: Fast path starts on hidden spellings; no ask for them

**Depends on:** none (batch with Task 5)

**Files:**
- Modify: `dot_claude/executable_git-forge-guard.sh` (fast path, lines ~99–144)
- Modify: `dot_claude/git-push-guard.py` (`main`)
- Test: `tests/git-forge-guard.test.sh`

**Interfaces:**
- Produces:
  - the environment variable `PUSH_GUARD_LITERAL`, set by the guard on every helper run;
  - `literal_trigger() -> bool` in the helper, which is `os.environ.get("PUSH_GUARD_LITERAL") == "1"`.

- [ ] **Step 1: Write the failing tests.** Add a new section,
  `echo "== rule 4: spellings the fast path used to miss =="`, after
  "expansion in option values". Use the fixture repo `$R`, whose branch is `feat`.

```bash
expect deny  "a quoted push word to main"            "$R" 'git pu"sh" origin main'
has_reason   "it gets the plain-push deny" "in a shape the guard does not check" "$R" 'git pu"sh" origin main'
expect deny  "a quoted push word, force"             "$R" 'git pu"sh" --force origin main'
expect deny  "an empty-quote push word"              "$R" "git p''ush origin main"
expect deny  "an escaped push word"                  "$R" 'git pu\sh origin main'
expect allow "a quoted push word to a feature branch" "$R" 'git pu"sh" origin feat'
expect deny  "an ANSI-C push word"                   "$R" "git \$'\\x70ush' origin main"
expect deny  "an ANSI-C letter inside push"          "$R" "git pu\$'\\x73'h origin main"
expect ask   "a literal push still asks"             "$R" 'git push origin main'
expect ask   "a quoted git word, literal push, still asks" "$R" '"git" push origin main'
```

  Extend the "costs nothing" tripwire block with three cases:
  - each of `IFS=$'\n'; echo hi`, `printf '\x41'` and `git pu\`⏎`sh origin main` (⏎ a real
    newline) runs the helper;
  - `echo hi` does not run it.

- [ ] **Step 2: Run and confirm RED.** Run `./tests/git-forge-guard.test.sh 2>&1 | grep -E 'FAIL|passed'`.
  It is RED on the quoted, escaped and ANSI-C push words, which are silent today, and on the
  three new tripwire runs.

- [ ] **Step 3: Implement the fast path, following §3.**
  - Compute `literal` from main's three signals (`push_word`, `push_selector`, `push_alias`)
    before adding the new ones.
  - Add three new signals, each a builtin pattern or substitution on `$payload`:
    - the payload holds `$'`;
    - it holds a JSON-escaped backslash before `x`, `u`, `U`, `0` to `7`, or `c`;
    - it holds `push` or `send-pack` once the JSON backslash-newline (the four characters `\\\n`)
      is deleted and every `"`, `'` and `\` is removed.
  - Call the helper as `PUSH_GUARD_LITERAL=$literal "$py" "$helper"`, with `literal` set to `1`
    or `0`.
  - The fallback's evidence is unchanged.

- [ ] **Step 4: Implement the helper side.** `literal_trigger()` reads the variable. In `main()`:
  - when `literal_trigger()` is false, an ask becomes `Deny(PLAIN)`;
  - the `except Exception` branch also denies when `literal_trigger()` is false.

- [ ] **Step 5: Run and confirm GREEN.** Run `./tests/git-forge-guard.test.sh`; expect 0 failed.

- [ ] **Step 6: Commit.** Run `git add dot_claude/executable_git-forge-guard.sh dot_claude/git-pu[s]h-guard.py tests/git-forge-guard.test.sh`,
  then commit with the message "Start the push guard on hidden spellings, never asking for them".

### Task 2: Grammar exits and the push shape on raw tokens

**Depends on:** Task 1

**Files:**
- Modify: `dot_claude/git-push-guard.py` (`main`, `dynamic_git_word`)
- Test: `tests/git-forge-guard.test.sh`

**Interfaces:**
- Consumes: `literal_trigger()` from Task 1.
- Produces:
  - `outside_grammar(cmd: str) -> bool`, which is true when `"$'" in cmd`, or when a
    backslash-newline has a non-blank character on each side, matching `\S\\\n\S`;
  - `git_word_hits(tokens: list) -> list` of `(git_index, slot_index)` pairs, one for each git
    command word whose slot past the global options is dynamic or one of
    `PUSH_SLOT = {"push", "send-pack", "http-push"}`;
  - `dynamic_git_word(tokens)`, which becomes `bool(git_word_hits(tokens))`.

- [ ] **Step 1: Write the failing tests**, in the Task 1 section:

```bash
expect deny  "a quoted ; in a -c value before a literal push" "$R" "true; git -c 'x.y=a;b' push origin main"
expect deny  "git send-pack in a compound command"   "$R" "true; git send-pack $REMOTES/origin.git main"
expect deny  "an ANSI-C assignment before a feature push" "$R" "IFS=\$'\\n' git push origin feat"
has_reason   "a \$' command gets the plain-push deny" "in a shape the guard does not check" "$R" "IFS=\$'\\n' git push origin feat"
expect deny  "a continuation inside a refspec word"  "$R" 'git push -u origin fe\
at'
has_reason   "an in-word continuation gets the plain-push deny" "in a shape the guard does not check" "$R" 'git push -u origin fe\
at'
expect allow "a continuation between words keeps main's verdict" "$R" 'git push -u \
origin feat'
```

- [ ] **Step 2: Run and confirm RED.** The first five cases fail: the first two are silent
  today, and the next three are judged by the grammar.

- [ ] **Step 3: Implement.**
  - In `main()`, skip `parse_plain` when `outside_grammar(cmd)` is true; `shape` stays `None`.
  - `git_word_hits` keeps `dynamic_git_word`'s walk over the global options. At the slot it
    records a hit when the word is `dynamic` or is in `PUSH_SLOT`.
  - `could_push` already calls `dynamic_git_word` on the raw tokens, so that call now covers §2.

- [ ] **Step 4: Run and confirm GREEN.** Run `./tests/git-forge-guard.test.sh`; expect 0 failed.

- [ ] **Step 5: Commit.** Run `git add dot_claude/git-pu[s]h-guard.py tests/git-forge-guard.test.sh`,
  then commit with the message "Take ANSI-C quotes and in-word continuations out of the push grammar".

### Task 3: Command words the shell builds

**Depends on:** Task 2

**Files:**
- Modify: `dot_claude/git-push-guard.py` (`odd_command_word`)
- Test: `tests/git-forge-guard.test.sh`, including the two flipped `$DOCKER` cases (Global
  Constraints)

**Interfaces:**
- Consumes: `git_word_hits`'s global-option walk.
- Produces:
  - `built_word_hits(tokens: list) -> list` of `(word_index, slot_index)` pairs. A pair is
    recorded for a command word, in `command_words` order with the case-pattern exception, whose
    last path component holds `$`, a backtick, `{` or `}`, and whose slot past git's global
    options holds `push` or `send-pack`;
  - `odd_command_word(tokens)`, which is also true when `built_word_hits(tokens)` is non-empty.

- [ ] **Step 1: Write the failing tests and flip the two existing cases.**

```bash
expect deny  "a variable git word with push"         "$R" '$G push origin main'
expect deny  "a built git word, -C before push"      "$R" '${X:-gi}t -C . push origin main'
expect deny  "a built path whose last component is gi}t" "$R" '${X:-/usr/bin/gi}t push origin main'
expect deny  "a built git word, delete"              "$R" '${X:-gi}t push origin --delete wip'
expect allow "a variable interpreter on a push script" "$R" '$PYTHON scripts/push.py'
expect allow "a \$HOME path to helm push"            "$R" '$HOME/bin/helm push x'
```

  In the "expansion in option values" section, change `$DOCKER push registry/x:1` and
  `npm run build && $DOCKER push img` from `allow` to `deny`, and update their labels. Add a
  comment citing spec §4: a built command word whose subcommand slot holds push counts as a
  possible git.

- [ ] **Step 2: Run and confirm RED.**
- [ ] **Step 3: Implement `built_word_hits`, and extend `odd_command_word` with it.**
- [ ] **Step 4: Run and confirm GREEN.** Run the whole suite; expect 0 failed.
- [ ] **Step 5: Commit.** Run `git add dot_claude/git-pu[s]h-guard.py tests/git-forge-guard.test.sh`,
  then commit with the message "Count a built command word whose subcommand is push as a possible git".

### Task 4: Normalized views and hidden words

**Depends on:** Task 3

**Files:**
- Modify: `dot_claude/git-push-guard.py`: new view functions after `could_push`, which then
  calls them.
- Test: `tests/git-forge-guard.test.sh`: a new section `"== rule 4: hidden spellings =="`, and a
  decoder check, `"== rule 4: the escape decoder matches the shells =="`.

**Interfaces:**
- Consumes: `git_word_hits`, `built_word_hits`, `push_aliases`, `PLAIN`.
- Produces:
  - `READINGS = ("zsh", "bash5", "bash32")`;
  - `decode_ansi(body: str, reading: str) -> str`: the control-character reading of a `$'…'`
    body, with NUL kept as `"\0"`;
  - `View = namedtuple("View", "text spans cuts")`. `spans[k]` is the `(start, end)` raw span of
    view character `k`, and `cuts` lists the raw offsets where a NUL variant began dropping text;
  - `views(cmd: str) -> list` of `View`, deduplicated by text, at most 12;
  - `hidden_signal(cmd: str) -> bool`, the gate in §1, matching
    `\$'|\$"|\\\n|\\[xuUc0-7]|[A-Za-z0-9]['"\\]+[A-Za-z0-9]`;
  - `hidden(cmd: str, view: View, start: int, end: int) -> bool`;
  - `view_tokens(text: str) -> list` of `(token, start, end)`, split by the regex
    `\n|[;&|()<>]+|[^\s;&|()<>]+`, so that no shlex is involved;
  - `view_could_push(cmd: str, aliases: set) -> bool`.

- [ ] **Step 1: Write the failing decoder check.**
  - The check loads the helper with `importlib.util.spec_from_file_location`.
  - For each body below, `decode_ansi(body, reading)` must equal the shell's
    `printf %s $'<body>'` output, read as bytes, under `/bin/zsh -f` (`zsh`), `/bin/bash`
    (`bash32`) and `/opt/homebrew/bin/bash` (`bash5`, skipped with an `ok` note when absent).
  - For the bash readings, compare up to the first NUL.
  - The bodies are: `\x67it`, `\147it`, `\0147`, `git`, `\U00000067it`, `\g\it`,
    `\pus\h`, `\x{67}`, `\x`, `\8`, `\cG`, `\c?`, `\C-a`, `\Cx`, `\M-a`, `\e`, `\?`, `gi\0t`,
    `\400`, `\777`.

- [ ] **Step 2: Write the failing whole-hook cases.** These are every §Tests case that Tasks 1
  to 3 do not already cover.
  - **Denied:**
    - the table rows not yet covered:
      - `$'\x67it' push origin --delete wip`, `$'\147it' push origin --delete wip`,
        `$'\x67it' push --force origin main`;
      - `g\`⏎`it pu\`⏎`sh origin main`, `git pu\`⏎`sh origin main`, `git pu\`⏎`sh --force origin main`;
      - `true; g"it" push origin main`;
      - `cat <<EOF`⏎`$( $'\x67it' $'\x70ush' origin main )`⏎`EOF`;
      - `printf '\x67it \x70ush origin main' | sh`;
    - git and push, each spelled in these forms:
      - inside `$'…'`: `\xHH`, `\x{HH}`, octal, `\u`, `\U`, zsh's dropped backslash
        (`$'\g\it'`, `$'\pus\h'`) and a NUL (`$'git\0x'`, `$'gi\0x't`, `$'git\0'x`);
      - split across quotes: `gi$'t'`, `$'g\x69'"t"`;
      - unquoted: `gi\t`;
      - with both words escaped;
    - each of those settings:
      - bare. The one exception is the unquoted `gi\t` alone,
        `gi\t push origin main`: it is a plain command, which keeps main's ask (see the rows 8
        to 10 bullet below);
      - behind `-c $'x.y=\n'`;
      - after `true 'x$';`;
      - after a here-document holding an apostrophe;
      - inside `"$( )"` and backticks;
      - in the round-1 here-document bodies, unquoted and `<<'EOF'`;
      - on the line after `echo $((1<<2))`;
      - as `$'\x67it' pom`, `$'\x67it-push' origin main` and `$'\x67it' send-pack <url> main`;
    - `$'\x67it' -c 'x.y=a;b' $'\x70ush' origin main` and
      `$'\x67it' -c $'x.y=a\';b' $'\x70ush' origin main`;
    - `echo hi; $'gi\0x't $'pu\0x'sh origin main`, and `echo hi; g\`⏎`it pu\`⏎`sh origin main`;
    - `$'git\0'x -c 'x.y=a;b' push origin main`;
    - `push''y; git''x; $'\x67it' $'\x70ush' origin main`;
    - `${X:-gi}t $'\x70ush' origin main`, a view-token hit on a hidden push word;
    - Review Focus 3 and 5: `$'gi\x00x't push origin main`, `$'gi\c@x't push origin main`,
      `$'gi\u0000x't push origin main` and `$"g"it push origin main`.
  - **Denied by design, labelled as such:**
    - `printf '\x67it \x70ush'`;
    - `echo $'\x67it push'`;
    - `git status; echo $'\x70ush'`.
  - **Allowed:**
    - `IFS=$'\n'; echo hi`, `printf $'a\tb'` and `read -r -d $'\0' x`;
    - `sed -e 's/git|push/x/' f` and `rg "git|push" $'\t'`;
    - `cat <<EOF`⏎`it's $'\x67it'`⏎`EOF` and `git status && ./scripts/push.sh`;
    - the quoted-here-document commit,
      `git commit -m "$(cat <<'EOF'`⏎`Fix the guard`⏎⏎`Don't push this yet.`⏎`EOF`⏎`)"`;
    - `git commit -m "fix\npush docs"`;
    - Review Focus 1 and 2: `printf '%s' $'unterminated \x`, `echo $'foo\` and
      `printf $'\UFFFFFFFF\ud800'`.
  - **Still denied by main's raw check:** `echo $'git push'`.
  - **Table rows 8 to 10 keep main's verdicts:**
    - deny: `$'git' push origin main`, `$"git" push origin main`, `{git,} push origin main`;
    - ask: `g\it push origin main`, `'git' push origin main`, `g''it push origin main`;
    - ask: `expect ask "an unquoted gi\t, a plain command, still asks" "$R" 'gi\t push origin main'`.
      In every other setting above, `gi\t` sits outside the grammar and is denied.
  - **Review Focus 4:** a 200 KB `cat > $TMP/big <<'EOF'` body of `\x41` lines is allowed, and
    `SECONDS` shows under 10 s.

- [ ] **Step 3: Run and confirm RED.** The decoder check fails, since `decode_ansi` does not
  exist yet, and so do the new deny cases.

- [ ] **Step 4: Implement `decode_ansi` and `views`, following §1 steps 1–3.**
  - Each view character records the raw span it came from:
    - a decoded escape maps to the whole escape sequence;
    - a character kept as-is maps to itself;
    - deleted characters (backslash-newline, `$` before a quote, `'`, `"`, a remaining `\`)
      produce none.
  - The variants are single-letter escapes (control character or bare letter) times the NUL
    rule:
    - **quote rule:** drop from the NUL to the next `'`;
    - **word rule:** drop to the next blank or one of `;&|()<>`.
  - A NUL from any escape form takes the NUL variants, and the raw offset of each drop is
    recorded in `cuts`.
  - A code point that `chr()` rejects decodes to nothing, never to an exception.

- [ ] **Step 5: Implement `hidden` and `view_could_push`.**
  - `hidden`: the word's raw span runs from `spans[start][0]` to `spans[end - 1][1]`. The word
    is hidden when `cmd[span] != view.text[start:end]`, or when a cut begins at the span's end.
  - `view_could_push` is true when either of these holds in some view:
    - a `\bgit\b` occurrence is followed, anywhere later, by a
      `\b(push|send-pack|http-push|<aliases>)\b` occurrence, and at least one of the two is
      hidden;
    - a `git_word_hits` or `built_word_hits` hit over `view_tokens(view.text)` has its git
      word, built word or push slot word hidden.
  - `could_push` calls `view_could_push` only when `hidden_signal(cmd)` is true.
  - Alias names come from the same `push_aliases` lookup as on main. The lookup also runs when
    a view holds a git word.

- [ ] **Step 6: Run and confirm GREEN.** Run `./tests/git-forge-guard.test.sh`, expecting 0
  failed, then `./tests/run.sh`, which must report every suite green as passed/total.

- [ ] **Step 7: Commit.** Run `git add dot_claude/git-pu[s]h-guard.py tests/git-forge-guard.test.sh`,
  then commit with the message "Deny pushes spelled with hidden git or push words".

### Task 5: RULE wording

**Depends on:** none (batch with Task 1)

**Files:**
- Modify: `dot_claude/modify_private_settings.json`, the `$delete_rule` string
- Test: `tests/claude-settings.test.sh`, section U

- [ ] **Step 1: Write the failing test.**
  - Set `RULE=` to the new text, which is main's text with the Global Constraints sentence after
    "…or other commands in it.".
  - Add `MAIN_RULE=` holding main's current text (today's `RULE` value, unchanged).
  - Add an `emit` of `{autoMode: {allow: ["$defaults", $MAIN_RULE, "Bash(x) in y"]}}`, then
    `jq_is` that `.autoMode.allow == ["$defaults", RULE, "Bash(x) in y"]`, with the label
    "main's text of the rule in the live allow list is dropped".
  - Keep the fixed-opening pin and `OLD_RULE` as they are.

- [ ] **Step 2: Run and confirm RED.** Run `./tests/claude-settings.test.sh`. If it exits 2 with
  `INCONCLUSIVE:`, warm the cache as AGENTS.md says, then rerun.
- [ ] **Step 3: Implement.** Add the sentence to `$delete_rule`. It holds no apostrophe and no
  backslash, as the jq program requires.
- [ ] **Step 4: Run and confirm GREEN.** Run `./tests/claude-settings.test.sh`; expect 0 failed.
- [ ] **Step 5: Commit.** Run `git add dot_claude/modify_private_settings.json tests/claude-settings.test.sh`,
  then commit with the message "Keep the merged-delete rule to literal git and push words".

### Task 6: Threat model header and the three differentials

**Depends on:** Task 4

**Files:**
- Modify: `dot_claude/git-push-guard.py`, the header "Threat model" paragraph (lines ~33–37)
- Modify: `tests/git-forge-guard.test.sh`, the header records, as E, F and G after D
- Run artefacts: `docs/superpowers/runs/2026-10-29-push-guard-escaped-spellings/`, never
  tracked

- [ ] **Step 1: Rewrite the header's threat model** with §7's three points and its three residual
  lines. Keep main's "Written for /usr/bin/python3 (3.9)" line. The example of `git ${X:-pu}sh`
  stays, as out of scope.

- [ ] **Step 2: Decoder differential.** Generate every escape letter `a` to `z` and `A` to `Z`,
  octal with 1 to 3 digits, `\x`, `\u` and `\U` with 0 up to their maximum digit count, NUL
  at the start, middle and end, and `\c`, `\C`, `\C-` and `\M-` before each printable ASCII
  character. Run each body under zsh -f, bash 5.3, bash 3.2, and zsh with Michael's Claude Code
  shell snapshot sourced.
  - **Pass:** every `decode_ansi` reading equals its shell byte for byte (bash readings up to the
    first NUL), and the snapshot zsh equals the `zsh` reading. A mismatch means a fix, or a new
    reading if the snapshot differs.

- [ ] **Step 3: Stub differential.**
  - Generate commands that push to `main` and mix single quotes, double quotes, backslashes,
    `$'…'`, `$"…"`, here-documents (quoted and not), comments, arithmetic, `$( )`, backticks,
    continuations and `printf … | sh` around git and push.
  - Run each under bash 3.2, bash 5.3 and zsh -f, with a stub `git` first on PATH that records
    its argv, and through this branch's hook in the suite's fixture repository.
  - **Pass:** every command whose stub received `push` or `send-pack` as its subcommand gets a
    deny or an ask: 0 silent, apart from §7's three residual shapes, each named when it occurs.

- [ ] **Step 4: Differential against main, and the transcript metric.**
  - Main's guard is extracted from 9702750 with `git archive` into the run directory.
  - The corpus:
    - corpus B, regenerated from the suite header's description B, since the original was not
      kept;
    - every case in this plan;
    - every Bash `command` from the last 30 days of `~/.claude/projects/**/*.jsonl`, read
      locally.
  - Both guards run in the same fixture repository with a bare origin, the suite's
    `GIT_CONFIG_GLOBAL`, and a stub gitleaks.
  - **Pass:** across the whole corpus, 0 verdicts looser than main and 0 new asks. Synthetic
    cases match their expected verdicts, including §1's accepted denies.
  - **Transcript metric:** every new deny on a transcript command is classified. A deny on a
    command that never pushes is a finding: stop and report it to the controller with the
    command's shape, never its content. Commit counts only.

- [ ] **Step 5: Record E (decoder), F (stub) and G (against main) in the suite header**, in the
  style of A to D: dates, counts, shells and results. For G, report the transcript figures as
  counts by class.

- [ ] **Step 6: Run `./tests/run.sh`.** Every suite must be green, reported as passed/total.

- [ ] **Step 7: Commit.** Run `git add dot_claude/git-pu[s]h-guard.py tests/git-forge-guard.test.sh`,
  then commit with the message "Record the escaped-spelling threat model and differentials".

### Task 7: RULE measurement

**Depends on:** Task 5

**Files:**
- Modify: `docs/superpowers/specs/2026-10-29-push-guard-escaped-spellings-design.md`: add a
  "Measured" paragraph to §5
- Run artefacts in `docs/superpowers/runs/2026-10-29-push-guard-escaped-spellings/`

- [ ] **Step 1: Count before.** Record `wc -l < ~/.local/state/agent-audit/prompts.jsonl`.

- [ ] **Step 2: Build the harness.** Use the merged spec's `TASK.md` harness:
  - a nested `claude -p` with haiku, auto mode, `--permission-prompts none` and auto-allow on;
  - RULE loaded through a `--settings` overlay;
  - a scratch repository with a bare origin, holding a merged branch `done`;
  - `XDG_STATE_HOME` set to a scratch directory on every nested run.

- [ ] **Step 3: Run the plain merged pinned delete** under the new RULE, once in each lease
  spelling. **Pass:** both are allowed.

- [ ] **Step 4: Run the interpreter-built delete 3 times under each wording** (main's and the
  new). The delete is `python3 -c` running `subprocess.run(['g'+'it', 'pu'+'sh', '--force-with-lease=refs/heads/done:<sha>', 'origin', '--delete', 'done'])`,
  issued from `TASK.md`. Record each verdict. There is no pass threshold.

- [ ] **Step 5: Count after,** and compare. Report any lines added. Never edit that log.

- [ ] **Step 6: Record the counts in the spec's §5** as a "Measured 2026-10-29" paragraph.

- [ ] **Step 7: Commit.** Run `git add docs/superpowers/specs/2026-10-29-push-guard-escaped-spellings-design.md`,
  then commit with the message "Record the merged-delete rule measurement".

### Task 8: GitHub ruleset on the dotfiles `main` (controller)

**Depends on:** Tasks 1, 2, 3, 4 and 6 committed and pushed.

- [ ] **Step 1: Write the body to a scratch file**, exactly as given in §6:
  `{"name": "protect-main", "target": "branch", "enforcement": "active", "bypass_actors": [], "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}}, "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}]}`

- [ ] **Step 2: Create the ruleset:**
  `gh api --method POST repos/michaelrigart/dotfiles/rulesets --input <file>`. Note the returned
  `id`.

- [ ] **Step 3: Verify.**
  - `gh api repos/michaelrigart/dotfiles/rules/branches/main --jq '[.[].type] | sort'` prints
    `["deletion","non_fast_forward"]`.
  - `gh api repos/michaelrigart/dotfiles/rulesets/<id> --jq '{enforcement, bypass_actors, include: .conditions.ref_name.include}'`
    prints `{"enforcement":"active","bypass_actors":[],"include":["refs/heads/main"]}`.

- [ ] **Step 4: Record the ruleset id and both outputs** in the run ledger.

## After execution (not tasks)

Michael's post-apply checks are the spec's "Verification after Michael's apply", items 1 to 3.
