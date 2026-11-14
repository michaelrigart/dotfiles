# Forge push protection: Michael's steps (revision 2)

**Status:** In progress

**Spec:** `docs/superpowers/specs/2026-11-12-forge-push-protection-design.md` (sections 1.1, 2, 3, 6 and 7, and "Revision 2", which you signed on 2026-11-14).
**Plan:** `docs/superpowers/plans/2026-11-12-forge-push-protection-merge-1.md` (Task 9, "Michael's steps"), rewritten here for revision 2.

**Where things stand (2026-11-14).** Merge 1 is merged and applied (2026-11-13), and you have run the baseline check: 100 repositories, 1 ok, 81 drift, 18 unreadable, 0 excepted. The line lands in three merges: merge 1 (done); merge 2, which removes the machine-account plumbing, makes the check print the GitHub target of revision 2 and moves the dotfiles to a pull request you merge (it changes no guard verdict); and merge 3, the retirement of the spelling hunt, the first dotfiles line to land through a pull request.

**GitHub waits for merge 2.** The check on `main` today still prints the old GitHub target: two rulesets, one of them `main-owner-only`, which is never created now. **Ignore every `gh api --method POST …/rulesets` line the check prints until merge 2 is applied (step 7), and paste none of them.** GitLab, Azure DevOps and the exceptions file (steps 1 to 6) can be done now, from today's check; every GitHub step (8 to 13) follows step 7.

Run the commands from your own terminal unless a step says the agent session. Never use `!` in a session for a step here. In a session `gh` carries `GH_TOKEN`, the fine-grained token of your own account (item `GitHub Agent Token`, step 10), which cannot merge or push over HTTPS; `git` over SSH is your own key, as it was before merge 1.

