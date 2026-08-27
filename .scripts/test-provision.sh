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
CALLS="$T/calls"; IDDB="$T/identity"
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
printf '#!/usr/bin/env bash\necho "sudo $*" >> "$CALLS"\ncase "$1" in -v|-n) exit 0;; esac\nexec "$@"\n' > "$T/bin/sudo"
printf '#!/usr/bin/env bash\necho "brew $*" >> "$CALLS"\ncase "$1" in shellenv) echo "export PATH=\\"%s/brew/bin:\\$PATH\\"";; --prefix) echo "%s/brew";; esac\nexit 0\n' "$T" "$T" > "$T/brew/bin/brew"
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
chmod +x "$T"/bin/* "$T"/brew/bin/brew "$T"/src/.scripts/*

reset(){ : > "$CALLS"; printf 'ComputerName=MacBook Pro\nLocalHostName=MacBook-Pro\n' > "$IDDB"; }
run(){ local ans=$1; shift
  OUT=$(printf '%b' "$ans" | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" USER=tester SHELL=/bin/zsh \
    XDG_CACHE_HOME="$T/home/.cache" XDG_CONFIG_HOME="$T/home/.config" \
    XDG_DATA_HOME="$T/home/.local/share" XDG_STATE_HOME="$T/home/.local/state" \
    XDG_BIN_HOME="$T/home/.local/bin" CALLS="$CALLS" IDDB="$IDDB" \
    PROVISION_SRC_OVERRIDE="$T/src" PROVISION_BREW_BIN="$T/brew/bin/brew" \
    zsh "$SRC/.scripts/provision.sh" "$@" 2>&1); RC=$?; }

echo "A. containment"
reset; run 'studio\ny\n'
not_called "/opt/homebrew" "the real Homebrew is never invoked"
[ -f "$HOME/.zprofile" ] || [ ! -e "$HOME/.zprofile" ] && _pass "the real HOME is not the target" || _fail "the real HOME is not the target"

echo "B. preflight asks first, then applies"
reset; run 'studio\ny\n'
called "scutil --set ComputerName studio"  "ComputerName is set"
called "scutil --set HostName studio"      "HostName is set (Borg reads this)"
called "scutil --set LocalHostName studio" "LocalHostName is set"
grep -q '^ComputerName=studio$' "$IDDB" && _pass "the identity really changed" || _fail "the identity really changed"
la=$(grep -n "scutil --set ComputerName" "$CALLS" | head -1 | cut -d: -f1)
lb=$(grep -n "chezmoi init" "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; } && _pass "identity is set before chezmoi init" || _fail "identity is set before chezmoi init"

echo "C. consent gates the rename"
reset; run 'studio\nn\n'
rc_is 1 "declining aborts"
not_called "scutil --set" "declining renames nothing"
grep -q '^ComputerName=MacBook Pro$' "$IDDB" && _pass "identity untouched after decline" || _fail "identity untouched after decline"

echo "D. allowlist"
reset; run 'nosuchmachine\nstudio\ny\n'
has "Unknown machine" "an unlisted name is refused"
not_called "scutil --set ComputerName nosuchmachine" "the refused name is never applied"

echo "E. unattended boundary"
reset; run 'studio\ny\n'
called "sudo chsh" "chsh goes through the cached sudo credential"
# Substring matching cannot tell "chsh -s" from "sudo chsh -s". Count instead: sudo
# delegates, so a chsh reached through sudo logs both lines. Equal counts mean every
# invocation went through sudo; an excess chsh line means one was called bare.
n_chsh=$(grep -c '^chsh ' "$CALLS" || true); n_sudo_chsh=$(grep -c '^sudo chsh ' "$CALLS" || true)
[ "$n_chsh" = "$n_sudo_chsh" ] && _pass "no chsh call bypasses sudo" \
  || _fail "no chsh call bypasses sudo (chsh=$n_chsh via-sudo=$n_sudo_chsh)"
called "StrictHostKeyChecking=accept-new" "the SSH check cannot block on a host key"
called "configure.sh --hostname studio" "configure.sh is told the identity, not asked"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
