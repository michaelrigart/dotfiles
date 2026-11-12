#!/bin/bash
# Badge Herdr spaces with where a worktree sits between "I'm working on this" and "this is
# waiting to be merged". Managed by chezmoi (source: dot_config/herdr/executable_phase.sh).
#
# Tokens do NOT survive a Herdr server restart, so this script alone keeps the badges alive. One
# `herdr workspace report-metadata` call per space sets one phase token (active, draft, review,
# merged) and, beside an open MR or PR, one pipeline token (ci_ok, ci_fail, ci_run), clears the rest.
#
# Driven by the dev.phase plugin's startup and workspace/worktree hooks, and by a LaunchAgent
# running `refresh --force` every 50 s. The timer is not redundant: opening or merging an MR fires
# no Herdr event. It must not be throttled (no ProcessType=Background or LowPriorityIO): a run that
# outlasts its interval makes launchd skip cycles while reporting exit code 0.
#
# Freshness: --force (the timer) looks every repository up now; --fresh (a focus refresh) does too
# unless its stamp <key>.lookup is under FRESH_GAP (10 s) old, then it answers from the cache; the
# other hooks use the 120 s TTL.
#
# Structure: `refresh` becomes `/usr/bin/timeout -s KILL $RUN_DEADLINE`, which runs the worker
# (`_refresh`) in a process group of its own. The worker takes one run lock
# ($CACHE_DIR/run.lock, fd 9, /usr/bin/lockf, LOCK_WAIT s, else it skips), sweeps stale +tmp.*
# files, starts one background job per repository and waits. Everything but the bounded calls
# inherits fd 9, so the lock is free when the last such process exits. The deadline covers the lock
# wait, and a cache write is a rename of a temporary file beside its target, so a KILL at any point
# leaves the previous file. Every glab, gh and herdr call also runs under its own timeout from the
# run's start, in a process group of its own and without fd 9: forge calls are cut CALL_MARGIN s
# before the deadline (a hung one falls back to the cache and the job reports), herdr calls at the
# deadline. The outer KILL or a forwarded TERM does not reach a call; its own bound ends it.
#
# Accepted failure modes (each costs stale badges until its cause ends):
#   - INT (a person at a terminal; launchd sends TERM): bash ignores INT in `&` jobs when job control
#     is off, so it ends timeout and the worker but not the jobs, which hold the lock until their
#     calls are cut, about the run's deadline at most (whole seconds can add one). The same holds
#     for a KILL of `timeout`, and for any job that outlives the worker. TERM and HUP end timeout,
#     the worker and the jobs and free the lock at once; a call in flight lives on, in its own group
#     and without the lock, until its bound.
#   - A hung local git or file operation outlasts every bound: an intact run's outer deadline ends
#     it, but in an orphaned job it holds the lock until it ends. A process a call leaves behind
#     (the CLI exited, so its timeout cut nothing) that keeps the call's stdout open blocks its
#     job, and in an orphaned job the lock, until it exits.
#   - A job cut at the deadline leaves some spaces on their previous badge (a report is one call).
#   - The caller's environment reaches the script (overrides, BASH_ENV, exported functions, glab's
#     variables), unlike gh, which runs under `env -i`.
#   - A partial answer (the merged half failed) is published but not cached.
#
# Runs outside the sandbox (launchd, herdr's hooks and keybindings), so it resolves nothing a
# sandboxed command can write (spec 2026-10-16, sandbox write boundary): an absolute shebang,
# the system bash 3.2 (SIP-protected, and what the launchd suite case already runs), and a
# pinned PATH that no caller's direnv or mise entry reaches. PINNED_PATH is for the suite only.
PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
set -u

# glab reads the current directory's repository (its .git/glab-cli/config.yml, and it runs git
# there), and a caller's directory is whatever a key command or plugin hook happened to have: a
# repository a sandboxed command can write. Every path below is absolute and git runs with -C.
cd / || exit 2

SOURCE_ID="herdr-phase"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-phase"

# phase.sh runs inside a pane, where HERDR_SOCKET_PATH outranks HERDR_SESSION, so thread
# --session rather than let the pane's socket pick the session (see AGENTS.md).
HERDR_ARGS=""
[ -n "${HERDR_SESSION:-}" ] && HERDR_ARGS="--session $HERDR_SESSION"
TTL=120
STALE_PIPELINE=1800   # seconds a cached pipeline status may stand in for a failed lookup
FRESH_GAP=10          # seconds a --fresh refresh trusts the cache after a lookup of the repository began
CALL_MARGIN=5         # seconds before the run deadline at which forge calls are cut, so a job can still fall back to its cache and report
LOCK_WAIT="${HERDR_PHASE_LOCK_WAIT-10}"   # seconds the worker waits for the run lock; lockf takes it as given
RUN_DEADLINE="${HERDR_PHASE_RUN_DEADLINE-40}"   # seconds a run lasts at most, lock wait included; refresh checks it

