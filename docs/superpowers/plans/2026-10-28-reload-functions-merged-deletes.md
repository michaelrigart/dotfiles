# Reload changed functions; delete merged branches Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress

> **Superseded in part, 2026-10-29. Do not execute Task 2 or Task 3.** Michael chose option (d),
> recorded in the spec's section 2 (c9adecf and the spec commits after it). The allow rules A1,
> A2, A4, F1 and F2, the guard's mirror of them (`DELETE_ALLOW_RULES`, `NOT_A_DELETE_PUSH`,
> `NOT_DELETE_SHAPE`), and their parity tests were built and then removed. They are replaced by:
> - an `autoMode.allow` classifier rule for the exact plain pinned delete of a merged branch;
> - rule 4's silent pass requiring canonical text;
> - the `sdd-clean` fsmonitor fix.
>
> The removal landed at 5663016 and the fixes after it. Also superseded:
> - the Goal's "through the push guard instead of the auto-mode classifier": the classifier
>   still decides, trusting the guard's verification;
> - the Architecture line on the rules;
> - the Global Constraints that list the five allow rules and the two mirror deny reasons;
> - the constraint that a push matching no mirror rule keeps today's verdict exactly. Two kinds
>   of push now get a stricter verdict: a merged, pinned delete that is not canonical, and a
>   dry run outside canonical text. "No verdict loosens" and "nothing adds an ask" still hold;
> - Tasks 2 and 3.
>
> Task 1 (the reload hook) and the `global.md` wording were implemented as written. The tasks
> below are left as approved, as history.

**Goal:** Interactive shells reload `~/.config/zsh/functions` when it changes, and agents delete merged branches through the push guard instead of the auto-mode classifier.

**Architecture:** A `preexec` hook in `dot_zshrc` reads the functions file once (mtime first), trials it in a subshell and loads that same text. Three push allow rules and two fetch rules go into the settings modify script; `git-push-guard.py` mirrors the push rules and judges every command that matches one by what git will parse. The "confirm first" rule in `global.md` gets a narrow exception.

