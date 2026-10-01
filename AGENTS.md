# Dotfiles (chezmoi)

macOS dotfiles managed with chezmoi: XDG layout, secrets rendered from 1Password at
apply time, one-line provisioning. **This repo is public.** Human docs: `README.md`.
Canonical agent context; `CLAUDE.md` imports this file.

## Rules

- **Never commit a secret.** Every secret is a template —
  `{{ onepasswordRead "op://Private/Item/field" }}` (SSH keys: `…?ssh-format=openssh`).
  SSH keys live in `private_dot_ssh/`, tokens in `dot_config/bundler/config.tmpl`.
  Before committing under those paths: `git diff --cached`, and
  `grep -L onepassword private_dot_ssh/private_*.tmpl` must print nothing.
- `.chezmoiignore` is an **allowlist** for `~/.claude`, `~/.codex`, and Alfred: ignore
  the directory contents, then re-include one file at a time, one level at a time — a
  re-include cannot reach inside an ignored directory. A new managed file under those
  trees needs its own `!` entry, or `chezmoi add` silently drops it.
- `README.md`, `AGENTS.md`, `CLAUDE.md`, `docs/`, `tests/`, `.scripts/` are ignored so
  they never land in `$HOME`.
- Edit here and `chezmoi apply`; never hand-edit a deployed file. `chezmoi cat <target>`
  renders one file; `chezmoi apply --dry-run --verbose` previews. Data variables
  (`.name`, `.email`, `.hostname`, `.is_darwin`, `.is_linux`, `.is_arm`) come from
  `.chezmoi.toml.tmpl`, which `chezmoi init` renders — not `apply`.
- The global agent instructions are tracked fragments in `.chezmoitemplates/agents/`.
  `global.md` (shared, tool-agnostic) renders into all three targets
  (`~/.config/agents/GLOBAL.md`, `~/.codex/AGENTS.md`, `~/.claude/CLAUDE.md`);
  `claude-code.md` (Claude Code only, opening with `## Claude Code only`) is appended to
  `~/.claude/CLAUDE.md` alone. Edit a fragment, then `chezmoi apply`. This repo is
  public: nothing private goes in them. `global.md` stays within 180 lines and
  `claude-code.md` within 50; `tests/agent-instructions.test.sh` pins both, and the render.
- This checkout is shared: other sessions switch branches in it, and uncommitted work
  follows the switch. Re-check `git branch --show-current` right before each commit.
  Work here on a branch, not in a harness worktree: xreview needs the repository's own
  Codex pane.
- `.scripts/` are ad-hoc helpers (`provision.sh`, `configure.sh`,
  `reconcile-agents.sh`, `preflight-ssh-agent.sh`), deliberately not `run_once_`
  scripts: they change system settings and need interaction. `measure-interventions.py`
  sits beside them: the transcript metrics for the safe-autonomy evaluation. Mode `755`
  — git stores only the exec bit, so a clone yields 755, never 700.
- `tests/` holds every test suite, one `<subject>.test.sh` per script under test. Same
  mode `755`, and the shebang is load-bearing — see Testing.
- Permissions: `~/.ssh` 700, private keys 600, public keys 644, sensitive configs 600.
- Brewfile: only tools actually in use. Add packages via
  `chezmoi edit ~/.config/homebrew/Brewfile`, then `chezmoi apply` and
  `brew bundle install --file ~/.config/homebrew/Brewfile`.
- `~/.local/bin/codex` is a launcher that shadows Homebrew's `codex`, because `zshenv`
  puts `~/.local/bin` in front of Homebrew after `brew shellenv` (which prepends);
  `tests/zshenv.test.sh` pins the order. Interactive starts attach to the
  launchd-started daemon or refuse (`--no-daemon` is the escape). Anything needing the
  real binary uses `codex-daemon real-bin`, never `command -v codex`.

## Layout

```
.chezmoi.toml.tmpl        # chezmoi's own config; must stay at the source root
.chezmoiignore            # what never reaches $HOME (see Rules)
.chezmoitemplates/agents/ # the agent instruction fragments: global.md, claude-code.md (never deployed)
.scripts/                 # provisioning helpers (ignored)
tests/                    # test suites, `./tests/run.sh` runs them (ignored)
dot_config/               # → ~/.config (git, homebrew/Brewfile, mise, zsh, agents, …)
dot_claude/  dot_codex/   # agent harness config: settings/config templates, hooks, guards, agents, skills
private_dot_ssh/          # SSH key templates (1Password)
Library/…/Alfred/         # only the Relay snippet collection
docs/superpowers/         # design records (tracked, ignored by chezmoi)
```

## Testing

Suites live in `tests/`, one `<subject>.test.sh` per script under test.

```bash
./tests/run.sh                 # every suite with no special requirement
./tests/run.sh --all           # those too — read each `needs:` tag before believing it
./tests/run.sh forge worktree  # only suites whose name contains one of these
```

**Execute suites, never prefix an interpreter.** Every suite carries a correct shebang
(most bash; `wt-functions`, `dev`, `dev-topology` and `dev-integrations` are zsh). Running
a zsh suite under `bash` reports bogus syntax errors that read exactly like a regression,
because it stubs zsh builtins. `./tests/x.test.sh` is always right; `bash tests/x.test.sh`
is the footgun. `run.sh` executes them for this reason.

Suites needing conditions `run.sh` cannot create carry a `# test-requires:` line and are
skipped by default. A substring filter to `./tests/run.sh` keeps that gate; only an
exact suite name lifts it (so `./tests/run.sh reconcile-agents` runs the suite, while
`./tests/run.sh reconcile` does not):

| Suite | Needs | Why |
|---|---|---|
| `reconcile-agents` | unsandboxed | writes a temp XDG config dir; sandboxed it reports ~18 false failures |
| `ssh-credential-inventory` | unsandboxed | the `Read(~/.ssh/**)` deny blocks enumeration; it then exits 2 (INCONCLUSIVE) rather than green |
| `dev-topology` | unsandboxed + live `herdr` | drives the real binary, whose socket the sandbox denies |
| `dev-integrations` | live `herdr` + **interactive** | stops midway for an operator to attach the session and start both agents; it exits 2 with no TTY rather than half-running |
| `live-codex-daemon` | unsandboxed + live `herdr` + clean daemon | drives the real Codex daemon and a scratch tab; the canary for Codex protocol changes. Run from inside a herdr pane after `chezmoi apply` |
| `live-agent-auth`, `live-agent-signing`, `live-credential-boundary` | **fresh session after `chezmoi apply`, and SANDBOXED** | they measure the sandbox |

**Never run `live-agent-auth`, `live-agent-signing` or `live-credential-boundary` with
the sandbox disabled.** They measure the sandbox, so disabling it inverts the result:
`live-credential-boundary.test.sh` then reports every private key readable and exits
12. That is the suite working, not a regression.

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
because that file is TOML. `herdr-phase` stubs `herdr` and `glab` on `PATH`; the script it
tests is not runnable sandboxed, since `phase.sh` wraps `herdr` and fails silently when the
socket is denied.

A suite whose subject has moved must fail loudly, not silently pass: each one checks its
target exists and exits 2 if not. Keep that when adding suites — a guard test whose guard
is missing otherwise reports every "must allow" case as a pass.

Two output idioms exist and `run.sh` counts both: prose (`  ok  …` / `  PASS: …`) and the
`KEY=VALUE` status the `live-agent-auth`, `live-agent-signing` and
`live-credential-boundary` suites emit so they never print key material. A kv suite
encodes failures in its values and exits with the count, so it is judged on exit status
alone — the prose cross-check does not apply to it.

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
