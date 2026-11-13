# Forge push protection: Michael's steps after merge 1

**Status:** In progress

**Spec:** `docs/superpowers/specs/2026-11-12-forge-push-protection-design.md` (sections 1, 2, 3, 6, 7).
**Plan:** `docs/superpowers/plans/2026-11-12-forge-push-protection-merge-1.md` (Task 9, "Michael's steps").

Run the commands from your own terminal unless a step says the agent session: after step 9, in a
session `gh` carries the `GH_TOKEN` of the 1Password item `GitHub Agent Token` (decision a says
whose it is), and `GIT_SSH_COMMAND` selects the machine account's key. Never use `!` in a session
for a step here.

Placeholders: `<agent-account>` (the machine account's login), `<owner>` (your own GitHub login),
`<repo>`, `<repo-a>` and `<repo-b>` (repositories you chose), `<scratch-repo>` (a throwaway
repository of yours), `<branch>` (the default branch), `<project-id>` (GitLab's numeric id),
`<org-url>`, `<project>`, `<repo-id>`, `<ruleset-id>`. Real values come from the check's output,
which stays on your screen or in a file outside this repository: it names repositories, so never
commit it, paste it into a tracked file or put it in a report. Report counts only.

Commands and item names are copied from the committed code: `.scripts/forge-protection.sh` (the
lines it prints), `dot_claude/modify_private_settings.json`, `private_dot_ssh/private_github-agent.pub.tmpl`,
`dot_config/agent-identity/ssh_config` and `tests/live-agent-auth.test.sh`. Where this file and
the plan differ, this file follows the code.

## Checklist

Three decisions come first: GitHub identity reach and authorship, GitLab on shared projects, secret scan stays in guard ([Three decisions first](#three-decisions-first)). Then, in order, do and verify; the long form below is the reference.

1. Create the GitHub machine account at github.com/signup, two-factor on ([Step 1](#step-1)).
   Verify: `https://github.com/settings/security` shows two-factor authentication enabled.
2. 1Password SSH Key item `GitHub Agent SSH Key`, then `op read "op://Private/GitHub Agent SSH Key/public key" | pbcopy` and paste it at Settings > SSH and GPG keys ([Step 2](#step-2)).
   Verify: `op read "op://Private/GitHub Agent SSH Key/public key" | ssh-keygen -lf -` prints `256 SHA256:… (ED25519)`, the fingerprint on `https://github.com/settings/keys`.
3. Fine-grained token of your own account (Settings > Developer settings > Personal access tokens), item `GitHub Agent Token`, field `token`; details: [Step 3](#step-3) below.
   Verify: `GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api user --jq .login` prints `<owner>`.
4. GitLab: Edit profile > Access tokens > Add new token (fine-grained), item `GitLab Agent Token`, field `token`; details: [Step 4](#step-4) below.
   Verify: `GITLAB_TOKEN="$(op read 'op://Private/GitLab Agent Token/token')" glab api --hostname gitlab.com personal_access_tokens/self | jq 'del(.token)'` lists no merge, approve, protect or project-update permission.
5. `git -C ~/.local/share/chezmoi merge --ff-only feat/forge-push-protection`, then `git -C ~/.local/share/chezmoi pom` ([Step 5](#step-5)).
   Verify: `git -C ~/.local/share/chezmoi status --short --branch` prints `## main...origin/main` with no `ahead`.
6. `~/.local/share/chezmoi/.scripts/forge-protection.sh check > ~/.local/state/forge-protection/check.txt` (after `mkdir -p ~/.local/state/forge-protection`) ([Step 6](#step-6)).
   Verify: `tail -n 1 ~/.local/state/forge-protection/check.txt` prints `forge-protection: N repositories: a ok, b drift, c unreadable, d excepted; e checkouts without origin skipped`.
7. Filter the check's GitHub remedy lines for the repositories you chose, read them, then `bash ~/.local/state/forge-protection/github-remedies.sh`; dotfiles first; details: [Step 7](#step-7) below.
   Verify: `gh api repos/<owner>/<repo>/rules/branches/<branch> --jq '[.[].type] | sort'` prints `["creation","deletion","non_fast_forward","update"]`.
8. `for r in <repo-a> <repo-b>; do gh api --method PUT repos/<owner>/$r/collaborators/<agent-account> -f permission=push; done`, then accept each invitation as the machine account ([Step 8](#step-8)).
   Verify: `for r in <repo-a> <repo-b>; do gh api repos/<owner>/$r/collaborators/<agent-account>/permission --jq .permission; done` prints `write` for each.
9. `command -v gitleaks` (must print a path), then `chezmoi apply`, plain, never `chezmoi diff` ([Step 9](#step-9)).
   Verify: `git config --global --get core.hooksPath` prints `~/.config/git/hooks`; the other checks: [Step 9](#step-9) below.
10. One GitLab project first: record its rules with `glab api --hostname gitlab.com 'projects/<project-id>/protected_branches?per_page=100' > ~/.local/state/forge-protection/before-<project-id>.json`, then paste the check's printed line for it; details: [Step 10](#step-10) below.
    Verify: `glab api --hostname gitlab.com projects/<project-id>/protected_branches/<rule-name-uri-encoded> | jq '{id, push: [.push_access_levels[].access_level], merge: [.merge_access_levels[].access_level], force: .allow_force_push}'` shows push `[0]`, merge `[40]` (or `[0]`), force `false`, the same `id`.
11. Record every chosen project's rules first, then `bash ~/.local/state/forge-protection/gitlab-remedies.sh`; details: [Step 11](#step-11) below.
    Verify: re-run Step 6's command into a new file; every GitLab row you chose reads `ok`.
12. Azure, per repository: save the policy list and permissions first, then paste the check's printed `az repos policy approver-count create …` line; details: [Step 12](#step-12) below.
    Verify: `az repos policy list --org <org-url> --project <project> --repository-id <repo-id> --branch <branch> --query "[?isEnabled && isBlocking].type.id" --output json` includes `"fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"`.
13. Exceptions file: `git -C <checkout> remote get-url --push origin >> ~/.config/forge-protection/exceptions` for one repository; the `awk` form for many is in [Step 13](#step-13) below.
    Verify: `~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"` prints `exit 0`, and `d excepted` equals the file's line count.
14. From your own terminal: `~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"` ([Step 14](#step-14)).
    Verify: `exit 0`, every row `ok` or `excepted`; `ssh -T git@github.com` greets `Hi <owner>!`; the other commands: [Step 14](#step-14) below.
15. In a new agent session started after step 9, ask it to run, sandboxed, `./tests/run.sh live-agent-auth`; never with `!` ([Step 15](#step-15)).
    Verify: `AUTH=READY`, `GITHUB_SSH=AGENT`, `GITLAB_SSH=READY`, exit 0; the other commands: [Step 15](#step-15) below.
16. Tell the line the results by the template in [Step 16](#step-16), with no repository names; no command.
    Verify: the line has the results and puts them in the spec's Implementation notes.

Rollbacks: sections "Rollback, group A", B, D, E, F, G and H (group C changes nothing). Accepted limits: section "Accepted limits and rulings".

## Three decisions first

**Decided on 2026-11-13 (Michael, relayed by the driver session): a and b as recommended, c
accepted as built.** The steps below already follow them; the check in a that the token cannot
merge is still yours to make.

Read these before step 1. The steps below follow the recommendations; each decision says what
changes in them if you decide otherwise. None needs a code change in merge 1 unless it says so.

### a. GitHub identity reach and authorship

**Found.** The agent SSH key is pinned for every `github.com` remote, and `GH_TOKEN` in agent
sessions would be the machine account's token. The read-only check, with its walk widened to three
levels under `~/Code`, read 86 repositories on 2026-11-13; on GitHub that is 43 repositories of
your own, all drift, and 14 owned by others that it cannot read (HTTP 403). The spec assumed two
GitHub repositories.

**Consequence.** An agent cannot push to a repository where the machine account is not a
collaborator, and cannot fetch it if it is private, because the pinned key is the only one offered
to `github.com`. And with the machine account's token every pull request, issue and comment an
agent opens is authored by the machine account, against the rule that the published record is
yours.

**Recommendation.** (i) Keep pushes on the machine account's SSH key, and add it as collaborator
only on the repositories agents actually work in (step 8). (ii) Make the 1Password item `GitHub
Agent Token` a fine-grained token of **your own** account with Contents: read, Pull requests:
write, Issues: write, Metadata: read and nothing else. Pull requests and issues are then yours, and
the token can neither push, merge (merging needs Contents: write) nor change rulesets (that needs
Administration); this mirrors the GitLab design. **UNVERIFIED:** that those permission names are
the form's, and that the token cannot merge. Verify as that token: a merge call on a test pull
request must be refused (step 3 gives the command). This needs no code change in merge 1: the item
name and its `token` field are the same. (iii) The dormant repositories: archive them on GitHub, or
list them in the exceptions file (step 13). The check does not yet treat an archived repository as
`ok`, so today they need an exceptions line either way.

**If you decide otherwise.** Keeping the machine account's own classic token: step 3 uses its
"classic variant", step 8's verifications use that token, step 15 expects `<agent-account>` from
`gh api user`, and authorship stays the machine account's. Making the machine account a
collaborator on all 43 repositories instead of a chosen few: steps 7 and 8 run over every own
row, and no dormant repository needs an exceptions line for the rulesets (only for the 14
unreadable ones). Under (ii) one more consequence: `current_user_can_bypass` describes the token's
user, which is you, the owner, so the agent-session check of step 15 may not read the GitHub rows
`ok`; see step 15. **UNVERIFIED.**

### b. GitLab on shared projects

**Found.** The check's target (push "No one", merge Maintainers, force push off) also removes
default-branch push from other project members and from any CI job or bot that pushes it, and
merge from Developers. The spec's "nothing visible to others" was wrong. The inventory now: 25
`gitlab.com` repositories, 22 of them drift and 3 unreadable.

**Consequence.** The merge-level clause does not constrain agents: they act as you, and their token
cannot merge. It only changes what your teammates can do.

**Recommendation.** Apply push "No one" only where you are the only one who pushes the default
branch directly. On projects with other members or a pushing CI job, decide per project, and use an
exceptions line where the change would hurt others. Also decide whether the merge-level clause
should leave the target: that is a small code change (in `check_gitlab` and its printed lines, and
its rows in `tests/forge-protection.test.sh`) for the line to make on your word.

**If you decide otherwise.** Patching all 22: steps 10 and 11 run over every `drift` GitLab row
and step 13 holds only the 3 unreadable ones. Dropping the merge clause: the printed lines lose
`allowed_to_merge`, and the target in step 10's "Expected" line loses its `merge` part.

### c. The secret scan stays partly in the guard

**Found.** Commit `6c3893d` (subject "Scan silent sends the global pre-push hook will not see"):
the push guard still scans an otherwise-allowed agent push when it cannot show that the deployed
hook will run for it. The cases are `--no-verify`, any environment assignment or wrapper on the
command, a `core.hooksPath` that is not the deployed hooks directory, and a missing or
non-executable hook.

**Consequence.** This restores main's verdicts for those pushes, and corrects spec section 5's
"only this call remains in the helper". A push the hook will see is scanned by the hook alone.

**Recommendation.** Keep it.

**If you decide otherwise.** Moving the whole scan into the hook is a code change for the line to
make on your word, and `--no-verify` or `HOME=` on an agent push would then skip the scan, as the
spec's section 5 says. No step here changes.

## What is unverified against a real forge

Each is marked **UNVERIFIED** at its step. You confirm it while doing the step and tell the line
what you saw, so the spec's Implementation notes and (for a wrong printed form) merge 2 are corrected.

| Item | Step |
|---|---|
| Decision a(ii): the fine-grained form's permission names, and that a token with only those permissions cannot merge | 3 |
| Only if decision a(ii) is declined: a classic `public_repo` token, not a fine-grained one, is what the machine account needs | 3 |
| Repository role id 5 is "Repository admin" (the check accepts id 5 without proving it) | 7 |
| `rules/branches/<branch>` returns rulesets in evaluate mode (the check and the verification both read it) | 7 |
| Decision a(ii): in an agent session the check reads `current_user_can_bypass` for the token's user (you), so the GitHub rows may not read `ok` there | 15 |
| The exact permission names of the GitLab fine-grained token form, and what `personal_access_tokens/self` returns for one | 4, 15 |
| GitLab accepts the printed PATCH (`_destroy` entries, `allowed_to_push`, `allowed_to_merge`) on Free | 10 |
| Azure: the state of all three repositories was never read, because `az repos` hung from an agent session (the outbound firewall is the first suspect) | 12 |
| Azure: the permission-bit values and the security token format the check uses | 12 |
| Azure: an empty `acesDictionary` for a user whose rights come only from groups makes the row `unreadable` | 12 |
| Azure: the check reads the rights of `az account show`'s user; if you push to Azure as another identity (a PAT of another account), it does not describe that identity | 12 |
| Azure: a policy scoped by prefix or to all branches may not be returned by the exact-branch read, so the check prints a create for a branch that is already covered | 12 |
| Azure: the reviewers-policy type id `fa4e907d-c16b-4a4c-9dfa-4906e5d171dd` is taken from documentation | 12 |

## Order

1. Steps 1 to 4: the accounts, tokens and 1Password items (group A). Nothing deployed changes.
2. Step 5: merge 1 into the main checkout and push `main` (group B). The hook and the identity are
   still not deployed; the check script is now in the main checkout.
3. Step 6: the baseline check (group C). Read-only, run as you; it needs no apply.
4. Steps 7 and 8: the GitHub rulesets and the collaborator (group D).
5. Step 9: the apply (group E). This is the step that switches agent sessions to the machine
   identity and puts the hook on your own pushes.
6. Steps 10 to 13: GitLab, Azure, the exceptions file (groups F to H). They run as you and need no
   apply, so they may also come before step 9; they follow it here so that the per-project GitLab
   decisions do not hold up the identity switch.
7. Steps 14 to 16: verification and the record (group I).

**The window.** From step 5 to step 9 nothing deployed changes: an agent session is still you, with
your keys and logins. The rulesets of step 7 do not constrain it in that window, because you bypass
them; the local push guard, which stays live until merge 2, is what covers it. From step 9 on, an
agent's GitHub push succeeds only on a repository where the machine account is a collaborator
(step 8), and fails with a permission error everywhere else, by decision a(i). Doing step 8 before
step 9 means there is no moment when a repository you chose has the machine account missing.

## Group A: accounts, tokens and 1Password items (no repository changes)

These can come before or after step 5, but step 9 needs steps 1 to 4 done: an item that does not
exist yet leaves its part inert, and a second `chezmoi apply` after creating it renders it.

### Step 1. Create the GitHub machine account <a id="step-1"></a>

Create a second GitHub account for the agent (github.com/signup; GitHub's terms allow one free
machine account beside a personal one). Use an email address you control that no other GitHub
account uses. Turn on two-factor authentication and keep the login, the authenticator secret and
the recovery codes in a 1Password item of your own naming. Do not title it `GitHub Agent SSH Key`
or `GitHub Agent Token`: those two titles are read by the code.

Verify: signed in as that account, `https://github.com/settings/security` shows two-factor
authentication enabled.

If it fails: enable it there before going on; the account must not exist without it.

### Step 2. Its SSH key (needs step 1) <a id="step-2"></a>

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

### Step 3. Its token (decision a; the recommended form needs no step before it) <a id="step-3"></a>

**As recommended (decision a(ii)): a fine-grained token of your own account.** Signed in as
yourself, not as the machine account: Settings > Developer settings > Personal access tokens >
Fine-grained tokens > Generate new token. Resource owner `<owner>`. Repository access: only select
repositories, the ones you give the collaborator in step 8 plus `<scratch-repo>` for the test
below. Repository permissions: Contents read-only, Pull requests read and write, Issues read and
write, Metadata read-only (the form adds it), and nothing else: no Administration, no Workflows,
no Actions. Set an expiry. Store it in 1Password: vault **Private**, item titled exactly `GitHub
Agent Token`, with the secret in a field labelled exactly `token` (an API Credential item has a
`credential` field: rename its label to `token`).

**UNVERIFIED: the permission names on the form, and that this set cannot merge.** Write down the
names you ticked and tell the line.

Verify (the token is only in that one command's environment; nothing prints it):

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api user --jq .login
```

Expected: `<owner>`: it is your account, so what it opens is authored by you.

The merge refusal, on a throwaway: in `<scratch-repo>` (a repository of yours that nothing depends
on) push a branch with one trivial commit from your own terminal and open a pull request, note its
number, then:

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api --method PUT repos/<owner>/<scratch-repo>/pulls/<number>/merge
```

Expected: refused (HTTP 403; the wording is unverified) and the pull request still open. If it
merges, revoke the token at once and tell the line: the permission set is wrong. Close the test
pull request, delete its branch, and take `<scratch-repo>` out of the token's repository list.

If it fails: `bad credentials` means the token was copied wrongly or has expired; 404 on the merge
call means the token cannot see `<scratch-repo>` (add it to the selection for the test). `op read`
failing means the field is not labelled `token`: step 9's apply would refuse for the same reason.

**Classic variant (only if you declined decision a(ii)).** Signed in as the machine account:
Settings > Developer settings > Personal access tokens > Tokens (classic) > Generate new token
(classic). Scope `public_repo` only, an expiry you will remember. Store it in the same item and
field. **UNVERIFIED: classic, not fine-grained.** The spec says a fine-grained token cannot reach
another user's personal repository. Confirm on `https://github.com/settings/personal-access-tokens/new`
as the machine account: "Resource owner" should offer only the machine account (and any
organisations it belongs to), never `<owner>`. If it does offer `<owner>`, stop and tell the line:
that is decision a(ii) available to the machine account itself, narrower than a classic token, and a
design change. Verify:

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api user --jq .login
```

Expected: `<agent-account>`.

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api -i user | rg -i '^x-oauth-scopes'
```

Expected: `X-Oauth-Scopes: public_repo`. An extra scope means regenerate it narrower.

### Step 4. The GitLab token (your own GitLab account, no second account) <a id="step-4"></a>

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
SSH key item in 1Password, remove the machine account's key at `https://github.com/settings/keys`,
revoke the GitHub token (the fine-grained one at `https://github.com/settings/personal-access-tokens`,
the classic one at `https://github.com/settings/tokens` as the machine account), and revoke the
GitLab token (Access tokens > Revoke). If step 9 has run, the next `chezmoi apply` (step 9's
command) then removes `GH_TOKEN`, `GITLAB_TOKEN` and `~/.ssh/github-agent.pub`: items not listed
are the inert state.

## Group B: merge

### Step 5. Merge 1 and push `main` from your own terminal <a id="step-5"></a>

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

### Rollback, group B

Nothing is deployed until step 9, so nothing needs undoing on the machine. To take merge 1 back
out of `main`, `git revert` its commits in a `wt` checkout and merge that (the commit list is in
the rollback of group E).

## Group C: the baseline check

### Step 6. Run the check (needs step 5; no apply) <a id="step-6"></a>

The script is in the main checkout once step 5 has merged; the check runs as you, so the apply
(step 9) is not needed. Keep the output in a file outside this repository, because steps 7 and 11
filter it:

```
mkdir -p ~/.local/state/forge-protection
~/.local/share/chezmoi/.scripts/forge-protection.sh check > ~/.local/state/forge-protection/check.txt
```

It is read-only (GET calls only) and walks `~/.local/share/chezmoi` and every checkout one to three
levels under `~/Code`, never entering a repository. It needs `gh`, `glab` (logged in to gitlab.com)
and `az` on the path, plus `jq` and `git`. A forge call that gets no answer in 20 s is
`unreadable`; raise it with `FORGE_PROTECTION_TIMEOUT=60` if a slow network needs it. With no
repository found it prints that and exits 1. The file names repositories: never copy it into a
tracked file.

Verify:

```
tail -n 1 ~/.local/state/forge-protection/check.txt
```

Expected: `forge-protection: N repositories: a ok, b drift, c unreadable, d excepted; e checkouts
without origin skipped`. The first line of the file is `# This output names repositories: …`, then
one row per push address of a checkout's `origin` (a checkout whose `origin` has several push
addresses gets a row for each): `ok`, `drift` (with the lines to paste), `unreadable` (with a
reason) or `excepted`. The counts here and in the summary line are approximate: rows are per push
address, not per checkout. Earlier, on 2026-11-13, the check read 86 repositories: GitHub 43 of your own `drift` and 14 of
other owners `unreadable` (HTTP 403); `gitlab.com` 22 `drift` and 3 `unreadable`; Azure DevOps 3
`unreadable` (read from an agent session, where `az` hangs); and 1 repository on a self-hosted
host the check does not know, `unreadable`. That is 65 `drift` and 21 `unreadable`, none `ok`. Your
numbers will differ if checkouts changed. The exit status is 1 until everything is `ok` or
`excepted`.

Printed lines quote any word with a character a shell treats specially (including `=`, so the
GitLab POST reads `-f 'name=<branch>'`): paste them exactly as printed, quotes included; a plain
name appears bare. Row names are lower-case.

If it fails: `unknown forge host <host>` means a remote uses an SSH host alias or a host the check
does not read (the self-hosted one); the check refuses to guess, and an alias that resolves to
`github.com` would push with your key: fix the remote or except it (step 13). A row `unreadable`
with `no answer within 20s` for Azure is the known `az` hang (step 12): only a timeout stops the
later Azure rows (they read `az did not answer earlier in this run`); any other Azure failure, such
as `HTTP 404` on one repository, makes just that row `unreadable`. `HTTP 404` on a GitLab project
is a project you cannot see (step 13).

No rollback: it changes nothing.

## Group D: GitHub

### Step 7. The rulesets (needs step 6) <a id="step-7"></a>

Choose the repositories agents actually work in (decision a(i)); call them `<repo-a>`, `<repo-b>`,
and so on. For each, the rulesets are the `gh api --method POST …/rulesets` lines the check printed
under its `drift` row. The dotfiles repository already has `protect-main`, so it gets only
`main-owner-only`; every other chosen repository gets both. The printed forms are:

```
gh api --method POST repos/<owner>/<repo>/rulesets --input <(printf '%s\n' '{"name":"protect-main","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["refs/heads/<branch>"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}')
```

```
gh api --method POST repos/<owner>/<repo>/rulesets --input <(printf '%s\n' '{"name":"main-owner-only","target":"branch","enforcement":"active","bypass_actors":[{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"always"}],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"update"},{"type":"creation"}]}')
```

Do not paste these: paste the check's own lines, whose `<repo>` and `<branch>` are filled in, and
not one repository at a time by hand. Filter the check's output for the remedy lines of the chosen
repositories into a file, read it, then run it. The pattern is the row name, lower-case, as the
check printed it; the dotfiles repository first:

```
want='^github\.com/<owner>/dotfiles$'
awk -v want="$want" '/^[a-z]/ { on = ($2 ~ want) } on && /^    gh api --method POST/' ~/.local/state/forge-protection/check.txt > ~/.local/state/forge-protection/github-remedies.sh
```

`awk` takes each row line (it starts with a lower-case letter) as the start of a repository and
keeps that repository's indented `gh api --method POST` lines. Read the file before running it:

```
less ~/.local/state/forge-protection/github-remedies.sh
```

Expected: only the repositories you named, each with the lines it needs, and no other command.
Then:

```
bash ~/.local/state/forge-protection/github-remedies.sh
```

A line that fails does not stop the others; step 6's command lists what is left. Do the dotfiles
first and finish the role check below before the rest, because a wrong role id would lock you out
of pushing `main`. Then the rest, with the pattern widened, the same way:

```
want='^github\.com/<owner>/(<repo-a>|<repo-b>)$'
```

and the same `awk` and `less`, then `bash`, with a new file name if you keep the first.

If the check printed a `# in the UI: https://github.com/<owner>/<repo>/rules/<ruleset-id>: …`
note instead (`awk -v want="$want" '/^[a-z]/ { on = ($2 ~ want) } on && /^    # in the UI/' …`
prints them), a ruleset has the rules but is not Active or has the wrong bypass list: fix that
page as the note says. Create rulesets Active, as printed, never in evaluate mode.

The 14 repositories of other owners (unreadable, HTTP 403) and the self-hosted one go in the
exceptions file (step 13), as do your own dormant repositories you did not choose (decision
a(iii)); they stay `unreadable` or `drift` until step 13.

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

Verify, for each chosen repository:

```
gh api repos/<owner>/<repo>/rules/branches/<branch> --jq '[.[].type] | sort'
```

Expected: `["creation","deletion","non_fast_forward","update"]`. Then re-run step 6's command into
a new file; each chosen row reads `ok`.

If it fails:
- A POST returning 403 or 404: your `gh` login lacks `repo` scope or admin on that repository.
  `gh auth status`.
- A POST returning 422 `name must be unique`: a ruleset of that name exists; list with
  `gh api repos/<owner>/<repo>/rulesets --jq '.[] | [.id, .name, .enforcement]'` and fix it in the UI.
- A missing type in the list: one of the rulesets did not apply; re-run the check, it prints what is left.
- If the first push of `main` after this is refused for you: delete `main-owner-only` (rollback
  below) and tell the line; the role id is wrong.

### Step 8. The collaborator (needs steps 2 and 7 for those repositories) <a id="step-8"></a>

Only after the rulesets: until then the machine account would have write on an unprotected `main`.
This is spec section 2.1's command, not a line the check prints, so it is a loop over the chosen
repositories:

```
for r in <repo-a> <repo-b>; do gh api --method PUT repos/<owner>/$r/collaborators/<agent-account> -f permission=push; done
```

Accept each invitation as the machine account: sign in as it and open the emailed link, or
`https://github.com/<owner>/<repo>/invitations` for each.

Verify:

```
for r in <repo-a> <repo-b>; do gh api repos/<owner>/$r/collaborators/<agent-account>/permission --jq .permission; done
```

Expected: `write` for each (`read` while its invitation is pending).

With the recommended token (decision a(ii)) it is your token, not the machine account's, so it
cannot describe the machine account. The machine account's reach is what the permission read above
shows: `write` is below `admin`, so it can neither edit rulesets nor, with `main-owner-only` active
and role 5 the only bypass, move the default branch. Confirm that list once for one repository:

```
gh api repos/<owner>/<repo>/rulesets/<ruleset-id> --jq .bypass_actors
```

Expected: only role 5 (the check of step 7).

Classic variant (decision a(ii) declined): the machine account's own token reads its rights:

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api repos/<owner>/<repo> --jq '[.permissions.push, .permissions.admin]'
```

Expected: `[true,false]`: it can push branches, and it is not an admin. And with the id of
`main-owner-only`:

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api repos/<owner>/<repo>/rulesets/<ruleset-id> --jq .current_user_can_bypass
```

Expected: `never`.

If it fails: still `read` means the invitation is pending or expired: `gh api repos/<owner>/<repo>/invitations --jq '.[].invitee.login'` lists
pending ones; resend the PUT. `admin` in the permission answer means the account was made admin:
remove it and invite again with `permission=push`.

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

## Group E: apply

### Step 9. Apply (needs steps 1 to 4, and steps 7 and 8 for the repositories you chose) <a id="step-9"></a>

From this apply on, agent sessions carry the machine account's SSH key for `github.com` and the
token of the `GitHub Agent Token` item, and every push of yours runs the hook (see the window in
"Order"). Start the session after it, not before: the tokens are read at session start.

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

### What the hook now does to your own pushes

The global hook is hygiene for agents and applies to you as well, from this apply on:

- **A first push of a long history** to a remote with no tracking refs (a fresh remote, a remote
  addressed by URL, or one whose push address differs from its fetch address) scans all of it and
  can run past the 30 s budget, which refuses the push. Raise it for that push with
  `SECRET_SCAN_BUDGET=<seconds>` in front of the command (the variable and its default of 30 are
  read in `dot_config/git/hooks/executable_secret-scan`), or skip the hook at your own terminal
  with `--no-verify`.
- **`.gitleaksignore` must be committed on the pushed ref.** A fingerprint counts only when the
  file in the work tree equals the one committed on the ref being pushed; otherwise the push is
  refused with "Commit the exception first". This binds your pushes now.
- **The messages are worded for agents.** "Push by hand" and "Restore it with chezmoi apply" mean,
  at your terminal, "fix the cause the message names, or accept it and use `--no-verify`".
- **A push from a bare repository is blocked** when it sends anything (the hook finds no work
  tree: "cannot resolve the work tree"); a push that only deletes refs passes. Use `--no-verify`
  there.

### Rollback, group E

- The identity (quick, no code change): the group A rollback above, then `chezmoi apply`. Sessions
  fall back to your own logins.
- The hook: it is `hooksPath = ~/.config/git/hooks` in `dot_config/git/config` plus the commits
  that moved the scan. In a `wt` checkout, revert these, newest first, identifying each by its
  subject because their SHAs change at a rebase (find them with `git -C ~/.local/share/chezmoi log
  --oneline -40 -- dot_config/git/hooks dot_claude tests/git-forge-guard.test.sh`):
  1. "Scan silent sends the global pre-push hook will not see" (the helper scans what the hook
     will not see)
  2. "Report a cold chezmoi cache in the pre-push hook suite as inconclusive" (the hook suite only;
     commit 6 creates that suite, so this one is reverted first)
  3. "Align the hung-gitleaks comment with the helper's process-group docstring" (a comment in the
     guard suite, reverted only so the chain applies)
  4. "Attribute a named remote's tracking refs only when it fetches and pushes to one address"
  5. "Close the review findings on the global hook and its suite"
  6. "Move the secret scan into a global git hook" (adds the hook, `secret-scan`, the
     `core.hooksPath` line and the move out of the helper)

  Revert 6 may need a hand merge in `tests/hook-path.test.sh`, which "Render the agent forge tokens
  into the Claude settings" also edits. "Deny agent edits of the forge protection exceptions and
  the deployed global hook" stays: it only denies edits of those paths. Then merge and apply (spec
  section 7). In an emergency for one push of yours, `git push --no-verify` skips the hook; the
  hook is hygiene, not a boundary.
- All of merge 1: `git revert` its commits in a `wt` checkout, merge, apply. Forge rules stay.

## Group F: GitLab branch protection

What this costs you: you can no longer push a default branch directly on GitLab, on the small
single-developer projects included; every change lands through a merge request you merge. As the
Owner you can lift the rule in the UI when you need to. On a project with other members it also
takes their direct pushes (and a pushing CI job's) away, and the merge level from Developers
(decision b): apply it where you alone push, decide the rest per project, and put the ones you
leave in the exceptions file (step 13).

Changes are made **in place**. Never unprotect a branch and protect it again: between the two
calls, or for good if the second fails, the branch would accept a force push its old rule refused.
The check never prints a DELETE.

### Step 10. One project first (needs step 6) <a id="step-10"></a>

Pick one project the check marked `drift` that already has a rule (it printed a `--method PATCH`
line). Record its rules before changing them, into a file outside this repository:

```
mkdir -p ~/.local/state/forge-protection
glab api --hostname gitlab.com 'projects/<project-id>/protected_branches?per_page=100' > ~/.local/state/forge-protection/before-<project-id>.json
jq '.[] | {id, name, push: [.push_access_levels[].access_level], merge: [.merge_access_levels[].access_level], force: .allow_force_push}' ~/.local/state/forge-protection/before-<project-id>.json
```

Note the `id` of the rule the PATCH names. Then paste the check's printed line for that project.
Its form:

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

### Step 11. The rest (needs step 10 working, or the UI form) <a id="step-11"></a>

Decide the project list first (decision b): the projects where you alone push the default branch.
Regenerate the check's output so step 10's project reads `ok` and is not repeated:

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check > ~/.local/state/forge-protection/check.txt
want='^gitlab\.com/(<path-a>|<path-b>)$'
awk -v want="$want" '/^[a-z]/ { on = ($2 ~ want) } on && /^    glab api /' ~/.local/state/forge-protection/check.txt > ~/.local/state/forge-protection/gitlab-remedies.sh
less ~/.local/state/forge-protection/gitlab-remedies.sh
```

(`<path-a>` is a row name's path after `gitlab.com/`, lower-case, with a nested group's slashes
kept.) Expected: only the projects you named, each with its PATCH or POST. **Before running any of
it, record the current state of every one of those projects, not only the first.** The ids are in
the printed lines:

```
for id in $(rg -o 'projects/[0-9]+' ~/.local/state/forge-protection/gitlab-remedies.sh | sort -u | cut -d/ -f2); do glab api --hostname gitlab.com "projects/$id/protected_branches?per_page=100" > ~/.local/state/forge-protection/before-$id.json; done
```

Then make sure every file is there and non-empty (a project with no rule holds `[]`):

```
for id in $(rg -o 'projects/[0-9]+' ~/.local/state/forge-protection/gitlab-remedies.sh | sort -u | cut -d/ -f2); do test -s ~/.local/state/forge-protection/before-$id.json || echo "missing or empty: $id"; done
```

Expected: no output. Only then:

```
bash ~/.local/state/forge-protection/gitlab-remedies.sh
```

Or use the UI form per project. Then run the check again (step 6's command, into a new file):
every GitLab row you chose should read `ok`, and the rest are what step 13 excepts or you decided to
leave `drift`.

If it fails: a row that stays `drift` prints what is left, including a permissive wildcard rule
that matches the default branch (GitLab applies the most permissive rule): patch that rule too.
An `unreadable` row with `HTTP 403` or `HTTP 404` is a project you cannot administer (step 13).

### Rollback, group F

Per project, in the UI (Settings > Repository > Protected branches): put "Allowed to push and
merge" back to what `~/.local/state/forge-protection/before-<project-id>.json` recorded (it holds
every rule of the project as it was) and the force-push toggle back, on the same row. A rule created
by a printed POST was not there before (`[]`): unprotecting it (the row's Unprotect button) returns
the project to its earlier state. Revoke the GitLab token (group A rollback). The tokens were never
needed for this group: the check ran as you.

## Group G: Azure DevOps

What this costs you: with a blocking policy and your effective rights set to Deny, direct pushes of
the default branch fail for you too; every change lands through a pull request (the printed policy
lets you approve your own).

### Step 12. Read, then set (needs step 6) <a id="step-12"></a>

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

**Record the state before you change anything**, for each of the three repositories, into files
outside this repository: the policy list above, and your three permissions on the branch. The
rollback of this group goes back to these files; without them it has nothing to go back to. Save the
policy list:

```
mkdir -p ~/.local/state/forge-protection
az repos policy list --org <org-url> --project <project> --repository-id <repo-id> --branch <branch> --output json > ~/.local/state/forge-protection/azure-before-<repo-id>-policies.json
```

Then the permissions, with the same calls the check makes (it runs them but does not print them):

```
az account show --query user.name --output tsv
```

```
printf '%s' <branch> | iconv -f UTF-8 -t UTF-16LE | xxd -p
```

(for `main` that prints `6d00610069006e00`; a branch name with `/` is converted one segment at a
time and the segments joined with `/`.)

```
az devops security permission show --id 2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87 --subject <user-name> --token repoV2/<project-id>/<repo-id>/refs/heads/<hex-branch>/ --org <org-url> --output json > ~/.local/state/forge-protection/azure-before-<repo-id>-permissions.json
```

The saved answer holds your own entry for the branch: its `allow` and `deny` bits (8 force push, 128
bypass policies when pushing, 32768 bypass policies when completing pull requests) next to
`extendedInfo`, which carries the inherited rights. **UNVERIFIED:** that the explicit entry shows
Allow, Deny or Not set exactly as the dialog does. So also open Repos > Branches > `<branch>` > ⋯ >
Branch security > your user and write the three values the dialog shows (Allow, Deny or Not set) into
`~/.local/state/forge-protection/azure-before-<repo-id>-dialog.txt`. Check that all three files exist
and are not empty before the next step; the policy file of a repository without policies holds `[]`.

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
reads the same with the permission call recorded above, which the script runs but does not print.

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
re-run the check (step 6's command): the row reads `ok`.

If it fails: a row that stays `drift` prints the exact UI path and the permission names to Deny. A
repository whose policies or permissions you cannot edit goes to the exceptions file (step 13) and the
line is told.

### Rollback, group G

Per repository, from the files recorded in step 12 (`azure-before-<repo-id>-policies.json`,
`-permissions.json` and `-dialog.txt` in `~/.local/state/forge-protection/`). Protection that existed
before these steps stays.

Policies: delete only a policy these steps created. Read the policy list again and list the ids the
recorded file does not hold:

```
az repos policy list --org <org-url> --project <project> --repository-id <repo-id> --branch <branch> --output json > ~/.local/state/forge-protection/azure-after-<repo-id>-policies.json
jq -n --slurpfile b ~/.local/state/forge-protection/azure-before-<repo-id>-policies.json --slurpfile a ~/.local/state/forge-protection/azure-after-<repo-id>-policies.json '[$a[0][].id] - [$b[0][].id] | .[]'
```

Each id printed is one of yours: Project settings > Repositories > `<repo>` > Policies > Branch
policies > that policy > Delete (or `az repos policy delete --id <policy-id> --org <org-url> --project <project>`;
**UNVERIFIED:** the flags, see `az repos policy delete --help`). A policy whose id the recorded file
holds existed before: delete nothing, and if you edited it in step 12 (turned it on, made it
Required, raised the reviewer count), put those settings back to the values the recorded file holds
(`isEnabled`, `isBlocking`, `settings.minimumApproverCount`, `settings.creatorVoteCounts`).

Permissions: Branch security > your user: set each of the three permissions (Force push, Bypass
policies when pushing, Bypass policies when completing pull requests) to the value `-dialog.txt`
recorded, which may be Allow or Deny as well as Not set. Never set all three to Not set without
reading it: a Deny that stood before these steps is protection, and an Allow that stood before them
is what it was (the check reports it as drift again).

## Group H: the exceptions file

### Step 13. Write it (needs steps 6 to 12 done as far as they go) <a id="step-13"></a>

`~/.config/forge-protection/exceptions` is yours alone: it is outside this repository and outside
the sandbox's writable paths. Use it only for the repositories you knowingly accept as unprotected:
the 14 GitHub repositories of other owners and the self-hosted one the check does not know, your
own dormant GitHub repositories you did not choose in step 7 (until they are archived and the check
reads archived as `ok`), the GitLab projects that answer 404 (not yours to administer) or that you
decided in step 11 not to change, and any Azure repository you cannot edit or read. Without the
file nothing is excepted. Do not add it to chezmoi: this repository is public.

Format, as the script reads it: one remote URL per line, in any form git accepts. Blank lines and
lines whose first character after leading spaces is `#` are skipped; surrounding whitespace and a
carriage return are trimmed. Each line is normalized like an origin (lower-cased, scheme, user,
port and a trailing `.git` or `/` dropped, scp form read, every Azure URL form turned into
`dev.azure.com/<org>/<project>/<repo>`) and must equal a row's name exactly; a comment after a URL on the
same line is not stripped and makes it not match. An excepted row is never queried and prints `excepted`.

For one repository, the push URL the check reads:

```
mkdir -p ~/.config/forge-protection
git -C <checkout> remote get-url --push origin >> ~/.config/forge-protection/exceptions
```

For many, build the lines from a fresh check's rows: `https://` plus the row's name normalizes to
that row. Print them first and read them:

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check > ~/.local/state/forge-protection/check.txt
awk '/^unreadable +github\.com\// { print "https://" $2 }' ~/.local/state/forge-protection/check.txt
```

Expected: the 14 repositories of other owners and nothing of yours. If so, append them:

```
awk '/^unreadable +github\.com\// { print "https://" $2 }' ~/.local/state/forge-protection/check.txt >> ~/.config/forge-protection/exceptions
```

The same form with `/unknown forge host/` selects the self-hosted one, and with `$2 !~ want` on
the `drift` rows (the `want` pattern of step 7) your unchosen own repositories; read each list
before appending it. Add `# why` comments on their own lines. An Azure row name can hold a
character the awk form mangles: write those by hand.

Verify:

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"
```

Expected: `exit 0`, and the summary's `d excepted` equals the number of lines in the file. A listed
repository that still shows `unreadable` has a URL that normalizes differently: compare the row's
name with the line.

If it fails: an exception hides a real problem for good, so keep the list to the section 2.4 cases and
review it whenever it grows.

### Rollback, group H

Delete the file: nothing is excepted, and the check reports those repositories again.

## Group I: verification (spec section 6; needs everything above)

### Step 14. From your own terminal <a id="step-14"></a>

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"
```

Expected: `exit 0`, every row `ok` or `excepted`, the excepted rows only the section 2.4 repositories
and the ones you chose to except, their count the one you expect. Run by you, `bypass_actors` is
visible, so this proves the whole target, including that `protect-main` binds you too.

```
for r in <repo-a> <repo-b>; do gh api repos/<owner>/$r/rules/branches/<branch> --jq '[.[].type] | sort'; done
```

Expected, for each chosen GitHub repository: `["creation","deletion","non_fast_forward","update"]`.

```
for r in <repo-a> <repo-b>; do gh api repos/<owner>/$r/collaborators/<agent-account>/permission --jq .permission; done
```

Expected: `write` for each.

```
ssh -T git@github.com
```

Expected: `Hi <owner>!` (exit status 1 is normal). Your own shell must greet you: the handoff of merge 2
(you push the dotfiles' `main` yourself with `pom`) depends on it.

If it fails: the first command's remaining rows say which step to repeat. `ssh -T` greeting
`<agent-account>` means your own SSH configuration or agent offers the machine key: look at `~/.ssh/config`
and 1Password's agent order.

### Step 15. From a new agent session <a id="step-15"></a>

Start a **new** Claude Code session after step 9 (the tokens are read from the settings at start),
in `~/.local/share/chezmoi-feat-forge-push-protection`, and ask it to run the following with its
Bash tool, sandboxed. Do not run these with `!` in the session, and never with the sandbox off.

```
./tests/run.sh live-agent-auth
```

Expected: `AUTH=READY`, `GITHUB_SSH=AGENT`, `GITLAB_SSH=READY`, exit 0. `GITHUB_SSH=INERT` means
`~/.ssh/github-agent.pub` or `~/.config/agent-identity/ssh_config` is absent (step 9); `MICHAEL`
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

Expected: `<owner>` with the recommended token (decision a(ii); the token is yours, so what a session
opens is authored by you), `<agent-account>` with the classic variant.

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

The check as the agent:

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"
```

Expected with the classic variant: the GitHub and GitLab rows `ok` (proves the agent cannot
bypass). **UNVERIFIED, with the recommended token:** `current_user_can_bypass` describes the token's
user, which is you, so a GitHub row may read `drift` (the bypass is not `never`) or `unreadable` (a
fine-grained token without Administration may not read a ruleset). If so, that is not a defect of
the protection: the proof that the machine account cannot bypass is the collaborator permission
`write` below `admin` and role 5 as the only bypass (steps 7 and 8), and step 14's run from your own
terminal. Tell the line what the rows read. The Azure rows will probably read `unreadable` (the
first "no answer within 20s", the rest "az did not answer earlier in this run") while `az` still
hangs from a session: that is the known hang, and it is why the exit-0 proof of step 14 comes from
your own terminal. If the session shows `excepted 0` while the file has lines, the sandbox may not
read it (UNVERIFIED); that is not a defect of the protection.

If it fails: a GitHub row `unreadable` with `HTTP 403` or `404` for the agent means the token cannot
read that repository's rules (with the classic variant, or a repository outside the fine-grained
selection); a row that shows `drift` only here, with the classic variant, means a ruleset the agent
could bypass (`current_user_can_bypass` is not `never`): recheck step 8's last verification.

### Step 16. Record <a id="step-16"></a>

Tell the line, in the session or by paste, with no repository names:

```
Merge 1 is verified. Results: <check exit codes and the counts a ok / d excepted, own terminal and
session>; GitHub rules and collaborator permission as expected; ssh greetings as expected;
live-agent-auth GITHUB_SSH=<value> GITLAB_SSH=<value>. Decisions: a <(i)(ii)(iii) as recommended,
or what you chose>; b <which projects patched, whether the merge clause stays>; c <keep>.
Confirmed or corrected: fine-grained GitHub token permission names <list> and merge refused <yes/no>
(or classic public_repo token <yes/no>); role id 5 is Repository admin <yes/no>; rules/branches
shows evaluate-mode rulesets <yes/no/not tried>; session check GitHub rows <ok/drift/unreadable>;
GitLab PATCH accepted on Free <yes, or UI used>; GitLab token permission names <list>; Azure: <what
az printed, what the bits and token format did, whether the dialog comparison agreed with the
check, whether the reviewers type id matched, whether the empty acesDictionary case or a
prefix-scoped policy occurred>. Please put them in the spec's Implementation notes and plan
merge 2.
```

If any of these differ from what the code assumes, the line corrects the printed forms before merge 2.

## Accepted limits and rulings

Recorded so you can overrule any of them; none is a code change in merge 1.

- **The agent SSH pin covers `github.com` and `ssh.github.com`.** A trailing-dot host name
  (`github.com.`), an IP literal, an SSH host alias and an HTTPS remote are not covered: they fall
  through to your own configuration, or to HTTPS with whatever credentials a session holds. A
  pinned trailing-dot form was tried and reverted. Accepted limits, not code.
- **Printed GitLab commands carry `--hostname gitlab.com`.** The check reads `gitlab.com` only, so
  a project on another GitLab host is `unreadable` (unknown host) and goes to the exceptions file.
- **The agent SSH configuration is passed with `-F`,** which makes `ssh` skip
  `/etc/ssh/ssh_config` for agent sessions; the user-level `~/.ssh/config` is still included for
  every other host.
- **Public-key templates render at mode 600,** not 644: the `private_` prefix of the template name
  strips group and world access, as for every `.pub` template in `private_dot_ssh/`.
- **An archived repository is not `ok`.** The check does not read the archived flag, so an archived
  repository needs an exceptions line until a later change reads it.
- **The scan skips history by tracking refs, which are evidence and not proof.** A remote's
  tracking refs are skipped only for a push whose destination is that remote's one fetch address.
  If you point a remote at another repository without pruning its tracking refs
  (`git remote set-url` and no `git fetch --prune`), a push to the new address still skips the old
  history, as the guard on main did. Parked for you: skipping only what the push handshake proves
  would close this, and would scan the whole history on each first push of a branch.

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