# Nerd Font private-use codepoints, written as escapes because literals do not survive every
# editor and pipeline.
ICON_BRANCH=$(printf '\xee\xb1\xaf')   # U+EC6F cod-git_branch
ICON_MR=$(printf '\xee\xa9\xa4')       # U+EA64 cod-git_pull_request
ICON_DRAFT=$(printf '\xee\xaf\x9b')    # U+EBDB cod-git_pull_request_draft
ICON_MERGE=$(printf '\xee\xab\xbe')    # U+EAFE cod-git_merge
CI_OK=$(printf '\xee\xaa\xb2')         # U+EAB2 cod-check
CI_FAIL=$(printf '\xee\xa9\xb6')       # U+EA76 cod-close
CI_RUN=$(printf '\xee\xa9\xb7')        # U+EA77 cod-sync

# jq reads ~/.jq at start, and a sandboxed command can write it: a `def fromjson: ...` there would
# replace the builtin every parse below calls. It runs with HOME=/var/empty, so nothing is read.
jqi() { HOME=/var/empty /usr/bin/jq "$@"; }

# This runs unsandboxed (launchd, herdr's hooks) in worktrees whose repository configuration is
# writable from the sandbox. A partial clone's lazy fetch would run remote.<name>.uploadpack,
# which that configuration names, so no git call below may fetch; `rev-list` over a missing
# object then fails and counts as 0 ahead.
export GIT_NO_LAZY_FETCH=1

# `git status` on a stat-dirty file would run core.fsmonitor and every clean filter, and
# refresh the index, which fires the post-index-change hook from core.hooksPath and, on git 2.54
# and later, from any hook.<name>.command with hook.<name>.event=post-index-change. So the status
# runs with --no-optional-locks (no index write, hence no hook of any source), the monitor and
# each configured filter driver switched off, and hooks pointed at nothing. The overrides travel
# as GIT_CONFIG_KEY_n/VALUE_n pairs, never `-c`: git splits `-c key=value` at the first "=", so a
# driver named "x=y" would survive it. The inherited GIT_CONFIG_COUNT, GIT_CONFIG_KEY_*/VALUE_*
# and GIT_CONFIG_PARAMETERS are removed first (git reads PARAMETERS after our pairs, and bash
# reads a count such as 010 as octal), and ours are numbered from 0. Mirrors xreview's cmd_apply.
set_cfg() { # set_cfg <key> <value> - appends to the caller's `ge` array and `gn` counter
  ge+=("GIT_CONFIG_KEY_$gn=$1" "GIT_CONFIG_VALUE_$gn=$2"); gn=$((gn + 1))
}
repo_status() { # repo_status <checkout_path> -> porcelain status, nothing from config run
  local path="$1" k d v seen=$'\n' gn=0
  local -a ge=() unset_args=(-u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS)
  while IFS= read -r v; do
    case $v in GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) unset_args+=(-u "$v") ;; esac
  done < <(compgen -e)
  set_cfg core.fsmonitor false
  set_cfg core.hooksPath /dev/null
  # The driver name is everything between "filter." and the last "." (it may hold dots or "=");
  # -z ends each name with a NUL, so no name is cut at a newline or a space.
  while IFS= read -r -d '' k; do
    d=${k#filter.}
    [[ $d == *.* ]] || continue
    d=${d%.*}
    [[ $seen == *$'\n'"$d"$'\n'* ]] && continue
    seen+="$d"$'\n'
    set_cfg "filter.$d.clean" ""; set_cfg "filter.$d.smudge" ""; set_cfg "filter.$d.process" ""
    set_cfg "filter.$d.required" false
  done < <(git -C "$path" config -z --name-only --get-regexp '^filter\.' 2>/dev/null)
  env "${unset_args[@]}" "${ge[@]}" "GIT_CONFIG_COUNT=$gn" \
    git --no-optional-locks -C "$path" status --porcelain --ignore-submodules=all 2>/dev/null
}

# No here-documents in this script: bash 3.2 writes each to a temp file, and from a "/" working
# directory a sandboxed run (the suite) cannot create it. Plain strings need no file.
usage() {
  printf '%s\n' \
    'phase.sh — badge Herdr spaces with their merge phase' \
    '' \
    '  phase.sh refresh [--force | --fresh] [--workspace ID]   report phases (all spaces, or one)' \
    '      --force  look every repository up now' \
    "      --fresh  look up now, unless that repository was looked up in the last $FRESH_GAP s" \
    '  phase.sh --help' \
    '' \
    'Phases: active, draft, review, merged.'
}

die() { echo "phase.sh: $*" >&2; exit 2; }

# timeout reads a duration of 0 as no limit, and a run must never be unbounded. The digits are
# listed, as in slug_chars_ok: under a UTF-8 locale bash 3.2 lets U+2185 through the range [0-9].
# The worker does arithmetic on the value, so `refresh` and `_refresh` both check it.
require_deadline() {
  case "$RUN_DEADLINE" in ''|*[!0123456789]*|0*) die "HERDR_PHASE_RUN_DEADLINE is not a positive whole number of seconds" ;; esac
}

