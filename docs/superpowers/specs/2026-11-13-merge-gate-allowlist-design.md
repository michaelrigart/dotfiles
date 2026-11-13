# Merge-gate allowlist: stop denying syncs and MR/PR housekeeping

**Status:** Approved
**Date:** 2026-11-13
**Sign-off:** Michael, 2026-11-13, with every recommendation in §10, relayed by the driver
session. Codex spec review: approve in round 3 (`xr-1794600398-68907e28`; rounds 1 and 2,
`xr-1794600294-92ed7a4a` and `xr-1794600363-c7457584`, one P2 each, both fixed).
**Branch:** `feat/merge-gate-allowlist`, in the `wt` checkout
`~/.local/share/chezmoi-feat-merge-gate-allowlist`, from `main` at `4c35ad4`
**Related:** `2026-10-02-xreview-receipt-binding-design.md` (§3.6 "Plain commands only" and
"Unresolved forms are denied" are narrowed here; nothing else in it changes).
`2026-11-12-xreview-trust-design.md` (the gate as it stands; its §7 limits and §11 decisions are
not reopened). Source: item 23 of the vault note `2026-11-11-agent-setup-full-review`, approved
by Michael on 2026-11-12.

## 1. Why

The pre-merge gate denies commands that neither propose nor land a change. The 2026-11-11 setup
review sampled 64 denials in 14 days and called about 50 of them false positives. Each one costs
an agent a retry, and in an unattended run it teaches the agent that the gate's denials are
noise.

Item 23 names three classes: fast-forward syncs, merges into non-default branches, and MR
sub-resource writes. This spec allows those classes by positive match on a strict form. Every
other command is decided exactly as today.

## 2. Measured

Every gate denial in the Claude Code transcripts on this Mac, 2026-10-05 to 2026-11-13, joined
to the command that drew it (159 denials). "Verified" below means read in a file or measured;
the classification itself was done by pattern and read by hand, so its counts are about ±3.

| Class | Denials | After this change |
|---|---|---|
| A `git merge` of origin's default branch, in a chain or a pipe (`git switch main && git merge --ff-only origin/main`, `git merge --no-edit origin/main 2>&1 \| tail -3` on a feature branch) | about 35 | allowed (§4.1) |
| A write to an MR/PR sub-resource through `glab api`/`gh api`: 14 pipeline starts, 2 comment replies | 16 | allowed (§4.2) |
| A description update through the API with `-F description=@<file>` | 7 | allowed (§4.3) |
| A merge of another ref into a non-default branch, as the first command of a compound | 4 | D1 |
| A merge of another ref, after other commands, or with the path in a shell variable (`R=…; git -C $R merge …`), test fixtures included | about 22 | denied as today |
| A creation in a pipe or a chain (`glab mr create … 2>&1 \| tail -3`) | 13 | denied as today |
| No approving receipt, a partial approval, an unpinned or short pin, a branch not on origin | about 40 | denied as today (the gate working) |
| A command naming another project than the checkout's origin | 14 | denied as today |
| The rest: an update whose body is a JSON file (2), a forge rebase (1), a creation with an unreadable body (3), a GraphQL file (1), a mention (1) | 8 | denied as today |

So about 58 of 159 denials go away, and about 62 with D1. Of the roughly 105 denials that were
not the gate working as designed, that is a little over half.

Verified in the code at `4c35ad4`:
- A compound holding any gated verb is denied before the gate reads a branch
  (`xreview-guard.py:2308-2313`). That is why a sync in a chain is denied on any branch, although
  the same sync as a plain command passes (`:1288-1293`).
- Every POST, PUT or PATCH to a path naming `merge_requests` or `pulls` is gated
  (`:887-896`), and only the create and merge endpoints can pass (`:2212-2225`). The suite pins
  a note as denied (`tests/xreview-guard.test.sh`, row O7).
- `glab mr update`, `glab mr note`, `gh pr edit` and `gh pr comment` are not gated verbs
  (`:766-773`). An agent can already retitle, redescribe, retarget and comment through the CLI.

