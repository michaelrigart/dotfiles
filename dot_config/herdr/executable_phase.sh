#!/bin/bash
# Badge Herdr spaces with where a worktree sits between "I'm working on this" and
# "this is waiting to be merged".
#
# Managed by chezmoi (source: dot_config/herdr/executable_phase.sh).
#
# Reported tokens are display-only and do NOT survive a Herdr server restart, so this script
# is the only thing keeping the badges alive. It must be cheap and safely re-runnable, and
# it must never read back state it previously reported.
#
# Each report carries seven keys in one `herdr workspace report-metadata` call: the phase
# (active, draft, review or merged) and, for a space with an open MR (draft or not), the head
# pipeline's status (ci_ok, ci_fail or ci_run). One of each group is set and the rest cleared.
#
# Three things drive it, and the periodic one is not redundant:
#   - the dev.phase plugin's [[startup]] hook, which repaints every badge after a restart;
#   - its [[events]] hooks on workspace.focused / worktree.created / worktree.removed;
#   - a LaunchAgent (be.netronix.herdr-phase-refresh) running `refresh --force` every 50 seconds.
#
# The event hooks alone cannot keep an MR badge true: opening or merging an MR produces no
# Herdr event, and UI-driven workspace switches may not fire workspace.focused. The
# LaunchAgent must not be throttled (no ProcessType=Background or LowPriorityIO): a run
# that outlasts its interval makes launchd skip cycles while reporting exit code 0.
#
# How fresh a badge is depends on who asked:
#   - the timer forces every lookup (--force), so a change shows within about a minute. Without
#     --force a focus refresh would renew a cache and the next timer run would reuse it;
#   - a focus refresh (--fresh --workspace) looks its space's repository up whatever the TTL, so the
#     phase being read is at most about FRESH_GAP (10 s) old, unless a lookup of that repository
#     started less than FRESH_GAP ago: then it answers from the cache, as a failed lookup would. The
#     stamp is per repository but the lookup is only the focused space's: a CI token is as old as
#     the last lookup of that space's own pipeline;
#   - the startup and worktree hooks use the TTL (120 s), and the keybinding is `--force`.
# The gap is measured from <key>.lookup, a stamp every forge lookup writes before it calls out. It
# is written and read only under the repository's lock, so a failing forge, or two refreshes at
# once, are rate-limited too, and --force ignores it.
#
# A refresh runs one background job per repository, side by side, and each job holds a kernel lock
# on that repository's lock file (<key>.lock in the cache directory, fd 9, /usr/bin/lockf) from its
# stamp check to its last report. Two refreshes of one repository (the timer and a focus hook, say) run
# one after the other, and an older lookup can never publish after a newer one. A job that cannot
# take the lock within LOCK_WAIT seconds skips its repository and says so on stderr; that run's
# spaces keep their last badge until the next run (the holder reports only the spaces it was
# started for). Cache files are replaced atomically, so a refresh killed mid-write leaves the
# previous table, and each job sweeps its repository's stray temporary files under the lock.
#
# A stuck job is ended at the run deadline: the refresh waits for its jobs at most RUN_DEADLINE
# (40 s, under the 50 s interval), then sends TERM to each unfinished job's process group (KILL
# KILL_GRACE s later to any group that still has a member), which takes its forge call with it and
# frees its lock. The other repositories are reported as usual, and the exit status stays 0. The
# jobs sit in process groups of their own, out of reach of launchd's group kill, so the main shell
# traps TERM, HUP and INT and ends them itself; SIGKILL of the main shell cannot be covered.
# Temporary files stage in .tmp/<key> of the cache directory, one directory per repository.
#
# When Herdr is not running, `spaces` comes back empty and refresh returns before any git,
# glab or gh work. It never fetches: `origin/<branch>` is read as-is, and only the MR and PR state,
# where freshness matters, is cached with a TTL: the table per repo (GitLab through glab, GitHub
# through gh), and each open GitLab MR's pipeline status per repo and MR number.
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
CACHE_DIR="${HERDR_PHASE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-phase}"

