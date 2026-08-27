# Provisioning preflight

**Status:** Approved
**Date:** 2026-08-27

Restructures `.scripts/provision.sh` around a single rule: every question is asked
before any long-running work starts. Introduces machine identity as a real, validated
concept, because a second Mac now exists.

Depends on the source-root relocation of `.chezmoi.toml.tmpl` (landed 2026-08-27,
same working tree). That change is a prerequisite, not part of this design — but it
inverts an ordering constraint this design must honour, see §5.1.

## 1. Problem

`provision.sh` is a 16-step linear script under `set -e`. Two defects make a fresh
provision unpleasant, and a third makes it wrong once a second machine exists.

**Input is scattered through the run.** The script stops for a human four times, at
unpredictable points, potentially hours apart:

| Step | Interruption |
|---|---|
| 1 | Xcode CLT dialog — and the script `exit 0`s, requiring a manual re-run |
| 4 | `eval $(op signin)` |
| 10 | `chsh` password prompt |
| `configure.sh` | `sudo -v`, then the hostname prompt, then Alfred accessibility |

There is no point at which the machine can be left alone with confidence.

**One failure destroys the run.** Under `set -e` a single cask that wants a licence
kills every remaining step, with no record of what completed. The one exception is
`reconcile-agents.sh`, wrapped in `|| log_warn` — proving the best-effort concept is
already understood here, just not generalised.

**Step 4 cannot succeed on a genuinely fresh Mac.** `eval $(op signin)` assumes a
configured 1Password account. On a new machine `op account list` is empty, and the
`1password` desktop cask that would supply CLI integration is not installed until
step 8 — two steps *after* `chezmoi apply` at step 6, which needs `op://` reads to
render `~/.ssh`, `~/.ssh/config`, git signing keys, `GLOBAL.md`, and bundler tokens.
The dependency runs backwards.

**Machine identity is declared but fictional.** `.chezmoi.toml.tmpl` sets
`hostname` from `output "scutil" "--get" "ComputerName"`. Measured on the primary
workstation, 2026-08-27:

```
ComputerName:   MacBook Pro
HostName:       not set
LocalHostName:  MacBook-Pro
~/.config/chezmoi/chezmoi.toml:  hostname = "fenrir"
```

The rendered config disagrees with the machine. The cause is ordering:
`configure.sh` sets the hostname at the very end of provisioning, long after
`chezmoi init` read it. Today this is harmless — `grep` across every `*.tmpl` and
`*.sh` in the repo finds **no consumer of `.hostname` at all**. It stops being
harmless the moment anything keys off it.

## 2. Goals

- All human input collected before the first mutating phase, then an unattended run.
- A failure surfaces what needs attention without discarding completed work.
- `hostname` becomes accurate and load-bearing, with unknown machines rejected
  loudly rather than silently taking a default branch.
- Per-machine divergence expressible in the Brewfile and `configure.sh`.
- No new runtime dependency: the script is `curl | zsh` on a bare machine.

## 3. Non-goals

- **No TUI toolkit.** `gum` and a compiled ratatui/bubbletea binary were both
  considered and rejected (§9). The bootstrap constraint is real: a fresh Mac has
  no package manager when `provision.sh` starts.
- **No profile/role concept.** A `profile = desktop|laptop` key decoupled from
  machine name was considered and rejected (§9). Conditionals key off `.hostname`
  directly.
- **No rollback.** Phases are idempotent and resumable; they do not undo.
- **`configure.sh` is not absorbed.** It stays independently re-runnable (§7).

## 4. Stage structure

Four stages replace sixteen steps. The boundary between stage 1 and stage 2 is the
only thing that matters: **nothing after the confirm asks a question.**

### 4.1 Stage 0 — bootstrap

Xcode CLT (waits for completion rather than exiting), Homebrew,
`brew install chezmoi 1password-cli git`, `brew install --cask 1password`, then a
plain `git clone` of the dotfiles repo over HTTPS into `$XDG_DATA_HOME/chezmoi`.

