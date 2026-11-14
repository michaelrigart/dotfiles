# rm root denies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: load the `plan-run` skill and run this plan with it (it overrides superpowers:subagent-driven-development). Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress

**Goal:** Deny `rm` of `~` and every sandbox write root in every operand form, tell agents to write
rm targets as literal absolute paths, add a live canary for the matcher, and (gated on D1) drop the
four rm ask rules.

**Architecture:** One root list in the jq program of `dot_claude/modify_private_settings.json`
feeds both `sandbox.filesystem.allowWrite` and 240 generated `Bash(rm …)` deny rules. The
instruction goes in the Claude Code fragment and the SubagentStart line. A new live suite renders
the modify script under a throwaway `HOME` and drives `claude -p` against throwaway roots.

**Tech Stack:** bash 3.2 and jq (the modify script), bash test suites, `claude -p`.

**Spec:** `docs/superpowers/specs/2026-11-14-rm-exact-denies-design.md` (§3.1 to §3.4, §6).

## Global Constraints

- Roots, in this order: `~`, `~/Code`, `~/.local/share/chezmoi`, `~/Documents`,
  `~/Library/Mobile Documents/iCloud~md~obsidian`. The last four are exactly `allowWrite`.
- Each root R is written twice: the `~` form, and `$HOME` + the part after `~` (the modify script
  takes `--arg home "$HOME"`). Never a hardcoded `/Users/michael` in the source.
- Operands per R: `R`, `R/`, `R/\*`, `R/\*/`, `R/\*\*`, `R/.\*`; each rule is
  `Bash(<lead><R><operand>)` and `Bash(<lead><R><operand> *)` for each lead `rm * ` and `rm `
  (amended after the Task 1 review: `rm * R` does not deny a flagless `rm R/*`). 24 per path, 240
  in all, appended after the existing deny rules.
- In a rule, `\*` is a literal star; the only wildcards are the `*` of the `rm * ` lead and the
  trailing ` *`.
- The jq program is one single-quoted shell string: no apostrophe anywhere in it, and no backslash
  in a jq comment.
- Guards (deciding PreToolUse hooks) are not touched. `global.md` is not touched.
  `claude-code.md` stays within 50 lines.
- The repository is public: no private names beyond what the files already hold.
- **D1 is open (Michael's).** Task 4 does not start until the driver relays his answer. Tasks 1 to 3
  keep the four rm ask rules exactly as they are.

## Review Focus

- A root's own sibling with a longer name (`~/.local/share/chezmoi-fix-x`, `~/Code2`,
  `~/Documents.bak`) is not denied: the rules end at an operand boundary (Task 1, rows NO).
- A glob deeper than the first level or a selective glob/brace (`~/Code/*/*/build`,
  `~/Code/*/build`, `~/Documents/*.log`, `~/Documents/{a,b}.pdf`) is not denied (Task 1, rows NO).
- A root as a non-last argument (`rm -rf ~/Code /tmp/x`) is denied (Task 1, rows YES).
- The vault root's space survives rendering and matching (Task 1 rows; Task 3 live case).
- The live canary never touches a real root: every command it sends names a path under its
  throwaway home `H`, and `$HOME/...` commands resolve under `H` (Task 3). A denial it records
  counts only when the same command without the rules deletes (Task 3, BARE runs).

---

### Task 1: Generate the root denies

**Depends on:** none

**Files:**
- Modify: `dot_claude/modify_private_settings.json:67-72` (jq args), `:78-111` (the `as` bindings
  before `$live + {`), `:169-232` (deny), `:506-519` (allowWrite and its comment)
- Test: `tests/claude-settings.test.sh` (`EXP_DENY` at `:60-90` and its comparison at `:130`, the
  rule model at `:184-190`, the model calibration at `:212-223`, a new section `T.`)

**Interfaces:**
- Produces: `$write_roots` (the four allowWrite entries) and `$rm_roots` (`["~"] + $write_roots`)
  in the jq program; Task 4 (b) appends to `$rm_roots`. The 240 rules sit at the end of
  `.permissions.deny`, and are the only deny rules starting `Bash(rm `.

- [ ] **Step 1: Teach the suite's rule model a literal star**

In `MATCHES` (`:184-190`), `hit` splits the rule on the two characters `\*`, turns each other `*`
into `.*`, escapes the rest, and joins the parts with the regex for a literal star. Calibration rows
beside the existing ones (`:212-223`), on a fixture with `Bash(rm * /r/\*)` and
`Bash(rm * /r/\* *)` in `deny`:

