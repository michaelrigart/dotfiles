# Safe autonomy: standing policies, enforcement, instruction layout

**Status:** Approved
**Date:** 2026-09-30
**Branch:** `feat/safe-autonomy`

## Goal

Let an agent carry a task from signed-off spec to Draft MR without Michael, while every
dangerous, destructive action is still stopped by the harness rather than by the model's
discretion. The three goals of the setup review are simplify, improve, and more safe
autonomy. This design covers the first slice of that work:
- the standing policies that remove needless stops;
- the enforcement those policies depend on;
- the instruction-file layout that carries the policies;
- the verified bugs found by the review.

**Prompt budget.** Only dangerous, destructive actions may ask. The preferred responses,
in order: a silent deny with a reason the agent can act on, then the auto-mode classifier,
then `ask`. Michael gets no more prompts than today.

## Baseline

Measured over 2026-09-16 to 2026-09-30: 41 main sessions, all in auto mode.
- 490 human turns after a session's first. About 35% were avoidable (hand-labelled,
  ±10%). They broke down as:
  - asks that had a standing answer: 50
  - Codex pane handling and relay: 68
  - cross-review triggered by Michael: 14
  - status checks: 22
  - deferrals: 12
  - mid-plan stalls: 7
- 1 explicit rejection and 2 interrupts in main sessions.
- Guard denials:
  - path-resolution: 89
  - xreview-apply: 3
  - xreview pre-merge: 2
  - forge: 1
  - worktree: 0
- 917 sandbox escapes, only 25 of them after a visible sandbox failure.
- 11% of xreview dispatches failed.
- Approved permission prompts are not visible in transcripts, so the prompt baseline
  starts with the audit log in §5.

## Decisions (Michael, 2026-09-30)

1. Agents may push feature branches and open Draft MRs without asking. Merge stays
   Michael's.
2. GitLab `main` protection is in place on the project repos: pushes are Maintainers only
   and force-push is off (verified on VM.Portal and curato). Maintainer pushes include
   Michael's own key, so a client-side push rule covers agents. No GitLab change.
3. The sandbox escape hatch stays open. Closing it would turn every blocked command into a
   `!` for Michael, and the classifier stays the backstop.
4. The live Codex view stays. xreview reliability (Option B) is a separate branch.
5. Agents rule on review trade-offs that stay inside the approved spec, recorded in the MR.
   Anything that would change the spec is escalated.
6. Codex reviews every plan, and the agent proceeds once Codex approves. Michael reviews a
   plan only when he asks to at spec sign-off.
7. The global instructions become tracked fragments. Only private details stay in
   1Password.
8. `wt-rm` is always Michael's and is never an autonomy target.

## Out of scope

These are separate branches, each with its own design:
- xreview Option B: reviews in their own Herdr tab, and the pane-record bug.
- The Herdr/wt simplification.
- The base-dotfiles cleanup.
- Project-repo instruction fixes (one MR per repo).
- Retiring guards, which waits for 30 days of data.
- Enforcement against habitual sandbox escapes (decision 3). The baseline number is kept
  for the evaluation only.
- Credential exposure through `docker run` bind mounts. Blocking it properly means parsing
  mount sources, including ancestors such as `-v $HOME:/host`, and it is the same class of
  risk as an unsandboxed command reading those paths. Decision 3 leaves that class to the
  classifier.

## 1. Enforcement

### 1.1 Push rule (`git-forge-guard.sh`, new rule 4)

**Recognising a push.** A git invocation in command position counts as a push when:
- it has any of these prefixes: environment assignments, `command`, `env [VAR=val…]`,
  `sudo`;
- it may carry git global options before the subcommand: `-C <path>`, `-c <k=v>`,
  `--git-dir=…`, `--work-tree=…`, `--no-pager` and the like;
- the subcommand is `push`, or an alias whose expansion (`git config alias.<name>`) starts
  with `push`. For example, the dotfiles define `pom = push origin main`.

