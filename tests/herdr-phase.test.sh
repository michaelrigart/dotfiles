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
#   3. Exactly one of the three phase tokens may be set at a time, and the other two must be
#      explicitly cleared; the same holds for the three pipeline tokens (ci_ok, ci_fail,
#      ci_run). Herdr keeps a token until told otherwise, so a space that moves review ->
#      merged would otherwise render both icons at once.
#   4. The icons are Nerd Font private-use codepoints. A wrong codepoint renders as tofu in
#      the sidebar and nothing anywhere reports an error, so the exact bytes are pinned here.
#
# `git` is real throughout — dirty trees, unpushed commits and linked worktrees have enough
# semantics that stubbing them would test the stub. `herdr`, `glab` and `gh` are stubbed: one to
# capture what would be reported, the others to make MR and PR state deterministic and to count
# calls, which is how the per-repo caching is proved.
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

# The four icons, as bytes. Written as escapes rather than literals because this file travels
# through tools that silently drop private-use characters.
ICON_BRANCH=$(printf '\xee\xb1\xaf')   # U+EC6F cod-git_branch
ICON_MR=$(printf '\xee\xa9\xa4')       # U+EA64 cod-git_pull_request
ICON_DRAFT=$(printf '\xee\xaf\x9b')    # U+EBDB cod-git_pull_request_draft
ICON_MERGE=$(printf '\xee\xab\xbe')    # U+EAFE cod-git_merge

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
# And the collision the other way round. The trailing tab anchors the END of the field but
# nothing anchors the start, so a search for "mr-suffix<TAB>" matches inside the row for
# owner/mr-suffix. This branch has no MR of its own and owner/mr-suffix has !16 open.
# Dirty, because that is the shape the bug is worst in: the MR test now runs first, so a
# worktree you are actively editing reports somebody else's review instead of active.
mkwt suffix   mr-suffix        1
echo scratch >> "$T/repo-suffix/f"
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

# A third repository on GitHub, with one worktree per PR shape section M exercises, and a fourth
# on GitLab under the same owner/name, so the two forges' cache keys can be told apart.
mkrepo() { # mkrepo <dir> <origin-url> <branch>...
  local d="$T/$1" url="$2" b; shift 2
  q git init --bare -b main "$d.git"
  q git clone "$d.git" "$d"
  echo base > "$d/f"
  q git -C "$d" add f
  q git -C "$d" commit -m base
  q git -C "$d" push -u origin main
  for b in "$@"; do
    q git -C "$d" worktree add -b "feature/$b" "$d-$b" main
    echo "$b" > "$d-$b/f"
    q git -C "$d-$b" add f
    q git -C "$d-$b" commit -m "$b"
    q git -C "$d-$b" push -u origin "feature/$b"
  done
  q git -C "$d" remote set-url origin "$url"
}
REPO3="$T/repo3"; REPO4="$T/repo4"
mkrepo repo3 git@github.com:test/proj3.git gh-ready gh-draft gh-merged gh-cross gh-reused
mkrepo repo4 git@gitlab.com:test/proj3.git gl3
for _d in gh-ready gh-draft gh-merged gh-cross gh-reused; do
  [ -d "$REPO3-$_d" ] || { echo "FIXTURE BROKEN: $REPO3-$_d was not created" >&2; exit 2; }
done
[ -d "$REPO4-gl3" ] || { echo "FIXTURE BROKEN: $REPO4-gl3 was not created" >&2; exit 2; }

# Assert the fixture before asserting anything about the script. Every git call above is
# silenced by q(), so a setup that failed reached the phase assertions as "no output" and
# read as the script itself being broken.
for _d in dirty unpushed review draft merged nomr prefix fresh dirtyreview aheadreview mergeddirty suffix; do
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

chmod 755 "$BIN/herdr"

# Models the three things about glab the script depends on: `mr list` lists OPEN merge requests
# by default and merged ones only under --merged, it answers per --repo, and
# `api projects/<url-encoded slug>/merge_requests/<iid>` answers the head pipeline's status from
# the $PIPES fixture (`iid<TAB>status`; an iid absent from it has no pipeline). A stub that
# returned every row to every query would hide the truncation the two-call split exists to
# avoid, and one that ignored the slug would hide an unencoded `/`. Both calls must name the
# host (`api --hostname gitlab.com`, `mr list --repo https://gitlab.com/<slug>`): glab otherwise
# takes it from the current directory's repository, and any other form is refused here.
# A $PIPEFAIL file makes api fail the way glab does, the error's JSON body on STDOUT and a
# non-zero exit; with the content "200" it answers 200 with a body that is not the MR, and with
# "body-rc1" it prints a valid body for the asked MR (head pipeline failed) and still exits 1.
# Every call records its working directory in $PWDS.
# A function because later cases overwrite the stub with failing variants.
glab_stub() {
cat > "$BIN/glab" <<'G'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
[ -z "${PWDS:-}" ] || echo "$PWD" >> "$PWDS"
if [ "${1:-}" = "api" ]; then
  if [ -e "${PIPEFAIL:-}" ]; then
    if [ "$(cat "$PIPEFAIL")" = "body-rc1" ]; then
      echo "{\"iid\":${4##*/},\"head_pipeline\":{\"status\":\"failed\"}}"
      echo "glab: HTTP 502" >&2; exit 1
    fi
    echo '{"message":"401 Unauthorized"}'
    [ "$(cat "$PIPEFAIL")" = "200" ] && exit 0
    echo "glab: 401 Unauthorized (HTTP 401)" >&2; exit 1
  fi
  [ "${2:-}" = "--hostname" ] && [ "${3:-}" = "gitlab.com" ] || { echo '{"message":"wrong host"}'; exit 1; }
  case "${4:-}" in projects/test%2Fproj/merge_requests/*) ;; *) echo '{"message":"404 Not Found"}'; exit 1 ;; esac
  iid="${4##*/}"; st=""
  [ -r "${PIPES:-}" ] && st="$(awk -F'\t' -v i="$iid" '$1==i {print $2; exit}' "$PIPES")"
  if [ -n "$st" ]; then echo "{\"iid\":$iid,\"head_pipeline\":{\"status\":\"$st\"}}"
  else echo "{\"iid\":$iid,\"head_pipeline\":null}"; fi
  exit 0
fi
case " $* " in *" --repo https://gitlab.com/test/proj "*) ;; *) echo '[]'; exit 0 ;; esac
case " $* " in *" --merged "*) cat "$MRMERGED" ;; *) cat "$MROPEN" ;; esac
exit 0
G
chmod 755 "$BIN/glab"
}
glab_stub

# Models what the script depends on in `gh pr list`: it answers per `-R github.com/<owner>/<repo>`
# and per `--state open|merged` from fixture files ($GHDIR/<state>-<owner>__<repo>.json, `[]` when
# absent), and refuses any other -R form, a missing `--limit 100` or a missing `--json`. The script
# runs gh under `env -i`, so the stub gets no suite variable: the paths below are written into it,
# and the failure mode comes from $GHDIR/mode (fail: exit 1 with a message on stderr; garbage and
# object: exit 0 with an answer that is not a list; empty: exit 0 and no output at all;
# open-empty: the open query alone answers with no output; merged-fail, merged-garbage and merged-empty: only the merged query misbehaves). Every call records its arguments, its working directory and its
# environment.
GHDIR="$T/gh"; GHENV="$T/gh-env"; mkdir -p "$GHDIR"; : > "$GHENV"
cat > "$T/gh.stub" <<'G'
#!/usr/bin/env bash
GHDIR=@GHDIR@
echo "gh $*" >> @CALLS@
echo "$PWD" >> @PWDS@
env >> @GHENV@
mode=""; [ -r "$GHDIR/mode" ] && mode="$(cat "$GHDIR/mode")"
[ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ] || { echo "gh: unsupported command" >&2; exit 1; }
shift 2
repo=""; state=""; limit=""; json=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R) repo="${2:-}"; shift 2 ;;
    --state) state="${2:-}"; shift 2 ;;
    --limit) limit="${2:-}"; shift 2 ;;
    --json) json="${2:-}"; shift 2 ;;
    *) echo "gh: unexpected argument $1" >&2; exit 1 ;;
  esac
