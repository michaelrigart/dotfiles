# Merge-gate allowlist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented (branch `feat/merge-gate-allowlist`; no MR, a dotfiles line)

> **Completed; do not run again.** Tasks 1 and 2 were built, then withdrawn after four review
> rounds found commands the gate read differently from the shell. The branch ships only the
> tightenings the rounds produced. What shipped and why: the spec's §11.

**Goal:** The pre-merge gate stops denying merges of origin's default branch in a compound, and
writes to MR/PR comments, threads, pipelines, titles and descriptions through `glab api`/`gh api`.

**Architecture:** Two additions to `dot_claude/xreview-guard.py`. `api_exempt` makes an
allowlisted API write not a gated verb at all. A sync filter in `main` drops `git merge
origin/<default>` candidates before the gate decides between "not gated", "plain" and "compound".
Everything else, the shell front included, is unchanged.

**Tech Stack:** Python 3.9 (`/usr/bin/python3`: no `match`, no `X | Y` unions), bash test suite.

**Spec:** `docs/superpowers/specs/2026-11-13-merge-gate-allowlist-design.md`

## Global Constraints

- Nothing that proposes or lands a change passes without the receipt it needs today.
- Each exemption is a positive match on a strict form; a command that misses it falls through to
  today's decision.
- The gate's deny messages, the shell front's fast path and fallbacks, `xreview-ledger.py`, the
  `cross-review` skill and `xreview` are not edited.
- Fixtures use `acme/app` on `forge.example`; no private host, client or repository name anywhere.
- Never run a gated forge verb (`glab mr`/`gh pr`/`az repos pr` `create|merge|update`) for real,
  `--help` included. The suite's stubs and the guard's allowlists are the reference.
- Run suites by executing them (`./tests/run.sh xreview-guard`), never with an interpreter
  prefix. Implementers run `./tests/run.sh xreview-guard xreview-skill hook-path` and no more.
- Comments say a non-obvious why and never cite tasks, rounds, reviews or spec sections.
- A Bash command that mentions a gated verb unquoted is denied by the deployed gate: write commit
  messages with `git commit -F <file>` or a quoted `<<'EOF'` here-document.

## Review Focus

- A sync whose directory the gate guesses wrong (a second `cd`, `pushd`): expected deny unless
  the first `-C` is absolute. Task 2, row S5.
- A ref that looks like origin's default but resolves elsewhere (a local branch `origin/main`,
  a repository whose default is `develop`): expected deny. Task 2, rows S6 and S7.
- An exempt path with something the forge may read differently (`..`, a `%` after the project,
  `:branch`): expected deny. Task 1, row R2.
- An update that carries one allowed field and one other (`description` with `target_branch`):
  expected deny. Task 1, row U2.
- A compound holding a sync and a real gated verb: expected deny. Task 2, row S3.

---

### Task 1: API exemptions

**Depends on:** none

**Files:**
- Modify: `dot_claude/xreview-guard.py` (`parse_api`, `api_gated`, `api_unplaced`, new
  `api_exempt` beside them, the header comment)
- Test: `tests/xreview-guard.test.sh` (section O; row O7 rewritten, rows R0-R2, U1-U2 added)

**Interfaces:**
- Produces: `api_exempt(args, tool) -> bool`; `parse_api(...)["input"]` (True when `--input` is
  given; `["body"]` keeps its meaning).

