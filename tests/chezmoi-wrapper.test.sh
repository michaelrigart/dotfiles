#!/usr/bin/env zsh
# Tests the chezmoi wrapper in dot_config/zsh/functions (spec 2026-10-16, sandbox write
# boundary, section 3): apply and update deploy a fresh clone of origin's main, only from a
# clean main checkout equal to it, and the previews that run the working tree's code (diff,
# status, cat, verify, dump, archive, execute-template) read the same clone; --dirty-ok runs the
# working tree. chezmoi is a stub
# that records its arguments and what its --source holds; git is real, origin is a local bare
# repository.
#
#   ./tests/chezmoi-wrapper.test.sh   (sandboxed is fine)
emulate -L zsh
setopt no_unset pipe_fail
SRC=${0:A:h:h}
FUNCS=$SRC/dot_config/zsh/functions
[[ -f $FUNCS ]] || { print -u2 "missing file under test: $FUNCS"; exit 2 }
integer pass=0 fail=0
_pass() { print "  PASS: $1"; (( ++pass )); return 0 }
_fail() { print "  FAIL: $1\n    | got: $2"; (( ++fail )); return 0 }
T=$(mktemp -d "${TMPDIR:-/tmp}/chezmoi-wrapper.XXXXXX")
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=$T/gitconfig GIT_CONFIG_NOSYSTEM=1 TMPDIR=$T/tmp XDG_CACHE_HOME=$T/cache
mkdir -p $T/tmp $T/bin $T/cache
print -r -- $'[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main' > $GIT_CONFIG_GLOBAL

# The stub: `chezmoi source-path` prints the checkout; anything else logs its arguments and
# the listing of the --source directory (or "WORKTREE" without one).
cat > $T/bin/chezmoi <<'EOF'
#!/bin/sh
[ "$1" = source-path ] && { printf '%s\n' "$CHECKOUT"; exit 0; }
src=""; prev=""
for a in "$@"; do [ "$prev" = --source ] && src=$a; prev=$a; done
printf 'ARGS %s\n' "$*" > "$LOG"
printf 'TMPDIR %s\n' "$TMPDIR" >> "$LOG"
if [ -n "$src" ]; then printf 'SOURCE %s\n' "$src" >> "$LOG"; ls -A "$src" >> "$LOG"; else echo WORKTREE >> "$LOG"; fi
exit ${STUBRC:-0}
EOF
chmod 755 $T/bin/chezmoi
# The git stub: GITSTUB=clonefail makes `git clone` fail; GITSTUB=badhead makes the fresh clone
# report a HEAD that is not origin's. Anything else goes to the real git.
export REALGIT=$(command -v git)
cat > $T/bin/git <<'EOF'
#!/bin/sh
case "$GITSTUB" in
  clonefail) for a in "$@"; do [ "$a" = clone ] && exit 128; done ;;
  badhead) if [ "$1" = -C ]; then case "$2" in */src) [ "$3" = rev-parse ] && { echo 0000000000000000000000000000000000000000; exit 0; } ;; esac; fi ;;
esac
exec "$REALGIT" "$@"
EOF
chmod 755 $T/bin/git
path=($T/bin /usr/bin /bin /opt/homebrew/bin)
export LOG=$T/log CHEZMOI_REVIEWED_ORIGIN=$T/origin.git
source $FUNCS

# origin: a bare repo whose main holds dot_testfile.
git init -q --bare $T/origin.git
git clone -q $T/origin.git $T/seed 2>/dev/null
print hello > $T/seed/dot_testfile
git -C $T/seed add dot_testfile && git -C $T/seed commit -q -m init && git -C $T/seed push -q origin main 2>/dev/null
WANT=$(git -C $T/seed rev-parse HEAD)

# --no-local: the checkout gets its own object files, so a forged object in it can never
# alter origin's through a hard link.
fresh() { rm -rf $T/co; git clone -q --no-local $T/origin.git $T/co 2>/dev/null; export CHECKOUT=$T/co; rm -f $LOG }
applied_clone() { [[ -f $LOG ]] && grep -q '^SOURCE ' $LOG && grep -qx dot_testfile $LOG && ! grep -q "$1" $LOG }
tmp_clean() { [[ ! -d $T/cache/chezmoi-apply || -z $(ls -A $T/cache/chezmoi-apply) ]] }