done
case "$repo" in github.com/*/*) ;; *) echo "gh: -R must name the host" >&2; exit 1 ;; esac
[ "$limit" = "100" ] || { echo "gh: --limit 100 is required" >&2; exit 1; }
[ -n "$json" ] || { echo "gh: --json is required" >&2; exit 1; }
case "$state" in open|merged) ;; *) echo "gh: bad --state" >&2; exit 1 ;; esac
case "$mode" in
  fail) echo "gh: HTTP 502" >&2; exit 1 ;;
  garbage) echo garbage; exit 0 ;;
  object) echo '{"message":"x"}'; exit 0 ;;
  empty) exit 0 ;;
  open-empty) [ "$state" = "open" ] && exit 0 ;;
  merged-fail) [ "$state" = "merged" ] && { echo "gh: HTTP 502" >&2; exit 1; } ;;
  merged-garbage) [ "$state" = "merged" ] && { echo garbage; exit 0; } ;;
  merged-empty) [ "$state" = "merged" ] && exit 0 ;;
esac
slug="${repo#github.com/}"
f="$GHDIR/$state-${slug%%/*}__${slug#*/}.json"
if [ -r "$f" ]; then cat "$f"; else echo '[]'; fi
G
sed -e "s|@GHDIR@|$GHDIR|" -e "s|@CALLS@|$T/calls|" -e "s|@PWDS@|$T/pwds|" -e "s|@GHENV@|$GHENV|" \
  "$T/gh.stub" > "$BIN/gh"
chmod 755 "$BIN/gh"

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
 {"workspace_id":"w12","label":"mergeddirty","worktree":{"checkout_path":"$T/repo-mergeddirty","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"w13","label":"suffix","worktree":{"checkout_path":"$T/repo-suffix","is_linked_worktree":true,"repo_root":"$REPO"}}
]}}
J

MROPEN="$T/mr-open.json"
cat > "$MROPEN" <<'J'
[{"iid":10,"source_branch":"feature/review","state":"opened","draft":false},
 {"iid":11,"source_branch":"feature/draft","state":"opened","draft":true},
 {"iid":13,"source_branch":"feature/dirty-review","state":"opened","draft":false},
 {"iid":14,"source_branch":"feature/ahead-review","state":"opened","draft":false},
 {"iid":16,"source_branch":"owner/mr-suffix","state":"opened","draft":false}]
J
MRMERGED="$T/mr-merged.json"
cat > "$MRMERGED" <<'J'
[{"iid":12,"source_branch":"feature/merged","state":"merged","draft":false},
 {"iid":15,"source_branch":"feature/merged-dirty","state":"merged","draft":false}]
J
PIPES="$T/pipes.tsv"; PIPEFAIL="$T/pipe-fail"
PWDS="$T/pwds"; : > "$PWDS"
export WSJSON MROPEN MRMERGED CALLS PIPES PIPEFAIL PWDS

run() { # run <args...> -> stdout+stderr, sets RC; each run starts a clean call log. RUNDIR starts it elsewhere.
  : > "$CALLS"; : > "$PWDS"
  OUT=$(cd "${RUNDIR:-$PWD}" && PATH="$BIN:$PATH" PINNED_PATH="$BIN:$PATH" \
        HERDR_PHASE_CACHE_DIR="$T/cache" \
        HERDR_PHASE_TTL="${TTL:-120}" \
        /bin/bash "$PHASE" "$@" 2>&1); RC=$?
}

# The report line for one workspace, so assertions read as "what did w4 get told".
report_for() { grep -E "^herdr workspace report-metadata $1 " "$CALLS" | head -1; }

# A report sets exactly the one phase token and clears the other three.
phase_check() { # phase_check <ws> <phase> <value> <label>
  local line t ok=1; line="$(report_for "$1")"
  case "$line" in *" --token $2=$3 "*) ;; *) ok=0 ;; esac
  for t in active draft review merged; do
    [ "$t" = "$2" ] || case "$line" in *" --clear-token $t "*) ;; *) ok=0 ;; esac
  done
  if [ "$ok" = 1 ]; then _pass "$4"; else _fail "$4 (got: $line)"; fi
}

echo "A. usage"
run --help
check "$RC" "0" "--help exits 0"
case "$OUT" in *"Phases: active, draft, review, merged."*) _pass "--help lists the four phases";; *) _fail "--help lists the four phases (got: $OUT)";; esac
case "$OUT" in *refresh*) _pass "--help documents refresh";; *) _fail "--help documents refresh";; esac
case "$OUT" in *pin*) _fail "--help no longer offers pin";; *) _pass "--help no longer offers pin";; esac
run bogus-subcommand
[ "$RC" -ne 0 ] && _pass "unknown subcommand is an error" || _fail "unknown subcommand is an error"
run pin --workspace w2 parked; [ "$RC" -ne 0 ] && _pass "pin is gone" || _fail "pin is gone"

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
phase_check w5 draft "$ICON_DRAFT !11" "open draft MR -> draft, carries !11"
# The branch is matched on the whole field, not as a substring. feature/rev must not pick up
# the MR belonging to feature/review — a wrong badge is worse than none, because it says a
# branch is waiting on a review that does not exist. Nothing in the script's output shows
# which row was matched, so only an assertion like this one can catch it.
case "$(report_for w9)" in *"--token active=$ICON_BRANCH"*) _pass "a branch that is a prefix of another does not inherit its MR";;
  *) _fail "a branch that is a prefix of another does not inherit its MR (got: $(report_for w9))";; esac
# The same collision from the other end, and the one the tab anchor cannot catch: the tab
# terminates the field but nothing marks its start, so mr-suffix matches inside the row for
# owner/mr-suffix. Only whole-field equality rejects both.
case "$(report_for w13)" in *"--token active=$ICON_BRANCH"*) _pass "a branch that is a suffix of another does not inherit its MR";;
  *) _fail "a branch that is a suffix of another does not inherit its MR (got: $(report_for w13))";; esac
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

# Herdr keeps a token until told otherwise, so the two unused tokens must be cleared on
# every report or a space that changes phase renders two icons at once.
missing=0
for w in w2 w3 w4 w5 w6 w7 w8 w10 w11 w12 w13 wA wB; do
  line="$(report_for $w)"
  set_count=$(printf '%s\n' "$line" | grep -o -- "--token " | wc -l | tr -d ' ')
  clear_count=$(printf '%s\n' "$line" | grep -o -- "--clear-token " | wc -l | tr -d ' ')
  phase_sets=$(printf '%s\n' "$line" | grep -o -E -- "--token (active|draft|review|merged)=" | wc -l | tr -d ' ')
  [ $((set_count + clear_count)) -eq 7 ] && [ "$phase_sets" -eq 1 ] || missing=$((missing + 1))
done
check "$missing" "0" "each report accounts for the four phase and the three pipeline tokens, one phase set"

echo
echo "D. MR lookups are cached per repo"
# Two glab calls per repo, not one. `glab mr list` caps --per-page at 100 and never paginates
# here, so a single --all query silently drops the oldest rows once a repo passes 100 merge
# requests — and on netronix/curato, which is at !123, that is exactly what happened: MRs !121
# to !123 were absent from a 99-row cache and their three worktrees sat unbadged. Splitting the
# query means the OPEN list, the only one a review badge depends on, is never truncated.
glab_calls() { grep -c '^glab mr list' "$CALLS"; }
glab_api_calls() { grep -c '^glab api ' "$CALLS"; }
glab_repos() { grep '^glab mr list' "$CALLS" | sed -E 's/.*--repo ([^ ]+).*/\1/' | sort -u | wc -l | tr -d ' '; }

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
echo "F. a single space can be refreshed on its own"
run refresh --workspace w4
check "$(grep -c -E '^herdr workspace report-metadata ' "$CALLS")" "1" "refresh --workspace reports once"
case "$(report_for w4)" in *"--token review="*) _pass "refresh --workspace reports the right space";;
  *) _fail "refresh --workspace reports the right space";; esac

