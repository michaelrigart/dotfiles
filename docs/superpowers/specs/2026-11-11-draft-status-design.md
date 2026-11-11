# Draft status for MR and PR spaces

**Status:** Approved
**Date:** 2026-11-11
**Sign-off:** Michael, 2026-11-11 (Codex spec review approved, `xr-1794357508-3017fb0b`); section 5
(freshness) was added at his sign-off and is reviewed with the plan
**Branch:** `feat/draft-status`, in the `wt` checkout `~/.local/share/chezmoi-feat-draft-status`
(the second dotfiles `wt` line; see `docs/superpowers/specs/2026-11-11-wt-dotfiles-design.md`,
section 5, on the unmerged `feat/wt-dotfiles`)
**Design approved:** Michael, 2026-11-11, in conversation

**Where this line runs.** The deployed instructions still say the dotfiles never use `wt`, and
until `feat/wt-dotfiles` is merged and applied a dotfiles sibling has none of the sandbox's
root-keyed write denials. Michael ruled on 2026-11-11 that this line runs in its `wt` checkout
anyway ("do wt for the git status"), with that gap accepted for it as for `feat/wt-dotfiles`.
The plan's implementers run in this checkout.

## Why

`dot_config/herdr/phase.sh` badges every linked-worktree space in the Herdr sidebar with a phase:
`active` (green, local work), `review` (yellow, an open MR) or `merged` (dim), plus the head
pipeline's result for an open MR. Two gaps hide a draft:

- An open **draft** MR is reported as `active`, with the draft icon and no MR number, in the same
  green as local work. A draft that is pushed and waiting reads like a branch nobody has opened.
- **GitHub** repositories get no MR/PR state at all: `repo_slug` accepts only `gitlab.com`. Half
  of Michael's repositories are on GitHub (tagteam, tafl, skald, hulder, linger, muninn, the
  dotfiles and others), so their spaces never show a PR, draft or not.

Michael wants a proper status for draft PRs and MRs.

## Goals

- An open draft MR or PR shows its own phase, `draft`, with its number and its CI result.
- GitHub PRs are looked up, so a GitHub space can show `draft`. Its `review`, `merged` and CI
  badges come with the same lookup.
- A status change shows in the sidebar promptly (section 5).
- Everything the script guarantees today still holds: one stable report source, exactly one
  token per group, stale data preferred over wiping badges on a failed lookup, and the hardening
  of an unsandboxed script holding forge tokens.

## Non-goals