fresh; chezmoi apply >/dev/null 2>&1
if applied_clone NOPE && grep -q "^ARGS --source $T/cache/chezmoi-apply/run\..*/src apply$" $LOG \
   && grep -q "^TMPDIR $T/cache/chezmoi-apply/run\..*/tmp$" $LOG && tmp_clean; then
  _pass "a clean main equal to origin applies a fresh clone kept under the cache, with chezmoi's TMPDIR there"
else _fail "clean main applies a fresh clone under the cache" "$(cat $LOG 2>/dev/null)"; fi
fresh; chezmoi apply -v >/dev/null 2>&1
applied_clone NOPE && grep -q -- ' apply -v$' $LOG && _pass "options after apply take the wrapper's path" || _fail "apply -v" "$(cat $LOG 2>/dev/null)"
for form in "-v apply" "--progress auto apply" "--source $T/co apply" "-S $T/co update" "--color off init --apply"; do
  fresh; err=$(chezmoi ${=form} 2>&1 >/dev/null); rc=$?
  (( rc == 1 )) && [[ $err == *"put the subcommand first"* ]] && [[ ! -e $LOG ]] \
    && _pass "chezmoi $form is refused: subcommand first" || _fail "chezmoi $form is refused" "rc=$rc err=$err"
done
for form in "apply --source $T/co" "apply --source=$T/co" "apply -S$T/co" "apply -vS$T/co" "apply -nvc$T/x.toml" \
            "apply --config $T/x.toml" "update --working-tree $T/co"; do
  fresh; err=$(chezmoi ${=form} 2>&1 >/dev/null); rc=$?
  (( rc == 1 )) && [[ $err == *"the wrapper chooses the source"* ]] && [[ ! -e $LOG ]] \
    && _pass "chezmoi $form is refused" || _fail "chezmoi $form is refused" "rc=$rc err=$err"
done
for form in "init --apply" "init --apply=true" "init -a" "init -va" "init -av" "init -a=true" \
            "edit --apply x" "edit --apply=1 x"; do
  fresh; err=$(chezmoi ${=form} 2>&1 >/dev/null); rc=$?
  (( rc == 1 )) && [[ $err == *"--apply is refused"* ]] && [[ ! -e $LOG ]] \
    && _pass "chezmoi $form is refused" || _fail "chezmoi $form is refused" "rc=$rc err=$err"
done
fresh; chezmoi --version >/dev/null 2>&1; grep -q '^ARGS --version$' $LOG && _pass "an option-only command passes through" || _fail "--version" "$(cat $LOG 2>/dev/null)"
fresh; chezmoi apply --dry-run --verbose >/dev/null 2>&1
grep -q -- '--dry-run --verbose' $LOG 2>/dev/null && applied_clone NOPE && _pass "the dry-run preview takes the same path" || _fail "dry-run" "$(cat $LOG 2>/dev/null)"

refuses() { # refuses <label> <expected reason text>: chezmoi apply returns 1, names it, runs nothing
  local err; err=$(chezmoi apply 2>&1 >/dev/null); local rc=$?
  if (( rc == 1 )) && [[ $err == *"$2"* ]] && [[ ! -e $LOG ]] && tmp_clean; then _pass "$1"
  else _fail "$1" "rc=$rc err=$err log=$(cat $LOG 2>/dev/null)"; fi
}
fresh; git -C $T/co switch -q -c other; refuses "another branch is refused" "not on main"
fresh; print change >> $T/co/dot_testfile; refuses "an uncommitted change is refused" "uncommitted"
fresh; print x > $T/co/newfile; refuses "an untracked file is refused" "uncommitted"
fresh; git -C $T/co commit -q --allow-empty -m local; refuses "a local commit origin lacks is refused" "origin's main is"
fresh; git -C $T/seed commit -q --allow-empty -m ahead && git -C $T/seed push -q origin main 2>/dev/null
refuses "origin ahead of the checkout is refused" "origin's main is"
WANT=$(git -C $T/seed rev-parse HEAD)