This stage makes no decisions, so it needs no input — which is why it precedes
preflight rather than being folded into it. Homebrew must exist before the
1Password cask can be installed, and the 1Password gate in stage 1 needs that cask.
Naming the stage honestly is preferable to pretending preflight comes first.

**The clone is separated from `chezmoi init` deliberately.** `chezmoi init` does two
things — clone the source, and render the config from it. Preflight needs the source
present, because the hostname allowlist (§5.2) lives in it; but the config must not
be rendered until *after* the name is set (§5.1). Splitting them resolves what would
otherwise be circular: stage 0 clones with `git`, stage 2 runs `chezmoi init` against
the already-present source and only generates the config. `chezmoi init` against an
existing source directory was verified to do exactly that on v2.72.0.

Xcode CLT changes behaviour: today an uninstalled CLT triggers the dialog, prints
"re-run this script", and exits 0. It instead polls `xcode-select -p` until the
dialog is satisfied. A user who cancels gets a clear abort, not a silent success.

Stage 0's work is recorded in the state file like any other phase, so `--resume`
skips it.

### 4.2 Stage 1 — preflight

Everything that can ask a question, in this order:

1. **1Password gate.** Open `1Password.app`, print the two required in-app actions
   (sign in; Settings → Developer → *Integrate with 1Password CLI*), then poll
   `op whoami` until it answers. Biometric unlock; the Secret Key is never typed,
   which matters because the Emergency Kit is stored off-machine by policy.
2. **Machine name.** Prompted and validated against the allowlist in the
   just-cloned `.chezmoidata/machines.toml` (§5.2). The answer is recorded, not yet
   applied — `scutil --set` needs sudo, which is not held until step 3.
3. **sudo.** `sudo -v` plus the existing keepalive loop, held for the whole run.
   With it in hand, the name recorded in step 2 is applied now: `scutil --set` for
   `ComputerName`, `HostName`, and `LocalHostName`. Acquiring sudo here is also what
   lets stage 2 run unattended.
4. **Summary and confirm.** Every decision echoed, then one `[y/N]`.

Preflight answers are written to the state file before the confirm, so `--resume`
re-asks nothing.

### 4.3 Stage 2 — run

Ten phases, unattended. See §6.

### 4.4 Stage 3 — report

Accumulated warnings with concrete remediation, and the retry command for the
phases that produced them. Items that cannot be scripted — Microsoft Office
licensing, macfuse's System Settings approval, Alfred's Accessibility grant — are
reported here rather than blocking the run.

## 5. Machine identity

### 5.1 The ordering defect, and why it inverts

`.chezmoi.toml.tmpl` now lives at the source root, so `chezmoi init` renders it
before any `apply`. That fixed the chicken-and-egg described in the file's own
header, and in doing so made init the moment machine identity is captured:

```
today:     chezmoi init … (14 steps) … configure.sh → prompt → scutil --set
proposed:  git clone (stage 0) → scutil --set (stage 1) → chezmoi init (stage 2)
```

`chezmoi init` must therefore run *after* the name is set. This is the single
ordering constraint the whole design exists to protect, and it gets a dedicated
test (§8).

### 5.2 Allowlist, enforced in two independent places

`.chezmoidata/machines.toml` at the source root:

```toml
known_hostnames = ["fenrir", "studio"]
```

Verified against chezmoi v2.72.0: `.chezmoidata/` entries load into template data
(`{{ .known_hostnames | join "," }}` → `fenrir,studio`), and sprig's `fail` aborts
a render with exit 1.

**Layer 1 — preflight.** An unlisted name is rejected interactively, with the
manifest path named so the fix is obvious.

**Layer 2 — the template itself.** `Brewfile.tmpl` opens with:

```gotemplate
{{ if not (has .hostname .known_hostnames) }}
{{- fail (printf "unknown machine %q — add it to .chezmoidata/machines.toml" .hostname) }}
{{- end }}
```