echo
echo "G. a repo Herdr cannot resolve to GitLab or GitHub degrades to git-only"
q git -C "$REPO" remote set-url origin git@codeberg.org:test/proj.git
rm -rf "$T/cache"   # a cached table would answer for the repo that no longer resolves
run refresh
check "$(grep -c -- 'gitlab.com/test/proj ' "$CALLS")" "0" "no glab call for a remote on neither forge"
check "$(grep -c '^gh ' "$CALLS")" "0" "no gh call for a remote on neither forge"
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
case " $* " in *" --repo https://gitlab.com/test/proj "*) ;; *) echo '[]'; exit 0 ;; esac
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
check "$(grep -c '^glab mr list' "$CALLS")" "4" "a half-answered lookup is not cached, so the next run retries"

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
echo "K. the head pipeline's status rides beside an open MR's badge"
# The list endpoint carries no head_pipeline, so each open MR costs one `glab api` call. The
# glyph bytes are pinned for the same reason as the icons: a wrong codepoint is tofu with no error.
CI_OK=$(printf '\xee\xaa\xb2')     # U+EAB2 cod-check
CI_FAIL=$(printf '\xee\xa9\xb6')   # U+EA76 cod-close
CI_RUN=$(printf '\xee\xa9\xb7')    # U+EA77 cod-sync
glab_stub
rm -f "$PIPEFAIL"

set_pipe() { # set_pipe [<iid> <status>]... -> the $PIPES fixture; no pairs means no pipelines
  : > "$PIPES"
  while [ $# -ge 2 ]; do printf '%s\t%s\n' "$1" "$2" >> "$PIPES"; shift 2; done
}
# The report must END with exactly one set pipeline token and the other two cleared, in that
# order, after the phase tokens.
ci_check() { # ci_check <ws> <ok|fail|run|none> <label>
  local g="" t want="" line
  case "$2" in ok) g=$CI_OK ;; fail) g=$CI_FAIL ;; run) g=$CI_RUN ;; esac
  for t in ok fail run; do
    if [ "$t" = "$2" ]; then want="$want --token ci_$t=$g"; else want="$want --clear-token ci_$t"; fi
  done
  line="$(report_for "$1")"
  case "$line" in *"$want") _pass "$3";; *) _fail "$3 (got: $line)";; esac
}

set_pipe 10 success
run refresh --force --workspace w4
ci_check w4 ok "success -> ci_ok"
case "$(report_for w4)" in *"--token review=$ICON_MR !10 "*) _pass "the phase token is unchanged beside the pipeline token";;
  *) _fail "the phase token is unchanged beside the pipeline token (got: $(report_for w4))";; esac
set_pipe 10 failed;  run refresh --force --workspace w4; ci_check w4 fail "failed -> ci_fail"
for st in running pending created preparing waiting_for_resource scheduled; do
  set_pipe 10 "$st"; run refresh --force --workspace w4; ci_check w4 run "$st -> ci_run"
done
for st in canceled skipped manual; do
  set_pipe 10 "$st"; run refresh --force --workspace w4; ci_check w4 none "$st -> no pipeline badge"
done
set_pipe; run refresh --force --workspace w4; ci_check w4 none "no head pipeline -> no pipeline badge"

# A draft is an open MR too; and only open MRs cost a call.
set_pipe 10 success 11 failed 12 success 15 success
run refresh --force
ci_check w4 ok "a ready MR shows its pipeline"
ci_check w5 fail "a draft MR shows its pipeline too"
case "$(report_for w5)" in *"--token draft=$ICON_DRAFT !11 "*) _pass "the draft keeps its phase token beside the pipeline";;
  *) _fail "the draft keeps its phase token beside the pipeline (got: $(report_for w5))";; esac
ci_check w6 none "a merged MR shows no pipeline badge"
ci_check w7 none "a branch without an MR shows no pipeline badge"
check "$(glab_api_calls)" "4" "one api call per open MR, none for merged or MR-less spaces"
check "$(grep -c -E 'merge_requests/(12|15)$' "$CALLS")" "0" "merged MRs are never queried for a pipeline"
# glab takes the host from the current directory's repository unless told: name it every time.
check "$(grep '^glab api ' "$CALLS" | grep -vc -- ' --hostname gitlab.com projects/test%2Fproj/')" "0" \
  "every api call pins --hostname gitlab.com"
check "$(grep '^glab mr list' "$CALLS" | grep -vc -- ' --repo https://gitlab.com/')" "0" \
  "every mr list call pins the host in --repo"
run refresh --force --workspace w6
check "$(glab_api_calls)" "0" "a merged space makes no api call"
run refresh --force --workspace w7
check "$(glab_api_calls)" "0" "a space without an MR makes no api call"

# Per-MR cache with the MR-table TTL.
rm -rf "$T/cache"
set_pipe 10 success 11 success 13 failed 14 running
run refresh
check "$(glab_api_calls)" "4" "a cold refresh makes one api call per open MR"
run refresh
check "$(glab_api_calls)" "0" "a second refresh inside the TTL makes no api call"
check "$(glab_calls)" "0" "and no list call either"
ci_check w4 ok "the cached status still renders"
run refresh --force
check "$(glab_api_calls)" "4" "--force refetches the pipelines"

