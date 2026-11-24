#!/usr/bin/env bash
# Mocked test for provision.sh preflight and the machine allowlist.
# Isolation is not optional: provision.sh deletes files under $HOME and rewrites macOS
# defaults, so every run gets a temporary HOME and every temporary XDG root, plus the
# two override points. Run: ./tests/provision.test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0; OUT=""; RC=0
_pass(){ echo "  PASS: $1"; pass=$((pass+1)); }
_fail(){ echo "  FAIL: $1"; fail=$((fail+1)); }
has(){ case "$OUT" in *"$1"*) _pass "$2";; *) _fail "$2";; esac; }
hasnt(){ case "$OUT" in *"$1"*) _fail "$2";; *) _pass "$2";; esac; }
rc_is(){ [ "$RC" -eq "$1" ] && _pass "$2" || _fail "$2 (rc=$RC)"; }
called(){ grep -qF -- "$1" "$CALLS" && _pass "$2" || _fail "$2"; }
not_called(){ grep -qF -- "$1" "$CALLS" && _fail "$2" || _pass "$2"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/provtest.XXXXXX") || { echo "cannot create a temp dir"; exit 2; }
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)                       # /tmp is a symlink to /private/tmp on macOS
# Fail closed. An empty $T would make every path below absolute at the filesystem root,
# and the suite would happily run against it.
[ -n "$T" ] && [ -d "$T" ] || { echo "REFUSING: temp root did not resolve"; exit 2; }
case "$T" in "$HOME"|"$HOME"/*) echo "REFUSING: temp root is inside the real HOME"; exit 2;; esac
mkdir -p "$T"/{bin,home,src/.chezmoidata,src/.scripts,brew/bin}
mkdir -m 755 "$T/managed"                    # not umask-dependent: the installer's walk refuses a 775 root
CALLS="$T/calls"; IDDB="$T/identity"; MUTLOG="$T/refused"; SBX_ROOT="$T"
LAUNCHCTL_LOADED="$T/launchctl-loaded"; : > "$LAUNCHCTL_LOADED"
lc_reset(){ : > "$LAUNCHCTL_LOADED"; rm -rf "$T/home/.local/state/launchagents"; }
cp "$SRC/.chezmoidata/machines.toml" "$T/src/.chezmoidata/"
mkdir -p "$T/src/.git"

# scutil is file-backed so --set really changes what --get returns; without that the
# read-back assertions would pass against a constant and prove nothing.
cat > "$T/bin/scutil" <<'S'
#!/usr/bin/env bash
echo "scutil $*" >> "$CALLS"
case "$1" in
  --get) v=$(sed -n "s/^$2=//p" "$IDDB" 2>/dev/null); [ -n "$v" ] && echo "$v" || echo "$2: not set" ;;
  --set) { grep -v "^$2=" "$IDDB" 2>/dev/null; echo "$2=$3"; } > "$IDDB.n"; mv "$IDDB.n" "$IDDB" ;;
esac; exit 0
S
# sudo must DELEGATE, or `sudo scutil --set` never reaches the scutil stub and the
# identity assertions become vacuous.
cat > "$T/bin/sudo" <<'SU'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALLS"
case "$1" in -v|-n) exit 0 ;; esac
# An absolute command path bypasses PATH stubbing. configure.sh runs
# `sudo /usr/libexec/ApplicationFirewall/socketfilterfw`, which reached the host
# binary through this stub's exec. Refuse anything outside the sandbox.
case "$1" in
  /*) r=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")
      case "$r" in "$SBX_ROOT"|"$SBX_ROOT"/*) ;;
        # Record and DO NOT execute, but exit 0. The scripts under test run with set -e,
        # so failing here truncates them at the first system call -- configure.sh died at
        # `sudo /usr/libexec/.../socketfilterfw` and never reached the later blocks, which
        # silently made every assertion about them vacuous. Containment is unchanged: the
        # command still never runs, and MUTLOG makes the refusal assertable.
        *) echo "SUDO-REFUSED: $1" >> "$MUTLOG"; exit 0 ;; esac ;;
esac
exec "$@"
SU
# fail-brew-bundle fails `brew bundle`; its check then names a missed item on stderr, as Homebrew 7 does.
printf '#!/usr/bin/env bash\necho "brew[$0] $*" >> "$CALLS"\ncase "$1" in shellenv) echo "export PATH=\\"%s/brew/bin:\\$PATH\\"";; --prefix) echo "%s/brew";;\n  bundle) [ -e "$SBX_ROOT/fail-brew-bundle" ] || exit 0; [ "$2" = check ] && echo "→ Cask microsoft-office needs to be installed or updated." >&2; exit 1;; esac\nexit 0\n' "$T" "$T" > "$T/brew/bin/brew"
cp "$T/brew/bin/brew" "$T/bin/brew"
# Homebrew's zsh, which step 10 makes the login shell only when it is installed.
printf '#!/bin/sh\nexec /bin/zsh "$@"\n' > "$T/brew/bin/zsh"
# tee is stubbed because step 10 pipes into `sudo tee -a /etc/shells`; without it the
# delegating sudo reaches the real /etc/shells. Anything the script writes outside the
# temp roots needs a stub here — that is the whole isolation boundary.
# fdesetup is controllable via $FV so both FileVault branches can be exercised.
printf '#!/usr/bin/env bash\necho "fdesetup $*" >> "$CALLS"\necho "FileVault is ${FV:-Off}."\n' > "$T/bin/fdesetup"
printf '#!/usr/bin/env bash\necho "pmset $*" >> "$CALLS"\nexit "${PMSET_RC:-0}"\n' > "$T/bin/pmset"
printf '#!/usr/bin/env bash\necho "csrutil $*" >> "$CALLS"\nexit 0\n' > "$T/bin/csrutil"
for t in op chezmoi git xcode-select mise chsh open curl ssh defaults killall tee; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\nexit 0\n' "$t" > "$T/bin/$t"
done
# osascript and pgrep answer from the environment, so a case can make the Apple Event fail
# ($OSA_RC) or Alfred look running ($PGREP_RC=0; the default is not running).
printf '#!/usr/bin/env bash\necho "osascript $*" >> "$CALLS"\nexit "${OSA_RC:-0}"\n' > "$T/bin/osascript"
printf '#!/usr/bin/env bash\necho "pgrep $*" >> "$CALLS"\nexit "${PGREP_RC:-1}"\n' > "$T/bin/pgrep"
# REUSABLE launchctl stub (the loader and any later case read it): a file of loaded labels
# ($LAUNCHCTL_LOADED, one per line). `print` exits 0 iff the label is listed, `bootstrap` adds
# it unless $LAUNCHCTL_FAIL names it, `bootout` removes it, and every call is logged to
# $CALLS. Like launchd, bootstrap of a loaded label fails with 5, and a run that does not
# pass $LAUNCHCTL_LOADED fails loudly (99) instead of answering from nothing. Nothing reaches
# the host's launchd. Pass it to a run with LAUNCHCTL_LOADED/LAUNCHCTL_FAIL (see run and
# cfg_run); clear it with lc_reset.
cat > "$T/bin/launchctl" <<'L'
#!/usr/bin/env bash
echo "launchctl $*" >> "$CALLS"
[ -n "${LAUNCHCTL_LOADED:-}" ] || { echo "launchctl stub: LAUNCHCTL_LOADED unset" >&2; exit 99; }
verb=$1; target=$2
case "$verb" in
  print)     grep -qx "${target##*/}" "$LAUNCHCTL_LOADED" || exit 1
             if [ -e "$SBX_ROOT/lc-stopped" ]; then echo "state = not running"; else echo "state = running"; fi ;;
  bootstrap) label=$(basename "$3" .plist)
             grep -qx "$label" "$LAUNCHCTL_LOADED" && exit 5
             [ "${LAUNCHCTL_FAIL:-}" = "$label" ] && exit 5
             echo "$label" >> "$LAUNCHCTL_LOADED" ;;
  bootout)   label=${target##*/}
             grep -vx "$label" "$LAUNCHCTL_LOADED" > "$LAUNCHCTL_LOADED.n"; mv "$LAUNCHCTL_LOADED.n" "$LAUNCHCTL_LOADED" ;;
esac
L
# op also logs the app-integration switch it was started with (see section B). 1Password
# authorizes each terminal session and `op whoami` only reports it: with $T/op-signed-out,
# whoami fails until `op signin` has run ($T/op-authorized), or, with $T/op-manual (an account
# added without the app integration), until the session variable signin prints is exported.
# `account list` gives as many empty answers as $T/op-no-account counts; fail-op-signin fails.
cat > "$T/bin/op" <<'O'
#!/usr/bin/env bash
echo "op $*" >> "$CALLS"
echo "op-env OP_BIOMETRIC_UNLOCK_ENABLED=${OP_BIOMETRIC_UNLOCK_ENABLED:-unset}" >> "$CALLS"
case "$1" in
  whoami)  [ -e "$SBX_ROOT/op-signed-out" ] || exit 0
           [ -e "$SBX_ROOT/op-authorized" ] && exit 0
           [ "${OP_SESSION_test:-}" = tok ] && exit 0
           echo "[ERROR] account is not signed in" >&2; exit 1 ;;
  account) n=$(cat "$SBX_ROOT/op-no-account" 2>/dev/null || echo 0)
           if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$SBX_ROOT/op-no-account"; echo '[]'; exit 0; fi
           echo '[{"account_uuid":"A","email":"tester@example.com","url":"my.1password.com","user_uuid":"U"}]' ;;
  signin)  [ -e "$SBX_ROOT/fail-op-signin" ] && exit 1
           if [ -e "$SBX_ROOT/op-manual" ]; then echo 'export OP_SESSION_test="tok"'; else : > "$SBX_ROOT/op-authorized"; fi ;;
