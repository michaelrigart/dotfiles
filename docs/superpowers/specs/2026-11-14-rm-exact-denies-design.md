# rm: deny the roots, drop the two ask rules

**Status:** In progress (awaiting sign-off)
**Date:** 2026-11-14
**Sign-off:** D2 (b) by the driver session on Michael's delegation, 2026-11-14. D1 is Michael's,
pending. Codex spec review: approve in round 3 (`xr-1794664170-b520bb27`; round 1,
`xr-1794663800-0efa37b0`, two P1s, and round 2, `xr-1794664059-c104a548`, one P2, all fixed).
**Branch:** `fix/rm-exact-denies`, in the `wt` checkout `~/.local/share/chezmoi-fix-rm-exact-denies`,
from `main` at `f292740`
**Source:** item 22 of the vault note `2026-11-11-agent-setup-full-review` ("`rm` takes literal
absolute paths ... Replace those two rules with exact denies for every sandbox-writable root").

## 1. Why

`permissions.ask` holds `Bash(rm -rf ~/*)`, `Bash(rm -r ~/*)` and the same two with
`/Users/michael/*`. Each is a prefix rule, so it asks on every recursive delete of a literal home
path written with `-rf` or `-r`: a `build/` directory, a `__pycache__`, a probe in a repository's
`tmp/`. It gates the spelling, not the danger. A whole-home delete written `rm -fr ~` never matched
it, and neither did `rm -R`, `rm -r -f` or `/bin/rm`.

Michael's rule for prompts (memory `prompt-budget-destructive-only`): only dangerous destructive
actions ask; a silent deny beats the classifier, and the classifier beats an ask. An ask rule cannot
be narrowed by a hook (memory `ask-rule-beats-hook-allow`), so the rule has to go, and what it should
have protected moves to deny rules.

## 2. Measured

Every Bash call that runs `rm`, in all Claude Code transcripts on this Mac from 2026-11-01 to
2026-11-14 (1,071 calls, 191 in main sessions), joined to the `permissionDecision` recorded on its
tool result. `reasonCode` says which mechanism decided.

| Outcome | Calls | Mechanism (`reasonCode`) |
|---|---|---|
| Prompt, approved | 44 | `rule:userSettings`: the rm ask rules (every one of the 44 commands matches their shape and no other ask rule). 27 literal targets, 17 variable targets the matcher resolved (`W=/Users/michael/...; rm -rf $W/x`). 25 in main sessions, 19 in subagents |
| Prompt, approved | 2 | `safetyCheck`, `circuitBreaker: dangerousRemoval`: Claude Code's built-in removal check, on loop variables |
| Denied, no prompt | 24 | the same built-in check, in subagents (23) and one main session: `rm -rf $S/m1`, `rm -f $TMPDIR/*.orig` |
| Denied, no prompt | 2 | the auto-mode classifier ("Destructive or Unwanted Actions"), both scratchpad deletes |
| Denied, no prompt | 46 | guards firing on another part of the command (push guard 34, path guard 11, merge gate 1) |
| Ran, classifier allowed | 952 | |
| Prompt, rejected | 0 | |

The 44 are 27% of the 160 Bash prompts in the prompt audit log over the same days. All were
approved. No rm call named a root (§3.1), a repository or an organisation directory: the targets
were scratchpads and `$TMPDIR` (324 arguments), build output, `__pycache__`, `.superpowers/` and
repository `tmp/`.

The review's attribution (28 of 50 from the built-in check, 7 from the ask rules, repeated in its
"Withdrawn" list) does not survive the `reasonCode` join: the variable-target prompts it gave to the
built-in check were the ask rules matching a resolved variable. The recommendation is unchanged;
the expected saving is about six times larger.

How the matcher treats an rm deny rule, measured with `claude -p` (Claude Code 2.1.325, haiku) on
throwaway directories under this checkout's git-ignored `.superpowers/`, with a control run for
each claim. The last round used the real setting shape: sandbox on, auto-allow on, auto mode, no
allow rule.

| Rule shape | Denies | Does not deny |
|---|---|---|
| `Bash(rm * R)` | `rm -rf R`, `rm -fr R`, `rm -r -f R`, `rm -Rf -- R`, `/bin/rm -rf R`, `command rm -rf R`, `rm -rf "R"`, `rm -rf R\ x` for a path with a space, `rm -rf $HOME/...R`, `rm -rf "$HOME"/...R`, `rm -rf X R`; also as one command of a compound | `rm -rf R/sub`, `rm -rf ${HOME}/...R`, a `~` spelling of R |
| `Bash(rm * R *)` | `rm -rf R X` | `rm -rf R/sub X` |
| `Bash(rm * R/)` | `rm -rf R/`, `rm -fr R/` | |
| `Bash(rm * R/\*)` | `rm -rf R/*` (the control, with no such rule, deletes) | `rm -rf R/sub`: `\*` is a literal star |
| `Bash(rm * R/\**)` (not used) | `rm -rf R/*`, `rm -rf R/**`, `rm -rf R/*/`, and by the same trailing wildcard `rm -rf R/*/*/build` | `rm -rf R/sub` |
| `Bash(rm * R/?*)`, `Bash(rm * R/{*)` (not used) | `rm -rf R/?*`, `rm -rf R/{x,y}`, and so a selective `rm -f R/{a,b}.pdf` | |
| `Bash(rm * R/.\*)` | `rm -rf R/.*` | |
| `Bash(rm * R/\*)` (amended 2026-11-14, found in the Task 1 review) | | a flagless `rm R/*`, which deletes the root's top-level files: the middle `*` needs a word between `rm ` and ` R` |
| exact `Bash(rm -rf R)` | `rm -rf R`, `rm -rf "R"` | `rm -fr R`, `rm -r -f R`, `rm -rf R/`: why the design uses the wildcard shape |

