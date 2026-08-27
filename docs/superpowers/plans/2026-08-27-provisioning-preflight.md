# Provisioning Preflight Implementation Plan

**Status:** Approved
**Date:** 2026-08-27

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This plan is executed once.** Move both this plan and its spec to `**Status:** In progress` in the first execution commit, and to `**Status:** Implemented` citing the MR in the final pre-merge commit. Do not re-run it afterwards.

**Goal:** Restructure `.scripts/provision.sh` so every decision is made before the unattended work starts, and make machine identity a validated, live-read concept.

**Architecture:** Four stages — bootstrap (prerequisites, one macOS dialog), preflight (all decisions, ending in one confirm that gates identity mutation), run (seven unattended phases), report. Ten phases total, each critical or best-effort. A state file carries three consent markers — `answers_collected`, `confirmed`, `identity_applied` — that define every resume, phase and repair transition. Identity is read live from `scutil` at template-render time, never from stored chezmoi data.

**Tech Stack:** zsh (provision.sh, configure.sh), bash 3.2 (test suites), chezmoi v2.72.0 templates + `.chezmoidata` + `.chezmoitemplates`, Homebrew Bundle.

**Spec:** `docs/superpowers/specs/2026-08-27-provisioning-preflight-design.md`

## Global Constraints

- `provision.sh` and `configure.sh` are **zsh**. Test suites are **bash, 3.2-compatible** (macOS `/bin/bash`): no associative arrays, no `mapfile`, no `${x,,}`.
- **`set -e` is removed from `provision.sh`.** Best-effort phases cannot exist under it; `run_phase` interprets each phase's status.
- **No new Homebrew dependencies.** `provision.sh` runs as `curl | zsh` on a bare machine.
- **Identity is read live.** No template, conditional, or guard may key off stored `.hostname` for a decision. `.hostname` appears only as the *stored* half of a drift comparison.
- **Identity mutation requires consent, in every mode.** `scutil --set` happens in exactly two places: preflight step 5 and `--repair-identity`, both after an explicit `y`.
- Scripts in `.scripts/` are mode `755`. XDG paths only; state at `$XDG_STATE_HOME/provision/`.
- **Never add agent attribution to commits.**
- `docs/superpowers/runs/` and `.superpowers/` are never tracked.
- **Every commit leaves the tests green.** Do not add an assertion for behaviour a later task delivers.

## Execution preconditions

Before the first task, and again before anything runs `scutil --set`:

```bash
scutil --get ComputerName; scutil --get HostName; scutil --get LocalHostName; hostname
```

Two agents disagreed about this machine's identity during design review. Confirm the real values in a human terminal and reconcile them with `.chezmoidata/machines.toml` before executing Task 5 or later. This is a gate, not a suggestion.

---

### Task 1: Machine allowlist and identity partial

**Files:**
- Create: `.chezmoidata/machines.toml`, `.chezmoitemplates/identity-guard`
- Rename + modify: `dot_config/homebrew/Brewfile` → `Brewfile.tmpl`
- Create: `.scripts/test-provision.sh`

**Interfaces:**
- Produces: `.known_hostnames` (list of strings) in template data; the `identity-guard` partial, invoked as `{{ template "identity-guard" (dict "live" $live "stored" .hostname "known" .known_hostnames) }}`. Callers bind `$live` themselves — a Go partial cannot export a variable to its caller's scope.

- [ ] **Step 1: Write the failing test**

Create `.scripts/test-provision.sh`:

```bash
#!/usr/bin/env bash
# Mocked test for provision.sh and the machine-identity templates.
# Run: bash .scripts/test-provision.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0; OUT=""; RC=0

_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '%s\n' "$OUT" | sed 's/^/    | /'; fail=$((fail + 1)); }
has()   { case "$OUT" in *"$1"*) _pass "$2" ;; *) _fail "$2" ;; esac; }
hasnt() { case "$OUT" in *"$1"*) _fail "$2" ;; *) _pass "$2" ;; esac; }
rc_is() { if [ "$RC" -eq "$1" ]; then _pass "$2"; else _fail "$2"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
printf '#!/bin/sh\ncase "$2" in ComputerName) echo "$FAKE_CN";; HostName) echo "$FAKE_HN";; LocalHostName) echo "$FAKE_LHN";; esac\n' \
  > "$TMP/bin/scutil"; chmod +x "$TMP/bin/scutil"

# render <ComputerName> <HostName> <stored> ; sets $OUT and $RC
render() {
  printf '[data]\n  hostname = "%s"\n' "$3" > "$TMP/cfg.toml"
  OUT=$(FAKE_CN="$1" FAKE_HN="$2" PATH="$TMP/bin:$PATH" \
        chezmoi execute-template --source "$SRC" --config "$TMP/cfg.toml" \
          --file "$SRC/dot_config/homebrew/Brewfile.tmpl" 2>&1); RC=$?
}
# exact_casks -> the cask lines of the last render, comma-joined
exact_casks() { printf '%s\n' "$OUT" | sed -n 's/^cask "\(.*\)"$/\1/p' | sort | tr '\n' ',' ; }

echo "A. identity guard — five outcomes"
render fenrir fenrir fenrir
rc_is 0 "agreement renders"
render studio studio studio
rc_is 0 "second known identity renders"
render "MacBook Pro" "MacBook Pro" "MacBook Pro"
rc_is 1 "unlisted live identity fails"
has "unknown machine" "unlisted identity names the problem"
has "machines.toml"   "unlisted identity names the file to edit"
render studio studio fenrir
rc_is 1 "stored-vs-live drift fails"
has "identity drift" "drift is named as drift, not as an unknown machine"
has "--repair-identity" "drift names the repair mode, not chezmoi init"
hasnt "run: chezmoi init" "drift does NOT offer chezmoi init, which cannot set HostName"
render fenrir "HostName: not set" fenrir
rc_is 1 "unset HostName fails"
has "HostName is unset" "unset HostName gets the migration message"
render fenrir bogus fenrir
rc_is 1 "set-but-wrong HostName fails"
has "disagrees with ComputerName" "wrong HostName is distinct from unset HostName"

echo "B. Brewfile — exact cask lists per machine"
render fenrir fenrir fenrir
FENRIR_CASKS=$(exact_casks)
render studio studio studio
STUDIO_CASKS=$(exact_casks)
# Asserted as exact sets, not spot-checks: an unrelated cask added or removed must
# change these and fail loudly rather than pass unnoticed.
case "$FENRIR_CASKS" in
  *"elgato-control-center,"*) _pass "fenrir set contains elgato-control-center" ;;
  *) _fail "fenrir set contains elgato-control-center" ;;
esac
if [ "$FENRIR_CASKS" != "$STUDIO_CASKS" ]; then _pass "the two machines get different cask sets"
else _fail "the two machines get different cask sets"; fi
DIFF=$(printf '%s\n' "$FENRIR_CASKS" | tr ',' '\n' | sort > "$TMP/f"; \
       printf '%s\n' "$STUDIO_CASKS" | tr ',' '\n' | sort > "$TMP/s"; \
       comm -23 "$TMP/f" "$TMP/s" | grep -v '^$' | tr '\n' ',')
if [ "$DIFF" = "elgato-control-center,focusrite-control,jiggler," ]; then
  _pass "fenrir's surplus is exactly the three peripheral casks"
else _fail "fenrir's surplus is exactly the three peripheral casks (got: $DIFF)"; fi

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

```bash
chmod 755 .scripts/test-provision.sh && bash .scripts/test-provision.sh
```

Expected: FAIL — neither `Brewfile.tmpl` nor the partial exists.

- [ ] **Step 3: Create the allowlist**

`.chezmoidata/machines.toml`:

```toml
# Known machines. Adding one here is the first half of provisioning it; the second is
# a conditional in dot_config/homebrew/Brewfile.tmpl, and only if it diverges.
#
# Enforced in two places: .scripts/provision.sh rejects an unlisted name at preflight,
# and .chezmoitemplates/identity-guard fails any render on an unlisted LIVE identity.
known_hostnames = ["fenrir", "studio"]
```

- [ ] **Step 4: Create the identity partial**

`.chezmoitemplates/identity-guard` — the single definition of what a valid identity is:

```gotemplate
{{- /*
Identity guard. Invoke as:
  {{- $live := output "scutil" "--get" "ComputerName" | trim -}}
  {{- template "identity-guard" (dict "live" $live "stored" .hostname "known" .known_hostnames) -}}

The CALLER binds $live and passes it in. A Go template partial cannot export a
variable back to its caller, so a partial that bound $live internally would leave the
caller with nothing to write conditionals against. Binding once in the caller keeps
the ComputerName lookup to one subprocess and guarantees the conditionals see exactly
the value that was validated.

ComputerName is the live key because macOS always has one. HostName can be unset, and
`scutil --get HostName` then exits 0 while PRINTING "HostName: not set" — hence the
hasPrefix check before the equality check, or the message would be nonsense.

LocalHostName is deliberately absent: macOS appends -2/-3/-4 itself on Bonjour
collisions, so a template failing on `fenrir-2` would fail on something the machine's
owner neither chose nor can prevent. Preflight validates it with a suffix tolerance.
*/ -}}
{{- $hn := output "scutil" "--get" "HostName" | trim -}}
{{- if not (has .live .known) -}}
{{-   fail (printf "unknown machine %q — add it to .chezmoidata/machines.toml" .live) -}}
{{- end -}}
{{- if ne .live .stored -}}
{{-   fail (printf "identity drift: chezmoi has %q, machine is %q — run: provision.sh --repair-identity" .stored .live) -}}
{{- end -}}
{{- if hasPrefix "HostName: not set" $hn -}}
{{-   fail "HostName is unset — legacy machine, run: provision.sh --repair-identity" -}}
{{- end -}}
{{- if ne $hn .live -}}
{{-   fail (printf "HostName %q disagrees with ComputerName %q — run: provision.sh --repair-identity" $hn .live) -}}
{{- end -}}
```

- [ ] **Step 5: Convert the Brewfile to a template**

```bash
git mv dot_config/homebrew/Brewfile dot_config/homebrew/Brewfile.tmpl
```

Prepend to `Brewfile.tmpl`, above the existing comment block:

```gotemplate
{{- $live := output "scutil" "--get" "ComputerName" | trim -}}
{{- template "identity-guard" (dict "live" $live "stored" .hostname "known" .known_hostnames) -}}
```

Delete `cask "elgato-control-center"`, `cask "focusrite-control"` and `cask "jiggler"` from the cask block, and insert immediately after `cask "docker-desktop"`:

```gotemplate
{{ if eq $live "fenrir" -}}
# Peripherals and laptop-only utilities, guarded because they follow the hardware.
# $live, never .hostname — a conditional on stored data has the same staleness bug as
# a guard on it. See the design doc §5.3.
cask "elgato-control-center"
cask "focusrite-control"
cask "jiggler"
{{ end -}}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
bash .scripts/test-provision.sh
```

Expected: `RESULT: 16 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add .chezmoidata .chezmoitemplates dot_config/homebrew .scripts/test-provision.sh
git commit -m "Add machine allowlist and live identity guard

