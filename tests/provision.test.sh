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
# outdated-brew-bundle: everything is installed but glab has a newer release, so only a check
# without --no-upgrade fails. With both markers, the install fails on that upgrade.
printf '#!/usr/bin/env bash\necho "brew[$0] $*" >> "$CALLS"\ncase "$1" in shellenv) echo "export PATH=\\"%s/brew/bin:\\$PATH\\"";; --prefix) echo "%s/brew";;\n  bundle) [ -e "$SBX_ROOT/st-appears" ] && : > "$HOME/Library/Application Support/Syncthing/config.xml"; if [ -e "$SBX_ROOT/outdated-brew-bundle" ] && [ "$2" = check ]; then case " $* " in *" --no-upgrade "*) exit 0;; esac; echo "→ Formula glab needs to be installed or updated." >&2; exit 1; fi; [ -e "$SBX_ROOT/fail-brew-bundle" ] || exit 0; [ "$2" = check ] && echo "→ Cask microsoft-office needs to be installed." >&2; exit 1;; esac\nexit 0\n' "$T" "$T" > "$T/brew/bin/brew"
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
# $T/vorta-running makes `pgrep -x vorta-darwin` (Vorta.app's process) succeed; read-stdin-pgrep makes any
# pgrep that gets a line on stdin succeed too, so a step that left its stdin open reads Vorta as running.
cat > "$T/bin/pgrep" <<'PG'
#!/usr/bin/env bash
echo "pgrep $*" >> "$CALLS"
[ -e "$SBX_ROOT/read-stdin-pgrep" ] && { read -r _ && exit 0; }
case "$*" in *"-x vorta-darwin"*) [ -e "$SBX_ROOT/vorta-running" ] && exit 0 ;; esac
exit "${PGREP_RC:-1}"
PG
# open logs its arguments. With $T/vorta-imports it plays Vorta's start: it copies ~/.vorta-init.json to
# $T/vorta-init-seen, its mode to $T/vorta-init-mode, and deletes it, as Vorta does after an import.
# read-stdin-open makes it read one line of stdin and fail on EOF, before importing.
cat > "$T/bin/open" <<'OP'
#!/usr/bin/env bash
echo "open $*" >> "$CALLS"
[ -e "$SBX_ROOT/read-stdin-open" ] && { read -r _ || exit 1; }
f="$HOME/.vorta-init.json"
if [ -e "$SBX_ROOT/vorta-imports" ] && [ -f "$f" ]; then
  cp "$f" "$SBX_ROOT/vorta-init-seen"; stat -f %Lp "$f" > "$SBX_ROOT/vorta-init-mode"; /bin/rm -f "$f"
fi
exit 0
OP
# Vorta imports by default, so a run that reaches step 15b does not wait out its 2 minutes; section X
# removes the marker for the case where it never does.
: > "$T/vorta-imports"
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
# `read` and `document get` answer from the files $T/op-items/<vault>/<item>/<field> (a Document's
# content in .../document) and exit 1 when the file is absent. Their log line names items only.
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
  read)    [ -e "$SBX_ROOT/read-stdin-op" ] && { read -r _ || exit 1; }
           f="$SBX_ROOT/op-items/${2#op://}"
           [ -f "$f" ] || { echo "[ERROR] \"$2\" isn't an item in any vault" >&2; exit 1; }
           cat "$f" ;;
  document) [ -e "$SBX_ROOT/read-stdin-op" ] && { read -r _ || exit 1; }
           f="$SBX_ROOT/op-items/$5/$3/document"
           [ -f "$f" ] || { echo "[ERROR] \"$3\" isn't an item in the vault $5" >&2; exit 1; }
           cat "$f" ;;
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
# netbird logs its whole environment, and `status --json` prints $T/netbird-status (absent: connected);
# after the first status call, $T/netbird-status-later when it exists (the preflight reads the first,
# step 8c the later ones). `up` writes its stdin to $T/netbird-up-stdin; fail-netbird-up fails only `up`.
cat > "$T/bin/netbird" <<'NB'
#!/usr/bin/env bash
echo "netbird $*" >> "$CALLS"
/usr/bin/env | sed 's/^/netbird-env /' >> "$CALLS"
if [ "$1" = up ]; then
  cat > "$SBX_ROOT/netbird-up-stdin"
  [ -e "$SBX_ROOT/fail-netbird-up" ] || [ -e "$SBX_ROOT/fail-netbird" ] && exit 1
  exit 0
fi
[ -e "$SBX_ROOT/read-stdin-netbird" ] && { read -r _ || exit 1; }
[ -e "$SBX_ROOT/fail-netbird" ] && exit 1
if [ "$1 $2" = "status --json" ]; then
  n=$(cat "$SBX_ROOT/netbird-status-n" 2>/dev/null || echo 0); echo $((n + 1)) > "$SBX_ROOT/netbird-status-n"
  f="$SBX_ROOT/netbird-status"
  [ "$n" -gt 0 ] && [ -e "$SBX_ROOT/netbird-status-later" ] && f="$SBX_ROOT/netbird-status-later"
  if [ -e "$f" ]; then cat "$f"
  else echo '{"daemonStatus":"Connected","management":{"connected":true}}'; fi