# phase.sh runs inside a pane, where HERDR_SOCKET_PATH outranks HERDR_SESSION, so thread
# --session rather than let the pane's socket pick the session (see AGENTS.md).
HERDR_ARGS=""
[ -n "${HERDR_SESSION:-}" ] && HERDR_ARGS="--session $HERDR_SESSION"
TTL="${HERDR_PHASE_TTL:-120}"
STALE_PIPELINE=1800   # seconds a cached pipeline status may stand in for a failed lookup
FRESH_GAP=10          # seconds a --fresh refresh trusts the cache after a lookup of the repository began
LOCK_WAIT="${HERDR_PHASE_LOCK_WAIT:-30}"   # seconds a refresh waits for a repository's lock; the suite lowers it
RUN_DEADLINE="${HERDR_PHASE_RUN_DEADLINE:-40}"   # seconds a refresh waits for its jobs before ending them; the suite lowers it
# Seconds between TERM and KILL when jobs are ended. On `launchctl bootout` launchd sends TERM and
# KILLs the main shell after its ExitTimeOut (20 s by default); the trap's grace, KILL and reap
# must finish well inside that, so this stays small (the suite pins it at 5 s or less).
KILL_GRACE=2

# Nerd Font private-use codepoints, written as escapes because literals do not survive every
# editor and pipeline.
ICON_BRANCH=$(printf '\xee\xb1\xaf')   # U+EC6F cod-git_branch
ICON_MR=$(printf '\xee\xa9\xa4')       # U+EA64 cod-git_pull_request
ICON_DRAFT=$(printf '\xee\xaf\x9b')    # U+EBDB cod-git_pull_request_draft
ICON_MERGE=$(printf '\xee\xab\xbe')    # U+EAFE cod-git_merge
CI_OK=$(printf '\xee\xaa\xb2')         # U+EAB2 cod-check
CI_FAIL=$(printf '\xee\xa9\xb6')       # U+EA76 cod-close
CI_RUN=$(printf '\xee\xa9\xb7')        # U+EA77 cod-sync

# Run with -I below: isolated mode keeps the current directory (a repository) off sys.path and
# ignores PYTHON* variables, so a module a sandboxed command wrote there cannot be imported.
PY=/usr/bin/python3
[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null || true)"

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

