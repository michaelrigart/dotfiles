# Dotfiles (chezmoi)

macOS dotfiles managed with chezmoi: XDG layout, secrets rendered from 1Password at
apply time, one-line provisioning. **This repo is public.** Human docs: `README.md`.
Canonical agent context for every agent: Claude Code and Codex both load it natively.

## Rules

- **Never commit a secret.** Every secret is a template —
  `{{ onepasswordRead "op://Private/Item/field" }}` (SSH keys: `…?ssh-format=openssh`).
  SSH keys live in `private_dot_ssh/`, tokens in `dot_config/bundler/private_config.tmpl`,
  `dot_config/private_ha-mcp/private_env.tmpl` and `dot_config/private_ha-mcp/private_env-remote.tmpl`.
  Before committing under those paths: `git diff --cached`, and
  `grep -L onepassword private_dot_ssh/private_*.tmpl` must print nothing.
  The agent forge tokens are the exception to "a template": `dot_claude/modify_private_settings.json`
  reads them from 1Password at apply and they live only in the deployed `~/.claude/settings.json`.
  Preview that target through `jq 'del(.env.GH_TOKEN, .env.GITLAB_TOKEN)'`, never whole; a
  dry-run diff of it can print the token lines as context, so filter that output too.
- `.chezmoiignore` is an **allowlist** for `~/.claude`, `~/.codex`, and Alfred: ignore
  the directory contents, then re-include one file at a time, one level at a time — a
  re-include cannot reach inside an ignored directory. A new managed file under those
  trees needs its own `!` entry, or `chezmoi add` silently drops it.
- `README.md`, `AGENTS.md`, `CLAUDE.md`, `docs/`, `tests/`, `.scripts/` are ignored so
  they never land in `$HOME`.
- Edit the source in a `wt` checkout (never in the main one); it deploys once merged, when
  Michael runs `chezmoi apply`. Never hand-edit a deployed file. Agents preview with
  `command chezmoi cat <target>` and `command chezmoi apply --dry-run --verbose`:
  sandboxed, so running the working tree's scripts is safe. In a `wt` sibling a bare
  `command chezmoi` renders the main checkout, so preview with
  `command chezmoi --source <checkout> cat <target>` and
  `command chezmoi --source <checkout> apply --dry-run --verbose`. The zsh wrapper reaches
  agent shells too (Claude Code's shell snapshot omits every function whose name starts
  with a single `_`, so each public function in `~/.config/zsh/functions` that uses a
  helper reloads the file when it is missing): off main it refuses previews, and on main
  its clone into `~/.cache` hits a sandbox denial. Data variables (`.name`, `.email`,
  `.is_arm`) come from `.chezmoi.toml.tmpl`, which `chezmoi apply --init` re-renders — not
  plain `apply`; `.known_hostnames` comes from `.chezmoidata/machines.toml`.
- The `chezmoi` wrapper (`dot_config/zsh/functions`): Michael's `apply`, `update` and
  previews (`diff`, `status`, `cat`, …) deploy or render a fresh clone of origin's main, and
  only from a clean main equal to it. `--dirty-ok` is for a deliberate local change. Every
  `init` is refused; use `chezmoi apply --init`.
- The global agent instructions are tracked fragments in `.chezmoitemplates/agents/`.
  `global.md` (shared, tool-agnostic) renders into all three targets
  (`~/.config/agents/GLOBAL.md`, `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`);
  `claude-code.md` (Claude Code only, opening with `## Claude Code only`) is appended to
  `~/.claude/CLAUDE.md` alone; `codex.md` (Codex only, opening with `## Codex only`) is
  appended to `~/.codex/AGENTS.md` alone. Edit a fragment; it deploys once merged, when
  Michael runs `chezmoi apply`. This repo is public: nothing private goes in them.
  `global.md` stays within 150 lines, `claude-code.md` within 50 and `codex.md` within 30;
  `tests/agent-instructions.test.sh` pins all three, and the renders.
