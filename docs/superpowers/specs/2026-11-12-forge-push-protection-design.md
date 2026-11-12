# Push protection moves to the forge

**Status:** In progress (spec review; the dotfiles have no MR)
**Date:** 2026-11-12
**Branch:** `feat/forge-push-protection`

Item 35 of the 2026-11-11 setup review, decided by Michael on 2026-11-12. He chose the split
identity (approach C below) and the retirement of the spelling hunt on every remote on the same
day. It replaces the threat model of
[spec 2026-10-29](2026-10-29-push-guard-escaped-spellings-design.md), section 7, and changes rule 4
of [spec 2026-09-30](2026-09-30-safe-autonomy-design.md), section 1.1.

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

C was chosen because it changes no workflow Michael uses: he merges the dotfiles locally and pushes
`main`, and he merges GitLab projects through merge requests. The published record on client forges
stays his.

## 1. Agent identity

### 1.1 GitHub: a machine account

GitHub's terms allow one free machine account beside a personal account.

- Michael creates the account, with two-factor authentication, its credentials in 1Password.
- It is a collaborator (write) on the two repositories. A collaborator on a personal repository
  cannot reach its settings, so it cannot edit rulesets.
- It gets an SSH key held in 1Password (served by the same agent socket) and a personal access
  token for `gh`. A fine-grained token cannot reach another user's personal repository, so this is
  a classic token with the `public_repo` scope; the plan verifies that against the live API before
  anything depends on it.
- Agent sessions use it by default:
  - `git` over SSH to `github.com` offers only the machine account's key. The session's
    `GIT_SSH_COMMAND` (today `ssh-sandbox-proxy`, set by the SessionStart hook) selects an agent
    SSH configuration that pins `IdentityFile` to the public key and sets `IdentitiesOnly yes` for
    `github.com`, then includes Michael's configuration for every other host. The public key file
    is added to the sandbox's readable `~/.ssh` list.
  - `gh` reads the token from `GH_TOKEN` in the `env` block of the settings template.
- Commits stay authored and signed by Michael's key, as today. Only the pusher differs.
- Michael's shells are untouched: none of this is in `zshenv`, the global git config or his SSH
  configuration.

### 1.2 GitLab: a fine-grained token of Michael's account

No second account. Fine-grained personal access tokens are generally available on GitLab.com
(19.2) and on Free.

- Michael creates one token limited to what agents do: read projects, repositories, pipelines,
  jobs and issues; create and update merge requests and their notes. It has no Merge Request
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

Both repositories get two rulesets on the default branch:

1. `protect-main`, as it exists on the dotfiles: `deletion` and `non_fast_forward`, no bypass. It
   keeps binding Michael too. Created on the second repository with the command from spec
   2026-10-29, section 6.
2. `main-owner-only`, new: the `update` and `creation` rules, with the repository admin role as the
   only bypass actor. Michael pushes `main`; the machine account, a collaborator, cannot, by push or
   by merging a pull request.

```json
{"name": "main-owner-only", "target": "branch", "enforcement": "active",
 "bypass_actors": [{"actor_type": "RepositoryRole", "actor_id": 5, "bypass_mode": "always"}],
 "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
 "rules": [{"type": "update"}, {"type": "creation"}]}
```

`gh api --method POST repos/<owner>/<repo>/rulesets --input <file>`, then
`gh api --method PUT repos/<owner>/<repo>/collaborators/<machine account> -f permission=push`.
The plan confirms that role id 5 is admin from the API's answer before Michael runs it.

Two separate rulesets, because a bypass actor bypasses every rule of its ruleset: merged into one,
Michael could force-push `main` again.

### 2.2 GitLab (28 projects)

On the default branch of every project: allowed to push and merge **No one**, allowed to merge
**Maintainers**, force push off. All of it is in Free.

- 9 projects: `glab api --method POST projects/<id>/protected_branches -f name=<default> -f
  push_access_level=0 -f merge_access_level=40 -f allow_force_push=false`.
- 17 projects: the existing rule goes from Maintainers to No one (unprotect and protect again; the
  check prints both commands as one line each), and the one that allows force push loses it.
- 2 projects protect a branch that is not the default: the default branch gets the rule too.

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
- Per repository it prints one row: `ok`, `drift` with the exact command that reaches the target
  state of section 2, or `unreadable` with the reason. It exits 0 only when every readable
  repository is `ok`; unreadable ones are listed and counted separately.
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
  branch is Michael's; push the branch and open a merge request, or he pushes it himself with `!`".
  This is the one prompt removed. It holds on every remote, the unprotected ones included.

### 4.3 Goes

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
- It reads git's own lines on stdin (`<local ref> <local sha> <remote ref> <remote sha>`) and, for
  each updated ref, scans `gitleaks git --redact --log-opts="<local sha> --not --remotes=<remote>"`.
  Git names the commits, so the guard's refspec arithmetic for the scan is deleted with it.
- A leak, a missing gitleaks or a gitleaks error blocks the push, with the rule, file and commit,
  never the value. `.gitleaksignore` works as today.
- It then runs the repository's own `.git/hooks/pre-push`, if executable, with the same stdin and
  arguments.
- Hygiene, not a boundary: `--no-verify`, `core.hooksPath=` or `HOME=` turn it off, and a
  repository that sets its own `core.hooksPath` (none does today) replaces it.

