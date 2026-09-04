#!/usr/bin/env bash
# Badge Herdr spaces with where a worktree sits between "I'm working on this" and
# "this is waiting to be merged".
#
# Managed by chezmoi (source: dot_config/herdr/executable_phase.sh).
#
# Reported tokens are display-only and do NOT survive a Herdr server restart, so this script
# is the only thing keeping the badges alive: the dev.phase plugin replays a full refresh on
# startup and on worktree/focus events. It must therefore be cheap and safely re-runnable, and
# it must never read back state it previously reported.
#
# It also never fetches. `origin/<branch>` is read as-is, which is what a push from the
# worktree itself updates; the MR state comes from GitLab and is where freshness actually
# matters, so that is what gets cached with a TTL.
set -u

SOURCE_ID="herdr-phase"
CACHE_DIR="${HERDR_PHASE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-phase}"
STATE_DIR="${HERDR_PHASE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-phase}"
TTL="${HERDR_PHASE_TTL:-120}"

# Appended rather than prepended: a plugin hook runs with a minimal PATH and needs these, but
# an explicit override earlier in PATH (a test stub) must still win.
case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) PATH="$PATH:/opt/homebrew/bin" ;; esac

# Nerd Font private-use codepoints, written as escapes because literals do not survive every
# editor and pipeline they pass through. A wrong codepoint renders as tofu and reports nothing.
ICON_BRANCH=$(printf '\xee\xb1\xaf')   # U+EC6F cod-git_branch
ICON_MR=$(printf '\xee\xa9\xa4')       # U+EA64 cod-git_pull_request
ICON_DRAFT=$(printf '\xee\xaf\x9b')    # U+EBDB cod-git_pull_request_draft
ICON_MERGE=$(printf '\xee\xab\xbe')    # U+EAFE cod-git_merge
ICON_FLAG=$(printf '\xee\xb0\xbf')     # U+EC3F cod-flag

PY=/usr/bin/python3
[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null || true)"

usage() {
  cat <<'U'
phase.sh — badge Herdr spaces with their merge phase

  phase.sh refresh [--force] [--workspace ID]   report phases (all spaces, or one)
  phase.sh pin [--workspace ID] <phase>         override what git says for a space
  phase.sh unpin [--workspace ID]               drop the override
  phase.sh --help

Phases: active, review, merged, parked. A pin persists on disk and survives the Herdr
server restart that wipes reported tokens.
U
}

die() { echo "phase.sh: $*" >&2; exit 2; }

# ------------------------------------------------------------------ pins
# Keyed by checkout path, not workspace id: ids are assigned by the running server, and a pin
# is meant to outlive it.
pin_file() { printf '%s/pins/%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr '/ ' '__')"; }

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

  local json table
  json="$(glab mr list --repo "$slug" --all --output json --per-page 100 2>/dev/null)" || return 1
  [ -n "$json" ] || return 1
  table="$(printf '%s' "$json" | "$PY" -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(1)
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
' 2>/dev/null)" || return 1

  mkdir -p "$CACHE_DIR"
  printf '%s\n' "$table" > "$cache"
  printf '%s\n' "$table"
}