Machine divergence becomes explicit: three peripheral casks move behind a
conditional keyed on the LIVE identity, never on chezmoi's stored .hostname, which
is captured once at init and never refreshed.

The guard lives in a shared .chezmoitemplates partial covering ComputerName and
HostName. LocalHostName is excluded: macOS appends its own numeric suffix on
Bonjour collisions."
```

---

### Task 2: Safe test harness for `provision.sh`

No `provision.sh` changes. This task exists alone because an unsafe harness is the single most dangerous artefact in this plan: `provision.sh` deletes files in `$HOME`, chmods `~/.ssh`, installs packages and rewrites macOS defaults.

**Files:**
- Modify: `.scripts/test-provision.sh` (add the harness + section C)

**Interfaces:**
- Produces, for Tasks 3–10: `run <stdin> [args...]` setting `$OUT`/`$RC`/`$CALLS`; `called <pattern> <label>`, `not_called <pattern> <label>`, `before <a> <b> <label>`; `$FAKEHOME`, `$STATE`.

- [ ] **Step 1: Write the failing test**

Append to `.scripts/test-provision.sh` before the `RESULT` line:

```bash
PROV="$SRC/.scripts/provision.sh"
FAKEHOME="$TMP/home"; STATE="$TMP/state"; CALLS="$TMP/calls.log"
mkdir -p "$FAKEHOME" "$STATE"

