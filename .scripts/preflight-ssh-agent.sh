#!/usr/bin/env bash
# Resolve the SSH agent socket that sandboxed git actually uses, so allowUnixSockets can
# be narrowed to it. Read-only: changes nothing. Bash 3.2 compatible.
#
# CONTRACT: stdout carries ONLY the socket path, and only on success. Every diagnostic
# goes to stderr, so `sock=$(preflight-ssh-agent.sh)` yields a clean path.
#
# Exit 0 -> protocol-validated socket path on stdout (allowlist exactly it)
# Exit 2 -> no usable socket; layer 2 (credential denial) MUST NOT deploy, because
#           denying on-disk keys without a working agent path breaks sandboxed git auth.
set -u

log() { printf '%s\n' "$*" >&2; }

log "== SSH agent preflight =="
log "SSH_AUTH_SOCK: ${SSH_AUTH_SOCK:-(unset)}"

# A socket file existing proves nothing: it may be stale, or belong to an agent holding
# no identities. Once the on-disk keys are denied, ssh_config's `AddKeysToAgent yes`
# cannot recover (it would have to read the key file), so identities must be present NOW.
validate() {  # validate <path> -> 0 only if the agent answers AND holds >=1 identity
  [ -S "$1" ] || { log "  absent or not a socket: $1"; return 1; }
  SSH_AUTH_SOCK="$1" ssh-add -l >/dev/null 2>&1
  case $? in
    0) log "  agent responds, identities present: $1"; return 0 ;;
    1) log "  agent responds but holds NO identities: $1"; return 1 ;;
    *) log "  cannot connect to agent at: $1"; return 1 ;;
  esac
}

for c in "$HOME/.1password/agent.sock" \
         "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"; do
  if validate "$c"; then
    log "RESULT: allowlist $c"
    printf '%s\n' "$c"          # the ONLY write to stdout
    exit 0
  fi
done

case "${SSH_AUTH_SOCK:-}" in
  /var/run/com.apple.launchd.*/Listeners)
    log "RESULT: launchd agent only — the path has a per-boot random component."
    log "Refusing to emit a wildcard: it would admit every launchd listener."
    exit 2 ;;
  "")
    log "RESULT: no SSH agent in this environment."; exit 2 ;;
  *)
    if validate "${SSH_AUTH_SOCK}"; then
      log "RESULT: socket is live, but its path stability across reboot is unproven."
      log "Confirm stability before allowlisting; failing closed for now."
    fi
    exit 2 ;;
esac