Consequences Michael should know: his own pushes are scanned too, a second or so each; and a
global `core.hooksPath` switches off the other hooks in a repository's `.git/hooks`. One inactive
checkout has such hooks (ctags, last touched 2022). No repository uses a hook manager today.

The helper's secret scan and its suite sections are removed in the same commit that lands the
hook, so no push is scanned twice and none goes unscanned.

## 6. Order

1. **Lands first, changes no verdict:** `forge-protection check`, the `pre-push` hook with the
   scan's removal from the helper, the agent identity plumbing (inert until the 1Password items
   exist: no item, no variable, and the sessions behave as today).
2. **Michael's forge actions** (list below), then `chezmoi apply` and a new session.
3. **Verification, recorded under Implementation notes with repository names left out:**
   - `forge-protection check` exits 0, or lists only the repositories of section 2.4;
   - `gh api repos/<owner>/<repo>/rules/branches/<default> --jq '[.[].type] | sort'` prints
     `["creation","deletion","non_fast_forward","update"]` for both GitHub repositories, and
     `gh api repos/<owner>/<repo>/collaborators/<machine account>/permission --jq .permission`
     prints `write`;
   - `ssh -T git@github.com` from an agent session greets the machine account;
   - `glab api projects/<id>/protected_branches` with the agent token answers 403 or an empty
     permission error on one project (a GET; the token has no Branch permission at all).

   These verify configuration, not a refused push. No live push against a default branch is
   attempted: a probe that the forge failed to refuse would itself move the branch.
4. **Only then: the retirement commits** (section 4), on this branch, after step 3's results are
   in the spec. The branch is pushed once at the end; Michael merges.

If step 2 has not happened when the code is ready, the branch stops after step 1 and is reported
as waiting on Michael; step 4 never merges ahead of step 3.

### Michael's forge actions

1. Create the GitHub machine account; add its SSH key and token to 1Password.
2. GitHub: `main-owner-only` on both repositories, `protect-main` on the second, the collaborator
   invitation on both (accepted from the machine account).
3. GitLab: create the fine-grained token; run the commands `forge-protection check` prints for the
   28 projects.
4. Azure DevOps: read the three repositories' policies and set the one in 2.3, or report which he
   cannot edit.
5. `chezmoi apply`, then a new Claude Code session.

## 7. Rollback

- The retirement: `git revert` of its commits and `chezmoi apply` restores the full helper. The
  forge rules stay; they are not part of the rollback.
- The hook: unset `core.hooksPath` (one line in the global git config) and revert the commit that
  moved the scan.
- The identity: delete the two 1Password references from the settings template; sessions fall back
  to Michael's logins. Forge side, remove the collaborator and revoke the tokens.
- A forge rule: each is one DELETE or one UI switch, Michael's.

## Residual

- Michael's credentials stay reachable from an agent session: the 1Password socket serves all his
  keys, and unsetting `GH_TOKEN` or `GITLAB_TOKEN`, or an unsandboxed command, reaches his logins.
  That takes a deliberate act the classifier sees, not a spelling. With his login an agent can
  still merge on GitLab and Azure, and unprotect a branch; the existing asks (`glab mr merge`,
  `glab api` writes) and the merge gate stay in front of that.
- A hidden spelling of a force push or delete on a branch other than the default is no longer
  refused locally. The classifier sees it; the damage is one branch, usually the agent's own.
- The remotes of section 2.4.
- gitleaks can be skipped (section 5).

## Tests

- `tests/forge-protection.test.sh`: each forge's `ok`, `drift` and `unreadable` rows from stubbed
  API answers; the printed command for each drift shape of section 2; the exit status; no write
  verb outside printed strings; no repository name from a fixture in a tracked file.
- `tests/git-pre-push-hook.test.sh`: a leak blocks and names no value; a clean push passes; missing
  gitleaks blocks; a new branch and a deleted ref are handled; the repository's own hook runs and
  its failure blocks; `.gitleaksignore` is honoured.
- `tests/git-forge-guard.test.sh`: the default-branch rows move from ask to deny; the sections
  listed in 4.3 are deleted, not skipped; one row per retired class pins that the guard is now
  **silent** on it (so a later change cannot bring a half-hunt back unnoticed); the plain-grammar,
  inert-text, merged-delete and fail-closed sections stay.
- `tests/claude-settings.test.sh`: the two variables render when the items exist and are absent
  when they do not; the agent SSH configuration is readable in the sandbox.
- `live-agent-auth` gains a probe, run sandboxed in a fresh session after apply: `ssh -T` to
  `github.com` greets the machine account, and to `gitlab.com` Michael.

## After Michael's apply

1. `forge-protection check` exits 0, or lists only the repositories of section 2.4.
2. `./tests/run.sh git-forge-guard` and the new suites pass; the heavy tag is gone if the time
   allows.
3. A push of a feature branch from an agent session to GitHub shows the machine account as pusher
   and Michael as commit author with a valid signature.
4. `git push origin main` from an agent session is a silent deny; no prompt appears.

## Left to the plan

- The rendering mechanism for the two tokens, and the exact agent SSH configuration.
- The exact fine-grained permission names on GitLab, and the GitHub token type, each checked
  against the live forms.
- The line and second counts of section 4.3.