- The main checkout `~/.local/share/chezmoi` stays on a clean `main`: never switched,
  never edited in place, because Michael applies from it and the wrapper needs a clean
  `main`. Every branch is a `wt` checkout at `~/.local/share/chezmoi-<branch>`, run by its
  own session with its own Codex pane. The sandbox grants a sibling's writes only to its
  own session's shell, so another session (the driver in the main checkout) writes there
  only with its Edit/Write tools and git commands that touch only the repository (`add`,
  `commit`). Check `git branch --show-current` before each commit, since a session can sit
  in the wrong checkout.
- `.scripts/` are ad-hoc helpers (`provision.sh`, `configure.sh`, `reconcile-agents.sh`,
  `preflight-ssh-agent.sh`), deliberately not `run_once_` scripts: they change system settings
  and need interaction. `install-claude-managed-settings.sh` installs
  `claude-managed-settings.json`, the Claude Code mods lock, into
  `/Library/Application Support/ClaudeCode/`, and refuses a `managed-settings.d` beside it.
  `configure.sh` runs it; `chezmoi apply` never does. Running it for real (sudo, `--replace` to
  overwrite a different policy) is Michael's; agents run it only in test mode, through its
  suite and `tests/provision.test.sh`.
  `forge-protection.sh check` is read-only (GET calls only): it walks `~/Code` to three levels
  and reads each repository's forge protection, skipping the ones listed in the owner's
  `~/.config/forge-protection/exceptions`. Its output names repositories and is never committed;
  agents run it only through its mocked suite, never with a write verb.
  The scripts are mode `755` (not the 644 policy file), except `process-replay.py`'s package
  `process_replay/`, plain 644 modules — git stores only the exec bit, so a clone yields 755,
  never 700.
- The global pre-push hook and its secret scan live in `dot_config/git/hooks/` and deploy to
  `~/.config/git/hooks` (`core.hooksPath`, which replaces each repository's `.git/hooks`; the hook
  runs the repository's own one after its scan). Edit the source; never the deployed copy.
- `tests/` holds every test suite, one `<subject>.test.sh` per script under test. Same
  mode `755`, and the shebang is load-bearing — see Testing.
- `layout.sh`, `tab-goto.sh` and `phase.sh` thread `--session` into every herdr call and never
  call `command herdr` bare: inside a Herdr pane `HERDR_SOCKET_PATH` outranks `HERDR_SESSION`,
  so a bare call targets the pane's own session. `layout.sh` starts a server whenever
  `HERDR_SESSION` is set, even inside a pane. History: `tests/AGENTS.md`.
- Third-party skills are pinned archive externals in `.chezmoiexternal.toml`, each with a
  `symlink_` in `dot_claude/skills/` and a `.chezmoiignore` re-include.
  `.scripts/skill-updates.sh`, run weekly by the `skill-updates` workflow, reports new releases
  as `skill-update` issues. Closing one without a bump declines that release; it is never filed
  again. To bump one, follow the procedure at the top of `.chezmoiexternal.toml`.
- Permissions: `~/.ssh` 700, private keys 600, public keys 644, sensitive configs 600.
- Brewfile: only tools actually in use. Add packages by editing
  `dot_config/homebrew/Brewfile.tmpl` in a `wt` checkout; once merged, Michael runs
  `chezmoi apply` and `brew bundle install --file ~/.config/homebrew/Brewfile`.
- `~/.local/bin/codex` is a launcher that shadows Homebrew's `codex`, because `zshenv`
  puts `~/.local/bin` in front of Homebrew after `brew shellenv` (which prepends);
  `tests/zshenv.test.sh` pins the order. Interactive starts attach to the
  launchd-started daemon or refuse (`--no-daemon` is the escape). Anything needing the
  real binary uses `codex-daemon real-bin`, never `command -v codex`. The daemon would update
  itself outside Homebrew, so it is pinned to the CLI's package with
  `codex app-server daemon update --from-cli`; Michael re-runs that after every
  `brew upgrade codex`, when no review is active, then runs the `live-codex-daemon` canary.

## Layout

```
.chezmoi.toml.tmpl        # chezmoi's own config; must stay at the source root
.chezmoiignore            # what never reaches $HOME (see Rules)
.chezmoiexternal.toml     # pinned third-party skills (archive externals)
.chezmoitemplates/agents/ # the agent instruction fragments: global.md, claude-code.md, codex.md (never deployed)
.scripts/                 # provisioning helpers (ignored)
tests/                    # test suites, `./tests/run.sh` runs them; tests/AGENTS.md (ignored)
dot_config/               # → ~/.config (git, homebrew/Brewfile, mise, zsh, agents, …)
dot_claude/  dot_codex/   # agent harness config: settings/config templates, hooks, guards, agents, skills
private_dot_ssh/          # SSH key templates (1Password)
Library/…/Alfred/         # only the Relay snippet collection
docs/superpowers/         # design records (tracked, ignored by chezmoi)
.github/workflows/        # CI: the weekly skill-update check (ignored)
```

## Testing

```bash
./tests/run.sh                 # every suite with no special requirement
./tests/run.sh --all           # those too, heavy ones included (at least 15 min) — read each `needs:` tag before believing it
./tests/run.sh --changed       # default suites plus each heavy suite whose subject changed against main; the pre-merge run
./tests/run.sh --changed=<ref> # the same against another base
./tests/run.sh forge worktree  # only suites whose name contains one of these
```

Suites run in parallel and print in name order, so the verdicts do not depend on load; a
load-sensitive suite's assertion count can differ between runs (`xreview-packet` F7 slices a
20,000-file case into 8 or 9).