`-C <path>` (and `--git-dir`/`--work-tree`) select the repository used for every
resolution below.

**Dry runs** (`--dry-run`, `-n`) are always allowed and never scanned.

**Supported configuration.** Rule 4 resolves pushes only under git's plain push
configuration. All 48 repositories under `~/Code` and the dotfiles, and the global git
config, use it (checked 2026-09-30):
- `push.default` unset, `simple` or `current`;
- no `remote.pushDefault`, `branch.<b>.pushRemote`, `remote.<r>.push` or
  `remote.<r>.mirror`;
- exactly one effective push destination, identical to the fetch destination. Checked
  with git itself: `git remote get-url --push --all <remote>` must print one URL, equal to
  `git remote get-url <remote>`. This covers `pushurl`, multiple `url` entries and
  `url.<base>.pushInsteadOf` rewrites;
- no `-c` option on the push invocation itself.

Anything else is a silent deny naming the key: "unsupported push configuration for the
push guard: <key>; push by hand or simplify the configuration". It never asks. Git's full
push-resolution precedence is deliberately not re-implemented.

**Resolving the target**, under that configuration:
- **Remote:** the one named in the command. Otherwise the current branch's `remote`, then
  `origin`.
- **Default branch:** read from `refs/remotes/<remote>/HEAD`, falling back to `main` and
  then `master`.
- **Destination:** explicit refspecs are parsed, and a source of `HEAD` resolves to the
  current branch. Without a refspec, the destination is the current branch's name; `simple`
  and `current` both push to the same name.
- Fetch and push URLs are the same, so the remote's tracking refs stand for what the
  destination already holds. The secret scan relies on this.

**Asks** when any of these hold:
- the destination is the default branch. This covers `git push origin main`,
  `git push origin HEAD:main`, `git pom`, and a bare `git push` or `git push <remote>`
  while on the default branch;
- it force-pushes without a lease: `--force`, `-f`, or a `+` refspec;
- it deletes remote refs: `--delete`, `-d`, a `:ref` refspec, or `--prune`;
- it uses `--mirror` or `--all`.

**Allowed silently:**
- pushes of other branches;
- `--force-with-lease` or `--force-if-includes` on a branch that is not the default
  branch;
- `--tags`.

**Denies silently** when gitleaks finds a secret in the outgoing commits:
- The scan is `gitleaks git --redact --log-opts="<local-refs> --not
  --remotes=<remote>"`, run in the resolved repository.
- Only the destination remote's history is excluded. A commit already published elsewhere,
  such as on a private remote, is still scanned before it reaches this one.
- The deny reason names the rule, file and commit, never the value.
- A false positive is resolved with a fingerprint in the repository's tracked
  `.gitleaksignore`, so the exception is reviewed like any other change.
- The scan fails closed. If gitleaks is missing or exits with an error other than
  "leaks found", the push is denied, with the remediation (`brew bundle`, or the gitleaks
  error) as the reason. gitleaks is declared in the Brewfile.

**Removed ask rules:** `Bash(git push --force*)` and `Bash(git push -f *)`. Ask rules are
absolute, so a hook cannot narrow them. Rule 4 replaces them, and `--force-with-lease` on a
feature branch stops asking.

### 1.2 Guard bypasses

`FORGE_GUARD=off` lifts rules 1 and 2 only, the behavioural ones. It never lifts rule 3
(`glab api` writes) or rule 4. `XREVIEW_GUARD=off` and `WT_GUARD=off` stay as they are;
they gate process, not danger.

### 1.3 Permission rules (settings template)

Ask and deny rules accept wildcards anywhere; verified against the 2.1.285 binary.