# Every external call (glab, gh, herdr) runs under its own timeout, measured from the run's start, so
# an orphaned job (an INT ends timeout and the worker but not the jobs) cannot hold the run lock
# beyond the deadline through a call, the two escapes the header names aside (a hung local git or
# file operation; a process a call leaves behind with its stdout open). The call gets a process
# group of its own (timeout without --foreground) and the KILL at its bound, which cannot be
# ignored, takes the whole group: what gh or glab start (a credential helper, git) dies with it. It
# has no fd 9, so nothing a call starts can hold the run lock, and no stdin, so a call in a
# background group cannot stop on the terminal. The call is thereby out of reach of the run's outer
# KILL or a forwarded TERM: its own bound ends it. A cut call is a failed call, and the
# failed-lookup paths handle it. Forge calls end at CALL_END, CALL_MARGIN before the run deadline;
# herdr calls at RUN_END, the deadline itself, so a job whose forge call was cut still reports.
bounded() { # bounded <end: epoch seconds> <command...>
  local left=$(( $1 - $(date +%s) ))
  shift
  [ "$left" -gt 0 ] || return 124
  /usr/bin/timeout -s KILL "$left" "$@" </dev/null 9>&-
}

# ------------------------------------------------------------------ MR state
# One lookup per repo, cached as a small table so the per-worktree path stays a grep.
# Prints nothing and fails when the repo is on neither GitLab nor GitHub or the lookup did not work.

# Whether a slug holds only [A-Za-z0-9._/-]. The characters are listed one by one: bash 3.2
# resolves a bracket range such as [A-Z] by collation, so under a UTF-8 locale (the one Herdr's
# hooks and keybindings inherit) a range lets "é", "ẞ" and fullwidth letters through.
slug_chars_ok() { # slug_chars_ok <slug>
  case "$1" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-]*) return 1 ;;
  esac
}
repo_slug() { # repo_slug <repo_root> -> "<forge> <slug>" on stdout (gitlab or github), or fails
  local url slug
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  # The three GitHub forms are matched on their exact prefix before the GitLab test, so a host
  # that merely contains "github.com" (github.com.evil.com, evil.com/github.com/...) is neither.
  case "$url" in
    git@github.com:*) slug="${url#git@github.com:}" ;;
    https://github.com/*) slug="${url#https://github.com/}" ;;
    ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
    *)
      case "$url" in *gitlab.com*) ;; *) return 1 ;; esac
      slug="${url#*gitlab.com}"; slug="${slug#:}"; slug="${slug#/}"; slug="${slug%.git}"
      [ -n "$slug" ] || return 1
      # The remote URL is repository configuration, which a sandboxed command can rewrite, and the
      # slug lands in glab's repository argument and in an API path under Michael's token: accept
      # only a plain group/project path, so nothing can leave the project's own path.
      slug_chars_ok "$slug" || return 1
      case "$slug" in *..*) return 1 ;; esac
      printf 'gitlab %s\n' "$slug"
      return 0
      ;;
  esac
  slug="${slug%.git}"
  # The same applies to gh's -R argument: exactly owner/repo, each part from [A-Za-z0-9._-]+,
  # no "..", and no part that is a bare ".".
  slug_chars_ok "$slug" || return 1
  case "$slug" in
    */*/*|/*|*/|*..*|./*|*/.) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  printf 'github %s\n' "$slug"
}

# glab takes the host from the current directory's git repository, whose configuration a
# sandboxed command can rewrite, and this runs unsandboxed with a token. Both calls therefore
# name the host: `api` through --hostname, and `mr list` through a full URL for --repo (measured
# with glab: HOST/OWNER/REPO is read as a namespace, the https:// form pins the host).
GITLAB_HOST_NAME="gitlab.com"

# repo_slug admits no "%", so encoding "/" as %2F maps each slug to its own file name: a "_"
# replacement made a/b_c and a_b/c share one. GitHub keys carry a "github@" prefix, a character no
# GitLab slug can hold, so a GitHub o/r never meets a GitLab o/r, and GitLab's names stay as they were.
cache_key() { # cache_key <forge> <slug>
  local key
  key="$(printf '%s' "$2" | sed 's|/|%2F|g')"
  if [ "$1" = "github" ]; then printf 'github@%s' "$key"; else printf '%s' "$key"; fi
}

# One rule for how old a cache file is: seconds since its mtime. A missing file is as old as can be,
# and so is one dated in the future (the clock stepped back): it is evidence of nothing recent.
age_of() { # age_of <file>
  local mtime age
  mtime="$(stat -f %m "$1" 2>/dev/null)"
  [ -n "$mtime" ] || { echo 999999999; return 0; }
  age=$(( $(date +%s) - mtime ))
  if [ "$age" -ge 0 ]; then echo "$age"; else echo 999999999; fi
}