esac
exit 0
O
# A fresh machine has no checkout: `git clone` copies the fixture source into the target, so
# the run after it reads the same allowlist and scripts as one with an existing checkout.
cat > "$T/bin/git" <<'G'
#!/usr/bin/env bash
echo "git $*" >> "$CALLS"
case "$*" in *"branch --show-current"*) cat "$SBX_ROOT/branch" 2>/dev/null ;; esac
if [ "$1" = clone ]; then
  for last; do :; done
  mkdir -p "$last" && cp -R "$SBX_ROOT/src/." "$last"
fi
exit 0
G
# Provisioning's own tools. A file named fail-<tool> in $T makes that stub exit 1, so a case can
# make a step fail without a new env var; the stubs read $SBX_ROOT, which every run passes. A file
# named read-stdin-<tool> makes the stub read one line of stdin and fail on EOF: the run feeds
# spare lines, so a step that does not close its stdin gets one and succeeds.
for t in netbird nvim; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\n[ -e "$SBX_ROOT/read-stdin-%s" ] && { read -r _ || exit 1; }\n[ -e "$SBX_ROOT/fail-%s" ] && exit 1\nexit 0\n' "$t" "$t" "$t" > "$T/bin/$t"
done
# `herdr plugin list` prints the file $T/herdr-list (the linked plugins); `plugin link` can fail.
cat > "$T/bin/herdr" <<'H'
#!/usr/bin/env bash
echo "herdr $*" >> "$CALLS"
case "$1 $2" in
  "plugin list") [ -e "$SBX_ROOT/read-stdin-herdr-list" ] && { read -r _ || exit 1; }
                 [ -e "$SBX_ROOT/fail-herdr-list" ] && exit 1; cat "$SBX_ROOT/herdr-list" 2>/dev/null; exit 0 ;;
  "plugin link") [ -e "$SBX_ROOT/read-stdin-herdr-link" ] && { read -r _ || exit 1; }
                 [ -e "$SBX_ROOT/fail-herdr-link" ] && exit 1; exit 0 ;;
esac
exit 0
H
# kern.hv_vmm_present is 1 inside a VM; $HV chooses.
printf '#!/usr/bin/env bash\necho "sysctl $*" >> "$CALLS"\necho "${HV:-0}"\n' > "$T/bin/sysctl"
# chezmoi also logs the marker provisioning sets for its apply; fail-chezmoi-apply fails the apply.
printf '#!/usr/bin/env bash\necho "chezmoi $*" >> "$CALLS"\necho "chezmoi-env DOTFILES_PROVISIONING=${DOTFILES_PROVISIONING:-unset}" >> "$CALLS"\n[ "$1" = apply ] && [ -e "$SBX_ROOT/fail-chezmoi-apply" ] && exit 1\nexit 0\n' > "$T/bin/chezmoi"
# The pin runs the real codex through `codex-daemon real-bin`, under env -i: the stub codex
# cannot read $CALLS from the environment, so its path is baked in, and it logs its whole
# environment (that is what the pin's clean-environment assertions read).
mkdir -p "$T/home/.local/bin" "$T/codexbin"
printf '#!/usr/bin/env bash\necho "codex-daemon $*" >> "$CALLS"\n[ -e "$SBX_ROOT/read-stdin-codex-daemon" ] && { read -r _ || exit 1; }\ncase "$1" in real-bin) echo "%s/codexbin/codex";; esac\nexit 0\n' "$T" > "$T/home/.local/bin/codex-daemon"
# Like the real one, `daemon update` fails until the daemon has selected a package (its link).
printf '#!/usr/bin/env bash\necho "codex $*" >> "%s"\n/usr/bin/env | sed "s/^/codex-env /" >> "%s"\n[ -e "%s/read-stdin-codex" ] && { read -r _ || exit 1; }\n[ -e "%s/fail-codex" ] && exit 1\ncase "$*" in "app-server daemon update"*) [ -L "$HOME/.codex/packages/app-server-daemon/current" ] || { echo "Error: no daemon package is selected" >&2; exit 1; };; esac\nexit 0\n' "$CALLS" "$CALLS" "$T" "$T" > "$T/codexbin/codex"
# sleep returns at once with $T/fast-sleep, except the sudo keep-alive's 60, and with
# $T/mk-current-at-sleep the daemon selects its package (the link) during the first one.
cat > "$T/bin/sleep" <<'SL'
#!/usr/bin/env bash
if [ -e "$SBX_ROOT/fast-sleep" ] && [ "$1" != 60 ]; then
  echo "sleep $*" >> "$CALLS"
  if [ -e "$SBX_ROOT/mk-current-at-sleep" ]; then
    mkdir -p "$HOME/.codex/packages/app-server-daemon"; ln -sfn local-late "$HOME/.codex/packages/app-server-daemon/current"
  fi
  exit 0
fi
exec /bin/sleep "$@"
SL
# getconf is how the pin finds launchd's per-user TMPDIR; fail-getconf makes it print nothing.
printf '#!/usr/bin/env bash\necho "getconf $*" >> "$CALLS"\n[ -e "$SBX_ROOT/fail-getconf" ] && exit 1\necho "$SBX_ROOT/darwin-tmp/"\n' > "$T/bin/getconf"
# Scripts provision.sh calls BY PATH bypass $PATH, so stub them by path.
# reconcile-agents.sh (step 9) is also where a codex plugin step could create the daemon's
# package link, long before step 16: $T/mk-current-early makes the stub do that.
for sc in reconcile-agents.sh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\nif [ -e "$SBX_ROOT/mk-current-early" ]; then mkdir -p "$HOME/.codex/packages/app-server-daemon"; ln -sfn local-early "$HOME/.codex/packages/app-server-daemon/current"; fi\nexit 0\n' "$sc" > "$T/src/.scripts/$sc"
done
# machine-check.sh also records whether its stdin was closed (read-stdin-machine-check).
cat > "$T/src/.scripts/machine-check.sh" <<'MC'
#!/usr/bin/env bash
echo "machine-check.sh $*" >> "$CALLS"
if [ -e "$SBX_ROOT/read-stdin-machine-check" ]; then
  if read -r _; then echo "machine-check-stdin got-input" >> "$CALLS"; else echo "machine-check-stdin eof" >> "$CALLS"; fi