# HARD GUARD. provision.sh removes files under $HOME and rewrites macOS defaults.
# If any root still points inside the real home directory, refuse to run at all.
for v in "$FAKEHOME" "$STATE"; do
  case "$v" in
    "$HOME"|"$HOME"/*) echo "REFUSING: harness root '$v' is inside the real HOME"; exit 2 ;;
  esac
done

# Stub every tool reached through PATH. Each records argv and nothing else.
for tool in brew chezmoi op scutil sudo open chsh git mise defaults killall osascript \
            xcode-select curl ssh find chmod grep; do
  case "$tool" in grep|find|chmod) continue ;; esac   # needed for real by the harness
  cat > "$TMP/bin/$tool" <<STUB
#!/usr/bin/env bash
echo "$tool \$*" >> "$CALLS"
case "\${MOCK_FAIL:-}" in *"$tool"*) exit 1 ;; esac
case "$tool" in
  scutil) case "\$2" in ComputerName) echo "\${FAKE_CN:-studio}";;
                        HostName) echo "\${FAKE_HN:-studio}";;
                        LocalHostName) echo "\${FAKE_LHN:-studio}";; esac ;;
  chezmoi) case "\$1" in execute-template) echo "\${FAKE_CN:-studio}";; esac ;;
  op)      case "\$1" in whoami) exit "\${MOCK_OP_RC:-0}";; esac ;;
  xcode-select) exit "\${MOCK_XCODE_RC:-0}" ;;
esac
exit 0
STUB
  chmod +x "$TMP/bin/$tool"
done

# Scripts provision.sh invokes BY PATH bypass $PATH entirely, so stub them by path.
STUBSRC="$TMP/srcstub"; mkdir -p "$STUBSRC/.scripts" "$STUBSRC/.chezmoidata"
cp "$SRC/.chezmoidata/machines.toml" "$STUBSRC/.chezmoidata/"
for sc in configure.sh reconcile-agents.sh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit "${MOCK_%s_RC:-0}"\n' \
    "$sc" "$CALLS" "$(echo "$sc" | tr 'a-z.-' 'A-Z__')" > "$STUBSRC/.scripts/$sc"
  chmod +x "$STUBSRC/.scripts/$sc"
done

# run <stdin-answers> [args...]
run() {
  local answers=$1; shift
  : > "$CALLS"
  OUT=$(printf '%b' "$answers" | env -i \
        PATH="$TMP/bin:/usr/bin:/bin" HOME="$FAKEHOME" USER="${USER}" \
        XDG_STATE_HOME="$STATE" XDG_CONFIG_HOME="$FAKEHOME/.config" \
        XDG_DATA_HOME="$FAKEHOME/.local/share" XDG_CACHE_HOME="$FAKEHOME/.cache" \
        XDG_BIN_HOME="$FAKEHOME/.local/bin" \
        PROVISION_SRC_OVERRIDE="$STUBSRC" \
        MOCK_FAIL="${MOCK_FAIL:-}" MOCK_OP_RC="${MOCK_OP_RC:-0}" \
        FAKE_CN="${FAKE_CN:-studio}" FAKE_HN="${FAKE_HN:-studio}" \
        FAKE_LHN="${FAKE_LHN:-studio}" \
        zsh "$PROV" "$@" 2>&1); RC=$?
}
reset_state() { rm -rf "${STATE:?}/provision"; }
called()     { if grep -qF -- "$1" "$CALLS"; then _pass "$2"; else _fail "$2"; fi; }
not_called() { if grep -qF -- "$1" "$CALLS"; then _fail "$2"; else _pass "$2"; fi; }
before() {
  local la lb
  la=$(grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1)
  lb=$(grep -nF -- "$2" "$CALLS" | head -1 | cut -d: -f1)
  if [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; then _pass "$3"
  else _fail "$3 (a=${la:-missing} b=${lb:-missing})"; fi
}

echo "C. harness isolation"
reset_state; run 'studio\ny\n'
if [ -z "$(find "$HOME" -maxdepth 1 -newer "$CALLS" -name '.zprofile' 2>/dev/null)" ]; then
  _pass "the real ~/.zprofile is untouched by a test run"
else _fail "the real ~/.zprofile is untouched by a test run"; fi
not_called "$HOME/.ssh" "no call references the real ~/.ssh"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash .scripts/test-provision.sh
```

Expected: section C fails — `provision.sh` does not yet honour `PROVISION_SRC_OVERRIDE` and still uses `set -e` with the old structure.

- [ ] **Step 3: No implementation in this task**

Section C's assertions are satisfied by Task 3's rewrite. To keep this commit green, comment out section C's two assertions with a `# enabled in Task 3` marker and commit the harness alone. Re-enable them in Task 3 Step 4.

- [ ] **Step 4: Verify green and commit**

```bash
bash .scripts/test-provision.sh   # expect: 16 passed, 0 failed
git add .scripts/test-provision.sh
git commit -m "Add isolated test harness for provision.sh

Temporary HOME and every XDG root, with a hard guard refusing to run if any still
resolves inside the real home directory. provision.sh deletes files under \$HOME and
rewrites macOS defaults, so an under-isolated harness is a destructive artefact.

Scripts invoked by path rather than through PATH are stubbed by path. Assertions
read the recorded call log, not stdout: a stub that records to a file contributes
nothing to stdout, so an output substring check passes or fails for the wrong
reason."
```

---

### Task 3: Phase framework, state markers, flag matrix

**Files:**
- Rewrite: `.scripts/provision.sh` (header, flags, state, `run_phase`; phase bodies are stubs that later tasks replace)
- Modify: `.scripts/test-provision.sh` (re-enable section C; add D)

**Interfaces:**
- Produces: `run_phase <name> <crit> <idx> <total>`; `warn <msg>`; `state_record/state_completed/state_answer/state_get/state_has_marker/state_mark`; globals `MACHINE_NAME`, `SRC_DIR`, `WARNINGS`, `DRY_RUN`, `RESUME`, `RESTART`, `ONLY_PHASE`, `REPAIR`. Phase functions are `phase_<name with - replaced by _>`, returning 0/non-zero.

- [ ] **Step 1: Write the failing test**

Re-enable section C, then append section D:

```bash
echo "D. flag matrix"
reset_state; run 'studio\ny\n'; rc_is 0 "clean run exits 0"
called "[4/10]" "stage 2 phases are numbered continuously"

reset_state; run 'studio\ny\n' --dry-run
not_called "brew " "dry-run invokes no tools"
if [ ! -f "$STATE/provision/state" ]; then _pass "dry-run writes no state"
else _fail "dry-run writes no state"; fi

reset_state; run 'studio\ny\n'; run '' --restart --dry-run
if [ -f "$STATE/provision/state" ]; then _pass "--restart --dry-run does not delete state"
else _fail "--restart --dry-run does not delete state"; fi

reset_state; run 'studio\ny\n'; run '' --phase nosuchphase
rc_is 2 "an unknown --phase name is a usage error, not a silent no-op"

reset_state; run 'studio\ny\n' --repair-identity --resume
rc_is 2 "--repair-identity with --resume is a usage error"

echo "E. criticality"
reset_state; MOCK_FAIL="chezmoi" run 'studio\ny\n'
rc_is 1 "a failing critical phase exits 1"
has "--resume" "critical failure prints a resume command"
hasnt "\$0" "the resume command is a resolved path, not \$0"
MOCK_FAIL=""
reset_state; MOCK_FAIL="mise" run 'studio\ny\n'
rc_is 0 "a failing best-effort phase does not abort"
called "[10/10]" "phases after a best-effort failure still run"
MOCK_FAIL=""
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash .scripts/test-provision.sh
```

Expected: C, D, E fail.

- [ ] **Step 3: Rewrite the head of `provision.sh`**

Replace `.scripts/provision.sh` lines 1–34 (shebang through the confirmation loop):

```zsh
#!/usr/bin/env zsh
# macOS Provision Script
# Install by running: /bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/michaelrigart/dotfiles/refs/heads/main/.scripts/provision.sh)"
#
# Four stages: bootstrap (prerequisites + the Xcode CLT dialog), preflight (ALL
# decisions, ending in one confirm that gates identity mutation), run (unattended),
# report. See docs/superpowers/specs/2026-08-27-provisioning-preflight-design.md
#
# NOT `set -e`: best-effort phases must fail without killing the run.
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { print -r -- "${GREEN}[INFO]${NC} $1"; }
log_warn()  { print -r -- "${YELLOW}[WARN]${NC} $1"; }
log_error() { print -r -- "${RED}[ERROR]${NC} $1"; }

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
export XDG_BIN_HOME="${XDG_BIN_HOME:-${HOME}/.local/bin}"

# PROVISION_SRC_OVERRIDE exists for the test harness; nothing else sets it.
SRC_DIR="${PROVISION_SRC_OVERRIDE:-${XDG_DATA_HOME}/chezmoi}"
DOTFILES_HTTPS="https://github.com/michaelrigart/dotfiles.git"
DOTFILES_SSH="git@github.com:michaelrigart/dotfiles.git"
STATE_DIR="${XDG_STATE_HOME}/provision"
STATE_FILE="${STATE_DIR}/state"

# $0 is the literal word "provision" under `zsh -c "$(curl …)" provision`, so never
# print it as a command. Resolve a real path, preferring the cloned copy.
SELF="${SRC_DIR}/.scripts/provision.sh"
[[ -r $SELF ]] || SELF="$0"

typeset -g MACHINE_NAME=""
typeset -ga WARNINGS=()
typeset -g RESUME=0 RESTART=0 DRY_RUN=0 REPAIR=0 ONLY_PHASE=""

typeset -ga PHASES=(
  "xcode-clt:critical"      "homebrew:critical"     "source-clone:critical"
  "chezmoi-init:critical"   "dotfiles:critical"     "brewfile:best-effort"
  "agent-plugins:best-effort" "mise:best-effort"    "macos-config:best-effort"
  "shell:best-effort"
)

usage() {
  cat <<'EOF'
Usage: provision.sh [--resume | --restart | --phase NAME | --dry-run | --repair-identity]

  --resume            skip completed phases; re-use decisions; revalidate credentials
  --restart           discard recorded state and start over
  --phase NAME        run only NAME (requires a confirmed, identity-applied state)
  --dry-run           print what each phase would do; run nothing, record nothing
  --repair-identity   repair a machine's identity fields; mutually exclusive with the above
EOF
}

while (( $# )); do
  case $1 in
    --resume)          RESUME=1 ;;
    --restart)         RESTART=1 ;;
    --dry-run)         DRY_RUN=1 ;;
    --repair-identity) REPAIR=1 ;;
    --phase)           (( $# >= 2 )) || { log_error "--phase needs a name"; exit 2; }
                       ONLY_PHASE=$2; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 log_error "unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

# --repair-identity is a repair mode, not a provisioning mode: it never merges.
if (( REPAIR )) && { (( RESUME || RESTART || DRY_RUN )) || [[ -n $ONLY_PHASE ]] }; then
  log_error "--repair-identity cannot be combined with other flags"
  exit 2
fi
if [[ -n $ONLY_PHASE ]] && ! print -r -- "${PHASES[@]%%:*}" | grep -qw -- "$ONLY_PHASE"; then
  log_error "unknown phase: ${ONLY_PHASE}"
  log_error "known phases: ${PHASES[@]%%:*}"
  exit 2
fi

mkdir -p "$STATE_DIR"
# --restart must not destroy state during a --dry-run, and flag validation above must
# have passed first: a usage error should never have side effects.
(( RESTART && ! DRY_RUN )) && rm -f "$STATE_FILE"
[[ -f $STATE_FILE || $DRY_RUN -eq 1 ]] || : > "$STATE_FILE"

state_record()     { (( DRY_RUN )) || print -r -- "phase=$1" >> "$STATE_FILE"; }
state_completed()  { grep -qxF "phase=$1" "$STATE_FILE" 2>/dev/null; }
state_answer()     { (( DRY_RUN )) || print -r -- "$1=$2" >> "$STATE_FILE"; }
state_get()        { sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | tail -1; }
state_mark()       { (( DRY_RUN )) || print -r -- "marker=$1" >> "$STATE_FILE"; }
state_has_marker() { grep -qxF "marker=$1" "$STATE_FILE" 2>/dev/null; }
warn()             { WARNINGS+=("$1"); log_warn "$1"; }

run_phase() {
  local name=$1 crit=$2 idx=$3 total=$4 fn="phase_${1//-/_}"
  [[ -n $ONLY_PHASE && $ONLY_PHASE != $name ]] && return 0
  if (( RESUME )) && [[ -z $ONLY_PHASE ]] && state_completed "$name"; then
    printf '[%d/%d] %-16s skipped (already done)\n' "$idx" "$total" "$name"; return 0
  fi
  if (( DRY_RUN )); then
    printf '[%d/%d] %-16s dry-run\n' "$idx" "$total" "$name"; return 0
  fi
  printf '[%d/%d] %-16s\n' "$idx" "$total" "$name"
  if "$fn"; then state_record "$name"; return 0; fi
  if [[ $crit == critical ]]; then
    log_error "critical phase '${name}' failed — aborting"
    log_error "fix the cause, then resume with: ${SELF} --resume"
    exit 1
  fi
  warn "phase '${name}' failed (best-effort) — see output above"
  return 0
}
```

- [ ] **Step 4: Add stubs and the run loop**

Replace everything after the header (old steps 1–16) with:

```zsh
# --- phase stubs, replaced by Tasks 5-8 --------------------------------------
phase_xcode_clt()     { return 0; }
phase_homebrew()      { return 0; }
phase_source_clone()  { return 0; }
phase_chezmoi_init()  { chezmoi --version >/dev/null; }
phase_dotfiles()      { return 0; }
phase_brewfile()      { brew --version >/dev/null; }
phase_agent_plugins() { return 0; }
phase_mise()          { mise --version >/dev/null; }
phase_macos_config()  { return 0; }
phase_shell()         { return 0; }

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

Re-enable section C's two commented assertions.

- [ ] **Step 5: Verify green**

```bash
bash .scripts/test-provision.sh
printf 'studio\ny\n' | zsh .scripts/provision.sh --dry-run | grep -o '\[[0-9]*/10\]' | tr '\n' ' '
```

Expected: all sections green, and `[1/10] … [10/10]` exactly once each — a repeated `[1/10]` means a duplicate counter declaration.

- [ ] **Step 6: Commit**

```bash
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Add phase framework and flag matrix to provision.sh

