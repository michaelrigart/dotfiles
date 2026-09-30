# Safe autonomy — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented. Completed 2026-10-01 on `feat/safe-autonomy`; do not re-run. Review
fix rounds changed several tasks' code beyond this text. The spec's "Implementation notes"
record the result.

**Goal:** Let an agent carry a task from signed-off spec to pushed branch or Draft MR without Michael, while the harness (not the model) stops every dangerous push, secret leak and destructive action, and fix the bugs the setup review found.

**Architecture:** A new rule 4 in the forge guard gates `git push`: a stdlib Python helper beside the guard judges a push only when the whole Bash command is one plain `git push` by a small grammar (anything else that could push is a silent deny asking for a plain push), resolves repository, remote and destination under git's plain push configuration, runs gitleaks over the outgoing commits (fail closed), and asks only for default-branch, force, delete and mirror pushes. The Claude settings `modify_` script is inverted to start from the live file and overlay owned keys. Evaluation gets a `PermissionRequest` audit hook and a transcript metrics script. The global instructions move from a 1Password render to tracked `.chezmoitemplates` fragments.

**Tech Stack:** bash 3.2 (guards, hooks, tests), Python 3.9 stdlib under `/usr/bin/python3` (push helper, metrics), jq 1.7+, chezmoi 2.73 templates and `modify_` scripts, gitleaks 8.30, zsh, git 2.4x.

**Spec:** `docs/superpowers/specs/2026-09-30-safe-autonomy-design.md` (read it with this plan; section numbers below refer to it).

**Deferred:** bug fix 8 (Ghostty `scrollback-limit` in bytes) is out of this plan: `dot_config/ghostty/config` carries someone else's uncommitted edits.

## Global Constraints

- **Shared checkout.** Work on `feat/safe-autonomy` in `/Users/michael/.local/share/chezmoi`. Other sessions switch branches in this checkout: run `git branch --show-current` right before every commit and stop if it does not print `feat/safe-autonomy`.
- **Foreign edits.** `dot_config/ghostty/config`, `dot_config/herdr/config.toml` and `dot_zshrc` carry someone else's uncommitted edits. Never edit, stage, stash or restore them. Stage explicit paths only; never `git add -A`, `git add .` or `git commit -a`.
- All commands run from the repository root. Never open a Bash command with `cd`; never hand a recursive grep a bare `.`.
- **Commit order (spec §7):** enforcement (§1: Tasks 1-3), then bug fixes (§4: Tasks 4-10), then evaluation instruments (§5: Tasks 11-12), then instruction layout and policies (§2, §3: Tasks 13-14). One commit per task unless a task says otherwise. Small, imperative-mood messages, no agent attribution of any kind.
- **Prompt budget (spec, Goal):** only dangerous, destructive actions may ask. Preferred responses, in order: a silent deny with a reason the agent can act on, then the auto-mode classifier, then `ask`.
- **Guards and hooks:** bash 3.2 compatible, no `set -e`, every failure path of a behavioural rule allows (fails open). The two exceptions fail closed: rule 4 of the forge guard (push) denies when it cannot decide, and the gitleaks scan "fails closed. If gitleaks is missing or exits with an error other than 'leaks found', the push is denied" (spec §1.1).
- **Unsupported-configuration reason, verbatim (spec §1.1):** `unsupported push configuration for the push guard: <key>; push by hand or simplify the configuration`. It never asks.
- **Python** runs under `/usr/bin/python3` (3.9): standard library only, no `match`, no `X | Y` unions. Never run `python3 -m py_compile` (it writes a cache outside the sandbox); check syntax with `/usr/bin/python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' <file>`.
- **`dot_claude/modify_private_settings.json`** is bash wrapping one single-quoted jq program: no apostrophe anywhere inside the jq program, comments included.
- **`.chezmoiignore` is an allowlist** for `~/.claude`: every new deployed file under it needs its own `!.claude/...` line.
- **Retired settings keys (spec §4.2):** `includeCoAuthoredBy`, `voiceEnabled` (plus `subagentStatusLine`, retired by Task 6). `cleanupPeriodDays` is 30. `model`, `effortLevel`, `permissions.defaultMode`, `outputStyle` keep seed-if-absent.
- **Instruction fragment sizes (spec §3.2):** `global.md` at most 180 lines, `claude.md` at most 50.
- **Tests:** one `tests/<subject>.test.sh` per script, mode 755, correct shebang, a missing subject exits 2. Execute suites (`./tests/x.test.sh` or `./tests/run.sh <name>`), never `bash tests/x.test.sh`. Run them sandboxed. Report totals as passed/total.
- **Secrets:** never commit one. Fixture secrets are assembled at runtime from two halves (`part_a=AKIA; part_b=...`), never written as one literal.
- **Do not** create files this plan does not name, and do not touch the live `~/.claude`, `~/.codex` or `~/.config` (no `chezmoi apply`; Michael applies after merge).
- **Apply each replace instruction exactly once.** Many are insertions whose new text keeps the old anchor, so applying one twice silently duplicates the inserted block. If a step has to be redone, check first with `grep -c` whether it already landed.

## Review Focus

