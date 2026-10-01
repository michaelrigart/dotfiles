#!/usr/bin/env bash
# Badge Herdr spaces with where a worktree sits between "I'm working on this" and
# "this is waiting to be merged".
#
# Managed by chezmoi (source: dot_config/herdr/executable_phase.sh).
#
# Reported tokens are display-only and do NOT survive a Herdr server restart, so this script
# is the only thing keeping the badges alive. It must be cheap and safely re-runnable, and
# it must never read back state it previously reported.
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
# When Herdr is not running, `spaces` comes back empty and refresh returns before any git or
# glab work. It never fetches: `origin/<branch>` is read as-is, and only the MR state, where
# freshness matters, is cached with a TTL.
set -u

SOURCE_ID="herdr-phase"
CACHE_DIR="${HERDR_PHASE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-phase}"

# phase.sh runs inside a pane, where HERDR_SOCKET_PATH outranks HERDR_SESSION, so thread
# --session rather than let the pane's socket pick the session (see AGENTS.md).
HERDR_ARGS=""
[ -n "${HERDR_SESSION:-}" ] && HERDR_ARGS="--session $HERDR_SESSION"
TTL="${HERDR_PHASE_TTL:-120}"

# Appended, not prepended: a plugin hook's minimal PATH needs these, but an override earlier
# in PATH (a test stub) must still win.
case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) PATH="$PATH:/opt/homebrew/bin" ;; esac

# Nerd Font private-use codepoints, written as escapes because literals do not survive every
# editor and pipeline.
ICON_BRANCH=$(printf '\xee\xb1\xaf')   # U+EC6F cod-git_branch
ICON_MR=$(printf '\xee\xa9\xa4')       # U+EA64 cod-git_pull_request
ICON_DRAFT=$(printf '\xee\xaf\x9b')    # U+EBDB cod-git_pull_request_draft
ICON_MERGE=$(printf '\xee\xab\xbe')    # U+EAFE cod-git_merge

PY=/usr/bin/python3
[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null || true)"

usage() {
  cat <<'U'
phase.sh — badge Herdr spaces with their merge phase

  phase.sh refresh [--force] [--workspace ID]   report phases (all spaces, or one)
  phase.sh --help

Phases: active, review, merged.
U
}

die() { echo "phase.sh: $*" >&2; exit 2; }

