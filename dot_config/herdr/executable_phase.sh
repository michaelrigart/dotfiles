#!/usr/bin/env bash
# Badge Herdr spaces with where a worktree sits between "I'm working on this" and
# "this is waiting to be merged".
#
# Managed by chezmoi (source: dot_config/herdr/executable_phase.sh).
#
# Reported tokens are display-only and do NOT survive a Herdr server restart, so this script
# is the only thing keeping the badges alive. It must therefore be cheap and safely
# re-runnable, and it must never read back state it previously reported.
#
# Three things drive it, and the periodic one is not redundant:
#   - the dev.phase plugin's [[startup]] hook, which repaints every badge after a restart;
#   - its [[events]] hooks on workspace.focused / worktree.created / worktree.removed;
#   - a LaunchAgent (be.netronix.herdr-phase-refresh) running `refresh` every 3 minutes.
#
# The event hooks alone cannot keep an MR badge true, because the state that changes is not
# local: opening an MR from the worktree you are sitting in, or someone merging one while you
# are away, produces no Herdr event at all, so the badge stays whatever it last was until you
# happen to switch spaces. Observed 2026-09-09: two worktrees with open MRs (!49 and !34) sat
# unbadged while the derivation below returned the correct `review` phase for both. Separately,
# herdr 0.9.0's workspace.focused hook did not fire for UI-driven workspace switches at all —
# the plugin command log held only the startup entry across two days and ~10 focus events,
# while a CLI `herdr workspace focus` fired it every time. The timer covers both without
# depending on which of them is true today.
#
# That timer then spent a month not working, and the two ways it failed are why the code below
# looks the way it does. Measured 2026-09-11: (1) the LaunchAgent carried ProcessType=Background
# and LowPriorityIO, which stretched a 13-second run to roughly six minutes — longer than its own
# 180 s interval, so launchd skipped cycle after cycle while reporting runs=739 and exit code 0;
# (2) `derive` consulted GitLab last, so a single untracked file was enough to repaint a space in
# review as active. An open MR now outranks every local signal, and the plist asks for no
# throttling.
#
# When Herdr is not running, `spaces` comes back empty and refresh returns before any git or
# glab work — so the timer costs nothing on a machine with no session up.
#
# It also never fetches. `origin/<branch>` is read as-is, which is what a push from the
# worktree itself updates; the MR state comes from GitLab and is where freshness actually
# matters, so that is what gets cached with a TTL.
set -u

SOURCE_ID="herdr-phase"
CACHE_DIR="${HERDR_PHASE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/herdr-phase}"
STATE_DIR="${HERDR_PHASE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-phase}"

# herdr 0.8.2 selects a session only via `--session`, never an environment variable.
# phase.sh runs as a plugin action and from the prompt, both of which may be inside a
# named session, so thread it rather than defaulting to the live one.
HERDR_ARGS=""
[ -n "${HERDR_SESSION:-}" ] && HERDR_ARGS="--session $HERDR_SESSION"
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

  # Two queries, not one. `glab mr list` caps --per-page at 100 and this never paginates, so a
  # single --all query silently drops the oldest rows once a repo passes 100 merge requests.
  # netronix/curato is at !123: its cached table held 99 rows ending at !120, and the three
  # worktrees whose MRs were !121-!123 sat unbadged. Asking for the OPEN list on its own puts
  # the only rows a review badge depends on nowhere near the cap, and merged state — which is
  # about work that already landed — is fine with the hundred most recent.
  local open_json merged_json table
  open_json="$(glab mr list --repo "$slug" --output json --per-page 100 2>/dev/null)" || open_json=""
  if [ -z "$open_json" ]; then
    # A failed lookup is not evidence that the MRs went away. Returning nothing here makes every
    # worktree in the repo fall through to `active`, so one blocked request wipes every review
    # badge at once. A stale table is strictly better than a table asserted to be empty.
    if [ -f "$cache" ]; then cat "$cache"; return 0; fi
    return 1
  fi
  # Merged state is best-effort: if only this half fails the run still has the open rows, which
  # are what a review badge needs. The table just does not get cached, so the miss lasts one
  # cycle instead of a TTL — a landed branch reading `active` for three minutes is nothing next
  # to caching a table that claims nothing ever merged.
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

  state=""; iid=""; draft=""
  # The trailing tab is the field anchor, and it does survive the command substitution:
  # `$(...)` strips trailing NEWLINES, not other whitespace. Without it the match would be
  # an unanchored substring and `feature/rev` would pick up the row for `feature/review`.
  row="$(printf '%s\n' "$table" | grep -F "$(printf '%s\t' "$branch")" | head -1)"
  if [ -n "$row" ]; then
    state="$(printf '%s' "$row" | cut -f2)"
    iid="$(printf '%s' "$row" | cut -f3)"
    draft="$(printf '%s' "$row" | cut -f4)"
  fi

  # An open MR outranks everything git can see locally, and this is the whole point of the
  # ordering. It is the one fact that says somebody else is waiting on this branch, and it does
  # not stop being true because you opened a file in the worktree or committed a review fix you
  # have not pushed yet — which is precisely what the two tests below would otherwise conclude.
  # Measured 2026-09-11: curato-issue-98 reported `active` with !120 open because of a single
  # untracked probe file, and curato-issue-91 because of two unpushed commits.
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

  # Unpushed work is still yours. Without a remote branch the comparison is against the base,
  # which is the only honest reading of "there is work here that has gone nowhere".
  local ahead
  if git -C "$path" rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
    ahead="$(git -C "$path" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
  else
    ahead="$(git -C "$path" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
  fi
  if [ "${ahead:-0}" -gt 0 ]; then printf 'active %s\n' "$ICON_BRANCH"; return 0; fi

  # Merged stays BELOW the local tests, unlike opened. Once a branch has landed there is nobody
  # waiting on it, so new work in that worktree is new work — badging it merged would hide it.
  if [ "$state" = "merged" ]; then
    printf 'merged %s !%s\n' "$ICON_MERGE" "$iid"; return 0
  fi

  # Nothing above matched: no local work, and no MR saying anyone else has it. That is still
  # yours, so it reads as active.
  #
  # Emphatically NOT inferred here: "HEAD is contained in the base, therefore merged". A
  # worktree created minutes ago has no commits of its own, which makes it contained in the
  # base too — so that test marks every new worktree as merged and invites deleting work that
  # was never done. It also cannot catch what it was meant to: a squash merge rewrites the
  # commits, so a squash-merged branch is never an ancestor either. Only a merged MR is
  # evidence that something landed.
  printf 'active %s\n' "$ICON_BRANCH"
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
  herdr $HERDR_ARGS "${args[@]}" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ spaces
# Only linked worktrees are badged. A repo's main checkout is nearly always dirty with local
# scratch, and badging it would mark every project permanently active.
#
# Sorted by repo_root because Herdr does not return the list grouped — the live session returns
# VM.Portal, VM.Portal, curato, VM.Portal, curato, curato — and cmd_refresh holds exactly one MR
# table at a time, so every switch back to a repo it already looked up refetched it. The sort is
# stable, so workspaces keep their Herdr order within a repo.
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