Placeholders: `<owner>` (your own GitHub login), `<repo>`, `<repo-a>` and `<repo-b>` (in-scope repositories), `<dotfiles-repo>`, `<scratch-repo>` (the throwaway repository of step 9), `<branch>` (the default branch), `<number>` (a pull request number), `<project-id>` (GitLab's numeric id), `<org-url>`, `<project>`, `<repo-id>`, `<ruleset-id>`. Real values come from the check's output, which stays on your screen or in a file outside this repository: it names repositories, so never commit it, paste it into a tracked file or put it in a report. Report counts only.

Commands and item names are copied from the committed code: `.scripts/forge-protection.sh` (the lines it prints), `dot_claude/modify_private_settings.json` and `tests/live-agent-auth.test.sh`. Where this file and the plan differ, this file follows the code. The GitHub lines of the check change with merge 2; this file follows the spec for them.

## Checklist

Three decisions come first ([Three decisions first](#three-decisions-first)). Then, in order, do and verify; the long form below is the reference. Steps 1 to 6 need no merge; steps 8 to 13 need step 7.

1. `~/.local/share/chezmoi/.scripts/forge-protection.sh check > ~/.local/state/forge-protection/check.txt` (after `mkdir -p ~/.local/state/forge-protection`); ignore its GitHub POST lines ([Step 1](#step-1)).
   Verify: `tail -n 1 ~/.local/state/forge-protection/check.txt` prints `forge-protection: N repositories: a ok, b drift, c unreadable, d excepted; e checkouts without origin skipped`.
2. GitLab: Edit profile > Access tokens > Add new token (fine-grained), item `GitLab Agent Token`, field `token`; details: [Step 2](#step-2) below.
   Verify: `GITLAB_TOKEN="$(op read 'op://Private/GitLab Agent Token/token')" glab api --hostname gitlab.com personal_access_tokens/self | jq 'del(.token)'` lists no merge, approve, protect or project-update permission.
3. One GitLab project first: record its rules with `(set -o pipefail; glab api --hostname gitlab.com --paginate 'projects/<project-id>/protected_branches?per_page=100' | jq -s add > ~/.local/state/forge-protection/before-<project-id>.json) || echo "read failed: do not go on"`, then paste the check's printed line for it; details: [Step 3](#step-3) below.
   Verify: `glab api --hostname gitlab.com projects/<project-id>/protected_branches/<rule-name-uri-encoded> | jq '{id, push: [.push_access_levels[].access_level], force: .allow_force_push}'` shows push `[0]`, force `false`, the same `id` (the merge levels are not part of the target).
4. Record every chosen project's rules first, then `bash ~/.local/state/forge-protection/gitlab-remedies.sh`; details: [Step 4](#step-4) below.
   Verify: re-run step 1's command into a new file; every GitLab row you chose reads `ok`.
5. Azure, per repository: save the policy list and permissions first, then paste the check's printed `az repos policy approver-count create …` line; details: [Step 5](#step-5) below.
   Verify: `az repos policy list --org <org-url> --project <project> --repository-id <repo-id> --branch <branch> --query "[?isEnabled && isBlocking].type.id" --output json` includes `"fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"`.
6. Exceptions file: `git -C <checkout> remote get-url --push origin >> ~/.config/forge-protection/exceptions` for one repository; the `awk` form for many is in [Step 6](#step-6) below.
   Verify: step 1's command prints a summary whose `d excepted` equals the file's URL lines.
7. Merge 2: `git -C ~/.local/share/chezmoi merge --ff-only feat/forge-push-protection`, `git -C ~/.local/share/chezmoi pom`, then `chezmoi apply`, plain, never `chezmoi diff` ([Step 7](#step-7)).
   Verify: `git -C ~/.local/share/chezmoi status --short --branch` prints `## main...origin/main` with no `ahead`; step 1's command again prints no `main-owner-only`.
8. GitHub scope: the repositories agents work in, each private one checked against your plan, each dormant one archived or excepted ([Step 8](#step-8)).
   Verify: `gh repo view <owner>/<repo> --json visibility,isArchived --jq '[.visibility,.isArchived]'` per in-scope repository.
9. A scratch public repository with the ruleset of spec section 2.1 ([Step 9](#step-9)).
   Verify: `gh api repos/<owner>/<scratch-repo>/rules/branches/main --jq '[.[].type] | sort'` prints `["deletion","non_fast_forward","pull_request"]`.
10. Fine-grained token of your own account (scratch repository among its repositories), item `GitHub Agent Token`, field `token`; `chezmoi apply` again; a new agent session ([Step 10](#step-10)).
    Verify: `GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api user --jq .login` prints `<owner>`; in the new session `gh auth status` names `GH_TOKEN`.
11. The three tests on the scratch repository, from your own terminal; any failure stops the line here ([Step 11](#step-11)).
    Verify: token merge refused, token write refused, your push of `main` refused, your merge of the pull request merges.
12. The check's GitHub POST line for each in-scope repository ([Step 12](#step-12)).
    Verify: `gh api repos/<owner>/<repo>/rules/branches/<branch> --jq '[.[].type] | sort'` prints `["deletion","non_fast_forward","pull_request"]`.
13. Delete the scratch repository ([Step 13](#step-13)).
    Verify: `gh repo view <owner>/<scratch-repo>` fails.
14. From your own terminal: `~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"` ([Step 14](#step-14)).
    Verify: `exit 0`, every row `ok` or `excepted`; the other commands: [Step 14](#step-14) below.
15. In a new agent session started after step 10's apply, ask it to run, sandboxed, `./tests/run.sh live-agent-auth` and `gh auth status`; never with `!` ([Step 15](#step-15)).
    Verify: `AUTH=READY`, `GITLAB_SSH=READY`, exit 0, `GH_TOKEN` named as the source; the other commands: [Step 15](#step-15) below.
16. Tell the line the results by the template in [Step 16](#step-16), with no repository names; no command.
    Verify: the line has the results and puts them in the spec's Implementation notes.

Rollbacks: sections "Rollback, steps 2 to 4 (GitLab)", "step 5 (Azure)", "step 6 (exceptions)", "step 7 (merge 2 and the hook)" and "steps 8 to 13 (tokens and GitHub)". Steps 1 and 14 to 16 change nothing. Accepted limits: section "Accepted limits and rulings".

## Three decisions first

**Decided on 2026-11-13 (Michael, relayed by the driver session): b as recommended, c accepted as built. a was replaced on 2026-11-14 (below).** The steps below follow them.

### a. GitHub: no second account

**Decided.** You declined the GitHub machine account on 2026-11-13 and chose pull requests only on 2026-11-14 ("ok, lets go with A then"). GitHub now works like GitLab: no second identity; agents push feature branches with your own SSH key; `GH_TOKEN` is a fine-grained token of your own account (Metadata read, Contents read, Pull requests write, Issues write, limited to the repositories agents work in); the default branch of each in-scope repository takes only pull requests, yours included, through rulesets with an empty bypass list. `main-owner-only` is never created and there is no collaborator. The dotfiles land through a pull request you merge from your own terminal.

**Decided at your signature on 2026-11-14, each as recommended**, with what each would change if you revise it:

- The merge method, `merge` only (the ruleset JSON of step 9; "rebase" would rewrite your signed commits unsigned, "squash" replaces them).
- The scope: the repositories agents work in (step 8).
- The dotfiles' pull request opened ready for review, not as a draft ("How the dotfiles land": a draft costs you `gh pr ready` first).
- Three merges, with the pull-request flow starting at merge 2 and the retirement at merge 3.

### b. GitLab on shared projects

**Found.** The check's original target (push "No one", merge Maintainers, force push off) also removes default-branch push from other project members and from any CI job or bot that pushes it, and merge from Developers. The spec's "nothing visible to others" was wrong.

**Consequence.** The merge-level clause does not constrain agents: they act as you, and their token cannot merge. It only changed what your teammates can do. **The merge clause was therefore removed from the target** (decided by the driver session on Michael's delegation, 2026-11-13): the check judges push "No one" and force push off only, and prints nothing about merge.

**Recommendation.** Apply push "No one" only where you are the only one who pushes the default branch directly. On projects with other members or a pushing CI job, decide per project, and use an exceptions line where the change would hurt others.

**If you decide otherwise.** Patching every `drift` GitLab row: steps 3 and 4 run over all of them, and step 6 holds only the unreadable ones.

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

Each is marked **UNVERIFIED** at its step. You confirm it while doing the step and tell the line what you saw, so the spec's Implementation notes and (for a wrong printed form) the code are corrected.

| Item | Step |
|---|---|
| The permission names on the GitHub token form, and that the set cannot merge or write contents (test 1) | 10, 11 |
| `allowed_merge_methods` is accepted by the ruleset POST | 9 |
| The ruleset refuses your own direct push of `main` (test 2), and the exact refusal text (generic shape `remote: error: GH013: Repository rule violations found`) | 11 |
| With 0 approvals you merge your own pull request (test 3) | 11 |
| The Contents write probe of test 1 targets a branch other than `main`, so that the answer shows the token's permission and not the ruleset | 11 |
| Your plan covers rulesets on a private repository (GitHub Pro) | 8 |
| `gh auth status` names `GH_TOKEN` in a session, and its wording | 10, 15 |
| The `gh` flags and the delete scope round trip in steps 9 to 13 | 9, 13 |
| `~/.ssh/github-agent.pub` and `~/.config/agent-identity/ssh_config` stay on disk after merge 2 | 7 |
| In an agent session the GitHub rows read `unreadable` (the token is not shown bypass lists) | 15 |
| The keys `live-agent-auth` prints after merge 2 | 15 |
| The exact permission names of the GitLab fine-grained token form, and what `personal_access_tokens/self` returns for one | 2, 15 |
| GitLab accepts the printed PATCH (`_destroy` entries, `allowed_to_push`) on Free | 3 |
| Azure: the state of all three repositories was never read, because `az repos` hung from an agent session (the outbound firewall is the first suspect) | 5 |
| Azure: the permission-bit values and the security token format the check uses | 5 |
| Azure: an empty `acesDictionary` for a user whose rights come only from groups makes the row `unreadable` | 5 |
| Azure: the check reads the rights of `az account show`'s user; if you push to Azure as another identity (a PAT of another account), it does not describe that identity | 5 |
| Azure: a policy scoped by prefix or to all branches may not be returned by the exact-branch read, so the check prints a create for a branch that is already covered | 5 |
| Azure: the reviewers-policy type id `fa4e907d-c16b-4a4c-9dfa-4906e5d171dd` is taken from documentation | 5 |

## Order

1. Steps 1 to 6, now: the check, GitLab, Azure and the exceptions file (group A). They run as you and need no apply; the check's GitHub lines wait for step 7.
2. Step 7: merge 2 into the main checkout, push `main`, apply (group B). The check now prints the GitHub target of revision 2.
3. Steps 8 to 13: GitHub (group C). The scratch repository takes all three tests before any real repository gets a ruleset; a failure stops the line at step 11.
4. Steps 14 to 16: verification and the record (group D).
5. Merge 3 only after steps 14 to 16: the line stops before it, and writes its plan once your results are in the spec.

**The window.** From the apply of step 7 to the ruleset of step 12 nothing at GitHub refuses a push of a default branch; the full local guard, which stays live until merge 3, is what covers it. Merge 2 itself lands by the current flow, before any ruleset. After step 12 GitHub refuses a direct push of `main` for everyone, you included: do not use `pom` on the dotfiles from then on.

## Group A: now, from today's check (steps 1 to 6)

They need no merge and run as you.

### Step 1. Run the check <a id="step-1"></a>

Merge 1 is applied, so `.scripts/forge-protection.sh` is in the main checkout and the check runs as you. You ran it on 2026-11-13: 100 repositories, 1 ok, 81 drift, 18 unreadable, 0 excepted. Run it again whenever a step says "step 1's command"; keep the output in a file outside this repository, because steps 4, 6, 8 and 12 filter it:

```
mkdir -p ~/.local/state/forge-protection
~/.local/share/chezmoi/.scripts/forge-protection.sh check > ~/.local/state/forge-protection/check.txt
```

It is read-only (GET calls only) and walks `~/.local/share/chezmoi` and every checkout one to three levels under `~/Code`, never entering a repository. It needs `gh`, `glab` (logged in to gitlab.com) and `az` on the path, plus `jq` and `git`. A forge call that gets no answer in 20 s is `unreadable`; raise it with `FORGE_PROTECTION_TIMEOUT=60` if a slow network needs it. With no repository found it prints that and exits 1.

**Until merge 2 is applied its GitHub rows describe the old target: ignore their `gh api --method POST …/rulesets` lines.** The GitLab and Azure rows and every `unreadable` reason are current.

Verify:

```
tail -n 1 ~/.local/state/forge-protection/check.txt
```

Expected: `forge-protection: N repositories: a ok, b drift, c unreadable, d excepted; e checkouts without origin skipped`. The first line of the file is `# This output names repositories: …`, then one row per push address of a checkout's `origin`: `ok`, `drift` (with the lines to paste), `unreadable` (with a reason) or `excepted`. The counts are approximate: rows are per push address, not per checkout. The exit status is 1 until everything is `ok` or `excepted`.

Printed lines quote any word with a character a shell treats specially (including `=`, so the GitLab POST reads `-f 'name=<branch>'`): paste them exactly as printed, quotes included; a plain name appears bare. Row names are lower-case.

If it fails: `unknown forge host <host>` means a remote uses an SSH host alias or a host the check does not read (the self-hosted one); the check refuses to guess, and an alias that resolves to `github.com` would push with your key: fix the remote or except it (step 6). A row `unreadable` with `no answer within 20s` for Azure is the known `az` hang (step 5): only a timeout stops the later Azure rows (they read `az did not answer earlier in this run`); any other Azure failure, such as `HTTP 404` on one repository, makes just that row `unreadable`. `HTTP 404` on a GitLab project is a project you cannot see (step 6).

No rollback: it changes nothing.

### Step 2. The GitLab token (your own GitLab account, no second account) <a id="step-2"></a>

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

The token reaches the settings only at a `chezmoi apply`, and only a session started after it carries it: step 7's apply renders it, or step 10's if you create it later. An item whose `token` field is not labelled exactly `token` makes that apply refuse to overwrite the settings (step 7, first failure).

## GitLab protection (steps 3 and 4)

What this costs you: you can no longer push a default branch directly on GitLab, on the small
single-developer projects included; every change lands through a merge request you merge. As the
Owner you can lift the rule in the UI when you need to. On a project with other members it also
takes their direct pushes (and a pushing CI job's) away (decision b; the merge level is not
touched): apply it where you alone push, decide the rest per project, and put the ones you leave in
the exceptions file (step 6).

Changes are made **in place**. Never unprotect a branch and protect it again: between the two
calls, or for good if the second fails, the branch would accept a force push its old rule refused.
The check never prints a DELETE.

### Step 3. One project first (needs step 1) <a id="step-3"></a>

Pick one project the check marked `drift` that already has a rule (it printed a `--method PATCH`
line). Record its rules before changing them, into a file outside this repository:

```
mkdir -p ~/.local/state/forge-protection
(set -o pipefail; glab api --hostname gitlab.com --paginate 'projects/<project-id>/protected_branches?per_page=100' | jq -s add > ~/.local/state/forge-protection/before-<project-id>.json) || echo "read failed: do not go on"
jq '.[] | {id, name, push: [.push_access_levels[].access_level], merge: [.merge_access_levels[].access_level], force: .allow_force_push}' ~/.local/state/forge-protection/before-<project-id>.json
```

Note the `id` of the rule the PATCH names. Then paste the check's printed line for that project.
Its form:

```
glab api --hostname gitlab.com --method PATCH projects/<project-id>/protected_branches/<rule-name-uri-encoded> -H 'Content-Type: application/json' --input <(printf '%s\n' '{"allow_force_push":false,"allowed_to_push":[{"id":<entry-id>,"_destroy":true},{"access_level":0}]}')
```

The JSON holds only what must change: `allow_force_push:false`, `allowed_to_push` (each offending
entry destroyed, and `{"access_level":0}` added when no "No one" entry remains). The merge side
is never in it. For a project with no rule for its default branch the check prints a POST instead:

```
glab api --hostname gitlab.com --method POST projects/<project-id>/protected_branches -f 'name=<branch>' -f push_access_level=0 -f allow_force_push=false
```

**UNVERIFIED: GitLab Free accepts the PATCH fields.** Verify:

```
glab api --hostname gitlab.com projects/<project-id>/protected_branches/<rule-name-uri-encoded> | jq '{id, push: [.push_access_levels[].access_level], force: .allow_force_push}'
```

Expected: `push` `[0]`, `force` `false`, and the same `id` as before (the
rule was changed, not recreated). I could not confirm that `glab api` has a `--jq` flag, so the
output is piped to `jq`.

If it fails: if GitLab answers 400 or 422 for `_destroy` or the other fields, nothing was changed
(read the rule again to be sure), and you use the UI form the check prints under each line for every
project: Settings > Repository > Protected branches > the rule: Allowed to push and merge: No one;
Allowed to force push: off. Tell the line
which form worked, so the printed form can be corrected. A 403 means your `glab` login is
not Owner there; that project is a step 6 candidate.

### Step 4. The rest (needs step 3 working, or the UI form) <a id="step-4"></a>

Decide the project list first (decision b): the projects where you alone push the default branch.
Regenerate the check's output so step 3's project reads `ok` and is not repeated:

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
for id in $(rg -o 'projects/[0-9]+' ~/.local/state/forge-protection/gitlab-remedies.sh | sort -u | cut -d/ -f2); do (set -o pipefail; glab api --hostname gitlab.com --paginate "projects/$id/protected_branches?per_page=100" | jq -s add > ~/.local/state/forge-protection/before-$id.json) || { echo "read failed: $id"; rm -f ~/.local/state/forge-protection/before-$id.json; }; done
```

Then make sure every file is there and holds a list (a project with no rule holds `[]`; a failed
read leaves `null` or an error object):

```
for id in $(rg -o 'projects/[0-9]+' ~/.local/state/forge-protection/gitlab-remedies.sh | sort -u | cut -d/ -f2); do jq -e 'type == "array"' ~/.local/state/forge-protection/before-$id.json >/dev/null 2>&1 || echo "missing or not a list: $id"; done
```

Expected: no output. Only then:

```
bash ~/.local/state/forge-protection/gitlab-remedies.sh
```

Or use the UI form per project. Then run the check again (step 1's command, into a new file):
every GitLab row you chose should read `ok`, and the rest are what step 6 excepts or you decided to
leave `drift`.

If it fails: a row that stays `drift` prints what is left, including a permissive wildcard rule
that matches the default branch (GitLab applies the most permissive rule): patch that rule too.
An `unreadable` row with `HTTP 403` or `HTTP 404` is a project you cannot administer (step 6).

### Rollback, steps 2 to 4 (GitLab)

Per project, in the UI (Settings > Repository > Protected branches): put "Allowed to push and
merge" back to what `~/.local/state/forge-protection/before-<project-id>.json` recorded (it holds
every rule of the project as it was) and the force-push toggle back, on the same row. A rule created
by a printed POST was not there before (`[]`): unprotecting it (the row's Unprotect button) returns
the project to its earlier state. Revoke the GitLab token ("Rollback, steps 8 to 13"). The token was never
needed for this group: the check ran as you.

## Azure DevOps (step 5)

What this costs you: with a blocking policy and your effective rights set to Deny, direct pushes of
the default branch fail for you too; every change lands through a pull request (the printed policy
lets you approve your own).

### Step 5. Azure: read, then set (needs step 1) <a id="step-5"></a>

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
re-run the check (step 1's command): the row reads `ok`.

If it fails: a row that stays `drift` prints the exact UI path and the permission names to Deny. A
repository whose policies or permissions you cannot edit goes to the exceptions file (step 6) and the
line is told.

### Rollback, step 5 (Azure)

Per repository, from the files recorded in step 5 (`azure-before-<repo-id>-policies.json`,
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
holds existed before: delete nothing, and if you edited it in step 5 (turned it on, made it
Required, raised the reviewer count), put those settings back to the values the recorded file holds
(`isEnabled`, `isBlocking`, `settings.minimumApproverCount`, `settings.creatorVoteCounts`).

Permissions: Branch security > your user: set each of the three permissions (Force push, Bypass
policies when pushing, Bypass policies when completing pull requests) to the value `-dialog.txt`
recorded, which may be Allow or Deny as well as Not set. Never set all three to Not set without
reading it: a Deny that stood before these steps is protection, and an Allow that stood before them
is what it was (the check reports it as drift again).

### Step 6. The exceptions file (needs steps 1 to 5 done as far as they go) <a id="step-6"></a>

`~/.config/forge-protection/exceptions` is yours alone: it is outside this repository and outside the sandbox's writable paths. Use it only for the repositories you knowingly accept as unprotected: the GitHub repositories of other owners and the self-hosted one the check does not know (both `unreadable`), the GitLab projects that answer 404 (not yours to administer) or that you decided in step 4 not to change, any Azure repository you cannot edit or read, and your own dormant GitHub repositories (step 8). **A GitHub repository agents work in is never excepted**: see step 8. (The shared GitLab projects and the Azure repositories you cannot edit are the accepted exceptions of the spec's section 2.4 and correction 11, agents or not.) Without the file nothing is excepted. Do not add it to chezmoi: this repository is public.

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

For many, build the lines from a fresh check's rows: `https://` plus the row's name normalizes to that row. Print them first and read them:

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check > ~/.local/state/forge-protection/check.txt
awk '/^unreadable +github\.com\// { print "https://" $2 }' ~/.local/state/forge-protection/check.txt
```

Expected: repositories of other owners and nothing of yours. If so, append them:

```
awk '/^unreadable +github\.com\// { print "https://" $2 }' ~/.local/state/forge-protection/check.txt >> ~/.config/forge-protection/exceptions
```

The same form with `/unknown forge host/` selects the self-hosted one; read each list before appending it. Add `# why` comments on their own lines. An Azure row name can hold a character the awk form mangles: write those by hand.

Verify:

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check | tail -n 1
```

Expected: the summary's `d excepted` equals the number of URL lines in the file. The exit status stays 1 until step 12: the GitHub rows are not done yet. A listed repository that still shows `unreadable` has a URL that normalizes differently: compare the row's name with the line.

If it fails: an exception hides a real problem for good, so keep the list to the section 2.4 cases and review it whenever it grows.

### Rollback, step 6 (exceptions)

Delete the file: nothing is excepted, and the check reports those repositories again.

## Group B: merge 2

### Step 7. Merge 2, push `main`, apply <a id="step-7"></a>

Needs the line's final report for merge 2: the pre-merge review receipt and the suites it names. Merge 2 lands by the current flow (local merge, you push `main`), because the pull-request flow starts with it. In a terminal of your own, not the session:

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

`pom` is the global alias for `push origin main`; the hook scans this push. Then apply, plain:

```
chezmoi apply
```

**Not** `chezmoi diff`, not `apply --verbose`, and not `chezmoi cat` of `~/.claude/settings.json`: each prints the file whole, and the file holds the tokens. 1Password may ask for Touch ID several times. The `chezmoi` wrapper applies only from a clean `main` equal to origin's.

Verify:

```
git -C ~/.local/share/chezmoi status --short --branch
```

Expected: `## main...origin/main` with no `ahead`.

```
jq '.env | has("GH_TOKEN"), has("GITLAB_TOKEN")' ~/.claude/settings.json
```

Expected: `false`, then `true` if step 2's item exists (the GitHub item comes in step 10; it prints no value). Then run step 1's command again; the file now carries the GitHub target of revision 2:

```
rg -c main-owner-only ~/.local/state/forge-protection/check.txt || echo none
```

Expected: `none`. If it prints a count, the check is still the old one: stop and tell the line.

**UNVERIFIED: leftovers.** Merge 2 removes the sources of `~/.ssh/github-agent.pub` and `~/.config/agent-identity/ssh_config`, and chezmoi does not delete a target whose source is gone. Nothing reads them after merge 2; remove them by hand if they are still there.

If it fails:
- `modify settings.json: 1Password lists "GitLab Agent Token" but its token cannot be read — refusing to overwrite` (or the GitHub one): that item exists but its `token` field is empty or not labelled `token`. Fix the label (steps 2 and 10) and apply again. The old settings file is untouched.
- `chezmoi apply` stops at an `op` error: unlock 1Password, `op whoami`, apply again.
- If the `--ff-only` merge refuses, `main` has moved. Do not force it: tell the line's session to rebase `feat/forge-push-protection` onto the new `main` and re-run the suites its report names, then repeat this step. If the push is rejected, `origin/main` moved after your merge: do not force it; tell the line.



### What the hook does to your own pushes

The global hook is hygiene for agents and applies to you as well, since the apply of merge 1:

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

### Rollback, step 7 (merge 2 and the hook)

- The identity (quick, no code change): "Rollback, steps 8 to 13", then `chezmoi apply`. Sessions fall back to your own logins.

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

- Merge 2: `git revert` its commits in a `wt` checkout, merge, apply. Forge rules stay.

### How the dotfiles land from now on

**Until merge 2 is applied** the current flow stays: an agent merges the finished branch into `main` in the main checkout, you approve the push of `main` or run `git -C ~/.local/share/chezmoi pom` yourself. Merge 2 lands that way (step 7).

**From the apply of merge 2** a dotfiles line pushes its branch and opens a pull request against `main`, ready for review and assigned to you. Its final report ends on the pull request number and these commands, to run in a terminal of your own, never with `!` in a session (a `!` command runs with the session's `GH_TOKEN`, which cannot merge):

```
gh pr merge <number> --merge --match-head-commit <sha>
git -C ~/.local/share/chezmoi pull --ff-only
chezmoi apply
```

Run the first one inside the main checkout, or add `--repo <owner>/<dotfiles-repo>`; the merge button does the same. `--match-head-commit` makes the merge fail if the branch moved after the review. The `pull --ff-only` is needed because the `chezmoi` wrapper deploys only from a clean `main` equal to origin's. `wt-rm` finds the branch merged once the main checkout is pulled; the report gives its command. The flow works with or without the ruleset; once step 12 has put it on the dotfiles, a direct push of `main` is refused for everyone, you included (`pom` stops working there on purpose).

## Group C: GitHub (steps 8 to 13, after step 7)

The scratch repository takes all three tests before any real repository gets a ruleset: a merge or push GitHub failed to refuse would otherwise stay on a real `main`, where the force push that removes it is refused. A failure at step 11 stops here.

### Step 8. Scope (needs step 7; changes nothing on a forge) <a id="step-8"></a>

Rulesets bind everyone, so they go where agents work. The spec counts seven by the baseline. The check's GitHub rows are the list:

```
awk '/^[a-z]/ && $2 ~ /^github\.com\// { print $1, $2 }' ~/.local/state/forge-protection/check.txt
```

1. Write down the in-scope repositories of your own (`<repo-a>`, `<repo-b>`, …). The repositories of other owners stay out; they are the exceptions of step 6.
2. Each dormant repository of yours: archive it (Settings > General > Danger Zone), or give it an exceptions line. As of merge 1 the check does not read the archived flag, so an archived repository needs the line too (merge 2 does not change that). With `want` set to the pattern of your in-scope repositories, as in step 12, print the lines, read them, and append them:

   ```
   want='^github\.com/<owner>/(<repo-a>|<repo-b>)$'
   awk -v want="$want" '/^drift +github\.com\// && $2 !~ want { print "https://" $2 }' ~/.local/state/forge-protection/check.txt
   ```

   Expected: your dormant repositories and none in scope. Then append the same output with `>> ~/.config/forge-protection/exceptions`.
3. Each private in-scope repository: rulesets on a private repository of a personal account need GitHub Pro. List them and read your plan:

   ```
   gh repo list <owner> --visibility private --limit 200
   gh api user --jq .plan.name
   ```

   **UNVERIFIED:** that `plan.name` answers for your token; the billing page of your account is the fallback. A repository agents work in is **never excepted**: if it is private on Free, make it public, take Pro, or take it out of agent work before merge 3. After the retirement a hidden push with your key would meet no refusal there. A dormant private repository can be excepted like any other.

Verify, for each in-scope repository:

```
gh repo view <owner>/<repo> --json visibility,isArchived --jq '[.visibility,.isArchived]'
```

Expected: `["PUBLIC",false]`, or `["PRIVATE",false]` only with Pro.

No rollback: it changes nothing on a forge.

### Step 9. The scratch repository and its ruleset (needs step 8) <a id="step-9"></a>

A throwaway public repository with one commit. The clone lives outside `~/Code`, so the check does not read it. **UNVERIFIED:** the `gh repo create` flags of your version (`gh repo create --help`).

```
mkdir -p ~/.cache/forge-scratch
git -C ~/.cache/forge-scratch init -b main
printf 'one\n' > ~/.cache/forge-scratch/file.txt
git -C ~/.cache/forge-scratch add file.txt
git -C ~/.cache/forge-scratch commit -m "first commit"
gh repo create <owner>/<scratch-repo> --public --source ~/.cache/forge-scratch --remote origin --push
git -C ~/.cache/forge-scratch remote set-url origin git@github.com:<owner>/<scratch-repo>.git
```

The last line gives the clone the transport of your real repositories (your SSH key). Then the ruleset of spec section 2.1, the same body the check prints for a repository without a ruleset:

```
gh api --method POST repos/<owner>/<scratch-repo>/rulesets --input - <<'EOF'
{"name": "protect-main", "target": "branch", "enforcement": "active", "bypass_actors": [],
 "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
 "rules": [{"type": "deletion"}, {"type": "non_fast_forward"},
           {"type": "pull_request", "parameters": {"required_approving_review_count": 0,
            "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false,
            "require_last_push_approval": false, "required_review_thread_resolution": false,
            "allowed_merge_methods": ["merge"]}}]}
EOF
```

**UNVERIFIED: `allowed_merge_methods` is accepted.** A 422 naming that parameter means the schema differs: stop and tell the line, because the check's printed form carries it too.

Verify:

```
gh api repos/<owner>/<scratch-repo>/rules/branches/main --jq '[.[].type] | sort'
```

Expected: `["deletion","non_fast_forward","pull_request"]`.

If it fails: a 403 or 404 means your `gh` login lacks `repo` scope (`gh auth status`); a 422 `name must be unique` means the ruleset exists (`gh api repos/<owner>/<scratch-repo>/rulesets --jq '.[] | [.id, .name]'`).

### Step 10. The GitHub token, a second apply, a new session (needs step 9) <a id="step-10"></a>

A fine-grained token of your own account, signed in as yourself: Settings > Developer settings > Personal access tokens > Fine-grained tokens > Generate new token. Resource owner `<owner>`. Repository access: only select repositories: the in-scope ones of step 8 **and `<scratch-repo>`**. Repository permissions: Metadata read-only (the form adds it), Contents read-only, Pull requests read and write, Issues read and write, and nothing else: no Administration, no Workflows, no Actions. Without Contents write it can neither merge a pull request nor push over HTTPS; without Administration it cannot touch rulesets. Set an expiry. Store it in 1Password: vault **Private**, item titled exactly `GitHub Agent Token`, with the secret in a field labelled exactly `token` (an API Credential item has a `credential` field: rename its label to `token`).

**UNVERIFIED: the permission names on the form, and that this set cannot merge or write contents (step 11 tests it).** Write down the names you ticked and tell the line.

Verify (the token is only in that one command's environment; nothing prints it):

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api user --jq .login
```

Expected: `<owner>`: it is your account, so what it opens is authored by you.

The tokens reach the settings only at an apply, so apply again, plain (step 7's warning holds), then start a **new** Claude Code session, which reads them at start:

```
chezmoi apply
```

```
jq '.env | has("GH_TOKEN"), has("GITLAB_TOKEN")' ~/.claude/settings.json
```

Expected: `true` twice (it prints no value). In the new session, ask it to run `gh auth status` with its Bash tool, sandboxed; never with `!`. Expected: the active github.com login is `<owner>` and the source named is `GH_TOKEN`, not the keyring. **UNVERIFIED:** the wording. If the keyring is named, the session does not have the token: start another one after the apply.

If it fails: `bad credentials` means the token was copied wrongly or has expired. `op read` failing means the field is not labelled `token`: the apply would refuse for the same reason (step 7).

### Step 11. The three tests (needs step 10; your own terminal) <a id="step-11"></a>

All three on the scratch repository, from your own terminal, none in an agent session: there the local merge gate would refuse test 1 before it reached GitHub and prove nothing about the token. The commands below name the clone `~/.cache/forge-scratch` in full, so a new tab needs no variable. First the pull request that tests 1 and 3 use:

```
git -C ~/.cache/forge-scratch switch -c scratch-branch
printf 'two\n' > ~/.cache/forge-scratch/file.txt
git -C ~/.cache/forge-scratch commit -am "second commit"
git -C ~/.cache/forge-scratch push -u origin scratch-branch
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh pr create --repo <owner>/<scratch-repo> --head scratch-branch --base main --title scratch --body scratch
```

The pull request is created **with the agent token**: that needs Pull requests write on this repository, so it proves the scratch repository is among the token's repositories (reading a public repository would prove nothing). The answer ends on the pull request's URL; its last number is `<number>`. If it is refused, `<scratch-repo>` is not in the token's repository list or the token lacks Pull requests write (step 10): correct the token and repeat. Do not go on to test 1 without it, because a token that cannot reach the scratch repository fails every write there and would pass test 1 falsely.

**Test 1, the token cannot merge or write.** The pull request above is the control. Then:

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh pr merge <number> --merge --repo <owner>/<scratch-repo>
```

Expected: refused (HTTP 403; the wording is **UNVERIFIED**), the pull request still open:

```
gh pr view <number> --repo <owner>/<scratch-repo> --json state --jq .state
```

Expected: `OPEN`. Then a write through the Contents API, the permission an HTTPS push needs, aimed at the branch and not at `main`, so the ruleset cannot be what refuses it (**UNVERIFIED** that this spelling is right for your `gh`):

```
GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api --method PUT repos/<owner>/<scratch-repo>/contents/probe.txt -f message=probe -f content=cHJvYmU= -f branch=scratch-branch
```

Expected: refused (403 or 404 with a message that the token cannot access the resource; **UNVERIFIED** wording), and no `probe.txt` on the branch. **If the merge or the write succeeds, stop:** revoke the token, give it fewer permissions or tell the line; the line stops.

**Test 2, the ruleset refuses your own push of `main`.**

```
git -C ~/.cache/forge-scratch switch main
git -C ~/.cache/forge-scratch merge --ff-only scratch-branch
git -C ~/.cache/forge-scratch push origin main
```

Expected: refused by GitHub, in the generic shape `remote: error: GH013: Repository rule violations found` followed by lines naming the rule (**UNVERIFIED:** the exact text). Verify that `main` did not move:

```
git -C ~/.cache/forge-scratch ls-remote origin refs/heads/main
git -C ~/.cache/forge-scratch rev-parse HEAD~1
```

Expected: the same commit on both lines. **If the push is not refused, stop here:** the boundary does not hold. Create no ruleset on a real repository, delete nothing else, and tell the line; the line stops before merge 3.

**Test 3, you merge your own pull request.**

```
gh pr merge <number> --merge --repo <owner>/<scratch-repo>
```

Expected: merged. Verify:

```
gh pr view <number> --repo <owner>/<scratch-repo> --json state --jq .state
```

Expected: `MERGED`. If it is refused (an approval is asked for, or the merge method is not allowed), delete the scratch ruleset (the rollback below) and tell the line: nothing real was touched, and the pull-request flow does not work as specified.

### Step 12. The rulesets on the real repositories (needs step 11 passed) <a id="step-12"></a>

First record every existing ruleset of each in-scope repository, so that an edit below can be undone (one file per repository; `<repo>` is the name after `<owner>/`):

```
for repo in <repo-a> <repo-b>; do (set -o pipefail; gh api "repos/<owner>/$repo/rulesets" --jq '.[].id' | while read -r id; do gh api "repos/<owner>/$repo/rulesets/$id"; done | jq -s . > ~/.local/state/forge-protection/github-before-$repo.json) || echo "read failed: $repo"; done
```

Expected: no output, and one file per repository holding a list (`[]` where it has no ruleset). Check with `jq -e 'type == "array"' ~/.local/state/forge-protection/github-before-<repo>.json`. Do not go on for a repository whose read failed.

Run step 1's command again so the file holds the apply's view, then take the check's own lines for the in-scope repositories. Each carries the one POST of spec section 2.1: `protect-main` where a repository has no ruleset, and `main-pr-only` (the `pull_request` rule alone) on the dotfiles, beside the `protect-main` they already have, which is not edited. **If a line names `main-owner-only`, the check is still the old one: stop.** Do not paste from this file or by hand; filter the check's lines into a file, read it, then run it. The dotfiles first:

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check > ~/.local/state/forge-protection/check.txt
want='^github\.com/<owner>/<dotfiles-repo>$'
awk -v want="$want" '/^[a-z]/ { on = ($2 ~ want) } on && /^    gh api --method POST/' ~/.local/state/forge-protection/check.txt > ~/.local/state/forge-protection/github-remedies.sh
less ~/.local/state/forge-protection/github-remedies.sh
```

Expected: one `main-pr-only` POST for the dotfiles and no other command. Then:

```
bash ~/.local/state/forge-protection/github-remedies.sh
```

Then the rest of the in-scope repositories the same way, with `want='^github\.com/<owner>/(<repo-a>|<repo-b>)$'` and a new file name. A line that fails does not stop the others; step 1's command lists what is left. If the check printed a `# in the UI: https://github.com/<owner>/<repo>/rules/<ruleset-id>: …` note instead, a ruleset has the rules but is not Active or has a bypass actor: fix that page as the note says, after checking that the ruleset is in that repository's `github-before-<repo>.json` (recorded above). Create rulesets Active, as printed.

Verify, for each in-scope repository:

```
gh api repos/<owner>/<repo>/rules/branches/<branch> --jq '[.[].type] | sort'
```

Expected: `["deletion","non_fast_forward","pull_request"]`. Then re-run step 1's command; each in-scope row reads `ok`.

If it fails:
- A POST returning 403 or 404: your `gh` login lacks `repo` scope or admin there (`gh auth status`). A 403 about the plan on a private repository: see step 8, which allows no exception for a repository agents work in.
- A POST returning 422 `name must be unique`: a ruleset of that name exists; list with `gh api repos/<owner>/<repo>/rulesets --jq '.[] | [.id, .name, .enforcement]'` and fix it in the UI.
- A missing type in the list: one ruleset did not apply; re-run the check, it prints what is left.

### Step 13. Delete the scratch repository (needs step 12) <a id="step-13"></a>

Deleting needs the `delete_repo` scope, which you add for the command and take away again (or delete it in the repository's Settings > Danger Zone instead):

```
gh auth refresh -h github.com -s delete_repo
gh repo delete <owner>/<scratch-repo>
gh auth refresh -h github.com -r delete_repo
rm -rf -- ~/.cache/forge-scratch
```

Then take `<scratch-repo>` out of the token's repository list (Settings > Developer settings > the token > Repository access).

Verify:

```
gh repo view <owner>/<scratch-repo>
```

Expected: it fails (the repository does not exist; the wording is **UNVERIFIED**).

### Rollback, steps 8 to 13 (tokens and GitHub)

Per ruleset, as the owner. Never delete the dotfiles' `protect-main`: it predates this work. List the rulesets, then delete the one you made (for the dotfiles `main-pr-only`, for another repository `protect-main`):

```
gh api repos/<owner>/<repo>/rulesets --jq '.[] | [.id, .name]'
```

```
gh api --method DELETE repos/<owner>/<repo>/rulesets/<ruleset-id>
```

or Settings > Rules > Rulesets > the ruleset > Delete. Direct pushes of `main` work again. The scratch repository: step 13.

A ruleset that existed before step 12 and that you edited from a UI note is never deleted: put its enforcement and bypass list back from the file step 12 recorded:

```
jq -c '.[] | select(.id == <ruleset-id>) | {enforcement, bypass_actors}' ~/.local/state/forge-protection/github-before-<repo>.json
```

```
jq -c '.[] | select(.id == <ruleset-id>) | {enforcement, bypass_actors}' ~/.local/state/forge-protection/github-before-<repo>.json | gh api --method PUT repos/<owner>/<repo>/rulesets/<ruleset-id> --input -
```

The first command shows what the second sends; it must print one object. **UNVERIFIED:** that a PUT with only these two fields leaves the ruleset's other fields as they are; otherwise set the two in the ruleset's page as the first command shows them.

The tokens: delete the two items in 1Password (or archive them; `op item list` does not list archived items), revoke the GitHub token at `https://github.com/settings/personal-access-tokens` and the GitLab token (Access tokens > Revoke), then `chezmoi apply`: an item that is not listed is the inert state, so the apply removes `GH_TOKEN` and `GITLAB_TOKEN`.

## Group D: verification (spec section 6; needs everything above)

### Step 14. From your own terminal <a id="step-14"></a>

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"
```

Expected: `exit 0`, every row `ok` or `excepted`, the excepted rows only the section 2.4 repositories, your dormant GitHub repositories and the shared GitLab projects you chose to leave, their count the one you expect. Run by you, `bypass_actors` is visible, so this proves the whole target, including that the rulesets bind you too.

```
for r in <repo-a> <repo-b>; do gh api repos/<owner>/$r/rules/branches/<branch> --jq '[.[].type] | sort'; done
```

Expected, for each in-scope GitHub repository: `["deletion","non_fast_forward","pull_request"]`.

If it fails: the first command's remaining rows say which step to repeat.

### Step 15. From a new agent session <a id="step-15"></a>

Start a **new** Claude Code session after step 10's apply (the tokens are read from the settings at start), in `~/.local/share/chezmoi-feat-forge-push-protection`, and ask it to run the following with its Bash tool, sandboxed. Do not run these with `!` in the session, and never with the sandbox off.

```
./tests/run.sh live-agent-auth
```

Expected: `AUTH=READY`, `GITLAB_SSH=READY`, exit 0, and no `GITHUB_SSH` key: merge 2 removes that probe. **UNVERIFIED:** the suite's exact keys after merge 2; the line's report lists them. `KEY_REJECTED` for GitLab means the sandbox key was refused.

The session's own transport (the wrapper and configuration git uses, not a bare `ssh`):

```
sh -c "$GIT_SSH_COMMAND -T -o BatchMode=yes -o ConnectTimeout=15 git@github.com"
```

Expected: `Hi <owner>!` (exit status 1 is normal): both forges greet you, as before merge 1.

```
gh auth status
```

Expected: the source of the active github.com login is `GH_TOKEN`, so `gh` is not on your keyring login.

```
gh api user --jq .login
```

Expected: `<owner>`.

```
test -n "$GH_TOKEN" && test -n "$GITLAB_TOKEN" && echo set
```

Expected: `set` (it prints no value). The agent tokens read one repository each:

```
gh api repos/<owner>/<repo-a>/rules/branches/<branch> --jq '[.[].type] | sort'
```

```
glab api --hostname gitlab.com 'projects/<project-id>/protected_branches?per_page=1' | jq length
```

Expected: the three rule types, and a number, not an error. And:

```
glab api --hostname gitlab.com personal_access_tokens/self | jq 'del(.token)'
```

Expected: no merge, approve, protect or project-update permission.

The check as the agent:

```
~/.local/share/chezmoi/.scripts/forge-protection.sh check; echo "exit $?"
```

Expected: the GitLab rows `ok`, and every GitHub row `unreadable` with "ruleset <id> does not show its bypass list to this login": GitHub shows a ruleset's bypass list only to an admin, and the agent token has no Administration, so the check cannot prove the list empty from a session. That is not a defect of the protection: step 14's run from your own terminal is the proof; tell the line what the rows read. The Azure rows will probably read `unreadable` (the first "no answer within 20s", the rest "az did not answer earlier in this run") while `az` still hangs from a session: that is the known hang, and it is why the exit-0 proof of step 14 comes from your own terminal. If the session shows `excepted 0` while the file has lines, the sandbox may not read it (UNVERIFIED); that is not a defect of the protection.

If it fails: a GitHub row `unreadable` with `HTTP 403` or `404` for the agent means the token cannot read that repository's rules, or the repository is outside the token's selection (step 10).

### Step 16. Record <a id="step-16"></a>

Tell the line, in the session or by paste, with no repository names:

```
Merge 2 is applied and the GitHub steps are done. Results: <check exit codes and the counts a ok / d excepted, own terminal and
session>; GitHub rules as expected on <n> repositories; tests 1 <token merge and write refused yes/no>, 2 <direct push of main
refused yes/no>, 3 <own merge worked yes/no>; live-agent-auth <keys and values>; gh auth status names GH_TOKEN <yes/no>.
Decisions: b <which projects patched>; c <keep>; the four decisions of a <unchanged, or what you changed>.
Confirmed or corrected: fine-grained GitHub token permission names <list>; the refusal wordings (generic shape only);
allowed_merge_methods accepted <yes/no>; private repositories in scope <none / public / Pro>; session check GitHub rows
<ok/drift/unreadable>; GitLab PATCH accepted on Free <yes, or UI used>; GitLab token permission names <list>; Azure: <what
az printed, what the bits and token format did, whether the dialog comparison agreed with the check, whether the reviewers
type id matched, whether the empty acesDictionary case or a prefix-scoped policy occurred>. Please put them in the spec's
Implementation notes and write the plan for merge 3.
```

## Accepted limits and rulings

Recorded so you can overrule any of them; none is a code change in merge 2.

- **Your own login still reaches everything.** An agent that unsets `GH_TOKEN` or leaves the sandbox uses your keyring login and your SSH key: it can merge on GitHub, GitLab and Azure, and unprotect a branch. The rulesets stop a push of a default branch, not that; the existing asks and the merge gate stay in front of it.
- **Branches other than the default are not protected on any forge:** agents must be able to push feature branches. Rule 4 asks for a force without a lease and for unmerged deletes.
- **The rulesets bind you too.** An emergency direct push of a GitHub `main` means deleting the ruleset first (the rollback above), not a bypass.
- **Printed GitLab commands carry `--hostname gitlab.com`.** The check reads `gitlab.com` only, so a project on another GitLab host is `unreadable` (unknown host) and goes to the exceptions file.
- **An archived repository is not `ok`.** As of merge 1 the check does not read the archived flag, so an archived repository needs an exceptions line until a later change reads it.
- **The scan skips history by tracking refs, which are evidence and not proof.** A remote's tracking refs are skipped only for a push whose destination is that remote's one fetch address. If you point a remote at another repository without pruning its tracking refs (`git remote set-url` and no `git fetch --prune`), a push to the new address still skips the old history, as the guard on main did. Parked for you: skipping only what the push handshake proves would close this, and would scan the whole history on each first push of a branch.

- **GitHub Actions can merge for an agent (open; inferred, untested; predates this line).** With your SSH key an agent can push a branch holding a workflow file (`on: push`, `permissions: contents: write`), open a pull request with its own token, and let the workflow's `GITHUB_TOKEN` merge it: the `pull_request` rule with no approvals is satisfied by any merge. It is a deliberate act in three steps, visible in the repository's Actions log, and narrower than before this line, when a workflow could push `main` directly. Yours to decide before merge 3's plan: an `update` rule whose only bypass actor is the Repository admin role in `pull_request` mode (tested on the scratch repository first), or a local refusal of agent changes under `.github/workflows/`; the spec's Residual weighs both.

## What stays owed after these steps

- **Merge 3 has no plan yet.** Its plan is written only after your verification results are in the spec's Implementation notes (step 16): deleting the hidden-spelling machinery, the default-branch push going from ask to deny, and the `global.md` wording (section 4). It is the first dotfiles line to land through a pull request. Until it is applied, the full local guard stays live.
- **A private in-scope repository on Free** (step 8) is made public, covered by Pro or taken out of agent work before merge 3.
- **The line's checkout** stays until merge 3 is merged; the final report gives the `wt-rm <branch>` command to run then, and nothing before.
- If your steps have not happened when merge 2 is done, the line stops there and is reported as waiting on you.
