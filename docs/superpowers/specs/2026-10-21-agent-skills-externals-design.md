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
3. After merge, Michael's `chezmoi apply` downloads the new archive.

AGENTS.md gets one Rules bullet for this. Third-party skills are pinned archive externals in
`.chezmoiexternal.toml`, each with a `symlink_` in `dot_claude/skills/` and a
`.chezmoiignore` re-include. A bump means reading the upstream diff first. The Layout block
also lists `.chezmoiexternal.toml`.

### Sandbox and previews

chezmoi is a Go binary. In the agent sandbox its TLS verification fails with
`OSStatus -26276`, because trustd is blocked and Go on macOS ignores `SSL_CERT_FILE`.
`chezmoi apply --dry-run` therefore cannot download the external sandboxed. Agents preview
everything else with `--exclude=externals`, and check the external offline (see Testing).
Michael's apply runs unsandboxed. On a fresh machine Little Snitch may first ask about
chezmoi reaching `github.com` and `codeload.github.com`.

## Testing

A new offline suite, `tests/agent-skills.test.sh`, runs sandboxed with no network. For each
`.agents/skills/<name>` entry in `.chezmoiexternal.toml`, it asserts:

- `type = "archive"`, and the URL has the form
  `https://github.com/<owner>/<repo>/archive/<40-hex>.tar.gz`, so a branch or tag name is
  rejected
- `exact = true` and `stripComponents = 1`, with no `refreshPeriod` (or 0)
- `include` is present, so a whole repository never lands
- `dot_claude/skills/symlink_<name>` exists and holds exactly `../../.agents/skills/<name>`
- chezmoi itself treats `.claude/skills/<name>` as managed and not ignored, checked with
  `--exclude=externals` so nothing is downloaded

Each assertion needs a negative case: a fixture with a branch URL, a missing symlink, a
missing re-include and a missing `include`, each of which must fail. Following the repository
rule, the suite also exits 2 when `.chezmoiexternal.toml` is missing.

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
