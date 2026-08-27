# Provisioning preflight

**Status:** Approved
**Date:** 2026-08-27

Restructures `.scripts/provision.sh` around a single rule: **every decision is made
before the unattended work starts.** Bootstrap is the bounded exception — it installs
the prerequisites needed to ask anything at all, and requires one macOS dialog (§4.1).
Introduces machine identity as a real, validated concept, because a second Mac now
exists.

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

- All human input collected before the **confirm**, which gates hostname mutation
  and phases 4–10. Bootstrap (phases 1–3) is an explicit exception: it installs
  software before anything can be asked, because nothing can be asked until it has.
  See §4.1 — this is a narrower promise than "no mutation before input", and the
  narrower one is the true one.
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
  machine name was considered and rejected (§9). Conditionals key off the live
  identity (§5.2), not a stored value.
- **No rollback.** Phases are idempotent and resumable; they do not undo.
- **`configure.sh` is not absorbed.** It stays independently re-runnable (§7).
- **No Vorta or BorgBase automation.** Provisioning sets the hostname that backup
  identity depends on, and reports Borg setup as outstanding; it creates no repos,
  keys, or backup profiles (§11.4).

## 4. Stage structure

Four stages replace sixteen steps. The boundary between stage 1 and stage 2 is the
only thing that matters: **nothing after the confirm asks a question.**

### 4.1 Stage 0 — bootstrap

Xcode CLT (waits for completion rather than exiting), Homebrew,
`brew install chezmoi 1password-cli git`, `brew install --cask 1password`, then a
plain `git clone` of the dotfiles repo over HTTPS into `$XDG_DATA_HOME/chezmoi`.

This stage makes no *decisions* — which is why it precedes preflight rather than
being folded into it. Homebrew must exist before the 1Password cask can be
installed, and the 1Password gate in stage 1 needs that cask. Naming the stage
honestly is preferable to pretending preflight comes first. It does still require
one interaction, the Xcode CLT dialog; see below.

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

**Stage 0 mutates the machine before anything has been confirmed, and that is not
avoidable.** Installing Homebrew, the 1Password cask and the dotfiles source is the
prerequisite for asking any question at all. What stage 0 must not do is make a
*decision*: it installs a fixed set of prerequisites identically on every machine,
and touches nothing machine-specific. The confirm gates everything that is a choice
— hostname mutation included (§4.2).

**Stage 0 is also not input-free**, and an earlier draft claiming it "needs no input"
was wrong. Installing the Xcode Command Line Tools opens a GUI dialog that macOS
owns and that a human must accept. The honest contract is narrower and worth stating
exactly: *bootstrap may require Xcode CLT interaction; everything after a successful
confirm is unattended for the remainder of that uninterrupted run.* A later `--resume`
may still reacquire lapsed credentials (§6.3) — it re-asks no decisions, which is a
different promise.

Because macOS gives no completion signal, the CLT install is detected by polling
`xcode-select -p`. Two failure modes need explicit handling, since neither raises an
error on its own: the user **cancels** the dialog, and the user **never responds**.
Both present identically — `xcode-select -p` simply keeps failing — so both resolve
through one bounded wait that aborts with a message naming the dialog, rather than
hanging forever or reporting a false success the way the current script's `exit 0`
does.

Homebrew's installer prompts for confirmation by default, so it is invoked with
`NONINTERACTIVE=1`. Without it, stage 0 stops on a "Press RETURN to continue" that
the design promises does not exist.

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
   Acquiring it here is what lets stage 2 run unattended. Nothing is applied yet.
4. **Summary and confirm.** Every decision echoed, then one `[y/N]`.
5. **Apply the identity.** Only now: `scutil --set` for `ComputerName`, `HostName`
   and `LocalHostName`, followed by a read-back asserting `ComputerName` and
   `HostName` equal the chosen name exactly and `LocalHostName` matches
   `^<identity>(-[0-9]+)?$` (§5.2 explains the suffix tolerance). This is the first
   machine-specific mutation in the entire run.