| Change | Rules | Response | Expected frequency |
|---|---|---|---|
| Secrets never enter the transcript | `Bash(op read*)`, `Bash(op item get*)`, `Bash(op document get*)`, `Bash(op inject*)`, `Bash(op run*)` | deny | rare |
| Lasting mail send-out paths | `mcp__claude_ai_Microsoft_365__outlook_create_filter`, `…__outlook_set_vacation` | deny | ~0 |
| Destructive Microsoft 365 actions | `…__outlook_batch_delete_messages`, `…__outlook_trash_thread`, `…__outlook_delete_event`, `…__sharepoint_delete_item` | ask | ~0 |
| Destructive Basecamp actions | `Bash(basecamp <resource> trash*)` and `Bash(basecamp <resource> delete*)` for each resource (projects, todos, todolists, messages, chat, cards, files, checkins, schedule, comments). Enumerated so that text arguments containing "delete" don't match | ask | ~0 |
| Infrastructure teardown | `Bash(helm uninstall*)`, `Bash(helm delete*)`, `Bash(az * delete*)`, `Bash(terraform destroy*)` | ask | ~0 |
| Remove a hole | the `Bash(chezmoi cat *)` allow. `chezmoi cat` runs unsandboxed through `op` and can render private keys; it goes back to the classifier | — | no prompt |

The existing destructive asks stay unchanged: `glab mr merge`, `sudo`, `git reset --hard`,
`git clean -f`, `git branch -D`, `git filter-branch`, `rm -r[f] ~`, `brew uninstall`,
`kubectl delete`, `borg`/`vorta`, `op item create/edit/delete`, `docker rm/rmi/prune`,
`docker volume rm`, `docker compose down`, `Read(~/.kube/config)`.

These stay with the classifier, with no prompts:
- feature-branch pushes and Draft MRs;
- Basecamp comments and cards;
- mail sends;
- `kubectl apply/exec/scale`;
- `chezmoi apply`;
- the learned `glab mr:*` allow in curato. `approve` and `close` aren't destructive, and
  `merge` keeps its own ask.

**Net prompt change:** fewer. `--force-with-lease` on a feature branch stops asking (3
times in the baseline), and every new ask covers actions seen 0 times in the baseline.

## 2. Standing policies

These go into the shared global instructions (§3). User instructions take precedence over
the superpowers skills, so these override their gates where the two differ.

1. **Asking.** Ask only for a real decision: a design choice, a trade-off outside the
   approved spec, or an irreversible action. Otherwise take the sensible default and say
   which one was taken.
2. **Execution.** Execution is always subagent-driven. Proceed to the next task or plan in
   a series without asking.
3. **Plans.** Codex reviews every plan, and execution starts once it approves. If Michael
   asked at spec sign-off to review the plan, stop after Codex approves. The plan's path
   always goes in the progress note.
4. **Brainstorming.** Present the whole design in one message. The written spec, reviewed
   by Codex and then signed off by Michael, is the hard gate.
5. **Cross-review.** Dispatch at every checkpoint without being asked. Commits after the
   last pre-merge receipt mean a new pre-merge review before reporting done.
6. **Rulings.** Rule on trade-offs inside the approved spec and record each one under
   "Rulings" in the MR description. Escalate only what would change the spec.
7. **Fix now.** In-scope findings are fixed in the same branch. No follow-up MRs unless
   Michael asks.
8. **Finishing.**
   - Push the feature branch.
   - Open a Draft MR where the repository uses MRs. For the dotfiles repo, pushing the
     branch is the end.
   - Show no finishing menus.
   - Never offer or run `wt-rm`, and never merge.
9. **Reporting.** Every final report ends with one state line: pushed, review receipt,
   open items, next step.
10. **Momentum.** Don't stop while the next step is already authorised. Send one phone ping
    when an unattended stretch ends or is blocked, not one per step.

## 3. Instruction layout

### 3.1 Files

| Path | Content | Rendered into |
|---|---|---|
| `.chezmoitemplates/agents/global.md` | Shared, tool-agnostic rules, including §2 | all three targets |
| `.chezmoitemplates/agents/claude.md` | Claude Code-only rules: sandbox specifics, subagent tiers, the recursive-`grep .` trap, the silent-wrong-answer tools | `~/.claude/CLAUDE.md` only |
| 1Password `Agent instructions` note | Private details only (expected: the backup specifics). If nothing private remains after the rewrite, the `op` render is removed | all three targets, where present |