## 3. Constraints

- **The receipt rule is untouched.** Nothing that proposes or lands a change passes without the
  receipt it needs today.
- **No bypass by another spelling.** Each exemption matches one strict form. A command that
  misses the form by anything falls through to today's decision, which is a deny.
- **Nothing hidden passes.** A substitution, a nested shell or a here-document that runs a gated
  verb is denied as today, a sync included: a sync depends on the directory it runs in, which
  the gate reads only at the top level. An exempt API call (§4.2, §4.3) is not a gated verb
  anywhere, since its own words decide what it does.
- **The guards are frozen** (security locks §9). This change adds no rule a deny rule could
  express: it removes false denies inside the gate, which only the gate can do. No guard is
  retired and no never-rule is added.
- **No prompt is added.** The gate still only denies or stays silent.
- **Withdrawn in the review, so not done here:** cutting the gate to plain forms. The grammar,
  the hidden-verb readings and the fallbacks stay as they are.
- The repository is public: fixtures use `acme/app` on `forge.example`, as the suite does.

## 4. Design

### 4.1 A merge of origin's default branch is never gated

Merging `origin/<default>` lands work that is already on origin's default branch. On the default
branch it is a sync; on any other branch it is a merge into a non-default branch. Neither needs
a receipt, and the answer does not depend on the current branch. So the gate can decide it in a
compound, where it cannot know the branch.

A `git merge` is a **sync** when all of this holds (rules 1 to 3 were tightened during
execution, §10):

1. **It is a simple command of its own, written in plain characters.** The command is split at
   its unquoted `;`, `&`, `|` and newlines, redirections dropped. The merge's own part may hold
   only letters, digits, `_`, `.`, `/`, `=`, `-` and blanks: no quote, backslash, parenthesis,
   `$`, glob character, brace or `~`. Its words are then exactly what any shell passes to git.
   Its first word is `git`. So an assignment (`GIT_DIR=x git merge …`), a wrapper, `sudo`, a
   keyword (`then git merge …`), a subshell and a mention (`echo git merge …`) are not syncs.
2. **Its global options are the plain form's:** `-C <path>` and the flags in `GIT_FLAGS`. `-c`,
   `--git-dir`, `--work-tree` and the rest are not syncs.
3. **It names one ref, spelled `origin/<name>` or `refs/remotes/origin/<name>`, and carries
   only listed flags:** `--ff-only`, `--ff`, `--no-ff`, `--no-edit`, `--no-commit`, `-q`,
   `--quiet`, `--stat`, `--no-stat`, `-n`, `--autostash`, `--no-autostash`, `-v`, `--verbose`,
   each as an exact word. No option that takes a value is listed: git accepts a unique prefix
   of a long option (`--mess` is `--message`), so the gate cannot tell an unknown option's value
   from the ref. `@{u}`, `FETCH_HEAD` and `HEAD`-relative names depend on the branch or on the
   last fetch, so in a compound they are not syncs. As a plain command they are judged as today.
4. **The directory is known.** It is the hook's working directory, moved by one leading
   `cd <path> &&` in plain characters and by the command's own `-C` paths. If the word `cd`,
   `chdir`, `pushd` or `popd` stands anywhere else before the merge, the directory is unknown,
   and only a merge whose first `-C` path is absolute can be a sync.
5. **The ref resolves to origin's default branch of that repository:**
   `git rev-parse --symbolic-full-name <ref>` prints `refs/remotes/origin/<default>`, with
   `<default>` from the ledger's `default_branch`, as the plain form checks today. A local
   branch named `origin/main` makes the name resolve elsewhere, so it is no sync.

**The decision.** After reading the command, the gate replaces every sync with a no-op and reads
what is left as it does today. Then:
- no gated verb left: the command is allowed, whatever else it holds;
- otherwise: as today. One plain gated verb is judged; anything else is denied as a compound.

