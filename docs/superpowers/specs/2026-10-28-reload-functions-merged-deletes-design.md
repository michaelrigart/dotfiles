# Shells reload changed functions; agents delete merged branches

**Status:** In progress
**Date:** 2026-10-28
**Branch:** `feat/reload-functions-merged-deletes`

Design approved by Michael on 2026-10-28; this record adds the evidence and the rulings.

## Problem

1. **Stale functions.** After `chezmoi apply` deployed new `wt` functions, `wt blabla …` in a
   terminal opened earlier ran the old code and refused ("differs from the main checkout's");
   `exec zsh` fixed it. `dot_zshrc` sources `~/.config/zsh/functions` once, at startup. The
   PATH wrappers (`wt-prepare`, `wt-rm`) load it fresh, but interactive functions shadow them.
2. **Classifier-denied deletes.** Rule 4 (`dot_claude/git-push-guard.py`) passes a delete-only
   push of merged branches, each pinned to the tip it read, without an ask (spec 2026-10-16,
   "Merged-branch deletes"). The hook is then silent, so in auto mode the classifier decides,
   and it denied four as "[Git Destructive]":
   `git push --force-with-lease=refs/heads/<b>:<sha> origin :refs/heads/<b>`,
   `git push origin --delete …` and `git fetch --prune origin`. Michael ran them by hand.

## 1. Reload changed functions

`dot_zshrc` records the functions file's mtime just before its existing `source` of that file
(the mtime before the text, as in the hook) and registers a `preexec` hook that reloads on a
changed mtime. The hook lives in `dot_zshrc`, never in the functions file, so a reload never
redefines the running function. Sketch, with the startup `source` between the first `zstat`
and the hook (the plan settles the code):

```zsh
zmodload -F zsh/stat b:zstat && {
  typeset -g _zshrc_fn=$HOME/.config/zsh/functions
  typeset -ga _zshrc_fn_mtime
  zstat -A _zshrc_fn_mtime +mtime -- $_zshrc_fn 2>/dev/null || _zshrc_fn_mtime=missing
  _zshrc_reload_functions() {
    local -a m
    local body
    zstat -A m +mtime -- $_zshrc_fn 2>/dev/null || m=missing   # the mtime before the text
    [[ $m == $_zshrc_fn_mtime ]] && return 0
    _zshrc_fn_mtime=$m
    if [[ $m != missing ]] && body=$(<$_zshrc_fn) 2>/dev/null &&
        ( eval "$body" ) >/dev/null 2>&1 && eval "$body"; then
      print -ru2 -- 'zsh: reloaded ~/.config/zsh/functions'
    else
      print -ru2 -- 'zsh: cannot reload ~/.config/zsh/functions; keeping the old functions'
    fi
  }
  autoload -Uz add-zsh-hook && add-zsh-hook preexec _zshrc_reload_functions
}
```

- **`preexec`, not `precmd`:** `precmd` runs before a prompt is drawn, so a prompt drawn
  before the apply would run one stale command. `preexec` runs after Enter.
- **mtime by `zstat`, compared for inequality.** A builtin, so no fork per command; `-nt`
  needs a per-shell reference file rewritten on every reload. `-F … b:zstat` loads `zstat`
  alone, because a plain `zmodload zsh/stat` adds a `stat` builtin that shadows
  `/usr/bin/stat`. Inequality, so an older mtime reloads too. One-second resolution: a second
  write in the second of a reload waits for the next change. Verified on zsh 5.9: `stat`
  stays a command. Run against a temp file, the sketch met the unchanged, changed,
  earlier-mtime, syntax-error, alias-clash, mode-000, missing and replaced-mid-hook cases
  under Tests.