- `dot_config/agents/GLOBAL.md.tmpl` and `dot_codex/AGENTS.md.tmpl` render the shared
  fragment plus the private part.
- `dot_claude/CLAUDE.md.tmpl` renders the shared fragment, the private part and the Claude
  addendum.
- `.chezmoitemplates/` is never deployed. The repository is public, so the fragments pass
  the §1.1 gitleaks scan and review like any other change.

### 3.2 Content rules for `global.md`

- Only rules a model cannot infer. No restating the harness:
  - no sandbox mechanics already in Claude Code's own prompt;
  - no `cd` rule already in the Bash tool description and enforced by
    `path-resolution-guard`.
- Machine, Backups and Design Records are cut to what is actionable. For example, Backups
  keeps "uncommitted work in a `wt` worktree is not backed up; checkpoint commits are the
  protection", plus a pointer to the vault note.
- The `superpowers:brainstorming step 6` reference is replaced by "at spec sign-off".
- The "Guardrails" push rule is replaced by §2.8 (policy 8). Destructive git operations stay
  confirm-first, and the harness enforces the confirmation (§1).
- Target sizes: `global.md` at most 180 lines, `claude.md` at most 50.

### 3.3 Other instruction files

- **Repository `AGENTS.md`:**
  - fix the stale "herdr 0.8.2" claim and the launcher claim (bug 1 below);
  - remove the restated design-records section;
  - add "other sessions switch branches in this shared checkout; re-check
    `git branch --show-current` right before each commit. Work here on a branch, not in a
    harness worktree: xreview needs the repository's own Codex pane";
  - replace the 1Password bullet with the §3.1 layout.
- **`dot_claude/agents/sp-*.md`:** drop the `cd`/`grep` bullet. Subagents receive the
  global instructions and the Bash tool description, and the guard enforces it.

## 4. Bug fixes

Each fix is its own commit, with a test where one can observe it.

1. **`dot_config/zsh/zshenv`:** run `brew shellenv` first, then prepend `~/.local/bin` and
   krew. Drop the `brew --prefix` calls in favour of `$HOMEBREW_PREFIX`. Fixes Homebrew's
   `codex` shadowing the launcher in interactive shells.
2. **Settings merge, inverted.** `modify_private_settings.json` starts from the live file
   and overrides only the keys chezmoi owns, then deletes a named list of retired keys
   (`includeCoAuthoredBy`, `voiceEnabled`). Runtime keys such as `modelSettings` and any
   future key now survive an apply. Also:
   - `cleanupPeriodDays` goes to 30;
   - the dead `defaultMode: "default"` literal is dropped;
   - model, effort, mode and style keep their seed-if-absent behaviour.
3. **Delete `subagent-statusline.sh`** and its `subagentStatusLine` key. It never rendered.
4. **`tests/run.sh`:** a filter bypasses the `# test-requires:` gate only on an exact suite
   name. Substring filters keep the gate.
5. **Codex:** remove the `features.js_repl` pin, which is removed in 0.159. Resync the
   vendored Claude Herdr hook to the version herdr 0.9.2 embeds.
6. **Shell history** moves from `$XDG_CACHE_HOME/zsh` to `$XDG_STATE_HOME/zsh`, which Borg
   backs up. The existing file is migrated once, on first shell start.
7. **xreview receipts** record the checkpoint (`dispatch --checkpoint
   spec|plan|pre-merge`). `xreview-guard.sh` then allows `glab mr create` / `gh pr create`
   only with a pre-merge receipt whose verdict is `approve` on this branch. HEAD stays
   unbound: every fix after a review moves HEAD, so binding it would demand a second review
   of each fix (see the comment above `record_receipt` in `xreview`). Policy 5 handles
   commits made after the last receipt. `SKILL.md` passes the flag.