# Replaces a cache file atomically: a temporary file beside it (same filesystem, fixed +tmp. prefix
# for the worker's sweep), then a rename onto the target. A run killed mid-write leaves the previous
# file, never half of a new one that would later read as a valid, shorter table.
write_cache() { # write_cache <file> <content>
  local tmp
  tmp="$(mktemp "$CACHE_DIR/+tmp.XXXXXX")" || return 1
  if printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# Prints a cached table. GitHub's CI (column 5) is blanked once the file is older than
# STALE_PIPELINE, the age limit GitLab's pipeline cache has: a stale answer to a failed lookup must
# not keep showing a check result nobody has confirmed.
read_table() { # read_table <cache_file>
  local cache="$1"
  if [ "$(age_of "$cache")" -lt "$STALE_PIPELINE" ]; then cat "$cache"
  else awk -F'\t' -v OFS='\t' 'NF >= 5 { $5 = "" } { print }' "$cache"; fi
}

# The table: one row per branch, `branch<TAB>opened|merged<TAB><number><TAB>0|1[<TAB><ci>]`.
# <ci> (ok, fail, run or empty) is a GitHub column only, empty on a merged row.
# <mode> is ttl (look up once the cache is older than TTL), force (always look up) or cached (never
# call out: answer as a failed lookup would). A lookup that cannot answer falls back to the cached
# table: the phases stand however old it is, but read_table drops GitHub's CI column once it is
# older than STALE_PIPELINE. Every lookup writes the repository's stamp first (see the header).
mr_table() { # mr_table <forge> <slug> <mode: ttl|force|cached>
  local forge="$1" slug="$2" mode="$3" key cache rows rc

  key="$(cache_key "$forge" "$slug")"
  cache="$CACHE_DIR/$key.tsv"
  if [ "$mode" = "ttl" ] && [ -f "$cache" ]; then
    if [ "$(age_of "$cache")" -lt "$TTL" ]; then read_table "$cache"; return 0; fi
  fi

  # <forge>_rows exits 0 for a full answer, 3 for the open rows alone (the merged half failed:
  # use them, do not cache them) and anything else for a failed lookup. A failed lookup is not
  # evidence that the MRs went away: returning nothing would wipe every review badge at once, so
  # a stale table beats a table asserted to be empty.
  if [ "$mode" = "cached" ]; then rows=""; rc=1
  else
    write_cache "$CACHE_DIR/$key.lookup" "" || true
    rows="$("${forge}_rows" "$slug")"; rc=$?
  fi
  case "$rc" in
    0) write_cache "$cache" "$rows" ;;
    3) ;;
    *)
      if [ -f "$cache" ]; then read_table "$cache"; return 0; fi
      return 1
      ;;
  esac
  printf '%s\n' "$rows"
}

gitlab_rows() { # gitlab_rows <slug> -> table rows; 0 full, 3 open rows only, else failed
  local slug="$1" open_json merged_json
  # Two queries, not one: `glab mr list` caps --per-page at 100 and this never paginates, so
  # a single --all query drops the oldest rows once a repo passes 100 MRs. The OPEN list on
  # its own keeps the rows a review badge depends on far from the cap.
  open_json="$(bounded "$CALL_END" glab mr list --repo "https://$GITLAB_HOST_NAME/$slug" --output json --per-page 100 2>/dev/null)" || open_json=""
  [ -n "$open_json" ] || return 1
  # Merged state is best-effort: if only this half fails the open rows still stand, and the
  # table is not cached, so the miss lasts one cycle instead of a TTL.
  local cacheable=1
  merged_json="$(bounded "$CALL_END" glab mr list --repo "https://$GITLAB_HOST_NAME/$slug" --merged --output json --per-page 100 2>/dev/null)" || merged_json=""
  [ -n "$merged_json" ] || { merged_json="[]"; cacheable=0; }

  # Each answer reaches jq as a file of its own (a pipe from printf, never an argument: an answer can
  # outgrow the argument list), parsed on its own: one that does not parse fails the lookup, a
  # document that is not a list adds no rows, a row that is not an object fails it too, and a row
  # without a source_branch is skipped. Any non-zero status fails the lookup. An open MR is the live
  # one for a branch; anything else only fills a gap, so a branch reused after a merge still reports
  # the MR that is actually open on it. Rows keep the order in which their branch was first seen.
  jqi -nr --rawfile open <(printf '%s' "$open_json") --rawfile merged <(printf '%s' "$merged_json") '
def bad: "" | halt_error(1);
def falsy: . == null or . == false or . == 0 or . == "" or . == [] or . == {};
def text: if type == "string" then . else bad end;
def answer: try (fromjson | [.]) catch null;
($open | answer) as $a | ($merged | answer) as $b
| if $a == null or $b == null then bad else . end
| reduce (($a[0], $b[0]) | arrays[]) as $m ({pos: {}, out: []};
    if ($m | type) != "object" then bad
    elif ($m.source_branch | falsy) then .
    else ($m.source_branch | text) as $k
      | if .pos[$k] == null then .pos[$k] = (.out | length) | .out += [$m]
        elif $m.state == "opened" then .out[.pos[$k]] = $m
        else . end
    end)
| .out[]
| [.source_branch, (.state | if falsy then "" else text end),
   (.iid | if falsy then "" elif type == "string" then . else tostring end),
   (if (.draft | falsy) then "0" else "1" end)]
| join("\t")
' 2>/dev/null || return 1
  [ "$cacheable" = "1" ] || return 3
}