# Replaces a cache file atomically: a temporary file in the repository's own staging directory
# (.tmp/<key>, on the same filesystem), then a rename onto the target. A refresh killed mid-write
# leaves the previous file, never half of a new one that would later read as a valid, shorter table.
# The staging directory is the repository's alone (a key holds %2F, never a /, and never starts a
# name with a dot), so what is in it is that repository's stray temporary files and nothing else.
write_cache() { # write_cache <key> <file> <content>
  local stage="$CACHE_DIR/.tmp/$1" tmp
  mkdir -p "$stage" || return 1
  tmp="$(mktemp "$stage/${2##*/}.XXXXXX")" || return 1
  if printf '%s\n' "$3" > "$tmp" && mv -f "$tmp" "$2"; then return 0; fi
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
    write_cache "$key" "$CACHE_DIR/$key.lookup" "" || true
    rows="$("${forge}_rows" "$slug")"; rc=$?
  fi
  case "$rc" in
    0) write_cache "$key" "$cache" "$rows" ;;
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
  open_json="$(glab mr list --repo "https://$GITLAB_HOST_NAME/$slug" --output json --per-page 100 2>/dev/null)" || open_json=""
  [ -n "$open_json" ] || return 1
  # Merged state is best-effort: if only this half fails the open rows still stand, and the
  # table is not cached, so the miss lasts one cycle instead of a TTL.
  local cacheable=1
  merged_json="$(glab mr list --repo "https://$GITLAB_HOST_NAME/$slug" --merged --output json --per-page 100 2>/dev/null)" || merged_json=""
  [ -n "$merged_json" ] || { merged_json="[]"; cacheable=0; }

  printf '%s\n%s\n' "$open_json" "$merged_json" | "$PY" -I -c '
import json, sys
# Two concatenated JSON documents rather than one, so read them off the stream in turn.
dec, data, i, rows = json.JSONDecoder(), sys.stdin.read(), 0, []
while i < len(data):
    while i < len(data) and data[i].isspace():
        i += 1
    if i >= len(data):
        break
    try:
        obj, i = dec.raw_decode(data, i)
    except Exception:
        sys.exit(1)
    if isinstance(obj, list):
        rows.extend(obj)
seen = {}
for m in rows:
    b = m.get("source_branch")
    if not b:
        continue
    # An open MR is the live one for a branch; anything else only fills a gap, so a branch
    # reused after a merge still reports the MR that is actually open on it.
    if b not in seen or m.get("state") == "opened":
        seen[b] = m
for b, m in seen.items():
    print("\t".join([b, m.get("state") or "", str(m.get("iid") or ""),
                     "1" if m.get("draft") else "0"]))
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
  open_json="$(env -i HOME="$HOME" PATH="$PATH" gh pr list -R "github.com/$slug" --state open --limit 100 \
    --json headRefName,state,number,isDraft,isCrossRepository,statusCheckRollup 2>/dev/null)" || return 1
  # Each status is taken on its own, never through a pipe into the parser. The merged half is
  # best-effort, as on GitLab: "null" stands for a failed call and the parser reads it as not
  # being a list.
  merged_json="$(env -i HOME="$HOME" PATH="$PATH" gh pr list -R "github.com/$slug" --state merged --limit 100 \
    --json headRefName,state,number,isDraft,isCrossRepository 2>/dev/null)" || merged_json="null"

  # Exit 1: the open answer is not a list. Exit 3: the rows are the open ones alone, because the
  # merged answer is not a list. A row is dropped unless it is a PR of this repository (a fork's
  # branch name is not this checkout's branch) with a branch name that holds no tab or newline and
  # an integer number. OPEN is "opened", MERGED is "merged", CLOSED has no badge, and an open PR
  # beats a merged one on the same branch.
  # The two answers are separated by a line no JSON document can hold and each is parsed on its
  # own, so an empty answer can never let the other one take its place.
  # An open PR's CI comes from its rollup, in gh pr checks' buckets: a CheckRun's state is its
  # conclusion once COMPLETED and its status before; a StatusContext's is its state. Fail beats
  # pending, pending beats success, and a state in no bucket (STALE, say) gives no badge.
  printf '%s\n@@\n%s\n' "$open_json" "$merged_json" | "$PY" -I -c '
import json, sys
FAIL = {"FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"}
PEND = {"QUEUED", "IN_PROGRESS", "PENDING", "EXPECTED", "REQUESTED", "WAITING"}
GOOD = {"SUCCESS", "SKIPPED", "NEUTRAL"}
def ci(roll):
    if not isinstance(roll, list) or not roll:
        return ""
    states = set()
    for c in roll:
        st = None
        if isinstance(c, dict):
            if "state" in c:
                st = c["state"]
            elif c.get("status") == "COMPLETED":
                st = c.get("conclusion")
            else:
                st = c.get("status")
        states.add(st if isinstance(st, str) else "")
    if states & FAIL:
        return "fail"
    if states & PEND:
        return "run"
    return "ok" if states <= GOOD else ""
def load(text):
    try:
        v = json.loads(text)
    except Exception:
        return None
    return v if isinstance(v, list) else None
a, _, b = sys.stdin.read().partition("\n@@\n")
opened, merged = load(a), load(b)
if opened is None:
    sys.exit(1)
rows = {"OPEN": {}, "MERGED": {}}
for pr in opened + (merged or []):
    if not isinstance(pr, dict) or pr.get("state") not in rows or pr.get("isCrossRepository") is not False:
        continue
    b, n = pr.get("headRefName"), pr.get("number")
    if not isinstance(b, str) or not b or "\t" in b or "\n" in b:
        continue
    if type(n) is not int or n < 1:
        continue
    # gh lists the newest first, so the first PR of a state is the one that counts.
    rows[pr["state"]].setdefault(b, (n, "1" if pr.get("isDraft") is True else "0",
                                          ci(pr.get("statusCheckRollup")) if pr["state"] == "OPEN" else ""))
for b, (n, d, c) in rows["OPEN"].items():
    print("\t".join([b, "opened", str(n), d, c]))
for b, (n, d, c) in rows["MERGED"].items():
    if b not in rows["OPEN"]:
        print("\t".join([b, "merged", str(n), d, ""]))
sys.exit(0 if merged is not None else 3)
' 2>/dev/null
  rc=$?
  case "$rc" in 0|3) return "$rc" ;; *) return 1 ;; esac
}

# The list endpoint carries no head_pipeline, so the status costs one call per open MR. It is
# cached per repo AND iid: a branch reused after a merge gets a new MR number and must not show
# the old MR's pipeline. Prints ok, fail or run, or nothing (no pipeline, a status that is not
# a badge, or no answer at all).
pipeline_class() { # pipeline_class <slug> <iid> <mode: ttl|force|cached>
  local slug="$1" iid="$2" mode="$3" key cache status json
  case "$iid" in ''|*[!0-9]*) return 0 ;; esac

  key="$(cache_key gitlab "$slug")"
  cache="$CACHE_DIR/$key.mr$iid.pipeline"
  status=""
  if [ "$mode" = "ttl" ] && [ -f "$cache" ]; then
    if [ "$(age_of "$cache")" -lt "$TTL" ]; then status="$(cat "$cache")"; fi
  fi
  if [ -z "$status" ]; then
    if [ "$mode" != "cached" ]; then
      write_cache "$key" "$CACHE_DIR/$key.lookup" "" || true
      # glab prints an API error's JSON body on stdout and exits non-zero (a 401, 404, 429 or
      # 5xx), so its status is taken on its own, never through a pipe into the parser. An empty
      # status is a failed call or a body that is not this MR; a pipeline-less MR prints "none".
      json="$(glab api --hostname "$GITLAB_HOST_NAME" \
        "projects/$(printf '%s' "$slug" | sed 's|/|%2F|g')/merge_requests/$iid" 2>/dev/null)" || json=""
      if [ -n "$json" ]; then
        status="$(printf '%s' "$json" | "$PY" -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict) or str(d.get("iid")) != sys.argv[1]:
    sys.exit(1)
