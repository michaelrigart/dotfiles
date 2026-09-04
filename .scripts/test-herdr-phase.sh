#!/usr/bin/env bash
# Tests phase.sh — the reporter that badges Herdr spaces with where a worktree sits
# between "I'm working on this" and "this is waiting to be merged".
#
# Four properties here are load-bearing and none is visible by reading the script casually:
#
#   1. Reported tokens do NOT survive a Herdr server restart (confirmed against the CLI
#      reference and by session.json carrying no metadata field). The badges therefore only
#      exist because something replays them, so the script must be safely re-runnable and
#      must never depend on state it previously reported.
#   2. A workspace accepts sequenced token reports from at most 32 DISTINCT sources for its
#      lifetime, and clearing or expiry does not release a slot. Every report must therefore
#      use the one stable --source; a per-run source id would exhaust a long-lived workspace.
#   3. Exactly one of the four phase tokens may be set at a time, and the other three must be
#      explicitly cleared. Herdr keeps a token until told otherwise, so a space that moves
#      review -> merged would otherwise render both icons at once.
#   4. The icons are Nerd Font private-use codepoints. A wrong codepoint renders as tofu in
#      the sidebar and nothing anywhere reports an error, so the exact bytes are pinned here.
#
# `git` is real throughout — dirty trees, unpushed commits and linked worktrees have enough
# semantics that stubbing them would test the stub. `herdr` and `glab` are stubbed: one to
# capture what would be reported, the other to make MR state deterministic and to count calls,
# which is how the per-repo caching is proved.
#
# Run: bash .scripts/test-herdr-phase.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="$ROOT/dot_config/herdr/executable_phase.sh"

pass=0; fail=0
_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }
check() { if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 (got '$1', want '$2')"; fi; }

if [ ! -r "$PHASE" ]; then
  echo "FATAL: $PHASE not found — every assertion below would pass vacuously."
  echo "RESULT: 0 passed, 1 failed"
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/herdr-phase-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# The five icons, as bytes. Written as escapes rather than literals because this file travels
# through tools that silently drop private-use characters.
ICON_BRANCH=$(printf '\xee\xb1\xaf')   # U+EC6F cod-git_branch
ICON_MR=$(printf '\xee\xa9\xa4')       # U+EA64 cod-git_pull_request
ICON_DRAFT=$(printf '\xee\xaf\x9b')    # U+EBDB cod-git_pull_request_draft
ICON_MERGE=$(printf '\xee\xab\xbe')    # U+EAFE cod-git_merge
ICON_FLAG=$(printf '\xee\xb0\xbf')     # U+EC3F cod-flag

# ---------------------------------------------------------------- git fixture
# One bare origin, one main checkout, and a linked worktree per phase we want to exercise.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
q() { "$@" >/dev/null 2>&1; }

ORIGIN="$T/origin.git"
REPO="$T/repo"
q git init --bare -b main "$ORIGIN"
q git clone "$ORIGIN" "$REPO"
echo base > "$REPO/f"
q git -C "$REPO" add f
q git -C "$REPO" commit -m base
q git -C "$REPO" push -u origin main

# Each worktree gets a commit so it differs from main; whether it is pushed is what varies.
mkwt() { # mkwt <slug> <branch> <pushed:0|1>
  local dest="$T/repo-$1"
  q git -C "$REPO" worktree add -b "$2" "$dest" main
  echo "$1" > "$dest/f"
  q git -C "$dest" add f
  q git -C "$dest" commit -m "$1"
  [ "$3" = "1" ] && q git -C "$dest" push -u origin "$2"
  return 0
}
mkwt dirty    feature/dirty    1
mkwt unpushed feature/unpushed 0
mkwt review   feature/review   1
mkwt draft    feature/draft    1
mkwt merged   feature/merged   1
mkwt nomr     feature/nomr     1
echo scratch >> "$T/repo-dirty/f"          # the one uncommitted change in the fixture

# Rewritten only now that every push is done: the script never fetches, it reads the
# remote-tracking refs that already exist, so a URL it cannot reach is realistic and safe.
q git -C "$REPO" remote set-url origin git@gitlab.com:test/proj.git

# ------------------------------------------------------------------ stubs
BIN="$T/bin"; mkdir -p "$BIN"
CALLS="$T/calls"; : > "$CALLS"

cat > "$BIN/herdr" <<'H'
#!/usr/bin/env bash
echo "herdr $*" >> "$CALLS"
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "list" ]; then cat "$WSJSON"; fi
exit 0
H