# The cache key holds the iid: a branch reused after a merge gets a new MR number, and the old
# MR's pipeline must not be shown for it. Only the MR table is dropped, so the iid 10 entry is
# still warm when the table says 17.
set_pipe 10 success 17 failed 11 success 13 failed 14 running
sed 's/"iid":10,/"iid":17,/' "$MROPEN" > "$MROPEN.new" && mv "$MROPEN.new" "$MROPEN"
rm -f "$T/cache"/*.tsv
run refresh --workspace w4
check "$(glab_api_calls)" "1" "a new MR iid refetches at once"
ci_check w4 fail "the new MR's status shows, never iid 10's"
case "$(report_for w4)" in *"!17 "*) _pass "the report carries the new iid";; *) _fail "the report carries the new iid (got: $(report_for w4))";; esac
sed 's/"iid":17,/"iid":10,/' "$MROPEN" > "$MROPEN.new" && mv "$MROPEN.new" "$MROPEN"
rm -f "$T/cache"/*.tsv

# A failed call is not evidence that the pipeline went away. With a warm cache the cached class
# stands; with nothing cached there is nothing to show, and the phase token still goes out.
rm -rf "$T/cache"
set_pipe 10 success
run refresh --workspace w4
ci_check w4 ok "PRECONDITION: the pipeline cache warms"
: > "$PIPEFAIL"
TTL=0 run refresh --workspace w4
check "$(glab_api_calls)" "1" "an expired pipeline cache is refetched"
ci_check w4 ok "a failed api call keeps the cached class"
# glab prints an API error's JSON body on stdout (the stub does); parsed as if it were the MR it
# would read as "no pipeline" and overwrite the warm cache for a whole TTL.
check "$(cat "$T/cache/test%2Fproj.mr10.pipeline")" "success" "an error body does not overwrite the cached status"
echo 200 > "$PIPEFAIL"
TTL=0 run refresh --workspace w4
ci_check w4 ok "a 200 body that is not the MR keeps the cached class"
check "$(cat "$T/cache/test%2Fproj.mr10.pipeline")" "success" "a body without the MR's iid does not overwrite the cached status"
# The exit status is read on its own: a valid body for this MR with a non-zero exit (a gateway
# error that still carried a body) must not be taken as an answer and overwrite the cache.
echo body-rc1 > "$PIPEFAIL"
TTL=0 run refresh --workspace w4
ci_check w4 ok "a valid body with exit 1 keeps the cached class"
check "$(cat "$T/cache/test%2Fproj.mr10.pipeline")" "success" "a valid body with exit 1 does not overwrite the cached status"

# The stale fallback has an age limit: within 1800 s a failed call keeps the cached class, past it
# the pipeline tokens are cleared (the cached status stays on disk, a later good call replaces it).
aged() { touch -t "$(date -v-"$1"M +%Y%m%d%H%M.%S)" "$T/cache/test%2Fproj.mr10.pipeline"; }
: > "$PIPEFAIL"
aged 29
TTL=0 run refresh --workspace w4
ci_check w4 ok "a failed call keeps a cached status 29 minutes old"
aged 31
TTL=0 run refresh --workspace w4
ci_check w4 none "a failed call clears the pipeline tokens once the cache is 31 minutes old"
case "$(report_for w4)" in *"--token review=$ICON_MR !10 "*) _pass "the phase token survives the cleared pipeline tokens";;
  *) _fail "the phase token survives the cleared pipeline tokens (got: $(report_for w4))";; esac
rm -f "$PIPEFAIL"
TTL=0 run refresh --workspace w4
ci_check w4 ok "a good call after the limit shows the pipeline again"
: > "$PIPEFAIL"
rm -rf "$T/cache"
run refresh --workspace w4
check "$RC" "0" "refresh survives a failing api call with a cold cache"
ci_check w4 none "a cold cache plus a failed api call invents no pipeline"
case "$(report_for w4)" in *"--token review=$ICON_MR !10 "*) _pass "the phase token survives the failed api call";;
  *) _fail "the phase token survives the failed api call (got: $(report_for w4))";; esac
rm -f "$PIPEFAIL"

# A cached GitLab row with no iid still refreshes cleanly: no unbound variable, no pipeline badge.
rm -rf "$T/cache"; mkdir -p "$T/cache"
printf 'feature/review\topened\t\t0\n' > "$T/cache/test%2Fproj.tsv"
set_pipe 10 success
run refresh --workspace w4
check "$RC" "0" "a GitLab row with an empty iid refreshes with exit 0"
case "$OUT" in *"unbound variable"*) _fail "an empty iid leaves stderr clean (got: $OUT)";; *) _pass "an empty iid leaves stderr clean";; esac
ci_check w4 none "an empty iid shows no pipeline badge"
rm -rf "$T/cache"; set_pipe

# glab reads its configuration from the current directory's repository and runs git there, and a
# key command or plugin hook starts phase.sh wherever the caller was. Started from inside a
# repository, every glab call must still run from /.
set_pipe 10 success 11 failed
RUNDIR="$T/repo-review" run refresh --force
[ "$(wc -l < "$PWDS" | tr -d ' ')" -gt 0 ] && _pass "the cwd case reached glab" || _fail "the cwd case reached glab"
check "$(grep -vxc / "$PWDS")" "0" "every glab call runs from / even when phase.sh starts inside a repository"

# Socket limit: at most 16 token keys per report; this one makes seven.
set_pipe 10 success 11 failed
run refresh --force
over=0
while IFS= read -r line; do
  n=$(printf '%s\n' "$line" | grep -o -E -- '--(clear-)?token ' | wc -l | tr -d ' ')
  [ "$n" -le 16 ] || over=$((over + 1))
done < <(grep -E '^herdr workspace report-metadata ' "$CALLS")
check "$over" "0" "no report carries more than 16 token keys"

# The slug comes from a remote URL a sandboxed command can rewrite and reaches glab's --repo and
# an API path: a slug that is not a plain group/project path makes no glab call at all (repo2,
# whose remote is untouched, still makes its two).
for bad in 'a/../b' 'a/b?x=1' 'a/b%2Fc' 'a/b c'; do
  q git -C "$REPO" remote set-url origin "git@gitlab.com:$bad.git"
  rm -rf "$T/cache"
  run refresh
  check "$(grep -c '^glab ' "$CALLS")" "2" "remote slug '$bad': no glab call for it"
  check "$(grep -c 'proj2' "$CALLS")" "2" "remote slug '$bad': only the untouched repo is queried"
  case "$(report_for w4)" in *"--token review"*) _fail "remote slug '$bad': no review badge";; *) _pass "remote slug '$bad': no review badge";; esac
done
# The same under a UTF-8 locale, for GitLab's slug check (see section M).
for bad in 'é/b' 'a/ẞ' 'a/ｂ'; do
  q git -C "$REPO" remote set-url origin "git@gitlab.com:$bad.git"
  rm -rf "$T/cache"
  LC_ALL=en_US.UTF-8 run refresh
  check "$(grep -c '^glab ' "$CALLS")" "2" "remote slug '$bad' under a UTF-8 locale: no glab call for it"
  check "$(grep -c 'proj2' "$CALLS")" "2" "remote slug '$bad' under a UTF-8 locale: only the untouched repo is queried"
done
q git -C "$REPO" remote set-url origin git@gitlab.com:test/proj.git

# Two slugs that a "/" -> "_" cache name would fold into one file (a/b_c and a_b/c): each repo
# has an MR numbered 10 on its own branch, with its own pipeline, and a cold run must not let the
# second repo read the first one's MR table or pipeline status from the shared name.
cat > "$BIN/glab" <<'G'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
if [ "${1:-}" = "api" ]; then
  case "${4:-}" in
    projects/a%2Fb_c/merge_requests/10) echo '{"iid":10,"head_pipeline":{"status":"success"}}' ;;
    projects/a_b%2Fc/merge_requests/10) echo '{"iid":10,"head_pipeline":{"status":"failed"}}' ;;
    *) echo '{}'; exit 1 ;;
  esac
  exit 0
fi
case " $* " in
  *" --merged "*) echo '[]' ;;
  *" --repo https://gitlab.com/a/b_c "*) echo '[{"iid":10,"source_branch":"feature/review","state":"opened","draft":false}]' ;;
  *" --repo https://gitlab.com/a_b/c "*) echo '[{"iid":10,"source_branch":"feature/one","state":"opened","draft":false}]' ;;
  *) echo '[]' ;;
esac
G
chmod 755 "$BIN/glab"
q git -C "$REPO" remote set-url origin git@gitlab.com:a/b_c.git
q git -C "$REPO2" remote set-url origin git@gitlab.com:a_b/c.git
cat > "$T/ws-collide.json" <<J
{"id":"x","result":{"type":"workspace_list","workspaces":[
 {"workspace_id":"w4","label":"review","worktree":{"checkout_path":"$T/repo-review","is_linked_worktree":true,"repo_root":"$REPO"}},
 {"workspace_id":"wA","label":"two-one","worktree":{"checkout_path":"$T/repo2-one","is_linked_worktree":true,"repo_root":"$REPO2"}}
]}}
J
rm -rf "$T/cache"
WSJSON="$T/ws-collide.json" run refresh
ci_check w4 ok "slug a/b_c shows its own pipeline (success)"
ci_check wA fail "slug a_b/c shows its own pipeline (failed), not a/b_c's"
case "$(report_for wA)" in *"--token review=$ICON_MR !10 "*) _pass "slug a_b/c finds its own MR table, not a/b_c's";;
  *) _fail "slug a_b/c finds its own MR table, not a/b_c's (got: $(report_for wA))";; esac
check "$(ls "$T/cache" | LC_ALL=C sort | tr '\n' ' ')" "a%2Fb_c.mr10.pipeline a%2Fb_c.tsv a_b%2Fc.mr10.pipeline a_b%2Fc.tsv " "cache names encode the slug's / as %2F"
q git -C "$REPO" remote set-url origin git@gitlab.com:test/proj.git
q git -C "$REPO2" remote set-url origin git@gitlab.com:test/proj2.git
glab_stub

echo
echo "L. a space moves between draft and the other phases"
set_pipe
cp "$MROPEN" "$MROPEN.orig"; cp "$MRMERGED" "$MRMERGED.orig"
move() { run refresh --force --workspace w5; }
sed 's/"iid":11,"source_branch":"feature\/draft","state":"opened","draft":true/"iid":11,"source_branch":"feature\/draft","state":"opened","draft":false/' "$MROPEN.orig" > "$MROPEN"
move; phase_check w5 review "$ICON_MR !11" "draft -> review when the MR is marked ready"
cp "$MROPEN.orig" "$MROPEN"
move; phase_check w5 draft "$ICON_DRAFT !11" "review -> draft when the MR goes back to draft"
printf '[{"iid":10,"source_branch":"feature/review","state":"opened","draft":false}]\n' > "$MROPEN"
move; phase_check w5 active "$ICON_BRANCH" "draft -> active when the MR is gone from both lists"
cp "$MROPEN.orig" "$MROPEN"
move; phase_check w5 draft "$ICON_DRAFT !11" "active -> draft when an open draft MR appears"
printf '[{"iid":10,"source_branch":"feature/review","state":"opened","draft":false}]\n' > "$MROPEN"
printf '[{"iid":11,"source_branch":"feature/draft","state":"merged","draft":false}]\n' > "$MRMERGED"
move; phase_check w5 merged "$ICON_MERGE !11" "draft -> merged when the MR lands"
cp "$MROPEN.orig" "$MROPEN"; cp "$MRMERGED.orig" "$MRMERGED"; rm -f "$MROPEN.orig" "$MRMERGED.orig"

echo
echo "M. GitHub PRs are looked up like GitLab MRs"
GH_OPEN="$GHDIR/open-test__proj3.json"; GH_MERGED="$GHDIR/merged-test__proj3.json"
# Besides the five shapes under test, the open list holds rows the parse must drop: a branch with
# a tab in it, and two PR numbers that are not integers.
cat > "$GH_OPEN" <<'J'
[{"headRefName":"feature/gh-ready","state":"OPEN","number":21,"isDraft":false,"isCrossRepository":false,"statusCheckRollup":[]},
 {"headRefName":"feature/gh-draft","state":"OPEN","number":22,"isDraft":true,"isCrossRepository":false,"statusCheckRollup":[]},
 {"headRefName":"feature/gh-cross","state":"OPEN","number":24,"isDraft":false,"isCrossRepository":true,"statusCheckRollup":[]},
 {"headRefName":"feature/gh-reused","state":"OPEN","number":26,"isDraft":false,"isCrossRepository":false,"statusCheckRollup":[]},
 {"headRefName":"feature/tab\tbranch","state":"OPEN","number":27,"isDraft":false,"isCrossRepository":false,"statusCheckRollup":[]},
 {"headRefName":"feature/gh-badnum","state":"OPEN","number":"28","isDraft":false,"isCrossRepository":false,"statusCheckRollup":[]},
 {"headRefName":"feature/gh-badnum2","state":"OPEN","number":2.5,"isDraft":false,"isCrossRepository":false,"statusCheckRollup":[]}]
J
cat > "$GH_MERGED" <<'J'
[{"headRefName":"feature/gh-merged","state":"MERGED","number":23,"isDraft":false,"isCrossRepository":false},
 {"headRefName":"feature/gh-reused","state":"MERGED","number":25,"isDraft":false,"isCrossRepository":false}]
J
cp "$GH_OPEN" "$GH_OPEN.orig"; cp "$GH_MERGED" "$GH_MERGED.orig"
cat > "$T/ws-gh.json" <<J
{"id":"x","result":{"type":"workspace_list","workspaces":[
 {"workspace_id":"wG1","label":"gh-ready","worktree":{"checkout_path":"$REPO3-gh-ready","is_linked_worktree":true,"repo_root":"$REPO3"}},
 {"workspace_id":"wG2","label":"gh-draft","worktree":{"checkout_path":"$REPO3-gh-draft","is_linked_worktree":true,"repo_root":"$REPO3"}},
 {"workspace_id":"wG3","label":"gh-merged","worktree":{"checkout_path":"$REPO3-gh-merged","is_linked_worktree":true,"repo_root":"$REPO3"}},
 {"workspace_id":"wG4","label":"gh-cross","worktree":{"checkout_path":"$REPO3-gh-cross","is_linked_worktree":true,"repo_root":"$REPO3"}},
 {"workspace_id":"wG5","label":"gh-reused","worktree":{"checkout_path":"$REPO3-gh-reused","is_linked_worktree":true,"repo_root":"$REPO3"}}
]}}
J
gh_calls() { grep -c '^gh pr list' "$CALLS"; }
ghrun() { WSJSON="$T/ws-gh.json" run "$@"; }
rm -f "$GHDIR/mode"; rm -rf "$T/cache"

ghrun refresh
check "$RC" "0" "a GitHub refresh exits 0"
phase_check wG1 review "$ICON_MR #21" "an open ready PR -> review, carries #21"
phase_check wG2 draft "$ICON_DRAFT #22" "an open draft PR -> draft, carries #22"
phase_check wG3 merged "$ICON_MERGE #23" "a merged PR -> merged, carries #23"
# A fork's branch name is not this checkout's branch, so a cross-repository PR badges nothing.
phase_check wG4 active "$ICON_BRANCH" "a branch whose only PR is cross-repository stays active"
phase_check wG5 review "$ICON_MR #26" "a branch with a merged #25 and an open #26 reports #26"

# The table the parse produced: five columns, no row for what it must drop.
GH_TSV="$T/cache/github@test%2Fproj3.tsv"
check "$(grep -c . "$GH_TSV")" "4" "the table keeps four rows: three open and one merged, nothing dropped by mistake"
check "$(awk -F'\t' 'NF != 5' "$GH_TSV" | wc -l | tr -d ' ')" "0" "every GitHub row has five columns"
check "$(grep -c 'tab\|badnum\|gh-cross' "$GH_TSV")" "0" "cross-repository, tab-in-branch and non-integer rows are dropped"

# Calls: two per repository, host named, run from /, no rollup on the merged query.
rm -rf "$T/cache"
ghrun refresh
check "$(gh_calls)" "2" "a cold refresh makes two gh pr list calls for the repository"
check "$(grep -c -- '--state open ' "$CALLS")" "1" "one of them asks for open PRs"
check "$(grep -c -- '--state merged ' "$CALLS")" "1" "the other asks for merged PRs"
check "$(grep -- '--state merged ' "$CALLS" | grep -c statusCheckRollup)" "0" "the merged query does not request statusCheckRollup"
check "$(grep -- '--state open ' "$CALLS" | grep -c statusCheckRollup)" "1" "the open query requests statusCheckRollup"
check "$(grep '^gh ' "$CALLS" | grep -vc -- ' -R github.com/test/proj3 ')" "0" "every gh call names the host and the repository in -R"
[ "$(wc -l < "$PWDS" | tr -d ' ')" = "2" ] && _pass "the cwd check saw both gh calls" || _fail "the cwd check saw both gh calls"
check "$(grep -vxc / "$PWDS")" "0" "every gh call runs from /"
ghrun refresh
check "$(gh_calls)" "0" "a second refresh inside the TTL makes no gh call"
ghrun refresh --force
check "$(gh_calls)" "2" "--force bypasses the GitHub cache"
TTL=0 ghrun refresh
check "$(gh_calls)" "2" "an expired GitHub cache is refetched"
unset TTL

# gh runs under env -i with HOME and PATH only: a Herdr server started under direnv or mise carries
# these into its hooks, and none may reach the token's lookup.
: > "$GHENV"
GH_HOST=evil.example GH_REPO=x/y GH_CONFIG_DIR=/nonexistent GH_TOKEN=t GITHUB_TOKEN=t \
  XDG_CONFIG_HOME=/nonexistent HTTPS_PROXY=http://evil.invalid:1 SSL_CERT_FILE=/nonexistent \
  ghrun refresh --force
[ "$(grep -c '^HOME=' "$GHENV")" -gt 0 ] && _pass "the gh environment was recorded" || _fail "the gh environment was recorded"
check "$(grep -cE '^(GH_HOST|GH_REPO|GH_CONFIG_DIR|GH_TOKEN|GITHUB_TOKEN|XDG_CONFIG_HOME|HTTPS_PROXY|SSL_CERT_FILE)=' "$GHENV")" "0" \
  "no caller GH_*, token, XDG_CONFIG_HOME, proxy or CA variable reaches gh"
check "$(grep -vcE '^(HOME|PATH|PWD|OLDPWD|SHLVL|_)=' "$GHENV")" "0" "gh gets nothing but HOME and PATH from the suite"

# Draft to ready moves the space to review, and back.
sed 's/"isDraft":true/"isDraft":false/' "$GH_OPEN.orig" > "$GH_OPEN"
ghrun refresh --force --workspace wG2
phase_check wG2 review "$ICON_MR #22" "draft -> review when the PR is marked ready"
cp "$GH_OPEN.orig" "$GH_OPEN"
ghrun refresh --force --workspace wG2
phase_check wG2 draft "$ICON_DRAFT #22" "review -> draft when the PR goes back to draft"

# CI comes from the open list's rollup (Ruling 2): no extra call, mixed CheckRuns and
# StatusContexts, and an unknown state is never ok.
cr() { printf '{"__typename":"CheckRun","name":"c","status":"%s","conclusion":"%s"}' "$1" "$2"; }
sc() { printf '{"__typename":"StatusContext","context":"c","state":"%s"}' "$1"; }
roll() { # roll <rollup json> -> the open list with #21 carrying it; #22 always carries a failure
  printf '[{"headRefName":"feature/gh-ready","state":"OPEN","number":21,"isDraft":false,"isCrossRepository":false,"statusCheckRollup":%s},\n' "$1"
  printf ' {"headRefName":"feature/gh-draft","state":"OPEN","number":22,"isDraft":true,"isCrossRepository":false,"statusCheckRollup":[%s]}]\n' "$(cr COMPLETED FAILURE)"
}
gh_ci() { # gh_ci <ok|fail|run|none> <label> <rollup json>
  roll "$3" > "$GH_OPEN"
  rm -rf "$T/cache"; ghrun refresh --force --workspace wG1
  ci_check wG1 "$1" "$2"
}
gh_ci none "an empty rollup shows no CI" '[]'
gh_ci ok "all CheckRuns COMPLETED/SUCCESS -> ci_ok" "[$(cr COMPLETED SUCCESS),$(cr COMPLETED SUCCESS)]"
gh_ci ok "SUCCESS, SKIPPED and NEUTRAL -> ci_ok" "[$(cr COMPLETED SUCCESS),$(cr COMPLETED SKIPPED),$(cr COMPLETED NEUTRAL)]"
gh_ci fail "successes and one FAILURE -> ci_fail" "[$(cr COMPLETED SUCCESS),$(cr COMPLETED FAILURE),$(cr COMPLETED SUCCESS)]"
for st in ERROR CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE; do
  gh_ci fail "a lone $st -> ci_fail" "[$(cr COMPLETED $st)]"
done
gh_ci run "IN_PROGRESS and SUCCESS -> ci_run" "[$(cr IN_PROGRESS ''),$(cr COMPLETED SUCCESS)]"
gh_ci run "QUEUED -> ci_run" "[$(cr QUEUED '')]"
gh_ci run "StatusContext PENDING -> ci_run" "[$(sc PENDING)]"
gh_ci fail "StatusContext ERROR -> ci_fail" "[$(sc ERROR)]"
gh_ci fail "FAILURE and IN_PROGRESS -> ci_fail" "[$(cr COMPLETED FAILURE),$(cr IN_PROGRESS '')]"
gh_ci ok "CheckRun SUCCESS and StatusContext SUCCESS -> ci_ok" "[$(cr COMPLETED SUCCESS),$(sc SUCCESS)]"
gh_ci none "SUCCESS and a COMPLETED/STALE give no badge, never ok" "[$(cr COMPLETED SUCCESS),$(cr COMPLETED STALE)]"
gh_ci none "a rollup that is not a list shows no CI" '{"state":"SUCCESS"}'
gh_ci none "a null rollup shows no CI" 'null'

roll "[$(cr COMPLETED SUCCESS)]" > "$GH_OPEN"
rm -rf "$T/cache"; ghrun refresh --force
ci_check wG1 ok "the ready PR shows its CI"
ci_check wG2 fail "the draft PR shows its CI too"
ci_check wG3 none "a merged PR shows no CI"
check "$(gh_calls)" "2" "CI costs no extra gh call"

# A failed lookup keeps the cached CI for 30 minutes, then clears it and keeps the phase.
rm -rf "$T/cache"; ghrun refresh
echo fail > "$GHDIR/mode"
aged_gh() { touch -t "$(date -v-"$1"M +%Y%m%d%H%M.%S)" "$GH_TSV"; }
aged_gh 29
TTL=0 ghrun refresh --workspace wG1
ci_check wG1 ok "a failed lookup keeps GitHub CI from a cache 29 minutes old"
aged_gh 31
TTL=0 ghrun refresh --workspace wG1
ci_check wG1 none "a failed lookup clears GitHub CI from a cache 31 minutes old"
phase_check wG1 review "$ICON_MR #21" "the review phase survives the cleared CI"
rm -f "$GHDIR/mode"; unset TTL
cp "$GH_OPEN.orig" "$GH_OPEN"

# Failures. A warm cache stands in for a failed lookup, whatever shape the failure has.
rm -rf "$T/cache"; ghrun refresh
for m in fail garbage object empty open-empty; do
  echo "$m" > "$GHDIR/mode"
  TTL=0 ghrun refresh
  check "$RC" "0" "refresh survives gh answering '$m'"
  phase_check wG1 review "$ICON_MR #21" "gh answering '$m' keeps the cached review badge"
  phase_check wG3 merged "$ICON_MERGE #23" "gh answering '$m' keeps the cached merged badge"
done
rm -f "$GHDIR/mode"

# The merged half alone failing (an error exit, or an answer that is not a list): the open rows
# stand, merged state is not invented, and the table is not cached.
for m in merged-fail merged-garbage merged-empty; do
  rm -rf "$T/cache"; echo "$m" > "$GHDIR/mode"
  ghrun refresh
  phase_check wG1 review "$ICON_MR #21" "$m: open PRs still badge"
  phase_check wG3 active "$ICON_BRANCH" "$m: no merged state is invented"
  ghrun refresh
  check "$(gh_calls)" "2" "$m: a half-answered lookup is not cached, so the next run retries"
done
rm -f "$GHDIR/mode"

# Nothing cached and nothing answered: no PR state at all.
rm -rf "$T/cache"; echo fail > "$GHDIR/mode"
ghrun refresh
check "$RC" "0" "refresh survives gh failing with a cold cache"
phase_check wG1 active "$ICON_BRANCH" "a cold cache plus a failed lookup invents no PR state"
rm -f "$GHDIR/mode"

# A valid empty answer is an answer: a closed PR's badge must go, not linger from the cache.
rm -rf "$T/cache"; ghrun refresh
phase_check wG1 review "$ICON_MR #21" "PRECONDITION: the cache warms"
echo '[]' > "$GH_OPEN"; echo '[]' > "$GH_MERGED"
TTL=0 ghrun refresh
phase_check wG1 active "$ICON_BRANCH" "an empty open list replaces the table: #21 goes back to active"
phase_check wG3 active "$ICON_BRANCH" "an empty merged list replaces the table too"
cp "$GH_OPEN.orig" "$GH_OPEN"; cp "$GH_MERGED.orig" "$GH_MERGED"

# The slug comes from a remote URL a sandboxed command can rewrite and reaches gh's -R argument
# under Michael's token. These forms are GitHub's own and make a call; the rest make none.
for good in git@github.com:test/proj3.git https://github.com/test/proj3 \
            https://github.com/test/proj3.git ssh://git@github.com/test/proj3.git; do
  q git -C "$REPO3" remote set-url origin "$good"
  rm -rf "$T/cache"; ghrun refresh
  check "$(grep -c -- '^gh pr list -R github.com/test/proj3 ' "$CALLS")" "2" "remote '$good' is looked up as test/proj3"
done
for bad in git@github.com:a/b/c.git 'https://github.com/a/../b' 'https://github.com/a/b?x=1' \
           git@github.com.evil.com:a/b.git https://evil.com/github.com/a/b \
           'https://github.com/a/b c' 'https://github.com/a/' 'https://github.com//b' 'https://github.com/a/b%2Fc'; do
  q git -C "$REPO3" remote set-url origin "$bad"
  rm -rf "$T/cache"; ghrun refresh
  check "$(grep -c '^gh ' "$CALLS")" "0" "remote '$bad': no gh call"
  phase_check wG1 active "$ICON_BRANCH" "remote '$bad': no PR state"
done
# bash 3.2 resolves a bracket range such as [A-Z] by collation, so under a UTF-8 locale (the one
# Herdr's hooks and keybindings inherit) a range test lets non-ASCII letters through. The slug
# check names its characters one by one instead.
for bad in 'https://github.com/é/b' 'git@github.com:a/ẞ.git' 'https://github.com/a/ｂ'; do
  q git -C "$REPO3" remote set-url origin "$bad"
  rm -rf "$T/cache"; LC_ALL=en_US.UTF-8 ghrun refresh
  check "$(grep -c '^gh ' "$CALLS")" "0" "remote '$bad' under a UTF-8 locale: no gh call"
done
q git -C "$REPO3" remote set-url origin git@github.com:test/proj3.git

# A GitLab test/proj3 and a GitHub test/proj3 in one run: each has its own cache file and its own
# badge, and neither answers for the other.
cat > "$BIN/glab" <<'G'
#!/usr/bin/env bash
echo "glab $*" >> "$CALLS"
if [ "${1:-}" = "api" ]; then echo '{"iid":31,"head_pipeline":null}'; exit 0; fi
case " $* " in
  *" --repo https://gitlab.com/test/proj3 "*) ;;
  *) echo '[]'; exit 0 ;;
esac
case " $* " in
  *" --merged "*) echo '[]' ;;
  *) echo '[{"iid":31,"source_branch":"feature/gl3","state":"opened","draft":false}]' ;;
esac
G
chmod 755 "$BIN/glab"
cat > "$T/ws-both.json" <<J
{"id":"x","result":{"type":"workspace_list","workspaces":[
 {"workspace_id":"wG1","label":"gh-ready","worktree":{"checkout_path":"$REPO3-gh-ready","is_linked_worktree":true,"repo_root":"$REPO3"}},
 {"workspace_id":"wL1","label":"gl3","worktree":{"checkout_path":"$REPO4-gl3","is_linked_worktree":true,"repo_root":"$REPO4"}}
]}}
J
rm -rf "$T/cache"
WSJSON="$T/ws-both.json" run refresh
phase_check wG1 review "$ICON_MR #21" "the GitHub test/proj3 space shows its own PR, with a # prefix"
phase_check wL1 review "$ICON_MR !31" "the GitLab test/proj3 space shows its own MR, with a ! prefix"
check "$(ls "$T/cache" | grep '\.tsv$' | LC_ALL=C sort | tr '\n' ' ')" "github@test%2Fproj3.tsv test%2Fproj3.tsv " \
  "the two forges' tables live in separate cache files"
check "$(grep -c 'feature/gl3' "$T/cache/test%2Fproj3.tsv")" "1" "the GitLab file holds the GitLab table"
check "$(grep -c 'gh-ready' "$T/cache/github@test%2Fproj3.tsv")" "1" "the GitHub file holds the GitHub table"
glab_stub
rm -rf "$T/cache"

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
  for tok in active draft review merged; do
    grep -q "token = \"[\$]$tok\"" "$CONF" \
      && _pass "sidebar renders \$$tok" || _fail "sidebar renders \$$tok"
  done
  grep -q 'parked' "$CONF" && _fail "the sidebar no longer renders \$parked" \
                           || _pass "the sidebar no longer renders \$parked"
  grep -Eq 'pin-parked|"unpin"' "$MANIFEST" && _fail "the plugin no longer offers pin actions" \
                                            || _pass "the plugin no longer offers pin actions"
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
echo "J. a repository's own configuration runs nothing"
# phase.sh runs unsandboxed (the launchd job, herdr's hooks) and a repository's configuration is
# writable from the sandbox. For each linked worktree it runs `git status` and `git rev-list`, and
# these ran: core.fsmonitor; a clean filter (on a file whose stat data differs from the index, so
# git compares content through the filter); the post-index-change hook that the index refresh
# fires, from core.hooksPath and from a git 2.54+ config hook (hook.<name>.event); and, from the
# rev-list over a dangling remote-tracking ref, a promisor remote's uploadpack. Each is a marker
# script that touches a file. Reproduced 2026-10-18 on git 2.54 and 2.56.
rm -rf "$T/cache"
glab_stub

# mkmarkers <name> -> $T/<name>/{repo,wt1,wt2,marks}. wt1 (feature/merged) is clean apart from the
# stat data of two tracked files, so its phase is `merged` (a merged MR, no local work); wt2
# (feature/merged-dirty) has an untracked file, so its phase is `active`. That pair is what
# tells a status that still works from one that was neutered.
mkmarkers() {
  local d="$T/$1" m="$T/$1/marks" c
  mkdir -p "$m" "$d/hooks"
  _mark() { # _mark <name> [body]
    printf '#!/bin/sh\ntouch "%s/%s"\n%bexit 0\n' "$m" "$1" "${2:-}" > "$d/$1"; chmod 755 "$d/$1"; }
  _mark fsmonitor; _mark clean 'cat\n'; _mark cleanxy 'cat\n'; _mark confighook
  _mark inherited; _mark uploadpack 'exit 1\n'
  printf '#!/bin/sh\ntouch "%s/hookspath"\n' "$m" > "$d/hooks/post-index-change"
  chmod 755 "$d/hooks/post-index-change"
  q git init -b main "$d/repo"
  echo gg > "$d/repo/g"; echo hh > "$d/repo/h"; echo base > "$d/repo/f"
  printf 'g filter=m\nh filter=x=y\n' > "$d/repo/.gitattributes"
  q git -C "$d/repo" add .
  q git -C "$d/repo" commit -m base
  q git -C "$d/repo" worktree add -b feature/merged "$d/wt1" main
  q git -C "$d/repo" worktree add -b feature/merged-dirty "$d/wt2" main
  echo untracked > "$d/wt2/new"
  # Configured only now: the blobs and the checkouts above hold the raw content.
  c="$d/repo"
  q git -C "$c" config core.fsmonitor "$d/fsmonitor"
  q git -C "$c" config core.hooksPath "$d/hooks"
  q git -C "$c" config hook.evil.command "$d/confighook"
  q git -C "$c" config hook.evil.event post-index-change
  q git -C "$c" config filter.m.clean "$d/clean"
  q git -C "$c" config "filter.x=y.clean" "$d/cleanxy"
  q git -C "$c" remote add origin git@gitlab.com:test/proj.git
  q git -C "$c" config remote.pm.url "$d/nowhere"
  q git -C "$c" config remote.pm.promisor true
  q git -C "$c" config remote.pm.uploadpack "$d/uploadpack"
  q git -C "$c" config core.repositoryformatversion 1
  q git -C "$c" config extensions.partialClone pm
  # Dangling remote-tracking refs: rev-list over them needs an object that is not there.
  mkdir -p "$c/.git/refs/remotes/origin/feature"
  for _b in merged merged-dirty; do
    printf '1234567890abcdef1234567890abcdef12345678\n' > "$c/.git/refs/remotes/origin/feature/$_b"
  done
  touch -t 200001010000 "$d/wt1/g" "$d/wt1/h" "$d/wt2/g" "$d/wt2/h"
}

# The fixture must fire every marker when git is run bare, or "nothing fired" proves nothing.
mkmarkers raw
q git -C "$T/raw/wt1" status --porcelain
q git -C "$T/raw/wt1" rev-list --count origin/feature/merged..HEAD
for _m in fsmonitor hookspath clean cleanxy uploadpack; do
  [ -e "$T/raw/marks/$_m" ] && _pass "fixture: bare git fires the $_m marker" \
    || _fail "fixture: bare git fires the $_m marker"
done
# The config-based hook needs git 2.54; an older git has nothing to fire.
if [ -e "$T/raw/marks/confighook" ]; then _pass "fixture: bare git fires the confighook marker"
else echo "  note: git $(git --version | awk '{print $3}') ignores hook.<name>.command; confighook not exercised"; fi

mkmarkers live
M="$T/live/marks"
cat > "$T/ws-markers.json" <<J
{"id":"x","result":{"type":"workspace_list","workspaces":[
 {"workspace_id":"w20","label":"m1","worktree":{"checkout_path":"$T/live/wt1","is_linked_worktree":true,"repo_root":"$T/live/repo"}},
 {"workspace_id":"w21","label":"m2","worktree":{"checkout_path":"$T/live/wt2","is_linked_worktree":true,"repo_root":"$T/live/repo"}}
]}}
J
# launchd's environment: nothing inherited, the system PATH, Apple's git and bash 3.2.
launchd_run() { # launchd_run [VAR=value ...]
  rm -f "$M"/*; : > "$CALLS"
  OUT=$(env -i HOME="$T" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        PINNED_PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" CALLS="$CALLS" \
        WSJSON="$T/ws-markers.json" MROPEN="$MROPEN" MRMERGED="$MRMERGED" \
        HERDR_PHASE_CACHE_DIR="$T/cache" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "$@" /bin/bash "$PHASE" refresh 2>&1); RC=$?
}
launchd_run
check "$RC" "0" "refresh exits 0 in launchd's environment"
check "$(ls "$M" | tr '\n' ' ')" "" "no fsmonitor, filter, hook or uploadpack ran"
case "$(report_for w20)" in *"--token merged=$ICON_MERGE !12"*) _pass "a stat-only change is not dirty: merged";;
  *) _fail "a stat-only change is not dirty: merged (got: $(report_for w20); $OUT)";; esac
case "$(report_for w21)" in *"--token active=$ICON_BRANCH"*) _pass "an untracked file is still dirty: active";;
  *) _fail "an untracked file is still dirty: active (got: $(report_for w21))";; esac

# Overrides inherited from the caller (GIT_CONFIG_COUNT with its pairs, GIT_CONFIG_PARAMETERS)
# must neither win over ours nor shift them. A well-formed count: the other git calls here
# (rev-parse, rev-list) read the inherited environment as it is, and die on a malformed one.
launchd_run GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="$T/live/inherited" \
  GIT_CONFIG_PARAMETERS="'core.fsmonitor=$T/live/inherited'"
check "$(ls "$M" | tr '\n' ' ')" "" "inherited GIT_CONFIG_COUNT/KEY/VALUE/PARAMETERS run nothing"
case "$(report_for w20)" in *"--token merged=$ICON_MERGE !12"*) _pass "the phase is unchanged with inherited overrides";;
  *) _fail "the phase is unchanged with inherited overrides (got: $(report_for w20))";; esac

# And from the suite's own environment, which is how a hook-run refresh looks.
rm -f "$M"/*
WSJSON="$T/ws-markers.json" run refresh
check "$(ls "$M" | tr '\n' ' ')" "" "a refresh from the suite's environment runs nothing either"

# The pin. phase.sh runs outside the sandbox (launchd, herdr's hooks and keybindings), so the
# PATH of whoever started it must not decide which git, herdr, glab or bash it runs (spec
# 2026-10-16, sandbox write boundary). A scratch copy runs through its own shebang with a
# hostile directory first on PATH, holding a marker-writing stub for every tool it could reach;
# no marker may appear. The suite's stubs reach it through PINNED_PATH, as in every run above.
echo
echo "C. the pinned PATH"
HOSTILE="$T/hostile"; HM="$T/hostile-marks"; mkdir -p "$HOSTILE" "$HM"
printf '#!/bin/sh\necho "${0##*/}" >> "%s/marker"\nexit 0\n' "$HM" > "$HOSTILE/.marker"
chmod 755 "$HOSTILE/.marker"
for _t in git herdr bash zsh python3 jq glab gh awk cut tr sort stat date; do ln -s .marker "$HOSTILE/$_t"; done
marked() { if [ -e "$HM/marker" ]; then tr '\n' ' ' < "$HM/marker"; else printf clean; fi; }
cp "$PHASE" "$T/phase-pinned.sh"; chmod 755 "$T/phase-pinned.sh"

