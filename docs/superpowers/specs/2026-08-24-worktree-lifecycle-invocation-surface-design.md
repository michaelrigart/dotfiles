# Worktree lifecycle invocation surface

**Status:** In progress
**Date:** 2026-08-24

Extends [2026-07-30 Worktree hook protocol](./2026-07-30-worktree-hook-protocol-design.md),
which remains accurate and Implemented. This record adds an invocation surface; it
changes no protocol semantics.

## 1. Problem

Six husk directories accumulated under `~/Code/Netronix/` between 2026-08-14 and
2026-08-23: `curato-issue-{82,83,84,89,90,92}`. Each contained nothing but a
Bootsnap compile cache under `tmp/cache/`, two also an empty `.claude/.cc-writes`.
No source, no `.git`, no unpushed work. Git registered only the primary worktree,
so the husks were inert directories, not worktrees.

The 2026-07-30 protocol anticipated this shape exactly. §8 step 14 warns when the
target directory "remains or reappears after Git reports success," and the §8
rationale names the cause: "a live process holding the directory open is what
leaves an empty `tmp/` husk behind after removal," with Bootsnap named explicitly.

But `wt-rm` did not run. Shell history records no `wt-rm` invocation — evidence of
what was not run interactively, not proof it has never run. Every one of the six was removed by a Claude Code session issuing raw
`git worktree remove`, one with `--force`. Under §10 those removals receive no
guarantees: no session shutdown, so the Zellij session's Rails processes survived
and rewrote `tmp/cache/` into the just-deleted path.

The bypass is structural, not a discipline failure. The lifecycle commands are zsh
functions in `dot_config/zsh/functions`, sourced by `.zshrc` line 8 — so they exist
only in an interactive shell:

```
$ zsh -c 'type wt-rm'    # wt-rm not found
$ zsh -lc 'type wt-rm'   # wt-rm not found
```

Agents, scripts, and cron run non-interactively. For them `wt-rm` is unreachable
and raw `git worktree remove` is the only option available. `wtcp` — a real binary
at `/opt/homebrew/bin/wtcp` — is reachable; the lifecycle commands are the outlier.

The protocol was not bypassed because it was ignored. It was bypassed because it
could not be called.

## 2. Goals

1. Make worktree **retirement** and **recovery** callable from a non-interactive
   shell, so the protocol is an available choice rather than an interactive-only one.
2. Change no protocol semantics, no ordering, no failure states, and no existing
   interactive behavior.
3. Catch the specific raw command that produced the husks, at the point an agent
   would issue it.
4. Keep every guard fail-open: a guard that breaks unrelated commands is worse than
   no guard.

## 3. Non-goals

- **Agent-side worktree creation.** `wt` calls `dev "$dest"`
  (`dot_config/zsh/functions:676`), which attaches to and can switch Zellij
  sessions. Exposing it to a non-interactive caller would be wrong, not merely
  unhelpful. `wt` and `dev` stay interactive-only. Only retirement and recovery
  become reachable — this record does not give agents a way to *create* worktrees.
- **A security boundary.** §5.3 enumerates what the guard cannot see. It is a
  correctness catch for literal commands, nothing more.
- **Adopting non-`wt` worktrees.** `wt-rm` addresses only the sibling convention
  (§4.1). Worktrees created by other tools keep their own lifecycle.
- **Refactoring the protocol implementation.** No code motion; see §8.

## 4. Invocation surface

### 4.1 Scope of `wt-rm`, and why ownership matters

`wt-rm` derives its target by path arithmetic, not by lookup
(`dot_config/zsh/functions:749`):

```zsh
dest="${main:h}/${main:t}-${slug}"      # slug = branch with '/' → '-'
```

So `wt-rm` addresses exactly one convention: a sibling of the primary worktree
named `<repo>-<slug>`. A worktree under `.worktrees/`, `.claude/worktrees/`, or any
other layout is not merely unsupported — it is unaddressable. `wt-rm <branch>` would
compute the sibling path, fail its `[[ -d "$dest" ]]` check, and report "does not
exist."

This is load-bearing for §5: any message recommending `wt-rm` for a non-sibling
worktree would hand the caller a remedy that provably cannot work.

### 4.2 Commands exposed

`wt-rm` (retirement) and `wt-prepare` (recovery — the documented
`wt-prepare <branch> && wt <branch>` path in §9.3 of the base protocol). Neither
mutates the parent shell, and `wt-rm` already refuses to run from inside its own
target, so neither needs to be a shell function.

