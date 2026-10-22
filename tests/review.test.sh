#!/usr/bin/env bash
# Tests for dot_local/bin/executable_review: it runs a headless claude -p session in the
# current repository on a Console API key, refuses --fix outside a clean feature-branch
# worktree, aborts unless claude reports the API key as its credential, and writes a report.
# op, claude and osascript are stubs on a temp PATH; nothing real is called.
#
#   ./tests/review.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
RV="$SRC/dot_local/bin/executable_review"
[ -f "$RV" ] || { echo "missing script under test: $RV" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/review.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"

KEY=sk-ant-test-SECRETKEY123
SD="$T/stub"; mkdir -p "$SD/bin"
export STUB_DIR="$SD" PATH="$SD/bin:$PATH"
export ANTHROPIC_AUTH_TOKEN=leak-token ANTHROPIC_BASE_URL=http://leak.invalid CLAUDE_CODE_USE_BEDROCK=1

cat > "$SD/bin/op" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/op.args"
[ "${STUB_OP_FAIL:-}" = 1 ] && exit 1
[ "${STUB_OP_EMPTY:-}" = 1 ] && exit 0
printf '%s\n' "${STUB_OP_KEY:-sk-ant-test-SECRETKEY123}"
EOF
cat > "$SD/bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/osascript.args"
EOF
cat > "$SD/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_DIR/claude.argv"
pwd -P > "$STUB_DIR/claude.cwd"
for v in ANTHROPIC_API_KEY CLAUDE_CODE_SUBPROCESS_ENV_SCRUB ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_BEDROCK; do
  if [ -n "${!v+x}" ]; then printf '%s=%s\n' "$v" "${!v}"; else printf '%s=<unset>\n' "$v"; fi
done > "$STUB_DIR/claude.env"
hooks() {
  printf '%s\n' '{"type":"system","subtype":"hook_started","hook_name":"SessionStart"}'
  printf '%s\n' '{"type":"system","subtype":"hook_response","hook_name":"SessionStart"}'
  printf '%s\n' 'this line is not json'
}
init() { printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"apiKeySource\":\"$1\",\"session_id\":\"sess-123\",\"model\":\"claude-opus-5-5\",\"permissionMode\":\"auto\"}"; }
asst() { printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the code"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la\nsecond line"}}]}}'; }
case "${STUB_CLAUDE_MODE:-ok}" in
  ok)
    hooks; init ANTHROPIC_API_KEY; asst
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"# Report\n\nOpened https://gitlab.example.com/g/r/-/merge_requests/7 for review","total_cost_usd":1.234,"session_id":"sess-123"}' ;;
  error)
    hooks; init ANTHROPIC_API_KEY
    printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"result":"Credit balance is too low","total_cost_usd":0,"session_id":"sess-123"}' ;;
  nores)
    hooks; init ANTHROPIC_API_KEY; asst; echo "boom" >&2; exit 3 ;;
  badsource)
    hooks; init none; exec sleep 5 ;;
  noinit)
    hooks; asst ;;
  hang)
    hooks; init ANTHROPIC_API_KEY; asst; exec sleep 30 ;;
esac
EOF
chmod 755 "$SD/bin/op" "$SD/bin/osascript" "$SD/bin/claude" "$RV"

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
git -C "$T/seed" commit -q --allow-empty -m init
git -C "$T/seed" push -q origin main 2>/dev/null
git clone -q "$T/origin.git" "$T/Acme.Portal" 2>/dev/null
git -C "$T/Acme.Portal" worktree add -q -b feat "$T/Acme.Portal-feat"
MAIN="$T/Acme.Portal"; WT="$T/Acme.Portal-feat"
git -C "$MAIN" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null \
  || { echo "fixture broken: origin/HEAD is not set" >&2; exit 2; }
mkdir -p "$T/norepo"

