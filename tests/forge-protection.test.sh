#!/usr/bin/env bash
# Mocked test for .scripts/forge-protection.sh: stubs gh, glab and az on PATH (every argv is
# appended to $CALLS; answers come from $T/answers/<tool>/<key>{.out,.rc,.err,.sleep}, the key
# being the argv with every character outside A-Za-z0-9 turned into _) and asserts each row's
# state, the remedies, the exit status, the exceptions file, the dedupe, and that nothing
# writes to a forge. Fixture checkouts are hand-built git directories under a throwaway HOME.
# The script runs under /bin/bash to pin Bash 3.2 compatibility.
# Run: ./tests/forge-protection.test.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.scripts/forge-protection.sh"
[ -f "$SCRIPT" ] || { echo "missing script under test: $SCRIPT" >&2; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/forge-protection.XXXXXX") || { echo "cannot create a temp dir" >&2; exit 2; }
BIN="$T/bin"; ANS="$T/answers"; CALLS="$T/calls.log"; ALLCALLS="$T/all-calls.log"; ALLOUT="$T/all-out.log"
H="$T/home"
mkdir -p "$BIN"
trap 'rm -rf "$T"' EXIT
: > "$ALLCALLS"; : > "$ALLOUT"
export ANS CALLS
pass=0; fail=0; OUT=""; ERR=""; RC=0; SECS=0

cat > "$BIN/stub" <<'STUB'
#!/usr/bin/env bash
tool=$(basename "$0")
echo "$tool $*" >> "$CALLS"
key=$(printf '%s' "$*" | tr -c 'A-Za-z0-9' '_')
d="$ANS/$tool/$key"
if [ ! -e "$d.out" ] && [ ! -e "$d.rc" ]; then echo "stub: unconfigured call" >&2; exit 99; fi
[ ! -f "$d.sleep" ] || sleep "$(cat "$d.sleep")"
[ ! -f "$d.out" ] || cat "$d.out"
[ ! -f "$d.err" ] || cat "$d.err" >&2
rc=0; [ ! -f "$d.rc" ] || rc=$(cat "$d.rc")
exit "$rc"
STUB
chmod +x "$BIN/stub"
for t in gh glab az; do ln -s stub "$BIN/$t"; done

# ans <tool> <argv string> <out> [rc] [err] [sleep]
ans() {
  local k; k=$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')
  mkdir -p "$ANS/$1"
  printf '%s\n' "$3" > "$ANS/$1/$k.out"
  [ -z "${4:-}" ] || printf '%s' "$4" > "$ANS/$1/$k.rc"
  [ -z "${5:-}" ] || printf '%s\n' "$5" > "$ANS/$1/$k.err"
  [ -z "${6:-}" ] || printf '%s' "$6" > "$ANS/$1/$k.sleep"
}
# mkrepo <dir> [origin url [push url]]: a minimal git directory, no git write command needed
mkrepo() {
  mkdir -p "$1/.git/objects" "$1/.git/refs"
  echo 'ref: refs/heads/main' > "$1/.git/HEAD"
  printf '[core]\n\trepositoryformatversion = 0\n' > "$1/.git/config"
  [ -z "${2:-}" ] || printf '[remote "origin"]\n\turl = %s\n' "$2" >> "$1/.git/config"
  [ -z "${3:-}" ] || printf '\tpushurl = %s\n' "$3" >> "$1/.git/config"
}

R=example-owner/example-repo
GHURL="git@github.com:$R.git"
BYADMIN='{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"always"}'
PM_RULES='[{"type":"deletion","ruleset_id":1},{"type":"non_fast_forward","ruleset_id":1}]'
OO_RULES='[{"type":"update","ruleset_id":2},{"type":"creation","ruleset_id":2}]'
ALL_RULES='[{"type":"deletion","ruleset_id":3},{"type":"non_fast_forward","ruleset_id":3},{"type":"update","ruleset_id":3},{"type":"creation","ruleset_id":3}]'
join() { jq -nc --argjson a "$1" --argjson b "$2" '$a + $b'; }

gh_repo()  { ans gh "api repos/$1" '{"default_branch":"main"}'; }
gh_rules() { ans gh "api --paginate repos/$1/rules/branches/main?per_page=100" "$2"; }
gh_rs()    { ans gh "api repos/$1/rulesets/$2" "$3"; }
# the two target rulesets as seen by Michael (bypass_actors shown) or by the agent (not shown)
gh_michael() {
  gh_repo "$1"; gh_rules "$1" "$(join "$PM_RULES" "$OO_RULES")"
  gh_rs "$1" 1 '{"id":1,"enforcement":"active","bypass_actors":[],"current_user_can_bypass":"never"}'
  gh_rs "$1" 2 "{\"id\":2,\"enforcement\":\"active\",\"bypass_actors\":[$BYADMIN],\"current_user_can_bypass\":\"always\"}"
}
gh_agent() {
  gh_repo "$1"; gh_rules "$1" "$(join "$PM_RULES" "$OO_RULES")"
  gh_rs "$1" 1 '{"id":1,"enforcement":"active","current_user_can_bypass":"never"}'
  gh_rs "$1" 2 '{"id":2,"enforcement":"active","current_user_can_bypass":"never"}'
}

reset() {
  rm -rf "$H" "$ANS"; mkdir -p "$H/.local/share" "$H/Code/ExampleOrg" "$ANS"
  : > "$CALLS"
  unset FORGE_PROTECTION_TIMEOUT
}
# run: sets OUT (stdout), ERR (stderr), RC, SECS; appends the calls and output to the totals
run() {
  local t0=$SECONDS
  : > "$CALLS"
  OUT=$(HOME="$H" PATH="$BIN:$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null /bin/bash "$SCRIPT" "${@:-check}" 2>"$T/err"); RC=$?
  SECS=$((SECONDS - t0))
  ERR=$(cat "$T/err")
  cat "$CALLS" >> "$ALLCALLS"; printf '%s\n' "$OUT" >> "$ALLOUT"
}
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() {
  echo "  FAIL: $1"
  printf '%s\n' "$OUT" | sed 's/^/    out| /'; printf '%s\n' "$ERR" | sed 's/^/    err| /'
  [ ! -s "$CALLS" ] || sed 's/^/    call| /' "$CALLS"
  fail=$((fail + 1))
}
out_has()   { case "$OUT" in *"$1"*) _pass "$2" ;; *) _fail "$2" ;; esac; }
out_hasnt() { case "$OUT" in *"$1"*) _fail "$2" ;; *) _pass "$2" ;; esac; }
rc_is()     { if [ "$RC" -eq "$1" ]; then _pass "$2"; else _fail "$2"; fi; }
row_is()    { if printf '%s\n' "$OUT" | grep -q "^$1 .*$2"; then _pass "$3"; else _fail "$3"; fi; }
rows_are()  { local n; n=$(printf '%s\n' "$OUT" | grep -c "^$1 "); if [ "$n" -eq "$2" ]; then _pass "$3"; else _fail "$3 (got $n)"; fi; }
not_called() { if grep -q "$1" "$CALLS"; then _fail "$2"; else _pass "$2"; fi; }

