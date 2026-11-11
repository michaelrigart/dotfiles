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
#   - a LaunchAgent (be.netronix.herdr-phase-refresh) running `refresh` every 3 minutes.
#
# The event hooks alone cannot keep an MR badge true: opening or merging an MR produces no
# Herdr event, and UI-driven workspace switches may not fire workspace.focused. The
# LaunchAgent must not be throttled (no ProcessType=Background or LowPriorityIO): a run
# that outlasts its 180 s interval makes launchd skip cycles while reporting exit code 0.
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
    '  phase.sh refresh [--force] [--workspace ID]   report phases (all spaces, or one)' \
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

# Prints a cached table. GitHub's CI (column 5) is blanked once the file is older than
# STALE_PIPELINE, the age limit GitLab's pipeline cache has: a stale answer to a failed lookup must
# not keep showing a check result nobody has confirmed.
read_table() { # read_table <cache_file>
  local cache="$1" age now
  now="$(date +%s)"
  age=$(( now - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
  if [ "$age" -lt "$STALE_PIPELINE" ]; then cat "$cache"
  else awk -F'\t' -v OFS='\t' 'NF >= 5 { $5 = "" } { print }' "$cache"; fi
}

# The table: one row per branch, `branch<TAB>opened|merged<TAB><number><TAB>0|1[<TAB><ci>]`.
# <ci> (ok, fail, run or empty) is a GitHub column only, empty on a merged row.
# <force> is 0 or 1. A lookup that cannot answer falls back to the cached table, however old.
mr_table() { # mr_table <forge> <slug> <force>
  local forge="$1" slug="$2" force="$3" cache age now rows rc

  cache="$CACHE_DIR/$(cache_key "$forge" "$slug").tsv"
  if [ "$force" != "1" ] && [ -f "$cache" ]; then
    now="$(date +%s)"
    age=$(( now - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$TTL" ]; then read_table "$cache"; return 0; fi
  fi

  # <forge>_rows exits 0 for a full answer, 3 for the open rows alone (the merged half failed:
  # use them, do not cache them) and anything else for a failed lookup. A failed lookup is not
  # evidence that the MRs went away: returning nothing would wipe every review badge at once, so
  # a stale table beats a table asserted to be empty.
  rows="$("${forge}_rows" "$slug")"; rc=$?
  case "$rc" in
    0)
      mkdir -p "$CACHE_DIR"
      printf '%s\n' "$rows" > "$cache"
      ;;
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
pipeline_class() { # pipeline_class <slug> <iid> <force>
  local slug="$1" iid="$2" force="$3" cache age now status json
  case "$iid" in ''|*[!0-9]*) return 0 ;; esac

  cache="$CACHE_DIR/$(cache_key gitlab "$slug").mr$iid.pipeline"
  status=""
  if [ "$force" != "1" ] && [ -f "$cache" ]; then
    now="$(date +%s)"
    age=$(( now - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$TTL" ]; then status="$(cat "$cache")"; fi
  fi
  if [ -z "$status" ]; then
    # glab prints an API error's JSON body on stdout and exits non-zero (a 401, 404, 429 or
    # 5xx), so its status is taken on its own, never through a pipe into the parser. An empty
    # status is a failed call or a body that is not this MR; a pipeline-less MR prints "none".
    json="$(glab api --hostname "$GITLAB_HOST_NAME" \
      "projects/$(printf '%s' "$slug" | sed 's|/|%2F|g')/merge_requests/$iid" 2>/dev/null)" || json=""
    status=""
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
    if [ -n "$status" ]; then
      mkdir -p "$CACHE_DIR"
      printf '%s\n' "$status" > "$cache"
    elif [ -f "$cache" ]; then
      # A failed call is not evidence that the pipeline went away, so a stale status beats none,
      # but only for a while: a cached "run" glyph would otherwise stay on for as long as glab
      # keeps failing. Past STALE_PIPELINE the tokens are cleared.
      now="$(date +%s)"
      age=$(( now - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
      if [ "$age" -lt "$STALE_PIPELINE" ]; then status="$(cat "$cache")"; fi
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
# Sorted by repo_root because Herdr does not return the list grouped and cmd_refresh holds
# one MR table at a time. The sort is stable, so Herdr order holds within a repo.
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
cmd_refresh() {
  local force=0 only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --workspace) only="${2:-}"; [ -n "$only" ] || die "--workspace needs an id"; shift 2 ;;
      *) die "unknown option for refresh: $1" ;;
    esac
  done

  local list ws path root phase value last_root="" table="" forge="" slug="" out first second ci iid
  list="$(spaces)"
  [ -n "$list" ] || return 0

  while IFS=$'\t' read -r ws path root; do
    [ -n "$ws" ] || continue
    [ -z "$only" ] || [ "$ws" = "$only" ] || continue
    [ -d "$path" ] || continue
    # `spaces` sorts by repo, so one lookup per repo falls out of iterating it.
    if [ "$root" != "$last_root" ]; then
      slug="$(repo_slug "$root" || true)"
      forge=""; table=""
      if [ -n "$slug" ]; then
        forge="${slug%% *}"; slug="${slug#* }"
        table="$(mr_table "$forge" "$slug" "$force" || true)"
      fi
      last_root="$root"
    fi
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
        if [ "$forge" = "gitlab" ]; then ci="$(pipeline_class "$slug" "$iid" "$force")"
        else case "$ci" in ok|fail|run) ;; *) ci="" ;; esac; fi
        ;;
    esac
    report "$ws" "$phase" "$value" "$ci"
  done < <(printf '%s\n' "$list")
}

case "${1:---help}" in
  refresh) shift; cmd_refresh "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; die "unknown subcommand: $1" ;;
esac
