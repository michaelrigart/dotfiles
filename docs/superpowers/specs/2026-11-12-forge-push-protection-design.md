# Push protection moves to the forge

**Status:** In progress
**Date:** 2026-11-12
**Branch:** `feat/forge-push-protection`

Item 35 of the 2026-11-11 setup review, decided by Michael on 2026-11-12. Signed off by Michael
on 2026-11-12 in the line's own session, in two answers to stated recommendations, each "I follow
your recommendation(s)": first for the split identity (approach C below) and the retirement of
the spelling hunt on every remote, then for pushing the dotfiles' `main` himself (section 4.3).
The handoff of section 4.3 was corrected after his second answer, from a `!` command to his own
terminal, and he was told. Codex approved the spec in review round 5 (`xr-1794522145-9b1396e4`). It replaces the threat model of
[spec 2026-10-29](2026-10-29-push-guard-escaped-spellings-design.md), section 7, and changes rule 4
of [spec 2026-09-30](2026-09-30-safe-autonomy-design.md), section 1.1.

**Revision 2 (2026-11-14), awaiting Michael's signature.** Michael declined the GitHub machine
account on 2026-11-13 and chose, on 2026-11-14 in the driver session ("ok, lets go with A then"),
that GitHub's default branches take changes only through a pull request, his own included. Sections
1.1, 2.1, 4.3 and 6 and the lines that named the account are rewritten below; the section
"Revision 2" at the end lists every change, what is documented, inferred and his to test, and the
decisions he can still change at signature. The text as signed on 2026-11-12 is this file at
commit `1ca66ad`.

This repository is public. Client organisations, groups, projects and hosts are never named here,
in the plan, in code or in tests; the tooling reads them from the local checkouts at run time.

## Problem

Rule 4 of `git-forge-guard.sh` is a text check that runs in the agent's own environment. It can
only refuse the spellings of `git push` it recognises, so the 2026-10-29 work chased spellings for
14 to 15 review rounds and ended with a residual list of about 90 lines in the helper's header.
Measured on main `0a0f580`:

| | Before that work (`9702750`) | Now |
|---|---|---|
| `dot_claude/git-push-guard.py` | about 1,490 lines | 3,339 |
| `dot_claude/executable_git-forge-guard.sh` | 512 | 625 |
| `tests/git-forge-guard.test.sh` | 2,053 | 4,137 (242 s, heavy) |

What the guard still does not stop:

- a push by a tool whose text holds neither `push` nor `send-pack` (`glab stack sync` force-pushes),
  a script, an interpreter, or a word built at run time;
- a push to the default branch written plainly: that **asks**, it is not denied
  (`git-push-guard.py`, `evaluate`), so the boundary is one click.

It also over-denies: a read-only command that names `git` beside a `--push` option, a `pre-push`
hook or a path that contains `push` is refused. The checkout of this very branch triggers it.

The forge sees every push whatever the spelling. Read on 2026-11-12 with read-only API calls:

| Remote | Repositories | Protection today | Plan |
|---|---|---|---|
| GitHub, Michael's personal account, public | 2 | Dotfiles: ruleset `protect-main` (no deletion, no force push, no bypass); a direct push to `main` passes. The other: none. | Free: rulesets available on public repositories |
| GitLab.com, Michael is Owner | 28 | 17 protect the default branch (push: Maintainers; one of them allows force push), 2 protect only a branch that is not the default, 9 protect nothing | Free in all three namespaces |
| GitLab.com, no access (404) | 3 | unreadable; last commits 2022 to 2025 | not Michael's to set |
| Azure DevOps | 3 | **unread**: `az repos` hangs from an agent session (section 2.3) | branch policies exist on every tier |

Agent sessions use Michael's credentials: his keys through the 1Password SSH agent socket, and his
`gh`, `glab` and `az` logins. A forge rule therefore binds an agent only where it binds Michael,
unless the agent has an identity of its own.

## Goals

- Every repository Michael administers refuses, at the forge, an agent's update of the default
  branch, a force push to it and its deletion, whatever the command looks like.
- Rule 4 goes back to judging plain commands. The spelling hunt and its tests are deleted.
- gitleaks keeps running on every push, as hygiene.
- No change adds a permission prompt. One ask is removed.

## Non-goals

- The merge gate, `xreview`, and the deny rules of `fix/xreview-trust`. This spec does not touch
  them.
- Rules 1 to 3 of the forge guard.
- A hard wall between agents and Michael's credentials. While the sandbox escape stays open
  (decision 3 of spec 2026-09-30), his keys and tokens are reachable from an agent session. The
  agent identity below is the default path, not a boundary; see Residual.
- Forge features above the plans in use: required approvals and push rules on GitLab (Premium),
  secret push protection (Ultimate), group-level protection (Premium).

## Anti-goals

- A forge setting changed by an agent. Every forge change is Michael's, one by one.
- Michael losing a workflow he uses today without having been told in this spec.
- A new local text check that again tries to recognise pushes.

## Approaches

| | A. No agent identity | B. An agent account on every forge | C. Split (chosen) |
|---|---|---|---|
| Default branch | MR/PR only, for Michael too | Michael keeps direct push; the agent's role cannot push | GitHub as B, GitLab and Azure as A |
| Merging, approving, unprotecting by an agent | local gates only | refused by the forge | GitHub: refused by the forge. GitLab: not in the agent's token; local gates behind it |
| Visible to others | nothing | a bot authors MRs and sits in client groups | nothing on client forges |
| Cost to Michael | the dotfiles' local merge and push of `main` becomes a PR merge | three accounts, keys and tokens; a seat in each client group | one GitHub account, one GitLab token |