echo "A. github"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
run check
row_is ok "github.com/$R" "github ok as Michael: ok row"
rc_is 0 "github ok as Michael: exit 0"
out_has "1 repositories: 1 ok, 0 drift, 0 unreadable, 0 excepted; 0 checkouts without origin skipped" "summary line"
case "$OUT" in "# This output names repositories: never commit it or paste it into a tracked file."*) _pass "first line warns the output names repositories" ;; *) _fail "first line warns the output names repositories" ;; esac

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_agent "$R"
run check
row_is ok "github.com/$R" "github ok as the agent (no bypass_actors, current_user_can_bypass never): ok row"
rc_is 0 "github ok as the agent: exit 0"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"
gh_repo "$R"; gh_rules "$R" "$PM_RULES"
gh_rs "$R" 1 '{"id":1,"enforcement":"active","bypass_actors":[],"current_user_can_bypass":"never"}'
run check
row_is drift "github.com/$R" "github only protect-main: drift row"
out_has '"actor_id":5' "github only protect-main: the owner-only POST names role 5"
out_has '~DEFAULT_BRANCH' "github only protect-main: the owner-only POST targets the default branch"
out_has 'gh api --method POST repos/example-owner/example-repo/rulesets --input <(printf' "github only protect-main: the POST is a copy-pastable command"
out_hasnt '"name":"protect-main"' "github only protect-main: protect-main is not printed again"
rc_is 1 "github only protect-main: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"
gh_repo "$R"; gh_rules "$R" "$ALL_RULES"
gh_rs "$R" 3 "{\"id\":3,\"enforcement\":\"active\",\"bypass_actors\":[$BYADMIN],\"current_user_can_bypass\":\"always\"}"
run check
row_is drift "github.com/$R" "github one merged ruleset with the admin bypass: drift row"
out_has '"name":"protect-main"' "github one merged ruleset: the protect-main POST is printed"
out_hasnt 'bypass list none' "github one merged ruleset: never told to empty its bypass list"
out_hasnt '"name":"main-owner-only"' "github one merged ruleset: no owner-only POST (its admin bypass already is one)"
out_hasnt 'in the UI' "github one merged ruleset: no UI note, the protect-main POST alone"
out_has '"include":["refs/heads/main"]' "github one merged ruleset: protect-main includes the default branch"
rc_is 1 "github one merged ruleset: exit 1"