# Planted content in a checkout that passes the precondition never reaches the source.
fresh; print 'touch PWNED' > $T/co/run_evil.sh; print run_evil.sh >> $T/co/.git/info/exclude
chezmoi apply >/dev/null 2>&1; applied_clone run_evil.sh && _pass "a run_ script hidden by .git/info/exclude is not applied" || _fail "excluded run_ script" "$(cat $LOG 2>/dev/null)"
# mkevil: in the current checkout, a commit whose tree holds run_evil.sh; sets EVIL and EVILTREE.
mkevil() {
  local blob; blob=$(print 'touch PWNED' | git -C $T/co hash-object -w --stdin) || return 1
  EVILTREE=$(printf '100644 blob %s\trun_evil.sh\n' $blob | git -C $T/co mktree) || return 1
  EVIL=$(git -C $T/co commit-tree -m evil $EVILTREE) || return 1
  [[ -n $EVIL && -n $EVILTREE ]]
}
fresh; if mkevil && git -C $T/co replace $WANT $EVIL; then
  chezmoi apply >/dev/null 2>&1; applied_clone run_evil.sh && _pass "a replacement ref for origin's commit is not applied" || _fail "replace ref" "$(cat $LOG 2>/dev/null)"
else _fail "replace-ref fixture" "setup failed"; fi
fresh; if mkevil && git -C $T/co update-ref refs/remotes/origin/main $EVIL \
     && [[ $(git -C $T/co rev-parse refs/remotes/origin/main) == $EVIL ]]; then
  chezmoi apply >/dev/null 2>&1; applied_clone run_evil.sh && _pass "a moved refs/remotes/origin/main is not applied" || _fail "moved remote ref" "$(cat $LOG 2>/dev/null)"
else _fail "moved-ref fixture" "setup failed"; fi
fresh; obj=$T/co/.git/objects/${WANT[1,2]}/${WANT[3,-1]}
if mkevil && mkdir -p ${obj:h} && printf 'tree %s\nauthor x <x> 0 +0000\ncommitter x <x> 0 +0000\n\nforged\n' $EVILTREE \
     | /usr/bin/python3 -c 'import sys,zlib; d=sys.stdin.buffer.read(); sys.stdout.buffer.write(zlib.compress(b"commit %d\0" % len(d) + d))' > $obj \
     && [[ -s $obj ]]; then
  # Whether git reads the forged loose copy or the packed original decides what the checkout
  # looks like; either way the outcome must be safe. If it reads the forgery, the checkout no
  # longer matches its index and the wrapper refuses. If not, it applies the fresh clone.
  # Never the forged tree.
  chezmoi apply >/dev/null 2>&1; rc=$?
  if [[ $(git -C $T/co cat-file -p $WANT | tail -1) == forged ]]; then
    (( rc == 1 )) && [[ ! -e $LOG ]] && _pass "a forged object that git reads makes the wrapper refuse" \
      || _fail "forged object read by git" "rc=$rc log=$(cat $LOG 2>/dev/null)"
  else
    applied_clone run_evil.sh && _pass "a forged object git ignores leaves the fresh clone applied" \
      || _fail "forged object ignored by git" "$(cat $LOG 2>/dev/null)"
  fi
  [[ $(git -C $T/origin.git cat-file -p $WANT | tail -1) != forged ]] && _pass "origin's own object stays intact" \
    || _fail "origin's object" "forged through a hard link"
else _fail "forged-object fixture" "setup failed"; fi

# The checkout's own remote is not what is deployed: another repository whose main carries
# run_evil.sh, set as remote.origin.url, changes nothing, for apply and for update.
git init -q --bare $T/evil.git
git clone -q $T/origin.git $T/evilseed 2>/dev/null
print 'touch PWNED' > $T/evilseed/run_evil.sh
git -C $T/evilseed add run_evil.sh && git -C $T/evilseed commit -q -m evil && git -C $T/evilseed push -q $T/evil.git main 2>/dev/null
fresh; git -C $T/co remote set-url origin $T/evil.git; chezmoi apply >/dev/null 2>&1
applied_clone run_evil.sh && _pass "a repointed remote.origin.url still deploys the pinned origin's main" || _fail "repointed remote" "$(cat $LOG 2>/dev/null)"
fresh; git -C $T/co remote set-url origin $T/evil.git
git -C $T/seed commit -q --allow-empty -m ahead3 && git -C $T/seed push -q origin main 2>/dev/null
chezmoi update >/dev/null 2>&1
applied_clone run_evil.sh && [[ $(git -C $T/co rev-parse HEAD) == $(git -C $T/seed rev-parse HEAD) ]] \
  && _pass "update pulls from the pinned origin, not the repointed remote" || _fail "update with a repointed remote" "$(cat $LOG 2>/dev/null)"