So `git fetch -q origin && git switch -q main && git merge --ff-only origin/main && git branch -d
feature` passes, and `git merge --ff-only origin/main && git merge feature` is denied. A sync
with a message (`-m "…"`), a quoted ref or a `~` path is denied as a compound, as before this
change; the agent runs it as a plain command.

**What a compound adds.** The plain sync is allowed today. In a compound the gate reads the
directory and the ref before the earlier commands run. Rule 4 covers a plain change of
directory, and a fetch from origin moves `origin/<default>` to a newer commit that is equally on
origin's default branch. An earlier command that deliberately changes either is an accepted
limit (§6).

### 4.2 Writes to an MR/PR sub-resource are not gated

A write (POST, PUT or PATCH) through `glab api` or `gh api` is exempt when its endpoint is one of
these paths, matched whole, after the scheme, host and `api/v3` or `api/v4` prefix are dropped:

| Forge | Path under the MR/PR | What it does |
|---|---|---|
| GitLab `projects/<project>/merge_requests/<n>/` | `notes`, `notes/<id>` | a comment |
| | `discussions`, `discussions/<id>`, `discussions/<id>/notes`, `discussions/<id>/notes/<id>` | a thread, a reply, resolving one |
| | `pipelines` | starts the MR's pipeline |
| GitHub `repos/<owner>/<repo>/pulls/<n>/` | `comments`, `comments/<id>/replies` | a review comment, a reply |
| GitHub `repos/<owner>/<repo>/pulls/` | `comments/<id>` | edits a review comment |

- `<n>` and `<id>` are digits. A GitLab discussion id is hexadecimal.
- `<project>` is digits, `:id`, `:fullpath`, or an encoded path: name segments of letters,
  digits, `.`, `_` and `-` joined by `%2F`. `<owner>/<repo>` are such names, or `{owner}/{repo}`.
- The path is matched as written. A `%` outside `<project>`, a `..`, a `:branch` or `{branch}`
  segment, or any other character fails the match.
- The endpoint must be the only word of the call that names an MR/PR path (`names_gated_path`).
  A second such word is the case the existing net denies, and it stays denied.
- A writing `glab api` call carrying `--placeholder` stays denied before any of this
  (trust spec §5.6).
- On GitHub, and for a GitLab pipeline start, the body may come from anywhere (`-f`,
  `-F body=@file`, `--input`): the path decides what the call does.
- **A GitLab note or thread must show its field names** (amended during execution, §10). GitLab
  runs quick actions in a note's body, also through the API, and
  `POST …/merge_requests/<n>/notes` takes `merge_request_diff_head_sha`, which its documentation
  calls "required for the /merge quick action": with it, a note whose body is `/merge` merges
  the MR or sets auto-merge (docs.gitlab.com/api/notes and
  `lib/gitlab/quick_actions/merge_request_actions.rb`, read 2026-11-13). So a write to `notes` or
  `discussions` is exempt only when it carries no `--input` and every field name, the query
  string's included, is `body`, `resolved`, `commit_id` or `position[…]`. A field's value may
  still come from a file. Without the SHA field `/merge` does nothing; the discussions, note-edit
  and MR-update endpoints do not accept it.
- An option word holding `$`, a backtick or `{` makes the call not exempt, and so does a `;` in
  the endpoint: either could carry a field or an option the gate does not read.
- The project and the host are not checked. A comment or a pipeline start proposes and lands
  nothing, on any project.

Not in the table, so denied as today: `merge`, `rebase` (rewrites the source branch on origin; 1
denial), `approve`, `unapprove`, `approvals`, `reset_approvals`, GitHub's `reviews`,
`requested_reviewers` and `update-branch`, and anything new a forge adds. The CLIs' own
`glab mr approve`, `glab mr rebase` and `gh pr review` stay as they are (trust spec §7).

An exempt call is not a gated verb, so it also passes in a pipe or a chain
(`glab api -X POST …/pipelines | jq .id`), and inside a substitution or a nested shell
(`ID=$(glab api -X POST …/pipelines | jq .id)`, `sh -c 'glab api …/notes -f body=x'`). That is
deliberate: the exemption reads nothing but the call's own literal words, which are the same
words wherever the call stands, and a word holding `$` or a backtick fails the path match. The
same holds for §4.3.

