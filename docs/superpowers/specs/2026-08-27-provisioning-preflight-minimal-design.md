# Provisioning preflight (minimal)

**Status:** In progress — branch `feat/provisioning-preflight`, under review
**Date:** 2026-08-27

Supersedes [2026-07-30 → 2026-08-27 Provisioning preflight](./2026-08-27-provisioning-preflight-design.md),
which was approved and then deliberately reduced. This record describes what was
actually built.

## 1. Problem

`provision.sh` stopped for human input four times, at unpredictable points, hours
apart: the Xcode CLT dialog (after which it `exit 0`d and asked to be re-run),
`op signin`, the `chsh` password prompt, and `configure.sh`'s hostname prompt. There
was no point at which a fresh machine could be left alone.

Two smaller defects compounded it. `op signin` at step 4 assumed a configured
1Password account, but the desktop cask that supplies CLI integration was not
installed until step 8 — two steps *after* the apply that renders `op://` templates.
And `configure.sh` set the hostname at the very end, long after `chezmoi init` had
captured it — so on a fresh machine the identity chezmoi recorded was whatever the
machine happened to be called at clone time, not the name being provisioned.

## 2. What was built

- **One preflight block.** 1Password gate, machine name, `sudo -v`, one `[y/N]`, then
  the identity is applied. Nothing after the confirm asks a question.
- **Machine identity is real.** The name is validated against
  `.chezmoidata/machines.toml`, then `ComputerName`, `HostName` and `LocalHostName`
  are set and read back. `HostName` matters specifically: it is what `hostname(1)` —
  and therefore Borg archive naming — resolves to. `LocalHostName` tolerates the
  numeric suffix macOS appends on Bonjour collisions.
- **Consent gates the rename.** Declining leaves identity and configuration exactly
  as found; only bootstrap installs have happened by then.
- **Ordering fixed.** A plain `git clone` fetches the source, so the allowlist is
  readable before the name is chosen; `chezmoi init` runs afterwards and captures the
  settled identity.
- **A live template guard.** `Brewfile.tmpl` reads `ComputerName` and `HostName` from
  `scutil` at render time and fails on an unlisted machine, on a `ComputerName` /
  `HostName` disagreement, or on an unset `HostName`. It does **not** use chezmoi's
  `.hostname`, which is captured once at `init` and never refreshed — a guard built on
  it could never fire.
- **Interruptions removed:** `NONINTERACTIVE=1` for Homebrew's own prompt, bounded
  Xcode CLT polling (a cancelled dialog and a slow one are indistinguishable, so one
  wait covers both), `sudo chsh`, and `StrictHostKeyChecking=accept-new`.
- **One bad cask no longer ends the run.** Brewfile failures become warnings,
  itemised via `brew bundle check --verbose`, printed in a summary at the end.
- **`configure.sh --hostname` verifies and never renames**, checking all three fields.

## 3. What was deliberately not built

The superseded design specified a phase framework, a state file, `--resume`,
`--phase`, `--dry-run`, `--repair-identity`, and three consent markers. None was
built.

Those emerged from design review rather than from the problem. The problem was four
interruptions in a bootstrap script that runs a handful of times per machine
lifetime; the machinery was disproportionate to it, and each review round found real
defects in complexity that the previous round had introduced.

`set -e` is retained. **The recovery model is re-running from the start**, which is
safe because every step is idempotent: existing installs are detected, `scutil --set`
is idempotent, and `chezmoi apply --force` converges. That is why no state file is
needed.

## 4. Testing

`.scripts/test-provision.sh`, bash, 36 assertions. Isolation is a correctness
requirement, not hygiene: `provision.sh` deletes files under `$HOME` and rewrites
macOS defaults.

- `env -i` with a temporary `HOME` and every temporary XDG root.
- `PROVISION_BREW_BIN` and `PROVISION_SRC_OVERRIDE` as the only two override points,
  both asserted to resolve inside the temp root **before** anything runs. Verifying
  that a containment assertion can fail must never be done by pointing an override at
  a real binary — doing exactly that executed the host's Homebrew twice during
  development and advanced its git HEAD.
- `sudo` delegates via `exec "$@"`, or `MOCK_FAIL` injection never reaches the tool
  under test and the identity assertions become vacuous.
- `scutil` is file-backed, so `--set` really changes what `--get` returns.
- `rm`, `chmod` and `find` are wrapped: they delegate inside the temp root and refuse
  outside it, logging refusals to a file so an escape is observable even when the
  caller redirects stderr. Logging alone is fail-open.
- `configure.sh` and `reconcile-agents.sh` are invoked by path, so they are stubbed by
  path — but the identity validation is tested against the **real** `configure.sh`,
  because a stub left that code untested.

Assertions key on what discriminates. `rc_is 1` against `configure.sh` passes for
unrelated reasons; the mismatch tests assert that `identity verified` is never
reached. Both properties were confirmed by deleting the checks and watching the
suite go red.

## 5. Known consequence

The live guard fails on any machine whose `ComputerName` is not in `known_hostnames`,
or whose `HostName` disagrees with it. Adding a machine therefore means adding it to
`.chezmoidata/machines.toml` *before* the first `chezmoi apply`.

The primary workstation satisfies the guard as-is: `ComputerName` and `HostName` are
both `fenrir`, and `LocalHostName` is `fenrir-4` — the numeric suffix macOS appends on
a Bonjour name collision, which is exactly why `LocalHostName` is excluded from the
template guard and matched with a suffix tolerance in preflight. No migration is
required.

**A caution about verifying this.** During development, the agent's sandboxed shell
consistently reported `MacBook Pro` / unset / `MacBook-Pro` for the same three
`scutil` reads that the user's interactive shell reported as `fenrir` / `fenrir` /
`fenrir-4`. The discrepancy was never explained. Identity claims about this machine
should be taken from an interactive terminal, not from tooling.

## 6. Out of scope

Borg identity: each machine needs its own BorgBase repo and keypair, since archives
are named from the hostname and a shared repo would interleave two machines. The
`borg-fenrir` and `borg-append-only-fenrir` keys are not chezmoi-managed, which is a
restore gap for the existing machine. Both are recorded in the superseded design's
§11 and remain unaddressed.