p = d.get("head_pipeline")
s = p.get("status") if isinstance(p, dict) else None
print(s if isinstance(s, str) and re.fullmatch(r"[a-z_]{1,40}", s) else "none")
' "$iid" 2>/dev/null)" || status=""
      fi
      [ -z "$status" ] || write_cache "$key" "$cache" "$status"
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
  herdr $HERDR_ARGS "${args[@]}" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ spaces
# Only linked worktrees are badged: a main checkout is nearly always dirty, and would read
# permanently active.
#
# Sorted by repo_root because Herdr does not return the list grouped and cmd_refresh starts one
# job per run of equal roots. The sort is stable, so Herdr order holds within a repo.
spaces() {
  herdr $HERDR_ARGS workspace list 2>/dev/null | "$PY" -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in d.get("result", {}).get("workspaces", []):
    wt = w.get("worktree") or {}
    if not wt.get("is_linked_worktree"):
        continue
    path, root = wt.get("checkout_path"), wt.get("repo_root")
    if path and root:
        print("\t".join([w["workspace_id"], path, root]))
' 2>/dev/null | LC_ALL=C sort -t"$(printf '\t')" -k3,3 -s
}

# ------------------------------------------------------------------ commands
# One repository's refresh: its table, then derive, CI and a report for each of its spaces. Runs in
# a background subshell, never in the main shell: the lock is on that subshell's fd 9, and it is
# released only when the job and every child that inherited fd 9 have exited.
refresh_repo() { # refresh_repo <root> <run: ttl|force|fresh> <spaces: ws<TAB>path<TAB>root lines>
  local root="$1" run="$2" spaces="$3" ws path r phase value table="" forge="" slug="" key out first second ci iid age mode="ttl"
  slug="$(repo_slug "$root" || true)"
  if [ -n "$slug" ]; then
    forge="${slug%% *}"; slug="${slug#* }"
    key="$(cache_key "$forge" "$slug")"
    # The kernel releases the lock only when every process holding fd 9 has exited, so a parent
    # that dies while this job lives on does not free it, and nothing reclaims or breaks it. A job
    # stuck in a forge call is ended at the run deadline, with its process group.
    mkdir -p "$CACHE_DIR"
    exec 9>>"$CACHE_DIR/$key.lock" || { echo "phase.sh: skipped $key: cannot open its lock file" >&2; return 0; }
    /usr/bin/lockf -s -t "$LOCK_WAIT" 9 || { echo "phase.sh: skipped $key: its lock is held" >&2; return 0; }
    # Stray temporary files come from a refresh killed mid-write; they live in this repository's
    # staging directory alone, and the lock keeps this from deleting a live job's file.
    rm -f "$CACHE_DIR/.tmp/$key/"*
    # The lookup mode is decided here, once, with the lock held: a --fresh refresh trusts the cache
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

# Starts a repository's job in its own process group (job control on just for the fork, so the job's
# group is its PID and a group signal reaches the forge call it runs inside $(...)), with no stdin.
# Records the PID in JOB_PIDS and PID<TAB>root in JOB_ROOTS.
spawn_job() { # spawn_job <root> <run> <spaces>
  set -m
  ( refresh_repo "$1" "$2" "$3" ) </dev/null &
  set +m
  JOB_PIDS="$JOB_PIDS $!"
  JOB_ROOTS="$JOB_ROOTS$!"$'\t'"$1"$'\n'
}

live_jobs() { # live_jobs -> LEFT: the jobs of JOB_PIDS whose first process is still running
  local pid
  LEFT=""
  for pid in $JOB_PIDS; do
    if kill -0 "$pid" 2>/dev/null; then LEFT="$LEFT $pid"; fi
  done
}

live_groups() { # live_groups -> LEFT: the jobs of JOB_PIDS whose process group still has a member
  local pid
  LEFT=""
  for pid in $JOB_PIDS; do
    if kill -0 -- "-$pid" 2>/dev/null; then LEFT="$LEFT $pid"; fi
  done
}

# Ends every job that still has a process: TERM to its group, then KILL to each group that still has
# a member after KILL_GRACE seconds. The first process of a job (bash) always dies on TERM, so the
# grace is judged on the whole group: a forge call that ignores TERM is still a member. TERMED holds
# the jobs that were signalled.
end_jobs() {
  local i pid
  live_groups
  TERMED="$LEFT"
  for pid in $TERMED; do kill -TERM -- "-$pid" 2>/dev/null; done
  for ((i = 0; i < KILL_GRACE * 10; i++)); do
    live_groups
    [ -n "$LEFT" ] || break
    sleep 0.1
  done
  for pid in $LEFT; do kill -KILL -- "-$pid" 2>/dev/null; done
}

# TERM, HUP or INT to the main shell (launchd's bootout, a kill, ^C): launchd's group kill cannot
# reach the jobs, which sit in groups of their own, so the main shell ends them itself, then exits.
# SIGKILL of the main shell cannot be caught: its jobs run on, and the next run waits for their lock.
abort_run() { # abort_run <exit status>
  local pid
  trap - TERM HUP INT
  end_jobs
  for pid in $JOB_PIDS; do wait "$pid" 2>/dev/null; done
  exit "$1"
}

job_key() { # job_key <pid> -> the cache key of that job's repository, for its stderr line
  local root slug
  root="$(printf '%s' "$JOB_ROOTS" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }')"
  slug="$(repo_slug "$root" || true)"
  if [ -n "$slug" ]; then cache_key "${slug%% *}" "${slug#* }"; else echo "(no forge)"; fi
}

# Waits for the jobs at most RUN_DEADLINE seconds of wall time (bash 3.2 has no `wait -n` and no
# timeout on `wait`, so it polls), then ends every job that still has a process (end_jobs). That
# reaches the forge call too, so no process of a job outlives the run, and the kernel frees the
# job's lock. A stuck forge call therefore holds up no other repository and not the next timer run.
# Each job is then reaped on its own: one that was signalled and died of it (status 128 or more) is
# named as ended at the deadline, one that died abnormally otherwise is named too. A failed lookup
# is not a failed refresh: the status stays 0. Runs with stderr on /dev/null and writes its own
# lines to fd 8.
wait_jobs() {
  local pid st start=$SECONDS
  LEFT=""; TERMED=""
  while [ $((SECONDS - start)) -lt "$RUN_DEADLINE" ]; do
    live_jobs
    [ -n "$LEFT" ] || break
    sleep 0.1
  done
  end_jobs
  for pid in $JOB_PIDS; do
    wait "$pid"; st=$?
    case " $TERMED " in
      *" $pid "*)
        if [ "$st" -ge 128 ]; then echo "phase.sh: $(job_key "$pid"): killed at the run deadline" >&8; continue; fi ;;
    esac
    [ "$st" -eq 0 ] || echo "phase.sh: a refresh job ended abnormally (status $st)" >&8
  done
}

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

  local list ws path root group="" last_root="" nl=$'\n' tab=$'\t'
  list="$(spaces)"
  [ -n "$list" ] || return 0
  JOB_PIDS=""; JOB_ROOTS=""
  trap 'abort_run 143' TERM
  trap 'abort_run 129' HUP
  trap 'abort_run 130' INT

  # `spaces` sorts by repo, so each repository's spaces are one run of lines; every run is a job.
  while IFS=$'\t' read -r ws path root; do
    [ -n "$ws" ] || continue
    [ -z "$only" ] || [ "$ws" = "$only" ] || continue
    [ -d "$path" ] || continue
    if [ "$root" != "$last_root" ] && [ -n "$group" ]; then
      spawn_job "$last_root" "$run" "$group"
      group=""
    fi
    last_root="$root"
    group="${group:+$group$nl}$ws$tab$path$tab$root"
  done < <(printf '%s\n' "$list")
  if [ -n "$group" ]; then spawn_job "$last_root" "$run" "$group"; fi
  # The shell's own notices about a signalled job go nowhere; the script's lines use fd 8, opened
  # only now so that no job holds it.
  exec 8>&2
  wait_jobs 2>/dev/null
  exec 8>&-
  return 0
}

case "${1:---help}" in
  refresh) shift; cmd_refresh "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; die "unknown subcommand: $1" ;;
esac