### 4.3 Wrapper contract

Two executables under `dot_local/bin/`, matching the existing `executable_*`
convention. `XDG_BIN_HOME` is already on `PATH` (`dot_config/zsh/zshenv:8,15`).

```zsh
#!/usr/bin/env zsh
emulate -L zsh
conf="${XDG_CONFIG_HOME:-$HOME/.config}"
for f in zshenv functions; do
  [[ -r "$conf/zsh/$f" ]] || { print -ru2 -- "wt-rm: cannot read $conf/zsh/$f"; exit 1 }
  source "$conf/zsh/$f"
done
(( $+functions[wt-rm] )) || {
  print -ru2 -- "wt-rm: $conf/zsh/functions did not define wt-rm."; exit 1 }
wt-rm "$@"
```

Each clause earns its place:

- **`zshenv` is sourced first, and is not optional.** There is no `~/.zshenv`, so a
  bare `zsh` has no XDG variables, no `wtcp` or `zellij` on `PATH`, and no
  `ZELLIJ_SOCKET_DIR` (`dot_config/zsh/zshenv:34`) — which `wt-rm` needs to find the
  session it must stop. Only the XDG base variables are guarded with
  `test "$X" || export`; the rest are unconditional, so sourcing prepends `PATH`
  entries again and re-runs `brew --prefix`. Both are harmless in a wrapper process
  that exits immediately, and neither is avoidable without duplicating the
  environment contract here.
- **`functions` is safe to source.** The file defines functions and nothing else; it
  has no top-level side effects.
- **No `set -u`.** `zshenv` tests unset variables by design; `set -u` would abort on
  the first one.
- **The `$+functions` guard prevents a fork bomb.** The script and the function
  share a name. If the functions file is present but does not define `wt-rm`, the
  bare call would resolve back through `PATH` to this script and recurse without
  limit. A readability check alone does not cover this: the dangerous case is a file
  that exists and is readable but empty. This is the guard's only purpose.
- **Interactive shells are unaffected.** A zsh function shadows a `PATH` command, so
  an interactive `wt-rm` continues to call the function directly.
- **The function call is last, so its exit status is the script's.**

`emulate -L zsh` is scoped to the script and does not leak.

### 4.4 Standard input

Base protocol §9.4: hooks "inherit stdin and may legitimately wait for
interaction." The wrappers leave stdin inherited and do not redirect it.

A prompting hook invoked from a non-interactive caller may block or may receive
EOF, depending on the runner. Redirecting `/dev/null` would make that uniform but
worse: a hook whose `read` returns empty may proceed on a wrong default silently,
where blocking fails visibly. The wrapper does not alter the hook contract; the
consequence is documented instead.

### 4.5 Zellij-unreachable preflight

Both wrappers land on a caller class the base protocol never had to consider:
sandboxed processes. `wt-rm`'s own session-shutdown step (base protocol §8) treats
an absent Zellij session as successful shutdown — the normal state on a retry. But
`zellij list-sessions -s` can report "no sessions" for a reason other than there
being none: when zellij cannot reach its own sockets, most commonly because the
process is sandboxed and the socket directory is denied, it prints the same
nothing-here output and exits 0 — nothing about the output or the exit status
distinguishes the two cases. Read as absent, that reads as successful shutdown,
and `wt-rm` proceeds straight through teardown to `git worktree remove` while the
session's processes are still alive and holding the directory open — reproducing
the §1 husk mechanism through the very surface this record introduces, and
reporting success while doing it.

This belongs in the wrapper, not in `dot_config/zsh/functions`. The wrapper is the
new entry point this record adds, and it is the caller class this record makes
reachable — non-interactive, and therefore sandboxable — that is exposed to the
discrepancy; the interactive path was never at risk. Moving the check into the
shared teardown step would change what step 7 treats as failure for every caller,
interactive included, which §2 goal 2 rules out for this record. Fixing it there
is a change to protocol failure states and needs its own design record, not a
clause added under cover of this one.

The check, in `dot_local/bin/executable_wt-rm`: refuse when the Zellij socket
directory (`$ZELLIJ_SOCKET_DIR/contract_version_1`) holds entries but
`zellij list-sessions -s` names none. That is the discrepancy itself, not a proxy
for it — the check does not key on any sandbox-specific variable, or on any other
signal that this particular caller is a sandbox. Keying on such a variable would
encode an undocumented, implementation-specific detail of one caller as the
trigger, when the actual hazard is the mismatch between what the sockets say and
what zellij reports, regardless of why the two disagree.