- **A failure keeps the old functions.** A `source` that fails halfway has already replaced
  what came before the error. So the hook reads the text once, runs it in a subshell as a
  trial (which inherits the live shell's aliases and options), and runs that same text for
  real only if the trial succeeds: one fork, only on a change. A parse in a fresh `zsh -fn`
  is not enough: zsh expands aliases while parsing, so with `alias ll='ls -l'` live, a file
  defining `f` and then `ll()` passes `zsh -fn` but fails in the live shell (status 126)
  after replacing `f`; measured, the subshell trial fails there too and leaves `f` alone. One
  read means the trial and the load cannot see different versions, whoever writes the file.
  A failure records the mtime, so nothing retries or reprints until the file changes again; a
  `chmod` alone, which leaves the mtime, does not trigger a retry.
- **The mtime is taken before the text is read, and that mtime is recorded.** If the file is
  replaced between the two, the hook loads the newer text under the older mtime, and the
  next command reloads once more, which is harmless because loading is idempotent. The other
  order would load the older text under the newer mtime and stay stale until the next change.
- **Not taken:** snapshotting `$functions` and restoring it on failure (it rewrites the
  whole function table and must remove what a partial load added), and sourcing the file
  twice (a second apply between the reads defeats the trial).
- **A deleted function stays defined** until `exec zsh`. Accepted: removing it needs the names
  the file defined last time, and a name shared with oh-my-zsh would go with it.
- **Scope: the functions file only.** `aliases`, `config` and `zshenv` run evals (starship,
  direnv, mise) and set state.
- **Invariants, both pinned by a test.** The functions file has only function definitions
  and comments at top level (46 definitions on 2026-10-28): it is loaded inside a function,
  where a top-level `typeset` would turn local, and the trial must have no side effects. No
  function reads where it was loaded from (`$0`, `funcsourcetrace`, `functions_source`, `%x`,
  `%N`, `LINENO`: none on 2026-10-28), so loading by `eval` equals `source`.
- Claude Code's shell snapshot copies function definitions but not `preexec_functions`
  (checked in a current snapshot), so agent shells get the hook function, never registered.
- **First deployment needs one restart.** A shell opened before the apply that installs this
  hook has no hook, so it needs one `exec zsh`. Every later change to the functions file
  reloads by itself.

## 2. Merged-branch deletes go to the guard, not the classifier

New `permissions.allow` rules in `dot_claude/modify_private_settings.json`:

| # | Rule | Covers |
|---|---|---|
| A1 | `Bash(git push --force-with-lease=* origin --delete *)` | rule 4's printed form |
| A2 | `Bash(git push --force-with-lease=* origin -d *)` | its `-d` spelling |
| F1 | `Bash(git fetch --prune)` | exact |
| F2 | `Bash(git fetch --prune origin)` | exact |

**Michael's decision, 2026-10-29: `sandbox.autoAllowBashIfSandboxed: false`.** While it was on,
a sandboxed Bash command never reached an allow rule (evidence b), so A1, A2, F1 and F2 would
have changed nothing for the sandboxed `git push` and `git fetch` that agents run. With it off,
a sandboxed command that matches an allow rule runs without the classifier, and one that
matches none goes to the classifier as before. The change was measured first (Step 0, below),
and Michael accepted it with three costs:

- **One new prompt.** A write through a symlink in the working directory that leads outside
  both the working directories and the sandbox allowWrite now prompts. The sandbox would block
  the write anyway. A silent deny for it was tried and not built (below), so it is an accepted
  exception.
- **Rarer prompt paths found only in the code.** These are:
  - `rm` inside `sh -c`, `bash -c` or `eval` with a dangerous or uncheckable target, which
    raises a dangerous-removal dialog that auto-denies after 120 s. Six such shapes were
    measured, and all went to the classifier.
  - A write through an unresolvable link, or into the session-env folder.
  - An internal hard deny.
  - A permission check that throws.
- **Allow becomes deny for some reads.** A Bash command's path arguments now meet the Read()
  and Edit() deny rules, so `wc -l ~/.ssh/config` is denied. Until now the sandbox's
  allowWithinDeny let that read through.

**Step 0, measured 2026-10-29 on 2.1.312.** The harness ran nested `claude -p --model haiku
--permission-mode auto --permission-prompts none` in a scratch repository. `--settings`
overlaid the switch, on as the control and off as the change. Each tool call's
`permission_decision.reason_type` in the stream-json output named the decider, and a would-be
prompt showed as "requires approval … no approval surface".

The results across 46 command shapes:
- **Same with the switch off:** `a & b`, `ls & pwd`, `sleep 0 &`, `cmd 2>&1 | tail`, `$VAR`
  uses and assignments, a heredoc, `git commit`, `git push --dry-run`, a for loop, `$(…)`,
  `find -exec`, a long `rg | sed | sort | head` pipeline, reads and allowWrite writes outside
  the working directory, `git -C` of another repository, and `rm` inside `bash -c`, `sh -c`,
  `eval`, `find -exec` and `xargs`. All of these went to the classifier both ways.
- **Only the decider changed:**
  - `sdd-clean` and `glab mr view --help` went to the classifier with the switch on and matched
    their rule with it off.
  - A pinned merged delete in A1's form, with A1 added to the overlay, went to the classifier on
    and matched its rule off. The deployed guard was silent and the branch was deleted.
  - `rm` of a file or directory in the working directory, and a write through an in-cwd or
    dangling link, went to the classifier on and were decided by `mode` (the acceptEdits path)
    off.
- **Prompts both ways, so not new:** a top-level `rm -rf` outside the working directory.
- **New prompt:** only the link write described above. The same write made directly to the same
  path went to the classifier both ways, and so did a write through a link into `~/Code`.
- **Allow becomes deny:** only `wc -l ~/.ssh/config`.

**Silent deny for the link-write prompt: not built.** In 2.1.312 a `PermissionRequest` hook
receives the common fields plus `tool_name`, `tool_input`, `permission_suggestions` and
`mcp_server`. It receives no decision reason and no safety-check text (read in the binary at
`executePermissionRequestHooks`). It does fire under `--permission-prompts none`.

Measured with a logging hook, the inputs were:
- for the link write: the command plus a suggestion `addDirectories: [~/Desktop]`;
- for a dangerous-removal prompt: the command alone.

So a hook could recognise the link-write case only by guessing from the command text or from a
suggested remedy. It cannot see the reason, and a guess could turn another prompt, a
destructive one included, into a deny.

**Every allow rule now runs without the classifier when sandboxed.** Reviewed one by one:
- **The glab reads** (`ci list`, `ci get`, `mr view`, `issue view`, `auth status`) stay as they
  are.
- **`chezmoi diff` and `chezmoi status` are narrowed to the exact commands.** In the `*` forms,
  `--config`, `--source` or `--destination` let a configured diff command or a template's
  `output` call run arbitrary sandboxed code. Nothing in the repository or the instructions
  passes them arguments: the README's `chezmoi diff --dirty-ok` is Michael's wrapper flag,
  typed by him.
- **`sdd-clean *` stays.** It refuses anything but a git-ignored, untracked
  `<top>/.superpowers/sdd/<name>` that holds no `.git`. The git it runs reads that repository's
  config, which the sandbox lets an agent write only in the session scratchpad.
- **A1 and A2** are judged by the guard (below).
- **F1 and F2** are exact.
- **The basecamp reads are unaffected:** basecamp is an excluded command, so it already runs
  unsandboxed and its rules already applied.
- **`WebFetch(domain:launchpad.37signals.com)`** is not Bash, so the switch does not touch it.

**Michael's decision, 2026-10-28, after the final whole-branch review: no `-C` rule.** The
signed-off design had A4, `Bash(git -C * push --force-with-lease=* origin --delete *)`. Its
`*` comes before the subcommand, so it matched commands the guard could not judge safely
(another git subcommand, a quoted first word, injected options on a dry run). It is dropped,
with its mirror entry. A delete-shaped push in another repository goes to the classifier, and
the agent hands Michael the command.

**The guard mirrors the push rules.** A `*` matches any text, so a pattern cannot prove what
git will parse. `git-push-guard.py` therefore holds the same A1 and A2 patterns in its own list
and matches them with Claude Code's semantics (`*` matches anything, spaces included). It
searches the raw command text, the text with `\`-newline continuations joined, each of those
with every quote and backslash removed, and the shell-unquoted tokens joined with spaces. Every
reading is also taken twice more, with ANSI-C `$'…'` quoting decoded as bash decodes it and as
zsh decodes it, and with `$"…"` read as `"…"` (controller's ruling, after the final review's
fourth re-review: before it, `$'\x67it' push …` matched no reading and the guard was silent on
it; evidence c). The two shells differ: zsh reads a `\x`, `\u` or `\U` with no hex digit as a
NUL and cuts the whole word at a NUL, so `$'\x67it\x' push …` runs git in zsh only. The
decoder is checked against bash 3.2, bash 5.3 and zsh by enumerating the escape grammar, not
by sampling it; the guard suite's header records the totals and every accepted mismatch, each
of which leaves the guard stricter.

The guarantee is that the search is a superset of Claude Code's match. Claude Code 2.1.312
(read in the binary) matches each subcommand after stripping wrappers, safe assignments and
comment lines, and after removing the quotes from the first word, so `"git" push …` matches A1.

The guard does not model spellings that only evaluation produces: a variable (`G=git; $G push
…`), `eval`, a nested shell, or an alias. These match no rule's text in Claude Code either, so
they reach the classifier.

The `$'…'` decoding is the second layer behind Claude Code's own (evidence c). Controller's
ruling, after the fifth re-review: no context-free decoding round. Contexts the decoder misreads
(a `#` after an escaped blank, `$'…'` inside `"$(…)"` or after a heredoc, `$$'` in bash, an
array in a zsh cut tail) cannot reach A1, because Claude Code declines the command first.

