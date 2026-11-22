#!/bin/bash
# Loads the be.netronix.* LaunchAgents chezmoi wrote, safe to re-run: a job is bootstrapped
# when it is not loaded, and a loaded one is reloaded only when its plist differs from the
# copy recorded at its last load. be.netronix.codex-app-server is never reloaded: a reload
# disconnects every Codex session. macOS /bin/bash is 3.2: no associative arrays, no ${x,,}.
set -u

uid=$(id -u)
state="${XDG_STATE_HOME:-$HOME/.local/state}/launchagents"
failed=0

# launchd tears a job down asynchronously: right after a bootout the label can still
# answer print, and a bootstrap then fails. Poll up to about 5 s for it to go.
wait_unloaded() {
  local i=0
  while [ "$i" -lt 25 ] && launchctl print "gui/$uid/$1" >/dev/null 2>&1; do
    sleep 0.2
    i=$((i + 1))
  done
}

# One retry after 1 s: a bootstrap straight after a bootout can still lose that race.
bootstrap() {
  launchctl bootstrap "gui/$uid" "$1" >/dev/null 2>&1 && return 0
  sleep 1
  launchctl bootstrap "gui/$uid" "$1" >/dev/null 2>&1
}

for plist in "$HOME/Library/LaunchAgents"/be.netronix.*.plist; do
  [ -f "$plist" ] || continue
  label=$(basename "$plist" .plist)
  record="$state/$label.plist"

  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    if [ "$label" = be.netronix.codex-app-server ]; then
      echo "  unchanged $label (never reloaded here: a reload disconnects every Codex session)"
      continue
    fi
    if cmp -s "$plist" "$record"; then
      echo "  unchanged $label"
      continue
    fi
    launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
    wait_unloaded "$label"
    verb=reloaded
  else
    verb=loaded
  fi

  if bootstrap "$plist"; then
    echo "  $verb $label"
    # Without the record every later run would reload this job (ssh-agent loses its keys).
    if ! { mkdir -p "$state" && cp "$plist" "$record"; } 2>/dev/null; then
      echo "  could not record $label in $state"
      failed=1
    fi
  else
    echo "  could not load $label — run: launchctl bootstrap gui/$uid $plist"
    failed=1
  fi
done

exit "$failed"
