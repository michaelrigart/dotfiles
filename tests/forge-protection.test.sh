#!/usr/bin/env bash
# Mocked test for .scripts/forge-protection.sh: stubs gh, glab and az on PATH (every argv is
# appended to $CALLS; answers come from $T/answers/<tool>/<key>{.out,.rc,.err,.sleep}, the key
# being the argv with every character outside A-Za-z0-9 turned into _, a key over 200 characters cut and
# suffixed with its cksum) and asserts each row's
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
[ "${#key}" -le 200 ] || key="${key:0:100}_$(printf '%s' "$key" | cksum | tr ' ' _)"
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
  [ "${#k}" -le 200 ] || k="${k:0:100}_$(printf '%s' "$k" | cksum | tr ' ' _)"
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
  rm -f "$T/pwned" "$T/evaldir/pwned" "$T/body" "$T/argv"
  ( mkdir -p "$T/evaldir" && cd "$T/evaldir" &&
    gh() { cat "${@: -1}" > "$T/body"; }
    glab() { printf '%s\n' "$@" > "$T/argv"; cat "${@: -1}" > "$T/body" 2>/dev/null; }
    az() { printf '%s\n' "$@" > "$T/argv"; }
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

echo "A2. gitlab"
GP=example-group/example-sub/example-app
GENC=example-group%2Fexample-sub%2Fexample-app
GID=77
GLA="api --hostname gitlab.com"
gl_proj() { ans glab "$GLA projects/$GENC" "{\"id\":$GID,\"default_branch\":\"${1:-main}\"}"; }
gl_pb()   { ans glab "$GLA --paginate projects/$GID/protected_branches?per_page=100" "$1"; }
# glrule <name> <push level> <merge level> <force push> [first entry id]: one protected-branch rule
glrule() { jq -nc --arg n "$1" --argjson p "$2" --argjson m "$3" --argjson f "$4" --argjson i "${5:-10}" \
  '{id:$i,name:$n,push_access_levels:[{id:$i,access_level:$p}],merge_access_levels:[{id:($i+1),access_level:$m}],allow_force_push:$f}'; }
glab_case() {  # <protected_branches answer> [default branch]: a fresh fixture, then a run
  reset; mkrepo "$H/Code/ExampleOrg/example-app" "git@gitlab.com:$GP.git"
  gl_proj "${2:-main}"; gl_pb "$1"
  run check
}
GL_STRICT=$(glrule main 0 40 false 10)
GLR="gitlab.com/$GP"

glab_case "[$GL_STRICT]"
row_is ok "$GLR" "gitlab ok (nested group path, @uri encoded): ok row"
rc_is 0 "gitlab ok: exit 0"
if grep -q "projects/$GENC\$" "$CALLS"; then _pass "gitlab ok: the nested path is @uri encoded in the call"; else _fail "gitlab ok: the nested path is @uri encoded in the call"; fi

glab_case '[]'
row_is drift "$GLR" "gitlab no rule: drift row"
out_has "glab api --hostname gitlab.com --method POST projects/$GID/protected_branches -f 'name=main' -f push_access_level=0 -f merge_access_level=40 -f allow_force_push=false" "gitlab no rule: the POST with push 0, merge 40, force push off"
out_hasnt "PATCH" "gitlab no rule: no PATCH"
rc_is 1 "gitlab no rule: exit 1"

glab_case "[$(glrule main 40 40 false 10)]"
row_is drift "$GLR" "gitlab push Maintainers: drift row"
out_has "--method PATCH projects/$GID/protected_branches/main " "gitlab push Maintainers: the PATCH names the rule in place"
out_has '"allowed_to_push":[{"id":10,"_destroy":true},{"access_level":0}]' "gitlab push Maintainers: the push entry is destroyed and No one added"
out_hasnt 'allowed_to_merge' "gitlab push Maintainers: the merge side is left alone"
out_hasnt 'allow_force_push' "gitlab push Maintainers: force push is left alone"
out_has "# in place, never removed and re-created" "gitlab push Maintainers: the in-place note"
out_has "# or in the UI: Settings > Repository > Protected branches > main: Allowed to push and merge: No one; Allowed to force push: off" "gitlab push Maintainers: the UI note"
out_hasnt "--method POST" "gitlab push Maintainers: no POST beside the PATCH"
out_hasnt "Allowed to merge" "gitlab push Maintainers: the UI note leaves the merge side alone"
rc_is 1 "gitlab push Maintainers: exit 1"

glab_case "[$(glrule main 0 40 true 10)]"
row_is drift "$GLR" "gitlab force push on: drift row"
out_has '"allow_force_push":false' "gitlab force push on: the PATCH turns it off"
out_hasnt 'allowed_to_push' "gitlab force push on: the push side is left alone"

glab_case "[$(glrule main 0 30 false 10)]"
row_is drift "$GLR" "gitlab merge Developers: drift row"
out_has '"allowed_to_merge":[{"id":11,"_destroy":true},{"access_level":40}]' "gitlab merge Developers: the merge entry is replaced by Maintainers"
out_has "Allowed to merge: Maintainers" "gitlab merge Developers: the UI note names Allowed to merge: Maintainers"

glab_case "[$(glrule main 0 0 false 10)]"
row_is ok "$GLR" "gitlab merge No one: ok"

glab_case '[{"id":10,"name":"main","push_access_levels":[{"id":10,"access_level":0,"deploy_key_id":3}],"merge_access_levels":[{"id":11,"access_level":40}],"allow_force_push":false}]'
row_is drift "$GLR" "gitlab a deploy key allowed to push: drift row"
out_has '"allowed_to_push":[{"id":10,"_destroy":true},{"access_level":0}]' "gitlab a deploy key allowed to push: the entry is destroyed"

# a user or a group allowed to push or merge is drift, even at a permitted level
glrule_with() {  # <push entries> <merge entries> [force push]: one rule named main with literal entry lists
  printf '[{"id":10,"name":"main","push_access_levels":%s,"merge_access_levels":%s,"allow_force_push":%s}]' "$1" "$2" "${3:-false}"
}
glab_case "$(glrule_with '[{"id":10,"access_level":0,"user_id":5}]' '[{"id":11,"access_level":40}]')"
row_is drift "$GLR" "gitlab a user allowed to push (level 0): drift row"
glab_case "$(glrule_with '[{"id":10,"access_level":0,"group_id":6}]' '[{"id":11,"access_level":40}]')"
row_is drift "$GLR" "gitlab a group allowed to push (level 0): drift row"
glab_case "$(glrule_with '[{"id":10,"access_level":0}]' '[{"id":11,"access_level":40,"user_id":5}]')"
row_is drift "$GLR" "gitlab a user allowed to merge (level 40): drift row"
out_has '"allowed_to_merge":[{"id":11,"_destroy":true},{"access_level":40}]' "gitlab a user allowed to merge: the entry is destroyed and Maintainers added"
glab_case "$(glrule_with '[{"id":10,"access_level":0}]' '[{"id":11,"access_level":40,"group_id":6}]')"
row_is drift "$GLR" "gitlab a group allowed to merge (level 40): drift row"

# a missing allow_force_push counts as on
glab_case '[{"id":10,"name":"main","push_access_levels":[{"id":10,"access_level":0}],"merge_access_levels":[{"id":11,"access_level":40}]}]'
row_is drift "$GLR" "gitlab allow_force_push missing: drift row (counts as on)"
out_has '"allow_force_push":false' "gitlab allow_force_push missing: the PATCH turns it off"

# an access-level list that is absent or not a list cannot be read: never counted protected
gl_unread() {  # <label> <answer> <field>
  glab_case "$2"
  row_is unreadable "$GLR.*rule main: $3 is not a list" "gitlab $1: unreadable naming the rule and the field"
  rc_is 1 "gitlab $1: exit 1"
  out_hasnt "--method" "gitlab $1: no remedy is printed"
}
gl_unread "push_access_levels absent" '[{"id":10,"name":"main","merge_access_levels":[{"id":11,"access_level":40}],"allow_force_push":false}]' push_access_levels
gl_unread "merge_access_levels absent" '[{"id":10,"name":"main","push_access_levels":[{"id":10,"access_level":0}],"allow_force_push":false}]' merge_access_levels
gl_unread "push_access_levels null" "$(glrule_with null '[{"id":11,"access_level":40}]')" push_access_levels
gl_unread "push_access_levels an object" "$(glrule_with '{"id":10,"access_level":0}' '[{"id":11,"access_level":40}]')" push_access_levels
gl_unread "merge_access_levels a string" "$(glrule_with '[{"id":10,"access_level":0}]' '"none"')" merge_access_levels
glab_case "[$GL_STRICT,{\"id\":30,\"name\":\"develop\",\"allow_force_push\":true}]"
row_is ok "$GLR" "gitlab a rule for another branch without access-level lists is not judged: ok"

# an explicit empty list says nothing about No one: drift, and the PATCH adds the role
glab_case "$(glrule_with '[]' '[{"id":11,"access_level":40}]')"
row_is drift "$GLR" "gitlab an empty push list: drift row"
out_has '"allowed_to_push":[{"access_level":0}]' "gitlab an empty push list: the PATCH adds No one"
glab_case "$(glrule_with '[{"id":10,"access_level":0}]' '[]')"
row_is drift "$GLR" "gitlab an empty merge list: drift row"
out_has '"allowed_to_merge":[{"access_level":40}]' "gitlab an empty merge list: the PATCH adds Maintainers"

# the role entry is added only when no entry survives the destroy
glab_case "$(glrule_with '[{"id":10,"access_level":0},{"id":12,"access_level":0,"deploy_key_id":3}]' '[{"id":11,"access_level":40}]')"
row_is drift "$GLR" "gitlab a surviving No one push entry: drift row"
out_has '"allowed_to_push":[{"id":12,"_destroy":true}]}' "gitlab a surviving No one push entry: only the offender is destroyed, no role entry added"
glab_case "$(glrule_with '[{"id":10,"access_level":0}]' '[{"id":11,"access_level":40},{"id":13,"access_level":30}]')"
row_is drift "$GLR" "gitlab a surviving Maintainers merge entry: drift row"
out_has '"allowed_to_merge":[{"id":13,"_destroy":true}]}' "gitlab a surviving Maintainers merge entry: only the offender is destroyed, no role entry added"
glab_case "$(glrule_with '[{"id":10,"access_level":0}]' '[{"id":11,"access_level":0},{"id":13,"access_level":30}]')"
out_has '"allowed_to_merge":[{"id":13,"_destroy":true}]}' "gitlab a surviving No one merge entry: only the offender is destroyed, Maintainers is not added"

glab_case "[$GL_STRICT,$(glrule 'ma*' 40 40 false 20)]"
row_is drift "$GLR" "gitlab strict exact rule beside a permissive wildcard: drift row"
out_has "protected_branches/ma%2A " "gitlab strict exact beside a permissive wildcard: the PATCH names the wildcard rule"
if [ "$(printf '%s\n' "$OUT" | grep -c -- '--method PATCH')" -eq 1 ]; then _pass "gitlab strict exact beside a permissive wildcard: the strict exact rule is not patched"; else _fail "gitlab strict exact beside a permissive wildcard: the strict exact rule is not patched"; fi

glab_case "[$GL_STRICT,$(glrule 'ma*' 0 40 false 20)]"
row_is ok "$GLR" "gitlab strict exact and strict wildcard: ok"

glab_case "[$GL_STRICT]"
ans glab "$GLA --paginate projects/$GID/protected_branches?per_page=100" "[$GL_STRICT]
[$(glrule 'ma*' 40 40 false 20)]"
run check
row_is drift "$GLR" "gitlab a permissive wildcard on the second page: drift (every page is merged)"
out_has "protected_branches/ma%2A " "gitlab a permissive wildcard on the second page: the PATCH names it"

glab_case "[$(glrule develop 40 40 true 10)]"
row_is drift "$GLR" "gitlab rule for another branch only: drift row"
out_has "--method POST projects/$GID/protected_branches -f 'name=main'" "gitlab rule for another branch only: the POST is printed"
out_hasnt "PATCH" "gitlab rule for another branch only: the other branch's rule is not patched"

glab_case "[$GL_STRICT,$(glrule 'dev*' 40 40 true 20),$(glrule mai 40 40 true 30),$(glrule 'm.in' 40 40 true 40),$(glrule 'main2' 40 40 true 50)]"
row_is ok "$GLR" "gitlab non-matching rules (other wildcard, prefix, regex dot, suffix) are ignored: ok"

glab_case "[$GL_STRICT,$(glrule '*' 40 40 false 20)]"
row_is drift "$GLR" "gitlab a bare * rule matches every branch: drift"

# the match is anchored at both ends: a proper suffix (ain) or prefix (mai) of main is another branch's rule
glab_case "[$(glrule ain 40 40 true 10),$(glrule mai 40 40 true 20)]"
row_is drift "$GLR" "gitlab rules ain and mai (a suffix and a prefix of main): drift row"
out_has "--method POST projects/$GID/protected_branches -f 'name=main'" "gitlab rules ain and mai: no rule matches, so the POST is printed"
out_hasnt "PATCH" "gitlab rules ain and mai: neither is patched"

reset; mkrepo "$H/Code/ExampleOrg/example-app" "git@gitlab.com:$GP.git"
ans glab "$GLA projects/$GENC" '{"message":"404 Project Not Found"}' 1 "glab: 404 Project Not Found (HTTP 404)"
run check
row_is unreadable "$GLR.*HTTP 404" "gitlab project 404: unreadable naming HTTP 404"
rc_is 1 "gitlab project 404: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-app" "git@gitlab.com:$GP.git"; gl_proj
ans glab "$GLA --paginate projects/$GID/protected_branches?per_page=100" '{"message":"403 Forbidden"}' 1 "glab: 403 Forbidden (HTTP 403)"
run check
row_is unreadable "$GLR.*HTTP 403" "gitlab protected_branches 403: unreadable naming HTTP 403"
rc_is 1 "gitlab protected_branches 403: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-app" "git@gitlab.com:$GP.git"; gl_proj; gl_pb "[$GL_STRICT]"
ans glab "$GLA projects/$GENC" "{\"id\":$GID,\"default_branch\":\"main\"}" "" "" 5
export FORGE_PROTECTION_TIMEOUT=1
run check
unset FORGE_PROTECTION_TIMEOUT
row_is unreadable "$GLR.*no answer within 1s" "gitlab no answer: unreadable naming the timeout"
if [ "$SECS" -lt 4 ]; then _pass "gitlab no answer: returns within 4 s (took ${SECS}s)"; else _fail "gitlab no answer: returns within 4 s (took ${SECS}s)"; fi

glab_case '{"message":"odd"}'
row_is unreadable "$GLR.*not a list" "gitlab an answer that is not a list: unreadable"

reset; mkrepo "$H/Code/ExampleOrg/example-app" "git@gitlab.com:$GP.git"
ans glab "$GLA projects/$GENC" '{"default_branch":"main"}'
run check
row_is unreadable "$GLR.*no project id" "gitlab no project id: unreadable"

glab_case '[]' 'a\nb'
row_is unreadable "$GLR.*control characters" "gitlab a default branch with a control character is unreadable"

# The remedy lines embed forge-supplied branch and rule names: pasted, each must run nothing extra
# and hand glab the exact name.
glab_case '[]' "$HOSTILE"
row_is drift "$GLR" "gitlab hostile default branch: drift row"
eval_remedy "--method POST"
if [ "$EXTRA" -eq 0 ]; then _pass "gitlab hostile default branch: pasting the POST line runs nothing extra"; else _fail "gitlab hostile default branch: pasting the POST line runs nothing extra"; fi
if grep -qxF "name=$HOSTILE" "$T/argv"; then _pass "gitlab hostile default branch: the pasted POST hands glab the exact name"; else _fail "gitlab hostile default branch: the pasted POST hands glab the exact name"; fi

# a name with no quote character at all: only the shell quoting of the word stops `;` from ending the command
HOSTILE2="x;touch $T/pwned;y"
glab_case '[]' "$HOSTILE2"
row_is drift "$GLR" "gitlab hostile default branch without quotes: drift row"
eval_remedy "--method POST"
if [ "$EXTRA" -eq 0 ]; then _pass "gitlab hostile default branch without quotes: pasting the POST line runs nothing extra"; else _fail "gitlab hostile default branch without quotes: pasting the POST line runs nothing extra"; fi
if grep -qxF "name=$HOSTILE2" "$T/argv"; then _pass "gitlab hostile default branch without quotes: the pasted POST hands glab the exact name"; else _fail "gitlab hostile default branch without quotes: the pasted POST hands glab the exact name"; fi

HRULE="main';touch $T/pwned;echo '"
glab_case "[$(glrule "$HRULE" 40 40 true 10)]" "$HRULE"
row_is drift "$GLR" "gitlab hostile rule name: drift row"
eval_remedy "--method PATCH"
if [ "$EXTRA" -eq 0 ]; then _pass "gitlab hostile rule name: pasting the PATCH line runs nothing extra"; else _fail "gitlab hostile rule name: pasting the PATCH line runs nothing extra"; fi
if [ "$(jq -c . < "$T/body" 2>/dev/null)" = '{"allow_force_push":false,"allowed_to_push":[{"id":10,"_destroy":true},{"access_level":0}]}' ]; then
  _pass "gitlab hostile rule name: the pasted PATCH hands glab the exact JSON body"
else _fail "gitlab hostile rule name: the pasted PATCH hands glab the exact JSON body (got $(cat "$T/body" 2>/dev/null))"; fi
if grep -qxF "projects/$GID/protected_branches/$(jq -rn --arg b "$HRULE" '$b | @uri')" "$T/argv"; then
  _pass "gitlab hostile rule name: the pasted PATCH endpoint is the encoded name"
else _fail "gitlab hostile rule name: the pasted PATCH endpoint is the encoded name"; fi

echo "A3. azure"
AZORG=example-org; AZOURL="https://dev.azure.com/$AZORG"
AZURL="https://$AZORG@dev.azure.com/$AZORG/Example%20Project/_git/example-repo"
AZR="dev.azure.com/$AZORG/example project/example-repo"
AZPID=11111111-aaaa-bbbb-cccc-000000000001; AZRID=22222222-aaaa-bbbb-cccc-000000000002
AZNS=2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87
AZUSER=michael@example.com
AZACCT="{\"user\":{\"name\":\"$AZUSER\"}}"
# the permission token, computed here by an independent implementation
az_tok() {  # <project id> <repo id> <branch>
  /usr/bin/python3 -I -c 'import sys; print("repoV2/%s/%s/refs/heads/%s/" % (sys.argv[1], sys.argv[2], "/".join(s.encode("utf-16-le").hex() for s in sys.argv[3].split("/"))))' "$1" "$2" "$3"
}
az_show() { ans az "repos show --org $AZOURL --project $1 --repository $2 --output json" "$3"; }
az_showok() {  # <project> <repo> [branch] [repo id]
  az_show "$1" "$2" "$(jq -nc --arg b "refs/heads/${3:-main}" --arg r "${4:-$AZRID}" --arg p "$AZPID" '{id:$r,defaultBranch:$b,project:{id:$p}}')"
}
az_pol()  { ans az "repos policy list --org $AZOURL --project $1 --repository-id $2 --branch $3 --output json" "$4"; }  # <project> <repo id> <branch> <answer>
az_acct() { ans az "account show --output json" "${1:-$AZACCT}"; }
az_perm() {  # <repo id> <branch> <answer> [user]
  ans az "devops security permission show --id $AZNS --subject ${4:-$AZUSER} --token $(az_tok "$AZPID" "$1" "$2") --org $AZOURL --output json" "$3"
}
AZREVID=fa4e907d-c16b-4a4c-9dfa-4906e5d171dd   # the policy type id of Minimum number of reviewers
AZBUILDID=0609b952-1397-4640-95ec-e00a01b2c241  # the policy type id of Build
pol() {  # <display name> <enabled> <blocking> <count> [type id, default the reviewers type]
  jq -nc --arg n "$1" --argjson e "$2" --argjson b "$3" --argjson c "$4" --arg t "${5:-$AZREVID}" '{id:7,isEnabled:$e,isBlocking:$b,settings:{minimumApproverCount:$c},type:{id:$t,displayName:$n}}'
}
# acd <effectiveAllow> <effectiveDeny>: one entry carrying both
acd() { printf '[{"acesDictionary":{"d":{"allow":0,"deny":0,"extendedInfo":{"effectiveAllow":%s,"effectiveDeny":%s}}},"includeExtendedInfo":true,"inheritPermissions":true,"token":"t"}]' "$1" "$2"; }
ace() { printf '[{"acesDictionary":{"d":{"allow":0,"deny":0,"extendedInfo":{"effectiveAllow":%s}}},"includeExtendedInfo":true,"inheritPermissions":true,"token":"t"}]' "$1"; }
AZGOOD=$(pol "Minimum number of reviewers" true true 1)
AZREALISTIC=16502   # bits 2, 4, 16, 32, 64 and 16384: none of 8, 128, 32768
N8='Force push (rewrite history, delete branches and tags)'
N128='Bypass policies when pushing'
N32768='Bypass policies when completing pull requests'
azure_case() {  # <policies answer> <permission answer> [branch]
  local b=${3:-main}
  reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
  az_showok "example project" example-repo "$b"
  az_pol "example project" "$AZRID" "$b" "$1"
  az_acct
  az_perm "$AZRID" "$b" "$2"
  run check
}
azu() {  # <label> <reason regex> <policies answer> <permission answer>: one fail-closed case
  azure_case "$3" "$4"
  row_is unreadable "$AZR.*$2" "azure $1: unreadable"
  rc_is 1 "azure $1: exit 1"
  out_hasnt "approver-count create" "azure $1: no remedy is printed"
}

azure_case "[$AZGOOD]" "$(ace $AZREALISTIC)"
row_is ok "$AZR" "azure ok (project Example Project reached through %20): ok row"
rc_is 0 "azure ok: exit 0"
out_has "1 repositories: 1 ok" "azure ok: the summary counts it"
if grep -qx "az repos show --org $AZOURL --project example project --repository example-repo --output json" "$CALLS"; then _pass "azure ok: repos show gets the decoded project name and --output json"; else _fail "azure ok: repos show gets the decoded project name and --output json"; fi
if grep -qx "az devops security permission show --id $AZNS --subject $AZUSER --token repoV2/$AZPID/$AZRID/refs/heads/6d00610069006e00/ --org $AZOURL --output json" "$CALLS"; then _pass "azure ok: the token is repoV2/<project>/<repo>/refs/heads/<hex of main in UTF-16LE>/"; else _fail "azure ok: the token is repoV2/<project>/<repo>/refs/heads/<hex of main in UTF-16LE>/"; fi

azure_case "[$AZGOOD]" "$(ace $AZREALISTIC)" feature/x
row_is ok "$AZR.*default branch feature/x" "azure branch feature/x: ok row"
if grep -qx "az devops security permission show --id $AZNS --subject $AZUSER --token repoV2/$AZPID/$AZRID/refs/heads/6600650061007400750072006500/7800/ --org $AZOURL --output json" "$CALLS"; then _pass "azure branch feature/x: every path segment is hexed on its own, joined by /"; else _fail "azure branch feature/x: every path segment is hexed on its own, joined by /"; fi
if grep -qx "az repos policy list --org $AZOURL --project example project --repository-id $AZRID --branch feature/x --output json" "$CALLS"; then _pass "azure branch feature/x: policy list gets the plain branch name"; else _fail "azure branch feature/x: policy list gets the plain branch name"; fi

azure_case "[$AZGOOD]" "$(ace 0)" 'feature/é😀'
row_is ok "$AZR" "azure branch with a non-ASCII segment and a surrogate pair: ok row"
if grep -qx "az devops security permission show --id $AZNS --subject $AZUSER --token repoV2/$AZPID/$AZRID/refs/heads/6600650061007400750072006500/e9003dd800de/ --org $AZOURL --output json" "$CALLS"; then _pass "azure non-ASCII branch: UTF-16LE with a surrogate pair"; else _fail "azure non-ASCII branch: UTF-16LE with a surrogate pair"; fi

# no policy: the create command, every value shell-quoted
azure_case '[]' "$(ace $AZREALISTIC)"
row_is drift "$AZR" "azure no policy: drift row"
out_has "    az repos policy approver-count create --org $AZOURL --project 'example project' --repository-id $AZRID --branch main --blocking true --enabled true --minimum-approver-count 1 --creator-vote-counts true --allow-downvotes false --reset-on-source-push false" "azure no policy: the create command is filled in"
rc_is 1 "azure no policy: exit 1"
out_hasnt "Branch security" "azure no policy: no permission note when none is allowed"

# only the type Minimum number of reviewers counts, matched by its type id
azure_case "[$(pol 'Build' true true 1 "$AZBUILDID")]" "$(ace $AZREALISTIC)"
row_is drift "$AZR" "azure a blocking policy of another type only: drift row"
out_has "approver-count create" "azure a blocking policy of another type only: the create command is printed"
azure_case "[$(pol 'Build' true true 1 "$AZBUILDID"),$AZGOOD]" "$(ace $AZREALISTIC)"
row_is ok "$AZR" "azure a policy of another type beside the reviewers policy: ok"
azure_case "[$(pol 'Mindestanzahl von Prüfern' true true 1)]" "$(ace $AZREALISTIC)"
row_is ok "$AZR" "azure the reviewers policy under a localised display name (same type id): ok, matched by id"
out_hasnt "approver-count create" "azure the reviewers policy under a localised display name: no duplicate create"
azure_case "[$(pol 'Minimum number of reviewers' true true 1 "$AZBUILDID")]" "$(ace $AZREALISTIC)"
row_is drift "$AZR" "azure a policy named Minimum number of reviewers with another type id: drift, not counted"
out_has "approver-count create" "azure a policy named Minimum number of reviewers with another type id: the create command is printed"

# a reviewers policy that is off, optional or asks for nobody is drift with a note, not a second create
for spec in "disabled|false true 1" "not blocking|true false 1" "no reviewers|true true 0"; do
  set -- $(printf '%s' "${spec#*|}")
  azure_case "[$(pol 'Minimum number of reviewers' "$1" "$2" "$3")]" "$(ace $AZREALISTIC)"
  row_is drift "$AZR" "azure policy ${spec%%|*}: drift row"
  out_has '# Repos > Branches > main > Branch policies: Minimum number of reviewers must be enabled, Required and ask for at least 1 reviewer' "azure policy ${spec%%|*}: the click path is printed"
  out_hasnt "approver-count create" "azure policy ${spec%%|*}: no create command beside the existing policy"
  rc_is 1 "azure policy ${spec%%|*}: exit 1"
done
azure_case "[$(pol 'Minimum number of reviewers' false true 1),$AZGOOD]" "$(ace $AZREALISTIC)"
row_is ok "$AZR" "azure a disabled reviewers policy beside an enabled one: ok (any qualifying policy)"
azure_case "[$(pol 'Minimum number of reviewers' true true 2)]" "$(ace $AZREALISTIC)"
row_is ok "$AZR" "azure two required reviewers: ok"

# each of the three bits alone is drift naming its permission; the others never trigger it
for pair in "8|$N8" "128|$N128" "32768|$N32768"; do
  bit=${pair%%|*}; name=${pair#*|}
  azure_case "[$AZGOOD]" "$(ace $((AZREALISTIC + bit)))"
  row_is drift "$AZR" "azure bit $bit allowed: drift row"
  out_has "# Repos > Branches > main > Branch security > $AZUSER: set \"$name\" to Deny" "azure bit $bit allowed: the note names only that permission"
  rc_is 1 "azure bit $bit allowed: exit 1"
  out_hasnt "approver-count create" "azure bit $bit allowed: the policy is fine, no create command"
done
azure_case "[$AZGOOD]" "$(ace 32768)"
row_is drift "$AZR" "azure only PullRequestBypassPolicy (32768) allowed: drift"
azure_case "[$AZGOOD]" "$(ace $((AZREALISTIC + 8 + 128 + 32768)))"
out_has "set \"$N8\", \"$N128\", \"$N32768\" to Deny" "azure all three bits allowed: one note names all three"
# the bit anywhere in the answer counts, not just in the first entry
azure_case "[$AZGOOD]" '[{"acesDictionary":{"a":{"extendedInfo":{"effectiveAllow":0}},"b":{"extendedInfo":{"effectiveAllow":128}}}}]'
row_is drift "$AZR" "azure a second access control entry allows PolicyExempt: drift"
azure_case "[$AZGOOD]" "$(jq -nc --argjson a "$(ace 0)" --argjson b "$(ace 8)" '$a + $b')"
row_is drift "$AZR" "azure a second access control list allows ForcePush: drift"
azure_case '[]' "$(ace $((AZREALISTIC + 128)))"
out_has "approver-count create" "azure no policy and a bit: the create command"
out_has "set \"$N128\" to Deny" "azure no policy and a bit: and the permission note"
# effectiveDeny never cancels effectiveAllow (fail closed: a group grant can still apply): a bit in both is drift, a bit only denied is fine
azure_case "[$AZGOOD]" "$(acd $((AZREALISTIC + 128)) 128)"
row_is drift "$AZR" "azure a bit in effectiveAllow and in effectiveDeny: drift, the deny does not cancel it"
out_has "set \"$N128\" to Deny" "azure a bit in effectiveAllow and in effectiveDeny: the note names it"
out_has "a group grant" "azure a bypass bit: the note says a group grant stays effective when the user already shows Deny"
azure_case "[$AZGOOD]" "$(acd $AZREALISTIC 128)"
row_is ok "$AZR" "azure a bit only in effectiveDeny: ok"

# fail closed: an answer lacking a field the target depends on is never ok
azu "policies answer an object" "policies answer" '{"value":[]}' "$(ace 0)"
azu "policies answer null" "policies answer" 'null' "$(ace 0)"
azu "policies answer an object of policies" "policies answer" "{\"x\":$AZGOOD}" "$(ace 0)"
azu "policy without a type" "policies answer" '[{"isEnabled":true,"isBlocking":true,"settings":{"minimumApproverCount":1}}]' "$(ace 0)"
azu "policy type without an id" "policies answer" '[{"isEnabled":true,"isBlocking":true,"settings":{"minimumApproverCount":1},"type":{"displayName":"Minimum number of reviewers"}}]' "$(ace 0)"
azu "policy type id a number" "policies answer" "[$(printf '%s' "$AZGOOD" | jq -c '.type.id = 7')]" "$(ace 0)"
azu "policy type id null" "policies answer" "[$(printf '%s' "$AZGOOD" | jq -c '.type.id = null')]" "$(ace 0)"
azu "reviewers policy without isEnabled" "policies answer" "[$(printf '%s' "$AZGOOD" | jq -c 'del(.isEnabled)')]" "$(ace 0)"
azu "reviewers policy without isBlocking" "policies answer" "[$(printf '%s' "$AZGOOD" | jq -c 'del(.isBlocking)')]" "$(ace 0)"
azu "reviewers policy without minimumApproverCount" "policies answer" "[$(printf '%s' "$AZGOOD" | jq -c 'del(.settings.minimumApproverCount)')]" "$(ace 0)"
azu "reviewers policy with isEnabled a string" "policies answer" "[$(printf '%s' "$AZGOOD" | jq -c '.isEnabled = "true"')]" "$(ace 0)"
azu "reviewers policy with minimumApproverCount a string" "policies answer" "[$(printf '%s' "$AZGOOD" | jq -c '.settings.minimumApproverCount = "1"')]" "$(ace 0)"
azu "permission answer an object" "permission answer" "[$AZGOOD]" '{}'
azu "permission answer an object of lists" "permission answer" "[$AZGOOD]" '{"x":{"acesDictionary":{"d":{"extendedInfo":{"effectiveAllow":0}}}}}'
azu "one permission list readable and one without acesDictionary" "permission answer" "[$AZGOOD]" "$(jq -nc --argjson a "$(ace 0)" '$a + [{"token":"t"}]')"
azu "permission answer null" "permission answer" "[$AZGOOD]" 'null'
azu "permission answer an empty list" "permission answer" "[$AZGOOD]" '[]'
azu "permission list without acesDictionary" "permission answer" "[$AZGOOD]" '[{"token":"t"}]'
azu "permission answer with no entry for the subject" "permission answer" "[$AZGOOD]" '[{"acesDictionary":{},"token":"t"}]'
azu "entry without extendedInfo" "permission answer" "[$AZGOOD]" '[{"acesDictionary":{"d":{"allow":8,"deny":0}}}]'
azu "extendedInfo without effectiveAllow" "permission answer" "[$AZGOOD]" '[{"acesDictionary":{"d":{"extendedInfo":{"inheritedAllow":0}}}}]'
azu "effectiveAllow null" "permission answer" "[$AZGOOD]" '[{"acesDictionary":{"d":{"extendedInfo":{"effectiveAllow":null}}}}]'
azu "effectiveAllow a string" "permission answer" "[$AZGOOD]" '[{"acesDictionary":{"d":{"extendedInfo":{"effectiveAllow":"8"}}}}]'
azu "effectiveAllow negative" "permission answer" "[$AZGOOD]" '[{"acesDictionary":{"d":{"extendedInfo":{"effectiveAllow":-8}}}}]'
azu "effectiveAllow fractional" "permission answer" "[$AZGOOD]" '[{"acesDictionary":{"d":{"extendedInfo":{"effectiveAllow":1.5}}}}]'
azu "one entry readable and one without effectiveAllow" "permission answer" "[$AZGOOD]" '[{"acesDictionary":{"a":{"extendedInfo":{"effectiveAllow":0}},"b":{"allow":8}}}]'

# the repository answer
for spec in "no repository id|id|no repository id" "no project id|project|no project id" "no default branch|defaultBranch|no default branch"; do
  IFS='|' read -r label key why <<<"$spec"
  reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
  az_show "example project" example-repo "$(jq -nc --arg r "$AZRID" --arg p "$AZPID" --arg k "$key" '{id:$r,defaultBranch:"refs/heads/main",project:{id:$p}} | del(.[$k])')"
  run check
  row_is unreadable "$AZR.*$why" "azure repos show with $label: unreadable"
  rc_is 1 "azure repos show with $label: exit 1"
  not_called "^az repos policy list" "azure repos show with $label: nothing is read after it"
done
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_show "example project" example-repo "{\"id\":\"$AZRID\",\"defaultBranch\":null,\"project\":{\"id\":\"$AZPID\"}}"
run check
row_is unreadable "$AZR.*no default branch" "azure an empty repository (defaultBranch null): unreadable"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_show "example project" example-repo "{\"id\":\"$AZRID\",\"defaultBranch\":\"refs/tags/v1\",\"project\":{\"id\":\"$AZPID\"}}"
run check
row_is unreadable "$AZR.*not a branch" "azure a default branch outside refs/heads: unreadable"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_show "example project" example-repo "$(jq -nc --arg r "$AZRID" --arg p "$AZPID" '{id:$r,defaultBranch:"refs/heads/a\nb",project:{id:$p}}')"
run check
row_is unreadable "$AZR.*control characters" "azure a default branch with a control character: unreadable, never printed into a row"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_show "example project" example-repo "$(jq -nc --arg p "$AZPID" '{id:"a\nb",defaultBranch:"refs/heads/main",project:{id:$p}}')"
run check
row_is unreadable "$AZR.*control characters" "azure a repository id with a control character: unreadable"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_show "example project" example-repo "[]"
run check
row_is unreadable "$AZR.*no repository id" "azure a repos show answer that is not an object: unreadable"

# errors from az and from the subject lookup
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
ans az "repos show --org $AZOURL --project example project --repository example-repo --output json" "" 1 "ERROR: TF401019: The Git repository does not exist (HTTP 404)"
run check
row_is unreadable "$AZR.*HTTP 404" "azure repos show fails: unreadable naming the status"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_showok "example project" example-repo; az_pol "example project" "$AZRID" main '[]'
ans az "account show --output json" "" 1 "ERROR: Please run 'az login' to setup account."
run check
row_is unreadable "$AZR.*Please run" "azure account show fails: unreadable naming the reason"
not_called "devops security" "azure account show fails: no permission read without a subject"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_showok "example project" example-repo; az_pol "example project" "$AZRID" main '[]'; az_acct '{"user":{"type":"user"}}'
run check
row_is unreadable "$AZR.*no user name" "azure account show without user.name: unreadable"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_showok "example project" example-repo; az_pol "example project" "$AZRID" main "[$AZGOOD]"; az_acct
ans az "devops security permission show --id $AZNS --subject $AZUSER --token $(az_tok "$AZPID" "$AZRID" main) --org $AZOURL --output json" "" 1 "ERROR: TF400813 (HTTP 403)"
run check
row_is unreadable "$AZR.*HTTP 403" "azure permission show fails: unreadable naming the status"
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_showok "example project" example-repo
ans az "repos policy list --org $AZOURL --project example project --repository-id $AZRID --branch main --output json" "" 1 "ERROR: boom (HTTP 401)"
run check
row_is unreadable "$AZR.*HTTP 401" "azure policy list fails: unreadable naming the status"
# an error text from az is forge-supplied: no control character reaches a row
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
ans az "repos show --org $AZOURL --project example project --repository example-repo --output json" "" 1 "ERROR: bad$(printf '\033')[2J$(printf '\r')login"
run check
row_is unreadable "$AZR.*bad.*login" "azure an error text with control characters: still an unreadable row"
if printf '%s' "$OUT" | grep -q "$(printf '\033')\|$(printf '\r')"; then _fail "azure an error text with control characters: none reaches the output"; else _pass "azure an error text with control characters: none reaches the output"; fi

# the subject is read once per run, a failure of that read too
AZ2() {  # <first repo> <second repo>: two Azure remotes sharing every answer but the name
  reset
  mkrepo "$H/Code/ExampleOrg/aaa" "https://$AZORG@dev.azure.com/$AZORG/Example%20Project/_git/aaa-repo"
  mkrepo "$H/Code/ExampleOrg/zzz" "https://$AZORG@dev.azure.com/$AZORG/Example%20Project/_git/zzz-repo"
}
AZ2
for r in aaa-repo zzz-repo; do az_showok "example project" "$r"; az_pol "example project" "$AZRID" main "[$AZGOOD]"; done
az_acct; az_perm "$AZRID" main "$(ace $AZREALISTIC)"
run check
rows_are ok 2 "azure two repositories: both ok"
if [ "$(grep -c '^az account show' "$CALLS")" -eq 1 ]; then _pass "azure two repositories: account show is called once per run"; else _fail "azure two repositories: account show is called once per run"; fi
AZ2
for r in aaa-repo zzz-repo; do az_showok "example project" "$r"; az_pol "example project" "$AZRID" main "[$AZGOOD]"; done
ans az "account show --output json" "" 1 "ERROR: Please run 'az login' to setup account."
run check
rows_are unreadable 2 "azure two repositories, account show fails: both unreadable"
if [ "$(grep -c '^az account show' "$CALLS")" -eq 1 ]; then _pass "azure two repositories, account show fails: it is not asked again"; else _fail "azure two repositories, account show fails: it is not asked again"; fi

# only a timeout stops the later az calls: an ordinary failure (here HTTP 404) of one repository leaves the next one read
AZ2
ans az "repos show --org $AZOURL --project example project --repository aaa-repo --output json" "" 1 "ERROR: TF401019: The Git repository does not exist (HTTP 404)"
az_showok "example project" zzz-repo; az_pol "example project" "$AZRID" main "[$AZGOOD]"
az_acct; az_perm "$AZRID" main "$(ace $AZREALISTIC)"
run check
row_is unreadable "aaa-repo.*HTTP 404" "azure a failed repos show that is no timeout: the first remote is unreadable naming the failure"
row_is ok "zzz-repo" "azure a failed repos show that is no timeout: the second remote is still read and ok"
if grep -q '^az repos show .*--repository zzz-repo ' "$CALLS"; then _pass "azure a failed repos show that is no timeout: the second repos show is called"; else _fail "azure a failed repos show that is no timeout: the second repos show is called"; fi

# after the first az timeout every later Azure row is unreadable with no further az call
AZ2
ans az "repos show --org $AZOURL --project example project --repository aaa-repo --output json" '{}' "" "" 5
export FORGE_PROTECTION_TIMEOUT=1
run check
unset FORGE_PROTECTION_TIMEOUT
row_is unreadable "aaa-repo.*no answer within 1s" "azure no answer: the first remote is unreadable naming the timeout"
row_is unreadable "zzz-repo.*az did not answer earlier in this run" "azure no answer: the second remote is unreadable without asking"
if [ "$(grep -c '^az repos show' "$CALLS")" -eq 1 ] && [ "$(grep -c . "$CALLS")" -eq 1 ]; then _pass "azure no answer: one az repos show, no other az call"; else _fail "azure no answer: one az repos show, no other az call"; fi
if [ "$SECS" -lt 4 ]; then _pass "azure no answer: two repositories cost one timeout (took ${SECS}s)"; else _fail "azure no answer: two repositories cost one timeout (took ${SECS}s)"; fi
rc_is 1 "azure no answer: exit 1"
AZ2
for r in aaa-repo zzz-repo; do az_showok "example project" "$r"; az_pol "example project" "$AZRID" main "[$AZGOOD]"; done
ans az "account show --output json" "$AZACCT" "" "" 5
export FORGE_PROTECTION_TIMEOUT=1
run check
unset FORGE_PROTECTION_TIMEOUT
row_is unreadable "zzz-repo.*az did not answer earlier in this run" "azure account show gives no answer: the second remote is unreadable without asking"
if [ "$(grep -c '^az repos show' "$CALLS")" -eq 1 ]; then _pass "azure account show gives no answer: the second remote makes no az call"; else _fail "azure account show gives no answer: the second remote makes no az call"; fi
# a timeout of one forge does not stop another
AZ2
mkrepo "$H/Code/ExampleOrg/gh" "$GHURL"; gh_michael "$R"
ans az "repos show --org $AZOURL --project example project --repository aaa-repo --output json" '{}' "" "" 5
export FORGE_PROTECTION_TIMEOUT=1
run check
unset FORGE_PROTECTION_TIMEOUT
row_is ok "github.com/$R" "azure no answer: a GitHub row is still read"

# a path that is not org/project/repo is unreadable and asks az nothing
for spec in "two segments|https://dev.azure.com/$AZORG/Example%20Project" "four segments|https://dev.azure.com/$AZORG/Example%20Project/_git/a/b" "empty project|https://dev.azure.com/$AZORG//_git/r"; do
  reset; mkrepo "$H/Code/ExampleOrg/example-repo" "${spec#*|}"
  run check
  row_is unreadable "dev.azure.com.*not an org/project/repo path" "azure a path with ${spec%%|*}: unreadable"
  if [ -s "$CALLS" ]; then _fail "azure a path with ${spec%%|*}: no az call"; else _pass "azure a path with ${spec%%|*}: no az call"; fi
done

# forge-supplied and origin-supplied values in the printed command: pasted, each must run nothing extra
argv_after() { awk -v k="$1" 'p{print; exit} $0==k{p=1}' "$T/argv"; }
HB="x;touch pwned;y"; HID="i;touch pwned;j"
HP='p`touch pwned`q'; HRP='r$(touch pwned)'
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "https://$AZORG@dev.azure.com/$AZORG/p\`touch%20pwned\`q/_git/r\$(touch%20pwned)"
az_showok "$HP" "$HRP" "$HB" "$HID"
az_pol "$HP" "$HID" "$HB" '[]'
az_acct
ans az "devops security permission show --id $AZNS --subject $AZUSER --token $(az_tok "$AZPID" "$HID" "$HB") --org $AZOURL --output json" "$(ace 0)"
run check
row_is drift "dev.azure.com" "azure hostile project, repo, id and branch: drift row"
eval_remedy "az repos policy approver-count create"
if [ "$EXTRA" -eq 0 ]; then _pass "azure hostile values: pasting the create line runs nothing extra"; else _fail "azure hostile values: pasting the create line runs nothing extra"; fi
for pair in "--project|$HP" "--repository-id|$HID" "--branch|$HB" "--org|$AZOURL"; do
  if [ "$(argv_after "${pair%%|*}")" = "${pair#*|}" ]; then _pass "azure hostile values: the pasted line hands az the exact ${pair%%|*}"; else _fail "azure hostile values: the pasted line hands az the exact ${pair%%|*} (got $(argv_after "${pair%%|*}"))"; fi
done
# the organization comes from the origin too
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "https://dev.azure.com/o\$(touch%20pwned)/p/_git/r"
HORG='https://dev.azure.com/o$(touch pwned)'
ans az "repos show --org $HORG --project p --repository r --output json" "{\"id\":\"$AZRID\",\"defaultBranch\":\"refs/heads/main\",\"project\":{\"id\":\"$AZPID\"}}"
ans az "repos policy list --org $HORG --project p --repository-id $AZRID --branch main --output json" '[]'
az_acct
ans az "devops security permission show --id $AZNS --subject $AZUSER --token $(az_tok "$AZPID" "$AZRID" main) --org $HORG --output json" "$(ace 0)"
run check
eval_remedy "az repos policy approver-count create"
if [ "$EXTRA" -eq 0 ] && [ "$(argv_after --org)" = "$HORG" ]; then _pass "azure hostile organization: pasting the create line runs nothing extra and hands az the exact --org"; else _fail "azure hostile organization: pasting the create line runs nothing extra and hands az the exact --org (got $(argv_after --org))"; fi
# the subject (a note, so a comment) cannot start a command line
HUSER=$(printf 'a@example.com\ntouch pwned')
reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$AZURL"
az_showok "example project" example-repo; az_pol "example project" "$AZRID" main "[$AZGOOD]"
az_acct "$(jq -nc --arg u "$HUSER" '{user:{name:$u}}')"
az_perm "$AZRID" main "$(ace 8)" "$HUSER"
run check
row_is drift "$AZR" "azure a subject with a newline: drift row"
if printf '%s\n' "$OUT" | grep 'touch pwned' | grep -qv '^    # '; then _fail "azure a subject with a newline: every printed line that names it is a comment"; else _pass "azure a subject with a newline: every printed line that names it is a comment"; fi
out_has 'touch pwned' "azure a subject with a newline: the note still names it"

# The printed commands are pasted into zsh, which expands a word that starts with = (to a command path) or ~
# (to a home directory), and with magic_equal_subst also the part after any name=. Each remedy line is run
# under `zsh -f` with the forge CLI a function that records its argv (and the --input body), once with the
# defaults and once with magic_equal_subst: a branch that looks like such an expansion must reach the CLI literally.
command -v zsh >/dev/null 2>&1 || { echo "missing zsh: the zsh paste rows cannot run" >&2; exit 2; }
zsh_remedy() {  # <fixed string selecting the line> [zsh option...] -> $T/argv and $T/body hold what the CLI got
  local line
  line=$(printf '%s\n' "$OUT" | grep -F -- "$1" | head -n 1); shift
  rm -f "$T/argv" "$T/body"
  ZARGV="$T/argv" ZBODY="$T/body" zsh -f "$@" -c '
    rec() { printf "%s\n" "$@" > "$ZARGV"; cat "${@[-1]}" > "$ZBODY" 2>/dev/null; }
    gh() { rec "$@"; }; glab() { rec "$@"; }; az() { rec "$@"; }
    '"$line" >/dev/null 2>&1
}
for ZO in "default options|" "magic_equal_subst|-o magic_equal_subst"; do
  zlabel=${ZO%%|*}; zopts=${ZO#*|}
  for ZB in '=ls' '~root' '=(ls)'; do
    zl="zsh ($zlabel), default branch $ZB"
    reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"
    ans gh "api repos/$R" "$(jq -nc --arg b "$ZB" '{default_branch:$b}')"
    ans gh "api --paginate repos/$R/rules/branches/$(jq -rn --arg b "$ZB" '$b | @uri')?per_page=100" '[]'
    run check
    row_is drift "github.com/$R" "$zl, github: drift row"
    zsh_remedy '"name":"protect-main"' $zopts
    if [ "$(jq -r '.conditions.ref_name.include[0]' "$T/body" 2>/dev/null)" = "refs/heads/$ZB" ]; then _pass "$zl, github: the pasted line hands gh the literal ref"; else _fail "$zl, github: the pasted line hands gh the literal ref (got $(cat "$T/body" 2>/dev/null))"; fi

    glab_case '[]' "$ZB"
    row_is drift "$GLR" "$zl, gitlab: drift row"
    zsh_remedy "--method POST" $zopts
    if grep -qxF -- "name=$ZB" "$T/argv" 2>/dev/null; then _pass "$zl, gitlab: the pasted POST hands glab the literal name"; else _fail "$zl, gitlab: the pasted POST hands glab the literal name (got $(grep name= "$T/argv" 2>/dev/null))"; fi

    glab_case "[$(glrule "$ZB" 0 40 true 10)]" "$ZB"
    row_is drift "$GLR" "$zl, gitlab rule: drift row"
    zsh_remedy "--method PATCH" $zopts
    if [ "$(jq -c . < "$T/body" 2>/dev/null)" = '{"allow_force_push":false}' ]; then _pass "$zl, gitlab rule: the pasted PATCH hands glab the exact JSON body"; else _fail "$zl, gitlab rule: the pasted PATCH hands glab the exact JSON body (got $(cat "$T/body" 2>/dev/null))"; fi

    azure_case '[]' "$(ace 0)" "$ZB"
    row_is drift "$AZR" "$zl, azure: drift row"
    zsh_remedy "az repos policy approver-count create" $zopts
    if [ "$(argv_after --branch)" = "$ZB" ]; then _pass "$zl, azure: the pasted create hands az the literal --branch"; else _fail "$zl, azure: the pasted create hands az the literal --branch (got $(argv_after --branch))"; fi
  done
done

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

reset
mkrepo "$H/Code/depth-one" "https://github.com/depth-owner/depth-one.git"
mkrepo "$H/Code/ExampleOrg/group/depth-three" "https://github.com/depth-owner/depth-three.git"
mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"
mkrepo "$H/Code/ExampleOrg/example-repo/vendor/nested" "https://github.com/nested-owner/nested.git"
mkrepo "$H/Code/depth-one/inner" "https://github.com/nested-owner/inner.git"
mkrepo "$H/Code/ExampleOrg/group/depth-three/deeper" "https://github.com/nested-owner/deeper.git"
mkrepo "$H/Code/ExampleOrg/group/too/deep/beyond" "https://github.com/nested-owner/beyond.git"
gh_michael depth-owner/depth-one; gh_michael depth-owner/depth-three; gh_michael "$R"
run check
row_is ok "depth-owner/depth-one" "walk: a repository directly under Code is read"
row_is ok "depth-owner/depth-three" "walk: a repository three levels under Code is read"
rows_are ok 3 "walk: a repository inside another, or deeper than three levels, gets no row of its own"
out_hasnt "nested-owner" "walk: no nested checkout is read"

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
for v in "repos show --org https://dev.azure.com/example-org --project p --repository r --output json" "repos policy list --org https://dev.azure.com/example-org --project p --repository-id x --branch main --output json" "account show --output json" "devops security permission show --id 2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87 --subject u --token t --org https://dev.azure.com/example-org --output json"; do
  # shellcheck disable=SC2086
  got=$(azr $v)
  if [ "$got" = "0 forge_call az $v" ]; then _pass "az_read allows: $v"; else _fail "az_read allows: $v (got $got)"; fi
done
for v in "repos policy create --id x" "repos policy update --id x" "repos policy approver-count create --org x" "repos delete --id x" "repos create --name x" "repos update --id x" "account set --subscription x" "account get-access-token" "devops security permission update --id x" "devops security permission reset --id x" "pipelines run" "repos showx --id x" "repos policy listx --id x" "account showx --output json" "devops security permission showx --id x" "repos show" "account show" ""; do
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
if grep -q '^az repos show' "$ALLCALLS"; then _pass "no write: the cases made az calls"; else _fail "no write: the cases made az calls"; fi

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
