# Provisioning Preflight (minimal) Implementation Plan

**Status:** Implemented — merged to `main` in f670f33
**Date:** 2026-08-27

**Spec:** [2026-08-27 Provisioning preflight (minimal)](../specs/2026-08-27-provisioning-preflight-minimal-design.md)

Supersedes [the original plan](./2026-08-27-provisioning-preflight.md), which was
never executed.

> **Retrospective record.** This plan documents work already done, in the order it was
> done. It is written down because the lifecycle policy tracks a plan alongside every
> spec, not because it was followed prospectively. Do not re-execute it.
>
> Strict checkpoint compliance would place this record *before* the implementation
> commits in branch history. Reordering history was not done, because it requires
> explicit authorization and rewrites commits already reviewed. Noted rather than
> silently ignored.

## Tasks, as executed

- [x] **1. Machine allowlist and Brewfile template.** Added
  `.chezmoidata/machines.toml` (`known_hostnames`); `git mv` of
  `dot_config/homebrew/Brewfile` → `Brewfile.tmpl`; the three peripheral casks
  (`elgato-control-center`, `focusrite-control`, `jiggler`) moved behind
  `{{ if eq $live "fenrir" }}`, with a header guard reading `ComputerName` and
  `HostName` live from `scutil`.

- [x] **2. Preflight in `provision.sh`.** Replaced the old steps 4–5 with: plain
  `git clone` of the source; the 1Password gate (`op whoami` polled, cask installed
  during bootstrap and fatal on failure); machine-name prompt validated against the
  allowlist; `sudo -v` plus a keepalive; one confirm; then `scutil --set` for all
  three fields with a read-back. `chezmoi init` moved after the identity is settled.

- [x] **3. Interruption fixes.** `NONINTERACTIVE=1` on the Homebrew installer;
  bounded Xcode CLT polling replacing `exit 0`; `sudo chsh` replacing bare `chsh`;
  `StrictHostKeyChecking=accept-new` on the GitHub check; Brewfile failures
  downgraded to itemised warnings with an end-of-run summary; `SRC_DIR` used
  consistently in place of hardcoded `${XDG_DATA_HOME}/chezmoi`.

- [x] **4. `configure.sh --hostname`.** Verifies all three identity fields and never
  renames in that mode; standalone behaviour unchanged except that the hostname
  comparison is now exact rather than a `grep -q` substring match. Trackpad and
  battery `defaults` gained hostname guards, preserving all five original trackpad
  lines including the `-currentHost` variant.

- [x] **5. `.scripts/test-provision.sh`.** 36 assertions. See the spec's §4 for the
  isolation contract, which is the part that matters.

- [x] **6. Lifecycle.** Original spec and plan marked
  `Superseded — see <link>`, forward-linked to these records.

## Defects found by the tests, not by review

Worth recording because they justify the suite's existence:

- `SRC_DIR` was introduced but three later steps still hardcoded
  `${XDG_DATA_HOME}/chezmoi`, so the run aborted at step 7.
- The `sudo` keepalive loop held stdout open in both `provision.sh` and
  `configure.sh`, hanging any caller using `$( )`.
- `not_called "chsh -s"` could not distinguish `chsh -s` from `sudo chsh -s`; it now
  compares invocation counts.
- `rc_is 1` against `configure.sh` passed for unrelated reasons, leaving the new
  `HostName` check untested until the assertions keyed on `identity verified` not
  being reached.

## Follow-ups, not done

- Borg: per-machine BorgBase repo; the two `borg-*-fenrir` keys are unmanaged.
- The primary workstation's `ComputerName` must be set before `chezmoi apply` will
  succeed under the new guard (spec §5). User-authorized; not performed.
