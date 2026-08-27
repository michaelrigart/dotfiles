# Provisioning Preflight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure `.scripts/provision.sh` so every question is asked before any long-running work, and make machine identity a validated, load-bearing concept.

**Architecture:** Four stages — bootstrap (prerequisites, no decisions), preflight (all human input, ending in one confirm), run (ten unattended phases), report (warnings + remediation). Phases declare themselves critical or best-effort; a state file records completed phases and preflight answers so `--resume` re-asks nothing. Machine identity is validated against an allowlist in `.chezmoidata/machines.toml`, enforced both in preflight and inside `Brewfile.tmpl`.

**Tech Stack:** zsh (provision.sh, configure.sh), bash (test suites), chezmoi v2.72.0 templates, Homebrew Bundle.

**Spec:** `docs/superpowers/specs/2026-08-27-provisioning-preflight-design.md`

## Global Constraints

- `provision.sh` and `configure.sh` are **zsh**. Test suites are **bash**, and must be **Bash 3.2 compatible** (macOS `/bin/bash`): no associative arrays, no `mapfile`, no `${x,,}`.
- **`set -e` is removed from `provision.sh`.** Best-effort phases cannot exist under it. Every phase returns a status that `run_phase` interprets. This is a deliberate reversal of the current script's behaviour.
- **No new Homebrew dependencies.** `provision.sh` runs as `curl | zsh` on a machine with nothing installed.
- Scripts in `.scripts/` are mode `755`.
- XDG paths only: state at `$XDG_STATE_HOME/provision/`, config at `$XDG_CONFIG_HOME`, data at `$XDG_DATA_HOME`.
- chezmoi minimum is 2.40.0 (`.chezmoiversion`); behaviour verified on 2.72.0.
- **Never add agent attribution to commits** — no `Co-authored-by`, no "Generated with", no session links.
- `docs/superpowers/runs/` and `.superpowers/` are never tracked.
- Test suites are fully mocked and must pass under either sandbox mode.

---

### Task 1: Machine allowlist and `Brewfile.tmpl`

Establishes machine identity as data, and makes the Brewfile enforce it. Self-contained: no `provision.sh` changes, and reviewable on its own.

**Files:**
- Create: `.chezmoidata/machines.toml`
- Rename + modify: `dot_config/homebrew/Brewfile` → `dot_config/homebrew/Brewfile.tmpl`
- Create: `.scripts/test-provision.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: template variable `.known_hostnames` (list of strings), available to every chezmoi template. The rendered target path is unchanged: `~/.config/homebrew/Brewfile`.

- [ ] **Step 1: Write the failing test**

Create `.scripts/test-provision.sh`:

```bash
#!/usr/bin/env bash
# Mocked test for provision.sh and the machine-identity templates. Stubs brew, chezmoi,
# op, scutil, sudo and open on PATH, records every call, and asserts stage ordering,
# allowlist enforcement, phase criticality and resume.
# Run: bash .scripts/test-provision.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0; OUT=""; RC=0

_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/    | /'; fail=$((fail + 1)); }
has()   { case "$OUT" in *"$1"*) _pass "$2" ;; *) _fail "$2" ;; esac; }
hasnt() { case "$OUT" in *"$1"*) _fail "$2" ;; *) _pass "$2" ;; esac; }
rc_is() { if [ "$RC" -eq "$1" ]; then _pass "$2"; else _fail "$2"; fi; }

# render <hostname> -> renders Brewfile.tmpl with .hostname set; sets $OUT and $RC
render() {
  local cfg; cfg=$(mktemp)
  printf '[data]\n  hostname = "%s"\n' "$1" > "$cfg"
  OUT=$(chezmoi execute-template --source "$SRC" --config "$cfg" \
          --file "$SRC/dot_config/homebrew/Brewfile.tmpl" 2>&1); RC=$?
  rm -f "$cfg"
}

echo "A. Brewfile template — allowlist guard and per-machine casks"
render fenrir
rc_is 0 "known hostname renders"
has 'cask "elgato-control-center"' "fenrir gets elgato-control-center"
has 'cask "focusrite-control"'     "fenrir gets focusrite-control"
has 'cask "jiggler"'               "fenrir gets jiggler"
has 'brew "chezmoi"'               "shared formulae present for fenrir"

render studio
rc_is 0 "second known hostname renders"
hasnt 'cask "elgato-control-center"' "studio omits elgato-control-center"
hasnt 'cask "focusrite-control"'     "studio omits focusrite-control"
hasnt 'cask "jiggler"'               "studio omits jiggler"
has   'brew "chezmoi"'               "shared formulae present for studio"

render "MacBook Pro"
rc_is 1 "unknown hostname fails the render"
has "unknown machine" "unknown hostname names the problem"
has "machines.toml"   "unknown hostname names the file to edit"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod 755 .scripts/test-provision.sh
bash .scripts/test-provision.sh
```

Expected: FAIL. `Brewfile.tmpl` does not exist, so every `render` call errors and all thirteen assertions fail.

- [ ] **Step 3: Create the allowlist**

Create `.chezmoidata/machines.toml`:

```toml
# Known machines. Adding one here is the first half of provisioning it; the second is
# a conditional in dot_config/homebrew/Brewfile.tmpl, and only if it diverges.
#
# This list is enforced twice, deliberately: .scripts/provision.sh rejects an unlisted
# name at preflight, and Brewfile.tmpl fails the render. The second guard is the one
# that catches a bare `chezmoi apply` on a machine renamed outside provisioning — a
# path provision.sh never observes.
known_hostnames = ["fenrir", "studio"]
```

- [ ] **Step 4: Convert the Brewfile to a template**

```bash
git mv dot_config/homebrew/Brewfile dot_config/homebrew/Brewfile.tmpl
```

Prepend the guard to the top of `dot_config/homebrew/Brewfile.tmpl`, above the existing comment block:

```gotemplate
{{- if not (has .hostname .known_hostnames) -}}
{{- fail (printf "unknown machine %q — add it to .chezmoidata/machines.toml" .hostname) -}}
{{- end -}}
```

Then remove these three lines from the `cask` block and re-add them behind a conditional. Delete:

```
cask "elgato-control-center"
cask "focusrite-control"
cask "jiggler"
```

Insert, immediately after `cask "docker-desktop"`:

```gotemplate
{{ if eq .hostname "fenrir" -}}
# Peripherals and laptop-only utilities. Guarded because these follow the hardware,
# not the user — see docs/superpowers/specs/2026-08-27-provisioning-preflight-design.md §5.3
cask "elgato-control-center"
cask "focusrite-control"
cask "jiggler"
{{ end -}}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash .scripts/test-provision.sh
```

Expected: `RESULT: 13 passed, 0 failed`.

- [ ] **Step 6: Verify the rendered Brewfile on this machine is unchanged in substance**

```bash
chezmoi cat ~/.config/homebrew/Brewfile | grep -c '^\(brew\|cask\|tap\) '
git show HEAD:dot_config/homebrew/Brewfile | grep -c '^\(brew\|cask\|tap\) '
```

Expected: identical counts. This machine is `fenrir` in the allowlist, so it must still receive every entry it had before. If `chezmoi cat` errors with "unknown machine", the machine's `ComputerName` has not yet been set to `fenrir` — that is expected until Task 4 runs, so pass `--config` with an explicit `hostname` as the test's `render()` helper does.

- [ ] **Step 7: Commit**

```bash
git add .chezmoidata/machines.toml dot_config/homebrew/Brewfile.tmpl .scripts/test-provision.sh
git add -u dot_config/homebrew
git commit -m "Add machine allowlist and make the Brewfile a template