cat > "$BIN/glab" <<'G'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
cat "$MRJSON"
exit 0
G
chmod 755 "$BIN/herdr" "$BIN/glab"

WSJSON="$T/ws.json"
cat > "$WSJSON" <<J
{"id":"x","result":{"type":"workspace_list","workspaces":[
 {"workspace_id":"w1","label":"proj","worktree":{"checkout_path":"$REPO","is_linked_worktree":false,"repo_root":"$REPO"}},
 {"workspace_id":"w2","label":"dirty","worktree":{"checkout_path":"$T/repo-dirty","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w3","label":"unpushed","worktree":{"checkout_path":"$T/repo-unpushed","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w4","label":"review","worktree":{"checkout_path":"$T/repo-review","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w5","label":"draft","worktree":{"checkout_path":"$T/repo-draft","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w6","label":"merged","worktree":{"checkout_path":"$T/repo-merged","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w7","label":"nomr","worktree":{"checkout_path":"$T/repo-nomr","is_linked_worktree":true,"repo_root":"$REPO"}}
]}}
J

MRJSON="$T/mr.json"
cat > "$MRJSON" <<'J'
[{"iid":10,"source_branch":"feature/review","state":"opened","draft":false},
 {"iid":11,"source_branch":"feature/draft","state":"opened","draft":true},
 {"iid":12,"source_branch":"feature/merged","state":"merged","draft":false}]
J
export WSJSON MRJSON CALLS

run() { # run <args...> -> stdout+stderr, sets RC; each run starts a clean call log
  : > "$CALLS"
  OUT=$(PATH="$BIN:$PATH" \
        HERDR_PHASE_CACHE_DIR="$T/cache" \
        HERDR_PHASE_STATE_DIR="$T/state" \
        HERDR_PHASE_TTL="${TTL:-120}" \
        bash "$PHASE" "$@" 2>&1); RC=$?
}

# The report line for one workspace, so assertions read as "what did w4 get told".
report_for() { grep -E "^herdr workspace report-metadata $1 " "$CALLS" | head -1; }

echo "A. usage"
run --help
check "$RC" "0" "--help exits 0"
case "$OUT" in *refresh*) _pass "--help documents refresh";; *) _fail "--help documents refresh";; esac
case "$OUT" in *pin*) _pass "--help documents pin";; *) _fail "--help documents pin";; esac
run bogus-subcommand
[ "$RC" -ne 0 ] && _pass "unknown subcommand is an error" || _fail "unknown subcommand is an error"

echo
echo "B. phase derivation"
run refresh
check "$RC" "0" "refresh exits 0"

case "$(report_for w2)" in *"--token active=$ICON_BRANCH"*) _pass "dirty worktree -> active";;
  *) _fail "dirty worktree -> active (got: $(report_for w2))";; esac
case "$(report_for w3)" in *"--token active=$ICON_BRANCH"*) _pass "unpushed commits -> active";;
  *) _fail "unpushed commits -> active (got: $(report_for w3))";; esac
case "$(report_for w4)" in *"--token review=$ICON_MR !10"*) _pass "open ready MR -> review, carries !10";;
  *) _fail "open ready MR -> review, carries !10 (got: $(report_for w4))";; esac
case "$(report_for w5)" in *"--token active=$ICON_DRAFT"*) _pass "open draft MR -> active, draft icon";;
  *) _fail "open draft MR -> active, draft icon (got: $(report_for w5))";; esac
case "$(report_for w6)" in *"--token merged=$ICON_MERGE !12"*) _pass "merged MR -> merged, carries !12";;
  *) _fail "merged MR -> merged, carries !12 (got: $(report_for w6))";; esac

# Clean, pushed, no MR is the "nothing to say" case: every token cleared, none set.
NOMR="$(report_for w7)"
case "$NOMR" in *"--token "*) _fail "clean branch with no MR sets no token (got: $NOMR)";;
  *) _pass "clean branch with no MR sets no token";; esac
case "$NOMR" in *"--clear-token active"*) _pass "clean branch with no MR clears active";;
  *) _fail "clean branch with no MR clears active";; esac

# The main checkout is dirty in this fixture (worktrees leave no trace, but real ones do);
# badging it would mark every repo permanently active.
[ -z "$(report_for w1)" ] && _pass "main checkout is never badged" \
  || _fail "main checkout is never badged (got: $(report_for w1))"