C was chosen because it keeps the published record on client forges his and costs the least:
GitLab projects already land through merge requests he merges, and on the dotfiles he keeps a
direct push of `main`. It does change one thing he does today, the push of the dotfiles' `main`
by an agent on his word; section 4.3 says what replaces it.

**Revision 2: A on every forge.** The GitHub half of C needed a second account, which is visible
as the pusher of feature branches, in the collaborator list and as a profile; Michael declined it.
GitHub has no way to limit one credential of an account to branches other than the default (an
SSH account key acts as the whole user; a fine-grained token is scoped by repository and
permission, not by branch), so with his own key an agent is the repository admin and any rule the
admin may bypass lets it through. What is left is A: nobody pushes the default branch. The cost in
A's column is now his: the dotfiles' local merge and push of `main` becomes a pull request he
merges. Considered and not taken: keeping the local guard as GitHub's only refusal (the spelling
hunt could then not be retired, because a hidden spelling is a push whose remote the guard cannot
read); one deploy key per repository (whether a deploy key gets past a ruleset whose bypass list
holds the admin role is not documented, and the 2024-04-30 changelog suggests it once did); a
GitHub App (a visible second identity).

## 1. Agent identity

### 1.1 GitHub: a fine-grained token of Michael's account

No second account, as on GitLab.

- `git` over SSH to `github.com` keeps using Michael's key. The forge cannot tell the agent from
  him there, which is why section 2.1 protects the default branch against everyone.
- Michael creates one fine-grained personal access token of his own account for `gh`, limited to
  the repositories agents work in: Metadata read, Contents **read**, Pull requests write, Issues
  write. Without Contents write it cannot merge a pull request or push over HTTPS, and without
  Administration it cannot touch rulesets. Agent sessions read it from `GH_TOKEN` in the `env`
  block of the settings template (in place since merge 1; `gh` prefers it to the keyring).
- Pull requests, issues and comments an agent opens are his, like the commits.
- The agent SSH configuration, the pinned key and the `GITHUB_SSH` probe that merge 1 added for
  the machine account are removed (section 6).
- Michael's shells are untouched, as before.

### 1.2 GitLab: a fine-grained token of Michael's account

No second account. Fine-grained personal access tokens are generally available on GitLab.com
(19.2) and on Free.

- Michael creates one token limited to what agents do: read projects, repositories, branches and
  their protection, pipelines, jobs and issues; create and update merge requests and their notes.
  It has no Merge Request
  **Merge** or **Approve**, no Branch **Protect**, no Project **Update**, no member or token
  administration. The plan lists the exact permission names from the token form.
- Agent sessions read it from `GITLAB_TOKEN` in the `env` block; `glab` prefers it to the keyring.
- `git` to `gitlab.com` keeps using Michael's key. The forge cannot tell the agent from him there,
  which is why section 2.2 protects the default branch against everyone.

### 1.3 Azure DevOps: none

No token scope separates pushing from completing a pull request, and a second user is a licence
and a visible member. Agents keep Michael's login; the branch policy of section 2.3 binds everyone,
and completing a pull request stays with the classifier, as today.

### 1.4 Where the tokens live

Both tokens are 1Password items rendered at `chezmoi apply`, never committed. The plan picks the
mechanism the settings template supports (it is a `modify_` script today, not a template) and adds
the file to the secret-path list in `AGENTS.md` if a new templated file appears. The tokens are the
agent's own, so their presence in the session's environment is intended; nothing prints them, and
the suites assert only that the variables are set, never their value.

## 2. Forge rules

Michael sets each rule. The spec gives the shape; `forge-protection check` (section 3) prints the
exact command for every repository that is not yet in the target state, so no client name is
written down anywhere.

### 2.1 GitHub

The target, on the default branch of every repository agents work in: the rules `deletion`,
`non_fast_forward` and `pull_request`, each carried by an active ruleset with an **empty bypass
list**. Nobody deletes the branch, force-pushes it or pushes it directly, Michael included; a
change lands when a pull request is merged.

- A repository with no ruleset gets one:

  ```json
  {"name": "protect-main", "target": "branch", "enforcement": "active", "bypass_actors": [],
   "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
   "rules": [{"type": "deletion"}, {"type": "non_fast_forward"},
             {"type": "pull_request", "parameters": {"required_approving_review_count": 0,
              "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false,
              "require_last_push_approval": false, "required_review_thread_resolution": false,
              "allowed_merge_methods": ["merge"]}}]}
  ```

- The dotfiles already have `protect-main` with the first two rules. It gets a second ruleset,
  `main-pr-only`, with the `pull_request` rule alone and the same empty bypass list; the existing
  one is not edited. Rules of several rulesets add up.
- No approval is required: Michael is the only account, and an author cannot approve his own pull
  request. The author can merge it.
- `allowed_merge_methods` is `["merge"]`: a merge commit keeps his signed commits as they are and
  adds a merge commit GitHub signs; "rebase" would rewrite them unsigned and "squash" replaces
  them. Michael's default of 2026-11-14; he can change it at signature.