Every ambiguous case is open, not closed: no `zellij` on `PATH`, no socket
directory, or a socket directory that is empty or unreadable all proceed —
"nothing to check," the same as the retry-safe absent-session case the check is
protecting. Only the discrepancy itself refuses. This follows §2 goal 4 the same
way the correctness guard in §5 does: a preflight that failed closed on ambiguity
would block retirement in states the base protocol already treats as fine.

The accepted cost is a false refusal: a zellij server killed by a crash can leave
a socket file behind with no process left to answer for it, and the preflight
cannot distinguish that from a live, merely-unreachable session. It refuses until
the stale socket is removed. That is the safe direction — the alternative is the
husk this record exists to stop — and the refusal message names both the socket
directory and the discrepancy, so the fix is legible rather than a bare exit 1.

A known limit: the socket subdirectory name (`contract_version_1`) is hard-coded.
A future Zellij release that bumps its socket contract would change that name, and
the preflight would find no directory to check — not a false refusal, but a silent
return to the hazard this section describes. That is fail-open, consistent with
§2 goal 4, and a candidate follow-up rather than something solved here.

## 5. Correctness guard

A `PreToolUse(Bash)` hook, `dot_claude/executable_worktree-guard.sh`, following the
conventions already established by `git-forge-guard.sh`: no `set -e`, every failure
path allows, unparseable input allows, Bash 3.2 compatible, and `deny` rather than
`ask` — this is a correctness catch, not a danger gate, per the "prompt on danger,
not mechanism" rule. Wired as an additional `PreToolUse` entry, appended, per the
existing warning in `modify_private_settings.json` that the hooks otherwise clobber
each other.

### 5.1 What it denies

Exactly one shape: a **standalone, beginning-anchored** `git worktree remove` whose
target is a **literal absolute path** matching the `wt` sibling convention. All six
observed commands were of this shape — each began with the removal, with pipes,
redirections and `&& echo` following it and nothing preceding it.

Anchoring is a correctness requirement, not a simplification. A pattern that matches
mid-command cannot bind a target to the invocation that owns it: in
`echo remove /a && git worktree remove /b`, scanning for a `remove` token finds the
decoy and would deny `/a` — a directory git was never asked to remove. Extraction is
therefore performed on the remainder of the *matched* invocation, and a command with
anything before the removal falls open.

The restriction to absolute paths is not conservatism, it is correctness. Git offers
two other ways to name a worktree that a text-matching guard cannot resolve:

- **`-C <repo>` changes git's working directory before the command runs**, so a
  relative target resolves against `<repo>`, not against the shell. The payload's
  `.cwd` is therefore the wrong base whenever `-C` is present, and using it would
  misclassify.
- **A unique trailing path component identifies a worktree outright.** Per
  `git-worktree(1)`: "If the last path components in the worktree's path is unique
  among worktrees, it can be used to identify a worktree." So
  `git worktree remove curato-issue-92` is valid and carries no filesystem path at
  all.

The two need different machinery, and neither is warranted here. A relative target
needs no registry query — the payload's `.cwd` plus any literal `-C` determines git's
effective directory — but it does need shell-aware parsing of quoting and of `-C`
composition, which git defines recursively: "each subsequent non-absolute `-C <path>`
is interpreted relative to the preceding `-C <path>`", and `-C ""` leaves the
directory unchanged. A suffix identifier needs more than parsing: only
`git worktree list` can say whether a trailing component is unique among the
registered worktrees.

Both exceed the deliberately narrow, observed absolute-path case, and are documented
blind spots (§5.3) instead. Cost is not the argument — the fast path already filters,
so any such work would run only for candidate removal commands, not on every Bash
call.

Recognition of the absolute case is filesystem-only, no subprocess: for each `-` in
the target's basename, if `<parent>/<prefix>` is a directory containing a `.git`
entry, the target is a `wt`-managed sibling. Splitting at every hyphen rather than
the first is required — repository names contain hyphens, as
`VM.Portal-duplicate-alerts` shows.

### 5.2 What it allows

