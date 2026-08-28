#!/usr/bin/env zsh
# layout.sh — build, focus or repair a project's Herdr workspace.
# Managed by chezmoi (source: dot_config/herdr/executable_layout.sh).
#
#   layout.sh <repo-path>   build-or-focus, called by hdev from a shell
#   layout.sh --current     repair in place, called by the dev.layout.apply plugin
#
# The single definition of what a project workspace looks like. Both entry points go
# through it, so there is no second copy to drift.
emulate -L zsh
# no_bg_nice: zsh sets BG_NICE by default, so `cmd &` renices the job. That renice
# fails outright where setpriority is denied (a sandbox, some CI), taking the
# backgrounded server with it — and even where it succeeds, quietly deprioritising the
# Herdr server every agent runs inside is not what anyone wants.
setopt local_options no_unset pipe_fail no_bg_nice

MANAGED_TABS=(agents editor runtime git)
BUILDING_SUFFIX=" (building)"

die() { print -ru2 -- "layout.sh: $*"; exit 1 }

# hl_api — run a herdr CLI call, return its JSON on stdout. Non-zero on failure, with
# the server's message. Every call goes through here so failures are uniform: the old
# Zellij shape returned 0 from every step while the layout silently failed, and exit
# status was no guard.
hl_api() {
  local out rc
  out="$(command herdr "$@" 2>&1)"; rc=$?
  if (( rc != 0 )) || [[ "$out" == *'"error"'* ]]; then
    print -ru2 -- "layout.sh: herdr $* failed: $out"
    return 1
  fi
  print -r -- "$out"
}

# hl_server_ready — is a server actually answering? `herdr status server` exits 0 even
# while reporting "not running", so exit status is not a readiness signal, and there is
# no CLI `ping`. The probe is therefore a real call that fails when the server is down.
hl_server_ready() {
  local out
  out="$(command herdr workspace list 2>&1)" || return 1
  [[ "$out" == *server_not_running* ]] && return 1
  return 0
}

hl_ensure_server() {
  hl_server_ready && return 0
  # `herdr server` runs in the foreground: background and detach it explicitly. A
  # second hdev racing this must neither fail nor start a second server, so the start
  # is fire-and-forget and readiness is what we actually wait on.
  (command herdr server >/dev/null 2>&1 &) || true
  local tries="${HL_READY_TRIES:-40}" i=1
  while (( i <= tries )); do
    hl_server_ready && return 0
    sleep 0.25
    (( i++ ))
  done
  die "the herdr server did not become ready after $(( tries / 4 ))s"
}

# hl_label — the display label. Deterministic from the path so it is stable, but
# purely cosmetic: identity is the canonical path, checked via pane cwd.
hl_label() {
  local repo="$1"
  case "$repo" in
    "$HOME/Code/"*) print -r -- "${repo#$HOME/Code/}" ;;
    "$HOME/"*)      print -r -- "${repo#$HOME/}" ;;
    *)              print -r -- "$repo" ;;
  esac
}

# hl_lock — serialise per canonical repo path. Acquired BEFORE any scan, and the scan
# repeated underneath it: classifying first and locking second permits a delayed
# duplicate, where B scans empty, waits while A builds and releases, then acts on its
# stale observation and creates a second workspace for the same repo.
#
# `zsystem flock`, matching _wt_lock in zsh/functions — NOT a mkdir sentinel. The
# reason is stated there: an fcntl record lock is released by the kernel when the
# process dies, "the backstop for every path an explicit unlock cannot reach." A mkdir
# lock has no such backstop, so one SIGKILL would wedge that repository until someone
# removed the directory by hand.
#
# zsystem opens but does not create the lock file, so it must exist first.
hl_lock() {
  local key="${1//\//-}" dir="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-layout"
  mkdir -p "$dir"
  HL_LOCKFILE="$dir/${key#-}.lock"
  : >>"$HL_LOCKFILE"
  zmodload -F zsh/system b:zsystem 2>/dev/null

  [[ -n "${HL_LOCK_DELAY:-}" ]] && sleep "$HL_LOCK_DELAY"

  if ! zsystem flock -t 10 "$HL_LOCKFILE" 2>/dev/null; then
    die "another layout.sh has held the lock for $1 for over 10s"
  fi
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "LOCK-ACQUIRED"
  return 0
}

# hl_find_workspace — the workspace whose panes live at this path, if any.
# Identity is the canonical path, not the label: WorkspaceInfo carries no cwd, but
# PaneInfo carries `cwd`, and labels are mutable and non-unique. A workspace whose
# label happens to match but whose panes are elsewhere is simply not a match.
hl_find_workspace() {
  local repo="$1" panes
  local -a ids
  # stderr, not stdout: this function's stdout IS its return value (ws="$(...)"), so a
  # trace line printed there would be captured into the workspace id and corrupt it.
  [[ -n "${HL_TRACE_LOCK:-}" ]] && print -ru2 -- "SCAN"
  [[ -n "${HL_SCAN_DELAY:-}" ]] && sleep "$HL_SCAN_DELAY"
  panes="$(hl_api pane list)" || return 1
  ids=( ${(f)"$(print -r -- "$panes" | jq -r --arg d "$repo" \
        '.result.panes[] | select(.cwd == $d) | .workspace_id' | sort -u)"} )
  ids=( ${ids:#} )
  (( ${#ids} == 0 )) && return 0
  (( ${#ids} > 1 )) && die "panes for $repo span workspaces: ${ids[*]} — refusing to guess"
  print -r -- "${ids[1]}"
}

# Replaced in Tasks 6-7 by real classification, build and repair.
hl_reconcile() { hl_api workspace focus "$1" >/dev/null }
hl_build()     { hl_api workspace create --cwd "$1" --label "$(hl_label "$1")" --no-focus >/dev/null }

# hl_attach — from a shell, the point of hdev is to end up *inside* Herdr. Build or
# focus first, then hand the terminal over. Inside Herdr there is nothing to attach to,
# and HDEV_NO_ATTACH lets tests and scripted runs stop short of a blocking TUI.
hl_attach() {
  [[ -n "${HERDR_ENV:-}" ]] && return 0
  [[ -n "${HDEV_NO_ATTACH:-}" ]] && return 0
  exec command herdr
}

main() {
  local mode repo
  if [[ "${1:-}" == "--current" ]]; then
    mode=current
  else
    mode=path
    repo="${1:?usage: layout.sh <repo-path> | --current}"
    [[ -d "$repo" ]] || die "no such directory: $repo"
    repo="${repo:A}"
  fi

  if [[ -z "${HERDR_ENV:-}" ]]; then
    hl_ensure_server
  fi

  if [[ "$mode" == path ]]; then
    hl_lock "$repo"
    local ws; ws="$(hl_find_workspace "$repo")" || exit 1
    # Explicit propagation, not `setopt err_return`: err_return does not fire for a
    # command whose status is already being tested, so it gives false confidence in
    # exactly the shapes used here. Without this, a failed focus or a failed create
    # fell through to hl_attach and the whole run reported success.
    if [[ -n "$ws" ]]; then
      hl_reconcile "$ws" "$repo" || exit 1
    else
      hl_build "$repo" || exit 1
    fi
  fi

  hl_attach
}

# Allow the test suite to source the helpers without running anything.
if [[ "${1:-}" == "--source-only" ]]; then
  return 0 2>/dev/null || exit 0
fi
main "$@"