# update without creation is a main-owner-only carrier, never a protect-main one: no "bypass list none" note
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"
gh_repo "$R"; gh_rules "$R" '[{"type":"deletion","ruleset_id":4},{"type":"non_fast_forward","ruleset_id":4},{"type":"update","ruleset_id":4}]'
gh_rs "$R" 4 "{\"id\":4,\"enforcement\":\"active\",\"bypass_actors\":[$BYADMIN],\"current_user_can_bypass\":\"always\"}"
run check
row_is drift "github.com/$R" "github one ruleset with deletion, non_fast_forward and update, admin bypass: drift row"
out_has '"name":"main-owner-only"' "github deletion+non_fast_forward+update ruleset: the main-owner-only POST is printed"
out_has '"name":"protect-main"' "github deletion+non_fast_forward+update ruleset: the protect-main POST is printed (its deletion is not closed)"
out_hasnt 'bypass list none' "github deletion+non_fast_forward+update ruleset: never told to empty its bypass list"
out_hasnt 'in the UI' "github deletion+non_fast_forward+update ruleset: no UI note, its admin bypass is the owner-only one"
rc_is 1 "github deletion+non_fast_forward+update ruleset: exit 1"

# an empty bypass list is closed, not owner-only: Michael could no longer push the default branch
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"
gh_repo "$R"; gh_rules "$R" "$ALL_RULES"
gh_rs "$R" 3 '{"id":3,"enforcement":"active","bypass_actors":[],"current_user_can_bypass":"never"}'
run check
row_is drift "github.com/$R" "github one merged ruleset with an empty bypass list: drift (Michael is locked out), never ok"
out_has "# in the UI: https://github.com/$R/rules/3: Enforcement Active, bypass list Repository admin" "github merged ruleset, empty bypass: the UI note names Repository admin"
out_hasnt 'bypass list none' "github merged ruleset, empty bypass: never told to keep its bypass list empty"
rc_is 1 "github merged ruleset, empty bypass: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
gh_rs "$R" 2 '{"id":2,"enforcement":"active","bypass_actors":[],"current_user_can_bypass":"never"}'
run check
row_is drift "github.com/$R" "github main-owner-only with an empty bypass list: drift (Michael is locked out), never ok"
out_has "# in the UI: https://github.com/$R/rules/2: Enforcement Active, bypass list Repository admin" "github main-owner-only, empty bypass: the UI note names Repository admin"
out_hasnt 'bypass list none' "github main-owner-only, empty bypass: never told to keep its bypass list empty"
rc_is 1 "github main-owner-only, empty bypass: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
gh_rs "$R" 2 "{\"id\":2,\"enforcement\":\"active\",\"bypass_actors\":[$BYADMIN,{\"actor_type\":\"User\",\"actor_id\":42,\"bypass_mode\":\"always\"}],\"current_user_can_bypass\":\"always\"}"
run check
row_is drift "github.com/$R" "github an extra bypass actor: drift row"
out_has "# in the UI: https://github.com/$R/rules/2: Enforcement Active, bypass list Repository admin" "github an extra bypass actor: the UI note"
out_hasnt '"name":"main-owner-only"' "github an extra bypass actor: no second owner-only POST beside the UI note"
out_hasnt '"name":"protect-main"' "github an extra bypass actor: protect-main is fine and not printed"
rc_is 1 "github an extra bypass actor: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
gh_rs "$R" 1 '{"id":1,"enforcement":"evaluate","bypass_actors":[],"current_user_can_bypass":"never"}'
run check
row_is drift "github.com/$R" "github ruleset in evaluate mode: drift row"
out_has "# in the UI: https://github.com/$R/rules/1: Enforcement Active, bypass list none" "github ruleset in evaluate mode: the UI note"
out_hasnt '"name":"protect-main"' "github ruleset in evaluate mode: no second protect-main POST beside the UI note"
rc_is 1 "github ruleset in evaluate mode: exit 1"