# The checkout's configuration cannot run a program through the wrapper's git reads.
print -r -- $'#!/bin/sh\ntouch "$FSMON_MARK"' > $T/fsmon.sh; chmod 755 $T/fsmon.sh
fresh; git -C $T/co config core.fsmonitor $T/fsmon.sh
FSMON_MARK=$T/FSMON chezmoi apply >/dev/null 2>&1
[[ ! -e $T/FSMON ]] && applied_clone NOPE && _pass "core.fsmonitor in the checkout is never run" || _fail "core.fsmonitor ran" "$(cat $LOG 2>/dev/null)"

# Every command that would apply the working tree is refused, with a pointer to apply.
refused() { # refused <command line> <expected text>: returns 1, names it, runs nothing
  fresh; local err; err=$(chezmoi ${=1} 2>&1 >/dev/null); local rc=$?
  (( rc == 1 )) && [[ $err == *"$2"* ]] && [[ ! -e $LOG ]] \
    && _pass "chezmoi $1 is refused" || _fail "chezmoi $1 is refused" "rc=$rc err=$err log=$(cat $LOG 2>/dev/null)"
}
refused "init --one-shot" "--one-shot is refused"
refused "init --one-shot=true" "--one-shot is refused"
refused "edit --watch" "--watch is refused"
refused "edit --watch=true x" "--watch is refused"
refused "init" "chezmoi apply --init"
refused "init $T/origin.git" "chezmoi apply --init"
refused "update --apply=false" "update-only flags are not supported"
refused "update -a" "update-only flags are not supported"
refused "update --recurse-submodules=false" "update-only flags are not supported"
fresh; chezmoi apply -xscripts >/dev/null 2>&1
applied_clone NOPE && grep -q -- ' apply -xscripts$' $LOG && _pass "-xscripts is a value, not -c: apply is not refused" || _fail "apply -xscripts" "$(cat $LOG 2>/dev/null)"
# update checks the branch before it pulls: a feature branch is refused and does not move.
fresh; git -C $T/co switch -q -c feature
git -C $T/seed commit -q --allow-empty -m ahead4 && git -C $T/seed push -q origin main 2>/dev/null
before=$(git -C $T/co rev-parse HEAD); err=$(chezmoi update 2>&1 >/dev/null); rc=$?
(( rc == 1 )) && [[ $err == *"not on main"* ]] && [[ ! -e $LOG ]] \
  && [[ $(git -C $T/co rev-parse HEAD) == $before && $(git -C $T/co symbolic-ref --short HEAD) == feature ]] \
  && _pass "update on a feature branch is refused and the branch does not move" || _fail "update on a feature branch" "rc=$rc err=$err"

# The temporary clone is removed however the run ends.
fresh; ( export GITSTUB=clonefail; chezmoi apply ) >/dev/null 2>&1; rc=$?
(( rc != 0 )) && [[ ! -e $LOG ]] && tmp_clean && _pass "a failed clone leaves nothing behind" || _fail "failed clone" "rc=$rc left=$(ls -A $T/cache/chezmoi-apply)"
fresh; err=$( ( export GITSTUB=badhead; chezmoi apply ) 2>&1 >/dev/null ); rc=$?
(( rc == 1 )) && [[ $err == *"moved during the clone"* ]] && [[ ! -e $LOG ]] && tmp_clean \
  && _pass "a clone whose HEAD is not origin's is not applied and leaves nothing behind" || _fail "clone HEAD mismatch" "rc=$rc err=$err left=$(ls -A $T/cache/chezmoi-apply)"