# gh gets the environment launchd gives it (HOME and PATH), the one it was measured to authenticate
# in: a Herdr server started under direnv or mise carries GH_CONFIG_DIR, GH_HOST, GH_TOKEN, a proxy
# or a CA bundle into its hooks, and none of them may steer a call made under Michael's token.
# -R names the host (gh otherwise reads the current directory's repository) and the call runs
# from "/". The open query also asks for statusCheckRollup, for the CI badge; the merged one does
# not (measured: 5.1 s and 240 KB with it, 0.54 s without).
github_rows() { # github_rows <slug> -> table rows; 0 full, 3 open rows only, else failed
  local slug="$1" open_json merged_json rc
  open_json="$(bounded "$CALL_END" env -i HOME="$HOME" PATH="$PATH" gh pr list -R "github.com/$slug" --state open --limit 100 \
    --json headRefName,state,number,isDraft,isCrossRepository,statusCheckRollup 2>/dev/null)" || return 1
  # Each status is taken on its own, never through a pipe into the parser. The merged half is
  # best-effort, as on GitLab: "null" stands for a failed call and the parser reads it as not
  # being a list.
  merged_json="$(bounded "$CALL_END" env -i HOME="$HOME" PATH="$PATH" gh pr list -R "github.com/$slug" --state merged --limit 100 \
    --json headRefName,state,number,isDraft,isCrossRepository 2>/dev/null)" || merged_json="null"

  # jq exits 10 when the rows are the open ones alone, because the merged answer is not a list, and
  # that maps to 3; 0 maps to 0 and every other status is a failed lookup, the open answer not being
  # a list among them. 10 is a status jq never uses itself (it exits 2, 3 and 5 for usage, compile
  # and runtime errors), so a broken program cannot pass for a partial answer. A row is dropped
  # unless it is a PR of this repository (a fork's branch name is not this checkout's branch) with a
  # branch name that holds no tab or newline and a whole number. OPEN is "opened", MERGED is
  # "merged", CLOSED has no badge, and an open PR beats a merged one on the same branch.
  # Each answer reaches jq as a file of its own (see gitlab_rows), parsed on its own, so an empty
  # answer can never let the other one take its place. jq cannot tell 12, 12.0 and 12e0 apart, so a
  # number written 12.0 is #12.
  # gh lists the newest first, so the first PR of a state is the one that counts.
  # An open PR's CI comes from its rollup, in gh pr checks' buckets: a CheckRun's state is its
  # conclusion once COMPLETED and its status before; a StatusContext's is its state. Fail beats
  # pending, pending beats success, and a state in no bucket (STALE, say) gives no badge.
  jqi -nr --rawfile open <(printf '%s' "$open_json") --rawfile merged <(printf '%s' "$merged_json") '
def fail: ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"];
def pend: ["QUEUED", "IN_PROGRESS", "PENDING", "EXPECTED", "REQUESTED", "WAITING"];
def good: ["SUCCESS", "SKIPPED", "NEUTRAL"];
def state: if type != "object" then null
  elif has("state") then .state
  elif .status == "COMPLETED" then .conclusion
  else .status end;
def ci: if type != "array" or length == 0 then ""
  else [.[] | state | if type == "string" then . else "" end] as $s
    | if any($s[]; IN(fail[])) then "fail"
      elif any($s[]; IN(pend[])) then "run"
      elif all($s[]; IN(good[])) then "ok"
      else "" end
  end;
def answer: (try fromjson catch null) | if type == "array" then . else null end;
def firsts: reduce .[] as $r ({seen: {}, out: []};
    if .seen[$r.b] then . else .seen[$r.b] = true | .out += [$r] end) | .out;
($open | answer) as $a | ($merged | answer) as $b
| if $a == null then "" | halt_error(1) else . end
| [($a[], ($b // [])[])
    | select(type == "object" and (.state == "OPEN" or .state == "MERGED") and .isCrossRepository == false)
    | select(.headRefName | type == "string" and length > 0 and (contains("\t") or contains("\n") | not))
    | select(.number | type == "number" and . >= 1 and . == floor)
    | {s: .state, b: .headRefName, n: (.number | floor | tostring),
       d: (if .isDraft == true then "1" else "0" end),
       c: (if .state == "OPEN" then (.statusCheckRollup | ci) else "" end)}] as $prs
| ($prs | map(select(.s == "OPEN")) | firsts) as $open_rows
| (reduce $open_rows[] as $r ({}; .[$r.b] = true)) as $taken
| (($prs | map(select(.s == "MERGED")) | firsts | map(select($taken[.b] | not))) as $merged_rows
  | ($open_rows | map(. + {s: "opened"})) + ($merged_rows | map(. + {s: "merged"}))
  | .[] | [.b, .s, .n, .d, .c] | join("\t")),
  (if $b == null then "" | halt_error(10) else empty end)
' 2>/dev/null
  rc=$?
  case "$rc" in 0) return 0 ;; 10) return 3 ;; *) return 1 ;; esac
}

