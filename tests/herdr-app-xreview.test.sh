#!/bin/zsh
# Tests for bin/xreview-app, as chezmoi renders it from dot_config/herdr-app. Run: ./tests/herdr-app-xreview.test.sh
#
# xreview-app is a wrapper that stays for sessions recorded with its path (spec 2026-11-14, 5.7):
# it pins PATH and runs xreview, which picks the app front end itself. The helper xreview drives is
# tested in tests/xreview-app-pane.test.sh. xreview is never run here: a stand-in takes its place.
emulate -L zsh
setopt no_unset pipe_fail

here=${0:A:h}
SRC=${0:A:h:h}
for f in dot_config/herdr-app/bin/executable_xreview-app; do
  [[ -f $SRC/$f ]] || { print -u2 -- "missing $f"; exit 2 }
done
source $here/fixtures/herdr-app/render.zsh
root=$(mktemp -d "${TMPDIR:-/tmp}/xreview-app-tests.XXXXXX") || exit 1
root=${root:A}
trap 'rm -rf "$root"' EXIT
herdr_app_render $root/r || { print -u2 -- "INCONCLUSIVE: chezmoi could not render dot_config/herdr-app"; exit 2 }
bin=$root/r/home/.config/herdr-app/bin
unset PINNED_PATH XREVIEW_APP_XREVIEW

typeset -i passed=0 total=0
exec 9>&1  # check reports here, so a check called with its output redirected still counts for run.sh
check() { # <description> <command...>: passes when the command succeeds
  local what=$1; shift
  (( ++total ))
  if "$@"; then (( ++passed )); print -u9 -- "  PASS: $what"; else print -u9 -- "  FAIL: $what"; fi
}
same() { [[ $1 == $2 ]] }

# --- xreview-app ---------------------------------------------------------------------------
# A stand-in for xreview, said to be the one to run through XREVIEW_APP_XREVIEW. It records its
# arguments, the PATH it was started with and whether a PINNED_PATH reached it.
world=$root/world; mkdir -p $world
cat > $world/xreview <<'EOS'
#!/bin/bash
echo "PATH=$PATH"
echo "PINNED_PATH=${PINNED_PATH-unset}"
printf '[%s]\n' "$@"
exit 7
EOS
chmod +x $world/xreview
# xreview-app runs outside the sandbox with the caller's PATH. With tools planted in a folder first
# on that PATH, none may run.
mkdir -p $world/planted $world/marks
for tool in grep jq xreview; do
  printf '#!/bin/sh\necho planted >> %s/%s\nexit 1\n' $world/marks $tool > $world/planted/$tool
  chmod +x $world/planted/$tool
done
marks() { local -a m; m=($world/marks/*(N:t)); print -r -- $m }
PATH=$world/planted:$PATH XREVIEW_APP_XREVIEW=$world/xreview "$bin/xreview-app" round "two words" --flag >$world/out 2>$world/err; rc=$?
check "xreview-app is executable" test -x $bin/xreview-app
check "xreview-app passes xreview's exit status on" test $rc -eq 7
check "xreview gets its arguments as they were" same "$(sed -n '3,$p' $world/out | tr '\n' ' ')" "[round] [two words] [--flag] "
check "xreview is started with the PATH of folders the sandbox cannot write" same "$(sed -n 1p $world/out)" "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
check "the wrapper sets no PINNED_PATH" same "$(sed -n 2p $world/out)" "PINNED_PATH=unset"
check "planted tools first on the caller's PATH: none of them runs" same "$(marks)" ""

# Sessions recorded with the wrapper's path never set XREVIEW_APP_XREVIEW: the default is $HOME/.local/bin/xreview.
mkdir -p $world/home/.local/bin; cp $world/xreview $world/home/.local/bin/xreview
HOME=$world/home "$bin/xreview-app" round "two words" >$world/out 2>$world/err; rc=$?
check "without XREVIEW_APP_XREVIEW it runs \$HOME/.local/bin/xreview" test $rc -eq 7
check "...with the arguments unchanged" same "$(sed -n '3,$p' $world/out | tr '\n' ' ')" "[round] [two words] "

XREVIEW_APP_XREVIEW=$world/absent "$bin/xreview-app" >$world/out 2>$world/err; rc=$?
check "a missing xreview is an error" test $rc -ne 0

print -- "$passed/$total passed"
(( passed == total ))
