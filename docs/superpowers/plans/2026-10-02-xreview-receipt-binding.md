# xreview receipt binding (P1-A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bind every pre-merge approval to the exact change Codex reviewed and the branch it is
meant to land on, and gate every agent-run MR/PR creation and merge on it, with one locked
ledger per repository.

**Architecture:** One Python helper, `dot_claude/xreview-ledger.py`, owns three things: the
identity of a change (range normalization and a content fingerprint), the per-repository
ledger (locked, idempotent appends), and the gate's decision. `xreview` runs it as a command:
it records each review's targets, writes pending entries at dispatch and writes receipts at
collect. The pre-merge guard becomes a thin bash fast path in front of
`dot_claude/xreview-guard.py`. That file parses the command grammar and resolves the
repository, the remote head and the forge's destination, then imports the helper to decide.
Both Python files deploy to `~/.claude`, which the sandbox cannot write.

**Tech Stack:**
- bash: xreview, the guard front and the test suites;
- `/usr/bin/python3` 3.9, standard library only: hashlib, json, shlex, subprocess, importlib, signal;
- git 2.31 or later, for `--path-format=absolute`;
- jq;
- glab 1.120 and gh 2.102, stubbed in the tests;
- chezmoi.

**Spec:** `docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md`, approved
2026-10-02. Read it in full before any task. Section numbers below (§3.6 and so on) refer to it.

## Global Constraints

Copied from the spec, with the rulings of plan review rounds 1 to 3 marked as such. Every
task's requirements include these.

**The change and its fingerprint (§3.1)**
- A review target is (repository = absolute git common directory, `dest`, base commit, tip
  commit).
- **Default branch:** `refs/remotes/origin/HEAD`, falling back to `main`, then `master`.
- **Normalized range:** a left side naming a branch (`X`, `origin/X`, in `X..B` or `X...B`)
  normalizes to `dest` = `X` and `dest_ref` = the ref as given, with
  `base = git merge-base <dest_ref> <tip>`.
- **Partial range:** a commit on the left side keeps its literal base, has no `dest`, and is
  partial.
- **Full target:** it has a `dest` and `base = merge-base(dest_ref, tip)`. Only a full target
  opens the gate, and only for its `dest`.
- **Fingerprint:** the SHA-256 of the sorted records
  `<path>\t<old-mode>\t<new-mode>\t<old-blob>\t<new-blob>`, taken from:
  ```
  git diff --raw -z --no-abbrev --no-renames --no-ext-diff --no-textconv --ignore-submodules=none <base> <tip>
  ```
- An empty diff has no fingerprint and cannot be approved.
- The inlined review diff also uses `--ignore-submodules=none`. Plan review round 1 ruled that
  each target's packet diff is rendered by one function, from the recorded base..tip pair,
  with the fingerprint's flags: `--no-relative --no-ext-diff --no-textconv --no-renames
  --ignore-submodules=none`.

**Ledger entries (§3.2)**
- Both kinds carry `v:2`, `nonce`, `dispatched_at` (UTC, fixed at dispatch), `checkpoint` and
  `targets[]`.
- Each target has `repo`, `dest`, `dest_ref`, `branch`, `range`, `base`, `tip`, `full` and
  `fingerprint`.
- A receipt adds `verdict`, `findings`, `thread`, `turn` and `tier`.
- Entries are idempotent per nonce. A review's state is its receipt if one exists, otherwise
  its pending entry.
- v1 receipts (no `v`) are shown as on record and never open the gate.

**The ledger itself (§3.3)**
- **Location:** `$XDG_STATE_HOME/xreview/ledgers/<key>/reviews.jsonl`, where `<key>` is the
  SHA-256 of the absolute git common directory path. A `repo` file beside it names the path.
- **Lock:** each append takes a `mkdir <ledger>.lock` lock (macOS has no `flock(1)`). It
  retries for up to 5 s, and a lock older than 60 s is broken.
- Plan review round 1 added how a lock is broken:
  - each holder writes a unique owner token inside the lock directory;
  - breaking is serialized by `mkdir <ledger>.lock.break`;
  - under the break lock, the main lock is removed only if it still carries the stale token
    seen;
  - a release removes the lock only while it carries the releaser's own token.
- Plan review round 2 serialized the release: it takes `<ledger>.lock.break`, checks its
  token, removes the lock, then drops the break lock. A release that cannot take the break
  lock within the retry window leaves the lock to go stale, and only warns.
- Plan review round 3 ruled that `<ledger>.lock.break` is never broken automatically. It is
  held only for the few operations around a break or a release. If it exists and is older
  than 60 s, the writer fails closed: a dispatch refuses, and a collect or a release warns.
  The message names the path to remove by hand.
- A pending-write failure is fatal: the dispatch is refused before any turn. A receipt-write
  failure only warns on stderr.
- Reads parse one line at a time and skip a damaged line.

**Dispatch (§3.4)**
- `--diff [<repo-path>:]<range>` is repeatable.
- Spec and plan checkpoints may have no target, and then write no ledger entries.
- A pre-merge dispatch with no `--diff` targets the current branch against the default
  branch. One whose targets are all empty is refused.
- The size cap applies to the total of all inlined diffs.
- Targets and `dispatched_at` are kept in `turns/<nonce>.targets`. The turn record's format
  is unchanged.

**The guard (§3.6)**
- **Gated shapes:**
  - `glab mr create`/`new`; `gh pr create`/`new`;
  - `glab api`/`gh api` POST to `…/merge_requests` or `repos/<o>/<r>/pulls`;
  - `git merge <ref>` while the repository's current branch is its default branch;
  - `glab mr merge`/`accept [<n>]`; `glab api` PUT `…/merge_requests/<n>/merge`;
  - `gh pr merge [<n>]`; `gh api` PUT `repos/<o>/<r>/pulls/<n>/merge`.
- CLI creation must name `--target-branch`/`-b` (glab) or `--base`/`-B` (gh).
- **Denied as unresolved:** any `glab api`/`gh api` POST, PUT or PATCH whose path names
  `merge_requests` or `pulls`, unless the gate can read it. Also any GraphQL call carrying
  `mergeRequestCreate`, `mergeRequestAccept`, `mergeRequestSetAutoMerge`, `createPullRequest`,
  `mergePullRequest` or `enablePullRequestAutoMerge`.
- **Plain commands only:**
  - allowed: an optional leading `cd <literal path> &&`, `sudo`, `git -C <path>`,
    `glab -R <repo>`, `gh -R <repo>`, and `XREVIEW_GUARD=off`;
  - any other `VAR=` or an `env` wrapper on a gated verb is denied;
  - any other compound holding a gated verb is denied.
- Plan review round 1 ruled on three details of this grammar and on two things the gate
  checks:
  - redirections are read past wherever they stand;
  - `sudo` is plain only when bare;
  - `--help`/`-h` exempts a command only as the first argument after the subcommand, and a
    merge's `--abort`/`--quit`/`--continue` only as its sole argument;
  - an API call's `--hostname`, an absolute endpoint, a `-R` host and a PR/MR URL argument
    must all name origin's host and project;
  - a forge merge must come from origin's own project (no fork MR/PR), and must not go
    through a merge queue or merge train.
- Before round 2 the coordinator ruled on substitutions:
  - the body of every `$(…)` and backtick substitution is a candidate command, inside double
    quotes and outside; one inside single quotes stays inert;
  - a here-document with an unquoted delimiter (`<<EOF`, `<<-EOF`) is scanned the same way for
    its substitutions, and the rest of its body stays inert;
  - a quoted delimiter (`<<'EOF'`, `<<"EOF"`, `<<\EOF`) keeps the whole body inert.
- Plan review round 2 ruled:
  - **API host.** Without `--hostname`, the effective host of a `gh api` call is the guard's
    own `GH_HOST`, else `github.com`; for `glab api` it is `GITLAB_HOST` (or `GITLAB_URI`,
    `GITLAB_URL`), else the host of the repository's remote. It must equal origin's host, or
    the call is denied with a message naming `--hostname <origin host>`. `api.<host>` stays
    accepted for an absolute URL. Decision 17 adds a step to gh's order that was measured
    after the ruling: the one host in gh's `hosts.yml`, when it lists exactly one.
- Plan review round 3 ruled that the lookups inherit that host. `check_api_host` (or its
  caller) returns the single effective host, and every dependent lookup for the command (the
  MR/PR, the merge train or queue, the project) passes it explicitly: `--hostname <host>` for
  `glab api` and `gh api`, and `-R <host>/<owner>/<repo>` for `gh pr view`. The remote head
  is read from origin with `git ls-remote`.
  - **Redirections** are recognized wherever they stand in a word, outside quotes: `>`,
    `>>`, `<`, `2>`, `&>`, `>&`, `N>&M`, `<>`, `>|`. The operator and its operand are split
    off.
  - **Here-document delimiters** are read as a whole shell word: `'…'` or `"…"` holding any
    characters, a backslash escape, or unquoted up to a metacharacter. The closing line is
    compared with the delimiter, quotes removed. `<<-` strips leading tabs.
- **Creation** reads `git ls-remote <remote> refs/heads/<source>`. The source repository must
  be the checkout's `origin`, so forks are denied.
- **Forge merges:**
  - must pin `--sha <sha>` (glab), the GitLab API `sha`, `--match-head-commit <sha>` (gh), or
    the GitHub API `sha`;
  - deferred merges are denied, even pinned;
  - the destination commit is `refs/remotes/origin/D`. For a local `git merge` it is the
    checked-out default branch's `HEAD`.
- **Decision:**
  - compute F over `merge-base(<D's commit>, T)..T`;
  - consider the v2 pre-merge entries in R's ledger with a full target whose `repo` is R,
    whose `dest` is D and whose fingerprint is F;
  - allow if and only if the latest by `dispatched_at` is a receipt that says `approve`.
- **Fails closed** on a gated shape when there is no repository, the head is not available
  locally, the forge lookup fails, the change is empty, or the ledger is unreadable.
- **Fast path:** a payload containing none of `create`, `new`, `merge`, `accept`, `pulls` or
  `graphql` costs no subprocess.
- **Deny message:** it names the change (repo, source, destination, tip, fingerprint) and
  what is on record for it and for the branch name, v1 and pending entries included. It gives
  the dispatch `xreview dispatch --checkpoint pre-merge --diff <dest>...<branch> <body>`, and
  for a forge merge the head to pin.
- `XREVIEW_GUARD=off` is the only bypass.

**Repository facts**
- This is macOS: no `flock(1)`, and `/usr/bin/python3` is 3.9.
- Suites are executed (`./tests/x.test.sh`), never given an interpreter prefix. zsh suites
  keep their shebangs.
- A suite whose subject is missing exits 2.
- Commit messages are imperative, with no trailers and no mention of any AI tool.
- No Bash command in this plan contains `git` followed by `push`. The live push guard denies
  such a command, so pushes stay a separate plain call that is not part of this plan.

## Review Focus

These are the five input classes most likely to bite in use. Each line names the test that
pins it and the task that owns that test.

Test IDs are per suite, written as suite and ID: "ledger" is `tests/xreview-ledger.test.sh`,
"xreview" is `tests/xreview.test.sh`, and "guard" is `tests/xreview-guard.test.sh`.

1. **Different spellings of one repository's path.** A worktree, a symlinked path, or
   macOS's `/var` against `/private/var` must resolve to the same ledger. Otherwise problem 4
   (split ledgers) comes back without anyone seeing it.
   - Task 1: ledger C4-C7.
   - Task 5: xreview W19 (a harness worktree's review opens the gate in the main checkout).
2. **Commands that only mention a gated verb.** They must stay allowed. Recorded transcripts
   held nine false denies to five real ones for the first matcher. The cases:
   - an MR body written through a here-document whose lines begin with `git merge` or
     `glab mr create`, its delimiter spelled `EOF`, `'MR-BODY'`, `END.md` or `"a b"`;
   - a `#` inside a quoted title;
   - a commit message that says "merge";
   - `rg 'glab mr merge'`;
   - `--help`;
   - a redirection around an approved merge (`git merge feature > merge.log 2>&1`).

   The reverse also holds. None of these may hide a real verb:
   - a redirection, with or without blanks around it (`git>log merge x`);
   - a `sudo` option;
   - a `--help` option value;
   - a command substitution, whether inside double quotes or inside an unquoted
     here-document. This includes a backtick code span in an MR body written through
     `<<EOF`, which bash really runs.

   Tests: Task 6, guard A1-A19, B12-B39, C9 and C16-C22; Task 7, guard H8.
3. **Merges the forge defers on its own.** These must be denied:
   - glab 1.120 turns auto-merge on while a pipeline runs, so `glab mr merge <n> --sha <head>`
     alone is a deferred merge, and the message must name `--auto-merge=false`;
   - `gh pr merge` on a branch with a merge queue enables auto-merge or enqueues;
   - GitLab merge trains do the same.

   Task 8: guard M5, M6 and P10-P16.
4. **The deny's own dispatch, run as printed, must open the gate.** For forge shapes it names
   `origin/<dest>...<source>`, and a pre-merge dispatch with no `--diff` targets
   `origin/<default>...<branch>`. This keeps a stale local branch out of the fingerprint.
   - Task 7: guard I3 and I4.
   - Task 1: ledger D4.
5. **A reviewed repository whose configuration changes what `git diff` shows.** Three
   settings could make the reviewer see less than the receipt names: `diff.relative` with
   xreview run from a subdirectory, a `diff.external` driver, and a textconv attribute. The
   packet must still hold every path and every byte the fingerprint names.
   - Task 1: ledger A18-A47.
   - Task 4: xreview V24 and V25.

   Ordering when dispatches are close together or out of order (ledger F13, F14 and F25)
   stays pinned in Task 3.

## Decisions this plan takes

Each of these resolves a point the spec leaves open, improves the suggested design, or records
a ruling from plan review rounds 1 to 3 (marked R1, R2 or R3, with Codex's finding number).
Each one stays within the spec's goals.

**Where the code lives**

1. **The helper lives in `dot_claude/xreview-ledger.py`, not `dot_local/bin/executable_xreview-ledger`.**
   - Why: `~/.local/bin` is sandbox-writable, and the gate must not execute code an agent can
     edit. `~/.claude` is not writable from the sandbox.
   - How it is reached: `xreview` runs it as
     `/usr/bin/python3 "${XREVIEW_LEDGER:-$HOME/.claude/xreview-ledger.py}"`, and the guard
     imports it from its own directory. One file, no copies.
2. **The interpreter is pinned to `/usr/bin/python3`, not `/usr/bin/env python3`.** A reviewed
   repository's mise configuration can shadow `python3` on PATH. `xreview-rpc` and the push
   guard pin it for the same reason.
3. **The guard imports the helper rather than shelling out.** That saves a second interpreter
   start on every gated command, and every plain `git merge` reaches the decision code. The
   helper keeps its full command line for xreview and the tests.

**The ledger**

4. **Locking is `mkdir`, as the spec says, with owner tokens (R1, finding 8).**
   - Each holder writes a unique token into the lock directory.
   - A stale lock is broken only under `<ledger>.lock.break`, and only while it still
     carries the stale token seen.
   - The break lock is never broken automatically (R3, finding 2). Two writers that both
     judged it stale could each remove it, and each would then break or release under a
     break lock of its own. It is held only for a few steps, so one older than 60 s means a
     writer died holding it: `check_break_lock` makes every writer fail closed, naming the
     path to remove by hand. `acquire` checks it before each try, so an append fails at once
     rather than after the wait; a release that finds it leaves its own lock and warns.
     xreview's collect passes the helper's reason into its warning.
   - A release removes only the releaser's own lock, and checks and removes it under
     `<ledger>.lock.break` (R2, finding 3). Without that, a breaker could replace a lock
     between the releaser's check and its removal, and the releaser would delete the new
     holder's lock. A release that cannot take the break lock in time leaves its lock to go
     stale, and warns.
   - The two-breaker interleaving is tested deterministically, through the module's own
     functions with injected timestamps. So is the release: a test seam, `RELEASE_PAUSE`,
     stops a release between its check and its removal while a breaker tries to step in.
   - Rejected: Python's `fcntl.flock`. It is simpler and leaves nothing stale, but the spec
     names `mkdir`.
5. **One list of diff flags for the fingerprint and the packet (R1, finding 1).**
   - The helper's `patch()` (command `diff`) renders each target's packet from the recorded
     base..tip.
   - It uses the fingerprint's flags (`--no-relative --no-ext-diff --no-textconv --no-renames
     --ignore-submodules=none`), plus `--no-color` and `--text`. Binary is decided by the blob's
     content, never by gitattributes: a binary path is excluded from the one text diff and gets
     a summary line with both modes and both blob ids, its name quoted as git quotes a header
     path. The count of `diff --git` headers is checked against what the text records call
     for (two for a change between a regular file, a symlink and a gitlink, which git renders
     as a delete and a create), and `git` drops the `GIT_*_PATHSPECS` variables from its
     environment, so a packet that does not match the fingerprint fails closed.
   - Fingerprint records end with NUL rather than a newline: a git path cannot hold NUL, but it
     can hold a newline.
6. **The common directory is canonicalized with `realpath`.** git already resolves symlinks
   at discovery; this is defense in depth for paths recorded by worktrees.
7. **`dispatched_at` has microsecond precision,** and reviews with an equal time keep ledger
   order.
8. **A commit on the left of a range keeps its literal base (R1, finding 9).** This holds for
   both `C..B` and `C...B` (spec §3.1), and the packet shows exactly that base..tip.

**Dispatch and collect**

9. **Spec and plan reviews:**
   - with no target, they write no ledger entry (spec-literal). Their reviewer tier then
     appears only in the turn records, not in `xreview receipts --tiers`;
   - with targets, they get a receipt but no pending entry, because the spec writes pending
     entries for pre-merge only.
10. **Every empty target is refused**, as today. This is stricter than "all empty".
11. **The pending entries and the targets file are written after the pane checks and before
    the pane is freed.**
    - A refused pending write therefore touches nothing.
    - A turn-start that fails afterwards leaves an orphan pending entry. It keeps that change's
      gate closed until a new review, which is the conservative side.
12. **Turns from before this change still collect.** They write the v1 receipt into the
    per-checkout file, as today. The guard reads that file only to show what is on record.
13. **Ranges that suggest themselves use origin.** A pre-merge dispatch with no `--diff` uses
    `origin/<default>` when that ref exists, and a forge deny suggests
    `origin/<dest>...<source>`. Both measure against what the forge merges into.

**The guard: forges**

14. **A glab merge must say `--auto-merge=false`.** Otherwise it is denied as deferred
    (measured from `glab mr merge --help`, glab 1.120). `glab mr create --auto-merge` is
    denied too.
15. **Destination lookups, and the source repository (R1, finding 6):**
    - GitLab: `glab api projects/<project>/merge_requests/<n>`. For the `<branch>` and no-id
      forms, the one open MR whose `source_branch` matches. The MR's `project_id`,
      `source_project_id` and `target_project_id` must all be equal, and it was looked up in
      origin's project.
    - GitHub: `gh pr view [<n>] [-R <repo>] --json baseRefName,headRefName,headRefOid,isCrossRepository,headRepository,headRepositoryOwner`.
      The PR must not be cross-repository, and its head owner and name must be origin's.
16. **Merge queues and merge trains are deferred merges (R1, finding 7).**
    - GitHub merges, CLI and REST, query `repository(owner,name){mergeQueue(branch:D){id}}`
      through `gh api graphql`. A non-null result or a failed lookup is denied. This also
      denies `gh pr merge --admin` on such a branch.
    - GitLab merges read `glab api projects/<p>`. `merge_trains_enabled: true` or a failed
      lookup is denied. A project without that field (no trains on that tier) is allowed.
17. **Hosts (R1, findings 4 and 5):**
    - `glab api`/`gh api --hostname`, and an absolute endpoint, must name origin's host. An
      absolute GitHub endpoint may name `api.<host>`, and an absolute `…/graphql` endpoint is
      treated as GraphQL.
    - A `-R` with a host must match origin's host. gh reads `-R [HOST/]OWNER/REPO`. glab
      reads any `-R` but a URL or an scp-style address as a project path on its default
      host (measured with glab 1.120: `-R other.example/acme/app` requests the project
      `other.example/acme/app`), so for glab `-R HOST/PATH` names another project and is
      denied (R3; it was accepted before).
    - A PR/MR URL argument must name origin's host and project before any lookup.
    - Without `--hostname` the CLI picks the host, and that host must be origin's too (R2,
      finding 1):
      - `gh api`: `GH_HOST`, else the only host in gh's `hosts.yml` when it lists exactly one,
        else `github.com`. The middle step goes beyond the ruling. It was measured with gh
        2.102: with one host configured, `gh api user` went to that host, and with two it went
        to github.com, inside a repository whose origin was on the configured host as well.
        Only the file's top-level keys are read, never a value, and an unreadable file is a
        deny (`UNREADABLE`).
      - `glab api`: `glab help api` says the host is "the authenticated host in the current
        directory". `glab help config` documents the host variables, first one set wins:
        `GITLAB_HOST`, `GITLAB_URI`, `GL_HOST`; `glab help api` adds `GITLAB_URL`. Every one
        that is set must name origin's host, which also covers their order. With none set,
        glab picks a remote on a host it is signed in to, so every remote (from
        `git remote -v`, fetch and push) must be on origin's host (`SEVERAL_HOSTS`).
      - `GITLAB_API_HOST`, glab's documented override of the API host, must be origin's host
        when set (`API_HOST_VAR`). Measured: it sends `glab api` there, whatever the host.
      - The guard reads its own environment. The command cannot change it, because an
        assignment, `env` or `export` in front of a gated verb is not a plain command.
    - Every lookup goes to that host (R3, finding 1). `check_api_host` returns origin's host,
      and the MR, project-id and merge-train lookups pass `glab api --hostname <host>`, the
      merge-queue lookup `gh api graphql --hostname <host>`, and the PR lookup
      `gh pr view <n> -R <host>/<owner>/<repo>`. They name origin's project path, never the
      command's placeholder or numeric id, which the environment could resolve elsewhere.
    - A CLI verb's own host is checked the same way (beyond the letter of the R3 ruling).
      Pinning its lookups while the verb itself followed the environment would recreate the
      split the finding describes: the lookup on origin, the merge somewhere else.
      - A `-R` with a host (a URL, or gh's `HOST/OWNER/REPO`) was checked by
        `forge_context`.
      - A bare `-R OWNER/REPO` goes to the CLI's default host. Measured: gh 2.102 sends
        `gh pr view 9 -R acme/app` to gh's one configured host, and glab 1.120 sends
        `glab mr view 7 -R acme/app` to `GITLAB_HOST`, else to its config's `host`, else to
        gitlab.com, even inside a repository whose origin is elsewhere. So gh's default is
        `gh_default_host()`, and glab's is every set host variable, else every `host` key in
        its config.yml (the global one and the repository's own `.git/glab-cli/config.yml`),
        else gitlab.com. A default elsewhere is denied with `DEFAULT_HOST`, which names the
        `-R` that carries origin's host: `<host>/<path>` for gh, `https://<host>/<path>` for
        glab.
      - `GH_REPO` and `GITLAB_REPO` stand in for a missing `-R`. Measured: each retargets the
        verb. They must name origin's project, and they also fill the `:id` and
        `{owner}/{repo}` placeholders of an api call.
      - With no project named, the CLI takes origin, the only remote. Measured: a `GH_HOST`
        or `GITLAB_HOST` naming another host makes gh and glab fail ("none of the git remotes
        configured for this repository correspond to the … environment variable").
      - `gh pr merge` with no target keeps an unqualified `gh pr view --json …` lookup: gh
        refuses `-R` without a target, and this resolves the current branch's PR exactly as
        the merge does, on the host just checked.
18. **When the command does not name a project,** `origin` must be the checkout's only
    remote. With several remotes the CLI could pick another project; the deny tells the agent
    to pass the `-R` that carries origin's host (`explicit_repo`).
19. **Every other `POST`, `PUT` or `PATCH` under `merge_requests` or `pulls` is denied,** MR
    notes and approvals included (spec-literal). The CLI equivalents are not gated.

**The guard: grammar**

20. **What counts as part of a gated command (R1, findings 2 and 3):**
    - Here-document bodies, comments and redirections (any operator, any operand, before the
      command word or between arguments) are read past.
    - A process substitution counts as a command.
    - After a wrapper (`sudo`, `env`, `command`, `time`, `xargs`, …), every later word is a
      candidate command, so `sudo -u root git merge` is seen. It is then denied, because only
      a bare `sudo` is plain.
    - `--help`/`-h` exempts a command only as the first word after the verb, and `--abort`,
      `--quit` and `--continue` only as a merge's sole argument.
    - Substitutions (coordinator, before round 2): the body of every `$(…)` and backtick
      substitution is scanned as a command, recursively, outside single quotes and comments,
      double-quoted or not. So is each substitution in a here-document body whose delimiter is
      unquoted. The rest of such a body, and the whole body under a quoted or escaped
      delimiter, is data.
    - A gated verb found in a substitution is never part of a plain command: the command is
      denied with the plain-form message. Nesting deeper than 8 levels is denied.
    - Redirections need no blank around them (R2, finding 2). Outside quotes, an operator is
      recognized wherever it stands: where a word starts it may carry a descriptor (`2>`,
      `2>&1`), and inside a word it is the operator alone, as bash reads `feature2>err` as
      the word `feature2`. So `git>log merge x` is `git merge x`, and `git merge x>log`
      merges `x`.
    - A here-document delimiter is the whole shell word after `<<` or `<<-` (R2, finding 4):
      quoted parts are taken whole, whatever they hold (`'MR-BODY'`, `"a b"`), a backslash
      escapes one character, and an unquoted word runs to a metacharacter (`END.md`). Any
      quoting makes the body inert. The body ends at the line equal to the delimiter with
      its quotes removed, after leading tabs only for `<<-`.
21. **A `git merge` anywhere in a compound command is denied, on any branch.** The branch the
    merge will run on cannot be known from the text. A plain `git merge` with no ref on the
    default branch is denied; `git merge-base` is another command.
22. **`XREVIEW_GUARD=off` keeps matching anywhere in the command,** as today.
23. **Timeouts:**
    - the hook gets an explicit 60 s limit (`modify_private_settings.json`, pinned by
      `claude-settings.test.sh`);
    - the guard gives up at 40 s through `SIGALRM`;
    - each subprocess gets 8 s, the merge-queue and train lookups included.

    A hook that outruns its limit is non-blocking, so giving up early fails closed.
24. **The shell front has a second substring stage** (`glab|gh|git`), so payloads that only
    mention "new" or "create" still start no interpreter.

**Tests, evaluation and gaps**

25. **Fingerprint, normalization, locking and isolation tests live in a new
    `tests/xreview-ledger.test.sh`.** AGENTS.md wants one suite per script.
    `tests/xreview.test.sh` and `tests/xreview-guard.test.sh` cover the rest of §5.
26. **§4's evaluation attribution:** `.scripts/measure-interventions.py` learns the new
    "Pre-merge gate:" deny wording. A dated note goes into the safe-autonomy spec.
27. **`git pull`, `git rebase` and `git reset` onto the default branch are not gated.** The
    spec names only `git merge`; this is reported as a residual gap rather than added.

## Files

| Path | Change | Responsibility |
|---|---|---|
| `dot_claude/xreview-ledger.py` | create (T1-T3) | change identity, ledger, decision; CLI for xreview and tests |
| `dot_claude/xreview-guard.py` | create (T6-T8) | the gate's grammar and checks |
| `dot_claude/executable_xreview-guard.sh` | rewrite (T6) | fast path and fail-closed fallback |
| `dot_local/bin/executable_xreview` | modify (T4, T5) | targets, pending entries, receipts |
| `dot_claude/skills/cross-review/SKILL.md` | modify (T9) | §3.7 text |
| `.chezmoiignore` | modify (T1, T6) | allowlist the two `.py` files |
| `dot_claude/modify_private_settings.json` | modify (T6) | 60 s hook timeout |
| `.scripts/measure-interventions.py` | modify (T9) | attribute the new deny wording |
| `docs/superpowers/specs/2026-09-30-safe-autonomy-design.md` | modify (T9) | rollout note |
| `tests/xreview-ledger.test.sh` | create (T1-T3) | the helper |
| `tests/xreview.test.sh` | modify (T4, T5) | dispatch and collect |
| `tests/xreview-guard.test.sh` | rewrite (T6), extend (T7, T8) | the gate |
| `tests/xreview-skill.test.sh` | modify (T6, T9) | skill against implementation |
| `tests/claude-settings.test.sh` | modify (T1, T6) | timeout; helpers are chezmoi-managed |
| `tests/measure-interventions.test.sh` | modify (T9) | attribution |

## How to work this plan

**Where and on what**
- Run every command from the repository root, `/Users/michael/.local/share/chezmoi`, on the
  branch `feat/xreview-receipt-binding`.
- This checkout is shared. Right before each commit, `git branch --show-current` must print
  `feat/xreview-receipt-binding`.

**Writing files**
- Write file content with the Write and Edit tools only, never with a Bash heredoc, `echo`
  or `cat >`. These test files hold `glab api` writes, gated verbs and `git` subcommands at
  the start of lines. The live forge, push and pre-merge guards read those from a Bash
  command's text, and would ask or deny.
- An "Edit N - replace / with" step names an exact old text and its replacement. Each old
  text occurs exactly once in its file.
- A "replace from line A to line B" step replaces everything from line A up to, but not
  including, line B.

**Commands**
- No command here contains `git` followed by `push`. Test fixtures publish a branch with
  `git -C <origin> fetch <work> +refs/heads/<b>:refs/heads/<b>`.
- Execute suites directly, never through an interpreter.
- `./tests/xreview.test.sh` takes about four minutes: give that Bash call a timeout of
  600000 ms. The other suites take under a minute.

**Expected counts**
- Each "Expected" count is passed/total, measured on a scratch clone with every step of this
  plan applied in order.
- If a count differs, stop and find out why before going on.

---

## Task 1: The ledger helper: a change's identity

**Files:**
- Create: `dot_claude/xreview-ledger.py`
- Create: `tests/xreview-ledger.test.sh` (mode 755)
- Modify: `.chezmoiignore` (allowlist `!.claude/xreview-ledger.py`)
- Modify: `tests/claude-settings.test.sh` (section X: the helper is chezmoi-managed)

**Interfaces:**
- Consumes: nothing.
- Produces: the module `dot_claude/xreview-ledger.py`, which is also a command:
  `/usr/bin/python3 dot_claude/xreview-ledger.py <subcommand>`.
  - Python:
    - `class Fail(Exception)`; `CALL_TIMEOUT = 20.0`, the limit per git call, which the guard
      lowers.
    - `common_dir(repo: str) -> str`: the git common directory, absolute and through
      `realpath`. Raises `Fail("not inside a git repository (<repo>)")`.
    - `has_ref(repo, ref) -> bool`; `commit_of(repo, rev) -> str | None`;
      `current_branch(repo) -> str | None`.
    - `default_branch(repo) -> str`;
      `default_range(repo) -> str`: `origin/<default>...<branch>` when that ref exists, else
      `<default>...<branch or HEAD>`.
    - `merge_base(repo, a, b) -> str`: raises `Fail`.
    - `DIFF_FLAGS`, shared by `DIFF_RAW` (the fingerprint) and `DIFF_PATCH` (the packet):
      `--no-relative --no-ext-diff --no-textconv --no-renames --ignore-submodules=none`.
    - `fingerprint(repo, base, tip) -> str | None`: 64 hex characters, or `None` when nothing
      changed.
    - `patch(repo, base, tip) -> bytes`: the change as a patch the reviewer reads in full.
      Binary is decided by content (a NUL byte in either blob), never by gitattributes. One
      `git diff --text` with the same flags plus `--no-color` covers every text path, with the
      binary paths excluded as literal top-level pathspecs. After it come one summary line per
      binary path, `Binary file <path>: <old mode> <old blob> -> <new mode> <new blob>`, the
      path quoted as git quotes a header path (a control character, DEL, a byte of 0x80 or
      more, a double quote or a backslash puts it in double quotes, with git's short escapes
      and octal for the rest). The output has no NUL byte, and it raises `Fail` when git
      cannot diff or when its `diff --git` headers do not number what the text records call
      for: one each, two for a change between a regular file, a symlink and a gitlink. `git`
      drops the four `GIT_*_PATHSPECS` variables from the environment of every call.
    - `normalize(repo, rng) -> dict` with the keys `repo, dest, dest_ref, branch, range, base,
      tip, full, fingerprint`. A commit on the left keeps its literal base in both the `..` and
      the `...` form.
    - `now() -> str`: `YYYY-MM-DDTHH:MM:SS.ffffffZ`.
    - `state_home() -> str`; `ledger_key(common) -> str`; `ledger_file(common) -> str`.
  - Command line:
    - `key COMMON_DIR`, `path REPO`, `default-branch REPO`, `default-range REPO`, `now`;
    - `fingerprint REPO BASE TIP`: exit 3 and no output when the change is empty;
    - `diff REPO BASE TIP`: the patch on stdout, as bytes;
    - `normalize REPO RANGE`: compact JSON;
    - errors: exit 1 with `xreview-ledger: <reason>` on stderr; usage errors exit 2.

- [ ] **Step 1: Write the failing helper test.** Create `tests/xreview-ledger.test.sh` with
  exactly this content, then run `chmod 755 tests/xreview-ledger.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for dot_claude/xreview-ledger.py: the pre-merge review ledger and the identity of a
# reviewed change (spec docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md,
# sections 3.1-3.3 and the decision in 3.6).
#
# Fixtures are real git repositories under $TMPDIR, with a private git configuration and a
# private XDG_STATE_HOME. Every assertion pins an exact value or decision.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="$SRC/dot_claude/xreview-ledger.py"
[ -f "$LEDGER" ] || { echo "missing helper under test: $LEDGER" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
differs() { if [ -n "$2" ] && [ "$2" != "$3" ]; then _pass "$1"; else _fail "$1" "$2 = $3"; fi; }
L() { /usr/bin/python3 "$LEDGER" "$@"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrledger.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state" GIT_CEILING_DIRECTORIES="$ROOT"
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
  > "$GIT_CONFIG_GLOBAL"
unset XREVIEW_LEDGER_LOCK_WAIT

# mkrepo <dir>: a repository on main whose one commit holds a.txt, s.py, b.bin and run.sh.
mkrepo() {
  mkdir -p "$1" && git -C "$1" init -q
  printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n' > "$1/a.txt"
  printf 'x = "a b"\n    y = 1\n' > "$1/s.py"
  printf '\000\001\002\003\004' > "$1/b.bin"
  printf 'echo hi\n' > "$1/run.sh"
  git -C "$1" add -A && git -C "$1" commit -q -m init
}
commit() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }
# variant <repo> <branch>: a fresh branch off main, checked out, for one edit.
variant() { git -C "$1" switch -q -c "$2" main; }
fp() { L fingerprint "$1" "$2" "$3"; }

echo "A. the fingerprint names the exact change (spec 3.1)"
R="$ROOT/fp"; mkrepo "$R"
variant "$R" feature
sed -i '' 's/^two$/TWO/' "$R/a.txt"; commit "$R" "edit a"
F0="$(fp "$R" main feature)"
is "A1 a change has a 64-hex fingerprint" "$(printf '%s' "$F0" | grep -cE '^[0-9a-f]{64}$')" 1
is "A2 it is stable" "$(fp "$R" main feature)" "$F0"
git -C "$R" switch -q main; printf 'beta\n' > "$R/other.txt"; commit "$R" "main adds another file"
git -C "$R" switch -q feature; git -C "$R" rebase -q main
is "A3 a clean rebase onto a destination change in another file keeps it" "$(fp "$R" main feature)" "$F0"
git -C "$R" switch -q main; sed -i '' 's/^seven$/SEVEN/' "$R/a.txt"; commit "$R" "main edits a"
git -C "$R" switch -q feature; git -C "$R" rebase -q main
differs "A4 a rebase over a destination change in the same file changes it" "$(fp "$R" main feature)" "$F0"
F1="$(fp "$R" main feature)"
sed -i '' 's/^three$/THREE/' "$R/a.txt"; commit "$R" "one more line"
differs "A5 a one-line text change changes it" "$(fp "$R" main feature)" "$F1"
variant "$R" ws1; sed -i '' 's/^    y = 1$/  y = 1/' "$R/s.py"; commit "$R" "indent 2"
variant "$R" ws2; sed -i '' 's/^    y = 1$/   y = 1/' "$R/s.py"; commit "$R" "indent 3"
differs "A6 a whitespace-only change (indentation) changes it" "$(fp "$R" main ws1)" "$(fp "$R" main ws2)"
variant "$R" str1; sed -i '' 's/"a b"/"a  b"/' "$R/s.py"; commit "$R" "two spaces in a string"
is "A7 a whitespace-only change inside a string is a change" "$(fp "$R" main str1 | grep -cE '^[0-9a-f]{64}$')" 1
variant "$R" str2; sed -i '' 's/"a b"/"a   b"/' "$R/s.py"; commit "$R" "three spaces in a string"
differs "A8 and two such changes differ" "$(fp "$R" main str1)" "$(fp "$R" main str2)"
variant "$R" loc1; sed -i '' 's/^two$/edited/' "$R/a.txt"; commit "$R" "edit line 2"
variant "$R" loc2; sed -i '' 's/^six$/edited/' "$R/a.txt"; commit "$R" "edit line 6"
variant "$R" loc3; sed -i '' 's/^two$/edited/' "$R/a.txt"; commit "$R" "line 2 again"
is "A9 the same edit at the same place is the same change" "$(fp "$R" main loc3)" "$(fp "$R" main loc1)"
differs "A10 the same edit applied at a different location changes it" "$(fp "$R" main loc1)" "$(fp "$R" main loc2)"
variant "$R" bin; printf '\000\001\002\003\005' > "$R/b.bin"; commit "$R" "one byte"
B0="$(fp "$R" main bin)"
printf '\000\001\002\003\006' > "$R/b.bin"; commit "$R" "another byte"
differs "A11 a one-byte binary change changes it" "$(fp "$R" main bin)" "$B0"
# executable <repo>: run.sh becomes executable, on disk and in the index, and is committed.
executable() { chmod +x "$1/run.sh"; git -C "$1" update-index --chmod=+x run.sh; git -C "$1" commit -q -m "mode"; }
variant "$R" mode; executable "$R"
is "A12 a mode-only change is a change" "$(fp "$R" main mode | grep -cE '^[0-9a-f]{64}$')" 1
variant "$R" content; printf 'echo hi\n# x\n' > "$R/run.sh"; commit "$R" "content"
M1="$(fp "$R" main content)"
executable "$R"
differs "A13 a mode-only change on top of a content change changes it" "$(fp "$R" main content)" "$M1"
git -C "$R" config diff.ignoreSubmodules all
variant "$R" sub
git -C "$R" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,sub
git -C "$R" commit -q -m "add a gitlink"
G1="$(fp "$R" main sub)"
is "A14 a gitlink is a change even with diff.ignoreSubmodules=all" "$(printf '%s' "$G1" | grep -cE '^[0-9a-f]{64}$')" 1
git -C "$R" update-index --cacheinfo 160000,2222222222222222222222222222222222222222,sub
git -C "$R" commit -q -m "move the gitlink"
differs "A15 a gitlink (submodule pointer) change changes it" "$(fp "$R" main sub)" "$G1"
git -C "$R" config --unset diff.ignoreSubmodules
out="$(fp "$R" main main)"; rc=$?
is "A16 an empty range has no fingerprint (exit 3, nothing printed)" "$rc/$out" "3/"
git -C "$R" config diff.renames copies
variant "$R" mv; git -C "$R" mv a.txt moved.txt; commit "$R" "rename"
is "A17 a rename is a delete plus an add, whatever diff.renames says" \
   "$(fp "$R" main mv | grep -cE '^[0-9a-f]{64}$')" 1
git -C "$R" config --unset diff.renames
variant "$R" rel; mkdir -p "$R/deep"; printf 'in\n' > "$R/deep/in.txt"; printf 'out\n' > "$R/out.txt"
commit "$R" "one file inside deep/, one outside"
F_ROOT="$(fp "$R" main rel)"
git -C "$R" config diff.relative true
is "A18 run from a subdirectory under diff.relative, the fingerprint is the same" "$(fp "$R/deep" main rel)" "$F_ROOT"
# The patch the reviewer reads, under every setting that could hide a path or rewrite content:
# diff.relative from a subdirectory, an external driver that prints nothing, and a textconv.
printf '#!/bin/sh\nexit 0\n' > "$ROOT/silent-diff"; chmod +x "$ROOT/silent-diff"
git -C "$R" config diff.external "$ROOT/silent-diff"
git -C "$R" config diff.upper.textconv 'tr a-z A-Z'
printf '*.txt diff=upper\n' > "$R/.git/info/attributes"
out="$(L diff "$R/deep" main rel)"
is "A19 the patch names every path the fingerprint names" \
   "$(printf '%s\n' "$out" | sed -n 's/^diff --git a\/\([^ ]*\) .*/\1/p' | sort | tr '\n' ' ')" "deep/in.txt out.txt "
is "A20 with the content as committed, never converted" "$(printf '%s\n' "$out" | grep -c '^+in$')" 1
is "A21 and the fingerprint ignores all three settings too" "$(fp "$R/deep" main rel)" "$F_ROOT"
git -C "$R" config --unset diff.relative; git -C "$R" config --unset diff.external
git -C "$R" config --unset diff.upper.textconv; rm "$R/.git/info/attributes"
# Binary is decided by content, never by gitattributes: a text path marked -diff, or bound to a
# driver with binary=true, must still show its changed lines in the packet.
variant "$R" attr; sed -i '' 's/^two$/TWO2/' "$R/a.txt"; commit "$R" "text under attributes"
printf '*.txt -diff\n' > "$R/.git/info/attributes"
is "A22 a path marked -diff still shows its changed line" "$(L diff "$R" main attr | grep -c '^+TWO2$')" 1
printf '*.txt diff=hide\n' > "$R/.git/info/attributes"; git -C "$R" config diff.hide.binary true
is "A23 so does a diff driver with binary=true" "$(L diff "$R" main attr | grep -c '^+TWO2$')" 1
git -C "$R" config --unset diff.hide.binary; rm "$R/.git/info/attributes"
variant "$R" bn; printf '\000\001\002\003\007' > "$R/b.bin"; commit "$R" "binary change"
L diff "$R" main bn > "$ROOT/bn.patch"
is "A24 a true binary file gets one summary line with both blob ids" \
   "$(cat "$ROOT/bn.patch")" "Binary file b.bin: 100644 $(git -C "$R" rev-parse main:b.bin) -> 100644 $(git -C "$R" rev-parse bn:b.bin)"
is "A25 and the patch holds no NUL byte" "$(tr -d '\000' < "$ROOT/bn.patch" | wc -c | tr -d ' ')" "$(wc -c < "$ROOT/bn.patch" | tr -d ' ')"
variant "$R" glob; printf 'g\n' > "$R/*.txt"; printf 'a\000b\n' > "$R/a.txt"; commit "$R" "a file named *.txt, and a binary a.txt"
L diff "$R" main glob > "$ROOT/glob.patch"
is "A26 a file named *.txt is read literally: its own line shows" "$(grep -c '^+g$' "$ROOT/glob.patch")" 1
is "A27 and does not pull in another .txt path as text" "$(grep -c '^diff --git a/a.txt' "$ROOT/glob.patch")" 0
is "A28 which is summarized as binary" "$(grep -c '^Binary file a.txt: ' "$ROOT/glob.patch")" 1
# The pathspec environment variables a reviewed repository's mise.toml or direnv could set must
# not change what the packet holds.
is "A29 GIT_LITERAL_PATHSPECS=1 does not hide the text change" \
   "$(GIT_LITERAL_PATHSPECS=1 L diff "$R" main glob | grep -c '^+g$')" 1
is "A30 GIT_GLOB_PATHSPECS=1 leaves the packet unchanged" \
   "$(GIT_GLOB_PATHSPECS=1 L diff "$R" main glob | cmp - "$ROOT/glob.patch" && echo same)" same
is "A31 and so does GIT_NOGLOB_PATHSPECS=1" \
   "$(GIT_NOGLOB_PATHSPECS=1 L diff "$R" main glob | cmp - "$ROOT/glob.patch" && echo same)" same
git -C "$R" config diff.relative true; mkdir -p "$R/sub"
is "A32 with binary paths, run from a subdirectory under diff.relative, the packet is the same" \
   "$(L diff "$R/sub" main glob | cmp - "$ROOT/glob.patch" && echo same)" same
git -C "$R" config --unset diff.relative; rmdir "$R/sub"
git -C "$R" reset -q --hard
# x.txt (text) and X.txt (binary), built through the index: case-colliding paths.
h_text="$(printf 'lower\n' | git -C "$R" hash-object -w --stdin)"
h_bin="$(printf 'a\000b\n' | git -C "$R" hash-object -w --stdin)"
variant "$R" icase
git -C "$R" update-index --add --cacheinfo "100644,$h_text,x.txt"
git -C "$R" update-index --add --cacheinfo "100644,$h_bin,X.txt"
git -C "$R" commit -q -m "x.txt and X.txt"; git -C "$R" switch -q -f main   # the two collide on disk
GIT_ICASE_PATHSPECS=1 L diff "$R" main icase > "$ROOT/icase.patch"
is "A33 GIT_ICASE_PATHSPECS=1: no NUL byte in the packet" \
   "$(tr -d '\000' < "$ROOT/icase.patch" | wc -c | tr -d ' ')" "$(wc -c < "$ROOT/icase.patch" | tr -d ' ')"
ZERO="$(printf '0%.0s' {1..40})"
is "A34 X.txt is a summary line" "$(grep -cxF "Binary file X.txt: 000000 $ZERO -> 100644 $h_bin" "$ROOT/icase.patch")" 1
is "A35 and x.txt still shows its text" "$(grep -c '^+lower$' "$ROOT/icase.patch")" 1
variant "$R" bmode; chmod +x "$R/b.bin"; git -C "$R" update-index --chmod=+x b.bin; git -C "$R" commit -q -m "binary mode"
B_ID="$(git -C "$R" rev-parse main:b.bin)"
is "A36 a binary mode-only change shows both modes" "$(L diff "$R" main bmode)" \
   "Binary file b.bin: 100644 $B_ID -> 100755 $B_ID"
variant "$R" nl; printf 'a\000b\n' > "$R/$(printf 'bad\nforged')"; commit "$R" "a binary file with a newline in its name"
L diff "$R" main nl > "$ROOT/nl.patch"
is "A37 a newline in a file name cannot start a packet line" "$(grep -c '^forged' "$ROOT/nl.patch")" 0
is "A38 the name appears quoted" "$(grep -c '^Binary file "bad\\nforged": ' "$ROOT/nl.patch")" 1
is "A39 a packet that does not match the change is refused" "$(/usr/bin/python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real = m.git
m.git = lambda repo, *a, raw=False: b"" if "--text" in a else real(repo, *a, raw=raw)
try:
    m.patch(sys.argv[2], "main", "attr"); print("accepted")
except m.Fail as e:
    print("refused" if "does not match the change" in str(e) else str(e))
' "$LEDGER" "$R")" refused
# A change between a regular file, a symlink and a gitlink is a delete plus a create in a patch:
# two headers for one raw record, which the cross-check must expect.
variant "$R" tc; rm "$R/a.txt"; ln -s target "$R/a.txt"; commit "$R" "a.txt becomes a symlink"
out="$(L diff "$R" main tc 2>&1)"
is "A40 a file turned symlink renders the old side" "$(printf '%s\n' "$out" | grep -c '^-one$')" 1
is "A41 and the new side" "$(printf '%s\n' "$out" | grep -c '^+target$')" 1
git -C "$R" switch -q -c tc2 tc; rm "$R/a.txt"; printf 'back\n' > "$R/a.txt"; commit "$R" "a.txt is a file again"
out="$(L diff "$R" tc tc2 2>&1)"
is "A42 a symlink turned file renders the new side" "$(printf '%s\n' "$out" | grep -c '^+back$')" 1
is "A43 and the old side" "$(printf '%s\n' "$out" | grep -c '^-target$')" 1
variant "$R" tg
git -C "$R" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,a.txt
git -C "$R" commit -q -m "a.txt becomes a gitlink"; git -C "$R" switch -q -f main
out="$(L diff "$R" main tg 2>&1)"
is "A44 a file turned gitlink renders the old side" "$(printf '%s\n' "$out" | grep -c '^-one$')" 1
is "A45 and the new side" "$(printf '%s\n' "$out" | grep -c '^+Subproject commit 1111111111111111111111111111111111111111$')" 1
# Path quoting is git's own: short escapes, octal for the rest, bytes of 0x80 and up in octal.
QN=$'q\a\b\v\f\r\001\303\251"\\z'
variant "$R" qp; printf 'a\000b\n' > "$R/$QN"; commit "$R" "a binary file with an awkward name"
git -C "$R" diff --raw --no-renames main qp | cut -f2 > "$ROOT/qp.git"
L diff "$R" main qp | sed -n 's/^Binary file \(.*\): 000000 .*/\1/p' > "$ROOT/qp.ours"
is "A46 the quoted name is what git writes for it" "$(cat "$ROOT/qp.ours")" "$(cat "$ROOT/qp.git")"
is "A47 as spelled out: short escapes, then octal" "$(cat "$ROOT/qp.ours")" '"q\a\b\v\f\r\001\303\251\"\\z"'
git -C "$R" switch -q main
git -C "$R" switch -q main

echo "B. range normalization (spec 3.1)"
N="$ROOT/norm"; mkrepo "$N"
variant "$N" feature; printf 'f\n' > "$N/f.txt"; commit "$N" "feature"
git -C "$N" switch -q main; printf 'm\n' > "$N/m.txt"; commit "$N" "main moves on"
MB="$(git -C "$N" merge-base main feature)"
t="$(L normalize "$N" main..feature)"
is "B1 main..feature after main advanced is full" "$(printf '%s' "$t" | jq -r .full)" true
is "B2 its base is the merge-base, not main's head" "$(printf '%s' "$t" | jq -r .base)" "$MB"
is "B3 dest and dest_ref are main" "$(printf '%s' "$t" | jq -r '"\(.dest)/\(.dest_ref)"')" "main/main"
is "B4 the branch is the tip's" "$(printf '%s' "$t" | jq -r .branch)" feature
is "B5 the fingerprint is the merge-base diff's" "$(printf '%s' "$t" | jq -r .fingerprint)" "$(fp "$N" "$MB" feature)"
is "B6 the range is kept as written" "$(printf '%s' "$t" | jq -r .range)" "main..feature"
is "B7 main...feature normalizes to the same change" \
   "$(L normalize "$N" main...feature | jq -r '"\(.base) \(.fingerprint) \(.full)"')" \
   "$(printf '%s' "$t" | jq -r '"\(.base) \(.fingerprint) \(.full)"')"
# hotfix starts at main's head; the remote release/1.2 is there too, while a stale local
# release/1.2 still sits on the root commit, so the two refs give different merge-bases.
git -C "$N" switch -q -c hotfix main; printf 'h\n' > "$N/h.txt"; commit "$N" "hotfix"
git -C "$N" update-ref refs/remotes/origin/release/1.2 main
REMOTE_MB="$(git -C "$N" merge-base origin/release/1.2 hotfix)"
t="$(L normalize "$N" origin/release/1.2...hotfix)"
is "B8 origin/release/1.2...hotfix with no local release/1.2 is full" "$(printf '%s' "$t" | jq -r .full)" true
is "B9 for the destination release/1.2" "$(printf '%s' "$t" | jq -r .dest)" "release/1.2"
is "B10 with the ref as written" "$(printf '%s' "$t" | jq -r .dest_ref)" "origin/release/1.2"
is "B11 its base comes from the remote ref" "$(printf '%s' "$t" | jq -r .base)" "$REMOTE_MB"
git -C "$N" branch release/1.2 "$(git -C "$N" rev-list --max-parents=0 main)"   # a stale local branch
differs "B12 the stale local release/1.2 would give another base" "$(git -C "$N" merge-base release/1.2 hotfix)" "$REMOTE_MB"
is "B13 and it is not used" "$(L normalize "$N" origin/release/1.2...hotfix | jq -r .base)" "$REMOTE_MB"
SHA="$(git -C "$N" rev-parse main~1)"
t="$(L normalize "$N" "${SHA:0:7}..feature")"
is "B14 a commit-based left side is partial" "$(printf '%s' "$t" | jq -r '"\(.full)/\(.dest)"')" "false/null"
is "B15 and keeps its literal base" "$(printf '%s' "$t" | jq -r .base)" "$SHA"
is "B16 HEAD~1..HEAD is partial" "$(L normalize "$N" HEAD~1..HEAD | jq -r .full)" false
out="$(L normalize "$N" feature 2>&1)"; rc=$?
is "B17 a range without .. is refused" "$rc/$(printf '%s' "$out" | grep -c '<base>..<tip>')" "1/1"
out="$(L normalize "$N" no-such..feature 2>&1)"; rc=$?
is "B18 an unresolvable side is refused" "$rc/$(printf '%s' "$out" | grep -c 'cannot resolve no-such')" "1/1"
is "B19 an empty range normalizes with no fingerprint" "$(L normalize "$N" main...main | jq -r .fingerprint)" null
C="$(git -C "$N" rev-parse hotfix)"     # diverged from feature: their merge-base is the root
t="$(L normalize "$N" "$C...feature")"
is "B20 a divergent commit...branch keeps its literal base, not the merge-base" \
   "$(printf '%s' "$t" | jq -r '"\(.base) \(.full)"')" "$C false"
is "B21 and names the change base..tip" "$(printf '%s' "$t" | jq -r .fingerprint)" "$(fp "$N" "$C" feature)"

echo "C. one ledger per repository (spec 3.3)"
REAL="$(cd "$N" && pwd -P)"
COMMON="$(cd "$(git -C "$N" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
is "C1 key is the SHA-256 of the path" "$(L key /a_b/.git)" "$(printf '%s' /a_b/.git | shasum -a 256 | cut -d' ' -f1)"
differs "C2 paths that collide under / -> _ get different keys" "$(L key /a_b/.git)" "$(L key /a/b/.git)"
KEY="$(printf '%s' "$COMMON" | shasum -a 256 | cut -d' ' -f1)"
is "C3 path is the ledger of the repository's common dir" "$(L path "$N")" "$XDG_STATE_HOME/xreview/ledgers/$KEY/reviews.jsonl"
is "C4 the normalized target names that common dir" "$(L normalize "$N" main...feature | jq -r .repo)" "$COMMON"
git -C "$N" worktree add -q "$ROOT/norm-wt" feature 2>/dev/null
is "C5 a worktree resolves to the same ledger" "$(L path "$ROOT/norm-wt")" "$(L path "$N")"
ln -s "$REAL" "$ROOT/norm-link"
is "C6 a symlinked path resolves to the same ledger" "$(L path "$ROOT/norm-link")" "$(L path "$N")"
is "C7 and the same target repo" "$(L normalize "$ROOT/norm-link" main...feature | jq -r .repo)" "$COMMON"
out="$(L path "$ROOT" 2>&1)"; rc=$?
is "C8 outside a repository there is no ledger" "$rc/$(printf '%s' "$out" | grep -c 'not inside a git repository')" "1/1"

echo "D. the default branch and the default target (spec 3.1, 3.4)"
D="$ROOT/dflt"; mkrepo "$D"
is "D1 no origin: main" "$(L default-branch "$D")" main
git -C "$D" branch -m main master
is "D2 a master-only repository: master" "$(L default-branch "$D")" master
git -C "$D" update-ref refs/remotes/origin/trunk master
git -C "$D" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
is "D3 origin/HEAD wins" "$(L default-branch "$D")" trunk
git -C "$D" switch -q -c topic
is "D4 the default target uses origin's default branch" "$(L default-range "$D")" "origin/trunk...topic"
git -C "$D" symbolic-ref --delete refs/remotes/origin/HEAD; git -C "$D" update-ref -d refs/remotes/origin/trunk
is "D5 without origin, the local default branch" "$(L default-range "$D")" "master...topic"
git -C "$D" switch -q --detach
is "D6 a detached HEAD targets HEAD" "$(L default-range "$D")" "master...HEAD"
is "D7 now is UTC to the microsecond" "$(L now | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$')" 1

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
```

- [ ] **Step 2: Write the failing chezmoi check.** Apply this to `tests/claude-settings.test.sh`:

Edit 1 - replace:

```bash
        *)      _fail "hook script $f is chezmoi-managed" "not in \`chezmoi managed\`" ;;
      esac
    done
  fi
else
```

with:

```bash
        *)      _fail "hook script $f is chezmoi-managed" "not in \`chezmoi managed\`" ;;
      esac
    done
  fi
  # The pre-merge gate's Python halves deploy beside its shell front, each through its own
  # .chezmoiignore allowlist entry. Without one the file never deploys: the gate then refuses
  # every gated command, and xreview cannot dispatch.
  for f in .claude/xreview-ledger.py; do
    case "$managed" in
      *"$f"*) _pass "helper $f is chezmoi-managed" ;;
      *)      _fail "helper $f is chezmoi-managed" "not in \`chezmoi managed\`" ;;
    esac
  done
else
```

- [ ] **Step 3: Run both and confirm they fail.**
  - `./tests/xreview-ledger.test.sh`: expect exit 2 with
    `missing helper under test: …/dot_claude/xreview-ledger.py`.
  - `./tests/claude-settings.test.sh 2>&1 | tail -3`: expect
    `FAIL: helper .claude/xreview-ledger.py is chezmoi-managed` and
    `RESULT: 176 passed, 1 failed`.

- [ ] **Step 4: Write the helper.** Create `dot_claude/xreview-ledger.py` with exactly:

```python
#!/usr/bin/python3
# Pinned to the system interpreter, not `env python3`: an untrusted mise.toml in a reviewed
# repository can shadow `python3` on PATH, and the pre-merge gate must not be shadowable.
"""xreview-ledger - the pre-merge review ledger, and the identity of a reviewed change.

Managed by chezmoi (source: dot_claude/xreview-ledger.py). xreview runs it to write the
ledger; xreview-guard.py beside it imports it to decide the gate. It lives in ~/.claude, not
~/.local/bin, so the gate never executes code from a directory the sandbox can write.
Design: docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md, sections 3.1-3.3
and the decision in 3.6.

  key            COMMON_DIR                 SHA-256 of an absolute git common directory
  path           REPO                       the ledger file of the repository REPO is in
  default-branch REPO                       origin/HEAD's branch, else main, else master
  default-range  REPO                       <origin/default or default>...<current branch or HEAD>
  fingerprint    REPO BASE TIP              the change's exact content identity (exit 3: empty)
  diff           REPO BASE TIP              the change as a patch, for the review packet
  normalize      REPO RANGE                 one review target, as JSON
  now                                       the UTC time, to the microsecond
  append         COMMON_DIR ENTRY_JSON      one v2 entry, locked, idempotent per (nonce, kind)
  decide         REPO DEST DEST_REV TIP [--branch NAME]   the gate's decision, as JSON
  show           REPO                       every line on record: the ledger, then the legacy file

Exit codes: 0 ok (decide: allow), 1 failed (decide: deny), 2 usage, 3 empty change.
Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

LOCK_WAIT = 5.0          # seconds an append waits for the ledger lock
LOCK_STALE = 60.0        # a lock older than this was left by a crashed writer
CALL_TIMEOUT = 20.0      # per git call; the guard lowers it to fit its own budget
# The flags of every diff the ledger names or renders - the fingerprint, and the patch the
# reviewer reads - so the two always cover the same paths and content. Each pins an input the
# user's configuration could change: diff.relative would drop paths outside the current
# directory, an external or textconv driver would rewrite or hide content, renames would merge
# a delete and an add, and diff.ignoreSubmodules or submodule.<name>.ignore would hide a gitlink.
DIFF_FLAGS = ["--no-relative", "--no-ext-diff", "--no-textconv", "--no-renames",
              "--ignore-submodules=none"]
PATHSPEC_VARS = ("GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS",
                 "GIT_ICASE_PATHSPECS")
DIFF_RAW = ["diff", "--raw", "-z", "--no-abbrev"] + DIFF_FLAGS
DIFF_PATCH = ["diff", "--no-color"] + DIFF_FLAGS
USAGE = ("usage: xreview-ledger key COMMON_DIR | path REPO | default-branch REPO | "
         "default-range REPO | fingerprint REPO BASE TIP | diff REPO BASE TIP | "
         "normalize REPO RANGE | now | "
         "append COMMON_DIR ENTRY_JSON | decide REPO DEST DEST_REV TIP [--branch NAME] | "
         "show REPO")


class Fail(Exception):
    """A step that could not be completed, carrying the reason a caller shows."""


# ------------------------------------------------------------------ git
def git_env():
    """The environment of every git call, without the variables that change how a pathspec is
    read: a reviewed repository's mise.toml or direnv could set them, and the packet's
    pathspecs would then match other paths than the ones the fingerprint names."""
    return {k: v for k, v in os.environ.items() if k not in PATHSPEC_VARS}


def git(repo, *args, raw=False):
    """stdout of `git -C repo args` (stripped text, or bytes when raw), or None on failure."""
    try:
        p = subprocess.run(["git", "-C", repo] + list(args), capture_output=True,
                           timeout=CALL_TIMEOUT, env=git_env())
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    return p.stdout if raw else p.stdout.decode("utf-8", "replace").strip()


def common_dir(repo):
    """The repository's git common directory, absolute and with symlinks resolved, so every
    worktree and every spelling of the path (/var vs /private/var) names one ledger."""
    out = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not out:
        raise Fail("not inside a git repository ({})".format(repo))
    return os.path.realpath(out)


def has_ref(repo, ref):
    return git(repo, "show-ref", "--verify", "--quiet", ref) is not None


def commit_of(repo, rev):
    """The full id of the commit rev names, or None."""
    if not rev or rev.startswith("-"):
        return None
    return git(repo, "rev-parse", "--verify", "--quiet", rev + "^{commit}") or None


def current_branch(repo):
    return git(repo, "symbolic-ref", "--quiet", "--short", "HEAD") or None


def default_branch(repo):
    """origin/HEAD's branch, else main, else master (a local or remote-tracking branch of
    that name), else main."""
    head = git(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    if head and head.startswith("origin/"):
        return head[len("origin/"):]
    for name in ("main", "master"):
        if has_ref(repo, "refs/heads/" + name) or has_ref(repo, "refs/remotes/origin/" + name):
            return name
    return "main"


def default_range(repo):
    """A pre-merge dispatch's target when none is named: the current branch against the
    default branch, as origin has it when origin has it (that is what a forge merges into)."""
    dest = default_branch(repo)
    left = "origin/" + dest if has_ref(repo, "refs/remotes/origin/" + dest) else dest
    return "{}...{}".format(left, current_branch(repo) or "HEAD")


def merge_base(repo, a, b):
    out = git(repo, "merge-base", a, b)
    if not out:
        raise Fail("{} and {} share no history in {}".format(a, b, repo))
    return out.splitlines()[0]


# ------------------------------------------------------------------ the change
def fingerprint(repo, base, tip):
    """SHA-256 over the sorted records <path> TAB <old mode> TAB <new mode> TAB <old blob>
    TAB <new blob>, one per changed path, each ended by NUL (git paths cannot hold NUL, so
    the encoding is unambiguous). None when nothing changed."""
    records = [b"\t".join(r) for r in raw_records(repo, base, tip)]
    if not records:
        return None
    digest = hashlib.sha256()
    for record in sorted(records):
        digest.update(record + b"\0")
    return digest.hexdigest()


def raw_records(repo, base, tip):
    """The changed paths of base..tip as (path, old mode, new mode, old blob, new blob) byte
    tuples, from the raw diff both the fingerprint and the patch read."""
    out = git(repo, *DIFF_RAW, base, tip, "--", raw=True)
    if out is None:
        raise Fail("cannot diff {}..{} in {}".format(base, tip, repo))
    fields, records, i = out.split(b"\0"), [], 0
    while i + 1 < len(fields) and fields[i]:
        meta = fields[i][1:].split(b" ")
        if not fields[i].startswith(b":") or len(meta) != 5 or meta[4][:1] in (b"R", b"C"):
            raise Fail("unexpected raw diff output for {}..{}".format(base, tip))
        old_mode, new_mode, old_blob, new_blob = meta[:4]
        records.append((fields[i + 1], old_mode, new_mode, old_blob, new_blob))
        i += 2
    return records


def has_nul(repo, blobs):
    """The subset of blobs whose content holds a NUL byte, from one `git cat-file --batch`."""
    blobs = sorted(set(blobs))
    if not blobs:
        return set()
    try:
        p = subprocess.run(["git", "-C", repo, "cat-file", "--batch"], capture_output=True,
                           input=b"".join(b + b"\n" for b in blobs), timeout=CALL_TIMEOUT,
                           env=git_env())
    except (OSError, subprocess.TimeoutExpired):
        raise Fail("cannot read blobs in {}".format(repo))
    if p.returncode != 0:
        raise Fail("cannot read blobs in {}".format(repo))
    out, pos, found = p.stdout, 0, set()
    for blob in blobs:
        end = out.find(b"\n", pos)
        head = out[pos:end].split(b" ") if end >= 0 else []
        if len(head) != 3 or head[0] != blob or head[1] != b"blob":
            raise Fail("cannot read blob {} in {}".format(blob.decode("ascii", "replace"), repo))
        size = int(head[2])
        if b"\0" in out[end + 1:end + 1 + size]:
            found.add(blob)
        pos = end + 1 + size + 1
    return found


def patch(repo, base, tip):
    """The change base..tip as a patch the reviewer can read in full. Binary is decided by the
    content, never by gitattributes (a path marked -diff would otherwise show only a "Binary
    files differ" line for text the fingerprint binds): a path whose old or new blob holds a NUL
    byte gets one summary line after the text patch,
    `Binary file <path>: <old mode> <old blob> -> <new mode> <new blob>`, with the path quoted
    as git quotes a header path (see quote_path), so a file name cannot forge a line. Every
    other path is rendered by one `git diff --text` over the whole range with the fingerprint's
    own flags, the binary paths excluded as literal top-level pathspecs. The output never holds
    a NUL byte (a blob with a NUL anywhere, not only in git's first 8000 bytes, is summarized).
    The number of `diff --git` headers must equal the number the text records call for: one
    each, two for a change between a regular file, a symlink or a gitlink (git renders that as
    a delete and a create). Otherwise the packet does not match the fingerprint and Fail is
    raised. Raises Fail when git cannot diff it."""
    records = sorted(raw_records(repo, base, tip))
    want = set()
    for _path, old_mode, new_mode, old_blob, new_blob in records:
        if old_mode != b"160000" and old_blob.strip(b"0"):
            want.add(old_blob)
        if new_mode != b"160000" and new_blob.strip(b"0"):
            want.add(new_blob)
    binary = has_nul(repo, want)
    texts, skip, lines = 0, [], []
    for path, old_mode, new_mode, old_blob, new_blob in records:
        if old_blob in binary or new_blob in binary:
            skip.append(b":(top,exclude,literal)" + path)
            lines.append(b"Binary file " + quote_path(path) + b": " + old_mode + b" " + old_blob
                         + b" -> " + new_mode + b" " + new_blob + b"\n")
        else:
            both = old_mode != b"000000" and new_mode != b"000000"
            texts += 2 if both and old_mode[:2] != new_mode[:2] else 1
    out = b""
    if texts:
        pathspec = ["--", ":(top)"] + skip if skip else []
        out = git(repo, *(DIFF_PATCH + ["--text", base, tip] + pathspec), raw=True)
        if out is None:
            raise Fail("cannot diff {}..{} in {}".format(base, tip, repo))
    headers = sum(1 for line in out.split(b"\n") if line.startswith(b"diff --git "))
    if headers != texts:
        raise Fail("the review packet does not match the change: {} diffs expected, {} found, "
                   "for {}..{} in {}".format(texts, headers, base, tip, repo))
    return out + b"".join(lines)


def quote_path(path):
    """path as git quotes it in a header under its default core.quotePath: when it holds a
    control character, DEL, a byte of 0x80 or more, a double quote or a backslash, it is in
    double quotes with \\a \\b \\t \\n \\v \\f \\r \\" \\\\ and three-digit octal for the rest;
    any other path as it is."""
    if not any(c < 0x20 or c >= 0x7f or c in b'"\\' for c in path):
        return path
    names = {0x07: b"\\a", 0x08: b"\\b", 0x09: b"\\t", 0x0a: b"\\n", 0x0b: b"\\v",
             0x0c: b"\\f", 0x0d: b"\\r", 0x22: b'\\"', 0x5c: b"\\\\"}
    return b'"' + b"".join(names.get(c) or (b"\\%03o" % c if c < 0x20 or c >= 0x7f else
                                            bytes([c])) for c in path) + b'"'


def branch_of(repo, right):
    """The branch a range's right side names: the current branch for HEAD, a local branch,
    or the branch of an origin/<b> remote-tracking ref; None for anything else."""
    if right in ("HEAD", "@"):
        return current_branch(repo)
    if has_ref(repo, "refs/heads/" + right):
        return right
    if right.startswith("origin/") and has_ref(repo, "refs/remotes/" + right):
        return right[len("origin/"):]
    return None


def normalize(repo, rng):
    """One review target for rng (<left>..<tip> or <left>...<tip>). A left side naming a
    branch (X, or origin/X) is normalized: dest is X, dest_ref the ref as written, base the
    merge-base of dest_ref and the tip, and the target is full. Any other left side keeps its
    literal base in both forms (spec 3.1), has no dest, and is partial; the packet shows
    exactly base..tip, so the reviewed diff and the record always agree."""
    for dots in ("...", ".."):
        if dots in rng:
            left, right = rng.split(dots, 1)
            break
    else:
        raise Fail("a review range is <base>..<tip> or <base>...<tip>, not {}".format(rng))
    left, right = left or "HEAD", right or "HEAD"
    common = common_dir(repo)
    tip = commit_of(repo, right)
    if tip is None:
        raise Fail("cannot resolve {} in {}".format(right, repo))
    dest = dest_ref = full_ref = None
    if has_ref(repo, "refs/heads/" + left):
        dest, dest_ref, full_ref = left, left, "refs/heads/" + left
    elif left.startswith("origin/") and has_ref(repo, "refs/remotes/" + left):
        dest, dest_ref, full_ref = left[len("origin/"):], left, "refs/remotes/" + left
    if full_ref is not None:
        base = merge_base(repo, full_ref, tip)
    else:
        base = commit_of(repo, left)
        if base is None:
            raise Fail("cannot resolve {} in {}".format(left, repo))
    return {"repo": common, "dest": dest, "dest_ref": dest_ref,
            "branch": branch_of(repo, right), "range": rng, "base": base, "tip": tip,
            "full": dest is not None, "fingerprint": fingerprint(repo, base, tip)}


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


# Reviews are ordered by comparing dispatched_at as strings, so only now()'s format is kept.
AT_FORMAT = re.compile(r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z\Z")


# ------------------------------------------------------------------ the ledger
def state_home():
    return os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"),
                                                             ".local", "state")


def ledger_key(common):
    return hashlib.sha256(common.encode("utf-8", "surrogateescape")).hexdigest()


def ledger_file(common):
    return os.path.join(state_home(), "xreview", "ledgers", ledger_key(common), "reviews.jsonl")


# ------------------------------------------------------------------ the command line
def main(argv):
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "key" and len(args) == 1:
            print(ledger_key(args[0]))
            return 0
        if cmd == "path" and len(args) == 1:
            print(ledger_file(common_dir(args[0])))
            return 0
        if cmd == "default-branch" and len(args) == 1:
            common_dir(args[0])
            print(default_branch(args[0]))
            return 0
        if cmd == "default-range" and len(args) == 1:
            common_dir(args[0])
            print(default_range(args[0]))
            return 0
        if cmd == "fingerprint" and len(args) == 3:
            change = fingerprint(*args)
            if change is None:
                return 3
            print(change)
            return 0
        if cmd == "diff" and len(args) == 3:
            sys.stdout.flush()
            sys.stdout.buffer.write(patch(*args))
            return 0
        if cmd == "normalize" and len(args) == 2:
            print(json.dumps(normalize(args[0], args[1]), separators=(",", ":")))
            return 0
        if cmd == "now" and not args:
            print(now())
            return 0
    except (Fail, OSError) as e:
        print("xreview-ledger: {}".format(e), file=sys.stderr)
        return 1
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 5: Allowlist the helper.** Apply this to `.chezmoiignore`. A file under `.claude/`
  is never deployed without its own `!` entry.

Edit 1 - replace:

```text
!.claude/xreview-guard.sh
```

with:

```text
!.claude/xreview-guard.sh
!.claude/xreview-ledger.py
```

- [ ] **Step 6: Run both and confirm they pass.**
  - `./tests/xreview-ledger.test.sh`: expect `passed: 83  failed: 0`.
  - `./tests/claude-settings.test.sh 2>&1 | tail -1`: expect `RESULT: 177 passed, 0 failed`.

- [ ] **Step 7: Commit.** Check that `git branch --show-current` prints
  `feat/xreview-receipt-binding`, then:

```bash
git add dot_claude/xreview-ledger.py tests/xreview-ledger.test.sh .chezmoiignore tests/claude-settings.test.sh
git commit -m "Add the xreview ledger helper: range normalization and the change fingerprint"
```

## Task 2: The ledger helper: locked, idempotent appends

**Files:**
- Modify: `dot_claude/xreview-ledger.py`
- Modify: `tests/xreview-ledger.test.sh`

**Interfaces:**
- Consumes (Task 1): `common_dir`, `ledger_file`, `state_home`, `git`, `Fail`.
- Produces:
  - `legacy_file(repo) -> str | None`: the per-checkout v1 file,
    `$XDG_STATE_HOME/xreview/<toplevel with / mapped to _, the leading _ dropped>/reviews.jsonl`.
  - `read_entries(path) -> list[dict]`: skips damaged lines; raises `OSError` when unreadable.
  - The lock, `<ledger>.lock`:
    - `owner_of(lock) -> str | None` and `stale(path) -> bool`;
    - `check_break_lock(guard)`: raises `Fail` when the break lock is older than 60 s,
      naming it: `remove it by hand (rmdir <guard>)`. Nothing removes it automatically;
    - `break_stale(lock, seen) -> bool`: under `<lock>.break`, removes the lock only while it
      is stale and still carries the token `seen`. It returns `False` while another writer
      holds the break lock, and raises through `check_break_lock` when that one is stale;
    - `acquire(lock) -> str`: returns this holder's token, and fails at once while a stale
      break lock stands. `XREVIEW_LEDGER_LOCK_WAIT` overrides the 5 s wait;
    - `release(lock, token)`: under `<lock>.break`, removes the lock only while it carries
      `token`. When it cannot take the break lock within the wait, or finds it stale, it
      leaves the lock and warns on stderr, naming a stale break lock;
    - `RELEASE_PAUSE`: `None`, or a function a test sets; `release` calls it between its
      token check and the removal.
  - `append(common: str, entry: dict) -> "appended" | "present"`. It raises `Fail` unless the
    entry is v2 with kind `pending` or `receipt`, a nonce, a `dispatched_at`, and a non-empty
    `targets` list whose every `repo` is `common`.
  - `show(repo) -> bool`.
  - Command line: `append COMMON_DIR ENTRY_JSON` prints `appended` or `present`;
    `show REPO` prints the ledger, then the legacy file, and exits 1 when neither exists.

- [ ] **Step 1: Write the failing test.** Insert this block into `tests/xreview-ledger.test.sh`
  immediately above the line `printf '\npassed: %d  failed: %d\n' "$pass" "$fail"`:

```bash
echo "E. appends are locked and idempotent (spec 3.2, 3.3)"
E="$ROOT/app"; mkrepo "$E"
EC="$(L normalize "$E" HEAD..HEAD | jq -r .repo)"
EF="$(L path "$E")"
# entry <kind> <nonce> [repo]: a minimal v2 entry for the ledger of <repo> (default: E's).
entry() {
  jq -nc --arg k "$1" --arg n "$2" --arg r "${3:-$EC}" \
    '{v:2,kind:$k,nonce:$n,dispatched_at:"2026-10-02T10:00:00.000000Z",checkpoint:"pre-merge",
      targets:[{repo:$r,dest:"main",full:true,fingerprint:"f"}]}'
}
is "E1 a pending entry is appended" "$(L append "$EC" "$(entry pending xr-1)")" appended
is "E2 the ledger directory names its repository" "$(cat "$(dirname "$EF")/repo")" "$EC"
is "E3 the same pending again is already present" "$(L append "$EC" "$(entry pending xr-1)")" present
is "E4 its receipt is appended" "$(L append "$EC" "$(entry receipt xr-1)")" appended
is "E5 a second receipt for that nonce is not" "$(L append "$EC" "$(entry receipt xr-1)")" present
is "E6 so the ledger holds two lines" "$(wc -l < "$EF" | tr -d ' ')" 2
out="$(L append "$EC" "$(entry receipt xr-2 /elsewhere/.git)" 2>&1)"; rc=$?
is "E7 an entry whose target is another repository is refused" "$rc/$(printf '%s' "$out" | grep -c 'not a v2 ledger entry')" "1/1"
out="$(L append "$EC" '{"branch":"main","verdict":"approve"}' 2>&1)"; rc=$?
is "E8 a v1-shaped entry is refused" "$rc" 1
P="$ROOT/par"; mkrepo "$P"; PC="$(L normalize "$P" HEAD..HEAD | jq -r .repo)"; PF="$(L path "$P")"
for i in $(seq 1 20); do L append "$PC" "$(entry pending "xr-par-$i" "$PC")" >/dev/null & done
wait
is "E9 20 concurrent appends produce 20 lines" "$(wc -l < "$PF" | tr -d ' ')" 20
is "E10 every one of them valid JSON" "$(jq -c . < "$PF" 2>/dev/null | wc -l | tr -d ' ')" 20
is "E11 with 20 distinct nonces" "$(jq -r .nonce < "$PF" | sort -u | wc -l | tr -d ' ')" 20
is "E12 and no lock left behind" "$([ -e "$PF.lock" ] && echo held || echo free)" free
mkdir "$PF.lock"
out="$(XREVIEW_LEDGER_LOCK_WAIT=0.3 L append "$PC" "$(entry pending xr-held "$PC")" 2>&1)"; rc=$?
is "E13 a held lock refuses at the bound" "$rc/$(printf '%s' "$out" | grep -c 'is held')" "1/1"
is "E14 and appends nothing" "$(grep -c xr-held "$PF")" 0
is "E15 a fresh lock is never broken" "$([ -d "$PF.lock" ] && echo held || echo free)" held
/usr/bin/python3 -c 'import os,sys,time; t=time.time()-120; os.utime(sys.argv[1],(t,t))' "$PF.lock"
is "E16 a stale lock is broken" "$(XREVIEW_LEDGER_LOCK_WAIT=0.3 L append "$PC" "$(entry pending xr-stale "$PC")")" appended
is "E17 and released" "$([ -e "$PF.lock" ] && echo held || echo free)" free
L_SHOW="$(L show "$E")"; rc=$?
is "E18 show lists the ledger" "$rc/$(printf '%s\n' "$L_SHOW" | grep -c '"nonce":"xr-1"')" "0/2"
LEG="$XDG_STATE_HOME/xreview/$(printf '%s' "$(git -C "$E" rev-parse --show-toplevel)" | tr '/' '_' | sed 's/^_//')"
mkdir -p "$LEG" && printf '{"branch":"main","checkpoint":"pre-merge","verdict":"approve"}\n' > "$LEG/reviews.jsonl"
is "E19 and then the checkout's legacy receipts" "$(L show "$E" | tail -1 | jq -r .branch)" main
out="$(L show "$D")"; rc=$?
is "E20 with nothing on record it exits 1" "$rc/$out" "1/"
# Two writers both find the same stale lock. Breaker A judges it stale and is suspended;
# breaker B breaks it, takes a fresh lock and still holds it when A resumes. The steps run in
# this order, deterministically, through the module's own functions: no sleeps, no races.
LK="$ROOT/interleave.lock"
lines="$(/usr/bin/python3 - "$LEDGER" "$LK" <<'PY'
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1])
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)
lock, old = sys.argv[2], time.time() - 120

def stale_lock(token):
    os.mkdir(lock)
    with open(os.path.join(lock, "owner"), "w") as fh:
        fh.write(token + "\n")
    os.utime(lock, (old, old))

stale_lock("dead")
seen_by_a = ledger.owner_of(lock)                       # A: "dead", and stale
print("a-saw-stale", seen_by_a, ledger.stale(lock))
token_b = ledger.acquire(lock)                          # B: breaks it, takes a fresh lock
print("b-holds", ledger.owner_of(lock) == token_b)
os.utime(lock, (old, old))      # and is slow: its lock looks stale too, so only the token tells

print("a-breaks", ledger.break_stale(lock, seen_by_a))  # A resumes: the token moved on
print("b-still-holds", ledger.owner_of(lock) == token_b)
ledger.release(lock, "not-the-holder")
print("foreign-release-kept", os.path.isdir(lock))
ledger.release(lock, token_b)
print("own-release-freed", os.path.isdir(lock))
stale_lock("dead2")
os.mkdir(lock + ".break")                               # a writer died holding the break lock
os.utime(lock + ".break", (old, old))
try:
    print("stale-break-lock", "broken", ledger.break_stale(lock, "dead2"))
except ledger.Fail as e:
    print("stale-break-lock", "failed", ("rmdir " + lock + ".break") in str(e))
print("both-left", os.path.isdir(lock + ".break"), os.path.isdir(lock))
os.rmdir(lock + ".break")                               # removed by hand
print("then-broken", ledger.break_stale(lock, "dead2"), os.path.isdir(lock))
stale_lock("dead3")
os.mkdir(lock + ".break")                               # another writer is breaking right now
print("fresh-break-lock-waits", ledger.break_stale(lock, "dead3"), os.path.isdir(lock))
PY
)"
is "E21 breaker A first judges the lock stale" "$(printf '%s\n' "$lines" | grep -c '^a-saw-stale dead True$')" 1
is "E22 breaker B breaks it and holds a fresh lock" "$(printf '%s\n' "$lines" | grep -c '^b-holds True$')" 1
is "E23 A, resuming, never removes B's lock" "$(printf '%s\n' "$lines" | grep -c '^a-breaks False$')" 1
is "E24 B still holds it" "$(printf '%s\n' "$lines" | grep -c '^b-still-holds True$')" 1
is "E25 a release by another token leaves the lock" "$(printf '%s\n' "$lines" | grep -c '^foreign-release-kept True$')" 1
is "E26 B's own release frees it" "$(printf '%s\n' "$lines" | grep -c '^own-release-freed False$')" 1
is "E27 a stale break lock is never removed: breaking fails, naming it to remove by hand" "$(printf '%s\n' "$lines" | grep -c '^stale-break-lock failed True$')" 1
is "E28 both locks are left; removed by hand, the stale lock is then broken" \
   "$(printf '%s\n' "$lines" | grep -c -E '^(both-left True True|then-broken True False)$')" 2
is "E29 a fresh break lock means another breaker is deciding: wait" "$(printf '%s\n' "$lines" | grep -c '^fresh-break-lock-waits False True$')" 1
# A release checks its token and is suspended (the module's test seam) while B, finding A's
# lock stale, tries to break it and take its own. The release holds the break lock, so B must
# wait, and A then removes only its own lock. A release that cannot take the break lock in
# time, or finds it stale, leaves the lock and warns.
LR="$ROOT/release.lock"
lines="$(XREVIEW_LEDGER_LOCK_WAIT=0.2 /usr/bin/python3 - "$LEDGER" "$LR" <<'PY'
import contextlib, importlib.util, io, os, sys, time
spec = importlib.util.spec_from_file_location("ledger", sys.argv[1])
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)
lock, old = sys.argv[2], time.time() - 120
token_a = ledger.acquire(lock)
os.utime(lock, (old, old))                    # A is slow: its lock looks stale to B
seen = []

def b_breaks_in():
    try:
        seen.append(("b-acquired", ledger.acquire(lock)))
    except ledger.Fail:
        seen.append(("b-waited", None))

ledger.RELEASE_PAUSE = b_breaks_in
ledger.release(lock, token_a)
ledger.RELEASE_PAUSE = None
print("b-during-release", seen[0][0])
print("release-freed", os.path.isdir(lock), os.path.isdir(lock + ".break"))
token_c = ledger.acquire(lock)
os.mkdir(lock + ".break")                     # a breaker is deciding right now
err = io.StringIO()
with contextlib.redirect_stderr(err):
    ledger.release(lock, token_c)
print("blocked-release-kept", ledger.owner_of(lock) == token_c, "could not take" in err.getvalue())
os.utime(lock + ".break", (old, old))         # that breaker died holding the break lock
err = io.StringIO()
with contextlib.redirect_stderr(err):
    ledger.release(lock, token_c)
print("stale-break-release-kept", ledger.owner_of(lock) == token_c, os.path.isdir(lock + ".break"),
      ("rmdir " + lock + ".break") in err.getvalue())
PY
)"
is "E30 a release holds the break lock: a breaker arriving mid-release waits" "$(printf '%s\n' "$lines" | grep -c '^b-during-release b-waited$')" 1
is "E31 and the release frees its own lock and the break lock" "$(printf '%s\n' "$lines" | grep -c '^release-freed False False$')" 1
is "E32 a release that cannot take the break lock leaves the lock and warns" "$(printf '%s\n' "$lines" | grep -c '^blocked-release-kept True True$')" 1
is "E33 one that finds it stale leaves both, and warns naming it" "$(printf '%s\n' "$lines" | grep -c '^stale-break-release-kept True True True$')" 1
# A writer that died holding the break lock stops every append until it is removed by hand.
mkdir "$PF.lock.break"
/usr/bin/python3 -c 'import os,sys,time; t=time.time()-120; os.utime(sys.argv[1],(t,t))' "$PF.lock.break"
out="$(L append "$PC" "$(entry pending xr-stuck "$PC")" 2>&1)"; rc=$?
is "E34 a stale break lock: an append fails closed, naming it to remove by hand" \
   "$rc/$(printf '%s' "$out" | grep -c -F "remove it by hand (rmdir $PF.lock.break)")" "1/1"
is "E35 it appends nothing and leaves the break lock" "$(grep -c xr-stuck "$PF")/$([ -d "$PF.lock.break" ] && echo kept || echo gone)" "0/kept"
rmdir "$PF.lock.break"
is "E36 removed by hand, appends go through again" "$(L append "$PC" "$(entry pending xr-stuck "$PC")")" appended

```

- [ ] **Step 2: Run it and confirm it fails.** `./tests/xreview-ledger.test.sh`: expect
  `passed: 85  failed: 34`. E1-E11, E13-E16 and E18-E36 fail, because `append`, `show` and
  the lock functions do not exist yet.

- [ ] **Step 3: Add the writes.** In `dot_claude/xreview-ledger.py`, insert this block
  immediately above the line
  `# ------------------------------------------------------------------ the command line`:

```python
def legacy_file(repo):
    """The per-checkout v1 receipt file of the checkout repo is in (keyed by its top-level
    path, / mapped to _), or None outside a work tree."""
    top = git(repo, "rev-parse", "--show-toplevel")
    if not top:
        return None
    key = top.replace("/", "_")
    return os.path.join(state_home(), "xreview", key[1:] if key.startswith("_") else key,
                        "reviews.jsonl")


def read_entries(path):
    """The JSON objects on record in path, one per line. A damaged line is skipped, as jq's
    fromjson? skips it. Raises OSError when the file cannot be read."""
    entries = []
    with open(path, "rb") as fh:
        for line in fh:
            try:
                entry = json.loads(line.decode("utf-8"))
            except ValueError:
                continue
            if isinstance(entry, dict):
                entries.append(entry)
    return entries


def lock_wait():
    try:
        return float(os.environ.get("XREVIEW_LEDGER_LOCK_WAIT", LOCK_WAIT))
    except ValueError:
        return LOCK_WAIT


# The ledger lock is a directory (mkdir is atomic, and macOS has no flock(1)) holding one file,
# owner, with its holder's unique token. A lock older than LOCK_STALE was left by a crashed
# writer. Breaking it is serialized by a second directory, <lock>.break, and only removes a
# lock that still carries the token seen when it was judged stale: two writers that both saw
# it stale can never remove the fresh lock one of them took in between. A release removes the
# lock only while it carries the releaser's own token, checked and removed under the same
# break lock, so a breaker cannot slip in between the check and the removal.
#
# The break lock is held only for those few steps, and is never broken automatically: two
# writers that both judged it stale could each remove it and then each break or release
# under a break lock of its own. One older than LOCK_STALE means a writer died holding it, so
# every writer fails closed, naming it, until it is removed by hand.
def owner_of(lock):
    try:
        with open(os.path.join(lock, "owner"), encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def stale(path):
    try:
        return time.time() - os.stat(path).st_mtime > LOCK_STALE
    except FileNotFoundError:
        return False


def check_break_lock(guard):
    """Fail when the break lock guard is stale: a writer died holding it, and only a person
    may remove it."""
    if stale(guard):
        raise Fail("the break lock {0} is older than {1:.0f} s: a writer died holding it, and "
                   "it is never removed automatically. Check that no xreview is running, "
                   "remove it by hand (rmdir {0}), then retry".format(guard, LOCK_STALE))


def break_stale(lock, seen):
    """Remove lock if it is still stale and still carries the token seen (None: no owner
    file). Returns True when it removed the lock, False when it did not or another writer
    holds the break lock. Raises Fail when the break lock is stale."""
    guard = lock + ".break"
    try:
        os.mkdir(guard)
    except FileExistsError:
        check_break_lock(guard)
        return False
    try:
        if owner_of(lock) != seen or not stale(lock):
            return False
        try:
            os.unlink(os.path.join(lock, "owner"))
        except OSError:
            pass
        try:
            os.rmdir(lock)
        except OSError:
            return False
        return True
    finally:
        try:
            os.rmdir(guard)
        except OSError:
            pass


def acquire(lock):
    """Take the ledger lock, waiting up to lock_wait(); returns this holder's token. Fails at
    once while a stale break lock stands."""
    token = "{}-{}".format(os.getpid(), uuid.uuid4().hex)
    deadline = time.monotonic() + lock_wait()
    while True:
        check_break_lock(lock + ".break")
        try:
            os.mkdir(lock)
        except FileExistsError:
            seen = owner_of(lock)
            if stale(lock) and break_stale(lock, seen):
                continue
            if time.monotonic() >= deadline:
                raise Fail("the ledger lock {} is held".format(lock))
            time.sleep(0.05)
            continue
        with open(os.path.join(lock, "owner"), "w", encoding="utf-8") as fh:
            fh.write(token + "\n")
        return token


RELEASE_PAUSE = None    # a test seam: called between a release's token check and its removal


def release(lock, token):
    """Remove the lock, only while it carries token. The check and the removal run under
    <lock>.break, the breakers' own lock, so no breaker can replace the lock in between. A
    release that cannot take the break lock in time, or finds it stale, leaves the lock and
    only warns."""
    guard = lock + ".break"
    deadline = time.monotonic() + lock_wait()
    while True:
        try:
            os.mkdir(guard)
            break
        except FileExistsError:
            pass
        try:
            check_break_lock(guard)
        except Fail as e:
            print("xreview-ledger: {}; {} is left in place".format(e, lock), file=sys.stderr)
            return
        if time.monotonic() >= deadline:
            print("xreview-ledger: could not take {} to release {}; it will be broken once "
                  "stale".format(guard, lock), file=sys.stderr)
            return
        time.sleep(0.05)
    try:
        if owner_of(lock) != token:
            return
        if RELEASE_PAUSE:
            RELEASE_PAUSE()
        try:
            os.unlink(os.path.join(lock, "owner"))
        except OSError:
            pass
        try:
            os.rmdir(lock)
        except OSError:
            pass
    finally:
        try:
            os.rmdir(guard)
        except OSError:
            pass


def append(common, entry):
    """Append one v2 entry to common's ledger, under its lock. Returns "appended", or
    "present" when the ledger already holds an entry of that kind for that nonce."""
    common = os.path.realpath(common)
    if not (isinstance(entry, dict) and entry.get("v") == 2
            and entry.get("kind") in ("pending", "receipt")
            and isinstance(entry.get("nonce"), str) and entry["nonce"]
            and isinstance(entry.get("dispatched_at"), str)
            and AT_FORMAT.match(entry["dispatched_at"])
            and isinstance(entry.get("targets"), list) and entry["targets"]
            and all(isinstance(t, dict) and t.get("repo") == common for t in entry["targets"])):
        raise Fail("not a v2 ledger entry for {}".format(common))
    path = ledger_file(common)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    note = os.path.join(os.path.dirname(path), "repo")
    if not os.path.exists(note):
        with open(note, "w", encoding="utf-8") as fh:
            fh.write(common + "\n")
    lock = path + ".lock"
    token = acquire(lock)
    try:
        if os.path.lexists(path):
            for held in read_entries(path):
                if (held.get("v") == 2 and held.get("nonce") == entry["nonce"]
                        and held.get("kind") == entry["kind"]):
                    return "present"
        line = (json.dumps(entry, separators=(",", ":")) + "\n").encode("utf-8")
        if os.path.lexists(path) and os.path.getsize(path) > 0:
            with open(path, "rb") as fh:
                fh.seek(-1, os.SEEK_END)
                if fh.read(1) != b"\n":
                    line = b"\n" + line
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            if os.write(fd, line) != len(line):
                raise Fail("a short write to {}".format(path))
        finally:
            os.close(fd)
        return "appended"
    finally:
        release(lock, token)


```

- [ ] **Step 4: Add the commands.** In the same file, replace everything from the line
  `# ------------------------------------------------------------------ the command line` to
  the end of the file with:

```python
# ------------------------------------------------------------------ the command line
def show(repo):
    """Print every line on record for repo: its ledger, then its checkout's legacy file.
    False when neither exists."""
    found = False
    for path in (ledger_file(common_dir(repo)), legacy_file(repo)):
        if path and os.path.exists(path):
            found = True
            with open(path, "rb") as fh:
                sys.stdout.write(fh.read().decode("utf-8", "replace"))
    return found


def main(argv):
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "key" and len(args) == 1:
            print(ledger_key(args[0]))
            return 0
        if cmd == "path" and len(args) == 1:
            print(ledger_file(common_dir(args[0])))
            return 0
        if cmd == "default-branch" and len(args) == 1:
            common_dir(args[0])
            print(default_branch(args[0]))
            return 0
        if cmd == "default-range" and len(args) == 1:
            common_dir(args[0])
            print(default_range(args[0]))
            return 0
        if cmd == "fingerprint" and len(args) == 3:
            change = fingerprint(*args)
            if change is None:
                return 3
            print(change)
            return 0
        if cmd == "diff" and len(args) == 3:
            sys.stdout.flush()
            sys.stdout.buffer.write(patch(*args))
            return 0
        if cmd == "normalize" and len(args) == 2:
            print(json.dumps(normalize(args[0], args[1]), separators=(",", ":")))
            return 0
        if cmd == "now" and not args:
            print(now())
            return 0
        if cmd == "append" and len(args) == 2:
            try:
                entry = json.loads(args[1])
            except ValueError:
                raise Fail("the entry is not JSON")
            print(append(args[0], entry))
            return 0
        if cmd == "show" and len(args) == 1:
            return 0 if show(args[0]) else 1
    except (Fail, OSError) as e:
        print("xreview-ledger: {}".format(e), file=sys.stderr)
        return 1
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 5: Run it and confirm it passes.** `./tests/xreview-ledger.test.sh`: expect
  `passed: 119  failed: 0`.

- [ ] **Step 6: Commit.** Check the branch, then:

```bash
git add dot_claude/xreview-ledger.py tests/xreview-ledger.test.sh
git commit -m "Lock and deduplicate xreview ledger appends"
```

## Task 3: The ledger helper: the gate's decision

**Files:**
- Modify: `dot_claude/xreview-ledger.py`
- Modify: `tests/xreview-ledger.test.sh`

**Interfaces:**
- Consumes (Tasks 1-2): `common_dir`, `commit_of`, `merge_base`, `fingerprint`,
  `ledger_file`, `legacy_file`, `read_entries`.
- Produces:
  - `states_of(entries, match) -> list[dict]`: each review's state, oldest dispatch first.
  - `describe(entry) -> str`: `<checkpoint>/<verdict or pending> <nonce> at <dispatched_at>`,
    or `<checkpoint>/<verdict> (v1, never opens the gate)`.
  - `branch_record(entries, branch) -> list[str]`.
  - `decide(repo, dest, dest_rev, tip, branch=None) -> dict` with the keys
    `allow: bool, reason: str` (no final period), `repo, dest, tip, base, fingerprint,
    on_record: list[str], on_record_branch: list[str]`.
  - Command line: `decide REPO DEST DEST_REV TIP [--branch NAME]` prints compact JSON and exits
    0 on allow, 1 on deny.
  - Reasons the guard and the tests match on:
    - `not inside a git repository (…)`;
    - `the head <tip> is not available locally; fetch it (git fetch origin), then retry`;
    - `the destination <dest> (<rev>) is not available locally; fetch it …`;
    - `the change is empty: …`;
    - `the review ledger <path> is unreadable (…)`;
    - `no full-range pre-merge review of this change is on record`;
    - `the latest review of this change is <describe>, not an approval`;
    - `approved by the pre-merge review <nonce>`.

- [ ] **Step 1: Write the failing test.** Insert this block into `tests/xreview-ledger.test.sh`
  immediately above the line `printf '\npassed: %d  failed: %d\n' "$pass" "$fail"`:

```bash
echo "F. the decision (spec 3.6)"
G="$ROOT/gate"; mkrepo "$G"
variant "$G" feature; printf 'f\n' > "$G/f.txt"; commit "$G" "feature"
git -C "$G" switch -q main
GT="$(L normalize "$G" main...feature)"
GC="$(printf '%s' "$GT" | jq -r .repo)"
# put <nonce> <kind> [verdict] [checkpoint] [target-json] [dispatched_at]: one entry in G's
# ledger; prints appended or present. A pending entry fixes its nonce's dispatch time (now,
# unless given), and the nonce's receipt reuses it.
put() {
  local at="${6:-}"
  if [ -z "$at" ]; then
    if [ "$2" = pending ]; then at="$(L now)"; else at="$(cat "$ROOT/at.$1")"; fi
  fi
  [ "$2" = pending ] && printf '%s' "$at" > "$ROOT/at.$1"
  L append "$GC" "$(jq -nc --arg n "$1" --arg k "$2" --arg v "${3:-}" --arg cp "${4:-pre-merge}" \
      --arg at "$at" --argjson t "${5:-$GT}" \
    '{v:2,kind:$k,nonce:$n,dispatched_at:$at,checkpoint:$cp,targets:[$t]}
     + (if $k == "receipt" then {verdict:$v,findings:0,thread:"t",turn:"u",tier:""} else {} end)')"
}
# gate [dest] [dest-rev] [tip]: allow or deny for tip landing on dest (default feature on main).
gate() { L decide "$G" "${1:-main}" "${2:-main}" "${3:-feature}" | jq -r 'if .allow then "allow" else "deny" end'; }
why() { L decide "$G" "${1:-main}" "${2:-main}" "${3:-feature}" --branch feature | jq -r .reason; }
is "F1 nothing on record denies" "$(gate)" deny
is "F2 saying so" "$(why)" "no full-range pre-merge review of this change is on record"
put r1 pending >/dev/null
is "F3 a pending review alone denies" "$(gate)" deny
put r1 receipt approve >/dev/null
is "F4 an approved full change allows" "$(gate)" allow
L decide "$G" main main feature >/dev/null; rc=$?
is "F5 decide exits 0 on allow" "$rc" 0
git -C "$G" branch release main
is "F6 the same change into another branch is denied" "$(gate release release)" deny
put r2 pending >/dev/null
is "F7 a newer pending review closes it" "$(gate)" deny
is "F8 and names it" "$(why | grep -c 'pre-merge/pending r2')" 1
L decide "$G" main main feature >/dev/null; rc=$?
is "F9 decide exits 1 on deny" "$rc" 1
put r2 receipt changes >/dev/null
is "F10 a later changes verdict closes it" "$(gate)" deny
put r3 pending >/dev/null; put r3 receipt approve >/dev/null
is "F11 a fresh approving round reopens it" "$(gate)" allow
is "F12 re-collecting a receipt appends nothing" "$(put r3 receipt approve)" present
OLDER="$(L now)"
put r4 pending >/dev/null; put r4 receipt changes >/dev/null
put r5 pending "" pre-merge "$GT" "$OLDER" >/dev/null; put r5 receipt approve >/dev/null
is "F13 an older review's approve collected after a newer changes does not reopen it" "$(gate)" deny
put r6 pending >/dev/null; put r6 receipt approve >/dev/null
is "F14 the latest dispatch decides, whatever the ledger order" "$(gate)" allow
put r7 pending >/dev/null
is "F15 a failed receipt write (its pending entry newest) leaves it closed" "$(gate)" deny
put r7 receipt approve >/dev/null
is "F16 until a later collect records the receipt" "$(gate)" allow
git -C "$G" switch -q feature; printf 'g\n' > "$G/g.txt"; commit "$G" "one extra commit"; git -C "$G" switch -q main
is "F17 one extra commit closes it" "$(gate)" deny
GT2="$(L normalize "$G" main...feature)"
PART="$(L normalize "$G" "$(git -C "$G" rev-parse main)..feature")"
put r8 pending "" pre-merge "$PART" >/dev/null; put r8 receipt approve pre-merge "$PART" >/dev/null
is "F18 a partial-range approve does not open it" "$(gate)" deny
put r9 pending "" spec "$GT2" >/dev/null; put r9 receipt approve spec "$GT2" >/dev/null
put r10 pending "" plan "$GT2" >/dev/null; put r10 receipt approve plan "$GT2" >/dev/null
is "F19 approved spec and plan reviews do not open it" "$(gate)" deny
LEGG="$XDG_STATE_HOME/xreview/$(printf '%s' "$(git -C "$G" rev-parse --show-toplevel)" | tr '/' '_' | sed 's/^_//')"
mkdir -p "$LEGG" && printf '{"branch":"feature","checkpoint":"pre-merge","verdict":"approve"}\n' > "$LEGG/reviews.jsonl"
is "F20 a v1 approve does not open it" "$(gate)" deny
rec="$(L decide "$G" main main feature --branch feature | jq -r '.on_record_branch | join("|")')"
is "F21 the branch record lists the v1 receipt" "$(printf '%s' "$rec" | grep -c 'pre-merge/approve (v1, never opens the gate)')" 1
is "F22 the spec review, full" "$(printf '%s' "$rec" | grep -c 'spec/approve r9 at [^ ]* (dest main, full,')" 1
is "F23 and the partial approve" "$(printf '%s' "$rec" | grep -c 'pre-merge/approve r8 at [^ ]* (dest none, partial,')" 1
put r11 pending "" pre-merge "$GT2" >/dev/null; put r11 receipt approve pre-merge "$GT2" >/dev/null
is "F24 a full-range approve of the new head opens it" "$(gate)" allow
AT="$(L now)"
put r12 pending "" pre-merge "$GT2" "$AT" >/dev/null; put r12 receipt approve pre-merge "$GT2" >/dev/null
put r13 pending "" pre-merge "$GT2" "$AT" >/dev/null
is "F25 a review dispatched in the same microsecond, later on record, wins the tie" "$(gate)" deny
put r13 receipt approve pre-merge "$GT2" >/dev/null
git -C "$G" switch -q -c moved main; printf 'm\n' > "$G/m.txt"; commit "$G" "main moves on, elsewhere"
git -C "$G" switch -q main; git -C "$G" merge -q --ff-only moved
git -C "$G" switch -q -c rebased feature; git -C "$G" rebase -q main; git -C "$G" switch -q main
is "F26 a rebased head with an unchanged fingerprint is allowed" "$(gate main main rebased)" allow
is "F27 an empty change is denied" "$(gate main main main)" deny
is "F28 saying so" "$(L decide "$G" main main main | jq -r .reason | grep -c '^the change is empty')" 1
is "F29 a head that is not available locally is denied" \
   "$(L decide "$G" main main 1234567890123456789012345678901234567890 | jq -r .reason | grep -c 'is not available locally; fetch it')" 1
is "F30 a destination that is not available locally is denied" \
   "$(L decide "$G" ghost refs/remotes/origin/ghost feature | jq -r .reason | grep -c '^the destination ghost')" 1
is "F31 outside a repository it is denied" \
   "$(L decide "$ROOT" main main feature | jq -r '"\(.allow) \(.reason)"' | grep -c '^false not inside a git repository')" 1
GF="$(L path "$G")"
chmod 000 "$GF"
is "F32 an unreadable ledger is denied" \
   "$(L decide "$G" main main rebased | jq -r '"\(.allow) \(.reason)"' | grep -c '^false the review ledger .* is unreadable')" 1
chmod 644 "$GF"
is "F33 readable again, it allows" "$(gate main main rebased)" allow

echo "G. repositories never share a ledger (spec 3.3, isolation)"
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"
for d in "$ROOT/iso/a_b" "$ROOT/iso/a/b"; do
  mkrepo "$d"; variant "$d" feature; printf 'same\n' > "$d/s.txt"; commit "$d" "same change"; git -C "$d" switch -q main
done
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
is "G1 the two repositories hold identical commits" "$(git -C "$ROOT/iso/a_b" rev-parse feature)" "$(git -C "$ROOT/iso/a/b" rev-parse feature)"
is "G2 their old per-checkout keys collide" \
   "$(printf '%s' "$ROOT/iso/a_b" | tr '/' '_')" "$(printf '%s' "$ROOT/iso/a/b" | tr '/' '_')"
differs "G3 their ledgers do not" "$(L path "$ROOT/iso/a_b")" "$(L path "$ROOT/iso/a/b")"
T="$(L normalize "$ROOT/iso/a_b" main...feature)"; C="$(printf '%s' "$T" | jq -r .repo)"
L append "$C" "$(jq -nc --argjson t "$T" '{v:2,kind:"pending",nonce:"xr-iso",dispatched_at:"2026-10-02T00:00:00.000000Z",checkpoint:"pre-merge",targets:[$t]}')" >/dev/null
L append "$C" "$(jq -nc --argjson t "$T" '{v:2,kind:"receipt",nonce:"xr-iso",dispatched_at:"2026-10-02T00:00:00.000000Z",checkpoint:"pre-merge",verdict:"approve",targets:[$t]}')" >/dev/null
is "G4 the approval opens a_b" "$(L decide "$ROOT/iso/a_b" main main feature | jq -r .allow)" true
is "G5 and never a/b, for identical blobs and destination" "$(L decide "$ROOT/iso/a/b" main main feature | jq -r .allow)" false

echo "H. a damaged ledger never lets the gate fail open"
D="$ROOT/dmg"; mkrepo "$D"
variant "$D" feature; printf 'd\n' > "$D/d.txt"; commit "$D" "feature"; git -C "$D" switch -q main
DT="$(L normalize "$D" main...feature)"; DC="$(printf '%s' "$DT" | jq -r .repo)"; DF="$(L path "$D")"
dentry() {
  jq -nc --arg k "$1" --arg n "$2" --argjson t "${3:-$DT}" --arg at "${4-$(L now)}" \
    '{v:2,kind:$k,nonce:$n,dispatched_at:$at,checkpoint:"pre-merge",targets:[$t]}
     + (if $k == "receipt" then {verdict:"approve",findings:0,thread:"t",turn:"u",tier:""} else {} end)'
}
DAT="$(L now)"
L append "$DC" "$(dentry pending r1 "$DT" "$DAT")" >/dev/null; L append "$DC" "$(dentry receipt r1 "$DT" "$DAT")" >/dev/null
is "H1 an approved change allows" "$(L decide "$D" main main feature | jq -r .allow)" true
printf '{"v":2,"kind":"receipt","nonce":"other","dispa' >> "$DF"
is "H2 a later pending entry is appended after a partial line" "$(L append "$DC" "$(dentry pending r2)")" appended
is "H3 it is readable" "$(grep -c '"nonce":"r2"' "$DF")" 1
is "H4 and it closes the gate" "$(L decide "$D" main main feature | jq -r .allow)" false
is "H5 on a line of its own" "$(grep -c '^{"v":2,"kind":"pending","nonce":"r2"' "$DF")" 1
before="$(wc -c < "$DF" | tr -d ' ')"
for bad in "2026-10-02T00:00:00Z" "" "x"; do
  out="$(L append "$DC" "$(dentry pending r3 "$DT" "$bad")" 2>&1)"; rc=$?
  is "H6 dispatched_at '$bad' is refused" "$rc/$(printf '%s' "$out" | grep -c 'not a v2 ledger entry')" "1/1"
done
is "H7 and nothing is appended" "$(wc -c < "$DF" | tr -d ' ')" "$before"
NUMT="$(printf '%s' "$DT" | jq -c '.fingerprint = 12345 | .branch = "numeric"')"
L append "$DC" "$(dentry pending r4 "$NUMT")" >/dev/null
out="$(L decide "$D" main main feature --branch numeric 2>&1)"; rc=$?
is "H8 a numeric fingerprint is no traceback" "$([ "$rc" -le 1 ] && printf '%s' "$out" | jq -e 'has("allow")' >/dev/null && ! printf '%s' "$out" | grep -q Traceback && echo ok)" ok
is "H9 and the branch record shows it" "$(printf '%s' "$out" | jq -r '.on_record_branch | join("|")' | grep -c 'pending r4')" 1

```

- [ ] **Step 2: Run it and confirm it fails.** `./tests/xreview-ledger.test.sh`: expect
  `passed: 130  failed: 38`. Every F and G decision fails, because `decide` is a usage error so
  far.

- [ ] **Step 3: Add the decision.** In `dot_claude/xreview-ledger.py`, insert this block
  immediately above the line
  `# ------------------------------------------------------------------ the command line`:

```python
# ------------------------------------------------------------------ the decision
def states_of(entries, match):
    """Each review's state - its receipt if one exists, otherwise its pending entry - for
    the v2 entries with a target that satisfies match, oldest dispatch first. Reviews
    dispatched in the same microsecond keep the order they reached the ledger."""
    first, state = {}, {}
    for index, entry in enumerate(entries):
        if entry.get("v") != 2 or entry.get("kind") not in ("pending", "receipt"):
            continue
        nonce, at = entry.get("nonce"), entry.get("dispatched_at")
        targets = entry.get("targets") if isinstance(entry.get("targets"), list) else []
        if not isinstance(nonce, str) or not isinstance(at, str):
            continue
        if not any(isinstance(t, dict) and match(t) for t in targets):
            continue
        first.setdefault(nonce, index)
        held = state.get(nonce)
        if held is None or (held["kind"] == "pending" and entry["kind"] == "receipt"):
            state[nonce] = entry
    return sorted(state.values(), key=lambda e: (e["dispatched_at"], first[e["nonce"]]))


def describe(entry):
    if entry.get("v") != 2:
        return "{}/{} (v1, never opens the gate)".format(entry.get("checkpoint") or "unrecorded",
                                                          entry.get("verdict") or "")
    state = entry.get("verdict") if entry.get("kind") == "receipt" else "pending"
    return "{}/{} {} at {}".format(entry.get("checkpoint"), state or "", entry.get("nonce"),
                                   entry.get("dispatched_at"))


def branch_record(entries, branch):
    """What is on record for a branch name: every v2 review with a target on that branch,
    then every v1 receipt naming it."""
    lines = []
    for entry in states_of(entries, lambda t: t.get("branch") == branch):
        target = next(t for t in entry["targets"]
                      if isinstance(t, dict) and t.get("branch") == branch)
        lines.append("{} (dest {}, {}, fingerprint {})".format(
            describe(entry), target.get("dest") or "none",
            "full" if target.get("full") is True else "partial",
            str(target.get("fingerprint") or "none")[:12]))
    lines.extend(describe(e) for e in entries if e.get("v") is None and e.get("branch") == branch)
    return lines


def decide(repo, dest, dest_rev, tip, branch=None):
    """The gate's decision for the change tip would land on dest, whose commit is dest_rev,
    in the repository repo is in. A dict: allow, reason (no final period), repo, dest, tip,
    base, fingerprint, on_record (this change's reviews) and on_record_branch."""
    out = {"allow": False, "reason": "", "repo": None, "dest": dest, "tip": None,
           "base": None, "fingerprint": None, "on_record": [], "on_record_branch": []}
    try:
        common = common_dir(repo)
    except Fail as e:
        out["reason"] = str(e)
        return out
    out["repo"] = common
    head = commit_of(repo, tip)
    if head is None:
        out["reason"] = ("the head {} is not available locally; fetch it (git fetch origin), "
                         "then retry".format(tip))
        return out
    out["tip"] = head
    target = commit_of(repo, dest_rev)
    if target is None:
        out["reason"] = ("the destination {} ({}) is not available locally; fetch it (git "
                         "fetch origin), then retry".format(dest, dest_rev))
        return out
    try:
        base = merge_base(repo, target, head)
        change = fingerprint(repo, base, head)
    except Fail as e:
        out["reason"] = str(e)
        return out
    out["base"], out["fingerprint"] = base, change
    if change is None:
        out["reason"] = "the change is empty: {} holds nothing that {} lacks".format(tip, dest)
        return out
    path = ledger_file(common)
    try:
        entries = read_entries(path) if os.path.lexists(path) else []
    except OSError as e:
        out["reason"] = "the review ledger {} is unreadable ({})".format(path, e.strerror or e)
        return out
    legacy = []
    old = legacy_file(repo)
    if old and os.path.exists(old):
        try:
            legacy = read_entries(old)
        except OSError:
            legacy = []
    reviews = states_of([e for e in entries if e.get("checkpoint") == "pre-merge"],
                        lambda t: (t.get("repo") == common and t.get("dest") == dest
                                   and t.get("full") is True and t.get("fingerprint") == change))
    out["on_record"] = [describe(e) for e in reviews]
    if branch:
        out["on_record_branch"] = branch_record(entries + legacy, branch)
    if reviews and reviews[-1]["kind"] == "receipt" and reviews[-1].get("verdict") == "approve":
        out["allow"] = True
        out["reason"] = "approved by the pre-merge review {}".format(reviews[-1]["nonce"])
    elif reviews:
        out["reason"] = "the latest review of this change is {}, not an approval".format(
            describe(reviews[-1]))
    else:
        out["reason"] = "no full-range pre-merge review of this change is on record"
    return out


```

- [ ] **Step 4: Add the command.** In the same file, replace everything from the line
  `# ------------------------------------------------------------------ the command line` to
  the end of the file with:

```python
# ------------------------------------------------------------------ the command line
def show(repo):
    """Print every line on record for repo: its ledger, then its checkout's legacy file.
    False when neither exists."""
    found = False
    for path in (ledger_file(common_dir(repo)), legacy_file(repo)):
        if path and os.path.exists(path):
            found = True
            with open(path, "rb") as fh:
                sys.stdout.write(fh.read().decode("utf-8", "replace"))
    return found


def main(argv):
    if not argv:
        print(USAGE, file=sys.stderr)
        return 2
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "key" and len(args) == 1:
            print(ledger_key(args[0]))
            return 0
        if cmd == "path" and len(args) == 1:
            print(ledger_file(common_dir(args[0])))
            return 0
        if cmd == "default-branch" and len(args) == 1:
            common_dir(args[0])
            print(default_branch(args[0]))
            return 0
        if cmd == "default-range" and len(args) == 1:
            common_dir(args[0])
            print(default_range(args[0]))
            return 0
        if cmd == "fingerprint" and len(args) == 3:
            change = fingerprint(*args)
            if change is None:
                return 3
            print(change)
            return 0
        if cmd == "diff" and len(args) == 3:
            sys.stdout.flush()
            sys.stdout.buffer.write(patch(*args))
            return 0
        if cmd == "normalize" and len(args) == 2:
            print(json.dumps(normalize(args[0], args[1]), separators=(",", ":")))
            return 0
        if cmd == "now" and not args:
            print(now())
            return 0
        if cmd == "append" and len(args) == 2:
            try:
                entry = json.loads(args[1])
            except ValueError:
                raise Fail("the entry is not JSON")
            print(append(args[0], entry))
            return 0
        if cmd == "show" and len(args) == 1:
            return 0 if show(args[0]) else 1
        if cmd == "decide" and (len(args) == 4 or (len(args) == 6 and args[4] == "--branch")):
            result = decide(args[0], args[1], args[2], args[3], args[5] if len(args) == 6 else None)
            print(json.dumps(result, separators=(",", ":")))
            return 0 if result["allow"] else 1
    except (Fail, OSError) as e:
        print("xreview-ledger: {}".format(e), file=sys.stderr)
        return 1
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 5: Run it and confirm it passes.** `./tests/xreview-ledger.test.sh`: expect
  `passed: 168  failed: 0`.

- [ ] **Step 6: Commit.** Check the branch, then:

```bash
git add dot_claude/xreview-ledger.py tests/xreview-ledger.test.sh
git commit -m "Decide the pre-merge gate from the latest review of the exact change"
```

## Task 4: xreview dispatch: targets, inline diffs, pending entries

**Files:**
- Modify: `dot_local/bin/executable_xreview`
- Modify: `tests/xreview.test.sh`

**Interfaces:**
- Consumes (Tasks 1-2): the helper's `normalize`, `diff`, `default-range`, `now` and `append`
  subcommands.
- Produces:
  - in xreview:
    - `ledger <subcommand> …`: runs `/usr/bin/python3 "${XREVIEW_LEDGER:-$HOME/.claude/xreview-ledger.py}"`;
    - `add_target <spec>`: appends to `cmd_dispatch`'s locals `TARGETS` (a JSON array),
      `DIFFS` and `DIFF_BYTES`. The packet diff is `ledger diff <dir> <base> <tip>`, the
      recorded pair, with the fingerprint's flags;
    - `record_pending <targets-doc>`: returns 1 on the first ledger it cannot write.
  - The file `$(state_dir)/turns/<nonce>.targets`, as one JSON line:
    `{"v":2,"nonce":…,"dispatched_at":…,"checkpoint":…,"targets":[…]}`.
  - The usage text `[--diff [<repo-path>:]<range>]...`.
  - New `die` messages:
    - `cannot diff <spec> - <dir> is not a directory`;
    - `cannot record the pending review in every target ledger; no review was started`;
    - `the diffs are too large to carry inline (<n> bytes, cap <m>).`;
    - `cannot name the current branch's default target; pass --diff <dest>...<branch>`.
  - Unchanged:
    - the turn record's format;
    - `cannot diff <spec> - check the range resolves in that repository`;
    - `cannot diff <spec> - the range is empty, so there is nothing to review`.

- [ ] **Step 1: Point the suite at the helper.** Apply this to `tests/xreview.test.sh`:

Edit 1 - replace:

```bash
XREVIEW="$SRC/dot_local/bin/executable_xreview"
[ -f "$XREVIEW" ] || { echo "missing CLI under test: $XREVIEW" >&2; exit 2; }
```

with:

```bash
XREVIEW="$SRC/dot_local/bin/executable_xreview"
LEDGER="$SRC/dot_claude/xreview-ledger.py"
for f in "$XREVIEW" "$LEDGER"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
```

Edit 2 - replace:

```bash
export XREVIEW_POLL_SECS=0.05 XREVIEW_PANE_WAIT=2
unset XREVIEW_MAX_ROUNDS XREVIEW_PANE XREVIEW_THREAD
```

with:

```bash
export XREVIEW_POLL_SECS=0.05 XREVIEW_PANE_WAIT=2 XREVIEW_LEDGER="$LEDGER"
unset XREVIEW_MAX_ROUNDS XREVIEW_PANE XREVIEW_THREAD XREVIEW_LEDGER_LOCK_WAIT
```

- [ ] **Step 2: Snapshot the ledger, and give F15 a real change.** Apply this to
  `tests/xreview.test.sh`. F15 used to review a branch identical to the default branch. A
  pre-merge review of an empty change is now refused, so the test gives `review-a` a change and
  names its range.

Edit 1 - replace:

```bash
  turn-start) cp "$input" "$P/packet"; [ -n "$known" ] && echo '[]' > "$known"
```

with:

```bash
  turn-start) cp "$input" "$P/packet"; [ -n "$known" ] && echo '[]' > "$known"
              # SNAP_LEDGER: keep a copy of that ledger as it stood when the turn started.
              [ -n "${SNAP_LEDGER:-}" ] && cp "$SNAP_LEDGER" "$P/ledger-at-start" 2>/dev/null
```

Edit 2 - replace:

```bash
        RPC_STATUS_FAIL_FOR RPC_STATUS_NOBOOL_FOR CODEX_CHILD XREVIEW_RUNG_WAIT GET_FAIL PROCINFO_BAD RPC_RESOLVE_RC PROCINFO_FG
```

with:

```bash
        RPC_STATUS_FAIL_FOR RPC_STATUS_NOBOOL_FOR CODEX_CHILD XREVIEW_RUNG_WAIT GET_FAIL PROCINFO_BAD RPC_RESOLVE_RC PROCINFO_FG \
        SNAP_LEDGER XREVIEW_LEDGER_LOCK_WAIT
```

Edit 3 - replace:

```bash
  rm -f "$P"/running.*
```

with:

```bash
  rm -f "$P"/running.* "$P/ledger-at-start"
```

Edit 4 - replace:

```bash
git checkout -q -b review-a
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge b.md 2>/dev/null)"
```

with:

```bash
git checkout -q -b review-a
printf 'a\n' > review-a.txt && git add review-a.txt && git commit -q -m "review-a's change"
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff "$BR...review-a" b.md 2>/dev/null)"
```

- [ ] **Step 3: Write the failing dispatch tests.** Insert this block into
  `tests/xreview.test.sh` immediately above the last two lines of the file. Those lines are
  `printf '\npassed: %d  failed: %d\n' "$pass" "$fail"` and `(( fail == 0 ))`. Leave one blank
  line before them.

```bash
echo "V. review targets and pending entries (spec 2026-10-02 §3.2-§3.4)"
# vrepo <dir>: a repository on main with one commit, and a branch, feature, one change ahead and
# checked out. Its own default branch is main, whatever this machine's git configuration says.
vrepo() {
  mkdir -p "$1" && git -C "$1" init -q -b main && git -C "$1" config user.email t@t \
    && git -C "$1" config user.name t && git -C "$1" config commit.gpgsign false
  printf 'one\n' > "$1/a.txt" && git -C "$1" add a.txt && git -C "$1" commit -q -m init
  git -C "$1" switch -q -c feature && printf 'two\n' >> "$1/a.txt" && git -C "$1" commit -q -am feature
  printf 'body\n' > "$1/b.md"
}
V="$ROOT/v-one"; vrepo "$V"
V2="$ROOT/v-two"; vrepo "$V2"
VCWD="$(git -C "$V" rev-parse --show-toplevel)"
VSTATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$VCWD" | tr '/' '_' | sed 's/^_//')"
VLEDGER="$(/usr/bin/python3 "$LEDGER" path "$V")"
V2LEDGER="$(/usr/bin/python3 "$LEDGER" path "$V2")"
targets_files() { find "$VSTATE/turns" -name '*.targets' 2>/dev/null | wc -l | tr -d ' '; }
cd "$V" || exit 1
fresh; export PANE_CWD="$VCWD"
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
is "V1 a plan dispatch with no --diff still works" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "V2 its targets file names no target" "$(jq -c .targets "$VSTATE/turns/$nonce.targets")" "[]"
is "V3 and it writes no ledger entry" "$([ -e "$VLEDGER" ] && echo written || echo none)" none
fresh; export PANE_CWD="$VCWD"
nonce="$(bash "$XREVIEW" dispatch --checkpoint spec b.md 2>/dev/null)"
is "V4 so does a spec dispatch" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
fresh; export PANE_CWD="$VCWD"
nonce="$(SNAP_LEDGER="$VLEDGER" bash "$XREVIEW" dispatch --checkpoint pre-merge b.md 2>/dev/null)"
is "V5 a pre-merge dispatch with no --diff targets the branch against the default branch" \
   "$(jq -r '.targets[0] | "\(.range) \(.dest) \(.branch) \(.full)"' "$VSTATE/turns/$nonce.targets")" \
   "main...feature main feature true"
is "V6 its targets file carries the nonce, the checkpoint and the dispatch time" \
   "$(jq -r '"\(.nonce) \(.checkpoint) \(.dispatched_at | test("^[0-9-]+T[0-9:]+\\.[0-9]{6}Z$"))"' "$VSTATE/turns/$nonce.targets")" \
   "$nonce pre-merge true"
is "V7 its pending entry was on record before the turn started" \
   "$(jq -r 'select(.kind == "pending") | .nonce' "$P/ledger-at-start" 2>/dev/null)" "$nonce"
is "V8 naming the same targets" \
   "$(jq -c --arg n "$nonce" 'select(.nonce == $n and .kind == "pending") | .targets' "$VLEDGER")" \
   "$(jq -c .targets "$VSTATE/turns/$nonce.targets")"
fresh; export PANE_CWD="$VCWD"
before="$(targets_files)"
mkdir "$VLEDGER.lock"   # another writer holds the ledger past the wait
out="$(XREVIEW_LEDGER_LOCK_WAIT=0.2 bash "$XREVIEW" dispatch --checkpoint pre-merge b.md 2>&1)"; rc=$?
is "V9 a pre-merge dispatch whose pending write fails is refused" \
   "$rc/$(printf '%s' "$out" | grep -c 'cannot record the pending review in every target ledger')" "1/1"
is "V10 before the pane or the reviewer is touched" "$(untouched)" yes
is "V11 with no nonce handed back" "$(printf '%s' "$out" | grep -c '^xr-')" 0
is "V12 and no targets file left behind" "$(targets_files)" "$before"
rmdir "$VLEDGER.lock"
fresh; export PANE_CWD="$VCWD"
git switch -q main
out="$(bash "$XREVIEW" dispatch --checkpoint pre-merge b.md 2>&1)"; rc=$?
is "V13 a pre-merge dispatch whose target is empty is refused" \
   "$rc/$(printf '%s' "$out" | grep -c 'nothing to review')" "1/1"
is "V14 untouched" "$(untouched)" yes
printf 'm\n' > m.txt && git add m.txt && git commit -q -m "main moves on"
git switch -q feature
fresh; export PANE_CWD="$VCWD"
bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main..feature b.md >/dev/null 2>&1
is "V15 main..feature is normalized: the packet carries the branch's own change" "$(grep -c '^+two$' "$P/packet")" 1
is "V16 and not main's later change, reversed" "$(grep -c 'm.txt' "$P/packet")" 0
git switch -q -c sub main
git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,lib
git commit -q -m "a gitlink"
git config diff.ignoreSubmodules all
fresh; export PANE_CWD="$VCWD"
bash "$XREVIEW" dispatch --checkpoint plan --diff main...sub b.md >/dev/null 2>&1
is "V17 the inlined diff shows a gitlink even with diff.ignoreSubmodules=all" \
   "$(grep -c '^+Subproject commit 1111111111111111111111111111111111111111$' "$P/packet")" 1
git config --unset diff.ignoreSubmodules
git switch -q feature
fresh; export PANE_CWD="$VCWD"
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff main...feature --diff "$V2:main...feature" b.md 2>/dev/null)"
is "V18 --diff repeats: both diffs travel in the packet" "$(grep -c '^--- diff (' "$P/packet")" 2
is "V19 the second labelled with its repository" "$(grep -cF -- "--- diff ($V2:main...feature) ---" "$P/packet")" 1
is "V20 one target per repository" \
   "$(jq -r '[.targets[].repo] | unique | length' "$VSTATE/turns/$nonce.targets")" 2
one="$(git -C "$V2" diff main...feature | wc -c | tr -d ' ')"
fresh; export PANE_CWD="$VCWD"
out="$(XREVIEW_MAX_DIFF_BYTES=$((one * 2 - 10)) bash "$XREVIEW" dispatch --checkpoint plan \
         --diff main...feature --diff "$V2:main...feature" b.md 2>&1)"
is "V21 the size cap binds the total of all the diffs" "$(printf '%s' "$out" | grep -c 'too large')" 1
is "V22 untouched" "$(untouched)" yes
fresh; export PANE_CWD="$VCWD"
out="$(bash "$XREVIEW" dispatch --checkpoint plan --diff "$ROOT/no-such:main...feature" b.md 2>&1)"; rc=$?
is "V23 a --diff naming no directory is refused" "$rc/$(printf '%s' "$out" | grep -c 'is not a directory')" "1/1"
# The packet shows every path and byte the fingerprint names, whatever the reviewed repository's
# configuration says: diff.relative with xreview run from a subdirectory, an external diff
# driver that prints nothing, and a textconv that rewrites content.
git switch -q -c hostile main
mkdir -p deep && printf 'in\n' > deep/in.txt && printf 'out\n' > out.txt
git add deep/in.txt out.txt && git commit -q -m "one file inside deep/, one outside"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/silent-diff"; chmod +x "$ROOT/silent-diff"
git config diff.relative true
git config diff.external "$ROOT/silent-diff"
git config diff.upper.textconv 'tr a-z A-Z'
printf '*.txt diff=upper\n' > .git/info/attributes
cd deep || exit 1
fresh; export PANE_CWD="$VCWD"
bash "$XREVIEW" dispatch --checkpoint plan --diff main...hostile ../b.md >/dev/null 2>&1
cd "$V" || exit 1
want="$(git diff --no-relative --no-renames --name-only main...hostile | sort | tr '\n' ' ')"
is "V24 from a subdirectory, under diff.relative, an external driver and a textconv, the packet holds every changed path" \
   "$(sed -n 's/^diff --git a\/\([^ ]*\) .*/\1/p' "$P/packet" | sort | tr '\n' ' ')" "$want"
is "V25 with the content as committed, never converted" "$(grep -c '^+in$' "$P/packet")" 1
git config --unset diff.relative; git config --unset diff.external; git config --unset diff.upper.textconv
rm .git/info/attributes
# A partial range keeps its literal base, and the packet shows exactly that base..tip: from a
# divergent commit, the commit's own file goes away.
git switch -q -c divergent main
printf 'd\n' > div.txt && git add div.txt && git commit -q -m divergent
DIV="$(git rev-parse HEAD)"
git switch -q feature
fresh; export PANE_CWD="$VCWD"
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff "$DIV...feature" b.md 2>/dev/null)"
is "V26 a divergent commit...branch is recorded with its literal base" \
   "$(jq -r '.targets[0] | "\(.base) \(.full)"' "$VSTATE/turns/$nonce.targets")" "$DIV false"
is "V27 and the packet shows that base..tip" "$(grep -c '^diff --git a/div.txt b/div.txt$' "$P/packet")" 1
cd "$ROOT/repo" || exit 1
unset PANE_CWD
```

- [ ] **Step 4: Run it and confirm it fails.** `./tests/xreview.test.sh` (timeout 600000 ms):
  expect `passed: 419  failed: 20`. The failures are V2, V5-V7, V9-V11, V13, V14, V16-V21
  and V23-V27.

- [ ] **Step 5: Implement.** Apply these edits to `dot_local/bin/executable_xreview`, in
  order:
  - Edit 1 adds the `ledger` helper.
  - Edit 2 adds `record_pending`.
  - Edit 3 replaces `inline_diff` with `add_target`, which renders the packet diff through
    `ledger diff`.
  - Edits 4-11 change `cmd_dispatch` and the usage line.

Edit 1 - replace:

```bash
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
```

with:

```bash
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

# The review ledger and the reviewed change's identity (spec 2026-10-02 §3.1-§3.3) live in one
# helper, shared with the pre-merge guard. It sits beside the guard in ~/.claude, which the
# sandbox cannot write; XREVIEW_LEDGER points the test suites at the source copy.
ledger() { /usr/bin/python3 "${XREVIEW_LEDGER:-$HOME/.claude/xreview-ledger.py}" "$@"; }
```

Edit 2 - replace:

```bash
    printf 'xreview: could not write the receipt for %s to %s/reviews.jsonl\n' "$2" "$dir" >&2
  fi
  return 0
}
```

with:

```bash
    printf 'xreview: could not write the receipt for %s to %s/reviews.jsonl\n' "$2" "$dir" >&2
  fi
  return 0
}

# record_pending <targets-doc> - spec 2026-10-02 §3.3: a pre-merge review puts a pending entry
# in every target repository's ledger before its turn starts, so every pre-merge review that
# runs is on record, and a newer review always shadows an older approval. Returns 1 at the
# first ledger it cannot write.
record_pending() {
  local repos repo entry
  repos="$(printf '%s' "$1" | jq -r '[.targets[].repo] | unique | .[]')" || return 1
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    entry="$(printf '%s' "$1" | jq -c --arg r "$repo" \
      '{v:2,kind:"pending",nonce,dispatched_at,checkpoint,targets:[.targets[] | select(.repo == $r)]}')" \
      || return 1
    ledger append "$repo" "$entry" >/dev/null || return 1
  done <<<"$repos"
  return 0
}
```

Edit 3 - replace:

```bash
# A dispatch that names a path makes the reviewer open it, and every search and read is a
# full-context model step (measured 2026-09-01: ~16 steps and ~2.0M tokens per review).
# Refuse an oversized diff rather than truncating it: a reviewer handed half a change reviews
# half a change and reports nothing on the rest, which reads as a clean review.
inline_diff() {
  local range="$1" out max
  max="${XREVIEW_MAX_DIFF_BYTES:-100000}"
  out="$(git diff "$range" 2>/dev/null)" \
    || die "cannot diff $range - check the range resolves in this repository"
  [ -n "$out" ] || die "cannot diff $range - the range is empty, so there is nothing to review"
  if [ "${#out}" -gt "$max" ]; then
    die "diff for $range is too large to carry inline (${#out} bytes, cap $max).
Review it in slices, or raise XREVIEW_MAX_DIFF_BYTES if the reviewer can hold it."
  fi
  printf '%s' "$out"
}
```

with:

```bash
# add_target <spec> - one --diff [<repo-path>:]<range> (spec 2026-10-02 §3.1, §3.4): normalized
# by the ledger helper, appended to cmd_dispatch's TARGETS, and its diff to DIFFS. The path is
# everything before the last colon, since a ref can never hold one. A dispatch that names a
# path makes the reviewer open it, and every search and read is a full-context model step
# (measured 2026-09-01: ~16 steps and ~2.0M tokens per review), so the diff travels inline.
# The diff is base..tip as recorded, rendered by the ledger helper with the fingerprint's own
# flags, so the reviewer reads every path and byte the receipt will name, whatever
# diff.relative, an external or textconv driver, or diff.ignoreSubmodules would do.
add_target() {
  local spec="$1" rdir rng t base tip d
  case "$spec" in
    *:*) rdir="${spec%:*}"; rng="${spec##*:}" ;;
    *)   rdir=.; rng="$spec" ;;
  esac
  [ -d "$rdir" ] || die "cannot diff $spec - $rdir is not a directory"
  t="$(ledger normalize "$rdir" "$rng")" \
    || die "cannot diff $spec - check the range resolves in that repository"
  base="$(printf '%s' "$t" | jq -r .base)"
  tip="$(printf '%s' "$t" | jq -r .tip)"
  d="$(ledger diff "$rdir" "$base" "$tip" 2>/dev/null)" \
    || die "cannot diff $spec - check the range resolves in that repository"
  [ -n "$d" ] || die "cannot diff $spec - the range is empty, so there is nothing to review"
  TARGETS="$(printf '%s' "$TARGETS" | jq -c --argjson t "$t" '. + [$t]')"
  DIFF_BYTES=$(( DIFF_BYTES + ${#d} ))
  DIFFS="$DIFFS$(printf '\n\n--- diff (%s) ---\n%s\n--- end diff ---' "$spec" "$d")"
}
```

Edit 4 - replace:

```bash
  local body_file diff_range="" diff_text="" dir pane proc thread nonce packet turn="" \
        need_resume checkpoint=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --diff) [ "$#" -ge 2 ] || die "--diff needs a range"; diff_range="$2"; shift 2 ;;
```

with:

```bash
  local body_file dir pane proc thread nonce packet turn="" need_resume checkpoint="" \
        specs=() spec cap dispatched doc
  # Filled by add_target, one entry per --diff.
  local TARGETS='[]' DIFFS="" DIFF_BYTES=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --diff) [ "$#" -ge 2 ] || die "--diff needs a range"; specs+=("$2"); shift 2 ;;
```

Edit 5 - replace:

```bash
  [ "$#" -eq 1 ] || die "usage: xreview dispatch --checkpoint spec|plan|pre-merge [--diff <range>] <body-file>"
```

with:

```bash
  [ "$#" -eq 1 ] || die "usage: xreview dispatch --checkpoint spec|plan|pre-merge [--diff [<repo-path>:]<range>]... <body-file>"
```

Edit 6 - replace:

```bash
    "") die "usage: xreview dispatch --checkpoint spec|plan|pre-merge [--diff <range>] <body-file>" ;;
```

with:

```bash
    "") die "usage: xreview dispatch --checkpoint spec|plan|pre-merge [--diff [<repo-path>:]<range>]... <body-file>" ;;
```

Edit 7 - replace:

```bash
  pane_command >/dev/null
  [ -z "$diff_range" ] || diff_text="$(inline_diff "$diff_range")"
```

with:

```bash
  pane_command >/dev/null
  # The review targets (spec 2026-10-02 §3.4). A pre-merge review that names none reviews the
  # current branch against the default branch; spec and plan reviews may have none at all.
  if [ "${#specs[@]}" -eq 0 ] && [ "$checkpoint" = pre-merge ]; then
    spec="$(ledger default-range .)" \
      || die "cannot name the current branch's default target; pass --diff <dest>...<branch>"
    specs=("$spec")
  fi
  for spec in ${specs[@]+"${specs[@]}"}; do add_target "$spec"; done
  # Refuse an oversized total rather than truncating it: a reviewer handed half a change
  # reviews half a change and reports nothing on the rest, which reads as a clean review.
  cap="${XREVIEW_MAX_DIFF_BYTES:-100000}"
  if [ "$DIFF_BYTES" -gt "$cap" ]; then
    die "the diffs are too large to carry inline ($DIFF_BYTES bytes, cap $cap).
Review them in slices, or raise XREVIEW_MAX_DIFF_BYTES if the reviewer can hold it."
  fi
```

Edit 8 - replace:

```bash
  thread_running "$thread" \
    && die "the review thread $thread is still running a turn; collect it first"
```

with:

```bash
  thread_running "$thread" \
    && die "the review thread $thread is still running a turn; collect it first"

  # The review is fixed now, before the pane is touched (spec 2026-10-02 §3.2-§3.4): its nonce,
  # its dispatch time and its targets, kept in turns/<nonce>.targets for collect. A pre-merge
  # review then puts a pending entry in every target ledger, or is refused: every pre-merge
  # review that runs is on record before its turn exists.
  nonce="xr-$(date +%s)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  dispatched="$(ledger now)" || die "cannot read the time through the ledger helper; no review was started"
  doc="$(jq -nc --arg n "$nonce" --arg at "$dispatched" --arg cp "$checkpoint" --argjson t "$TARGETS" \
           '{v:2,nonce:$n,dispatched_at:$at,checkpoint:$cp,targets:$t}')"
  mkdir -p "$dir/turns"
  printf '%s\n' "$doc" > "$dir/turns/$nonce.targets" \
    || die "cannot record the review's targets in $dir/turns; no review was started"
  if [ "$checkpoint" = pre-merge ] && ! record_pending "$doc"; then
    rm -f "$dir/turns/$nonce.targets"
    die "cannot record the pending review in every target ledger; no review was started"
  fi
```

Edit 9 - replace:

```bash
  nonce="xr-$(date +%s)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  packet="$(mktemp "${TMPDIR:-/tmp}/xreview-packet.XXXXXX")"
  { printf '<cross-review-request>\n'
    cat "$REVIEWER"
    printf '\n'
    cat "$body_file"
    if [ -n "$diff_text" ]; then
      printf '\n\n--- diff (%s) ---\n' "$diff_range"
      printf '%s\n' "$diff_text"
      printf -- '--- end diff ---\n'
    fi
    printf '</cross-review-request>\n'
```

with:

```bash
  packet="$(mktemp "${TMPDIR:-/tmp}/xreview-packet.XXXXXX")"
  { printf '<cross-review-request>\n'
    cat "$REVIEWER"
    printf '\n'
    cat "$body_file"
    [ -z "$DIFFS" ] || printf '%s\n' "$DIFFS"
    printf '</cross-review-request>\n'
```

Edit 10 - replace:

```bash
    *) rm -f "$dir/turns/$nonce.known"
       die "the review turn could not be started on $thread" ;;
```

with:

```bash
    *) rm -f "$dir/turns/$nonce.known" "$dir/turns/$nonce.targets"
       die "the review turn could not be started on $thread" ;;
```

Edit 11 - replace:

```bash
dispatch --checkpoint spec|plan|pre-merge [--diff <range>] <body-file> | tier
```

with:

```bash
dispatch --checkpoint spec|plan|pre-merge [--diff [<repo-path>:]<range>]... <body-file> | tier
```

- [ ] **Step 6: Run the suites and confirm they pass.**
  - `./tests/xreview.test.sh` (timeout 600000 ms): expect `passed: 439  failed: 0`.
  - `./tests/xreview-skill.test.sh`: expect `passed: 76  failed: 0`. The parser still has a
    `--diff)` arm.

- [ ] **Step 7: Commit.** Check the branch, then:

```bash
git add dot_local/bin/executable_xreview tests/xreview.test.sh
git commit -m "Record review targets and pre-merge pending entries at xreview dispatch"
```

## Task 5: xreview collect: receipts per repository

**Files:**
- Modify: `dot_local/bin/executable_xreview`
- Modify: `tests/xreview.test.sh`

**Interfaces:**
- Consumes:
  - Task 4: `ledger` and `turns/<nonce>.targets`;
  - Tasks 2-3: the helper's `append`, `show` and `decide`.
- Produces:
  - `record_receipts <thread> <nonce> <turn> <findings-json> <targets-file>`: one receipt per
    target repository, through `append`, which keeps it idempotent. On a failed write it warns
    `xreview: could not write the receipt for <nonce> to the ledger of <repo> (<the helper's
    reason>)` and returns 0. A stale break lock's reason names the path to remove by hand.
  - `cmd_receipts` prints `ledger show`. `--tiers` counts receipts only.
  - `record_receipt`, the v1 receipt, now runs only for a turn that has no targets file.

- [ ] **Step 1: Read receipts from the ledger, and write the failing collect tests.** Apply
  these edits to `tests/xreview.test.sh`:
  - Edit 1 adds `MAIN_LEDGER`.
  - Edits 2-8 move the D10, F1, F14, F15 and F11 receipt assertions from the per-checkout file
    to the repository's ledger.

Edit 1 - replace:

```bash
STATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$CWD" | tr '/' '_' | sed 's/^_//')"
```

with:

```bash
STATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$CWD" | tr '/' '_' | sed 's/^_//')"
MAIN_LEDGER="$(/usr/bin/python3 "$LEDGER" path "$CWD")"   # this repository's review ledger
```

Edit 2 - replace:

```bash
nonce="$(RPC_START_UNCERTAIN=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>"$ROOT/err")"; rc=$?
is "D10 an unanswered turn/start still hands back a nonce" "$rc/$(printf '%s' "$nonce" | grep -c '^xr-')" "0/1"
is "D10 with a do-not-re-dispatch warning" "$(grep -c 'do NOT re-dispatch' "$ROOT/err")" 1
```

with:

```bash
nonce="$(RPC_START_UNCERTAIN=1 bash "$XREVIEW" dispatch --checkpoint plan --diff HEAD~1..HEAD b.md 2>"$ROOT/err")"; rc=$?
is "D10 an unanswered turn/start still hands back a nonce" "$rc/$(printf '%s' "$nonce" | grep -c '^xr-')" "0/1"
is "D10 with a do-not-re-dispatch warning" "$(grep -c 'do NOT re-dispatch' "$ROOT/err")" 1
```

Edit 3 - replace:

```bash
is "D10 and the receipt names it" "$(tail -1 "$STATE/reviews.jsonl" | jq -r .turn)" turn-recovered
```

with:

```bash
is "D10 and the receipt names it" "$(tail -1 "$MAIN_LEDGER" | jq -r .turn)" turn-recovered
```

Edit 4 - replace:

```bash
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
ROLL1=
```

with:

```bash
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff HEAD~1..HEAD b.md 2>/dev/null)"
ROLL1=
```

Edit 5 - replace:

```bash
r="$(tail -1 "$STATE/reviews.jsonl")"
is "F1 the receipt keeps the old fields" "$(printf '%s' "$r" | jq -r '[.thread,.nonce,(.ts|length>0),(.head|length>0),has("tier")] | map(tostring) | join(" ")')" "$U1 $nonce true true true"
```

with:

```bash
r="$(tail -1 "$MAIN_LEDGER")"
is "F1 the receipt is a v2 receipt in the repository's ledger" \
   "$(printf '%s' "$r" | jq -r '[.v,.kind,.thread,.nonce,(.dispatched_at|length>0),has("tier")] | map(tostring) | join(" ")')" \
   "2 receipt $U1 $nonce true true"
```

Edit 6 - replace:

```bash
is "F14 a pre-merge review's receipt says so" \
   "$(tail -1 "$STATE/reviews.jsonl" | jq -r '"\(.checkpoint)/\(.verdict)"')" "pre-merge/approve"
```

with:

```bash
is "F14 a pre-merge review's receipt says so" \
   "$(tail -1 "$MAIN_LEDGER" | jq -r '"\(.checkpoint)/\(.verdict)"')" "pre-merge/approve"
```

Edit 7 - replace:

```bash
is "F15 and the receipt names the dispatch branch" "$(tail -1 "$STATE/reviews.jsonl" | jq -r .branch)" review-a
is "F15 with that branch's head, not the one checked out" \
   "$(tail -1 "$STATE/reviews.jsonl" | jq -r .head)" "$(git rev-parse review-a)"
```

with:

```bash
is "F15 and the receipt names the dispatch branch" \
   "$(tail -1 "$MAIN_LEDGER" | jq -r '"\(.kind) \(.targets[0].branch)"')" "receipt review-a"
is "F15 with that branch's head at dispatch, not the one checked out" \
   "$(tail -1 "$MAIN_LEDGER" | jq -r '"\(.kind) \(.targets[0].tip)"')" "receipt $(git rev-parse review-a)"
```

Edit 8 - replace:

```bash
echo "F11. record_receipt warns on stderr but still exits 0 when it cannot write"
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
rm -f "$STATE/reviews.jsonl"; mkdir -p "$STATE/reviews.jsonl"   # the append target cannot be written
out="$(RPC_WAIT_OUT="$ANSWER" bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F11 it still exits 0" "$rc" 0
is "F11 but warns that the receipt could not be written" \
   "$(printf '%s' "$out" | grep -c 'could not write the receipt')" 1
rmdir "$STATE/reviews.jsonl"
```

with:

```bash
echo "F11. a receipt that cannot be written warns on stderr, but collect still exits 0"
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff HEAD~1..HEAD b.md 2>/dev/null)"
mkdir -p "$(dirname "$MAIN_LEDGER")" && mkdir "$MAIN_LEDGER.lock"   # another writer holds the ledger
out="$(XREVIEW_LEDGER_LOCK_WAIT=0.2 RPC_WAIT_OUT="$ANSWER" bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F11 it still exits 0" "$rc" 0
is "F11 but warns that the receipt could not be written" \
   "$(printf '%s' "$out" | grep -c 'could not write the receipt')" 1
rmdir "$MAIN_LEDGER.lock"
```

  Then insert this block immediately above the last two lines of the file, leaving one blank
  line before them:

```bash
echo "W. receipts: one per repository, fixed at dispatch, idempotent (spec 2026-10-02 §3.5)"
APPROVE='{"verdict":"approve","findings":[]}'
CHANGES='{"verdict":"changes","findings":[]}'
# vgate <repo> [tip]: the pre-merge gate's decision for <tip> (default feature) landing on main.
vgate() { /usr/bin/python3 "$LEDGER" decide "$1" main main "${2:-feature}" | jq -r 'if .allow then "allow" else "deny" end'; }
receipts_of() { jq -r --arg n "$1" 'select(.nonce == $n and .kind == "receipt") | .verdict' "$2" 2>/dev/null; }
cd "$V" || exit 1
fresh; export PANE_CWD="$VCWD"
n1="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
is "W1 a dispatch alone leaves the gate closed" "$(vgate "$V")" deny
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n1" >/dev/null 2>&1
is "W2 an approving collect opens it" "$(vgate "$V")" allow
is "W3 with one receipt for the nonce" "$(receipts_of "$n1" "$VLEDGER")" approve
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n1" >/dev/null 2>&1
is "W4 collecting it again appends nothing" "$(receipts_of "$n1" "$VLEDGER" | wc -l | tr -d ' ')" 1
fresh; export PANE_CWD="$VCWD"
n2="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
is "W5 a newer pending review closes it" "$(vgate "$V")" deny
RPC_WAIT_OUT="$CHANGES" bash "$XREVIEW" collect "$n2" >/dev/null 2>&1
is "W6 a later changes verdict keeps it closed" "$(vgate "$V")" deny
is "W6b with the changes receipt for that nonce on record" "$(receipts_of "$n2" "$VLEDGER")" changes
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n1" >/dev/null 2>&1
is "W7 re-collecting the old approve does not reopen it" "$(vgate "$V")" deny
fresh; export PANE_CWD="$VCWD"
n3="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
mkdir "$VLEDGER.lock"   # another writer holds the ledger past the wait
out="$(XREVIEW_LEDGER_LOCK_WAIT=0.2 RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n3" 2>&1)"; rc=$?
rmdir "$VLEDGER.lock"
is "W8 a receipt that cannot be written warns, and collect still exits 0" \
   "$rc/$(printf '%s' "$out" | grep -c "could not write the receipt for $n3")" "0/1"
is "W9 the gate stays closed: the pending entry is the newest state" "$(vgate "$V")" deny
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n3" >/dev/null 2>&1
is "W10 until a later collect records the receipt" "$(vgate "$V")" allow
fresh; export PANE_CWD="$VCWD"
n4="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
printf 'three\n' >> a.txt && git commit -q -am "after the dispatch"
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n4" >/dev/null 2>&1
is "W11 the receipt names the targets fixed at dispatch" \
   "$(jq -c --arg n "$n4" 'select(.nonce == $n and .kind == "receipt") | .targets' "$VLEDGER")" \
   "$(jq -c --arg n "$n4" 'select(.nonce == $n and .kind == "pending") | .targets' "$VLEDGER")"
is "W12 so a commit made after the dispatch is not approved" "$(vgate "$V")" deny
printf '%s %s %s %s\n' "$U1" "turn-$U1" pre-merge feature > "$VSTATE/turns/xr-1-old"
before="$(wc -l < "$VLEDGER" | tr -d ' ')"
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect xr-1-old >/dev/null 2>&1; rc=$?
is "W13 an old turn record without a targets file still collects" "$rc" 0
is "W14 as a v1 receipt in the checkout's own file" \
   "$(tail -1 "$VSTATE/reviews.jsonl" | jq -r '"\(.nonce) \(.checkpoint) \(.branch) \(has("v"))"')" \
   "xr-1-old pre-merge feature false"
is "W15 which never reaches the ledger" "$(wc -l < "$VLEDGER" | tr -d ' ')" "$before"
fresh; export PANE_CWD="$VCWD"
nm="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature --diff "$V2:main...feature" b.md 2>/dev/null)"
is "W16 one dispatch, two repositories: one pending entry in each ledger" \
   "$(for f in "$VLEDGER" "$V2LEDGER"; do jq -r --arg n "$nm" 'select(.nonce == $n and .kind == "pending") | .targets | length' "$f"; done | tr '\n' ' ')" "1 1 "
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$nm" >/dev/null 2>&1
is "W17 and one receipt in each" "$(receipts_of "$nm" "$VLEDGER")/$(receipts_of "$nm" "$V2LEDGER")" "approve/approve"
is "W18 each opens its own repository's gate" "$(vgate "$V") $(vgate "$V2")" "allow allow"
git worktree add -q "$VCWD/.claude/worktrees/hw" -b hw main
HW="$(git -C "$VCWD/.claude/worktrees/hw" rev-parse --show-toplevel)"
printf 'hw\n' > "$HW/hw.txt" && git -C "$HW" add hw.txt && git -C "$HW" commit -q -m "harness change"
cd "$HW" || exit 1
fresh; export PANE_CWD="$VCWD"
nw="$(bash "$XREVIEW" dispatch --checkpoint pre-merge "$V/b.md" 2>/dev/null)"
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$nw" >/dev/null 2>&1
cd "$V" || exit 1
is "W19 a review collected in a harness worktree opens the gate in the main checkout" "$(vgate "$V" hw)" allow
out="$(bash "$XREVIEW" receipts)"
is "W20 receipts lists the repository's ledger, harness reviews included" "$(printf '%s\n' "$out" | grep -c "\"nonce\":\"$nw\"")" 2
is "W21 and this checkout's v1 receipts after it" "$(printf '%s\n' "$out" | tail -1 | jq -r .nonce)" xr-1-old
is "W22 --tiers counts receipts, never pending entries" \
   "$(bash "$XREVIEW" receipts --tiers | awk '{s += $1} END {print s}')" \
   "$(( $(jq -r 'select(.kind == "receipt") | .nonce' "$VLEDGER" | wc -l) + 1 ))"
fresh; export PANE_CWD="$VCWD"
nA="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
nB="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
RPC_WAIT_OUT="$CHANGES" bash "$XREVIEW" collect "$nB" >/dev/null 2>&1
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$nA" >/dev/null 2>&1
is "W26 a first-time approve of the older dispatch, collected last, leaves it closed" "$(vgate "$V")" deny
is "W27 because a receipt keeps its dispatch time" \
   "$(jq -r --arg n "$nA" 'select(.nonce == $n and .kind == "receipt") | .dispatched_at' "$VLEDGER")" \
   "$(jq -r --arg n "$nA" 'select(.nonce == $n and .kind == "pending") | .dispatched_at' "$VLEDGER")"
# A helper that succeeds but warns (a release that could not take the break lock): collect
# passes the warning through on stderr and still exits 0.
printf '%s\n' 'import os, runpy, sys' \
  'if "append" in sys.argv: sys.stderr.write("xreview-ledger: stub warning\n")' \
  'runpy.run_path(os.environ["XREVIEW_REAL_LEDGER"], run_name="__main__")' > "$ROOT/warn-ledger.py"
fresh; export PANE_CWD="$VCWD"
nWn="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
out="$(XREVIEW_REAL_LEDGER="$LEDGER" XREVIEW_LEDGER="$ROOT/warn-ledger.py" RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$nWn" 2>&1 >/dev/null)"; rc=$?
is "W28 a helper warning on a successful receipt write reaches stderr, and collect exits 0" \
   "$rc/$(printf '%s' "$out" | grep -c 'xreview-ledger: stub warning')/$(receipts_of "$nWn" "$VLEDGER")" "0/1/approve"
# A writer that died holding the ledger's break lock leaves it in place: collect warns, naming
# it, and a pre-merge dispatch is refused until it is removed by hand.
fresh; export PANE_CWD="$VCWD"
n5="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
mkdir "$VLEDGER.lock.break"
/usr/bin/python3 -c 'import os,sys,time; t=time.time()-120; os.utime(sys.argv[1],(t,t))' "$VLEDGER.lock.break"
out="$(RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n5" 2>&1)"; rc=$?
is "W23 a stale break lock: collect warns, naming it to remove by hand, and still exits 0" \
   "$rc/$(printf '%s' "$out" | grep -c -F "remove it by hand (rmdir $VLEDGER.lock.break)")" "0/1"
fresh; export PANE_CWD="$VCWD"
out="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>&1)"; rc=$?
is "W24 and a pre-merge dispatch is refused, naming it" \
   "$rc/$(printf '%s' "$out" | grep -c -F "remove it by hand (rmdir $VLEDGER.lock.break)")" "1/1"
is "W25 the break lock is left in place" "$([ -d "$VLEDGER.lock.break" ] && echo kept || echo gone)" kept
rmdir "$VLEDGER.lock.break"
cd "$ROOT/repo" || exit 1
unset PANE_CWD
```

- [ ] **Step 2: Run it and confirm it fails.** `./tests/xreview.test.sh` (timeout 600000 ms):
  expect `passed: 442  failed: 22`. The failures are D10, F1 (4 assertions), F14, F15 (2), F11,
  W2-W4, W8, W10, W11 and W17-W23.

- [ ] **Step 3: Implement.** Apply these edits to `dot_local/bin/executable_xreview`, in
  order:
  - Edit 1: the v1 receipt's comment.
  - Edit 2: `record_receipts`.
  - Edit 3: `cmd_receipts`.
  - Edit 4: `cmd_collect`.

Edit 1 - replace:

```bash
# A receipt is the only durable evidence that a review actually happened. It names the
# branch the review was dispatched on, not the one checked out at collect time: in a shared
# checkout another session may have switched branches in between. It records that branch's
# head at collection time so a reader can tell how far the branch has moved since;
# it deliberately does not try to invalidate itself, because applying a finding necessarily
# moves HEAD and a self-invalidating receipt would demand a second review of the fix.
# The tier is recorded, never enforced: which model and effort the reviewer runs at is
# Michael's setting, and a gate pinned to model names refuses every dispatch the day a new
# one ships. The checkpoint (spec, plan or pre-merge, named at dispatch) IS enforced:
# xreview-guard.sh admits an MR only on a pre-merge receipt whose verdict is approve.
```

with:

```bash
# The v1 receipt, written only for a turn dispatched before review targets existed (no
# turns/<nonce>.targets): it stays in the per-checkout file, names the branch the review was
# dispatched on, and never opens the pre-merge gate (spec 2026-10-02 §3.2, §3.5).
# The tier is recorded, never enforced: which model and effort the reviewer runs at is
# Michael's setting, and a gate pinned to model names refuses every dispatch the day a new
# one ships.
```

Edit 2 - replace:

```bash
    ledger append "$repo" "$entry" >/dev/null || return 1
  done <<<"$repos"
  return 0
}
```

with:

```bash
    ledger append "$repo" "$entry" >/dev/null || return 1
  done <<<"$repos"
  return 0
}

# record_receipts <thread> <nonce> <turn> <findings-json> <targets-file> - spec 2026-10-02
# §3.5: one receipt per target repository, idempotent per nonce. The targets were fixed at
# dispatch and nothing about them is read again. A failed write only warns: the pending entry
# stays the newest state of that change, so the gate stays closed until a later collect.
record_receipts() {
  local tier verdict count repos repo entry err
  tier="$(codex_tier "$1" 2>/dev/null)" || tier=""
  verdict="$(printf '%s' "$4" | jq -r '.verdict // ""' 2>/dev/null)" || verdict=""
  count="$(printf '%s' "$4" | jq -r '(.findings // []) | length' 2>/dev/null)" || count=0
  if ! repos="$(jq -r '[.targets[].repo] | unique | .[]' "$5" 2>/dev/null)"; then
    printf 'xreview: could not write the receipt for %s: its targets in %s cannot be read\n' "$2" "$5" >&2
    return 0
  fi
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    err=""
    if ! entry="$(jq -c --arg r "$repo" --arg thread "$1" --arg turn "$3" --arg tier "$tier" \
                     --arg verdict "$verdict" --argjson findings "${count:-0}" \
           '{v:2,kind:"receipt",nonce,dispatched_at,checkpoint,verdict:$verdict,findings:$findings,
             thread:$thread,turn:$turn,tier:$tier,targets:[.targets[] | select(.repo == $r)]}' \
           "$5" 2>/dev/null)" \
       || ! err="$(ledger append "$repo" "$entry" 2>&1 >/dev/null)"; then
      printf 'xreview: could not write the receipt for %s to the ledger of %s%s\n' "$2" "$repo" \
        "${err:+ ($err)}" >&2
    else
      [ -z "$err" ] || printf '%s\n' "$err" >&2
    fi
  done <<<"$repos"
  return 0
}
```

Edit 3 - replace:

```bash
cmd_receipts() {
  local f; f="$(state_dir)/reviews.jsonl"
  [ -r "$f" ] || { printf 'no reviews recorded for %s\n' "$(repo_root)"; return 1; }
  if [ "${1:-}" = "--tiers" ]; then
    jq -r '(.tier // "") | if . == "" then "(unrecorded)" else . end' "$f" 2>/dev/null \
      | sort | uniq -c | sort -rn
    return 0
  fi
  cat "$f"
}
```

with:

```bash
# Everything on record for this repository: its ledger (shared by every worktree), then this
# checkout's v1 receipts. --tiers counts the receipts only, never the pending entries.
cmd_receipts() {
  local out
  out="$(ledger show "$(pwd)" 2>/dev/null)" \
    || { printf 'no reviews recorded for %s\n' "$(repo_root)"; return 1; }
  if [ "${1:-}" = "--tiers" ]; then
    printf '%s\n' "$out" | jq -Rr 'fromjson? | select((.kind // "receipt") == "receipt")
      | (.tier // "") | if . == "" then "(unrecorded)" else . end' 2>/dev/null \
      | sort | uniq -c | sort -rn
    return 0
  fi
  printf '%s\n' "$out"
}
```

Edit 4 - replace:

```bash
    0) printf '%s\n' "$out"
       record_receipt "$thread" "$nonce" "$turn" "$out" "$checkpoint" "$branch" ;;
```

with:

```bash
    0) printf '%s\n' "$out"
       # A turn dispatched before review targets existed has no targets file: its receipt
       # is the v1 one, as before, so every turn in flight at rollout still collects.
       if [ -e "$(state_dir)/turns/$nonce.targets" ]; then
         record_receipts "$thread" "$nonce" "$turn" "$out" "$(state_dir)/turns/$nonce.targets"
       else
         record_receipt "$thread" "$nonce" "$turn" "$out" "$checkpoint" "$branch"
       fi ;;
```

- [ ] **Step 4: Run it and confirm it passes.** `./tests/xreview.test.sh` (timeout 600000 ms):
  expect `passed: 468  failed: 0`.

- [ ] **Step 5: Commit.** Check the branch, then:

```bash
git add dot_local/bin/executable_xreview tests/xreview.test.sh
git commit -m "Write xreview receipts to each target repository's ledger, once per nonce"
```

## Task 6: The guard: grammar, fast path and git merge

**Files:**
- Create: `dot_claude/xreview-guard.py`
- Rewrite: `dot_claude/executable_xreview-guard.sh`
- Rewrite: `tests/xreview-guard.test.sh` (mode stays 755)
- Modify: `.chezmoiignore` (allowlist `!.claude/xreview-guard.py`)
- Modify: `dot_claude/modify_private_settings.json` (a 60 s timeout on the guard's hook)
- Modify: `tests/claude-settings.test.sh` (timeout; the guard helper is managed)
- Modify: `tests/xreview-skill.test.sh` (the gate's code is three files now)

**Interfaces:**
- Consumes (Tasks 1-3): the helper, imported from the guard's directory or from
  `$XREVIEW_LEDGER`. The guard uses `decide`, `default_branch`, `current_branch` and
  `CALL_TIMEOUT`.
- Produces, in `xreview-guard.py`:
  - `tokenize(cmd) -> list[str]`, with here-document bodies, comments and redirections
    stripped (`split_heredocs`, `strip_comments`, `strip_redirections`, `skip_word`).
  - `split_heredocs(cmd) -> (text, expanding_bodies)`, which finds each `<<`/`<<-` with
    `HEREDOC_START` and reads its delimiter with `heredoc_word(line, i) -> (delimiter,
    quoted) | None`, the whole shell word (`METACHARS` end it); `substitutions(text,
    shell=True) -> list[str]`; `closing_paren(text, i)`; `substituted_commands(cmd)`;
    `gated_in_substitution(cmd, depth=0) -> bool`.
  - `strip_redirections(cmd)`: `REDIRECT_RE` (an optional descriptor, then the operator) where
    a word starts, `REDIRECT_MID_RE` (the operator alone) inside a word, both outside quotes.
  - `command_words(tokens) -> list[int]`: every word after a wrapper is a candidate;
    `segment(tokens, k) -> list[str]`; `literal(word) -> bool`.
  - `gated_verb(words) -> dict | None`, as
    `{"tool": "git" | "glab" | "gh", "kind": "merge-local" | "create" | "merge" | "api", "args": [...]}`.
  - `parse_api(args) -> dict` with `endpoint, method, fields, body, hostname`;
    `endpoint_parts`; `is_graphql`; `api_gated`.
  - `parse_plain(tokens, cwd) -> dict | None`, which adds `cwd`.
  - `parse_flags(args, takes_value) -> (dict, list)`.
  - `run(argv, cwd=None) -> str | None`; `toplevel(cwd) -> str`, which raises `Deny`.
  - `check(ledger, top, source, dest, dest_rev, tip, dispatch_range, merge_hint)`: returns on
    allow, raises `Deny` otherwise.
  - `judge(shape, ledger)` and `class Deny(Exception)`.
  - `decision(reason) -> str`: the hook JSON, with the Michael-only bypass paragraph appended.
  - The constant `NOT_MODELLED`: Tasks 7 and 8 replace it, and until then forge shapes are
    denied with it.
  - The environment knobs `XREVIEW_LEDGER` (tests) and `XREVIEW_GUARD_BUDGET` (whole seconds,
    default 40).

- [ ] **Step 1: Write the failing guard test.** Replace the whole content of
  `tests/xreview-guard.test.sh` with:

```bash
#!/usr/bin/env bash
# Tests for the pre-merge gate: dot_claude/executable_xreview-guard.sh (the shell front and its
# fast path) and dot_claude/xreview-guard.py (the grammar and the checks), which decides through
# dot_claude/xreview-ledger.py. Spec: docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md.
#
# Fixtures are real git repositories under $TMPDIR, with a private git configuration and
# XDG_STATE_HOME. origin is a bare repository reached through url.<path>.insteadOf, so its
# configured URL names a forge project (acme/app on forge.example) while every git call stays
# local. Every assertion pins an exact decision: "did not crash" is not evidence a guard fired.
#
# Many cases pin the ALLOW side. The guard fires on every Bash call, and its first matcher
# read "gh" out of "outright" and "create" out of "recreate": nine false denies to five real
# ones in the recorded transcripts (2026-09-03). A guard that stops unrelated work is worse
# than no guard.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$SRC/dot_claude/executable_xreview-guard.sh"
HELPER="$SRC/dot_claude/xreview-guard.py"
LEDGER="$SRC/dot_claude/xreview-ledger.py"
for f in "$GUARD" "$HELPER" "$LEDGER"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
L() { /usr/bin/python3 "$LEDGER" "$@"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrguard.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state" XREVIEW_LEDGER="$LEDGER" CALLS="$ROOT/calls" \
       GIT_CEILING_DIRECTORIES="$ROOT"
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
  > "$GIT_CONFIG_GLOBAL"
unset XREVIEW_GUARD XREVIEW_GUARD_BUDGET XREVIEW_LEDGER_LOCK_WAIT
# The forge CLIs pick a host from these when no --hostname or host-qualified -R names one; the
# fixtures' forge is forge.example. gh's configuration directory starts empty, and glab's
# config names forge.example as its default host.
export GH_HOST=forge.example GH_CONFIG_DIR="$ROOT/gh" GLAB_CONFIG_DIR="$ROOT/glab"
unset GITLAB_HOST GITLAB_URI GL_HOST GITLAB_URL GITLAB_API_HOST GITLAB_REPO GH_REPO
mkdir -p "$GLAB_CONFIG_DIR" && printf 'host: forge.example\n' > "$GLAB_CONFIG_DIR/config.yml"

# W: the work repository, on main; feature is one change ahead. SIDE: a second worktree, on
# side. origin holds main only, until a section publishes more.
ORIGIN="$ROOT/remotes/app.git"; W="$ROOT/work/app"; SIDE="$ROOT/work/app-side"
git init -q --bare "$ORIGIN"
mkdir -p "$W" && git -C "$W" init -q
printf 'one\ntwo\nthree\n' > "$W/a.txt"; printf 'alpha\n' > "$W/b.txt"
git -C "$W" add a.txt b.txt && git -C "$W" commit -q -m init
git -C "$W" remote add origin 'git@forge.example:acme/app.git'
git -C "$W" config "url.$ORIGIN.insteadOf" 'git@forge.example:acme/app.git'
# publish <branch>...: origin takes these branches from W, and W fetches them back.
publish() {
  local b
  for b in "$@"; do git -C "$ORIGIN" fetch -q "$W" "+refs/heads/$b:refs/heads/$b"; done
  git -C "$W" fetch -q origin
}
publish main
git -C "$W" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$W" branch feature && git -C "$W" switch -q feature
printf 'one\nTWO\nthree\n' > "$W/a.txt"; git -C "$W" commit -q -am "edit a"
git -C "$W" switch -q main
git -C "$W" worktree add -q -b side "$SIDE" main
mkdir -p "$ROOT/norepo"

payload() { jq -n --arg d "$1" --arg c "$2" '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
# The payload is materialised before the pipeline: the guard can exit without reading stdin,
# and jq writing into a closed pipe prints an error that looks like a test failure.
run_guard() { local p; p="$(payload "$1" "$2")"; printf '%s' "$p" | bash "$GUARD" 2>/dev/null; }
# decision <cwd> <command>: allow (silence), deny, or what else the guard printed.
decision() {
  local out; out="$(run_guard "$1" "$2")"
  [ -n "$out" ] || { printf 'allow'; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || printf 'malformed'
}
reason() { run_guard "$1" "$2" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
# review <repo> <range> <verdict|pending> [checkpoint]: one review of <range> on record, as
# xreview writes it - a pending entry, then (unless pending) its receipt.
NREV=0
review() {
  local t at nonce common
  NREV=$((NREV + 1)); nonce="xr-test-$NREV"
  t="$(L normalize "$1" "$2")" || { echo "cannot normalize $2 in $1" >&2; return 1; }
  at="$(L now)"; common="$(printf '%s' "$t" | jq -r .repo)"
  L append "$common" "$(jq -nc --arg n "$nonce" --arg at "$at" --arg cp "${4:-pre-merge}" --argjson t "$t" \
    '{v:2,kind:"pending",nonce:$n,dispatched_at:$at,checkpoint:$cp,targets:[$t]}')" >/dev/null
  [ "$3" = pending ] && return 0
  L append "$common" "$(jq -nc --arg n "$nonce" --arg at "$at" --arg cp "${4:-pre-merge}" --arg v "$3" --argjson t "$t" \
    '{v:2,kind:"receipt",nonce:$n,dispatched_at:$at,checkpoint:$cp,verdict:$v,findings:0,thread:"t",turn:"u",tier:"",targets:[$t]}')" >/dev/null
}

echo "A. what is never gated"
is "A1 an unrelated command" "$(decision "$W" 'git status')" allow
is "A2 a commit message that says merge" "$(decision "$W" 'git commit -m "merge the feature"')" allow
is "A3 rg for a gated verb" "$(decision "$W" "rg 'glab mr merge' docs/")" allow
is "A4 rg for another" "$(decision "$W" "rg 'gh pr create' docs/")" allow
is "A5 a Basecamp comment whose prose contains gh, pr and create" \
   "$(decision "$W" "printf '%s\\n' 'The runner outright refuses the proposed patch; recreate the cache.' | basecamp comments create 10268194367 - --in 47577890")" allow
is "A6 a card comment about a GitHub download" \
   "$(decision "$W" "printf '%s' '<p>Weights were fetched from <strong>github.com/ultralytics/assets</strong>; the proposed change recreates that path.</p>' | basecamp comments create 1 - --in 2")" allow
is "A7 an MR body written through a here-document, lines starting with gated verbs" \
   "$(decision "$W" 'cat > "$TMPDIR/mr-body.md" <<'"'"'EOF'"'"'
## How to land it
git merge feature
glab mr create --target-branch main
EOF')" allow
is "A8 help is never gated" "$(decision "$W" 'gh pr create --help')" allow
is "A9 git merge --abort" "$(decision "$W" 'git merge --abort')" allow
is "A10 git merge-base is another command" "$(decision "$W" 'git merge-base main feature')" allow
is "A11 a merge on a branch other than the default is not gated" "$(decision "$SIDE" 'git merge feature')" allow
is "A12 nor through git -C <path> on such a branch" "$(decision "$W" "git -C $SIDE merge feature")" allow
is "A13 a glab api read of an MR" "$(decision "$W" 'glab api projects/:id/merge_requests/7')" allow
is "A14 a gh api read of pulls" "$(decision "$W" "gh api 'repos/{owner}/{repo}/pulls' --jq '.[].number'")" allow
# A here-document delimiter is a whole shell word: quoted with any characters in it, or
# unquoted up to a metacharacter. The closing line must equal it, quotes removed.
SQ="'"; TAB="$(printf '\t')"
is "A15 a quoted delimiter with a hyphen" "$(decision "$W" "cat > \"\$TMPDIR/mr-body.md\" <<'MR-BODY'
## How to land it
git merge feature
glab mr create --target-branch main
MR-BODY")" allow
is "A16 the same under <<-, its closing line tab-indented" "$(decision "$W" "cat <<-'MR-BODY'
${TAB}git merge feature
${TAB}MR-BODY")" allow
is "A17 an unquoted delimiter with a dot" "$(decision "$W" 'cat > notes.md <<END.md
git merge feature
END.md')" allow
is "A18 a quoted delimiter with a space keeps its body inert" "$(decision "$W" 'cat <<"a b"
$(git merge feature)
a b')" allow
is "A19 only <<- strips tabs: under <<, a tab-indented delimiter is body" "$(decision "$W" "cat <<'EOF'
${TAB}EOF
git merge feature
EOF")" allow

echo "B. a gated verb must be a plain command"
is "B1 a chain that switches branch first" "$(decision "$W" 'git switch main && git merge feature')" deny
is "B2 a ; chain before an MR creation" "$(decision "$W" 'true; glab mr create --target-branch main')" deny
is "B3 the verb after an assignment on a previous line" "$(decision "$W" 'SP=/tmp/scratch
glab mr create --description "$(cat "$SP/mr-body.md")" --target-branch main --yes')" deny
is "B4 the verb after a pipe" "$(decision "$W" 'printf body | gh pr create --base main --body-file -')" deny
is "B5 an environment assignment on the verb" "$(decision "$W" 'GH_REPO=o/r gh pr create --base main')" deny
is "B6 GIT_DIR on a merge" "$(decision "$W" 'GIT_DIR=/tmp/x git merge feature')" deny
is "B7 an env wrapper" "$(decision "$W" 'env GITLAB_HOST=x glab mr merge 7')" deny
is "B8 a subshell" "$(decision "$W" '(git merge feature)')" deny
is "B9 a merge in a chain on a feature branch is denied too" "$(decision "$SIDE" 'git fetch origin && git merge origin/main')" deny
is "B10 an API merge piped to jq" "$(decision "$W" 'glab api -X PUT projects/:id/merge_requests/7/merge | jq .state')" deny
is "B11 the deny asks for the plain form" "$(reason "$W" 'git switch main && git merge feature' | grep -c 'plain command of its own')" 1
is "B12 a leading redirection hides no verb" "$(decision "$W" '>merge.log git merge feature')" deny
is "B13 nor does a descriptor redirection" "$(decision "$W" '2>err git merge feature')" deny
is "B14 sudo with an option is denied" "$(decision "$W" 'sudo -u root git merge feature')" deny
is "B15 a merge whose message is --help is still gated" "$(decision "$W" 'git merge -m "--help" feature')" deny
is "B16 a creation titled --help is still gated" "$(decision "$W" 'glab mr create -s feature -b main --title --help')" deny
is "B17 --abort beside a ref is still gated" "$(decision "$W" 'git merge --abort feature')" deny
is "B18 a process substitution runs a command" "$(decision "$W" 'cat <(git merge feature)')" deny
# Command substitutions run, quoted with double quotes or not; single quotes keep them inert.
is "B19 a substitution inside double quotes runs its command" "$(decision "$W" 'echo "$(git merge feature)"')" deny
is "B20 so does a backtick substitution inside double quotes" "$(decision "$W" 'echo "`git merge feature`"')" deny
is "B21 and an unquoted backtick one" "$(decision "$W" 'echo `git merge feature`')" deny
is "B22 even in an ungated command's message" "$(decision "$W" 'git commit -m "$(git merge feature)"')" deny
is "B23 at any depth" "$(decision "$W" 'echo "$(echo `git merge feature`)"')" deny
is "B24 the deny asks for the plain form" "$(reason "$W" 'echo "$(git merge feature)"' | grep -c 'plain command of its own')" 1
is "B25 single quotes keep both kinds inert" "$(decision "$W" "echo ${SQ}\$(git merge feature)${SQ} ${SQ}\`git merge feature\`${SQ}")" allow
is "B26 so does a backslash" "$(decision "$W" 'echo "\$(git merge feature)"')" allow
is "B27 and a comment" "$(decision "$W" 'git status # $(git merge feature)')" allow
# A here-document whose delimiter is unquoted expands its substitutions; the rest of its body,
# and the whole body under a quoted delimiter, is data.
is "B28 an unquoted here-document runs its substitutions" "$(decision "$W" 'cat > notes.md <<EOF
done: $(git merge feature)
EOF')" deny
is "B29 a backtick code span in an unquoted MR body runs too" "$(decision "$W" 'cat > "$TMPDIR/mr-body.md" <<EOF
Land it with `glab mr create --target-branch main`.
EOF')" deny
is "B30 so does a tab-stripped <<-EOF body" "$(decision "$W" "cat <<-EOF
${TAB}\$(git merge feature)
${TAB}EOF")" deny
is "B31 the rest of an unquoted body is data" "$(decision "$W" 'cat > notes.md <<EOF
git merge feature
on $(date +%F)
EOF')" allow
is "B32 a quoted or escaped delimiter keeps the whole body inert" \
   "$(decision "$W" "cat <<${SQ}EOF${SQ}
\$(git merge feature)
EOF") $(decision "$W" 'cat <<"EOF"
$(git merge feature)
EOF') $(decision "$W" 'cat <<\EOF
`git merge feature`
EOF')" "allow allow allow"
is "B33 an unquoted delimiter with a dot still expands its body" "$(decision "$W" 'cat <<END.md
$(git merge feature)
END.md')" deny
# A redirection operator needs no blank before it: git>log is git, then a redirection.
is "B34 a redirection fused to the command word" "$(decision "$W" 'git>merge.log merge feature')" deny
is "B35 fused to the verb" "$(decision "$W" 'git merge>merge.log feature')" deny
is "B36 fused to glab's subcommand" "$(decision "$W" 'glab mr>create.log create -s feature -b main')" deny
is "B37 and to glab" "$(decision "$W" 'glab>create.log mr create -s feature -b main')" deny
is "B38 fused redirections before the command word" "$(decision "$W" '>merge.log<in.txt git merge feature')" deny
is "B39 a <<- body ends at its tab-indented delimiter, and what follows runs" "$(decision "$W" "cat <<-'EOF'
${TAB}EOF
git merge feature
EOF")" deny

echo "C. git merge into the default branch"
is "C1 an unreviewed merge into main is denied" "$(decision "$W" 'git merge feature')" deny
r="$(reason "$W" 'git merge feature')"
is "C2 the deny names the dispatch that opens the gate" "$(printf '%s' "$r" | grep -c -- '--checkpoint pre-merge --diff main...feature <body-file>')" 1
is "C3 and the change's fingerprint" "$(printf '%s' "$r" | grep -cE 'fingerprint [0-9a-f]{64}')" 1
is "C4 and offers the bypass only when Michael asked" "$(printf '%s' "$r" | tr '\n' ' ' | grep -c 'Only if Michael has asked, in this conversation')" 1
review "$W" main...feature approve
is "C5 an approved full change opens it" "$(decision "$W" 'git merge feature')" allow
is "C6 with options and a message" "$(decision "$W" 'git merge --no-ff -m "Land feature" feature')" allow
is "C7 from cd <path> &&" "$(decision "$ROOT" "cd $W && git merge feature")" allow
is "C8 and from git -C <path>" "$(decision "$SIDE" "git -C $W merge feature")" allow
is "C9 a trailing comment is not a second ref" "$(decision "$W" 'git merge feature # land it')" allow
git -C "$W" switch -q feature; printf 'four\n' >> "$W/b.txt"; git -C "$W" commit -q -am "one more"; git -C "$W" switch -q main
is "C10 one extra commit closes it" "$(decision "$W" 'git merge feature')" deny
is "C11 the deny lists what is on record for the branch" "$(reason "$W" 'git merge feature' | grep -c 'On record for branch feature: pre-merge/approve xr-test-1')" 1
review "$W" main...feature approve
is "C12 a fresh full-range round reopens it" "$(decision "$W" 'git merge feature')" allow
is "C13 two refs at once are denied" "$(decision "$W" 'git merge feature side')" deny
is "C14 a merge that names no ref is denied" "$(decision "$W" 'git merge')" deny
is "C15 an empty change is denied" "$(decision "$W" 'git merge side')" deny
is "C16 redirections after an approved merge are read past" "$(decision "$W" 'git merge feature > merge.log 2>&1')" allow
is "C17 and before it" "$(decision "$W" '>merge.log git merge feature')" allow
is "C18 a harmless substitution in an approved merge stays allowed" "$(decision "$W" 'git merge -m "$(cat /tmp/msg)" feature')" allow
is "C19 a redirection fused to the ref is read past" "$(decision "$W" 'git merge feature>merge.log')" allow
is "C20 and one fused to the command word" "$(decision "$W" 'git>merge.log merge feature')" allow
is "C21 and one fused to the verb" "$(decision "$W" 'git merge>merge.log feature')" allow
is "C22 every operator form, fused" \
   "$(for c in 'feature>>m.log' 'feature<in.txt' 'feature 2>err>m.log' 'feature&>m.log' 'feature>&2' 'feature 2>&1' 'feature<>m.log' 'feature>|m.log'; do
        decision "$W" "git merge $c"; printf ' '; done)" \
   "allow allow allow allow allow allow allow allow "

echo "D. it fails closed"
is "D1 a merge outside any repository is denied" "$(decision "$ROOT/norepo" 'git merge feature')" deny
is "D2 saying why" "$(reason "$ROOT/norepo" 'git merge feature' | grep -c 'is not inside a git repository')" 1
LF="$(L path "$W")"
chmod 000 "$LF"
is "D3 an unreadable ledger is a deny" "$(decision "$W" 'git merge feature')" deny
is "D4 naming it" "$(reason "$W" 'git merge feature' | grep -c 'is unreadable')" 1
chmod 644 "$LF"
is "D5 readable again, the approval stands" "$(decision "$W" 'git merge feature')" allow
is "D6 unbalanced quotes around a gated verb" "$(decision "$W" 'git merge "feature')" deny

echo "E. the bypass is Michael's"
is "E1 XREVIEW_GUARD=off on the command" "$(decision "$W" 'XREVIEW_GUARD=off git merge side')" allow
is "E2 mid-command" "$(decision "$W" 'cd /tmp && XREVIEW_GUARD=off glab mr create --fill')" allow
is "E3 in a trailing comment" "$(decision "$W" 'glab mr create --fill # XREVIEW_GUARD=off')" allow
XREVIEW_GUARD=off; export XREVIEW_GUARD
is "E4 in the hook's environment" "$(decision "$W" 'git merge side')" allow
unset XREVIEW_GUARD
is "E5 an empty payload fails open" "$(printf '' | bash "$GUARD" 2>/dev/null | wc -c | tr -d ' ')" 0

echo "F. the fast path costs nothing, and a helper that cannot run fails closed"
TRIP="$ROOT/trip"; mkdir -p "$TRIP"
cp "$GUARD" "$TRIP/xreview-guard.sh"
printf 'import sys\nopen(sys.argv[0] + ".ran", "a").write("x")\n' > "$TRIP/xreview-guard.py"
tripped() { [ -e "$TRIP/xreview-guard.py.ran" ] && echo ran || echo idle; }
for c in 'ls -la' 'git status' 'npm test' 'git log --oneline -5' 'mkdir -p newdir'; do
  payload /tmp "$c" | bash "$TRIP/xreview-guard.sh" >/dev/null 2>&1
done
is "F1 commands without a trigger word never start the helper" "$(tripped)" idle
payload /tmp 'git merge feature' | bash "$TRIP/xreview-guard.sh" >/dev/null 2>&1
is "F2 a gated verb does" "$(tripped)" ran
printf 'import sys\nsys.exit(3)\n' > "$TRIP/xreview-guard.py"
out="$(payload "$W" 'git merge feature' | bash "$TRIP/xreview-guard.sh" 2>/dev/null)"
is "F3 a helper that cannot run denies a gated verb" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision)" deny
out="$(payload "$W" 'git commit -m "a new test"' | bash "$TRIP/xreview-guard.sh" 2>/dev/null)"
is "F4 and leaves an ungated command alone" "$out" ""

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
```

- [ ] **Step 2: Write the failing settings and skill checks.**
  - Apply this to `tests/claude-settings.test.sh`:

Edit 1 - replace:

```bash
  for f in .claude/xreview-ledger.py; do
```

with:

```bash
  for f in .claude/xreview-guard.py .claude/xreview-ledger.py; do
```

Edit 2 - replace:

```bash
jq_is '[.hooks.PreToolUse[].hooks[] | select(.command == "bash $HOME/.claude/git-forge-guard.sh") | .timeout] | join(",")' 60 \
      "the forge guard hook carries an explicit 60 s timeout"
```

with:

```bash
jq_is '[.hooks.PreToolUse[].hooks[] | select(.command == "bash $HOME/.claude/git-forge-guard.sh") | .timeout] | join(",")' 60 \
      "the forge guard hook carries an explicit 60 s timeout"
# The pre-merge guard reads origin (git ls-remote) and the forge (glab, gh). It gives up at
# 40 s, inside this limit: a hook that outruns its timeout is treated as non-blocking.
jq_is '[.hooks.PreToolUse[].hooks[] | select(.command == "bash $HOME/.claude/xreview-guard.sh") | .timeout] | join(",")' 60 \
      "the pre-merge guard hook carries an explicit 60 s timeout"
```

  - Apply this to `tests/xreview-skill.test.sh`. The skill suite reads the gate's code from
    all three files, so its "the guard matches it" checks keep finding the gated verbs once
    the shell front stops spelling them.

Edit 1 - replace:

```bash
IMPL=("$XREVIEW" "$ROOT/dot_claude/executable_xreview-guard.sh" "$ROOT/dot_claude/executable_xreview-apply-guard.sh")
```

with:

```bash
IMPL=("$XREVIEW" "$ROOT/dot_claude/executable_xreview-guard.sh" "$ROOT/dot_claude/xreview-guard.py"
      "$ROOT/dot_claude/xreview-ledger.py" "$ROOT/dot_claude/executable_xreview-apply-guard.sh")
```

Edit 2 - replace:

```bash
GUARD="$ROOT/dot_claude/executable_xreview-guard.sh"
guard_code="$(strip_comments "$GUARD")"
```

with:

```bash
# The gate is the shell front, the Python grammar beside it, and the ledger it decides with.
GUARD="$ROOT/dot_claude/executable_xreview-guard.sh"
guard_code="$(strip_comments "$GUARD" "$ROOT/dot_claude/xreview-guard.py" "$ROOT/dot_claude/xreview-ledger.py")"
```

- [ ] **Step 3: Run them and confirm they fail.**
  - `./tests/xreview-guard.test.sh`: expect exit 2 with
    `missing file under test: …/dot_claude/xreview-guard.py`.
  - `./tests/xreview-skill.test.sh`: expect exit 2 with the same message.
  - `./tests/claude-settings.test.sh 2>&1 | tail -1`: expect `RESULT: 177 passed, 2 failed`,
    which are the managed `xreview-guard.py` and the timeout.

- [ ] **Step 4: Write the guard's Python half.** Create `dot_claude/xreview-guard.py` with
  exactly:

```python
#!/usr/bin/python3
# The pre-merge gate: its command grammar and its checks. xreview-guard.sh beside this file
# runs it for a payload that mentions create, new, merge, accept, pulls or graphql and one of
# glab, gh or git. Design: docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md,
# section 3.6.
#
# Reads the PreToolUse payload on stdin. Prints ONE hookSpecificOutput deny object, or
# nothing. It never asks, and it never allows on doubt: a gated shape it cannot complete is
# denied with a reason the agent can act on. A command holding no gated verb is allowed.
#
# A gated verb counts only in command position, and it must be a plain command:
#
#   [cd <literal path> &&] [sudo] git [-C <path>]... merge [options] <ref>   (onto the default branch)
#   [cd <literal path> &&] [sudo] glab mr create|new|merge|accept [options]
#   [cd <literal path> &&] [sudo] gh pr create|new|merge [options]
#   [cd <literal path> &&] [sudo] glab|gh api [options] <endpoint>   (an MR/PR write, or graphql)
#
# Any other command holding a gated verb in command position (a chain, a pipe, a newline, a
# subshell, an assignment, env, sudo with an option, or another wrapper) is denied, asking for
# the plain form. So is any command whose substitutions run one: a $( ) or backtick body,
# unquoted or inside double quotes, or inside a here-document whose delimiter is unquoted.
# A comment, a redirection, single-quoted text and the rest of a here-document body are read
# past, wherever they stand. --help or -h right after the verb, and a merge's lone --abort,
# --quit or --continue, are never gated.
#
# Threat model: the commands an agent plausibly writes. A verb assembled from variables, eval,
# a script file or an alias passes; the auto-mode classifier covers those.
#
# Written for /usr/bin/python3 (3.9): no match statements, no X | Y type unions.
import importlib.util
import json
import os
import re
import shlex
import signal
import subprocess
import sys
from urllib.parse import parse_qsl, quote, unquote, urlsplit

# Claude Code treats a hook that outruns its timeout (60 s in the settings) as non-blocking,
# so the gate gives up first, and a give-up is a deny. XREVIEW_GUARD_BUDGET exists only so
# the test suite can shorten it.
try:
    BUDGET = max(1, int(os.environ.get("XREVIEW_GUARD_BUDGET", "40")))
except ValueError:
    BUDGET = 40
CALL_TIMEOUT = 8.0
HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER_PATH = os.environ.get("XREVIEW_LEDGER") or os.path.join(HERE, "xreview-ledger.py")

TAIL = ("\n\nDo not bypass this on your own judgement. Only if Michael has asked, in this "
        "conversation, for this to go ahead without a review: re-run with XREVIEW_GUARD=off in "
        "the command (an assignment on the command line is read, a trailing "
        "# XREVIEW_GUARD=off works too), and say so in the MR.")
PLAIN = ("Pre-merge gate: this command proposes or merges a change in a shape the gate does not "
         "check. Run the verb as a plain command of its own - [cd <path> &&] git [-C <path>] "
         "merge <ref>, glab mr ..., gh pr ..., or glab|gh api ... - with no chain, pipe, "
         "newline, subshell, environment assignment or env wrapper. If the command only "
         "mentions the verb, keep it out of command position (quote it).")
UNPARSEABLE = ("Pre-merge gate: this command cannot be parsed (unbalanced quotes), and it may "
               "propose or merge a change. Fix the quoting, and run the verb as a plain command.")
TIMED_OUT = "Pre-merge gate: the check did not finish in time, so the command is refused. Retry it."
LITERAL = "Pre-merge gate: {} must be a literal value the gate can read, not {}."
NO_REPO = "Pre-merge gate: {} is not inside a git repository, so the change cannot be checked."
ONE_REF = "Pre-merge gate: merge one named ref at a time: git merge <ref>."
NOT_MODELLED = "Pre-merge gate: the gate does not check this forge command yet, so it is refused."


class Deny(Exception):
    """A gated command that must be refused, carrying the reason the agent reads."""


def decision(reason):
    return json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason + TAIL,
    }}, separators=(",", ":"))


# ------------------------------------------------------------------ tokens
PUNCT = ";&|()<>\n"
ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# A here-document operator, << or <<- (not the here-string <<<); its delimiter word follows.
HEREDOC_START = re.compile(r"(?<!<)<<(?!<)(-?)[ \t]*")
METACHARS = " \t\n;&|()<>"
WRAPPERS = {"command", "env", "sudo", "time", "nohup", "xargs", "exec", "nice", "builtin"}
RESERVED = {"if", "then", "elif", "else", "do", "while", "until", "!", "{"}
MAX_NESTING = 8


def heredoc_word(line, i):
    """(delimiter, quoted) of the here-document word starting at line[i], read as the shell
    reads it: up to a metacharacter, a '...' or "..." part taken whole whatever it holds, and a
    backslash escaping the next character. Any quoting or escaping makes it quoted: the body
    then does not expand. None when there is no word or a quote never closes."""
    out, quoted, n = [], False, len(line)
    while i < n and line[i] not in METACHARS:
        c = line[i]
        if c == "\\" and i + 1 < n:
            out.append(line[i + 1])
            quoted, i = True, i + 2
        elif c in "'\"":
            j = line.find(c, i + 1)
            if j < 0:
                return None
            out.append(line[i + 1:j])
            quoted, i = True, j + 1
        else:
            out.append(c)
            i += 1
    return ("".join(out), quoted) if out else None


def split_heredocs(cmd):
    """(cmd without the bodies of its here-documents, the bodies that expand). A body is data,
    never a command; but when its delimiter is unquoted the shell still runs the $( ) and
    backtick substitutions in it, so those bodies are kept for scanning. A body ends at the
    line that is exactly its unquoted delimiter (after leading tabs, for <<-). A marker whose
    terminator line never comes is left alone, so no text is dropped on a guess."""
    lines, out, expanding, i = cmd.split("\n"), [], [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in HEREDOC_START.finditer(line):
            word = heredoc_word(line, m.end())
            if word is None:
                continue
            delimiter, quoted = word
            j = i
            while j < len(lines) and (lines[j].lstrip("\t") if m.group(1) else lines[j]) != delimiter:
                j += 1
            if j < len(lines):
                if not quoted:
                    expanding.append("\n".join(lines[i:j]))
                i = j + 1
    return "\n".join(out), expanding


def closing_paren(text, i):
    """The index of the ) that closes a $( opened just before i: nested parentheses and quotes
    inside it are tracked. len(text) when it never closes."""
    depth, quoting, n = 1, None, len(text)
    while i < n:
        c = text[i]
        if c == "\\" and quoting != "'" and i + 1 < n:
            i += 2
            continue
        if quoting:
            if c == quoting:
                quoting = None
        elif c in "'\"":
            quoting = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def substitutions(text, shell=True):
    """The bodies of the command substitutions, $( ) and backticks, that run when text does.
    In shell text (shell=True) single quotes keep them inert, double quotes do not. In an
    expanding here-document body (shell=False) quotes are plain characters; only a
    backslash keeps a $ or a backtick literal."""
    out, i, n, quoting = [], 0, len(text), None
    while i < n:
        c = text[i]
        if c == "\\" and quoting != "'" and i + 1 < n:
            i += 2
            continue
        if shell and quoting is None and c in "'\"":
            quoting = c
        elif shell and c == quoting:
            quoting = None
        elif quoting != "'" and text.startswith("$(", i):
            j = closing_paren(text, i + 2)
            out.append(text[i + 2:j])
            i = j + 1
            continue
        elif quoting != "'" and c == "`":
            j = i + 1
            while j < n and text[j] != "`":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i + 1:j])
            i = j + 1
            continue
        i += 1
    return out


def substituted_commands(cmd):
    """The command texts cmd runs through substitution: every $( ) and backtick body outside
    single quotes and comments, and each one in a here-document body whose delimiter is
    unquoted. Nested ones are found when each body is read in turn."""
    main, expanding = split_heredocs(cmd)
    bodies = substitutions(strip_comments(main.replace("\\\n", " ")))
    for body in expanding:
        bodies.extend(substitutions(body, shell=False))
    return bodies


def gated_in_substitution(cmd, depth=0):
    """Does a command substitution in cmd, at any depth, run a gated verb?"""
    for body in substituted_commands(cmd):
        if depth >= MAX_NESTING:
            return True
        try:
            tokens = tokenize(body)
        except ValueError:
            if CRUDE.search(body):
                return True
            continue
        if any(gated_verb(segment(tokens, k)) for k in command_words(tokens)):
            return True
        if gated_in_substitution(body, depth + 1):
            return True
    return False


def strip_comments(cmd):
    """cmd without its comments: an unquoted # that starts a word, to the end of its line.
    Quotes and backslashes are tracked as the shell does, so a quoted '#12 fix' stays."""
    out, i, n, quoting = [], 0, len(cmd), None
    while i < n:
        c = cmd[i]
        if quoting is None and c == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|()"):
            j = cmd.find("\n", i)
            if j < 0:
                break
            i = j
            continue
        out.append(c)
        if c == "\\" and quoting != "'" and i + 1 < n:
            out.append(cmd[i + 1])
            i += 2
            continue
        if quoting is None and c in "'\"":
            quoting = c
        elif c == quoting:
            quoting = None
        i += 1
    return "".join(out)


# A redirection operator: >, >>, >|, <, <>, <&, >&, &>, &>>, a here-string or a here-document
# marker, anywhere in an unquoted word; at the start of a word it may carry a descriptor
# number (2>, 2>&1). Not a process substitution, <( ) or >( ), which runs a command.
REDIRECT_OP = r"(?:&>>|&>|>>|>&|>\||<>|<&|<<<|<<-|<<|>|<)(?!\()"
REDIRECT_RE = re.compile(r"\d*" + REDIRECT_OP)
REDIRECT_MID_RE = re.compile(REDIRECT_OP)
WORD_END = " \t\n;&|()<>"


def skip_word(cmd, i):
    """The index just past the shell word that starts at i, quotes and backslashes included."""
    n, quoting = len(cmd), None
    while i < n:
        c = cmd[i]
        if quoting is None and c in WORD_END:
            break
        if c == "\\" and quoting != "'" and i + 1 < n:
            i += 2
            continue
        if quoting is None and c in "'\"":
            quoting = c
        elif c == quoting:
            quoting = None
        i += 1
    return i


def strip_redirections(cmd):
    """cmd without its redirections: an unquoted operator (>f, > f, 2>f, &>f, <f, N>&M, <>f,
    >|f, <<<, a here-document marker) and its operand, split off the word it touches
    (git>log merge is git, then merge). A redirection changes where input and output go,
    never what runs, so the gate reads past it wherever it stands, before the command word
    and between arguments alike. Quoted text is left alone."""
    out, i, n, quoting = [], 0, len(cmd), None
    while i < n:
        c = cmd[i]
        if quoting is None:
            starts_word = i == 0 or cmd[i - 1] in " \t\n;&|()"
            m = (REDIRECT_RE if starts_word else REDIRECT_MID_RE).match(cmd, i)
            if m:
                j = m.end()
                while j < n and cmd[j] in " \t":
                    j += 1
                out.append(" ")
                i = skip_word(cmd, j)
                continue
        out.append(c)
        if c == "\\" and quoting != "'" and i + 1 < n:
            out.append(cmd[i + 1])
            i += 2
            continue
        if quoting is None and c in "'\"":
            quoting = c
        elif c == quoting:
            quoting = None
        i += 1
    return "".join(out)


def tokenize(cmd):
    """Shell words and operator tokens, with here-document bodies, comments and redirections
    dropped. Raises ValueError on unbalanced quotes."""
    text = strip_redirections(strip_comments(split_heredocs(cmd)[0].replace("\\\n", " ")))
    lx = shlex.shlex(text, posix=True, punctuation_chars=PUNCT)
    lx.whitespace = " \t\r"          # a newline separates commands; it is not a blank
    lx.whitespace_split = True
    lx.commenters = ""
    return list(lx)


def is_operator(tok):
    return bool(tok) and all(c in PUNCT for c in tok)


def starts_command(tok):
    """An operator after which a new command begins: a separator, a pipe, a subshell or a
    process substitution."""
    return is_operator(tok) and ("(" in tok or ("<" not in tok and ">" not in tok))


def command_words(tokens):
    """Indexes of the words that may run as a command: the first word of each simple command,
    after VAR=value assignments and reserved words, and - after a wrapper (command, env, sudo,
    time, xargs, ...) - every later word of that command. A wrapper's options can take an
    argument (sudo -u root git merge ...), so which word it runs cannot be read from the text."""
    out, i, n, at = [], 0, len(tokens), True
    while i < n:
        t = tokens[i]
        if starts_command(t):
            at = True
        elif not is_operator(t) and at:
            if ASSIGN_RE.match(t) or t in RESERVED:
                pass
            elif os.path.basename(t) in WRAPPERS:
                j = i + 1
                while j < n and not is_operator(tokens[j]):
                    out.append(j)
                    j += 1
                at = False
                i = j
                continue
            else:
                out.append(i)
                at = False
        i += 1
    return out


def segment(tokens, k):
    """The words of the simple command whose command word is at k."""
    end = k
    while end < len(tokens) and not is_operator(tokens[end]):
        end += 1
    return tokens[k:end]


def literal(word):
    """Is this word what the program receives: no variable and no command substitution?"""
    return word is not None and "$" not in word and "`" not in word


# ------------------------------------------------------------------ the gated verbs
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env",
                  "--super-prefix"}
FORGE_VALUE_OPTS = {"-R", "--repo"}
HELP = {"--help", "-h"}
MERGE_CONTROL = {"--abort", "--quit", "--continue"}
CLI_VERBS = {
    ("glab", "mr", "create"): "create", ("glab", "mr", "new"): "create",
    ("glab", "mr", "merge"): "merge", ("glab", "mr", "accept"): "merge",
    ("gh", "pr", "create"): "create", ("gh", "pr", "new"): "create",
    ("gh", "pr", "merge"): "merge",
}
MUTATIONS = re.compile(r"\b(mergeRequestCreate|mergeRequestAccept|mergeRequestSetAutoMerge|"
                       r"createPullRequest|mergePullRequest|enablePullRequestAutoMerge)\b")
NAMES_MR_PATH = re.compile(r"(^|/)(merge_requests|pulls)(/|$)")
API_VALUE = {"-X", "--method", "-f", "--raw-field", "-F", "--field", "--form", "-H", "--header",
             "--input", "--hostname", "-q", "--jq", "-t", "--template", "--cache", "-p",
             "--preview", "--output"}
API_FIELD = {"-f": False, "--raw-field": False, "-F": True, "--field": True, "--form": True}


def skip_options(words, i, value_opts):
    while i < len(words) and words[i].startswith("-") and words[i] != "-":
        i += 2 if words[i] in value_opts else 1
    return i


def parse_api(args):
    """The parts of a glab/gh api call the gate reads: endpoint, method (the CLIs' default:
    POST once a field or a body is given, GET otherwise), fields (name -> last value), body
    (True when the body or a typed field comes from a file or stdin) and hostname."""
    call = {"endpoint": None, "method": None, "fields": {}, "body": False, "hostname": None}
    i, n = 0, len(args)
    while i < n:
        a, name, value = args[i], None, None
        if a.startswith("--") and len(a) > 2:
            name, eq, value = a.partition("=")
            if name in API_VALUE and not eq:
                i += 1
                value = args[i] if i < n else ""
        elif a.startswith("-") and len(a) > 1:
            name = a[:2]
            if name in API_VALUE:
                if len(a) > 2:
                    value = a[2:]
                else:
                    i += 1
                    value = args[i] if i < n else ""
        elif call["endpoint"] is None:
            call["endpoint"] = a
        if name in ("-X", "--method"):
            call["method"] = (value or "").upper()
        elif name in API_FIELD:
            key, _, val = (value or "").partition("=")
            if API_FIELD[name] and val.startswith("@"):
                call["body"] = True
            call["fields"][key] = val
        elif name == "--input":
            call["body"] = True
        elif name == "--hostname":
            call["hostname"] = value
        i += 1
    if call["method"] is None:
        call["method"] = "POST" if call["fields"] or call["body"] else "GET"
    return call


def endpoint_parts(endpoint):
    """(path, query fields) of an api endpoint, a scheme and host and an api/v3 or api/v4
    prefix dropped."""
    if "://" in endpoint:
        parts = urlsplit(endpoint)
        path, query = parts.path, parts.query
    else:
        path, _, query = endpoint.partition("?")
    path = re.sub(r"^api/v[34]/", "", path.strip("/"))
    return path, dict(parse_qsl(query, keep_blank_values=True))


def is_graphql(endpoint):
    """graphql, or an absolute URL whose path ends in /graphql."""
    return endpoint_parts(endpoint)[0].split("/")[-1] == "graphql"


def api_gated(call):
    """A GraphQL call carrying an MR/PR create, merge or auto-merge mutation, or a query the
    gate cannot read; or a POST, PUT or PATCH to a path naming merge_requests or pulls."""
    endpoint = call["endpoint"] or ""
    if is_graphql(endpoint):
        return call["body"] or bool(MUTATIONS.search(" ".join(call["fields"].values())))
    path, _ = endpoint_parts(endpoint)
    return call["method"] in ("POST", "PUT", "PATCH") and bool(NAMES_MR_PATH.search(path))


def gated_verb(words):
    """The gated verb that words (a command word and its arguments) spell, as {tool, kind,
    args}, or None. kind is merge-local (git merge), create, merge or api; args are the words
    after the verb, with an option written before the noun (glab -R x mr ...) kept in front.
    Help is exempt only as the first word after the verb, and a merge's --abort, --quit or
    --continue only as its sole argument: anywhere else either may be an option's value."""
    if not words:
        return None
    tool, rest = os.path.basename(words[0]), words[1:]
    if tool not in ("git", "glab", "gh"):
        return None
    if tool == "git":
        i = skip_options(rest, 0, GIT_VALUE_OPTS)
        if i < len(rest) and rest[i] == "merge":
            after = rest[i + 1:]
            if after[:1] and after[0] in HELP or len(after) == 1 and after[0] in MERGE_CONTROL:
                return None
            return {"tool": "git", "kind": "merge-local", "args": rest}
        return None
    i = skip_options(rest, 0, FORGE_VALUE_OPTS)
    if i + 1 < len(rest) and (tool, rest[i], rest[i + 1]) in CLI_VERBS:
        if rest[i + 2:i + 3] and rest[i + 2] in HELP:
            return None
        return {"tool": tool, "kind": CLI_VERBS[(tool, rest[i], rest[i + 1])],
                "args": rest[:i] + rest[i + 2:]}
    if i < len(rest) and rest[i] == "api":
        if rest[i + 1:i + 2] and rest[i + 1] in HELP:
            return None
        if api_gated(parse_api(rest[i + 1:])):
            return {"tool": tool, "kind": "api", "args": rest[i + 1:]}
    return None


# ------------------------------------------------------------------ the plain command
def parse_plain(tokens, cwd):
    """The gated verb of a plain command - [cd <literal path> &&] [sudo] <verb> - with the
    directory it runs in; None when the command is anything else."""
    t = list(tokens)
    while t and t[-1] == "\n":
        t.pop()
    while t and t[0] == "\n":
        t.pop(0)
    i = 0
    if len(t) >= 3 and t[0] == "cd" and t[2] == "&&" and not is_operator(t[1]):
        target = os.path.expanduser(t[1])
        if not literal(target) or target == "-":
            return None
        cwd, i = os.path.normpath(os.path.join(cwd, target)), 3
    if i < len(t) and t[i] == "sudo":
        i += 1
    words = t[i:]
    if not words or any(is_operator(w) for w in words):
        return None
    verb = gated_verb(words)
    if verb is not None:
        verb["cwd"] = cwd
    return verb


def parse_flags(args, takes_value):
    """(flags, positionals) of a CLI's arguments. flags maps each option as written (--name or
    -x) to the list of its values: its value when it is in takes_value, else the =value or
    None. A short bundle (-yd) is split, a value-taking short option ending it (-ys feature,
    -sfeature) included. -- ends the options."""
    flags, pos, i, n = {}, [], 0, len(args)
    while i < n:
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a.startswith("--"):
            name, eq, value = a.partition("=")
            if name in takes_value and not eq:
                i += 1
                value = args[i] if i < n else None
            elif not eq:
                value = None
            flags.setdefault(name, []).append(value)
        elif a.startswith("-") and len(a) > 1:
            j = 1
            while j < len(a):
                name = "-" + a[j]
                if name in takes_value:
                    rest = a[j + 1:]
                    rest = rest[1:] if rest.startswith("=") else rest
                    if not rest:
                        i += 1
                        rest = args[i] if i < n else None
                    flags.setdefault(name, []).append(rest)
                    break
                flags.setdefault(name, []).append(None)
                j += 1
        else:
            pos.append(a)
        i += 1
    return flags, pos


# ------------------------------------------------------------------ the repository
def run(argv, cwd=None):
    """stdout of a command, or None when it fails or cannot start."""
    try:
        p = subprocess.run(argv, cwd=cwd, capture_output=True, timeout=CALL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    return p.stdout.decode("utf-8", "replace")


def toplevel(cwd):
    out = run(["git", "-C", cwd, "rev-parse", "--show-toplevel"])
    if not out or not out.strip():
        raise Deny(NO_REPO.format(cwd))
    return out.strip()


# ------------------------------------------------------------------ the decision
def listing(items):
    return "; ".join(items) if items else "nothing"


def check(ledger, top, source, dest, dest_rev, tip, dispatch_range, merge_hint):
    """Allow (return) when the ledger approves tip landing on dest; deny otherwise, naming the
    change, what is on record, and the dispatch that opens the gate."""
    d = ledger.decide(top, dest, dest_rev, tip, branch=source)
    if d["allow"]:
        return
    text = ("Pre-merge gate: {reason}.\n\n"
            "The change: {repo}, {source} -> {dest}, tip {tip}, fingerprint {fp}.\n"
            "On record for this change: {change}.\n"
            "On record for branch {source}: {branch}.\n\n"
            "A change lands only when the latest full-range pre-merge review of exactly this "
            "change approves it: a newer pending review, a newer verdict of changes, a partial "
            "range, or a spec or plan review never opens the gate. Run the cross-review skill, "
            "or:\n\n"
            "    xreview dispatch --checkpoint pre-merge --diff {rng} <body-file>\n"
            "    xreview collect <nonce>").format(
                reason=d["reason"], repo=d["repo"] or "(no repository)", source=source,
                dest=dest, tip=d["tip"] or tip, fp=d["fingerprint"] or "(none)",
                change=listing(d["on_record"]), branch=listing(d["on_record_branch"]),
                rng=dispatch_range)
    if merge_hint:
        text += "\n\nThen merge it pinned and immediate: " + merge_hint
    raise Deny(text)


# ------------------------------------------------------------------ git merge
GIT_FLAGS = {"-p", "-P", "--paginate", "--no-pager", "--no-replace-objects",
             "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs",
             "--icase-pathspecs", "--no-optional-locks", "--no-advice", "--no-lazy-fetch"}
MERGE_VALUE = {"-m", "-F", "-s", "-X", "--message", "--file", "--strategy",
               "--strategy-option", "--into-name"}


def judge_git_merge(shape, ledger):
    """git [-C <path>]... merge <ref>: gated only while the repository's current branch is its
    default branch; the change is <ref>, landing on that branch's HEAD."""
    args, cwd, i = shape["args"], shape["cwd"], 0
    while i < len(args) and args[i] != "merge":
        if args[i] == "-C" and i + 1 < len(args):
            if not literal(args[i + 1]):
                raise Deny(LITERAL.format("the -C path", args[i + 1]))
            cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(args[i + 1])))
            i += 2
        elif args[i] in GIT_FLAGS:
            i += 1
        else:
            raise Deny(PLAIN)
    top = toplevel(cwd)
    dest = ledger.default_branch(top)
    if ledger.current_branch(top) != dest:
        return
    _, refs = parse_flags(args[i + 1:], MERGE_VALUE)
    if len(refs) != 1:
        raise Deny(ONE_REF)
    ref = refs[0]
    if not literal(ref) or ref.startswith("-"):
        raise Deny(LITERAL.format("the merged ref", ref))
    source = ref[len("origin/"):] if ref.startswith("origin/") else ref
    check(ledger, top, source, dest, "HEAD", ref, "{}...{}".format(dest, ref), None)


def judge(shape, ledger):
    if shape["kind"] == "merge-local":
        return judge_git_merge(shape, ledger)
    raise Deny(NOT_MODELLED)


# ------------------------------------------------------------------ main
CRUDE = re.compile(r"\b(glab|gh)\b[^\n]*\b(mr|pr|api)\b|\bgit\b[^\n]*\bmerge\b")


def on_alarm(signum, frame):
    raise Deny(TIMED_OUT)


def load_ledger():
    spec = importlib.util.spec_from_file_location("xreview_ledger", LEDGER_PATH)
    if spec is None or spec.loader is None:
        raise Deny("Pre-merge gate: the ledger helper {} cannot be loaded, so the command is "
                   "refused. Restore it (chezmoi apply).".format(LEDGER_PATH))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.CALL_TIMEOUT = CALL_TIMEOUT
    return module


def main():
    try:
        payload = json.load(sys.stdin)
        cmd = payload.get("tool_input", {}).get("command") or ""
        cwd = payload.get("cwd") or os.getcwd()
    except (ValueError, AttributeError):
        return
    # The bypass is read from the command, the only place a model can write it.
    if not isinstance(cmd, str) or not cmd or "XREVIEW_GUARD=off" in cmd:
        return
    signal.signal(signal.SIGALRM, on_alarm)
    signal.alarm(BUDGET)
    gated = False
    try:
        try:
            tokens = tokenize(cmd)
        except ValueError:
            if CRUDE.search(cmd):
                raise Deny(UNPARSEABLE)
            return
        # A gated verb run by a substitution is never part of a plain command.
        hidden = gated_in_substitution(cmd)
        gated = hidden or any(gated_verb(segment(tokens, k)) for k in command_words(tokens))
        if not gated:
            return
        shape = None if hidden else parse_plain(tokens, cwd)
        if shape is None:
            raise Deny(PLAIN)
        judge(shape, load_ledger())
    except Deny as d:
        print(decision(str(d)))
    except Exception as e:                             # a bug here must not open the gate
        if gated or CRUDE.search(cmd):
            print(decision("Pre-merge gate: internal error ({}: {}), so the command is "
                           "refused.".format(type(e).__name__, e)))
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Write the shell front.** Replace the whole content of
  `dot_claude/executable_xreview-guard.sh` with the text below. Its header drops the old "the
  receipt is advisory about freshness" rationale (§3.7).

```bash
#!/usr/bin/env bash
# PreToolUse(Bash) guard for the pre-merge cross-review gate.
#
# Enforces the one part of the cross-review workflow that prose cannot: that nothing is
# proposed or merged without an approving pre-merge Codex review of exactly that change. A
# skipped review is otherwise indistinguishable from one that found nothing.
# Design: docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md, section 3.6.
#
# Gated: MR/PR creation and agent-run merges - glab mr create|new|merge|accept, gh pr
# create|new|merge, their REST forms through glab api / gh api, GraphQL mutations that create
# or merge (denied outright), and a local git merge into the default branch. Each opens only
# when the latest full-range pre-merge review of that exact change, for that destination,
# approved it. The change is named by a content fingerprint, so any content change after the
# approval closes the gate again, while a clean rebase keeps it open. The receipts live in one
# ledger per repository, shared by all its worktrees (xreview-ledger.py beside this file).
#
# This shell front is the fast path. The hook fires on EVERY Bash call, so a payload that
# names none of create, new, merge, accept, pulls or graphql, or none of glab, gh or git,
# costs no subprocess at all. Everything else goes to xreview-guard.py beside this file,
# which owns the grammar and the checks and fails closed on a gated shape.
#
# The bypass is XREVIEW_GUARD=off, for Michael's explicit use only: in this hook's
# environment, or anywhere in the command (the only place a model can write it).
#
# Bash 3.2 compatible (macOS system bash).
set -uo pipefail
set -f

[ "${XREVIEW_GUARD:-}" = "off" ] && exit 0

payload=$(cat)
[ -n "$payload" ] || exit 0

case "$payload" in
  *create*|*new*|*merge*|*accept*|*pulls*|*graphql*) ;;
  *) exit 0 ;;
esac
case "$payload" in
  *glab*|*gh*|*git*) ;;
  *) exit 0 ;;
esac

py=/usr/bin/python3
[ -x "$py" ] || py=python3
helper="$(dirname "$0")/xreview-guard.py"
verdict=$(printf '%s' "$payload" | "$py" "$helper" 2>/dev/null)
rc=$?
if [ -n "$verdict" ]; then
  printf '%s\n' "$verdict"
  exit 0
fi
[ "$rc" -eq 0 ] && exit 0

# The helper could not run at all. FAIL DIRECTION IS CLOSED for a command that may propose or
# merge: glab/gh with mr, pr or api, or git with merge, in its text. Anything else is allowed.
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || cmd=$payload
case "$cmd" in *XREVIEW_GUARD=off*) exit 0 ;; esac
if printf '%s' "$cmd" | grep -Eq '(glab|gh)[[:space:]]+([^;&|]*[[:space:]])?(mr|pr|api)([[:space:]]|$)|git[[:space:]]+([^;&|]*[[:space:]])?merge([[:space:]]|$)'; then
  reason="Pre-merge gate: the gate's check could not run ($helper exited $rc), so this command, which may propose or merge a change, is refused. Restore the helper (chezmoi apply)."
  printf '%s' "$reason" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' 2>/dev/null \
    || printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Pre-merge gate: the check could not run, so this command is refused."}}'
fi
exit 0
```

- [ ] **Step 6: Allowlist the guard, and give its hook a limit.**
  - Apply this to `.chezmoiignore`:

Edit 1 - replace:

```text
!.claude/xreview-guard.sh
```

with:

```text
!.claude/xreview-guard.sh
!.claude/xreview-guard.py
```

  - Apply this to `dot_claude/modify_private_settings.json`:

Edit 1 - replace:

```text
              { "type": "command", "command": "bash $HOME/.claude/xreview-guard.sh" }
```

with:

```text
              { "type": "command", "command": "bash $HOME/.claude/xreview-guard.sh", "timeout": 60 }
```

Edit 2 - replace:

```text
        # Third entry: the cross-review guard. Denies proposing a branch for merge with
        # no Codex review on record; a skipped review looks identical to a clean one.
```

with:

```text
        # Third entry: the cross-review guard. Denies proposing or merging a change that no
        # approving pre-merge Codex review of it is on record for; a skipped review looks
        # identical to a clean one. It reads origin and the forge, and gives up at 40 s inside
        # an explicit 60 s limit, so a slow forge is a deny rather than a fall-through.
```

- [ ] **Step 7: Run them and confirm they pass.**
  - `./tests/xreview-guard.test.sh`: expect `passed: 95  failed: 0`.
  - `./tests/xreview-skill.test.sh`: expect `passed: 76  failed: 0`.
  - `./tests/claude-settings.test.sh 2>&1 | tail -1`: expect `RESULT: 179 passed, 0 failed`.

- [ ] **Step 8: Commit.** Check the branch, then:

```bash
git add dot_claude/xreview-guard.py dot_claude/executable_xreview-guard.sh tests/xreview-guard.test.sh .chezmoiignore dot_claude/modify_private_settings.json tests/claude-settings.test.sh tests/xreview-skill.test.sh
git commit -m "Gate a git merge into the default branch on the exact change's approval"
```

## Task 7: The guard: creating an MR/PR

**Files:**
- Modify: `dot_claude/xreview-guard.py`
- Modify: `tests/xreview-guard.test.sh`

**Interfaces:**
- Consumes (Task 6): `parse_flags`, `run`, `toplevel`, `check`, `parse_api`, `endpoint_parts`,
  `is_graphql`, `literal`, `Deny`, and the messages `LITERAL`, `NO_REPO` and `NOT_MODELLED`.
- Produces:
  - `one(flags, names, label) -> str | None`;
  - `split_url(url) -> (host, path)`; `same_project(named, host, path, tool) -> bool`: a
    URL or scp-style address must name origin's host and path; otherwise the value must be
    origin's path, or for gh also `<origin host>/<path>`;
  - `explicit_repo(tool, host, path) -> str`: the `-R` value that carries origin's host;
  - `forge_context(cwd, named, tool) -> (toplevel, host, path)`;
  - `remote_head(top, branch) -> str`;
  - `flag_on(values) -> bool`;
  - `field(fields, name, top, ledger) -> str | None`;
  - `lookup_json(argv, top, what)`;
  - `origin_host(cwd) -> str`; `host_of(value) -> str`; `set_values(names) -> list`;
    `config_dir(variable, name)`; `top_level(path) -> list | None`, the top-level
    `(key, value)` lines of a YAML file, indented lines unread;
  - `gh_default_host() -> str | None`: `GH_HOST`, else the one top-level key of gh's
    `hosts.yml`, else `github.com`; `None` when that file cannot be read;
  - `glab_default_hosts(top) -> list | None`: every set `GITLAB_HOST`, `GITLAB_URI`,
    `GL_HOST` and `GITLAB_URL` (`GLAB_HOST_VARS`), else the `host` keys (`GLAB_HOST_KEYS`)
    of the global and the repository's `glab-cli/config.yml`, else `gitlab.com`;
  - `remote_hosts(top) -> set | None`, from `git remote -v`;
  - `check_api_host_var(host)`: a set `GITLAB_API_HOST` must be origin's host (message
    `API_HOST_VAR`);
  - `check_api_host(cwd, tool, call) -> str`: the host the call goes to must be origin's.
    That is the absolute endpoint's host (`api.<host>` accepted) and any `--hostname`;
    without either, `gh_default_host()` for gh, and for glab every set `GLAB_HOST_VARS`, or,
    with none set, every remote's host. Returns origin's host, which every lookup the command
    needs is then given. Messages `OTHER_HOST` (it names `--hostname <origin host>`),
    `SEVERAL_HOSTS` and `UNREADABLE`;
  - `env_repo(tool) -> str | None`: `GITLAB_REPO` or `GH_REPO`, the project a verb takes
    without `-R`;
  - `check_cli_host(tool, top, host, path, named) -> str`: a `glab`/`gh` verb's own host
    must be origin's; a bare `-R OWNER/REPO` (or `env_repo`) takes the CLI's default host
    (message `DEFAULT_HOST`, naming `-R` with `explicit_repo`);
  - `gitlab_project(cwd, segment, hostname)`, which looks a numeric id up on `hostname`,
    and `github_project(cwd, owner, repo)`; placeholders take `env_repo`;
  - `judge_create_cli`, `judge_create_gitlab_api(shape, ledger, segment, fields, host)`,
    `judge_create_github_api(shape, ledger, owner, repo, fields)` and `judge_api`.
    Until Task 8, `judge_api` checks the create endpoints only and denies the rest;
  - the constants `FALSE`, `FULL_ID`, `GITLAB_MR`, `GITHUB_PR` and
    `BRANCH_PLACEHOLDERS`.

- [ ] **Step 1: Write the failing test.** Insert this block into `tests/xreview-guard.test.sh`
  immediately above the line `printf '\npassed: %d  failed: %d\n' "$pass" "$fail"`:

```bash
echo "H. creating an MR/PR"
# glab answers the one lookup creation makes, a numeric project id; anything else fails, so an
# unexpected call shows up as a deny rather than passing silently. The host a call reaches is
# its --hostname, else glab's host variables, else origin's; on another host, project 4242 is
# ELSEWHERE_PATH.
STUB="$ROOT/stub"; mkdir -p "$STUB"
cat > "$STUB/glab" <<'SH'
#!/bin/sh
printf 'glab %s\n' "$*" >> "$CALLS"
host="${GITLAB_HOST:-${GITLAB_URI:-${GL_HOST:-forge.example}}}"
if [ "$1" = api ] && [ "$2" = --hostname ]; then host="$3"; shift 3; set -- api "$@"; fi
path="${PROJECT_PATH:-acme/app}"
[ "$host" = forge.example ] || path="${ELSEWHERE_PATH:-$path}"
case "$*" in
  "api projects/4242") printf '{"id":4242,"path_with_namespace":"%s"}\n' "$path" ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\nprintf "gh %%s\\n" "$*" >> "$CALLS"\nexit 1\n' > "$STUB/gh"
chmod +x "$STUB/glab" "$STUB/gh"
export PATH="$STUB:$PATH"
FW="$ROOT/work/app-feature"; git -C "$W" worktree add -q "$FW" feature
is "H1 a branch not yet on origin is denied" "$(decision "$W" 'glab mr create --source-branch feature --target-branch main --fill --yes')" deny
is "H2 saying to publish it" "$(reason "$W" 'glab mr create -s feature -b main' | grep -c 'is not on origin')" 1
publish feature
is "H3 glab mr create, approved" "$(decision "$W" 'glab mr create -s feature -b main --fill --yes')" allow
is "H4 glab mr new, = forms" "$(decision "$W" 'glab mr new --source-branch=feature --target-branch=main')" allow
is "H5 gh pr create" "$(decision "$W" 'gh pr create --head feature --base main --title "Land feature" --body-file /tmp/body.md')" allow
is "H6 gh pr new, short flags" "$(decision "$W" 'gh pr new -H feature -B main')" allow
is "H7 the source defaults to the current branch" "$(decision "$FW" 'glab mr create --target-branch main --fill')" allow
is "H8 a # inside a quoted title is a value, not a comment" "$(decision "$W" 'glab mr create --title "Land it # 12" -s feature -b main')" allow
is "H9 the GitLab REST create" "$(decision "$W" 'glab api -X POST projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main -f title=x')" allow
is "H10 by numeric project id, POST implied by the fields" "$(decision "$W" 'glab api projects/4242/merge_requests -f source_branch=feature -f target_branch=main')" allow
is "H11 by the :id placeholder, the source as :branch" "$(decision "$FW" 'glab api --method POST projects/:id/merge_requests -F source_branch=:branch -f target_branch=main')" allow
is "H12 the GitHub REST create" "$(decision "$W" 'gh api repos/acme/app/pulls -f head=feature -f base=main -f title=x')" allow
is "H13 with the {owner}/{repo} placeholders and an owner:branch head" "$(decision "$W" "gh api -X POST 'repos/{owner}/{repo}/pulls' -f head=acme:feature -f base=main")" allow
is "H14 -R naming origin's project" "$(decision "$W" 'gh pr create -R acme/app --head feature --base main')" allow
is "H15 gh -R with the host" "$(decision "$W" 'gh pr create -R forge.example/acme/app --head feature --base main')" allow
is "H16 -R as a URL" "$(decision "$W" 'glab mr create -R https://forge.example/acme/app.git -s feature -b main')" allow
is "H17 cd <path> && glab mr create is checked in that path" "$(decision "$ROOT/norepo" "cd $W && glab mr create -s feature -b main")" allow

echo "I. the destination is part of the approval"
git -C "$W" branch release main && publish release
is "I1 the same change proposed into another branch is denied" "$(decision "$W" 'glab mr create -s feature -b release')" deny
r="$(reason "$W" 'glab mr create -s feature -b release')"
is "I2 because nothing on record approves it there" "$(printf '%s' "$r" | grep -c 'no full-range pre-merge review of this change is on record')" 1
rng="$(printf '%s\n' "$r" | sed -n 's/.*--diff \([^ ]*\) <body-file>.*/\1/p')"
is "I3 the deny names the range against origin's destination" "$rng" "origin/release...feature"
review "$W" "$rng" approve
is "I4 and that dispatch, run as named, opens the gate" "$(decision "$W" 'glab mr create -s feature -b release')" allow
is "I5 a CLI creation without --target-branch is denied" "$(decision "$W" 'glab mr create -s feature --fill')" deny
is "I6 naming the flag" "$(reason "$W" 'glab mr create -s feature --fill' | grep -c -- '--target-branch')" 1
is "I7 gh without --base is denied" "$(decision "$W" 'gh pr create --head feature --fill')" deny
is "I8 naming the flag" "$(reason "$W" 'gh pr create --head feature --fill' | grep -c -- '--base')" 1
is "I9 --target-branch twice is denied" "$(decision "$W" 'glab mr create -s feature -b main -b release')" deny
is "I10 glab mr create --auto-merge is a deferred merge" "$(decision "$W" 'glab mr create -s feature -b main --auto-merge')" deny
is "I11 a destination origin does not have is denied" "$(decision "$W" 'glab mr create -s feature -b ghost')" deny
is "I12 saying to fetch" "$(reason "$W" 'glab mr create -s feature -b ghost' | grep -c 'not available locally; fetch it')" 1
is "I13 a source in a variable is denied" "$(decision "$W" 'glab mr create -s "$BRANCH" -b main')" deny

echo "J. creation reads the remote head"
printf 'five\n' >> "$FW/b.txt"; git -C "$FW" commit -q -am "an unreviewed change"
publish feature                                   # origin now holds an unreviewed head
printf 'six\n' >> "$FW/b.txt"; git -C "$FW" commit -q -am "fixed locally"
review "$W" main...feature approve                # only the local head is approved
is "J1 a creation whose remote head differs from the approved local branch is denied" "$(decision "$W" 'glab mr create -s feature -b main')" deny
publish feature
is "J2 once origin has the approved head, it is allowed" "$(decision "$W" 'glab mr create -s feature -b main')" allow
OTHER="$ROOT/other"; git clone -q "$ORIGIN" "$OTHER"
git -C "$OTHER" switch -q -c remote-only; printf 'r\n' > "$OTHER/r.txt"; git -C "$OTHER" add r.txt; git -C "$OTHER" commit -q -m "remote only"
git -C "$ORIGIN" fetch -q "$OTHER" +refs/heads/remote-only:refs/heads/remote-only
is "J3 a remote head that is not available locally is denied" "$(decision "$W" 'glab mr create -s remote-only -b main')" deny
is "J4 saying to fetch" "$(reason "$W" 'glab mr create -s remote-only -b main' | grep -c 'not available locally; fetch it')" 1

echo "K. the project and forks"
is "K1 -R naming another project is denied" "$(decision "$W" 'glab mr create -R other/app -s feature -b main')" deny
is "K2 saying to run from its checkout" "$(reason "$W" 'glab mr create -R other/app -s feature -b main' | grep -c "Run it from that project's checkout")" 1
is "K3 an API path naming another project" "$(decision "$W" 'glab api -X POST projects/other%2Fapp/merge_requests -f source_branch=feature -f target_branch=main')" deny
is "K4 a GitHub fork head" "$(decision "$W" 'gh pr create --head someone:feature --base main')" deny
is "K5 a glab head repository" "$(decision "$W" 'glab mr create -H someone/app -s feature -b main')" deny
is "K6 a GitLab target_project_id" "$(decision "$W" 'glab api -X POST projects/:id/merge_requests -f source_branch=feature -f target_branch=main -f target_project_id=9')" deny
git -C "$W" remote add upstream 'git@forge.example:upstream/app.git'
is "K7 several remotes and no project named is denied" "$(decision "$W" 'gh pr create --head feature --base main')" deny
is "K8 naming origin's project with -R is allowed" "$(decision "$W" 'gh pr create -R acme/app --head feature --base main')" allow
git -C "$W" remote remove upstream
is "K9 outside a repository, creation is denied" "$(decision "$ROOT/norepo" 'gh pr create --head feature --base main')" deny
is "K10 -R naming another host is denied" "$(decision "$W" 'gh pr create -R evil.example/acme/app --head feature --base main')" deny
is "K11 -R as a URL on another host is denied" "$(decision "$W" 'glab mr create -R https://evil.example/acme/app -s feature -b main')" deny
is "K12 glab api --hostname on another host is denied" \
   "$(decision "$W" 'glab api --hostname evil.example -X POST projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main')" deny
is "K13 gh api --hostname on another host is denied" \
   "$(decision "$W" 'gh api --hostname evil.example repos/acme/app/pulls -f head=feature -f base=main')" deny
is "K14 glab api --hostname naming origin's host is allowed" \
   "$(decision "$W" 'glab api --hostname forge.example -X POST projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main')" allow
is "K15 and gh api" "$(decision "$W" 'gh api --hostname forge.example repos/acme/app/pulls -f head=feature -f base=main')" allow
is "K16 an absolute GitLab endpoint on another host is denied" \
   "$(decision "$W" 'glab api -X POST https://evil.example/api/v4/projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main')" deny
is "K17 an absolute GitHub endpoint on another host is denied" \
   "$(decision "$W" 'gh api -X POST https://evil.example/api/v3/repos/acme/app/pulls -f head=feature -f base=main')" deny
is "K18 an absolute endpoint on origin's host is allowed" \
   "$(decision "$W" 'gh api -X POST https://forge.example/api/v3/repos/acme/app/pulls -f head=feature -f base=main')" allow
# Without --hostname, gh api goes to GH_HOST, else to the one host gh's hosts.yml lists, else to
# github.com; glab api to GITLAB_HOST, GITLAB_URI or GITLAB_URL, else to a remote's host.
GHCREATE='gh api repos/acme/app/pulls -f head=feature -f base=main'
GLCREATE='glab api -X POST projects/acme%2Fapp/merge_requests -f source_branch=feature -f target_branch=main'
is "K19 gh api with no GH_HOST goes to github.com, not origin's host" "$(GH_HOST= decision "$W" "$GHCREATE")" deny
is "K20 the deny names origin's host to pass" "$(GH_HOST= reason "$W" "$GHCREATE" | grep -c -- '--hostname forge.example')" 1
is "K21 a stray GH_HOST is denied" "$(GH_HOST=github.example decision "$W" "$GHCREATE")" deny
is "K22 --hostname naming origin's host outranks it" "$(GH_HOST=github.example decision "$W" "gh api --hostname forge.example ${GHCREATE#gh api }")" allow
mkdir -p "$GH_CONFIG_DIR"; printf 'forge.example:\n    user: t\n    git_protocol: ssh\n' > "$GH_CONFIG_DIR/hosts.yml"
is "K23 gh's one configured host is its default" "$(GH_HOST= decision "$W" "$GHCREATE")" allow
printf 'github.com:\n    user: t\n' >> "$GH_CONFIG_DIR/hosts.yml"
is "K24 with two, the default is github.com again" "$(GH_HOST= decision "$W" "$GHCREATE")" deny
# The same with origin on github.com: gh's one configured host elsewhere takes the call there.
git -C "$W" config --add "url.$ORIGIN.insteadOf" 'git@github.com:acme/app.git'
git -C "$W" remote set-url origin 'git@github.com:acme/app.git'
printf 'forge.example:\n    user: t\n' > "$GH_CONFIG_DIR/hosts.yml"
is "K25 an origin on github.com, and gh's one configured host elsewhere" "$(GH_HOST= decision "$W" "$GHCREATE")" deny
printf 'github.com:\n    user: t\n' > "$GH_CONFIG_DIR/hosts.yml"
is "K26 and that one host github.com" "$(GH_HOST= decision "$W" "$GHCREATE")" allow
git -C "$W" remote set-url origin 'git@forge.example:acme/app.git'
git -C "$W" config --unset "url.$ORIGIN.insteadOf" 'github'
rm "$GH_CONFIG_DIR/hosts.yml"
git -C "$W" remote add mirror 'git@forge.example:acme/app-mirror.git'
is "K27 glab api with every remote on origin's host" "$(decision "$W" "$GLCREATE")" allow
is "K28 GITLAB_HOST on another host is denied" "$(GITLAB_HOST=gitlab.com decision "$W" "$GLCREATE")" deny
is "K29 so is GITLAB_URL" "$(GITLAB_URL=https://gitlab.com decision "$W" "$GLCREATE")" deny
is "K30 GITLAB_URI naming origin's host is allowed" "$(GITLAB_URI=https://forge.example decision "$W" "$GLCREATE")" allow
is "K31 --hostname naming origin's host outranks a stray GITLAB_HOST" \
   "$(GITLAB_HOST=gitlab.com decision "$W" "glab api --hostname forge.example ${GLCREATE#glab api }")" allow
git -C "$W" remote set-url mirror 'git@gitlab.com:acme/app.git'
is "K32 a remote on another host is denied" "$(decision "$W" "$GLCREATE")" deny
is "K33 naming origin's host to pass" "$(reason "$W" "$GLCREATE" | grep -c -- '--hostname forge.example')" 1
is "K34 --hostname naming origin's host is allowed" "$(decision "$W" "glab api --hostname forge.example ${GLCREATE#glab api }")" allow
git -C "$W" remote remove mirror
# A CLI verb reaches the host its -R names. A bare OWNER/REPO, GH_REPO or GITLAB_REPO takes the
# CLI's default host, which must be origin's too.
is "K35 gh -R without a host, gh's default host elsewhere" \
   "$(GH_HOST=github.example decision "$W" 'gh pr create -R acme/app --head feature --base main')" deny
is "K36 naming the host-qualified -R to pass" \
   "$(GH_HOST=github.example reason "$W" 'gh pr create -R acme/app --head feature --base main' | grep -c -- '-R forge.example/acme/app')" 1
is "K37 glab -R without a host, glab's default host gitlab.com" \
   "$(GLAB_CONFIG_DIR="$ROOT/glab-none" decision "$W" 'glab mr create -R acme/app -s feature -b main')" deny
is "K38 glab's config naming origin's host" "$(decision "$W" 'glab mr create -R acme/app -s feature -b main')" allow
is "K39 a host variable outranks the config" "$(GITLAB_HOST=gitlab.com decision "$W" 'glab mr create -R acme/app -s feature -b main')" deny
mkdir -p "$W/.git/glab-cli" && printf 'host: gitlab.com\n' > "$W/.git/glab-cli/config.yml"
is "K40 so does the repository's own glab config" "$(decision "$W" 'glab mr create -R acme/app -s feature -b main')" deny
rm -r "$W/.git/glab-cli"
is "K41 GH_REPO naming another project is denied" "$(GH_REPO=other/app decision "$W" 'gh pr create --head feature --base main')" deny
is "K42 so is GITLAB_REPO" "$(GITLAB_REPO=other/app decision "$W" 'glab mr create -s feature -b main')" deny
is "K43 GH_REPO naming origin's project is allowed" "$(GH_REPO=acme/app decision "$W" 'gh pr create --head feature --base main')" allow
is "K44 GITLAB_API_HOST on another host is denied" "$(GITLAB_API_HOST=api.other.example decision "$W" 'glab mr create -s feature -b main')" deny
is "K45 for an api call too" "$(GITLAB_API_HOST=api.other.example decision "$W" "$GLCREATE")" deny
is "K46 glab reads -R HOST/PATH as a group path on its default host: another project" \
   "$(decision "$W" 'glab mr create -R forge.example/acme/app -s feature -b main')" deny
# A numeric project id is looked up on origin's host, never on the host the environment picks.
is "K47 a project id is looked up on origin's host" \
   "$(GITLAB_HOST=other.example PROJECT_PATH=other/app ELSEWHERE_PATH=acme/app decision "$W" 'glab api -X POST https://forge.example/api/v4/projects/4242/merge_requests -f source_branch=feature -f target_branch=main')" deny

```

- [ ] **Step 2: Run it and confirm it fails.** `./tests/xreview-guard.test.sh`: expect
  `passed: 135  failed: 41`. Every allow case in H-K fails, and so do the deny reasons naming a
  flag, a fetch, a project or a host, because each creation is still denied with
  `NOT_MODELLED`.

- [ ] **Step 3: Add the messages.** In `dot_claude/xreview-guard.py`, insert this block
  immediately above the line that starts `NOT_MODELLED = `:

```python
ONCE = "Pre-merge gate: name {} once."
NO_ORIGIN = ("Pre-merge gate: {} has no origin remote, so the forge project cannot be checked. "
             "Run the command from the project's own checkout.")
OTHER_PROJECT = ("Pre-merge gate: the command acts on the project {} (named by -R, or by GH_REPO or "
                 "GITLAB_REPO in the environment), but this checkout's origin is {}. Run it from "
                 "that project's checkout.")
OTHER_HOST = ("Pre-merge gate: this call goes to {0}, but this checkout's origin is on {1}. Send "
              "it to origin's host, --hostname {1}, from that project's checkout.")
SEVERAL_HOSTS = ("Pre-merge gate: without --hostname, glab api picks its host from this "
                 "checkout's remotes, and some are on another host than origin's ({0}). Name "
                 "origin's host: --hostname {1}.")
DEFAULT_HOST = ("Pre-merge gate: {0} names no host, so the CLI sends this to its default host, "
                "{1}, but this checkout's origin is on {2}. Name origin's host: {3}.")
API_HOST_VAR = ("Pre-merge gate: GITLAB_API_HOST sends glab's API requests to {0}, not to "
                "origin's host {1}, so the gate cannot check what this command does. Run it "
                "without GITLAB_API_HOST.")
UNREADABLE = ("Pre-merge gate: {0} cannot be read, so the host this call goes to is unknown. "
              "Name origin's host: {1}.")
SEVERAL_REMOTES = ("Pre-merge gate: this checkout has remotes besides origin ({}), so the CLI "
                   "could pick another project. Name origin's project explicitly: -R {}.")
FORK = ("Pre-merge gate: {} proposes from another repository. Merge requests from forks are not "
        "checked by the gate; propose from the checkout's origin.")
DETACHED = "Pre-merge gate: HEAD is detached in {}, so the source branch is unknown. Name it with {}."
NEED_DEST = ("Pre-merge gate: name the destination explicitly with {}. The CLI could otherwise "
             "take an implicit base from per-branch configuration, which the gate does not read.")
NOT_ON_ORIGIN = ("Pre-merge gate: the branch {} is not on origin, so the change the forge would "
                 "propose cannot be read. Publish the branch to origin first, then retry.")
LS_REMOTE = ("Pre-merge gate: cannot read origin's head of {} (git ls-remote failed), so the "
             "command is refused.")
DEFERRED = ("Pre-merge gate: {} is a deferred merge (auto-merge, or merge when the pipeline "
            "succeeds), which the gate never allows: the MR/PR could be retargeted while it "
            "waits. Wait for the pipeline, then merge immediately and pinned: {}.")
LOOKUP = ("Pre-merge gate: the forge lookup of {} failed, so its destination is unknown and the "
          "merge is refused. Check that it exists and that the CLI is signed in, then retry.")
UNRESOLVED_API = ("Pre-merge gate: this {} api call writes to an MR/PR path whose source, head or "
                  "destination the gate cannot read. Use the CLI (glab mr ..., gh pr ...) or the "
                  "REST create and merge endpoints with literal fields.")
```

- [ ] **Step 4: Add `one`.** Insert this block immediately above the line
  `# ------------------------------------------------------------------ the repository`:

```python
def one(flags, names, label):
    """The single literal value of an option spelt any of names; None when it is absent."""
    values = [v for name in names for v in flags.get(name, [])]
    if len(values) > 1:
        raise Deny(ONCE.format(label))
    if not values:
        return None
    if values[0] is None or not values[0] or not literal(values[0]):
        raise Deny(LITERAL.format(label, values[0] or "an empty value"))
    return values[0]


```

- [ ] **Step 5: Add creation.** Replace everything from the line `def judge(shape, ledger):` up
  to the line `# ------------------------------------------------------------------ main`
  (keep that line) with:

```python
# ------------------------------------------------------------------ the forge project
SCP_RE = re.compile(r"^(?:[^/@:]+@)?[^/:]+:(?!/)")


def split_url(url):
    """(host, project path) of a remote URL or a project reference: lowercased host, path as
    written, .git dropped."""
    u = url.strip()
    if "://" in u:
        parts = urlsplit(u)
        host, path = parts.hostname or "", parts.path
    elif SCP_RE.match(u):
        head, path = u.split(":", 1)
        host = head.split("@")[-1]
    else:
        host, path = "", u
    path = path.strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    return host.lower(), path


def same_project(named, host, path, tool):
    """Does a project the command names equal origin's (host, path)? A URL or an scp-style
    address names its host. Otherwise glab reads the whole value as a project path
    (GROUP/SUB/REPO, on its default host), and gh reads [HOST/]OWNER/REPO."""
    want = path.lower()
    if "://" in named or SCP_RE.match(named):
        h, p = split_url(named)
        return p.lower() == want and h == host
    v = named.strip("/").lower()
    if v.endswith(".git"):
        v = v[:-4]
    return v == want or (tool == "gh" and bool(host) and v == host + "/" + want)


def explicit_repo(tool, host, path):
    """The -R value that names origin's project with its host, as each CLI reads it."""
    return ("https://{}/{}" if tool == "glab" else "{}/{}").format(host or "<host>", path)


def forge_context(cwd, named, tool):
    """(toplevel, origin host, origin path) of the repository a glab or gh verb runs in. named
    is the project the command names, or None; then origin must be the only remote, because
    the CLI could otherwise pick another one."""
    top = toplevel(cwd)
    url = run(["git", "-C", top, "config", "--get", "remote.origin.url"])
    if not url or not url.strip():
        raise Deny(NO_ORIGIN.format(top))
    host, path = split_url(url)
    if named is not None:
        if not literal(named):
            raise Deny(LITERAL.format("the project", named))
        if not same_project(named, host, path, tool):
            raise Deny(OTHER_PROJECT.format(named, path))
    else:
        remotes = (run(["git", "-C", top, "remote"]) or "").split()
        if remotes != ["origin"]:
            raise Deny(SEVERAL_REMOTES.format(", ".join(r for r in remotes if r != "origin"),
                                              explicit_repo(tool, host, path)))
    return top, host, path


def remote_head(top, branch):
    """origin's head of branch, as git ls-remote reads it: what the forge would propose."""
    if not literal(branch) or branch.startswith("-"):
        raise Deny(LITERAL.format("the source branch", branch))
    out = run(["git", "-C", top, "ls-remote", "origin", "refs/heads/" + branch])
    if out is None:
        raise Deny(LS_REMOTE.format(branch))
    for line in out.splitlines():
        sha, _, ref = line.partition("\t")
        if ref.strip() == "refs/heads/" + branch and FULL_ID.fullmatch(sha):
            return sha
    raise Deny(NOT_ON_ORIGIN.format(branch))


# ------------------------------------------------------------------ creating an MR/PR
GLAB_CREATE_VALUE = {"-s", "--source-branch", "-b", "--target-branch", "-R", "--repo", "-H",
                     "--head", "-t", "--title", "-d", "--description", "--description-file",
                     "-a", "--assignee", "-l", "--label", "-m", "--milestone", "--reviewer",
                     "-i", "--related-issue", "--template", "--attach"}
GH_CREATE_VALUE = {"-B", "--base", "-H", "--head", "-R", "--repo", "-a", "--assignee",
                   "--attach", "-b", "--body", "-F", "--body-file", "-l", "--label", "-m",
                   "--milestone", "-p", "--project", "--recover", "-r", "--reviewer", "-T",
                   "--template", "-t", "--title"}
FALSE = ("false", "0", "f")
FULL_ID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


def flag_on(values):
    """A boolean CLI flag as the CLI reads it: on when given bare or with a value other than
    false."""
    return bool(values) and (values[-1] is None or values[-1].lower() not in FALSE)


def judge_create_cli(shape, ledger):
    """glab mr create|new, gh pr create|new: the source is --source-branch/--head or the
    current branch, as origin has it; the destination must be named."""
    tool = shape["tool"]
    flags, _ = parse_flags(shape["args"], GLAB_CREATE_VALUE if tool == "glab" else GH_CREATE_VALUE)
    named = one(flags, ("-R", "--repo"), "-R/--repo") or env_repo(tool)
    top, host, path = forge_context(shape["cwd"], named, tool)
    check_cli_host(tool, top, host, path, named)
    if tool == "glab":
        if flags.get("-H") or flags.get("--head"):
            raise Deny(FORK.format("--head"))
        if flag_on(flags.get("--auto-merge")):
            raise Deny(DEFERRED.format("glab mr create --auto-merge",
                                       "glab mr merge <n> --sha <head> --auto-merge=false"))
        source = one(flags, ("-s", "--source-branch"), "--source-branch")
        dest = one(flags, ("-b", "--target-branch"), "--target-branch")
        if dest is None:
            raise Deny(NEED_DEST.format("--target-branch <branch>"))
    else:
        source = one(flags, ("-H", "--head"), "--head")
        dest = one(flags, ("-B", "--base"), "--base")
        if dest is None:
            raise Deny(NEED_DEST.format("--base <branch>"))
        if source is not None and ":" in source:
            owner, _, source = source.partition(":")
            if owner.lower() != path.split("/")[0].lower():
                raise Deny(FORK.format("--head " + owner + ":" + source))
    if source is None:
        source = ledger.current_branch(top)
        if source is None:
            raise Deny(DETACHED.format(top, "--source-branch" if tool == "glab" else "--head"))
    check(ledger, top, source, dest, "refs/remotes/origin/" + dest, remote_head(top, source),
          "origin/{}...{}".format(dest, source), None)


GITLAB_MR = re.compile(r"^projects/([^/]+)/merge_requests(?:/(\d+)(/merge)?)?$")
GITHUB_PR = re.compile(r"^repos/([^/]+)/([^/]+)/pulls(?:/(\d+)(/merge)?)?$")
BRANCH_PLACEHOLDERS = (":branch", "{branch}")


def field(fields, name, top, ledger):
    """An api field's literal value, the current-branch placeholder resolved; None when the
    field is absent."""
    if name not in fields:
        return None
    value = fields[name]
    if value in BRANCH_PLACEHOLDERS:
        value = ledger.current_branch(top)
        if value is None:
            raise Deny(DETACHED.format(top, "the field " + name))
    if not value or not literal(value):
        raise Deny(LITERAL.format("the field " + name, value or "an empty value"))
    return value


def lookup_json(argv, top, what):
    value = None
    out = run(argv, top)
    try:
        value = json.loads(out) if out else None
    except ValueError:
        value = None
    if value is None:
        raise Deny(LOOKUP.format(what))
    return value


def origin_host(cwd):
    top = toplevel(cwd)
    url = run(["git", "-C", top, "config", "--get", "remote.origin.url"])
    if not url or not url.strip():
        raise Deny(NO_ORIGIN.format(top))
    return split_url(url)[0]


def host_of(value):
    """The lowercased host of a hostname, a host:port or a URL."""
    v = value.strip()
    return (urlsplit(v if "://" in v else "//" + v).hostname or "").lower()


GLAB_HOST_VARS = ("GITLAB_HOST", "GITLAB_URI", "GL_HOST", "GITLAB_URL")
GLAB_HOST_KEYS = ("host", "gitlab_host", "gitlab_uri", "gl_host")


def set_values(names):
    """The values of those environment variables that are set and not empty."""
    return [os.environ[k] for k in names if os.environ.get(k)]


def config_dir(variable, name):
    return os.environ.get(variable) or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), name)


def top_level(path):
    """(key, value) of each top-level line of a YAML config file; [] when there is no such
    file, None when it cannot be read. Indented lines (a host's token among them) are skipped
    unread."""
    found = []
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line[:1] in ("", " ", "\t", "#", "\n", "-") or ":" not in line:
                    continue
                key, _, value = line.partition(":")
                found.append((key.strip().strip("'\""), value.strip().strip("'\"")))
    except FileNotFoundError:
        return []
    except (OSError, UnicodeDecodeError):
        return None
    return found


def gh_default_host():
    """The host gh goes to when nothing names one (gh api without --hostname, -R OWNER/REPO):
    GH_HOST, else the one host gh's hosts.yml lists when it lists exactly one, else github.com.
    None when hosts.yml cannot be read."""
    if os.environ.get("GH_HOST"):
        return host_of(os.environ["GH_HOST"])
    hosts = top_level(os.path.join(config_dir("GH_CONFIG_DIR", "gh"), "hosts.yml"))
    if hosts is None:
        return None
    return host_of(hosts[0][0]) if len(hosts) == 1 else "github.com"


def glab_default_hosts(top):
    """The hosts glab may take for a project named without one: every set GITLAB_HOST,
    GITLAB_URI, GL_HOST and GITLAB_URL, else the host keys of its config.yml - the global one
    and the repository's own .git/glab-cli/config.yml - else gitlab.com. None when a config
    file cannot be read."""
    env = set_values(GLAB_HOST_VARS)
    if env:
        return env
    files = [os.path.join(config_dir("GLAB_CONFIG_DIR", "glab-cli"), "config.yml")]
    for flag in ("--absolute-git-dir", "--git-common-dir"):
        out = run(["git", "-C", top, "rev-parse", flag])
        if out is None or not out.strip():
            return None
        files.append(os.path.join(top, out.strip(), "glab-cli", "config.yml"))
    hosts = []
    for path in files:
        found = top_level(path)
        if found is None:
            return None
        hosts.extend(value for key, value in found if key in GLAB_HOST_KEYS and value)
    return hosts or ["gitlab.com"]


def check_api_host_var(host):
    """GITLAB_API_HOST, when set, sends every glab API request to its host: it must be origin's."""
    for value in set_values(("GITLAB_API_HOST",)):
        if host_of(value) != host:
            raise Deny(API_HOST_VAR.format(host_of(value) or value, host or "a local path"))


def remote_hosts(top):
    """The hosts of every remote URL, fetch and push, as git rewrites them; None when git
    cannot list them. A local-path remote has no host and is left out."""
    out = run(["git", "-C", top, "remote", "-v"])
    if out is None:
        return None
    hosts = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and split_url(parts[1])[0]:
            hosts.add(split_url(parts[1])[0])
    return hosts


def check_api_host(cwd, tool, call):
    """An api call must go to origin's host. An absolute endpoint names its host (a GitHub one
    may name origin's api. host); so does --hostname. Without either the CLI picks the host:
    gh from GH_HOST, else from its hosts.yml, else github.com; glab from GITLAB_HOST,
    GITLAB_URI, GL_HOST or GITLAB_URL, else from a remote on a host it is signed in to, so
    every remote must then be on origin's host. The guard reads its own environment: the
    command cannot set one, because an assignment or an env wrapper is not a plain command.
    Returns origin's host: every lookup the command needs is sent there, with --hostname or a
    host-qualified -R, never left to the environment."""
    top = toplevel(cwd)
    host = origin_host(top)
    where = host or "a local path"
    if tool == "glab":
        check_api_host_var(host)
    endpoint = call["endpoint"] or ""
    chosen = []
    if call["hostname"] is not None:
        chosen = [call["hostname"]]
    elif "://" in endpoint:
        pass
    elif tool == "gh":
        picked = gh_default_host()
        if picked is None:
            raise Deny(UNREADABLE.format("gh's hosts.yml", "--hostname " + where))
        chosen = [picked]
    else:
        chosen = set_values(GLAB_HOST_VARS)
        if not chosen:
            hosts = remote_hosts(top)
            if hosts is None or hosts - {host}:
                raise Deny(SEVERAL_HOSTS.format(
                    ", ".join(sorted(hosts - {host})) if hosts else "unreadable", where))
    for value in chosen:
        if host_of(value) != host:
            raise Deny(OTHER_HOST.format(host_of(value) or value, where))
    if "://" in endpoint:
        named = host_of(endpoint)
        if named not in (host, "api." + host):
            raise Deny(OTHER_HOST.format(named, where))
    return host


def env_repo(tool):
    """The project the environment names for a CLI verb given no -R: GITLAB_REPO for glab,
    GH_REPO for gh. It also fills the :id and {owner}/{repo} placeholders of an api call."""
    return os.environ.get("GITLAB_REPO" if tool == "glab" else "GH_REPO") or None


def check_cli_host(tool, top, host, path, named):
    """A glab or gh verb must reach origin's host too. A project named with its host (a URL,
    or gh's HOST/OWNER/REPO) has had it checked by forge_context. One named by its path alone
    goes to the CLI's default host: gh_default_host() for gh, glab_default_hosts() for glab.
    With no project named, the CLI takes the checkout's one remote, origin, and fails when a
    host variable names another host. Returns origin's host, where every lookup is then
    sent."""
    where = host or "a local path"
    if tool == "glab":
        check_api_host_var(host)
    if named is None or "://" in named or SCP_RE.match(named):
        return host
    bare = named.strip("/").lower()
    if bare.endswith(".git"):
        bare = bare[:-4]
    if bare != path.lower():
        return host
    fix = "-R " + explicit_repo(tool, host, path)
    if tool == "gh":
        picked = gh_default_host()
        if picked is None:
            raise Deny(UNREADABLE.format("gh's hosts.yml", fix))
        chosen = [picked]
    else:
        chosen = glab_default_hosts(top)
        if chosen is None:
            raise Deny(UNREADABLE.format("glab's config.yml", fix))
    for value in chosen:
        if host_of(value) != host:
            raise Deny(DEFAULT_HOST.format(named, host_of(value) or value, where, fix))
    return host


def gitlab_project(cwd, segment, hostname):
    """The repository context of a GitLab project segment - an encoded path, a numeric id
    (looked up on hostname), or the :id / :fullpath placeholder - checked against origin."""
    if segment in (":id", ":fullpath"):
        return forge_context(cwd, env_repo("glab"), "glab")
    if segment.isdigit():
        found = lookup_json(["glab", "api", "--hostname", hostname, "projects/" + segment],
                            toplevel(cwd), "project " + segment)
        named = found.get("path_with_namespace") if isinstance(found, dict) else None
        if not isinstance(named, str) or not named:
            raise Deny(LOOKUP.format("project " + segment))
        return forge_context(cwd, named, "glab")
    return forge_context(cwd, unquote(segment), "glab")


def github_project(cwd, owner, repo):
    if (owner, repo) == ("{owner}", "{repo}"):
        return forge_context(cwd, env_repo("gh"), "gh")
    return forge_context(cwd, owner + "/" + repo, "gh")


def judge_create_gitlab_api(shape, ledger, segment, fields, host):
    top, host, path = gitlab_project(shape["cwd"], segment, host)
    if "target_project_id" in fields:
        raise Deny(FORK.format("target_project_id"))
    source = field(fields, "source_branch", top, ledger)
    dest = field(fields, "target_branch", top, ledger)
    if source is None or dest is None:
        raise Deny(UNRESOLVED_API.format("glab"))
    check(ledger, top, source, dest, "refs/remotes/origin/" + dest, remote_head(top, source),
          "origin/{}...{}".format(dest, source), None)


def judge_create_github_api(shape, ledger, owner, repo, fields):
    top, host, path = github_project(shape["cwd"], owner, repo)
    if "head_repo" in fields:
        raise Deny(FORK.format("head_repo"))
    source = field(fields, "head", top, ledger)
    dest = field(fields, "base", top, ledger)
    if source is None or dest is None:
        raise Deny(UNRESOLVED_API.format("gh"))
    if ":" in source:
        who, _, source = source.partition(":")
        if who.lower() != path.split("/")[0].lower():
            raise Deny(FORK.format("head " + who + ":" + source))
    check(ledger, top, source, dest, "refs/remotes/origin/" + dest, remote_head(top, source),
          "origin/{}...{}".format(dest, source), None)


def judge_api(shape, ledger):
    """The REST create endpoints are checked; every other MR/PR write is denied. The call must
    reach origin's host."""
    tool, call = shape["tool"], parse_api(shape["args"])
    endpoint = call["endpoint"] or ""
    if is_graphql(endpoint):
        raise Deny(NOT_MODELLED)
    if not literal(endpoint):
        raise Deny(LITERAL.format("the api endpoint", endpoint))
    if call["body"]:
        raise Deny(UNRESOLVED_API.format(tool))
    host = check_api_host(shape["cwd"], tool, call)
    path, query = endpoint_parts(endpoint)
    fields = dict(query)
    fields.update(call["fields"])
    if tool == "glab":
        m = GITLAB_MR.match(path)
        if m and call["method"] == "POST" and m.group(2) is None:
            return judge_create_gitlab_api(shape, ledger, m.group(1), fields, host)
    else:
        m = GITHUB_PR.match(path)
        if m and call["method"] == "POST" and m.group(3) is None:
            return judge_create_github_api(shape, ledger, m.group(1), m.group(2), fields)
    raise Deny(UNRESOLVED_API.format(tool))


def judge(shape, ledger):
    kind = shape["kind"]
    if kind == "merge-local":
        return judge_git_merge(shape, ledger)
    if kind == "create":
        return judge_create_cli(shape, ledger)
    if kind == "api":
        return judge_api(shape, ledger)
    raise Deny(NOT_MODELLED)


```

- [ ] **Step 6: Run it and confirm it passes.** `./tests/xreview-guard.test.sh`: expect
  `passed: 176  failed: 0`.

- [ ] **Step 7: Commit.** Check the branch, then:

```bash
git add dot_claude/xreview-guard.py tests/xreview-guard.test.sh
git commit -m "Gate MR and PR creation on origin's head of the approved change"
```

## Task 8: The guard: forge merges, forks, merge queues and trains, GraphQL and other API writes

**Files:**
- Modify: `dot_claude/xreview-guard.py`
- Modify: `tests/xreview-guard.test.sh`

**Interfaces:**
- Consumes (Tasks 6-7): `parse_flags`, `one`, `forge_context`, `check_api_host`, `flag_on`,
  `field`, `lookup_json`, `gitlab_project`, `github_project`, `check`, `is_graphql`, `FULL_ID`,
  `GITLAB_MR`, `GITHUB_PR`.
- Produces:
  - `explicitly_off(values)` and `on_value(value)`;
  - `url_number(target, host, path, pattern, what) -> str`, with the patterns `PR_URL` and
    `MR_URL` (message `OTHER_URL`);
  - `gitlab_mr(top, project, number, branch, hostname) -> (source, target, head, iid)`,
    which denies an MR whose project ids differ;
  - `github_pr(top, target, repo, owner, name) -> (source, base, head)`, where `repo` is
    `<host>/<owner>/<name>`, passed as `-R` whenever there is a target; it denies a
    cross-repository PR;
  - `gitlab_merge_train(top, project, hostname)` and
    `github_merge_queue(top, host, owner, name, dest)` (message `QUEUED`);
  - `merge_pinned(ledger, top, source, dest, head, pin, hint)`;
  - `judge_merge_cli`, `judge_merge_gitlab_api(shape, ledger, segment, number, fields, host)`,
    `judge_merge_github_api(shape, ledger, owner, repo, number, fields, host)`;
  - the final `judge_api` and `judge`. `NOT_MODELLED` is removed.
- The forge lookups, exactly as the test stubs answer them. `<h>` is always origin's host
  and `<project>` origin's encoded path:
  - `glab api --hostname <h> projects/<project>/merge_requests/<n>`;
  - `glab api --hostname <h> projects/<project>/merge_requests?source_branch=<branch>&state=opened`;
  - `glab api --hostname <h> projects/<project>`: the id, `path_with_namespace` and
    `merge_trains_enabled`;
  - `gh pr view <n> -R <h>/<owner>/<name> --json baseRefName,headRefName,headRefOid,isCrossRepository,headRepository,headRepositoryOwner`,
    or `gh pr view --json …` for the current branch's PR;
  - `gh api graphql --hostname <h> -f query=<MERGE_QUEUE> -f owner=… -f name=… -f branch=<dest>`.

- [ ] **Step 1: Write the failing test.** Insert this block into `tests/xreview-guard.test.sh`
  immediately above the line `printf '\npassed: %d  failed: %d\n' "$pass" "$fail"`:

```bash
echo "L. merging an MR/PR on the forge"
# MR 7 and PR 9 come from feature in acme/app (project 4242). Their destination and head come
# from MR_TARGET/MR_SHA and PR_BASE/PR_SHA. MR_SOURCE_PROJECT, PR_CROSS and PR_OWNER make them
# come from a fork; MERGE_TRAINS and MERGE_QUEUE put a train or a queue on the destination, and
# TRAIN_FAIL and QUEUE_FAIL fail those lookups. FORGE_FAIL fails every lookup; FORGE_SLOW
# delays it. A call reaches the host its --hostname or host-qualified -R names, else the one
# the CLI's environment picks, else origin's. Another host answers with its own MR and PR:
# ELSEWHERE_TARGET, ELSEWHERE_TRAINS and ELSEWHERE_BASE.
cat > "$STUB/glab" <<'SH'
#!/bin/sh
printf 'glab %s\n' "$*" >> "$CALLS"
[ -n "${FORGE_SLOW:-}" ] && sleep "$FORGE_SLOW"
[ -n "${FORGE_FAIL:-}" ] && exit 1
host="${GITLAB_HOST:-${GITLAB_URI:-${GL_HOST:-forge.example}}}"
if [ "$1" = api ] && [ "$2" = --hostname ]; then host="$3"; shift 3; set -- api "$@"; fi
if [ "$host" != forge.example ]; then
  MR_TARGET="${ELSEWHERE_TARGET:-${MR_TARGET:-main}}"
  MERGE_TRAINS="${ELSEWHERE_TRAINS:-${MERGE_TRAINS:-false}}"
fi
mr() { printf '{"iid":7,"project_id":4242,"source_project_id":%s,"target_project_id":4242,"source_branch":"feature","target_branch":"%s","sha":"%s"}' \
  "${MR_SOURCE_PROJECT:-4242}" "${MR_TARGET:-main}" "${MR_SHA:-}"; }
project() { [ -n "${TRAIN_FAIL:-}" ] && exit 1
  printf '{"id":4242,"path_with_namespace":"acme/app","merge_trains_enabled":%s}\n' "${MERGE_TRAINS:-false}"; }
case "$*" in
  "api projects/4242"|"api projects/acme%2Fapp"|"api projects/:id") project ;;
  "api projects/acme%2Fapp/merge_requests/7"|"api projects/:id/merge_requests/7"|"api projects/4242/merge_requests/7") mr; echo ;;
  "api projects/acme%2Fapp/merge_requests?source_branch=feature&state=opened") printf '['; mr; printf ']\n' ;;
  *) exit 1 ;;
esac
SH
cat > "$STUB/gh" <<'SH'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$CALLS"
[ -n "${FORGE_FAIL:-}" ] && exit 1
host=forge.example; prev=
for a in "$@"; do
  case "$prev" in
    --hostname) host="$a" ;;
    -R) case "$a" in */*/*) host="${a%%/*}" ;; *) host="${GH_HOST:-github.com}" ;; esac ;;
  esac
  prev="$a"
done
[ "$host" = forge.example ] || PR_BASE="${ELSEWHERE_BASE:-${PR_BASE:-main}}"
F=baseRefName,headRefName,headRefOid,isCrossRepository,headRepository,headRepositoryOwner
case "$*" in
  "pr view 9 --json $F"|"pr view 9 -R acme/app --json $F"|"pr view 9 -R "*"/acme/app --json $F"|"pr view --json $F"|"pr view https://"*" --json $F")
    printf '{"baseRefName":"%s","headRefName":"feature","headRefOid":"%s","isCrossRepository":%s,"headRepository":{"name":"app"},"headRepositoryOwner":{"login":"%s"}}\n' \
      "${PR_BASE:-main}" "${PR_SHA:-}" "${PR_CROSS:-false}" "${PR_OWNER:-acme}" ;;
  "api graphql --hostname forge.example -f query="*mergeQueue*)
    [ -n "${QUEUE_FAIL:-}" ] && exit 1
    printf '{"data":{"repository":{"mergeQueue":%s}}}\n' "${MERGE_QUEUE:-null}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$STUB/glab" "$STUB/gh"
HEAD_SHA="$(git -C "$W" rev-parse refs/remotes/origin/feature)"
export MR_SHA="$HEAD_SHA" PR_SHA="$HEAD_SHA"
is "L1 glab mr merge, pinned and immediate, approved" "$(decision "$W" "glab mr merge 7 --sha $HEAD_SHA --auto-merge=false --yes")" allow
is "L2 glab mr accept" "$(decision "$W" "glab mr accept 7 --sha=$HEAD_SHA --auto-merge=false")" allow
is "L3 the MR of the current branch" "$(decision "$FW" "glab mr merge --sha $HEAD_SHA --auto-merge=false")" allow
is "L4 gh pr merge" "$(decision "$W" "gh pr merge 9 --match-head-commit $HEAD_SHA --squash")" allow
is "L5 gh pr merge -R" "$(decision "$W" "gh pr merge 9 -R acme/app --match-head-commit $HEAD_SHA")" allow
is "L6 the GitLab REST merge" "$(decision "$W" "glab api -X PUT projects/acme%2Fapp/merge_requests/7/merge -f sha=$HEAD_SHA")" allow
is "L7 by the :id placeholder" "$(decision "$W" "glab api --method PUT projects/:id/merge_requests/7/merge -f sha=$HEAD_SHA")" allow
is "L8 by numeric project id" "$(decision "$W" "glab api -X PUT projects/4242/merge_requests/7/merge -f sha=$HEAD_SHA")" allow
is "L9 the GitHub REST merge" "$(decision "$W" "gh api -X PUT repos/acme/app/pulls/9/merge -f sha=$HEAD_SHA")" allow

echo "M. a forge merge is pinned and immediate"
is "M1 an unpinned glab merge is denied" "$(decision "$W" 'glab mr merge 7 --auto-merge=false')" deny
is "M2 naming the head to pin" "$(reason "$W" 'glab mr merge 7 --auto-merge=false' | grep -c "glab mr merge 7 --sha $HEAD_SHA --auto-merge=false")" 1
is "M3 an unpinned gh merge is denied" "$(decision "$W" 'gh pr merge 9 --squash')" deny
is "M4 an unpinned REST merge is denied" "$(decision "$W" 'gh api -X PUT repos/acme/app/pulls/9/merge')" deny
is "M5 glab's default auto-merge is a deferred merge, even pinned" "$(decision "$W" "glab mr merge 7 --sha $HEAD_SHA")" deny
is "M6 naming --auto-merge=false" "$(reason "$W" "glab mr merge 7 --sha $HEAD_SHA" | grep -c -- '--auto-merge=false')" 1
is "M7 glab --auto-merge, even pinned" "$(decision "$W" "glab mr merge 7 --sha $HEAD_SHA --auto-merge")" deny
is "M8 gh --auto, even pinned" "$(decision "$W" "gh pr merge 9 --auto --match-head-commit $HEAD_SHA")" deny
is "M9 merge_when_pipeline_succeeds, even pinned" "$(decision "$W" "glab api -X PUT projects/:id/merge_requests/7/merge -f sha=$HEAD_SHA -F merge_when_pipeline_succeeds=true")" deny
is "M10 auto_merge, even pinned" "$(decision "$W" "glab api -X PUT projects/:id/merge_requests/7/merge -f sha=$HEAD_SHA -F auto_merge=true")" deny
is "M11 an abbreviated pin" "$(decision "$W" "gh pr merge 9 --match-head-commit ${HEAD_SHA:0:12}")" deny

echo "N. what the pin names"
printf 'seven\n' >> "$FW/b.txt"; git -C "$FW" commit -q -am "never reviewed"
UNREVIEWED="$(git -C "$FW" rev-parse HEAD)"; git -C "$FW" reset -q --hard HEAD~1
is "N1 a pin whose fingerprint is unapproved is denied" "$(decision "$W" "gh pr merge 9 --match-head-commit $UNREVIEWED")" deny
is "N2 the deny names the pinned merge to run once approved" "$(reason "$W" "gh pr merge 9 --match-head-commit $UNREVIEWED" | grep -c "Then merge it pinned and immediate: gh pr merge 9 --match-head-commit $UNREVIEWED")" 1
is "N3 a destination origin does not have is denied" "$(MR_TARGET=ghost2 decision "$W" "glab mr merge 7 --sha $HEAD_SHA --auto-merge=false")" deny
git -C "$W" branch release2 main && publish release2
is "N4 an MR retargeted to an unapproved destination is denied" "$(PR_BASE=release2 decision "$W" "gh pr merge 9 --match-head-commit $HEAD_SHA")" deny
printf 'm\n' > "$W/m.txt"; git -C "$W" add m.txt; git -C "$W" commit -q -m "main moves on, elsewhere"; publish main
git -C "$FW" rebase -q main; publish feature
REBASED="$(git -C "$W" rev-parse refs/remotes/origin/feature)"
is "N5 a rebased pin with an unchanged fingerprint is allowed" "$(PR_SHA=$REBASED decision "$W" "gh pr merge 9 --match-head-commit $REBASED")" allow
is "N6 a forge lookup failure is denied" "$(FORGE_FAIL=1 decision "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false")" deny
is "N7 saying so" "$(FORGE_FAIL=1 reason "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" | grep -c 'forge lookup of MR !7 failed')" 1
is "N8 a forge slower than the budget is denied" "$(FORGE_SLOW=3 XREVIEW_GUARD_BUDGET=1 decision "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false")" deny
is "N9 saying it ran out of time" "$(FORGE_SLOW=3 XREVIEW_GUARD_BUDGET=1 reason "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false" | grep -c 'did not finish in time')" 1

echo "O. GraphQL and other API writes"
is "O1 createPullRequest is denied" "$(decision "$W" "gh api graphql -f query='mutation { createPullRequest(input: {}) { clientMutationId } }'")" deny
is "O2 mergeRequestAccept is denied" "$(decision "$W" "glab api graphql -f query='mutation { mergeRequestAccept(input: {}) { errors } }'")" deny
is "O3 enablePullRequestAutoMerge is denied" "$(decision "$W" "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }'")" deny
is "O4 mergePullRequest, mergeRequestCreate and mergeRequestSetAutoMerge too" \
   "$(decision "$W" "gh api graphql -f query='mutation { mergePullRequest(input: {}) { clientMutationId } }'") $(decision "$W" "glab api graphql -f query='mutation { mergeRequestCreate(input: {}) { errors } }'") $(decision "$W" "glab api graphql -f query='mutation { mergeRequestSetAutoMerge(input: {}) { errors } }'")" \
   "deny deny deny"
is "O5 a GraphQL read is allowed" "$(decision "$W" "gh api graphql -f query='query { viewer { login } }'")" allow
is "O6 a GraphQL query from a file is denied" "$(decision "$W" 'gh api graphql -F query=@q.graphql')" deny
is "O7 an MR note through the API is an unresolved write" "$(decision "$W" 'glab api -X POST projects/:id/merge_requests/7/notes -f body=hi')" deny
is "O8 a PATCH of a pull request (a retarget) is denied" "$(decision "$W" 'gh api -X PATCH repos/acme/app/pulls/9 -f base=release')" deny
is "O9 a REST create whose body comes from a file is denied" "$(decision "$W" 'glab api -X POST projects/:id/merge_requests --input mr.json')" deny
is "O10 an absolute GraphQL endpoint carrying a merge mutation is denied" \
   "$(decision "$W" "gh api https://api.github.com/graphql -f query='mutation { mergePullRequest(input: {}) { clientMutationId } }'")" deny

echo "P. a forge merge reaches only origin's own project, and merges at once"
export MR_SHA="$REBASED" PR_SHA="$REBASED"
is "P1 a PR URL on another host is denied, even with an approved pin" \
   "$(decision "$W" "gh pr merge https://github.com/acme/app/pull/9 --match-head-commit $REBASED")" deny
is "P2 saying it is not on origin" \
   "$(reason "$W" "gh pr merge https://github.com/acme/app/pull/9 --match-head-commit $REBASED" | grep -c "is not on this checkout's origin")" 1
is "P3 a PR URL in another project is denied" \
   "$(decision "$W" "gh pr merge https://forge.example/other/app/pull/9 --match-head-commit $REBASED")" deny
is "P4 origin's own PR URL is allowed" \
   "$(decision "$W" "gh pr merge https://forge.example/acme/app/pull/9 --match-head-commit $REBASED")" allow
is "P5 an MR URL on another host is denied" \
   "$(decision "$W" "glab mr merge https://evil.example/acme/app/-/merge_requests/7 --sha $REBASED --auto-merge=false")" deny
is "P6 origin's own MR URL is allowed" \
   "$(decision "$W" "glab mr merge https://forge.example/acme/app/-/merge_requests/7 --sha $REBASED --auto-merge=false")" allow
is "P7 an MR from a fork is denied" \
   "$(MR_SOURCE_PROJECT=99 decision "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false")" deny
is "P8 a cross-repository PR is denied" \
   "$(PR_CROSS=true decision "$W" "gh pr merge 9 --match-head-commit $REBASED")" deny
is "P9 a PR whose head lives in another owner's repository is denied" \
   "$(PR_OWNER=someone decision "$W" "gh pr merge 9 --match-head-commit $REBASED")" deny
is "P10 a destination with a merge queue is a deferred merge" \
   "$(MERGE_QUEUE='{"id":"MQ_1"}' decision "$W" "gh pr merge 9 --match-head-commit $REBASED")" deny
is "P11 saying so" \
   "$(MERGE_QUEUE='{"id":"MQ_1"}' reason "$W" "gh pr merge 9 --match-head-commit $REBASED" | grep -c 'the merge queue of main')" 1
is "P12 a failed merge-queue lookup is denied" \
   "$(QUEUE_FAIL=1 decision "$W" "gh pr merge 9 --match-head-commit $REBASED")" deny
is "P13 a project with merge trains is a deferred merge" \
   "$(MERGE_TRAINS=true decision "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false")" deny
is "P14 a failed project lookup is denied" \
   "$(TRAIN_FAIL=1 decision "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false")" deny
is "P15 the GitLab REST merge checks the train too" \
   "$(MERGE_TRAINS=true decision "$W" "glab api -X PUT projects/:id/merge_requests/7/merge -f sha=$REBASED")" deny
is "P16 and the GitHub REST merge the queue" \
   "$(MERGE_QUEUE='{"id":"MQ_1"}' decision "$W" "gh api -X PUT repos/acme/app/pulls/9/merge -f sha=$REBASED")" deny
is "P17 gh api --hostname on another host is denied" \
   "$(decision "$W" "gh api --hostname evil.example -X PUT repos/acme/app/pulls/9/merge -f sha=$REBASED")" deny
is "P18 glab api --hostname on another host is denied" \
   "$(decision "$W" "glab api --hostname evil.example -X PUT projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED")" deny
is "P19 gh api --hostname naming origin's host is allowed" \
   "$(decision "$W" "gh api --hostname forge.example -X PUT repos/acme/app/pulls/9/merge -f sha=$REBASED")" allow
is "P20 glab api --hostname naming origin's host is allowed" \
   "$(decision "$W" "glab api --hostname forge.example -X PUT projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED")" allow
is "P21 an absolute GitLab endpoint on another host is denied" \
   "$(decision "$W" "glab api -X PUT https://evil.example/api/v4/projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED")" deny
is "P22 on origin's host it is allowed" \
   "$(decision "$W" "glab api -X PUT https://forge.example/api/v4/projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED")" allow
is "P23 an absolute GitHub endpoint on another host is denied" \
   "$(decision "$W" "gh api -X PUT https://evil.example/api/v3/repos/acme/app/pulls/9/merge -f sha=$REBASED")" deny
is "P24 on origin's host it is allowed" \
   "$(decision "$W" "gh api -X PUT https://forge.example/api/v3/repos/acme/app/pulls/9/merge -f sha=$REBASED")" allow
is "P25 -R naming another host is denied (gh)" \
   "$(decision "$W" "gh pr merge 9 -R evil.example/acme/app --match-head-commit $REBASED")" deny
is "P26 -R as a URL on another host is denied (glab)" \
   "$(decision "$W" "glab mr merge 7 -R https://evil.example/acme/app --sha $REBASED --auto-merge=false")" deny
is "P27 a gh REST merge with no GH_HOST goes to github.com and is denied" \
   "$(GH_HOST= decision "$W" "gh api -X PUT repos/acme/app/pulls/9/merge -f sha=$REBASED")" deny
is "P28 a glab REST merge under a stray GITLAB_HOST is denied" \
   "$(GITLAB_HOST=gitlab.com decision "$W" "glab api -X PUT projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED")" deny
# Every lookup goes to the host the command reaches, never to the one the environment picks.
# On other.example, MR 7 and PR 9 target main, which is approved; on origin's host, release2.
GLMERGE="glab api -X PUT https://forge.example/api/v4/projects/acme%2Fapp/merge_requests/7/merge -f sha=$REBASED"
GHMERGE="gh api -X PUT https://forge.example/api/v3/repos/acme/app/pulls/9/merge -f sha=$REBASED"
is "P29 a GitLab REST merge to origin's absolute endpoint reads origin's MR" \
   "$(GITLAB_HOST=other.example ELSEWHERE_TARGET=main MR_TARGET=release2 decision "$W" "$GLMERGE")" deny
is "P30 and origin's merge train" \
   "$(GITLAB_HOST=other.example ELSEWHERE_TRAINS=false MERGE_TRAINS=true decision "$W" "$GLMERGE")" deny
is "P31 with both hosts agreeing, it is allowed" "$(GITLAB_HOST=other.example decision "$W" "$GLMERGE")" allow
is "P32 a GitHub REST merge to origin's absolute endpoint reads origin's PR" \
   "$(GH_HOST=other.example ELSEWHERE_BASE=main PR_BASE=release2 decision "$W" "$GHMERGE")" deny
is "P33 with both hosts agreeing, it is allowed" "$(GH_HOST=other.example decision "$W" "$GHMERGE")" allow
is "P34 glab mr merge -R <url> reads the MR on that URL's host" \
   "$(GITLAB_HOST=other.example ELSEWHERE_TARGET=main MR_TARGET=release2 decision "$W" "glab mr merge 7 -R https://forge.example/acme/app --sha $REBASED --auto-merge=false")" deny
is "P35 gh pr merge -R without a host, gh's default host elsewhere" \
   "$(GH_HOST=other.example decision "$W" "gh pr merge 9 -R acme/app --match-head-commit $REBASED")" deny
is "P36 glab mr merge -R without a host, glab's default host gitlab.com" \
   "$(GLAB_CONFIG_DIR="$ROOT/glab-none" decision "$W" "glab mr merge 7 -R acme/app --sha $REBASED --auto-merge=false")" deny
is "P37 GH_REPO naming another project is denied" "$(GH_REPO=other/app decision "$W" "gh pr merge 9 --match-head-commit $REBASED")" deny
is "P38 so is GITLAB_REPO" "$(GITLAB_REPO=other/app decision "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false")" deny
is "P39 and GITLAB_API_HOST on another host" "$(GITLAB_API_HOST=api.other.example decision "$W" "glab mr merge 7 --sha $REBASED --auto-merge=false")" deny

```

- [ ] **Step 2: Run it and confirm it fails.** `./tests/xreview-guard.test.sh`: expect
  `passed: 229  failed: 25`. The failures are L1-L9, M2, M6, N2, N5, N7, N9, P2, P4, P6, P11,
  P19, P20, P22, P24, P31 and P33: merges are still denied with `NOT_MODELLED`, or as unresolved API
  writes.

- [ ] **Step 3: Replace the placeholder message.** In `dot_claude/xreview-guard.py`, replace
  the line that starts `NOT_MODELLED = ` with:

```python
UNPINNED = ("Pre-merge gate: a forge merge must pin the head it merges. Its head is now {}. Once "
            "a pre-merge review of that head approves it, merge with: {}.")
FULL_SHA = "Pre-merge gate: pin the head with a full commit id, not {}."
NOT_ONE = "Pre-merge gate: {} open merge requests come from {}; name the one to merge by number."
ONE_TARGET = "Pre-merge gate: name one {} to merge."
GRAPHQL = ("Pre-merge gate: this GraphQL call creates or merges an MR/PR, enables auto-merge, or "
           "carries a query the gate cannot read. Use the forms the gate checks: glab mr "
           "create|merge, gh pr create|merge, or the REST merge_requests/pulls endpoints.")
OTHER_URL = ("Pre-merge gate: the {} {} is not on this checkout's origin ({}/{}). Run the merge "
             "from that project's checkout, or name the MR/PR by number.")
QUEUED = ("Pre-merge gate: this merge would go through {}: it would be enqueued, or set to merge "
          "once checks pass - a deferred merge, which the gate never allows, since nothing can pin "
          "what finally lands. A merge through a queue or a train is Michael's to run.")
```

- [ ] **Step 4: Add merging.** Replace everything from the line
  `def judge_api(shape, ledger):` up to the line
  `# ------------------------------------------------------------------ main` (keep that line)
  with:

```python
# ------------------------------------------------------------------ merging an MR/PR
GLAB_MERGE_VALUE = {"-m", "--message", "--sha", "--squash-message", "-R", "--repo"}
GH_MERGE_VALUE = {"-A", "--author-email", "-b", "--body", "-F", "--body-file",
                  "--match-head-commit", "-t", "--subject", "-R", "--repo"}
GH_VIEW_FIELDS = ("baseRefName,headRefName,headRefOid,isCrossRepository,headRepository,"
                  "headRepositoryOwner")
PR_URL = re.compile(r"^/(.+)/pull/(\d+)/?$")
MR_URL = re.compile(r"^/(.+)/-/merge_requests/(\d+)/?$")
MERGE_QUEUE = ("query($owner:String!,$name:String!,$branch:String!){repository(owner:$owner,"
               "name:$name){mergeQueue(branch:$branch){id}}}")


def explicitly_off(values):
    return bool(values) and values[-1] is not None and values[-1].lower() in FALSE


def on_value(value):
    """An api field that switches something on: present with any value but false."""
    return value is not None and value.lower() not in FALSE


def url_number(target, host, path, pattern, what):
    """The number of the MR/PR a URL argument names, once its host and project are origin's:
    a URL can name any repository on any forge."""
    parts = urlsplit(target)
    m = pattern.match(parts.path)
    if not m or (parts.hostname or "").lower() != host or m.group(1).lower() != path.lower():
        raise Deny(OTHER_URL.format(what, target, host, path))
    return m.group(2)


def gitlab_mr(top, project, number, branch, hostname):
    """(source, target, head, iid) of a GitLab MR on hostname - by number, or the one open MR
    from branch. Its source and target project must be the project it was looked up in: a
    fork's MR is denied."""
    base = ["glab", "api", "--hostname", hostname]
    if number is not None:
        mr = lookup_json(base + ["projects/{}/merge_requests/{}".format(project, number)], top,
                         "MR !" + number)
    else:
        found = lookup_json(base + ["projects/{}/merge_requests?source_branch={}&state=opened"
                                    .format(project, quote(branch, safe=""))], top,
                            "the MR from " + branch)
        if not isinstance(found, list) or len(found) != 1:
            raise Deny(NOT_ONE.format(len(found) if isinstance(found, list) else "no", branch))
        mr = found[0]
    if not isinstance(mr, dict) or not all(isinstance(mr.get(k), str) and mr.get(k)
                                           for k in ("source_branch", "target_branch", "sha")):
        raise Deny(LOOKUP.format("MR " + (number or branch)))
    ids = [mr.get(k) for k in ("project_id", "source_project_id", "target_project_id")]
    if not all(isinstance(i, int) for i in ids) or len(set(ids)) != 1:
        raise Deny(FORK.format("MR !" + str(mr.get("iid") or number or branch)))
    return mr["source_branch"], mr["target_branch"], mr["sha"], str(mr.get("iid") or number or "")


def gitlab_merge_train(top, project, hostname):
    """Deny when the project on hostname merges through a merge train: the merge would join
    the train, a deferred merge. A failed lookup is a deny too; a project without the setting
    has no train."""
    found = lookup_json(["glab", "api", "--hostname", hostname, "projects/" + project], top,
                        "project " + unquote(project))
    if not isinstance(found, dict):
        raise Deny(LOOKUP.format("project " + unquote(project)))
    if found.get("merge_trains_enabled") is True:
        raise Deny(QUEUED.format("the merge train of " + unquote(project)))


def github_pr(top, target, repo, owner, name):
    """(source, base, head) of a GitHub PR, as gh pr view resolves target in repo, a
    host-qualified HOST/OWNER/NAME. With no target, gh needs no -R: it takes the current
    branch's PR where the merge itself would. A cross-repository PR, or one whose head lives
    anywhere but origin's project, is denied."""
    what = "PR " + (target or "of the current branch")
    pr = lookup_json(["gh", "pr", "view"] + ([target, "-R", repo] if target else [])
                     + ["--json", GH_VIEW_FIELDS], top, what)
    if not isinstance(pr, dict):
        raise Deny(LOOKUP.format(what))
    values = [pr.get(k) for k in ("headRefName", "baseRefName", "headRefOid")]
    if not all(isinstance(v, str) and v for v in values):
        raise Deny(LOOKUP.format(what))
    head_repo = pr.get("headRepository") if isinstance(pr.get("headRepository"), dict) else {}
    head_owner = (pr.get("headRepositoryOwner")
                  if isinstance(pr.get("headRepositoryOwner"), dict) else {})
    if (pr.get("isCrossRepository") is not False
            or str(head_owner.get("login", "")).lower() != owner.lower()
            or str(head_repo.get("name", "")).lower() != name.lower()):
        raise Deny(FORK.format(what))
    return values[0], values[1], values[2]


def github_merge_queue(top, host, owner, name, dest):
    """Deny when dest merges through a merge queue: gh pr merge would then enable auto-merge
    or enqueue the PR, a deferred merge. A failed lookup is a deny too."""
    what = "the merge queue of " + dest
    found = lookup_json(["gh", "api", "graphql", "--hostname", host,
                         "-f", "query=" + MERGE_QUEUE, "-f", "owner=" + owner,
                         "-f", "name=" + name, "-f", "branch=" + dest], top, what)
    try:
        queue = found["data"]["repository"]["mergeQueue"]
    except (KeyError, TypeError):
        raise Deny(LOOKUP.format(what))
    if queue is not None:
        raise Deny(QUEUED.format(what))


def merge_pinned(ledger, top, source, dest, head, pin, hint):
    """A forge merge pinned to pin; hint is the immediate pinned merge, {} for the head."""
    if pin is None:
        raise Deny(UNPINNED.format(head, hint.format(head)))
    if not FULL_ID.fullmatch(pin):
        raise Deny(FULL_SHA.format(pin))
    check(ledger, top, source, dest, "refs/remotes/origin/" + dest, pin,
          "origin/{}...{}".format(dest, source), hint.format(pin))


def judge_merge_cli(shape, ledger):
    """glab mr merge|accept [<n>|<branch>|<url>], gh pr merge [<n>|<url>|<branch>]: pinned,
    immediate, from origin's own project, and the destination read from the forge."""
    tool = shape["tool"]
    flags, pos = parse_flags(shape["args"], GLAB_MERGE_VALUE if tool == "glab" else GH_MERGE_VALUE)
    named = one(flags, ("-R", "--repo"), "-R/--repo") or env_repo(tool)
    top, host, path = forge_context(shape["cwd"], named, tool)
    check_cli_host(tool, top, host, path, named)
    if len(pos) > 1:
        raise Deny(ONE_TARGET.format("MR" if tool == "glab" else "PR"))
    target = pos[0] if pos else None
    if target is not None and not literal(target):
        raise Deny(LITERAL.format("the MR/PR", target))
    if tool == "glab":
        # glab turns auto-merge on by default while a pipeline runs: only an explicit
        # --auto-merge=false is an immediate merge.
        if not explicitly_off(flags.get("--auto-merge")) or flag_on(flags.get("--when-pipeline-succeeds")):
            raise Deny(DEFERRED.format("glab mr merge without --auto-merge=false",
                                       "glab mr merge <n> --sha <head> --auto-merge=false"))
        if target is not None and "://" in target:
            target = url_number(target, host, path, MR_URL, "MR")
        number = target if target and target.isdigit() else None
        branch = None if number else (target or ledger.current_branch(top))
        if number is None and branch is None:
            raise Deny(DETACHED.format(top, "the MR number"))
        project = quote(path, safe="")
        source, dest, head, iid = gitlab_mr(top, project, number, branch, host)
        gitlab_merge_train(top, project, host)
        pin = one(flags, ("--sha",), "--sha")
        hint = "glab mr merge " + (iid or "<n>") + " --sha {} --auto-merge=false"
    else:
        if flag_on(flags.get("--auto")):
            raise Deny(DEFERRED.format("gh pr merge --auto", "gh pr merge <n> --match-head-commit <head>"))
        if target is not None and "://" in target:
            target = url_number(target, host, path, PR_URL, "PR")
        owner, _, name = path.partition("/")
        source, dest, head = github_pr(top, target, host + "/" + path, owner, name)
        github_merge_queue(top, host, owner, name, dest)
        pin = one(flags, ("--match-head-commit",), "--match-head-commit")
        hint = "gh pr merge " + (target or "<n>") + " --match-head-commit {}"
    merge_pinned(ledger, top, source, dest, head, pin, hint)


def judge_merge_gitlab_api(shape, ledger, segment, number, fields, host):
    """A REST merge: the MR and the project's merge train are read from origin's project on
    host, the host the call was checked to reach."""
    top, host, path = gitlab_project(shape["cwd"], segment, host)
    hint = "glab api -X PUT projects/{}/merge_requests/{}/merge -f sha={{}}".format(segment, number)
    if on_value(fields.get("merge_when_pipeline_succeeds")) or on_value(fields.get("auto_merge")):
        raise Deny(DEFERRED.format("merge_when_pipeline_succeeds/auto_merge", hint.format("<head>")))
    project = quote(path, safe="")
    source, dest, head, _ = gitlab_mr(top, project, number, None, host)
    gitlab_merge_train(top, project, host)
    merge_pinned(ledger, top, source, dest, head, field(fields, "sha", top, ledger), hint)


def judge_merge_github_api(shape, ledger, owner, repo, number, fields, host):
    """A REST merge: the PR and the merge queue are read from origin's project on host."""
    top, host, path = github_project(shape["cwd"], owner, repo)
    o, _, n = path.partition("/")
    source, dest, head = github_pr(top, number, host + "/" + path, o, n)
    github_merge_queue(top, host, o, n, dest)
    merge_pinned(ledger, top, source, dest, head, field(fields, "sha", top, ledger),
                 "gh api -X PUT repos/{}/{}/pulls/{}/merge -f sha={{}}".format(owner, repo, number))


def judge_api(shape, ledger):
    """The REST create and merge endpoints are checked; GraphQL and every other MR/PR write
    are denied. The call must reach origin's host."""
    tool, call = shape["tool"], parse_api(shape["args"])
    endpoint = call["endpoint"] or ""
    if is_graphql(endpoint):
        raise Deny(GRAPHQL)
    if not literal(endpoint):
        raise Deny(LITERAL.format("the api endpoint", endpoint))
    if call["body"]:
        raise Deny(UNRESOLVED_API.format(tool))
    host = check_api_host(shape["cwd"], tool, call)
    path, query = endpoint_parts(endpoint)
    fields = dict(query)
    fields.update(call["fields"])
    if tool == "glab":
        m = GITLAB_MR.match(path)
        if m and call["method"] == "POST" and m.group(2) is None:
            return judge_create_gitlab_api(shape, ledger, m.group(1), fields, host)
        if m and call["method"] == "PUT" and m.group(3):
            return judge_merge_gitlab_api(shape, ledger, m.group(1), m.group(2), fields, host)
    else:
        m = GITHUB_PR.match(path)
        if m and call["method"] == "POST" and m.group(3) is None:
            return judge_create_github_api(shape, ledger, m.group(1), m.group(2), fields)
        if m and call["method"] == "PUT" and m.group(4):
            return judge_merge_github_api(shape, ledger, m.group(1), m.group(2), m.group(3),
                                          fields, host)
    raise Deny(UNRESOLVED_API.format(tool))


def judge(shape, ledger):
    kind = shape["kind"]
    if kind == "merge-local":
        return judge_git_merge(shape, ledger)
    if kind == "create":
        return judge_create_cli(shape, ledger)
    if kind == "merge":
        return judge_merge_cli(shape, ledger)
    return judge_api(shape, ledger)


```

- [ ] **Step 5: Run it and confirm it passes.** `./tests/xreview-guard.test.sh`: expect
  `passed: 254  failed: 0`. Then `grep -c NOT_MODELLED dot_claude/xreview-guard.py` must print
  `0`.

- [ ] **Step 6: Commit.** Check the branch, then:

```bash
git add dot_claude/xreview-guard.py tests/xreview-guard.test.sh
git commit -m "Gate forge merges on a pinned, immediate merge of the approved change"
```

## Task 9: Skill text, evaluation attribution and rollout note

**Files:**
- Modify: `dot_claude/skills/cross-review/SKILL.md`
- Modify: `tests/xreview-skill.test.sh`
- Modify: `.scripts/measure-interventions.py`
- Modify: `tests/measure-interventions.test.sh`
- Modify: `docs/superpowers/specs/2026-09-30-safe-autonomy-design.md` (a dated note)

**Interfaces:**
- Consumes (Tasks 6-8): the guard reads the flags `"--auto-merge"`, `"--sha"`,
  `"--match-head-commit"`, `"--target-branch"` and `"--base"`.
- Produces:
  - the §3.7 skill text;
  - the `xreview-guard` attribution regex
    `No (approved pre-merge )?Codex cross-review on record|Pre-merge gate: `.

- [ ] **Step 1: Write the failing skill checks.** Apply this to `tests/xreview-skill.test.sh`:
  - Edit 1 extends the gated-verb extractor to `new`, `merge` and `accept`.
  - Edit 2 matches the new gate sentence.
  - Edit 3 adds the §3.7 pins and the stale-text checks.

Edit 1 - replace:

```bash
gated="$(grep -oE '(glab|gh)[[:space:]]+(mr|pr)[[:space:]]+create[A-Za-z0-9_-]*' "$SKILL" | tr -s ' \t' ' ' | sort -u)"
```

with:

```bash
gated="$(grep -oE '(glab|gh)[[:space:]]+(mr|pr)[[:space:]]+(create|new|merge|accept)[A-Za-z0-9_-]*' "$SKILL" | tr -s ' \t' ' ' | sort -u)"
```

Edit 2 - replace:

```bash
   && grep -qi 'latest .pre-merge. receipt has the verdict' "$SKILL"; then
```

with:

```bash
   && grep -qi 'latest full-range .pre-merge. review of exactly that change' "$SKILL"; then
```

Edit 3 - replace:

```bash
# A schema miss is its own exit code.
```

with:

```bash
# spec 2026-10-02 §3.7: the gate opens only for the full range of the change a review saw,
# a forge merge is pinned and immediate, creation names its destination, and a fix round
# needs a fresh full-range round. A skill that drifts from these teaches a call the gate
# denies, and the guard must read every flag the skill tells the model to pass.
for phrase in 'full range against the branch it will land on' '<dest>...<branch>' \
              'names its destination explicitly' 'never deferred' '--auto-merge=false' \
              '--sha <head>' '--match-head-commit <head>' 'fresh full-range round' \
              '--diff <repo-path>:<range>' 'xreview/ledgers/'; do
  if grep -qF -- "$phrase" "$SKILL"; then
    _pass "the skill says '$phrase'"
  else _fail "the skill says '$phrase'" "missing"; fi
done
for flag in '"--auto-merge"' '"--sha"' '"--match-head-commit"' '"--target-branch"' '"--base"'; do
  if grep -qF -- "$flag" <<<"$guard_code"; then
    _pass "the guard reads $flag"
  else _fail "the guard reads $flag" "the skill names a flag the guard never reads"; fi
done
for stale in 'advisory about freshness' '`glab mr create` / `gh pr create` in command position' \
             'local merges, pushes, forge web UIs'; do
  if grep -qiF -- "$stale" "$GUARD" "$SKILL"; then
    _fail "no '$stale' survives" "still present"
  else _pass "no '$stale' survives"; fi
done

# A schema miss is its own exit code.
```

- [ ] **Step 2: Write the failing attribution check.** Apply this to
  `tests/measure-interventions.test.sh`:

Edit 1 - replace:

```bash
[ "$rc" -eq 2 ] && _pass "a missing projects dir is a usage error" || _fail "a missing projects dir is a usage error" "rc=$rc"
```

with:

```bash
[ "$rc" -eq 2 ] && _pass "a missing projects dir is a usage error" || _fail "a missing projects dir is a usage error" "rc=$rc"

# spec 2026-10-02 §4: the pre-merge gate's denies read "Pre-merge gate: ..." from the receipt
# binding on. The evaluation attributes them, and the older wording, to xreview-guard; a
# result that merely quotes the text is still no denial.
names="$(/usr/bin/python3 - "$SCRIPT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("measure", sys.argv[1])
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)
for text in ("PreToolUse:Bash hook error: Pre-merge gate: no full-range pre-merge review of this change is on record.",
             "PreToolUse:Bash hook error: No approved pre-merge Codex cross-review on record for branch 'x'.",
             "grep: Pre-merge gate: appears in a file"):
    print(next((name for name, rx in measure.DENIAL_RES if rx.match(text)), "none"))
PY
)"
if [ "$names" = "$(printf 'xreview-guard\nxreview-guard\nnone')" ]; then
  _pass "the pre-merge gate's denies, old and new wording, count as xreview-guard"
else _fail "the pre-merge gate's denies, old and new wording, count as xreview-guard" "$names"; fi
```

- [ ] **Step 3: Run them and confirm they fail.**
  - `./tests/xreview-skill.test.sh`: expect `passed: 81  failed: 13`. The gate sentence fails,
    so do the ten §3.7 phrases, and so do the two stale phrases still in the skill.
  - `./tests/measure-interventions.test.sh`: expect `passed: 24  failed: 1`, which is the
    pre-merge-gate attribution.

- [ ] **Step 4: Rewrite the skill text (§3.7).** Apply these edits to
  `dot_claude/skills/cross-review/SKILL.md`, in order:
  - Edit 1: the dispatch example.
  - Edit 2: the checkpoint sentence, plus two new paragraphs: the full range with the
    multi-repository form, and landing through the gate.
  - Edit 3: what is enforced.
  - Edit 4: what fails open.
  - Edit 5: what the guard reads.

Edit 1 - replace:

```markdown
xreview dispatch --checkpoint <spec|plan|pre-merge> --diff <base>..<head> <body-file>
```

with:

```markdown
xreview dispatch --checkpoint <spec|plan|pre-merge> --diff <dest>...<branch> <body-file>
```

Edit 2 - replace:

```markdown
completion, `pre-merge` before merging. The receipt records it, and the pre-merge gate
below opens only on a `pre-merge` receipt whose latest verdict is `approve`.
```

with:

````markdown
completion, `pre-merge` before merging. The receipt records it, and the pre-merge gate
below opens only for a change whose latest full-range `pre-merge` review approved it.

**A pre-merge review opens the gate only for the change it saw.** Use the
full range against the branch it will land on: `<dest>...<branch>`, or `<dest>..<branch>`,
which is normalized to the same thing; for a forge MR/PR the destination is origin's,
`origin/<dest>...<branch>`. With no `--diff`, a pre-merge dispatch reviews the current
branch against the default branch. A range that starts at a commit (`5c86f2c..<branch>`) is
partial: it is recorded but never opens the gate, so point the reviewer at the new commits
in the body, not in `--diff`. Every fix round needs a fresh full-range round: any change to
the content after the approval closes the gate again, and a clean rebase does not. One
review can cover several repositories, each with its own `--diff <repo-path>:<range>`:

```
xreview dispatch --checkpoint pre-merge --diff main...feat/x --diff ../api:main...feat/x <body-file>
```

**Land through the gate.** MR/PR creation names its destination explicitly
(`glab mr create --target-branch <dest>`, `gh pr create --base <dest>`), from a branch
already published to origin. A forge merge by an agent pins the head and is never deferred:
wait for the pipeline, then merge immediately with
`glab mr merge <n> --sha <head> --auto-merge=false` (glab otherwise turns auto-merge on
while a pipeline runs) or `gh pr merge <n> --match-head-commit <head>`. Run each as a plain
command of its own: a chain, a pipe or an environment assignment on the verb is denied.
````

Edit 3 - replace:

```markdown
`xreview collect` writes a receipt to `$XDG_STATE_HOME/xreview/<repo>/reviews.jsonl`,
naming the checkpoint and the verdict, and a `PreToolUse` guard denies `glab mr create` /
`gh pr create` on a branch unless its latest `pre-merge` receipt has the verdict
`approve`. Spec and plan receipts never open it, and neither does a pre-merge round that
came back `changes`. That is the one part of this workflow prose cannot guarantee: a
skipped review is otherwise indistinguishable from one that found nothing.
```

with:

```markdown
`xreview dispatch` puts a pending entry, and `xreview collect` a receipt, in the
repository's ledger, `$XDG_STATE_HOME/xreview/ledgers/<key>/reviews.jsonl`: one ledger per
repository, shared by all its worktrees. An entry names the exact change reviewed (a content
fingerprint) and the branch it is meant to land on. A `PreToolUse` guard gates
`glab mr create`/`new`, `gh pr create`/`new`, `glab mr merge`/`accept`, `gh pr merge`, their
REST forms through `glab api`/`gh api`, and a local `git merge` into the default branch. It
denies them unless the latest full-range `pre-merge` review of exactly that change, for that
destination, has the verdict `approve`. Spec and plan reviews never open it, a partial
range never does, and neither does a newer pending review or a verdict of `changes`. That is
the one part of this workflow prose cannot guarantee: a skipped review is otherwise
indistinguishable from one that found nothing.
```

Edit 4 - replace:

```markdown
The guards are deliberately narrow — local merges, pushes, forge web UIs and other CLIs
fail open, and `XREVIEW_GUARD=off` bypasses it.
```

with:

```markdown
The guards are deliberately narrow — pushes, merges in a forge web UI, other CLIs and a
command assembled from variables fail open, and `XREVIEW_GUARD=off` bypasses it.
```

Edit 5 - replace:

```markdown
description that it went up without a cross-review and why. The pre-merge guard only ever
looks at `glab mr create` / `gh pr create` in command position, so writing the Basecamp
card, the comment and the MR body is never gated
```

with:

```markdown
description that it went up without a cross-review and why. The pre-merge guard only reads
a gated verb in command position, so writing the Basecamp card, the comment and the MR body
is never gated
```

- [ ] **Step 5: Teach the evaluation the new wording.** Apply this to
  `.scripts/measure-interventions.py`:

Edit 1 - replace:

```python
    ("xreview-guard", r"No (approved pre-merge )?Codex cross-review on record"),
```

with:

```python
    # "Pre-merge gate:" from the receipt binding on (spec 2026-10-02); the older wording before.
    ("xreview-guard", r"No (approved pre-merge )?Codex cross-review on record|Pre-merge gate: "),
```

- [ ] **Step 6: Run them and confirm they pass.**
  - `./tests/xreview-skill.test.sh`: expect `passed: 96  failed: 0`.
  - `./tests/measure-interventions.test.sh`: expect `passed: 25  failed: 0`.

- [ ] **Step 7: Record the rollout in the safe-autonomy spec (§4).** Run `date +%F` and use
  its output as DATE. Append this subsection at the end of
  `docs/superpowers/specs/2026-09-30-safe-autonomy-design.md`, after its last "Rule 4
  follow-up" subsection:

```markdown
### Pre-merge gate follow-up: receipt binding (branch `feat/xreview-receipt-binding`, DATE)

The pre-merge gate now binds an approval to the exact change and its destination
(`docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md`).

- **What it gates.** From this merge, the gate also gates:
  - forge merges;
  - the REST and GraphQL forms;
  - a local `git merge` into the default branch;
  - every creation or merge whose change has no current full-range approval.

  v1 receipts no longer open it, so every in-flight branch needs one fresh full-range
  pre-merge round.
- **Evaluation impact.** Its deny reasons now begin "Pre-merge gate:", and
  `measure-interventions.py` counts them as xreview-guard. Count the denies from this date
  separately when comparing against the baseline above: a rise is expected, not a regression.
```

- [ ] **Step 8: Commit.** Check the branch, then:

```bash
git add dot_claude/skills/cross-review/SKILL.md tests/xreview-skill.test.sh .scripts/measure-interventions.py tests/measure-interventions.test.sh docs/superpowers/specs/2026-09-30-safe-autonomy-design.md
git commit -m "Teach the cross-review skill the bound pre-merge gate, and count its denies"
```

## Task 10: Full verification

**Files:** none changed, unless a step finds a defect. A defect goes back to the task that
owns it.

**Interfaces:** consumes everything above.

- [ ] **Step 1: Run every suite.** Run `./tests/run.sh` as one foreground Bash call with a
  timeout of 600000 ms. Do not filter it, and do not run any other suite while it runs.
  - It took 618 s on the scratch clone, so it will likely reach the limit. If the call is moved to the
    background there, wait for its completion notice and read its output file. Do not start a
    second run.
  - Expected:
    - every suite `ok`;
    - `29 suites run, 8 skipped (see the needs: lines)`;
    - `all 29 suites passed (3332 assertions)`.
  - The eight skipped suites carry a `# test-requires:` line.
  - Report the total as passed/total, `3332/3332`, copied from the runner's last line.

- [ ] **Step 2: Confirm the deployed set.** Run
  `chezmoi managed --include=files | grep -c -E '^\.claude/xreview-(guard|ledger)\.py$'` and
  expect `2`. This is the same fact `claude-settings.test.sh` section X pins; this run checks
  the real source directory.

- [ ] **Step 3: Check the spec's coverage.** Check the coverage table below against the spec
  once more. Any §5 bullet without a passing test is a defect in its owning task.

- [ ] **Step 4: Hand off.** Report:
  - the runner's total;
  - the commits made, from `git log --oneline main..HEAD`;
  - anything that differed from an expected count, and the ruling taken on it.

  The pre-merge cross-review, the Status updates and the merge belong to the driver, and are
  not steps of this plan.

## Spec coverage

Test IDs are per suite: ledger = `tests/xreview-ledger.test.sh`, xreview =
`tests/xreview.test.sh`, guard = `tests/xreview-guard.test.sh`, skill =
`tests/xreview-skill.test.sh`, settings = `tests/claude-settings.test.sh`.

| Spec | Task | Tests |
|---|---|---|
| §1.1 the wrong subject | T4, T5 | xreview V5, V8, W11, F15 |
| §1.2 only two command shapes | T6-T8 | guard B, C, H-K, L-O |
| §1.3 no freshness check | T3, T6 | ledger F17; guard C10 |
| §1.4 ledgers split per checkout | T1, T5 | ledger C4-C7; xreview W19 |
| §1.5 unlocked appends | T2, T5 | ledger E9-E17, E21-E36; xreview W23-W25 |
| §2 goals | all | the rows below |
| §3.1 target, default branch, normalization, fingerprint | T1 | ledger A1-A47, B1-B21, D1-D6 |
| §3.2 entries, idempotency, a review's state, v1 | T2, T3 | ledger E1-E8, F12, F20, F21 |
| §3.3 location, key, `repo` file | T1, T2 | ledger C1-C3, E2 |
| §3.3 the lock | T2, T5 | ledger E9-E17, E21-E36; xreview W23-W25 |
| §3.3 pending write fatal, receipt write warns | T4, T5 | xreview V9-V12, W8-W10, W23-W25, F11 |
| §3.4 dispatch | T4 | xreview V1-V27 |
| §3.5 collect | T5 | xreview W1-W25, D10, F1, F14, F15 |
| §3.6 gated shapes, plain grammar, fast path | T6-T8 | guard A, B, C16-C22, F1-F4, H, L, O |
| §3.6 creation reads the remote head; project and forks | T7 | guard H1, H2, J1-J4, K1-K47 |
| §3.6 forge merges pinned, never deferred | T7, T8 | guard I10, M1-M11, N1-N5, P10-P16 |
| §3.6 destination commit and decision | T3, T6-T8 | ledger F1-F33; guard C5, I1-I4, N3, N4 |
| §3.6 fails closed | T3, T6-T8 | ledger F27-F32; guard D1-D6, I11, I12, J3, J4, K9, N6-N9 |
| §3.6 repository and host of a forge shape and of its lookups, numeric id, placeholders | T7, T8 | guard H9-H13, K3, K12-K47, L6-L9, P17-P39 |
| §3.6 deny message and the bypass | T6 | guard B11, C2-C4, C11, E1-E5 |
| §3.7 skill text, guard header | T6, T9 | skill: the §3.7 pins and the stale-text checks |
| §4 push and forge guards unchanged | T10 | the full run (the git-forge-guard suite) |
| §4 in-flight branches (v1 never opens) | T3, T5 | ledger F20; xreview W13-W15 |
| §4 safe-autonomy evaluation | T9 | measure-interventions attribution check; the dated note |
| §6 rollout | T10 hand-off | the driver |
| §7 rebase churn, stale lock, network only on a gated shape | T1, T2, T6 | ledger A4, E16; guard F1, F2 |

Each §5 bullet:

| §5 bullet | Task | Tests |
|---|---|---|
| clean rebase over another file keeps the fingerprint | T1 | ledger A3 (also ledger F26, guard N5) |
| rebase over a same-file change changes it | T1 | ledger A4 |
| one-line text change changes it | T1 | ledger A5 |
| whitespace-only change (indentation, inside a string) changes it | T1 | ledger A6-A8 |
| the same edit at a different location changes it | T1 | ledger A9, A10 |
| one-byte binary change changes it | T1 | ledger A11 |
| mode-only change changes it | T1 | ledger A12, A13 |
| gitlink change, even with `diff.ignoreSubmodules=all` | T1, T4 | ledger A14, A15; xreview V17 |
| an empty range has none | T1 | ledger A16, B19 |
| `main..feature` after `main` advanced: normalized and full | T1, T4 | ledger B1-B7; xreview V15, V16 |
| `origin/release/1.2...hotfix`: the remote ref, never a stale local one | T1 | ledger B8-B13 |
| a commit-based left side is partial | T1, T4 | ledger B14, B15, B20, B21; xreview V26, V27 |
| an approved full change opens every gated shape for its dest, and only that dest | T3, T6-T8 | ledger F4, F6; guard C5-C9, H3-H17, I1-I4, L1-L9, N3, N4 |
| one extra commit closes it | T3, T6 | ledger F17; guard C10 |
| a later `changes` verdict closes it | T3, T5 | ledger F10; xreview W6 |
| a newer pending review closes it | T3, T5 | ledger F7; xreview W5 |
| a failed receipt write leaves it closed | T3, T5 | ledger F15; xreview W8, W9 |
| re-collecting an old approve after a newer `changes` does not reopen it | T3, T5 | ledger F12, F13; xreview W4, W7 |
| a partial-range approve, spec and plan reviews, v1 receipts do not open it | T3 | ledger F18-F20 |
| each create and merge form, `glab mr new`/`accept`, `gh pr new`, `gh api` PUT/POST pulls | T7, T8 | guard H3-H13, L1-L9 |
| the GraphQL mutations are denied | T8 | guard O1-O4, O6 |
| `git -C <path> merge`: gated on the default branch, not on another | T6 | guard C8, A11, A12 |
| `git switch main && git merge x` and `x; glab mr create` denied as compound | T6 | guard B1, B2, B18-B24, B28-B30 |
| `cd <path> && glab mr create` checked in that path | T7, T6 | guard H17, C7 |
| `GH_REPO=o/r gh pr create`, `GIT_DIR=… git merge x`, `env … glab mr merge` denied | T6 | guard B5-B7, B14 |
| an unpinned forge merge is denied | T8 | guard M1-M4 |
| a deferred merge is denied, even pinned | T8, T7 | guard M5, M7-M10, P10-P16, I10 |
| a CLI creation without `--target-branch`/`--base` is denied | T7 | guard I5-I8 |
| a pin whose fingerprint is unapproved is denied | T8 | guard N1, N2 |
| a rebased pin with an unchanged fingerprint is allowed | T8 | guard N5 |
| a creation whose remote head differs from the approved local branch is denied | T7 | guard J1, J2 |
| a fork source is denied | T7, T8 | guard K4-K6, P7-P9 |
| `rg 'glab mr merge'` and a commit message with "merge" are not gated | T6 | guard A2, A3 |
| spec and plan dispatches with no `--diff` still work | T4 | xreview V1-V4 |
| a pre-merge dispatch whose pending write fails is refused | T4 | xreview V9-V12 |
| fail closed: no repository | T6, T7 | guard D1, D2, K9 |
| fail closed: head missing locally | T7, T3 | guard J3, J4; ledger F29 |
| fail closed: forge lookup failure | T8 | guard N6, N7 |
| fail closed: unreadable ledger | T6, T3 | guard D3-D5; ledger F32 |
| multi-repository: a pending entry and a receipt in each ledger, each opening its own gate | T5, T4 | xreview W16-W18, V18-V20 |
| worktrees: a review collected in a harness worktree opens the main checkout's gate | T5, T1 | xreview W19; ledger C5 |
| isolation: paths colliding under `/`→`_` get separate ledgers, never sharing an approval | T3, T1 | ledger G1-G5, C1, C2 |
| locking: 20 concurrent appends make 20 valid lines; a stale lock is broken | T2 | ledger E9-E12, E16, E17, E21-E36 |
| old turn records without a targets file still collect, as v1 | T5 | xreview W13-W15 (and the F14, F15 legacy records) |

Plan review round 1 (Codex, ten findings), each with the coordinator's ruling as applied:

| Finding | Task | Change | Tests |
|---|---|---|---|
| 1 (P1) the inlined diff can omit fingerprinted content | T1, T4 | one `patch()` with the fingerprint's flags renders every target's packet from the recorded base..tip | ledger A18-A47; xreview V24, V25 |
| 2 (P1) leading redirections and wrapper option arguments hide gated verbs | T6 | redirections read past anywhere; every word after a wrapper is a candidate; only bare `sudo` is plain | guard B12-B14, B18, C16, C17 |
| 3 (P1) help and merge-control exemptions match option values | T6 | `--help`/`-h` only first after the verb; `--abort`/`--quit`/`--continue` only alone | guard B15-B17, A8, A9 |
| 4 (P1) API calls ignore the endpoint host | T7, T8 | `--hostname`, absolute endpoints and `-R` hosts must be origin's; an absolute `/graphql` is GraphQL | guard K10-K18, P17-P26, O10 |
| 5 (P1) a PR/MR URL argument can transfer approval | T8 | a URL must name origin's host and project before any lookup | guard P1-P6 |
| 6 (P1) forge merges do not verify the source repository | T8 | GitLab project ids must agree; GitHub PRs must not be cross-repository | guard P7-P9 |
| 7 (P1) deferred merges through a merge queue or train | T8 | `mergeQueue` (GraphQL) and `merge_trains_enabled` lookups; non-null, true or failed is denied | guard P10-P16 |
| 8 (P2) the stale-lock break can steal a fresh lock | T2 | owner tokens, a `.break` lock, token-checked break and release | ledger E21-E29 |
| 9 (P2) commit-left ranges | T1, T4 | literal base for `C..B` and `C...B`; the packet shows base..tip | ledger B20, B21; xreview V26, V27 |
| 10 (P2) B12 cannot tell the two destination refs apart | T1 | `hotfix` starts at main's head, so the stale local branch gives another merge-base | ledger B12, B13 (mutation-checked) |

Before round 2, the coordinator added two rulings on substitutions:

| Gap | Task | Change | Tests |
|---|---|---|---|
| a command substitution, `$(…)` or backticks, inside double quotes (or unquoted backticks) runs its command | T6 | every substitution body outside single quotes and comments is scanned as a command, recursively | guard B19-B27, C18 |
| a here-document with an unquoted delimiter runs the substitutions in its body | T6 | those substitutions are scanned; the rest of the body, and quoted-delimiter bodies, stay data | guard B28-B32, A7 |

Plan review round 2 (Codex, four findings), each with the coordinator's ruling as applied.
Every new test was mutation-checked: it fails with the fix removed.

| Finding | Task | Change | Tests |
|---|---|---|---|
| 1 (P1) `gh api`/`glab api` without `--hostname` goes to an implicit host | T7, T8 | the effective host (gh: `GH_HOST`, gh's one configured host, github.com; glab: `GITLAB_HOST`/`URI`/`URL`, else every remote's host) must be origin's; the deny names `--hostname <origin host>` | guard K19-K34, P27, P28 |
| 2 (P1) redirections fused to a word hide a gated verb | T6 | operators are recognized anywhere outside quotes; a descriptor only where a word starts | guard B34-B38, C19-C22 |
| 3 (P2) a release can delete a lock a breaker just replaced | T2 | release checks and removes under `<ledger>.lock.break`; without it in time, it leaves the lock and warns | ledger E30-E32 |
| 4 (P2) quoted here-document delimiters with punctuation | T6 | the delimiter is the whole shell word; the closing line is compared unquoted; tabs stripped only for `<<-` | guard A15-A19, B32, B33, B39 |

Plan review round 3 (Codex, two findings), each with the coordinator's ruling as applied.
Every new test was mutation-checked: it fails with the fix removed.

| Finding | Task | Change | Tests |
|---|---|---|---|
| 1 (P1) forge lookups do not inherit the validated host | T7, T8 | `check_api_host` returns origin's host, and every MR/PR, project-id, merge-train and merge-queue lookup passes it (`--hostname <host>`, `gh pr view <n> -R <host>/<owner>/<repo>`) on origin's project path. A CLI verb's own host is checked too: a bare `-R`, `GH_REPO` or `GITLAB_REPO` takes the CLI's default host, and `GITLAB_API_HOST` must be origin's. glab's `-R HOST/PATH`, which glab reads as another project's path, is denied | guard H15, K35-K47, P29-P39 |
| 2 (P2) stale break-lock recovery races | T2, T5 | the break lock is never broken automatically; a stale one makes every writer fail closed, naming the path to remove by hand; collect's warning carries the helper's reason | ledger E27, E28, E33-E36; xreview W23-W25 |