### 4.3 A title or description update through the API is not gated

`glab mr update --description` takes its text inline only, so agents send a long description
from a file through the API, and the gate denies it because the body comes from a file.

A write is exempt when:
- GitLab: the method is PUT and the path is `projects/<project>/merge_requests/<n>`;
  GitHub: the method is PATCH and the path is `repos/<owner>/<repo>/pulls/<n>`, with no query
  string (as for every gated gh write);
- it carries at least one field, and every field's name is `title` or `description` (GitLab),
  `title` or `body` (GitHub). For glab the query string's fields count too, as today;
- it carries no `--input`. A field read from a file (`-F description=@file`) is fine: the file
  supplies the value, never the name.

Any other field (`target_branch`, `base`, `state_event`, `state`) leaves the call gated and
denied, as row O8 pins today. This allows nothing `glab mr update` and `gh pr edit` do not
already allow ungated.

### 4.4 A GraphQL note that can merge is denied (scope added during execution)

The same fact reaches the deployed gate, apart from this line: GitLab's GraphQL `createNote`
mutation takes `mergeRequestDiffHeadSha` (gitlab-org/gitlab issue 354091), so a GraphQL note
with `/merge` merges with no receipt, and the gate's mutation list does not name it. A GraphQL
call whose text holds `mergeRequestDiffHeadSha` is now denied with the existing GraphQL message.
This tightens the receipt rule the gate exists for; a deny rule cannot read a GraphQL body.

### 4.5 Where it goes in the code

All of it is in `dot_claude/xreview-guard.py`. The shell front, its fast path, the fallbacks and
the ledger are untouched.

- `parse_api` records `--input` apart from a field read from a file.
- A new `api_exempt(args, tool)` holds §4.2 and §4.3. `api_gated` and `api_unplaced` both treat
  an exempt call as not gated; `api_placeholder` is checked first, as now.
- `judge_git_merge`'s walk over the global options, and its "names origin's default" test, move
  into two helpers that the sync test shares. The plain form's behaviour does not change.
- `main` drops syncs before it decides between "not gated", "plain" and "compound".
- The header comments of both guard files say what is exempt.

Estimate: about 90 lines of non-test code. Inferred, not measured.

### 4.6 Cost

