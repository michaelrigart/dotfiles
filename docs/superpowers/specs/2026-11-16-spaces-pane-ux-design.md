# Herdr app: a clearer spaces pane

**Status:** Implemented (branch `feat/spaces-pane-ux`, its PR against `main`)
**Date:** 2026-11-16
**Branch:** `feat/spaces-pane-ux`
**Sign-off:** Michael, 2026-11-16. Each change below was approved by him point by point while he
tested it live, 2026-11-15 and 2026-11-16. Codex spec review: round 1's one finding fixed (the `gitTail`
guard embedded Herdr's method; now a digest), round 2's one finding fixed (the method was still in
the branch's history; folded out before any push), round 3 approved.

Michael wanted the Herdr app's spaces pane (the `michael-spaces` clone of Herdr's `spaces` mod)
clearer at a glance. It should keep every piece of information it showed (phase, PR/MR number, CI,
ahead/behind, branch) and waste less of the 268 px sidebar. His points: spaces and their worktree
subspaces should fold per repository; worktree rows were crowded (a branch glyph, a long name, the
branch again, "draft/review #N", a CI mark, or a green dot he couldn't read); and a space name such
as `chezmoi-fix-merge-full-sha` nearly repeats its branch `fix/merge-full-sha`.

## How it was designed

The design was explored live instead of in a brainstorm. Michael tested the running app, and each
point went to an agent, landed in the pane within minutes, and was committed once he had seen it
(§Live path). This spec records what he approved. The change is not small (about 270 lines of
non-test code across `patches/rows.js`, `patches/phases.js`, `bin/patch-mod` and `bin/respaces`).
It has no plan: every task was already implemented and committed when the spec was written, so a
plan would only be a backdated record of the commits listed in §Commits.

## What the pane showed before

- A worktree row nested under its repository: a branch glyph, the space name, then the branch in
  the row's tail. The mod's `gitTail` hid the branch only when it equalled the space name exactly;
  `bin/open-space` names a space after its checkout folder, so a `wt` space is
  `<repo>-<branch slug>` and its branch nearly always showed twice.
- A phase badge (`patches/phases.js`): green ● for "active" (local work, no MR), draft #N,
  review #N, merged #N, and after it a CI mark: ✓, ✕, or a yellow ● while a pipeline ran. So ●
  meant two things, besides Herdr's own ● for a machine's status.
- Folding only per machine. A main checkout on a branch showed the whole branch in its tail, and
  only `main` and `master` were hidden.

## Goals

- Every piece of information shown before stays visible, or reachable on a folded repository.
- Nothing is said twice on a row, and each glyph and each colour has one meaning.
- A folded repository still says when something in it needs Michael.
- Every addition to Herdr's file stays small and fails loudly when a Herdr update moves it.

## Non-goals

- The Agents list and the picker (Herdr's `agents` and `picker` mods) keep the full space name.
  Changing them means patching another Herdr mod.
- Naming new worktree spaces after the branch in `bin/open-space` (option 2, declined): the agents
  list and the picker would lose the repository, and existing spaces would need renaming.
- A "changes requested" marker: the GitLab query has no equivalent of GitHub's `reviewDecision`.

## Decisions

1. **Naming in the pane only** (Michael, 2026-11-15). A worktree row nested under its repository
   shows its branch; the full space name stays everywhere else. A space renamed by hand keeps its
   name and still shows the branch.
2. **Keep patching Herdr's mod; do not own it** (Michael, 2026-11-16). A Herdr update that moves a
   patched line stops `respaces` at that edit, naming it, and the pane falls back to Herdr's stock
   spaces pane, which keeps working. Owning the mod would freeze a copy of a mod Herdr updates
   almost daily, lose its fixes, still break when Herdr's mod interface changes, leave no stock
   pane to fall back to, and commit Herdr's shipped code to this public repository, which
   `2026-11-14-herdr-app-in-chezmoi-design.md` names as an anti-goal. The logic lives in our own
   modules; the edits to Herdr's `main.js` are short call sites. **Revisit** when `respaces` starts
   stopping often, or when a wanted change cannot be expressed as a small edit.
3. **One meaning per colour** (Michael, 2026-11-16), defined once in `tones()` and `marks()` in
   `phases.js`:

   | Colour | Meaning | Shown as |
   |---|---|---|
   | red | needs Michael | CI failed ✕ (`ansi1`); an agent waiting `!`, "not wt" and "gone" (`t.blocked`) |
   | blue | waiting on others | review #N (`ansi4`) |
   | yellow | in progress | CI running ◐ (`ansi3`) |
   | green | done | CI passed ✓ (`ansi2`) |
   | quiet | nothing to act on | draft (`t.muted`), merged (`t.dim`), the hidden-current-space ◆ (`t.foreground`) |

## Design

### Rows

| Row | Now |
|---|---|
| Worktree nested under its repository, automatic name | The branch is the label, its type prefix (`fix/`, `feat/`, …) in `t.dim`; the branch is not repeated in the tail. No branch glyph; the label starts at a 36 px indent. |
| Worktree nested, renamed by hand | Its name, and the branch in the tail as before. |
| Merged worktree | Label in `t.muted` (prefix stays `t.dim`); drawn after the repository's other worktrees. |
| Repository (main checkout) | The branch in the tail with its type prefix dimmed and the rest `t.muted`; hidden when it is the repository's own default branch (`main`/`master` while that is unknown). |
| Any space with an agent waiting for Michael | A bold red `!` first in the row's end. |
| Any space with no MR | No badge (the green ● is gone). |
| Badge while CI runs | A yellow ◐ after it (◌ was too faint at 11.5 px). |

A name is automatic when it equals `<repo>-<branch with / as ->` or the branch itself, compared
case-insensitively, and only a row nested under its repository qualifies. Detached HEAD rows and the
main checkout's own row are unchanged.

### Folding per repository

- The row a repository's worktrees follow carries a chevron; a click folds or unfolds them without
  selecting the space. The state is a set of repository keys in localStorage under `repos.folded`,
  apart from the machine folds in `machines.folded`.
- A folded repository shows, before its hidden count, the most urgent hidden state: a red `!` (an
  agent waiting) and a red ✕ (CI failed), both when both apply; otherwise a blue "review"; otherwise
  a ◆ when the space Michael is in is hidden. With none, only the count. The tooltip names each
  reason.
- Folding and merged-last ordering change only what is drawn (`grouped()`), never the order Herdr
  stores and `space.move` uses (`ordered()`).
- The narrow rail has no toggle, so it ignores folds and keeps the stored order.

### Where the data comes from

- Phase and CI: `phases.js`'s existing forge lookups (every 60 s, every 15 s while a pipeline runs).
- The default branch: `git symbolic-ref --short -q refs/remotes/origin/HEAD` (no network), one read
  per git common dir, cached for 10 minutes and run inside the existing phases tick (`defaultOf()`
  in `phases.js`).
- An agent waiting: each `spaces()` entry's `status`, kept by the app ("blocked" is what the Agents
  list calls "Needs you"). No new process, poll or subscription.

### Modules and how they are applied

- `patches/phases.js` keeps the phase and forge data, `badge()`, the colour scheme and
  `defaultOf()`. `patches/rows.js` (new) holds the row drawing: `asBranch`, `label`, `tail`,
  `fold`, `mergedLast`, `waiting`, `urgent`, `toggle`, `end`. It imports `tones` and `marks` from
  `phases.js`; `phases.js` does not import it.
- `bin/respaces` copies both into the clone. `.chezmoiignore` already re-includes
  `.config/herdr-app/patches` as a directory, so `rows.js` deploys with no new entry.
- `bin/patch-mod` makes six edits to the spaces mod's `main.js`:
  1. import `Phases` and `Rows`;
  2. construct them with the view;
  3. the row's label, tail and end call `rows.label`, `rows.tail` and `rows.end`;
  4. the right-click opens `michael-menu` (unchanged);
  5. `grouped()` draws `rows.fold(this.ordered(), collapsed)`;
  6. the nested row's branch glyph becomes a plain indent.
- It also checks the shipped `gitTail` method by digest. `rows.tail` draws non-nested rows with its
  own version of `gitTail`, so a Herdr change there would otherwise drift unnoticed. `patch-mod`
  takes the method from its signature line (`  gitTail(g, tree, name, t) {`, which must occur
  exactly once) to the first closing brace at its indent, and compares its SHA-256 with
  `GITTAIL_SHA256`. A missing or repeated signature, or a different digest, stops `respaces` like a
  failed edit, leaves the clone unpatched, and names `rows.tail`; on a mismatch the message prints
  the new digest to set once `rows.tail` is up to date. Only the digest is committed, never the
  method, since this repository does not carry Herdr's shipped code. Nested worktree rows still go
  through Herdr's own `gitTail`.

## Tests

- `tests/herdr-app.test.sh` gains a headless section: it copies `phases.js` and `rows.js` to a
  scratch folder, points their imports at `tests/fixtures/herdr-app/rows-stubs.js` (which stands in
  for `herdr`, `gpui-kit` and `gpui-base` and records what the builders draw), and runs
  `tests/fixtures/herdr-app/rows.test.js` in JavaScriptCore's `jsc`, which ships with macOS and the
  resume suite already uses. It covers `asBranch`, `label`, `fold`, `mergedLast`, `urgent`,
  `toggle` and its persistence, `waiting` and `end`, `badge` and the colour scheme, and `tail` with
  the default branch. It skips, counted, without `jsc`.
- Three cases work on a copy of the shipped `main.js`: one character of `gitTail` changed, the
  signature line removed, and the method present twice (the copy is taken from the shipped file at
  run time, so no shipped code is committed). Each asserts that `patch-mod` fails with the check's
  message naming `rows.tail` and leaves the copy unpatched.
- Revert checks: 29 one-line breaks of the logic, each failing at least one assertion, and the
  digest comparison disabled, failing the changed-character case.
- Not covered by a suite: `defaultOf()`'s git call, the forge lookups, and the real rendering. The
  live run covered the rendering.

## Live path (during the line only)

The sandbox cannot write `~/.config/herdr-app/mods`. An untracked helper,
`.superpowers/live/build`, rebuilt `.superpowers/live/michael-spaces` from the shipped `spaces` mod,
the checkout's patches and `bin/patch-mod`, exactly as `respaces` does (its first build was
byte-identical to the deployed clone). Michael linked `mods/michael-spaces` to that folder once.
The app reloads a mod only when the entry in `mods/` changes, not on a save inside a linked folder,
so each landed change was followed by `ln -sfn` of the same link, run outside the sandbox. After
the merge, `respaces` sets the link aside like any earlier clone and makes a real one.

