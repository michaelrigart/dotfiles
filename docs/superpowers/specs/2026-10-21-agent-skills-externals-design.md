# Third-party agent skills as pinned chezmoi externals

**Status:** Draft, awaiting sign-off
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

## Non-goals

- An upstream-moved notice. Checking for updates stays manual.
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
    url = "https://github.com/addyosmani/clarity/archive/e27ceeff60368cf6966b4ea00a5b9b36418ee9a0.tar.gz"
    exact = true
    stripComponents = 1
    include = ["*/SKILL.md", "*/LICENSE", "*/references", "*/references/**", "*/scripts", "*/scripts/**"]
```

- **Pin:** the URL names a full 40-character commit SHA. With `refreshPeriod` left at its
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

### Updating a skill

1. Read the upstream diff between the pinned SHA and the new one (GitHub compare). Pay
   particular attention to `SKILL.md`, `references/` and every script.
2. Change the SHA in `.chezmoiexternal.toml` in a commit on a branch, like any other change.
3. Warm chezmoi's cache for the new URL outside the sandbox (see Sandbox and previews).
4. After merge, Michael's `chezmoi apply` installs the new archive.

AGENTS.md gets one Rules bullet for this. Third-party skills are pinned archive externals in
`.chezmoiexternal.toml`, each with a `symlink_` in `dot_claude/skills/` and a
`.chezmoiignore` re-include. A bump means reading the upstream diff first, then warming
chezmoi's cache outside the sandbox (see below). The Layout block also lists
`.chezmoiexternal.toml`.

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

## Security notes

- Clarity at `e27ceef`, upstream's HEAD as of 2026-10-21, is read. `SKILL.md` adds no
  hooks, MCP servers or permissions. `scripts/prose_stats.py` and
  `scripts/strip_markdown.py`, which lint mode runs, and `scripts/validate_package.py`
  (packaging only, never invoked by the skill) use only the standard library, read the paths
  they are given, and write only to stdout.
- The pin is the review point. Nothing reaches an agent without a commit here that changes
  the SHA.
- The repository is public. It names only a public upstream and a commit SHA.

## Left to the builder

How the suite reads the TOML (a narrow parser for this file's simple shape is fine), how it
builds its negative fixtures, and the exact AGENTS.md wording.