for mode in always pull_requests_only; do
  reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_agent "$R"
  gh_rs "$R" 1 "{\"id\":1,\"enforcement\":\"active\",\"current_user_can_bypass\":\"$mode\"}"
  run check
  row_is drift "github.com/$R" "github protect-main without bypass_actors, current_user_can_bypass $mode: drift"
  out_has "rules/1: Enforcement Active, bypass list none" "github protect-main, bypass $mode: the UI note"
  reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_agent "$R"
  gh_rs "$R" 2 "{\"id\":2,\"enforcement\":\"active\",\"current_user_can_bypass\":\"$mode\"}"
  run check
  row_is drift "github.com/$R" "github main-owner-only without bypass_actors, current_user_can_bypass $mode: drift"
  out_has "rules/2: Enforcement Active, bypass list Repository admin" "github main-owner-only, bypass $mode: the UI note"
done

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
gh_rs "$R" 2 '{"id":2,"enforcement":"active","bypass_actors":[{"actor_type":"RepositoryRole","actor_id":2,"bypass_mode":"always"}],"current_user_can_bypass":"always"}'
run check
row_is drift "github.com/$R" "github the only bypass actor is RepositoryRole 2, not 5: drift"
out_has "rules/2: Enforcement Active, bypass list Repository admin" "github bypass role 2: the UI note"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
gh_rules "$R" "$(join "$PM_RULES" '[]')"
ans gh "api --paginate repos/$R/rules/branches/main?per_page=100" "$PM_RULES
$OO_RULES"
run check
row_is ok "github.com/$R" "github update rule on the second page: ok (every page is merged)"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
ans gh "api --paginate repos/$R/rules/branches/main?per_page=100" '{"message":"Forbidden"}' 1 "gh: Forbidden (HTTP 403)"
run check
row_is unreadable "github.com/$R.*HTTP 403" "github rules read 403: unreadable naming HTTP 403"
rc_is 1 "github rules read 403: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"
ans gh "api repos/$R" '{"message":"Not Found"}' 1 "gh: Not Found (HTTP 404)"
run check
row_is unreadable "github.com/$R.*HTTP 404" "github repo 404: unreadable"
rc_is 1 "github repo 404: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
ans gh "api repos/$R" '{"default_branch":"main"}' "" "" 5
export FORGE_PROTECTION_TIMEOUT=1
run check
unset FORGE_PROTECTION_TIMEOUT
row_is unreadable "github.com/$R.*no answer within 1s" "github no answer: unreadable naming the timeout"
if [ "$SECS" -lt 4 ]; then _pass "github no answer: returns within 4 s (took ${SECS}s)"; else _fail "github no answer: returns within 4 s (took ${SECS}s)"; fi

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
gh_rs "$R" 1 '{"id":1,"enforcement":"active"}'
run check
row_is unreadable "github.com/$R.*neither bypass_actors" "github bypass not readable: unreadable"
rc_is 1 "github bypass not readable: exit 1"