- [ ] **Step 1: Write the failing rows** in section O, in the suite's `is`/`decision`/`denies`
  style, from `$W`:
  - O7 rewritten, each `allow`: `glab api -X POST projects/:id/merge_requests/7/notes -f body=hi`;
    `glab api -X POST projects/acme%2Fapp/merge_requests/7/discussions/0a1b2c/notes -f body=hi`;
    `glab api -X PUT "projects/4242/merge_requests/7/discussions/0a1b2c?resolved=true"`;
    `glab api -X POST projects/:fullpath/merge_requests/7/pipelines | jq .id`;
    `glab api --method POST https://forge.example/api/v4/projects/4242/merge_requests/7/notes --input note.json`;
    `gh api repos/acme/app/pulls/9/comments -f body=hi`;
    `gh api repos/{owner}/{repo}/pulls/9/comments/55/replies -f body=hi --jq .html_url`;
    `gh api -X PATCH repos/acme/app/pulls/comments/55 -f body=hi`;
    `gh api repos/acme/.github/pulls/9/comments -f body=hi`.
  - R0: `allow` for `ID=$(glab api -X POST projects/:id/merge_requests/7/pipelines | jq .id)` and
    `sh -c 'glab api -X POST projects/:id/merge_requests/7/notes -f body=x'`; `deny` for
    `sh -c 'glab api -X PUT projects/:id/merge_requests/7/merge'` and
    `glab api -X POST projects/$P/merge_requests/7/notes -f body=x`.
  - R1, each `deny`: PUT `projects/:id/merge_requests/7/rebase`; POST `…/7/approve`;
    POST `…/7/notes/5/award_emoji`; `gh api -X POST repos/acme/app/pulls/9/reviews -f event=APPROVE`;
    `gh api -X PUT repos/acme/app/pulls/9/update-branch`. And
    `glab api -X PUT projects/:id/merge_requests/7/merge -f sha=<40 hex>` still reaches the
    ledger: `denies … 'no full-range pre-merge review'` is 1 (use the phrase the suite's other
    unreviewed-merge rows match).
  - R2, each `deny`: `…/7/notes/../merge` with `-X PUT`; `…/7/notes%2F..%2Fmerge`;
    `projects/:id/merge_requests/:branch/notes`; `projects/a%2F..%2Fb/merge_requests/7/notes`;
    `glab api -X POST projects/:id/merge_requests/7/notes projects/:id/merge_requests/7/merge`;
    `glab api -X POST projects/:id/merge_requests/7/notes --input x/merge_requests/b.json`;
    `glab api -X POST projects/:id/:seg/7/notes --placeholder seg=merge_requests`.
  - U1, each `allow`: `glab api -X PUT projects/:id/merge_requests/7 -F description=@d.md --silent`;
    `glab api --method PUT projects/acme%2Fapp/merge_requests/7 -f title=x -F description=@d.md | jq .iid`;
    `glab api -X PUT "projects/:id/merge_requests/7?title=x"`;
    `gh api -X PATCH repos/acme/app/pulls/9 -f body=x -f title=y`.
  - U2, each `deny`: the glab update with `-f description=x -f target_branch=release`; with
    `-f state_event=close`; with `--input body.json`; with `-F description=@d.md --input b.json`;
    with no field; `"…/merge_requests/7?target_branch=release" -f title=x`;
    `glab api -X POST projects/:id/merge_requests/7 -f title=x`;
    `gh api -X PATCH "repos/acme/app/pulls/9?base=release" -f body=x`;
    `gh api -X PUT repos/acme/app/pulls/9 -f body=x`. Row O8 stays as it is.

- [ ] **Step 2: Run `./tests/run.sh xreview-guard`.** Expected: the new allow rows fail (deny),
  the deny rows already pass.

- [ ] **Step 3: Implement.**
  - `parse_api`: add `"input": False` to `call`; set it where `--input` sets `body`.
  - Module constants beside `NAMES_MR_PATH`:

    ```python
    NAME = r"[A-Za-z0-9._-]+"      # .github is a name; a .. anywhere is refused apart
    GITLAB_PROJECT = r"(?:\d+|:id|:fullpath|{0}(?:%2[Ff]{0})+)".format(NAME)
    GITHUB_PROJECT = r"(?:\{{owner\}}/\{{repo\}}|{0}/{0})".format(NAME)
    EXEMPT_PATH = {
        "glab": re.compile(r"projects/{}/merge_requests/\d+/(?:notes(?:/\d+)?|discussions"
                           r"(?:/[0-9a-f]+(?:/notes(?:/\d+)?)?)?|pipelines)".format(GITLAB_PROJECT)),
        "gh": re.compile(r"repos/{}/pulls/(?:\d+/comments(?:/\d+/replies)?|comments/\d+)"
                         .format(GITHUB_PROJECT)),
    }
    UPDATE_PATH = {
        "glab": (re.compile(r"projects/{}/merge_requests/\d+".format(GITLAB_PROJECT)), "PUT",
                 {"title", "description"}),
        "gh": (re.compile(r"repos/{}/pulls/\d+".format(GITHUB_PROJECT)), "PATCH",
               {"title", "body"}),
    }
    ```
  - `api_exempt(args, tool) -> bool`. True only when all hold: `api_options` yields exactly one
    positional; exactly one word of `args` satisfies `names_gated_path`, and it is that
    positional; the endpoint is `literal`; the parsed method is POST, PUT or PATCH; the path
    (`endpoint_parts(endpoint)[0]`, **not** unquoted) holds no `..`; and either
    `EXEMPT_PATH[tool]` full-matches the path, or the update form holds: `UPDATE_PATH[tool]`'s
    pattern full-matches, the method equals its method, `call["input"]` is False, gh's endpoint
    holds no `?`, and the field names (the call's fields, plus for glab the endpoint's query
    fields) are non-empty and a subset of its set.
  - `api_gated(call)` keeps its signature. In `gated_verb` and `reordered`, the two places that
    test `api_gated(...) or api_unplaced(...) or api_placeholder(...)`, an exempt call counts
    only through `api_placeholder`: `api_placeholder(a, tool) or (not api_exempt(a, tool) and
    (api_gated(parse_api(a, tool)) or api_unplaced(a, tool)))`. Put that in one helper,
    `api_is_gated(args, tool) -> bool`, and call it from both.
  - Header comment of the file: one sentence after the plain-form list saying which API writes
    are never gated (comments, threads, pipeline starts, a title or description update).

