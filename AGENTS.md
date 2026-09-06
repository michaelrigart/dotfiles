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
- The global agent instructions (`~/.config/agents/GLOBAL.md`, `~/.claude/CLAUDE.md`,
  `~/.codex/AGENTS.md`) render from the 1Password item *Agent instructions*. Edit the
  note, then `chezmoi apply`.
- `.scripts/` are ad-hoc helpers (`provision.sh`, `configure.sh`,
  `reconcile-agents.sh`, `preflight-ssh-agent.sh`, `test-*.sh`), deliberately not
  `run_once_` scripts: they change system settings and need interaction. Mode `755` —
  git stores only the exec bit, so a clone yields 755, never 700.
- Permissions: `~/.ssh` 700, private keys 600, public keys 644, sensitive configs 600.
- Brewfile: only tools actually in use. Add packages via
  `chezmoi edit ~/.config/homebrew/Brewfile`, then `chezmoi apply` and
  `brew bundle install --file ~/.config/homebrew/Brewfile`.

## Layout

```
.chezmoi.toml.tmpl        # chezmoi's own config; must stay at the source root
.chezmoiignore            # what never reaches $HOME (see Rules)
.scripts/                 # provisioning + test suites (ignored)
dot_config/               # → ~/.config (git, homebrew/Brewfile, mise, zsh, agents, …)
dot_claude/  dot_codex/   # agent harness config: settings/config templates, hooks, guards, agents, skills
private_dot_ssh/          # SSH key templates (1Password)
Library/…/Alfred/         # only the Relay snippet collection
docs/superpowers/         # design records (tracked, ignored by chezmoi)
```

## Testing

`.scripts/test-*.sh` do **not** all run the same way, and getting it wrong produces
convincing fake failures. Control for interpreter and sandbox mode before calling
anything a regression — comparing a sandboxed run against an unsandboxed one once
produced a believable "18-test regression" that was entirely an artefact.

| Suite | Interpreter | Sandbox |
|---|---|---|
| `test-wt-functions.sh` | **zsh** — bash reports bogus syntax errors (it stubs zsh builtins) | either |
| `test-reconcile-agents.sh` | bash | **unsandboxed** — writes a temp XDG config dir; sandboxed it reports ~18 false failures |
| `test-ssh-credential-inventory.sh` | bash | **unsandboxed** — the `Read(~/.ssh/**)` deny blocks enumeration; it correctly exits 2 (INCONCLUSIVE) rather than green |
| `test-codex-config.sh` | bash | either — drives the `modify_` **template** via `chezmoi execute-template --with-stdin --file`; without `--with-stdin` every case dies on "map has no entry for key stdin". The empty-input fixture is `''`, not `'{}'` — that file is TOML, not JSON |
| `test-git-forge-guard.sh` | bash | either — builds git fixtures under `$TMPDIR`, writable when sandboxed |
| `test-herdr-phase.sh` | bash | either — git fixtures under `$TMPDIR`; `herdr` and `glab` are stubbed on `PATH`. The script it tests is **not** runnable sandboxed: `phase.sh` wraps `herdr`, whose socket the sandbox denies, and it fails silently |
| `test-claude-settings.sh`, `test-ssh-sandbox-proxy.sh`, `test-git-signing-config.sh`, `test-alfred-relay.sh`, `test-path-resolution-guard.sh` | bash | either (fully mocked) |
| `test-live-agent-auth.sh`, `test-live-agent-signing.sh`, `test-live-credential-boundary.sh` | bash | **fresh session after `chezmoi apply`, and SANDBOXED** |

**Never run the live suites with the sandbox disabled.** They measure the sandbox, so
disabling it inverts the result: `test-live-credential-boundary.sh` then reports every
private key readable and exits 12. That is the suite working, not a regression.

**Never invoke them with brace expansion.** `bash .scripts/test-live-{a,b}.sh` expands to
`bash a.sh b.sh` — only `a.sh` runs, `b.sh` becomes an ignored `$1`, and the skipped suite
prints nothing, so the run looks like a clean pass. Use a loop:

```bash
for f in .scripts/test-live-*.sh; do bash "$f"; done
```

(`test-live-agent-auth.sh` is the one that genuinely takes an argument — the repo path.)

**Report totals as passed/total, never "N green".** A handoff once claimed "324 assertions
green" when it was 321 green / 3 red — 324 was the *total*. The three red were in
`test-wt-functions.sh`, the one suite needing zsh, which a bash run hides.

## Troubleshooting

- "1Password CLI couldn't connect": the app must be running with Settings → Developer →
  CLI integration on; then `eval $(op signin)`.
- Script permissions wrong: `chmod 755 .scripts/*.sh && git add --chmod=+x .scripts/*.sh`.

## Design Records

Specs and plans are committed under `docs/superpowers/specs/` and `docs/superpowers/plans/`.
Execution state (`.superpowers/`, `docs/superpowers/runs/`) is never tracked.