A compound holding a `git merge` now loads the ledger helper and runs three git calls per merge
candidate (toplevel, the default branch, the ref's full name). Today it is denied without them.
The helper already starts for such a command. API calls gain one regular-expression match.

## 5. Prompts

None added or removed.

## 6. Accepted limits

New with this change:
- A command earlier in the same compound that deliberately changes what `origin/<default>`
  names or where git runs: `git update-ref refs/remotes/origin/main …`, a fetch with a refspec
  into that ref, `git remote set-url origin …` before a fetch, a local branch created under the
  name `origin/main`, `export GIT_DIR=…`, an `eval` or a sourced script that changes directory,
  a shell function named `git`. Most already work today as one call before a plain sync; the
  ones that need the same shell (`eval`, a function, the shadowing branch) are new with the
  compound. None reaches origin without the push guard's ask.
- A comment, a thread or a pipeline start on any project the agent's token reaches, through the
  API. The CLI verbs already allow the same.
- A sub-resource a forge later gives a landing meaning under one of the names in §4.2.
- GitLab quick actions that need no SHA (`/approve`, `/rebase`, `/target_branch`, `/close`) in a
  note or a description sent through the API. The ungated CLI verbs already run them
  (`glab mr note`, `glab mr update --description`), so the exemption adds no reach; approvals
  and retargets are accepted limits in the trust spec's §7, and the pinned merge reads the
  destination again.

Unchanged: everything in the trust spec's §7.

## 7. Rejected

| Alternative | Why not |
|---|---|
| Judging every gated verb in a compound, not only syncs | It needs the branch, the directory and the environment as they will be when the verb runs, which is what the plain-form rule exists to avoid. |
| Resolving `R=/path; git -C $R merge …` | About 12 denials, half of them test fixtures. It means evaluating shell assignments in a frozen guard. |
| Allowing a creation followed by `\| tail` | 13 denials, but a creation is a real gated verb, and not in item 23. One retry fixes each. |
| Exempting every write under `merge_requests/<n>/` except `merge` | A denylist: a new landing endpoint would pass until someone noticed. |
| Checking the project and host of an exempt API call | The call lands nothing wherever it goes, and the checks are the gate's most environment-dependent code. |
| Allowing `--input` for a description update | The gate would have to read a JSON file the agent can rewrite between the check and the call. `-F description=@file` does the same job. |
| An allow rule in `permissions.allow` | A hook's deny outranks it. |

## 8. Tests

`tests/xreview-guard.test.sh`, table rows beside the sections they extend. Each row pins an
exact decision. Not heavy; inferred growth about 5 s.

| Row | Pins | Catches |
|---|---|---|
| B9 rewritten | on a feature branch, `git fetch origin && git merge origin/main` is allowed | the main false deny |
| S1 | on the default branch: `git switch main && git merge --ff-only origin/main \| tail -1`; `git -C <abs> merge -q --ff-only origin/main && git log -1` from another directory; `cd <abs> && git fetch -q && git merge refs/remotes/origin/main` are allowed | the three measured spellings |
| S2 | in a chain, `feature` at the same commit as origin's main, `origin/feature`, `@{u}` and `FETCH_HEAD` are denied | a sync that is really a change |
| S3 | a sync beside another gated verb is denied (`… origin/main && git merge feature`, `… && glab mr create …`) | the filter swallowing a real verb |
| S4 | `GIT_DIR=x git merge origin/main && true`, `git -c a=b merge …`, `git --git-dir x merge …`, `sudo git merge …`, `-C "$R"` are denied | the context-changing forms |
| S5 | `cd <abs> && cd sub && git merge origin/main` and `pushd x; git merge origin/main` are denied; the same with an absolute `-C` is allowed | rule 4 |
| S6 | in a repository whose default branch is `develop`, `git fetch && git merge origin/main` on `develop` is denied | the default read per repository |
| S7 | with a local branch named `origin/main`, the chain is denied | a ref that resolves elsewhere |
| S8 | `echo "$(git merge origin/main)"` and `sh -c 'git merge origin/main'` are denied | nothing hidden passes |
| S10 | `git merge origin/main -m ';' feature`, the same with `\;`, `'|'`, `'&&'`, `')'` and a process substitution, and `git merge origin/main(N) feature` are denied | a quoted operator or a glob qualifier hiding a second ref |
| S11 | in a chain, `--mess origin/main`, `--into origin/main`, `-m msg origin/main`, `-qn`, `--` and `-s ours` are denied | an option that takes the ref as its value |
| S12 | in a chain, a quoted ref, a glob, a brace list, `=git`, a `~` path and a subshell are denied | a word the shell rewrites |
| S13 | a sync with a redirection, beside segments that hold quotes and quoted operators, is allowed | the plain-character rule reaching past the merge's own part |
| O7 rewritten | a note, a discussion reply, a resolve (PUT) and a pipeline start are allowed, plain and piped; so are gh's review comment, reply and comment edit | §4.2 |
| R0 | a pipeline start inside `$( )` and inside `sh -c '…'` is allowed; `sh -c 'glab api -X PUT …/7/merge'` and an endpoint `projects/$P/merge_requests/7/notes` are denied | the exemption holding where it stands, and only for literal words |
| R1 | `…/7/merge` (still judged), `…/7/rebase`, `…/7/approve`, `pulls/9/reviews`, `pulls/9/update-branch` are denied | the table growing by accident |
| R2 | `…/7/notes/../merge`, `…/7/notes%2F..%2Fmerge`, `…/:branch/notes`, a second word naming an MR path, and a writing call with `--placeholder` are denied | a path the forge reads differently |
| R3 | a GitLab note with `-f merge_request_diff_head_sha=…`, with the same name in the query string, with `--input`, and with an unknown field is denied; a diff note with `position[…]` fields and `-F body=@f` is allowed; gh's comment with `--input` stays allowed | a note that merges |
| R4 | an exempt call with an option word `--{input=b.json,silent}` or `--$Z`, and an update whose query holds `;`, are denied | an option or field the gate does not read |
| O11 | a GraphQL call whose query names `mergeRequestDiffHeadSha` is denied; a `createNote` without it is allowed | §4.4 |
| U1 | PUT with `-F description=@f`, with `-f title=x`, and gh's PATCH with `-f body=x` are allowed | §4.3 |
| U2 | the same with `target_branch`, `state_event` or `base` (O8), with `--input`, with no field, or gh with a query string is denied | a retarget through the update |

Before the pre-merge review: `./tests/run.sh --changed`. The guard's rows in the subject map put
`xreview-guard`, `xreview-skill` and `hook-path` in it; no heavy suite names the guard.

## 9. Rollout

- One line, one phase, with a plan; each task gets a review, and Codex reviews at spec, plan and
  pre-merge.
- The deployed gate guards this branch throughout. No step needs `XREVIEW_GUARD=off`.
- No state changes: no receipt, ledger or settings format is touched, and in-flight reviews are
  unaffected.
- After the merge Michael runs `chezmoi apply` on both Macs. The hook reads the files per call,
  so no session restart is needed.
- Texts left alone on purpose, because `chore/instruction-weight` edits them in parallel: the
  `cross-review` skill (its line on plain commands stays true for every verb that needs a
  receipt) and `xreview`'s refusal messages. The gate's own deny messages do not change.
- Rollback: revert the line and apply.

## 10. Decisions for Michael

**Decided at sign-off (Michael, 2026-11-13, relayed by the driver session):** D1 A (not built),
D2 yes, D3 the list as written, without `rebase`. He was also shown that an exempt API call
passes inside `$( )` and `sh -c` (§4.2) and the new accepted limits (§6). The options are kept
below as the record.

**Amended during execution (2026-11-13, ruled by the driver session on Michael's delegation and
reported to him):**
- §4.2 is narrowed: a GitLab note or thread must show its field names. The first task's review
  found that a note can merge (the fact and its sources are in §4.2).
- Quick actions that need no SHA are an accepted limit (§6).
- A GraphQL call naming `mergeRequestDiffHeadSha` is denied (§4.4): a hole in the deployed gate,
  older than this line, fixed here.
- §4.1's rules 1 to 3 are tightened: a sync is read from plain characters only, with a list of
  exact flags. The second task's review found that the first form read the command from words
  that had lost their quoting, so `git merge origin/main -m ';' feature` passed as a sync while
  git merged `feature`.

- **D1, a merge of another ref into a non-default branch, in a compound** (the third part of
  item 23's second class; 4 denials).
  - A (recommended): not built. §4.1 already covers the usual merge into a feature branch,
    which merges origin's default. What remains needs the current branch, so it could only be
    allowed as the first command of a compound, with rules for the pipe and `&` beside it: about
    25 more lines in a frozen guard for 4 denials in 6 weeks. The agent's retry as a plain
    command passes.
  - B: built, as "a `git merge` that is the first command, in a pipeline holding no other git or
    forge word and not in the background, is judged as a plain one".
- **D2, the description update (§4.3).** Recommended: yes. It goes one step past "sub-resource",
  since it writes the MR itself, but only fields the ungated CLI already writes, and it is 7 of
  the measured denials. Without it §4.3 and rows U1 and U2 are dropped.
- **D3, the sub-resource list (§4.2).** Recommended: as written, comments, threads and pipeline
  starts. The alternative adds `rebase` (1 denial); it rewrites a branch on origin, so it is
  left out.