The search runs first, over the whole command. A command whose text matches (a command, not
only a push) gets its verdict from what the guard parses:

| Parsed as | Verdict |
|---|---|
| not a plain command the guard can parse (a compound command, a redirect other than `2>&1`, unbalanced quotes) | silent deny with today's reason: "run the push as a plain command of its own …" |
| a plain git command whose literal subcommand is not `push` (a commit message quoting the delete form) | silent deny: "this command matches a delete allow rule but is not a delete push; reword it so it does not carry the delete form (a commit message quoting it, for example)" |
| delete-only, every branch merged and pinned, bare | silent pass: it runs, the classifier skipped |
| delete-only, every branch merged, but not bare or not pinned | silent deny; the reason is the bare pinned command (below) |
| delete-only, with a branch unmerged, the default branch, or a failed merge read | ask, as today |
| anything else: an update, a mixed push, a delete without a refspec, an option value that swallowed `--delete`, a quoted spoof | silent deny: "this command matches a delete allow rule but git would not parse it as a delete-only push; push normally, without the delete shape" |

- **Bare** means the command is `git push …` with no global option, no `cd` prefix, no
  variable assignment and no wrapper, and in canonical text (controller's ruling, 2026-10-28,
  after the final review's fix rounds: an allowlist of the shell surface instead of a
  denylist). Canonical: the raw command, with at most one trailing newline removed and then
  its leading and trailing spaces stripped (a leading newline or a second trailing one is not
  canonical), is `git push` and its arguments separated by single spaces, then at most one
  trailer: ` 2>&1`, ` | tail -n N`, ` | head -n N`, ` 2>&1 | tail -n N` or
  ` 2>&1 | head -n N`, N digits. Every argument matches `^[A-Za-z0-9._/:=@+,%-]+$`, and none
  starts with `=` (zsh's EQUALS expansion; the Bash tool runs Michael's zsh). The allowlist
  is checked under bash and zsh by differential fuzzing (the guard suite's header records
  it). A delete of a branch whose name needs another character is not bare: it gets the
  not-bare verdicts below, and the agent hands Michael the command. The remote word must
  name a configured remote: rule 4 refuses any other ("which is not a configured remote").
  A mirrored dry run used to return before that check; it now meets it too, so a path or URL
  in the remote position never passes. `parse_plain` records every global option it reads; today it
  drops `--exec-path`. `-c`, `--config-env`, `--git-dir`, `--work-tree` and `--namespace`
  keep today's deny.
