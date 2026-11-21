#!/usr/bin/env bash
# Tests for dot_local/bin/executable_change-facts: it prints the measured facts of the change
# since the merge base of two commits (lines per class, the 2000 ceiling, test lines deleted, CI
# workflow files, dependency lines), judges nothing, and reads only the two commits' history.
#
#   ./tests/change-facts.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
CF="$SRC/dot_local/bin/executable_change-facts"
[ -f "$CF" ] || { echo "missing script under test: $CF" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/change-facts.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"

R=""
rc=0
# fx <name>: a fresh repository on main; $R names it.
fx() { R="$T/$1"; git init -q -b main "$R"; }
# wf <path>: write stdin to <path> in $R.
wf() { case $1 in */*) mkdir -p "$R/${1%/*}";; esac; cat > "$R/$1"; }
# n <count> [prefix]: count distinct lines.
n() { seq -f "${2:-l}%g" 1 "$1"; }
# wn <path> <count> [prefix]: a file of count lines.
wn() { n "$2" "${3:-l}" | wf "$1"; }
# wt <path> <text>: a one-line file.
wt() { printf '%s\n' "$2" | wf "$1"; }
commit() { git -C "$R" add -A && git -C "$R" commit -q --allow-empty -m "${1:-c}"; }
# base: commit what is written so far and tag it; the head is the next commit.
base() { commit base && git -C "$R" tag -f base >/dev/null; }
# runin <dir> <args...>: run the script in <dir>; sets rc, $T/out, $T/err.
runin() { local d=$1; shift; ( CDPATH= cd -- "$d" && "$CF" "$@" ) >"$T/out" 2>"$T/err"; rc=$?; }
# rep [arg]: the report of the fixture, base...HEAD unless told otherwise.
rep() { runin "$R" "${1:-base...HEAD}"; }
# lines_ok <label> <line>...: exit 0 and each line is a whole line of the report.
lines_ok() {
  local label=$1 l miss=""; shift
  for l in "$@"; do grep -qxF -- "$l" "$T/out" || miss+="[$l]"; done
  if [ "$rc" = 0 ] && [ -z "$miss" ]; then _pass "$label"
  else _fail "$label" "rc=$rc missing: $miss | $(head -c 800 "$T/out") | $(cat "$T/err")"; fi
}
# same <label> <text>: the whole report is exactly the text.
same() {
  printf '%s\n' "$2" > "$T/want"
  if [ "$rc" = 0 ] && cmp -s "$T/want" "$T/out"; then _pass "$1"
  else _fail "$1" "rc=$rc $(head -c 800 "$T/out") | $(cat "$T/err")"; fi
}
# from_is <label> <start> <text>: the report from the line starting <start> to its end is the text.
from_is() {
  local got; got="$(sed -n "/^$2/,\$p" "$T/out")"
  if [ "$rc" = 0 ] && [ "$got" = "$3" ]; then _pass "$1"; else _fail "$1" "rc=$rc ${got:0:800} | $(cat "$T/err")"; fi
}
# usage_err <label> <dir> <args...>: exit 2 with a change-facts: line, nothing else on stderr, no stdout.
usage_err() {
  local label=$1 d=$2; shift 2
  runin "$d" "$@"
  if [ "$rc" = 2 ] && [ "$(wc -l < "$T/err" | tr -d ' ')" = 1 ] && grep -q '^change-facts: ' "$T/err" && [ ! -s "$T/out" ]; then _pass "$label"
  else _fail "$label" "rc=$rc out: $(cat "$T/out") err: $(cat "$T/err")"; fi
}

# 1. the three classes, and the whole report
fx c1; wt seed.txt s; base
wn app/model.rb 10; wn spec/model_spec.rb 5; wn docs/guide.md 3; commit
rep
same "the three classes and the seven items" "code: 10 lines (+10 -0)
test: 5 lines (+5 -0)
docs: 3 lines (+3 -0)
code over 2000: no
test lines deleted: 0
ci workflow files: none
dependency lines: none"

# 2. and 3. the class of each path, one commit per path
fx cls; wt seed.txt s; base
one() {
  printf 'x\n' | wf "$1"; commit one
  runin "$R" HEAD~1...HEAD
  lines_ok "$2: $1" "$2: 1 lines (+1 -0)"
}
for p in test/a.rb tests/a.py features/a.feature e2e/a.ts a_test.go a_spec.rb a.test.sh a.spec.ts a-test.js test_a.py WidgetTests.cs tests/README.md; do one "$p" test; done
for p in latest/a.rb contest.rb test_a.rb; do one "$p" code; done
for p in README.md notes.txt a.rst a.adoc docs/x.py; do one "$p" docs; done

# 4. deletions
fx c4; wn spec/a_spec.rb 10; wn lib/a.rb 5; base
wn spec/a_spec.rb 6; printf 'x1\nx2\nl3\nl4\nl5\n' | wf lib/a.rb; commit
rep
lines_ok "a deletion" "test: 4 lines (+0 -4)" "test lines deleted: 4" "code: 4 lines (+2 -2)"

# 5. lockfiles are left out of every figure
fx c5; wt seed.txt s; base
for p in Gemfile.lock package-lock.json go.sum Package.resolved sub/x.lock; do wn "$p" 500; done
commit; rep
lines_ok "lockfiles" "code: 0 lines (+0 -0)" "test: 0 lines (+0 -0)" "docs: 0 lines (+0 -0)"

# 6. the ceiling
fx c6a; wt seed.txt s; base; wn app/big.rb 2000; commit; rep
lines_ok "2000 added code lines" "code over 2000: no"
fx c6b; wt seed.txt s; base; wn app/big.rb 2001; commit; rep
lines_ok "2001 added code lines" "code over 2000: yes"
fx c6c; wt seed.txt s; base; wn spec/big_spec.rb 2001; wn app/a.rb 10; commit; rep
lines_ok "2001 test lines and 10 code lines" "code over 2000: no"
fx c6d; wn app/big.rb 1001; base; wn app/big.rb 1000 y; commit; rep
lines_ok "added plus deleted counts toward the ceiling" "code: 2001 lines (+1000 -1001)" "code over 2000: yes"

# 7. dependency manifests
fx c7; wt seed.txt s; base
for p in Gemfile x.gemspec package.json pyproject.toml requirements-dev.txt Cargo.toml Package.swift go.mod Brewfile \
         dot_config/homebrew/Brewfile.tmpl mise.toml .mise.toml dot_config/mise/config.toml .tool-versions \
         .chezmoiexternal.toml sub/dir/package.json; do wt "$p" "v $p"; done
printf '    - uses: actions/checkout@v4\n      run: make\n' | wf .github/workflows/ci.yml
commit; rep
from_is "every manifest kind is listed with its added line" "dependency lines:" "dependency lines:
  .chezmoiexternal.toml
    + v .chezmoiexternal.toml
  .github/workflows/ci.yml
    +     - uses: actions/checkout@v4
  .mise.toml
    + v .mise.toml
  .tool-versions
    + v .tool-versions
  Brewfile
    + v Brewfile
  Cargo.toml
    + v Cargo.toml
  Gemfile
    + v Gemfile
  Package.swift
    + v Package.swift
  dot_config/homebrew/Brewfile.tmpl
    + v dot_config/homebrew/Brewfile.tmpl
  dot_config/mise/config.toml
    + v dot_config/mise/config.toml
  go.mod
    + v go.mod
  mise.toml
    + v mise.toml
  package.json
    + v package.json
  pyproject.toml
    + v pyproject.toml
  requirements-dev.txt
    + v requirements-dev.txt
  sub/dir/package.json
    + v sub/dir/package.json
  x.gemspec
    + v x.gemspec"

# 8. what is not a manifest line
fx c8; wn app/a.rb 3; base; wn app/a.rb 4; commit; rep
lines_ok "no manifest" "dependency lines: none"
fx c8b; wn Gemfile 3; base
wn Gemfile 2; wt config.toml "x = 1"; wt package.json.md "x"; commit; rep
lines_ok "deleted lines only, config.toml outside mise, package.json.md" "dependency lines: none"

# 9. CI workflow files
fx c9; wt .github/workflows/old.yml "on: push"; base
rm "$R/.github/workflows/old.yml"
wt .github/workflows/ci.yml "on: push"; wt .gitlab-ci.yml "x: 1"; wt .gitlab/ci/build.yml "x: 1"
wt azure-pipelines.yml "x: 1"; wt ci.yml "x: 1"; wt sub/.github/workflows/z.yml "x: 1"
commit; rep
from_is "CI workflow files in path order, deleted ones included" "ci workflow files:" "ci workflow files:
  .github/workflows/ci.yml
  .github/workflows/old.yml
  .gitlab-ci.yml
  .gitlab/ci/build.yml
  azure-pipelines.yml
dependency lines: none"
fx c9b; wt seed.txt s; base; wt ci.yml "x: 1"; commit; rep
lines_ok "a root ci.yml is not a CI workflow file" "ci workflow files: none"

# 10. a line that looks like a diff header
fx c10; wt Gemfile 'source "x"'; base
printf 'source "x"\n++ odd\n' | wf Gemfile; commit; rep
lines_ok "an added line starting ++" "code: 1 lines (+1 -0)"
from_is "listed as git has it after its +" "dependency lines:" "dependency lines:
  Gemfile
    + ++ odd"

# 11. arguments
fx c11; wt seed.txt s; base
ls_before="$(find "$R" -path "$R/.git" -prune -o -print | sort)"
usage_err "no argument" "$R"
usage_err "two arguments" "$R" base...HEAD base...HEAD
usage_err "two dots" "$R" main..HEAD
usage_err "empty base" "$R" ...HEAD
usage_err "empty head" "$R" main...
usage_err "an option as the base" "$R" --output=x...HEAD
usage_err "an option as the head" "$R" main...--stat
usage_err "a side that names no commit" "$R" nope...HEAD
ls_after="$(find "$R" -path "$R/.git" -prune -o -print | sort)"
if [ "$ls_before" = "$ls_after" ]; then _pass "the refused arguments wrote no file"; else _fail "the refused arguments wrote no file" "$ls_after"; fi
mkdir "$T/norepo"
GIT_CEILING_DIRECTORIES="$T" usage_err "a directory that is not a repository" "$T/norepo" main...HEAD

# 12. a repository's configuration names no command that runs
fx c12; wn app/a.rb 2; wt .gitattributes '* diff=mark'; base; wn app/a.rb 5; commit
printf '#!/bin/sh\ntouch "%s"\n' "$T/ext-ran" > "$T/ext.sh"
printf '#!/bin/sh\ntouch "%s"\ncat "$1"\n' "$T/tc-ran" > "$T/tc.sh"
chmod 755 "$T/ext.sh" "$T/tc.sh"
git -C "$R" config diff.external "$T/ext.sh"
git -C "$R" config diff.mark.textconv "$T/tc.sh"
git -C "$R" diff base...HEAD >/dev/null 2>&1
git -C "$R" diff --no-ext-diff base...HEAD >/dev/null 2>&1
if [ -e "$T/ext-ran" ] && [ -e "$T/tc-ran" ]; then _pass "control: git runs the configured diff.external and textconv"
else _fail "control: git runs the configured diff.external and textconv" "ext: $([ -e "$T/ext-ran" ] && echo ran || echo no) textconv: $([ -e "$T/tc-ran" ] && echo ran || echo no)"; fi
rm -f "$T/ext-ran" "$T/tc-ran"
rep
lines_ok "the report is right with diff.external and textconv configured" "code: 3 lines (+3 -0)"
if [ ! -e "$T/ext-ran" ]; then _pass "diff.external never runs"; else _fail "diff.external never runs" "the command ran"; fi
if [ ! -e "$T/tc-ran" ]; then _pass "textconv never runs"; else _fail "textconv never runs" "the command ran"; fi

# 13. attributes cannot change the report
fx c13; wn Gemfile 3; wn app/a.rb 5; base
wn Gemfile 4; wn app/a.rb 15; commit
rep; cp "$T/out" "$T/first"
lines_ok "attributes: the plain report" "code: 11 lines (+11 -0)" "  Gemfile" '    + l4'
clean_attrs() {
  git -C "$R" reset -q; rm -f "$R/.gitattributes" "$R/.git/info/attributes" "$T/attrfile"
  git -C "$R" config --unset core.attributesFile 2>/dev/null || true
}
attr() { # attr <place> <content>
  case $1 in
    work) printf '%b\n' "$2" > "$R/.gitattributes";;
    staged) printf '%b\n' "$2" > "$R/.gitattributes"; git -C "$R" add .gitattributes;;
    info) printf '%b\n' "$2" > "$R/.git/info/attributes";;
    file) printf '%b\n' "$2" > "$T/attrfile"; git -C "$R" config core.attributesFile "$T/attrfile";;
  esac
  rep
  if [ "$rc" = 0 ] && cmp -s "$T/first" "$T/out"; then _pass "attributes: ${2//\\n/; } in $1 changes nothing"
  else _fail "attributes: ${2//\\n/; } in $1 changes nothing" "rc=$rc $(head -c 400 "$T/out")"; fi
  clean_attrs
}
for place in work staged info file; do
  attr $place '* binary'
  attr $place 'Gemfile binary\napp/a.rb binary'
done
attr info '* -diff'

# 14. paths
fx c14; wt seed.txt s; base
wt "my dir/a b.rb" x; wt "ünï.rb" x; wt $'nl\nname.rb' x; wt $'ctl\ty/Gemfile' x; wt $'nl\ndir/Gemfile' x
commit; rep
lines_ok "spaces, non-ASCII and a newline in a path count once each" "code: 5 lines (+5 -0)"
if [ "$(grep -c '^[a-z]' "$T/out")" = 7 ]; then _pass "the report has exactly seven top-level items"
else _fail "the report has exactly seven top-level items" "$(cat "$T/out")"; fi
from_is "a control character in a printed path becomes ?" "dependency lines:" "dependency lines:
  ctl?y/Gemfile
    + x
  nl?dir/Gemfile
    + x"

# 15. edges
fx c15; wn app/a.rb 3; wn Gemfile 3; base
printf 'a\0b\n%s\n' "$(n 10)" | wf app/a.rb
printf 'a\0b\n' | wf Gemfile; printf 'a\0b\n' | wf sub/Gemfile; printf 'a\0b\n' | wf img/x.dat
commit; rep
lines_ok "binary files add zero lines" "code: 0 lines (+0 -0)"
from_is "binary manifests are listed as (binary)" "dependency lines:" "dependency lines:
  Gemfile
    (binary)
  sub/Gemfile
    (binary)"
fx c15b; wt .gitattributes '* binary'; wn app/a.rb 3; base; wn app/a.rb 8; commit; rep
lines_ok "a text file a committed .gitattributes marks binary is counted" "code: 5 lines (+5 -0)"
rep HEAD...HEAD
same "HEAD...HEAD" "code: 0 lines (+0 -0)
test: 0 lines (+0 -0)
docs: 0 lines (+0 -0)
code over 2000: no
test lines deleted: 0
ci workflow files: none
dependency lines: none"

# 16. renames, with the setting that turns them off
fx c16; git -C "$R" config diff.renames false
wn lib/old.rb 20; wn sub/package.json 6 p; wn Gemfile 4 g; base
git -C "$R" mv lib/old.rb lib/new.rb; sed -i.bak '5s/.*/changed/' "$R/lib/new.rb"; rm "$R/lib/new.rb.bak"
git -C "$R" mv sub/package.json package.json
git -C "$R" mv Gemfile sub/Gemfile; printf 'gem "rack"\n' >> "$R/sub/Gemfile"
commit; rep
lines_ok "a renamed file with one changed line counts 2" "code: 3 lines (+2 -1)"
from_is "a moved manifest lists only its added line" "dependency lines:" "dependency lines:
  sub/Gemfile
    + gem \"rack\""

# 16a. one record, one file
fx c16a; ln -s nope "$R/Gemfile"; base
rm "$R/Gemfile"; printf 'gem "a"\ngem "b"\ngem "c"\n' | wf Gemfile; commit; rep
lines_ok "a symlink replaced by a file" "code: 4 lines (+3 -1)"
from_is "only the file's lines are listed" "dependency lines:" "dependency lines:
  Gemfile
    + gem \"a\"
    + gem \"b\"
    + gem \"c\""
fx c16b; wn lib/tool 20; base
rm "$R/lib/tool"; wn lib/tool/main.rb 20; wn lib/tool/extra.rb 5 e; commit; rep
lines_ok "a file renamed into a directory beside a new file" "code: 5 lines (+5 -0)"
fx c16c; wt seed.txt s; base
printf 'x\ny' | wf lib/nonl.rb; : | wf lib/empty.rb; commit; rep
lines_ok "a last line without a newline counts, an empty file counts zero" "code: 2 lines (+2 -0)"

# 17. the change since the merge base
fx c17; wt app/x.rb l1; base
git -C "$R" switch -q -c feat; wn app/y.rb 3; commit feat
git -C "$R" switch -q main; wn app/z.rb 50; commit later
rep main...feat
lines_ok "the base branch's later lines are not counted" "code: 3 lines (+3 -0)"

# 18. history only
fx c18; wn app/a.rb 2; wn Gemfile 2; base; wn app/a.rb 5; wn Gemfile 3; commit
rep; cp "$T/out" "$T/first"
lines_ok "history: the committed report" "code: 4 lines (+4 -0)" "  Gemfile"
wn app/a.rb 200; wn new.rb 30; wn staged.rb 40; git -C "$R" add staged.rb
rep
if [ "$rc" = 0 ] && cmp -s "$T/first" "$T/out"; then _pass "uncommitted, staged and untracked changes do not change the report"
else _fail "uncommitted, staged and untracked changes do not change the report" "rc=$rc $(head -c 400 "$T/out")"; fi
git -C "$R" config diff.relative true
runin "$R/app" base...HEAD
if [ "$rc" = 0 ] && cmp -s "$T/first" "$T/out"; then _pass "diff.relative does not change the report from a subdirectory"
else _fail "diff.relative does not change the report from a subdirectory" "rc=$rc $(head -c 400 "$T/out") | $(cat "$T/err")"; fi

# 19. an untrusted mise config in the work tree cannot stop the script
fx c19; wn app/a.rb 2; wt .mise.toml 'not toml ['; wt .tool-versions 'python 2.7.99'; base; wn app/a.rb 5; commit; rep
lines_ok "a work tree with an untrusted .mise.toml and a .tool-versions naming a missing python" "code: 3 lines (+3 -0)"

# 20. diff.algorithm cannot change the counts
fx c20; printf 'x\nc\nc\nb\nb\nc\nb\n' | wf app/a.rb; base
printf 'c\na\nc\na\nx\na\nc\n' | wf app/a.rb; commit
git -C "$R" config diff.algorithm patience
if [ "$(git -C "$R" diff --numstat base...HEAD | cut -f1,2)" = "$(printf '5\t5')" ]; then _pass "control: patience counts this pair as +5 -5"
else _fail "control: patience counts this pair as +5 -5" "$(git -C "$R" diff --numstat base...HEAD)"; fi
rep
lines_ok "diff.algorithm = patience does not change the counts (myers: +4 -4)" "code: 8 lines (+4 -4)"

fx c20b; for k in a b c; do wn "lib/$k.rb" 20 "$k"; done; base
for k in a b c; do n 20 "$k" | sed '5s/.*/changed/' | wf "lib/n$k.rb"; rm "$R/lib/$k.rb"; done
commit; git -C "$R" config diff.renameLimit 1; rep
lines_ok "diff.renameLimit = 1 does not turn three renames into deletions and additions" "code: 6 lines (+3 -3)"

fx c20c; wt seed.txt s; git -C "$R" add seed.txt
git -C "$R" update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,sub1"
git -C "$R" commit -q -m base; git -C "$R" tag base
git -C "$R" update-index --add --cacheinfo "160000,2222222222222222222222222222222222222222,sub1"
git -C "$R" update-index --add --cacheinfo "160000,3333333333333333333333333333333333333333,sub2"
git -C "$R" commit -q -m head; git -C "$R" config diff.ignoreSubmodules all; rep
lines_ok "diff.ignoreSubmodules = all: an added gitlink is +1, a bumped one +1 -1" "code: 3 lines (+2 -1)"

fx c20d; wn app/a.rb 2; base; wn app/a.rb 5; commit; git -C "$R" config diff.orderFile "$T/no-such-order-file"; rep
lines_ok "diff.orderFile naming a missing file" "code: 3 lines (+3 -0)"

fx c20e; wn app/a.rb 2; base; wn app/a.rb 5; commit
git -C "$R" replace "$(git -C "$R" rev-parse base:app/a.rb)" "$(n 50 | git -C "$R" hash-object -w --stdin)"; rep
lines_ok "a replace ref on a blob of the change" "code: 3 lines (+3 -0)"

# 21. a file named after a blob id
fx c21; wn app/a.rb 2; base; id="$(git -C "$R" rev-parse base:app/a.rb)"
wn app/a.rb 5; wt "$id" x; commit; rep
lines_ok "a committed file named after the base blob id of a modified file" "code: 4 lines (+4 -0)"
wt "$(git -C "$R" rev-parse base)...$(git -C "$R" rev-parse HEAD)" x; rep
lines_ok "an untracked file named after the range of two commit ids" "code: 4 lines (+4 -0)"

# 22. a binary manifest that only moved or went away lists nothing
fx c22; printf 'a\0g\n' | wf Gemfile; printf 'b\0x\n' | wf x.gemspec; wt seed.txt s; base
mkdir "$R/sub"; mv "$R/Gemfile" "$R/sub/Gemfile"; rm "$R/x.gemspec"; commit; rep
lines_ok "a binary Gemfile moved unchanged and a deleted binary gemspec list nothing" "dependency lines: none"

# 23. control characters in a dependency line
fx c23; wt seed.txt s; base
printf 'gem "a"\r\033[2Kgem "b"\ngem "c" \x9b x\ngem\t"d"\ngem "e"\xe2\x80\xaex\ngem "f"\xe2\x80\x8bg\ngem "g"\xe2\x80\xa8x\ngem "h"\xe2\x80\xa9y\n' | wf Gemfile; commit; rep
from_is "control, format, separator and stray bytes in an added line show as ?, a tab stays" "dependency lines:" "dependency lines:
  Gemfile
    + gem \"a\"??[2Kgem \"b\"
    + gem \"c\" ? x
    + gem"$'\t'"\"d\"
    + gem \"e\"?x
    + gem \"f\"?g
    + gem \"g\"?x
    + gem \"h\"?y"

# 24. a reader that exits at once
fx c24; wt seed.txt s; base; wn Gemfile 30000; commit
( CDPATH= cd -- "$R" && "$CF" base...HEAD 2>"$T/err" | head -1 >/dev/null ); rc=$?
if [ "$rc" = 0 ] && [ ! -s "$T/err" ]; then _pass "a closed pipe ends quietly with exit 0"
else _fail "a closed pipe ends quietly with exit 0" "rc=$rc $(head -c 300 "$T/err")"; fi
fx c24b; wt seed.txt s; base; wt app/a.rb x; commit
( CDPATH= cd -- "$R" && "$CF" base...HEAD 2>"$T/err" | true ); rc=$?
if [ "$rc" = 0 ] && [ ! -s "$T/err" ]; then _pass "a short report into a pipe already closed ends quietly with exit 0"
else _fail "a short report into a pipe already closed ends quietly with exit 0" "rc=$rc $(head -c 300 "$T/err")"; fi

# 25. nothing is fetched, and grafts do not rewrite the history
fx c25; wt seed.txt s; base; wn app/a.rb 4; commit
git init -q --bare "$T/bare25"
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$T/fetch-ran" > "$T/uploadpack.sh"; chmod 755 "$T/uploadpack.sh"
git -C "$R" config core.repositoryformatversion 1
git -C "$R" config extensions.partialClone origin
git -C "$R" config remote.origin.url "$T/bare25"
git -C "$R" config remote.origin.promisor true
git -C "$R" config remote.origin.uploadpack "$T/uploadpack.sh"
blob="$(git -C "$R" rev-parse HEAD:app/a.rb)"; rm -f "$R/.git/objects/${blob:0:2}/${blob:2}"
git -C "$R" cat-file blob "$blob" >/dev/null 2>&1
if [ -e "$T/fetch-ran" ]; then _pass "control: git fetches a missing blob of a partial clone through remote.origin.uploadpack"
else _fail "control: git fetches a missing blob of a partial clone through remote.origin.uploadpack" "no marker"; fi
rm -f "$T/fetch-ran"
usage_err "a missing blob of a partial clone is an error, not a fetch" "$R" base...HEAD
if [ ! -e "$T/fetch-ran" ]; then _pass "the configured uploadpack command never runs"; else _fail "the configured uploadpack command never runs" "the command ran"; fi

fx c25b; wt seed.txt s; base; wn app/a.rb 2; commit one; wn app/a.rb 5; commit two
one="$(git -C "$R" rev-parse HEAD~1)"; rep "$one...HEAD"; cp "$T/out" "$T/first"
printf '%s %s\n' "$(git -C "$R" rev-parse HEAD)" "$(git -C "$R" rev-parse base)" > "$R/.git/info/grafts"
if [ "$(git -C "$R" diff --numstat "$one...HEAD" 2>/dev/null | cut -f1,2)" = "$(printf '5\t0')" ]; then _pass "control: git honours .git/info/grafts"
else _fail "control: git honours .git/info/grafts" "$(git -C "$R" diff --numstat "$one...HEAD" 2>/dev/null)"; fi
rep "$one...HEAD"
if [ "$rc" = 0 ] && cmp -s "$T/first" "$T/out"; then _pass "a graft re-parenting the head does not change the report"
else _fail "a graft re-parenting the head does not change the report" "rc=$rc $(head -c 300 "$T/out")"; fi

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