# The list endpoint carries no head_pipeline, so the status costs one call per open MR. It is
# cached per repo AND iid: a branch reused after a merge gets a new MR number and must not show
# the old MR's pipeline. Prints ok, fail or run, or nothing (no pipeline, a status that is not
# a badge, or no answer at all).
pipeline_class() { # pipeline_class <slug> <iid> <mode: ttl|force|cached>
  local slug="$1" iid="$2" mode="$3" key cache status json
  # The digits are listed: a range such as [0-9] is resolved by collation (see slug_chars_ok).
  case "$iid" in ''|*[!0123456789]*) return 0 ;; esac

  key="$(cache_key gitlab "$slug")"
  cache="$CACHE_DIR/$key.mr$iid.pipeline"
  status=""
  if [ "$mode" = "ttl" ] && [ -f "$cache" ]; then
    if [ "$(age_of "$cache")" -lt "$TTL" ]; then status="$(cat "$cache")"; fi
  fi
  if [ -z "$status" ]; then
    if [ "$mode" != "cached" ]; then
      write_cache "$CACHE_DIR/$key.lookup" "" || true
      # glab prints an API error's JSON body on stdout and exits non-zero (a 401, 404, 429 or
      # 5xx), so its status is taken on its own, never through a pipe into the parser. An empty
      # status is a failed call or a body that is not this MR; a pipeline-less MR prints "none".
      json="$(bounded "$CALL_END" glab api --hostname "$GITLAB_HOST_NAME" \
        "projects/$(printf '%s' "$slug" | sed 's|/|%2F|g')/merge_requests/$iid" 2>/dev/null)" || json=""
      if [ -n "$json" ]; then
        # \A and \z, not ^ and $: those match at a line break, so "ok<newline>x" would pass.
        status="$(jqi -nr --rawfile json <(printf '%s' "$json") --arg iid "$iid" '
(try ($json | fromjson) catch null) as $d
| if ($d | type) != "object" or ($d.iid | if type == "number" and . == floor then floor | tostring else tostring end) != $iid then "" | halt_error(1) else . end
| ($d.head_pipeline | if type == "object" then .status else null end) as $s
| if ($s | type) == "string" and ($s | test("\\A[a-z_]{1,40}\\z")) then $s else "none" end
' 2>/dev/null)" || status=""
      fi
      [ -z "$status" ] || write_cache "$cache" "$status"
    fi
    if [ -z "$status" ] && [ -f "$cache" ]; then
      # A failed call (or none, in cached mode) is not evidence that the pipeline went away, so a
      # stale status beats none, but only for a while: a cached "run" glyph would otherwise stay
      # on for as long as glab keeps failing. Past STALE_PIPELINE the tokens are cleared.
      if [ "$(age_of "$cache")" -lt "$STALE_PIPELINE" ]; then status="$(cat "$cache")"; fi
    fi
  fi

  case "$status" in
    success) echo ok ;;
    failed) echo fail ;;
    running|pending|created|preparing|waiting_for_resource|scheduled) echo run ;;
  esac
}