fresh; ( export STUBRC=3; chezmoi apply ) >/dev/null 2>&1; rc=$?
(( rc == 3 )) && [[ -e $LOG ]] && tmp_clean && _pass "chezmoi's exit status is returned and the clone is removed" || _fail "chezmoi exits non-zero" "rc=$rc left=$(ls -A $T/cache/chezmoi-apply)"

fresh; print change >> $T/co/dot_testfile; chezmoi apply --dirty-ok >/dev/null 2>&1
grep -qx WORKTREE $LOG 2>/dev/null && ! grep -q -- --dirty-ok $LOG && _pass "--dirty-ok applies the working tree and never reaches chezmoi" || _fail "--dirty-ok" "$(cat $LOG 2>/dev/null)"
fresh; chezmoi managed >/dev/null 2>&1; grep -q '^ARGS managed$' $LOG && _pass "other subcommands pass through" || _fail "passthrough" "$(cat $LOG 2>/dev/null)"
fresh; git -C $T/seed commit -q --allow-empty -m ahead2 && git -C $T/seed push -q origin main 2>/dev/null
chezmoi update >/dev/null 2>&1
grep -q '^ARGS --source .* apply$' $LOG 2>/dev/null && [[ $(git -C $T/co rev-parse HEAD) == $(git -C $T/seed rev-parse HEAD) ]] \
  && _pass "update fast-forwards, then applies a fresh clone" || _fail "update" "$(cat $LOG 2>/dev/null)"
[[ $(git -C $T/co rev-parse refs/remotes/origin/main) == $(git -C $T/co rev-parse HEAD) ]] \
  && _pass "update leaves refs/remotes/origin/main at the new HEAD" || _fail "update leaves origin/main stale" "origin/main=$(git -C $T/co rev-parse refs/remotes/origin/main) HEAD=$(git -C $T/co rev-parse HEAD)"
git -C $T/co status -sb | head -1 | grep -q ahead && _fail "update leaves the checkout ahead of origin/main" "$(git -C $T/co status -sb | head -1)" \
  || _pass "update leaves the checkout level with origin/main"
tmp_clean && _pass "no temporary clone is left behind" || _fail "temporary clones" "$(ls -A $T/cache/chezmoi-apply)"

# The previews run modify_ scripts and template output calls from the working tree, so they
# take apply's path: refused unless the checkout is clean main equal to origin's, else a fresh
# clone. --dirty-ok runs the working tree.
GATED=(diff status cat verify dump archive execute-template)
gated_refuses() { # gated_refuses <label> <command> <expected reason>: refused, reason and pointer named, nothing run
  local err; err=$(chezmoi ${=2} 2>&1 >/dev/null); local rc=$?
  if (( rc == 1 )) && [[ $err == *"$3"* && $err == *"chezmoi ${2%% *} --dirty-ok runs on the working tree"* ]] && [[ ! -e $LOG ]] && tmp_clean; then _pass "$1"
  else _fail "$1" "rc=$rc err=$err log=$(cat $LOG 2>/dev/null)"; fi
}
for c in $GATED; do
  fresh; git -C $T/co switch -q -c other; gated_refuses "chezmoi $c on another branch is refused" "$c" "not on main"
  fresh; print change >> $T/co/dot_testfile; gated_refuses "chezmoi $c with an uncommitted change is refused" "$c" "uncommitted"
  fresh; print x > $T/co/newfile; gated_refuses "chezmoi $c with an untracked file is refused" "$c" "uncommitted"
  fresh; git -C $T/co commit -q --allow-empty -m local; gated_refuses "chezmoi $c with a local commit is refused" "$c" "origin's main is"
  fresh; chezmoi $c -v >/dev/null 2>&1
  if applied_clone NOPE && grep -q "^ARGS --source $T/cache/chezmoi-apply/run\..*/src $c -v$" $LOG && tmp_clean; then
    _pass "chezmoi $c on a clean main runs against a fresh clone, removed afterwards"
  else _fail "chezmoi $c on a clean main" "$(cat $LOG 2>/dev/null)"; fi
  fresh; print change >> $T/co/dot_testfile; chezmoi $c --dirty-ok -v >/dev/null 2>&1
  grep -qx WORKTREE $LOG 2>/dev/null && grep -q "^ARGS $c -v$" $LOG && _pass "chezmoi $c --dirty-ok runs the working tree and never reaches chezmoi" \
    || _fail "chezmoi $c --dirty-ok" "$(cat $LOG 2>/dev/null)"
  fresh; err=$(chezmoi $c --source $T/co 2>&1 >/dev/null); rc=$?
  (( rc == 1 )) && [[ $err == *"the wrapper chooses the source"* ]] && [[ ! -e $LOG ]] \
    && _pass "chezmoi $c --source is refused" || _fail "chezmoi $c --source" "rc=$rc err=$err"