check "$(head -1 "$PHASE")" "#!/bin/bash" "phase.sh has an absolute shebang"
check "$(grep -v '^[[:space:]]*#' "$PHASE" | grep . | head -1)" \
  'PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH' \
  "phase.sh pins its PATH as its first command"

rm -f "$HM/marker"
OUT=$(env -i HOME="$T" PATH="$HOSTILE:/usr/bin:/bin" "$T/phase-pinned.sh" --help 2>&1); RC=$?
check "$RC" "0" "--help runs with a hostile PATH and no PINNED_PATH"
check "$(marked)" "clean" "a hostile PATH runs none of the hostile tools, bash included"

# A whole refresh, through the status, the MR lookup, herdr and both Python calls, with the
# hostile directory first on the caller's PATH and the suite's stubs behind PINNED_PATH.
rm -f "$M"/* "$HM/marker"; : > "$CALLS"
OUT=$(env -i HOME="$T" PATH="$HOSTILE:$BIN:/usr/bin:/bin" \
      PINNED_PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" CALLS="$CALLS" \
      WSJSON="$T/ws-markers.json" MROPEN="$MROPEN" MRMERGED="$MRMERGED" \
      HERDR_PHASE_CACHE_DIR="$T/cache-hostile" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      "$T/phase-pinned.sh" refresh 2>&1); RC=$?
check "$RC" "0" "refresh exits 0 with a hostile directory first on the caller's PATH"
case "$(report_for w20)" in *"--token merged=$ICON_MERGE !12"*) _pass "the refresh still derived and reported a phase";;
  *) _fail "the refresh still derived and reported a phase (got: $(report_for w20); $OUT)";; esac
check "$(marked)" "clean" "a refresh runs none of the hostile tools"

# The same for a GitHub repository, which is the only way a hostile gh would ever be reached.
rm -f "$HM/marker"; : > "$CALLS"
OUT=$(env -i HOME="$T" PATH="$HOSTILE:$BIN:/usr/bin:/bin" \
      PINNED_PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" CALLS="$CALLS" \
      WSJSON="$T/ws-gh.json" HERDR_PHASE_CACHE_DIR="$T/cache-hostile-gh" \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      "$T/phase-pinned.sh" refresh 2>&1); RC=$?
check "$RC" "0" "a GitHub refresh exits 0 with a hostile directory first on the caller's PATH"
phase_check wG1 review "$ICON_MR #21" "the GitHub refresh still reached the pinned gh and reported a phase"
check "$(marked)" "clean" "a GitHub refresh runs none of the hostile tools, gh included"

# The two Python calls run isolated: the current directory (a repository) is not on sys.path.
# The fixture must bite first, or "no import" proves nothing.
PYH="$T/pyhostile"; mkdir -p "$PYH"
printf 'open("%s/imported", "a").close()\n' "$HM" > "$PYH/json.py"
rm -f "$HM/imported"
( cd "$PYH" && /usr/bin/python3 -c 'import json' >/dev/null 2>&1 )
[ -e "$HM/imported" ] && _pass "fixture: a bare python3 imports a json.py from the current directory" \
  || _fail "fixture: a bare python3 imports a json.py from the current directory"
rm -f "$HM/imported" "$HM/marker"; rm -rf "$T/cache-hostile"; : > "$CALLS"
( cd "$PYH" && env -i HOME="$T" PATH="$BIN:/usr/bin:/bin" PINNED_PATH="$BIN:/usr/bin:/bin" CALLS="$CALLS" \
    WSJSON="$T/ws-markers.json" MROPEN="$MROPEN" MRMERGED="$MRMERGED" \
    HERDR_PHASE_CACHE_DIR="$T/cache-hostile" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$T/phase-pinned.sh" refresh >/dev/null 2>&1 )
[ -e "$HM/imported" ] && _fail "a module in the current directory is not imported" \
  || _pass "a module in the current directory is not imported"
case "$(report_for w20)" in *"--token merged=$ICON_MERGE !12"*) _pass "the isolated Python calls still produce the report";;
  *) _fail "the isolated Python calls still produce the report (got: $(report_for w20))";; esac

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