# The remedy lines embed forge-supplied text: run each printed line with `gh` replaced by a
# function that keeps the --input body, and check nothing but that call ran and the body is intact.
eval_remedy() {  # <fixed string selecting the line> -> sets BODY, EXTRA (1 if the injected file appeared)
  local line
  line=$(printf '%s\n' "$OUT" | grep -F -- "$1" | head -n 1)
  rm -f "$T/pwned" "$T/evaldir/pwned" "$T/body"
  ( mkdir -p "$T/evaldir" && cd "$T/evaldir" &&
    gh() { cat "${@: -1}" > "$T/body"; }
    eval "$line" ) >/dev/null 2>&1
  BODY=$(cat "$T/body" 2>/dev/null); EXTRA=0; [ ! -e "$T/pwned" ] && [ ! -e "$T/evaldir/pwned" ] || EXTRA=1
}
HOSTILE="x';touch $T/pwned;echo '"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"
ans gh "api repos/$R" "$(jq -nc --arg b "$HOSTILE" '{default_branch:$b}')"
ans gh "api --paginate repos/$R/rules/branches/$(jq -rn --arg b "$HOSTILE" '$b | @uri')?per_page=100" '[]'
run check
row_is drift "github.com/$R" "hostile default branch: drift row"
eval_remedy '"name":"protect-main"'
if [ "$EXTRA" -eq 0 ]; then _pass "hostile default branch: pasting the protect-main line runs nothing extra"; else _fail "hostile default branch: pasting the protect-main line runs nothing extra"; fi
if [ "$(printf '%s' "$BODY" | jq -r '.conditions.ref_name.include[0]' 2>/dev/null)" = "refs/heads/$HOSTILE" ]; then
  _pass "hostile default branch: the pasted line hands gh the exact ref"
else _fail "hostile default branch: the pasted line hands gh the exact ref (got $BODY)"; fi
eval_remedy '"name":"main-owner-only"'
if [ "$EXTRA" -eq 0 ] && [ "$(printf '%s' "$BODY" | jq -r '.name' 2>/dev/null)" = main-owner-only ]; then
  _pass "the owner-only line pastes back to its own body"
else _fail "the owner-only line pastes back to its own body"; fi

# the repo path comes from the origin URL: the printed remedy must quote it
HR='o/r$(touch pwned)'
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "https://github.com/$HR"
gh_repo "$HR"; gh_rules "$HR" "$PM_RULES"
gh_rs "$HR" 1 '{"id":1,"enforcement":"active","bypass_actors":[],"current_user_can_bypass":"never"}'
run check
row_is drift 'github.com/o/r' "hostile repo path: drift row"
out_has "repos/'o/r\$(touch pwned)'/rulesets" "hostile repo path: the printed remedy quotes the repo path"
eval_remedy '"name":"main-owner-only"'
if [ "$EXTRA" -eq 0 ]; then _pass "hostile repo path: pasting the remedy line runs nothing extra"; else _fail "hostile repo path: pasting the remedy line runs nothing extra"; fi

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"
ans gh "api repos/$R" '{"default_branch":"a\nb"}'
run check
row_is unreadable "github.com/$R.*control characters" "a default branch with a control character is unreadable, never printed into a row"

echo "B. unknown host, exceptions"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "git@gh-alias:$R.git"
run check
row_is unreadable "gh-alias/$R.*gh-alias" "unknown host: unreadable naming the host"
if [ -s "$CALLS" ]; then _fail "unknown host: no forge call"; else _pass "unknown host: no forge call"; fi
rc_is 1 "unknown host: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "git@gh-alias:$R.git"; mkrepo "$H/Code/ExampleOrg/ok-repo" "https://github.com/example-owner/ok-repo.git"
gh_michael example-owner/ok-repo
mkdir -p "$H/.config/forge-protection"
printf '# accepted\n\nhttps://gh-alias/%s.git\n' "$R" > "$H/.config/forge-protection/exceptions"
run check
row_is excepted "gh-alias/$R" "exceptions: the unreadable remote is excepted (https form matches scp form)"
out_has "1 excepted" "exceptions: the summary counts it"
rc_is 0 "exceptions: exit 0 when the rest is ok"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "git@gh-alias:$R.git"
mkdir -p "$H/.config/forge-protection"
printf '#https://gh-alias/%s\n' "$R" > "$H/.config/forge-protection/exceptions"
run check
row_is unreadable "gh-alias/$R" "exceptions: a # line is ignored"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "git@gh-alias:$R.git"
run check
row_is unreadable "gh-alias/$R" "exceptions: with the file absent the same remote is unreadable"
rc_is 1 "exceptions: file absent: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "git@gh-alias:$R.git"
mkdir -p "$H/.config/forge-protection"; printf 'git@gh-alias:%s.git\n' "$R" > "$H/.config/forge-protection/exceptions"
run check
not_called . "excepted remote: no forge call at all"