1. **A legitimate feature-branch push is asked or denied.** Expected: silent allow for a feature push from any directory inside the repository, with push options, and under Michael's real git config, whose `format.pretty` once broke gitleaks' commit attribution. Tests: Task 1 ("a push option on a feature branch", "a push from a subdirectory"); Task 2 ("the fingerprint is bound to the commit, despite format.pretty", "a clean feature branch is scanned and passes", plus a live check against this repository's own branch).
2. **The settings merge drops or duplicates a key on the real `~/.claude/settings.json`.** Expected: only the intended differences, and a second apply changes nothing. Tests: Task 5 section E2 (runtime keys survive, owned keys replaced wholesale, idempotence, a live-sized file under `/bin/bash`), plus a step that runs the old and new script over a copy of the live file and compares every key.
3. **A template render breaks `chezmoi apply`.** Expected: all three instruction targets render with no `op`. Tests: Task 13 `tests/agent-instructions.test.sh`; Task 15 targeted `chezmoi diff`.
4. **The push guard slows every Bash call.** Expected: a command that mentions neither git nor push costs no subprocess, a plain git command costs one git call, and only a git command naming another repository or configuration (`-C`, `--git-dir`, `-c`, …; about 7% of Bash calls in the baseline fortnight) starts the Python helper. Tests: Task 1 tripwire section ("commands that cannot push never run the helper", "a git -C command runs it: its aliases live in that repository"), plus a latency step.
5. **A push written in a shape the parser does not model goes through unjudged.** The helper judges a push only when the WHOLE Bash command is one plain push by a small grammar: an optional leading `cd <literal path> &&`, `VAR=value` words, `command`/`sudo`/`env` without options, `git` with allowlisted global options (`-C <path>`, `--no-pager`, …), `push` or a push alias, allowlisted push options, the remote and refspecs (literals, or one of three current-branch substitutions), and an optional `2>&1 | tail|head`. Any other command whose text could run git push is a silent deny asking for a plain push: a comment (any token beginning with `#`: `git push origin main # --dry-run` really pushes, and `could_push` reads the raw text, comments included, so even `git status # push later` is denied), chains, pipes other than tail/head, redirects, control structures, subshells, heredocs, shells and evaluators, `env`/`sudo` with options, substitutions, a second git command (the scan runs before the call, so it cannot see a commit made earlier in it), plus the option, refspec and configuration denials inside `evaluate`. Expected: no push is allowed unexamined, and a lone `git push …` still works. Tests: Task 1 ("a push inside a quoted substitution", "env with an option, such as -C", "a push followed by another command", "a push piped to anything but tail/head", "a commit chained to a push", "bash -lc with a push", "a push inside if/then", "a dry run negated later", "a comment that fakes --dry-run", "a push after a quoted # inside a substitution", "a lone push, the form to use", "a push piped to tail", "a leading cd, then a push"); Task 2 ("git -C <leaky repo> is scanned there"). The cost is retries, never prompts: `git add -A && git commit -m x && git push …` has to become two Bash calls, a push with a trailing comment has to drop it, and a command that merely mentions git and push (an `echo`, an `rg "git push"`, a heredoc, a comment such as `git status # push later`, a quoted `'#…'` token) is denied; the deny reason says to keep the words apart (`rg 'git pu[s]h'`).
6. **gitleaks false positives on this repository block its own push.** Expected: zero findings on the history and on the branch; a genuine false positive is resolved only by a reviewed `.gitleaksignore` fingerprint. Tests: Task 2 history-scan step; Task 15 branch scan.

---

## File Structure

| Path (chezmoi source) | Deployed | Responsibility | Task |
|---|---|---|---|
| `dot_claude/git-push-guard.py` (new) | `~/.claude/git-push-guard.py` | Rule 4: parse, resolve, decide, scan | 1, 2 |
| `dot_claude/executable_git-forge-guard.sh` | `~/.claude/git-forge-guard.sh` | Fast path for pushes, calls the helper, bypass scope | 1 |
| `tests/git-forge-guard.test.sh` | — | Rule 1-4 tests | 1, 2 |
| `dot_config/homebrew/Brewfile.tmpl` | `~/.config/homebrew/Brewfile` | Declares gitleaks | 2 |
| `dot_claude/modify_private_settings.json` | `~/.claude/settings.json` | Permission rules, inverted merge, hooks | 3, 5, 6, 11 |
| `tests/claude-settings.test.sh` | — | Settings tests | 3, 5, 6, 11, 14 |
| `dot_config/zsh/zshenv`, `tests/zshenv.test.sh` (new) | `~/.config/zsh/zshenv` | PATH order | 4 |
| `dot_claude/executable_subagent-statusline.sh` (deleted) | removed via `.chezmoiremove` | — | 6 |
| `tests/run.sh`, `tests/run.test.sh` (new) | — | Exact-name gate bypass | 7 |
| `dot_codex/modify_private_config.toml`, `tests/codex-config.test.sh` | `~/.codex/config.toml` | Drop `features.js_repl` | 8 |
| `dot_claude/hooks/executable_herdr-agent-state.sh` | `~/.claude/hooks/herdr-agent-state.sh` | Resync to herdr's embedded hook | 8 |
| `dot_config/zsh/config`, `tests/zsh-config.test.sh` (new) | `~/.config/zsh/config` | History in `$XDG_STATE_HOME` | 9 |
| `dot_local/bin/executable_xreview`, `dot_claude/executable_xreview-guard.sh`, `dot_claude/skills/cross-review/SKILL.md` + their three suites | `~/.local/bin/xreview`, `~/.claude/xreview-guard.sh`, skill | Checkpoint receipts, pre-merge gate | 10, 14 |
| `dot_claude/hooks/executable_prompt-audit.sh` (new), `tests/prompt-audit.test.sh` (new) | `~/.claude/hooks/prompt-audit.sh` | Prompt audit log | 11 |
| `.scripts/measure-interventions.py` (new), `tests/measure-interventions.test.sh` (new) | — | Transcript metrics | 12 |
| `.chezmoitemplates/agents/global.md`, `claude.md` (new); the three `*.md.tmpl` targets; `tests/agent-instructions.test.sh` (new) | `~/.config/agents/GLOBAL.md`, `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md` | Instruction layout | 13 |
| `AGENTS.md`, `dot_claude/agents/sp-*.md` | `~/.claude/agents/*` | Repo rules, subagent definitions | 14 |
| `.chezmoiignore`, `.chezmoiremove` | — | Allowlist entries, tombstone | 1, 6, 11 |

---

### Task 1: Push rule — recognition, configuration, destinations; bypass scope (sp-standard)

**Files:**
- Create: `dot_claude/git-push-guard.py`
- Modify: `dot_claude/executable_git-forge-guard.sh`
- Modify: `tests/git-forge-guard.test.sh`
- Modify: `.chezmoiignore` (after `!.claude/git-forge-guard.sh`)

**Interfaces:**
- Produces: `dot_claude/git-push-guard.py`, run as `/usr/bin/python3 <dir-of-guard>/git-push-guard.py` with the PreToolUse payload on stdin. It prints one compact JSON object (`{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"|"deny","permissionDecisionReason":"..."}}`, separators `,` and `:`) or nothing. Functions later tasks edit: `evaluate(cwd, assigns, repo_opts, config_opts, args)` (returns `None` to allow, a reason string to ask, raises `Deny(reason)` to deny); module constant `UNSUPPORTED`. Every non-spec reason starts with `Push guard:`. A wildcard or matching (`:`, `+:`) refspec, a `--git-dir`/`--work-tree` option, and a refspec or remote that is a shell value (other than the current-branch substitutions in `CURRENT_BRANCH`) are denied inside `evaluate` before any source is recorded. `parse_plain(tokens, cwd)` accepts a command only when the WHOLE of it is one plain git invocation by the grammar in the helper's header (optional leading `cd <literal path> &&`/`;`, `VAR=value` words, one of `command`/`sudo`/`env` without options, `git` with allowlisted global options, the subcommand and its words, an optional `2>&1 | tail|head [-n N | -N]`, no `$( )`/backtick substitution other than the `CURRENT_BRANCH` forms, and no token beginning with `#`, so a comment, or a quoted `'#…'` literal, puts the command outside the grammar); `could_push` always reads the raw command text, never a transformed one; `judge` resolves aliases and evaluates a push. Any other command that `could_push` (git and push, or git and a push alias, in its text) is a silent deny with reason `PLAIN`. A current-branch substitution under `-C` or a leading `cd` is denied. `parse_push` accepts only the options in `PUSH_LONG`/`PUSH_SHORT` (the ones agents use, per the baseline transcripts); any other option, any `--no-*` negation except `--no-verify`, and the `--` separator are a silent deny naming them.
- Produces (tests): helpers `reason <cwd> <cmd>`, `has_reason <label> <needle> <cwd> <cmd>`, `clone <name>`, fixture repo `$R` on branch `feat` with `origin/HEAD` → `main`, `$REMOTES/{origin,backup}.git`, `$STUBBIN` (a gitleaks stub that finds nothing, first on PATH), `$REALPATH` (the PATH before the stub). Task 2 uses all of them.

- [ ] **Step 1: Write the failing tests**

In `tests/git-forge-guard.test.sh`, insert this block right after the line `export GUARDTMP="$TMP"`:

```bash

# Rule 4 reads git configuration, so the suite must not inherit Michael's: a global
# push.default or alias would change what is under test. Every git call below, the
# guard's own included, sees only this file.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = t
	email = t@t
[commit]
	gpgsign = false
[init]
	defaultBranch = main
[alias]
	st = status
	pom = push origin main
	shp = !git push origin main
EOF

# Rule 4 scans outgoing commits with gitleaks. The decision cases run against a stub
# that finds nothing, so they exercise the decision alone; the gitleaks section puts
# the real binary back.
STUBBIN="$TMP/stubbin"; mkdir -p "$STUBBIN"
printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/gitleaks"; chmod 755 "$STUBBIN/gitleaks"
REALPATH=$PATH
export PATH="$STUBBIN:$PATH"
```

Replace the line

```bash
expect allow "bypass switch, rule 3"    "$BARE" 'FORGE_GUARD=off glab api -X DELETE "projects/1"'
```

with

```bash
expect ask   "the bypass does not lift rule 3" "$BARE" 'FORGE_GUARD=off glab api -X DELETE "projects/1"'
```

Then insert this block immediately before the final two lines `echo` / `echo "passed: $pass  failed: $fail"`:

```bash

# reason <cwd> <command> -> the permissionDecisionReason, or nothing on allow
reason() {
  run "$1" "$2" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null
}
# has_reason <label> <needle> <cwd> <command>
has_reason() {
  local label=$1 needle=$2 got
  got=$(reason "$3" "$4")
  case "$got" in
    *"$needle"*) pass=$((pass + 1)); printf '  ok   %s\n' "$label" ;;
    *) fail=$((fail + 1)); printf '  FAIL %s (reason lacks %s: %s)\n' "$label" "$needle" "$got" ;;
  esac
}

# ---------------------------------------------------------------- rule 4 fixtures
# Two bare remotes and a work repo whose origin/HEAD names main. The repo sits on a
# pushed feature branch; clone() copies it so a case can bend its config alone.
REMOTES="$TMP/remotes"; mkdir -p "$REMOTES"
git init -q --bare "$REMOTES/origin.git"
git init -q --bare "$REMOTES/backup.git"
BASE="$TMP/work"   # no "push" in the path: the fast path matches the raw payload
git init -q "$BASE"
git -C "$BASE" commit -q --allow-empty -m init
git -C "$BASE" remote add origin "$REMOTES/origin.git"
git -C "$BASE" push -q origin main 2>/dev/null
git -C "$BASE" remote set-head origin main
git -C "$BASE" switch -q -c feat
git -C "$BASE" commit -q --allow-empty -m feature
git -C "$BASE" push -q -u origin feat 2>/dev/null
git -C "$BASE" config alias.lp 'push origin main'
[ "$(git -C "$BASE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" = origin/main ] \
  || { echo "rule 4 fixture setup failed" >&2; exit 1; }
clone() { cp -R "$BASE" "$TMP/$1" && printf '%s' "$TMP/$1"; }
R=$BASE

echo "== rule 4: recognising a push =="
expect ask   "push to the default branch"             "$R"   'git push origin main'
expect ask   "git -C <repo> from another directory"   "$TMP" "git -C $R push origin main"
expect ask   "command git push"                       "$R"   'command git push origin main'
expect ask   "env X=1 git push"                       "$R"   'env X=1 git push origin main'
expect ask   "an assignment prefix"                   "$R"   'X=1 git push origin main'
expect ask   "sudo git push"                          "$R"   'sudo git push origin main'
expect ask   "a path to git"                          "$R"   '/usr/bin/git push origin main'
expect ask   "global options before push"             "$TMP" "git --no-pager -C $R push origin main"
expect ask   "FORGE_GUARD=off does not lift rule 4"   "$R"   'FORGE_GUARD=off git push origin main'
expect ask   "a global alias: pom = push origin main" "$R"   'git pom'
expect ask   "a repository-local alias"               "$R"   'git lp'
expect deny  "a push after another git command, on a later line" "$R" 'git status
git push origin main'
expect deny  "a push after another git command, after &&" "$R" 'git add -A && git push origin main'
expect ask   "a push with redirects and a pipe"       "$R"   'git push origin main 2>&1 | tail -5'
expect deny  "a push inside bash -c"                  "$R"   "bash -c 'git push origin main'"
expect ask   "a cd before the push is followed"       "$TMP" "cd $R && git push origin main"
# Only a plain command is judged; a push inside any compound command is a silent deny.
expect deny  "a push inside if/then"                  "$R"   'if true; then git push origin main; fi'
expect deny  "a push as an if condition"              "$R"   'if git push origin main; then echo ok; fi'
expect deny  "a push inside a while loop"             "$R"   'while false; do git push origin main; done'
expect deny  "a push inside a for loop"               "$R"   'for b in x; do git push origin main; done'
expect deny  "a push inside a { } group"              "$R"   '{ git push origin main; }'
expect deny  "a negated push"                         "$R"   '! git push origin main'
# Parentheses of any kind (a case arm, a subshell, a function body) are not modelled.
expect deny  "a push inside a case arm is denied"     "$R"   'case x in x) git push origin main;; esac'
# An alias defined only in the repository git selects is resolved THERE, not in the cwd:
# the fast path cannot list it, so any git command naming another repository goes on.
OTHER=$(clone other); git -C "$OTHER" config alias.lp2 'push origin main'
expect ask   "an alias local to the -C repository"    "$TMP" "git -C $OTHER lp2"
expect deny  "an alias in the --git-dir= repository is denied with it" "$TMP" "git --git-dir=$OTHER/.git lp2"
expect ask   "a -C path through a variable the hook can see" "$TMP" 'git -C "$GUARDTMP/work" push origin main'
expect deny  "an alias defined with -c on the command line" "$R" "git -c alias.zz='push origin main' zz"
expect deny  "an alias under a GIT_DIR override"      "$TMP" "GIT_DIR=$OTHER/.git git lp2"
# deny beats ask: a rule 4 ask must not swallow a rule 1 deny in the same command.
expect deny  "a rule 1 deny beats a rule 4 ask"       "$R"   'gh pr create --title x --body "Generated with Claude Code" && git push origin main'
# One git command per push: the scan runs before the call, so it cannot see a commit made
# earlier in it, and a switch changes the branch the push reads.
expect deny  "a switch chained to a push"             "$R"   'git switch main && git push'
expect deny  "a commit chained to a push"             "$R"   'git commit -am x && git push origin feat'
expect deny  "add, commit and push in one call"       "$R"   'git add -A && git commit -m x && git push -u origin feat'
expect deny  "two pushes in one call"                 "$R"   'git push origin feat; git push origin feat-2'
expect deny  "git inside a substitution next to a push" "$R" 'git push -o "$(git log -1 --format=%s)" origin feat'
expect allow "a lone push, the form to use"           "$R"   'git push -u origin feat'
# The grammar: the whole command is one plain push, optionally after one cd and piped
# only to tail or head. Everything else that could push is a silent deny.
expect deny  "a push inside a quoted substitution"    "$R"   'echo "$(git push origin main)"'
expect deny  "env with an option, such as -C"         "$R"   "env -C $OTHER git push origin HEAD"
expect allow "a push piped to tail"                   "$R"   'git push -u origin feat 2>&1 | tail -5'
expect allow "a push piped to head -n"                "$R"   'git push -u origin feat | head -n 3'
expect allow "a leading cd, then a push"              "$TMP" "cd $R && git push -u origin feat"
expect deny  "a push followed by another command"     "$R"   'git push origin feat && echo done'
expect deny  "a push piped to anything but tail/head" "$R"   'git push origin feat | tee log'
expect deny  "a push redirected to a file"            "$R"   'git push origin feat > push.log'
expect allow "a plain git command that does not push" "$R"  'git log --oneline -3 | head -n 3'
# Shells and evaluators run their arguments as code; the guard never reads those.
expect deny  "bash -lc with a push"                   "$R"   "bash -lc 'git push origin main'"
expect deny  "sh -c with a push"                      "$R"   'sh -c "git push"'
expect deny  "eval with a push"                       "$R"   'eval "git push origin main"'
expect deny  "time in front of a push"                "$R"   'time git push origin feat'
expect deny  "xargs running a push"                   "$R"   'echo feat | xargs git push origin'
expect deny  "ssh running a push"                     "$R"   "ssh host 'git push origin main'"
expect deny  "a shell running a push alias"           "$R"   "bash -c 'git pom'"
expect allow "a shell running a push that is not git" "$R"   "bash -c 'docker push registry/x'"
expect allow "a shell running git that cannot push"   "$R"   "bash -c 'git status'"
expect deny  "a shell alias that pushes"              "$R"   'git shp'
expect allow "an alias that does not push"           "$R"   'git st'
# Text that holds git and push outside a plain push is denied too: the guard reads no
# shape but the plain one, so it cannot tell a mention from a call.
expect deny  "echo mentioning a push"                 "$R"   'echo "git push origin main"'
expect deny  "rg for the text"                        "$R"   'rg "git push origin main" docs/'
expect allow "rg for the text, with git and push kept apart" "$R" "rg 'git pu[s]h origin main' docs/"
expect allow "a commit message about pushing"         "$R"   'git commit --allow-empty -m "push to main later"'
# Here-documents are not modelled: any << next to something push-shaped is denied, even
# a body that only mentions one. Quote-aware heredoc parsing is deliberately not attempted.
expect deny  "a heredoc body naming a push is denied" "$R"   "cat > $TMP/notes.md <<'EOF'
Then run git push origin main, it's done.
EOF"
expect deny  "quoted heredoc-looking text before a push" "$R" 'printf "<<EOF"
git push origin main'
expect deny  "a commit heredoc chained to a push"     "$R"   "git commit --allow-empty -F - <<'EOF'
msg
EOF
git push origin feat"
expect allow "a heredoc with no push in it"           "$R"   "cat > $TMP/notes.md <<'EOF'
nothing to see
EOF"
# Comments are not in the grammar: any token that begins with # puts the command outside
# it, and could_push reads the raw text, comments included (a superset, never trimmed). bash
# drops a comment, so a trailing one could fake an option the push never gets.
expect deny  "a comment line naming a push"           "$R"   '# git push origin main
git status'
expect deny  "a comment that fakes --dry-run"         "$R"   'git push origin main # --dry-run'
expect deny  "a push with a trailing comment"         "$R"   'git push -u origin feat # note'
expect deny  "a non-push git command with a comment that says push" "$R" 'git status # push later'
# A # inside nested quotes is not a comment to bash, and the push after it runs.
expect deny  "a push after a quoted # inside a substitution" "$R" 'echo "$(echo " # note"; git push origin main)"'
# A quoted token that begins with # is rejected too: a false deny the grammar accepts.
expect deny  "a quoted token starting with # is outside the grammar" "$R" "git push -o '#1' origin feat"
expect allow "a quoted # inside a push option"        "$R"   "git push --push-option='ci.skip#1' origin feat"
expect allow "a # inside a word is not a comment"     "$R"   'git push -o ci.skip#1 origin feat'
expect allow "a word containing push, no git"         "$R"   'ls pushed/'

echo "== rule 4: pushes that ask =="
expect ask   "HEAD:main"                              "$R" 'git push origin HEAD:main'
expect ask   "refs/heads/main as the destination"     "$R" 'git push origin feat:refs/heads/main'
expect ask   "a lease on the default branch"          "$R" 'git push --force-with-lease origin main'
expect ask   "a + refspec"                            "$R" 'git push origin +feat'
expect ask   "--force on a feature branch"            "$R" 'git push --force origin feat'
expect ask   "-f bundled as -fu"                      "$R" 'git push -fu origin feat'
expect ask   "a :ref refspec"                         "$R" 'git push origin :old'
expect ask   "--delete"                               "$R" 'git push --delete origin old'
expect ask   "-d"                                     "$R" 'git push -d origin old'
expect ask   "--prune"                                "$R" 'git push --prune origin feat'
expect ask   "--mirror"                               "$R" 'git push --mirror origin'
expect ask   "--all"                                  "$R" 'git push --all origin'
ONMAIN=$(clone onmain); git -C "$ONMAIN" switch -q main
expect ask   "a bare push while on main"              "$ONMAIN" 'git push'
expect ask   "push <remote> while on main"            "$ONMAIN" 'git push origin'
expect ask   "push HEAD while on main"                "$ONMAIN" 'git push origin HEAD'
has_reason   "the ask names the default branch" "main, the default branch of origin" "$R" 'git push origin main'
TRUNK=$(clone trunk); git -C "$TRUNK" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
expect ask   "the default branch comes from origin/HEAD" "$TRUNK" 'git push origin trunk'
expect allow "main is not special when HEAD names trunk" "$TRUNK" 'git push origin main'
NOHEAD=$(clone nohead); git -C "$NOHEAD" remote set-head origin -d
expect ask   "no origin/HEAD falls back to main"      "$NOHEAD" 'git push origin main'

echo "== rule 4: pushes that go ahead silently =="
expect allow "a feature branch"                       "$R" 'git push origin feat'
expect allow "-u on a feature branch"                 "$R" 'git push -u origin feat'
expect allow "a bare push on a feature branch"        "$R" 'git push'
expect allow "HEAD on a feature branch"               "$R" 'git push origin HEAD'
expect allow "a lease on a feature branch"            "$R" 'git push --force-with-lease origin feat'
expect allow "lease and if-includes on a feature branch" "$R" 'git push --force-with-lease --force-if-includes origin feat'
expect allow "--tags"                                 "$R" 'git push --tags origin'
expect allow "--dry-run to main"                      "$R" 'git push --dry-run origin main'
expect allow "-n to main"                             "$R" 'git push -n origin main'
expect allow "a new branch name"                      "$R" 'git push origin HEAD:feat-2'
expect allow "a push option on a feature branch"      "$R" 'git push -o ci.skip origin feat'
# git push options come from an allowlist; anything else is a silent deny naming it. A
# negation is the reason: --no-dry-run after --dry-run makes the dry run a real push.
expect deny  "a dry run negated later"                "$R" 'git push --dry-run --no-dry-run origin main'
expect deny  "--no-dry-run alone"                     "$R" 'git push --no-dry-run origin main'
has_reason   "the deny names the option" "the push option --no-dry-run" "$R" 'git push --no-dry-run origin main'
expect deny  "an unknown push option"                 "$R" 'git push --frobnicate origin feat'
expect deny  "an unknown short push option"           "$R" 'git push -x origin feat'
expect deny  "--repo, which is not modelled"          "$R" 'git push --repo=origin feat'
expect deny  "an option after --"                     "$R" 'git push origin -- --force'
has_reason   "--repo is denied as an option, by name" "the push option --repo=origin" "$R" 'git push --repo=origin feat'
has_reason   "-- is denied as a separator, by name"   "the -- separator" "$R" 'git push origin -- --force'
expect allow "--no-verify on a feature push"          "$R" 'git push --no-verify origin feat'
for o in -u --set-upstream -q --quiet -v --verbose --progress --porcelain --atomic \
         --force-with-lease --force-with-lease=feat --force-if-includes --follow-tags \
         -n --dry-run --push-option=ci.skip -oci.skip -uq; do
  expect allow "allowlisted, silent on a feature branch: $o" "$R" "git push $o origin feat"
done
expect allow "allowlisted, silent on a feature branch: --push-option <value>" "$R" 'git push --push-option ci.skip origin feat'
mkdir -p "$R/sub/dir"
expect allow "a push from a subdirectory"             "$R/sub/dir" 'git push origin feat'
expect ask   "a push to main from a subdirectory"     "$R/sub/dir" 'git push origin main'

echo "== rule 4: unsupported configuration is denied, never asked =="
u=0
unsupported() { # unsupported <label> <git config args...>
  local label=$1 d; shift
  u=$((u + 1)); d=$(clone "unsupported-$u")
  git -C "$d" config "$@"
  expect deny "$label" "$d" 'git push origin feat'
}
unsupported "remote.pushDefault"        remote.pushDefault origin
unsupported "branch.<b>.pushRemote"     branch.feat.pushRemote origin
unsupported "remote.<r>.push"           remote.origin.push 'refs/heads/*:refs/heads/*'
unsupported "remote.<r>.mirror"         remote.origin.mirror true
unsupported "push.default=upstream"     push.default upstream
unsupported "push.default=matching"     push.default matching
unsupported "a pushurl"                 remote.origin.pushurl "$REMOTES/backup.git"
unsupported "pushInsteadOf"             url."$REMOTES/backup.git".pushInsteadOf "$REMOTES/origin.git"
SECOND=$(clone second-url); git -C "$SECOND" config --add remote.origin.url "$REMOTES/backup.git"
expect deny  "a second url"                           "$SECOND" 'git push origin feat'
expect deny  "-c on the push invocation"              "$R" 'git -c push.default=current push origin feat'
expect deny  "GIT_DIR on the push invocation"         "$R" "GIT_DIR=$R/.git git push origin feat"
expect deny  "a push to a URL, not a remote"          "$R" "git push $REMOTES/origin.git feat"
expect deny  "an unknown remote"                      "$R" 'git push nosuch feat'
DETACHED=$(clone detached); git -C "$DETACHED" switch -q --detach
expect deny  "a bare push on a detached HEAD"         "$DETACHED" 'git push'
expect deny  "an unresolvable cd before the push"     "$R" 'cd "$NO_SUCH_DIR_VAR" && git push origin feat'
# Only one leading, top-level cd <literal path> is modelled; any other directory change or
# subshell around a push is denied. The first case is the one Codex found: the cd runs in
# a subshell, and the push runs from where the command started.
expect deny  "a cd inside a subshell before the push" "$R"   "(cd $OTHER; git status); git push origin HEAD"
expect allow "a leading cd <path>; is followed"       "$TMP" "cd $R; git push origin feat"
expect deny  "a second cd before the push"            "$TMP" "cd $R && cd sub && git push origin feat"
expect deny  "a cd after the push"                    "$R"   'git push origin feat; cd /tmp'
expect deny  "a pushd before the push"                "$TMP" "pushd $R && git push origin feat"
expect deny  "a cd inside an if before the push"      "$TMP" "if cd $R; then git push origin feat; fi"
expect deny  "an unquoted substitution"               "$R"   'git push origin $(git branch --show-current)'
# git rejects attached global options itself; the guard denies them rather than parse them.
expect deny  "an attached -c<k=v> option on a push"   "$R"   'git -cremote.origin.url=/x push origin feat'
expect deny  "an attached -C<path> option on a push"  "$R"   'git -C/other push origin feat'
expect deny  "an unrecognised git option on a push"   "$R"   'git --frobnicate push origin feat'
# Only -C selects a repository the scan can follow; --git-dir and --work-tree cannot.
expect deny  "--git-dir on a push"                    "$TMP" "git --git-dir=$OTHER/.git push origin feat"
expect deny  "--work-tree on a push"                  "$R"   "git --work-tree=$R push origin feat"
# `:` and `+:` push every matching branch; they are not deletions.
expect deny  "the matching refspec :"                 "$R"   'git push origin :'
expect deny  "the forced matching refspec +:"         "$R"   'git push origin +:'
expect deny  "a --config-env= option on the push"     "$R" 'git --config-env=core.pager=PAGER push origin feat'
# A wildcard names no branch and no commits to scan, so it cannot be asked about safely.
expect deny  "a wildcard refspec"                     "$R" "git push origin 'refs/heads/*:refs/heads/*'"
# Values only the shell knows: the guard would judge the literal text, not the branch.
expect deny  "a refspec in a shell variable"          "$R" 'B=main; git push origin $B'
expect deny  "a remote in a shell variable"           "$R" 'git push "$REMOTE" feat'
expect deny  "a refspec in backticks"                 "$R" 'git push origin `git branch --show-current`'
expect allow "the current branch by substitution"     "$R" 'git push -u origin "$(git branch --show-current)"'
expect ask   "the current branch by substitution, on main" "$ONMAIN" 'git push origin "$(git branch --show-current)"'
# The shell runs the substitution where it is, not where -C or a cd points the push.
expect deny  "a current-branch substitution under -C" "$TMP" "git -C $OTHER push origin \"\$(git branch --show-current)\""
expect deny  "a current-branch substitution after a leading cd" "$TMP" "cd $R && git push origin \"\$(git branch --show-current)\""
MATCHING=$(clone matching); git -C "$MATCHING" config push.default matching
has_reason   "the deny names the key" \
  "unsupported push configuration for the push guard: push.default=matching" "$MATCHING" 'git push origin feat'
expect allow "a dry run is never refused"             "$MATCHING" 'git push --dry-run origin main'
expect deny  "unbalanced quotes around a push"        "$R" 'git push origin "feat'

echo "== rule 4 costs nothing on commands that do not push =="
# The helper is where the time goes (python plus a dozen git calls). A tripwire helper
# records every run, so a plain command that cannot push must never reach it. A git command
# that names another repository does reach it, by design: only the helper can read the
# aliases defined there.
TRIP="$TMP/tripwire"; mkdir -p "$TRIP"
cp "$GUARD" "$TRIP/git-forge-guard.sh"
printf 'import sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$TRIP/git-push-guard.py"
SAVED_GUARD=$GUARD; GUARD="$TRIP/git-forge-guard.sh"
for c in 'ls -la' 'git status' 'git log --oneline -5' 'git st' 'npm test'; do
  run "$R" "$c" >/dev/null
done
if [ -e "$TRIP/git-push-guard.py.ran" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "commands that cannot push never run the helper"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "commands that cannot push never run the helper"
fi
run "$R" 'git pom' >/dev/null
if [ -e "$TRIP/git-push-guard.py.ran" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "an alias that pushes does run it"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "an alias that pushes does run it"
fi
rm -f "$TRIP/git-push-guard.py.ran"
run "$TMP" "git -C $R status" >/dev/null
if [ -e "$TRIP/git-push-guard.py.ran" ]; then
  pass=$((pass + 1)); printf '  ok   %s\n' "a git -C command runs it: its aliases live in that repository"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "a git -C command runs it: its aliases live in that repository"
fi
GUARD=$SAVED_GUARD

echo "== rule 4 fails closed when its helper is missing =="
NOHELPER="$TMP/nohelper"; mkdir -p "$NOHELPER"
cp "$GUARD" "$NOHELPER/git-forge-guard.sh"
SAVED_GUARD=$GUARD; GUARD="$NOHELPER/git-forge-guard.sh"
expect deny  "a push with no helper is refused"       "$R" 'git push origin feat'
expect allow "a non-push command is untouched"        "$R" 'echo push'
expect allow "git status is untouched"                "$R" 'git status'
# The fallback denies on the evidence the fast path used, aliases included.
expect deny  "an alias push with no helper is refused" "$R" 'git pom'
# Fail closed: with no helper, the aliases of a -C repository cannot be checked.
expect deny  "a git -C command with no helper is refused" "$TMP" "git -C $R status"
# The fallback cannot read quotes, so it cannot tell a comment from code: it fails closed.
expect deny  "a commented git command with no helper is refused" "$R" 'git status # push later'
GUARD=$SAVED_GUARD

echo "== the helper deploys beside the guard =="
# The guard looks for git-push-guard.py next to itself. A helper chezmoi never deploys
# would leave rule 4 denying every push. .chezmoiignore is an allowlist for ~/.claude.
if command -v chezmoi >/dev/null 2>&1 \
   && chezmoi --source "$SRC" managed 2>/dev/null | grep -qx '.claude/git-push-guard.py'; then
  pass=$((pass + 1)); printf '  ok   %s\n' "git-push-guard.py is chezmoi-managed"
else
  fail=$((fail + 1)); printf '  FAIL %s\n' "git-push-guard.py is chezmoi-managed"
fi
```

Also update the header comment of the suite: replace

```bash
# The guard is a PreToolUse(Bash) hook: it reads the hook payload on stdin and
# either stays silent (allow) or prints a permissionDecision JSON object —
# "deny" for rules 1-2 (correctness catches, bounced back to the model) or "ask"
# for rule 3 (a danger gate, surfaced to the user).
```

with

```bash
# The guard is a PreToolUse(Bash) hook: it reads the hook payload on stdin and
# either stays silent (allow) or prints a permissionDecision JSON object —
# "deny" for rules 1-2 (correctness catches, bounced back to the model) or "ask"
# for rule 3 (a danger gate, surfaced to the user). Rule 4 (git push) asks for
# default-branch, force, delete and mirror pushes and denies what it cannot resolve.
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./tests/git-forge-guard.test.sh`
Expected: exit 1. FAIL lines for the rule 4 ask/deny cases (they come back `allow`), for "the bypass does not lift rule 3" (`allow`), the two tripwire cases that expect the helper to run, the three missing-helper denies, and "git-push-guard.py is chezmoi-managed". The rule 1-3 cases still pass, and so do the allow cases.

- [ ] **Step 3: Create the helper**

Create `dot_claude/git-push-guard.py` (mode 644; the guard runs it through `python3`, so it needs no exec bit and no `executable_` prefix) with exactly:

```python
#!/usr/bin/env python3
# Rule 4 of git-forge-guard.sh: the push gate. Design: section 1.1 of
# docs/superpowers/specs/2026-09-30-safe-autonomy-design.md.
#
# Reads the PreToolUse payload on stdin. Prints ONE hookSpecificOutput object when a push
# must ask or be denied, and nothing when the command may go ahead.
#
# It judges a push only when the WHOLE command is a plain push, by this grammar over the
# shlex tokens (nothing else may be left over):
#
#   [cd <literal path> (&& | ;)]
#   [VAR=value ...]
#   [command | sudo | env [VAR=value ...]]        no options on sudo or env
#   git [allowlisted global options]              -C <path>, --no-pager, ...
#   push | <an alias that expands to push>
#   [allowlisted push options] [<remote> [<refspec> ...]]
#   [2>&1] [| tail|head [-n N | -N]]              a read-only output tail, nothing else
#
# No token may hold a $( ) or backtick substitution other than the three current-branch
# forms, and no token may begin with # (a comment, or a quoted '#...' literal: both are
# outside the grammar). could_push always reads the raw command text. A single git command of the same shape that does not push is left alone. Any
# other command that could run git push (git and push in its text, or git and a push
# alias) is a silent deny asking for the push as a plain command. Nothing else is parsed:
# no control structures, subshells, heredocs, evaluators or chains.
#
# Fail direction: a push this cannot resolve is DENIED with a reason the agent can act on.
# It never asks on doubt (an ask costs Michael a prompt) and never allows on doubt (a push
# is the one irreversible outward path).
#
# Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
import json
import os
import re
import shlex
import subprocess
import sys

PUNCT = ";&|()<>\n"
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Could this text run git push? git, then push (or a push alias), within one command.
PUSH_SHAPE = re.compile(r"\bgit\b[^;&|\n]*\bpush\b")
TAILS = {"tail", "head"}
# A refspec written as the current branch through a command substitution; anything else
# carrying $ or a backtick is a value the guard cannot know.
CURRENT_BRANCH = {"$(git branch --show-current)", "$(git rev-parse --abbrev-ref HEAD)",
                  "$(git symbolic-ref --short HEAD)"}

# git global options this parser recognises. -C moves the working directory and resolves
# correctly; every other repository or configuration selector is unsupported on a push,
# and so is any option not listed here (git rejects attached forms such as -C<path>).
GIT_FLAGS = {"-p", "-P", "--paginate", "--no-pager", "--bare", "--no-replace-objects",
             "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs",
             "--icase-pathspecs", "--no-optional-locks", "--no-advice", "--no-lazy-fetch"}
GIT_LONG_OPTS_WITH_VALUE = {"--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"}
GIT_CONFIG_OPTS = {"-c", "--config-env"}
# Environment assignments that select a repository or inject configuration.
GIT_ENV_UNSUPPORTED = re.compile(r"^(GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_NAMESPACE|GIT_CONFIG.*)$")
# Builtins cannot be aliased, so these never need an alias lookup.
GIT_BUILTINS = {
    "add", "am", "apply", "bisect", "blame", "branch", "cat-file", "checkout", "cherry-pick",
    "clean", "clone", "commit", "config", "describe", "diff", "fetch", "for-each-ref",
    "format-patch", "gc", "grep", "help", "init", "log", "ls-files", "ls-remote", "merge",
    "merge-base", "mv", "name-rev", "notes", "pull", "range-diff", "rebase", "reflog",
    "remote", "reset", "restore", "rev-list", "rev-parse", "revert", "rm", "shortlog", "show",
    "show-ref", "sparse-checkout", "stash", "status", "submodule", "switch", "symbolic-ref",
    "tag", "update-ref", "var", "version", "worktree",
}
# The git push options this guard models. Every other option is a silent deny naming it,
# every --no-* negation included (--no-dry-run turns a dry run into a real push); the one
# allowed negation is --no-verify, which only skips local hooks.
PUSH_LONG = {"--set-upstream", "--force-with-lease", "--force-if-includes", "--force", "--tags",
             "--follow-tags", "--all", "--mirror", "--delete", "--prune", "--dry-run", "--quiet",
             "--verbose", "--progress", "--porcelain", "--atomic", "--push-option", "--no-verify"}
PUSH_LONG_WITH_VALUE = {"--force-with-lease", "--push-option"}    # --x=value accepted
PUSH_SHORT = set("ufdnqv")                                        # plus -o <value>

UNSUPPORTED = ("unsupported push configuration for the push guard: {}; "
               "push by hand or simplify the configuration")
PLAIN = ("Push guard: this command may run git push in a shape the guard does not check. Run "
         "the push as a plain command of its own: git push [options] <remote> <branch> "
         "(optionally after one cd <path> &&, and piped only to tail or head). If the command "
         "does not push, keep git and push apart in its text, for example rg 'git pu[s]h'.")


class Deny(Exception):
    """A push that must be refused, carrying the reason the agent reads."""


def decision(kind, reason):
    # Compact separators: the shell side matches "permissionDecision":"ask" literally.
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": kind,
        "permissionDecisionReason": reason,
    }}, separators=(",", ":"))


# ------------------------------------------------------------------ the grammar
def tokenize(cmd):
    """Shell words and operator tokens. Raises ValueError on unbalanced quotes."""
    lx = shlex.shlex(cmd.replace("\\\n", " "), posix=True, punctuation_chars=PUNCT)
    lx.whitespace = " \t\r"          # a newline separates commands; it is not a blank
    lx.whitespace_split = True
    lx.commenters = ""
    return list(lx)


def is_operator(tok):
    return bool(tok) and all(c in PUNCT for c in tok)


def substitutes(tok):
    return ("$(" in tok or "`" in tok) and tok not in CURRENT_BRANCH


def parse_plain(tokens, cwd):
    """The one git invocation of a plain command, as the grammar in the header allows it,
    as a dict; or None when the command is anything else."""
    t = list(tokens)
    while t and t[-1] == "\n":
        t.pop()
    n, i, cd_used = len(t), 0, False
    if any(substitutes(x) or x.startswith("#") for x in t):
        return None
    if n >= 3 and t[0] == "cd" and t[2] in ("&&", ";") and not is_operator(t[1]):
        target = os.path.expanduser(t[1])
        if "$" in target or target == "-":
            return None
        cwd, cd_used, i = os.path.normpath(os.path.join(cwd, target)), True, 3
    assigns = []
    while i < n and ASSIGN_RE.match(t[i]):
        assigns.append(t[i].split("=", 1)[0])
        i += 1
    if i < n and t[i] in ("command", "sudo"):
        i += 1
    elif i < n and t[i] == "env":
        i += 1
        while i < n and ASSIGN_RE.match(t[i]):
            assigns.append(t[i].split("=", 1)[0])
            i += 1
    if i >= n or os.path.basename(t[i]) != "git":
        return None
    i += 1
    repo_opts, config_opts, unknown = [], [], []
    while i < n and t[i].startswith("-") and not is_operator(t[i]):
        w = t[i]
        name = w.split("=", 1)[0]
        if w in ("-C", "-c") or (name in GIT_LONG_OPTS_WITH_VALUE and "=" not in w):
            if i + 1 >= n or is_operator(t[i + 1]):
                return None
            opt, i = [w, t[i + 1]], i + 2
        elif name in GIT_LONG_OPTS_WITH_VALUE:
            opt, i = [w], i + 1
        else:
            if w not in GIT_FLAGS and not w.startswith("--exec-path"):
                unknown.append(w)
            i += 1
            continue
        if name in GIT_CONFIG_OPTS:
            config_opts.extend(opt)
        else:
            # ~ and $HOME are expanded as the shell would; a value still holding $ names
            # a variable only the shell knows, and git -C resolves it to nothing.
            repo_opts.extend(os.path.expanduser(os.path.expandvars(x)) for x in opt)
    if i >= n or is_operator(t[i]):
        return None
    sub, args, i = t[i], [], i + 1
    while i < n and not is_operator(t[i]) and t[i:i + 3] != ["2", ">&", "1"]:
        args.append(t[i])
        i += 1
    if t[i:i + 3] == ["2", ">&", "1"]:
        i += 3
    if i < n and t[i] == "|":
        if i + 1 >= n or t[i + 1] not in TAILS:
            return None
        i += 2
        if i + 1 < n and t[i] == "-n" and t[i + 1].isdigit():
            i += 2
        elif i < n and re.match(r"^-[0-9]+$", t[i]):
            i += 1
    if i != n:
        return None
    return {"cwd": cwd, "cd_used": cd_used, "assigns": assigns, "repo_opts": repo_opts,
            "config_opts": config_opts, "unknown": unknown, "sub": sub, "args": args}


# ------------------------------------------------------------------ git queries
class Repo:
    def __init__(self, cwd, repo_opts):
        self.base = ["git", "-C", cwd] + list(repo_opts)

    def run(self, *args):
        """stdout of a git query, or None when git fails."""
        try:
            p = subprocess.run(self.base + list(args), capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return p.stdout if p.returncode == 0 else None

    def config(self, key):
        """A config value, or None when the key is not set."""
        out = self.run("config", "--get", key)
        return None if out is None else out.strip()

    def has_ref(self, ref):
        return self.run("show-ref", "--verify", "--quiet", ref) is not None


def expand_alias(repo, sub, args, depth=0):
    """Follow git aliases until a builtin appears. An alias whose expansion starts with
    push becomes a push; a shell alias that mentions push cannot be resolved."""
    if sub == "push" or sub in GIT_BUILTINS or depth > 5:
        return sub, args
    value = repo.config("alias." + sub)
    if value is None:
        return sub, args
    if value.startswith("!"):
        if re.search(r"\bpush\b", value):
            raise Deny(UNSUPPORTED.format("alias." + sub + " is a shell alias that pushes"))
        return sub, args
    try:
        expanded = shlex.split(value)
    except ValueError:
        return sub, args
    if not expanded:
        return sub, args
    if expanded[0].startswith("-"):
        if "push" in expanded:
            raise Deny(UNSUPPORTED.format("alias." + sub + " passes git options before push"))
        return sub, args
    return expand_alias(repo, expanded[0], expanded[1:] + list(args), depth + 1)


def push_aliases(cwd, selector):
    """Names of the aliases that expand to a push, in cwd or the repository a -C or
    --git-dir selector names."""
    out = Repo(cwd, selector).run("config", "--get-regexp", r"^alias\.") or ""
    names = set()
    for line in out.splitlines():
        name, _, value = line.partition(" ")
        if value.startswith("push") or (value.startswith("!") and re.search(r"\bpush\b", value)):
            names.add(name[len("alias."):])
    return names


def could_push(cmd, tokens, cwd):
    """For a command outside the grammar: could it run git push? git and push in its text,
    git and a push alias (from cwd, or a repository a -C, --git-dir or GIT_DIR in it names),
    or git under a GIT_CONFIG override. Text only; no shape is parsed."""
    if PUSH_SHAPE.search(cmd):
        return True
    if not re.search(r"\bgit\b", cmd):
        return False
    if "GIT_CONFIG" in cmd:
        return True
    selectors = [[]]
    for k, tok in enumerate(tokens or []):
        if tok in ("-C", "--git-dir") and k + 1 < len(tokens):
            selectors.append([tok, os.path.expanduser(tokens[k + 1])])
        elif tok.startswith("--git-dir="):
            selectors.append([tok])
        elif tok.startswith("GIT_DIR="):
            selectors.append(["--git-dir=" + tok.split("=", 1)[1]])
    names = set()
    for sel in selectors:
        names |= push_aliases(cwd, sel)
    return any(re.search(r"\bgit\b[^;&|\n]*\b" + re.escape(a) + r"\b", cmd) for a in names)


def judge(s):
    """None to allow, a reason to ask; raises Deny. s is a plain command from parse_plain."""
    sub, args = s["sub"], s["args"]
    if sub != "push" and sub not in GIT_BUILTINS:
        if s["unknown"] or [a for a in s["assigns"] if GIT_ENV_UNSUPPORTED.match(a)]:
            raise Deny(PLAIN)                          # an alias under an override
        # -c options go into the lookup too: `git -c alias.x=push x` defines the alias on
        # the command line itself.
        sub, args = expand_alias(Repo(s["cwd"], s["repo_opts"] + s["config_opts"]), sub, args)
    if sub != "push":
        return None                                    # a plain git command that does not push
    if s["unknown"]:
        raise Deny(UNSUPPORTED.format("the git option " + s["unknown"][0] + " on the push invocation"))
    # The shell runs the substitution where it is, not in the repository -C or a cd
    # selects, so the branch it names may belong to another repository.
    if (s["repo_opts"] or s["cd_used"]) and any(a in CURRENT_BRANCH for a in args):
        raise Deny("Push guard: the current-branch substitution runs where the shell is, not "
                   "in the repository -C or cd selects. Name the branch literally.")
    return evaluate(s["cwd"], s["assigns"], s["repo_opts"], s["config_opts"], args)


def parse_push(args):
    """Split git push arguments into (flags, remote or None, refspecs). Raises Deny for an
    option outside the modelled set, and for the -- separator."""
    flags, positional, i, n = set(), [], 0, len(args)
    while i < n:
        a = args[i]
        if a == "--":
            raise Deny(UNSUPPORTED.format("the -- separator on the push invocation"))
        if a.startswith("--"):
            name, eq, _ = a.partition("=")
            if name not in PUSH_LONG or (eq and name not in PUSH_LONG_WITH_VALUE):
                raise Deny(UNSUPPORTED.format("the push option " + a))
            if name == "--push-option" and not eq:
                i += 1                   # its value is the next word
            flags.add(name)
        elif a.startswith("-") and len(a) > 1:
            for j, c in enumerate(a[1:], start=1):
                if c == "o":             # -o <option> or -o<option>: the rest is its value
                    if j == len(a) - 1:
                        i += 1
                    break
                if c not in PUSH_SHORT:
                    raise Deny(UNSUPPORTED.format("the push option -" + c))
                flags.add("-" + c)
        else:
            positional.append(a)
        i += 1
    remote = positional[0] if positional else None
    return flags, remote, positional[1:]


def default_branch(repo, remote):
    head = repo.run("symbolic-ref", "--quiet", "--short", "refs/remotes/" + remote + "/HEAD")
    if head and head.strip().startswith(remote + "/"):
        return head.strip()[len(remote) + 1:]
    for ref in ("refs/remotes/" + remote + "/", "refs/heads/"):
        for name in ("main", "master"):
            if repo.has_ref(ref + name):
                return name
    return "main"


# ------------------------------------------------------------------ one push
def evaluate(cwd, assigns, repo_opts, config_opts, args):
    """None to allow, a reason string to ask; raises Deny to deny."""
    flags, remote_arg, refspecs = parse_push(args)
    if "-n" in flags or "--dry-run" in flags:
        return None                                    # never scanned, never asked
    if config_opts:
        raise Deny(UNSUPPORTED.format("a " + config_opts[0] + " option on the push invocation"))
    for opt in repo_opts:
        name = opt.split("=", 1)[0]
        if name.startswith("--"):
            # Only -C resolves the way the scan needs; --git-dir and --work-tree would
            # leave it reading the wrong tree.
            raise Deny(UNSUPPORTED.format(name + " on the push invocation"))
    for name in assigns:
        if GIT_ENV_UNSUPPORTED.match(name):
            raise Deny(UNSUPPORTED.format(name + " set on the push invocation"))

    repo = Repo(cwd, repo_opts)
    root = repo.run("rev-parse", "--show-toplevel")
    if not root or not root.strip():
        raise Deny("Push guard: cannot resolve the repository this push runs in ({}). Run it "
                   "from inside the repository, or as git -C <path> push.".format(cwd))
    root = root.strip()

    push_default = repo.config("push.default")
    if push_default not in (None, "simple", "current"):
        raise Deny(UNSUPPORTED.format("push.default=" + push_default))
    if repo.config("remote.pushDefault") is not None:
        raise Deny(UNSUPPORTED.format("remote.pushDefault"))
    branch = repo.run("symbolic-ref", "--quiet", "--short", "HEAD")
    branch = branch.strip() if branch else None
    if branch and repo.config("branch." + branch + ".pushRemote") is not None:
        raise Deny(UNSUPPORTED.format("branch." + branch + ".pushRemote"))
    if remote_arg and ("$" in remote_arg or "`" in remote_arg):
        raise Deny("Push guard: the remote " + remote_arg + " is a shell value the guard cannot "
                   "know. Name the remote literally.")
    remote = remote_arg or (branch and repo.config("branch." + branch + ".remote")) or "origin"
    if remote not in (repo.run("remote") or "").split():
        raise Deny(UNSUPPORTED.format("a push to " + remote + ", which is not a configured remote"))
    for key in ("remote." + remote + ".push", "remote." + remote + ".mirror"):
        if repo.config(key) is not None:
            raise Deny(UNSUPPORTED.format(key))
    push_urls = (repo.run("remote", "get-url", "--push", "--all", remote) or "").split("\n")
    push_urls = [u for u in push_urls if u.strip()]
    fetch_url = (repo.run("remote", "get-url", remote) or "").strip()
    if len(push_urls) != 1 or push_urls[0].strip() != fetch_url:
        raise Deny(UNSUPPORTED.format(
            "remote." + remote + " pushes somewhere other than it fetches from "
            "(pushurl, a second url, or pushInsteadOf)"))

    default = default_branch(repo, remote)
    asks, sources, dests = [], [], []
    deleting = "-d" in flags or "--delete" in flags
    if "--mirror" in flags or "--all" in flags:
        asks.append("it pushes every ref (--mirror or --all)")
    if deleting or "--prune" in flags:
        asks.append("it deletes remote refs (--delete, -d or --prune)")
    if "-f" in flags or "--force" in flags:
        asks.append("it force-pushes without a lease (--force or -f)")
    for spec in refspecs:
        s = "HEAD" if spec in CURRENT_BRANCH else spec
        if "$" in s or "`" in s:
            raise Deny("Push guard: the refspec " + spec + " is a shell value the guard cannot "
                       "know, so it cannot tell where the push goes. Name the branch literally "
                       "(git push origin <branch>, or HEAD for the current one).")
        if s.startswith("+"):
            asks.append("the refspec " + spec + " force-pushes without a lease")
            s = s[1:]
        if "*" in s:
            # Denied, not asked: a wildcard names no branches, so there is nothing to scan,
            # and an approved ask would publish whatever it matched unscanned.
            raise Deny("Push guard: the wildcard refspec " + spec + " can update any branch, "
                       "the default branch included, and names no commits to scan. Push the "
                       "branches by name, or push by hand.")
        src, colon, dst = s.partition(":")
        if colon and not dst:
            # `:` and `+:` push every matching branch; `x:` names no destination.
            raise Deny(UNSUPPORTED.format("the refspec " + spec + ", which names no single "
                                          "destination (: pushes every matching branch)"))
        if colon and not src:
            asks.append("the refspec " + spec + " deletes " + dst + " on " + remote)
            continue
        if deleting:
            continue                                   # these name refs to delete
        if src.startswith("-"):
            raise Deny("Push guard: cannot read the refspec " + spec + ".")
        if src in ("HEAD", "@"):
            src = "HEAD"
            if not colon:
                if not branch:
                    raise Deny("Push guard: HEAD is detached, so " + spec + " names no branch. "
                               "Name the destination: git push " + remote + " HEAD:<branch>.")
                dst = branch
        elif not colon:
            dst = src
        sources.append(src)
        dests.append(dst)
    if not refspecs and not (deleting or flags & {"--tags", "--all", "--mirror"}):
        if not branch:
            raise Deny("Push guard: HEAD is detached, so a push without a refspec has no branch "
                       "to push. Name the destination: git push " + remote + " HEAD:<branch>.")
        sources.append("HEAD")
        dests.append(branch)
    for dst in dests:
        name = dst[len("refs/heads/"):] if dst.startswith("refs/heads/") else dst
        if not name.startswith("refs/") and name == default:
            asks.append("it updates " + default + ", the default branch of " + remote)

    if asks:
        return "Push guard: this push needs Michael, because " + "; ".join(asks) + "."
    return None


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = payload.get("tool_input", {}).get("command") or ""
        cwd = payload.get("cwd") or os.getcwd()
    except (ValueError, AttributeError):
        return
    if not cmd:
        return
    shape = None
    try:
        try:
            tokens = tokenize(cmd)
        except ValueError:
            tokens = None                              # unbalanced quotes: not plain
        if tokens is not None:
            shape = parse_plain(tokens, cwd)
        if shape is None:
            if could_push(cmd, tokens, cwd):           # the raw text: a superset, never trimmed
                raise Deny(PLAIN)
            return
        reason = judge(shape)
    except Deny as d:
        print(decision("deny", str(d)))
        return
    except Exception as e:                             # a bug here must not open the gate
        # A plain git command may be an alias push (git pom): it fails closed as well.
        if shape is not None or PUSH_SHAPE.search(cmd):
            print(decision("deny", "Push guard: internal error ({}: {}), so the push is "
                                   "refused. Push by hand.".format(type(e).__name__, e)))
        return
    if reason:
        print(decision("ask", reason))


if __name__ == "__main__":
    main()
```

Check syntax: `/usr/bin/python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' dot_claude/git-push-guard.py` — expected: no output, exit 0.

- [ ] **Step 4: Wire rule 4 into the guard**

In `dot_claude/executable_git-forge-guard.sh`, make these five replacements.

(a) Replace

```bash
# It also carries one genuine danger gate (rule 3): `glab api` calls that write.
#
```

with

```bash
# It also carries two genuine danger gates: `glab api` calls that write (rule 3), and
# `git push` (rule 4, in git-push-guard.py beside this file: default-branch, force,
# delete and mirror pushes ask; an unsupported push configuration or a secret in the
# outgoing commits is denied).
#
```

(b) Replace

```bash
# SAFETY: a guard that breaks unrelated commands is worse than no guard. There is
# no `set -e`; every failure path calls allow(); anything unparseable is allowed.
#
# Bypass for a one-off: put FORGE_GUARD=off anywhere in the command.
```

with

```bash
# SAFETY: a guard that breaks unrelated commands is worse than no guard. There is
# no `set -e`; every failure path of rules 1-2 calls allow(); anything unparseable is
# allowed. Rules 3 and 4 are danger gates and fail the other way (see each).
#
# Bypass for a one-off: put FORGE_GUARD=off anywhere in the command. It lifts rules 1
# and 2 only, the behavioural ones; it never lifts rule 3 or rule 4.
```

(c) Replace

```bash
allow() { exit 0; }
```

with

```bash
# A rule-4 ask is held here rather than printed at once, so that a rule 1-2 deny
# further down still wins over it (deny beats ask). allow() releases it.
pending=""
allow() { [ -z "$pending" ] || printf '%s\n' "$pending"; exit 0; }
```

(d) Replace the fast path and the bypass line — this exact block:

```bash
# Fast path. This hook fires on EVERY Bash call, so the common case must cost no
# subprocess at all — a shell-builtin substring test on the raw payload, before
# any JSON parsing. Everything below is reached only by the handful of commands
# that even mention a commit or an MR/PR.
case "$payload" in
  *"git commit"*|*"glab mr create"*|*"glab mr update"* \
  |*"gh pr create"*|*"gh pr edit"*|*"az repos pr create"*|*"az repos pr update"* \
  |*"glab api"*) ;;
  *) allow ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] || allow

case "$cmd" in *FORGE_GUARD=off*) allow ;; esac
```

with

```bash
# Fast path. This hook fires on EVERY Bash call, so the common case must cost no
# subprocess at all — a shell-builtin substring test on the raw payload, before
# any JSON parsing. Everything below is reached only by the handful of commands
# that even mention a commit, an MR/PR, or a push.
forge_candidate=0
case "$payload" in
  *"git commit"*|*"glab mr create"*|*"glab mr update"* \
  |*"gh pr create"*|*"gh pr edit"*|*"az repos pr create"*|*"az repos pr update"* \
  |*"glab api"*) forge_candidate=1 ;;
esac

# Rule 4 candidates, from three independent signals:
#   push_word      the payload mentions "push" at all (cheap and broad);
#   push_selector  it mentions git together with something that selects ANOTHER repository
#                  or configuration (-C, --git-dir, --work-tree, -c, GIT_DIR, GIT_WORK_TREE,
#                  GIT_CONFIG*, a cd). An alias defined there cannot be listed from here,
#                  so the helper resolves it in the repository git would select;
#   push_alias     it names an alias that expands to a push (the dotfiles define
#                  pom = push origin main), listed with ONE git call in the payload's cwd,
#                  read from the raw JSON with a builtin match.
# A payload that mentions neither git nor push costs no subprocess at all, and a plain git
# command costs one git call, never the helper.
push_word=0; push_selector=0; push_alias=0
case "$payload" in *push*) push_word=1 ;; esac
case "$payload" in
  *git*)
    case "$payload" in
      *" -C"*|*"--git-dir"*|*"--work-tree"*|*" -c"*|*GIT_DIR*|*GIT_WORK_TREE*|*GIT_CONFIG*|*"cd "*)
        push_selector=1 ;;
    esac
    if [ "$push_selector" = 0 ]; then
      pcwd=.
      cwd_re='"cwd"[[:space:]]*:[[:space:]]*"([^"]*)"'
      [[ $payload =~ $cwd_re ]] && pcwd=${BASH_REMATCH[1]}
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        case "$payload" in *"$a"*) push_alias=1; break ;; esac
      done <<EOF
$(git -C "$pcwd" config --get-regexp '^alias\.' 2>/dev/null | sed -n -E 's/^alias\.([^ ]+) (push|!.*push).*/\1/p')
EOF
    fi
    ;;
esac
push_candidate=0
[ "$push_word$push_selector$push_alias" = 000 ] || push_candidate=1

[ "$forge_candidate" = 1 ] || [ "$push_candidate" = 1 ] || allow

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] || allow

# ------------------------------------------------------------ rule 4: git push
# The work is in git-push-guard.py beside this file: it prints a finished decision (ask
# or deny) or nothing. A deny is final. An ask is held in $pending and released by
# allow(), so the rules below can still deny. FAIL DIRECTION IS CLOSED: if the helper
# cannot run at all, a command that looks like a push is denied, with a reason the agent
# can act on. Runs before the FORGE_GUARD=off check below, which never lifts it.
if [ "$push_candidate" = 1 ]; then
  py=/usr/bin/python3
  [ -x "$py" ] || py=python3
  helper="$(dirname "$0")/git-push-guard.py"
  verdict=$(printf '%s' "$payload" | "$py" "$helper" 2>/dev/null)
  rc=$?
  case "$verdict" in
    '') ;;
    *'"permissionDecision":"ask"'*) pending=$verdict ;;
    *) printf '%s\n' "$verdict"; exit 0 ;;
  esac
  # The fallback denies on the same evidence the fast path acted on: an alias that pushes,
  # a repository selector (whose aliases only the helper can see), or a literal git push.
  # The bare word "push" alone is not enough; it is too common in unrelated commands.
  if [ "$rc" -ne 0 ]; then
    if [ "$push_alias" = 1 ] || [ "$push_selector" = 1 ] \
       || printf '%s' "$cmd" | grep -Eq 'git[^;&|]*[[:space:]]push([[:space:]]|$)'; then
      deny "Push guard: the push check could not run ($helper exited $rc), so this command, which may push, is refused. Push by hand, or restore the helper (chezmoi apply)."
    fi
  fi
fi
```

(e) Move the bypass after rule 3. Replace

```bash
    esac
    ;;
esac

# Precise gate: the forge command must actually sit in command position. Without
```

with

```bash
    esac
    ;;
esac

# The bypass lifts rules 1 and 2 only. It sits here, after both danger gates, so a
# FORGE_GUARD=off in the command can never reach a push or a glab api write.
case "$cmd" in *FORGE_GUARD=off*) allow ;; esac

# Precise gate: the forge command must actually sit in command position. Without
```

Check: `bash -n dot_claude/executable_git-forge-guard.sh && /bin/bash -n dot_claude/executable_git-forge-guard.sh` — expected: no output.

- [ ] **Step 5: Allowlist the helper**

In `.chezmoiignore`, replace

```
!.claude/git-forge-guard.sh
```

with

```
!.claude/git-forge-guard.sh
!.claude/git-push-guard.py
```

- [ ] **Step 6: Run the suite to verify it passes, under both bashes**

Run: `./tests/git-forge-guard.test.sh`
Expected: `passed: 248  failed: 0` (the count at plan time; what matters is `failed: 0` and exit 0).

Then under the macOS system bash 3.2 as the guard's interpreter:

```bash
B=$(mktemp -d "${TMPDIR:-/tmp}/bash32.XXXXXX"); ln -s /bin/bash "$B/bash"; PATH="$B:$PATH" ./tests/git-forge-guard.test.sh | tail -1; rm -rf "${B:?}"
```

Expected: `passed: 248  failed: 0`.

- [ ] **Step 7: Measure the fast path**

```bash
for c in 'ls -la' 'git status' "git -C $PWD status"; do P=$(jq -cn --arg c "$c" --arg d "$PWD" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'); /usr/bin/time -p bash -c 'for i in 1 2 3 4 5 6 7 8 9 10; do printf "%s" "$1" | bash dot_claude/executable_git-forge-guard.sh >/dev/null; done' _ "$P" 2>&1 | grep real; done
```

Expected, for ten runs each: `ls -la` and `git status` well under 0.5 s (about 0.04 s and 0.12 s at plan time); `git -C … status` under about 1 s, because a command that names another repository starts the helper by design (about 7% of Bash calls in the baseline fortnight). A plain `git status` near a second means the fast path is starting the helper; stop and find out why.

- [ ] **Step 8: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_claude/git-push-guard.py dot_claude/executable_git-forge-guard.sh tests/git-forge-guard.test.sh .chezmoiignore
git commit -m "Gate git push in the forge guard (rule 4); FORGE_GUARD=off lifts rules 1-2 only"
```

---

### Task 2: Push rule — the gitleaks scan, failing closed (sp-standard)

**Files:**
- Modify: `dot_claude/git-push-guard.py`
- Modify: `tests/git-forge-guard.test.sh`
- Modify: `dot_config/homebrew/Brewfile.tmpl`
- Create only if the history scan in Step 7 finds a false positive: `.gitleaksignore`

**Interfaces:**
- Consumes (Task 1): `evaluate(...)`, `Deny`, the test helpers `reason`, `has_reason`, `clone`, `$R`, `$REMOTES`, `$STUBBIN`, `$REALPATH`.
- Produces: `scan(root, remote, sources)` (returns on a clean scan, raises `Deny` otherwise) and `leak_reason(report_path, remote)`. The deny reason for a leak lists `- rule <RuleID> in <File> at commit <12 hex> (fingerprint <commit>:<file>:<rule>:<line>)`.

- [ ] **Step 1: Install gitleaks**

Run: `brew install gitleaks`
It writes under `/opt/homebrew`, which is outside the sandbox's write set: a sandboxed run fails with "Operation not permitted". That is a visible sandbox failure, so rerun the same command with the sandbox disabled.
Then: `gitleaks version` — expected `8.30.1` or newer.

- [ ] **Step 2: Write the failing tests**

In `tests/git-forge-guard.test.sh`, replace

```bash
	shp = !git push origin main
EOF
```

with

```bash
	shp = !git push origin main
[format]
	pretty = format:%h %s
EOF
```

(Michael's global config sets `format.pretty`; this makes the suite meet it too.)

Insert this block immediately before the final two lines `echo` / `echo "passed: $pass  failed: $fail"` (after the "the helper deploys beside the guard" section):

```bash

echo "== rule 4: the secret scan =="
PATH="$REALPATH"
CLEAN=$(clone clean)
printf 'hello\n' > "$CLEAN/notes.txt"
git -C "$CLEAN" add notes.txt && git -C "$CLEAN" commit -q -m "a clean change"
if ! command -v gitleaks >/dev/null 2>&1; then
  fail=$((fail + 1))
  printf '  FAIL %s\n' "gitleaks is installed (brew install gitleaks); the scan cases cannot run"
else
  # The fixture secret is assembled at runtime from two halves, so no committed file
  # holds a scannable credential: this suite is itself pushed through the scan it tests.
  part_a=AKIA; part_b=QX7T2MZL4KRB6WNP
  SECRET_LINE="aws = \"$part_a$part_b\""
  LEAKY=$(clone leaky)
  printf '%s\n' "$SECRET_LINE" > "$LEAKY/creds.txt"
  git -C "$LEAKY" add creds.txt && git -C "$LEAKY" commit -q -m "add creds"
  expect allow "a clean feature branch is scanned and passes" "$CLEAN" 'git push origin feat'
  expect deny  "a secret in the outgoing commits"             "$LEAKY" 'git push origin feat'
  has_reason   "the deny names rule, file and commit" \
               "rule aws-access-token in creds.txt at commit" "$LEAKY" 'git push origin feat'
  got=$(reason "$LEAKY" 'git push origin feat')
  # The suite's gitconfig carries a format.pretty like Michael's, which once made gitleaks
  # report findings with no commit. The fingerprint must be commit-bound.
  if printf '%s\n' "$got" | grep -Eq '\(fingerprint [0-9a-f]{40}:creds\.txt:aws-access-token:1\)'; then
    pass=$((pass + 1)); printf '  ok   %s\n' "the fingerprint is bound to the commit, despite format.pretty"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n' "the fingerprint is bound to the commit, despite format.pretty ($got)"
  fi
  # -C selects the repository that is scanned: the same push, two repositories.
  expect deny  "git -C <leaky repo> is scanned there"  "$CLEAN" "git -C $LEAKY push origin feat"
  expect allow "git -C <clean repo> is scanned there"  "$LEAKY" "git -C $CLEAN push origin feat"
  case "$got" in
    *"$part_b"*) fail=$((fail + 1)); printf '  FAIL %s\n' "the deny never shows the secret" ;;
    *)           pass=$((pass + 1)); printf '  ok   %s\n' "the deny never shows the secret" ;;
  esac
  expect deny  "a secret beats an ask: deny, not ask"         "$LEAKY" 'git push origin feat:main'
  expect allow "a dry run is never scanned"                   "$LEAKY" 'git push --dry-run origin feat'
  INLINE=$(clone inline)
  printf '%s # gitleaks:allow\n' "$SECRET_LINE" > "$INLINE/creds.txt"
  git -C "$INLINE" add creds.txt && git -C "$INLINE" commit -q -m "add creds inline-allowed"
  expect deny  "an inline gitleaks:allow is not an exception" "$INLINE" 'git push origin feat'
  # The reviewed way through: the finding's fingerprint in the tracked .gitleaksignore.
  fp=$(printf '%s\n' "$got" | sed -n 's/.*(fingerprint \([^)]*\)).*/\1/p' | head -1)
  printf '%s\n' "$fp" > "$LEAKY/.gitleaksignore"
  git -C "$LEAKY" add .gitleaksignore && git -C "$LEAKY" commit -q -m "ignore a false positive"
  expect allow "a fingerprint in .gitleaksignore lets it through" "$LEAKY" 'git push origin feat'
  # Only the DESTINATION remote's history is excluded. A commit already published on
  # another remote is still scanned before it reaches this one.
  TWO=$(clone two-remotes)
  git -C "$TWO" remote add backup "$REMOTES/backup.git"
  git -C "$TWO" switch -q -c elsewhere
  printf '%s\n' "$SECRET_LINE" > "$TWO/creds.txt"
  git -C "$TWO" add creds.txt && git -C "$TWO" commit -q -m "add creds"
  git -C "$TWO" push -q backup elsewhere 2>/dev/null
  expect deny  "a secret reachable only from another remote is still scanned" "$TWO" 'git push origin elsewhere'
  expect allow "the destination remote's own history is excluded"            "$TWO" 'git push backup elsewhere'