# ------------------------------------------------------------------ MR state
# One lookup per repo, cached as a small table so the per-worktree path stays a grep.
# Prints nothing and fails when the repo is not on GitLab or the lookup did not work.
mr_table() { # mr_table <repo_root> <force>
  local root="$1" force="$2" url slug cache age now
  url="$(git -C "$root" remote get-url origin 2>/dev/null)" || return 1
  case "$url" in *gitlab.com*) ;; *) return 1 ;; esac
  slug="${url#*gitlab.com}"; slug="${slug#:}"; slug="${slug#/}"; slug="${slug%.git}"
  [ -n "$slug" ] || return 1

  cache="$CACHE_DIR/$(printf '%s' "$slug" | tr '/' '_').tsv"
  if [ "$force" != "1" ] && [ -f "$cache" ]; then
    now="$(date +%s)"
    age=$(( now - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$TTL" ]; then cat "$cache"; return 0; fi
  fi

  # Two queries, not one: `glab mr list` caps --per-page at 100 and this never paginates, so
  # a single --all query drops the oldest rows once a repo passes 100 MRs. The OPEN list on
  # its own keeps the rows a review badge depends on far from the cap.
  local open_json merged_json table
  open_json="$(glab mr list --repo "$slug" --output json --per-page 100 2>/dev/null)" || open_json=""
  if [ -z "$open_json" ]; then
    # A failed lookup is not evidence that the MRs went away: returning nothing would wipe
    # every review badge at once. A stale table beats a table asserted to be empty.
    if [ -f "$cache" ]; then cat "$cache"; return 0; fi
    return 1
  fi
  # Merged state is best-effort: if only this half fails the open rows still stand, and the
  # table is not cached, so the miss lasts one cycle instead of a TTL.
  local cacheable=1
  merged_json="$(glab mr list --repo "$slug" --merged --output json --per-page 100 2>/dev/null)" || merged_json=""
  [ -n "$merged_json" ] || { merged_json="[]"; cacheable=0; }

  table="$(printf '%s\n%s\n' "$open_json" "$merged_json" | "$PY" -c '
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
' 2>/dev/null)" || { [ -f "$cache" ] && { cat "$cache"; return 0; }; return 1; }

  if [ "$cacheable" = "1" ]; then
    mkdir -p "$CACHE_DIR"
    printf '%s\n' "$table" > "$cache"
  fi
  printf '%s\n' "$table"
}

# ------------------------------------------------------------------ derivation
# Prints "<phase> <value>" for one checkout. Order matters: an open MR outranks every local
# signal; local work outranks a merged MR.
derive() { # derive <checkout_path> <repo_root> <mr_table>
  local path="$1" root="$2" table="$3" branch base row state iid draft

  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)" || { echo none; return 0; }

  state=""; iid=""; draft=""
  # Whole-field equality, not a substring search: `grep -F` collides in both directions
  # (`mr-suffix` inside `owner/mr-suffix`, `feature/rev` against `feature/review`). The
  # branch travels in the environment, not `awk -v`, which processes escape sequences.
  row="$(printf '%s\n' "$table" | B="$branch" awk -F'\t' 'BEGIN{b=ENVIRON["B"]} $1==b {print; exit}')"
  if [ -n "$row" ]; then
    state="$(printf '%s' "$row" | cut -f2)"
    iid="$(printf '%s' "$row" | cut -f3)"
    draft="$(printf '%s' "$row" | cut -f4)"
  fi

  # An open MR outranks everything git can see locally: it says somebody else is waiting on
  # this branch, and an untracked file or an unpushed review fix does not change that.
  if [ "$state" = "opened" ]; then
    if [ "$draft" = "1" ]; then printf 'active %s\n' "$ICON_DRAFT"
    else printf 'review %s !%s\n' "$ICON_MR" "$iid"; fi
    return 0
  fi

  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
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
    printf 'merged %s !%s\n' "$ICON_MERGE" "$iid"; return 0
  fi

  # No local work and no MR: still yours, so active. Do NOT infer "HEAD is contained in the
  # base, therefore merged": a new worktree is contained in the base too, and a squash merge
  # is never an ancestor. Only a merged MR is evidence that something landed.
  printf 'active %s\n' "$ICON_BRANCH"
}

# Herdr keeps a token until told otherwise, so the two unused ones are cleared on every
# report; otherwise a space moving review -> merged renders both icons at once.
report() { # report <workspace_id> <phase> <value>
  local ws="$1" phase="$2" value="$3"
  local -a args
  args=(workspace report-metadata "$ws" --source "$SOURCE_ID")
  local t
  for t in active review merged; do
    if [ "$t" = "$phase" ]; then args+=(--token "$t=$value")
    else args+=(--clear-token "$t"); fi
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
  herdr $HERDR_ARGS workspace list 2>/dev/null | "$PY" -c '
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

  local list ws path root phase value last_root="" table=""
  list="$(spaces)"
  [ -n "$list" ] || return 0

  while IFS=$'\t' read -r ws path root; do
    [ -n "$ws" ] || continue
    [ -z "$only" ] || [ "$ws" = "$only" ] || continue
    [ -d "$path" ] || continue
    # `spaces` sorts by repo, so one lookup per repo falls out of iterating it.
    if [ "$root" != "$last_root" ]; then
      table="$(mr_table "$root" "$force" || true)"
      last_root="$root"
    fi
    set -- $(derive "$path" "$root" "$table")
    phase="${1:-none}"; shift || true
    value="$*"
    report "$ws" "$phase" "$value"
  done <<EOF
$list
EOF
}

case "${1:---help}" in
  refresh) shift; cmd_refresh "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; die "unknown subcommand: $1" ;;
esac
