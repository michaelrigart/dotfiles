# Forge push protection, merge 1: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress

**Scope:** merge 1 of the spec (section 6) only: `forge-protection check` (section 3, with the
targets of section 2), the `pre-push` hook with the scan moved out of the helper (section 5), and
the agent identity plumbing (section 1), inert until the 1Password items exist. Merge 1 changes no
verdict of rule 4's grammar. **Merge 2 is not in this plan**: deleting the hidden-spelling
machinery, the default-branch push going from ask to deny, and the `global.md` wording (section 4)
get their own plan, written after the verification results of section 6 are in the spec.

**Goal:** the forge can be set to refuse an agent's update of a default branch, every push is
scanned by a global hook, and agent sessions carry their own GitHub identity once Michael creates
it, while every session behaves as today until he does.

**Architecture:** a read-only Bash script walks the checkouts and asks each forge (GET only)
whether its default branch is in the target state. The secret scan becomes a Python script beside
a global `pre-push` hook; the hook scans every push, and the push helper calls the same script only
for a push that would ask. The settings `modify_` script reads two tokens from 1Password at apply,
and the SSH proxy selects an agent SSH configuration when its public key has been rendered.

**Tech Stack:** Bash 3.2 (`/bin/bash`), `/usr/bin/python3` 3.9, jq, git 2.56, gitleaks, `gh`,
`glab`, `az`, OpenSSH `ssh -G`, chezmoi templates, the shell suites in `tests/`.

**Spec:** `docs/superpowers/specs/2026-11-12-forge-push-protection-design.md`. Every section
reference below (§1 to §7, Tests) points into it.

## Global Constraints

- **Public repository.** No client organisation, group, project or host name in code, tests,
  fixtures, commit messages or this plan. Fixtures use invented names (`example-owner`,
  `example-group/example-sub`, `example-org`, `Example Project`). Michael's login `michaelrigart`
  and the repo name `dotfiles` are allowed.
- **No forge writes.** No task changes a forge setting, creates an account or token, or sends a
  forge write. Forge reads are GET only: `gh api` and `glab api` with no `--method`, `-X`, `-f`,
  `-F`, `--field`, `--raw-field` or `--input`; `az` with read verbs only. Everything Michael does
  is under "Michael's steps", never a task.
- **No new prompt.** No `ask` rule, no new `ask` verdict. Rule 4's grammar verdicts do not change.
  No push-guard verdict differs from main's. A silent push the deployed hook will certainly run
  for is scanned by the hook alone (§5: "a push that passes rule 4 silently is scanned by the
  hook alone"), so its deny moves to the hook suite; Task 5 lists each. Every other silent push
  (`--no-verify`, an assignment or wrapper on the command, a `core.hooksPath` that is not the
  deployed hooks directory, a hook that is missing or not executable) is still scanned by the
  helper, with main's verdict: the Decisions row "Silent pushes the hook will not see".
- **No secret printed or logged.** Tests compare a token with `jq '… == $ENV.X'` and print only
  the boolean; no suite prints a value. The fixture secret is assembled at run time from two
  halves, as in `tests/git-forge-guard.test.sh`.
- **The scan moves, it is not rewritten** (§5). Every message text moves byte for byte, `Push
  guard:` prefixes included, so every existing needle still matches. The only behaviour changes in
  the moved code are the three Task 5 names: the CLI, the exclusion (one rule on the destination
  URL), and the git configuration environment.
- Python stays 3.9 (no `match`, no `X | Y`) and is always started as `/usr/bin/python3 -I`. The
  hook, the proxy, the settings script and `forge-protection.sh` stay Bash 3.2 compatible (an empty
  array under `set -u` needs `${a[@]+"${a[@]}"}`).
- Suites are executed, never interpreter-prefixed. A new suite exits 2 when its subject is missing.
  Report totals as passed/total. Prose idioms (`  ok   …`, `  PASS: …`); `live-agent-auth` stays
  key=value.
- **Shell hazards of this branch** (the guard of main is live while you work): the checkout path,
  the spec and this plan's file names contain `push`, so never pass the checkout path to git (the
  cwd is the checkout: use relative paths). Never spell `git` and `push` in one Bash command: write
  `dot_claude/git-pu[s]h-guard.py`, stage hook files by directory (`git add dot_config/git/hooks/`)
  or by quoted glob pathspec (`git add 'tests/git-pre-pu[s]h-hook.test.sh'`,
  `git add 'docs/superpowers/plans/2026-11-12-forge-pu[s]h-protection-*.md'`), run the hook suite as
  `./tests/git-pre-pu[s]h-hook.test.sh` or `./tests/run.sh pre-pu`, and keep the word out of
  commit messages. Merge 2 retires this over-deny.
- **Base.** The plan runs on the current base (main `0a0f580`), not after `chore/test-audit`. Find
  every suite section by its echo heading, never by line number alone; line numbers in this plan
  are as of `3f36697`. The rebase onto the audited main is owed (closing note).

## Decisions the spec left open