n=0
# run <dir> <claude mode> [args...]: runs the script there with fresh state; sets rc, STATE, DIR.
run() {
  local d=$1; STUB_CLAUDE_MODE=$2; shift 2
  export STUB_CLAUDE_MODE
  n=$((n + 1)); STATE="$T/state/$n"; DIR="$STATE/review/acme-portal"; export XDG_STATE_HOME="$STATE"
  rm -f "$SD"/op.args "$SD"/osascript.args "$SD"/claude.argv "$SD"/claude.cwd "$SD"/claude.env
  ( cd "$d" && "$RV" "$@" ) >"$T/out" 2>"$T/err"; rc=$?
}
# again <dir> <claude mode> [args...]: like run, but keeps the current state directory.
again() {
  local d=$1; STUB_CLAUDE_MODE=$2; shift 2
  export STUB_CLAUDE_MODE
  rm -f "$SD"/op.args "$SD"/osascript.args "$SD"/claude.argv "$SD"/claude.cwd "$SD"/claude.env
  ( cd "$d" && "$RV" "$@" ) >"$T/out" 2>"$T/err"; rc=$?
}
rc_is() { [ "$rc" = "$1" ]; }
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }
absent() { [ ! -e "$1" ]; }
file_of() { ls "$DIR"/*"$1" 2>/dev/null | head -n 1; }
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
arg_after() { grep -x -A1 -- "$1" "$SD/claude.argv" | tail -n 1; }
ok() {
  local l=$1; shift
  if "$@"; then _pass "$l"; else _fail "$l" "rc=$rc out=$(head -c 400 "$T/out") err=$(head -c 400 "$T/err")"; fi
}

run "$MAIN" ok bogus;               ok "an unknown word is a usage error (exit 2)" rc_is 2
ok "the usage goes to stderr" has "$T/err" "usage: review"
run "$MAIN" ok --nope;              ok "an unknown flag is a usage error (exit 2)" rc_is 2
run "$MAIN" ok --budget abc;        ok "a non-numeric budget is a usage error (exit 2)" rc_is 2
run "$MAIN" ok --budget 0;          ok "a zero budget is a usage error (exit 2)" rc_is 2
run "$MAIN" ok --budget -5;         ok "a negative budget is a usage error (exit 2)" rc_is 2
run "$MAIN" ok --budget;            ok "--budget without a value is a usage error (exit 2)" rc_is 2
ok "bad arguments never reach op" absent "$SD/op.args"
run "$MAIN" ok --help;              ok "--help exits 0" rc_is 0
ok "--help prints the usage on stdout" has "$T/out" "usage: review"
run "$T/norepo" ok;                 ok "outside a git work tree exits 2" rc_is 2
ok "outside a git work tree says so" has "$T/err" "not inside a git work tree"
ok "outside a git work tree op is not called" absent "$SD/op.args"

run "$MAIN" ok
ok "the main checkout run completes (exit 0)" rc_is 0
ok "the key ref is the one fixed review key" has "$SD/op.args" "read op://Private/cc-review-api-key/credential"
ok "the report is named by stamp and label" test -n "$(file_of -general.md)"
REPORT=$(file_of -general.md)
ok "report heading has repo name, label and mode" has "$REPORT" "# review: Acme.Portal — general (review)"
ok "report status is completed" has "$REPORT" "- Status: completed"
ok "report cost is formatted to cents" has "$REPORT" "- Cost: \$1.23"
ok "report names the session" has "$REPORT" "claude --resume sess-123"
ok "stdout names the log at the start" has "$T/out" "log: $DIR/"
ok "report carries the result text" has "$REPORT" "# Report"
ok "report names the branch and sha" has "$REPORT" "- Branch: main (at $(git -C "$MAIN" rev-parse --short HEAD))"
ok "stdout shows the rendered text" has "$T/out" "Looking at the code"
ok "stdout shows the tool summary" has "$T/out" "→ Bash: ls -la"
ok "a tool summary is the first line only" lacks "$T/out" "second line"
ok "stdout shows the merge request URL" has "$T/out" "https://gitlab.example.com/g/r/-/merge_requests/7"
ok "the log holds the rendered progress" has "$(file_of -general.log)" "Looking at the code"
ok "the jsonl holds the raw stream including non-JSON lines" has "$(file_of -general.jsonl)" "this line is not json"
ok "osascript is called with the merge request URL" has "$SD/osascript.args" "merge_requests/7"
ok "osascript names the repo and label" has "$SD/osascript.args" "Acme.Portal general: completed, \$1.23"
ok "an empty .err file is removed" test -z "$(file_of -general.err)"
ok "the report is mode 600" test "$(mode_of "$REPORT")" = 600
ok "the log is mode 600" test "$(mode_of "$(file_of -general.log)")" = 600
ok "the jsonl is mode 600" test "$(mode_of "$(file_of -general.jsonl)")" = 600

ok "claude gets -p" has "$SD/claude.argv" "-p"
ok "claude gets the auto permission mode" test "$(arg_after --permission-mode)" = auto
ok "claude gets the opus model" test "$(arg_after --model)" = opus
ok "claude gets stream-json output" test "$(arg_after --output-format)" = stream-json
ok "claude gets --verbose" has "$SD/claude.argv" "--verbose"
ok "the review budget defaults to 20" test "$(arg_after --max-budget-usd)" = 20
ok "claude runs in the repository top" test "$(cat "$SD/claude.cwd")" = "$(cd "$MAIN" && pwd -P)"
ok "claude gets the API key" has "$SD/claude.env" "ANTHROPIC_API_KEY=$KEY"
ok "claude gets the env scrub flag" has "$SD/claude.env" "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1"
ok "ANTHROPIC_AUTH_TOKEN is removed" has "$SD/claude.env" "ANTHROPIC_AUTH_TOKEN=<unset>"
ok "ANTHROPIC_BASE_URL is removed" has "$SD/claude.env" "ANTHROPIC_BASE_URL=<unset>"
ok "CLAUDE_CODE_USE_BEDROCK is removed" has "$SD/claude.env" "CLAUDE_CODE_USE_BEDROCK=<unset>"
ok "the key is not in claude's argv" lacks "$SD/claude.argv" "$KEY"
ok "the key is not on stdout" lacks "$T/out" "$KEY"
ok "the key is not on stderr" lacks "$T/err" "$KEY"
ok "the key is in no file under XDG_STATE_HOME" test -z "$(grep -rlF -- "$KEY" "$STATE")"
ok "the review prompt forbids changes" has "$SD/claude.argv" "Do not modify any files"
ok "the review prompt names the focus" has "$SD/claude.argv" "general quality: correctness bugs"
ok "the prompt names the branch" has "$SD/claude.argv" "on branch main."

run "$WT" ok
ok "the linked worktree run completes (exit 0)" rc_is 0
ok "the key ref is the same fixed key in a linked worktree" has "$SD/op.args" "read op://Private/cc-review-api-key/credential"
ok "the linked worktree report is filed under the main repository slug" test -n "$(file_of -general.md)"
ok "the linked worktree heading uses the main repository name" has "$(file_of -general.md)" "# review: Acme.Portal — general (review)"
ok "claude runs in the linked worktree" test "$(cat "$SD/claude.cwd")" = "$(cd "$WT" && pwd -P)"

REVIEW_OP_REF=op://Other/thing/credential run "$MAIN" ok
ok "REVIEW_OP_REF overrides the key ref" has "$SD/op.args" "read op://Other/thing/credential"
STUB_OP_FAIL=1 run "$MAIN" ok
ok "an op failure exits 1" rc_is 1
ok "an op failure names the ref" has "$T/err" "could not read the API key from op://Private/cc-review-api-key/credential"
ok "an op failure never starts claude" absent "$SD/claude.argv"
STUB_OP_EMPTY=1 run "$MAIN" ok
ok "an empty key exits 1" rc_is 1
ok "an empty key never starts claude" absent "$SD/claude.argv"

run "$MAIN" ok security --budget 7.5 -- check the billing flow carefully
ok "a custom budget reaches claude" test "$(arg_after --max-budget-usd)" = 7.5
ok "extra instructions reach the prompt" has "$SD/claude.argv" "Additional instructions: check the billing flow carefully"
ok "the security focus text is in the prompt" has "$SD/claude.argv" "security: authentication and authorisation"
run "$MAIN" ok performance security
ok "the focus label is in canonical order" test -n "$(file_of -security+performance.md)"
ok "both focus texts are joined with a semicolon" has "$SD/claude.argv" "dependency risk; performance: N+1 queries"
run "$MAIN" ok --last --list;       ok "--last with --list is a usage error (exit 2)" rc_is 2
run "$MAIN" ok --last general;      ok "--last with another word is a usage error (exit 2)" rc_is 2
run "$MAIN" ok --list --fix;        ok "--list with --fix is a usage error (exit 2)" rc_is 2
run "$MAIN" ok --last --budget 5;   ok "--last with --budget is a usage error (exit 2)" rc_is 2
run "$MAIN" ok --list -- more;      ok "--list with -- extras is a usage error (exit 2)" rc_is 2
ok "the --last combination error shows the usage" has "$T/err" "usage: review"

run "$MAIN" ok --last;              ok "--last with no reports exits 1" rc_is 1
ok "--last with no reports names the repository" has "$T/err" "review: no reports for Acme.Portal"
ok "--last with no reports prints nothing on stdout" test ! -s "$T/out"
run "$MAIN" ok --list;              ok "--list with no reports exits 1" rc_is 1
ok "--list with no reports names the repository" has "$T/err" "review: no reports for Acme.Portal"
ok "--last and --list never call op or claude without reports" absent "$SD/op.args"

run "$MAIN" ok
FIRST=$(file_of -general.md)
sleep 1
again "$MAIN" error security
SECOND=$(file_of -security.md)
ok "the two runs filed two reports" test -n "$FIRST" -a -n "$SECOND"
again "$MAIN" ok --last
ok "--last exits 0" rc_is 0
ok "--last prints the newer report's absolute path" test "$(cat "$T/out")" = "$SECOND"
ok "--last never calls op" absent "$SD/op.args"
ok "--last never calls claude" absent "$SD/claude.argv"
again "$MAIN" ok --list
ok "--list exits 0" rc_is 0
ok "--list prints one line per report" test "$(wc -l < "$T/out" | tr -d ' ')" = 2
ok "--list puts the newer report first" test "$(head -n 1 "$T/out" | awk '{print $NF}')" = "$SECOND"
ok "--list puts the older report last" test "$(tail -n 1 "$T/out" | awk '{print $NF}')" = "$FIRST"
ok "--list shows a stamp, label, status and cost for a stopped run" \
  grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}  security  stopped: Credit balance is too low  \\\$0\\.00  $SECOND\$" "$T/out"
ok "--list shows a stamp, label, status and cost for a completed run" \
  grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}  general  completed  \\\$1\\.23  $FIRST\$" "$T/out"
ok "--list never calls op" absent "$SD/op.args"
ok "--list never calls claude" absent "$SD/claude.argv"
again "$WT" ok --last
ok "--last works from the linked worktree" test "$(cat "$T/out")" = "$SECOND"
again "$WT" ok --list
ok "--list works from the linked worktree" test "$(wc -l < "$T/out" | tr -d ' ')" = 2
ok "--last and --list in the worktree never call op" absent "$SD/op.args"
printf '# stub\n' > "$DIR/2026-01-01-000000-general-fix.md"
again "$WT" ok --list
ok "--list shows ? for a missing status and cost" has "$T/out" "general-fix  ?  ?  $DIR/2026-01-01-000000-general-fix.md"
again "$WT" ok --fix --last
ok "--last with --fix is a usage error before the --fix refusals" has "$T/err" "take no other argument"

run "$MAIN" ok general general security
ok "duplicate focus words are ignored" test -n "$(file_of -security+general.md)"

run "$WT" ok --fix
ok "--fix in a clean linked worktree runs (exit 0)" rc_is 0
ok "--fix files are named with -fix" test -n "$(file_of -general-fix.md)"
ok "--fix heading says fix" has "$(file_of -general-fix.md)" "# review: Acme.Portal — general (fix)"
ok "the fix budget defaults to 40" test "$(arg_after --max-budget-usd)" = 40
ok "the fix prompt has the Needs Michael section" has "$SD/claude.argv" "Needs Michael"
ok "the fix prompt forbids merging" has "$SD/claude.argv" "Never merge"
ok "claude runs in the worktree for --fix" test "$(cat "$SD/claude.cwd")" = "$(cd "$WT" && pwd -P)"
run "$WT" ok --fix --budget 12
ok "--budget overrides the fix default" test "$(arg_after --max-budget-usd)" = 12

run "$MAIN" ok --fix
ok "--fix is refused in the main checkout (exit 2)" rc_is 2
ok "--fix in the main checkout points to wt" has "$T/err" "wt worktree"
ok "a refused --fix never calls op" absent "$SD/op.args"
ok "a refused --fix never calls claude" absent "$SD/claude.argv"
printf 'x\n' > "$WT/untracked.txt"
run "$WT" ok --fix
ok "--fix is refused with an untracked file (exit 2)" rc_is 2
ok "a dirty --fix never calls op" absent "$SD/op.args"
rm -f "$WT/untracked.txt"
git -C "$MAIN" worktree add -q --detach "$T/Acme.Portal-det"
run "$T/Acme.Portal-det" ok --fix
ok "--fix is refused on a detached HEAD (exit 2)" rc_is 2
ok "a detached --fix never calls op" absent "$SD/op.args"
git -C "$MAIN" checkout -q --detach
git -C "$MAIN" worktree add -q "$T/Acme.Portal-main" main
run "$T/Acme.Portal-main" ok --fix
ok "--fix is refused on the default branch (exit 2)" rc_is 2
ok "a default-branch --fix never calls op" absent "$SD/op.args"
ok "a default-branch --fix never calls claude" absent "$SD/claude.argv"

run "$WT" error
ok "a result with is_error exits 1" rc_is 1
ok "the stopped status carries the first result line" has "$(file_of -general.md)" "Status: stopped: Credit balance is too low"
ok "a zero cost is reported" has "$(file_of -general.md)" "- Cost: \$0.00"
run "$WT" nores
ok "no result exits 1" rc_is 1
ok "the incomplete status carries the exit code" has "$(file_of -general.md)" "Status: incomplete: Claude exited (code 3) without a result"
ok "an unknown cost is reported as unknown" has "$(file_of -general.md)" "- Cost: unknown"
ok "a non-empty .err file is kept" has "$(file_of -general.err)" "boom"
run "$WT" noinit
ok "an event before init aborts (exit 1)" rc_is 1
ok "the no-init status says so" has "$(file_of -general.md)" "Status: aborted: no credential check before the first model call"

start=$SECONDS
run "$WT" badsource
elapsed=$((SECONDS - start))
ok "a wrong credential source exits 1" rc_is 1
ok "the wrong source status names it" has "$(file_of -general.md)" "Status: aborted: Claude would have used none, not the API key"
ok "the wrong source returns before claude's sleep ends" test "$elapsed" -lt 4
ok "the wrong source never reaches the model output" lacks "$T/out" "Looking at the code"

STUB_CLAUDE_MODE=hang
n=$((n + 1)); STATE="$T/state/$n"; DIR="$STATE/review/acme-portal"; export XDG_STATE_HOME="$STATE"
rm -f "$SD/claude.argv"
( cd "$WT" && exec "$RV" ) >"$T/out" 2>"$T/err" &
rpid=$!
for _ in $(seq 60); do grep -qF "Looking at the code" "$T/out" 2>/dev/null && break; sleep 0.1; done
start=$SECONDS
kill -TERM "$rpid" 2>/dev/null
wait "$rpid"; rc=$?
elapsed=$((SECONDS - start))
ok "a TERM stops the run with exit 1" rc_is 1
ok "a TERM is reported as interrupted" has "$(file_of -general.md)" "Status: interrupted"
ok "a TERM returns promptly" test "$elapsed" -lt 10

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