8. **Ghostty `scrollback-limit`** is counted in bytes, so it is set in bytes. This is a
   one-line change; the file has uncommitted edits in the main checkout.

## 5. Evaluation

- **Prompt audit:** a `PermissionRequest` hook appends `{ts, session, cwd, tool,
  subcommand}` to `~/.local/state/agent-audit/prompts.jsonl`. It never decides, and it
  never logs full input, because command lines can hold secrets.
- **Retention:** `cleanupPeriodDays: 30` keeps enough transcript to measure.
- **Measurement:** `.scripts/measure-interventions.py` computes the mechanical baseline
  metrics from transcripts:
  - human turns;
  - guard and classifier denials;
  - sandbox escapes;
  - xreview failures;
  - autonomous stretch.

  Categorising avoidable turns stays a hand-labelling pass, the same as the baseline.
- **Review at +14 days after apply.** Success means:
  - the avoidable share is below 15%;
  - prompts per week are no higher than in the first week;
  - no unintended default-branch push, no pushed secret, and no destructive action without
    an ask.

## 6. Testing

All sandboxed suites pass, reported as passed/total.
- **`git-forge-guard.test.sh`:**
  - rule 4 recognition: `git -C <repo> push …`, `command git push …`, `env X=1 git push
    …`, `FORGE_GUARD=off git push …`, and an alias expanding to `push origin main`;
  - rule 4 decisions:
    - asks: default branch given explicitly, as `HEAD:main`, or bare while on the
      default branch; lease on the default branch; `+ref`; `:ref`; `--delete`; `--prune`;
      `--mirror`; `--all`;
    - silent: feature branch; lease on a feature branch; `--tags`; `--dry-run` to `main`;
    - silent deny, never ask: each unsupported key (`remote.pushDefault`, `pushRemote`,
      `remote.<r>.push`, `remote.<r>.mirror`, `push.default=upstream` or `matching`); a
      push destination that differs from the fetch destination (`pushurl`, a second
      `url`, `pushInsteadOf`); and a `-c` on the push;
  - the bypass does not lift rules 3 and 4;
  - gitleaks:
    - a deny against a secret fixture built at runtime, never committed;
    - a secret-bearing commit reachable only from a second remote's tracking refs is
      still scanned;
    - a missing gitleaks denies, via a PATH without it.
- **`claude-settings.test.sh`:**
  - the new deny and ask rules are present, and the removed rules are absent;
  - an unknown runtime key and `modelSettings` survive;
  - retired keys are gone;
  - the `PermissionRequest` hook is present;
  - `subagentStatusLine` is absent.
- **Instruction render test:** each of the three targets renders. The Codex target contains
  no Claude-only marker, and the fragments stay within their size limits.
- **`xreview` and `xreview-guard` suites:** the checkpoint is recorded; a spec or plan
  receipt does not satisfy the pre-merge gate; a `changes` verdict does not satisfy it.
- **`run.sh`:** a substring filter keeps the gate, and an exact name bypasses it.
- **zshenv:** in a clean interactive zsh, `type -a codex` lists `~/.local/bin/codex` first.

## 7. Rollout

- **Commit order on the branch:** enforcement (§1), then bug fixes (§4), then the
  evaluation instruments (§5), then the instruction layout and policies (§2, §3). A partial
  application therefore never loosens a stop before its enforcement exists.
- Michael merges and runs `chezmoi apply`. After that he can remove the retired `op` render
  from the 1Password note.
- **Rollback:** revert the merge commit and apply.

## Risks

- **Wildcard ask and deny rules can match free text in arguments.** The Basecamp rules are
  enumerated for this reason, and the others match verbs that rarely appear in text.
- **gitleaks false positives block a push,** and the fix is a reviewed `.gitleaksignore`
  entry. That is deliberate friction on the one outward path with irreversible leakage.
- **Looser stops rely on the rest holding:** enforcement, the receipt gate and the
  evaluation. If §5's success criteria fail, the policies are revised before the next
  slice, not after.