echo "C. walk"
reset
mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; mkrepo "$H/Code/ExampleOrg/example-repo-copy" "https://github.com/$R"
mkrepo "$H/Code/ExampleOrg/no-origin"; mkrepo "$H/.local/share/chezmoi" "https://github.com/example-owner/dotfiles.git"
mkrepo "$H/Code/ExampleOrg/aaa" "https://github.com/aaa-owner/aaa-repo.git"
mkdir -p "$H/Code/ExampleOrg/not-a-checkout"
gh_michael "$R"; gh_michael example-owner/dotfiles; gh_michael aaa-owner/aaa-repo
run check
rows_are ok 3 "dedupe: two checkouts with one origin give one row, the dotfiles and another repository their own"
out_has "3 repositories: 3 ok, 0 drift, 0 unreadable, 0 excepted; 1 checkouts without origin skipped" "no origin: skipped and counted, a plain directory is neither"
# the walk reaches the dotfiles first and aaa-repo second, so only a sort puts aaa-repo first
rowlist=$(printf '%s\n' "$OUT" | grep '^ok ' | awk '{print $2}')
first=$(printf '%s\n' "$rowlist" | head -n 1)
case "$first" in "github.com/aaa-owner/aaa-repo") _pass "rows start with the remote that sorts first, not the first one walked" ;; *) _fail "rows start with the remote that sorts first, not the first one walked (got $first)" ;; esac
if [ "$rowlist" = "$(printf '%s\n' "$rowlist" | sort)" ]; then _pass "rows are in sorted order"; else _fail "rows are in sorted order"; fi

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "https://github.com/$R.git" "git@gh-alias:$R.git"
run check
row_is unreadable "gh-alias/$R" "the remote is where pushes go (pushurl wins over url)"

echo "D. normalize_remote"
norm() { (. /dev/stdin <<<"$(sed -n '/^normalize_remote()/,/^}/p' "$SCRIPT")"; normalize_remote "$1"); }
for pair in \
  "git@github.com:Example-Owner/Example-Repo.git|github.com/example-owner/example-repo" \
  "git@x@github.com:Example-Owner/Example-Repo.git|github.com/example-owner/example-repo" \
  "https://user@github.com:443/example-owner/example-repo/|github.com/example-owner/example-repo" \
  "https://user:p@ss@github.com/example-owner/example-repo.git|github.com/example-owner/example-repo" \
  "ssh://git@gitlab.com/example-group/example-sub/example-repo.git|gitlab.com/example-group/example-sub/example-repo" \
  "git@ssh.dev.azure.com:v3/example-org/Example%20Project/example-repo|dev.azure.com/example-org/example project/example-repo" \
  "example-org@vs-ssh.visualstudio.com:v3/example-org/Example%20Project/example-repo|dev.azure.com/example-org/example project/example-repo" \
  "https://example-org@dev.azure.com/example-org/Example%20Project/_git/example-repo|dev.azure.com/example-org/example project/example-repo" \
  "https://example-org.visualstudio.com/Example%20Project/_git/example-repo|dev.azure.com/example-org/example project/example-repo" ; do
  got=$(norm "${pair%%|*}")
  if [ "$got" = "${pair#*|}" ]; then _pass "normalize ${pair%%|*}"; else _fail "normalize ${pair%%|*} (got $got)"; fi