Ten phases, each critical or best-effort, dispatched through run_phase with state
under XDG_STATE_HOME. Flags are validated before any side effect: --restart does not
delete state during a --dry-run, an unknown --phase is a usage error rather than a
silent no-op, and --repair-identity refuses to combine with the others.

Recovery messages print a resolved path: \$0 is the literal word 'provision' under
the documented curl invocation.

set -e is removed deliberately — best-effort phases cannot exist under it."
```

---

### Task 4: Stage 0 — bootstrap

**Files:** modify `.scripts/provision.sh` (three stubs), `.scripts/test-provision.sh` (section F).

**Interfaces:** produces `HOMEBREW_PREFIX` and a PATH-configured Homebrew, **hoisted out of phase completion** so a resumed run that skips the phase still gets them; populates `$SRC_DIR`.

- [ ] **Step 1: Write the failing test**

```bash
echo "F. stage 0"
reset_state; run 'studio\ny\n'
called "NONINTERACTIVE" "Homebrew is installed non-interactively"
before "brew install chezmoi" "git clone" "chezmoi is installed before the clone"
called "git clone" "the source is cloned with git, not chezmoi init"
reset_state; run 'studio\ny\n'; MOCK_FAIL="" run '' --resume
called "brew --prefix" "a resumed run initialises the brew environment even when the phase is skipped"
```

- [ ] **Step 2: Run to verify it fails**, then **Step 3: implement**:

```zsh
# Homebrew's process environment is NOT part of phase completion: a resumed run that
# skips phase_homebrew still needs PATH and HOMEBREW_PREFIX, and ${HOMEBREW_PREFIX}
# is an unbound-variable abort under `set -u` without it.
init_brew_env() {
  [[ -x /opt/homebrew/bin/brew ]] || return 0
  eval "$(/opt/homebrew/bin/brew shellenv)"
  export HOMEBREW_PREFIX=$(brew --prefix)
}

phase_xcode_clt() {
  xcode-select -p &>/dev/null && { log_info "✓ Xcode CLT already installed"; return 0; }
  log_info "Installing Xcode Command Line Tools — accept the dialog that just opened"
  xcode-select --install 2>/dev/null
  # Cancellation and no-response are indistinguishable here: xcode-select -p simply
  # keeps failing. One bounded wait resolves both, rather than hanging forever or
  # reporting the false success the old `exit 0` produced.
  local -i waited=0
  until xcode-select -p &>/dev/null; do
    (( waited >= 1800 )) && { log_error "no Xcode CLT after 30m — was the dialog cancelled?"; return 1; }
    sleep 5; (( waited += 5 ))
    (( waited % 60 == 0 )) && log_info "  still waiting for the Xcode CLT dialog (${waited}s)"
  done
}

phase_homebrew() {
  if ! command -v brew &>/dev/null; then
    log_info "Installing Homebrew..."
    # NONINTERACTIVE=1: the installer prompts for confirmation by default, which would
    # stop the run on a "Press RETURN to continue" this design promises does not exist.
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
  else
    log_info "✓ Homebrew already installed"
    brew update || warn "brew update failed — continuing with the current index"
  fi
  init_brew_env
  brew install chezmoi 1password-cli git || return 1
  brew install --cask 1password || return 1   # preflight's gate needs the desktop app
}

phase_source_clone() {
  [[ -d $SRC_DIR/.git ]] && { log_info "✓ source already at ${SRC_DIR}"; return 0; }
  # Plain git clone, NOT chezmoi init: preflight needs .chezmoidata/machines.toml
  # present, but the config must not render until the identity is set.
  log_info "Cloning dotfiles source..."
  git clone "$DOTFILES_HTTPS" "$SRC_DIR" || return 1
}
```

Call `init_brew_env` once immediately after the flag block, before any phase runs.

- [ ] **Step 4: Verify green and commit**

```bash
bash .scripts/test-provision.sh
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Implement stage 0 bootstrap

Xcode CLT polls until the dialog is satisfied instead of exiting 0 and asking to be
re-run; cancellation and no-response both resolve through one bounded wait. Homebrew
installs with NONINTERACTIVE=1, which its installer requires to skip its own prompt.