- An `update` rule ("Restrict updates") is not part of the target: with an empty bypass list it
  would refuse the merge of a pull request too. `main-owner-only` is never created.
- Scope: the repositories agents work in (seven by the baseline of 2026-11-13). The dormant ones
  are archived or go into his exceptions file, his choice per repository.
- Rulesets on a private repository of a personal account need GitHub Pro; on Free they exist for
  public repositories only. A repository agents work in must reach the target: one that is
  private on Free is made public, covered by Pro, or taken out of agent work, before merge 3. It
  is never excepted while agents still work in it, because after the retirement a hidden push
  with his key would meet no refusal there. A dormant private repository can be excepted like any
  other dormant one. Michael confirms which of his repositories are private before the first
  ruleset.

### 2.2 GitLab (28 projects)

On the default branch of every project: allowed to push and merge **No one**, allowed to merge
**Maintainers**, force push off. All of it is in Free.

GitLab applies the most permissive of all rules that match a branch. The target is therefore a
property of **every** protected-branch rule whose name or wildcard matches the default branch, not
of one rule: none of them may allow a push by any role, or a force push. The check evaluates all
matching rules, and the remediation it prints covers each one.

- 9 projects, and the 2 that protect only another branch: `glab api --method POST
  projects/<id>/protected_branches -f name=<default> -f push_access_level=0 -f
  merge_access_level=40 -f allow_force_push=false`.
- 17 projects: each existing rule goes from Maintainers to No one, and the one that allows force
  push loses it, **in place**. A rule is never removed and created again: between the two calls,
  or for good if the second fails, the branch would accept a force push its old rule refused.
  In place means `glab api --method PATCH projects/<id>/protected_branches/<name>` (the plan
  establishes the exact fields that Free accepts on one project of Michael's choosing before the
  check prints it for the rest), or, where the API refuses, the UI: Settings > Repository >
  Protected branches, the "Allowed to push and merge" dropdown and the "Allowed to force push"
  toggle of the existing row. The check never prints a DELETE.

What this costs Michael: he can no longer push a default branch directly on GitLab, on the small
single-developer projects included; every change lands through a merge request he merges. An
Owner can lift the rule in the UI when he needs to.

Not available on Free, so not set: required approvals, "prevent approval by author", push rules,
group-level protection. A new project is therefore unprotected until Michael protects it; the
check reports it.

### 2.3 Azure DevOps (3 repositories)

Unread. From an agent session `az repos …` produces no output until it is killed, sandboxed or
not, while `az account show` answers; the outbound firewall is the first suspect. Michael runs,
per repository:

```
az repos policy list --org <org url> --project <project> --repository-id <id> --branch <default>
```

Target: one blocking policy on the default branch, "Require a minimum number of reviewers" with 1
reviewer and "Allow requestors to approve their own changes" on. Any blocking policy makes direct
pushes fail and forbids deleting the branch, for everyone without the bypass permission, which no
group holds by default. Force push is a separate permission, not set for Contributors by default.

```
az repos policy approver-count create --org <org url> --project <project> --repository-id <id>
  --branch <default> --blocking true --enabled true --minimum-approver-count 1
  --creator-vote-counts true --allow-downvotes false --reset-on-source-push false
```

It needs the Edit policies permission (Project Administrators). Where Michael lacks it, the
repository joins the list below.

A policy binds only an identity without the bypass permissions, and agents push with Michael's
login. These repositories are unread, so the defaults prove nothing. A repository counts as
protected only when, in addition to the policy, Michael's **effective** permissions on the default
branch (own and inherited, as Repos > Branches > the branch's menu > Branch security shows them
for his user) do not allow "Bypass policies when pushing", "Bypass policies when completing pull
requests" or "Force push (rewrite history, delete branches and tags)". Where one is allowed, the
remediation is to set it to Deny for his user on that branch, in the same dialog; where he cannot,
the repository joins the list below. The check reads these with `az devops security permission
show` when it can reach Azure; until it can, Michael reads the dialog and the three repositories
stay in his exceptions file (section 3).

### 2.4 Where the forge cannot hold the boundary

| Remote | Why | What protects it |
|---|---|---|
| 3 GitLab projects with no API access | not Michael's to administer; inactive | plain rule 4, the classifier, whatever their owners set |
| Azure repositories until 2.3 is done, or where Michael cannot edit policies | unread | the same |
| Any new repository before Michael protects it | no group-level rules on these plans | the same, and the check names it |
| Branches other than the default, on every forge | protecting them would stop agents pushing feature branches | plain rule 4 (force without a lease and unmerged deletes ask) |

The spelling hunt is retired for these too (Michael, 2026-11-12). Keeping it for six repositories
would keep all of it.

## 3. `forge-protection check`

A new `.scripts/forge-protection.sh`, read-only, with a suite `tests/forge-protection.test.sh`
that stubs `gh`, `glab` and `az`.

- It walks the dotfiles checkout and `~/Code/*/*`, reads each `origin`, and asks the forge for the
  default branch and its protection with GET calls only.
- Per repository it prints one row: `ok`, `drift` with the exact command or click path that reaches
  the target state of section 2, `unreadable` with the reason, or `excepted`.
- **It exits 0 only when every repository is `ok` or `excepted`.** An unreadable repository fails
  the check like a drifted one: a token that cannot read protection, a forge that does not answer
  or a project that returns 404 is never counted as protected.