done

echo "E0. az_read allow-list"
azr() {  # <args...>: runs az_read with forge_call recorded instead of run; prints "<rc> <recorded call>"
  ( forge_call() { echo "forge_call $*" > "$T/azr.call"; FC_RC=0; return 0; }
    . /dev/stdin <<<"$(sed -n '/^az_read()/,/^}/p' "$SCRIPT")"
    rm -f "$T/azr.call"
    az_read "$@" >/dev/null 2>&1; rc=$?
    printf '%s %s' "$rc" "$(cat "$T/azr.call" 2>/dev/null)" )
}
for v in "repos show --id x" "repos policy list --repository-id x" "account show" "devops security permission show --id x"; do
  # shellcheck disable=SC2086
  got=$(azr $v)
  if [ "$got" = "0 forge_call az $v" ]; then _pass "az_read allows: $v"; else _fail "az_read allows: $v (got $got)"; fi
done
for v in "repos policy create --id x" "repos policy update --id x" "repos delete --id x" "repos create --name x" "account set --subscription x" "devops security permission update --id x" "pipelines run" ""; do
  # shellcheck disable=SC2086
  got=$(azr $v)
  if [ "$got" = "125 " ]; then _pass "az_read refuses with 125 and no call: ${v:-(no arguments)}"; else _fail "az_read refuses with 125 and no call: ${v:-(no arguments)} (got $got)"; fi
done

echo "E. no write"
bad=$(grep -E '^gh ' "$ALLCALLS" | grep -vE '^gh api ' || true)
bad="$bad$(grep -E '^(gh|glab) ' "$ALLCALLS" | grep -E ' (--method|-X|-f|-F|--field|--raw-field|--input)( |$)' || true)"
if [ -z "$bad" ]; then _pass "no write: every gh/glab call is a plain api GET"; else _fail "no write: every gh/glab call is a plain api GET"; printf '    %s\n' "$bad"; fi
bad=$(grep -E '^az ' "$ALLCALLS" | grep -vE '^az (repos show|repos policy list|account show|devops security permission show)' || true)
if [ -z "$bad" ]; then _pass "no write: every az call is an allowed read verb"; else _fail "no write: every az call is an allowed read verb"; fi
if grep -qE 'DELETE|unprotect' "$ALLOUT"; then _fail "no write: printed output never holds DELETE or unprotect"; else _pass "no write: printed output never holds DELETE or unprotect"; fi
if grep -q '^gh api' "$ALLCALLS"; then _pass "no write: the cases made gh calls"; else _fail "no write: the cases made gh calls"; fi

body=$(grep -vE '^[[:space:]]*#' "$SCRIPT")
bad=$(printf '%s\n' "$body" | grep -E '(^|[^A-Za-z0-9_])(POST|PUT|PATCH|DELETE)([^A-Za-z0-9_]|$)' | grep -vE '^[[:space:]]*(remedy|note) ' || true)
if [ -z "$bad" ]; then _pass "no write verb: POST/PUT/PATCH/DELETE only on remedy and note lines"; else _fail "no write verb: POST/PUT/PATCH/DELETE only on remedy and note lines"; printf '    %s\n' "$bad"; fi
bad=$(printf '%s\n' "$body" | grep -E '(^|[^A-Za-z0-9_])(gh|glab|az|gh_get|glab_get|az_read|forge_call)([^A-Za-z0-9_-]|$).*(create|update|delete|merge|approve|protect)' | grep -vE '^[[:space:]]*(remedy|note) ' || true)
if [ -z "$bad" ]; then _pass "no write verb: no forge call line holds create/update/delete/merge/approve/protect"; else _fail "no write verb: no forge call line holds create/update/delete/merge/approve/protect"; printf '    %s\n' "$bad"; fi

echo "F. usage"
reset; run frobnicate
rc_is 2 "usage: an unknown command exits 2"
run --help
rc_is 0 "usage: --help exits 0"
out_has "Usage: forge-protection.sh check" "usage: --help prints the usage"

echo
echo "$pass/$((pass + fail)) passed, $fail failed"
[ "$fail" -eq 0 ]