| Question | Decision |
|---|---|
| Where the scan lives | One deployed copy beside the hook: `dot_config/git/hooks/executable_secret-scan` → `~/.config/git/hooks/secret-scan` (§5 "beside the hook"). The hook finds it by `$(dirname "$0")`; the helper by `PUSH_GUARD_SCAN`, else `$HOME/.config/git/hooks/secret-scan`. The guard thereby trusts one more path under `~/.config`, which sandboxed sessions cannot write (`live-write-boundary`'s `config_git` probe). The name holds no `push`, so the guard's fast path never reads it. |
| The scan's CLI | `secret-scan --repo <toplevel> --remote <shown> [--destination <url>] [--budget <s>] -- <source>...`. `--remote` only names the push in reasons; `--destination` is the URL git sends to (the hook's `$2`) and is the only input to attribution. Exit 0: clean or nothing outgoing; 1: refused, one reason on stderr; 2: usage. stdout always empty. Budget: `--budget`, else `SECRET_SCAN_BUDGET`, else 30 s. |
| Which history is excluded | One rule, keyed on the destination git actually uses (the hook's `$2`, after every rewrite and override; `$1` is only a name). A remote R's tracking refs are excluded if and only if R has exactly one fetch URL in the configuration the scan reads (`git remote get-url --all R` under the scan's environment, so `insteadOf` applies exactly as when the refs were fetched, and command-line `-c` is dropped) and that URL is string-equal to the destination. Every remote satisfying this is excluded, which covers a push by URL to a configured remote's address. With none, or no `--destination`, nothing is excluded: every source's whole history is scanned, and a history too large for the budget ends in the existing timeout refusal (fail closed). `pushurl`, `pushInsteadOf`, `git -c remote.<r>.pushurl=…`, the remote's name and several urls need no case of their own: a remote that fetches from A says nothing about what B holds, and a push by name to B is simply a push to B. The helper has no hook `$2`; it passes the one push URL it has already resolved and checked equal to the fetch URL. |
| The scan's git environment | Inherited env minus `GITLEAKS_*` and `GIT_CONFIG_PARAMETERS`; inherited `GIT_CONFIG_COUNT` entries are kept and the pins appended after them. Measured in an agent session: git hands the hook four `safe.directory` entries and the proxy's parameters, and a `git -c x=y push` reaches the hook through `GIT_CONFIG_PARAMETERS`. |
| Dry runs | git runs `pre-push` for `--dry-run` (measured, git 2.56.1), so the hook scans dry runs; the helper still never scans a canonical dry run. The hook suite drives judged pushes as dry runs and pins that git still runs the hook for them. |
| Silent pushes the hook will not see | The helper scans an otherwise-allowed push (`run_scan`, main's verdict: the leak reason on a finding, the existing refusals on a timeout or a missing gitleaks) unless `hook_will_run` shows the deployed hook will run for it. It shows that only when all hold: no `--no-verify` among the push flags; no environment assignment on the command (any name: `HOME`, `XDG_CONFIG_HOME` and `PATH` can move git's configuration or the hook it finds, so the rule does not enumerate them; `GIT_CONFIG*`, `GIT_DIR` and `GIT_WORK_TREE` are already refused); no `command`, `env` or `sudo` wrapper; the repository's effective `core.hooksPath` (`git config --type=path --get`, as git reads it, a relative value taken from the work tree) resolves, by `realpath`, to the directory that holds the scan the helper would call (`SCAN`), and that directory holds an executable regular `pre-push`, and `SCAN` is a file. Any of these missing, or a query that fails, means scan. A dry run does not count against it: git runs `pre-push` for `--dry-run` (the row above). A push the hook will see is not scanned twice. An asking push is always scanned by the helper. |
| Token rendering | The `modify_` script calls `op` at apply: `op item list --vault Private --format json`, then `op read` for each listed item. Listed: the variable is set. Not listed: absent (the inert and rollback state). `op` missing or failing: the live file's two values are carried unchanged, so a sandboxed preview neither drops nor diffs them. Listed but unreadable: exit 1 with no stdout (chezmoi keeps the old file). Values reach jq through its environment (`$ENV`), never its argv. |
| 1Password items | `op://Private/GitHub Agent SSH Key/public key` (an SSH Key item), `op://Private/GitHub Agent Token/token`, `op://Private/GitLab Agent Token/token`. |
| Agent SSH files | `~/.ssh/github-agent.pub` (template `private_dot_ssh/private_github-agent.pub.tmpl`, rendered only when the item is listed, so it is absent otherwise) and the static `~/.config/agent-identity/ssh_config`. `ssh-sandbox-proxy` adds `-F` for that config only when both files are readable, so `GIT_SSH_COMMAND` stays the proxy's path and `live-agent-auth`'s precondition holds. |
| Agent SSH configuration | `Match host "github.com,ssh.github.com"` pins the agent key, `IdentitiesOnly yes` and the 1Password socket (`ssh.github.com` is GitHub's port-443 endpoint); `Match host "*,!github.com,!ssh.github.com"` includes `~/.ssh/config`. IdentityFile is cumulative, so Michael's configuration is not read at all for either host. |
| A remote on an SSH host alias | `forge-protection check` reports a host it does not know as `unreadable`; an alias that resolves to `github.com` would push with Michael's key. |
| GitHub bypass visibility | `bypass_actors` is returned to admins only (read 2026-11-12 on the dotfiles: present for Michael, with `current_user_can_bypass`). The check reads `bypass_actors` when present, else requires `current_user_can_bypass == "never"`; as the machine account that proves the agent boundary, run by Michael it proves the whole target. |
| Excepted remotes | Not queried: no forge call, row `excepted`. |
| The Azure reviewers policy | Matched by policy type id `fa4e907d-c16b-4a4c-9dfa-4906e5d171dd` (`type.id`), never by the localised display name; a missing or non-string `type.id` is `unreadable`. The id is taken from documentation and confirmed when Michael first reads a real policy list. |
| Azure bypass bits | A bit in `effectiveAllow` counts as allowed even when `effectiveDeny` also holds it (fail closed: a group grant can still apply); `effectiveDeny` is never read. |
| Azure after a failure | Only a timeout disables Azure for the rest of the run; any other failure makes that one row `unreadable`. |
| Printed commands | Every forge-supplied word goes through `shq` (Task 2), so a printed remedy reads back literally under Bash, POSIX sh and zsh; `=` is quoted, e.g. `-f 'name=main'`. |
| The collaborator invitation | Not checked: it is identity, not protection. Michael's verification covers it. |

## Review Focus

1. **The scan inside an agent's git.** git already carries `GIT_CONFIG_COUNT` (four `safe.directory`
   entries) and `GIT_CONFIG_PARAMETERS` in the sandbox, and `git -c color.diff=always push` reaches
   the hook the same way. The moved code would overwrite the inherited entries, and the `-c` value
   can outrank its pins (git reads both at command-line scope), so a secret ends "refused by
   count" instead of found. A person expects
   the rule named. Task 5 rows: `-c color.diff=always` and an inherited `GIT_CONFIG_COUNT=1`
   `color.diff=always`, each blocked with `rule aws-access-token in creds.txt`.
2. **Pushes from linked worktrees**, which every `wt` checkout is. git exports `GIT_DIR` to the
   hook; the work tree, the scan and the repository's own hook must all resolve there. Task 5 rows:
   a leaky push from a linked worktree is blocked naming the rule, a clean one passes, and the
   common directory's hook runs.
3. **`hook-path` loses the scan silently.** It mirrors only `~/.claude` under `HOME=$T`, so after
   the swap the helper finds no scan script, denies with the missing-scan reason, and the suite's
   hostile-configuration check no longer reaches the scan's git calls while still reporting green.
   Task 5 mirrors the script and asserts no reason is the missing-scan text.
4. **1Password unreachable at apply or in a sandboxed preview.** The tokens must neither vanish
   from the settings nor show in a diff, and an item that is listed but unreadable must fail the
   apply rather than drop the variable. Task 6 rows for each case.
5. **Suites that push under the real global configuration after apply.** `git-config.test.sh` uses
   the source config as its global config and pushes to a bare remote, so after apply it runs the
   deployed hook. Task 5 isolates it with `HOME=$T` and turns that push into the proof that
   `core.hooksPath` wires the hook; Task 10 runs the whole suite with the hook live.

---

## Batches

Task 1 alone; then Tasks 2, 5 and 7 together (disjoint files, no shared resource); then 3, 6 and 8;
then 4; then 9; then 10. Task 6 follows Task 5 because both edit `tests/hook-path.test.sh`.

### Task 1: Locate and baseline

**Depends on:** none.

**Files:** none changed except the spec's Status line.

**Interfaces:** Produces `$SCRATCH/guard-before.txt` and `$SCRATCH/run-before.txt`, where
`$SCRATCH` is the executing session's scratchpad directory (never tracked); Tasks 5 and 10 diff
against them.

- [ ] **Step 1: Locate the sections this plan names** by their echo headings, not their line
  numbers: `rg -n '^echo "== ' tests/git-forge-guard.test.sh tests/claude-settings.test.sh` and
  `rg -n '^(def |[A-Z_]+ = )' dot_claude/git-pu[s]h-guard.py`. Record each range in your task
  report: in the guard suite, "== rule 4: the secret scan ==" through the line before "==
  internal failures fail closed ==" (3511–3944 at `3f36697`), the rule 4 fixtures (489–504), the
  promisor rows (925–980), "== the helper deploys beside the guard ==" (3501); in the helper, the
  scan constants (313–342), `run_gitleaks`, `expected_commits`, `scan`, `leak_reason` (2865–3072)
  and the scan call in `evaluate` (3205–3215).
- [ ] **Step 2: Baseline.** Run `./tests/run.sh > $SCRATCH/run-before.txt 2>&1` and
  `./tests/git-forge-guard.test.sh > $SCRATCH/guard-before.txt 2>&1`. Expected: both green. If not,
  stop and report the failures; they are not this plan's.
- [ ] **Step 3: Commit.** Set the spec's `**Status:**` to `In progress` (the only spec edit in
  this plan), `git add 'docs/superpowers/specs/2026-11-12-forge-pu[s]h-protection-design.md'`,
  commit "Mark the forge protection spec in progress".

### Task 2: `forge-protection.sh`: walk, rows, exceptions, GitHub

**Depends on:** Task 1.

**Files:**
- Create: `.scripts/forge-protection.sh` (mode 755: `git add --chmod=+x`)
- Create: `tests/forge-protection.test.sh` (mode 755)

**Interfaces:**
- Produces, in `.scripts/forge-protection.sh`:
  - CLI `forge-protection.sh check` and `--help`. Exit 0 only when every row is `ok` or
    `excepted`; 1 when any row is `drift` or `unreadable`, or when the walk finds no repository
    (it then prints that instead of a summary); 2 on usage, or when `git` or `jq` is missing.
  - Inputs: `HOME` (walk `$HOME/.local/share/chezmoi` itself and every checkout one to three levels
    under `$HOME/Code` (`~/Code/*`, `~/Code/*/*`, `~/Code/*/*/*`), recording a repository and
    never descending into it; exceptions file
    `$HOME/.config/forge-protection/exceptions`), `PATH`, `FORGE_PROTECTION_TIMEOUT` (seconds per
    forge call, default 20).
  - `normalize_remote <url>` prints `<host>/<path>`: lower case; scheme, user, port and a trailing
    `.git` or `/` dropped; scp form read; Azure `ssh.dev.azure.com:v3/…`,
    `vs-ssh.visualstudio.com:v3/…`, `<org>@dev.azure.com/<org>/<project>/_git/<repo>` and
    `<org>.visualstudio.com/<project>/_git/<repo>` all become `dev.azure.com/<org>/<project>/<repo>`,
    percent-decoded. Exceptions lines are normalized the same way; blank and `#` lines are skipped.
  - `forge_call <tool> <args...>` sets `FC_OUT`, `FC_ERR`, `FC_RC` (124 on timeout, the child
    killed); every forge call goes through `gh_get <endpoint>` (`gh api <endpoint>`),
    `glab_get <endpoint>` (`glab api --hostname gitlab.com <endpoint>`) or `az_read <args...>`,
    which refuses any call whose leading words are not `repos show`, `repos policy list`,
    `account show` or `devops security permission show`.
  - `row <ok|drift|unreadable|excepted> <remote> [detail]` prints `%-10s %s  %s`; `remedy <line>`
    prints one indented, copy-pastable command; `note <text>` prints `    # <text>`.
  - `check_github <remote> <owner/repo>`, dispatched for `github.com`; Tasks 3 and 4 add
    `check_gitlab` (`gitlab.com`) and `check_azure` (`dev.azure.com`) to the dispatcher. Any other
    host is `unreadable` ("unknown forge host <host>; an SSH host alias is read as one").
  - Output: a first line `# This output names repositories: never commit it or paste it into a
    tracked file.`, one row per normalized remote in sorted order (checkouts sharing an origin give
    one row), and the summary `forge-protection: N repositories: a ok, b drift, c unreadable, d
    excepted; e checkouts without origin skipped`.
  - The remote is `git -C <dir> remote get-url --push origin` (where pushes go).
- GitHub target (§2.1), from `repos/<o>/<r>` (`.default_branch`),
  `repos/<o>/<r>/rules/branches/<default, URL-encoded>?per_page=100` (every page: `gh_get` takes
  `--paginate` here, merged with `jq -s add`; the suite has a case whose `update` rule sits on a
  second page) and, per distinct
  `ruleset_id`, `repos/<o>/<r>/rulesets/<id>`:
  - a ruleset is *closed* when `enforcement == "active"` and either `bypass_actors` is present and
    empty, or absent with `current_user_can_bypass == "never"`;
  - a ruleset is *owner-only* when active and either `bypass_actors` is non-empty and every entry
    is `{actor_type: "RepositoryRole", actor_id: 5, bypass_mode: "always"}`, or the field is absent
    with `current_user_can_bypass == "never"`;
  - `ok` when `deletion` and `non_fast_forward` each come from a closed ruleset, `update` and
    `creation` each come from an owner-only one, and **every** active ruleset on the default branch
    that carries `update` or `creation` is owner-only (GitHub enforces all applicable rulesets, so
    one more that the owner cannot bypass locks him out; a ruleset in `evaluate` or `disabled`
    enforces nothing and is not judged); `unreadable` when any ruleset answer has neither
    bypass field, or any call fails (reason: the `HTTP nnn` from gh's stderr, or "no answer within
    Ns"); else `drift`.
  - Remediation: no closed ruleset with both of its rules → `gh api --method POST
    repos/<o>/<r>/rulesets --input <(printf '%s\n' '<json>')` with spec 2026-10-29 section 6's
    `protect-main` body, `include` set to `refs/heads/<default>`; no owner-only ruleset with both
    of its rules → the same form with §2.1's `main-owner-only` body; a ruleset that has the rules but
    fails enforcement or bypass → `note "in the UI: https://github.com/<o>/<r>/rules/<id>: Enforcement
    Active, bypass list <none | Repository admin with bypass mode "always">"`, followed for an
    active ruleset with `update` or `creation` that is not owner-only by `; ruleset '<name>' blocks
    the owner's direct push of the default branch until then (or drop its update and creation
    rules)`. No POST is printed for a state a POST cannot fix.
  - Printed commands: every forge-supplied word (a repository, a branch, an id, a path) enters a
    printed line through `shq`, which leaves a word bare only when it holds nothing but
    `A-Za-z0-9_./:@%+,-` and otherwise single-quotes it, so it reads back exactly under Bash, POSIX
    sh and zsh. `=` is therefore quoted (zsh expands a leading `=` to a command path, and with
    `magic_equal_subst` the part after `name=` too), as are `~`, `#`, `^`, `(`, `{`, `*`, `?` and
    `[`. The suite pastes each remedy into `zsh -f`, with and without `magic_equal_subst`, for the
    branches `=ls`, `~root` and `=(ls)`, and asserts the forge CLI receives the literal word.

- [ ] **Step 1: Write the failing suite.** Header and harness after `tests/skill-updates.test.sh`:
  `SCRIPT=…/.scripts/forge-protection.sh`, exit 2 when missing; run it as `/bin/bash "$SCRIPT"
  check` with `HOME=$T/home` and a stub dir first on `PATH`. The stubs `gh`, `glab` and `az` append
  their argv to `$CALLS` and answer from `$T/answers/<tool>/<key>{.out,.rc,.err,.sleep}`, the key
  being the argv with every character outside `A-Za-z0-9` turned into `_`; an unconfigured call
  prints `stub: unconfigured call` and exits 99. Fixture checkouts are `git init` directories
  under `$T/home/Code/ExampleOrg/` and `$T/home/.local/share/chezmoi`, each with an `origin`.
  Cases, each asserting the row's state and the exit status:
  - `github ok as Michael`: both rulesets visible with `bypass_actors` → `ok`, exit 0.
  - `github ok as the agent`: no `bypass_actors`, `current_user_can_bypass: "never"` → `ok`.
  - `github only protect-main` → `drift`; output holds the `main-owner-only` POST with
    `"actor_id":5` and `~DEFAULT_BRANCH`, exit 1.
  - `github one merged ruleset with the admin bypass` (all four rules in one ruleset) → `drift`,
    and the `protect-main` POST is printed (catches a check that accepts §2.1's rejected design).
  - `github an extra bypass actor` (a `User` actor beside role 5) → `drift`.
  - `github admin bypass for pull requests only` (`bypass_mode: "pull_requests_only"`) → `drift`,
    the note names the mode, no POST; `github a third active ruleset with update and no bypass` →
    `drift`, the note names it, no POST; the same third ruleset in `evaluate` or `disabled` → `ok`;
    `github a third owner-only ruleset` → `ok`.
  - `github ruleset in evaluate mode` → `drift` with the UI note.
  - `github rules read 403` → `unreadable` naming `HTTP 403`, exit 1; `github repo 404` →
    `unreadable`; `github no answer` (`.sleep` 5, `FORGE_PROTECTION_TIMEOUT=1`) → `unreadable`
    within 4 s; `github bypass not readable` (neither field) → `unreadable`.
  - `unknown host`: origin `git@gh-alias:example-owner/example-repo.git` → `unreadable` naming
    the host, with no forge call in `$CALLS`.
  - `exceptions`: an unreadable remote listed in the file (written in https form while the origin
    is scp form) → `excepted`, not queried, summary says `1 excepted`, exit 0 when the rest is `ok`;
    with the file absent the same remote is `unreadable` and exit 1; a `#` line is ignored.
  - `dedupe`: two checkouts with one origin → one row; `no origin` → skipped and counted.
  - `no write`: across every case, each `gh`/`glab` line of `$CALLS` starts with `api` and holds
    none of `--method -X -f -F --field --raw-field --input` (`--paginate` is allowed), and each `az` line starts with an
    allowed verb; printed output never contains `DELETE` or `unprotect`.
  - `no write verb outside printed strings` (§3): every non-comment line of the script holding
    `POST`, `PUT`, `PATCH` or `DELETE` as a word, or `gh`, `glab`, `az` or a wrapper name followed
    later on the line by `create`, `update`, `delete`, `merge`, `approve` or `protect`, is a
    `remedy` or `note` line. (A rule type such as `"update"` in a jq filter is data, not a verb.)
  - `usage`: `forge-protection.sh frobnicate` exits 2.
- [ ] **Step 2: Run and confirm it fails.** `./tests/forge-protection.test.sh`. Expected: exit 2,
  `missing script under test`.
- [ ] **Step 3: Implement** the interfaces above in `.scripts/forge-protection.sh`. `forge_call`
  runs the tool in the background with stdout and stderr in temp files, polls every 0.1 s and
  kills it at the limit; no `timeout` binary is assumed.
- [ ] **Step 4: Run and confirm it passes.** `./tests/forge-protection.test.sh`. Expected: `0
  failed`, exit 0. Revert check: make `gh_get` pass `-X GET`; the `no write` case fails; restore.
- [ ] **Step 5: Commit.** `git add --chmod=+x .scripts/forge-protection.sh tests/forge-protection.test.sh`,
  commit "Add a read-only forge protection check for GitHub".

### Task 3: GitLab in the check

**Depends on:** Task 2.

**Files:** Modify `.scripts/forge-protection.sh`, `tests/forge-protection.test.sh`.

**Interfaces:**
- Consumes: `glab_get`, `row`, `remedy`, `note`, `normalize_remote` from Task 2.
- Produces: `check_gitlab <remote> <path>`. Reads `projects/<path, @uri>` (`.id`,
  `.default_branch`) and `projects/<id>/protected_branches?per_page=100`, **every page** (`glab_get` takes `--paginate`
  for this call, still a GET; the pages are merged with `jq -s add` before any rule is judged, and
  a page that fails makes the row `unreadable`). A rule *matches* when its
  name equals the default branch or its wildcard does (`*` is any run of characters, everything
  else literal, anchored). Target (§2.2), over **every** matching rule: each `push_access_levels`
  entry has `access_level == 0` and no `user_id`, `group_id` or `deploy_key_id`;
  `allow_force_push == false`; each `merge_access_levels` entry has `access_level` 0 or ≥ 40 and no
  user or group. `ok` when at least one rule matches and all pass.
- Remediation, never a DELETE or an unprotect: no matching rule → §2.2's POST with `<id>` and
  `<default>` filled in, the name word quoted by `shq` (`-f 'name=<default>'`; the other `-f`
  fields are fixed words); per failing rule → `glab api --hostname gitlab.com --method PATCH
  projects/<id>/protected_branches/<name, @uri> -H 'Content-Type: application/json' --input
  <(printf '%s\n' '<json>')`, the JSON holding only what must change: `"allow_force_push":false`,
  `"allowed_to_push":[{"id":<each failing entry>,"_destroy":true},{"access_level":0}]`, and for
  merge `[{"id":…,"_destroy":true},{"access_level":40}]`; then `note "in place, never removed and
  re-created"` and `note "or in the UI: Settings > Repository > Protected branches > <name>:
  Allowed to push and merge: No one; Allowed to force push: off"`. The PATCH fields are GitLab's
  documented form; Michael confirms them on one project (Michael's steps).

- [ ] **Step 1: Write the failing cases**: `gitlab ok`; `gitlab no rule` (POST printed with
  `push_access_level=0`, `merge_access_level=40`, `allow_force_push=false`); `gitlab push
  Maintainers` (PATCH naming that rule's access id, `_destroy`, `access_level":0`); `gitlab force
  push on`; `gitlab strict exact rule beside a permissive wildcard` (`ma*` with push 40 → `drift`
  naming the wildcard rule, §Tests); `gitlab strict exact and strict wildcard` → `ok`; `gitlab a permissive wildcard on the
  second page` (the stub answers the paginated call with two JSON arrays, the strict exact rule in
  the first and `ma*` with push 40 in the second) → `drift`; `gitlab
  rule for another branch only` → `drift` with the POST; `gitlab project 404`, `gitlab
  protected_branches 403`, `gitlab no answer` → `unreadable`, exit 1. Nested group path
  `example-group/example-sub/example-app` in one fixture (the `@uri` encoding).
- [ ] **Step 2: Run, confirm the new cases fail.** `./tests/forge-protection.test.sh`. Expected:
  every gitlab case FAILs, its row reading `unreadable` "unknown forge host gitlab.com"; the
  GitHub cases still pass.
- [ ] **Step 3: Implement `check_gitlab`** and wire it into the dispatcher.
- [ ] **Step 4: Run.** Expected `0 failed`. Revert check: evaluate only the exact-name rule; the
  wildcard case fails; restore.
- [ ] **Step 5: Commit.** `git add .scripts/forge-protection.sh tests/forge-protection.test.sh`,
  commit "Read GitLab branch protection in the forge protection check".

### Task 4: Azure DevOps in the check

**Depends on:** Task 3.

**Files:** Modify `.scripts/forge-protection.sh`, `tests/forge-protection.test.sh`.

**Interfaces:**
- Consumes: `az_read`, `row`, `remedy`, `note` from Task 2.
- Produces: `check_azure <remote> <org> <project> <repo>`, org URL `https://dev.azure.com/<org>`.
  Calls, each `--output json`: `repos show --org --project --repository` (`.id`,
  `.defaultBranch`, `.project.id`); `repos policy list --org --project --repository-id --branch
  <defaultBranch>`; `account show` once per run (`.user.name`, the subject); `devops security
  permission show --id 2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87 --subject <user> --token
  repoV2/<projectId>/<repoId>/refs/heads/<branch>/ --org <url>`, where each path segment of the
  branch is the hex of its UTF-16LE bytes (`main` → `6d00610069006e00`).
- Target (§2.3): an enabled, blocking policy whose `type.id` is
  `fa4e907d-c16b-4a4c-9dfa-4906e5d171dd` (Minimum number of reviewers; matched by id, never by the
  localised display name) with `settings.minimumApproverCount >= 1`, and none of the bits ForcePush
  (8), PolicyExempt (128) or PullRequestBypassPolicy (32768) in any `extendedInfo.effectiveAllow` of
  the answer. A policy whose `type.id` is missing or not a string makes the row `unreadable`.
  `effectiveDeny` is never read: a bit in both `effectiveAllow` and `effectiveDeny` counts as allowed
  (a group grant can still apply), so it is drift. Token format, bits and the type id are the
  documented ones; Michael confirms them once `az` answers.
- Remediation: no policy → §2.3's `az repos policy approver-count create …` filled in, each
  forge-supplied word quoted by `shq`; an allowed bit → `note "Repos > Branches > <branch> > Branch
  security > <user>: set <permission names> to Deny (if it already shows Deny for the user, a group
  grant is still effective: check the groups)"`.
- After the first `az` timeout (and only a timeout), every later Azure row is `unreadable` ("az did
  not answer earlier in this run") with no further `az` call, so three hanging repositories cost
  one timeout. Any other failure (for example HTTP 404 on one repository) makes just that row
  `unreadable`; the next repository is still read.

- [ ] **Step 1: Write the failing cases**: `azure ok`; `azure no policy` (create command printed);
  `azure policy but PolicyExempt allowed` → `drift` (§Tests); `azure policy not blocking` →
  `drift`; `azure no answer` on the first of two Azure remotes → both `unreadable`, one `az repos
  show` in `$CALLS`; `azure repos show` failing with HTTP 404 on the first of two remotes → the
  first `unreadable`, the second read and `ok`; a policy named `Minimum number of reviewers` with
  another type id → `drift` with the create printed, and the reviewers type id under a localised
  display name → `ok`; a `type.id` that is absent, a number or null → `unreadable`; a bit in both
  `effectiveAllow` and `effectiveDeny` → `drift`, a bit only in `effectiveDeny` → `ok`; a project
  named `Example Project` reached through `%20` in the origin.
- [ ] **Step 2: Run, confirm the azure cases fail.** `./tests/forge-protection.test.sh`.
- [ ] **Step 3: Implement `check_azure`** and wire it in.
- [ ] **Step 4: Run.** Expected `0 failed`. Revert check: drop the 32768 bit; add a case allowing
  only PullRequestBypassPolicy, see it fail without the bit, restore.
- [ ] **Step 5: Commit.** `git add .scripts/forge-protection.sh tests/forge-protection.test.sh`,
  commit "Read Azure DevOps policies in the forge protection check".

### Task 5: The scan moves into a global hook (one commit)

**Depends on:** Task 1.

§5 lands this as one commit, so one apply swaps the helper's scan for the hook's.

**Files:**
- Create: `dot_config/git/hooks/executable_pre-push`, `dot_config/git/hooks/executable_secret-scan`
- Create: `tests/git-pre-push-hook.test.sh` (mode 755)
- Modify: `dot_config/git/config` (add `core.hooksPath`), `dot_claude/git-push-guard.py`,
  `dot_claude/executable_git-forge-guard.sh` (header comment, lines 12–15),
  `dot_config/homebrew/Brewfile.tmpl` (the `gitleaks` comment, line 65)
- Modify: `tests/git-forge-guard.test.sh`, `tests/git-config.test.sh`, `tests/hook-path.test.sh`

**Interfaces:**
- Produces `secret-scan` (the CLI in Decisions). It holds the moved `GITLEAKS_LEAKS_EXIT`,
  `GIT_LOG_DEFAULTS`, `MERGE_DIFF`, `PATCH_OPTS`, `EXCEPTION_FILES`, `GITLEAKS_CONFIG_RE`,
  `SCANNED_RE`, `ERR_RE`, `UNSUPPORTED`, `TIMED_OUT`, `run_gitleaks`, `expected_commits`, `scan`,
  `leak_reason`, and its own copy of `Repo.run`'s budget, per-call timeout, lazy-fetch and raw
  semantics. Three changes only: `main()` parses the CLI and maps `Deny` to exit 1 (an unexpected
  exception is exit 1 with `Push guard: internal error (<type>: <msg>), so the push is refused.
  Push by hand.`); the exclusion is built once, by the one rule in Decisions ("Which history is
  excluded"): `--not` and one `--remotes=<r>` per configured remote whose single fetch URL equals
  `--destination`, or no exclusion at all; the environment follows Decisions.
- Produces the hook `pre-push <remote> <url>`, git's lines on stdin. It saves stdin to a temp file
  (never `$(cat)`, which drops the last newline), collects each line's local sha that is not all
  zeros, and when there is one runs `/usr/bin/python3 -I "$(dirname "$0")/secret-scan" --repo
  "$(git rev-parse --show-toplevel)" --remote "$shown" --destination "$2" -- <shas>`, where
  `$shown` is `$1` (the remote's name, or the URL as typed) unless git rewrote the URL (`$2`
  differs from `$1` and `$1` is not in `git remote`), when it is `<$2> (rewritten from <$1>)` (as
  `dot_config/git/hooks/executable_pre-push` builds it); `$shown` only names the push in reasons,
  `$2` alone drives the exclusion; a non-zero exit blocks (exit 1).
  A missing `secret-scan` blocks with `Push guard: the secret scan (<path>) is missing, so the push
  is refused. Restore it with chezmoi apply.`; a work tree that cannot be resolved blocks too. Then
  it runs `$(git rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push` when that is
  executable and not the same file as `$0` (`-ef`), with the same arguments and the saved stdin,
  and exits with its status.
- Produces, in the helper: `SCAN = os.environ.get("PUSH_GUARD_SCAN") or
  os.path.join(os.path.expanduser("~"), ".config", "git", "hooks", "secret-scan")` and
  `run_scan(root: str, remote: str, destination: str, sources: list) -> None`, which raises `Deny`
  (`destination` is the push URL `evaluate` resolved). It runs
  `[sys.executable, "-I", SCAN, "--repo", root, "--remote", remote, "--destination", destination,
  "--budget", <remaining − 1, at least 0.1>, "--", *sources]` in its own session, killing the group at the remaining budget
  (`Deny(TIMED_OUT)`); a missing file or `OSError` is `Deny("Push guard: the secret scan (<path>)
  could not run (<why>), so the push is refused. Restore it with chezmoi apply, or push by
  hand.")`; any non-zero exit is `Deny(<its stderr, stripped>)`, or a fixed reason when stderr is
  empty.
- Consumed by Tasks 9 and 10: the suite names and the hook paths.

**Where each moved row goes.** Every row from "== rule 4: the secret scan ==" through the end of
"== rule 4: the scan fails closed ==" (sub-headings included) moves to the hook suite with its
label, as a dry-run push of the same refs: `deny` becomes `block`, `allow` becomes `pass`,
`has_reason` a stderr needle. Exceptions:

| Row (label) | Goes to |
|---|---|
| "a secret beats an ask: deny, not ask"; "a dry run is never scanned"; "--all …" and "--mirror with an exception file in the worktree"; "a dry run to main" with "a dry run never runs gitleaks" | stay in the guard, unchanged (asks, or canonical dry runs) |
| "a missing gitleaks denies the push", "a gitleaks error denies the push", "a gitleaks slower than the budget is a deny" with its elapsed check | both suites: the hook as a dry run; the guard as `git push --force origin feat` (§Tests: the same with gitleaks missing or failing) |
| "a source that is not a ref is a deny" | stays in the guard as `git push --force origin nosuch` (git refuses the plain form before any hook) |
| "after an amend" | hook, as `--force-with-lease` (a plain push is rejected non-fast-forward before the hook sees a line) |
| "--tags with an exception file in the worktree" and "…push the refs by name" | hook, blocked with "Commit the exception first" (the hook names refs by sha) |
| Outside the sections: "a dangling remote ref with a promisor remote", the pinned-PATH verdict comparison, "an outgoing commit naming a missing blob, with a promisor remote" and their marker rows | stay in the guard as `git push --force origin work`; the missing-blob row is added to the hook suite too, with its no-lazy-fetch marker |

The guard keeps only the fixture lines its remaining rows read (`SECRET_LINE`, `LEAKY`, `CLEAN`,
`TAGGED`, the gitleaks stubs); the hook suite builds its own. Like the guard suite today, the hook
suite counts a FAIL when gitleaks is not installed rather than skipping its rows.

- [ ] **Step 1: Write the hook suite.** `tests/git-pre-push-hook.test.sh`: `HOOK` and `SCAN` are
  the two source files, exit 2 if either is missing; copy both into `$TMP/hooks/` as `pre-push`
  and `secret-scan`, mode 755; `GIT_CONFIG_GLOBAL=$TMP/gitconfig` with the guard suite's content
  (its `format.pretty` included) plus `core.hooksPath = $TMP/hooks`; the guard suite's rule 4
  fixture block (bare `origin` and `backup`, `BASE`, `clone`). `expect_push <pass|block> <label>
  <repo> <args…>` runs `git -C <repo> push --dry-run <args>`: `pass` is exit 0, `block` is a
  non-zero exit with a non-empty reason on stderr, and every block row also asserts its own
  case-specific needle (the moved messages keep their texts, and not all start with `Push guard:`:
  `UNSUPPORTED` starts "unsupported push configuration"); `push_reason` returns stderr.
  **Fixture seeding is not a judged push**: every setup push that publishes history to a fixture
  remote (the two-remotes block's `push -q backup elsewhere`, and any other the moved sections
  make) runs with `--no-verify` through a `seed_push <repo> <remote> <ref>` helper that then
  asserts the remote ref exists (`git -C <remote.git> rev-parse --verify`) and fails the suite's
  setup loudly when it does not, so no judged row runs against an unseeded remote. Then:
  - the tripwire, first: a leaky dry run is blocked naming the rule (without the hook a dry run
    exits 0, so a git that stops running `pre-push` for dry runs fails here instead of turning
    every row below into a vacuous pass);
    a real push of a clean branch to a fresh bare remote creates the ref; a real push of a leaky
    branch is blocked and the ref is absent;
  - the moved rows, per the table;
  - new rows (§Tests and Review Focus): a new branch; a delete-only push passes and runs no
    gitleaks (a recording stub); a delete beside a leaky branch is blocked; two refs, one leaky,
    are blocked, two clean ones pass; an annotated tag on a leaky commit is blocked naming the
    rule; `git -c color.diff=always push` of a leaky branch is blocked naming the rule; inherited
    configuration survives: under `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=forge.marker
    GIT_CONFIG_VALUE_0=kept`, with a recording `git` first on the scan's `PATH` that appends
    `$GIT_CONFIG_COUNT:$GIT_CONFIG_KEY_0=$GIT_CONFIG_VALUE_0` to a log and execs the real git, every
    logged call of the scan has `forge.marker=kept` at index 0 and a count greater than 1 (the pins
    follow it), and the leaky push is still blocked naming the rule;
    a leaky push from a linked worktree is blocked naming the rule, a clean one passes; a push to
    the bare remote's path instead of `origin` passes when clean and is blocked when leaky; the
    two-remotes regression by URL: a secret-bearing branch that only `backup` holds, pushed to
    `origin`'s path as a URL, is blocked naming the rule, and pushed to `backup`'s path as a URL
    passes (that destination already holds it); a URL that matches no configured remote, with a
    secret in old history, is blocked; distinct fetch and push URLs: `backup` fetches from
    repository A and has `pushurl` B, a secret-bearing commit fetched from A and pushed to B's
    path as a URL is blocked naming the rule (the pushurl attributes nothing); the same shape
    pushed by the remote's name (`git push backup <ref>`) is blocked naming the rule, as is the
    same shape with `url.<B>.pushInsteadOf` rewriting A to B and with two pushurls, and `origin`
    fetching from A and pushed by name with `-c remote.origin.pushurl=<B>` (the scan drops the
    command-line configuration, so only the destination tells B from A); controls where the fetch
    and push URL are equal (a `pushurl` equal to the fetch URL, no rewrite, the ordinary push by
    name, and a remote written in an `insteadOf` short form) pass for history the remote holds;
    `secret-scan` removed from `$TMP/hooks` blocks with "is missing";
  - the repository's own hook: an executable `.git/hooks/pre-push` receives the same two arguments
    and, for a two-ref push, both lines (it counts lines with `while read`); exiting 1 it blocks a
    clean push; it is not run when not executable; from a linked worktree the common directory's
    hook runs; it is not re-entered when it is a link to the global hook;
  - direct CLI rows: no `--` is exit 2; no sources is exit 0 with empty output;
  - `chezmoi managed` lists `.config/git/hooks/pre-push` and `.config/git/hooks/secret-scan`.
- [ ] **Step 2: Write the guard suite's failing rows.** Export
  `PUSH_GUARD_SCAN="$SRC/dot_config/git/hooks/executable_secret-scan"` beside the stub-gitleaks
  setup, and add `dot_config/git/hooks/executable_secret-scan` to the `test-requires: heavy` line's
  list of loaded files. Where the moved sections stood, add `echo "== rule 4: a push that would ask
  is scanned first =="` with: deny "a force push without a lease, its commits holding a secret"
  (`git push --force origin feat`, needle `rule aws-access-token in creds.txt`); deny "a delete
  beside a pushed branch holding a secret" (`git push origin :old feat`); ask "a clean force push
  is scanned, then asks"; allow "a leaky feature push is left to the hook"; the rows the table
  keeps or doubles; deny "with the scan script missing, an asking push is denied"
  (`PUSH_GUARD_SCAN=$TMP/none`, needle `could not run`) and deny "and a silent push is scanned
  too, as the hook may not be there" (same setting, needle `could not run`). The suite's global
  config names a hooks directory (`core.hooksPath`) holding a link to the scan source and a
  `pre-push` stub, and `PUSH_GUARD_SCAN` points into it, so the hook counts as deployed for every
  other row; fixture pushes run the stub. Rows for the Decisions row "Silent pushes the hook will
  not see", each a leaky push unless named: deny `--no-verify` (needle `rule aws-access-token in
  creds.txt`); allow `--no-verify` on a clean push; deny with `HOME=` and with `XDG_CONFIG_HOME=`
  reassigned, with `env HOME=`, with `sudo` and with `command`; allow with `HOME=` reassigned on a
  clean push; allow a leaky dry run that is not canonical text (`git -C <repo> push -n …` from
  another directory) with the hook deployed (git runs the hook for it); deny when the
  hooks directory lacks `pre-push`, when `pre-push` is not executable, and when the repository's
  `core.hooksPath` names another directory; control: an ordinary leaky push with the hook deployed
  is allowed by the helper and a recording gitleaks is not called, while the same stub is called for
  `--no-verify`. The section runs with the real gitleaks (`PATH="$REALPATH"`), as the moved one did,
  and puts the stub back at its end. Convert the promisor and `nosuch` rows per the table.
- [ ] **Step 3: Extend the other two suites.** `git-config.test.sh`: run the "a bare remote works"
  push with `HOME=$T`, and a marker hook at `$T/.config/git/hooks/pre-push`; the case also asserts
  the marker (the source config's `core.hooksPath` wires a hook under `HOME`, and the suite never
  runs the deployed one). `hook-path.test.sh`: copy the scan source to
  `$T/.config/git/hooks/secret-scan` beside the `~/.claude` mirror, capture the forge guard's
  stdout, and add a row that no reason holds "the secret scan (".
- [ ] **Step 4: Run and confirm RED.** `./tests/git-pre-pu[s]h-hook.test.sh` exits 2 (subject
  missing); `./tests/git-forge-guard.test.sh 2>&1 | grep -E 'FAIL|passed'` fails "a leaky feature
  push is left to the hook" and "with the scan script missing…"; `./tests/git-config.test.sh`
  fails the marker.
- [ ] **Step 5: Create `secret-scan`** by moving the code (Interfaces). Delete it from the helper,
  with `import shutil`, `import signal` and `import tempfile` if nothing else uses them.
- [ ] **Step 6: Create `pre-push`** (`#!/bin/bash`, Interfaces) and add to `dot_config/git/config`:
  `[core]` `hooksPath = ~/.config/git/hooks` (git expands the `~`).
- [ ] **Step 7: Wire the helper.** In `evaluate`, keep building `scan_sources`; remove the
  `scan(...)` call and call `run_scan(root, remote, fetch_url, scan_sources)` when there are scan sources and
  either `asks` remain (after the dry-run deny, immediately before the ask is returned) or
  `hook_will_run` is false for an otherwise-allowed push (Decisions, "Silent pushes the hook will
  not see"). `parse_plain` records whether `command`, `env` or `sudo` wrapped git, `judge` hands
  that to `evaluate`, and `evaluate`'s default reads a caller that does not say as wrapped. Update
  the helper's header (a short paragraph: an asking push is scanned by `secret-scan` before the ask,
  a silent one when the hook may not see it, and every push by the hook), the guard's header lines 12–15 and the Brewfile comment
  ("secret scan in ~/.config/git/hooks/pre-push, and before a push guard ask").
- [ ] **Step 8: Run and confirm GREEN.** `./tests/git-pre-pu[s]h-hook.test.sh`,
  `./tests/git-forge-guard.test.sh`, `./tests/git-config.test.sh`, `./tests/hook-path.test.sh`:
  each `0 failed`. Then diff the guard suite's `ok`/`FAIL` labels against
  `$SCRATCH/guard-before.txt`: every label that disappeared or changed verdict must be in the table
  above; anything else is a regression to fix, never a relabel.
- [ ] **Step 9: Revert checks**, each restored after: move `run_scan` after the ask return →
  "a force push without a lease, its commits holding a secret" fails; read stdin with `$(cat)` →
  the two-line repository-hook row fails; write the pins from index 0 again → the inherited
  configuration row fails on the missing `forge.marker` (confirm it does: the pins alone still
  find the secret, so only the recorded environment can catch this); attribute by the remote's
  name again (exclude `--remotes=<name>` whatever the destination) → the command-line `pushurl`,
  distinct-URLs and `pushInsteadOf` rows fail; never attribute → every control that expects the
  destination's history to be excluded fails; compare the raw `remote.<r>.url` instead of `git
  remote get-url` → the `insteadOf` control fails; drop the scan copy in `hook-path.test.sh` → its new row fails; make `hook_will_run`
  always true → every "silent push the hook will not see" deny row fails; drop each of its
  conditions in turn (`--no-verify`, assignment, wrapper, `core.hooksPath` comparison, `pre-push`
  existence, its executable bit) → the row for that condition fails.
- [ ] **Step 10: Commit once.** `git add dot_config/git/ dot_claude/executable_git-forge-guard.sh
  dot_config/homebrew/Brewfile.tmpl tests/git-forge-guard.test.sh tests/git-config.test.sh
  tests/hook-path.test.sh` plus `git add 'dot_claude/git-pu[s]h-guard.py'` and
  `git add --chmod=+x 'tests/git-pre-pu[s]h-hook.test.sh'`; commit "Move the secret scan into a
  global git hook", its body listing each guard row whose verdict changed and where it went.

### Task 6: Agent tokens in the settings

**Depends on:** Task 5 (both edit `tests/hook-path.test.sh`).

**Files:**
- Modify: `dot_claude/modify_private_settings.json` (before the jq call at 36–40; the `env`
  object at 74–91; `allowRead` at 431–444)
- Modify: `tests/claude-settings.test.sh` (`emit`, `EXP_ALLOW_READ`, a new section),
  `tests/hook-path.test.sh` and `tests/ssh-credential-inventory.test.sh` (their `$MOD` calls)
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: the item names in Decisions; `~/.ssh/github-agent.pub` from Task 7 (a path only).
- Produces: `.env.GH_TOKEN` and `.env.GITLAB_TOKEN` with the semantics in Decisions, the jq
  argument `--arg op_state reachable|unreachable`, values in `AGENT_GH_TOKEN` and
  `AGENT_GITLAB_TOKEN` set only on the jq command (`$ENV.…`), and `"~/.ssh/github-agent.pub"` in
  `sandbox.filesystem.allowRead`. The jq program keeps its no-apostrophe rule.

- [ ] **Step 1: Write the failing tests.** In `claude-settings.test.sh`, `emit` puts a stub dir
  first on `PATH`. The stub `op` answers `item list --vault Private --format json` with
  `$OP_ITEMS` (default `[]`) or exits 1 when `OP_DOWN=1`, and `read op://Private/<title>/token`
  with `$OP_GH` or `$OP_GL`, or exits 1 when `OP_READ_FAIL=1`; anything else is logged and exits
  99. A `jq` shim in the same dir logs its argv and runs the real jq. New section
  `echo "Y. agent identity tokens (spec 2026-11-12-forge-push-protection, section 1.4)"`:
  - both items listed → `.env.GH_TOKEN == $ENV.OP_GH` and the same for GitLab print `true`;
  - only the GitHub token listed → `.env | has("GITLAB_TOKEN")` is `false`;
  - none listed, live file holding both → both absent (the rollback);
  - `OP_DOWN=1`, live holding both → both carried, equal to the live values; live holding none →
    absent; no `op` on `PATH` at all → the same as `OP_DOWN`;
  - `OP_READ_FAIL=1` with an item listed → non-zero exit and empty stdout;
  - in every case above, stderr and the shim's argv log never contain `$OP_GH` or `$OP_GL`;
  - with both tokens, a second apply changes nothing;
  - `EXP_ALLOW_READ` gains `"~/.ssh/github-agent.pub"`; no `permissions.deny` entry and no
    `sandbox.credentials.files` path covers `~/.config/agent-identity/ssh_config` (§Tests: the
    agent SSH configuration is readable in the sandbox).
- [ ] **Step 2: Run, confirm RED.** `./tests/claude-settings.test.sh 2>&1 | grep -E 'FAIL|passed'`.
  Expected: the Y rows and the allowRead set fail; every other section passes.
- [ ] **Step 3: Implement** in the modify script: one function that sets `op_state` and the two
  values, exiting 1 with `modify settings.json: 1Password lists "<title>" but its token cannot be
  read — refusing to overwrite` on a failed read; merge the result into `env` in jq; add the
  `allowRead` entry. Give the `$MOD` calls in `hook-path.test.sh` and
  `ssh-credential-inventory.test.sh` a stub `op` that exits 1, so no suite ever starts the real
  `op` (unsandboxed it would ask for Touch ID).
- [ ] **Step 4: AGENTS.md.** In the secrets rule: the agent tokens are read from 1Password by
  `dot_claude/modify_private_settings.json` at apply and live only in the deployed
  `~/.claude/settings.json`; preview that target through `jq 'del(.env.GH_TOKEN,
  .env.GITLAB_TOKEN)'`, never whole. In the `.scripts/` rule: `forge-protection.sh check`, read-only,
  GET calls only, its output names repositories and is never committed.
- [ ] **Step 5: Run, confirm GREEN.** `./tests/claude-settings.test.sh` and
  `./tests/hook-path.test.sh`: `0 failed`. Revert check: drop the carry branch; the `OP_DOWN`
  row fails; restore.
- [ ] **Step 6: Commit.** `git add dot_claude/modify_private_settings.json AGENTS.md
  tests/claude-settings.test.sh tests/hook-path.test.sh tests/ssh-credential-inventory.test.sh`,
  commit "Render the agent forge tokens into the Claude settings".

### Task 7: The agent's GitHub SSH identity

**Depends on:** Task 1.

**Files:**
- Create: `dot_config/agent-identity/ssh_config`, `private_dot_ssh/private_github-agent.pub.tmpl`
- Modify: `dot_local/bin/executable_ssh-sandbox-proxy` (the two `exec /usr/bin/ssh` lines, 10 and
  64–66), `tests/ssh-sandbox-proxy.test.sh`

**Interfaces:**
- Produces `~/.config/agent-identity/ssh_config`, exactly:

  ```
  # Agent sessions only, through ssh-sandbox-proxy (spec 2026-11-12-forge-push-protection, section 1.1).
  Match host "github.com,ssh.github.com"
    IdentityFile ~/.ssh/github-agent.pub
    IdentitiesOnly yes
    IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  Match host "*,!github.com,!ssh.github.com"
    Include ~/.ssh/config
  ```
- Produces the template: it reads `output "op" "item" "list" "--vault" "Private" "--format"
  "json" | fromJson`, and renders `onepasswordRead "op://Private/GitHub Agent SSH Key/public key"`
  only when a title equals `GitHub Agent SSH Key`; otherwise it renders nothing, so chezmoi creates
  no file and removes one that exists. `grep -L onepassword private_dot_ssh/private_*.tmpl` still
  prints nothing.
- Produces in the proxy: `-F "$HOME/.config/agent-identity/ssh_config"` before `"$@"` on both exec
  lines when that file and `$HOME/.ssh/github-agent.pub` are readable; otherwise the argv is
  today's.

- [ ] **Step 1: Write the failing tests** in `ssh-sandbox-proxy.test.sh` (exit 2 if the proxy or
  `ssh_config` source is missing):
  - proxy, with `FTP_PROXY`, `ftp_proxy`, `ALL_PROXY` and `all_proxy` unset and `HOME=$T`: with a
    fixture config holding `User proxy-marker` and the key file present, `"$HELPER" -G
    example.invalid` prints `user proxy-marker`; with the key file absent it does not; the same pair
    through the proxy branch (`FTP_PROXY=socks5h://u:p@127.0.0.1:1`);
  - the shipped config holds exactly one `Include ~/.ssh/config`; a copy with that path replaced
    by a fixture (whose `Host github.com` and `Host *` blocks set other `IdentityFile`s and `User
    fixture-user`) under `/usr/bin/ssh -G -F <copy>`: `github.com` has exactly one `identityfile`,
    ending `github-agent.pub`, `identitiesonly yes` and the 1Password `identityagent`; `GitHub.com`,
    `ssh.github.com` and `SSH.GitHub.com` the same; `gitlab.com`, `notgithub.com`, `gist.github.com`
    and `ssh.github.com.example` have the fixture's identity and user and no `github-agent.pub`;
  - the template under `chezmoi execute-template` (hermetic config and state, as in
    `codex-config.test.sh`; INCONCLUSIVE exit 2 when chezmoi is absent or its cache is cold) with a
    stub `op` first on `PATH`: listed → the stub's public key; not listed → empty output. The stub
    logs every call and exits 99 on one it does not know: answer what chezmoi asks (`--version`,
    `read`, `item list`, whatever the log shows), never with a catch-all success;
  - `chezmoi managed` lists `.config/agent-identity/ssh_config` and `.ssh/github-agent.pub`.
- [ ] **Step 2: Run, confirm RED.** `./tests/ssh-sandbox-proxy.test.sh`: exit 2.
- [ ] **Step 3: Implement** the three files.
- [ ] **Step 4: Run, confirm GREEN**, then the revert check: move the `Include` out of the `Match`
  block; the single-`identityfile` row fails; restore.
- [ ] **Step 5: Commit.** `git add dot_config/agent-identity private_dot_ssh/private_github-agent.pub.tmpl
  dot_local/bin/executable_ssh-sandbox-proxy tests/ssh-sandbox-proxy.test.sh`, commit "Give agent
  sessions their own GitHub SSH identity".

### Task 8: `live-agent-auth` probes the identities

**Depends on:** Task 7.

**Files:** Modify `tests/live-agent-auth.test.sh`.

**Interfaces:**
- Consumes: the two paths from Task 7.
- Produces two keys after `AUTH=READY` (the early exits before it stay): `GITHUB_SSH` and
  `GITLAB_SSH`, each from `sh -c "$GIT_SSH_COMMAND -T -o BatchMode=yes -o ConnectTimeout=15
  git@<host>"` with stderr captured and never printed. `GITHUB_SSH=AGENT` when the greeting `Hi
  <login>!` names a login other than `michaelrigart` (compared case-insensitively), `MICHAEL` when
  it names him (a failure), `INERT` when either agent file is absent (not a failure: merge 1 is
  inert until Michael's items exist), `NO_GREETING` otherwise (a failure). `GITLAB_SSH=READY` on
  `Welcome to GitLab, @`, else `KEY_REJECTED` or `NO_GREETING` (failures). Failures join
  `failed_keys=`; the exit status is their count.

- [ ] **Step 1: Write the probes** (this suite is its own test: it measures a fresh session).
- [ ] **Step 2: Check what can be checked here.** `bash -n tests/live-agent-auth.test.sh`, then
  `./tests/run.sh live-agent-auth` sandboxed in this session. Expected: `AUTH=READY`,
  `GITHUB_SSH=INERT`, `GITLAB_SSH=READY`, exit 0. The `AGENT` path is Michael's verification.
- [ ] **Step 3: Commit.** `git add tests/live-agent-auth.test.sh`, commit "Probe the agent SSH
  identities in live-agent-auth".

### Task 9: Michael's morning list

**Depends on:** Tasks 2–8 (it copies their exact names and printed forms).

**Files:** Create `docs/superpowers/plans/2026-11-12-forge-push-protection-michael-steps.md`
(tracked, public, ignored by chezmoi as all of `docs/`).

**Interfaces:**
- Consumes: the item titles and fields in `private_dot_ssh/private_github-agent.pub.tmpl` and
  `dot_claude/modify_private_settings.json`; the remediation lines `forge-protection.sh` prints for
  the Task 2–4 fixtures; the paths of Tasks 5 and 7.
- Produces: one ordered, paste-ready list, the outline under "Michael's steps" below expanded: each
  step is what to do (a command in its own code block, or a click path) followed by the command or
  click path that verifies it and the expected result. Placeholders only, written as
  `<machine-account>`, `<repo-a>`, `<project-id>`, `<branch>`, `<org-url>`, `<project>`,
  `<repo-id>`; real values come from the check's output, which stays on his screen. Every
  verification prints booleans, logins or public keys, never a token.

- [ ] **Step 1: Copy the printed forms.** Run the Task 2–4 fixture cases that print each
  remediation (`main-owner-only`, `protect-main`, the GitLab POST and PATCH, the Azure create) and
  copy each line, replacing fixture names with the placeholders.
- [ ] **Step 2: Write the file** from the outline, one numbered step per outline item, in that
  order, with a one-line header naming the spec and this plan, and the line "Run the commands from
  your own terminal unless a step says the agent session: in a session `gh` is the machine
  account".
- [ ] **Step 3: Verify the file.** Each `op://` reference in it appears verbatim in the template or
  the settings script (`rg -F`). No client name: for every `~/Code/*/*` checkout whose origin is not
  on `github.com`, take each path segment of four or more characters and count its
  case-insensitive occurrences in the file; print only the total. Expected `0`.
- [ ] **Step 4: Commit.** `git add docs/superpowers/plans/2026-11-12-forge-push-protection-michael-steps.md`,
  commit "Write Michael's steps for the forge protection rules".

### Task 10: Full suite, measurements, Status

**Depends on:** Tasks 1–9.

**Files:** Modify this plan (Status and a completion banner); `AGENTS.md` only if the hook suite
measures heavy (below).

- [ ] **Step 1: Full suite.** `./tests/run.sh`, then `./tests/run.sh xreview git-forge-guard
  wt-functions` (the heavy three by exact name, AGENTS.md's pre-merge rule; the guard's files
  changed). Record passed/total for each and compare with `$SCRATCH/run-before.txt`: no suite that
  was green is red.
- [ ] **Step 2: The hook live.** Build `$SCRATCH/live-hooks/` with copies of both hook sources
  (mode 755) and `$SCRATCH/live-gitconfig` holding `[include] path = <the real global config>` and
  `[core] hooksPath = $SCRATCH/live-hooks`, then `GIT_CONFIG_GLOBAL=$SCRATCH/live-gitconfig
  ./tests/run.sh`. Expected: the same verdicts as Step 1. A difference is a suite that pushes under
  the global configuration: isolate it and record it.
- [ ] **Step 3: Measure.** `wc -l dot_claude/git-pu[s]h-guard.py tests/git-forge-guard.test.sh
  tests/git-pre-pu[s]h-hook.test.sh` (unquoted, so the shell expands the globs) and each suite's
  seconds from Step 1: the baseline merge 2 measures against (§4.4). If the hook suite runs longer
  than 120 s (the shortest heavy suite runs 123 s), give it a `test-requires: heavy` line and an
  AGENTS.md table row.
- [ ] **Step 4: No client name on the branch.** The count of Task 9 Step 3, run over `git diff
  main...HEAD` and `git log main..HEAD --format=%B`. Expected `0`.
- [ ] **Step 5: Optional live smoke run of the check.** `.scripts/forge-protection.sh check`
  (GET only). Report counts per state, never rows: it is the only run against real answers, so a
  row that is `unreadable` for a parse reason, not an HTTP status or timeout, is a defect to fix
  first.
- [ ] **Step 6: Status.** Set this plan's Status to `Implemented (merge 1, branch
  feat/forge-push-protection; no MR, a dotfiles line)` and add the banner: completed on <date>; do
  not run it again; merge 2 has its own plan. The spec stays `In progress`. Commit "Record merge 1
  of the forge protection plan as implemented".

---

## Michael's steps

Not tasks: each is a forge write, an account, a token or a reading of his own forms. This is the
outline Task 9 expands into the paste-ready file; the order is §6's, except that the apply follows
the GitHub steps (the check needs no apply). "Verify" is what Task 9 writes after each step. The file
opens with "Three decisions first" (GitHub identity reach and authorship, GitLab on shared projects,
the scan staying partly in the guard), which the spec's "Corrections from planning" records for
Michael to overrule.

1. **Machine account.** Create the GitHub machine account, two-factor authentication on, its login
   in 1Password. Verify: as that account, `https://github.com/settings/security` shows two-factor
   authentication enabled.
2. **Its SSH key.** 1Password > New Item > SSH Key (Ed25519), vault Private, titled exactly `GitHub
   Agent SSH Key`; add the public key at `https://github.com/settings/keys` as the machine account.
   Verify: `op read "op://Private/GitHub Agent SSH Key/public key"` prints one `ssh-ed25519` line
   (a public key), and the same key is listed on that page.
3. **Its token** (decision a, below). Recommended: a fine-grained token of his own account, only
   Contents read, Pull requests read and write, Issues read and write, Metadata read, on the
   repositories agents work in; into 1Password, vault Private, item `GitHub Agent Token`, field
   `token`. Verify: `GH_TOKEN="$(op read 'op://Private/GitHub Agent Token/token')" gh api user --jq
   .login` prints `<owner>`, and a merge call on a test pull request in a scratch repository is
   refused. If he declines the decision: a classic `public_repo` token of the machine account
   (§1.1's reason: a fine-grained token's resource owner offers only the machine account), verified
   as before.
4. **GitLab token.** On his own account: Edit profile > Access tokens > Add new token, fine-grained.
   Allow reading projects, repositories, branches and protected branches, pipelines, jobs, issues
   and merge requests, and creating and updating merge requests and their notes (the pre-merge gate
   reads projects and merge requests with it). Leave out merge request merge and approve, branch
   protect, project update, members and tokens. Into 1Password item `GitLab Agent Token`, field
   `token`. Verify: `GITLAB_TOKEN="$(op read 'op://Private/GitLab Agent Token/token')" glab api
   personal_access_tokens/self` lists none of merge, approve, protect or project update; the exact
   permission names go into the spec's Implementation notes.
5. **Merge 1** into the main checkout and publish `main` from his own terminal. The hook and the
   identity are not deployed yet.
6. **The check** (no apply needed), into a file outside the repository:
   `~/.local/share/chezmoi/.scripts/forge-protection.sh check`. Its output names repositories.
   Verify: one row per repository, `drift` with commands where nothing is set yet. Read on
   2026-11-13: 86 repositories (GitHub 43 own `drift` and 14 others' `unreadable`; gitlab.com 22
   `drift` and 3 `unreadable`; Azure 3 `unreadable` from an agent session; 1 self-hosted host the
   check does not know, `unreadable`).
7. **GitHub rulesets**, own terminal, on the repositories agents work in (a chosen few, not all 43):
   the `gh api --method POST …/rulesets` lines the check prints, filtered out of its saved output for
   those repositories, read, then run (`main-owner-only` on `dotfiles`, both rulesets elsewhere).
   Verify: `gh api repos/michaelrigart/<repo>/rules/branches/<branch> --jq '[.[].type] | sort'`
   prints `["creation","deletion","non_fast_forward","update"]` for each; the ruleset page the check
   names shows "Repository admin" as the only bypass of `main-owner-only` (this confirms `actor_id
   5`). The 14 repositories of other owners and the self-hosted one go in the exceptions file
   (step 13), with his unchosen dormant repositories.
8. **Collaborator.** Own terminal, a loop over the same repositories: `gh api --method PUT
   repos/michaelrigart/<repo>/collaborators/<machine-account> -f permission=push`; accept as the
   machine account in the browser. Verify: `gh api
   repos/michaelrigart/<repo>/collaborators/<machine-account>/permission --jq .permission` prints
   `write` for each.
9. **Apply.** `chezmoi apply`, `brew bundle --file ~/.config/homebrew/Brewfile` if gitleaks is
   missing, a new Claude Code session. Verify, own terminal: `git config --global --get
   core.hooksPath` prints `~/.config/git/hooks`; `ls ~/.config/git/hooks` lists `pre-push` and
   `secret-scan`; `test -s ~/.ssh/github-agent.pub && echo present`; `jq '.env | has("GH_TOKEN"),
   has("GITLAB_TOKEN")' ~/.claude/settings.json` prints `true` twice; `ssh -T git@github.com` greets
   `michaelrigart`. In the session: `$GIT_SSH_COMMAND -T git@github.com` names `<machine-account>`
   and `gh api user --jq .login` names the owner of the token (`michaelrigart` with the
   recommended token). The step lists what the hook does to his own pushes (budget, the
   `.gitleaksignore` rule, agent-worded messages, bare repositories).
10. **GitLab protection, one project.** A project of his choosing: record its protected branches
    first, then its printed PATCH (or POST) line. Verify: `glab api projects/<project-id>/protected_branches/<branch>
    --jq '{id, push: [.push_access_levels[].access_level], force: .allow_force_push}'` shows push
    `[0]`, force `false`, and an unchanged id. If GitLab refuses the fields, use the printed UI path
    (Settings > Repository > Protected branches) for every project, and tell the line which form
    worked, so the printed form is corrected before merge 2.
11. **GitLab protection, the rest.** Only the projects he decides on (decision b: where he alone
    pushes the default branch); the before-state of every one of them recorded first, then the
    printed lines, filtered out of a fresh output and read. Verify: a new check shows every chosen
    GitLab row `ok`.
12. **Azure DevOps**, per repository: `az repos policy list --org <org-url> --project <project>
    --repository-id <repo-id> --branch <branch>`; where missing, the printed `az repos policy
    approver-count create …`; then Repos > Branches > `<branch>` > ⋯ > Branch security > his user:
    "Bypass policies when pushing", "Bypass policies when completing pull requests" and "Force push"
    set to Deny where they show Allow. On one repository he first compares the check's reading with
    that dialog for his user: an Allow in the dialog while the check says `ok` means the token
    format is wrong, and he stops and reports it. If `az` hangs, the policy through Project settings >
    Repositories > `<repo>` > Policies > Branch policies. Verify: the same `policy list` with
    `--query "[?isEnabled && isBlocking].type.id"` includes
    `"fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"` (Minimum number of reviewers), or the policy shows as
    Required in the UI. A repository he cannot edit goes into step 13's file.
13. **Exceptions.** `mkdir -p ~/.config/forge-protection`, then one remote per line in
    `~/.config/forge-protection/exceptions`: the repositories of §2.4 he accepts as unprotected
    (the 14 others' GitHub repositories, the self-hosted one, unchosen dormant ones, projects he
    leaves). Verify: the check exits 0 (`echo $?`) and its summary's excepted count equals that list.
14. **Own-terminal verification.** The check exits 0; the GitHub rule list and collaborator
    permission for each chosen repository; `ssh -T git@github.com` greets `michaelrigart`.
15. **From a new agent session**, sandboxed: `./tests/run.sh live-agent-auth` prints
    `GITHUB_SSH=AGENT` and `GITLAB_SSH=READY`; with the agent token a GET of one project's protected
    branches succeeds; the check as the agent (with the fine-grained token its GitHub rows may not
    read `ok`, because `current_user_can_bypass` describes the token's user).
16. **Record.** Results go into the spec's Implementation notes without repository names, and
    the line is told merge 1 is verified; merge 2 is planned after that (§6).

The apply is step 9, after the GitHub steps, so no chosen repository has the machine account
missing when agent sessions switch to it; until the apply an agent session is still him, and the
local guard is what covers it.

## Rulings

Accepted limits of merge 1, recorded for Michael to overrule. None is code.

- The agent SSH pin covers `github.com` and `ssh.github.com`. A trailing-dot host name, an IP
  literal, an SSH host alias and an HTTPS remote are not covered (a pinned trailing-dot form was
  tried and reverted).
- Printed GitLab commands carry `--hostname gitlab.com`; the check reads `gitlab.com` only, and a
  project on another GitLab host reads `unreadable`.
- The `-F` ssh option, which selects the agent configuration, skips `/etc/ssh/ssh_config` for
  agent sessions; `~/.ssh/config` is still included for hosts other than GitHub's.
- Public-key templates render at mode 600 (the `private_` prefix of the template name).
- An archived repository is not `ok`: the check does not read the archived flag, so such a
  repository needs an exceptions line.
- A remote's tracking refs are attributed only to a push whose destination URL is its one fetch
  URL (Decisions row "Which history is excluded"); any other push scans the whole history.
- Tracking refs are evidence, not proof, of what a destination holds. A remote whose URL was
  changed to another repository without pruning its tracking refs still has them excluded for a
  push to the new address, as on main, where the guard excluded by remote name. The question of
  whose history the scan may skip was raised in four review rounds, each with a new variant; it is
  closed here at one rule. The structural alternative is parked for Michael: exclude only what the
  push handshake proves (the remote object id git hands the hook for each updated ref) and scan
  every new ref's whole history, at the cost of a full scan, and possibly the timeout refusal, on
  each first push of a branch.

## Owed

Rebase this branch onto main after `chore/test-audit` merges, then re-run the guard suites this
plan changes, by name: `./tests/run.sh git-forge-guard pre-pu hook-path` (`git-forge-guard`
exactly, to lift its heavy gate; `pre-pu` selects `git-pre-push-hook`). That audit cuts rows in
`claude-settings`, `git-config` and other suites this plan extends, and changes the global testing
rule to "test behaviour, not wording; extend a case before adding one": re-check the rows added
here against it.

