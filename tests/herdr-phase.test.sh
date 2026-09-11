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
# Run: ./tests/herdr-phase.test.sh
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
# Isolate from global config, the way wt-functions does. The fixture inherited
# commit.gpgsign=true and signed through the 1Password agent, so whenever that agent's
# authorization lapsed every fixture commit failed, `git worktree add` had no base to
# branch from, and the suite reported 18 phase-derivation failures with empty output —
# a dead signing key wearing the costume of a broken phase script.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
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
# The two shapes a branch under review actually has while you are still working on it. An open
# MR is the one fact that says someone else is waiting, and it does not stop being true because
# you opened a file. Measured 2026-09-11 against the live session: curato-issue-98 sat on
# `active` with MR !120 open because of a single untracked probe file, and curato-issue-91
# because of two unpushed commits — which is the "the badge disappeared while I worked" report.
mkwt dirtyreview feature/dirty-review 1
mkwt aheadreview feature/ahead-review 1
# A branch that HAS landed, with new uncommitted work on top. Merged must stay BELOW the local
# tests when the open-MR test moves above them, or resuming work in a merged space is invisible.
mkwt mergeddirty feature/merged-dirty 1
echo scratch >> "$T/repo-mergeddirty/f"
# Dirty and in review at once.
echo scratch >> "$T/repo-dirtyreview/f"
# Pushed, then one more commit on top: the MR exists, this commit is not in it yet.
echo more > "$T/repo-aheadreview/g"
q git -C "$T/repo-aheadreview" add g
q git -C "$T/repo-aheadreview" commit -m ahead
# Its branch name is a strict prefix of feature/review, which HAS an open MR. The table
# lookup anchors on the field-separating tab; drop that anchor and this worktree silently
# inherits !10 from a branch it has nothing to do with.
mkwt prefix   feature/rev      1
# Branched from main and not committed to yet. Zero commits ahead of the base and HEAD is an
# ancestor of it — arithmetically identical to a fully merged branch, so anything inferring
# "merged" from containment alone marks every worktree the day it is created.
q git -C "$REPO" worktree add -b feature/fresh "$T/repo-fresh" main
echo scratch >> "$T/repo-dirty/f"

# A second repo, so the workspace list can interleave the two. Herdr does not return the list
# grouped by repo — the live session returns VM.Portal, VM.Portal, curato, VM.Portal, curato,
# curato — and the refresh loop only holds ONE MR table at a time, so an interleaved list
# refetches every time the repo changes. With one repo in the fixture that was invisible.
ORIGIN2="$T/origin2.git"
REPO2="$T/repo2"
q git init --bare -b main "$ORIGIN2"
q git clone "$ORIGIN2" "$REPO2"
echo base > "$REPO2/f"
q git -C "$REPO2" add f
q git -C "$REPO2" commit -m base
q git -C "$REPO2" push -u origin main
for _s in one two; do
  q git -C "$REPO2" worktree add -b "feature/$_s" "$T/repo2-$_s" main
  echo "$_s" > "$T/repo2-$_s/f"
  q git -C "$T/repo2-$_s" add f
  q git -C "$T/repo2-$_s" commit -m "$_s"
  q git -C "$T/repo2-$_s" push -u origin "feature/$_s"
done

# Rewritten only now that every push is done: the script never fetches, it reads the
# remote-tracking refs that already exist, so a URL it cannot reach is realistic and safe.
q git -C "$REPO" remote set-url origin git@gitlab.com:test/proj.git
q git -C "$REPO2" remote set-url origin git@gitlab.com:test/proj2.git

# Assert the fixture before asserting anything about the script. Every git call above is
# silenced by q(), so a setup that failed reached the phase assertions as "no output" and
# read as the script itself being broken.
for _d in dirty unpushed review draft merged nomr prefix fresh dirtyreview aheadreview mergeddirty; do
  [ -d "$T/repo-$_d" ] || { echo "FIXTURE BROKEN: $T/repo-$_d was not created" >&2; exit 2; }
