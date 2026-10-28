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

`dot_zshrc`, right after it sources the functions file, records the file's mtime and registers
a `preexec` hook that reloads on a changed mtime. The hook lives in `dot_zshrc`, never in the
functions file, so a reload never redefines the running function. Sketch (the plan settles it):

```zsh
zmodload -F zsh/stat b:zstat && {
  typeset -g _zshrc_fn=$HOME/.config/zsh/functions _zshrc_fn_failed
  typeset -ga _zshrc_fn_mtime
  zstat -A _zshrc_fn_mtime +mtime -- $_zshrc_fn 2>/dev/null || _zshrc_fn_mtime=missing
  _zshrc_reload_functions() {
    local -a m
    zstat -A m +mtime -- $_zshrc_fn 2>/dev/null || m=missing
    [[ $m == $_zshrc_fn_mtime ]] && return 0
    if [[ $m != missing && -r $_zshrc_fn ]] && zsh -fn -- $_zshrc_fn 2>/dev/null &&
        source $_zshrc_fn; then
      _zshrc_fn_mtime=$m _zshrc_fn_failed=
      print -ru2 -- 'zsh: reloaded ~/.config/zsh/functions'
    elif [[ $m != $_zshrc_fn_failed ]]; then
      _zshrc_fn_failed=$m
      print -ru2 -- 'zsh: cannot reload ~/.config/zsh/functions; keeping the old functions'
    fi
  }
  autoload -Uz add-zsh-hook && add-zsh-hook preexec _zshrc_reload_functions
}
```

- **`preexec`, not `precmd`:** `precmd` runs before a prompt is drawn, so a prompt drawn
  before the apply would run one stale command. `preexec` runs after Enter.
- **mtime by `zstat`, compared for inequality.** A builtin, so no fork per command, and the
  value lives in a shell variable; `-nt` needs a per-shell reference file rewritten on every
  reload. `zmodload -F zsh/stat b:zstat` loads `zstat` alone: a plain `zmodload zsh/stat` adds
  a `stat` builtin that shadows `/usr/bin/stat` in every shell. Inequality, so an older mtime
  reloads too. One-second resolution: a second write in the second of a reload waits for the
  next change. Verified on zsh 5.9: `whence -w stat` stays `command`; `zstat` on a missing
  file returns 1; `zsh -fn` returns 1 on an unclosed brace and 0 on the real file. Run
  against a temp file, the sketch met the unchanged, changed, earlier-mtime, syntax-error,
  mode-000 and missing cases under Tests.
- **A failure keeps the old functions.** A `source` that fails halfway has already replaced
  what came before the error, so the file is parsed first (`zsh -fn`, forked only on a change).
  Missing, unreadable or unparsable: nothing is sourced, one stderr line, the mtime is not
  recorded and the next command retries; the line repeats only after the mtime changes again.
- **A deleted function stays defined** until `exec zsh`. Accepted: removing it needs the names
  the file defined last time, and a name shared with oh-my-zsh would go with it.
- **Scope: the functions file only.** `aliases`, `config` and `zshenv` run evals (starship,
  direnv, mise) and set state.
- **Invariant:** the functions file has only function definitions and comments at top level
  (46 definitions on 2026-10-28). The hook sources it inside a function, where a top-level
  `typeset` would turn local. A test pins it.
- If `zmodload` fails there is no hook, and startup is as today.
- **First deployment needs one restart.** A shell opened before the apply that installs this
  hook has no hook, so it needs one `exec zsh`. Every later change to the functions file
  reloads by itself.

## 2. Merged-branch deletes go to the guard, not the classifier

New `permissions.allow` rules in `dot_claude/modify_private_settings.json`:

| # | Rule | Covers |
|---|---|---|
| A1 | `Bash(git push --force-with-lease=* origin --delete *)` | rule 4's printed form |
| A2 | `Bash(git push --force-with-lease=* origin -d *)` | its `-d` spelling |
| A4 | `Bash(git -C * push --force-with-lease=* origin --delete *)` | A1 in another repository |
| F1 | `Bash(git fetch --prune)` | exact |
| F2 | `Bash(git fetch --prune origin)` | exact |

**The guarantee.** A `*` in a rule always matches extra arguments, so the patterns do not
prove a push delete-only. The guarantee is that every push a new rule matches still passes
through `git-push-guard.py`, which stays silent only for a merged, pinned, delete-only push
from a bare invocation (below) or a dry run, and otherwise asks or denies; its `ask` or `deny`
overrides an allow rule (evidence b). Merged and pinned: runs, without the classifier. Merged
but unpinned: the guard's silent deny naming the pinned command. Anything else (unmerged, the
default branch, an extra global option, a network error): the guard's ask. A dry run changes
nothing.