fi

echo "== rule 4: the scan fails closed =="
NOGL="$TMP/nogl"; mkdir -p "$NOGL"; ln -s "$(command -v jq)" "$NOGL/jq"
PATH="$NOGL:/usr/bin:/bin"
expect deny  "a missing gitleaks denies the push"   "$CLEAN" 'git push origin feat'
has_reason   "and names the remedy" "brew bundle"   "$CLEAN" 'git push origin feat'
BROKEN="$TMP/brokengl"; mkdir -p "$BROKEN"
printf '#!/bin/sh\necho "gitleaks: boom" >&2\nexit 2\n' > "$BROKEN/gitleaks"; chmod 755 "$BROKEN/gitleaks"
PATH="$BROKEN:$REALPATH"
expect deny  "a gitleaks error denies the push"     "$CLEAN" 'git push origin feat'
has_reason   "and carries the error" "boom"         "$CLEAN" 'git push origin feat'
RECORD="$TMP/recordgl"; mkdir -p "$RECORD"
printf '#!/bin/sh\necho called >> "%s/calls"\nexit 0\n' "$RECORD" > "$RECORD/gitleaks"; chmod 755 "$RECORD/gitleaks"
PATH="$RECORD:$REALPATH"
expect allow "a dry run to main"                    "$CLEAN" 'git push -n origin main'
if [ -e "$RECORD/calls" ]; then
  fail=$((fail + 1)); printf '  FAIL %s\n' "a dry run never runs gitleaks"
else
  pass=$((pass + 1)); printf '  ok   %s\n' "a dry run never runs gitleaks"
fi
PATH="$STUBBIN:$REALPATH"
```

- [ ] **Step 3: Run the suite to verify it fails**

Run: `./tests/git-forge-guard.test.sh`
Expected: exit 1 with exactly these eleven FAIL lines: "git -C <leaky repo> is scanned there", "a secret in the outgoing commits", "the deny names rule, file and commit", "the fingerprint is bound to the commit, despite format.pretty", "a secret beats an ask: deny, not ask", "an inline gitleaks:allow is not an exception", "a secret reachable only from another remote is still scanned", "a missing gitleaks denies the push", "and names the remedy", "a gitleaks error denies the push", "and carries the error".

- [ ] **Step 4: Implement the scan**

In `dot_claude/git-push-guard.py`:

(a) Replace

```python
import shlex
import subprocess
import sys
```

with

```python
import shlex
import shutil
import subprocess
import sys
import tempfile
```

(b) Replace

```python
UNSUPPORTED = ("unsupported push configuration for the push guard: {}; "
               "push by hand or simplify the configuration")
```

with

```python
UNSUPPORTED = ("unsupported push configuration for the push guard: {}; "
               "push by hand or simplify the configuration")
GITLEAKS_LEAKS_EXIT = 99
GITLEAKS_TIMEOUT = 120
# gitleaks parses `git log -p` output, and log formatting config breaks the parse. Under
# Michael's own format.pretty it reported "0 commits scanned" and findings with no commit,
# so no commit-bound fingerprint. These pin git's default output for the scan alone.
GIT_LOG_DEFAULTS = [("format.pretty", "medium"), ("log.showSignature", "false"),
                    ("log.abbrevCommit", "false"), ("diff.noprefix", "false"),
                    ("diff.mnemonicPrefix", "false"), ("color.ui", "false")]
```

(c) Insert this section immediately before the line `# ------------------------------------------------------------------ one push`:

```python
# ------------------------------------------------------------------ the secret scan
def scan(root, remote, sources):
    """gitleaks over the commits this push would send. Returns on a clean scan and
    raises Deny otherwise; a scan that cannot run is a deny, never a pass.
    --ignore-gitleaks-allow: the only exception is a reviewed .gitleaksignore entry, never
    an inline comment. A repository's own .gitleaks.toml is honoured; it is tracked and
    reviewed like any other change."""
    exe = shutil.which("gitleaks")
    if not exe:
        raise Deny("Push guard: gitleaks is not installed, so the outgoing commits cannot be "
                   "scanned for secrets and the push is refused. Install it with: "
                   "brew bundle --file ~/.config/homebrew/Brewfile")
    log_opts = " ".join(sources + ["--not", "--remotes=" + remote])
    env = dict(os.environ, GIT_CONFIG_COUNT=str(len(GIT_LOG_DEFAULTS)))
    for i, (key, value) in enumerate(GIT_LOG_DEFAULTS):
        env["GIT_CONFIG_KEY_%d" % i] = key
        env["GIT_CONFIG_VALUE_%d" % i] = value
    fd, report = tempfile.mkstemp(prefix="push-guard-", suffix=".json")
    os.close(fd)
    try:
        try:
            p = subprocess.run(
                [exe, "git", "--no-banner", "--no-color", "--redact", "--ignore-gitleaks-allow",
                 "--exit-code", str(GITLEAKS_LEAKS_EXIT),
                 "--report-format", "json", "--report-path", report,
                 "--log-opts=" + log_opts, root],
                cwd=root, env=env, capture_output=True, text=True, timeout=GITLEAKS_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise Deny("Push guard: the gitleaks scan did not finish within {}s, so the push is "
                       "refused. Scan by hand (gitleaks git --redact) and push by hand."
                       .format(GITLEAKS_TIMEOUT))
        except OSError as e:
            raise Deny("Push guard: gitleaks could not run ({}), so the push is refused.".format(e))
        if p.returncode == 0:
            return
        if p.returncode == GITLEAKS_LEAKS_EXIT:
            raise Deny(leak_reason(report, remote))
        tail = "\n".join((p.stderr or p.stdout or "").strip().splitlines()[-5:])
        raise Deny("Push guard: gitleaks failed (exit {}), so the push is refused:\n{}"
                   .format(p.returncode, tail))
    finally:
        try:
            os.unlink(report)
        except OSError:
            pass


def leak_reason(report, remote):
    try:
        with open(report, encoding="utf-8") as fh:
            findings = json.load(fh)
    except (OSError, ValueError):
        findings = []
    lines = ["- rule {} in {} at commit {} (fingerprint {})".format(
        f.get("RuleID", "?"), f.get("File", "?"), str(f.get("Commit", "?"))[:12],
        f.get("Fingerprint", "?")) for f in findings[:10]]
    if len(findings) > 10:
        lines.append("- and {} more".format(len(findings) - 10))
    return ("Push guard: gitleaks found {} secret(s) in the commits this push would send to {}:\n"
            "{}\n\n"
            "Take the secret out of those commits (rewrite the branch), and rotate it if it is "
            "real. If a finding is a false positive, add its fingerprint as a line in the "
            "repository's tracked .gitleaksignore and commit that, so the exception is "
            "reviewed like any other change.").format(
                len(findings) or "one or more", remote,
                "\n".join(lines) or "- (the gitleaks report could not be read)")


```

(d) In `evaluate`, replace

```python
            asks.append("it updates " + default + ", the default branch of " + remote)

    if asks:
```

with

```python
            asks.append("it updates " + default + ", the default branch of " + remote)

    # The scan runs before any ask is returned: a push Michael approves must already be
    # clean, and a secret is a deny, which beats an ask.
    scan_sources = list(sources)
    if "--tags" in flags:
        scan_sources.append("--tags")
    if "--all" in flags:
        scan_sources.append("--branches")
    if "--mirror" in flags:
        scan_sources.append("--all")
    if scan_sources:
        scan(root, remote, scan_sources)

    if asks:
```

Check syntax: `/usr/bin/python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' dot_claude/git-push-guard.py`.

- [ ] **Step 5: Declare gitleaks in the Brewfile**

In `dot_config/homebrew/Brewfile.tmpl`, replace

```
brew "git-delta"
```

with

```
brew "git-delta"
brew "gitleaks"                        # secret scan before every push: ~/.claude/git-push-guard.py (forge guard rule 4)
```

- [ ] **Step 6: Run the suite to verify it passes**

Run: `./tests/git-forge-guard.test.sh`
Expected: `passed: 267  failed: 0` (plan-time count), exit 0. The suite takes about a minute.

- [ ] **Step 7: Scan this repository's history (Review Focus 5)**

```bash
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=format.pretty GIT_CONFIG_VALUE_0=medium \
  gitleaks git --no-banner --no-color --redact --ignore-gitleaks-allow --exit-code 99 \
  --report-format json --report-path "$TMPDIR/dotfiles-gitleaks.json" "$PWD"; echo "rc=$?"
jq -r '.[] | [.RuleID, .File, .Commit[0:12], .StartLine, .Fingerprint] | @tsv' "$TMPDIR/dotfiles-gitleaks.json"
```

The `format.pretty` override matters: without it gitleaks reports "0 commits scanned" under Michael's config. Expected at plan time: "643 commits scanned" (more by now), "no leaks found", `rc=0`, an empty table. Then create no `.gitleaksignore`.
If there are findings, review each one by opening the file at that commit (`git show <commit>:<file>`) without printing the value anywhere else:
- A false positive (a template placeholder, a public key, a test fixture): add its fingerprint as one line to a new root `.gitleaksignore`, each preceded by a `# <why this is not a secret>` comment line, and rerun until `rc=0`. chezmoi ignores dot-prefixed files at the source root, so `.gitleaksignore` is never deployed (verified at plan time).
- A real secret: STOP. Do not add it to `.gitleaksignore`. Report it to the lead for rotation.

- [ ] **Step 8: Live check against this repository (Review Focus 1)**

With Michael's real git config and the real gitleaks, the helper must let this branch's own push through silently, in each of the plain forms an agent runs:

```bash
for c in 'git push -u origin feat/safe-autonomy' 'git push -u origin HEAD' 'git push -u origin "$(git branch --show-current)"' "git -C $PWD push origin feat/safe-autonomy" 'git push -u origin feat/safe-autonomy 2>&1 | tail -5'; do
  out=$(jq -cn --arg c "$c" --arg d "$PWD" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | /usr/bin/python3 dot_claude/git-push-guard.py)
  printf '%s -> [%s]\n' "$c" "${out:-silent}"
done
```

Expected: `[silent]` for all five. Any output is a false ask or deny on a common real push; stop and fix before committing. (A chained `git add -A && git commit -m x && git push …` is denied on purpose, since the scan cannot see the commit it makes; that is Review Focus 5.)

- [ ] **Step 9: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_claude/git-push-guard.py tests/git-forge-guard.test.sh dot_config/homebrew/Brewfile.tmpl
git commit -m "Scan outgoing commits with gitleaks before a push, failing closed"
```

(Add `.gitleaksignore` to the `git add` only if Step 7 created it.)

---

### Task 3: Permission rules (sp-mechanical)

**Files:**
- Modify: `dot_claude/modify_private_settings.json` (permissions block only)
- Modify: `tests/claude-settings.test.sh`

**Interfaces:**
- Produces: `EXP_DENY` (22 rules) and `EXP_ASK` (52 rules) in the test; later tasks keep them.

- [ ] **Step 1: Write the failing tests**

In `tests/claude-settings.test.sh`:

(a) Replace

```bash
 "Read(**/*.pem)","Edit(**/*.pem)",
 "Bash(basecamp auth token*)"]'
```

with

```bash
 "Read(**/*.pem)","Edit(**/*.pem)",
 "Bash(basecamp auth token*)",
 "Bash(op read*)","Bash(op item get*)","Bash(op document get*)","Bash(op inject*)","Bash(op run*)",
 "mcp__claude_ai_Microsoft_365__outlook_create_filter",
 "mcp__claude_ai_Microsoft_365__outlook_set_vacation"]'
```

(b) Replace

```bash
 "Bash(git push --force*)","Bash(git push -f *)","Bash(git reset --hard*)",
```

with

```bash
 "Bash(git reset --hard*)",
```

(c) Replace

```bash
 "Bash(docker volume rm*)","Bash(docker compose down*)"]'
```

with

```bash
 "Bash(docker volume rm*)","Bash(docker compose down*)",
 "mcp__claude_ai_Microsoft_365__outlook_batch_delete_messages",
 "mcp__claude_ai_Microsoft_365__outlook_trash_thread",
 "mcp__claude_ai_Microsoft_365__outlook_delete_event",
 "mcp__claude_ai_Microsoft_365__sharepoint_delete_item",
 "Bash(basecamp projects trash*)","Bash(basecamp projects delete*)",
 "Bash(basecamp todos trash*)","Bash(basecamp todos delete*)",
 "Bash(basecamp todolists trash*)","Bash(basecamp todolists delete*)",
 "Bash(basecamp messages trash*)","Bash(basecamp messages delete*)",
 "Bash(basecamp chat trash*)","Bash(basecamp chat delete*)",
 "Bash(basecamp cards trash*)","Bash(basecamp cards delete*)",
 "Bash(basecamp files trash*)","Bash(basecamp files delete*)",
 "Bash(basecamp checkins trash*)","Bash(basecamp checkins delete*)",
 "Bash(basecamp schedule trash*)","Bash(basecamp schedule delete*)",
 "Bash(basecamp comments trash*)","Bash(basecamp comments delete*)",
 "Bash(helm uninstall*)","Bash(helm delete*)","Bash(az * delete*)","Bash(terraform destroy*)"]'
```

(d) Replace

```bash
# Belt and braces: every rule is a COMPLETE, closed form naming a tool we actually use.
jq_is '[.permissions.deny[], .permissions.ask[]
        | select(test("^(Read|Edit|Bash)\\([^)]+\\)$") | not)] | length' 0 \
      "every rule is a complete Read/Edit/Bash(spec) form"
```

with

```bash
# Belt and braces: every rule is a COMPLETE, closed form naming a tool we actually use:
# Read/Edit/Bash(spec), or one MCP tool named in full (mcp__<server>__<tool>, no wildcard).
jq_is '[.permissions.deny[], .permissions.ask[]
        | select((test("^(Read|Edit|Bash)\\([^)]+\\)$") or test("^mcp__[A-Za-z0-9_]+__[A-Za-z0-9_]+$")) | not)] | length' 0 \
      "every rule is a complete Read/Edit/Bash(spec) form or a named MCP tool"
```

(e) Replace

```bash
for r in "Bash(git push --force*)" "Bash(git reset --hard*)" "Bash(rm -rf ~/*)" \
         "Bash(sudo *)" "Bash(borg *)" "Bash(op item edit*)"; do
```

with

```bash
for r in "Bash(terraform destroy*)" "Bash(git reset --hard*)" "Bash(rm -rf ~/*)" \
         "Bash(sudo *)" "Bash(borg *)" "Bash(op item edit*)"; do
```

(f) Replace

```bash
jq_is '.permissions.deny | length' 15 "deny rules intact when defaultMode carried"
```

with

```bash
jq_is "(.permissions.deny | sort) == ($EXP_DENY | sort)" true "deny rules intact when defaultMode carried"
```

(g) Replace

```bash
echo "X. every wired hook script is actually managed by chezmoi"
```

with

```bash
echo "Q. the safe-autonomy permission changes (spec section 1.3)"
emit '{}'
# The push asks are gone because an ask rule is absolute: a PreToolUse hook returning
# allow loses to it, so it could never let --force-with-lease through on a feature
# branch. git-forge-guard.sh rule 4 gates every push instead; do not add them back.
for r in "Bash(git push --force*)" "Bash(git push -f *)"; do
  jq_is ".permissions.ask | index(\"$r\")" null "no ask rule for $r - rule 4 of the forge guard owns pushes"
done
# chezmoi cat runs op unsandboxed and can render a private key; it is the classifier's call.
jq_is '.permissions.allow | index("Bash(chezmoi cat *)")' null "chezmoi cat is not allowlisted"
# Enumerated per resource, so a comment body that merely says "delete" never matches.
for res in projects todos todolists messages chat cards files checkins schedule comments; do
  jq_is ".permissions.ask | (index(\"Bash(basecamp $res trash*)\") != null) and (index(\"Bash(basecamp $res delete*)\") != null)" \
        true "basecamp $res trash and delete both ask"
done
jq_is '[.permissions.ask[] | select(startswith("Bash(basecamp") and (test(" (trash|delete)\\*\\)$") | not))] | length' 0 \
      "no basecamp ask rule matches a bare verb anywhere in the text"

echo "X. every wired hook script is actually managed by chezmoi"
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./tests/run.sh claude-settings`
Expected: FAIL, 17 failed assertions: the two exact-array checks, "danger gate present: Bash(terraform destroy*)", "deny rules intact when defaultMode carried", both "no ask rule for Bash(git push ...)", "chezmoi cat is not allowlisted", and the ten "basecamp <res> trash and delete both ask".

- [ ] **Step 3: Change the rules**

In `dot_claude/modify_private_settings.json`:

(a) Replace

```
          "Bash(chezmoi cat *)",
```

with

```
          # NOTE: no chezmoi cat here. It runs op unsandboxed and can render private
          # keys, so it goes to the auto-mode classifier like any other command.
```

(b) Replace

```
          "Bash(basecamp auth token*)"
        ],
```

with

```
          "Bash(basecamp auth token*)",
          # Secrets never enter the transcript: every op verb that prints or injects a
          # secret value. op item create/edit/delete stay asks, below.
          "Bash(op read*)",              "Bash(op item get*)",
          "Bash(op document get*)",      "Bash(op inject*)",
          "Bash(op run*)",
          # Lasting mail send-out paths: a server-side rule or an auto-reply keeps
          # sending long after the session that set it up.
          "mcp__claude_ai_Microsoft_365__outlook_create_filter",
          "mcp__claude_ai_Microsoft_365__outlook_set_vacation"
        ],
```

(c) Replace

```
          "Bash(git push --force*)",    "Bash(git push -f *)",
```

with

```
          # NOTE: no git push rules here on purpose. An ask rule is absolute (a hook allow
          # loses to it), so it could not tell --force-with-lease on a feature branch from a
          # force push to main. git-forge-guard.sh rule 4 gates pushes instead.
```

(d) Replace

```
          "Bash(docker compose down*)"
        ],
```

with

```
          "Bash(docker compose down*)",
          # Destructive Microsoft 365 actions.
          "mcp__claude_ai_Microsoft_365__outlook_batch_delete_messages",
          "mcp__claude_ai_Microsoft_365__outlook_trash_thread",
          "mcp__claude_ai_Microsoft_365__outlook_delete_event",
          "mcp__claude_ai_Microsoft_365__sharepoint_delete_item",
          # Destructive Basecamp verbs, enumerated per resource so that free text which
          # merely contains the word delete (a comment body, say) never matches.
          "Bash(basecamp projects trash*)",   "Bash(basecamp projects delete*)",
          "Bash(basecamp todos trash*)",      "Bash(basecamp todos delete*)",
          "Bash(basecamp todolists trash*)",  "Bash(basecamp todolists delete*)",
          "Bash(basecamp messages trash*)",   "Bash(basecamp messages delete*)",
          "Bash(basecamp chat trash*)",       "Bash(basecamp chat delete*)",
          "Bash(basecamp cards trash*)",      "Bash(basecamp cards delete*)",
          "Bash(basecamp files trash*)",      "Bash(basecamp files delete*)",
          "Bash(basecamp checkins trash*)",   "Bash(basecamp checkins delete*)",
          "Bash(basecamp schedule trash*)",   "Bash(basecamp schedule delete*)",
          "Bash(basecamp comments trash*)",   "Bash(basecamp comments delete*)",
          # Infrastructure teardown.
          "Bash(helm uninstall*)",      "Bash(helm delete*)",
          "Bash(az * delete*)",         "Bash(terraform destroy*)"
        ],
```

Check the counts: `printf '{}' | /bin/bash dot_claude/modify_private_settings.json | jq '{deny:(.permissions.deny|length), ask:(.permissions.ask|length), allow:(.permissions.allow|length)}'` — expected `22`, `52`, `19`.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./tests/run.sh claude-settings`
Expected: `ok    claude-settings  135/135` (plan-time count; `RESULT: ... 0 failed`).

