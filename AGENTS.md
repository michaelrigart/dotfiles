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
- `.scripts/` are ad-hoc helpers (`provision.sh`, `configure.sh`,
  `reconcile-agents.sh`, `preflight-ssh-agent.sh`), deliberately not `run_once_`
  scripts: they change system settings and need interaction.
  `install-claude-managed-settings.sh` installs `claude-managed-settings.json`, the Claude Code
  mods lock, into `/Library/Application Support/ClaudeCode/`, and refuses a `managed-settings.d`
  beside it. `configure.sh` runs it; `chezmoi apply` never does. Running it for real (sudo,
  `--replace` to overwrite a different policy) is Michael's; agents run it only in test mode,
  through its suite and `tests/provision.test.sh`.
  `measure-interventions.py` sits beside them: the transcript metrics for the
  safe-autonomy evaluation, and `process-replay.py` (with its package `process_replay/`,
  plain 644 modules) and `xreview-replay.py` are the replay-experiment harnesses.
  `skill-updates.sh` is non-interactive too and runs weekly in the `skill-updates` workflow.
  The scripts are mode `755` (not the 644 policy file) — git stores only the exec bit, so a
  clone yields 755, never 700.
- `tests/` holds every test suite, one `<subject>.test.sh` per script under test. Same
  mode `755`, and the shebang is load-bearing — see Testing.