- [ ] **Step 4: Run `./tests/run.sh xreview-guard xreview-skill hook-path`.** Expected: every
  suite passes with consistent totals.

- [ ] **Step 5: Commit** `dot_claude/xreview-guard.py tests/xreview-guard.test.sh`, message
  "Stop gating MR/PR comment, thread, pipeline and description writes through the API".

### Task 2: Syncs in a compound

**Depends on:** Task 1 (same files; nothing of Task 1's is called)

**Files:**
- Modify: `dot_claude/xreview-guard.py` (`candidates`, `judge_git_merge`, `main`, new helpers,
  the header comment), `dot_claude/executable_xreview-guard.sh` (header comment only)
- Test: `tests/xreview-guard.test.sh` (row B9 rewritten; rows S1-S8 in a new section after the
  sync rows C29-C30)

**Interfaces:**
- Produces:
  - `candidate_spans(tokens) -> list of (start, end)`; `candidates(tokens)` returns
    `[tokens[s:e] for s, e in candidate_spans(tokens)]` as before.
  - `merge_dir(args, cwd) -> (cwd, i)`: the walk `judge_git_merge` does today over git's global
    options up to `merge` (raising the same `Deny`s), returning the directory and the index of
    `merge`.
  - `names_origin_default(top, ref, dest) -> bool`: `git rev-parse --symbolic-full-name <ref>`
    prints `refs/remotes/origin/<dest>`.
  - `is_sync(tokens, start, end, cwd, ledger) -> bool`.

- [ ] **Step 1: Write the failing rows.**
  - B9 rewritten: from `$SIDE`, `git fetch origin && git merge origin/main` is `allow`.
  - S1, from `$W` (on main), each `allow`: `git switch main && git merge --ff-only origin/main | tail -1`;
    from `/` with the payload cwd `/`: `git -C $W merge -q --ff-only origin/main && git -C $W log -1`
    (`$W` expanded by the test, so the guard sees an absolute literal);
    `cd $W && git fetch -q origin && git merge refs/remotes/origin/main; git status -sb`;
    `git merge --no-edit origin/main 2>&1 | tail -3` from `$SIDE`;
    `git merge --ff-only origin/main && git merge --ff-only origin/main`.
  - S2, from `$W`, each `deny`: `git fetch origin && git merge feature` with `feature` moved to
    origin's main commit for the row (restore after); `git fetch && git merge origin/feature`
    (publish `feature` first if the section has not); `git fetch && git merge --ff-only @{u}`
    with main's upstream set as C30 does; `git fetch origin main && git merge FETCH_HEAD`;
    `git fetch && git merge origin/main feature`.
  - S3, each `deny`: `git merge --ff-only origin/main && git merge feature`;
    `git merge --ff-only origin/main && glab mr create --target-branch main`.
  - S4, each `deny`: `GIT_DIR=/tmp/x git merge origin/main && true`;
    `git -c merge.ff=only merge origin/main && true`; `git --git-dir .git merge origin/main && true`;
    `sudo git merge origin/main && true`; `R=$W; git -C "$R" merge origin/main` (the `$R`
    reaching the guard unexpanded); `true && env git merge origin/main`;
    `if true; then git merge origin/main; fi`.
  - S5: `deny` for `cd $W && cd sub && git merge origin/main`, `pushd $SIDE; git merge origin/main`
    and `cd "$D" && git merge origin/main` (`$D` unexpanded); `allow` for
    `cd /tmp && cd x; git -C $W merge --ff-only origin/main` (absolute `-C`).
  - S6: a third fixture repository whose `refs/remotes/origin/HEAD` names `develop`, on `develop`,
    with an `origin/main` ref: `git fetch && git merge origin/main` is `deny`, and
    `git fetch && git merge origin/develop` is `allow`.
  - S7: with a local branch named `origin/main` in `$W` (`git branch origin/main feature`, deleted
    after), `git fetch && git merge origin/main` is `deny`.
  - S8, each `deny`: `echo "$(git merge origin/main)"`; `sh -c 'git merge origin/main'`;
    `true && (cd sub; git merge origin/main)`.

- [ ] **Step 2: Run `./tests/run.sh xreview-guard`.** Expected: B9, S1, S5's allow and S6's allow
  fail; the deny rows pass.

- [ ] **Step 3: Implement.**
  - Refactor first, behaviour unchanged: `candidate_spans`, `merge_dir`,
    `names_origin_default`, with `judge_git_merge` using the last two.
  - `is_sync(tokens, start, end, cwd, ledger)` for the candidate `tokens[start:end]`, whose
    `gated_verb` kind is `merge-local`. False unless every rule of spec §4.1 holds:
    1. `start == 0`, or `tokens[start - 1]` is an operator; and `tokens[start]` names `git`.
    2. `merge_dir` accepts the global options (a `Deny` from it means False).
    3. `parse_flags(after merge, MERGE_VALUE)` leaves exactly one positional; it is `literal`
       and matches `(?:refs/remotes/)?origin/.+` whole.
    4. The base directory is `cwd`, or the target of a leading `cd <literal> &&` (the form
       `parse_plain` reads). If any other token before `start` is `cd`, `chdir`, `pushd` or
       `popd`, including a leading `cd` that is not that form, the directory is unknown: then
       the candidate's first `-C` value, after `os.path.expanduser`, must be absolute.
    5. `toplevel(dir)` succeeds (a `Deny` means False) and
       `names_origin_default(top, ref, ledger.default_branch(top))`.
  - `main`: after `scan`, build the gated candidates from `candidate_spans`. When `hidden` is
    False and one of them is `merge-local`, load the ledger and drop those `is_sync` accepts.
    None left: return (allowed). Otherwise continue exactly as today (`parse_plain`, then
    `judge` or `PLAIN`); `gated` stays True for the internal-error path. A plain single
    non-sync merge must reach `judge_git_merge` unchanged.
  - Header comments: in `xreview-guard.py`, after the sentence on plain commands, say that a
    merge of origin's default branch is never gated where it starts a simple command of its
    own, since it lands only what origin's default branch already holds; in
    `executable_xreview-guard.sh`, add the same clause to the "Gated:" paragraph.

- [ ] **Step 4: Run `./tests/run.sh xreview-guard xreview-skill hook-path`.** Expected: all
  pass. Rows B1, B6, B8 and C29-C30 must be untouched and green.

- [ ] **Step 5: Commit** the three files, message "Stop gating a merge of origin's default
  branch in a compound".

### Task 3: Final runs (the controller's)

**Depends on:** Task 2

- [ ] Run the source guard on real payloads from a scratch clone, sandboxed, and record the
  decisions: a sync chain, a pipeline start, a description update, and `git merge feature` on
  the default branch (still denied).
- [ ] `./tests/run.sh --changed`; quote the heavy suites' `needs:` lines.
- [ ] Final whole-branch review, fix wave, then set the spec's and this plan's
  `**Status:** Implemented`, mark this plan completed, and commit.
- [ ] Codex pre-merge review on the full range `main...feat/merge-gate-allowlist`; push; no
  commit after the approval.