- [ ] **Step 5: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_claude/modify_private_settings.json tests/claude-settings.test.sh
git commit -m "Deny secret-printing op verbs and mail send-out paths; ask on destructive M365, Basecamp and teardown; drop the push asks and the chezmoi cat allow"
```

---

### Task 4: zshenv — Homebrew first, own bins in front (sp-mechanical)

**Files:**
- Modify: `dot_config/zsh/zshenv`
- Create: `tests/zshenv.test.sh` (mode 755)

**Interfaces:** none shared.

- [ ] **Step 1: Write the failing test**

Create `tests/zshenv.test.sh`:

```bash
#!/usr/bin/env bash
# Starts a clean interactive LOGIN zsh (env -i, as Ghostty starts one, so /etc/zprofile's
# path_helper runs first) that sources the SOURCE zshenv the way dot_zshrc does, and checks
# where commands resolve.
#
# The bug this pins: `brew shellenv` PREPENDS /opt/homebrew/bin, so everything zshenv put on
# PATH before it ended up behind Homebrew, and Homebrew's `codex` shadowed the
# ~/.local/bin/codex launcher in every interactive shell.
#
# HOME is a temp directory holding a stub launcher, so the check never depends on what is
# deployed. Real Homebrew is used on purpose: its shellenv is the thing being ordered.
#
#   ./tests/zshenv.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ZSHENV="$SRC/dot_config/zsh/zshenv"
[ -f "$ZSHENV" ] || { echo "missing script under test: $ZSHENV" >&2; exit 2; }
[ -x /bin/zsh ] || { echo "no /bin/zsh" >&2; exit 2; }
[ -x /opt/homebrew/bin/brew ] || { echo "Homebrew is not at /opt/homebrew; this suite needs it" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/zshenv.XXXXXX")"
trap 'rm -rf "$T"' EXIT
FAKE="$T/home"
mkdir -p "$FAKE/.local/bin"
printf '#!/bin/sh\necho launcher\n' > "$FAKE/.local/bin/codex"
chmod 755 "$FAKE/.local/bin/codex"
printf 'source "%s"\n' "$ZSHENV" > "$FAKE/.zshrc"

probe() { # probe <zsh code> -> its stdout in a clean interactive login shell
  env -i HOME="$FAKE" USER="${USER:-michael}" TERM=dumb PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    ZDOTDIR="$FAKE" /bin/zsh -il -c "$1" 2>/dev/null
}

first=$(probe 'type -a codex' | head -1)
if [ "$first" = "codex is $FAKE/.local/bin/codex" ]; then
  _pass "type -a codex lists the ~/.local/bin launcher first"
else
  _fail "type -a codex lists the ~/.local/bin launcher first" "$first"
fi
if [ -x /opt/homebrew/bin/codex ]; then
  if probe 'type -a codex' | grep -qx 'codex is /opt/homebrew/bin/codex'; then
    _pass "Homebrew's codex is still reachable, behind the launcher"
  else
    _fail "Homebrew's codex is still reachable, behind the launcher" "$(probe 'type -a codex' | tr '\n' '|')"
  fi
fi

path=$(probe 'print -r -- $PATH')
index_of() { printf '%s\n' "$path" | tr ':' '\n' | grep -nxF -- "$1" | head -1 | cut -d: -f1; }
bin=$(index_of "$FAKE/.local/bin"); krew=$(index_of "$FAKE/.krew/bin"); brew=$(index_of /opt/homebrew/bin)
if [ -n "$bin" ] && [ -n "$brew" ] && [ "$bin" -lt "$brew" ]; then
  _pass "~/.local/bin precedes /opt/homebrew/bin on PATH"
else
  _fail "~/.local/bin precedes /opt/homebrew/bin on PATH" "$path"
fi
if [ -n "$krew" ] && [ -n "$brew" ] && [ "$krew" -lt "$brew" ]; then
  _pass "the krew bin precedes /opt/homebrew/bin on PATH"
else
  _fail "the krew bin precedes /opt/homebrew/bin on PATH" "$path"
fi
if [ -n "$bin" ] && [ -n "$krew" ] && [ "$bin" -lt "$krew" ]; then
  _pass "~/.local/bin leads the krew bin, as it leads Claude's own PATH"
else
  _fail "~/.local/bin leads the krew bin, as it leads Claude's own PATH" "$path"
fi

got=$(probe 'print -r -- $HOMEBREW_PREFIX')
[ "$got" = /opt/homebrew ] && _pass "HOMEBREW_PREFIX comes from brew shellenv" || _fail "HOMEBREW_PREFIX comes from brew shellenv" "$got"
got=$(probe 'print -r -- $RUBY_CONFIGURE_OPTS')
[ "$got" = "--with-jemalloc=/opt/homebrew/opt/jemalloc" ] \
  && _pass "the jemalloc path is built from HOMEBREW_PREFIX" \
  || _fail "the jemalloc path is built from HOMEBREW_PREFIX" "$got"
# `brew --prefix <formula>` can reach the network (it refreshes the API index), which is a
# slow shell start at best. Nothing in zshenv may call it.
if grep -v '^[[:space:]]*#' "$ZSHENV" | grep -q 'brew --prefix'; then
  _fail "zshenv calls no brew --prefix" "$(grep -n 'brew --prefix' "$ZSHENV")"
else
  _pass "zshenv calls no brew --prefix"
fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then `chmod 755 tests/zshenv.test.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/run.sh zshenv`
Expected: FAIL with 5 or 6 failed: "type -a codex lists the ~/.local/bin launcher first", the three PATH-order checks and "zshenv calls no brew --prefix"; sandboxed, the jemalloc check fails too, because `brew --prefix jemalloc` tries to refresh Homebrew's API index over the network. If Homebrew's codex is not installed, the "still reachable" check is simply not run; the PATH-order checks carry the assertion.

- [ ] **Step 3: Fix the order**

In `dot_config/zsh/zshenv`, replace

```zsh
# Set $PATH environment variable
export PATH=$XDG_BIN_HOME:$PATH
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

# Homebrew configuration
eval "$(/opt/homebrew/bin/brew shellenv)"
export HOMEBREW_PREFIX=$(brew --prefix)
export FPATH="$HOMEBREW_PREFIX/share/zsh/site-functions:${FPATH}"
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_BUNDLE_FILE="$XDG_CONFIG_HOME/homebrew/Brewfile"
```

with

```zsh
# Homebrew configuration. FIRST, because `brew shellenv` PREPENDS /opt/homebrew/bin:
# anything put on PATH before it ends up behind Homebrew, which is how Homebrew's codex
# came to shadow the ~/.local/bin/codex launcher. shellenv also exports HOMEBREW_PREFIX,
# so nothing below calls `brew --prefix` (which can reach the network).
eval "$(/opt/homebrew/bin/brew shellenv zsh)"
export FPATH="$HOMEBREW_PREFIX/share/zsh/site-functions:${FPATH}"
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_BUNDLE_FILE="$XDG_CONFIG_HOME/homebrew/Brewfile"

# Then the user's own bins, in FRONT of Homebrew: ~/.local/bin first, then krew.
# tests/zshenv.test.sh pins this order.
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
export PATH=$XDG_BIN_HOME:$PATH
```

and replace

```zsh
export RUBY_CONFIGURE_OPTS="--with-jemalloc=$(brew --prefix jemalloc)"
```

with

```zsh
export RUBY_CONFIGURE_OPTS="--with-jemalloc=$HOMEBREW_PREFIX/opt/jemalloc"
```

- [ ] **Step 4: Run it to verify it passes**

Run: `./tests/run.sh zshenv`
Expected: `ok    zshenv  8/8` (7/7 when Homebrew's codex is absent).

- [ ] **Step 5: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_config/zsh/zshenv tests/zshenv.test.sh
git commit -m "zshenv: run brew shellenv first so ~/.local/bin wins; drop brew --prefix"
```

---

### Task 5: Settings merge, inverted (sp-standard)

**Files:**
- Modify: `dot_claude/modify_private_settings.json`
- Modify: `tests/claude-settings.test.sh`

**Interfaces:**
- Consumes (Task 3): `EXP_DENY`, `EXP_ASK`, section Q.
- Produces: in the jq program, `$live` (the live object), `$perm` (its `permissions` or `{}`), the owned overlay `$live + { ... }`, and the retired list `del(.includeCoAuthoredBy, .voiceEnabled)` that Task 6 extends. In the test, `hook_matchers <event> <command>` (prints the comma-joined matchers of every entry under `.hooks[<event>]` that runs `<command>`), used by Tasks 6 and 11.

Design, for the reviewer: owned keys are overlaid with jq's object `+`, which replaces each named top-level key wholesale — so `env`, `attribution`, `hooks`, `sandbox`, `statusLine`, `voice` and the scalars never keep a stale nested entry. `permissions` is the one partly owned key: `allow`, `deny` and `ask` are replaced wholesale, `defaultMode` is seeded if absent, and any other `permissions` key (such as `additionalDirectories`) is carried. Runtime-owned keys (`autoMode`, `enabledPlugins`, `extraKnownMarketplaces`, `modelSettings`, the notification toggles, `autoContinueAtUsageLimit`, and any unknown key) are simply never named, so they survive. The larger alternative, a declared per-key ownership table with deep merges, was rejected: every nested owned object here should be replaced, not merged, so a table buys nothing.

- [ ] **Step 1: Write the failing tests**

In `tests/claude-settings.test.sh`:

(a) Replace

```bash
emit '{}'
jq_is '.autoContinueAtUsageLimit == null' true "autoContinueAtUsageLimit not invented when absent"
```

with

```bash
emit '{}'
jq_is '.autoContinueAtUsageLimit == null' true "autoContinueAtUsageLimit not invented when absent"

echo "E2. the merge starts from the live file: owned keys win, everything else survives"
# Until 2026-09-30 the script rebuilt the object and carried a named whitelist, so every
# runtime key nobody listed vanished on apply (modelSettings was the fourth). It now
# overlays the owned keys on the live file, so an UNKNOWN key must survive too.
emit '{"modelSettings":{"opus":{"x":1}},"someFutureKey":{"nested":[1,2]},"permissions":{"additionalDirectories":["/tmp/extra"],"allow":["Bash(stale-allow *)"],"ask":["Bash(stale-ask *)"],"deny":["Bash(stale-deny *)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"stale"}]}]},"sandbox":{"stale":true},"env":{"STALE":"1"},"cleanupPeriodDays":14,"includeCoAuthoredBy":true,"voiceEnabled":true}'
jq_is '.modelSettings.opus.x'              1      "modelSettings survives an apply"
jq_is '.someFutureKey.nested | length'     2      "an unknown future key survives an apply"
jq_is '.permissions.additionalDirectories[0]' /tmp/extra "a runtime permissions key survives"
jq_is '.permissions.allow | index("Bash(stale-allow *)")' null "a stale allow rule is replaced, never merged"
jq_is '.permissions.ask   | index("Bash(stale-ask *)")'   null "a stale ask rule is replaced, never merged"
jq_is '.permissions.deny  | index("Bash(stale-deny *)")'  null "a stale deny rule is replaced, never merged"
jq_is '.hooks | has("Stop")'               false  "owned hooks replace the live hooks wholesale"
jq_is '.sandbox | has("stale")'            false  "owned sandbox replaces the live sandbox wholesale"
jq_is '.env | has("STALE")'                false  "owned env replaces the live env wholesale"
jq_is '.cleanupPeriodDays'                 30     "cleanupPeriodDays is owned, and is 30"
jq_is 'has("includeCoAuthoredBy")'         false  "retired key includeCoAuthoredBy is deleted"
jq_is 'has("voiceEnabled")'                false  "retired key voiceEnabled is deleted"
FIRST=$OUT
emit "$FIRST"
if [ "$(printf '%s' "$OUT" | jq -S .)" = "$(printf '%s' "$FIRST" | jq -S .)" ]; then
  _pass "a second apply changes nothing"
else
  _fail "a second apply changes nothing" "the second pass differs from the first"
fi
# A live-sized file under the system bash. The empty-input check used to be a bash 3.2
# pattern substitution that took 8-40s on a real 13 KB settings.json.
emit '{}'; BIG=$OUT
start=$SECONDS
emit "$BIG"
if [ $((SECONDS - start)) -le 3 ]; then
  _pass "a live-sized settings file is processed in seconds by /bin/bash"
else
  _fail "a live-sized settings file is processed in seconds by /bin/bash" "$((SECONDS - start))s"
fi
```

(b) Replace

```bash
# so MRs kept carrying a Claude-Session trailer while co-authorship was already off. Pin all
# three, and keep the deprecated key as the fallback for builds predating `attribution`.
jq_is '.attribution.sessionUrl' 'false' "session link suppressed (attribution.sessionUrl)"
jq_is '.attribution.commit'     ''      "commit attribution text empty"
jq_is '.attribution.pr'         ''      "PR attribution text empty"
jq_is '.includeCoAuthoredBy'    'false' "deprecated co-authored-by fallback still false"
```

with

```bash
# so MRs kept carrying a Claude-Session trailer while co-authorship was already off. Pin all
# three. The deprecated key itself is retired (spec 2026-09-30 section 4 item 2).
jq_is '.attribution.sessionUrl' 'false' "session link suppressed (attribution.sessionUrl)"
jq_is '.attribution.commit'     ''      "commit attribution text empty"
jq_is '.attribution.pr'         ''      "PR attribution text empty"
jq_is 'has("includeCoAuthoredBy")' 'false' "the deprecated includeCoAuthoredBy key is gone"
```

(c) Replace

```bash
jq_is '.hooks.SessionStart[0].hooks[0].command
       | contains("CLAUDE_ENV_FILE") and contains("GIT_SSH_COMMAND") and contains("ssh-sandbox-proxy")' true \
      "SessionStart hook exports GIT_SSH_COMMAND to CLAUDE_ENV_FILE via the proxy helper"
```

with

```bash
jq_is '[.hooks.SessionStart[].hooks[].command
        | select(contains("CLAUDE_ENV_FILE") and contains("GIT_SSH_COMMAND") and contains("ssh-sandbox-proxy"))]
       | length' 1 \
      "SessionStart hook exports GIT_SSH_COMMAND to CLAUDE_ENV_FILE via the proxy helper"
```

(d) Replace the whole section N — everything from the line `echo "N. both Bash guards are wired as PreToolUse hooks"` up to (not including) the line `echo "O. basecamp is allowlisted read-only"` — with:

```bash
echo "N. every guard is wired exactly once, found by its command"
# Matched by COMMAND, not by list position: entries are added and removed over time, and
# a positional assertion silently retargets itself at whatever moved into the slot.
# hook_matchers <event> <command> -> the matchers of every entry running that command.
hook_matchers() {
  printf '%s' "$OUT" | jq -r --arg e "$1" --arg c "$2" \
    '[.hooks[$e][]? | select(any(.hooks[]?; .command == $c)) | .matcher] | map(tostring) | join(",")'
}
emit '{}'
for g in git-forge-guard worktree-guard xreview-guard path-resolution-guard; do
  got=$(hook_matchers PreToolUse "bash \$HOME/.claude/$g.sh")
  if [ "$got" = "Bash" ]; then _pass "$g runs once, on the Bash tool"; else _fail "$g runs once, on the Bash tool" "$got"; fi
done
# The apply-window guard inspects Edit/Write, so it must match every tool.
got=$(hook_matchers PreToolUse 'bash $HOME/.claude/xreview-apply-guard.sh')
if [ "$got" = "*" ]; then _pass "xreview-apply-guard runs once, on every tool"; else _fail "xreview-apply-guard runs once, on every tool" "$got"; fi
jq_is '.hooks.PreToolUse | length' 5 "no PreToolUse entry beyond the five guards"
# The SessionStart hooks must survive alongside them — adding PreToolUse replaced the
# whole hooks object once during development.
jq_is '.hooks.SessionStart | length' 2 "both SessionStart hooks present"
jq_is "[.hooks.SessionStart[] | select(.matcher == \"*\") | .hooks[]
        | select(.command == \"bash '$HOME/.claude/hooks/herdr-agent-state.sh' session\" and .timeout == 10)] | length" 1 \
      "the herdr agent-state hook: absolute path, session arg, installer matcher and timeout"

```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./tests/run.sh claude-settings`
Expected: FAIL with 8 failed: "modelSettings survives an apply", "an unknown future key survives an apply", "a runtime permissions key survives", "cleanupPeriodDays is owned, and is 30", both "retired key ... is deleted", "a live-sized settings file is processed in seconds by /bin/bash", and "the deprecated includeCoAuthoredBy key is gone". The run is slow (tens of seconds): that is the bash 3.2 substitution the last of them pins.

- [ ] **Step 3: Invert the merge**

In `dot_claude/modify_private_settings.json`:

(a) Replace the header paragraph

```bash
# settings.json mixes Michael's stable config with keys Claude Code writes at runtime
# (`enabledPlugins` from `claude plugin install`, `extraKnownMarketplaces` from marketplace
# adds, `autoMode` from auto-mode learning). chezmoi can't own the whole file without the two
# sides clobbering each other, so
# this receives the CURRENT file on stdin, enforces the strictly-owned keys, carries the
# tool-written keys through untouched, and seeds model/effortLevel as defaults only (they
# are mutable via /model and /effort, so runtime changes persist). The plugin/marketplace
# *intent* is declared in
# .scripts/reconcile-agents.sh + dot_config/agents/plugins.conf; this just avoids reverting
# the tool's writes on `chezmoi apply`.
```

with

```bash
# settings.json mixes Michael's stable config with keys Claude Code writes at runtime
# (`enabledPlugins`, `extraKnownMarketplaces`, `autoMode`, `modelSettings`, the /config
# toggles, and whatever a future release adds). This receives the CURRENT file on stdin,
# starts from it, and overlays only the keys chezmoi owns; every other key survives an
# apply untouched. Owned keys are replaced wholesale, so a stale rule or hook never lingers
# in them. Keys chezmoi no longer wants are deleted by name (the retired list at the end),
# because starting from the live file would otherwise keep them forever. model,
# effortLevel, permissions.defaultMode and outputStyle are seeded only when absent. The
# plugin/marketplace *intent* is declared in .scripts/reconcile-agents.sh +
# dot_config/agents/plugins.conf.
```

(b) Replace

```bash
# Fresh machine: no existing file => empty stdin => start from {}.
[ -z "${input//[[:space:]]/}" ] && input='{}'
```

with

```bash
# Fresh machine: no existing file => empty stdin => start from {}. A case pattern, not
# ${input//[[:space:]]/}: bash 3.2 runs that substitution in quadratic time, 8-40s on a
# real 13 KB settings.json.
case "$input" in *[![:space:]]*) ;; *) input='{}' ;; esac
```

(c) Replace

```
  # capture from the current file (null when absent): tool-written keys are carried
  # through as-is; model/effortLevel/defaultMode/outputStyle are seeded as defaults only
  # (applied at the end) — all four are mutable at runtime via /model, /effort,
  # /permissions and /output-style.
  .agentPushNotifEnabled as $pushnotif
  | .inputNeededNotifEnabled as $inputnotif
  | .autoContinueAtUsageLimit as $autocontinue
  | .enabledPlugins as $plugins
  | .extraKnownMarketplaces as $mkts
  | .autoMode as $automode
  | .model as $curmodel
  | .effortLevel as $cureffort
  | .permissions.defaultMode as $curmode
  | .outputStyle as $curstyle
  | {
      "theme": "custom:tokyo-night",
      "cleanupPeriodDays": 14,
```

with

```
  # Start from the LIVE file and overlay the owned keys with +, which replaces each named
  # key wholesale and leaves every other key alone. Until 2026-09-30 this rebuilt the object
  # and carried a named whitelist, so every runtime key nobody listed (the notification
  # toggles, autoContinueAtUsageLimit, modelSettings) vanished on the next apply.
  # NB: no apostrophes anywhere in this program; it is one single-quoted shell string.
  . as $live
  | ($live.permissions // {}) as $perm
  | $live + {
      "theme": "custom:tokyo-night",
      # 30 days of transcripts: the safe-autonomy evaluation measures over them.
      "cleanupPeriodDays": 30,
```

(d) Replace

```
      # the commit/PR attribution text. The deprecated key is kept as a fallback for
      # builds that predate `attribution`; both settings say the same thing.
      "attribution": { "commit": "", "pr": "", "sessionUrl": false },
      "includeCoAuthoredBy": false,
```

with

```
      # the commit/PR attribution text. The deprecated key is retired (deleted below).
      "attribution": { "commit": "", "pr": "", "sessionUrl": false },
```

(e) Drop the dead literal. Replace

```
          "Bash(az * delete*)",         "Bash(terraform destroy*)"
        ],
        "defaultMode": "default"
      },
```

with

```
          "Bash(az * delete*)",         "Bash(terraform destroy*)"
        ]
      },
```

(f) Replace

```
      "skipAutoPermissionPrompt": true,
      "voiceEnabled": false
    }
```

with

```
      "skipAutoPermissionPrompt": true
    }
```

(g) Replace the whole tail — every line from `  # carry the tool-written keys through if the current file had them` down to and including `  | .outputStyle = ($curstyle // "Concise")` — with:

```
  # permissions is owned only in part: allow, deny and ask above replace the live lists
  # wholesale; every other permissions key in the live file (additionalDirectories, say)
  # is carried, and defaultMode is seeded below.
  | .permissions = ($perm + .permissions)
  # Retired keys: owned once, owned no more. Starting from the live file keeps a key
  # forever unless it is deleted here by name. includeCoAuthoredBy is superseded by
  # attribution, voiceEnabled by the voice object.
  | del(.includeCoAuthoredBy, .voiceEnabled)
  # default-only: keep the current value if set (runtime /model, /effort, /permissions,
  # /output-style persist), otherwise seed the default; deleting the key and re-applying
  # restores it. outputStyle names a built-in style (Proactive, Concise, Explanatory,
  # Learning) or a file in ~/.claude/output-styles.
  | .model = ($live.model // "opus[1m]")
  | .effortLevel = ($live.effortLevel // "xhigh")
  | .permissions.defaultMode = ($perm.defaultMode // "auto")
  | .outputStyle = ($live.outputStyle // "Concise")
```

(The closing `'` line after it stays.)

(h) Two comments still claim positional pins. Replace

```
          # APPENDED deliberately: the GIT_SSH_COMMAND hook must stay at index 0,
          # which claude-settings.test.sh pins by position. No apostrophes in these
          # comments; see the note further down about ending the shell string.
```

with

```
          # claude-settings.test.sh finds each hook by its command, not its position.
          # No apostrophes in these comments: the program is one single-quoted string.
```

and replace

```
        # Order is load-bearing — claude-settings.test.sh pins each guard by index.
```

with

```
        # claude-settings.test.sh finds each guard by its command, so order carries no meaning.
```

Check: `grep -n "'" dot_claude/modify_private_settings.json` — every hit must be outside the jq program (the header comment, the `input=` / `jq` lines, `--arg herdr_hook`, and the closing `'`). Then `printf '' | /bin/bash dot_claude/modify_private_settings.json | jq -r .theme` — expected `custom:tokyo-night`.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./tests/run.sh claude-settings`
Expected: `ok    claude-settings  142/142` (plan-time count), and the run now takes seconds.

- [ ] **Step 5: Compare old and new on the real settings file (Review Focus 2)**

```bash
cp ~/.claude/settings.json "$TMPDIR/live.json"
git show HEAD:dot_claude/modify_private_settings.json > "$TMPDIR/old-modify.sh"
/opt/homebrew/bin/bash "$TMPDIR/old-modify.sh" < "$TMPDIR/live.json" | jq -S . > "$TMPDIR/before.json"
/opt/homebrew/bin/bash dot_claude/modify_private_settings.json < "$TMPDIR/live.json" | jq -S . > "$TMPDIR/after.json"
jq -c 'keys' "$TMPDIR/before.json"; jq -c 'keys' "$TMPDIR/after.json"
F='del(.cleanupPeriodDays,.includeCoAuthoredBy,.voiceEnabled,.modelSettings)'
jq -S "$F" "$TMPDIR/before.json" > "$TMPDIR/b.json"; jq -S "$F" "$TMPDIR/after.json" > "$TMPDIR/a.json"
cmp "$TMPDIR/b.json" "$TMPDIR/a.json" && echo "no other differences"
/opt/homebrew/bin/bash dot_claude/modify_private_settings.json < "$TMPDIR/after.json" | jq -S . | cmp - "$TMPDIR/after.json" && echo idempotent
```

Expected: the key lists differ only in that `after` has `modelSettings` (if the live file has it) and lacks `includeCoAuthoredBy` and `voiceEnabled`; then `no other differences` and `idempotent`. (At plan time the live file held `modelSettings`, which the old script dropped.) Any other difference is a dropped or duplicated key: stop. This reads the live file and writes only under `$TMPDIR`.

- [ ] **Step 6: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_claude/modify_private_settings.json tests/claude-settings.test.sh
git commit -m "Invert the settings merge: start from the live file, overlay owned keys, delete retired ones"
```

---

### Task 6: Retire the subagent statusline (sp-mechanical)

**Files:**
- Delete: `dot_claude/executable_subagent-statusline.sh`
- Modify: `dot_claude/modify_private_settings.json`
- Modify: `tests/claude-settings.test.sh`
- Modify: `.chezmoiignore`, `.chezmoiremove`

**Interfaces:**
- Consumes (Task 5): the retired list `del(.includeCoAuthoredBy, .voiceEnabled)`, `hook_matchers`.

- [ ] **Step 1: Write the failing test**

In `tests/claude-settings.test.sh`, replace

```bash
echo "X. every wired hook script is actually managed by chezmoi"
```

with

```bash
echo "S. the subagent statusline is retired"
# It never rendered. The script is deleted, and the key must go from the LIVE file too:
# the merge starts from it, so dropping the key from the owned set alone would keep it.
emit '{"subagentStatusLine":{"type":"command","command":"bash /x/subagent-statusline.sh"}}'
jq_is 'has("subagentStatusLine")' false "a live subagentStatusLine is deleted"
jq_is '.statusLine.command | endswith("/.claude/statusline.sh")' true "the main statusline stays"

echo "X. every wired hook script is actually managed by chezmoi"
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `./tests/run.sh claude-settings`
Expected: FAIL, 1 failed: "a live subagentStatusLine is deleted" (the owned overlay re-adds it).

- [ ] **Step 3: Remove it**

In `dot_claude/modify_private_settings.json`, delete the line

```
  --arg subsl "bash $HOME/.claude/subagent-statusline.sh" \
```

delete the line

```
      "subagentStatusLine": { "type": "command", "command": $subsl },
```

and replace

```
  # forever unless it is deleted here by name. includeCoAuthoredBy is superseded by
  # attribution, voiceEnabled by the voice object.
  | del(.includeCoAuthoredBy, .voiceEnabled)
```

with

```
  # forever unless it is deleted here by name. includeCoAuthoredBy is superseded by
  # attribution, voiceEnabled by the voice object; subagentStatusLine never rendered and
  # its script is gone.
  | del(.includeCoAuthoredBy, .voiceEnabled, .subagentStatusLine)
```

Delete the script: `git rm -q dot_claude/executable_subagent-statusline.sh`.

The deployed `~/.claude/subagent-statusline.sh` must be removed on apply. `.chezmoiremove` skips any target `.chezmoiignore` ignores (verified with chezmoi 2.73 at plan time), and `.claude/*` is ignored, so the existing re-include line stays as the tombstone's enabler. In `.chezmoiignore`, replace

```
!.claude/subagent-statusline.sh
```

with

```
# Tombstone: re-included only so .chezmoiremove can reach it (chezmoi skips removing an
# ignored target). The source file is gone.
!.claude/subagent-statusline.sh
```

Append to `.chezmoiremove`:

```

# The subagent statusline, retired 2026-09-30: it never rendered.
.claude/subagent-statusline.sh
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `./tests/run.sh claude-settings`
Expected: `ok    claude-settings  144/144` (plan-time count).
Then preview the removal without touching `$HOME`: `chezmoi apply --dry-run --verbose ~/.claude/subagent-statusline.sh` — expected: a diff deleting the file, or no output if the file was never deployed on this machine. If chezmoi reports an error that needs `op`, note it and rely on the plan-time verification of the mechanism.

- [ ] **Step 5: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_claude/modify_private_settings.json tests/claude-settings.test.sh .chezmoiignore .chezmoiremove
git commit -m "Retire the subagent statusline, which never rendered"
```

(`git rm` already staged the deletion.)

---

### Task 7: run.sh — only an exact name lifts the requirement gate (sp-mechanical)

**Files:**
- Modify: `tests/run.sh`
- Create: `tests/run.test.sh` (mode 755)

**Interfaces:** none shared.

- [ ] **Step 1: Write the failing test**

Create `tests/run.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for tests/run.sh's requirement gate: a suite tagged `# test-requires:` runs only
# when named exactly or with --all. A substring filter must still skip it.
#
# Runs a COPY of run.sh in a temp directory holding two fake suites, so nothing here
# executes a real suite (and nothing recurses into this one).
#
#   ./tests/run.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$SRC/tests/run.sh"
[ -f "$RUN" ] || { echo "missing script under test: $RUN" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/runsh.XXXXXX")"
trap 'rm -rf "$T"' EXIT
cp "$RUN" "$T/run.sh"
# The tag is assembled at runtime: run.sh greps every suite FILE for a line starting with
# the tag, so a literal one anywhere in this file would make it skip this suite too.
tag="# test-requires"
printf '#!/usr/bin/env bash\n%s: a condition run.sh cannot create\necho "  ok  gated suite ran"\n' "$tag" \
  > "$T/gated-alpha.test.sh"
cat > "$T/plain-alpha.test.sh" <<'SUITE'
#!/usr/bin/env bash
echo "  ok  plain suite ran"
SUITE
chmod 755 "$T"/*.sh

# ran <label> <yes|no> <extended regex> <output> - run.sh prints `ok    <suite>` for a
# suite it ran and `skip  <suite>` for one it skipped.
ran() {
  local got=no
  printf '%s\n' "$4" | grep -Eq "$3" && got=yes
  if [ "$got" = "$2" ]; then _pass "$1"; else _fail "$1" "$(printf '%s' "$4" | tr '\n' '|')"; fi
}

out="$("$T/run.sh" 2>&1)"
ran "no filter: the gated suite is skipped"      no  'ok +gated-alpha' "$out"
ran "no filter: the plain suite runs"            yes 'ok +plain-alpha' "$out"
out="$("$T/run.sh" alpha 2>&1)"
ran "a substring filter keeps the gate"          no  'ok +gated-alpha' "$out"
ran "and still lists the skipped suite"          yes 'skip +gated-alpha' "$out"
ran "a substring filter runs the plain suite"    yes 'ok +plain-alpha' "$out"
out="$("$T/run.sh" gated 2>&1)"
ran "a prefix of the name keeps the gate"        no  'ok +gated-alpha' "$out"
out="$("$T/run.sh" gated-alpha 2>&1)"
ran "the exact suite name lifts the gate"        yes 'ok +gated-alpha' "$out"
out="$("$T/run.sh" plain gated-alpha 2>&1)"
ran "an exact name among several filters lifts it" yes 'ok +gated-alpha' "$out"
out="$("$T/run.sh" --all alpha 2>&1)"
ran "--all lifts the gate"                       yes 'ok +gated-alpha' "$out"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then `chmod 755 tests/run.test.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/run.test.sh`
Expected: `passed: 6  failed: 3` — "a substring filter keeps the gate", "and still lists the skipped suite", "a prefix of the name keeps the gate".

- [ ] **Step 3: Fix the gate**

In `tests/run.sh`, replace

```bash
# Suites with a `# test-requires:` line need conditions this runner cannot create
# (an unsandboxed shell, a live herdr, a fresh Claude session). They are listed and
# skipped unless named or --all is passed. Read the tag before believing their output.
```

with

```bash
# Suites with a `# test-requires:` line need conditions this runner cannot create
# (an unsandboxed shell, a live herdr, a fresh Claude session). They are listed and
# skipped unless named EXACTLY (`./tests/run.sh live-agent-auth`) or --all is passed; a
# substring filter (`live`) still skips them. Read the tag before believing their output.
```

replace

```bash
matches() { # matches <name>
  [ ${#filters[@]} -eq 0 ] && return 0
  local f
  for f in "${filters[@]}"; do case "$1" in *"$f"*) return 0 ;; esac; done
  return 1
}
```

with

```bash
matches() { # matches <name>
  [ ${#filters[@]} -eq 0 ] && return 0
  local f
  for f in "${filters[@]}"; do case "$1" in *"$f"*) return 0 ;; esac; done
  return 1
}

# Only an exact suite name lifts the requirement gate. A substring filter used to lift it
# too, so `./tests/run.sh live` ran the sandbox-measuring suites in whatever mode the
# shell happened to be in — the inverted-result trap AGENTS.md warns about.
named() { # named <name>
  [ ${#filters[@]} -eq 0 ] && return 1
  local f
  for f in "${filters[@]}"; do [ "$f" = "$1" ] && return 0; done
  return 1
}
```

and replace

```bash
  if [ -n "$req" ] && [ "$all" -eq 0 ] && [ ${#filters[@]} -eq 0 ]; then
```

with

```bash
  if [ -n "$req" ] && [ "$all" -eq 0 ] && ! named "$name"; then
```

- [ ] **Step 4: Run it to verify it passes**

Run: `./tests/run.sh run`
Expected: `ok    run  9/9`.

- [ ] **Step 5: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add tests/run.sh tests/run.test.sh
git commit -m "run.sh: only an exact suite name lifts the test-requires gate"
```

---

### Task 8: Codex js_repl pin removed; Herdr hook resynced (sp-mechanical)

**Files:**
- Modify: `dot_codex/modify_private_config.toml`, `tests/codex-config.test.sh`
- Modify: `dot_claude/hooks/executable_herdr-agent-state.sh`

**Interfaces:** none shared. Two commits.

- [ ] **Step 1: Write the failing Codex test**

In `tests/codex-config.test.sh`, replace

```bash
echo "A. enforced feature flags win over whatever is on disk"
# The live file had js_repl removed and memories added by Codex itself; both must be
# pinned by us, not left to the tool.
emit '[features]
js_repl = true
memories = false
prevent_idle_sleep = false
'
has '^\s*js_repl = false'           "js_repl forced off even when the live file says true"
has '^\s*memories = true'           "memories forced on even when the live file says false"
```

with

```bash
echo "A. enforced feature flags win over whatever is on disk"
# memories was added by Codex itself; it must be pinned by us, not left to the tool.
emit '[features]
js_repl = true
memories = false
prevent_idle_sleep = false
'
hasnt '^\s*js_repl'                 "js_repl deleted even when the live file sets it"
has '^\s*memories = true'           "memories forced on even when the live file says false"
```

and replace

```bash
echo "B. js_repl is pinned, not dropped"
# Regression guard. An earlier revision unset the key on the grounds that it was
# obsolete; codex 0.149.1 still ships it, so unsetting it silently removed the guard
# and let an upstream default flip enable a JS REPL. Absent must never be acceptable.
emit ''
has '^\s*js_repl = false' "js_repl emitted even when absent from the input"
```

with

```bash
echo "B. js_repl is deleted, not pinned"
# It was pinned off while Codex shipped it as a live flag (0.149.1). Codex 0.159 removed
# the flag. The template carries every key it does not name, so the old pin has to be
# DELETED from the live file; merely no longer setting it would keep it forever.
emit '[features]
js_repl = false
'
hasnt '^\s*js_repl' "a leftover js_repl pin is deleted from the live file"
emit ''
hasnt '^\s*js_repl' "js_repl is never emitted"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/run.sh codex-config`
Expected: FAIL, 3 failed (the three `js_repl` assertions).

- [ ] **Step 3: Delete the pin**

In `dot_codex/modify_private_config.toml`, replace

```
{{- /*   - keep js_repl explicitly off.                                       */ -}}
```

with

```
{{- /*   - delete the retired js_repl flag.                                   */ -}}
```

replace

```
{{- /* Enforce feature flags. js_repl is NOT obsolete — 0.149.1 still ships it as a
       live flag (alongside code_mode_only / js_repl_tools_only) plus js_repl_node_path
       and js_repl_node_module_dirs. It is off by default today, so unsetting it looked
       harmless, but that also guaranteed an explicit guard could never persist: one
       upstream default flip and Codex gets a JS REPL silently. Pin it off instead. */ -}}
```

with

```
{{- /* Enforce feature flags. */ -}}
```

and replace

```
{{- $config = setValueAtPath "features.js_repl" false $config -}}
```

with

```
{{- /* js_repl was pinned off while Codex shipped it as a live flag; 0.159 removed the
       flag. Deleted rather than merely no longer set: this template carries every key it
       does not name, so the old pin would otherwise sit in the live file forever.     */ -}}
{{- $config = deleteValueAtPath "features.js_repl" $config -}}
```

(`deleteValueAtPath` is a chezmoi template function and a no-op for an absent path; verified on 2.73.)

- [ ] **Step 4: Run it to verify it passes**

Run: `./tests/run.sh codex-config`
Expected: `ok    codex-config  34/34`.

- [ ] **Step 5: Commit the Codex change**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_codex/modify_private_config.toml tests/codex-config.test.sh
git commit -m "Codex: delete the js_repl pin; 0.159 removed the flag"
```