done
for _d in one two; do
  [ -d "$T/repo2-$_d" ] || { echo "FIXTURE BROKEN: $T/repo2-$_d was not created" >&2; exit 2; }
done
git -C "$REPO" rev-parse --verify -q HEAD >/dev/null \
  || { echo "FIXTURE BROKEN: the base commit does not exist" >&2; exit 2; }
# The two states the precedence assertions turn on. Both are set up by side effect above, so a
# silent failure there would make those assertions test nothing.
[ -n "$(git -C "$T/repo-dirtyreview" status --porcelain)" ] \
  || { echo "FIXTURE BROKEN: repo-dirtyreview is not dirty" >&2; exit 2; }
[ "$(git -C "$T/repo-aheadreview" rev-list --count origin/feature/ahead-review..HEAD)" = "1" ] \
  || { echo "FIXTURE BROKEN: repo-aheadreview is not ahead of its remote" >&2; exit 2; }

# ------------------------------------------------------------------ stubs
BIN="$T/bin"; mkdir -p "$BIN"
CALLS="$T/calls"; : > "$CALLS"

cat > "$BIN/herdr" <<'H'
#!/usr/bin/env bash
echo "herdr $*" >> "$CALLS"
if [ "${1:-}" = "workspace" ] && [ "${2:-}" = "list" ]; then cat "$WSJSON"; fi
exit 0
H

# Models the two things about `glab mr list` the script depends on: it lists OPEN merge
# requests by default and merged ones only under --merged, and it answers per --repo. A stub
# that returned every row to every query would hide the truncation this split exists to avoid.
cat > "$BIN/glab" <<'G'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
case " $* " in *" --repo test/proj "*) ;; *) echo '[]'; exit 0 ;; esac
case " $* " in *" --merged "*) cat "$MRMERGED" ;; *) cat "$MROPEN" ;; esac
exit 0
G
chmod 755 "$BIN/herdr" "$BIN/glab"

