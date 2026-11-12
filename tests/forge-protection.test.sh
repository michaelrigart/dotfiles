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
out_has '"include":["refs/heads/main"]' "github one merged ruleset: protect-main includes the default branch"
rc_is 1 "github one merged ruleset: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
gh_rs "$R" 2 "{\"id\":2,\"enforcement\":\"active\",\"bypass_actors\":[$BYADMIN,{\"actor_type\":\"User\",\"actor_id\":42,\"bypass_mode\":\"always\"}],\"current_user_can_bypass\":\"always\"}"
run check
row_is drift "github.com/$R" "github an extra bypass actor: drift row"
rc_is 1 "github an extra bypass actor: exit 1"

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "$GHURL"; gh_michael "$R"
gh_rs "$R" 1 '{"id":1,"enforcement":"evaluate","bypass_actors":[],"current_user_can_bypass":"never"}'
run check
row_is drift "github.com/$R" "github ruleset in evaluate mode: drift row"
out_has "# in the UI: https://github.com/$R/rules/1: Enforcement Active, bypass list none" "github ruleset in evaluate mode: the UI note"
rc_is 1 "github ruleset in evaluate mode: exit 1"

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
mkdir -p "$H/Code/ExampleOrg/not-a-checkout"
gh_michael "$R"; gh_michael example-owner/dotfiles
run check
rows_are ok 2 "dedupe: two checkouts with one origin give one row, the dotfiles another"
out_has "2 repositories: 2 ok, 0 drift, 0 unreadable, 0 excepted; 1 checkouts without origin skipped" "no origin: skipped and counted, a plain directory is neither"
first=$(printf '%s\n' "$OUT" | grep '^ok ' | head -n 1)
case "$first" in *"github.com/example-owner/dotfiles"*) _pass "rows are in sorted order" ;; *) _fail "rows are in sorted order" ;; esac

reset; mkrepo "$H/Code/ExampleOrg/example-repo" "https://github.com/$R.git" "git@gh-alias:$R.git"
run check
row_is unreadable "gh-alias/$R" "the remote is where pushes go (pushurl wins over url)"

echo "D. normalize_remote"
norm() { (. /dev/stdin <<<"$(sed -n '/^normalize_remote()/,/^}/p' "$SCRIPT")"; normalize_remote "$1"); }
for pair in \
  "git@github.com:Example-Owner/Example-Repo.git|github.com/example-owner/example-repo" \
  "https://user@github.com:443/example-owner/example-repo/|github.com/example-owner/example-repo" \
  "ssh://git@gitlab.com/example-group/example-sub/example-repo.git|gitlab.com/example-group/example-sub/example-repo" \
  "git@ssh.dev.azure.com:v3/example-org/Example%20Project/example-repo|dev.azure.com/example-org/example project/example-repo" \
  "example-org@vs-ssh.visualstudio.com:v3/example-org/Example%20Project/example-repo|dev.azure.com/example-org/example project/example-repo" \
  "https://example-org@dev.azure.com/example-org/Example%20Project/_git/example-repo|dev.azure.com/example-org/example project/example-repo" \
  "https://example-org.visualstudio.com/Example%20Project/_git/example-repo|dev.azure.com/example-org/example project/example-repo" ; do
  got=$(norm "${pair%%|*}")
  if [ "$got" = "${pair#*|}" ]; then _pass "normalize ${pair%%|*}"; else _fail "normalize ${pair%%|*} (got $got)"; fi
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
