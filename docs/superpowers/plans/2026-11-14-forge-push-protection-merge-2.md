# Forge push protection, merge 2: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress

**Goal:** Land revision 2 of the spec up to, and not including, the retirement: no machine-account
plumbing, the pull-request target for GitHub in `forge-protection check`, and the pull-request flow
for the dotfiles in the instructions.

**Architecture:** Three independent edits to code that merge 1 put on `main`. Nothing here touches
`dot_claude/git-push-guard.py` or `dot_claude/executable_git-forge-guard.sh`: no verdict of rule 4
changes, and the retirement is merge 3 with its own plan.

**Tech stack:** bash, jq, the suites under `tests/` run through `./tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-11-12-forge-push-protection-design.md`, revision 2 (signed
2026-11-14): sections 1.1, 2.1, 4.3, 6 and the final section "Revision 2".

## Global constraints

- No guard file changes: `git diff main...HEAD -- dot_claude/git-push-guard.py
  dot_claude/executable_git-forge-guard.sh tests/git-forge-guard.test.sh` stays empty.
- No forge is touched; `forge-protection.sh` is run only through its mocked suite.
- This repository is public: no private host, organisation, client or repository name in code,
  tests or documents. Fixtures use invented names.
- No change adds a permission prompt.
- `GH_TOKEN` and `GITLAB_TOKEN` handling in `dot_claude/modify_private_settings.json` stays as it
  is. `ssh-sandbox-proxy` and the session's `GIT_SSH_COMMAND` predate merge 1 and stay.
- `.chezmoitemplates/agents/global.md` is at its limit of 150 lines: an edit there adds no line.
- Test behaviour, not wording; extend a case before adding one. A removed feature's rows are
  deleted, not skipped.