Layer 2 is the one that matters long-term. It catches a bare `chezmoi apply` on a
machine renamed outside provisioning — a path the script never observes. Without
it, an unknown hostname silently takes the else-branch: nothing errors, nothing
installs, and the divergence is invisible until someone notices a missing app.

### 5.3 `Brewfile` becomes `Brewfile.tmpl`

The direct consequence of hostname-keyed conditionals. Three peripheral casks move
behind a guard:

```gotemplate
{{ if eq .hostname "fenrir" -}}
cask "elgato-control-center"
cask "focusrite-control"
cask "jiggler"
{{ end -}}
```

`chezmoi edit ~/.config/homebrew/Brewfile` continues to work on templates.
`provision.sh`'s tap-trust loop seds the *rendered* file at
`$XDG_CONFIG_HOME/homebrew/Brewfile` and is unaffected.

The cost is real: the Brewfile stops being one flat readable list, and each new
machine means auditing each conditional. Accepted deliberately — see §9 for the
alternative that was weighed against it.

## 6. Phase model

### 6.1 Phases and criticality

| # | Phase | Criticality |
|---|---|---|
| 1 | `xcode-clt` | critical |
| 2 | `homebrew` | critical |
| 3 | `source-clone` | critical |
| 4 | `chezmoi-init` | critical |
| 5 | `dotfiles` | critical |
| 6 | `brewfile` | best-effort |
| 7 | `agent-plugins` | best-effort |
| 8 | `mise` | best-effort |
| 9 | `macos-config` | best-effort |
| 10 | `shell` | best-effort |

Phases 1–3 are stage 0's work; phases 4–10 are stage 2's. The numbering is
continuous because the state file and `--phase` do not distinguish them.

Critical failures abort: nothing downstream is meaningful without Homebrew, or
without a rendered `~/.ssh`. Best-effort failures append to the warning list and
the run continues.

`shell` (adding Homebrew zsh to `/etc/shells` and `chsh`) is best-effort by
deliberate choice: a failure leaves the login shell as the system zsh, which is
inconvenient at next login but breaks nothing in the current run, and is a
one-line manual fix.

`chsh -s …` becomes `sudo chsh -s … "$USER"`. Bare `chsh` prompts for the user's
password mid-run; routed through the sudo credential already cached in preflight,
it does not. This removes an interruption at no cost.

### 6.2 Brewfile per-item reporting

`brew bundle` exits non-zero if any single item fails, which by itself yields
"bundle failed" plus a wall of output. On non-zero exit the phase re-runs
`brew bundle check --verbose` and reports the specific missing items as individual
warnings. That is what turns the failure into `⚠ microsoft-office — licence`.

### 6.3 State and resume

`$XDG_STATE_HOME/provision/state` records completed phase names **and the preflight
answers**, so `--resume` re-asks nothing.

Flags: `--resume`, `--phase <name>`, `--restart`, `--dry-run`.

Invoked via curl, flags pass as `/bin/zsh -c "$(curl -fsSL …)" provision --resume`
(`zsh -c` takes `$0` then positional arguments). Once the dotfiles are cloned, the
local path at `~/.local/share/chezmoi/.scripts/provision.sh` is the better entry
point and the report says so.

## 7. Boundary with `configure.sh`

`configure.sh` remains a standalone, independently re-runnable script — documented
as such in `CLAUDE.md`, and genuinely useful on its own for re-applying macOS
defaults. It becomes phase 8 rather than being absorbed.

Three changes:

- Accepts `--hostname <name>`. When supplied, it does not prompt. When run
  standalone with no flag it prompts exactly as today, and skips the `scutil --set`
  calls when the current name already matches.
- Trackpad (`TrackpadThreeFingerDrag`, `Clicking`) and battery-percentage `defaults`
  gain hostname guards. They are harmless no-ops on a desktop, but under a design
  that models divergence explicitly, leaving them unguarded is inconsistent.