- **`git worktree prune`, unconditionally.** Git's documentation: "Remove worktree
  information in `$GIT_DIR/worktrees` for worktrees whose working trees are missing.
  Useful after manually removing a working tree." It touches metadata, never a
  working tree; it acts only where the directory is *already* gone, so it cannot
  create a husk; and it is the remedy git itself prescribes after a manual removal —
  which is base-protocol §10's reconciliation path. Denying it would block the
  documented repair for the exact situation this guard exists to clean up after.
  It also has no target path, so it could not be ownership-scoped even if denial
  were desirable.
- **Removals of worktrees the `wt` protocol does not own.** Denying a
  `.claude/worktrees/` removal would break the harness's own worktree cleanup,
  turning a correctness guard into a functional regression.
- **`WT_GUARD=off` anywhere in the command**, for the manual reconciliation §10
  explicitly permits.

### 5.3 Blind spots, and why they are acceptable

The guard sees only literal command text passed to the Bash tool. It cannot see:

- native worktree tools such as `EnterWorktree` / `ExitWorktree`, which never reach
  the Bash tool;
- removal nested inside a script, Make target, or alias;
- variable targets such as `git worktree remove "$WORKTREE_PATH"`, which carry no
  literal path to classify;
- **relative targets**, whose base is the shell's cwd or, under `-C <repo>`, the
  repo — resolvable, but only through shell-aware parsing, and so out of scope (§5.1);
- **unique-suffix identifiers** such as `curato-issue-92`, which name a worktree
  without being a path (§5.1);
- **quoted paths containing spaces**, which split across whitespace-separated
  tokens. The guard deliberately bails rather than act on the truncated leading
  fragment: a fragment can itself name a real sibling, so guessing would deny the
  wrong directory and name it in the message;
- **any removal not at the start of the command** — one preceded by another command
  (`cd x && git worktree remove …`), or a second removal in a later clause. Only the
  leading invocation is examined (§5.1);
- the deliberate `WT_GUARD=off` bypass.

All eight fail open. This is a correctness catch aimed at the observed failure — a
literal absolute raw command issued directly — and is not a boundary. Closing the
relative case would take shell-aware argument parsing and the suffix case a
`git worktree list` query (§5.1); both are rejected as unnecessary complexity for
that goal, not as unaffordable.

### 5.4 Denial message

The message must not assume ownership it has not established (§4.1). Having matched
the sibling convention, it names `wt-rm` as the remedy, and additionally states the
two routes a caller may need if the match is wrong: a worktree owned by another tool
is retired through that tool, and manual reconciliation uses `WT_GUARD=off`. A denial
is read by the model, so it costs a retry rather than an interruption.

The message names the **slug** it matched, not a reconstructed branch. Slug
derivation is lossy — `slug="${branch//\//-}"` maps both `feature/foo` and
`feature-foo` to `feature-foo` — so inverting it would produce a branch name that may
not exist. The caller knows the branch it was working on; the guard supplies the
directory it recognized and lets the caller name the branch.

## 6. Written rule

The worktree paragraph gains the rule that retirement of a `wt`-managed sibling
worktree goes through `wt-rm`, never raw `git worktree remove`, and that agents do
not create `wt`-managed sibling worktrees.

The scoping matters. A blanket "agents do not create worktrees" would prohibit the
supported native isolation the harness itself provides — `EnterWorktree`, and the
Agent tool's `isolation: "worktree"`. Those worktrees are created, owned, and retired
by their own lifecycle tool, and this rule does not reach them. It governs the `wt`
sibling convention only.

The source of truth is **not a file in this repository**. `dot_config/agents/GLOBAL.md.tmpl`,
`dot_claude/CLAUDE.md.tmpl`, and `dot_codex/AGENTS.md.tmpl` are three identical
62-byte templates:

```
{{ onepasswordRead "op://Private/Agent instructions/notes" }}
```

The text lives in the 1Password item `Private/Agent instructions`, notes field;
`chezmoi apply` renders it to all three destinations at once. Editing the rule means
editing that item, then applying. No repository file carries the prose.

Two consequences for the plan. `op` is the one command that must run with the
sandbox disabled — its config path is a denied credential — so a full `chezmoi apply`
needs `op` signed in and the desktop app approved. And because the item is personal
content in a password manager rather than tracked source, the edit is Michaël's to
make or to approve explicitly; this record does not authorize an agent to write to it.

## 7. Testing strategy

Extend `.scripts/test-wt-functions.sh`, which sources the chezmoi source file and
exercises the functions from non-interactive zsh — some cases in a command
substitution inside the suite's own shell, some in an explicit
`zsh -c "source '$FUNCS'; …"`. Either way no interactive shell is involved, which is
the evidence that the protocol logic is already non-interactive-safe.

