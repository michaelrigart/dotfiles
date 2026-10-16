#!/usr/bin/env zsh
# Tests the chezmoi wrapper in dot_config/zsh/functions (spec 2026-10-16, sandbox write
# boundary, section 3): apply and update deploy a fresh clone of origin's main, only from a
# clean main checkout equal to it; --dirty-ok applies the working tree. chezmoi is a stub
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
EOF
chmod 755 $T/bin/chezmoi
path=($T/bin /usr/bin /bin /opt/homebrew/bin)
export LOG=$T/log
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

fresh; print change >> $T/co/dot_testfile; chezmoi apply --dirty-ok >/dev/null 2>&1
grep -qx WORKTREE $LOG 2>/dev/null && ! grep -q -- --dirty-ok $LOG && _pass "--dirty-ok applies the working tree and never reaches chezmoi" || _fail "--dirty-ok" "$(cat $LOG 2>/dev/null)"
fresh; chezmoi status >/dev/null 2>&1; grep -q '^ARGS status$' $LOG && _pass "other subcommands pass through" || _fail "passthrough" "$(cat $LOG 2>/dev/null)"
fresh; git -C $T/seed commit -q --allow-empty -m ahead2 && git -C $T/seed push -q origin main 2>/dev/null
chezmoi update >/dev/null 2>&1
grep -q '^ARGS --source .* apply$' $LOG 2>/dev/null && [[ $(git -C $T/co rev-parse HEAD) == $(git -C $T/seed rev-parse HEAD) ]] \
  && _pass "update fast-forwards, then applies a fresh clone" || _fail "update" "$(cat $LOG 2>/dev/null)"
tmp_clean && _pass "no temporary clone is left behind" || _fail "temporary clones" "$(ls $T/tmp)"

print "\npassed: $pass  failed: $fail"
(( fail == 0 ))