**The runner locks itself:** one per machine. A runner that has to wait prints on stderr who
holds the lock (arguments, checkout, minutes held), again each minute, and once it has the lock
how long it waited (`run.sh: waited 9 min for the test-run lock`). Never wrap it in `lockf`
yourself.

**Execute suites, never prefix an interpreter.** Every suite carries a correct shebang (most
bash; `chezmoi-wrapper`, `dev`, `dev-integrations`, `dev-topology`, `op-edit` and
`wt-functions` are zsh). `./tests/x.test.sh` is always right; `bash tests/x.test.sh` on a zsh
suite reports bogus syntax errors that read exactly like a regression.

Suites needing conditions `run.sh` cannot create carry a `# test-requires:` line and are
skipped by default (a `heavy` tag gives only the suite's timing; what the suite loads is in the
subject map alone). A substring filter to `./tests/run.sh` keeps that gate; only an exact suite
name lifts it (so `./tests/run.sh reconcile-agents` runs the suite, while
`./tests/run.sh reconcile` does not; `./tests/run.sh xreview` is the exact name, so it lifts
the gate and also selects every `xreview-*` suite, which run beside it at no extra wall time):

| Suite | Needs | Why |
|---|---|---|
| `xreview`, `git-forge-guard`, `wt-functions`, `test-audit` | `heavy`: 672 s, 242 s, 123 s, 89 s | skipped by default for their length. Before every pre-merge review run `./tests/run.sh --changed`: it runs each one whose subject (its rows in `.scripts/test-audit/subjects.tsv`, its own file, `tests/run.sh`) changed against main, committed or not, and runs it whenever it cannot tell. An exact name or `--all` runs one regardless. After a tool upgrade that could reach them (`brew upgrade`), run all four by name, since no diff shows that: `./tests/run.sh xreview git-forge-guard wt-functions test-audit` |
| `reconcile-agents` | unsandboxed | writes a temp XDG config dir; sandboxed it reports ~18 false failures |
| `ssh-credential-inventory` | unsandboxed | the `Read(~/.ssh/**)` deny blocks enumeration; it then exits 2 (INCONCLUSIVE) rather than green |
| `zshrc` | unsandboxed | drives a real zsh on a pseudo-terminal (Alt-k and SIGURG), and the sandbox has no pty devices; it then exits 2 (INCONCLUSIVE) |
| `dev-topology` | unsandboxed + live `herdr` | drives the real binary, whose socket the sandbox denies |
| `dev-integrations` | live `herdr` + **interactive** | stops midway for an operator to attach the session and start both agents; it exits 2 with no TTY rather than half-running |
| `live-codex-daemon` | unsandboxed + live `herdr` + clean daemon | drives the real Codex daemon and a scratch tab; the canary for Codex protocol changes. Run from inside a herdr pane after `chezmoi apply` |
| `live-deny-modes` | unsandboxed + model | spends model calls (four modes and a control, each capped by `--max-budget-usd`), and `claude` writes session state under `~/.claude`, which the sandbox denies. Run after each Claude Code upgrade |
| `live-agent-auth`, `live-agent-signing`, `live-credential-boundary`, `live-write-boundary` | **fresh session after `chezmoi apply`, and SANDBOXED** | they measure the sandbox |