# Deliberately interleaved between the two repos, the way the live session returns it.
WSJSON="$T/ws.json"
cat > "$WSJSON" <<J
{"id":"x","result":{"type":"workspace_list","workspaces":[
 {"workspace_id":"w1","label":"proj","worktree":{"checkout_path":"$REPO","is_linked_worktree":false,"repo_root":"$REPO"}},
 {"workspace_id":"w2","label":"dirty","worktree":{"checkout_path":"$T/repo-dirty","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"wA","label":"two-one","worktree":{"checkout_path":"$T/repo2-one","is_linked_worktree":true,"repo_root":"$REPO2"}},
 {"workspace_id":"w3","label":"unpushed","worktree":{"checkout_path":"$T/repo-unpushed","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w4","label":"review","worktree":{"checkout_path":"$T/repo-review","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"wB","label":"two-two","worktree":{"checkout_path":"$T/repo2-two","is_linked_worktree":true,"repo_root":"$REPO2"}},
 {"workspace_id":"w5","label":"draft","worktree":{"checkout_path":"$T/repo-draft","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w6","label":"merged","worktree":{"checkout_path":"$T/repo-merged","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w7","label":"nomr","worktree":{"checkout_path":"$T/repo-nomr","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w8","label":"fresh","worktree":{"checkout_path":"$T/repo-fresh","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w9","label":"prefix","worktree":{"checkout_path":"$T/repo-prefix","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w10","label":"dirtyreview","worktree":{"checkout_path":"$T/repo-dirtyreview","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w11","label":"aheadreview","worktree":{"checkout_path":"$T/repo-aheadreview","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w12","label":"mergeddirty","worktree":{"checkout_path":"$T/repo-mergeddirty","is_linked_worktree":true,"repo_root":"$REPO"}}
]}}
J

MROPEN="$T/mr-open.json"
cat > "$MROPEN" <<'J'
[{"iid":10,"source_branch":"feature/review","state":"opened","draft":false},
 {"iid":11,"source_branch":"feature/draft","state":"opened","draft":true},
 {"iid":13,"source_branch":"feature/dirty-review","state":"opened","draft":false},
 {"iid":14,"source_branch":"feature/ahead-review","state":"opened","draft":false}]
J
MRMERGED="$T/mr-merged.json"
cat > "$MRMERGED" <<'J'
[{"iid":12,"source_branch":"feature/merged","state":"merged","draft":false},
 {"iid":15,"source_branch":"feature/merged-dirty","state":"merged","draft":false}]
J
export WSJSON MROPEN MRMERGED CALLS

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
# The branch is matched on the whole field, not as a substring. feature/rev must not pick up
# the MR belonging to feature/review — a wrong badge is worse than none, because it says a
# branch is waiting on a review that does not exist. Nothing in the script's output shows
# which row was matched, so only an assertion like this one can catch it.
case "$(report_for w9)" in *"--token active=$ICON_BRANCH"*) _pass "a branch that is a prefix of another does not inherit its MR";;
  *) _fail "a branch that is a prefix of another does not inherit its MR (got: $(report_for w9))";; esac
case "$(report_for w6)" in *"--token merged=$ICON_MERGE !12"*) _pass "merged MR -> merged, carries !12";;
  *) _fail "merged MR -> merged, carries !12 (got: $(report_for w6))";; esac

# An open MR outranks anything git can see locally. It is the one fact that says somebody else
# is waiting on this branch, and it does not stop being true because you edited a file or
# committed a review fix you have not pushed yet. Ranking it below the local tests is what made
# the badge vanish the moment work resumed in a space that was genuinely in review.
case "$(report_for w10)" in *"--token review=$ICON_MR !13"*) _pass "a dirty worktree with an open MR still reports review";;
  *) _fail "a dirty worktree with an open MR still reports review (got: $(report_for w10))";; esac
case "$(report_for w11)" in *"--token review=$ICON_MR !14"*) _pass "unpushed commits on a branch with an open MR still report review";;
  *) _fail "unpushed commits on a branch with an open MR still report review (got: $(report_for w11))";; esac
# The converse, so the reordering does not quietly swallow the local states it sits above:
# without an MR, dirty and ahead must still read active (asserted for w2/w3 above), and a
# MERGED MR must stay below them — once a branch has landed, new work in that worktree is new
# work, not something waiting to be merged.
case "$(report_for w2)" in *"--token active=$ICON_BRANCH"*) _pass "dirty without an MR is untouched by the reordering";;
  *) _fail "dirty without an MR is untouched by the reordering (got: $(report_for w2))";; esac
case "$(report_for w12)" in *"--token active=$ICON_BRANCH"*) _pass "a merged MR does not outrank live local work";;
  *) _fail "a merged MR does not outrank live local work (got: $(report_for w12))";; esac

# Pushed with no MR is still yours: nobody is waiting on it and nothing has landed.
case "$(report_for w7)" in *"--token active=$ICON_BRANCH"*) _pass "pushed branch with no MR -> active";;
  *) _fail "pushed branch with no MR -> active (got: $(report_for w7))";; esac

# The regression: a worktree created moments ago has no commits, so every containment test
# against the base is trivially true. Only a merged MR is evidence that work actually landed.
case "$(report_for w8)" in *"--token merged"*) _fail "a fresh worktree is not reported as merged (got: $(report_for w8))";;
  *) _pass "a fresh worktree is not reported as merged";; esac
case "$(report_for w8)" in *"--token active=$ICON_BRANCH"*) _pass "a fresh worktree -> active";;
  *) _fail "a fresh worktree -> active (got: $(report_for w8))";; esac

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
for w in w2 w3 w4 w5 w6 w7 w8 w10 w11 w12 wA wB; do
  line="$(report_for $w)"
  set_count=$(printf '%s\n' "$line" | grep -o -- "--token " | wc -l | tr -d ' ')
  clear_count=$(printf '%s\n' "$line" | grep -o -- "--clear-token " | wc -l | tr -d ' ')
  [ $((set_count + clear_count)) -eq 4 ] || missing=$((missing + 1))