```bash
d_is 'rm -rf /r/*'        yes "model: \\* is a literal star"
d_is 'rm -rf /r/* /x'     yes "model: a trailing ' *' takes more arguments"
d_is 'rm -rf /r/sub'      no  "model: \\* does not match a name"
d_is 'rm -rf /r/*/*/b'    no  "model: the operand ends at a space or the end"
```

- [ ] **Step 2: Write the failing section T**

`echo "T. rm: every root is denied in every operand form"`, after `emit '{}'`:

- The suite's own copy of the roots (the five above) builds `RM_PATHS` (both spellings, with
  `$HOME`) and the expected 240 rules; `EXP_DENY` at `:130` is compared as `EXP_DENY` + those.
- `jq_is` that `allowWrite` equals the four write roots and that the rm deny rules number 240.
- `jq_is` that no rm deny rule has a `*` other than the leading `rm *`, an escaped `\*`, or a
  trailing ` *`.
- YES rows (`d_is … yes`), for every path P in `RM_PATHS`: `rm -rf P`, `rm -fr P/`,
  `rm -r -f P/*`, `rm -rf P/*/`, `rm -rf P/**`, `rm -rf P/.*`, and `rm -rf P /tmp/x`,
  `rm -rf /tmp/a P/* /tmp/b`.
- NO rows (`d_is … no`): `rm -rf P/sub` for every P; `rm -rf ~/Code/*/*/build`,
  `rm -rf ~/Code/*/build`, `rm -f ~/Documents/*.log`, `rm -f ~/Documents/{a,b}.pdf`,
  `rm -rf ~/Code/x/build`, `rm -rf $HOME/.local/share/chezmoi-fix-x`, `rm -rf ~/Code2`,
  `rm -rf ~/Documents.bak`, `rm -rf /private/tmp/claude-501/x/scratchpad/m1`, `rm -f ~/.zshrc`.
  (Write each `~` row once in `~` form and once with `$HOME` expanded by the suite.)

Run: `./tests/claude-settings.test.sh` — Expected: section T and the `:130` comparison FAIL; the
model calibration rows PASS.

- [ ] **Step 3: Generate the rules in the modify script**

Add `--arg home "$HOME"`. Before `$live + {`, bind `$write_roots` and `$rm_roots`, and
`$rm_denies`: for each R in `$rm_roots`, for each of R and `$home + R[1:]`, for each operand of the
Global Constraints, for each tail in `("", " *")`, the string `"Bash(rm * " + path + operand +
tail + ")"`. `allowWrite` becomes `$write_roots`; `deny` becomes the existing list `+ $rm_denies`.
A comment above the deny rules (no backslash, no apostrophe) says why: the roots, both spellings,
the operand boundary, the measured matcher facts, and the spec path.

- [ ] **Step 4: Run the suite**

Run: `./tests/claude-settings.test.sh` — Expected: every row passes; the totals line shows 0
failed.

- [ ] **Step 5: Commit**

```bash
git add dot_claude/modify_private_settings.json tests/claude-settings.test.sh
git commit -m "Deny rm of the home directory and every sandbox write root"
```

---

### Task 2: Literal absolute paths in rm

**Depends on:** none

**Files:**
- Modify: `.chezmoitemplates/agents/claude-code.md` (a bullet after the Path-resolution guard,
  `:12-14`)
- Modify: `tests/fixtures/agent-instructions/rules.tsv` (one row after `cc-path-guard`)
- Modify: `dot_claude/hooks/executable_subagent-shell-context.sh` (`line=` and the header comment)
- Test: `tests/subagent-shell-context.test.sh:23` (`LINE`), `tests/agent-instructions.test.sh`

- [ ] **Step 1: Pin the new text in the tests**

`rules.tsv` row (tab-separated):
`cc-rm-targets`, `.chezmoitemplates/agents/claude-code.md`, `` **`rm` targets.** ``, `yes`,
``Name each target as a literal absolute path, never through a variable, a loop or a substitution: Claude Code's removal check refuses a target it cannot resolve.;`~` and every sandbox write root are denied, with all their contents.``,
`rm targets are literal absolute paths; the roots are denied`.

`LINE` in `tests/subagent-shell-context.test.sh` becomes:
``Shell: every Bash call starts fresh in the session's directory and a `cd` never carries over, so never begin a command with `cd` (the path guard denies it). Name every file by its absolute path, and write each `rm` target as a literal absolute path, never a variable.``

Run: `./tests/agent-instructions.test.sh` and `./tests/subagent-shell-context.test.sh` —
Expected: the new rule row and the line rows FAIL.

- [ ] **Step 2: Write the bullet and the line**