echo
echo "C. every report is well-formed"
# One stable source: a per-run id would burn through the 32-source budget over a long session.
BADSRC=$(grep -c -E "^herdr workspace report-metadata [^ ]+ --source herdr-phase( |$)" "$CALLS")
TOTAL=$(grep -c -E "^herdr workspace report-metadata " "$CALLS")
check "$BADSRC" "$TOTAL" "all $TOTAL reports use --source herdr-phase"

# Herdr keeps a token until told otherwise, so the three unused tokens must be cleared on
# every report or a space that changes phase renders two icons at once.
missing=0
for w in w2 w3 w4 w5 w6 w7; do
  line="$(report_for $w)"
  set_count=$(printf '%s\n' "$line" | grep -o -- "--token " | wc -l | tr -d ' ')
  clear_count=$(printf '%s\n' "$line" | grep -o -- "--clear-token " | wc -l | tr -d ' ')
  [ $((set_count + clear_count)) -eq 4 ] || missing=$((missing + 1))
done
check "$missing" "0" "each report accounts for all four phase tokens"

echo
echo "D. MR lookups are cached per repo"
rm -rf "$T/cache"   # section B already warmed it; these assertions count from cold
run refresh
check "$(grep -c '^glab ' "$CALLS")" "1" "one glab call covers all six worktrees of a repo"

run refresh
check "$(grep -c '^glab ' "$CALLS")" "0" "second refresh inside the TTL makes no glab call"

run refresh --force
check "$(grep -c '^glab ' "$CALLS")" "1" "--force bypasses the cache"

TTL=0 run refresh
check "$(grep -c '^glab ' "$CALLS")" "1" "an expired cache is refetched"
unset TTL

echo
echo "E. a pin overrides what git says"
run pin --workspace w2 parked
check "$RC" "0" "pin exits 0"
run refresh
case "$(report_for w2)" in *"--token parked=$ICON_FLAG"*) _pass "pinned space reports parked, not its git state";;
  *) _fail "pinned space reports parked, not its git state (got: $(report_for w2))";; esac
case "$(report_for w4)" in *"--token review=$ICON_MR !10"*) _pass "pinning one space leaves the others derived";;
  *) _fail "pinning one space leaves the others derived";; esac

run unpin --workspace w2
check "$RC" "0" "unpin exits 0"
run refresh
case "$(report_for w2)" in *"--token active=$ICON_BRANCH"*) _pass "unpin restores the derived phase";;
  *) _fail "unpin restores the derived phase (got: $(report_for w2))";; esac

# A pin has to outlive the server restart that wipes the reported tokens, so it belongs on
# disk rather than in Herdr.
run pin --workspace w4 parked
[ -n "$(find "$T/state" -type f 2>/dev/null)" ] && _pass "a pin is persisted outside Herdr" \
  || _fail "a pin is persisted outside Herdr"
run unpin --workspace w4

echo
echo "F. a single space can be refreshed on its own"
run refresh --workspace w4
check "$(grep -c -E '^herdr workspace report-metadata ' "$CALLS")" "1" "refresh --workspace reports once"
case "$(report_for w4)" in *"--token review="*) _pass "refresh --workspace reports the right space";;
  *) _fail "refresh --workspace reports the right space";; esac

echo
echo "G. a repo Herdr cannot resolve to GitLab degrades to git-only"
q git -C "$REPO" remote set-url origin git@github.com:test/proj.git
run refresh
check "$(grep -c '^glab ' "$CALLS")" "0" "no glab call for a non-GitLab remote"
case "$(report_for w2)" in *"--token active=$ICON_BRANCH"*) _pass "git-derived phases still reported";;
  *) _fail "git-derived phases still reported (got: $(report_for w2))";; esac
# feature/review has an open MR upstream, but without GitLab the script cannot know that;
# it is clean and pushed, so it must fall through to saying nothing rather than guessing.
case "$(report_for w4)" in *"--token "*) _fail "no MR state means no review badge";;
  *) _pass "no MR state means no review badge";; esac
q git -C "$REPO" remote set-url origin git@gitlab.com:test/proj.git

echo
echo "H. failure of the MR lookup is not failure of the refresh"
cat > "$BIN/glab" <<'G'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
echo "error: could not reach gitlab.com" >&2
exit 1
G
chmod 755 "$BIN/glab"
rm -rf "$T/cache"
run refresh
check "$RC" "0" "refresh survives glab failing"
case "$(report_for w2)" in *"--token active=$ICON_BRANCH"*) _pass "git-derived phases survive glab failing";;
  *) _fail "git-derived phases survive glab failing (got: $(report_for w2))";; esac

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