- Third-party skills are pinned archive externals in `.chezmoiexternal.toml`, each with a
  `symlink_` in `dot_claude/skills/` and a `.chezmoiignore` re-include.
  `.scripts/skill-updates.sh`, run weekly by the `skill-updates` workflow, reports new
  releases as `skill-update` issues. Closing one without a bump declines that release; it is
  never filed again. A bump reads the upstream diff first and runs `agent-text-scan --diff` on it: an `invisible`
  finding stops the bump until Michael has seen it, and any other finding that matters goes in
  the commit message. It then changes the SHA and its tag
  comment, then warms chezmoi's cache outside the sandbox
  (`command chezmoi --source <checkout> managed >/dev/null`: sandboxed, Go's TLS fails).
  Confirm afterwards that `command chezmoi --source <checkout> managed` lists
  `.agents/skills/<name>/SKILL.md`, and that `.scripts/skill-updates.sh` prints
  `current: <name> <tag>` (a SHA that exists only in a fork still downloads). The commit
  message carries `Closes #<issue>`.
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
tests/                    # test suites, `./tests/run.sh` runs them (ignored)
dot_config/               # → ~/.config (git, homebrew/Brewfile, mise, zsh, agents, …)
dot_claude/  dot_codex/   # agent harness config: settings/config templates, hooks, guards, agents, skills
private_dot_ssh/          # SSH key templates (1Password)
Library/…/Alfred/         # only the Relay snippet collection
docs/superpowers/         # design records (tracked, ignored by chezmoi)
.github/workflows/        # CI: the weekly skill-update check (ignored)
```

## Testing

Suites live in `tests/`, one `<subject>.test.sh` per script under test.

```bash
./tests/run.sh                 # every suite with no special requirement
./tests/run.sh --all           # those too, heavy ones included (~11 min) — read each `needs:` tag before believing it
./tests/run.sh forge worktree  # only suites whose name contains one of these
```

Suites run in parallel (`RUN_JOBS`, default: half the online CPUs, at least 2; an explicit
`RUN_JOBS=1` is honoured and restores sequential order). Output is buffered and printed in name order, so the verdicts are
the same either way; a load-sensitive suite's assertion count can differ (`xreview-packet`
F7 slices a 20,000-file case into 8 or 9). A suite that cannot share the machine carries a
`# test-serial` line and runs alone after the parallel ones (today only `xreview`), and so does
every suite gated on a condition other than `heavy` (a live herdr, a pty, the real daemon).

**The runner locks itself:** one per machine (`lockf` on `/tmp/claude-$(id -u)/tests-run.lock`,
`RUN_SH_LOCK` overrides the path), and it says so when it waits. A nested runner sees
`RUN_SH_LOCKED=1` and does not lock again. Never wrap it in `lockf` yourself.

**Execute suites, never prefix an interpreter.** Every suite carries a correct shebang
(most bash; `chezmoi-wrapper`, `dev`, `dev-integrations`, `dev-topology`, `op-edit` and
`wt-functions` are zsh). Running
a zsh suite under `bash` reports bogus syntax errors that read exactly like a regression,
because it stubs zsh builtins. `./tests/x.test.sh` is always right; `bash tests/x.test.sh`
is the footgun. `run.sh` executes them for this reason.

Suites needing conditions `run.sh` cannot create carry a `# test-requires:` line and are
skipped by default. A substring filter to `./tests/run.sh` keeps that gate; only an
exact suite name lifts it (so `./tests/run.sh reconcile-agents` runs the suite, while
`./tests/run.sh reconcile` does not; `./tests/run.sh xreview` is the exact name, so it
lifts the gate and also selects every `xreview-*` suite, which run beside it at no extra
wall time):

| Suite | Needs | Why |
|---|---|---|
| `xreview`, `git-forge-guard`, `wt-functions` | `heavy`: 672 s, 242 s, 123 s | skipped by default for their length. Run by exact name when a file its tag lists changes, and all three before every pre-merge review: `./tests/run.sh xreview git-forge-guard wt-functions` |
| `reconcile-agents` | unsandboxed | writes a temp XDG config dir; sandboxed it reports ~18 false failures |
| `ssh-credential-inventory` | unsandboxed | the `Read(~/.ssh/**)` deny blocks enumeration; it then exits 2 (INCONCLUSIVE) rather than green |
| `zshrc` | unsandboxed | drives a real zsh on a pseudo-terminal (Alt-k and SIGURG), and the sandbox has no pty devices; it then exits 2 (INCONCLUSIVE) |
| `dev-topology` | unsandboxed + live `herdr` | drives the real binary, whose socket the sandbox denies |
| `dev-integrations` | live `herdr` + **interactive** | stops midway for an operator to attach the session and start both agents; it exits 2 with no TTY rather than half-running |
| `live-codex-daemon` | unsandboxed + live `herdr` + clean daemon | drives the real Codex daemon and a scratch tab; the canary for Codex protocol changes. Run from inside a herdr pane after `chezmoi apply` |
| `live-deny-modes` | unsandboxed + model | spends model calls (four modes and a control, each capped by `--max-budget-usd`), and `claude` writes session state under `~/.claude`, which the sandbox denies. Run after each Claude Code upgrade |
| `live-agent-auth`, `live-agent-signing`, `live-credential-boundary`, `live-write-boundary` | **fresh session after `chezmoi apply`, and SANDBOXED** | they measure the sandbox |

`live-write-boundary` also probes a dotfiles `wt` sibling. That probe measures only from a
session started in one (`~/.local/share/chezmoi-<branch>`); from anywhere else it reads
FAIL (exit 2) with an `INCONCLUSIVE: sibling:` line and no `failed_keys`.

**Never run `live-agent-auth`, `live-agent-signing`, `live-credential-boundary` or `live-write-boundary`
with the sandbox disabled.** They measure the sandbox, so disabling it inverts the result:
`live-credential-boundary.test.sh` then reports every private key readable and exits
12 or more. That is the suite working, not a regression.

**Control for sandbox mode before calling anything a regression.** Comparing a sandboxed
run against an unsandboxed one once produced a believable "18-test regression" that was
entirely an artefact.

**Never invoke suites with brace expansion.** `bash tests/live-{a,b}.test.sh` expands to
`bash a b` — only the first runs, the second becomes an ignored `$1`, and the skipped
suite prints nothing, so the run looks like a clean pass. Use `run.sh`, or a loop over a
glob. (`live-agent-auth.test.sh` is the one that genuinely takes an argument — the repo
path; `git-forge-guard.test.sh` optionally takes a guard path, defaulting to the source
copy so it tests what will be deployed rather than what currently is.)

**Report totals as passed/total, never "N green".** A handoff once claimed "324 assertions
green" when it was 321 green / 3 red — 324 was the *total*. `run.sh` prints `passed/total`
per suite, judges each on its **exit status**, and cross-checks that against the counted
assertions: a suite that dies partway prints only the assertions it reached and would
otherwise look clean, so it is reported `INCONSISTENT` instead of folded into a total.

Two suite-specific gotchas worth keeping: `codex-config` drives the `modify_` **template**
via `chezmoi execute-template --with-stdin --file` — without `--with-stdin` every case dies
on "map has no entry for key stdin", and its empty-input fixture is `''`, not `'{}'`,
because that file is TOML. `herdr-phase` stubs `herdr`, `glab` and `gh` on `PATH`; the script it
tests is not runnable sandboxed, since `phase.sh` wraps `herdr` and fails silently when the
socket is denied. The script itself needs `/usr/bin/jq` and `/usr/bin/timeout` (and
`/usr/bin/lockf`); the stubs do not replace them, and `refresh` exits 2 without any.

While chezmoi's external cache is cold (after adding or bumping an external, before the
warm-up), `codex-config`, `claude-settings` and `live-feedback-skill` exit 2 with an
`INCONCLUSIVE:` line and the warm-up command, and `run.sh` shows it under their `????` row.
That is not a regression.