Machine divergence becomes explicit: three peripheral casks move behind a
hostname conditional. The allowlist in .chezmoidata/machines.toml is enforced
inside the template as well as in provisioning, so a bare chezmoi apply on a
renamed machine fails loudly instead of silently taking the else branch."
```

---

### Task 2: Phase framework

The skeleton every later task plugs into: phase table, criticality, state, flags. No phase bodies yet — a stub phase per name, so the framework is testable before any real work is wired in.

**Files:**
- Modify: `.scripts/provision.sh` (replaces lines 1–34, the header and confirmation prompt)
- Modify: `.scripts/test-provision.sh` (add section B)

**Interfaces:**
- Consumes: `.known_hostnames` from Task 1 (not yet — Task 4 uses it).
- Produces, for every later task:
  - `run_phase <name> <criticality> <index> <total>` — dispatches to `phase_<name_with_underscores>`
  - `warn <message>` — appends to `WARNINGS` and logs
  - `state_record <phase>`, `state_completed <phase>`, `state_answer <key> <value>`, `state_get <key>`
  - Globals: `MACHINE_NAME`, `SRC_DIR`, `WARNINGS`, `DRY_RUN`, `RESUME`, `RESTART`, `ONLY_PHASE`
  - Phase functions must be named `phase_xcode_clt`, `phase_homebrew`, `phase_source_clone`, `phase_chezmoi_init`, `phase_dotfiles`, `phase_brewfile`, `phase_agent_plugins`, `phase_mise`, `phase_macos_config`, `phase_shell` and return 0 on success, non-zero on failure.

- [ ] **Step 1: Write the failing test**

Append to `.scripts/test-provision.sh`, before the `RESULT` line:

```bash
PROV="$SRC/.scripts/provision.sh"
BIN=$(mktemp -d); STATE=$(mktemp -d); CALLS="$BIN/calls.log"
trap 'rm -rf "$BIN" "$STATE"' EXIT

# Every stub records its argv, so ordering assertions read the log rather than the output.
for tool in brew chezmoi op scutil sudo open chsh git mise defaults killall; do
  cat > "$BIN/$tool" <<STUB
#!/usr/bin/env bash
echo "$tool \$*" >> "$CALLS"
case "\${MOCK_FAIL:-}" in *"$tool"*) exit 1 ;; esac
exit 0
STUB
  chmod +x "$BIN/$tool"
done

