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
setopt local_options no_unset pipe_fail

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

  # Workspace handling arrives in Tasks 5-8.

  hl_attach
}

# Allow the test suite to source the helpers without running anything.
if [[ "${1:-}" == "--source-only" ]]; then
  return 0 2>/dev/null || exit 0
fi
main "$@"