done
check "$missing" "0" "each report accounts for all four phase tokens"

echo
echo "D. MR lookups are cached per repo"
# Two glab calls per repo, not one. `glab mr list` caps --per-page at 100 and never paginates
# here, so a single --all query silently drops the oldest rows once a repo passes 100 merge
# requests — and on netronix/curato, which is at !123, that is exactly what happened: MRs !121
# to !123 were absent from a 99-row cache and their three worktrees sat unbadged. Splitting the
# query means the OPEN list, the only one a review badge depends on, is never truncated.
glab_calls() { grep -c '^glab ' "$CALLS"; }
glab_repos() { grep '^glab ' "$CALLS" | sed -E 's/.*--repo ([^ ]+).*/\1/' | sort -u | wc -l | tr -d ' '; }

rm -rf "$T/cache"   # section B already warmed it; these assertions count from cold
run refresh
check "$(glab_calls)" "4" "a cold refresh makes two glab calls per repo, for two repos"
check "$(glab_repos)" "2" "both repos are looked up"
check "$(grep -c -- '--merged' "$CALLS")" "2" "one of each repo's two calls asks for merged MRs"

# The workspace list interleaves the two repos. Holding a single last_root means every switch
# back refetches, so this is what proves the loop groups before it iterates.
check "$(glab_calls)" "4" "an interleaved workspace list still costs one lookup pair per repo"

run refresh
check "$(glab_calls)" "0" "second refresh inside the TTL makes no glab call"

run refresh --force
check "$(glab_calls)" "4" "--force bypasses the cache"

TTL=0 run refresh
check "$(glab_calls)" "4" "an expired cache is refetched"
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
rm -rf "$T/cache"   # a cached table would answer for the repo that no longer resolves
run refresh
check "$(grep -c -- '--repo test/proj ' "$CALLS")" "0" "no glab call for a non-GitLab remote"
case "$(report_for w2)" in *"--token active=$ICON_BRANCH"*) _pass "git-derived phases still reported";;
  *) _fail "git-derived phases still reported (got: $(report_for w2))";; esac
# feature/review has an open MR upstream, but without GitLab the script cannot know that.
case "$(report_for w4)" in *"--token review="*) _fail "no MR state means no review badge";;
  *) _pass "no MR state means no review badge";; esac
# And with no MR data nothing can be shown as merged, however contained it looks.
case "$(report_for w6)" in *"--token merged"*) _fail "no MR state means nothing is called merged";;
  *) _pass "no MR state means nothing is called merged";; esac
q git -C "$REPO" remote set-url origin git@gitlab.com:test/proj.git

echo
echo "H. failure of the MR lookup is not failure of the refresh"
# Warm the cache with a working glab first — the interesting case is a lookup that fails while
# a previous answer is on disk, which is every network blip on a machine that was working a
# minute ago.
rm -rf "$T/cache"
run refresh
case "$(report_for w4)" in *"--token review=$ICON_MR !10"*) ;;
  *) _fail "PRECONDITION: the cache did not warm (got: $(report_for w4))";; esac

cat > "$BIN/glab" <<'G'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
echo "error: could not reach gitlab.com" >&2
exit 1
G
chmod 755 "$BIN/glab"

TTL=0 run refresh
check "$RC" "0" "refresh survives glab failing"
# A failed lookup is not evidence that the MRs went away. Falling through with an empty table
# repaints every worktree in the repo as `active`, so one blocked request wipes every review
# badge at once — which is the "the badges were just gone" half of the report. A stale table is
# strictly better than a table asserted to be empty.
case "$(report_for w4)" in *"--token review=$ICON_MR !10"*) _pass "a failed lookup falls back to the cached MR table";;
  *) _fail "a failed lookup falls back to the cached MR table (got: $(report_for w4))";; esac