done
fresh; err=$(chezmoi -v diff 2>&1 >/dev/null); rc=$?
(( rc == 1 )) && [[ $err == *"put the subcommand first"* ]] && [[ ! -e $LOG ]] && _pass "chezmoi -v diff is refused: subcommand first" || _fail "chezmoi -v diff" "rc=$rc err=$err"
# merge and merge-all write into the source: a temporary clone would lose the result.
for c in merge merge-all; do
  fresh; err=$(chezmoi $c x 2>&1 >/dev/null); rc=$?
  (( rc == 1 )) && [[ $err == *"writes the merged result into the source"* && $err == *"chezmoi $c --dirty-ok"* ]] && [[ ! -e $LOG ]] && tmp_clean \
    && _pass "chezmoi $c is refused on a clean main, with the reason" || _fail "chezmoi $c refused" "rc=$rc err=$err log=$(cat $LOG 2>/dev/null)"
  fresh; print change >> $T/co/dot_testfile; chezmoi $c --dirty-ok x >/dev/null 2>&1
  grep -qx WORKTREE $LOG 2>/dev/null && grep -q "^ARGS $c x$" $LOG && _pass "chezmoi $c --dirty-ok runs on the working tree" || _fail "chezmoi $c --dirty-ok" "$(cat $LOG 2>/dev/null)"
done