The bullet, wrapped at 100 columns like its neighbours:
``- **`rm` targets.** Name each target as a literal absolute path, never through a variable, a loop or a substitution: Claude Code's removal check refuses a target it cannot resolve. `~` and every sandbox write root are denied, with all their contents.``
The hook's `line=` takes the `LINE` text above; its header comment adds that the `rm` clause comes
from spec `2026-11-14-rm-exact-denies` §3.3 and was not part of the measured line.

- [ ] **Step 3: Run both suites**

Run: `./tests/agent-instructions.test.sh` and `./tests/subagent-shell-context.test.sh` —
Expected: 0 failed; `claude-code.md` at most 50 lines.

- [ ] **Step 4: Commit**

```bash
git add .chezmoitemplates/agents/claude-code.md tests/fixtures/agent-instructions/rules.tsv \
  dot_claude/hooks/executable_subagent-shell-context.sh tests/subagent-shell-context.test.sh
git commit -m "Tell agents to write rm targets as literal absolute paths"
```

---

### Task 3: Live canary for the root denies

**Depends on:** Task 1 (it renders the deny rules Task 1 generates)

**Files:**
- Create: `tests/live-rm-denies.test.sh` (mode 755, `#!/usr/bin/env bash`)
- Modify: `.scripts/test-audit/subjects.tsv` (add `live-rm-denies` to the `loaded_by` of
  `dot_claude/modify_private_settings.json`)
- Modify: `tests/missing-subject.test.sh` (one row: the modify script hidden, the canary exits 2
  before any model call)
- Modify: `AGENTS.md` (the gated-suites table: a `live-rm-denies` row beside `live-deny-modes`)

**Interfaces:**
- Consumes: the rendered `.permissions.deny` of Task 1, taken as the rules containing `$H`.

- [ ] **Step 1: Write the suite**

Header: `# test-requires: unsandboxed, model`, a comment naming what it proves (the spec's §2
matcher facts on the rendered list) and "run after each Claude Code upgrade".

- Guards, exit 2: `claude`, `jq` or the modify script missing.
- `wrap=$(mktemp -d "$HOME/.cache/live-rm-denies.XXXXXX")`, `H=$wrap/home` (the rendered home).
  `wrap` is every run's working directory, so `H` is never the session directory (the built-in
  check guards that) and every path a case names is inside the working directory (a path outside
  it draws a denial of its own). Render with
  `printf '{}' | HOME="$H" PATH="<dir with an op stub that exits 1>:$PATH" /bin/bash <modify script>`;
  keep the deny rules that contain `$H` (`EXPECT_RULES=120`; another count is a FAIL of its own).
- Overlays: RULES = `{"permissions":{"allow":["Bash(rm:*)"],"deny":<those rules>}}`, BARE =
  `{"permissions":{"allow":["Bash(rm:*)"]}}`. Before every run, recreate the tree under `H`, each
  directory holding a file `f`: `Code/x`, `.local/share/chezmoi/x`, `Documents/x`,
  `Library/Mobile Documents/iCloud~md~obsidian/x`, `.hidden`; plus a top-level file
  `Documents/top`. A run is
  `claude -p "Run exactly this one Bash command, verbatim, once, and nothing else: <cmd>"` from
  `wrap` with `--setting-sources project --settings <overlay> --permission-mode auto
  --output-format stream-json --verbose --max-turns 2 --max-budget-usd 0.5 --no-session-persistence
  --model haiku`. From the stream it keeps the `input.command` of every `tool_use` block named
  `Bash` in the `assistant` events, and the `permission_denials` of the final `result` event.
- A run is faithful when it sent exactly one Bash command and that command equals the requested
  one byte for byte, and, under RULES, every recorded denial names that same command. A run that
  is not faithful (a rewrite, an expanded `$HOME`, an extra command) makes its case INCONCLUSIVE,
  since it no longer tests the spelling the case is about.
- Over-match control: `rm -rf <H>/Code/x` under RULES must remove `Code/x/f`; otherwise
  INCONCLUSIVE, exit 2, no case run.
- Each deny case is run twice, with BARE and with RULES, and names its sentinels (files under `H`):

  | Command | Sentinels |
  |---|---|
  | `rm -rf <H>/Code` | `Code/x/f` |
  | `rm -fr <H>/.local/share/chezmoi/` | `.local/share/chezmoi/x/f` |
  | `rm -r -f <H>/Documents/*` | `Documents/x/f` |
  | `/bin/rm -rf "<H>/Library/Mobile Documents/iCloud~md~obsidian"` | `Library/Mobile Documents/iCloud~md~obsidian/x/f` |
  | `command rm -rf $HOME/<H relative to HOME>/Code/ <H>/Documents/x` | `Code/x/f`, `Documents/x/f` |
  | `rm -rf <H>/Documents/**` | `Documents/x/f` |
  | `rm -rf <H>/.*` | `.hidden/f`, `.local/share/chezmoi/x/f` |
  | `rm -rf <H>` | `Code/x/f` |
  | `rm <H>/Documents/*` (flagless) | `Documents/top` |

  Verdict, for a case whose two runs were both faithful: ok when the BARE run removed every
  sentinel and the RULES run kept every one and recorded a denial of the command. FAIL when the
  BARE run removed them and the RULES run removed any. INCONCLUSIVE otherwise, with the reason: a
  BARE run that removed nothing means something other than the rules refuses that command, so a
  RULES denial proves nothing. The over-match control also has to be faithful.