Steps 3 and 5 are deliberately split. An earlier draft applied the hostname in step
3, before the confirm — which meant declining at step 4 still left the machine
renamed, and silently changed the basis of Borg's archive naming. Declining must
leave the machine exactly as it was found.

**Recorded answers are not recorded consent.** State carries three distinct
markers, written at three different moments:

| Marker | Written when | Means |
|---|---|---|
| `answers_collected` | after step 2 | the questions have been answered |
| `confirmed` | after a `y` at step 4 | the user approved *this* answer set |
| `identity_applied` | after step 5's read-back succeeds | the machine has been renamed |

An earlier draft wrote the answers before the confirm and let `--resume` treat their
presence as proof consent had been given. That is a consent-laundering bug: answer
the questions, decline at the confirm, resume a week later, and the machine is
renamed and provisioned without anyone ever having said yes. **Resuming a run whose
state lacks `confirmed` re-displays the summary and asks again.** `--resume` skips
the confirm only when `confirmed` is present.

The markers are a state machine, and a resume must handle every boundary:

| State found | Action on resume |
|---|---|
| no `confirmed` | re-display the summary and ask again; nothing is applied |
| `confirmed`, no `identity_applied` | apply the identity, then continue |
| `identity_applied` | **revalidate live** before trusting it — the machine may have been renamed since; a mismatch aborts and directs to `--repair-identity` |
| answers differ from those recorded | clear `confirmed` and `identity_applied`; a changed answer set has never been consented to |

`scutil --set` is idempotent, so a crash between applying the identity and recording
`identity_applied` is safe: the retry re-applies the same values and the read-back
passes. The marker records that the step *completed*, and is never the sole evidence
that it happened — the read-back is.

### 4.3 Stage 2 — run