# ------------------------------------------------------------------ derivation
# Prints "<phase> <value>" for one checkout. Order matters: a pin wins outright, then whether
# work is still local, then what GitLab says.
derive() { # derive <checkout_path> <repo_root> <mr_table>
  local path="$1" root="$2" table="$3" pf branch base row state iid draft

  pf="$(pin_file "$path")"
  if [ -f "$pf" ]; then
    read -r pinned < "$pf"
    case "$pinned" in
      active)  printf 'active %s\n' "$ICON_BRANCH" ;;
      review)  printf 'review %s\n' "$ICON_MR" ;;
      merged)  printf 'merged %s\n' "$ICON_MERGE" ;;
      parked)  printf 'parked %s\n' "$ICON_FLAG" ;;
      *)       printf 'none\n' ;;
    esac
    return 0
  fi

  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)" || { echo none; return 0; }

  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    printf 'active %s\n' "$ICON_BRANCH"; return 0
  fi

  base="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  [ -n "$base" ] || base="origin/main"

  # Unpushed work is still yours. Without a remote branch the comparison is against the base,
  # which is the only honest reading of "there is work here that has gone nowhere".
  local ahead
  if git -C "$path" rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
    ahead="$(git -C "$path" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
  else
    ahead="$(git -C "$path" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
  fi
  if [ "${ahead:-0}" -gt 0 ]; then printf 'active %s\n' "$ICON_BRANCH"; return 0; fi

  row="$(printf '%s\n' "$table" | grep -F "$(printf '%s\t' "$branch")" | head -1)"
  if [ -n "$row" ]; then
    state="$(printf '%s' "$row" | cut -f2)"
    iid="$(printf '%s' "$row" | cut -f3)"
    draft="$(printf '%s' "$row" | cut -f4)"
    case "$state" in
      opened)
        if [ "$draft" = "1" ]; then printf 'active %s\n' "$ICON_DRAFT"
        else printf 'review %s !%s\n' "$ICON_MR" "$iid"; fi
        return 0 ;;
      merged)
        printf 'merged %s !%s\n' "$ICON_MERGE" "$iid"; return 0 ;;
    esac
  fi

  # No MR to go on: content already contained in the base is done regardless.
  if git -C "$path" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    printf 'merged %s\n' "$ICON_MERGE"; return 0
  fi
  echo none
}

# Herdr keeps a token until told otherwise, so the three unused ones are cleared on every
# report — otherwise a space moving review -> merged renders both icons at once.
report() { # report <workspace_id> <phase> <value>
  local ws="$1" phase="$2" value="$3"
  local -a args
  args=(workspace report-metadata "$ws" --source "$SOURCE_ID")
  local t
  for t in active review merged parked; do
    if [ "$t" = "$phase" ]; then args+=(--token "$t=$value")
    else args+=(--clear-token "$t"); fi
  done
  herdr "${args[@]}" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ spaces
# Only linked worktrees are badged. A repo's main checkout is nearly always dirty with local
# scratch, and badging it would mark every project permanently active.
spaces() {
  herdr workspace list 2>/dev/null | "$PY" -c '
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
' 2>/dev/null
}

# resolve a workspace id to its checkout path
path_of() { spaces | awk -F'\t' -v w="$1" '$1 == w { print $2; exit }'; }

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
    # The list arrives grouped by repo, so one lookup per repo falls out of iterating it.
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

cmd_pin() {
  local ws="${HERDR_WORKSPACE_ID:-}" phase=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws="${2:-}"; shift 2 ;;
      -*) die "unknown option for pin: $1" ;;
      *) phase="$1"; shift ;;
    esac
  done
  [ -n "$ws" ] || die "no workspace — pass --workspace or run inside one"
  case "$phase" in
    active|review|merged|parked) ;;
    "") die "pin needs a phase: active, review, merged or parked" ;;
    *) die "unknown phase: $phase" ;;
  esac
  local path; path="$(path_of "$ws")"
  [ -n "$path" ] || die "workspace $ws is not a linked worktree"
  mkdir -p "$STATE_DIR/pins"
  printf '%s\n' "$phase" > "$(pin_file "$path")"
}

cmd_unpin() {
  local ws="${HERDR_WORKSPACE_ID:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) ws="${2:-}"; shift 2 ;;
      *) die "unknown option for unpin: $1" ;;
    esac
  done
  [ -n "$ws" ] || die "no workspace — pass --workspace or run inside one"
  local path; path="$(path_of "$ws")"
  [ -n "$path" ] || die "workspace $ws is not a linked worktree"
  rm -f "$(pin_file "$path")"
}

case "${1:---help}" in
  refresh) shift; cmd_refresh "$@" ;;
  pin)     shift; cmd_pin "$@" ;;
  unpin)   shift; cmd_unpin "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; die "unknown subcommand: $1" ;;
esac