# run <stdin-answers> [args...] ; sets $OUT, $RC, and $CALLS
run() {
  local answers=$1; shift
  : > "$CALLS"; rm -rf "${STATE:?}/provision"
  OUT=$(printf '%b' "$answers" | PATH="$BIN:$PATH" XDG_STATE_HOME="$STATE" \
        MOCK_FAIL="${MOCK_FAIL:-}" zsh "$PROV" "$@" 2>&1); RC=$?
}
# before <a> <b> <label> — asserts call a is logged before call b
before() {
  local la lb
  la=$(grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1)
  lb=$(grep -n -- "$2" "$CALLS" | head -1 | cut -d: -f1)
  if [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; then _pass "$3"
  else _fail "$3 (a=${la:-missing} b=${lb:-missing})"; fi
}

echo "B. phase framework — dispatch, criticality, state, flags"
MOCK_FAIL="" run 'studio\ny\n'
rc_is 0 "clean run exits 0"
has "[1/10]"  "phases are numbered out of ten"
has "[10/10]" "the tenth phase runs"

MOCK_FAIL="" run 'studio\ny\n' --dry-run
hasnt "$(printf 'brew ')" "dry-run invokes no tools" 
has "dry-run" "dry-run says so"

echo "C. criticality"
MOCK_FAIL="chezmoi" run 'studio\ny\n'
rc_is 1 "a failing critical phase exits 1"
has "--resume" "critical failure prints the resume command"
hasnt "[10/10]" "phases after a critical failure do not run"

MOCK_FAIL="mise" run 'studio\ny\n'
rc_is 0 "a failing best-effort phase does not abort"
has "[10/10]" "phases after a best-effort failure still run"
has "mise"    "the failed best-effort phase is named in the report"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash .scripts/test-provision.sh
```

Expected: section A passes (13), section B and C fail — the current `provision.sh` has no phases, no flags, and prompts differently.

- [ ] **Step 3: Replace the head of `provision.sh`**

Replace `.scripts/provision.sh` lines 1–34 (shebang through the `while read "REPLY?Ready to provision macOS?..."` confirmation loop) with:

```zsh
#!/usr/bin/env zsh
# macOS Provision Script
# Install by running: /bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/michaelrigart/dotfiles/refs/heads/main/.scripts/provision.sh)"
#
# Four stages: bootstrap (prerequisites, no decisions), preflight (ALL human input,
# ending in one confirm), run (unattended phases), report. See
# docs/superpowers/specs/2026-08-27-provisioning-preflight-design.md
#
# NOTE: deliberately NOT `set -e`. Best-effort phases must be able to fail without
# killing the run; run_phase interprets each phase's status instead.
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info() { print -r -- "${GREEN}[INFO]${NC} $1"; }
log_warn() { print -r -- "${YELLOW}[WARN]${NC} $1"; }
log_error() { print -r -- "${RED}[ERROR]${NC} $1"; }

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
export XDG_BIN_HOME="${XDG_BIN_HOME:-${HOME}/.local/bin}"

SRC_DIR="${XDG_DATA_HOME}/chezmoi"
DOTFILES_HTTPS="https://github.com/michaelrigart/dotfiles.git"
DOTFILES_SSH="git@github.com:michaelrigart/dotfiles.git"
STATE_DIR="${XDG_STATE_HOME}/provision"
STATE_FILE="${STATE_DIR}/state"

typeset -g MACHINE_NAME=""
typeset -ga WARNINGS=()
typeset -g RESUME=0 RESTART=0 DRY_RUN=0 ONLY_PHASE=""

# name:criticality, in execution order. Phases 1-3 are stage 0's work, 4-10 stage 2's;
# the numbering is continuous because the state file and --phase do not distinguish them.
typeset -ga PHASES=(
  "xcode-clt:critical"
  "homebrew:critical"
  "source-clone:critical"
  "chezmoi-init:critical"
  "dotfiles:critical"
  "brewfile:best-effort"
  "agent-plugins:best-effort"
  "mise:best-effort"
  "macos-config:best-effort"
  "shell:best-effort"
)

usage() {
  cat <<'EOF'
Usage: provision.sh [--resume] [--restart] [--phase NAME] [--dry-run]

  --resume       skip phases already recorded as complete, and re-use recorded answers
  --restart      discard recorded state and start from the first phase
  --phase NAME   run only this phase (implies --resume for the answers)
  --dry-run      print what each phase would do; run nothing, record nothing
EOF
}

while (( $# )); do
  case $1 in
    --resume)  RESUME=1 ;;
    --restart) RESTART=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --phase)   (( $# >= 2 )) || { log_error "--phase needs a name"; exit 2; }
               ONLY_PHASE=$2; RESUME=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         log_error "unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$STATE_DIR"
(( RESTART )) && rm -f "$STATE_FILE"
[[ -f $STATE_FILE ]] || : > "$STATE_FILE"

state_record()    { print -r -- "phase=$1" >> "$STATE_FILE"; }
state_completed() { grep -qxF "phase=$1" "$STATE_FILE" 2>/dev/null; }
state_answer()    { print -r -- "$1=$2" >> "$STATE_FILE"; }
state_get()       { sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | tail -1; }
warn()            { WARNINGS+=("$1"); log_warn "$1"; }

# run_phase <name> <criticality> <index> <total>
run_phase() {
  local name=$1 crit=$2 idx=$3 total=$4
  local fn="phase_${name//-/_}"

  if [[ -n $ONLY_PHASE && $ONLY_PHASE != $name ]]; then
    return 0
  fi
  if (( RESUME )) && [[ -z $ONLY_PHASE ]] && state_completed "$name"; then
    printf '[%d/%d] %-16s skipped (already done)\n' "$idx" "$total" "$name"
    return 0
  fi
  if (( DRY_RUN )); then
    printf '[%d/%d] %-16s dry-run\n' "$idx" "$total" "$name"
    return 0
  fi

  printf '[%d/%d] %-16s\n' "$idx" "$total" "$name"
  if "$fn"; then
    state_record "$name"
    return 0
  fi

  if [[ $crit == critical ]]; then
    log_error "critical phase '${name}' failed — aborting"
    log_error "fix the cause, then resume with: ${0} --resume"
    exit 1
  fi
  warn "phase '${name}' failed (best-effort) — see output above"
  return 0
}
```

- [ ] **Step 4: Add stub phase bodies and the run loop**

Append to the end of `provision.sh`, replacing everything that currently follows (the old steps 1–16 are removed here and re-added, one at a time, by Tasks 3–6):

```zsh
# --- phase stubs, replaced by Tasks 3-6 -------------------------------------
phase_xcode_clt()    { return 0; }
phase_homebrew()     { return 0; }
phase_source_clone() { return 0; }
phase_chezmoi_init() { chezmoi --version >/dev/null; }
phase_dotfiles()     { return 0; }
phase_brewfile()     { brew --version >/dev/null; }
phase_agent_plugins(){ return 0; }
phase_mise()         { mise --version >/dev/null; }
phase_macos_config() { return 0; }
phase_shell()        { return 0; }

# --- stage 2: run ------------------------------------------------------------
local -i idx=0
local total=${#PHASES}
local entry
for entry in "${PHASES[@]}"; do
  (( idx++ ))
  run_phase "${entry%%:*}" "${entry##*:}" "$idx" "$total"
done

print ""
log_info "✓ macOS provision complete"
```

- [ ] **Step 5: Run the tests to verify B and C pass**

```bash
bash .scripts/test-provision.sh
```

Expected: sections A, B and C green. Section C's `MOCK_FAIL="chezmoi"` case exercises a critical failure through `phase_chezmoi_init`'s `chezmoi --version`; `MOCK_FAIL="mise"` exercises a best-effort failure through `phase_mise`.

- [ ] **Step 6: Commit**

```bash
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Add phase framework to provision.sh

Ten named phases, each critical or best-effort, dispatched through run_phase.
Completed phases are recorded under XDG_STATE_HOME so --resume skips them;
--restart, --phase and --dry-run round out the surface.

set -e is removed deliberately: best-effort phases cannot exist under it."
```

---

### Task 3: Stage 0 — bootstrap phases

Fills in the three phases that must run before anyone can be asked anything.

**Files:**
- Modify: `.scripts/provision.sh` (replace the `phase_xcode_clt`, `phase_homebrew`, `phase_source_clone` stubs)
- Modify: `.scripts/test-provision.sh` (add section D)

**Interfaces:**
- Consumes: `warn`, `log_*`, `SRC_DIR`, `DOTFILES_HTTPS` from Task 2.
- Produces: `HOMEBREW_PREFIX` exported for later phases; `$SRC_DIR` populated, which Task 4's allowlist read depends on.

- [ ] **Step 1: Write the failing test**

Append section D to `.scripts/test-provision.sh`:

```bash
echo "D. stage 0 — bootstrap ordering"
MOCK_FAIL="" run 'studio\ny\n'
before "brew install chezmoi" "git clone"      "chezmoi is installed before the source is cloned"
before "git clone"            "scutil --set"   "the source is cloned before preflight sets the hostname"
has "git clone" "the source is cloned with git, not chezmoi init"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash .scripts/test-provision.sh
```

Expected: section D fails — the stubs make no `brew` or `git` calls.

- [ ] **Step 3: Implement the three phases**

Replace the three stubs in `provision.sh`:

```zsh
phase_xcode_clt() {
  if xcode-select -p &>/dev/null; then
    log_info "✓ Xcode Command Line Tools already installed"
    return 0
  fi
  log_info "Installing Xcode Command Line Tools — complete the dialog that just opened"
  xcode-select --install 2>/dev/null
  local -i waited=0
  until xcode-select -p &>/dev/null; do
    (( waited >= 1800 )) && { log_error "timed out after 30m waiting for Xcode CLT"; return 1; }
    sleep 5; (( waited += 5 ))
    (( waited % 60 == 0 )) && log_info "  still waiting for Xcode CLT (${waited}s)"
  done
  log_info "✓ Xcode Command Line Tools installed"
}

phase_homebrew() {
  if ! command -v brew &>/dev/null; then
    log_info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
  else
    log_info "✓ Homebrew already installed"
    brew update || warn "brew update failed — continuing with the current index"
  fi
  eval "$(/opt/homebrew/bin/brew shellenv)"
  export HOMEBREW_PREFIX=$(brew --prefix)

  log_info "Installing bootstrap tools..."
  brew install chezmoi 1password-cli git || return 1
  # The 1Password gate in preflight needs the desktop app, so it is bootstrap work,
  # not Brewfile work. Installing it twice is harmless and idempotent.
  brew install --cask 1password || return 1
}

phase_source_clone() {
  if [[ -d $SRC_DIR/.git ]]; then
    log_info "✓ dotfiles source already present at ${SRC_DIR}"
    return 0
  fi
  # A plain clone, NOT `chezmoi init` — preflight needs .chezmoidata/machines.toml
  # present, but the config must not be rendered until the hostname is set.
  log_info "Cloning dotfiles source..."
  git clone "$DOTFILES_HTTPS" "$SRC_DIR" || return 1
}
```

- [ ] **Step 4: Run the tests to verify D passes**

```bash
bash .scripts/test-provision.sh
```

Expected: A–D green.

- [ ] **Step 5: Commit**

```bash
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Implement stage 0 bootstrap phases

Xcode CLT now polls until the dialog is satisfied instead of exiting 0 and
asking to be re-run. The dotfiles source is cloned with plain git rather than
chezmoi init, so preflight can read the machine allowlist before the hostname
is set and the config is rendered."
```

---

### Task 4: Stage 1 — preflight

All human input, in one place, ending in one confirm.

**Files:**
- Modify: `.scripts/provision.sh` (insert the preflight block between the phase definitions and the run loop)
- Modify: `.scripts/test-provision.sh` (add sections E and F)

**Interfaces:**
- Consumes: `state_answer`, `state_get`, `SRC_DIR`, `MACHINE_NAME` from Task 2; `$SRC_DIR` populated by Task 3.
- Produces: `MACHINE_NAME` set and applied via `scutil`; sudo credential held; `machine_name` recorded in state.

- [ ] **Step 1: Write the failing test**

Append sections E and F to `.scripts/test-provision.sh`:

```bash
echo "E. preflight — allowlist and ordering"
MOCK_FAIL="" run 'studio\ny\n'
before "scutil --set ComputerName" "chezmoi init" "the hostname is set BEFORE chezmoi init"
has "scutil --set ComputerName studio"  "ComputerName is set to the chosen name"
has "scutil --set HostName studio"      "HostName is set — Borg identity depends on it"
has "scutil --set LocalHostName studio" "LocalHostName is set"

MOCK_FAIL="" run 'nosuchmachine\nstudio\ny\n'
rc_is 0 "an unknown name is re-prompted, not fatal"
has "machines.toml" "rejection names the file to edit"
hasnt "scutil --set ComputerName nosuchmachine" "the rejected name is never applied"

echo "F. preflight — confirm gate and resume"
MOCK_FAIL="" run 'studio\nn\n'
rc_is 1 "declining the confirm aborts"
hasnt "[1/10]" "no phase runs when the confirm is declined"
hasnt "scutil --set" "nothing is mutated when the confirm is declined"

# --resume re-uses the recorded answer instead of asking again
MOCK_FAIL="" run 'studio\ny\n'
OUT=$(printf '' | PATH="$BIN:$PATH" XDG_STATE_HOME="$STATE" zsh "$PROV" --resume 2>&1); RC=$?
rc_is 0 "--resume completes with no answers on stdin"
has "studio" "--resume re-uses the recorded machine name"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash .scripts/test-provision.sh
```

Expected: E and F fail — there is no preflight yet, so nothing prompts and `scutil` is never called.

- [ ] **Step 3: Implement preflight**

Insert into `provision.sh`, after the phase function definitions and before the run loop:

```zsh
# --- stage 1: preflight ------------------------------------------------------
# Everything that can ask a question lives here. Nothing after the confirm prompts.

known_hostnames() {
  # A deliberately small parser: the file holds one flat array and nothing else.
  sed -n 's/^known_hostnames *= *\[\(.*\)\]/\1/p' "$SRC_DIR/.chezmoidata/machines.toml" 2>/dev/null \
    | tr -d '" ' | tr ',' '\n' | grep -v '^$'
}

preflight_1password() {
  if op whoami &>/dev/null; then
    log_info "✓ 1Password CLI already authenticated"
    return 0
  fi
  open -a "1Password" 2>/dev/null
  print ""
  print "  Do this now, in the 1Password app:"
  print "    1. Sign in to your account"
  print "    2. Settings → Developer → ☑ Integrate with 1Password CLI"
  print ""
  local -i waited=0
  until op whoami &>/dev/null; do
    (( waited >= 900 )) && { log_error "timed out after 15m waiting for the 1Password CLI"; return 1; }
    sleep 3; (( waited += 3 ))
  done
  log_info "✓ 1Password CLI authenticated"
}

preflight_machine_name() {
  local recorded
  recorded=$(state_get machine_name)
  if [[ -n $recorded ]]; then
    MACHINE_NAME=$recorded
    log_info "✓ machine name (recorded): ${MACHINE_NAME}"
    return 0
  fi

  local -a allowed
  allowed=(${(f)"$(known_hostnames)"})
  if (( ${#allowed} == 0 )); then
    log_error "no known_hostnames found in ${SRC_DIR}/.chezmoidata/machines.toml"
    return 1
  fi

  local name
  while true; do
    print -n "  Machine name (${(j:, :)allowed}): "
    read -r name || return 1
    if (( ${allowed[(Ie)$name]} )); then
      MACHINE_NAME=$name
      state_answer machine_name "$name"
      return 0
    fi
    log_warn "unknown machine '${name}' — add it to .chezmoidata/machines.toml first"
  done
}

preflight_sudo_and_hostname() {
  sudo -v || return 1
  # Keep the credential alive for the whole unattended run.
  while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

  # Ordering is load-bearing: this must happen before phase_chezmoi_init, which
  # captures the name into chezmoi's [data]. HostName in particular is what Borg's
  # {hostname} resolves to — see the design doc §11.1. Never make this best-effort.
  local n=$MACHINE_NAME
  [[ $(scutil --get ComputerName 2>/dev/null)  == "$n" ]] || sudo scutil --set ComputerName  "$n" || return 1
  [[ $(scutil --get HostName 2>/dev/null)      == "$n" ]] || sudo scutil --set HostName      "$n" || return 1
  [[ $(scutil --get LocalHostName 2>/dev/null) == "$n" ]] || sudo scutil --set LocalHostName "$n" || return 1
  log_info "✓ hostname set to ${n}"
}

preflight_confirm() {
  print ""
  print "══ Provision: ${MACHINE_NAME} ══════════════════════"
  printf '  Machine name ....... %s\n' "$MACHINE_NAME"
  printf '  Dotfiles source .... %s\n' "$SRC_DIR"
  printf '  1Password .......... authenticated\n'
  printf '  Phases ............. %d\n' "${#PHASES}"
  print "────────────────────────────────────────────────────"
  local reply
  print -n "  Proceed? [y/N] "
  read -r reply || return 1
  [[ $reply == (y|Y) ]]
}

# Bootstrap phases must complete before preflight can ask anything.
local -i idx=0
local total=${#PHASES}
local entry
for entry in "${PHASES[@]:0:3}"; do
  (( idx++ ))
  run_phase "${entry%%:*}" "${entry##*:}" "$idx" "$total"
done

if [[ -z $ONLY_PHASE ]] && (( ! DRY_RUN )); then
  preflight_1password        || { log_error "1Password gate failed"; exit 1; }
  preflight_machine_name     || { log_error "could not determine machine name"; exit 1; }
  preflight_sudo_and_hostname|| { log_error "could not set the hostname"; exit 1; }
  if ! preflight_confirm; then
    log_warn "Aborted before any phase ran."
    exit 1
  fi
fi
```

**Then delete the counter declarations and run loop Task 2 added at the end of the
file** — `local -i idx=0`, `local total=${#PHASES}`, `local entry`, and the
`for entry in "${PHASES[@]}"` loop. The preflight block above already declares all
three and runs the first three phases; leaving Task 2's copies in place would reset
`idx` to 0 and renumber phases 4–10 as 1–7.

Replace them with a loop over only the remaining phases:

```zsh
# --- stage 2: run ------------------------------------------------------------
for entry in "${PHASES[@]:3}"; do
  (( idx++ ))
  run_phase "${entry%%:*}" "${entry##*:}" "$idx" "$total"
done
```

Verify the numbering survived before moving on:

```bash
printf 'studio\ny\n' | zsh .scripts/provision.sh --dry-run | grep -o '\[[0-9]*/10\]' | tr '\n' ' '
```

Expected: `[1/10] [2/10] [3/10] [4/10] [5/10] [6/10] [7/10] [8/10] [9/10] [10/10]` — a
second run of `[1/10]` means the duplicate declaration is still there.

- [ ] **Step 4: Run the tests to verify E and F pass**

```bash
bash .scripts/test-provision.sh
```

Expected: A–F green. Assertion "the hostname is set BEFORE chezmoi init" is the one this whole plan exists to protect — if it fails, the ordering is wrong and no other green matters.

- [ ] **Step 5: Commit**

```bash
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Add preflight stage to provision.sh

All human input moves ahead of the unattended run: the 1Password gate polls
op whoami rather than assuming a configured account, the machine name is
validated against the allowlist, and sudo is acquired once and held.

The hostname is applied before chezmoi init captures it. Borg's {hostname}
resolves through HostName, so this ordering is load-bearing for backups."
```

---

### Task 5: Stage 2 — critical phases

`chezmoi-init` and `dotfiles`, lifted from the current steps 5–7.

**Files:**
- Modify: `.scripts/provision.sh` (replace the `phase_chezmoi_init` and `phase_dotfiles` stubs)
- Modify: `.scripts/test-provision.sh` (add section G)

**Interfaces:**
- Consumes: `MACHINE_NAME` (already applied to the system), `SRC_DIR`, `DOTFILES_SSH`.
- Produces: `~/.config/chezmoi/chezmoi.toml` with correct `[data]`; a fully applied `$HOME`.

- [ ] **Step 1: Write the failing test**

Append section G:

```bash
echo "G. critical phases — init, apply, SSH remote"
MOCK_FAIL="" run 'studio\ny\n'
has "chezmoi init"          "chezmoi init runs"
has "chezmoi apply"         "chezmoi apply runs"
before "chezmoi init" "chezmoi apply" "init precedes apply"
has "git remote set-url"    "the source remote is switched to SSH"
before "chezmoi apply" "git remote set-url" "the remote switch follows the apply that renders the key"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash .scripts/test-provision.sh
```

Expected: G fails — `phase_chezmoi_init` only calls `chezmoi --version`, and `phase_dotfiles` is a no-op.

- [ ] **Step 3: Implement the two phases**

Replace the stubs (this folds in the current script's steps 5, 6 and 7 at lines 84–124):

```zsh
phase_chezmoi_init() {
  # The source is already cloned by phase_source_clone; init's job here is solely to
  # render ~/.config/chezmoi/chezmoi.toml from the source-root .chezmoi.toml.tmpl.
  # It reads `scutil --get ComputerName`, which preflight has already set.
  log_info "Generating chezmoi config for ${MACHINE_NAME}..."
  chezmoi init || return 1

  local got
  got=$(chezmoi execute-template '{{ .hostname }}' 2>/dev/null)
  if [[ $got != $MACHINE_NAME ]]; then
    log_error "chezmoi resolved hostname '${got}', expected '${MACHINE_NAME}'"
    return 1
  fi
  log_info "✓ chezmoi config generated (hostname=${got})"
}

phase_dotfiles() {
  log_info "Applying dotfiles..."
  chezmoi apply --force || return 1

  if [[ -d ${HOME}/.ssh ]]; then
    chmod 700 "${HOME}/.ssh"
    find "${HOME}/.ssh" -type f ! -name "*.pub" ! -name "config" -exec chmod 600 {} \; 2>/dev/null
  fi

  # Only now does an SSH key exist to authenticate with.
  log_info "Switching the dotfiles remote to SSH..."
  git -C "$SRC_DIR" remote set-url origin "$DOTFILES_SSH" || return 1
  if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    log_info "✓ SSH connection to GitHub verified"
  else
    warn "SSH connection to GitHub not confirmed — check ~/.ssh/michael"
  fi
}
```

- [ ] **Step 4: Run the tests to verify G passes**

```bash
bash .scripts/test-provision.sh
```

Expected: A–G green.

- [ ] **Step 5: Commit**

```bash
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Implement the critical dotfiles phases

chezmoi init now only renders the config, since the source is already cloned,
and asserts the hostname it resolved matches the one preflight set. The apply
phase keeps SSH permissions and the HTTPS-to-SSH remote switch together, since
the switch only works once the apply has rendered the key."
```

---

### Task 6: Stage 2 — best-effort phases

The five phases that must not abort the run.

**Files:**
- Modify: `.scripts/provision.sh` (replace the remaining five stubs)
- Modify: `.scripts/test-provision.sh` (add section H)

**Interfaces:**
- Consumes: `warn`, `HOMEBREW_PREFIX`, `SRC_DIR`, `XDG_*`.
- Produces: entries in `WARNINGS` for anything a human still has to do.

- [ ] **Step 1: Write the failing test**

Append section H:

```bash
echo "H. best-effort phases"
MOCK_FAIL="" run 'studio\ny\n'
has "brew trust --tap"      "third-party taps are trusted before bundling"
before "brew trust --tap" "brew bundle" "taps are trusted before the bundle runs"
has "brew bundle"           "the Brewfile is installed"
has "mise install"          "mise tools are installed"
has "sudo chsh"             "chsh is routed through the cached sudo credential"
hasnt "$(printf '\nchsh -s')" "bare chsh is never called"

MOCK_FAIL="mise" run 'studio\ny\n'
rc_is 0 "a mise failure does not abort the run"
has "Done, with"  "the report renders after a best-effort failure"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash .scripts/test-provision.sh
```

Expected: H fails — the stubs call no `brew bundle`, no `chsh`.

- [ ] **Step 3: Implement the five phases**

Replace the remaining stubs (folding in current steps 8–15, lines 126–222):

```zsh
phase_brewfile() {
  local bf="${XDG_CONFIG_HOME}/homebrew/Brewfile"
  [[ -f $bf ]] || { log_error "Brewfile not found at ${bf}"; return 1; }
  export HOMEBREW_BUNDLE_FILE="$bf"

  # Homebrew refuses formulae/casks from untrusted third-party taps, which aborts
  # `brew bundle` on a fresh machine. Declaring a tap in the Brewfile IS the decision
  # to trust it. Idempotent.
  local tap
  for tap in ${(f)"$(sed -n 's/^tap "\([^"]*\)".*/\1/p' "$bf")"}; do
    brew trust --tap "$tap" || warn "could not trust tap ${tap}"
  done

  brew bundle install --file "$bf" && return 0

  # `brew bundle` exits non-zero for the whole file, which by itself says nothing
  # useful. `check --verbose` names each missing item on its own `→ ` line.
  local item
  for item in ${(f)"$(brew bundle check --verbose --file "$bf" 2>/dev/null | sed -n 's/^→ *//p')"}; do
    warn "brewfile: ${item}"
  done
  return 1
}

phase_agent_plugins() {
  local script="${SRC_DIR}/.scripts/reconcile-agents.sh"
  [[ -x $script ]] || { warn "reconcile-agents.sh not found — agent plugins unconfigured"; return 1; }
  "$script" || return 1
}

phase_mise() {
  command -v mise &>/dev/null || { warn "mise not installed — dev toolchains unconfigured"; return 1; }
  mise install || return 1
}

phase_macos_config() {
  local script="${SRC_DIR}/.scripts/configure.sh"
  [[ -x $script ]] || { warn "configure.sh not found — macOS settings unapplied"; return 1; }
  # --hostname suppresses configure.sh's own prompt: preflight already owns the name.
  "$script" --hostname "$MACHINE_NAME" --as-phase || return 1
}

phase_shell() {
  local target="${HOMEBREW_PREFIX}/bin/zsh"
  if [[ $SHELL == $target ]]; then
    log_info "✓ shell already ${target}"
  else
    if ! grep -qxF "$target" /etc/shells; then
      print -r -- "$target" | sudo tee -a /etc/shells >/dev/null || return 1
    fi
    # sudo chsh, not bare chsh: bare chsh prompts for the user's password mid-run,
    # while sudo reuses the credential preflight already cached.
    sudo chsh -s "$target" "$USER" || return 1
  fi

  if [[ -d ${XDG_DATA_HOME}/oh-my-zsh ]]; then
    git -C "${XDG_DATA_HOME}/oh-my-zsh" pull --quiet || warn "oh-my-zsh update failed"
  else
    ZSH="${XDG_DATA_HOME}/oh-my-zsh" sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended \
      || return 1
  fi

  mkdir -p "${XDG_CACHE_HOME}"/{zsh,irb} "${XDG_CACHE_HOME}"/bundler/{cache,plugin} "${XDG_CACHE_HOME}/gem/specs"
  rm -f "${HOME}/.zprofile" "${HOME}/.zprofile.bak" \
        "${HOME}/.zshrc.pre-oh-my-zsh" "${HOME}/.shell.pre-oh-my-zsh"
  brew cleanup || warn "brew cleanup failed"
}
```

- [ ] **Step 4: Run the tests to verify H passes**

```bash
bash .scripts/test-provision.sh
```

Expected: A–H green, except the two `Done, with` assertions, which Task 7 satisfies.

- [ ] **Step 5: Commit**

```bash
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Implement the best-effort phases

Each of the five can fail without ending the run. The Brewfile phase re-runs
brew bundle check --verbose on failure so the report names the specific missing
casks rather than saying the bundle failed.

chsh now goes through the cached sudo credential instead of prompting."
```

---

### Task 7: Stage 3 — report

**Files:**
- Modify: `.scripts/provision.sh` (replace the closing `log_info "✓ macOS provision complete"`)
- Modify: `.scripts/test-provision.sh` (add section I)

**Interfaces:**
- Consumes: `WARNINGS`, `MACHINE_NAME`, `STATE_FILE`.
- Produces: process exit status 0 whether or not warnings accumulated — warnings are not failures.

- [ ] **Step 1: Write the failing test**

Append section I:

```bash
echo "I. report"
MOCK_FAIL="" run 'studio\ny\n'
has "provision complete" "a clean run says so"
hasnt "Done, with"       "a clean run shows no warning block"

MOCK_FAIL="mise" run 'studio\ny\n'
has "Done, with"            "a run with warnings shows the warning block"
has "mise"                  "the failing phase is named"
has "--phase mise"          "the report gives a per-phase retry command"
rc_is 0                     "warnings do not change the exit status"
has "1Password"             "the report lists the manual follow-ups"
has "Borg"                  "the report lists Borg setup as outstanding"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash .scripts/test-provision.sh
```

Expected: section I fails — there is no report block yet.

- [ ] **Step 3: Implement the report**

Replace the closing lines of `provision.sh`:

```zsh
# --- stage 3: report ---------------------------------------------------------
print ""
if (( ${#WARNINGS} )); then
  print "══ Done, with ${#WARNINGS} item(s) needing you ══════"
  local w
  for w in "${WARNINGS[@]}"; do
    print "  ⚠ ${w}"
  done
  print ""
  print "  Retry a single phase with:"
  local entry name
  for entry in "${PHASES[@]}"; do
    name="${entry%%:*}"
    state_completed "$name" || print "    ${0} --phase ${name}"
  done
  print ""
else
  log_info "✓ macOS provision complete — no warnings"
fi

print "══ Still manual ════════════════════════════════════"
print "  • Little Snitch: import your rule set, or expect prompts for every"
print "    ad-hoc-signed Homebrew binary (tsh, gh, …)"
print "  • Borg: create this machine's own BorgBase repo and keypair, store the"
print "    passphrase in 1Password, then configure Vorta. Archive naming must use"
print "    the literal name '${MACHINE_NAME}', not {hostname}."
print "  • Alfred: System Settings → Privacy & Security → Accessibility → add"
print "    Alfred, then re-run .scripts/configure.sh so snippets auto-expand."
print "    Verify with: bash .scripts/test-alfred-relay.sh"
print "  • FileVault: System Settings → Privacy & Security"
print "  • Sign in: 1Password already done; Slack, Teams, Notion, Obsidian,"
print "    Proton, Spotify, Docker Desktop, Office"
print "  • Unmanaged state to restore: ~/.kube, ~/.aws, ~/.azure, ~/Code"
print ""
log_info "Restart your terminal, or run: exec ${HOMEBREW_PREFIX:-/opt/homebrew}/bin/zsh"
```

- [ ] **Step 4: Run the tests to verify I passes**

```bash
bash .scripts/test-provision.sh
```

Expected: A–I all green.

- [ ] **Step 5: Commit**

```bash
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Add the provisioning report stage

Accumulated warnings print with a per-phase retry command, followed by the
manual follow-ups that cannot be scripted. Warnings never change the exit
status; they are work for a human, not failures of the run."
```

---

### Task 8: `configure.sh` integration

**Files:**
- Modify: `.scripts/configure.sh:22-46` (sudo, hostname block), `:144-150` (trackpad), `:227` (battery), `:319-327` (trailer)
- Modify: `.scripts/test-provision.sh` (add section J)

**Interfaces:**
- Consumes: `--hostname <name>` and `--as-phase` from `phase_macos_config`.
- Produces: unchanged standalone behaviour when invoked with no flags.

- [ ] **Step 1: Write the failing test**

Append section J:

```bash
echo "J. configure.sh flags"
CONF="$SRC/.scripts/configure.sh"
OUT=$(PATH="$BIN:$PATH" zsh "$CONF" --hostname studio --as-phase 2>&1); RC=$?
rc_is 0 "runs non-interactively with --hostname"
hasnt "is this correct" "--hostname suppresses the prompt"
hasnt "Manual tasks still required" "--as-phase suppresses the standalone trailer"

OUT=$(PATH="$BIN:$PATH" zsh "$CONF" --hostname fenrir --as-phase 2>&1); RC=$?
has "TrackpadThreeFingerDrag" "fenrir applies the trackpad defaults"

OUT=$(PATH="$BIN:$PATH" zsh "$CONF" --hostname studio --as-phase 2>&1); RC=$?
hasnt "TrackpadThreeFingerDrag" "studio skips the trackpad defaults"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash .scripts/test-provision.sh
```

Expected: J fails — `configure.sh` accepts no flags and prompts unconditionally.

- [ ] **Step 3: Add flag parsing and replace the hostname block**

Replace `.scripts/configure.sh` lines 22–46 with:

```zsh
HOSTNAME_ARG="" AS_PHASE=0
while (( $# )); do
  case $1 in
    --hostname) (( $# >= 2 )) || { log_error "--hostname needs a name"; exit 2; }
                HOSTNAME_ARG=$2; shift ;;
    --as-phase) AS_PHASE=1 ;;
    *) log_error "unknown option: $1"; exit 2 ;;
  esac
  shift
done

sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# ============================================================================
# Set Hostname
# ============================================================================
# When driven by provision.sh the name is already chosen AND already applied in
# preflight, so this block only reconciles. Standalone, it prompts as before.
if [[ -n $HOSTNAME_ARG ]]; then
  HOSTNAME=$HOSTNAME_ARG
else
  while true; do
    print -n "Enter the hostname for this machine: "
    read HOSTNAME
    print -n "You have entered $HOSTNAME, is this correct (y/n)? "
    read answer
    [[ $answer == (y|Y) ]] && break
  done
fi

log_info "Setting hostname to $HOSTNAME..."
[[ $(scutil --get ComputerName 2>/dev/null)  == "$HOSTNAME" ]] || sudo scutil --set ComputerName  "$HOSTNAME"
[[ $(scutil --get HostName 2>/dev/null)      == "$HOSTNAME" ]] || sudo scutil --set HostName      "$HOSTNAME"
[[ $(scutil --get LocalHostName 2>/dev/null) == "$HOSTNAME" ]] || sudo scutil --set LocalHostName "$HOSTNAME"
log_info "✓ Hostname set to $HOSTNAME"
```

Note the comparison change: the original used `scutil --get ComputerName | grep -q "$HOSTNAME"`, a substring match that would treat `studio` as already-set on a machine named `studio-2`. Exact comparison is correct.

- [ ] **Step 4: Guard the hardware-specific defaults**

Wrap `.scripts/configure.sh` lines 144–150 (trackpad) and line 227 (battery):

```zsh
if [[ $HOSTNAME == fenrir ]]; then
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
  defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool true
  defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool true
  log_info "✓ Trackpad configured"
else
  log_info "✓ Trackpad settings skipped (no built-in trackpad on ${HOSTNAME})"
fi
```

```zsh
if [[ $HOSTNAME == fenrir ]]; then
  defaults write com.apple.menuextra.battery ShowPercent -string "YES"
fi
```

- [ ] **Step 5: Suppress the standalone trailer under `--as-phase`**

Wrap `.scripts/configure.sh` lines 319–327:

```zsh
if (( ! AS_PHASE )); then
  log_warn "Manual tasks still required:"
  log_warn "  1. Configure Spotlight privacy settings (System Settings > Siri & Spotlight)"
  log_warn "  2. Review Privacy & Security settings (System Settings > Privacy & Security)"
  log_warn "  3. Configure Little Snitch rules"
  log_warn "  4. Sign in to applications (1Password, browsers, etc.)"
  log_warn "  5. Some settings may require a logout/restart to take full effect"
  log_info "Consider restarting your Mac to ensure all settings are applied."
fi
```

- [ ] **Step 6: Run the tests to verify J passes**

```bash
bash .scripts/test-provision.sh
```

Expected: A–J all green.

- [ ] **Step 7: Commit**

```bash
git add .scripts/configure.sh .scripts/test-provision.sh
git commit -m "Teach configure.sh --hostname and --as-phase

Provisioning already owns the machine name, so configure.sh stops prompting when
driven as a phase and only reconciles. Standalone behaviour is unchanged.

The hostname comparison becomes exact: the old grep -q substring match would
treat 'studio' as already set on a machine named 'studio-2'.

Trackpad and battery defaults are guarded — they are no-ops on a desktop, but
under a design that models divergence explicitly, unguarded is inconsistent."
```

---

### Task 9: Documentation and baseline

**Files:**
- Modify: `README.md` (Quick Start, repository structure)
- Modify: `CLAUDE.md` (file structure, common operations)
- Modify: `docs/superpowers/specs/2026-08-27-provisioning-preflight-design.md` (status line)

**Interfaces:**
- Consumes: the finished implementation.
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Run the full suite and record the totals**

```bash
for f in .scripts/test-*.sh; do
  case "$f" in
    *test-live-*) continue ;;
    *test-wt-functions.sh) echo "== $f (zsh)"; zsh "$f" | tail -2 ;;
    *) echo "== $f"; bash "$f" | tail -2 ;;
  esac
done
```

Note `test-reconcile-agents.sh` and `test-ssh-credential-inventory.sh` must run **unsandboxed** — sandboxed they report false failures. Report totals as `passed/total`, never "N green".

- [ ] **Step 2: Update `README.md`**

In the structure block, change `│   ├── homebrew/         # Brewfile` to `│   ├── homebrew/         # Brewfile.tmpl (hostname-conditional)`, and add `├── .chezmoidata/          # Machine allowlist` above `├── .chezmoiignore`.

Replace the "This will:" list under Quick Start with:

```markdown
This runs four stages:

1. **Bootstrap** — Xcode CLT, Homebrew, chezmoi, 1Password, clone the dotfiles
2. **Preflight** — the only stage that asks you anything: 1Password sign-in,
   machine name, sudo, then one confirmation
3. **Run** — ten unattended phases (dotfiles, Brewfile, agent plugins, mise,
   macOS settings, shell)
4. **Report** — what failed, how to retry it, and what still needs you

Interrupted or partially failed runs resume with `provision.sh --resume`.
```

- [ ] **Step 3: Update `CLAUDE.md`**

In the file structure block add, under `.scripts/`:

```
│   └── test-provision.sh     # mocked test for provision.sh + machine templates
```

and above `├── .chezmoi.toml.tmpl`:

```
├── .chezmoidata/             # Machine allowlist (known_hostnames)
```

Add to "Common Operations":

````markdown
### Adding a Machine

```bash
# 1. Add the name to the allowlist
chezmoi edit ~/.local/share/chezmoi/.chezmoidata/machines.toml

# 2. Only if it diverges, add a conditional
chezmoi edit ~/.config/homebrew/Brewfile

# 3. Provision it
/bin/zsh -c "$(curl -fsSL .../provision.sh)"
```

An unlisted machine fails the Brewfile render by design — never add an `else`
branch to work around it.
````

- [ ] **Step 4: Mark the spec implemented**

Change the spec's status line to `**Status:** Implemented` and cite the MR, per the design-records policy's final pre-merge commit.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md docs/superpowers/specs/2026-08-27-provisioning-preflight-design.md
git commit -m "Document the provisioning stages and machine allowlist

Marks the provisioning preflight design Implemented."
```

---

## Self-Review

**Spec coverage.** §4.1 → Task 3. §4.2 → Task 4. §4.3 → Tasks 5–6. §4.4 → Task 7. §5.1 (ordering) → Task 4 step 1, assertion "the hostname is set BEFORE chezmoi init". §5.2 (two-layer allowlist) → Task 1 (template layer) and Task 4 (preflight layer). §5.3 → Task 1. §6.1 → Task 2. §6.2 → Task 6. §6.3 → Task 2. §7 → Task 8. §8 → distributed across every task's test step. §11.1 (`HostName` non-downgradable) → Task 4, `preflight_sudo_and_hostname` returns non-zero on failure and preflight aborts. §11.4 (no Vorta automation) → Task 7's report lists Borg as manual.

**Known gaps, deliberately out of scope.** §11.3 (the two unmanaged Borg keys) is recorded in the spec as follow-up and has no task here — closing it means putting key material into 1Password and adding templates, which is credential work, not provisioning work. The live Vorta `{hostname}` → literal-name change is likewise a separate, separately-confirmed action on the existing machine.

**Idioms verified during authoring** (chezmoi v2.72.0, zsh 5.9), so an executor need
not re-derive them: `.chezmoidata/machines.toml` loads as `.known_hostnames`;
`fail` aborts a render with exit 1 and the message reaches stderr; the `render()`
helper's `--source`/`--config`/`--file` combination renders `Brewfile.tmpl` in
isolation (fenrir includes the guarded casks, studio omits them, an unlisted name
exits 1); `${allowed[(Ie)$name]}` is an exact-match allowlist test; `${P[@]:0:3}`
and `${P[@]:3}` slice correctly; `local` is legal at zsh script top level;
`brew bundle check --verbose` prefixes each missing item with `→ `.

**Type consistency.** Phase function names are `phase_<name with hyphens replaced by underscores>` throughout; `run_phase` derives them with `${name//-/_}`. `warn` is defined in Task 2 and used in Tasks 3, 5, 6. `state_get`/`state_answer` use the key `machine_name` in both Task 2's definition and Task 4's use. `MACHINE_NAME` is set in Task 4 and read in Tasks 5, 6, 7.
