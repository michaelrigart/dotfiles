# Third-party agent skills as pinned chezmoi externals

**Status:** Implemented on `feat/agent-skills` (no MR; dotfiles end at the pushed branch)
**Date:** 2026-10-21
**Branch:** `feat/agent-skills`

## Problem

Michael wants [Clarity](https://clarity.addy.ie/) (`addyosmani/clarity`, MIT, v0.2.1), a
writing skill invoked as `/clarity rewrite|review|interview …` in Claude Code and `$clarity`
in Codex. It is a plain Agent Skill: `SKILL.md` at the repository root, `references/`, and
lint scripts. It ships no `.claude-plugin/` manifest and is not in Addy's `agent-skills`
marketplace, so `dot_config/agents/plugins.conf` cannot declare it. Upstream's only install
route is the third-party `skills` npm CLI (`npx skills add`).

An undeclared install works until the machine is rebuilt. Everything else the agents load
is declared: plugins and marketplaces in `plugins.conf` (installed by
`.scripts/reconcile-agents.sh`), and first-party skills as chezmoi files in
`dot_claude/skills/`. A third-party skill should be declared too, and because a skill is
instructions an agent follows, what gets installed should be content Michael has reviewed.

## Goals

- Clarity is declared in this repository and installs for Claude Code and Codex on
  `chezmoi apply`, here and on a rebuilt machine.
- Every machine gets the same reviewed commit. The skill changes only when a commit to this
  repository changes the pin.
- Adding the next third-party skill repeats the same small pattern.
- When a pinned skill has a newer upstream release, Michael is notified and Claude can see it
  with `gh`, without the pin changing.

## Non-goals

- Auto-bumping. Nothing edits the pin, pushes a branch or opens a PR on its own.
- Repositories holding several skills, or a skill below the root. The pattern supports both
  through `include` and `stripComponents`, but nothing here needs them.
- Clarity's optional `commands/clarity-*.md` shortcuts. `/clarity <mode>` covers them.
- Moving `basecamp`, which is already in `~/.agents/skills` and installed outside chezmoi.
- Changing `reconcile-agents.sh` or `plugins.conf`.

## Anti-goals

- Running third-party installer code. No `npx skills`, no npm, no new dependency.
- A skill changing because upstream pushed.
- Committing third-party skill files into this public repository.
- Touching a first-party skill (`cross-review`, `live-feedback`) or an unmanaged sibling in
  `~/.agents/skills`.

## Design

### Layout

| Target | Source | What |
|---|---|---|
| `~/.agents/skills/clarity/` | `.chezmoiexternal.toml` | an archive external pinned to a commit |
| `~/.claude/skills/clarity` | `dot_claude/skills/symlink_clarity` | a relative symlink, `../../.agents/skills/clarity` |

Codex 0.163 loads `~/.agents/skills` as a skill root (measured 2026-10-21 with
`codex debug prompt-input`: root `r0` is `/Users/michael/.agents/skills`, where it found
`basecamp`). Claude Code loads only `~/.claude/skills` and follows a symlink there: the
existing `~/.claude/skills/basecamp -> ../../.agents/skills/basecamp` loads as the `basecamp`
skill. One copy therefore serves both agents. It is also the layout `npx skills` produces.

### The external

`.chezmoiexternal.toml` at the source root:

```toml
[".agents/skills/clarity"]
    type = "archive"
    # v0.2.1
    url = "https://github.com/addyosmani/clarity/archive/e27ceeff60368cf6966b4ea00a5b9b36418ee9a0.tar.gz"
    exact = true
    stripComponents = 1
    include = ["*/SKILL.md", "*/LICENSE", "*/references", "*/references/**", "*/scripts", "*/scripts/**"]
```

- **Pin:** the URL names a full 40-character commit SHA: the commit of an upstream release
  tag when upstream publishes releases (Clarity's `v0.2.1` is exactly `e27ceef`), with the
  tag in a comment for people. With `refreshPeriod` left at its
  default (0), chezmoi downloads once and re-downloads only when the URL changes. No
  checksum: the commit SHA already fixes the content, and GitHub does not guarantee that a
  generated tarball stays byte-identical. (My call.)
- **Contents:** only what the skill uses (`SKILL.md`, `references/`, `scripts/`) plus
  `LICENSE`. The site, samples, evals and CI files stay out. Include patterns match archive
  paths *before* `stripComponents`, hence the `*/` prefix for the `clarity-<sha>/` top
  directory.
- **`exact = true`:** a SHA bump that drops an upstream file removes it here too. It applies
  only to the `clarity` subtree. `~/.agents/skills` itself is not exact, so `basecamp` and any
  other sibling survive.

Measured on 2026-10-21 against a scratch source and destination with chezmoi 2.73.3:

- the include list yields exactly `SKILL.md`, `LICENSE`, `references/*.md` and the three
  `scripts/*.py`
- the symlink resolves to the extracted copy
- a stray file in the copy is removed on the next apply
- a hand edit to a managed file stops apply with chezmoi's "has changed since chezmoi last
  wrote it?"
- changing the SHA in the URL triggers a fresh download
- an unmanaged `basecamp` beside the copy, and a real `cross-review` beside the link,
  are both left alone

### The symlink

`dot_claude/skills/symlink_clarity` holds `../../.agents/skills/clarity`. `.chezmoiignore`
ignores `.claude/skills/*` and re-includes skills one by one, so it needs
`!.claude/skills/clarity` beside the existing `cross-review` and `live-feedback` entries.
Otherwise chezmoi silently drops the link.

### Update notices

**The check: `.scripts/skill-updates.sh`** (mode 755, Bash 3.2). It reads
`.chezmoiexternal.toml`, and for each `.agents/skills/<name>` archive entry takes
`owner/repo` and the pinned SHA from the URL. It then asks GitHub through `gh api` for the
latest release:

- `releases/latest` gives the tag, and `git/ref/tags/<tag>` gives the commit, dereferencing
  an annotated tag (Clarity's are annotated)
- with no releases, it uses the default branch's HEAD

*Erratum (implementation):* the script resolves the tag with `commits/<tag>`, which peels an
annotated tag in one call (measured 2026-10-21: `v0.2.1` → `e27ceef…`), instead of
`git/ref/tags/<tag>` plus a dereference.

It prints one line per skill, either up to date or
`update: <name> <pinned tag or short SHA> → <new tag or short SHA> <compare URL>`. It exits:

| Exit | Meaning |
|---|---|
| 0 | every skill is current |
| 1 | at least one update exists |
| 2 | something could not be checked (no `gh`, an API error, an unparseable entry) |

A failed lookup is never reported as up to date. `gh api` works sandboxed (measured
2026-10-21), so Claude can run the script locally on request ("check skill updates").

With `--open-issues`, the script also turns each update into an issue. All of the issue
logic lives here, where the suite can test it:

1. **Ensure the label.** `gh label create skill-update --force …` creates the label or
   updates it in place. The repository has no such label today (checked 2026-10-21), and
   `gh issue create --label` fails on a missing one.
2. **Dedupe exactly.** It lists open issues labelled `skill-update` with
   `gh issue list --json title`, with a `--limit` high enough to see them all, and compares
   titles exactly. It does not use the search
   API, which lags.
3. **Open what's missing.** For each update with no open issue, `gh issue create` makes one
   titled `Skill update: <name> <new tag>`. The body holds the compare URL and the checklist
   from "Updating a skill" below.
   *Erratum (after merge):* the list uses `--state all`, so a closed issue also counts;
   see Errata.

In this mode it exits 0 once every update has an open issue, and 2 if any lookup, label or
issue call fails. A pending update is not a failure here, because the issue is the
notification, so it does not fail the run every week.

**The schedule: `.github/workflows/skill-updates.yml`.** This is the repository's first
workflow.

- **Triggers:** a weekly `schedule`, plus `workflow_dispatch`.
- **Permissions:** `contents: read` and `issues: write`, nothing more.
- **Steps:** `actions/checkout` pinned by commit SHA (`3d3c42e5…`, v7.0.1, with the tag in a
  comment), then `.scripts/skill-updates.sh --open-issues` with
  `GH_TOKEN: ${{ github.token }}`. The YAML holds no other logic.
- **On exit 2:** the run fails, and GitHub emails the owner when a scheduled run fails.

**Why an issue rather than a PR (my call).** The bump is one line. The work is reading the
diff, warming the cache and the cross-review, and that belongs in a session. An issue also
needs only `issues: write`: no `contents: write`, and no "allow Actions to create pull
requests" setting.

**Who sees it.** Michael watches his own repository by default, so a new issue reaches his
GitHub notifications. Claude sees it with `gh issue list --label skill-update`.

**Two GitHub facts to live with:**

- GitHub disables a public repository's scheduled workflows after 60 days with no repository
  activity. This repository is active, and a disabled workflow shows in the Actions tab.
- A `.github/` directory in the source would be deployed to `~/.github`, so `.chezmoiignore`
  gets a `.github/` entry beside `.scripts/`.

  *Erratum (final review):* chezmoi 2.73.3 never deploys a dot-prefixed source entry, so
  `.github/` would not have reached `$HOME` anyway. The entry is kept for consistency with
  `.scripts/`, and it does no harm.

### Updating a skill

1. A `skill-update` issue, or a local run of `.scripts/skill-updates.sh`, names the new
   release and its compare URL.
2. Read the upstream diff between the pinned SHA and the new one. Pay particular attention
   to `SKILL.md`, `references/` and every script.
3. Change the SHA and its tag comment in `.chezmoiexternal.toml` in a commit on a branch,
   like any other change.
4. Warm chezmoi's cache for the new URL outside the sandbox (see Sandbox and previews).
5. The bump commit's message carries `Closes #<issue>`, so the issue closes when the commit
   reaches `main`. After merge, Michael's `chezmoi apply` installs the new archive.

AGENTS.md gets one Rules bullet for this. Third-party skills are pinned archive externals in
`.chezmoiexternal.toml`, each with a `symlink_` in `dot_claude/skills/` and a
`.chezmoiignore` re-include. `.scripts/skill-updates.sh`, run weekly by the
`skill-updates` workflow, reports new releases as `skill-update` issues. A bump means reading
the upstream diff first, then warming chezmoi's cache outside the sandbox (see below). The
Layout block also lists `.chezmoiexternal.toml` and `.github/workflows/`.

### Sandbox and previews

chezmoi is a Go binary. In the agent sandbox its TLS verification fails with
`OSStatus -26276`, because trustd is blocked and Go on macOS ignores `SSL_CERT_FILE`. So
chezmoi cannot download the archive sandboxed.

**Every command that reads source state needs the archive.** Measured 2026-10-21 with an
empty cache, `managed`, `ignored`, `cat`, `diff`, `status` and `apply --dry-run` all try the
download first and fail sandboxed, with or without `--exclude=externals` and
`--refresh-externals=never`. `execute-template` does not. With the archive cached, all of
them work sandboxed and offline.

**The cache is keyed by URL alone.** A file under `~/.cache/chezmoi/external/` is named by
the URL's sha256, whatever the source directory. Michael's apply (the wrapper's fresh clone)
and a sandboxed session reading the working tree therefore share one cache entry. In steady
state the cache is warm:

- on a fresh machine, provisioning's apply fills it
- after a SHA bump, it is cold until something downloads the new URL outside the sandbox

**After adding or bumping an external, warm the cache once.** Run
`command chezmoi --source <checkout> managed >/dev/null` outside the sandbox. It
downloads the archive into the cache and writes nothing else. The implementing branch does
this once after adding the external. The AGENTS.md bullet records it for every later bump.

Michael's apply runs unsandboxed. On a fresh machine Little Snitch may first ask about
chezmoi reaching `github.com` and `codeload.github.com`.

## Testing

A new offline suite, `tests/agent-skills.test.sh`, runs sandboxed with no network. For each
`.agents/skills/<name>` entry in `.chezmoiexternal.toml`, it checks what the entry does
rather than which fields it has.

**Static checks**, for what an apply cannot show:

- `type = "archive"`, and the URL has the form
  `https://github.com/<owner>/<repo>/archive/<40-hex>.tar.gz`, so a branch or tag name is
  rejected
- no `refreshPeriod`, or 0

**Behaviour, through chezmoi.** chezmoi accepts a `file://` archive URL, sandboxed and offline
(measured 2026-10-21). The suite copies the production entry, swaps only its `url` for a
local fixture tarball, and applies it to a scratch destination with its own config, cache and
state.

- **The fixture** mirrors the pinned commit's top-level layout: a `<repo>-<sha>/` top
  directory holding `SKILL.md`, `LICENSE`, `README.md`, `DESIGN.md`, `PRODUCT.md`,
  `netlify.toml`, `skills.sh.json`, `.gitignore`, `.claude/`, `.github/`, `commands/`,
  `evals/`, `references/`, `samples/`, `scripts/` and `site/`, each with at least one file.
- **Exact file set:** the extracted copy is exactly `SKILL.md`, `LICENSE`, `references/…` and
  `scripts/…`. A missing `SKILL.md` fails, and so does any stray site, sample, eval or command
  file.
- **Stale-file removal:** a file planted in the copy before a second apply is gone after it.
- **Siblings survive:** a sentinel in `~/.agents/skills/basecamp/` and a real
  `~/.claude/skills/cross-review/` are untouched.
- **The link:** `~/.claude/skills/<name>` is a symlink holding exactly
  `../../.agents/skills/<name>`, and it resolves to the extracted copy. The scratch source is
  built from the real `.chezmoiignore` (which uses no template syntax) and the real
  `dot_claude/skills/symlink_<name>`, so the apply proves both the link and its re-include.
  The suite never reads the real source state with the real URL, so it does not depend on
  the cache.

Every check needs a negative case that must fail: a branch URL, a `refreshPeriod`, an
incomplete include (`["*/LICENSE"]`), an overbroad include (`["**"]`), `exact` removed, a
missing symlink and a missing re-include. Following the repository rule, the suite exits 2
when `.chezmoiexternal.toml` is missing.

**The update check.** `tests/skill-updates.test.sh` stubs `gh` on `PATH` with fixture
responses and covers these cases:

- a current pin: exit 0
- a newer release: exit 1, with the compare URL
- an annotated tag dereferenced to its commit
- no releases: falls back to the default branch's HEAD
- `gh` absent, a failing `gh` call, or garbage JSON: exit 2, never "up to date"
- an unparseable entry: exit 2
- two skills, one current and one not: exit 1, naming only the stale one

With `--open-issues`, the stub records every `gh` call:

- an update with no label in the repository: `gh label create skill-update … --force` runs
  before `gh issue create`, and the exit is 0
- an open issue with the same title: no `gh issue create`
- an open issue whose title differs only in the tag: a new issue is created
- a failing label or issue call: exit 2
- every pin current: no label or issue calls, exit 0

The workflow's YAML gets static checks in the same suite:

- the permissions block is exactly `contents: read` and `issues: write`
- every `uses:` is pinned to a 40-hex SHA
- its run step invokes `.scripts/skill-updates.sh --open-issues`

**Existing suites and a cold cache.** `codex-config`, `claude-settings` and
`live-feedback-skill` run `chezmoi managed` on the real source with stderr discarded. With a
cold cache, `managed` fails, its output is empty, and each suite reports every target as
missing from the allowlist: a false regression. Each of the three must instead treat a
failing `chezmoi managed` as inconclusive. It prints chezmoi's first error line and the
warm-cache command, and exits 2 rather than failing per target. Each change needs a test
case that stubs a failing `chezmoi` on `PATH`.

## Rollout

After merge, Michael runs `chezmoi apply`. Then:

- `readlink ~/.claude/skills/clarity` prints `../../.agents/skills/clarity`
- a new Claude Code session lists `clarity`
- `codex debug prompt-input` lists `clarity` under the `~/.agents/skills` root (it needs the
  sandbox escape)
- a manual `workflow_dispatch` run of `skill-updates` succeeds and opens no issue, because
  `v0.2.1` is current

## Security notes

- Clarity at `e27ceef`, upstream's HEAD as of 2026-10-21, is read. `SKILL.md` adds no
  hooks, MCP servers or permissions. `scripts/prose_stats.py` and
  `scripts/strip_markdown.py`, which lint mode runs, and `scripts/validate_package.py`
  (packaging only, never invoked by the skill) use only the standard library, read the paths
  they are given, and write only to stdout.
- The pin is the review point. Nothing reaches an agent without a commit here that changes
  the SHA.
- The repository is public. It names only a public upstream and a commit SHA.
- The workflow's token can read contents and write issues, nothing else. Its one action is
  pinned by commit SHA. It never touches the pin.

## Left to the builder

These are the builder's to decide:

- how the suites read the TOML (a narrow parser for this file's simple shape is fine, as
  long as it ignores comments)
- how they build their negative fixtures
- how the script shows the pinned version (the tag comment, or a tag lookup)
- the weekly cron time
- the issue body's wording
- the exact AGENTS.md wording

## Errata

Changes made during implementation and review, after sign-off. The two inline errata above
cover `commits/<tag>` and the `.github/` ignore entry.

- **Stricter parsing in `skill-updates.sh`.**
  - An entry header must be `[".agents/skills/<name>"]` at column 0, with a name made of
    `[A-Za-z0-9_.-]`.
  - Any other `[`-line naming `.agents/skills/` is an unparseable entry: a diagnostic, then
    exit 2.
  - The tag comment counts only directly above `url`, and only when it holds no `|`.
  - A tag that contains `|` is rejected.
- **`--open-issues` acts on its own checkout.** It resolves `--externals` to an absolute path,
  then `cd`s to the script's repository before any `gh` call, so a run from another
  repository never files issues there. `GH_REPO` still overrides.
- **Cold-cache hint.** The three suites take chezmoi's first non-blank stderr line, falling
  back to `(no stderr)`. `tests/run.sh` prints a suite's `INCONCLUSIVE:` lines, with their
  indented continuations, under its `????` row; the verdict does not change.
- **Bump confirmation.** After warming the cache, the bumper also confirms that
  `.scripts/skill-updates.sh` prints `current: <name> <tag>`. This rules out a SHA that only
  a fork serves. It appears in the issue checklist and in AGENTS.md.
- **Serialized runs.** The workflow has a top-level `concurrency` group (`skill-updates`,
  `cancel-in-progress: false`). Without it, a manual dispatch that overlaps the scheduled run
  could list issues before either run creates one, and both would file the same issue (from
  the pre-merge review).
- **Dedupe across all issues.** Michael's decision after merge (2026-10-22): the issue list
  uses `--state all`, so closing an issue without a bump declines that release and it is
  never filed again; a newer release gets its own issue. The issue body says so. The
  `--limit 200` stays: the list is newest first, so only issues for long-superseded
  releases could fall off it.