- `excepted` comes only from Michael's own list, `~/.config/forge-protection/exceptions`: one
  remote URL per line, the repositories of section 2.4 he accepts as unprotected. The file is his,
  outside the sandbox's writable paths and outside this repository; the script reads it and prints
  how many rows it excepted. Without the file nothing is excepted.
- It works with the agent identity: the GitLab token can read branch protection (section 1.2),
  and the GitHub token reads a repository's rules. A ruleset's bypass list is returned to
  repository admins only, so that the list is empty shows when Michael runs the check with his
  own login; with the agent token the check reads `current_user_can_bypass`. The suite pins that
  a 403 on the protection read is `unreadable`, and that `unreadable` fails.
- It never writes to a forge. There is no apply mode: Michael runs the printed commands. The suite
  pins that the script contains no write verb (`POST`, `PUT`, `PATCH`, `DELETE`, `create`,
  `update`) outside the strings it prints.
- Its output names repositories, so it is never committed or pasted into a tracked file.

## 4. What rule 4 becomes

### 4.1 Stays

The plain grammar of the helper's header and everything `evaluate` decides for it:

- unsupported push configuration, wildcard and ambiguous refspecs: silent deny, unchanged;
- force without a lease, deletes, `--mirror`, `--all`, `--prune` on other branches: ask, unchanged;
- the merged-branch delete, pinned and bare: passes silently, unchanged, and the classifier rule
  that trusts it keeps its wording;
- a command outside the grammar whose text holds the literal words `git` and `push` (or a push
  alias) outside inert arguments: the plain-push deny, as before 2026-10-29. It keeps pushes in the
  judged form and costs no parsing of hidden forms.

### 4.2 Changes

- **A plain push that updates the default branch is a silent deny**, no longer an ask: "the default
  branch is Michael's; push the branch and open a merge request or pull request".
  This is the one prompt removed. It holds on every remote, the unprotected ones included, and on
  the dotfiles (section 4.3). It lands with merge 3.

### 4.3 The dotfiles' `main`, and every other default branch

Today an agent merges a finished dotfiles branch into `main` in the main checkout and pushes it
when Michael approves the ask. Under revision 2 nobody pushes a GitHub default branch: the forge
refuses the push, his own included, and after merge 3 rule 4 denies the plain form everywhere.

- **The dotfiles land through a pull request.** The line's session pushes its branch, as today,
  and opens a pull request against `main` with `gh pr create` (through the pre-merge gate, which
  already requires the approved pre-merge review of that exact head; assigned to Michael; no
  agent attribution). Its final report ends with the pull request and the two commands for him,
  **run in a terminal of his own, not with `!` in the session**:
  `gh pr merge <number> --merge --match-head-commit <sha>` (or the merge button), then
  `git -C ~/.local/share/chezmoi pull --ff-only`, which the `chezmoi` wrapper needs before
  `chezmoi apply`: it deploys only from a clean `main` equal to origin's. A `!` command runs with
  the session's `GH_TOKEN`, which cannot merge.
- The pull request is opened ready for review, not as a draft: the reviews are done when it is
  opened, and nobody else reads the repository's pull requests. Michael can change this at
  signature (a draft costs him `gh pr ready` first).
- **No agent merges on GitHub, on his word or otherwise.** The agent token cannot (section 1.1),
  as on GitLab. The driver no longer merges a dotfiles line into `main` or pushes `main`; it
  collects the line's report and hands Michael the two commands. The local merge into the main
  checkout is gone, so the main checkout only ever fast-forwards.
- Every dotfiles line becomes a pull request in a public repository, under his own name.
- `wt-rm` needs no change: it already recognises a branch whose work reached the base by a merge
  commit, a rebase or a squash. It finds it merged once the main checkout has been pulled.
- On GitLab and Azure nothing changes: agents never pushed those default branches.
- The global instructions change in two steps. With merge 2: the Finishing rule loses its
  dotfiles exception ("for the dotfiles, the pushed branch is the end" becomes: push the branch
  and open a pull request Michael merges, ready for review), and `AGENTS.md` describes the flow
  above. With merge 3: "pushing to the default branch" leaves the list of actions an agent
  confirms first and becomes a thing an agent never does. `tests/fixtures/agent-instructions/
  rules.tsv` pins the rules and the line limits still hold.
- **Transition.** Until merge 2 is applied the current flow stays: local merge, the ask, the push
  of `main`. From the apply of merge 2 the flow is the pull request, which works with or without
  the ruleset. Once Michael has set the ruleset on the dotfiles, a direct push of `main` is
  refused for everyone. The full local guard stays live until merge 3 is applied.

### 4.4 Goes

Everything spec 2026-10-29 added, in the helper, the shell fast path and the suite:

- the normalized views and the escape decoder; the strict path and every glob reading; built
  command words and `dynamic_git_word`; the nested shell-string readers;
- the fast path's hidden-spelling and glob triggers and `PUSH_GUARD_LITERAL` values 0 and 2: the
  helper starts only on a literal push word, a selector or an alias;
- the suite sections "ways a push to the default branch could hide" through "hidden spellings", the
  decoder section and stub differential record F.