- [ ] **Step 6: Extract the hook herdr embeds**

The spec names herdr 0.9.2; 0.9.3 is installed at plan time, embedding `HERDR_INTEGRATION_VERSION=10` (the vendored copy is 9). Never run `herdr integration install claude`: it rewrites the live `~/.claude/settings.json`. Extract the script from the binary instead:

```bash
/usr/bin/python3 - "$(readlink -f /opt/homebrew/bin/herdr)" > "$TMPDIR/herdr-claude-hook.sh" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
i = data.find(b"# HERDR_INTEGRATION_ID=claude\n")
if i < 0:
    sys.exit("no embedded claude hook in " + sys.argv[1])
start = data.rfind(b"#!/bin/sh\n", 0, i)
end = data.find(b"\nPY\n", i)
sys.stdout.write(data[start:end + 4].decode("utf-8"))
PY
herdr --version
diff dot_claude/hooks/executable_herdr-agent-state.sh "$TMPDIR/herdr-claude-hook.sh"
```

Expected at plan time (herdr 0.9.3): the only difference is line 6, `# HERDR_INTEGRATION_VERSION=9` → `=10`. If the diff shows more, read all of it: the script must still accept only the `session` action, read `SessionStart` from stdin, and use nothing but `HERDR_*` variables and the herdr socket. Check also that the installer's settings shape has not changed (the binary still holds `{"matcher":"*","hooks":[{"type":"command","command":…,"timeout":10}]}` next to `claude settings`): `LC_ALL=C grep -a -c '"timeout":10' "$(readlink -f /opt/homebrew/bin/herdr)"` — expected at least 1. If it changed, stop and report; the settings entry in the modify script mirrors it.

- [ ] **Step 7: Resync and commit**

```bash
cp "$TMPDIR/herdr-claude-hook.sh" dot_claude/hooks/executable_herdr-agent-state.sh
./tests/run.sh claude-settings    # expected: still ok, same count as after Task 6
git branch --show-current         # must print feat/safe-autonomy
git add dot_claude/hooks/executable_herdr-agent-state.sh
git commit -m "Resync the vendored Claude Herdr hook to herdr 0.9.3 (integration version 10)"
```

(The source file keeps mode 644; its `executable_` prefix sets the deployed mode.)

---

### Task 9: Shell history moves to XDG state (sp-mechanical)

**Files:**
- Modify: `dot_config/zsh/config`
- Create: `tests/zsh-config.test.sh` (mode 755)

**Interfaces:** none shared.

Note for the final report: the spec says `$XDG_STATE_HOME` is backed up by Borg. It is not: Vorta's source list (read at plan time from its `settings.db`) is `~/Documents`, `~/Code`, the Obsidian vault, `~/.config`, `~/.claude`, `~/.codex` and `~/.local/share/chezmoi`. The move is still right (history is state, not cache), but for it to be backed up Michael has to add `~/.local/state/zsh` to Vorta by hand. Say so in the report; do not edit Vorta.

- [ ] **Step 1: Write the failing test**

Create `tests/zsh-config.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for dot_config/zsh/config: where shell history lives, and its one-time move.
#
# History is state, not cache: it moved from $XDG_CACHE_HOME/zsh to $XDG_STATE_HOME/zsh
# (spec 2026-09-30, section 4 item 6). The first shell start after the change moves the
# old file across; it must never clobber a history file that already exists at the new
# place, because two shells can start at once.
#
# Sources the SOURCE config in a clean zsh with stub starship/direnv/mise/zoxide on PATH,
# and a temp HOME, so nothing real is read or written.
#
#   ./tests/zsh-config.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SRC/dot_config/zsh/config"
[ -f "$CONFIG" ] || { echo "missing script under test: $CONFIG" >&2; exit 2; }
[ -x /bin/zsh ] || { echo "no /bin/zsh" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/zshconfig.XXXXXX")"
trap 'rm -rf "$T"' EXIT
STUB="$T/stub"; mkdir -p "$STUB"
for tool in starship direnv mise zoxide; do
  printf '#!/bin/sh\nexit 0\n' > "$STUB/$tool"; chmod 755 "$STUB/$tool"
done

start_shell() { # start_shell <home> -> prints $HISTFILE after sourcing the config
  env -i HOME="$1" XDG_CACHE_HOME="$1/.cache" XDG_STATE_HOME="$1/.local/state" \
    PATH="$STUB:/usr/bin:/bin" /bin/zsh -f -c "source \"$CONFIG\"; print -r -- \$HISTFILE" 2>/dev/null
}

H="$T/fresh"; mkdir -p "$H"
is "HISTFILE is under XDG_STATE_HOME" "$(start_shell "$H")" "$H/.local/state/zsh/zsh_history"
is "its directory is created, so zsh can write history" \
   "$([ -d "$H/.local/state/zsh" ] && echo yes || echo no)" yes

H="$T/migrate"; mkdir -p "$H/.cache/zsh"; printf 'old history\n' > "$H/.cache/zsh/zsh_history"
start_shell "$H" >/dev/null
is "the old cache history is moved on first start" "$(cat "$H/.local/state/zsh/zsh_history" 2>/dev/null)" "old history"
is "and is gone from the cache" "$([ -e "$H/.cache/zsh/zsh_history" ] && echo kept || echo gone)" gone
start_shell "$H" >/dev/null
is "a second start leaves the moved history alone" "$(cat "$H/.local/state/zsh/zsh_history" 2>/dev/null)" "old history"

H="$T/both"; mkdir -p "$H/.cache/zsh" "$H/.local/state/zsh"
printf 'old\n' > "$H/.cache/zsh/zsh_history"; printf 'new\n' > "$H/.local/state/zsh/zsh_history"
start_shell "$H" >/dev/null
is "an existing new history is never overwritten" "$(cat "$H/.local/state/zsh/zsh_history")" new
is "and the old file is left for a human to look at" "$(cat "$H/.cache/zsh/zsh_history")" old

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then `chmod 755 tests/zsh-config.test.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/run.sh zsh-config`
Expected: FAIL, 5 failed (every assertion but the two in the "both" block).

- [ ] **Step 3: Move the history**

In `dot_config/zsh/config`, replace

```zsh
# Set location of HISTFILE
HISTFILE="$XDG_CACHE_HOME/zsh/zsh_history"
```

with

```zsh
# History is state, not cache: it lives in $XDG_STATE_HOME. The first shell start after
# the move carries the old $XDG_CACHE_HOME file across, and never overwrites a history
# that already exists at the new place (two shells can start at once).
HISTFILE="$XDG_STATE_HOME/zsh/zsh_history"
[[ -d "${HISTFILE:h}" ]] || mkdir -p "${HISTFILE:h}"
if [[ ! -e "$HISTFILE" && -f "$XDG_CACHE_HOME/zsh/zsh_history" ]]; then
  mv -n "$XDG_CACHE_HOME/zsh/zsh_history" "$HISTFILE" 2>/dev/null
fi
```

- [ ] **Step 4: Run it to verify it passes**

Run: `./tests/run.sh zsh-config`
Expected: `ok    zsh-config  7/7`.

- [ ] **Step 5: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_config/zsh/config tests/zsh-config.test.sh
git commit -m "Keep shell history in XDG state, moving the old cache file once"
```

---

### Task 10: xreview receipts record the checkpoint; the pre-merge gate needs an approval (sp-standard)

**Files:**
- Modify: `dot_local/bin/executable_xreview`, `tests/xreview.test.sh`
- Modify: `dot_claude/executable_xreview-guard.sh`, `tests/xreview-guard.test.sh`
- Modify: `dot_claude/skills/cross-review/SKILL.md`, `tests/xreview-skill.test.sh`

**Interfaces:**
- Produces: `xreview dispatch --checkpoint spec|plan|pre-merge [--diff <range>] <body-file>` (required; refused before anything is touched when missing or unknown). The turn record `$(state_dir)/turns/<nonce>` becomes `<thread> <turn> <checkpoint>` (a two-field record from before still collects). `record_receipt <thread> <nonce> <turn> <findings-json> <checkpoint>` adds `checkpoint` to each `reviews.jsonl` line. The guard allows `glab mr create` / `gh pr create` only when the LATEST receipt on the branch with `checkpoint == "pre-merge"` has `verdict == "approve"`.

Why required rather than defaulted: the receipt is what the gate reads. A review dispatched without its checkpoint would only be found out at MR time, after a ~2M-token review turn was spent; refusing at dispatch costs nothing. Why the latest pre-merge verdict rather than any: a later pre-merge round that came back `changes` overturns an earlier approve. Transition cost: receipts written before this change carry no checkpoint, so a branch already in flight needs one fresh pre-merge dispatch before its MR. HEAD stays unbound (spec §4.7; see the comment above `record_receipt`).

- [ ] **Step 1: Update the xreview suite (failing)**

First, mechanically, name a checkpoint on every existing dispatch in the suite:

```bash
sed -i '' 's/"\$XREVIEW" dispatch /"$XREVIEW" dispatch --checkpoint plan /g' tests/xreview.test.sh
grep -c 'dispatch --checkpoint plan' tests/xreview.test.sh    # expected: 86
```

Then update the turn-record assertions, which now carry a third field:
- replace `"$(cat "$STATE/turns/$nonce")" "$U1 turn-$U1"` with `"$(cat "$STATE/turns/$nonce")" "$U1 turn-$U1 plan"` (1 occurrence, D1)
- replace `"$(cat "$STATE/turns/$nonce")" "$U1 ?"` with `"$(cat "$STATE/turns/$nonce")" "$U1 ? plan"` (2 occurrences, D10 and D16)
- replace `"$(cat "$STATE/turns/$nonce")" "$U1 turn-recovered"` with `"$(cat "$STATE/turns/$nonce")" "$U1 turn-recovered plan"` (1 occurrence)
- replace `"$(cat "$STATE/turns/$nonce" 2>/dev/null)" "$U1 turn-$U1"` with `"$(cat "$STATE/turns/$nonce" 2>/dev/null)" "$U1 turn-$U1 plan"` (3 occurrences: T3, D, T4b)

Replace

```bash
is "F1 the tier is a real value read from the thread's own rollout file" \
   "$(printf '%s' "$r" | jq -r .tier)" "gpt-5.6-sol/xhigh"
```

with

```bash
is "F1 the tier is a real value read from the thread's own rollout file" \
   "$(printf '%s' "$r" | jq -r .tier)" "gpt-5.6-sol/xhigh"
is "F1 the receipt records the checkpoint named at dispatch" "$(printf '%s' "$r" | jq -r .checkpoint)" plan
```

Then (after the sed, so these lines keep their bare form) replace

```bash
echo "F10. the packet temp file never lingers, on the paths the explicit rm covers"
```

with

```bash
echo "F14. every dispatch names its checkpoint, and the receipt carries it"
fresh
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "F14 a dispatch without --checkpoint is refused" "$rc" 1
is "F14 and the usage names the flag" "$(printf '%s' "$out" | grep -c -- '--checkpoint spec|plan|pre-merge')" 1
is "F14 before anything is touched" "$(untouched)" yes
fresh
out="$(bash "$XREVIEW" dispatch --checkpoint merge b.md 2>&1)"; rc=$?
is "F14 an unknown checkpoint is refused" "$rc/$(printf '%s' "$out" | grep -c 'unknown checkpoint: merge')" "1/1"
is "F14 before anything is touched, too" "$(untouched)" yes
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff HEAD~1..HEAD b.md 2>/dev/null)"
is "F14 the turn record carries the checkpoint" "$(cat "$STATE/turns/$nonce")" "$U1 turn-$U1 pre-merge"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "F14 a pre-merge review's receipt says so" \
   "$(tail -1 "$STATE/reviews.jsonl" | jq -r '"\(.checkpoint)/\(.verdict)"')" "pre-merge/approve"
# A turn record written before the checkpoint existed has two fields; collect must still
# work and record an empty checkpoint, which the pre-merge gate never accepts.
printf '%s %s\n' "$U1" "turn-$U1" > "$STATE/turns/xr-1-legacy"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect xr-1-legacy >/dev/null 2>&1; rc=$?
is "F14 a legacy two-field record still collects" "$rc" 0
is "F14 with an empty checkpoint on its receipt" "$(tail -1 "$STATE/reviews.jsonl" | jq -r .checkpoint)" ""

echo "F10. the packet temp file never lingers, on the paths the explicit rm covers"
```

- [ ] **Step 2: Update the guard suite (failing)**

In `tests/xreview-guard.test.sh`, replace

```bash
# ------------------------------------------------------------------------- receipts
mkdir -p "$(dirname "$RECEIPTS")"
printf '{"ts":"t","branch":"other","head":"h","thread":"x","nonce":"n"}\n' > "$RECEIPTS"
is "a receipt for a DIFFERENT branch still denies" "$(decision 'glab mr create')" deny

printf '{"ts":"t","branch":"%s","head":"h","thread":"x","nonce":"n"}\n' "$BRANCH" >> "$RECEIPTS"
is "a receipt for this branch allows"          "$(decision 'glab mr create')" allow
```

with

```bash
# ------------------------------------------------------------------------- receipts
# Only a pre-merge receipt whose LATEST verdict is approve opens the gate (spec
# 2026-09-30, section 4 item 7). receipt <branch> <checkpoint> <verdict> appends one.
receipt() {
  printf '{"ts":"t","branch":"%s","head":"h","thread":"x","nonce":"n","verdict":"%s","checkpoint":"%s"}\n' \
    "$1" "$3" "$2" >> "$RECEIPTS"
}
mkdir -p "$(dirname "$RECEIPTS")"
: > "$RECEIPTS"
receipt other pre-merge approve
is "an approved pre-merge receipt for a DIFFERENT branch still denies" "$(decision 'glab mr create')" deny
: > "$RECEIPTS"
printf '{"ts":"t","branch":"%s","head":"h","thread":"x","nonce":"n"}\n' "$BRANCH" >> "$RECEIPTS"
is "a receipt from before checkpoints existed denies" "$(decision 'glab mr create')" deny
receipt "$BRANCH" spec approve
is "an approved spec review denies"               "$(decision 'glab mr create')" deny
receipt "$BRANCH" plan approve
is "an approved plan review denies"               "$(decision 'gh pr create --fill')" deny
receipt "$BRANCH" pre-merge changes
is "a pre-merge verdict of changes denies"        "$(decision 'glab mr create')" deny
out="$(payload 'glab mr create' | bash "$GUARD" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason')"
is "the deny lists what is on record" \
   "$(printf '%s' "$out" | grep -c 'On record for this branch: unrecorded/, spec/approve, plan/approve, pre-merge/changes')" 1
is "the deny names the dispatch that fixes it" "$(printf '%s' "$out" | grep -c -- '--checkpoint pre-merge')" 1
receipt "$BRANCH" pre-merge approve
is "an approved pre-merge review allows"          "$(decision 'glab mr create')" allow
receipt "$BRANCH" pre-merge changes
is "a later pre-merge verdict of changes closes it again" "$(decision 'glab mr create')" deny
receipt "$BRANCH" pre-merge approve
printf 'not json at all\n' >> "$RECEIPTS"
is "a damaged line does not hide the approval before it" "$(decision 'glab mr create')" allow
```

- [ ] **Step 3: Update the skill and its suite (failing)**

In `tests/xreview-skill.test.sh`, replace

```bash
# A schema miss is its own exit code. The skill must say what to do with it, or the model
```

with

```bash
# The checkpoint is what the pre-merge gate reads. A dispatch example without it teaches
# a call the CLI refuses, and the model follows the skill, not the usage line.
if grep -E '^\s*(NONCE=)?\$?\(?xreview dispatch' "$SKILL" | grep -q -- '--checkpoint'; then
  _pass "the skill's dispatch example names the checkpoint"
else
  _fail "the skill's dispatch example names the checkpoint" "$(grep -E 'xreview dispatch' "$SKILL" | head -1)"
fi
if printf '%s' "$xreview_code" | grep -q -- '--checkpoint)'; then
  _pass "the CLI actually accepts --checkpoint"
else
  _fail "the CLI actually accepts --checkpoint" "no --checkpoint case in the dispatch parser"
fi
for cp in spec plan pre-merge; do
  if grep -q -- "\`$cp\`" "$SKILL" && printf '%s' "$xreview_code" | grep -qE "(^|[|[:space:]])$cp([|)]|$)"; then
    _pass "the skill and the CLI agree on the '$cp' checkpoint"
  else
    _fail "the skill and the CLI agree on the '$cp' checkpoint" "named in one and not the other"
  fi
done
# The gate the skill describes is the gate the guard applies.
if strip_comments "$GUARD" | grep -q 'pre-merge' && strip_comments "$GUARD" | grep -q 'approve' \
   && grep -qi 'latest .pre-merge. receipt has the verdict' "$SKILL"; then
  _pass "the skill and the guard agree: only an approved pre-merge receipt opens the gate"
else
  _fail "the skill and the guard agree: only an approved pre-merge receipt opens the gate" "skill/guard mismatch"
fi

# A schema miss is its own exit code. The skill must say what to do with it, or the model
```

- [ ] **Step 4: Run the three suites to verify they fail**

Run: `./tests/run.sh xreview`
Expected: `xreview` FAILs (every dispatch now passes an option the CLI rejects), `xreview-guard` FAILs (the new receipt cases), `xreview-skill` FAILs (the new checkpoint checks). `xreview-apply-guard` and `xreview-rpc` stay ok.

- [ ] **Step 5: Implement in the CLI**

In `dot_local/bin/executable_xreview`:

(a) Replace

```bash
# The tier is recorded, never enforced: which model and effort the reviewer runs at is
# Michael's setting, and a gate pinned to model names refuses every dispatch the day a new
# one ships.
record_receipt() { # record_receipt <thread> <nonce> <turn> <findings-json>
```

with

```bash
# The tier is recorded, never enforced: which model and effort the reviewer runs at is
# Michael's setting, and a gate pinned to model names refuses every dispatch the day a new
# one ships. The checkpoint (spec, plan or pre-merge, named at dispatch) IS enforced:
# xreview-guard.sh admits an MR only on a pre-merge receipt whose verdict is approve.
record_receipt() { # record_receipt <thread> <nonce> <turn> <findings-json> <checkpoint>
```

(b) Replace

```bash
         --arg verdict "$verdict" --argjson findings "${count:-0}" \
    '{ts:$ts,branch:$branch,head:$head,thread:$thread,nonce:$nonce,tier:$tier,turn:$turn,verdict:$verdict,findings:$findings}' \
```

with

```bash
         --arg verdict "$verdict" --argjson findings "${count:-0}" --arg checkpoint "${5:-}" \
    '{ts:$ts,branch:$branch,head:$head,thread:$thread,nonce:$nonce,tier:$tier,turn:$turn,verdict:$verdict,findings:$findings,checkpoint:$checkpoint}' \
```

(c) Replace

```bash
  local body_file diff_range="" diff_text="" dir pane status thread nonce packet turn="" \
        title_thread title_prefix gen need_resume
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --diff) [ "$#" -ge 2 ] || die "--diff needs a range"; diff_range="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || die "usage: xreview dispatch [--diff <range>] <body-file>"
```

with

```bash
  local body_file diff_range="" diff_text="" dir pane status thread nonce packet turn="" \
        title_thread title_prefix gen need_resume checkpoint=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --diff) [ "$#" -ge 2 ] || die "--diff needs a range"; diff_range="$2"; shift 2 ;;
      --checkpoint) [ "$#" -ge 2 ] || die "--checkpoint needs spec, plan or pre-merge"
                    checkpoint="$2"; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || die "usage: xreview dispatch --checkpoint spec|plan|pre-merge [--diff <range>] <body-file>"
  # Required, not defaulted: the receipt is what the pre-merge gate reads, and a review
  # dispatched without its checkpoint could only be found out at MR time, after the turn
  # was spent. Refused here, before anything is touched.
  case "$checkpoint" in
    spec|plan|pre-merge) ;;
    "") die "usage: xreview dispatch --checkpoint spec|plan|pre-merge [--diff <range>] <body-file>" ;;
    *) die "unknown checkpoint: $checkpoint (spec, plan or pre-merge)" ;;
  esac
```

(d) Replace `    0) printf '%s %s\n' "$thread" "$turn" > "$dir/turns/$nonce"` with `    0) printf '%s %s %s\n' "$thread" "$turn" "$checkpoint" > "$dir/turns/$nonce"`.

(e) Replace `       printf '%s ?\n' "$thread" > "$dir/turns/$nonce"` with `       printf '%s ? %s\n' "$thread" "$checkpoint" > "$dir/turns/$nonce"`.

(f) Replace `  local nonce="${1:-}" budget="${2:-$COLLECT_BUDGET_DEFAULT}" rec thread turn out rc` with `  local nonce="${1:-}" budget="${2:-$COLLECT_BUDGET_DEFAULT}" rec thread turn checkpoint out rc`.

(g) Replace

```bash
  read -r thread turn < "$rec"
```

with

```bash
  # A third field names the checkpoint; a record from before it existed has two.
  read -r thread turn checkpoint < "$rec"
```

(h) Replace `    printf '%s %s\n' "$thread" "$turn" > "$rec"` with `    printf '%s %s%s\n' "$thread" "$turn" "${checkpoint:+ $checkpoint}" > "$rec"`.

(i) Replace `       record_receipt "$thread" "$nonce" "$turn" "$out" ;;` with `       record_receipt "$thread" "$nonce" "$turn" "$out" "$checkpoint" ;;`.

(j) Replace the final usage line

```bash
  *) die "usage: xreview init [id] | thread | receipts [--tiers] | apply <nonce>|--done | round [--reset] | dispatch [--diff <range>] <body-file> | tier [thread] | collect <nonce> [budget]" ;;
```

with

```bash
  *) die "usage: xreview init [id] | thread | receipts [--tiers] | apply <nonce>|--done | round [--reset] | dispatch --checkpoint spec|plan|pre-merge [--diff <range>] <body-file> | tier [thread] | collect <nonce> [budget]" ;;
```

Check: `bash -n dot_local/bin/executable_xreview`.

- [ ] **Step 6: Implement in the guard**

In `dot_claude/executable_xreview-guard.sh`, replace

```bash
# Enforces the one part of the cross-review workflow that prose cannot: that a
# branch is not proposed for merge without Codex having reviewed it at least once.
# The relay itself is automatic, but nothing otherwise guarantees it ran — and a
# skipped review is indistinguishable from one that found nothing.
```

with

```bash
# Enforces the one part of the cross-review workflow that prose cannot: that a
# branch is not proposed for merge without an approving pre-merge Codex review. The
# relay itself is automatic, but nothing otherwise guarantees it ran — and a skipped
# review is indistinguishable from one that found nothing. Since 2026-09-30 a receipt
# names its checkpoint (xreview dispatch --checkpoint): a spec or plan review, or a
# pre-merge review whose latest verdict is `changes`, does not open the gate.
```

and replace

```bash
# No receipts file at all, or none naming this branch.
if [ -r "$receipts" ] &&
   jq -e --arg b "$branch" 'select(.branch == $b)' "$receipts" >/dev/null 2>&1; then
  allow
fi

deny "No Codex cross-review on record for branch '$branch'.

The pre-merge checkpoint requires one review of this branch before it is proposed
for merge. Run the cross-review skill, or dispatch directly:

    xreview dispatch <body-file>   # then: xreview collect <nonce>
```

with

```bash
# The LATEST pre-merge receipt for this branch must approve: an earlier approve that a
# later pre-merge round overturned does not count. Lines are parsed one at a time
# (fromjson?), so one damaged line cannot hide the rest of the file.
latest=""
[ -r "$receipts" ] && latest=$(jq -Rrn --arg b "$branch" '
  [inputs | fromjson? | select(type == "object" and .branch == $b and .checkpoint == "pre-merge")]
  | last | .verdict // ""' "$receipts" 2>/dev/null)
[ "$latest" = approve ] && allow

onrecord=""
[ -r "$receipts" ] && onrecord=$(jq -Rrn --arg b "$branch" '
  [inputs | fromjson? | select(type == "object" and .branch == $b)
   | "\(.checkpoint // "" | if . == "" then "unrecorded" else . end)/\(.verdict // "")"]
  | join(", ")' "$receipts" 2>/dev/null)

deny "No approved pre-merge Codex cross-review on record for branch '$branch'.

On record for this branch: ${onrecord:-nothing}.

A branch is proposed for merge only after a pre-merge review whose latest verdict is
approve. Spec and plan reviews do not count, and a pre-merge verdict of changes means
the findings still need a fix and another round. Run the cross-review skill, or:

    xreview dispatch --checkpoint pre-merge --diff <base>..HEAD <body-file>
    xreview collect <nonce>
```

Check: `bash -n dot_claude/executable_xreview-guard.sh && /bin/bash -n dot_claude/executable_xreview-guard.sh`.

- [ ] **Step 7: Update the skill**

In `dot_claude/skills/cross-review/SKILL.md`, replace

````text
```
NONCE=$(xreview dispatch --diff <base>..<head> <body-file>)
xreview collect "$NONCE" [budget-secs]
```
````

with

````text
```
NONCE=$(xreview dispatch --checkpoint <spec|plan|pre-merge> --diff <base>..<head> <body-file>)
xreview collect "$NONCE" [budget-secs]
```

**Name the checkpoint.** `--checkpoint` is required: `spec` at spec sign-off, `plan` at plan
completion, `pre-merge` before merging. The receipt records it, and the pre-merge gate
below opens only on a `pre-merge` receipt whose latest verdict is `approve`.
````

and replace

```text
`xreview collect` writes a receipt to `$XDG_STATE_HOME/xreview/<repo>/reviews.jsonl`,
and a `PreToolUse` guard denies `glab mr create` / `gh pr create` on a branch with no
receipt. That is the one part of this workflow prose cannot guarantee: a skipped review
is otherwise indistinguishable from one that found nothing.
```

with

```text
`xreview collect` writes a receipt to `$XDG_STATE_HOME/xreview/<repo>/reviews.jsonl`,
naming the checkpoint and the verdict, and a `PreToolUse` guard denies `glab mr create` /
`gh pr create` on a branch unless its latest `pre-merge` receipt has the verdict
`approve`. Spec and plan receipts never open it, and neither does a pre-merge round that
came back `changes`. That is the one part of this workflow prose cannot guarantee: a
skipped review is otherwise indistinguishable from one that found nothing.
```

- [ ] **Step 8: Run the three suites to verify they pass**