# ------------------------------------------------------------------ derivation
# Prints "<phase> <value>" for one checkout, and "open <number>" on a second line when the
# branch's MR or PR is open (draft or not), with " <ci>" after it when the table's fifth column
# holds one; a draft's phase is draft. The ref is !<iid> on GitLab and #<number> on GitHub, by the
# forge argument. Order matters: an open MR outranks every local signal; local work outranks a
# merged MR.
derive() { # derive <checkout_path> <repo_root> <mr_table> <forge>
  local path="$1" root="$2" table="$3" forge="$4" branch base row state iid draft ci ref='!'
  [ "$forge" != "github" ] || ref='#'

  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)" || { echo none; return 0; }

  state=""; iid=""; draft=""; ci=""
  # Whole-field equality, not a substring search: `grep -F` collides in both directions
  # (`mr-suffix` inside `owner/mr-suffix`, `feature/rev` against `feature/review`). The
  # branch travels in the environment, not `awk -v`, which processes escape sequences.
  row="$(printf '%s\n' "$table" | B="$branch" awk -F'\t' 'BEGIN{b=ENVIRON["B"]} $1==b {print; exit}')"
  if [ -n "$row" ]; then
    state="$(printf '%s' "$row" | cut -f2)"
    iid="$(printf '%s' "$row" | cut -f3)"
    draft="$(printf '%s' "$row" | cut -f4)"
    ci="$(printf '%s' "$row" | cut -f5)"
  fi

  # An open MR outranks everything git can see locally: it says somebody else is waiting on
  # this branch, and an untracked file or an unpushed review fix does not change that.
  if [ "$state" = "opened" ]; then
    if [ "$draft" = "1" ]; then printf 'draft %s %s%s\n' "$ICON_DRAFT" "$ref" "$iid"
    else printf 'review %s %s%s\n' "$ICON_MR" "$ref" "$iid"; fi
    printf 'open %s%s\n' "$iid" "${ci:+ $ci}"
    return 0
  fi

  if [ -n "$(repo_status "$path")" ]; then
    printf 'active %s\n' "$ICON_BRANCH"; return 0
  fi

  base="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  [ -n "$base" ] || base="origin/main"

  # Unpushed work is still yours. Without a remote branch, compare against the base.
  local ahead
  if git -C "$path" rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
    ahead="$(git -C "$path" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
  else
    ahead="$(git -C "$path" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
  fi
  if [ "${ahead:-0}" -gt 0 ]; then printf 'active %s\n' "$ICON_BRANCH"; return 0; fi

  # Merged stays BELOW the local tests, unlike opened: once landed, nobody is waiting, so
  # new work in that worktree is new work.
  if [ "$state" = "merged" ]; then
    printf 'merged %s %s%s\n' "$ICON_MERGE" "$ref" "$iid"; return 0
  fi

  # No local work and no MR: still yours, so active. Do NOT infer "HEAD is contained in the
  # base, therefore merged": a new worktree is contained in the base too, and a squash merge
  # is never an ancestor. Only a merged MR is evidence that something landed.
  printf 'active %s\n' "$ICON_BRANCH"
}

# Herdr keeps a token until told otherwise, so the unused ones are cleared on every report;
# otherwise a space moving review -> merged renders both icons at once. Seven keys per call:
# the phase group (active, draft, review, merged) with one set, and the pipeline group (ci_ok,
# ci_fail, ci_run) with at most one set, none when <ci> is empty.
report() { # report <workspace_id> <phase> <value> <ci: ok|fail|run|"">
  local ws="$1" phase="$2" value="$3" ci="${4:-}" g=""
  local -a args
  args=(workspace report-metadata "$ws" --source "$SOURCE_ID")
  local t
  for t in active draft review merged; do
    if [ "$t" = "$phase" ]; then args+=(--token "$t=$value")
    else args+=(--clear-token "$t"); fi
  done
  for t in ok fail run; do
    case "$t" in ok) g=$CI_OK ;; fail) g=$CI_FAIL ;; run) g=$CI_RUN ;; esac
    if [ "$t" = "$ci" ]; then args+=(--token "ci_$t=$g")
    else args+=(--clear-token "ci_$t"); fi
  done
  bounded "$RUN_END" herdr $HERDR_ARGS "${args[@]}" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ spaces
# Only linked worktrees are badged: a main checkout is nearly always dirty, and would read
# permanently active.
#
# Sorted by repo_root because Herdr does not return the list grouped and the worker starts one
# job per run of equal roots. The sort is stable, so Herdr order holds within a repo.
spaces() {
  bounded "$RUN_END" herdr $HERDR_ARGS workspace list 2>/dev/null | jqi -rRs '
(try fromjson catch empty) | .result.workspaces[]?
| (.worktree // {}) as $wt
| select($wt.is_linked_worktree == true and (.workspace_id | type == "string")
    and ($wt.checkout_path | type == "string" and length > 0) and ($wt.repo_root | type == "string" and length > 0))
| [.workspace_id, $wt.checkout_path, $wt.repo_root] | join("\t")
' 2>/dev/null | LC_ALL=C sort -t"$(printf '\t')" -k3,3 -s
}

# ------------------------------------------------------------------ commands
# One repository's refresh: its table, then derive, CI and a report for each of its spaces. Runs in
# a background subshell of the worker, which holds the run lock.
refresh_repo() { # refresh_repo <root> <run: ttl|force|fresh> <spaces: ws<TAB>path<TAB>root lines>
  local root="$1" run="$2" spaces="$3" ws path r phase value table="" forge="" slug="" key out first second ci iid age mode="ttl"
  slug="$(repo_slug "$root" || true)"
  if [ -n "$slug" ]; then
    forge="${slug%% *}"; slug="${slug#* }"
    key="$(cache_key "$forge" "$slug")"
    # The lookup mode is decided here, once, under the run lock: a --fresh refresh trusts the cache
    # while a lookup of this repository began less than FRESH_GAP ago, and looks up otherwise.
    case "$run" in
      force) mode="force" ;;
      fresh)
        # age_of calls a stamp dated in the future expired: no evidence of a recent lookup.
        age="$(age_of "$CACHE_DIR/$key.lookup")"
        if [ "$age" -lt "$FRESH_GAP" ]; then mode="cached"; else mode="force"; fi ;;
    esac
    table="$(mr_table "$forge" "$slug" "$mode" || true)"
  fi

  while IFS=$'\t' read -r ws path r; do
    [ -n "$ws" ] || continue
    out="$(derive "$path" "$root" "$table" "$forge")"
    first="${out%%$'\n'*}"
    second=""
    case "$out" in *$'\n'*) second="${out#*$'\n'}" ;; esac
    set -- $first
    phase="${1:-none}"; shift || true
    value="$*"
    ci=""
    case "$second" in
      "open "*)
        # GitHub's CI comes with the table (derive's second line); GitLab's costs a call per MR.
        iid="${second#open }"; ci="${iid#* }"
        [ "$ci" != "$iid" ] || ci=""
        iid="${iid%% *}"
        if [ "$forge" = "gitlab" ]; then ci="$(pipeline_class "$slug" "$iid" "$mode")"
        else case "$ci" in ok|fail|run) ;; *) ci="" ;; esac; fi
        ;;
    esac
    report "$ws" "$phase" "$value" "$ci"
  done < <(printf '%s\n' "$spaces")
  return 0
}