The brew process environment is initialised outside phase completion, so a resumed
run that skips the phase still has HOMEBREW_PREFIX — otherwise every later phase runs
unconfigured and aborts under set -u.

The source is cloned with plain git so preflight can read the allowlist before the
identity is set."
```

---

### Task 5: Stage 1 — preflight and the consent markers

**Do not start without completing the execution precondition above.** This is the first task whose code renames a machine.

**Files:** modify `.scripts/provision.sh`, `.scripts/test-provision.sh` (sections G, H).

**Interfaces:** produces `MACHINE_NAME`; markers `answers_collected`, `confirmed`, `identity_applied`; `validate_identity <name>` shared with Task 6.

- [ ] **Step 1: Write the failing test**

```bash
echo "G. preflight ordering and consent"
reset_state; run 'studio\ny\n'
before "scutil --set ComputerName" "chezmoi init" "identity is set BEFORE chezmoi init"
called "scutil --set HostName studio"      "HostName is set — Borg depends on it"
called "scutil --set LocalHostName studio" "LocalHostName is set"

reset_state; run 'nosuchmachine\nstudio\ny\n'
rc_is 0 "an unlisted name re-prompts rather than aborting"
not_called "scutil --set ComputerName nosuchmachine" "the rejected name is never applied"

reset_state; run 'studio\nn\n'
rc_is 1 "declining aborts"
not_called "scutil --set" "declining mutates NOTHING — identity included"
not_called "[4/10]"       "declining runs no stage 2 phase"

echo "H. consent laundering regression"
reset_state; run 'studio\nn\n'          # answers recorded, consent refused
run '' --resume                          # must NOT proceed on recorded answers alone
not_called "scutil --set" "resume after a decline does not rename"
has "Proceed?" "resume after a decline re-asks for consent"
run 'y\n' --resume
called "scutil --set ComputerName studio" "a second explicit yes does apply the identity"

echo "I. LocalHostName suffix tolerance"
reset_state; FAKE_LHN="studio-2" run 'studio\ny\n'
rc_is 0 "LocalHostName studio-2 is accepted (macOS Bonjour suffix)"
reset_state; FAKE_LHN="studio-x" run 'studio\ny\n'
rc_is 1 "LocalHostName studio-x is rejected"
FAKE_LHN="studio"
```

- [ ] **Step 2: Run to verify it fails**, then **Step 3: implement**. Insert before the run loop:

```zsh
known_hostnames() {
  sed -n 's/^known_hostnames *= *\[\(.*\)\]/\1/p' "$SRC_DIR/.chezmoidata/machines.toml" 2>/dev/null \
    | tr -d '" ' | tr ',' '\n' | grep -v '^$'
}

# validate_identity <name> -> 0 if all three fields match. ComputerName and HostName
# exactly; LocalHostName tolerates the numeric suffix macOS adds on Bonjour collisions.
validate_identity() {
  local want=$1 cn hn lhn
  cn=$(scutil --get ComputerName 2>/dev/null)
  hn=$(scutil --get HostName 2>/dev/null)
  lhn=$(scutil --get LocalHostName 2>/dev/null)
  [[ $cn == $want ]]  || { log_error "ComputerName is ${cn:-unset}, expected ${want}"; return 1; }
  [[ $hn == $want ]]  || { log_error "HostName is ${hn:-unset}, expected ${want}"; return 1; }
  [[ $lhn == ${~want}(-<->|) ]] || { log_error "LocalHostName is ${lhn:-unset}, expected ${want} or ${want}-N"; return 1; }
}

apply_identity() {
  local n=$1
  sudo scutil --set ComputerName  "$n" || return 1
  sudo scutil --set HostName      "$n" || return 1
  sudo scutil --set LocalHostName "$n" || return 1
  validate_identity "$n" || return 1
  state_mark identity_applied
}

preflight_credentials() {   # decisions persist across a resume; credentials do not
  if ! op whoami &>/dev/null; then
    open -a "1Password" 2>/dev/null
    print "\n  In the 1Password app: sign in, then Settings → Developer →"
    print "  ☑ Integrate with 1Password CLI\n"
    local -i waited=0
    until op whoami &>/dev/null; do
      (( waited >= 900 )) && { log_error "timed out waiting for the 1Password CLI"; return 1; }
      sleep 3; (( waited += 3 ))
    done
  fi
  log_info "✓ 1Password CLI authenticated"
  sudo -v || return 1
  while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
}

