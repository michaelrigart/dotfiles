# Forge push protection: Michael's steps after merge 1

**Status:** In progress

**Spec:** `docs/superpowers/specs/2026-11-12-forge-push-protection-design.md` (sections 1, 2, 3, 6, 7).
**Plan:** `docs/superpowers/plans/2026-11-12-forge-push-protection-merge-1.md` (Task 9, "Michael's steps").

Run the commands from your own terminal unless a step says the agent session: in a session `gh` is
the machine account, and `GIT_SSH_COMMAND` selects its key. Never use `!` in a session for a step
here.

Placeholders: `<agent-account>` (the machine account's login), `<owner>` (your own GitHub login),
`<repo>`, `<branch>` (the default branch), `<project-id>` (GitLab's numeric id), `<org-url>`,
`<project>`, `<repo-id>`, `<ruleset-id>`. Real values come from the check's output, which stays on
your screen: it names repositories, so never commit it, paste it into a tracked file or put it in
a report. Report counts only.

Commands and item names are copied from the committed code: `.scripts/forge-protection.sh` (the
lines it prints), `dot_claude/modify_private_settings.json`, `private_dot_ssh/private_github-agent.pub.tmpl`,
`dot_config/agent-identity/ssh_config` and `tests/live-agent-auth.test.sh`. Where this file and
the plan differ, this file follows the code.

## What is unverified against a real forge

Each is marked **UNVERIFIED** at its step. You confirm it while doing the step and tell the line
what you saw, so the spec's Implementation notes and (for a wrong printed form) merge 2 are corrected.

| Item | Step |
|---|---|
| A classic `public_repo` token, not a fine-grained one, is what the machine account needs | 3 |
| The exact permission names of the GitLab fine-grained token form, and what `personal_access_tokens/self` returns for one | 4, 15 |
| Repository role id 5 is "Repository admin" (the check accepts id 5 without proving it) | 8 |
| `rules/branches/<branch>` returns rulesets in evaluate mode (the check and the verification both read it) | 8 |
| GitLab accepts the printed PATCH (`_destroy` entries, `allowed_to_push`, `allowed_to_merge`) on Free | 10 |
| Azure: the state of all three repositories was never read, because `az repos` hung from an agent session (the outbound firewall is the first suspect) | 12 |
| Azure: the permission-bit values and the security token format the check uses | 12 |
| Azure: an empty `acesDictionary` for a user whose rights come only from groups makes the row `unreadable` | 12 |
| Azure: the check reads the rights of `az account show`'s user; if you push to Azure as another identity (a PAT of another account), it does not describe that identity | 12 |
| Azure: a policy scoped by prefix or to all branches may not be returned by the exact-branch read, so the check prints a create for a branch that is already covered | 12 |
| Azure: the reviewers-policy type id `fa4e907d-c16b-4a4c-9dfa-4906e5d171dd` is taken from documentation | 12 |

## Group A: accounts, tokens and 1Password items (no repository changes)

These can come before or after step 5, but step 6 needs steps 1 to 4 done: an item that does not
exist yet leaves its part inert, and a second `chezmoi apply` after creating it renders it.

### Step 1. Create the GitHub machine account

Create a second GitHub account for the agent (github.com/signup; GitHub's terms allow one free
machine account beside a personal one). Use an email address you control that no other GitHub
account uses. Turn on two-factor authentication and keep the login, the authenticator secret and
the recovery codes in a 1Password item of your own naming. Do not title it `GitHub Agent SSH Key`
or `GitHub Agent Token`: those two titles are read by the code.

Verify: signed in as that account, `https://github.com/settings/security` shows two-factor
authentication enabled.

If it fails: enable it there before going on; the account must not exist without it.

### Step 2. Its SSH key (needs step 1)

In 1Password: New Item > SSH Key > Add Private Key > Generate New Key, type Ed25519, vault
**Private**, title exactly `GitHub Agent SSH Key`. Then, signed in as the machine account,
Settings > SSH and GPG keys > New SSH key, type Authentication Key, and paste the public key:

```
op read "op://Private/GitHub Agent SSH Key/public key" | pbcopy
```

Verify (the public key, never the private one):

```
op read "op://Private/GitHub Agent SSH Key/public key" | ssh-keygen -lf -
```

Expected: one line `256 SHA256:… (ED25519)` whose fingerprint is the one listed on
`https://github.com/settings/keys` for the machine account.

If it fails: `op read` says the item or field is not found: the title or the vault is wrong, or the
key's public field is not labelled `public key` (rename it). If `op` cannot connect, 1Password's
Settings > Developer > CLI integration must be on, then `eval $(op signin)`.

### Step 3. Its token (needs step 1)

Signed in as the machine account: Settings > Developer settings > Personal access tokens >
Tokens (classic) > Generate new token (classic). Scope `public_repo` only, an expiry you will
remember. Store it in 1Password: vault **Private**, item titled exactly `GitHub Agent Token`, with
the secret in a field labelled exactly `token` (an API Credential item has a `credential` field:
rename its label to `token`).

**UNVERIFIED: classic, not fine-grained.** The spec says a fine-grained token cannot reach another
user's personal repository. Confirm on `https://github.com/settings/personal-access-tokens/new` as
the machine account: "Resource owner" should offer only the machine account (and any organisations
it belongs to), never `<owner>`. If it does offer `<owner>`, stop and tell the line: a fine-grained
token limited to the two repositories would be narrower, and that is a design change.

Verify (the token is only in that one command's environment; nothing prints it):

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api user --jq .login
```

Expected: `<agent-account>`.

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api -i user | rg -i '^x-oauth-scopes'
```

Expected: `X-Oauth-Scopes: public_repo`.

If it fails: `bad credentials` means the token was copied wrongly or has expired; an extra scope
means regenerate it narrower. `op read` failing means the field is not labelled `token`: step 6's
apply would refuse for the same reason.

### Step 4. The GitLab token (your own GitLab account, no second account)

On your own account: Edit profile > Access tokens > Add new token, fine-grained. Give it only what
agents do: read projects, repositories, branches and their protection (the check needs
`projects/<id>` and `protected_branches`), pipelines, jobs, issues and merge requests, and create
and update merge requests and their notes. Leave out merge request **Merge** and **Approve**,
branch **Protect**, project **Update**, and member and token administration. Set an expiry. Store it in 1Password: vault **Private**, item
titled exactly `GitLab Agent Token`, secret in a field labelled exactly `token`.

**UNVERIFIED: the permission names on the form, on Free.** Write down the names you ticked (no
project names) and give them to the line for the spec's Implementation notes.

Verify:

```
GITLAB_TOKEN="$(op read 'op://Private/GitLab Agent Token/token')" glab api --hostname gitlab.com personal_access_tokens/self | jq 'del(.token)'
```

Expected: the answer lists no merge, approve, protect or project-update permission. UNVERIFIED:
what shape this answer has for a fine-grained token. If it shows only `scopes`, the token's own page
in the GitLab UI is the reading.

If it fails: 401 means the secret was pasted wrongly; a forbidden permission means edit the token
(Access tokens > the token > edit) and remove it.

### Rollback, group A

Delete the two token items (or archive them; `op item list` does not list archived items) and the
SSH key item in 1Password, remove the machine account's key and token at
`https://github.com/settings/keys` and `https://github.com/settings/tokens`, and revoke the GitLab
token (Access tokens > Revoke). If step 6 has run, the next `chezmoi apply` (step 6's command)
then removes `GH_TOKEN`, `GITLAB_TOKEN` and `~/.ssh/github-agent.pub`: items not listed are the inert state.

## Group B: merge and apply

### Step 5. Merge 1 and push `main` from your own terminal

Needs the line's final report: pre-merge review receipt, and the heavy suites green. In a terminal
of your own, not the session:

```
git -C ~/.local/share/chezmoi status --short --branch
```

Expected: `## main...origin/main` and nothing else. Then:

```
git -C ~/.local/share/chezmoi merge --ff-only feat/forge-push-protection
```

(Fast-forward is the default I chose; use your usual merge style if it differs.) Then:

```
git -C ~/.local/share/chezmoi pom
```

`pom` is the global alias for `push origin main`. The hook is not deployed yet, so this push is
not scanned.

Verify:

```
git -C ~/.local/share/chezmoi status --short --branch
```

Expected: `## main...origin/main` with no `ahead`.

If it fails: if the `--ff-only` merge refuses, `main` has moved (for example `chore/test-audit`
merged). Do not force it: tell the line's session to rebase `feat/forge-push-protection` onto the
new `main` and re-run `./tests/run.sh git-forge-guard pre-pu hook-path`, then repeat this step.
If the push is rejected, `origin/main` moved after your merge: do not force it; tell the line.

### Step 6. Apply (needs steps 1 to 5)

```
command -v gitleaks
```

Expected: a path. If it prints nothing, run `brew bundle install --file ~/.config/homebrew/Brewfile`
first: from this apply on, every push of yours runs the scan, and a missing gitleaks blocks it.

```
chezmoi apply
```

Run it plain: **not** `chezmoi diff`, not `apply --verbose`, and not `chezmoi cat` of
`~/.claude/settings.json`. Each prints the file whole, and the file now holds both tokens. 1Password
may ask for Touch ID several times.

Verify, in your own terminal:

```
git config --global --get core.hooksPath
```

Expected: `~/.config/git/hooks`.

```
ls ~/.config/git/hooks
```

Expected: `pre-push` and `secret-scan`.

```
test -s ~/.ssh/github-agent.pub && echo present
```

Expected: `present`. The file lands at mode 600, not 644: its template is
`private_dot_ssh/private_github-agent.pub.tmpl`, and the `private_` prefix makes chezmoi strip
group and world access, as it does for every other `.pub` template in that directory.

```
ls -l ~/.ssh/github-agent.pub
```

Expected: `-rw-------`.

```
jq '.env | has("GH_TOKEN"), has("GITLAB_TOKEN")' ~/.claude/settings.json
```

Expected: `true` twice (it prints no value).

```
ssh -F ~/.config/agent-identity/ssh_config -T git@github.com
```

This is a diagnostic, not a pass criterion: it uses the agent configuration without the session.
Expected: `Hi <agent-account>! You've successfully authenticated…` (exit status 1 is normal, GitHub
gives no shell). 1Password may ask to approve the key.

If it fails:
- `modify settings.json: 1Password lists "GitHub Agent Token" but its token cannot be read —
  refusing to overwrite` (or the GitLab one): that item exists but its `token` field is empty or
  not labelled `token`. Fix the label (steps 3 and 4) and apply again. The old settings file is untouched.
- `chezmoi apply` stops at an `op` error: unlock 1Password, `op whoami`, apply again.
- `jq` prints `false` for a variable, or `github-agent.pub` is absent: the item is not listed in
  vault Private under that exact title; fix the title, apply again.
- The diagnostic greets `<owner>` or says `Permission denied (publickey)`: the key on the machine
  account's keys page is not the item's public key (step 2), or 1Password's SSH agent does not
  serve the Private vault (check its `agent.toml` if you have one).

### Rollback, group B

- The identity (quick, no code change): the group A rollback above, then `chezmoi apply`. Sessions
  fall back to your own logins.
- The hook: it is `hooksPath = ~/.config/git/hooks` in `dot_config/git/config` plus the commit that
  moved the scan. In a `wt` checkout, unset that line and revert the scan commit, merge, apply (spec
  section 7). In an emergency for one push of yours, `git push --no-verify` skips the hook; the
  hook is hygiene, not a boundary.
- All of merge 1: `git revert` its commits in a `wt` checkout, merge, apply. Forge rules stay.

## Group C: the baseline check

### Step 7. Run the check (needs step 6)

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check
```

It is read-only (GET calls only) and walks `~/.local/share/chezmoi` and `~/Code/*/*`. It needs
`gh`, `glab` (logged in to gitlab.com) and `az` on the path, plus `jq` and `git`. A forge call that
gets no answer in 20 s is `unreadable`; raise it with `FORGE_PROTECTION_TIMEOUT=60` if a slow
network needs it. Keep the output on screen.

Verify: a first line `# This output names repositories: …`, one row per remote, `ok`, `drift`
(with the lines to paste), `unreadable` (with a reason) or `excepted`, and a last line `forge-protection: N
repositories: a ok, b drift, c unreadable, d excepted; e checkouts without origin skipped`. Expect
roughly 36 rows (2 GitHub, 28 plus 3 inaccessible GitLab, 3 Azure), mostly `drift`, a few
`unreadable`. The exit status is 1 until everything is `ok` or `excepted`.

Printed lines quote any word with a character a shell treats specially (including `=`, so the
GitLab POST reads `-f 'name=<branch>'`): paste them exactly as printed, quotes included; a plain
name appears bare.

If it fails: `unknown forge host <host>` means a remote uses an SSH host alias; the check refuses to
guess, and an alias that resolves to `github.com` would push with your key: fix the remote or
except it (step 13). A row `unreadable` with `no answer within 20s` for Azure is the known `az`
hang (step 12): only a timeout stops the later Azure rows (they read `az did not answer earlier in
this run`); any other Azure failure, such as `HTTP 404` on one repository, makes just that row
`unreadable`. `HTTP 404` on a GitLab project is a project you cannot see (step 13).

No rollback: it changes nothing.

## Group D: GitHub

### Step 8. The rulesets (needs step 7)

For each GitHub repository the check marks `drift`, paste the `gh api --method POST …/rulesets`
lines it printed, in your own terminal. The dotfiles repository already has `protect-main`, so it
gets only `main-owner-only`; the second repository gets both. The printed forms are:

```
gh api --method POST repos/<owner>/<repo>/rulesets --input <(printf '%s\n' '{"name":"protect-main","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["refs/heads/<branch>"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}')
```

```
gh api --method POST repos/<owner>/<repo>/rulesets --input <(printf '%s\n' '{"name":"main-owner-only","target":"branch","enforcement":"active","bypass_actors":[{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"update"},{"type":"creation"}]}')
```

Paste the check's own line, not these: its `<repo>` and `<branch>` are filled in. They are two
separate rulesets on purpose: a bypass actor bypasses every rule of its ruleset, so merged into one
you could force-push `main` again. Do the dotfiles first and finish the role check below before
the second repository, because a wrong role id would lock you out of pushing `main`.

If the check printed a `# in the UI: https://github.com/<owner>/<repo>/rules/<ruleset-id>: …`
note instead, a ruleset has the rules but is not Active or has the wrong bypass list: fix that page
as the note says. Create rulesets Active, as printed, never in evaluate mode.

**UNVERIFIED: role id 5 is "Repository admin".** Verify in the UI before going on: Settings >
Rules > Rulesets > `main-owner-only`: the bypass list shows only "Repository admin", mode "Always
allow". Or:

```
gh api repos/<owner>/<repo>/rulesets/<ruleset-id> --jq .bypass_actors
```

Expected: one entry with `"actor_id":5` and `"actor_type":"RepositoryRole"`. (The check accepts
id 5 without proving what it is; this is the only proof.)

**UNVERIFIED: `rules/branches/<branch>` shows rulesets in evaluate mode.** Not needed if you create
the rulesets Active. If the check says `drift` for a ruleset you made in evaluate mode, it may
be because that endpoint does not return it; look at the Rules page before posting a second one.

Verify, for each repository:

```
gh api repos/<owner>/<repo>/rules/branches/<branch> --jq '[.[].type] | sort'
```

Expected: `["creation","deletion","non_fast_forward","update"]`.

If it fails:
- A POST returning 403 or 404: your `gh` login lacks `repo` scope or admin on that repository.
  `gh auth status`.
- A POST returning 422 `name must be unique`: a ruleset of that name exists; list with
  `gh api repos/<owner>/<repo>/rulesets --jq '.[] | [.id, .name, .enforcement]'` and fix it in the UI.
- A missing type in the list: one of the rulesets did not apply; re-run the check, it prints what is left.
- If the first push of `main` after this is refused for you: delete `main-owner-only` (rollback
  below) and tell the line; the role id is wrong.

### Step 9. The collaborator (needs step 8 for that repository)

Only after the rulesets: until then the machine account would have write on an unprotected `main`.
This is spec section 2.1's command, not a line the check prints. For each repository:

```
gh api --method PUT repos/<owner>/<repo>/collaborators/<agent-account> -f permission=push
```

Accept the invitation as the machine account: sign in as it and open the emailed link, or
`https://github.com/<owner>/<repo>/invitations`.

Verify:

```
gh api repos/<owner>/<repo>/collaborators/<agent-account>/permission --jq .permission
```

Expected: `write` (`read` while the invitation is pending).

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api repos/<owner>/<repo> --jq '[.permissions.push, .permissions.admin]'
```

Expected: `[true,false]`: it can push branches, and it is not an admin, so it can neither edit rulesets
nor bypass them.

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api repos/<owner>/<repo>/rulesets/<ruleset-id> --jq .current_user_can_bypass
```

Run with the id of `main-owner-only`. Expected: `never`.

If it fails: still `read` means the invitation is pending or expired: `gh api repos/<owner>/<repo>/invitations --jq '.[].invitee.login'` lists
pending ones; resend the PUT. `[true,true]` means the account was made admin: remove it and invite
again with `permission=push`.

No live push against a default branch is tried to prove the refusal: a probe that the forge failed
to refuse would itself move the branch. Your own next `pom` is the proof that the owner bypass works.

### Rollback, group D

Per ruleset, as the owner (never delete the dotfiles' `protect-main`: it predates this work):

```
gh api repos/<owner>/<repo>/rulesets --jq '.[] | [.id, .name]'
```

```
gh api --method DELETE repos/<owner>/<repo>/rulesets/<ruleset-id>
```

or Settings > Rules > Rulesets > the ruleset > Delete. Remove the collaborator:

```
gh api --method DELETE repos/<owner>/<repo>/collaborators/<agent-account>
```

Revoke the token (group A rollback). The forge rules stay if you only roll back the identity.

## Group E: GitLab branch protection

What this costs you: you can no longer push a default branch directly on GitLab, on the small
single-developer projects included; every change lands through a merge request you merge. As the
Owner you can lift the rule in the UI when you need to.

Changes are made **in place**. Never unprotect a branch and protect it again: between the two
calls, or for good if the second fails, the branch would accept a force push its old rule refused.
The check never prints a DELETE.

### Step 10. One project first (needs step 7)

Pick one project the check marked `drift` that already has a rule (it printed a `--method PATCH`
line). Record its rule before changing it, into a file outside this repository:

```
mkdir -p ~/.local/state/forge-protection
glab api --hostname gitlab.com projects/<project-id>/protected_branches/<rule-name-uri-encoded> > ~/.local/state/forge-protection/before-<project-id>.json
jq '{id, push: [.push_access_levels[].access_level], merge: [.merge_access_levels[].access_level], force: .allow_force_push}' ~/.local/state/forge-protection/before-<project-id>.json
```

Note the `id`. Then paste the check's printed line for that project. Its form:

```
glab api --hostname gitlab.com --method PATCH projects/<project-id>/protected_branches/<rule-name-uri-encoded> -H 'Content-Type: application/json' --input <(printf '%s\n' '{"allow_force_push":false,"allowed_to_push":[{"id":<entry-id>,"_destroy":true},{"access_level":0}]}')
```

The JSON holds only what must change: `allow_force_push:false`, `allowed_to_push` (each offending
entry destroyed, and `{"access_level":0}` added when no "No one" entry remains), and
`allowed_to_merge` (each offender destroyed, `{"access_level":40}` added when no entry remains).
For a project with no rule for its default branch the check prints a POST instead:

```
glab api --hostname gitlab.com --method POST projects/<project-id>/protected_branches -f 'name=<branch>' -f push_access_level=0 -f merge_access_level=40 -f allow_force_push=false
```

**UNVERIFIED: GitLab Free accepts the PATCH fields.** Verify:

```
glab api --hostname gitlab.com projects/<project-id>/protected_branches/<rule-name-uri-encoded> | jq '{id, push: [.push_access_levels[].access_level], merge: [.merge_access_levels[].access_level], force: .allow_force_push}'
```

Expected: `push` `[0]`, `merge` `[40]` (or `[0]`), `force` `false`, and the same `id` as before (the
rule was changed, not recreated). I could not confirm that `glab api` has a `--jq` flag, so the
output is piped to `jq`.

If it fails: if GitLab answers 400 or 422 for `_destroy` or the other fields, nothing was changed
(read the rule again to be sure), and you use the UI form the check prints under each line for every
project: Settings > Repository > Protected branches > the rule: Allowed to push and merge: No one
(and Allowed to merge: Maintainers where the note says so); Allowed to force push: off. Tell the line
which form worked, so the printed form is corrected before merge 2. A 403 means your `glab` login is
not Owner there; that project is a step 13 candidate.

### Step 11. The rest (needs step 10 working, or the UI form)

Paste each remaining `drift` project's printed line, or use the UI form. Then run the check again
(step 7's command): every GitLab row should read `ok` except the projects you have no access to.

If it fails: a row that stays `drift` prints what is left, including a permissive wildcard rule
that matches the default branch (GitLab applies the most permissive rule): patch that rule too.
An `unreadable` row with `HTTP 403` or `HTTP 404` is a project you cannot administer (step 13).

### Rollback, group E

Per project, in the UI (Settings > Repository > Protected branches): put "Allowed to push and
merge" back to what `~/.local/state/forge-protection/before-<project-id>.json` recorded and the
force-push toggle back, on the same row. A rule created by a printed POST was not there before:
unprotecting it (the row's Unprotect button) returns the project to its earlier state. Revoke the
GitLab token (group A rollback). The tokens were never needed for this group: the check ran as you.

## Group F: Azure DevOps

What this costs you: with a blocking policy and your effective rights set to Deny, direct pushes of
the default branch fail for you too; every change lands through a pull request (the printed policy
lets you approve your own).

### Step 12. Read, then set (needs step 7)

**UNVERIFIED: all of this group.** The state of the three repositories has never been read, because
`az repos` produced no output from an agent session. If `az repos` hangs in your terminal too,
look for a pending prompt of the outbound firewall for `az` or its Python, and allow it; if
`az` asks for the extension, `az extension add --name azure-devops`. Where `az` stays unusable,
use the UI paths below.

For each of the three repositories, the check's row gives `dev.azure.com/<org>/<project>/<repo>`.
Read the repository and its policies:

```
az repos show --org <org-url> --project <project> --repository <repo> --output json
```

`<org-url>` is `https://dev.azure.com/<org>`. Note `id` (the `<repo-id>`), `defaultBranch` and
`project.id`.

```
az repos policy list --org <org-url> --project <project> --repository-id <repo-id> --branch <branch> --output json
```

Target: an enabled, blocking policy of type "Minimum number of reviewers" with at least 1
reviewer. The check recognises the type by its type id, `fa4e907d-c16b-4a4c-9dfa-4906e5d171dd`
(`type.id`), never by the display name, which is localised. **UNVERIFIED:** that id is taken from
documentation; confirm it the first time you read a real policy list (the `type` object of the
reviewers policy shows it), and tell the line if it differs. Where there is no such policy, the
check prints (once `az` answers; each value is single-quoted only when it holds a character that
a shell treats specially, so a plain name appears bare):

```
az repos policy approver-count create --org <org-url> --project <project> --repository-id <repo-id> --branch <branch> --blocking true --enabled true --minimum-approver-count 1 --creator-vote-counts true --allow-downvotes false --reset-on-source-push false
```

It needs the Edit policies permission (Project Administrators). Where you lack it, or `az` hangs,
the UI path: Project settings > Repositories > `<repo>` > Policies > Branch policies > the branch >
Minimum number of reviewers: On, Required, 1 reviewer, "Allow requestors to approve their own
changes" on.

Then your effective permissions on that branch. In the UI: Repos > Branches > `<branch>` > ⋯ >
Branch security > your user. "Force push (rewrite history, delete branches and tags)", "Bypass
policies when pushing" and "Bypass policies when completing pull requests" must not show Allow
(own or inherited); where one does, set it to **Deny** for your user on that branch. The check
reads the same with this call, which the script runs but does not print:

```
az account show --query user.name --output tsv
```

```
printf '%s' <branch> | iconv -f UTF-8 -t UTF-16LE | xxd -p
```

(for `main` that prints `6d00610069006e00`; a branch name with `/` is converted one segment at a
time and the segments joined with `/`.)

```
az devops security permission show --id 2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87 --subject <user-name> --token repoV2/<project-id>/<repo-id>/refs/heads/<hex-branch>/ --org <org-url> --output json
```

**UNVERIFIED: the bits and token format.** The script treats bit values 8 (force push), 128 (bypass
policies when pushing) and 32768 (bypass policies when completing pull requests) in any
`extendedInfo.effectiveAllow` as drift. Confirm those match the names in the dialog. The script
never reads `effectiveDeny`: a bit present in both `effectiveAllow` and `effectiveDeny` counts as
allowed (a group grant can still apply), so its note tells you to check the groups when the dialog
already shows Deny for your user.

**Do this on ONE repository before trusting any Azure row.** Run the `az devops security permission
show` call above (the one the script makes) and open that branch's Branch security dialog for your
user. Compare "Bypass policies when pushing", "Bypass policies when completing pull requests" and
"Force push" there with the check's reading. If the dialog shows Allow for any of the three while
the check says `ok`, the token format is wrong: stop and report it to the line, and do not rely on
the Azure rows.

**UNVERIFIED: whose rights the check reads.** The subject is `az account show`'s user. If you push
to Azure with a different identity (a PAT of another account), the check does not describe that
identity.

**UNVERIFIED: policy scope.** A policy scoped by prefix or to all branches may not be returned by
the exact-branch `az repos policy list` read; the check then prints a create for a branch that is
already covered. Check the existing policies in the UI (Project settings > Repositories > `<repo>`
> Policies > Branch policies) before pasting a create.

**UNVERIFIED: an empty `acesDictionary`.** If your rights come only through groups, this answer may hold no
entry for you, and the check then marks the row `unreadable` ("the permission answer holds no
whole effectiveAllow for the subject"). Then the dialog is the reading; setting an explicit Deny
for your user may also create the entry the check needs (unconfirmed).

Verify:

```
az repos policy list --org <org-url> --project <project> --repository-id <repo-id> --branch <branch> --query "[?isEnabled && isBlocking].type.id" --output json
```

Expected: includes `"fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"` (Minimum number of reviewers), or the UI
shows the policy as Required. Then
re-run the check (step 7's command): the row reads `ok`.

If it fails: a row that stays `drift` prints the exact UI path and the permission names to Deny. A
repository whose policies or permissions you cannot edit goes to the exceptions file (step 13) and the
line is told.

### Rollback, group F

In the UI: Project settings > Repositories > `<repo>` > Policies > Branch policies > the policy
> Delete; and Branch security > your user: set the three permissions back to "Not set".

## Group G: the exceptions file

### Step 13. Write it (needs steps 7 to 12 done as far as they go)

`~/.config/forge-protection/exceptions` is yours alone: it is outside this repository and outside
the sandbox's writable paths. Use it only for the repositories you knowingly accept as unprotected:
the GitLab projects that answer 404 (not yours to administer), and any Azure repository you cannot
edit or read. Without the file nothing is excepted. Do not add it to chezmoi: this repository is public.

Format, as the script reads it: one remote URL per line, in any form git accepts. Blank lines and
lines whose first character after leading spaces is `#` are skipped; surrounding whitespace and a
carriage return are trimmed. Each line is normalized like an origin (lower-cased, scheme, user,
port and a trailing `.git` or `/` dropped, scp form read, every Azure URL form turned into
`dev.azure.com/<org>/<project>/<repo>`) and must equal a row's name exactly; a comment after a URL on the
same line is not stripped and makes it not match. An excepted row is never queried and prints `excepted`.

```
mkdir -p ~/.config/forge-protection
git -C <checkout> remote get-url --push origin >> ~/.config/forge-protection/exceptions
```

The second command appends one checkout's push URL (the address the check reads); repeat per
repository, and add `# why` comments on their own lines.

Verify:

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"
```

Expected: `exit 0`, and the summary's `d excepted` equals the number of lines in the file. A listed
repository that still shows `unreadable` has a URL that normalizes differently: compare the row's
name with the line.

If it fails: an exception hides a real problem for good, so keep the list to the section 2.4 cases and
review it whenever it grows.

### Rollback, group G

Delete the file: nothing is excepted, and the check reports those repositories again.

## Group H: verification (spec section 6; needs everything above)

### Step 14. From your own terminal

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"
```

Expected: `exit 0`, every row `ok` or `excepted`, the excepted rows only the section 2.4 repositories
and their count the one you expect. Run by you, `bypass_actors` is visible, so this proves the whole
target, including that `protect-main` binds you too.

```
gh api repos/<owner>/<repo>/rules/branches/<branch> --jq '[.[].type] | sort'
```

Expected, for both GitHub repositories: `["creation","deletion","non_fast_forward","update"]`.

```
gh api repos/<owner>/<repo>/collaborators/<agent-account>/permission --jq .permission
```

Expected: `write`.

```
ssh -T git@github.com
```

Expected: `Hi <owner>!` (exit status 1 is normal). Your own shell must greet you: the handoff of merge 2
(you push the dotfiles' `main` yourself with `pom`) depends on it.

If it fails: the first command's remaining rows say which step to repeat. `ssh -T` greeting
`<agent-account>` means your own SSH configuration or agent offers the machine key: look at `~/.ssh/config`
and 1Password's agent order.

### Step 15. From a new agent session

Start a **new** Claude Code session after step 6 (the tokens are read from the settings at start),
in `~/.local/share/chezmoi-feat-forge-push-protection`, and ask it to run the following with its
Bash tool, sandboxed. Do not run these with `!` in the session, and never with the sandbox off.

```
./tests/run.sh live-agent-auth
```

Expected: `AUTH=READY`, `GITHUB_SSH=AGENT`, `GITLAB_SSH=READY`, exit 0. `GITHUB_SSH=INERT` means
`~/.ssh/github-agent.pub` or `~/.config/agent-identity/ssh_config` is absent (step 6); `MICHAEL`
means the session greeted `<owner>` (the agent configuration is not used; check that
`GIT_SSH_COMMAND` is the `ssh-sandbox-proxy` path); `NO_GREETING` means no `Hi <login>!` (key not
on the machine account, or 1Password's socket unreachable from the sandbox); `KEY_REJECTED` for GitLab means the sandbox
key was refused.

The session's own transport (the wrapper and configuration git uses, not a bare `ssh`):

```
sh -c "$GIT_SSH_COMMAND -T -o BatchMode=yes -o ConnectTimeout=15 git@github.com"
```

Expected: `Hi <agent-account>!`.

```
gh api user --jq .login
```

Expected: `<agent-account>`.

```
test -n "$GH_TOKEN" && test -n "$GITLAB_TOKEN" && echo set
```

Expected: `set` (it prints no value).

The GitLab agent token reads one project's protection (the check depends on it):

```
glab api --hostname gitlab.com 'projects/<project-id>/protected_branches?per_page=1' | jq length
```

Expected: a number, not an error. And:

```
glab api --hostname gitlab.com personal_access_tokens/self | jq 'del(.token)'
```

Expected: no merge, approve, protect or project-update permission.

The check as the agent (proves the agent cannot bypass):

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"
```

Expected: the GitHub and GitLab rows `ok`. The Azure rows will probably read `unreadable` (the
first "no answer within 20s", the rest "az did not answer earlier in this run") while `az` still
hangs from a session: that is the known hang, and it is why
the exit-0 proof of step 14 comes from your own terminal. If the session shows `excepted 0` while
the file has lines, the sandbox may not read it (UNVERIFIED); that is not a defect of the
protection.

If it fails: a GitHub row `unreadable` with `HTTP 403` or `404` for the agent means the token cannot
read that repository's rules; a row that shows `drift` only here means a ruleset the agent could
bypass (`current_user_can_bypass` is not `never`): recheck step 9's last verification.

### Step 16. Record

Tell the line, in the session or by paste, with no repository names:

```
Merge 1 is verified. Results: <check exit codes and the counts a ok / d excepted, own terminal and
session>; GitHub rules and collaborator permission as expected; ssh greetings as expected;
live-agent-auth GITHUB_SSH=<value> GITLAB_SSH=<value>. Confirmed or corrected: classic public_repo
token <yes/no>; role id 5 is Repository admin <yes/no>; rules/branches shows evaluate-mode
rulesets <yes/no/not tried>; GitLab PATCH accepted on Free <yes, or UI used>; GitLab token
permission names <list>; Azure: <what az printed, what the bits and token format did, whether the
dialog comparison agreed with the check, whether the reviewers type id matched, whether the empty
acesDictionary case or a prefix-scoped policy occurred>. Please put them in the spec's Implementation notes and plan
merge 2.
```

If any of these differ from what the code assumes, the line corrects the printed forms before merge 2.

## What stays owed after these steps

- **The rebase.** `feat/forge-push-protection` is rebased onto `main` once `chore/test-audit` has merged,
  then `./tests/run.sh git-forge-guard pre-pu hook-path` runs again (`git-forge-guard` exactly, to
  lift its heavy gate; `pre-pu` selects the hook suite). The audit cuts rows in suites this work
  extends, so the rows added here are re-checked against the new "test behaviour, not wording" rule.
- **Merge 2 has no plan yet.** Its plan is written only after your verification results are in the
  spec's Implementation notes (step 16): deleting the hidden-spelling machinery, the default-branch
  push going from ask to deny, and the `global.md` wording (section 4). Until it is applied, the full
  local guard stays live.
- **The line's checkout** stays until merge 2 is merged; the final report gives the `wt-rm <branch>`
  command to run then, and nothing before.
- If your steps have not happened when merge 1 is done, the line stops there and is reported as
  waiting on you.