Run: `./tests/run.sh xreview`
Expected: all ok — at plan time `xreview 254/254`, `xreview-guard 25/25`, `xreview-skill 59/59`, and `xreview-apply-guard`, `xreview-rpc` unchanged.

- [ ] **Step 9: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_local/bin/executable_xreview tests/xreview.test.sh dot_claude/executable_xreview-guard.sh tests/xreview-guard.test.sh dot_claude/skills/cross-review/SKILL.md tests/xreview-skill.test.sh
git commit -m "xreview: record the checkpoint on every receipt; the MR gate needs an approved pre-merge review"
```

---

### Task 11: The prompt audit hook (sp-mechanical)

**Files:**
- Create: `dot_claude/hooks/executable_prompt-audit.sh` (mode 644 in the repo, like its neighbours)
- Create: `tests/prompt-audit.test.sh` (mode 755)
- Modify: `dot_claude/modify_private_settings.json`, `tests/claude-settings.test.sh`, `.chezmoiignore`

**Interfaces:**
- Consumes (Task 5): `hook_matchers`.
- Produces: `~/.local/state/agent-audit/prompts.jsonl` lines `{ts, session, cwd, tool, subcommand}` (Task 12 does not read it; the +14-day review does).

Verified against the installed Claude Code 2.1.285 binary: the event is `PermissionRequest`, fired on the ask path (when a permission dialog would show). Its payload carries `session_id`, `transcript_path`, `cwd`, `permission_mode`, `agent_id`, `hook_event_name`, `tool_name`, `tool_input`, `permission_suggestions`, and `mcp_server` for MCP tools. A hook that prints nothing leaves the prompt to proceed as usual.

- [ ] **Step 1: Write the failing hook test**

Create `tests/prompt-audit.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for dot_claude/hooks/executable_prompt-audit.sh, the PermissionRequest hook that
# logs each permission prompt for the safe-autonomy evaluation (spec 2026-09-30, section 5).
#
# Pins the two promises the hook makes: it never decides (prints nothing), and it never
# logs a command line, only its first word or two. Fixture secrets are assembled at
# runtime so no committed line looks like one.
#
#   ./tests/prompt-audit.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SRC/dot_claude/hooks/executable_prompt-audit.sh"
[ -f "$HOOK" ] || { echo "missing script under test: $HOOK" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/promptaudit.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state"
LOG="$XDG_STATE_HOME/agent-audit/prompts.jsonl"

# fire <tool> <tool_input json> -> the hook's stdout
fire() {
  jq -cn --arg t "$1" --argjson i "$2" \
    '{hook_event_name:"PermissionRequest",session_id:"sess-1",cwd:"/work/repo",tool_name:$t,tool_input:$i,permission_suggestions:[]}' \
    | bash "$HOOK"
}
bash_cmd() { fire Bash "$(jq -cn --arg c "$1" '{command:$c,description:"d"}')"; }
last() { tail -1 "$LOG" | jq -r "$1"; }

is "it prints nothing: the prompt is never decided" "$(bash_cmd 'git push origin main')" ""
is "the log line carries the session"   "$(last .session)" sess-1
is "and the cwd"                        "$(last .cwd)" /work/repo
is "and the tool"                       "$(last .tool)" Bash
is "a multi-command tool keeps its subcommand" "$(last .subcommand)" "git push"
last '.ts' | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  && _pass "the timestamp is UTC ISO-8601" || _fail "the timestamp is UTC ISO-8601" "$(last .ts)"
is "exactly the five fields" "$(tail -1 "$LOG" | jq -c 'keys')" '["cwd","session","subcommand","tool","ts"]'

word=hunter; secret="${word}2-$RANDOM"
bash_cmd "TOKEN=$secret git push origin main" >/dev/null
is "leading assignments are skipped"    "$(last .subcommand)" "git push"
bash_cmd "echo $secret" >/dev/null
is "any other tool logs its first word only" "$(last .subcommand)" echo
bash_cmd "curl -H \"Authorization: Bearer $secret\" https://example.com" >/dev/null
is "flags are never logged"             "$(last .subcommand)" curl
bash_cmd "op read op://Private/item/$secret" >/dev/null
is "op read is logged as op read"       "$(last .subcommand)" "op read"
if grep -q "$secret" "$LOG"; then _fail "no secret ever reaches the log" "$(grep -c "$secret" "$LOG") lines"
else _pass "no secret ever reaches the log"; fi

fire mcp__claude_ai_Microsoft_365__outlook_send_mail "$(jq -cn --arg b "$secret" '{to:"a@b",body:$b}')" >/dev/null
is "an MCP tool logs the tool name"     "$(last .subcommand)" mcp__claude_ai_Microsoft_365__outlook_send_mail
fire Edit '{"file_path":"/work/repo/x","old_string":"a","new_string":"b"}' >/dev/null
is "any other tool logs no subcommand"  "$(last .subcommand)" ""

lines=$(wc -l < "$LOG" | tr -d ' ')
out=$(printf 'not json' | bash "$HOOK"; echo "rc=$?")
is "a malformed payload fails open and silent" "$out" "rc=0"
is "and appends nothing" "$(wc -l < "$LOG" | tr -d ' ')" "$lines"
out=$(printf '' | bash "$HOOK"; echo "rc=$?")
is "an empty payload fails open and silent" "$out" "rc=0"

mkdir -p "$ROOT/ro/agent-audit"; : > "$ROOT/ro/agent-audit/prompts.jsonl"; chmod 444 "$ROOT/ro/agent-audit/prompts.jsonl"
out=$(XDG_STATE_HOME="$ROOT/ro" bash_cmd 'git push' 2>&1; echo "rc=$?")
is "an unwritable log fails open and silent" "$out" "rc=0"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then `chmod 755 tests/prompt-audit.test.sh`.

In `tests/claude-settings.test.sh`, replace

```bash
echo "X. every wired hook script is actually managed by chezmoi"
```

with

```bash
echo "R. every permission prompt is audited, never decided"
emit '{}'
got=$(hook_matchers PermissionRequest 'bash $HOME/.claude/hooks/prompt-audit.sh')
if [ "$got" = "*" ]; then _pass "the prompt-audit hook runs once, on every tool"; else _fail "the prompt-audit hook runs once, on every tool" "$got"; fi
jq_is '.hooks.PermissionRequest | length' 1 "no other PermissionRequest hook"

echo "X. every wired hook script is actually managed by chezmoi"
```

- [ ] **Step 2: Run both suites to verify they fail**

Run: `./tests/prompt-audit.test.sh; echo "exit=$?"` — expected: `missing script under test: ...`, `exit=2`.
Run: `./tests/run.sh claude-settings` — expected: FAIL, 2 failed (section R).

- [ ] **Step 3: Create the hook**

Create `dot_claude/hooks/executable_prompt-audit.sh`:

```bash
#!/usr/bin/env bash
# PermissionRequest hook: appends one line per permission prompt Michael is shown, to
# ${XDG_STATE_HOME:-~/.local/state}/agent-audit/prompts.jsonl, as
#   {ts, session, cwd, tool, subcommand}
# Approved prompts are invisible in transcripts, so this log is the only prompt count the
# safe-autonomy evaluation has (spec 2026-09-30, section 5).
#
# It NEVER decides: it prints nothing, so the prompt proceeds exactly as it would without
# the hook. It NEVER logs the tool input: a command line can carry a secret. subcommand is
# the first word of a Bash command, skipping leading VAR=value assignments, plus the
# second word only for a known multi-command tool (git push, op read); for an MCP tool it
# is the tool name; for anything else it is empty.
#
# Fails open and silent on every error. Bash 3.2 compatible.
set -uo pipefail

payload=$(cat) || exit 0
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

dir="${XDG_STATE_HOME:-$HOME/.local/state}/agent-audit"
mkdir -p "$dir" 2>/dev/null || exit 0

# Tools whose second word is a subcommand. Any other tool logs its first word only: the
# second word of an arbitrary command (echo, mysql, htpasswd) can be the secret itself.
multi='["git","glab","gh","op","docker","kubectl","helm","az","aws","terraform","brew","mise","chezmoi","basecamp","herdr","xreview","codex","claude","npm","yarn","pnpm","bundle","rails","cargo","go","uv","pip","borg","vorta","tsh","tctl","kubie"]'
line=$(printf '%s' "$payload" | jq -c --argjson multi "$multi" '
  def subcommand:
    [splits("[[:space:]]+") | select(length > 0)]
    | until((length == 0) or (.[0] | test("^[A-Za-z_][A-Za-z0-9_]*=") | not); .[1:])
    | if length == 0 then ""
      elif (.[0] | test("^[A-Za-z0-9_./+-]+$") | not) then "?"
      elif (length > 1) and (.[0] | IN($multi[])) and (.[1] | test("^[a-z][a-z0-9-]*$"))
        then "\(.[0]) \(.[1])"
      else .[0] end;
  (.tool_name // "") as $tool
  | {ts: (now | todate),
     session: (.session_id // ""),
     cwd: (.cwd // ""),
     tool: $tool,
     subcommand: (if $tool == "Bash" then ((.tool_input.command // "") | subcommand)
                  elif ($tool | startswith("mcp__")) then $tool
                  else "" end)}' 2>/dev/null) || exit 0
[ -n "$line" ] || exit 0
printf '%s\n' "$line" 2>/dev/null >> "$dir/prompts.jsonl"
exit 0
```

(`2>/dev/null` sits before `>>` on purpose: redirections apply left to right, so an unwritable log fails silently.)

- [ ] **Step 4: Wire it**

In `dot_claude/modify_private_settings.json`, replace

```
              { "type": "command", "command": "bash $HOME/.claude/path-resolution-guard.sh" }
            ]
          }
        ]
      },
```

with

```
              { "type": "command", "command": "bash $HOME/.claude/path-resolution-guard.sh" }
            ]
          }
        ],
        # Prompt audit (spec 2026-09-30 section 5): appends one JSONL line per permission
        # prompt to ~/.local/state/agent-audit/prompts.jsonl and never decides. Approved
        # prompts leave no trace in transcripts, so this is the only prompt count there is.
        "PermissionRequest": [
          {
            "matcher": "*",
            "hooks": [
              { "type": "command", "command": "bash $HOME/.claude/hooks/prompt-audit.sh" }
            ]
          }
        ]
      },
```

In `.chezmoiignore`, replace

```
!.claude/hooks/herdr-agent-state.sh
```

with

```
!.claude/hooks/herdr-agent-state.sh
!.claude/hooks/prompt-audit.sh
```

- [ ] **Step 5: Run both suites to verify they pass**

Run: `./tests/run.sh prompt-audit` — expected `ok    prompt-audit  18/18`.
Run: `./tests/run.sh claude-settings` — expected `ok    claude-settings  147/147` (plan-time count; section X now also checks `.claude/hooks/prompt-audit.sh` is managed).

- [ ] **Step 6: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add dot_claude/hooks/executable_prompt-audit.sh tests/prompt-audit.test.sh dot_claude/modify_private_settings.json tests/claude-settings.test.sh .chezmoiignore
git commit -m "Audit every permission prompt to a JSONL log, never deciding and never logging input"
```

---

### Task 12: The intervention metrics script (sp-standard)

**Files:**
- Create: `.scripts/measure-interventions.py` (mode 755)
- Create: `tests/measure-interventions.test.sh` (mode 755)

**Interfaces:**
- Produces: `.scripts/measure-interventions.py [--days N] [--projects-dir PATH]`, printing one JSON object: `window_days`, `since`, `sessions`, `human_turns{total,after_first,queued}`, `interrupts`, `denials{<name>:{main,subagent}}` for `path-resolution-guard`, `git-forge-guard`, `push-guard`, `worktree-guard`, `xreview-guard`, `xreview-apply-guard`, `classifier-deny`, `classifier-no-verdict`, `builtin-safety-check`, `user-rejected`; `sandbox_escapes{main,subagent}`; `xreview{dispatches,dispatch_failures,collects,collect_failures,dispatch_failure_rate}`; `autonomous_stretch{n,tool_calls{median,p90},minutes{median,p90}}`. Exit 2 on a usage error.

Scope, from the spec: mechanical metrics only. Whether a human turn was avoidable stays a hand-labelling pass. The denial patterns are anchored at the start of a tool result, so a result that merely quotes a guard message is not counted; they include the new texts from Tasks 1, 2 and 10. An xreview call counts wherever it sits in command position, including inside `$( … )`, which is the form the cross-review skill teaches (`NONCE=$(xreview dispatch …)`). Single-quoted text is removed before matching, since nothing inside single quotes runs (`printf %s 'NONCE=$(xreview dispatch …)'` is not a dispatch).

- [ ] **Step 1: Write the failing test**

Create `tests/measure-interventions.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for .scripts/measure-interventions.py against a tiny synthetic transcript tree.
#
# The fixture is written at runtime with timestamps relative to NOW, so the --days window
# means the same thing on every run. Each entry exists to pin one counting rule: what is
# a genuine human turn and what is not, which tool results are denials, what a sandbox
# escape and an xreview failure look like, and how an autonomous stretch is measured.
#
#   ./tests/measure-interventions.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/.scripts/measure-interventions.py"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/measure.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PROJ="$ROOT/projects/-Users-x-Code-demo"
mkdir -p "$PROJ/sess-a/subagents"

# The system python on purpose: the script must run on what every Mac has.
/usr/bin/python3 - "$PROJ" <<'PY'
import datetime, json, os, sys, time
proj = sys.argv[1]
now = time.time()
t0 = now - 3600
def ts(offset_min):
    return datetime.datetime.fromtimestamp(t0 + offset_min * 60, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
def human(m, text):
    return {"type": "user", "timestamp": ts(m), "origin": {"kind": "human"}, "message": {"role": "user", "content": text}}
def tool_use(tid, name, inp):
    return {"type": "tool_use", "id": tid, "name": name, "input": inp}
def result(tid, text, err=True):
    return {"type": "tool_result", "tool_use_id": tid, "is_error": err, "content": text}
main = [
    # a human turn from 30 days ago: outside the 14-day window, never counted
    {"type": "user", "timestamp": datetime.datetime.fromtimestamp(now - 30 * 86400, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
     "origin": {"kind": "human"}, "message": {"role": "user", "content": "ancient"}},
    human(0, "start the task"),                                      # human turn 1 (the first)
    {"type": "assistant", "timestamp": ts(1), "message": {"role": "assistant", "content": [
        {"type": "text", "text": "working"},
        tool_use("t1", "Bash", {"command": "ls", "dangerouslyDisableSandbox": True}),
        # the form the cross-review skill teaches: the dispatch inside $( ... )
        tool_use("t2", "Bash", {"command": "NONCE=$(xreview dispatch --checkpoint plan --diff a..b b.md)"}),
        tool_use("t3", "Read", {"file_path": "/x"}),
        tool_use("t4", "Bash", {"command": "xreview collect xr-1-abc 60"}),
        tool_use("t5", "Bash", {"command": "rg \"xreview dispatch\" docs/"}),   # a mention, not a call
        # single-quoted, so never executed: the form the skill teaches, printed as text
        tool_use("t6", "Bash", {"command": "printf %s 'NONCE=$(xreview dispatch --checkpoint plan b.md)'"}),
    ]}},
    {"type": "user", "timestamp": ts(2), "message": {"role": "user", "content": [
        result("t1", "ok", err=False),
        result("t2", "Exit code 1\nxreview: the Codex pane is mid-turn"),
        result("t3", "Compound command starting with `cd`.\n\nA compound command..."),
        result("t4", "{\"verdict\":\"approve\",\"findings\":[]}", err=False),
        result("t5", "docs/x.md: xreview dispatch", err=False),
        result("t6", "NONCE=$(xreview dispatch --checkpoint plan b.md)", err=False),
    ]}},
    {"type": "user", "timestamp": ts(3), "message": {"role": "user", "content": [
        result("t9", "Permission for this action was denied by the Claude Code auto mode classifier. Reason: x"),
    ]}},
    # an error that merely QUOTES a guard message is not a denial
    {"type": "user", "timestamp": ts(4), "message": {"role": "user", "content": [
        result("t8", "grep: Compound command starting with `cd` appears in guard.sh"),
    ]}},
    {"type": "attachment", "timestamp": ts(5), "attachment": {                  # human turn 2 (queued)
        "type": "queued_command", "prompt": "also do y", "origin": {"kind": "human"}}},
    {"type": "user", "timestamp": ts(6), "origin": {"kind": "peer", "from": "a1"},  # not human
     "message": {"role": "user", "content": "peer says hi"}},
    {"type": "user", "timestamp": ts(7), "origin": {"kind": "task-notification"},   # not human
     "message": {"role": "user", "content": "<task-notification>done</task-notification>"}},
    {"type": "user", "timestamp": ts(8), "isMeta": True, "origin": {"kind": "human"},  # not human
     "message": {"role": "user", "content": "meta"}},
    {"type": "user", "timestamp": ts(9), "origin": {"kind": "human"},               # an interrupt
     "message": {"role": "user", "content": "[Request interrupted by user]"}},
    human(10, "next step"),                                          # human turn 3
    "this line is not JSON",
]
with open(os.path.join(proj, "sess-a.jsonl"), "w") as fh:
    for e in main:
        fh.write((e if isinstance(e, str) else json.dumps(e)) + "\n")
sub = [
    {"type": "assistant", "timestamp": ts(1), "message": {"role": "assistant", "content": [
        tool_use("s1", "Bash", {"command": "rg foo .", "dangerouslyDisableSandbox": True})]}},
    {"type": "user", "timestamp": ts(2), "message": {"role": "user", "content": [
        result("s1", "Recursive search rooted at `.`.")]}},
    # a subagent prompt with a human origin is still not one of Michael's turns
    human(3, "subagent brief"),
]
with open(os.path.join(proj, "sess-a", "subagents", "agent-1.jsonl"), "w") as fh:
    for e in sub:
        fh.write(json.dumps(e) + "\n")
# a whole session last touched 30 days ago
old = os.path.join(proj, "sess-old.jsonl")
with open(old, "w") as fh:
    fh.write(json.dumps(human(0, "recent-looking but the file is old")) + "\n")
os.utime(old, (now - 30 * 86400, now - 30 * 86400))
PY

OUT="$(/usr/bin/python3 "$SCRIPT" --days 14 --projects-dir "$ROOT/projects" 2>&1)"; rc=$?
is() { # is <jq filter> <expected> <label>
  local got; got="$(printf '%s' "$OUT" | jq -r "$1" 2>&1)"
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$got"; fi
}
[ "$rc" -eq 0 ] && _pass "runs on the system python and exits 0" || _fail "runs on the system python and exits 0" "rc=$rc: $OUT"
is '.sessions'                        1   "only sessions active in the window count"
is '.human_turns.total'               3   "human turns: typed, queued and typed again"
is '.human_turns.after_first'         2   "the first turn of a session is not an intervention"
is '.human_turns.queued'              1   "a queued_command with a human origin is a human turn"
is '.interrupts'                      1   "an interrupt is counted apart, never as a turn"
is '.sandbox_escapes.main'            1   "a main-session sandbox escape"
is '.sandbox_escapes.subagent'        1   "a subagent sandbox escape"
is '.xreview.dispatches'              1   "an xreview dispatch inside \$( ); a quoted or single-quoted mention is not one"
is '.xreview.dispatch_failures'       1   "an xreview dispatch that failed"
is '.xreview.collects'                1   "an xreview collect"
is '.xreview.collect_failures'        0   "a collect that succeeded is no failure"
is '.xreview.dispatch_failure_rate == 1' true "the dispatch failure rate"
is '.denials["path-resolution-guard"].main'     1 "a guard denial, main session"
is '.denials["path-resolution-guard"].subagent' 1 "a guard denial, subagent"
is '.denials["classifier-deny"].main' 1   "a classifier denial"
is '[.denials[][]] | add'             3   "a quoted guard message is not a denial"
is '.autonomous_stretch.n'            1   "one stretch closed by a turn the agent waited for"
is '.autonomous_stretch.tool_calls.median == 6' true "the stretch counts every tool call since the last turn"
is '.autonomous_stretch.minutes.median == 4' true "the stretch runs to the last agent activity"

out="$(/usr/bin/python3 "$SCRIPT" --days 0 --projects-dir "$ROOT/projects" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && _pass "--days 0 is a usage error" || _fail "--days 0 is a usage error" "rc=$rc"
out="$(/usr/bin/python3 "$SCRIPT" --projects-dir "$ROOT/nope" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && _pass "a missing projects dir is a usage error" || _fail "a missing projects dir is a usage error" "rc=$rc"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then `chmod 755 tests/measure-interventions.test.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/measure-interventions.test.sh; echo "exit=$?"`
Expected: `missing script under test: ...`, `exit=2`.

- [ ] **Step 3: Write the script**

Create `.scripts/measure-interventions.py`:

```python
#!/usr/bin/env python3
"""Mechanical intervention metrics from Claude Code transcripts.

The safe-autonomy evaluation (docs/superpowers/specs/2026-09-30-safe-autonomy-design.md,
section 5) compares these against the 2026-09-16..30 baseline. Only what a transcript
records mechanically is counted here; whether a human turn was AVOIDABLE stays a
hand-labelling pass.

    .scripts/measure-interventions.py [--days 14] [--projects-dir ~/.claude/projects]

Prints one JSON object. Streams every file line by line and keeps only per-file state,
so a month of transcripts never has to fit in memory. Standard library only.

Transcript shape (observed 2026-09-30, Claude Code 2.1.285):
  <projects-dir>/<project>/<session>.jsonl                  a main session
  <projects-dir>/<project>/<session>/subagents/<agent>.jsonl a subagent of it
  a genuine human turn is either a `user` entry whose origin.kind is "human" (tool
  results, peer messages and task notifications carry other origins or none), or an
  `attachment` entry of type queued_command whose origin.kind is "human" (typed while
  the agent was working).
"""
import argparse
import datetime
import json
import os
import re
import sys

DENIALS = [
    ("path-resolution-guard", r"Compound command starting with `cd`|Recursive search rooted at"),
    ("git-forge-guard", r"This repo ships an MR/PR template|Agent attribution is not allowed"),
    ("push-guard", r"Push guard|unsupported push configuration for the push guard"),
    ("worktree-guard", r"Raw `git worktree remove`"),
    ("xreview-guard", r"No (approved pre-merge )?Codex cross-review on record"),
    ("xreview-apply-guard", r"Outside the cross-review apply window"),
    ("classifier-deny", r"Permission for this action was denied by the Claude Code auto mode"),
    ("classifier-no-verdict", r"The server-side auto mode classifier gave no verdict"),
    ("builtin-safety-check", r"Permission for this command was denied by a built-in"),
    ("user-rejected", r"The user doesn't want to proceed"),
]
# Anchored at the start of the tool result, after an optional hook-error prefix, so a
# result that merely QUOTES a guard message (a cat of the guard, a grep) is not a denial.
DENIAL_RES = [(name, re.compile(r"^(?:PreToolUse:\w+ hook error: )?(?:" + pat + ")"))
              for name, pat in DENIALS]
# xreview in command position: at the start, after an operator, or inside $( ... ), which
# is how the cross-review skill writes it (NONCE=$(xreview dispatch ...)). A quoted mention
# (rg "xreview dispatch") is not a call, and single-quoted text is removed first: nothing
# inside single quotes executes (printf %s 'NONCE=$(xreview dispatch ...)').
SINGLE_QUOTED = re.compile(r"'[^']*'")
XREVIEW_RE = re.compile(r"(?:^|[;&|(\n]|\$\()\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:command\s+)?(?:\S*/)?xreview\s+(dispatch|collect)\b")
INTERRUPT = "[Request interrupted by user"


def parse_ts(value):
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") if isinstance(b, dict) else str(b) for b in content)
    return ""


def is_human(entry):
    kind = entry.get("type")
    if kind == "user":
        if (entry.get("origin") or {}).get("kind") != "human" or entry.get("isMeta"):
            return False
        content = (entry.get("message") or {}).get("content")
        if isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return False
        return not text_of(content).startswith(INTERRUPT)
    if kind == "attachment":
        att = entry.get("attachment") or {}
        return att.get("type") == "queued_command" and (att.get("origin") or {}).get("kind") == "human"
    return False


def is_interrupt(entry):
    if entry.get("type") != "user":
        return False
    content = (entry.get("message") or {}).get("content")
    return text_of(content).startswith(INTERRUPT)


def percentile(values, p):
    if not values:
        return None
    xs = sorted(values)
    k = (len(xs) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo), 2)


class Totals:
    def __init__(self):
        self.sessions = 0
        self.human_total = 0
        self.human_after_first = 0
        self.human_queued = 0
        self.interrupts = 0
        self.denials = {name: {"main": 0, "subagent": 0} for name, _ in DENIALS}
        self.escapes = {"main": 0, "subagent": 0}
        self.xreview = {"dispatches": 0, "dispatch_failures": 0, "collects": 0, "collect_failures": 0}
        self.stretch_tools = []
        self.stretch_minutes = []


def scan_file(path, scope, cutoff, totals):
    """One transcript. Returns True when it had any entry inside the window."""
    pending_xreview = {}            # tool_use id -> the xreview verbs that call ran
    seen = False
    humans = 0
    tools_since_human = 0
    last_human_ts = None
    last_agent_ts = None
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return False
    with fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            ts = parse_ts(entry.get("timestamp"))
            if ts is None or ts < cutoff:
                continue
            seen = True
            kind = entry.get("type")
            if kind == "assistant":
                last_agent_ts = ts
                for block in (entry.get("message") or {}).get("content") or []:
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    tools_since_human += 1
                    inp = block.get("input") or {}
                    if block.get("name") != "Bash" or not isinstance(inp, dict):
                        continue
                    if inp.get("dangerouslyDisableSandbox"):
                        totals.escapes[scope] += 1
                    command = SINGLE_QUOTED.sub("''", inp.get("command") or "").strip()
                    verbs = set(XREVIEW_RE.findall(command))
                    for verb in verbs:
                        totals.xreview["dispatches" if verb == "dispatch" else "collects"] += 1
                    if verbs:
                        pending_xreview[block.get("id")] = verbs
                continue
            if kind == "user":
                content = (entry.get("message") or {}).get("content")
                if isinstance(content, list) and any(
                        isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
                    last_agent_ts = ts
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_result":
                            continue
                        verbs = pending_xreview.pop(block.get("tool_use_id"), ())
                        if block.get("is_error"):
                            for verb in verbs:
                                key = "dispatch_failures" if verb == "dispatch" else "collect_failures"
                                totals.xreview[key] += 1
                            text = text_of(block.get("content"))
                            for name, rx in DENIAL_RES:
                                if rx.match(text):
                                    totals.denials[name][scope] += 1
                                    break
                    continue
                if is_interrupt(entry):
                    if scope == "main":
                        totals.interrupts += 1
                    continue
            if scope == "main" and is_human(entry):
                totals.human_total += 1
                queued = kind == "attachment"
                if queued:
                    totals.human_queued += 1
                if humans > 0:
                    totals.human_after_first += 1
                    # The stretch a typed-ahead (queued) message interrupts is not over, so
                    # only a turn the agent actually waited for closes one.
                    if not queued and last_human_ts is not None:
                        totals.stretch_tools.append(tools_since_human)
                        end = last_agent_ts if last_agent_ts and last_agent_ts >= last_human_ts else last_human_ts
                        totals.stretch_minutes.append((end - last_human_ts) / 60.0)
                humans += 1
                if not queued:
                    tools_since_human = 0
                    last_human_ts = ts
    return seen


def measure(projects_dir, days, now=None):
    now = now if now is not None else datetime.datetime.now(datetime.timezone.utc).timestamp()
    cutoff = now - days * 86400
    totals = Totals()
    for project in sorted(os.listdir(projects_dir)):
        pdir = os.path.join(projects_dir, project)
        if not os.path.isdir(pdir):
            continue
        for name in sorted(os.listdir(pdir)):
            path = os.path.join(pdir, name)
            if not name.endswith(".jsonl") or not os.path.isfile(path):
                continue
            if os.path.getmtime(path) < cutoff:
                continue
            if scan_file(path, "main", cutoff, totals):
                totals.sessions += 1
            subdir = os.path.join(pdir, name[:-len(".jsonl")], "subagents")
            if os.path.isdir(subdir):
                for sub in sorted(os.listdir(subdir)):
                    spath = os.path.join(subdir, sub)
                    if sub.endswith(".jsonl") and os.path.getmtime(spath) >= cutoff:
                        scan_file(spath, "subagent", cutoff, totals)
    x = totals.xreview
    return {
        "window_days": days,
        "since": datetime.datetime.fromtimestamp(cutoff, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sessions": totals.sessions,
        "human_turns": {"total": totals.human_total, "after_first": totals.human_after_first,
                        "queued": totals.human_queued},
        "interrupts": totals.interrupts,
        "denials": totals.denials,
        "sandbox_escapes": totals.escapes,
        "xreview": dict(x, dispatch_failure_rate=(
            round(x["dispatch_failures"] / x["dispatches"], 3) if x["dispatches"] else None)),
        "autonomous_stretch": {
            "n": len(totals.stretch_tools),
            "tool_calls": {"median": percentile(totals.stretch_tools, 0.5),
                           "p90": percentile(totals.stretch_tools, 0.9)},
            "minutes": {"median": percentile(totals.stretch_minutes, 0.5),
                        "p90": percentile(totals.stretch_minutes, 0.9)},
        },
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--days", type=int, default=14, help="window size in days (default 14)")
    ap.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"),
                    help="Claude Code transcript root (default ~/.claude/projects)")
    args = ap.parse_args(argv)
    if args.days <= 0:
        ap.error("--days must be positive")
    if not os.path.isdir(args.projects_dir):
        ap.error("no such directory: " + args.projects_dir)
    json.dump(measure(args.projects_dir, args.days), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Then `chmod 755 .scripts/measure-interventions.py`.

- [ ] **Step 4: Run it to verify it passes**

Run: `./tests/run.sh measure-interventions`
Expected: `ok    measure-interventions  22/22`.

- [ ] **Step 5: Sanity-check against the real transcripts**

Run: `/usr/bin/python3 .scripts/measure-interventions.py --days 14 | jq -c '{sessions, human_turns, interrupts, sandbox_escapes, xreview, stretch: .autonomous_stretch, pr: .denials["path-resolution-guard"]}'`
Expected: the same order of magnitude as the spec's baseline (41 sessions, ~490 human turns after the first, ~917 escapes, ~11% dispatch failures, ~89 path-resolution denials). At plan time it read 41 sessions, 499 after-first turns, 931 escapes (611 main + 320 subagent), 283 dispatches with a 12.4% failure rate (the baseline's own count missed dispatches inside `$( )` and after `&&`), and 102 path-resolution denials; the window slides daily. A figure an order of magnitude off means a counting rule is wrong: stop and find which. It reads `~/.claude/projects` only; it writes nothing. Put the full JSON in your report: it is the pre-change baseline measured with the same instrument the +14-day review will use, and those transcripts age out.

- [ ] **Step 6: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add .scripts/measure-interventions.py tests/measure-interventions.test.sh
git commit -m "Add the mechanical intervention metrics script for the safe-autonomy evaluation"
```

---

### Task 13: Instruction fragments replace the 1Password render (sp-mechanical)

**Files:**
- Create: `.chezmoitemplates/agents/global.md`, `.chezmoitemplates/agents/claude.md`
- Modify: `dot_config/agents/GLOBAL.md.tmpl`, `dot_codex/AGENTS.md.tmpl`, `dot_claude/CLAUDE.md.tmpl`
- Create: `tests/agent-instructions.test.sh` (mode 755)

**Interfaces:**
- Consumes: the lead's fragment drafts (content is not this task's to change).
- Produces: `claude.md` opens with the heading `## Claude Code only`; the render test pins it.

- [ ] **Step 1: Write the failing render test**

Create `tests/agent-instructions.test.sh`:

```bash
#!/usr/bin/env bash
# Renders the three agent-instruction targets from the chezmoi source and checks what each
# one carries (spec 2026-09-30, section 3).
#
#   dot_config/agents/GLOBAL.md.tmpl  -> the shared fragment
#   dot_codex/AGENTS.md.tmpl          -> the shared fragment
#   dot_claude/CLAUDE.md.tmpl         -> the shared fragment, then the Claude addendum
#
# Both fragments live in .chezmoitemplates/agents/, which chezmoi never deploys. This repo
# is PUBLIC and the fragments are plain tracked text: no template actions, no 1Password.
#
#   ./tests/agent-instructions.test.sh   (sandboxed is fine; needs no op)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
FRAG="$SRC/.chezmoitemplates/agents"
GLOBAL_T=dot_config/agents/GLOBAL.md.tmpl
CODEX_T=dot_codex/AGENTS.md.tmpl
CLAUDE_T=dot_claude/CLAUDE.md.tmpl
for f in "$FRAG/global.md" "$FRAG/claude.md" "$SRC/$GLOBAL_T" "$SRC/$CODEX_T" "$SRC/$CLAUDE_T"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
command -v chezmoi >/dev/null 2>&1 || { echo "chezmoi not on PATH" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

# The heading claude.md opens with. Only the Claude target may carry it.
MARKER='## Claude Code only'
T="$(mktemp -d "${TMPDIR:-/tmp}/agentinstr.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# --config /dev/null: render from this source alone, never from Michael's chezmoi config.
render() { # render <template, relative to the source> <out-file>
  chezmoi --config /dev/null --config-format toml --source "$SRC" --destination "$HOME" \
    execute-template --file "$SRC/$1" > "$2" 2>"$T/err"
}

first_line=$(head -1 "$FRAG/global.md")
for t in "$GLOBAL_T" "$CODEX_T" "$CLAUDE_T"; do
  out="$T/$(basename "$t")"
  if render "$t" "$out" && [ -s "$out" ]; then
    _pass "$t renders"
  else
    _fail "$t renders" "$(cat "$T/err")"
  fi
  if grep -qxF -- "$first_line" "$out"; then
    _pass "$t carries the shared fragment"
  else
    _fail "$t carries the shared fragment" "first line '$first_line' not found"
  fi
  if grep -q 'onepasswordRead' "$SRC/$t"; then
    _fail "$t no longer reads 1Password" "$(grep -n onepasswordRead "$SRC/$t")"
  else
    _pass "$t no longer reads 1Password"
  fi
done

for t in "$GLOBAL_T" "$CODEX_T"; do
  if grep -qF -- "$MARKER" "$T/$(basename "$t")"; then
    _fail "$t carries no Claude-only section" "found '$MARKER'"
  else
    _pass "$t carries no Claude-only section"
  fi
done
claude_out="$T/$(basename "$CLAUDE_T")"
marker_at=$(grep -nxF -- "$MARKER" "$claude_out" | head -1 | cut -d: -f1)
shared_at=$(grep -nxF -- "$first_line" "$claude_out" | head -1 | cut -d: -f1)
if [ -n "$marker_at" ] && [ -n "$shared_at" ] && [ "$shared_at" -lt "$marker_at" ]; then
  _pass "the Claude target is the shared fragment, then the Claude addendum"
else
  _fail "the Claude target is the shared fragment, then the Claude addendum" "shared at '$shared_at', marker at '$marker_at'"
fi

is_first() { [ "$(head -1 "$1")" = "$2" ]; }
is_first "$FRAG/claude.md" "$MARKER" && _pass "claude.md opens with '$MARKER'" \
  || _fail "claude.md opens with '$MARKER'" "$(head -1 "$FRAG/claude.md")"
grep -qF -- "$MARKER" "$FRAG/global.md" && _fail "global.md holds no Claude-only heading" "found it" \
  || _pass "global.md holds no Claude-only heading"

lines=$(wc -l < "$FRAG/global.md" | tr -d ' ')
[ "$lines" -le 180 ] && _pass "global.md is at most 180 lines ($lines)" || _fail "global.md is at most 180 lines" "$lines"
lines=$(wc -l < "$FRAG/claude.md" | tr -d ' ')
[ "$lines" -le 50 ] && _pass "claude.md is at most 50 lines ($lines)" || _fail "claude.md is at most 50 lines" "$lines"

# A template action inside a fragment would run at apply time, with this machine's data,
# in a file the repo publishes. The fragments are plain text.
for f in global.md claude.md; do
  if grep -q '{{' "$FRAG/$f"; then _fail "$f contains no template action" "$(grep -n '{{' "$FRAG/$f" | head -3)"
  else _pass "$f contains no template action"; fi
done

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

Then `chmod 755 tests/agent-instructions.test.sh`.

- [ ] **Step 2: Run it to verify it fails**

Run: `./tests/agent-instructions.test.sh; echo "exit=$?"`
Expected: `missing file under test: .../.chezmoitemplates/agents/global.md`, `exit=2`.

- [ ] **Step 3: Create the fragments and the three targets**

Create the two fragment files with the exact content from the lead's drafts at `/private/tmp/claude-501/-Users-michael--local-share-chezmoi/61529705-077b-46f9-bb7e-09bffaeac5aa/scratchpad/fragments/global.md` and `claude.md`:

```bash
mkdir -p .chezmoitemplates/agents
cp /private/tmp/claude-501/-Users-michael--local-share-chezmoi/61529705-077b-46f9-bb7e-09bffaeac5aa/scratchpad/fragments/global.md .chezmoitemplates/agents/global.md
cp /private/tmp/claude-501/-Users-michael--local-share-chezmoi/61529705-077b-46f9-bb7e-09bffaeac5aa/scratchpad/fragments/claude.md .chezmoitemplates/agents/claude.md
```

If the drafts are missing, stop and ask the lead; never write the content yourself. Read both files in full before going on: they are published in a public repository.

Replace the whole content of `dot_config/agents/GLOBAL.md.tmpl` with:

```
{{ template "agents/global.md" . }}
```

Replace the whole content of `dot_codex/AGENTS.md.tmpl` with:

```
{{ template "agents/global.md" . }}
```

Replace the whole content of `dot_claude/CLAUDE.md.tmpl` with:

```
{{ template "agents/global.md" . }}

{{ template "agents/claude.md" . }}
```

`.chezmoitemplates` is already listed in `.chezmoiignore`, and chezmoi never deploys it.

- [ ] **Step 4: Run it to verify it passes; scan the fragments**

Run: `./tests/run.sh agent-instructions` — expected `ok    agent-instructions  18/18`.
Run: `gitleaks dir --no-banner --no-color --redact .chezmoitemplates; echo "rc=$?"` — expected `no leaks found`, `rc=0`.
Run: `chezmoi --source "$PWD" managed | grep -c chezmoitemplates` — expected `0`.

- [ ] **Step 5: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add .chezmoitemplates/agents/global.md .chezmoitemplates/agents/claude.md dot_config/agents/GLOBAL.md.tmpl dot_codex/AGENTS.md.tmpl dot_claude/CLAUDE.md.tmpl tests/agent-instructions.test.sh
git commit -m "Render the global agent instructions from tracked fragments, not 1Password"
```

---

### Task 14: Repository instructions, subagent definitions, skill policy (sp-mechanical)

**Files:**
- Modify: `AGENTS.md`
- Modify: `dot_claude/agents/sp-architect.md`, `sp-mechanical.md`, `sp-reviewer.md`, `sp-standard.md`
- Modify: `tests/claude-settings.test.sh` (agent-definition block)
- Modify: `dot_claude/skills/cross-review/SKILL.md`, `tests/xreview-skill.test.sh`

**Interfaces:** none new.

Why the SKILL.md policy edit is here: spec §2 policy 6 lets the agent rule on trade-offs inside the approved spec, but the cross-review skill still sends every trade-off to Michael. Left alone, the skill and the global instructions contradict each other at every review. The edit is the minimum that removes the contradiction; the exhaustive escalation list keeps every entry the skill test pins.

- [ ] **Step 1: Write the failing tests**

In `tests/claude-settings.test.sh`, replace

```bash
  # The prompt-side half of the path-resolution guard. GLOBAL.md carries this rule, but
  # a subagent reaching for `cd` in a repo other than the session's showed it does not
  # reliably arrive — and its own definition is the one prompt it certainly reads.
  # Without this, path-resolution-guard.sh still stops the interruption, but every
  # subagent pays a denied call to learn the rule it should have started with.
  if grep -q 'Never open a Bash command with `cd`' "$agent"; then
    _pass "$stem carries the no-leading-cd rule"
  else
    _fail "$stem carries the no-leading-cd rule" "rule missing — every dispatch relearns it via a denied call"
  fi
```

with

```bash
  # The cd/grep bullet is deliberately NOT restated here any more (spec 2026-09-30,
  # section 3.3): the Bash tool description carries the cd rule, ~/.claude/CLAUDE.md the
  # recursive-grep trap, and path-resolution-guard.sh enforces both. A copy here is one
  # more place to keep in step.
  if grep -q 'Never open a Bash command with `cd`' "$agent"; then
    _fail "$stem does not restate the cd/grep rule" "the bullet is back"
  else
    _pass "$stem does not restate the cd/grep rule"
  fi
```

In `tests/xreview-skill.test.sh`, replace

```bash
# The escalation list must actually be exhaustive: refusals only Michael can resolve
```

with

```bash
# Policy 6 (spec 2026-09-30): a trade-off inside the approved spec is the agent's to rule
# on and record under "Rulings" in the MR; only what would change the spec goes to Michael.
if grep -q 'Rulings' "$SKILL" && grep -qi 'would change the approved spec' "$SKILL"; then
  _pass "the skill routes in-spec trade-offs to a recorded ruling"
else
  _fail "the skill routes in-spec trade-offs to a recorded ruling" "every trade-off still goes to Michael"
fi

# The escalation list must actually be exhaustive: refusals only Michael can resolve
```

- [ ] **Step 2: Run them to verify they fail**

Run: `./tests/run.sh claude-settings` — expected FAIL, 4 failed ("sp-* does not restate the cd/grep rule").
Run: `./tests/run.sh xreview-skill` — expected FAIL, 1 failed.

- [ ] **Step 3: Drop the bullet from the four agent definitions**

In each of `dot_claude/agents/sp-architect.md`, `sp-mechanical.md`, `sp-reviewer.md` and `sp-standard.md`, delete these five lines (identical in all four):

```
- Never open a Bash command with `cd`, and never hand a recursive `grep`/`rg` a bare
  `.`. Both leave paths the permission analyser cannot resolve, so it interrupts
  Michael for approval every time. Use absolute paths and name the directories to
  search; if a command truly needs a working directory, send `cd /abs/dir` as its own
  call first — the cwd persists between calls.
```

Keep the trailing newline at the end of each file.

- [ ] **Step 4: Align the skill with policy 6**

In `dot_claude/skills/cross-review/SKILL.md`, replace

```text
- **Verified, and no trade-off involved** — fix it, and say that you did.
- **Design judgement, or a trade-off** — Michael decides. This is most spec and plan
  findings.
- **You disagree, or cannot verify it** — Michael decides.
```

with

```text
- **Verified, and no trade-off involved** — fix it, and say that you did.
- **A trade-off inside the approved spec** — rule on it yourself, and record the ruling
  under "Rulings" in the MR description.
- **Anything that would change the approved spec** — Michael decides. At spec sign-off
  that is most findings.
- **You disagree, or cannot verify it** — Michael decides.
```

and replace

```text
- a finding needs design judgement or a trade-off
```

with

```text
- a finding needs design judgement or a trade-off that would change the approved spec
```

- [ ] **Step 5: Update AGENTS.md**

(a) Replace

```text
- The global agent instructions (`~/.config/agents/GLOBAL.md`, `~/.claude/CLAUDE.md`,
  `~/.codex/AGENTS.md`) render from the 1Password item *Agent instructions*. Edit the
  note, then `chezmoi apply`.
```

with

```text
- The global agent instructions are tracked fragments in `.chezmoitemplates/agents/`.
  `global.md` (shared, tool-agnostic) renders into all three targets
  (`~/.config/agents/GLOBAL.md`, `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`);
  `claude.md` (Claude Code only, opening with `## Claude Code only`) is appended to
  `~/.claude/CLAUDE.md` alone. Edit a fragment, then `chezmoi apply`. This repo is
  public: nothing private goes in them. `global.md` stays within 180 lines and
  `claude.md` within 50; `tests/agent-instructions.test.sh` pins both, and the render.
- This checkout is shared: other sessions switch branches in it, and uncommitted work
  follows the switch. Re-check `git branch --show-current` right before each commit.
  Work here on a branch, not in a harness worktree: xreview needs the repository's own
  Codex pane.
```

(b) Replace

```text
- `.scripts/` are ad-hoc helpers (`provision.sh`, `configure.sh`,
  `reconcile-agents.sh`, `preflight-ssh-agent.sh`), deliberately not `run_once_`
  scripts: they change system settings and need interaction. Mode `755` — git stores
  only the exec bit, so a clone yields 755, never 700.
```

with

```text
- `.scripts/` are ad-hoc helpers (`provision.sh`, `configure.sh`,
  `reconcile-agents.sh`, `preflight-ssh-agent.sh`), deliberately not `run_once_`
  scripts: they change system settings and need interaction. `measure-interventions.py`
  sits beside them: the transcript metrics for the safe-autonomy evaluation. Mode `755`
  — git stores only the exec bit, so a clone yields 755, never 700.
```

(c) Replace

```text
- `~/.local/bin/codex` is a launcher that shadows Homebrew's `codex`: interactive starts
  attach to the launchd-started daemon or refuse (`--no-daemon` is the escape). Anything
  needing the real binary uses `codex-daemon real-bin`, never `command -v codex`.
```

with

```text
- `~/.local/bin/codex` is a launcher that shadows Homebrew's `codex`, because `zshenv`
  puts `~/.local/bin` in front of Homebrew after `brew shellenv` (which prepends);
  `tests/zshenv.test.sh` pins the order. Interactive starts attach to the
  launchd-started daemon or refuse (`--no-daemon` is the escape). Anything needing the
  real binary uses `codex-daemon real-bin`, never `command -v codex`.
```

(d) In the Layout block, replace

```text
.chezmoiignore            # what never reaches $HOME (see Rules)
```

with

```text
.chezmoiignore            # what never reaches $HOME (see Rules)
.chezmoitemplates/agents/ # the agent instruction fragments: global.md, claude.md (never deployed)
```

(e) Replace

```text
**`HERDR_SESSION` is a layout.sh convention, not a herdr one.** herdr 0.8.2 selects a
session only via `--session`; there is no environment variable. `layout.sh`, `tab-goto.sh`
and `phase.sh` each thread it in themselves, and nothing in them may call `command herdr`
bare — a bare call silently targets the *default* session. That is what made
`dev-topology`'s isolation a fiction: it built its fixtures into the live session and then
asserted against an empty `dev-test`. `layout.sh` also starts a server whenever
`HERDR_SESSION` is set, even inside a Herdr pane, because the pane you are in belongs to a
different session than the one you named.
```

with

```text
**Inside a Herdr pane, `HERDR_SESSION` does not pick the session.** herdr 0.9.3 reads
`HERDR_SESSION`, but `HERDR_SOCKET_PATH`, which herdr exports into every pane, outranks it;
only `--session` outranks the socket (measured 2026-09-30 with `herdr status`). So
`layout.sh`, `tab-goto.sh` and `phase.sh` thread `--session` in themselves, and nothing in
them may call `command herdr` bare — from inside a pane a bare call targets the pane's own
session, whatever `HERDR_SESSION` says. That is what made `dev-topology`'s isolation a
fiction: it built its fixtures into the live session and then asserted against an empty
`dev-test`. `layout.sh` also starts a server whenever `HERDR_SESSION` is set, even inside a
Herdr pane, because the pane you are in belongs to a different session than the one you
named.
```

(f) Delete the restated design-records section at the end of the file — these lines and the blank line before them:

```text
## Design Records

Specs and plans are committed under `docs/superpowers/specs/` and `docs/superpowers/plans/`.
Execution state (`.superpowers/`, `docs/superpowers/runs/`) is never tracked.
```

The file must still end with a single newline (after the Troubleshooting section).

- [ ] **Step 6: Run the suites to verify they pass**

Run: `./tests/run.sh claude-settings` — expected `ok    claude-settings  147/147`.
Run: `./tests/run.sh xreview-skill` — expected `ok    xreview-skill  60/60`.

- [ ] **Step 7: Commit**

```bash
git branch --show-current   # must print feat/safe-autonomy
git add AGENTS.md dot_claude/agents/sp-architect.md dot_claude/agents/sp-mechanical.md dot_claude/agents/sp-reviewer.md dot_claude/agents/sp-standard.md tests/claude-settings.test.sh dot_claude/skills/cross-review/SKILL.md tests/xreview-skill.test.sh
git commit -m "Document the fragment layout and shared checkout; drop the restated cd rule; let in-spec trade-offs be ruled"
```

---

### Task 15: Whole-branch verification (sp-standard)

**Files:** none, unless a check fails (then fix it in the task that owns the file, as a new commit).

- [ ] **Step 1: Every sandboxed suite**

Run: `./tests/run.sh`
Expected: `NOT OK` absent; every suite `ok`; the gated suites listed as `skip`. Record each suite's `passed/total` for the report (never a bare "N green").

- [ ] **Step 2: No secret on the branch**

```bash
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=format.pretty GIT_CONFIG_VALUE_0=medium \
  gitleaks git --no-banner --no-color --redact --ignore-gitleaks-allow --log-opts="origin/main..HEAD" "$PWD"; echo "rc=$?"
```

Expected: `no leaks found`, `rc=0`, and an "N commits scanned" close to `git rev-list --count origin/main..HEAD` (a count of 0 means the `format.pretty` override did not take, and the scan proved nothing).

- [ ] **Step 3: The deployed targets render (Review Focus 3)**

```bash
chezmoi --no-pager diff ~/.claude/settings.json ~/.claude/CLAUDE.md ~/.codex/AGENTS.md ~/.config/agents/GLOBAL.md ~/.codex/config.toml ~/.config/zsh/zshenv ~/.config/zsh/config ~/.claude/git-forge-guard.sh ~/.claude/git-push-guard.py ~/.claude/hooks/prompt-audit.sh ~/.claude/hooks/herdr-agent-state.sh ~/.claude/xreview-guard.sh ~/.local/bin/xreview > "$TMPDIR/branch.diff" 2>&1; echo "rc=$?"
grep '^diff --git' "$TMPDIR/branch.diff"
grep -E '^[-+] *"(modelSettings|autoMode|enabledPlugins|extraKnownMarketplaces|includeCoAuthoredBy|voiceEnabled|subagentStatusLine|cleanupPeriodDays)"' "$TMPDIR/branch.diff"
```

Expected: `rc=0` with no `onepasswordRead` or `op` error; a `diff --git` header for each changed target (the three instruction files rendered from the fragments, settings, and so on); and from the last grep only `-  "cleanupPeriodDays": 14,`, `+  "cleanupPeriodDays": 30,`, and removals of `includeCoAuthoredBy`, `subagentStatusLine` and `voiceEnabled`. A `-` line for `modelSettings`, `autoMode`, `enabledPlugins` or `extraKnownMarketplaces` means the merge drops a runtime key: stop. (This exact check was run at plan time against a simulated end state of this plan.)
Then try the full preview: `chezmoi apply --dry-run --verbose > "$TMPDIR/apply-dry.txt" 2>&1; echo "rc=$?"`. It renders templates that need `op` (SSH keys, bundler tokens); if it fails for `op` alone, note that in the report and rely on the targeted diff above. Never run it unsandboxed to get past `op`.

- [ ] **Step 4: The foreign edits are untouched**

Run: `git status --short`
Expected: exactly ` M dot_config/ghostty/config`, ` M dot_config/herdr/config.toml`, ` M dot_zshrc` (unstaged, as at the start) and nothing else.
Run: `git log --format='%h %s' origin/main..HEAD` — expected: the spec commit, the plan commit, then this plan's commits in task order.

- [ ] **Step 5: Report**

Report to the lead:
- per-suite passed/total from Step 1;
- the gitleaks results (history in Task 2, branch in Step 2);
- the latency figures from Task 1 Step 7;
- anything skipped and why (the full `chezmoi apply --dry-run` if it needed `op`);
- for Michael after merge: run `chezmoi apply`, then `brew bundle --file ~/.config/homebrew/Brewfile` if gitleaks is not yet installed on the other machine; the `op` render can be removed from the 1Password *Agent instructions* note (spec §7); add `~/.local/state/zsh` to Vorta's sources if shell history should be backed up (Task 9 note); `herdr integration status` should report the Claude integration current; a branch already in flight needs one fresh `xreview dispatch --checkpoint pre-merge` before its MR (Task 10 note);
- the +14-day review: `.scripts/measure-interventions.py --days 14` and `~/.local/state/agent-audit/prompts.jsonl`.