fi
exit 0
MC
# configure.sh is what first loads the Codex daemon's LaunchAgent, whose daemon selects a package
# (its link): the stub makes the link unless $T/no-daemon-package, so a case can tell "before"
# from "after".
cat > "$T/src/.scripts/configure.sh" <<'C'
#!/usr/bin/env bash
echo "configure.sh $*" >> "$CALLS"
echo "configure-env DOTFILES_PROVISIONING=${DOTFILES_PROVISIONING:-unset}" >> "$CALLS"
if [ ! -e "$SBX_ROOT/no-daemon-package" ]; then
  mkdir -p "$HOME/.codex/packages/app-server-daemon"
  ln -sfn local-created "$HOME/.codex/packages/app-server-daemon/current"
fi
exit 0
C
# Mutators are wrapped, not merely logged: they delegate inside the temp root and
# refuse outside it. Logging alone is fail-open -- an unstubbed rm simply runs.
cat > "$T/bin/_mut" <<'M'
#!/usr/bin/env bash
tool=$1; shift
for a in "$@"; do
  case "$a" in -*) continue ;; esac
  r=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$a")
  case "$r" in "$SBX_ROOT"|"$SBX_ROOT"/*) ;;
    *) echo "MUTATOR-REFUSED: $tool $a -> $r" | tee -a "$MUTLOG" >&2; exit 99 ;; esac
done
echo "$tool $*" >> "$CALLS"; exec "/bin/$tool" "$@"
M
chmod +x "$T/bin/_mut"
for t in rm chmod find mv; do
  printf '#!/usr/bin/env bash\nexec "%s/bin/_mut" %s "$@"\n' "$T" "$t" > "$T/bin/$t"
done
chmod +x "$T"/bin/* "$T"/brew/bin/brew "$T"/brew/bin/zsh "$T"/src/.scripts/* "$T/home/.local/bin/codex-daemon" "$T/codexbin/codex"

# Guard the harness against itself. Verifying that a containment assertion CAN fail
# must never be done by pointing an override at the real binary -- that executes it.
# Twice during development this ran the host's Homebrew and advanced its git HEAD.
canon(){ python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
assert_inside(){ local r; r=$(canon "$2")
  case "$r" in "$T"|"$T"/*) ;; *) echo "REFUSING: $1='$2' resolves to '$r', outside $T"; exit 2 ;; esac; }

# A run starts on a machine chezmoi has configured (its config exists) and a terminal 1Password
# has not authorized yet; section B2b removes the config.
reset(){ : > "$CALLS"; : > "$MUTLOG"; printf 'ComputerName=MacBook Pro\nLocalHostName=MacBook-Pro\n' > "$IDDB"
  mkdir -p "$T/home/.config/chezmoi"; : > "$T/home/.config/chezmoi/chezmoi.toml"; rm -f "$T/op-authorized"; }
SBX_SRC="$T/src"; SBX_BREW="$T/brew/bin/brew"
run(){ local ans=$1; shift
  assert_inside PROVISION_BREW_BIN "$SBX_BREW"
  assert_inside PROVISION_SRC_OVERRIDE "$SBX_SRC"
  OUT=$(cd "$T" && printf '%b' "$ans" | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" USER=tester SHELL=/bin/zsh \
    XDG_CACHE_HOME="$T/home/.cache" XDG_CONFIG_HOME="$T/home/.config" \
    XDG_DATA_HOME="$T/home/.local/share" XDG_STATE_HOME="$T/home/.local/state" \
    XDG_BIN_HOME="$T/home/.local/bin" CALLS="$CALLS" IDDB="$IDDB" \
    MUTLOG="$MUTLOG" SBX_ROOT="$SBX_ROOT" \
    LAUNCHCTL_LOADED="$LAUNCHCTL_LOADED" LAUNCHCTL_FAIL="${LAUNCHCTL_FAIL:-}" \
    PROVISION_REF="${PROVISION_REF:-}" HV="${HV:-0}" HERDR_PANE_ID=pane-test HERDR_SOCKET_PATH="$T/herdr.sock" TMPDIR="$T/caller-tmp" \
    PROVISION_SRC_OVERRIDE="$SBX_SRC" PROVISION_BREW_BIN="$SBX_BREW" \
    zsh "$SRC/.scripts/provision.sh" "$@" 2>&1); RC=$?; }

echo "A. containment"
REAL_HOME="$HOME"
reset; run 'hercules\ny\n'
# Which brew actually ran. The old assertion grepped the stub log for "/opt/homebrew",
# which the real brew would never write to -- it could not fail.
if grep -q "brew\[$T/brew/bin/brew\]" "$CALLS"; then _pass "PROVISION_BREW_BIN is honoured (sandbox brew ran)"
else _fail "PROVISION_BREW_BIN is honoured (sandbox brew ran)"; fi
not_called "brew[/opt/homebrew/bin/brew]" "the real Homebrew binary is never the one invoked"
# Every stubbed call's paths stay inside the temp roots. This observes only what the
# stubs see; an unstubbed binary would not appear here, which is why the stub list
# above must cover everything the script can reach.
if grep -F "$REAL_HOME/" "$CALLS" | grep -vF "$T" | head -1 | grep -q .; then
  _fail "no call targets the real HOME: $(grep -F "$REAL_HOME/" "$CALLS" | grep -vF "$T" | head -1)"
else _pass "no call targets the real HOME"; fi
[ -s "$MUTLOG" ] && _fail "no mutator was refused: $(head -1 "$MUTLOG")" || _pass "no mutator attempted to leave the temp root"

echo "B. preflight asks first, then applies"
reset; run 'hercules\ny\n'
called "scutil --set ComputerName hercules"  "ComputerName is set"
called "scutil --set HostName hercules"      "HostName is set (Borg reads this)"
called "scutil --set LocalHostName hercules" "LocalHostName is set"
grep -q '^ComputerName=hercules$' "$IDDB" && _pass "the identity really changed" || _fail "the identity really changed"
# Regression: provisioning runs before zshenv exists, so on macOS 27.2 op could not see the
# 1Password app integration and the 1Password gate polled for 15 minutes.
called "op-env OP_BIOMETRIC_UNLOCK_ENABLED=true" "op runs with the 1Password app integration on"
not_called "op-env OP_BIOMETRIC_UNLOCK_ENABLED=unset" "no op call runs without it"

echo "B2. a fresh machine inits and applies; one whose checkout existed does neither"
# This runs in zsh as a script, so the chezmoi wrapper (origin's main only) is not loaded and
# init/apply would deploy the working tree of a checkout the sandbox may have changed.
SBX_SRC="$T/fresh"; rm -rf "$SBX_SRC"
reset; run 'hercules\ny\n'
called "git clone" "a fresh machine clones the dotfiles"
called "chezmoi init" "a fresh machine runs chezmoi init"
called "chezmoi apply --force" "a fresh machine applies"
la=$(grep -n "scutil --set ComputerName" "$CALLS" | head -1 | cut -d: -f1)
lb=$(grep -n "chezmoi init" "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; } && _pass "identity is set before chezmoi init" || _fail "identity is set before chezmoi init"
# The first apply runs modify_ scripts whose jq programs the system jq (1.7.1) rejects: the second
# VM run (2026-11-24) stopped there with "chezmoi: .claude/settings.json: exit status 3".
lj=$(grep -nE '^brew\[[^]]*\] install( [^ ]+)* jq( |$)' "$CALLS" | head -1 | cut -d: -f1)
lp=$(grep -n '^chezmoi apply' "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$lj" ] && [ -n "$lp" ] && [ "$lj" -lt "$lp" ]; } && _pass "Homebrew's jq is installed before the first apply" || _fail "Homebrew's jq is installed before the first apply"
hasnt "already provisioned" "a fresh machine is not told it is already provisioned"
SBX_SRC="$T/src"
reset; run 'hercules\ny\n'
rc_is 0 "a machine with an existing checkout still finishes"
not_called "git clone" "an existing checkout is not cloned again"
not_called "chezmoi init" "an existing checkout is not initialised from the working tree"
not_called "chezmoi apply" "an existing checkout is not applied from the working tree"
has "already provisioned" "the skip is announced"
has "chezmoi apply --init" "and Michael is pointed at the wrapper's command"
called "scutil --set ComputerName hercules" "the rest of the run still happens"
called "configure.sh --hostname hercules" "including the macOS configuration"

ls -d "$T"/src.earlier-* >/dev/null 2>&1 && _fail "a configured machine's checkout stays where it is" || _pass "a configured machine's checkout stays where it is"

echo "B2b. a checkout an earlier run left before chezmoi ran is moved aside and cloned afresh"
# The first VM run (2026-11-24) stopped at the 1Password wait after cloning; its retry skipped
# chezmoi for good, so nothing was deployed. No chezmoi config means chezmoi never ran here. The
# left checkout is never applied: git status cannot vouch for the files chezmoi reads.
rm -rf "$T/left" "$T"/left.earlier-*; cp -R "$T/src" "$T/left"; echo planted > "$T/left/run_planted.log"
SBX_SRC="$T/left"
reset; rm -f "$T/home/.config/chezmoi/chezmoi.toml"; run 'hercules\ny\n'
rc_is 0 "a never-applied checkout's retry finishes"
moved=$(ls -d "$T"/left.earlier-* 2>/dev/null | head -1)
[ -n "$moved" ] && [ -f "$moved/run_planted.log" ] && _pass "the left checkout is moved aside, whole" || _fail "the left checkout is moved aside, whole"
[ ! -e "$T/left/run_planted.log" ] && _pass "nothing of it stays in the source chezmoi applies" || _fail "nothing of it stays in the source chezmoi applies"
called "git clone --branch main" "the source is cloned afresh"
called "chezmoi init" "the fresh clone is initialised"
called "chezmoi apply --force" "and applied"
hasnt "already provisioned" "it is not called provisioned"
has "⚠ An earlier run's checkout, which chezmoi never finished applying, is now $moved" "the closing list says where the old checkout went"
gl=$(grep -n '^git clone' "$CALLS" | head -1 | cut -d: -f1); ml=$(grep -n "^mv $T/left " "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$ml" ] && [ -n "$gl" ] && [ "$ml" -lt "$gl" ]; } && _pass "moved before the clone" || _fail "moved before the clone"
rm -rf "$T/left" "$T"/left.earlier-*
# chezmoi's state shows it applied here even when its config was deleted: the checkout, and the
# wt siblings whose .git files point into it, stay where they are.
cp -R "$T/src" "$T/left"; : > "$T/home/.config/chezmoi/chezmoistate.boltdb"
reset; rm -f "$T/home/.config/chezmoi/chezmoi.toml"; run 'hercules\ny\n'
ls -d "$T"/left.earlier-* >/dev/null 2>&1 && _fail "an applied machine without its config keeps its checkout" || _pass "an applied machine without its config keeps its checkout"
not_called "git clone" "and nothing is cloned over it"
rm -rf "$T/left" "$T"/left.earlier-* "$T/home/.config/chezmoi/chezmoistate.boltdb"
SBX_SRC="$T/src"

echo "B2c. a run whose apply failed: the retry moves its clone aside and applies a fresh one"
# The second VM run (2026-11-24): the first apply failed after chezmoi init had written its config
# and the apply its state, so the retry took the clone for a provisioned machine and skipped chezmoi.
SBX_SRC="$T/failed"; rm -rf "$SBX_SRC" "$T"/failed.earlier-*
: > "$T/fail-chezmoi-apply"
reset; run 'hercules\ny\n'
[ "$RC" -ne 0 ] && _pass "a failed apply ends the run" || _fail "a failed apply ends the run"
rm -f "$T/fail-chezmoi-apply"
# What chezmoi init and the partial apply left behind.
: > "$T/home/.config/chezmoi/chezmoistate.boltdb"
reset; run 'hercules\ny\n'
rc_is 0 "the retry finishes"
moved=$(ls -d "$T"/failed.earlier-* 2>/dev/null | head -1)
[ -n "$moved" ] && _pass "the clone the failed apply left is moved aside" || _fail "the clone the failed apply left is moved aside"
called "git clone" "the source is cloned afresh"
called "chezmoi apply --force" "and applied"
hasnt "already provisioned" "the retry is not called provisioned"
# A finished apply leaves an ordinary checkout: the next run keeps it.
reset; run 'hercules\ny\n'
[ "$(ls -d "$T"/failed.earlier-* 2>/dev/null | wc -l)" -eq 1 ] && _pass "after a finished apply the next run keeps the checkout" || _fail "after a finished apply the next run keeps the checkout"
not_called "chezmoi apply" "and applies nothing from it"
# A checkout with wt siblings is in use, mark or not (an apply by hand, which leaves the mark, then
# wt lines): moving it would break every sibling's link into its .git.
rm -rf "$SBX_SRC" "$T"/failed.earlier-*
cp -R "$T/src" "$SBX_SRC"; : > "$SBX_SRC/.git/provision-unapplied"; mkdir -p "$SBX_SRC/.git/worktrees/failed-feat-x"
reset; run 'hercules\ny\n'
ls -d "$T"/failed.earlier-* >/dev/null 2>&1 && _fail "a marked checkout with wt siblings stays where it is" || _pass "a marked checkout with wt siblings stays where it is"
not_called "git clone" "and nothing is cloned over it"
reset; rm -f "$T/home/.config/chezmoi/chezmoi.toml" "$T/home/.config/chezmoi/chezmoistate.boltdb"; run 'hercules\ny\n'
ls -d "$T"/failed.earlier-* >/dev/null 2>&1 && _fail "so does one without chezmoi's config and state" || _pass "so does one without chezmoi's config and state"
rm -rf "$SBX_SRC" "$T"/failed.earlier-* "$T/home/.config/chezmoi/chezmoistate.boltdb"
SBX_SRC="$T/src"

echo "B3. 1Password: the run signs the CLI in, in its own terminal session"
# 1Password authorizes each terminal session and op whoami only reports it, so a run that only
# polled whoami waited out its 15 minutes on a fresh machine (the VM run of 2026-11-24).
: > "$T/op-signed-out"
reset; run 'hercules\ny\n'
rc_is 0 "a signed-out terminal finishes"
called "op signin" "the run signs in itself"
ql=$(grep -n '^op account list' "$CALLS" | head -1 | cut -d: -f1); sl=$(grep -n '^op signin' "$CALLS" | head -1 | cut -d: -f1)
il=$(grep -n 'scutil --set ComputerName' "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$ql" ] && [ -n "$sl" ] && [ "$ql" -lt "$sl" ]; } && _pass "once op sees an account" || _fail "once op sees an account"
{ [ -n "$sl" ] && [ -n "$il" ] && [ "$sl" -lt "$il" ]; } && _pass "before anything changes" || _fail "before anything changes"
has "✓ 1Password CLI authenticated" "and says so"
echo 1 > "$T/op-no-account"
reset; run 'hercules\ny\n'
[ "$(grep -c '^op account list' "$CALLS")" -ge 2 ] && _pass "it waits while op sees no account" || _fail "it waits while op sees no account"
called "op signin" "then signs in"
: > "$T/op-manual"
reset; run 'hercules\ny\n'
rc_is 0 "an account added without the app integration signs in too"
has "✓ 1Password CLI authenticated" "with the session op signin prints"
rm -f "$T/op-manual"
: > "$T/fail-op-signin"
reset; run 'hercules\ny\n'
rc_is 1 "a refused sign-in ends the run"
has "1Password CLI sign-in failed" "and says so"
not_called "scutil --set" "before anything changes"
rm -f "$T/fail-op-signin" "$T/op-signed-out" "$T/op-no-account"
reset; run 'hercules\ny\n'
not_called "op signin" "a terminal already signed in is not asked again"

echo "C. consent gates the rename"
reset; run 'hercules\nn\n'
rc_is 1 "declining aborts"
not_called "scutil --set" "declining renames nothing"
grep -q '^ComputerName=MacBook Pro$' "$IDDB" && _pass "identity untouched after decline" || _fail "identity untouched after decline"

echo "D. allowlist"
reset; run 'nosuchmachine\nhercules\ny\n'
has "Unknown machine" "an unlisted name is refused"
not_called "scutil --set ComputerName nosuchmachine" "the refused name is never applied"

echo "E. unattended boundary"
reset; run 'hercules\ny\n'
called "sudo chsh" "chsh goes through the cached sudo credential"
# Substring matching cannot tell "chsh -s" from "sudo chsh -s". Count instead: sudo
# delegates, so a chsh reached through sudo logs both lines. Equal counts mean every
# invocation went through sudo; an excess chsh line means one was called bare.
n_chsh=$(grep -c '^chsh ' "$CALLS" || true); n_sudo_chsh=$(grep -c '^sudo chsh ' "$CALLS" || true)
[ "$n_chsh" = "$n_sudo_chsh" ] && _pass "no chsh call bypasses sudo" \
  || _fail "no chsh call bypasses sudo (chsh=$n_chsh via-sudo=$n_sudo_chsh)"
called "StrictHostKeyChecking=accept-new" "the SSH check cannot block on a host key"
called "configure.sh --hostname hercules" "configure.sh is told the identity, not asked"
has "⚠ Brewfile not found" "a missing Brewfile is in the closing list"
# The second VM run's closing list said only "brew bundle did not complete": Homebrew 7 writes the
# items `brew bundle check` misses to stderr, which the run threw away.
mkdir -p "$T/home/.config/homebrew"; : > "$T/home/.config/homebrew/Brewfile"; : > "$T/fail-brew-bundle"
reset; run 'hercules\ny\n'
rc_is 0 "a run whose brew bundle fails finishes"
has "⚠ brewfile: Cask microsoft-office needs to be installed or updated." "the closing list names each item brew bundle missed"
rm -rf "$T/home/.config/homebrew" "$T/fail-brew-bundle"
# The first VM run deployed no Brewfile, then pointed the login shell at a zsh that did not
# exist, so no new terminal could start.
mv "$T/brew/bin/zsh" "$T/brew-zsh.off"
reset; run 'hercules\ny\n'
rc_is 0 "a run without Homebrew's zsh finishes"
not_called "chsh" "the login shell is not pointed at a missing zsh"
not_called "/etc/shells" "nor is the missing zsh added to /etc/shells"
has "⚠ Homebrew zsh is not installed" "the closing list says so"
hasnt "exec $T/brew/bin/zsh" "and the next steps do not offer to exec it"
mv "$T/brew-zsh.off" "$T/brew/bin/zsh"

echo "F. identity guard in Brewfile.tmpl"
mkdir -p "$T/tbin"
printf '#!/bin/sh\ncase "$2" in ComputerName) echo "$FCN";; HostName) echo "$FHN";; esac\n' > "$T/tbin/scutil"
chmod +x "$T/tbin/scutil"
render(){ printf '[data]\n  hostname = "%s"\n' "$1" > "$T/c.toml"
  OUT=$(FCN="$1" FHN="$2" PATH="$T/tbin:$PATH" chezmoi execute-template --source "$SRC" \
        --config "$T/c.toml" --file "$SRC/dot_config/homebrew/Brewfile.tmpl" 2>&1); RC=$?; }
render fenrir fenrir
rc_is 0 "matching identity renders"
has 'cask "elgato-control-center"' "fenrir gets the peripheral casks"
has 'cask "herdr-app"' "fenrir gets the Herdr app"
has 'tap "openai/tools", trusted: true' "fenrir taps the Tart formula's repository"
has 'brew "openai/tools/tart"' "fenrir gets Tart for the reinstall test VM"
render hercules hercules
rc_is 0 "the other machine renders"
hasnt 'tap "openai/tools"' "hercules does not tap the Tart repository"
hasnt 'brew "openai/tools/tart"' "hercules does not get Tart"
hasnt 'cask "elgato-control-center"' "hercules does not get the peripheral casks"
has 'cask "herdr-app"' "hercules gets the Herdr app"
has 'cask "azure-cli"' "azure-cli is a cask (homebrew-core dropped the formula)"
hasnt 'brew "azure-cli"' "azure-cli is not declared as a formula"
render "MacBook Pro" "MacBook Pro"
rc_is 1 "an unlisted machine fails the render"
has "unknown machine" "unlisted machine is named"
render fenrir hercules
rc_is 1 "ComputerName/HostName mismatch fails"
has "identity mismatch" "the mismatch is reported as such"
render fenrir "HostName: not set"
rc_is 1 "unset HostName fails"
has "HostName is unset" "unset HostName gets its own message"

echo "G. configure.sh identity validation (the real script, not a stub)"
# The harness stubs configure.sh for provision.sh's benefit, so its own validation was
# never exercised: deleting the HostName check left every assertion green. These call
# the real script. Mismatches exit before configure.sh touches anything.
# The only thing keeping this real configure.sh run away from /Library and the REAL sudo is
# CLAUDE_MANAGED_SETTINGS_TEST_ROOT in the env -i list below. The sudo stub never sees the
# installer, which calls /usr/bin/sudo by absolute path; section K asserts the redirect.
# cfg_run feeds stdin ($1) and the configure.sh arguments after it. $CFG_DATA, when set, is
# XDG_DATA_HOME (where configure.sh looks for the chezmoi checkout's backgrounds).
cfg_run(){ local ans=$1; shift
  OUT=$(cd "$T" && printf '%b' "$ans" | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" USER=tester \
        FV="${FV:-Off}" PMSET_RC="${PMSET_RC:-0}" OSA_RC="${OSA_RC:-0}" PGREP_RC="${PGREP_RC:-1}" \
        LAUNCHCTL_LOADED="$LAUNCHCTL_LOADED" LAUNCHCTL_FAIL="${LAUNCHCTL_FAIL:-}" XDG_DATA_HOME="${CFG_DATA:-}" \
        CALLS="$CALLS" IDDB="$IDDB" MUTLOG="$MUTLOG" SBX_ROOT="$SBX_ROOT" CLAUDE_MANAGED_SETTINGS_TEST_ROOT="$T/managed" \
        zsh "$SRC/.scripts/configure.sh" "$@" 2>&1); RC=$?; }
cfg(){ printf 'ComputerName=%s\nHostName=%s\nLocalHostName=%s\n' "$1" "$2" "$3" > "$IDDB"
  cfg_run '' --hostname "$4"; }
# An attended run: no --hostname, so configure.sh asks for the name on stdin.
cfg_attended(){ printf 'ComputerName=%s\nHostName=%s\nLocalHostName=%s\n' "$1" "$1" "$1" > "$IDDB"
  cfg_run "$1\ny\n"; }
cfg fenrir fenrir fenrir fenrir
has "identity verified" "matching identity passes validation"
# `rc_is 1` alone is NOT discriminating here: configure.sh exits 1 for plenty of
# unrelated reasons once it gets past validation. Deleting the HostName check left
# every assertion green until these keyed on "identity verified" NOT being reached.
cfg hercules fenrir fenrir fenrir
hasnt "identity verified" "ComputerName mismatch stops before verification"
has "ComputerName is" "the ComputerName error names the field"
cfg fenrir hercules fenrir fenrir
hasnt "identity verified" "HostName mismatch stops before verification"
has "HostName is" "the HostName error names the field"
cfg fenrir fenrir hercules fenrir
hasnt "identity verified" "LocalHostName mismatch stops before verification"
has "LocalHostName is" "the LocalHostName error names the field"
cfg fenrir fenrir fenrir-3 fenrir
has "identity verified" "a Bonjour numeric suffix on LocalHostName is accepted"

echo "H. containment during the real configure.sh run"
: > "$MUTLOG"; cfg fenrir fenrir fenrir fenrir
grep -q 'SUDO-REFUSED: /usr/libexec/ApplicationFirewall' "$MUTLOG" \
  && _pass "the firewall call is refused, not executed on the host" \
  || _fail "the firewall call is refused, not executed on the host"

echo "I. Universal Control is per-machine"
cfg fenrir fenrir fenrir fenrir
hasnt "Disabling Universal Control" "fenrir keeps Universal Control (pairs with the iPad)"
has   "Leaving Universal Control enabled" "and says so"
cfg hercules hercules hercules hercules
has   "Disabling Universal Control" "hercules disables it (conflicts with Screen Sharing)"

echo "J. FileVault expectation and autorestart are per-machine"
FV=On  cfg fenrir fenrir fenrir fenrir
has   "FileVault is enabled"        "fenrir with FileVault on is correct"
FV=Off cfg fenrir fenrir fenrir fenrir
has   "FileVault is OFF"            "fenrir without FileVault is flagged (it travels)"
FV=Off cfg hercules hercules hercules hercules
has   "FileVault is off (intended"  "hercules without FileVault is correct"
FV=On  cfg hercules hercules hercules hercules
has   "FileVault is ON on hercules" "hercules WITH FileVault is flagged"
has   "fdesetup disable"            "and the remedy is named"
FV=Off
: > "$CALLS"; cfg hercules hercules hercules hercules
called "pmset -a autorestart 1 sleep 0 womp 1" "hercules enables restart-after-power-loss, no sleep and wake-on-network"
: > "$CALLS"; cfg fenrir fenrir fenrir fenrir
not_called "pmset" "fenrir sets no power setting (it has a battery and a lid)"
# A VM can reject a pmset key; under set -e that must not end configure.sh.
: > "$CALLS"; PMSET_RC=1 cfg hercules hercules hercules hercules
called "pmset -a autorestart 1 sleep 0 womp 1" "a failing pmset is still attempted"
has "pmset -a autorestart 1 sleep 0 womp 1 failed" "and the warning names the command"
has "macOS configuration complete" "and configure.sh still completes"

echo "K. configure.sh installs the Claude Code managed policy"
rm -rf "$T/managed/ClaudeCode"; cfg fenrir fenrir fenrir fenrir
has "✓ Claude Code managed policy in place" "the managed policy is installed"
has "installed: $T/managed/ClaudeCode/managed-settings.json" "the policy went to the scratch root"
hasnt "/Library/Application Support/ClaudeCode" "the first run stays out of /Library"
cmp -s "$T/managed/ClaudeCode/managed-settings.json" "$SRC/.scripts/claude-managed-settings.json" \
  && _pass "the installed policy is the repo's policy" || _fail "the installed policy is the repo's policy"
printf '%s\n' '{"pluginConfigs":{}}' > "$T/managed/ClaudeCode/managed-settings.json"
cfg fenrir fenrir fenrir fenrir
has "Claude Code managed policy NOT installed" "a different existing policy is refused, not replaced"
[ "$(cat "$T/managed/ClaudeCode/managed-settings.json")" = '{"pluginConfigs":{}}' ] \
  && _pass "the refused policy file is untouched" || _fail "the refused policy file is untouched"
has "Configuring keyboard settings" "a refusal does not stop configure.sh"
hasnt "/Library/Application Support/ClaudeCode" "the refused run stays out of /Library"

echo "L. configure.sh with and without LaunchAgents plists"
# zsh's nomatch turns an empty be.netronix.*.plist glob into a fatal error under set -e.
# The probe label is one this checkout has a template for: the loader skips any it lacks.
mkdir -p "$T/home/Library/LaunchAgents"; rm -f "$T/home/Library/LaunchAgents"/be.netronix.*.plist
cfg fenrir fenrir fenrir fenrir
has   "macOS configuration complete" "no LaunchAgents plists: configure.sh still completes"
hasnt "no matches found" "and the empty glob is not an error"
: > "$T/home/Library/LaunchAgents/be.netronix.codex-memory-share.plist"; : > "$CALLS"
cfg fenrir fenrir fenrir fenrir
has    "macOS configuration complete" "a plist present: configure.sh completes"
called "launchctl bootstrap gui/" "and the plist is bootstrapped through the stubbed launchctl"
has    "loaded be.netronix.codex-memory-share" "and reported loaded"
grep -qx be.netronix.codex-memory-share "$LAUNCHCTL_LOADED" && _pass "the file-backed launchctl now lists it" \
  || _fail "the file-backed launchctl now lists it"
: > "$CALLS"; cfg fenrir fenrir fenrir fenrir
has    "unchanged be.netronix.codex-memory-share" "a second run finds it unchanged"
not_called "launchctl bootout" "and boots nothing out"
not_called "launchctl bootstrap" "and bootstraps nothing"
rm -f "$T/home/Library/LaunchAgents/be.netronix.codex-memory-share.plist"; lc_reset
: > "$T/home/Library/LaunchAgents/be.netronix.codex-memory-share.plist"; : > "$CALLS"
LAUNCHCTL_FAIL=be.netronix.codex-memory-share cfg fenrir fenrir fenrir fenrir
has    "could not load be.netronix.codex-memory-share" "a job that fails to load is reported by the loader"
has    "Some LaunchAgents did not load" "and configure.sh warns, naming what to re-run"
has    "macOS configuration complete" "and still completes"
rm -f "$T/home/Library/LaunchAgents/be.netronix.codex-memory-share.plist"; lc_reset
# The loader loads only a plist the source (here this checkout) still has: chezmoi leaves a
# removed template's deployed file behind.
: > "$T/home/Library/LaunchAgents/be.netronix.removed-job.plist"; : > "$CALLS"
cfg fenrir fenrir fenrir fenrir
has    "skipped be.netronix.removed-job: not in the source" "a deployed plist the source does not have is reported skipped"
not_called "launchctl bootstrap" "and is not bootstrapped"
has    "macOS configuration complete" "and configure.sh completes"
rm -f "$T/home/Library/LaunchAgents/be.netronix.removed-job.plist"; lc_reset

echo "M. the unattended run sends no Apple Event; an attended one survives a refusal"
# The wallpaper needs the chezmoi checkout's backgrounds; Alfred's block needs its prefs.json.
# Both exist, so only the unattended skip keeps osascript out of the log.
mkdir -p "$T/home/.local/share/chezmoi/.backgrounds" "$T/home/Library/Application Support/Alfred"
: > "$T/home/.local/share/chezmoi/.backgrounds/skyline-appartment.png"
printf '{"localhash": "abc123"}\n' > "$T/home/Library/Application Support/Alfred/prefs.json"
CFG_DATA="$T/home/.local/share"
: > "$CALLS"; PGREP_RC=0 cfg fenrir fenrir fenrir fenrir
rc_is 0 "--hostname with Alfred running completes"
not_called "osascript" "--hostname: no osascript call, wallpaper or Alfred"
has "Skipping the wallpaper" "the wallpaper skip is announced"
has "Skipping the Alfred toggle" "the Alfred skip is announced"
called "pgrep -x Alfred" "the Alfred skip is decided by a running Alfred"
: > "$CALLS"; cfg fenrir fenrir fenrir fenrir
not_called "osascript" "--hostname with Alfred not running: still no osascript call"
: > "$CALLS"; OSA_RC=1 cfg_attended fenrir
rc_is 0 "an attended run whose wallpaper Apple Event fails still exits 0"
called "osascript -e tell application \"System Events\"" "the attended run does try the wallpaper"
has "macOS configuration complete" "and still completes"
has "Could not set the desktop wallpaper" "and warns about the wallpaper"
hasnt "Skipping the wallpaper" "and does not claim to have skipped it"
CFG_DATA=; rm -rf "$T/home/.local/share/chezmoi" "$T/home/Library/Application Support"

echo "N. NetBird's daemon is installed once"
reset; lc_reset; run 'hercules\ny\n'
rc_is 0 "a run with no NetBird daemon finishes"
called "sudo netbird service install" "an absent NetBird daemon is installed through the cached sudo credential"
called "sudo netbird service start" "and started"
called "launchctl print system/netbird" "absence is read from launchd"
reset; echo netbird > "$LAUNCHCTL_LOADED"; run 'hercules\ny\n'
not_called "netbird service" "a NetBird daemon launchd already lists is left alone"
lc_reset
reset; echo netbird > "$LAUNCHCTL_LOADED"; : > "$T/lc-stopped"; run 'hercules\ny\n'
rm -f "$T/lc-stopped"; lc_reset
rc_is 0 "a NetBird daemon installed but not running finishes"
called "sudo netbird service start" "is started"
not_called "netbird service install" "and not installed again"
reset; echo netbird > "$LAUNCHCTL_LOADED"; : > "$T/lc-stopped"; : > "$T/fail-netbird"; run 'hercules\ny\n'
rm -f "$T/lc-stopped" "$T/fail-netbird"; lc_reset
rc_is 0 "a failing NetBird start does not end the run"
has "run: sudo netbird service start" "and the warning names the command"
reset; : > "$T/fail-netbird"; run 'hercules\ny\n'
rm -f "$T/fail-netbird"
rc_is 0 "a failing NetBird install does not end the run"
has "sudo netbird service install && sudo netbird service start" "and the warning names the two commands"

echo "O. Neovim plugins and Herdr plugin links"
CFG="$T/home/.config"; NVL="$T/home/.local/share/nvim/lazy/smart-splits.nvim"
mkdir -p "$CFG/herdr/plugin-a" "$CFG/herdr/plugin-b" "$CFG/herdr/plugin-c" "$NVL"
: > "$CFG/herdr/plugin-a/herdr-plugin.toml"; : > "$CFG/herdr/plugin-b/herdr-plugin.toml"; : > "$NVL/herdr-plugin.toml"
printf '2 plugins installed:\n- b (B) enabled [local:%s/herdr/plugin-b]\n  config: x\n' "$CFG" > "$T/herdr-list"
reset; run 'hercules\ny\n'
called "nvim --headless +Lazy! install +qa" "Neovim installs its plugins headless"
called "herdr plugin link $CFG/herdr/plugin-a" "an unlinked plugin folder is linked"
called "herdr plugin link $NVL" "smart-splits.nvim's bundled plugin is linked"
not_called "herdr plugin link $CFG/herdr/plugin-b" "a folder whose [local:<dir>] is already listed is not linked again"
not_called "herdr plugin link $CFG/herdr/plugin-c" "a folder without a manifest is not linked"
nl=$(grep -n '^nvim ' "$CALLS" | head -1 | cut -d: -f1); hl=$(grep -n '^herdr plugin link' "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$nl" ] && [ -n "$hl" ] && [ "$nl" -lt "$hl" ]; } && _pass "Neovim installs before the links" || _fail "Neovim installs before the links"
ml=$(grep -n '^mise ' "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$ml" ] && [ "$ml" -lt "$nl" ]; } && _pass "and after mise" || _fail "and after mise"
printf '3 plugins installed:\n- a (A) enabled [local:%s/herdr/plugin-a]\n- b (B) enabled [local:%s/herdr/plugin-b]\n- s (S) enabled [local:%s]\n' "$CFG" "$CFG" "$NVL" > "$T/herdr-list"
reset; run 'hercules\ny\n'
not_called "herdr plugin link" "every plugin already listed: no link at all"
printf '0 plugins installed\n' > "$T/herdr-list"; rm -rf "$NVL"
reset; : > "$T/fail-herdr-link"; run 'hercules\ny\n'
rm -f "$T/fail-herdr-link"
rc_is 0 "a failing link does not end the run"
has "herdr plugin link $CFG/herdr/plugin-a" "and the warning names the command to re-run"
called "herdr plugin link $CFG/herdr/plugin-b" "and the next plugin is still tried"
not_called "herdr plugin link $NVL" "a smart-splits.nvim that was never installed is not linked"
reset; : > "$T/fail-nvim"; run 'hercules\ny\n'
rm -f "$T/fail-nvim"
rc_is 0 "a failing Neovim install does not end the run"
has "Lazy! install" "and the warning names the command"
called "herdr plugin link $CFG/herdr/plugin-a" "and the links still happen"
reset; : > "$T/fail-herdr-list"; run 'hercules\ny\n'
rm -f "$T/fail-herdr-list"
rc_is 0 "a herdr that cannot list plugins does not end the run"
not_called "herdr plugin link" "and links nothing it cannot check"
rm -rf "$CFG/herdr" "$T/herdr-list" "$T/home/.local/share/nvim"

echo "P. the Codex pin runs only on a machine with no daemon package"
PKG="$T/home/.codex/packages/app-server-daemon"
PIN="codex app-server daemon update --from-cli --yes"
rm -rf "$T/home/.codex"; reset; run 'hercules\ny\n'
rc_is 0 "a fresh machine finishes"
called "$PIN" "a machine with no daemon package is pinned to the CLI's package"
called "codex-daemon real-bin" "through the real binary codex-daemon names, not a bare codex"
cl=$(grep -n 'configure.sh --hostname' "$CALLS" | head -1 | cut -d: -f1); pl=$(grep -n "^$PIN" "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$cl" ] && [ -n "$pl" ] && [ "$cl" -lt "$pl" ]; } && _pass "after configure.sh" || _fail "after configure.sh"
called "codex-env HOME=$T/home" "the pin has HOME"
called "codex-env PATH=$T/home/.local/share/mise/shims:$T/home/.local/bin:$T/brew/bin:$T/brew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "and the LaunchAgent's PATH"
called "codex-env USER=tester" "and USER"
called "codex-env LOGNAME=" "and LOGNAME (zsh fills one in for a caller that had none)"
called "codex-env SHELL=/bin/zsh" "and SHELL"
called "codex-env TMPDIR=$T/darwin-tmp/" "and launchd's per-user TMPDIR from getconf"
for v in CONFIG:.config DATA:.local/share STATE:.local/state CACHE:.cache; do
  called "codex-env XDG_${v%%:*}_HOME=$T/home/${v#*:}" "and XDG_${v%%:*}_HOME"
done
not_called "codex-env HERDR_" "and no HERDR_* variable, though the caller's pane set some"
not_called "codex-env CALLS=" "and nothing else of the caller's environment"
rm -rf "$T/home/.codex"; : > "$T/fail-getconf"; reset; run 'hercules\ny\n'
rm -f "$T/fail-getconf"
called "codex-env TMPDIR=$T/caller-tmp" "a getconf that prints nothing falls back to the caller's TMPDIR"
rm -rf "$T/home/.codex"; reset; run 'hercules\ny\n'
called "$PIN" "a daemon package configure.sh itself created does not stop the pin: it is read at the start"
rm -rf "$T/home/.codex"; : > "$T/mk-current-early"; reset; run 'hercules\ny\n'
rm -f "$T/mk-current-early"
called "reconcile-agents.sh" "a package link made by step 9, long before step 16, is on disk by the time of the pin"
called "$PIN" "and still does not stop the pin: a fresh machine is read before step 1"
rm -rf "$T/home/.codex"; : > "$T/fail-codex"; reset; run 'hercules\ny\n'
rm -f "$T/fail-codex"
rc_is 0 "a failing pin does not end the run"
has "codex app-server daemon update --from-cli --yes" "and the warning names the manual command"
# The third VM run: the daemon launchd had just started selected its package only after the pin
# had run, and "no daemon package is selected" left the machine unpinned for good.
rm -rf "$T/home/.codex"; : > "$T/no-daemon-package"; : > "$T/fast-sleep"; : > "$T/mk-current-at-sleep"
reset; run 'hercules\ny\n'
rm -f "$T/mk-current-at-sleep"
called "$PIN" "the pin waits until the daemon has selected its package"
hasnt "codex daemon not pinned" "and then pins it"
rm -rf "$T/home/.codex"; reset; run 'hercules\ny\n'
rm -f "$T/fast-sleep" "$T/no-daemon-package"
rc_is 0 "a daemon that never selects a package does not end the run"
not_called "$PIN" "and is not pinned"
has "codex daemon not pinned: it selected no package" "the warning says why"
mkdir -p "$PKG"; ln -s local-20261101 "$PKG/current"
reset; run 'hercules\ny\n'
not_called "$PIN" "a local- package link (dangling) means no pin"
rm -rf "$T/home/.codex"; mkdir -p "$PKG/releases/0.1.0"; ln -s releases/0.1.0 "$PKG/current"
reset; run 'hercules\ny\n'
not_called "$PIN" "a releases/0.1.0 package link means no pin"
not_called "codex-daemon real-bin" "and codex-daemon is not asked"
rm -rf "$T/home/.codex"

echo "Q. chezmoi apply knows it is provisioning"
SBX_SRC="$T/fresh2"; rm -rf "$SBX_SRC"; reset; run 'hercules\ny\n'
called "chezmoi-env DOTFILES_PROVISIONING=1" "chezmoi apply --force runs with DOTFILES_PROVISIONING=1"
al=$(grep -n '^chezmoi apply' "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$al" ] && [ "$(sed -n "$((al+1))p" "$CALLS")" = "chezmoi-env DOTFILES_PROVISIONING=1" ]; } \
  && _pass "the marker is on the apply itself" || _fail "the marker is on the apply itself"
il=$(grep -n '^chezmoi init' "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$il" ] && [ "$(sed -n "$((il+1))p" "$CALLS")" = "chezmoi-env DOTFILES_PROVISIONING=unset" ]; } \
  && _pass "chezmoi init does not get it" || _fail "chezmoi init does not get it"
called "configure-env DOTFILES_PROVISIONING=unset" "the marker is not exported: a later script (configure.sh) never sees it"
not_called "configure-env DOTFILES_PROVISIONING=1" "and no later script sees it set"
called "git clone --branch main" "an unset PROVISION_REF clones main"
hasnt "Branch ....." "and the summary shows no branch line"
SBX_SRC="$T/src"

echo "R. PROVISION_REF"
SBX_SRC="$T/fresh3"; rm -rf "$SBX_SRC"
reset; PROVISION_REF=feat/x HV=1 run 'hercules\ny\n'
rc_is 0 "a branch ref inside a VM provisions"
called "sysctl -n kern.hv_vmm_present" "the VM is read from kern.hv_vmm_present"
called "git clone --branch feat/x" "the clone checks the ref out"
has "Branch ............. feat/x" "and the summary shows it"
SBX_SRC="$T/fresh4"; rm -rf "$SBX_SRC"
reset; PROVISION_REF=feat/x HV=0 run 'hercules\ny\n'
rc_is 1 "a branch ref outside a VM is refused"
not_called "sudo -v" "before sudo is asked"
not_called "git clone" "nothing is cloned"
not_called "brew" "and nothing is installed"
has "PROVISION_REF" "and the refusal names the variable"
[ -e "$SBX_SRC" ] && _fail "and no checkout exists" || _pass "and no checkout exists"
reset; PROVISION_REF=main HV=0 run 'hercules\ny\n'
rc_is 0 "PROVISION_REF=main is allowed outside a VM"
called "git clone --branch main" "and clones main"
hasnt "Branch ....." "with no branch line"
SBX_SRC="$T/src"
echo "other-branch" > "$T/branch"
reset; PROVISION_REF=feat/x HV=1 run 'hercules\ny\n'
rm -f "$T/branch"
rc_is 0 "a branch ref over an existing checkout (in a VM) finishes"
has "Branch ............. other-branch (existing checkout, used as is)" "the summary names the branch the checkout is on, as used"
hasnt "feat/x" "and not the ref it ignored"
not_called "git clone" "nothing is cloned"

echo "T. no new step can hang the unattended run on stdin"
# Each stub below reads a line of stdin and fails on EOF; the run is fed spare lines, so a step
# that left stdin open would read one and succeed, and its warning would be missing.
SPARE='hercules\ny\nx\nx\nx\nx\nx\nx\n'
CFG="$T/home/.config"; mkdir -p "$CFG/herdr/plugin-a"; : > "$CFG/herdr/plugin-a/herdr-plugin.toml"
printf '0 plugins installed\n' > "$T/herdr-list"
rm -rf "$T/home/.codex"
for t in netbird nvim herdr-link codex machine-check; do : > "$T/read-stdin-$t"; done
reset; run "$SPARE"
rc_is 0 "stdin read failures do not end the run"
has "NetBird daemon not installed or started" "netbird service install and start read /dev/null"
has "neovim plugins: install failed" "nvim reads /dev/null"
has "herdr plugin not linked" "herdr plugin link reads /dev/null"
has "codex daemon not pinned — run: $T/codexbin/codex" "the pin reads /dev/null"
called "machine-check-stdin eof" "machine-check.sh reads /dev/null"
for t in netbird nvim herdr-link codex machine-check; do rm -f "$T/read-stdin-$t"; done
rm -rf "$T/home/.codex"
for t in herdr-list codex-daemon netbird; do : > "$T/read-stdin-$t"; done
echo netbird > "$LAUNCHCTL_LOADED"; : > "$T/lc-stopped"
reset; run "$SPARE"
rc_is 0 "and neither do the list, real-bin and start reads"
has "herdr plugins: could not list them" "herdr plugin list reads /dev/null"
has "codex-daemon real-bin found no codex" "codex-daemon real-bin reads /dev/null"
has "NetBird daemon installed but not started" "the NetBird start reads /dev/null"
for t in herdr-list codex-daemon netbird; do rm -f "$T/read-stdin-$t"; done
rm -f "$T/lc-stopped"; lc_reset; rm -rf "$CFG/herdr" "$T/herdr-list" "$T/home/.codex"

echo "S. the end of the run points at the checklist"
reset; run 'hercules\ny\n'
called "machine-check.sh --todo --machine hercules" "the end calls machine-check.sh --todo for the machine"
cl=$(grep -n 'configure.sh --hostname' "$CALLS" | head -1 | cut -d: -f1); ml=$(grep -n 'machine-check.sh' "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$cl" ] && [ -n "$ml" ] && [ "$cl" -lt "$ml" ]; } && _pass "after configure.sh" || _fail "after configure.sh"
has "Check again any time: $SBX_SRC/.scripts/machine-check.sh" "and says how to run the checklist again, by the source dir's path"
hasnt "Borg: this machine" "the hard-coded Borg step is gone"
hasnt "Alfred snippets" "the hard-coded Alfred steps are gone"
hasnt "respaces" "the hard-coded Herdr step is gone"
has "Restart your terminal" "the restart line stays"
has "exec $T/brew/bin/zsh" "with the exec hint while Homebrew's zsh exists"
has "logout/restart" "and the logout line"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