The header's threat model becomes: rule 4 judges the plain push an agent is told to write, and
refuses a literal push it cannot parse. Anything else is not its job; the forge refuses what
matters, and the classifier sees the rest. The residual list is deleted.

Expected size, to be measured by the plan and reported in the final report: the helper back to
roughly 1,300 lines (it also loses the scan, section 5), the suite to roughly 1,700, about 4,400
lines removed. The suite's 242 s is re-measured; if it lands under the heavy threshold its
`test-requires: heavy` tag goes, and `AGENTS.md` and the global instructions' pushing paragraph
are corrected in the same commit.

The removal starts from the current files, not from a revert of the 2026-10-29 commits: later
branches (merged-branch deletes, dry runs, the test audit) changed the same code.

## 5. gitleaks in a `pre-push` hook

- `dot_config/git/hooks/executable_pre-push`, enabled by `core.hooksPath = ~/.config/git/hooks` in
  the global git config.
- **The scan moves; it is not rewritten.** The helper's scan (`scan`, `run_gitleaks`,
  `expected_commits`, `leak_reason`, the neutralised git configuration, `PATCH_OPTS` with
  `--diff-merges=remerge`, `--root`, `--text`, `--no-textconv`, `--no-ext-diff`,
  `--submodule=short`, the scanned-commit count check and the time budget) becomes its own script
  beside the hook, taking the repository, the remote and the commits to scan. Every safeguard and
  its regression rows move with it into the hook's suite; none is dropped. A secret added while
  committing a merge, in a file marked binary, or in a root commit is found as today.
- The hook reads git's own lines on stdin (`<local ref> <local sha> <remote ref> <remote sha>`) and
  hands the script each updated ref's local sha, excluding `--remotes=<remote>` as today.
- **A push that would ask is still scanned by rule 4 first**, with the same script and the sources
  `evaluate` already resolves, and a leak, a missing gitleaks or a scan error is a silent deny, as
  today. Otherwise the ask would come before the hook's scan, and a push now refused without a
  prompt would cost Michael a click before it fails. Only this call remains in the helper; a push
  that passes rule 4 silently is scanned by the hook alone, and an approved ask is scanned twice
  (rare, and the second scan is the cheap one).
- A leak, a missing gitleaks or a gitleaks error blocks the push, with the rule, file and commit,
  never the value. `.gitleaksignore` works as today.
- It then runs the repository's own `pre-push` hook, if executable, with the same stdin and
  arguments, found at `$(git rev-parse --git-common-dir)/hooks/pre-push`: in a linked worktree
  `.git` is a file, and `--git-path hooks` would answer with the global directory.
- Hygiene, not a boundary: `--no-verify`, `core.hooksPath=` or `HOME=` turn it off, and a
  repository that sets its own `core.hooksPath` (none does today) replaces it.

Consequences Michael should know: his own pushes are scanned too, a second or so each; and a
global `core.hooksPath` switches off the other hooks in a repository's `.git/hooks`. One inactive
checkout has such hooks (ctags, last touched 2022). No repository uses a hook manager today.

The scan leaves the helper for the script in the same commit that lands the hook, so one apply
swaps them and no push goes unscanned.

## 6. Order

`chezmoi apply` deploys origin's `main`, so nothing on a branch is live. Under revision 2 the line
lands in three merges, each with its own pre-merge review; the retirement is the third.

**Merge 1, changes no verdict of rule 4. Done: on `main` at `1ca66ad`, applied on 2026-11-13.**
`forge-protection check`; the `pre-push` hook with the scan moved out of the helper; the agent
identity plumbing, inert until the 1Password items exist.