- Its closing "manual tasks still required" list feeds stage 3 rather than printing
  its own trailer when invoked as a phase.

## 8. Testing strategy

New `.scripts/test-provision.sh`, bash, mocked in the existing house style: stub
`brew`, `chezmoi`, `op`, `scutil`, and `sudo` on `PATH` and assert on the recorded
call sequence. Assertions that earn their place:

1. **`scutil --set ComputerName` is recorded before `chezmoi init`.** The ordering
   regression in §5.1 — the single most important assertion in the suite.
2. Preflight rejects a hostname absent from `known_hostnames`.
3. `Brewfile.tmpl` renders `fail` (exit 1) for an unknown hostname, driven through
   `chezmoi execute-template` as `test-codex-config.sh` already does.
4. `Brewfile.tmpl` renders the exact three peripheral casks for `fenrir` and omits
   exactly those three for `studio` — asserted as exact cask lists, never as counts.
5. `--resume` skips phases recorded in the state file and asks no questions.
6. A critical phase failure aborts; a best-effort failure continues and appears in
   the stage 3 report.
7. No mutating phase runs before the confirm.
8. The source clone is recorded before preflight reads `known_hostnames` — the
   dependency that makes layer-1 validation possible at all.

Per repo convention the suite is fully mocked and runs under either sandbox mode.
Its assertion count is added to the running baseline once green.

## 9. Alternatives considered

**`gum`-driven wizard, two-stage.** A pure-zsh stage 0 installs Homebrew and `gum`,
then re-execs into a `gum choose` / `gum input` / `gum spin` wizard. Genuinely
better-looking. Rejected: it adds a Brewfile dependency and a visible bootstrap
seam, to solve a problem that is not actually aesthetic. The run is unpleasant
because it interrupts you four times, not because it lacks box-drawing — and
front-loading fixes that without the dependency.

**Compiled TUI binary** (Rust/ratatui or Go/bubbletea). Full-screen, live logs,
per-phase retry. Rejected: needs a build-and-release pipeline, and a bare Mac would
have to fetch and run a binary it has no established way to verify. Disproportionate
to a script that runs a handful of times per machine lifetime.

**`profile` data key decoupled from machine name.** A `desktop|laptop` role
prompted at preflight; machines sharing a role stay byte-identical. Cleaner at
three or more machines. Rejected at two: it asks a second question per machine, and
peripheral ownership does not actually follow role — it follows whatever is
plugged in, which is a per-machine fact, not a per-role one.

**One config everywhere; accept the three extra casks.** The minimal option: no
`Brewfile.tmpl`, no conditionals, `hostname` load-bearing only for Borg identity.
Rejected in favour of explicit divergence, accepting that the Brewfile stops being
a single flat list.

## 10. Consequences

- `dot_config/homebrew/Brewfile` → `Brewfile.tmpl`. The file is no longer readable
  as a plain list without rendering it.
- `.hostname` becomes load-bearing. A machine whose `ComputerName` drifts from its
  allowlist entry now fails loudly at render time. This is intended, and is the
  behaviour that makes the current `MacBook Pro` / `fenrir` mismatch impossible to
  reproduce.
- Adding a machine is a two-file change: an entry in `.chezmoidata/machines.toml`
  and, only if it diverges, a conditional in `Brewfile.tmpl`.
- `configure.sh` gains a flag and stops being the owner of machine naming.
- Provisioning gains resumable state at `$XDG_STATE_HOME/provision/`, which is
  execution exhaust and is never tracked.

## 11. Open questions

- **Borg identity is out of scope here but adjacent.** The Borg repo name
  (`fenrir`) and key (`~/.ssh/borg-fenrir`) encode machine identity independently
  of `.hostname`. A second machine needs its own repo and key. Whether those should
  derive from `.hostname` is a separate decision, deliberately not settled by this
  design — the SSH key templates read from 1Password and changing their naming
  touches credential material.