A suite whose subject has moved must fail loudly, not silently pass: each one checks its
target exists and exits 2 if not. Keep that when adding suites — a guard test whose guard
is missing otherwise reports every "must allow" case as a pass.

Two output idioms exist and `run.sh` counts both: prose (`  ok  …` / `  PASS: …`) and the
`KEY=VALUE` status the `live-agent-auth`, `live-agent-signing`, `live-credential-boundary` and
`live-write-boundary` suites share (the first three also so they never print key material). A kv suite
encodes failures in its values and exits with the count, so it is judged on exit status
alone — the prose cross-check does not apply to it. A kv suite that fails a probe closes with one
`failed_keys=<key>,<key>` line (not when it dies early, before any key); `run.sh` shows that line
and any `INCONCLUSIVE:` lines under the FAIL row, never a `KEY=VALUE` line, so no value is echoed,
and does not count it as an assertion. A new kv suite should print it.
`tests/write-boundary-probe.test.sh` drives `live-write-boundary` against a throwaway `HOME`
and a stubbed `mkdir`, so its `.git/modules` probe, its sibling probe (including the INCONCLUSIVE-only
exit 2, through the `WRITE_BOUNDARY_SIBLING_ONLY` seam, refused against the real home) and `failed_keys` line are
tested without measuring a sandbox.

**Inside a Herdr pane, `HERDR_SESSION` does not pick the session.** herdr 0.9.3 reads
`HERDR_SESSION`, but `HERDR_SOCKET_PATH`, which herdr exports into every pane, outranks it;
only `--session` outranks the socket (measured 2026-09-30 with `herdr status`). So
`layout.sh`, `tab-goto.sh` and `phase.sh` thread `--session` in themselves, and nothing in
them may call `command herdr` bare — from inside a pane a bare call targets the pane's own
session, whatever `HERDR_SESSION` says. That is what made `dev-topology`'s isolation a
fiction: it built its fixtures into the live session and then asserted against an empty
`dev-test`. `layout.sh` also starts a server whenever `HERDR_SESSION` is set, even inside a
Herdr pane, because the pane you are in belongs to a different session than the one you
named.

## Troubleshooting

- "1Password CLI couldn't connect": the app must be running with Settings → Developer →
  CLI integration on; then `eval $(op signin)`.
- Script permissions wrong: `chmod 755 .scripts/*.sh && git add --chmod=+x .scripts/*.sh`.