# `refresh` checks its arguments and the system tools, then becomes timeout: at the deadline
# timeout sends KILL to the process group of the worker it runs (the worker's shells; each call has
# a group of its own), and a TERM, HUP or INT to the run is forwarded to that group. The worker is
# this script again (the suite runs it as /bin/bash <path>, so $0 is that path).
cmd_refresh() {
  local run="ttl" only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) run="force"; shift ;;
      --fresh) [ "$run" = "force" ] || run="fresh"; shift ;;
      --workspace) only="${2:-}"; [ -n "$only" ] || die "--workspace needs an id"; shift 2 ;;
      *) die "unknown option for refresh: $1" ;;
    esac
  done
  require_deadline
  [ -x /usr/bin/timeout ] && [ -x /usr/bin/lockf ] && [ -x /usr/bin/jq ] || die "/usr/bin/timeout, /usr/bin/lockf and /usr/bin/jq are required"
  # The script has done `cd /`, so a relative $0 would no longer name it.
  case "$0" in /*) ;; *) die "run phase.sh by its absolute path" ;; esac
  exec /usr/bin/timeout -s KILL "$RUN_DEADLINE" /bin/bash "$0" _refresh "$run" "$only"
}

# The run under timeout. The lock file is created with mode 0200 and opened for append: flock needs an
# open descriptor, which a sandboxed command can then get neither for writing (the cache directory is
# outside its write list) nor for reading. A run that cannot get the lock in LOCK_WAIT s does nothing.
cmd_worker() { # cmd_worker <run: ttl|force|fresh> <workspace id or "">
  local run="${1:-ttl}" only="${2:-}" lock="$CACHE_DIR/run.lock" rc=0
  require_deadline
  RUN_END=$(( $(date +%s) + RUN_DEADLINE )); CALL_END=$(( RUN_END - CALL_MARGIN ))
  mkdir -p "$CACHE_DIR" || exit 2
  ( umask 577; : >> "$lock" ) || exit 2
  exec 9>>"$lock" || exit 2
  /usr/bin/lockf -s -t "$LOCK_WAIT" 9 || rc=$?
  case "$rc" in
    0) ;;
    75) echo "phase.sh: skipped: another refresh holds the lock" >&2; exit 0 ;;
    *) exit 2 ;;
  esac
  find "$CACHE_DIR" -maxdepth 1 -name '+tmp.*' -mmin +1 -delete 2>/dev/null || true

  local list ws path root group="" last_root="" nl=$'\n' tab=$'\t'
  list="$(spaces)"
  [ -n "$list" ] || return 0
  # `spaces` sorts by repo, so each repository's spaces are one run of lines; every run is a job.
  while IFS=$'\t' read -r ws path root; do
    [ -n "$ws" ] || continue
    [ -z "$only" ] || [ "$ws" = "$only" ] || continue
    [ -d "$path" ] || continue
    if [ "$root" != "$last_root" ] && [ -n "$group" ]; then
      ( refresh_repo "$last_root" "$run" "$group" ) </dev/null &
      group=""
    fi
    last_root="$root"
    group="${group:+$group$nl}$ws$tab$path$tab$root"
  done < <(printf '%s\n' "$list")
  if [ -n "$group" ]; then ( refresh_repo "$last_root" "$run" "$group" ) </dev/null & fi
  wait
  return 0
}

case "${1:---help}" in
  refresh) shift; cmd_refresh "$@" ;;
  _refresh) shift; cmd_worker "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; die "unknown subcommand: $1" ;;
esac
