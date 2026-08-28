#!/usr/bin/env bash
# Mocked test for provision.sh preflight and the machine allowlist.
# Isolation is not optional: provision.sh deletes files under $HOME and rewrites macOS
# defaults, so every run gets a temporary HOME and every temporary XDG root, plus the
# two override points. Run: bash .scripts/test-provision.sh
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
CALLS="$T/calls"; IDDB="$T/identity"; MUTLOG="$T/refused"; SBX_ROOT="$T"
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
        *) echo "SUDO-REFUSED: $1" | tee -a "$MUTLOG" >&2; exit 99 ;; esac ;;
esac
exec "$@"
SU
printf '#!/usr/bin/env bash\necho "brew[$0] $*" >> "$CALLS"\ncase "$1" in shellenv) echo "export PATH=\\"%s/brew/bin:\\$PATH\\"";; --prefix) echo "%s/brew";; esac\nexit 0\n' "$T" "$T" > "$T/brew/bin/brew"
cp "$T/brew/bin/brew" "$T/bin/brew"
# tee is stubbed because step 10 pipes into `sudo tee -a /etc/shells`; without it the
# delegating sudo reaches the real /etc/shells. Anything the script writes outside the
# temp roots needs a stub here — that is the whole isolation boundary.
for t in op chezmoi git xcode-select mise chsh open curl ssh defaults killall osascript tee; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\nexit 0\n' "$t" > "$T/bin/$t"
done
# Scripts provision.sh calls BY PATH bypass $PATH, so stub them by path.
for sc in configure.sh reconcile-agents.sh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS"\nexit 0\n' "$sc" > "$T/src/.scripts/$sc"
done
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
for t in rm chmod find; do
  printf '#!/usr/bin/env bash\nexec "%s/bin/_mut" %s "$@"\n' "$T" "$t" > "$T/bin/$t"
done
chmod +x "$T"/bin/* "$T"/brew/bin/brew "$T"/src/.scripts/*

# Guard the harness against itself. Verifying that a containment assertion CAN fail
# must never be done by pointing an override at the real binary -- that executes it.
# Twice during development this ran the host's Homebrew and advanced its git HEAD.
canon(){ python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
assert_inside(){ local r; r=$(canon "$2")
  case "$r" in "$T"|"$T"/*) ;; *) echo "REFUSING: $1='$2' resolves to '$r', outside $T"; exit 2 ;; esac; }

reset(){ : > "$CALLS"; : > "$MUTLOG"; printf 'ComputerName=MacBook Pro\nLocalHostName=MacBook-Pro\n' > "$IDDB"; }
SBX_SRC="$T/src"; SBX_BREW="$T/brew/bin/brew"
run(){ local ans=$1; shift
  assert_inside PROVISION_BREW_BIN "$SBX_BREW"
  assert_inside PROVISION_SRC_OVERRIDE "$SBX_SRC"
  OUT=$(cd "$T" && printf '%b' "$ans" | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" USER=tester SHELL=/bin/zsh \
    XDG_CACHE_HOME="$T/home/.cache" XDG_CONFIG_HOME="$T/home/.config" \
    XDG_DATA_HOME="$T/home/.local/share" XDG_STATE_HOME="$T/home/.local/state" \
    XDG_BIN_HOME="$T/home/.local/bin" CALLS="$CALLS" IDDB="$IDDB" \
    MUTLOG="$MUTLOG" SBX_ROOT="$SBX_ROOT" \
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
la=$(grep -n "scutil --set ComputerName" "$CALLS" | head -1 | cut -d: -f1)
lb=$(grep -n "chezmoi init" "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; } && _pass "identity is set before chezmoi init" || _fail "identity is set before chezmoi init"

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

echo "F. identity guard in Brewfile.tmpl"
mkdir -p "$T/tbin"
printf '#!/bin/sh\ncase "$2" in ComputerName) echo "$FCN";; HostName) echo "$FHN";; esac\n' > "$T/tbin/scutil"
chmod +x "$T/tbin/scutil"
render(){ printf '[data]\n  hostname = "%s"\n' "$1" > "$T/c.toml"
  OUT=$(FCN="$1" FHN="$2" PATH="$T/tbin:$PATH" chezmoi execute-template --source "$SRC" \
        --config "$T/c.toml" --file "$SRC/dot_config/homebrew/Brewfile.tmpl" 2>&1); RC=$?; }
render fenrir fenrir
rc_is 0 "matching identity renders"
has 'cask "jiggler"' "fenrir gets the peripheral casks"
render hercules hercules
rc_is 0 "the other machine renders"
hasnt 'cask "jiggler"' "hercules does not get the peripheral casks"
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
cfg(){ printf 'ComputerName=%s\nHostName=%s\nLocalHostName=%s\n' "$1" "$2" "$3" > "$IDDB"
  OUT=$(cd "$T" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" USER=tester \
        CALLS="$CALLS" IDDB="$IDDB" MUTLOG="$MUTLOG" SBX_ROOT="$SBX_ROOT" \
        zsh "$SRC/.scripts/configure.sh" --hostname "$4" 2>&1); RC=$?; }
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

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
