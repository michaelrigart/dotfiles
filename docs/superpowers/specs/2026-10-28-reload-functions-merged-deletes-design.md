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
- **mtime by `zstat`, compared for inequality.** A builtin, so no fork per command; `-nt`
  needs a per-shell reference file rewritten on every reload. `-F … b:zstat` loads `zstat`
  alone, because a plain `zmodload zsh/stat` adds a `stat` builtin that shadows
  `/usr/bin/stat`. Inequality, so an older mtime reloads too. One-second resolution: a second
  write in the second of a reload waits for the next change. Verified on zsh 5.9: `stat`
  stays a command; `zsh -fn` returns 0 on the real file. Run against a temp file, the sketch
  met the unchanged, changed, earlier-mtime, syntax-error, mode-000 and missing cases below.
- **A failure keeps the old functions.** A `source` that fails halfway has already replaced
  what came before the error, so the file is parsed first (`zsh -fn`, forked only on a change).
  The failure line repeats only after the mtime changes again; every command retries.
- **A deleted function stays defined** until `exec zsh`. Accepted: removing it needs the names
  the file defined last time, and a name shared with oh-my-zsh would go with it.
- **Scope: the functions file only.** `aliases`, `config` and `zshenv` run evals (starship,
  direnv, mise) and set state.
- **Invariant:** the functions file has only function definitions and comments at top level
  (46 definitions on 2026-10-28). It is sourced inside a function, where a top-level
  `typeset` would turn local. A test pins it.
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

**The guard mirrors the push rules.** A `*` matches any text, so a pattern cannot prove what
git will parse. `git-push-guard.py` therefore holds the same A1, A2 and A4 patterns in its own
list and matches them with Claude Code's semantics (`*` matches anything, spaces included) as
a search over the raw command text, `\`-newline continuations joined. That is a superset of
Claude Code's match, which runs per subcommand after stripping wrappers and safe assignments.
A push whose text matches gets its verdict from what the guard parses:

| Parsed as | Verdict |
|---|---|
| delete-only, every branch merged and pinned, bare | silent pass: it runs, the classifier skipped |
| delete-only, every branch merged, but not bare or not pinned | silent deny; the reason is the bare pinned command |
| delete-only, with a branch unmerged, the default branch, or a failed merge read | ask, as today |
| anything else: an update, a mixed push, a delete without a refspec, an option value that swallowed `--delete`, a quoted spoof | silent deny: "this command matches a delete allow rule but git would not parse it as a delete-only push; push normally, without the delete shape" |

- **Bare** means the command is `git [-C <path>] push …`, optionally piped to `tail` or
  `head`: no other global option (`--exec-path`, `--no-pager`, a second `-C`, …), no `cd`
  prefix, no variable assignment (`GIT_EXEC_PATH` is `--exec-path`'s environment form) and no
  wrapper. `parse_plain` records every global option it reads; today it drops `--exec-path`.
  `-c`, `--config-env`, `--git-dir`, `--work-tree` and `--namespace` keep today's deny.
- A dry run keeps today's silent early return. A push that matches no pattern keeps today's
  behaviour exactly.
- Every row is today's verdict or stricter. A non-bare merged delete went silently to the
  classifier and now gets a silent deny; no row adds a prompt. The guard's `ask` or `deny`
  overrides an allow rule (evidence b), so the only push an allow rule runs unjudged is the
  first row.

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

- **No `:<ref>` rule.** A `:refs/heads/*` rule would also match a mixed delete and update,
  and `… origin :*` never matches (evidence a). Agents use A1 or A4, as the guard prints.
- **Left to the classifier:** remotes other than `origin`, other argument orders, `:<ref>`
  refspecs and `-C` with `-d`.
- **A4's warning is accepted:** one rule, so one warning, and the mirror judges every option
  it names.
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
`blabla` case); harness worktree locks; the push guard's other rules, and its verdicts for a
push that matches no delete pattern.

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
- **`tests/claude-settings.test.sh`:** the five rules pinned as a set; "no mutating verb is
  allowlisted" exempts exactly A1, A2 and A4, as it does `sdd-clean`. **Parity:** the
  rendered allow rules that run `git … push` must equal the guard's mirror list.
  A matcher model of the documented semantics, calibrated on the docs' rows: no rule matches
  `git push`, `git push origin feat`, `git push --force-with-lease=feat:<sha> origin feat`,
  `git push origin main`, `git -C /r push origin main`,
  `git fetch --prune origin '+refs/heads/*:refs/heads/*'` or `git -C /r fetch --prune origin`;
  the printed form with and without `-C`, its `-d` spelling and `git fetch --prune origin`
  match. No allow rule ends in `:*` with a `*` before it.
- **`tests/agent-instructions.test.sh`:** `need` the new exception text; caps unchanged.
- **`tests/git-forge-guard.test.sh`**, rule 4's merged-delete section, one case per row:
  - bare, merged, pinned, with and without `-C <path>`: silent;
  - merged and pinned with `--exec-path=<dir>`, `--no-pager`, a second `-C` or a leading
    `GIT_EXEC_PATH=<dir>`: deny naming the bare pinned command; with `-c x.y=z`: today's deny;
  - a pinned delete of the unmerged branch in A1's shape: ask;
  - `git push --force-with-lease=feat:<sha> --push-option="ci.variable=X= origin --delete x"
    origin feat`, `git push --force-with-lease=feat:<sha> -o --delete origin feat` and the
    refspec-less `git push --force-with-lease=done:<sha> origin --delete --no-verify`: deny;
  - an update push in no delete shape (`git push --force-with-lease=feat:<sha> origin feat`):
    today's verdict. The existing rule-4 cases stay green.

## Verification after Michael's apply

1. A shell opened after the apply, so with the hook, prints the reload line once on its next
   command after a later change to the functions file (the next apply that changes it, or a
   `touch` of the deployed file), and runs the new code. Shells opened before this apply get
   one `exec zsh`.
2. In a fresh auto-mode session, a pinned delete of a merged throwaway branch runs without a
   prompt or a denial; a pinned delete of an unmerged one prompts.
3. Startup shows one settings warning, for A4.

## Expected effect

Net prompts: none added; every delete that asked before still asks, and nothing else asks.
Pinned merged deletes in the guard's printed form and `git fetch --prune` go from a classifier
denial, then Michael by hand, to running.