# Help is an exact -h or --help token (or a short group holding h, with no =) before --. It is
# never forwarded: the wrapper runs `chezmoi help <subcommand>` (a plain-word subcommand) or
# `chezmoi help`, so nothing depends on how chezmoi parses the rest, and no precondition or
# clone is involved, on any branch.
fresh; git -C $T/co switch -q -c other; print change >> $T/co/dot_testfile
for form in "apply --help" "apply -h" "apply -vh" "diff -h" "diff --help" "update --help" "init --help" "apply --dirty-ok --help" \
            "apply --source -h" "apply -D -h" "apply -S -h" "apply -x -h" "apply -h --help=false" "apply --help=false -h" \
            "execute-template -h" "--help" "-h" "-v apply -h" "--source $T/co apply --help"; do
  rm -f $LOG; chezmoi ${=form} >/dev/null 2>&1; rc=$?
  w=${${=form}[1]}; [[ $w == [A-Za-z0-9]([A-Za-z0-9-])# ]] && expect="help $w" || expect=help
  (( rc == 0 )) && grep -qx WORKTREE $LOG 2>/dev/null && grep -qx "ARGS $expect" $LOG && tmp_clean \
    && _pass "chezmoi $form prints 'chezmoi $expect' on a dirty feature branch: no checks, no clone" || _fail "chezmoi $form" "rc=$rc $(cat $LOG 2>/dev/null)"
done
for form in "apply -- -h" "apply --help=false" "apply -h=false" "apply -vh=false" "diff --help=f" "diff --help=0" "execute-template -ph=x X" \
            "execute-template -h=x X" "dump -fh=x" "archive -fh=x" "status -ph=x" "update --help=false" \
            "--help=false apply" "-h=false apply" "init --help=false --apply" "edit --help=0 --apply" "init -h=1 -a"; do
  fresh; git -C $T/co switch -q -c other; print change >> $T/co/dot_testfile
  rm -f $LOG; err=$(chezmoi ${=form} 2>&1 >/dev/null); rc=$?
  (( rc == 1 )) && [[ ! -e $LOG ]] && tmp_clean && _pass "chezmoi $form is not help: refused, never reaches chezmoi" || _fail "chezmoi $form (dirty branch)" "rc=$rc err=$err log=$(cat $LOG 2>/dev/null)"
done
# On a clean main the same forms either run against the clone (the gated subcommands) or are
# refused by the subcommand-first and --apply rules. None runs the working tree.
for form in "apply --help=false" "apply -h=false" "apply -vh=false" "diff --help=f" "execute-template -ph=x X" "execute-template -h=x X" \
            "dump -fh=x" "archive -fh=x" "status -ph=x"; do
  fresh; chezmoi ${=form} >/dev/null 2>&1
  applied_clone NOPE && grep -q "^ARGS --source $T/cache/chezmoi-apply/run\..*/src ${form}$" $LOG && tmp_clean \
    && _pass "chezmoi $form on a clean main runs against the clone, not the working tree" || _fail "chezmoi $form (clean main)" "$(cat $LOG 2>/dev/null)"
done
fresh; chezmoi update --help=false >/dev/null 2>&1
applied_clone NOPE && grep -q "^ARGS --source .*/src apply --help=false$" $LOG && tmp_clean \
  && _pass "chezmoi update --help=false on a clean main runs apply against the clone" || _fail "update --help=false" "$(cat $LOG 2>/dev/null)"
for form in "--help=false apply" "-h=false apply" "init --help=false --apply" "edit --help=0 --apply" "init -h=1 -a"; do
  fresh; chezmoi ${=form} >/dev/null 2>&1; rc=$?
  (( rc == 1 )) && [[ ! -e $LOG ]] && _pass "chezmoi $form on a clean main is refused" || _fail "chezmoi $form (clean main)" "rc=$rc $(cat $LOG 2>/dev/null)"
done
# Which short letters take a value depends on the subcommand: a bool letter must not hide a
# later -S from the scan, a value letter must not be read as the option it contains.
for form in "execute-template -fS$T/co X" "execute-template -iS$T/co X" "execute-template -fc$T/x.toml X" "init -pS$T/co"; do
  fresh; err=$(chezmoi ${=form} 2>&1 >/dev/null); rc=$?
  (( rc == 1 )) && [[ ! -e $LOG ]] && _pass "chezmoi $form is refused" || _fail "chezmoi $form" "rc=$rc err=$err log=$(cat $LOG 2>/dev/null)"
done
for form in "dump -fS" "archive -fc" "status -pS" "status -pc$T/x" "execute-template -pS=x X" "apply -xscripts"; do
  fresh; chezmoi ${=form} >/dev/null 2>&1
  applied_clone NOPE && grep -q " ${form}$" $LOG && _pass "chezmoi $form: the letter is a value, so apply is not refused" || _fail "chezmoi $form" "$(cat $LOG 2>/dev/null)"
done

# --mode symlink would link into the clone, which is removed: only --mode file runs from it.
for form in "apply --mode symlink" "apply --mode=symlink" "update --mode symlink" "diff --mode=symlink" "apply --mode" "apply --mode=" "apply --mode FILE"; do
  fresh; err=$(chezmoi ${=form} 2>&1 >/dev/null); rc=$?
  (( rc == 1 )) && [[ $err == *"only --mode file works from a temporary clone"* ]] && [[ ! -e $LOG ]] \
    && _pass "chezmoi $form is refused" || _fail "chezmoi $form is refused" "rc=$rc err=$err"
done
for form in "apply --mode file" "apply --mode=file" "diff --mode file"; do
  fresh; chezmoi ${=form} >/dev/null 2>&1
  applied_clone NOPE && grep -q -- " ${form#* }$" $LOG && _pass "chezmoi $form runs against the clone" || _fail "chezmoi $form" "$(cat $LOG 2>/dev/null)"
done
fresh; chezmoi apply --mode symlink --dirty-ok >/dev/null 2>&1
grep -qx WORKTREE $LOG 2>/dev/null && grep -q '^ARGS apply --mode symlink$' $LOG && _pass "--dirty-ok passes --mode symlink through" || _fail "--dirty-ok --mode" "$(cat $LOG 2>/dev/null)"

print "\npassed: $pass  failed: $fail"
(( fail == 0 ))