- The Bash guard refuses a command line that holds both the word git and the word that names
  sending commits (file names and this checkout's path count): use the Read and Edit tools for
  such files, relative paths, and a character class in shell globs.
- Commit messages: imperative, no agent attribution.

## Review focus

1. A GitHub repository whose `pull_request` rule comes only from a ruleset with a bypass actor
   must read `drift`, never `ok`: the admin on the bypass list is the agent. Task 2 pins it.
2. A ruleset that is not active (`evaluate`, `disabled`) carries nothing. Task 2 pins it for
   `pull_request`.
3. The printed POST must be safe to paste into zsh for a default branch name with a quote or an
   `=`. The existing quoting rows cover `protect-main`; Task 2 keeps one for the new body.
4. With the `-F` branch gone, `ssh-sandbox-proxy` must pass exactly the arguments it got to
   `/usr/bin/ssh`, with and without a proxy. Task 1 keeps the existing pass-through rows green.
5. A leftover `~/.config/agent-identity/ssh_config` on a machine that applied merge 1 must not be
   read by anything. Task 1 pins that the proxy never passes `-F`, file present or not.

---

### Task 1: Remove the machine-account plumbing

**Depends on:** nothing.

**Files:**
- Delete: `dot_config/agent-identity/ssh_config`, `private_dot_ssh/private_github-agent.pub.tmpl`
- Modify: `dot_local/bin/executable_ssh-sandbox-proxy` (the `agent_config` / `agent_args` lines and
  both uses), `dot_claude/modify_private_settings.json` (the `allowRead` entry
  `~/.ssh/github-agent.pub`), `.scripts/test-audit/subjects.tsv` (the two rows)
- Test: `tests/ssh-sandbox-proxy.test.sh`, `tests/claude-settings.test.sh`,
  `tests/live-agent-auth.test.sh`, `tests/ssh-credential-inventory.test.sh`,
  `tests/missing-subject.test.sh` if it names either deleted file

**Interfaces:** Produces: `ssh-sandbox-proxy` with no `-F`; `live-agent-auth` prints no
`GITHUB_SSH` key and keeps `GITLAB_SSH`.

- [ ] **Step 1: Turn the proxy rows first.** In `tests/ssh-sandbox-proxy.test.sh`, replace the
  section that renders the agent configuration and key template (everything that reads
  `CFG_SRC`, `KEY_TPL`, `agent-identity` or `github-agent.pub`, including the guard on
  `CFG_SRC_GUARD`) with two rows: with a readable `$HOME/.config/agent-identity/ssh_config` and
  `$HOME/.ssh/github-agent.pub` in the fixture home, the arguments the stub `ssh` receives hold no
  `-F`, without a proxy and with one. Run `./tests/run.sh ssh-sandbox-proxy`: both new rows FAIL.
- [ ] **Step 2: Remove the code.** Delete the two files; drop `agent_config`, `agent_args` and
  their two expansions from the proxy; drop the `allowRead` entry. Run the suite: all pass.
- [ ] **Step 3: Follow in the other suites.** `claude-settings`: delete the rows about the agent
  SSH configuration's readability and the `~/.ssh/github-agent.pub` entry, and take
  `GitHub Agent SSH Key` out of the item fixtures (`ITEMS_BOTH`, `ITEMS_GH`); the token rows stay.
  `live-agent-auth`: delete the `GITHUB_SSH` probe and its precondition; `GITLAB_SSH` stays.
  `ssh-credential-inventory`: revert its list to what `git show 1ca66ad^1` had if merge 1's only
  change there was the agent key (check with `git log -p`); otherwise remove just that entry.
  `subjects.tsv`: delete the two rows. `rg -n 'github-agent|agent-identity|GITHUB_SSH|GitHub Agent
  SSH' dot_claude dot_config dot_local private_dot_ssh tests .scripts AGENTS.md` prints only the
  two stale-file rows of Step 1 in `tests/ssh-sandbox-proxy.test.sh` (their fixture paths), and
  nothing else.
- [ ] **Step 4: Run** `./tests/run.sh ssh-sandbox-proxy claude-settings hook-path run
  missing-subject`. Expected: all pass (`live-agent-auth` and `ssh-credential-inventory` are gated;
  read their diffs instead).
- [ ] **Step 5: Commit** "Remove the GitHub machine-account plumbing".

### Task 2: The pull-request target in `check_github`

**Depends on:** nothing.

**Files:**
- Modify: `.scripts/forge-protection.sh` (`body_protect_main`, `body_main_owner_only`,
  `check_github`, and the comments that describe the GitHub target)
- Test: `tests/forge-protection.test.sh` (the GitHub section)

**Interfaces:**
- `body_protect_main <ref>`: the ruleset of spec section 2.1, compact JSON: name `protect-main`,
  `bypass_actors: []`, rules `deletion`, `non_fast_forward` and `pull_request` with parameters
  `required_approving_review_count: 0`, `dismiss_stale_reviews_on_push: false`,
  `require_code_owner_review: false`, `require_last_push_approval: false`,
  `required_review_thread_resolution: false`, `allowed_merge_methods: ["merge"]`. Its `<ref>`
  stays `refs/heads/<default>` as today.
- `body_main_pr_only`: name `main-pr-only`, `bypass_actors: []`, include `~DEFAULT_BRANCH`, the
  `pull_request` rule alone with the same parameters.
- `body_main_owner_only` is deleted.

Target, as `check_github` judges it: each of `deletion`, `non_fast_forward` and `pull_request`
appears in the branch's rules from at least one **closed** ruleset: active, with `bypass_actors`
shown and empty. The fallback on `current_user_can_bypass == "never"` goes: it says only that
this login cannot bypass, not that the list is empty. A ruleset that carries one of the three
rules and does not show `bypass_actors` makes the row `unreadable` ("ruleset <id> does not show
its bypass list to this login; run the check with the owner's login").
`update` and `creation` are no longer read. `owner`, `oo`, `uc`, `blocker`, `owner_post` and the
"blocks the owner's direct push" note go.

Printed for `drift`:
- no ruleset carries `deletion` and `non_fast_forward` together: the POST of `body_protect_main`
  (it brings `pull_request` too), and nothing else;
- such a ruleset exists but `pull_request` has no closed carrier: the POST of `body_main_pr_only`,
  unless a ruleset already carries `pull_request` (then only its UI note);
- per ruleset that carries one of the three rules and is not closed: the existing UI note,
  `in the UI: https://github.com/<repo>/rules/<id>: Enforcement Active, bypass list none`.

- [ ] **Step 1: Write the failing rows** in the GitHub section, reusing its helpers and fixtures:
  1. `deletion`, `non_fast_forward`, `pull_request` from one closed ruleset: `ok`, exit 0;
  2. the first two from one closed ruleset, `pull_request` from a second closed one: `ok`;
  3. `protect-main` closed with the first two, no `pull_request`: `drift`, the output holds
     `"name":"main-pr-only"` and `"type":"pull_request"`, no `"name":"protect-main"`;
  4. no ruleset: `drift`, one POST, it holds `"name":"protect-main"`, `"type":"pull_request"`,
     `"allowed_merge_methods":["merge"]`; the output holds no `main-owner-only`, no `"update"`;
  5. `pull_request` only from a ruleset whose bypass list holds the admin role: `drift`, a UI note
     with `bypass list none`, no second POST;
  6. `pull_request` only from a ruleset with enforcement `evaluate`: `drift`;
  7. all three closed plus an active `update` rule from any ruleset: `ok` (it is not read);
  8. a ruleset carrying `pull_request` whose answer has no `bypass_actors` and
     `current_user_can_bypass: "never"`: `unreadable`, never `ok`, exit 1.
  Run `./tests/run.sh forge-protection`: rows 1 to 8 FAIL (row 4 at least on `pull_request`).
- [ ] **Step 2: Implement** the target above. Run: rows 1 to 8 pass.
- [ ] **Step 3: Remove what the old target pinned.** Delete every row about `main-owner-only`,
  owner-only carriers, bypass mode `always`, the merged ruleset and "blocks the owner's direct
  push"; adapt the rows that expected two POSTs to the one. Keep the unreadable, pagination,
  quoting and control-character rows; keep one quoting row whose POST is the new body. The
  no-write-verb row at the end of the suite must still pass unchanged.
- [ ] **Step 4: Run** `./tests/run.sh forge-protection`. Expected: all pass. Report the suite's
  line count before and after.
- [ ] **Step 5: Commit** "Judge pull requests only as the GitHub target".

### Task 3: The pull-request flow for the dotfiles in the instructions

**Depends on:** Task 1 (`AGENTS.md` is edited here only, after Task 1's `rg` shows only its two fixture rows).

**Files:**
- Modify: `.chezmoitemplates/agents/global.md` (the Finishing rule),
  `tests/fixtures/agent-instructions/rules.tsv` (row `g-finishing`), `AGENTS.md`
- Test: `tests/agent-instructions.test.sh` (through the fixture; no new assertion)

- [ ] **Step 1: The fixture first.** In `rules.tsv`, row `g-finishing`: replace the sentence "For
  the dotfiles, the pushed branch is the end." with "For the dotfiles, open the PR ready for
  review; Michael merges it." Run `./tests/run.sh agent-instructions`: FAIL on that row.
- [ ] **Step 2: The rule.** In `global.md`, the Finishing bullet becomes: "Push the feature branch
  and open a Draft MR where the repository uses MRs. For the dotfiles, open the PR ready for
  review; Michael merges it. Show no finishing menus, and never merge." It must still fit its two
  lines; the file stays at 150 lines or fewer. "Pushing to the default branch" in "Every agent
  confirms first" is **not** touched (merge 3). Run the suite: pass.
- [ ] **Step 3: `AGENTS.md`.** In Rules, where the main checkout and `wt` checkouts are described,
  add the flow of spec section 4.3 in at most six lines: a line ends with its branch pushed and a
  pull request against `main`, opened with `gh pr create` after the pre-merge review, assigned to
  Michael; no agent merges it or pushes `main`; Michael merges from his own terminal with
  `gh pr merge <number> --merge --match-head-commit <sha>`, then
  `git -C ~/.local/share/chezmoi pull --ff-only`, then `chezmoi apply`. In the `forge-protection`
  paragraph nothing changes. Remove any sentence Task 1 left that names the agent SSH key.
- [ ] **Step 4: Run** `./tests/run.sh agent-instructions`. Expected: pass.
- [ ] **Step 5: Commit** "Land dotfiles lines through a pull request Michael merges".

### Task 4: Full run and Status

**Depends on:** Tasks 1 to 3.

- [ ] **Step 1:** `./tests/run.sh --changed`. Record passed/total per suite and the `needs:` lines
  of the heavy ones. `git-forge-guard` must read "no subject changed".
- [ ] **Step 2:** `git diff main...HEAD --stat -- dot_claude/git-pu[s]h-guard.py
  dot_claude/executable_git-forge-guard.sh tests/git-forge-guard.test.sh` prints nothing.
- [ ] **Step 3:** Set this plan's Status to `Implemented (merge 2, branch
  feat/forge-push-protection)` with the banner "Completed on <date>. Do not run this plan again;
  merge 3 has its own plan." The spec stays `In progress`. Commit "Record merge 2 of the forge
  protection plan as implemented".

## Rulings

- 2026-11-14, plan review: a ruleset whose bypass list is not shown is `unreadable`, where the
  spec's revision 2 let `current_user_can_bypass: "never"` stand in for an empty list. Tightened
  on Michael's delegation to the driver (he is away); spec section 3 carries the sentence. Cost:
  a check run with a login that is not shown the lists cannot read a GitHub row `ok`; his own
  run, the one the verification uses, is not affected.

## Left for Michael after the apply

`rm -r ~/.config/agent-identity` (merge 1 deployed its `ssh_config`; nothing reads it after this
merge, and `chezmoi apply` does not remove a file whose source is gone). Then steps 8 to 13 of
`docs/superpowers/plans/2026-11-12-forge-push-protection-michael-steps.md`.