- **Printed commands** (controller's ruling, from Michael's decision): every deny reason that
  prints a corrected command, mirrored or not, prints the plain `git push …` form when the
  push's repository is the session's cwd. When it is not, the reason says the delete must run
  from that checkout, or that Michael runs it; it no longer prints a `git -C … push` form,
  which no rule allows. A printed word that starts with `=` is quoted, since zsh would expand
  it.
- **Dry runs** (controller's ruling, final review C1): for a mirrored command the option denies
  run before the dry-run early return, and a mirrored dry run passes silently only when it is
  bare; otherwise it is denied. A push option can ride inside A1's or A2's first `*`. A dry run
  that matches no pattern keeps today's early return, and a push that matches no pattern keeps
  today's verdict.
- **Reasons** (controller's ruling, final review I1): a mirrored command the guard cannot parse
  as a plain command gets today's plain-command reason, which names the form to use;
  "not a delete push" is kept for a parsed git command that is not a push.
- Every row is today's verdict or stricter. A non-bare merged delete went silently to the
  classifier and now gets a silent deny; no row adds a prompt. The guard's `ask` or `deny`
  overrides an allow rule (evidence b), so the only command an allow rule runs unjudged is
  the pass row.
- **Controller's ruling, 2026-10-28, after Michael's sign-off: the first two rows** (a command,
  not only a push). They closed a hole in A4, whose `*` before the subcommand matched
  `git -C <r> -c core.fsmonitor=<cmd> status push --force-with-lease=a origin --delete b`,
  on which the guard was silent (measured). With A4 dropped they still cover a command that
  merely quotes the delete form, which the unanchored search matches; that costs a silent deny.

**Evidence (a), wildcards.** Permissions docs, "Wildcard patterns" (read 2026-10-28): "A `*`
in a Bash rule matches any text, including spaces" and "can go anywhere in the rule: at the
start, in the middle, or at the end"; `Bash(git log * main)` matches `git log --oneline main`,
not `git push origin main`. Each subcommand is matched whole, after splitting on `&&`, `||`,
`;`, `|`, `&` and newlines. Claude Code 2.1.312's rule validator (read in the binary) adds:
a rule ending in `:*` is the legacy prefix form and an earlier `*` is not expanded, so
`… origin :*` would never match; an allow rule with a `*` before the subcommand is valid but
raises a settings warning ("has a wildcard before the rest of the command … For git, options
such as -c and --exec-path can run arbitrary commands"). That was A4, now dropped; no
remaining rule raises it.

**Evidence (b), a hook with an allow rule.** Hooks docs: `"deny"` prevents the call, `"ask"`
prompts, and "A hook's "ask" also forces a permission prompt in auto mode: the classifier
can still deny the tool call, but it can't approve the call silently". Permissions docs: "A
blocking hook also takes precedence over allow rules". Auto mode, step 1: "Actions matching
your allow, ask, or deny rules resolve immediately", so a matched allow rule skips the
classifier. Measured 2026-08-25 on 2.1.245: hook `ask` plus a matching allow rule prompts; a
silent hook plus one runs.

Corrected 2026-10-29: that measurement holds only for commands that run unsandboxed. In 2.1.312,
while `autoAllowBashIfSandboxed` is on, a sandboxed Bash command never reaches the allow rules:
- The sandbox auto-allow (`gze`) runs before prefix and exact rule matching. It consults only
  the deny and ask rules, and otherwise allows the command ("Auto-allowed with sandbox").
- Auto mode then sends that allow to the classifier (`WDr` maps it to "sandbox": "Auto mode held
  this command for the server-side classifier to review").

The logged decisions agree. Sandboxed, `sdd-clean` was decided by the classifier 27 times out
of 27 and `glab mr view` 4 of 4; unsandboxed, both were decided by their rule. Step 0 measured
the same, which is why Michael turned the setting off.

**Evidence (c), ANSI-C quoting.** Two layers cover a delete spelled with `$'…'`.

- **The first is Claude Code.** Its Bash permission check returns an ask for a command too
  complex to read as simple commands, such as one whose first word is `$'…'`, and it does so
  before any rule matching (read in 2.1.312). In auto mode that ask goes to the classifier.
  Measured 2026-10-29 with auto-allow off: `$'\x67lab' mr view --help` went to the classifier,
  while `glab mr view --help` matched its rule.
- **The second is the guard.** Its decoded readings mirror `$'\x67it' push …`,
  `git $'\x70ush' …` and the zsh-only `$'\x67it\x' push …`. None is canonical, so all are
  denied. For `$'…'` in a later word, which was not measured in Claude Code, the guard denies
  the command regardless.

Rulings:

- **No `:<ref>` rule.** A `:refs/heads/*` rule would also match a mixed delete and update,
  and `… origin :*` never matches (evidence a). Agents use A1, as the guard prints.
- **Left to the classifier:** remotes other than `origin`, other argument orders, `:<ref>`
  refspecs, and every delete push in another repository (`git -C`, or a `cd` to a checkout
  other than the session's), whose command the agent hands to Michael.
- **Fetch: exact rules only.** `git config --get fetch.prune` prints `true` here (from
  `dot_config/git/config`), so every fetch already prunes; F1 and F2 only stop the classifier
  reacting to the word. No `*` after `--prune`: `git fetch --prune origin
  '+refs/heads/*:refs/heads/*'` rewrites and prunes local branches. No `-C` form: nothing
  guards fetch, so `git -C * fetch …` would approve `-c core.sshCommand=…` at its `*`.
- **No rule for `git branch -d`:** it refuses an unmerged branch itself and was not denied;
  `Bash(git branch -D*)` stays an ask rule.
- **Residual, accepted: fail direction.** If the guard is missing or broken and returns no
  decision, a matching delete runs without the classifier. The guard fails closed on its own
  errors (a 30 s budget inside the 60 s hook timeout, a deny on a helper failure),
  `disableAllHooks: false` is pinned, and the guard and the allow rules deploy together
  through chezmoi, so they cannot drift apart.
- A Bash call that passes `allowed_domains` goes to the classifier despite a matching rule.

## 3. Instructions

`.chezmoitemplates/agents/global.md`, the "Every agent confirms first" bullet, reworded in
place; four lines stay four and the file stays at its 180-line cap. Michael's decision,
2026-10-28, after the final whole-branch review: this wording, which keeps "history others
have" and "not the check" from the old rule (the signed-off text had narrowed both):

```
- **Every agent confirms first** before force-pushing without a lease, rewriting history
  others have, deleting branches, tags, data or infrastructure, discarding uncommitted work
  it did not create, or pushing to the default branch. Exempt: a lease on your own branch, a
  merged branch's pinned delete, `git branch -d`. Harness prompts are a backstop, not the check.
```

A pinned delete is rule 4's shape: a delete-only push carrying `--force-with-lease=<b>:<sha>`
for each deleted branch, as the guard's deny reason prints it.

## Non-goals

Reloading aliases, config or zshenv; `wt-rm` keeping branches not merged into main (the
`blabla` case); harness worktree locks; the push guard's other rules, and its verdicts for a
push that matches no delete pattern. Observed, not changed: startup sources the functions
after the aliases and oh-my-zsh, so a function named like a live alias already fails there.

## Tests

- **`tests/zshrc-reload.test.sh`**, new and sandboxed, split from the pty-bound
  `zshrc.test.sh` as `dev-topology` is from `dev`. A non-pty `/bin/zsh -f` sources the source
  `dot_zshrc` with `zshrc.test.sh`'s stubs and a functions fixture, checks the registration,
  then removes it and calls the hook directly: zsh 5.9 runs `preexec` hooks before each line
  of a `zsh -f` script too (measured), which would reload between a test's own lines.
  mtimes are set with `touch -t`, never by waiting. Cases: registered in `preexec_functions`,
  not `precmd_functions`, and `stat` is no builtin; unchanged file: silent, not re-sourced (the
  fixture counts loads); changed: the new function runs, stderr is exactly the reload line; an
  earlier mtime reloads; a syntax error keeps the old function with one line, a second call is
  silent, the fixed file reloads; mode 000 and missing files likewise; with `alias ll='ls -l'`
  live, a file defining `f` then `ll()` keeps the old `f` with one line, and reloads once the
  alias is gone and the mtime moves; replaced between the stat and the read (the test shadows
  `zstat` with a function that calls `builtin zstat` and then swaps the file in by rename),
  the newer version is loaded, the next call reloads it once more and the call after is
  silent; a removed function stays defined; the real functions file holds both invariants.
- **`tests/zshrc.test.sh`** (pty), one case: with the prompt drawn the functions file changes,
  and Enter on `f` prints the reload line, then the new output.
- **`tests/claude-settings.test.sh`:** the four rules pinned as a set; "no mutating verb is
  allowlisted" exempts exactly A1 and A2, as it does `sdd-clean`. **Parity:** the rendered
  allow rules that run `git … push` must equal the guard's mirror list.
  A matcher model of the documented semantics, calibrated on the docs' rows: no rule matches
  `git push`, `git push origin feat`, `git push --force-with-lease=feat:<sha> origin feat`,
  `git push origin main`, `git -C /r push origin main`,
  `git -C /r push --force-with-lease=b:<sha> origin --delete b`,
  `git fetch --prune origin '+refs/heads/*:refs/heads/*'` or `git -C /r fetch --prune origin`;
  the printed form, its `-d` spelling and `git fetch --prune origin` match. No allow rule ends
  in `:*` with a `*` before it, and no allow rule has a `*` before its subcommand.
  `sandbox.autoAllowBashIfSandboxed` is pinned to `false`. The chezmoi rules are exactly
  `chezmoi diff` and `chezmoi status`, with no `*` form.
- **`tests/agent-instructions.test.sh`:** `need` the new exception text; caps unchanged.
- **`tests/git-forge-guard.test.sh`**, rule 4's merged-delete section, one case per row:
  - bare, merged, pinned: silent, once per allowed trailer; a quoted first word
    (`"git" push …`): deny naming the plain form;
  - not canonical, one case per class, each denied: a glob in an option value, brackets, a
    quoted operator, an escaped operator, NUL, `\r`, NBSP, `$`, a backtick, `~`, a leading
    `=` (the dry run `git push --force-with-lease=a -n origin --delete =x`, and a merged,
    pinned delete of branch `=e`, whose printed command quotes `'=e'`), a brace, a leading
    newline and a second trailing newline; one trailing newline stays canonical;
  - ANSI-C quoting, each denied: `$'\x67it' push …`, `git $'\x70ush' …`, and the zsh-only
    `$'\x67it\x' push …`, `$'\x67it\0'zz push …` and `git $'\x70ush\u' …` in A1's shape;
  - merged and pinned behind a wrapper (`command`), an assignment or a `cd` to the cwd: deny
    naming the plain pinned `git push …` form; behind a `cd` to another checkout: deny saying
    it must run from that checkout or Michael runs it;
  - a `-C` delete matches no rule: today's verdict, and an unpinned one's reason no longer
    prints a `git -C … push` form (it says run it from that checkout or hand it to Michael);
  - a mirrored dry run that is not bare (a wrapper, an assignment, a `cd`): deny; a bare one:
    silent;
  - a quoted first word on Codex's push-option spoof: deny;
  - a compound command in A1's shape: today's plain-command reason;
  - a pinned delete of the unmerged branch in A1's shape: ask;
  - `git push --force-with-lease=feat:<sha> --push-option="ci.variable=X= origin --delete x"
    origin feat`, `git push --force-with-lease=feat:<sha> -o --delete origin feat` and the
    refspec-less `git push --force-with-lease=done:<sha> origin --delete --no-verify`: deny.
    The `-o --delete` case does not exercise the mirror: its text lacks A1's
    ` origin --delete `, and today's push-option check already denies it; it pins that deny.
    No option can swallow `--delete` inside A1's text, since A1 needs `origin` right before
    it and `origin` takes no value;
  - an update push in no delete shape (`git push --force-with-lease=feat:<sha> origin feat`):
    today's verdict. The existing rule-4 cases stay green;
  - a command that pushes nothing and holds a `$'…'` word cut before a substitution
    (`echo $'\x'$(date +%s)`): silent.

## Verification after Michael's apply

1. A shell opened after the apply, so with the hook, prints the reload line once on its next
   command after a later change to the functions file (the next apply that changes it, or a
   `touch` of the deployed file), and runs the new code. Shells opened before this apply get
   one `exec zsh`.
2. In a fresh auto-mode session, a pinned delete of a merged throwaway branch in the canonical
   form runs without the classifier (its logged reasonType is a rule, not the classifier) and
   without a prompt. A pinned delete of an unmerged one prompts.
3. Startup shows no settings warning for the new rules.
4. Sandboxed `glab mr view --help` logs reasonType `rule` or `subcommandResults`, not
   `classifier`.
5. Sandboxed `$'\x67lab' mr view --help` does not log `rule`.
6. A write through a symlink in the working directory to a path outside the working
   directories and the sandbox allowWrite prompts (the accepted exception). The same write
   made directly goes to the classifier.

## Expected effect

Prompts:
- One rare class is added: the link write in verification item 6. The code-only paths listed
  in section 2 remain possible.
- Every delete that asked before still asks.

Bash reads under a Read() deny rule, such as `~/.ssh/config`, are now denied.

Pinned merged deletes in the guard's printed form and `git fetch --prune` go from a classifier
denial, then Michael by hand, to running. Sandboxed commands that match an allow rule
(`sdd-clean`, the glab reads) skip the classifier.
