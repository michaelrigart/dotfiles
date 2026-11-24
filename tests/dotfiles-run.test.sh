#!/usr/bin/env bash
# Tests dotfiles-run in dot_config/zsh/functions: it runs .scripts/<name>.sh from a fresh clone
# of origin's main, never from the main checkout, which the sandbox can write (spec
# 2026-11-22-complete-provisioning, §2). git is real; origin is a local bare repository whose
# probe script prints where it runs from and its arguments, and exits with PROBE_RC.
#
#   ./tests/dotfiles-run.test.sh   (sandboxed is fine)
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
FUNCS="$SRC/dot_config/zsh/functions"
[ -f "$FUNCS" ] || { echo "missing file under test: $FUNCS"; exit 2; }
command -v zsh >/dev/null 2>&1 || { echo "INCONCLUSIVE: zsh is not on PATH"; exit 2; }
pass=0; fail=0; OUT=""; RC=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
rc_is() { [ "$RC" -eq "$1" ] && ok "$2" || bad "$2 (exit $RC, wanted $1: $OUT)"; }
has()   { case "$OUT" in *"$1"*) ok "$2" ;; *) bad "$2 (got: $OUT)" ;; esac; }
hasnt() { case "$OUT" in *"$1"*) bad "$2 (got: $OUT)" ;; *) ok "$2" ;; esac; }

T=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-run.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

# origin's main has the reviewed probe; the checkout cloned from it then has a planted one.
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/checkout" 2>/dev/null
mkdir -p "$T/checkout/.scripts"
cat > "$T/checkout/.scripts/probe.sh" <<'P'
#!/bin/sh
echo "reviewed probe in $(cd "$(dirname "$0")/.." && pwd -P)"
for a in "$@"; do echo "arg [$a]"; done
exit "${PROBE_RC:-0}"
P
printf '#!/bin/sh\necho data\n' > "$T/checkout/.scripts/notexec.sh"
chmod 755 "$T/checkout/.scripts/probe.sh"
git -C "$T/checkout" add -A && git -C "$T/checkout" commit -qm reviewed && git -C "$T/checkout" push -q origin main
printf '#!/bin/sh\necho planted probe\n' > "$T/checkout/.scripts/probe.sh"

# run [env...] -- <args>: dotfiles-run in a zsh started in the planted checkout.
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  OUT=$(cd "$T/checkout" && env CHEZMOI_REVIEWED_ORIGIN="file://$T/origin.git" XDG_CACHE_HOME="$T/cache" ${envs[@]+"${envs[@]}"} \
    zsh -f -c 'source "$1"; shift; dotfiles-run "$@"' zsh "$FUNCS" "$@" 2>&1)
  RC=$?
}

echo "1. it runs origin's script from a fresh clone"
run -- probe "two words" ""
rc_is 0 "exit 0"
has "reviewed probe in $T/cache/dotfiles-run/run." "the reviewed script runs, from a clone in the cache"
hasnt "planted probe" "never the checkout's"
has "arg [two words]" "arguments pass through whole"
has "arg []" "an empty argument too"
has "dotfiles-run: running probe.sh from origin's main $(git -C "$T/origin.git" rev-parse --short=12 main), a fresh clone" "it says which commit runs"
[ -z "$(ls -A "$T/cache/dotfiles-run")" ] && ok "the clone is removed afterwards" || bad "the clone is removed afterwards ($(ls -A "$T/cache/dotfiles-run"))"
run PROBE_RC=3 -- probe
rc_is 3 "the script's exit status is returned"

echo "2. what it refuses"
for n in "" "../probe" "probe.sh" "x/probe" "Probe"; do
  run -- "$n"
  rc_is 2 "the name [$n]: exit 2"
done
has "usage: dotfiles-run <script> [args]" "with the usage"
[ ! -e "$T/cache/dotfiles-run" ] || [ -z "$(ls -A "$T/cache/dotfiles-run")" ] && ok "and nothing is cloned" || bad "and nothing is cloned"
run -- missing
rc_is 2 "a script origin's main lacks: exit 2"
has "dotfiles-run: origin's main has no .scripts/missing.sh" "and says so"
run -- notexec
rc_is 2 "a script that is not executable: exit 2"
run CHEZMOI_REVIEWED_ORIGIN="$T/nowhere.git" -- probe
rc_is 1 "origin cannot be cloned: exit 1"
has "dotfiles-run: cannot clone origin's main" "and says so"
[ -z "$(ls -A "$T/cache/dotfiles-run")" ] && ok "and leaves no clone behind" || bad "and leaves no clone behind"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