- Azure DevOps repositories.
- A status for a pushed branch that never gets a PR (the dotfiles' own lines).
- Any change to the GitLab lookup beyond what the `draft` phase needs.

## Anti-goals

- A forge call whose host, repository or arguments a sandboxed command can steer.
- Wiping badges because a GitHub call failed.
- A per-run report source, or two phase tokens set at once.

## Design

### 1. The `draft` phase

- `derive()`: an open MR/PR with the draft flag prints `draft <icon> <ref>`, where the icon is the
  existing `ICON_DRAFT` (U+EBDB) and `<ref>` is `!<iid>` on GitLab and `#<number>` on GitHub. The
  `open <id>` second line follows as for `review`, so the CI badge shows on a draft too. The order
  of signals is unchanged: an open MR/PR, draft or not, outranks local work.
- `report()`: the phase group becomes `active`, `draft`, `review`, `merged`. One is set and the
  other three are cleared on every report, so a space moving between any two phases never shows
  two badges.
- `dot_config/herdr/config.toml`, the `[ui.sidebar.spaces]` row: a `$draft` token after
  `$active`, `fg = "#ff9e64"` (Tokyo Night orange), bold like `$active` and `$review`. The colour
  is the driver's call; any palette colour that is not green, yellow or the dim grey will do.
- The usage text, the header comments of `phase.sh` and the `dev.phase` plugin description name
  the four phases.

### 2. GitHub PRs

`repo_slug` returns a forge as well as a slug. GitHub remotes in the three usual forms
(`git@github.com:o/r.git`, `https://github.com/o/r(.git)`, `ssh://git@github.com/o/r.git`) yield
`github` and `o/r`. A GitHub slug is exactly `owner/repo`, each part `[A-Za-z0-9._-]+`, with no
`..`. Anything else is not a slug, as today.

- **The table:** one `gh pr list` per repository and state, open and merged, with
  `-R github.com/<owner>/<repo>` naming the host explicitly, `--limit 100`, and the JSON fields it
  needs (`headRefName`, `state`, `number`, `isDraft`, `isCrossRepository`). It produces the same
  table format as GitLab's (`branch`, `state` normalised to `opened`/`merged`, number, draft flag)
  and goes through the same cache, TTL and stale-cache fallback. Cross-repository PRs are dropped:
  a fork's branch name is not this checkout's branch.
- **The cache key** carries the forge, so a GitHub `o/r` and a GitLab `o/r` never share a file.
  Only GitHub keys get a prefix, with a character no GitLab slug can contain, so GitLab's cache
  file names (pinned by the suite) do not change.
- **CI:** an open PR's checks map to `ok`, `fail` or `run`, or to no badge, with the same staleness
  rules as `pipeline_class`. Whether the result comes from the list call's `statusCheckRollup` or
  from one call per open PR is the builder's call. The rollup maps as follows: any failure-type
  conclusion means `fail`; otherwise anything still queued or in progress means `run`; all
  successful (skipped and neutral count as success) means `ok`; no checks means no badge. If the
  CI result comes from the list's rollup, it keeps `pipeline_class`'s own age limit
  (`STALE_PIPELINE`, 1800 s) when the table falls back to its stale cache: the table's fallback
  has no age limit, and a stale "run" badge must not stay on indefinitely.
- **Hardening:**
  - `gh` runs from `/`, like `glab`, at an absolute or pinned-PATH location.
  - No call relies on the current directory's repository.
  - `gh api`, if used, passes `--hostname github.com`.
  - A failed or non-JSON answer is a failed lookup, never an empty table.
  - Whether `gh` can reach its token from the LaunchAgent's environment: see section 4.

### 3. Tests

`tests/herdr-phase.test.sh` stubs `gh` on `PATH` beside `glab`, deterministic and counting calls:

- draft on GitLab and on GitHub: phase `draft`, the exact icon bytes, the right ref prefix, and
  the other three phase tokens cleared;
- every move between `draft` and the other three phases, which clears the previous token;
- GitHub `review`, `merged` and CI mapping, including no checks, and a failed lookup keeping the
  cached table;
- slug parsing for the three remote forms, plus refusals (an extra path segment, `..`, a
  non-GitHub host);
- a cross-repository PR on the same branch name does not badge the space;
- per-repo caching for GitHub, proved by call counts as for GitLab;
- the forge-separated cache keys.

Existing pins and notes that move with the change:
- `tests/herdr-config.test.sh` pins the row-2 token order; it gains `$draft`.
- Section G of `tests/herdr-phase.test.sh` uses a `github.com` remote as its "no forge" case; it
  moves to a host that is neither forge.
- The `herdr-phase` note in `AGENTS.md` names the stubbed tools; it adds `gh`.

### 4. Live checks

- **Before the push (the line's own gate):** the branch's exact `gh pr list -R github.com/…` call
  runs unsandboxed from `/`, in a stripped environment (`env -i` with `HOME` and the pinned
  `PATH`), against a real GitHub repository, and returns JSON. It is the closest an agent gets to
  launchd's environment without loading a LaunchAgent; no `launchctl` action is taken.
- **After the merge (Michael):** `chezmoi apply`; the sidebar picks up the `$draft` token after
  Herdr reloads its config (restart the server if it does not). Then the LaunchAgent refresh
  badges a GitHub space with an open PR, and any draft PR or MR shows orange `draft` with its
  number.
- **If `gh` cannot authenticate under launchd:** the failed lookup leaves GitHub spaces as they
  are today, and the finding goes to Michael. A token outside the keychain (for example from
  1Password) would cross the secrets boundary, so it is a spec change, never designed inside
  this line.

### 5. Freshness

Added by Michael at sign-off: "make sure those statuses don't take too long to update properly.
Sometimes I'm under the impression that it takes a while for the proper status to show up in
herdr."

Today:
- The LaunchAgent (`be.netronix.herdr-phase-refresh`) runs every 180 s.
- The MR table and pipeline caches live for 120 s (`TTL`).
- The `workspace.focused` hook refreshes one space without forcing a fresh lookup.
- Opening an MR, marking it ready or merging it fires no Herdr event.

A cache that a focus refresh renewed just before a LaunchAgent run is reused by that run, so a
change can take about five minutes to show (the cache files on fenrir confirm the 180 s cadence,
2026-11-11).

- **Targets:**
  - an MR/PR change (opened, draft to ready or back, merged, pipeline result) shows within about
    60 s without any action;
  - focusing a space shows that space's current state within a few seconds.
- **Measure first.** Before changing anything, the line records:
  - the LaunchAgent's real cadence and per-run duration (cache mtimes, a timing line);
  - the worst-case staleness the TTL and interval produce together.
  It fixes the causes it finds. The plist's own comment records an earlier incident: a run longer
  than the interval made launchd skip cycles while reporting exit 0. Any shorter interval must
  leave the run time well inside it.
- **Levers in scope:**
  - the interval and the TTL;
  - a focus refresh that bypasses the TTL for the focused space's repository, rate-limited per
    repository so that quick switching cannot hammer the forges;
  - the run's cost (fewer calls per repository, for example CI from GitHub's list rollup).
  Forge rate limits stay far away: the line states the call budget per hour at the new cadence,
  against GitHub's 5,000/h and GitLab's per-user limit.
- **Out of scope:** a Claude Code hook that refreshes after `gh pr ready` or `glab mr merge`.
  `feat/wt-dotfiles` is changing the settings file it would live in; it can be proposed to
  Michael as a follow-up.
- **After the merge:** a changed `StartInterval` needs the LaunchAgent reloaded. That is
  Michael's step, and the line's report gives the exact commands.

## Left to the builder

- Where the CI result comes from (list rollup or per-PR call).
- How `derive` learns the ref prefix (a table column or the forge).
- The exact test layout inside `herdr-phase.test.sh`.