case "$(report_for w6)" in *"--token merged=$ICON_MERGE !12"*) _pass "the merged badge survives a failed lookup too";;
  *) _fail "the merged badge survives a failed lookup too (got: $(report_for w6))";; esac
case "$(report_for w2)" in *"--token active=$ICON_BRANCH"*) _pass "git-derived phases survive glab failing";;
  *) _fail "git-derived phases survive glab failing (got: $(report_for w2))";; esac
unset TTL

# Only the merged half failing is its own case: the open rows are good, so the run uses them,
# but the table must NOT be cached — caching it would persist "nothing ever merged" for a whole
# TTL. Proven by the refetch: a cached table would have suppressed the second run's glab calls.
cat > "$BIN/glab" <<'G'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
case " $* " in *" --merged "*) echo "error: could not reach gitlab.com" >&2; exit 1 ;; esac
case " $* " in *" --repo test/proj "*) ;; *) echo '[]'; exit 0 ;; esac
cat "$MROPEN"
G
chmod 755 "$BIN/glab"
rm -rf "$T/cache"
run refresh
check "$RC" "0" "refresh survives only the merged lookup failing"
case "$(report_for w4)" in *"--token review=$ICON_MR !10"*) _pass "open MRs still badge when the merged lookup fails";;
  *) _fail "open MRs still badge when the merged lookup fails (got: $(report_for w4))";; esac
case "$(report_for w6)" in *"--token merged"*) _fail "a half-answered lookup does not invent merged state";;
  *) _pass "a half-answered lookup does not invent merged state";; esac
run refresh
check "$(grep -c '^glab ' "$CALLS")" "4" "a half-answered lookup is not cached, so the next run retries"

# With nothing cached there is nothing to fall back to, and git-only is the honest answer.
cat > "$BIN/glab" <<'G'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
echo "error: could not reach gitlab.com" >&2
exit 1
G
chmod 755 "$BIN/glab"
rm -rf "$T/cache"
run refresh
check "$RC" "0" "refresh survives glab failing with a cold cache"
case "$(report_for w4)" in *"--token review="*) _fail "a cold cache plus a failed lookup invents no MR state";;
  *) _pass "a cold cache plus a failed lookup invents no MR state";; esac

echo
echo "I. the wiring that makes the badges appear and persist"
# These are static assertions about config, not behaviour of the script — but nothing else
# catches them, and each one silently produces no badges rather than an error.
MANIFEST="$ROOT/dot_config/herdr/plugin-phase/herdr-plugin.toml"
CONF="$ROOT/dot_config/herdr/config.toml"
if [ ! -r "$MANIFEST" ] || [ ! -r "$CONF" ]; then
  _fail "plugin manifest and herdr config are both present"
else
  _pass "plugin manifest and herdr config are both present"
  grep -qE '^id = "dev\.phase"' "$MANIFEST" \
    && _pass "manifest declares dev.phase" || _fail "manifest declares dev.phase"
  # Without this hook every badge is gone after a server restart, with nothing to say so.
  grep -A2 '^\[\[startup\]\]' "$MANIFEST" | grep -q 'phase.sh' \
    && _pass "a startup hook replays the phases" || _fail "a startup hook replays the phases"
  for ev in workspace.focused worktree.created worktree.removed; do
    grep -q "on = \"$ev\"" "$MANIFEST" \
      && _pass "subscribes to $ev" || _fail "subscribes to $ev"
  done
  # Focus fires on every workspace switch. A full refresh there costs ~0.4s of forked git for
  # a badge the user is about to look at exactly one of.
  grep -A3 'on = "workspace.focused"' "$MANIFEST" | grep -q 'HERDR_WORKSPACE_ID' \
    && _pass "the focus hook refreshes only the focused space" \
    || _fail "the focus hook refreshes only the focused space"

  # A token the sidebar never references is reported into a void.
  for tok in active review merged parked; do
    grep -q "token = \"[\$]$tok\"" "$CONF" \
      && _pass "sidebar renders \$$tok" || _fail "sidebar renders \$$tok"
  done
  grep -q 'phase.sh refresh --force' "$CONF" \
    && _pass "a keybinding forces a refresh" || _fail "a keybinding forces a refresh"