Seven phases (4–10 of the ten; phases 1–3 are stage 0's). Unattended. See §6.

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

Note what this ordering does and does not buy. It makes the *stored* `.hostname`
correct at the moment of provisioning. It does nothing about drift afterwards —
that is §5.2's problem, and it is why the template guard reads the machine live
rather than trusting what init captured.

### 5.2 Identity must be read live, not from stored data

`.chezmoidata/machines.toml` at the source root:

```toml
known_hostnames = ["fenrir", "studio"]
```

Verified against chezmoi v2.72.0: `.chezmoidata/` entries load into template data
(`{{ .known_hostnames | join "," }}` → `fenrir,studio`), and sprig's `fail` aborts
a render with exit 1.

**`.hostname` is stored, not live — so a guard built on it cannot detect drift.**
An earlier draft of this section keyed the template guard on `.hostname` and claimed
it would catch a machine renamed outside provisioning. That claim was false.
`.chezmoi.toml.tmpl` evaluates `scutil --get ComputerName` **once, at `chezmoi init`**,
and writes the result into `~/.config/chezmoi/chezmoi.toml`. Every later `apply`
reads the stored value. Measured on the primary workstation, which already exhibits
exactly this drift:

```
scutil --get ComputerName          → MacBook Pro     (live)
chezmoi execute-template .hostname → fenrir          (stored)
```

A rename therefore leaves `.hostname` reporting the old name indefinitely, and a
guard comparing it to the allowlist passes forever.

**The guard reads the machine live, from a shared partial.** `.chezmoitemplates/identity-guard`
holds the rules; every template keying off identity opens the same way:

```gotemplate
{{- $live := output "scutil" "--get" "ComputerName" | trim -}}
{{- template "identity-guard" (dict "live" $live "stored" .hostname "known" .known_hostnames) -}}
```

The caller binds `$live` itself and passes it in. That is not redundancy: a Go
template partial cannot export a variable back into its caller's scope, so a partial
that bound `$live` internally would leave the caller with nothing to write its
conditionals against. Binding once in the caller and passing it down keeps the
`ComputerName` lookup to a single subprocess and gives the conditionals the same
value the guard validated. The partial reads `HostName` itself, since no caller
needs it.

Verified on chezmoi v2.72.0 with a stubbed `scutil`, all five paths: agreement
renders; a non-matching machine renders without the guarded casks; unset `HostName`
fails with the migration message; a `HostName` disagreeing with `ComputerName` fails
naming both; and stored-versus-live drift fails naming both.

`ComputerName` is the live key because macOS always has one; `HostName` can be
unset, and `scutil --get HostName` then exits **0** while printing the literal
string `HostName: not set`, which a naive guard would happily compare against the
allowlist. Every conditional in the file keys off `$live`, never `.hostname` — a
conditional on stored data has the same staleness bug as a guard on it.

**The guard checks `HostName` too, because `ComputerName` alone does not enforce the
invariant.** §11.1 requires all three identity fields to agree; a guard reading only
`ComputerName` passes a machine whose `HostName` has drifted — and `HostName` is the
Borg-critical field, so that is precisely the drift that must not pass silently. The
checks live in a shared partial under `.chezmoitemplates/`, included by any template
that keys off identity, so the rule is defined once:

| Field | Checked where | Rule |
|---|---|---|
| `ComputerName` | template + preflight | equals the chosen identity; equals stored `.hostname` |
| `HostName` | template + preflight | equals the chosen identity; unset is a *named migration state*, reported as such rather than as a mismatch |
| `LocalHostName` | preflight only | matches `^<identity>(-[0-9]+)?$` |

`LocalHostName` is deliberately excluded from the template and matched loosely:
macOS appends `-2`, `-3`, `-4` on its own when the Bonjour name collides on the
network, so requiring permanent exact equality would fail for reasons outside the
machine's control. Provisioning sets it and tolerates a numeric suffix; nothing keys
off it.

**Reconciliation needs its own mode, not a phase.** `chezmoi init` refreshes the
*stored* `.hostname` and nothing else — it cannot set `HostName`, so it is the wrong
remedy for field divergence and no message may offer it alone.

`--phase identity` is equally wrong, and an earlier draft proposed it: there is no
`identity` phase in the table (§6.1), `--phase` requires a state file a legacy
machine does not have, and `--phase` skips the confirm — which would make identity
mutation possible without consent, the exact hole §4.2 closes.

The remedy is a distinct top-level mode, **`provision.sh --repair-identity`**, which:

1. runs without any recorded state, so it works on a legacy or externally-renamed
   machine;
2. prompts for the identity and validates it against `known_hostnames`;
3. **displays the proposed before/after for all three fields** and requires an
   explicit `y` — identity mutation always requires consent, in every mode;
4. applies `scutil --set`, reads all three back, and fails if any disagrees;
5. re-runs `chezmoi init` so stored data matches.

It shares the read-back validator with preflight rather than reimplementing it.

What it does to an *existing* state file — including the case where the repair
changes the identity a previous run was consented to — is specified in §6.3, with
the flag matrix, because that is a state-transition question rather than an identity
one.

**What each layer actually catches**, stated narrowly because the earlier draft
overclaimed:

| Situation | Preflight | Template |
|---|---|---|
| Unlisted name typed during provisioning | rejected, re-prompts | — |
| `chezmoi init` on a machine with an unlisted identity | — | **not caught** — init renders no targets and exits 0 |
| `chezmoi apply` with an unlisted stored identity | — | fails the render |
| `ComputerName` or `HostName` changed after init, then `apply` | — | fails on the drift check |
| `LocalHostName` gains a `-N` suffix from a Bonjour collision | — | **deliberately passes** — not a rename |

Verified: `chezmoi init` against an unlisted identity exits 0, stores
`hostname = "MacBook Pro"`, and writes zero targets. Only the following `apply`
rejects it. Provisioning is what prevents an unlisted identity being stored in the
first place; the template is what prevents one being *used*.

### 5.3 `Brewfile` becomes `Brewfile.tmpl`

The direct consequence of hostname-keyed conditionals. Three peripheral casks move
behind a guard:

```gotemplate
{{ if eq $live "fenrir" -}}
cask "elgato-control-center"
cask "focusrite-control"
cask "jiggler"
{{ end -}}
```

`$live` is the live-read identity bound at the top of the file (§5.2), not
`.hostname`. A conditional keyed on stored data carries the same staleness bug as a
guard keyed on it: after a rename the machine would keep receiving the old machine's
casks.

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

The `dotfiles` phase's `ssh -T git@github.com` check is a **pre-existing** prompt,
not one this design introduces — but the promise of an unattended run is new, and it
makes the prompt a contract violation. `ssh -G github.com` resolves
`stricthostkeychecking ask`, and no `known_hosts` is managed, so on a fresh machine
the check blocks on "Are you sure you want to continue connecting?". Either it runs
with `-o StrictHostKeyChecking=accept-new`, or GitHub's host keys become managed
content. Which one is an implementation detail; leaving it prompting is not.

### 6.2 Brewfile per-item reporting

`brew bundle` exits non-zero if any single item fails, which by itself yields
"bundle failed" plus a wall of output. On non-zero exit the phase re-runs
`brew bundle check --verbose` and reports the specific missing items as individual
warnings. That is what turns the failure into `⚠ microsoft-office — licence`.

### 6.3 State and resume

`$XDG_STATE_HOME/provision/state` records completed phase names **and the preflight
answers**, so `--resume` re-asks no decisions. Credentials are separate (below), and
consent is gated on the `confirmed` marker (§4.2), not on the answers' presence.

Flags are explicit state transitions, not independent booleans. Each is defined by
what it does to recorded state and to preflight:

| Flag | Recorded state | Preflight | Confirm |
|---|---|---|---|
| *(none)* | starts fresh; refuses to run if state exists, directing to `--resume` or `--restart` | full | asked |
| `--resume` | read; completed phases skipped | decisions re-used; credentials revalidated | skipped **only** if `confirmed` is recorded |
| `--restart` | discarded **after** flag validation, never during a `--dry-run` | full | asked |
| `--phase NAME` | read; requires **both** `confirmed` and `identity_applied`; only `NAME` runs | decisions re-used; live identity revalidated; credentials that phase needs revalidated; unknown `NAME` is an error, not a no-op | not asked |
| `--dry-run` | neither read nor written | skipped | not asked |
| `--repair-identity` | see below — depends on whether a state file exists and whether the identity changes | identity questions only | **always asked**, before any `scutil --set` |

`--repair-identity` is **mutually exclusive** with `--resume`, `--restart`, `--phase`
and `--dry-run`; combining them is a usage error, not a merge of behaviours. It is a
repair mode, not a provisioning mode, and it never runs a provisioning phase.

Its interaction with existing state is the part that must be nailed down, because
repair can *change the identity a previous run was consented to*:

| State found | What repair does |
|---|---|
| none | works standalone; sets and verifies the identity; creates **no** provisioning state |
| exists, identity unchanged | repairs the fields, then marks `identity_applied` — the previous consent still describes this machine |
| exists, identity **changed** | **deletes the state file entirely**, then exits telling the user to run `provision.sh` with no flags |

The third row is the one worth stating explicitly. Consent was given for a specific
identity and does not transfer to a different one. Neither do the completed phases —
they ran against the old identity, and on a hostname-conditional Brewfile that means
they may have installed the wrong machine's packages. Carrying either forward would
let a `--resume` treat approval of `fenrir` as approval of `studio`: the
consent-laundering bug of §4.2 arriving by a different route.

**It deletes the whole file rather than selectively clearing markers**, and that
choice is deliberate. An earlier draft cleared `confirmed`, `identity_applied` and
the phase records but left the recorded *answer* — so a repair from `fenrir` to
`studio` left `machine_name=fenrir` in state, and the next `--resume` would have
displayed `fenrir` and renamed the machine straight back. Selective clearing has now
produced a cross-identity carryover bug three times in this design's review; the
state file describes one provisioning run of one machine, and once the identity
changes, none of it describes anything. Re-entering one answer is cheaper than
reasoning about which fields survive.

Three failure modes this table exists to prevent, all of which a naive
implementation exhibits:

- **An already-confirmed `--resume` blocking on the confirm.** Re-approving what was
  already approved makes `--resume` unusable non-interactively. This applies only
  once `confirmed` is recorded — an *unconfirmed* resume correctly asks again (§4.2),
  and that is not the failure mode.
- **A skipped phase skipping its side effects.** The `homebrew` phase both installs
  Homebrew *and* initialises `HOMEBREW_PREFIX` and `PATH` for the process. Resuming
  past it must still perform the second part, or every later phase runs against an
  unconfigured environment — and `${HOMEBREW_PREFIX}` is an unbound-variable abort
  under `set -u`. Process-environment setup belongs outside phase completion.
- **`--phase` running without an identity.** `--phase macos-config` needs the machine
  name; without loading recorded answers it passes an empty string.
- **`--phase` running *before* the identity was applied.** Requiring only `confirmed`
  is not enough: from a state with `confirmed` but no `identity_applied`,
  `--phase chezmoi-init` would capture whatever the machine is currently called —
  reintroducing the §5.1 ordering defect through the flag surface rather than through
  the phase order. `--phase` therefore requires both markers *and* revalidates the
  live identity, refusing and naming `--resume` or `--repair-identity` otherwise.

**Decisions persist; credentials do not.** `--resume` re-uses every answer, but sudo
times out after five minutes and a 1Password CLI session after ten. A resumed run
must revalidate both — `sudo -v` and `op whoami`, reacquiring if either has lapsed —
before entering the unattended phases. "Nothing is prompted on resume" is therefore
true of *decisions* and false of *credentials*, and the design should not claim
otherwise: a resume hours later will ask for a password, and that is correct.

Invoked via curl, flags pass as `/bin/zsh -c "$(curl -fsSL …)" provision --resume`
(`zsh -c` takes `$0` then positional arguments). Under that invocation `$0` is the
literal word `provision`, so recovery messages must print a resolved path to the
cloned script — never `$0`, which would print a command that does not exist.

## 7. Boundary with `configure.sh`

`configure.sh` remains a standalone, independently re-runnable script — documented
as such in `CLAUDE.md`, and genuinely useful on its own for re-applying macOS
defaults. It becomes phase 9 rather than being absorbed.

Three changes:

- Accepts `--hostname <name>`. **In this mode it validates and never renames.** If
  the live identity disagrees with the supplied name it aborts and directs to
  `--repair-identity`; it does not call `scutil --set` at all.

  This is a correctness requirement, not tidiness. `configure.sh` is phase 9, and
  phase 9 is best-effort and reachable via `--phase macos-config`, which skips the
  confirm. If it could rename, that path would be an unconfirmed identity mutation —
  the same hole §4.2 closes at the front door, left open at the back. Renaming
  happens in exactly two places, both explicitly confirmed: preflight step 5, and
  `--repair-identity`.

  Run standalone with no flag, it prompts and renames exactly as today.
- Trackpad (`TrackpadThreeFingerDrag`, `Clicking`) and battery-percentage `defaults`
  gain hostname guards. They are harmless no-ops on a desktop, but under a design
  that models divergence explicitly, leaving them unguarded is inconsistent.
- Its closing "manual tasks still required" list feeds stage 3 rather than printing
  its own trailer when invoked as a phase.

## 8. Testing strategy

New `.scripts/test-provision.sh`, bash, mocked in the existing house style.

**Isolation is a correctness requirement of the suite, not a nicety.** `provision.sh`
deletes files in `$HOME`, chmods `~/.ssh`, installs packages and rewrites macOS
defaults. A harness that isolates only `PATH` and `XDG_STATE_HOME` leaves all of that
pointed at the real machine — and `eval "$(/opt/homebrew/bin/brew shellenv)"`, an
absolute path, puts real Homebrew ahead of the stubs mid-run. The suite therefore
runs against a temporary `HOME` and temporary values for **every** XDG root, and
opens with a guard that aborts if any of them still resolves inside the real home
directory. Scripts invoked by path rather than through `PATH` (`configure.sh`,
`reconcile-agents.sh`) must be stubbed by path too.

Assertions must read the recorded call log, not the script's stdout: a stub that
records to a file contributes nothing to stdout, so a substring assertion against
output silently passes or fails for the wrong reason.

Assertions that earn their place:

1. **`scutil --set ComputerName` is recorded before `chezmoi init`.** The ordering
   regression in §5.1 — the single most important assertion in the suite.
2. Preflight rejects a hostname absent from `known_hostnames`.
3. The identity partial renders `fail` (exit 1) for a live identity absent from the
   allowlist, **and separately** for a live identity that disagrees with stored
   `.hostname`, **and separately** for an unset `HostName` with the migration message
   rather than a mismatch one. Driven through `chezmoi execute-template` with a
   stubbed `scutil`, as `test-codex-config.sh` already drives templates.
4. `Brewfile.tmpl` renders the exact three peripheral casks for `fenrir` and omits
   exactly those three for `studio` — asserted as exact cask lists, never as counts.
5. `--resume` skips phases recorded in the state file and re-asks no *decisions*
   (credentials are a separate matter — see 9).
6. A critical phase failure aborts; a best-effort failure continues and appears in
   the stage 3 report.
7. No *machine-specific* mutation runs before the confirm — specifically, no
   `scutil --set`. Bootstrap's installs are the acknowledged exception (§4.1), so
   this is asserted against the identity calls, not against mutation in general.
8. Decline at the confirm, then `--resume`: the summary is shown and consent asked
   again, and no `scutil --set` is recorded until a second explicit `y`. This is the
   consent-laundering regression from §4.2.
9. A resume with a lapsed sudo credential and a locked 1Password session
   revalidates both rather than proceeding with stale authority.
10. The source clone is recorded before preflight reads `known_hostnames` — the
    dependency that makes preflight validation possible at all.
11. A `HostName` that is *set but wrong* fails the guard, distinctly from one that is
    unset — the two produce different messages and must not be conflated.
12. `LocalHostName` of `fenrir-2` is accepted by the preflight read-back; `fenrir-x`
    and `studio` are rejected. The suffix tolerance is a specific pattern, not a
    prefix match.
13. `--repair-identity` runs to completion with **no state file present** — the
    legacy path — and still refuses to apply anything without an explicit `y`.
14. **`--phase macos-config` never records a `scutil --set` call.** Asserted directly
    against the call log, because this is the back-door identity mutation §7 exists
    to prevent.
15. Resume across each marker boundary: no `confirmed` re-asks; `confirmed` without
    `identity_applied` applies then continues; `identity_applied` with a since-changed
    live identity aborts to `--repair-identity`; a changed answer set clears both
    markers.
16. **`--repair-identity` from `fenrir` to `studio`, with existing state, leaves no
    state file at all.** Asserted on the file's absence, not on individual markers.
    The following invocation must prompt from scratch and **display `studio`** — the
    assertion checks the identity shown, since a run that merely asks for
    confirmation while displaying `fenrir` is the exact bug this prevents.
17. `--repair-identity` combined with `--resume`, `--restart`, `--phase` or
    `--dry-run` is rejected as a usage error.
18. `--phase` from a state with `confirmed` but **no** `identity_applied` is refused,
    naming `--resume` — not silently run, which would let `chezmoi-init` capture a
    pre-migration name.
19. `--phase` from a state with `identity_applied` whose live identity has since
    drifted is refused, naming `--repair-identity`.

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
- `scutil --set HostName` becomes load-bearing for backups, not merely cosmetic
  (§11.1). It is critical-path in preflight and may not be downgraded.
- An unset `HostName` changes from the status quo to a failure state (§11.1).
- `Brewfile.tmpl` shells out to `scutil` on every render, including during
  `chezmoi diff` and `chezmoi status`. That is the price of live identity, and it
  is the right trade: a guard on stored data cannot detect the drift it exists to
  catch (§5.2).
- Declining the confirm leaves the machine's *identity and configuration* exactly as
  found — no `scutil --set`, no dotfiles applied, no packages beyond bootstrap. It is
  not byte-identical: bootstrap has by then installed Homebrew, the 1Password cask
  and the dotfiles source. Those are machine-independent and identical on every
  machine, which is what makes them acceptable before consent — but the honest claim
  is "nothing machine-specific", not "nothing".
- Two Borg keys remain unmanaged by chezmoi (§11.3). Tracked as follow-up; a
  rebuild of the existing machine currently omits them.

## 11. Borg identity

Resolved 2026-08-27, during spec review. Recorded here because it constrains what
preflight may do to the system hostname.

### 11.1 Backup identity does not come from `.hostname`

Measured from Vorta's `settings.db` on the primary workstation:

```
archive name  : {hostname}-{now:%Y-%m-%d-%H%M%S}
prune prefix  : {hostname}-
recent archive: fenrir-2026-08-26-101429
profile key   : borg-append-only-fenrir
repo url      : an opaque BorgBase repo id, not a machine name
```

`{hostname}` is Borg's placeholder, resolved through `socket.gethostname()`, which
returns `fenrir`. But `ComputerName` is `MacBook Pro` and `HostName` is unset — so
`fenrir` is supplied by DHCP/DNS, not configured on the machine. Backup identity
currently depends on the network.

Two consequences follow. Because `prune_prefix` is `{hostname}-`, a DHCP-supplied
rename silently stops prune from matching existing archives: backups keep
succeeding while retention quietly stops working. And chezmoi's `.hostname`
(from `ComputerName`) and Borg's `{hostname}` (from DNS) are *different values on
the same machine today*.

Setting `HostName` in preflight (§4.2) makes the name local rather than
network-supplied. That is a fix, but it makes preflight load-bearing for backups:
**`scutil --set HostName` may never be skipped or made best-effort.**

**All three fields are validated; two of them exactly.** Preflight sets
`ComputerName`, `HostName` and `LocalHostName`, then reads all three back: the first
two must equal the chosen identity exactly, and `LocalHostName` must match
`^<identity>(-[0-9]+)?$`. The template guard (§5.2) checks `ComputerName` **and**
`HostName` — an earlier draft checked only `ComputerName`, which would have left
`HostName` free to drift past every render, and `HostName` is the field Borg reads.

`LocalHostName` is excluded from the template and matched loosely because macOS
appends a number to it on its own when the name collides on the local network. A
template failing on `fenrir-2` would be failing on something the machine's owner
neither chose nor can prevent, and nothing keys off `LocalHostName` anyway.

**The currently-unset `HostName` is a one-time legacy migration, not a supported
state.** After provisioning, an unset `HostName` is a failure, not a fallback.

### 11.2 Separate repo per machine

Each machine gets its own BorgBase repo, its own keypair, and its own quota. A
prefix mistake or a hostname collision cannot reach another machine's archives, and
either machine can be restored or purged without reasoning about the other.

Rejected: one shared repo with per-machine archive prefixes. It deduplicates across
both Macs — not nothing, given both would hold `~/Code` and the Obsidian vault —
but prune is prefix-scoped, so a prefix collision merges two machines' retention
silently, and both machines contend on one repository lock. Isolation is worth more
than dedup for irreplaceable data.

### 11.3 The Borg keys are unmanaged

`private_dot_ssh/` templates cover `borg`, `borg-append-only`, `borg-hercules`, and
`borg-synology`. The keys the Vorta profile actually uses — `borg-fenrir` and
`borg-append-only-fenrir` — exist on disk but are **not chezmoi-managed** and not in
the public repo.

This is a restore gap for the existing machine, not only a provisioning gap for the
new one: a rebuild of fenrir reproduces every other credential from 1Password and
silently omits the two that reach the backups. Closing it is out of scope for this
design and is tracked as follow-up work.

### 11.4 What provisioning does, and does not, do

**Does:** set `HostName` authoritatively in preflight, so `{hostname}` is local and
stable.

**Does not:** create BorgBase repos, generate or register Borg keypairs, or write
Vorta profiles. Repo creation needs the BorgBase UI, and the passphrase belongs in
1Password — neither is scriptable from `provision.sh`, and inventing a half-automated
path around credential material is worse than a named manual step. Stage 3 reports
Borg setup as outstanding on a machine with no configured repo.

**Separately, on the existing machine:** replace `{hostname}` with the literal
machine name in the archive template and prune prefix, so backup identity stops
depending on DNS resolution. This edits a live backup profile and is therefore a
deliberate, separately-confirmed change — not something provisioning performs.
