#!/usr/bin/env zsh
# Tests op-edit in dot_config/zsh/functions: the editor is always Neovim, started without swap,
# ShaDa, undo or backup files, so a 1Password note's text stays out of Neovim's state. chezmoi,
# op, nvim and vim are stubs; the nvim and vim stubs record their name and arguments, then edit
# the temp file. mktemp is a stub too: this macOS's `mktemp -t` ignores TMPDIR and writes to a
# directory the sandbox denies.
#
#   ./tests/op-edit.test.sh   (sandboxed is fine)
emulate -L zsh
setopt no_unset pipe_fail
unsetopt extended_glob
SRC=${0:A:h:h}
FUNCS=$SRC/dot_config/zsh/functions
[[ -f $FUNCS ]] || { print -u2 "missing file under test: $FUNCS"; exit 2 }
integer pass=0 fail=0
_pass() { print "  PASS: $1"; (( ++pass )); return 0 }
_fail() { print "  FAIL: $1\n    | got: $2"; (( ++fail )); return 0 }
T=$(mktemp -d "${TMPDIR:-/tmp}/op-edit.XXXXXX")
trap 'rm -rf "$T"' EXIT
export T TMPDIR=$T/tmp
mkdir -p $T/tmp $T/bin $T/src

cat > $T/bin/chezmoi <<'STUB'
#!/bin/sh
if [ "$1" = source-path ]; then
  [ $# -eq 1 ] && { printf '%s\n' "$T/src"; exit 0; }
  exit 1
fi
exit 0
STUB
cat > $T/bin/op <<'STUB'
#!/bin/sh
[ "$1" = read ] && { echo "note body"; exit 0; }
exit 0
STUB
cat > $T/bin/mktemp <<'STUB'
#!/bin/sh
exec /usr/bin/mktemp "$TMPDIR/op-edit.XXXXXX"
STUB
for ed in nvim vim; do
  cat > $T/bin/$ed <<STUB
#!/bin/sh
echo $ed >> "\$T/argv"
for a in "\$@"; do echo "\$a" >> "\$T/argv"; last=\$a; done
echo edited >> "\$last"
STUB
done
chmod 755 $T/bin/*
path=($T/bin /usr/bin /bin)
source $FUNCS
unfunction chezmoi

for ed in nvim vim; do
  rm -f $T/argv
  EDITOR=$ed op-edit "Some note"
  args=("${(@f)$(<$T/argv)}")
  got="${args[*]}"
  [[ ${args[1]} == nvim ]] && _pass "EDITOR=$ed starts nvim" || _fail "EDITOR=$ed starts nvim" "$got"
  (( ${args[(Ie)-n]} )) && _pass "EDITOR=$ed: -n (no swap file)" || _fail "EDITOR=$ed: -n (no swap file)" "$got"
  i=${args[(i)-i]}
  [[ ${args[i+1]:-} == NONE ]] && _pass "EDITOR=$ed: -i NONE (no ShaDa)" || _fail "EDITOR=$ed: -i NONE (no ShaDa)" "$got"
  i=${args[(i)-c]}
  [[ ${args[i+1]:-} == *noundofile*nobackup*nowritebackup* ]] && _pass "EDITOR=$ed: -c sets noundofile, nobackup and nowritebackup" || _fail "EDITOR=$ed: -c sets noundofile, nobackup and nowritebackup" "$got"
  [[ ${args[-2]} == -- && ${args[-1]} == */op-edit.* ]] && _pass "EDITOR=$ed: temp file last, after --" || _fail "EDITOR=$ed: temp file last, after --" "$got"
done

print "\npassed: $pass  failed: $fail"
(( fail == 0 ))