preflight_machine_name() {
  local recorded; recorded=$(state_get machine_name)
  if [[ -n $recorded ]]; then MACHINE_NAME=$recorded; return 0; fi
  local -a allowed; allowed=(${(f)"$(known_hostnames)"})
  (( ${#allowed} )) || { log_error "no known_hostnames in ${SRC_DIR}/.chezmoidata/machines.toml"; return 1; }
  local name
  while true; do
    print -n "  Machine name (${(j:, :)allowed}): "
    read -r name || return 1
    if (( ${allowed[(Ie)$name]} )); then
      MACHINE_NAME=$name; state_answer machine_name "$name"; state_mark answers_collected
      return 0
    fi
    log_warn "unknown machine '${name}' — add it to .chezmoidata/machines.toml first"
  done
}

preflight_confirm() {
  print "\n══ Provision: ${MACHINE_NAME} ══════════════════"
  printf '  Machine name ....... %s\n' "$MACHINE_NAME"
  printf '  Dotfiles source .... %s\n' "$SRC_DIR"
  printf '  Phases ............. %d\n' "${#PHASES}"
  print "────────────────────────────────────────────────"
  local reply; print -n "  Proceed? [y/N] "
  read -r reply || return 1
  [[ $reply == (y|Y) ]] || return 1
  state_mark confirmed
}
```

Then insert the stage sequencing, replacing the single run loop:

```zsh
local -i idx=0
local total=${#PHASES}
local entry

# Stage 0 — bootstrap
for entry in "${PHASES[@]:0:3}"; do
  (( idx++ )); run_phase "${entry%%:*}" "${entry##*:}" "$idx" "$total"
done

# Stage 1 — preflight
if [[ -z $ONLY_PHASE ]] && (( ! DRY_RUN )); then
  preflight_credentials  || { log_error "credential gate failed"; exit 1; }
  preflight_machine_name || { log_error "could not determine the machine name"; exit 1; }
  # Consent, then mutation — never the reverse. Declining must leave the machine as found.
  if ! state_has_marker confirmed; then
    preflight_confirm || { log_warn "Aborted before any machine-specific change."; exit 1; }
  fi
  if ! state_has_marker identity_applied; then
    apply_identity "$MACHINE_NAME" || { log_error "could not set the identity"; exit 1; }
  else
    validate_identity "$MACHINE_NAME" || {
      log_error "live identity has drifted — run: ${SELF} --repair-identity"; exit 1; }
  fi
fi

# Stage 2 — run
for entry in "${PHASES[@]:3}"; do
  (( idx++ )); run_phase "${entry%%:*}" "${entry##*:}" "$idx" "$total"
done
```

Add the `--phase` precondition immediately after the flag block:

```zsh
if [[ -n $ONLY_PHASE ]]; then
  # Both markers, not just `confirmed`: from a confirmed-but-unapplied state,
  # --phase chezmoi-init would capture the pre-migration name — the §5.1 ordering
  # defect arriving through the flag surface.
  state_has_marker confirmed || { log_error "no confirmed run — use: ${SELF} --resume"; exit 2; }
  state_has_marker identity_applied || { log_error "identity not applied — use: ${SELF} --resume"; exit 2; }
  MACHINE_NAME=$(state_get machine_name)
  validate_identity "$MACHINE_NAME" || { log_error "identity drift — run: ${SELF} --repair-identity"; exit 2; }
  preflight_credentials || exit 1
fi
```

- [ ] **Step 4: Verify green and commit**

```bash
bash .scripts/test-provision.sh
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Add preflight, consent markers, and identity application

All decisions move ahead of the unattended run, and the confirm gates identity
mutation: declining leaves the machine exactly as found, including its name.

Recorded answers are not recorded consent. answers_collected, confirmed and
identity_applied are separate markers, so answering, declining and later resuming
re-asks instead of treating the stored answer as approval.

All three identity fields are read back after being set. ComputerName and HostName
must match exactly; LocalHostName tolerates the numeric suffix macOS appends on
Bonjour collisions.

--phase requires both markers and revalidates the live identity."
```

---

### Task 6: `--repair-identity`

**Files:** modify `.scripts/provision.sh`, `.scripts/test-provision.sh` (section J).

- [ ] **Step 1: Write the failing test**

```bash
echo "J. --repair-identity"
reset_state; run 'fenrir\ny\n' --repair-identity
rc_is 0 "repair runs with no state file at all"
if [ ! -f "$STATE/provision/state" ]; then _pass "stateless repair creates no provisioning state"
else _fail "stateless repair creates no provisioning state"; fi

reset_state; run 'fenrir\nn\n' --repair-identity
not_called "scutil --set" "declining repair mutates nothing"

# changed identity, existing state -> file deleted BEFORE the first mutation
reset_state; run 'studio\ny\n'
MOCK_FAIL="scutil" run 'fenrir\ny\n' --repair-identity
if [ ! -f "$STATE/provision/state" ]; then
  _pass "a repair that dies mid-mutation has already deleted the old state"
else _fail "a repair that dies mid-mutation has already deleted the old state"; fi
MOCK_FAIL=""

reset_state; run 'studio\ny\n'
cp "$STATE/provision/state" "$TMP/state.before"
run 'studio\nn\n' --repair-identity
if cmp -s "$TMP/state.before" "$STATE/provision/state"; then
  _pass "declining repair leaves the state file byte-identical"
else _fail "declining repair leaves the state file byte-identical"; fi

reset_state; run 'studio\ny\n'
run 'fenrir\ny\n' --repair-identity
run '' --resume
has "fenrir" "the run after a changed-identity repair displays the NEW identity"
hasnt "Machine name ....... studio" "it does not display the old identity"
```

- [ ] **Step 2: Run to verify it fails**, then **Step 3: implement**, inserted before the stage sequencing and guarded to exit before it:

```zsh
repair_identity() {
  local -a allowed; allowed=(${(f)"$(known_hostnames)"})
  (( ${#allowed} )) || { log_error "no known_hostnames in ${SRC_DIR}/.chezmoidata/machines.toml"; return 1; }

  local name recorded reply
  recorded=$(state_get machine_name)
  while true; do
    print -n "  Repair identity to (${(j:, :)allowed}): "
    read -r name || return 1
    (( ${allowed[(Ie)$name]} )) && break
    log_warn "unknown machine '${name}' — add it to .chezmoidata/machines.toml first"
  done

  print "\n══ Repair identity ═════════════════════════════"
  printf '  ComputerName ..... %-22s → %s\n' "$(scutil --get ComputerName 2>/dev/null)" "$name"
  printf '  HostName ......... %-22s → %s\n' "$(scutil --get HostName 2>/dev/null)"     "$name"
  printf '  LocalHostName .... %-22s → %s\n' "$(scutil --get LocalHostName 2>/dev/null)" "$name"
  print "────────────────────────────────────────────────"
  print -n "  Apply? [y/N] "
  read -r reply || return 1
  [[ $reply == (y|Y) ]] || { log_warn "Repair declined — nothing changed."; return 1; }

  # Deletion timing is the whole point. AFTER the y (declining must preserve a good
  # in-progress run) and BEFORE the first scutil --set (repair is not atomic: three
  # sets then a chezmoi init, any of which can fail, and a half-renamed machine beside
  # a confirmed state file for the OLD identity is exactly what --resume would eat).
  if [[ -n $recorded && $recorded != $name ]]; then
    log_info "identity changes ${recorded} → ${name}; discarding the previous run's state"
    rm -f "$STATE_FILE"
  fi

  sudo scutil --set ComputerName  "$name" || return 1
  sudo scutil --set HostName      "$name" || return 1
  sudo scutil --set LocalHostName "$name" || return 1
  validate_identity "$name" || return 1
  chezmoi init || return 1

  if [[ -n $recorded && $recorded != $name ]]; then
    log_info "✓ identity repaired to ${name}. Now run: ${SELF}"
  else
    state_mark identity_applied
    log_info "✓ identity repaired to ${name}"
  fi
}

if (( REPAIR )); then
  init_brew_env
  repair_identity || exit 1
  exit 0
fi
```

- [ ] **Step 4: Verify green and commit**

```bash
bash .scripts/test-provision.sh
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Add --repair-identity

A repair mode that works without state, so a legacy or externally-renamed machine can
be fixed. It shows a before/after for all three fields and requires an explicit yes:
identity mutation always requires consent, in every mode.

When the identity changes, the previous run's state file is deleted after the yes and
before the first scutil --set. Repair is not atomic, so deleting on success would let
a mid-repair failure leave a half-renamed machine beside a confirmed state file for
the old identity — which --resume would consume. Declining preserves it untouched."
```

---

### Task 7: Stage 2 critical phases

**Files:** modify `.scripts/provision.sh` (two stubs), `.scripts/test-provision.sh` (section K).

- [ ] **Step 1: Write the failing test**

```bash
echo "K. critical phases"
reset_state; run 'studio\ny\n'
before "chezmoi init" "chezmoi apply" "init precedes apply"
called "git remote set-url" "the remote is switched to SSH"
before "chezmoi apply" "git remote set-url" "the switch follows the apply that renders the key"
called "StrictHostKeyChecking=accept-new" "the SSH check cannot block on an unknown host key"
```

- [ ] **Step 2: Run to verify it fails**, then **Step 3: implement**:

```zsh
phase_chezmoi_init() {
  # The source is already cloned; init's only job here is rendering the config from
  # the source-root .chezmoi.toml.tmpl, which reads the identity preflight just set.
  log_info "Generating chezmoi config for ${MACHINE_NAME}..."
  chezmoi init || return 1
  local got; got=$(chezmoi execute-template '{{ .hostname }}' 2>/dev/null)
  [[ $got == $MACHINE_NAME ]] || {
    log_error "chezmoi resolved '${got}', expected '${MACHINE_NAME}'"; return 1; }
}

phase_dotfiles() {
  log_info "Applying dotfiles..."
  chezmoi apply --force || return 1
  if [[ -d ${HOME}/.ssh ]]; then
    chmod 700 "${HOME}/.ssh" || { log_error "could not chmod ~/.ssh"; return 1; }
    find "${HOME}/.ssh" -type f ! -name "*.pub" ! -name "config" -exec chmod 600 {} \; \
      || { log_error "could not chmod private keys"; return 1; }
  fi
  log_info "Switching the dotfiles remote to SSH..."
  git -C "$SRC_DIR" remote set-url origin "$DOTFILES_SSH" || return 1
  # accept-new, not `ask`: a fresh machine has no known_hosts entry for github.com and
  # the default would block the unattended run on a host-key prompt.
  if ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    log_info "✓ SSH to GitHub verified"
  else
    warn "SSH to GitHub not confirmed — check ~/.ssh/michael"
  fi
}
```

- [ ] **Step 4: Verify green and commit**

```bash
bash .scripts/test-provision.sh
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Implement the critical dotfiles phases

chezmoi init renders only the config, since the source is already cloned, and asserts
the identity it resolved matches the one preflight applied.

The SSH verification uses StrictHostKeyChecking=accept-new: a fresh machine has no
known_hosts entry and the default 'ask' would block the unattended run on a host-key
prompt. chmod failures now fail the phase rather than being swallowed with set -e
gone."
```

---

### Task 8: Stage 2 best-effort phases

**Files:** modify `.scripts/provision.sh` (five stubs), `.scripts/test-provision.sh` (section L).

- [ ] **Step 1: Write the failing test**

```bash
echo "L. best-effort phases"
reset_state; run 'studio\ny\n'
before "brew trust --tap" "brew bundle" "taps are trusted before bundling"
called "mise install" "mise tools are installed"
called "sudo chsh"    "chsh goes through the cached sudo credential"
not_called "$(printf 'chsh -s')" "bare chsh is never called"
called "configure.sh --hostname studio" "configure.sh is driven with the identity"
```

- [ ] **Step 2: Run to verify it fails**, then **Step 3: implement**:

```zsh
phase_brewfile() {
  local bf="${XDG_CONFIG_HOME}/homebrew/Brewfile"
  [[ -f $bf ]] || { log_error "Brewfile not found at ${bf}"; return 1; }
  export HOMEBREW_BUNDLE_FILE="$bf"
  local tap
  for tap in ${(f)"$(sed -n 's/^tap "\([^"]*\)".*/\1/p' "$bf")"}; do
    brew trust --tap "$tap" || warn "could not trust tap ${tap}"
  done
  brew bundle install --file "$bf" && return 0
  # `brew bundle` fails for the whole file; `check --verbose` names each missing item
  # on its own "→ " line, which is what turns this into an actionable report.
  local item
  for item in ${(f)"$(brew bundle check --verbose --file "$bf" 2>/dev/null | sed -n 's/^→ *//p')"}; do
    warn "brewfile: ${item}"
  done
  return 1
}

phase_agent_plugins() {
  local s="${SRC_DIR}/.scripts/reconcile-agents.sh"
  [[ -x $s ]] || { warn "reconcile-agents.sh missing — agent plugins unconfigured"; return 1; }
  "$s" || return 1
}

phase_mise() {
  command -v mise &>/dev/null || { warn "mise not installed"; return 1; }
  mise install || return 1
}

phase_macos_config() {
  local s="${SRC_DIR}/.scripts/configure.sh"
  [[ -x $s ]] || { warn "configure.sh missing — macOS settings unapplied"; return 1; }
  # --hostname makes configure.sh VALIDATE ONLY. It must never rename: this phase is
  # best-effort and reachable via --phase, which skips the confirm.
  "$s" --hostname "$MACHINE_NAME" --as-phase || return 1
}

phase_shell() {
  local target="${HOMEBREW_PREFIX}/bin/zsh"
  if [[ $SHELL != $target ]]; then
    grep -qxF "$target" /etc/shells || print -r -- "$target" | sudo tee -a /etc/shells >/dev/null || return 1
    sudo chsh -s "$target" "$USER" || return 1
  fi
  if [[ -d ${XDG_DATA_HOME}/oh-my-zsh ]]; then
    git -C "${XDG_DATA_HOME}/oh-my-zsh" pull --quiet || warn "oh-my-zsh update failed"
  else
    ZSH="${XDG_DATA_HOME}/oh-my-zsh" sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/robbyrussell/oh-my-zsh/master/tools/install.sh)" "" --unattended || return 1
  fi
  mkdir -p "${XDG_CACHE_HOME}"/{zsh,irb} "${XDG_CACHE_HOME}"/bundler/{cache,plugin} "${XDG_CACHE_HOME}/gem/specs"
  rm -f "${HOME}"/.zprofile{,.bak} "${HOME}/.zshrc.pre-oh-my-zsh" "${HOME}/.shell.pre-oh-my-zsh"
  brew cleanup || warn "brew cleanup failed"
}
```

- [ ] **Step 4: Verify green and commit**

```bash
bash .scripts/test-provision.sh
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Implement the best-effort phases

Each can fail without ending the run. The Brewfile phase re-runs brew bundle check
--verbose on failure so the report names the specific missing casks rather than
saying the bundle failed.

chsh goes through the sudo credential preflight already holds, removing a
mid-run password prompt."
```

---

### Task 9: Stage 3 — report

**Files:** modify `.scripts/provision.sh`, `.scripts/test-provision.sh` (section M).

- [ ] **Step 1: Write the failing test**

```bash
echo "M. report"
reset_state; run 'studio\ny\n'
has "provision complete" "a clean run says so"
hasnt "Done, with"       "a clean run shows no warning block"
reset_state; MOCK_FAIL="mise" run 'studio\ny\n'
has "Done, with"   "warnings are reported"
has "--phase mise" "the report gives a per-phase retry command"
rc_is 0            "warnings do not change the exit status"
has "Borg"         "Borg setup is listed as outstanding"
has "own terminal" "the report repeats the identity-verification precondition"
MOCK_FAIL=""
```

- [ ] **Step 2: Run to verify it fails**, then **Step 3: implement**, replacing the closing lines:

```zsh
print ""
if (( ${#WARNINGS} )); then
  print "══ Done, with ${#WARNINGS} item(s) needing you ══"
  local w; for w in "${WARNINGS[@]}"; do print "  ⚠ ${w}"; done
  print "\n  Retry a single phase with:"
  local entry name
  for entry in "${PHASES[@]}"; do
    name="${entry%%:*}"; state_completed "$name" || print "    ${SELF} --phase ${name}"
  done
  print ""
else
  log_info "✓ macOS provision complete — no warnings"
fi

print "══ Still manual ════════════════════════════════"
print "  • Little Snitch: import your rule set, or expect a prompt for every"
print "    ad-hoc-signed Homebrew binary (tsh, gh, …)"
print "  • Borg: create this machine's own BorgBase repo and keypair, store the"
print "    passphrase in 1Password, then configure Vorta. Archive naming must use"
print "    the literal name '${MACHINE_NAME}', not {hostname}."
print "  • Alfred: System Settings → Privacy & Security → Accessibility → add"
print "    Alfred, then re-run .scripts/configure.sh. Verify with:"
print "    bash .scripts/test-alfred-relay.sh"
print "  • FileVault: System Settings → Privacy & Security"
print "  • Unmanaged state to restore: ~/.kube, ~/.aws, ~/.azure, ~/Code"
print "  • Confirm the identity in your own terminal before trusting it:"
print "    scutil --get ComputerName; scutil --get HostName; hostname"
print ""
log_info "Restart your terminal, or run: exec ${HOMEBREW_PREFIX:-/opt/homebrew}/bin/zsh"
```

- [ ] **Step 4: Verify green and commit**

```bash
bash .scripts/test-provision.sh
git add .scripts/provision.sh .scripts/test-provision.sh
git commit -m "Add the provisioning report stage

Warnings print with a per-phase retry command, followed by the follow-ups that
cannot be scripted. Warnings never change the exit status — they are work for a
human, not failures of the run."
```

---

### Task 10: `configure.sh` integration

**Files:** modify `.scripts/configure.sh:22-46`, `:141-152`, `:227`, `:319-327`; `.scripts/test-provision.sh` (section N).

- [ ] **Step 1: Write the failing test**

```bash
echo "N. configure.sh"
CONF="$SRC/.scripts/configure.sh"
crun() { OUT=$(PATH="$TMP/bin:/usr/bin:/bin" FAKE_CN="$1" FAKE_HN="$1" FAKE_LHN="$1" \
               zsh "$CONF" --hostname "$2" --as-phase 2>&1); RC=$?; }
crun studio studio
rc_is 0 "runs non-interactively with --hostname"
hasnt "is this correct" "--hostname suppresses the prompt"
hasnt "Manual tasks still required" "--as-phase suppresses the standalone trailer"
: > "$CALLS"; crun studio studio
not_called "scutil --set" "provisioning mode NEVER renames — the back-door consent hole"
crun fenrir studio
rc_is 1 "a live identity disagreeing with --hostname aborts"
has "--repair-identity" "the abort names the repair mode"
crun fenrir fenrir; has "TrackpadThreeFingerDrag" "fenrir applies the trackpad defaults"
crun studio studio; hasnt "TrackpadThreeFingerDrag" "studio skips the trackpad defaults"
```

- [ ] **Step 2: Run to verify it fails**, then **Step 3: implement**. Replace `configure.sh:22-46`:

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
# Hostname
# ============================================================================
# With --hostname this VALIDATES ONLY and never renames. It runs as provisioning
# phase 9 — best-effort, and reachable via --phase, which skips the confirm — so a
# rename here would be an unconfirmed identity mutation. Renaming happens in exactly
# two confirmed places: provision.sh preflight, and provision.sh --repair-identity.
if [[ -n $HOSTNAME_ARG ]]; then
  HOSTNAME=$HOSTNAME_ARG
  cn=$(scutil --get ComputerName 2>/dev/null)
  if [[ $cn != $HOSTNAME ]]; then
    log_error "live ComputerName is '${cn:-unset}' but --hostname says '${HOSTNAME}'"
    log_error "run: provision.sh --repair-identity"
    exit 1
  fi
  log_info "✓ identity verified: ${HOSTNAME}"
else
  while true; do
    print -n "Enter the hostname for this machine: "; read HOSTNAME
    print -n "You have entered $HOSTNAME, is this correct (y/n)? "; read answer
    [[ $answer == (y|Y) ]] && break
  done
  log_info "Setting hostname to $HOSTNAME..."
  [[ $(scutil --get ComputerName 2>/dev/null)  == "$HOSTNAME" ]] || sudo scutil --set ComputerName  "$HOSTNAME"
  [[ $(scutil --get HostName 2>/dev/null)      == "$HOSTNAME" ]] || sudo scutil --set HostName      "$HOSTNAME"
  [[ $(scutil --get LocalHostName 2>/dev/null) == "$HOSTNAME" ]] || sudo scutil --set LocalHostName "$HOSTNAME"
fi
```

The comparison changes from `scutil --get ComputerName | grep -q "$HOSTNAME"` to exact equality: the old substring match treated `studio` as already-set on a machine named `studio-2`.

Guard `configure.sh:141-152`, **preserving all five original lines** including the `-currentHost` variant:

```zsh
if [[ $HOSTNAME == fenrir ]]; then
  log_info "Configuring trackpad and mouse..."
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
  defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
  defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool true
  defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool true
  log_info "✓ Trackpad configured"
else
  log_info "✓ Trackpad settings skipped (no built-in trackpad on ${HOSTNAME})"
fi
```

Guard line 227 (`defaults write com.apple.menuextra.battery ShowPercent`) the same way, and wrap `:319-327` in `if (( ! AS_PHASE )); then … fi`.

- [ ] **Step 4: Verify green and commit**

```bash
bash .scripts/test-provision.sh
git add .scripts/configure.sh .scripts/test-provision.sh
git commit -m "Teach configure.sh --hostname and --as-phase

With --hostname it validates and never renames. It is provisioning phase 9 —
best-effort and reachable via --phase, which skips the confirm — so a rename there
was the consent gate's back door.

The hostname comparison becomes exact: the old grep -q substring match treated
'studio' as already set on a machine named 'studio-2'.

Trackpad and battery defaults are hostname-guarded, keeping all five original
trackpad lines including the -currentHost variant."
```

---

### Task 11: Documentation and lifecycle

**Files:** `README.md`, `CLAUDE.md`, both design records.

- [ ] **Step 1: Run the full suite, aggregating exit statuses**

```bash
rc=0
for f in .scripts/test-*.sh; do
  case "$f" in
    *test-live-*) continue ;;
    *test-wt-functions.sh) sh="zsh" ;;
    *) sh="bash" ;;
  esac
  out=$("$sh" "$f" 2>&1) || rc=1        # capture the STATUS, not just the tail
  printf '%-40s %s\n' "$f" "$(printf '%s\n' "$out" | grep -E 'RESULT|passed:' | tail -1)"
done
[ "$rc" -eq 0 ] && echo "ALL SUITES GREEN" || echo "AT LEAST ONE SUITE FAILED"
```

`test-reconcile-agents.sh` and `test-ssh-credential-inventory.sh` must run **unsandboxed**; sandboxed they report false failures. Report totals as passed/total, never "N green".

- [ ] **Step 2: Update `README.md`**

Replace the "This will:" list under Quick Start with the four stages; add `.chezmoidata/` and `.chezmoitemplates/` to the structure block; change `homebrew/ # Brewfile` to `Brewfile.tmpl (identity-conditional)`. **Replace the stale "Manual" setup section** — its six steps predate the stage model and would leave a machine with no identity applied.

- [ ] **Step 3: Update `CLAUDE.md`**

Add `test-provision.sh` under `.scripts/`, and `.chezmoidata/` + `.chezmoitemplates/` to the structure. Add:

````markdown
### Adding a Machine

```bash
# 1. Add the name to the allowlist. NOT `chezmoi edit` — .chezmoidata is source
#    metadata, not a target; chezmoi reports it as "not managed".
$EDITOR ~/.local/share/chezmoi/.chezmoidata/machines.toml

# 2. Only if it diverges, add a conditional (this one IS a target)
chezmoi edit ~/.config/homebrew/Brewfile

# 3. Provision it
/bin/zsh -c "$(curl -fsSL .../provision.sh)"
```

An unlisted machine fails every render by design — never add an `else` branch to
work around it. To fix a machine whose identity has drifted:
`provision.sh --repair-identity`.
````

- [ ] **Step 4: Mark both records Implemented**

Set `**Status:** Implemented — MR !N` on **both** the spec and this plan, citing the MR. Both are design records; marking only the spec leaves the plan looking re-runnable.

- [ ] **Step 5: Commit**

```bash
git diff --check    # must be clean; the old plan's trailing whitespace is gone with the rewrite
git add README.md CLAUDE.md docs/superpowers/
git commit -m "Document the provisioning stages and machine allowlist

Marks the provisioning preflight spec and plan Implemented."
```

---

## Self-Review

**Spec coverage.** §2/§4.1 → Task 4 (`NONINTERACTIVE`, bounded CLT wait). §4.2 → Task 5 (markers, confirm-then-mutate, three-field read-back). §4.3/§4.4 → Tasks 7–9. §5.1 → Task 5, assertion "identity is set BEFORE chezmoi init". §5.2 → Tasks 1 and 6 (partial, five outcomes, repair mode). §5.3 → Task 1. §6.1 → Task 3. §6.2 → Task 8. §6.3 → Tasks 3, 5, 6 (flag matrix, `--phase` preconditions, repair state transitions). §7 → Task 10. §8 → distributed; the harness itself is Task 2. §11.1 → Task 5 `validate_identity`. §11.4 → Task 9's report.

**Assertion mapping.** Spec assertions 1→G, 2→G, 3→A, 4→B, 5→D, 6→E, 7→G, 8→H, 9→F, 10→F, 11→A, 12→I, 13→J, 14→N, 15→H/D, 16→J, 17→D, 18→D, 19→D, 20→J.

**Out of scope, recorded not forgotten.** Spec §11.3's two unmanaged Borg keys, and the live Vorta `{hostname}` → literal-name change. Both are credential/backup work needing their own confirmation.

**Type consistency.** Phase functions are `phase_<name>` with hyphens as underscores, derived by `${name//-/_}` in `run_phase`. `validate_identity` is defined in Task 5 and reused by Task 6 and the `--phase` guard. `init_brew_env` is defined in Task 4 and called from the flag block and `--repair-identity`. Markers are `answers_collected`/`confirmed`/`identity_applied` everywhere. `$SELF` replaces `$0` in every user-facing command string.

**Every commit green.** No task adds an assertion a later task satisfies; Task 2's two isolation assertions are explicitly commented out and re-enabled in Task 3 Step 4, which is the only deferred assertion in the plan.