A variable set in the command (`D=...; rm -rf $D/x`) is refused by the built-in check whatever the
rules say. `$HOME` is expanded before matching; `${HOME}` and `~` are not. `?` and `[...]` are
literal in a rule (`Bash(rm * R/a?c)` does not deny `rm -rf R/abc`), and matching is
case-sensitive: `Bash(rm * R/Case1)` does not deny `rm -rf R/case1`, which on case-insensitive APFS
deletes `Case1`.

## 3. Design

### 3.1 Deny every spelling of a root

The roots are `~` and the four `sandbox.filesystem.allowWrite` entries: `~/Code`,
`~/.local/share/chezmoi`, `~/Documents` and `~/Library/Mobile Documents/iCloud~md~obsidian`. A
sandboxed `rm` can reach only these (plus the session's own directory and `$TMPDIR`); an
unsandboxed one can reach `~`. Each root is written twice, as `~/...` and as the absolute path the
modify script builds from `$HOME` at apply time, and gets 24 rules. Six operands name the root
or all of its contents: `R`, `R/`, `R/*`, `R/*/`, `R/**` and `R/.*`. Each is denied as the last
argument and before more arguments, so every rule ends at an operand boundary: the end of the
command or a space. Each rule has two leads, `rm *` (flags or other arguments first) and plain `rm`
(the operand first, no flag: a flagless `rm R/*` still deletes the root's top-level files, and
`rm ~/.*` the home dotfiles). `\*` is a literal star, and the only wildcards are the leading `rm *`
and the trailing ` *`, so a glob deeper down (`R/*/*/build`) or a selective one (`R/{a,b}.pdf`,
`R/*.log`) is not denied.

```
Bash(rm * R)       Bash(rm * R/)       Bash(rm * R/\*)       Bash(rm * R/\*/)       Bash(rm * R/\*\*)       Bash(rm * R/.\*)
Bash(rm * R *)     Bash(rm * R/ *)     Bash(rm * R/\* *)     Bash(rm * R/\*/ *)     Bash(rm * R/\*\* *)     Bash(rm * R/.\* *)
Bash(rm R)         Bash(rm R/)         Bash(rm R/\*)         Bash(rm R/\*/)         Bash(rm R/\*\*)         Bash(rm R/.\*)
Bash(rm R *)       Bash(rm R/ *)       Bash(rm R/\* *)       Bash(rm R/\*/ *)       Bash(rm R/\*\* *)       Bash(rm R/.\* *)
```

240 rules, generated by jq from one list. The list is the `allowWrite` list plus `~`, defined once
and used by both, so a root added to `allowWrite` gets its rm denies with it. A deny is silent and
cannot be answered with yes. A deny rule carries no reason of its own, so the instruction of §3.3
says that the roots are denied.

### 3.2 Remove the four ask rules

`Bash(rm -rf ~/*)`, `Bash(rm -rf /Users/michael/*)`, `Bash(rm -r ~/*)` and
`Bash(rm -r /Users/michael/*)` leave `permissions.ask`. A delete below a root then goes where every
other rm spelling already goes: the classifier when sandboxed, which can delete only inside the
writable roots; the built-in check when, by its own message, the target is one it cannot resolve
(a variable that could empty into `/`) or a home, system or workspace directory.

| Target | Today | After |
|---|---|---|
| A root or all its contents (§3.1 forms), `-rf`/`-r`, `~` or absolute | ask | deny |
| The same, `-fr`, `-R`, `-r -f`, `/bin/rm`, `command rm`, `$HOME/...` | classifier | deny |
| Below a root, `-rf`/`-r`, literal or resolved variable | ask | classifier (D1) |
| A root or all its contents through an alias: another case (`~/documents`), `..` (`~/Code/../Documents`), `//` or `/./`, a symlink, a name glob (`~/Do*`), a brace (`~/{Code,x}`), another glob (`R/?*`, `R/[!.]*`), `-rf`/`-r` | ask | classifier (D1) |
| Below a root or an alias, any other spelling | classifier | classifier |
| A variable target the matcher cannot resolve | built-in check | built-in check |

The ask rules matched every `-rf`/`-r` delete under a literal home prefix, so they also caught the
aliases. No deny list can: matching is case-sensitive and literal, and the alias forms are
unbounded.

### 3.3 One instruction: literal absolute paths in rm

Without the ask rules, the 17 variable-target deletes would meet the built-in check instead: a
prompt in a main session, a denial and a wasted turn in a subagent (already 24 in the window). Two
places carry one sentence, because Sonnet subagents act on a rule in their first turn, not in their
system prompt (memory `sonnet-ignores-agent-body-rules`):

- `.chezmoitemplates/agents/claude-code.md`, a bullet beside the path-resolution guard: name each
  `rm` target as a literal absolute path, never through a variable, loop or substitution; the roots
  are denied.
- the SubagentStart line in `dot_claude/hooks/executable_subagent-shell-context.sh`, which already
  says "Name every file by its absolute path": it adds that an `rm` target is a literal absolute
  path, never a variable.

### 3.4 Tests

- `tests/claude-settings.test.sh`: the expected ask set loses the four rules; the expected deny set
  gains the 240, built by the suite from its own copy of the root list; a section pins them by
  shape against the rule model. The model learns `\*` as a literal star, calibrated on fixture rows
  that mirror §2. Rows: every operand of every root is denied in both spellings, last and before
  another argument; `rm -rf <root>/sub`, `rm -rf ~/Code/*/*/build`, `rm -rf ~/Code/*/build`,
  `rm -f ~/Documents/{a,b}.pdf`, `rm -f ~/Documents/*.log`, a repository path, a scratchpad path and
  `rm -rf ~/Code/x/build` are not; no ask rule names `rm`.
- `tests/subagent-shell-context.test.sh`: its pinned line follows the new text.
- `tests/agent-instructions.test.sh`: the fragment stays within its 50-line cap.
- A live run (D2) of the rendered deny list through `claude -p`, with the modify script rendered
  under a throwaway `HOME` below the real one, so every absolute root is a throwaway directory and
  a `$HOME/...` spelling of it is too; the `~` spelling is covered by the §2 probe and the model
  rows, since a live `~` always names the real home.

## 4. Net prompt change

Over the 14 days measured: the ask rules' 44 prompts go to 0. If agents still write variable
targets, up to 9 come back as built-in prompts in main sessions (the 8 in subagents become
denials). Expected: 35 to 44 fewer prompts per 14 days, and fewer built-in denials in subagents.
The root denies matched none of the 1,071 calls, so they add no denial to ordinary work.

## 5. Limits

- The aliases of §3.2 (another case, `..`, `//`, `/./`, a symlink, a name glob such as `~/Do*`, a
  brace, a glob other than the six operands of §3.1) are not matched.
  Neither are `${HOME}/Code` and other `~` spellings (`~michael`). A root spelled through `${HOME}`
  empties into a top-level path, which the built-in check refuses by its own description; that was
  not measured on a real root, and is not, since a miss deletes it.
- A relative target (`rm -rf ../..`), `find -delete`, `xargs rm` and an interpreter
  (`shutil.rmtree`) reach the classifier, as every spelling the ask rules missed does today.
- Guards are frozen: nothing here touches a hook that decides.

## 6. Decisions

- **D1. What the ask rules caught that no deny can** moves from a prompt to the classifier: (i) a
  delete below a root but above ordinary work (a whole repository, an organisation directory, the
  vault folder under the iCloud root) and (ii) a root through an alias (§3.2), each when written
  `-rf`/`-r` with a literal or resolved home path. Options: (a) accept; (b) also deny, by name,
  `~/Code/Netronix`, `~/Code/ViuMore` and the vault's `Documents` folder (+144 rules, a static list;
  top-level repositories under `~/Code` and every alias stay with the classifier); (c) keep the four
  ask rules beside the denies, which keeps (i) and (ii) behind a prompt and keeps the 44 prompts:
  item 22 not done. Recommendation: (a). None of the 1,071 calls targeted (i) or (ii); all 44
  prompts were approved, the reflex the prompt budget exists to avoid; the same deletes in any
  other flag spelling already reach the classifier today; committed work has forge copies; the
  classifier refused even two scratchpad deletes. **Open: Michael's call** (it loosens a deletion
  boundary, so it is not ruled on delegation).
- **D2. Live check.** (a) one run before the PR, its result in the PR (the recorded probes of §2
  plus the rendered list); (b) also a committed canary, `tests/live-rm-denies.test.sh`
  (unsandboxed + model, skipped by default, run after each Claude Code upgrade like
  `live-deny-modes`). The design rests on four undocumented matcher behaviours (`\*` literal,
  `$HOME` expanded, `/bin/rm` and `command` normalised, wildcards crossing spaces); an upgrade that
  changes one silently drops a root deny. Recommendation: (b). **Ruled (b)**, 2026-11-14.