## Acceptance

Seen live by Michael (2026-11-16): branch labels, folding, no badge without an MR, merged rows muted
and last, the red `!` on a waiting agent's space. CI running ◐ was not running at the time.

After the merge, Michael runs `chezmoi apply`, then `respaces`, and checks that the pane looks as
it did in the live run. After the next Herdr update, `respaces-guard` runs `respaces`; if it stops
at the `gitTail` check, `rows.tail` is brought up to date with Herdr's new `gitTail` and
`GITTAIL_SHA256` is set to the digest the message prints.

## Known limits

- For about one phases tick after the app starts, a repository's default branch can show before
  its first read hides it.
- A merged worktree drawn below a later active one can make the drag drop line look one row off;
  the mod's drag code works from stored positions and is not patched.
- A worktree moves to the bottom, and mutes, up to a minute after its MR merges (the forge lookup).

## Rulings during the live run

- ◐ for CI running over ◌, which was faint at 11.5 px.
- Draft changed from bright yellow (`ansi11`) to `t.muted`, since yellow now means in progress.
- The ◆ for a hidden current space is `t.foreground`, not `t.accent`, which reads as blue.
- `defaultOf()` stays in `phases.js` with the data it reads; `rows.js` only reads its cache.
- The nested-row indent is 36 px, about 9 px past the repository's name.
- Edit 6 is a new, small anchor rather than a widening of edit 3, which would have pulled the
  unrelated avatar line into an anchor.
- The `gitTail` check compares a digest rather than the method's text: the text would put
  Herdr's shipped code in this public repository (Codex, spec review round 1). Its failures exit
  the same way as a failed edit.

## Commits

`8e4458e` labels and folding · `1a01e92` badges · `e2c97e8` folded markers · `7d21947` no branch
glyph · `332b20d` merged muted · `d993e4e` main-checkout tail · `663ff2f` colours · `7ad6c76` merged
last · `7d20335` `rows.js` · `cd8629f` agent waiting · `e6daa4e` tests · `552bf4f` the `gitTail`
digest check.