**Tech Stack:** zsh 5.9 (`zsh/stat`'s `zstat`), Python 3.9 (`/usr/bin/python3`, no `match`, no `X | Y`), bash test suites, jq.

**Spec:** `docs/superpowers/specs/2026-10-28-reload-functions-merged-deletes-design.md` (signed off at `aa70903`). Read it first; this plan does not repeat its reasoning.

## Global Constraints

- Fixed copy: `zsh: reloaded ~/.config/zsh/functions` and `zsh: cannot reload ~/.config/zsh/functions; keeping the old functions` (stderr, one line each).
- The guard's two mirror deny reasons, verbatim:
  - `NOT_A_DELETE_PUSH`: `Push guard: this command matches a delete allow rule but is not a delete push; reword it so it does not carry the delete form (a commit message quoting it, for example).`
  - `NOT_DELETE_SHAPE`: `Push guard: this command matches a delete allow rule but git would not parse it as a delete-only push; push normally, without the delete shape.`
- The five allow rules, verbatim: `Bash(git push --force-with-lease=* origin --delete *)`, `Bash(git push --force-with-lease=* origin -d *)`, `Bash(git -C * push --force-with-lease=* origin --delete *)`, `Bash(git fetch --prune)`, `Bash(git fetch --prune origin)`.
- A push that matches no mirror rule keeps today's verdict exactly; no verdict loosens; nothing adds an `ask` that is not an ask today.
- Suites are executed, never prefixed with an interpreter. `zshrc.test.sh` needs unsandboxed + a pty (the controller runs it); every other suite here runs sandboxed. Report passed/total.
- Never `chezmoi apply`, never edit a deployed file, never run `wt*`, never touch `~/.claude/settings.json` or `~/.zshrc`. Implementers do not commit.
- `global.md` stays at most 180 lines (it is at 180); `claude-code.md` is not touched.

## Review Focus

- A `-C` path with a space, quoted as the guard prints it (`git -C '/a b' push …`), on a merged pinned delete: silent pass (A4 matches through the quotes; one `-C` is bare). Test in Task 2.
- `cd <repo> && git push --force-with-lease=<b>:<sha> origin --delete <b>`: Claude Code splits it and A1 allows the push half; the guard sees a `cd` prefix, so not bare: deny naming `git -C <repo> push …`. Test in Task 2.
- Spacing variants of the delete shape (two spaces, a tab, a `\`-newline) still meet the mirror: the guard matches a pattern space as `\s+` after joining continuations. Test in Task 2.
- A git command that is not a push but carries A4's text after its `*` (`git -C <r> -c core.fsmonitor=<cmd> status push --force-with-lease=a origin --delete b`): today the guard is silent and A4 would run it unjudged. Deny (the spec's controller ruling of 2026-10-28). Test in Task 2.
- A `$HOME` with a space in it: the hook's path variables are unquoted zsh words, which do not split. Test in Task 1 (the fixture HOME has a space).

---

### Task 1: Reload hook in `dot_zshrc`

**Depends on:** none. **Tier:** `sp-standard`.

**Files:**
- Modify: `dot_zshrc` (the `source "$HOME/.config/zsh/functions"` line, 8)
- Create: `tests/zshrc-reload.test.sh` (mode 755, `#!/usr/bin/env bash`)
- Modify: `tests/zshrc.test.sh` (one pty case)
- Modify: `AGENTS.md` only if a new suite needs a Testing-table row (it does not: sandboxed, no `test-requires`)

**Interfaces:**
- Produces: `_zshrc_reload_functions` (no arguments; registered with `add-zsh-hook preexec`), globals `_zshrc_fn` (scalar path) and `_zshrc_fn_mtime` (array, one element: the mtime, or `missing`).

- [ ] **Step 1: Write the failing suite `tests/zshrc-reload.test.sh`.** Pattern after `tests/zsh-config.test.sh` (`_pass`/`_fail`/`is`, `passed: N  failed: M`, exit 2 when `dot_zshrc` or `/bin/zsh` is missing). Each case runs a fresh `env -i … /bin/zsh -f` that sources the source `dot_zshrc` with `zshrc.test.sh`'s stubs (temp `HOME` **containing a space**, `ZSH`, `HOMEBREW_PREFIX`, empty `zshenv`/`config`/`aliases`) and a functions fixture, asserts the registration, then runs `add-zsh-hook -d preexec _zshrc_reload_functions` and calls the hook directly. The `-d` is required: zsh 5.9 runs `preexec` hooks before each line of a `zsh -f` script too. mtimes are set with `touch -t`, never by waiting. Cases (stderr captured per call; `f` prints its version):
  - Z1 `preexec_functions` contains `_zshrc_reload_functions`; `precmd_functions` does not; `whence -w stat` is `stat: command`.
  - Z2 unchanged file: the call prints nothing; a fixture counter (`(( ++LOADS ))` at the fixture's top level is allowed in the fixture only) is unchanged.
  - Z3 new body, later mtime: `f` prints the new version; stderr is exactly the reload line.
  - Z4 an earlier mtime than recorded reloads.
  - Z5 unclosed brace: old `f` kept, stderr exactly the failure line; a second call prints nothing; a fixed file with a new mtime reloads.
  - Z6 mode 000 with a new mtime: old `f` kept, one failure line; `chmod 644` alone (mtime unchanged) reloads nothing.
  - Z7 file moved away: one failure line, second call silent; moved back with a new mtime reloads.
  - Z8 with `alias ll='ls -l'` defined, a file defining `f` then `ll()`: old `f` kept, one failure line; after `unalias ll` and a new mtime it reloads.
  - Z9 replaced between the stat and the read: the test defines `zstat() { builtin zstat "$@"; local rc=$?; <once: write v3 to a temp file, touch -t later, mv it over the functions file>; return rc }`; that call loads v3 and prints the reload line; the next call prints the reload line again; the call after prints nothing; `f` prints v3 throughout.
  - Z10 a function present before and absent from the new file stays defined.
  - Z11 the real `dot_config/zsh/functions`: every top-level line is a comment, blank, `}` or `name() {`; and it contains none of `$0`, `funcsourcetrace`, `functions_source`, `%x`, `%N`, `LINENO`.

- [ ] **Step 2: Run it; expect RED.** `./tests/zshrc-reload.test.sh` → Z1 and Z3–Z9 fail (no hook yet); Z11 passes.

- [ ] **Step 3: Implement in `dot_zshrc`.** Exactly the spec's sketch, split around line 8: `zmodload -F zsh/stat b:zstat`, the globals and the first `zstat` go before `source "$HOME/.config/zsh/functions"`; the function and `add-zsh-hook preexec` after it. If the `zmodload` fails, nothing of the hook is defined and the `source` still runs. No `zmodload zsh/stat` without `-F`.

- [ ] **Step 4: Run it; expect GREEN.** `./tests/zshrc-reload.test.sh` → `failed: 0`. Also `./tests/zsh-config.test.sh`.

- [ ] **Step 5: Add the pty case to `tests/zshrc.test.sh`.** The stub functions file starts as `f() { print OLD-F }`. After the existing three checks, the Python harness rewrites it to `f() { print NEW-F }` with an mtime one minute later (`os.utime`), sends `f\r` at the already-drawn prompt, reads until `NEW-F`, and appends two fields: the reload line appears, and it appears before `NEW-F`. Two new `is` assertions; the `read -r` line gains two names. The existing eleven assertions are unchanged. The implementer cannot run this suite (sandboxed: exit 2, INCONCLUSIVE); the controller runs `./tests/run.sh zshrc` unsandboxed.

### Task 2: The guard mirrors the delete rules

**Depends on:** none. **Tier:** `sp-standard`.

**Files:**
- Modify: `dot_claude/git-push-guard.py`
- Modify: `tests/git-forge-guard.test.sh` (rule 4's merged-delete section, after the existing cases and before the cases that move the remote)

**Interfaces:**
- Produces: `DELETE_ALLOW_RULES: tuple[str, ...]` — exactly the three push rule strings from Global Constraints, in that order (Task 3's parity test reads it with `runpy.run_path`); `NOT_A_DELETE_PUSH: str` and `NOT_DELETE_SHAPE: str` — the two mirror deny reasons.
- Produces: `rule_pattern(rule: str) -> re.Pattern` and `matches_delete_rule(cmd: str) -> bool`.
- Changes: `parse_plain` returns two more keys, `global_opts` (every global option word as written, `-C` and its value included, `--exec-path…` included) and `wrapper` (`"command"`, `"sudo"`, `"env"` or `None`); `merged_delete` / `check_merged_delete` take `where` (the words printed between `git` and `push`) instead of reading `repo.repo_opts`.

- [ ] **Step 1: Write the failing cases.** In the merged-delete section (fixtures `DEL`, `DONE`, `OPEN`, `MAIN` exist), with `expect` / `has_reason`:
  - M1 `git -C $DEL push --force-with-lease=done:$DONE origin --delete done` from `$TMP`: allow.
  - M2 the same through `'$TMP/del work'` (the existing copy with a space): allow.
  - M3 `git -C $DEL --no-pager push …` (merged, pinned): deny; `has_reason` names `git -C $DEL push --force-with-lease=done:$DONE origin --delete done`.
  - M4 the same with `--exec-path=$TMP`, with a second `-C $DEL`, and with a leading `GIT_EXEC_PATH=$TMP`: deny each.
  - M5 the same with `-c x.y=z`: deny (today's unsupported-configuration reason, unchanged).
  - M6 `cd $DEL && git push --force-with-lease=done:$DONE origin --delete done` from `$TMP`: deny; the reason names `git -C $DEL push …`.
  - M7 A1's shape on the unmerged branch, pinned: ask (existing "an unmerged branch, pinned" already covers it; keep it).
  - M8, M9, M12 and M14 push `$DEL`'s `work` branch (checked out at `main`'s tip, not on the remote, so its scan is clean) with the lease `work:$MAIN`.
  - M8 `git push --force-with-lease=work:$MAIN --push-option="ci.variable=X= origin --delete x" origin work`: deny; `has_reason` matches `NOT_DELETE_SHAPE`. Allowed today: the spoofed update gets through.
  - M9 `git push --force-with-lease=work:$MAIN -o --delete origin work`: deny (today's push-option check; it does not reach the mirror).
  - M10 `git push --force-with-lease=done:$DONE origin --delete --no-verify` (no refspec): deny with `NOT_DELETE_SHAPE`.
  - M11 `git push --force-with-lease=done:$DONE origin --delete done --force`: deny with `NOT_DELETE_SHAPE` (today: ask).
  - M12 spacing: `git  push --force-with-lease=work:$MAIN --push-option="ci.variable=X=  origin	--delete x" origin work` (two spaces, a tab): deny with `NOT_DELETE_SHAPE`. Allowed today.
  - M13 `git -C $DEL -c core.fsmonitor=true status push --force-with-lease=a origin --delete b`: deny with `NOT_A_DELETE_PUSH` (today: silent).
  - M14 `git push --force-with-lease=work:$MAIN origin work` (no delete shape): today's verdict (allow).
  - M15 a dry run in A1's shape (`… origin --delete done --dry-run`): allow.
  - M16 `git -C $DEL commit --allow-empty -m 'quote: push --force-with-lease=a origin --delete b'`: deny with `NOT_A_DELETE_PUSH` (today: silent).
  - M17 `git -C $DEL commit --allow-empty -m 'tidy the fixtures'`: allow (an unrelated commit stays silent).
  Every existing rule-4 case stays as it is.

- [ ] **Step 2: Run it; expect RED.** `./tests/git-forge-guard.test.sh` → M3, M4, M6, M8, M10–M13 and M16 fail (M8 and M12 because today's guard allows them); the rest pass.

- [ ] **Step 3: Implement.**
  - `rule_pattern`: strip `Bash(` and `)`, split on `*`, `re.escape` each literal part with every escaped space replaced by `\s+`, join with `.*`, compile with `re.S`; used with `.search` (unanchored: a superset of Claude Code's per-subcommand match, which strips wrappers first). `matches_delete_rule` joins `\`-newline continuations before searching.
  - `main`: the mirror search runs first, over the whole command text. If `matches_delete_rule(cmd)` and the command is not a plain git invocation whose literal subcommand word is `push` (tokenizing fails, `parse_plain` returns `None`, or `sub != "push"`), deny `NOT_A_DELETE_PUSH`, before any other check. Otherwise thread `mirrored=True` through `judge` into `evaluate`. The deny goes out through the existing `decision("deny", …)`.
  - `evaluate`, when mirrored, after today's early returns and denies (dry run, `-c`, `--git-dir`, …): `delete_targets` returning `None` is a deny `NOT_DELETE_SHAPE`; a target list that names the default branch falls through to today's ask; otherwise call `merged_delete` with the push's leases when the invocation is bare and with no leases when it is not, so a non-bare merged delete comes back as the deny naming the pinned command and an unmerged one as `None` (ask). `True` (bare, merged, pinned) is the silent pass.
  - Bare: no `cd` prefix, no assignment, no `wrapper`, and `global_opts` empty or exactly `["-C", <path>]`. A `2>&1` and a `tail`/`head` pipe are allowed.
  - `where`: the push's `-C <path>` as written when it had one; `-C <cwd>` (quoted with `shlex.quote`) when a `cd` prefix moved it; otherwise empty. Non-mirrored pushes pass `repo.repo_opts` as today, so the existing `has_reason` cases keep their text.

- [ ] **Step 4: Run it; expect GREEN.** `./tests/git-forge-guard.test.sh` → `failed: 0`, every pre-existing case unchanged.

### Task 3: Allow rules, parity and the instruction

**Depends on:** Task 2 (`DELETE_ALLOW_RULES`). **Tier:** `sp-mechanical`.

**Files:**
- Modify: `dot_claude/modify_private_settings.json` (`permissions.allow`, with a comment naming the guard's mirror and the spec)
- Modify: `tests/claude-settings.test.sh` (section A)
- Modify: `.chezmoitemplates/agents/global.md` (the "Every agent confirms first" bullet, 4 lines → 4 lines)
- Modify: `tests/agent-instructions.test.sh`

**Interfaces:**
- Consumes: `DELETE_ALLOW_RULES` from `dot_claude/git-push-guard.py` (read with `/usr/bin/python3 -I -c 'import runpy,json,sys; print(json.dumps(sorted(runpy.run_path(sys.argv[1])["DELETE_ALLOW_RULES"])))'`).

- [ ] **Step 1: Write the failing cases in `tests/claude-settings.test.sh`, section A.**
  - S1 each of the five rules is in `.permissions.allow`.
  - S2 "no mutating verb is allowlisted" keeps its regex and exempts exactly the three push rules (`select(… | not)` on membership in that list); `sdd-clean` stays as it is.
  - S3 parity: the rendered allow rules matching `^Bash\(git .*\bpush\b` sorted equal the guard's `DELETE_ALLOW_RULES` sorted.
  - S4 a matcher model of the documented semantics (whole text; `*` any text including spaces; a trailing ` *` that is the rule's only `*` also matches the bare command), as a small jq or python function. Calibration first: `Bash(git log * main)` matches `git log --oneline main` and not `git log main` or `git push origin main`; `Bash(ls *)` matches `ls` and not `lsof`. Then no allow rule matches `git push`, `git push origin feat`, `git push --force-with-lease=feat:abc origin feat`, `git push origin main`, `git -C /r push origin main`, `git fetch --prune origin '+refs/heads/*:refs/heads/*'` or `git -C /r fetch --prune origin`; and `git push --force-with-lease=b:abc origin --delete b`, `git -C /r push --force-with-lease=b:abc origin --delete b`, `git push --force-with-lease=b:abc origin -d b` and `git fetch --prune origin` each match exactly one rule.
  - S5 no allow rule ends in `:*` with another `*` before it.

- [ ] **Step 2: Write the failing case in `tests/agent-instructions.test.sh`:** `need global.md '  does a merged branch'"'"'s pinned delete and `git branch -d`. Harness prompts are a backstop.' "global.md exempts a merged branch's pinned delete from confirm-first"`.

- [ ] **Step 3: Run both; expect RED.** S1, S3, the S4 match half and the `need` fail; S2 passes vacuously; S5 passes.

- [ ] **Step 4: Implement.** The five rules in `permissions.allow` with a comment; the bullet in `global.md` replaced by the spec's four lines verbatim (section 3).

- [ ] **Step 5: Run; expect GREEN.** `./tests/claude-settings.test.sh` and `./tests/agent-instructions.test.sh` → `failed: 0`; `wc -l < .chezmoitemplates/agents/global.md` → `180`.

## Execution

- **Batch 1:** Tasks 1 and 2 in parallel (disjoint files; neither suite loads the other's subject). **Batch 2:** Task 3.
- The controller commits each task on its own, reviews it on that commit (`sp-reviewer`), and after each batch runs `./tests/run.sh` sandboxed and `./tests/run.sh zshrc` unsandboxed, one at a time, then pushes.
- The final whole-branch review is `sp-architect`. The last commit before the pre-merge review
  sets this plan's and the spec's `**Status:**` to `Implemented`, citing the branch.