Wrapper:

1. Both wrappers are callable from a non-interactive shell and dispatch to the
   function.
2. Arguments are preserved, including a branch containing `/`.
3. Exit status propagates from the function.
4. A missing functions file exits non-zero with a diagnostic.
5. **A present but empty functions file exits non-zero and does not recurse.** This
   is the case that exercises the `$+functions` guard; a missing file never reaches
   it.

Guard, in a new `.scripts/test-worktree-guard.sh` mirroring
`.scripts/test-git-forge-guard.sh`:

6. `git worktree remove <absolute sibling>` — denied.
7. `git -C <repo> worktree remove <absolute sibling>` — denied. `-C` does not change
   an absolute target.
8. `git worktree remove --force <absolute sibling>` — denied.
9. `git worktree prune` — **allowed**.
10. Non-sibling absolute targets (`.worktrees/`, `.claude/worktrees/`) — allowed.
11. Variable target — allowed.
12. **Relative target**, with and without `-C` — allowed. Asserts the §5.1 boundary
    rather than aspiring past it.
13. **Unique-suffix target** (`git worktree remove curato-issue-92`) — allowed, same
    reason.
14. False positives — the string inside an `rg` pattern, a comment, or a heredoc —
    allowed.
15. `WT_GUARD=off` honoured in leading, middle, and trailing position.
16. **Fail-open on degenerate input** — empty payload, malformed JSON, absent
    `.tool_input.command`, and a target that classifies as nothing.

Settings wiring, in `.scripts/test-claude-settings.sh`:

17. That suite currently asserts `.hooks.PreToolUse | length == 1` (line 322) and
    reads the forge guard at `PreToolUse[0]` (lines 323–325). **Adding a second guard
    breaks it**, so the assertions must be updated to expect both entries — and to
    pin each guard to its own index, since the existing ones are positional and a
    reordering would silently retarget them.
18. `.hooks.SessionStart` must still be asserted present. Its own comment records that
    "adding PreToolUse replaced the whole hooks object once during development" — the
    exact regression this change risks repeating.

## 8. Alternatives considered

Closed decisions, recorded rather than left open.

**Extracting `wt-rm` and its helpers into a standalone program.** Rejected.
`wt-rm` depends on nine `_wt_*` helpers also used by `wt`, `wt-prepare`, and `dev`,
so extraction yields a shared library plus wrappers — a large diff across a
1410-line test suite, risking regressions in working code, to reach the same place
as a 12-line loader. The functions are already non-interactive-safe; only the
loading path was missing.

**Self-healing husk removal in step 14.** Rejected as the fix for this problem: the
husks came from raw git, so `wt-rm` never executed and a change there would not have
prevented one of them. It also adds autonomous deletion to a layer that deliberately
avoids it ("Generic rollback. Rejected."). Reconsider only if husks appear from a
run that actually used `wt-rm`.

**Documentation alone.** Rejected. A rule to use a command that a non-interactive
caller cannot invoke is unfollowable; §1 is what that produces.

**A blanket deny on all `git worktree` mutations.** Rejected. It would break
harness-owned worktree cleanup and block git's own prescribed reconciliation, and it
would recommend `wt-rm` for worktrees `wt-rm` cannot address.

**Exposing `wt` and `dev`.** Rejected; see §3.

## 9. Consequences

- Retirement and recovery become callable by agents, scripts, and cron. Creation
  does not.
- Interactive behavior is unchanged: the functions still shadow the wrappers.
- The protocol implementation is untouched, so the existing suite keeps its meaning.
- Husks remain possible, through the §5.3 blind spots and through two residual paths
  inside `wt-rm` itself: a **false-success shutdown**, where `zellij delete-session`
  reports success but descendant processes outlive it and write after removal; and
  the **session-recreation race** the base protocol documents in §8, where a `dev`
  run in another terminal restores the session between shutdown and teardown. A
  shutdown that *reports* failure is not one of them — `wt-rm` refuses to remove and
  preserves the worktree intact (`dot_config/zsh/functions:786`). This record makes
  the correct path available and the common wrong path visible; it does not make
  husks unreachable.
- A sandboxed caller whose Zellij session is genuinely live is refused by the §4.5
  preflight, rather than the wrapper silently reporting success while producing a
  husk.
- A new hook fires on every Bash call, so its fast path must stay cheap.

## 10. Open questions

None.