- Output `  ok  <case>` / `  FAIL <case> (<why>)` / `INCONCLUSIVE: <case>: <why>`; exit 1 on any
  FAIL, else 2 on any INCONCLUSIVE, else 0. Remove `wrap` on exit. About 19 haiku runs.

- [ ] **Step 2: Wire it**

The `subjects.tsv`, `missing-subject` and `AGENTS.md` rows above. Run:
`./tests/missing-subject.test.sh`, `./tests/run.test.sh` and `./tests/agent-instructions.test.sh`
(it reads `AGENTS.md`) — Expected: 0 failed each. Do not run the canary itself in this task: it
needs the sandbox off and model calls, which the controller runs at the end.

- [ ] **Step 3: Commit**

```bash
git add tests/live-rm-denies.test.sh .scripts/test-audit/subjects.tsv tests/missing-subject.test.sh AGENTS.md
git commit -m "Add a live canary for the rm root denies"
```

---

### Task 4: Drop the four rm ask rules (GATED on D1)

**Depends on:** Task 1, Task 3 (for (b), which edits the canary), and Michael's D1 answer relayed
by the driver. Do not start without it.

**Files:**
- Modify: `dot_claude/modify_private_settings.json:252-253` (the two ask lines)
- Modify: `tests/claude-settings.test.sh:108-109` (`EXP_ASK`), `:666-685` (the section G comment
  and the danger-gate loop entry `Bash(rm -rf ~/*)`), section T
- Modify: the spec §6 D1 (his answer, dated) and, for (b), §3.1
- Modify, for (b) only: `tests/live-rm-denies.test.sh` (`EXPECT_RULES=192`, the tree and one case)

- [ ] **Step 1: Failing rows**

Section G: replace the `Bash(rm -rf ~/*)` loop entry with `jq_is` that no ask rule starts with
`Bash(rm `; rewrite the `:677-680` comment to say the root denies replaced the rm asks (spec path).
`EXP_ASK` loses the four rules. For D1 (b) also: the roots gain `~/Code/Netronix`,
`~/Code/ViuMore` and `~/Library/Mobile Documents/iCloud~md~obsidian/Documents` (rm denies only,
never `allowWrite`); the count becomes 384; YES rows for each; NO row
`rm -rf ~/Code/Netronix/curato`. In the canary, for (b): `EXPECT_RULES=192`; the tree gains
`Code/Netronix/r/f`; a case `rm -rf <H>/Code/Netronix` with sentinel `Code/Netronix/r/f`; the
over-match control becomes `rm -rf <H>/Code/Netronix/r` (it must still delete).
Run: `./tests/claude-settings.test.sh` — Expected: those rows FAIL.

- [ ] **Step 2: Implement**

Delete the two ask lines. For (b) only, bind `$rm_dirs` (the three) and generate from
`$rm_roots + $rm_dirs`, and make the canary changes of Step 1.

- [ ] **Step 3: Run and commit**

Run: `./tests/claude-settings.test.sh` (and, for (b), `bash -n tests/live-rm-denies.test.sh`;
the controller runs the canary itself) — Expected: 0 failed. For (b), add
`tests/live-rm-denies.test.sh` to the `git add` below.

```bash
git add dot_claude/modify_private_settings.json tests/claude-settings.test.sh docs/superpowers/specs/2026-11-14-rm-exact-denies-design.md
git commit -m "Drop the rm ask rules the root denies replace"
```

---

## Finish (controller)

1. `./tests/live-rm-denies.test.sh` with the sandbox off (it needs model calls and writes
   `~/.cache`); quote its lines in the PR.
2. Preview: `command chezmoi --source ~/.local/share/chezmoi-fix-rm-exact-denies cat ~/.claude/settings.json`
   piped through `jq 'del(.env.GH_TOKEN, .env.GITLAB_TOKEN) | .permissions'`, never whole.
3. `./tests/run.sh --changed`, then the Codex pre-merge review, then the PR (merge-request skill).