**Merge 2, the GitHub respec; changes no verdict of rule 4 either.** Landed by the current flow
(local merge, Michael's push of `main`). In this order:

1. The machine-account plumbing of merge 1 is removed, first: the agent SSH configuration
   (`dot_config/agent-identity/ssh_config`), the key template
   (`private_dot_ssh/private_github-agent.pub.tmpl`), the `-F` branch of `ssh-sandbox-proxy` (the
   proxy and the session's `GIT_SSH_COMMAND` predate merge 1 and stay), the sandbox's read entry
   for `~/.ssh/github-agent.pub`, the `GITHUB_SSH` probe of `live-agent-auth`, their test rows and
   subject-map rows. About 60 lines of code and 250 of tests. It touches sandbox settings and
   authentication, so it is reviewed like the rest and not shipped alone. `GH_TOKEN` and
   `GITLAB_TOKEN` stay.
2. `check_github` judges the target of section 2.1: the owner-only carrier, the bypass-mode
   reading and the second POST go; `deletion`, `non_fast_forward` and `pull_request` must each
   come from an active ruleset with an empty bypass list, and the printed line is the one POST of
   section 2.1 (or `main-pr-only` where `protect-main` exists).
3. Michael's steps file is rewritten for revision 2.
4. The dotfiles flow of section 4.3: the Finishing rule in `global.md`, `AGENTS.md`.

**Michael's forge actions** (list below). GitLab, Azure DevOps and the exceptions file do not
depend on merge 2 and can be done now, from the check on `main`. The GitHub token and rulesets
follow the apply of merge 2, from the commands the new check prints.

**Verification**, recorded under Implementation notes with repository names left out:

- `forge-protection check`, run by Michael with his own logins, exits 0. Every row is `ok` or
  `excepted`, and the excepted rows are the repositories of section 2.4, the dormant GitHub
  repositories and the shared GitLab projects of correction 11, and no others (he confirms the
  count);
- `gh api repos/<owner>/<repo>/rules/branches/<default> --jq '[.[].type] | sort'` prints
  `["deletion","non_fast_forward","pull_request"]` for each GitHub repository in scope;
- in a new agent session `gh auth status` names `GH_TOKEN` as the source of the active GitHub
  login (so `gh` is not on his keyring login), a GET of one repository's rules succeeds, and the
  three tests of "Revision 2" below have been run once;
- with the agent's GitLab token, a GET of one project's protected branches succeeds (the check
  depends on it) and `glab api personal_access_tokens/self` lists no merge, approve, protect or
  project-update permission.

Apart from Michael's three tests these verify configuration, not a refused push: no agent
attempts a live push against a default branch.

**Merge 3, the retirement** (section 4), the first dotfiles line to land through a pull request.
Its commits are written only after the verification results are in the spec, with their own plan
and a fresh pre-merge review. Until merge 3 is applied the full local guard is live, so there is
no moment at which neither the forge nor the guard refuses.

If Michael's actions have not happened when merge 2 is done, the line stops there and is reported
as waiting on him.

### Michael's forge actions

1. GitLab: create the fine-grained token; run the commands `forge-protection check` prints for
   the projects where he alone pushes the default branch (in place, never unprotecting).
2. Azure DevOps: set what section 2.3 names on the repositories the check reports as drift, or
   report which he cannot edit.
3. After the apply of merge 2, GitHub, in this order:
   1. create the scratch repository and give it the ruleset of section 2.1;
   2. create the fine-grained token of section 1.1, with the scratch repository among its
      repositories, and store it in 1Password;
   3. `chezmoi apply` again (the tokens are rendered only at apply; the same holds for the GitLab
      token of action 1) and start a new agent session; `gh auth status` there names `GH_TOKEN`;
   4. run the three tests on the scratch repository. Any failure stops here, before a real
      repository is touched;
   5. create the ruleset the check prints on each repository agents work in;
   6. delete the scratch repository.
4. Write `~/.config/forge-protection/exceptions` with the remotes he accepts as unprotected.

## 7. Rollback

- The retirement: `git revert` of its commits and `chezmoi apply` restores the full helper. The
  forge rules stay; they are not part of the rollback.
- The hook: unset `core.hooksPath` (one line in the global git config) and revert the commit that
  moved the scan.
- The identity: delete the two 1Password references from the settings template; sessions fall back
  to Michael's logins. Forge side, revoke the tokens.
- The pull-request flow on GitHub: delete the `pull_request` rule (or the `main-pr-only` ruleset)
  and the direct push of `main` works again; the Finishing rule is one reverted commit.
- A forge rule: each is one DELETE or one UI switch, Michael's.

## Residual

- Michael's credentials stay reachable from an agent session: the 1Password socket serves all his
  keys, and unsetting `GH_TOKEN` or `GITLAB_TOKEN`, or an unsandboxed command, reaches his logins.
  That takes a deliberate act the classifier sees, not a spelling. With his login an agent can
  still merge on GitHub, GitLab and Azure, and unprotect a branch; the existing asks (`glab mr merge`,
  `glab api` writes) and the merge gate stay in front of that.
- A hidden spelling of a force push or delete on a branch other than the default is no longer
  refused locally. The classifier sees it; the damage is one branch, usually the agent's own.
- The remotes of section 2.4.
- gitleaks can be skipped (section 5).

## Tests

- `tests/forge-protection.test.sh`: each forge's `ok`, `drift` and `unreadable` rows from stubbed
  API answers; the printed remediation for each drift shape of section 2, never a DELETE; a
  permissive wildcard rule beside a strict exact rule is `drift`; a 403, a 404 and a forge that
  does not answer are `unreadable` and fail; an excepted remote passes only through the exceptions
  file, and a missing file excepts nothing; an Azure branch with the policy but an allowed bypass
  permission is `drift`; no write verb outside printed strings; fixtures use invented names.
- `tests/git-pre-push-hook.test.sh`: the scan sections of `git-forge-guard.test.sh` ("the secret
  scan", "the scan fails closed"), moved and driven through the hook: every existing row keeps its
  verdict, the merge-commit, binary-attribute, root-commit, count-mismatch and timeout rows
  included. New rows: a new branch, a deleted ref, several refs in one push; the repository's own
  hook runs, its failure blocks, and it is found from a linked worktree.
- `tests/git-forge-guard.test.sh` keeps, as permission outcomes through the whole hook: a force
  push without a lease, and a delete beside a pushed branch, whose commits hold a secret are a
  **deny**, not an ask; the same with gitleaks missing or failing.
- `tests/git-forge-guard.test.sh`: the default-branch rows move from ask to deny; the sections
  listed in 4.4 are deleted, not skipped; one row per retired class pins that the guard is now
  **silent** on it (so a later change cannot bring a half-hunt back unnoticed); the plain-grammar,
  inert-text, merged-delete and fail-closed sections stay.
- `tests/claude-settings.test.sh`: the two variables render when the items exist and are absent
  when they do not. Revision 2: the rows for the agent SSH configuration and key go with them.
- `live-agent-auth`: revision 2 removes the `GITHUB_SSH` probe; `github.com` and `gitlab.com` both
  greet Michael through the session's transport, as before merge 1.
- `tests/forge-protection.test.sh`, revision 2: the GitHub rows follow section 2.1. All three
  rules from closed rulesets is `ok`; `pull_request` missing, or carried only by a ruleset with a
  bypass actor, is `drift` with the one POST; the owner-only rows go.

## After Michael's apply

1. After merge 2 and his forge actions: the verification of section 6. After merge 3:
   `forge-protection check` still exits 0, with the same excepted rows.
2. `./tests/run.sh git-forge-guard` and the new suites pass; the heavy tag is gone if the time
   allows.
3. A dotfiles line ends in a pull request under Michael's name; after his merge and the pull of
   the main checkout, `chezmoi apply` deploys it and `wt-rm` finds the branch merged.
4. `git push origin main` from an agent session is a silent deny; no prompt appears.

## Corrections from planning (2026-11-12, after sign-off)

Planning merge 1 against the code found wording in this spec that does not hold. The design is
unchanged; each correction is listed here for Michael, and the text above stands as signed.

1. **"Merge 1 changes no verdict of rule 4" means its judgement of the push target.** Section 5
   already moves the scan: a plain push that rule 4 passes silently and whose commits hold a
   secret, or whose scan fails, is no longer denied by the guard but blocked by the hook. The plan
   lists every guard test row whose verdict moves.
2. **The moved scan changes in three named ways**, not zero: it gets a command line; a push to a
   URL excludes only the tracking refs of a configured remote with that URL, and nothing when
   there is none; and it keeps the git configuration entries git hands a
   hook (`GIT_CONFIG_COUNT`, measured: four `safe.directory` entries in an agent session) and
   appends its pins after them, dropping `GIT_CONFIG_PARAMETERS`. Every safeguard and message
   text moves unchanged.
3. **"Every existing row keeps its verdict" holds per behaviour, not per command.** Through the
   hook some rows need another command (an amend needs a lease to reach the hook; a source that is
   not a ref is refused by git first), the hook also scans dry runs, and the `--tags` "push the
   refs by name" reason cannot occur there. The plan's table says where each row goes.
4. **Section 1.2: the GitLab token also reads merge requests.** The pre-merge gate reads projects
   and merge requests with `glab`, in the same environment.
5. **Section 1.4, "nothing prints them":** the tokens sit in the `env` block of
   `~/.claude/settings.json`, so a full render or diff of that file shows them. `AGENTS.md` gains
   the rule to preview it through `jq 'del(.env.GH_TOKEN, .env.GITLAB_TOKEN)'`. This is a residual.
6. **Section 3, the write-verb pin:** a write verb is an HTTP method or a CLI write subcommand;
   the GitHub rule type `update`, which the check must read, is data.
7. **Section 6, "the deployed check":** `.scripts/` is not deployed; Michael runs the check from
   the main checkout after merge 1.
8. **Section 2.1:** `bypass_actors` is returned to repository admins only. Run in an agent session
   the check proves that the agent cannot bypass; that `protect-main` binds Michael too shows
   only when he runs it, which his steps include.
9. **The inventory is larger than this spec counts.** The check, read on 2026-11-13, found 86
   repositories, not the two GitHub repositories and 28 GitLab projects above: on GitHub 43 of
   Michael's own (all drift) and 14 of other owners that it cannot read (HTTP 403); on `gitlab.com`
   25 (22 drift, 3 unreadable); 3 on Azure DevOps (unreadable from an agent session); and 1 on a
   self-hosted host the check does not know (unreadable). Recorded for Michael to overrule; his
   steps use these figures.
10. **GitHub identity reach and authorship is an open decision of Michael's.** The agent SSH key is
    pinned for every `github.com` remote, so an agent cannot push to (or, if private, fetch) a
    repository where the machine account is not a collaborator, and a machine-account `GH_TOKEN`
    makes every pull request, issue and comment the machine account's, against the rule that the
    published record is Michael's. The steps recommend a fine-grained token of his own account (no
    Contents write, so it cannot push or merge) and a collaborator only where agents work; recorded
    for him to overrule, and unverified until he checks the permission names and that a merge is
    refused.
11. **GitLab changes are visible to other members.** The target (push "No one", merge Maintainers,
    force push off) also removes default-branch push from other members and from a pushing CI job,
    and merge from Developers; section 2.2's "nothing visible to others" was wrong. Recorded for
    Michael to overrule: apply it only where he alone pushes the default branch, and decide whether
    the merge clause leaves the target.
12. **Section 5, "only this call remains in the helper", did not hold.** The guard still scans an
    otherwise-allowed agent push when it cannot show the deployed hook will run for it
    (`--no-verify`, an environment assignment or wrapper, a `core.hooksPath` that is not the
    deployed directory, a missing or non-executable hook), which keeps main's verdicts for those
    pushes. Recorded for Michael to overrule.
13. **A named remote's tracking refs are attributed only when its fetch and push address are
    one.** Otherwise the scan excludes nothing and scans the whole history, failing closed on the
    budget; a `pushurl`, a `pushInsteadOf` rewrite or several URLs say nothing about what the push
    destination holds. This sharpens correction 2 and is recorded for Michael to overrule.
14. **The walk is three levels deep.** The check covers the dotfiles checkout and every checkout
    one to three levels under `~/Code`, never entering a repository, and exits 1 when it finds none;
    two levels missed checkouts. Recorded for Michael to overrule.
15. **The Azure reviewers policy is matched by its type id,** not its localised display name, and
    a policy without a string `type.id` makes the row unreadable. The id is taken from
    documentation and confirmed when Michael first reads a real policy list. Recorded for him to
    overrule.
16. **The agent SSH pin covers `ssh.github.com` as well as `github.com`.** The port-443 endpoint is
    GitHub's own; a trailing-dot host name, an IP literal, an SSH host alias and an HTTPS remote
    stay outside the pin as accepted limits. Recorded for Michael to overrule.

### Decisions on corrections 10 to 12 (Michael, 2026-11-13, relayed by the driver session)

- **Correction 10, decided as recommended.** `GH_TOKEN` is a fine-grained token of Michael's own
  account without Contents write, so pull requests, issues and comments stay his; the machine
  account pushes, and is a collaborator only on repositories agents work in. Still unverified until
  he checks the permission names and that a merge is refused; his steps keep that check.
- **Correction 11, decided as recommended.** The GitLab target is applied only on projects where
  he alone pushes the default branch; every other project goes into his exceptions file or stays
  as it is.
  The merge clause leaves the target: the check judges push "No one" and force push off only,
  and prints nothing about merge. Decided by the driver session on Michael's delegation,
  2026-11-13: the clause does not constrain agents (they act as the owner and the agent token
  cannot merge) and it is the part that changes what other project members can do.
- **Correction 12, accepted as built.** The guard keeps scanning the pushes it cannot show the
  hook will see.

## Left to the plan

- The rendering mechanism for the two tokens, and the exact agent SSH configuration (the latter
  removed by revision 2).
- The exact fine-grained permission names on GitLab, and the GitHub token type, each checked
  against the live forms.
- The line and second counts of section 4.4.

## Revision 2 (2026-11-14): GitHub without a second account

Awaiting Michael's signature. He declined the machine account on 2026-11-13 ("I don't like that.
So this is not something that I want to introduce": it would show as the pusher of feature
branches, in the collaborator list and as a profile) and chose pull requests only on 2026-11-14
("ok, lets go with A then"), both in the driver session.

**Rewritten:** the Approaches note, sections 1.1, 2.1, 4.3 and 6 with its list of forge actions;
single lines in sections 3, 4.2 and 7, Residual, Tests and "After Michael's apply". **Superseded
corrections:** 8 (the bypass list still shows only to an admin; the machine account in it is
gone), 10 (decided on 2026-11-13 for his own token; the collaborator half is gone) and 16 (the
SSH pin is removed). Sections 1.2, 1.3, 2.2 to 2.4, 4.1, 4.4 and 5 stand.

**What is documented, inferred, and his to test** (GitHub's documentation, read on 2026-11-13):

| Claim | Status |
|---|---|
| No credential of an account can be limited to branches other than the default | no such feature found: fine-grained tokens scope by repository and permission, SSH account keys not at all |
| Merging a pull request by API needs Contents write | documented (the fine-grained permission table lists the merge endpoint under Contents write only) |
| A token with Pull requests write and Contents read cannot merge and cannot push over HTTPS | inferred from that table: **test 1** |
| With an empty bypass list the `pull_request` rule refuses a direct push by the admin too | inferred (bypass is opt-in in rulesets, unlike classic branch protection): **test 2** |
| With 0 required approvals the author merges his own pull request | inferred ("it must be opened", it need not be approved): **test 3** |
| `allowed_merge_methods` is a parameter of the `pull_request` rule | from the REST schema, not checked against a live answer: the POST of test 2's ruleset shows it |
| Rulesets on a private personal repository need GitHub Pro | documented for Pro, and for public repositories on Free |

The three tests, once (his steps give the commands). All three run on a scratch public repository
he creates for it, gives the ruleset of section 2.1 and deletes afterwards, **before** any real
repository gets the ruleset: a merge or push the forge failed to refuse would otherwise stay on a
real `main`, where the force push that removes it is refused. He runs them from his own terminal;
in an agent session the local merge gate would refuse test 1 before it reached GitHub and prove
nothing about the token.

1. With the agent token read from 1Password into `GH_TOKEN` for the one command: `gh pr merge` of
   a pull request on the scratch repository is refused, and so is a write through the Contents
   API (`PUT repos/<owner>/<scratch>/contents/<file>`), the permission an HTTPS push needs.
2. With his own login: `git push origin main` with a new commit on the scratch `main` is refused
   by the forge.
3. With his own login: the pull request of test 1 merges with `gh pr merge <n> --merge`.

If test 2 fails (the admin gets through), the boundary does not hold and the line stops before
merge 3. If test 1 fails, the token gets fewer permissions or the line stops. If test 3 fails, the
ruleset is deleted and nothing is lost.

**Decisions he can still change at signature:**

- the merge method, `merge` only (section 2.1);
- the scope: the repositories agents work in, the dormant ones archived or excepted per
  repository (section 2.1);
- the dotfiles' pull request opened ready for review, not as a draft (section 4.3);
- three merges, with the pull-request flow starting at merge 2 and the retirement at merge 3
  (section 6).

**What changes for the driver:** it no longer merges a dotfiles line into `main`, and no agent
pushes `main` or merges on GitHub. A line's final report carries the pull request and Michael's
two commands.