**Rule 4's silent pass needs a bare invocation (a guard change).** In `git-push-guard.py`,
the merged-delete pass (`merged_delete` returning `True`) applies only when the git
invocation carries no global option other than one `-C <path>`, and no leading variable
assignment (`GIT_EXEC_PATH` is `--exec-path`'s environment form). With `--exec-path[=…]`,
`--no-pager`, `-p`, `--bare`, a second `-C` or any other global option, the delete ask
stands, as today. The unpinned silent deny is unchanged. `-c`, `--config-env`, `--git-dir`,
`--work-tree` and `--namespace` keep today's deny, which `evaluate` raises before rule 4.
`parse_plain` must therefore record every global option it reads; today it drops
`--exec-path` silently. This only tightens: no verdict moves toward allow, and pushes other
than merged deletes are unchanged.

**Evidence (a), wildcards.** Permissions docs, "Wildcard patterns" (read 2026-10-28): "A `*`
in a Bash rule matches any text, including spaces" and "can go anywhere in the rule: at the
start, in the middle, or at the end"; `Bash(git log * main)` matches `git log --oneline main`,
not `git push origin main`. Each subcommand is matched whole, after splitting on `&&`, `||`,
`;`, `|`, `&` and newlines. Claude Code 2.1.312's rule validator (read in the binary) adds:
a rule ending in `:*` is the legacy prefix form and an earlier `*` is not expanded, so
`… origin :*` would never match; an allow rule with a `*` before the subcommand is valid but
raises a settings warning ("has a wildcard before the rest of the command … For git, options
such as -c and --exec-path can run arbitrary commands"): A4.

**Evidence (b), a hook with an allow rule.** Hooks docs: `"deny"` prevents the call, `"ask"`
prompts, and "A hook's "ask" also forces a permission prompt in auto mode: the classifier
can still deny the tool call, but it can't approve the call silently". Permissions docs: "A
blocking hook also takes precedence over allow rules". Auto mode, step 1: "Actions matching
your allow, ask, or deny rules resolve immediately", so a matched allow rule skips the
classifier. Measured 2026-08-25 on 2.1.245: hook `ask` plus a matching allow rule prompts; a
silent hook plus one runs.

Rulings:

- **What the patterns still exclude.** A1, A2 and A4 need `--delete` or `-d` after the
  remote, and git then deletes every listed ref, so a plainly written update push matches no
  rule; deleting the default branch asks (rule 4 excludes it). Text quoted inside another
  argument can still match, and that push still meets the guard.
- **No `:<ref>` rule.** A `:refs/heads/*` rule would also match a mixed delete and update
  (`… origin :refs/heads/a feat`), and `… origin :*` never matches (evidence a). Agents use
  A1 or A4, the form the guard prints.
- **Left to the classifier:** remotes other than `origin`, other argument orders, `:<ref>`
  refspecs, and `-C` with `-d`.
- **A4 is one rule, so one warning.** Every option the warning names is either denied on a
  push (`-c`, `--config-env`, `--git-dir`, `--work-tree`, `--namespace`, unknown options) or,
  after the tightening above, takes away the silent pass (`--exec-path` and the rest).
- **Fetch: exact rules only.** `fetch.prune = true` in `dot_config/git/config` (here,
  `git config --get fetch.prune` prints `true`, from `~/.config/git/config`) already makes
  every fetch prune; F1 and F2 only stop the classifier reacting to the word. No `*` after
  `--prune`: `git fetch --prune origin '+refs/heads/*:refs/heads/*'` rewrites and prunes local
  branches. No `-C` form: nothing guards fetch, so `git -C * fetch …` would approve
  `-c core.sshCommand=…` at its `*`, and `git -C <repo> fetch origin` prunes anyway.
- **No rule for `git branch -d`:** it refuses an unmerged branch itself and was not denied;
  `Bash(git branch -D*)` stays an ask rule.
- **Residual, accepted: fail direction.** For matched shapes the guard is the only judge. If
  it is missing or broken and returns no decision, a matching delete runs without the
  classifier, where before the classifier judged it. The guard fails closed on its own errors
  (a 30 s budget inside the 60 s hook timeout, a deny on a helper failure), and
  `disableAllHooks: false` is pinned. The guard and the allow rules deploy together through
  chezmoi, so they cannot drift apart.
- A Bash call that passes `allowed_domains` goes to the classifier despite a matching rule.
  SSH pushes need none.
- **Not taken:** the guard returning `"allow"` for a proven delete. It fails toward the
  classifier and matches no text, but it changes the guard's output contract, and the docs do
  not say whether a hook `"allow"` skips the auto-mode classifier.

## 3. Instructions

`.chezmoitemplates/agents/global.md`, the "Every agent confirms first" bullet, reworded in
place; four lines stay four and the file stays at its 180-line cap:

```
- **Every agent confirms first** before force-pushing without a lease, rewriting others'
  history, deleting branches, tags, data or infrastructure, discarding uncommitted work it
  did not create, or pushing to the default branch. A lease on your own branch needs none, nor
  does a merged branch's pinned delete and `git branch -d`. Harness prompts are a backstop.
```

A pinned delete is rule 4's shape: a delete-only push carrying `--force-with-lease=<b>:<sha>`
for each deleted branch, as the guard's deny reason prints it.

## Non-goals

Reloading aliases, config or zshenv; `wt-rm` keeping branches not merged into main (the
`blabla` case); harness worktree locks; the push guard's rules, unchanged apart from the
rule-4 tightening in section 2.

## Tests

- **`tests/zshrc-reload.test.sh`**, new and sandboxed, split from the pty-bound
  `zshrc.test.sh` as `dev-topology` is from `dev`. A non-pty `/bin/zsh -f` sources the source
  `dot_zshrc` with `zshrc.test.sh`'s stubs and a functions fixture, then calls the hook.
  mtimes are set with `touch -t`, never by waiting. Cases: registered in `preexec_functions`,
  not `precmd_functions`, and `stat` is no builtin; unchanged file: silent, not re-sourced (the
  fixture counts loads); changed: the new function runs, stderr is exactly the reload line; an
  earlier mtime reloads; a syntax error keeps the old function with one line, a second call is
  silent, the fixed file reloads; mode 000 and missing files likewise; a removed function stays
  defined; the real functions file has only definitions and comments at top level.
- **`tests/zshrc.test.sh`** (pty), one case: with the prompt drawn the functions file changes,
  and Enter on `f` prints the reload line, then the new output.
- **`tests/claude-settings.test.sh`:** the five rules pinned as a set. "no mutating verb is
  allowlisted" exempts exactly A1, A2 and A4, as it does `sdd-clean`. A matcher model of the
  documented semantics (whole text; `*` any text; a trailing ` *` that is the only `*` also
  matches the bare command), calibrated on the docs' rows. No rule matches `git push`,
  `git push origin feat`, `git push --force-with-lease=feat:<sha> origin feat`,
  `git push origin main`, `git push --force-with-lease=main:<sha> origin main`,
  `git push --force-with-lease=refs/heads/a:<sha> origin :refs/heads/a feat`,
  `git -C /r push origin main`, `git fetch --prune origin '+refs/heads/*:refs/heads/*'` or
  `git -C /r fetch --prune origin`. The printed form with and without `-C`, its `-d`
  spelling and `git fetch --prune origin` match. No allow rule ends in `:*` with a `*` before
  it.
- **`tests/agent-instructions.test.sh`:** `need` the new exception text; caps unchanged.
- **`tests/git-forge-guard.test.sh`**, in rule 4's merged-delete section: a merged, pinned
  delete as `git -C <path> push …` from another directory is silent; the same with
  `--exec-path=<dir>`, `--no-pager`, a second `-C` or a leading `GIT_EXEC_PATH=<dir>` asks;
  the same with `-c x.y=z` keeps today's deny. The existing rule-4 cases stay green.

## Verification after Michael's apply

1. A shell opened after the apply, so with the hook, prints the reload line once on its next
   command after a later change to the functions file (the next apply that changes it, or a
   `touch` of the deployed file), and runs the new code. Shells opened before this apply get
   one `exec zsh`.
2. In a fresh auto-mode session, a pinned delete of a merged throwaway branch runs without a
   prompt or a denial; a pinned delete of an unmerged one prompts.
3. Startup shows one settings warning, for A4.

## Expected effect

Net prompts: none added; every delete that asked before still asks. Pinned merged deletes in
the guard's printed form and `git fetch --prune` go from a classifier denial, then Michael by
hand, to running.