fi

# The timer is what actually keeps an MR badge true. The plugin's event hooks cannot: the
# state that changes lives on GitLab, so opening an MR from the worktree you are sitting in,
# or someone merging one while you are away, fires no Herdr event and the badge stays stale
# until you happen to switch spaces. Observed 2026-09-09 — two worktrees with open MRs sat
# unbadged for two days while `refresh` returned the correct `review` phase for both.
PLIST="$ROOT/Library/LaunchAgents/be.netronix.herdr-phase-refresh.plist.tmpl"
if [ ! -r "$PLIST" ]; then
  _fail "a LaunchAgent refreshes the badges on a timer (plist missing)"
else
  _pass "a LaunchAgent refreshes the badges on a timer"
  grep -q '<string>be.netronix.herdr-phase-refresh</string>' "$PLIST" \
    && _pass "the plist Label matches its filename" || _fail "the plist Label matches its filename"
  # Invoking anything but `refresh` would load the agent and badge nothing.
  grep -q '<string>refresh</string>' "$PLIST" \
    && _pass "the agent runs phase.sh refresh" || _fail "the agent runs phase.sh refresh"
  # An interval longer than the MR-table TTL means every run re-reads GitLab; a much longer
  # one would make the badge stale for exactly as long as nobody switches spaces, which is
  # the failure this exists to fix.
  ival="$(grep -A1 '<key>StartInterval</key>' "$PLIST" | grep -oE '[0-9]+' | head -1)"
  if [ -n "$ival" ] && [ "$ival" -ge 60 ] && [ "$ival" -le 600 ]; then
    _pass "the refresh interval is between 1 and 10 minutes ($ival s)"
  else
    _fail "the refresh interval is between 1 and 10 minutes (got '${ival:-none}')"
  fi
  # The agent must run at normal scheduling priority. ProcessType=Background puts every one of
  # the ~100 forks a refresh makes — git, python3, glab, herdr — in the lowest band, and
  # LowPriorityIO throttles them further. Measured 2026-09-11 on the live session, same script,
  # same arguments: 13 s at normal priority, and under `taskpolicy -b` still unfinished after
  # 4 minutes; a real `launchctl kickstart` of the agent took ~6 minutes. launchd never overlaps
  # a StartInterval job, so at 180 s the timer could not complete a single cycle — it reported
  # runs=739 and last exit code=0 while the MR caches sat 5 and 53 minutes stale. That is the
  # "I have MRs open and no badge appears" half of the report, and neither key is worth it for a
  # 13-second job that runs once every three minutes.
  # Matched on the <key> element, not the bare word: the comment above those keys in the plist
  # explains why they are absent and names both of them.
  grep -q '<key>ProcessType</key>' "$PLIST" \
    && _fail "the agent is not throttled to background scheduling priority" \
    || _pass "the agent is not throttled to background scheduling priority"
  grep -q '<key>LowPriorityIO</key>' "$PLIST" \
    && _fail "the agent does not ask for low-priority I/O" \
    || _pass "the agent does not ask for low-priority I/O"
  # chezmoi renders the home path; a hard-coded /Users/<someone> deploys a broken agent on
  # any other machine and fails silently, because launchd logs nothing here by design.
  grep -q '{{ .chezmoi.homeDir }}/.config/herdr/phase.sh' "$PLIST" \
    && _pass "the program path is templated, not hard-coded" \
    || _fail "the program path is templated, not hard-coded"
  # configure.sh is the only thing that tells launchd the plist exists.
  grep -q 'launchctl bootstrap' "$ROOT/.scripts/configure.sh" \
    && _pass "configure.sh loads the LaunchAgents" || _fail "configure.sh loads the LaunchAgents"
fi

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