fi
exit 0
NB
# Syncthing's bundled binary, found through PROVISION_APPLICATIONS. It logs its arguments and
# environment, writes its stdin to $T/syncthing-stdin, and `generate --home <dir>` writes
# <dir>/config.xml (mode 600) in the shape the real one wrote: a <gui> with a user and a bcrypt
# password, and the four <options> elements each on its own line (the only ones step 8d and the
# syncthing-settings verify read). $T/st-no-relays leaves <relaysEnabled> out; fail-syncthing exits
# 1 writing nothing.
ST_STUB="$T/apps/Syncthing.app/Contents/Resources/syncthing/syncthing"
mkdir -p "${ST_STUB%/*}"
cat > "$ST_STUB" <<'SY'
#!/usr/bin/env bash
echo "syncthing $*" >> "$CALLS"
/usr/bin/env | sed 's/^/syncthing-env /' >> "$CALLS"
cat > "$SBX_ROOT/syncthing-stdin"
[ -e "$SBX_ROOT/fail-syncthing" ] && exit 1
[ "$1" = generate ] || exit 0
home=""; user=""
while [ $# -gt 0 ]; do case "$1" in --home) home=$2; shift;; --gui-user) user=$2; shift;; esac; shift; done
mkdir -p "$home"
{
  echo '<configuration version="52">'
  echo '    <gui enabled="true" tls="false" sendBasicAuthPrompt="false">'
  echo "        <user>$user</user>"
  echo '        <password>$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234</password>'
  echo '    </gui>'
  echo '    <options>'
  echo '        <globalAnnounceEnabled>true</globalAnnounceEnabled>'
  echo '        <localAnnounceEnabled>true</localAnnounceEnabled>'
  [ -e "$SBX_ROOT/st-no-relays" ] || echo '        <relaysEnabled>true</relaysEnabled>'
  echo '        <natEnabled>true</natEnabled>'
  echo '    </options>'
  echo '</configuration>'
} > "$home/config.xml"
/bin/chmod 600 "$home/config.xml"
exit 0
SY
# nvim also records the first entry of its PATH: Mason's Ruby tools need mise's Ruby.
cat > "$T/bin/nvim" <<'NV'
#!/usr/bin/env bash
echo "nvim $*" >> "$CALLS"
echo "nvim-path-head ${PATH%%:*}" >> "$CALLS"
[ -e "$SBX_ROOT/read-stdin-nvim" ] && { read -r _ || exit 1; }
[ -e "$SBX_ROOT/fail-nvim" ] && exit 1
exit 0
NV
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
echo "machine-check-from $(cd "$(dirname "$0")/.." && pwd)" >> "$CALLS"
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
echo "configure-from $(cd "$(dirname "$0")/.." && pwd)" >> "$CALLS"
echo "configure-env DOTFILES_PROVISIONING=${DOTFILES_PROVISIONING:-unset}" >> "$CALLS"
/usr/bin/env | sed 's/^/configure-fullenv /' >> "$CALLS"
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
chmod +x "$T"/bin/* "$T"/brew/bin/brew "$T"/brew/bin/zsh "$T"/src/.scripts/* "$T/home/.local/bin/codex-daemon" "$T/codexbin/codex" "$ST_STUB"

# Guard the harness against itself. Verifying that a containment assertion CAN fail
# must never be done by pointing an override at the real binary -- that executes it.
# Twice during development this ran the host's Homebrew and advanced its git HEAD.
canon(){ python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
assert_inside(){ local r; r=$(canon "$2")
  case "$r" in "$T"|"$T"/*) ;; *) echo "REFUSING: $1='$2' resolves to '$r', outside $T"; exit 2 ;; esac; }

# A run starts on a machine chezmoi has configured (its config exists) and a terminal 1Password
# has not authorized yet; section B2b removes the config.
# It is also a machine whose setup is done: netbird is connected, Syncthing has its config.xml and
# Vorta's settings.db holds a profile with a repository, so no step reads a 1Password item.
ST_DIR="$T/home/Library/Application Support/Syncthing"; VORTA_DIR="$T/home/Library/Application Support/Vorta"
VI="$T/home/.vorta-init.json"; mkdir -p "$T/apps/Vorta.app"
nowrite(){ not_called "open -g -a Vorta" "$1: Vorta is not started"
  [ -e "$VI" ] || [ -L "$VI" ] && _fail "$1: no file is written" || _pass "$1: no file is written"; }
reset(){ rm -f "$VI" "$T/vorta-init-seen" "$T/vorta-init-mode"; : > "$CALLS"; : > "$MUTLOG"; printf 'ComputerName=MacBook Pro\nLocalHostName=MacBook-Pro\n' > "$IDDB"
  mkdir -p "$T/home/.config/chezmoi"; : > "$T/home/.config/chezmoi/chezmoi.toml"; rm -f "$T/op-authorized"
  rm -rf "$T/op-items" "$ST_DIR" "$VORTA_DIR"; rm -f "$T/netbird-status" "$T/netbird-status-later" "$T/netbird-status-n" "$T/netbird-up-stdin" "$T/syncthing-stdin" "$T/st-no-relays" "$T/fail-syncthing" "$T/st-appears"; mkdir -p "$ST_DIR" "$VORTA_DIR"; : > "$ST_DIR/config.xml"
  /usr/bin/sqlite3 "$VORTA_DIR/settings.db" "create table backupprofilemodel(id integer primary key, name text, repo_id integer); insert into backupprofilemodel(name, repo_id) values('p', 1);"; }
# The secrets are the suite's markers; nothing here is a real value. items_all takes the vault.
MK_NB='MARK-NB-KEY-7f3a'; MK_ST='MARK-ST-PW-91c2'; MK_VORTA='MARK-VORTA-PW-d4e8'
VORTA_EXPORT='{"id":1,"name":"Default","SchemaVersion":{"version":23},"repo":{"url":"ssh://nobody@127.0.0.1:9/./repo"},"password":"'"$MK_VORTA"'"}'
put_item(){ mkdir -p "$T/op-items/$1/$2"; printf '%s\n' "$4" > "$T/op-items/$1/$2/$3"; }
items_all(){ local v=${1:-Private}
  put_item "$v" "NetBird setup key" credential "$MK_NB"
  put_item "$v" "Syncthing GUI" username st-user; put_item "$v" "Syncthing GUI" password "$MK_ST"
  put_item "$v" "BorgBase hercules" document "$VORTA_EXPORT"; }
# A machine on which all three steps are not done.
fresh_steps(){ rm -f "$ST_DIR/config.xml" "$VORTA_DIR/settings.db"; echo '{"daemonStatus":"NeedsLogin"}' > "$T/netbird-status"; }
SBX_SRC="$T/src"; SBX_BREW="$T/brew/bin/brew"
run(){ local ans=$1; shift
  assert_inside PROVISION_BREW_BIN "$SBX_BREW"
  assert_inside PROVISION_SRC_OVERRIDE "$SBX_SRC"
  assert_inside PROVISION_APPLICATIONS "${PROVISION_APPLICATIONS:-$T/apps}"
  OUT=$(cd "$T" && printf '%b' "$ans" | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" USER=tester SHELL=/bin/zsh \
    XDG_CACHE_HOME="$T/home/.cache" XDG_CONFIG_HOME="$T/home/.config" \
    XDG_DATA_HOME="$T/home/.local/share" XDG_STATE_HOME="$T/home/.local/state" \
    XDG_BIN_HOME="$T/home/.local/bin" CALLS="$CALLS" IDDB="$IDDB" \
    MUTLOG="$MUTLOG" SBX_ROOT="$SBX_ROOT" \
    LAUNCHCTL_LOADED="$LAUNCHCTL_LOADED" LAUNCHCTL_FAIL="${LAUNCHCTL_FAIL:-}" \
    PROVISION_REF="${PROVISION_REF:-}" HV="${HV:-0}" PROVISION_OP_VAULT="${PROVISION_OP_VAULT:-}" \
    PROVISION_APPLICATIONS="${PROVISION_APPLICATIONS:-$T/apps}" PV_NETBIRD_KEY="${PV_NETBIRD_KEY:-}" PV_ST_USER="${PV_ST_USER:-}" \
    PV_ST_PASSWORD="${PV_ST_PASSWORD:-}" PV_VORTA_EXPORT="${PV_VORTA_EXPORT:-}" HERDR_PANE_ID=pane-test HERDR_SOCKET_PATH="$T/herdr.sock" TMPDIR="$T/caller-tmp" \
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
called "configure-from $SBX_SRC" "a fresh machine runs configure.sh from its own clone"
SBX_SRC="$T/src"
reset; run 'hercules\ny\n'
rc_is 0 "a machine with an existing checkout still finishes"
not_called "michaelrigart/dotfiles.git $SBX_SRC" "an existing checkout is not cloned again"
# The sandbox can write that checkout, and these scripts run outside it (spec §2).
CLONE="$T/home/.cache/dotfiles-run/provision."
called "git clone -q --depth 1 --branch main https://github.com/michaelrigart/dotfiles.git $CLONE" "the scripts come from a fresh clone of the ref instead"
called "configure-from $CLONE" "configure.sh runs from it"
not_called "configure-from $SBX_SRC" "never from the checkout"
called "machine-check-from $CLONE" "so does the closing machine-check.sh"
called "+luafile $CLONE" "and the Neovim step's script"
[ -z "$(ls -A "$T/home/.cache/dotfiles-run" 2>/dev/null)" ] && _pass "the clone is removed when the run ends" || _fail "the clone is removed when the run ends"
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
not_called "michaelrigart/dotfiles.git $SBX_SRC" "and nothing is cloned over it"
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
not_called "michaelrigart/dotfiles.git $SBX_SRC" "and nothing is cloned over it"
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
has "⚠ brewfile: Cask microsoft-office needs to be installed." "the closing list names each item brew bundle missed"
rm -rf "$T/home/.config/homebrew" "$T/fail-brew-bundle"
# The fifth VM run: releases published during the run left three installed items outdated, and
# step 8's check, unlike the brewfile row's, reported them as not installed.
mkdir -p "$T/home/.config/homebrew"; : > "$T/home/.config/homebrew/Brewfile"; : > "$T/outdated-brew-bundle"
reset; run 'hercules\ny\n'
hasnt "brewfile: Formula glab" "an installed item with a newer release is not reported missing"
hasnt "brew bundle did not complete" "nor is the Brewfile reported incomplete"
hasnt "every Brewfile item is installed" "an install that succeeds leaves no upgrade warning"
# A re-run whose install fails twice on an upgrade alone: nothing is missing, but the failure
# still reaches the closing list.
: > "$T/fail-brew-bundle"
reset; run 'hercules\ny\n'
has "⚠ brew bundle failed although every Brewfile item is installed" "an upgrade that fails twice is in the closing list"
hasnt "brew bundle did not complete" "it is not reported as a missing item"
rm -rf "$T/home/.config/homebrew" "$T/outdated-brew-bundle" "$T/fail-brew-bundle"
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

echo "J. FileVault is expected on every machine; autorestart is per-machine"
FV=On  cfg fenrir fenrir fenrir fenrir
has   "FileVault is enabled"        "fenrir with FileVault on is correct"
FV=Off cfg fenrir fenrir fenrir fenrir
has   "FileVault is OFF"            "fenrir without FileVault is flagged"
FV=On  cfg hercules hercules hercules hercules
has   "FileVault is enabled"        "hercules with FileVault on is correct"
FV=Off cfg hercules hercules hercules hercules
has   "FileVault is OFF on hercules" "hercules without FileVault is flagged"
has   "Privacy & Security"          "and the remedy is named"
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
rm -f "$T/home/Library/Application Support/Alfred/prefs.json"
: > "$CALLS"; cfg fenrir fenrir fenrir fenrir
hasnt "Alfred has not been launched yet — re-run" "--hostname with Alfred never launched: no warning, the alfred-snippets step covers it"
has "Skipping the Alfred toggle: Alfred has not been launched yet" "and the skip is announced"
: > "$CALLS"; cfg_attended fenrir
has "Alfred has not been launched yet — re-run" "an attended run with Alfred never launched still warns"
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
called "nvim --headless +Lazy! install +luafile $T/home/.cache/dotfiles-run/provision." "Neovim installs its plugins headless (on this provisioned machine, the script from a fresh clone)"
called "/src/.scripts/nvim-finish-install.lua +cq 2" "then waits for Mason's tools and the parsers"
called "nvim-path-head $T/home/.local/share/mise/shims" "with mise's shims first on PATH, so Mason's Ruby tools get mise's Ruby"
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
has "neovim: not everything installed" "and it warns"
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
sl=$(grep -n '^sleep 5' "$CALLS" | head -1 | cut -d: -f1); pl=$(grep -n "^$PIN" "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$sl" ] && [ -n "$pl" ] && [ "$sl" -lt "$pl" ]; } && _pass "the pin waits until the daemon has selected its package" || _fail "the pin waits until the daemon has selected its package"
hasnt "codex daemon not pinned" "and then pins it"
# Without a codex there is nothing to wait for: the warning names the missing binary at once.
rm -rf "$T/home/.codex"; : > "$T/read-stdin-codex-daemon"; reset; run 'hercules\ny\n'
rm -f "$T/read-stdin-codex-daemon"
not_called "sleep 5" "a machine without codex does not wait for a daemon package"
has "codex-daemon real-bin found no codex" "and the warning names the missing codex"
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
not_called "michaelrigart/dotfiles.git $SBX_SRC" "nothing is cloned over it"

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
has "neovim: not everything installed" "nvim reads /dev/null"
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
# The preflight's reads: a read that left stdin open would take a spare line and find its item.
: > "$T/read-stdin-op"
reset; fresh_steps; items_all; run "$SPARE"
rm -f "$T/read-stdin-op"
rc_is 0 "a preflight whose reads fail does not end the run"
has "Not read from 1Password  NetBird setup key, Syncthing GUI, BorgBase hercules" "op read and op document get read /dev/null"
: > "$T/read-stdin-netbird"; : > "$T/fast-sleep"
reset; items_all; run "$SPARE"
rm -f "$T/read-stdin-netbird" "$T/fast-sleep"
has "read: NetBird setup key" "the preflight's netbird status --json reads /dev/null (a status it cannot read means the key is read)"
has "NetBird did not join with the setup key" "and step 8c's reads /dev/null too: it warns instead of joining on a spare line's status"
not_called "netbird up" "and runs no up"
# Vorta's step: pgrep and open read /dev/null. A leaked line makes pgrep report Vorta running, or open import.
mkdir -p "$T/apps/Vorta.app"; : > "$T/fast-sleep"
: > "$T/read-stdin-pgrep"
reset; fresh_steps; items_all; run "$SPARE"
rm -f "$T/read-stdin-pgrep"
hasnt "quit Vorta, then run provision.sh again" "pgrep -x vorta-darwin reads /dev/null"
called "open -g -a Vorta" "and Vorta is started"
: > "$T/read-stdin-open"
reset; fresh_steps; items_all; run "$SPARE"
rm -f "$T/read-stdin-open" "$T/fast-sleep"
[ -e "$VI" ] && _pass "open reads /dev/null: it fails before importing" || _fail "open reads /dev/null: it fails before importing"
has "answer macOS's prompt to open Vorta" "and the file's warning stands"

echo "S. the end of the run points at the checklist"
reset; run 'hercules\ny\n'
called "machine-check.sh --todo --machine hercules" "the end calls machine-check.sh --todo for the machine"
cl=$(grep -n 'configure.sh --hostname' "$CALLS" | head -1 | cut -d: -f1); ml=$(grep -n 'machine-check.sh' "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$cl" ] && [ -n "$ml" ] && [ "$cl" -lt "$ml" ]; } && _pass "after configure.sh" || _fail "after configure.sh"
has "Check again any time, from a new shell: dotfiles-run machine-check" "and says how to run the checklist again, from a fresh clone of origin's main"
hasnt "Borg: this machine" "the hard-coded Borg step is gone"
hasnt "Alfred snippets" "the hard-coded Alfred steps are gone"
hasnt "herdr-app/bin/respaces" "the hard-coded Herdr step is gone"
has "Restart your terminal" "the restart line stays"
has "exec $T/brew/bin/zsh" "with the exec hint while Homebrew's zsh exists"
has "logout/restart" "and the logout line"

echo "U. the preflight reads only what a step needs"
SCUTIL_LINE(){ grep -n 'scutil --set ComputerName' "$CALLS" | head -1 | cut -d: -f1; }
reset; fresh_steps; items_all; run 'hercules\ny\n'
rc_is 0 "a machine with nothing set up finishes"
called "op read op://Private/NetBird setup key/credential" "the NetBird key is read"
called "op read op://Private/Syncthing GUI/username" "the Syncthing user is read"
called "op read op://Private/Syncthing GUI/password" "the Syncthing password is read"
called "op document get BorgBase hercules --vault Private" "Vorta's export is read, for the machine just named"
sl=$(SCUTIL_LINE); last=$(grep -nE '^op (read|document) ' "$CALLS" | tail -1 | cut -d: -f1)
{ [ -n "$sl" ] && [ -n "$last" ] && [ "$last" -lt "$sl" ]; } && _pass "every read comes before the machine's identity is set" || _fail "every read comes before the machine's identity is set"
has "Setup secrets ...... read: NetBird setup key, Syncthing GUI, BorgBase hercules" "the summary names what was read"
for m in "$MK_NB" "$MK_ST" "$MK_VORTA"; do hasnt "$m" "no secret is printed by the run"; done
reset; run 'hercules\ny\n'
not_called "op read" "a machine that is set up reads no item"
not_called "op document" "and no document"
has "Setup secrets ...... none needed" "and the summary says so"
hasnt "Not read from 1Password" "with nothing unread"
# One step at a time.
reset; rm -f "$ST_DIR/config.xml"; items_all; run 'hercules\ny\n'
called "op read op://Private/Syncthing GUI/password" "without config.xml, Syncthing's login is read"
not_called "op read op://Private/NetBird" "and NetBird's key is not"
not_called "op document" "nor Vorta's export"
reset; rm -f "$VORTA_DIR/settings.db"; items_all; run 'hercules\ny\n'
called "op document get BorgBase hercules --vault Private" "without settings.db, Vorta's export is read"
not_called "op read" "and nothing else"
reset; items_all; rm -f "$VORTA_DIR/settings.db"
/usr/bin/sqlite3 "$VORTA_DIR/settings.db" "create table backupprofilemodel(id integer primary key, name text, repo_id integer); insert into backupprofilemodel(name) values('p');"
run 'hercules\ny\n'
called "op document get BorgBase hercules --vault Private" "a settings.db whose profile has no repository: Vorta's export is read"
# Missing items: the step is skipped and the run goes on.
for it in "NetBird setup key" "Syncthing GUI" "BorgBase hercules"; do
  reset; fresh_steps; items_all; rm -rf "$T/op-items/Private/$it"; run 'hercules\ny\n'
  rc_is 0 "$it missing: the run finishes"
  has "Not read from 1Password  $it — answer n, add or unlock them in 1Password (Private) and run again; y skips their steps" "$it missing: the summary names it before Proceed"
  has "⚠ 1Password item '$it' could not be read from Private:" "$it missing: the closing list names it"
done
reset; fresh_steps; items_all; rm -f "$T/op-items/Private/Syncthing GUI/password"; run 'hercules\ny\n'
has "Not read from 1Password  Syncthing GUI" "an item with one field missing is missing"
reset; fresh_steps; items_all; printf '  \n' > "$T/op-items/Private/NetBird setup key/credential"; run 'hercules\ny\n'
rc_is 0 "a value of only whitespace: the run finishes"
has "Not read from 1Password  NetBird setup key" "and counts as unread"
reset; fresh_steps; items_all; rm -rf "$T/op-items/Private/NetBird setup key" "$T/op-items/Private/Syncthing GUI" "$T/op-items/Private/BorgBase hercules"; run 'hercules\ny\n'
has "Setup secrets ...... none read" "with every item missing, the summary reads none"
hasnt "is not a profile Vorta can import" "and step 15b has no export to check"
nowrite "every item missing"
# NetBird's done test.
: > "$T/fail-netbird"; : > "$T/fast-sleep"; reset; items_all; run 'hercules\ny\n'; rm -f "$T/fail-netbird" "$T/fast-sleep"
called "op read op://Private/NetBird setup key/credential" "a status netbird cannot give: the key is read"
for st in '{"version":"0.20"}' 'not json' '{"daemonStatus":"LoginFailed"}' '{"daemonStatus":"NeedsLogin"}'; do
  : > "$T/fast-sleep"; reset; items_all; printf '%s\n' "$st" > "$T/netbird-status"; run 'hercules\ny\n'; rm -f "$T/fast-sleep"
  called "op read op://Private/NetBird setup key/credential" "status $st: the key is read"
  case "$st" in '{"version"'*|'not json')
    has "NetBird did not join" "status $st: step 8c warns, a status that names no daemonStatus is unreadable"
    not_called "netbird up" "status $st: and runs no up" ;;
  esac
done
for st in Connected SessionExpired Idle Connecting; do
  reset; items_all; printf '{"daemonStatus":"%s"}\n' "$st" > "$T/netbird-status"; run 'hercules\ny\n'
  not_called "op read" "status $st: no key is read"
  not_called "netbird up" "status $st: no join"
done
called "netbird status --json" "the state is read from netbird status --json"
# Vorta's done test fails closed: a settings.db that cannot be read counts as done.
reset; items_all; printf 'not a database' > "$VORTA_DIR/settings.db"; run 'hercules\ny\n'
rc_is 0 "an unreadable settings.db: the run finishes"
not_called "op document get" "Vorta's export is not read"
has "⚠ Vorta's settings could not be read: no profile imported — see the vorta row" "and the closing list says so"
# The vault knob.
reset; fresh_steps; items_all Test; PROVISION_OP_VAULT=Test HV=1 run 'hercules\ny\n'
rc_is 0 "PROVISION_OP_VAULT inside a VM provisions"
called "op read op://Test/NetBird setup key/credential" "the reads use that vault"
called "op document get BorgBase hercules --vault Test" "the document too"
not_called "op://Private" "and none uses Private"
has "1Password vault .... Test" "the summary shows the vault"
reset; fresh_steps; items_all Test; PROVISION_OP_VAULT=Test HV=0 run 'hercules\ny\n'
rc_is 1 "PROVISION_OP_VAULT outside a VM is refused"
not_called "sudo -v" "before sudo is asked"
not_called "op read" "and nothing is read"
has "PROVISION_OP_VAULT" "and the refusal names the variable"
reset; fresh_steps; items_all; PROVISION_OP_VAULT= HV=0 run 'hercules\ny\n'
rc_is 0 "an empty PROVISION_OP_VAULT is unset"
called "op read op://Private/NetBird setup key/credential" "and the reads use Private"
hasnt "1Password vault" "with no vault line in the summary"
# A caller that already exports a secret's variable name: no child's environment carries it.
reset; fresh_steps; items_all; PV_NETBIRD_KEY=decoy1 PV_ST_USER=decoy2 PV_ST_PASSWORD=decoy3 PV_VORTA_EXPORT=decoy4 run 'hercules\ny\n'
rc_is 0 "a caller exporting all four secret variables: the run finishes"
called "op read op://Private/NetBird setup key/credential" "the key is still read"
called "configure-fullenv HOME=" "and configure.sh, a child started after the reads, ran"
not_called "configure-fullenv PV_" "no child started after the reads carries a PV_ variable"
not_called "netbird-env PV_" "nor does netbird"
for m in "$MK_NB" "$MK_ST" "$MK_VORTA" decoy1 decoy2 decoy3 decoy4; do not_called "$m" "no log line carries $m"; done
for m in "$MK_NB" "$MK_ST" "$MK_VORTA" decoy1 decoy2 decoy3 decoy4; do hasnt "$m" "the run prints no $m"; done

echo "V. NetBird joins with the setup key"
UP="netbird up --no-browser --setup-key-file /dev/stdin"
for st in NeedsLogin LoginFailed; do
  reset; items_all; printf '{"daemonStatus":"%s"}\n' "$st" > "$T/netbird-status"; run 'hercules\ny\n'
  rc_is 0 "$st: the run finishes"
  called "$UP" "$st: NetBird joins with the setup key on stdin"
  not_called "sudo netbird up" "$st: without sudo"
  [ "$(cat "$T/netbird-up-stdin" 2>/dev/null)" = "$MK_NB" ] && _pass "$st: stdin is exactly the key" || _fail "$st: stdin is exactly the key"
  not_called "netbird-env PV_" "$st: the key is in no netbird environment"
  not_called "$MK_NB" "$st: no log line carries the key"
  hasnt "$MK_NB" "$st: the run prints no key"
  hasnt "NetBird did not join" "$st: no warning"
done
# A key with shell-special content arrives byte for byte and nothing in it runs.
reset; items_all; echo '{"daemonStatus":"NeedsLogin"}' > "$T/netbird-status"
printf '%s\n' "-n \$(touch $T/pwned) \\x " > "$T/op-items/Private/NetBird setup key/credential"
run 'hercules\ny\n'
rc_is 0 "a key with shell-special content: the run finishes"
[ "$(cat "$T/netbird-up-stdin" 2>/dev/null)" = "-n \$(touch $T/pwned) \\x " ] && _pass "it reaches stdin byte for byte" || _fail "it reaches stdin byte for byte"
[ -e "$T/pwned" ] && _fail "and nothing in it ran" || _pass "and nothing in it ran"
# Any other state after the preflight read the key: joined or an SSO login's to renew, so no join.
for st in Connected SessionExpired; do
  reset; items_all; echo '{"daemonStatus":"NeedsLogin"}' > "$T/netbird-status"; printf '{"daemonStatus":"%s"}\n' "$st" > "$T/netbird-status-later"
  run 'hercules\ny\n'
  rc_is 0 "$st at step 8c: the run finishes"
  not_called "netbird up" "$st at step 8c: no join"
  has "NetBird is $st" "$st at step 8c: logged and skipped"
  hasnt "NetBird did not join" "$st at step 8c: no warning"
done
# A daemon 8b just started that has not settled (Idle, Connecting) is polled for 30 s, then warned about.
for st in Idle Connecting; do
  reset; items_all; echo '{"daemonStatus":"NeedsLogin"}' > "$T/netbird-status"; printf '{"daemonStatus":"%s"}\n' "$st" > "$T/netbird-status-later"
  : > "$T/fast-sleep"; run 'hercules\ny\n'; rm -f "$T/fast-sleep"
  rc_is 0 "$st at step 8c: the run finishes"
  not_called "netbird up" "$st at step 8c: no join"
  has "NetBird is still $st after 30 s — check netbird status" "$st at step 8c: the warning says it is still $st"
  hasnt "✓ NetBird is $st" "$st at step 8c: and does not read as joined"
  [ "$(grep -c '^sleep 2$' "$CALLS")" -eq 15 ] && _pass "$st at step 8c: polled for 15 steps, 30 s" || _fail "$st at step 8c: polled for 15 steps, 30 s ($(grep -c '^sleep 2$' "$CALLS"))"
done
reset; echo '{"daemonStatus":"NeedsLogin"}' > "$T/netbird-status"; run 'hercules\ny\n'
not_called "netbird up" "no key read: no join"
hasnt "NetBird did not join" "and no second warning (the preflight's already names the item)"
reset; items_all; echo '{"daemonStatus":"NeedsLogin"}' > "$T/netbird-status"; : > "$T/fail-netbird-up"; run 'hercules\ny\n'
rm -f "$T/fail-netbird-up"
rc_is 0 "a join that fails: the run finishes"
has "netbird up (SSO login)" "and the warning names the SSO fallback"
has "netbird-session-expiry" "and the session-expiry row"
hasnt "$MK_NB" "and prints no key"
# A status that never reads at step 8c: the 30 s wait runs, then the SSO fallback, never a join.
reset; items_all; echo '{"daemonStatus":"NeedsLogin"}' > "$T/netbird-status"; : > "$T/fast-sleep"; : > "$T/fail-netbird"; run 'hercules\ny\n'
rm -f "$T/fast-sleep" "$T/fail-netbird"
rc_is 0 "a status that cannot be read: the run finishes"
not_called "netbird up" "no join without a state"
has "netbird up (SSO login)" "and a warning names the SSO fallback"
called "sleep 2" "after waiting in 2 s steps"
[ "$(grep -c '^sleep 2$' "$CALLS")" -eq 15 ] && _pass "for 15 steps, 30 s" || _fail "for 15 steps, 30 s ($(grep -c '^sleep 2$' "$CALLS"))"

echo "W. Syncthing's config before its first start"
ST_GEN="syncthing generate --home $ST_DIR --gui-user st-user --gui-password=-"
xp(){ xmllint --xpath "string(//options/$1)" "$ST_DIR/config.xml" 2>/dev/null; }
OLD_UMASK=$(umask); umask 022
reset; fresh_steps; items_all; rmdir "$ST_DIR"; run 'hercules\ny\n'
rc_is 0 "a fresh machine: the run finishes"
called "$ST_GEN" "generate runs with the login's user and the password read from stdin"
# print -r -- sends the password and one newline.
[ "$(od -An -c "$T/syncthing-stdin" | tr -d ' \n')" = 'MARK-ST-PW-91c2\n' ] && _pass "stdin is exactly the password and one newline" || _fail "stdin is exactly the password and one newline"
not_called "syncthing-env PV_" "no secret variable is in Syncthing's environment"
not_called "$MK_ST" "no log line carries the password"
hasnt "$MK_ST" "the run prints no password"
[ "$(xp globalAnnounceEnabled)" = false ] && _pass "Global Discovery is off" || _fail "Global Discovery is off"
[ "$(xp relaysEnabled)" = false ] && _pass "Relaying is off" || _fail "Relaying is off"
[ "$(xp natEnabled)" = false ] && _pass "NAT traversal is off" || _fail "NAT traversal is off"
[ "$(xp localAnnounceEnabled)" = true ] && _pass "Local Discovery stays on" || _fail "Local Discovery stays on"
[ "$(xmllint --xpath 'string(//gui/user)' "$ST_DIR/config.xml")" = st-user ] && _pass "the GUI user is in the file" || _fail "the GUI user is in the file"
[ "$(stat -f %Lp "$ST_DIR/config.xml")" = 600 ] && _pass "config.xml is mode 600 under umask 022" || _fail "config.xml is mode 600 under umask 022"
[ "$(stat -f %Lp "$ST_DIR")" = 700 ] && _pass "the Syncthing folder is mode 700" || _fail "the Syncthing folder is mode 700"
hasnt "Syncthing's config was not generated" "and no warning"
hasnt "are not as section 8 E1 wants" "and none about the options"
# A password with shell-special content arrives byte for byte and nothing in it runs.
reset; fresh_steps; items_all
printf '%s\n' "-n \$(touch $T/pwned) \\x " > "$T/op-items/Private/Syncthing GUI/password"
run 'hercules\ny\n'
rc_is 0 "a password with shell-special content: the run finishes"
[ "$(cat "$T/syncthing-stdin" 2>/dev/null)" = "-n \$(touch $T/pwned) \\x " ] && _pass "it reaches stdin byte for byte" || _fail "it reaches stdin byte for byte"
[ -e "$T/pwned" ] && _fail "and nothing in it ran" || _pass "and nothing in it ran"
# A machine whose Syncthing has a config.xml is left alone.
reset; items_all; printf '<configuration version="52">kept</configuration>\n' > "$ST_DIR/config.xml"; cp "$ST_DIR/config.xml" "$T/config.before"
run 'hercules\ny\n'
not_called "syncthing generate" "an existing config.xml: nothing is generated"
cmp -s "$ST_DIR/config.xml" "$T/config.before" && _pass "and the file is byte-identical" || _fail "and the file is byte-identical"
# Syncthing started during the run (the Brewfile step), after the preflight read the login: warn, do not generate.
mkdir -p "$T/home/.config/homebrew"; : > "$T/home/.config/homebrew/Brewfile"
reset; fresh_steps; items_all; : > "$T/st-appears"; run 'hercules\ny\n'; rm -rf "$T/home/.config/homebrew"
rc_is 0 "a config.xml that appears after the preflight: the run finishes"
has "Syncthing already has a config.xml (it started during this run) — set its GUI login and options by hand: see the syncthing-settings row" "the warning says so"
not_called "syncthing generate" "and nothing is generated"
# A generate that fails.
reset; fresh_steps; items_all; : > "$T/fail-syncthing"; run 'hercules\ny\n'
rc_is 0 "a failing generate: the run finishes"
has "Syncthing's config was not generated — see the syncthing-settings row" "and the warning names the row"
[ -e "$ST_DIR/config.xml" ] && _fail "and no config.xml is left" || _pass "and no config.xml is left"
# Syncthing.app missing (its cask failed): a warning, no generate.
reset; fresh_steps; items_all; mv "$T/apps/Syncthing.app" "$T/Syncthing.app.away"; run 'hercules\ny\n'; mv "$T/Syncthing.app.away" "$T/apps/Syncthing.app"
rc_is 0 "no Syncthing.app: the run finishes"
has "Syncthing.app is not installed" "and the warning says so"
not_called "syncthing generate" "and nothing is generated"
[ -e "$ST_DIR/config.xml" ] && _fail "and no config.xml is written" || _pass "and no config.xml is written"
# A generated file whose options cannot be turned off.
reset; fresh_steps; items_all; : > "$T/st-no-relays"; run 'hercules\ny\n'; rm -f "$T/st-no-relays"
rc_is 0 "a config without <relaysEnabled>: the run finishes"
has "Syncthing's options relaysEnabled are not as section 8 E1 wants — set them in Syncthing's GUI" "and the warning names the option"
hasnt "Syncthing's options globalAnnounceEnabled" "and only that one"
# Without the login (item unread), nothing is generated.
reset; fresh_steps; items_all; rm -rf "$T/op-items/Private/Syncthing GUI"; run 'hercules\ny\n'
not_called "syncthing generate" "no login read: nothing is generated"
umask "$OLD_UMASK"

echo "X. Vorta imports its own export"
OLD_UMASK=$(umask); umask 022
mkdir -p "$T/apps/Vorta.app"; : > "$T/vorta-imports"; : > "$T/fast-sleep"
reset; fresh_steps; items_all; run 'hercules\ny\n'
rc_is 0 "a fresh machine: the run finishes"
called "open -g -a Vorta" "Vorta is started in the background"
[ "$(cat "$T/vorta-init-mode" 2>/dev/null)" = 600 ] && _pass "the file is mode 600 under umask 022" || _fail "the file is mode 600 under umask 022"
printf '%s\n' "$VORTA_EXPORT" | cmp -s - "$T/vorta-init-seen" && _pass "Vorta sees the export byte for byte" || _fail "Vorta sees the export byte for byte"
[ -e "$VI" ] && _fail "the file is gone after the import" || _pass "the file is gone after the import"
ol=$(grep -n '^open -g -a Vorta' "$CALLS" | head -1 | cut -d: -f1); cl=$(grep -n 'configure.sh --hostname' "$CALLS" | head -1 | cut -d: -f1)
{ [ -n "$ol" ] && [ -n "$cl" ] && [ "$ol" -lt "$cl" ]; } && _pass "Vorta starts before configure.sh" || _fail "Vorta starts before configure.sh"
not_called "$MK_VORTA" "no log line carries the password"
hasnt "$MK_VORTA" "the run prints no password"
# Vorta never imports (macOS's first-open prompt, say): the file stays and the warning says what is left.
rm -f "$T/vorta-imports"
reset; fresh_steps; items_all; run 'hercules\ny\n'
rc_is 0 "no import: the run finishes"
[ -f "$VI" ] && _pass "the file stays" || _fail "the file stays"
has "answer macOS's prompt to open Vorta" "and the warning says what is left"
has "$VI" "and names the file"
hasnt "$MK_VORTA" "and prints no password"
[ "$(grep -c '^sleep 5$' "$CALLS")" -eq 24 ] && _pass "the wait is 24 steps of 5 s, 120 s" || _fail "the wait is 24 steps of 5 s, 120 s ($(grep -c '^sleep 5$' "$CALLS"))"
: > "$T/vorta-imports"
# A profile with a repository, or a settings.db that cannot be read: the export is not even read.
reset; items_all; run 'hercules\ny\n'
nowrite "a configured profile"
reset; items_all; printf 'not a database' > "$VORTA_DIR/settings.db"; run 'hercules\ny\n'
nowrite "a settings.db that is not a database"
# Vorta running.
: > "$T/vorta-running"
reset; fresh_steps; items_all; run 'hercules\ny\n'; rm -f "$T/vorta-running"
rc_is 0 "Vorta running: the run finishes"
nowrite "Vorta running"
has "quit Vorta, then run provision.sh again" "and the warning says what to do"
called "pgrep -x vorta-darwin" "and the process asked about is Vorta's"
# A file already there stays as it is.
reset; fresh_steps; items_all; printf 'keep me\n' > "$VI"; run 'hercules\ny\n'
not_called "open -g -a Vorta" "an existing file: Vorta is not started"
[ "$(cat "$VI")" = "keep me" ] && _pass "an existing file: its content is unchanged" || _fail "an existing file: its content is unchanged"
has "$VI already exists" "and the warning names it"
# A dangling symlink is not followed.
reset; fresh_steps; items_all; ln -s "$T/elsewhere" "$VI"; run 'hercules\ny\n'
rc_is 0 "a dangling symlink: the run finishes"
not_called "open -g -a Vorta" "a dangling symlink: Vorta is not started"
[ -e "$T/elsewhere" ] && _fail "nothing is written through the symlink" || _pass "nothing is written through the symlink"
[ -L "$VI" ] && _pass "and the symlink is left" || _fail "and the symlink is left"
has "$VI already exists" "and the warning names it"
# Vorta.app missing (its cask failed): a warning, nothing written.
reset; fresh_steps; items_all; mv "$T/apps/Vorta.app" "$T/Vorta.app.away"; run 'hercules\ny\n'; mv "$T/Vorta.app.away" "$T/apps/Vorta.app"
rc_is 0 "no Vorta.app: the run finishes"
nowrite "no Vorta.app"
has "Vorta.app is not installed" "and the warning says so"
# An export Vorta could not import is never written; no export text reaches the output.
for bad in '[]' "not json $MK_VORTA {" \
  '{"id":"1","name":"'"$MK_VORTA"'","SchemaVersion":{"version":23},"repo":{"url":"u"},"password":"x"}' \
  '{"id":1,"name":"'"$MK_VORTA"'","SchemaVersion":{"version":23},"repo":{"url":"u"},"password":""}' \
  '{"id":1,"name":"'"$MK_VORTA"'","SchemaVersion":{"version":23},"repo":{"url":"u"}}'; do
  reset; fresh_steps; items_all; put_item Private "BorgBase hercules" document "$bad"; run 'hercules\ny\n'
  rc_is 0 "an export that fails the check: the run finishes"
  nowrite "an export that fails the check"
  has "is not a profile Vorta can import" "and the warning says so"
  hasnt "$MK_VORTA" "and no marker reaches the output"
  not_called "$MK_VORTA" "nor the log"
done
rm -f "$T/fast-sleep"
umask "$OLD_UMASK"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