A new or moved file a suite loads gets its map row in the same commit; for a file a heavy suite
names, `run`'s drift check fails until it does. Under `--changed` a skipped heavy suite reads
`needs: heavy (no subject changed since <sha>)`, and one that runs carries
`[needs: heavy; changed: …]` or the reason the runner could not tell; quote those lines in the
pre-merge report.

`git-pre-push-hook` needs `gitleaks` and runs sandboxed; its rows are dry-run pushes through a real
git, so none publishes anything. `forge-protection` stubs `gh`, `glab` and `az` on `PATH` and
takes about two minutes (it is not tagged heavy); `ssh-sandbox-proxy` renders its templates with a
stubbed `op`.

`live-write-boundary` also probes a dotfiles `wt` sibling. That probe measures only from a
session started in one (`~/.local/share/chezmoi-<branch>`); from anywhere else it reads FAIL
(exit 2) with an `INCONCLUSIVE: sibling:` line and no `failed_keys`.

**Never run `live-agent-auth`, `live-agent-signing`, `live-credential-boundary` or
`live-write-boundary` with the sandbox disabled.** They measure the sandbox, so disabling it
inverts the result: `live-credential-boundary.test.sh` then reports every private key readable
and exits 12 or more. That is the suite working, not a regression.

**Control for sandbox mode before calling anything a regression:** compare only runs made in
the same mode.

**Never invoke suites with brace expansion.** `bash tests/live-{a,b}.test.sh` expands to
`bash a b` — only the first runs, and the skipped suite prints nothing, so the run looks like a
clean pass. Use `run.sh`, or a loop over a glob. (`live-agent-auth.test.sh` is the one that
genuinely takes an argument — the repo path; `git-forge-guard.test.sh` optionally takes a guard
path, defaulting to the source copy so it tests what will be deployed rather than what
currently is.)

**Report totals as passed/total, never "N green".** `run.sh` prints `passed/total` per suite,
judges each on its **exit status**, and cross-checks that against the counted assertions: a
suite that dies partway is reported `INCONSISTENT` instead of folded into a total.

While chezmoi's external cache is cold (after adding or bumping an external, before the
warm-up), `codex-config`, `claude-settings`, `live-feedback-skill`, `git-pre-push-hook` and
`ssh-sandbox-proxy` exit 2 with an
`INCONCLUSIVE:` line and the warm-up command, and `run.sh` shows it under their `????` row.
That is not a regression.
`xreview-guard-cli` does the same after a glab, gh or az upgrade changes the commands, or the
`api` flags, the pre-merge gate was measured against: it exits 2 with an `INCONCLUSIVE:` line
naming what was added or removed. It also exits 2 when a CLI, or the az extension directory, is
missing. That is not a regression either.

**Reading a run.** A `????` row is not a verdict: the suite asserted nothing, or its exit
status contradicts its assertions (`INCONSISTENT`). Read the exit status the row prints and the
line `run.sh` shows under it. Exit 2 is a suite's own guard (a missing subject, an
`INCONCLUSIVE:` condition), never 1: 1 means an assertion failed. A kv suite (the `KEY=VALUE`
status of `live-agent-auth`, `live-agent-signing`, `live-credential-boundary` and
`live-write-boundary`) encodes failures in its values and exits with the count, so it is judged
on exit status alone. A kv suite that fails a probe closes with one `failed_keys=<key>,<key>`
line; `run.sh` shows that line and any `INCONCLUSIVE:` lines under the FAIL row, never a
`KEY=VALUE` line, so no value is echoed.

**Before adding or changing a suite, a fixture or the runner, read `tests/AGENTS.md`:** it
holds the suite conventions, the runner's knobs and the suite-specific gotchas. Claude Code
loads it when it reads a file under `tests/`; a subagent and Codex read it by hand.

## Troubleshooting

- "1Password CLI couldn't connect": the app must be running with Settings → Developer →
  CLI integration on; then `eval $(op signin)`.
- Script permissions wrong: `chmod 755 .scripts/*.sh && git add --chmod=+x .scripts/*.sh`.
